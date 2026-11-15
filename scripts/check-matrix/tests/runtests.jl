using Test
import Sockets
import TOML
include(joinpath(@__DIR__, "..", "check-matrix.jl"))
using .CheckMatrix
const M = CheckMatrix
const P = M.PlanMatrix

CheckMatrix.enable_subreaper()

function fails(action, fragment)
    error = try
        action()
        nothing
    catch error
        error
    end
    error isa M.MatrixError && occursin(fragment, error.message)
end

# The shell stands in for a check: what it prints, and how it ends, are all a phase sees.
shell(script) = ["/bin/sh", "-c", script]

@testset "owned preparation" begin
    mktempdir(; prefix="libtmux-julia-matrix-test-") do base
        @testset "the standard library cache is copied, completed files only" begin
            compiled = joinpath(base, "tool-depot", "compiled", "v1.13")
            for name in ("Pkg", "LibTmux")
                mkpath(joinpath(compiled, name))
                write(joinpath(compiled, name, "cache.ji"), "cache bytes")
                write(joinpath(compiled, name, "cache.so"), "native bytes")
            end
            write(joinpath(compiled, "Pkg", "cache.pidfile"), "unfinished")
            write(joinpath(compiled, "Pkg", "jl_incomplete.so"), "unfinished")
            source = dirname(dirname(compiled))
            destination = joinpath(base, "stdlib-consumer")
            copied = M.seed_stdlib_cache(source, destination, "v1.13", ["Pkg"])
            @test [item["file"] for item in copied] == ["Pkg/cache.ji", "Pkg/cache.so"]
            @test !ispath(joinpath(destination, "compiled", "v1.13", "LibTmux"))
            write(
                joinpath(destination, "compiled", "v1.13", "Pkg", "cache.ji"),
                "changed consumer cache",
            )
            @test read(joinpath(compiled, "Pkg", "cache.ji"), String) == "cache bytes"
            @test fails(
                () -> M.seed_stdlib_cache(source, destination, "v1.13", ["Pkg"]),
                "empty consumer cache",
            )
            symlink(
                joinpath(compiled, "Pkg", "cache.ji"),
                joinpath(compiled, "Pkg", "linked.ji"),
            )
            @test fails(
                () -> M.seed_stdlib_cache(
                    source,
                    joinpath(base, "linked-stdlib"),
                    "v1.13",
                    ["Pkg"],
                ),
                "regular completed files",
            )
        end
        @testset "the registry cache is copied, never shared" begin
            registry = joinpath(base, "quality-depot", "registries")
            mkpath(registry)
            write(joinpath(registry, "General.toml"), "registry metadata")
            write(joinpath(registry, "General.tar.gz"), "registry archive")
            consumer = joinpath(base, "consumer-depot")
            copies = M.seed_registry_cache(dirname(registry), consumer)
            @test [item["file"] for item in copies] == ["General.tar.gz", "General.toml"]
            for item in copies
                copy = joinpath(consumer, "registries", item["file"])
                @test read(copy, String) == read(joinpath(registry, item["file"]), String)
                @test item["sha256"] == bytes2hex(open(M.SHA.sha256, copy)) && !islink(copy)
            end
            write(joinpath(consumer, "registries", "General.toml"), "changed copy")
            @test read(joinpath(registry, "General.toml"), String) == "registry metadata"
            @test fails(
                () -> M.seed_registry_cache(dirname(registry), consumer),
                "empty destination",
            )
            symlink(joinpath(registry, "General.toml"), joinpath(registry, "linked.toml"))
            @test fails(
                () -> M.seed_registry_cache(
                    dirname(registry),
                    joinpath(base, "linked-consumer"),
                ),
                "regular files",
            )
        end
        @testset "a stage outside the checkout is required and owned" begin
            @test fails(
                () -> M.checked_stage(joinpath(M.ROOT, "stage"); create=true),
                "outside the checkout",
            )
            stage = joinpath(base, "owned-stage")
            @test M.checked_stage(stage; create=true) == stage
            @test M.checked_stage(stage) == stage
            @test fails(() -> M.checked_stage(joinpath(base, "unprepared")), "not prepared")
            restored = joinpath(base, "restored")
            mkpath(joinpath(restored, "depot"))
            mkpath(joinpath(restored, "logs"))
            @test M.checked_stage(restored; create=true) == restored
            occupied = joinpath(base, "occupied")
            mkpath(occupied)
            write(joinpath(occupied, "file"), "x")
            @test fails(() -> M.checked_stage(occupied; create=true), "empty stage")
        end
    end
