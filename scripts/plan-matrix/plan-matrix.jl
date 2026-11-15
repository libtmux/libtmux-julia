# Plan which tmux releases and jobs a Julia CI run covers.
#
# usage:
#   julia --project=. scripts/plan-matrix/plan-matrix.jl plan --event EVENT [--ref REF]
#       [--scope SCOPE] [--tmux-ref REFS] [--julia VERSION] [--threads N]
#       [--suite SUITE] [--tmate MODE] [--github-output FILE] [--summary FILE]
#   julia --project=. scripts/plan-matrix/plan-matrix.jl gate
#
# This module holds the tmux table and decides what a run covers, so the workflow
# lists no version. Scopes:
#
# - `edges`: the oldest and newest supported release. The default for a push, a
#   pull request and a dispatch.
# - `full`: the whole table and the refusal lanes. A release tag, and a dispatch
#   that asks.
# - `custom`: only the tmux versions, tags, branches or commits a dispatch names.
#
# `gate` checks the results of the jobs the plan scheduled, which the `required`
# job passes in `MATRIX_RESULT`, `MATRIX_RUN_REJECTED`, `REJECT_RESULT` and
# `CHECK_RESULT`. The tests are in tests/runtests.jl.

module PlanMatrix

# Supported releases, oldest first. The first is the floor and the last the newest.
# The shared build-tmux action pins and builds each of them.
const SUPPORTED_TMUX = ("3.3a", "3.4", "3.5a", "3.6b", "3.7", "3.7a", "3.7b", "3.7c", "3.8")
# Releases below the supported floor. Their cells assert refusal without effect and
# stay outside the supported matrix.
const REJECTED_TMUX = ("3.0a", "3.1c", "3.2a", "3.3")
# Releases whose daemon answers a current client with a protocol mismatch or a usage
# error; their cells run the real-build refusal test in place of the owned-daemon
# rejection suite.
const PRE_PROBE_TMUX = ("3.0a", "3.1c")
const MINIMUM_TMUX = SUPPORTED_TMUX[1]
const NEWEST_TMUX = SUPPORTED_TMUX[end]
# The full scope runs the delivery suite, which does not depend on the release, at
# the floor, at 3.7c and at the newest release, and runs 3.7c at four threads as
# well. A push and a pull request run the edges instead.
const DELIVERY_TMUX = ("3.3a", "3.7c", "3.8")
const FOUR_THREAD_TMUX = "3.7c"
const MINIMUM_JULIA = "1.13.1"
const SUITES = ("runtime", "delivery")

const WORKFLOW = joinpath(dirname(dirname(@__DIR__)), ".github", "workflows", "julia.yml")

const SCOPES = ("edges", "full", "custom")
const TMATE_MODES = ("off", "before-tests", "on-failure")
const EVENTS = ("push", "pull_request", "workflow_dispatch")

# Every item of `tmux-ref` is checked against this before it reaches a shell or a
# git command.
const REF_PATTERN = r"^[A-Za-z0-9._/-]{1,64}$"
const ABBREVIATED_SHA = r"^[0-9a-f]{7,39}$"
const JULIA_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$"
const EXACT_JULIA = r"^\d+\.\d+\.\d+$"

# A mistyped list should fail rather than fan out into a huge matrix.
const MAX_REFS = 8
# The planning job and the aggregate, which every run has.
const FIXED_JOBS = 2

# The tests replace a rule with its absence to prove that a check notices. Every
# replaceable rule is read through `hook`, so a test can swap one for the length of
# a call without rewriting the module.
const HOOKS = Dict{Symbol,Any}()
hook(name, default) = get(HOOKS, name, default)

function with_hooks(f, replacements::Pair{Symbol}...)
    saved = Dict(name => get(HOOKS, name, nothing) for (name, _) in replacements)
    for (name, value) in replacements
        HOOKS[name] = value
    end
    try
        f()
    finally
        for (name, value) in saved
            value === nothing ? delete!(HOOKS, name) : (HOOKS[name] = value)
        end
    end
end

"The inputs name a run that cannot or must not happen."
struct PlanError <: Exception
    message::String
