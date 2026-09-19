struct ProcessRetirementProbe{T}
    resource::T
    progress::Channel{Symbol}
end
function Base.close(probe::ProcessRetirementProbe)
    put!(probe.progress, :joining)
    close(probe.resource)
end
function Base.wait(probe::ProcessRetirementProbe)
    put!(probe.progress, :joining)
    wait(probe.resource)
end

@testset "process callback retirement" begin
    for kind in (:cancellation, :deadline)
        entered, release, registered = Base.Event(), Base.Event(), Base.Event()
        progress = Channel{Symbol}(2)
        token = CancellationToken()
        function subscribe(callback, token)
            subscription = on_cancel(token) do
                callback()
                notify(entered)
                wait(release)
            end
            notify(registered)
            ProcessRetirementProbe(subscription, progress)
        end
        timer_calls = Threads.Atomic{Int}(0)
        function timer_factory(callback, delay)
            ordinal = Threads.atomic_add!(timer_calls, 1)
            if ordinal == 0
                timer, task = LibTmux._owned_timer(delay) do
                    callback()
                    notify(entered)
                    wait(release)
                    error("retirement callback failed")
                end
                return timer, ProcessRetirementProbe(task, progress)
            end
            LibTmux._owned_timer(callback, delay)
        end
        operation = Threads.@spawn try
            if kind === :cancellation
                LibTmux._run_process(
                    `sh -c "while :; do :; done"`;
                    cancel=token,
                    _cancel_subscribe=subscribe,
                )
            else
                LibTmux._run_process(
                    `sh -c "while :; do :; done"`;
                    timeout=0.03,
                    _make_timer=timer_factory,
                )
            end
        catch error
            error
        end
        returned = Threads.@spawn begin
            wait(operation)
            put!(progress, :returned)
        end
        cancelling = nothing
        try
            if kind === :cancellation
                wait(registered)
                cancelling = Threads.@spawn cancel!(token)
            end
            wait(entered)
            @test take!(progress) === :joining
            @test !istaskdone(operation)
        finally
            notify(release)
            cancelling === nothing || fetch(cancelling)
            wait(returned)
        end
        failure = fetch(operation)
        if kind === :cancellation
            @test failure isa RequestCancelled && failure.sent
            @test failure.result.termsignal == Base.SIGKILL && isempty(token.hooks)
        else
            @test failure isa CompositeException
            if failure isa CompositeException
                @test first(failure.exceptions) isa DeadlineExceeded
                @test last(failure.exceptions) isa TaskFailedException
            end
        end
    end
end
