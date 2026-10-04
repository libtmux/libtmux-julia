using LibTmux

environment = Dict(
    "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
    "TERM" => "xterm-256color",
    "SHELL" => "/bin/sh",
)

with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
    created = new_session(server; name="stream", command=["/bin/cat"])
    pane = only(panes(snapshot(server))).ref
    open_control(server, created) do connection
        observe_output(connection, pane) do stream
            baseline = capture_baseline(stream)
            @assert baseline.continuity === :reset
            message = "observed terminal echo: λ"
            send_keys(server, pane, message; literal=true)
            result = wait_for(stream; timeout=0.9) do observed
                observed.text == message
            end
            @assert result.text == message
            @assert result.source === :output
            @assert observation_cursor(stream).pane == pane.id
            println(result.text)
        end
    end
end
