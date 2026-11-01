#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Plan which tmux releases and jobs a Julia CI run covers.

Every push and pull request ran the whole tmux table, although the oldest and
newest release bracket what the rest do. This module holds the table and decides
what a run covers, so the workflow lists no version.

Scopes:

- `edges`: the oldest and newest supported release. The default for a push, a
  pull request and a dispatch.
- `full`: the whole table and the refusal lanes. A release tag, and a dispatch
  that asks.
- `custom`: only the tmux versions, tags, branches or commits a dispatch names.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any, NotRequired, TypedDict
from unittest import mock

# Supported releases, oldest first. The first is the floor and the last the
# newest; tmux_ref.py builds neither, they come from the official tarballs
# whose digests check-matrix.py pins.
SUPPORTED_TMUX = ("3.3a", "3.4", "3.5a", "3.6b", "3.7", "3.7a", "3.7b", "3.7c", "3.8")
# Releases below the supported floor. Their cells assert refusal without effect
# and stay outside the supported matrix.
REJECTED_TMUX = ("3.0a", "3.1c", "3.2a", "3.3")
# Releases whose daemon answers a current client with a protocol mismatch or a
# usage error; their cells run the real-build refusal test in place of the
# owned-daemon rejection suite.
PRE_PROBE_TMUX = ("3.0a", "3.1c")
MINIMUM_TMUX = SUPPORTED_TMUX[0]
NEWEST_TMUX = SUPPORTED_TMUX[-1]
# The full scope runs the delivery suite, which does not depend on the release,
# at the floor, at 3.7c and at the newest release, and runs 3.7c at four threads
# as well. A push and a pull request run the edges instead.
DELIVERY_TMUX = ("3.3a", "3.7c", "3.8")
FOUR_THREAD_TMUX = "3.7c"
MINIMUM_JULIA = "1.13.1"
SUITES = ("runtime", "delivery")

WORKFLOW = (
    Path(__file__).resolve().parent.parent / ".github" / "workflows" / "julia.yml"
)

SCOPES = ("edges", "full", "custom")
TMATE_MODES = ("off", "before-tests", "on-failure")
EVENTS = ("push", "pull_request", "workflow_dispatch")

# Every item of `tmux-ref` is checked against this before it reaches a shell
# or a git command.
REF_PATTERN = re.compile(r"^[A-Za-z0-9._/-]{1,64}$")
ABBREVIATED_SHA = re.compile(r"^[0-9a-f]{7,39}$")
JULIA_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,31}$")
EXACT_JULIA = re.compile(r"^\d+\.\d+\.\d+$")

# A mistyped list should fail rather than fan out into a huge matrix.
MAX_REFS = 8

# The planning job and the aggregate, which every run has.
FIXED_JOBS = 2


class PlanError(ValueError):
    """The inputs name a run that cannot or must not happen."""


class QaCell(TypedDict):
    label: str
    os: str
    runner: str
    arch: str
    julia: str
    tmux: str
    threads: int
    suites: tuple[str, ...]
    status: str
    kind: str
    expected_julia: str
    expected_tmux: str
    docs_artifact: str
    tmate: str
    suite: NotRequired[str]
    job_label: NotRequired[str]


def split_list(value: str) -> list[str]:
    """Split a comma-separated input, dropping blanks and repeats."""
    items: list[str] = []
    for each in value.split(","):
        item = each.strip()
        if item and item not in items:
            items.append(item)
    return items


def resolve_scope(event: str, ref: str, scope: str) -> str:
    """Decide how much of the table a run covers."""
    if scope:
        if scope not in SCOPES:
            raise PlanError(f"scope must be one of {', '.join(SCOPES)}, not {scope!r}")
        return scope
    if ref.startswith("refs/tags/"):
        return "full"
    if event in EVENTS:
        return "edges"
    raise PlanError(f"no scope is defined for the {event!r} event")


def edge_versions(supported: tuple[str, ...]) -> tuple[str, ...]:
    """Pick the oldest and the newest supported release."""
    return tuple(dict.fromkeys([*supported[:1], *supported[-1:]]))


def check_scope_inputs(scope: str, **given: str) -> None:
    """Refuse inputs that only a custom run reads, so none is silently ignored."""
    for name, value in given.items():
        if value and scope != "custom":
            raise PlanError(f"{name} is only used with scope custom")


def require_jobs(jobs: list[QaCell]) -> None:
    """Refuse a plan with no job, which GitHub would reject anyway."""
    if not jobs:
        raise PlanError("the plan has no job")


def check_ref(item: str) -> str:
    """Refuse a tmux ref that is malformed or could be read as an option."""
    if not REF_PATTERN.fullmatch(item):
        raise PlanError(f"tmux-ref item {item!r} must match {REF_PATTERN.pattern}")
    if item.startswith("-") or ".." in item or item.endswith((".lock", "/")):
        raise PlanError(f"tmux-ref item {item!r} is not a usable git ref")
    if ABBREVIATED_SHA.fullmatch(item):
        raise PlanError(
            f"tmux-ref item {item!r} looks like an abbreviated commit; "
            "give the full 40-hex SHA"
        )
    return item


def custom_refs(tmux_ref: str) -> list[str]:
    """Validate the refs a custom run was asked to build."""
    items = split_list(tmux_ref)
    if not items:
        raise PlanError(
            "scope custom needs tmux-ref, a comma-separated list of tmux refs"
        )
    if len(items) > MAX_REFS:
        raise PlanError(
            f"tmux-ref names {len(items)} refs; at most {MAX_REFS} fit one run"
        )
    return [check_ref(item) for item in items]


def select_julia(requested: str) -> str:
    """Take the Julia version a dispatch asks for, or the normal one."""
    if not requested:
        return MINIMUM_JULIA
    if not JULIA_PATTERN.fullmatch(requested):
        raise PlanError(f"julia {requested!r} must match {JULIA_PATTERN.pattern}")
    return requested


def select_threads(requested: str) -> int:
    """Take the thread count a custom run asks for, or one thread."""
    if requested not in ("", "1", "4"):
        raise PlanError(f"threads must be 1 or 4, not {requested!r}")
    return int(requested or "1")


def select_suites(requested: str) -> tuple[str, ...]:
    """Take the suites a custom run asks for, or the runtime suite alone."""
    if requested in ("", "runtime"):
        return ("runtime",)
    if requested == "delivery":
        return ("delivery",)
    if requested == "both":
        return SUITES
    raise PlanError(f"suite must be runtime, delivery or both, not {requested!r}")


