const OBSERVATION_SCRIPT_ENTRY_NS = time_ns()
using JSON, SHA, Pkg, Random

const OBSERVATION_ROOT = dirname(@__DIR__)

function observation_parameters(arguments)
    values = Dict(
        "samples"=>"3",
        "bytes"=>"4096",
        "capacity"=>"4",
        "timeout"=>"0.9",
        "budget"=>"480",
        "seed"=>"2026",
        "output"=>joinpath(@__DIR__, "results", "observations.json"),
    )
    seen = Set{String}()
    for argument in arguments
        pair = split(argument, '='; limit=2)
        length(pair) == 2 || error("use name=value arguments")
        key, value = pair
        haskey(values, key) && !(key in seen) || error("unknown or duplicate parameter")
        push!(seen, key)
        values[key] = value
    end
    samples, bytes = parse(Int, values["samples"]), parse(Int, values["bytes"])
    capacity = parse(Int, values["capacity"])
    timeout, budget = parse(Float64, values["timeout"]), parse(Float64, values["budget"])
    1 <= samples <= 12 || error("samples must be in 1:12")
    256 <= bytes <= 16384 || error("bytes must be in 256:16384")
    2 <= capacity <= 32 || error("capacity must be in 2:32")
    isfinite(timeout) && 0 < timeout <= 0.9 || error("timeout must be in (0,0.9]")
    isfinite(budget) && 0 < budget <= 540 || error("budget must be in (0,540]")
    (;
        samples,
        bytes,
        capacity,
        timeout,
        budget,
        seed=parse(Int, values["seed"]),
        output=values["output"],
    )
end

observation_payload(count) = UInt8[mod(index - 1, 256) for index = 1:count]

function observation_contains(bytes, needle)
    isempty(needle) && return true
    length(bytes) < length(needle) && return false
    any(
        index -> @view(bytes[index:(index+length(needle)-1)]) == needle,
        1:(length(bytes)-length(needle)+1),
    )
end

function observation_remaining(started, timeout)
    left = timeout - (time_ns() - started) / 1e9
    left > 0 || error("benchmark phase deadline exceeded")
    left
end

function observation_scope(f)
    actions = Function[]
    result = nothing
    failures = Exception[]
    try
        result = f(action -> push!(actions, action))
    catch error
        push!(failures, error)
    finally
        for action in Iterators.reverse(actions)
            try
                action()
            catch error
                push!(failures, error)
            end
        end
    end
    isempty(failures) ||
        throw(length(failures) == 1 ? only(failures) : CompositeException(failures))
    result
end

# Measurement instrumentation only: observe state under the connection lock.
# The workload itself uses public APIs. The deadline task is closed and joined.
function observation_state_ready(ready, connection, timeout)
    expired = Ref(false)
    timer = Timer(timeout)
    watcher = Threads.@spawn begin
        fired = try
            wait(timer)
            true
        catch error
            error isa EOFError || rethrow()
            false
        end
        if fired
            lock(connection.lock) do
                expired[] = true
                notify(connection.changed; all=true)
            end
        end
    end
    try
        lock(connection.lock) do
            while !ready() && connection.state === :open && !expired[]
                wait(connection.changed)
            end
            ready() || error("benchmark state readiness not proved")
        end
    finally
        close(timer)
        wait(watcher)
    end
    nothing
end

observation_reader_ready(stream, timeout) = observation_state_ready(
    () -> stream.consumer !== nothing && stream.open,
    stream.connection,
    timeout,
)

function observation_source_hashes()
    result = Dict{String,String}()
    for (directory, _, names) in walkdir(joinpath(OBSERVATION_ROOT, "src"))
        for name in names
            endswith(name, ".jl") || continue
            path = joinpath(directory, name)
            result[relpath(path, OBSERVATION_ROOT)] = bytes2hex(open(sha256, path))
        end
    end
    for name in ("Project.toml", "benchmark/Project.toml", "benchmark/observations.jl")
        result[name] = bytes2hex(open(sha256, joinpath(OBSERVATION_ROOT, name)))
    end
    result
end

