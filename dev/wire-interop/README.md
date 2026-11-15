# Criteria wire interoperability

The explicitly named Julia adapters translate a verified pane-scalar subset
between two existing version-1 envelopes. The Julia-owned `encode_where`
profile remains separate.

Lua callers can author Julia-owned criteria directly; the
[Lua producer record](lua.md) describes that profile. It does not translate the
Lua library's own envelope.

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

## Fixtures

[fixtures.toml](fixtures.toml) holds three captured pane rows, 16 valid
criteria and six invalid documents. Every available field has a concrete
value. [test/sibling_wire.jl](../../test/sibling_wire.jl) reads it. For each
valid criterion it decodes the TypeScript and Rust forms, checks the selected
pane IDs, encodes them again and checks the IDs of the round trip. Each invalid
document must raise `UnsupportedCriterion`. Absent, unavailable and uncaptured
graph states are outside this subset. No tmux server is needed.

The subset follows the TypeScript and Rust sources pinned below. This
repository runs neither library.

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