end

@testset "a phase is bounded, streamed and audited" begin
    mktempdir(; prefix="libtmux-julia-phase-test-") do base
        env = Dict(ENV)
        run(argv; budget=10.0, completion=false, name="p") = M.phase(
            name,
            argv;
            cwd=base,
            env,
            log=joinpath(base, "$name.log"),
            budget,
            completion,
        )
        literal = "; \$(touch must-not-exist)"
        ok = run(["/bin/echo", literal]; name="literal")
        @test ok["status"] == "PASS" &&
              strip(read(joinpath(base, "literal.log"), String)) == literal
        @test !ispath(joinpath(base, "must-not-exist"))
        failed = run(shell("exit 7"); name="failure")
        @test failed["status"] == "FAIL" && failed["exit_code"] == 7
        @test run([joinpath(base, "missing")]; name="missing")["status"] == "NOT RUN"
        timed = run(["/bin/sleep", "30"]; budget=0.2, name="deadline")
        @test timed["status"] == "TIMEOUT" && timed["direct_child_reaped"]
        incomplete = run(shell("true"); completion=true, name="incomplete")
        @test incomplete["status"] == "INCOMPLETE"
        for content in ("invocation = \"stale\"\n", "invocation = \"truncated")
            bad = run(
                shell("printf '%s' '$content' > \"\$LIBTMUX_TEST_COMPLETION\"");
                completion=true,
                name="bad-receipt",
            )
            @test bad["status"] == "INCOMPLETE"
        end
        if Sys.islinux()
            program = "run(Cmd(`sleep 300`; detach=true); wait=false); println(\"DETACHED_CHILD_STARTED\"); flush(stdout); sleep(300)"
            cancelled = run(
                [
                    joinpath(Sys.BINDIR, Base.julia_exename()),
                    "--startup-file=no",
                    "-e",
                    program,
                ];
                budget=3.0,
                name="detached",
            )
            @test cancelled["status"] == "TIMEOUT"
            @test !isempty(cancelled["cleanup"]["reaped"]) &&
                  isempty(cancelled["cleanup"]["survivors"])
            @test cancelled["cleanup"]["temporary_directory_removed"]
        end
        log = joinpath(base, "skipped.log")
        write(
            log,
            "PASS core\n┌ Warning: control suites skipped: below 3.7\nSKIPPED README.md fence 3: control acquisition needs tmux 3.7\nPASS x\n",
        )
        @test M.skipped_checks(log) == [
            "Warning: control suites skipped: below 3.7",
            "SKIPPED README.md fence 3: control acquisition needs tmux 3.7",
        ]
        @test M.skipped_checks(joinpath(base, "absent.log")) == String[]
    end
end

