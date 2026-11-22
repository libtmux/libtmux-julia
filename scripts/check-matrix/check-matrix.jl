# Prepare isolated Julia tooling, then record offline quality and matrix cells.
#
# usage:
#   julia --project=. scripts/check-matrix/check-matrix.jl prepare STAGE [--julia JULIA] [--threads 1|4]
#   julia --project=. scripts/check-matrix/check-matrix.jl run STAGE [--julia JULIA] [--tmux TMUX]
#       [--threads 1|4] [--tier unit|quality|unit-quality|outer|all] [--suite all|runtime|delivery]
#       [--expected-julia V] [--expected-tmux V] [--expected-os V] [--expected-arch V]
#   julia --project=. scripts/check-matrix/check-matrix.jl artifacts STAGE
#
# `prepare` resolves the pinned tools and exports immutable consumer packages; it may
# use the network. `run` records every check offline, each phase in its own tmux
# sandbox, with bounded work and cleanup. `artifacts` writes sanitized evidence. The
# stage lives outside the checkout. The tests are in tests/runtests.jl.

module CheckMatrix

import SHA
import Sockets
import TOML
import UUIDs

include(joinpath(@__DIR__, "..", "plan-matrix", "plan-matrix.jl"))
using .PlanMatrix: PlanMatrix

const ROOT = dirname(dirname(@__DIR__))
const PINNED_TOOLS = [
    "Aqua" => "0.8.18",
    "JuliaFormatter" => "2.14.0",
    "Documenter" => "1.17.0",
    "Tables" => "1.14.0",
    "JSON" => "1.9.0",
    "YAML" => "0.4.17",
    "ModelContextProtocol" => "0.7.0",
]

# JuliaFormatter's default workload formats a copied package tree in every style.
# Keep that optional workload out of tool setup; the normal format gate still runs.
const TOOL_PREFERENCES = "[JuliaFormatter]\nprecompile_workload = false\n"

const DELIVERY_PHASES = Set([
    "extensions",
    "docs",
    "doc-snippets",
    "doc-contextual",
    "imports",
    "external-examples",
    "external-launchers",
    "readme-commands",
    "api-export",
    "api-export-check",
])

const HARD_WORK_SECONDS = 15 * 60
const SKIPPED_PATTERN = r"(?:^|\s)SKIPPED\b.*|Warning: .*\bskipped\b.*"

"A check cannot run, or its evidence cannot be trusted."
struct MatrixError <: Exception
    message::String
end
Base.showerror(io::IO, error::MatrixError) = print(io, error.message)
fail(message) = throw(MatrixError(message))

"Lines in a phase log that report a check skipped on this tmux release."
function skipped_checks(log)
    isfile(log) || return String[]
    found = String[]
    for line in eachline(log)
        matched = match(SKIPPED_PATTERN, line)
        matched === nothing && continue
        text = strip(matched.match)
        text in found || push!(found, text)
    end
    found
end

"Surface skipped checks in the result and the job summary; a skip is not a pass."
function report_skipped(result)
    skipped = [
        (item["name"], line) for item in result["phases"] for
        line in get(item, "skipped", String[])
    ]
    result["skipped_checks"] =
        [Dict("phase" => name, "detail" => line) for (name, line) in skipped]
    summary = get(ENV, "GITHUB_STEP_SUMMARY", "")
    if !isempty(skipped) && !isempty(summary)
        open(summary, "a") do io
            println(io, "### Skipped checks\n")
            for (name, line) in skipped
                println(io, "- `$name`: $line")
            end
        end
    end
end

const DIGEST_INPUTS = (
    "Project.toml",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    ".github/workflows",
    "src",
    "ext",
    "test",
    "schema",
    "docs",
    "examples",
    "packages",
    "dev",
    "benchmark",
    "scripts",
)

"A digest of every source file the checks read, so a change after preparation is caught."
function source_digest(root=ROOT)
    digest = SHA.SHA256_CTX()
    for base in DIGEST_INPUTS
        path = joinpath(root, base)
        files = String[]
        if isfile(path)
            push!(files, path)
        elseif isdir(path)
            for (directory, directories, names) in walkdir(path)
                filter!(
                    name -> !(name in ("build", "__pycache__", ".git", "node_modules")),
                    directories,
                )
                append!(files, joinpath.(directory, names))
            end
        end
        for file in sort!(files)
            islink(file) && continue
            isfile(file) || continue
            relative = relpath(file, root)
            parts = splitpath(relative)
            parts[1:min(2, end)] == ["benchmark", "results"] && continue
            name = basename(file)
            (
                startswith(name, "Manifest") ||
                endswith(name, ".log") ||
                endswith(name, ".pyc")
            ) && continue
            SHA.update!(digest, codeunits(relative))
            SHA.update!(digest, UInt8[0])
            SHA.update!(digest, read(file))
        end
    end
    bytes2hex(SHA.digest!(digest))
end

function checked_stage(path; create=false, root=ROOT)
    stage = abspath(path)
    (stage == root || startswith(stage, root * "/")) &&
        fail("the prepared stage must be outside the checkout")
    marker = joinpath(stage, ".libtmux-julia-matrix")
    if create
        mkpath(stage)
        # The workflow restores the depot cache into the stage and opens the log
        # directory before preparation, so a stage that holds only those two is still
        # a stage nobody else has used.
        if !isfile(marker) && !issubset(readdir(stage), ["depot", "logs"])
            fail("preparation requires an empty stage or an owned matrix stage")
        end
        isfile(marker) || write(marker, string(UUIDs.uuid4()))
    elseif !isfile(marker)
        fail("stage is not prepared; run prepare outside timed checks")
    end
    stage
