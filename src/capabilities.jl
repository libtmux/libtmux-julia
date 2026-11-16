"""
    CapabilityCommand

Native tmux `command` and immutable `flags` associated with a capability.
"""
struct CapabilityCommand
    command::String
    flags::Tuple{Vararg{String}}
end

"""
    CapabilityStatus

One library feature and its `supported` decision for the observed release.
`id` is the stable lookup name; `name` and `summary` describe the feature.
`since` and `except` state its release requirements. `handling` and `error`
describe the library's response when unavailable. `apis` and `commands`
identify its Julia and native entry points. All collections are immutable.
"""
struct CapabilityStatus
    id::String
    name::String
    summary::String
    since::String
    except::Tuple{Vararg{String}}
    handling::Symbol
    error::Union{Nothing,String}
    apis::Tuple{Vararg{String}}
    commands::Tuple{Vararg{CapabilityCommand}}
    supported::Bool
end

"""
    WorkaroundStatus

A release-specific library workaround and its `active` decision. `id`,
`name` and `summary` identify it; `releases` lists affected releases, including
their prerelease builds at the same patch level. `handling` describes the
library response. `apis` and `commands` locate affected operations. Collections
are immutable.
"""
struct WorkaroundStatus
    id::String
    name::String
    summary::String
    releases::Tuple{Vararg{String}}
    handling::Symbol
    apis::Tuple{Vararg{String}}
    commands::Tuple{Vararg{CapabilityCommand}}
    active::Bool
end

"""
    CapabilityReport

Immutable feature and workaround decisions for an observed tmux daemon.
`generation` is its `pid:start_time` identity and `version` is its release.
`features` and `workarounds` retain detached metadata from the library registry.
The report is historical: it grants no operation permission, renews no entity
reference and does not guarantee a future daemon will be the same.

Obtain a report with [`capabilities`](@ref), then inspect it with
[`supports`](@ref), [`capability`](@ref) or [`workaround`](@ref).
"""
struct CapabilityReport
    generation::String
    version::String
    features::Tuple{Vararg{CapabilityStatus}}
    workarounds::Tuple{Vararg{WorkaroundStatus}}
end

_capability_commands(commands) =
    Tuple(CapabilityCommand(c.command, Tuple(c.flags)) for c in commands)

function _capability_report(generation, version)
    _require_supported(version)
    features = Tuple(
        CapabilityStatus(
            c.id,
            c.name,
            c.summary,
            c.since,
            Tuple(c.except),
            c.handling,
            c.error,
            Tuple(c.apis),
            _capability_commands(c.commands),
            _version_at_least(version, c.since) && !_in_releases(version, c.except),
        ) for c in _CAPABILITIES
    )
    workarounds = Tuple(
        WorkaroundStatus(
            w.id,
            w.name,
            w.summary,
            Tuple(w.releases),
            w.handling,
            Tuple(w.apis),
            _capability_commands(w.commands),
            _in_releases(version, w.releases),
        ) for w in _WORKAROUNDS
    )
    CapabilityReport(String(generation), String(version), features, workarounds)
end

"""
    capability(report::CapabilityReport, id::AbstractString)

Return the [`CapabilityStatus`](@ref) with stable `id`, or throw `KeyError`
for an unknown id. This reads the report without I/O.
"""
function capability(report::CapabilityReport, id::AbstractString)
    for entry in report.features
        entry.id == id && return entry
    end
    throw(KeyError(id))
end

"""
    supports(report::CapabilityReport, id::AbstractString)

Return whether the observed release supports feature `id`. An unknown id
throws `KeyError`; it is not a negative capability decision. No I/O occurs.
"""
supports(report::CapabilityReport, id::AbstractString) = capability(report, id).supported

"""
    workaround(report::CapabilityReport, id::AbstractString)

Return the [`WorkaroundStatus`](@ref) with stable `id`, or throw `KeyError`
for an unknown id. Inspect `.active` to check the observed release. No I/O occurs.
"""
function workaround(report::CapabilityReport, id::AbstractString)
    for entry in report.workarounds
        entry.id == id && return entry
    end
    throw(KeyError(id))
