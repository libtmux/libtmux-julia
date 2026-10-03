"""Prepare and prove an explicit Lua producer for Julia-owned criteria JSON."""
import argparse
import hashlib
import io
import json
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
HARNESS = ("check-lua.py", "lua.lua", "lua.jl", "lua-producer.lua", "lua-fixtures.json")
PRODUCT = tuple(sorted(str(path.relative_to(ROOT)) for path in (ROOT / "src").rglob("*.jl"))) + (
    "ext/LibTmuxJSONExt.jl", "schema/fields.toml", "Project.toml")


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def hashes(root, files):
    return {str(path): digest(root / path) for path in files}


def runtime_sources(stage):
    return sorted(path.relative_to(stage) for folder in ("lua", "codec")
                  for path in (stage / folder).rglob("*.lua"))


def clean_checkout(root, revision=None):
    if command(["git", "-C", str(root), "status", "--porcelain"],
               capture_output=True).stdout:
        raise RuntimeError("reference checkout has uncommitted changes")
    actual = command(["git", "-C", str(root), "rev-parse", "HEAD"],
                     capture_output=True).stdout.strip()
    if revision is not None and actual != revision:
        raise RuntimeError("codec revision differs from the fixture pin")
    return actual


def prepare(args):
    started = time.perf_counter()
    corpus = json.loads((HERE / "lua-fixtures.json").read_text())
    lua_root, codec_root = pathlib.Path(args.lua_root).resolve(), pathlib.Path(args.codec_root).resolve()
    clean_checkout(lua_root)
    clean_checkout(codec_root, corpus["codec_revision"])
    stage = pathlib.Path(tempfile.mkdtemp(prefix="libtmux-lua-wire-"))
    for name in HARNESS:
        shutil.copyfile(HERE / name, stage / name)
    archive = subprocess.run(["git", "-C", str(lua_root), "archive",
                              corpus["lua_revision"], "lua"], check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(archive)) as source:
        source.extractall(stage, filter="data")
    shutil.copytree(codec_root / "src", stage / "codec")
    julia_project = pathlib.Path(args.julia_project).resolve()
    lua, julia = shutil.which(args.lua), shutil.which(args.julia)
    if lua is None or julia is None:
        raise RuntimeError("explicit Lua and Julia executables are required")
    lua, julia = str(pathlib.Path(lua).resolve()), str(pathlib.Path(julia).resolve())
    lua_version = command([lua, "-v"], capture_output=True).stdout.strip()
    if not lua_version.startswith("Lua 5.5.1 "):
        raise RuntimeError("Lua 5.5.1 is required for this pinned conformance check")
    config = {"lua": lua, "julia": julia, "julia_project": str(julia_project),
              "julia_depot": os.environ.get("JULIA_DEPOT_PATH"),
              "lua_revision": corpus["lua_revision"], "codec_revision": corpus["codec_revision"],
              "harness": hashes(HERE, HARNESS), "product": hashes(ROOT, PRODUCT),
              "runtime": hashes(stage, runtime_sources(stage)),
              "lua_version": lua_version,
              "executables": {lua: digest(pathlib.Path(lua)), julia: digest(pathlib.Path(julia))}}
    command([julia, "--startup-file=no", "--compile=min", "-O0", "--project=" + str(julia_project),
             "-e", "using LibTmux, JSON; @assert realpath(dirname(dirname(pathof(LibTmux)))) == realpath(ARGS[1]); @assert Base.pkgversion(JSON) == v\"1.9.0\"", str(ROOT)],
            capture_output=True)
    (stage / "stage.json").write_text(json.dumps(config))
    print(json.dumps({"stage": str(stage), "prepare_seconds": time.perf_counter() - started}))


def environment(stage, config):
    env = os.environ.copy()
    for key in tuple(env):
        if key.startswith("LUA_INIT"):
            env.pop(key)
    env["LUA_PATH"] = ";".join(str(stage / pattern) for pattern in
                             ("lua/?.lua", "lua/?/init.lua", "codec/?.lua"))
    if config["julia_depot"] is not None:
        env["JULIA_DEPOT_PATH"] = config["julia_depot"]
    return env


def validate_inputs(stage, config, corpus):
    for name in ("lua_revision", "codec_revision"):
        if config[name] != corpus[name]:
            raise RuntimeError("fixture pins changed; prepare again")
    if hashes(HERE, HARNESS) != config["harness"] or hashes(stage, HARNESS) != config["harness"]:
        raise RuntimeError("harness changed; prepare again")
    if hashes(ROOT, PRODUCT) != config["product"]:
        raise RuntimeError("criteria source changed; prepare again")
    if hashes(stage, runtime_sources(stage)) != config["runtime"]:
        raise RuntimeError("pinned runtime source changed; prepare again")
    if any(digest(pathlib.Path(path)) != expected
           for path, expected in config["executables"].items()):
        raise RuntimeError("runtime executable changed; prepare again")


def check(args):
    started = time.perf_counter()
    stage = pathlib.Path(args.stage).resolve()
    config = json.loads((stage / "stage.json").read_text())
    (stage / "result.json").unlink(missing_ok=True)
    corpus = json.loads((HERE / "lua-fixtures.json").read_text())
    validate_inputs(stage, config, corpus)
    env, produced = environment(stage, config), stage / "produced.json"
    lua = json.loads(command([config["lua"], str(stage / "lua.lua"),
        str(stage / "lua-fixtures.json"), str(produced)], env=env, capture_output=True).stdout)
    julia = json.loads(command([config["julia"], "--startup-file=no", "--compile=min", "-O0",
        "--project=" + config["julia_project"], str(stage / "lua.jl"),
        str(stage / "lua-fixtures.json"), str(produced), str(ROOT)], env=env, capture_output=True).stdout)
    for result in (lua, julia):
        if result["valid_cases"] != len(corpus["valid"]):
            raise RuntimeError("driver omitted fixtures")
        accepted = {row["name"]: row["detail"] for row in result["records"]
                    if row["status"] == "accepted"}
        for case in corpus["valid"]:
            if accepted[case["name"]] != case["expected"]:
                raise RuntimeError("native semantic differential disagrees")
    if julia["json_version"] != "1.9.0":
        raise RuntimeError("JSON version differs from the verified codec")
    example_env = env.copy()
    example_env["LUA_PATH"] = str(stage / "codec/?.lua")
    example = command([config["lua"], str(stage / "lua-producer.lua")],
                      env=example_env, capture_output=True).stdout
    reference = next(row for row in json.loads(produced.read_text())
                     if row["name"] == "false-is-value")
    if json.loads(example) != json.loads(reference["julia_json"]):
        raise RuntimeError("authored producer example differs from tested criteria")
    validate_inputs(stage, config, corpus)
    receipt = {"status": "PASS", "profile": corpus["profile"],
               "valid_cases": len(corpus["valid"]), "check_seconds": time.perf_counter() - started,
               "pins": {key: config[key] for key in ("lua_revision", "codec_revision")},
               "source": config["product"], "lua": lua, "julia": julia}
    (stage / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2))
    print(json.dumps({key: value for key, value in receipt.items() if key not in ("lua", "julia")}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prep = modes.add_parser("prepare")
    prep.add_argument("--lua-root", required=True)
    prep.add_argument("--codec-root", required=True)
    prep.add_argument("--lua", required=True)
    prep.add_argument("--julia", default="julia")
    prep.add_argument("--julia-project", required=True)
    run = modes.add_parser("check")
    run.add_argument("stage")
    args = parser.parse_args()
    prepare(args) if args.mode == "prepare" else check(args)
