include("cli_output.jl")

const _CLI_HELP = """
Usage: libtmux-workspace <validate|plan|load|freeze> <file-or-session> [options]

validate FILE      Check YAML/JSON syntax and the supported schema.
plan FILE          Expand supplied values and print an inert plan.
load FILE          Apply detached; existing session names fail by default.
freeze SESSION     Capture names, indices, paths, layout and focus.

--socket PATH | --socket-name NAME   Required for load/freeze.
--tmux EXECUTABLE                    Default: tmux.
--output human|json|ndjson           Default: human.
--env NAME=VALUE                     Explicit expansion value; repeatable.
--home PATH                         Explicit tilde expansion home.
--base-directory PATH               Override config-relative expansion base.
--timeout SECONDS                   One load/freeze deadline; default: 30.
--reuse                             Explicitly reuse the named session.
--rollback-created                  Clean up only created resources on failure.
--no-readiness                      Skip the POSIX shell handshake explicitly.
--attach                            Attach after load; requires terminal stdio.
--help                              Print this help.

Exit codes: 0 success; 2 input/usage; 3 backend/output failure; 4 partial application;
5 cancellation; 6 deadline. JSON uses one final stdout value. NDJSON streams
ordered progress and one terminal result/error. Human diagnostics use stderr.
"""

function _jsonable(value)
    Base.@nospecialize value
    value isa Symbol && return string(value)
    value isa Union{Nothing,AbstractString,Number,Bool} && return value
    value isa AbstractVector{UInt8} &&
        return Dict("encoding" => "base64", "data" => base64encode(value))
    value isa AbstractDict && return Dict(string(k) => _jsonable(v) for (k, v) in value)
    if value isa NamedTuple
        result = Dict{String,Any}()
        for key in keys(value)
            item = getfield(value, key)
            result[string(key)] = key == :environment ? Dict(item) : _jsonable(item)
        end
        return result
    end
    value isa Pair && return Dict(string(first(value)) => _jsonable(last(value)))
    if value isa Union{Tuple,AbstractVector}
        result = Any[]
        sizehint!(result, length(value))
        for index in eachindex(value)
            push!(result, _jsonable(value[index]))
        end
        return result
    end
    if value isa Union{LibTmux.SessionRef,LibTmux.WindowRef,LibTmux.PaneRef}
        kind =
            value isa LibTmux.SessionRef ? "session" :
            value isa LibTmux.WindowRef ? "window" : "pane"
        return Dict(
            "kind" => kind,
            "id" => string(value.id),
            "socket" => value.server.socket_path,
            "generation" => value.server.generation,
        )
    elseif value isa WorkspacePlan
        return Dict(
            "schema_version" => 1,
            "session_name" => value.workspace.session_name,
            "steps" => _jsonable(value.steps),
        )
    elseif value isa PlanStep
        return _jsonable((
            action=value.action,
            window=value.window,
            pane=value.pane,
            arguments=value.arguments,
        ))
    elseif value isa WorkspaceApplyResult
        return _jsonable((
            status=value.status,
            session=value.session,
            created=value.created,
            borrowed=value.borrowed,
            completed=value.completed,
            unknown_effects=value.unknown_effects,
            removed=value.removed,
            rollback=value.rollback,
        ))
    elseif value isa WorkspaceDocument
        return value.data
    end
    throw(ArgumentError("unsupported CLI output value"))
end

