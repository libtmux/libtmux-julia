module DocsApiExport

using SHA, TOML, Markdown, REPL
using LibTmux

const ROOT = pkgdir(LibTmux)
const REPOSITORY = "libtmux/libtmux-julia"

qualified(mod::Module, name::Symbol) = string(mod, '.', name)
written(value) = sprint(Base.show_unquoted, value)
native_type(value) = sprint(show,value; context=:module=>Core)

function relative_source(path)
    path = String(path)
    absolute = isabspath(path) ? normpath(path) : normpath(joinpath(ROOT, path))
    relative = replace(relpath(absolute, ROOT), '\\'=>'/')
    startswith(relative, "../") && return nothing
    isfile(absolute) || return nothing
    relative
end

function source_files()
    paths = split(read(`git -C $ROOT ls-files -- src ext packages Project.toml`, String), '\n'; keepempty=false)
    [Dict("path"=>path, "sha256"=>bytes2hex(sha256(read(joinpath(ROOT, path)))))
     for path in sort(paths) if isfile(joinpath(ROOT, path))]
end

function signature_call(expr)
    while expr isa Expr && expr.head in (:where, :(::))
        expr = expr.args[1]
    end
    expr isa Expr && expr.head === :call ? expr : nothing
end

function parameter(expr; keyword=false)
    default = nothing
    type = nothing
    variadic = false
    if expr isa Expr && expr.head in (:kw, :(=))
        default = written(expr.args[2])
        expr = expr.args[1]
    end
    if expr isa Expr && expr.head === :(...)
        variadic = true
        expr = expr.args[1]
    end
    if expr isa Expr && expr.head === :(::)
        type = written(expr.args[end])
        expr = length(expr.args) == 2 ? expr.args[1] : nothing
    end
    Dict("name"=>isnothing(expr) ? nothing : written(expr), "type"=>type,
        "default"=>default, "keyword"=>keyword, "variadic"=>variadic)
end

function syntax_signatures(files)
    found = Dict{Tuple{String,Int},Vector{Any}}()
    declarations = Dict{String,Any}()
    definitions = Dict{String,Any}()
    external_modules = Set{Symbol}()
    function visit(expr, file, line, namespace; toplevel=true)
        expr isa Expr || return
        if expr.head === :module
            name = string(expr.args[2])
            namespace = namespace == name ? name : namespace*"."*name
        end
        if toplevel && expr.head in (:abstract, :primitive, :struct)
            name = expr.args[expr.head === :struct ? 2 : 1]
            while name isa Expr && name.head in (:(<:), :curly)
                name = name.args[1]
            end
            name isa Symbol && (declarations[namespace*"."*string(name)] = Dict("file"=>file,"line"=>line))
        end
        if toplevel && expr.head === :const
            assignment = only(expr.args)
            if assignment isa Expr && assignment.head === :(=) && first(assignment.args) isa Symbol
                name = namespace*"."*string(first(assignment.args))
                declarations[name] = Dict("file"=>file,"line"=>line)
                definitions[name] = written(last(assignment.args))
            end
        end
        if expr.head in (:function, :(=))
            call = signature_call(expr.args[1])
            if !isnothing(call)
                callee = call.args[1]
                if callee isa Expr && callee.head === :. && first(callee.args) isa Symbol
                    push!(external_modules, first(callee.args))
                end
                params = Any[]
                for arg in call.args[2:end]
                    if arg isa Expr && arg.head === :parameters
                        append!(params, [parameter(kw; keyword=true) for kw in arg.args])
                    else
                        push!(params, parameter(arg))
                    end
                end
                body = expr.args[end]
                declaration_line = body isa Expr && body.head === :block &&
                    !isempty(body.args) && first(body.args) isa LineNumberNode ? first(body.args).line : line
                entry = Dict("signature"=>written(Base.remove_linenums!(deepcopy(expr.args[1]))),
                    "name"=>written(call.args[1]), "parameters"=>params)
                push!(get!(found, (file, declaration_line), Any[]), entry)
            end
        end
        for arg in expr.args
            if arg isa LineNumberNode
                line = arg.line
            else
                visit(arg, file, line, namespace; toplevel=toplevel && expr.head !== :function)
            end
        end
    end
    for item in files
        file = item["path"]
        endswith(file, ".jl") || continue
        # Julia's own parser retains generated declarations inside @eval syntax.
        expr = Meta.parseall(read(joinpath(ROOT, file), String); filename=file)
        parts = split(file,'/')
        namespace = startswith(file,"packages/") ? parts[2] : "LibTmux"
        visit(expr, file, 1, namespace)
    end
    (methods=found, declarations=declarations, definitions=definitions, external_modules=external_modules)
end

