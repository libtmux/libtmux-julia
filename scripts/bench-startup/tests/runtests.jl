using Test
import Base64
import JSON
import TOML
include(joinpath(@__DIR__, "..", "bench-startup.jl"))
using .BenchStartup
const B = BenchStartup
const OP = B.OwnedProcess

environment() = Dict{String,String}(ENV)
soon(seconds=10) = OP.monotonic() + seconds

# The child ignores SIGINT as it starts, because the disposition survives exec and
# the cancellation cannot arrive before the child has set up a handler.
function ignoring_sigint(action)
    previous = ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 2, Ptr{Cvoid}(1))
    try
        action()
    finally
        ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 2, previous)
    end
end

@testset "startup driver" begin
    @testset "observing a process" begin
        mktempdir(; prefix="ltj-startup-test-") do directory
            marker = joinpath(directory, "must-not-exist")
            literal = "; \$(touch $marker)"
            result = B.observe(
                ["/bin/sh", "-c", "printf '%s\\n' \"\$1\"", "sh", literal],
                environment(),
                soon(),
            )
            @test result["status"] == "pass" && String(result["stdout"]) == literal * "\n"
            @test result["direct_child_reaped"] && !ispath(marker)
            @test result["wait4_max_rss_bytes"] > 0 && result["spawner_max_rss_bytes"] > 0

            result =
                B.observe(["/bin/sh", "-c", "echo retained; exit 7"], environment(), soon())
            @test result["status"] == "failed" && result["exit_code"] == 7
            @test String(result["stdout"]) == "retained\n"

            result = ignoring_sigint() do
                B.observe(["sleep", "30"], environment(), soon(0.05); grace=0.05)
            end
            @test result["status"] == "deadline" && result["direct_child_reaped"]
            @test result["termination_signal"] == "SIGKILL"

            result = B.observe(
                ["/bin/sh", "-c", "head -c $(B.OUTPUT_LIMIT + 1) /dev/zero"],
                environment(),
                soon(),
            )
            @test result["status"] == "output_limit"
            @test length(result["stdout"]) == B.OUTPUT_LIMIT &&
                  result["direct_child_reaped"]

            result = B.observe([marker], environment(), OP.monotonic() - 1)
            @test result["status"] == "not_started_deadline"
            @test !result["direct_child_reaped"]

            result = B.observe(["/nonexistent/ltj-startup-test"], environment(), soon())
            @test result["status"] == "spawn_error" && result["error_type"] == "SystemError"

            # A descendant that keeps the pipe open neither stalls the run nor waits for an EOF the
            # run cannot own; it is killed with the group.
            result =
                B.observe(["/bin/sh", "-c", "sleep 30 & echo group"], environment(), soon())
            @test result["status"] == "pass" && String(result["stdout"]) == "group\n"
        end
    end

    @testset "decoding a sample" begin
        partial = Dict{String,Any}(
            "status" => "failed",
            "stdout" => Vector{UInt8}(
                "LTJ_STARTUP_PHASE\tpackage_load\tfailed\t7\t9\t11\nLTJ_STARTUP_TOML_BEGIN\nstatus = \"failed\"\nLTJ_STARTUP_TOML_END\n",
            ),
        )
        B.decode_sample!(partial, "core")
        @test partial["phase_records"][1]["elapsed_ns"] == 7
        @test partial["measurement"]["status"] == "failed"
        # A sample that passed but reports no measurement is not a measurement.
        silent = Dict{String,Any}("status" => "pass", "stdout" => UInt8[])
        @test B.decode_sample!(silent, "core")["status"] == "invalid_measurement"
        text = "LTJ_STARTUP_BASELINE\t1.13.1\t1\t5000\nName:\tjulia\nVmHWM:\t   100 kB\n"
        baseline = Dict{String,Any}("status" => "pass", "stdout" => Vector{UInt8}(text))
        B.decode_sample!(baseline, "baseline")
        @test baseline["status"] == "pass"
        # VmHWM, which a large spawner cannot inflate, replaces the inherited figure.
        @test baseline["baseline"]["max_rss_bytes"] == 100 * 1024
        garbled = Dict{String,Any}(
            "status" => "pass",
            "stdout" =>
                Vector{UInt8}("LTJ_STARTUP_PHASE\tx\tpass\tnot-a-number\t1\t1\n"),
        )
        @test_throws ArgumentError B.decode_sample!(garbled, "core")
    end

    @testset "options" begin
        defaults = B.options(String[])
        @test defaults.samples == 3 &&
              defaults.threads == 1 &&
              defaults.profiles == ["normal"]
        parsed = B.options([
            "--profiles",
            "normal,o0,minimal",
            "--samples",
            "2",
            "--threads",
            "4",
            "--seed",
            "9",
        ],)
        @test parsed.profiles == ["normal", "o0", "minimal"] && parsed.seed == 9
        for bad in (
            ["--samples", "0"],
            ["--samples", "11"],
            ["--samples", "x"],
            ["--threads", "2"],
            ["--profiles", "normal,normal"],
            ["--profiles", "turbo"],
            ["--budget", "541"],
            ["--process-budget", "0"],
            ["--budget", "NaN"],
            ["--unknown", "1"],
            ["--samples"],
            ["--samples", "1", "--samples", "2"],
        )
            @test_throws B.UsageError B.options(bad)
        end
        redirect_stderr(devnull) do
            @test B.main(["--samples", "0"]) == 2
        end
    end

    @testset "job order" begin
        jobs = B.job_order(["normal", "o0"], 2, 2026)
        @test sort(jobs) == sort([
            (i, p, k) for i = 1:2 for p in ("normal", "o0") for k in ("baseline", "core")
        ])
        @test jobs == B.job_order(["normal", "o0"], 2, 2026)
        @test jobs != B.job_order(["normal", "o0"], 2, 2027)
    end

    @testset "the child hashes the files the driver hashes" begin
        child = read(joinpath(B.ROOT, "benchmark", "startup.jl"), String)
        for name in keys(B.source_hashes())
            startswith(name, "src/") ||
                startswith(name, "ext/") ||
                @test occursin("\"$name\"", child)
        end
    end

    @testset "a run with stand-in julia and tmux" begin
        mktempdir(; prefix="ltj-startup-run-") do directory
            hashes = B.source_hashes()
            toml(core_hashes) = sprint(
                io -> TOML.print(
                    io,
                    Dict("status" => "pass", "source_sha256" => core_hashes),
                ),
            )
            function stand_in(name, core_hashes)
                script = joinpath(directory, name)
                body = toml(core_hashes)
                write(
                    script,
                    """
                    #!/bin/sh
                    for argument in "\$@"; do
                        case \$argument in
                        -e)
                            printf 'LTJ_STARTUP_BASELINE\\t1.13.1\\t1\\t4096\\n'
                            exit 0 ;;
                        esac
                    done
                    printf 'LTJ_STARTUP_PHASE\\tpackage_load\\tpass\\t5\\t6\\t7\\n'
                    printf 'LTJ_STARTUP_TOML_BEGIN\\n'
                    cat <<'END'
                    $body
                    END
                    printf 'LTJ_STARTUP_TOML_END\\n'
                    """,
                )
                chmod(script, 0o755)
                script
            end
            tmux = joinpath(directory, "tmux")
            write(tmux, "#!/bin/sh\necho 'tmux 3.7c'\n")
            chmod(tmux, 0o755)
            run_main(julia, output) = B.main([
                "--julia",
                julia,
                "--tmux",
                tmux,
                "--project",
                directory,
                "--samples",
                "2",
                "--profiles",
                "normal,o0",
                "--output",
                output,
            ])

            output = joinpath(directory, "report.json")
            redirect_stdout(devnull) do
                @test run_main(stand_in("julia-good", hashes), output) == 0
            end
            report = JSON.parsefile(output)
            @test report["status"] == "pass" && length(report["samples"]) == 8
            @test report["tmux_version"] == "tmux 3.7c"
            @test sort(unique(sample["profile"] for sample in report["samples"])) ==
                  ["normal", "o0"]
            core = first(sample for sample in report["samples"] if sample["kind"] == "core")
            @test core["measurement"]["status"] == "pass"
            @test occursin(
                "package_load",
                String(Base64.base64decode(core["stdout_base64"])),
            )
            @test haskey(core, "wait4_max_rss_bytes") && core["pipe_eof"]["stdout"] === true

            # Existing measurements are never replaced.
            @test_throws Base.IOError run_main(stand_in("julia-good", hashes), output)

            # A core process that hashed other sources is a stale measurement.
            stale = joinpath(directory, "stale.json")
            redirect_stdout(devnull) do
                @test run_main(stand_in("julia-stale", Dict("src/x.jl" => "0")), stale) == 1
            end
            @test JSON.parsefile(stale)["status"] == "failed"
            @test "stale_source" in
                  (sample["status"] for sample in JSON.parsefile(stale)["samples"])
        end
    end
end