end
Base.showerror(io::IO, error::PlanError) = print(io, error.message)

supported() = hook(:SUPPORTED_TMUX, SUPPORTED_TMUX)
newest() = hook(:NEWEST_TMUX, NEWEST_TMUX)

"Split a comma-separated input, dropping blanks and repeats."
split_list(value) = unique(filter(!isempty, strip.(split(value, ','))))

"Decide how much of the table a run covers."
resolve_scope(event, ref, scope) = hook(:resolve_scope, _resolve_scope)(event, ref, scope)
function _resolve_scope(event, ref, scope)
    if !isempty(scope)
        scope in SCOPES || throw(
            PlanError("scope must be one of $(join(SCOPES, ", ")), not $(repr(scope))"),
        )
        return scope
    end
    startswith(ref, "refs/tags/") && return "full"
    event in EVENTS && return "edges"
    throw(PlanError("no scope is defined for the $(repr(event)) event"))
end

"Pick the oldest and the newest supported release."
edge_versions(table) = hook(:edge_versions, _edge_versions)(table)
_edge_versions(table) = unique([first(table), last(table)])

"Refuse inputs that only a custom run reads, so none is silently ignored."
check_scope_inputs(scope; given...) =
    hook(:check_scope_inputs, _check_scope_inputs)(scope; given...)
function _check_scope_inputs(scope; given...)
    for (name, value) in given
        !isempty(value) &&
            scope != "custom" &&
            throw(
                PlanError(
                    "$(replace(string(name), '_' => '-')) is only used with scope custom",
                ),
            )
    end
end

"Refuse a plan with no job, which GitHub would reject anyway."
require_jobs(jobs) = hook(:require_jobs, _require_jobs)(jobs)
_require_jobs(jobs) = isempty(jobs) && throw(PlanError("the plan has no job"))

"Refuse a tmux ref that is malformed or could be read as an option."
check_ref(item) = hook(:check_ref, _check_ref)(item)
function _check_ref(item)
    occursin(REF_PATTERN, item) ||
        throw(PlanError("tmux-ref item $(repr(item)) must match $(REF_PATTERN.pattern)"))
    (
        startswith(item, "-") ||
        occursin("..", item) ||
        endswith(item, ".lock") ||
        endswith(item, "/")
    ) && throw(PlanError("tmux-ref item $(repr(item)) is not a usable git ref"))
    occursin(ABBREVIATED_SHA, item) && throw(
        PlanError(
            "tmux-ref item $(repr(item)) looks like an abbreviated commit; give the full 40-hex SHA",
        ),
    )
    item
end

"Validate the refs a custom run was asked to build."
custom_refs(tmux_ref) = hook(:custom_refs, _custom_refs)(tmux_ref)
function _custom_refs(tmux_ref)
    items = split_list(tmux_ref)
    isempty(items) &&
        throw(PlanError("scope custom needs tmux-ref, a comma-separated list of tmux refs"))
    length(items) > hook(:MAX_REFS, MAX_REFS) && throw(
        PlanError("tmux-ref names $(length(items)) refs; at most $(MAX_REFS) fit one run"),
    )
    [check_ref(item) for item in items]
end

"Take the Julia version a dispatch asks for, or the normal one."
select_julia(requested) = hook(:select_julia, _select_julia)(requested)
function _select_julia(requested)
    isempty(requested) && return MINIMUM_JULIA
    occursin(JULIA_PATTERN, requested) ||
        throw(PlanError("julia $(repr(requested)) must match $(JULIA_PATTERN.pattern)"))
    requested
end

"Take the thread count a custom run asks for, or one thread."
select_threads(requested) = hook(:select_threads, _select_threads)(requested)
function _select_threads(requested)
    requested in ("", "1", "4") ||
        throw(PlanError("threads must be 1 or 4, not $(repr(requested))"))
    parse(Int, isempty(requested) ? "1" : requested)
end

"Take the suites a custom run asks for, or the runtime suite alone."
select_suites(requested) = hook(:select_suites, _select_suites)(requested)
function _select_suites(requested)
    requested in ("", "runtime") && return ("runtime",)
    requested == "delivery" && return ("delivery",)
    requested == "both" && return SUITES
    throw(PlanError("suite must be runtime, delivery or both, not $(repr(requested))"))
