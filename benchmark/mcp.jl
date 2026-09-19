using JSON, SHA, Pkg, Random

const MCP_BENCH_ROOT = dirname(@__DIR__)
const MCP_BENCH_PROFILES =
    Dict("normal"=>String[], "o0"=>["-O0"], "minimal"=>["--compile=min", "-O0"])
const MCP_BENCH_TOOLS = (
    "list_panes",
    "capture_pane",
    "send_keys",
    "paste_text",
    "resize_pane",
    "kill_pane",
    "run_operations",
    "create_session",
    "teardown_session",
    "wait_for_text",
    "send_keys_and_wait",
)

# ProcessFailedException renders Cmd.env. Keep the original cause inspectable,
# but print only error categories and process exit evidence.
struct MCPBenchmarkError <: Exception
    cause::Exception
end

function mcp_error_evidence(error::Exception)
    error isa MCPBenchmarkError && return mcp_error_evidence(error.cause)
    evidence = Dict{String,Any}("type"=>string(nameof(typeof(error))))
    if error isa ProcessFailedException
        evidence["processes"] = [
            Dict("exit_code"=>process.exitcode, "signal"=>process.termsignal) for
            process in error.procs
        ]
    elseif error isa CompositeException
        evidence["causes"] = mcp_error_evidence.(error.exceptions)
    end
    evidence
end

function Base.showerror(io::IO, error::MCPBenchmarkError)
    print(io, "MCP benchmark failure: ")
    JSON.print(io, mcp_error_evidence(error.cause))
end

function mcp_self_test()
    marker = "mcp-synthetic-credential-sentinel"
    failure = try
        run(setenv(Cmd(["/bin/sh", "-c", "exit 7"]), Dict("MCP_TEST_SECRET"=>marker)))
        nothing
    catch error
        error
    end
    @assert failure isa ProcessFailedException
    wrapped = MCPBenchmarkError(failure)
    @assert wrapped.cause === failure
    evidence = mcp_error_evidence(wrapped)
    @assert evidence["type"] == "ProcessFailedException"
    @assert only(evidence["processes"]) == Dict("exit_code"=>7, "signal"=>0)
    @assert !occursin(marker, sprint(showerror, wrapped))
    combined = MCPBenchmarkError(CompositeException([failure, ArgumentError(marker)]))
    @assert [item["type"] for item in mcp_error_evidence(combined)["causes"]] == ["ProcessFailedException", "ArgumentError"]
    @assert !occursin(marker, sprint(showerror, combined))
    println("PASS benchmark failure classification and diagnostic omission")
end

function mcp_parameters(arguments)
    values = Dict(
        "samples"=>"3",
        "warm"=>"5",
        "profiles"=>"normal",
        "threads"=>"1",
        "budget"=>"480",
        "startup"=>"90",
        "bytes"=>"4096",
        "seed"=>"2026",
        "output"=>joinpath(@__DIR__, "results", "mcp.json"),
    )
    seen = Set{String}()
    for argument in arguments
        pair = split(argument, '='; limit=2)
        length(pair) == 2 || error("use name=value arguments")
        name, value = pair
        haskey(values, name) && !(name in seen) || error("unknown or duplicate parameter")
        push!(seen, name)
        values[name] = value
    end
    profiles = String.(split(values["profiles"], ','))
    !isempty(profiles) &&
    all(profile -> haskey(MCP_BENCH_PROFILES, profile), profiles) &&
    length(unique(profiles)) == length(profiles) || error("invalid compiler profiles")
    samples, warm = parse(Int, values["samples"]), parse(Int, values["warm"])
    threads, bytes = parse(Int, values["threads"]), parse(Int, values["bytes"])
    budget, startup = parse(Float64, values["budget"]), parse(Float64, values["startup"])
    1 <= samples <= 10 && 0 <= warm <= 64 || error("samples/warm exceed bounds")
    1 <= threads <= 64 && 0 <= bytes <= 32768 || error("threads/bytes exceed bounds")
    isfinite(budget) && 0 < budget <= 540 || error("budget must be in (0,540] seconds")
    isfinite(startup) && 0 < startup <= 180 || error("startup must be in (0,180] seconds")
    (;
        profiles,
        samples,
        warm,
        threads,
        bytes,
        budget,
        startup,
        seed=parse(Int, values["seed"]),
        output=values["output"],
    )
end

mcp_flags(profile, threads) =
    vcat(["--startup-file=no", "--threads=$threads"], MCP_BENCH_PROFILES[profile])

function mcp_source_hashes()
    result = Dict{String,String}()
    for directory in ("src", "packages/LibTmuxMCP/src")
        for (parent, _, files) in walkdir(joinpath(MCP_BENCH_ROOT, directory))
            for name in files
                endswith(name, ".jl") || continue
                path = joinpath(parent, name)
                result[relpath(path, MCP_BENCH_ROOT)] = bytes2hex(open(sha256, path))
            end
        end
    end
    for name in (
        "Project.toml",
        "packages/LibTmuxMCP/Project.toml",
        "benchmark/mcp.jl",
        "benchmark/mcp_client.py",
    )
        result[name] = bytes2hex(open(sha256, joinpath(MCP_BENCH_ROOT, name)))
    end
    result
