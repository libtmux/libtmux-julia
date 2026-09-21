# Criteria wire interoperability

The explicitly named Julia adapters translate a verified pane-scalar subset
between two existing version-1 envelopes. The Julia-owned `encode_where`
profile remains separate.

| API | Envelope |
| --- | --- |
| `encode_typescript_where`, `decode_typescript_where` | `version`, `model`, `where` |
| `encode_rust_where`, `decode_rust_where` | `version`, `target`, `expr` |

Both adapters return or consume inert data; they do not select a JSON library
or perform I/O. `WhereLimits` bounds input before translation and bounds output.
Duplicate-preserving `WireObject` inputs retain core duplicate-key checks.
`UnsupportedCriterion` identifies meanings outside the supported subset;
preflight violations retain `WireCriteriaError`.

## Verified subset

Pane fields: `id`, `index`, `active`, `dead`, `width`, `height`,
`current_command`, `current_path`, and `title`. Wire fields use tmux tokens
such as `pane_current_command`, mapped from the explicit Julia field catalog.

Supported operations are equality, membership, case-sensitive substring,
prefix and suffix matching, and nonempty Boolean composition. Julia inequality
exports as a negated equality. Single-child Boolean nodes collapse on export.
Empty membership is supported. TypeScript `NOT` arrays mean that every child
is false; they do not negate one conjunction.

Boolean TypeScript wire operands are `"0"` or `"1"`; Rust operands are Boolean.
Both profiles encode integer operands as canonical decimal strings. The
verified shared integer domain is unsigned 32-bit, matching Rust pane fields.
Text does not normalize Unicode or interpret format-like content.

Relations, other entity types, null operands, numeric ordering, regular
expressions, case folding, aliases, `notIn`/`not_in`, and empty criteria are
explicitly unsupported. TypeScript's additional authored scalar forms are
outside this wire adapter. Do not infer general schema equivalence from the
shared subset.

## Scope of the executable proof

[fixtures.toml](fixtures.toml) contains three captured pane rows, 16 valid
criteria, and six invalid documents. Every available field has a concrete
value. Absent, unavailable and uncaptured graph states are outside this proof.

The TypeScript runner calls its public decoder and encoder, then the actual
`compileWhere` evaluator over scalar projection records. It does not exercise
projection authentication, live handles, or tmux acquisition.

The Rust runner validates each document as the production `FilterExpr<Pane>`.
Public pane handles lack an inert constructor, so evaluation uses the same
library's `Filterable` derive over fixture rows with matching scalar types.
It does not claim execution over live Rust pane handles or optional-field
coverage equivalence.

The driver performs two rounds:

1. Both pinned siblings parse, evaluate and canonicalize shared fixtures.
2. Julia imports both canonical forms, checks the same ordered pane IDs,
   cross-exports them, and both siblings parse and evaluate the exports.

All three runtimes also reject the shared invalid fixtures. Julia unit tests
separately cover limits, cycles, duplicates, operand ownership and unsupported
meanings. No tmux server or reference-repository mutation is required.

## Reproduce

Prepare dependencies and runtimes first. The runner requires Python 3.11+,
Bun, Rust/Cargo, Julia, and both sibling checkouts at the pinned clean revisions.
Cargo preparation is offline and fails if required crates are not cached.
It builds in a fresh external temporary directory; it never changes either
reference checkout.

```console
$ wire_stage=$(python3 dev/wire-interop/check.py prepare \
    --typescript ../libtmux-ts \
    --rust ../libtmux-rs \
    --julia julia | jq -r .stage)
```

Run the prepared check. It verifies sibling revisions and runner source files
before execution and prints monotonic elapsed time.

```console
$ python3 dev/wire-interop/check.py check "$wire_stage"
```

Remove only the stage created by preparation when finished.

```console
$ rm -rf -- "$wire_stage"
```

Measured with Julia 1.13.0, Bun 1.4.2 and Cargo 1.98.0: separate offline Rust
build preparation took 12.67 seconds. The final 16-valid/six-invalid check took
1.404 seconds including Python process startup. These are local measurements,
not runtime guarantees or a compatibility matrix.

## Pinned primary sources

- TypeScript revision
  [`ee5a031`](https://github.com/libtmux/libtmux-ts/tree/ee5a0312620b4b001b8f0d1144f7ad16193cc933):
  [serialization](https://github.com/libtmux/libtmux-ts/blob/ee5a0312620b4b001b8f0d1144f7ad16193cc933/packages/libtmux/src/_internal/selection/serialization.ts),
  [scalar decoding](https://github.com/libtmux/libtmux-ts/blob/ee5a0312620b4b001b8f0d1144f7ad16193cc933/packages/libtmux/src/_internal/codec/format_values.ts),
  [evaluation](https://github.com/libtmux/libtmux-ts/blob/ee5a0312620b4b001b8f0d1144f7ad16193cc933/packages/libtmux/src/_internal/selection/compile.ts).
- Rust revision
  [`07d86c5`](https://github.com/libtmux/libtmux-rs/tree/07d86c59e3f88cecf8da0f46410a29db0496b2dc):
  [wire parser](https://github.com/libtmux/libtmux-rs/blob/07d86c59e3f88cecf8da0f46410a29db0496b2dc/crates/libtmux/src/query/serde_v1.rs),
  [grammar](https://github.com/libtmux/libtmux-rs/blob/07d86c59e3f88cecf8da0f46410a29db0496b2dc/crates/libtmux/src/query/grammar.rs),
  [evaluation](https://github.com/libtmux/libtmux-rs/blob/07d86c59e3f88cecf8da0f46410a29db0496b2dc/crates/libtmux/src/query/matching.rs).
