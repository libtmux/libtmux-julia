using Test
include(joinpath(@__DIR__, "..", "plan-matrix.jl"))
using .PlanMatrix
const P = PlanMatrix

# Each rule has a check, and each check has a deliberate break: the rule is replaced
# with its absence and the check has to notice.

function refusal(; event="workflow_dispatch", inputs...)
    try
        P.plan(event; inputs...)
    catch error
        error isa P.PlanError && return error.message
        rethrow()
    end
    nothing
end
refused(match; kwargs...) =
    (message=refusal(; kwargs...); message !== nothing && occursin(Regex(match), message))

labels(result) = unique((c["tmux"], c["threads"], c["suite"]) for c in result["cells"])
versions(jobs) = unique(c["tmux"] for c in jobs)

# The full scope, which a release rests on, pinned cell by cell.
const FULL_SCOPE = [
    ("3.3a", 1, "runtime"),
    ("3.3a", 1, "delivery"),
    ("3.4", 1, "runtime"),
    ("3.5a", 1, "runtime"),
    ("3.6b", 1, "runtime"),
    ("3.7", 1, "runtime"),
    ("3.7a", 1, "runtime"),
    ("3.7b", 1, "runtime"),
    ("3.7c", 1, "runtime"),
    ("3.7c", 1, "delivery"),
    ("3.7c", 4, "runtime"),
    ("3.7c", 4, "delivery"),
    ("3.8", 1, "runtime"),
    ("3.8", 1, "delivery"),
]

needs(; matrix="success", check="success", reject="skipped", planned=false) = Dict(
    "matrix" => Dict(
        "result" => matrix,
        "outputs" => Dict("run_rejected" => planned ? "true" : "false"),
    ),
    "check" => Dict("result" => check),
    "reject" => Dict("result" => reject),
)

const BAD_REFS = [
    "3.6b;rm",
    "\$(id)",
    "a b",
    "x`id`",
    "a"^65,
    "--upload-pack=x",
    "-x",
    "a..b",
    "topic.lock",
    "topic/",
    "deadbeef",
    "é",
]

