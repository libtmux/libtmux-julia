import Profile
import SHA

const PROFILE_SAMPLE_WORDS = 1_000_000
const PROFILE_MAX_BYTES = 32*1024*1024
const PROFILE_MAX_ADDRESSES = 16_384
const PROFILE_MAX_CHECKPOINTS = 8
const PROFILE_CHECKPOINT_SECONDS = 5.0
const PROFILE_EXPORT_SECONDS = 0.75

struct ProfileBuffer <: IO
    io::IOBuffer
    maximum::Int
end

function Base.unsafe_write(io::ProfileBuffer, pointer::Ptr{UInt8}, count::UInt)
    count <= UInt(io.maximum-position(io.io)) || error("profile serialization byte limit")
    Base.unsafe_write(io.io, pointer, count)
end

function Base.write(io::ProfileBuffer, value::UInt8)
    position(io.io) < io.maximum || error("profile serialization byte limit")
    write(io.io, value)
end

mutable struct ProfileSession
    observer::Observer
    directory::String
    mode::String
    lookup::Profile.LineInfoDict
    frames::Dict{String,Any}
    lock::ReentrantLock
    timer::Timer
    task::Union{Task,Nothing}
    stopping::Threads.Atomic{Bool}
    sequence::Int
    overhead_ns::UInt64
end

function profile_event(session, event; fields...)
    OBSERVER[] === session.observer || return false
    emit(event; mode=session.mode, fields...)
end

function resume_sampler(session)
    session.mode == "wall" ? Profile.start_timer(true) : Profile.start_timer()
end

function portable_frames(frames)
    [
        Dict(
            "function"=>sanitize(string(frame.func)),
            "file"=>sanitize(source_file(frame.file)),
            "line"=>Int(frame.line),
            "from_c"=>frame.from_c,
            "inlined"=>frame.inlined,
        ) for frame in frames
    ]
end

function start_profiles(
    observer,
    directory,
    mode;
    interval=PROFILE_CHECKPOINT_SECONDS,
    import_seconds=0.0,
)
    started = time_ns()
    if mode == "wall" && VERSION < v"1.13"
        emit("profile_unavailable"; mode, reason="requires_julia_1_13")
        return nothing
    end
    isfinite(interval) && interval > 0 ||
        throw(ArgumentError("profile checkpoint interval must be finite and positive"))
    PROFILE_SESSION[] === nothing || error("a diagnostic sampler already owns this process")
    Profile.is_running() && error("another sampler owns this process")
    # These controls implement the native macros on floor and current Julia.
    Profile.init(; n=PROFILE_SAMPLE_WORDS, delay=0.01, limitwarn=false)
    Profile.clear()
    lookup = Profile.LineInfoDict()
    Profile.getdict!(lookup, UInt[0])
    timer = Timer(interval; interval)
    session = ProfileSession(
        observer,
        directory,
        mode,
        lookup,
        Dict{String,Any}("0"=>portable_frames(lookup[UInt(0)])),
        ReentrantLock(),
        timer,
        nothing,
        Threads.Atomic{Bool}(false),
        0,
        UInt64(0),
    )
    PROFILE_SESSION[] = session
    try
        resume_sampler(session)
        session.task = @async begin
            while isopen(timer) && !session.stopping[]
                try
                    wait(timer)
                catch error
                    error isa EOFError || rethrow()
                    break
                end
                session.stopping[] && break
                if session.sequence < PROFILE_MAX_CHECKPOINTS-1
                    checkpoint_profile(; label="periodic")
                else
                    profile_event(
                        session,
                        "profile_checkpoint_limit";
                        reason="final_checkpoint_reserved",
                        maximum=PROFILE_MAX_CHECKPOINTS,
                    )
                    close(timer)
                end
            end
        end
        profile_event(
            session,
            "profile_start";
            interval_seconds=interval,
            sample_delay_seconds=0.01,
            sample_buffer_words=PROFILE_SAMPLE_WORDS,
            maximum_checkpoints=PROFILE_MAX_CHECKPOINTS,
            checkpoint_work_seconds=PROFILE_EXPORT_SECONDS,
            checkpoint_scheduling="cooperative_requires_yield",
            measurement_scope="cumulative_buffer; checkpoints overlap",
            sampling_overhead_status="unavailable_requires_paired_whole_commands",
            import_seconds,
            setup_seconds=(time_ns()-started)/1e9,
        )
    catch
        session.stopping[] = true
        close(timer)
        Profile.stop_timer()
        PROFILE_SESSION[] = nothing
        rethrow()
    end
    session
