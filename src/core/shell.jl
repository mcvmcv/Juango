# manage.jl shell (Django's shell command): code from -c or stdin runs with the project's models and some
# common names already bound, as Django 5.2's automatic imports.

"""
    shell_auto_imports() -> Vector{String}

What `manage.jl shell` binds before running code (Django's `get_auto_imports`): `Juango.settings`,
`Juango.connection_queries`, `Juango.reset_queries!`, `Juango.timezone_now` and the `Juango.Functions`
module, then each installed model by its path (`Shop.Product`). A model of an earlier app wins over
one of the same name in a later app.
"""
function shell_auto_imports()
    defaults = ["Juango.settings", "Juango.connection_queries", "Juango.reset_queries!", "Juango.Functions", "Juango.timezone_now"]
    models = [string(parentmodule(T), ".", nameof(T)) for T in reverse(all_models()) if shell_model_app_installed(T)]
    vcat(defaults, models)
end

# (a model of an app that isn't installed is left out; one that belongs to no registered App is the project's)
function shell_model_app_installed(@nospecialize(T))
    a = try resolve_app(modelmeta(T).app) catch; nothing end
    a === nothing || is_installed(a)
end
"A module by its name: Main, one bound in Main, or a loaded package."
function shell_root(name)
    name == "Main" && return Main
    if isdefined(Main, Symbol(name))
        v = getfield(Main, Symbol(name))
        v isa Module && return v
    end
    for m in values(Base.loaded_modules)
        string(nameof(m)) == name && return m
    end
    nothing
end
"The value a dotted path names (`Juango.settings`, `Shop.Product`, `Juango`), or `nothing`."
function resolve_dotted(path::AbstractString)
    parts = split(path, '.')
    root = shell_root(parts[1])
    root === nothing && return nothing
    v = root
    for p in parts[2:end]
        (v isa Module && isdefined(v, Symbol(p))) || return nothing
        v = getfield(v, Symbol(p))
    end
    v
end

"""
    shell_namespace(; verbosity = 0, no_imports = false, auto_imports = shell_auto_imports(), io = stdout) -> Dict{String,Any}

The names `manage.jl shell` binds (Django's `get_namespace`): each path of `auto_imports` that resolves,
by its last part. With `verbosity` 1 it says how many, with 2 which (`using Juango: settings, ...`), and
paths that don't resolve are listed. `auto_imports = nothing` binds nothing.
"""
function shell_namespace(; verbosity::Integer = 0, no_imports::Bool = false, auto_imports = shell_auto_imports(), io::IO = cmd_stdout())
    no_imports && return Dict{String,Any}()
    auto_imports === nothing && return Dict{String,Any}()
    groups = Pair{Union{Nothing,String},Vector{Pair{String,Any}}}[]          # module path (nothing: top level) => names, in order
    errors = String[]
    for path in auto_imports
        obj = resolve_dotted(path)
        obj === nothing && (push!(errors, path); continue)
        mod, name = occursin('.', path) ? (rsplit(path, '.'; limit = 2)...,) : (nothing, path)
        mod = mod === nothing ? nothing : String(mod)
        i = findfirst(g -> isequal(g[1], mod), groups)
        i === nothing && (push!(groups, mod => Pair{String,Any}[]); i = length(groups))
        any(p -> p[1] == name && p[2] === obj, groups[i][2]) || push!(groups[i][2], String(name) => obj)
    end
    ns = Dict{String,Any}(n => o for (_, items) in groups for (n, o) in items)
    verbosity < 1 && return ns
    if !isempty(errors)
        print(io, length(errors), length(errors) == 1 ? " object" : " objects", " could not be automatically imported:\n\n",
              join(["  " * e for e in errors], "\n"), "\n\n")
    end
    n = length(ns)
    msg = "$n $(n == 1 ? "object" : "objects") imported automatically"
    if verbosity < 2
        print(io, msg, n == 0 ? "" : " (use -v 2 for details)", ".\n\n")
        return ns
    end
    lines = vcat(["  import " * name for (m, items) in groups if m === nothing for (name, _) in items],
                 ["  using $m: " * join(first.(items), ", ") for (m, items) in groups if m !== nothing && !isempty(items)])
    print(io, isempty(lines) ? msg * "." : msg * ":\n\n" * join(lines, "\n"), "\n\n")
    ns
end

"Run Julia code in a fresh module with `ns` bound (as Django's shell runs a command in its namespace)."
function shell_run(code::AbstractString, ns::AbstractDict)
    m = Module(:JuangoShell)
    Core.eval(m, :(using Juango))
    for (name, obj) in ns
        Core.eval(m, Expr(:const, Expr(:(=), Symbol(name), obj)))
    end
    Base.include_string(m, code, "shell")
end

register_command!("shell"; help = "Runs Julia code with the project loaded: shell -c CODE, or code on stdin. " *
                                   "Interactively, start Julia with `julia --project -i manage.jl`.",
                  requires_system_checks = [],
                  arguments = [arg("--no-imports"; action = :store_true, help = "Disable automatic imports of models."),
                               arg("-c", "--command"; help = "Instead of opening an interactive shell, run a command and exit.")]) do opts
    ns = shell_namespace(; verbosity = opts.verbosity, no_imports = opts.no_imports)
    io = command_io()
    code = opts.command !== nothing ? opts.command : !io.isatty ? read(io.stdin, String) : nothing
    if code !== nothing
        shell_run(code, ns)
    elseif isinteractive()
        for (name, obj) in ns
            Core.eval(Main, Expr(:(=), Symbol(name), obj))
        end
    else
        println(cmd_stdout(), "Start Julia with:\n    julia --project -i manage.jl\n",
                "(running manage.jl without a command in interactive mode loads your project without doing anything).")
    end
    nothing
end
