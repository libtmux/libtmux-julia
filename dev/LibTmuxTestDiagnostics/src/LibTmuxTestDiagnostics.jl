module LibTmuxTestDiagnostics

using Random
using Test

mutable struct Observer
    io::IOStream
    root::String
    invocation::String
    source_digest::String
    process_birth_id::String
    phase::Union{String,Nothing}
    console::Bool
    started::UInt64
    sequence::Int
    next_testset::Int
    lock::ReentrantLock
    faults::Vector{String}
    coverage_complete::Bool
    admission_stop_cause::Union{Nothing,String}
end

const OBSERVER = Ref{Union{Nothing,Observer}}(nothing)
const TESTSET_ALIAS = :__LibTmuxDiagnosticTestSet
const PROFILE_SESSION = Ref{Any}(nothing)
const CONSOLE_EVENTS = Set((
    "process_start",
    "process_finish",
    "span_start",
    "span_finish",
    "testset_start",
    "testset_body_end",
    "testset_finalize",
    "assertion_problem",
    "profile_checkpoint",
    "coverage_incomplete",
))

function start_profiles end
function stop_profiles end
function checkpoint_profile end
function decode_profile end

function load_profiling()
    isdefined(LibTmuxTestDiagnostics, :ProfileSession) ||
        include(joinpath(@__DIR__, "profiling.jl"))
    nothing
end

function source_file(file, observer=OBSERVER[])
    text = string(file)
    isabspath(text) || return text
    if observer !== nothing
        relative = relpath(text, observer.root)
        if relative != ".." && !startswith(relative, "../")
            return replace(relative, '\\'=>'/')
        end
    end
    "external/" * basename(text)
end

function sanitize(text::AbstractString)
    answer = String(text)
    observer = OBSERVER[]
    if observer !== nothing
        for prefix in unique((observer.root, Base.contractuser(observer.root)))
            pattern = Regex("(?<![A-Za-z0-9_~])\\Q" * prefix * "\\E/[^\\s\"'<>),;]+")
            answer = replace(
                answer,
                pattern=>token->begin
                    relative = replace(token, prefix * "/"=>""; count=1)
                    occursin(r"(?:^|[/\\])\.\.(?:[/\\]|$)", relative) ?
                    "[external_path]" : relative
                end,
            )
        end
    end
    answer = replace(answer, r"[A-Za-z]:[\\/][^\s\"'<>),;]*"=>"[external_path]")
    answer = replace(answer, r"\\\\[^\s\"'<>),;]+"=>"[external_path]")
    answer = replace(answer, r"(?<![A-Za-z0-9_])(?:~?/)[^\s\"'<>),;]+"=>"[external_path]")
    answer
end

function json_string(io, value::AbstractString)
    write(io, '"')
    for character in value
        if character == '"'
            write(io, "\\\"")
        elseif character == '\\'
            write(io, "\\\\")
        elseif character == '\n'
            write(io, "\\n")
        elseif character == '\r'
            write(io, "\\r")
        elseif character == '\t'
            write(io, "\\t")
        elseif Int(character) < 0x20
            write(io, "\\u", lpad(string(Int(character); base=16), 4, '0'))
        else
            write(io, character)
        end
    end
    write(io, '"')
end

function json_value(io, value)
    if value === nothing
        write(io, "null")
    elseif value isa AbstractString || value isa Symbol
        json_string(io, string(value))
    elseif value isa Bool
        write(io, value ? "true" : "false")
    elseif value isa Integer
        print(io, value)
    elseif value isa AbstractFloat
        isfinite(value) ? print(io, value) : write(io, "null")
    elseif value isa AbstractDict
        write(io, '{')
        for (index, key) in enumerate(sort!(collect(keys(value)); by=string))
            index == 1 || write(io, ',')
            json_string(io, string(key))
            write(io, ':')
            json_value(io, value[key])
        end
        write(io, '}')
    elseif value isa Tuple || value isa AbstractVector
        write(io, '[')
        for (index, item) in enumerate(value)
            index == 1 || write(io, ',')
            json_value(io, item)
        end
        write(io, ']')
    else
        throw(ArgumentError("unsupported diagnostic value type"))
    end
