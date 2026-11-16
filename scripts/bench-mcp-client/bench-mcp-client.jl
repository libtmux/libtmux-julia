# Measure an installed MCP launcher as an independent stdio client; one sample each of a
# workflow and a stopped-reader run per invocation.
#
# usage:
#   julia --project=benchmark scripts/bench-mcp-client/bench-mcp-client.jl
#       --launcher PATH --socket PATH --tmux PATH --pane ID --output FILE
#       [--warm 0:64] [--budget SECONDS] [--startup SECONDS]
#
# The client owns the launcher's pipes and a blocking `wait4` watcher, and reads, writes
# and waits for exit in one `poll`; it never polls for readiness. It speaks newline
# JSON to the launcher and does not use the package's own transport. The client's own
# code is compiled before the launcher starts, so no measured interval includes it.
# The tests are in tests/runtests.jl.

module BenchMCPClient

import JSON
import SHA

include(joinpath(@__DIR__, "..", "owned-process", "owned-process.jl"))
using .OwnedProcess

const PROTOCOL = "2026-07-28"
const FRAME_LIMIT = 8 * 1024 * 1024
const DIAGNOSTIC_LIMIT = 1024 * 1024
const REQUEST_LIMIT = 2 * 1024 * 1024
const MESSAGE_QUEUE_LIMIT = 64
const TOOLS = (
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
# fcntl commands that read and set a pipe's capacity; Linux only.
const F_SETPIPE_SZ = 1031
const F_GETPIPE_SZ = 1032

"A measurement could not establish its stated boundary."
struct MeasurementError <: Exception
    message::String
end
Base.showerror(io::IO, error::MeasurementError) = print(io, error.message)

"""
    frame(identity, method, params=nothing) -> Vector{UInt8}

One newline-terminated JSON-RPC message. The protocol version and client capabilities go
in `params._meta`, which keeps any `_meta` the caller names. A `nothing` identity makes a
notification.
"""
function frame(@nospecialize(identity), method::AbstractString, params=nothing)
    metadata = Dict{String,Any}(
        "io.modelcontextprotocol/protocolVersion" => PROTOCOL,
        "io.modelcontextprotocol/clientCapabilities" => Dict{String,Any}(),
    )
    arguments = Dict{String,Any}(params === nothing ? Dict{String,Any}() : params)
    merge!(metadata, pop!(arguments, "_meta", Dict{String,Any}()))
    arguments["_meta"] = metadata
    message =
        Dict{String,Any}("jsonrpc" => "2.0", "method" => method, "params" => arguments)
    identity === nothing || (message["id"] = identity)
    Vector{UInt8}(codeunits(JSON.json(message) * "\n"))
end

"The `result` of a reply, or a failure that names only a bounded error code."
function checked_result(message)
    (haskey(message, "error") || !haskey(message, "result")) &&
        throw(MeasurementError("protocol request failed"))
    result = message["result"]
    if get(result, "isError", false) === true
        content = get(result, "structuredContent", Dict())
        code = get(get(content, "error", Dict()), "code", "unknown")
        throw(MeasurementError("tool failed: " * first(string(code), 64)))
    end
    result
end

struct Message
    data::Dict{String,Any}
    received_ns::UInt64
    bytes::Int
    sha256::String
end

mutable struct Client
    deadline::Float64
    started_ns::UInt64
    child::Child
    spawned_ns::UInt64
    pending::Vector{UInt8}
    messages::Vector{Message}
    pending_output::Vector{UInt8}
    message_bytes::Int
    stdin_bytes::Int
    stdout_bytes::Int
    stderr_bytes::Int
    stdout_digest::SHA.SHA2_256_CTX
    stderr_digest::SHA.SHA2_256_CTX
    # What the next poll waits for.
    watch_stdout::Bool
    watch_stderr::Bool
    watch_stdin::Bool
    watch_exit::Bool
    paused::Bool
    wire_samples::Vector{Dict{String,Any}}
end

"""
    Client(command, deadline) -> Client

Start `command` with its stdin and stdout and stderr on pipes the client owns. `deadline`
is a `monotonic()` time that bounds every wait. The environment is the caller's without
`TMUX` and `TMUX_PANE`.
"""
function Client(command, deadline::Real)
    started_ns = time_ns()
    environment = Dict{String,String}(ENV)
    delete!(environment, "TMUX")
    delete!(environment, "TMUX_PANE")
    child = spawn_child(
        collect(String, command);
        env=environment,
        stdin=:pipe,
        group=false,
        reap=true,
    )
    Client(
        deadline,
        started_ns,
        child,
        time_ns(),
        UInt8[],
        Message[],
        UInt8[],
        0,
        0,
        0,
        0,
        SHA.SHA2_256_CTX(),
        SHA.SHA2_256_CTX(),
        true,
        true,
        false,
        true,
        false,
        Dict{String,Any}[],
    )
end

function remaining(client::Client, deadline::Real)
    left = min(client.deadline, deadline) - monotonic()
    left <= 0 && throw(MeasurementError("event deadline exceeded"))
    left
end

function accept_stdout!(client::Client, chunk::AbstractVector{UInt8})
    client.stdout_bytes += length(chunk)
    SHA.update!(client.stdout_digest, chunk)
    append!(client.pending, chunk)
    length(client.pending) > FRAME_LIMIT &&
        throw(MeasurementError("stdout frame exceeded byte bound"))
    while (newline = findfirst(==(0x0a), client.pending)) !== nothing
        line = client.pending[1:(newline-1)]
        deleteat!(client.pending, 1:newline)
        data = JSON.parse(String(copy(line)); dicttype=Dict{String,Any})
        client.message_bytes += length(line) + 1
        (
            length(client.messages) >= MESSAGE_QUEUE_LIMIT ||
            client.message_bytes > FRAME_LIMIT
        ) && throw(MeasurementError("unconsumed reply queue exceeded bound"))
        push!(
            client.messages,
            Message(data, time_ns(), length(line) + 1, bytes2hex(SHA.sha256([line; 0x0a]))),
        )
    end
    nothing
end

function accept_stderr!(client::Client, chunk::AbstractVector{UInt8})
    client.stderr_bytes += length(chunk)
    SHA.update!(client.stderr_digest, chunk)
    client.stderr_bytes > DIAGNOSTIC_LIMIT &&
        throw(MeasurementError("diagnostics exceeded byte bound"))
    nothing
end

"""
    pump!(client, deadline)

Wait for one batch of events from the launcher's pipes and its exit, or for room to write
a pending request, and handle them. Throws when `deadline`, or the client's own, passes
with nothing to handle.
"""
function pump!(client::Client, deadline::Real)
    child = client.child
    entries = PollFD[]
    client.watch_stdin && push!(entries, PollFD(child.stdin, POLLOUT, 0))
    client.watch_exit && push!(entries, PollFD(child.wake_read, POLLIN, 0))
    client.watch_stdout && push!(entries, PollFD(child.stdout, POLLIN, 0))
    client.watch_stderr && push!(entries, PollFD(child.stderr, POLLIN, 0))
    if poll!(entries, remaining(client, deadline)) == 0
        monotonic() >= min(client.deadline, deadline) &&
            throw(MeasurementError("event deadline exceeded"))
        return nothing
    end
    for entry in entries
        entry.revents == 0 && continue
        if entry.fd == child.stdin && client.watch_stdin
            count = write_available(child.stdin, client.pending_output)
            count === nothing && continue
            client.stdin_bytes += count
            deleteat!(client.pending_output, 1:count)
            isempty(client.pending_output) && (client.watch_stdin = false)
        elseif entry.fd == child.wake_read
            drain_wake(child)
            client.watch_exit = false
            child.watch_error === nothing ||
                throw(MeasurementError("process watcher failed: " * child.watch_error))
        else
            chunk = read_available(entry.fd)
            chunk === nothing && continue
            if isempty(chunk)
                entry.fd == child.stdout ? (client.watch_stdout = false) :
                (client.watch_stderr = false)
            elseif entry.fd == child.stdout
                accept_stdout!(client, chunk)
            else
                accept_stderr!(client, chunk)
            end
        end
    end
    nothing
end

"Write one request and return its size in bytes."
function send!(
    client::Client,
    @nospecialize(identity),
    method,
    params=nothing;
    timeout::Real=30,
)
    client.child.exited && throw(MeasurementError("child exited before request"))
    data = frame(identity, method, params)
    (!isempty(client.pending_output) || length(data) > REQUEST_LIMIT) &&
        throw(MeasurementError("outgoing request exceeded bound"))
    append!(client.pending_output, data)
    client.watch_stdin = true
    deadline = monotonic() + timeout
    while !isempty(client.pending_output)
        pump!(client, deadline)
    end
    length(data)
end

"""
    receive!(client; identity, progress, timeout) -> Message

Take the queued reply to request `identity`, or the progress notification for token
`progress`, waiting for it if it has not arrived.
"""
receive!(client::Client; identity=nothing, progress=nothing, timeout::Real=30) =
    take_message!(client, identity, progress, timeout)

# One compiled method for every kind of identity, so a first use of another kind never
# compiles inside a measured interval.
function take_message!(
    client::Client,
    @nospecialize(identity),
    @nospecialize(progress),
    timeout,
)
    deadline = monotonic() + timeout
    while true
        for (index, message) in enumerate(client.messages)
            data = message.data
            matches =
                (identity !== nothing && get(data, "id", nothing) == identity) || (
                    progress !== nothing &&
                    get(data, "method", nothing) == "notifications/progress" &&
                    get(get(data, "params", Dict()), "progressToken", nothing) == progress
                )
            if matches
                deleteat!(client.messages, index)
                client.message_bytes -= message.bytes
                return message
            end
        end
        client.child.exited && throw(MeasurementError("child exited before expected reply"))
        pump!(client, deadline)
    end
end

"Send a request, wait for its reply, check it and record the round trip."
function request!(
    client::Client,
    @nospecialize(identity),
    method,
    params=nothing;
    timeout::Real=30,
    label=nothing,
)
    started = time_ns()
    request_bytes = send!(client, identity, method, params; timeout)
    reply = receive!(client; identity, timeout)
    checked_result(reply.data)
    push!(
        client.wire_samples,
        Dict{String,Any}(
            "phase" => label === nothing ? method : label,
            "elapsed_ns" => Int(reply.received_ns - started),
            "request_bytes" => request_bytes,
            "response_bytes" => reply.bytes,
            "response_sha256" => reply.sha256,
        ),
    )
    reply.data, reply.bytes
end

"Call a tool and return its structured content."
function call!(
    client::Client,
    @nospecialize(identity),
    name,
    arguments=nothing;
    label=nothing,
)
    reply, _ = request!(
        client,
        identity,
        "tools/call",
        Dict{String,Any}(
            "name" => name,
            "arguments" => arguments === nothing ? Dict{String,Any}() : arguments,
        );
        label=label === nothing ? name : label,
    )
    checked_result(reply)["structuredContent"]
end

"Start a wait that never matches and return once the launcher reports it is waiting."
function wait_progress!(client::Client, @nospecialize(identity))
    started = time_ns()
    sent = send!(
        client,
        identity,
        "tools/call",
        Dict{String,Any}(
            "name" => "wait_for_text",
            "arguments" => Dict{String,Any}("text" => "absent-benchmark-marker"),
            "_meta" => Dict{String,Any}("progressToken" => identity),
        ),
    )
    message = receive!(client; progress=identity)
    get(message.data["params"], "message", nothing) == "waiting" ||
        throw(MeasurementError("wait did not reach its observation boundary"))
    push!(
        client.wire_samples,
        Dict{String,Any}(
            "phase" => "wait_progress",
            "elapsed_ns" => Int(message.received_ns - started),
            "request_bytes" => sent,
            "response_bytes" => message.bytes,
            "response_sha256" => message.sha256,
        ),
    )
    nothing
end

"Stop reading stdout, so the launcher's writer can fill the pipe."
function pause_stdout!(client::Client)
    client.watch_stdout = false
    client.paused = true
end

"Read exactly one byte of stdout, which proves the writer entered, and no more."
function first_paused_byte!(client::Client, timeout::Real=30)
    child = client.child
    deadline = monotonic() + timeout
    entries = [PollFD(child.stdout, POLLIN, 0), PollFD(child.wake_read, POLLIN, 0)]
    poll!(entries, remaining(client, deadline))
    if entries[1].revents == 0 || entries[2].revents != 0
        throw(MeasurementError("writer did not enter before child exit/deadline"))
    end
    byte = read_available(child.stdout, 1)
    (byte === nothing || isempty(byte)) &&
        throw(MeasurementError("stdout ended before writer entry"))
    client.stdout_bytes += 1
    SHA.update!(client.stdout_digest, byte)
    nothing
end

"""
    eof_and_join!(client) -> (eof_ns, exit_ns)

Close the launcher's stdin and wait for it to exit cleanly. A paused stdout stays
unread until the exit; then its finite remainder is drained without parsing a partial
reply.
"""
function eof_and_join!(client::Client)
    child = client.child
    client.watch_stdin = false
    eof_ns = time_ns()
    close_fd(child.stdin)
    child.stdin = -1
    while child.exit_ns === nothing
        pump!(client, client.deadline)
    end
    wait(child.watcher)
    code = exit_code(child.status)
    code == 0 || throw(MeasurementError("launcher exit was not clean"))
    for (label, fd) in (("stdout", child.stdout), ("stderr", child.stderr))
        while true
            chunk = read_available(fd, 65536)
            chunk === nothing &&
                throw(MeasurementError("pipe remained open after direct child exit"))
            isempty(chunk) && break
            if label == "stdout" && !client.paused
                accept_stdout!(client, chunk)
            elseif label == "stdout"
                client.stdout_bytes += length(chunk)
                SHA.update!(client.stdout_digest, chunk)
                client.stdout_bytes > FRAME_LIMIT &&
                    throw(MeasurementError("paused output exceeded byte bound"))
            else
                accept_stderr!(client, chunk)
            end
        end
    end
    eof_ns, child.exit_ns
end

function report(client::Client)
    child = client.child
    usage = child.usage === nothing ? nothing : usage_fields(child.usage)
    Dict{String,Any}(
        "spawn_ns" => Int(client.spawned_ns - client.started_ns),
        "exit_code" => child.status === nothing ? nothing : exit_code(child.status),
        "stdin_bytes" => client.stdin_bytes,
        "stdout_bytes" => client.stdout_bytes,
        "stderr_bytes" => client.stderr_bytes,
        "stdout_sha256" => bytes2hex(SHA.digest!(client.stdout_digest)),
        "stderr_sha256" => bytes2hex(SHA.digest!(client.stderr_digest)),
        "child_max_rss_bytes" => usage === nothing ? nothing : usage.max_rss_bytes,
        "child_user_seconds" => usage === nothing ? nothing : usage.user_seconds,
        "child_system_seconds" => usage === nothing ? nothing : usage.system_seconds,
        "samples" => client.wire_samples,
    )
end

function Base.close(client::Client)
    child = client.child
    child.exited || signal_process(child, Base.SIGKILL)
    wait(child.watcher)
    foreach(
        close_fd,
        (child.stdin, child.stdout, child.stderr, child.wake_read, child.wake_write),
    )
    nothing
end

# The pipe's capacity, or nothing where the system does not report it.
function pipe_capacity(fd)
    Sys.islinux() || return nothing
    size = ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_GETPIPE_SZ, 0)
    size < 0 ? nothing : Int(size)
