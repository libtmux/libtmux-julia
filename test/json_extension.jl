using JSON

@testset "JSON criteria codec rejects ambiguous input before evaluation" begin
    @test isdefined(LibTmux, :read_where_json)
    if isdefined(LibTmux, :read_where_json)
        q = PaneWhere(active=true, current_command=LibTmux.Filters.Contains("vim"))
        encoded = LibTmux.write_where_json(q)
        @test encode_where(LibTmux.read_where_json(encoded)) == encode_where(q)
        duplicate = replace(encoded, "\"version\":1" => "\"version\":1,\"version\":1")
        @test duplicate != encoded
        @test_throws WireCriteriaError LibTmux.read_where_json(duplicate)
        @test_throws WireCriteriaError LibTmux.read_where_json("{} {}")
        @test_throws WireCriteriaError LibTmux.read_where_json("{" * repeat("\"", 20))
        @test_throws WireCriteriaError LibTmux.read_where_json(encoded; max_input_bytes=10)
        @test_throws WireCriteriaError LibTmux.read_where_json(
            encoded;
            limits=WhereLimits(max_nodes=5),
        )
        @test_throws WireCriteriaError LibTmux.read_where_json(repeat("[", 10000))
        @test_throws WireCriteriaError LibTmux.read_where_json(
            "[" * repeat("0,", 10000) * "0]",
        )
        @test_throws WireCriteriaError LibTmux.read_where_json(
            "{\"a\":\"" * repeat("x", 100) * "\"}";
            limits=WhereLimits(max_string_bytes=5),
        )
        @test_throws WireCriteriaError LibTmux.read_where_json(String(UInt8[0xff]))
        escaped_boundary = replace(
            LibTmux.write_where_json(PaneWhere(title=repeat("a", 22))),
            repeat("a", 22) => repeat("\\u0061", 22),
        )
        @test encode_where(
            LibTmux.read_where_json(
                escaped_boundary;
                limits=WhereLimits(max_string_bytes=22),
            ),
        ) == encode_where(PaneWhere(title=repeat("a", 22)))
        for value in ("quote\"\\end", "\u0000tab\tline\n", "é日本")
            criterion = PaneWhere(title=value)
            @test encode_where(
                LibTmux.read_where_json(LibTmux.write_where_json(criterion)),
            ) == encode_where(criterion)
        end
        @test_throws ArgumentError LibTmux.read_where_json(encoded; max_input_bytes=0)

        F = LibTmux.Filters
        snap = LibTmux._build_snapshot(
            ServerIdentity(socket_path="/tmp/libtmux-json-empty", generation="one");
            acquired=(0, 0),
            complete=true,
            windows=[(id="@1",)],
            panes=[(id="%1", window_id="@1", title="literal")],
        )
        for (label, criterion, key, expected) in (
            ("all", F.AllOf(), "args", 1),
            ("any", F.AnyOf(), "args", 0),
            ("membership", PaneWhere(title=F.OneOf(())), "values", 0),
            ("fields", PaneWhere(), "fields", 1),
        )
            @testset "empty $label array" begin
                text = write_where_json(criterion; entity=:pane)
                node = JSON.parse(text)["where"]
                container = key == "values" ? node["fields"][1]["match"][key] : node[key]
                @test container isa Vector
                restored = read_where_json(text)
                @test encode_where(restored; entity=:pane) ==
                      encode_where(criterion; entity=:pane)
                @test count(restored, panes(snap)) == expected
            end
        end
    end
end