end

function emit(event; fields...)
    observer = OBSERVER[]
    observer === nothing && return false
    lock(observer.lock) do
        observer.sequence += 1
        record = Dict{String,Any}(string(key)=>value for (key, value) in fields)
        merge!(
            record,
            Dict(
                "schema"=>2,
                "event"=>event,
                "seq"=>observer.sequence,
                "pid"=>getpid(),
                "thread"=>Threads.threadid(),
                "invocation"=>observer.invocation,
                "source_digest"=>observer.source_digest,
                "process_birth_id"=>observer.process_birth_id,
                "elapsed_ns"=>time_ns()-observer.started,
            ),
        )
        try
            json_value(observer.io, record)
            write(observer.io, '\n')
            flush(observer.io)
            if observer.console && event in CONSOLE_EVENTS
                try
                    packet = merge(record, Dict("ci_phase"=>observer.phase))
                    buffer = IOBuffer()
                    write(buffer, "\nLIBTMUX_TEST_PROGRESS ")
                    json_value(buffer, packet)
                    write(buffer, '\n')
                    bytes = take!(buffer)
                    lock(stdout)
                    try
                        write(stdout, bytes)
                        flush(stdout)
                    finally
                        unlock(stdout)
                    end
                catch error
                    push!(observer.faults, "console_write:"*string(nameof(typeof(error))))
                    observer.console = false
                    observer.coverage_complete = false
                    emit(
                        "coverage_incomplete";
                        reason="live_output_failed",
                        error_type=string(nameof(typeof(error))),
                    )
                end
            end
            true
        catch error
            push!(observer.faults, string(nameof(typeof(error))))
            false
        end
    end
end

function identity(value, label)
    text = String(value)
    occursin(r"\A[A-Za-z0-9._-]{1,128}\z", text) || throw(ArgumentError("invalid $label"))
    text
end

function start_observer(
    directory;
    root=pwd(),
    invocation::AbstractString,
    source_digest::AbstractString,
    process_birth_id::AbstractString,
    phase=get(ENV, "LIBTMUX_CI_PHASE", nothing),
    profile_mode=get(ENV, "LIBTMUX_CI_PROFILE", "off"),
    profile_symbolization=get(ENV, "LIBTMUX_CI_PROFILE_SYMBOLIZATION", "native"),
    console::Bool=false,
)
    OBSERVER[] === nothing || error("an observer already owns this process")
    run_id = identity(invocation, "invocation")
    birth_id = identity(process_birth_id, "process birth identity")
    phase_id = phase === nothing ? nothing : identity(phase, "phase")
    profile_mode in ("off", "cpu", "wall") ||
        throw(ArgumentError("profile mode must be off, cpu or wall"))
    profile_symbolization in ("native", "deferred") ||
        throw(ArgumentError("profile symbolization must be native or deferred"))
    occursin(r"\A[0-9a-f]{64}\z", source_digest) ||
        throw(ArgumentError("source digest must be SHA256"))
    mkpath(directory)
    path = joinpath(directory, "events-$birth_id.jsonl")
    ispath(path) && error("diagnostic event file already exists")
    observer = Observer(
        open(path, "w"),
        abspath(root),
        run_id,
        String(source_digest),
        birth_id,
        phase_id,
        console,
        time_ns(),
        0,
        0,
        ReentrantLock(),
        String[],
        true,
        nothing,
    )
    OBSERVER[] = observer
    emit(
        "process_start";
        julia=string(VERSION),
        threads=Threads.nthreads(),
        parent_pid=Int(ccall(:getppid, Cint, ())),
        phase=phase_id,
        compile_status="unavailable_no_counter_ownership",
    )
    if profile_mode != "off"
        import_started = time_ns()
        try
            load_profiling()
            import_seconds = (time_ns()-import_started)/1e9
            Base.invokelatest(
                start_profiles,
                observer,
                abspath(directory),
                profile_mode;
                import_seconds,
                symbolization=profile_symbolization,
            )
        catch error
            push!(observer.faults, "profile_start:" * string(nameof(typeof(error))))
            emit(
                "profile_unavailable";
                mode=profile_mode,
                reason="sampler_start_failed",
                error_type=string(nameof(typeof(error))),
            )
        end
    end
    observer
