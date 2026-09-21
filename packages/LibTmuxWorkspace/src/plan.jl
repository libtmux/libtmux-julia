struct ExpandedPane
    commands::Tuple
    start_directory::String
    environment::Tuple
    shell::Union{Nothing,String}
    suppress_history::Bool
    focus::Bool
end
struct ExpandedWindow
    name::String
    index::Union{Nothing,Int}
    start_directory::String
    options::Tuple
    options_after::Tuple
    layout::Union{Nothing,String}
    focus::Bool
    panes::Tuple
end
"""A workspace with explicit directories, environment values and ordered commands."""
struct ExpandedWorkspace
    session_name::String
    start_directory::String
    before_script::Union{Nothing,String}
    base_directory::String
    environment::Tuple
    options::Tuple
    global_options::Tuple
    windows::Tuple
end

function _expanded_text(text, context, path; home=true)
    if home && startswith(text, "~")
        (text == "~" || startswith(text, "~/")) ||
            _fail(:home, path, "named-user home lookup is not supported")
        context.home === nothing &&
            _fail(:home, path, "supply home explicitly for tilde expansion")
        ncodeunits(context.home) <= context.limits.max_bytes - ncodeunits(text) + 1 ||
            _fail(:limit, path, "expanded string byte limit exceeded")
        text = context.home * text[2:end]
    end
    pattern = r"\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*"
    function replacement(token)
        name = startswith(token, "\${") ? token[3:(end-1)] : token[2:end]
        if haskey(context.env, name)
            return context.env[name]
        elseif context.unknown == :error
            _fail(:variable, path, "variable is absent from the supplied environment")
        end
        String(token)
    end
    # Bound the result before allocation; replacement text is never re-expanded.
    bytes = ncodeunits(text)
    for match in eachmatch(pattern, text)
        value = replacement(match.match)
        ncodeunits(value) <= context.limits.max_bytes ||
            _fail(:limit, path, "expanded value is too large")
        bytes += ncodeunits(value) - ncodeunits(match.match)
        bytes <= context.limits.max_bytes ||
            _fail(:limit, path, "expanded string byte limit exceeded")
    end
    context.bytes[] <= context.limits.max_bytes - bytes ||
        _fail(:limit, path, "expanded string byte limit exceeded")
    context.bytes[] += bytes
    replace(text, pattern => replacement)
end

function _directory(value, parent, context, path)
    value === nothing && return parent
    text = _expanded_text(value, context, path)
    normpath(isabspath(text) ? text : joinpath(parent, text))
end

function _expanded_pairs(pairs, context, path)
    Tuple(
        name => (
            value isa String ?
            begin
                text = _expanded_text(value, context, path * "." * name)
                startswith(text, ".") ? normpath(joinpath(context.base, text)) : text
            end : value
        ) for (name, value) in pairs
    )
end
function _merge_environment(parent, child)
    values = Dict{String,String}(parent)
    for (name, value) in child
        values[name] = value
    end
    Tuple(name => values[name] for name in sort!(collect(keys(values))))
end

"""
    expand(config; env=Dict(), home=nothing, base_directory=nothing,
           unknown_variables=:preserve, limits=ConfigLimits()) -> ExpandedWorkspace

Expand only the supplied environment (`\$NAME` and `\${NAME}`) and home directory.
Absent variables remain literal by default; `:error` rejects them. Directories
resolve lexically against their parent, starting at the supplied absolute base
or the config file's directory. There is no implicit `ENV`, cwd, home lookup,
filesystem traversal, shell expansion or command execution.

Before commands run in session, window, pane order before each pane's commands.
A pane environment map replaces window overrides, while retaining session values,
as in tmuxp. Commands stay inert, including `before_script`.
"""
function expand(
    config::WorkspaceConfig;
    env::AbstractDict=Dict{String,String}(),
    home=nothing,
    base_directory=nothing,
    unknown_variables::Symbol=:preserve,
    limits::ConfigLimits=ConfigLimits(),
)
    unknown_variables in (:preserve, :error) ||
        throw(ArgumentError("unknown_variables must be :preserve or :error"))
    base =
        base_directory === nothing ?
        (
            config.source_path === nothing ?
            _fail(:path, "\$", "supply an absolute base_directory or source_path") :
            dirname(config.source_path)
        ) : _string(base_directory, "\$.base_directory"; empty=false)
    isabspath(base) || _fail(:path, "\$.base_directory", "base_directory must be absolute")
    base = normpath(base)
    if home !== nothing
        home = _string(home, "\$.home"; empty=false)
        isabspath(home) || _fail(:path, "\$.home", "home must be absolute")
        home = normpath(home)
    end
    supplied = Dict{String,String}()
    for (name, value) in env
        key = _string(name, "\$.env"; empty=false)
        supplied[key] = _string(value, "\$.env." * key)
    end
    context = (
        env=supplied,
        home=home,
        base=base,
        unknown=unknown_variables,
        limits=limits,
        bytes=Ref(0),
    )
    name = _expanded_text(config.session_name, context, "\$.session_name")
    isempty(name) && _fail(:value, "\$.session_name", "expanded name must not be empty")
    directory = _directory(config.start_directory, base, context, "\$.start_directory")
    environment = _expanded_pairs(config.environment, context, "\$.environment")
    windows = ExpandedWindow[]
    for (wi, window) in enumerate(config.windows)
        path = "\$.windows[$wi]"
        wname = _expanded_text(window.name, context, path * ".window_name")
        isempty(wname) &&
            _fail(:value, path * ".window_name", "expanded name must not be empty")
        wdir = _directory(
            window.start_directory,
            directory,
            context,
            path * ".start_directory",
        )
        wenv = _expanded_pairs(window.environment, context, path * ".environment")
        suppress = something(window.suppress_history, config.suppress_history)
        panes = ExpandedPane[]
        for (pi, pane) in enumerate(window.panes)
            ppath = path * ".panes[$pi]"
            pdir =
                _directory(pane.start_directory, wdir, context, ppath * ".start_directory")
            overrides =
                pane.environment === nothing ? wenv :
                _expanded_pairs(pane.environment, context, ppath * ".environment")
            commands = CommandConfig[]
            for command in
                (config.before..., window.before..., pane.before..., pane.commands...)
                push!(
                    commands,
                    CommandConfig(
                        _expanded_text(command.text, context, ppath * ".shell_command"),
                        something(command.enter, pane.enter),
                    ),
                )
            end
            push!(
                panes,
                ExpandedPane(
                    Tuple(commands),
                    pdir,
                    _merge_environment(environment, overrides),
                    pane.shell === nothing ? window.shell : pane.shell,
                    something(pane.suppress_history, suppress),
                    pane.focus,
                ),
            )
        end
        push!(
            windows,
            ExpandedWindow(
                wname,
                window.index,
                wdir,
                _expanded_pairs(window.options, context, path * ".options"),
                _expanded_pairs(window.options_after, context, path * ".options_after"),
                window.layout,
                window.focus,
                Tuple(panes),
            ),
        )
    end
    script =
        config.before_script === nothing ? nothing :
        _expanded_text(config.before_script, context, "\$.before_script")
    script !== nothing &&
        isempty(script) &&
        _fail(:value, "\$.before_script", "expanded script must not be empty")
    ExpandedWorkspace(
        name,
        directory,
        script,
        base,
        environment,
        _expanded_pairs(config.options, context, "\$.options"),
        _expanded_pairs(config.global_options, context, "\$.global_options"),
        Tuple(windows),
    )
