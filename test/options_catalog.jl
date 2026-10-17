@testset "pinned option admission metadata" begin
    metadata = LibTmux._tmux_option_metadata
    @test (metadata("history-limit").scope, metadata("history-limit").kind) ==
          (0x02, :number)
    @test metadata("history") === metadata("@custom") === nothing
    @test (
        metadata("default-shell").checked_string,
        metadata("status-left").checked_string,
    ) == (true, false)
    command = metadata("default-client-command")
    @test (command.kind, command.array, command.hook) == (:command, false, false)

    scopes = (
        ("pane-border-style", "3.6b", 0x04),
        ("pane-border-style", "3.7", 0x0c),
        ("pane-active-border-style", "3.3", 0x04),
        ("pane-active-border-style", "3.7c", 0x0c),
    )
    @test all(metadata(name, version).scope == scope for (name, version, scope) in scopes)
    # Options that only the unsupported 3.2a release scoped differently are stable.
    stable =
        (("window-linked", 0x02), ("window-unlinked", 0x02), ("pane-border-format", 0x0c))
    @test all(metadata(name).scope == scope for (name, scope) in stable)
    @test !any(LibTmux._tmux_option_versioned(name) for (name, _) in stable)
    @test all(metadata(name, "3.3").scope == scope for (name, scope) in stable)
    @test (
        metadata("destroy-unattached", "3.3a").kind,
        metadata("destroy-unattached", "3.4").kind,
    ) == (:flag, :choice)
    @test metadata("allow-passthrough", "3.3").kind == :flag
    @test metadata("allow-passthrough", "3.2a") === nothing
    @test metadata("pane-border-style", "3.7c").scope == 0x0c
    @test all(
        metadata("pane-border-style", version) === nothing for
        version in ("3.2", "3.2a", "3.7d", "3.8", "next-3.9")
    )
    @test metadata("history-limit", "next-3.9").scope == 0x02
    @test LibTmux._tmux_option_versioned("pane-border-style") &&
          metadata("pane-border-style") === nothing
end
