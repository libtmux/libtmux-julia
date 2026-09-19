import FileWatching

struct StartupRetirementProbe
    subscription::CancellationSubscription
    progress::Channel{Symbol}
    failure::Exception
end
function Base.close(probe::StartupRetirementProbe)
    put!(probe.progress, :joining)
    close(probe.subscription)
    throw(probe.failure)
end

@testset "startup callback retirement" begin
    mktempdir(; prefix="ltj-start-retire-") do directory
        fifo = joinpath(directory, "hold")
        run(`mkfifo $fifo`)
        process = run(
            pipeline(
                ignorestatus(`cat $fifo`);
                stdin=devnull,
                stdout=devnull,
                stderr=devnull,
            );
            wait=false,
        )
        monitor = FileWatching.FolderMonitor(directory)
        owner = (;
            _process=process,
            _monitor=monitor,
            server=Server(socket_path=joinpath(directory, "missing-socket")),
        )
        token = CancellationToken()
        entered, release, registered = Base.Event(), Base.Event(), Base.Event()
        progress = Channel{Symbol}(2)
        sentinel = ErrorException("startup subscription cleanup failed")
        function subscribe(callback, token)
            subscription = on_cancel(token) do
                callback()
                notify(entered)
                wait(release)
            end
            notify(registered)
            StartupRetirementProbe(subscription, progress, sentinel)
        end
        operation = Threads.@spawn try
            LibTmux._owned_ready(
                owner,
                Dict{String,String}(),
                token,
                time_ns(),
                0.9;
                _cancel_subscribe=subscribe,
            )
        catch error
            error
        end
        returned = Threads.@spawn begin
            wait(operation)
            put!(progress, :returned)
        end
        cancelling = nothing
        try
            wait(registered)
            cancelling = Threads.@spawn cancel!(token)
            wait(entered)
            @test take!(progress) === :joining
            @test !istaskdone(operation)
        finally
            notify(release)
            cancelling === nothing || fetch(cancelling)
            wait(returned)
            process_running(process) && kill(process, Base.SIGKILL)
            wait(process)
            close(monitor)
        end
        failure = fetch(operation)
        @test failure isa CompositeException
        if failure isa CompositeException
            @test first(failure.exceptions) isa RequestCancelled
            @test last(failure.exceptions) === sentinel
        end
        @test isempty(token.hooks) && process_exited(process)
    end
end
