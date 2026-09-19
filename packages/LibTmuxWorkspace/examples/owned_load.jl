using LibTmux, LibTmuxWorkspace

function main()
    endpoint = Ref{Server}()
    frozen = with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        endpoint[] = server
        config = validate(
            Dict(
                "session_name" => "workspace-example",
                "options" => Dict("default-shell" => "/bin/sh"),
                "windows" => [
                    Dict(
                        "window_name" => "editor",
                        "window_index" => 0,
                        "layout" => "even-horizontal",
                        "focus" => true,
                        "panes" => [
                            Dict(
                                "shell_command" => [
                                    Dict("cmd" => "printf ready", "enter" => false),
                                ],
                                "focus" => true,
                            ),
                            nothing,
                        ],
                    ),
                ],
            ),
        )
        prepared = plan(expand(config; base_directory=dirname(server.socket_path)))
        result = apply(server, prepared; rollback=:created)
        @assert result.status == :complete
        observed = snapshot(server)
        @assert length(panes(observed)) == 2
        @assert only(windowlinks(observed)).index == 0
        document = freeze(server, result.session)
        @assert length(validate(document).windows[1].panes) == 2
        println("Loaded 1 window and 2 panes; frozen names, layout, paths and focus")
        document
    end
    @assert !ispath(dirname(endpoint[].socket_path))
    frozen
end

main()
