using Test, LibTmux, LibTmuxMCP
import JSON

discovery_result(app, args=Dict(); kwargs...) =
    LibTmuxMCP._invoke_tool(app, "list_panes", args; kwargs...)

if isempty(ARGS) || any(arg -> arg in ("unit", "discovery", "all"), ARGS)
    @testset "MCP discovery plans inert queries before I/O" begin
        endpoint = Server(socket_path="/tmp/libtmux-julia-uncontacted/s")
        app = Application(endpoint; allowed_tools=("list_panes",))
        query = encode_where(PaneWhere(title=Filters.StartsWith("work")))
        try
            plan = try
                LibTmuxMCP._plan_tool(
                    app,
                    "list_panes",
                    Dict(
                        "where"=>query,
                        "columns"=>["id", "title"],
                        "scope"=>Dict("sessionId"=>"\$0", "generation"=>"1:1"),
                    ),
                )
            catch error
                error
            end
            @test plan isa NamedTuple
            properties = only(tools(app)).input_schema["properties"]
            @test all(
                key -> haskey(properties, key),
                ("where", "columns", "scope", "pageToken"),
            )
            invalid_query = deepcopy(query)
            invalid_query["where"]["fields"][1]["match"]["op"] = "eval"
            deep_query = deepcopy(query)
            for _ = 1:25
                deep_query["where"] = Dict("op"=>"not", "arg"=>deep_query["where"])
            end
            for input in (
                Dict("where"=>invalid_query),
                Dict("where"=>deep_query),
                Dict("where"=>encode_where(SessionWhere())),
                Dict("columns"=>["window"]),
                Dict("columns"=>["id", "id"]),
                Dict("pageToken"=>"invalid"),
                Dict(
                    "scope"=>Dict(
                        "sessionId"=>"\$0",
                        "windowId"=>"@0",
                        "generation"=>"1:1",
                    ),
                ),
            )
                result = discovery_result(app, input)
                @test result.is_error &&
                      result.structured_content["error"]["code"] == "invalid_arguments" &&
                      result.structured_content["error"]["effects"] == "none"
            end
        finally
            close(app)
        end
    end
end