end

# Shrink the pipe to its smallest size, so a small reply can fill it.
function shrink_pipe(fd)
    ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_SETPIPE_SZ, 4096) < 0 && return nothing
    pipe_capacity(fd)
end

"The launcher's command line, as the installed product is run."
function launcher_command(options)
    command = [
        options.launcher,
        "--socket",
        options.socket,
        "--tmux",
        options.tmux,
        "--caller-pane",
        options.pane,
        "--allow-pane",
        options.pane,
        "--timeout",
        "30",
        "--workers",
        "2",
        "--capacity",
        "4",
        "--allow-create",
    ]
    for tool in TOOLS
        push!(command, "--tool", tool)
    end
    command
end

"""
    run_sample(command, options, deadline; backpressure) -> Dict

Run one bounded sample against a fresh launcher and return its report. A workflow
sample lists and captures panes, creates a session, cancels a wait and closes stdin. A
backpressure sample stops reading stdout with a reply pending, cancels, closes stdin
and requires the launcher to exit. The report is also pushed to `options.results`, and
a failure is rethrown after it is recorded.
"""
function run_sample(command, options, deadline::Real; backpressure::Bool)
    # Linux counts the spawner's peak in a child's ru_maxrss, so report how large it is.
    spawner_max_rss_bytes = Sys.maxrss()
    client = Client(command, deadline)
    result = Dict{String,Any}(
        "kind" => backpressure ? "backpressure" : "workflow",
        "status" => "running",
    )
    try
        reply, _ = request!(
            client,
            "discover",
            "server/discover";
            timeout=options.startup,
            label="discovery",
        )
        result["process_to_discovery_ns"] = Int(time_ns() - client.started_ns)
        result["supported_versions"] = checked_result(reply)["supportedVersions"]
        _, catalog_bytes = request!(client, "catalog1", "tools/list"; label="catalog")
        if backpressure
            capacity = pipe_capacity(client.child.stdout)
            if capacity === nothing
                result["status"] = "unsupported_pipe_capacity"
                eof_and_join!(client)
                return result
            end
            original_capacity = capacity
            if catalog_bytes - 1 <= capacity
                capacity = something(shrink_pipe(client.child.stdout), capacity)
            end
            if catalog_bytes - 1 <= capacity
                result["status"] = "inconclusive_reply_fits_pipe"
                result["pipe_capacity_bytes"] = capacity
                eof_and_join!(client)
                return result
            end
            wait_progress!(client, "blocked-wait")
            (isempty(client.messages) && isempty(client.pending)) ||
                throw(MeasurementError("unexpected output before backpressure boundary"))
            pause_stdout!(client)
            prior_stdout_bytes = client.stdout_bytes
            requested_ns = time_ns()
            send!(client, "catalog2", "tools/list")
            first_paused_byte!(client)
            writer_entry_ns = Int(time_ns() - requested_ns)
            cancelled_ns = time_ns()
            send!(
                client,
                nothing,
                "notifications/cancelled",
                Dict{String,Any}("requestId" => "blocked-wait"),
            )
            eof_ns, exit_ns = eof_and_join!(client)
            merge!(
                result,
                Dict{String,Any}(
                    "backpressure_proven" => true,
                    "pipe_capacity_bytes" => capacity,
                    "original_pipe_capacity_bytes" => original_capacity,
                    "expected_reply_bytes" => catalog_bytes,
                    "bytes_consumed_before_eof" => 1,
                    "writer_entry_ns" => writer_entry_ns,
                    "bytes_drained_after_exit" =>
                        client.stdout_bytes - prior_stdout_bytes - 1,
                    "cancel_to_exit_ns" => Int(exit_ns - cancelled_ns),
                    "eof_to_exit_ns" => Int(exit_ns - eof_ns),
                ),
            )
        else
            first = call!(client, "list-first", "list_panes"; label="first_list")
            (length(first["panes"]) == 1 && first["panes"][1]["caller"] === true) ||
                throw(MeasurementError("fixture pane policy changed"))
            captured = call!(client, "capture-first", "capture_pane"; label="first_capture")
            capture_digest = SHA.sha256(codeunits(captured["text"]))
            result["capture_text_bytes"] = ncodeunits(captured["text"])
            for index = 0:(options.warm-1)
                call!(client, "list-$index", "list_panes"; label="warm_list")
                actual =
                    call!(client, "capture-$index", "capture_pane"; label="warm_capture")
                SHA.sha256(codeunits(actual["text"])) == capture_digest || throw(
                    MeasurementError("capture content changed between equal workloads"),
                )
            end
            created = call!(
                client,
                "create",
                "create_session",
                Dict{String,Any}("name" => "benchmark-owned", "command" => ["/bin/cat"]),
            )
            result["application_owned_session_created"] =
                created["ownership"] == "application"
            wait_progress!(client, "waiting")
            call!(client, "concurrent", "list_panes"; label="unrelated_list_during_wait")
            cancelled_ns = time_ns()
            send!(
                client,
                nothing,
                "notifications/cancelled",
                Dict{String,Any}("requestId" => "waiting"),
            )
            discovered, _ = request!(
                client,
                "after-cancel",
                "server/discover";
                label="reader_discovery_after_cancel",
            )
            checked_result(discovered)["supportedVersions"] ==
            result["supported_versions"] ||
                throw(MeasurementError("discovery profile changed after cancellation"))
            eof_ns, exit_ns = eof_and_join!(client)
            merge!(
                result,
                Dict{String,Any}(
                    "cancel_to_exit_ns" => Int(exit_ns - cancelled_ns),
                    "eof_to_exit_ns" => Int(exit_ns - eof_ns),
                    "cancellation_retirement" => "EOF-joined upper bound; no cancellation acknowledgement",
                ),
            )
            (isempty(client.messages) && isempty(client.pending)) ||
                throw(MeasurementError("unexpected late protocol output"))
        end
        result["status"] = "pass"
        return result
    catch error
        result["status"] = "fail"
        result["error_type"] = string(nameof(typeof(error)))
        error isa MeasurementError && (result["error"] = error.message)
        rethrow()
    finally
        close(client)
        merge!(result, report(client))
        result["spawner_max_rss_bytes"] = spawner_max_rss_bytes
        push!(options.results, result)
    end
