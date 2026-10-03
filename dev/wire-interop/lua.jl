using LibTmux, JSON
F=LibTmux.Filters
identity=ServerIdentity(socket_path="/tmp/libtmux-lua-wire", generation="inert")
function fixture()
    LibTmux._build_snapshot(
        identity;
        acquired=(0, 0),
        complete=true,
        sessions=[
            (id="\$0", name="dev", attached_clients=0),
            (id="\$1", name="ops", attached_clients=1),
        ],
        windows=[
            (id="@1", name="API", width=120, height=30),
            (id="@2", name="build", width=80, height=24),
            (id="@3", name="empty", width=80, height=24),
        ],
        panes=[
            (
                id="%1",
                window_id="@1",
                index=0,
                active=true,
                dead=false,
                width=120,
                height=30,
                current_command="nvim",
                current_path="/app",
                title="λ\0雪 #{pane_id}.*",
            ),
            (
                id="%2",
                window_id="@1",
                index=1,
                active=false,
                dead=true,
                width=120,
                height=30,
                current_command=nothing,
                current_path=nothing,
                title="shell",
            ),
            (
                id="%3",
                window_id="@2",
                index=0,
                active=true,
                dead=false,
                width=80,
                height=24,
                current_command="julia",
                current_path="/work",
                title="build",
            ),
        ],
        windowlinks=[
            (session_id="\$0", window_id="@1", index=0, active=true),
            (session_id="\$0", window_id="@2", index=1, active=false),
            (session_id="\$1", window_id="@1", index=4, active=true),
        ],
        clients=[(
            id=ClientID("client", "first"),
            name="client",
            pid=100,
            created=1,
            session_id=nothing,
        )],
    )
end
snap=fixture()
sources=Dict(
    "pane"=>panes(snap),
    "window"=>windows(snap),
    "session"=>sessions(snap),
    "window_link"=>windowlinks(snap),
    "client"=>clients(snap),
)
@assert realpath(dirname(dirname(pathof(LibTmux)))) == realpath(ARGS[3])
corpus=JSON.parsefile(ARGS[1])["valid"];
produced=JSON.parsefile(ARGS[2]);
results=Any[]
emit(name, status, detail) = push!(results, (; name, status, detail))
function rejected(name, text, code)
    err=try
        read_where_json(text)
        nothing
    catch e
        e
    end
    @assert err isa WireCriteriaError
    @assert err.code===code (name, err)
    emit(name, "refused", string(err.code, ":", err.path))
end
ids(rows) = [string(x.id) for x in rows]
for (case, document) in zip(corpus, produced)
    @assert case["name"]==document["name"]
    q=read_where_json(document["julia_json"])
    items=sources[case["entity"]]
    actual=ids(filter(q, items))
    @assert actual==case["expected"] (case["name"], actual, case["expected"])
    encoded=write_where_json(q; entity=Symbol(case["julia"]["entity"]))
    restored=read_where_json(encoded)
    @assert ids(filter(restored, items))==actual
    @assert encode_where(restored; entity=Symbol(case["julia"]["entity"]))==case["julia"]
    rejected("lua-envelope-"*case["name"], document["lua_json"], :shape)
    emit(case["name"], "accepted", actual)
end
base=encode_where(PaneWhere(active=false))
function wire_node(node; entity="pane")
    JSON.json(
        Dict(
            "schema"=>"libtmux.julia.where",
            "version"=>1,
            "entity"=>entity,
            "where"=>node,
        ),
    )
end
function field(name, op, val)
    Dict(
        "op"=>"fields",
        "fields"=>[Dict("field"=>"tmux.pane."*name, "match"=>Dict("op"=>op, "value"=>val))],
    )
end
rejected("object-in-args", wire_node(Dict("op"=>"all", "args"=>Dict())), :type)
rejected("array-in-node", wire_node([]), :type)
rejected(
    "object-in-membership",
    wire_node(
        Dict(
            "op"=>"fields",
            "fields"=>[
                Dict(
                    "field"=>"tmux.pane.title",
                    "match"=>Dict("op"=>"in", "values"=>Dict()),
                ),
            ],
        ),
    ),
    :type,
)
rejected(
    "duplicate-field",
    replace(
        JSON.json(base),
        "\"schema\":\"libtmux.julia.where\""=>"\"schema\":\"libtmux.julia.where\",\"schema\":\"libtmux.julia.where\"",
    ),
    :duplicate,
)
rejected(
    "escaped-duplicate-field",
    replace(
        JSON.json(base),
        "\"schema\":\"libtmux.julia.where\""=>"\"schema\":\"libtmux.julia.where\",\"\\u0073chema\":\"libtmux.julia.where\"",
    ),
    :duplicate,
)
rejected("unknown-field", wire_node(field("missing", "eq", 1)), :field)
rejected("boolean-wrong-type", wire_node(field("active", "eq", 0)), :value)
rejected("nonnullable-null", wire_node(field("active", "eq", nothing)), :value)
rejected("wide-integer", wire_node(field("width", "eq", 9007199254740992)), :value)
rejected(
    "minimum-integer-overflow",
    wire_node(field("width", "eq", typemin(Int64))),
    :value,
)
rejected("fractional-equality", wire_node(field("width", "eq", 1.5)), :value)
rejected("floating-integral-equality", wire_node(field("width", "eq", 1.0)), :value)
rejected("unsupported-code", wire_node(Dict("op"=>"eval", "code"=>"run()")), :unsupported)
# JSON.jl accepts a lexical underflow token which Lua's SAX boundary refuses.
underflow=replace(wire_node(field("width", "gt", 1.0)), "\"value\":1.0"=>"\"value\":1e-999")
q=read_where_json(underflow);
@assert count(q, panes(snap))==3;
emit("underflow-token", "accepted-native-only", underflow)
missing=LibTmux._build_snapshot(
    identity;
    acquired=(0, 0),
    complete=true,
    windows=[(id="@1",)],
    panes=[(id="%9", window_id="@1", active=false)],
)
err=try
    filter(
        F.AnyOf(PaneWhere(active=false), PaneWhere(current_command=nothing)),
        panes(missing),
    )
    nothing
catch e
    e
end
@assert err isa SnapshotCoverageError;
emit("uncaptured-short-circuit", "refused", sprint(showerror, err))
partial=LibTmux._build_snapshot(
    identity;
    acquired=(0, 0),
    windows=[(id="@1", name="partial")],
    complete=(:windows,),
)
err=try
    filter(
        F.AnyOf(WindowWhere(name="partial"), WindowWhere(panes=F.AllRelated(PaneWhere()))),
        windows(partial),
    )
    nothing
catch e
    e
end
@assert err isa SnapshotCoverageError;
emit("uncaptured-relationship", "refused", sprint(showerror, err))
ps=panes(snap);
repeated=Selection([ps[1], ps[1], ps[3]]; snapshot=snap);
@assert ids(filter(PaneWhere(active=true), repeated))==["%1", "%1", "%3"]
emit("order-duplicates-provenance", "accepted", ids(repeated))
@assert snapshotof(repeated)===snap
err=try
    setproperty!(ps[1], :active, false)
    nothing
catch e
    e
end
@assert err!==nothing;
emit("immutable-captured-view", "native-limit", string(typeof(err)))
println(
    JSON.json((;
        profile="julia-owned-from-lua/v1",
        runtime=string(VERSION),
        json_version=string(Base.pkgversion(JSON)),
        valid_cases=length(corpus),
        records=results,
    )),
)
