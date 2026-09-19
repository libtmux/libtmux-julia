struct CrossServerReference <: LibTmuxError
    target::String
end
struct StaleReference <: LibTmuxError
    target::String
end

"""
A creation command completed, but its reply could not establish the result.
`result` retains the command output and exit evidence; `cause` explains the
invalid reply or changed identity. `sent` is always `true`: remote effects may
have occurred. The library neither retries creation nor removes its results.
"""
struct CreationResponseError{R} <: LibTmuxError
    result::R
    cause::Exception
    sent::Bool

    CreationResponseError(result::R, cause::Exception) where {R} =
        new{R}(result, cause, true)
end

Base.showerror(io::IO, e::CrossServerReference) =
    print(io, "target ", repr(e.target), " belongs to another server")
Base.showerror(io::IO, e::StaleReference) =
    print(io, "target ", repr(e.target), " belongs to another observed daemon generation")
Base.showerror(io::IO, e::CreationResponseError) = print(
    io,
    "could not validate creation reply; remote effects may have occurred: ",
    sprint(showerror, e.cause),
)

function _operation_context(server; timeout::Real=5.0, cancel=nothing, strict::Bool=false)
    strict && throw(
        UnsupportedCapability(
            :strict_generation,
            "subprocess checks are best effort; strict operations require an admitted control transport",
        ),
    )
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("invalid operation timeout"))
    (; server, budget, started=time_ns(), cancel)
end

function _target_context(server::Server, ref::EntityRef; kwargs...)
    context = _operation_context(server; kwargs...)
    if server.socket_path !== nothing && server.socket_path != ref.server.socket_path
        throw(CrossServerReference(string(ref.id)))
    end
    _verify_row_codec(server, context.started, context.budget, context.cancel)
    current = _snapshot_metadata(server, context.started, context.budget, context.cancel)
    current.socket_path == ref.server.socket_path ||
        throw(CrossServerReference(string(ref.id)))
    current == ref.server || throw(StaleReference(string(ref.id)))
    context
end

function _operation_command(context, args...; kwargs...)
    run_command(
        context.server,
        args...;
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
        kwargs...,
    )
end

function _creation_reference(
    ::Type{R},
    result::CommandResult;
    expected=nothing,
) where {R<:EntityRef}
    try
        row = only(_decode_format_rows(result.stdout, 4))
        _observed_int(row[1], "pid")
        _observed_int(row[2], "start_time")
        identity = ServerIdentity(socket_path=row[3], generation=row[1] * ":" * row[2])
        ref = R(identity, row[4])
        if expected !== nothing
            identity.socket_path == expected.socket_path ||
                throw(CrossServerReference(row[4]))
            identity == expected || throw(StaleReference(row[4]))
        end
        ref
    catch error
        error isa InterruptException && rethrow()
        throw(CreationResponseError(result, error))
    end
end

function _literal_tmux_argument(value::AbstractString)
    text = _argument(value)
    endswith(text, ';') ? chop(text; tail=1) * "\\;" : text
end
_literal_format(value::AbstractString) =
    _literal_tmux_argument(replace(_argument(value), "#" => "##"))

function _pane_command_args(command, shell_command; encoder=_literal_tmux_argument)
    command === nothing ||
        shell_command === nothing ||
        throw(ArgumentError("choose command argv or shell_command, not both"))
    if shell_command !== nothing
        return ["/bin/sh", "-c", encoder(shell_command)]
    end
    command === nothing && return String[]
    command isa AbstractVector{<:AbstractString} || throw(
        ArgumentError("command must be an argv vector; use shell_command for shell syntax"),
    )
    isempty(command) && throw(ArgumentError("command argv cannot be empty"))
    argv = encoder.(command)
    isempty(first(argv)) && throw(ArgumentError("command executable cannot be empty"))
    startswith(first(argv), '-') && throw(
        ArgumentError(
            "command executable cannot start with '-'; use './-name' or an absolute path",
        ),
    )
    # tmux interprets a single command argument as shell syntax. A fixed
    # wrapper passes that executable as data while preserving zero arguments.
    length(argv) == 1 ? ["/bin/sh", "-c", "exec \"\$0\"", only(argv)] : argv
end

function _creation_args(
    command,
    shell_command,
    start_directory,
    environment=();
    encoder=_literal_tmux_argument,
)
    environment isa Union{AbstractDict,Tuple,AbstractVector} || throw(
        ArgumentError("environment must be a mapping or collection of name => value pairs"),
    )
    args = String[]
    names = Set{String}()
    for entry in environment
        entry isa Pair ||
            throw(ArgumentError("environment entries must be name => value pairs"))
        name, value = entry
        name isa AbstractString && value isa AbstractString ||
            throw(ArgumentError("environment names and values must be strings"))
        name = _configuration_name(name; environment=true)
        name in names && throw(ArgumentError("environment names must be unique"))
        push!(names, name)
        append!(args, ["-e", encoder(name * "=" * _argument(value))])
    end
    start_directory === nothing ||
        append!(args, ["-c", encoder(replace(_argument(start_directory), "#" => "##"))])
    append!(args, ["--"; _pane_command_args(command, shell_command; encoder)])
    args
end

