using Test
include(joinpath(@__DIR__, "..", "docs-preview-cleanup.jl"))
using .DocsPreviewCleanup
const D = DocsPreviewCleanup

# The response is what `gh api --jq` prints for the filter in the script.
closed = "12\t\"closed\"\n"
opened = "12\t\"open\"\n"

function refused(action, message)
    error = try
        action()
        nothing
    catch error
        error
    end
    error isa D.CleanupError && error.message == message
end

@testset "eligibility" begin
    @test D.eligible(closed, "12") === true
    @test D.eligible(opened, "12") === false
    for (description, response) in (
        "another number" => "13\t\"closed\"\n",
        "a number sent as a string" => "\"12\"\t\"closed\"\n",
        "no number" => "null\t\"closed\"\n",
        "a state that is neither" => "12\t\"merged\"\n",
        "a state in another case" => "12\t\"Closed\"\n",
        "no state" => "12\tnull\n",
        "a response that is not an object" => "invalid\n",
        "an empty response" => "",
        "an extra field" => "12\t\"closed\"\t1\n",
    )
        @test refused(
            () -> D.eligible(response, "12"),
            "invalid current pull request response",
        )
    end
end

@testset "the pull request number" begin
    for pr in ("", "0", "012", "abc", "12 ", "-3", "1.5", "12\n")
        @test refused(() -> D.eligible(closed, pr), "pull request number must be numeric")
        @test refused(
            () -> D.preview_prefix("bucket", pr),
            "pull request number must be numeric",
        )
    end
    @test D.preview_prefix("docs-bucket", "34") == "s3://docs-bucket/en/julia/pr-34/"
end

@testset "the command line refuses a number before it calls gh or aws" begin
    mktempdir(; prefix="libtmux-julia-cleanup-test-") do base
        output = joinpath(base, "output")
        status = redirect_stderr(devnull) do
            D.main([
                "eligibility",
                "--repository",
                "a/b",
                "--pr",
                "abc",
                "--github-output",
                output,
            ])
        end
        @test status == 1
        @test read(output, String) == "should_cleanup=false\n"
        @test redirect_stderr(devnull) do
            D.main(["delete", "--bucket", "b", "--pr", "abc"])
        end == 1
        @test redirect_stderr(devnull) do
            D.main(["delete", "--bucket", "b"])
        end == 1
    end
    @test redirect_stderr(devnull) do
        D.main(String[])
    end == 2
    @test redirect_stderr(devnull) do
        D.main(["remove"])
    end == 2
end