workflow_text() = read(P.WORKFLOW, String)
const BREAKS = [
    (
        "matrix: \${{ fromJSON(needs.matrix.outputs.cells) }}",
        "matrix: {tmux: ['3.8']}",
        "the cells must come from the plan",
    ),
    (
        "matrix: \${{ fromJSON(needs.matrix.outputs.rejected) }}",
        "matrix: {tmux: ['3.2a']}",
        "the lanes must come from the plan",
    ),
    ("          TIER: \${{ matrix.tier }}\n", "", "the tier must come from the plan"),
    ("          --tier \"\$TIER\"\n", "", "the tier must come from the plan"),
    (
        "if: needs.matrix.outputs.run_rejected == 'true'",
        "if: always()",
        "it runs only where the plan schedules it",
    ),
    (
        "      matrix: \${{ fromJSON(needs.matrix.outputs.cells) }}\n",
        "      matrix: \${{ fromJSON(needs.matrix.outputs.cells) }}\n    if: true\n",
        "no leg may be skipped",
    ),
    (
        "scripts/plan-matrix/tests/runtests.jl",
        "true",
        "it must plan the run and check the plan",
    ),
    (
        "    needs: [matrix, reject, check]\n",
        "    needs: [matrix, check]\n",
        "it must check the planning job, the lanes and the checks",
    ),
    (
        "scripts/plan-matrix/plan-matrix.jl gate",
        "true",
        "it must check the planning job, the lanes and the checks",
    ),
    (
        "          MATRIX_RESULT: \${{ needs.matrix.result }}\n",
        "",
        "it must check the planning job, the lanes and the checks",
    ),
    (
        "    needs: check\n    if: >-",
        "    needs: matrix\n    if: >-",
        "it follows the checks",
    ),
    (
        "matrix.docs_artifact == 'true' && matrix.suite == 'delivery'",
        "matrix.tmux == '3.7c' && matrix.suite == 'delivery'",
        "the documentation artifact comes from the cell the plan marks",
    ),
    ("      suite:\n", "      shell:\n", "missing the suite input"),
    ("      tmate:\n", "      debug:\n", "missing the tmate input"),
    (
        "        default: 'off'\n",
        "        default: off\n",
        "quote 'off' in the tmate options",
    ),
    (
        "options: ['off', before-tests, on-failure]",
        "options: [off, before-tests, on-failure]",
        "quote 'off' in the tmate options",
    ),
    (
        "\${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}",
        "",
        "add github.run_id to a dispatch run's group",
    ),
    (
        "\${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}",
        "-\${{ github.run_id }}",
        "add github.run_id to a dispatch run's group",
    ),
    (
        "  cancel-in-progress: true\n",
        "  cancel-in-progress: false\n",
        "a superseded push must still be cancelled",
    ),
    (
        "action-tmate@35b54afac29c97fb54faba5b513f8fbd1882f113 # v3.24",
        "action-tmate@v3.24 # v3.24",
        "must be pinned to a full commit SHA",
    ),
    (
        "          limit-access-to-actor: true\n",
        "          limit-access-to-actor: false\n",
        "must be limited to the actor",
    ),
    (
        "        timeout-minutes: 30\n        continue-on-error: true\n",
        "        continue-on-error: true\n",
        "needs its own time limit",
    ),
    (
        "if: github.event_name == 'workflow_dispatch' && matrix.tmate == 'before-tests'",
        "if: matrix.tmate == 'before-tests'",
        "runs only on a dispatch",
    ),
    (
        "if: failure() && github.event_name == 'workflow_dispatch' && matrix.tmate == 'on-failure'",
        "if: failure() && github.event_name == 'workflow_dispatch'",
        "on the job the plan chose",
    ),
    (
        "timeout-minutes: \${{ matrix.tmate == 'off' && 20 || 50 }}",
        "timeout-minutes: 20",
        "give the debugging job more",
    ),
    ("          TMATE: \${{ inputs.tmate }}\n", "", "receive the tmate input through env"),
    (
        "      - name: Restart the work clock after the session\n        if: matrix.tmate == 'before-tests'\n        run: echo \"MATRIX_JOB_DEADLINE=",
        "      - name: Restart the work clock after the session\n        if: matrix.tmate == 'before-tests'\n        run: echo \"MATRIX_JOB_DEADLINE_UNUSED=",
        "work clock must restart",
    ),
    (
        "--tmux-ref \"\$TMUX_REF\"",
        "--tmux-ref \"\${{ inputs.tmux-ref }}\"",
        "pass an input to a script through env",
    ),
    (
        "          ref: \${{ matrix.tmux }}\n          prefix: \${{ runner.temp }}/libtmux-julia-tmux",
        "          ref: '3.8'\n          prefix: \${{ runner.temp }}/libtmux-julia-tmux",
        "belongs in the table, not the workflow",
    ),
]

const SYNTHETIC = """
jobs:
  build:
    steps:
      - name: Raw update
        run: |
          # sudo apt-get install ignored-comment
          sudo apt-get update
      - name: Shared action
        uses: libtmux/.github/actions/apt-get@0000000000000000000000000000000000000000
        with:
          update: "true"
          args: install --yes libevent-dev
"""

