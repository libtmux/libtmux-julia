"""Bounded script output and direct-child exit evidence; the child has been reaped."""
struct ScriptResult
    pid::Int
    stdout::Vector{UInt8}
    stderr::Vector{UInt8}
    exitcode::Int
    termsignal::Int
end
struct BeforeScriptError <: Exception
    code::Symbol
    result::Union{Nothing,ScriptResult}
    cause::Union{Nothing,Exception}
end
Base.showerror(io::IO, error::BeforeScriptError) = print(
    io,
    "before_script failed: ",
    error.code,
    error.result === nothing ? " before child admission" : " (bounded output retained)",
)

# Match Python shlex.split(..., posix=true, comments=false): quote removal and
# whitespace splitting only. In double quotes, only quote/backslash lose escapes.
function _script_argv(text::AbstractString)
    args, word = String[], IOBuffer()
    quote_state = '\0'
    escaped = false
    present = false
    for char in text
        if escaped
            quote_state == '"' && char != '"' && char != '\\' && write(word, '\\')
            write(word, char)
            escaped = false
            present = true
        elseif quote_state == '\''
            char == '\'' ? (quote_state = '\0') : write(word, char)
        elseif char == '\\'
            escaped = true
            present = true
        elseif quote_state == '"'
            char == '"' ? (quote_state = '\0') : write(word, char)
        elseif char in ('\'', '"')
            quote_state = char
            present = true
        elseif char in (' ', '\t', '\r', '\n')
            if present
                push!(args, String(take!(word)))
                present = false
            end
        else
            write(word, char)
            present = true
        end
    end
    escaped && _fail(:value, "\$.before_script", "dangling backslash")
    quote_state == '\0' || _fail(:value, "\$.before_script", "unterminated quote")
    present && push!(args, String(take!(word)))
    isempty(args) && _fail(:value, "\$.before_script", "script argv must not be empty")
    isempty(first(args)) &&
        _fail(:value, "\$.before_script", "script executable must not be empty")
    args
end

function _script_close(io)
    try
        close(io)
    catch error
        error isa Base.IOError || error isa ArgumentError || rethrow()
    end
end

# Retain the timer's waiter so close can join callbacks already in flight.
function _owned_timer(callback, delay)
    timer = Timer(delay)
    task = Threads.@spawn begin
        try
            wait(timer)
        catch error
            error isa EOFError || rethrow()
            return
        end
        callback()
    end
    timer, task
end

