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
            mv(marker * ".pending", marker)
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
        @test_throws ArgumentError ready(0.9, nothing) do marker, content
            write(marker * ".pending", "wrong content")
            mv(marker * ".pending", marker)
        end
    end
end
