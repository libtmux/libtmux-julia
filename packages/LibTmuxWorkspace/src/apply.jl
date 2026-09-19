"""Known creations, completed plan steps and effects requiring caller inspection."""
struct WorkspaceApplyResult
    status::Symbol
    session::Union{Nothing,LibTmux.SessionRef}
    created::Tuple
    borrowed::Tuple
    completed::Tuple
    unknown_effects::Tuple
    removed::Tuple
    rollback::Tuple
end
struct WorkspaceApplyError <: Exception
    result::WorkspaceApplyResult
    cause::Exception
end
Base.showerror(io::IO, error::WorkspaceApplyError) = print(
    io,
    "workspace application ",
    error.result.status,
    "; ",
    length(error.result.completed),
    " plan steps completed; inspect result and cause for partial effects",
)

function _remaining(started, budget, cancel)
    cancel === nothing ||
        !LibTmux.iscancelled(cancel) ||
        throw(LibTmux.RequestCancelled(false))
    remaining = budget - (time_ns() - started) / 1e9
    remaining > 0 || throw(LibTmux.DeadlineExceeded(budget, false, nothing))
    remaining
end
_shell_word(value) = "'" * replace(value, "'" => "'\\''") * "'"
_option_text(value::Bool) = value ? "on" : "off"
_option_text(value) = string(value)

function _session_view(snapshot, ref)
    snapshot.identity == ref.server || throw(LibTmux.StaleReference(string(ref.id)))
    only(filter(s -> s.ref == ref, LibTmux.sessions(snapshot)))
end
function _created_window(server, session_ref, window_ref, remaining, cancel)
    snap = LibTmux.snapshot(server; timeout=remaining(), cancel)
    view = _session_view(snap, session_ref)
    link = only(filter(l -> LibTmux.window(l).ref == window_ref, LibTmux.windowlinks(view)))
    pane = only(LibTmux.panes(LibTmux.window(link))).ref
    LibTmux.WindowLinkRef(link), pane
end

function _with_ready_marker(publish, timeout, cancel)
    started = time_ns()
    directory = mktempdir(; prefix="libtmux-julia-ready-")
    marker = joinpath(directory, "ready")
    content = string(uuid4())
    monitor = nothing
    timer = nothing
    timer_task = nothing
    subscription = nothing
    state_lock = ReentrantLock()
    retired = Ref(false)
    reason = Ref{Union{Nothing,Symbol}}(nothing)
    function stop(code)
        lock(state_lock) do
            retired[] && return
            reason[] === nothing && (reason[] = code)
            monitor === nothing || close(monitor)
        end
    end
    function check()
        cause = lock(state_lock) do
            reason[]
        end
        cause == :cancelled && throw(LibTmux.RequestCancelled(true))
        cause == :deadline && throw(LibTmux.DeadlineExceeded(timeout, true, nothing))
        _remaining(started, timeout, cancel)
    end
    try
        monitor = FolderMonitor(directory)
        subscription =
            cancel === nothing ? nothing : LibTmux.on_cancel(() -> stop(:cancelled), cancel)
        timer, timer_task = _owned_timer(() -> stop(:deadline), check())
        check()
        publish(marker, content)
        while true
            check()
            event = try
                wait(monitor)
            catch error
                check()
                rethrow()
            end
            check()
            # The producer publishes by rename: reads never observe partial text.
            first(event) == "ready" || continue
            bytes = open(marker, "r") do io
                read(io, ncodeunits(content) + 1)
            end
            bytes == codeunits(content) ||
                throw(ArgumentError("invalid shell readiness marker"))
            return nothing
        end
    finally
        lock(state_lock) do
            retired[] = true
        end
        timer === nothing || close(timer)
        timer_task === nothing || wait(timer_task)
        subscription === nothing || close(subscription)
        monitor === nothing || close(monitor)
        # A late producer cannot recreate the removed parent directory.
        rm(directory; recursive=true, force=true)
    end
end