end

function resolve_profile_frames(session, data, deadline)
    addresses = unique(Profile.has_meta(data) ? Profile.strip_meta(data) : data)
    missing = filter(address->!haskey(session.lookup, address), addresses)
    length(session.lookup)+length(missing) <= PROFILE_MAX_ADDRESSES ||
        return "address_limit"
    for batch in Iterators.partition(missing, 32)
        time_ns() < deadline || return "symbolization_work_limit"
        Profile.getdict!(session.lookup, collect(batch))
        for address in batch
            session.frames[string(address)] = portable_frames(session.lookup[address])
        end
    end
    nothing
end

function checkpoint_profile(; label="requested", final=false)
    session = PROFILE_SESSION[]
    session === nothing && return nothing
    trylock(session.lock) || return nothing
    started = time_ns()
    paused = false
    try
        session.sequence < PROFILE_MAX_CHECKPOINTS || return nothing
        session.stopping[] && !final && return nothing
        Profile.stop_timer()
        paused = true
        deadline = started+UInt64(round(PROFILE_EXPORT_SECONDS*1e9))
        data = Profile.fetch(; limitwarn=false)
        truncated = length(data) > PROFILE_SAMPLE_WORDS
        if length(data) > PROFILE_SAMPLE_WORDS
            # Keep a complete native sample, including its thread/task metadata.
            last = findprev(
                index->Profile.is_block_end(data, index),
                eachindex(data),
                PROFILE_SAMPLE_WORDS,
            )
            last === nothing && error("no complete profile sample within the word bound")
            resize!(data, last)
        end
        unavailable = resolve_profile_frames(session, data, deadline)
        if unavailable !== nothing
            profile_event(
                session,
                "profile_unavailable";
                reason=unavailable,
                label,
                capture_seconds=(time_ns()-started)/1e9,
                data_words=length(data),
            )
        end
        addresses = unique(Profile.has_meta(data) ? Profile.strip_meta(data) : data)
        frames = Dict{String,Any}("0"=>session.frames["0"])
        unresolved = 0
        for address in addresses
            key = string(address)
            frames[key] = get(session.frames, key, nothing)
            frames[key] === nothing && (unresolved += 1)
        end
        sequence = session.sequence+1
        birth_hash = bytes2hex(SHA.sha256(session.observer.process_birth_id))
        filename = "profile-$(session.mode)-$birth_hash-$sequence.json"
        path = joinpath(session.directory, filename)
        status = isempty(data) ? "empty" : "captured"
        payload = Dict{String,Any}(
            "schema"=>2,
            "invocation"=>session.observer.invocation,
            "source_digest"=>session.observer.source_digest,
            "process_birth_id"=>session.observer.process_birth_id,
            "pid"=>getpid(),
            "checkpoint_seq"=>sequence,
            "mode"=>session.mode,
            "status"=>status,
            "julia"=>string(VERSION),
            "threads"=>Threads.nthreads(),
            "label"=>sanitize(label),
            "data"=>data,
            "lookup"=>frames,
            "symbolization_status"=>unresolved == 0 ? "complete" : "partial",
            "unresolved_addresses"=>unresolved,
            "measurement_scope"=>"cumulative_buffer; checkpoints overlap",
            "buffer_full"=>Profile.is_buffer_full(),
            "truncated"=>truncated,
        )
        buffer = ProfileBuffer(IOBuffer(), PROFILE_MAX_BYTES)
        json_value(buffer, payload)
        write(buffer, '\n')
        bytes = take!(buffer.io)
        digest = bytes2hex(SHA.sha256(bytes))
        temporary = path*".tmp"
        try
            open(temporary, "w") do io
                write(io, bytes)
                flush(io)
            end
            mv(temporary, path; force=false)
        finally
            ispath(temporary) && rm(temporary)
        end
        session.sequence = sequence
        profile_event(
            session,
            "profile_checkpoint";
            label=sanitize(label),
            checkpoint_seq=sequence,
            file=filename,
            status,
            input_sha256=digest,
            data_words=length(data),
            buffer_full=payload["buffer_full"],
            truncated,
            symbolization_status=payload["symbolization_status"],
            unresolved_addresses=unresolved,
            capture_seconds=(time_ns()-started)/1e9,
            symbolization_cache_addresses=length(session.lookup),
            measurement_scope=payload["measurement_scope"],
        )
        (path=path, payload=payload)
    catch error
        push!(session.observer.faults, "profile_checkpoint:"*string(nameof(typeof(error))))
        profile_event(
            session,
            "profile_unavailable";
            reason="checkpoint_failed",
            error_type=string(nameof(typeof(error))),
            label=sanitize(label),
        )
        nothing
    finally
        session.overhead_ns += time_ns()-started
        if paused && !session.stopping[]
            try
                resume_sampler(session)
                session.stopping[] && Profile.stop_timer()
            catch error
                session.stopping[] = true
                profile_event(
                    session,
                    "profile_unavailable";
                    reason="sampler_restart_failed",
                    error_type=string(nameof(typeof(error))),
                )
            end
        end
        if session.stopping[] && PROFILE_SESSION[] === session
            PROFILE_SESSION[] = nothing
        end
        unlock(session.lock)
    end
