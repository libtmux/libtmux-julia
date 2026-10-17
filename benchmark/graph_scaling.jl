const GRAPH_ENTRY_NS = time_ns()
const GRAPH_ROOT = dirname(@__DIR__)
const GRAPH_SIZES = (16, 64, 256, 1024, 4096)

function graph_parameters(arguments)
    options = Dict{String,Any}(
        "sizes"=>collect(GRAPH_SIZES),
        "samples"=>20,
        "seed"=>20261003,
        "budget"=>480.0,
        "output"=>joinpath(@__DIR__, "results", "graph-scaling"),
    )
    for argument in arguments
        pair = split(argument, '='; limit=2)
        length(pair) == 2 || error("use name=value arguments or --self-test")
        name, value = pair
        haskey(options, name) || error("unknown parameter: $name")
        options[name] =
            name == "sizes" ? parse.(Int, split(value, ',')) :
            name in ("samples", "seed") ? parse(Int, value) :
            name == "budget" ? parse(Float64, value) : String(value)
    end
    sizes = options["sizes"]
    !isempty(sizes) &&
    issorted(sizes) &&
    length(unique(sizes)) == length(sizes) &&
    all(size -> size in GRAPH_SIZES, sizes) ||
        error("sizes must be an ordered subset of 16,64,256,1024,4096")
    20 <= options["samples"] <= 200 || error("samples must be in 20:200")
    isfinite(options["budget"]) && 0 < options["budget"] < 600 ||
        error("budget must be positive and below 600 seconds")
    options
end

function graph_reserve(output)
    destination = abspath(output)
    mkpath(dirname(destination))
    mkdir(destination) # Atomic reservation; an existing result is never replaced.
    destination
end

graph_percentile(values, fraction) =
    sort(values)[clamp(ceil(Int, length(values) * fraction), 1, length(values))]

function graph_source_hashes(root=GRAPH_ROOT)
    files = [
        "Project.toml",
        "benchmark/Project.toml",
        "benchmark/graph_scaling.jl",
        "schema/fields.toml",
    ]
    for directory in ("src", "ext")
        for (parent, _, names) in walkdir(joinpath(root, directory)), name in names
            endswith(name, ".jl") && push!(files, relpath(joinpath(parent, name), root))
        end
    end
    Dict(path=>bytes2hex(open(SHA.sha256, joinpath(root, path))) for path in sort!(files))
end

function graph_environment_hashes()
    project = Base.active_project()
    project === nothing && error("a prepared project is required")
    manifest = joinpath(dirname(project), "Manifest.toml")
    Dict(
        "project_sha256"=>bytes2hex(open(SHA.sha256, project)),
        "manifest_sha256"=>isfile(manifest) ? bytes2hex(open(SHA.sha256, manifest)) :
                           nothing,
    )
end

function graph_fixture_rows(n)
    sessions = [
        (
            id="\$0",
            name="primary",
            attached_clients=0,
            created=1,
            activity=2,
            last_attached=nothing,
        ),
        (
            id="\$1",
            name="shared",
            attached_clients=0,
            created=1,
            activity=2,
            last_attached=nothing,
        ),
    ]
    windows = [
        (
            id="@$i",
            name=iseven(i) ? "build" : "dev",
            width=80+i%10,
            height=24,
            layout="synthetic",
            visible_layout="synthetic",
            zoomed=false,
            activity=2,
        ) for i = 1:n
    ]
    panes = [
        (
            id="%$i",
            window_id="@$i",
            index=0,
            active=iseven(i),
            dead=false,
            width=80+i%10,
            height=24,
            current_command="sh",
            current_path="/",
            title="pane $i",
            pid=i,
            tty=nothing,
            exit_status=nothing,
            history_size=i,
            history_limit=10000,
            cursor_x=0,
            cursor_y=0,
        ) for i = 1:n
    ]
    links = [(session_id="\$0", window_id="@$i", index=i-1, active=i==1) for i = 1:n]
    for i = 1:n
        push!(links, (session_id="\$1", window_id="@$i", index=i==2 ? 0 : i, active=i==2))
    end
    push!(links, (session_id="\$0", window_id="@1", index=n, active=false))
    (; sessions, windows, panes, windowlinks=links)
end

