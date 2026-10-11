#!/usr/bin/env python3
"""Export source-bound CI diagnostics without changing the original test verdict.

Process starts bind schema, invocation, source_digest and process_birth_id.
Later records inherit that binding; an explicit conflicting binding is rejected.
Native cumulative counts are counted on a non-overlapping set of finalized
subtrees. Missing bodies and unknown inventories remain partial.
"""

import argparse
import csv
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import re
import sys
import tempfile
import time
import xml.etree.ElementTree as ET


COUNT_KEYS = ("passed", "failed", "errored", "broken")
ABSOLUTE_PATH = re.compile(r"(?<![\w])(?:[A-Za-z]:[\\/]|\\\\|/)[^\s\"'<>`]+")
PRIVATE_PATH_TOKEN = re.compile(r"/(?:home|Users|tmp|mnt|private|var|opt|usr|etc|run|srv|Volumes|workspace|workspaces)(?=/|$|[\s\"'<>`])(?:/[^\s\"'<>`]*)?|[A-Za-z]:[\\/][^\s\"'<>`]*|\\\\[^\s\"'<>`]*")
PRIVATE_PATH_REJECT = re.compile(r"/(?:home|Users|tmp|mnt|private|var|opt|usr|etc|run|srv|Volumes|workspace|workspaces)(?=/|$)|[A-Za-z]:[/\\]|\\\\")
IDENTIFIER = re.compile(r"[A-Za-z0-9_.-]{1,128}\Z")
SHA256 = re.compile(r"[a-f0-9]{64}\Z")
MAX_RECORD_BYTES = 1024 * 1024
MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_PROFILE_BYTES = 32 * 1024 * 1024
MAX_PROFILE_TOTAL_BYTES = 128 * 1024 * 1024
MAX_PROFILE_CHECKPOINTS = 32
MAX_SETUP_FILES = 64
MAX_SETUP_BYTES = 32 * 1024 * 1024
MAX_SETUP_FILE_BYTES = 8 * 1024 * 1024


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def bounded_structure(value, depth=0):
    if depth > 32:
        return False
    if isinstance(value, list):
        return all(bounded_structure(item, depth + 1) for item in value)
    if isinstance(value, dict):
        return all(bounded_structure(item, depth + 1) for item in value.values())
    return True


def parse_json(raw):
    def reject_constant(_):
        raise ValueError("nonfinite JSON constant")
    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON field")
            result[key] = value
        return result
    return json.loads(raw, parse_constant=reject_constant, object_pairs_hook=unique_object)


class SourceMap:
    """Map known source roots and remove every remaining absolute path."""

    def __init__(self, roots):
        if not roots:
            raise ValueError("explicit source roots are required")
        self.roots = []
        self.redacted_paths = 0
        labels = set()
        for physical, logical in roots:
            if not Path(physical).is_absolute():
                raise ValueError("physical source roots must be absolute")
            physical = str(Path(physical).resolve())
            label = str(PurePosixPath(logical))
            if not Path(physical).is_absolute() or not label or label in (".", "/"):
                raise ValueError("source roots require an absolute root and relative label")
            if PurePosixPath(label).is_absolute() or ".." in PurePosixPath(label).parts or "\\" in label:
                raise ValueError("source labels must stay relative")
            if any(not IDENTIFIER.fullmatch(part) for part in PurePosixPath(label).parts):
                raise ValueError("source labels require portable path segments")
            if label in labels:
                raise ValueError("source labels must be distinct")
            labels.add(label)
            if physical == os.path.abspath(os.sep):
                raise ValueError("filesystem root is not a source root")
            self.roots.append((physical.rstrip(os.sep), label))
        self.roots.sort(key=lambda item: len(item[0]), reverse=True)
        self.source_aliases = []
        home = str(Path.home().resolve()).rstrip(os.sep)
        for physical, logical in self.roots:
            prefixes = [physical]
            if physical.startswith(home + os.sep):
                prefixes.append("~" + physical[len(home):])
            for prefix in prefixes:
                pattern = (r"(?<![\w~])" + re.escape(prefix)
                    + r"(?=$|[/\\\s:;,\"'<>`\)])(?P<tail>[/\\][^\s\"'<>`),;]*)?")
                self.source_aliases.append((re.compile(pattern), logical))

    def text(self, value):
        text = str(value)
        for pattern, logical in self.source_aliases:
            def owned(match):
                tail = match.group("tail") or ""
                if ".." in re.split(r"[/\\]", tail):
                    self.redacted_paths += 1
                    return "redacted-path"
                return logical + tail.replace("\\", "/")
            text = pattern.sub(owned, text)
        def redact(_):
            self.redacted_paths += 1
            return "redacted-path"
        text = ABSOLUTE_PATH.sub(redact, text)
        text = PRIVATE_PATH_TOKEN.sub(redact, text)
        return "".join(character if (ord(character) >= 32 or character in "\n\r\t")
                       and not 0xD800 <= ord(character) <= 0xDFFF and ord(character) not in (0xFFFE, 0xFFFF)
                       else "?" for character in text)

    def value(self, value):
        if isinstance(value, str):
            return self.text(value)
        if isinstance(value, list):
            return [self.value(item) for item in value]
        if isinstance(value, dict):
            return {self.text(key): self.value(item) for key, item in value.items()}
        return value

    def owns(self, path):
        path = Path(path)
        if path.is_symlink():
            return False
        resolved = path.resolve()
        return any(resolved == Path(root) or Path(root) in resolved.parents for root, _ in self.roots)


def fault(kind, detail, *, severe=False, **fields):
    return dict(kind=str(kind), detail=str(detail), severe=severe, **fields)


def input_bytes(path, mapping, issues, *, limit=MAX_INPUT_BYTES):
    path = Path(path)
    if not mapping.owns(path):
        issues.append(fault("unowned_input", "input is outside mapped roots or is a symbolic link", severe=True))
        return b""
    try:
        with path.open("rb") as stream:
            raw = stream.read(limit + 1)
    except OSError:
        issues.append(fault("input_unavailable", "input could not be read", severe=True))
        return b""
    if len(raw) > limit:
        issues.append(fault("input_truncated", "input exceeds the declared export bound"))
        raw = raw[:limit]
    return raw


def read_process(path, *, invocation, source_digest, mapping, ordinal):
    issues = []
    raw = input_bytes(path, mapping, issues)
    events, birth, pid, phase, previous, previous_elapsed = [], None, None, None, 0, 0
    source_bound = False
    lines = raw.splitlines(keepends=True)
    for number, line in enumerate(lines, 1):
        if len(line) > MAX_RECORD_BYTES:
            issues.append(fault("record_too_large", "trusted prefix retained", line=number))
            break
        try:
            event = parse_json(line)
        except (ValueError, UnicodeError, RecursionError):
            final = number == len(lines) and not line.endswith(b"\n")
            issues.append(fault("truncated_tail" if final else "malformed_record", "trusted prefix retained", severe=not final, line=number))
            break
        if not isinstance(event, dict) or not bounded_structure(event) or type(event.get("schema")) is not int or event["schema"] not in (1, 2):
            issues.append(fault("unsupported_schema", "record rejected", severe=True, line=number))
            break
        if not isinstance(event.get("event"), str) or not event["event"]:
            issues.append(fault("invalid_event", "record rejected", severe=True, line=number))
            break
        if type(event.get("seq")) is not int or event["seq"] != previous + 1:
            issues.append(fault("sequence_fault", "record rejected", severe=True, line=number))
            break
        if not events:
            if event.get("event") != "process_start" or event.get("invocation") != invocation:
                issues.append(fault("stale_invocation", "entire stream rejected", severe=True))
                break
            if event.get("source_digest") not in (None, source_digest):
                issues.append(fault("stale_source", "entire stream rejected", severe=True))
                break
            birth = event.get("process_birth_id")
            if birth is not None and (not isinstance(birth, str) or not IDENTIFIER.fullmatch(birth)):
                issues.append(fault("invalid_birth", "entire stream rejected", severe=True))
                break
            pid = event.get("pid")
            phase = event.get("phase")
            if type(pid) is not int or pid <= 0:
                issues.append(fault("invalid_pid", "entire stream rejected", severe=True))
                break
            source_bound = event.get("source_digest") == source_digest and birth is not None
            if not source_bound:
                issues.append(fault("legacy_binding", "source digest or process birth identity unavailable"))
        elif event.get("event") == "process_start":
            issues.append(fault("duplicate_process_start", "record rejected", severe=True))
            break
        if (event.get("pid") != pid or event.get("invocation", invocation) != invocation
                or event.get("source_digest", source_digest) != source_digest
                or event.get("process_birth_id", birth) != birth
                or event.get("phase", phase) != phase):
            issues.append(fault("identity_fault", "record rejected", severe=True))
            break
        if not finite_number(event.get("elapsed_ns")) or event["elapsed_ns"] < previous_elapsed:
            issues.append(fault("clock_fault", "record rejected", severe=True))
            break
        previous = event["seq"]
        previous_elapsed = event["elapsed_ns"]
        events.append(mapping.value(event | dict(invocation=invocation, process_birth_id=birth,
                                                 source_digest=source_digest if source_bound else None)))
        if not line.endswith(b"\n"):
            issues.append(fault("unterminated_record", "complete JSON retained; final durability unproved"))
    if not events:
        issues.append(fault("missing_process_start", "no trusted events"))
    return dict(input_name=mapping.text(Path(path).name), input_ordinal=ordinal, input_sha256=hashlib.sha256(raw).hexdigest(),
                process_id=birth or f"unbound-stream-{ordinal:04d}", pid=pid, source_bound=source_bound,
                events=events, issues=issues)


def portable_file(value):
    return (isinstance(value, str) and bool(value) and not PurePosixPath(value).is_absolute()
            and "\\" not in value and "redacted-path" not in value
            and all(IDENTIFIER.fullmatch(part) and part not in (".", "..") for part in value.split("/")))


def body_outcome(testset):
    finish = testset["finish"] or {}
    return finish.get("body_outcome", finish.get("body_completion", "unknown"))


def body_completed(testset):
    finish = testset["finish"]
    return bool(finish) and (body_outcome(testset) == "returned"
                            or body_outcome(testset) == "threw" and finish["counts"]["errored"] > 0
                            and finish.get("native_finish") in ("returned", "threw"))


def native_detail(problem):
    if str(problem.get("detail_status", "")).lower() == "unavailable":
        return "Native detail unavailable; inspect the bound sanitized original log.", "UNAVAILABLE"
    for key in ("detail", "rendered"):
        if isinstance(problem.get(key), str) and problem[key].strip():
            return problem[key], "AVAILABLE"
    return "Native detail unavailable; inspect the bound sanitized original log.", "UNAVAILABLE"


def ancestors(identifier, testsets):
    parent = testsets[identifier]["start"].get("parent_id")
    while parent is not None:
        yield parent
        parent = testsets[parent]["start"].get("parent_id")


def analyze_process(process):
    testsets, problems, spans, profiles = {}, [], [], []
    inventory, file_starts, file_finishes, files_open = set(), [], [], {}
    inventory_seen = False
    finish = None
    for event in process["events"]:
        kind = event.get("event")
        if finish is not None:
            process["issues"].append(fault("after_process_finish", "unexpected record", severe=True))
            break
        identifier = event.get("testset_id")
        if kind == "testset_start":
            parent = event.get("parent_id")
            if (type(identifier) is not int or identifier <= 0 or identifier in testsets
                    or parent is not None and (type(parent) is not int or parent not in testsets)
                    or not isinstance(event.get("description"), str)
                    or event.get("file") is not None and not isinstance(event["file"], str)
                    or event.get("line") is not None and (type(event["line"]) is not int or event["line"] <= 0)):
                process["issues"].append(fault("testset_identity_fault", "unknown parent or duplicate testset", severe=True))
                continue
            parent_name = testsets[parent]["qualified_name"] + " > " if parent is not None else ""
            testsets[identifier] = dict(start=event, finish=None, body_end=None, problems=[],
                                       qualified_name=parent_name + event["description"])
        elif kind == "testset_body_end":
            if (type(identifier) is not int or identifier not in testsets or testsets[identifier]["body_end"] is not None
                    or event.get("body_outcome") not in ("returned", "threw", "interrupted", "nonlocal_exit")):
                process["issues"].append(fault("testset_body_fault", "unknown or duplicate body outcome", severe=True))
                continue
            testsets[identifier]["body_end"] = event
        elif kind == "testset_finalize":
            counts = event.get("counts")
            if type(identifier) is not int or identifier not in testsets or testsets[identifier]["finish"] is not None:
                process["issues"].append(fault("testset_finish_fault", "unknown or duplicate finalization", severe=True))
                continue
            if not isinstance(counts, dict) or any(type(counts.get(key)) is not int or counts[key] < 0 for key in COUNT_KEYS):
                process["issues"].append(fault("counts_fault", "invalid native counts", severe=True))
                continue
            testsets[identifier]["finish"] = event
            body = testsets[identifier]["body_end"]
            if body and body.get("body_outcome") != body_outcome(testsets[identifier]):
                process["issues"].append(fault("testset_body_conflict", "body and finalization outcomes differ", severe=True))
        elif kind == "assertion_problem":
            if event.get("result_type") not in ("Fail", "Error"):
                process["issues"].append(fault("native_problem_shape", "invalid native result record", severe=True))
                continue
            if type(identifier) is not int or identifier <= 0:
                identifier = None
            if not isinstance(event.get("problem_kind"), str):
                process["issues"].append(fault("native_problem_shape", "native failure retained with unknown result kind", severe=True))
                event = event | dict(problem_kind="unknown")
            if event.get("file") is not None and not isinstance(event["file"], str):
                process["issues"].append(fault("native_problem_source", "native failure retained without a usable source", severe=True))
                event = event | dict(file=None)
            event = event | dict(testset_id=identifier)
            event = event | dict(native_detail_status=event.get("detail_status", "unspecified"), detail_status=native_detail(event)[1],
                                 qualified_name=testsets[identifier]["qualified_name"] if identifier in testsets else "unknown testset")
            problems.append(event)
            if identifier in testsets:
                testsets[identifier]["problems"].append(event)
            else:
                process["issues"].append(fault("orphan_problem", "native problem retained without a testset"))
        elif kind == "process_finish":
            finish = event
        elif kind == "coverage_incomplete":
            process["issues"].append(fault("coverage_incomplete", event.get("reason", "native coverage incomplete")))
        elif kind == "file_inventory":
            files = event.get("files")
            if (event.get("scope") != "declared_files_only" or not isinstance(files, list) or not files
                    or any(not portable_file(file) for file in files)
                    or len(files) != len(set(files)) or inventory.intersection(files)):
                process["issues"].append(fault("file_inventory_fault", "invalid or repeated declared files", severe=True))
                continue
            if file_starts:
                process["issues"].append(fault("late_file_inventory", "declared files arrived after file admission"))
            inventory.update(files)
            inventory_seen = True
        elif kind == "span_start" and event.get("kind") == "file":
            label = event.get("label")
            if not portable_file(label):
                process["issues"].append(fault("file_admission_fault", "invalid file start"))
                continue
            if label not in inventory or label in file_starts:
                process["issues"].append(fault("file_admission_fault", "file start is undeclared, invalid or repeated"))
            elif label not in files_open:
                files_open[label] = event
            file_starts.append(label)
        elif kind == "span_finish":
            spans.append(event)
            if event.get("kind") == "file":
                label = event.get("label")
                if not isinstance(label, str) or label not in files_open:
                    process["issues"].append(fault("file_finish_fault", "file finish has no matching start", severe=True))
                else:
                    files_open.pop(label)
                    file_finishes.append(event)
        elif kind == "child_first_byte":
            spans.append(dict(kind="child_start_to_first_byte", label="first byte", seconds=event.get("seconds"), outcome="observed"))
        elif kind.startswith("profile_"):
            profiles.append(event)
            if kind == "profile_checkpoint" and finite_number(event.get("capture_seconds")):
                spans.append(dict(kind="profile_export", label=event.get("file", "unknown"), seconds=event["capture_seconds"], outcome=event.get("status", "unknown")))
    finalized = {identifier for identifier, ts in testsets.items() if ts["finish"] is not None}
    invalid_counts = set()
    child_totals = {}
    for ts in testsets.values():
        parent = ts["start"].get("parent_id")
        if parent is not None and ts["finish"] is not None:
            total = child_totals.setdefault(parent, dict.fromkeys(COUNT_KEYS, 0))
            for key in COUNT_KEYS:
                total[key] += ts["finish"]["counts"][key]
    for identifier in finalized:
        ts = testsets[identifier]
        observed = dict(failed=sum(problem["result_type"] == "Fail" for problem in ts["problems"]),
                        errored=sum(problem["result_type"] == "Error" for problem in ts["problems"]))
        if any(ts["finish"]["counts"][key] < child_totals.get(identifier, {}).get(key, 0) + observed.get(key, 0)
               for key in COUNT_KEYS):
            process["issues"].append(fault("cumulative_counts_conflict", "parent counts omit observed child counts or native problems", severe=True))
            invalid_counts.add(identifier)
    finalized.difference_update(invalid_counts)
    selected = {identifier for identifier in finalized if not any(parent in finalized for parent in ancestors(identifier, testsets))}
    counts = {key: sum(testsets[identifier]["finish"]["counts"][key] for identifier in selected) for key in COUNT_KEYS}
    for problem in problems:
        identifier = problem.get("testset_id")
        covered = identifier in selected or identifier in testsets and any(parent in selected for parent in ancestors(identifier, testsets))
        if not covered:
            key = "failed" if problem.get("result_type") == "Fail" else "errored"
            counts[key] += 1
    bodies_complete = bool(testsets) and all(body_completed(ts) for ts in testsets.values())
    if any(not portable_file(ts["start"].get("file")) or ts["start"]["file"] not in inventory for ts in testsets.values()):
        process["issues"].append(fault("testset_source_unbound", "testset source is outside the declared file inventory"))
    file_coverage_complete = (inventory_seen and bool(inventory) and not files_open
                              and len(file_starts) == len(file_finishes) == len(inventory)
                              and set(file_starts) == inventory
                              and all(event.get("outcome") == "returned"
                                      or event.get("outcome") == "threw" and counts["failed"] + counts["errored"] > 0
                                      for event in file_finishes))
    outcome = finish.get("outcome", "unknown") if finish else "unknown"
    complete = process["source_bound"] and not process["issues"] and finish is not None and bodies_complete and file_coverage_complete
    complete = complete and finish.get("coverage_complete") is True
    if finish and finish.get("observer_faults", finish.get("observer_failures")):
        process["issues"].append(fault("observer_fault", "native observer could not preserve all evidence", severe=True))
        complete = False
    if outcome not in ("returned", "failed"):
        complete = complete and outcome == "threw" and counts["failed"] + counts["errored"] > 0
    process.update(testsets=list(testsets.values()), assertion_problems=problems, assertion_counts=counts,
                   count_scope="nonoverlapping_finalized_subtrees_and_uncovered_problems; lower_bound",
                   count_testsets=sorted(selected), process_finish=finish, process_outcome=outcome,
                   test_bodies_complete=complete, spans=spans, profiles=profiles,
                   phase=process["events"][0].get("phase") if process["events"] else None,
                   file_coverage=dict(scope="declared_files_only", complete=file_coverage_complete,
                                      declared=sorted(inventory), started=file_starts,
                                      finalized=[event.get("label") for event in file_finishes],
                                      unstarted=sorted(inventory.difference(file_starts)),
                                      unfinished=sorted(files_open)))
    process["failure_details"] = detail_counts(counts, problems)
    return process


