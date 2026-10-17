# Support: which tmux releases libtmux supports. This file is the version check
# (`support.versions`): it reads the daemon's version, refuses releases below
# the floor before any effect, and fences each command against a replaced
# daemon. "Support" means tmux version support, not helper code.

using UUIDs: uuid4

# The oldest tmux release that ordinary operations support. Releases compare
# with their patch letters, so 3.3 is below 3.3a.
const MINIMUM_TMUX_VERSION = "3.3a"

"""
    UnsupportedTmuxVersion(observed, minimum, detail)

Raised when the selected tmux daemon, or the executable that would start one,
reports a release below `MINIMUM_TMUX_VERSION`, when no release can be
read, or when the daemon changed after the version check. The refused command
had no effect. `observed` is the reported release, empty when none was established;
`detail` explains refusals that a release number cannot.
"""
struct UnsupportedTmuxVersion <: LibTmuxError
    observed::String
    minimum::String
    detail::String
end
UnsupportedTmuxVersion(observed::AbstractString, detail::AbstractString="") =
    UnsupportedTmuxVersion(String(observed), MINIMUM_TMUX_VERSION, String(detail))

function Base.showerror(io::IO, e::UnsupportedTmuxVersion)
    print(io, "tmux ")
    isempty(e.observed) ? print(io, "version") : print(io, repr(e.observed))
    unrecognized = !isempty(e.observed) && _release_key(e.observed) === nothing
    print(io, unrecognized ? " is not a recognized release" : " is unsupported")
    print(io, "; libtmux requires tmux ", e.minimum, " or newer")
    isempty(e.detail) || print(io, ": ", e.detail)
    print(io, ". Upgrade tmux and restart the server, or pin the previous libtmux release.")
end

# The spellings tmux has reported: `X.Y` with an optional patch letter,
# `X.Y-rc` and `X.Y-rcN`, development builds `next-X.Y`, and no others.
const _RELEASE_PATTERN =
    r"\A(?:(next-)([0-9]+)\.([0-9]+)|([0-9]+)\.([0-9]+)(?:([a-z])|-rc([0-9]*))?)\z"

# Order releases by number, patch letter, then maturity: `next-X.Y` precedes
# `X.Y-rc`, which precedes `X.Y-rcN`, which precedes `X.Y`, which precedes
# `X.Ya`. A bare `master`, an OpenBSD report or any other spelling has no rank
# and is never supported.
function _release_key(version::AbstractString)
    parsed = match(_RELEASE_PATTERN, version)
    parsed === nothing && return nothing
    # A digit run too long for an Int is no release tmux reports.
    number(text) = isempty(text) ? 0 : tryparse(Int, text)
    if parsed[1] !== nothing
        major, minor = number(parsed[2]), number(parsed[3])
        return nothing in (major, minor) ? nothing : (major, minor, "", 0, 0)
    end
    major, minor = number(parsed[4]), number(parsed[5])
    nothing in (major, minor) && return nothing
    parsed[6] !== nothing && return (major, minor, String(parsed[6]), 2, 0)
    parsed[7] === nothing && return (major, minor, "", 2, 0)
    candidate = number(parsed[7])
    candidate === nothing ? nothing : (major, minor, "", 1, candidate)
end

function _version_at_least(version::AbstractString, minimum::AbstractString)
    current, floor = _release_key(version), _release_key(minimum)
    floor === nothing && throw(ArgumentError("invalid minimum tmux version"))
    current !== nothing && current >= floor
end

function _require_supported(version::AbstractString)
    _version_at_least(version, MINIMUM_TMUX_VERSION) ||
        throw(UnsupportedTmuxVersion(version))
    nothing
end

_selector(server::Server) =
    server.socket_path === nothing ? ["-L", something(server.socket_name)] :
    ["-S", server.socket_path]

_version_marker() = "libtmux-version-" * replace(string(uuid4()), "-" => "")

_stderr_lines(result::CommandResult) =
    [rstrip(line, '\r') for line in split(decode_text(result.stderr; invalid=:replace), '\n')]

# A refusal, or a failed probe, happens before the command is sent.
_not_dispatched(error) =
    error isa UnsupportedTmuxVersion ||
    error isa CommandError && error.command == "version probe"

# A probe has no effect on the daemon, so interrupting it was never "sent".
function _version_process(argv, env; cancel, timeout, started)
    try
        _run_process(
            setenv(Cmd(argv), env);
            cancel,
            timeout,
            _started=started,
            max_output_bytes=4096,
            max_error_bytes=64 * 1024,
        )
    catch error
        error isa DeadlineExceeded && throw(DeadlineExceeded(error.timeout, false, nothing))
        error isa RequestCancelled && throw(RequestCancelled(false))
        rethrow()
    end
