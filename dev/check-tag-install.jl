"""Install and verify all three LibTmux packages from a checked public release tag."""

using Pkg
using TOML
using UUIDs

const RELEASE_REPOSITORY = "https://github.com/libtmux/libtmux-julia.git"
const EXPECTED_PACKAGES = (
    ("LibTmux", UUID("1a5dcb9e-7968-44df-ad70-bf0a17628f09"), nothing),
    ("LibTmuxMCP", UUID("6ec2004f-18ba-4da6-9e55-6cdc607d109e"), "packages/LibTmuxMCP"),
    (
        "LibTmuxWorkspace",
        UUID("dc7c1d2a-fec3-4b55-92f0-7133c728c990"),
        "packages/LibTmuxWorkspace",
    ),
)

struct ReleaseInstallError <: Exception
    message::String
end

Base.showerror(io::IO, error::ReleaseInstallError) = print(io, error.message)

struct ReleasePackage
    name::String
    uuid::UUID
    version::VersionNumber
    subdir::Union{Nothing,String}
    tree::String
end

struct ReleaseRecord
    repository::String
    tag::String
    commit::String
    packages::NTuple{3,ReleasePackage}
end

struct StageLayout
    root::String
    project::String
    depot::String
    home::String
    bin::String
    proof::String
end

fail(message::AbstractString) = throw(ReleaseInstallError(String(message)))
require(condition::Bool, message::AbstractString) = condition || fail(message)

function require_string(table::AbstractDict, name::AbstractString)
    value = get(table, name, nothing)
    value isa String || fail("release record field $name must be a string")
    return value
end

function require_hash(value::AbstractString, label::AbstractString)
    require(length(value) == 40 && all(isxdigit, value), "$label is not a Git object ID")
    return lowercase(value)
end

function release_package(table::AbstractDict, expected)
    name, uuid, subdir = expected
    require(
        require_string(table, "name") == name,
        "release record has an unexpected package name",
    )
    recorded_uuid = try
        UUID(require_string(table, "uuid"))
    catch error
        error isa ArgumentError || rethrow()
        fail("release record has an invalid package UUID")
    end
    require(recorded_uuid == uuid, "release record has an unexpected package UUID")
    version_text = require_string(table, "version")
    version = try
        VersionNumber(version_text)
    catch error
        error isa ArgumentError || rethrow()
        fail("release record has an invalid package version")
    end
    recorded_subdir = require_string(table, "subdir")
    normalized_subdir = isempty(recorded_subdir) ? nothing : recorded_subdir
    require(
        normalized_subdir == subdir,
        "release record has an unexpected package subdirectory",
    )
    return ReleasePackage(
        name,
        uuid,
        version,
        normalized_subdir,
        require_hash(require_string(table, "tree"), "package tree"),
    )
end

function release_record(table::AbstractDict)
    require(
        get(table, "schema_version", nothing) == 1,
        "release record schema is unsupported",
    )
    repository = require_string(table, "repository")
    require(repository == RELEASE_REPOSITORY, "release record repository is not canonical")
    tag = require_string(table, "tag")
    startswith(tag, "v") || fail("release record tag must start with v")
    commit = require_hash(require_string(table, "commit"), "release commit")
    raw_packages = get(table, "packages", nothing)
    raw_packages isa AbstractVector || fail("release record packages must be an array")
    require(
        length(raw_packages) == length(EXPECTED_PACKAGES),
        "release record package count is wrong",
    )
    packages = ReleasePackage[]
    for (raw, expected) in zip(raw_packages, EXPECTED_PACKAGES)
        raw isa AbstractDict || fail("release record package entry is not a table")
        push!(packages, release_package(raw, expected))
    end
    versions = unique(package.version for package in packages)
    require(length(versions) == 1, "release record packages must share one version")
    require(
        tag == "v" * string(only(versions)),
        "release record tag does not match package version",
    )
    return ReleaseRecord(repository, tag, commit, Tuple(packages))
end

function package_specs(record::ReleaseRecord)
    return [
        Pkg.PackageSpec(url=record.repository, rev=record.commit, subdir=package.subdir) for
        package in record.packages
    ]
end