end

"""
Describe one platform cell. A release is built from its official tarball and its
`tmux -V` must match. Anything else is resolved to a commit and built from source,
and has no version to assert.
"""
make_cell(tmux, julia, threads, suites, release) =
    hook(:make_cell, _make_cell)(tmux, julia, threads, suites, release)
function _make_cell(tmux, julia, threads, suites, release)
    Dict{String,Any}(
        "label" => "Linux-x86_64-julia$julia-tmux$(replace(tmux, '/' => '-'))-t$threads",
        "os" => "Linux",
        "runner" => "ubuntu-24.04",
        "arch" => "x86_64",
        "julia" => julia,
        "tmux" => tmux,
        "threads" => threads,
        "suites" => collect(suites),
        "status" => "NOT RUN",
        "kind" => release ? "release" : "ref",
        "expected_julia" => occursin(EXACT_JULIA, julia) ? julia : "",
        "expected_tmux" => release ? tmux : "",
        "docs_artifact" => "false",
        "tmate" => "off",
    )
end

"""
Plan the cells of the whole table. Every release runs the runtime suite at one
thread. The delivery suite does not depend on the release, so it runs at the floor,
at 3.7c and at the newest release, and 3.7c also runs at four threads.
"""
function full_cells(julia)
    cells = Dict{String,Any}[]
    for tmux in supported()
        suites = tmux in hook(:DELIVERY_TMUX, DELIVERY_TMUX) ? SUITES : ("runtime",)
        push!(cells, make_cell(tmux, julia, 1, suites, true))
        tmux == hook(:FOUR_THREAD_TMUX, FOUR_THREAD_TMUX) &&
            push!(cells, make_cell(tmux, julia, 4, SUITES, true))
    end
    cells
end

"""
Plan the cells of a push: the oldest and newest release, both with the runtime and
delivery suites at one thread. The thread axis is part of the stack, which a push
keeps, so the newest release also runs at four threads.
"""
edge_cells(julia) = hook(:edge_cells, _edge_cells)(julia)
function _edge_cells(julia)
    cells = [make_cell(tmux, julia, 1, SUITES, true) for tmux in edge_versions(supported())]
    push!(cells, make_cell(newest(), julia, 4, SUITES, true))
    cells
end

"""
Upload the documentation artifact from the newest release at one thread. It does not
depend on the tmux release, so it comes from an edge cell, which every scope of the
table runs, and is uploaded once.
"""
mark_docs_artifact(cells) = hook(:mark_docs_artifact, _mark_docs_artifact)(cells)
function _mark_docs_artifact(cells)
    for cell in cells
        cell["tmux"] == newest() && cell["threads"] == 1 && (cell["docs_artifact"] = "true")
    end
end

"Plan one cell for each ref a dispatch names."
function custom_cells(refs, julia, threads, suites)
    known = (supported()..., REJECTED_TMUX...)
    [make_cell(item, julia, threads, suites, item in known) for item in refs]
end

"Plan the platform cells of a run."
qa_cells(scope="full"; tmux_ref="", julia="", threads="", suite="") =
    hook(:qa_cells, _qa_cells)(scope; tmux_ref, julia, threads, suite)
function _qa_cells(scope="full"; tmux_ref="", julia="", threads="", suite="")
    version = select_julia(julia)
    cells = if scope == "custom"
        custom_cells(
            custom_refs(tmux_ref),
            version,
            select_threads(threads),
            select_suites(suite),
        )
    elseif scope == "edges"
        edge_cells(version)
    else
        full_cells(version)
    end
    mark_docs_artifact(cells)
    cells
end

"Emit one job for each suite of every cell."
split_cells(cells) = [
    merge(cell, Dict("suite" => suite, "job_label" => "$(cell["label"])-$suite")) for
    cell in cells for suite in cell["suites"]
]

