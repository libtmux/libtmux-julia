struct _CLIOutputError <: Exception
    reason::Symbol
    cause::Union{Nothing,Exception}
end
_CLIOutputError(reason::Symbol) = _CLIOutputError(reason, nothing)
Base.showerror(io::IO, error::_CLIOutputError) =
    print(io, "workspace CLI output failed: ", error.reason)

mutable struct _CLIOwnedOutput
    out::IO
    err::IO
    cancel::LibTmux.CancellationToken
    changed::Threads.Condition
    queue::Vector{Tuple{Symbol,String}}
    bytes::Int
    max_items::Int
    max_bytes::Int
    timeout::Float64
    closing::Bool
    io_closed::Bool
    failure::Union{Nothing,Exception}
    worker::Union{Nothing,Task}
end

struct _CLIOutputDeadline
    owner::_CLIOwnedOutput
    active::Threads.Atomic{Bool}
    reason::Symbol
end
_CLIOutputDeadline(owner, reason) =
    _CLIOutputDeadline(owner, Threads.Atomic{Bool}(true), reason)
function (deadline::_CLIOutputDeadline)()
    Threads.atomic_xchg!(deadline.active, false) || return nothing
    _cli_output_abort(deadline.owner, _CLIOutputError(deadline.reason))
end

_cli_forceclose(stream::IO) = close(stream)
_cli_forceclose(stream::IOContext) = _cli_forceclose(stream.io)
function _cli_forceclose(stream::Base.Pipe)
    errors = Exception[]
    for endpoint in (stream.in, stream.out)
        try
            _cli_forceclose(endpoint)
        catch error
            push!(errors, error)
        end
    end
    isempty(errors) || throw(CompositeException(errors))
    nothing
end
function _cli_forceclose(stream::Base.LibuvStream)
    # Base.close flushes pending writes. A stalled owned pipe must instead
    # interrupt its write before joining the worker.
    Base.iolock_begin()
    try
        if stream.handle != C_NULL && isopen(stream)
            ccall(:jl_forceclose_uv, Cvoid, (Ptr{Cvoid},), stream.handle)
            stream.status = Base.StatusClosing
        end
    finally
        Base.iolock_end()
    end
    Base.wait_close(stream)
    nothing
end

function _cli_output_failure(owner, error)
    lock(owner.changed) do
        owner.failure =
            owner.failure === nothing ? error : CompositeException([owner.failure, error])
    end
end

function _cli_output_close_io(owner)
    claimed = lock(owner.changed) do
        owner.io_closed && return false
        owner.io_closed = true
        true
    end
    claimed || return
    for index = 1:2
        stream = index == 1 ? owner.out : owner.err
        index == 2 && stream === owner.out && continue
        try
            _cli_forceclose(stream)
        catch error
            _cli_output_failure(owner, error)
        end
    end
end

function _cli_output_abort(owner, error)
    lock(owner.changed) do
        owner.failure === nothing && (owner.failure = error)
        owner.closing = true
        empty!(owner.queue)
        owner.bytes = 0
        notify(owner.changed; all=true)
    end
    try
        LibTmux.cancel!(owner.cancel)
    catch cleanup
        _cli_output_failure(owner, cleanup)
    end
    _cli_output_close_io(owner)
    nothing
end

_cli_pipe_endpoint(stream::IOContext) = _cli_pipe_endpoint(stream.io)
_cli_pipe_endpoint(stream::Base.PipeEndpoint) = stream
_cli_pipe_endpoint(stream::IO) = nothing

function _cli_output_write_generic(stream, text, owner)
    deadline = _CLIOutputDeadline(owner, :write_deadline)
    timer, timer_task = _owned_timer(deadline, owner.timeout)
    try
        write(stream, text)
        flush(stream)
    finally
        deadline.active[] = false
        close(timer)
        wait(timer_task)
    end
    nothing
end

function _cli_output_wait_write(request, deadline, timeout)
    task = current_task()
    Base.preserve_handle(task)
    Base.sigatomic_begin()
    Base.uv_req_set_data(request, task)
    Base.iolock_end()
    timer = timer_task = nothing
    local status
    try
        Base.sigatomic_end()
        timer, timer_task = _owned_timer(deadline, timeout)
        status = wait()::Cint
        # Julia 1.11+ re-enters this section before Base.uv_write_wait cleanup.
        isdefined(Base, :uv_write_wait) && Base.sigatomic_begin()
    finally
        deadline.active[] = false
        timer === nothing || close(timer)
        timer_task === nothing || wait(timer_task)
        # This is the cleanup path used by Base.uv_write_wait on Julia 1.13
        # and by Base.uv_write before that helper was exposed in Julia 1.11.
        Base.sigatomic_end()
        Base.iolock_begin()
        queue = task.queue
        queue === nothing ||
            Base.list_deletefirst!(queue::Base.IntrusiveLinkedList{Task}, task)
        if Base.uv_req_data(request) != C_NULL
            Base.uv_req_set_data(request, C_NULL)
        else
            Base.Libc.free(request)
        end
        Base.iolock_end()
        Base.unpreserve_handle(task)
    end
    status
