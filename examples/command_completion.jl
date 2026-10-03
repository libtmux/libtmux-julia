using LibTmux, UUIDs

environment = Dict(
    "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
    "TERM"=>"xterm-256color",
    "SHELL"=>"/bin/sh",
)

with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
    marker = "completion-" * string(uuid4())
    command = [
        "/bin/sh",
        "-c",
        "IFS= read -r line; /bin/sh -c \"\$line\"; status=\$?; printf '\\n%s:%d\\n' \"\$1\" \"\$status\"; exec /bin/cat",
        "sh",
        marker,
    ]
    created = new_session(server; name="completion", command)
    pane = only(panes(snapshot(server))).ref
    open_control(server, created) do connection
        observe_output(connection, pane) do stream
            input = "printf 'payload\\n'; false"
            @assert !occursin(marker, input)
            send_keys(connection, pane, input; literal=true)
            send_keys(connection, pane, "Enter")
            result = wait_for_text(stream, marker * ":1"; timeout=0.9)
            @assert result.source === :output
            @assert occursin("payload", result.text)
            println("Authored wrapper reports exit status 1")
        end
    end
end
