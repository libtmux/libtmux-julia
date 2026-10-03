using LibTmux

function capture_named_pane(server; session_name, pane_title)
    matches = filter(SessionWhere(name = session_name), sessions(snapshot(server)))
    length(matches) == 1 || throw(ArgumentError("expected one named session"))
    scoped = snapshot(server, only(matches).ref)
    candidates = [pane for window in windows(scoped) for pane in panes(window)]
    matches = filter(PaneWhere(title = pane_title), candidates)
    length(matches) == 1 || throw(
        ArgumentError("expected one pane titled $pane_title; found $(length(matches))"),
    )
    pane = only(matches).ref
    (; pane, screen = capture_pane(server, pane))
end

function main()
    endpoint = Ref{Server}()
    result = with_server(; tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        endpoint[] = server
        new_session(server; name = "example", command = ["/bin/cat"])
        snap = snapshot(server)
        pane = only(panes(snap))
        screen = capture_pane(server, pane.ref)
        @assert isempty(strip(screen))
        @assert only(sessions(snap)).name == "example"
        set_title(server, pane.ref, "chosen")
        borrowed = Server(socket_path = server.socket_path, tmux = server.tmux)
        selected = capture_named_pane(
            borrowed;
            session_name = "example",
            pane_title = "chosen",
        )
        @assert selected.pane == pane.ref && isempty(strip(selected.screen))
        sibling = split_window(server, pane.ref; command = ["/bin/cat"])
        set_title(server, sibling, "chosen")
        for title in ("missing", "chosen")
            rejected = try
                capture_named_pane(borrowed; session_name = "example", pane_title = title)
                false
            catch error
                error isa ArgumentError || rethrow()
                true
            end
            @assert rejected
        end
        @assert length(panes(snapshot(borrowed))) == 2
        println("Captured ", string(pane.id), ": ", ncodeunits(screen), " screen bytes")
        (; snap, screen)
    end
    @assert !ispath(dirname(endpoint[].socket_path))
    @assert length(panes(result.snap)) == 1
    result
end

main()
