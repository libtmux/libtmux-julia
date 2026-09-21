import FileWatching

function lifecycle_environment()
    Dict(
        "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM" => "xterm-256color",
        "SHELL" => "/bin/sh",
        "TMUX" => "borrowed",
        "TMUX_PANE" => "%999",
        "LIBTMUX_OWNER_TEST" => "owned-environment-marker",
    )
end

@testset "owned server lifecycle" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    owned = LibTmux.open_server(; tmux, env=lifecycle_environment())
    process = getfield(owned, :_process)
    directory = dirname(owned.server.socket_path)
    try
        @test isopen(owned)
        @test startswith(basename(directory), "libtmux-julia-")
        @test propertynames(owned) == (:server,)
        @test !occursin("owned-environment-marker", sprint(show, owned))
        @test decode_text(
            run_command(owned.server, "display-message", "-p", "#{pid}").stdout,
        ) == string(getpid(process)) * "\n"
        @test decode_text(
            run_command(owned.server, "show-environment", "-g", "LIBTMUX_OWNER_TEST").stdout,
        ) == "LIBTMUX_OWNER_TEST=owned-environment-marker\n"
        @test_throws CommandError run_command(
            owned.server,
            "show-environment",
            "-g",
            "TMUX",
        )
        @test_throws CommandError run_command(
            owned.server,
            "show-environment",
            "-g",
            "TMUX_PANE",
        )
        with_tmux() do borrowed
            close(owned)
            @test readchomp(tmuxcmd(borrowed, "display-message", "-p", "#{pid}")) ==
                  string(getpid(borrowed.process))
        end
    finally
        close(owned)
    end
    @test !isopen(owned) && process_exited(process)
    @test !ispath(directory)
    @test istaskdone(getfield(owned, :_watcher))
    @test istaskdone(getfield(owned, :_stderr_task))
    @test close(owned) === nothing

    endpoint = Ref{Server}()
    result = LibTmux.with_server(; tmux, env=lifecycle_environment()) do server
        endpoint[] = server
        new_session(server; name="owned", command=["/bin/cat"])
        :completed
    end
    @test result === :completed && !ispath(dirname(endpoint[].socket_path))
    sentinel = ErrorException("body failed")
    failure = try
        LibTmux.with_server(; tmux, env=lifecycle_environment()) do server
            endpoint[] = server
            throw(sentinel)
        end
    catch error
        error
    end
    @test failure === sentinel
    @test !ispath(dirname(endpoint[].socket_path))

    owned = LibTmux.open_server(; tmux, env=lifecycle_environment())
    tasks = [Threads.@spawn(close(owned)) for _ = 1:4]
    @test all(task -> fetch(task) === nothing, tasks)
    @test process_exited(getfield(owned, :_process)) &&
          !ispath(dirname(owned.server.socket_path))

    owned = LibTmux.open_server(; tmux, env=lifecycle_environment())
    directory = dirname(owned.server.socket_path)
    try
        write(joinpath(directory, "owner"), "replaced-marker")
        failure = try
            close(owned)
        catch error
            error
        end
        @test failure isa LibTmux.OwnedServerCleanupError &&
              failure.reason === :directory_ownership
        @test process_exited(getfield(owned, :_process)) && isdir(directory)
    finally
        close(owned)
        rm(directory; recursive=true)
    end
end

@testset "owned startup failures" begin
    mktempdir(; prefix="ltj-life-") do parent
        withenv("TMPDIR" => parent) do
            token = CancellationToken()
            cancel!(token)
            @test_throws RequestCancelled LibTmux.open_server(
                env=lifecycle_environment(),
                cancel=token,
            )
            @test_throws TmuxNotFound LibTmux.open_server(
                tmux="libtmux-no-such-tmux",
                env=lifecycle_environment(),
            )
            @test_throws ArgumentError LibTmux.open_server(
                env=Dict("bad=name" => "private-value"),
            )
            @test isempty(readdir(parent))
            diagnostic = try
                LibTmux.open_server(tmux="libtmux-no-such-tmux", env=lifecycle_environment())
            catch
                sprint(showerror, current_exceptions())
            end
            contains_environment = occursin("owned-environment-marker", diagnostic)
            @test !contains_environment
            executable = joinpath(parent, "failing-tmux")
            write(executable, "#!/bin/sh\nprintf 'startup diagnostic' >&2\nexit 7\n")
            chmod(executable, 0o700)
            failure = try
                LibTmux.open_server(tmux=executable, env=lifecycle_environment())
            catch error
                error
            end
            @test failure isa LibTmux.OwnedServerStartError
            @test failure.result.exitcode == 7
            @test failure.result.stderr == codeunits("startup diagnostic")
            @test readdir(parent) == ["failing-tmux"]

            write(executable, "#!/bin/sh\nprintf '%070000d' 0 >&2\nexit 7\n")
            failure = try
                LibTmux.open_server(tmux=executable, env=lifecycle_environment())
            catch error
                error
            end
            @test failure isa LibTmux.OwnedServerStartError
            @test length(failure.result.stderr) == 64 * 1024 && failure.stderr_truncated
            @test readdir(parent) == ["failing-tmux"]
        end
    end