function graph_construct(rows)
    identity = LibTmux.ServerIdentity(;
        socket_path="/synthetic/graph-scaling",
        generation="inert-fixture",
    )
    # The private builder creates inert fixtures; all timed navigation uses public APIs.
    LibTmux._build_snapshot(identity; rows..., acquired=(0.0, 0.0), complete=true)
end

function graph_sample_record(sample)
    record = Dict{String,Any}(
        "status"=>"pass",
        "elapsed_ns"=>round(Int, sample.time * 1e9),
        "allocated_bytes"=>sample.bytes,
        "allocations"=>Base.gc_alloc_count(sample.gcstats),
        "gc_ns"=>round(Int, sample.gctime * 1e9),
        "process_max_rss_bytes"=>Sys.maxrss(),
    )
    if hasproperty(sample, :compile_time)
        record["compile_ns"] = round(Int, sample.compile_time * 1e9)
        record["recompile_ns"] = round(Int, sample.recompile_time * 1e9)
    end
    record
end

function graph_sample_failure(started, failure)
    nothing,
    Dict{String,Any}(
        "status"=>"fail",
        "elapsed_ns"=>time_ns()-started,
        "error_type"=>string(typeof(failure)),
        "error"=>sprint(showerror, failure),
    ),
    failure
end

Base.@noinline function graph_measure(@nospecialize(action))
    started = time_ns()
    try
        sample = @timed Base.invokelatest(action)
        sample.value, graph_sample_record(sample), nothing
    catch failure
        graph_sample_failure(started, failure)
    end
end

function graph_measure_warm(action)
    started = time_ns()
    try
        sample = @timed action()
        sample.value, graph_sample_record(sample), nothing
    catch failure
        graph_sample_failure(started, failure)
    end
end

function graph_emit(io, record)
    JSON.print(io, record)
    println(io)
    flush(io)
end

function graph_call(io, action, n, name, phase, iteration, options)
    (time_ns()-GRAPH_ENTRY_NS)/1e9 < options["budget"] ||
        error("whole script budget exceeded")
    caller_started = time_ns()
    value, record, failure =
        phase == "first" ? graph_measure(action) : graph_measure_warm(action)
    record["caller_elapsed_ns"] = time_ns()-caller_started
    record["first_native_warm_call"] = phase == "warm" && iteration == 1
    merge!(record, Dict("size"=>n, "name"=>name, "phase"=>phase, "iteration"=>iteration))
    graph_emit(io, record)
    failure === nothing || throw(failure)
    value, record
end

function graph_jobs(snap, rows, ps, ws)
    even = LibTmux.PaneWhere(; active=true, width=F.AtLeast(80))
    nested = LibTmux.PaneWhere(;
        window=LibTmux.WindowWhere(; panes=F.AnyRelated(LibTmux.PaneWhere(; active=true))),
    )
    correlated = LibTmux.WindowWhere(;
        windowlinks=F.AnyRelated(
            LibTmux.WindowLinkWhere(;
                index=0,
                session=LibTmux.SessionWhere(; name="shared"),
            ),
        ),
    )
    independent = F.AllOf(
        LibTmux.WindowWhere(; windowlinks=F.AnyRelated(LibTmux.WindowLinkWhere(; index=0))),
        LibTmux.WindowWhere(;
            windowlinks=F.AnyRelated(
                LibTmux.WindowLinkWhere(; session=LibTmux.SessionWhere(; name="shared")),
            ),
        ),
    )
    pane_ref = first(ps).ref
    session = snap[LibTmux.SessionRef(snap.identity, "\$0")]
    columns = (:id, :width, :exit_status)
    [
        ("harness_control", () -> nothing),
        ("fixture_rows", () -> graph_fixture_rows(length(ps))),
        ("construction", () -> graph_construct(rows)),
        ("flat_panes", () -> LibTmux.panes(snap)),
        ("flat_windows", () -> LibTmux.windows(snap)),
        ("index", () -> ps[div(length(ps), 2)]),
        ("scalar_id", () -> first(ps).id),
        ("scalar_width", () -> first(ps).width),
        ("captured_lookup", () -> snap[pane_ref]),
        ("window_panes", () -> LibTmux.panes(first(ws))),
        ("window_links", () -> LibTmux.windowlinks(first(ws))),
        ("session_windows", () -> LibTmux.windows(session)),
        ("occurrences", () -> LibTmux.paneoccurrences(snap)),
        ("closure_filter", () -> filter(p -> p.active && p.width >= 80, ps)),
        ("criterion_filter", () -> filter(even, ps)),
        ("related_filter", () -> filter(nested, ps)),
        ("correlated_filter", () -> filter(correlated, ws)),
        ("independent_filter", () -> filter(independent, ws)),
        ("projection", () -> LibTmux.project_rows(ps; columns)),
        ("projection_materialize", () -> collect(LibTmux.project_rows(ps; columns))),
    ]
