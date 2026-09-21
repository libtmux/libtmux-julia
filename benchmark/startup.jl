const STARTUP_ENTRY_NS = time_ns()
const STARTUP_SELF_TEST = ARGS == ["--self-test"]
isempty(ARGS) || STARTUP_SELF_TEST || error("usage: startup.jl [--self-test]")

function startup_emit(io, name, status, elapsed, rss)
    println(
        io,
        "LTJ_STARTUP_PHASE\t",
        name,
        '\t',
        status,
        '\t',
        elapsed,
        '\t',
        time_ns() - STARTUP_ENTRY_NS,
        '\t',
        rss,
    )
    flush(io)
end

Base.@noinline function startup_phase!(@nospecialize(action), records, name; io=stdout)
    record = Dict{String,Any}("name"=>name, "status"=>"running")
    push!(records, record)
    started = time_ns()
    try
        measurement = @timed Base.invokelatest(action)
        record["allocated_bytes"] = measurement.bytes
        record["gc_seconds"] = measurement.gctime
        record["status"] = "pass"
        measurement.value
    catch error
        record["status"] = "failed"
        record["error_type"] = string(typeof(error))
        rethrow()
    finally
        record["elapsed_ns"] = time_ns() - started
        record["max_rss_bytes"] = Sys.maxrss()
        record["from_script_entry_ns"] = time_ns() - STARTUP_ENTRY_NS
        startup_emit(
            io,
            name,
            record["status"],
            record["elapsed_ns"],
            record["max_rss_bytes"],
        )
    end
end

function startup_source_hashes()
    root = dirname(@__DIR__)
    files = [
        joinpath(root, name) for name in (
            "Project.toml",
            "benchmark/Project.toml",
            "benchmark/startup.jl",
            "benchmark/startup.py",
        )
    ]
    for entry in ("src", "ext")
        for (directory, _, names) in walkdir(joinpath(root, entry)), name in names
            endswith(name, ".jl") && push!(files, joinpath(directory, name))
        end
    end
    Dict(relpath(path, root)=>bytes2hex(open(SHA.sha256, path)) for path in sort!(files))
end

const STARTUP_IMPORTS = Dict{String,Any}[]
const STARTUP_HASHES = Dict{String,String}()
const STARTUP_LOAD_FAILURE = Ref{Any}(nothing)
if !STARTUP_SELF_TEST
    let started = time_ns()
        @eval using SHA
        merge!(STARTUP_HASHES, Base.invokelatest(startup_source_hashes))
        elapsed = time_ns() - started
        push!(
            STARTUP_IMPORTS,
            Dict(
                "name"=>"sha_and_source_setup",
                "status"=>"pass",
                "elapsed_ns"=>elapsed,
                "max_rss_bytes"=>Sys.maxrss(),
            ),
        )
        startup_emit(stdout, "sha_and_source_setup", "pass", elapsed, Sys.maxrss())
    end
    let started = time_ns(), status = "pass"
        try
            @eval using LibTmux
        catch error
            status = "failed"
            STARTUP_LOAD_FAILURE[] = error
        end
        elapsed = time_ns() - started
        record = Dict{String,Any}(
            "name"=>"package_load",
            "status"=>status,
            "elapsed_ns"=>elapsed,
            "max_rss_bytes"=>Sys.maxrss(),
        )
        STARTUP_LOAD_FAILURE[] === nothing ||
            (record["error_type"] = string(typeof(STARTUP_LOAD_FAILURE[])))
        push!(STARTUP_IMPORTS, record)
        startup_emit(stdout, "package_load", status, elapsed, Sys.maxrss())
    end
end

