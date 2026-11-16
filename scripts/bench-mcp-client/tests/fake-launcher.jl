# A stand-in for the installed MCP launcher, for the client's tests. It answers the
# requests the benchmark client sends and ignores the launcher's command line.
#
# LTJ_FAKE_LAUNCHER selects a variant: `small-catalog` makes the tool catalog fit any
# pipe, `two-panes` lists a pane the client does not own and `silent-exit` leaves with
# status 3 once its stdin closes.
#
# It parses requests with regular expressions, so it needs no JSON package. Replies go
# through `write(2)` on a pool thread. A reply that fills the pipe blocks only its own
# task, and the process still leaves when stdin closes.

include(joinpath(@__DIR__, "..", "..", "owned-process", "owned-process.jl"))
using .OwnedProcess: @blocking_ccall

const VARIANT = get(ENV, "LTJ_FAKE_LAUNCHER", "")

# Julia opens stdout non-blocking. A reply that fills the pipe must wait for the reader
# instead of failing with EAGAIN, so the descriptor goes back to blocking mode.
ccall(:fcntl, Cint, (Cint, Cint, Cint...), 1, 4, 0) == 0 || error("fcntl")

field(line, pattern) =
    (found=match(pattern, line); found === nothing ? nothing : found.captures[1])

function reply(identity, result)
    "{\"jsonrpc\":\"2.0\",\"id\":$identity,\"result\":$result}\n"
end

function emit(text)
    bytes = Vector{UInt8}(codeunits(text))
    GC.@preserve bytes begin
        offset = 0
        while offset < length(bytes)
            written = @blocking_ccall(
                :write,
                Cssize_t,
                (Cint, Ptr{UInt8}, Csize_t),
                1,
                pointer(bytes) + offset,
                length(bytes) - offset
            )
            written < 0 && return nothing
            offset += written
        end
    end
    nothing
end

function catalog()
    padding = VARIANT == "small-catalog" ? "" : repeat("x", 20_000)
    "{\"tools\":[{\"name\":\"list_panes\",\"description\":\"$padding\"}]}"
end

function answer(line)
    method = field(line, r"\"method\":\"([^\"]+)\"")
    identity = field(line, r"\"id\":(\"[^\"]*\"|\d+)")
    if method == "server/discover"
        reply(identity, "{\"supportedVersions\":[\"2026-07-28\",\"2025-11-25\"]}")
    elseif method == "tools/list"
        reply(identity, catalog())
    elseif method == "tools/call"
        # The arguments may carry a `name` of their own, so take the one that names a tool.
        names = [found.captures[1] for found in eachmatch(r"\"name\":\"([^\"]+)\"", line)]
        tool = findfirst(
            in(("list_panes", "capture_pane", "create_session", "wait_for_text")),
            names,
        )
        tool = tool === nothing ? nothing : names[tool]
        content(body) = reply(identity, "{\"isError\":false,\"structuredContent\":$body}")
        if tool == "list_panes"
            panes =
                VARIANT == "two-panes" ? "[{\"caller\":true},{\"caller\":false}]" :
                "[{\"caller\":true}]"
            content("{\"panes\":$panes}")
        elseif tool == "capture_pane"
            content("{\"text\":\"data\"}")
        elseif tool == "create_session"
            content("{\"ownership\":\"application\"}")
        elseif tool == "wait_for_text"
            token = field(line, r"\"progressToken\":\"([^\"]*)\"")
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/progress\",\"params\":{\"progressToken\":\"$token\",\"message\":\"waiting\"}}\n"
        else
            reply(
                identity,
                "{\"isError\":true,\"structuredContent\":{\"error\":{\"code\":\"unknown_tool\"}}}",
            )
        end
    else
        nothing
    end
end

for line in eachline(stdin)
    text = answer(line)
    text === nothing || @async emit(text)
end
# A reply may still be blocked on a full pipe; leave without flushing it.
ccall(:_exit, Cvoid, (Cint,), VARIANT == "silent-exit" ? 3 : 0)
