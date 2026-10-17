@testset "tmux older than 3.2 is refused, not reported as a probe failure" begin
    # What tmux 3.1 (daemon), a 3.0 daemon and a client older than 3.2 print for
    # `tmux -N -- run-shell -C <marker>`.
    diagnostics = (
        "usage: run-shell [-b] [-t target-pane] shell-command",
        "server version is too old for client",
        "tmux: unknown option -- N\nusage: tmux [-2CluvV] [-c shell-command]",
    )
    mktempdir(; prefix="ltj-old-") do directory
        script = joinpath(directory, "tmux-old")
        socket = joinpath(directory, "s")
        old = Server(socket_path=socket, tmux=script)
        commands = [LibTmux.TmuxCommand("list-sessions")]
        for diagnostic in diagnostics
            rm(script * ".calls"; force=true)
            write(
                script,
                """#!/bin/sh
printf '%s\\n' "\$*" >> "\$0.calls"
cat >&2 <<'DIAGNOSTIC'
$diagnostic
DIAGNOSTIC
exit 1
""",
            )
            chmod(script, 0o700)
            failure = try
                run_command(old, "new-session", "-d", "-s", "refused")
            catch error
                error
            end
            @test failure isa UnsupportedTmuxVersion
            failure isa UnsupportedTmuxVersion &&
                @test occursin("older than 3.2", sprint(showerror, failure))
            @test all(contains("run-shell -C"), readlines(script * ".calls"))
            @test !ispath(socket)

            batch = LibTmux.run_batch(old, commands; timeout=60)
            @test only(batch).status === :failed && !only(batch).acknowledged
        end

        # A probe that fails for another reason is a command error that never
        # dispatched anything.
        write(script, "#!/bin/sh\necho 'boom' >&2\nexit 1\n")
        probe = try
            run_command(old, "new-session", "-d", "-s", "refused")
        catch error
            error
        end
        @test probe isa LibTmux.CommandError && LibTmux._not_dispatched(probe)
        batch = LibTmux.run_batch(old, commands; timeout=60)
        @test only(batch).status === :failed && !only(batch).acknowledged
    end
end
