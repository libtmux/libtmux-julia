using Test, JSON, SHA
using LibTmux, LibTmuxMCP, LibTmuxWorkspace, Tables

const ROOT = pkgdir(LibTmux)
const ARTIFACT = isempty(ARGS) ? joinpath(@__DIR__, "build", "api.json") : only(ARGS)
const DATA = JSON.parsefile(ARTIFACT)

function own_method(method, files)
    file = replace(relpath(String(method.file), ROOT), '\\'=>'/')
    file in files
end

function check_method_inventory(data)
    files = Set(item["path"] for item in data["source"]["files"])
    modules = Dict(
        "LibTmux"=>LibTmux,
        "LibTmux.Filters"=>LibTmux.Filters,
        "LibTmuxMCP"=>LibTmuxMCP,
        "LibTmuxWorkspace"=>LibTmuxWorkspace,
        "Base"=>Base,
        "Tables"=>Tables,
        "ModelContextProtocol"=>LibTmuxMCP.SDK,
    )
    for symbol in [data["symbols"]; data["extensionMethods"]]
        mod = get(modules, symbol["module"], nothing)
        isnothing(mod) && error("Unverified API owner: $(symbol["module"])")
        value = getfield(mod, Symbol(symbol["name"]))
        value isa Function || value isa Type || continue
        expected = Set(
            sprint(show, method.sig; context=:module=>Core) for
            method in methods(value) if own_method(method, files)
        )
        actual = Set(method["identity"] for method in symbol["methods"])
        (value isa Function ? expected == actual : issubset(expected, actual)) ||
            error("Native method inventory differs for $(symbol["id"])")
    end
end

symbol(id) = only(filter(s->s["id"] == id, DATA["symbols"]))

function check_specialized_methods(data)
    files = Set(item["path"] for item in data["source"]["files"])
    all_symbols = Dict(s["id"]=>s for s in [data["symbols"]; data["extensionMethods"]])
    # Concrete native queries exercise dispatch surfaces that methods(UnionAll) omits.
    samples = [
        ("LibTmux.Criterion", SessionWhere()),
        ("LibTmux.FormatObservation", FormatObservation{String}),
        ("LibTmux.FormatValueError", FormatValueError{Nothing}),
        ("LibTmux.Selection", Selection{SessionSnapshot}),
        (
            "LibTmux.RowProjection",
            RowProjection{NamedTuple{(:id,),Tuple{SessionID}},Selection{SessionSnapshot}},
        ),
        ("Base.IndexStyle", Base.IndexStyle),
        ("Base.IteratorSize", Base.IteratorSize),
    ]
    for (id, value) in samples
        haskey(all_symbols, id) || error("Missing specialized API: $id")
        expected = Set(
            sprint(show, method.sig; context=:module=>Core) for
            method in methods(value) if own_method(method, files)
        )
        isempty(expected) && error("Empty native regression inventory: $id")
        actual = Set(method["identity"] for method in all_symbols[id]["methods"])
        issubset(expected, actual) || error("Missing specialized methods: $id")
    end
    any(
        s->startswith(s["name"], "#") || s["id"] == "Core.Type",
        data["extensionMethods"],
    ) && error("Runtime method owners leaked into the public extension inventory")
    nothing
end

function check_aliases(data)
    by_id = Dict(s["id"]=>s for s in data["symbols"])
    for entry in values(by_id)
        entry["kind"] == "type" && !isnothing(entry["aliasOf"]) || continue
        haskey(by_id, entry["aliasOf"]) || error("Unresolved alias target: $(entry["id"])")
        definition = entry["definition"]
        isnothing(definition) && error("Missing alias definition: $(entry["id"])")
        source = entry["source"]
        line = readlines(joinpath(ROOT, source["file"]))[source["line"]]
        occursin("const "*entry["name"]*" = "*definition, line) ||
            error("Wrong alias source: $(entry["id"])")
        isempty(entry["typeArguments"]) &&
            error("Missing alias specialization: $(entry["id"])")
    end
end

