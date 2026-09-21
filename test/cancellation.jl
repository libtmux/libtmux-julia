@testset "public cancellation subscriptions" begin
    token = CancellationToken()
    @test !iscancelled(token)
    calls = Ref(0)
    retired = on_cancel(() -> (calls[] += 1), token)
    close(retired)
    close(retired)
    live = on_cancel(() -> (calls[] += 1), token)
    cancel!(token)
    cancel!(token)
    @test iscancelled(token) && calls[] == 1
    close(live)
    late = on_cancel(() -> (calls[] += 1), token)
    @test calls[] == 2
    close(late)

    token = CancellationToken()
    failed = on_cancel(() -> error("callback failed"), token)
    signalled = Ref(false)
    survivor = on_cancel(() -> (signalled[] = true), token)
    @test_throws CompositeException cancel!(token)
    @test signalled[] && iscancelled(token)
    close(failed)
    close(survivor)

    token = CancellationToken()
    entered, release, retired = Base.Event(), Base.Event(), Base.Event()
    subscription = on_cancel(token) do
        notify(entered)
        wait(release)
        notify(retired)
    end
    cancelling = Threads.@spawn cancel!(token)
    wait(entered)
    closing = Threads.@spawn begin
        close(subscription)
        retired.set
    end
    notify(release)
    fetch(cancelling)
    @test fetch(closing)
    @test isempty(token.hooks)
end
