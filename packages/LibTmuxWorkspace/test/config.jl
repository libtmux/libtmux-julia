using Test
using LibTmuxWorkspace

function config_error(f, code, path=nothing)
    error = try
        f()
        nothing
    catch caught
        caught
    end
    @test error isa WorkspaceConfigError
    if error isa WorkspaceConfigError
        @test error.code == code
        path === nothing || @test error.path == path
    end
    error
end

const SIMPLE = "session_name: demo\nwindows:\n  - window_name: main\n"

@testset "strict parser admission" begin
    a = validate(parse_config(SIMPLE; format=:yaml))
    b = validate(
        parse_config(
            raw"""{"schema_version":1,"session_name":"demo","windows":[{"window_name":"main"}]}""";
            format=:json,
        ),
    )
    @test a.session_name == b.session_name == "demo"
    @test length(a.windows[1].panes) == 1
    @test isempty(a.windows[1].panes[1].commands)
    config_error(
        () -> parse_config("session_name: one\nsession_name: two"; format=:yaml),
        :duplicate,
    )
    config_error(
        () -> parse_config(
            raw"""{"windows":[{"window_name":"a","window_name":"b"}]}""";
            format=:json,
        ),
        :duplicate,
    )
    config_error(
        () -> parse_config("session_name: &x demo\nwindows: *x"; format=:yaml),
        :unsupported,
    )
    config_error(() -> parse_config("a: 1\n---\na: 2"; format=:yaml), :documents)
    config_error(
        () -> parse_config("a: !!python/object:thing {}"; format=:yaml),
        :unsupported,
    )
    config_error(() -> parse_config("a: {<<: {b: 1}}"; format=:yaml), :unsupported)
    config_error(
        () -> parse_config(
            repeat("[", 40) * repeat("]", 40);
            format=:json,
            limits=ConfigLimits(max_depth=16),
        ),
        :limit,
    )
    config_error(
        () -> parse_config(
            repeat("[", 40) * repeat("]", 40);
            format=:yaml,
            limits=ConfigLimits(max_depth=16),
        ),
        :limit,
    )
    config_error(() -> parse_config(SIMPLE; limits=ConfigLimits(max_bytes=10)), :limit)
    config_error(() -> parse_config(String(UInt8[0xff])), :encoding)
end

@testset "schema validation and owned values" begin
    base = Dict{String,Any}(
        "session_name" => "demo",
        "windows" => [Dict("window_name" => "main")],
    )
    config_error(
        () -> validate(merge(base, Dict("schema_version" => 2))),
        :version,
        "\$.schema_version",
    )
    config_error(() -> validate(merge(base, Dict("typo" => true))), :unknown_key, "\$.typo")
    for key in ("plugins", "workspace_builder", "extends")
        config_error(
            () -> validate(merge(base, Dict(key => "ignored"))),
            :unsupported,
            "\$." * key,
        )
    end
    config_error(() -> validate(merge(base, Dict("windows" => []))), :value, "\$.windows")
    config_error(
        () -> validate(merge(base, Dict("session_name" => true))),
        :type,
        "\$.session_name",
    )
    config_error(
        () -> validate(merge(base, Dict("environment" => Dict("SECRET" => 1)))),
        :type,
        "\$.environment.SECRET",
    )
    config_error(() -> validate(merge(base, Dict("options" => Dict("@x" => [1])))), :type)
    numeric = validate(merge(base, Dict("options" => Dict("@count" => big(12)))))
    @test last(only(numeric.options)) isa Int64
    panes = Any[
        nothing,
        "blank",
        "pane",
        "",
        ["echo a", Dict("cmd" => "echo b", "enter" => false)],
    ]
    base["windows"] = Any[Dict("window_name" => "main", "panes" => panes)]
    cfg = validate(base)
    push!(panes, "echo later")
    @test length(cfg.windows[1].panes) == 5
    @test all(isempty(p.commands) for p in cfg.windows[1].panes[1:3])
    @test only(cfg.windows[1].panes[4].commands).text == ""
    @test cfg.windows[1].panes[5].commands[2].enter === false
    @test cfg.windows isa Tuple
    cyclic = Any[]
    push!(cyclic, cyclic)
    config_error(() -> validate(Dict("windows" => cyclic)), :limit)
    sleep_cfg = Dict(
        "session_name" => "demo",
        "windows" =>
            [Dict("window_name" => "main", "panes" => [Dict("sleep_after" => 0.1)])],
    )
    config_error(
        () -> validate(sleep_cfg),
        :unsupported,
        "\$.windows[1].panes[1].sleep_after",
    )