end

# Compile the client's code against `cat`, which echoes every request, so that no
# measured interval includes compilation.
function warm_up()
    client = Client(["cat"], monotonic() + 30)
    try
        refuses(action) =
            try
                action()
                false
            catch error
                error isa MeasurementError || rethrow()
                true
            end
        send!(client, "warm", "ping")
        receive!(client; identity="warm")
        send!(
            client,
            nothing,
            "notifications/progress",
            Dict{String,Any}("progressToken" => "warm", "message" => "waiting"),
        )
        receive!(client; progress="warm")
        # An echo has no result, so a checked request refuses it after the full round trip.
        refuses(() -> request!(client, "echo", "ping"; timeout=5)) || error("echo accepted")
        refuses(() -> call!(client, "tool", "list_panes")) ||
            error("echo accepted as a tool reply")
        refuses(() -> checked_result(Dict("result" => Dict("isError" => true)))) ||
            error("tool error accepted")
        something(shrink_pipe(client.child.stdout), 0)
        pause_stdout!(client)
        send!(client, "paused", "ping")
        first_paused_byte!(client)
        eof_and_join!(client)
        report(client)
    finally
        close(client)
    end
    nothing
end

const USAGE = """
usage: bench-mcp-client.jl --launcher PATH --socket PATH --tmux PATH --pane ID
           --output FILE [--warm 0:64] [--budget SECONDS] [--startup SECONDS]"""

