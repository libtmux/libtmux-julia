using SHA
using TOML

const OPTION_RELEASES = (
    "3.2a",
    "3.3",
    "3.3a",
    "3.4",
    "3.5",
    "3.5a",
    "3.6",
    "3.6a",
    "3.6b",
    "3.7",
    "3.7a",
    "3.7b",
    "3.7c",
)
const OPTION_KINDS = ("string", "number", "key", "colour", "flag", "choice", "command")
const OPTION_SCOPES = Dict("SERVER" => 1, "SESSION" => 2, "WINDOW" => 4, "PANE" => 8)
const OPTION_FLAGS = ("ARRAY", "HOOK", "STYLE")

function source_options(source)
    for (prefix, scope) in
        ("" => "SESSION", "WINDOW_" => "WINDOW", "PANE_" => "WINDOW|OPTIONS_TABLE_PANE")
        definition = match(
            Regex(
                "#define OPTIONS_TABLE_" *
                prefix *
                "HOOK\\(hook_name, default_value\\)(.*?\\n\\t\\})",
                "s",
            ),
            source,
        )
        definition === nothing && error("missing upstream hook macro")
        body = replace(definition[1], r"[\s\\]" => "")
        all(
            part -> occursin(part, body),
            (
                ".type=OPTIONS_TABLE_COMMAND,",
                ".scope=OPTIONS_TABLE_" * scope * ",",
                ".flags=OPTIONS_TABLE_IS_ARRAY|OPTIONS_TABLE_IS_HOOK,",
            ),
        ) || error("upstream hook macro changed")
    end
    marker = "const struct options_table_entry options_table[] = {"
    pieces = split(source, marker; limit=2)
    length(pieces) == 2 || error("missing upstream options table")
    table = last(pieces)
    occursin(r"(?m)^\s*#", table) && error("conditional upstream table needs review")
    options = Dict{String,NamedTuple}()
    records = collect(eachmatch(r"\{\s*\.name\s*=\s*\"([^\"]+)\",(.*?)\n\s*\},"s, table))
    length(records) == length(collect(eachmatch(r"\.name\s*=\s*\"", table))) ||
        error("unparsed upstream option record")
    for record in records
        name, body = record.captures
        fields = Dict(
            m[1] => strip(m[2]) for m in
            eachmatch(r"(?m)^\s*\.(type|scope|flags|pattern)\s*=\s*([^\n]*),\s*$", body)
        )
        length(fields) ==
        length(collect(eachmatch(r"\.(type|scope|flags|pattern)\s*=", body))) ||
            error("unparsed upstream option metadata")
        kind = lowercase(replace(fields["type"], "OPTIONS_TABLE_" => ""))
        kind in OPTION_KINDS || error("unknown upstream type: $kind")
        scopes = split(replace(fields["scope"], "OPTIONS_TABLE_" => ""), '|')
        all(s -> haskey(OPTION_SCOPES, s), scopes) || error("unknown upstream scope")
        scope = sum(OPTION_SCOPES[s] for s in scopes)
        flags = split(replace(get(fields, "flags", ""), "OPTIONS_TABLE_IS_" => ""), '|')
        all(f -> isempty(f) || f in OPTION_FLAGS, flags) || error("unknown upstream flag")
        haskey(options, name) && error("duplicate upstream option: $name")
        options[name] = (;
            scope,
            kind,
            array="ARRAY" in flags,
            hook="HOOK" in flags,
            checked_string="STYLE" in flags ||
                           haskey(fields, "pattern") ||
                           name == "default-shell",
        )
    end
    hooks = collect(eachmatch(r"OPTIONS_TABLE_(PANE_|WINDOW_)?HOOK\(\"([^\"]+)\"", table))
    length(hooks) == length(collect(eachmatch(r"OPTIONS_TABLE_\w*HOOK\(", table))) ||
        error("unparsed upstream hook record")
    for hook in hooks
        prefix, name = hook.captures
        scope = prefix === nothing ? 2 : prefix == "PANE_" ? 12 : 4
        haskey(options, name) && error("duplicate upstream hook: $name")
        options[name] =
            (; scope, kind="command", array=true, hook=true, checked_string=false)
    end
    isempty(options) && error("empty upstream options table")
    options
end

