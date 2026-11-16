# Start a child process and watch it through POSIX calls that libuv would hide.
#
# usage: include("owned-process.jl"); using .OwnedProcess
#
# The benchmark drivers need three things that `Base.run` does not give them: the
# child's own process group, to retire everything it started; its exit observed
# before it is reaped, so the group number cannot be reused while it is signalled;
# and `wait4` accounting, for its peak resident set and CPU time. This module spawns
# the child with `posix_spawn`, gives the parent non-blocking pipe ends, and runs one
# blocking `waitid` or `wait4` on a libuv pool thread. That thread writes a byte to a
# pipe when the child exits, so a caller waits for output and exit in a single
# `poll` and never polls for readiness. Those calls are marked safe for the garbage
# collector: `@threadcall` leaves its thread unsafe for the whole call, so a collection on
# the main thread would wait until the child exited. The tests are in tests/runtests.jl.

module OwnedProcess

export @blocking_ccall,
    Child,
    PollFD,
    POLLIN,
    POLLOUT,
    spawn_child,
    poll!,
    read_available,
    write_available,
    set_nonblocking!,
    close_fd,
    signal_group,
    signal_process,
    wait_exit,
    drain_wake,
    reap!,
    usage_fields,
    exit_code,
    monotonic

# Linux and macOS agree on these values.
const F_SETFD = 2
const F_SETFL = 4
const FD_CLOEXEC = 1
const P_PID = 1
const WEXITED = 4
const SPAWN_SETPGROUP = Cshort(0x02)
const SPAWN_SETSIGDEF = Cshort(0x04)
const SPAWN_SETSIGMASK = Cshort(0x08)
const SIGPIPE = 13
const POLLIN = Cshort(0x0001)
const POLLOUT = Cshort(0x0004)
# These differ between the two systems.
const O_NONBLOCK = Sys.islinux() ? 0o4000 : 0x0004
const WNOWAIT = Sys.islinux() ? 0x01000000 : 0x20
# Opaque POSIX structures are larger on glibc than on macOS; this holds either.
const OPAQUE_BYTES = 512

"The kernel's `struct pollfd`."
struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end

"A started child and the parent's ends of its pipes. A descriptor of -1 is not open."
mutable struct Child
    pid::Cint
    stdin::Cint
    stdout::Cint
    stderr::Cint
    wake_read::Cint
    wake_write::Cint
    started_ns::UInt64
    exit_ns::Union{Nothing,UInt64}
    exited::Bool
    exit_event::Base.Event
    watcher::Task
    watch_error::Union{Nothing,String}
    # Filled by the watcher when it reaps, or by `reap!`.
    status::Union{Nothing,Cint}
    usage::Union{Nothing,Vector{UInt8}}
    Child(pid, stdin, stdout, stderr, wake_read, wake_write, started_ns) = new(
        pid,
        stdin,
        stdout,
        stderr,
        wake_read,
        wake_write,
        started_ns,
        nothing,
        false,
        Base.Event(),
        Task(() -> nothing),
        nothing,
        nothing,
        nothing,
    )
end

"""
    @blocking_ccall((cfunc, clib), rettype, (argtypes...), argvals...)

Call a C function that can block on a thread of libuv's pool, as `@threadcall` does, and
mark the call safe for the garbage collector. `@threadcall` leaves its thread GC unsafe,
so a collection on the calling thread waits until the call returns. The function must
not call back into Julia.
"""
macro blocking_ccall(f, rettype, argtypes, argvals...)
    isa(argtypes, Expr) && argtypes.head === :tuple ||
        error("blocking_ccall: argument types must be a tuple")
    length(argtypes.args) == length(argvals) ||
        error("blocking_ccall: wrong number of arguments to C function")
    f = esc(f)
    rettype = esc(rettype)
    argtypes = map(esc, argtypes.args)
    argvals = map(esc, argvals)
    wrapper = :(function (fptr::Ptr{Cvoid}, args_ptr::Ptr{Cvoid}, retval_ptr::Ptr{Cvoid})
        p = args_ptr
    end)
    body = wrapper.args[2].args
    args = Symbol[]
    for (i, T) in enumerate(argtypes)
        arg = Symbol("arg", i)
        push!(body, :($arg = unsafe_load(convert(Ptr{$T}, p))))
        push!(body, :(p += Core.sizeof($T)))
        push!(args, arg)
    end
    # `ccall` takes no `gc_safe` keyword with a function pointer; `@ccall` does.
    callee = Expr(
        :call,
        Expr(:$, :fptr),
        [Expr(:(::), a, T) for (a, T) in zip(args, argtypes)]...,
    )
    call = Expr(
        :macrocall,
        GlobalRef(Base, Symbol("@ccall")),
        __source__,
        :(gc_safe = true),
        Expr(:(::), callee, rettype),
    )
    push!(body, :(ret = $call))
    push!(body, :(unsafe_store!(convert(Ptr{$rettype}, retval_ptr), ret)))
    push!(body, :(return Int(Core.sizeof($rettype))))
    wrapper = Expr(:var"hygienic-scope", wrapper, @__MODULE__, __source__)
    return :(
        let fun_ptr = @cfunction($wrapper, Int, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}))
            Base.do_threadcall(
                fun_ptr,
                cglobal($f),
                $rettype,
                Any[$(argtypes...)],
                Any[$(argvals...)],
            )
        end
    )
