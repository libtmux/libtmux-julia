using Test
using LibTmuxWorkspace
import LibTmux
isdefined(@__MODULE__, :with_workspace_server) || include("owned_server.jl")

@testset "known creation remains visible after observation failure" begin
    with_workspace_server() do fixture
        server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
        borrowed = LibTmux.new_session(server; name="borrowed", command=["/bin/cat"])
        flag, wrapper = joinpath(fixture.directory, "fail-observation"),
        joinpath(fixture.directory, "tmux-fault")
        word = LibTmuxWorkspace._shell_word
        write(
            wrapper,
            "#!/bin/sh\nfor arg do\n" *
            "case \"\$arg\" in\nnew-window) : > " *
            word(flag) *
            ";;\n" *
            "list-sessions) if test -f " *
            word(flag) *
            "; then exit 78; fi;;\nesac\ndone\n" *
            "exec " *
            word(fixture.tmux) *
            " \"\$@\"\n",
        )
        chmod(wrapper, 0o700)
        faulty = LibTmux.Server(socket_path=fixture.socket, tmux=wrapper)
        prepared = plan(
            expand(
                validate(
                    Dict(
                        "session_name" => "borrowed",
                        "windows" =>
                            [Dict("window_name" => "created", "window_index" => 8)],
                    ),
                );
                base_directory=fixture.directory,
            ),
        )
        failure = try
            apply(faulty, prepared; reuse=borrowed, rollback=:created, readiness=:none)
        catch error
            error
        end
        @test failure isa WorkspaceApplyError
        created = only(filter(x -> x isa LibTmux.WindowRef, failure.result.created))
        @test any(
            item -> item.target == created && item.status == :unresolved,
            failure.result.rollback,
        )
        @test length(LibTmux.windows(LibTmux.snapshot(server))) == 2
    end
end

@testset "borrowed session survives partial apply cleanup" begin
    with_workspace_server() do fixture
        server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session = LibTmux.new_session(server; name="workspace", command=["/bin/cat"])
        failed_doc = Dict(
            "session_name" => "workspace",
            "windows" => [
                Dict(
                    "window_name" => "temporary",
                    "window_index" => 7,
                    "options_after" => Dict("not-a-real-option" => true),
                ),
            ],
        )
        failure = try
            apply(
                server,
                plan(expand(validate(failed_doc); base_directory=fixture.directory));
                reuse=session,
                rollback=:created,
            )
        catch error
            error
        end
        @test failure isa WorkspaceApplyError
        @test failure.result.status == :partial
        @test failure.result.borrowed == (session,)
        @test !isempty(failure.result.created)
        @test !isempty(failure.result.rollback)
        @test length(LibTmux.windows(LibTmux.snapshot(server))) == 1
    end
end
