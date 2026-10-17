# Times the steps that start a process or wait on tmux, to size hang guards
# against the slowest run on each platform: dev/time-steps.jl [repetitions].
# The first repetition includes compilation and is reported on its own.
using LibTmux, LibTmuxWorkspace

const REPETITIONS = isempty(ARGS) ? 20 : parse(Int, first(ARGS))
const STEPS = [
    "open_server",
    "new_session",
    "open_control",
    "run_command",
    "split_window",
    "close_control",
    "close_server",
    "run_before_script",
]

function timed!(samples, name, f)
    started = time_ns()
    result = f()
    push!(samples[name], (time_ns() - started) / 1e9)
    result
end

function main()
    tmux = get(ENV, "LIBTMUX_TEST_TMUX", "tmux")
    env = Dict(
        "PATH" => get(ENV, "PATH", "/usr/bin:/bin"),
        "TERM" => "xterm-256color",
        "SHELL" => "/bin/sh",
    )
    samples = Dict(name => Float64[] for name in STEPS)
    for _ = 1:REPETITIONS
        mktempdir() do directory
            timed!(
                samples,
                "run_before_script",
                () -> LibTmuxWorkspace.run_before_script(
                    "/bin/echo ready";
                    base_directory=directory,
                    timeout=60.0,
                ),
            )
        end
        owned = timed!(samples, "open_server", () -> open_server(; tmux, env, timeout=60.0))
        try
            server = owned.server
            session = timed!(
                samples,
                "new_session",
                () -> new_session(
                    server;
                    name="timing",
                    command=["/bin/cat"],
                    timeout=60.0,
                ),
            )
            connection = timed!(
                samples,
                "open_control",
                () -> open_control(server, session; timeout=60.0),
            )
            timed!(
                samples,
                "run_command",
                () -> run_command(server, "display-message", "-p", "ready"; timeout=60.0),
            )
            anchor = only(panes(snapshot(server))).ref
            timed!(
                samples,
                "split_window",
                () -> split_window(server, anchor; command=["/bin/cat"], timeout=60.0),
            )
            timed!(samples, "close_control", () -> close(connection))
        finally
            timed!(samples, "close_server", () -> close(owned))
        end
    end
    println("| step | runs | first s | median s | slowest after first s |")
    println("| --- | --- | --- | --- | --- |")
    for name in STEPS
        first_run, rest = first(samples[name]), sort(samples[name][2:end])
        median = rest[cld(length(rest), 2)]
        println(
            "| ",
            name,
            " | ",
            length(rest) + 1,
            " | ",
            round(first_run; digits=3),
            " | ",
            round(median; digits=3),
            " | ",
            round(last(rest); digits=3),
            " |",
        )
    end
end

main()
