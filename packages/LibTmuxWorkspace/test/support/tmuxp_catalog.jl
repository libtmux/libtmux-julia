# tmuxp's example catalog, the structure each accepted file has to produce, and
# the record of which tmuxp syntax the loader takes.
#
# The files under fixtures/tmuxp/expected were written by hand from what tmuxp
# documents for each example; see the README beside them. No tmuxp or Python
# runs. Where this loader means something else, DIFFERENCES lists the rule with
# its reason, and the tests fail when the loader stops differing.
module TmuxpCatalog

using JSON
using LibTmuxWorkspace

const DIRECTORY = joinpath(@__DIR__, "..", "fixtures", "tmuxp")
const EXPECTED = joinpath(DIRECTORY, "expected")
const SYNTAX = joinpath(DIRECTORY, "syntax-support.json")

# The loader reads no ambient environment, so the test supplies a home, a base
# directory and the variables the catalog uses. Expected files name the first
# two as symbols and write the others as the placeholders below.
const WORKSPACE_DIR = "\${WORKSPACE_DIR}"
const HOME = "\${HOME}"
const BASE = "/@WORKSPACE_DIR@"
const HOME_DIRECTORY = "/@HOME@"
const VARIABLES =
    Dict("PWD" => "/@PWD@", "MY_ENV_VAR" => "/@MY_ENV_VAR@", "USER" => "@USER@")

# tmuxp's examples this loader reads.
const LOADED = [
    "2-pane-synchronized",
    "2-pane-vertical",
    "3-pane",
    "4-pane",
    "blank-panes",
    "env-variables",
    "focus-window-and-panes",
    "main-pane-height-percentage",
    "main-pane-height",
    "pane-shell",
    "session-environment",
    "shorthands",
    "start-directory",
    "suppress-history",
    "window-index",
]

path(name) = joinpath(DIRECTORY, name * ".yaml")

function expected(name)
    tree = JSON.parsefile(joinpath(EXPECTED, name * ".json"); dicttype=Dict{String,Any})
    delete!(tree, "source")
    # Keys that only some files need default to empty.
    get!(tree["session"], "before_script", nothing)
    for window in tree["windows"]
        get!(window, "options_after", Dict{String,Any}())
        for pane in window["panes"]
            get!(pane, "shell", nothing)
        end
    end
    tree
end

"A directory as the expected files write it. A trailing slash names the same directory."
function symbolic(directory)
    directory === nothing && return nothing
    text = directory == "/" ? directory : rstrip(directory, '/')
    for (prefix, symbol) in ((BASE, WORKSPACE_DIR), (HOME_DIRECTORY, HOME))
        text == prefix && return symbol
        startswith(text, prefix * "/") && return symbol * text[(ncodeunits(prefix)+1):end]
    end
    text
end

option_value(value::Bool) = value ? "on" : "off"
option_value(value) = value
options(pairs) =
    Dict{String,Any}(string(name) => option_value(value) for (name, value) in pairs)

"""
The window each pane and window is in when the build ends: the last one the file
focuses, else the first. A window without an index gets the lowest one tmux has
free when it is made.
"""
function effective(windows)
    used = Set{Int}()
    indices = Int[]
    for window in windows
        index = window.index
        if index === nothing
            index = 0
            while index in used
                index += 1
            end
        end
        push!(used, index)
        push!(indices, index)
    end
    focused(items) = something(findlast(i -> i.focus, items), 1)
    indices, focused(windows)
end

function structure(name)
    expanded = expand(
        validate(read_config(path(name)));
        env=VARIABLES,
        home=HOME_DIRECTORY,
        base_directory=BASE,
    )
    shape(expanded, symbolic)
end

