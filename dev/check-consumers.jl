using SHA
using TOML

const SOURCE_ROOT = dirname(@__DIR__)
const PACKAGE_SOURCES = (
    ("LibTmux", ".", "1a5dcb9e-7968-44df-ad70-bf0a17628f09"),
    ("LibTmuxMCP", "packages/LibTmuxMCP", "6ec2004f-18ba-4da6-9e55-6cdc607d109e"),
    (
        "LibTmuxWorkspace",
        "packages/LibTmuxWorkspace",
        "dc7c1d2a-fec3-4b55-92f0-7133c728c990",
    ),
)

# ProcessFailedException renders the inherited environment stored in Cmd.env.
struct ConsumerProcessError <: Exception
    phase::String
    cause::Exception
end

function Base.showerror(io::IO, error::ConsumerProcessError)
    print(
        io,
        "consumer phase ",
        repr(error.phase),
        " failed: ",
        nameof(typeof(error.cause)),
    )
    if error.cause isa ProcessFailedException
        for (index, process) in enumerate(error.cause.procs)
            print(
                io,
                "; child ",
                index,
                " exit=",
                process.exitcode,
                " signal=",
                process.termsignal,
            )
        end
    end
end

function run_consumer_child(phase::AbstractString, command)
    result, failure = nothing, nothing
    try
        result = run(command)
    catch error
        failure = error
    end
    # Leave the catch stack before throwing so Julia cannot render the raw cause.
    failure isa InterruptException && throw(failure)
    failure === nothing || throw(ConsumerProcessError(String(phase), failure))
    result
end

function consumer_self_test()
    marker = "consumer-synthetic-credential-sentinel"
    child = Cmd(["/bin/sh", "-c", "echo child-stdout; echo child-stderr >&2; exit 7"])
    program = """
    include($(repr(@__FILE__)))
    run_consumer_child("sentinel child", addenv($(repr(child)), "CONSUMER_TEST_EXTRA" => "safe"))
    """
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=min -O0 -e $program`
    output, errors = IOBuffer(), IOBuffer()
    process = run(
        pipeline(
            ignorestatus(setenv(command, Dict("CONSUMER_TEST_SECRET" => marker)));
            stdout=output,
            stderr=errors,
        ),
    )
    stdout_text, stderr_text = String(take!(output)), String(take!(errors))
    @assert !success(process)
    @assert occursin("child-stdout", stdout_text)
    @assert occursin("child-stderr", stderr_text)
    @assert occursin("consumer phase \"sentinel child\" failed", stderr_text)
    @assert occursin("exit=7 signal=0", stderr_text)
    @assert !occursin(marker, stdout_text * stderr_text)
    @assert !occursin("CONSUMER_TEST_SECRET", stdout_text * stderr_text)
    @assert !occursin("caused by", stderr_text)
    failure = try
        run_consumer_child(
            "inspectable cause",
            setenv(`/bin/sh -c "exit 7"`, Dict("CONSUMER_TEST_SECRET" => marker)),
        )
    catch error
        error
    end
    @assert failure isa ConsumerProcessError
    @assert failure.cause isa ProcessFailedException
    @assert only(failure.cause.procs).exitcode == 7
    @assert success(run_consumer_child("successful child", `/bin/sh -c "exit 0"`))
    println(
        "PASS consumer child output, exit evidence, inspectable cause and diagnostic omission",
    )
end

function package_files(root)
    files = String[]
    for entry in (
        "Project.toml",
        "LICENSE",
        "README.md",
        "CHANGELOG.md",
        "src",
        "ext",
        "examples",
        "test",
    )
        path = joinpath(root, entry)
        ispath(path) || continue
        islink(path) && error("Package exports must not contain symbolic links")
        if isfile(path)
            push!(files, entry)
        else
            for (directory, directories, names) in walkdir(path)
                filter!(name -> name != "__pycache__", directories)
                any(name -> islink(joinpath(directory, name)), directories) &&
                    error("Package exports must not contain symbolic links")
                for name in names
                    file = joinpath(directory, name)
                    islink(file) && error("Package exports must not contain symbolic links")
                    push!(files, relpath(file, root))
                end
            end
        end
    end
    sort!(files)
end

digest(path) = bytes2hex(open(sha256, path))

function isolated_environment(stage)
    (
        "JULIA_DEPOT_PATH" => joinpath(stage, "depot"),
        "JULIA_LOAD_PATH" => "@:@stdlib",
        "JULIA_PKG_OFFLINE" => "true",
        "JULIA_PKG_PRECOMPILE_AUTO" => "0",
    )
end

function workspace_test_setup(stage)
    """
    Pkg.activate($(repr(joinpath(stage, "test-environments", "LibTmuxWorkspace"))))
    Pkg.develop([
        Pkg.PackageSpec(path=$(repr(joinpath(stage, "source", "LibTmux")))),
        Pkg.PackageSpec(path=$(repr(joinpath(stage, "source", "LibTmuxWorkspace")))),
    ])
    Pkg.add(Pkg.PackageSpec(name="JSON", version=v"1.9.0"))
    """
end

function check_manifest(stage, project)
    manifest = TOML.parsefile(joinpath(project, "Manifest.toml"))
    for entries in values(manifest["deps"]), entry in entries
        haskey(entry, "path") || continue
        path = realpath(joinpath(project, entry["path"]))
        startswith(path, joinpath(stage, "source") * "/") ||
            error("Manifest depends on a source outside the export")
    end
end

function prepare(stage)
    ispath(stage) &&
        any(entry -> entry != "depot", readdir(stage)) &&
        error("Preparation needs an empty directory or only a reusable depot")
    mkpath(stage)
    exports = Dict{String,Any}()
    for (name, relative, uuid) in PACKAGE_SOURCES
        source = normpath(joinpath(SOURCE_ROOT, relative))
        metadata = TOML.parsefile(joinpath(source, "Project.toml"))
        metadata["name"] == name || error("Unexpected package name")
        metadata["uuid"] == uuid || error("Unexpected package UUID")
        files = package_files(source)
        isempty(files) && error("Package has no exportable source")
        hashes = Dict{String,String}()
        for file in files
            destination = joinpath(stage, "source", name, file)
            mkpath(dirname(destination))
            cp(joinpath(source, file), destination)
            hashes[file] = digest(destination)
            chmod(destination, 0o444)
        end
        exports[name] = hashes
    end

    program = """
    using Pkg
    Pkg.offline(false)
    stage = $(repr(stage))
    for name in $(repr(first.(PACKAGE_SOURCES)))
        Pkg.activate(joinpath(stage, "environments", name))
        packages = [Pkg.PackageSpec(path = joinpath(stage, "source", "LibTmux"))]
        if name != "LibTmux"
            push!(packages, Pkg.PackageSpec(path = joinpath(stage, "source", name)))
        end
        Pkg.develop(packages)
    end
    """
    program *= workspace_test_setup(stage)
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 -e $program`
    # Dependency acquisition is an explicit setup phase, outside timed checks.
    run_consumer_child(
        "prepare dependencies",
        addenv(
            Cmd(command; dir=stage),
            isolated_environment(stage)...,
            "JULIA_PKG_OFFLINE" => "false",
        ),
    )
    for (name, _, _) in PACKAGE_SOURCES
        project = joinpath(stage, "environments", name)
        warmup = "using $name; using UUIDs"
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$project -e $warmup`
        run_consumer_child(
            "prepare $name import",
            addenv(Cmd(command; dir=stage), isolated_environment(stage)...),
        )
    end
    test_project = joinpath(stage, "test-environments", "LibTmuxWorkspace")
    warmup = "using LibTmuxWorkspace, JSON"
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$test_project -e $warmup`
    run_consumer_child(
        "prepare workspace test import",
        addenv(Cmd(command; dir=stage), isolated_environment(stage)...),
    )
    open(joinpath(stage, "exports.toml"), "w") do io
        TOML.print(io, exports; sorted=true)
    end
    println("PASS prepared three isolated import environments; no original source paths")
