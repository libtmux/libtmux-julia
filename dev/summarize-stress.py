#!/usr/bin/env python3
"""Count each matrix phase's failures over repeated runs of check-matrix.py run."""

import csv
import json
import os
from pathlib import Path
import sys


def summarize(directory):
    runs = sorted(Path(directory).glob("run-*.json"))
    counts = {}
    for run in runs:
        for item in json.loads(run.read_text()).get("phases", []):
            row = counts.setdefault(item["name"], dict(runs=0, failures=0, statuses={}, slowest=0.0))
            row["runs"] += 1
            row["failures"] += item["status"] != "PASS"
            row["statuses"][item["status"]] = row["statuses"].get(item["status"], 0) + 1
            row["slowest"] = max(row["slowest"], item.get("seconds", 0.0))
    return len(runs), counts


def testsets(directory):
    """Count each top-level testset's runs and failing runs from the phase logs."""
    counts = {}
    for log in sorted(Path(directory).glob("log-*.txt")):
        lines = log.read_text(errors="replace").splitlines()
        for index, line in enumerate(lines[:-1]):
            if line.startswith("Test Summary:") and "|" in line:
                header = line.split("|", 1)[1]
                name = lines[index + 1].split("|", 1)[0].strip()
                row = counts.setdefault(name, dict(runs=0, failures=0))
                row["runs"] += 1
                row["failures"] += "Fail" in header or "Error" in header
    return counts


def main(argv):
    directory, label = argv[1], argv[2]
    total, counts = summarize(directory)
    with open(Path(directory) / "failure-counts.csv", "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["lane", "phase", "repetitions", "failures", "statuses", "slowest_seconds"])
        for name, row in counts.items():
            statuses = ";".join(f"{key}={value}" for key, value in sorted(row["statuses"].items()))
            writer.writerow([label, name, row["runs"], row["failures"], statuses, f"{row['slowest']:.1f}"])
    lines = [f"### {label}: {total} repetitions", "",
             "| phase | runs | failures | statuses | slowest (s) |", "|---|---|---|---|---|"]
    for name, row in counts.items():
        statuses = ", ".join(f"{key} {value}" for key, value in sorted(row["statuses"].items()))
        lines.append(f"| {name} | {row['runs']} | {row['failures']} | {statuses} | {row['slowest']:.1f} |")
    sets = testsets(directory)
    with open(Path(directory) / "testset-failure-counts.csv", "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["lane", "testset", "runs", "failures"])
        for name, row in sorted(sets.items()):
            writer.writerow([label, name, row["runs"], row["failures"]])
    failing = {name: row for name, row in sets.items() if row["failures"]}
    lines += ["", f"{len(sets)} testsets observed; {len(failing)} failed at least once."]
    if failing:
        lines += ["", "| testset | runs | failures |", "|---|---|---|"]
        lines += [f"| {name} | {row['runs']} | {row['failures']} |" for name, row in sorted(failing.items())]
    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as handle:
            handle.write(text)


if __name__ == "__main__":
    main(sys.argv)