end

function graph_verify(name, value, snap, n)
    ids(items) = [string(item.id) for item in items]
    if name == "harness_control"
        @assert value === nothing
    elseif name == "fixture_rows"
        @assert length(value.panes) == n && length(value.windowlinks) == 2n+1
    elseif name == "construction"
        @assert length(LibTmux.panes(value)) == n
        @assert value.identity == snap.identity
    elseif name in ("flat_panes", "closure_filter", "criterion_filter", "related_filter")
        expected = name == "flat_panes" ? (1:n) : (2:2:n)
        @assert ids(value) == ["%$i" for i in expected]
        @assert LibTmux.snapshotof(value) === snap
    elseif name in
           ("flat_windows", "session_windows", "correlated_filter", "independent_filter")
        expected =
            name in ("flat_windows", "session_windows") ? (1:n) :
            name == "correlated_filter" ? (2,) : (1, 2)
        @assert ids(value) == ["@$i" for i in expected]
        @assert LibTmux.snapshotof(value) === snap
    elseif name in ("index", "captured_lookup")
        @assert string(value.id) == "%$(name == "index" ? div(n, 2) : 1)"
        @assert LibTmux.snapshotof(value) === snap
    elseif name == "scalar_id"
        @assert value == LibTmux.PaneID("%1")
    elseif name == "scalar_width"
        @assert value === 81
    elseif name == "window_panes"
        @assert ids(value) == ["%1"] && LibTmux.snapshotof(value) === snap
    elseif name == "window_links"
        @assert [(string(link.session_id), link.index) for link in value] == [("\$0", 0), ("\$1", 1), ("\$0", n)]
        @assert LibTmux.snapshotof(value) === snap
    elseif name == "occurrences"
        @assert [string(item.pane.id) for item in value] == vcat(["%$i" for i = 1:n], ["%$i" for i = 1:n], ["%1"])
        @assert length(unique(LibTmux.occurrencekey.(value))) == 2n+1
        @assert LibTmux.snapshotof(value) === snap
    elseif name in ("projection", "projection_materialize")
        @assert [string(row.id) for row in value] == ["%$i" for i = 1:n]
        @assert all(row -> row.width isa Int && row.exit_status === nothing, value)
        name == "projection" && @assert LibTmux.snapshotof(value) === snap
    else
        error("unverified operation $name")
    end
    nothing
end