end

function check(stage; imports=true)
    isfile(joinpath(stage, "exports.toml")) ||
        error("Consumer stage is not prepared; run prepare first")
    exports = TOML.parsefile(joinpath(stage, "exports.toml"))
    for (name, relative, uuid) in PACKAGE_SOURCES
        source = normpath(joinpath(SOURCE_ROOT, relative))
        exported = joinpath(stage, "source", name)
        hashes = exports[name]
        package_files(source) == sort!(collect(keys(hashes))) ||
            error("Source file set changed; prepare a fresh stage")
        for (file, hash) in hashes
            digest(joinpath(source, file)) == hash ||
                error("Current package source changed; prepare a fresh stage")
            digest(joinpath(exported, file)) == hash || error("Prepared source changed")
            iszero(stat(joinpath(exported, file)).mode & 0o222) ||
                error("Prepared source is writable")
        end
        project = joinpath(stage, "environments", name)
        check_manifest(stage, project)
        imports || continue
        program = """
        using LibTmux
        using $name
        using UUIDs
        @assert LOAD_PATH == ["@", "@stdlib"]
        @assert DEPOT_PATH == [$(repr(joinpath(stage, "depot")))]
        @assert Base.active_project() == $(repr(joinpath(project, "Project.toml")))
        @assert Base.PkgId($name).uuid == UUID($(repr(uuid)))
        @assert realpath(pathof($name)) == $(repr(joinpath(exported, "src", name * ".jl")))
        @assert realpath(pathof(LibTmux)) == $(repr(joinpath(stage, "source", "LibTmux", "src", "LibTmux.jl")))
        @assert $name.LibTmux === LibTmux
        @assert :Server in names(LibTmux)
        endpoint = LibTmux.Server(socket_name = "libtmux-consumer-check", tmux = "missing-tmux")
        @assert endpoint.socket_name == "libtmux-consumer-check"
        @assert occursin("libtmux-consumer-check", repr(endpoint))
        println("PASS $name external import and core module identity")
        """
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$project -e $program`
        run_consumer_child(
            "$name external import",
            addenv(Cmd(command; dir=stage), isolated_environment(stage)...),
        )
    end
    check_manifest(stage, joinpath(stage, "test-environments", "LibTmuxWorkspace"))
    metadata = TOML.parsefile(joinpath(stage, "source", "LibTmux", "Project.toml"))
    dependencies = keys(get(metadata, "deps", Dict()))
    forbidden = ("LibTmuxMCP", "LibTmuxWorkspace", "HTTP", "YAML", "DataFrames")
    isempty(intersect(dependencies, forbidden)) ||
        error("Core imports a consumer dependency")
    println("PASS unchanged exported sources and core dependency boundary")
end

function check_examples(stage)
    check(stage; imports=false)
    programs = Tuple{String,String}[]
    for (name, _, _) in PACKAGE_SOURCES
        examples = joinpath(stage, "source", name, "examples")
        isdir(examples) || continue
        for (directory, _, files) in walkdir(examples), file in sort!(files)
            endswith(file, ".jl") || continue
            push!(programs, (name, joinpath(directory, file)))
        end
    end
    isempty(programs) && error("No executable examples were discovered")
    python = something(Sys.which("python3"), "python3")
    checker = joinpath(@__DIR__, "check-example-cleanup.py")
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    core_project = joinpath(stage, "environments", "LibTmux")
    audit = `$python $checker --negative-control --tmux $tmux --cwd $stage -- $(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$core_project`
    run_consumer_child(
        "example cleanup negative control",
        addenv(Cmd(audit; dir=stage), isolated_environment(stage)...),
    )
    for (name, program) in programs
        project = joinpath(stage, "environments", name)
        example = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$project $program`
        pure = name == "LibTmuxWorkspace" && basename(program) == "plan.jl"
        mode = pure ? ["--pure"] : String[]
        command = `$python $checker $mode --tmux $tmux --cwd $stage -- $example`
        started = time_ns()
        run_consumer_child(
            "$name example $(relpath(program, joinpath(stage, "source", name)))",
            addenv(Cmd(command; dir=stage), isolated_environment(stage)...),
        )
        println(
            "PASS ",
            name,
            "/",
            relpath(program, joinpath(stage, "source", name)),
            " whole_seconds=",
            round((time_ns() - started) / 1e9; digits=3),
        )
    end
    println(
        "PASS ",
        length(programs),
        " discovered examples from immutable external packages",
    )
end

function check_launchers(stage)
    check(stage; imports=false)
    for (name, script) in
        (("LibTmuxMCP", "product.jl"), ("LibTmuxWorkspace", "cli_integration.jl"))
        application_project = joinpath(stage, "environments", name)
        project = joinpath(
            stage,
            name == "LibTmuxWorkspace" ? "test-environments" : "environments",
            name,
        )
        program = joinpath(stage, "source", name, "test", script)
        command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --compile=yes -O2 --threads=1 --project=$project $program`
        started = time_ns()
        run_consumer_child(
            "$name installed launcher",
            addenv(
                Cmd(command; dir=stage),
                isolated_environment(stage)...,
                "LIBTMUX_TEST_MINIMAL_CHILD"=>"0",
                "LIBTMUX_TEST_CLI_COMPILE"=>"normal",
                "LIBTMUX_TEST_CLI_PROJECT"=>application_project,
            ),
        )
        println(
            "PASS ",
            name,
            " installed launcher from external package whole_seconds=",
            round((time_ns() - started) / 1e9; digits=3),
        )
    end
end

function main(args)
    args == ["--self-test"] && return consumer_self_test()
    length(args) == 2 && args[1] in ("prepare", "check", "examples", "launchers") || error(
        "Usage: julia dev/check-consumers.jl <prepare|check|examples|launchers> <external-stage>, or --self-test",
    )
    stage = abspath(args[2])
    ancestor = stage
    while !ispath(ancestor)
        ancestor = dirname(ancestor)
    end
    source = realpath(SOURCE_ROOT)
    resolved = joinpath(realpath(ancestor), relpath(stage, ancestor))
    (resolved == source || startswith(resolved, source * "/")) &&
        error("Consumer verification must run outside the checkout")
    operation = Dict(
        "prepare"=>prepare,
        "check"=>check,
        "examples"=>check_examples,
        "launchers"=>check_launchers,
    )[args[1]]
    operation(stage)
end

abspath(PROGRAM_FILE) == (@__FILE__) && main(ARGS)