"Plan the refusal lanes, which only the whole table runs."
rejection_cells(scope="full") = hook(:rejection_cells, _rejection_cells)(scope)
function _rejection_cells(scope="full")
    scope == "full" || return Dict{String,Any}[]
    [
        Dict{String,Any}(
            "label" => "Linux-x86_64-julia$MINIMUM_JULIA-tmux$tmux-rejection",
            "tmux" => tmux,
            "job_label" => "Reject tmux $tmux",
            "real_old" => tmux in PRE_PROBE_TMUX ? "true" : "false",
            "suite" => tmux in PRE_PROBE_TMUX ? "old-daemon" : "rejection",
        ) for tmux in REJECTED_TMUX
    ]
end

"Give exactly one job the debug session, or fail."
assign_tmate(event, mode, jobs, rejected) =
    hook(:assign_tmate, _assign_tmate)(event, mode, jobs, rejected)
function _assign_tmate(event, mode, jobs, rejected)
    mode in TMATE_MODES || throw(
        PlanError("tmate must be one of $(join(TMATE_MODES, ", ")), not $(repr(mode))"),
    )
    mode == "off" && return
    event == "workflow_dispatch" ||
        throw(PlanError("tmate is only available on a workflow_dispatch run"))
    legs = length(jobs) + length(rejected)
    legs == 1 || throw(
        PlanError(
            "tmate needs exactly one job and this run has $legs; use scope custom with one tmux-ref and the default suite",
        ),
    )
    jobs[1]["tmate"] = mode
end

"Return the jobs, the refusal lanes and the job count for one run."
function plan(
    event;
    ref="",
    scope="",
    tmux_ref="",
    julia="",
    threads="",
    suite="",
    tmate="",
)
    chosen = resolve_scope(event, ref, scope)
    check_scope_inputs(chosen; tmux_ref, threads, suite)
    jobs = split_cells(qa_cells(chosen; tmux_ref, julia, threads, suite))
    require_jobs(jobs)
    rejected = rejection_cells(chosen)
    assign_tmate(event, isempty(tmate) ? "off" : tmate, jobs, rejected)
    Dict{String,Any}(
        "scope" => chosen,
        "cells" => jobs,
        "rejected" => rejected,
        "expected_jobs" => hook(:FIXED_JOBS, FIXED_JOBS) + length(jobs) + length(rejected),
    )
end

"""
Find the jobs that stop the aggregate from passing. The planning job and the checks
must succeed. The refusal lanes must succeed when the plan scheduled them and be
skipped when it left them out, so a skipped lane that was planned cannot pass.
"""
check_needs(needs) = hook(:check_needs, _check_needs)(needs)
function _check_needs(needs)
    problems = String[]
    for job in ("matrix", "check")
        result = get(get(needs, job, Dict()), "result", nothing)
        result == "success" ||
            push!(problems, "$job finished $(something(result, "missing")), not success")
    end
    outputs = get(get(needs, "matrix", Dict()), "outputs", Dict())
    wanted = get(outputs, "run_rejected", nothing) == "true" ? "success" : "skipped"
    result = get(get(needs, "reject", Dict()), "result", nothing)
    result == wanted ||
        push!(problems, "reject finished $(something(result, "missing")), not $wanted")
    problems
end

"The `needs` the aggregate job passes, read from the environment."
function needs_from_environment(env=ENV)
    Dict{String,Any}(
        "matrix" => Dict(
            "result" => get(env, "MATRIX_RESULT", ""),
            "outputs" => Dict("run_rejected" => get(env, "MATRIX_RUN_REJECTED", "")),
        ),
        "reject" => Dict("result" => get(env, "REJECT_RESULT", "")),
        "check" => Dict("result" => get(env, "CHECK_RESULT", "")),
    )
end

"Describe a plan for the job summary."
function summary(result)
    lines = [
        "### tmux plan: $(result["scope"])",
        "",
        "Expected jobs in this workflow: $(result["expected_jobs"])",
        "",
    ]
    for each in result["cells"]
        push!(
            lines,
            "- Julia $(each["julia"]) with tmux $(each["tmux"]), $(each["threads"]) thread(s), $(each["suite"]) suite ($(each["kind"]))",
        )
    end
    for each in result["rejected"]
        push!(lines, "- tmux $(each["tmux"]) is refused")
    end
    join(lines, '\n') * "\n"
