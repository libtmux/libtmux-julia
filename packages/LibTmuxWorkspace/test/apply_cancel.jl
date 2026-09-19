using Test
using LibTmuxWorkspace
import LibTmux
isdefined(@__MODULE__, :with_workspace_server) || include("owned_server.jl")

@testset "cancelled apply removes only its created session" begin
    with_workspace_server() do fixture
        server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
        token = LibTmux.CancellationToken()
        cancel_doc = Dict(
            "session_name" => "cancelled",
            "options" => Dict("default-shell" => "/bin/sh"),
            "windows" => [Dict("window_name" => "owned")],
        )
        failure = try
            apply(
                server,
                plan(expand(validate(cancel_doc); base_directory=fixture.directory));
                cancel=token,
                rollback=:created,
                on_event=event -> begin
                    if event.event == :step_completed && event.action == :create_window
                        LibTmux.cancel!(token)
                    end
                end,
            )
        catch error
            error
        end
        @test failure isa WorkspaceApplyError && failure.result.status == :cancelled
        @test only(failure.result.rollback).status == :removed
        @test [s.name for s in LibTmux.sessions(LibTmux.snapshot(server))] == String[]
    end
end