end

# What tmux 3.1 and older print for the probe: usage of `run-shell` without
# `-C`, an unknown `-N` option, or a client/server protocol mismatch.
_pre_probe_diagnostic(line) =
    startswith(line, "usage: run-shell") ||
    startswith(line, "tmux: unknown option") ||
    occursin("server version is too old for client", line)

function _endpoint_absent(stderr::AbstractString)
    occursin("no server running", stderr) ||
        occursin("error connecting to", stderr) &&
        (occursin("No such file or directory", stderr) || occursin("Connection refused", stderr))
end

"""
Report the selected daemon's release, or `nothing` for an absent endpoint.

`run-shell -C` has no after-hook, and tmux parses its expanded argument only
after the command returned, so the version arrives as an unknown-command error
without firing `after-*` or `command-error` hooks. `-N` keeps a client from
starting a daemon.
"""
function _daemon_version(server::Server, env; cancel=nothing, timeout=nothing, started=time_ns())
    marker = _version_marker()
    argv = String[server.tmux, "-u"]
    append!(argv, _selector(server))
    append!(argv, ["-N", "--", "run-shell", "-C", marker * "#{version}"])
    # Absence is recognized by tmux's English diagnostics.
    result = _version_process(
        argv,
        merge(env, Dict("LC_ALL" => "C")); cancel, timeout, started,
    )
    prefix = "unknown command: " * marker
    if result.exitcode == 1 && result.termsignal == 0
        for line in _stderr_lines(result)
            startswith(line, prefix) && return String(line[(ncodeunits(prefix) + 1):end])
        end
        _endpoint_absent(decode_text(result.stderr; invalid=:replace)) && return nothing
    end
    # tmux 3.1 and older have no `run-shell -C`, and a client older than 3.2 has
    # no `-N`; a 3.0 daemon answers a newer client with a protocol mismatch. All
    # three put the release below the floor rather than leave it unreadable.
    result.exitcode != 0 &&
        any(_pre_probe_diagnostic, _stderr_lines(result)) &&
        throw(
            UnsupportedTmuxVersion(
                "",
                "the tmux in use is older than 3.2, which has no hook-free version query",
            ),
        )
    throw(CommandError(result, "version probe"))
end

# Standalone `-V` is a diagnostic for a daemon that does not exist yet. Release
# 3.3a prints the executable's basename in place of `tmux`.
function _executable_version(server::Server, env; cancel=nothing, timeout=nothing, started=time_ns())
    result = _version_process([server.tmux, "-V"], env; cancel, timeout, started)
    text = String(copy(result.stdout))
    name = basename(server.tmux) * " "
    prefix = startswith(text, name) ? name : startswith(text, "tmux ") ? "tmux " : nothing
    result.exitcode == 0 && result.termsignal == 0 && prefix !== nothing ||
        throw(UnsupportedTmuxVersion("", "the executable did not report a release"))
    String(strip(text[(ncodeunits(prefix) + 1):end]))
end

"""
Check the version of the selected daemon, or of the executable that would create
it. Return the release and whether the endpoint is live. With `cleanup`, an absent
endpoint needs no executable and returns a `nothing` release.
"""
function _check_version(server::Server, env; cleanup::Bool=false, kwargs...)
    version = _daemon_version(server, env; kwargs...)
    if version !== nothing
        _require_supported(version)
        return (; version, live=true)
    end
    cleanup && return (; version=nothing, live=false)
    version = _executable_version(server, env; kwargs...)
    _require_supported(version)
    (; version, live=false)
end

# Run `args` behind a fence on the checked release. If another daemon answers
# the endpoint, the format is false, tmux fails on the marker as an unknown
# command and nothing after the fence runs.
function _fenced_argv(server::Server, args, checked, marker)
    argv = String[server.tmux, "-u"]
    checked.live && push!(argv, "-N")
    append!(argv, _selector(server))
    append!(
        argv,
        ["--", "if-shell", "-F", "#{==:#{version}," * checked.version * "}", "", marker, ";"],
    )
    append!(argv, _argument.(args))
end

function _check_fence(result::CommandResult, marker)
    needle = "unknown command: " * marker
    any(==(needle), _stderr_lines(result)) && throw(
        UnsupportedTmuxVersion(
            "",
            "the daemon changed after the version check; the command did not run",
        ),
    )
    nothing
end

# Check the version of a live daemon for a client that never starts one. An
# absent endpoint is left to the caller's own failure.
function _check_daemon(server::Server, env; kwargs...)
    version = _daemon_version(server, env; kwargs...)
    version === nothing || _require_supported(version)
    version
end
