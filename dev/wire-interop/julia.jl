using LibTmux, TOML

root, input_file, output_file = ARGS
isdefined(LibTmux, :decode_typescript_where) ||
    Base.include(LibTmux, joinpath(root, "src", "sibling_wire.jl"))
data = TOML.parsefile(input_file)
identity = ServerIdentity(socket_path="/tmp/libtmux-wire-fixture", generation="fixture")
records = [
    (
        id=p["pane_id"],
        window_id="@1",
        active=p["pane_active"],
        dead=p["pane_dead"],
        index=p["pane_index"],
        width=p["pane_width"],
        height=p["pane_height"],
        current_command=p["pane_current_command"],
        current_path=p["pane_current_path"],
        title=p["pane_title"],
    ) for p in data["panes"]
]
snap = LibTmux._build_snapshot(
    identity;
    acquired=(1, 2),
    complete=true,
    sessions=[(id="\$0", name="fixture")],
    windows=[(id="@1", name="fixture")],
    panes=records,
    windowlinks=[(session_id="\$0", window_id="@1", index=0)],
)
cases = Dict{String,Any}[]
for fixture in data["valid"]
    left = LibTmux.decode_typescript_where(fixture["typescript"])
    right = LibTmux.decode_rust_where(fixture["rust"])
    for criterion in (left, right)
        selected = [string(p.id) for p in filter(criterion, panes(snap))]
        selected == fixture["expected"] || error("Julia mismatch in " * fixture["id"])
    end
    push!(
        cases,
        Dict(
            "id"=>fixture["id"],
            "expected"=>fixture["expected"],
            "typescript"=>LibTmux.encode_typescript_where(right),
            "rust"=>LibTmux.encode_rust_where(left),
        ),
    )
end
for fixture in data["invalid"]
    for (name, decode) in (
        ("typescript", LibTmux.decode_typescript_where),
        ("rust", LibTmux.decode_rust_where),
    )
        failure = try
            decode(fixture[name])
        catch error
            error
        end
        failure isa LibTmux.UnsupportedCriterion || error("Julia accepted " * fixture["id"])
    end
end
open(output_file, "w") do io
    TOML.print(io, Dict("panes"=>data["panes"], "valid"=>cases, "invalid"=>data["invalid"]))
end