function callable_owner(method, kind)
    receiver = Base.unwrap_unionall(Base.unwrap_unionall(method.sig).parameters[1])
    if kind == "constructor"
        receiver isa DataType && receiver.name === Base.unwrap_unionall(Type).name || return nothing
        receiver = Base.unwrap_unionall(only(receiver.parameters))
    elseif receiver isa DataType && receiver.name === Base.unwrap_unionall(Type).name
        return nothing
    end
    receiver isa DataType ? receiver.name : nothing
end

function native_methods(value)
    value isa Function && return [(method,"function") for method in methods(value)]
    value isa Type || return Tuple{Method,String}[]
    datatype = Base.unwrap_unionall(value)
    datatype isa DataType || return Tuple{Method,String}[]
    found = Dict{Method,String}(method=>"constructor" for method in methods(value)
        if callable_owner(method,"constructor") === datatype.name)
    # Query abstract call signatures without constructing instances or choosing sample type arguments.
    for (kind, receiver) in (("constructor",Type{<:value}),("call",value))
        matches = Base._methods_by_ftype(Tuple{receiver,Vararg{Any}},-1,Base.get_world_counter())
        for match in matches
            method = match.method
            callable_owner(method,kind) === datatype.name || continue
            found[method] = kind
        end
    end
    collect(found)
end

function doc_records(binding, modules)
    records = Any[]
    for mod in modules
        metadata = Base.Docs.meta(mod; autoinit=false)
        isnothing(metadata) && continue
        haskey(metadata, binding) || continue
        multi = metadata[binding]
        for signature in multi.order
            doc = multi.docs[signature]
            path = relative_source(get(doc.data, :path, ""))
            isnothing(path) && continue
            fielddocs = get(doc.data, :fields, get(doc.data, :fielddocs, Dict()))
            push!(records, (signature, Dict(
                "signature"=>native_type(signature),
                "markdown"=>sprint(show, MIME("text/markdown"), Base.Docs.parsedoc(doc)),
                "source"=>Dict("file"=>path, "line"=>get(doc.data, :linenumber, 1)),
                "fields"=>Dict(string(k)=>string(v) for (k,v) in fielddocs))))
        end
    end
    records
end

function method_record(method::Method, syntax, docs; kind="function")
    file = relative_source(method.file)
    isnothing(file) && return nothing
    params = Any[]
    argnames = Base.method_argnames(method)
    types = Base.unwrap_unionall(method.sig).parameters
    candidates = get(syntax.methods, (file, Int(method.line)), Any[])
    source_syntax = length(candidates) == 1 ? only(candidates) : nothing
    positional = isnothing(source_syntax) ? Any[] : filter(p->!p["keyword"], source_syntax["parameters"])
    for index in 2:length(types)
        name = index <= length(argnames) ? string(argnames[index]) : nothing
        detail = index - 1 <= length(positional) ? positional[index-1] : nothing
        push!(params, Dict("name"=>name, "type"=>native_type(types[index]),
            "keyword"=>false, "variadic"=>method.isva && index == length(types),
            "default"=>isnothing(detail) ? nothing : detail["default"]))
    end
    for name in Base.kwarg_decl(method)
        candidates = isnothing(source_syntax) ? Any[] : filter(p->p["keyword"] &&
            (p["name"] == string(name) || p["name"]*"..." == string(name)), source_syntax["parameters"])
        detail = length(candidates) == 1 ? only(candidates) : nothing
        push!(params, Dict("name"=>replace(string(name), r"\.\.\.$"=>""),
            "type"=>isnothing(detail) ? nothing : detail["type"], "keyword"=>true,
            "variadic"=>endswith(string(name), "..."),
            "default"=>isnothing(detail) ? nothing : detail["default"]))
    end
    typedoc = Base.tuple_type_tail(method.sig)
    matches = [record for (signature, record) in docs if signature !== Union{} && typedoc <: signature]
    type_parameters = String[]
    signature = method.sig
    while signature isa UnionAll
        push!(type_parameters,native_type(signature.var))
        signature = signature.body
    end
    Dict("identity"=>native_type(method.sig),
        "kind"=>kind,
        "receiver"=>kind == "call" ? Dict("name"=>string(first(argnames)),"type"=>native_type(first(types))) : nothing,
        "signature"=>first(split(sprint(show, method;context=:module=>Core), " @ ")),
        "parameters"=>params,
        "typeParameters"=>type_parameters,
        "source"=>Dict("file"=>file, "line"=>Int(method.line)),
        "sourceSignature"=>isnothing(source_syntax) ? nothing : source_syntax["signature"],
        "module"=>string(method.module), "documentation"=>matches)
end

