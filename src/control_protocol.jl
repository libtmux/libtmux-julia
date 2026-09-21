struct _ControlProtocolError <: LibTmuxError
    state::Symbol
    reason::Symbol
end

Base.showerror(io::IO, error::_ControlProtocolError) =
    print(io, "invalid tmux control protocol in ", error.state, ": ", error.reason)

struct _ControlGuard
    timestamp::UInt64
    number::UInt64
    flags::UInt64
end

abstract type _ControlEvent end

struct _ControlFrame <: _ControlEvent
    guard::_ControlGuard
    payload::Vector{UInt8}
    failed::Bool
end

struct _ControlNotification <: _ControlEvent
    name::Symbol
    bytes::Vector{UInt8}
end

struct _ControlOutput <: _ControlEvent
    pane::UInt64
    age_ms::Union{Nothing,UInt64}
    bytes::Vector{UInt8}
end

"""
Private reply grammar. The default admits no payload. `prefix` admits rows
starting with those exact bytes; returned frame payload retains the prefix
and LF. `diagnostics=true` also admits nonempty lines not starting with `%`
in frames that close with `%error`; a success guard after diagnostic text is
a terminal error. Reflected operands of admitted commands cannot inject LF.

This is not a grammar for arbitrary command stdout. A forged matching guard
is indistinguishable from a real guard. Aliases, hooks and unsolicited
commands must respect the transport's trusted-server admission contract.
"""
struct _ControlReplyPolicy
    prefix::Vector{UInt8}
    diagnostics::Bool

    function _ControlReplyPolicy(; prefix="", diagnostics::Bool=false)
        bytes = collect(codeunits(String(prefix)))
        (isempty(bytes) || (bytes[1] != 0x25 && all(b -> b >= 0x20 || b == 0x09, bytes))) ||
            throw(
                ArgumentError(
                    "control row prefix must not start with % or contain control bytes other than TAB",
                ),
            )
        new(bytes, diagnostics)
    end
end

_control_empty_policy(::_ControlGuard) = _ControlReplyPolicy()

"""
Single-owner incremental parser for admitted control replies, without I/O.
`frame_policy(guard)` chooses the grammar for each frame, including startup
and hook frames. Flags and server-global command numbers are preserved;
they do not by themselves assign a frame to a pending request.

Line and frame bounds include their LF. `max_events` bounds each feed's
returned nodes. Errors close the parser and discard retained bytes. Output
notification bytes are octal-decoded without UTF-8 conversion. Other
notifications retain the complete record bytes, excluding LF.

Known 3.2a/current notifications can occur inside a reply. Unknown records
fail; this parser does not silently discard future notification dialects.
Consumers must defer operation success until their completion fence: frame
closure alone does not establish completion of commands returning WAIT.
"""
mutable struct _ControlParser{F}
    frame_policy::F
    max_line_bytes::Int
    max_frame_bytes::Int
    max_events::Int
    line::Vector{UInt8}
    payload::Vector{UInt8}
    guard::Union{Nothing,_ControlGuard}
    policy::_ControlReplyPolicy
    diagnostic_seen::Bool
    closed::Bool
    exited::Bool
end

function _ControlParser(;
    frame_policy=_control_empty_policy,
    max_line_bytes::Integer=1_048_576,
    max_frame_bytes::Integer=4_194_304,
    max_events::Integer=256,
)
    max_line_bytes > 0 && max_frame_bytes >= 0 && max_events > 0 || throw(
        ArgumentError(
            "control limits require positive line/events and nonnegative frame bytes",
        ),
    )
    _ControlParser(
        frame_policy,
        Int(max_line_bytes),
        Int(max_frame_bytes),
        Int(max_events),
        UInt8[],
        UInt8[],
        nothing,
        _ControlReplyPolicy(),
        false,
        false,
        false,
    )
end

function _control_fail(parser::_ControlParser, reason::Symbol)
    state = parser.guard === nothing ? :idle : :frame
    parser.closed = true
    empty!(parser.line)
    empty!(parser.payload)
    parser.guard = nothing
    throw(_ControlProtocolError(state, reason))
end

