# Measure fresh-process startup of the core package; prepare dependencies first.
#
# usage:
#   julia --project=benchmark scripts/bench-startup/bench-startup.jl [--julia JULIA]
#       [--tmux TMUX] [--project DIR] [--profiles normal,o0,minimal] [--samples 1:10]
#       [--threads 1|4] [--seed N] [--budget SECONDS] [--process-budget SECONDS]
#       [--output FILE]
#
# Runs benchmark/startup.jl, and a bare Julia baseline, in fresh processes in a seeded
# random order. Each process leads its own group, is observed to exit before it is
# reaped, and is retired as a group. The driver keeps its output, bounded, with the
# `wait4` accounting. The report is written after every sample and refuses to replace
# an existing file. The tests are in tests/runtests.jl.

module BenchStartup

import Base64
import JSON
import Random
import SHA
import TOML

include(joinpath(@__DIR__, "..", "owned-process", "owned-process.jl"))
using .OwnedProcess

const ROOT = dirname(dirname(@__DIR__))
const PROFILES =
    Dict("normal" => String[], "o0" => ["-O0"], "minimal" => ["--compile=min", "-O0"])
const OUTPUT_LIMIT = 1024 * 1024
# Linux counts the address space a child inherited from its spawner in `ru_maxrss`, so
# the baseline also prints /proc/self/status, whose VmHWM covers only its own. One
# statement keeps the peak at that of a bare Julia process.
const BASELINE = raw"""
println("LTJ_STARTUP_BASELINE\t", VERSION, "\t", Threads.nthreads(), "\t", Sys.maxrss(), "\n", isfile("/proc/self/status") ? read("/proc/self/status", String) : "")
"""

"The command line cannot be turned into a measurement."
struct UsageError <: Exception
    message::String
end
Base.showerror(io::IO, error::UsageError) = print(io, error.message)

# Signal names the report uses.
const SIGINT = Base.SIGINT
const SIGKILL = Base.SIGKILL

