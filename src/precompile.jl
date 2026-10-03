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
            ss=[["\$0", "precompile", "2", "1", "1", "1"]],
            ws=[[
                "@0",
                "window",
                "80",
                "24",
                "\$0",
                "0",
                "1",
                "layout",
                "visible",
                "0",
                "1",
            ]],
            ps=[[
                "%0",
                "@0",
                "0",
                "1",
                "0",
                "80",
                "24",
                "cat",
                "/",
                "title",
                "123",
                "/dev/pts/0",
                "",
                "0",
                "2000",
                "0",
                "0",
            ]],
            cs=Vector{String}[],
        )
        snapshot_type = typeof(_snapshot_from_rows(identity, rows, (0.0, 0.0)))
        for (View, Where, collection) in (
            (SessionSnapshot, SessionWhere, sessions),
            (WindowSnapshot, WindowWhere, windows),
            (PaneSnapshot, PaneWhere, panes),
            (ClientSnapshot, ClientWhere, clients),
            (WindowLink, WindowLinkWhere, windowlinks),
        )
            view_type = View{snapshot_type}
            selection_type = Selection{view_type}
            precompile(Tuple{typeof(collection),snapshot_type})
            precompile(Tuple{typeof(Base.getproperty),view_type,Symbol})
            precompile(Tuple{typeof(Base.getindex),selection_type,Int})
            precompile(Tuple{Where,view_type})
            precompile(Tuple{typeof(Base.filter),Where,selection_type})
            precompile(Tuple{typeof(encode_where),Where})
        end
        precompile(Tuple{typeof(paneoccurrences),snapshot_type})
        for encoder in (encode_typescript_where, encode_rust_where)
            precompile(Tuple{typeof(encoder),PaneWhere})
        end
        for decoder in (decode_where, decode_typescript_where, decode_rust_where)
            precompile(Tuple{typeof(decoder),Dict{String,Any}})
        end
        push!(
            rows.ps,
            [
                "%1",
                "@0",
                "1",
                "0",
                "1",
                "80",
                "24",
                "",
                "",
                "",
                "124",
                "",
                "7",
                "0",
                "2000",
                "0",
                "0",
            ],
        )
        push!(rows.cs, ["client", "123", "1", "\$0", "1"])
        _snapshot_from_rows(identity, rows, (0.0, 0.0))
    end

end
