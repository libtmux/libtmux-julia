using LibTmux, LibTmuxWorkspace
import JSON, Random, SHA


function workspace_source_hashes()
    root = normpath(joinpath(@__DIR__, "..", "..", ".."))
    result = Dict{String,String}()
    for relative in ("src", "packages/LibTmuxWorkspace/src")
        for (parent, _, names) in walkdir(joinpath(root, relative)), name in names
            endswith(name, ".jl") || continue
            path = joinpath(parent, name)
            result[relpath(path, root)] = bytes2hex(open(SHA.sha256, path))
        end
    end
    for relative in (
        "Project.toml",
        "packages/LibTmuxWorkspace/Project.toml",
        "packages/LibTmuxWorkspace/dev/cli_latency.jl",
    )
        result[relative] = bytes2hex(open(SHA.sha256, joinpath(root, relative)))
    end
    result
end

# Separate benchmark tier: fresh installed CLI processes, prepared dependencies.
function measure_cli(args, budget)
    started = time_ns()
    word(text) = "'" * replace(text, "'" => "'\\''") * "'"
    result = run_before_script(
        join(word.(args), " ");
        base_directory=pwd(),
        timeout=budget,
        max_output_bytes=1024^2,
    )
    isempty(result.stderr) || error("unexpected CLI diagnostics")
    (seconds=(time_ns() - started) / 1e9, text=String(result.stdout))
end

function main()
    1 <= length(ARGS) <= 3 ||
        error("usage: cli_latency.jl OUTPUT.json [normal|o0|minimal|all] [samples]")
    output_path = first(ARGS)
    ispath(output_path) && error("refusing to replace an existing measurement file")
    profile = length(ARGS) == 1 ? "normal" : ARGS[2]
    samples = length(ARGS) < 3 ? 1 : parse(Int, ARGS[3])
    1 <= samples <= 8 || error("samples must be in 1:8")
    seed = parse(Int, get(ENV, "LIBTMUX_BENCH_SEED", "2026"))
    random = Random.MersenneTwister(seed)
    profile in ("normal", "o0", "minimal", "all") || error("unknown profile")
    all_modes =
        (("normal", String[]), ("o0", ["-O0"]), ("minimal", ["--compile=min", "-O0"]))
    modes = profile == "all" ? all_modes : filter(item -> first(item) == profile, all_modes)
    child_threads = parse(Int, get(ENV, "LIBTMUX_BENCH_THREADS", "1"))
    child_threads in (1, 4) || error("LIBTMUX_BENCH_THREADS must be 1 or 4")
    began = time_ns()
    remaining() = begin
        budget = 480.0 - (time_ns() - began) / 1e9
        budget > 0 || error("benchmark exceeded its 480-second workload budget")
        budget
    end
    results = []
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict(
        "PATH" => get(ENV, "PATH", "/usr/local/bin:/usr/bin:/bin"),
        "SHELL" => "/bin/sh",
        "TERM" => "xterm-256color",
    )
    report = Dict(
        "schema_version" => 1,
        "status" => "running",
        "source_sha256" => workspace_source_hashes(),
        "driver_compile_mode"=>Base.JLOptions().compile_enabled,
        "driver_optimization_level"=>Base.JLOptions().opt_level,
        "driver_threads"=>Threads.nthreads(),
        "load_average_start"=>Sys.loadavg(),
        "julia" => string(VERSION),
        "tmux" => readchomp(Cmd([tmux, "-V"])),
        "machine" => string(Sys.MACHINE),
        "samples_per_mode" => samples,
        "seed" => seed,
        "child_threads" => child_threads,
        "dependencies_prepared" => true,
        "notes" => "Fresh CLI processes with existing package caches; randomized profile order per repetition. Small-sample tails are descriptive, not population estimates.",
        "results" => results,
    )
    try
        for iteration = 1:samples, (mode, flags) in Random.shuffle(random, collect(modes))
            remaining()
            whole_started = time_ns()
            row = Dict{String,Any}(
                "iteration"=>iteration,
                "mode"=>mode,
                "flags"=>flags,
                "status"=>"running",
            )
            push!(results, row)
            endpoint = Ref{Server}()
            measurements = with_server(; tmux, env) do server
                endpoint[] = server
                directory = dirname(server.socket_path)
                launcher = install_cli(
                    joinpath(directory, "bin");
                    julia_flags=["--threads=" * string(child_threads); flags],
                )
                config = joinpath(directory, "workspace.json")
                write(
                    config,
                    JSON.json(
                        Dict(
                            "session_name" => "latency",
                            "options" => Dict("default-shell" => "/bin/sh"),
                            "windows" => [Dict("window_name" => "main")],
                        ),
                    ),
                )
                selectors = ["--socket", server.socket_path, "--tmux", tmux]
                loaded = measure_cli(
                    [launcher, "load", config, selectors..., "--output", "ndjson"],
                    remaining(),
                )
                records = JSON.parse.(split(chomp(loaded.text), '\n'))
                last(records)["event"] == "result" || error("load did not complete")
                frozen = measure_cli(
                    [launcher, "freeze", "latency", selectors..., "--output", "json"],
                    remaining(),
                )
                document = JSON.parse(frozen.text)
                validate(document["workspace"]).windows[1].name == "main" ||
                    error("freeze mismatch")
                isempty(clients(snapshot(server))) ||
                    error("CLI left a client attached")
                (
                    load_seconds=loaded.seconds,
                    freeze_seconds=frozen.seconds,
                    load_records=length(records),
                    output_bytes=ncodeunits(loaded.text) + ncodeunits(frozen.text),
                )
            end
            ispath(dirname(endpoint[].socket_path)) &&
                error("owned daemon directory survived close")
            merge!(
                row,
                Dict(
                    "status"=>"pass",
                    "clients_after"=>0,
                    "owned_server_closed"=>true,
                    "load_seconds" => measurements.load_seconds,
                    "freeze_seconds" => measurements.freeze_seconds,
                    "load_records" => measurements.load_records,
                    "output_bytes" => measurements.output_bytes,
                    "whole_seconds" => (time_ns() - whole_started) / 1e9,
                ),
            )
            println(JSON.json(row))
            flush(stdout)
        end
        report["summary"] = Dict(
            mode => Dict(
                key => begin
                    values = sort!([row[key] for row in results if row["mode"] == mode])
                    Dict(
                        "count"=>length(values),
                        "median"=>values[cld(length(values), 2)],
                        "p95"=>values[clamp(
                            ceil(Int, 0.95 * length(values)),
                            1,
                            length(values),
                        )],
                    )
                end for key in ("load_seconds", "freeze_seconds", "whole_seconds")
            ) for (mode, _) in modes
        )
        report["status"] = "pass"
    catch error
        report["status"] = "fail"
        report["error_type"] = string(nameof(typeof(error)))
        rethrow()
    finally
        report["source_unchanged"] = workspace_source_hashes() == report["source_sha256"]
        report["source_unchanged"] || (report["status"] = "invalid_source_changed")
        report["whole_seconds"] = (time_ns() - began) / 1e9
        report["load_average_end"] = Sys.loadavg()
        mkpath(dirname(abspath(output_path)))
        write(output_path, JSON.json(report))
    end
    report["status"] == "pass" || error("measurement source changed")
end

main()