if isempty(ARGS) || any(arg -> arg in ("integration", "discovery", "all"), ARGS)
    @testset "MCP discovery scopes and refuses changed continuation pages" begin
        owned = Ref("")
        environment = Dict(
            "PATH"=>get(ENV, "PATH", "/usr/bin:/bin"),
            "TERM"=>"xterm-256color",
            "SHELL"=>"/bin/sh",
        )
        with_server(; env=environment) do server
            owned[] = dirname(server.socket_path)
            work = new_session(server; name="work", command=["/bin/cat"])
            first_scope = snapshot(server, work)
            first_pane = only(panes(only(windows(first_scope)))).ref
            other = split_window(server, first_pane; direction=:right, command=["/bin/cat"])
            ops = new_session(server; name="ops", command=["/bin/cat"])
            window = first(windows(snapshot(server, work))).ref
            run_command(server, "link-window", "-s", string(window.id), "-t", "ops:4")
            set_title(server, first_pane, "wanted:first")
            set_title(server, other, "wanted:second")
            generation = work.server.generation
            app = Application(server; allowed_tools=("list_panes",))
            session_scope = Dict("sessionId"=>string(work.id), "generation"=>generation)
            window_scope = Dict("windowId"=>string(window.id), "generation"=>generation)
            columns = ["id", "title"]
            try
                query = encode_where(PaneWhere(title=Filters.StartsWith("wanted:")))
                scoped = discovery_result(
                    app,
                    Dict("scope"=>session_scope, "where"=>query, "columns"=>columns),
                )
                @test !scoped.is_error
                if !scoped.is_error
                    data = scoped.structured_content
                    @test data["total"] == 2 && data["coverage"] == "session_scope"
                    @test data["contextsCoverage"] == "selected_session" && all(
                        row ->
                            length(row["contexts"]) == 1 &&
                            only(row["contexts"])["sessionName"] == "work",
                        data["panes"],
                    )
                    @test Set(row["values"]["id"] for row in data["panes"]) ==
                          Set(string.((first_pane.id, other.id)))
                    @test all(
                        row -> Set(keys(row["values"])) == Set(columns),
                        data["panes"],
                    )
                end
                correlated = encode_where(
                    PaneWhere(
                        window=WindowWhere(
                            windowlinks=Filters.AnyRelated(
                                WindowLinkWhere(session=SessionWhere(name="ops")),
                            ),
                        ),
                    ),
                )
                shared =
                    discovery_result(app, Dict("scope"=>window_scope, "where"=>correlated))
                shared.is_error &&
                    println("shared scope failure: ", shared.structured_content)
                @test !shared.is_error && shared.structured_content["total"] == 2
                shared.is_error || @test all(
                    row -> length(row["contexts"]) == 2,
                    shared.structured_content["panes"],
                )
                incomplete =
                    discovery_result(app, Dict("scope"=>session_scope, "where"=>correlated))
                @test incomplete.is_error &&
                      incomplete.structured_content["error"]["code"] ==
                      "incomplete_observation" &&
                      incomplete.structured_content["error"]["effects"] == "possible"
                first_page = discovery_result(app, Dict("columns"=>columns, "limit"=>1))
                @test !first_page.is_error && first_page.structured_content["total"] == 3
                token = first_page.structured_content["nextPageToken"]
                continued = discovery_result(
                    app,
                    Dict("columns"=>columns, "limit"=>1, "pageToken"=>token),
                )
                @test !continued.is_error &&
                      only(continued.structured_content["panes"])["target"] !=
                      only(first_page.structured_content["panes"])["target"]
                changed_query =
                    discovery_result(app, Dict("columns"=>["id"], "pageToken"=>token))
                @test changed_query.is_error &&
                      changed_query.structured_content["error"]["code"] ==
                      "observation_changed"
                long_title = repeat("t", 300)
                set_title(server, first_pane, long_title * "A")
                clipped_page = discovery_result(
                    app,
                    Dict("columns"=>columns, "limit"=>1, "scope"=>window_scope),
                )
                @test only(clipped_page.structured_content["panes"])["fieldsTruncated"]
                set_title(server, first_pane, long_title * "B")
                changed = discovery_result(
                    app,
                    Dict(
                        "columns"=>columns,
                        "scope"=>window_scope,
                        "pageToken"=>clipped_page.structured_content["nextPageToken"],
                    ),
                )
                @test changed.is_error &&
                      changed.structured_content["error"]["code"] == "observation_changed"
                @test changed.structured_content["error"]["effects"] == "possible"
                restarted = discovery_result(app, Dict("columns"=>columns))
                @test !restarted.is_error && restarted.structured_content["total"] == 3
                @test isempty(clients(snapshot(server)))
            finally
                close(app)
            end
        end
        @test !ispath(owned[])
    end
end

if isempty(ARGS) || any(arg -> arg in ("integration", "discovery", "all"), ARGS)
    Base.include(@__MODULE__, joinpath(@__DIR__, "support", "named_tmux.jl"))
    @testset "named socket discovery scopes avoid global graph acquisition" begin
        directory = Ref("")
        NamedTmux.with_named_tmux() do fixture
            directory[] = fixture.directory
            session = new_session(fixture.server; name="scoped", command=["/bin/cat"])
            wrapper = joinpath(fixture.directory, "targeted-tmux")
            write(
                wrapper,
                raw"""#!/bin/sh
for argument in "$@"; do
    if [ "$argument" = list-clients ]; then
        printf '%s\n' 'global graph acquisition refused by scoped probe' >&2
        exit 1
    fi
done
""" *
                "exec " *
                LibTmuxMCP._launcher_word(fixture.tmux) *
                " \"\$@\"\n",
            )
            chmod(wrapper, 0o755)
            endpoint = Server(socket_name=fixture.server.socket_name, tmux=wrapper)
            app = Application(endpoint; allowed_tools=("list_panes",))
            try
                result = discovery_result(
                    app,
                    Dict(
                        "scope"=>Dict(
                            "sessionId"=>string(session.id),
                            "generation"=>session.server.generation,
                        ),
                    ),
                )
                result.is_error &&
                    println("named scoped result: ", result.structured_content)
                @test !result.is_error && result.structured_content["total"] == 1
            finally
                close(app)
            end
        end
        @test !ispath(directory[])
    end
end