@testset "the cells and documents the workflow relies on" begin
    cells = P.qa_cells()
    @test [(c["os"], c["arch"], c["julia"], c["tmux"], c["threads"]) for c in cells] == [
        ("Linux", "x86_64", "1.13.1", tmux, threads) for (tmux, threads) in (
            ("3.3a", 1),
            ("3.4", 1),
            ("3.5a", 1),
            ("3.6b", 1),
            ("3.7", 1),
            ("3.7a", 1),
            ("3.7b", 1),
            ("3.7c", 1),
            ("3.7c", 4),
            ("3.8", 1),
        )
    ]
    @test all(
        c["suites"] ==
        (c["tmux"] in ("3.3a", "3.7c", "3.8") ? collect(P.SUITES) : ["runtime"]) for
        c in cells
    )
    jobs = [(c["label"], suite) for c in cells for suite in c["suites"]]
    @test length(jobs) == length(unique(jobs)) &&
          length(unique(c["label"] for c in cells)) == length(cells)
    @test all(c["status"] == "NOT RUN" for c in cells)
    @test Set(c["tmux"] for c in P.qa_cells("edges")) ==
          Set([P.MINIMUM_TMUX, P.NEWEST_TMUX])
    @test [c["tmux"] for c in cells if c["docs_artifact"] == "true"] == [P.NEWEST_TMUX]
    for name in ("docs/src/compatibility.md", "CONTRIBUTING.md")
        text = read(joinpath(M.ROOT, name), String)
        unnamed = [
            tmux for tmux in (P.SUPPORTED_TMUX..., P.REJECTED_TMUX...) if !occursin(
                Regex("(?<![\\w.])" * replace(tmux, "." => "\\.") * "(?![\\w])"),
                text,
            )
        ]
        @test isempty(unnamed)
    end
    rejected = P.rejection_cells()
    @test [c["tmux"] for c in rejected] == ["3.0a", "3.1c", "3.2a", "3.3"]
    @test [c["tmux"] for c in rejected if c["real_old"] == "true"] == ["3.0a", "3.1c"]
    @test isdisjoint(Set(c["tmux"] for c in rejected), Set(c["tmux"] for c in cells))
    @test all(c["tmux"] != P.MINIMUM_TMUX for c in rejected) &&
          length(unique(c["label"] for c in rejected)) == length(rejected)
    workflow = read(P.WORKFLOW, String)
    # Every rejection lane runs behind a client at the floor release.
    step = split(
        split(workflow, "- name: Build the current client"; limit=2)[2],
        "- name:";
        limit=2,
    )[1]
    @test !occursin("if:", step) && occursin("ref: $(P.MINIMUM_TMUX)", step)
    client = [
        line for line in split(workflow, '\n') if occursin("LIBTMUX_TEST_CLIENT_TMUX", line)
    ]
    @test !isempty(client) && all(line -> !occursin("real_old", line), client)
    # The package suites that need real old daemons run in the reject job and fail
    # rather than skip when the builds are absent.
    for package in ("LibTmuxWorkspace", "LibTmuxMCP")
        @test occursin("packages/$package/test/runtests.jl old-daemon", workflow)
    end
    @test count("LIBTMUX_TEST_REQUIRE_OLD_DAEMON: '1'", workflow) == 2
    # The reject environment must import what those steps import.
    prepare = split(
        split(workflow, "- name: Prepare the package environment"; limit=2)[2],
        "- name:";
        limit=2,
    )[1]
    needed = Set(keys(TOML.parsefile(joinpath(M.ROOT, "Project.toml"))["weakdeps"]))
    for package in ("LibTmuxWorkspace", "LibTmuxMCP")
        source =
            read(joinpath(M.ROOT, "packages", package, "test", "old_daemon.jl"), String)
        union!(
            needed,
            [
                m.captures[1] for
                m in eachmatch(r"(?m)^\s*(?:using|import)\s+([A-Za-z0-9_]+)", source)
            ],
        )
    end
    setdiff!(needed, ["Test", "LibTmux", "LibTmuxWorkspace", "LibTmuxMCP"])
    @test isempty(filter(name -> !occursin("\"$name\"", prepare), needed))
end

