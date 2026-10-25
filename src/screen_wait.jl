# Polling pane-text wait: reads the visible screen with one tmux invocation per
# tick, on every supported release, without a control client.

"""
One accepted screen wait. `text` is the screen of the matching read, cut to a
tail of at most `max_bytes` bytes, and `dropped_bytes` counts the bytes cut
from its head. When `max_bytes` cuts the screen, the match can lie in the
dropped head, so `text` need not contain it.
`matched_at_entry` is `true` exactly when the match was on the entry read, and
then `source == :baseline`; otherwise `source == :output`.

A screen wait has no stream, so unlike [`OutputWaitResult`](@ref) it carries
no cursor and no received or pending byte counts. A match is evidence that the
text was on the screen, not that a process succeeded.
"""
struct ScreenWaitResult
    text::String
    source::Symbol
    matched_at_entry::Bool
    dropped_bytes::Int
end

"""
A screen wait that ended because the pane or the tmux server is gone. `reason`
is `:pane_exited` (the pane is dead, or tmux no longer knows it) or
`:server_exited`; `text` is the last screen the wait read, cut to the wait's
`max_bytes`. [`OutputWaitEnded`](@ref) is the counterpart for stream waits.
"""
struct ScreenWaitEnded <: LibTmuxError
    reason::Symbol
    text::String
end
Base.showerror(io::IO, error::ScreenWaitEnded) = print(
    io,
    error.reason === :server_exited ? "the tmux server exited during the wait" :
    "the pane exited during the wait",
)

"""
    ScreenWatch

The handle [`watch_screen`](@ref) passes to its block. It holds the entry
screen, the polling interval and the total deadline. It is valid only inside
the block. Every wait on it counts against the entry read taken when the block
opened, so a second wait for the same text returns at once.
"""
mutable struct ScreenWatch
    server::Server
    pane::PaneRef
    interval::Float64
    timeout::Float64
    started::UInt64
    cancel::Any
    entry::String
    entry_alternate::Bool
    entry_state::Symbol
    open::Bool
    timer::Union{Nothing,Timer}
end

_screen_marker() = "libtmux-screen-" * first(replace(string(uuid4()), "-" => ""), 16)

function _screen_remaining(screen::ScreenWatch)
    screen.cancel === nothing ||
        !_iscancelled(screen.cancel) ||
        throw(RequestCancelled(false))
    remaining = screen.timeout - (time_ns() - screen.started) / 1e9
    remaining > 0 || throw(DeadlineExceeded(screen.timeout, false, nothing))
    remaining
end

# The state a failed read names, by the package's own server-gone rules plus
# tmux's pane lookup failures. `nothing` means the read does not say; the
# caller keeps the error.
function _screen_gone(stderr::AbstractString)
    lines = [rstrip(line, '\r') for line in split(stderr, '\n')]
    if _server_gone(stderr) || "lost server" in lines
        return :server_exited
    end
    any(
        line ->
            startswith(line, "can't find pane") ||
            startswith(line, "can't find window") ||
            startswith(line, "can't find session"),
        lines,
    ) && return :pane_exited
    nothing
end

# Read one answer from `result`. Only the read's own marker line counts: the
# fence in front of the command prints its own `unknown command:` line, and
# pane output or a hook cannot forge a random marker.
function _screen_parse(
    result::CommandResult,
    marker::AbstractString,
    pane::AbstractString,
    generation::AbstractString,
)
    prefix = "unknown command: " * marker
    fields = nothing
    for line in _stderr_lines(result)
        startswith(line, prefix) || continue
        body = line[(ncodeunits(prefix)+1):end]
        endswith(body, "|") || continue
        parts = split(body[1:(end-1)], '-')
        length(parts) == 5 && (fields = parts)
    end
    stderr = decode_text(result.stderr; invalid=:replace)
    bytes = result.stdout
    complete = !isempty(bytes) && last(bytes) == UInt8('\n')
    if fields === nothing
        state = _screen_gone(stderr)
        state === nothing && throw(CommandError(result, "wait_for_text"))
        # A capture that finished before the marker failed is still a screen.
        text = complete ? decode_text(bytes; invalid=:replace) : nothing
        return (; text, alternate=false, state)
    end
    complete || throw(CommandError(result, "wait_for_text"))
    id, dead, alternate, pid, started = fields
    pid * ":" * started == generation || throw(StaleReference(pane))
    text = decode_text(bytes; invalid=:replace)
    state =
        id != pane ? :pane_exited :
        dead == "0" ? :live :
        dead == "1" ? :pane_exited : throw(CommandError(result, "wait_for_text"))
    (; text, alternate=alternate == "1", state)
