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
    refused = (
        "3.3",
        "3.2a",
        "3.3-rc",
        "3.2-rc5",
        "next-3.3",
        "master",
        "openbsd-7.6",
        "",
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
    @test !any(atleast, refused)
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
end