@testset "Native API export" begin
    @test DATA["schema"] == 1
    @test DATA["port"] == "julia"
    @test DATA["source"]["revision"] == strip(read(`git -C $ROOT rev-parse HEAD`, String))
    @test DATA["exporter"]["sha256"] ==
          bytes2hex(sha256(read(joinpath(@__DIR__, "export-api.jl"))))
    for item in DATA["source"]["files"]
        @test item["sha256"] == bytes2hex(sha256(read(joinpath(ROOT, item["path"]))))
    end
    for mod in [LibTmux, LibTmuxMCP, LibTmuxWorkspace]
        expected = Set(string(mod, '.', name) for name in names(mod) if name != nameof(mod))
        actual = Set(
            s["id"] for
            s in DATA["symbols"] if s["module"] == string(mod) && !s["supporting"]
        )
        @test actual == expected
    end
    @test isnothing(check_method_inventory(DATA))
    @test isnothing(check_specialized_methods(DATA))
    @test isnothing(check_aliases(DATA))
    for entry in DATA["symbols"]
        @test !isnothing(entry["source"])
        @test isfile(joinpath(ROOT, entry["source"]["file"]))
        @test entry["source"]["line"] > 0
    end

    server = symbol("LibTmux.Server")
    @test Set(f["name"] for f in server["fields"]) ==
          Set(["socket_path", "socket_name", "tmux"])
    constructor = only(server["methods"])
    tmux = only(filter(p->p["name"] == "tmux", constructor["parameters"]))
    @test tmux["keyword"] && tmux["default"] == "\"tmux\""

    contains = symbol("LibTmux.Filters.Contains")
    @test contains["qualifiedAccess"] && !contains["exported"]
    case = only(filter(p->p["name"] == "case", only(contains["methods"])["parameters"]))
    @test case["default"] == ":sensitive"
    @test case["type"] == "Symbol"

    kill = symbol("LibTmux.kill_session")
    @test length(kill["methods"]) == 2
    control =
        only(filter(m->occursin("ControlConnection", m["signature"]), kill["methods"]))
    @test any(d->occursin("pinned daemon", d["markdown"]), control["documentation"])
    @test control["source"]["file"] == "src/control_topology.jl"

    @test Set(DATA["extensions"]) == Set(["LibTmuxJSONExt", "LibTmuxTablesExt"])
    @test all(m["requiresExtension"] for m in symbol("LibTmux.read_where_json")["methods"])
    tables = filter(s->startswith(s["id"], "Tables."), DATA["extensionMethods"])
    @test Set(s["id"] for s in tables) ==
          Set(["Tables.rows", "Tables.schema", "Tables.istable", "Tables.rowaccess"])
    @test all(m["requiresExtension"] for s in tables for m in s["methods"])
    @test any(s->s["id"] == "Base.close", DATA["extensionMethods"])
    @test any(!isempty(m["typeParameters"]) for s in DATA["symbols"] for m in s["methods"])
    criterion_call = only(symbol("LibTmux.Criterion")["methods"])
    @test criterion_call["kind"] == "call"
    @test criterion_call["receiver"] == Dict("name"=>"q", "type"=>"LibTmux.Criterion")
    @test symbol("LibTmux.SessionID")["definition"] == "TmuxID{:session}"
    @test symbol("LibTmux.SessionID")["typeArguments"] == [":session"]
    @test symbol("LibTmux.TmuxID")["supporting"]
    # A documented type's in-module supertypes get pages of their own.
    for id in ("LibTmux.EntityID", "LibTmux.EntitySnapshot", "LibTmux._FiniteCommandResult")
        @test symbol(id)["supporting"] && !isempty(symbol(id)["documentation"])
    end

    incomplete = deepcopy(DATA)
    broken = only(filter(s->s["id"] == "LibTmux.kill_session", incomplete["symbols"]))
    filter!(m->!occursin("ControlConnection", m["signature"]), broken["methods"])
    @test_throws "Native method inventory differs for LibTmux.kill_session" check_method_inventory(
        incomplete,
    )
    for id in ["LibTmux.Criterion", "LibTmux.FormatObservation"]
        incomplete = deepcopy(DATA)
        broken = only(filter(s->s["id"] == id, incomplete["symbols"]))
        filter!(
            m->m["kind"] != "call" && !occursin("Vararg", m["identity"]),
            broken["methods"],
        )
        @test_throws "Missing specialized methods: $id" check_specialized_methods(
            incomplete,
        )
    end
    incomplete = deepcopy(DATA)
    filter!(s->s["id"] != "Base.IndexStyle", incomplete["extensionMethods"])
    @test_throws "Missing specialized API: Base.IndexStyle" check_specialized_methods(
        incomplete,
    )
    incomplete = deepcopy(DATA)
    only(filter(s->s["id"] == "LibTmux.SessionID", incomplete["symbols"]))["definition"] =
        nothing
    @test_throws "Missing alias definition: LibTmux.SessionID" check_aliases(incomplete)
end
