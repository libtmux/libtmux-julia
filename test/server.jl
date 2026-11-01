@testset "explicit server selection" begin
    @test isdefined(LibTmux, :Server)
    if isdefined(LibTmux, :Server)
        none = Dict{String,String}()
        @test_throws ArgumentError Server(socket_path="/tmp/a", socket_name="b", env=none)
        @test_throws ArgumentError Server(socket_path="", env=none)
        @test_throws ArgumentError Server(socket_name="bad/name", env=none)
        @test_throws ArgumentError Server(socket_name="", env=none)
        @test_throws ArgumentError Server(socket_path="bad\0name", env=none)
        server = Server(socket_path="/tmp/libtmux-julia-no-server", tmux="absent-tmux")
        @test server.socket_path == "/tmp/libtmux-julia-no-server"
        @test occursin("libtmux-julia-no-server", sprint(show, server))
        @test LibTmux._argv(server, ["list-panes", "-a"]) == [
            "absent-tmux",
            "-u",
            "-S",
            "/tmp/libtmux-julia-no-server",
            "--",
            "list-panes",
            "-a",
        ]
        named = Server(socket_name="work", tmux="absent-tmux")
        @test LibTmux._argv(named, ["list-panes"]) ==
              ["absent-tmux", "-u", "-L", "work", "--", "list-panes"]
        named = from_env(env=Dict("TMUX" => "/tmp/with,comma,123,0"))
        @test named.socket_path == "/tmp/with,comma"
        @test from_env(env=Dict{String,String}()).socket_name == "default"
        @test from_env(env=Dict("TMUX" => "invalid"); socket_name="explicit").socket_name ==
              "explicit"
        @test_throws ArgumentError from_env(env=Dict("TMUX" => "invalid"))
    end
end

@testset "a server that names no socket passes tmux neither -S nor -L" begin
    server = Server(env=Dict{String,String}(), tmux="absent-tmux")
    @test server.socket_path === nothing && server.socket_name === nothing
    @test LibTmux._argv(server, ["list-panes", "-a"]) ==
          ["absent-tmux", "-u", "--", "list-panes", "-a"]
    @test sprint(show, server) == "Server(tmux=\"absent-tmux\")"
    # Variables that name a server of the caller's own select nothing here.
    unrelated = Dict("TMUX" => "/tmp/pane,1,0", "TMUX_PANE" => "%1", "TMUX_TMPDIR" => "/x")
    @test LibTmux._argv(Server(env=unrelated, tmux="t"), ["kill-server"]) ==
          ["t", "-u", "--", "kill-server"]
end

@testset "LIBTMUX_SOCKET_PATH and LIBTMUX_SOCKET select the socket when none is named" begin
    by_path =
        Server(env=Dict("LIBTMUX_SOCKET_PATH" => "/tmp/libtmux-julia-env.sock"), tmux="t")
    @test by_path.socket_path == "/tmp/libtmux-julia-env.sock"
    @test by_path.socket_name === nothing
    @test LibTmux._argv(by_path, ["list-panes"]) ==
          ["t", "-u", "-S", "/tmp/libtmux-julia-env.sock", "--", "list-panes"]
    by_name = Server(env=Dict("LIBTMUX_SOCKET" => "work"), tmux="t")
    @test by_name.socket_name == "work" && by_name.socket_path === nothing
    @test LibTmux._argv(by_name, ["list-panes"]) ==
          ["t", "-u", "-L", "work", "--", "list-panes"]
    @test sprint(show, by_name) == "Server(socket_name=\"work\", tmux=\"t\")"
    # A relative path is taken from the current directory, as for an explicit one.
    relative = Server(env=Dict("LIBTMUX_SOCKET_PATH" => "env.sock"))
    @test relative.socket_path == abspath("env.sock")
    # Without an env argument the process environment is read.
    withenv("LIBTMUX_SOCKET" => "from-process", "LIBTMUX_SOCKET_PATH" => nothing) do
        @test Server().socket_name == "from-process"
    end
    withenv("LIBTMUX_SOCKET" => nothing, "LIBTMUX_SOCKET_PATH" => "/tmp/from-process") do
        @test Server().socket_path == "/tmp/from-process"
    end
    withenv("LIBTMUX_SOCKET" => nothing, "LIBTMUX_SOCKET_PATH" => nothing) do
        @test LibTmux._selector(Server()) == String[]
    end
