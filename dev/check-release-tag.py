"""Verify a tagged LibTmux source release before a public Git install."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


EXPECTED_REPOSITORY = "libtmux/libtmux-julia"
PUBLIC_REPOSITORY_URL = "https://github.com/libtmux/libtmux-julia.git"
ZERO_SHA = "0" * 40
SHA = re.compile(r"[0-9a-fA-F]{40}\Z")
VERSION = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
TAG = re.compile(r"v" + VERSION + r"\Z")


class ReleaseCheckError(RuntimeError):
    """The candidate tag cannot establish the requested source-release proof."""


@dataclass(frozen=True)
class Package:
    name: str
    uuid: str
    project: str
    subdir: str | None


PACKAGES = (
    Package("LibTmux", "1a5dcb9e-7968-44df-ad70-bf0a17628f09", "Project.toml", None),
    Package(
        "LibTmuxMCP",
        "6ec2004f-18ba-4da6-9e55-6cdc607d109e",
        "packages/LibTmuxMCP/Project.toml",
        "packages/LibTmuxMCP",
    ),
    Package(
        "LibTmuxWorkspace",
        "dc7c1d2a-fec3-4b55-92f0-7133c728c990",
        "packages/LibTmuxWorkspace/Project.toml",
        "packages/LibTmuxWorkspace",
    ),
)


def fail(message: str) -> None:
    raise ReleaseCheckError(message)


def sha(value: str, label: str) -> str:
    if not SHA.fullmatch(value):
        fail(f"{label} is not a full Git commit ID")
    return value.lower()


def tag_name(value: str) -> str:
    if not TAG.fullmatch(value):
        fail("tag must be a v-prefixed semantic version")
    return value


def run_git(arguments: list[str], *, cwd: Path) -> str:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            text=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as error:
        fail(f"Git is unavailable: {error.strerror}")
    if result.returncode:
        fail(f"Git command failed: {arguments[0]}")
    return result.stdout.strip()


def git_succeeds(arguments: list[str], *, cwd: Path) -> bool:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except OSError as error:
        fail(f"Git is unavailable: {error.strerror}")
    return result.returncode == 0


def read_project(checkout: Path, commit: str, package: Package) -> dict[str, Any]:
    source = run_git(["show", f"{commit}:{package.project}"], cwd=checkout)
    try:
        metadata = tomllib.loads(source)
    except tomllib.TOMLDecodeError as error:
        fail(f"{package.project} is not valid TOML: {error}")
    if not isinstance(metadata, dict):
        fail(f"{package.project} is not a package manifest")
    return metadata


def validate_package_metadata(metadata: dict[str, Any], package: Package, tag: str) -> None:
    version = tag.removeprefix("v")
    if metadata.get("name") != package.name:
        fail(f"{package.project} has an unexpected package name")
    if metadata.get("uuid") != package.uuid:
        fail(f"{package.project} has an unexpected package UUID")
    if metadata.get("version") != version:
        fail(f"{package.project} does not match tag {tag}")


def release_packages(checkout: Path, commit: str, tag: str) -> list[dict[str, str]]:
    tag = tag_name(tag)
    version = tag.removeprefix("v")
    packages: list[dict[str, str]] = []
    for package in PACKAGES:
        metadata = read_project(checkout, commit, package)
        validate_package_metadata(metadata, package, tag)
        tree_ref = f"{commit}^{{tree}}" if package.subdir is None else f"{commit}:{package.subdir}"
        packages.append(
            {
                "name": package.name,
                "uuid": package.uuid,
                "version": version,
                "subdir": package.subdir or "",
                "tree": sha(run_git(["rev-parse", tree_ref], cwd=checkout), "package tree"),
            }
        )
    return packages


def validate_event(event: dict[str, Any], *, tag: str, commit: str, ref: str, repository: str) -> None:
    tag = tag_name(tag)
    commit = sha(commit, "workflow commit")
    expected_ref = f"refs/tags/{tag}"
    if repository != EXPECTED_REPOSITORY:
        fail("workflow repository is not canonical")
    if ref != expected_ref:
        fail("workflow ref does not name the release tag")
    if event.get("ref") != expected_ref:
        fail("push event ref does not name the release tag")
    if event.get("deleted") is not False:
        fail("release tags must not be deleted")
    if event.get("created") is not True or event.get("before") != ZERO_SHA:
        fail("release tags must be newly created")
    if event.get("forced") is not False:
        fail("release tags must not be force-updated")
    payload_repository = event.get("repository")
    if not isinstance(payload_repository, dict) or payload_repository.get("full_name") != EXPECTED_REPOSITORY:
        fail("push event repository is not canonical")
    if sha(str(event.get("after", "")), "push event commit") != commit:
        fail("push event commit does not match the workflow commit")


def remote_tag_commit(checkout: Path, repository_url: str, tag: str) -> str:
    tag = tag_name(tag)
    direct = f"refs/tags/{tag}"
    output = run_git(["ls-remote", "--tags", repository_url, direct + "*"], cwd=checkout)
    references: dict[str, str] = {}
    for line in output.splitlines():
        try:
            value, name = line.split("\t", 1)
        except ValueError:
            fail("public remote returned an invalid tag reference")
        if name in (direct, direct + "^{}"):
            references[name] = sha(value, "public tag object")
    if direct not in references:
        fail("public remote does not contain the release tag")
    return references.get(direct + "^{}", references[direct])


def require_clean_checkout(checkout: Path, commit: str) -> None:
    if sha(run_git(["rev-parse", "HEAD^{commit}"], cwd=checkout), "checkout commit") != commit:
        fail("checkout does not match the workflow commit")
    if run_git(["status", "--porcelain=v1", "--untracked-files=all"], cwd=checkout):
        fail("checkout is dirty")


def require_trunk_ancestry(checkout: Path, repository_url: str, commit: str) -> None:
    trunk = "refs/remotes/release-check/master"
    arguments = ["fetch", "--no-tags"]
    if run_git(["rev-parse", "--is-shallow-repository"], cwd=checkout) == "true":
        arguments.append("--unshallow")
    arguments.extend((repository_url, f"refs/heads/master:{trunk}"))
    run_git(arguments, cwd=checkout)
    if not git_succeeds(["merge-base", "--is-ancestor", commit, trunk], cwd=checkout):
        fail("release tag commit is not reachable from master")


def toml_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def write_release_record(path: Path, *, tag: str, commit: str, packages: list[dict[str, str]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "schema_version = 1",
        f"repository = {toml_string(PUBLIC_REPOSITORY_URL)}",
        f"tag = {toml_string(tag)}",
        f"commit = {toml_string(commit)}",
    ]
    for package in packages:
        lines.extend(
            (
                "",
                "[[packages]]",
                f"name = {toml_string(package['name'])}",
                f"uuid = {toml_string(package['uuid'])}",
                f"version = {toml_string(package['version'])}",
                f"subdir = {toml_string(package['subdir'])}",
                f"tree = {toml_string(package['tree'])}",
            )
        )
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text("\n".join(lines) + "\n")
    temporary.replace(path)


def preflight(
    *,
    checkout: Path,
    event_path: Path,
    tag: str,
    commit: str,
    ref: str,
    repository: str,
    output: Path,
    repository_url: str = PUBLIC_REPOSITORY_URL,
) -> None:
    tag = tag_name(tag)
    commit = sha(commit, "workflow commit")
    try:
        event = json.loads(event_path.read_text())
    except OSError as error:
        fail(f"cannot read push event: {error.strerror}")
    except json.JSONDecodeError as error:
        fail(f"push event is not JSON: {error.msg}")
    if not isinstance(event, dict):
        fail("push event is not an object")
    validate_event(event, tag=tag, commit=commit, ref=ref, repository=repository)
    require_clean_checkout(checkout, commit)
    if remote_tag_commit(checkout, repository_url, tag) != commit:
        fail("public tag does not resolve to the workflow commit")
    require_trunk_ancestry(checkout, repository_url, commit)
    packages = release_packages(checkout, commit, tag)
    write_release_record(output, tag=tag, commit=commit, packages=packages)


def expect_error(action: Callable[[], None], fragment: str) -> None:
    try:
        action()
    except ReleaseCheckError as error:
        assert fragment in str(error), str(error)
    else:
        raise AssertionError(f"expected failure containing {fragment!r}")


def git(arguments: list[str], *, cwd: Path) -> str:
    return run_git(arguments, cwd=cwd)


def self_test() -> None:
    with tempfile.TemporaryDirectory(prefix="libtmux-julia-release-self-test-") as directory:
        root = Path(directory)
        source, remote, record = root / "source", root / "remote.git", root / "release.toml"
        git(["init", "-q", str(source)], cwd=root)
        git(["-C", str(source), "config", "user.name", "release check"], cwd=root)
        git(["-C", str(source), "config", "user.email", "release-check@example.invalid"], cwd=root)
        for package in PACKAGES:
            project = source / package.project
            project.parent.mkdir(parents=True, exist_ok=True)
            project.write_text(
                f'name = "{package.name}"\n'
                f'uuid = "{package.uuid}"\n'
                'version = "0.1.0-alpha.1"\n'
            )
        (source / "README.md").write_text("fixture\n")
        git(["-C", str(source), "add", "."], cwd=root)
        git(["-C", str(source), "commit", "-qm", "release fixture"], cwd=root)
        git(["-C", str(source), "branch", "-M", "master"], cwd=root)
        commit = sha(git(["-C", str(source), "rev-parse", "HEAD"], cwd=root), "fixture commit")
        git(["-C", str(source), "tag", "-a", "v0.1.0-alpha.1", "-m", "release fixture"], cwd=root)
        git(["init", "-q", "--bare", str(remote)], cwd=root)
        remote_url = remote.as_uri()
        git(["-C", str(source), "remote", "add", "origin", remote_url], cwd=root)
        git(["-C", str(source), "push", "-q", "origin", "master", "--tags"], cwd=root)
        event = {
            "ref": "refs/tags/v0.1.0-alpha.1",
            "before": ZERO_SHA,
            "after": commit,
            "created": True,
            "deleted": False,
            "forced": False,
            "repository": {"full_name": EXPECTED_REPOSITORY},
        }
        event_path = root / "event.json"
        event_path.write_text(json.dumps(event))
        preflight(
            checkout=source,
            event_path=event_path,
            tag="v0.1.0-alpha.1",
            commit=commit,
            ref="refs/tags/v0.1.0-alpha.1",
            repository=EXPECTED_REPOSITORY,
            output=record,
            repository_url=remote_url,
        )
        parsed = tomllib.loads(record.read_text())
        assert parsed["commit"] == commit
        assert parsed["tag"] == "v0.1.0-alpha.1"
        assert [item["subdir"] for item in parsed["packages"]] == [
            "",
            "packages/LibTmuxMCP",
            "packages/LibTmuxWorkspace",
        ]
        assert remote_tag_commit(source, remote_url, "v0.1.0-alpha.1") == commit
        shallow = root / "shallow"
        git(
            [
                "clone",
                "-q",
                "--depth",
                "1",
                "--branch",
                "v0.1.0-alpha.1",
                remote_url,
                str(shallow),
            ],
            cwd=root,
        )
        assert git(["-C", str(shallow), "rev-parse", "--is-shallow-repository"], cwd=root) == "true"
        require_trunk_ancestry(shallow, remote_url, commit)
        assert git(["-C", str(shallow), "rev-parse", "--is-shallow-repository"], cwd=root) == "false"
        expect_error(lambda: tag_name("alpha.1"), "v-prefixed")
        expect_error(lambda: tag_name("v0.1.0/escape"), "v-prefixed")
        expect_error(
            lambda: validate_event(
                event,
                tag="v0.1.0-alpha.1",
                commit=commit,
                ref="refs/tags/not-the-tag",
                repository=EXPECTED_REPOSITORY,
            ),
            "workflow ref",
        )
        retargeted = dict(event, before="f" * 40, created=False)
        expect_error(
            lambda: validate_event(
                retargeted,
                tag="v0.1.0-alpha.1",
                commit=commit,
                ref="refs/tags/v0.1.0-alpha.1",
                repository=EXPECTED_REPOSITORY,
            ),
            "newly created",
        )
        wrong_repository = dict(event, repository={"full_name": "example/other"})
        expect_error(
            lambda: validate_event(
                wrong_repository,
                tag="v0.1.0-alpha.1",
                commit=commit,
                ref="refs/tags/v0.1.0-alpha.1",
                repository=EXPECTED_REPOSITORY,
            ),
            "event repository",
        )
        expect_error(
            lambda: validate_event(
                event,
                tag="v0.1.0-alpha.1",
                commit="f" * 40,
                ref="refs/tags/v0.1.0-alpha.1",
                repository=EXPECTED_REPOSITORY,
            ),
            "does not match",
        )
        wrong_package = dict(read_project(source, commit, PACKAGES[0]), name="Wrong")
        expect_error(
            lambda: validate_package_metadata(wrong_package, PACKAGES[0], "v0.1.0-alpha.1"),
            "package name",
        )
        wrong_version = dict(read_project(source, commit, PACKAGES[0]), version="0.1.0")
        expect_error(
            lambda: validate_package_metadata(wrong_version, PACKAGES[0], "v0.1.0-alpha.1"),
            "does not match",
        )
        (source / "untracked").write_text("dirty\n")
        expect_error(lambda: require_clean_checkout(source, commit), "dirty")
        (source / "untracked").unlink()
        tree = sha(git(["-C", str(source), "write-tree"], cwd=root), "fixture tree")
        unrelated = sha(
            git(["-C", str(source), "commit-tree", tree, "-m", "unrelated"], cwd=root),
            "unrelated commit",
        )
        expect_error(
            lambda: require_trunk_ancestry(source, remote_url, unrelated),
            "not reachable",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("self-test", help="run deterministic release-validation checks")
    verify = commands.add_parser("verify", help="validate a pushed tag and write a release record")
    verify.add_argument("--checkout", type=Path, required=True)
    verify.add_argument("--event", type=Path, required=True)
    verify.add_argument("--tag", required=True)
    verify.add_argument("--commit", required=True)
    verify.add_argument("--ref", required=True)
    verify.add_argument("--repository", required=True)
    verify.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "self-test":
            self_test()
        else:
            preflight(
                checkout=arguments.checkout.resolve(),
                event_path=arguments.event.resolve(),
                tag=arguments.tag,
                commit=arguments.commit,
                ref=arguments.ref,
                repository=arguments.repository,
                output=arguments.output.resolve(),
            )
    except (OSError, ReleaseCheckError) as error:
        print(f"NOT RUN: {error}", file=os.sys.stderr)
        return 2
    print("PASS release tag verification")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
