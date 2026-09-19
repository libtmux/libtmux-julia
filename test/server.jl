@testset "explicit server selection" begin
    @test isdefined(LibTmux, :Server)
    if isdefined(LibTmux, :Server)
        @test_throws ArgumentError Server()
        @test_throws ArgumentError Server(socket_path="/tmp/a", socket_name="b")
        @test_throws ArgumentError Server(socket_path="")
        @test_throws ArgumentError Server(socket_name="bad/name")
        @test_throws ArgumentError Server(socket_path="bad\0name")
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
        named = from_env(env=Dict("TMUX" => "/tmp/with,comma,123,0"))
        @test named.socket_path == "/tmp/with,comma"
        @test from_env(env=Dict{String,String}()).socket_name == "default"
        @test from_env(env=Dict("TMUX" => "invalid"); socket_name="explicit").socket_name ==
              "explicit"
        @test_throws ArgumentError from_env(env=Dict("TMUX" => "invalid"))
    end
end
