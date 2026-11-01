using Test
isdefined(@__MODULE__, :OwnedTmux) || include("support/owned_tmux.jl")

# These tests start tmux without -S or -L on purpose. The sandbox makes that
# safe: a client that names no socket looks under the sandbox's TMUX_TMPDIR, and
# each test stops what it starts and removes the socket before its file ends, as
# the sweep requires.

const SOCKET_DEFAULT_TMUX = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")

# A home with no tmux.conf, so a developer's own configuration cannot change what
# a server started here does. Only the sandbox's TMUX_TMPDIR is carried over.
function socket_default_env(home; extra...)
    env = Dict(
        "PATH" => get(ENV, "PATH", "/usr/local/bin:/usr/bin:/bin"),
        "HOME" => home,
        "TERM" => "xterm-256color",
        "SHELL" => "/bin/sh",
        Main.TestSandbox.child_entries()...,
    )
    for (name, value) in extra
        env[String(name)] = value
    end
    env
end

# Stop the server, wait until nothing answers on its socket, and remove the file
# tmux leaves behind, so the sweep at the end of the file finds nothing. The file
# is removed only once no server answers there.
function socket_default_stop(server, socket, env)
    run_command(server, "kill-server"; check=false, env)
    stopped = Main.TestSandbox.gone(socket)
    stopped && rm(socket; force=true)
    stopped
end

function socket_default_session(server, env, name)
    run_command(server, "new-session", "-d", "-s", name, "/bin/cat"; env)
end

@testset "a server that names no socket lands where a bare tmux looks" begin
    uid_directory = joinpath(ENV["TMUX_TMPDIR"], "tmux-$(Libc.getuid())")
    default = joinpath(uid_directory, "default")
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="h-") do home
        env = socket_default_env(home)
        server = Server(env=Dict{String,String}(); tmux=SOCKET_DEFAULT_TMUX)
        @test !ispath(default)
        stopped = false
        try
            socket_default_session(server, env, "bare")
            @test issocket(default)
            # A real client that names no socket finds the session the library started.
            listed = read(
                setenv(
                    `$SOCKET_DEFAULT_TMUX -u -N list-sessions -F "#{session_name}"`,
                    env,
                ),
                String,
            )
            @test chomp(listed) == "bare"
        finally
            stopped = socket_default_stop(server, default, env)
        end
        @test stopped
        @test !ispath(default)
    end
end

@testset "each variable puts the server on its socket and leaves the default empty" begin
    uid_directory = joinpath(ENV["TMUX_TMPDIR"], "tmux-$(Libc.getuid())")
    default = joinpath(uid_directory, "default")
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="h-") do home
        env = socket_default_env(home)
        path = joinpath(home, "env.sock")
        name = "ltj-env-name"
        cases = (
            ("LIBTMUX_SOCKET_PATH" => path, path),
            ("LIBTMUX_SOCKET" => name, joinpath(uid_directory, name)),
        )
        for (variable, socket) in cases
            server = Server(env=Dict(variable); tmux=SOCKET_DEFAULT_TMUX)
            stopped = false
            try
                socket_default_session(server, env, "chosen")
                @test issocket(socket)
                @test !ispath(default)
            finally
                stopped = socket_default_stop(server, socket, env)
            end
            @test stopped
        end
        # With both set the path wins, and the named socket is never made.
        server = Server(
            env=Dict("LIBTMUX_SOCKET_PATH" => path, "LIBTMUX_SOCKET" => name);
            tmux=SOCKET_DEFAULT_TMUX,
        )
        stopped = false
        try
            socket_default_session(server, env, "both")
            @test issocket(path)
            @test !ispath(joinpath(uid_directory, name)) && !ispath(default)
        finally
            stopped = socket_default_stop(server, path, env)
        end
        @test stopped
    end
end

@testset "a socket named in the call beats the variables on a real server" begin
    uid_directory = joinpath(ENV["TMUX_TMPDIR"], "tmux-$(Libc.getuid())")
    mktempdir(ENV["TMUX_TMPDIR"]; prefix="h-") do home
        env = socket_default_env(home)
        explicit = joinpath(home, "explicit.sock")
        variables = Dict("LIBTMUX_SOCKET_PATH" => joinpath(home, "env.sock"))
        merge!(variables, Dict("LIBTMUX_SOCKET" => "ltj-env-name"))
        server = Server(socket_path=explicit, env=variables, tmux=SOCKET_DEFAULT_TMUX)
        stopped = false
        try
            socket_default_session(server, env, "explicit")
            @test issocket(explicit)
            @test !ispath(joinpath(home, "env.sock"))
            @test !ispath(joinpath(uid_directory, "ltj-env-name"))
        finally
            stopped = socket_default_stop(server, explicit, env)
        end
        @test stopped
    end
end

@testset "inside tmux a server that names no socket follows TMUX" begin
    OwnedTmux.with_tmux() do fixture
        server = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        # The second session is the one tmux picks when nothing names a pane.
        new_session(server; name="first", command=["/bin/cat"])
        new_session(server; name="second", command=["/bin/cat"])
        rows = run_command(server, "list-panes", "-a", "-F", "#{session_name} #{pane_id}")
        pane = Dict(split(line, ' ') |> Tuple for line in eachline(IOBuffer(rows.stdout)))
        inside = merge(
            fixture.env,
            Dict(
                "TMUX" => "$(fixture.socket),$(getpid(fixture.process)),0",
                "TMUX_PANE" => pane["first"],
            ),
        )
        bare = Server(env=Dict{String,String}(); tmux=fixture.tmux)
        listed = run_command(bare, "list-sessions", "-F", "#{session_name}"; env=inside)
        @test sort(split(chomp(String(copy(listed.stdout))), '\n')) == ["first", "second"]
        # TMUX_PANE comes along too: tmux resolves a command that names no target
        # to that pane, not to the most recent session.
        shown = run_command(bare, "display-message", "-p", "#{session_name}"; env=inside)
        @test chomp(String(copy(shown.stdout))) == "first"
        # A named socket takes neither variable along.
        named = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        result = run_command(named, "display-message", "-p", "#{session_name}"; env=inside)
        @test chomp(String(copy(result.stdout))) == "second"
        other = Server(socket_name="ltj-absent", tmux=fixture.tmux)
        absent = run_command(other, "list-sessions"; env=inside, check=false)
        @test absent.exitcode != 0
        # Outside tmux the same server looks under the sandbox, not at the fixture.
        away = run_command(bare, "list-sessions"; env=fixture.env, check=false)
        @test away.exitcode != 0
        @test !occursin("first", String(copy(away.stdout)))
    end
end

# The attach drops TMUX, so a server that names no socket leaves tmux nothing to
# follow; the connection names the socket of the daemon the session came from.
@testset "a control connection from a server that names no socket attaches to the captured daemon" begin
    OwnedTmux.with_tmux() do fixture
        fixed = Server(socket_path=fixture.socket, tmux=fixture.tmux)
        session = new_session(fixed; name="control", command=["/bin/cat"])
        bare = Server(env=Dict{String,String}(); tmux=fixture.tmux)
        inside = "TMUX" => "$(fixture.socket),$(getpid(fixture.process)),0"
        withenv(inside) do
            release = LibTmux._daemon_version(bare, LibTmux._client_environment(ENV, bare))
            if LibTmux._version_at_least(release, LibTmux.CONTROL_MINIMUM_TMUX)
                open_control(bare, session) do connection
                    @test connection.identity.socket_path == fixture.socket
                end
            end
        end
    end
end