end

"Seconds on a clock that never steps back."
monotonic() = time_ns() / 1e9

close_fd(fd::Integer) = fd >= 0 && ccall(:close, Cint, (Cint,), fd)

function check(result, call)
    result == 0 || Base.systemerror(call, Cint(result))
    nothing
end

# Both ends are close-on-exec, so a child keeps only the descriptors it is given.
function make_pipe()
    fds = zeros(Cint, 2)
    ccall(:pipe, Cint, (Ptr{Cint},), fds) == 0 || Base.systemerror("pipe")
    for fd in fds
        ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_SETFD, FD_CLOEXEC) == 0 ||
            Base.systemerror("fcntl")
    end
    fds[1], fds[2]
end

function set_nonblocking!(fd::Integer)
    ccall(:fcntl, Cint, (Cint, Cint, Cint...), fd, F_SETFL, O_NONBLOCK) == 0 ||
        Base.systemerror("fcntl")
    nothing
end

"Find `name` the way the child would, along the PATH of its own environment."
function resolve_executable(name::AbstractString, env)
    occursin('/', name) && return String(name)
    for directory in split(get(env, "PATH", get(ENV, "PATH", "/usr/bin:/bin")), ':')
        candidate = joinpath(isempty(directory) ? "." : directory, name)
        isfile(candidate) && Base.Filesystem.isexecutable(candidate) && return candidate
    end
    throw(SystemError("posix_spawn: $name", Libc.ENOENT))
end

function c_strings(items)
    all(item -> !occursin('\0', item), items) ||
        throw(ArgumentError("a command or environment entry holds a NUL byte"))
    strings = String.(items)
    pointers = Cstring[Base.unsafe_convert(Cstring, string) for string in strings]
    push!(pointers, Cstring(C_NULL))
    strings, pointers
end