def detail_counts(counts, problems):
    available = sum(native_detail(problem)[1] == "AVAILABLE" for problem in problems)
    unavailable = len(problems) - available
    unobserved = max(0, counts["failed"] + counts["errored"] - len(problems))
    status = ("PARTIAL" if available and unavailable + unobserved else "AVAILABLE" if available
              else "UNAVAILABLE" if unavailable + unobserved else "NOT_OBSERVED")
    return dict(status=status, available=available, unavailable=unavailable, unobserved=unobserved)


def require_binding(invocation, source_digest):
    if (not isinstance(invocation, str) or not IDENTIFIER.fullmatch(invocation) or invocation in (".", "..")
            or not isinstance(source_digest, str) or not SHA256.fullmatch(source_digest)):
        raise ValueError("portable invocation and SHA256 source digest are required")


def collect_process_evidence(event_paths, *, invocation, expected_source_digest, source_roots, expected_phase=None):
    """Read bounded native evidence without writing or certifying child admission.

The supervisor must independently supply the expected process/file inventory.
Observed streams alone cannot establish that all admitted children reported.
"""
    require_binding(invocation, expected_source_digest)
    if expected_phase is not None and (not isinstance(expected_phase, str) or not IDENTIFIER.fullmatch(expected_phase)):
        raise ValueError("expected phase must be a portable identifier")
    mapping = SourceMap(source_roots)
    issues, processes, hashes, births = [], [], set(), set()
    for ordinal, path in enumerate(event_paths, 1):
        process = read_process(path, invocation=invocation, source_digest=expected_source_digest, mapping=mapping, ordinal=ordinal)
        if process["input_sha256"] in hashes:
            issues.append(fault("duplicate_stream", "identical input was not counted twice", severe=True))
            continue
        hashes.add(process["input_sha256"])
        if process["source_bound"] and process["process_id"] in births:
            issues.append(fault("duplicate_birth", "process birth identity is ambiguous", severe=True))
            continue
        births.add(process["process_id"])
        process = analyze_process(process)
        if expected_phase is not None and process["phase"] != expected_phase:
            process["issues"].append(fault("phase_binding_fault", "process phase is missing or differs", severe=process["phase"] is not None))
            process["test_bodies_complete"] = False
        processes.append(process)
    if not processes:
        issues.append(fault("events_missing", "no process events supplied"))
    return dict(processes=processes, issues=issues,
                redacted_absolute_paths=mapping.redacted_paths,
                observed_file_coverage_complete=bool(processes) and not issues and all(process["test_bodies_complete"] for process in processes),
                process_birth_ids=[process["process_id"] for process in processes if process["source_bound"]],
                test_inventory_complete=False, child_inventory_status="UNPROVED")


def profile_shape(payload):
    if not isinstance(payload.get("data"), list) or not isinstance(payload.get("lookup"), dict):
        return False
    words = payload["data"]
    if set(map(type, words)) - {int} or min(words, default=0) < 0 or max(words, default=0) >= 2**64:
        return False
    for address, frames in payload["lookup"].items():
        if (not isinstance(address, str) or not 1 <= len(address) <= 20 or not address.isascii() or not address.isdecimal()
                or str(int(address)) != address or int(address) >= 2**64):
            return False
        if frames is None:
            continue
        if not isinstance(frames, list):
            return False
        for frame in frames:
            if frame is None:
                continue
            if (not isinstance(frame, dict) or not isinstance(frame.get("function"), str)
                    or not isinstance(frame.get("file"), str) or type(frame.get("line")) is not int
                    or type(frame.get("from_c")) is not bool or type(frame.get("inlined")) is not bool):
                return False
    return True


def profile_observations(payload, event):
    """Keep copy success separate from incomplete attribution or sample prefixes."""
    unresolved = sum(frames is None for address, frames in payload["lookup"].items() if address != "0")
    declared = payload.get("symbolization_status")
    if declared is not None and declared not in ("partial", "complete"):
        raise ValueError("unsupported symbolization status")
    if "unresolved_addresses" in payload and (type(payload["unresolved_addresses"]) is not int
            or payload["unresolved_addresses"] != unresolved):
        raise ValueError("unresolved-address count differs from the lookup")
    if declared is not None and (declared == "complete") != (unresolved == 0):
        raise ValueError("symbolization status differs from the lookup")
    if payload.get("symbolization_policy") not in (None, "native", "deferred"):
        raise ValueError("unsupported checkpoint symbolization policy")
    for field in ("symbolization_policy", "symbolization_status", "unresolved_addresses", "buffer_full", "truncated"):
        if field in event and (event[field] != payload.get(field) or type(event[field]) is not type(payload.get(field))):
            raise ValueError("checkpoint observation differs from its payload")
    for field in ("buffer_full", "truncated"):
        if field in payload and type(payload[field]) is not bool:
            raise ValueError("checkpoint prefix flag is not Boolean")
    return dict(symbolization_policy=payload.get("symbolization_policy"),
                symbolization_status="PARTIAL" if unresolved else "COMPLETE" if declared == "complete" else "UNAVAILABLE",
                unresolved_addresses=unresolved, buffer_full=payload.get("buffer_full"), truncated=payload.get("truncated"),
                sample_coverage_status="UNPROVED", symbolization_scope="checkpoint lookup only; not sample/process/time coverage")


def copy_profiles(processes, event_paths, *, invocation, source_digest, mapping, output, issues, metadata=None):
    """Retain hashed raw checkpoints; native decoder success needs separate proof."""
    records, previous, total_bytes, attempted = [], {}, 0, 0
    for process in processes:
        start = process["events"][0] if process["events"] else {}
        directory = Path(event_paths[process["input_ordinal"] - 1]).parent
        for event in process["profiles"]:
            if event["event"] != "profile_checkpoint":
                if metadata is not None:
                    metadata.append(mapping.value(event | dict(process_id=process["process_id"],
                        metadata_kind="lifecycle" if event["event"] in ("profile_start", "profile_stop") else "availability")))
                continue
            attempted += 1
            record = dict(process_id=process["process_id"], mode=event.get("mode", "unknown"),
                          checkpoint_seq=event.get("checkpoint_seq"), status="UNAVAILABLE", decoder_status="UNAVAILABLE")
            records.append(record)
            if attempted > MAX_PROFILE_CHECKPOINTS or total_bytes >= MAX_PROFILE_TOTAL_BYTES:
                record["reason"] = "bounded_profile_export_limit"
                continue
            seq, filename, digest = event.get("checkpoint_seq"), event.get("file"), event.get("input_sha256")
            if (not process["source_bound"] or event.get("schema") != 2 or type(seq) is not int or seq <= 0
                    or not isinstance(filename, str) or not IDENTIFIER.fullmatch(filename) or not filename.endswith(".json")
                    or event.get("mode") not in ("cpu", "wall") or event.get("status") not in ("captured", "empty")
                    or not isinstance(digest, str) or not SHA256.fullmatch(digest)):
                record["reason"] = "checkpoint_binding_unavailable"
                continue
            if seq <= previous.get(process["process_id"], 0):
                issues.append(fault("profile_sequence_fault", "repeated or reordered checkpoint rejected", severe=True))
                record["reason"] = "checkpoint_sequence_fault"
                continue
            previous[process["process_id"]] = seq
            profile_issues = []
            raw = input_bytes(directory / filename, mapping, profile_issues, limit=min(MAX_PROFILE_BYTES, MAX_PROFILE_TOTAL_BYTES - total_bytes))
            total_bytes += len(raw)
            issues.extend(profile_issues)
            if profile_issues:
                record["reason"] = "checkpoint_input_unavailable_or_truncated"
                continue
            if hashlib.sha256(raw).hexdigest() != digest:
                issues.append(fault("stale_profile", "checkpoint bytes differ from the event digest", severe=True))
                record["reason"] = "checkpoint_digest_mismatch"
                continue
            try:
                payload = parse_json(raw)
            except (ValueError, UnicodeError, RecursionError):
                payload = None
            if (not isinstance(payload, dict) or not bounded_structure({key: value for key, value in payload.items() if key != "data"}) or type(payload.get("schema")) is not int or payload["schema"] != 2
                    or payload.get("invocation") != invocation or payload.get("source_digest") != source_digest
                    or payload.get("process_birth_id") != process["process_id"] or type(payload.get("pid")) is not int or payload["pid"] != process["pid"]
                    or type(payload.get("checkpoint_seq")) is not int or payload["checkpoint_seq"] != seq or payload.get("mode") != event["mode"]
                    or payload.get("status") != event["status"]
                    or not isinstance(payload.get("julia"), str) or payload["julia"] != start.get("julia")
                    or type(payload.get("threads")) is not int or payload["threads"] <= 0 or payload["threads"] != start.get("threads")
                    or not profile_shape(payload)
                    or type(event.get("data_words")) is not int or event["data_words"] != len(payload["data"])
                    or (payload["status"] == "empty") != (len(payload["data"]) == 0)):
                issues.append(fault("profile_binding_fault", "checkpoint identity or shape differs from its process event", severe=True))
                record["reason"] = "checkpoint_identity_or_shape_fault"
                continue
            try:
                observations = profile_observations(payload, event)
            except ValueError:
                issues.append(fault("profile_observation_fault", "checkpoint symbolization or prefix metadata differs", severe=True))
                record["reason"] = "checkpoint_observation_fault"
                continue
            filename = f"profile-{len(records):04d}-{event['mode']}.json"
            # Sample words are validated UInt64 values, so only metadata needs path mapping.
            safe = mapping.value({key: value for key, value in payload.items() if key not in ("data", "lookup")})
            safe["data"] = payload["data"]
            safe["lookup"] = {address: mapping.value(frames) for address, frames in payload["lookup"].items()}
            # Do not trust a producer-supplied decoder verdict.
            safe["decoder_status"] = "RAW_PRESERVED_NATIVE_DECODER_UNVERIFIED"
            safe["measurement_scope"] = "cumulative_checkpoint; checkpoints overlap"
            (output / filename).write_text(json.dumps(safe, sort_keys=True, separators=(",", ":")) + "\n")
            record.update(observations, file=filename, status="RAW_PRESERVED", capture_status=payload["status"],
                          input_sha256=digest, data_words=len(payload["data"]), lookup_addresses=len(payload["lookup"]),
                          julia=payload["julia"], threads=payload["threads"],
                          decoder_status=safe["decoder_status"],
                          capture_seconds=event["capture_seconds"] if finite_number(event.get("capture_seconds")) and event["capture_seconds"] >= 0 else None)
    return records


def bound_phase_outcome(phase, issues):
    """Retain failures and reject a reported PASS that contradicts retirement."""
    normalized = phase.copy()
    status, semantic, code = phase.get("status"), phase.get("semantic_status"), phase.get("exit_code")
    reasons = []
    if status == "PASS":
        if phase.get("started") is not True:
            reasons.append("successful command was not admitted")
        if type(code) is not int or code != 0:
            reasons.append("successful command has no zero exit code")
        if semantic != "PASS":
            reasons.append("successful command contradicts its semantic verdict")
        if phase.get("direct_child_reaped") is not True or phase.get("cleanup_status") != "REAPED":
            reasons.append("successful command has unproved direct-child cleanup")
        if phase.get("soft_limit_exceeded") is True:
            reasons.append("successful command exceeded its soft limit")
        if phase.get("diagnostics_status") == "FAIL":
            reasons.append("successful command lost its required diagnostics")
    if semantic == "PASS" and code is not None and (type(code) is not int or code != 0):
        reasons.append("semantic PASS contradicts the original exit code")
    if reasons:
        issues.append(fault("phase_outcome_contradiction", "; ".join(reasons), severe=True, phase=phase.get("name")))
        normalized["reported_status"] = status
        normalized["reported_semantic_status"] = semantic
        normalized["status"] = "FAIL"
        if semantic == "PASS" and type(code) is int and code != 0:
            normalized["semantic_status"] = "FAIL"
    return normalized


def bound_supervisor_outcome(receipt, issues):
    normalized = receipt.copy()
    normalized["phases"] = [bound_phase_outcome(phase, issues) for phase in receipt.get("phases", [])]
    planned = receipt.get("required_phases")
    names = [phase.get("name") for phase in normalized["phases"]]
    planned_valid = (isinstance(planned, list) and bool(planned)
        and all(isinstance(name, str) and IDENTIFIER.fullmatch(name) for name in planned)
        and len(planned) == len(set(planned)))
    names_valid = all(isinstance(name, str) and IDENTIFIER.fullmatch(name) for name in names)
    inventory_complete = planned_valid and names_valid and len(names) == len(set(names)) and set(names) == set(planned)
    normalized["command_inventory_status"] = "COMPLETE" if inventory_complete else "PARTIAL"
    if normalized.get("status") == "PASS" and not inventory_complete:
        issues.append(fault("supervisor_inventory_contradiction", "supervisor PASS lacks every distinct required command receipt", severe=True))
        normalized["reported_status"], normalized["status"] = "PASS", "FAIL"
    loops = receipt.get("loops", {})
    if not isinstance(loops, dict) or any(not isinstance(loop, dict) for loop in loops.values()):
        issues.append(fault("receipt_loop_shape", "supervisor loop records rejected", severe=True))
        normalized["loops"] = {}
        normalized["reported_status"], normalized["status"] = receipt.get("status"), "FAIL"
    if normalized.get("status") == "PASS" and (any(phase.get("status") != "PASS" for phase in normalized["phases"])
            or any(loop.get("status") != "PASS" for loop in normalized.get("loops", {}).values())):
        issues.append(fault("supervisor_outcome_contradiction", "supervisor PASS contradicts a command or loop verdict", severe=True))
        normalized["reported_status"], normalized["status"] = "PASS", "FAIL"
    return normalized


