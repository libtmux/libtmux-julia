"""
    Server(; socket_path=nothing, socket_name=nothing, tmux="tmux")

Describe a tmux endpoint without contacting it. Supply exactly one socket
selector. A description does not own a daemon or any sessions. Use `from_env`
to opt into the ambient tmux endpoint.
"""
struct Server
    socket_path::Union{Nothing,String}
    socket_name::Union{Nothing,String}
    tmux::String

    function Server(; socket_path=nothing, socket_name=nothing, tmux="tmux")
        (socket_path === nothing) != (socket_name === nothing) ||
            throw(ArgumentError("supply exactly one of socket_path or socket_name"))
        executable = _argument(tmux)
        isempty(executable) && throw(ArgumentError("tmux executable cannot be empty"))
        if socket_path !== nothing
            path = _argument(socket_path)
            isempty(path) && throw(ArgumentError("socket_path cannot be empty"))
            return new(abspath(path), nothing, executable)
        end
        name = _argument(socket_name)
        (isempty(name) || occursin('/', name)) &&
            throw(ArgumentError("socket_name must be nonempty and contain no slash"))
        new(nothing, name, executable)
    end
end

function _argument(value::AbstractString)
    occursin('\0', value) && throw(ArgumentError("tmux arguments cannot contain NUL"))
    String(value)
end

"""
    from_env(; env=ENV, socket_path=nothing, socket_name=nothing, tmux="tmux")

Read the endpoint from `TMUX`, or select the named `default` socket when it
is absent. Explicit selectors take precedence. This function performs no I/O.
"""
function from_env(; env=ENV, socket_path=nothing, socket_name=nothing, tmux="tmux")
    if socket_path !== nothing || socket_name !== nothing
        return Server(; socket_path, socket_name, tmux)
    end
    ambient = get(env, "TMUX", "")
    isempty(ambient) && return Server(; socket_name="default", tmux)
    fields = rsplit(ambient, ','; limit=3)
    length(fields) == 3 &&
    !isempty(fields[1]) &&
    tryparse(Int, fields[2]) !== nothing &&
    tryparse(Int, fields[3]) !== nothing || throw(
        ArgumentError("TMUX must contain a socket path, process ID and session index"),
    )
    Server(; socket_path=fields[1], tmux)
end

function _argv(server::Server, args)
    selector =
        server.socket_path === nothing ? ["-L", something(server.socket_name)] :
        ["-S", server.socket_path]
    [server.tmux; "-u"; selector; "--"; _argument.(args)]
end

function Base.show(io::IO, server::Server)
    print(io, "Server(")
    if server.socket_path === nothing
        print(io, "socket_name=")
        show(io, server.socket_name)
    else
        print(io, "socket_path=")
        show(io, server.socket_path)
    end
    print(io, ", tmux=")
    show(io, server.tmux)
    print(io, ')')
end
