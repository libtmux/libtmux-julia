using Test
using LibTmuxWorkspace
isdefined(@__MODULE__, :TmuxpCatalog) ||
    include(joinpath(@__DIR__, "support", "tmuxp_catalog.jl"))

@testset "tmuxp example catalog means what tmuxp means" begin
    Catalog = TmuxpCatalog
    @test sort([
        splitext(name)[1] for name in readdir(Catalog.EXPECTED) if endswith(name, ".json")
    ]) == sort(Catalog.LOADED)
    fired = Set{Symbol}()
    for name in Catalog.LOADED
        want, applied = Catalog.port_expected(name)
        union!(fired, applied)
        @test Catalog.mismatches(want, Catalog.structure(name)) == []
    end
    # A recorded difference that no file reaches any more has stopped differing.
    @test fired == Set(rule.id for rule in Catalog.DIFFERENCES)
    # Without the recorded differences the same comparison reports them.
    plain = Catalog.mismatches(
        Catalog.expected("start-directory"),
        Catalog.structure("start-directory"),
    )
    @test any(m -> m[1] == ["windows", 5, "start_directory"] && m[3] == "/var", plain)
    @test any(
        m -> m[1] == ["session", "start_directory"] && m[2] == "/var",
        Catalog.mismatches(
            Catalog.expected("start-directory"),
            merge(
                Catalog.structure("start-directory"),
                Dict(
                    "session" => merge(
                        Catalog.structure("start-directory")["session"],
                        Dict("start_directory" => "/other"),
                    ),
                ),
            ),
        ),
    )
end

@testset "the tmuxp syntax record is what the loader does" begin
    Catalog = TmuxpCatalog
    record = Catalog.syntax()
    entries = record["entries"]
    @test allunique(entry["id"] for entry in entries)
    @test Set(entry["status"] for entry in entries) == Set(keys(record["statuses"]))
    for entry in entries
        outcome = Catalog.probe(entry)
        if entry["status"] == "refused"
            @test outcome == entry["message"]
        else
            @test outcome isa AbstractDict
            if entry["status"] == "difference" && outcome isa AbstractDict
                path = [
                    part isa Integer ? part + 1 : part for part in entry["observed"]["path"]
                ]
                @test get(entry, "difference", "") != ""
                @test foldl((tree, key) -> tree[key], path; init=outcome) ==
                      entry["observed"]["value"]
            end
        end
    end
    # A change in what the loader does is reported: a refusal that no longer refuses,
    # and an observed value that moved.
    refused = first(entry for entry in entries if entry["status"] == "refused")
    @test Catalog.probe(
        merge(
            refused,
            Dict(
                "probe" => [
                    "session_name: a",
                    "windows:",
                    "  - window_name: w",
                    "    panes: [{}]",
                ],
            ),
        ),
    ) isa AbstractDict
    moved = first(entry for entry in entries if entry["status"] == "difference")
    @test Catalog.probe(
        merge(
            moved,
            Dict(
                "probe" => [
                    "session_name: a",
                    "start_directory: /elsewhere",
                    "windows:",
                    "  - window_name: w",
                    "    panes: [{}]",
                ],
            ),
        ),
    )["session"]["start_directory"] != moved["observed"]["value"]
end