function is_within(path::AbstractString, root::AbstractString)
    relative = relpath(abspath(path), abspath(root))
    return relative == "." || (
        relative != ".." && !startswith(relative, ".." * Base.Filesystem.path_separator)
    )
end

function stage_layout(stage::AbstractString, checkout::AbstractString)
    root = abspath(stage)
    is_within(root, checkout) && fail("release stage must be outside the checkout")
    isdir(root) || fail("release stage does not exist")
    allowed = Set(["release.toml"])
    for entry in readdir(root)
        entry in allowed || fail("release stage contains unexpected input")
    end
    isfile(joinpath(root, "release.toml")) ||
        fail("release stage does not contain release.toml")
    layout = StageLayout(
        root,
        joinpath(root, "project"),
        joinpath(root, "depot"),
        joinpath(root, "home"),
        joinpath(root, "bin"),
        joinpath(root, "install-proof.toml"),
    )
    for path in (layout.project, layout.depot, layout.home, layout.bin, layout.proof)
        !ispath(path) || fail("release stage is not fresh")
    end
    return layout
end

function configure_isolation(layout::StageLayout)
    for directory in (layout.project, layout.depot, layout.home, layout.bin)
        mkpath(directory)
    end
    ENV["HOME"] = layout.home
    ENV["JULIA_DEPOT_PATH"] = layout.depot
    ENV["JULIA_LOAD_PATH"] = "@:@stdlib"
    ENV["JULIA_PKG_OFFLINE"] = "false"
    ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    pop!(ENV, "TMUX", nothing)
    pop!(ENV, "TMUX_PANE", nothing)
    empty!(DEPOT_PATH)
    push!(DEPOT_PATH, layout.depot)
    empty!(LOAD_PATH)
    append!(LOAD_PATH, ("@", "@stdlib"))
end

function package_info(record::ReleasePackage, info, checkout::AbstractString)
    require(info.name == record.name, "installed package name is wrong")
    require(info.uuid == record.uuid, "installed package UUID is wrong")
    require(info.version == record.version, "installed package version is wrong")
    require(info.is_direct_dep, "installed package is not direct")
    require(!info.is_tracking_path, "installed package tracks a path")
    require(info.is_tracking_repo, "installed package does not track a Git repository")
    require(!info.is_tracking_registry, "installed package tracks a registry")
    require(
        info.git_source == RELEASE_REPOSITORY,
        "installed package source is not canonical",
    )
    require(
        info.git_revision == record.commit,
        "installed package revision is not the release commit",
    )
    require(
        string(info.tree_hash) == record.tree,
        "installed package tree does not match the release commit",
    )
    source = info.source
    source isa AbstractString && isdir(source) ||
        fail("installed package source is unavailable")
    !is_within(source, checkout) ||
        fail("installed package source points into the checkout")
end

function manifest_entry(manifest::AbstractDict, name::AbstractString)
    dependencies = get(manifest, "deps", nothing)
    dependencies isa AbstractDict || fail("Manifest.toml has no dependency table")
    entries = get(dependencies, name, nothing)
    entries isa AbstractVector || fail("Manifest.toml has no package entry")
    require(length(entries) == 1, "Manifest.toml has an ambiguous package entry")
    entry = only(entries)
    entry isa AbstractDict || fail("Manifest.toml package entry is not a table")
    return entry
end

function verify_manifest(record::ReleaseRecord, project::AbstractString)
    manifest = try
        TOML.parsefile(joinpath(project, "Manifest.toml"))
    catch error
        error isa Base.TOML.ParserError || rethrow()
        fail("Manifest.toml is invalid")
    end
    for package in record.packages
        entry = manifest_entry(manifest, package.name)
        require(
            get(entry, "uuid", nothing) == string(package.uuid),
            "Manifest.toml has a wrong package UUID",
        )
        require(
            get(entry, "version", nothing) == string(package.version),
            "Manifest.toml has a wrong package version",
        )
        require(
            get(entry, "repo-url", nothing) == RELEASE_REPOSITORY,
            "Manifest.toml has a wrong repository",
        )
        require(
            get(entry, "repo-rev", nothing) == record.commit,
            "Manifest.toml has a wrong release commit",
        )
        require(
            get(entry, "git-tree-sha1", nothing) == package.tree,
            "Manifest.toml has a wrong package tree",
        )
        if package.subdir === nothing
            !haskey(entry, "repo-subdir") ||
                fail("Manifest.toml gives the root package a subdirectory")
        else
            get(entry, "repo-subdir", nothing) == package.subdir ||
                fail("Manifest.toml has a wrong package subdirectory")
        end
    end