function graph_coverage_proof(snap)
    roots = (:sessions, :windows, :panes, :clients, :windowlinks, :paneoccurrences)
    @assert all(key -> LibTmux.hascoverage(snap, key), roots)
    @assert all(
        win ->
            LibTmux.hascoverage(snap, (:window, win.id, :panes)) &&
            LibTmux.hascoverage(snap, (:window, win.id, :windowlinks)),
        LibTmux.windows(snap),
    )
    @assert all(
        session -> LibTmux.hascoverage(snap, (:session, session.id, :windowlinks)),
        LibTmux.sessions(snap),
    )
    @assert isempty(LibTmux.clients(snap))
    @assert get(snap, LibTmux.PaneRef(snap.identity, "%999999"), nothing) === nothing
    partial = LibTmux._build_snapshot(
        snap.identity;
        sessions=[(id="\$0", name="partial")],
        windows=[(id="@1", name="partial")],
        panes=[(id="%1", window_id="@1", tty=nothing)],
        windowlinks=[(session_id="\$0", window_id="@1", index=0)],
        acquired=(0.0, 0.0),
        complete=[:panes],
    )
    pane = only(LibTmux.panes(partial))
    @assert pane.tty === nothing
    failures = 0
    for action in (
        () -> pane.width,
        () -> LibTmux.panes(pane.window),
        () -> F.AnyOf(LibTmux.PaneWhere(), LibTmux.PaneWhere(; width=80))(pane),
        () -> LibTmux.WindowWhere(; windowlinks=F.AnyRelated(LibTmux.WindowLinkWhere()))(
            pane.window,
        ),
        () -> get(partial, LibTmux.WindowRef(snap.identity, "@2"), nothing),
    )
        try
            action()
        catch failure
            failure isa LibTmux.SnapshotCoverageError || rethrow()
            failures += 1
        end
    end
    @assert failures == 5
    wide = LibTmux._build_snapshot(
        snap.identity;
        panes=[(id="%1", width=typemax(UInt128), exit_status=nothing)],
        acquired=(0.0, 0.0),
        complete=[:panes],
    )
    @assert only(LibTmux.panes(wide)).width === typemax(UInt128)
    @assert only(LibTmux.panes(wide)).exit_status === nothing
    Dict(
        "complete_roots_and_parents"=>true,
        "partial_refusals"=>failures,
        "captured_null_distinct_from_uncaptured"=>true,
        "wide_integer_preserved"=>true,
    )
end

function graph_retained(snap, ps)
    selected = LibTmux.Selection([first(ps)]; snapshot=snap)
    projection = LibTmux.project_rows(selected; columns=(:id, :width, :exit_status))
    detached = collect(projection)
    @assert LibTmux.snapshotof(selected) === snap && LibTmux.snapshotof(projection) === snap
    @assert only(detached) == only(projection)
    @assert only(detached).id isa LibTmux.PaneID && only(detached).width isa Int
    Dict(
        "snapshot_bytes"=>Base.summarysize(snap),
        "one_view_bytes"=>Base.summarysize(first(ps)),
        "one_selection_bytes"=>Base.summarysize(selected),
        "one_projection_bytes"=>Base.summarysize(projection),
        "detached_one_row_bytes"=>Base.summarysize(detached),
        "selected_and_projected_retain_snapshot"=>true,
        "detached_row_fields"=>["typed ID", "Int", "nothing"],
    )
end

function graph_size(io, n, options)
    row_value, row_sample =
        graph_call(io, () -> graph_fixture_rows(n), n, "fixture_rows", "first", 0, options)
    snap, build_sample = graph_call(
        io,
        () -> graph_construct(row_value),
        n,
        "construction",
        "first",
        0,
        options,
    )
    ps, pane_sample =
        graph_call(io, () -> LibTmux.panes(snap), n, "flat_panes", "first", 0, options)
    ws, window_sample =
        graph_call(io, () -> LibTmux.windows(snap), n, "flat_windows", "first", 0, options)
    firsts = Dict(
        "fixture_rows"=>row_sample,
        "construction"=>build_sample,
        "flat_panes"=>pane_sample,
        "flat_windows"=>window_sample,
    )
    cold_values = Dict{String,Any}(
        "fixture_rows"=>row_value,
        "construction"=>snap,
        "flat_panes"=>ps,
        "flat_windows"=>ws,
    )
    pane_ref = LibTmux.PaneRef(snap.identity, "%1")
    for (name, action) in (
        ("index", () -> ps[div(n, 2)]),
        ("scalar_id", () -> first(ps).id),
        ("scalar_width", () -> first(ps).width),
        ("captured_lookup", () -> snap[pane_ref]),
    )
        value, sample = graph_call(io, action, n, name, "first", 0, options)
        firsts[name] = sample
        cold_values[name] = value
    end
    jobs = graph_jobs(snap, row_value, ps, ws)
    for (name, action) in jobs
        haskey(firsts, name) && continue
        value, sample = graph_call(io, action, n, name, "first", 0, options)
        firsts[name] = sample
        cold_values[name] = value
    end
    # Correctness checks run after every first invocation, then outside warm timings.
    for (name, value) in cold_values
        graph_verify(name, value, snap, n)
    end
    warm = Dict(name=>Any[] for (name, _) in jobs)
    rng = Random.MersenneTwister(options["seed"] + n)
    for iteration = 1:options["samples"], job in Random.randperm(rng, length(jobs))
        name, action = jobs[job]
        value, sample = graph_call(io, action, n, name, "warm", iteration, options)
        push!(warm[name], sample)
        graph_verify(name, value, snap, n)
    end
    operations = Dict{String,Any}()
    for (name, _) in jobs
        raw = warm[name]
        operations[name] = Dict(
            "first"=>firsts[name],
            "warm"=>raw,
            "p50_ns"=>graph_percentile([sample["elapsed_ns"] for sample in raw], 0.5),
            "p95_ns"=>graph_percentile([sample["elapsed_ns"] for sample in raw], 0.95),
            "p50_allocated_bytes"=>graph_percentile(
                [sample["allocated_bytes"] for sample in raw],
                0.5,
            ),
            "p95_allocated_bytes"=>graph_percentile(
                [sample["allocated_bytes"] for sample in raw],
                0.95,
            ),
            "p50_allocations"=>graph_percentile(
                [sample["allocations"] for sample in raw],
                0.5,
            ),
            "p95_allocations"=>graph_percentile(
                [sample["allocations"] for sample in raw],
                0.95,
            ),
        )
    end
    Dict(
        "size"=>n,
        "sessions"=>2,
        "physical_windows"=>n,
        "physical_panes"=>n,
        "links"=>2n+1,
        "occurrences"=>2n+1,
        "operations"=>operations,
        "semantics"=>graph_coverage_proof(snap),
        "retained"=>graph_retained(snap, ps),
    )
