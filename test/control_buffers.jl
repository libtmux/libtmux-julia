@testset "control buffers preserve bytes and retire owned resources" begin
    admitted = hasmethod(load_buffer, Tuple{ControlConnection,Vector{UInt8}})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="control-buffer", command=["/bin/cat"])
            pane = only(panes(snapshot(server))).ref
            borrowed_name = " leading #{literal};雪"
            run_command(server, "set-buffer", "-b", borrowed_name, "keep")
            names() = run_command(server, "list-buffers", "-F", "#{buffer_name}").stdout
            before_names = names()
            withenv("TMPDIR"=>fixture.directory) do
                open_control(server, session) do connection
                    payload = repeat(collect(UInt8(0):UInt8(255)), 16)
                    buffer = load_buffer(connection, payload)
                    @test buffer.server == connection.identity
                    @test save_buffer(connection, buffer) == payload
                    @test save_buffer(server, buffer) == payload
                    @test_throws OutputLimitExceeded save_buffer(
                        connection,
                        buffer;
                        max_bytes=4,
                    )
                    @test delete_buffer(connection, buffer) isa ControlResult
                    @test_throws StaleReference save_buffer(connection, buffer)
                    @test save_buffer(
                        connection,
                        BufferRef(connection.identity, borrowed_name),
                    ) == codeunits("keep")
                    before = connection.submitted
                    @test_throws ArgumentError load_buffer(connection, UInt8[])
                    @test_throws InvalidUTF8Error paste_text(
                        connection,
                        pane,
                        String(UInt8[0xff]),
                    )
                    @test_throws UnsupportedCapability delete_buffer(
                        connection,
                        BufferRef(connection.identity, "bad\n%end 1 2 1"),
                    )
                    stale = BufferRef(
                        ServerIdentity(socket_path=fixture.socket, generation="stale"),
                        "borrowed",
                    )
                    @test_throws StaleReference save_buffer(connection, stale)
                    token = CancellationToken()
                    cancel!(token)
                    @test_throws RequestCancelled load_buffer(
                        connection,
                        payload;
                        cancel=token,
                    )
                    @test paste_bytes(connection, pane, UInt8[]) === nothing
                    @test connection.submitted == before

                    output = joinpath(fixture.directory, "pasted")
                    # A raw terminal that keeps exactly the pasted bytes and the next key.
                    raw_window = new_window(
                        connection,
                        session;
                        command=Main.StandIns.julia_argv(
                            """
                            signal(channel) = run(`\$(ARGS[1]) -S \$(ARGS[2]) wait-for -S \$channel`)
                            StandIns.raw_terminal()
                            signal("raw-ready")
                            run(pipeline(`dd bs=1 count=\$(ARGS[3]) of=\$(ARGS[4])`; stderr=devnull))
                            signal("raw-done")
                            StandIns.exec("cat")
                            """,
                            fixture.tmux,
                            fixture.socket,
                            length(payload) + 1,
                            output,
                        ),
                    )
                    raw_pane = PaneRef(
                        connection.identity,
                        only(read_formats(connection, raw_window, FormatField("pane_id"))).value,
                    )
                    run_command(server, "wait-for", "raw-ready"; timeout=30)
                    @test paste_bytes(connection, raw_pane, payload) isa ControlResult
                    send_keys(connection, raw_pane, "Z"; literal=true)
                    run_command(server, "wait-for", "raw-done"; timeout=30)
                    @test read(output) == vcat(payload, codeunits("Z"))
                    missing = PaneRef(connection.identity, "%999999")
                    @test_throws ControlCommandError paste_bytes(
                        connection,
                        missing,
                        UInt8[0x41],
                    )
                    @test names() == before_names

                    fail_after_spool(f, operation) = begin
                        LibTmux._with_control_spool(f, operation)
                        error("local spool retirement failed")
                    end
                    context = LibTmux._control_operation_context(connection)
                    @test_throws ErrorException LibTmux._control_load_buffer(
                        context,
                        payload;
                        _spool=fail_after_spool,
                    )
                    @test names() == before_names

                    run_command(
                        server,
                        "set-hook",
                        "-g",
                        "after-load-buffer",
                        "wait-for -S buffer-loaded; wait-for buffer-release",
                    )
                    active = CancellationToken()
                    task = Threads.@spawn try
                        load_buffer(connection, payload; cancel=active)
                    catch error
                        error
                    end
                    outcome = nothing
                    try
                        run_command(server, "wait-for", "buffer-loaded"; timeout=0.9)
                    finally
                        cancel!(active)
                        try
                            run_command(
                                server,
                                "wait-for",
                                "-S",
                                "buffer-release";
                                timeout=0.9,
                            )
                        finally
                            outcome = fetch(task)
                        end
                    end
                    @test outcome isa RequestCancelled
                    run_command(server, "set-hook", "-gu", "after-load-buffer")
                    @test names() == before_names
                    @test isopen(connection)
                    @test delete_buffer(
                        connection,
                        BufferRef(connection.identity, borrowed_name),
                    ) isa ControlResult
                    @test LibTmux._control_buffer_size(
                        something(connection.cleanup),
                        borrowed_name,
                    ) === nothing
                    @test isopen(connection)
                end
            end
            @test isempty(run_command(server, "list-clients").stdout)
            @test !any(
                name -> startswith(name, "libtmux-julia-buffer-"),
                readdir(fixture.directory),
            )
        end
    end
end
