const _CLI_HELP = """
Usage: libtmux-mcp (--socket PATH | --socket-name NAME) [options]

Serve MCP over stdin/stdout; diagnostics go to stderr. The tmux server is
borrowed. Only sessions created through enabled tools belong to this process.

  --tmux PATH           tmux executable (default: tmux)
  --caller-pane ID      captured pane used when a tool omits its target
  --allow-pane ID       permit this pane; repeat to restrict the target set
  --tool NAME           enable a tool; repeat to replace the default catalog
  --allow-create        permit enabled creation tools to create owned sessions
  --timeout SECONDS     shared per-tool deadline, greater than 0 and at most 30
  --workers N           concurrent request workers (default: 4)
  --capacity N          queued and running request limit, at most 16 (default: 16)
  --help                print this help without contacting tmux

Default tools: list_panes, capture_pane, send_keys.
Pane IDs must be exact tmux IDs, such as %3. No ambient/current pane fallback.
"""

function _cli_options(arguments)
    args = String[String(argument) for argument in arguments]
    args == ["--help"] && return (; help=true)
    values = Dict{String,String}()
    pane_ids, tool_names = String[], String[]
    allow_create = false
    scalar = (
        "--socket",
        "--socket-name",
        "--tmux",
        "--caller-pane",
        "--timeout",
        "--workers",
        "--capacity",
    )
    index = 1
    while index <= length(args)
        flag = args[index]
        if flag == "--allow-create"
            allow_create && throw(ArgumentError("duplicate --allow-create"))
            allow_create = true
            index += 1
            continue
        end
        flag in (scalar..., "--allow-pane", "--tool") ||
            throw(ArgumentError("unknown option: $flag"))
        index < length(args) || throw(ArgumentError("missing value for $flag"))
        value = args[index+1]
        (!isempty(value) && isvalid(value) && !occursin('\0', value)) ||
            throw(ArgumentError("$flag requires nonempty UTF-8 text without NUL"))
        if flag == "--allow-pane"
            LibTmux.PaneID(value)
            push!(pane_ids, value)
        elseif flag == "--tool"
            value in _TOOL_NAMES || throw(ArgumentError("unknown tool: $value"))
            push!(tool_names, value)
        else
            haskey(values, flag) && throw(ArgumentError("duplicate $flag"))
            values[flag] = value
        end
        index += 2
    end
    xor(haskey(values, "--socket"), haskey(values, "--socket-name")) ||
        throw(ArgumentError("supply exactly one of --socket or --socket-name"))
    caller = get(values, "--caller-pane", nothing)
    caller === nothing || LibTmux.PaneID(caller)
    length(pane_ids) <= 256 && length(unique(pane_ids)) == length(pane_ids) ||
        throw(ArgumentError("allow at most 256 distinct panes"))
    length(unique(tool_names)) == length(tool_names) ||
        throw(ArgumentError("duplicate tool"))
    timeout = tryparse(Float64, get(values, "--timeout", "5"))
    timeout !== nothing && isfinite(timeout) && 0 < timeout <= 30 ||
        throw(ArgumentError("--timeout must be greater than zero and at most 30 seconds"))
    workers = tryparse(Int, get(values, "--workers", "4"))
    capacity = tryparse(Int, get(values, "--capacity", "16"))
    workers !== nothing && capacity !== nothing && 1 <= workers <= capacity <= 16 ||
        throw(ArgumentError("require 1 <= workers <= capacity <= 16"))
    server = LibTmux.Server(
        socket_path=get(values, "--socket", nothing),
        socket_name=get(values, "--socket-name", nothing),
        tmux=get(values, "--tmux", "tmux"),
    )
    (;
        help=false,
        server,
        caller,
        pane_ids,
        allowed_tools=isempty(tool_names) ? _ROUTINE_TOOLS : Tuple(tool_names),
        allow_create,
        timeout,
        workers,
        capacity,
    )
end

function _cli_application(options)
    captured = LibTmux.snapshot(options.server; timeout=options.timeout)
    function resolve(id)
        matches = filter(pane -> string(pane.ref.id) == id, LibTmux.panes(captured))
        length(matches) == 1 || throw(ArgumentError("configured pane $id does not exist"))
        only(matches).ref
    end
    caller = options.caller === nothing ? nothing : resolve(options.caller)
    allowed_panes = isempty(options.pane_ids) ? nothing : resolve.(options.pane_ids)
    Application(
        options.server;
        caller,
        allowed_panes,
        options.allowed_tools,
        options.allow_create,
        options.timeout,
    )