end

function graph_self_test()
    @assert graph_percentile(collect(1:20), 0.5) == 10
    @assert graph_percentile(collect(1:20), 0.95) == 19
    refused = false
    try
        graph_parameters(["samples=19"])
    catch
        refused = true
    end
    @assert refused
    mktempdir() do root
        destination = graph_reserve(joinpath(root, "result"))
        write(joinpath(destination, "sentinel"), "retained")
        refused = false
        try
            graph_reserve(destination)
        catch
            refused = true
        end
        @assert refused && read(joinpath(destination, "sentinel"), String) == "retained"
        for file in (
            "Project.toml",
            "benchmark/Project.toml",
            "benchmark/graph_scaling.jl",
            "schema/fields.toml",
            "src/model.jl",
            "ext/sample.jl",
        )
            mkpath(dirname(joinpath(root, file)))
            write(joinpath(root, file), "initial")
        end
        baseline = graph_source_hashes(root)
        write(joinpath(root, "src/added.jl"), "new")
        @assert graph_source_hashes(root) != baseline
        rm(joinpath(root, "src/added.jl"))
        write(joinpath(root, "src/model.jl"), "changed")
        @assert graph_source_hashes(root) != baseline
        open(joinpath(destination, "failure.jsonl"), "w") do io
            _, record, failure = graph_measure(() -> error("owned failure probe"))
            @assert failure isa ErrorException && record["status"] == "fail"
            @assert record["error"] == "owned failure probe"
            graph_emit(io, record)
        end
        @assert occursin(
            "owned failure probe",
            read(joinpath(destination, "failure.jsonl"), String),
        )
    end
    value, record, failure = graph_measure(() -> zeros(Int, 64))
    @assert failure === nothing && length(value) == 64
    @assert record["allocated_bytes"] > 0 && record["allocations"] > 0
    println(
        "PASS graph driver percentiles, bounds, no-overwrite, source set/hash, allocation counters",
    )
end

