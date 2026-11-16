using Test
import JSON
include(joinpath(@__DIR__, "..", "bench-mcp-client.jl"))
using .BenchMCPClient
const M = BenchMCPClient
const OP = M.OwnedProcess

# The launcher is a stand-in that answers the benchmark's requests. The client runs one
# executable, so the file written here only names the test's own Julia, which runs
# fake-launcher.jl.
function stand_in_launcher(directory)
    launcher = joinpath(directory, "launcher")
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    fake = joinpath(@__DIR__, "fake-launcher.jl")
    write(launcher, "#!/usr/bin/env -S $julia --startup-file=no\ninclude($(repr(fake)))\n")
    chmod(launcher, 0o755)
    launcher
end

function with_variant(action, variant)
    previous = get(ENV, "LTJ_FAKE_LAUNCHER", nothing)
    ENV["LTJ_FAKE_LAUNCHER"] = variant
    try
        action()
    finally
        previous === nothing ? delete!(ENV, "LTJ_FAKE_LAUNCHER") :
        (ENV["LTJ_FAKE_LAUNCHER"] = previous)
    end
end

function refusal(action)
    try
        action()
    catch error
        error isa M.MeasurementError && return error.message
        rethrow()
    end
    nothing
end

# A child that never reads or answers.
idle_client(timeout=10) = M.Client(["sleep", "30"], OP.monotonic() + timeout)

options(launcher; warm=2) = (;
    launcher,
    socket="/tmp/ltj-bench-socket",
    tmux="tmux",
    pane="%1",
    warm,
    startup=30.0,
    results=Dict{String,Any}[],
)

