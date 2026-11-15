# Exercise native Julia progress, failure continuation and completion evidence.
#
# usage: julia --project=. dev/test-progress.jl [JULIA]
#
# Runs dev/test-diagnostics.jl under child Julia processes over small test files
# and checks the live progress lines, assertion details, the files that follow a
# failure, the completion receipt and the exits that leave no receipt. JULIA names
# the executable the children use; the default is the running one.
# The matrix runs it in its quality tier.

using Test
using TOML

const ROOT = dirname(@__DIR__)
const HELPER = joinpath(@__DIR__, "test-diagnostics.jl")
const PROGRAM = """
include(ARGS[1])
using Test, Random
Random.seed!(23)
original = copy(Random.default_rng())
for file in ARGS[2:end]
    include_test_file(Main, file)
end
@assert rand(original) == rand(Random.default_rng())
finish_test_diagnostics()
"""

"A child test run with its input, its merged output so far, and a way to wait for text."
mutable struct Child
    process::Base.Process
    input::IO
    output::Vector{UInt8}
    changed::Threads.Condition
    reader::Task
end

function start(julia, directory, files)
    environment =
        Dict(name => value for (name, value) in ENV if !startswith(name, "LIBTMUX_CI_"))
    merge!(
        environment,
        Dict(
            "JULIA_TEST_VERBOSE" => "true",
            "LIBTMUX_TEST_INVOCATION" => basename(directory),
            "LIBTMUX_TEST_COMPLETION" => joinpath(directory, "complete.toml"),
        ),
    )
    command = setenv(
        `$julia --startup-file=no --compile=min -O0 --project=$ROOT -e $PROGRAM $HELPER $files`,
        environment,
    )
    input, output = Pipe(), Pipe()
    process = run(pipeline(command; stdin=input, stdout=output, stderr=output); wait=false)
    close(input.out)
    close(output.in)
    changed = Threads.Condition()
    bytes = UInt8[]
    reader = Threads.@spawn while !eof(output.out)
        chunk = readavailable(output.out)
        lock(changed) do
            append!(bytes, chunk)
            notify(changed)
        end
    end
    Child(process, input.in, bytes, changed, reader)
end

text(child::Child) = lock(() -> String(copy(child.output)), child.changed)

"Wait until the output holds `needle`, or fail after `seconds`."
function await(child::Child, needle; seconds=20.0)
    timer = Timer(seconds) do _
        lock(() -> notify(child.changed), child.changed)
    end
    deadline = time() + seconds
    try
        lock(child.changed) do
            while !occursin(needle, String(copy(child.output)))
                time() < deadline || error("timed out waiting for $needle:\n$(text(child))")
                process_running(child.process) || break
                wait(child.changed)
            end
        end
    finally
        close(timer)
    end
    occursin(needle, text(child)) ||
        error("child ended before printing $needle:\n$(text(child))")
end

"Wait for the child to exit and return everything it printed."
function finish(child::Child; seconds=20.0)
    timer = Timer(
        _ -> process_running(child.process) && kill(child.process, Base.SIGKILL),
        seconds,
    )
    try
        wait(child.process)
        wait(child.reader)
    finally
        close(timer)
    end
    text(child)
end

retire(child::Child) = process_running(child.process) && kill(child.process, Base.SIGKILL)

function fixture(directory, name, source)
    path = joinpath(directory, name)
    write(path, source)
    path
end

function main(julia)
    mktempdir(; prefix="ltj-progress-") do directory
        @testset "native live progress, details, continuation and incomplete exits" begin
            passing = fixture(
                directory,
                "passing.jl",
                """using Test
@testset "outer" begin
    @test true
    @testset "nested live" begin
        readline(stdin)
        @test 2 == 2
    end
    @test_skip false
end
""",
            )
            child = start(julia, directory, [passing])
            try
                await(child, "Starting testset: nested live")
                @test process_running(child.process)
                @test occursin("FILE START", text(child))
                write(child.input, "\n")
                close(child.input)
                output = finish(child)
                @test success(child.process)
                @test occursin("Broken", output) &&
                      occursin("Finished testset: nested live", output)
                receipt = TOML.parsefile(joinpath(directory, "complete.toml"))
                @test receipt["invocation"] == basename(directory) &&
                      receipt["status"] == "PASS"
                @test receipt["files"][1]["outcome"] == "RETURNED"
            finally
                retire(child)
            end

            rm(joinpath(directory, "complete.toml"))
            failing = fixture(
                directory,
                "failing.jl",
                "using Test\n@testset \"intentional failure\" begin\n    @test 1 == 2\nend\n",
            )
            following = fixture(
                directory,
                "following.jl",
                "using Test\n@testset \"following file\" begin\n    @test true\nend\nprintln(\"FOLLOWING_REACHED\")\n",
            )
            child = start(julia, directory, [failing, following])
            try
                close(child.input)
                output = finish(child)
                @test !success(child.process)
                @test occursin("FOLLOWING_REACHED", output)
                @test occursin("failing.jl:3", output) && occursin("1 == 2", output)
                receipt = TOML.parsefile(joinpath(directory, "complete.toml"))
                @test receipt["status"] == "FAIL"
                @test [row["outcome"] for row in receipt["files"]] == ["ABORTED", "RETURNED"]
            finally
                retire(child)
            end

            rm(joinpath(directory, "complete.toml"))
            interrupted = fixture(
                directory,
                "interrupted.jl",
                "using Test\n@testset \"outer\" begin\n    @testset \"nested interruption\" begin\n        throw(InterruptException())\n    end\nend\n",
            )
            child = start(julia, directory, [interrupted, following])
            try
                close(child.input)
                output = finish(child)
                @test !success(child.process)
                @test !occursin("FOLLOWING_REACHED", output)
                @test occursin("INTERRUPTED", output)
                @test !isfile(joinpath(directory, "complete.toml"))
            finally
                retire(child)
            end

            premature = fixture(directory, "premature.jl", "exit(0)\n")
            child = start(julia, directory, [premature])
            try
                close(child.input)
                finish(child)
                @test success(child.process)
                @test !isfile(joinpath(directory, "complete.toml"))
            finally
                retire(child)
            end
        end
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) &&
    main(isempty(ARGS) ? Base.julia_cmd().exec[1] : ARGS[1])