"""
The expanded workspace in the shape of the expected files. `directory` maps each
start directory, which the catalog shows as symbols and the syntax probes show as is.
"""
function shape(expanded, directory)
    indices, selected = effective(expanded.windows)
    Dict{String,Any}(
        "session" => Dict{String,Any}(
            "name" => expanded.session_name,
            "start_directory" => directory(expanded.start_directory),
            "environment" => Dict{String,Any}(expanded.environment),
            "options" => options(expanded.options),
            "before_script" => expanded.before_script,
        ),
        "windows" => [
            Dict{String,Any}(
                "name" => window.name,
                "index" => indices[wi],
                "layout" => window.layout,
                "focus" => wi == selected,
                "start_directory" => directory(window.start_directory),
                "options" => options(window.options),
                "options_after" => options(window.options_after),
                "panes" => [
                    Dict{String,Any}(
                        "focus" =>
                            pi == something(findlast(p -> p.focus, window.panes), 1),
                        "start_directory" => directory(pane.start_directory),
                        "shell" => pane.shell,
                        "environment" => Dict{String,Any}(pane.environment),
                        "commands" => String[command.text for command in pane.commands],
                    ) for (pi, pane) in enumerate(window.panes)
                ],
            ) for (wi, window) in enumerate(expanded.windows)
        ],
    )
end

# Where the loader means something other than tmuxp, and why. A rule maps what
# the expected file says at one place to what the loader produces there, or
# returns `missing` where it does not apply. The tests fail when a rule no
# longer applies to anything or the loader stops differing.
#
# undeclared_directory: tmuxp leaves a start_directory nobody declared to tmux,
#   which uses the directory tmuxp was started in. The loader has no ambient
#   working directory, so it starts every undeclared directory in the workspace
#   file's directory, and the same file means the same panes wherever it is loaded.
# dot_relative_directory: the example's text asks for the workspace file's
#   directory with `./`. The loader resolves every relative window or pane
#   directory, `./` included, against its parent's directory, so under a session
#   start_directory of /var the window starts in /var.
const DIFFERENCES = (
    (
        id=:undeclared_directory,
        apply=(file, location, want) ->
            last(location) == "start_directory" && want === nothing ? WORKSPACE_DIR :
            missing,
    ),
    (
        id=:dot_relative_directory,
        apply=(file, location, want) ->
            file == "start-directory" &&
            location[1] == "windows" &&
            location[2] == 5 &&
            last(location) == "start_directory" &&
            want == WORKSPACE_DIR ? "/var" : missing,
    ),
)

"The expected tree with the loader's differences applied, and the rules that applied."
function port_expected(name)
    fired = Set{Symbol}()
    function walk(value, location)
        if value isa AbstractDict
            Dict{String,Any}(key => walk(item, [location; key]) for (key, item) in value)
        elseif value isa AbstractVector
            [walk(item, [location; index]) for (index, item) in enumerate(value)]
        else
            for rule in DIFFERENCES
                replacement = rule.apply(name, location, value)
                if replacement !== missing
                    push!(fired, rule.id)
                    return replacement
                end
            end
            value isa String && last(location) == "start_directory" ? symbolic(value) :
            value
        end
    end
    tree = expected(name)
    walk(tree, String[]), fired
end

"The record of which tmuxp syntax the loader takes, one entry per key and form."
syntax() = JSON.parsefile(SYNTAX; dicttype=Dict{String,Any})

"What an entry's probe expands to, or the message of the error that refuses it."
function probe(entry)
    options = get(entry, "options", Dict{String,Any}())
    try
        shape(
            expand(
                validate(parse_config(join(entry["probe"], "\n") * "\n"));
                env=get(options, "env", Dict{String,String}()),
                home="/home/u",
                base_directory="/workspace",
            ),
            identity,
        )
    catch error
        error isa WorkspaceConfigError || rethrow()
        sprint(showerror, error)
    end
end

"The places where two trees differ, as (location, wanted, got) triples."
function mismatches(want, got, location=Any[])
    found = Tuple[]
    if want isa AbstractDict && got isa AbstractDict
        for key in sort!(collect(union(keys(want), keys(got))))
            append!(
                found,
                mismatches(
                    get(want, key, :absent),
                    get(got, key, :absent),
                    [location; key],
                ),
            )
        end
    elseif want isa AbstractVector && got isa AbstractVector && length(want) == length(got)
        for (index, (a, b)) in enumerate(zip(want, got))
            append!(found, mismatches(a, b, [location; index]))
        end
    elseif want != got
        push!(found, (location, want, got))
    end
    found
end

end
