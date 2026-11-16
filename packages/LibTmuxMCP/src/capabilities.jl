function _capability_output_fields()
    text = Dict("type"=>"string")
    texts = Dict("type"=>"array", "items"=>text)
    command =
        _json_object(Dict("command"=>text, "flags"=>texts); required=["command", "flags"])
    common = Dict{String,Any}(
        "id"=>text,
        "name"=>text,
        "summary"=>text,
        "handling"=>Dict("enum"=>["refuse", "fallback", "repair"]),
        "apis"=>texts,
        "commands"=>Dict("type"=>"array", "items"=>command),
    )
    feature = merge(
        common,
        Dict(
            "since"=>text,
            "except"=>texts,
            "error"=>Dict("type"=>["string", "null"]),
            "supported"=>Dict("type"=>"boolean"),
        ),
    )
    workaround = merge(common, Dict("releases"=>texts, "active"=>Dict("type"=>"boolean")))
    Dict{String,Any}(
        "generation"=>text,
        "version"=>text,
        "features"=>Dict(
            "type"=>"array",
            "items"=>_json_object(feature; required=collect(keys(feature))),
        ),
        "workarounds"=>Dict(
            "type"=>"array",
            "items"=>_json_object(workaround; required=collect(keys(workaround))),
        ),
        "enabledTools"=>Dict("type"=>"array", "items"=>Dict("enum"=>collect(_TOOL_NAMES))),
    )
end

function _capability_entry(entry)
    Dict{String,Any}(
        "id"=>entry.id,
        "name"=>entry.name,
        "summary"=>entry.summary,
        "handling"=>String(entry.handling),
        "apis"=>collect(entry.apis),
        "commands"=>[
            Dict("command"=>c.command, "flags"=>collect(c.flags)) for c in entry.commands
        ],
    )
end

function _get_capabilities(app, context)
    report = LibTmux.capabilities(
        app.server;
        timeout=_tool_remaining(context),
        cancel=context.cancel,
    )
    features = [
        merge(
            _capability_entry(c),
            Dict(
                "since"=>c.since,
                "except"=>collect(c.except),
                "error"=>c.error,
                "supported"=>c.supported,
            ),
        ) for c in report.features
    ]
    workarounds = [
        merge(
            _capability_entry(w),
            Dict("releases"=>collect(w.releases), "active"=>w.active),
        ) for w in report.workarounds
    ]
    Dict(
        "generation"=>report.generation,
        "version"=>report.version,
        "features"=>features,
        "workarounds"=>workarounds,
        "enabledTools"=>collect(app.allowed_tools),
    )
end
