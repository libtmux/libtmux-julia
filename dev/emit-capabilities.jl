# Write capabilities.json from the capability registry, or verify it.
#
#   julia --project=. dev/emit-capabilities.jl           write the manifest
#   julia --project=. dev/emit-capabilities.jl --check   fail if it differs

using LibTmux

const MANIFEST = joinpath(@__DIR__, "..", "capabilities.json")

function main(args)
    unknown = setdiff(args, ["--check"])
    isempty(unknown) || error("usage: emit-capabilities.jl [--check]")
    expected = LibTmux._capabilities_manifest()
    if "--check" in args
        isfile(MANIFEST) && read(MANIFEST, String) == expected || error(
            "capabilities.json differs from the registry; run julia --project=. dev/emit-capabilities.jl",
        )
        println("Capabilities check PASS")
    else
        write(MANIFEST, expected)
        println("Capabilities generation PASS")
    end
end

main(ARGS)
