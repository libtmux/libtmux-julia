using Test
using LibTmuxWorkspace
import LibTmux
isdefined(@__MODULE__, :with_workspace_server) || include("owned_server.jl")
isdefined(@__MODULE__, :TmuxpCatalog) ||
    include(joinpath(@__DIR__, "support", "tmuxp_catalog.jl"))

# Builds each of tmuxp's examples the loader accepts on a private tmux, and compares
# the session, window and pane tree tmux holds once the build returns with the
# structure written by hand in fixtures/tmuxp/expected: names, indices, pane counts,
# focus, directories, and whether the named layout is the one in effect. Pane
# contents and command output stay out. The commands and the before_script are
# dropped from the plan, because the examples run ssh, top, htop and vim, and a
# pane's own shell is replaced by the default one, because the examples name
# programs this machine may lack.

# The tree tmux holds for the one session, in the shape of the expected files.
# tmux renames a window whose automatic-rename is on to the program it runs, so
# the windows in `renamed` are compared without their name.
function built_tree(server, layouts, renamed)
    snap = LibTmux.snapshot(server)
    session = only(LibTmux.sessions(snap))
    links = sort(collect(LibTmux.windowlinks(session)); by=link -> link.index)
    windows = map(links) do link
        window = LibTmux.window(link)
        layout = layouts[link.index]
        before = window.layout
        applied = if layout === nothing
            nothing
        else
            LibTmux.select_layout(server, window.ref, layout)
            LibTmux.snapshot(server, window.ref).layout == before
        end
        panes = sort(collect(LibTmux.panes(window)); by=pane -> pane.index)
        Dict{String,Any}(
            "name" => link.index in renamed ? nothing : window.name,
            "index" => link.index,
            "focus" => link.active,
            "layout" => applied,
            "panes" => [
                Dict{String,Any}(
                    "focus" => pane.active,
                    "start_directory" => realpath(pane.current_path),
                ) for pane in panes
            ],
        )
    end
    Dict{String,Any}("session" => session.name, "windows" => windows)
end

@testset "tmuxp example catalog builds the tree tmuxp documents" begin
    Catalog = TmuxpCatalog
    with_workspace_server() do fixture
        server = LibTmux.Server(socket_path=fixture.socket, tmux=fixture.tmux)
        root = realpath(fixture.directory)
        directories = Dict(
            Catalog.WORKSPACE_DIR => joinpath(root, "workspace"),
            Catalog.HOME => joinpath(root, "home"),
            "/@PWD@" => joinpath(root, "pwd"),
        )
        mkpath.([
            joinpath(root, "workspace"),
            joinpath(root, "home"),
            joinpath(root, "pwd", "test"),
        ])
        real(directory) =
            realpath(replace(directory, (key => value for (key, value) in directories)...))
        for name in Catalog.LOADED
            want, _ = Catalog.port_expected(name)
            expanded = expand(
                validate(read_config(Catalog.path(name)));
                env=merge(Catalog.VARIABLES, Dict("PWD" => directories["/@PWD@"])),
                home=directories[Catalog.HOME],
                base_directory=directories[Catalog.WORKSPACE_DIR],
            )
            prepared = plan(expanded)
            steps = filter(
                step -> !(step.action in (:send_command, :before_script)),
                prepared.steps,
            )
            steps = map(steps) do step
                haskey(step.arguments, :shell) ?
                PlanStep(
                    step.action,
                    step.window,
                    step.pane,
                    merge(step.arguments, (; shell=nothing)),
                ) : step
            end
            result = apply(server, WorkspacePlan(expanded, Tuple(steps)); readiness=:none)
            @test result.status == :complete
            layouts =
                Dict(window["index"] => window["layout"] for window in want["windows"])
            renamed = Set(
                window["index"] for window in want["windows"] if
                get(window["options"], "automatic-rename", nothing) == "on"
            )
            tree = built_tree(server, layouts, renamed)
            wanted = Dict{String,Any}(
                "session" => want["session"]["name"],
                "windows" => [
                    Dict{String,Any}(
                        "name" => window["index"] in renamed ? nothing : window["name"],
                        "index" => window["index"],
                        "focus" => window["focus"],
                        "layout" => window["layout"] === nothing ? nothing : true,
                        "panes" => [
                            Dict{String,Any}(
                                "focus" => pane["focus"],
                                "start_directory" => real(pane["start_directory"]),
                            ) for pane in window["panes"]
                        ],
                    ) for
                    window in sort(want["windows"]; by=window -> window["index"])
                ],
            )
            @test Catalog.mismatches(wanted, tree) == []
            # The comparison reports a tree that differs, as a changed focus or
            # a missing pane would be.
            changed = deepcopy(tree)
            changed["windows"][1]["panes"][1]["focus"] =
                !changed["windows"][1]["panes"][1]["focus"]
            @test !isempty(Catalog.mismatches(wanted, changed))
            @test !isempty(
                Catalog.mismatches(wanted, merge(tree, Dict("session" => "other"))),
            )
            LibTmux.kill_session(server, result.session)
            @test isempty(LibTmux.sessions(LibTmux.snapshot(server)))
        end
    end
end