function _pane_ready(server, session_ref, pane, timeout, cancel)
    _with_ready_marker(min(0.9, timeout()), cancel) do marker, content
        pending = marker * ".pending"
        line =
            " (command printf '%s' " *
            _shell_word(content) *
            " > " *
            _shell_word(pending) *
            " && command mv " *
            _shell_word(pending) *
            " " *
            _shell_word(marker) *
            ") 2>/dev/null"
        LibTmux.send_keys(server, pane, line; literal=true, timeout=timeout(), cancel)
        LibTmux.send_keys(server, pane, "Enter"; timeout=timeout(), cancel)
    end
    nothing
end

function _rollback_created(server, session_ref, created_session, links, created)
    outcomes = NamedTuple[]
    started, budget = time_ns(), 0.9
    remaining() = _remaining(started, budget, nothing)
    if created_session && session_ref !== nothing
        try
            LibTmux.kill_session(server, session_ref; timeout=remaining())
            push!(outcomes, (target=session_ref, status=:removed))
        catch error
            push!(outcomes, (target=session_ref, status=:unresolved))
        end
    else
        observed = Set(link.window for link in links)
        for ref in created
            ref isa LibTmux.WindowRef &&
                !(ref in observed) &&
                push!(outcomes, (target=ref, status=:unresolved))
        end
        for link in reverse(links)
            try
                # Remove only the created occurrence, preserving any other links.
                LibTmux.unlink_window(server, link; allow_destroy=true, timeout=remaining())
                push!(outcomes, (target=link.window, status=:removed_link))
            catch error
                push!(outcomes, (target=link.window, status=:unresolved))
            end
        end
    end
    Tuple(outcomes)
end