function _control_uint(parser::_ControlParser, value)
    bytes = codeunits(value)
    isempty(bytes) && _control_fail(parser, :invalid_integer)
    result = UInt64(0)
    for byte in bytes
        0x30 <= byte <= 0x39 || _control_fail(parser, :invalid_integer)
        digit = UInt64(byte - 0x30)
        result <= (typemax(UInt64) - digit) ÷ 10 || _control_fail(parser, :integer_overflow)
        result = result * 10 + digit
    end
    result
end

function _control_id(parser::_ControlParser, value, prefix::UInt8)
    bytes = codeunits(value)
    length(bytes) >= 2 && bytes[1] == prefix || _control_fail(parser, :invalid_id)
    _control_uint(parser, SubString(value, 2))
end

function _control_event!(parser::_ControlParser, events, event::_ControlEvent)
    length(events) < parser.max_events || _control_fail(parser, :event_limit)
    push!(events, event)
end

function _control_output_bytes(parser::_ControlParser, data)
    bytes = codeunits(data)
    result = UInt8[]
    position = 1
    while position <= length(bytes)
        byte = bytes[position]
        if byte == 0x5c
            position + 3 <= length(bytes) || _control_fail(parser, :incomplete_octal)
            0x30 <= bytes[position+1] <= 0x33 &&
            all(b -> 0x30 <= b <= 0x37, @view(bytes[(position+2):(position+3)])) ||
                _control_fail(parser, :invalid_octal)
            value =
                64 * Int(bytes[position+1] - 0x30) +
                8 * Int(bytes[position+2] - 0x30) +
                Int(bytes[position+3] - 0x30)
            push!(result, UInt8(value))
            position += 4
        else
            byte >= 0x20 || _control_fail(parser, :unescaped_output_byte)
            push!(result, byte)
            position += 1
        end
    end
    result
end

const _CONTROL_NOTIFICATION_NAMES = (
    "sessions-changed",
    "pane-mode-changed",
    "window-pane-changed",
    "window-close",
    "unlinked-window-close",
    "window-add",
    "unlinked-window-add",
    "window-renamed",
    "unlinked-window-renamed",
    "session-changed",
    "client-session-changed",
    "client-detached",
    "session-renamed",
    "session-window-changed",
    "layout-change",
    "paste-buffer-changed",
    "paste-buffer-deleted",
    "subscription-changed",
    "config-error",
    "pause",
    "continue",
    "exit",
)

function _control_notification!(parser::_ControlParser, events, line, name::String)
    name in _CONTROL_NOTIFICATION_NAMES || _control_fail(parser, :unknown_record)
    # Notification text is not a second escaping layer. Invalid UTF-8 stays bytes.
    all(b -> b >= 0x20, line) || _control_fail(parser, :notification_control_byte)
    fields = split(String(copy(line)), ' '; limit=9, keepempty=true)
    args = @view(fields[2:end])
    if name == "sessions-changed"
        isempty(args) || _control_fail(parser, :notification_arity)
    elseif name in ("pause", "continue", "pane-mode-changed")
        length(args) == 1 || _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], 0x25)
    elseif name in
           ("window-add", "window-close", "unlinked-window-add", "unlinked-window-close")
        length(args) == 1 || _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], 0x40)
    elseif name == "window-pane-changed"
        length(args) == 2 || _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], 0x40)
        _control_id(parser, args[2], 0x25)
    elseif name == "session-window-changed"
        length(args) == 2 || _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], 0x24)
        _control_id(parser, args[2], 0x40)
    elseif name in (
        "window-renamed",
        "unlinked-window-renamed",
        "session-changed",
        "session-renamed",
    )
        length(args) >= 2 || _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], startswith(name, "session") ? 0x24 : 0x40)
    elseif name == "client-session-changed"
        length(args) >= 2 && !isempty(args[1]) || _control_fail(parser, :notification_arity)
        _control_id(parser, args[2], 0x24)
    elseif name == "layout-change"
        length(args) == 4 && !isempty(args[2]) && !isempty(args[3]) ||
            _control_fail(parser, :notification_arity)
        _control_id(parser, args[1], 0x40)
    elseif name == "subscription-changed"
        length(args) >= 7 && args[6] == ":" || _control_fail(parser, :notification_arity)
        _control_id(parser, args[2], 0x24)
    elseif name in ("paste-buffer-changed", "paste-buffer-deleted")
        # The complete tail is a buffer name, including leading or repeated spaces.
        length(line) > ncodeunits(name) + 2 || _control_fail(parser, :notification_arity)
    elseif name != "exit"
        !isempty(args) && !isempty(args[1]) || _control_fail(parser, :notification_arity)
    end
    if name == "exit"
        parser.guard === nothing || _control_fail(parser, :exit_inside_frame)
        parser.exited = true
    end
    _control_event!(parser, events, _ControlNotification(Symbol(name), copy(line)))