def make_cell(
    tmux: str, julia: str, threads: int, suites: tuple[str, ...], release: bool
) -> QaCell:
    """Describe one platform cell.

    A release is built from its official tarball and its `tmux -V` must match.
    Anything else is resolved to a commit and built from source, and has no
    version to assert.
    """
    slug = tmux.replace("/", "-")
    return {
        "label": f"Linux-x86_64-julia{julia}-tmux{slug}-t{threads}",
        "os": "Linux",
        "runner": "ubuntu-24.04",
        "arch": "x86_64",
        "julia": julia,
        "tmux": tmux,
        "threads": threads,
        "suites": suites,
        "status": "NOT RUN",
        "kind": "release" if release else "ref",
        "expected_julia": julia if EXACT_JULIA.fullmatch(julia) else "",
        "expected_tmux": tmux if release else "",
        "docs_artifact": "false",
        "tmate": "off",
    }


def full_cells(julia: str) -> list[QaCell]:
    """Plan the cells of the whole table.

    Every release runs the runtime suite at one thread. The delivery suite
    does not depend on the release, so it runs at the floor, at 3.7c and at the
    newest release, and 3.7c also runs at four threads.
    """
    cells: list[QaCell] = []
    for tmux in SUPPORTED_TMUX:
        suites = SUITES if tmux in DELIVERY_TMUX else ("runtime",)
        cells.append(make_cell(tmux, julia, 1, suites, True))
        if tmux == FOUR_THREAD_TMUX:
            cells.append(make_cell(tmux, julia, 4, SUITES, True))
    return cells


def edge_cells(julia: str) -> list[QaCell]:
    """Plan the cells of a push: the oldest and newest release.

    Both run the runtime and delivery suites at one thread. The thread axis is
    part of the stack, which a push keeps, so the newest release also runs at
    four threads.
    """
    cells = [
        make_cell(tmux, julia, 1, SUITES, True)
        for tmux in edge_versions(SUPPORTED_TMUX)
    ]
    cells.append(make_cell(NEWEST_TMUX, julia, 4, SUITES, True))
    return cells


def mark_docs_artifact(cells: list[QaCell]) -> None:
    """Upload the documentation artifact from the newest release at one thread.

    The artifact does not depend on the tmux release, so it comes from an edge
    cell, which every scope of the table runs; it is uploaded once.
    """
    for cell in cells:
        if cell["tmux"] == NEWEST_TMUX and cell["threads"] == 1:
            cell["docs_artifact"] = "true"


def custom_cells(
    refs: list[str], julia: str, threads: int, suites: tuple[str, ...]
) -> list[QaCell]:
    """Plan one cell for each ref a dispatch names."""
    known = (*SUPPORTED_TMUX, *REJECTED_TMUX)
    return [make_cell(item, julia, threads, suites, item in known) for item in refs]


def qa_cells(
    scope: str = "full",
    *,
    tmux_ref: str = "",
    julia: str = "",
    threads: str = "",
    suite: str = "",
) -> list[QaCell]:
    """Plan the platform cells of a run."""
    version = select_julia(julia)
    if scope == "custom":
        cells = custom_cells(
            custom_refs(tmux_ref),
            version,
            select_threads(threads),
            select_suites(suite),
        )
    elif scope == "edges":
        cells = edge_cells(version)
    else:
        cells = full_cells(version)
    mark_docs_artifact(cells)
    return cells


def split_cells(cells: list[QaCell]) -> list[QaCell]:
    """Emit one job for each suite of every cell."""
    return [
        {**cell, "suite": suite, "job_label": f"{cell['label']}-{suite}"}
        for cell in cells
        for suite in cell["suites"]
    ]


def rejection_cells(scope: str = "full") -> list[dict[str, str]]:
    """Plan the refusal lanes, which only the whole table runs."""
    if scope != "full":
        return []
    return [
        {
            "label": f"Linux-x86_64-julia{MINIMUM_JULIA}-tmux{tmux}-rejection",
            "tmux": tmux,
            "job_label": f"Reject tmux {tmux}",
            "real_old": "true" if tmux in PRE_PROBE_TMUX else "false",
            "suite": "old-daemon" if tmux in PRE_PROBE_TMUX else "rejection",
        }
        for tmux in REJECTED_TMUX
    ]


def assign_tmate(
    event: str, mode: str, jobs: list[QaCell], rejected: list[dict[str, str]]
) -> None:
    """Give exactly one job the debug session, or fail."""
    if mode not in TMATE_MODES:
        raise PlanError(f"tmate must be one of {', '.join(TMATE_MODES)}, not {mode!r}")
    if mode == "off":
        return
    if event != "workflow_dispatch":
        raise PlanError("tmate is only available on a workflow_dispatch run")
    legs = len(jobs) + len(rejected)
    if legs != 1:
        raise PlanError(
            f"tmate needs exactly one job and this run has {legs}; use scope custom "
            "with one tmux-ref and the default suite"
        )
    jobs[0]["tmate"] = mode


def plan(
    event: str,
    *,
    ref: str = "",
    scope: str = "",
    tmux_ref: str = "",
    julia: str = "",
    threads: str = "",
    suite: str = "",
    tmate: str = "",
) -> dict[str, Any]:
    """Return the jobs, the refusal lanes and the job count for one run."""
    chosen = resolve_scope(event, ref, scope)
    check_scope_inputs(
        chosen, **{"tmux-ref": tmux_ref, "threads": threads, "suite": suite}
    )
    jobs = split_cells(
        qa_cells(chosen, tmux_ref=tmux_ref, julia=julia, threads=threads, suite=suite)
    )
    require_jobs(jobs)
    rejected = rejection_cells(chosen)
    assign_tmate(event, tmate or "off", jobs, rejected)
    return {
        "scope": chosen,
        "cells": jobs,
        "rejected": rejected,
        "expected_jobs": FIXED_JOBS + len(jobs) + len(rejected),
    }


def check_needs(needs: dict[str, Any]) -> list[str]:
    """Find the jobs that stop the aggregate from passing.

    The planning job and the checks must succeed. The refusal lanes must
    succeed when the plan scheduled them and be skipped when it left them out,
    so a skipped lane that was planned cannot pass.
    """
    problems = []
    for job in ("matrix", "check"):
        result = needs.get(job, {}).get("result")
        if result != "success":
            problems.append(f"{job} finished {result or 'missing'}, not success")
    planned = needs.get("matrix", {}).get("outputs", {}).get("run_rejected") == "true"
    wanted = "success" if planned else "skipped"
    result = needs.get("reject", {}).get("result")
    if result != wanted:
        problems.append(f"reject finished {result or 'missing'}, not {wanted}")
    return problems