"""
    apply(server, plan; timeout=30.0, cancel=nothing, reuse=nothing,
          rollback=:none, readiness=:posix_shell, script_env=ENV, on_event=nothing)

Apply detached through public core operations under one monotonic deadline.
Existing names fail by default. `reuse=SessionRef(...)` explicitly borrows that
exact session after checking its generation and name. Only newly created panes
receive commands. The plan's 1-based positions resolve to returned typed refs.

Default readiness sends a marker through a POSIX shell and awaits its atomic
publication through an owned directory monitor. No polling or delays occur.
Cancellation removes the directory, so late producers cannot leave waiters.
Custom launchers with
input require explicit `readiness=:none`. A successful command step means input
was delivered, not that its shell job finished or succeeded.

`rollback=:created` attempts uncancelled cleanup within 900 ms: remove the new
session, or only created window links in a borrowed session. It does not restore
borrowed options/environment, global settings or shell effects. Failed/uncertain
creations are never guessed at or deleted. Inspect `WorkspaceApplyError.result`.
Events run synchronously and must return promptly; a callback error stops apply.
"""
function apply(
    server::LibTmux.Server,
    prepared::WorkspacePlan;
    timeout::Real=30.0,
    cancel=nothing,
    reuse::Union{Nothing,LibTmux.SessionRef}=nothing,
    rollback::Symbol=:none,
    readiness::Symbol=:posix_shell,
    script_env::AbstractDict=ENV,
    on_event=nothing,
)
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 ||
        throw(ArgumentError("invalid workspace timeout"))
    rollback in (:none, :created) ||
        throw(ArgumentError("rollback must be :none or :created"))
    readiness in (:none, :posix_shell) ||
        throw(ArgumentError("readiness must be :none or :posix_shell"))
    workspace = prepared.workspace
    if readiness == :posix_shell
        any(
            p -> p.shell !== nothing && !isempty(p.commands),
            (p for w in workspace.windows for p in w.panes),
        ) && throw(
            ArgumentError("custom pane launchers with commands require readiness=:none"),
        )
    end
    started = time_ns()
    remaining() = _remaining(started, budget, cancel)
    emit(event; fields...) = on_event === nothing ? nothing : on_event((; event, fields...))
    created, borrowed, completed, unknown, removed =
        Any[], Any[], Int[], NamedTuple[], Any[]
    links = LibTmux.WindowLinkRef[]
    panes = Dict{Tuple{Int,Int},LibTmux.PaneRef}()
    session_ref = nothing
    created_session = false
    placeholder = nothing
    current = 0
    result(status; rollback_outcomes=()) = WorkspaceApplyResult(
        status,
        session_ref,
        Tuple(created),
        Tuple(borrowed),
        Tuple(completed),
        Tuple(unknown),
        Tuple(removed),
        rollback_outcomes,
    )
    try
        for (index, step) in enumerate(prepared.steps)
            current = index
            remaining()
            emit(:step_started; step=index, action=step.action)
            args, wi, pi = step.arguments, step.window, step.pane
            if step.action == :create_session
                if reuse === nothing
                    session_ref = LibTmux.new_session(
                        server;
                        name=args.name,
                        start_directory=args.start_directory,
                        command=["/bin/cat"],
                        timeout=remaining(),
                        cancel,
                    )
                    created_session = true
                    push!(created, session_ref)
                    snap = LibTmux.snapshot(server; timeout=remaining(), cancel)
                    initial = only(LibTmux.windowlinks(_session_view(snap, session_ref)))
                    placeholder = LibTmux.WindowLinkRef(initial)
                    reserved =
                        Set(w.index for w in workspace.windows if w.index !== nothing)
                    slot = Int(typemax(Int32))
                    while slot in reserved
                        slot -= 1
                    end
                    LibTmux.move_window(
                        server,
                        placeholder,
                        session_ref;
                        index=slot,
                        timeout=remaining(),
                        cancel,
                    )
                    placeholder =
                        LibTmux.WindowLinkRef(session_ref, placeholder.window, slot)
                else
                    snap = LibTmux.snapshot(server; timeout=remaining(), cancel)
                    view = _session_view(snap, reuse)
                    view.name == args.name ||
                        throw(ArgumentError("borrowed session name differs from the plan"))
                    session_ref = reuse
                    push!(borrowed, reuse)
                end
            elseif step.action == :before_script
                push!(unknown, (step=index, effect=:external_script))
                run_before_script(
                    args.text;
                    base_directory=args.base_directory,
                    start_directory=args.start_directory,
                    env=script_env,
                    timeout=remaining(),
                    cancel,
                    on_output=(stream, bytes) ->
                        emit(:script_output; step=index, stream, bytes),
                )
            elseif step.action == :set_option
                scope =
                    args.scope == :global_session ? :global_session :
                    args.scope == :session ? session_ref : links[wi].window
                LibTmux.set_option(
                    server,
                    scope,
                    args.name,
                    _option_text(args.value);
                    timeout=remaining(),
                    cancel,
                )
                scope == :global_session || !created_session && wi === nothing ?
                push!(unknown, (step=index, effect=:borrowed_configuration)) : nothing
            elseif step.action == :set_environment
                LibTmux.set_environment(
                    server,
                    session_ref,
                    args.name,
                    args.value;
                    timeout=remaining(),
                    cancel,
                )
                created_session ||
                    push!(unknown, (step=index, effect=:borrowed_configuration))
            elseif step.action == :create_window
                if readiness == :posix_shell && args.shell === nothing
                    shell = LibTmux.get_option(
                        server,
                        session_ref,
                        "default-shell";
                        inherit=true,
                        timeout=remaining(),
                        cancel,
                    )
                    basename(something(shell, "")) in
                    ("sh", "bash", "dash", "zsh", "ksh", "mksh", "ash") || throw(
                        ArgumentError(
                            "readiness=:posix_shell requires a supported POSIX shell",
                        ),
                    )
                end
                window_ref = LibTmux.new_window(
                    server,
                    session_ref;
                    name=args.name,
                    index=args.index,
                    environment=args.environment,
                    start_directory=args.start_directory,
                    shell_command=args.shell,
                    timeout=remaining(),
                    cancel,
                )
                push!(created, window_ref)
                link, pane =
                    _created_window(server, session_ref, window_ref, remaining, cancel)
                push!(links, link)
                panes[(wi, 1)] = pane
                push!(created, pane)
                readiness == :posix_shell &&
                    args.shell === nothing &&
                    _pane_ready(server, session_ref, pane, remaining, cancel)
            elseif step.action == :split_pane
                pane = LibTmux.split_window(
                    server,
                    panes[(wi, pi - 1)];
                    environment=args.environment,
                    start_directory=args.start_directory,
                    shell_command=args.shell,
                    timeout=remaining(),
                    cancel,
                )
                panes[(wi, pi)] = pane
                push!(created, pane)
                readiness == :posix_shell &&
                    args.shell === nothing &&
                    _pane_ready(server, session_ref, pane, remaining, cancel)
            elseif step.action == :send_command
                pane = panes[(wi, pi)]
                text = args.suppress_history ? " " * args.text : args.text
                push!(unknown, (step=index, effect=:shell_input))
                LibTmux.paste_text(server, pane, text; timeout=remaining(), cancel)
                args.enter &&
                    LibTmux.send_keys(server, pane, "Enter"; timeout=remaining(), cancel)
            elseif step.action == :select_layout
                LibTmux.select_layout(
                    server,
                    links[wi].window,
                    args.layout;
                    timeout=remaining(),
                    cancel,
                )
            elseif step.action == :focus_pane
                LibTmux.select_pane(server, panes[(wi, pi)]; timeout=remaining(), cancel)
            elseif step.action == :focus_window
                LibTmux.select_window(server, links[wi]; timeout=remaining(), cancel)
            else
                throw(ArgumentError("unknown workspace plan action"))
            end
            push!(completed, index)
            emit(:step_completed; step=index, action=step.action)
        end
        if placeholder !== nothing
            LibTmux.unlink_window(
                server,
                placeholder;
                allow_destroy=true,
                timeout=remaining(),
                cancel,
            )
            push!(removed, placeholder.window)
        end
        if !any(w -> w.focus, workspace.windows)
            LibTmux.select_window(server, first(links); timeout=remaining(), cancel)
        end
        answer = result(:complete)
        emit(:complete; result=answer)
        answer
    catch error
        error isa WorkspaceApplyError && rethrow()
        current in completed || push!(unknown, (step=current, effect=:uncertain_step))
        outcomes =
            rollback == :created ?
            _rollback_created(server, session_ref, created_session, links, created) : ()
        cancelled =
            error isa InterruptException ||
            error isa LibTmux.RequestCancelled ||
            error isa BeforeScriptError && error.code == :cancelled
        status =
            cancelled ? :cancelled :
            isempty(created) && isempty(borrowed) ? :failed : :partial
        throw(WorkspaceApplyError(result(status; rollback_outcomes=outcomes), error))
    end