end

"""
An inert effect with 1-based config window/pane positions, not tmux indices.
`nothing` denotes session/global scope. `arguments` contains owned values.
"""
struct PlanStep
    action::Symbol
    window::Union{Nothing,Int}
    pane::Union{Nothing,Int}
    arguments::NamedTuple
end
struct WorkspacePlan
    workspace::ExpandedWorkspace
    steps::Tuple
end

"""
    plan(workspace::ExpandedWorkspace) -> WorkspacePlan

Describe ordered effects without starting processes, connecting to tmux, probing
paths or executing hooks. Window creation includes its first pane. Explicit
window indices are distinct from the 1-based positions used in plan targets.
The plan records script text and its base directory; it does not shell-evaluate
`before_script` or promise rollback of future shell effects.
"""
function plan(workspace::ExpandedWorkspace)
    steps = PlanStep[]
    push!(
        steps,
        PlanStep(
            :create_session,
            nothing,
            nothing,
            (name=workspace.session_name, start_directory=workspace.start_directory),
        ),
    )
    if workspace.before_script !== nothing
        push!(
            steps,
            PlanStep(
                :before_script,
                nothing,
                nothing,
                (
                    text=workspace.before_script,
                    base_directory=workspace.base_directory,
                    start_directory=workspace.start_directory,
                ),
            ),
        )
    end
    for (scope, options) in
        ((:session, workspace.options), (:global_session, workspace.global_options))
        for (name, value) in options
            push!(steps, PlanStep(:set_option, nothing, nothing, (; scope, name, value)))
        end
    end
    for (name, value) in workspace.environment
        push!(steps, PlanStep(:set_environment, nothing, nothing, (; name, value)))
    end
    for (wi, window) in enumerate(workspace.windows)
        firstpane = first(window.panes)
        push!(
            steps,
            PlanStep(
                :create_window,
                wi,
                1,
                (
                    name=window.name,
                    index=window.index,
                    start_directory=firstpane.start_directory,
                    environment=firstpane.environment,
                    shell=firstpane.shell,
                ),
            ),
        )
        for (name, value) in window.options
            push!(
                steps,
                PlanStep(:set_option, wi, nothing, (scope=:window, name=name, value=value)),
            )
        end
        for (pi, pane) in enumerate(window.panes)
            if pi > 1
                push!(
                    steps,
                    PlanStep(
                        :split_pane,
                        wi,
                        pi,
                        (
                            start_directory=pane.start_directory,
                            environment=pane.environment,
                            shell=pane.shell,
                        ),
                    ),
                )
            end
            for command in pane.commands
                push!(
                    steps,
                    PlanStep(
                        :send_command,
                        wi,
                        pi,
                        (
                            text=command.text,
                            enter=command.enter,
                            suppress_history=pane.suppress_history,
                        ),
                    ),
                )
            end
        end
        window.layout === nothing ||
            push!(steps, PlanStep(:select_layout, wi, nothing, (layout=window.layout,)))
        for (name, value) in window.options_after
            push!(
                steps,
                PlanStep(:set_option, wi, nothing, (scope=:window, name=name, value=value)),
            )
        end
        for (pi, pane) in enumerate(window.panes)
            pane.focus && push!(steps, PlanStep(:focus_pane, wi, pi, (;)))
        end
    end
    for (wi, window) in enumerate(workspace.windows)
        window.focus && push!(steps, PlanStep(:focus_window, wi, nothing, (;)))
    end
    WorkspacePlan(workspace, Tuple(steps))
end
