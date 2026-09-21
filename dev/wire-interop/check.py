"""Prepare external runners separately from the timed, offline differential check."""
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile
import time
import tomllib

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def command(args, **kwargs):
    return subprocess.run(args, check=True, text=True, **kwargs)


def verified_head(root, revision):
    actual = command(["git", "-C", str(root), "rev-parse", "HEAD"], capture_output=True).stdout.strip()
    if actual != revision:
        raise RuntimeError("sibling revision differs from the fixture pin")
    if command(["git", "-C", str(root), "status", "--porcelain"], capture_output=True).stdout:
        raise RuntimeError("sibling checkout has uncommitted changes")


def inline_toml(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(k) + " = " + inline_toml(v)
                                 for k, v in value.items()) + " }"
    if isinstance(value, list):
        return "[" + ", ".join(map(inline_toml, value)) + "]"
    if value is None:
        raise ValueError("null is outside the verified subset")
    return json.dumps(value, ensure_ascii=False)


def write_toml(path, corpus):
    lines = []
    for kind in ("panes", "valid", "invalid"):
        for entry in corpus[kind]:
            lines.append("[[" + kind + "]]")
            lines.extend(json.dumps(key) + " = " + inline_toml(value)
                         for key, value in entry.items())
    path.write_text("\n".join(lines) + "\n")


def prepare(args, corpus):
    ts_root = pathlib.Path(args.typescript).resolve()
    rs_root = pathlib.Path(args.rust).resolve()
    verified_head(ts_root, corpus["typescript_revision"])
    verified_head(rs_root, corpus["rust_revision"])
    stage = pathlib.Path(tempfile.mkdtemp(prefix="libtmux-julia-wire-"))
    rust = stage / "rust"
    (rust / "src").mkdir(parents=True)
    for name in ("typescript.ts", "julia.jl"):
        shutil.copyfile(HERE / name, stage / name)
    shutil.copyfile(HERE / "rust.rs", rust / "src" / "main.rs")
    manifest = (
        '[package]\nname = "libtmux-julia-wire-proof"\nversion = "0.0.0"\nedition = "2024"\n'
        '[dependencies]\nlibtmux = { path = ' + json.dumps(str(rs_root / "crates/libtmux")) +
        ', features = ["serde", "derive"] }\n'
        'serde = { version = "1", features = ["derive"] }\nserde_json = "1"\n'
    )
    (rust / "Cargo.toml").write_text(manifest)
    shutil.copyfile(rs_root / "Cargo.lock", rust / "Cargo.lock")
    started = time.perf_counter()
    command([args.cargo, "build", "--offline", "--manifest-path", str(rust / "Cargo.toml"),
             "--target-dir", str(stage / "target")])
    config = {"typescript": str(ts_root), "rust": str(rs_root), "bun": args.bun,
              "julia": args.julia, "pins": {k: corpus[k] for k in
              ("typescript_revision", "rust_revision")}}
    (stage / "stage.json").write_text(json.dumps(config))
    print(json.dumps({"stage": str(stage), "build_seconds": time.perf_counter() - started}))


def run_siblings(stage, config, corpus, label):
    path = stage / (label + ".json")
    path.write_text(json.dumps(corpus, ensure_ascii=False))
    ts = json.loads(command([config["bun"], str(stage / "typescript.ts"),
        config["typescript"], str(path)], capture_output=True).stdout)
    rs = json.loads(command([str(stage / "target/debug/libtmux-julia-wire-proof"), str(path)],
        capture_output=True).stdout)
    for name, result in (("typescript", ts), ("rust", rs)):
        for actual, fixture in zip(result["valid"], corpus["valid"], strict=True):
            if actual["id"] != fixture["id"] or actual["selected"] != fixture["expected"]:
                raise RuntimeError(f"{name} mismatch in {fixture['id']}: {actual['selected']}")
        for actual, fixture in zip(result["invalid"], corpus["invalid"], strict=True):
            if actual["id"] != fixture["id"] or not actual["rejected"]:
                raise RuntimeError(f"{name} accepted invalid {fixture['id']}")
    return ts, rs


def check(args, corpus):
    started = time.perf_counter()
    stage = pathlib.Path(args.stage).resolve()
    config = json.loads((stage / "stage.json").read_text())
    for language in ("typescript", "rust"):
        revision = corpus[language + "_revision"]
        if config["pins"][language + "_revision"] != revision:
            raise RuntimeError("stage fixture pins changed; prepare again")
        verified_head(config[language], revision)
    for name in ("typescript.ts", "julia.jl"):
        if (stage / name).read_bytes() != (HERE / name).read_bytes():
            raise RuntimeError("harness source changed; prepare again")
    if (stage / "rust/src/main.rs").read_bytes() != (HERE / "rust.rs").read_bytes():
        raise RuntimeError("Rust harness source changed; prepare again")
    ts, rs = run_siblings(stage, config, corpus, "source")
    canonical = {"panes": corpus["panes"], "valid": [], "invalid": corpus["invalid"]}
    for original, t, r in zip(corpus["valid"], ts["valid"], rs["valid"], strict=True):
        canonical["valid"].append({"id": original["id"], "expected": original["expected"],
            "typescript": t["canonical"], "rust": r["canonical"]})
    wire_input, wire_output = stage / "canonical.toml", stage / "julia.toml"
    write_toml(wire_input, canonical)
    command([config["julia"], "--startup-file=no", "--compile=min", "-O0", "--project=" + str(ROOT),
             str(stage / "julia.jl"), str(ROOT), str(wire_input), str(wire_output)])
    julia_output = tomllib.loads(wire_output.read_text())
    run_siblings(stage, config, julia_output, "julia")
    print(json.dumps({"status": "PASS", "valid_cases": len(corpus["valid"]),
        "invalid_cases": len(corpus["invalid"]), "rounds": 2,
        "check_seconds": time.perf_counter() - started}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    prep = modes.add_parser("prepare")
    prep.add_argument("--typescript", required=True)
    prep.add_argument("--rust", required=True)
    prep.add_argument("--julia", default="julia")
    prep.add_argument("--bun", default="bun")
    prep.add_argument("--cargo", default="cargo")
    run = modes.add_parser("check")
    run.add_argument("stage")
    args = parser.parse_args()
    corpus = tomllib.loads((HERE / "fixtures.toml").read_text())
    prepare(args, corpus) if args.mode == "prepare" else check(args, corpus)