end

function close_observer(; outcome="unknown")
    observer = OBSERVER[]
    observer === nothing && return
    PROFILE_SESSION[] === nothing || Base.invokelatest(stop_profiles)
    emit(
        "process_finish";
        outcome,
        coverage_complete=observer.coverage_complete,
        observer_faults=copy(observer.faults),
    )
    close(observer.io)
    OBSERVER[] = nothing
    nothing
end

function incomplete(reason, source; file_exception=nothing)
    observer = OBSERVER[]
    observer === nothing && return
    observer.coverage_complete = false
    details = file_exception === nothing ? (;) : (; file_exception)
    emit(
        "coverage_incomplete";
        reason,
        file=source_file(source.file),
        line=Int(source.line),
        details...,
    )
    nothing
end

function stop_cause(error)
    error isa InterruptException && return "interrupt"
    error isa Union{OutOfMemoryError,StackOverflowError} && return "resource_failure"
    pending = Any[error]
    seen = Base.IdSet{Any}()
    while !isempty(pending)
        length(seen) >= 128 && return "uninspectable_exception_chain"
        current = pop!(pending)
        current in seen && continue
        push!(seen, current)
        current isa InterruptException && return "interrupt"
        current isa Union{OutOfMemoryError,StackOverflowError} && return "resource_failure"
        if current isa LoadError
            length(seen) + length(pending) >= 128 && return "uninspectable_exception_chain"
            push!(pending, current.error)
        elseif current isa CapturedException
            length(seen) + length(pending) >= 128 && return "uninspectable_exception_chain"
            push!(pending, current.ex)
        elseif current isa CompositeException
            for item in current.exceptions
                length(seen) + length(pending) >= 128 &&
                    return "uninspectable_exception_chain"
                push!(pending, item)
            end
        elseif current isa TaskFailedException
            for item in Base.current_exceptions(current.task; backtrace=false)
                length(seen) + length(pending) >= 128 &&
                    return "uninspectable_exception_chain"
                push!(pending, item.exception)
            end
        end
    end
    nothing
end

function admission_stopped()
    observer = OBSERVER[]
    observer === nothing && return false
    lock(observer.lock) do
        observer.admission_stop_cause !== nothing
    end
end

function stop_admission(cause, source)
    observer = OBSERVER[]
    observer === nothing && return
    lock(observer.lock) do
        observer.admission_stop_cause = cause
        incomplete("test_admission_stopped_" * cause, source)
    end
    nothing
end

function declare_files(files::AbstractVector{<:AbstractString})
    emit(
        "file_inventory";
        files=[source_file(file) for file in files],
        scope="declared_files_only",
    )
    nothing
end

mutable struct ObservedTestSet <: Test.AbstractTestSet
    delegate::Test.DefaultTestSet
    id::Int
    parent_id::Union{Int,Nothing}
    started::UInt64
    gc_start::Any
    source::Any
    body_outcome::String
end

function ObservedTestSet(description::AbstractString; diagnostic_source=nothing, kwargs...)
    parent = Test.get_testset()
    options = (; kwargs...)
    if parent isa ObservedTestSet && !haskey(options, :failfast)
        options = merge(options, (; failfast=parent.delegate.failfast))
    end
    if diagnostic_source !== nothing && !haskey(options, :source)
        options = merge(options, (; source=diagnostic_source.file))
    end
    delegate = Test.DefaultTestSet(description; options...)
    observer = OBSERVER[]
    id = observer === nothing ? 0 : lock(observer.lock) do
        observer.next_testset += 1
        observer.next_testset
    end
    parent_id = parent isa ObservedTestSet ? parent.id : nothing
    ts = ObservedTestSet(
        delegate,
        id,
        parent_id,
        time_ns(),
        Base.gc_num(),
        diagnostic_source,
        "not_entered",
    )
    diagnostic_source === nothing &&
        incomplete("unmapped_testset", LineNumberNode(0, :unknown))
    emit(
        "testset_start";
        testset_id=id,
        parent_id,
        description=sanitize(description),
        file=diagnostic_source === nothing ? nothing : source_file(diagnostic_source.file),
        line=diagnostic_source === nothing ? nothing : Int(diagnostic_source.line),
    )
    ts