"The command line cannot be turned into a measurement."
struct UsageError <: Exception
    message::String
end
Base.showerror(io::IO, error::UsageError) = print(io, error.message)

function options(arguments)
    values = Dict{String,String}("--warm" => "5", "--budget" => "180", "--startup" => "90")
    required = ("--launcher", "--socket", "--tmux", "--pane", "--output")
    rest = collect(String, arguments)
    seen = Set{String}()
    while !isempty(rest)
        name = popfirst!(rest)
        (name in required || haskey(values, name)) && !isempty(rest) ||
            throw(UsageError("unknown option or missing value: $name"))
        name in seen && throw(UsageError("duplicate option: $name"))
        push!(seen, name)
        values[name] = popfirst!(rest)
    end
    for name in required
        haskey(values, name) || throw(UsageError("missing $name"))
    end
    function number(type, name)
        value = tryparse(type, values[name])
        value === nothing && throw(UsageError("$name must be a number"))
        value
    end
    warm, budget, startup =
        number(Int, "--warm"), number(Float64, "--budget"), number(Float64, "--startup")
    (0 <= warm <= 64 && 0 < budget <= 600 && 0 < startup <= 180) ||
        throw(UsageError("warm, budget or startup limit is out of range"))
    (;
        launcher=values["--launcher"],
        socket=values["--socket"],
        tmux=values["--tmux"],
        pane=values["--pane"],
        output=values["--output"],
        warm,
        budget,
        startup,
        results=Dict{String,Any}[],
    )