function imported_catalog(upstream; pinned=nothing)
    sources, snapshots = Dict{String,Any}[], Dict{String,NamedTuple}[]
    for (index, ref) in enumerate(OPTION_RELEASES)
        commit =
            pinned === nothing ?
            strip(read(`git -C $upstream rev-parse $(ref * "^{commit}")`, String)) :
            pinned[index]["commit"]
        occursin(r"\A[0-9a-f]{40}\z", commit) || error("invalid upstream commit")
        source = read(`git -C $upstream show $(commit * ":options-table.c")`, String)
        digest = bytes2hex(sha256(source))
        pinned === nothing ||
            digest == pinned[index]["sha256"] ||
            error("upstream source digest changed: $ref")
        push!(sources, Dict("ref" => ref, "commit" => commit, "sha256" => digest))
        push!(snapshots, source_options(source))
    end
    rows = Dict{String,Any}[]
    names = sort!(collect(union((Set(keys(snapshot)) for snapshot in snapshots)...)))
    for name in names
        first_index = 1
        while first_index <= length(snapshots)
            metadata = get(snapshots[first_index], name, nothing)
            if metadata === nothing
                first_index += 1
                continue
            end
            last_index = first_index
            while last_index < length(snapshots) &&
                  get(snapshots[last_index+1], name, nothing) == metadata
                last_index += 1
            end
            row = Dict{String,Any}(string(key) => value for (key, value) in pairs(metadata))
            merge!(
                row,
                Dict(
                    "name" => name,
                    "first" => OPTION_RELEASES[first_index],
                    "last" => OPTION_RELEASES[last_index],
                ),
            )
            push!(rows, row)
            first_index = last_index + 1
        end
    end
    Dict(
        "version" => 1,
        "upstream" => "https://github.com/tmux/tmux",
        "releases" => sources,
        "options" => rows,
    )
end

function catalog_text(catalog)
    io = IOBuffer()
    println(io, "# Extracted metadata from pinned upstream options-table.c files.")
    println(io, "# Refresh: dev/generate-options.jl --import-upstream CHECKOUT")
    println(io, "# Scope bits: server=1, session=2, window=4, pane=8.\n")
    println(io, "version = 1\nupstream = ", repr(catalog["upstream"]), "\n")
    println(io, "releases = [")
    for source in catalog["releases"]
        println(
            io,
            "  { ref = ",
            repr(source["ref"]),
            ", commit = ",
            repr(source["commit"]),
            ", sha256 = ",
            repr(source["sha256"]),
            " },",
        )
    end
    println(io, "]\n\noptions = [")
    keys = ("name", "first", "last", "scope", "kind", "array", "hook", "checked_string")
    for row in catalog["options"]
        println(
            io,
            "  { ",
            join((key * " = " * repr(row[key]) for key in keys), ", "),
            " },",
        )
    end
    println(io, "]")
    String(take!(io))
end

function validate_catalog(catalog)
    Set(keys(catalog)) == Set(("version", "upstream", "releases", "options")) ||
        error("unknown catalog fields")
    catalog["version"] == 1 || error("unsupported option catalog version")
    Tuple(source["ref"] for source in catalog["releases"]) == OPTION_RELEASES ||
        error("unexpected option release profiles")
    for source in catalog["releases"]
        Set(keys(source)) == Set(("ref", "commit", "sha256")) ||
            error("unknown source field")
        occursin(r"\A[0-9a-f]{40}\z", source["commit"]) || error("invalid source commit")
        occursin(r"\A[0-9a-f]{64}\z", source["sha256"]) || error("invalid source digest")
    end
    grouped = Dict{String,Vector{Dict{String,Any}}}()
    fields =
        Set(("name", "first", "last", "scope", "kind", "array", "hook", "checked_string"))
    for row in catalog["options"]
        Set(keys(row)) == fields || error("unknown option field")
        name = row["name"]
        occursin(r"\A[a-z][a-z0-9-]*\z", name) || error("invalid exact option name")
        row["scope"] in (1, 2, 4, 12) || error("invalid scope bits")
        row["kind"] in OPTION_KINDS || error("invalid option kind")
        all(key -> row[key] isa Bool, ("array", "hook", "checked_string")) ||
            error("invalid option flags")
        !row["hook"] || (row["array"] && row["kind"] == "command") || error("invalid hook")
        !row["checked_string"] || row["kind"] == "string" || error("invalid string check")
        first_index = findfirst(==(row["first"]), OPTION_RELEASES)
        last_index = findfirst(==(row["last"]), OPTION_RELEASES)
        first_index !== nothing && last_index !== nothing && first_index <= last_index ||
            error("invalid release interval")
        push!(get!(grouped, name, Dict{String,Any}[]), row)
    end
    for rows in values(grouped)
        previous = 0
        for row in rows
            first_index = findfirst(==(row["first"]), OPTION_RELEASES)
            last_index = findfirst(==(row["last"]), OPTION_RELEASES)
            first_index > previous || error("overlapping option release intervals")
            previous = last_index
        end
    end
    grouped