end

# One tick: a capture and a hook-free marker in one tmux invocation.
function _screen_read(screen::ScreenWatch)
    remaining = _screen_remaining(screen)
    id = string(screen.pane.id)
    marker = _screen_marker()
    result = try
        run_command(
            screen.server,
            "capture-pane",
            "-p",
            "-J",
            "-t",
            id,
            ";",
            "run-shell",
            "-C",
            "-t",
            id,
            marker *
            "#{q:pane_id}-#{q:pane_dead}-#{q:alternate_on}-#{q:pid}-#{q:start_time}|";
            check=false,
            cancel=screen.cancel,
            timeout=remaining,
        )
    catch error
        error isa CommandError || rethrow()
        state = _screen_gone(decode_text(error.result.stderr; invalid=:replace))
        state === nothing && rethrow()
        return (; text=nothing, alternate=false, state)
    end
    _screen_parse(result, marker, id, screen.pane.server.generation)
end

function _screen_sleep(screen::ScreenWatch)
    delay = min(screen.interval, _screen_remaining(screen))
    timer = Timer(delay)
    screen.timer = timer
    key = nothing
    try
        key =
            screen.cancel === nothing ? nothing :
            _register_cancel(() -> close(timer), screen.cancel)
        try
            wait(timer)
        catch error
            error isa EOFError || rethrow()
        end
    finally
        close(timer)
        key === nothing || _unregister_cancel(screen.cancel, key)
    end
    nothing
end

function _screen_text(text, max_bytes)
    max_bytes = _output_wait_byte_limit(max_bytes)
    isvalid(text) && !isempty(text) ||
        throw(ArgumentError("wait text must be nonempty valid UTF-8"))
    ncodeunits(text) <= max_bytes ||
        throw(ArgumentError("wait text exceeds the tail limit"))
    (String(text), max_bytes)
end

function _screen_interval(interval, timeout)
    delay, budget = Float64(interval), Float64(timeout)
    isfinite(delay) && delay > 0 ||
        throw(ArgumentError("wait interval must be positive and finite"))
    isfinite(budget) && budget > 0 ||
        throw(ArgumentError("wait timeout must be positive and finite"))
    (delay, budget)
end

"""
    watch_screen(f, server::Server, pane::PaneRef; interval=0.1, timeout=5.0,
                 cancel=nothing)

Take the entry read of `pane`'s visible screen, call `f(screen)` with a
[`ScreenWatch`](@ref) and return its value. Keys sent inside `f` cannot be
counted as already on the entry screen, so a block can act and then wait:

```julia
watch_screen(server, pane) do screen
    send_keys(server, pane, "echo ready", "Enter")
    wait_for_text(screen, "ready")
end
```

`timeout` is one total deadline from the entry read, shared by every wait in
the block; `interval` is the pause between reads. `cancel` is a
[`CancellationToken`](@ref). Every wait in the block counts against the entry
read taken when the block opened, so repeat the same text only with a new
`watch_screen`. The entry read raises [`ScreenWaitEnded`](@ref) when the pane or
server is already gone. A `pane` from another server, or from an earlier
generation of this one, raises `CrossServerReference` or `StaleReference`. The
handle is not valid after `f` returns.
"""
function watch_screen(
    f,
    server::Server,
    pane::PaneRef;
    interval::Real=0.1,
    timeout::Real=5.0,
    cancel=nothing,
)
    delay, budget = _screen_interval(interval, timeout)
    if server.socket_path !== nothing && server.socket_path != pane.server.socket_path
        throw(CrossServerReference(string(pane.id)))
    end
    screen = ScreenWatch(
        server,
        pane,
        delay,
        budget,
        time_ns(),
        cancel,
        "",
        false,
        :live,
        true,
        nothing,
    )
    try
        entry = _screen_read(screen)
        entry.text === nothing && throw(ScreenWaitEnded(entry.state, ""))
        screen.entry = entry.text
        screen.entry_alternate = entry.alternate
        screen.entry_state = entry.state
        f(screen)
    finally
        screen.open = false
    end
end

