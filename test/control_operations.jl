@testset "typed control creation and keys" begin
    admitted =
        hasmethod(new_window, Tuple{ControlConnection,SessionRef}) &&
        hasmethod(split_window, Tuple{ControlConnection,PaneRef}) &&
        hasmethod(send_keys, Tuple{ControlConnection,PaneRef,String})
    @test admitted
    if admitted
        with_tmux() do fixture
            server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
            session = new_session(server; name="typed-control", command=["/bin/cat"])
            open_control(server, session) do connection
                pane = only(panes(snapshot(connection))).ref
                count_before = connection.submitted
                @test_throws UnsupportedCapability new_window(
                    connection,
                    session;
                    name="bad\n%end 1 2 1",
                )
                @test_throws InvalidUTF8Error new_window(
                    connection,
                    session;
                    name=String(UInt8[0xff]),
                )
                @test_throws InvalidUTF8Error send_keys(
                    connection,
                    pane,
                    String(UInt8[0xff]),
                )
                @test connection.submitted == count_before
                cancelled = CancellationToken()
                cancel!(cancelled)
                @test_throws RequestCancelled split_window(
                    connection,
                    pane;
                    cancel=cancelled,
                )
                @test connection.submitted == count_before
                wrong = PaneRef(
                    ServerIdentity(socket_path=fixture.socket*"-other", generation="1"),
                    pane.id,
                )
                stale = PaneRef(
                    ServerIdentity(socket_path=fixture.socket, generation="stale"),
                    pane.id,
                )
                @test_throws CrossServerReference send_keys(connection, wrong, "x")
                @test_throws StaleReference split_window(connection, stale)
                @test connection.submitted == count_before
                @test_throws ControlCommandError send_keys(
                    connection,
                    PaneRef(pane.server, "%999999"),
                    "x",
                )
                @test_throws ControlCommandError split_window(
                    connection,
                    PaneRef(pane.server, "%999999"),
                )
                @test_throws ControlCommandError new_window(
                    connection,
                    SessionRef(session.server, "\$999999"),
                )
                @test isopen(connection)

                physical = joinpath(fixture.directory, "physical")
                alias = joinpath(fixture.directory, "alias")
                mkdir(physical)
                symlink(physical, alias)
                cwd = joinpath(alias, "cwd;\t\n#literal")
                mkdir(cwd)
                path = joinpath(fixture.directory, "creation-bytes")
                signal = control_signal(connection)
                script =
                    raw"""printf '%s\000' "$VALUE" "$PWD" "$1" > "$2"; "$3" -S "$4" wait-for -S "$5"; exec /bin/cat"""
                argument = "argv;#{literal}\nend;"
                value = "env;#{literal}\nend;"
                created = new_window(
                    connection,
                    session;
                    name="window;#{literal};雪;",
                    index=9,
                    start_directory=cwd,
                    environment=Dict("VALUE"=>value),
                    command=[
                        "/bin/sh",
                        "-c",
                        script,
                        "sh",
                        argument,
                        path,
                        fixture.tmux,
                        fixture.socket,
                        signal.name,
                    ],
                )
                wait(signal)
                @test created isa WindowRef && created.server == connection.identity
                observed = split(read(path, String), '\0')
                @test observed[[1, 3, 4]] == [value, argument, ""]
                @test realpath(observed[2]) == realpath(cwd)
                graph = snapshot(connection)
                window = only(filter(w -> w.ref == created, windows(graph)))
                @test window.name == "window;#{literal};雪;"
                @test only(
                    filter(l -> LibTmux.window(l).ref == created, windowlinks(graph)),
                ).index == 9
                @test_throws ControlCommandError new_window(connection, session; index=9)
                @test isopen(connection)
                extra = split_window(
                    connection,
                    only(panes(window)).ref;
                    direction=:right,
                    command=["/bin/cat"],
                )
                @test extra isa PaneRef && extra.server == connection.identity
                @test length(panes(snapshot(connection))) == 3

                signal = control_signal(connection)
                path = joinpath(fixture.directory, "key-bytes")
                script =
                    raw"""IFS= read -r line; printf '%s' "$line" > "$1"; "$2" -S "$3" wait-for -S "$4"; exec /bin/cat"""
                receiver = split_window(
                    connection,
                    pane;
                    command=[
                        "/bin/sh",
                        "-c",
                        script,
                        "sh",
                        path,
                        fixture.tmux,
                        fixture.socket,
                        signal.name,
                    ],
                )
                text = "literal;#{value};雪;"
                @test send_keys(connection, receiver, text; literal=true) isa ControlResult
                @test !isfile(path)
                @test send_keys(connection, receiver, "Enter") isa ControlResult
                wait(signal)
                @test read(path, String) == text
                @test isopen(connection)
            end
            @test isempty(run_command(server, "list-clients").stdout)
        end
    end
end

@testset "control creation reply evidence" begin
    if isdefined(LibTmux, :_control_creation_reference)
        identity = ServerIdentity(socket_path="/owned/s", generation="100:200")
        for payload in ("malformed\n", "LIBTMUX\t101\t200\t/owned/s\t@1\n")
            result = ControlResult(collect(codeunits(payload)), false, 1, 2, 1)
            error = try
                LibTmux._control_creation_reference(WindowRef, result, identity)
            catch error
                error
            end
            @test error isa CreationResponseError && error.sent
            @test error.result === result
        end
    end
end