end

function Test.record(ts::ObservedTestSet, result::Test.Result)
    observer = OBSERVER[]
    if observer !== nothing && result isa Union{Test.Fail,Test.Error}
        source = hasproperty(result, :source) ? result.source : nothing
        detail_status = "rendered"
        rendered = try
            sanitize(sprint(show, result; context=:limit=>true))
        catch error
            lock(observer.lock) do
                push!(observer.faults, "native_result_render:" * string(nameof(typeof(error))))
            end
            detail_status = "unavailable"
            "native result rendering failed"
        end
        emit(
            "assertion_problem";
            testset_id=ts.id,
            result_type=string(nameof(typeof(result))),
            problem_kind=string(result.test_type),
            file=source === nothing ? nothing : source_file(source.file),
            line=source === nothing ? nothing : Int(source.line),
            detail=rendered,
            detail_status,
        )
    end
    Test.record(ts.delegate, result)
end

Test.record(ts::ObservedTestSet, child::Test.AbstractTestSet) =
    Test.record(ts.delegate, child isa ObservedTestSet ? child.delegate : child)
Test.get_test_counts(ts::ObservedTestSet) = Test.get_test_counts(ts.delegate)

if isdefined(Test, :get_rng)
    @eval Test.get_rng(ts::ObservedTestSet) = Test.get_rng(ts.delegate)
    @eval Test.set_rng!(ts::ObservedTestSet, rng::Random.AbstractRNG) =
        Test.set_rng!(ts.delegate, rng)
end

function total_counts(ts)
    counts = Test.get_test_counts(ts)
    values =
        counts isa Tuple ? counts :
        (
            counts.passes,
            counts.fails,
            counts.errors,
            counts.broken,
            counts.cumulative_passes,
            counts.cumulative_fails,
            counts.cumulative_errors,
            counts.cumulative_broken,
        )
    Dict(
        "passed"=>values[1]+values[5],
        "failed"=>values[2]+values[6],
        "errored"=>values[3]+values[7],
        "broken"=>values[4]+values[8],
    )
end

function Test.finish(ts::ObservedTestSet)
    native_finish = "threw"
    try
        answer = Test.finish(ts.delegate)
        native_finish = "returned"
        answer
    finally
        if ts.body_outcome in ("interrupted", "not_entered", "running")
            incomplete(
                "testset_body_" * ts.body_outcome,
                ts.source === nothing ? LineNumberNode(0, :unknown) : ts.source,
            )
        end
        diff = Base.GC_Diff(Base.gc_num(), ts.gc_start)
        emit(
            "testset_finalize";
            testset_id=ts.id,
            parent_id=ts.parent_id,
            body_outcome=ts.body_outcome,
            native_finish,
            counts=total_counts(ts.delegate),
            seconds=(time_ns()-ts.started)/1e9,
            allocation_bytes=diff.allocd,
            gc_seconds=diff.total_time/1e9,
            metric_scope="process_wide_inclusive",
            compile_seconds=nothing,
            recompile_seconds=nothing,
            compile_status="unavailable_no_counter_ownership",
        )
    end
end

function body_start()
    ts = Test.get_testset()
    ts isa ObservedTestSet || return ts
    ts.body_outcome = "running"
    ts
end

function body_outcome(ts, value)
    ts isa ObservedTestSet && (ts.body_outcome = value)
    nothing
end

function body_finish(ts)
    ts isa ObservedTestSet || return
    ts.body_outcome == "running" && (ts.body_outcome = "nonlocal_exit")
    emit("testset_body_end"; testset_id=ts.id, body_outcome=ts.body_outcome)
    nothing
end