end

# JSON for the workflow outputs. The values are strings, integers and lists of
# strings and of such tables, so a small writer is enough and needs no package.
function json(value; indent::Union{Nothing,Int}=nothing, level::Int=0)
    pad(n) = indent === nothing ? "" : "\n" * " "^(indent * n)
    if value isa AbstractString
        return "\"" *
               replace(
                   value,
                   "\\" => "\\\\",
                   "\"" => "\\\"",
                   "\n" => "\\n",
                   "\r" => "\\r",
                   "\t" => "\\t",
               ) *
               "\""
    elseif value isa Integer
        return string(value)
    elseif value isa AbstractDict
        isempty(value) && return "{}"
        body = [
            pad(level + 1) *
            json(key) *
            (indent === nothing ? ":" : ": ") *
            json(item; indent, level=level + 1) for
            (key, item) in sort!(collect(value); by=first)
        ]
        return "{" * join(body, ",") * pad(level) * "}"
    elseif value isa AbstractVector
        isempty(value) && return "[]"
        body = [pad(level + 1) * json(item; indent, level=level + 1) for item in value]
        return "[" * join(body, ",") * pad(level) * "]"
    end
    error("cannot write $(typeof(value)) as JSON")
end

"Flatten a plan into single-line workflow outputs."
outputs(result) = Dict(
    "scope" => result["scope"],
    "cells" => json(Dict("include" => result["cells"])),
    "rejected" => json(Dict("include" => result["rejected"])),
    "run_rejected" => isempty(result["rejected"]) ? "false" : "true",
    "expected_jobs" => string(result["expected_jobs"]),
)

# The workflow is read as text, because CI has no YAML parser for a plain script.

"Split julia.yml into its jobs."
function workflow_jobs(text)
    _, _, body = partition(text, "\njobs:\n")
    found = Dict{String,String}()
    for part in split(body, r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)")[2:end]
        name, _, rest = partition(part, ":")
        found[name] = rest
    end
    found
end

function partition(text, separator)
    range = findfirst(separator, text)
    range === nothing && return (text, "", "")
    (text[1:(first(range)-1)], separator, text[(last(range)+1):end])
end

"Find what julia.yml does that bypasses the plan or the aggregate."
workflow_problems(text) = hook(:workflow_problems, _workflow_problems)(text)
function _workflow_problems(text)
    problems = String[]
    jobs = workflow_jobs(text)
    for name in ("matrix", "reject", "check", "required", "tag-install")
        haskey(jobs, name) || push!(problems, "$name: missing job")
    end
    isempty(problems) || return problems
    need(condition, message) = condition || push!(problems, message)
    has(job, needle) = occursin(needle, jobs[job])
    need(
        has("check", "matrix: \${{ fromJSON(needs.matrix.outputs.cells) }}"),
        "check: the cells must come from the plan",
    )
    need(
        has("reject", "matrix: \${{ fromJSON(needs.matrix.outputs.rejected) }}"),
        "reject: the lanes must come from the plan",
    )
    need(
        has("reject", "    if: needs.matrix.outputs.run_rejected == 'true'\n"),
        "reject: it runs only where the plan schedules it",
    )
    need(
        !occursin("    if:", split(jobs["check"], "    steps:")[1]),
        "check: no leg may be skipped",
    )
    need(
        has("matrix", "scripts/plan-matrix/plan-matrix.jl plan") &&
            has("matrix", "scripts/plan-matrix/tests/runtests.jl"),
        "matrix: it must plan the run and check the plan",
    )
    need(
        has("required", "    needs: [matrix, reject, check]\n") &&
            has("required", "    if: always()\n") &&
            has("required", "MATRIX_RESULT: \${{ needs.matrix.result }}") &&
            has("required", "scripts/plan-matrix/plan-matrix.jl gate"),
        "required: it must check the planning job, the lanes and the checks",
    )
    need(has("tag-install", "    needs: check\n"), "tag-install: it follows the checks")
    need(
        has("check", "matrix.docs_artifact == 'true' && matrix.suite == 'delivery'"),
        "check: the documentation artifact comes from the cell the plan marks",
    )
    head = first(partition(text, "\njobs:\n"))
    need(
        occursin(
            "        options: ['off', before-tests, on-failure]\n        default: 'off'\n",
            head,
        ),
        "workflow_dispatch: quote 'off' in the tmate options and default, which YAML reads as the boolean false",
    )
    for name in ("scope", "tmux-ref", "julia", "threads", "suite", "tmate")
        need(
            occursin(Regex("(?m)^      $(name):\$"), head),
            "workflow_dispatch: missing the $name input",
        )
    end
    for (number, line) in enumerate(split(text, '\n'))
        occursin("inputs.", line) &&
            !occursin(r"^\s+[A-Z_]+: \$\{\{ inputs\.[a-z-]+ \}\}$", line) &&
            push!(problems, "line $number: pass an input to a script through env")
    end
    for tmux in (supported()..., REJECTED_TMUX...)
        need(
            !occursin("'$tmux'", text),
            "tmux $tmux belongs in the table, not the workflow",
        )
    end
    append!(problems, debug_session_problems(jobs))
    group = "  group: julia-\${{ github.workflow }}-\${{ github.ref }}\${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}\n"
    need(occursin(group, head), "concurrency: add github.run_id to a dispatch run's group")
    need(
        occursin("  cancel-in-progress: true\n", head),
        "concurrency: a superseded push must still be cancelled",
    )
    problems