def read_receipt(path, *, invocation, source_digest, mapping, issues):
    if path is None:
        issues.append(fault("receipt_missing", "supervisor completion and cleanup unavailable"))
        return None
    raw = input_bytes(path, mapping, issues)
    try:
        receipt = parse_json(raw)
    except (ValueError, UnicodeError, RecursionError):
        issues.append(fault("receipt_invalid", "supervisor receipt rejected", severe=True))
        return None
    if not isinstance(receipt, dict) or not bounded_structure(receipt) or receipt.get("invocation") != invocation or receipt.get("source_digest") != source_digest:
        issues.append(fault("stale_receipt", "supervisor invocation or source differs", severe=True))
        return None
    if not isinstance(receipt.get("phases", []), list) or any(not isinstance(phase, dict) for phase in receipt.get("phases", [])):
        issues.append(fault("receipt_shape", "supervisor phase records rejected", severe=True))
        return None
    if any(phase.get("invocation", invocation) != invocation or phase.get("source_digest", source_digest) != source_digest
           for phase in receipt.get("phases", [])):
        issues.append(fault("stale_phase", "phase invocation or source differs from its supervisor", severe=True))
        return None
    return mapping.value(bound_supervisor_outcome(receipt, issues))


def receipt_complete(receipt, processes):
    if not receipt or type(receipt.get("schema_version")) is not int or receipt["schema_version"] < 4:
        return False
    planned, phases = receipt.get("required_phases"), receipt.get("phases")
    if (not isinstance(planned, list) or not planned or not isinstance(phases, list)
            or not all(isinstance(name, str) for name in planned)
            or not all(isinstance(phase.get("name"), str) for phase in phases)):
        return False
    names = [phase.get("name") for phase in phases]
    expected_processes = receipt.get("test_process_birth_ids")
    for phase in phases:
        expected = phase.get("test_process_birth_ids")
        if (not isinstance(expected, list) or any(not isinstance(birth, str) or not IDENTIFIER.fullmatch(birth) for birth in expected)
                or len(expected) != len(set(expected))
                or set(expected) != {process["process_id"] for process in processes if process.get("phase") == phase["name"]}):
            return False
        inventory = phase.get("expected_test_file_inventory")
        if (not isinstance(inventory, dict) or inventory.get("source_digest") != receipt.get("source_digest")
                or not isinstance(inventory.get("files"), list) or not inventory["files"]
                or any(not isinstance(item, dict) or not portable_file(item.get("path"))
                       or not isinstance(item.get("sha256"), str) or not SHA256.fullmatch(item["sha256"])
                       for item in inventory["files"])):
            return False
        expected_files = [item["path"] for item in inventory["files"]]
        observed_files = {file for process in processes if process.get("phase") == phase["name"]
                          for file in process["file_coverage"]["declared"]}
        if len(expected_files) != len(set(expected_files)) or set(expected_files) != observed_files:
            return False
    if any(process.get("phase") not in names for process in processes):
        return False
    return (receipt.get("status") in ("PASS", "FAIL") and receipt.get("coverage_complete") is True
            and receipt.get("test_inventory_complete") is True and receipt.get("active_phase") is None
            and not receipt.get("active_phases") and not receipt.get("pending_phases")
            and len(names) == len(set(names)) == len(planned) == len(set(planned)) and set(names) == set(planned)
            and all(phase.get("status") in ("PASS", "FAIL") and phase.get("started") is True
                    and phase.get("direct_child_reaped") is True and phase.get("coverage_complete") is True
                    and phase.get("diagnostics_status") == "PASS" for phase in phases)
            and isinstance(expected_processes, list) and bool(expected_processes)
            and all(isinstance(identifier, str) and IDENTIFIER.fullmatch(identifier) for identifier in expected_processes)
            and len(expected_processes) == len(set(expected_processes))
            and set(expected_processes) == {process["process_id"] for process in processes}
            and all(process["test_bodies_complete"] for process in processes))


def timing_rows(processes, receipt):
    rows = []
    for process in processes:
        for ts in process["testsets"]:
            start, finish = ts["start"], ts["finish"] or {}
            rows.append(dict(kind="testset", name=ts["qualified_name"], process_id=process["process_id"],
                             seconds=finish.get("seconds"), outcome=finish.get("body_outcome", finish.get("body_completion", "unknown")),
                             file=start.get("file"), line=start.get("line"), metric_scope=finish.get("metric_scope", "unavailable"),
                             allocation_bytes=finish.get("allocation_bytes"), gc_seconds=finish.get("gc_seconds"),
                             compile_seconds=finish.get("compile_seconds"), compile_status=finish.get("compile_status", "unavailable")))
        for span in process["spans"]:
            rows.append(dict(kind=span.get("kind", "span"), name=span.get("label", "unknown"), process_id=process["process_id"],
                             seconds=span.get("seconds"), outcome=span.get("outcome", "unknown"), metric_scope="inclusive_span"))
    if receipt:
        for name, loop in receipt.get("loops", {}).items():
            if isinstance(loop, dict):
                rows.append(dict(kind="whole_loop", name=name, process_id="supervisor",
                    seconds=loop.get("seconds"), outcome=loop.get("status", "unknown"),
                    metric_scope="whole_loop_orchestration; overlaps commands and contained loops"))
        for phase in receipt.get("phases", []):
            name = phase.get("name", "unknown")
            rows.append(dict(kind="whole_command", name=name, process_id="supervisor",
                             seconds=phase.get("seconds"), outcome=phase.get("status", "unknown"), metric_scope="startup_execution_retirement_inclusive"))
            timings = phase.get("timings", {})
            if isinstance(timings, dict):
                for metric, value in timings.items():
                    if metric == "first_output_byte" and isinstance(value, dict):
                        observed = value.get("status") == "OBSERVED" and finite_number(value.get("seconds")) and value["seconds"] >= 0
                        rows.append(dict(kind="command_landmark", name=f"{name}: {metric}", process_id="supervisor",
                            seconds=value["seconds"] if observed else None, outcome="OBSERVED" if observed else "UNAVAILABLE",
                            metric_scope="parent_read_observation; combined_stdout_stderr_including_telemetry; readiness=UNPROVED; elapsed_from_command_start; overlaps whole_command"))
                        continue
                    component = metric in ("popen_seconds", "diagnostic_finalization_seconds")
                    rows.append(dict(kind="command_component" if component else "command_landmark",
                        name=f"{name}: {metric}", process_id="supervisor",
                        seconds=value if finite_number(value) else None,
                        outcome=phase.get("status", "unknown") if finite_number(value) else "UNAVAILABLE",
                        metric_scope="inclusive_component; overlaps whole_command" if component
                                     else "elapsed_from_command_start; overlaps whole_command"))
                observed, reaped = timings.get("exit_observed_seconds"), timings.get("reaped_seconds")
                if finite_number(observed) and finite_number(reaped) and reaped >= observed:
                    rows.append(dict(kind="reaping", name=name, process_id="supervisor", seconds=reaped-observed,
                        outcome=phase.get("cleanup_status", "unknown"), metric_scope="exit_observation_to_reaping; overlaps whole_command"))
            observer = phase.get("output_observer")
            if isinstance(observer, dict):
                for metric, field, scope in (("work", "work_seconds", "reader_wall_work"), ("cpu", "cpu_seconds", "reader_thread_cpu")):
                    measured = finite_number(observer.get(field)) and observer[field] >= 0
                    rows.append(dict(kind="diagnostic_overhead", name=f"{name}: output_observer_{metric}", process_id="supervisor",
                        seconds=observer[field] if measured else None, outcome=observer.get("status", "UNAVAILABLE") if measured else "UNAVAILABLE",
                        metric_scope=scope + "; inclusive_read_write_decode_forward; overlaps whole_command and other observer metrics"))
    for row in rows:
        if not finite_number(row.get("seconds")) or row["seconds"] < 0:
            row["seconds"] = None
    return sorted(rows, key=lambda row: -(row["seconds"] if row["seconds"] is not None else -1))


def junit(report):
    root = ET.Element("testsuites")
    for process in report["processes"]:
        suite = ET.SubElement(root, "testsuite", name=process["process_id"])
        properties = ET.SubElement(suite, "properties")
        for key, value in dict(scope="diagnostic_units; native assertion totals are separate", count_scope=process["count_scope"],
                               failure_detail_status=process["failure_details"]["status"], **process["assertion_counts"]).items():
            ET.SubElement(properties, "property", name=key, value=str(value))
        for ts in process["testsets"]:
            start, finish = ts["start"], ts["finish"] or {}
            case = ET.SubElement(suite, "testcase", name=ts["qualified_name"], classname="testset-body")
            if start.get("file"):
                case.set("file", start["file"])
            body = finish.get("body_outcome", finish.get("body_completion", "unknown"))
            if start.get("line"):
                case.set("line", str(start["line"]))
            if body == "nonlocal_exit":
                ET.SubElement(case, "skipped", message="UNKNOWN: nonlocal exit leaves later body coverage unproved")
            elif body in ("interrupted", "threw") and not body_completed(ts):
                ET.SubElement(case, "error", type=body, message="body did not complete normally; finalization does not prove PASS")
            elif body == "threw":
                ET.SubElement(case, "failure", type="CompletedFailedBody", message="native Error counts prove completed-and-failed; see original assertions")
            elif body != "returned":
                ET.SubElement(case, "skipped", message="UNKNOWN: body completion unavailable")
        for problem in process["assertion_problems"]:
            case = ET.SubElement(suite, "testcase", name=f"{problem['qualified_name']} > assertion-{problem['seq']}", classname="native-assertion-problem")
            if problem.get("file"):
                case.set("file", problem["file"])
            if problem.get("line"):
                case.set("line", str(problem["line"]))
            tag = "failure" if problem.get("result_type") == "Fail" else "error"
            detail, availability = native_detail(problem)
            node = ET.SubElement(case, tag, type=problem.get("problem_kind", "unknown"),
                                 message=f"native {problem.get('result_type', 'problem')}; detail={availability}")
            node.text = detail
        known = {"failed": sum(problem.get("result_type") == "Fail" for problem in process["assertion_problems"]),
                 "errored": sum(problem.get("result_type") == "Error" for problem in process["assertion_problems"])}
        if any(process["assertion_counts"][key] > known[key] for key in known):
            case = ET.SubElement(suite, "testcase", name="unobserved-native-problems", classname="diagnostics")
            ET.SubElement(case, "error", type="MissingNativeDetail", message="native counts prove additional problems without emitted detail")
        if not process["test_bodies_complete"]:
            case = ET.SubElement(suite, "testcase", name="partial-process", classname="diagnostics")
            ET.SubElement(case, "error", type="IncompleteDiagnostics", message="observed counts are lower bounds; complete inventory unproved")
    if report["supervisor"]:
        suite = ET.SubElement(root, "testsuite", name="supervisor")
        verdict = report["supervisor"].get("status", "UNKNOWN")
        case = ET.SubElement(suite, "testcase", name="whole-check-verdict", classname="supervisor")
        if verdict == "FAIL":
            ET.SubElement(case, "failure", type="CheckFailure", message="original supervisor verdict retained")
        elif verdict != "PASS":
            ET.SubElement(case, "error", type=str(verdict), message="whole-check completion unproved")
        for name, loop in report["supervisor"].get("loops", {}).items():
            if not isinstance(loop, dict):
                continue
            case = ET.SubElement(suite, "testcase", name=name, classname="whole-loop")
            if loop.get("status") == "FAIL":
                measured, budget = loop.get("seconds"), loop.get("budget_seconds")
                soft = loop.get("soft_limit_exceeded") is True or (finite_number(measured) and finite_number(budget) and measured >= budget)
                ET.SubElement(case, "failure", type="SoftLimit" if soft else "LoopFailure",
                    message=f"seconds={measured}; budget_seconds={budget}; complete={loop.get('complete')}")
            elif loop.get("status") != "PASS":
                ET.SubElement(case, "error", type=str(loop.get("status", "UNKNOWN")), message="loop completion unproved")
        for phase in report["supervisor"].get("phases", []):
            case = ET.SubElement(suite, "testcase", name=str(phase.get("name") or "unknown"), classname="process-phase")
            if phase.get("status") == "FAIL":
                ET.SubElement(case, "failure", type="SoftLimit" if phase.get("soft_limit_exceeded") else "PhaseFailure",
                              message=f"semantic_status={phase.get('semantic_status')}; exit_code={phase.get('exit_code')}")
            elif phase.get("status") != "PASS":
                ET.SubElement(case, "error", type=str(phase.get("status", "UNKNOWN")), message="phase completion or cleanup unproved")
    if report["issues"]:
        suite = ET.SubElement(root, "testsuite", name="artifact-integrity")
        for index, item in enumerate(report["issues"], 1):
            case = ET.SubElement(suite, "testcase", name=f"integrity-{index}", classname="diagnostics")
            ET.SubElement(case, "error" if item["severe"] else "skipped", type=item["kind"], message=item["detail"])
    for suite in root:
        cases = suite.findall("testcase")
        suite.set("tests", str(len(cases)))
        for key, tag in (("failures", "failure"), ("errors", "error"), ("skipped", "skipped")):
            suite.set(key, str(sum(case.find(tag) is not None for case in cases)))
    return ET.tostring(root, encoding="unicode", xml_declaration=True) + "\n"


PROGRESS_PREFIX = "LIBTMUX_TEST_PROGRESS "
UNPARSED_PROGRESS = "[unparsed diagnostic progress redacted]"


def decoded_progress(line):
    if not line.startswith(PROGRESS_PREFIX) or len(line.encode("utf-8")) > MAX_RECORD_BYTES:
        return None
    try:
        value = parse_json(line[len(PROGRESS_PREFIX):])
    except (ValueError, UnicodeError, RecursionError):
        return None
    return value if type(value) is dict and bounded_structure(value) else None


def sanitized_original_text(text, mapping, *, issues=None):
    output, redacted = [], 0
    for line in text.split("\n"):
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        packet = decoded_progress(body)
        if packet is not None:
            output.append(PROGRESS_PREFIX + json.dumps(mapping.value(packet), sort_keys=True) + ending)
        elif body.startswith(PROGRESS_PREFIX):
            output.append(UNPARSED_PROGRESS + ending)
            redacted += 1
        else:
            output.append(mapping.text(line))
    if redacted and issues is not None:
        issues.append(fault("unparsed_progress_redacted", "original byte hash retained; public progress payload unavailable",
                            records=redacted))
    return "\n".join(output)


def export_strings(path):
    """Inspect decoded values so XML syntax and JSON escapes cannot hide paths."""
    def strings(value):
        kind = type(value)
        if kind is str:
            yield value
        elif kind is list:
            if not set(map(type, value)) & {str, list, dict}:
                return
            for item in value:
                if type(item) is str:
                    yield item
                elif type(item) is list or type(item) is dict:
                    yield from strings(item)
        elif kind is dict:
            for key, item in value.items():
                yield key
                if type(item) is str:
                    yield item
                elif type(item) is list or type(item) is dict:
                    yield from strings(item)
    if path.suffix == ".json":
        yield from strings(json.loads(path.read_text()))
    elif path.suffix == ".jsonl":
        for line in path.read_text().splitlines():
            yield from strings(json.loads(line))
    elif path.suffix == ".xml":
        for node in ET.fromstring(path.read_text()).iter():
            yield from node.attrib.values()
            if node.text:
                yield node.text
            if node.tail:
                yield node.tail
    elif path.suffix == ".csv":
        with path.open(newline="") as stream:
            for row in csv.reader(stream):
                yield from row
    else:
        for line in path.read_text().split("\n"):
            packet = decoded_progress(line)
            if packet is not None:
                yield from strings(packet)
            elif line.startswith(PROGRESS_PREFIX):
                raise ValueError("unparsed diagnostic progress")
            else:
                yield line


