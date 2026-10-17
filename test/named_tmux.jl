isdefined(@__MODULE__, :NamedTmux) || include("support/named_tmux.jl")

# Immutable consumer staging exports each adapter's own test tree. Keep its
# local fixture copy aligned with this canonical core fixture.
@testset "named tmux fixture copies remain aligned" begin
    for file in ("named_tmux.jl", "hang_guard.jl")
        canonical = read(joinpath(@__DIR__, "support", file), String)
        for package in ("LibTmuxMCP", "LibTmuxWorkspace")
            copy = read(
                joinpath(@__DIR__, "..", "packages", package, "test", "support", file),
                String,
            )
            @test copy == canonical
        end
    end
end

@testset "named tmux startup reports a deadline" begin
    mktempdir(; prefix="libtmux-julia-named-deadline-") do directory
        process = run(`/bin/sleep 5`; wait=false)
        fixture = NamedTmux.Fixture(
            Server(socket_name="s", tmux="tmux"),
            "tmux",
            "s",
            joinpath(directory, "missing"),
            directory,
            Dict{String,String}(),
            process,
        )
        failure = nothing
        try
            NamedTmux.await_ready(fixture, NamedTmux.FolderMonitor(directory); budget=0.9)
        catch error
            failure = error
        finally
            NamedTmux.stop!(process)
        end
        @test failure isa ErrorException
        @test occursin("startup exceeded its hang guard", sprint(showerror, failure))
    end
end

@testset "named tmux startup finds a socket the watch never reports" begin
    # A deaf monitor models macOS, whose directory watch never reports a Unix
    # socket; readiness must still be observed by the poll.
    for deaf in (true, false)
        mktempdir(; prefix="libtmux-julia-named-lost-") do directory
            quiet = mkpath(joinpath(directory, "quiet"))
            socket = joinpath(directory, "socket")
            watched = deaf ? quiet : directory
            process = run(`/bin/sh -c "sleep 0.3; : > $socket; sleep 5"`; wait=false)
            fixture = NamedTmux.Fixture(
                Server(socket_name="s", tmux="tmux"),
                "tmux",
                "s",
                socket,
                directory,
                Dict{String,String}(),
                process,
            )
            try
                @test NamedTmux.await_ready(fixture, NamedTmux.FolderMonitor(watched)) ===
                      nothing
            finally
                NamedTmux.stop!(process)
            end
        end
    end
end

@testset "named tmux fixture ignores a long inherited temporary directory" begin
    mktempdir(; prefix="libtmux-julia-named-parent-") do parent
        inherited = joinpath(parent, repeat("x", 80))
        mkpath(inherited)
        withenv("TMPDIR" => inherited) do
            NamedTmux.with_named_tmux() do fixture
                @test !startswith(realpath(fixture.directory), realpath(inherited))
                @test ncodeunits(fixture.socket_path) < 104
                session = new_session(fixture.server; name="named", command=["/bin/cat"])
                @test only(sessions(snapshot(fixture.server))).ref == session
            end
        end
    end
end
