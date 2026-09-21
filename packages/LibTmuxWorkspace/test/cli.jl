using Test
using LibTmuxWorkspace
import JSON

@testset "workspace CLI protocol and installed launcher" begin
    @test isdefined(LibTmuxWorkspace, :main)
    @test isdefined(LibTmuxWorkspace, :install_cli)
    if isdefined(LibTmuxWorkspace, :main) && isdefined(LibTmuxWorkspace, :install_cli)
        mktempdir() do directory
            path = joinpath(directory, "workspace.yaml")
            write(path, "session_name: cli\nwindows:\n  - window_name: main\n")
            out, err = IOBuffer(), IOBuffer()
            @test main(["validate", path, "--output", "json"]; out, err) == 0
            payload = JSON.parse(String(take!(out)))
            @test payload["status"] == "valid"
            @test isempty(take!(err))
            @test main(["plan", path, "--output", "ndjson"]; out, err) == 0
            payloads = JSON.parse.(split(chomp(String(take!(out))), '\n'))
            @test last(payloads)["event"] == "result"
            @test last(payloads)["status"] == "planned"
            @test main(["load", path, "--output", "json"]; out, err) == 2
            @test JSON.parse(String(take!(out)))["status"] == "error"
            @test occursin("socket", String(take!(err)))
            write(path, "session_name: a\nsession_name: b\n")
            @test main(["validate", path, "--output", "json"]; out, err) == 2
            @test JSON.parse(String(take!(out)))["error"]["code"] == "duplicate"
            launcher = install_cli(
                joinpath(directory, "bin");
                julia_flags=["--compile=min", "-O0"],
            )
            result = read(Cmd([launcher, "--help"]), String)
            @test occursin("validate", result) && occursin("freeze", result)
            @test_throws ArgumentError install_cli(dirname(launcher))
            @test isfile(launcher)
        end
    end
end

include("cli_output.jl")