function observation_fixture(server, timeout)
    command(label) = [
        "/bin/sh",
        "-c",
        "stty raw -echo || exit; \"\$1\" -N -S \"\$2\" wait-for -S \"\$3\"; exec /bin/cat",
        "sh",
        server.tmux,
        server.socket_path,
        label,
    ]
    session = new_session(
        server;
        name="observation-benchmark",
        command=command("observation-raw-ready"),
        timeout,
    )
    run_command(server, "wait-for", "observation-raw-ready"; timeout)
    first_graph = snapshot(server; timeout)
    raw = only(panes(first_graph)).ref
    marker_window = new_window(
        server,
        session;
        name="markers",
        command=command("observation-marker-ready"),
        timeout,
    )
    run_command(server, "wait-for", "observation-marker-ready"; timeout)
    graph = snapshot(server; timeout)
    marker =
        only(panes(only(filter(window -> window.ref == marker_window, windows(graph))))).ref
    (; session, raw, marker)
end

function observation_collect(stream, count; timeout)
    started = time_ns()
    initial = observation_cursor(stream).sequence
    previous = initial
    received = UInt8[]
    chunks = Any[]
    while length(received) < count
        event = take!(stream; timeout=observation_remaining(started, timeout))
        event isa PaneOutput || error("unexpected observation event")
        event.cursor.sequence > previous || error("observation sequence did not advance")
        previous = event.cursor.sequence
        append!(received, event.bytes)
        length(received) <= count || error("controlled producer emitted extra bytes")
        push!(
            chunks,
            Dict(
                "sequence"=>event.cursor.sequence,
                "bytes"=>length(event.bytes),
                "arrival_ns"=>time_ns()-started,
                "age_ms"=>event.age_ms,
            ),
        )
    end
    (; received, chunks, initial, final=previous)
end

function observation_raw_trial(server, connection, target, options)
    observation_scope() do own
        setup = time_ns()
        stream = observe_output(
            connection,
            target;
            capacity=256,
            max_bytes=max(65536, 2 * options.bytes),
            timeout=options.timeout,
        )
        own(() -> close(stream))
        payload = observation_payload(options.bytes)
        setup_ns = time_ns() - setup
        started = time_ns()
        producer =
            Threads.@spawn paste_bytes(server, target, payload; timeout=options.timeout)
        own(() -> wait(producer))
        result = observation_collect(stream, length(payload); timeout=options.timeout)
        delivered_ns = time_ns() - started
        fetch(producer)
        Dict(
            "setup_ns"=>setup_ns,
            "elapsed_ns"=>time_ns()-started,
            "delivery_ns"=>delivered_ns,
            "expected_bytes"=>length(payload),
            "expected_sha256"=>bytes2hex(sha256(payload)),
            "received_hex"=>bytes2hex(result.received),
            "chunks"=>result.chunks,
            "initial_sequence"=>result.initial,
            "final_sequence"=>result.final,
            "exact"=>result.received == payload,
        )
    end
end

function observation_slow_trial(server, connection, target, options)
    observation_scope() do own
        setup = time_ns()
        fast = observe_output(
            connection,
            target;
            capacity=64,
            max_bytes=65536,
            timeout=options.timeout,
        )
        own(() -> close(fast))
        slow = observe_output(
            connection,
            target;
            capacity=1,
            max_bytes=128,
            timeout=options.timeout,
        )
        own(() -> close(slow))
        setup_ns = time_ns() - setup
        samples = Any[]
        previous = observation_cursor(fast).sequence
        for index = 1:3
            payload = collect(codeunits("slow-subscriber-$index\r\n"))
            started = time_ns()
            paste_bytes(server, target, payload; timeout=options.timeout)
            result = observation_collect(fast, length(payload); timeout=options.timeout)
            result.received == payload && result.final > previous ||
                error("fast subscriber lost bytes")
            previous = result.final
            push!(
                samples,
                Dict(
                    "elapsed_ns"=>time_ns()-started,
                    "bytes"=>length(payload),
                    "chunks"=>result.chunks,
                ),
            )
        end
        failure = try
            take!(slow; timeout=options.timeout)
            nothing
        catch error
            error
        end
        failure isa ObservationLost && failure.reason === :overflow ||
            error("slow subscriber did not report bounded overflow")
        isopen(fast) || error("fast subscriber closed with slow subscriber")
        Dict(
            "setup_ns"=>setup_ns,
            "slow_capacity"=>1,
            "slow_max_bytes"=>128,
            "slow_result"=>"overflow",
            "fast_open"=>isopen(fast),
            "samples"=>samples,
        )
    end
end

