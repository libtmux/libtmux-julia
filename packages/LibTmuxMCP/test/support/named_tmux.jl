module NamedTmux

using FileWatching
using LibTmux

export Fixture, with_named_tmux

struct Fixture
    server::Server
    tmux::String
    socket_name::String
    socket_path::String
    directory::String
    env::Dict{String,String}
    process::Base.Process
end

function tmuxcmd(fixture::Fixture, args::AbstractString...)
    setenv(
        Cmd([fixture.tmux, "-L", fixture.socket_name, "-f", "/dev/null", "--", args...]),
        fixture.env,
    )
end

function stop!(process::Base.Process)
    process_exited(process) && return
    forced = Ref(false)
    timer = Timer(0.9) do _
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
    forced[] && error("owned named tmux daemon required SIGKILL during cleanup")
end

function await_ready(fixture::Fixture, monitor::FolderMonitor)
    timer = Timer(_ -> close(monitor), 0.9)
    try
        while process_running(fixture.process)
            if ispath(fixture.socket_path) && !ispath(fixture.socket_path * ".lock")
                return
            end
            isopen(monitor) || error("owned named tmux startup exceeded 900 ms")
            try
                wait(monitor)
            catch caught
                caught isa EOFError || rethrow()
                process_running(fixture.process) &&
                    error("owned named tmux startup exceeded 900 ms")
                error("owned named tmux daemon exited before startup completed")
            end
        end
        error("owned named tmux daemon exited before startup completed")
    finally
        close(timer)
        close(monitor)
    end
end

"""
    with_named_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))

Call `f(fixture)` with a foreground tmux daemon addressed through `-L`.
The private directory is always created below `/tmp`, avoiding an inherited
temporary directory that would exceed tmux's UNIX-socket path limit. The
callback sees the matching `TMUX_TMPDIR` and no inherited tmux selector.
"""
function with_named_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))
    directory = mktempdir("/tmp"; prefix="ltj-named-", cleanup=false)
    process = nothing
    watcher = nothing
    monitor = nothing
    log = nothing
    primary_error = nothing
    try
        directory = realpath(directory)
        socket_name = "s"
        socket_directory = joinpath(directory, "tmux-$(Libc.getuid())")
        socket_path = joinpath(socket_directory, socket_name)
        ncodeunits(socket_path) < 104 ||
            error("temporary directory makes the tmux socket path too long")
        mkdir(socket_directory; mode=0o700)
        env = Dict(
            "PATH" => get(ENV, "PATH", "/usr/local/bin:/usr/bin:/bin"),
            "TERM" => "xterm-256color",
            "SHELL" => "/bin/sh",
            "TMUX_TMPDIR" => directory,
        )
        log = open(joinpath(directory, "stderr"), "w+")
        monitor = FolderMonitor(socket_directory)
        command = setenv(Cmd([tmux, "-D", "-L", socket_name, "-f", "/dev/null"]), env)
        process =
            run(pipeline(command; stdin=devnull, stdout=devnull, stderr=log); wait=false)
        fixture = Fixture(
            Server(socket_name=socket_name, tmux=tmux),
            tmux,
            socket_name,
            socket_path,
            directory,
            env,
            process,
        )
        watcher = Threads.@spawn begin
            wait(fixture.process)
            close(monitor)
        end
        await_ready(fixture, monitor)
        observed_pid = readchomp(tmuxcmd(fixture, "display-message", "-p", "#{pid}"))
        observed_pid == string(getpid(process)) ||
            error("tmux daemon ownership check failed")
        return withenv(
            "TMUX" => nothing,
            "TMUX_PANE" => nothing,
            "TMUX_TMPDIR" => directory,
        ) do
            f(fixture)
        end
    catch error
        primary_error = error
        rethrow()
    finally
        cleanup_error = nothing
        try
            process === nothing || stop!(process)
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
