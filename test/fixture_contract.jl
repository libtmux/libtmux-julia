using Test

include("support/owned_tmux.jl")
using .OwnedTmux

@testset "owned tmux fixture" begin
    owned = Ref{Any}()
    result = withenv(
        "TMUX" => "borrowed-server",
        "TMUX_PANE" => "%999",
        "LIBTMUX_FIXTURE_SECRET" => "test-only-private-marker",
    ) do
        with_tmux() do fixture
            owned[] = fixture
            @test !haskey(fixture.env, "TMUX")
            @test !haskey(fixture.env, "TMUX_PANE")
            contains_secret = haskey(fixture.env, "LIBTMUX_FIXTURE_SECRET")
            printed_contains_secret = occursin(
                "test-only-private-marker",
                sprint(show, tmuxcmd(fixture, "display-message", "-p", "ready")),
            )
            @test !contains_secret
            @test !printed_contains_secret
            @test dirname(fixture.socket) == fixture.directory
            @test startswith(basename(fixture.directory), "libtmux-julia-")
            @test process_running(fixture.process)
            @test readchomp(tmuxcmd(fixture, "display-message", "-p", "#{pid}")) ==
                  string(getpid(fixture.process))

            run(tmuxcmd(fixture, "new-session", "-d", "-s", "dev", "-n", "api", "cat"))
            run(tmuxcmd(fixture, "split-window", "-h", "-t", "dev:api", "cat"))
            run(tmuxcmd(fixture, "new-window", "-t", "dev:", "-n", "build", "cat"))
            run(tmuxcmd(fixture, "new-session", "-d", "-s", "ops", "cat"))
            run(tmuxcmd(fixture, "link-window", "-s", "dev:api", "-t", "ops:4"))
            run(tmuxcmd(fixture, "kill-window", "-t", "ops:0"))
            sessions = split(
                readchomp(tmuxcmd(fixture, "list-sessions", "-F", "#{session_id}")),
                '\n',
            )
            links = split(
                readchomp(tmuxcmd(fixture, "list-windows", "-a", "-F", "#{window_id}")),
                '\n',
            )
            panes = split(
                readchomp(tmuxcmd(fixture, "list-panes", "-a", "-F", "#{pane_id}")),
                '\n',
            )
            @test length(sessions) == 2
            @test length(links) == 3
            @test length(unique(links)) == 2
            @test length(panes) == 5
            @test length(unique(panes)) == 3
            with_tmux() do other
                @test other.socket != fixture.socket
                @test getpid(other.process) != getpid(fixture.process)
            end
            @test process_running(fixture.process)
            :completed
        end
    end
    @test result === :completed
    @test process_exited(owned[].process)
    @test success(owned[].process)
    @test !ispath(owned[].directory)

    sentinel = ErrorException("fixture callback failed")
    failure = try
        with_tmux() do fixture
            owned[] = fixture
            run(tmuxcmd(fixture, "new-session", "-d", "-s", "failing", "cat"))
            throw(sentinel)
        end
    catch error
        error
    end
    @test failure === sentinel
    @test process_exited(owned[].process)
    @test success(owned[].process)
    @test !ispath(owned[].directory)
end

# Outer case: deliberately stop the daemon to exercise its 900 ms deadline.
if get(ENV, "LIBTMUX_TEST_FIXTURE_ESCALATION", "0") == "1"
    @testset "owned tmux forced cleanup" begin
        owned = Ref{Any}()
        sentinel = ErrorException("callback failed before forced cleanup")
        failure = try
            with_tmux() do fixture
                owned[] = fixture
                run(Cmd(["kill", "-STOP", string(getpid(fixture.process))]))
                throw(sentinel)
            end
        catch error
            error
        end
        @test failure isa CompositeException
        if failure isa CompositeException
            @test failure.exceptions[1] === sentinel
            @test occursin("required SIGKILL", sprint(showerror, failure.exceptions[2]))
        end
        @test process_exited(owned[].process)
        @test owned[].process.termsignal == Base.SIGKILL
        @test !ispath(owned[].directory)
    end
end
