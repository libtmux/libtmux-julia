# Per-operation tmux release requirements above the 3.3a floor. A requirement
# never raises the minimum for the rest of the library.

const CONTROL_MINIMUM_TMUX = "3.7"
const BUFFER_DELETE_MINIMUM_TMUX = "3.4"

function _require_release(version, minimum, operation, what)
    version === nothing && return nothing
    _version_at_least(version, minimum) || throw(
        UnsupportedCapability(
            operation,
            "$what requires tmux $minimum or newer; the daemon reports $(repr(version))",
        ),
    )
    nothing
end

# Reuse the release an operation already checked, or read it hook-free.
_checked_release(context) =
    context.checked[] === nothing ? _context_release(context) : context.checked[].version

# Exact-name buffer deletion can act on an unrelated buffer before 3.4, so the
# operations that depend on it are refused before any buffer exists.
function _require_buffer_release(context, operation)
    _require_release(
        _checked_release(context),
        BUFFER_DELETE_MINIMUM_TMUX,
        operation,
        "named-buffer deletion",
    )
end

# tmux 3.7 rejects ':' and '.' in session and window names.
# 3.7a restored them. Pre-release builds of 3.7 rank below it but carry the
# restriction, so the guard covers every 3.7 build without a patch letter.
function _names_restricted(version)
    key = _release_key(version)
    key !== nothing && key[1:3] == (3, 7, "")
end

function _check_name_release(version, name, operation)
    _names_restricted(version) &&
        occursin(r"[:.]", name) &&
        throw(
            ArgumentError(
                "$operation: tmux 3.7 rejects ':' and '.' in session and window names; use another name or a different release",
            ),
        )
    nothing
end

function _check_name(context, name, operation)
    occursin(r"[:.]", name) || return nothing
    _check_name_release(_checked_release(context), name, operation)
end

function _check_name(connection::ControlConnection, name, operation)
    occursin(r"[:.]", name) || return nothing
    version = _control_release(connection)
    version === nothing || _check_name_release(version, name, operation)
end
