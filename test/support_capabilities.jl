using Test
using LibTmux

@testset "the capability registry and its manifest" begin
    manifest_path = joinpath(@__DIR__, "..", "capabilities.json")
    capabilities, workarounds = LibTmux._CAPABILITIES, LibTmux._WORKAROUNDS
    ids = [[c.id for c in capabilities]; [w.id for w in workarounds]]
    kebab = r"\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z"

    @testset "committed manifest is the registry" begin
        @test isfile(manifest_path)
        @test read(manifest_path, String) == LibTmux._capabilities_manifest()
        @test endswith(LibTmux._capabilities_manifest(), "}\n")
    end

    @testset "entries obey the manifest schema" begin
        @test length(unique(ids)) == length(ids)
        @test all(id -> occursin(kebab, id), ids)
        for c in capabilities
            @test c.handling in (:refuse, :fallback, :repair)
            c.handling === :refuse && @test c.error !== nothing
            @test LibTmux._release_key(c.since) !== nothing
            @test all(r -> LibTmux._release_key(r) !== nothing, c.except)
            @test !isempty(c.apis) && !isempty(c.commands)
        end
        for w in workarounds
            @test w.handling in (:refuse, :repair)
            @test !isempty(w.releases)
            @test all(r -> LibTmux._release_key(r) !== nothing, w.releases)
        end
        for command in Iterators.flatten(
            c.commands for c in Iterators.flatten((capabilities, workarounds))
        )
            @test all(flag -> occursin(r"\A-[A-Za-z]\z", flag), command.flags)
        end
        @test LibTmux._release_key(LibTmux.MINIMUM_TMUX_VERSION) !== nothing
    end

    @testset "api and error names resolve to exported symbols" begin
        function public(name)
            parts = split(name, '.')
            first(parts) == "LibTmux" && length(parts) == 2 || return false
            symbol = Symbol(parts[2])
            isdefined(LibTmux, symbol) && Base.isexported(LibTmux, symbol)
        end
        for entry in Iterators.flatten((capabilities, workarounds))
            for name in entry.apis
                @test public(name)
            end
        end
        for c in capabilities
            c.error === nothing || @test public(c.error)
        end
        @test !public("LibTmux.no_such_function")
    end

    @testset "gates read the registry" begin
        @test LibTmux.CONTROL_MINIMUM_TMUX == LibTmux._capability("control-mode").since
        @test LibTmux.BUFFER_DELETE_MINIMUM_TMUX ==
              LibTmux._capability("buffer-delete-named").since
        @test LibTmux.BUFFER_RENAME_MINIMUM_TMUX ==
              LibTmux._capability("buffer-rename").since
        @test LibTmux.CLIPBOARD_QUERY_MINIMUM_TMUX ==
              LibTmux._capability("clipboard-query").since
        @test LibTmux.LAYOUT_CHECKSUM_MINIMUM_TMUX ==
              LibTmux._capability("layout-without-checksum").since
        @test LibTmux.MIRRORED_LAYOUT_MINIMUM_TMUX ==
              LibTmux._capability("layout-mirrored-main").since
        @test LibTmux.JSON_LAYOUT_MINIMUM_TMUX == LibTmux._capability("layout-json").since
    end

    # A development build ranks just below the release it names, so each
    # probe must pass at the registry release and refuse one step under it.
    @testset "every gate refuses below its registry release" begin
        refuses(check) =
            try
                check()
                false
            catch error
                error isa UnsupportedCapability || rethrow()
                true
            end
        raw(words...) =
            version -> LibTmux._guard_raw_command(collect(String, words), version)
        layout(text) = version -> LibTmux._check_layout_version(text, version)
        # The release before a patch release is the one it patches.
        below(release) =
            occursin(r"[a-z]\z", release) ? release[1:(end-1)] : "next-" * release
        probes = Dict{String,Function}(
            "control-mode" =>
                version -> LibTmux._require_release(
                    version,
                    LibTmux.CONTROL_MINIMUM_TMUX,
                    :open_control,
                    "control acquisition",
                ),
            "buffer-delete-named" => raw("delete-buffer", "-b", "name"),
            "buffer-rename" => raw("set-buffer", "-b", "name", "-n", "other"),
            "clipboard-query" => raw("refresh-client", "-l"),
            "layout-without-checksum" => raw("select-layout", "not-a-layout"),
            "layout-mirrored-main" => layout("main-vertical-mirrored"),
            "layout-json" => layout("{\"layout\": {}}"),
        )
        @test Set(keys(probes)) == Set(c.id for c in capabilities)
        for c in capabilities
            probe = probes[c.id]
            @test !refuses(() -> probe(c.since))
            @test refuses(() -> probe(below(c.since)))
        end

        # A workaround covers its listed releases and their pre-release builds,
        # and no other patch level.
        for w in workarounds
            for release in w.releases
                @test LibTmux._workaround_applies(w.id, release)
                @test LibTmux._workaround_applies(w.id, "next-" * release)
                @test !LibTmux._workaround_applies(w.id, release * "a")
            end
        end
        for release in LibTmux._workaround("break-pane-misnames-windows").releases
            @test refuses(() -> raw("break-pane")(release))
            @test refuses(() -> raw("list-sessions", ";", "break-pane")(release))
            @test !refuses(() -> raw("break-pane", "-n", "named")(release))
            @test !refuses(() -> raw("break-pane")(release * "a"))
        end
        for release in LibTmux._workaround("name-separators-rejected").releases
            @test LibTmux._names_restricted(release)
            @test !LibTmux._names_restricted(release * "a")
        end
        # Each workaround reads its own releases: moving one leaves the other.
        @test LibTmux._unnamed_break_stops("3.7") ==
              LibTmux._workaround_applies("break-pane-misnames-windows", "3.7")
    end

    # Release numbers live in the registry. A literal in a gate would decide
    # a refusal that the manifest does not state.
    @testset "gate code holds no release literal" begin
        for file in ("features.jl", "operations.jl", "topology.jl", "pane_io.jl")
            lines = readlines(joinpath(@__DIR__, "..", "src", file))
            code = join(filter(line -> !startswith(strip(line), "#"), lines), "\n")
            @test !occursin(r"\"3\.[0-9]+[a-z]?\"", code)
        end
    end
end