end

function _cli_output_write_pipe(stream, text, owner)
    GC.@preserve text begin
        Base.iolock_begin()
        request = try
            Base.uv_write_async(stream, pointer(text), UInt(ncodeunits(text)))
        catch
            Base.iolock_end()
            rethrow()
        end
        deadline = _CLIOutputDeadline(owner, :write_deadline)
        status = _cli_output_wait_write(request, deadline, owner.timeout)
        status < 0 && Base.uv_error("write", status)
    end
    nothing
end

function _cli_output_write(stream::IO, text::String, owner)
    endpoint = _cli_pipe_endpoint(stream)
    endpoint === nothing ? _cli_output_write_generic(stream, text, owner) :
    _cli_output_write_pipe(endpoint, text, owner)
end

function _cli_output_worker(owner)
    while true
        item = lock(owner.changed) do
            while isempty(owner.queue) && !owner.closing
                wait(owner.changed)
            end
            isempty(owner.queue) && return nothing
            item = popfirst!(owner.queue)
            owner.bytes -= ncodeunits(last(item))
            item
        end
        item === nothing && return
        destination, text = item
        try
            stream = destination === :out ? owner.out : owner.err
            _cli_output_write(stream, text, owner)
        catch error
            _cli_output_abort(owner, _CLIOutputError(:write, error))
        end
    end
end

function _CLIOwnedOutput(out::IO, err::IO; timeout=0.5, max_items=64, max_bytes=8*1024^2)
    0 < timeout <= 0.9 && isfinite(timeout) ||
        throw(ArgumentError("invalid output deadline"))
    max_items > 0 && max_bytes > 0 || throw(ArgumentError("invalid output bounds"))
    owner = _CLIOwnedOutput(
        out,
        err,
        LibTmux.CancellationToken(),
        Threads.Condition(),
        Tuple{Symbol,String}[],
        0,
        max_items,
        max_bytes,
        Float64(timeout),
        false,
        false,
        nothing,
        nothing,
    )
    owner.worker = Threads.@spawn _cli_output_worker(owner)
    owner
end

function _cli_output_enqueue(owner, destination, text)
    owned = String(text)
    failure = lock(owner.changed) do
        owner.failure === nothing || return owner.failure
        owner.closing && return _CLIOutputError(:closed)
        if ncodeunits(owned) > 2*1024^2 ||
           length(owner.queue) >= owner.max_items ||
           ncodeunits(owned) > owner.max_bytes - owner.bytes
            return _CLIOutputError(:queue_limit)
        end
        push!(owner.queue, (destination, owned))
        owner.bytes += ncodeunits(owned)
        notify(owner.changed; all=true)
        nothing
    end
    failure === nothing || begin
        _cli_output_abort(owner, failure)
        throw(failure)
    end
    nothing
end

function Base.close(owner::_CLIOwnedOutput)
    lock(owner.changed) do
        owner.closing = true
        notify(owner.changed; all=true)
    end
    deadline = _CLIOutputDeadline(owner, :drain_deadline)
    timer, timer_task = _owned_timer(deadline, 0.9)
    try
        wait(owner.worker)
    finally
        deadline.active[] = false
        close(timer)
        wait(timer_task)
        _cli_output_close_io(owner)
    end
    failure = lock(() -> owner.failure, owner.changed)
    failure === nothing || throw(failure)
    nothing
end

# Cache cleanup without opening streams or starting a writer. Its first use
# may be a stalled output deadline, when compilation would consume the budget.
if ccall(:jl_generating_output, Cint, ()) == 1
    precompile(_cli_output_worker, (_CLIOwnedOutput,))
    precompile(_cli_output_enqueue, (_CLIOwnedOutput, Symbol, String))
    precompile(_cli_output_abort, (_CLIOwnedOutput, _CLIOutputError))
    precompile(_cli_output_close_io, (_CLIOwnedOutput,))
    precompile(Base.close, (_CLIOwnedOutput,))
    precompile(_cli_forceclose, (Base.PipeEndpoint,))
    precompile(_cli_forceclose, (Base.Pipe,))
    precompile(_cli_forceclose, (IOContext{Base.PipeEndpoint},))
    precompile(Tuple{_CLIOutputDeadline})
end
