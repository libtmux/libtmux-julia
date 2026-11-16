# Check that a pull request is closed, then delete its documentation preview.
#
# usage:
#   julia --startup-file=no scripts/docs-preview-cleanup/docs-preview-cleanup.jl eligibility
#       --repository OWNER/NAME --pr NUMBER --github-output FILE
#   julia --startup-file=no scripts/docs-preview-cleanup/docs-preview-cleanup.jl delete
#       --bucket BUCKET --pr NUMBER
#
# `eligibility` reads the pull request with `gh api`, which needs GH_TOKEN, and appends
# `should_cleanup=true` to the output file when the pull request is closed. It writes
# `should_cleanup=false` first, so a failed check leaves the cleanup off. A closed event
# can be rerun after the pull request reopens, which is why the state is read again.
# `delete` removes the Julia preview under the docs bucket with `aws s3 rm`. Both exit 1
# when the number is not a positive integer, and `eligibility` exits 1 when the response
# is not the pull request asked for or its state is neither open nor closed. The tests
# are in tests/runtests.jl.

module DocsPreviewCleanup

struct CleanupError <: Exception
    message::String
end

# gh filters the response with this, so the script reads two JSON-encoded fields and
# never parses the pull request. A number sent as a string, or a missing field, keeps
# its JSON spelling and fails the comparison below.
const FIELDS = """if type == "object" then [.number, .state] | map(tojson) | join("\\t") else "invalid" end"""

const USAGE = """
usage: docs-preview-cleanup.jl eligibility --repository OWNER/NAME --pr NUMBER
           --github-output FILE
       docs-preview-cleanup.jl delete --bucket BUCKET --pr NUMBER"""

"Refuse a pull request number that is not a positive decimal integer."
function pull_request_number(pr)
    occursin(r"^[1-9][0-9]*\z", pr) ||
        throw(CleanupError("pull request number must be numeric"))
    pr
end

"""
Whether the pull request in the filtered response is closed.

A response that is not an object, names another number, or has a state other than
open or closed is refused.
"""
function eligible(response, pr)
    pull_request_number(pr)
    fields = split(strip(response), '\t')
    (length(fields) == 2 && fields[1] == pr && fields[2] in ("\"open\"", "\"closed\"")) ||
        throw(CleanupError("invalid current pull request response"))
    fields[2] == "\"closed\""
end

"The S3 prefix that holds the preview of one pull request."
preview_prefix(bucket, pr) = "s3://$bucket/en/julia/pr-$(pull_request_number(pr))/"

function options(arguments, names)
    values = Dict{String,String}()
    rest = arguments
    while !isempty(rest)
        (length(rest) >= 2 && rest[1] in names) || throw(CleanupError(USAGE))
        values[rest[1]] = rest[2]
        rest = rest[3:end]
    end
    for name in names
        haskey(values, name) || throw(CleanupError("$name is required"))
    end
    values
end

function check_eligibility(arguments)
    values = options(arguments, ("--repository", "--pr", "--github-output"))
    output = values["--github-output"]
    open(io -> println(io, "should_cleanup=false"), output, "a")
    pr = pull_request_number(values["--pr"])
    command = `gh api --method GET repos/$(values["--repository"])/pulls/$pr --jq $FIELDS`
    response = try
        read(command, String)
    catch error
        error isa ProcessFailedException || rethrow()
        return 1
    end
    open(io -> println(io, "should_cleanup=", eligible(response, pr)), output, "a")
    0
end

function delete_preview(arguments)
    values = options(arguments, ("--bucket", "--pr"))
    prefix = preview_prefix(values["--bucket"], values["--pr"])
    run(ignorestatus(`aws s3 rm $prefix --recursive`)).exitcode
end

function main(arguments=ARGS)
    isempty(arguments) && (println(stderr, USAGE); return 2)
    action = first(arguments)
    action in ("eligibility", "delete") || (println(stderr, USAGE); return 2)
    try
        return action == "delete" ? delete_preview(arguments[2:end]) :
               check_eligibility(arguments[2:end])
    catch error
        error isa CleanupError || rethrow()
        println(stderr, error.message)
        return 1
    end
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(DocsPreviewCleanup.main(ARGS))
