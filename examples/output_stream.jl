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
            bytes = UInt8[]
            started = time_ns()
            while length(bytes) < ncodeunits(message)
                remaining = 0.9 - (time_ns() - started) / 1e9
                remaining > 0 || error("terminal echo deadline expired")
                append!(bytes, take!(stream; timeout=remaining).bytes)
            end
            @assert bytes == codeunits(message)
            @assert observation_cursor(stream).pane == pane.id
            println(decode_text(bytes))
        end
    end
end