function observation_cancel_trial(server, connection, target, options)
    observation_scope() do own
        setup = time_ns()
        stream = observe_output(connection, target; timeout=options.timeout)
        own(() -> close(stream))
        token = CancellationToken()
        reader = Threads.@spawn try
            take!(stream; timeout=options.timeout, cancel=token)
        catch error
            error
        end
        own(() -> wait(reader))
        own(() -> cancel!(token))
        observation_reader_ready(stream, options.timeout)
        buffer = load_buffer(server, UInt8[0x61]; timeout=options.timeout)
        setup_ns = time_ns() - setup
        started = time_ns()
        run_command(
            connection,
            "delete-buffer",
            "-b",
            string(buffer.id);
            timeout=options.timeout,
        )
        unrelated_ns = time_ns() - started
        started = time_ns()
        cancel!(token)
        outcome = fetch(reader)
        cancel_ns = time_ns() - started
        outcome isa RequestCancelled || error("blocked reader cancellation did not retire")
        Dict(
            "setup_ns"=>setup_ns,
            "unrelated_request_ns"=>unrelated_ns,
            "cancel_to_join_ns"=>cancel_ns,
            "result"=>"RequestCancelled",
            "reader_registration"=>"private locked condition, measurement only",
        )
    end
end

function observation_capacity_trial(server, connection, options)
    reserved = Any[]
    tokens = CancellationToken[]
    readers = Task[]
    observation_scope() do own
        own(() -> begin
            foreach(cancel!, tokens)
            foreach(wait, readers)
            for signal in reserved
                if lock(() -> signal.state === :minted, connection.lock)
                    notify(signal)
                    wait(signal; timeout=options.timeout)
                end
            end
            observation_state_ready(connection, options.timeout) do
                isempty(connection.pending) && isempty(connection.signals)
            end
        end)
        setup = time_ns()
        buffer = load_buffer(server, UInt8[0x61]; timeout=options.timeout)
        for _ = 1:options.capacity
            push!(reserved, control_signal(connection))
        end
        for signal in reserved
            token = CancellationToken()
            push!(tokens, token)
            push!(readers, Threads.@spawn try
                wait(signal; timeout=options.timeout, cancel=token)
            catch error
                error
            end)
        end
        observation_state_ready(connection, options.timeout) do
            all(signal -> signal.request !== nothing && signal.request.sent, reserved)
        end
        pending_peak = lock(() -> length(connection.pending), connection.lock)
        pending_peak == options.capacity || error("pending saturation not established")
        setup_ns = time_ns()-setup
        started = time_ns()
        failure = try
            control_signal(connection)
            nothing
        catch error
            error
        end
        reject_ns = time_ns()-started
        failure isa ArgumentError || error("reserved connection capacity was not enforced")
        started = time_ns()
        foreach(cancel!, tokens)
        outcomes = fetch.(readers)
        cancel_ns = time_ns()-started
        all(error -> error isa RequestCancelled && error.sent, outcomes) ||
            error("submitted cancellation storm did not cancel every caller")
        observation_state_ready(connection, options.timeout) do
            isempty(connection.pending) && isempty(connection.signals)
        end
        retirement_ns = time_ns()-started
        all(signal -> signal.cleanup_done && signal.error === nothing, reserved) ||
            error("backend signal retirement not confirmed")
        started = time_ns()
        run_command(
            connection,
            "delete-buffer",
            "-b",
            string(buffer.id);
            timeout=options.timeout,
        )
        elapsed = time_ns()-started
        Dict(
            "setup_ns"=>setup_ns,
            "capacity"=>options.capacity,
            "rejection_ns"=>reject_ns,
            "submitted_pending_peak"=>pending_peak,
            "cancelled_sent_requests"=>length(outcomes),
            "cancel_to_callers_ns"=>cancel_ns,
            "cancel_to_retirement_ns"=>retirement_ns,
            "pending_after"=>lock(() -> length(connection.pending), connection.lock),
            "signals_after"=>lock(() -> length(connection.signals), connection.lock),
            "recovery_request_ns"=>elapsed,
            "domain"=>"submitted waits at capacity; cancellation callers and backend retirement measured separately",
        )
    end
end