function instrument_body(body)
    token, error, answer, cause = gensym(:diagnostic_ts),
    gensym(:diagnostic_error),
    gensym(:answer),
    gensym(:stop_cause)
    quote
        local $token = $(GlobalRef(LibTmuxTestDiagnostics, :body_start))()
        try
            local $answer = $body
            $(GlobalRef(LibTmuxTestDiagnostics, :body_outcome))($token, "returned")
            $answer
        catch $error
            local $cause = $(GlobalRef(LibTmuxTestDiagnostics, :stop_cause))($error)
            if $cause !== nothing
                $(GlobalRef(LibTmuxTestDiagnostics, :stop_admission))(
                    $cause,
                    $token isa $(GlobalRef(LibTmuxTestDiagnostics, :ObservedTestSet)) &&
                    $token.source !== nothing ? $token.source : LineNumberNode(0, :unknown),
                )
            end
            $(GlobalRef(LibTmuxTestDiagnostics, :body_outcome))(
                $token,
                $cause == "interrupt" ? "interrupted" : "threw",
            )
            rethrow()
        finally
            $(GlobalRef(LibTmuxTestDiagnostics, :body_finish))($token)
        end
    end
end

function resolve_binding(module_::Module, name)
    if name isa Symbol
        return Base.invokelatest(isdefined, module_, name) ?
               Base.invokelatest(getfield, module_, name) : nothing
    elseif name isa GlobalRef
        return Base.invokelatest(isdefined, name.mod, name.name) ?
               Base.invokelatest(getfield, name.mod, name.name) : nothing
    elseif name isa Expr && name.head == :. && length(name.args) == 2
        owner = resolve_binding(module_, name.args[1])
        field = name.args[2] isa QuoteNode ? name.args[2].value : name.args[2]
        return owner isa Module &&
               field isa Symbol &&
               Base.invokelatest(isdefined, owner, field) ?
               Base.invokelatest(getfield, owner, field) : nothing
    end
    nothing
end

function install_alias(module_::Module)
    if Base.invokelatest(isdefined, module_, TESTSET_ALIAS)
        Base.invokelatest(getfield, module_, TESTSET_ALIAS) === ObservedTestSet ||
            error("diagnostic alias collision")
    else
        Core.eval(
            module_,
            Expr(
                :const,
                Expr(
                    :(=),
                    TESTSET_ALIAS,
                    GlobalRef(LibTmuxTestDiagnostics, :ObservedTestSet),
                ),
            ),
        )
    end
end

function mapped_testset(module_, ex, inherited_supported)
    source = ex.args[2]
    source isa LineNumberNode || return ex
    arguments = ex.args[3:end]
    isempty(arguments) && return ex
    body = arguments[end]
    options = arguments[1:(end-1)]
    types = [
        index for index in eachindex(options) if options[index] isa Symbol ||
            (options[index] isa Expr && options[index].head == :.)
    ]
    supported = inherited_supported
    if !isempty(types)
        supported =
            length(types) == 1 &&
            resolve_binding(module_, options[only(types)]) === Test.DefaultTestSet
    end
    context = body isa Expr && body.head == :let
    if !supported || context
        reason = context ? "context_testset" : "custom_or_unresolved_testset"
        return Expr(
            :block,
            Expr(
                :call,
                GlobalRef(LibTmuxTestDiagnostics, :incomplete),
                reason,
                QuoteNode(source),
            ),
            ex,
        )
    end
    options = Any[options...]
    if isempty(types)
        pushfirst!(options, TESTSET_ALIAS)
    else
        options[only(types)] = TESTSET_ALIAS
    end
    if body isa Expr &&
       body.head == :call &&
       !any(
           option->option isa AbstractString || (option isa Expr && option.head == :string),
           options,
       )
        push!(options, string(body.args[1]))
    end
    push!(options, Expr(:(=), :diagnostic_source, QuoteNode(source)))
    body = map_owned(module_, body, true)
    if body isa Expr && body.head == :for
        body = deepcopy(body)
        body.args[2] = instrument_body(body.args[2])
    else
        body = instrument_body(body)
    end
    Expr(:macrocall, ex.args[1], source, options..., body)
