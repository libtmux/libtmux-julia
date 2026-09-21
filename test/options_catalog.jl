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
        ("window-linked", "3.2a", 0x04),
        ("window-linked", "3.3", 0x02),
        ("pane-border-format", "3.2a", 0x04),
        ("pane-border-format", "3.3", 0x0c),
        ("pane-border-style", "3.6b", 0x04),
        ("pane-border-style", "3.7", 0x0c),
    )
    @test all(metadata(name, version).scope == scope for (name, version, scope) in scopes)
    @test (
        metadata("destroy-unattached", "3.3a").kind,
        metadata("destroy-unattached", "3.4").kind,
    ) == (:flag, :choice)
    @test metadata("allow-passthrough", "3.2a") === nothing
    @test metadata("pane-border-style", "3.7c").scope == 0x0c
    @test all(
        metadata("window-linked", version) === nothing for
        version in ("3.2", "3.7d", "3.8", "next-3.9")
    )
    @test metadata("history-limit", "next-3.9").scope == 0x02
    @test LibTmux._tmux_option_versioned("window-linked") &&
          metadata("window-linked") === nothing
end