function _cli_options(arguments)
    isempty(arguments) && throw(ArgumentError("supply a command; see --help"))
    command = String(first(arguments))
    command in ("validate", "plan", "load", "freeze") ||
        throw(ArgumentError("unknown workspace command"))
    values = Dict{String,String}()
    flags, positional, variables = Set{String}(), String[], Dict{String,String}()
    names = Set((
        "--socket",
        "--socket-name",
        "--tmux",
        "--output",
        "--env",
        "--home",
        "--base-directory",
        "--timeout",
    ))
    booleans = Set(("--reuse", "--rollback-created", "--no-readiness", "--attach"))
    index, options = 2, true
    while index <= length(arguments)
        item = String(arguments[index])
        if options && item == "--"
            options = false
        elseif options && item in names
            index += 1
            index <= length(arguments) || throw(ArgumentError("missing value after $item"))
            value = String(arguments[index])
            if item == "--env"
                pair = split(value, '='; limit=2)
                length(pair) == 2 && occursin(r"\A[A-Za-z_][A-Za-z0-9_]*\z", pair[1]) ||
                    throw(ArgumentError("--env expects NAME=VALUE"))
                haskey(variables, pair[1]) && throw(ArgumentError("duplicate --env name"))
                variables[pair[1]] = pair[2]
            else
                haskey(values, item) && throw(ArgumentError("duplicate option $item"))
                values[item] = value
            end
        elseif options && item in booleans
            item in flags && throw(ArgumentError("duplicate option $item"))
            push!(flags, item)
        elseif options && startswith(item, '-')
            throw(ArgumentError("unknown option $item"))
        else
            push!(positional, item)
        end
        index += 1
    end
    length(positional) == 1 || throw(ArgumentError("supply exactly one file or session"))
    output = get(values, "--output", "human")
    output in ("human", "json", "ndjson") || throw(ArgumentError("invalid --output mode"))
    if command in ("load", "freeze")
        haskey(values, "--socket") != haskey(values, "--socket-name") ||
            throw(ArgumentError("supply exactly one --socket or --socket-name"))
    elseif any(haskey(values, k) for k in ("--socket", "--socket-name", "--tmux")) ||
           !isempty(flags)
        throw(ArgumentError("server and load options are not valid for this pure command"))
    end
    command == "load" ||
        isempty(flags) ||
        throw(ArgumentError("load flags require the load command"))
    (; command, input=only(positional), values, flags, variables, output)
end

function _cli_exit(error)
    error isa WorkspaceConfigError && return 2
    error isa ArgumentError && return 2
    cause = error isa WorkspaceApplyError ? error.cause : error
    cause isa InterruptException && return 5
    cause isa LibTmux.RequestCancelled && return 5
    cause isa LibTmux.DeadlineExceeded && return 6
    cause isa BeforeScriptError && cause.code == :cancelled && return 5
    cause isa BeforeScriptError && cause.code == :deadline && return 6
    error isa WorkspaceApplyError && error.result.status == :partial && return 4
    3
end

mutable struct _CLIOutput
    out::IO
    err::IO
    mode::String
    serial::Int
    lock::ReentrantLock
    owner::Union{Nothing,_CLIOwnedOutput}
end
_CLIOutput(out, err, mode, owner=nothing) =
    _CLIOutput(out, err, mode, 0, ReentrantLock(), owner)

function _cli_emit(writer::_CLIOutput, destination, text)
    if writer.owner === nothing
        stream = destination === :out ? writer.out : writer.err
        write(stream, text)
        flush(stream)
    else
        _cli_output_enqueue(writer.owner, destination, text)
    end
    nothing
end

function _cli_record(writer::_CLIOutput, event, data)
    Base.@nospecialize data
    lock(writer.lock) do
        value = Dict{String,Any}(_jsonable(data))
        value["event"] = string(event)
        value["sequence"] = writer.serial + 1
        encoded = JSON.json(value)
        _cli_emit(writer, :out, encoded * "\n")
        writer.serial += 1
    end
end

function _cli_report_error(writer::_CLIOutput, error)
    Base.@nospecialize error
    code = _cli_exit(error)
    message = sprint(showerror, error)
    _cli_emit(writer, :err, message * "\n")
    payload = Dict{String,Any}(
        "status" => "error",
        "exit_code" => code,
        "error" => Dict(
            "code" =>
                error isa WorkspaceConfigError ? string(error.code) :
                string(nameof(typeof(error))),
            "message" => message,
        ),
    )
    error isa WorkspaceApplyError && (payload["result"] = _jsonable(error.result))
    if writer.mode == "json"
        _cli_emit(writer, :out, JSON.json(payload) * "\n")
    elseif writer.mode == "ndjson"
        _cli_record(writer, :error, payload)
    end
    code
end

