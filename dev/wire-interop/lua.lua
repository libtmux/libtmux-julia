local query = require("libtmux.query")
local graph = require("libtmux._internal.graph")
local json = require("lunajson")
local schemas = graph.schemas("3.7c")
local NULL = query.NULL
local file = assert(io.open(arg[1], "rb"))
local corpus = json.decode(file:read("*a"), 1, NULL).valid
file:close()
local sessions =
    { { id = "$0", name = "dev", attached = 0 }, { id = "$1", name = "ops", attached = 1 } }
local windows = {
    { id = "@1", name = "API", width = 120, height = 30 },
    { id = "@2", name = "build", width = 80, height = 24 },
    { id = "@3", name = "empty", width = 80, height = 24 },
}
local panes = {
    {
        id = "%1",
        index = 0,
        active = true,
        dead = false,
        width = 120,
        height = 30,
        current_command = "nvim",
        current_path = "/app",
        title = "λ\000雪 #{pane_id}.*",
        window = windows[1],
    },
    {
        id = "%2",
        index = 1,
        active = false,
        dead = true,
        width = 120,
        height = 30,
        current_command = NULL,
        current_path = NULL,
        title = "shell",
        window = windows[1],
    },
    {
        id = "%3",
        index = 0,
        active = true,
        dead = false,
        width = 80,
        height = 24,
        current_command = "julia",
        current_path = "/work",
        title = "build",
        window = windows[2],
    },
}
local links = {
    { index = 0, active = true, session = sessions[1], window = windows[1] },
    { index = 1, active = false, session = sessions[1], window = windows[2] },
    { index = 4, active = true, session = sessions[2], window = windows[1] },
}
sessions[1].window_links = { links[1], links[2] }
sessions[2].window_links = { links[3] }
windows[1].window_links = { links[1], links[3] }
windows[2].window_links = { links[2] }
windows[3].window_links = {}
windows[1].panes = { panes[1], panes[2] }
windows[2].panes = { panes[3] }
windows[3].panes = {}
local sources = {
    pane = panes,
    window = windows,
    session = sessions,
    window_link = links,
    client = { { name = "client", pid = 100, created = 1, session = NULL } },
}
local results = {}
local function eq(a, b)
    assert(#a == #b)
    for i, x in ipairs(a) do
        assert(x == b[i], tostring(x) .. "!=" .. tostring(b[i]))
    end
end
local function ids(rows)
    local a = {}
    for _, r in ipairs(rows) do
        a[#a + 1] = r.id or r.name
    end
    a[0] = #a
    return a
end
local function emit(label, status, detail)
    results[#results + 1] = { name = label, status = status, detail = detail }
end
local function reject(label, text, code, schema)
    local q, e = query.decode_json(schema or schemas.pane, text, json)
    assert(q == nil and e.code == code, label .. ":" .. tostring(e))
    emit(label, "refused", e.code .. ":" .. e.path)
end
local function lua_wire(s)
    return '{"version":"libtmux.where/v1","where":' .. s .. "}"
end
-- Tag only the Julia grammar's known arrays in fresh codec-owned copies.
local function copy(value, key)
    if rawequal(value, NULL) or type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = copy(v, k)
    end
    if key == "args" or key == "fields" or key == "values" then
        out[0] = #value
    end
    return out
end
local produced = {}
for _, case in ipairs(corpus) do
    local schema = schemas[case.entity]
    local authored = assert(query.encode_json(schema, case.lua, json))
    local native = assert(query.decode_json(schema, authored, json))
    local selected = query.where(sources[case.entity], native, schema)
    eq(ids(selected), case.expected)
    local encoded = assert(query.encode_json(schema, native, json))
    local restored = assert(query.decode_json(schema, encoded, json))
    eq(ids(query.where(sources[case.entity], restored, schema)), case.expected)
    local julia = json.encode(copy(case.julia), NULL)
    local refused, err = query.decode_json(schema, julia, json)
    assert(refused == nil and err.code == "invalid_wire")
    produced[#produced + 1] = {
        name = case.name,
        entity = case.entity,
        julia_json = julia,
        lua_json = encoded,
        ids = ids(selected),
    }
    emit(case.name, "accepted", ids(selected))
end
reject("julia-envelope", produced[1].julia_json, "invalid_wire")
reject("object-in-AND", lua_wire('{"AND":{}}'), "invalid_wire")
reject("array-in-criteria", lua_wire("[]"), "invalid_wire")
reject("object-in-membership", lua_wire('{"title":{"one_of":{}}}'), "invalid_wire")
reject("duplicate-field", lua_wire('{"active":true,"active":false}'), "invalid_json")
reject(
    "escaped-duplicate-field",
    lua_wire('{"active":true,"\\u0061ctive":false}'),
    "invalid_json"
)
reject("unknown-field", lua_wire('{"missing":1}'), "invalid_criteria")
reject("boolean-wrong-type", lua_wire('{"active":0}'), "invalid_criteria")
reject("nonnullable-null", lua_wire('{"active":null}'), "invalid_criteria")
reject("wide-integer", lua_wire('{"width":9007199254740992}'), "invalid_json")
reject("underflow-token", lua_wire('{"width":{"gt":1e-999}}'), "invalid_json")
reject("unsupported-code", lua_wire('{"eval":"os.execute()"}'), "invalid_criteria")
reject("native-regex", lua_wire('{"title":{"regex":".*"}}'), "invalid_criteria")
reject(
    "case-policy",
    lua_wire('{"title":{"contains":"x","case":"ascii_insensitive"}}'),
    "invalid_criteria"
)
local fractional = assert(query.decode_json(schemas.pane, lua_wire('{"width":1.5}'), json))
emit("fractional-equality", "accepted-native-only", fractional.width)
local minimum = assert(
    query.decode_json(schemas.pane, lua_wire('{"width":-9223372036854775808}'), json)
)
assert(minimum.width == math.mininteger and math.abs(minimum.width) < 0)
local oversized = assert(query.encode_json(schemas.pane, { width = minimum.width }, json))
local lost, range_error = query.decode_json(schemas.pane, oversized, json)
assert(lost == nil and range_error.code == "invalid_json")
emit("minimum-integer-overflow", "accepted-native-only", oversized)
local absent = { id = "%9", active = false }
local q = assert(
    query.compile(schemas.pane, { OR = { { active = false }, { current_command = NULL } } })
)
local ok, e = pcall(query.where, { absent }, q)
assert(not ok and e.code == "unloaded_field")
emit("uncaptured-short-circuit", "refused", e.code .. ":" .. e.path)
local partial = { id = "@9", name = "partial" }
q = assert(
    query.compile(
        schemas.window,
        { OR = { { name = "partial" }, { panes = { every = {} } } } }
    )
)
ok, e = pcall(query.where, { partial }, q)
assert(not ok and e.code == "unloaded_field")
emit("uncaptured-relationship", "refused", e.code .. ":" .. e.path)
local repeated =
    query.select({ panes[1], panes[1], panes[3] }, schemas.pane):where({ active = true })
eq(ids(repeated), { "%1", "%1", "%3" })
assert(rawequal(repeated[1], panes[1]))
emit("order-duplicates-shared-record", "accepted", ids(repeated))
local compiled = assert(query.compile(schemas.pane, { active = true }))
local before = #query.where(panes, compiled)
panes[1].active = false
local after = #query.where(panes, compiled)
assert(before == 2 and after == 1)
panes[1].active = true
emit("mutable-records", "native-limit", { before, after })
local nilcodec, err = query.encode_json(schemas.pane, { active = false }, nil)
assert(nilcodec == nil and err.code == "invalid_codec")
emit("explicit-codec-required", "refused", err.code)
local out = assert(io.open(arg[2], "wb"))
out:write(json.encode(produced))
out:close()
print(json.encode({
    profile = "julia-owned-from-lua/v1",
    runtime = _VERSION,
    valid_cases = #corpus,
    records = results,
}))