def unsafe_export(path):
    try:
        return any(PRIVATE_PATH_REJECT.search(value) or ABSOLUTE_PATH.search(value) for value in export_strings(path))
    except (ValueError, UnicodeError, RecursionError, ET.ParseError):
        return True


def write_bundle(evidence, event_paths, *, invocation, expected_source_digest, mapping,
                 output, receipt=None, logs=(), extra_report=None, snapshots=()):
    """Write a private build; callers publish only after the reject scan."""
    started = time.monotonic()
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if output.is_symlink() or any(output.iterdir()):
        raise ValueError("output must be a fresh owned directory")
    issues, processes = evidence["issues"], evidence["processes"]
    complete = not issues and receipt_complete(receipt, processes)
    counts = {key: sum(process["assertion_counts"][key] for process in processes) for key in COUNT_KEYS}
    native_failed = counts["failed"] + counts["errored"] > 0 or any(process["assertion_problems"] for process in processes)
    supervisor_failed = receipt and (receipt.get("status") != "PASS" or any(phase.get("status") != "PASS" or phase.get("soft_limit_exceeded") for phase in receipt.get("phases", [])))
    test_status = "FAIL" if native_failed or supervisor_failed else "PASS" if complete else "UNKNOWN"
    report = dict(schema=1, invocation=invocation, source_digest=expected_source_digest,
                  test_status=test_status, coverage_status="COMPLETE" if complete else "PARTIAL",
                  assertion_counts=counts, count_scope="native_total" if complete else "observed_lower_bound",
                  processes=processes, supervisor=receipt, issues=issues, original_logs=[],
                  profile_copy_status="UNAVAILABLE", diagnostics_complete=False,
                  failure_detail_status=detail_counts(counts, [problem for process in processes for problem in process["assertion_problems"]])["status"],
                  limitations=["Raw profile checkpoints need independent native Julia decoding proof.",
                               "Nested timings and process-wide GC/allocation counters overlap.",
                               "Complete native inventory requires an explicit source-bound supervisor proof.",
                               "Profile copying is bounded to 32 checkpoints, 32 MiB each and 128 MiB total.",
                               "Original logs are bounded snapshots; direct-child reap does not prove descendants stopped writing.",
                               "Assembly time covers bundle rendering; the supervisor times input collection and publication as finalizer overhead."])
    report.update(extra_report or {})
    report["profile_metadata"] = []
    report["profile_records"] = copy_profiles(processes, event_paths, invocation=invocation,
        source_digest=expected_source_digest, mapping=mapping, output=output, issues=issues, metadata=report["profile_metadata"])
    retained = [record for record in report["profile_records"] if record["status"] == "RAW_PRESERVED"]
    copied, attempted = len(retained), len(report["profile_records"])
    report["profile_copy_status"] = ("PARTIAL" if copied < attempted else "RAW_PRESERVED") if copied else "UNAVAILABLE"
    symbols = {record["symbolization_status"] for record in retained}
    report["profile_symbolization_status"] = ("COMPLETE" if symbols == {"COMPLETE"} else
        "UNAVAILABLE" if not symbols or symbols == {"UNAVAILABLE"} else "PARTIAL")
    report["profile_sample_coverage_status"] = "UNPROVED"
    report["profile_checkpoint_counts"] = dict(attempted=attempted, copied=copied)
    report["profile_copy_scope"] = "attempted checkpoint payloads only; not complete sampling/process/time coverage"
    request = report.get("profile_request")
    report["profile_request_status"] = "UNVERIFIED"
    if request is not None:
        valid = (isinstance(request, dict) and request.get("mode") in ("off", "cpu", "wall")
            and request.get("symbolization") in ("native", "deferred")
            and type(request.get("require_direct_native")) is bool
            and not (request["require_direct_native"] and request["mode"] == "off"))
        if not valid:
            report["profile_request_status"] = "FAIL"
        elif request["mode"] == "off":
            report["profile_request_status"] = "NOT_REQUESTED"
        elif request["require_direct_native"]:
            direct_birth = report.get("direct_process_birth_id")
            direct_profiles = [event for process in processes if process["process_id"] == direct_birth
                               for event in process["profiles"]]
            starts = [event for event in direct_profiles if event["event"] == "profile_start"]
            start_matches = (len(starts) == 1 and starts[0].get("mode") == request["mode"]
                             and starts[0].get("symbolization_policy") == request["symbolization"])
            checkpoints_match = start_matches and all(
                event.get("mode") == request["mode"] and event.get("symbolization_policy") == request["symbolization"]
                and event["seq"] > starts[0]["seq"]
                for event in direct_profiles if event["event"] == "profile_checkpoint")
            selected = [record for record in retained if record["process_id"] == direct_birth
                        and record["mode"] == request["mode"]
                        and record["symbolization_policy"] == request["symbolization"]]
            report["profile_request_status"] = ("CAPTURED" if any(record["data_words"] > 0 for record in selected)
                else "EMPTY") if checkpoints_match and selected else "FAIL"
        if report["profile_request_status"] == "FAIL":
            issues.append(fault("missing_requested_profile", "admitted native sampler start or bound raw checkpoint unavailable", severe=True))
            report["check_status"] = "FAIL"
    with (output / "partial-progress.jsonl").open("w") as stream:
        for process in processes:
            for event in process["events"]:
                stream.write(json.dumps(event, sort_keys=True) + "\n")
                stream.flush()
    for index, item in enumerate(logs, 1):
        if (not isinstance(item, dict) or item.get("invocation") != invocation or item.get("source_digest") != expected_source_digest
                or not isinstance(item.get("phase"), str) or not IDENTIFIER.fullmatch(item["phase"])):
            issues.append(fault("unbound_log", "original log binding rejected", severe=True))
            continue
        if receipt is not None and item["phase"] not in {phase.get("name") for phase in receipt.get("phases", [])}:
            issues.append(fault("log_phase_binding_fault", "original log phase differs from its supervisor", severe=True))
            continue
        if (not isinstance(item.get("path"), (str, Path)) or not isinstance(item.get("input_sha256"), str)
                or not SHA256.fullmatch(item["input_sha256"])):
            issues.append(fault("log_digest_missing", "original log has no input-byte binding", severe=True))
            continue
        raw = input_bytes(item["path"], mapping, issues)
        digest = hashlib.sha256(raw).hexdigest()
        if digest != item["input_sha256"]:
            issues.append(fault("stale_log", "original log bytes differ from its bound receipt", severe=True))
            continue
        filename = f"original-log-{index:04d}.txt"
        (output / filename).write_text(sanitized_original_text(raw.decode("utf-8", errors="replace"), mapping, issues=issues))
        report["original_logs"].append(dict(file=filename, phase=mapping.text(item["phase"]), input_sha256=digest,
            process_birth_id=item.get("process_birth_id"), binding_scope=item.get("binding_scope", "explicit_log_byte_binding")))
    for snapshot in snapshots:
        filename = snapshot["file"]
        if not isinstance(filename, str) or not IDENTIFIER.fullmatch(filename):
            raise ValueError("snapshot export needs a portable filename")
        (output / filename).write_text(mapping.text(snapshot["text"]))
    rows = timing_rows(processes, receipt)
    columns = ["kind", "name", "process_id", "seconds", "outcome", "file", "line", "metric_scope", "allocation_bytes", "gc_seconds", "compile_seconds", "compile_status"]
    with (output / "timings.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    (output / "junit.xml").write_text(junit(report))
    summary = [f"Supervisor verdict: {report.get('check_status', (receipt or {}).get('status', 'UNVERIFIED'))}.",
               f"Tests: {test_status}. Coverage: {report['coverage_status']}.",
               f"Requested sampler: {request.get('mode', 'unverified') if isinstance(request, dict) else 'unverified'}. Capture contract: {report['profile_request_status']}. Sample/process/time coverage remains UNPROVED.",
               f"Checkpoint copy: {report['profile_copy_status']} ({copied}/{attempted}). Symbolization: {report['profile_symbolization_status']}. Sample/process/time coverage: UNPROVED.",
               f"Invocation: {invocation}. Source digest: {expected_source_digest}.",
               f"Assertion counts ({report['count_scope']}): {json.dumps(report['assertion_counts'], sort_keys=True)}.",
               f"Original assertion/error details: {report['failure_detail_status']}.",
               "JUnit case counts represent diagnostic units, not native assertion totals.", "", "Process identity:"]
    for process in processes:
        identity = process["events"][0] if process["events"] else {}
        summary.append(f"{process['process_id']}: pid={process['pid']}; phase={process.get('phase')}; Julia={identity.get('julia', 'unavailable')}; threads={identity.get('threads', 'unavailable')}.")
    if retained:
        summary.extend(["", "Profile checkpoints:"])
        summary.extend(f"{record['process_id']} {record['mode']} checkpoint {record['checkpoint_seq']}: symbols={record['symbolization_status']}; unresolved_addresses={record['unresolved_addresses']}; buffer_full={record['buffer_full']}; truncated={record['truncated']}." for record in retained)
    warnings = [item for item in report["profile_metadata"] if item["metadata_kind"] == "availability"]
    if warnings:
        summary.extend(["", "Profile availability warnings:"])
        summary.extend(f"{item['process_id']} {item.get('mode', 'unknown')}: {item.get('reason', item['event'])}." for item in warnings)
    summary.extend(["", "Command verdict and cleanup:"])
    for phase in (receipt or {}).get("phases", []):
        summary.append(f"{phase.get('name')}: status={phase.get('status')}; semantic_status={phase.get('semantic_status', 'unavailable')}; exit_code={phase.get('exit_code', 'unavailable')}; soft_limit_exceeded={phase.get('soft_limit_exceeded', False)}; cleanup={phase.get('cleanup_status', 'unavailable')}; direct_child_reaped={phase.get('direct_child_reaped', False)}.")
        if phase.get("cleanup"):
            summary.append(str(phase["cleanup"]))
        observer = phase.get("output_observer")
        if isinstance(observer, dict):
            summary.append(f"{phase.get('name')} output observer: status={observer.get('status', 'UNAVAILABLE')}; reader_retired={observer.get('reader_retired', False)}; eof_observed={observer.get('eof_observed', False)}; bytes={observer.get('bytes', 'unavailable')}; forwarded_progress_records={observer.get('forwarded_records', 'unavailable')}; rejected_progress_records={observer.get('rejected_records', 'unavailable')}. Progress records are transport counts, not assertion totals; first output does not prove application readiness.")
    if report.get("receipt_timing_boundary"):
        summary.extend(["", "Receipt timing boundary: " + report["receipt_timing_boundary"] + "."])
    if report.get("snapshot_kind") == "LIVE_PREFIX":
        binding = report["snapshot_binding"]
        summary.extend(["", f"LIVE_PREFIX: snapshot {binding['snapshot_ordinal']}, phase {binding['phase']}, process {binding['process_birth_id']}, through record {binding['through_sequence']}.",
                        "Admission and the retained prefix are bound; command completion and complete coverage remain unproved."])
    if report.get("setup_reason"):
        summary.extend(["", "Setup evidence: " + report["setup_reason"] + ".", "Setup snapshots do not prove test execution."])
    if report.get("phase_bundles"):
        summary.extend(["", "Phase artifacts (counts remain separate):"])
        summary.extend(f"{item['phase']}: final command={item['command_status']}; artifact={item['artifact_status']}; profiles={item.get('profile_copy_status', 'unavailable')}; symbols={item.get('profile_symbolization_status', 'unavailable')}; bundle={item.get('bundle', 'unavailable')}." for item in report["phase_bundles"])
    summary.extend(["", "Ranked timings:"])
    summary.extend(f"{row['seconds'] if row['seconds'] is not None else 'unavailable'}s {row['kind']} {row['name']} ({row['outcome']})" for row in rows)
    summary.extend(["", "Limitations:"] + report["limitations"])
    (output / "summary.txt").write_text(mapping.text("\n".join(summary) + "\n"))
    report["redacted_absolute_paths"] = mapping.redacted_paths + evidence["redacted_absolute_paths"]
    report["export_status"] = "FAIL" if any(item["severe"] for item in issues) or any(item["severe"] for process in processes for item in process["issues"]) else "PASS"
    report["assembly_seconds"] = time.monotonic() - started
    (output / "diagnostics.json").write_text(json.dumps(mapping.value(report), indent=2, sort_keys=True) + "\n")
    manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in output.iterdir() if path.is_file()}
    (output / "manifest.json").write_text(json.dumps(dict(schema=1, invocation=invocation, source_digest=expected_source_digest, files=manifest), indent=2, sort_keys=True) + "\n")
    unsafe = [path.name for path in output.iterdir() if unsafe_export(path)]
    if unsafe:
        # A rejected export keeps no uploadable unsafe payload.
        for filename in unsafe:
            (output / filename).unlink()
        raise ValueError("export reject scan found an absolute path")
    return report


def publish_bundle(evidence, event_paths, *, invocation, expected_source_digest,
                   mapping, output, receipt=None, logs=(), extra_report=None, snapshots=(), validate_report=None):
    """Expose only a complete sanitized bundle, including its hash manifest.

A killed exporter can leave its private build, but the workflow never uploads
that build. Evidence coverage may remain partial even when publication succeeds.
"""
    require_binding(invocation, expected_source_digest)
    output = Path(output)
    if not mapping.owns(output) or output.exists() or output.is_symlink():
        raise ValueError("output must be a fresh directory inside an owned root")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".artifact-build-", dir=output.parent) as temporary:
        build = Path(temporary) / "bundle"
        report = write_bundle(evidence, event_paths, invocation=invocation,
                              expected_source_digest=expected_source_digest, mapping=mapping,
                              output=build, receipt=receipt, logs=logs, extra_report=extra_report, snapshots=snapshots)
        if validate_report is not None:
            validate_report(report)
        build.replace(output)
    return report


def assemble(event_paths, *, invocation, expected_source_digest, source_roots, output,
             supervisor_path=None, logs=(), expected_phase=None):
    """Export the same bounded native evidence used by supervisor verification."""
    event_paths = tuple(event_paths)
    evidence = collect_process_evidence(event_paths, invocation=invocation,
        expected_source_digest=expected_source_digest, source_roots=source_roots,
        expected_phase=expected_phase)
    mapping = SourceMap(source_roots)
    receipt = read_receipt(supervisor_path, invocation=invocation,
        source_digest=expected_source_digest, mapping=mapping, issues=evidence["issues"])
    return publish_bundle(evidence, event_paths, invocation=invocation,
        expected_source_digest=expected_source_digest, mapping=mapping, output=output,
        receipt=receipt, logs=logs)