"""
    observe(command, environment, deadline; grace=0.9, limit=OUTPUT_LIMIT) -> Dict

Run `command` as the leader of its own process group, with no stdin, and return what
happened as a report. `deadline` is a `monotonic()` time. The exit is observed without
reaping, so the group number stays ours while the owned group receives its final
SIGKILL; only then are the pipes drained and the child collected with `wait4`. At the
deadline, or past `limit` bytes of output, the group gets SIGINT and, after `grace`
seconds, SIGKILL. A deadline already past starts nothing.
"""
function observe(
    command,
    environment,
    deadline::Real;
    grace::Real=0.9,
    limit::Integer=OUTPUT_LIMIT,
)
    started = time_ns()
    result = Dict{String,Any}(
        "command" => collect(String, command),
        "status" => "running",
        "direct_child_reaped" => false,
        "termination_signal" => nothing,
    )
    captured = Dict("stdout" => UInt8[], "stderr" => UInt8[])
    counts = Dict("stdout" => 0, "stderr" => 0)
    eof = Dict("stdout" => false, "stderr" => false)
    child = nothing
    stop_reason = nothing
    stop_deadline = nothing
    elapsed() = Int(time_ns() - started)

    function request_stop(reason)
        if stop_reason === nothing
            stop_reason = reason
            stop_deadline = monotonic() + grace
            result["termination_signal"] = "SIGINT"
            signal_group(child, SIGINT)
        end
    end

    # One non-blocking read. False means nothing was there, or the stream ended.
    function read_stream(name, fd)
        chunk = read_available(fd)
        chunk === nothing && return false
        if isempty(chunk)
            eof[name] = true
            return false
        end
        haskey(result, "first_output_ns") || (result["first_output_ns"] = elapsed())
        counts[name] += length(chunk)
        room = max(0, limit - length(captured[name]))
        append!(captured[name], view(chunk, 1:min(room, length(chunk))))
        counts[name] > limit && request_stop("output_limit")
        true
    end

    try
        if monotonic() >= deadline
            result["status"] = "not_started_deadline"
            return result
        end
        result["spawner_max_rss_bytes"] = Sys.maxrss()
        child = spawn_child(command; env=environment, stdin=:null, group=true)
        result["spawn_ns"] = elapsed()
        streams = Dict("stdout" => child.stdout, "stderr" => child.stderr)
        while !child.exited
            now = monotonic()
            stop_reason === nothing && now >= deadline && request_stop("deadline")
            if stop_deadline !== nothing && now >= stop_deadline
                result["termination_signal"] = "SIGKILL"
                signal_group(child, SIGKILL)
                stop_deadline = nothing
            end
            next_deadline = stop_reason === nothing ? deadline : stop_deadline
            timeout = next_deadline === nothing ? -1.0 : max(0.0, next_deadline - now)
            owners = Dict(fd => name for (name, fd) in streams)
            entries = [
                PollFD(child.wake_read, POLLIN, 0)
                [PollFD(fd, POLLIN, 0) for fd in sort!(collect(keys(owners)))]
            ]
            poll!(entries, timeout)
            for entry in entries
                entry.revents == 0 && continue
                if entry.fd == child.wake_read
                    drain_wake(child)
                else
                    name = owners[entry.fd]
                    read_stream(name, entry.fd)
                    eof[name] && delete!(streams, name)
                end
            end
        end
    catch error
        if error isa InterruptException
            stop_reason = "interrupted"
        elseif error isa SystemError
            stop_reason = child === nothing ? "spawn_error" : "driver_error"
            result["error_type"] = string(nameof(typeof(error)))
        else
            rethrow()
        end
    finally
        if child !== nothing
            if stop_reason == "interrupted"
                result["termination_signal"] = "SIGINT"
                signal_group(child, SIGINT)
                wait_exit(child, grace) || (result["termination_signal"] = "SIGKILL")
            end
            # The direct child is still unreaped, so its group number cannot be reused
            # while this run sends the final signal to the group it owns.
            signal_group(child, SIGKILL)
            wait(child.watcher)
            for (name, fd) in (("stdout", child.stdout), ("stderr", child.stderr))
                # An escaped descendant may keep writing: never wait for an EOF this
                # run cannot own.
                for _ = 1:16
                    (eof[name] || !read_stream(name, fd)) && break
                end
            end
            code, usage = reap!(child)
            result["exit_code"] = code
            result["direct_child_reaped"] = true
            result["owned_group_retirement_signal"] = "SIGKILL"
            result["wait4_max_rss_bytes"] = usage.max_rss_bytes
            result["user_cpu_seconds"] = usage.user_seconds
            result["system_cpu_seconds"] = usage.system_seconds
            child.exit_ns === nothing ||
                (result["exit_observed_ns"] = Int(child.exit_ns - started))
            foreach(
                close_fd,
                (child.stdout, child.stderr, child.wake_read, child.wake_write),
            )
            result["status"] =
                stop_reason === nothing ? (code != 0 ? "failed" : "pass") : stop_reason
            if child.watch_error !== nothing
                result["status"] = "driver_error"
                result["watcher_errors"] = [child.watch_error]
            end
        elseif stop_reason !== nothing
            result["status"] = stop_reason
        end
        result["stdout"] = captured["stdout"]
        result["stderr"] = captured["stderr"]
        result["observed_bytes"] = counts
        result["pipe_eof"] = eof
        result["whole_ns"] = elapsed()
    end
    result
end

function source_hashes(root=ROOT)
    files = [
        joinpath(root, name) for name in (
            "Project.toml",
            "benchmark/Project.toml",
            "benchmark/startup.jl",
            "scripts/bench-startup/bench-startup.jl",
            "scripts/owned-process/owned-process.jl",
        )
    ]
    for directory in ("src", "ext")
        for (parent, _, names) in walkdir(joinpath(root, directory)), name in sort(names)
            endswith(name, ".jl") && push!(files, joinpath(parent, name))
        end
    end
    Dict(relpath(path, root) => bytes2hex(open(SHA.sha256, path)) for path in sort!(files))