function surface_names(mod; qualified_types=false)
    chosen = Set(names(mod))
    delete!(chosen, nameof(mod))
    if qualified_types
        # Filters is a qualified namespace: its named operators are not exports.
        for name in names(mod; all=true, imported=false)
            startswith(string(name), "_") && continue
            startswith(string(name), "#") && continue
            isdefined(mod, name) || continue
            value = getfield(mod, name)
            value isa Type && parentmodule(value) === mod && push!(chosen, name)
        end
    end
    sort!(collect(chosen); by=string)
end

function extract_modules(scopes, files, syntax)
    modules = [scope.namespace for scope in scopes]
    symbols = Any[]
    inventories = Any[]
    for scope in scopes
        mod = scope.namespace
        primary = surface_names(mod; qualified_types=scope.qualified_types)
        supporting = Set{Symbol}()
        for name in primary
            value = getfield(mod,name)
            if value isa Type && parentmodule(value) === mod && nameof(value) != name
                target = nameof(value)
                target in primary || push!(supporting,target)
            end
        end
        nameset = sort!(unique([primary;collect(supporting)]);by=string)
        push!(inventories, Dict("module"=>string(mod), "product"=>scope.product,
            "package"=>scope.package, "bindings"=>string.(primary),
            "supportingBindings"=>string.(sort!(collect(supporting);by=string))))
        for name in nameset
            isdefined(mod, name) || error("Public binding is undefined: $(qualified(mod,name))")
            value = getfield(mod, name)
            binding = Base.Docs.Binding(mod, name)
            docs = doc_records(binding, modules)
            kind = value isa Module ? "module" : value isa Type ? "type" :
                value isa Function ? (startswith(string(name), "@") ? "macro" : "function") : "constant"
            method_records = Any[]
            if value isa Function || value isa Type
                for (method,method_kind) in native_methods(value)
                    record = method_record(method, syntax, docs;kind=method_kind)
                    isnothing(record) || push!(method_records, record)
                end
            end
            sort!(method_records; by=m->(m["identity"], m["source"]["file"], m["source"]["line"]))
            datatype = value isa UnionAll ? Base.unwrap_unionall(value) : value
            fields = datatype isa DataType && !isabstracttype(datatype) && parentmodule(datatype) === mod ? [Dict("name"=>string(field),
                "type"=>native_type(fieldtype(datatype,index))) for (index,field) in enumerate(fieldnames(datatype))] : Any[]
            locations = [record["source"] for (_,record) in docs]
            append!(locations, [record["source"] for record in method_records])
            definition = get(syntax.definitions,qualified(mod,name),nothing)
            source = !isnothing(definition) || isempty(locations) ? get(syntax.declarations,qualified(mod,name),nothing) : first(locations)
            alias = if value isa Function || value isa Type || value isa Module
                owner = parentmodule(value)
                declared_name = nameof(value)
                owner !== mod || declared_name !== name ? qualified(owner, declared_name) : nothing
            else
                nothing
            end
            push!(symbols, Dict("id"=>qualified(mod,name), "name"=>string(name),
                "module"=>string(mod), "package"=>scope.package, "product"=>scope.product,
                "kind"=>kind, "exported"=>Base.isexported(mod,name),
                "supporting"=>name in supporting, "definition"=>definition,
                "typeArguments"=>datatype isa DataType ? native_type.(collect(datatype.parameters)) : String[],
                "public"=>isdefined(Base,:ispublic) ? Base.ispublic(mod,name) : Base.isexported(mod,name),
                "qualifiedAccess"=>scope.qualified_types, "aliasOf"=>alias,
                "type"=>native_type(value isa Type ? value : typeof(value)),
                "abstract"=>value isa Type && isabstracttype(value),
                "mutable"=>value isa Type && ismutabletype(value),
                "supertype"=>datatype isa DataType ? native_type(supertype(datatype)) : nothing,
                "fields"=>fields, "methods"=>method_records,
                "documentation"=>[record for (_,record) in docs], "source"=>source))
        end
    end
    (symbols=symbols, inventories=inventories)
end

function extract_extensions(scopes,syntax)
    modules = [scope.namespace for scope in scopes]
    owned_files = Set(item["path"] for item in source_files())
    available = Dict(nameof(mod)=>mod for mod in Base.loaded_modules_array())
    available[:Base] = Base
    available[:Core] = Core
    for scope in scopes, name in syntax.external_modules
        if isdefined(scope.namespace,name) && getfield(scope.namespace,name) isa Module
            available[name] = getfield(scope.namespace,name)
        end
    end
    records = Any[]
    visited = IdDict{Any,Nothing}()
    for module_name in sort!(collect(syntax.external_modules);by=string)
        mod = get(available,module_name,nothing)
        isnothing(mod) && continue
        mod in modules && continue
        for name in sort!(names(mod;all=true,imported=false);by=string)
            startswith(string(name),"#") && continue
            isdefined(mod,name) || continue
            value = getfield(mod,name)
            value isa Function || value isa Type || continue
            haskey(visited,value) && continue
            visited[value] = nothing
            own_methods = [(method,kind) for (method,kind) in native_methods(value) if
                relative_source(method.file) in owned_files]
            isempty(own_methods) && continue
            binding = Base.Docs.Binding(mod,name)
            docs = doc_records(binding,modules)
            method_records = [method_record(method,syntax,docs;kind=kind) for (method,kind) in own_methods]
            sort!(method_records;by=m->(m["identity"],m["source"]["file"],m["source"]["line"]))
            push!(records,Dict("id"=>qualified(parentmodule(value),nameof(value)),
                "name"=>string(nameof(value)),"module"=>string(parentmodule(value)),
                "methods"=>method_records,"documentation"=>[record for (_,record) in docs]))
        end
    end
    sort!(records;by=r->r["id"])