end

# Linux reparents orphaned descendants to this runner for bounded cleanup.
function enable_subreaper()
    Sys.islinux() || return nothing
    ccall(:prctl, Cint, (Cint, Culong, Culong, Culong, Culong), 36, 1, 0, 0, 0) == 0 ||
        Base.systemerror("cannot own orphaned test descendants")
    nothing
end

const SIGINT, SIGTERM, SIGKILL = 2, 15, 9
const WNOHANG = 1

# A process that has already exited has no pid left to ask for.
function safe_pid(process::Base.Process)
    try
        getpid(process)
    catch error
        error isa Base.IOError || rethrow()
        -1
    end
end

function signal_group(process::Base.Process, number)
    pid = safe_pid(process)
    pid > 0 || return Cint(-1)
    ccall(:killpg, Cint, (Cint, Cint), pid, number)
end

# Wait for a process to exit, or for the time to pass.
function wait_for_exit(process, seconds)
    seconds > 0 || return nothing
    done = Base.Event()
    Threads.@spawn begin
        try
            wait(process)
        catch
        end
        notify(done)
    end
    timer = Timer(_ -> notify(done), seconds)
    wait(done)
    close(timer)
    nothing
end

"Stop a process group politely, then hard; return whether the leader is gone."
function retire(process::Base.Process)
    for (number, grace) in ((SIGINT, 3.0), (SIGTERM, 2.0), (SIGKILL, 5.0))
        process_running(process) || return true
        signal_group(process, number)
        wait_for_exit(process, grace)
    end
    !process_running(process)
end

function child_pids()
    pids = Int[]
    base = "/proc/$(getpid())/task"
    for task in readdir(base)
        path = joinpath(base, task, "children")
        isfile(path) && append!(pids, parse.(Int, split(read(path, String))))
    end
    unique!(pids)
end

"""
Reap only our children, including detached daemons the kernel handed to this runner
when their parent exited. A pid cannot be reused while its parent has not reaped it, so
signalling it by number is safe.
"""
function retire_orphans(budget=10.0)
    answer = Dict{String,Any}(
        "descendant_retirement" => "unverified on this platform",
        "reaped" => Int[],
        "killed" => Int[],
        "survivors" => Int[],
    )
    Sys.islinux() || return answer
    deadline = time() + budget
    status = Ref{Cint}(0)
    while true
        owned = child_pids()
        if isempty(owned)
            answer["descendant_retirement"] = "verified"
            return answer
        end
        if time() >= deadline
            answer["survivors"] = owned
            return answer
        end
        for pid in owned
            if ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, WNOHANG) > 0
                push!(answer["reaped"], pid)
                continue
            end
            ccall(:kill, Cint, (Cint, Cint), pid, SIGKILL)
            push!(answer["killed"], pid)
            ccall(:waitpid, Cint, (Cint, Ptr{Cint}, Cint), pid, status, 0) > 0 &&
                push!(answer["reaped"], pid)
        end
    end
end