def assemble_checkpoint(event_paths, *, invocation, expected_source_digest, source_roots,
                        output, admission_path, expected_phase, expected_direct_birth,
                        snapshot_ordinal, through_sequence):
    """Publish an admitted, flushed native prefix without a completion verdict.

Read only through the notified start/checkpoint/assertion sequence. Later producer
writes are outside this snapshot. The caller owns finite export/cleanup limits
and gives every generation a fresh output directory.
"""
    require_binding(invocation, expected_source_digest)
    event_paths = tuple(event_paths)
    if (len(event_paths) != 1 or type(snapshot_ordinal) is not int or snapshot_ordinal <= 0
            or type(through_sequence) is not int or through_sequence <= 0
            or not isinstance(expected_phase, str) or not IDENTIFIER.fullmatch(expected_phase)
            or not isinstance(expected_direct_birth, str) or not IDENTIFIER.fullmatch(expected_direct_birth)):
        raise ValueError("checkpoint requires one stream, portable identities and positive ordinal/sequence")
    mapping = SourceMap(source_roots)
    event_path, admission_path = Path(event_paths[0]), Path(admission_path)
    if (not mapping.owns(event_path) or not mapping.owns(admission_path)
            or event_path.parent.resolve() != admission_path.parent.resolve()):
        raise ValueError("checkpoint stream and admission must share an owned phase directory")
    issues = []
    admission_raw = input_bytes(admission_path, mapping, issues, limit=MAX_RECORD_BYTES)
    try:
        admission = parse_json(admission_raw)
    except (ValueError, UnicodeError, RecursionError):
        admission = None
    if (issues or not isinstance(admission, dict) or not bounded_structure(admission)
            or admission.get("invocation") != invocation or admission.get("source_digest") != expected_source_digest
            or admission.get("name") != expected_phase or admission.get("started") is not True
            or type(admission.get("pid")) is not int or admission["pid"] <= 0
            or not isinstance(admission.get("process_token"), str) or not IDENTIFIER.fullmatch(admission["process_token"])
            or f"{admission['process_token']}-{admission['pid']}" != expected_direct_birth):
        raise ValueError("checkpoint admission identity is missing or stale")
    # A growing trailing record must not invalidate an earlier flushed marker.
    prefix = bytearray()
    try:
        with event_path.open("rb") as stream:
            for _ in range(through_sequence):
                line = stream.readline(MAX_RECORD_BYTES + 1)
                if (not line.endswith(b"\n") or len(line) > MAX_RECORD_BYTES
                        or len(prefix) + len(line) > MAX_INPUT_BYTES):
                    raise ValueError("checkpoint prefix is missing, truncated or exceeds its bound")
                prefix.extend(line)
    except OSError as error:
        raise ValueError("checkpoint prefix could not be read") from error
    with tempfile.TemporaryDirectory(prefix=".checkpoint-input-", dir=event_path.parent) as temporary:
        copied = Path(temporary) / "prefix.jsonl"
        copied.write_bytes(prefix)
        evidence = collect_process_evidence([copied], invocation=invocation,
            expected_source_digest=expected_source_digest, source_roots=source_roots,
            expected_phase=expected_phase)
    process = evidence["processes"][0]
    if (evidence["issues"] or any(item["severe"] for item in process["issues"])
            or not process["source_bound"] or process["process_id"] != expected_direct_birth
            or process["pid"] != admission["pid"] or process["phase"] != expected_phase
            or len(process["events"]) != through_sequence):
        raise ValueError("checkpoint prefix identity or structure differs from admission")
    marker = process["events"][-1]
    if marker["event"] not in ("process_start", "profile_checkpoint", "assertion_problem") or marker["seq"] != through_sequence:
        raise ValueError("checkpoint prefix does not end at a supported flushed marker")
    process["input_name"] = mapping.text(event_path.name)
    binding = dict(phase=expected_phase, process_birth_id=expected_direct_birth, pid=admission["pid"],
        snapshot_ordinal=snapshot_ordinal, through_sequence=through_sequence,
        event_prefix_bytes=len(prefix), event_prefix_sha256=hashlib.sha256(prefix).hexdigest(),
        admission_sha256=hashlib.sha256(admission_raw).hexdigest(), marker=marker["event"])
    if marker["event"] == "profile_checkpoint":
        binding.update(checkpoint_seq=marker.get("checkpoint_seq"), profile_input_sha256=marker.get("input_sha256"),
                       profile_mode=marker.get("mode"))
    native_failed = (process["assertion_counts"]["failed"] + process["assertion_counts"]["errored"] > 0
                     or bool(process["assertion_problems"]))
    extra = dict(snapshot_kind="LIVE_PREFIX", snapshot_binding=binding,
        check_status="FAIL" if native_failed else "UNKNOWN", test_inventory_complete=False,
        child_inventory_status="UNPROVED", observed_file_coverage_complete=False,
        receipt_timing_boundary="live admitted prefix; no completion, exit, reaping or whole-command timing proof")
    def validate(report):
        if report["export_status"] != "PASS":
            raise ValueError("checkpoint publication rejected invalid evidence")
        if marker["event"] == "profile_checkpoint":
            selected = [item for item in report["profile_records"] if item["process_id"] == expected_direct_birth
                        and item["checkpoint_seq"] == marker.get("checkpoint_seq")
                        and item.get("input_sha256") == marker.get("input_sha256")]
            if (len(selected) != 1 or selected[0]["status"] != "RAW_PRESERVED"
                    or report["profile_copy_status"] != "RAW_PRESERVED"):
                raise ValueError("checkpoint publication has no retained bound payload")
    return publish_bundle(evidence, event_paths, invocation=invocation,
        expected_source_digest=expected_source_digest, mapping=mapping, output=output,
        extra_report=extra, validate_report=validate)


def assemble_phase(event_paths, *, invocation, expected_source_digest, source_roots,
                   output, phase_path, expected_phase, expected_direct_birth=None):
    """Bind one admitted phase and publish its native evidence without recounting.

The phase receipt authenticates the direct child; observed children cannot prove
complete child admission. Unit and normal runs retain separate assertion counts.
A process-only phase preserves its command verdict without inventing test counts.
"""
    event_paths = tuple(event_paths)
    evidence = collect_process_evidence(event_paths, invocation=invocation,
        expected_source_digest=expected_source_digest, source_roots=source_roots,
        expected_phase=expected_phase)
    mapping = SourceMap(source_roots)
    issues = evidence["issues"]
    raw = input_bytes(phase_path, mapping, issues)
    try:
        phase = parse_json(raw)
    except (ValueError, UnicodeError, RecursionError):
        phase = None
    if (not isinstance(phase, dict) or not bounded_structure(phase)
            or phase.get("invocation") != invocation
            or phase.get("source_digest") != expected_source_digest
            or phase.get("name") != expected_phase):
        issues.append(fault("phase_receipt_binding_fault", "admitted phase receipt rejected", severe=True))
        phase = None
    direct_birth = None
    if phase is not None and phase.get("started") is True:
        token, pid = phase.get("process_token"), phase.get("pid")
        if (not isinstance(token, str) or not IDENTIFIER.fullmatch(token)
                or type(pid) is not int or pid <= 0):
            issues.append(fault("direct_child_binding_fault", "phase direct-child identity rejected", severe=True))
            phase = None
        else:
            direct_birth = f"{token}-{pid}"
            if not IDENTIFIER.fullmatch(direct_birth):
                issues.append(fault("direct_child_binding_fault", "direct birth exceeds the portable identifier bound", severe=True))
                phase = None
            if expected_direct_birth is not None and expected_direct_birth != direct_birth:
                issues.append(fault("direct_child_binding_fault", "admitted direct birth differs from its receipt", severe=True))
                phase = None
    elif expected_direct_birth is not None:
        issues.append(fault("direct_child_binding_fault", "expected direct child was not admitted", severe=True))
        phase = None
    if phase is not None:
        phase = bound_phase_outcome(phase, issues)
    expected_files, inventory_valid, matches = set(), False, False
    if phase is not None:
        inventory = phase.get("expected_test_file_inventory")
        if inventory is not None:
            inventory_valid = (isinstance(inventory, dict)
                and inventory.get("source_digest") == expected_source_digest
                and isinstance(inventory.get("files"), list) and bool(inventory["files"])
                and all(isinstance(item, dict) and portable_file(item.get("path"))
                        and isinstance(item.get("sha256"), str) and SHA256.fullmatch(item["sha256"])
                        for item in inventory["files"]))
            if inventory_valid:
                expected_files = {item["path"] for item in inventory["files"]}
                inventory_valid = len(expected_files) == len(inventory["files"])
            if not inventory_valid:
                issues.append(fault("file_inventory_binding_fault", "phase file inventory rejected", severe=True))
            direct = [process for process in evidence["processes"] if process["process_id"] == direct_birth]
            matches = (inventory_valid and len(direct) == 1 and direct[0]["pid"] == phase["pid"]
                       and set(direct[0]["file_coverage"]["declared"]) == expected_files)
            if direct and not matches:
                issues.append(fault("direct_file_inventory_fault", "direct process differs from the admitted file inventory", severe=True))
    logs = []
    if phase is not None and phase.get("log"):
        log_issues = []
        log = input_bytes(phase["log"], mapping, log_issues)
        issues.extend(log_issues)
        if not any(item["severe"] for item in log_issues):
            snapshot_digest = hashlib.sha256(log).hexdigest()
            if phase.get("log_sha256", snapshot_digest) != snapshot_digest:
                issues.append(fault("stale_log", "phase log bytes differ from the retirement receipt", severe=True))
            else:
                logs.append(dict(path=phase["log"], invocation=invocation,
                    source_digest=expected_source_digest, phase=expected_phase,
                    process_birth_id=direct_birth, input_sha256=snapshot_digest,
                    binding_scope="current_owned_log_snapshot"))
    receipt = (dict(schema_version=4, invocation=invocation, source_digest=expected_source_digest,
                    status=phase.get("status", "UNKNOWN"), phases=[mapping.value(phase)],
                    required_phases=[expected_phase], coverage_complete=False,
                    test_inventory_complete=False, test_process_birth_ids=evidence["process_birth_ids"],
                    active_phase=None, child_inventory_status="UNPROVED") if phase is not None else None)
    proof = dict(phase=expected_phase, direct_process_birth_id=direct_birth,
        profile_request=phase.get("profile_request") if phase is not None else None,
        observed_file_coverage_complete=evidence["observed_file_coverage_complete"],
        expected_file_inventory_matches=matches, observed_process_birth_ids=evidence["process_birth_ids"],
        process_issues=[dict(process_birth_id=process["process_id"], issues=process["issues"])
                        for process in evidence["processes"] if process["issues"]],
        test_inventory_complete=False, child_inventory_status="UNPROVED",
        native_inventory_status="SOURCE_BOUND_DIRECT_FILES" if matches else "UNPROVED",
        direct_log_binding_status="BOUND" if logs else "UNAVAILABLE",
        receipt_timing_boundary="direct-command retirement before this artifact finalizer; final supervisor receipt includes finalization",
        finalizer_timing_status="NOT_YET_IN_PHASE_SNAPSHOT")
    return publish_bundle(evidence, event_paths, invocation=invocation,
        expected_source_digest=expected_source_digest, mapping=mapping, output=output,
        receipt=receipt, logs=logs, extra_report=proof)


def assemble_job(*, invocation, expected_source_digest, source_roots, output, supervisor_path):
    """Index the final command/loop verdict without adding repeated native counts."""
    require_binding(invocation, expected_source_digest)
    mapping = SourceMap(source_roots)
    issues = []
    receipt = read_receipt(supervisor_path, invocation=invocation,
        source_digest=expected_source_digest, mapping=mapping, issues=issues)
    # Keep physical inputs private; public metadata uses the same explicit mapping.
    raw_receipt = None
    if receipt is not None:
        raw_receipt = parse_json(input_bytes(supervisor_path, mapping, issues))
    bundles = []
    for index, phase in enumerate((raw_receipt or {}).get("phases", [])):
        final_phase = receipt["phases"][index]
        record = dict(phase=phase.get("name"), command_status=final_phase.get("status"),
            reported_status=final_phase.get("reported_status"), semantic_status=final_phase.get("semantic_status"),
            exit_code=final_phase.get("exit_code"), soft_limit_exceeded=final_phase.get("soft_limit_exceeded", False),
            cleanup_status=final_phase.get("cleanup_status"), artifact_status="UNAVAILABLE")
        bundles.append(record)
        directory = phase.get("diagnostics_directory")
        if not isinstance(directory, str):
            record["reason"] = "phase did not produce an owned diagnostics directory"
            continue
        public = Path(directory) / "public"
        local_issues = []
        raw = input_bytes(public / "diagnostics.json", mapping, local_issues)
        manifest_raw = input_bytes(public / "manifest.json", mapping, local_issues, limit=1024*1024)
        if local_issues:
            record["reason"] = "phase bundle is missing or exceeded an export bound"
            issues.append(fault("phase_bundle_unavailable", "phase bundle could not be indexed", phase=phase.get("name")))
            continue
        try:
            payload, manifest = parse_json(raw), parse_json(manifest_raw)
        except (ValueError, UnicodeError, RecursionError):
            payload, manifest = None, None
        token, pid = phase.get("process_token"), phase.get("pid")
        expected_birth = f"{token}-{pid}" if phase.get("started") is True else None
        direct_binding_valid = (phase.get("started") is not True or
            isinstance(token, str) and IDENTIFIER.fullmatch(token) and type(pid) is int and pid > 0)
        if (not direct_binding_valid or not isinstance(payload, dict) or not bounded_structure(payload)
                or payload.get("direct_process_birth_id") != expected_birth
                or payload.get("invocation") != invocation or payload.get("source_digest") != expected_source_digest
                or payload.get("phase") != phase.get("name") or not isinstance(manifest, dict)
                or manifest.get("invocation") != invocation or manifest.get("source_digest") != expected_source_digest
                or not isinstance(manifest.get("files"), dict)
                or manifest["files"].get("diagnostics.json") != hashlib.sha256(raw).hexdigest()):
            record["reason"] = "phase bundle source/invocation/phase or manifest differs"
            issues.append(fault("phase_bundle_binding_fault", "phase bundle was not indexed", phase=phase.get("name"), severe=True))
            continue
        record.update(artifact_status=payload.get("export_status", "UNKNOWN"),
            bundle=mapping.text(public), manifest_sha256=hashlib.sha256(manifest_raw).hexdigest(),
            test_status=payload.get("test_status"), coverage_status=payload.get("coverage_status"),
            failure_detail_status=payload.get("failure_detail_status"), profile_copy_status=payload.get("profile_copy_status"))
    evidence = dict(issues=issues, processes=[], redacted_absolute_paths=0)
    extra = dict(artifact_scope="job_command_and_loop_verdict; native evidence remains in separate source-bound phase bundles",
        check_status=receipt.get("status", "UNKNOWN") if receipt is not None else "UNKNOWN",
        assertion_counts=None, count_scope="not_aggregated; see per-phase native assertion counts",
        failure_detail_status="NOT_AGGREGATED; see per-phase original failure details",
        phase_bundles=bundles, child_inventory_status="UNPROVED", test_inventory_complete=False,
        receipt_timing_boundary="final supervisor receipt includes per-phase diagnostic finalization; job exporter is separately timed")
    return publish_bundle(evidence, (), invocation=invocation, expected_source_digest=expected_source_digest,
        mapping=mapping, output=output, receipt=receipt, extra_report=extra)


def assemble_preparation(*, stage, invocation, expected_source_digest, source_roots,
                         output, reason="No final supervisor receipt; setup or work incomplete"):
    """Publish bounded setup snapshots while explicitly leaving tests unverified."""
    require_binding(invocation, expected_source_digest)
    mapping = SourceMap(source_roots)
    stage = Path(stage)
    if not mapping.owns(stage):
        raise ValueError("preparation snapshots require an owned matrix stage")
    issues = [fault("preparation_only", "no final test supervisor receipt; native results remain unverified")]
    known = [stage / "prepared.json", stage / "environment/Project.toml",
             stage / "environment/LocalPreferences.toml", stage / "environment/Manifest.toml"]
    logs = sorted((stage / "logs").glob("*.log")) if (stage / "logs").is_dir() else []
    snapshots, records, total = [], [], 0
    for ordinal, source in enumerate(known + logs, 1):
        if not source.exists() and not source.is_symlink():
            continue
        if len(snapshots) >= MAX_SETUP_FILES or total >= MAX_SETUP_BYTES:
            issues.append(fault("setup_snapshot_limit", "remaining setup files exceeded the finite export bound"))
            break
        local_issues = []
        raw = input_bytes(source, mapping, local_issues,
            limit=min(MAX_SETUP_FILE_BYTES, MAX_SETUP_BYTES-total))
        issues.extend(local_issues)
        if any(item["severe"] for item in local_issues):
            continue
        total += len(raw)
        suffix = source.suffix if source.suffix in (".json", ".toml") else ".txt"
        filename = f"setup-{len(snapshots)+1:04d}{suffix}"
        if suffix == ".json":
            try:
                value = parse_json(raw)
            except (ValueError, UnicodeError, RecursionError):
                filename, safe = filename + ".txt", mapping.text(raw.decode("utf-8", errors="replace"))
            else:
                safe = json.dumps(mapping.value(value), indent=2, sort_keys=True) + "\n"
        else:
            safe = mapping.text(raw.decode("utf-8", errors="replace"))
        snapshots.append(dict(file=filename, text=safe))
        records.append(dict(file=filename, source=mapping.text(source), input_sha256=hashlib.sha256(raw).hexdigest(),
            original_bytes=len(raw), truncated=any(item["kind"] == "input_truncated" for item in local_issues),
            binding_scope="PREPARATION_ONLY_UNVERIFIED_CURRENT_STAGE_SNAPSHOT"))
    extra = dict(artifact_scope="PREPARATION_ONLY_UNVERIFIED", check_status="UNVERIFIED",
        assertion_counts=None, count_scope="no test counts; setup snapshots do not prove test execution",
        failure_detail_status="NO_NATIVE_TEST_EVIDENCE", setup_reason=mapping.text(reason),
        setup_snapshots=records, snapshot_input_bytes=total, test_inventory_complete=False,
        child_inventory_status="UNPROVED",
        source_binding_scope="current exporter checkout; setup snapshots have no native invocation/source proof")
    evidence = dict(issues=issues, processes=[], redacted_absolute_paths=0)
    return publish_bundle(evidence, (), invocation=invocation, expected_source_digest=expected_source_digest,
        mapping=mapping, output=output, extra_report=extra, snapshots=snapshots)