@testset "which jobs a run covers" begin
    @testset "a push runs the edges only" begin
        result = P.plan("push"; ref="refs/heads/master")
        @test result["scope"] == "edges"
        @test labels(result) == [
            (P.MINIMUM_TMUX, 1, "runtime"),
            (P.MINIMUM_TMUX, 1, "delivery"),
            (P.NEWEST_TMUX, 1, "runtime"),
            (P.NEWEST_TMUX, 1, "delivery"),
            (P.NEWEST_TMUX, 4, "runtime"),
            (P.NEWEST_TMUX, 4, "delivery"),
        ]
        @test isempty(result["rejected"])
    end
    @testset "the table alone decides the edges" begin
        P.with_hooks(:SUPPORTED_TMUX => ("9.1", "9.2", "9.3"), :NEWEST_TMUX => "9.3") do
            @test versions(P.plan("push")["cells"]) == ["9.1", "9.3"]
            @test versions(P.plan("workflow_dispatch"; scope="full")["cells"]) ==
                  ["9.1", "9.2", "9.3"]
        end
    end
    @testset "a pull request and a dispatch run the edges" begin
        result = P.plan("pull_request"; ref="refs/pull/1/merge")
        @test result["scope"] == "edges" &&
              versions(result["cells"]) == [P.MINIMUM_TMUX, P.NEWEST_TMUX]
        @test isempty(result["rejected"])
        @test versions(P.plan("workflow_dispatch"; ref="refs/heads/topic")["cells"]) ==
              [P.MINIMUM_TMUX, P.NEWEST_TMUX]
    end
    @testset "full runs the whole table" begin
        for result in (
            P.plan("workflow_dispatch"; scope="full"),
            P.plan("push"; ref="refs/tags/v0.1.1"),
        )
            @test result["scope"] == "full"
            @test labels(result) == FULL_SCOPE
            @test [c["job_label"] for c in result["cells"]] == [
                "Linux-x86_64-julia1.13.1-tmux$tmux-t$threads-$suite$suffix" for
                (tmux, threads, suite) in FULL_SCOPE for
                suffix in (suite == "runtime" ? ("-unit-quality", "-outer") : ("",))
            ]
            @test length(unique(c["job_label"] for c in result["cells"])) == 24
            @test Set((c["os"], c["runner"], c["arch"]) for c in result["cells"]) ==
                  Set([("Linux", "ubuntu-24.04", "x86_64")])
            @test [c["tmux"] for c in result["rejected"]] == collect(P.REJECTED_TMUX)
        end
        @test P.plan("push"; ref="refs/tags/v0.1.1", scope="edges")["scope"] == "edges"
    end
    @testset "the documentation artifact comes from one edge job" begin
        for result in (P.plan("push"), P.plan("workflow_dispatch"; scope="full"))
            chosen = [c for c in result["cells"] if c["docs_artifact"] == "true"]
            @test [(c["tmux"], c["threads"]) for c in chosen] == fill((P.NEWEST_TMUX, 1), 3)
            @test Set(c["suite"] for c in chosen) == Set(["runtime", "delivery"])
            @test only(c for c in chosen if c["suite"] == "delivery")["tier"] == "all"
        end
        custom = P.plan("workflow_dispatch"; scope="custom", tmux_ref=P.NEWEST_TMUX)
        @test Set(c["docs_artifact"] for c in custom["cells"]) == Set(["true"])
    end
    @testset "a custom run builds the named refs" begin
        sha = "a"^40
        result = P.plan(
            "workflow_dispatch";
            scope="custom",
            tmux_ref="$(P.NEWEST_TMUX), 3.6c,master,$sha",
        )
        @test Dict(c["tmux"] => c["kind"] for c in result["cells"]) == Dict(
            P.NEWEST_TMUX => "release",
            "3.6c" => "ref",
            "master" => "ref",
            sha => "ref",
        )
        @test Dict(c["tmux"] => c["expected_tmux"] for c in result["cells"]) ==
              Dict(P.NEWEST_TMUX => P.NEWEST_TMUX, "3.6c" => "", "master" => "", sha => "")
        @test Set((c["threads"], c["suite"]) for c in result["cells"]) ==
              Set([(1, "runtime")])
        @test isempty(result["rejected"])
        @test !occursin(
            '/',
            P.plan("workflow_dispatch"; scope="custom", tmux_ref="feature/x")["cells"][1]["job_label"],
        )
    end
    @testset "inputs are refused where they cannot apply" begin
        @test refused("needs tmux-ref"; scope="custom")
        @test refused("tmux-ref is only used"; tmux_ref="3.6b")
        @test refused("tmux-ref is only used"; scope="full", tmux_ref="3.6b")
        @test refused("threads is only used"; threads="4")
        @test refused("suite is only used"; suite="both")
        @test refused("scope must be one of"; scope="everything")
        @test refused("no scope is defined"; event="schedule")
    end
    @testset "every ref is validated" begin
        for bad in BAD_REFS
            @test refusal(; scope="custom", tmux_ref="$(P.NEWEST_TMUX),$bad") !== nothing
        end
        for good in ("next-3.8", "feature/x_y.z", "a"^40, "A-b_c.1")
            @test versions(
                P.plan("workflow_dispatch"; scope="custom", tmux_ref=good)["cells"],
            ) == [good]
        end
        eight = join(("v$n" for n = 0:7), ",")
        @test length(
            P.plan("workflow_dispatch"; scope="custom", tmux_ref=eight)["cells"],
        ) == 16
        @test refused("fit one run"; scope="custom", tmux_ref=eight * ",v8")
    end
    @testset "julia, threads and suites follow the inputs" begin
        result = P.plan("workflow_dispatch"; julia="1.12.4")
        @test Set(c["julia"] for c in result["cells"]) == Set(["1.12.4"])
        @test Set(c["expected_julia"] for c in result["cells"]) == Set(["1.12.4"])
        @test occursin("julia1.12.4", result["cells"][1]["label"])
        @test Set(
            c["expected_julia"] for c in P.plan("workflow_dispatch"; julia="lts")["cells"]
        ) == Set([""])
        @test Set((c["julia"], c["expected_julia"]) for c in P.plan("push")["cells"]) ==
              Set([(P.MINIMUM_JULIA, P.MINIMUM_JULIA)])
        for bad in ("1.13.1;id", "-x", "a b", "x"^40)
            @test refused("julia .* must match"; julia=bad)
        end
        both = P.plan(
            "workflow_dispatch";
            scope="custom",
            tmux_ref="master",
            threads="4",
            suite="both",
        )
        @test [(c["threads"], c["suite"], c["tier"]) for c in both["cells"]] == [
            (4, "runtime", "unit-quality"),
            (4, "runtime", "outer"),
            (4, "delivery", "all"),
        ]
        @test [
            c["suite"] for c in P.plan(
                "workflow_dispatch";
                scope="custom",
                tmux_ref="master",
                suite="delivery",
            )["cells"]
        ] == ["delivery"]
        @test refused(
            "threads must be 1 or 4";
            scope="custom",
            tmux_ref="master",
            threads="2",
        )
        @test refused("suite must be"; scope="custom", tmux_ref="master", suite="all")
    end
    @testset "one job gets the debug session" begin
        result = P.plan(
            "workflow_dispatch";
            scope="custom",
            tmux_ref="master",
            tmate="on-failure",
        )
        @test [c["tmate"] for c in result["cells"]] == ["on-failure"]
        @test only(result["cells"])["tier"] == "all"
        @test [
            c["tmate"] for
            c in P.plan("workflow_dispatch"; scope="custom", tmux_ref="master")["cells"]
        ] == ["off", "off"]
        @test refused("exactly one job"; tmate="before-tests")
        @test refused("exactly one job"; scope="full", tmate="before-tests")
        @test refused(
            "exactly one job";
            scope="custom",
            tmux_ref="3.8,master",
            tmate="before-tests",
        )
        @test refused(
            "exactly one job";
            scope="custom",
            tmux_ref="master",
            suite="both",
            tmate="before-tests",
        )
        @test refused(
            "only available on a workflow_dispatch";
            event="push",
            scope="custom",
            tmux_ref="master",
            tmate="on-failure",
        )
        @test refused(
            "tmate must be one of";
            scope="custom",
            tmux_ref="master",
            tmate="always",
        )
    end
    @testset "the job count adds up and the matrix is never empty" begin
        @test P.plan("push")["expected_jobs"] == 11
        @test P.plan("workflow_dispatch"; scope="full")["expected_jobs"] == 30
        @test_throws P.PlanError P.require_jobs([])
    end
    @testset "the plan writes one line for each workflow output" begin
        outputs = P.outputs(P.plan("push"))
        @test !occursin('\n', outputs["cells"]) && !occursin('\n', outputs["rejected"])
        @test outputs["run_rejected"] == "false" && outputs["expected_jobs"] == "11"
        @test P.outputs(P.plan("workflow_dispatch"; scope="full"))["run_rejected"] == "true"
    end
