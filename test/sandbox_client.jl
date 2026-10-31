using Test

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