function observation_marker_reader(strategy, connection, target, stream, marker, timeout)
    started = time_ns()
    event_bytes = 0
    captures = Any[]
    if strategy == "event"
        received = UInt8[]
        while !observation_contains(received, marker)
            event = take!(stream; timeout=observation_remaining(started, timeout))
            append!(received, event.bytes)
            event_bytes += length(event.bytes)
            length(received) <= 65536 || error("marker event byte bound exceeded")
        end
    end
    for attempt = 1:256
        before = time_ns()
        screen = capture_bytes(
            connection,
            target;
            max_bytes=65536,
            timeout=observation_remaining(started, timeout),
        )
        found = observation_contains(screen, marker)
        push!(
            captures,
            Dict(
                "elapsed_ns"=>time_ns()-before,
                "bytes"=>length(screen),
                "sha256"=>bytes2hex(sha256(screen)),
                "marker_visible"=>found,
            ),
        )
        found && return Dict(
            "reader_ns"=>time_ns()-started,
            "capture_attempts"=>captures,
            "raw_event_bytes"=>event_bytes,
            "marker_visible"=>true,
        )
        strategy == "event" && error("output event did not establish screen visibility")
    end
    error("capture polling attempt bound exceeded")
end

function observation_marker_trial(strategy, server, connection, target, marker, options)
    observation_scope() do own
        setup = time_ns()
        stream =
            strategy == "event" ?
            observe_output(connection, target; timeout=options.timeout) : nothing
        stream === nothing || own(() -> close(stream))
        setup_ns = time_ns()-setup
        started = time_ns()
        reader = Threads.@spawn observation_marker_reader(
            strategy,
            connection,
            target,
            stream,
            marker,
            options.timeout,
        )
        own(() -> wait(reader))
        producer_started = time_ns()
        paste_bytes(
            server,
            target,
            [UInt8[0x0d, 0x0a]; marker; UInt8[0x0d, 0x0a]];
            timeout=options.timeout,
        )
        producer_ns = time_ns()-producer_started
        result = fetch(reader)
        merge!(
            result,
            Dict(
                "setup_ns"=>setup_ns,
                "elapsed_ns"=>time_ns()-started,
                "producer_ns"=>producer_ns,
                "strategy"=>strategy,
                "marker"=>String(copy(marker)),
            ),
        )
    end
end

function observation_record!(f, samples, iteration, name)
    record = Dict{String,Any}(
        "iteration"=>iteration,
        "phase"=>name,
        "temperature"=>iteration == 1 ? "first_use" : "repeated",
        "status"=>"running",
    )
    push!(samples, record)
    started = time_ns()
    try
        merge!(record, f())
        get(record, "exact", true) || error("raw pane output differs from controlled bytes")
        record["status"] = "pass"
    catch error
        record["status"] = "fail"
        record["error_type"] = string(nameof(typeof(error)))
        rethrow()
    finally
        record["phase_body_ns"] = time_ns()-started
        record["process_max_rss_bytes"] = Sys.maxrss()
    end
end

function observation_publish(output, report)
    destination = abspath(output)
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