end

@testset "the workflow follows the plan" begin
    text = workflow_text()
    @test P.workflow_problems(text) == []
    for (old, new, expected) in BREAKS
        @test occursin(old, text)
        found = P.workflow_problems(replace(text, old => new; count=1))
        @test any(problem -> occursin(expected, problem), found)
    end
    wrapped = replace(SYNTHETIC, "sudo apt-get update" => "echo update")
    @test P.raw_apt_problems("w.yml", wrapped) == []
    @test P.raw_apt_problems("w.yml", SYNTHETIC) == [
        "w.yml:5: job build, step Raw update: raw apt-get call; use the libtmux/.github apt-get action",
    ]
    inline = "jobs:\n  a:\n    steps:\n      - run: sudo -E apt install -y tmux\n"
    @test any(each -> occursin("raw apt call", each), P.raw_apt_problems("w.yml", inline))
    @test !isempty(P.ci_files())
    for path in P.ci_files()
        @test P.raw_apt_problems(basename(path), read(path, String)) == []
    end
end

@testset "the gate passes what the plan scheduled" begin
    @test P.check_needs(needs()) == []
    @test P.check_needs(needs(reject="success", planned=true)) == []
    for broken in (
        needs(matrix="failure"),
        needs(matrix="cancelled"),
        needs(check="failure"),
        needs(check="skipped"),
    )
        @test !isempty(P.check_needs(broken))
    end
    missing_check = needs()
    delete!(missing_check, "check")
    @test !isempty(P.check_needs(missing_check))
    @test !isempty(P.check_needs(needs(reject="skipped", planned=true)))
    @test !isempty(P.check_needs(needs(reject="failure", planned=true)))
    @test !isempty(P.check_needs(needs(reject="success")))
    from_environment = P.needs_from_environment(
        Dict(
            "MATRIX_RESULT" => "success",
            "MATRIX_RUN_REJECTED" => "true",
            "REJECT_RESULT" => "success",
            "CHECK_RESULT" => "success",
        ),
    )
    @test P.check_needs(from_environment) == []
    @test !isempty(
        P.check_needs(P.needs_from_environment(Dict("MATRIX_RESULT" => "success"))),
    )
