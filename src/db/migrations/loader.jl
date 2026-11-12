# --- loading ------------------------------------------------------------------------------------

const BUILTIN_DIR = joinpath(Juango.ASSETS_DIR, "migrations")

"Directory holding `app`'s migrations, or `nothing` if it has none configured."
function migration_dir(app::AbstractString)
    mm = settings.MIGRATION_MODULES
    haskey(mm, app) && return string(mm[app])
    app in Juango.BUILTIN_LABELS && return joinpath(BUILTIN_DIR, app)
    app == "project" && return string(settings.MIGRATIONS_DIR)
    a = get(Juango.APP_DEFS, app, nothing)                          # an app's own migrations/ folder
    a === nothing || a.path === nothing || return joinpath(a.path, "migrations")
    nothing
end

"Every app that owns models or has a configured migration directory."
known_apps() = sort(unique(vcat([l for l in Juango.BUILTIN_LABELS if Juango.is_installed(l) && isdir(joinpath(BUILTIN_DIR, l))],
                                [modelmeta(T).app for T in all_models() if Juango.model_in_use(T)],
                                collect(String, keys(settings.MIGRATION_MODULES)),
                                [a.label for a in Juango.installed_apps() if a.path !== nothing])))

const FILE_RE = r"^(\d{4})_([A-Za-z0-9_]+)\.jl$"

migration_files(dir) = (dir === nothing || !isdir(dir)) ? String[] :
    sort([f for f in readdir(dir) if occursin(FILE_RE, f)])

"Evaluate one migration file."
function load_migration(path::AbstractString, app::AbstractString)
    # While Juango itself precompiles (its workload migrates the built-in apps), new modules
    # can't be evaluated into, so the built-in files are read in this module instead.
    mig = if ccall(:jl_generating_output, Cint, ()) == 1 && startswith(path, BUILTIN_DIR)
        Base.include(@__MODULE__, path)
    else
        m = Module(:JuangoMigration)
        for n in names(@__MODULE__)
            n === nameof(@__MODULE__) && continue
            Core.eval(m, :(const $n = $(getfield(@__MODULE__, n))))
        end
        Core.eval(m, :(const Juango = $Juango))
        Base.include(m, path)
    end
    mig isa Migration || throw(MigrationError("$path must evaluate to a Migration(...), got $(typeof(mig))"))
    mig.app = app
    mig.name = splitext(basename(path))[1]
    mig.path = path
    mig
end

load_app(app) = (d = migration_dir(app); Migration[load_migration(joinpath(d, f), app) for f in migration_files(d)])

"Apps that have at least one migration file."
migrated_apps() = filter(a -> !isempty(migration_files(migration_dir(a))), known_apps())

# --- graph --------------------------------------------------------------------------------------

struct Graph
    nodes::Dict{Tuple{String,String},Migration}
end

function build_graph(apps = migrated_apps(); applied = nothing)
    nodes = Dict{Tuple{String,String},Migration}()
    for a in apps, m in load_app(a)
        nodes[key(m)] = m
    end
    resolve_swappable!(nodes)
    resolve_replacements!(nodes, applied)
    for m in values(nodes), d in m.dependencies
        haskey(nodes, d) || throw(MigrationError("$m depends on $(d[1]).$(d[2]), which does not exist"))
    end
    g = Graph(nodes)
    topo_order(g)   # fails early on cycles
    g
end

"All migrations in dependency order (ties broken by app and name, so the order is stable)."
function topo_order(g::Graph, subset = keys(g.nodes))
    sub = Set(subset)
    indeg = Dict(k => count(d -> d in sub, g.nodes[k].dependencies) for k in sub)
    children = Dict(k => Tuple{String,String}[] for k in sub)
    for k in sub, d in g.nodes[k].dependencies
        d in sub && push!(children[d], k)
    end
    ready = sort([k for (k, n) in indeg if n == 0])
    out = Tuple{String,String}[]
    while !isempty(ready)
        k = popfirst!(ready)
        push!(out, k)
        for c in children[k]
            indeg[c] -= 1
            indeg[c] == 0 && (push!(ready, c); sort!(ready))
        end
    end
    length(out) == length(sub) || throw(MigrationError("circular dependency between migrations: " *
                                                       join(sort([string(k[1], ".", k[2]) for k in setdiff(sub, out)]), ", ")))
    out
