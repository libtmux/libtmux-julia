import SHA
import Profile

@noinline function diagnostic_hot_loop(duration)
    stop = time_ns()+UInt64(round(duration*1e9))
    value = 1.0
    while time_ns() < stop
        for index = 1:10_000
            value = sqrt(value+index)
        end
        yield()
    end
    value
end

@noinline diagnostic_wait_for_release(channel) = take!(channel)

function check_profile_controls(directory, mode)
    before = copy(Random.default_rng())
    source_digest = get(ENV, "LIBTMUX_CI_SOURCE_DIGEST", repeat("b", 64))
    observer = D.start_observer(
        directory;
        root=normpath(joinpath(@__DIR__, "..", "..", "..")),
        invocation="profile-controls",
        source_digest,
        process_birth_id="profile-"*mode,
        profile_mode="off",
    )
    D.load_profiling()
    buffer_type = Base.invokelatest(getfield, D, :ProfileBuffer)
    bounded = Base.invokelatest(buffer_type, IOBuffer(), 4)
    limit_error = try
        Base.invokelatest(write, bounded, "oversized")
        nothing
    catch error
        error
    end
    @assert limit_error isa ErrorException
    @assert isempty(take!(bounded.io))
    waiting = Channel{Bool}(1)
    waiting_task = @async diagnostic_wait_for_release(waiting)
    yield()
    Base.invokelatest(D.start_profiles, observer, directory, mode; interval=5.0)
    if mode == "wall" && VERSION < v"1.13"
        @assert D.PROFILE_SESSION[] === nothing
        put!(waiting, true)
        wait(waiting_task)
        D.close_observer(; outcome="returned")
        @assert occursin(
            "requires_julia_1_13",
            read(joinpath(directory, "events-profile-wall.jsonl"), String),
        )
        return (; mode, supported=false, checkpoints=0)
    end
    workers = [Threads.@spawn(diagnostic_hot_loop(0.20)) for _ = 1:Threads.nthreads()]
    @assert all(isfinite, fetch.(workers))
    @assert isfinite(diagnostic_hot_loop(0.20))
    checkpoint = Base.invokelatest(D.checkpoint_profile; label="control")
    @assert checkpoint !== nothing "portable native checkpoint was not retained"
    first_bytes = read(checkpoint.path)
    first_path = checkpoint.path
    for _ = 1:3
        checkpoint.payload["symbolization_status"] == "complete" && break
        checkpoint = Base.invokelatest(D.checkpoint_profile; label="resolved_control")
        @assert checkpoint !== nothing
    end
    @assert read(first_path) == first_bytes
    payload = checkpoint.payload
    data, lookup = Base.invokelatest(D.decode_profile, payload)
    @assert !isempty(data)
    @assert haskey(lookup, UInt(0))
    @assert lookup[UInt(0)] == [Base.StackTraces.UNKNOWN]
    @assert any(
        frame->occursin("diagnostic_hot_loop", string(frame.func)),
        Iterators.flatten(values(lookup)),
    )
    if mode == "wall"
        @assert any(
            frame->occursin("diagnostic_wait_for_release", string(frame.func)),
            Iterators.flatten(values(lookup)),
        )
    end
    native = sprint() do io
        Profile.print(io, data, lookup; format=:flat, sortedby=:count)
    end
    @assert occursin("diagnostic_hot_loop", native)
    @assert payload["mode"] == mode && payload["threads"] == Threads.nthreads()
    @assert payload["source_digest"] == source_digest
    bytes = read(checkpoint.path)
    digest = bytes2hex(SHA.sha256(bytes))
    @assert !occursin(r"/(?:home|Users|tmp|mnt)/", String(copy(bytes)))
    put!(waiting, true)
    wait(waiting_task)
    session = D.PROFILE_SESSION[]
    D.close_observer(; outcome="returned")
    yield()
    @assert session.stopping[] && !isopen(session.timer)
    @assert session.task === nothing || istaskdone(session.task)
    @assert !Profile.is_running()
    @assert D.PROFILE_SESSION[] === nothing
    @assert rand(copy(Random.default_rng())) == rand(before)
    events = read(joinpath(directory, "events-profile-"*mode*".jsonl"), String)
    @assert occursin("\"input_sha256\":\"$digest\"", events)
    @assert occursin("\"label\":\"final\"", events)
    @assert !occursin("checkpoint_failed", events)
    @assert session.sequence <= 8
    @assert all(name->ncodeunits(name) <= 128, readdir(directory))
    checkpoints = count(
        name->startswith(name, "profile-") && endswith(name, ".json"),
        readdir(directory),
    )
    (; mode, supported=true, checkpoints)
end

mode = length(ARGS) > 1 ? ARGS[2] : "cpu"
mode in ("cpu", "wall") || error("expected cpu or wall profile mode")
profile_started = time_ns()
profile_result = if length(ARGS) > 2
    directory = ARGS[3]
    mkpath(directory)
    check_profile_controls(directory, mode)
else
    mktempdir(directory->check_profile_controls(directory, mode))
end
println(
    "PASS profile controls; mode=",
    mode,
    "; supported=",
    profile_result.supported,
    "; threads=",
    Threads.nthreads(),
    "; checkpoints=",
    profile_result.checkpoints,
    "; seconds=",
    (time_ns()-profile_started)/1e9,
)