"""
Run one phase: stream the original output to the console and a log, bound the work
and the cleanup independently, and check the completion receipt a native suite writes.
"""
function phase(name, argv::Vector{String}; cwd, env, log, budget, completion=false)
    start = time()
    mkpath(dirname(log))
    answer = Dict{String,Any}(
        "name" => name,
        "command" => argv,
        "status" => "NOT RUN",
        "hard_limit_seconds" => budget,
    )
    receipt = splitext(log)[1] * ".toml"
    rm(receipt; force=true)
    invocation = replace(string(UUIDs.uuid4()), "-" => "")
    temporary = mktempdir("/tmp"; prefix="ltj-check-", cleanup=false)
    child = Dict{String,String}(string(k) => string(v) for (k, v) in env)
    merge!(
        child,
        Dict(
            "JULIA_TEST_VERBOSE" => "true",
            "TMPDIR" => temporary,
            "LIBTMUX_TEST_TMPDIR" => temporary,
        ),
    )
    if completion
        child["LIBTMUX_TEST_COMPLETION"] = receipt
        child["LIBTMUX_TEST_INVOCATION"] = invocation
    else
        delete!(child, "LIBTMUX_TEST_COMPLETION")
        delete!(child, "LIBTMUX_TEST_INVOCATION")
    end
    println("PHASE START $name invocation=$invocation")
    flush(stdout)
    process = nothing
    copier = nothing
    complete = false
    try
        output = Pipe()
        command = setenv(Cmd(Cmd(argv); dir=cwd, detach=true), child)
        process = try
            run(pipeline(command; stdin=devnull, stdout=output, stderr=output); wait=false)
        catch error
            error isa Base.IOError || rethrow()
            answer["reason"] = "required executable is unavailable"
            nothing
        end
        close(output.in)
        if process !== nothing
            answer["pid"] = safe_pid(process)
            answer["invocation"] = invocation
            io = open(log, "w")
            copier = Threads.@spawn try
                while !eof(output.out)
                    chunk = readavailable(output.out)
                    write(io, chunk)
                    write(stdout, chunk)
                    flush(io)
                    flush(stdout)
                end
                true
            catch
                false
            finally
                close(io)
            end
            wait_for_exit(process, max(0.0, budget))
            if process_running(process)
                answer["status"] = "TIMEOUT"
            else
                wait(process)
                answer["status"] =
                    process.exitcode == 0 && process.termsignal == 0 ? "PASS" : "FAIL"
            end
            if completion && answer["status"] == "PASS"
                valid = try
                    report = TOML.parsefile(receipt)
                    report["invocation"] == invocation &&
                        report["pid"] == answer["pid"] &&
                        report["status"] == "PASS" &&
                        !isempty(report["files"]) &&
                        all(row -> row["outcome"] == "RETURNED", report["files"])
                catch error
                    error isa Union{
                        SystemError,
                        ErrorException,
                        TOML.ParserError,
                        KeyError,
                        TypeError,
                    } || rethrow()
                    false
                end
                valid || merge!(
                    answer,
                    Dict(
                        "status" => "INCOMPLETE",
                        "reason" => "missing, stale or incomplete test receipt",
                    ),
                )
            end
        end
    catch error
        error isa InterruptException || rethrow()
        answer["status"] = "INTERRUPTED"
    finally
        if process !== nothing
            answer["direct_child_reaped"] = retire(process)
            answer["exit_code"] = process.exitcode
        end
        if copier !== nothing
            complete = fetch(copier) === true
            answer["log_complete"] = complete
        end
        answer["cleanup"] = retire_orphans()
        cleanup = answer["cleanup"]
        if isempty(cleanup["survivors"]) && get(answer, "direct_child_reaped", true)
            rm(temporary; recursive=true, force=true)
            cleanup["temporary_directory_removed"] = true
        else
            cleanup["temporary_directory_removed"] = false
        end
        if answer["status"] == "PASS" && (
            !isempty(cleanup["killed"]) ||
            !isempty(cleanup["survivors"]) ||
            !get(answer, "log_complete", false)
        )
            merge!(
                answer,
                Dict(
                    "status" => "FAIL",
                    "reason" => "test process left descendants or incomplete output",
                ),
            )
        end
        answer["seconds"] = time() - start
        answer["log"] = log
        println(
            "PHASE END $name $(answer["status"]) $(round(answer["seconds"]; digits=3))s",
        )
        flush(stdout)
    end
    answer
end

# A client that names no socket follows an inherited TMUX to the server its caller is
# inside, and otherwise goes to the default socket under TMUX_TMPDIR. sun_path is 104
# bytes on macOS; the sandbox leaves room for /tmux-<uid>/<name>.
const SANDBOX_MAX_BYTES = 60
const SANDBOX_PREFIX = "ltj-sb-"
const SANDBOX = Ref{Union{Nothing,String}}(nothing)

selects_server(name) = name in ("TMUX", "TMUX_PANE") || startswith(name, "LIBTMUX_SOCKET")

"Make a private directory under the first root short enough for a socket path."
function make_sandbox(roots)
    for root in roots
        # The separator, the prefix and the eight characters mktemp appends.
        ncodeunits(root) + length(SANDBOX_PREFIX) + 9 <= SANDBOX_MAX_BYTES || continue
        try
            return mktempdir(root; prefix=SANDBOX_PREFIX, cleanup=false)
        catch error
            error isa SystemError || error isa Base.IOError || rethrow()
        end
    end
    fail(
        "no temporary directory is short enough for a tmux socket path; set TMPDIR to a shorter one",
    )
end

"Return this process's sandbox, made once and removed when it exits."
function matrix_sandbox()
    if SANDBOX[] === nothing
        SANDBOX[] = make_sandbox(unique([tempdir(), "/tmp"]))
        atexit(() -> remove_sandbox(SANDBOX[]))
    end
    mkpath(SANDBOX[]; mode=0o700)
    SANDBOX[]
end

"Name what keeps `env` from being the sandbox, never a value."
function sandbox_findings(env, sandbox)
    found = ["$name is set" for name in sort!(collect(keys(env))) if selects_server(name)]
    get(env, "TMUX_TMPDIR", nothing) == sandbox ||
        push!(found, "TMUX_TMPDIR is not the matrix sandbox")
    found
end

"""
List every socket below the sandbox, however a server came to be on it. A symbolic link
is not followed: the server it names is not ours to stop.
"""
function sandbox_leaks(sandbox)
    found = String[]
    for (directory, _, names) in walkdir(sandbox)
        for name in names
            path = joinpath(directory, name)
            try
                issocket(lstat(path)) && push!(found, relpath(path, sandbox))
            catch error
                error isa Base.IOError || rethrow()
            end
        end
    end
    sort!(found)
end

"Connect as a client does: only a live server accepts, or is too busy to."
function socket_answers(path)
    attempt = Threads.@spawn try
        close(Sockets.connect(path))
        true
    catch error
        error isa Base.IOError || rethrow()
        error.code in (Base.UV_EAGAIN, Base.UV_ETIMEDOUT)
    end
    timedwait(() -> istaskdone(attempt), 1.0) == :timed_out && return true
    fetch(attempt)
end

function socket_gone(path, patience=5.0)
    deadline = time() + patience
    while socket_answers(path)
        time() >= deadline && return false
        sleep(0.025)
    end
    true
end

