"""Bound document bytes, nesting and total values before schema normalization."""
struct ConfigLimits
    max_bytes::Int
    max_depth::Int
    max_nodes::Int
    function ConfigLimits(; max_bytes::Int=1024^2, max_depth::Int=32, max_nodes::Int=20_000)
        0 < max_bytes < typemax(Int) && 0 < max_depth <= 128 && max_nodes > 0 ||
            throw(ArgumentError("limits must be positive; max_depth must not exceed 128"))
        new(max_bytes, max_depth, max_nodes)
    end
end

"""A stable diagnostic code and document path, without interpolated config values."""
struct WorkspaceConfigError <: Exception
    code::Symbol
    path::String
    message::String
end
Base.showerror(io::IO, e::WorkspaceConfigError) =
    print(io, "workspace ", e.code, " at ", e.path, ": ", e.message)
_fail(code, path, message) = throw(WorkspaceConfigError(code, path, message))

"""Parsed data plus its optional absolute source path. Call `validate` before use."""
struct WorkspaceDocument
    data::Any
    source_path::Union{Nothing,String}
    limits::ConfigLimits
end

"""Inert pane text. `enter=nothing` inherits the pane's submission policy."""
struct CommandConfig
    text::String
    enter::Union{Nothing,Bool}
end
struct PaneConfig
    commands::Tuple
    before::Tuple
    start_directory::Union{Nothing,String}
    environment::Union{Nothing,Tuple}
    shell::Union{Nothing,String}
    enter::Bool
    suppress_history::Union{Nothing,Bool}
    focus::Bool
end
struct WindowConfig
    name::String
    index::Union{Nothing,Int}
    start_directory::Union{Nothing,String}
    before::Tuple
    environment::Tuple
    options::Tuple
    options_after::Tuple
    layout::Union{Nothing,String}
    shell::Union{Nothing,String}
    suppress_history::Union{Nothing,Bool}
    focus::Bool
    panes::Tuple
end
"""Validated, owned values. Version 1 also accepts unversioned tmuxp documents."""
struct WorkspaceConfig
    schema_version::Int
    session_name::String
    start_directory::Union{Nothing,String}
    before_script::Union{Nothing,String}
    before::Tuple
    environment::Tuple
    options::Tuple
    global_options::Tuple
    suppress_history::Bool
    windows::Tuple
    source_path::Union{Nothing,String}
end

const _UNSUPPORTED = Set((
    "plugins",
    "workspace_builder",
    "workspace_builder_paths",
    "workspace_builder_options",
    "extends",
    "imports",
    "import",
    "sleep_before",
    "sleep_after",
    "sleep",
    "hooks",
))
const _SESSION_KEYS = Set((
    "schema_version",
    "session_name",
    "start_directory",
    "before_script",
    "shell_command_before",
    "environment",
    "options",
    "global_options",
    "suppress_history",
    "windows",
))
const _WINDOW_KEYS = Set((
    "window_name",
    "window_index",
    "start_directory",
    "shell_command_before",
    "environment",
    "options",
    "options_after",
    "layout",
    "window_shell",
    "suppress_history",
    "focus",
    "panes",
))
const _PANE_KEYS = Set((
    "shell_command",
    "shell_command_before",
    "start_directory",
    "environment",
    "shell",
    "enter",
    "suppress_history",
    "focus",
))

# Count every visit, including repeated references. Cycles hit the depth bound.
function _bound_data(data, limits, path="\$", depth=1, counter=Ref(0), bytes=Ref(0))
    depth <= limits.max_depth || _fail(:limit, path, "nesting limit exceeded")
    counter[] += 1
    counter[] <= limits.max_nodes || _fail(:limit, path, "value count limit exceeded")
    if data isa AbstractDict
        for (key, value) in data
            _bound_data(key, limits, path, depth + 1, counter, bytes)
            _bound_data(value, limits, path, depth + 1, counter, bytes)
        end
    elseif data isa AbstractVector || data isa Tuple
        for value in data
            _bound_data(value, limits, path, depth + 1, counter, bytes)
        end
    elseif data isa AbstractString
        bytes[] += ncodeunits(data)
        bytes[] <= limits.max_bytes || _fail(:limit, path, "string byte limit exceeded")
        isvalid(data) || _fail(:encoding, path, "strings must contain valid UTF-8")
    elseif !(data isa Union{Nothing,Bool,Integer,AbstractFloat})
        _fail(:type, path, "expected JSON-compatible data")
    end
    nothing
