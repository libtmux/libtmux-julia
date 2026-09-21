# Portable criteria

`encode_where` exports built-in criteria as inert data. `decode_where`
validates that data and returns a callable local predicate. Neither function
contacts tmux. Keep ordinary closures and native regular expressions in local
Julia predicates.

The core has no JSON dependency. Objects use string keys; arrays use vectors.
External decoders must preserve duplicate keys with `WireObject`, or reject
them before constructing a `Dict`. Duplicates already discarded by a codec
cannot be detected afterward.

```jldoctest
julia> using LibTmux

julia> import LibTmux.Filters as F

julia> rule = PaneWhere(active=true, width=F.AtLeast(100));

julia> document = encode_where(rule);

julia> restored = decode_where(document);

julia> encode_where(restored) == document
true
```

## Version 1 profile

The envelope contains exactly four keys:

| Key | Value |
| --- | --- |
| `schema` | `libtmux.julia.where` |
| `version` | Integer `1`, not Boolean or floating point |
| `entity` | `pane`, `window`, `session`, `client`, or `windowlink` |
| `where` | One predicate node |

This is a Julia-owned profile. Existing TypeScript and Rust envelopes have
different structures and semantics. Named sibling adapters cover only the
verified pane-scalar subset described below. A local round trip does not
establish cross-port compatibility.

| Predicate | Exact keys and meaning |
| --- | --- |
| `fields` | `op`, `fields`; array of field constraints, implicitly conjoined |
| `all` | `op`, `args`; array of predicates, all must match |
| `any` | `op`, `args`; array of predicates, at least one must match |
| `not` | `op`, `arg`; negate one predicate |

A field constraint contains exactly `field` and `match`. `field` is a stable
identity such as `tmux.pane.current_command`, listed in the
[generated field reference](generated/criteria.md). It is distinct from a
Julia property name or tmux format token. Constraining the same field twice
in one `fields` node errors; use `all` for multiple constraints on one field.

| Match operator | Additional keys |
| --- | --- |
| `eq`, `ne`, `ge`, `le`, `gt`, `lt` | `value` |
| `in` | `values`, an array of scalar operands |
| `contains`, `startsWith`, `endsWith` | `value` string and `case` |
| `is` | `where`, a predicate on a to-one related entity |
| `anyRelated`, `allRelated`, `noRelated` | `where`, a predicate on a to-many related entity |

Every match also contains `op`. Unknown or extra keys error. Text case is
`sensitive` or `ascii_insensitive`. Relation targets come from the field
catalog, so nested nodes cannot silently change their entity. Empty
`anyRelated`/`allRelated`/`noRelated` results are false/true/true. Coverage is
checked before predicate evaluation, as with locally constructed criteria.

```json
{
  "schema": "libtmux.julia.where",
  "version": 1,
  "entity": "pane",
  "where": {
    "op": "fields",
    "fields": [
      {
        "field": "tmux.pane.active",
        "match": {"op": "eq", "value": true}
      }
    ]
  }
}
```

Entity IDs encode as strings in the appropriate typed field. A client ID
encodes as an object containing `name` and `incarnation`. `null` means
captured absence only where the catalog permits it; an omitted constraint
means unconstrained. Missing observations still raise a coverage error.

Integer operands must remain within +/-9007199254740991, the exact numeric
range shared with JSON consumers that use binary64 numbers. Integer equality
fields reject floating-point values, including `1.0`. Numeric comparison
thresholds also accept finite floating-point numbers. Unsupported Julia
numeric types error instead of silently losing precision.

## Input limits and ownership

`WhereLimits` bounds depth, node count, individual strings, collection size,
and total string bytes before criteria construction. The defaults are 32
levels, 4096 nodes, 65536 bytes per string, 1024 items per array/object, and
1048576 string bytes in total. Keys count as strings and nodes. Cyclic input
fails the depth bound. Limits do not bound later snapshot traversal.

Validation returns `WireCriteriaError` with a code, structural path, and
message. Schema/version mismatches, unknown fields, duplicate keys or fields,
invalid types, and exceeded limits remain distinct failures. Encoding an
empty `AllOf` or `AnyOf` requires an explicit `entity` keyword.

Decoded criteria retain their own immutable operands. Mutating the input
objects or arrays afterward does not change a decoded predicate. The wire
contains no executable Julia expressions, serialized objects, callbacks, or
compiled regular expressions.

## Optional JSON codec

Install and load `JSON` 1.9 or later to enable the package extension. Its
strict duplicate-key mode is required; earlier JSON versions are not admitted.
The codec checks input size, nesting, and token bounds before materializing
JSON, then applies the complete criteria validator. The default input cap is
8 MiB. No file or stream is read implicitly.

```jldoctest
julia> using LibTmux, JSON

julia> encoded = write_where_json(PaneWhere(active=true));

julia> restored = read_where_json(encoded);

julia> encode_where(restored) == encode_where(PaneWhere(active=true))
true
```

The optional codec uses the documented
[`JSON.parse` interface](https://juliaio.github.io/JSON.jl/stable/) with
`duplicate_keys=:error`. Core imports do not load JSON or its dependencies.


## TypeScript and Rust adapters

Use `encode_typescript_where` / `decode_typescript_where` for TypeScript v1,
and `encode_rust_where` / `decode_rust_where` for Rust v1. Each validates its
own envelope; neither silently interprets the Julia envelope as a sibling
format. `UnsupportedCriterion` identifies meanings outside the admitted
intersection.

The supported intersection is pane scalar equality, membership,
case-sensitive text, and nonempty Boolean composition. Relations, null
values, case folding, and numeric ordering are refused. Read the exact field
and scalar restrictions in the [interoperability record](../dev/wire-interop/README.md).
Its pinned executables test both valid and invalid fixtures through two rounds
of parsing, evaluation, and canonical re-encoding. Rust evaluates derived
captured scalar rows after validating its actual pane grammar; this does not
claim equivalent live snapshot acquisition across ports.