def summary(result: dict[str, Any]) -> str:
    """Describe a plan for the job summary."""
    lines = [
        f"### tmux plan: {result['scope']}",
        "",
        f"Expected jobs in this workflow: {result['expected_jobs']}",
        "",
    ]
    lines += [
        f"- Julia {each['julia']} with tmux {each['tmux']}, {each['threads']} thread(s), "
        f"{each['suite']} suite ({each['kind']})"
        for each in result["cells"]
    ]
    lines += [f"- tmux {each['tmux']} is refused" for each in result["rejected"]]
    return "\n".join(lines) + "\n"


def compact(value: object) -> str:
    """Write JSON on one line, as a workflow output needs."""
    return json.dumps(value, separators=(",", ":"))


def outputs(result: dict[str, Any]) -> dict[str, str]:
    """Flatten a plan into single-line workflow outputs."""
    return {
        "scope": result["scope"],
        "cells": compact({"include": result["cells"]}),
        "rejected": compact({"include": result["rejected"]}),
        "run_rejected": "true" if result["rejected"] else "false",
        "expected_jobs": str(result["expected_jobs"]),
    }


def workflow_jobs(text: str) -> dict[str, str]:
    """Split julia.yml into its jobs, read as text because CI has no YAML parser."""
    _, _, body = text.partition("\njobs:\n")
    found: dict[str, str] = {}
    for part in re.split(r"(?m)^  (?=[A-Za-z0-9_-]+:\s*$)", body)[1:]:
        name, _, rest = part.partition(":")
        found[name] = rest
    return found


def workflow_problems(text: str) -> list[str]:
    """Find what julia.yml does that bypasses the plan or the aggregate."""
    problems: list[str] = []
    jobs = workflow_jobs(text)
    for name in ("matrix", "reject", "check", "required", "tag-install"):
        if name not in jobs:
            problems.append(f"{name}: missing job")
    if problems:
        return problems

    def need(condition: bool, message: str) -> None:
        if not condition:
            problems.append(message)

    need(
        "matrix: ${{ fromJSON(needs.matrix.outputs.cells) }}" in jobs["check"],
        "check: the cells must come from the plan",
    )
    need(
        "matrix: ${{ fromJSON(needs.matrix.outputs.rejected) }}" in jobs["reject"],
        "reject: the lanes must come from the plan",
    )
    need(
        "    if: needs.matrix.outputs.run_rejected == 'true'\n" in jobs["reject"],
        "reject: it runs only where the plan schedules it",
    )
    need(
        "    if:" not in jobs["check"].split("    steps:")[0],
        "check: no leg may be skipped",
    )
    need(
        "python3 dev/plan_matrix.py plan" in jobs["matrix"]
        and "python3 dev/plan_matrix.py self-test" in jobs["matrix"],
        "matrix: it must plan the run and check the plan",
    )
    need(
        "    needs: [matrix, reject, check]\n" in jobs["required"]
        and "    if: always()\n" in jobs["required"]
        and "NEEDS: ${{ toJSON(needs) }}" in jobs["required"]
        and "python3 dev/plan_matrix.py gate" in jobs["required"],
        "required: it must check the planning job, the lanes and the checks",
    )
    need(
        "    needs: check\n" in jobs["tag-install"],
        "tag-install: it follows the checks",
    )
    need(
        "matrix.docs_artifact == 'true' && matrix.suite == 'delivery'" in jobs["check"],
        "check: the documentation artifact comes from the cell the plan marks",
    )
    head = text.partition("\njobs:\n")[0]
    need(
        "        options: ['off', before-tests, on-failure]\n        default: 'off'\n"
        in head,
        "workflow_dispatch: quote 'off' in the tmate options and default, "
        "which YAML reads as the boolean false",
    )
    for name in ("scope", "tmux-ref", "julia", "threads", "suite", "tmate"):
        need(
            re.search(rf"(?m)^      {re.escape(name)}:$", head) is not None,
            f"workflow_dispatch: missing the {name} input",
        )
    for number, line in enumerate(text.splitlines(), 1):
        if "inputs." in line and not re.match(
            r"^\s+[A-Z_]+: \$\{\{ inputs\.[a-z-]+ \}\}$", line
        ):
            problems.append(f"line {number}: pass an input to a script through env")
    for tmux in (*SUPPORTED_TMUX, *REJECTED_TMUX):
        need(
            f"'{tmux}'" not in text,
            f"tmux {tmux} belongs in the table, not the workflow",
        )
    problems += debug_session_problems(jobs)
    group = (
        "  group: julia-${{ github.workflow }}-${{ github.ref }}"
        "${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}\n"
    )
    need(group in head, "concurrency: add github.run_id to a dispatch run's group")
    need(
        "  cancel-in-progress: true\n" in head,
        "concurrency: a superseded push must still be cancelled",
    )
    return problems


RAW_APT = re.compile(
    r"(?:^|[;&|(!]\s*|\b(?:then|do|else)\s+)"
    r"(?:(?:sudo(?:\s+-\S+)*|\w+=\S*)\s+)*(apt(?:-get)?)(?=\s|$)"
)
ROOT = Path(__file__).resolve().parent.parent


def run_scripts(text: str) -> list[tuple[int, str, str, str]]:
    """List each step's run script as (line, job, step name, script), read as text."""
    lines = text.splitlines()
    found: list[tuple[int, str, str, str]] = []
    job = ""
    for number, line in enumerate(lines):
        if match := re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line):
            job = match.group(1)
        key = re.match(r"^(\s*(?:- )?)run:\s*(.*)$", line)
        if not key:
            continue
        column = len(key.group(1))
        script = [key.group(2)] if key.group(2) not in ("|", ">", "|-", ">-") else []
        rest = lines[number + 1 :]
        for follower in rest:
            if follower.strip() and len(follower) - len(follower.lstrip()) < column + 1:
                break
            script.append(follower.strip())
        start = number
        while start > 0 and not lines[start].startswith(" " * (column - 2) + "- "):
            start -= 1
        step = ""
        for each in lines[start : number + 1]:
            if name := re.match(rf"^\s{{{column - 2}}}(?:- |  )name:\s*(.*)$", each):
                step = name.group(1).strip("'\"")
        found.append((number + 1, job, step, "\n".join(script)))
    return found