end

function installed_packages(record::ReleaseRecord, checkout::AbstractString)
    dependencies = Pkg.dependencies()
    for package in record.packages
        info = get(dependencies, package.uuid, nothing)
        info === nothing && fail("Pkg did not install $(package.name)")
        package_info(package, info, checkout)
    end
end

function isolated_environment(layout::StageLayout)
    return (
        "HOME" => layout.home,
        "JULIA_DEPOT_PATH" => layout.depot,
        "JULIA_LOAD_PATH" => "@:@stdlib",
        "JULIA_PKG_OFFLINE" => "true",
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
    )
end

function verify_imports_and_launchers(record::ReleaseRecord, layout::StageLayout)
    launchers = joinpath(layout.root, "launchers.txt")
    program = """
    using LibTmux, LibTmuxMCP, LibTmuxWorkspace
    @assert LOAD_PATH == ["@", "@stdlib"]
    @assert DEPOT_PATH == [$(repr(layout.depot))]
    @assert Base.active_project() == $(repr(joinpath(layout.project, "Project.toml")))
    @assert Base.pkgversion(LibTmux) == $(repr(record.packages[1].version))
    @assert Base.pkgversion(LibTmuxMCP) == $(repr(record.packages[2].version))
    @assert Base.pkgversion(LibTmuxWorkspace) == $(repr(record.packages[3].version))
    @assert LibTmuxMCP.LibTmux === LibTmux
    @assert LibTmuxWorkspace.LibTmux === LibTmux
    mcp = LibTmuxMCP.install_cli($(repr(layout.bin)); project=Base.active_project())
    workspace = LibTmuxWorkspace.install_cli($(repr(layout.bin)); project=Base.active_project())
    write($(repr(launchers)), mcp * "\\n" * workspace * "\\n")
    """
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compiled-modules=no --compile=min -O0 --project=$(layout.project) -e $program`
    run(addenv(Cmd(command; dir=layout.root), isolated_environment(layout)...))
    paths = split(chomp(read(launchers, String)), '\n')
    require(length(paths) == 2 && all(isfile, paths), "installed launcher is unavailable")
    for launcher in paths
        run(
            addenv(
                Cmd(`$launcher --help`; dir=layout.root),
                isolated_environment(layout)...,
            ),
        )
    end
end

function write_proof(record::ReleaseRecord, layout::StageLayout)
    packages = Dict(
        package.name => Dict(
            "uuid" => string(package.uuid),
            "version" => string(package.version),
            "subdir" => something(package.subdir, ""),
            "tree" => package.tree,
        ) for package in record.packages
    )
    open(layout.proof, "w") do io
        TOML.print(
            io,
            Dict(
                "schema_version" => 1,
                "repository" => record.repository,
                "tag" => record.tag,
                "commit" => record.commit,
                "packages" => packages,
            ),
        )
    end
end

function verify(
    release_path::AbstractString,
    stage::AbstractString,
    checkout::AbstractString,
)
    layout = stage_layout(stage, checkout)
    record = release_record(TOML.parsefile(release_path))
    abspath(release_path) == joinpath(layout.root, "release.toml") ||
        fail("release record must be inside the release stage")
    configure_isolation(layout)
    Pkg.activate(layout.project)
    Pkg.add(package_specs(record))
    installed_packages(record, checkout)
    verify_manifest(record, layout.project)
    verify_imports_and_launchers(record, layout)
    write_proof(record, layout)
end

function expect_error(action, fragment::AbstractString)
    try
        action()
    catch error
        error isa ReleaseInstallError || rethrow()
        occursin(fragment, error.message) || rethrow()
        return nothing
    end
    error("expected release-install failure containing $fragment")
end

function fixture_record()
    return Dict(
        "schema_version" => 1,
        "repository" => RELEASE_REPOSITORY,
        "tag" => "v0.1.0-alpha.1",
        "commit" => repeat("a", 40),
        "packages" => [
            Dict(
                "name" => "LibTmux",
                "uuid" => "1a5dcb9e-7968-44df-ad70-bf0a17628f09",
                "version" => "0.1.0-alpha.1",
                "subdir" => "",
                "tree" => repeat("b", 40),
            ),
            Dict(
                "name" => "LibTmuxMCP",
                "uuid" => "6ec2004f-18ba-4da6-9e55-6cdc607d109e",
                "version" => "0.1.0-alpha.1",
                "subdir" => "packages/LibTmuxMCP",
                "tree" => repeat("c", 40),
            ),
            Dict(
                "name" => "LibTmuxWorkspace",
                "uuid" => "dc7c1d2a-fec3-4b55-92f0-7133c728c990",
                "version" => "0.1.0-alpha.1",
                "subdir" => "packages/LibTmuxWorkspace",
                "tree" => repeat("d", 40),
            ),
        ],
    )
end

function synthetic_manifest(record::ReleaseRecord)
    entries = Dict{String,Any}()
    for package in record.packages
        entry = Dict{String,Any}(
            "uuid" => string(package.uuid),
            "version" => string(package.version),
            "repo-url" => record.repository,
            "repo-rev" => record.commit,
            "git-tree-sha1" => package.tree,
        )
        package.subdir === nothing || (entry["repo-subdir"] = package.subdir)
        entries[package.name] = Any[entry]
    end
    return Dict{String,Any}("deps" => entries)
end

function self_test()
    record = release_record(fixture_record())
    @assert record.tag == "v0.1.0-alpha.1"
    @assert record.packages[1].subdir === nothing
    @assert record.packages[2].subdir == "packages/LibTmuxMCP"
    specs = package_specs(record)
    @assert getproperty(specs[1], :subdir) === nothing
    @assert getproperty(specs[3], :subdir) == "packages/LibTmuxWorkspace"
    @assert getproperty(specs[1], :rev) == record.commit
    manifest = synthetic_manifest(record)
    mktempdir(; prefix="libtmux-julia-release-install-self-test-") do directory
        project = joinpath(directory, "project")
        mkpath(project)
        open(joinpath(project, "Manifest.toml"), "w") do io
            TOML.print(io, manifest)
        end
        verify_manifest(record, project)
        manifest["deps"]["LibTmuxMCP"][1]["repo-subdir"] = "wrong"
        open(joinpath(project, "Manifest.toml"), "w") do io
            TOML.print(io, manifest)
        end
        expect_error(() -> verify_manifest(record, project), "subdirectory")
    end
    wrong_tag = fixture_record()
    wrong_tag["tag"] = "v0.1.0-alpha.2"
    expect_error(() -> release_record(wrong_tag), "does not match")
    wrong_package = fixture_record()
    wrong_package["packages"][1]["name"] = "Wrong"
    expect_error(() -> release_record(wrong_package), "package name")
    mktempdir(; prefix="libtmux-julia-release-stage-self-test-") do checkout
        stage = mktempdir(; prefix="libtmux-julia-release-stage-")
        write(joinpath(stage, "release.toml"), "schema_version = 1\\n")
        layout = stage_layout(stage, checkout)
        @assert layout.root == abspath(stage)
        expect_error(() -> stage_layout(checkout, checkout), "outside")
    end
end

function usage()
    error(
        "Usage: julia dev/check-tag-install.jl --self-test, or julia dev/check-tag-install.jl verify --release RELEASE.toml --stage STAGE --checkout CHECKOUT",
    )
end

function main(args)
    args == ["--self-test"] && return self_test()
    length(args) == 7 || usage()
    args[1] == "verify" || usage()
    options = Dict(args[index] => args[index+1] for index = 2:2:length(args))
    Set(keys(options)) == Set(["--release", "--stage", "--checkout"]) || usage()
    verify(options["--release"], options["--stage"], options["--checkout"])
end

try
    main(ARGS)
    println("PASS public tag installation")
catch error
    if error isa ReleaseInstallError ||
       error isa Base.TOML.ParserError ||
       error isa SystemError
        println(stderr, "NOT RUN: ", sprint(showerror, error))
        exit(2)
    end
    rethrow()
end
