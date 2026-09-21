using LibTmux

function main()
    with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        session = new_session(server; name="control", command=["/bin/cat"])
        open_control(server, session) do connection
            signal = control_signal(connection)
            token = CancellationToken()
            waiting = Threads.@spawn try
                wait(signal; cancel=token)
            catch error
                error
            end
            cancel!(token)
            @assert fetch(waiting) isa RequestCancelled
            @assert isopen(connection)
        end
        @assert isempty(clients(snapshot(server)))
    end
    println("Cancelled the wait and closed both owned control clients")
end

main()