end

function main(arguments=ARGS)
    parsed = try
        options(arguments)
    catch error
        error isa UsageError || rethrow()
        println(stderr, "bench-mcp-client: ", error.message)
        println(stderr, USAGE)
        return 2
    end
    warm_up()
    # An exclusive create, before any sample runs: existing measurements are preserved.
    destination = try
        Base.Filesystem.open(
            abspath(parsed.output),
            Base.Filesystem.JL_O_WRONLY | Base.Filesystem.JL_O_CREAT |
            Base.Filesystem.JL_O_EXCL,
            0o644,
        )
    catch error
        error isa Base.IOError || rethrow()
        println(stderr, "bench-mcp-client: ", sprint(showerror, error))
        return 1
    end
    command = launcher_command(parsed)
    started = time_ns()
    deadline = monotonic() + parsed.budget
    report = Dict{String,Any}(
        "schema_version" => 1,
        "status" => "running",
        "protocol" => PROTOCOL,
        "driver_julia" => string(VERSION),
        "platform" => lowercase(string(Sys.KERNEL)),
        "samples" => parsed.results,
    )
    failure = nothing
    try
        run_sample(command, parsed, deadline; backpressure=false)
        run_sample(command, parsed, deadline; backpressure=true)
        report["status"] =
            all(sample -> sample["status"] == "pass", parsed.results) ? "pass" : "partial"
    catch error
        failure = error
        report["status"] = "fail"
        report["error_type"] = string(nameof(typeof(error)))
    finally
        report["client_driver_body_ns"] = Int(time_ns() - started)
        try
            write(destination, sprint(io -> JSON.print(io, report, 2)) * "\n")
        finally
            close(destination)
        end
    end
    failure === nothing && return 0
    println(stderr, "bench-mcp-client: ", sprint(showerror, failure))
    1
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(BenchMCPClient.main(ARGS))