end

function metadata_expression(row)
    values = (
        "0x" * string(row["scope"]; base=16, pad=2),
        ":" * row["kind"],
        repr(row["array"]),
        repr(row["hook"]),
        repr(row["checked_string"]),
    )
    "_TmuxOptionMetadata(" * join(values, ", ") * ")"
end

function generated_options(catalog)
    grouped = validate_catalog(catalog)
    io = IOBuffer()
    println(io, "# Generated by dev/generate-options.jl from schema/tmux-options.toml.")
    println(io, "# Catalog SHA256: ", bytes2hex(sha256(catalog_text(catalog))))
    println(io, "# Scope bits: server=1, session=2, window=4, pane=8.")
    println(
        io,
        "struct _TmuxOptionMetadata\n    scope::UInt8\n    kind::Symbol\n    array::Bool\n    hook::Bool\n    checked_string::Bool\nend\n",
    )
    println(io, "const _TMUX_OPTIONS_STABLE = Dict{String,_TmuxOptionMetadata}(")
    for name in sort!(collect(keys(grouped)))
        rows = grouped[name]
        length(rows) == 1 || continue
        println(io, "    ", repr(name), " => ", metadata_expression(only(rows)), ",")
    end
    println(io, ")\n")
    println(
        io,
        "const _TMUX_OPTIONS_VERSIONED = Dict{String,Tuple{Vararg{Tuple{Int,Int,_TmuxOptionMetadata}}}}(",
    )
    for name in sort!(collect(keys(grouped)))
        rows = grouped[name]
        length(rows) > 1 || continue
        println(io, "    ", repr(name), " => (")
        for row in rows
            first_index = findfirst(==(row["first"]), OPTION_RELEASES)
            last_index = findfirst(==(row["last"]), OPTION_RELEASES)
            println(
                io,
                "        (",
                first_index,
                ", ",
                last_index,
                ", ",
                metadata_expression(row),
                "),",
            )
        end
        println(io, "    ),")
    end
    println(io, ")\n")
    println(io, "const _TMUX_OPTION_RELEASES = ", repr(OPTION_RELEASES), "\n")
    print(
        io,
        raw"""
# Stable entries still need an exact named backend probe for availability.
_tmux_option_metadata(name::AbstractString) = get(_TMUX_OPTIONS_STABLE, name, nothing)
_tmux_option_versioned(name::AbstractString) = haskey(_TMUX_OPTIONS_VERSIONED, name)

function _tmux_option_metadata(name::AbstractString, version::AbstractString)
    rows = get(_TMUX_OPTIONS_VERSIONED, name, nothing)
    rows === nothing && return _tmux_option_metadata(name)
    release = findfirst(==(version), _TMUX_OPTION_RELEASES)
    release === nothing && return nothing
    for (first_release, last_release, metadata) in rows
        first_release <= release <= last_release && return metadata
    end
    nothing
end
""",
    )
    String(take!(io))
end

function options_main(args)
    root = dirname(@__DIR__)
    schema = joinpath(root, "schema", "tmux-options.toml")
    output = joinpath(root, "src", "options_generated.jl")
    if length(args) == 2 && args[1] == "--import-upstream"
        catalog = imported_catalog(args[2])
        generated_options(catalog)
        write(schema, catalog_text(catalog))
        write(output, generated_options(catalog))
        println("imported ", length(catalog["releases"]), " pinned tmux option profiles")
        return
    end
    catalog = TOML.parsefile(schema)
    expected = generated_options(catalog)
    if length(args) == 2 && args[1] == "--check-upstream"
        imported = imported_catalog(args[2]; pinned=catalog["releases"])
        imported == catalog || error("catalog differs from pinned upstream metadata")
        println("option metadata matches pinned upstream sources")
    elseif args == ["--check"]
        isfile(output) && read(output, String) == expected ||
            error("generated options are stale")
        println("option generation is current")
    elseif isempty(args)
        write(output, expected)
    else
        error(
            "usage: generate-options.jl [--check | --import-upstream CHECKOUT | --check-upstream CHECKOUT]",
        )
    end
end

abspath(PROGRAM_FILE) == (@__FILE__) && options_main(ARGS)
