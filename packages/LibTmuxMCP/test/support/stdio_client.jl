# A raw stdio client for an installed launcher, independent of the package's own
# transport: it starts the process, writes newline-delimited JSON, and reads the
# child's stdout and stderr through file descriptors it owns, so a stopped reader
# really stops reading. The standard library has no pty or poll API, hence `ccall`.
module StdioClient

# JSON comes from the package under test, which every environment that runs this
# client already holds; only the launcher's transport is kept out of the client.
import LibTmuxMCP: JSON

export Child, spawn_child, send_line, close_stdin!, receive_line, read_byte, finish!

mutable struct Child
    process::Base.Process
    stdin::Cint
    stdout::Cint
    stderr::Cint
    pending::Vector{UInt8}
    diagnostics::Vector{UInt8}
end

# Both ends are close-on-exec, so the child keeps no copy of the end it does not use;
# otherwise closing our write end would never show it EOF.
function make_pipe()
    fds = zeros(Cint, 2)
    ccall(:pipe, Cint, (Ptr{Cint},), fds) == 0 || Base.systemerror("pipe")
    for fd in fds
        ccall(:fcntl, Cint, (Cint, Cint, Cint), fd, 2, 1) == 0 || Base.systemerror("fcntl")
    end
    fds[1], fds[2]
end

close_fd(fd) = fd >= 0 && ccall(:close, Cint, (Cint,), fd)

function spawn_child(argv; env=ENV)
    in_read, in_write = make_pipe()
    out_read, out_write = make_pipe()
    err_read, err_write = make_pipe()
    file(fd) = Base.Filesystem.File(RawFD(fd))
    inputs, outputs, errors = file(in_read), file(out_write), file(err_write)
    process = run(
        pipeline(
            setenv(
                Cmd(argv),
                Dict{String,String}(string(k) => string(v) for (k, v) in env),
            );
            stdin=inputs,
            stdout=outputs,
            stderr=errors,
        );
        wait=false,
    )
    # The child holds its own copies of these ends.
    close(inputs)
    close(outputs)
    close(errors)
    Child(process, in_write, out_read, err_read, UInt8[], UInt8[])
end

function send_line(child::Child, value)
    bytes = codeunits(value isa AbstractString ? value : JSON.json(value) * "\n")
    written = ccall(
        :write,
        Cssize_t,
        (Cint, Ptr{UInt8}, Csize_t),
        child.stdin,
        bytes,
        length(bytes),
    )
    written == length(bytes) || Base.systemerror("write to the launcher")
    nothing
end

function close_stdin!(child::Child)
    close_fd(child.stdin)
    child.stdin = -1
end

# Wait until one of the open descriptors is readable. A descriptor that has reached
# EOF is dropped by the caller, which sets it to -1.
function poll_readable(fds, seconds)
    open = [fd for fd in fds if fd >= 0]
    isempty(open) && return Cint[]
    entries = Cint[]
    for fd in open
        push!(entries, fd, Cint(1))  # events = POLLIN; revents stay zero
    end
    ready = ccall(
        :poll,
        Cint,
        (Ptr{Cint}, Culong, Cint),
        entries,
        length(open),
        round(Cint, 1000 * max(0.0, seconds)),
    )
    ready < 0 && Base.systemerror("poll")
    [open[i] for i in eachindex(open) if (entries[2i] >> 16) != 0]
end

function read_some(fd, limit=65536)
    buffer = Vector{UInt8}(undef, limit)
    count = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buffer, limit)
    count < 0 && Base.systemerror("read")
    resize!(buffer, count)
end

function note_diagnostics!(child::Child, chunk)
    append!(child.diagnostics, chunk)
    length(child.diagnostics) <= 1024 * 1024 || error("launcher diagnostics exceeded 1 MiB")
end

text(bytes) = String(copy(bytes))

"Read up to the next newline from stdout; diagnostics are collected on the way."
function receive_line(child::Child; timeout=45.0, limit=8 * 1024 * 1024)
    deadline = time() + timeout
    while !(10 in child.pending)
        remaining = deadline - time()
        remaining > 0 || error("installed launcher response exceeded its budget")
        for fd in poll_readable((child.stdout, child.stderr), remaining)
            chunk = read_some(fd)
            if isempty(chunk)
                fd == child.stdout &&
                    error("launcher exited before response: " * text(child.diagnostics))
                child.stderr = -1
            elseif fd == child.stdout
                append!(child.pending, chunk)
                length(child.pending) <= limit ||
                    error("launcher response exceeded $limit bytes")
            else
                note_diagnostics!(child, chunk)
            end
        end
    end
    index = findfirst(==(UInt8(10)), child.pending)
    line = text(child.pending[1:(index-1)])
    deleteat!(child.pending, 1:index)
    JSON.parse(line; dicttype=Dict{String,Any})
end

"Read exactly one byte of stdout, and no more, so the rest stays in the pipe."
function read_byte(child::Child, deadline)
    while true
        remaining = deadline - time()
        remaining > 0 || error("stdio response deadline")
        ready = poll_readable((child.stdout, child.stderr), remaining)
        isempty(ready) && error("stdio response deadline")
        for fd in ready
            if fd == child.stdout
                chunk = read_some(fd, 1)
                isempty(chunk) &&
                    error("child exited before response: " * text(child.diagnostics))
                return only(chunk)
            end
            chunk = read_some(fd)
            isempty(chunk) ? (child.stderr = -1) : note_diagnostics!(child, chunk)
        end
    end
end

function wait_for_exit(child::Child, seconds)
    event = Base.Event()
    Threads.@spawn begin
        try
            wait(child.process)
        catch
        end
        notify(event)
    end
    timer = Timer(_ -> notify(event), seconds)
    wait(event)
    close(timer)
end

"Everything left on a descriptor until EOF, up to `limit` bytes."
function read_rest(fd, limit)
    collected = UInt8[]
    while length(collected) <= limit
        chunk = read_some(fd)
        isempty(chunk) && break
        append!(collected, chunk)
    end
    collected
end

function finish!(child::Child)
    process_running(child.process) && kill(child.process, Base.SIGKILL)
    wait(child.process)
    close_fd.((child.stdin, child.stdout, child.stderr))
    child.stdin = child.stdout = child.stderr = -1
    nothing
end

export wait_for_exit, read_rest

end
