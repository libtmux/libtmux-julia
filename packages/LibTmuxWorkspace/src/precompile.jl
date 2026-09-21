# Cache inert configuration and CLI error paths, including runtime JSON dispatch.
# No files, processes or tmux endpoints are accessed by this workload.
@setup_workload begin
    document = """
    session_name: precompile-\${PROJECT}
    start_directory: .
    before_script: ./before
    options: {status: true}
    environment: {PROJECT: sample}
    shell_command_before: echo before
    windows:
      - window_name: main
        window_index: 0
        layout: even-horizontal
        focus: true
        options_after: {synchronize-panes: false}
        panes:
          - shell_command: [echo ready, {cmd: echo later, enter: false}]
            focus: true
          - null
    """
    @compile_workload begin
        for (text, format) in (
            (document, :yaml),
            (
                "{\"session_name\":\"precompile\",\"windows\":[{\"window_name\":\"main\"}]}",
                :json,
            ),
        )
            validated = validate(parse_config(text; format))
            prepared = plan(
                expand(validated; base_directory="/tmp", env=Dict("PROJECT" => "sample")),
            )
            JSON.json(_jsonable(prepared))
        end
        _cli_options([
            "load",
            "workspace.yaml",
            "--socket",
            "/tmp/precompile",
            "--output",
            "ndjson",
        ])
        _script_argv("./before 'a b' ''")
        identity = LibTmux.ServerIdentity(socket_path="/tmp/precompile", generation="1:1")
        session = LibTmux.SessionRef(identity, "\$0")
        window = LibTmux.WindowRef(identity, "@0")
        pane = LibTmux.PaneRef(identity, "%0")
        for mode in ("json", "ndjson", "human")
            writer = _CLIOutput(IOBuffer(), IOBuffer(), mode)
            for status in (:complete, :partial, :cancelled)
                result = WorkspaceApplyResult(
                    status,
                    session,
                    (session, window, pane),
                    (),
                    (1, 2),
                    ((step=2, effect=:external_script),),
                    (),
                    ((target=session, status=:removed),),
                )
                _cli_record(writer, :result, Dict("result" => _jsonable(result)))
                for cause in (
                    InterruptException(),
                    LibTmux.RequestCancelled(true),
                    LibTmux.DeadlineExceeded(0.9, true, nothing),
                    BeforeScriptError(
                        :cancelled,
                        ScriptResult(1, UInt8[], UInt8[], 0, 9),
                        nothing,
                    ),
                )
                    _cli_report_error(writer, WorkspaceApplyError(result, cause))
                end
            end
            _cli_report_error(
                writer,
                WorkspaceConfigError(:value, "\$", "invalid configuration"),
            )
            _cli_record(
                writer,
                :progress,
                Dict(
                    "progress" =>
                        (event=:script_output, step=2, stream=:stdout, bytes=UInt8[0x61]),
                ),
            )
        end
    end
end

# Compile owned-session rollback without invoking tmux during package loading.
if ccall(:jl_generating_output, Cint, ()) == 1
    precompile(
        _rollback_created,
        (
            LibTmux.Server,
            LibTmux.SessionRef,
            Bool,
            Vector{LibTmux.WindowLinkRef},
            Vector{Any},
        ),
    )
end
