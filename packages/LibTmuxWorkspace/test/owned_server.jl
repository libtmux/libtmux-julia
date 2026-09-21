# Consumer tests use the core's public ownership API and a minimal environment.
isdefined(@__MODULE__, :NamedTmux) ||
    include(joinpath(@__DIR__, "support", "named_tmux.jl"))

function with_workspace_server(f)
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict(
        "PATH" => get(ENV, "PATH", "/usr/local/bin:/usr/bin:/bin"),
        "SHELL" => "/bin/sh",
        "TERM" => "xterm-256color",
    )
    LibTmux.with_server(; tmux, env) do server
        f((
            tmux=server.tmux,
            socket=server.socket_path,
            directory=dirname(server.socket_path),
        ))
    end
end