def raw_apt_problems(name: str, text: str) -> list[str]:
    """Find a run script that calls apt or apt-get outside dev/apt-get.sh."""
    problems: list[str] = []
    for number, job, step, script in run_scripts(text):
        for each in script.splitlines():
            code = each.strip()
            if code.startswith("#"):
                continue
            if match := RAW_APT.search(code):
                problems.append(
                    f"{name}:{number}: job {job or '-'}, step {step or 'unnamed'}: "
                    f"raw {match.group(1)} call; "
                    "run it through dev/apt-get.sh"
                )
    return problems


def ci_files() -> list[Path]:
    """List every workflow and composite action the repository defines."""
    return [
        *sorted((ROOT / ".github" / "workflows").glob("*.yml")),
        *sorted((ROOT / ".github" / "actions").glob("*/action.yml")),
    ]


TMATE = "mxschmitt/action-tmate"


def debug_session_problems(jobs: dict[str, str]) -> list[str]:
    """Find what makes a debugging session unsafe or misplaced."""
    problems: list[str] = []
    found = 0
    for name, job in jobs.items():
        for step in re.split(r"(?m)^(?=      - )", job)[1:]:
            if TMATE not in step:
                continue
            found += 1
            if name != "check":
                problems.append(
                    f"{name}: a debugging session belongs only in the check job"
                )
            if not re.search(rf"uses: {TMATE}@[0-9a-f]{{40}} #", step):
                problems.append(
                    "a debugging session must be pinned to a full commit SHA"
                )
            if "limit-access-to-actor: true" not in step:
                problems.append("a debugging session must be limited to the actor")
            if not re.search(r"(?m)^        timeout-minutes: \d+$", step):
                problems.append("a debugging session needs its own time limit")
            condition = re.search(r"(?m)^        if: (.*)$", step)
            text = condition.group(1) if condition else ""
            if "github.event_name == 'workflow_dispatch'" not in text or (
                "matrix.tmate ==" not in text
            ):
                problems.append(
                    "a debugging session runs only on a dispatch, on the job the plan chose"
                )
    if found != 2:
        problems.append(
            "the check job must offer a debugging session before the checks and after a failure"
        )
    check = jobs.get("check", "")
    if "timeout-minutes: ${{ matrix.tmate == 'off' && 20 || 50 }}" not in check:
        problems.append(
            "check: the job must cap its time and give the debugging job more"
        )
    if "TMATE: ${{ inputs.tmate }}" not in jobs.get("matrix", "") or (
        '--tmate "$TMATE"' not in jobs.get("matrix", "")
    ):
        problems.append("matrix: the plan must receive the tmate input through env")
    restart = "MATRIX_JOB_DEADLINE=$(( $(date +%s) + 1200 ))"
    if restart not in check.split("Debug session before the checks")[-1]:
        problems.append("check: the work clock must restart after the session")
    return problems


# Checks. Each rule has one, and each check has a deliberate break: the rule is
# replaced with its absence and the check has to notice.

Check = Callable[[], None]


def versions_of(jobs: list[QaCell]) -> list[str]:
    return list(dict.fromkeys(each["tmux"] for each in jobs))


def refused(match: str, event: str = "workflow_dispatch", **inputs: str) -> None:
    try:
        plan(event, **inputs)
    except PlanError as error:
        assert re.search(match, str(error)), (match, str(error))
        return
    raise AssertionError(f"the plan was not refused: {match}")


def labels(result: dict[str, Any]) -> list[tuple[str, int, str]]:
    return [(each["tmux"], each["threads"], each["suite"]) for each in result["cells"]]


def check_push_runs_the_edges_only() -> None:
    result = plan("push", ref="refs/heads/master")
    assert result["scope"] == "edges"
    assert labels(result) == [
        (MINIMUM_TMUX, 1, "runtime"),
        (MINIMUM_TMUX, 1, "delivery"),
        (NEWEST_TMUX, 1, "runtime"),
        (NEWEST_TMUX, 1, "delivery"),
        (NEWEST_TMUX, 4, "runtime"),
        (NEWEST_TMUX, 4, "delivery"),
    ]
    assert result["rejected"] == []


def check_the_table_alone_decides_the_edges() -> None:
    table = ("9.1", "9.2", "9.3")
    with mock.patch.multiple(
        sys.modules[__name__], SUPPORTED_TMUX=table, NEWEST_TMUX="9.3"
    ):
        assert versions_of(plan("push")["cells"]) == ["9.1", "9.3"]
        full = plan("workflow_dispatch", scope="full")
        assert versions_of(full["cells"]) == list(table)


def check_pull_request_runs_the_edges_only() -> None:
    result = plan("pull_request", ref="refs/pull/1/merge")
    assert result["scope"] == "edges"
    assert versions_of(result["cells"]) == [MINIMUM_TMUX, NEWEST_TMUX]
    assert result["rejected"] == []


def check_dispatch_defaults_to_the_edges() -> None:
    assert versions_of(plan("workflow_dispatch", ref="refs/heads/topic")["cells"]) == [
        MINIMUM_TMUX,
        NEWEST_TMUX,
    ]


# The full scope as it was before pushes moved to the edges. A release rests on
# it, so it is pinned cell by cell: dropping, adding or moving one is a change
# this list has to show.
FULL_SCOPE = (
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
)


def check_full_runs_the_whole_table() -> None:
    for result in (
        plan("workflow_dispatch", scope="full"),
        plan("push", ref="refs/tags/v0.1.1"),
    ):
        assert result["scope"] == "full"
        assert labels(result) == list(FULL_SCOPE)
        assert [each["job_label"] for each in result["cells"]] == [
            f"Linux-x86_64-julia1.13.1-tmux{tmux}-t{threads}-{suite}"
            for tmux, threads, suite in FULL_SCOPE
        ]
        assert {
            (each["os"], each["runner"], each["arch"]) for each in result["cells"]
        } == {("Linux", "ubuntu-24.04", "x86_64")}
        assert [each["tmux"] for each in result["rejected"]] == list(REJECTED_TMUX)


def check_a_scope_input_wins_over_a_tag() -> None:
    assert plan("push", ref="refs/tags/v0.1.1", scope="edges")["scope"] == "edges"


def check_the_documentation_artifact_comes_from_one_edge_job() -> None:
    for result in (plan("push"), plan("workflow_dispatch", scope="full")):
        chosen = [each for each in result["cells"] if each["docs_artifact"] == "true"]
        assert [(each["tmux"], each["threads"]) for each in chosen] == [
            (NEWEST_TMUX, 1)
        ] * 2
        assert {each["suite"] for each in chosen} == {"runtime", "delivery"}
    custom = plan("workflow_dispatch", scope="custom", tmux_ref=NEWEST_TMUX)
    assert {each["docs_artifact"] for each in custom["cells"]} == {"true"}


