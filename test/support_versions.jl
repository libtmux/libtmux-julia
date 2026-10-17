@testset "tmux release ordering" begin
    atleast(version) = LibTmux._version_at_least(version, "3.3a")
    # Vectors from every version string tmux has reported.
    supported = (
        "3.3a",
        "3.4",
        "3.7d",
        "3.8",
        "3.10",
        "4.0",
        "3.4-rc",
        "3.8-rc",
        "3.8-rc2",
        "next-3.4",
        "next-3.9",
        "3.3b",
        "3.5a",
        "3.6b",
        "next-3.10",
    )
    # Recognized releases below the floor.
    below = ("3.3", "3.2a", "3.3-rc", "3.2-rc5", "next-3.3")
    # Spellings tmux has not reported as a release.
    unrecognized = (
        "master",
        "openbsd-7.6",
        "3",
        "garbage",
        "3.3a garbage",
        "3.3a-master",
        "3.3a-dev",
        "next-3.3a",
        "next-3.9-master",
        "next-3.4a",
        "3.4a-rc",
        "tmux 3.3a",
        "3.3a\n",
        "3.x",
        "3.4garbage",
        "9.9alpha",
        "next-",
        "3.3aa",
        "openbsd",
        "next-99999999999999999999.1",
        "99999999999999999999.1",
        "3.99999999999999999999",
    )
    @test all(atleast, supported)
    @test !any(atleast, below) && !any(atleast, unrecognized) && !atleast("")
    # Each input is refused as its own class: unsupported, or not a release.
    message(version) = sprint(showerror, UnsupportedTmuxVersion(version))
    for version in below
        @test LibTmux._release_key(version) !== nothing
        @test occursin("is unsupported", message(version))
        @test !occursin("not a recognized release", message(version))
    end
    for version in unrecognized
        @test LibTmux._release_key(version) === nothing
        @test occursin("is not a recognized release", message(version))
        @test !occursin("is unsupported", message(version))
    end
    @test startswith(message(""), "tmux version is unsupported;")
    @test LibTmux.MINIMUM_TMUX_VERSION == "3.3a"
    for chain in (
        ("next-3.7", "3.7-rc", "3.7-rc3", "3.7", "3.7a"),
        ("next-3.4", "3.4-rc", "3.4"),
        ("3.9", "3.10"),
    )
        keys = LibTmux._release_key.(chain)
        @test issorted(keys) && allunique(keys)
    end
    for control in ("3.8-rc2", "next-3.8", "3.7", "3.7d", "3.8")
        @test LibTmux._version_at_least(control, "3.7")
    end
    for below in ("next-3.7", "3.7-rc2", "3.6b")
        @test !LibTmux._version_at_least(below, "3.7")
    end
    @test LibTmux._version_at_least("3.7d", "3.7")
    @test !LibTmux._version_at_least("3.7-rc1", "3.7")
    @test !LibTmux._version_at_least("next-3.7", "3.7")
    @test LibTmux._version_at_least("next-3.9", "3.7")
    @test_throws ArgumentError LibTmux._version_at_least("3.4", "master")

    error = UnsupportedTmuxVersion("3.2a", "3.3a", "")
    @test error isa LibTmux.LibTmuxError
    @test sprint(showerror, error) ==
          "tmux \"3.2a\" is unsupported; libtmux requires tmux 3.3a or newer. " *
          "Upgrade tmux and restart the server, or pin the previous libtmux release."
    unrecognized = sprint(showerror, UnsupportedTmuxVersion("master"))
    @test occursin("\"master\" is not a recognized release", unrecognized)
    @test !occursin("is unsupported", unrecognized)
    @test occursin(
        "could not be read",
        sprint(showerror, UnsupportedTmuxVersion("", "could not be read")),
    )
    @test LibTmux._batch_sent(error) === false

    # Mirrored layouts need 3.5; pre-release builds rank by the release they name.
    for version in ("3.5", "3.7d", "3.8-rc2", "next-3.9")
        @test LibTmux._check_layout_version("main-vertical-mirrored", version) === nothing
    end
    for version in ("3.3a", "3.4", "next-3.5", "3.5-rc1", "master")
        @test_throws UnsupportedCapability LibTmux._check_layout_version(
            "main-vertical-mirrored",
            version,
        )
    end
end

@testset "version gates use the release ranking" begin
    # A development or release-candidate build ranks below the release it names.
    @test !LibTmux._version_at_least("next-3.4", "3.4")
    @test !LibTmux._version_at_least("3.4-rc", "3.4")
    @test LibTmux._version_at_least("3.4", "3.4")
    @test LibTmux._version_at_least("3.4a", "3.4")
    @test LibTmux._version_at_least("next-3.5", "3.4")

    # The layout gate is the 3.5 gate, for every spelling in the grammar.
    spellings =
        ("3.4", "3.4a", "3.5-rc", "next-3.5", "3.5", "3.5a", "3.8-rc", "next-3.9", "3.10")
    for version in spellings
        gate = LibTmux._version_at_least(version, "3.5")
        refused = try
            LibTmux._check_layout_version("tiled", version)
            false
        catch error
            error isa LibTmux.UnsupportedCapability || rethrow()
            true
        end
        @test refused == !gate
    end
    @test_throws LibTmux.UnsupportedCapability LibTmux._check_layout_version(
        "x",
        "next-3.5",
    )
    @test_throws LibTmux.UnsupportedCapability LibTmux._check_layout_version("x", "3.5-rc")
    @test LibTmux._check_layout_version("x", "3.8-rc") === nothing
    @test LibTmux._check_layout_version("x", "next-3.9") === nothing
end
