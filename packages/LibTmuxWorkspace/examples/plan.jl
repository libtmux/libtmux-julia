using LibTmuxWorkspace

path = isempty(ARGS) ? joinpath(@__DIR__, "workspace.yaml") : only(ARGS)
document = read_config(path)
config = validate(document)
workspace = expand(config; env=Dict("PROJECT" => "example"))
result = plan(workspace)

for step in result.steps
    println(step.action, " window=", step.window, " pane=", step.pane, " ", step.arguments)
end
