using LibTmux

function main()
    endpoint = Ref{Server}()
    result = with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        endpoint[] = server
        new_session(server; name="example", command=["/bin/cat"])
        snap = snapshot(server)
        pane = only(panes(snap))
        screen = capture_pane(server, pane.ref)
        @assert isempty(strip(screen))
        @assert only(sessions(snap)).name == "example"
        println("Captured ", string(pane.id), ": ", ncodeunits(screen), " screen bytes")
        (; snap, screen)
    end
    @assert !ispath(dirname(endpoint[].socket_path))
    @assert length(panes(result.snap)) == 1
    result
end

main()
