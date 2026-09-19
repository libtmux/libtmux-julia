"""
    TmuxCommand(argv...)
    TmuxCommand(argv::AbstractVector)

Own one finite command's literal arguments. Construction performs no I/O and
does not interpret shell text or semicolon separators. Control execution still
requires the transport's audited command grammar.
"""
struct TmuxCommand
    arguments::Tuple{Vararg{String}}
    function TmuxCommand(arguments::Union{Tuple,AbstractVector})
        1 <= length(arguments) <= 1024 ||
            throw(ArgumentError("command requires 1:1024 arguments"))
        all(argument -> argument isa AbstractString, arguments) ||
            throw(ArgumentError("tmux command arguments must be strings"))
        owned = Tuple(_argument(argument) for argument in arguments)
        all(argument -> ncodeunits(argument) <= 65536, owned) ||
            throw(ArgumentError("tmux command argument exceeds 65536 bytes"))
        new(owned)
    end
end
TmuxCommand(arguments::AbstractString...) = TmuxCommand(arguments)

"""
One input-indexed outcome. `status` is `:completed`, `:failed`, `:skipped`, or
`:unknown`. `acknowledged` records a response; `completed` records queue
completion for an audited synchronous command. `result` and `error` retain
the evidence. Background application work is never inferred complete.
"""
struct OperationResult
    index::Int
    command::TmuxCommand
    status::Symbol
    result::Union{Nothing,CommandResult,ControlResult}
    error::Union{Nothing,Exception}
    acknowledged::Bool
    completed::Bool
end

abstract type _FiniteCommandResult <: AbstractVector{OperationResult} end

"An ordered, read-only finite collection of independently executed command outcomes."
struct BatchResult <: _FiniteCommandResult
    operations::Vector{OperationResult}
end

"""
An explicit semicolon group's outcomes and aggregate response. `retired`
means its completion fence was observed. `opaque` means the transport could
not attribute the aggregate response to individual commands. A group is not
a transaction; successful effects before an error remain applied.
"""
struct GroupResult <: _FiniteCommandResult
    operations::Vector{OperationResult}
    aggregate::Union{Nothing,CommandResult,ControlResult}
    error::Union{Nothing,Exception}
    retired::Bool
    opaque::Bool
end

Base.size(result::_FiniteCommandResult) = size(result.operations)
Base.IndexStyle(::Type{<:_FiniteCommandResult}) = IndexLinear()
Base.getindex(result::_FiniteCommandResult, index::Int) = result.operations[index]
Base.similar(::_FiniteCommandResult, ::Type{T}, dims::Dims) where {T} =
    Array{T}(undef, dims)

const _BATCH_MAX_COMMANDS = 256
const _BATCH_MAX_ARGUMENT_BYTES = 1024 * 1024

function _batch_commands(target, commands::AbstractVector{TmuxCommand})
    length(commands) <= _BATCH_MAX_COMMANDS ||
        throw(ArgumentError("batch exceeds 256 commands"))
    owned = collect(commands)
    bytes = 0
    for command in owned
        bytes += sum(ncodeunits(argument) + 1 for argument in command.arguments)
        bytes <= _BATCH_MAX_ARGUMENT_BYTES ||
            throw(ArgumentError("batch exceeds 1 MiB of arguments"))
        if target isa ControlConnection
            _admit_control_command(collect(command.arguments))
        else
            argv = _argv(target, collect(_literal_tmux_argument.(command.arguments)))
            sum(ncodeunits(argument) + 1 for argument in argv) <= 14 * 1024 ||
                throw(ArgumentError("batch command exceeds the subprocess 14 KiB limit"))
        end
    end
    owned
end

function _batch_timeout(timeout)
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("batch timeout must be positive and finite"))
    budget
end

function _batch_audited(command)
    try
        _admit_control_command(collect(command.arguments))
        true
    catch error
        error isa ArgumentError || rethrow()
        false
    end
end

_batch_result(error) = nothing
_batch_result(
    error::Union{
        RequestCancelled,
        DeadlineExceeded,
        OutputLimitExceeded,
        ProcessIOError,
        CommandError,
    },
) = error.result
_batch_result(error::ControlCommandError) = error.result
_batch_sent(error) = true
_batch_sent(error::Union{RequestCancelled,DeadlineExceeded,ControlConnectionError}) =
    error.sent
