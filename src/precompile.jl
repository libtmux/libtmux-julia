# Native compilation only: no processes, timers, sockets or tasks run here.
if ccall(:jl_generating_output, Cint, ()) == 1
    precompile(Tuple{typeof(open_server)})
    precompile(
        Tuple{typeof(Core.kwcall),NamedTuple{(:tmux,),Tuple{String}},typeof(open_server)},
    )
    precompile(
        Tuple{
            typeof(Core.kwcall),
            NamedTuple{(:tmux, :env),Tuple{String,Dict{String,String}}},
            typeof(open_server),
        },
    )
    precompile(
        Tuple{typeof(_owned_ready),OwnedServer,Dict{String,String},Nothing,UInt64,Float64},
    )
    precompile(Tuple{typeof(_owned_stderr),Pipe})
    precompile(Tuple{typeof(close),OwnedServer})
    precompile(
        Tuple{
            typeof(Core.kwcall),
            NamedTuple{
                (:cancel, :timeout, :max_output_bytes, :max_error_bytes),
                Tuple{Nothing,Float64,Int,Int},
            },
            typeof(_run_process),
            Cmd,
        },
    )

    let stop = _ProcessStop{typeof(_owned_timer)}
        precompile(Tuple{_ProcessDrain{stop}})
        precompile(Tuple{_ProcessInput{stop}})
        precompile(Tuple{typeof(_run_owned_timer),Timer,_DeadlineCallback{stop}})
    end
    precompile(Tuple{typeof(_run_owned_timer),Timer,_ProcessDrainClose})
    precompile(Tuple{typeof(_run_owned_timer),Timer,_DeadlineCallback{_OwnedReadyStop}})

    precompile(
        Tuple{
            typeof(Core.kwcall),
            NamedTuple{(:name, :command),Tuple{String,Vector{String}}},
            typeof(new_session),
            Server,
        },
    )
    precompile(Tuple{typeof(snapshot),Server})
    precompile(Tuple{typeof(capture_pane),Server,PaneRef})
    precompile(Tuple{typeof(open_control),Server,SessionRef})
    for worker in (_control_reader, _control_writer, _control_supervise)
        precompile(Tuple{typeof(worker),ControlConnection})
    end
    precompile(Tuple{typeof(snapshot),ControlConnection})
    precompile(Tuple{typeof(capture_bytes),ControlConnection,PaneRef})
    let identity = ServerIdentity(socket_path="/precompile/s", generation="1:1")
        rows = (
            ss=[["\$0", "precompile", "2"]],
            ws=[["@0", "window", "80", "24", "\$0", "0", "1"]],
            ps=[["%0", "@0", "0", "1", "0", "80", "24", "cat", "/", "title"]],
            cs=Vector{String}[],
        )
        _snapshot_from_rows(identity, rows, (0.0, 0.0))
        push!(rows.ps, ["%1", "@0", "1", "0", "1", "80", "24", "", "", ""])
        push!(rows.cs, ["client", "123", "1", "\$0"])
        _snapshot_from_rows(identity, rows, (0.0, 0.0))
    end

end
