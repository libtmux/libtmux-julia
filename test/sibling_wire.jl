using TOML

function sibling_wire_fixture()
    data = TOML.parsefile(joinpath(@__DIR__, "..", "dev", "wire-interop", "fixtures.toml"))
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
    snapshot = LibTmux._build_snapshot(
        identity;
        acquired=(1, 2),
        complete=true,
        sessions=[(id="\$0", name="fixture")],
        windows=[(id="@1", name="fixture")],
        panes=records,
        windowlinks=[(session_id="\$0", window_id="@1", index=0)],
    )
    data, panes(snapshot)
end

@testset "explicit sibling wire adapters" begin
    @test isdefined(LibTmux, :decode_typescript_where)
    @test isdefined(LibTmux, :decode_rust_where)
    if isdefined(LibTmux, :decode_typescript_where) &&
       isdefined(LibTmux, :decode_rust_where)
        data, items = sibling_wire_fixture()
        selected(q) = [string(p.id) for p in filter(q, items)]
        for (profile, decode, encode) in (
            (
                "typescript",
                LibTmux.decode_typescript_where,
                LibTmux.encode_typescript_where,
            ),
            ("rust", LibTmux.decode_rust_where, LibTmux.encode_rust_where),
        )
            for fixture in data["valid"]
                criterion = decode(fixture[profile])
                @test selected(criterion) == fixture["expected"]
                @test selected(decode(encode(criterion))) == fixture["expected"]
            end
            for fixture in data["invalid"]
                @test_throws LibTmux.UnsupportedCriterion decode(fixture[profile])
            end
            for criterion in (
                PaneWhere(),
                PaneWhere(current_command=nothing),
                PaneWhere(title=LibTmux.Filters.Contains("a"; case=:ascii_insensitive)),
                PaneWhere(width=LibTmux.Filters.AtLeast(10)),
                PaneWhere(window=WindowWhere(name="x")),
                SessionWhere(name="x"),
                PaneWhere(width=Int64(typemax(UInt32)) + 1),
            )
                @test_throws LibTmux.UnsupportedCriterion encode(criterion)
            end
            basic = first(data["valid"])[profile]
            @test_throws WireCriteriaError decode(basic; limits=WhereLimits(max_depth=2))
            @test_throws WireCriteriaError decode(basic; limits=WhereLimits(max_nodes=5))
            @test_throws WireCriteriaError encode(
                PaneWhere(title="large");
                limits=WhereLimits(max_string_bytes=2),
            )
            duplicate = LibTmux.WireObject([collect(pairs(basic)); "version"=>1])
            @test_throws WireCriteriaError decode(duplicate)
            deep = PaneWhere(active=true)
            for _ = 1:200
                deep = LibTmux.Filters.Not(deep)
            end
            @test_throws WireCriteriaError encode(deep)
            not_equal = PaneWhere(active=LibTmux.Filters.NotEqualTo(true))
            @test selected(decode(encode(not_equal))) == ["%2"]
        end
        raw = Dict(
            "version"=>1,
            "model"=>"pane",
            "where" => Dict("pane_current_command"=>Dict("in"=>["nvim"])),
        )
        copied = LibTmux.decode_typescript_where(raw)
        push!(raw["where"]["pane_current_command"]["in"], "julia")
        @test selected(copied) == ["%1"]
        @test LibTmux.encode_typescript_where(PaneWhere(active=true)) ==
              Dict("version"=>1, "model"=>"pane", "where"=>Dict("pane_active"=>"1"))
        @test LibTmux.encode_rust_where(PaneWhere(active=true)) == Dict(
            "version"=>1,
            "target"=>"pane",
            "expr"=>Dict("op"=>"eq", "field"=>"pane_active", "value"=>true),
        )
        @test_throws LibTmux.UnsupportedCriterion LibTmux.decode_typescript_where(
            Dict("version"=>1, "model"=>"pane", "where"=>Dict("pane_title"=>nothing)),
        )
        @test_throws LibTmux.UnsupportedCriterion LibTmux.decode_rust_where(
            Dict(
                "version"=>1,
                "target"=>"pane",
                "expr"=>Dict("op"=>"eq", "field"=>"pane_title", "value"=>nothing),
            ),
        )
        cycle = Dict{String,Any}()
        cycle["NOT"] = [cycle]
        @test_throws WireCriteriaError LibTmux.decode_typescript_where(
            Dict("version"=>1, "model"=>"pane", "where"=>cycle),
        )
    end
end
