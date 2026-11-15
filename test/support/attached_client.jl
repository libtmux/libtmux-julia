module AttachedClient

export attach_client, stop!

"""
A tmux client attached to a session through a pseudo-terminal, as a user's terminal
holds one. Tests stop it with `stop!`, so tmux keeps a killed server alive until the
client is removed, or kill it to make the client leave. `control=true` attaches in
control mode. Close it to kill the client and release the terminal.
"""
mutable struct Client
    process::Base.Process
    master::Cint
    terminal::Base.Filesystem.File
end

Base.getpid(client::Client) = getpid(client.process)

function attach_client(tmux, socket, session; control::Bool=false)
    master, slave = Ref{Cint}(), Ref{Cint}()
    ccall(
        :openpty,
        Cint,
        (Ptr{Cint}, Ptr{Cint}, Ptr{UInt8}, Ptr{Cvoid}, Ptr{Cvoid}),
        master,
        slave,
        C_NULL,
        C_NULL,
        C_NULL,
    ) == 0 || Base.systemerror("openpty")
    terminal = Base.Filesystem.File(RawFD(slave[]))
    attach = control ? ["-C", "attach", "-t", session] : ["attach", "-t", session]
    environment = merge(Dict(ENV), Dict("TERM" => "xterm-256color"))
    command = setenv(Cmd([tmux, "-S", socket, attach...]), environment)
    process =
        run(pipeline(command; stdin=terminal, stdout=terminal, stderr=terminal); wait=false)
    Client(process, master[], terminal)
end

"Suspend the client, so it stops reading what tmux sends it."
stop!(client::Client) = run(`kill -STOP $(getpid(client))`)

function Base.close(client::Client)
    process_running(client.process) && kill(client.process, Base.SIGKILL)
    wait(client.process)
    client.master >= 0 && ccall(:close, Cint, (Cint,), client.master)
    client.master = -1
    isopen(client.terminal) && close(client.terminal)
    nothing
end

end