end

function _control_line!(parser::_ControlParser, events, line::Vector{UInt8})
    parser.exited && _control_fail(parser, :record_after_exit)
    record = String(copy(line))
    head = first(split(record, ' '; limit=2))
    if head in ("%begin", "%end", "%error")
        fields = split(record, ' '; limit=5, keepempty=true)
        length(fields) == 4 || _control_fail(parser, :guard_arity)
        guard = _ControlGuard((_control_uint(parser, field) for field in fields[2:4])...)
        if head == "%begin"
            parser.guard === nothing || _control_fail(parser, :nested_guard)
            policy = parser.frame_policy(guard)
            policy isa _ControlReplyPolicy || _control_fail(parser, :invalid_reply_policy)
            parser.guard = guard
            parser.policy = policy
            parser.diagnostic_seen = false
        else
            parser.guard === nothing && _control_fail(parser, :orphan_guard)
            guard == parser.guard || _control_fail(parser, :mismatched_guard)
            head == "%end" &&
                parser.diagnostic_seen &&
                _control_fail(parser, :unexpected_success_output)
            payload = parser.payload
            parser.payload = UInt8[]
            parser.guard = nothing
            _control_event!(parser, events, _ControlFrame(guard, payload, head == "%error"))
        end
    elseif head in ("%output", "%extended-output")
        fields = split(record, ' '; limit=head == "%output" ? 3 : 5, keepempty=true)
        expected = head == "%output" ? 3 : 5
        length(fields) == expected || _control_fail(parser, :output_arity)
        pane = _control_id(parser, fields[2], 0x25)
        age = nothing
        if expected == 5
            fields[4] == ":" || _control_fail(parser, :extended_output_separator)
            age = _control_uint(parser, fields[3])
        end
        bytes = _control_output_bytes(parser, fields[end])
        _control_event!(parser, events, _ControlOutput(pane, age, bytes))
    elseif startswith(record, "%")
        _control_notification!(parser, events, line, String(SubString(head, 2)))
    else
        parser.guard === nothing && _control_fail(parser, :unframed_data)
        prefix = parser.policy.prefix
        prefixed =
            !isempty(prefix) &&
            length(line) >= length(prefix) &&
            @view(line[1:length(prefix)]) == prefix
        diagnostic =
            parser.policy.diagnostics &&
            !isempty(line) &&
            all(b -> b >= 0x20 || b == 0x09, line)
        prefixed || diagnostic || _control_fail(parser, :unexpected_payload)
        parser.diagnostic_seen |= !prefixed
        length(line) + 1 <= parser.max_frame_bytes - length(parser.payload) ||
            _control_fail(parser, :frame_limit)
        append!(parser.payload, line)
        push!(parser.payload, 0x0a)
    end
end

function _control_feed!(
    parser::_ControlParser,
    chunk::AbstractVector{UInt8};
    final::Bool=false,
)
    parser.closed && throw(InvalidStateException("control parser is closed", :closed))
    events = _ControlEvent[]
    try
        for byte in chunk
            length(parser.line) < parser.max_line_bytes ||
                _control_fail(parser, :line_limit)
            if byte == 0x0a
                _control_line!(parser, events, parser.line)
                empty!(parser.line)
            else
                push!(parser.line, byte)
            end
        end
        if final
            isempty(parser.line) || _control_fail(parser, :truncated_line)
            parser.guard === nothing || _control_fail(parser, :truncated_frame)
            parser.closed = true
        end
    catch
        parser.closed = true
        empty!(parser.line)
        empty!(parser.payload)
        parser.guard = nothing
        rethrow()
    end
    events
