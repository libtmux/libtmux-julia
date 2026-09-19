using Test
using LibTmuxWorkspace
import LibTmux
isdefined(@__MODULE__, :with_workspace_server) || include("owned_server.jl")

@testset "owned workspace apply and freeze" begin
    @test isdefined(LibTmuxWorkspace, :apply)
    if isdefined(LibTmuxWorkspace, :apply)
        with_workspace_server() do fixture
            server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
            output = joinpath(fixture.directory, "command-result")
            script_output = joinpath(fixture.directory, "before-result")
            shellword(s) = "'" * replace(s, "'" => "'\\''") * "'"
            marker =
                shellword(fixture.tmux) *
                " -S " *
                shellword(fixture.socket) *
                " wait-for -S complete"
            document = Dict(
                "session_name" => "workspace",
                "start_directory" => fixture.directory,
                "before_script" =>
                    "/bin/sh -c 'printf before > \"\$1\"' sh " * shellword(script_output),
                "options" => Dict("default-shell" => "/bin/sh"),
                "environment" => Dict("VALUE" => "session"),
                "windows" => [
                    Dict(
                        "window_name" => "main",
                        "window_index" => 0,
                        "layout" => "even-horizontal",
                        "focus" => true,
                        "panes" => [
                            Dict(
                                "environment" => Dict("VALUE" => "literal;#{pane_id}"),
                                "shell_command" =>
                                    "printf '%s' \"\$VALUE\" > " *
                                    shellword(output) *
                                    "; " *
                                    marker,
                                "focus" => true,
                            ),
                            nothing,
                        ],
                    ),
                ],
            )
            prepared = plan(expand(validate(document); base_directory=fixture.directory))
            events = []
            result = apply(server, prepared; on_event=e -> push!(events, e))
            LibTmux.run_command(server, "wait-for", "complete"; timeout=0.9)
            @test result.status == :complete
            @test isempty(result.borrowed)
            @test read(output, String) == "literal;#{pane_id}"
            @test read(script_output, String) == "before"
            snap = LibTmux.snapshot(server)
            @test length(LibTmux.windows(snap)) == 1
            @test length(LibTmux.panes(snap)) == 2
            @test only(LibTmux.windowlinks(snap)).index == 0
            @test last(events).event == :complete
            @test_throws WorkspaceApplyError apply(server, prepared)
            frozen = freeze(server, result.session)
            @test validate(frozen).session_name == "workspace"
            @test length(validate(frozen).windows[1].panes) == 2

        end
    end
end