def check_custom_builds_the_named_refs() -> None:
    sha = "a" * 40
    result = plan(
        "workflow_dispatch",
        scope="custom",
        tmux_ref=f"{NEWEST_TMUX}, 3.6c,master,{sha}",
    )
    kinds = {each["tmux"]: each["kind"] for each in result["cells"]}
    assert kinds == {NEWEST_TMUX: "release", "3.6c": "ref", "master": "ref", sha: "ref"}
    expected = {each["tmux"]: each["expected_tmux"] for each in result["cells"]}
    assert expected == {NEWEST_TMUX: NEWEST_TMUX, "3.6c": "", "master": "", sha: ""}
    assert {(each["threads"], each["suite"]) for each in result["cells"]} == {
        (1, "runtime")
    }
    assert result["rejected"] == []
    slashed = plan("workflow_dispatch", scope="custom", tmux_ref="feature/x")
    assert "/" not in slashed["cells"][0]["job_label"]


def check_a_custom_run_needs_refs() -> None:
    refused("needs tmux-ref", scope="custom")


def check_inputs_a_custom_run_reads_need_the_custom_scope() -> None:
    refused("tmux-ref is only used", tmux_ref="3.6b")
    refused("tmux-ref is only used", scope="full", tmux_ref="3.6b")
    refused("threads is only used", threads="4")
    refused("suite is only used", suite="both")


def check_a_scope_must_be_known() -> None:
    refused("scope must be one of", scope="everything")


def check_an_unknown_event_is_refused() -> None:
    refused("no scope is defined", event="schedule")


BAD_REFS = (
    "3.6b;rm",
    "$(id)",
    "a b",
    "x`id`",
    "a" * 65,
    "--upload-pack=x",
    "-x",
    "a..b",
    "topic.lock",
    "topic/",
    "deadbeef",
    "é",
)


def check_every_ref_is_validated() -> None:
    for bad in BAD_REFS:
        try:
            plan("workflow_dispatch", scope="custom", tmux_ref=f"{NEWEST_TMUX},{bad}")
        except PlanError:
            continue
        raise AssertionError(f"accepted {bad!r}")
    for good in ("next-3.8", "feature/x_y.z", "a" * 40, "A-b_c.1"):
        result = plan("workflow_dispatch", scope="custom", tmux_ref=good)
        assert versions_of(result["cells"]) == [good]


def check_too_many_refs_are_refused() -> None:
    eight = ",".join(f"v{n}" for n in range(8))
    assert len(plan("workflow_dispatch", scope="custom", tmux_ref=eight)["cells"]) == 8
    refused("fit one run", scope="custom", tmux_ref=eight + ",v8")


def check_a_julia_input_replaces_the_version() -> None:
    result = plan("workflow_dispatch", julia="1.12.4")
    assert {each["julia"] for each in result["cells"]} == {"1.12.4"}
    assert {each["expected_julia"] for each in result["cells"]} == {"1.12.4"}
    assert "julia1.12.4" in result["cells"][0]["label"]
    channel = plan("workflow_dispatch", julia="lts")
    assert {each["expected_julia"] for each in channel["cells"]} == {""}
    normal = plan("push")
    assert {(each["julia"], each["expected_julia"]) for each in normal["cells"]} == {
        (MINIMUM_JULIA, MINIMUM_JULIA)
    }


def check_a_malformed_julia_is_refused() -> None:
    for bad in ("1.13.1;id", "-x", "a b", "x" * 40):
        refused("julia .* must match", julia=bad)


def check_a_custom_run_can_choose_threads_and_suites() -> None:
    both = plan(
        "workflow_dispatch",
        scope="custom",
        tmux_ref="master",
        threads="4",
        suite="both",
    )
    assert [(each["threads"], each["suite"]) for each in both["cells"]] == [
        (4, "runtime"),
        (4, "delivery"),
    ]
    delivery = plan(
        "workflow_dispatch", scope="custom", tmux_ref="master", suite="delivery"
    )
    assert [each["suite"] for each in delivery["cells"]] == ["delivery"]


def check_unknown_threads_and_suites_are_refused() -> None:
    refused("threads must be 1 or 4", scope="custom", tmux_ref="master", threads="2")
    refused("suite must be", scope="custom", tmux_ref="master", suite="all")


def check_one_job_gets_the_debug_session() -> None:
    result = plan(
        "workflow_dispatch", scope="custom", tmux_ref="master", tmate="on-failure"
    )
    assert [each["tmate"] for each in result["cells"]] == ["on-failure"]


def check_no_debug_session_by_default() -> None:
    result = plan("workflow_dispatch", scope="custom", tmux_ref="master")
    assert [each["tmate"] for each in result["cells"]] == ["off"]


def check_several_jobs_cannot_share_a_debug_session() -> None:
    refused("exactly one job", tmate="before-tests")
    refused("exactly one job", scope="full", tmate="before-tests")
    refused(
        "exactly one job", scope="custom", tmux_ref="3.8,master", tmate="before-tests"
    )
    refused(
        "exactly one job",
        scope="custom",
        tmux_ref="master",
        suite="both",
        tmate="before-tests",
    )


def check_a_debug_session_needs_a_dispatch() -> None:
    refused(
        "only available on a workflow_dispatch",
        event="push",
        scope="custom",
        tmux_ref="master",
        tmate="on-failure",
    )


def check_a_debug_mode_must_be_known() -> None:
    refused("tmate must be one of", scope="custom", tmux_ref="master", tmate="always")


def check_the_job_count_adds_up() -> None:
    # The planning job and the aggregate.
    fixed = 2
    assert plan("push")["expected_jobs"] == fixed + 6
    full = plan("workflow_dispatch", scope="full")
    assert full["expected_jobs"] == fixed + len(FULL_SCOPE) + len(REJECTED_TMUX)


def check_the_matrix_is_never_empty() -> None:
    try:
        require_jobs([])
    except PlanError as error:
        assert "no job" in str(error)
        return
    raise AssertionError("an empty plan was accepted")


def needs(
    matrix: str = "success",
    check: str = "success",
    reject: str = "skipped",
    planned: bool = False,
) -> dict[str, Any]:
    return {
        "matrix": {
            "result": matrix,
            "outputs": {"run_rejected": "true" if planned else "false"},
        },
        "check": {"result": check},
        "reject": {"result": reject},
    }