@testset "MCP benchmark client" begin
    @testset "framing" begin
        data = JSON.parse(
            String(
                M.frame("one", "tools/call", Dict("_meta" => Dict("progressToken" => "p"))),
            ),
        )
        @test data["params"]["_meta"]["progressToken"] == "p"
        @test data["params"]["_meta"]["io.modelcontextprotocol/protocolVersion"] ==
              M.PROTOCOL
        @test data["id"] == "one" && data["jsonrpc"] == "2.0"
        notification = M.frame(nothing, "notifications/cancelled")
        @test !haskey(JSON.parse(String(copy(notification))), "id") &&
              last(notification) == 0x0a
        @test M.frame(1, "x") == M.frame(1, "x", Dict{String,Any}())
    end

    @testset "checking a reply" begin
        @test M.checked_result(Dict("result" => Dict("ok" => true)))["ok"]
        @test refusal(() -> M.checked_result(Dict("error" => Dict()))) ==
              "protocol request failed"
        @test refusal(() -> M.checked_result(Dict("id" => 1))) == "protocol request failed"
        long = repeat("c", 100)
        failure = Dict(
            "result" => Dict(
                "isError" => true,
                "structuredContent" => Dict("error" => Dict("code" => long)),
            ),
        )
        @test refusal(() -> M.checked_result(failure)) == "tool failed: " * repeat("c", 64)
    end

    @testset "frames that arrive in pieces" begin
        client = idle_client()
        try
            raw = Vector{UInt8}("{\"id\":1,\"result\":{\"text\":\"λ\"}}\n")
            M.accept_stdout!(client, raw[1:(end-2)])
            @test isempty(client.messages)
            M.accept_stdout!(client, raw[(end-1):end])
            @test client.messages[1].data["result"]["text"] == "λ"
            @test client.stdout_bytes == length(raw)
            @test M.checked_result(client.messages[1].data)["text"] == "λ"
            # A queue nobody reads is bounded.
            for _ = 1:(M.MESSAGE_QUEUE_LIMIT-1)
                M.accept_stdout!(client, Vector{UInt8}("{\"id\":2}\n"))
            end
            @test refusal(() -> M.accept_stdout!(client, Vector{UInt8}("{\"id\":3}\n"))) ==
                  "unconsumed reply queue exceeded bound"
        finally
            close(client)
        end
        client = idle_client()
        try
            @test refusal(
                () -> M.accept_stdout!(client, zeros(UInt8, M.FRAME_LIMIT + 1)),
            ) == "stdout frame exceeded byte bound"
        finally
            close(client)
        end
    end

    mktempdir(; prefix="ltj-mcp-client-") do directory
        launcher = stand_in_launcher(directory)
        command(opts) = M.launcher_command(opts)

        @testset "requests against a process that stays silent or fails" begin
            # A paused stdout stays unread while the client writes, and is drained only
            # after the exit.
            client = with_variant("late-reply") do
                M.Client([launcher], OP.monotonic() + 30)
            end
            try
                OP.poll!([OP.PollFD(client.child.stdout, OP.POLLIN, 0)], 30)
                M.pause_stdout!(client)
                M.send!(client, "x", "ping")
                @test client.stdout_bytes == 0 && isempty(client.messages)
                M.eof_and_join!(client)
                @test client.stdout_bytes == length("{\"id\":\"late\"}\n") &&
                      isempty(client.messages)
            finally
                close(client)
            end

            client = idle_client()
            try
                @test refusal(() -> M.request!(client, "silent", "ping"; timeout=0.2)) ==
                      "event deadline exceeded"
            finally
                close(client)
            end

            client = with_variant("silent-exit") do
                M.Client([launcher], OP.monotonic() + 30)
            end
            try
                @test refusal(() -> M.eof_and_join!(client)) ==
                      "launcher exit was not clean"
            finally
                close(client)
            end

            client = with_variant("diagnostics") do
                M.Client([launcher], OP.monotonic() + 30)
            end
            try
                M.eof_and_join!(client)
                @test client.stderr_bytes == length("diagnostics\n")
            finally
                close(client)
            end
        end

        @testset "a request is answered and the exit is clean" begin
            client = M.Client([launcher], OP.monotonic() + 60)
            try
                reply, bytes = M.request!(client, "test", "server/discover"; timeout=30)
                @test M.checked_result(reply)["supportedVersions"][1] == M.PROTOCOL &&
                      bytes > 0
                eof_ns, exit_ns = M.eof_and_join!(client)
                @test exit_ns >= eof_ns
                @test M.report(client)["exit_code"] == 0 && client.stderr_bytes == 0
                @test M.report(client)["samples"][1]["phase"] == "server/discover"
            finally
                close(client)
            end
        end

        @testset "the workflow sample" begin
            opts = options(launcher)
            result =
                M.run_sample(command(opts), opts, OP.monotonic() + 60; backpressure=false)
            @test result["status"] == "pass" && result["exit_code"] == 0
            @test result["application_owned_session_created"] === true
            @test result["supported_versions"] == ["2026-07-28", "2025-11-25"]
            @test [sample["phase"] for sample in result["samples"]] == [
                "discovery",
                "catalog",
                "first_list",
                "first_capture",
                "warm_list",
                "warm_capture",
                "warm_list",
                "warm_capture",
                "create_session",
                "wait_progress",
                "unrelated_list_during_wait",
                "reader_discovery_after_cancel",
            ]
            @test result["process_to_discovery_ns"] > 0 && result["eof_to_exit_ns"] > 0
            @test result["cancel_to_exit_ns"] >= result["eof_to_exit_ns"]
            @test result["stderr_bytes"] == 0 && result["child_max_rss_bytes"] > 0
            @test only(opts.results) === result
        end

        @testset "the stopped-reader sample" begin
            opts = options(launcher)
            result =
                M.run_sample(command(opts), opts, OP.monotonic() + 60; backpressure=true)
            if Sys.islinux()
                @test result["status"] == "pass" && result["backpressure_proven"] === true
                @test result["bytes_consumed_before_eof"] == 1
                @test result["pipe_capacity_bytes"] < result["expected_reply_bytes"]
                @test result["original_pipe_capacity_bytes"] >=
                      result["pipe_capacity_bytes"]
                # The reply did not fit the pipe, so most of it was never read.
                @test 0 <
                      result["bytes_drained_after_exit"] <
                      result["expected_reply_bytes"]
                @test result["writer_entry_ns"] > 0 && result["eof_to_exit_ns"] > 0
            else
                @test result["status"] == "unsupported_pipe_capacity"
            end
        end

        @testset "a reply that fits the pipe proves nothing" begin
            opts = options(launcher)
            result = with_variant("small-catalog") do
                M.run_sample(command(opts), opts, OP.monotonic() + 60; backpressure=true)
            end
            @test result["status"] == (
                Sys.islinux() ? "inconclusive_reply_fits_pipe" :
                "unsupported_pipe_capacity"
            )
            @test !haskey(result, "backpressure_proven")
        end

        @testset "a changed fixture or an unclean exit fails the sample and is recorded" begin
            opts = options(launcher)
            message = with_variant("two-panes") do
                refusal(
                    () -> M.run_sample(
                        command(opts),
                        opts,
                        OP.monotonic() + 60;
                        backpressure=false,
                    ),
                )
            end
            @test message == "fixture pane policy changed"
            @test only(opts.results)["status"] == "fail" &&
                  only(opts.results)["error"] == message
            opts = options(launcher)
            message = with_variant("silent-exit") do
                refusal(
                    () -> M.run_sample(
                        command(opts),
                        opts,
                        OP.monotonic() + 60;
                        backpressure=false,
                    ),
                )
            end
            @test message == "launcher exit was not clean"
            @test only(opts.results)["status"] == "fail"
        end

        @testset "the command line, the report file and its refusal to overwrite" begin
            output = joinpath(directory, "client.json")
            arguments = [
                "--launcher",
                launcher,
                "--socket",
                "/tmp/ltj-bench-socket",
                "--tmux",
                "tmux",
                "--pane",
                "%1",
                "--output",
                output,
                "--warm",
                "1",
            ]
            @test M.main(arguments) == 0
            report = JSON.parsefile(output)
            @test report["status"] == (Sys.islinux() ? "pass" : "partial")
            @test [sample["kind"] for sample in report["samples"]] == ["workflow", "backpressure"]
            @test report["protocol"] == M.PROTOCOL && report["client_driver_body_ns"] > 0
            redirect_stderr(devnull) do
                @test M.main(arguments) == 1
                @test M.main(["--launcher", launcher]) == 2
                @test M.main([
                    "--launcher",
                    launcher,
                    "--socket",
                    "s",
                    "--tmux",
                    "t",
                    "--pane",
                    "%1",
                    "--output",
                    joinpath(directory, "x.json"),
                    "--warm",
                    "65",
                ]) == 2
            end
            @test JSON.parsefile(output) == report
        end
    end
end