function _attach_cli(server, target)
    argv = [
        server.tmux,
        "-u",
        "-N",
        "-S",
        target.server.socket_path,
        "-f",
        "/dev/null",
        "--",
        "attach-session",
        "-t",
        string(target.id),
    ]
    environment = Dict(k => v for (k, v) in ENV if !(k in ("TMUX", "TMUX_PANE")))
    result = try
        run(setenv(ignorestatus(Cmd(argv)), environment))
    catch error
        error
    end
    result isa Exception &&
        throw(ErrorException("could not start the explicit attach client"))
    success(result) || throw(ErrorException("attach client exited unsuccessfully"))
    nothing
end

"""
    main(args=ARGS; out=stdout, err=stderr) -> Int

Run the installed CLI protocol. Pure commands need no server. `load` and `freeze`
require one explicit socket selector; there is no default-server fallback.
Only `--attach` opens an interactive client. Return a documented exit code.
The supplied streams remain borrowed and open; their writes must return promptly.
The installed launcher separately owns bounded, cancellable stdout/stderr writes.
"""
main(arguments=ARGS; out::IO=stdout, err::IO=stderr) = _main(arguments; out, err)

function _main(arguments; out::IO, err::IO, owner=nothing)
    output = "human"
    for i = 1:max(0, length(arguments)-1)
        arguments[i] == "--output" &&
            arguments[i+1] in ("human", "json", "ndjson") &&
            (output = arguments[i+1])
    end
    writer = _CLIOutput(out, err, output, owner)
    cancel = owner === nothing ? nothing : owner.cancel
    record(event, data) = _cli_record(writer, event, data)
    try
        if arguments == ["--help"] || arguments == ["-h"]
            _cli_emit(writer, :out, _CLI_HELP)
            return 0
        end
        options = _cli_options(arguments)
        output = options.output
        command, values, flags = options.command, options.values, options.flags
        attached = "--attach" in flags
        attached &&
            output != "human" &&
            throw(ArgumentError("--attach requires human output"))
        attached &&
            !(stdin isa Base.TTY && stdout isa Base.TTY) &&
            throw(ArgumentError("--attach requires terminal stdin and stdout"))
        budget = parse(Float64, get(values, "--timeout", "30"))
        isfinite(budget) && 0 < budget < 1e15 || throw(ArgumentError("invalid --timeout"))
        server =
            command in ("load", "freeze") ?
            LibTmux.Server(
                socket_path=get(values, "--socket", nothing),
                socket_name=get(values, "--socket-name", nothing),
                tmux=get(values, "--tmux", "tmux"),
            ) : nothing
        payload = if command == "freeze"
            started = time_ns()
            snap = LibTmux.snapshot(server; timeout=budget, cancel)
            target =
                only(filter(s -> s.name == options.input, LibTmux.sessions(snap))).ref
            document = freeze(
                server,
                target;
                timeout=_remaining(started, budget, cancel),
                cancel,
            )
            Dict("status" => "frozen", "workspace" => document.data)
        else
            config = validate(read_config(options.input))
            if command == "validate"
                Dict(
                    "status" => "valid",
                    "schema_version" => 1,
                    "session_name" => config.session_name,
                )
            else
                prepared = plan(
                    expand(
                        config;
                        env=options.variables,
                        home=get(values, "--home", nothing),
                        base_directory=get(values, "--base-directory", nothing),
                    ),
                )
                if command == "plan"
                    Dict("status" => "planned", "plan" => _jsonable(prepared))
                else
                    started = time_ns()
                    reuse = if "--reuse" in flags
                        snap = LibTmux.snapshot(server; timeout=budget, cancel)
                        only(
                            filter(
                                s -> s.name == prepared.workspace.session_name,
                                LibTmux.sessions(snap),
                            ),
                        ).ref
                    else
                        nothing
                    end
                    function progress(event)
                        if output == "ndjson"
                            record(:progress, Dict("progress" => _jsonable(event)))
                        elseif output == "human"
                            if event.event == :step_started
                                _cli_emit(
                                    writer,
                                    :err,
                                    string("step ", event.step, ": ", event.action, "\n"),
                                )
                            elseif event.event == :script_output
                                _cli_emit(
                                    writer,
                                    :err,
                                    LibTmux.decode_text(event.bytes; invalid=:replace),
                                )
                            end
                        end
                    end
                    result = apply(
                        server,
                        prepared;
                        timeout=_remaining(started, budget, cancel),
                        cancel,
                        reuse,
                        rollback="--rollback-created" in flags ? :created : :none,
                        readiness="--no-readiness" in flags ? :none : :posix_shell,
                        on_event=progress,
                    )
                    if attached
                        try
                            _attach_cli(server, result.session)
                        catch error
                            throw(WorkspaceApplyError(result, error))
                        end
                    end
                    Dict("status" => "loaded", "result" => _jsonable(result))
                end
            end
        end
        if output == "human"
            if command == "freeze"
                encoded = IOBuffer()
                YAML.write(encoded, payload["workspace"])
                _cli_emit(writer, :out, String(take!(encoded)))
            elseif command == "plan"
                for step in payload["plan"]["steps"]
                    _cli_emit(writer, :out, JSON.json(step) * "\n")
                end
            else
                _cli_emit(writer, :out, payload["status"] * "\n")
            end
        elseif output == "json"
            _cli_emit(writer, :out, JSON.json(payload) * "\n")
        else
            record(:result, payload)
        end
        return 0
    catch error
        owner === nothing ||
            lock(() -> owner.failure === nothing, owner.changed) ||
            return 3
        return _cli_report_error(writer, error)
    end