_batch_sent(error::Union{TmuxNotFound,ProcessSpawnError,ArgumentError}) = false

function _batch_error(index, command, error)
    sent = _batch_sent(error)
    status =
        !sent && error isa Union{RequestCancelled,DeadlineExceeded,ControlConnectionError} ?
        :skipped : sent ? :unknown : :failed
    OperationResult(index, command, status, _batch_result(error), error, false, false)
end

function _batch_operation(target, command, index, started, budget, cancel)
    remaining = budget - (time_ns() - started) / 1e9
    remaining > 0 ||
        return _batch_error(index, command, DeadlineExceeded(budget, false, nothing))
    try
        arguments =
            target isa Server ? _literal_tmux_argument.(command.arguments) :
            command.arguments
        result = run_command(target, arguments...; timeout=remaining, cancel, check=false)
        signalled = result isa CommandResult && result.termsignal != 0
        failed = result isa ControlResult ? result.failed : result.exitcode != 0
        audited = target isa ControlConnection || _batch_audited(command)
        status = signalled ? :unknown : failed ? :failed : audited ? :completed : :unknown
        acknowledged = result isa ControlResult || (!failed && !signalled)
        completed = audited && (result isa ControlResult || (!failed && !signalled))
        OperationResult(index, command, status, result, nothing, acknowledged, completed)
    catch error
        _batch_error(index, command, error)
    end
end

"""
    run_batch(target, commands; concurrency=4, timeout=5.0, cancel=nothing)

Run at most 256 independent commands with at most 64 worker tasks. Results
retain input order; execution order is unspecified. A command error does not
skip independent siblings. One monotonic budget includes admission and all
workers; cancellation stops new admission and retains sent-effect uncertainty.
The call joins every worker before returning. There is no replay or fallback.

All control commands are validated before effects. Raw `Server` commands
retain their responses, but successful per-operation completion is `:unknown`
unless the command matches the audited synchronous grammar. This deliberately
does not equate an arbitrary process response with background-job completion.
"""
function run_batch(
    target::Union{Server,ControlConnection},
    commands::AbstractVector{TmuxCommand};
    concurrency::Integer=4,
    timeout::Real=5.0,
    cancel=nothing,
)
    started = time_ns()
    budget = _batch_timeout(timeout)
    1 <= concurrency <= 64 || throw(ArgumentError("batch concurrency must be in 1:64"))
    owned = _batch_commands(target, commands)
    isempty(owned) && return BatchResult(OperationResult[])
    results = Vector{OperationResult}(undef, length(owned))
    mutex = ReentrantLock()
    next = Ref(1)
    function worker()
        while true
            index = lock(mutex) do
                next[] > length(owned) && return nothing
                index = next[]
                next[] += 1
                index
            end
            index === nothing && return
            command = owned[index]
            outcome = if cancel !== nothing && _iscancelled(cancel)
                _batch_error(index, command, RequestCancelled(false))
            elseif target isa ControlConnection && !isopen(target)
                _batch_error(index, command, ControlConnectionError(:closed, false))
            else
                _batch_operation(target, command, index, started, budget, cancel)
            end
            results[index] = outcome
        end
    end
    @sync for _ = 1:min(Int(concurrency), length(owned))
        Threads.@spawn worker()
    end
    BatchResult(results)
end

mutable struct _GroupCollector <: _ControlReplyCollector
    expected::Int
    frames::Vector{_ControlFrame}
    bytes::Int
    retired::Bool
end

function _control_collect!(collector::_GroupCollector, request, frame)
    length(collector.frames) < collector.expected ||
        throw(_ControlProtocolError(:group, :extra_reply))
    isempty(collector.frames) ||
        !last(collector.frames).failed ||
        throw(_ControlProtocolError(:group, :reply_after_failure))
    length(frame.payload) <= 4*1024*1024 - collector.bytes ||
        throw(_ControlProtocolError(:group, :reply_bytes_limit))
    collector.bytes += length(frame.payload)
    push!(collector.frames, frame)
    request.frame = frame
end

function _control_finish!(collector::_GroupCollector, request)
    length(collector.frames) == collector.expected ||
        last(collector.frames).failed ||
        throw(_ControlProtocolError(:group, :missing_reply))
    collector.retired = true
    ControlResult(something(request.frame))