end

function export_api(output)
    revision = strip(read(`git -C $ROOT rev-parse HEAD`, String))
    occursin(r"^[0-9a-f]{40}$",revision) || error("Cannot determine source revision")
    changes = read(`git -C $ROOT status --porcelain -- src ext packages Project.toml`,String)
    isempty(changes) || error("Commit API sources before exporting documentation")
    files = source_files()
    syntax = syntax_signatures(files)
    core_scopes = [(namespace=LibTmux, package="LibTmux", product="core", qualified_types=false),
        (namespace=LibTmux.Filters, package="LibTmux", product="core", qualified_types=true)]
    base = extract_modules(core_scopes, files, syntax)
    base_extensions = extract_extensions(core_scopes,syntax)

    # Capture the base method inventory before dependencies activate weak extensions.
    @eval using LibTmuxMCP, LibTmuxWorkspace, JSON, Tables
    Base.invokelatest(export_loaded_api,output,revision,core_scopes,base,base_extensions,files,syntax)
end

function export_loaded_api(output,revision,core_scopes,base,base_extensions,files,syntax)
    scopes = [core_scopes;
        (namespace=LibTmuxMCP, package="LibTmuxMCP", product="mcp", qualified_types=false);
        (namespace=LibTmuxWorkspace, package="LibTmuxWorkspace", product="workspace", qualified_types=false)]
    loaded = Base.invokelatest(extract_modules,scopes,files,syntax)
    base_methods = Set((symbol["id"], method["identity"]) for symbol in base.symbols for method in symbol["methods"])
    union!(base_methods, ((symbol["id"],method["identity"]) for symbol in base_extensions for method in symbol["methods"]))
    for symbol in loaded.symbols, method in symbol["methods"]
        method["requiresExtension"] = symbol["product"] == "core" &&
            !((symbol["id"],method["identity"]) in base_methods)
    end
    extensions = extract_extensions(scopes,syntax)
    for symbol in extensions, method in symbol["methods"]
        method["requiresExtension"] = startswith(method["source"]["file"],"ext/") &&
            !((symbol["id"],method["identity"]) in base_methods)
    end
    source_files() == files || error("API sources changed during documentation extraction")
    projects = [Dict("name"=>TOML.parsefile(joinpath(ROOT,path))["name"],
        "version"=>TOML.parsefile(joinpath(ROOT,path))["version"], "file"=>path)
        for path in ["Project.toml","packages/LibTmuxMCP/Project.toml","packages/LibTmuxWorkspace/Project.toml"]]
    artifact = Dict("schema"=>1, "port"=>"julia",
        "source"=>Dict("repository"=>REPOSITORY,"revision"=>revision,"files"=>files),
        "exporter"=>Dict("name"=>"Julia syntax + native methods and documentation", "version"=>1,
            "julia"=>string(VERSION), "sha256"=>bytes2hex(sha256(read(@__FILE__))),
            "dependencies"=>Dict("JSON"=>string(Base.pkgversion(JSON)),"Tables"=>string(Base.pkgversion(Tables)))),
        "packages"=>projects, "modules"=>loaded.inventories, "symbols"=>loaded.symbols,
        "extensionMethods"=>extensions,
        "baseMethods"=>[Dict("symbol"=>id,"signature"=>sig) for (id,sig) in sort!(collect(base_methods))],
        "extensions"=>sort!([string(mod) for mod in Base.loaded_modules_array() if
            !isnothing(pathof(mod)) && !isnothing(relative_source(pathof(mod))) && occursin("/ext/",pathof(mod))]))
    mkpath(dirname(abspath(output)))
    # JSON is loaded after the base capture so extension methods remain identifiable.
    Base.invokelatest(JSON.json, output, artifact; pretty=2)
    println("Exported $(length(loaded.symbols)) bindings to $output")
end

end

if abspath(PROGRAM_FILE) == @__FILE__
    output = isempty(ARGS) ? joinpath(@__DIR__,"build","api.json") : only(ARGS)
    DocsApiExport.export_api(output)
end
