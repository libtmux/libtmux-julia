# Verify a tagged LibTmux source release before a public Git install.
#
# usage:
#   julia --project=scripts/check-release-tag scripts/check-release-tag/check-release-tag.jl \
#       verify --checkout DIR --event FILE --tag TAG --commit SHA --ref REF \
#       --repository OWNER/NAME --output FILE
#
# Checks the push event, the public tag, a clean checkout, the ancestry of the
# commit on master and the three package manifests, then writes a release record
# that dev/check-tag-install.jl reads. The tests are in tests/runtests.jl.

module CheckReleaseTag

import JSON
import TOML

const EXPECTED_REPOSITORY = "libtmux/libtmux-julia"
const PUBLIC_REPOSITORY_URL = "https://github.com/libtmux/libtmux-julia.git"
const ZERO_SHA = "0"^40
const SHA = r"^[0-9a-fA-F]{40}$"
const VERSION = "(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?"
const TAG = Regex("^v" * VERSION * "\$")

"The candidate tag cannot establish the requested source-release proof."
struct ReleaseCheckError <: Exception
    message::String
end
Base.showerror(io::IO, error::ReleaseCheckError) = print(io, error.message)

struct Package
    name::String
    uuid::String
    project::String
    subdir::Union{Nothing,String}
end

struct TagReference
    object_sha::String
    commit_sha::String
end

const PACKAGES = (
    Package("LibTmux", "1a5dcb9e-7968-44df-ad70-bf0a17628f09", "Project.toml", nothing),
    Package(
        "LibTmuxMCP",
        "6ec2004f-18ba-4da6-9e55-6cdc607d109e",
        "packages/LibTmuxMCP/Project.toml",
        "packages/LibTmuxMCP",
    ),
    Package(
        "LibTmuxWorkspace",
        "dc7c1d2a-fec3-4b55-92f0-7133c728c990",
        "packages/LibTmuxWorkspace/Project.toml",
        "packages/LibTmuxWorkspace",
    ),
)

fail(message) = throw(ReleaseCheckError(message))

function sha(value, label)
    occursin(SHA, value) || fail("$label is not a full Git commit ID")
    lowercase(value)
end

function event_argument(value)
    isempty(strip(value)) &&
        fail("--event is empty; the workflow did not pass the push event path")
    value
end

function tag_name(value)
    occursin(TAG, value) || fail("tag must be a v-prefixed semantic version")
    value
end

function git_command(arguments, cwd)
    Cmd(`git $arguments`; dir=cwd)
end

function run_git(arguments, cwd)
    output = IOBuffer()
    command =
        pipeline(git_command(arguments, cwd); stdin=devnull, stdout=output, stderr=devnull)
    success(command) || fail("Git command failed: $(first(arguments))")
    strip(String(take!(output)))
end

git_succeeds(arguments, cwd) = success(
    pipeline(git_command(arguments, cwd); stdin=devnull, stdout=devnull, stderr=devnull),
)

function read_project(checkout, commit, package)
    source = run_git(["show", "$commit:$(package.project)"], checkout)
    try
        TOML.parse(source)
    catch error
        error isa TOML.ParserError || rethrow()
        fail("$(package.project) is not valid TOML: $(error.type)")
    end
end

function validate_package_metadata(metadata, package, tag)
    version = chopprefix(tag, "v")
    get(metadata, "name", nothing) == package.name ||
        fail("$(package.project) has an unexpected package name")
    get(metadata, "uuid", nothing) == package.uuid ||
        fail("$(package.project) has an unexpected package UUID")
    get(metadata, "version", nothing) == version ||
        fail("$(package.project) does not match tag $tag")
end

function release_packages(checkout, commit, tag)
    tag = tag_name(tag)
    version = chopprefix(tag, "v")
    map(PACKAGES) do package
        validate_package_metadata(read_project(checkout, commit, package), package, tag)
        tree_ref =
            package.subdir === nothing ? "$commit^{tree}" : "$commit:$(package.subdir)"
        Dict(
            "name" => package.name,
            "uuid" => package.uuid,
            "version" => version,
            "subdir" => something(package.subdir, ""),
            "tree" => sha(run_git(["rev-parse", tree_ref], checkout), "package tree"),
        )
    end
end

function validate_event(event, ; tag, commit, ref, repository, public_tag)
    tag = tag_name(tag)
    commit = sha(commit, "workflow commit")
    expected_ref = "refs/tags/$tag"
    repository == EXPECTED_REPOSITORY || fail("workflow repository is not canonical")
    ref == expected_ref || fail("workflow ref does not name the release tag")
    get(event, "ref", nothing) == expected_ref ||
        fail("push event ref does not name the release tag")
    get(event, "deleted", nothing) === false || fail("release tags must not be deleted")
    (
        get(event, "created", nothing) === true &&
        get(event, "before", nothing) == ZERO_SHA
    ) || fail("release tags must be newly created")
    get(event, "forced", nothing) === false ||
        fail("release tags must not be force-updated")
    payload = get(event, "repository", nothing)
    (
        payload isa AbstractDict &&
        get(payload, "full_name", nothing) == EXPECTED_REPOSITORY
    ) || fail("push event repository is not canonical")
    public_tag.commit_sha == commit ||
        fail("public tag commit does not match the workflow commit")
    sha(string(get(event, "after", "")), "push event object") == public_tag.object_sha ||
        fail("push event object does not match the public tag")
    nothing