end

# One deliberate break for each rule: the rule is replaced and the check that guards
# it has to fail. A check that still passes means the rule has no guard.
every_version(table) = table
hard_coded(table) = ("3.3a", "3.8")
resolving(; replaced...) =
    (event, ref, scope) -> P._resolve_scope(
        get(replaced, :event, event),
        get(replaced, :ref, ref),
        get(replaced, :scope, scope),
    )
ignored(args...; kwargs...) = nothing
always_the_table(scope; julia="", kwargs...) = P.full_cells(P.select_julia(julia))
no_thread_cell(julia) = P._edge_cells(julia)[1:(end-1)]
docs_artifact_everywhere(cells) = foreach(cell -> cell["docs_artifact"] = "true", cells)
docs_artifact_middle(cells) = foreach(
    cell ->
        cell["tmux"] == "3.7c" && cell["threads"] == 1 && (cell["docs_artifact"] = "true"),
    cells,
)
release_cell(tmux, julia, threads, suites, release) =
    P._make_cell(tmux, julia, threads, suites, true)
debug_everywhere(event, mode, jobs, rejected) = foreach(job -> job["tmate"] = mode, jobs)
debug_without_event(event, mode, jobs, rejected) =
    P._assign_tmate("workflow_dispatch", mode, jobs, rejected)
gate_without(prefix) =
    needs -> filter(problem -> !startswith(problem, prefix), P._check_needs(needs))