end

@testset "the path wins when both variables are set" begin
    both = Server(
        env=Dict(
            "LIBTMUX_SOCKET_PATH" => "/tmp/libtmux-julia-both",
            "LIBTMUX_SOCKET" => "w",
        ),
    )
    @test both.socket_path == "/tmp/libtmux-julia-both" && both.socket_name === nothing
end

@testset "a blank variable counts as unset, each one alone" begin
    for blank in ("", " ", "\t \n")
        @test LibTmux._selector(Server(env=Dict("LIBTMUX_SOCKET_PATH" => blank))) ==
              String[]
        @test LibTmux._selector(Server(env=Dict("LIBTMUX_SOCKET" => blank))) == String[]
        named = Server(env=Dict("LIBTMUX_SOCKET_PATH" => blank, "LIBTMUX_SOCKET" => "w"))
        @test named.socket_name == "w" && named.socket_path === nothing
        pathed = Server(env=Dict("LIBTMUX_SOCKET" => blank, "LIBTMUX_SOCKET_PATH" => "/p"))
        @test pathed.socket_path == "/p" && pathed.socket_name === nothing
    end
    # Any other value is used as written, padding included.
    @test Server(env=Dict("LIBTMUX_SOCKET" => " w ")).socket_name == " w "
end

@testset "a socket named in the call leaves both variables unread" begin
    env = Dict("LIBTMUX_SOCKET_PATH" => "/tmp/from-env", "LIBTMUX_SOCKET" => "from-env")
    byname = Server(socket_name="explicit", env=env)
    @test byname.socket_name == "explicit" && byname.socket_path === nothing
    bypath = Server(socket_path="/tmp/explicit", env=env)
    @test bypath.socket_path == "/tmp/explicit" && bypath.socket_name === nothing
    # A variable that would be refused is not read at all.
    bad = Dict("LIBTMUX_SOCKET" => "a/b")
    @test Server(socket_path="/tmp/explicit", env=bad).socket_path == "/tmp/explicit"
    @test Server(socket_name="explicit", env=bad).socket_name == "explicit"
    @test_throws ArgumentError Server(socket_path="/tmp/a", socket_name="b", env=env)
end

@testset "a variable that cannot be used is refused by name and never by value" begin
    refusal = try
        Server(env=Dict("LIBTMUX_SOCKET" => "decoy-secret/name"))
    catch error
        error
    end
    @test refusal isa ArgumentError
    @test occursin("LIBTMUX_SOCKET", refusal.msg) && !occursin("decoy-secret", refusal.msg)
    @test_throws ArgumentError Server(env=Dict("LIBTMUX_SOCKET_PATH" => "a\0b"))
    @test_throws ArgumentError Server(env=Dict("LIBTMUX_SOCKET" => "a\0b"))
end

@testset "from_env asks for the TMUX socket and reads neither variable" begin
    env = Dict("LIBTMUX_SOCKET_PATH" => "/tmp/ignored", "LIBTMUX_SOCKET" => "ignored")
    @test from_env(env=env).socket_name == "default"
    inside = merge(env, Dict("TMUX" => "/tmp/pane,1,0"))
    @test from_env(env=inside).socket_path == "/tmp/pane"
end

@testset "tmux follows TMUX only for a server that names no socket" begin
    env = Dict("LANG" => "C", "TMUX" => "/tmp/pane,1,0", "TMUX_PANE" => "%3")
    stripped = Dict("LANG" => "C")
    bare = Server(env=Dict{String,String}())
    @test LibTmux._client_environment(env, bare) == env
    @test LibTmux._client_environment(env, Server(socket_name="work")) == stripped
    @test LibTmux._client_environment(env, Server(socket_path="/tmp/s")) == stripped
    @test LibTmux._client_environment(env) == stripped
end
