function _control_operation_context(
    connection;
    timeout::Real=5.0,
    cancel=nothing,
    strict::Bool=true,
)
    started = time_ns()
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("invalid operation timeout"))
    cancel === nothing || !iscancelled(cancel) || throw(RequestCancelled(false))
    isopen(connection) || throw(ControlConnectionError(connection.reason, false))
    (; connection, started, budget, cancel)
end

function _control_creation_name(name)
    text = _argument(name)
    isvalid(text) || decode_text(codeunits(text))
    all(byte -> byte >= 0x20 && byte != 0x7f, codeunits(text)) || throw(
        UnsupportedCapability(
            :new_window,
            "control creation names cannot contain control bytes: tmux may emit them unescaped in notifications",
        ),
    )
    replace(text, "#" => "##")
end

function _control_creation_reference(
    ::Type{R},
    result::ControlResult,
    expected,
) where {R<:EntityRef}
    try
        row = only(_decode_format_rows(result.stdout, 5))
        row[1] == "LIBTMUX" || throw(ArgumentError("invalid creation reply prefix"))
        _observed_int(row[2], "pid")
        _observed_int(row[3], "start_time")
        observed = ServerIdentity(socket_path=row[4], generation=row[2]*":"*row[3])
        observed.socket_path == expected.socket_path || throw(CrossServerReference(row[5]))
        observed == expected || throw(StaleReference(row[5]))
        R(expected, row[5])
    catch error
        error isa InterruptException && rethrow()
        throw(CreationResponseError(result, error))
    end
end

function _control_create(context, ::Type{R}, args) where {R<:EntityRef}
    result = _control_request(
        context.connection,
        args,
        _ControlReplyPolicy(; prefix="LIBTMUX\t", diagnostics=true);
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    result.failed && throw(ControlCommandError(result, first(args)))
    _control_creation_reference(R, result, context.connection.identity)
end

"""
    new_window(connection::ControlConnection, session::SessionRef; kwargs...)

Create a detached window through the existing connection and return its strict
`WindowRef`. Options match the subprocess method. Names must be valid UTF-8
without control bytes because supported tmux versions can emit initial names
unescaped in control notifications. This restriction is checked before writing.
Command argv, environment values and directories retain their literal bytes;
format metacharacters in names/directories are escaped separately.

The same-queue fence proves command completion under the connection's trusted
alias/hook contract. Cancellation can leave a created object; there is no
replay, implicit destruction or transport fallback. Invalid creation replies
raise `CreationResponseError` retaining the actual `ControlResult`.
`strict=false` does not weaken the connection's generation checks.
"""
function new_window(
    connection::ControlConnection,
    target::SessionRef;
    name=nothing,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    environment=(),
    index=nothing,
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, target)
    index === nothing || (index = _window_index(index))
    fields = ["pid", "start_time", "socket_path", "window_id"]
    args = [
        "new-window",
        "-d",
        "-P",
        "-F",
        "LIBTMUX\t"*_format_template(fields),
        "-t",
        string(target.id)*":"*(index === nothing ? "" : string(index)),
    ]
    name === nothing || append!(args, ["-n", _control_creation_name(name)])
    append!(
        args,
        _creation_args(
            command,
            shell_command,
            start_directory,
            environment;
            encoder=_argument,
        ),
    )
    _control_create(context, WindowRef, args)
end

"""
    split_window(connection::ControlConnection, pane::PaneRef; kwargs...)

Split an exact pane through its existing connection; return a strict `PaneRef`.
Direction, size, command, directory and environment options match the subprocess
method. Reply framing, cancellation and uncertain creation outcomes follow the
control `new_window` method. No implicit pane selection or fallback is allowed.
"""
function split_window(
    connection::ControlConnection,
    target::PaneRef;
    direction::Symbol=:below,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    size::Union{Nothing,Integer}=nothing,
    environment=(),
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, target)
    direction in (:right, :left, :below, :above) ||
        throw(ArgumentError("invalid split direction"))
    fields = ["pid", "start_time", "socket_path", "pane_id"]
    args = [
        "split-window",
        "-d",
        "-P",
        "-F",
        "LIBTMUX\t"*_format_template(fields),
        "-t",
        string(target.id),
        direction in (:right, :left) ? "-h" : "-v",
    ]
    direction in (:left, :above) && push!(args, "-b")
    if size !== nothing
        size > 0 && !(size isa Bool) || throw(ArgumentError("split size must be positive"))
        append!(args, ["-l", string(size)])
    end
    append!(
        args,
        _creation_args(
            command,
            shell_command,
            start_directory,
            environment;
            encoder=_argument,
        ),
    )
    _control_create(context, PaneRef, args)
end

"""
    send_keys(connection::ControlConnection, pane::PaneRef, keys...; literal=false, kwargs...)

Send valid UTF-8 key arguments to an exact pane over its pinned connection.
`literal=true` disables tmux key lookup. No Enter or format expansion is added.
Control bytes in key data are encoded as tmux parser escapes and never become
command separators. Completion means tmux accepted the keys, not that a pane
application processed them. Returns `ControlResult` after the completion fence.
"""
function send_keys(
    connection::ControlConnection,
    pane::PaneRef,
    keys::AbstractString...;
    literal::Bool=false,
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, pane)
    isempty(keys) && throw(ArgumentError("supply at least one key argument"))
    args = ["send-keys", "-t", string(pane.id)]
    literal && push!(args, "-l")
    push!(args, "--")
    for key in keys
        text = _argument(key)
        isvalid(text) || decode_text(codeunits(text))
        push!(args, text)
    end
    _control_effect(
        context.connection,
        args;
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end
