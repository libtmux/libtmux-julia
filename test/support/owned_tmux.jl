module OwnedTmux

using FileWatching
import LibTmux

export Fixture, tmuxcmd, with_tmux, with_control_if_supported

struct Fixture
    tmux::String
    directory::String
    socket::String
    env::Dict{String,String}
    process::Base.Process
end

"""
    with_control_if_supported(f, server, session)

Call `f(connection)` with an open control connection where tmux allows control
acquisition (3.7 and newer), and `f(nothing)` below it, so one body can cover the
subprocess transport everywhere and the control transport where it exists.
"""
function with_control_if_supported(f, server, session)
    release = LibTmux._daemon_version(server, LibTmux._client_environment(ENV))
    if LibTmux._version_at_least(release, LibTmux.CONTROL_MINIMUM_TMUX)
        LibTmux.open_control(f, server, session)
    else
        f(nothing)
    end
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
    forced[] && error("owned tmux daemon required SIGKILL during cleanup")
end

"Stop a test-created forked daemon; Linux waits on its pinned process identity."
function stop_daemon(tmux, socket; pidfd_symbols=nothing)
    environment = Dict(
        "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM" => "xterm-256color",
        "SHELL" => "/bin/sh",
        Main.TestSandbox.child_entries()...,
    )
    command(args...) = setenv(Cmd([tmux, "-N", "-S", socket, args...]), environment)
    errors = Any[]
    attempt(f) =
        try
            f()
        catch error
            push!(errors, error)
            nothing
        end
    descriptor, library, send_signal = -1, nothing, C_NULL
    attempt() do
        if Sys.islinux()
            if pidfd_symbols === nothing
                library = Base.Libc.Libdl.dlopen("")
                pidfd_symbols = (
                    Base.Libc.Libdl.dlsym_e(library, :pidfd_open),
                    Base.Libc.Libdl.dlsym_e(library, :pidfd_send_signal),
                )
            end
            open_pidfd, send_signal = pidfd_symbols
            if open_pidfd != C_NULL && send_signal != C_NULL
                probe = LibTmux._run_process(
                    command("display-message", "-p", "#{pid}");
                    timeout=0.9,
                )
                if probe.exitcode == 0 && probe.termsignal == 0
                    pid = parse(Cint, strip(String(probe.stdout)))
                    descriptor = ccall(open_pidfd, Cint, (Cint, Cuint), pid, 0)
                    if descriptor < 0
                        reason = Base.Libc.errno()
                        reason == Base.Libc.ESRCH && return
                        reason == Base.Libc.ENOSYS || Base.systemerror("pidfd_open", true)
                    else
                        return
                    end
                else
                    diagnostic = String(probe.stderr)
                    probe.termsignal == 0 && LibTmux._endpoint_absent(diagnostic) && return
                    error(
                        "owned tmux PID query failed: exit=$(probe.exitcode), signal=$(probe.termsignal); $diagnostic",
                    )
                end
            end
        end
        @warn "pidfd unavailable; owned tmux daemon exit will not be observed"
    end
    attempt() do
        result = LibTmux._run_process(command("kill-server"); timeout=0.9)
        if result.exitcode != 0 || result.termsignal != 0
            diagnostic = String(result.stderr)
            result.termsignal == 0 && LibTmux._endpoint_absent(diagnostic) || error(
                "owned tmux shutdown failed: exit=$(result.exitcode), signal=$(result.termsignal); $diagnostic",
            )
        end
    end
    if descriptor >= 0
        exited = attempt() do
            FileWatching.poll_fd(Base.RawFD(descriptor), 0.9; readable=true).readable
        end
        if exited !== true
            signalled = attempt() do
                ccall(
                    send_signal,
                    Cint,
                    (Cint, Cint, Ptr{Cvoid}, Cuint),
                    descriptor,
                    Base.SIGKILL,
                    C_NULL,
                    0,
                )
            end
            retired = attempt() do
                FileWatching.poll_fd(Base.RawFD(descriptor), 0.9; readable=true).readable
            end
            push!(
                errors,
                ErrorException(
                    "owned tmux daemon exceeded shutdown deadline; SIGKILL result=$signalled; exit observed=$retired",
                ),
            )
        end
        attempt(
            () -> Base.systemerror(
                "close pidfd",
                ccall(:close, Cint, (Cint,), descriptor) != 0,
            ),
        )
    end
    library === nothing || attempt(() -> Base.Libc.Libdl.dlclose(library))
    isempty(errors) ||
        throw(length(errors) == 1 ? only(errors) : CompositeException(errors))
    nothing
end

function await_ready(fixture::Fixture, monitor::FolderMonitor)
    timer = Timer(_ -> close(monitor), 0.9)
    try
        while process_running(fixture.process)
            # tmux removes its startup lock only after bind() and listen().
            if ispath(fixture.socket) && !ispath(fixture.socket * ".lock")
                return
            end
            isopen(monitor) || error("owned tmux startup exceeded 900 ms")
            wait(monitor)
        end
        error("owned tmux daemon exited before startup completed")
    finally
        close(timer)
        close(monitor)
    end
end

"""
    with_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))

Call `f(fixture)` with an isolated foreground tmux daemon. The callback's
return value is preserved. Startup uses filesystem notifications; shutdown
waits for and reaps the owned daemon, including when the callback throws.
Only `PATH` is inherited; `TERM` and `SHELL` have fixed test values. The
fixture does not own additional processes spawned by the callback.
"""
function with_tmux(f; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"))
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
            Main.TestSandbox.child_entries()...,
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