end

const RAW_APT =
    r"(?:^|[;&|(!]\s*|\b(?:then|do|else)\s+)(?:(?:sudo(?:\s+-\S+)*|\w+=\S*)\s+)*(apt(?:-get)?)(?=\s|$)"

"List each step's run script as (line, job, step name, script)."
function run_scripts(text)
    lines = split(text, '\n')
    found = Tuple{Int,String,String,String}[]
    job = ""
    for (number, line) in enumerate(lines)
        (m = match(r"^  ([A-Za-z0-9_-]+):\s*$", line)) === nothing || (job = m.captures[1])
        key = match(r"^(\s*(?:- )?)run:\s*(.*)$", line)
        key === nothing && continue
        column = length(key.captures[1])
        first_line = key.captures[2]
        script = first_line in ("|", ">", "|-", ">-") ? String[] : [first_line]
        for follower in lines[(number+1):end]
            !isempty(strip(follower)) &&
                length(follower) - length(lstrip(follower)) < column + 1 &&
                break
            push!(script, strip(follower))
        end
        start = number
        while start > 1 && !startswith(lines[start], " "^(column - 2) * "- ")
            start -= 1
        end
        step = ""
        for each in lines[start:number]
            name = match(Regex("^\\s{$(column - 2)}(?:- |  )name:\\s*(.*)\$"), each)
            name === nothing || (step = strip(name.captures[1], ['\'', '"']))
        end
        push!(found, (number, job, step, join(script, '\n')))
    end
    found
end

"Find a run script that calls apt or apt-get itself."
raw_apt_problems(name, text) = hook(:raw_apt_problems, _raw_apt_problems)(name, text)
function _raw_apt_problems(name, text)
    problems = String[]
    for (number, job, step, script) in run_scripts(text)
        for each in split(script, '\n')
            code = strip(each)
            startswith(code, "#") && continue
            found = match(RAW_APT, code)
            found === nothing && continue
            push!(
                problems,
                "$name:$number: job $(isempty(job) ? "-" : job), step $(isempty(step) ? "unnamed" : step): raw $(found.captures[1]) call; use the libtmux/.github apt-get action",
            )
        end
    end
    problems
end

"List every workflow and composite action the repository defines."
function ci_files()
    root = dirname(dirname(@__DIR__))
    files = String[]
    for (directory, pattern) in
        ((".github/workflows", r"\.yml$"), (".github/actions", r"^action\.yml$"))
        base = joinpath(root, directory)
        isdir(base) || continue
        for (parent, _, names) in walkdir(base), name in sort(names)
            occursin(pattern, name) && push!(files, joinpath(parent, name))
        end
    end
    files
end

const TMATE = "mxschmitt/action-tmate"