end

function mcp_dependencies()
    wanted = Set([
        "LibTmux",
        "LibTmuxMCP",
        "ModelContextProtocol",
        "JSON",
        "JSON3",
        "PrecompileTools",
    ])
    Dict(
        info.name => Dict(
            "version"=>string(info.version),
            "tree_sha1"=>info.tree_hash === nothing ? nothing : string(info.tree_hash),
        ) for info in values(Pkg.dependencies()) if info.name in wanted
    )
end

function mcp_summary(samples)
    groups = Dict{String,Vector{Int}}()
    for sample in samples
        haskey(sample, "client") || continue
        for process in sample["client"]["samples"]
            process["status"] == "pass" || continue
            for measurement in process["samples"]
                key = join((sample["profile"], process["kind"], measurement["phase"]), "/")
                push!(get!(groups, key, Int[]), measurement["elapsed_ns"])
            end
            for name in ("process_to_discovery_ns", "cancel_to_exit_ns", "eof_to_exit_ns")
                haskey(process, name) || continue
                key = join((sample["profile"], process["kind"], name), "/")
                push!(get!(groups, key, Int[]), process[name])
            end
        end
    end
    Dict(
        name => Dict(
            "count"=>length(values),
            "min_ns"=>minimum(values),
            "median_ns"=>sort(values)[cld(length(values), 2)],
            "p95_ns"=>sort(values)[clamp(
                ceil(Int, 0.95 * length(values)),
                1,
                length(values),
            )],
        ) for (name, values) in groups
    )
end

function mcp_fixture(server, bytes)
    ready = "mcp-benchmark-ready"
    command = [
        "/bin/sh",
        "-c",
        "printf '%s\\n' \"\$1\"; \"\$2\" -N -S \"\$3\" wait-for -S \"\$4\"; exec /bin/cat",
        "sh",
        repeat("x", bytes),
        server.tmux,
        server.socket_path,
        ready,
    ]
    session = new_session(server; name="benchmark-fixture", command)
    run_command(server, "wait-for", ready; timeout=0.9)
    pane = only(panes(snapshot(server))).ref
    app = Application(
        server;
        caller=pane,
        allowed_panes=[pane],
        allowed_tools=MCP_BENCH_TOOLS,
        allow_create=true,
    )
    catalog = try
        [tool.name for tool in tools(app)]
    finally
        close(app)
    end
    (; session, pane, catalog)
end