end

function _mapping(value, path, allowed=nothing)
    value isa AbstractDict || _fail(:type, path, "expected a mapping")
    for key in keys(value)
        key isa AbstractString || _fail(:type, path, "mapping keys must be strings")
        if allowed !== nothing && !(key in allowed)
            key in _UNSUPPORTED && _fail(
                :unsupported,
                path * "." * key,
                "this tmuxp feature is not supported by workspace schema 1",
            )
            _fail(:unknown_key, path * "." * key, "unknown configuration key")
        end
    end
    value
end

function _string(value, path; empty=true)
    value isa AbstractString || _fail(:type, path, "expected a string")
    isvalid(value) || _fail(:encoding, path, "expected valid UTF-8")
    occursin('\0', value) && _fail(:value, path, "NUL is not allowed")
    empty || !isempty(value) || _fail(:value, path, "value must not be empty")
    String(value)
end
_required(data, key, path) =
    haskey(data, key) ? data[key] :
    _fail(:required, path * "." * key, "required key is missing")
_optional_string(data, key, path) =
    haskey(data, key) ? _string(data[key], path * "." * key; empty=false) : nothing
function _boolean(data, key, path, default)
    haskey(data, key) || return default
    value = data[key]
    value isa Bool || _fail(:type, path * "." * key, "expected true or false")
    value
end

function _pairs(data, key, path; environment=false)
    haskey(data, key) || return ()
    location = path * "." * key
    values = _mapping(data[key], location)
    result = Pair{String,Any}[]
    for name in sort!(collect(keys(values)))
        itempath = location * "." * name
        name = _string(name, location; empty=false)
        if environment
            occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", name) ||
                _fail(:value, itempath, "expected a portable environment name")
            value = _string(values[name], itempath)
        else
            value = values[name]
            value isa Union{AbstractString,Bool,Integer} || _fail(
                :type,
                itempath,
                "option values must be strings, integers or booleans",
            )
            value isa AbstractString && (value = _string(value, itempath))
            value isa Integer &&
                !(value isa Bool) &&
                !(typemin(Int64) <= value <= typemax(Int64)) &&
                _fail(:value, itempath, "integer option is outside the signed 64-bit range")
            value isa Integer && !(value isa Bool) && (value = Int64(value))
        end
        push!(result, name => value)
    end
    Tuple(result)
end

function _commands(value, path)
    value === nothing && return ()
    items = value isa AbstractString ? [value] : value
    items isa AbstractVector || _fail(:type, path, "expected command text or a list")
    if length(items) == 1 &&
       (items[1] === nothing || items[1] == "blank" || items[1] == "pane")
        return ()
    end
    result = CommandConfig[]
    for (i, item) in enumerate(items)
        location = path * "[$i]"
        if item isa AbstractString
            push!(result, CommandConfig(_string(item, location), nothing))
        else
            item = _mapping(item, location, Set(("cmd", "enter")))
            text = _string(_required(item, "cmd", location), location * ".cmd")
            push!(result, CommandConfig(text, _boolean(item, "enter", location, nothing)))
        end
    end
    Tuple(result)
end

function _pane(value, path)
    data =
        value === nothing || value isa AbstractString || value isa AbstractVector ?
        Dict("shell_command" => value) : value
    data = _mapping(data, path, _PANE_KEYS)
    PaneConfig(
        _commands(get(data, "shell_command", nothing), path * ".shell_command"),
        _commands(
            get(data, "shell_command_before", nothing),
            path * ".shell_command_before",
        ),
        _optional_string(data, "start_directory", path),
        haskey(data, "environment") ? _pairs(data, "environment", path; environment=true) :
        nothing,
        _optional_string(data, "shell", path),
        _boolean(data, "enter", path, true),
        _boolean(data, "suppress_history", path, nothing),
        _boolean(data, "focus", path, false),
    )
