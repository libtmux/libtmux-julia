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
                            ),
                            Dict("focus" => true),
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
        link = only(windowlinks(observed))
        @assert link.index == 0 && link.active
        editor = window(link)
        editor_panes = sort(collect(panes(editor)); by=p -> p.index)
        @assert [p.active for p in editor_panes] == [false, true]
        @assert all(p -> p.height == editor.height, editor_panes)
        @assert sum(p.width for p in editor_panes) + 1 == editor.width
        @assert abs(editor_panes[1].width - editor_panes[2].width) <= 1
        document = freeze(server, result.session)
        @assert length(validate(document).windows[1].panes) == 2
        frozen_editor = only(validate(document).windows)
        @assert frozen_editor.name == "editor" && frozen_editor.focus
        @assert [p.focus for p in frozen_editor.panes] == [false, true]
        @assert all(
            p -> p.start_directory == realpath(dirname(server.socket_path)),
            frozen_editor.panes,
        )
        @assert frozen_editor.layout ==
                only(read_formats(server, editor.ref, FormatField("window_layout"))).value
        println("Loaded 1 window and 2 panes; frozen names, layout, paths and focus")
        document
    end
    @assert !ispath(dirname(endpoint[].socket_path))
    frozen
end

main()