"""
    wait_for_text(server::Server, pane::PaneRef, text; baseline=false,
                  interval=0.1, timeout=5.0, cancel=nothing, max_bytes=65536)
        -> ScreenWaitResult
    wait_for_text(screen::ScreenWatch, text; baseline=false, max_bytes=65536)
        -> ScreenWaitResult

Wait until the literal `text` is on the pane's visible screen. This method
polls `capture-pane` on every supported tmux release and opens no control
client; the [`ObservationStream`](@ref) method instead reads raw output and
needs tmux 3.7. Every read starts its own tmux client process, so an open
control connection to the same server never carries a read. The server form is
[`watch_screen`](@ref) plus one wait.

`text` must be nonempty valid UTF-8 that fits within `max_bytes`, otherwise
`ArgumentError` is raised before any tmux command runs. `max_bytes` bounds only
the tail of the screen kept in the result; when it cuts the screen, the match
can lie in the dropped head.

By default only text that appears after the entry read counts: the entry read
sets a bar equal to the number of occurrences on the screen, and a later read
matches when its count exceeds the bar. The bar is never lowered, so text that
scrolls off or is repainted cannot invent a match. With `baseline=true` text
already on the entry screen matches at once, with `source == :baseline` and
`matched_at_entry == true`.

Each read is one tmux invocation: `capture-pane -p -J` and a hook-free
`run-shell -C` marker that reports the pane id, whether the pane is dead,
whether it shows the alternate screen and which server generation answered.
`-J` joins wrapped rows. The first read comes before the first sleep, so a `timeout` shorter than `interval` still
reads once. The matcher sees the capture before the marker is acted on, so a
screen read from a pane that has just died (`remain-on-exit`) still matches. A
`pane` that belongs to another server or to an earlier generation of this one
raises `CrossServerReference` or `StaleReference` instead of reading another
pane.

A pane that is dead (`remain-on-exit`), a pane tmux no longer knows, or a
server that is gone raises [`ScreenWaitEnded`](@ref) with the last screen
read. Messages are matched in English, as elsewhere in the package. Cancelling
`cancel` raises `RequestCancelled` and an expired `timeout` raises
`DeadlineExceeded`; neither carries text, and a match found after either is
never reported.

# Limits

- Only the visible screen is read. Text that scrolled off is not seen.
- A repaint shows only its final state; the control stream shows every state.
- While a full-screen program uses the alternate screen, the capture shows only
  that screen. Such a read is not compared: it neither lowers nor raises the
  bar, so a round trip through `less` or `vim` does not invent a match. If the
  entry read is on the alternate screen, the first read back on the normal
  screen sets the bar.
- If an old occurrence scrolls off and a new one arrives between two reads, the
  count does not rise and the wait misses it.
- Typed echo that contains `text` counts as an occurrence. Match on what the
  command prints, not on the command.
- Every read runs the owner's `after-capture-pane` hook, and a hook that
  prints adds its output to the captured text.
"""
function wait_for_text(
    server::Server,
    pane::PaneRef,
    text::AbstractString;
    baseline::Bool=false,
    interval::Real=0.1,
    timeout::Real=5.0,
    cancel=nothing,
    max_bytes::Integer=65536,
)
    _screen_text(text, max_bytes)
    watch_screen(server, pane; interval, timeout, cancel) do screen
        wait_for_text(screen, text; baseline, max_bytes)
    end
end

function wait_for_text(
    screen::ScreenWatch,
    text::AbstractString;
    baseline::Bool=false,
    max_bytes::Integer=65536,
)
    needle, max_bytes = _screen_text(text, max_bytes)
    screen.open || throw(ArgumentError("the screen watch is closed"))
    tail(text) = _output_wait_tail(text, max_bytes)
    function matched(text, entry)
        shown, removed = tail(text)
        ScreenWaitResult(shown, entry ? :baseline : :output, entry, removed)
    end
    ended(reason, text) = ScreenWaitEnded(reason, first(tail(text)))
    entered = count(needle, screen.entry)
    baseline && entered > 0 && return matched(screen.entry, true)
    screen.entry_state === :live || throw(ended(screen.entry_state, screen.entry))
    bar = baseline ? 0 : screen.entry_alternate ? nothing : entered
    seen = screen.entry
    while true
        read = _screen_read(screen)
        if read.text !== nothing
            seen = read.text
            if !read.alternate
                found = count(needle, seen)
                if bar === nothing
                    bar = found
                elseif found > bar
                    _screen_remaining(screen)
                    return matched(seen, false)
                end
            end
        end
        _screen_remaining(screen)
        read.state === :live || throw(ended(read.state, seen))
        _screen_sleep(screen)
    end
end
