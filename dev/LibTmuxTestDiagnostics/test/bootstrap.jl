# Outer: separate Julia children verify preload, stdout and exit behavior.
const CHILD_BOOTSTRAP = normpath(joinpath(@__DIR__, "..", "src", "bootstrap.jl"))

function bootstrap_child(directory, mode, code; token="bootstrap-child")
    error_output =
        code == 0 ? "" :
        "write(stderr, UInt8[0, 255]); " *
        "print(stderr, \"intentional application error\"); flush(stderr); "
    program =
        "write(stdout, UInt8[0, 1, 127, 255]); " *
        "print(stdout, rand(UInt64, 8)); flush(stdout); " *
        error_output *
        "exit($code)"
    seed = "using Random; Random.seed!(0x12345678)"
    command = `$(Base.julia_cmd()) --startup-file=no --depwarn=error --threads=$(Threads.nthreads()) -e $seed --load $CHILD_BOOTSTRAP -e $program`
    environment = copy(ENV)
    pop!(environment, "TMUX", nothing)
    pop!(environment, "TMUX_PANE", nothing)
    merge!(
        environment,
        Dict(
            "JULIA_LOAD_PATH"=>"@:@stdlib",
            "JULIA_PKG_OFFLINE"=>"true",
            "LIBTMUX_CI_PROFILE"=>mode,
            "LIBTMUX_CI_PROFILE_SYMBOLIZATION"=>"deferred",
            "LIBTMUX_CI_CHILD_TOKEN"=>token,
            "LIBTMUX_CI_PROCESS_TOKEN"=>"bootstrap-parent",
            "LIBTMUX_CI_PARENT_PROCESS_BIRTH_ID"=>"bootstrap-parent-1",
            "LIBTMUX_CI_INVOCATION"=>"bootstrap-critical-controls",
            "LIBTMUX_CI_SOURCE_DIGEST"=>repeat("d", 64),
            "LIBTMUX_CI_PHASE"=>"bootstrap-child",
            "LIBTMUX_CI_DIAGNOSTICS_DIR"=>directory,
            "LIBTMUX_CI_SOURCE_ROOT"=>normpath(joinpath(@__DIR__, "..", "..", "..")),
        ),
    )
    output, errors = IOBuffer(), IOBuffer()
    process = run(
        pipeline(setenv(command, environment); stdout=output, stderr=errors);
        wait=false,
    )
    wait(process)
    eventfiles = filter(name->startswith(name, "events-"), readdir(directory))
    events = join(read(joinpath(directory, file), String) for file in eventfiles)
    (;
        exitcode=process.exitcode,
        output=take!(output),
        errors=String(take!(errors)),
        events,
    )
end

function check_bootstrap_controls(directory)
    disabled = mkpath(joinpath(directory, "off"))
    zero = mkpath(joinpath(directory, "zero"))
    failed = mkpath(joinpath(directory, "failed"))
    rejected = mkpath(joinpath(directory, "rejected"))
    plain = bootstrap_child(disabled, "off", 0)
    profiled = bootstrap_child(zero, "cpu", 0)
    nonzero = bootstrap_child(failed, "cpu", 7)
    inherited = bootstrap_child(rejected, "cpu", 0; token="bootstrap-parent")
    @assert plain.exitcode == profiled.exitcode == 0
    @assert nonzero.exitcode == 7
    @assert plain.output == profiled.output == nonzero.output
    @assert isempty(plain.errors) && isempty(profiled.errors)
    @assert codeunits(nonzero.errors) ==
            UInt8[0, 255, codeunits("intentional application error")...]
    @assert isempty(plain.events)
    @assert occursin("\"event\":\"child_bootstrap_start\"", profiled.events)
    @assert occursin("\"outcome\":\"exit_zero\"", profiled.events)
    @assert occursin("\"application_completion\":\"unproved\"", profiled.events)
    @assert occursin("\"outcome\":\"exit_nonzero\"", nonzero.events)
    @assert occursin("\"exit_code\":7", nonzero.events)
    @assert !occursin("testset_finalize", profiled.events)
    @assert !occursin("testset_start", profiled.events)
    finish = only(
        filter(
            line->occursin("\"event\":\"process_finish\"", line),
            split(nonzero.events, '\n'),
        ),
    )
    @assert occursin("\"outcome\":\"exit_nonzero\"", finish)
    @assert !occursin("\"outcome\":\"returned\"", finish)
    @assert inherited.exitcode != 0 && isempty(inherited.output)
    @assert occursin("child token must differ", inherited.errors)
    nothing
end

bootstrap_started = time_ns()
mktempdir(check_bootstrap_controls)
println("PASS child bootstrap controls; seconds=", (time_ns()-bootstrap_started)/1e9)