end

function remote_tag(checkout, repository_url, tag)
    tag = tag_name(tag)
    direct = "refs/tags/$tag"
    output = run_git(["ls-remote", "--tags", repository_url, direct * "*"], checkout)
    references = Dict{String,String}()
    for line in split(output, '\n'; keepempty=false)
        parts = split(line, '\t'; limit=2)
        length(parts) == 2 || fail("public remote returned an invalid tag reference")
        value, name = parts
        name in (direct, direct * "^{}") &&
            (references[name] = sha(String(value), "public tag object"))
    end
    haskey(references, direct) || fail("public remote does not contain the release tag")
    TagReference(references[direct], get(references, direct * "^{}", references[direct]))
end

function require_clean_checkout(checkout, commit)
    sha(run_git(["rev-parse", "HEAD^{commit}"], checkout), "checkout commit") == commit ||
        fail("checkout does not match the workflow commit")
    isempty(run_git(["status", "--porcelain=v1", "--untracked-files=all"], checkout)) ||
        fail("checkout is dirty")
end

function require_trunk_ancestry(checkout, repository_url, commit)
    trunk = "refs/remotes/release-check/master"
    arguments = ["fetch", "--no-tags"]
    run_git(["rev-parse", "--is-shallow-repository"], checkout) == "true" &&
        push!(arguments, "--unshallow")
    append!(arguments, [repository_url, "refs/heads/master:$trunk"])
    run_git(arguments, checkout)
    git_succeeds(["merge-base", "--is-ancestor", commit, trunk], checkout) ||
        fail("release tag commit is not reachable from master")
end

toml_string(value) = JSON.json(value)

function write_release_record(path, ; tag, commit, packages)
    mkpath(dirname(path))
    lines = [
        "schema_version = 1",
        "repository = $(toml_string(PUBLIC_REPOSITORY_URL))",
        "tag = $(toml_string(tag))",
        "commit = $(toml_string(commit))",
    ]
    for package in packages
        append!(
            lines,
            [
                "",
                "[[packages]]",
                (
                    "$key = $(toml_string(package[key]))" for
                    key in ("name", "uuid", "version", "subdir", "tree")
                )...,
            ],
        )
    end
    temporary = joinpath(dirname(path), ".$(basename(path)).$(getpid()).tmp")
    write(temporary, join(lines, "\n") * "\n")
    mv(temporary, path; force=true)
end

function preflight(;
    checkout,
    event_path,
    tag,
    commit,
    ref,
    repository,
    output,
    repository_url=PUBLIC_REPOSITORY_URL,
)
    tag = tag_name(tag)
    commit = sha(commit, "workflow commit")
    event = try
        JSON.parsefile(event_path; dicttype=Dict{String,Any})
    catch error
        error isa SystemError && fail("cannot read push event: $(error.prefix)")
        fail("push event is not JSON")
    end
    event isa AbstractDict || fail("push event is not an object")
    validate_event(
        event;
        tag,
        commit,
        ref,
        repository,
        public_tag=remote_tag(checkout, repository_url, tag),
    )
    require_clean_checkout(checkout, commit)
    require_trunk_ancestry(checkout, repository_url, commit)
    write_release_record(
        output;
        tag,
        commit,
        packages=release_packages(checkout, commit, tag),
    )
end

const USAGE = """
usage: check-release-tag.jl verify --checkout DIR --event FILE --tag TAG --commit SHA \\
    --ref REF --repository OWNER/NAME --output FILE"""

function parse_arguments(arguments)
    length(arguments) >= 1 && arguments[1] == "verify" || fail(USAGE)
    names =
        ("--checkout", "--event", "--tag", "--commit", "--ref", "--repository", "--output")
    values = Dict{String,String}()
    rest = arguments[2:end]
    while !isempty(rest)
        (length(rest) >= 2 && rest[1] in names && !haskey(values, rest[1])) || fail(USAGE)
        values[rest[1]] = rest[2]
        rest = rest[3:end]
    end
    all(name -> haskey(values, name), names) || fail(USAGE)
    values
end

function main(arguments=ARGS)
    try
        values = parse_arguments(arguments)
        preflight(;
            checkout=abspath(values["--checkout"]),
            event_path=abspath(event_argument(values["--event"])),
            tag=values["--tag"],
            commit=values["--commit"],
            ref=values["--ref"],
            repository=values["--repository"],
            output=abspath(values["--output"]),
        )
    catch error
        error isa ReleaseCheckError || error isa SystemError || rethrow()
        println(stderr, "NOT RUN: ", sprint(showerror, error))
        return 2
    end
    println("PASS release tag verification")
    0
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(CheckReleaseTag.main(ARGS))