def self_test():
    """Critical provenance, privacy, incomplete-count and outcome controls."""
    with tempfile.TemporaryDirectory(prefix="libtmux-ci-artifacts-") as temporary:
        root = Path(temporary)
        digest = "a" * 64
        mapping = SourceMap([(root, "owned")])
        private = "source:" + str(root / "test.jl")
        assert mapping.text(private) == "source:owned/test.jl"
        assert mapping.text("source:/private/unknown/test.jl") == "source:redacted-path"
        assert "private" not in mapping.text(r"source:C:\private\test.jl")
        assert mapping.text("</home/private/test.jl>") == "<redacted-path>"
        assert mapping.text("prefix/home/private/test.jl") == "prefixredacted-path"
        assert mapping.text("</unknown/private/test.jl>") == "<redacted-path>"
        assert mapping.text(r"prefixC:\private\test.jl") == "prefixredacted-path"
        assert mapping.text(r"source:\\private\server\test.jl") == "source:redacted-path"
        assert mapping.text("bad\ufffe\uffff") == "bad??"

        owned_root = Path.home() / ".synthetic-owned-root"
        alias = "~/.synthetic-owned-root"
        aliases = SourceMap([(owned_root, "repository"), (owned_root / "nested", "nested-source")])
        for prefix in (str(owned_root), alias):
            assert aliases.text(prefix + "/test/error.jl:49") == "repository/test/error.jl:49"
            for tail in ("/../private.jl:7", "/a:b/../../private.jl:7"):
                assert aliases.text(prefix + tail) == "redacted-path"
        assert aliases.text(alias + "/nested/error.jl:49") == "nested-source/error.jl:49"
        unknown = ("/private/unowned/private.jl:7", "~/not-owned/private.jl:7",
                   r"C:\private\private.jl:7", r"prefixC:\private\private.jl:7",
                   r"\\private\server\private.jl:7", alias + "-other/private.jl:7")
        progress_log = root / "progress-privacy.txt"
        detail = "Stacktrace:\n    [1] f()"
        progress = PROGRESS_PREFIX + json.dumps(dict(detail=detail)) + "\n"
        safe = sanitized_original_text(progress, aliases)
        assert parse_json(safe[len(PROGRESS_PREFIX):])["detail"] == detail
        progress_log.write_text(safe)
        assert not unsafe_export(progress_log)
        for value in unknown:
            progress = PROGRESS_PREFIX + json.dumps(dict(detail=value))
            progress_log.write_text(progress)
            assert unsafe_export(progress_log)
            safe = sanitized_original_text(progress, aliases)
            assert "private.jl" not in parse_json(safe[len(PROGRESS_PREFIX):])["detail"]
            progress_log.write_text(safe)
            assert not unsafe_export(progress_log)
        malformed = (
            r'{"detail":"\u002fprivate\u002funowned\u002fsecret.jl:7',
            r'{"detail":"\u007e\u002funowned\u002fsecret.jl:7',
            r'{"detail":"C:\u005cprivate\u005csecret.jl:7',
            r'{"detail":"\u005c\u005cprivate\u005cserver\u005csecret.jl:7',
            r'{"detail":"ok","detail":"\u002fprivate\u002fsecret.jl:7"}',
            '{"detail":' + '[' * 34 + '"relative"' + ']' * 34 + '}',
            json.dumps(dict(detail="relative")) + " " * MAX_RECORD_BYTES,
        )
        for value in malformed:
            progress = PROGRESS_PREFIX + value + "\n"
            progress_log.write_text(progress)
            assert unsafe_export(progress_log), "independent reader accepted unparsed progress"
            redactions = []
            safe = sanitized_original_text(progress, aliases, issues=redactions)
            assert safe == UNPARSED_PROGRESS + "\n" and not safe.startswith(PROGRESS_PREFIX)
            assert redactions == [fault("unparsed_progress_redacted",
                "original byte hash retained; public progress payload unavailable", records=1)]
            progress_log.write_text(safe)
            assert not unsafe_export(progress_log)
        assert sanitized_original_text("plain /private/unowned/private.jl:7\n", aliases) == "plain redacted-path\n"

        for separator in ("\u2028", "\u2029", "\u0085"):
            for escaped in (r"\u002fprivate\u002funowned\u002fsecret.jl:7",
                            r"\u007e\u002funowned\u002fsecret.jl:7"):
                for ending in ("\n", "\r\n", ""):
                    progress = PROGRESS_PREFIX + '{"detail":"before' + separator + escaped + '"}' + ending
                    progress_log.write_text(progress)
                    assert unsafe_export(progress_log), "Unicode separator split the decoded privacy scan"
                    safe = sanitized_original_text(progress, aliases)
                    assert safe.endswith(ending)
                    decoded = decoded_progress(safe.rstrip("\r\n"))
                    assert decoded and separator in decoded["detail"] and "secret.jl" not in decoded["detail"]
                    progress_log.write_text(safe)
                    assert not unsafe_export(progress_log)
                    truncated = PROGRESS_PREFIX + '{"detail":"before' + separator + escaped + ending
                    progress_log.write_text(truncated)
                    assert unsafe_export(progress_log)
                    assert sanitized_original_text(truncated, aliases) == UNPARSED_PROGRESS + ending
        def event(name, seq, **fields):
            return dict(schema=2, event=name, seq=seq, pid=123, elapsed_ns=seq, invocation="current",
                        source_digest=digest, process_birth_id="birth-one", **fields)
        events = [event("process_start", 1, phase="tests", julia="1.13.0", threads=1),
                  event("file_inventory", 2, files=["test/runtests.jl"], scope="declared_files_only"),
                  event("span_start", 3, kind="file", label="test/runtests.jl"),
                  event("testset_start", 4, testset_id=1, parent_id=None, description="root", file="test/runtests.jl", line=1),
                  event("testset_start", 5, testset_id=2, parent_id=1, description="nested", file="test/runtests.jl", line=2),
                  event("testset_body_end", 6, testset_id=2, body_outcome="returned"),
                  event("testset_finalize", 7, testset_id=2, body_outcome="returned", native_finish="returned", seconds=.01,
                        counts=dict(passed=1, failed=0, errored=0, broken=0)),
                  event("testset_body_end", 8, testset_id=1, body_outcome="returned"),
                  event("testset_finalize", 9, testset_id=1, body_outcome="returned", native_finish="returned", seconds=.02,
                        counts=dict(passed=2, failed=0, errored=0, broken=1)),
                  event("span_finish", 10, kind="file", label="test/runtests.jl", outcome="returned", seconds=.1),
                  event("process_finish", 11, outcome="returned", coverage_complete=True)]
        source = root / "events.jsonl"
        def write(items, tail=b""):
            source.write_bytes(b"".join((json.dumps(item | dict(seq=number, elapsed_ns=number)) + "\n").encode()
                                      for number, item in enumerate(items, 1)) + tail)
        receipt = root / "receipt.json"
        supervisor = dict(schema_version=4, invocation="current", source_digest=digest, status="PASS", coverage_complete=True,
                          test_inventory_complete=True, required_phases=["tests"],
                          phases=[dict(name="tests", status="PASS", started=True, direct_child_reaped=True, coverage_complete=True,
                                       semantic_status="PASS", exit_code=0, cleanup_status="REAPED",
                                       diagnostics_status="PASS", test_process_birth_ids=["birth-one"],
                                       expected_test_file_inventory=dict(source_digest=digest,
                                                                        files=[dict(path="test/runtests.jl", sha256="b"*64)]))],
                          test_process_birth_ids=["birth-one"], active_phase=None)
        receipt.write_text(json.dumps(supervisor))
        def run(name, **kwargs):
            return assemble([source], invocation="current", expected_source_digest=digest, source_roots=[(root, "owned")], output=root / name, supervisor_path=receipt, **kwargs)
        write(events)
        result = run("complete")
        assert result["test_status"] == "PASS" and result["coverage_status"] == "COMPLETE"
        assert result["assertion_counts"]["passed"] == 2 and result["export_status"] == "PASS"
        assert not result["diagnostics_complete"]
        assert result["failure_detail_status"] == "NOT_OBSERVED"
        assert "root > nested" in (root / "complete" / "timings.csv").read_text()
        assert ET.fromstring((root / "complete" / "junit.xml").read_text()).find(".//testcase[@name='root > nested']") is not None
        evidence = collect_process_evidence([source], invocation="current", expected_source_digest=digest,
                                            source_roots=[(root, "owned")], expected_phase="tests")
        assert evidence["observed_file_coverage_complete"] and not evidence["test_inventory_complete"]
        evidence = collect_process_evidence([source], invocation="current", expected_source_digest=digest,
                                            source_roots=[(root, "owned")], expected_phase="wrong-phase")
        assert not evidence["observed_file_coverage_complete"]
        write(events[:7], b'{"event":')
        result = run("partial")
        assert result["assertion_counts"]["passed"] == 1 and result["coverage_status"] == "PARTIAL"
        assert result["test_status"] != "PASS" and result["export_status"] == "PASS"
        assert len((root / "partial" / "partial-progress.jsonl").read_text().splitlines()) == 7
        unstarted = json.loads(json.dumps(events))
        unstarted[1]["files"].append("test/not-run.jl")
        write(unstarted)
        assert run("unstarted-file")["coverage_status"] == "PARTIAL"
        write(events[:9] + events[10:])
        assert run("unfinished-file")["test_status"] != "PASS"
        write(events[:2] + events[3:])
        assert run("unmatched-file-end")["export_status"] == "FAIL"
        write(events[:-1])
        assert run("no-process-end")["test_status"] != "PASS"
        write(events[:-1] + [event("coverage_incomplete", 11, reason="unmapped dynamic testset")] + events[-1:])
        assert run("unknown-dynamic-coverage")["coverage_status"] == "PARTIAL"
        failed = events[:5] + [event("assertion_problem", 6, testset_id=2, result_type="Fail", problem_kind="test", file="test/runtests.jl", line=9, detail="Expression: 1 == 2; evaluated: 1 == 2")]
        write(failed)
        result = run("native-failure")
        assert result["test_status"] == "FAIL" and result["assertion_counts"]["failed"] == 1
        assert result["failure_detail_status"] == "AVAILABLE"
        xml = ET.fromstring((root / "native-failure" / "junit.xml").read_text())
        assert "Expression: 1 == 2" in xml.find(".//failure").text
        assert next(case for case in xml.findall(".//testcase") if case.find("failure") is not None).get("file") == "test/runtests.jl"
        assert next(case for case in xml.findall(".//testcase") if case.find("failure") is not None).get("name").startswith("root > nested > assertion-")
        missing_detail = json.loads(json.dumps(failed))
        missing_detail[-1].update(detail="native result rendering failed", detail_status="unavailable")
        write(missing_detail)
        assert run("missing-native-detail")["failure_detail_status"] == "UNAVAILABLE"
        private_detail = json.loads(json.dumps(failed))
        private_detail[-1]["detail"] = "Expression source: /private/unknown/test.jl"
        write(private_detail)
        assert run("event-redaction-count")["redacted_absolute_paths"] >= 1
        interrupted = json.loads(json.dumps(events))
        interrupted[5]["body_outcome"] = interrupted[6]["body_outcome"] = "interrupted"
        interrupted[-1]["outcome"] = "interrupted"
        write(interrupted)
        assert run("interrupted")["test_status"] != "PASS"
        nonlocal_exit = json.loads(json.dumps(events))
        nonlocal_exit[5]["body_outcome"] = nonlocal_exit[6]["body_outcome"] = "nonlocal_exit"
        write(nonlocal_exit)
        result = run("nonlocal-exit")
        assert result["assertion_counts"]["errored"] == 0 and result["test_status"] != "PASS"
        assert ET.fromstring((root / "nonlocal-exit" / "junit.xml").read_text()).find(".//testcase[@name='root > nested']/skipped") is not None
        errored = events[:4] + [event("assertion_problem", 5, testset_id=1, result_type="Error", problem_kind="nontest_error", file="test/runtests.jl", line=8, detail="ErrorException: intended native body error"),
                               event("testset_body_end", 6, testset_id=1, body_outcome="threw"),
                               event("testset_finalize", 7, testset_id=1, body_outcome="threw", native_finish="threw", counts=dict(passed=0, failed=0, errored=1, broken=0)),
                               event("span_finish", 8, kind="file", label="test/runtests.jl", outcome="threw", seconds=.01),
                               event("process_finish", 9, outcome="threw", coverage_complete=True)]
        write(errored)
        failed_receipt = json.loads(json.dumps(supervisor))
        failed_receipt["status"] = failed_receipt["phases"][0]["status"] = "FAIL"
        failed_receipt["phases"][0].update(semantic_status="FAIL", exit_code=1)
        receipt.write_text(json.dumps(failed_receipt))
        result = run("completed-native-error")
        assert result["test_status"] == "FAIL" and result["coverage_status"] == "COMPLETE"
        receipt.write_text(json.dumps(supervisor))
        stale = json.loads(json.dumps(events))
        stale[0]["source_digest"] = "older"
        write(stale)
        result = run("stale")
        assert result["export_status"] == "FAIL" and result["assertion_counts"]["passed"] == 0
        write(events)
        result = assemble([source, source], invocation="current", expected_source_digest=digest, source_roots=[(root, "owned")], output=root / "duplicate", supervisor_path=receipt)
        assert result["export_status"] == "FAIL" and result["assertion_counts"]["passed"] == 2
        log = root / "raw.log"
        log.write_text(private + "\n")
        result = run("bound-log", logs=[dict(path=log, invocation="current", source_digest=digest, phase="tests", input_sha256=hashlib.sha256(log.read_bytes()).hexdigest())])
        assert (root / "bound-log" / "original-log-0001.txt").read_text() == "source:owned/test.jl\n"
        assert run("unbound-log", logs=[dict(path=log, phase="tests")])["export_status"] == "FAIL"
        assert run("stale-log", logs=[dict(path=log, invocation="current", source_digest=digest, phase="tests", input_sha256="incorrect")])["export_status"] == "FAIL"
        write(events[:1] + [dict(events[1], event=None)])
        assert run("malformed-event")["export_status"] == "FAIL"
        write(events[:-1] + [event("testset_finalize", 11, testset_id=[], counts=dict(passed=0, failed=0, errored=0, broken=0))] + events[-1:])
        assert run("unhashable-testset-identity")["export_status"] == "FAIL"
        write(events[:5] + [event("assertion_problem", 6, testset_id=[], result_type="Fail", problem_kind="test")])
        result = run("unhashable-problem-identity")
        assert result["test_status"] == "FAIL" and result["assertion_counts"]["failed"] == 1
        conflicted = json.loads(json.dumps(events))
        conflicted[8]["counts"]["passed"] = 0
        write(conflicted)
        result = run("contradictory-cumulative-counts")
        assert result["export_status"] == "FAIL" and result["assertion_counts"]["passed"] == 1
        write(events[:1], b'{"schema":2,"schema":2,"event":"process_finish"}\n')
        assert run("duplicate-json-field")["export_status"] == "FAIL"
        write(events[:1], b'{"event":"span_finish","seconds":NaN}\n')
        assert run("nonfinite-json-field")["export_status"] == "FAIL"
        write(events)
        duplicate_birth = root / "same-birth.jsonl"
        changed = json.loads(json.dumps(events))
        for item in changed:
            item["elapsed_ns"] += 10
        duplicate_birth.write_text("".join(json.dumps(event) + "\n" for event in changed))
        result = assemble([source, duplicate_birth], invocation="current", expected_source_digest=digest, source_roots=[(root, "owned")], output=root / "duplicate-birth", supervisor_path=receipt)
        assert result["export_status"] == "FAIL" and result["assertion_counts"]["passed"] == 2
        # These are serializer fixtures, not claims that CPU/wall sampling works.
        profile = root / "profile.json"
        payload = dict(schema=2, invocation="current", source_digest=digest, process_birth_id="birth-one", pid=123,
                       checkpoint_seq=1, mode="cpu", status="captured", julia="1.13.0", threads=1,
                       data=[0, 123, 0], lookup={"0": [None], "123": [dict(function="hot_loop", file="prefix/home/private/test.jl", line=7, from_c=False, inlined=False)]})
        def profile_events(value, **changes):
            profile.write_text(json.dumps(value) + "\n")
            checkpoint = event("profile_checkpoint", 11, checkpoint_seq=1, mode="cpu", status="captured", file="profile.json",
                               input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(), data_words=3, capture_seconds=.01)
            checkpoint.update(changes)
            return events[:-1] + [checkpoint] + events[-1:]
        write(profile_events(payload))
        result = run("bound-profile")
        assert result["profile_copy_status"] == "RAW_PRESERVED" and not result["diagnostics_complete"]
        retained = json.loads((root / "bound-profile" / result["profile_records"][0]["file"]).read_text())
        assert retained["data"] == payload["data"] and retained["lookup"]["0"] == [None]
        assert retained["decoder_status"] == "RAW_PRESERVED_NATIVE_DECODER_UNVERIFIED"
        assert retained["lookup"]["123"][0]["file"] == "prefixredacted-path"
        partial_payload = payload | dict(symbolization_status="partial", unresolved_addresses=1, buffer_full=False,
            truncated=False, lookup={"0": [None], "123": None})
        complete_payload = payload | dict(checkpoint_seq=2, symbolization_status="complete", unresolved_addresses=0,
                                         buffer_full=False, truncated=False)
        checkpoints = []
        for value, filename in ((partial_payload, "profile-partial.json"), (complete_payload, "profile-complete.json")):
            checkpoint_path = root / filename
            checkpoint_path.write_text(json.dumps(value) + "\n")
            checkpoints.append(event("profile_checkpoint", 1, checkpoint_seq=value["checkpoint_seq"], mode="cpu",
                status="captured", file=filename, input_sha256=hashlib.sha256(checkpoint_path.read_bytes()).hexdigest(),
                data_words=3, capture_seconds=.01, symbolization_status=value["symbolization_status"],
                unresolved_addresses=value["unresolved_addresses"], buffer_full=False, truncated=False))
        lifecycle = [event("profile_start", 1, mode="cpu"),
                     event("profile_unavailable", 1, mode="cpu", reason="symbolization_work_limit")]
        write(events[:-1] + lifecycle + checkpoints + [event("profile_stop", 1, mode="cpu", checkpoint_count=2)] + events[-1:])
        result = run("lifecycle-and-partial-symbols")
        assert result["profile_copy_status"] == "RAW_PRESERVED", "lifecycle/warnings were counted as failed checkpoint copies"
        assert result["profile_checkpoint_counts"] == dict(attempted=2, copied=2)
        assert result["profile_symbolization_status"] == "PARTIAL" and result["profile_sample_coverage_status"] == "UNPROVED"
        assert len(result["profile_records"]) == 2 and len(result["profile_metadata"]) == 3
        assert result["profile_records"][0]["unresolved_addresses"] == 1 and result["profile_records"][1]["symbolization_status"] == "COMPLETE"
        assert result["profile_records"][0]["buffer_full"] is False and result["profile_records"][0]["truncated"] is False
        summary = (root / "lifecycle-and-partial-symbols/summary.txt").read_text()
        assert "Checkpoint copy: RAW_PRESERVED (2/2). Symbolization: PARTIAL" in summary and "symbolization_work_limit" in summary
        write(events[:-1] + [event("profile_unavailable", 1, mode="wall", reason="requires_julia_1_13")] + events[-1:])
        result = run("unsupported-mode-without-checkpoints")
        assert result["profile_copy_status"] == "UNAVAILABLE" and result["profile_symbolization_status"] == "UNAVAILABLE"
        assert result["profile_checkpoint_counts"] == dict(attempted=0, copied=0) and result["profile_metadata"]
        for key, stale_value in (("source_digest", "b"*64), ("invocation", "older"), ("process_birth_id", "other-birth")):
            write(profile_events(payload | {key: stale_value}))
            result = run("stale-profile-" + key)
            assert result["export_status"] == "FAIL" and result["profile_copy_status"] == "UNAVAILABLE"
        write(profile_events(payload, input_sha256="b"*64))
        assert run("stale-profile-bytes")["export_status"] == "FAIL"
        write(profile_events(payload, file="../profile.json"))
        assert run("profile-traversal")["profile_copy_status"] == "UNAVAILABLE"
        items = profile_events(payload)
        write(items[:-1] + [items[-2]] + items[-1:])
        result = run("duplicate-checkpoint")
        assert result["export_status"] == "FAIL" and result["profile_copy_status"] == "PARTIAL"
        for label, word in (("overflow", 2**64), ("boolean", True), ("negative", -1),
                            ("nested", ["/home/private/sample"]), ("string", "/home/private/sample")):
            write(profile_events(payload | dict(data=[word, 123, 0])))
            result = run("invalid-profile-word-" + label)
            assert result["export_status"] == "FAIL" and result["profile_copy_status"] == "UNAVAILABLE"
        write(profile_events(payload | dict(lookup={"0123": [None]})))
        assert run("noncanonical-profile-address")["export_status"] == "FAIL"
        metadata = {"nested": [{"prefixC:\\private": "prefix/home/private/value"}],
                    "escaped": "\u002fhome\u002fprivate\u002fvalue"}
        frame = payload["lookup"]["123"][0] | dict(extension=metadata)
        value = payload | dict(extension=metadata, lookup=payload["lookup"] | {"123": [frame]})
        write(profile_events(value))
        result = run("profile-extension-privacy")
        assert result["export_status"] == "PASS" and result["profile_copy_status"] == "RAW_PRESERVED"
        kept = json.loads((root / "profile-extension-privacy" / result["profile_records"][0]["file"]).read_text())
        assert kept["data"] == payload["data"] and kept["lookup"]["0"] == [None]
        assert not unsafe_export(root / "profile-extension-privacy" / result["profile_records"][0]["file"])
        nested = "safe"
        for _ in range(34):
            nested = [nested]
        write(profile_events(payload | dict(extension=nested)))
        assert run("profile-extension-depth")["export_status"] == "FAIL"
        legacy = profile_events(payload)
        for key in ("checkpoint_seq", "input_sha256"):
            legacy[-2].pop(key)
        write(legacy)
        assert run("legacy-profile")["profile_copy_status"] == "UNAVAILABLE"
        write(events)
        phase_events = json.loads(json.dumps(events))
        for item in phase_events:
            item["process_birth_id"] = "direct-123"
        phase_path = root / "phase.json"
        phase_receipt = dict(name="tests", invocation="current", source_digest=digest,
            process_token="direct", pid=123, started=True, status="PASS", semantic_status="PASS", exit_code=0,
            direct_child_reaped=True, cleanup_status="REAPED", seconds=.2, log=str(log),
            log_sha256=hashlib.sha256(log.read_bytes()).hexdigest(),
            expected_test_file_inventory=dict(source_digest=digest, files=[dict(path="test/runtests.jl", sha256="b"*64)]),
            timings=dict(process_launch_seconds=.01, exit_observed_seconds=.18, reaped_seconds=.19,
                         first_output_byte=dict(status="UNAVAILABLE")))
        # Live publication proves an admitted prefix, never command completion.
        live_admission = phase_receipt | dict(status="NOT RUN", semantic_status="NOT RUN",
            exit_code=None, direct_child_reaped=False, cleanup_status="NOT NEEDED")
        checkpoint_payload = partial_payload | dict(process_birth_id="direct-123")
        profile.write_text(json.dumps(checkpoint_payload) + "\n")
        checkpoint_marker = event("profile_checkpoint", 1, checkpoint_seq=1, mode="cpu", status="captured",
            file="profile.json", input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest(), data_words=3,
            capture_seconds=.01, symbolization_status="partial", unresolved_addresses=1,
            buffer_full=False, truncated=False)
        def checkpoint_run(name, *, items=None, admission=None, tail=b"", input_path=None, **changes):
            current = phase_events[:-1] + [checkpoint_marker] if items is None else items
            current = [item | dict(process_birth_id="direct-123") for item in current]
            write(current, tail)
            phase_path.write_text(json.dumps(live_admission if admission is None else admission))
            arguments = dict(invocation="current", expected_source_digest=digest,
                source_roots=[(root, "owned")], output=root / name, admission_path=phase_path,
                expected_phase="tests", expected_direct_birth="direct-123", snapshot_ordinal=1,
                through_sequence=len(current))
            arguments.update(changes)
            return assemble_checkpoint([source if input_path is None else input_path], **arguments)
        result = checkpoint_run("live-checkpoint", tail=b'{"concurrent_tail":')
        assert result["test_status"] == result["check_status"] == "UNKNOWN"
        assert result["snapshot_kind"] == "LIVE_PREFIX" and result["coverage_status"] == "PARTIAL"
        assert not result["test_inventory_complete"] and not result["diagnostics_complete"]
        assert result["profile_copy_status"] == "RAW_PRESERVED" and result["profile_symbolization_status"] == "PARTIAL"
        binding = result["snapshot_binding"]
        prefix = b"".join(source.read_bytes().splitlines(keepends=True)[:binding["through_sequence"]])
        assert binding["event_prefix_sha256"] == hashlib.sha256(prefix).hexdigest()
        assert binding["admission_sha256"] == hashlib.sha256(phase_path.read_bytes()).hexdigest()
        assert binding["snapshot_ordinal"] == 1 and binding["event_prefix_bytes"] == len(prefix)
        assert result["assertion_counts"]["passed"] == 2 and result["count_scope"] == "observed_lower_bound"
        assert len((root / "live-checkpoint/partial-progress.jsonl").read_text().splitlines()) == binding["through_sequence"]
        assert "LIVE_PREFIX" in (root / "live-checkpoint/summary.txt").read_text()
        assert all(not unsafe_export(path) for path in (root / "live-checkpoint").iterdir())
        result = checkpoint_run("live-start", items=phase_events[:1])
        assert result["test_status"] == "UNKNOWN" and result["profile_copy_status"] == "UNAVAILABLE"
        result = checkpoint_run("live-native-failure", items=failed + [checkpoint_marker])
        assert result["test_status"] == result["check_status"] == "FAIL"
        assert result["assertion_counts"]["failed"] == 1 and result["failure_detail_status"] == "AVAILABLE"
        assert "Expression: 1 == 2" in (root / "live-native-failure/junit.xml").read_text()
        result = checkpoint_run("live-native-assertion-marker", items=failed)
        assert result["snapshot_binding"]["marker"] == "assertion_problem"
        assert result["test_status"] == result["check_status"] == "FAIL" and result["coverage_status"] == "PARTIAL"
        assert result["assertion_counts"]["failed"] == 1 and result["profile_copy_status"] == "UNAVAILABLE"
        assert result["failure_detail_status"] == "AVAILABLE" and not result["diagnostics_complete"]
        assert "Expression: 1 == 2" in (root / "live-native-assertion-marker/junit.xml").read_text()
        def reject_checkpoint(name, **changes):
            try:
                checkpoint_run(name, **changes)
            except ValueError:
                pass
            else:
                raise AssertionError("unsafe or stale live checkpoint was published: " + name)
            assert not (root / name).exists()
        for name, admission in (("invocation", live_admission | dict(invocation="older")),
                                ("source", live_admission | dict(source_digest="b" * 64)),
                                ("pid", live_admission | dict(pid=124)),
                                ("phase", live_admission | dict(name="other")),
                                ("unadmitted", live_admission | dict(started=False))):
            reject_checkpoint("live-reject-" + name, admission=admission)
        reject_checkpoint("live-reject-ordinal", snapshot_ordinal=True)
        reject_checkpoint("live-reject-sequence", through_sequence=100)
        reject_checkpoint("live-reject-nonmarker", items=phase_events[:5])
        reject_checkpoint("live-reject-truncated-marker", items=phase_events[:1],
            tail=json.dumps(checkpoint_marker).encode()[:-5], through_sequence=2)
        reject_checkpoint("live-reject-gap", items=phase_events[:1],
            tail=(json.dumps(checkpoint_marker | dict(seq=99)) + "\n").encode(), through_sequence=2)
        stale_stream = phase_events[:1] + [checkpoint_marker | dict(invocation="older")]
        reject_checkpoint("live-reject-stale-stream", items=stale_stream)
        admission_link = root / "admission-link.json"
        admission_link.symlink_to(phase_path)
        reject_checkpoint("live-reject-admission-symlink", admission_path=admission_link)
        input_link = root / "input-link.jsonl"
        input_link.symlink_to(source)
        reject_checkpoint("live-reject-input-symlink", input_path=input_link)
        reject_checkpoint("live-reject-profile-hash", items=phase_events[:1] + [checkpoint_marker | dict(input_sha256="b" * 64)])
        profile.write_text(json.dumps(checkpoint_payload | dict(pid=124)) + "\n")
        reject_checkpoint("live-reject-profile-shape", items=phase_events[:1] + [checkpoint_marker | dict(input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest())])
        profile.unlink()
        profile.symlink_to(root / "profile-partial.json")
        reject_checkpoint("live-reject-profile-symlink")
        profile.unlink()
        profile.write_text(json.dumps(checkpoint_payload) + "\n")
        saved_manifest = (root / "live-checkpoint/manifest.json").read_bytes()
        try:
            checkpoint_run("live-checkpoint")
        except ValueError:
            pass
        else:
            raise AssertionError("immutable checkpoint generation was overwritten")
        assert (root / "live-checkpoint/manifest.json").read_bytes() == saved_manifest
        def phase_run(name, *, receipt_override=None, items=None, **kwargs):
            write(phase_events if items is None else items)
            phase_path.write_text(json.dumps(phase_receipt if receipt_override is None else receipt_override))
            return assemble_phase([source], invocation="current", expected_source_digest=digest,
                source_roots=[(root, "owned")], output=root / name, phase_path=phase_path,
                expected_phase="tests", **kwargs)
        result = phase_run("bound-phase", expected_direct_birth="direct-123")
        assert result["observed_file_coverage_complete"] and result["expected_file_inventory_matches"]
        assert result["coverage_status"] == "PARTIAL" and result["test_status"] == "UNKNOWN"
        assert result["child_inventory_status"] == "UNPROVED" and result["observed_process_birth_ids"] == ["direct-123"]
        original_counts = result["assertion_counts"].copy()
        required_profile = dict(mode="cpu", symbolization="deferred", require_direct_native=True)
        result = phase_run("requested-profile-missing", receipt_override=phase_receipt | dict(profile_request=required_profile))
        assert result["profile_request_status"] == "FAIL", "requested native profiles were silently omitted"
        assert result["export_status"] == "FAIL" and result["check_status"] == "FAIL"
        assert result["assertion_counts"] == original_counts
        assert 'type="missing_requested_profile"' in (root / "requested-profile-missing/junit.xml").read_text()
        start_marker = event("profile_start", 1, mode="cpu", symbolization_policy="deferred")
        checkpoint_payload["symbolization_policy"] = "deferred"
        profile.write_text(json.dumps(checkpoint_payload) + "\n")
        checkpoint_marker = checkpoint_marker | dict(symbolization_policy="deferred",
            input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest())
        captured_events = [item | dict(process_birth_id="direct-123") for item in
                           phase_events[:-1] + [start_marker, checkpoint_marker] + phase_events[-1:]]
        result = phase_run("requested-profile-captured", receipt_override=phase_receipt | dict(profile_request=required_profile), items=captured_events)
        assert result["profile_request_status"] == "CAPTURED" and result["export_status"] == "PASS"
        assert result["assertion_counts"] == original_counts and result["profile_sample_coverage_status"] == "UNPROVED"
        assert result["profile_symbolization_status"] == "PARTIAL", "capture contract cannot imply symbolization"
        conflicting = [item | dict(process_birth_id="direct-123") for item in phase_events[:-1] +
            [start_marker, start_marker | dict(mode="wall", symbolization_policy="native"), checkpoint_marker] + phase_events[-1:]]
        result = phase_run("requested-profile-conflicting-start", receipt_override=phase_receipt | dict(profile_request=required_profile), items=conflicting)
        assert result["profile_request_status"] == "FAIL", "contradictory sampler starts were accepted"
        assert result["export_status"] == "FAIL" and result["assertion_counts"] == original_counts
        profile.write_text(json.dumps(checkpoint_payload | dict(symbolization_policy="native")) + "\n")
        conflicting_marker = checkpoint_marker | dict(symbolization_policy="native",
            input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest())
        conflicting = [item | dict(process_birth_id="direct-123") for item in
            phase_events[:-1] + [start_marker, conflicting_marker] + phase_events[-1:]]
        result = phase_run("requested-profile-conflicting-policy", receipt_override=phase_receipt | dict(profile_request=required_profile), items=conflicting)
        assert result["profile_request_status"] == "FAIL", "checkpoint contradicted the admitted symbolization policy"
        assert result["export_status"] == "FAIL" and result["assertion_counts"] == original_counts
        profile.write_text(json.dumps(checkpoint_payload) + "\n")
        wrong_request = required_profile | dict(mode="wall")
        result = phase_run("requested-profile-wrong-mode", receipt_override=phase_receipt | dict(profile_request=wrong_request), items=captured_events)
        assert result["profile_request_status"] == "FAIL" and result["export_status"] == "FAIL"
        unsupported = [item | dict(process_birth_id="direct-123") for item in phase_events[:-1] +
            [event("profile_unavailable", 1, mode="wall", reason="requires_julia_1_13")] + phase_events[-1:]]
        result = phase_run("requested-profile-unsupported", receipt_override=phase_receipt | dict(profile_request=wrong_request), items=unsupported)
        assert result["profile_request_status"] == "FAIL" and result["assertion_counts"] == original_counts
        empty_payload = checkpoint_payload | dict(data=[], status="empty", unresolved_addresses=0,
                                                 symbolization_status="complete", lookup={"0": [None]})
        profile.write_text(json.dumps(empty_payload) + "\n")
        empty_marker = checkpoint_marker | dict(status="empty", data_words=0, unresolved_addresses=0,
            symbolization_status="complete",
            input_sha256=hashlib.sha256(profile.read_bytes()).hexdigest())
        empty_events = [item | dict(process_birth_id="direct-123") for item in
                       phase_events[:-1] + [start_marker, empty_marker] + phase_events[-1:]]
        result = phase_run("requested-profile-empty", receipt_override=phase_receipt | dict(profile_request=required_profile), items=empty_events)
        assert result["profile_request_status"] == "EMPTY" and result["export_status"] == "PASS"
        assert result["assertion_counts"] == original_counts and result["profile_records"][0]["data_words"] == 0
        profile.write_text(json.dumps(checkpoint_payload) + "\n")
        for name, request in (("bad-shape", {}), ("off-required", required_profile | dict(mode="off"))):
            result = phase_run("requested-profile-" + name, receipt_override=phase_receipt | dict(profile_request=request))
            assert result["profile_request_status"] == "FAIL" and result["export_status"] == "FAIL"
        assert (root / "bound-phase" / "original-log-0001.txt").read_text() == "source:owned/test.jl\n"
        timings = (root / "bound-phase" / "timings.csv").read_text()
        assert "reaping" in timings and "first_output_byte" in timings and "UNAVAILABLE" in timings
        observed_output = phase_receipt | dict(timings=dict(first_output_byte=dict(status="OBSERVED", seconds=.015,
            scope="combined_stdout_stderr_including_telemetry", measurement="parent_read_observation",
            application_readiness="UNPROVED")), output_observer=dict(status="PASS", reader_retired=True,
            eof_observed=True, bytes=100, forwarded_records=1, rejected_records=0,
            work_seconds=.004, cpu_seconds=.002, work_scope="inclusive_read_write_decode_forward_overlapping_command"))
        observed_rows = timing_rows([], dict(phases=[observed_output]))
        first = next(row for row in observed_rows if row["name"] == "tests: first_output_byte")
        assert first["seconds"] == .015 and first["outcome"] == "OBSERVED" and "readiness=UNPROVED" in first["metric_scope"]
        overhead = {row["name"]: row for row in observed_rows if row["kind"] == "diagnostic_overhead"}
        assert overhead["tests: output_observer_work"]["seconds"] == .004
        assert overhead["tests: output_observer_cpu"]["seconds"] == .002
        phase_failed = phase_receipt | dict(status="FAIL", semantic_status="FAIL", exit_code=1)
        failed_direct = json.loads(json.dumps(failed))
        for item in failed_direct:
            item["process_birth_id"] = "direct-123"
        result = phase_run("bound-phase-failure", receipt_override=phase_failed, items=failed_direct)
        assert result["test_status"] == "FAIL" and result["failure_detail_status"] == "AVAILABLE"
        assert "Expression: 1 == 2" in (root / "bound-phase-failure" / "junit.xml").read_text()
        result = phase_run("phase-soft-overrun", receipt_override=phase_receipt | dict(status="FAIL", soft_limit_exceeded=True))
        assert result["test_status"] == "FAIL" and 'type="SoftLimit"' in (root / "phase-soft-overrun" / "junit.xml").read_text()
        result = phase_run("phase-hard-cancellation", receipt_override=phase_receipt | dict(status="TIMEOUT", semantic_status="TIMEOUT", exit_code=-2), items=phase_events[:5])
        assert result["test_status"] == "FAIL" and result["coverage_status"] == "PARTIAL" and not result["observed_file_coverage_complete"]
        assert not result["processes"][0]["test_bodies_complete"]
        assert phase_run("stale-phase-receipt", receipt_override=phase_receipt | dict(invocation="older"))["export_status"] == "FAIL"
        assert phase_run("wrong-direct-birth", expected_direct_birth="other-123")["export_status"] == "FAIL"
        assert phase_run("wrong-direct-pid", receipt_override=phase_receipt | dict(pid=124), expected_direct_birth="direct-123")["export_status"] == "FAIL"
        wrong_phase = json.loads(json.dumps(phase_events))
        wrong_phase[0]["phase"] = "other-phase"
        assert phase_run("wrong-process-phase", items=wrong_phase)["export_status"] == "FAIL"
        late_wrong_phase = json.loads(json.dumps(phase_events))
        late_wrong_phase[4]["phase"] = "other-phase"
        assert phase_run("late-process-phase-conflict", items=late_wrong_phase)["export_status"] == "FAIL"
        wrong_inventory = phase_receipt | dict(expected_test_file_inventory=dict(source_digest=digest, files=[dict(path="test/not-run.jl", sha256="b"*64)]))
        assert phase_run("wrong-direct-files", receipt_override=wrong_inventory)["export_status"] == "FAIL"
        stale_log = phase_run("stale-phase-log", receipt_override=phase_receipt | dict(log_sha256="b"*64))
        assert stale_log["export_status"] == "FAIL" and not stale_log["original_logs"]
        for name, changes in (("nonzero-exit", dict(exit_code=7)), ("semantic-timeout", dict(semantic_status="TIMEOUT", exit_code=-2)),
                              ("unreaped", dict(direct_child_reaped=False, cleanup_status="UNRETIRED")),
                              ("unlatched-soft", dict(soft_limit_exceeded=True)), ("lost-diagnostics", dict(diagnostics_status="FAIL"))):
            result = phase_run("contradictory-pass-" + name, receipt_override=phase_receipt | dict(expected_test_file_inventory=None) | changes, items=[])
            assert result["export_status"] == "FAIL" and result["test_status"] == "FAIL"
            assert ET.fromstring((root / ("contradictory-pass-" + name) / "junit.xml").read_text()).find(".//failure") is not None
        result = phase_run("process-only-phase", receipt_override=phase_receipt | dict(expected_test_file_inventory=None), items=[])
        assert result["test_status"] == "UNKNOWN" and result["coverage_status"] == "PARTIAL"
        assert result["supervisor"]["phases"][0]["status"] == "PASS" and result["original_logs"]
        receipt.write_text(json.dumps(supervisor | dict(status="FAIL", loops=dict(mid=dict(status="FAIL", complete=True, seconds=11, budget_seconds=10)))))
        write(events)
        result = run("aggregate-soft-failure")
        assert result["test_status"] == "FAIL" and 'type="SoftLimit"' in (root / "aggregate-soft-failure" / "junit.xml").read_text()
        write(phase_events)
        phase_path.write_text(json.dumps(phase_receipt))
        linked = root / "linked-phase"
        assemble_phase([source], invocation="current", expected_source_digest=digest,
            source_roots=[(root, "owned")], output=linked / "public", phase_path=phase_path,
            expected_phase="tests", expected_direct_birth="direct-123")
        job_receipt = supervisor | dict(status="FAIL", phases=[phase_receipt | dict(diagnostics_directory=str(linked))],
            loops=dict(outer=dict(status="FAIL", complete=True, seconds=61, budget_seconds=60)))
        def job_run(name, current=None):
            receipt.write_text(json.dumps(job_receipt if current is None else current))
            return assemble_job(invocation="current", expected_source_digest=digest, source_roots=[(root, "owned")],
                output=root / name, supervisor_path=receipt)
        job = job_run("job-soft-failure")
        assert job["export_status"] == "PASS" and job["check_status"] == "FAIL" and job["test_status"] == "FAIL"
        assert job["assertion_counts"] is None and len(job["phase_bundles"]) == 1
        assert job["phase_bundles"][0]["artifact_status"] == "PASS"
        assert "not_aggregated" in (root / "job-soft-failure/summary.txt").read_text()
        assert 'type="SoftLimit"' in (root / "job-soft-failure/junit.xml").read_text()
        final_soft = job_receipt | dict(phases=[phase_receipt | dict(diagnostics_directory=str(linked), status="FAIL", soft_limit_exceeded=True)])
        assert job_run("job-final-phase-overrun", final_soft)["phase_bundles"][0]["command_status"] == "FAIL"
        contradictory_job = job_receipt | dict(phases=[phase_receipt | dict(diagnostics_directory=str(linked), exit_code=7)])
        job = job_run("job-contradictory-phase", contradictory_job)
        assert job["export_status"] == "FAIL" and job["phase_bundles"][0]["command_status"] == "FAIL"
        missing_command = job_receipt | dict(status="PASS", loops={}, required_phases=["missing"], phases=[])
        job = job_run("job-missing-required-command", missing_command)
        assert job["export_status"] == "FAIL" and job["check_status"] == "FAIL"
        wrong_birth_job = job_receipt | dict(phases=[phase_receipt | dict(diagnostics_directory=str(linked), process_token="other")])
        job = job_run("job-wrong-direct-birth", wrong_birth_job)
        assert job["export_status"] == "FAIL" and job["phase_bundles"][0]["artifact_status"] == "UNAVAILABLE"
        for invalid_invocation, invalid_digest in (("/private/synthetic-person", digest), ("current", "/private/synthetic-source")):
            try:
                assemble_job(invocation=invalid_invocation, expected_source_digest=invalid_digest,
                    source_roots=[(root, "owned")], output=root / "invalid-job-identity", supervisor_path=receipt)
            except ValueError:
                pass
            else:
                raise AssertionError("job accepted an unsafe identity")
            assert not (root / "invalid-job-identity").exists()
        setup_stage = root / "setup-stage"
        (setup_stage / "logs").mkdir(parents=True)
        (setup_stage / "prepared.json").write_text(json.dumps(dict(path=str(root / "source"))))
        (setup_stage / "logs/prepare.log").write_text("Setup failed at /private/synthetic-person/build\n")
        setup = assemble_preparation(stage=setup_stage, invocation="setup-control", expected_source_digest=digest,
            source_roots=[(root, "owned")], output=root / "preparation-only")
        assert setup["export_status"] == "PASS" and setup["test_status"] == "UNKNOWN"
        assert setup["check_status"] == "UNVERIFIED" and setup["assertion_counts"] is None and len(setup["setup_snapshots"]) == 2
        assert setup["artifact_scope"] == "PREPARATION_ONLY_UNVERIFIED"
        assert all(not unsafe_export(artifact) for artifact in (root / "preparation-only").iterdir())
        original_copy_profiles = globals()["copy_profiles"]
        def interrupted_copy(*args, **kwargs):
            raise KeyboardInterrupt("intentional export cancellation")
        globals()["copy_profiles"] = interrupted_copy
        try:
            try:
                phase_run("interrupted-publication")
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("intentional export cancellation was swallowed")
            assert not (root / "interrupted-publication").exists()
            try:
                checkpoint_run("interrupted-live-publication")
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("live checkpoint export cancellation was swallowed")
            assert not (root / "interrupted-live-publication").exists()
            assert (root / "live-checkpoint/manifest.json").read_bytes() == saved_manifest
        finally:
            globals()["copy_profiles"] = original_copy_profiles
        for artifact in (root / "bound-log").iterdir():
            assert not unsafe_export(artifact)
        encoded_paths = (
            r'{"items":[0,true,null,"prefix\u002fhome\u002fprivate\u002fvalue",[1],{"relative":"ok"}]}',
            r'{"items":[0,true,null,[{"\u002fhome\u002fprivate\u002fkey":"ok"}]]}',
            r'{"items":[0,true,null,{"relative":"C:\u005cprivate\u005cvalue"}]}',
            r'{"items":[0,true,null,{"relative":"\u005c\u005cprivate\u005cserver"}]}',
        )
        for suffix in (".json", ".jsonl"):
            rejected = root / ("encoded-path" + suffix)
            for encoded in encoded_paths:
                rejected.write_text(encoded + "\n")
                assert unsafe_export(rejected), "independent decoded privacy scan missed an escaped path"
            rejected.write_text('{"items":[0,true,null,3.5,"relative/path",[1],{"relative":"ok"}]}\n')
            assert not unsafe_export(rejected)
        rejected = root / "unsafe.xml"
        rejected.write_text('<testsuites><testcase name="prefix/home/private/test.jl" /></testsuites>')
        assert unsafe_export(rejected), "independent reject scan missed an embedded private root"
        rejected.write_text('<testsuites><testcase name="relative/test.jl" /></testsuites>')
        assert not unsafe_export(rejected), "XML closing syntax was treated as a path"
    print("PASS artifact privacy, native counts, phase/direct/log binding, live prefix checkpoints, partial/failed verdicts, atomic publication and raw profile controls; native sampling/decoding unverified")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--invocation")
    parser.add_argument("--source-digest")
    parser.add_argument("--source-map", action="append", default=[], metavar="ROOT=LABEL")
    parser.add_argument("--events", action="append", default=[])
    parser.add_argument("--supervisor")
    parser.add_argument("--phase-receipt", help="flat owned phase receipt; export one phase without combining repeated runs")
    parser.add_argument("--job", action="store_true", help="index supervisor command/loop verdict without aggregating native assertion counts")
    parser.add_argument("--phase")
    parser.add_argument("--direct-birth")
    parser.add_argument("--log-bindings", help="owned JSON array of path/invocation/source_digest/phase/input_sha256 records")
    parser.add_argument("--output")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not args.invocation or not args.source_digest or not args.source_map or not args.output:
        parser.error("invocation, source-digest, source-map and output are required")
    roots = [item.rsplit("=", 1) for item in args.source_map]
    if any(len(item) != 2 for item in roots):
        parser.error("each source-map is ROOT=LABEL")
    try:
        logs = []
        if args.log_bindings:
            log_issues = []
            raw = input_bytes(args.log_bindings, SourceMap(roots), log_issues)
            if log_issues:
                raise ValueError("log binding metadata unavailable")
            logs = parse_json(raw)
            if not isinstance(logs, list):
                raise ValueError("log bindings must be an array")
        if args.job:
            if not args.supervisor or args.phase_receipt or args.events or args.log_bindings:
                raise ValueError("job export needs --supervisor and uses separate phase evidence")
            report = assemble_job(invocation=args.invocation, expected_source_digest=args.source_digest,
                source_roots=roots, output=args.output, supervisor_path=args.supervisor)
        elif args.phase_receipt:
            if not args.phase or args.supervisor or args.log_bindings:
                raise ValueError("phase export needs --phase and derives its own log binding")
            report = assemble_phase(args.events, invocation=args.invocation,
                expected_source_digest=args.source_digest, source_roots=roots, output=args.output,
                phase_path=args.phase_receipt, expected_phase=args.phase, expected_direct_birth=args.direct_birth)
        else:
            report = assemble(args.events, invocation=args.invocation, expected_source_digest=args.source_digest,
                              source_roots=roots, output=args.output, supervisor_path=args.supervisor, logs=logs)
    except (OSError, ValueError) as error:
        print(f"FAIL artifact export: {type(error).__name__}", file=sys.stderr)
        return 1
    print(json.dumps({key: report[key] for key in ("export_status", "test_status", "coverage_status", "diagnostics_complete", "assembly_seconds")}))
    return 0 if report["export_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