end

@testset "owned startup cancellation" begin
    mktempdir(; prefix="ltj-life-") do parent
        withenv("TMPDIR" => parent) do
            executable, ready, hold = joinpath.(parent, ("waiting-tmux", "ready", "hold"))
            write(
                executable,
                "#!/bin/sh\nprintf '%s\\n' \"\$\$\" >\"\$LIBTMUX_READY\"\nexec /bin/cat \"\$LIBTMUX_HOLD\"\n",
            )
            chmod(executable, 0o700)
            run(`mkfifo $hold`)
            environment = merge(
                lifecycle_environment(),
                Dict("LIBTMUX_READY" => ready, "LIBTMUX_HOLD" => hold),
            )
            token = CancellationToken()
            monitor = FileWatching.FolderMonitor(parent)
            operation = Threads.@spawn try
                LibTmux.open_server(tmux=executable, env=environment, cancel=token)
            catch error
                error
            end
            watcher = Threads.@spawn begin
                wait(operation)
                close(monitor)
            end
            try
                while !isfile(ready) && isopen(monitor)
                    try
                        wait(monitor)
                    catch error
                        error isa EOFError || rethrow()
                    end
                end
                @test isfile(ready)
                cancel!(token)
                failure = fetch(operation)
                @test failure isa RequestCancelled && failure.sent
                @test failure.result !== nothing &&
                      failure.result.termsignal == Base.SIGTERM
                @test isempty(token.hooks)
                @test sort(readdir(parent)) == ["hold", "ready", "waiting-tmux"]
                expired = try
                    LibTmux.open_server(tmux=executable, env=environment, timeout=0.1)
                catch error
                    error
                end
                @test expired isa DeadlineExceeded && expired.sent && expired.timeout == 0.1
                @test expired.result !== nothing &&
                      expired.result.termsignal == Base.SIGTERM
                @test sort(readdir(parent)) == ["hold", "ready", "waiting-tmux"]
            finally
                cancel!(token)
                wait(operation)
                close(monitor)
                wait(watcher)
            end
        end
    end
end

# Outer case: a stopped daemon requires the 900 ms SIGKILL escalation deadline.
if get(ENV, "LIBTMUX_TEST_LIFECYCLE_ESCALATION", "0") == "1"
    @testset "owned lifecycle forced cleanup" begin
        tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
        owned = LibTmux.open_server(; tmux, env=lifecycle_environment())
        process = getfield(owned, :_process)
        directory = dirname(owned.server.socket_path)
        try
            run(Cmd(["kill", "-STOP", string(getpid(process))]))
            @test_throws LibTmux.OwnedServerCleanupError close(owned)
        finally
            close(owned)
        end
        @test process_exited(process) && process.termsignal == Base.SIGKILL
        @test !ispath(directory) && !isopen(owned)
        @test istaskdone(getfield(owned, :_watcher)) &&
              istaskdone(getfield(owned, :_stderr_task))
        @test close(owned) === nothing

        sentinel = ErrorException("body failed before forced cleanup")
        endpoint = Ref{Server}()
        failure = try
            LibTmux.with_server(; tmux, env=lifecycle_environment()) do server
                endpoint[] = server
                pid = parse(
                    Int,
                    decode_text(
                        run_command(server, "display-message", "-p", "#{pid}").stdout,
                    ),
                )
                run(Cmd(["kill", "-STOP", string(pid)]))
                throw(sentinel)
            end
        catch error
            error
        end
        @test failure isa CompositeException
        @test failure.exceptions[1] === sentinel
        @test failure.exceptions[2] isa LibTmux.OwnedServerCleanupError
        @test !ispath(dirname(endpoint[].socket_path))
    end
end

include("lifecycle_retirement.jl")
