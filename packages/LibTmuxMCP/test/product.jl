using Test, LibTmux, LibTmuxMCP

isdefined(@__MODULE__, :NamedTmux) ||
    include(joinpath(@__DIR__, "support", "named_tmux.jl"))

# Outer: starts an installed Julia process and a real Python protocol client.
@testset "installed MCP application uses public core and owns only its sessions" begin
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
        borrowed = new_session(server; name="borrowed", command=["/bin/cat"])
        pane = only(panes(snapshot(server))).ref
        mktempdir(; prefix="libtmux-julia-mcp-product-") do directory
            julia_flags =
                get(ENV, "LIBTMUX_TEST_MINIMAL_CHILD", "0") == "1" ?
                ["--compile=min", "-O0"] : String[]
            launcher = LibTmuxMCP.install_cli(directory; julia_flags)
            client = joinpath(@__DIR__, "product_client.py")
            for profile in ("2026-07-28", "2025-11-25")
                run(
                    Cmd([
                        "python3",
                        client,
                        launcher,
                        "--socket",
                        server.socket_path,
                        server.tmux,
                        string(pane.id),
                        profile,
                    ]),
                )
                @test only(sessions(snapshot(server))).ref == borrowed
                @test isempty(clients(snapshot(server)))
            end
        end
    end
end

@testset "installed MCP launcher uses a named owned socket" begin
    NamedTmux.with_named_tmux() do fixture
        borrowed = new_session(fixture.server; name="borrowed", command=["/bin/cat"])
        pane = only(panes(snapshot(fixture.server))).ref
        mktempdir(; prefix="libtmux-julia-mcp-named-product-") do directory
            julia_flags =
                get(ENV, "LIBTMUX_TEST_MINIMAL_CHILD", "0") == "1" ?
                ["--compile=min", "-O0"] : String[]
            launcher = LibTmuxMCP.install_cli(directory; julia_flags)
            client = joinpath(@__DIR__, "product_client.py")
            run(
                Cmd([
                    "python3",
                    client,
                    launcher,
                    "--socket-name",
                    fixture.socket_name,
                    fixture.tmux,
                    string(pane.id),
                    "2026-07-28",
                ]),
            )
            @test only(sessions(snapshot(fixture.server))).ref == borrowed
            @test isempty(clients(snapshot(fixture.server)))
        end
    end
end
