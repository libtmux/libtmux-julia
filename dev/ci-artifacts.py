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

    def text(self, value):
        text = str(value)
        for physical, logical in self.roots:
            pattern = re.escape(physical) + r"(?=$|[/\\\s:;,\"'<>`\)])"
            text = re.sub(pattern, lambda _: logical, text)
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
    events, birth, pid, previous, previous_elapsed = [], None, None, 0, 0
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
                or event.get("process_birth_id", birth) != birth):
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


def collect_process_evidence(event_paths, *, invocation, expected_source_digest, source_roots, expected_phase=None):
    """Read bounded native evidence without writing or certifying child admission.

The supervisor must independently supply the expected process/file inventory.
Observed streams alone cannot establish that all admitted children reported.
"""
    if (not isinstance(invocation, str) or not IDENTIFIER.fullmatch(invocation)
            or not isinstance(expected_source_digest, str) or not SHA256.fullmatch(expected_source_digest)):
        raise ValueError("portable invocation and SHA256 source digest are required")
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
    if any(type(word) is not int or not 0 <= word < 2**64 for word in payload["data"]):
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


def copy_profiles(processes, event_paths, *, invocation, source_digest, mapping, output, issues):
    """Retain hashed raw checkpoints; native decoder success needs separate proof."""
    records, previous, total_bytes, attempted = [], {}, 0, 0
    for process in processes:
        start = process["events"][0] if process["events"] else {}
        directory = Path(event_paths[process["input_ordinal"] - 1]).parent
        for event in process["profiles"]:
            if event["event"] != "profile_checkpoint":
                records.append(dict(process_id=process["process_id"], mode=event.get("mode", "unknown"),
                                    status="UNAVAILABLE", reason=event.get("reason", event["event"])))
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
            if (not isinstance(payload, dict) or not bounded_structure(payload) or type(payload.get("schema")) is not int or payload["schema"] != 2
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
            filename = f"profile-{len(records):04d}-{event['mode']}.json"
            safe = mapping.value(payload)
            # Do not trust a producer-supplied decoder verdict.
            safe["decoder_status"] = "RAW_PRESERVED_NATIVE_DECODER_UNVERIFIED"
            safe["measurement_scope"] = "cumulative_checkpoint; checkpoints overlap"
            (output / filename).write_text(json.dumps(safe, sort_keys=True) + "\n")
            record.update(file=filename, status="RAW_PRESERVED", capture_status=payload["status"],
                          input_sha256=digest, data_words=len(payload["data"]), lookup_addresses=len(payload["lookup"]),
                          julia=payload["julia"], threads=payload["threads"],
                          decoder_status=safe["decoder_status"],
                          capture_seconds=event["capture_seconds"] if finite_number(event.get("capture_seconds")) and event["capture_seconds"] >= 0 else None)
    return records


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
    return mapping.value(receipt)


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
        for phase in receipt.get("phases", []):
            rows.append(dict(kind="whole_command", name=phase.get("name", "unknown"), process_id="supervisor",
                             seconds=phase.get("seconds"), outcome=phase.get("status", "unknown"), metric_scope="startup_execution_retirement_inclusive"))
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


def export_strings(path):
    """Inspect decoded values so XML syntax and JSON escapes cannot hide paths."""
    def strings(value):
        if isinstance(value, str):
            yield value
        elif isinstance(value, list):
            for item in value:
                yield from strings(item)
        elif isinstance(value, dict):
            for key, item in value.items():
                yield key
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
        yield path.read_text()


def unsafe_export(path):
    return any(PRIVATE_PATH_REJECT.search(value) or ABSOLUTE_PATH.search(value) for value in export_strings(path))


def assemble(event_paths, *, invocation, expected_source_digest, source_roots, output, supervisor_path=None, logs=()):
    """Write safe partial evidence; export_status is separate from test_status.

Each log input is a dictionary binding path, invocation, source_digest and
phase. A missing or conflicting binding cannot export the original log.
Only source-bound hashed profile checkpoints can export raw portable payloads.
Native decoding remains unverified until independently exercised in Julia.
"""
    started = time.monotonic()
    event_paths = tuple(event_paths)
    evidence = collect_process_evidence(event_paths, invocation=invocation, expected_source_digest=expected_source_digest,
                                        source_roots=source_roots)
    mapping = SourceMap(source_roots)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    if output.is_symlink() or any(output.iterdir()):
        raise ValueError("output must be a fresh owned directory")
    issues, processes = evidence["issues"], evidence["processes"]
    receipt = read_receipt(supervisor_path, invocation=invocation, source_digest=expected_source_digest, mapping=mapping, issues=issues)
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
                               "Profile copying is bounded to 32 checkpoints, 32 MiB each and 128 MiB total."])
    report["profile_records"] = copy_profiles(processes, event_paths, invocation=invocation,
                                              source_digest=expected_source_digest, mapping=mapping, output=output, issues=issues)
    copied = sum(record["status"] == "RAW_PRESERVED" for record in report["profile_records"])
    report["profile_copy_status"] = ("PARTIAL" if copied < len(report["profile_records"]) else "RAW_PRESERVED") if copied else "UNAVAILABLE"
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
        (output / filename).write_text(mapping.text(raw.decode("utf-8", errors="replace")))
        report["original_logs"].append(dict(file=filename, phase=mapping.text(item["phase"]), input_sha256=digest))
    rows = timing_rows(processes, receipt)
    columns = ["kind", "name", "process_id", "seconds", "outcome", "file", "line", "metric_scope", "allocation_bytes", "gc_seconds", "compile_seconds", "compile_status"]
    with (output / "timings.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)
    (output / "junit.xml").write_text(junit(report))
    summary = [f"Tests: {test_status}. Coverage: {report['coverage_status']}. Profiles: {report['profile_copy_status']}.",
               f"Invocation: {invocation}. Source digest: {expected_source_digest}.",
               f"Assertion counts ({report['count_scope']}): {json.dumps(counts, sort_keys=True)}.",
               f"Original assertion/error details: {report['failure_detail_status']}.",
               "JUnit case counts represent diagnostic units, not native assertion totals.", "", "Ranked timings:"]
    summary.extend(f"{row['seconds'] if row['seconds'] is not None else 'unavailable'}s {row['kind']} {row['name']} ({row['outcome']})" for row in rows)
    summary.extend(["", "Limitations:"] + report["limitations"])
    (output / "summary.txt").write_text(mapping.text("\n".join(summary) + "\n"))
    report["redacted_absolute_paths"] = mapping.redacted_paths + evidence["redacted_absolute_paths"]
    report["export_status"] = "FAIL" if any(item["severe"] for item in issues) or any(item["severe"] for process in processes for item in process["issues"]) else "PASS"
    report["assembly_seconds"] = time.monotonic() - started
    (output / "diagnostics.json").write_text(json.dumps(mapping.value(report), indent=2, sort_keys=True) + "\n")
    unsafe = [path.name for path in output.iterdir() if unsafe_export(path)]
    if unsafe:
        # A rejected export keeps no uploadable unsafe payload.
        for filename in unsafe:
            (output / filename).unlink()
        raise ValueError("export reject scan found an absolute path")
    manifest = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in output.iterdir() if path.is_file()}
    (output / "manifest.json").write_text(json.dumps(dict(schema=1, invocation=invocation, source_digest=expected_source_digest, files=manifest), indent=2, sort_keys=True) + "\n")
    return report


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
        write(profile_events(payload | dict(data=[2**64, 123, 0])))
        assert run("invalid-profile-word")["export_status"] == "FAIL"
        legacy = profile_events(payload)
        for key in ("checkpoint_seq", "input_sha256"):
            legacy[-2].pop(key)
        write(legacy)
        assert run("legacy-profile")["profile_copy_status"] == "UNAVAILABLE"
        for artifact in (root / "bound-log").iterdir():
            assert not unsafe_export(artifact)
        rejected = root / "unsafe.xml"
        rejected.write_text('<testsuites><testcase name="prefix/home/private/test.jl" /></testsuites>')
        assert unsafe_export(rejected), "independent reject scan missed an embedded private root"
        rejected.write_text('<testsuites><testcase name="relative/test.jl" /></testsuites>')
        assert not unsafe_export(rejected), "XML closing syntax was treated as a path"
    print("PASS artifact privacy, source binding, counts, file coverage, nested names and raw profile serializer controls; native sampling/decoding unverified")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--invocation")
    parser.add_argument("--source-digest")
    parser.add_argument("--source-map", action="append", default=[], metavar="ROOT=LABEL")
    parser.add_argument("--events", action="append", default=[])
    parser.add_argument("--supervisor")
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
        report = assemble(args.events, invocation=args.invocation, expected_source_digest=args.source_digest,
                          source_roots=roots, output=args.output, supervisor_path=args.supervisor, logs=logs)
    except (OSError, ValueError) as error:
        print(f"FAIL artifact export: {type(error).__name__}", file=sys.stderr)
        return 1
    print(json.dumps({key: report[key] for key in ("export_status", "test_status", "coverage_status", "diagnostics_complete", "assembly_seconds")}))
    return 0 if report["export_status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