gate_expecting_every_lane_skipped(needs) = P._check_needs(
    merge(
        needs,
        Dict(
            "matrix" => merge(
                needs["matrix"],
                Dict("outputs" => Dict("run_rejected" => "false")),
            ),
        ),
    ),
)
gate_accepting_unplanned_runs(needs) =
    filter(problem -> !occursin("not skipped", problem), P._check_needs(needs))

@testset "each rule has a check that notices its removal" begin
    push_edges() =
        labels(P.plan("push"; ref="refs/heads/master")) == [
            (P.MINIMUM_TMUX, 1, "runtime"),
            (P.MINIMUM_TMUX, 1, "delivery"),
            (P.NEWEST_TMUX, 1, "runtime"),
            (P.NEWEST_TMUX, 1, "delivery"),
            (P.NEWEST_TMUX, 4, "runtime"),
            (P.NEWEST_TMUX, 4, "delivery"),
        ] && isempty(P.plan("push")["rejected"])
    full() =
        labels(P.plan("workflow_dispatch"; scope="full")) == FULL_SCOPE &&
        labels(P.plan("push"; ref="refs/tags/v0.1.1")) == FULL_SCOPE &&
        [c["tmux"] for c in P.plan("workflow_dispatch"; scope="full")["rejected"]] == collect(P.REJECTED_TMUX)
    edges_from_table() =
        P.with_hooks(:SUPPORTED_TMUX => ("9.1", "9.2", "9.3"), :NEWEST_TMUX => "9.3") do
            versions(P.plan("push")["cells"]) == ["9.1", "9.3"]
        end
    pull_request() =
        versions(P.plan("pull_request"; ref="refs/pull/1/merge")["cells"]) ==
        [P.MINIMUM_TMUX, P.NEWEST_TMUX]
    dispatch_edges() =
        versions(P.plan("workflow_dispatch"; ref="refs/heads/topic")["cells"]) ==
        [P.MINIMUM_TMUX, P.NEWEST_TMUX]
    scope_wins() = P.plan("push"; ref="refs/tags/x", scope="edges")["scope"] == "edges"
    docs_one() =
        [
            (c["tmux"], c["threads"]) for
            c in P.plan("push")["cells"] if c["docs_artifact"] == "true"
        ] == fill((P.NEWEST_TMUX, 1), 3)
    custom_kinds() =
        Dict(
            c["tmux"] => c["kind"] for
            c in P.plan("workflow_dispatch"; scope="custom", tmux_ref="3.6c")["cells"]
        ) == Dict("3.6c" => "ref")
    needs_refs() = refused("needs tmux-ref"; scope="custom")
    custom_only() = refused("tmux-ref is only used"; tmux_ref="3.6b")
    scope_known() = refused("scope must be one of"; scope="everything")
    event_known() = refused("no scope is defined"; event="schedule")
    refs_validated() =
        all(bad -> refusal(; scope="custom", tmux_ref="3.8,$bad") !== nothing, BAD_REFS)
    ref_limit() =
        refused("fit one run"; scope="custom", tmux_ref=join(("v$n" for n = 0:8), ","))
    julia_input() =
        P.plan("workflow_dispatch"; julia="1.12.4")["cells"][1]["julia"] == "1.12.4"
    julia_malformed() = refused("julia .* must match"; julia="1.13.1;id")
    threads_input() =
        P.plan("workflow_dispatch"; scope="custom", tmux_ref="master", threads="4")["cells"][1]["threads"] ==
        4
    threads_known() =
        refused("threads must be 1 or 4"; scope="custom", tmux_ref="master", threads="2")
    suites_input() =
        length(
            P.plan("workflow_dispatch"; scope="custom", tmux_ref="master", suite="both")["cells"],
        ) == 3
    suites_known() =
        refused("suite must be"; scope="custom", tmux_ref="master", suite="all")
    debug_one() =
        [
            c["tmate"] for c in P.plan(
                "workflow_dispatch";
                scope="custom",
                tmux_ref="master",
                tmate="on-failure",
            )["cells"]
        ] == ["on-failure"]
    debug_single() = refused("exactly one job"; tmate="before-tests")
    debug_dispatch() = refused(
        "only available on a workflow_dispatch";
        event="push",
        scope="custom",
        tmux_ref="master",
        tmate="on-failure",
    )
    debug_known() =
        refused("tmate must be one of"; scope="custom", tmux_ref="master", tmate="always")
    job_count() = P.plan("push")["expected_jobs"] == 11
    never_empty() =
        try
            P.require_jobs([])
            false
        catch error
            error isa P.PlanError
        end
    workflow() =
        P.workflow_problems(workflow_text()) == [] && all(
            ((old, new, expected),) -> any(
                problem -> occursin(expected, problem),
                P.workflow_problems(replace(workflow_text(), old => new; count=1)),
            ),
            BREAKS,
        )
    apt() = !isempty(P.raw_apt_problems("w.yml", SYNTHETIC))
    gate_lane() = !isempty(P.check_needs(needs(reject="skipped", planned=true)))
    gate_scheduled() =
        P.check_needs(needs()) == [] &&
        P.check_needs(needs(reject="success", planned=true)) == []
    gate_unplanned() = !isempty(P.check_needs(needs(reject="success")))
    gate_checks() = !isempty(P.check_needs(needs(check="failure")))
    gate_planning() = !isempty(P.check_needs(needs(matrix="failure")))

    breaks = [
        ("the edges rule takes every release", push_edges, :edge_versions => every_version),
        (
            "the edges are written into the plan",
            edges_from_table,
            :edge_versions => hard_coded,
        ),
        (
            "a pull request runs the full scope",
            pull_request,
            :resolve_scope => resolving(event="pull_request", ref="refs/tags/x"),
        ),
        (
            "a tag does not run the full scope",
            full,
            :resolve_scope => resolving(ref="refs/heads/master"),
        ),
        ("the scope input is ignored", scope_wins, :resolve_scope => resolving(scope="")),
        (
            "a dispatch does not default to the edges",
            dispatch_edges,
            :resolve_scope => resolving(scope="full"),
        ),
        (
            "an unknown scope is accepted",
            scope_known,
            :resolve_scope => resolving(scope="edges"),
        ),
        (
            "an unknown event is accepted",
            event_known,
            :resolve_scope => (event, ref, scope) -> "edges",
        ),
        ("the edges run the whole table", push_edges, :qa_cells => always_the_table),
        (
            "the edges run the refusal lanes",
            push_edges,
            :rejection_cells => scope -> P._rejection_cells("full"),
        ),
        (
            "the full scope drops the refusal lanes",
            full,
            :rejection_cells => scope -> Dict{String,Any}[],
        ),
        (
            "the delivery suite runs on every release",
            full,
            :DELIVERY_TMUX => P.SUPPORTED_TMUX,
        ),
        ("3.7c loses its delivery suite", full, :DELIVERY_TMUX => ("3.3a", "3.8")),
        (
            "the four-thread cell moves to the newest release",
            full,
            :FOUR_THREAD_TMUX => "3.8",
        ),
        ("the full scope drops the four-thread cell", full, :FOUR_THREAD_TMUX => ""),
        ("a push drops the four-thread cell", push_edges, :edge_cells => no_thread_cell),
        (
            "every job uploads the documentation",
            docs_one,
            :mark_docs_artifact => docs_artifact_everywhere,
        ),
        (
            "a middle release uploads the documentation",
            docs_one,
            :mark_docs_artifact => docs_artifact_middle,
        ),
        ("no job uploads the documentation", docs_one, :mark_docs_artifact => ignored),
        ("a custom ref is taken for a release", custom_kinds, :make_cell => release_cell),
        (
            "a custom run without refs is planned",
            needs_refs,
            :custom_refs => ref -> P.split_list(ref),
        ),
        (
            "inputs the scope ignores are accepted",
            custom_only,
            :check_scope_inputs => ignored,
        ),
        ("a ref is not validated", refs_validated, :check_ref => item -> item),
        ("the ref count is unlimited", ref_limit, :MAX_REFS => 1000),
        (
            "the julia input is ignored",
            julia_input,
            :select_julia => requested -> P.MINIMUM_JULIA,
        ),
        (
            "a malformed julia is accepted",
            julia_malformed,
            :select_julia =>
                requested -> isempty(requested) ? P.MINIMUM_JULIA : requested,
        ),
        ("the threads input is ignored", threads_input, :select_threads => requested -> 1),
        (
            "an unknown threads value is accepted",
            threads_known,
            :select_threads =>
                requested -> parse(Int, isempty(requested) ? "1" : requested),
        ),
        (
            "the suite input is ignored",
            suites_input,
            :select_suites => requested -> ("runtime",),
        ),
        (
            "an unknown suite is accepted",
            suites_known,
            :select_suites =>
                requested -> requested == "both" ? P.SUITES : ("runtime",),
        ),
        ("no job gets the debug session", debug_one, :assign_tmate => ignored),
        (
            "every job gets the debug session",
            debug_single,
            :assign_tmate => debug_everywhere,
        ),
        (
            "the debug session runs outside a dispatch",
            debug_dispatch,
            :assign_tmate => debug_without_event,
        ),
        ("an unknown debug mode is accepted", debug_known, :assign_tmate => ignored),
        ("the job count omits the fixed jobs", job_count, :FIXED_JOBS => 0),
        ("an empty plan is accepted", never_empty, :require_jobs => ignored),
        ("the workflow is not checked", workflow, :workflow_problems => text -> String[]),
        (
            "raw apt-get calls are accepted",
            apt,
            :raw_apt_problems => (name, text) -> String[],
        ),
        (
            "the gate ignores the refusal lane",
            gate_lane,
            :check_needs => gate_without("reject"),
        ),
        (
            "the gate expects every lane skipped",
            gate_scheduled,
            :check_needs => gate_expecting_every_lane_skipped,
        ),
        (
            "the gate lets an unplanned lane run",
            gate_unplanned,
            :check_needs => gate_accepting_unplanned_runs,
        ),
        ("the gate ignores the checks", gate_checks, :check_needs => gate_without("check")),
        (
            "the gate ignores the planning job",
            gate_planning,
            :check_needs => gate_without("matrix"),
        ),
    ]
    # The checks pass with every rule in place, then each break has to turn one red.
    for (_, guard, _) in breaks
        @test guard()
    end
    for (description, guard, replacement) in breaks
        broken = P.with_hooks(replacement) do
            try
                guard() === false
            catch
                true
            end
        end
        @test broken
        broken || @info "check passed with its rule removed: $description"
    end