end

function _window(value, path)
    data = _mapping(value, path, _WINDOW_KEYS)
    name = _string(_required(data, "window_name", path), path * ".window_name"; empty=false)
    index = get(data, "window_index", nothing)
    if haskey(data, "window_index")
        index isa Integer && !(index isa Bool) && 0 <= index <= typemax(Int32) || _fail(
            :value,
            path * ".window_index",
            "expected an integer from 0 through 2147483647",
        )
        index = Int(index)
    end
    panes = get(data, "panes", Any[nothing])
    panes isa AbstractVector || _fail(:type, path * ".panes", "expected a nonempty list")
    isempty(panes) && _fail(:value, path * ".panes", "at least one pane is required")
    normalized = Tuple(_pane(pane, path * ".panes[$i]") for (i, pane) in enumerate(panes))
    count(p -> p.focus, normalized) <= 1 ||
        _fail(:value, path * ".panes", "only one pane may request focus")
    WindowConfig(
        name,
        index,
        _optional_string(data, "start_directory", path),
        _commands(
            get(data, "shell_command_before", nothing),
            path * ".shell_command_before",
        ),
        _pairs(data, "environment", path; environment=true),
        _pairs(data, "options", path),
        _pairs(data, "options_after", path),
        _optional_string(data, "layout", path),
        _optional_string(data, "window_shell", path),
        _boolean(data, "suppress_history", path, nothing),
        _boolean(data, "focus", path, false),
        normalized,
    )
end

"""
    validate(document_or_mapping; limits=ConfigLimits()) -> WorkspaceConfig

Validate schema version 1, copy caller-owned values and normalize pane shorthand.
No environment expansion, file access, subprocesses or tmux calls occur here.
Unknown keys and unsupported Python plugins/builders produce precise errors.
"""
function validate(
    data::AbstractDict;
    limits::ConfigLimits=ConfigLimits(),
    source_path=nothing,
)
    _bound_data(data, limits)
    data = _mapping(data, "\$", _SESSION_KEYS)
    version = get(data, "schema_version", 1)
    version isa Integer && !(version isa Bool) && version == 1 ||
        _fail(:version, "\$.schema_version", "only schema version 1 is supported")
    name = _string(_required(data, "session_name", "\$"), "\$.session_name"; empty=false)
    windows = _required(data, "windows", "\$")
    windows isa AbstractVector || _fail(:type, "\$.windows", "expected a nonempty list")
    isempty(windows) && _fail(:value, "\$.windows", "at least one window is required")
    normalized =
        Tuple(_window(window, "\$.windows[$i]") for (i, window) in enumerate(windows))
    count(w -> w.focus, normalized) <= 1 ||
        _fail(:value, "\$.windows", "only one window may request focus")
    indices = [w.index for w in normalized if w.index !== nothing]
    length(unique(indices)) == length(indices) ||
        _fail(:value, "\$.windows", "window indices must be distinct")
    WorkspaceConfig(
        1,
        name,
        _optional_string(data, "start_directory", "\$"),
        _optional_string(data, "before_script", "\$"),
        _commands(get(data, "shell_command_before", nothing), "\$.shell_command_before"),
        _pairs(data, "environment", "\$"; environment=true),
        _pairs(data, "options", "\$"),
        _pairs(data, "global_options", "\$"),
        _boolean(data, "suppress_history", "\$", true),
        normalized,
        _source_path(source_path),
    )
end
function validate(document::WorkspaceDocument; limits::ConfigLimits=document.limits)
    document.data isa AbstractDict || _fail(:type, "\$", "workspace root must be a mapping")
    validate(document.data; limits, source_path=document.source_path)
end
validate(data; kwargs...) = _fail(:type, "\$", "workspace root must be a mapping")
