using LibTmux

function main()
    endpoint = Ref{Server}()
    report = with_server(; tmux=get(ENV, "LIBTMUX_TEST_TMUX", "tmux")) do server
        endpoint[] = server
        session = new_session(server; name="capabilities", command=["/bin/cat"])
        observed = capabilities(server)
        @assert capability(observed, "layout-json").since == "3.8"
        @assert workaround(observed, "name-separators-rejected").handling === :refuse
        if supports(observed, "control-mode")
            open_control(server, session) do connection
                connected = capabilities(connection)
                @assert connected.generation == observed.generation
                @assert supports(connected, "layout-json") ==
                        supports(observed, "layout-json")
            end
        end
        observed
    end
    @assert !ispath(dirname(endpoint[].socket_path))
    @assert supports(report, "buffer-delete-named") isa Bool
    println("Capability report remains readable after owned server cleanup")
    report
end

main()