end

"""
Encode argv for tmux's command parser, not a shell. Every operand is quoted;
semicolon is always data. The result includes exactly one terminating LF.
Nonprintable/non-ASCII bytes use three-digit octal outside quotes, matching
tmux 3.2a cmd-parse.y's yylex_escape. NUL is not representable.

Encoding does not grant control admission: LF can round-trip into a target
and be reflected unescaped by cmd-find.c/cmdq_error. Use audited admission
before sending, even though this encoder can represent that argument.
"""
function _encode_control_command(
    argv::AbstractVector{<:AbstractString};
    max_argument_bytes::Integer=65_536,
    max_line_bytes::Integer=1_048_576,
    max_arguments::Integer=1_024,
)
    max_argument_bytes > 0 && max_line_bytes > 0 && max_arguments > 0 ||
        throw(ArgumentError("control encoding limits must be positive"))
    !isempty(argv) && !isempty(argv[1]) ||
        throw(ArgumentError("control command cannot be empty"))
    length(argv) <= max_arguments || throw(ArgumentError("control argument count exceeded"))
    output = UInt8[]
    function emit(bytes)
        length(bytes) <= max_line_bytes - length(output) ||
            throw(ArgumentError("encoded control line limit exceeded"))
        append!(output, bytes)
    end
    for (index, argument) in enumerate(argv)
        bytes = codeunits(argument)
        length(bytes) <= max_argument_bytes ||
            throw(ArgumentError("control argument limit exceeded"))
        0x00 in bytes && throw(ArgumentError("control arguments cannot contain NUL"))
        index > 1 && emit((0x20,))
        if isempty(bytes)
            emit((0x27, 0x27))
            continue
        end
        quoted = false
        for byte in bytes
            if 0x20 <= byte <= 0x7e && byte != 0x27
                quoted || emit((0x27,))
                quoted = true
                emit((byte,))
            else
                quoted && emit((0x27,))
                quoted = false
                if byte == 0x27
                    emit((0x22, 0x27, 0x22))
                else
                    emit((
                        0x5c,
                        0x30 + (byte >> 6),
                        0x30 + ((byte >> 3) & 0x07),
                        0x30 + (byte & 0x07),
                    ))
                end
            end
        end
        quoted && emit((0x27,))
    end
    emit((0x0a,))
    String(output)
end

"""
Admit only exact-ID destruction and deletion of a restricted buffer name.
This intentionally small allowlist excludes capture/stdout producers, raw
formats, command groups, names, paths and creation commands. Expanding it
requires auditing success output, reflected errors, hooks and aliases.
Return the permitted reply grammar; perform no I/O or fallback.
"""
function _admit_control_command(argv::AbstractVector{<:AbstractString})
    length(argv) == 3 || throw(ArgumentError("control command shape is not admitted"))
    all(argument -> all(b -> b >= 0x20 && b != 0x7f, codeunits(argument)), argv) ||
        throw(ArgumentError("control operands cannot contain reflected control bytes"))
    command, option, target = argv
    prefix =
        command == "kill-pane" ? '%' :
        command == "kill-window" ? '@' : command == "kill-session" ? '$' : nothing
    if prefix !== nothing
        option == "-t" &&
        ncodeunits(target) >= 2 &&
        target[1] == prefix &&
        all(b -> 0x30 <= b <= 0x39, codeunits(target)[2:end]) ||
            throw(ArgumentError("control destruction requires an exact typed ID"))
    elseif command == "delete-buffer"
        option == "-b" &&
        !isempty(target) &&
        all(
            b ->
                0x30 <= b <= 0x39 ||
                0x41 <= b <= 0x5a ||
                0x61 <= b <= 0x7a ||
                b in (0x2d, 0x5f),
            codeunits(target),
        ) || throw(
            ArgumentError("control buffer deletion requires a restricted buffer name"),
        )
    else
        throw(ArgumentError("control command is not admitted by the audited allowlist"))
    end
    _ControlReplyPolicy(; diagnostics=true)
end