end

"""
    freeze(server, session::SessionRef; timeout=5.0, cancel=nothing)

Capture the supported reconstruction subset as a version-1 `WorkspaceDocument`:
session/window names, window indices/layouts, pane paths and focus. Commands,
options, environment, history and shell side effects cannot be reconstructed and
are omitted. Shared windows become independent windows when this data is loaded.
Acquisition and layout reads are bounded observations, not one atomic snapshot.
"""
function freeze(
    server::LibTmux.Server,
    target::LibTmux.SessionRef;
    timeout::Real=5.0,
    cancel=nothing,
)
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 || throw(ArgumentError("invalid freeze timeout"))
    started = time_ns()
    remaining() = _remaining(started, budget, cancel)
    snap = LibTmux.snapshot(server; timeout=remaining(), cancel)
    view = _session_view(snap, target)
    data = Dict{String,Any}("schema_version" => 1, "session_name" => view.name)
    windows = Any[]
    for link in sort!(collect(LibTmux.windowlinks(view)); by=l -> l.index)
        win = LibTmux.window(link)
        item = Dict{String,Any}(
            "window_name" => win.name,
            "window_index" => link.index,
            "focus" => link.active,
        )
        layout = only(
            LibTmux.read_formats(
                server,
                win.ref,
                LibTmux.FormatField("window_layout");
                timeout=remaining(),
                cancel,
            ),
        )
        isempty(layout.raw) || (item["layout"] = layout.raw)
        pane_data = Any[]
        for pane in sort!(collect(LibTmux.panes(win)); by=p -> p.index)
            entry = Dict{String,Any}("focus" => pane.active)
            hasproperty(pane, :current_path) &&
                (entry["start_directory"] = pane.current_path)
            push!(pane_data, entry)
        end
        item["panes"] = pane_data
        push!(windows, item)
    end
    data["windows"] = windows
    document = WorkspaceDocument(data, nothing, ConfigLimits())
    validate(document)
    document
end
