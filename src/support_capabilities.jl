# Support: which optional tmux capabilities libtmux gates (`support.capabilities`).
# This file is the one table behind both the refusals in `features.jl` and the
# `capabilities.json` manifest that the documentation site reads. A capability
# is a feature that exists from one tmux release on; a workaround is a defect
# in exact releases that the library refuses or repairs. The ids are shared
# with the other ports (central ADR 0003). The manifest is emitted by
# `dev/emit-capabilities.jl`, and `test/support_capabilities.jl` fails when the
# committed file differs from this table.

struct _CapabilityCommand
    command::String
    flags::Vector{String}
end
_CapabilityCommand(command::AbstractString, flags::AbstractString...) =
    _CapabilityCommand(String(command), String[flags...])

struct _Capability
    id::String
    name::String
    summary::String
    since::String
    except::Vector{String}
    handling::Symbol
    error::Union{Nothing,String}
    apis::Vector{String}
    commands::Vector{_CapabilityCommand}
end

struct _Workaround
    id::String
    name::String
    summary::String
    releases::Vector{String}
    handling::Symbol
    apis::Vector{String}
    commands::Vector{_CapabilityCommand}
end

const _CAPABILITIES = _Capability[
    _Capability(
        "control-mode",
        "Control mode",
        "Attach a library-managed control client and stream events.",
        "3.7",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        [
            "LibTmux.open_control",
            "LibTmux.observe_output",
            "LibTmux.subscribe_format",
            "LibTmux.notifications",
        ],
        [_CapabilityCommand("attach-session")],
    ),
    _Capability(
        "buffer-delete-named",
        "Named buffer deletion",
        "Delete one paste buffer by name without risking another buffer. paste_bytes and paste_text keep working below it by deleting their own staging buffer with paste-buffer -d.",
        "3.4",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.delete_buffer", "LibTmux.load_buffer"],
        [
            _CapabilityCommand("delete-buffer", "-b"),
            _CapabilityCommand("load-buffer", "-b"),
        ],
    ),
    _Capability(
        "buffer-rename",
        "Buffer rename",
        "Rename a paste buffer without risking another buffer.",
        "3.4",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.run_command", "LibTmux.run_batch", "LibTmux.run_group"],
        [_CapabilityCommand("set-buffer", "-n")],
    ),
    _Capability(
        "layout-without-checksum",
        "Layouts without a checksum",
        "Apply a layout string that opens like a dumped layout; tmux 3.3 and 3.3a stop on any other operand.",
        "3.4",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.run_command", "LibTmux.run_batch", "LibTmux.run_group"],
        [_CapabilityCommand("select-layout")],
    ),
    _Capability(
        "clipboard-query",
        "Clipboard query",
        "Ask an attached client's terminal for its clipboard with refresh-client -l. tmux 3.3a stops at once; 3.4 to 3.6 stop when the client leaves before its terminal answers.",
        "3.6a",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.run_command", "LibTmux.run_batch", "LibTmux.run_group"],
        [_CapabilityCommand("refresh-client", "-l")],
    ),
    _Capability(
        "layout-mirrored-main",
        "Mirrored main layouts",
        "Apply the main-horizontal-mirrored and main-vertical-mirrored layouts.",
        "3.5",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.select_layout"],
        [_CapabilityCommand("select-layout")],
    ),
    _Capability(
        "layout-json",
        "JSON layout strings",
        "Apply a layout saved in the JSON form tmux reports. The library requires the 3.8 release, so 3.8 release candidates are refused although they accept it.",
        "3.8",
        String[],
        :refuse,
        "LibTmux.UnsupportedCapability",
        ["LibTmux.select_layout"],
        [_CapabilityCommand("select-layout")],
    ),
]

const _WORKAROUNDS = _Workaround[
    _Workaround(
        "name-separators-rejected",
        "Colon and dot in names",
        "tmux 3.7 rejects ':' and '.' in session and window names, so the library refuses them first.",
        ["3.7"],
        :refuse,
        [
            "LibTmux.new_session",
            "LibTmux.new_window",
            "LibTmux.rename_session",
            "LibTmux.rename_window",
        ],
        [
            _CapabilityCommand("new-session"),
            _CapabilityCommand("new-window"),
            _CapabilityCommand("rename-session"),
            _CapabilityCommand("rename-window"),
        ],
    ),
    _Workaround(
        "break-pane-misnames-windows",
        "break-pane window naming",
        "tmux 3.7 stops on a break-pane without a window name and ignores -n. The library refuses the nameless form in raw command lines and in break_pane, and break_pane renames the window afterwards.",
        ["3.7"],
        :refuse,
        ["LibTmux.run_command", "LibTmux.run_batch", "LibTmux.run_group"],
        [_CapabilityCommand("break-pane", "-n")],
    ),
]