end

function map_owned(module_::Module, ex, inherited_supported=true)
    ex isa Expr || return ex
    ex.head in (:quote, :inert) && return ex
    if ex.head == :module
        return Expr(:module, ex.args[1], ex.args[2], deferred_module_syntax(ex.args[3]))
    end
    if ex.head == :macrocall
        resolve_binding(module_, ex.args[1]) === getfield(Test, Symbol("@testset")) &&
            return mapped_testset(module_, ex, inherited_supported)
        if contains_testset(module_, ex.args[3:end])
            source = ex.args[2]
            return Expr(
                :block,
                Expr(
                    :call,
                    GlobalRef(LibTmuxTestDiagnostics, :incomplete),
                    "testset_inside_opaque_macro",
                    QuoteNode(source),
                ),
                ex,
            )
        end
        # Other macros own their argument evaluation and quotation semantics.
        return ex
    end
    Expr(
        ex.head,
        map(argument->map_owned(module_, argument, inherited_supported), ex.args)...,
    )
end

function native_testset_spelling(name)
    name == Symbol("@testset") && return true
    name isa GlobalRef && return name.name == Symbol("@testset")
    name isa Expr && name.head == :. && length(name.args) == 2 || return false
    field = name.args[2] isa QuoteNode ? name.args[2].value : name.args[2]
    field == Symbol("@testset")
end

function contains_testset_spelling(ex)
    ex isa Expr || return false
    ex.head in (:quote, :inert) && return false
    ex.head == :macrocall && native_testset_spelling(ex.args[1]) && return true
    any(contains_testset_spelling, ex.args)
end

function deferred_module_syntax(ex)
    ex isa Expr || return ex
    ex.head in (:quote, :inert) && return ex
    if ex.head == :macrocall
        if native_testset_spelling(ex.args[1])
            return Expr(
                :macrocall,
                GlobalRef(LibTmuxTestDiagnostics, Symbol("@deferred_testset")),
                ex.args[2],
                QuoteNode(ex.args[1]),
                ex.args[3:end]...,
            )
        end
        if contains_testset_spelling(ex)
            return Expr(
                :block,
                Expr(
                    :call,
                    GlobalRef(LibTmuxTestDiagnostics, :incomplete),
                    "testset_inside_opaque_macro",
                    QuoteNode(ex.args[2]),
                ),
                ex,
            )
        end
        return ex
    end
    Expr(ex.head, map(deferred_module_syntax, ex.args)...)
end

macro deferred_testset(original, arguments...)
    original isa QuoteNode || error("diagnostic macro identity must be quoted")
    native = Expr(:macrocall, original.value, __source__, arguments...)
    resolve_binding(__module__, original.value) === getfield(Test, Symbol("@testset")) ||
        return esc(native)
    install_alias(__module__)
    esc(mapped_testset(__module__, native, true))
end

function contains_testset(module_, value)
    value isa AbstractVector && return any(item->contains_testset(module_, item), value)
    value isa Expr || return false
    value.head in (:quote, :inert) && return false
    if value.head == :macrocall &&
       resolve_binding(module_, value.args[1]) === getfield(Test, Symbol("@testset"))
        return true
    end
    any(item->contains_testset(module_, item), value.args)
end

function diagnostic_include(module_::Module, path::AbstractString)
    install_alias(module_)
    Base.include(ex->map_owned(module_, ex), module_, path)
end

function observe_span(f::Function, kind::AbstractString, label::AbstractString)
    started = time_ns()
    emit("span_start"; kind=sanitize(kind), label=sanitize(label))
    outcome = "threw"
    try
        answer = f()
        outcome = "returned"
        answer
    catch error
        outcome =
            stop_cause(error) == "interrupt" || admission_stopped() ? "interrupted" :
            "threw"
        rethrow()
    finally
        emit(
            "span_finish";
            kind=sanitize(kind),
            label=sanitize(label),
            outcome,
            seconds=(time_ns()-started)/1e9,
            compile_status="unavailable_no_counter_ownership",
        )
    end
end

end
