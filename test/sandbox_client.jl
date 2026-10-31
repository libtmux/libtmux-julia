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

# The cleanup checker runs examples that start tmux. It must hide the caller's
# selectors from them and give them a socket directory of their own.
@testset "the example cleanup checker hides every selector from an example" begin
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    checker = joinpath(dirname(@__DIR__), "dev", "check-example-cleanup.py")
    python = Sys.which("python3")
    decoys = Dict(
        "TMUX" => "/decoy-secret/sock,1,0",
        "TMUX_PANE" => "%decoy-secret",
        "LIBTMUX_SOCKET" => "decoy-secret",
        "LIBTMUX_SOCKET_PATH" => "/decoy-secret",
        "LIBTMUX_SOCKET_FUTURE" => "decoy-secret",
        "TMUX_TMPDIR" => "/decoy-secret",
    )
    environment =
        merge(Dict{String,String}(string(k) => string(v) for (k, v) in ENV), decoys)
    probe = join(
        [
            "test -z \"\${$name+x}\"" for
            name in ("TMUX", "TMUX_PANE", "LIBTMUX_SOCKET", "LIBTMUX_SOCKET_PATH")
        ],
        " && ",
    )
    script = "$probe && test -z \"\${LIBTMUX_SOCKET_FUTURE+x}\" && test \"\$TMUX_TMPDIR\" = \"\$TMPDIR\""
    @test python !== nothing
    if python !== nothing
        mktempdir(ENV["TMUX_TMPDIR"]; prefix="c-") do directory
            # The probe fails in the decoy environment, so a pass means the checker removed them.
            control = run(
                pipeline(
                    ignorestatus(setenv(`/bin/sh -c $script`, environment));
                    stdout=devnull,
                    stderr=devnull,
                ),
            )
            @test control.exitcode != 0
            out, err = IOBuffer(), IOBuffer()
            checked = run(
                pipeline(
                    ignorestatus(
                        setenv(
                            `$python $checker --pure --tmux $tmux --cwd $directory -- /bin/sh -c $script`,
                            environment,
                        ),
                    );
                    stdout=out,
                    stderr=err,
                ),
            )
            @test checked.exitcode == 0
            @test occursin("PASS example success", String(take!(out)))
            @test !occursin("decoy-secret", String(take!(err)))
        end
    end
end