end

"""
    serve(app; input=stdin, output=stdout, workers=4, capacity=16, logger=...)

Serve the application's tools using the admitted MCP stdio profiles. This call
owns and closes both streams and `app`, including after EOF, cancellation or
failure. It joins request work before cleaning up application-owned sessions.
Protocol output is serialized; tool logs use the supplied task-local logger.
The borrowed tmux daemon and pre-existing sessions remain caller-owned.
"""
function serve(
    app::Application;
    input::IO=stdin,
    output::IO=stdout,
    workers::Int=4,
    capacity::Int=16,
    logger::AbstractLogger=SimpleLogger(stderr, Logging.Warn),
)
    primary = nothing
    result = nothing
    transport = _StdioTransport(input, output)
    try
        result = _serve_transport(transport, tools(app); workers, capacity, logger)
    catch error
        primary = error
    end
    errors = Exception[]
    primary === nothing || push!(errors, primary)
    for cleanup in (() -> SDK.close(transport), () -> close(app))
        try
            cleanup()
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) ||
        throw(length(errors) == 1 ? only(errors) : CompositeException(errors))
    result
end

"""
    main(arguments=ARGS; input=stdin, output=stdout, err=stderr) -> Int

Run `libtmux-mcp` with an explicit socket selector. Startup captures exact
caller/allowed pane references. `--help` and invalid options perform no tmux
I/O. Returns 0 after clean EOF, 2 for option errors, 130 for interruption and
1 for startup, protocol or cleanup failure. Only `--help` writes human text
to stdout; serving reserves it for MCP messages.
"""
function main(arguments=ARGS; input::IO=stdin, output::IO=stdout, err::IO=stderr)
    options = try
        _cli_options(arguments)
    catch error
        error isa ArgumentError || rethrow()
        println(err, "libtmux-mcp: ", sprint(showerror, error), "; use --help")
        return 2
    end
    if options.help
        print(output, _CLI_HELP)
        return 0
    end
    try
        app = _cli_application(options)
        serve(
            app;
            input,
            output,
            options.workers,
            options.capacity,
            logger=SimpleLogger(err, Logging.Warn),
        )
        0
    catch error
        println(err, "libtmux-mcp: ", sprint(showerror, error))
        error isa InterruptException ? 130 : 1
    end
end

_launcher_word(word::AbstractString) = "'" * replace(word, "'" => "'\\''") * "'"

"""
    install_cli(directory; project=Base.active_project(), julia=..., julia_flags=[], force=false)

Install a POSIX `libtmux-mcp` launcher bound to an already-resolved Julia
consumer project. No package resolution occurs. An existing destination is
preserved unless `force=true`. Arguments are shell-quoted individually;
`julia_flags` sets explicit Julia runtime options.
"""
function install_cli(
    directory::AbstractString;
    project=Base.active_project(),
    julia::AbstractString=joinpath(Sys.BINDIR, Base.julia_exename()),
    julia_flags::AbstractVector{<:AbstractString}=String[],
    force::Bool=false,
)
    Sys.isunix() || throw(ArgumentError("the MCP launcher currently requires POSIX"))
    project === nothing &&
        throw(ArgumentError("activate a resolved consumer project first"))
    project_path = abspath(project)
    project_directory = isfile(project_path) ? dirname(project_path) : project_path
    isfile(joinpath(project_directory, "Project.toml")) ||
        throw(ArgumentError("project has no Project.toml"))
    words = [
        julia,
        "--startup-file=no",
        "--project=" * project_directory,
        julia_flags...,
        "-e",
        "Base.exit_on_sigint(false); using LibTmuxMCP; exit(LibTmuxMCP.main())",
        "--",
    ]
    all(word -> isvalid(word) && !occursin('\0', word), words) ||
        throw(ArgumentError("launcher arguments must be UTF-8 without NUL"))
    destination = joinpath(abspath(directory), "libtmux-mcp")
    (ispath(destination) || islink(destination)) &&
        !force &&
        throw(
            ArgumentError(
                "launcher already exists; choose another directory or force=true",
            ),
        )
    mkpath(dirname(destination))
    temporary, io = mktemp(dirname(destination))
    try
        println(io, "#!/bin/sh\nexec ", join(_launcher_word.(words), " "), " \"\$@\"")
        close(io)
        chmod(temporary, 0o755)
        if force
            mv(temporary, destination; force=true)
        else
            hardlink(temporary, destination)
        end
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    destination
end
