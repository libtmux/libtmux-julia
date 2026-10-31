using Test
isdefined(@__MODULE__, :OwnedTmux) || include("support/owned_tmux.jl")

@testset "a client that names no socket looks under the sandbox" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    @test isempty(Main.TestSandbox.violations(ENV))
    default = "tmux-$(Libc.getuid())"
    # Runs a client with no -S or -L; it fails to connect, and the message names
    # the socket it looked for.
    function bare_client(tmux_tmpdir)
        env = Dict{String,String}(string(k) => string(v) for (k, v) in ENV)
        env["TMUX_TMPDIR"] = tmux_tmpdir
        diagnostic = IOBuffer()
        command = setenv(`$tmux -N list-sessions`, env)
        process = run(pipeline(ignorestatus(command); stdout=devnull, stderr=diagnostic))
        @test process.exitcode != 0
        String(take!(diagnostic))
    end
    sandbox = ENV["TMUX_TMPDIR"]
    @test occursin(joinpath(sandbox, default, "default"), bare_client(sandbox))
    mktempdir(sandbox; prefix="d-") do other
        diagnostic = bare_client(other)
        @test occursin(joinpath(other, default, "default"), diagnostic)
        @test !occursin(joinpath(sandbox, default, "default"), diagnostic)
    end
end

# A fixture's environment is replaced, so a client started with it sees only
# that environment. Without TMUX_TMPDIR in it such a client looked in the
# developer's own socket directory under /tmp. The client runs only once the
# environment names the sandbox, so a regression fails before it can connect to
# the default socket.
@testset "a client under a replaced environment looks under the sandbox" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    default = "tmux-$(Libc.getuid())"
    sandbox_socket = joinpath(ENV["TMUX_TMPDIR"], default, "default")
    real_socket = joinpath("/tmp", default, "default")
    OwnedTmux.with_tmux() do fixture
        keeps_sandbox = get(fixture.env, "TMUX_TMPDIR", nothing) == ENV["TMUX_TMPDIR"]
        @test keeps_sandbox
        if keeps_sandbox
            diagnostic = IOBuffer()
            command = setenv(`$tmux -N list-sessions`, fixture.env)
            process =
                run(pipeline(ignorestatus(command); stdout=devnull, stderr=diagnostic))
            text = String(take!(diagnostic))
            looked_in_sandbox = occursin(sandbox_socket, text)
            looked_in_real_default = occursin(real_socket, text)
            @test process.exitcode != 0
            @test looked_in_sandbox
            @test !looked_in_real_default
        end
    end
end
