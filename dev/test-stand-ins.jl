# Children for tests, checks and benchmarks that need a program no system tool
# provides. No shell runs: a child is a system tool called directly or a short
# Julia program. tmux starts a stand-in by path, so a stand-in tmux is an
# executable file that names this Julia and runs the program written for it.
module StandIns

# Julia's own signal handlers are off so that a stand-in which ignores SIGTERM does
# so from its first instruction, and one that does not dies of it without a dump.
const FLAGS = [
    "--startup-file=no",
    "--history-file=no",
    "--compile=min",
    "-O0",
    "--threads=1",
    "--handle-signals=no",
]

julia() = joinpath(Sys.BINDIR, Base.julia_exename())

"""
The argument vector of a Julia child that runs `program` with `arguments`. The
program sees the functions below as `StandIns`.
"""
julia_argv(program, arguments...) = String[
    julia(),
    FLAGS...,
    "-e",
    "include($(repr(@__FILE__)))\n"*program,
    string.(arguments)...,
]

julia_cmd(program, arguments...) = Cmd(julia_argv(program, arguments...))

"""
    install(path, program) -> path

Write an executable at `path` that runs the Julia source `program`. The program
sees the arguments in `ARGS`, its own path in `PROGRAM_FILE` and the functions
below as `StandIns`.
"""
function install(path, program)
    write(
        path,
        "#!/usr/bin/env -S $(julia()) $(join(FLAGS, ' '))\n",
        "include($(repr(@__FILE__)))\n",
        program,
        "\n",
    )
    chmod(path, 0o700)
    path
end

# What the programs call.

"Append `text` and a newline to the file at `path`."
function record(path, text)
    open(path, "a") do io
        write(io, text, '\n')
    end
    nothing
end

"""
Answer the release probe the way a tmux of `release` does, and exit. The probe is
`-C <marker>` where the marker ends in the format `#{version}`. Return when the
arguments hold no probe.
"""
function answer_probe(release; arguments=ARGS)
    for (previous, argument) in zip(arguments, Iterators.drop(arguments, 1))
        previous == "-C" || continue
        print(
            stderr,
            "unknown command: ",
            chopsuffix(argument, "#{version}"),
            release,
            "\n",
        )
        exit(1)
    end
    nothing
end

"Replace this process with `real` and `arguments`, as a wrapper that ends in `exec` does."
forward(real, arguments=ARGS) = exec(real, arguments...)

"""
Replace this process with `program`, as the shell's `exec` does, so a signal sent
to the stand-in reaches the program and no child outlives it.
"""
function exec(program, arguments...)
    argv = String[program, arguments...]
    # Julia blocks some signals and ignores SIGPIPE; a program must not inherit that.
    empty = zeros(UInt8, 256)
    ccall(:sigemptyset, Cint, (Ptr{UInt8},), empty)
    ccall(
        :pthread_sigmask,
        Cint,
        (Cint, Ptr{UInt8}, Ptr{Cvoid}),
        Sys.isapple() ? 3 : 2,
        empty,
        C_NULL,
    )
    ccall(:signal, Ptr{Cvoid}, (Cint, Ptr{Cvoid}), 13, C_NULL)
    # libuv makes the descriptors it opens non-blocking; the program expects blocking ones.
    nonblocking = Sys.isapple() ? 0x0004 : 0x0800
    for descriptor = 0:2
        flags = ccall(:fcntl, Cint, (Cint, Cint), descriptor, 3)
        flags >= 0 &&
            ccall(:fcntl, Cint, (Cint, Cint, Cint), descriptor, 4, flags & ~nonblocking)
    end
    GC.@preserve argv begin
        pointers = Ptr{UInt8}[pointer(argument) for argument in argv]
        push!(pointers, C_NULL)
        ccall(:execvp, Cint, (Cstring, Ptr{Ptr{UInt8}}), program, pointers)
    end
    error("could not run ", program)
end

"Put the terminal on stdin in raw mode without echo."
raw_terminal() = run(`stty raw -echo`)

end
