using Test
include(joinpath(@__DIR__, "..", "owned-process.jl"))
using .OwnedProcess
const O = OwnedProcess

environment() = Dict{String,String}(ENV)

# A child that runs `code` in the test's own Julia. The tests start no shell.
julia(code) = [joinpath(Sys.BINDIR, Base.julia_exename()), "--startup-file=no", "-e", code]

"Read a descriptor until EOF, waiting in `poll!`, and give up after `seconds`."
function read_until_eof(fd; seconds=10.0)
    collected = UInt8[]
    deadline = monotonic() + seconds
    while monotonic() < deadline
        poll!([PollFD(fd, POLLIN, 0)], deadline - monotonic())
        chunk = read_available(fd)
        chunk === nothing && continue
        isempty(chunk) && return collected, true
        append!(collected, chunk)
    end
    collected, false
end

function finish(child)
    wait_exit(child, 10) || error("the child did not exit")
    wait(child.watcher)
    code, usage = reap!(child)
    out, _ = read_until_eof(child.stdout)
    err, _ = read_until_eof(child.stderr)
    foreach(
        close_fd,
        (child.stdin, child.stdout, child.stderr, child.wake_read, child.wake_write),
    )
    (; code, usage, out=String(out), err=String(err))
end

open_descriptors() = Sys.islinux() ? length(readdir("/proc/self/fd")) : 0

@testset "owned process" begin
    @testset "a child's output, exit code and accounting" begin
        child = spawn_child(
            julia("println(\"out\"); println(stderr, \"err\"); exit(3)");
            env=environment(),
        )
        done = finish(child)
        @test done.code == 3
        @test done.out == "out\n" && done.err == "err\n"
        @test done.usage.max_rss_bytes > 0 && done.usage.user_seconds >= 0
        @test child.exit_ns !== nothing && child.exit_ns >= child.started_ns
    end

    @testset "a signal is reported as a negative code" begin
        child = spawn_child(julia("ccall(:raise, Cint, (Cint,), 9)"); env=environment())
        @test finish(child).code == -9
    end

    @testset "the wait4 watcher reaps and keeps the accounting" begin
        child = spawn_child(julia("exit(4)"); env=environment(), reap=true)
        wait_exit(child, 10)
        wait(child.watcher)
        @test child.status !== nothing && O.exit_code(child.status) == 4
        @test O.usage_fields(child.usage).max_rss_bytes > 0
        foreach(
            close_fd,
            (child.stdin, child.stdout, child.stderr, child.wake_read, child.wake_write),
        )
    end

    @testset "the child sees exactly the given environment and default signals" begin
        env = environment()
        env["LTJ_OWNED_PROCESS_PROBE"] = "kept"
        only_these = Dict(name => ENV[name] for name in ("PATH",))
        only_these["LTJ_OWNED_PROCESS_PROBE"] = "kept"
        child = spawn_child(["env"]; env=only_these)
        @test Set(split(finish(child).out, '\n'; keepempty=false)) ==
              Set(["$name=$value" for (name, value) in only_these])
        if Sys.islinux()
            # Julia ignores SIGPIPE and blocks signals; a child starts with neither. A
            # child that is not Julia reports its own masks.
            child =
                spawn_child(["grep", "-E", "^Sig(Ign|Blk)", "/proc/self/status"]; env=env)
            masks = Dict(
                split(line, r":\s+")[1] =>
                    parse(UInt64, split(line, r":\s+")[2]; base=16) for
                line in split(finish(child).out, '\n'; keepempty=false)
            )
            @test masks["SigIgn"] & (UInt64(1) << (O.SIGPIPE - 1)) == 0
            @test masks["SigBlk"] == 0
        end
    end

    @testset "stdin is /dev/null, or a pipe the parent writes" begin
        child = spawn_child(["cat"]; env=environment())
        @test finish(child).out == ""
        child = spawn_child(["cat"]; env=environment(), stdin=:pipe)
        @test write_available(child.stdin, codeunits("piped\n")) == 6
        close_fd(child.stdin)
        child.stdin = -1
        @test finish(child).out == "piped\n"
    end

    @testset "the child leads a group that one signal retires" begin
        # `sleep` inherits the output pipe, so the pipe stays open until it is killed.
        child = spawn_child(
            julia(
                "run(`sleep 30`; wait=false); println(\"started\"); flush(stdout); sleep(30)",
            );
            env=environment(),
        )
        poll!([PollFD(child.stdout, POLLIN, 0)], 10)
        @test String(read_available(child.stdout)) == "started\n"
        poll!([PollFD(child.stdout, POLLIN, 0)], 0.05)
        @test read_available(child.stdout) === nothing
        signal_group(child, Base.SIGKILL)
        _, ended = read_until_eof(child.stdout)
        @test ended
        @test finish(child).code == -9
        # A group with no process left is not an error.
        signal_group(child, Base.SIGKILL)
    end

    @testset "a collection does not wait for a call that blocks on the child" begin
        # Base's @threadcall leaves its thread GC unsafe, so GC.gc() would wait for the exit.
        child = spawn_child(
            julia("println(\"ready\"); flush(stdout); sleep(5)");
            env=environment(),
            reap=true,
        )
        poll!([PollFD(child.stdout, POLLIN, 0)], 10)
        @test (@elapsed GC.gc()) < 2.5
        signal_group(child, Base.SIGKILL)
        @test finish(child).code == -9
    end

    @testset "wait_exit gives up, and a poll with nothing to read returns zero" begin
        child = spawn_child(["sleep", "30"]; env=environment())
        @test !wait_exit(child, 0.05)
        @test poll!([PollFD(child.stdout, POLLIN, 0)], 0.01) == 0
        signal_group(child, Base.SIGKILL)
        @test finish(child).code == -9
    end

    @testset "a failed spawn throws and leaks no descriptor" begin
        before = open_descriptors()
        @test_throws SystemError spawn_child(
            ["/nonexistent/ltj-owned-process"];
            env=environment(),
        )
        @test_throws SystemError spawn_child(["ltj-no-such-command"]; env=environment())
        @test_throws ArgumentError spawn_child(["sh\0x"]; env=environment())
        @test open_descriptors() == before
    end

    @testset "wait status and rusage decoding" begin
        @test O.exit_code(7 << 8) == 7
        @test O.exit_code(9) == -9
        usage = zeros(UInt8, 256)
        # ru_utime 1.5 s, ru_stime 0.25 s, ru_maxrss 2048 in the system's own unit.
        for (offset, value) in (
            (0, Int64(1)),
            (8, Int64(500000)),
            (16, Int64(0)),
            (24, Int64(250000)),
            (32, Int64(2048)),
        )
            usage[(offset+1):(offset+8)] .= reinterpret(UInt8, [value])
        end
        fields = O.usage_fields(usage)
        @test fields.user_seconds == 1.5 && fields.system_seconds == 0.25
        @test fields.max_rss_bytes == (Sys.isapple() ? 2048 : 2048 * 1024)
    end
end