"Remove the sandbox unless a server still answers on a socket in it."
function remove_sandbox(sandbox)
    sandbox === nothing && return nothing
    isdir(sandbox) || return nothing
    any(name -> socket_answers(joinpath(sandbox, name)), sandbox_leaks(sandbox)) ||
        rm(sandbox; recursive=true, force=true)
    nothing
end

"""
Stop the server on each socket with -S and list them, then remove the sandbox. Return
the sockets found and those whose server still answers after kill-server. The sandbox
stays while any answers.
"""
function release_sandbox(sandbox, tmux; patience=5.0)
    found = sandbox_leaks(sandbox)
    kept = String[]
    env = Dict(k => v for (k, v) in ENV if !selects_server(k))
    for relative in found
        path = joinpath(sandbox, relative)
        command = setenv(ignorestatus(`$tmux -u -N -S $path kill-server`), env)
        process = run(pipeline(command; stdout=devnull, stderr=devnull); wait=false)
        timer = Timer(patience) do _
            process_running(process) && kill(process, Base.SIGKILL)
        end
        wait(process)
        close(timer)
        socket_gone(path, patience) || push!(kept, relative)
    end
    isempty(kept) && rm(sandbox; recursive=true, force=true)
    found, kept
end

function environment(stage; offline)
    sandbox = matrix_sandbox()
    env = Dict(k => v for (k, v) in ENV if !selects_server(k))
    delete!(env, "LIBTMUX_TEST_SANDBOX")
    merge!(
        env,
        Dict(
            "JULIA_DEPOT_PATH" => joinpath(stage, "depot"),
            "JULIA_LOAD_PATH" => "@:@stdlib",
            "JULIA_PKG_OFFLINE" => offline ? "true" : "false",
            "JULIA_PKG_PRECOMPILE_AUTO" => "0",
            "TMUX_TMPDIR" => sandbox,
        ),
    )
    findings = sandbox_findings(env, sandbox)
    isempty(findings) ||
        fail("the cell environment is not a tmux sandbox: " * join(findings, "; "))
    env
end

function file_record(path, relative, copied)
    expected = bytes2hex(open(SHA.sha256, path))
    mkpath(dirname(copied))
    cp(path, copied)
    (samefile(copied, path) || bytes2hex(open(SHA.sha256, copied)) != expected) &&
        fail("copy failed independent-byte verification")
    Dict("file" => relative, "sha256" => expected, "bytes" => filesize(copied))
end

"Copy registry bytes without sharing writable files or extending DEPOT_PATH."
function seed_registry_cache(source_depot, consumer_depot)
    source = joinpath(source_depot, "registries")
    destination = joinpath(consumer_depot, "registries")
    (!isdir(source) || islink(source)) &&
        fail("quality preparation did not produce an owned registry cache")
    (ispath(destination) || islink(destination)) &&
        fail("consumer registry seeding requires an empty destination")
    entries = String[]
    for (directory, directories, names) in walkdir(source)
        append!(entries, joinpath.(directory, directories), joinpath.(directory, names))
    end
    sort!(entries)
    (
        isempty(entries) ||
        any(path -> islink(path) || !(isfile(path) || isdir(path)), entries)
    ) && fail("registry cache must contain only regular files and directories")
    records = Dict{String,Any}[]
    for path in entries
        relative = relpath(path, source)
        isdir(path) && (mkpath(joinpath(destination, relative)); continue)
        push!(records, file_record(path, relative, joinpath(destination, relative)))
    end
    records
end

"Copy completed compiled caches of the standard library, never an unfinished one."
function seed_stdlib_cache(source_depot, consumer_depot, version, modules)
    source = joinpath(source_depot, "compiled", version)
    destination = joinpath(consumer_depot, "compiled", version)
    (ispath(destination) || islink(destination)) &&
        fail("stdlib seeding requires an empty consumer cache")
    records = Dict{String,Any}[]
    for module_name in sort!(collect(modules))
        directory = joinpath(source, module_name)
        islink(directory) && fail("stdlib cache must not contain symbolic links")
        isdir(directory) || continue
        for name in sort(readdir(directory))
            path = joinpath(directory, name)
            (splitext(name)[2] in (".ji", ".so", ".dylib") && !startswith(name, "jl_")) ||
                continue
            (islink(path) || !isfile(path)) &&
                fail("stdlib cache must contain regular completed files")
            relative = relpath(path, source)
            push!(records, file_record(path, relative, joinpath(destination, relative)))
        end
    end
    records
end

function stdlib_cache_profile(julia, env)
    program = """println(VERSION)
    println("v", VERSION.major, ".", VERSION.minor)
    foreach(println, filter(name -> isdir(joinpath(Sys.STDLIB, name)), readdir(Sys.STDLIB)))
    """
    lines = readlines(setenv(`$julia --startup-file=no --history-file=no -e $program`, env))
    Dict("julia" => lines[1], "version" => lines[2], "modules" => lines[3:end])
end

const PREPARE_PROGRAM = raw"""
using Pkg
root, project = ARGS[1:2]
Pkg.activate(project)
Pkg.develop([PackageSpec(path=root),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxWorkspace")),
             PackageSpec(path=joinpath(root, "packages", "LibTmuxMCP"))])
packages = [PackageSpec(name=String(first(pair)), version=VersionNumber(last(pair)))
            for pair in (split(argument, '='; limit=2) for argument in ARGS[3:end])]
Pkg.add(packages)
resolved = values(Pkg.dependencies())
for package in packages
    any(info -> info.name == package.name && info.version == package.version, resolved) ||
        error("resolved quality tool differs from its admitted version: " * package.name)
end
Pkg.precompile()
"""