function graph_main(options, destination, imports, hashes)
    environment_hashes = graph_environment_hashes()
    report = Dict{String,Any}(
        "schema_version"=>1,
        "status"=>"running",
        "julia"=>string(VERSION),
        "threads"=>Threads.nthreads(),
        "compile_mode"=>Base.JLOptions().compile_enabled,
        "optimization_level"=>Base.JLOptions().opt_level,
        "platform"=>string(Sys.KERNEL, " ", Sys.ARCH),
        "parameters"=>options,
        "imports"=>imports,
        "source_sha256"=>hashes,
        "environment_sha256"=>environment_hashes,
        "json_version"=>string(Base.pkgversion(JSON)),
        "sizes"=>Any[],
        "load_average_start"=>Sys.loadavg(),
        "timing_boundary"=>"script entry; imports separate; first action via invokelatest; warm action via specialized direct call",
        "limitations"=>[
            "Process startup precedes script entry; startup.py measures fresh-process startup",
            "First calls occur after imports and prerequisites; later sizes reuse progressive compiler caches",
            "Measurement and report helpers are outside operation timings; whole script includes them",
            "First calls include invokelatest dispatch/return boxing; warm calls use a direct function barrier",
            "First native warm wrappers may compile before the action timer; caller_elapsed_ns and raw first warm trials retain that boundary",
            "No-op harness control is reported without subtraction; tiny operation latency includes @timed instrumentation",
            "The script budget is cooperative between operations; an external process deadline must bound a single nonreturning operation",
            "No cache flushing, tmux acquisition, network, installs, or universal regression thresholds",
            "summarysize is reachable Julia object memory, not process RSS or allocator capacity",
            "process_max_rss_bytes is lifetime high-water RSS; it cannot attribute retained memory or growth to one operation",
            "Fixture rows are constructed through a private inert builder; measured query APIs are public",
        ],
    )
    failure = nothing
    try
        Base.JLOptions().compile_enabled == 1 && Base.JLOptions().opt_level == 2 ||
            error("graph measurements require the normal compiler and default -O2 profile")
        realpath(Base.pathof(LibTmux)) ==
        realpath(joinpath(GRAPH_ROOT, "src/LibTmux.jl")) ||
            error("prepared project imports a different LibTmux checkout")
        open(joinpath(destination, "samples.jsonl"), "w") do io
            for n in options["sizes"]
                push!(report["sizes"], graph_size(io, n, options))
            end
        end
        (time_ns()-GRAPH_ENTRY_NS)/1e9 < options["budget"] ||
            error("whole script budget exceeded")
        report["status"] = "pass"
    catch error
        failure = error
        report["status"] = "fail"
        report["error_type"] = string(typeof(error))
        report["error"] = sprint(showerror, error)
    finally
        report["source_unchanged"] = try
            graph_source_hashes() == hashes
        catch source_failure
            report["source_validation_error"] = sprint(showerror, source_failure)
            false
        end
        report["source_unchanged"] || (report["status"] = "invalid_source_changed")
        report["environment_unchanged"] = try
            graph_environment_hashes() == environment_hashes
        catch environment_failure
            report["environment_validation_error"] =
                sprint(showerror, environment_failure)
            false
        end
        report["environment_unchanged"] ||
            (report["status"] = "invalid_environment_changed")
        report["before_reporting_script_ns"] = time_ns()-GRAPH_ENTRY_NS
        report["before_reporting_max_rss_bytes"] = Sys.maxrss()
        report["load_average_end"] = Sys.loadavg()
        open(io -> JSON.print(io, report, 2), joinpath(destination, "report.json"), "w")
    end
    failure === nothing || throw(failure)
    report["status"] == "pass" || error("inputs changed; retained measurements are invalid")
    println("PASS pure graph measurements; raw samples and report retained")
end

function graph_entry(arguments)
    self_test = arguments == ["--self-test"]
    options = self_test ? nothing : graph_parameters(arguments)
    destination = self_test ? nothing : graph_reserve(options["output"])
    imports = Any[]
    hashes = Dict{String,String}()
    try
        packages = (
            ("stdlib_sha_random", () -> (@eval using SHA, Random)),
            ("core", () -> (@eval using LibTmux)),
            ("json", () -> (@eval using JSON)),
        )
        for (name, action) in packages
            self_test && name == "core" && continue
            started = time_ns()
            Base.invokelatest(action)
            push!(imports, Dict("name"=>name, "elapsed_ns"=>time_ns()-started))
            name == "stdlib_sha_random" &&
                merge!(hashes, Base.invokelatest(graph_source_hashes))
        end
        self_test || (@eval import LibTmux.Filters as F)
        self_test ? Base.invokelatest(graph_self_test) :
        Base.invokelatest(graph_main, options, destination, imports, hashes)
    catch failure
        if destination !== nothing
            open(joinpath(destination, "failure.log"), "w") do io
                showerror(io, failure, catch_backtrace())
                println(io)
            end
        end
        rethrow()
    end
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && graph_entry(ARGS)
