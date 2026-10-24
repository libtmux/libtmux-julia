using Test
using LibTmuxWorkspace
import LibTmux
import JSON
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

@testset "a tmux release below the floor is refused without effects" begin
    with_workspace_server() do fixture
        server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
        borrowed = LibTmux.new_session(server; name="borrowed", command=["/bin/cat"])
        script = joinpath(fixture.directory, "tmux-old")
        write(
            script,
            raw"""#!/bin/sh
previous=
for argument in "$@"; do
    if [ "$previous" = -C ]; then
        printf 'unknown command: %s3.2a\n' "${argument%\#\{version\}}" >&2
        exit 1
    fi
    previous=$argument
done
exit 99
""",
        )
        chmod(script, 0o700)
        old = LibTmux.Server(socket_path=fixture.socket, tmux=script)
        document = Dict(
            "session_name" => "refused",
            "windows" => [Dict("window_name" => "created")],
        )
        prepared = plan(expand(validate(document); base_directory=fixture.directory))
        failure = try
            apply(old, prepared)
        catch error
            error
        end
        @test failure isa WorkspaceApplyError
        @test failure.cause isa LibTmux.UnsupportedTmuxVersion
        @test failure.result.status == :failed
        @test isempty(failure.result.created) && isempty(failure.result.unknown_effects)

        path = joinpath(fixture.directory, "workspace.json")
        write(path, """{"session_name":"refused","windows":[{"window_name":"created"}]}""")
        # The CLI reports the refusal itself, under one code, for `load` and
        # `freeze`, in every output mode.
        for command in (["load", path], ["freeze", "borrowed"]),
            mode in ("human", "json", "ndjson")

            out, err = IOBuffer(), IOBuffer()
            code = LibTmuxWorkspace.main(
                [
                    command...,
                    "--socket",
                    fixture.socket,
                    "--tmux",
                    script,
                    "--output",
                    mode,
                ];
                out,
                err,
            )
            text, stdout = String(take!(err)), String(take!(out))
            @test code == 3
            @test occursin("\"3.2a\" is unsupported", text)
            @test occursin("requires tmux 3.3a or newer", text)
            @test occursin("Upgrade tmux", text)
            # No step is announced before the refusal: nothing ran.
            @test !occursin(r"workspace application|retained|partial|step \d", text)
            if mode == "human"
                @test isempty(stdout)
            else
                events = JSON.parse.(split(chomp(stdout), '\n'))
                @test all(event -> get(event, "event", "error") == "error", events)
                @test !occursin("step_started", stdout)
                payload = JSON.parse(last(split(chomp(stdout), '\n')))
                @test payload["status"] == "error" && payload["exit_code"] == 3
                @test payload["error"]["code"] == "tmux_unsupported"
                @test occursin("Upgrade tmux", payload["error"]["message"])
                @test !occursin(
                    r"workspace application|retained|partial",
                    payload["error"]["message"],
                )
                @test !haskey(payload, "result")
            end
        end

        # The interactive attach client is not fenced, so its daemon's version is
        # checked first.
        target = (server=(socket_path=fixture.socket,), id="\$0")
        @test_throws LibTmux.UnsupportedTmuxVersion LibTmuxWorkspace._attach_cli(
            old,
            target,
        )

        names = [session.name for session in LibTmux.sessions(LibTmux.snapshot(server))]
        @test names == ["borrowed"]
        @test borrowed isa LibTmux.SessionRef
    end
end

@testset "the interactive attach client never starts a daemon" begin
    mktempdir(; prefix="ltj-attach-") do directory
        script = joinpath(directory, "tmux-attach")
        write(
            script,
            raw"""#!/bin/sh
previous=
for argument in "$@"; do
    if [ "$previous" = -C ]; then
        printf 'unknown command: %s3.7c\n' "${argument%\#\{version\}}" >&2
        exit 1
    fi
    previous=$argument
done
printf '%s\n' "$*" > "$0.attach"
exit 0
""",
        )
        chmod(script, 0o700)
        socket = joinpath(directory, "s")
        server = LibTmux.Server(socket_path=socket, tmux=script)
        target = (server=(socket_path=socket,), id="\$0")
        LibTmuxWorkspace._attach_cli(server, target)
        words = split(readchomp(script * ".attach"))
        @test "attach-session" in words && "-N" in words
        @test findfirst(==("-N"), words) < findfirst(==("attach-session"), words)
    end
end