format_warmup_command(julia, threads, project) = [
    julia,
    "--startup-file=no",
    "--threads=$threads",
    "--project=$project",
    joinpath(ROOT, "dev/check-quality.jl"),
    "format",
]

function runcheck(argv, env; cwd=ROOT)
    success(pipeline(setenv(Cmd(Cmd(argv); dir=cwd), env); stdout=stdout, stderr=stderr)) ||
        fail("command failed: $(join(argv, ' '))")
end

function prepare(stage_path; julia="julia", threads=1)
    started_preparation = time()
    stage = checked_stage(stage_path; create=true)
    initial_digest = source_digest()
    project = joinpath(stage, "environment")
    mkpath(project)
    write(joinpath(project, "LocalPreferences.toml"), TOOL_PREFERENCES)
    env = environment(stage; offline=false)
    tools = ["$name=$version" for (name, version) in PINNED_TOOLS]
    # Preparation is a separate tier: package resolution, network and precompilation.
    runcheck(
        [
            julia,
            "--startup-file=no",
            "--project=$project",
            "-e",
            PREPARE_PROGRAM,
            ROOT,
            project,
            tools...,
        ],
        env,
    )
    runcheck(
        [
            julia,
            "--startup-file=no",
            "--compile=min",
            "-O0",
            "--project=$project",
            "-e",
            "using Aqua, LibTmux, LibTmuxWorkspace, LibTmuxMCP, ModelContextProtocol, JSON, Tables",
        ],
        env,
    )
    runcheck(
        format_warmup_command(julia, threads, project),
        environment(stage; offline=true),
    )
    consumers = joinpath(stage, "consumers-" * replace(string(UUIDs.uuid4()), "-" => ""))
    started = time()
    registry_files =
        seed_registry_cache(joinpath(stage, "depot"), joinpath(consumers, "depot"))
    registry_seed = Dict("seconds" => time() - started, "files" => registry_files)
    started = time()
    profile = stdlib_cache_profile(julia, env)
    stdlib_files = seed_stdlib_cache(
        joinpath(stage, "depot"),
        joinpath(consumers, "depot"),
        profile["version"],
        profile["modules"],
    )
    stdlib_seed =
        Dict("seconds" => time() - started, "profile" => profile, "files" => stdlib_files)
    runcheck(
        [
            julia,
            "--startup-file=no",
            "--compile=yes",
            "-O2",
            joinpath(ROOT, "dev/check-consumers.jl"),
            "prepare",
            consumers,
        ],
        env,
    )
    initial_digest == source_digest() || fail(
        "source changed during preparation; rerun with stable source (dependency cache retained)",
    )
    metadata = Dict{String,Any}(
        "schema_version" => 1,
        "source_digest" => initial_digest,
        "tools" => Dict(PINNED_TOOLS),
        "seconds" => time() - started_preparation,
        "consumers" => consumers,
        "project" => project,
        "registry_seed" => registry_seed,
        "stdlib_seed" => stdlib_seed,
        "tool_preferences" => TOML.parse(TOOL_PREFERENCES),
    )
    open(joinpath(stage, "prepared.toml"), "w") do io
        TOML.print(io, metadata)
    end
    println(
        "PASS prepared dependencies and immutable external consumers; no timed checks run",
    )
end

"""
The phases of a cell as (name, argv, target seconds, tier). The target is a
diagnostic, not a limit; the hard limit is the cell's remaining work time.
"""
function command_plan(julia, threads, project, consumers)
    normal = [julia, "--startup-file=no", "--threads=$threads", "--project=$project"]
    minimal = [normal; "--compile=min"; "-O0"]
    commands = Tuple{String,Vector{String},Float64,String}[]
    add(name, argv, budget, tier) = push!(commands, (name, argv, budget, tier))
    add("core-unit", [minimal; "test/runtests.jl"; "unit"], 30, "unit")
    add(
        "workspace-unit",
        [minimal; "packages/LibTmuxWorkspace/test/runtests.jl"; "unit"],
        30,
        "unit",
    )
    add("mcp-unit", [minimal; "packages/LibTmuxMCP/test/runtests.jl"; "unit"], 30, "unit")
    add("quality", [minimal; "dev/check-quality.jl"; "quality"], 30, "quality")
    add("format", [normal; "dev/check-quality.jl"; "format"], 30, "quality")
    add("generated", [minimal; "dev/generate-criteria.jl"; "--check"], 30, "quality")
    add("generated-options", [minimal; "dev/generate-options.jl"; "--check"], 30, "quality")
    add(
        "consumer-diagnostics",
        [minimal; "dev/check-consumers.jl"; "--self-test"],
        30,
        "quality",
    )
    add("test-progress", [minimal; "dev/test-progress.jl"; julia], 30, "quality")
    add("example-inventory", [minimal; "dev/check-doc-examples.jl"; "check"], 30, "quality")
    add("readme-links", [minimal; "dev/check-readme-commands.jl"; "static"], 30, "quality")
    add("core-normal", [normal; "test/runtests.jl"; "all"], 300, "outer")
    add(
        "workspace-normal",
        [normal; "packages/LibTmuxWorkspace/test/runtests.jl"; "all"],
        300,
        "outer",
    )
    add("mcp-normal", [normal; "packages/LibTmuxMCP/test/runtests.jl"; "all"], 300, "outer")
    add("mcp-product", [normal; "packages/LibTmuxMCP/test/product.jl"], 300, "outer")
    add(
        "mcp-stopped-reader",
        [normal; "packages/LibTmuxMCP/test/stdio_backpressure.jl"],
        300,
        "outer",
    )
    add(
        "script-example-cleanup",
        [normal; "scripts/check-example-cleanup/tests/runtests.jl"],
        300,
        "outer",
    )
    extensions = "using Test, LibTmux; include(\"test/criteria.jl\"); include(\"test/json_extension.jl\"); include(\"test/tables_extension.jl\")"
    add("extensions", [normal; "-e"; extensions], 300, "outer")
    add("docs", [normal; "docs/make.jl"], 300, "outer")
    add("api-export", [normal; "docs/export-api.jl"], 300, "outer")
    add("api-export-check", [normal; "docs/test-export-api.jl"], 300, "outer")
    add("doc-snippets", [normal; "dev/check-doc-examples.jl"; "doctest"], 300, "outer")
    add("doc-contextual", [normal; "dev/check-doc-examples.jl"; "contextual"], 300, "outer")
    add("imports", [minimal; "dev/check-consumers.jl"; "check"; consumers], 300, "outer")
    add(
        "external-examples",
        [minimal; "dev/check-consumers.jl"; "examples"; consumers],
        300,
        "outer",
    )
    add(
        "external-launchers",
        [minimal; "dev/check-consumers.jl"; "launchers"; consumers],
        300,
        "outer",
    )
    add(
        "readme-commands",
        [normal; "dev/check-readme-commands.jl"; "commands"],
        300,
        "outer",
    )
    commands