"Find what makes a debugging session unsafe or misplaced."
function debug_session_problems(jobs)
    problems = String[]
    found = 0
    for (name, job) in jobs, step in split(job, r"(?m)^(?=      - )")[2:end]
        occursin(TMATE, step) || continue
        found += 1
        name == "check" ||
            push!(problems, "$name: a debugging session belongs only in the check job")
        occursin(Regex("uses: $TMATE@[0-9a-f]{40} #"), step) ||
            push!(problems, "a debugging session must be pinned to a full commit SHA")
        occursin("limit-access-to-actor: true", step) ||
            push!(problems, "a debugging session must be limited to the actor")
        occursin(r"(?m)^        timeout-minutes: \d+$", step) ||
            push!(problems, "a debugging session needs its own time limit")
        condition = match(r"(?m)^        if: (.*)$", step)
        text = condition === nothing ? "" : condition.captures[1]
        (
            occursin("github.event_name == 'workflow_dispatch'", text) &&
            occursin("matrix.tmate ==", text)
        ) || push!(
            problems,
            "a debugging session runs only on a dispatch, on the job the plan chose",
        )
    end
    found == 2 || push!(
        problems,
        "the check job must offer a debugging session before the checks and after a failure",
    )
    check = get(jobs, "check", "")
    occursin("timeout-minutes: \${{ matrix.tmate == 'off' && 20 || 50 }}", check) ||
        push!(problems, "check: the job must cap its time and give the debugging job more")
    matrix = get(jobs, "matrix", "")
    (
        occursin("TMATE: \${{ inputs.tmate }}", matrix) &&
        occursin("--tmate \"\$TMATE\"", matrix)
    ) || push!(problems, "matrix: the plan must receive the tmate input through env")
    restart = "MATRIX_JOB_DEADLINE=\$(( \$(date +%s) + 1200 ))"
    occursin(restart, last(split(check, "Debug session before the checks"))) ||
        push!(problems, "check: the work clock must restart after the session")
    problems
end

const USAGE = """
usage: plan-matrix.jl plan --event EVENT [--ref REF] [--scope SCOPE] [--tmux-ref REFS]
           [--julia VERSION] [--threads N] [--suite SUITE] [--tmate MODE]
           [--github-output FILE] [--summary FILE]
       plan-matrix.jl gate"""

function main(arguments=ARGS)
    isempty(arguments) && (println(stderr, USAGE); return 2)
    if arguments[1] == "gate"
        problems = check_needs(needs_from_environment())
        foreach(problem -> println(stderr, "gate: ", problem), problems)
        return isempty(problems) ? 0 : 1
    end
    arguments[1] == "plan" || (println(stderr, USAGE); return 2)
    names = (
        "--event",
        "--ref",
        "--scope",
        "--tmux-ref",
        "--julia",
        "--threads",
        "--suite",
        "--tmate",
        "--github-output",
        "--summary",
    )
    values = Dict{String,String}()
    rest = arguments[2:end]
    while !isempty(rest)
        (length(rest) >= 2 && rest[1] in names) || (println(stderr, USAGE); return 2)
        values[rest[1]] = rest[2]
        rest = rest[3:end]
    end
    haskey(values, "--event") || (println(stderr, USAGE); return 2)
    result = try
        plan(
            values["--event"];
            ref=get(values, "--ref", ""),
            scope=get(values, "--scope", ""),
            tmux_ref=get(values, "--tmux-ref", ""),
            julia=get(values, "--julia", ""),
            threads=get(values, "--threads", ""),
            suite=get(values, "--suite", ""),
            tmate=get(values, "--tmate", ""),
        )
    catch error
        error isa PlanError || rethrow()
        println(stderr, "plan: ", error.message)
        return 1
    end
    println(json(result; indent=2))
    if haskey(values, "--github-output")
        open(values["--github-output"], "a") do io
            for (key, value) in sort!(collect(outputs(result)); by=first)
                println(io, key, "=", value)
            end
        end
    end
    haskey(values, "--summary") &&
        open(io -> print(io, summary(result)), values["--summary"], "a")
    0
end

end

abspath(PROGRAM_FILE) == (@__FILE__) && exit(PlanMatrix.main(ARGS))
