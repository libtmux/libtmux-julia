using Test, LibTmux

@testset "generation-bound captured lookup" begin
    identity = ServerIdentity(socket_path="/tmp/libtmux-captured", generation="daemon-a")
    client = ClientID("captured-client", "first")
    captured = LibTmux._build_snapshot(
        identity;
        sessions=[(id="\$0", name="work")],
        windows=[(id="@0", name="code")],
        panes=[(id="%0", title="target")],
        clients=[(id=client, name="captured-client")],
        complete=true,
        acquired=(0.0, 0.0),
    )
    ref = PaneRef(identity, "%0")
    found = try
        get(captured, ref, nothing)
    catch error
        error
    end
    @test found isa PaneSnapshot
    if found isa PaneSnapshot
        @test snapshotof(found) === captured && found.ref == ref
        @test (@inferred captured[ref]).ref == ref
        for reference in (
            SessionRef(identity, "\$0"),
            WindowRef(identity, "@0"),
            ref,
            ClientRef(identity, client),
        )
            @test captured[reference].ref == reference
        end
        @test get(captured, PaneRef(identity, "%9"), :absent) === :absent
        @test_throws KeyError captured[PaneRef(identity, "%9")]
        @test get(
            captured,
            ClientRef(identity, ClientID("captured-client", "next")),
            nothing,
        ) === nothing
        partial = LibTmux._build_snapshot(identity; panes=[(id="%0",)], acquired=(0.0, 0.0))
        @test partial[ref].ref == ref
        @test_throws SnapshotCoverageError get(partial, PaneRef(identity, "%9"), nothing)
        @test_throws CrossServerReference get(
            captured,
            PaneRef(
                ServerIdentity(socket_path="/tmp/libtmux-other", generation="daemon-a"),
                "%0",
            ),
            nothing,
        )
        @test_throws StaleReference get(
            captured,
            PaneRef(
                ServerIdentity(socket_path=identity.socket_path, generation="daemon-b"),
                "%0",
            ),
            nothing,
        )
    end
end