end

function selected_commands(commands; tier="all", suite="all")
    [
        item for item in commands if (
            tier == "all" ||
            item[4] == tier ||
            (tier == "unit-quality" && item[4] in ("unit", "quality"))
        ) && (suite == "all" || (item[1] in DELIVERY_PHASES) == (suite == "delivery"))
    ]
end

# Write a record that other processes read, never half written.
function save_record(path, record)
    temporary = path * ".tmp"
    open(io -> TOML.print(io, record), temporary, "w")
    mv(temporary, path; force=true)
end

version_output(argv, env) = strip(read(setenv(Cmd(argv), env), String))

"""
Run the selected phases of a prepared cell offline and record the result. The keyword
arguments let the tests stand in the work they do not exercise.
"""
function run_matrix(
    stage_path;
    julia="julia",
    tmux="tmux",
    threads=1,
    tier="all",
    suite="all",
    expected=Dict{String,String}(),
    digest=source_digest,
    plan=command_plan,
    run_phase=phase,
    env_for=environment,
)
    enable_subreaper()
    stage = checked_stage(stage_path)
    metadata = TOML.parsefile(joinpath(stage, "prepared.toml"))
    metadata["source_digest"] == digest() || fail(
        "source changed since preparation; prepare a fresh source snapshot before checks",
    )
    preferences = joinpath(metadata["project"], "LocalPreferences.toml")
    TOML.parsefile(preferences) == metadata["tool_preferences"] ||
        fail("tool preferences changed since preparation; prepare a fresh stage")
    env = env_for(stage; offline=true)
    merge!(
        env,
        Dict(
            "LIBTMUX_TEST_TMUX" => tmux,
            "LIBTMUX_TEST_CLI_COMPILE" => "normal",
            "LIBTMUX_TEST_MINIMAL_CHILD" => "0",
            "JULIA_TEST_VERBOSE" => "true",
        ),
    )
    work_seconds = Float64(HARD_WORK_SECONDS)
    haskey(env, "MATRIX_JOB_DEADLINE") && (
        work_seconds = min(
            work_seconds,
            max(0.0, parse(Float64, env["MATRIX_JOB_DEADLINE"]) - time() - 180),
        )
    )
    deadline = time() + work_seconds
    phases = Dict{String,Any}[]
    invocation = replace(string(UUIDs.uuid4()), "-" => "")
    result = Dict{String,Any}(
        "schema_version" => 2,
        "source_digest" => metadata["source_digest"],
        "platform" => string(Sys.KERNEL),
        "machine" => string(Sys.ARCH),
        "kernel" => string(Sys.KERNEL),
        "wsl" =>
            Sys.islinux() && occursin(
                "microsoft",
                lowercase(read("/proc/sys/kernel/osrelease", String)),
            ),
        "threads" => threads,
        "tools" => metadata["tools"],
        "status" => "NOT RUN",
        "phases" => phases,
        "suite" => suite,
        "tier" => tier,
        "active_phase" => "",
        "invocation" => invocation,
        "hard_work_seconds" => work_seconds,
        "preparation_seconds" => get(metadata, "seconds", 0.0),
    )
    suffix = suite == "all" ? "" : "-$suite"
    destination = joinpath(stage, "results-$tier$suffix-t$threads-$(invocation[1:8]).toml")
    logs = joinpath(stage, "logs", invocation)
    save() = save_record(destination, result)
    save()
    missing_tool = nothing
    for (key, argv) in
        (("julia", [julia, "--startup-file=no", "--version"]), ("tmux", [tmux, "-V"]))
        if Sys.which(argv[1]) === nothing
            result["reason"] = "$key executable is unavailable"
            missing_tool = key
            break
        end
        result[key] = version_output(argv, env)
    end
    if missing_tool === nothing
        checks = (
            (
                get(expected, "julia", ""),
                replace(result["julia"], "julia version " => ""),
                "Julia",
            ),
            (get(expected, "tmux", ""), replace(result["tmux"], "tmux " => ""), "tmux"),
            (get(expected, "os", ""), result["platform"], "OS"),
            (get(expected, "arch", ""), result["machine"], "architecture"),
        )
        mismatch = findfirst(item -> !isempty(item[1]) && item[1] != item[2], checks)
        if mismatch !== nothing
            result["reason"] = "observed $(checks[mismatch][3]) differs from the requested cell"
        else
            commands = selected_commands(
                plan(julia, threads, metadata["project"], metadata["consumers"]);
                tier,
                suite,
            )
            result["status"] = "RUNNING"
            result["planned_phases"] = [item[1] for item in commands]
            try
                for (name, argv, budget, _) in commands
                    result["active_phase"] = name
                    save()
                    remaining = deadline - time()
                    if remaining <= 0
                        merge!(
                            result,
                            Dict(
                                "status" => "TIMEOUT",
                                "reason" => "hard work limit reached",
                            ),
                        )
                        break
                    end
                    native = any(
                        argument ->
                            endswith(argument, "/test/runtests.jl") ||
                            argument == "test/runtests.jl",
                        argv,
                    )
                    item = run_phase(
                        name,
                        argv;
                        cwd=ROOT,
                        env,
                        log=joinpath(logs, "$name.log"),
                        budget=remaining,
                        completion=native,
                    )
                    item["target_seconds"] = Float64(budget)
                    item["over_target"] = item["seconds"] > budget
                    item["skipped"] = skipped_checks(joinpath(logs, "$name.log"))
                    push!(phases, item)
                    result["active_phase"] = ""
                    save()
                    println("$(item["status"]) $name $(round(item["seconds"]; digits=3))s")
                    flush(stdout)
                    for line in item["skipped"]
                        println("::warning title=Skipped in $name::$line")
                        flush(stdout)
                    end
                    if item["status"] in ("TIMEOUT", "INTERRUPTED") ||
                       !isempty(item["cleanup"]["survivors"])
                        result["status"] = item["status"]
                        break
                    end
                end
                report_skipped(result)
                leaked, kept = release_sandbox(env["TMUX_TMPDIR"], tmux)
                result["sandbox_leaks"] = leaked
                result["sandbox_kept"] = kept
                for relative in leaked
                    println(
                        "::error title=tmux sandbox::a socket was left at $relative",
                        relative in kept ?
                        "; its server still answers and the sandbox was kept" : "",
                    )
                    flush(stdout)
                end
                completed = Set(item["name"] for item in phases)
                result["not_run"] =
                    [name for (name, _...) in commands if !(name in completed)]
                if result["status"] == "RUNNING"
                    result["status"] =
                        isempty(result["not_run"]) &&
                        isempty(leaked) &&
                        !isempty(phases) &&
                        all(p -> p["status"] == "PASS", phases) ? "PASS" : "FAIL"
                end
                metadata["source_digest"] == digest() || merge!(
                    result,
                    Dict("status" => "STALE", "reason" => "source changed during checks"),
                )
            catch error
                result["status"] = error isa InterruptException ? "INTERRUPTED" : "FAIL"
                result["error_type"] = string(typeof(error))
                rethrow()
            finally
                save()
            end
        end
    end
    save()
    println("$(result["status"]) matrix result: $destination")
    result["status"] == "PASS" ? 0 : 1