"""
    new_session(server; name, command=nothing, shell_command=nothing,
                start_directory=nothing, environment=(), timeout=5.0, cancel=nothing, strict=false)

Create a detached session and return its generation-bound `SessionRef`.
`command` is an argv vector; `shell_command` explicitly runs `/bin/sh -c`.
An executable name beginning with `-` requires `./-name` or an absolute path;
arguments after the executable may begin with `-`.
Omitting both uses tmux's configured default command. Creation can start a
daemon at this endpoint. The returned reference does not own automatic cleanup.
`environment` is a mapping or pairs of portable names to literal string values,
passed at creation without format expansion. Duplicate names are rejected.

Subprocess identity checks are best effort. `strict=true` refuses execution;
there is no silent downgrade or replay after uncertain failure.
An invalid creation reply raises `CreationResponseError` with command evidence.
"""
function new_session(
    server::Server;
    name::AbstractString,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    environment=(),
    kwargs...,
)
    isempty(name) && throw(ArgumentError("session name cannot be empty"))
    context = _operation_context(server; kwargs...)
    fields = ["pid", "start_time", "socket_path", "session_id"]
    args = [
        "new-session",
        "-d",
        "-P",
        "-F",
        _format_template(fields),
        "-s",
        _literal_format(name),
    ]
    append!(args, _creation_args(command, shell_command, start_directory, environment))
    result = _operation_command(context, args...)
    _creation_reference(SessionRef, result)
end

"""
    new_window(server, target::SessionRef; name=nothing, index=nothing, kwargs...)

Create a detached window in the target session and return its `WindowRef`.
An explicit nonnegative `index` targets that session slot and refuses collisions.
Omit it to use tmux's next available index. Command, directory, environment,
deadline and strictness options follow [`new_session`](@ref).
Identity checks are best effort. A changed identity in the creation reply
raises `CreationResponseError`; the library does not retry or clean up.
"""
function new_window(
    server::Server,
    target::SessionRef;
    name=nothing,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    environment=(),
    index=nothing,
    kwargs...,
)
    index === nothing || (index = _window_index(index))
    fields = ["pid", "start_time", "socket_path", "window_id"]
    args = [
        "new-window",
        "-d",
        "-P",
        "-F",
        _format_template(fields),
        "-t",
        string(target.id) * ":" * (index === nothing ? "" : string(index)),
    ]
    name === nothing || append!(args, ["-n", _literal_format(name)])
    append!(args, _creation_args(command, shell_command, start_directory, environment))
    context = _target_context(server, target; kwargs...)
    result = _operation_command(context, args...)
    _creation_reference(WindowRef, result; expected=target.server)
end

"""
    split_window(server, target::PaneRef; direction=:below, size=nothing, kwargs...)

Split the target pane in `:right`, `:left`, `:below` or `:above`; return a `PaneRef`.
`size` is a positive cell count. Command, directory, deadline and strictness
options follow [`new_session`](@ref). Identity checks are best effort. A changed
identity in the reply raises `CreationResponseError` without retry or cleanup.
"""
function split_window(
    server::Server,
    target::PaneRef;
    direction::Symbol=:below,
    command=nothing,
    shell_command=nothing,
    start_directory=nothing,
    size::Union{Nothing,Integer}=nothing,
    environment=(),
    kwargs...,
)
    direction in (:right, :left, :below, :above) ||
        throw(ArgumentError("invalid split direction"))
    fields = ["pid", "start_time", "socket_path", "pane_id"]
    args = [
        "split-window",
        "-d",
        "-P",
        "-F",
        _format_template(fields),
        "-t",
        string(target.id),
    ]
    push!(args, direction in (:right, :left) ? "-h" : "-v")
    direction in (:left, :above) && push!(args, "-b")
    if size !== nothing
        size > 0 && !(size isa Bool) || throw(ArgumentError("split size must be positive"))
        append!(args, ["-l", string(size)])
    end
    append!(args, _creation_args(command, shell_command, start_directory, environment))
    context = _target_context(server, target; kwargs...)
    result = _operation_command(context, args...)
    _creation_reference(PaneRef, result; expected=target.server)
end

for (operation, command, Ref) in (
    (:kill_session, "kill-session", SessionRef),
    (:kill_window, "kill-window", WindowRef),
    (:kill_pane, "kill-pane", PaneRef),
)
    @eval function $operation(server::Server, target::$Ref; kwargs...)
        context = _target_context(server, target; kwargs...)
        _operation_command(context, $command, "-t", string(target.id))
    end
    @eval @doc $("""
        $operation(server, target; timeout=5.0, cancel=nothing, strict=false)

    Remove the referenced tmux object and return its `CommandResult`.
    Identity checks are best effort; `strict=true` refuses execution. Failures
    after submission may have remote effects and are never retried.
    """) $operation
end

"""Apply a named or explicit tmux layout to an exact window."""
function select_layout(
    server::Server,
    target::WindowRef,
    layout::Union{Symbol,AbstractString};
    kwargs...,
)
    text =
        layout isa Symbol ? replace(string(layout), '_' => '-') :
        _literal_tmux_argument(layout)
    if layout isa Symbol
        text in
        ("even-horizontal", "even-vertical", "main-horizontal", "main-vertical", "tiled") ||
            throw(ArgumentError("unknown named layout"))
    end
    context = _target_context(server, target; kwargs...)
    _operation_command(context, "select-layout", "-t", string(target.id), "--", text)
end

"""
    select_pane(server, target::PaneRef; kwargs...)

Focus an exact pane within its physical window. This does not select a linked
window in any session; use `select_window` with an explicit link for that.
Generation checks are best effort and share the operation deadline.
"""
function select_pane(server::Server, target::PaneRef; kwargs...)
    context = _target_context(server, target; kwargs...)
    _operation_command(context, "select-pane", "-t", string(target.id))
end