"""
    spawn_child(argv; env, stdin=:null, group=true, reap=false) -> Child

Start `argv` with `env` as its whole environment. Its stdout and stderr are pipes. Its
stdin is `/dev/null`, or a pipe with `stdin=:pipe`. With `group` it leads its own
process group. The watcher reaps the child with `wait4` when `reap` is set, and only
observes its exit otherwise, leaving `reap!` to collect it.
"""
function spawn_child(argv; env, stdin::Symbol=:null, group::Bool=true, reap::Bool=false)
    stdin in (:null, :pipe) || throw(ArgumentError("stdin is :null or :pipe"))
    path = resolve_executable(first(argv), env)
    argv_strings, argv_pointers = c_strings(argv)
    env_strings, env_pointers = c_strings(["$key=$value" for (key, value) in env])
    in_read, in_write = stdin === :pipe ? make_pipe() : (Cint(-1), Cint(-1))
    out_read, out_write = make_pipe()
    err_read, err_write = make_pipe()
    wake_read, wake_write = make_pipe()
    pid = Ref{Cint}(0)
    attribute = zeros(UInt8, OPAQUE_BYTES)
    actions = zeros(UInt8, OPAQUE_BYTES)
    defaults = zeros(UInt8, OPAQUE_BYTES)
    mask = zeros(UInt8, OPAQUE_BYTES)
    started_ns = time_ns()
    failure = nothing
    try
        GC.@preserve attribute actions defaults mask argv_strings env_strings begin
            check(ccall(:posix_spawnattr_init, Cint, (Ptr{UInt8},), attribute), "attr")
            check(
                ccall(:posix_spawn_file_actions_init, Cint, (Ptr{UInt8},), actions),
                "actions",
            )
            try
                # The child leaves Julia's ignored SIGPIPE and blocked signals behind.
                ccall(:sigemptyset, Cint, (Ptr{UInt8},), defaults)
                ccall(:sigaddset, Cint, (Ptr{UInt8}, Cint), defaults, SIGPIPE)
                ccall(:sigemptyset, Cint, (Ptr{UInt8},), mask)
                flags = SPAWN_SETSIGDEF | SPAWN_SETSIGMASK | (group ? SPAWN_SETPGROUP : 0)
                ccall(
                    :posix_spawnattr_setflags,
                    Cint,
                    (Ptr{UInt8}, Cshort),
                    attribute,
                    flags,
                )
                ccall(
                    :posix_spawnattr_setsigdefault,
                    Cint,
                    (Ptr{UInt8}, Ptr{UInt8}),
                    attribute,
                    defaults,
                )
                ccall(
                    :posix_spawnattr_setsigmask,
                    Cint,
                    (Ptr{UInt8}, Ptr{UInt8}),
                    attribute,
                    mask,
                )
                group && ccall(
                    :posix_spawnattr_setpgroup,
                    Cint,
                    (Ptr{UInt8}, Cint),
                    attribute,
                    0,
                )
                if stdin === :pipe
                    ccall(
                        :posix_spawn_file_actions_adddup2,
                        Cint,
                        (Ptr{UInt8}, Cint, Cint),
                        actions,
                        in_read,
                        0,
                    )
                else
                    ccall(
                        :posix_spawn_file_actions_addopen,
                        Cint,
                        (Ptr{UInt8}, Cint, Cstring, Cint, Cuint),
                        actions,
                        0,
                        "/dev/null",
                        0,
                        0,
                    )
                end
                ccall(
                    :posix_spawn_file_actions_adddup2,
                    Cint,
                    (Ptr{UInt8}, Cint, Cint),
                    actions,
                    out_write,
                    1,
                )
                ccall(
                    :posix_spawn_file_actions_adddup2,
                    Cint,
                    (Ptr{UInt8}, Cint, Cint),
                    actions,
                    err_write,
                    2,
                )
                started_ns = time_ns()
                check(
                    ccall(
                        :posix_spawn,
                        Cint,
                        (
                            Ref{Cint},
                            Cstring,
                            Ptr{UInt8},
                            Ptr{UInt8},
                            Ptr{Cstring},
                            Ptr{Cstring},
                        ),
                        pid,
                        path,
                        actions,
                        attribute,
                        argv_pointers,
                        env_pointers,
                    ),
                    "posix_spawn: $(basename(path))",
                )
            finally
                ccall(:posix_spawn_file_actions_destroy, Cint, (Ptr{UInt8},), actions)
                ccall(:posix_spawnattr_destroy, Cint, (Ptr{UInt8},), attribute)
            end
        end
    catch error
        failure = error
    end
    # The child holds its own copies of these ends, or never started.
    foreach(close_fd, (in_read, out_write, err_write))
    if failure !== nothing
        foreach(close_fd, (in_write, out_read, err_read, wake_read, wake_write))
        throw(failure)
    end
    foreach(
        set_nonblocking!,
        filter(>=(0), [in_write, out_read, err_read, wake_read, wake_write]),
    )
    child = Child(pid[], in_write, out_read, err_read, wake_read, wake_write, started_ns)
    child.watcher = @async watch!(child, reap)
    child
end

function watch!(child::Child, reap::Bool)
    try
        status = zeros(Cint, 1)
        usage = zeros(UInt8, 256)
        result = if reap
            GC.@preserve status usage @blocking_ccall(
                :wait4,
                Cint,
                (Cint, Ptr{Cint}, Cint, Ptr{UInt8}),
                child.pid,
                pointer(status),
                0,
                pointer(usage)
            )
        else
            information = zeros(UInt8, 256)
            GC.@preserve information @blocking_ccall(
                :waitid,
                Cint,
                (Cint, Cuint, Ptr{UInt8}, Cint),
                P_PID,
                child.pid,
                pointer(information),
                WEXITED | WNOWAIT
            )
        end
        child.exit_ns = time_ns()
        if reap
            result == child.pid || (child.watch_error = "wait4 failed")
            child.status, child.usage = status[1], usage
        else
            result == 0 || (child.watch_error = "waitid failed")
        end
    catch error
        child.watch_error = string(nameof(typeof(error)))
    finally
        child.exited = true
        ccall(
            :write,
            Cssize_t,
            (Cint, Ptr{UInt8}, Csize_t),
            child.wake_write,
            UInt8[0x78],
            1,
        )
        notify(child.exit_event)
    end
end

"Wait for at most `seconds` for the watcher to see the child exit."
function wait_exit(child::Child, seconds::Real)
    child.exited && return true
    done = Base.Event()
    @async (wait(child.exit_event); notify(done))
    timer = Timer(_ -> notify(done), seconds)
    wait(done)
    close(timer)
    child.exited
