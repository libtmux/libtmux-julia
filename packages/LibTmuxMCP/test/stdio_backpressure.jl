# Outer regression: default Julia stdio retires after EOF with a stopped reader.
#
# usage: julia --project=PROJECT [--threads=N] stdio_backpressure.jl
#
# Starts stdio_child.jl in a child Julia that serves one very large response, reads
# exactly one byte of it, closes the child's stdin and requires the child to exit
# within 900 ms although its output is still unread. The matrix runs it on its own.

include(joinpath(@__DIR__, "support", "stdio_client.jl"))
using .StdioClient

check(condition, message...) = condition || error(string(message...))

function backpressure()
    started = time()
    julia = joinpath(Sys.BINDIR, Base.julia_exename())
    project = dirname(Base.active_project())
    child = spawn_child([
        julia,
        "--startup-file=no",
        "--project=$project",
        "--threads=$(Threads.nthreads())",
        "--compiled-modules=yes",
        joinpath(@__DIR__, "stdio_child.jl"),
        "backpressure",
    ])
    try
        request(id, method, params=Dict{String,Any}()) = Dict{String,Any}(
            "jsonrpc" => "2.0",
            "id" => id,
            "method" => method,
            "params" => merge(
                Dict{String,Any}(
                    "_meta" => Dict(
                        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                        "io.modelcontextprotocol/clientCapabilities" => Dict(),
                    ),
                ),
                params,
            ),
        )
        send_line(child, request(1, "server/discover"))
        check(receive_line(child)["id"] == 1, "discovery answered")
        send_line(
            child,
            request(2, "tools/call", Dict("name" => "large", "arguments" => Dict())),
        )
        check(read_byte(child, time() + 45) == UInt8('{'), "the large response starts")
        # Exactly one response byte establishes write entry; nothing reads further, so
        # the output cannot drain before the process has retired.
        retired = time()
        close_stdin!(child)
        wait_for_exit(child, 0.9)
        check(
            !process_running(child.process),
            "EOF did not retire the blocked default-stdio writer",
        )
        elapsed = time() - retired
        diagnostics = String(vcat(child.diagnostics, read_rest(child.stderr, 1024 * 1024)))
        check(child.process.exitcode == 0, diagnostics)
        trailing = read_rest(child.stdout, 8 * 1024^2)
        check(
            length(trailing) < 2 * 1024^2,
            "response drained instead of blocking: $(length(trailing)) bytes",
        )
        check(isempty(diagnostics), diagnostics)
        println(
            "PASS eof_retirement_ms=$(round(1000 * elapsed; digits=1)) partial_response_bytes=$(length(trailing) + 1) ",
            "whole_seconds=$(round(time() - started; digits=3)) threads=$(Threads.nthreads())",
        )
    finally
        finish!(child)
    end
end

backpressure()
