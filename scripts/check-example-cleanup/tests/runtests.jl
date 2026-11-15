using Test
include(joinpath(@__DIR__, "..", "check-example-cleanup.jl"))
using .CheckExampleCleanup
const C = CheckExampleCleanup

const TMUX = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
const CHECKER = joinpath(@__DIR__, "..", "check-example-cleanup.jl")

@testset "example cleanup checker" begin
    @testset "process identity" begin
        C.identity_self_test()
    end

    mktempdir("/tmp"; prefix="ltj-cleanup-test-") do cwd
        @testset "a pure example starts no tmux and a failing one is reported" begin
            ok = C.run_example(`/bin/sh -c true`; tmux=TMUX, env=ENV, cwd)
            @test ok.daemons == 0 && ok.clients == 0 && ok.exit == 0
            failed = try
                C.run_example(`/bin/sh -c "exit 3"`; tmux=TMUX, env=ENV, cwd, diagnostics=false)
                nothing
            catch error
                error
            end
            @test failed isa ErrorException && occursin("example exited 3", failed.msg)
            declared = IOBuffer()
            @test run(
                pipeline(
                    ignorestatus(
                        `$(Base.julia_cmd()) --startup-file=no $CHECKER --tmux $TMUX --cwd $cwd -- /bin/sh -c true`,
                    );
                    stdout=declared,
                    stderr=devnull,
                ),
            ).exitcode != 0
        end

        @testset "an example sees no selector of the caller" begin
            decoys = Dict(
                "TMUX" => "/decoy-secret/sock,1,0",
                "TMUX_PANE" => "%decoy-secret",
                "LIBTMUX_SOCKET" => "decoy-secret",
                "LIBTMUX_SOCKET_PATH" => "/decoy-secret",
                "TMUX_TMPDIR" => "/decoy-secret",
            )
            probe = "test -z \"\${TMUX+x}\" && test -z \"\${TMUX_PANE+x}\" && test -z \"\${LIBTMUX_SOCKET+x}\" && test -z \"\${LIBTMUX_SOCKET_PATH+x}\" && test \"\$TMUX_TMPDIR\" = \"\$TMPDIR\""
            environment = merge(Dict{String,String}(ENV), decoys)
            @test C.run_example(`/bin/sh -c $probe`; tmux=TMUX, env=environment, cwd).exit ==
                  0
        end

        @testset "the audit notices a daemon that nobody closed" begin
            project = dirname(dirname(dirname(@__DIR__)))
            command = `$(Base.julia_cmd()) --startup-file=no --project=$project`
            @test C.negative_control(command; tmux=TMUX, cwd) === nothing
        end

        @testset "an example that closes its server passes with and without a fault" begin
            project = dirname(dirname(dirname(@__DIR__)))
            program = """
            using LibTmux
            with_server(; tmux=ENV["LIBTMUX_TEST_TMUX"]) do server
                new_session(server; name="audited", command=["/bin/cat"])
                snapshot(server)
            end
            """
            command = `$(Base.julia_cmd()) --startup-file=no --project=$project -e $program`
            ok = C.run_example(command; tmux=TMUX, env=ENV, cwd)
            @test ok.daemons == 1 && ok.exit == 0
            failed = C.run_example(command; tmux=TMUX, env=ENV, cwd, fault=true)
            @test failed.injected && failed.exit != 0
        end
    end
end
