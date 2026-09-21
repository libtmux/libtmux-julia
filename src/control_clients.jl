function _control_client_selector(context, client::ClientRef, operation::Symbol)
    name = _control_singleline(client.id.name, operation)
    occursin(' ', name) && throw(
        UnsupportedCapability(
            operation,
            "control client names cannot contain spaces: tmux emits them as unescaped notification fields",
        ),
    )
    rows = _control_rows(
        context.connection,
        "list-clients",
        ["client_name", "client_pid", "client_created"];
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
    matches = filter(row -> row[1] == name, rows)
    length(matches) == 1 || throw(StaleReference(name))
    row = only(matches)
    _observed_int(row[2], "client_pid")
    _observed_int(row[3], "client_created")
    row[2] * ":" * row[3] == client.id.incarnation || throw(StaleReference(name))
    # tmux removes one trailing colon before comparing client names.
    name * ":"
end

"""
    switch_client(connection::ControlConnection, client::ClientRef, session::SessionRef;
                  update_environment=false, kwargs...)

Switch the captured client to the exact session on the connected daemon.
Recheck its name and observed PID/creation-time incarnation before submission.
Client names must be valid UTF-8 without spaces or control bytes because tmux
reflects them as unescaped notification fields. `update_environment=true`
copies the client's configured environment variables into the destination session.

Return `ControlResult` after the completion fence. The connection pins daemon
identity; client incarnation remains observational and can change between the
check and mutation. `strict=false` does not weaken the daemon guard. There is
no implicit current client, replay or subprocess fallback.
"""
function switch_client(
    connection::ControlConnection,
    client::ClientRef,
    session::SessionRef;
    update_environment::Bool=false,
    kwargs...,
)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, client)
    _control_exact_target(connection, session)
    target = _control_client_selector(context, client, :switch_client)
    args = ["switch-client", "-c", target, "-t", string(session.id)]
    update_environment || push!(args, "-E")
    _control_effect(
        connection,
        args;
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end

"""
    detach_client(connection::ControlConnection, client::ClientRef; kwargs...)

Detach the captured client after checking its observed incarnation. No parent
signal or shell command is sent. Client validation and observational race
semantics match `switch_client`. Return `ControlResult` after the completion
fence. Detaching a client that carries this connection can close it before the
fence and raise an uncertain-effect error; no reconnect or fallback occurs.
"""
function detach_client(connection::ControlConnection, client::ClientRef; kwargs...)
    context = _control_operation_context(connection; kwargs...)
    _control_exact_target(connection, client)
    target = _control_client_selector(context, client, :detach_client)
    _control_effect(
        connection,
        ["detach-client", "-t", target];
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel=context.cancel,
    )
end