end

@testset "explicit expansion and inheritance" begin
    document = parse_config(raw"""
    session_name: dev-${PROJECT}
    start_directory: ./src
    shell_command_before: echo session
    environment:
      COMMON: session
      SESSION: yes-string
    windows:
      - window_name: api
        start_directory: service
        shell_command_before: echo window
        environment:
          COMMON: window
          WINDOW: inherited
        panes:
          - start_directory: ../tools
            shell_command_before: echo pane
            shell_command:
              - echo ${PROJECT}
              - cmd: literal
                enter: false
          - environment:
              COMMON: pane
            shell_command: echo ${UNKNOWN}
    """)
    cfg = validate(document)
    expanded = expand(
        cfg;
        env=Dict("PROJECT" => "sample"),
        home="/home/example",
        base_directory="/work/config",
    )
    p1, p2 = expanded.windows[1].panes
    @test expanded.session_name == "dev-sample"
    @test expanded.start_directory == "/work/config/src"
    @test expanded.windows[1].start_directory == "/work/config/src/service"
    @test p1.start_directory == "/work/config/src/tools"
    @test [c.text for c in p1.commands] == ["echo session", "echo window", "echo pane", "echo sample", "literal"]
    @test p1.commands[end].enter === false
    @test Dict(p1.environment) ==
          Dict("COMMON" => "window", "SESSION" => "yes-string", "WINDOW" => "inherited")
    @test Dict(p2.environment) == Dict("COMMON" => "pane", "SESSION" => "yes-string")
    @test p2.commands[end].text == raw"echo ${UNKNOWN}"
    config_error(() -> expand(cfg; env=Dict(), base_directory="relative"), :path)
    config_error(
        () -> expand(cfg; env=Dict(), base_directory="/work", unknown_variables=:error),
        :variable,
    )
    withenv("PROJECT" => "must-not-leak") do
        @test expand(cfg; base_directory="/work").session_name == raw"dev-${PROJECT}"
    end
    tilde = validate(
        Dict(
            "session_name" => "demo",
            "start_directory" => "~/dev",
            "windows" => [Dict("window_name" => "main")],
        ),
    )
    @test expand(tilde; home="/home/example", base_directory="/work").start_directory ==
          "/home/example/dev"
    config_error(() -> expand(tilde; base_directory="/work"), :home)
    empty_script = validate(
        Dict(
            "session_name" => "demo",
            "before_script" => raw"$SCRIPT",
            "windows" => [Dict("window_name" => "main")],
        ),
    )
    config_error(
        () -> expand(empty_script; env=Dict("SCRIPT" => ""), base_directory="/work"),
        :value,
        "\$.before_script",
    )
end

@testset "plans contain ordered inert effects" begin
    mktempdir() do directory
        marker = joinpath(directory, "must-not-exist")
        document = Dict(
            "session_name" => "demo",
            "before_script" => "touch " * marker,
            "options" => Dict("status" => false),
            "environment" => Dict("A" => "B"),
            "windows" => [
                Dict(
                    "window_name" => "main",
                    "layout" => "even-horizontal",
                    "focus" => true,
                    "options_after" => Dict("synchronize-panes" => true),
                    "panes" => [
                        Dict("shell_command" => "touch " * marker, "focus" => true),
                        nothing,
                    ],
                ),
            ],
        )
        result = plan(expand(validate(document); base_directory=directory))
        kinds = [step.action for step in result.steps]
        @test kinds[1:2] == [:create_session, :before_script]
        @test count(==(:create_window), kinds) == 1
        @test count(==(:split_pane), kinds) == 1
        @test count(==(:send_command), kinds) == 1
        @test findfirst(==(:select_layout), kinds) > findfirst(==(:split_pane), kinds)
        @test kinds[end] == :focus_window
        @test !ispath(marker)
        @test only(filter(s -> s.action == :send_command, result.steps)).pane == 1
        path = joinpath(directory, "workspace.yaml")
        write(path, SIMPLE)
        loaded = read_config(path)
        @test loaded isa WorkspaceDocument
        @test expand(validate(loaded)).start_directory == directory
        config_error(() -> read_config(path; limits=ConfigLimits(max_bytes=8)), :limit)
    end
end
