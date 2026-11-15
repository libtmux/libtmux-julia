using Test
include(joinpath(@__DIR__, "..", "check-release-tag.jl"))
using .CheckReleaseTag
const C = CheckReleaseTag

git(root, arguments...) = C.run_git(collect(String, arguments), root)

function fails(action, fragment)
    error = try
        action()
        nothing
    catch error
        error
    end
    error isa C.ReleaseCheckError && occursin(fragment, error.message)
end

@testset "release tag verification" begin
    mktempdir(; prefix="libtmux-julia-release-test-") do directory
        root = realpath(directory)
        source, remote, record = joinpath(root, "source"),
        joinpath(root, "remote.git"),
        joinpath(root, "release.toml")
        git(root, "init", "-q", source)
        git(root, "-C", source, "config", "user.name", "release check")
        git(root, "-C", source, "config", "user.email", "release-check@example.invalid")
        for package in C.PACKAGES
            project = joinpath(source, package.project)
            mkpath(dirname(project))
            write(
                project,
                "name = \"$(package.name)\"\nuuid = \"$(package.uuid)\"\nversion = \"0.1.0-alpha.1\"\n",
            )
        end
        write(joinpath(source, "README.md"), "fixture\n")
        git(root, "-C", source, "add", ".")
        git(root, "-C", source, "commit", "-qm", "release fixture")
        git(root, "-C", source, "branch", "-M", "master")
        commit = C.sha(git(root, "-C", source, "rev-parse", "HEAD"), "fixture commit")
        tag = "v0.1.0-alpha.1"
        git(root, "-C", source, "tag", "-a", tag, "-m", "release fixture")
        git(root, "init", "-q", "--bare", remote)
        remote_url = "file://" * remote
        git(root, "-C", source, "remote", "add", "origin", remote_url)
        git(root, "-C", source, "push", "-q", "origin", "master", "--tags")
        public_tag = C.remote_tag(source, remote_url, tag)
        event = Dict{String,Any}(
            "ref" => "refs/tags/$tag",
            "before" => C.ZERO_SHA,
            "after" => git(root, "-C", source, "rev-parse", "refs/tags/$tag"),
            "created" => true,
            "deleted" => false,
            "forced" => false,
            "repository" => Dict("full_name" => C.EXPECTED_REPOSITORY),
        )
        event_path = joinpath(root, "event.json")
        write(event_path, C.JSON.json(event))
        validate(event; tag=tag, commit=commit, ref="refs/tags/$tag", public=public_tag) =
            C.validate_event(
                event;
                tag,
                commit,
                ref,
                repository=C.EXPECTED_REPOSITORY,
                public_tag=public,
            )

        C.preflight(;
            checkout=source,
            event_path,
            tag,
            commit,
            ref="refs/tags/$tag",
            repository=C.EXPECTED_REPOSITORY,
            output=record,
            repository_url=remote_url,
        )
        parsed = C.TOML.parsefile(record)
        @test parsed["commit"] == commit && parsed["tag"] == tag
        @test [item["subdir"] for item in parsed["packages"]] == ["", "packages/LibTmuxMCP", "packages/LibTmuxWorkspace"]
        @test public_tag.commit_sha == commit && public_tag.object_sha != commit
        @test fails(() -> validate(merge(event, Dict("after" => commit))), "event object")

        lightweight_tag = "v0.1.0-alpha.1+lightweight"
        git(root, "-C", source, "tag", lightweight_tag, commit)
        git(root, "-C", source, "push", "-q", "origin", "refs/tags/$lightweight_tag")
        lightweight = C.remote_tag(source, remote_url, lightweight_tag)
        @test lightweight == C.TagReference(commit, commit)
        validate(
            merge(event, Dict("ref" => "refs/tags/$lightweight_tag", "after" => commit));
            tag=lightweight_tag,
            ref="refs/tags/$lightweight_tag",
            public=lightweight,
        )

        shallow = joinpath(root, "shallow")
        git(root, "clone", "-q", "--depth", "1", "--branch", tag, remote_url, shallow)
        @test git(root, "-C", shallow, "rev-parse", "--is-shallow-repository") == "true"
        C.require_trunk_ancestry(shallow, remote_url, commit)
        @test git(root, "-C", shallow, "rev-parse", "--is-shallow-repository") == "false"

        @test fails(() -> C.event_argument(""), "--event is empty")
        @test fails(() -> C.tag_name("alpha.1"), "v-prefixed")
        @test fails(() -> C.tag_name("v0.1.0/escape"), "v-prefixed")
        @test fails(() -> validate(event; ref="refs/tags/not-the-tag"), "workflow ref")
        retargeted = merge(event, Dict("before" => "f"^40, "created" => false))
        @test fails(() -> validate(retargeted), "newly created")
        other = merge(event, Dict("repository" => Dict("full_name" => "example/other")))
        @test fails(() -> validate(other), "event repository")
        @test fails(() -> validate(event; commit="f"^40), "does not match")
        project = C.read_project(source, commit, C.PACKAGES[1])
        @test fails(
            () -> C.validate_package_metadata(
                merge(project, Dict("name" => "Wrong")),
                C.PACKAGES[1],
                tag,
            ),
            "package name",
        )
        @test fails(
            () -> C.validate_package_metadata(
                merge(project, Dict("version" => "0.1.0")),
                C.PACKAGES[1],
                tag,
            ),
            "does not match",
        )
        write(joinpath(source, "untracked"), "dirty\n")
        @test fails(() -> C.require_clean_checkout(source, commit), "dirty")
        rm(joinpath(source, "untracked"))
        tree = C.sha(git(root, "-C", source, "write-tree"), "fixture tree")
        unrelated = C.sha(
            git(root, "-C", source, "commit-tree", tree, "-m", "unrelated"),
            "unrelated commit",
        )
        @test fails(
            () -> C.require_trunk_ancestry(source, remote_url, unrelated),
            "not reachable",
        )

        # The command line reports a refusal as exit status 2 and writes no record.
        refused = joinpath(root, "refused.toml")
        @test C.main([
            "verify",
            "--checkout",
            source,
            "--event",
            event_path,
            "--tag",
            "alpha.1",
            "--commit",
            commit,
            "--ref",
            "refs/tags/$tag",
            "--repository",
            C.EXPECTED_REPOSITORY,
            "--output",
            refused,
        ],) == 2
        @test !isfile(refused)
        @test C.main(["verify"]) == 2
    end
end