end

function _group_encoding(commands)
    join(
        (
            chop(_encode_control_command(collect(command.arguments)); tail=1) for
            command in commands
        ),
        " ; ",
    ) * "\n"
end

"""
    run_group(connection::ControlConnection, commands; timeout=5.0, cancel=nothing)

Send one explicit semicolon group of audited synchronous control commands.
The first command error skips its suffix; a separate same-queue fence proves
retirement. Preserve per-command responses and truthful skipped/unknown states.
Cancellation or connection loss returns available evidence without replay.
"""
function run_group(
    connection::ControlConnection,
    commands::AbstractVector{TmuxCommand};
    timeout::Real=5.0,
    cancel=nothing,
)
    started = time_ns()
    budget = _batch_timeout(timeout)
    owned = _batch_commands(connection, commands)
    isempty(owned) && throw(ArgumentError("a command group cannot be empty"))
    encoded = _group_encoding(owned)
    ncodeunits(encoded) <= 1024*1024 ||
        throw(ArgumentError("encoded control group exceeds 1 MiB"))
    collector = _GroupCollector(length(owned), _ControlFrame[], 0, false)
    aggregate = nothing
    failure = nothing
    try
        remaining = budget - (time_ns() - started) / 1e9
        remaining > 0 || throw(DeadlineExceeded(budget, false, nothing))
        aggregate = _control_request(
            connection,
            ["command-group"],
            _ControlReplyPolicy(; diagnostics=true);
            timeout=remaining,
            cancel,
            collector,
            encoded_group=encoded,
        )
    catch error
        failure = error
    end
    lock(connection.lock) do
        frames = copy(collector.frames)
        results = OperationResult[]
        sent = failure === nothing || _batch_sent(failure)
        for (index, command) in enumerate(owned)
            if index <= length(frames)
                frame = frames[index]
                status =
                    collector.retired ? (frame.failed ? :failed : :completed) : :unknown
                push!(
                    results,
                    OperationResult(
                        index,
                        command,
                        status,
                        ControlResult(frame),
                        collector.retired ? nothing : failure,
                        true,
                        collector.retired,
                    ),
                )
            else
                skipped = collector.retired || !sent
                push!(
                    results,
                    OperationResult(
                        index,
                        command,
                        skipped ? :skipped : :unknown,
                        nothing,
                        failure,
                        false,
                        false,
                    ),
                )
            end
        end
        GroupResult(results, aggregate, failure, collector.retired, false)
    end
end

"""
    run_group(server::Server, commands; timeout=5.0, cancel=nothing)

Run a native subprocess semicolon group. Preserve its aggregate response;
individual operation statuses remain `:unknown` because arbitrary stdout and
an exit status do not prove per-command attribution. Arguments are literal;
only separators inserted between commands establish the explicit group.
"""
function run_group(
    server::Server,
    commands::AbstractVector{TmuxCommand};
    timeout::Real=5.0,
    cancel=nothing,
)
    started = time_ns()
    budget = _batch_timeout(timeout)
    owned = _batch_commands(server, commands)
    isempty(owned) && throw(ArgumentError("a command group cannot be empty"))
    arguments = String[]
    for command in owned
        isempty(arguments) || push!(arguments, ";")
        append!(arguments, _literal_tmux_argument.(command.arguments))
    end
    sum(ncodeunits(argument) + 1 for argument in _argv(server, arguments)) <= 14*1024 ||
        throw(ArgumentError("subprocess group exceeds the conservative 14 KiB limit"))
    aggregate = nothing
    failure = nothing
    try
        remaining = budget - (time_ns() - started) / 1e9
        remaining > 0 || throw(DeadlineExceeded(budget, false, nothing))
        aggregate =
            run_command(server, arguments...; timeout=remaining, cancel, check=false)
    catch error
        failure = error
        aggregate = _batch_result(error)
    end
    skipped = failure !== nothing && !_batch_sent(failure)
    outcomes = [
        OperationResult(
            index,
            command,
            skipped ? :skipped : :unknown,
            nothing,
            failure,
            false,
            false,
        ) for (index, command) in enumerate(owned)
    ]
    GroupResult(outcomes, aggregate, failure, false, true)
end