function observation_main(arguments)
    options = observation_parameters(arguments)
    ispath(options.output) && error("refusing to overwrite existing measurements")
    samples = Any[]
    started = time_ns()
    report = Dict{String,Any}(
        "schema_version"=>2,
        "status"=>"running",
        "julia"=>string(VERSION),
        "threads"=>Threads.nthreads(),
        "compile_mode"=>Base.JLOptions().compile_enabled,
        "optimization_level"=>Base.JLOptions().opt_level,
        "check_bounds"=>Base.JLOptions().check_bounds,
        "platform"=>string(Sys.KERNEL, " ", Sys.ARCH),
        "source_sha256"=>observation_source_hashes(),
        "load_average_start"=>Sys.loadavg(),
        "dependencies"=>Dict(
            info.name=>string(info.version) for
            info in values(Pkg.dependencies()) if info.name in ("LibTmux", "JSON")
        ),
        "parameters"=>Dict(
            "samples"=>options.samples,
            "bytes"=>options.bytes,
            "capacity"=>options.capacity,
            "timeout_seconds"=>options.timeout,
            "budget_seconds"=>options.budget,
            "seed"=>options.seed,
        ),
        "samples"=>samples,
        "owned_server_closed"=>false,
        "limitations"=>[
            "Raw byte equality covers a controlled raw/no-echo cat PTY; applications may transform input",
            "Output cursors increase but need not be contiguous for one pane",
            "Raw output is not a screen image; marker strategies both require a capture containing the marker",
            "Event strategy wakes on output then captures once; failure does not silently fall back to polling",
            "Capture polling intentionally repeats public capture calls with no sleeps, at most 256 attempts",
            "Each timing includes public API work and scheduling; marker production uses the same paste_bytes path",
            "Private locked reader readiness is measurement instrumentation, not a public library guarantee",
            "Capacity pressure fills the primary pending queue with submitted waits; the auxiliary cleanup lane has separate capacity",
            "Cancellation caller latency is separate from confirmed backend retirement; neither implies rollback",
            "First use is retained; no artificial package warmup or dependency installation runs here",
            "Small raw samples do not establish population tail latency or relative speed",
            "RSS is the driver process lifetime high water, not per-phase allocation or daemon RSS",
            "script_elapsed_ns includes imports from first script statement, excluding Julia executable startup",
        ],
    )
    environment = Dict(
        "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM"=>"xterm-256color",
        "SHELL"=>"/bin/sh",
    )
    random = MersenneTwister(options.seed)
    budget() =
        (time_ns()-started)/1e9 < options.budget || error("benchmark budget exhausted")
    try
        observation_scope() do own
            opening = time_ns()
            owned = open_server(;
                tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"),
                env=environment,
                timeout=options.timeout,
            )
            own(() -> begin
                closing = time_ns()
                close(owned)
                report["owned_server_close_ns"] = time_ns()-closing
                report["owned_server_closed"] = !isopen(owned)
            end)
            server = owned.server
            report["owned_server_open_ns"] = time_ns()-opening
            setup = time_ns()
            fixture = observation_fixture(server, options.timeout)
            report["fixture_setup_ns"] = time_ns()-setup
            report["tmux"] = strip(
                decode_text(
                    run_command(
                        server,
                        "display-message",
                        "-p",
                        "#{version}";
                        timeout=options.timeout,
                    ).stdout,
                ),
            )
            opening = time_ns()
            connection = open_control(
                server,
                fixture.session;
                timeout=options.timeout,
                capacity=options.capacity,
            )
            own(
                () -> begin
                    closing = time_ns()
                    close(connection)
                    report["control_close_ns"] = time_ns()-closing
                    graph = snapshot(server; timeout=options.timeout)
                    report["clients_after_close"] = length(clients(graph))
                    report["fixture_sessions_preserved"] =
                        [item.ref for item in sessions(graph)] == [fixture.session]
                    report["buffers_empty_after_close"] = isempty(
                        run_command(server, "list-buffers"; timeout=options.timeout).stdout,
                    )
                    report["clients_after_close"] == 0 &&
                    report["fixture_sessions_preserved"] &&
                    report["buffers_empty_after_close"] ||
                        error("observation ownership cleanup not proved")
                end,
            )
            report["control_open_ns"] = time_ns()-opening
            for iteration = 1:options.samples
                for (name, operation) in (
                    (
                        "raw_bytes",
                        () ->
                            observation_raw_trial(server, connection, fixture.raw, options),
                    ),
                    (
                        "slow_subscriber",
                        () -> observation_slow_trial(
                            server,
                            connection,
                            fixture.marker,
                            options,
                        ),
                    ),
                    (
                        "reader_cancellation",
                        () -> observation_cancel_trial(
                            server,
                            connection,
                            fixture.marker,
                            options,
                        ),
                    ),
                    (
                        "connection_capacity",
                        () -> observation_capacity_trial(server, connection, options),
                    ),
                )
                    budget()
                    observation_record!(operation, samples, iteration, name)
                end
                for strategy in shuffle(random, ["event", "capture_poll"])
                    budget()
                    marker = collect(
                        codeunits(
                            "OBSERVATION_$(iteration)_$(strategy)_$(rand(random, UInt32))",
                        ),
                    )
                    observation_record!(samples, iteration, "marker_" * strategy) do
                        observation_marker_trial(
                            strategy,
                            server,
                            connection,
                            fixture.marker,
                            marker,
                            options,
                        )
                    end
                end
            end
        end
        budget()
        report["status"] = "pass"
    catch error
        report["status"] = "fail"
        report["error_type"] = string(nameof(typeof(error)))
        rethrow()
    finally
        report["driver_body_ns"] = time_ns()-started
        report["script_elapsed_ns"] = time_ns()-OBSERVATION_SCRIPT_ENTRY_NS
        report["load_average_end"] = Sys.loadavg()
        report["source_unchanged"] = observation_source_hashes() == report["source_sha256"]
        report["source_unchanged"] || (report["status"] = "invalid_source_changed")
        observation_publish(options.output, report)
    end
    report["status"] == "pass" || error("benchmark measurements invalidated")
    println("Observation benchmark pass; raw timings, bytes and cleanup evidence retained")
end

if abspath(PROGRAM_FILE) == (@__FILE__)
    using LibTmux
    observation_main(ARGS)
end