end

function _capability_probe_report(result, marker)
    result.exitcode == 1 && result.termsignal == 0 && isempty(result.stdout) ||
        throw(CommandError(result, "capabilities"))
    pattern = Regex(
        "\\Aunknown command: " * marker * "([1-9][0-9]*),([1-9][0-9]*),([^\\r\\n]+)\\n\\z",
    )
    text = String(copy(result.stderr))
    isvalid(text) || throw(CommandError(result, "capabilities"))
    parsed = match(pattern, text)
    parsed !== nothing &&
    tryparse(Int, parsed[1]) !== nothing &&
    tryparse(Int, parsed[2]) !== nothing || throw(CommandError(result, "capabilities"))
    _capability_report(parsed[1] * ":" * parsed[2], parsed[3])
end

"""
    capabilities(server::Server; timeout::Real=5.0, cancel=nothing)

Query the responding daemon and return its [`CapabilityReport`](@ref).
This read starts no daemon, runs no user hooks and changes no version cache.
`Server` is an endpoint: replacement daemons are observed on subsequent calls.
The result does not weaken the generation and release checks on operations.

`timeout` bounds the query in seconds and must be positive and finite.
`cancel` accepts a [`CancellationToken`](@ref). Both interrupt and join the
owned client before returning. An absent daemon or malformed reply raises
[`CommandError`](@ref); an unsupported release raises
[`UnsupportedTmuxVersion`](@ref). Cancellation and deadline errors retain the
existing process engine's semantics. The client executable's version is never
substituted for daemon evidence.
"""
function capabilities(server::Server; timeout::Real=5.0, cancel=nothing)
    context = _operation_context(server; timeout, cancel)
    marker = "libtmux-capabilities-" * replace(string(uuid4()), "-" => "") * "-"
    argv = String[server.tmux, "-u"]
    append!(argv, _selector(server))
    append!(
        argv,
        ["-N", "--", "run-shell", "-C", marker * "#{pid},#{start_time},#{version}"],
    )
    environment = merge(_client_environment(ENV, server), Dict("LC_ALL" => "C"))
    result = _version_process(
        argv,
        environment;
        cancel,
        timeout=context.budget,
        started=context.started,
    )
    _capability_probe_report(result, marker)
end

"""
    capabilities(connection::ControlConnection; timeout::Real=5.0, cancel=nothing)

Validate the original connection's daemon generation and release, then return
its [`CapabilityReport`](@ref). Uses the existing control client without a
subprocess fallback or shared version cache. Endpoint changes cannot rebind
the connection. This read runs no user hooks and grants no mutation authority.

`timeout` is a positive finite request budget in seconds; `cancel` accepts a
[`CancellationToken`](@ref). Cancellation follows the connection's request
retirement rules. A closed connection raises [`ControlConnectionError`](@ref).
Failed or unexpected native evidence raises [`ControlCommandError`](@ref).
"""
function capabilities(connection::ControlConnection; timeout::Real=5.0, cancel=nothing)
    context = _control_operation_context(connection; timeout, cancel)
    version = _control_release(connection)
    version === nothing &&
        throw(UnsupportedTmuxVersion("", "connection release is unknown"))
    _require_supported(version)
    pid, started = split(connection.identity.generation, ':'; limit=2)
    predicate = "#{&&:#{==:#{pid},$pid},#{&&:#{==:#{start_time},$started},#{==:#{version},$version}}}"
    result = _control_request(
        connection,
        ["if-shell", "-F", predicate, "", _version_marker()],
        _ControlReplyPolicy(; diagnostics=true);
        timeout=_snapshot_remaining(context.started, context.budget),
        cancel,
    )
    !result.failed && isempty(result.stdout) ||
        throw(ControlCommandError(result, "capabilities"))
    _capability_report(connection.identity.generation, version)
end
