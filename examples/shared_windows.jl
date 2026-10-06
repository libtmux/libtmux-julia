using LibTmux
import LibTmux.Filters as F

function main()
    snap = with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        dev = new_session(server; name="dev", command=["/bin/cat"])
        initial = snapshot(server)
        api = only(windows(initial)).ref
        rename_window(server, api, "api")
        split_window(server, only(panes(initial)).ref; command=["/bin/cat"])
        new_window(server, dev; name="build", command=["/bin/cat"])

        ops = new_session(server; name="ops", command=["/bin/cat"])
        captured = snapshot(server)
        in_ops = onlymatch(SessionWhere(name="ops"), sessions(captured))
        ops_windows = windows(in_ops)
        placeholder = only(ops_windows).ref
        source = onlymatch(
            WindowLinkWhere(window=WindowWhere(name="api")),
            windowlinks(captured),
        )
        link_window(server, WindowLinkRef(source), ops; index=4)
        kill_window(server, placeholder)
        snapshot(server)
    end

    @assert length(sessions(snap)) == 2
    @assert length(windows(snap)) == 2
    @assert length(windowlinks(snap)) == 3
    @assert length(panes(snap)) == 3
    @assert length(paneoccurrences(snap)) == 5

    # Captured relations remain usable after the owned daemon has stopped.
    has_api = SessionWhere(windows=F.AnyRelated(WindowWhere(name="api")))
    @assert count(has_api, sessions(snap)) == 2
    in_api = WindowWhere(name="api")
    selected = filter(PaneWhere(active=true, window=in_api), panes(snap))
    @assert length(selected) == 1
    active_api(p) = p.active && p.window.name == "api"
    api_pane = only(Iterators.filter(active_api, panes(snap)))
    @assert only(selected).ref == api_pane.ref
    println("2 sessions, 2 windows, 3 links, 3 panes, 5 occurrences")
    snap
end

main()
