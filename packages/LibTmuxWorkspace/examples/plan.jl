using LibTmuxWorkspace

path = isempty(ARGS) ? joinpath(@__DIR__, "workspace.yaml") : only(ARGS)
document = read_config(path)
config = validate(document)
workspace = expand(config; env=Dict("PROJECT" => "example"))
result = plan(workspace)

for step in result.steps
    target = string(" window=", step.window, " pane=", step.pane, " ")
    println(step.action, target, step.arguments)
end