end

@testset "the command line writes the plan and the gate reports" begin
    mktempdir() do directory
        output, summary = joinpath(directory, "output"), joinpath(directory, "summary")
        buffer = IOBuffer()
        status = redirect_stdout(
            () -> P.main([
                "plan",
                "--event",
                "push",
                "--github-output",
                output,
                "--summary",
                summary,
            ]),
            devnull,
        )
        @test status == 0
        lines = readlines(output)
        @test any(startswith("scope=edges"), lines) &&
              any(startswith("run_rejected=false"), lines)
        @test occursin("tmux plan: edges", read(summary, String))
        @test redirect_stderr(() -> P.main(["plan", "--event", "schedule"]), devnull) == 1
        @test redirect_stderr(() -> P.main(["plan"]), devnull) == 2
    end
    withenv(
        "MATRIX_RESULT" => "success",
        "MATRIX_RUN_REJECTED" => "false",
        "REJECT_RESULT" => "skipped",
        "CHECK_RESULT" => "success",
    ) do
        @test P.main(["gate"]) == 0
    end
    withenv(
        "MATRIX_RESULT" => "success",
        "MATRIX_RUN_REJECTED" => "true",
        "REJECT_RESULT" => "skipped",
        "CHECK_RESULT" => "success",
    ) do
        @test redirect_stderr(() -> P.main(["gate"]), devnull) == 1
    end
end