_capability(id::AbstractString) = only(filter(c -> c.id == id, _CAPABILITIES))
_workaround(id::AbstractString) = only(filter(w -> w.id == id, _WORKAROUNDS))

# Whether a release is one of the exact releases a workaround lists. A listed
# release without a patch letter also covers its pre-release builds, which rank
# below it but carry the same defect.
function _in_releases(version, releases)
    key = _release_key(version)
    key === nothing && return false
    any(release -> key[1:3] == _release_key(release)[1:3], releases)
end

_workaround_applies(id::AbstractString, version) =
    _in_releases(version, _workaround(id).releases)

# The first release at which a capability works. Gates read this, so moving a
# release here moves both the refusal and the manifest.
_capability_since(id::AbstractString) = _capability(id).since

const _CAPABILITY_SCHEMA = "libtmux-capabilities/1"
const _CAPABILITY_PORT = "julia"

# JSON with sorted keys, two-space indent and ASCII escapes, the way the other
# ports write it. Core Julia has no JSON writer and JSON is an optional
# dependency, so the manifest writes its own.
function _json_string(text::AbstractString)
    out = IOBuffer()
    print(out, '"')
    for c in text
        if c == '"'
            print(out, "\\\"")
        elseif c == '\\'
            print(out, "\\\\")
        elseif c == '\n'
            print(out, "\\n")
        elseif c == '\t'
            print(out, "\\t")
        elseif c == '\r'
            print(out, "\\r")
        elseif ' ' <= c <= '~'
            print(out, c)
        else
            for unit in (c > '￿' ? _surrogates(c) : UInt16[UInt16(c)])
                print(out, "\\u", lpad(string(unit; base=16), 4, '0'))
            end
        end
    end
    print(out, '"')
    String(take!(out))
end

function _surrogates(c::Char)
    offset = UInt32(c) - 0x10000
    UInt16[0xd800+(offset>>10), 0xdc00+(offset&0x3ff)]
end

# A value is a string, a vector, or a vector of key => value pairs, which the
# writer sorts by key.
function _json_value(value, depth)
    pad = "  "^depth
    inner = "  "^(depth + 1)
    if value isa AbstractString
        _json_string(value)
    elseif value isa AbstractVector{<:Pair}
        isempty(value) && return "{}"
        members = sort(collect(value); by=first)
        "{\n" *
        join(
            (
                inner * _json_string(k) * ": " * _json_value(v, depth + 1) for
                (k, v) in members
            ),
            ",\n",
        ) *
        "\n" *
        pad *
        "}"
    else
        isempty(value) && return "[]"
        "[\n" *
        join((inner * _json_value(v, depth + 1) for v in value), ",\n") *
        "\n" *
        pad *
        "]"
    end
end

function _command_json(command::_CapabilityCommand)
    members = Pair{String,Any}["command"=>command.command]
    isempty(command.flags) || push!(members, "flags" => command.flags)
    members
end

function _capability_json(capability::_Capability)
    members = Pair{String,Any}[
        "id"=>capability.id,
        "name"=>capability.name,
        "summary"=>capability.summary,
        "since"=>capability.since,
        "handling"=>String(capability.handling),
        "apis"=>capability.apis,
        "commands"=>[_command_json(c) for c in capability.commands],
    ]
    isempty(capability.except) || push!(members, "except" => capability.except)
    capability.error === nothing || push!(members, "error" => capability.error)
    members
end

_workaround_json(workaround::_Workaround) = Pair{String,Any}[
    "id"=>workaround.id,
    "name"=>workaround.name,
    "summary"=>workaround.summary,
    "releases"=>workaround.releases,
    "handling"=>String(workaround.handling),
    "apis"=>workaround.apis,
    "commands"=>[_command_json(c) for c in workaround.commands],
]

"""
The text of `capabilities.json`, emitted from `_CAPABILITIES` and
`_WORKAROUNDS`. It is deterministic and ends in a newline.
"""
function _capabilities_manifest()
    manifest = Pair{String,Any}[
        "schema"=>_CAPABILITY_SCHEMA,
        "port"=>_CAPABILITY_PORT,
        "floor"=>Pair{String,Any}["minimum"=>MINIMUM_TMUX_VERSION],
        "capabilities"=>[_capability_json(c) for c in _CAPABILITIES],
        "workarounds"=>[_workaround_json(w) for w in _WORKAROUNDS],
    ]
    _json_value(manifest, 0) * "\n"
end