end

"Read the phase records and the TOML measurement out of a sample's stdout."
function decode_sample!(result, kind)
    stdout = String(copy(result["stdout"]))
    rows = Dict{String,Any}[]
    high_water = nothing
    for line in split(stdout, '\n'; keepempty=false)
        fields = split(line, '\t')
        if kind == "baseline" && length(fields) == 2 && fields[1] == "VmHWM:"
            high_water = 1024 * parse(Int, first(split(fields[2])))
        elseif length(fields) == 6 && fields[1] == "LTJ_STARTUP_PHASE"
            push!(
                rows,
                Dict(
                    "name" => fields[2],
                    "status" => fields[3],
                    "elapsed_ns" => parse(Int, fields[4]),
                    "from_script_entry_ns" => parse(Int, fields[5]),
                    "max_rss_bytes" => parse(Int, fields[6]),
                ),
            )
        elseif kind == "baseline" &&
               length(fields) == 4 &&
               fields[1] == "LTJ_STARTUP_BASELINE"
            result["baseline"] = Dict(
                "julia" => fields[2],
                "threads" => parse(Int, fields[3]),
                "max_rss_bytes" => parse(Int, fields[4]),
            )
        end
    end
    # Where /proc reports it, VmHWM replaces the figure a large spawner can inflate.
    if high_water !== nothing && haskey(result, "baseline")
        result["baseline"]["max_rss_bytes"] = high_water
    end
    result["phase_records"] = rows
    begin_marker, end_marker = "LTJ_STARTUP_TOML_BEGIN\n", "LTJ_STARTUP_TOML_END\n"
    if occursin(begin_marker, stdout) && occursin(end_marker, stdout)
        body = first(split(last(split(stdout, begin_marker; limit=2)), end_marker; limit=2))
        result["measurement"] = TOML.parse(body)
    end
    if result["status"] == "pass"
        valid = if kind == "baseline"
            haskey(result, "baseline")
        else
            get(get(result, "measurement", Dict()), "status", nothing) == "pass"
        end
        valid || (result["status"] = "invalid_measurement")
    end
    result
end

const USAGE = """
usage: bench-startup.jl [--julia JULIA] [--tmux TMUX] [--project DIR]
           [--profiles normal,o0,minimal] [--samples 1:10] [--threads 1|4] [--seed N]
           [--budget SECONDS] [--process-budget SECONDS] [--output FILE]"""

"""
    options(arguments) -> NamedTuple

Parse and bound the command line. Anything else is a `UsageError`.
"""
function options(arguments)
    values = Dict(
        "--julia" => "julia",
        "--tmux" => get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
        "--project" => joinpath(ROOT, "benchmark"),
        "--profiles" => "normal",
        "--samples" => "3",
        "--threads" => "1",
        "--seed" => "2026",
        "--budget" => "480",
        "--process-budget" => "120",
        "--output" => joinpath(ROOT, "benchmark", "results", "startup.json"),
    )
    rest = collect(String, arguments)
    seen = Set{String}()
    while !isempty(rest)
        name = popfirst!(rest)
        haskey(values, name) && !isempty(rest) ||
            throw(UsageError("unknown option or missing value: $name"))
        name in seen && throw(UsageError("duplicate option: $name"))
        push!(seen, name)
        values[name] = popfirst!(rest)
    end
    function number(type, name)
        value = tryparse(type, values[name])
        value === nothing && throw(UsageError("$name must be a number"))
        value
    end
    profiles = String.(split(values["--profiles"], ','))
    (
        !isempty(profiles) &&
        length(unique(profiles)) == length(profiles) &&
        all(name -> haskey(PROFILES, name), profiles)
    ) || throw(UsageError("profiles must be distinct normal,o0,minimal names"))
    samples = number(Int, "--samples")
    1 <= samples <= 10 || throw(UsageError("samples must be in 1:10"))
    threads = number(Int, "--threads")
    threads in (1, 4) || throw(UsageError("threads must be 1 or 4"))
    budget = number(Float64, "--budget")
    (isfinite(budget) && 0 < budget <= 540) ||
        throw(UsageError("budget must be in (0,540] seconds"))
    process_budget = number(Float64, "--process-budget")
    (isfinite(process_budget) && 0 < process_budget <= 180) ||
        throw(UsageError("process-budget must be in (0,180] seconds"))
    (;
        julia=values["--julia"],
        tmux=values["--tmux"],
        project=values["--project"],
        profiles,
        samples,
        threads,
        seed=number(Int, "--seed"),
        budget,
        process_budget,
        output=values["--output"],
    )