@testset "the sandbox hides every selector and each check can fail" begin
    mktempdir(; prefix="libtmux-julia-sandbox-test-") do base
        dirty = Dict(
            "TMUX" => "/decoy-secret/sock,1,0",
            "TMUX_PANE" => "%decoy-secret",
            "LIBTMUX_SOCKET" => "decoy-secret",
            "LIBTMUX_SOCKET_PATH" => "/decoy-secret",
            "LIBTMUX_SOCKET_FUTURE" => "decoy-secret",
            "TMUX_TMPDIR" => "/decoy-secret",
            "LIBTMUX_TEST_SANDBOX" => "/decoy-secret",
            "LIBTMUX_TEST_TMUX" => "tmux",
        )
        cleaned = withenv(dirty...) do
            M.environment(base; offline=true)
        end
        sandbox = cleaned["TMUX_TMPDIR"]
        @test M.sandbox_findings(cleaned, sandbox) == []
        @test sandbox == M.matrix_sandbox() && isdir(sandbox)
        @test ncodeunits(sandbox) < M.SANDBOX_MAX_BYTES
        @test cleaned["LIBTMUX_TEST_TMUX"] == "tmux" &&
              !haskey(cleaned, "LIBTMUX_TEST_SANDBOX")
        flagged = M.sandbox_findings(dirty, sandbox)
        @test flagged == [
            "LIBTMUX_SOCKET is set",
            "LIBTMUX_SOCKET_FUTURE is set",
            "LIBTMUX_SOCKET_PATH is set",
            "TMUX is set",
            "TMUX_PANE is set",
            "TMUX_TMPDIR is not the matrix sandbox",
        ]
        @test !occursin("decoy-secret", join(flagged))
        too_long = "/" * "x"^M.SANDBOX_MAX_BYTES
        @test fails(() -> M.make_sandbox([too_long]), "short enough")
        fallback = M.make_sandbox([too_long, "/tmp"])
        @test dirname(fallback) == "/tmp" && isdir(fallback)
        rm(fallback)
        @test M.sandbox_leaks(sandbox) == []
        mkpath(joinpath(sandbox, "tmux-1000"))
        write(joinpath(sandbox, "tmux-1000", "regular-file"), "")
        @test M.sandbox_leaks(sandbox) == []
        # A socket file nothing listens on, as a server killed mid-run leaves.
        function stale(relative)
            path = joinpath(sandbox, relative)
            mkpath(dirname(path))
            Base.systemerror(
                "mknod",
                ccall(:mknod, Cint, (Cstring, UInt32, UInt64), path, 0o140600, 0) != 0,
            )
        end
        foreach(stale, ("custom.sock", "deep/er/nested.sock", "tmux-1000/default"))
        symlink(joinpath(sandbox, "custom.sock"), joinpath(sandbox, "link.sock"))
        everywhere = ["custom.sock", "deep/er/nested.sock", "tmux-1000/default"]
        @test M.sandbox_leaks(sandbox) == everywhere
        # `true` stands in for a tmux whose kill-server leaves nothing listening.
        @test M.release_sandbox(sandbox, "true"; patience=0.2) == (everywhere, String[])
        @test !ispath(sandbox)
        # A listener outlives a tmux that stops nothing, so the sandbox stays.
        sandbox = M.matrix_sandbox()
        listener = Sockets.listen(joinpath(sandbox, "survivor.sock"))
        @test M.release_sandbox(sandbox, "true"; patience=0.2) ==
              (["survivor.sock"], ["survivor.sock"])
        M.remove_sandbox(sandbox)
        @test isdir(sandbox) && ispath(joinpath(sandbox, "survivor.sock"))
        close(listener)
        M.remove_sandbox(sandbox)
        @test !ispath(sandbox)
    end
end

@testset "the plan of a prepared cell" begin
    commands = M.command_plan("julia", 1, "/project", "/consumers")
    names = [item[1] for item in commands]
    @test length(names) == length(unique(names))
    budgets = Dict(item[1] => item[3] for item in commands)
    @test budgets["format"] == 30
    @test M.format_warmup_command("julia", 1, "/project") == [
        "julia",
        "--startup-file=no",
        "--threads=1",
        "--project=/project",
        joinpath(M.ROOT, "dev/check-quality.jl"),
        "format",
    ]
    partitions = String[]
    for suite in P.SUITES
        append!(partitions, [item[1] for item in M.selected_commands(commands; suite)])
    end
    @test length(partitions) == length(unique(partitions)) == length(names) &&
          Set(partitions) == Set(names)
    @test issubset(M.DELIVERY_PHASES, Set(names))
    for item in commands
        @test item[2][1] == "julia" && item[4] in ("unit", "quality", "outer")
    end
    # Every file a phase runs exists.
    for item in commands, argument in item[2]
        endswith(argument, ".jl") &&
            !isabspath(argument) &&
            @test isfile(joinpath(M.ROOT, argument))
    end
end