end

"Export readable evidence without local paths or known credential values."
function artifacts(stage_path; root=ROOT, home=homedir())
    stage = checked_stage(stage_path)
    destination = joinpath(stage, "artifacts")
    mkpath(destination)
    deadline = time() + 30
    replacements = Pair{String,String}[stage=>"<stage>", root=>"<checkout>", home=>"<home>"]
    for (path, replacement) in collect(replacements)
        startswith(path, home * "/") &&
            push!(replacements, replace(path, home => "~"; count=1) => replacement)
    end
    push!(replacements, "~/" => "<home>/")
    for (key, value) in ENV
        occursin(r"TOKEN|SECRET|PASSWORD|CREDENTIAL", key) &&
            length(value) >= 8 &&
            push!(replacements, value => "<redacted>")
    end
    sort!(replacements; by=pair -> length(first(pair)), rev=true)
    sanitize(text) = foldl((text, pair) -> replace(text, pair), replacements; init=text)
    sources = String[]
    for (directory, _, names) in walkdir(stage)
        startswith(directory, destination) && continue
        for name in names
            path = joinpath(directory, name)
            relative = relpath(path, stage)
            (
                    startswith(name, "results-") &&
                    endswith(name, ".toml") &&
                    dirname(relative) == ""
                ) ||
                name == "prepared.toml" && dirname(relative) == "" ||
                (
                    startswith(relative, "logs/") &&
                    (endswith(name, ".log") || endswith(name, ".toml"))
                ) ||
                continue
            push!(sources, path)
        end
    end
    incomplete = String[]
    for source in sources
        exported = joinpath(destination, relpath(source, stage))
        mkpath(dirname(exported))
        open(exported, "w") do output
            for line in eachline(source; keep=true)
                if time() >= deadline
                    push!(incomplete, basename(source))
                    write(output, "\nARTIFACT EXPORT INTERRUPTED: finalization deadline\n")
                    break
                end
                write(output, sanitize(line))
            end
        end
    end
    rows = Dict{String,Any}[]
    summary = String[]
    receipts = Dict{String,Tuple{String,Int}}()
    for source in sources
        name = basename(source)
        (startswith(name, "results-") && dirname(relpath(source, stage)) == "") || continue
        result = TOML.parsefile(source)
        push!(
            summary,
            "$name: $(result["status"])\n",
            "Preparation: $(get(result, "preparation_seconds", ""))seconds\n",
        )
        isempty(get(result, "active_phase", "")) ||
            push!(summary, "  INCOMPLETE $(result["active_phase"])\n")
        for item in result["phases"]
            if haskey(item, "log") && haskey(item, "invocation")
                receipts[splitext(item["log"])[1]*".toml"] =
                    (item["invocation"], item["pid"])
            end
            push!(
                rows,
                Dict(
                    "name" => item["name"],
                    "status" => item["status"],
                    "seconds" => item["seconds"],
                    "target" => get(item, "target_seconds", ""),
                ),
            )
            push!(
                summary,
                "  $(item["status"]) $(item["name"]): $(round(item["seconds"]; digits=3))s" *
                (get(item, "over_target", false) ? " (over diagnostic target)" : "") *
                "\n",
            )
        end
        for name in get(result, "not_run", String[])
            push!(summary, "  NOT RUN $name\n")
        end
    end
    for source in sources
        (startswith(relpath(source, stage), "logs/") && endswith(source, ".toml")) ||
            continue
        try
            receipt = TOML.parsefile(source)
            if get(receipts, source, nothing) !=
               (get(receipt, "invocation", nothing), get(receipt, "pid", nothing))
                push!(summary, "Unmatched test receipt: $(basename(source))\n")
                continue
            end
            for row in receipt["files"]
                push!(
                    rows,
                    Dict(
                        "name" => row["file"],
                        "status" => row["outcome"],
                        "seconds" => row["seconds"],
                        "target" => "",
                    ),
                )
            end
        catch error
            error isa Union{ErrorException,TOML.ParserError,KeyError} || rethrow()
            push!(summary, "Incomplete test receipt: $(basename(source))\n")
        end
    end
    open(joinpath(destination, "timings.csv"), "w") do io
        println(io, "name,status,seconds,target_seconds")
        for row in sort(rows; by=row -> row["seconds"], rev=true)
            println(
                io,
                join((row["name"], row["status"], row["seconds"], row["target"]), ","),
            )
        end
    end
    push!(
        summary,
        "File and command timings overlap; add neither to their enclosing command.\n",
    )
    isempty(incomplete) ||
        push!(summary, "Incomplete artifact exports: $(join(incomplete, ", "))\n")
    rendered = sanitize(join(summary))
    write(joinpath(destination, "summary.txt"), rendered)
    if haskey(ENV, "GITHUB_STEP_SUMMARY")
        open(ENV["GITHUB_STEP_SUMMARY"], "a") do io
            print(io, "```text\n", rendered, "```\n")
        end
    end
    print(rendered)
    isempty(incomplete) ? 0 : 1