end

"Consume the byte the watcher wrote, so the wake descriptor stops being readable."
function drain_wake(child::Child)
    read_available(child.wake_read, 16)
    nothing
end

"Signal the child's process group. A group with no process left is not an error."
function signal_group(child::Child, signal::Integer)
    ccall(:killpg, Cint, (Cint, Cint), child.pid, signal) == 0 ||
        Libc.errno() == Libc.ESRCH ||
        Base.systemerror("killpg")
    nothing
end

function signal_process(child::Child, signal::Integer)
    ccall(:kill, Cint, (Cint, Cint), child.pid, signal) == 0 ||
        Libc.errno() == Libc.ESRCH ||
        Base.systemerror("kill")
    nothing
end

"""
    poll!(entries, timeout) -> Int

Wait for events on `entries` without blocking the Julia scheduler, so the watcher
task still runs. A negative `timeout` waits without limit. The count can be zero
before the timeout, when a signal woke the wait; a caller checks its own clock.
"""
function poll!(entries::Vector{PollFD}, timeout::Real)
    milliseconds = timeout < 0 ? -1 : clamp(ceil(Int, 1000 * timeout), 0, typemax(Cint))
    GC.@preserve entries begin
        count = @blocking_ccall(
            :poll,
            Cint,
            (Ptr{PollFD}, Culong, Cint),
            pointer(entries),
            length(entries),
            Cint(milliseconds)
        )
        if count < 0
            # A pool thread cannot report errno. Ask again, without waiting.
            count =
                ccall(:poll, Cint, (Ptr{PollFD}, Culong, Cint), entries, length(entries), 0)
            count < 0 && Libc.errno() != Libc.EINTR && Base.systemerror("poll")
        end
    end
    max(Int(count), 0)
end

"Read what a non-blocking descriptor holds: `nothing` when empty, no bytes at EOF."
function read_available(fd::Integer, limit::Integer=65536)
    buffer = Vector{UInt8}(undef, limit)
    count = ccall(:read, Cssize_t, (Cint, Ptr{UInt8}, Csize_t), fd, buffer, limit)
    if count < 0
        errno = Libc.errno()
        errno in (Libc.EAGAIN, Libc.EINTR) && return nothing
        Base.systemerror("read", errno)
    end
    resize!(buffer, count)
end

"Write as much of `bytes` as a non-blocking descriptor takes; `nothing` when full."
function write_available(fd::Integer, bytes::AbstractVector{UInt8})
    count = GC.@preserve bytes ccall(
        :write,
        Cssize_t,
        (Cint, Ptr{UInt8}, Csize_t),
        fd,
        pointer(bytes),
        length(bytes),
    )
    if count < 0
        errno = Libc.errno()
        errno in (Libc.EAGAIN, Libc.EINTR) && return nothing
        Base.systemerror("write", errno)
    end
    Int(count)
end

"""
    exit_code(status) -> Int

The code of a wait status, or minus the number of the signal that ended the child.
"""
function exit_code(status::Integer)
    signal = status & 0x7f
    signal == 0 ? Int((status >> 8) & 0xff) : -Int(signal)
end

"""
    usage_fields(usage) -> NamedTuple

Decode a `struct rusage`: user and system CPU seconds and peak resident bytes. Linux
reports the peak in kilobytes and macOS in bytes.
"""
function usage_fields(usage::Vector{UInt8})
    load(::Type{T}, offset) where {T} =
        GC.@preserve usage unsafe_load(Ptr{T}(pointer(usage) + offset))
    # `tv_usec` is 32 bits on macOS and 64 on Linux; its value fits either way.
    seconds(offset) = load(Int64, offset) + load(Int32, offset + 8) / 1e6
    peak = load(Int64, 32)
    (
        user_seconds=seconds(0),
        system_seconds=seconds(16),
        max_rss_bytes=Sys.isapple() ? peak : 1024 * peak,
    )
end

"""
    reap!(child) -> (code, usage)

Collect a child the watcher only observed. Call it after the child has been signalled,
so it returns at once. `usage` holds the `wait4` accounting.
"""
function reap!(child::Child)
    if child.status === nothing
        status = zeros(Cint, 1)
        usage = zeros(UInt8, 256)
        result = ccall(
            :wait4,
            Cint,
            (Cint, Ptr{Cint}, Cint, Ptr{UInt8}),
            child.pid,
            status,
            0,
            usage,
        )
        result == child.pid || Base.systemerror("wait4")
        child.status, child.usage = status[1], usage
    end
    exit_code(child.status), usage_fields(child.usage)
end

end
