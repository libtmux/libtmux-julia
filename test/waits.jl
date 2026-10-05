using Test, LibTmux

# Outer: stream waits verify real output, timer retirement and target loss.
@testset "shared core output waits" begin
    names = (:OutputWaitResult, :wait_for, :wait_for_text, :wait_for_quiet)
    @test all(name -> isdefined(LibTmux, name), names)
    if all(name -> isdefined(LibTmux, name), names)
        directory = Ref("")
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
        )
        with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux"), env=environment) do server
            directory[] = dirname(server.socket_path)
            created = new_session(server; name="waits", command=["/bin/cat"])
            pane = only(panes(snapshot(server))).ref
            open_control(server, created) do connection
                observe_output(connection, pane) do stream
                    @test_throws UnsupportedCapability wait_for_text(
                        stream,
                        "x";
                        mode=:rendered,
                    )
                    @test_throws ArgumentError wait_for_text(stream, "")
                    @test_throws ArgumentError wait_for_text(stream, "long"; max_bytes=2)
                    @test_throws ArgumentError wait_for_quiet(stream; quiet=0)
                    send_keys(connection, pane, "ready λ"; literal=true)
                    fresh = wait_for_text(stream, "λ"; timeout=0.9)
                    @test fresh isa OutputWaitResult
                    @test fresh.source === :output && fresh.evidence === :literal_text
                    @test fresh.cursor.pane == pane.id
                    @test fresh.continuity === :stream && fresh.pending_bytes == 0
                    send_keys(connection, pane, "wide λ"; literal=true)
                    wide = try
                        wait_for_text(stream, "λ"; max_bytes=UInt64(64), timeout=0.1)
                    catch error
                        error
                    end
                    @test wide isa OutputWaitResult
                    wide isa OutputWaitResult && @test occursin("λ", wide.text)
                    send_keys(
                        connection,
                        pane,
                        "middle-hit" * repeat("z", 128);
                        literal=true,
                    )
                    middle = try
                        wait_for_text(stream, "hit"; max_bytes=8, timeout=0.1)
                    catch error
                        error
                    end
                    @test middle isa OutputWaitResult
                    middle isa OutputWaitResult &&
                        @test occursin("hit", middle.text) && ncodeunits(middle.text) <= 8
                    baseline = wait_for_text(stream, "ready λ"; baseline=true, timeout=0.9)
                    @test baseline.source === :baseline && baseline.continuity === :reset

                    send_keys(connection, pane, "-prefix"; literal=true)
                    wait_for_text(stream, "-prefix"; timeout=0.9)
                    seen = OutputWaitResult[]
                    token = CancellationToken()
                    crossed = try
                        wait_for(stream; baseline=true, timeout=0.9, cancel=token) do result
                            push!(seen, result)
                            matched = occursin("-prefix-suffix", result.text)
                            if result.source === :baseline
                                send_keys(connection, pane, "-suffix"; literal=true)
                            elseif !matched && occursin("-suffix", result.text)
                                cancel!(token)
                            end
                            matched
                        end
                    catch error
                        error
                    end
                    @test crossed isa RequestCancelled
                    @test first(seen).source === :baseline
                    @test any(
                        result ->
                            result.source === :output && occursin("-suffix", result.text),
                        seen,
                    )
                    @test all(
                        result ->
                            result.source !== :output || !occursin("-prefix", result.text),
                        seen,
                    )
                    @test_throws DeadlineExceeded wait_for(_ -> false, stream; timeout=0.02)

                    send_keys(connection, pane, repeat("a", 64) * "λend"; literal=true)
                    bounded = wait_for(stream; max_bytes=8, timeout=0.9) do result
                        endswith(result.text, "λend")
                    end
                    @test ncodeunits(bounded.text) <= 8 && isvalid(bounded.text)
                    @test bounded.dropped_bytes > 0 && bounded.received_bytes >= 64
                    quiet = wait_for_quiet(stream; quiet=0.02, timeout=0.2)
                    @test quiet.evidence === :quiet && quiet.source === :output
                    @test isopen(stream)
                    @test_throws DeadlineExceeded wait_for_quiet(
                        stream;
                        quiet=0.2,
                        timeout=0.02,
                    )
                    token = CancellationToken()
                    cancel!(token)
                    @test_throws RequestCancelled wait_for_text(
                        stream,
                        "absent";
                        cancel=token,
                    )
                    @test_throws RequestCancelled wait_for_quiet(stream; cancel=token)
                    send_keys(connection, pane, "cancel-result"; literal=true)
                    token = CancellationToken()
                    rejected = try
                        wait_for(stream; cancel=token, timeout=0.9) do result
                            cancel!(token)
                            true
                        end
                    catch error
                        error
                    end
                    @test rejected isa RequestCancelled
                    @test isempty(token.hooks)
                end
                observe_output(connection, pane; max_bytes=1) do stream
                    send_keys(connection, pane, "overflow"; literal=true)
                    failure = try
                        wait_for_text(stream, "o"; timeout=0.9)
                    catch error
                        error
                    end
                    @test failure isa ObservationLost
                    @test failure.reason === :overflow
                end
                for mode in (:matched, :cancelled, :predicate_error)
                    signal = "utf8-" * string(time_ns())
                    child = [
                        "/bin/sh",
                        "-c",
                        "IFS= read -r line; printf 'hit\\316'; \"\$1\" -N -S \"\$2\" wait-for \"\$3\"; printf '\\273done'; exec /bin/cat",
                        "sh",
                        server.tmux,
                        server.socket_path,
                        signal,
                    ]
                    utf8 = split_window(connection, pane; command=child)
                    observe_output(connection, utf8) do stream
                        send_keys(connection, utf8, "Enter")
                        if mode === :matched
                            first = wait_for_text(stream, "hit"; timeout=0.9)
                            @test first.pending_bytes == 1
                            @test_throws ArgumentError wait_for_quiet(
                                stream;
                                invalid=:replace,
                            )
                            baseline =
                                wait_for_text(stream, "hit"; baseline=true, timeout=0.9)
                            @test baseline.source === :baseline
                        else
                            token = CancellationToken()
                            interrupted = try
                                wait_for(stream; timeout=0.9, cancel=token) do result
                                    occursin("hit", result.text) || return false
                                    @test result.pending_bytes == 1
                                    @test_throws ArgumentError wait_for_quiet(stream)
                                    @test_throws ArgumentError take!(stream; timeout=0.1)
                                    mode === :cancelled ? cancel!(token) :
                                    error("predicate stopped")
                                    true
                                end
                            catch error
                                error
                            end
                            @test interrupted isa
                                  (mode === :cancelled ? RequestCancelled : ErrorException)
                        end
                        run_command(server, "wait-for", "-S", signal; timeout=0.9)
                        second = try
                            mode === :cancelled ?
                            wait_for_quiet(stream; quiet=0.02, timeout=0.9) :
                            wait_for_text(stream, "done"; timeout=0.9)
                        catch error
                            error
                        end
                        @test second isa OutputWaitResult
                        second isa OutputWaitResult &&
                            @test occursin("λdone", second.text) &&
                                  second.pending_bytes == 0
                        if mode === :matched
                            @test wait_for_quiet(
                                stream;
                                invalid=:replace,
                                quiet=0.01,
                                timeout=0.1,
                            ).pending_bytes == 0
                            send_keys(connection, utf8, "raw"; literal=true)
                            take!(stream; timeout=0.9)
                            @test_throws ArgumentError wait_for_text(stream, "later")
                        end
                    end
                    kill_pane(connection, utf8)
                end
                victim = split_window(connection, pane; command=["/bin/cat"])
                observe_output(connection, victim) do stream
                    kill_pane(connection, victim)
                    @test_throws ObservationLost wait_for_text(
                        stream,
                        "absent";
                        timeout=0.9,
                    )
                end
            end
            @test isempty(clients(snapshot(server)))
        end
        @test !ispath(directory[])
    end
end