end

function _main_owned(arguments=ARGS; out::IO=stdout, err::IO=stderr)
    owner = _CLIOwnedOutput(out, err)
    signals = nothing
    code = 3
    try
        signals = _CLISignalWatcher(owner.cancel)
        code = _main(arguments; out, err, owner)
    catch error
        _cli_output_abort(owner, error)
    finally
        try
            close(owner)
        catch
            code = 3
        end
        try
            signals === nothing || close(signals)
        catch
            code = 3
        end
    end
    code
end

"""
    install_cli(directory; project=Base.active_project(), julia=..., julia_flags=[], force=false)

Install a POSIX `libtmux-workspace` launcher bound to an already-resolved Julia
project. Installation performs no package resolution. Existing files are
preserved unless `force=true`; the caller chooses the installation directory.
`julia_flags` permits explicit runtime choices such as minimal compilation.
"""
function install_cli(
    directory::AbstractString;
    project=Base.active_project(),
    julia::AbstractString=joinpath(Sys.BINDIR, Base.julia_exename()),
    julia_flags::AbstractVector{<:AbstractString}=String[],
    force::Bool=false,
)
    Sys.isunix() || throw(ArgumentError("the workspace launcher currently requires POSIX"))
    project === nothing &&
        throw(ArgumentError("activate a resolved consumer project first"))
    project_path = abspath(project)
    project_directory = isfile(project_path) ? dirname(project_path) : project_path
    isfile(joinpath(project_directory, "Project.toml")) ||
        throw(ArgumentError("project has no Project.toml"))
    destination = joinpath(abspath(directory), "libtmux-workspace")
    ispath(destination) &&
        !force &&
        throw(
            ArgumentError(
                "launcher already exists; choose another directory or force=true",
            ),
        )
    mkpath(dirname(destination))
    temporary, io = mktemp(dirname(destination))
    try
        words = [
            julia,
            "--startup-file=no",
            "--project=" * project_directory,
            julia_flags...,
            "-e",
            "Base.exit_on_sigint(false); using LibTmuxWorkspace; exit(LibTmuxWorkspace._main_owned())",
            "--",
        ]
        println(io, "#!/bin/sh\nexec ", join(_shell_word.(words), " "), " \"\$@\"")
        close(io)
        chmod(temporary, 0o755)
        if force
            mv(temporary, destination; force=true)
        else
            # Hard-link publication refuses a raced destination atomically.
            hardlink(temporary, destination)
        end
    finally
        isopen(io) && close(io)
        ispath(temporary) && rm(temporary)
    end
    destination
end