"""
    run_before_script(text; base_directory, start_directory=base_directory,
                      env=ENV, timeout=0.9, cancel=nothing, on_output=nothing,
                      max_output_bytes=65536, max_error_bytes=65536)

Execute shlex-style argv without implicit shell evaluation. Relative executable
paths containing `/` resolve from the configuration base; bare names use PATH.
Explicit `/bin/sh -c` remains an intentional shell command. Pipes are drained
concurrently with bounded captures; `on_output(stream, bytes)` receives owned
chunks and must return promptly. Its calls are serialized across both streams.

Cancellation/deadline kill the directly owned process and its still-owned POSIX
process group. The direct child is reaped on every path. Descendants that leave
the group, or outlive successful script exit with redirected output, are external
script effects; their exit is not established. The same monotonic deadline
bounds inherited open pipes after direct-child exit. No output appears in errors.
"""
function run_before_script(
    text::AbstractString;
    base_directory::AbstractString,
    start_directory::AbstractString=base_directory,
    env::AbstractDict=ENV,
    timeout::Real=0.9,
    cancel=nothing,
    on_output=nothing,
    max_output_bytes::Int=65536,
    max_error_bytes::Int=65536,
)
    Sys.isunix() || throw(ArgumentError("before_script execution currently requires POSIX"))
    isabspath(base_directory) && isabspath(start_directory) ||
        throw(ArgumentError("script directories must be absolute"))
    budget = Float64(timeout)
    isfinite(budget) && 0 < budget < 1e15 || throw(ArgumentError("invalid script timeout"))
    max_output_bytes >= 0 && max_error_bytes >= 0 ||
        throw(ArgumentError("negative output bound"))
    started = time_ns()
    argv = _script_argv(_string(text, "\$.before_script"; empty=false))
    if occursin('/', first(argv)) && !isabspath(first(argv))
        argv[1] = normpath(joinpath(base_directory, first(argv)))
    end
    environment = Dict{String,String}()
    total = 0
    for (name, value) in env
        name in ("TMUX", "TMUX_PANE") && continue
        key, item =
            _string(name, "\$.script_env"; empty=false), _string(value, "\$.script_env")
        occursin('=', key) && throw(ArgumentError("invalid script environment name"))
        total += ncodeunits(key) + ncodeunits(item) + 2
        total <= 128 * 1024 || throw(ArgumentError("script environment exceeds 128 KiB"))
        environment[key] = item
    end
    cancel === nothing ||
        !LibTmux.iscancelled(cancel) ||
        throw(BeforeScriptError(:cancelled, nothing, nothing))
    output, errors = Pipe(), Pipe()
    state_lock, output_lock = ReentrantLock(), ReentrantLock()
    reason = Ref{Union{Nothing,Symbol}}(nothing)
    cause = Ref{Union{Nothing,Exception}}(nothing)
    retired = Ref(false)
    proc = nothing
    subscription = nothing
    deadline_timer = nothing
    deadline_task = nothing
    workers = Task[]
    function stop(code, why=nothing)
        lock(state_lock) do
            retired[] && return
            if reason[] === nothing
                reason[], cause[] = code, why
            end
            if proc !== nothing && process_running(proc)
                # detach=true gives this still-live child its own POSIX group.
                ccall(:kill, Cint, (Cint, Cint), -getpid(proc), Base.SIGKILL)
                try
                    kill(proc, Base.SIGKILL)
                catch error
                    error isa Base.IOError || rethrow()
                end
            end
            _script_close(output.out)
            _script_close(errors.out)
        end
        nothing
    end
    try
        subscription =
            cancel === nothing ? nothing : LibTmux.on_cancel(() -> stop(:cancelled), cancel)
        spawned = lock(state_lock) do
            reason[] === nothing || return nothing
            try
                command = setenv(Cmd(Cmd(argv); dir=start_directory, detach=true), environment)
                if (time_ns() - started) / 1e9 >= budget
                    reason[] = :deadline
                    return nothing
                end
                proc = run(
                    pipeline(
                        ignorestatus(command);
                        stdin=devnull,
                        stdout=output,
                        stderr=errors,
                    );
                    wait=false,
                )
            catch error
                error
            end
        end
        spawned === nothing &&
            throw(BeforeScriptError(something(reason[], :cancelled), nothing, nothing))
        if spawned isa Exception
            clean =
                spawned isa Base.IOError ?
                Base.IOError("script spawn failed", spawned.code) :
                ErrorException("script spawn failed")
            throw(BeforeScriptError(:spawn, nothing, clean))
        end
        child_pid = getpid(proc)
        close(output.in)
        close(errors.in)
        reason[] === nothing || stop(reason[])
        deadline_timer, deadline_task = _owned_timer(
            () -> stop(:deadline),
            max(0.0, budget - (time_ns() - started) / 1e9),
        )
        function drain(io, stream, limit)
            local captured = UInt8[]
            try
                while !eof(io)
                    chunk = UInt8[read(io, UInt8)]
                    available = min(bytesavailable(io), 4095)
                    available == 0 || append!(chunk, read(io, available))
                    count = min(length(chunk), limit - length(captured))
                    offset = length(captured)
                    resize!(captured, offset + count)
                    count == 0 || copyto!(captured, offset + 1, chunk, 1, count)
                    if on_output !== nothing && count > 0
                        lock(output_lock) do
                            on_output(stream, chunk[1:count])
                        end
                    end
                    if length(chunk) > count
                        stop(:output_limit)
                        break
                    end
                end
            catch error
                if error isa InterruptException
                    stop(:cancelled, error)
                else
                    stop(
                        :io,
                        error isa Base.IOError ?
                        Base.IOError("script pipe failed", error.code) :
                        ErrorException("script pipe or output callback failed"),
                    )
                end
            end
            captured
        end
        stdout_task = Threads.@spawn drain(output.out, :stdout, max_output_bytes)
        push!(workers, stdout_task)
        stderr_task = Threads.@spawn drain(errors.out, :stderr, max_error_bytes)
        push!(workers, stderr_task)
        wait(proc)
        stdout_bytes, stderr_bytes = fetch(stdout_task), fetch(stderr_task)
        failure = lock(state_lock) do
            retired[] = true
            reason[]
        end
        result = ScriptResult(
            child_pid,
            stdout_bytes,
            stderr_bytes,
            Int(proc.exitcode),
            Int(proc.termsignal),
        )
        failure === nothing || throw(BeforeScriptError(failure, result, cause[]))
        result.exitcode == 0 && result.termsignal == 0 ||
            throw(BeforeScriptError(:exit, result, nothing))
        result
    finally
        lock(state_lock) do
            retired[] = true
        end
        deadline_timer === nothing || close(deadline_timer)
        deadline_task === nothing || wait(deadline_task)
        subscription === nothing || close(subscription)
        if proc !== nothing && process_running(proc)
            ccall(:kill, Cint, (Cint, Cint), -getpid(proc), Base.SIGKILL)
            kill(proc, Base.SIGKILL)
        end
        foreach(_script_close, (output, errors))
        proc === nothing || wait(proc)
        foreach(wait, workers)
    end
end
