using LibTmux, BenchmarkTools, JSON, Random, SHA
import LibTmux.Filters as F

const ROOT = dirname(@__DIR__)

function parameters(arguments)
    defaults = Dict(
        "samples"=>5,
        "operations"=>8,
        "sessions"=>2,
        "windows"=>2,
        "panes"=>2,
        "links"=>1,
        "bytes"=>256,
        "seed"=>2026,
    )
    output = joinpath(@__DIR__, "results", "workflows.json")
    for arg in arguments
        fields = split(arg, '='; limit=2)
        length(fields) == 2 || error("use name=value arguments")
        key, value = fields
        if key == "output"
            output = value
        else
            haskey(defaults, key) || error("unknown parameter: $key")
            defaults[key] = parse(Int, value)
        end
    end
    1 <= defaults["samples"] <= 100 || error("samples must be in 1:100")
    1 <= defaults["operations"] <= 64 || error("operations must be in 1:64")
    1 <= defaults["sessions"] <= 16 || error("sessions must be in 1:16")
    defaults["sessions"] <= defaults["windows"] <= 32 ||
        error("windows must be between sessions and 32")
    1 <= defaults["panes"] <= 4 || error("panes per window must be in 1:4")
    0 <= defaults["links"] <= 8 || error("extra shared links must be in 0:8")
    0 <= defaults["bytes"] <= 4 * 1024^2 || error("input bytes must be in 0:4194304")
    ispath(output) && error("refusing to replace an existing measurement file")
    defaults, output
end

function percentile(values, fraction)
    ordered = sort(values)
    ordered[clamp(ceil(Int, length(ordered) * fraction), 1, length(ordered))]
end

function source_hashes()
    result = Dict{String,String}()
    for directory in ("src", "ext")
        for (parent, dirs, names) in walkdir(joinpath(ROOT, directory))
            filter!(name -> name != "results", dirs)
            for name in names
                endswith(name, ".jl") || continue
                path = joinpath(parent, name)
                result[relpath(path, ROOT)] = bytes2hex(open(sha256, path))
            end
        end
    end
    for relative in ("Project.toml", "benchmark/Project.toml", "benchmark/workflows.jl")
        result[relative] = bytes2hex(open(sha256, joinpath(ROOT, relative)))
    end
    result
end

function setup_graph(server, options)
    history = max(2000, cld(options["bytes"], 20) + 200)
    set_option(server, :global_session, "history-limit", string(history))
    for index = 1:options["sessions"]
        new_session(server; name="bench_$index", command=["/bin/cat"])
    end
    graph = snapshot(server)
    primary = first(sessions(graph)).ref
    for index = (options["sessions"]+1):options["windows"]
        new_window(server, primary; name="window_$index", command=["/bin/cat"])
    end
    graph = snapshot(server)
    for win in windows(graph)
        resize_window(server, win.ref; width=160, height=80)
        placeholder = first(panes(win)).ref
        created = run_command(
            server,
            "split-window",
            "-d",
            "-P",
            "-F",
            "#{pane_id}",
            "-t",
            string(placeholder.id),
            "",
        )
        target = PaneRef(placeholder.server, chomp(decode_text(created.stdout)))
        kill_pane(server, placeholder)
        for _ = 2:options["panes"]
            run_command(server, "split-window", "-d", "-h", "-t", string(target.id), "")
        end
        select_layout(server, win.ref, "tiled")
    end
    graph = snapshot(server)
    link = first(windowlinks(graph))
    destination = last(sessions(graph)).ref
    for index = 1:options["links"]
        link_window(server, WindowLinkRef(link), destination; index=100+index)
    end
    graph = snapshot(server)
    target = first(panes(graph)).ref
    payload = repeat("x", options["bytes"])
    isempty(payload) || run_command(
        server,
        "display-message",
        "-I",
        "-t",
        string(target.id);
        input=codeunits(payload),
    )
    captured = capture_bytes(server, target; start_line=:history)
    count(==(0x78), captured) == options["bytes"] ||
        error("fixture capture lost seeded bytes; check pane width and history capacity")
    (; graph=snapshot(server), primary, target, captured)
end