@testset "the runner records, bounds and audits a cell" begin
    mktempdir(; prefix="libtmux-julia-run-test-") do base
        stage = joinpath(base, "stage")
        M.checked_stage(stage; create=true)
        mkpath(joinpath(base, "environment"))
        write(joinpath(base, "environment", "LocalPreferences.toml"), M.TOOL_PREFERENCES)
        metadata = Dict{String,Any}(
            "source_digest" => "fixed",
            "tools" => Dict{String,Any}(),
            "project" => joinpath(base, "environment"),
            "consumers" => base,
            "tool_preferences" => TOML.parse(M.TOOL_PREFERENCES),
            "seconds" => 1.0,
        )
        open(io -> TOML.print(io, metadata), joinpath(stage, "prepared.toml"), "w")
        fixed() = "fixed"
        phase_result(name, status; seconds=0.01) = Dict{String,Any}(
            "name" => name,
            "status" => status,
            "seconds" => seconds,
            "cleanup" => Dict("survivors" => Int[]),
        )
        one_after_another(results) = begin
            queue = collect(results)
            (name, argv; kwargs...) ->
                (item=popfirst!(queue); item isa Exception ? throw(item) : item)
        end
        results(prefix) = [
            TOML.parsefile(joinpath(stage, name)) for name in readdir(stage) if
            startswith(name, prefix) && endswith(name, ".toml")
        ]
        run_with(plan, runner; kwargs...) = redirect_stdout(devnull) do
            M.run_matrix(
                stage;
                julia="julia",
                tmux="tmux",
                digest=fixed,
                plan=(a, b, c, d) -> plan,
                run_phase=runner,
                kwargs...,
            )
        end

        # An interrupted phase is recorded, and the interruption is not swallowed.
        two = [("first", String[], 30.0, "unit"), ("second", String[], 30.0, "unit")]
        @test_throws InterruptException run_with(
            two,
            one_after_another([phase_result("first", "FAIL"), InterruptException()]),
        )
        interrupted = only(results("results-all-t1-"))
        @test interrupted["status"] == "INTERRUPTED" &&
              interrupted["active_phase"] == "second"
        @test interrupted["phases"][1]["status"] == "FAIL"

        # A phase over its diagnostic target still passes.
        slow = [("slow", String[], 0.001, "unit"), ("following", String[], 30.0, "unit")]
        @test run_with(
            slow,
            one_after_another([
                phase_result("slow", "PASS"),
                phase_result("following", "PASS"),
            ]),
        ) == 0
        passed = first(r for r in results("results-all-t1-") if r["status"] == "PASS")
        @test passed["phases"][1]["over_target"] && length(passed["phases"]) == 2
        @test passed["sandbox_leaks"] == [] && passed["sandbox_kept"] == []

        # A socket a phase leaves in the sandbox fails the cell, whatever the phase says.
        leaking(name, argv; env, kwargs...) = begin
            socket = joinpath(env["TMUX_TMPDIR"], "tmux-1000", "default")
            mkpath(dirname(socket))
            ccall(:mknod, Cint, (Cstring, UInt32, UInt64), socket, 0o140600, 0) == 0 ||
                Base.systemerror("mknod")
            phase_result(name, "PASS")
        end
        @test run_with([("leaky", String[], 30.0, "unit")], leaking) == 1
        leaked = first(
            r for r in results("results-all-t1-") if
            !isempty(r["phases"]) && r["phases"][1]["name"] == "leaky"
        )
        @test leaked["status"] == "FAIL" &&
              leaked["sandbox_leaks"] == ["tmux-1000/default"] &&
              leaked["sandbox_kept"] == []

        # A changed source stops the cell before it runs.
        @test fails(() -> M.run_matrix(stage; digest=() -> "changed"), "source changed")
        # A cell that is not the one requested records why and runs nothing.
        mismatched =
            run_with(two, one_after_another(Any[]); expected=Dict("julia" => "0.0.0"))
        @test mismatched == 1

        # Evidence leaves the stage without local paths or credential values.
        logs = joinpath(stage, "logs", "probe")
        mkpath(logs)
        write(
            joinpath(logs, "failure.log"),
            "$(homedir())/private failed: original assertion\n~/private failure\nsecret-value\n",
        )
        withenv("TEST_SECRET" => "secret-value") do
            redirect_stdout(devnull) do
                @test M.artifacts(stage) == 0
            end
        end
        exported =
            read(joinpath(stage, "artifacts", "logs", "probe", "failure.log"), String)
        @test !occursin(homedir(), exported) &&
              !occursin("secret-value", exported) &&
              !occursin("~/", exported)
        @test occursin("original assertion", exported)
        @test occursin(
            "INCOMPLETE second",
            read(joinpath(stage, "artifacts", "summary.txt"), String),
        )
    end
end

@testset "the command line refuses what it cannot run" begin
    @test redirect_stderr(() -> M.main(String[]), devnull) == 2
    @test redirect_stderr(() -> M.main(["run", "/nonexistent-stage"]), devnull) == 2
    @test redirect_stderr(() -> M.main(["prepare", "/tmp/x", "--threads", "3"]), devnull) ==
          2
end