function startup_workload!(report)
    phases = report["phases"]
    owned = connection = nothing
    directory = nothing
    report["status"] = "running"
    report["ownership"] = Dict{String,Any}(
        "owned_close_returned"=>false,
        "control_close_returned"=>false,
        "pane_descendants_retired"=>"not independently proved",
    )
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    try
        Base.get_extension(LibTmux, :LibTmuxJSONExt) === nothing ||
            error("cold-core sample must not activate the JSON extension")
        any(id -> id.name == "JSON", keys(Base.loaded_modules)) &&
            error("cold-core sample must not import JSON")
        report["json_extension_loaded_before_workflow"] = false
        report["loaded_source"] = pathof(LibTmux)
        realpath(dirname(pathof(LibTmux))) ==
        realpath(joinpath(dirname(@__DIR__), "src")) ||
            error("benchmark project loaded a different LibTmux source")
        owned = startup_phase!(phases, "owned_daemon_ready") do
            LibTmux.open_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment)
        end
        server = owned.server
        directory = dirname(server.socket_path)
        session = startup_phase!(phases, "first_session") do
            LibTmux.new_session(server; name="startup", command=["/bin/cat"])
        end
        graph = startup_phase!(() -> LibTmux.snapshot(server), phases, "first_snapshot")
        pane = only(LibTmux.panes(graph)).ref
        captured = startup_phase!(phases, "first_process_capture") do
            LibTmux.capture_bytes(server, pane; max_bytes=64*1024)
        end
        connection = startup_phase!(phases, "first_control_ready") do
            LibTmux.open_control(server, session)
        end
        control_graph = startup_phase!(phases, "first_control_snapshot") do
            LibTmux.snapshot(connection)
        end
        control_capture = startup_phase!(phases, "first_control_capture") do
            LibTmux.capture_bytes(connection, pane; max_bytes=64*1024)
        end
        @assert LibTmux.entitykey.(LibTmux.panes(graph)) ==
                LibTmux.entitykey.(LibTmux.panes(control_graph))
        @assert all(byte -> byte in (0x20, 0x0a), captured)
        @assert all(byte -> byte in (0x20, 0x0a), control_capture)
        report["process_capture_bytes"] = length(captured)
        report["control_capture_bytes"] = length(control_capture)
        report["physical_panes"] = length(LibTmux.panes(graph))
        report["control_clients"] = length(LibTmux.clients(control_graph))
        report["status"] = "pass"
    catch error
        report["status"] = "failed"
        report["error_type"] = string(typeof(error))
    finally
        if connection !== nothing
            try
                startup_phase!(() -> close(connection), phases, "control_teardown")
                report["ownership"]["control_close_returned"] = true
            catch error
                report["status"] = "failed"
                report["control_cleanup_error_type"] = string(typeof(error))
            end
        end
        if owned !== nothing
            try
                startup_phase!(() -> close(owned), phases, "owned_daemon_teardown")
                report["ownership"]["owned_close_returned"] = true
            catch error
                report["status"] = "failed"
                report["daemon_cleanup_error_type"] = string(typeof(error))
            end
        end
        if directory !== nothing
            report["ownership"]["socket_directory_removed"] = !ispath(directory)
            ispath(directory) && (report["status"] = "failed")
        end
    end
end

function startup_encode(report)
    encoded = IOBuffer()
    TOML.print(encoded, report; sorted=true)
    String(take!(encoded))
end

function startup_main()
    report = Dict{String,Any}(
        "schema_version"=>1,
        "julia"=>string(VERSION),
        "threads"=>Threads.nthreads(),
        "compile_mode"=>Base.JLOptions().compile_enabled,
        "optimization_level"=>Base.JLOptions().opt_level,
        "platform"=>string(Sys.KERNEL),
        "architecture"=>string(Sys.ARCH),
        "imports"=>STARTUP_IMPORTS,
        "source_sha256"=>STARTUP_HASHES,
        "phases"=>Dict{String,Any}[],
        "phase_dispatch"=>"invokelatest includes action compilation and dispatch; excludes earlier harness compilation",
        "package_load_boundary"=>"LibTmux follows SHA/source setup; this harness imports TOML only after teardown and never JSON",
        "fresh_process_boundary"=>"script timestamp follows interpreter startup; Python records whole process",
    )
    if STARTUP_LOAD_FAILURE[] === nothing
        startup_workload!(report)
    else
        report["status"] = "failed"
        report["error_type"] = string(typeof(STARTUP_LOAD_FAILURE[]))
    end
    report["through_cleanup_ns"] = time_ns() - STARTUP_ENTRY_NS
    report["before_reporting_max_rss_bytes"] = Sys.maxrss()
    import_started = time_ns()
    @eval using TOML
    report["toml_import_ns"] = time_ns() - import_started
    startup_emit(stdout, "reporting_import", "pass", report["toml_import_ns"], Sys.maxrss())
    encode_started = time_ns()
    body = Base.invokelatest(startup_encode, report)
    startup_emit(
        stdout,
        "reporting_encode",
        "pass",
        time_ns() - encode_started,
        Sys.maxrss(),
    )
    println("LTJ_STARTUP_TOML_BEGIN")
    print(body)
    println("LTJ_STARTUP_TOML_END")
    flush(stdout)
    report["status"] == "pass" ? 0 : 1
end

function startup_self_test()
    records = Dict{String,Any}[]
    output = IOBuffer()
    @assert startup_phase!(() -> 7, records, "success"; io=output) == 7
    sentinel = ErrorException("critical phase failure")
    caught = try
        startup_phase!(() -> throw(sentinel), records, "failure"; io=output)
        nothing
    catch error
        error
    end
    @assert caught === sentinel
    @assert [record["status"] for record in records] == ["pass", "failed"]
    @assert all(record -> record["elapsed_ns"] >= 0, records)
    @assert occursin("failure\tfailed", String(take!(output)))
    @eval using TOML
    encoded = Base.invokelatest(startup_encode, Dict("phases"=>records))
    decoded = Base.invokelatest(text -> TOML.parse(text), encoded)
    @assert decoded["phases"][2]["status"] == "failed"
    @assert !isdefined(Main, :LibTmux)
    println("PASS phase result, original failure, retained timing and late TOML reporting")
end

if STARTUP_SELF_TEST
    startup_self_test()
else
    exit(startup_main())
end