end

const USAGE = """
usage: check-matrix.jl prepare STAGE [--julia JULIA] [--threads 1|4]
       check-matrix.jl run STAGE [--julia JULIA] [--tmux TMUX] [--threads 1|4]
           [--tier unit|quality|unit-quality|outer|all] [--suite all|runtime|delivery]
           [--expected-julia V] [--expected-tmux V] [--expected-os V] [--expected-arch V]
       check-matrix.jl artifacts STAGE"""

function main(arguments=ARGS)
    try
        length(arguments) >= 2 && arguments[1] in ("prepare", "run", "artifacts") ||
            fail(USAGE)
        command, stage = arguments[1:2]
        options = Dict{String,String}()
        rest = arguments[3:end]
        while !isempty(rest)
            (length(rest) >= 2 && startswith(rest[1], "--")) || fail(USAGE)
            options[rest[1]] = rest[2]
            rest = rest[3:end]
        end
        threads = parse(Int, get(options, "--threads", "1"))
        threads in (1, 4) || fail("--threads must be 1 or 4")
        julia = get(options, "--julia", "julia")
        if command == "prepare"
            prepare(stage; julia, threads)
        elseif command == "artifacts"
            return artifacts(stage)
        else
            tier = get(options, "--tier", "all")
            suite = get(options, "--suite", "all")
            tier in ("unit", "quality", "unit-quality", "outer", "all") ||
                fail("--tier must be unit, quality, unit-quality, outer or all")
            suite in ("all", PlanMatrix.SUITES...) ||
                fail("--suite must be all, runtime or delivery")
            expected = Dict(
                name => get(options, "--expected-$name", "") for
                name in ("julia", "tmux", "os", "arch")
            )
            return run_matrix(
                stage;
                julia,
                tmux=get(options, "--tmux", "tmux"),
                threads,
                tier,
                suite,
                expected,
            )
        end
    catch error
        error isa MatrixError ||
            error isa SystemError ||
            error isa ProcessFailedException ||
            rethrow()
        println(stderr, "NOT RUN: ", sprint(showerror, error))
        return 2
    end
    0
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(CheckMatrix.main(ARGS))