end

function stop_profiles()
    session = PROFILE_SESSION[]
    session === nothing && return
    session.stopping[] = true
    close(session.timer)
    Profile.stop_timer()
    owns_export = trylock(session.lock)
    try
        if owns_export
            checkpoint_profile(; label="final", final=true)
        else
            profile_event(session, "profile_unavailable"; reason="finalization_busy")
        end
        profile_event(
            session,
            "profile_stop";
            checkpoint_count=session.sequence,
            export_seconds=session.overhead_ns/1e9,
            timer_closed=(!isopen(session.timer)),
            checkpoint_task_retired=session.task === nothing || istaskdone(session.task),
            retirement_scope="timer_closed; task_cooperative; supervisor_reaps_process",
        )
    finally
        if owns_export
            PROFILE_SESSION[] = nothing
            unlock(session.lock)
        end
    end
    nothing
end

function decode_profile(payload::AbstractDict)
    payload["schema"] == 2 || throw(ArgumentError("unsupported profile schema"))
    payload["julia"] == string(VERSION) ||
        throw(ArgumentError("native profile decoding requires its Julia version"))
    payload["mode"] in ("cpu", "wall") || throw(ArgumentError("invalid profile mode"))
    payload["mode"] == "wall" &&
        VERSION < v"1.13" &&
        throw(ArgumentError("wall sampling requires Julia 1.13"))
    data = UInt.(payload["data"])
    lookup = Profile.LineInfoDict()
    for (address, frames) in payload["lookup"]
        lookup[parse(UInt, address)] =
            frames === nothing ?
            [
                Base.StackTraces.StackFrame(
                    :symbolization_unavailable,
                    :unknown,
                    0,
                    nothing,
                    false,
                    false,
                    UInt(0),
                ),
            ] :
            [
                Base.StackTraces.StackFrame(
                    Symbol(frame["function"]),
                    Symbol(frame["file"]),
                    Int(frame["line"]),
                    nothing,
                    frame["from_c"],
                    frame["inlined"],
                    UInt(0),
                ) for frame in frames
            ]
    end
    haskey(lookup, UInt(0)) || throw(ArgumentError("profile has no NULL frame lookup"))
    data, lookup
end