end

sha256_file(path) = bytes2hex(open(SHA.sha256, path))

"The measurement jobs, in the seeded order a run uses."
function job_order(profiles, samples, seed)
    jobs = [
        (iteration, profile, kind) for iteration = 1:samples for profile in profiles for
        kind in ("baseline", "core")
    ]
    Random.shuffle!(Random.MersenneTwister(seed), jobs)
end

function child_command(args, profile, kind)
    command = [
        args.julia,
        "--startup-file=no",
        "--history-file=no",
        "--threads=$(args.threads)",
        "--project=$(abspath(args.project))",
        PROFILES[profile]...,
    ]
    append!(
        command,
        kind == "baseline" ? ["-e", BASELINE] : [joinpath(ROOT, "benchmark", "startup.jl")],
    )
    command
end

function main(arguments=ARGS)
    args = try
        options(arguments)
    catch error
        error isa UsageError || rethrow()
        println(stderr, "bench-startup: ", error.message)
        println(stderr, USAGE)
        return 2
    end
    started = monotonic()
    deadline = started + args.budget
    mkpath(dirname(abspath(args.output)))
    # An exclusive create: existing measurements are preserved.
    evidence = Base.Filesystem.open(
        abspath(args.output),
        Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT |
        Base.Filesystem.JL_O_EXCL,
        0o644,
    )
    status = try
        run_samples(evidence, args, started, deadline)
    finally
        close(evidence)
    end
    status == "pass" ? 0 : 1
end

