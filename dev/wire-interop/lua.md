# Lua producers for Julia criteria

Lua callers can author the Julia-owned criteria document and submit it to
`read_where_json`, or submit the parsed document as MCP `list_panes`'s `where`
argument.
The named consumer profile is `julia-owned-from-lua/v1`. It uses the existing
`libtmux.julia.where` version 1 envelope; it adds no production translator,
predicate evaluator, or Lua runtime dependency to Julia.

[lua-producer.lua](lua-producer.lua) emits a complete pane criterion whose
`active` value is false. It needs only an explicit lunajson codec. The
differential check verifies its output against the same criterion evaluated
by both libraries.

The Lua library's `query.encode_json` emits its own two-key envelope,
`version` and `where`. Julia requires four keys: `schema`, integer `version`,
`entity`, and `where`. Both native decoders refuse the other's envelope.
Do not pass Lua-native JSON to `read_where_json` or infer compatibility from
the version labels. Author Julia field IDs and operators directly, as the
producer example does.

## Verified meanings

[lua-fixtures.json](lua-fixtures.json) pairs 27 native Lua criteria with
explicit Julia documents and expected ordered records. It covers all nine
pane fields in the existing scalar intersection: `id`, `index`, `active`,
`dead`, `width`, `height`, `current_command`, `current_path`, and `title`.
It also covers physical pane `window`, window `panes`, contextual window
`windowlinks` (Lua `window_links`), link `session`, and nullable client
`session`. Window names and link indices preserve correlation: conditions
inside one quantified link refer to that same link.

The paired criteria exercise equality, inequality, membership and exclusion,
finite numeric ordering, case-sensitive literal text, empty and nonempty
Boolean composition, to-one relations, and to-many any/all/none. Lua spellings
such as `none_of`, `is_not`, and multiple operator terms correspond to
explicit Julia nodes in the corpus. No runtime conversion API is provided.

False remains a value. JSON null represents captured nullable absence;
uncaptured data raises an error before matching, including in branches which
would otherwise short-circuit. Empty any/membership is false, empty all is
true, and any/all/none over an empty relation is false/true/true. Filtering
preserves source order and repeated records.

With lunajson 1.2.3, tag an authored empty array as `{ [0] = 0 }`; an empty
object is `{}`. Julia node `args`, `fields`, and membership `values` require
arrays. Supply an explicit null sentinel to `json.encode(document, null)`
when authoring nullable operands; Lua `nil` removes a key and cannot encode
an explicit JSON null. Array tags belong to codec-owned data, not native
Lua criteria passed to `query.compile`.

## Limits and exclusions

Integer equality and membership operands use integral JSON tokens within
+/-9007199254740991. Numeric ordering also admits finite fractional
thresholds. Lua's native generic `number` fields accept fractional equality;
Julia's integer fields refuse it. Wide native Julia integers are not portable
wire values. IDs must follow Julia's canonical typed ID grammar.
Check authored operands against both bounds directly. Lua 5.5.1's
`math.abs(math.mininteger)` remains negative; the pinned Lua-native range guard
therefore admits that oversized integer. Its encoder then emits a number
which its own decoder refuses. Julia refuses the oversized operand.

The producer proof covers finite Lua values encoded by the pinned codec.
It does not claim identical acceptance of arbitrary JSON text: Lua's SAX
boundary refuses a nonzero token underflowing to zero, while JSON 1.9.0 with
Julia accepts `1e-999` as zero. Both native boundaries reject duplicate keys,
wrong container kinds, unknown criteria and nonnullable nulls. Ordinary
out-of-range operands are refused, with the Lua minimum-integer exception
above. Their error codes and paths remain port-specific.

Lua selections share mutable records; a compiled query observes later record
mutations. Julia selections retain immutable captured observations and
snapshot provenance. This check transfers criteria only. It does not transfer
snapshots, authenticate Lua relationship completeness, or establish equivalent
live tmux acquisition, daemon identity, cancellation, or MCP transport.

Case folding, regex, callbacks, invalid UTF-8, additional fields and relation
aliases remain outside this profile. In particular, Lua lacks Julia's session
`windows` relation, and its nonnullable TTY field preserves empty strings where
Julia can capture absence. The profile does not silently extend to those cases.

## Reproduce

Prepare dependencies outside timed loops. Use Python 3.12+, explicit Lua
5.5.1, a clean Lua checkout containing the pinned revision below, and an
external Julia environment with this core package and JSON 1.9.0. Preparation
archives the pinned Lua source without modifying either reference checkout.

Clone the official pinned codec into an owned temporary directory:

```console
$ codec_root=$(mktemp -d) && git clone \
    --branch 1.2.3 \
    --single-branch \
    --depth 1 \
    https://github.com/grafi-tt/lunajson.git "$codec_root"
```

Prepare an external Julia codec environment from the Julia repository root:

```console
$ lua_wire_project=$(mktemp -d) && julia \
    --startup-file=no \
    --project="$lua_wire_project" \
    -e 'using Pkg; Pkg.develop(path=pwd());
        Pkg.add(name="JSON", version="1.9.0")'
```

Select the installed Lua executable from `PATH`, or assign `lua_bin` to
another executable:

```console
$ lua_bin=$(command -v lua)
```

Prepare the isolated driver; this also warms the Julia imports before the
timed check:

```console
$ lua_wire_stage=$(python3 dev/wire-interop/check-lua.py prepare \
    --lua-root ../libtmux-lua \
    --codec-root "$codec_root" \
    --lua "$lua_bin" \
    --julia-project "$lua_wire_project" | jq -r .stage)
```

Run the offline differential check, including both native decoders and
evaluators, native round trips, envelope refusals, and the authored example:

```console
$ python3 dev/wire-interop/check-lua.py check "$lua_wire_stage"
```

The stage receipt records runtime versions, result IDs and error paths. The
driver refuses changed harness, criteria, or pinned runtime sources; prepare
a new stage after relevant source edits. No tmux server is started.

Emit the standalone producer document with only the consumer codec:

```console
$ LUA_PATH="$codec_root/src/?.lua" "$lua_bin" dev/wire-interop/lua-producer.lua
```

Remove only the temporary directories created above when finished:

```console
$ rm -rf -- "$lua_wire_stage" "$lua_wire_project" "$codec_root"
```

## Pinned primary sources

- Lua `c98a000354d7cef8e1db5160c3a700110896e509`:
  [query contract](https://github.com/libtmux/libtmux-lua/blob/c98a000354d7cef8e1db5160c3a700110896e509/docs/query.md),
  [wire codec](https://github.com/libtmux/libtmux-lua/blob/c98a000354d7cef8e1db5160c3a700110896e509/lua/libtmux/_internal/query_wire.lua),
  [native evaluation](https://github.com/libtmux/libtmux-lua/blob/c98a000354d7cef8e1db5160c3a700110896e509/lua/libtmux/_internal/query.lua).
- lunajson 1.2.3 `250afac121df831f449d6370ddf406673f6f9c2b`:
  [official codec and SAX API](https://github.com/grafi-tt/lunajson/tree/250afac121df831f449d6370ddf406673f6f9c2b).