function local_trials(graph)
    selection = panes(graph)
    vector = collect(selection)
    predicate = p -> p.active && p.width >= 10
    criterion = PaneWhere(active=true, width=F.AtLeast(10))
    decoded = decode_where(encode_where(criterion))
    related = PaneWhere(window=WindowWhere(panes=F.AnyRelated(PaneWhere(active=true))))
    expected = entitykey.(filter(predicate, vector))
    jobs = [
        ("closure_vector", () -> filter(predicate, vector), expected),
        ("criterion_vector", () -> filter(criterion, vector), expected),
        ("criterion_selection", () -> filter(criterion, selection), expected),
        ("lazy_criterion", () -> collect(Iterators.filter(criterion, selection)), expected),
        ("decoded_criterion", () -> filter(decoded, selection), expected),
        ("nested_relation", () -> filter(related, selection), entitykey.(selection)),
    ]
    results = Any[]
    for (name, operation, identities) in jobs
        @assert entitykey.(operation()) == identities
        trial = @benchmark $operation() samples=256 seconds=0.2 evals=1
        push!(
            results,
            Dict(
                "name"=>name,
                "samples_ns"=>trial.times,
                "median_ns"=>percentile(trial.times, 0.5),
                "p95_ns"=>percentile(trial.times, 0.95),
                "allocations"=>trial.allocs,
                "memory_bytes"=>trial.memory,
                "result_count"=>length(identities),
            ),
        )
    end
    results
end

const MODES = (
    "subprocess_serial",
    "subprocess_concurrent",
    "control_serial",
    "control_pipelined",
    "control_group",
    "subprocess_group",
)

function workload(mode, server, connection, commands, query, target)
    lane = startswith(mode, "subprocess") ? server : connection
    started = time_ns()
    outcomes = if endswith(mode, "group")
        run_group(lane, commands)
    else
        concurrency = endswith(mode, "serial") ? 1 : 4
        run_batch(lane, commands; concurrency)
    end
    mutation_ns = time_ns() - started
    # Opaque subprocess groups cannot attribute aggregate success to steps.
    if outcomes isa GroupResult && outcomes.opaque
        @assert outcomes.aggregate !== nothing && outcomes.aggregate.exitcode == 0
    else
        @assert all(outcome -> outcome.status === :completed, outcomes)
    end
    started = time_ns()
    graph = snapshot(lane)
    snapshot_ns = time_ns() - started
    started = time_ns()
    matched = filter(query, panes(graph))
    ids = entitykey.(matched)
    query_ns = time_ns() - started
    started = time_ns()
    capture = capture_bytes(lane, target; start_line=:history)
    capture_ns = time_ns() - started
    (;
        outcomes,
        ids,
        capture,
        phases=Dict(
            "mutation"=>mutation_ns,
            "snapshot"=>snapshot_ns,
            "query"=>query_ns,
            "capture"=>capture_ns,
        ),
    )
end

function workflow_trials(server, connection, target, options, samples)
    random = MersenneTwister(options["seed"])
    query = PaneWhere(active=true, width=F.AtLeast(10))
    expected = entitykey.(filter(query, panes(snapshot(server))))
    capture = capture_bytes(server, target; start_line=:history)
    count(==(0x78), capture) == options["bytes"] ||
        error("control attachment changed the captured payload")
    for iteration = 0:options["samples"]
        modes = shuffle(random, collect(MODES))
        for mode in modes
            setup_started = time_ns()
            buffers = [load_buffer(server, UInt8[0x61]) for _ = 1:options["operations"]]
            setup_ns = time_ns() - setup_started
            commands = [
                TmuxCommand("delete-buffer", "-b", string(buffer.id)) for buffer in buffers
            ]
            record = Dict{String,Any}(
                "mode"=>mode,
                "iteration"=>iteration,
                "status"=>"running",
                "phase"=>iteration == 0 ? "first_use" : "steady",
            )
            push!(samples, record)
            measured = @timed workload(mode, server, connection, commands, query, target)
            result = measured.value
            @assert result.ids == expected && result.capture == capture
            @assert isempty(run_command(server, "list-buffers").stdout)
            merge!(
                record,
                Dict(
                    "status"=>"pass",
                    "setup_ns"=>setup_ns,
                    "elapsed_ns"=>round(Int, measured.time * 1e9),
                    "allocated_bytes"=>measured.bytes,
                    "gc_seconds"=>measured.gctime,
                    "max_rss_bytes"=>Sys.maxrss(),
                    "operation_count"=>length(commands),
                    "result_count"=>length(result.ids),
                    "capture_bytes"=>length(result.capture),
                    "phases_ns"=>result.phases,
                    "mutations_per_second"=>length(commands) * 1e9 /
                                            result.phases["mutation"],
                    "statuses"=>string.([outcome.status for outcome in result.outcomes]),
                    "ordering"=>endswith(mode, "group") || endswith(mode, "serial") ?
                                "submission order" :
                                "input-indexed results; execution unspecified",
                    "control_capacity"=>connection.capacity,
                    "pending_after"=>lock(
                        () -> length(connection.pending),
                        connection.lock,
                    ),
                    "clients_after"=>length(clients(snapshot(server))),
                    "owned_buffers_after"=>0,
                ),
            )
        end
    end
    samples