end

function ancestors(g::Graph, k)
    seen = Set{Tuple{String,String}}()
    stack = [k]
    while !isempty(stack)
        x = pop!(stack)
        x in seen && continue
        push!(seen, x)
        append!(stack, g.nodes[x].dependencies)
    end
    seen
end

descendants(g::Graph, k) = Set(x for x in keys(g.nodes) if k in ancestors(g, x))

"Migrations of `app` that no other migration of `app` depends on (more than one means a conflict)."
function leaf_nodes(g::Graph, app)
    mine = [k for k in keys(g.nodes) if k[1] == app]
    sort([k for k in mine if !any(k in g.nodes[o].dependencies for o in mine)])
end

"Replay migrations to get the schema state after `keys` (in dependency order)."
function replay(g::Graph, ks)
    st = SchemaState()
    for k in topo_order(g, ks), op in g.nodes[k].operations
        state_forwards!(op, st, k[1])
    end
    st
end

state_before(g::Graph, k) = replay(g, setdiff(ancestors(g, k), [k]))

"""
`(\"__user_model__\", \"__first__\")` dependencies become the first migration of the app with
the AUTH_USER_MODEL (or go away when that app has no migrations).
"""
function resolve_swappable!(nodes)
    U = Juango.get_user_model()
    app = modelmeta(U).app
    mine = sort([k for k in keys(nodes) if k[1] == app]; by = last)
    target = isempty(mine) ? nothing : first(mine)
    for m in values(nodes)
        any(d -> d[1] == "__user_model__", m.dependencies) || continue
        m.dependencies = unique([d for d in (d[1] == "__user_model__" ? target : d for d in m.dependencies)
                                 if d !== nothing && d != key(m)])
    end
    nodes
end

"""
Squashed migrations stand in for the migrations they replace when none or all of those are
applied (their dependants then depend on the squashed one); when only some are, the
originals are used and the squashed migration is left out.
"""
function resolve_replacements!(nodes, applied)
    squashed = [m for m in values(nodes) if !isempty(m.replaces)]
    isempty(squashed) && return nodes
    applied === nothing && (applied = try applied_migrations() catch; Set{Tuple{String,String}}() end)
    for m in squashed
        k = key(m)
        reps = [r for r in m.replaces if haskey(nodes, r)]           # replaced files may be gone already
        done = count(in(applied), m.replaces)
        use_squashed = done == 0 || done == length(m.replaces) || isempty(reps)
        if use_squashed
            foreach(r -> delete!(nodes, r), reps)
        else
            delete!(nodes, k)
        end
        remap(d) = use_squashed ? (d in m.replaces ? k : d) : (d == k ? last(m.replaces) : d)
        for n in values(nodes)
            n.dependencies = filter(!=(key(n)), unique(map(remap, n.dependencies)))
        end
    end
    nodes
end

# --- recorder -----------------------------------------------------------------------------------

const RECORDER = Table("juango_migrations", "juango", "MigrationRecord",
                       [Column("app", :string; max_length = 255), Column("name", :string; max_length = 255),
                        Column("applied", :datetime)])

function ensure_recorder!()
    b = backend()
    table_exists(b, RECORDER.name) && return
    foreach(execute, first(create_table_sql(b, RECORDER)))
end

function applied_migrations()
    ensure_recorder!()
    Set((String(r[:app]), String(r[:name])) for r in execute("SELECT \"app\", \"name\" FROM \"juango_migrations\""))
end

record_applied!(k) = execute("INSERT INTO \"juango_migrations\" (\"app\", \"name\", \"applied\") VALUES (?, ?, ?)", [k[1], k[2], now()])
is_recorded(k) = !isempty(execute("SELECT 1 FROM \"juango_migrations\" WHERE \"app\" = ? AND \"name\" = ?", [k[1], k[2]]))
"Record a migration (and those it replaces, for a squashed one) as applied."
function record_applied_all!(m::Migration)
    for k in vcat([key(m)], m.replaces)
        is_recorded(k) || record_applied!(k)
    end
end
record_unapplied_all!(m::Migration) = foreach(record_unapplied!, vcat([key(m)], m.replaces))
record_unapplied!(k) = execute("DELETE FROM \"juango_migrations\" WHERE \"app\" = ? AND \"name\" = ?", [k[1], k[2]])
