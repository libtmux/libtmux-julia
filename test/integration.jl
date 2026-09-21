@testset "tmux subprocess boundary" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        @test_throws ArgumentError run_command(server)
        result = run_command(server, "display-message", "-p", "#{pid}")
        @test chomp(String(copy(result.stdout))) == string(getpid(fixture.process))
        @test isempty(result.stderr) && result.exitcode == 0
        unicode = run_command(
            server,
            "display-message",
            "-p",
            "é 雪";
            env=Dict("PATH" => get(ENV, "PATH", "/usr/bin:/bin"), "LC_ALL" => "C"),
        )
        @test unicode.stdout == codeunits("é 雪\n")
        failed = run_command(server, "kill-pane", "-t", "%999999"; check=false)
        @test failed.exitcode != 0
        @test !isempty(failed.stderr)
        @test_throws CommandError run_command(server, "kill-pane", "-t", "%999999")
        @test_throws ArgumentError run_command(server, "display-message", "a\0b")
        @test_throws ArgumentError run_command(
            server,
            "display-message",
            repeat("x", 15 * 1024),
        )
        @test_throws CommandError run_command(
            server,
            "-S",
            "/tmp/another-server",
            "list-sessions",
        )

        # Compile both timed paths before the one-thread live cancellation race.
        run_command(server, "display-message", "-p", "ready"; timeout=0.9)
        run_command(
            server,
            "display-message",
            "-p",
            "ready";
            cancel=CancellationToken(),
            timeout=0.9,
        )

        token = CancellationToken()
        task = Threads.@spawn try
            run_command(
                server,
                "wait-for",
                "-S",
                "started",
                ";",
                "wait-for",
                "blocked";
                cancel=token,
                timeout=0.9,
            )
        catch error
            error
        end
        run_command(server, "wait-for", "started"; timeout=0.9)
        cancel!(token)
        outcome = fetch(task)
        @test outcome isa RequestCancelled
        outcome isa RequestCancelled && @test outcome.sent
        @test process_running(fixture.process)
        @test run_command(server, "display-message", "-p", "alive").stdout ==
              codeunits("alive\n")
    end
end
