"""
One accepted output observation. `text` is a bounded UTF-8 tail;
`dropped_bytes` counts complete decoded bytes omitted from this result and
`pending_bytes` counts an incomplete UTF-8 suffix retained by the decoder.
`received_bytes` counts raw bytes consumed by this wait. Tail truncation is
local retention policy; an actual stream gap instead raises `ObservationLost`.
The cursor covers the whole last consumed event, including omitted bytes;
it cannot resume within a matched event.

`source == :baseline` denotes an independent captured screen with a `:reset`
boundary. `source == :output` denotes raw output within this stream, with
`:stream` continuity. Neither text matches nor `evidence == :quiet` establish
process completion or success.
"""
struct OutputWaitResult
    text::String
    source::Symbol
    cursor::ObservationCursor
    received_bytes::Int
    dropped_bytes::Int
    pending_bytes::Int
    evidence::Symbol
    continuity::Symbol
end

function _output_wait_policy(stream, timeout, max_bytes, mode, cancel)
    mode === :rendered && throw(
        UnsupportedCapability(
            :rendered_output_wait,
            "streaming waits do not reconstruct a rendered screen; use explicit capture_pane observations",
        ),
    )
    mode === :raw || throw(ArgumentError("wait mode must be :raw"))
    budget = Float64(timeout)
    isfinite(budget) && budget > 0 ||
        throw(ArgumentError("wait timeout must be positive and finite"))
    limit = _output_wait_byte_limit(max_bytes)
    stream.kind === :output || throw(ArgumentError("waits require a pane output stream"))
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    _output_wait_open(stream)
    (budget, limit)
end

function _output_wait_byte_limit(max_bytes)
    max_bytes isa Integer && !(max_bytes isa Bool) && 1 <= max_bytes <= 64*1024*1024 ||
        throw(ArgumentError("wait tail byte limit must be in 1:67108864"))
    Int(max_bytes)
end

function _output_wait_open(stream)
    lock(stream.connection.lock) do
        stream.error === nothing || throw(stream.error)
        stream.open || throw(EOFError())
    end
    nothing
end

function _output_wait_remaining(started, budget, cancel)
    cancel === nothing || !_iscancelled(cancel) || throw(RequestCancelled(false))
    _snapshot_remaining(started, budget)
end

function _output_wait_decoder(stream, invalid)
    requested = TextDecoder(; invalid)
    lock(stream.connection.lock) do
        stream._wait_active && throw(ArgumentError("an output wait is already active"))
        stream.consumer === nothing ||
            stream.consumer === current_task() ||
            throw(ArgumentError("observation has a different consumer task"))
        decoder = stream._wait_decoder
        if decoder === nothing
            decoder = requested
        else
            stream.cursor == stream._wait_cursor || throw(
                ArgumentError(
                    "raw reads changed text-wait continuity; register a new stream",
                ),
            )
            decoder._closed && throw(
                ArgumentError(
                    "text decoder closed after invalid UTF-8; register a new stream",
                ),
            )
            decoder._invalid == invalid ||
                isempty(decoder._pending) ||
                throw(ArgumentError("cannot change UTF-8 policy while bytes are pending"))
            decoder._invalid = invalid
        end
        stream.consumer = current_task()
        stream._wait_decoder = decoder
        stream._wait_active = true
        notify(stream.connection.changed; all=true)
        decoder
    end
end

function _output_wait_release(stream)
    lock(stream.connection.lock) do
        stream._wait_active = false
    end
    nothing
end

function _output_wait_take(stream; timeout, cancel)
    event = _take_observation(stream; timeout, cancel, _text_wait=true)
    event === nothing && throw(EOFError())
    lock(stream.connection.lock) do
        stream._wait_cursor = event.cursor
    end
    event
end

function _output_wait_tail(text, max_bytes)
    removed = max(0, ncodeunits(text) - max_bytes)
    removed == 0 && return (text, 0)
    first = nextind(text, removed)
    (String(SubString(text, first)), first - 1)
end

function _output_wait_result(text, stream, decoder, received, dropped, evidence)
    OutputWaitResult(
        text,
        :output,
        observation_cursor(stream),
        received,
        dropped,
        length(decoder._pending),
        evidence,
        :stream,
    )
end

"""
    wait_for(predicate, stream::ObservationStream; baseline=false, timeout=5.0,
             cancel=nothing, max_bytes=65536, invalid=:error, mode=:raw)

Consume raw pane output until `predicate(result::OutputWaitResult)` returns
`true`. The predicate runs outside the reader lock and must return promptly.
One total deadline includes baseline capture, predicate calls and every read;
a synchronous predicate cannot be forcibly interrupted. Cancellation and an
expired deadline are checked again before accepting its result.

By default only output consumed by this call is considered. `baseline=true`
first tests an independently captured screen, bounded by `max_bytes`; an
oversized capture raises `OutputLimitExceeded`. A rejected baseline is never
concatenated with subsequent raw bytes. Already queued output remains eligible;
register a new stream before sending input when fresh-output evidence matters.

Predicates see a tail of at most `max_bytes` bytes, not unlimited history.
UTF-8 spans chunks through `TextDecoder`; malformed input follows `invalid`.
Terminal escapes remain literal data. `mode=:rendered` refuses streaming
screen reconstruction before I/O; explicit captures remain available.

The stream retains incomplete UTF-8 across successive waits, including after
cancellation or a predicate exception. Only one helper may consume it at a
time, on its consumer task. A UTF-8 policy change requires no pending bytes.
Direct raw reads during a helper are refused; raw reads between helpers make
later text waits refuse lost decoder continuity. Register a new stream after
a strict UTF-8 error or to change consumption modes.

The caller retains ownership of the stream and connection. Stream overflow,
topology loss, cancellation, EOF and transport errors propagate without replay.
"""
function wait_for(predicate, stream::ObservationStream; kwargs...)
    _wait_for_output(predicate, stream, :predicate; kwargs...)
