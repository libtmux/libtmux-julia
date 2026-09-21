@testset "inert criteria preserve typed local meaning" begin
    @test isdefined(LibTmux, :encode_where)
    if isdefined(LibTmux, :encode_where)
        F = LibTmux.Filters
        snap = criteria_fixture()
        queries = (
            PaneWhere(active=true, current_command=F.OneOf(("nvim", "vim"))),
            PaneWhere(id=PaneID("%1"), width=F.AtLeast(99.5)),
            PaneWhere(current_command=nothing),
            PaneWhere(title=F.StartsWith("é"; case=:ascii_insensitive)),
            F.Not(PaneWhere(dead=true)),
            F.AnyOf(PaneWhere(index=0), PaneWhere(title=F.EndsWith("ell"))),
            SessionWhere(
                windows=F.AnyRelated(
                    WindowWhere(name="API", panes=F.AnyRelated(PaneWhere(active=true))),
                ),
            ),
            WindowWhere(panes=F.AllRelated(PaneWhere(dead=false))),
            WindowWhere(panes=F.NoRelated(PaneWhere(current_command="python"))),
            WindowLinkWhere(index=4, session=SessionWhere(name="ops")),
            ClientWhere(id=ClientID("client", "first"), session=nothing),
        )
        sources = (
            panes(snap),
            panes(snap),
            panes(snap),
            panes(snap),
            panes(snap),
            panes(snap),
            sessions(snap),
            windows(snap),
            windows(snap),
            windowlinks(snap),
            clients(snap),
        )
        expected = ([1], [1], [2], Int[], [1, 3], [1, 2, 3], [1, 2], [2], [1, 2], [3], [1])
        for (q, items, positions) in zip(queries, sources, expected)
            data = encode_where(q)
            restored = decode_where(data)
            @test findall(restored, items) == positions
            @test encode_where(restored) == data
        end
        expected_active = Dict(
            "schema"=>"libtmux.julia.where",
            "version"=>1,
            "entity"=>"pane",
            "where"=>Dict(
                "op"=>"fields",
                "fields"=>[
                    Dict(
                        "field"=>"tmux.pane.active",
                        "match"=>Dict("op"=>"eq", "value"=>true),
                    ),
                ],
            ),
        )
        @test encode_where(PaneWhere(active=true)) == expected_active
        @test findall(decode_where(expected_active), panes(snap)) == [1, 3]
        @test_throws ArgumentError encode_where(F.AllOf())
        @test count(decode_where(encode_where(F.AllOf(); entity=:pane)), panes(snap)) == 3
        @test_throws MethodError encode_where(p -> true)
        @test_throws WireCriteriaError encode_where(PaneWhere(width=typemax(Int64)))
        data = encode_where(PaneWhere(current_command=F.OneOf(("nvim", "vim"))))
        restored = decode_where(data)
        push!(data["where"]["fields"][1]["match"]["values"], "julia")
        @test findall(restored, panes(snap)) == [1]
    end
end

@testset "wire criteria reject ambiguity and bound work" begin
    @test isdefined(LibTmux, :decode_where)
    if isdefined(LibTmux, :decode_where)
        active = Dict(
            "schema"=>"libtmux.julia.where",
            "version"=>1,
            "entity"=>"pane",
            "where"=>Dict(
                "op"=>"fields",
                "fields"=>[
                    Dict(
                        "field"=>"tmux.pane.active",
                        "match"=>Dict("op"=>"eq", "value"=>true),
                    ),
                ],
            ),
        )
        cases = Any[
            merge(active, Dict("version"=>2)),
            merge(active, Dict("version"=>true)),
            merge(active, Dict("entity"=>"transport")),
            merge(active, Dict("extra"=>nothing)),
            merge(active, Dict("where"=>Dict("op"=>"eval", "code"=>"error(\"no\")"))),
            merge(
                active,
                Dict(
                    "where"=>Dict(
                        "op"=>"fields",
                        "fields"=>[
                            Dict(
                                "field"=>"tmux.pane.active",
                                "match"=>Dict("op"=>"eq", "value"=>nothing),
                            ),
                        ],
                    ),
                ),
            ),
            merge(
                active,
                Dict(
                    "where"=>Dict(
                        "op"=>"fields",
                        "fields"=>[
                            Dict(
                                "field"=>"tmux.window.name",
                                "match"=>Dict("op"=>"eq", "value"=>"api"),
                            ),
                        ],
                    ),
                ),
            ),
            merge(
                active,
                Dict(
                    "where"=>Dict(
                        "op"=>"fields",
                        "fields"=>[
                            Dict(
                                "field"=>"tmux.pane.width",
                                "match"=>Dict("op"=>"eq", "value"=>1.0),
                            ),
                        ],
                    ),
                ),
            ),
            merge(
                active,
                Dict(
                    "where"=>Dict(
                        "op"=>"fields",
                        "fields"=>[
                            Dict(
                                "field"=>"tmux.pane.width",
                                "match"=>Dict("op"=>"ge", "value"=>Inf),
                            ),
                        ],
                    ),
                ),
            ),
            merge(
                active,
                Dict(
                    "where"=>Dict(
                        "op"=>"fields",
                        "fields"=>[
                            Dict(
                                "field"=>"tmux.pane.window",
                                "match"=>Dict("op"=>"eq", "value"=>nothing),
                            ),
                        ],
                    ),
                ),
            ),
            LibTmux.WireObject([
                "schema"=>"libtmux.julia.where",
                "version"=>1,
                "entity"=>"pane",
                "where"=>active["where"],
                "entity"=>"window",
            ]),
        ]
        for invalid in cases
            @test_throws WireCriteriaError decode_where(invalid)
        end
        duplicate = deepcopy(active)
        push!(duplicate["where"]["fields"], duplicate["where"]["fields"][1])
        @test_throws WireCriteriaError decode_where(duplicate)
        @test_throws WireCriteriaError decode_where(active; limits=WhereLimits(max_nodes=5))
        @test_throws WireCriteriaError decode_where(active; limits=WhereLimits(max_depth=2))
        @test_throws WireCriteriaError decode_where(
            active;
            limits=WhereLimits(max_string_bytes=8),
        )
        @test_throws WireCriteriaError decode_where(active; limits=WhereLimits(max_items=1))
        @test_throws WireCriteriaError decode_where(
            active;
            limits=WhereLimits(max_bytes=20),
        )
        cycle = Dict{String,Any}("op"=>"not")
        cycle["arg"] = cycle
        @test_throws WireCriteriaError decode_where(merge(active, Dict("where"=>cycle)))
        @test_throws ArgumentError WhereLimits(max_depth=0)
    end
end
