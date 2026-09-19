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
        placeholder =
            only(windows(onlymatch(SessionWhere(name="ops"), sessions(captured)))).ref
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
    selected = filter(PaneWhere(active=true, window=WindowWhere(name="api")), panes(snap))
    @assert length(selected) == 1
    @assert only(selected).ref ==
            only(Iterators.filter(p -> p.active && p.window.name == "api", panes(snap))).ref
    println("2 sessions, 2 windows, 3 links, 3 panes, 5 occurrences")
    snap
end

main()