end

function _wait_for_output(
    predicate,
    stream,
    evidence;
    baseline::Bool=false,
    timeout::Real=5.0,
    cancel=nothing,
    max_bytes=65536,
    invalid=:error,
    mode::Symbol=:raw,
    literal=nothing,
)
    started = time_ns()
    budget, max_bytes = _output_wait_policy(stream, timeout, max_bytes, mode, cancel)
    decoder = _output_wait_decoder(stream, invalid)
    try
        function accepted(result)
            answer = predicate(result)
            answer isa Bool || throw(ArgumentError("wait predicate must return Bool"))
            _output_wait_remaining(started, budget, cancel)
            _output_wait_open(stream)
            answer
        end
        if baseline
            captured = capture_baseline(
                stream;
                max_bytes,
                timeout=_output_wait_remaining(started, budget, cancel),
                cancel,
            )
            result = OutputWaitResult(
                decode_text(captured.bytes; invalid),
                :baseline,
                captured.after,
                length(captured.bytes),
                0,
                0,
                evidence,
                :reset,
            )
            accepted(result) && return result
        end
        text = ""
        received = dropped = 0
        while true
            event = _output_wait_take(
                stream;
                timeout=_output_wait_remaining(started, budget, cancel),
                cancel,
            )
            received += length(event.bytes)
            text *= decode!(decoder, event.bytes)
            hit = literal === nothing ? nothing : findfirst(literal, text)
            omitted = 0
            if hit !== nothing
                stop = last(hit)
                omitted = ncodeunits(text) - nextind(text, stop) + 1
                text = String(SubString(text, 1, stop))
            end
            text, removed = _output_wait_tail(text, max_bytes)
            dropped += removed + omitted
            result = _output_wait_result(text, stream, decoder, received, dropped, evidence)
            accepted(result) && return result
        end
    finally
        _output_wait_release(stream)
    end
end

"""
    wait_for_text(stream::ObservationStream, text; kwargs...)

Wait for a nonempty literal UTF-8 string using `wait_for`'s raw-output,
baseline, bounded-tail and total-deadline policy. The pattern must fit the
tail limit. Matching can include terminal echo or concurrent writers; it is
literal-text evidence, not process success.

Every decoded byte is searched before tail retention. A match in the middle of
a large chunk remains visible: returned text ends at that match, and later
bytes in the same event count as received but omitted from the result.
"""
function wait_for_text(
    stream::ObservationStream,
    text::AbstractString;
    max_bytes=65536,
    kwargs...,
)
    max_bytes = _output_wait_byte_limit(max_bytes)
    isvalid(text) && !isempty(text) ||
        throw(ArgumentError("wait text must be nonempty valid UTF-8"))
    ncodeunits(text) <= max_bytes ||
        throw(ArgumentError("wait text exceeds the tail limit"))
    _wait_for_output(
        result -> occursin(text, result.text),
        stream,
        :literal_text;
        max_bytes,
        literal=String(text),
        kwargs...,
    )
end

"""
    wait_for_quiet(stream::ObservationStream; quiet=0.1, timeout=5.0,
                   cancel=nothing, max_bytes=65536, invalid=:error, mode=:raw)

Consume output until no event is received for `quiet` seconds, within one total
deadline. Each received event restarts only the inactivity interval. The result
has `evidence == :quiet`; inactivity does not prove process completion or
success. It covers this client's observed stream, not atomic daemon silence.

Tail retention and UTF-8 use `wait_for`'s policy; incomplete UTF-8 stays explicit
in `pending_bytes`. A shorter total deadline raises `DeadlineExceeded` rather
than reporting quiet. Cancellation, overflow, target loss and EOF propagate.
The caller keeps ownership of the stream. No polling or extra reader is used.
"""
function wait_for_quiet(
    stream::ObservationStream;
    quiet::Real=0.1,
    timeout::Real=5.0,
    cancel=nothing,
    max_bytes=65536,
    invalid=:error,
    mode::Symbol=:raw,
)
    started = time_ns()
    budget, max_bytes = _output_wait_policy(stream, timeout, max_bytes, mode, cancel)
    interval = Float64(quiet)
    isfinite(interval) && interval > 0 ||
        throw(ArgumentError("quiet interval must be positive and finite"))
    decoder = _output_wait_decoder(stream, invalid)
    try
        text = ""
        received = dropped = 0
        last_output = time_ns()
        while true
            remaining = _output_wait_remaining(started, budget, cancel)
            idle_remaining = interval - (time_ns() - last_output) / 1e9
            event = try
                _output_wait_take(
                    stream;
                    timeout=min(remaining, max(idle_remaining, eps(Float64))),
                    cancel,
                )
            catch error
                error isa DeadlineExceeded || rethrow()
                result = lock(stream.connection.lock) do
                    _output_wait_remaining(started, budget, cancel)
                    stream.error === nothing || throw(stream.error)
                    stream.open || throw(EOFError())
                    isempty(stream.queue) || return nothing
                    (time_ns() - last_output) / 1e9 >= interval || return nothing
                    _output_wait_result(text, stream, decoder, received, dropped, :quiet)
                end
                result === nothing || return result
                continue
            end
            last_output = time_ns()
            received += length(event.bytes)
            text, removed =
                _output_wait_tail(text * decode!(decoder, event.bytes), max_bytes)
            dropped += removed
        end
    finally
        _output_wait_release(stream)
    end
end
