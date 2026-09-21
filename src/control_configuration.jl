function _control_configuration_context(connection, scope; kwargs...)
    context = _control_operation_context(connection; kwargs...)
    scope isa EntityRef && _control_exact_target(connection, scope)
    context
end

"""
    set_environment(connection::ControlConnection, scope, name, value; hidden=false, kwargs...)

Set a literal environment value through the existing control connection and
return its `ControlResult`. Scope is `:global` or an exact `SessionRef`.
Empty values, format punctuation and line breaks remain data. The daemon
generation stays pinned; cancellation after submission does not undo the write.
Timeout and cancellation follow the control creation methods.
"""
function set_environment(
    connection::ControlConnection,
    scope,
    name::AbstractString,
    value::AbstractString;
    hidden::Bool=false,
    kwargs...,
)
    flags = _environment_scope_flags(scope)
    name = _configuration_name(name; environment=true)
    value = _argument(value)
    hidden && push!(flags, "-h")
    context = _control_configuration_context(connection, scope; kwargs...)
    _control_effect(
        connection,
        ["set-environment", flags..., "--", name, value];
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end

"""
    unset_environment(connection::ControlConnection, scope, name; kwargs...)

Delete an exact configured environment entry over the pinned connection,
allowing global inheritance. Return `ControlResult`; scopes and execution
controls follow the control `set_environment` method.
"""
function unset_environment(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    kwargs...,
)
    _control_environment_delete(connection, scope, name, "-u"; kwargs...)
end

"""
    remove_environment(connection::ControlConnection, scope, name; kwargs...)

Mark a variable for removal from new process environments, masking an inherited
global value. Return `ControlResult`; this does not mutate processes already
running in panes. Scopes and controls follow the control `set_environment` method.
"""
function remove_environment(
    connection::ControlConnection,
    scope,
    name::AbstractString;
    kwargs...,
)
    _control_environment_delete(connection, scope, name, "-r"; kwargs...)
end

function _control_environment_delete(connection, scope, name, flag; kwargs...)
    flags = _environment_scope_flags(scope)
    name = _configuration_name(name; environment=true)
    context = _control_configuration_context(connection, scope; kwargs...)
    _control_effect(
        connection,
        ["set-environment", flags..., flag, "--", name];
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end
