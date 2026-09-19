@testset "pane capture, keys and owned buffers" begin
    @test isdefined(LibTmux, :capture_bytes)
    @test isdefined(LibTmux, :paste_bytes)
    if isdefined(LibTmux, :capture_bytes) && isdefined(LibTmux, :paste_bytes)
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session_ref = LibTmux.new_session(server; name="io", command=["/bin/cat"])
            pane = only(panes(snapshot(server))).ref
            run_command(server, "set-buffer", "-b", "borrowed", "keep")
            buffer_names() = split(
                chomp(
                    decode_text(
                        run_command(server, "list-buffers", "-F", "#{buffer_name}").stdout,
                    ),
                ),
                '\n',
            )

            payload = repeat(UInt8[0x00, 0xff, 0x0a, 0x0d, 0x20], 4096)
            buffer = LibTmux.load_buffer(server, payload)
            @test buffer isa LibTmux.BufferRef
            @test LibTmux.save_buffer(server, buffer) == payload
            @test_throws OutputLimitExceeded LibTmux.save_buffer(
                server,
                buffer;
                max_bytes=32,
            )
            LibTmux.delete_buffer(server, buffer)
            @test buffer_names() == ["borrowed"]
            @test_throws CommandError LibTmux.save_buffer(server, buffer)
            @test_throws ArgumentError LibTmux.load_buffer(server, UInt8[])

            quote_shell(s) = "'" * replace(s, "'" => "'\\''") * "'"
            echo_file = joinpath(fixture.directory, "echo")
            literal = "Enter;#{pane_id}\$(printf should-not-run)"
            observed = literal * "!"
            signal = join(
                quote_shell.([
                    fixture.tmux,
                    "-S",
                    fixture.socket,
                    "wait-for",
                    "-S",
                    "echo-ready",
                ]),
                " ",
            )
            pipe = "dd bs=1 count=$(ncodeunits(observed)) of=$(quote_shell(echo_file)) 2>/dev/null; $signal"
            run_command(server, "pipe-pane", "-O", "-t", string(pane.id), pipe)
            LibTmux.send_keys(
                server,
                pane,
                "Enter;",
                "#{pane_id}\$(printf should-not-run)";
                literal=true,
            )
            LibTmux.send_keys(server, pane, "!"; literal=true)
            run_command(server, "wait-for", "echo-ready"; timeout=0.9)
            @test read(echo_file) == codeunits(observed)
            @test startswith(LibTmux.capture_pane(server, pane; end_line=0), observed)
            trimmed = LibTmux.capture_bytes(server, pane; end_line=0)
            padded = LibTmux.capture_bytes(server, pane; end_line=0, preserve_trailing=true)
            @test last(trimmed) == 0x0a && last(padded) == 0x0a
            @test length(padded) >= length(trimmed)
            @test decode_text(trimmed) == LibTmux.capture_pane(server, pane; end_line=0)
            @test_throws InvalidUTF8Error LibTmux.send_keys(
                server,
                pane,
                String(UInt8[0xff]);
                literal=true,
            )

            enter_file = joinpath(fixture.directory, "enter")
            enter_signal = join(
                quote_shell.([
                    fixture.tmux,
                    "-S",
                    fixture.socket,
                    "wait-for",
                    "-S",
                    "enter-ready",
                ]),
                " ",
            )
            run_command(
                server,
                "pipe-pane",
                "-O",
                "-t",
                string(pane.id),
                "dd bs=1 count=2 of=$(quote_shell(enter_file)) 2>/dev/null; $enter_signal",
            )
            LibTmux.send_keys(server, pane, "Enter")
            run_command(server, "wait-for", "enter-ready"; timeout=0.9)
            @test read(enter_file) == codeunits("\r\n")

            wrap_ref = LibTmux.new_window(server, session_ref; command=["/bin/cat"])
            wrap_window = only(filter(w -> w.ref == wrap_ref, windows(snapshot(server))))
            wrap_pane = only(panes(wrap_window)).ref
            wrapped = repeat("w", wrap_window.width + 5)
            wrap_file = joinpath(fixture.directory, "wrapped")
            wrap_signal = join(
                quote_shell.([
                    fixture.tmux,
                    "-S",
                    fixture.socket,
                    "wait-for",
                    "-S",
                    "wrap-ready",
                ]),
                " ",
            )
            run_command(
                server,
                "pipe-pane",
                "-O",
                "-t",
                string(wrap_pane.id),
                "dd bs=1 count=$(ncodeunits(wrapped)) of=$(quote_shell(wrap_file)) 2>/dev/null; $wrap_signal",
            )
            LibTmux.paste_text(server, wrap_pane, wrapped)
            run_command(server, "wait-for", "wrap-ready"; timeout=0.9)
            @test read(wrap_file) == codeunits(wrapped)
            @test !occursin(wrapped, LibTmux.capture_pane(server, wrap_pane))
            @test occursin(
                wrapped,
                LibTmux.capture_pane(server, wrap_pane; join_wrapped=true),
            )

            LibTmux.paste_text(server, pane, "buffer;#{pane_id}")
            @test buffer_names() == ["borrowed"]
            @test LibTmux.paste_bytes(server, pane, UInt8[]) === nothing
            @test_throws InvalidUTF8Error LibTmux.paste_text(
                server,
                pane,
                String(UInt8[0xff]),
            )
            missing = PaneRef(pane.server, "%999999")
            @test_throws CommandError LibTmux.paste_bytes(server, missing, UInt8[0x41])
            @test buffer_names() == ["borrowed"]
            token = CancellationToken()
            cancel!(token)
            @test_throws RequestCancelled LibTmux.paste_bytes(
                server,
                pane,
                UInt8[0x41];
                cancel=token,
            )
            @test buffer_names() == ["borrowed"]

            run_command(
                server,
                "set-hook",
                "-g",
                "after-load-buffer",
                "wait-for -S loaded; wait-for hold-loaded",
            )
            active = CancellationToken()
            task = Threads.@spawn try
                LibTmux.paste_bytes(server, pane, UInt8[0x42]; cancel=active)
            catch error
                error
            end
            outcome = nothing
            try
                run_command(server, "wait-for", "loaded"; timeout=0.9)
            finally
                cancel!(active)
                outcome = fetch(task)
            end
            @test outcome isa RequestCancelled
            @test buffer_names() == ["borrowed"]
            @test run_command(server, "save-buffer", "-b", "borrowed", "-").stdout ==
                  codeunits("keep")
            run_command(server, "set-hook", "-gu", "after-load-buffer")
        end
    end
end

@testset "capture decode failure preserves source bytes" begin
    @test isdefined(LibTmux, :CaptureDecodeError)
    if isdefined(LibTmux, :CaptureDecodeError)
        result = CommandResult(UInt8[0x41, 0xff, 0x20, 0x0a], UInt8[], 0, 0)
        failure = try
            LibTmux._decode_capture(result.stdout)
        catch error
            error
        end
        @test failure isa LibTmux.CaptureDecodeError
        @test failure.cause isa InvalidUTF8Error && failure.cause.offset == 2
        @test failure.bytes == result.stdout
        result.stdout[1] = 0x42
        @test failure.bytes == UInt8[0x41, 0xff, 0x20, 0x0a]
        @test LibTmux._decode_capture(failure.bytes; invalid=:replace) == "A\ufffd \n"
        @test_throws ArgumentError LibTmux._decode_capture(failure.bytes; invalid=:ignore)
    end
end