WORKFLOW_BREAKS = (
    (
        "matrix: ${{ fromJSON(needs.matrix.outputs.cells) }}",
        "matrix: {tmux: ['3.8']}",
        "the cells must come from the plan",
    ),
    (
        "matrix: ${{ fromJSON(needs.matrix.outputs.rejected) }}",
        "matrix: {tmux: ['3.2a']}",
        "the lanes must come from the plan",
    ),
    (
        "if: needs.matrix.outputs.run_rejected == 'true'",
        "if: always()",
        "it runs only where the plan schedules it",
    ),
    (
        "      matrix: ${{ fromJSON(needs.matrix.outputs.cells) }}\n",
        "      matrix: ${{ fromJSON(needs.matrix.outputs.cells) }}\n    if: true\n",
        "no leg may be skipped",
    ),
    (
        "python3 dev/plan_matrix.py self-test",
        "true",
        "it must plan the run and check the plan",
    ),
    (
        "    needs: [matrix, reject, check]\n",
        "    needs: [matrix, check]\n",
        "it must check the planning job, the lanes and the checks",
    ),
    (
        "run: python3 dev/plan_matrix.py gate",
        "run: true",
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
        "${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}",
        "",
        "add github.run_id to a dispatch run's group",
    ),
    (
        "${{ github.event_name == 'workflow_dispatch' && format('-{0}', github.run_id) || '' }}",
        "-${{ github.run_id }}",
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
        "timeout-minutes: ${{ matrix.tmate == 'off' && 20 || 50 }}",
        "timeout-minutes: 20",
        "give the debugging job more",
    ),
    (
        "          TMATE: ${{ inputs.tmate }}\n",
        "",
        "receive the tmate input through env",
    ),
    (
        '        run: echo "MATRIX_JOB_DEADLINE=',
        '        run: echo "MATRIX_JOB_DEADLINE_UNUSED=',
        "work clock must restart",
    ),
    (
        '--tmux-ref "$TMUX_REF"',
        '--tmux-ref "${{ inputs.tmux-ref }}"',
        "pass an input to a script through env",
    ),
    (
        "python3 dev/check-matrix.py resolve-tmux",
        "python3 dev/check-matrix.py resolve-tmux '3.8'",
        "belongs in the table, not the workflow",
    ),
)


def check_the_workflow_follows_the_plan() -> None:
    text = WORKFLOW.read_text(encoding="utf-8")
    assert workflow_problems(text) == []
    for old, new, expected in WORKFLOW_BREAKS:
        assert old in text, old
        found = workflow_problems(text.replace(old, new, 1))
        assert any(expected in problem for problem in found), (expected, found)


SYNTHETIC_WORKFLOW = """\
jobs:
  build:
    steps:
      - name: Raw update
        run: |
          # sudo apt-get install ignored-comment
          sudo apt-get update
      - name: Wrapped update
        run: ./dev/apt-get.sh update
"""


def check_apt_goes_through_the_wrapper() -> None:
    wrapped = SYNTHETIC_WORKFLOW.replace(
        "sudo apt-get update", "./dev/apt-get.sh update"
    )
    assert raw_apt_problems("w.yml", wrapped) == []
    found = raw_apt_problems("w.yml", SYNTHETIC_WORKFLOW)
    assert found == [
        (
            "w.yml:5: job build, step Raw update: raw apt-get call; "
            "run it through dev/apt-get.sh"
        )
    ], found
    inline = "jobs:\n  a:\n    steps:\n      - run: sudo -E apt install -y tmux\n"
    assert any("raw apt call" in each for each in raw_apt_problems("w.yml", inline))
    assert ci_files(), "no workflow found"
    for path in ci_files():
        assert raw_apt_problems(path.name, path.read_text(encoding="utf-8")) == []


def check_the_gate_passes_what_the_plan_scheduled() -> None:
    assert check_needs(needs()) == []
    assert check_needs(needs(reject="success", planned=True)) == []


def check_the_gate_needs_the_planning_job_and_the_checks() -> None:
    for broken in (
        needs(matrix="failure"),
        needs(matrix="cancelled"),
        needs(check="failure"),
        needs(check="skipped"),
    ):
        assert check_needs(broken)
    missing = needs()
    del missing["check"]
    assert check_needs(missing)


def check_a_planned_lane_that_was_skipped_fails_the_gate() -> None:
    assert check_needs(needs(reject="skipped", planned=True))
    assert check_needs(needs(reject="failure", planned=True))


def check_a_lane_the_plan_left_out_must_not_have_run() -> None:
    assert check_needs(needs(reject="success"))


ALL_CHECKS: tuple[Check, ...] = (
    check_push_runs_the_edges_only,
    check_the_table_alone_decides_the_edges,
    check_pull_request_runs_the_edges_only,
    check_dispatch_defaults_to_the_edges,
    check_full_runs_the_whole_table,
    check_a_scope_input_wins_over_a_tag,
    check_the_documentation_artifact_comes_from_one_edge_job,
    check_custom_builds_the_named_refs,
    check_a_custom_run_needs_refs,
    check_inputs_a_custom_run_reads_need_the_custom_scope,
    check_a_scope_must_be_known,
    check_an_unknown_event_is_refused,
    check_every_ref_is_validated,
    check_too_many_refs_are_refused,
    check_a_julia_input_replaces_the_version,
    check_a_malformed_julia_is_refused,
    check_a_custom_run_can_choose_threads_and_suites,
    check_unknown_threads_and_suites_are_refused,
    check_one_job_gets_the_debug_session,
    check_no_debug_session_by_default,
    check_several_jobs_cannot_share_a_debug_session,
    check_a_debug_session_needs_a_dispatch,
    check_a_debug_mode_must_be_known,
    check_the_job_count_adds_up,
    check_the_matrix_is_never_empty,
    check_the_workflow_follows_the_plan,
    check_apt_goes_through_the_wrapper,
    check_the_gate_passes_what_the_plan_scheduled,
    check_the_gate_needs_the_planning_job_and_the_checks,
    check_a_planned_lane_that_was_skipped_fails_the_gate,
    check_a_lane_the_plan_left_out_must_not_have_run,
)

# Checks that state a default or a boundary no single removal can reach.
WITHOUT_A_BREAK = frozenset({check_no_debug_session_by_default})

REAL = {
    name: globals()[name]
    for name in (
        "resolve_scope",
        "assign_tmate",
        "check_needs",
        "edge_cells",
        "rejection_cells",
    )
}


def resolving(**replaced: str) -> Callable[[str, str, str], str]:
    def broken(event: str, ref: str, scope: str) -> str:
        return str(
            REAL["resolve_scope"](
                replaced.get("event", event),
                replaced.get("ref", ref),
                replaced.get("scope", scope),
            )
        )

    return broken


