using Test, LibTmuxMCP

# The variables are cleared first, so a caller's own do not change what a case reads.
without_sockets(f) =
    withenv(f, "LIBTMUX_SOCKET" => nothing, "LIBTMUX_SOCKET_PATH" => nothing)

@testset "MCP command line is explicit and pure before startup" begin
    options = LibTmuxMCP._cli_options([
        "--socket-name",
        "absent",
        "--tmux",
        "missing-tmux",
        "--caller-pane",
        "%2",
        "--allow-pane",
        "%2",
        "--tool",
        "capture_pane",
    ])
    @test options.caller == "%2" && options.pane_ids == ["%2"]
    @test options.allowed_tools == ("capture_pane",)
    for args in (
        ["--socket", "a", "--socket-name", "b"],
        ["--socket", "a", "--caller-pane", "0"],
        ["--socket", "a", "--workers", "17"],
        ["--socket", "a", "--timeout", "NaN"],
        ["--socket", "a", "--tool", "raw_command"],
    )
        @test_throws ArgumentError LibTmuxMCP._cli_options(args)
    end
    out, err = IOBuffer(), IOBuffer()
    @test LibTmuxMCP.main(["--help"]; output=out, err) == 0
    help = String(take!(out))
    @test occursin("--caller-pane", help) && isempty(take!(err))
    @test occursin("tmux 3.3a or newer", help) && occursin("unsupported_tmux", help)
    @test occursin("LIBTMUX_SOCKET_PATH", help) && occursin("LIBTMUX_SOCKET", help)
    conflict = ["--socket", "a", "--socket-name", "b"]
    @test LibTmuxMCP.main(conflict; input=IOBuffer(), output=out, err) == 2
    @test isempty(take!(out)) && occursin("socket", String(take!(err)))
end

@testset "MCP names no socket unless a flag or a variable does" begin
    LibTmux = LibTmuxMCP.LibTmux
    without_sockets() do
        bare = LibTmuxMCP._cli_options(String[]).server
        @test bare.socket_path === nothing && bare.socket_name === nothing
        @test LibTmux._selector(bare) == String[]
        @test LibTmux._selector(LibTmuxMCP._cli_options(["--socket", "/tmp/m"]).server) ==
              ["-S", "/tmp/m"]
        @test LibTmux._selector(LibTmuxMCP._cli_options(["--socket-name", "m"]).server) ==
              ["-L", "m"]
    end
    withenv("LIBTMUX_SOCKET" => "from-env", "LIBTMUX_SOCKET_PATH" => nothing) do
        @test LibTmux._selector(LibTmuxMCP._cli_options(String[]).server) ==
              ["-L", "from-env"]
    end
    withenv("LIBTMUX_SOCKET" => nothing, "LIBTMUX_SOCKET_PATH" => "/tmp/from-env") do
        @test LibTmux._selector(LibTmuxMCP._cli_options(String[]).server) ==
              ["-S", "/tmp/from-env"]
    end
    withenv("LIBTMUX_SOCKET" => "from-env", "LIBTMUX_SOCKET_PATH" => "/tmp/from-env") do
        # The path wins, and a flag leaves both variables unread.
        @test LibTmux._selector(LibTmuxMCP._cli_options(String[]).server) ==
              ["-S", "/tmp/from-env"]
        @test LibTmux._selector(LibTmuxMCP._cli_options(["--socket-name", "m"]).server) ==
              ["-L", "m"]
        @test LibTmux._selector(LibTmuxMCP._cli_options(["--socket", "/tmp/m"]).server) ==
              ["-S", "/tmp/m"]
    end
end

@testset "MCP exits with status 2 for a variable it cannot use, naming it and not its value" begin
    out, err = IOBuffer(), IOBuffer()
    withenv("LIBTMUX_SOCKET" => "decoy-secret/name", "LIBTMUX_SOCKET_PATH" => nothing) do
        @test LibTmuxMCP.main(String[]; input=IOBuffer(), output=out, err) == 2
    end
    @test isempty(take!(out))
    message = String(take!(err))
    @test occursin("LIBTMUX_SOCKET", message) && !occursin("decoy-secret", message)
end

@testset "public MCP serve retires streams and application on EOF" begin
    app = Application(
        LibTmuxMCP.LibTmux.Server(socket_name="uncontacted", tmux="missing-tmux"),
    )
    input, output = IOBuffer(), IOBuffer()
    result = serve(app; input, output, workers=1, capacity=1)
    @test result.remaining == 0 && all(istaskdone, result.tasks)
    @test !isopen(app) && !isopen(input) && !isopen(output)
end

@testset "MCP launcher preserves argv and existing destinations" begin
    mktempdir(; prefix="libtmux-julia-mcp-launcher-") do directory
        project = joinpath(directory, "project 'quoted' \$literal")
        mkpath(project)
        write(joinpath(project, "Project.toml"), "[deps]\n")
        launcher =
            install_cli(directory; project, julia="/bin/echo", julia_flags=["--threads=1"])
        script = read(launcher, String)
        @test occursin("'\\''quoted'\\''", script)
        @test occursin("\"\$@\"", script)
        @test stat(launcher).mode & 0o111 != 0
        @test_throws ArgumentError install_cli(directory; project)
        @test read(launcher, String) == script
        marker = joinpath(directory, "must-not-exist")
        literal = "\$(touch '$marker')"
        echoed = read(Cmd([launcher, "--socket", literal]), String)
        @test occursin(literal, echoed) && !ispath(marker)
    end
end
