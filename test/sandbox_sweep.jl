using Test

# A real server on a socket the sandbox did not choose. The sweep must find it
# wherever it is, stop it with kill-server and see that nothing answers.
function started_server(tmux, directory, socket; bare=false, name=nothing)
    environment = Dict{String,String}(string(k) => string(v) for (k, v) in ENV)
    environment["TMUX_TMPDIR"] = directory
    arguments = name !== nothing ? `-L $name` : bare ? `` : `-S $socket`
    run(
        pipeline(
            setenv(
                `$tmux -f /dev/null $arguments new-session -d /bin/sleep 300`,
                environment,
            );
            stdout=devnull,
            stderr=devnull,
        ),
    )
end

# What a stopped server looks like to a client that asks: no server running.
no_server(tmux, socket) =
    !success(
        pipeline(
            ignorestatus(`$tmux -N -S $socket list-sessions`);
            stdout=devnull,
            stderr=devnull,
        ),
    )

@testset "a server on a custom socket in the sandbox fails the run and is stopped" begin
    sandbox = Main.TestSandbox
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    socket = joinpath(directory, "custom.sock")
    try
        started_server(tmux, directory, socket)
        @test sandbox.answers(socket)
        refusal = try
            sandbox.verify!(env)
        catch error
            error
        end
        @test refusal isa sandbox.Refused
        @test refusal.findings ==
              ["a server was left running on custom.sock in the sandbox"]
        @test !sandbox.answers(socket) && !ispath(socket)
        @test no_server(tmux, socket)
        @test sandbox.verify!(env) === nothing
    finally
        sandbox.stop(socket; tmux)
        rm(directory; recursive=true, force=true)
    end
end

@testset "a client that names no socket leaves a server the sweep stops" begin
    sandbox = Main.TestSandbox
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    default = joinpath(directory, "tmux-$(Libc.getuid())", "default")
    try
        started_server(tmux, directory, default; bare=true)
        @test sandbox.answers(default)
        refusal = try
            sandbox.verify!(env)
        catch error
            error
        end
        @test refusal isa sandbox.Refused
        @test refusal.findings == [
            "a client started without -S or -L and chose tmux-$(Libc.getuid())/default in the sandbox",
        ]
        @test !sandbox.answers(default) && no_server(tmux, default)
    finally
        sandbox.stop(default; tmux)
        rm(directory; recursive=true, force=true)
    end
end

@testset "a server started with -L is a server, not a client with no socket" begin
    sandbox = Main.TestSandbox
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    socket = joinpath(directory, "tmux-$(Libc.getuid())", "named")
    try
        started_server(tmux, directory, socket; name="named")
        @test sandbox.answers(socket)
        refusal = try
            sandbox.verify!(env)
        catch error
            error
        end
        @test refusal isa sandbox.Refused
        @test refusal.findings ==
              ["a server was left running on tmux-$(Libc.getuid())/named in the sandbox"]
        @test !sandbox.answers(socket) && no_server(tmux, socket)
    finally
        sandbox.stop(socket; tmux)
        rm(directory; recursive=true, force=true)
    end
end

@testset "a server that cannot be stopped keeps the sandbox directory" begin
    sandbox = Main.TestSandbox
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict{String,String}()
    directory, _ = sandbox.prepare!(env; roots=(ENV["TMUX_TMPDIR"],))
    socket = joinpath(directory, "frozen.sock")
    patience = sandbox.PATIENCE[]
    pid = 0
    try
        started_server(tmux, directory, socket)
        pid = parse(Int, readchomp(`$tmux -N -S $socket display-message -p '#{pid}'`))
        # A stopped server still accepts connections but never answers kill-server.
        ccall(:kill, Cint, (Cint, Cint), pid, 19)
        sandbox.PATIENCE[] = 0.5
        findings, kept = sandbox.sweep(directory; tmux)
        @test kept == ["frozen.sock"]
        @test findings == ["a server still answers on frozen.sock after kill-server"]
        @test issocket(socket) && isdir(directory)
    finally
        sandbox.PATIENCE[] = patience
        pid == 0 || ccall(:kill, Cint, (Cint, Cint), pid, 18)
        sandbox.stop(socket; tmux)
        @test sandbox.gone(socket) && no_server(tmux, socket)
        rm(directory; recursive=true, force=true)
    end
end
