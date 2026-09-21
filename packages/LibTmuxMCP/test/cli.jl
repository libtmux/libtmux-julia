using Test, LibTmuxMCP

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
        String[],
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
    @test occursin("--caller-pane", String(take!(out))) && isempty(take!(err))
    @test LibTmuxMCP.main(String[]; output=out, err) == 2
    @test isempty(take!(out)) && occursin("socket", String(take!(err)))
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
