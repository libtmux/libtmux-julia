@testset "typed format observations" begin
    with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        path =
            joinpath(fixture.directory, "é 雪\tline\nlibtmux_invented_hint=\n#{pane_id}\\;")
        mkpath(path)
        session_ref =
            new_session(server; name="formats", command=["/bin/cat"], start_directory=path)
        captured = snapshot(server)
        pane_ref = only(panes(captured)).ref
        window_ref = only(windows(captured)).ref
        fields = (
            LibTmux.FormatField("pane_current_path"),
            LibTmux.FormatField("pane_width", Int),
            LibTmux.FormatField("pane_active", Bool),
            LibTmux.FormatField("pane_dead", Bool),
            LibTmux.FormatField("version"),
        )
        observed = LibTmux.read_formats(server, pane_ref, fields...)
        @test observed[1].raw == path && observed[1].value == path
        @test observed[2].value isa Int && observed[2].value > 0
        @test observed[3].value === true
        @test observed[4].value === false
        @test all(o -> o.availability === :present, observed)
        other = split_window(server, pane_ref; command=["/bin/cat"])
        for target in (pane_ref, other)
            @test only(
                LibTmux.read_formats(server, target, LibTmux.FormatField("pane_id")),
            ).value == string(target.id)
        end
        @test only(
            LibTmux.read_formats(server, session_ref, LibTmux.FormatField("session_id")),
        ).value == string(session_ref.id)
        @test only(
            LibTmux.read_formats(server, window_ref, [LibTmux.FormatField("window_id")]),
        ).value == string(window_ref.id)
        for T in (String, Int, Bool)
            unknown = only(
                LibTmux.read_formats(
                    server,
                    pane_ref,
                    LibTmux.FormatField("libtmux_unknown_field", T),
                ),
            )
            @test unknown.raw == "" && unknown.availability === :unverified
            @test unknown.value === (T === String ? "" : nothing)
        end
        run_command(server, "select-pane", "-t", string(pane_ref.id), "-T", "")
        empty =
            only(LibTmux.read_formats(server, pane_ref, LibTmux.FormatField("pane_title")))
        @test empty.raw == "" && empty.availability === :unverified
        failure = try
            LibTmux.read_formats(server, pane_ref, LibTmux.FormatField("session_name", Int))
        catch error
            error
        end
        @test failure isa LibTmux.FormatValueError
        @test failure.raw == "formats" && failure.result.exitcode == 0

        hints = LibTmux.format_hints(server, pane_ref)
        @test "pane_title" in hints.candidate_names
        @test "libtmux_invented_hint" in hints.candidate_names
        @test hints.availability === :unverified && !hints.complete
        @test hints.result isa CommandResult && hints.result.exitcode == 0
        @test occursin(path, decode_text(hints.result.stdout))
        literal = "é\tline\n"
        raw = LibTmux.render_format(
            server,
            pane_ref,
            LibTmux.RawFormat("#{pane_id}:" * literal * ";"),
        )
        @test raw.stdout == codeunits(string(pane_ref.id) * ":" * literal * ";\n")
        @test raw isa CommandResult

        # Missing exact targets must never use the active pane's format context.
        for missing in (
            SessionRef(session_ref.server, SessionID(raw"$999999")),
            WindowRef(session_ref.server, WindowID("@999999")),
            PaneRef(session_ref.server, PaneID("%999999")),
        )
            @test_throws CommandError LibTmux.read_formats(
                server,
                missing,
                LibTmux.FormatField("pane_id"),
            )
            @test_throws CommandError LibTmux.render_format(
                server,
                missing,
                LibTmux.RawFormat("#{pane_id}"),
            )
            @test_throws CommandError LibTmux.format_hints(server, missing)
        end
        context = LibTmux._target_context(server, pane_ref)
        @test_throws CommandError LibTmux._configuration_parent(
            context,
            PaneRef(session_ref.server, PaneID("%999999")),
        )
    end
end

@testset "format validation before I/O" begin
    @test_throws ArgumentError LibTmux.FormatField("#{pane_id}")
    @test_throws ArgumentError LibTmux.FormatField("pane_id; display-message bad")
    @test_throws ArgumentError LibTmux.FormatField("pane_width", Float64)
    @test_throws ArgumentError LibTmux.RawFormat("bad\0format")
    server = Server(socket_name="unused", tmux="libtmux-no-such-executable")
    @test_throws ArgumentError LibTmux.read_formats(
        server,
        nothing,
        LibTmux.FormatField("pid"),
    )
    @test_throws ArgumentError LibTmux.format_hints(server, nothing)
    @test_throws ArgumentError LibTmux.render_format(
        server,
        nothing,
        LibTmux.RawFormat("#{pid}"),
    )
end