function mcp_main(arguments)
    options = mcp_parameters(arguments)
    ispath(options.output) && error("refusing to overwrite existing measurements")
    started = time_ns()
    samples = Any[]
    report = Dict{String,Any}(
        "schema_version"=>1,
        "status"=>"running",
        "julia"=>string(VERSION),
        "driver_threads"=>Threads.nthreads(),
        "driver_compile_mode"=>Base.JLOptions().compile_enabled,
        "driver_optimization_level"=>Base.JLOptions().opt_level,
        "platform"=>string(Sys.KERNEL, " ", Sys.ARCH),
        "dependencies"=>mcp_dependencies(),
        "source_sha256"=>mcp_source_hashes(),
        "load_average_start"=>Sys.loadavg(),
        "parameters"=>Dict(
            "samples"=>options.samples,
            "warm"=>options.warm,
            "profiles"=>options.profiles,
            "child_threads"=>options.threads,
            "budget_seconds"=>options.budget,
            "startup_seconds"=>options.startup,
            "fixture_bytes"=>options.bytes,
            "seed"=>options.seed,
        ),
        "samples"=>samples,
        "owned_server_closed"=>false,
        "limitations"=>[
            "Fresh process means a new Julia process; dependency and OS caches are not flushed",
            "Prepare dependencies and compiled caches before running; no package resolution runs here",
            "Cancellation has no protocol acknowledgement; cancel-to-exit includes the EOF join",
            "A pipe-capacity proof is required for backpressure; unavailable capacity is reported as partial",
            "Raw timings and byte counts include client JSON decoding; captured screen text is fixture data",
            "Peak RSS comes from wait4 for the reaped child and its waited descendants, when available",
            "Compiler profiles are comparisons; this driver does not choose a default launcher profile",
            "Small sample counts describe these runs and do not establish population tail latency",
            "driver_body_ns excludes Julia import/startup; process-to-discovery includes the measured child startup",
        ],
    )
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    child_environment = Dict(ENV)
    pop!(child_environment, "TMUX", nothing)
    pop!(child_environment, "TMUX_PANE", nothing)
    random = MersenneTwister(options.seed)
    owned = nothing
    primary = nothing
    cleanup = nothing
    try
        owned = open_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment)
        let server = owned.server
            report["tmux"] = strip(
                decode_text(
                    run_command(server, "display-message", "-p", "#{version}").stdout,
                ),
            )
            fixture_started = time_ns()
            fixture = mcp_fixture(server, options.bytes)
            report["fixture_setup_ns"] = time_ns() - fixture_started
            report["catalog"] = fixture.catalog
            mktempdir(; prefix="libtmux-julia-mcp-benchmark-") do directory
                launchers = Dict(
                    profile => install_cli(
                        joinpath(directory, profile);
                        julia_flags=[
                            "--threads=$(options.threads)";
                            MCP_BENCH_PROFILES[profile]
                        ],
                    ) for profile in options.profiles
                )
                for iteration = 1:options.samples
                    for profile in shuffle(random, copy(options.profiles))
                        remaining = options.budget - (time_ns() - started) / 1e9
                        remaining > 0 || error("benchmark run budget exhausted")
                        artifact = joinpath(directory, "$(profile)-$(iteration).json")
                        sample = Dict{String,Any}(
                            "iteration"=>iteration,
                            "profile"=>profile,
                            "compiler_flags"=>mcp_flags(profile, options.threads),
                            "status"=>"running",
                        )
                        push!(samples, sample)
                        command = Cmd([
                            "python3",
                            joinpath(@__DIR__, "mcp_client.py"),
                            "--launcher",
                            launchers[profile],
                            "--socket",
                            server.socket_path,
                            "--tmux",
                            server.tmux,
                            "--pane",
                            string(fixture.pane.id),
                            "--output",
                            artifact,
                            "--warm",
                            string(options.warm),
                            "--budget",
                            string(remaining),
                            "--startup",
                            string(options.startup),
                        ])
                        failure = nothing
                        try
                            run(setenv(command, child_environment))
                        catch error
                            failure = error
                        end
                        try
                            if isfile(artifact)
                                sample["client"] =
                                    JSON.parsefile(artifact; dicttype=Dict{String,Any})
                                sample["status"] = sample["client"]["status"]
                            else
                                sample["status"] = "missing_client_report"
                            end
                            graph = snapshot(server)
                            session_refs = [session.ref for session in sessions(graph)]
                            sample["fixture_session_preserved"] =
                                session_refs == [fixture.session]
                            sample["clients_after_exit"] = length(clients(graph))
                            sample["buffers_after_exit"] = length(
                                split(
                                    chomp(
                                        decode_text(
                                            run_command(server, "list-buffers").stdout,
                                        ),
                                    ),
                                    '\n';
                                    keepempty=false,
                                ),
                            )
                        catch error
                            failure =
                                failure === nothing ? error :
                                CompositeException([failure, error])
                        end
                        if failure !== nothing
                            sample["failure"] = mcp_error_evidence(failure)
                            throw(failure)
                        end
                        sample["fixture_session_preserved"] &&
                        sample["clients_after_exit"] == 0 &&
                        sample["buffers_after_exit"] == 0 ||
                            error("benchmark ownership cleanup failed")
                    end
                end
            end
        end
        report["status"] =
            all(sample -> sample["status"] == "pass", samples) ? "pass" : "partial"
    catch error
        primary = error
        report["status"] = "fail"
        report["error_type"] = string(nameof(typeof(error)))
        report["error"] = mcp_error_evidence(error)
    finally
        if owned !== nothing
            try
                close(owned)
                report["owned_server_closed"] = true
            catch error
                cleanup = error
                report["status"] = "fail"
                report["cleanup_error_type"] = string(nameof(typeof(error)))
                report["cleanup_error"] = mcp_error_evidence(error)
            end
        end
        report["driver_body_ns"] = time_ns() - started
        report["load_average_end"] = Sys.loadavg()
        report["source_unchanged"] = mcp_source_hashes() == report["source_sha256"]
        report["source_unchanged"] || (report["status"] = "fail_source_changed")
        report["summary"] = mcp_summary(samples)
        destination = abspath(options.output)
        mkpath(dirname(destination))
        temporary, io = mktemp(dirname(destination))
        try
            JSON.print(io, report, 2)
            close(io)
            hardlink(temporary, destination)
        finally
            isopen(io) && close(io)
            rm(temporary; force=true)
        end
    end
    errors = Exception[]
    primary === nothing || push!(errors, primary)
    cleanup === nothing || push!(errors, cleanup)
    report["source_unchanged"] ||
        push!(errors, ErrorException("sources changed during measurement"))
    # Throw after leaving the catch stack so Julia cannot print the raw cause.
    isempty(errors) || throw(
        MCPBenchmarkError(length(errors) == 1 ? only(errors) : CompositeException(errors)),
    )
    println("MCP benchmark ", report["status"], "; raw samples retained")
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    if ARGS == ["--self-test"]
        mcp_self_test()
    else
        using LibTmux, LibTmuxMCP
        mcp_main(ARGS)
    end
end
