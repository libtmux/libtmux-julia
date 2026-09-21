using Test
using LibTmuxWorkspace
import LibTmux

@testset "owned readiness marker lifecycle" begin
    @test isdefined(LibTmuxWorkspace, :_with_ready_marker)
    if isdefined(LibTmuxWorkspace, :_with_ready_marker)
        ready = LibTmuxWorkspace._with_ready_marker
        path = Ref("")
        ready(0.9, nothing) do marker, content
            path[] = marker
            write(marker * ".pending", content)
            Base.Filesystem.rename(marker * ".pending", marker)
        end
        @test !ispath(dirname(path[]))
        token = LibTmux.CancellationToken()
        @test_throws LibTmux.RequestCancelled ready(0.9, token) do marker, content
            path[] = marker
            LibTmux.cancel!(token)
        end
        @test !ispath(dirname(path[]))
        @test_throws SystemError write(path[], "late producer")
        @test_throws LibTmux.DeadlineExceeded ready(0.05, nothing) do marker, content
            path[] = marker
        end
        @test !ispath(dirname(path[]))
        for invalid in ("", "wrong content")
            @test_throws ArgumentError ready(0.9, nothing) do marker, content
                write(marker * ".pending", invalid)
                Base.Filesystem.rename(marker * ".pending", marker)
            end
        end
    end
end

struct _ReadinessGateMonitor
    monitor::LibTmuxWorkspace.FolderMonitor
    gate::Base.Event
end
function Base.wait(monitor::_ReadinessGateMonitor)
    notify(monitor.gate)
    wait(monitor.monitor)
end
Base.close(monitor::_ReadinessGateMonitor) = close(monitor.monitor)

@testset "asynchronous publication after readiness inspection" begin
    gate = Base.Event()
    producer = nothing
    path = Ref("")
    function monitor_file(file)
        @test isfile(file)
        _ReadinessGateMonitor(LibTmuxWorkspace.FolderMonitor(file), gate)
    end
    try
        @test isnothing(
            LibTmuxWorkspace._with_ready_marker(
                0.9,
                nothing;
                _monitor=monitor_file,
            ) do marker, content
                path[] = marker
                producer = Threads.@spawn begin
                    wait(gate)
                    write(marker * ".pending", content)
                    Base.Filesystem.rename(marker * ".pending", marker)
                end
            end,
        )
        fetch(producer)
        @test !ispath(dirname(path[]))
    finally
        notify(gate)
        producer === nothing || wait(producer)
    end
end

struct _ReadinessWake
    receive::Function
    closed::Base.RefValue{Bool}
end
Base.wait(monitor::_ReadinessWake) = monitor.receive()
Base.close(monitor::_ReadinessWake) = (monitor.closed[]=true; nothing)

@testset "readiness uses published state and unnamed wakes" begin
    ready = LibTmuxWorkspace._with_ready_marker
    closed = Ref(false)
    immediate = _ReadinessWake(() -> error("published marker must precede waiting"), closed)
    @test isnothing(ready(0.9, nothing; _monitor=(_ -> immediate)) do marker, content
        write(marker * ".pending", content)
        Base.Filesystem.rename(marker * ".pending", marker)
    end)
    @test closed[]
    marker_path, marker_content = Ref(""), Ref("")
    received = Ref(false)
    unnamed = _ReadinessWake(closed) do
        received[] && error("unnamed wake was discarded")
        received[] = true
        write(marker_path[] * ".pending", marker_content[])
        Base.Filesystem.rename(marker_path[] * ".pending", marker_path[])
        "" => nothing
    end
    @test isnothing(ready(0.9, nothing; _monitor=(_ -> unnamed)) do marker, content
        marker_path[], marker_content[] = marker, content
    end)
    @test received[]
    @test !ispath(dirname(marker_path[]))
end
