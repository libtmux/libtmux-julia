using LibTmux, LibTmuxMCP, Test
import SHA, JSON

# Pure: full canonical facets bind values and contexts omitted from a clipped page.
function canonical_reference(value)
    if value isa AbstractDict
        "{" *
        join(
            (
                JSON.json(String(key)) * ":" * canonical_reference(item) for
                (key, item) in sort!(collect(pairs(value)); by=first)
            ),
            ",",
        ) *
        "}"
    elseif value isa Union{AbstractVector,Tuple}
        "[" * join((canonical_reference(item) for item in value), ",") * "]"
    else
        JSON.json(value)
    end
end

function fixture(; later_name="ninth", title_suffix="tail", width=UInt128(1)<<100)
    sessions = [(id="\$$i", name=i == 9 ? later_name : "session-$i") for i = 1:10]
    LibTmux._build_snapshot(
        ServerIdentity(socket_path="/tmp/libtmux-c-facet-review", generation="same");
        acquired=(1, 2),
        complete=true,
        sessions,
        windows=[(id="@1", name="window")],
        panes=[
            (
                id="%$i",
                window_id="@1",
                index=i-1,
                active=false,
                dead=false,
                width,
                height=24,
                current_command=nothing,
                current_path=nothing,
                title=repeat("雪", 100)*title_suffix,
                exit_status=nothing,
            ) for i = 1:2
        ],
        windowlinks=vcat(
            [(session_id="\$$i", window_id="@1", index=i, active=false) for i = 1:10],
            [(session_id="\$1", window_id="@1", index=99, active=false)],
        ),
    )
end

function context()
    LibTmuxMCP._ToolContext(
        time_ns(),
        30.0,
        CancellationToken(),
        (_...)->nothing,
        Ref(true),
    )
end
function lazyrows(captured; parent=nothing, columns=nothing)
    selected = panes(captured)
    control = LibTmuxMCP._discovery_control(context())
    projection = columns === nothing ? nothing : project_rows(selected; columns)
    rows = LibTmuxMCP._DiscoveryRows(
        captured,
        selected,
        parent,
        nothing,
        projection,
        Dict{Int,LibTmuxMCP._DiscoveryWindowFacets}(),
        control,
    )
    rows, control
end
function raw_reference(pane, links; projected=false)
    contexts = [
        Dict(
            "sessionId"=>string(link.session_id),
            "sessionName"=>link.session.name,
            "windowId"=>string(link.window_id),
            "windowName"=>link.window.name,
            "windowIndex"=>link.index,
        ) for link in links
    ]
    row = Dict{String,Any}(
        "target"=>Dict("paneId"=>string(pane.id), "generation"=>pane.ref.server.generation),
        "caller"=>false,
        "contexts"=>contexts,
        "contextsTruncated"=>length(links)>8,
        "fieldsTruncated"=>ncodeunits(pane.title)>256,
    )
    if projected
        row["values"] = Dict(
            "id"=>string(pane.id),
            "title"=>pane.title,
            "width"=>pane.width,
            "exit_status"=>pane.exit_status,
        )
    else
        merge!(
            row,
            Dict(
                "active"=>pane.active,
                "dead"=>pane.dead,
                "command"=>pane.current_command,
                "title"=>pane.title,
                "width"=>pane.width,
                "height"=>pane.height,
            ),
        )
    end
    row
end

@testset "independent full discovery facet bytes" begin
    captured = fixture()
    for columns in (nothing, (:id, :title, :width, :exit_status))
        rows, control = lazyrows(captured; columns)
        expected = [
            raw_reference(pane, windowlinks(pane.window); projected=columns !== nothing) for pane in panes(captured)
        ]
        @test collect(rows) == expected
        @test LibTmuxMCP._discovery_fingerprint(rows, control) ==
              bytes2hex(SHA.sha256(canonical_reference(expected)))
        @test length(rows[1]["contexts"]) == 11
        @test rows[1]["contexts"][end]["windowIndex"] == 99
    end
    rows, control = lazyrows(captured)
    changed, changed_control = lazyrows(fixture(later_name="changed ninth"))
    clipped = LibTmuxMCP._discovery_row_at(rows, 1; clipped=true)
    @test length(clipped["contexts"]) == 8
    @test clipped == LibTmuxMCP._discovery_row_at(changed, 1; clipped=true)
    @test LibTmuxMCP._discovery_fingerprint(rows, control) !=
          LibTmuxMCP._discovery_fingerprint(changed, changed_control)
    changed_title, title_control = lazyrows(fixture(title_suffix="changed tail"))
    @test clipped == LibTmuxMCP._discovery_row_at(changed_title, 1; clipped=true)
    @test LibTmuxMCP._discovery_fingerprint(rows, control) !=
          LibTmuxMCP._discovery_fingerprint(changed_title, title_control)
    @test first(panes(captured)).width === UInt128(1)<<100
end


@testset "canonical chunks preserve JSON byte policy" begin
    cases=Any[
        nothing,
        true,
        typemax(Int),
        -0.0,
        Float32(1.25),
        "",
        (),
        Any[],
        Dict(),
        "😀λé/\\\"",
        String(UInt8[0, 1, 7, 8, 9, 10, 12, 13, 31, 127]),
        String(UInt8[0xff, 0xc2, 0x80]),
        repeat("a", 32767)*"😀"*repeat("z", 32769),
        repeat("a", 32767)*String(UInt8[0xc3])*repeat("z", 32769),
        repeat("😀/\\\"\0", 9000),
    ]
    control=LibTmuxMCP._discovery_control(context())
    @test all(
        LibTmuxMCP._discovery_fingerprint(value, control)==bytes2hex(
            SHA.sha256(canonical_reference(value)),
        ) for value in cases
    )
end

@testset "canonical hashing cooperates after real bytes are processed" begin
    ctx=context()
    current=Ref{Union{Nothing,LibTmuxMCP._DiscoveryDigest}}(nothing)
    checkpoint=function ()
        current[] === nothing || current[].hash.bytecount<65536 || cancel!(ctx.cancel)
        LibTmuxMCP._DiscoveryCheckpoint(ctx)()
    end
    control=LibTmux._CriterionTraversal{Function}(checkpoint, 0, nothing, nothing)
    state=LibTmuxMCP._DiscoveryDigest(
        SHA.SHA2_256_CTX(),
        Vector{UInt8}(undef, 65536),
        0,
        control,
    )
    current[]=state
    @test_throws RequestCancelled LibTmuxMCP._canonical_digest!(state, repeat("雪", 30000))
    @test state.hash.bytecount == 65536
    @test iscancelled(ctx.cancel)
end
