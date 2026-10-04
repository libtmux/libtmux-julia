module OwnedTmux

using FileWatching

export Fixture, tmuxcmd, with_tmux

include("hang_guard.jl")

struct Fixture
    tmux::String
    directory::String
    socket::String
    env::Dict{String,String}
    process::Base.Process
end

"Build a command that cannot start or contact any other tmux server."
function tmuxcmd(fixture::Fixture, args::AbstractString...)
    setenv(
        Cmd([
            fixture.tmux,
            "-u",
            "-N",
            "-S",
            fixture.socket,
            "-f",
            "/dev/null",
            "--",
            args...,
        ]),
        fixture.env,
    )
end

function stop!(process::Base.Process; grace=HANG_GUARD)
    process_exited(process) && return
    forced = Ref(false)
    timer = Timer(grace) do _
        if process_running(process)
            forced[] = true
            kill(process, Base.SIGKILL)
        end
    end
    try
        kill(process, Base.SIGTERM)
        wait(process)
    finally
        close(timer)
    end
    forced[] && error("owned tmux daemon required SIGKILL during cleanup")
end

# See `_watch_wake` in src/lifecycle.jl.
function wake_source(monitor::FolderMonitor; interval=0.05)
    wake = Base.Event(true)
    task = Threads.@spawn begin
        try
            while true
                wait(monitor)
                notify(wake)
            end
        catch error
            error isa EOFError || rethrow()
        finally
            notify(wake)
        end
    end
    tick = Timer(_ -> notify(wake), interval; interval)
    wake, () -> (close(tick); close(monitor); wait(task))
end

function await_ready(fixture::Fixture, monitor::FolderMonitor; budget=HANG_GUARD)
    timer = Timer(_ -> close(monitor), budget)
    wake, release = wake_source(monitor)
    try
        while process_running(fixture.process)
            # tmux removes its startup lock only after bind() and listen().
            if ispath(fixture.socket) && !ispath(fixture.socket * ".lock")
                return
            end
            isopen(monitor) || error("owned tmux startup exceeded its hang guard")
            wait(wake)
        end
        error("owned tmux daemon exited before startup completed")
    finally
        close(timer)
        release()
    end
end

"""
    with_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), grace=HANG_GUARD)

Call `f(fixture)` with an isolated foreground tmux daemon. The callback's
return value is preserved. Startup uses filesystem notifications; shutdown
waits for and reaps the owned daemon, including when the callback throws.
Only `PATH` is inherited; `TERM` and `SHELL` have fixed test values. The
fixture does not own additional processes spawned by the callback. `grace` is
how long a stopped daemon may take to exit before SIGKILL fails the test.
"""
function with_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), grace=HANG_GUARD)
    directory = mktempdir(; prefix="libtmux-julia-", cleanup=false)
    process = nothing
    watcher = nothing
    monitor = nothing
    log = nothing
    primary_error = nothing
    try
        socket = joinpath(directory, "s")
        ncodeunits(socket) < 104 ||
            error("temporary directory makes the tmux socket path too long")
        env = Dict(
            "PATH" => get(ENV, "PATH", "/usr/local/bin:/usr/bin:/bin"),
            "TERM" => "xterm-256color",
            "SHELL" => "/bin/sh",
        )
        log = open(joinpath(directory, "stderr"), "w+")
        monitor = FolderMonitor(directory)
        command = setenv(Cmd([tmux, "-D", "-S", socket, "-f", "/dev/null"]), env)
        process =
            run(pipeline(command; stdin=devnull, stdout=devnull, stderr=log); wait=false)
        fixture = Fixture(tmux, directory, socket, env, process)
        watcher = Threads.@spawn begin
            wait(fixture.process)
            close(monitor)
        end
        await_ready(fixture, monitor)
        observed_pid = readchomp(tmuxcmd(fixture, "display-message", "-p", "#{pid}"))
        observed_pid == string(getpid(process)) ||
            error("tmux daemon ownership check failed")
        return f(fixture)
    catch error
        primary_error = error
        rethrow()
    finally
        cleanup_error = nothing
        try
            process === nothing || stop!(process; grace)
        catch error
            cleanup_error = error
        finally
            monitor === nothing || close(monitor)
            watcher === nothing || wait(watcher)
            log === nothing || close(log)
            rm(directory; recursive=true, force=true)
        end
        if cleanup_error !== nothing
            primary_error === nothing && throw(cleanup_error)
            throw(CompositeException([primary_error, cleanup_error]))
        end
    end
end

end