def every_version(supported: tuple[str, ...]) -> tuple[str, ...]:
    return supported


def hard_coded(supported: tuple[str, ...]) -> tuple[str, ...]:
    return ("3.3a", "3.8")


def anything(item: str) -> str:
    return item


def ignored(*arguments: object, **keywords: object) -> None:
    return None


def always_the_table(
    scope: str,
    *,
    tmux_ref: str = "",
    julia: str = "",
    threads: str = "",
    suite: str = "",
) -> list[QaCell]:
    return full_cells(select_julia(julia))


def refusal_lanes_always(scope: str) -> list[dict[str, str]]:
    return list(REAL["rejection_cells"]("full"))


def no_refusal_lanes(scope: str) -> list[dict[str, str]]:
    return []


def no_thread_cell(julia: str) -> list[QaCell]:
    return list(REAL["edge_cells"](julia))[:-1]


def docs_artifact_everywhere(cells: list[QaCell]) -> None:
    for cell in cells:
        cell["docs_artifact"] = "true"


def docs_artifact_from_a_middle_release(cells: list[QaCell]) -> None:
    for cell in cells:
        if cell["tmux"] == "3.7c" and cell["threads"] == 1:
            cell["docs_artifact"] = "true"


def release_cell(
    tmux: str, julia: str, threads: int, suites: tuple[str, ...], release: bool
) -> QaCell:
    return make_cell_unbroken(tmux, julia, threads, suites, True)


def any_julia(requested: str) -> str:
    return requested or MINIMUM_JULIA


def any_threads(requested: str) -> int:
    return int(requested or "1")


def any_suites(requested: str) -> tuple[str, ...]:
    return SUITES if requested == "both" else ("runtime",)


def debug_session_everywhere(
    event: str, mode: str, jobs: list[QaCell], rejected: list[dict[str, str]]
) -> None:
    for each in jobs:
        each["tmate"] = mode


def debug_session_without_event(
    event: str, mode: str, jobs: list[QaCell], rejected: list[dict[str, str]]
) -> None:
    REAL["assign_tmate"]("workflow_dispatch", mode, jobs, rejected)


def gate_without_lanes(got: dict[str, Any]) -> list[str]:
    return [p for p in REAL["check_needs"](got) if not p.startswith("reject")]


def gate_that_expects_every_lane_skipped(got: dict[str, Any]) -> list[str]:
    forced = {**got, "matrix": {**got["matrix"], "outputs": {"run_rejected": "false"}}}
    return list(REAL["check_needs"](forced))


def gate_that_accepts_unplanned_runs(got: dict[str, Any]) -> list[str]:
    return [p for p in REAL["check_needs"](got) if "not skipped" not in p]


def gate_without_the_checks(got: dict[str, Any]) -> list[str]:
    return [p for p in REAL["check_needs"](got) if not p.startswith("check")]


def gate_without_the_planning_job(got: dict[str, Any]) -> list[str]:
    return [p for p in REAL["check_needs"](got) if not p.startswith("matrix")]


def unchecked_event(event: str, ref: str, scope: str) -> str:
    return "edges"


make_cell_unbroken = make_cell