end

function main(arguments)
    options, output = parameters(arguments)
    report = Dict{String,Any}(
        "schema_version"=>2,
        "status"=>"running",
        "julia"=>string(VERSION),
        "threads"=>Threads.nthreads(),
        "compile_mode"=>Base.JLOptions().compile_enabled,
        "optimization_level"=>Base.JLOptions().opt_level,
        "platform"=>string(Sys.KERNEL, " ", Sys.ARCH),
        "parameters"=>options,
        "source_sha256"=>source_hashes(),
        "load_average_start"=>Sys.loadavg(),
        "limitations"=>[
            "RSS is process-lifetime high water, not per-operation allocation",
            "Buffer deletion is the common audited group workload; acquisition/capture follow it",
            "Snapshot acquisition is stable after capture, not an atomic transaction",
            "No peak backlog instrumentation; pending_after reports the retirement boundary",
            "Input bytes are seeded x characters; screen capture also contains line breaks",
            "Phase timings isolate mutation, snapshot, local query and capture within one workload",
        ],
    )
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    whole = time_ns()
    directory = nothing
    try
        with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
            directory = dirname(server.socket_path)
            report["tmux"] = strip(
                decode_text(
                    run_command(server, "display-message", "-p", "#{version}").stdout,
                ),
            )
            setup_started = time_ns()
            fixture = setup_graph(server, options)
            report["topology_setup_ns"] = time_ns() - setup_started
            report["graph"] = Dict(
                "sessions"=>length(sessions(fixture.graph)),
                "windows"=>length(windows(fixture.graph)),
                "panes"=>length(panes(fixture.graph)),
                "windowlinks"=>length(windowlinks(fixture.graph)),
                "paneoccurrences"=>length(paneoccurrences(fixture.graph)),
            )
            report["output_fixture"] = Dict(
                "seeded_bytes"=>options["bytes"],
                "capture_bytes"=>length(fixture.captured),
                "capture_sha256"=>bytes2hex(sha256(fixture.captured)),
            )
            report["queries"] = local_trials(fixture.graph)
            opening = time_ns()
            connection = open_control(server, fixture.primary)
            report["first_control_open_ns"] = time_ns() - opening
            report["workflows"] = Any[]
            try
                workflow_trials(
                    server,
                    connection,
                    fixture.target,
                    options,
                    report["workflows"],
                )
            finally
                closing = time_ns()
                close(connection)
                report["control_close_ns"] = time_ns() - closing
            end
            @assert isempty(clients(snapshot(server)))
            report["clients_after_close"] = 0
        end
        report["owned_server_closed"] = true
        report["socket_directory_removed"] = !ispath(directory)
        report["socket_directory_removed"] ||
            error("owned socket directory survived cleanup")
        report["status"] = "pass"
    catch error
        report["status"] = "fail"
        report["error_type"] = string(nameof(typeof(error)))
        rethrow()
    finally
        report["whole_ns"] = time_ns() - whole
        report["load_average_end"] = Sys.loadavg()
        report["source_unchanged"] = source_hashes() == report["source_sha256"]
        report["source_unchanged"] || (report["status"] = "invalid_source_changed")
        mkpath(dirname(abspath(output)))
        open(io -> JSON.print(io, report, 2), output, "w")
    end
    report["status"] == "pass" || error("Measurement invalidated; inspect source_unchanged")
    println("PASS measured six execution modes and six local query shapes")
end

main(ARGS)
