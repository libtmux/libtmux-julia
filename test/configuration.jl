@testset "configuration scopes and values" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session_ref = new_session(server; name="configuration", command=["/bin/cat"])
        captured = snapshot(server)
        window_ref = only(windows(captured)).ref
        pane_ref = only(panes(captured)).ref
        value = "empty?\tline\n#{pane_id}\\;\n" * raw"$ENV \$ENV ${ENV} $_env"
        value *= String(UInt8[1:31; 127]) * raw"\033 \r \a \177"

        @test LibTmux.get_option(server, :server, "escape-time") isa String
        @test LibTmux.get_option(server, session_ref, "status-left") === nothing
        LibTmux.set_option(server, :global_session, "@configuration", value)
        @test LibTmux.get_option(server, session_ref, "@configuration") === nothing
        @test LibTmux.get_option(server, session_ref, "@configuration"; inherit=true) ==
              value
        LibTmux.set_option(server, session_ref, "@configuration", "")
        @test LibTmux.get_option(server, session_ref, "@configuration"; inherit=true) == ""
        LibTmux.unset_option(server, session_ref, "@configuration")
        @test LibTmux.get_option(server, session_ref, "@configuration"; inherit=true) ==
              value
        LibTmux.set_option(server, :global_window, "@configuration", "global window")
        @test LibTmux.get_option(server, pane_ref, "@configuration"; inherit=true) ==
              "global window"
        LibTmux.set_option(server, window_ref, "@configuration", "window")
        @test LibTmux.get_option(server, pane_ref, "@configuration"; inherit=true) ==
              "window"
        LibTmux.set_option(server, pane_ref, "@configuration", value)
        @test LibTmux.get_option(server, pane_ref, "@configuration") == value
        LibTmux.set_option(server, window_ref, "pane-border-format", value)
        @test LibTmux.get_option(server, window_ref, "pane-border-format") == value
        @test_throws ArgumentError LibTmux.set_option(
            server,
            pane_ref,
            "status-left",
            "wrong scope",
        )
        @test LibTmux.get_option(server, session_ref, "status-left") === nothing
        LibTmux.set_option(server, session_ref, "status-format", value; index=7)
        @test LibTmux.get_option(server, session_ref, "status-format"; index=7) == value
        @test LibTmux.get_option(server, session_ref, "status-format"; index=6) === nothing
        @test_throws ArgumentError LibTmux.get_option(server, session_ref, "status-format")
        LibTmux.unset_option(server, session_ref, "status-format"; index=7)
        @test LibTmux.get_option(server, session_ref, "status-format"; index=7) === nothing

        LibTmux.set_environment(server, :global, "LIBTMUX_CONFIG", value)
        @test LibTmux.get_environment(server, session_ref, "LIBTMUX_CONFIG") === nothing
        environment =
            LibTmux.get_environment(server, session_ref, "LIBTMUX_CONFIG"; inherit=true)
        @test environment.value == value && environment.inherited
        LibTmux.set_environment(server, session_ref, "LIBTMUX_CONFIG", "")
        @test LibTmux.get_environment(server, session_ref, "LIBTMUX_CONFIG").value == ""
        LibTmux.remove_environment(server, session_ref, "LIBTMUX_CONFIG")
        removed =
            LibTmux.get_environment(server, session_ref, "LIBTMUX_CONFIG"; inherit=true)
        @test removed.value === nothing && !removed.inherited
        LibTmux.unset_environment(server, session_ref, "LIBTMUX_CONFIG")
        @test LibTmux.get_environment(
            server,
            session_ref,
            "LIBTMUX_CONFIG";
            inherit=true,
        ).value == value
        LibTmux.set_environment(server, session_ref, "LIBTMUX_SECRET", value; hidden=true)
        hidden = LibTmux.get_environment(server, session_ref, "LIBTMUX_SECRET")
        @test hidden.value == value && hidden.hidden && !hidden.inherited

        LibTmux.set_hook(
            server,
            :global_session,
            "after-new-window",
            raw"set-option -g @hook-first 'literal #{pane_id};'";
            index=2,
        )
        LibTmux.set_hook(
            server,
            :global_session,
            "after-new-window",
            raw"set-option -g @hook-second 'second'";
            index=9,
        )
        @test LibTmux.get_hook(server, session_ref, "after-new-window") === nothing
        hooks = LibTmux.get_hook(server, session_ref, "after-new-window"; inherit=true)
        @test [h.index for h in hooks] == [2, 9]
        @test all(h -> h.inherited, hooks)
        @test occursin("@hook-first", hooks[1].command)
        @test LibTmux.get_option(server, :global_session, "@hook-first") === nothing
        new_window(server, session_ref; command=["/bin/cat"])
        @test LibTmux.get_option(server, :global_session, "@hook-first") ==
              "literal #{pane_id};"
        @test LibTmux.get_option(server, :global_session, "@hook-second") == "second"
        LibTmux.set_hook(server, session_ref, "after-new-window", "")
        @test isempty(
            LibTmux.get_hook(server, session_ref, "after-new-window"; inherit=true),
        )
        LibTmux.unset_hook(server, session_ref, "after-new-window")
        @test length(
            LibTmux.get_hook(server, session_ref, "after-new-window"; inherit=true),
        ) == 2
        LibTmux.set_hook(
            server,
            pane_ref,
            "pane-mode-changed",
            "display-message noop";
            index=5,
        )
        @test only(LibTmux.get_hook(server, pane_ref, "pane-mode-changed")).index == 5
        @test_throws CommandError LibTmux.set_hook(
            server,
            pane_ref,
            "pane-mode-changed",
            "libtmux-no-such-command";
            index=5,
        )
        @test only(LibTmux.get_hook(server, pane_ref, "pane-mode-changed")).index == 5
        LibTmux.unset_hook(server, pane_ref, "pane-mode-changed"; index=5)
        @test isempty(LibTmux.get_hook(server, pane_ref, "pane-mode-changed"))
        LibTmux.set_hook(
            server,
            pane_ref,
            "pane-mode-changed",
            "display-message noop";
            index=5,
        )
        @test_throws CommandError LibTmux.set_hook(
            server,
            pane_ref,
            "pane-mode-changed",
            "libtmux-no-such-command",
        )
        @test isempty(LibTmux.get_hook(server, pane_ref, "pane-mode-changed"))
        LibTmux.unset_hook(server, pane_ref, "pane-mode-changed")
        @test LibTmux.get_hook(server, pane_ref, "pane-mode-changed") === nothing
        LibTmux.set_hook(
            server,
            window_ref,
            "window-layout-changed",
            "display-message noop";
            index=3,
        )
        @test only(LibTmux.get_hook(server, window_ref, "window-layout-changed")).index == 3
        @test_throws ArgumentError LibTmux.set_hook(
            server,
            session_ref,
            "pane-mode-changed",
            "display-message bad",
        )
        @test_throws ArgumentError LibTmux.set_hook(
            server,
            session_ref,
            "status-left",
            "display-message bad",
        )
    end
end

@testset "configuration rejects invalid arguments before I/O" begin
    server = Server(socket_name="unused", tmux="libtmux-no-such-executable")
    @test_throws ArgumentError LibTmux.get_option(server, :global, "status-left")
    @test_throws ArgumentError LibTmux.set_option(server, :server, "bad name", "value")
    @test_throws ArgumentError LibTmux.set_option(
        server,
        :global_session,
        "status-format",
        "value";
        index=-1,
    )
    @test_throws ArgumentError LibTmux.set_environment(
        server,
        :global_session,
        "NAME",
        "value",
    )
    @test_throws ArgumentError LibTmux.set_environment(server, :global, "NAME=bad", "value")
    @test_throws ArgumentError LibTmux.set_hook(
        server,
        :server,
        "after-new-window",
        "display-message bad",
    )
    @test_throws ArgumentError LibTmux.set_hook(
        server,
        :global_session,
        "after-new-window",
        "";
        index=1,
    )
end