DELIBERATE_BREAKS: tuple[tuple[str, str, Any, Check], ...] = (
    (
        "the edges rule takes every release",
        "edge_versions",
        every_version,
        check_push_runs_the_edges_only,
    ),
    (
        "the edges are written into the plan",
        "edge_versions",
        hard_coded,
        check_the_table_alone_decides_the_edges,
    ),
    (
        "a pull request runs the full scope",
        "resolve_scope",
        resolving(event="pull_request", ref="refs/tags/x"),
        check_pull_request_runs_the_edges_only,
    ),
    (
        "a tag does not run the full scope",
        "resolve_scope",
        resolving(ref="refs/heads/master"),
        check_full_runs_the_whole_table,
    ),
    (
        "the scope input is ignored",
        "resolve_scope",
        resolving(scope=""),
        check_a_scope_input_wins_over_a_tag,
    ),
    (
        "a dispatch does not default to the edges",
        "resolve_scope",
        resolving(scope="full"),
        check_dispatch_defaults_to_the_edges,
    ),
    (
        "an unknown scope is accepted",
        "resolve_scope",
        resolving(scope="edges"),
        check_a_scope_must_be_known,
    ),
    (
        "an unknown event is accepted",
        "resolve_scope",
        unchecked_event,
        check_an_unknown_event_is_refused,
    ),
    (
        "the edges run the whole table",
        "qa_cells",
        always_the_table,
        check_push_runs_the_edges_only,
    ),
    (
        "the edges run the refusal lanes",
        "rejection_cells",
        refusal_lanes_always,
        check_push_runs_the_edges_only,
    ),
    (
        "the full scope drops the refusal lanes",
        "rejection_cells",
        no_refusal_lanes,
        check_full_runs_the_whole_table,
    ),
    (
        "the delivery suite runs on every release",
        "DELIVERY_TMUX",
        SUPPORTED_TMUX,
        check_full_runs_the_whole_table,
    ),
    (
        "3.7c loses its delivery suite",
        "DELIVERY_TMUX",
        ("3.3a", "3.8"),
        check_full_runs_the_whole_table,
    ),
    (
        "the four-thread cell moves to the newest release",
        "FOUR_THREAD_TMUX",
        "3.8",
        check_full_runs_the_whole_table,
    ),
    (
        "the full scope drops the four-thread cell",
        "FOUR_THREAD_TMUX",
        "",
        check_full_runs_the_whole_table,
    ),
    (
        "a push drops the four-thread cell",
        "edge_cells",
        no_thread_cell,
        check_push_runs_the_edges_only,
    ),
    (
        "every job uploads the documentation",
        "mark_docs_artifact",
        docs_artifact_everywhere,
        check_the_documentation_artifact_comes_from_one_edge_job,
    ),
    (
        "a middle release uploads the documentation",
        "mark_docs_artifact",
        docs_artifact_from_a_middle_release,
        check_the_documentation_artifact_comes_from_one_edge_job,
    ),
    (
        "no job uploads the documentation",
        "mark_docs_artifact",
        ignored,
        check_the_documentation_artifact_comes_from_one_edge_job,
    ),
    (
        "a custom ref is taken for a release",
        "make_cell",
        release_cell,
        check_custom_builds_the_named_refs,
    ),
    (
        "a custom run without refs is planned",
        "custom_refs",
        lambda tmux_ref: [anything(each) for each in split_list(tmux_ref)],
        check_a_custom_run_needs_refs,
    ),
    (
        "inputs the scope ignores are accepted",
        "check_scope_inputs",
        ignored,
        check_inputs_a_custom_run_reads_need_the_custom_scope,
    ),
    ("a ref is not validated", "check_ref", anything, check_every_ref_is_validated),
    ("the ref count is unlimited", "MAX_REFS", 1000, check_too_many_refs_are_refused),
    (
        "the julia input is ignored",
        "select_julia",
        lambda requested: MINIMUM_JULIA,
        check_a_julia_input_replaces_the_version,
    ),
    (
        "a malformed julia is accepted",
        "select_julia",
        any_julia,
        check_a_malformed_julia_is_refused,
    ),
    (
        "the threads input is ignored",
        "select_threads",
        lambda requested: 1,
        check_a_custom_run_can_choose_threads_and_suites,
    ),
    (
        "an unknown threads value is accepted",
        "select_threads",
        any_threads,
        check_unknown_threads_and_suites_are_refused,
    ),
    (
        "the suite input is ignored",
        "select_suites",
        lambda requested: ("runtime",),
        check_a_custom_run_can_choose_threads_and_suites,
    ),
    (
        "an unknown suite is accepted",
        "select_suites",
        any_suites,
        check_unknown_threads_and_suites_are_refused,
    ),
    (
        "no job gets the debug session",
        "assign_tmate",
        ignored,
        check_one_job_gets_the_debug_session,
    ),
    (
        "every job gets the debug session",
        "assign_tmate",
        debug_session_everywhere,
        check_several_jobs_cannot_share_a_debug_session,
    ),
    (
        "the debug session runs outside a dispatch",
        "assign_tmate",
        debug_session_without_event,
        check_a_debug_session_needs_a_dispatch,
    ),
    (
        "an unknown debug mode is accepted",
        "assign_tmate",
        ignored,
        check_a_debug_mode_must_be_known,
    ),
    (
        "the job count omits the fixed jobs",
        "FIXED_JOBS",
        0,
        check_the_job_count_adds_up,
    ),
    (
        "an empty plan is accepted",
        "require_jobs",
        ignored,
        check_the_matrix_is_never_empty,
    ),
    (
        "the workflow is not checked",
        "workflow_problems",
        lambda text: [],
        check_the_workflow_follows_the_plan,
    ),
    (
        "raw apt-get calls are accepted",
        "raw_apt_problems",
        lambda name, text: [],
        check_apt_goes_through_the_wrapper,
    ),
    (
        "the gate ignores the refusal lane",
        "check_needs",
        gate_without_lanes,
        check_a_planned_lane_that_was_skipped_fails_the_gate,
    ),
    (
        "the gate expects every lane skipped",
        "check_needs",
        gate_that_expects_every_lane_skipped,
        check_the_gate_passes_what_the_plan_scheduled,
    ),
    (
        "the gate lets an unplanned lane run",
        "check_needs",
        gate_that_accepts_unplanned_runs,
        check_a_lane_the_plan_left_out_must_not_have_run,
    ),
    (
        "the gate ignores the checks",
        "check_needs",
        gate_without_the_checks,
        check_the_gate_needs_the_planning_job_and_the_checks,
    ),
    (
        "the gate ignores the planning job",
        "check_needs",
        gate_without_the_planning_job,
        check_the_gate_needs_the_planning_job_and_the_checks,
    ),
)


def fails(check: Check) -> bool:
    """Report whether a check notices that something is wrong."""
    try:
        check()
    except (AssertionError, LookupError, TypeError, ValueError):
        return True
    return False


def self_test() -> None:
    """Run every check, then break each rule and require its check to notice."""
    for check in ALL_CHECKS:
        check()
    broken = {each[3] for each in DELIBERATE_BREAKS}
    unbroken = {check for check in ALL_CHECKS if check not in broken}
    assert unbroken == WITHOUT_A_BREAK, sorted(check.__name__ for check in unbroken)
    for description, attribute, replacement, check in DELIBERATE_BREAKS:
        with mock.patch.object(sys.modules[__name__], attribute, replacement):
            noticed = fails(check)
        assert noticed, (
            f"check {check.__name__} passed with its rule removed: {description}"
        )
    assert len(outputs(plan("push"))["cells"].splitlines()) == 1
    print("PASS matrix plan rules and their deliberate breaks")


def main(argv: list[str] | None = None) -> int:
    """Print the plan for a workflow, check the jobs that finished, or self-test."""
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    planner = commands.add_parser("plan", help="plan the jobs for one event")
    planner.add_argument("--event", required=True, help="github.event_name")
    planner.add_argument("--ref", default="", help="github.ref")
    planner.add_argument("--scope", default="", help="edges, full or custom")
    planner.add_argument("--tmux-ref", default="", help="comma-separated tmux refs")
    planner.add_argument("--julia", default="", help="the Julia version for the cells")
    planner.add_argument("--threads", default="", help="1 or 4, for scope custom")
    planner.add_argument(
        "--suite", default="", help="runtime, delivery or both, for scope custom"
    )
    planner.add_argument("--tmate", default="", help="off, before-tests or on-failure")
    planner.add_argument("--github-output", type=Path, help="the GITHUB_OUTPUT file")
    planner.add_argument("--summary", type=Path, help="the GITHUB_STEP_SUMMARY file")

    commands.add_parser("gate", help="check the NEEDS environment variable")
    commands.add_parser(
        "self-test", help="check the plan rules and their deliberate breaks"
    )
    arguments = parser.parse_args(argv)

    if arguments.command == "self-test":
        self_test()
        return 0
    if arguments.command == "gate":
        problems = check_needs(json.loads(os.environ.get("NEEDS", "{}")))
        for problem in problems:
            print(f"gate: {problem}", file=sys.stderr)
        return 1 if problems else 0

    try:
        result = plan(
            arguments.event,
            ref=arguments.ref,
            scope=arguments.scope,
            tmux_ref=arguments.tmux_ref,
            julia=arguments.julia,
            threads=arguments.threads,
            suite=arguments.suite,
            tmate=arguments.tmate,
        )
    except PlanError as error:
        print(f"plan: {error}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2))
    if arguments.github_output:
        with arguments.github_output.open("a", encoding="utf-8") as handle:
            for key, value in outputs(result).items():
                handle.write(f"{key}={value}\n")
    if arguments.summary:
        with arguments.summary.open("a", encoding="utf-8") as handle:
            handle.write(summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
