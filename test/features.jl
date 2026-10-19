isdefined(Main, :OwnedTmux) || include("support/owned_tmux.jl")

# A scripted client that reports `release` and refuses everything else, so a
# guard that dispatches anything after the release probe is visible.
function release_client(directory, release; name="tmux")
    script = joinpath(directory, name)
    write(
        script,
        """#!/bin/sh
printf '%s\\n' "\$*" >> "\$0.calls"
previous=
for argument in "\$@"; do
    if [ "\$previous" = -C ]; then
        printf 'unknown command: %s$release\\n' "\${argument%\\#\\{version\\}}" >&2
        exit 1
    fi
    previous=\$argument
done
exit 99
""",
    )
    chmod(script, 0o700)
    script
end

@testset "the supported floor refuses effects and attaches" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session = new_session(server; name="guarded", command=["/bin/cat"])
        captured = snapshot(server)
        pane = only(panes(captured)).ref
        window = only(windows(captured)).ref
        link = WindowLinkRef(only(windowlinks(only(windows(captured)))))
        @test success(OwnedTmux.tmuxcmd(fixture, "set-buffer", "-b", "bystander", "keep"))
        mktempdir(; prefix="ltj-feat-") do directory
            for release in ("3.3a", "3.4", "3.6b", "3.7", "3.7a", "3.7b")
                script = release_client(directory, release; name="tmux-$release")
                scripted = Server(socket_path=fixture.socket, tmux=script)
                operations = (
                    () -> run_command(
                        scripted,
                        "set-option",
                        "-g",
                        "@must-not-change",
                        "x",
                    ),
                    () -> new_session(scripted; name="must-not-create"),
                    () -> load_buffer(scripted, UInt8[0x64]),
                    () -> delete_buffer(scripted, BufferRef(pane.server, "bystander")),
                    () -> break_pane(scripted, pane, link, session; index=1),
                    () -> open_control(scripted, session),
                )
                for operation in operations
                    @test_throws UnsupportedTmuxVersion operation()
                end
                calls = readlines(script * ".calls")
                @test length(calls) == length(operations)
                @test all(contains("run-shell -C"), calls)
            end
        end
        @test readchomp(OwnedTmux.tmuxcmd(fixture, "show-buffer", "-b", "bystander")) ==
              "keep"
        @test isempty(readlines(OwnedTmux.tmuxcmd(fixture, "list-clients")))
        @test rename_session(server, session, "x.y") isa CommandResult
        @test rename_window(server, window, "x:y") isa CommandResult
    end
end