function run_samples(evidence, args, started, deadline)
    hashes = source_hashes()
    project = abspath(args.project)
    project_files = [
        path for
        path in (joinpath(project, "Project.toml"), joinpath(project, "Manifest.toml")) if
        isfile(path)
    ]
    report = Dict{String,Any}(
        "schema_version" => 1,
        "status" => "running",
        "source_sha256" => hashes,
        "driver_julia" => string(VERSION),
        "platform" => string(Sys.KERNEL),
        "machine" => string(Sys.ARCH),
        "project_files_sha256" =>
            Dict(path => sha256_file(path) for path in project_files),
        "executables" =>
            Dict("julia" => Sys.which(args.julia), "tmux" => Sys.which(args.tmux)),
        "tmux_version_status" => "not_started_deadline",
        "load_average_start" => Sys.loadavg(),
        "profiles" => Dict(name => PROFILES[name] for name in args.profiles),
        "threads" => args.threads,
        "seed" => args.seed,
        "repetitions" => args.samples,
        "budget_seconds" => args.budget,
        "process_budget_seconds" => args.process_budget,
        "samples" => Dict{String,Any}[],
        "limitations" => [
            "Fresh processes; dependency and OS caches are not flushed",
            "No runtime warmup, package resolution, or core deadline overrides",
            "Baseline executes only Base output and RSS metadata",
            "Package load excludes SHA setup; TOML reporting follows measured teardown",
            "Whole process includes reporting, imports, compilation and harness overhead",
            "driver_body_seconds starts after Julia argument parsing; time the outer command separately",
            "wait4 RSS includes the child and waited descendants where the OS reports them",
            "wait4 RSS includes the resident set the child inherited from its spawner; a value near spawner_max_rss_bytes, the driver's peak, may be the driver's, and the child's own max_rss_bytes read VmHWM on Linux, which excludes it",
            "Owned process-group signalling does not prove escaped descendants retired",
            "Raw samples are descriptive; no ranking or population-tail claim is made",
        ],
    )
    save() = begin
        report["driver_body_seconds"] = monotonic() - started
        seek(evidence, 0)
        body = sprint(io -> JSON.print(io, report, 2)) * "\n"
        write(evidence, body)
        truncate(evidence, length(codeunits(body)))
        nothing
    end
    save()
    environment = Dict{String,String}(ENV)
    delete!(environment, "TMUX")
    delete!(environment, "TMUX_PANE")
    environment["JULIA_PKG_OFFLINE"] = "true"
    environment["JULIA_PKG_PRECOMPILE_AUTO"] = "0"
    environment["LIBTMUX_TEST_TMUX"] = args.tmux
    jobs = job_order(args.profiles, args.samples, args.seed)
    report["order"] = [[iteration, profile, kind] for (iteration, profile, kind) in jobs]
    try
        for (iteration, profile, kind) in jobs
            if monotonic() >= deadline
                push!(
                    report["samples"],
                    Dict(
                        "iteration" => iteration,
                        "profile" => profile,
                        "kind" => kind,
                        "status" => "not_started_deadline",
                    ),
                )
                continue
            end
            result = observe(
                child_command(args, profile, kind),
                environment,
                min(deadline, monotonic() + args.process_budget),
            )
            merge!(
                result,
                Dict("iteration" => iteration, "profile" => profile, "kind" => kind),
            )
            try
                decode_sample!(result, kind)
                if kind == "core" &&
                   haskey(result, "measurement") &&
                   get(result["measurement"], "source_sha256", nothing) != hashes
                    result["status"] = "stale_source"
                end
            catch error
                error isa Union{ArgumentError,TOML.ParserError,BoundsError} || rethrow()
                result["status"] = "invalid_measurement"
                result["decode_error"] = string(nameof(typeof(error)))
            end
            for name in ("stdout", "stderr")
                raw = pop!(result, name)
                result[name*"_base64"] = Base64.base64encode(raw)
                result[name*"_sha256"] = bytes2hex(SHA.sha256(raw))
            end
            push!(report["samples"], result)
            save()
            println(
                "$(result["status"]) $profile/$kind/$iteration ",
                round(result["whole_ns"] / 1e9; digits=3),
                "s",
            )
            flush(stdout)
            result["status"] == "interrupted" && break
        end
        if monotonic() < deadline
            version =
                observe([args.tmux, "-V"], environment, min(deadline, monotonic() + 0.9))
            report["tmux_version"] = strip(String(copy(version["stdout"])))
            report["tmux_version_status"] = version["status"]
        end
        report["status"] =
            length(report["samples"]) == length(jobs) &&
            all(sample -> sample["status"] == "pass", report["samples"]) ? "pass" : "failed"
        report["status"] == "pass" &&
            report["tmux_version_status"] != "pass" &&
            (report["status"] = "partial_metadata")
        source_hashes() == hashes || (report["status"] = "stale_source")
        if any(
            ((path, digest),) -> !isfile(path) || sha256_file(path) != digest,
            report["project_files_sha256"],
        )
            report["status"] = "stale_project"
        end
        report["load_average_end"] = Sys.loadavg()
    catch error
        report["status"] = "driver_error"
        report["error_type"] = string(nameof(typeof(error)))
        rethrow()
    finally
        save()
    end
    report["status"]
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(BenchStartup.main(ARGS))
