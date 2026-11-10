# Versioned migrations --------------------------------------------------------------------------
#
#   julia --project manage.jl makemigrations      # write migrations/0002_add_post_status.jl
#   julia --project manage.jl migrate             # apply everything pending
#   julia --project manage.jl migrate 0001        # go back to 0001 (unapplies later ones)
#   julia --project manage.jl migrate zero        # unapply all of the project's migrations
#   julia --project manage.jl showmigrations
#   julia --project manage.jl sqlmigrate 0002 [--backwards]
#
# Each app has a directory of migration files `NNNN_name.jl`. Built-in models (users,
# sessions) belong to the app "juango", whose migrations ship with Juango. Everything else
# belongs to "project" (directory `settings.MIGRATIONS_DIR`), unless a model sets
# `Meta(app_label=...)` and `settings.MIGRATION_MODULES` maps that app to a directory.
# An app without migration files is synchronised instead (tables and columns are created,
# never altered), which is how Juango behaved before migrations existed.

module Migrations

using Dates
import ..Juango
using ..Juango: Column, Table, Index, SchemaState, copy_state, getcolumn, hascolumn, with_column, same_definition,
    backend, execute, atomic, settings, table_exists, table_columns, models_state, sync_models!, modelmeta,
    all_models, create_table_sql, drop_table_sql, rename_table_sql, add_column_sql, drop_column_sql,
    rename_column_sql, alter_column_sql, backfill_value, quote_name, VERSION_STRING

export Migration, CreateModel, DeleteModel, RenameModel, AddField, RemoveField, AlterField, RenameField,
       AlterUniqueTogether, AddIndex, RemoveIndex, RunSQL, RunJulia, Column, Index

# --- operations ---------------------------------------------------------------------------------

abstract type Operation end

"Create a table. `columns` excludes the automatic `id` primary key."
struct CreateModel <: Operation
    table::String
    model::String
    columns::Vector{Column}
    unique_together::Vector{Vector{String}}
    parent::Union{Nothing,String}     # multi-table inheritance parent table
    pk::Symbol                        # :auto or :uuid
    indexes::Vector{Index}
end
CreateModel(table; model = table, columns = Column[], unique_together = [], parent = nothing, pk = :auto, indexes = Index[]) =
    CreateModel(string(table), string(model), collect(Column, columns), Juango.normalize_unique(unique_together),
                parent === nothing ? nothing : string(parent), Symbol(pk), collect(Index, indexes))
to_table(op::CreateModel, app) = Table(op.table, app, op.model, copy(op.columns), [copy(u) for u in op.unique_together];
                                       parent = op.parent, pk = op.pk, indexes = copy(op.indexes))

"Add a named index (`Index(...)` with a name) to a table."
struct AddIndex <: Operation
    table::String
    index::Index
end
AddIndex(table, ix::Index) = AddIndex(string(table), ix)

"Drop a named index."
struct RemoveIndex <: Operation
    table::String
    name::String
end

"Set the multi-column unique constraints of a table (column names)."
struct AlterUniqueTogether <: Operation
    table::String
    unique_together::Vector{Vector{String}}
    AlterUniqueTogether(table, sets) = new(string(table), Juango.normalize_unique(sets))
end

"Drop a table."
struct DeleteModel <: Operation
    table::String
end

"Rename a table (foreign keys pointing at it follow)."
struct RenameModel <: Operation
    old::String
    new::String
    model::Union{Nothing,String}
end
RenameModel(old, new; model = nothing) = RenameModel(string(old), string(new), model === nothing ? nothing : string(model))

"Add a column."
struct AddField <: Operation
    table::String
    column::Column
end
AddField(table, c::Column) = AddField(string(table), c)

"Drop a column."
struct RemoveField <: Operation
    table::String
    name::String
end

"Change a column's definition (type, NULL, default, unique, index, foreign key)."
struct AlterField <: Operation
    table::String
    column::Column
end
AlterField(table, c::Column) = AlterField(string(table), c)

"Rename a column."
struct RenameField <: Operation
    table::String
    old::String
    new::String
end

"""
    RunSQL(forward, backward=nothing)

Raw SQL (a string or a vector of strings) with `?`-free statements. Without `backward` the
migration can't be unapplied; pass `\"\"` for a no-op reverse.
"""
struct RunSQL <: Operation
    forward::Vector{String}
    backward::Union{Nothing,Vector{String}}
    RunSQL(forward, backward = nothing) = new(sqllist(forward), backward === nothing ? nothing : sqllist(backward))
end
sqllist(x::AbstractString) = isempty(x) ? String[] : [String(x)]
sqllist(x) = String[string(s) for s in x]

"""
    RunJulia(forward, backward=nothing)

Run Julia code (a zero-argument function) as part of a migration, typically a data
migration. Prefer `Juango.execute` with raw SQL over the ORM here: the ORM uses today's
model definitions, which may not match the schema at this point in history.
"""
struct RunJulia <: Operation
    forward::Function
    backward::Union{Nothing,Function}
    RunJulia(forward, backward = nothing) = new(forward, backward)
end

"""
    Migration(; dependencies=[], operations=[], initial=false)

The value a migration file evaluates to. `dependencies` are `(app, name)` pairs. The app
and name come from the file's directory and filename.
"""
mutable struct Migration
    app::String
    name::String
    dependencies::Vector{Tuple{String,String}}
    operations::Vector{Operation}
    initial::Bool
    path::String
end
Migration(; dependencies = [], operations = [], initial = false) =
    Migration("", "", Tuple{String,String}[(string(a), string(n)) for (a, n) in dependencies],
              collect(Operation, operations), initial, "")

key(m::Migration) = (m.app, m.name)
Base.show(io::IO, m::Migration) = print(io, m.app, ".", m.name)

struct IrreversibleError <: Exception
    msg::String
end
Base.showerror(io::IO, e::IrreversibleError) = print(io, "IrreversibleError: ", e.msg)

struct MigrationError <: Exception
    msg::String
end
Base.showerror(io::IO, e::MigrationError) = print(io, "MigrationError: ", e.msg)

# --- state changes ------------------------------------------------------------------------------

function table!(st::SchemaState, name)
    t = get(st, name, nothing)
    t === nothing && throw(MigrationError("table '$name' does not exist in the migration state"))
    t
end

state_forwards!(op::CreateModel, st, app) = (st[op.table] = to_table(op, app); st)
state_forwards!(op::AddIndex, st, app) = (push!(table!(st, op.table).indexes, op.index); st)
state_forwards!(op::RemoveIndex, st, app) = (filter!(i -> i.name != op.name, table!(st, op.table).indexes); st)
state_forwards!(op::AlterUniqueTogether, st, app) = (table!(st, op.table).unique_together = [copy(u) for u in op.unique_together]; st)
state_forwards!(op::DeleteModel, st, app) = (table!(st, op.table); delete!(st, op.table); st)
function state_forwards!(op::RenameModel, st, app)
    t = table!(st, op.old)
    delete!(st, op.old)
    t.name = op.new
    op.model === nothing || (t.model = op.model)
    st[op.new] = t
    for other in values(st)
        other.columns = [c.references == op.old ? with_column(c; references = op.new) : c for c in other.columns]
    end
    st
end
function state_forwards!(op::AddField, st, app)
    t = table!(st, op.table)
    hascolumn(t, op.column.name) && throw(MigrationError("column $(op.table).$(op.column.name) already exists"))
    push!(t.columns, op.column)
    st
end
function state_forwards!(op::RemoveField, st, app)
    t = table!(st, op.table)
    getcolumn(t, op.name)
    filter!(c -> c.name != op.name, t.columns)
    st
end
function state_forwards!(op::AlterField, st, app)
    t = table!(st, op.table)
    getcolumn(t, op.column.name)
    t.columns = [c.name == op.column.name ? op.column : c for c in t.columns]
    st
end
function state_forwards!(op::RenameField, st, app)
    t = table!(st, op.table)
    getcolumn(t, op.old)
    t.columns = [c.name == op.old ? with_column(c; name = op.new) : c for c in t.columns]
    t.unique_together = Juango.normalize_unique([[x == op.old ? op.new : x for x in u] for u in t.unique_together])
    st
end
state_forwards!(::Union{RunSQL,RunJulia}, st, app) = st

# --- database changes ---------------------------------------------------------------------------
# `from`/`to` are the states before and after the operation (in the forward direction).
# Each returns a list of actions: SQL strings or functions to call.

function forwards(op::CreateModel, b, from, to, deferred)
    stmts, fks = create_table_sql(b, to[op.table])
    append!(deferred, fks)
    stmts
end
backwards(op::CreateModel, b, from, to, deferred) = drop_table_sql(b, to[op.table])

forwards(op::DeleteModel, b, from, to, deferred) = drop_table_sql(b, from[op.table])
backwards(op::DeleteModel, b, from, to, deferred) = forwards(CreateModel(op.table), b, to, from, deferred)

forwards(op::AddIndex, b, from, to, deferred) = Juango.index_spec_sql(b, op.table, op.index)
backwards(op::AddIndex, b, from, to, deferred) = Juango.drop_index_spec_sql(b, op.index)
forwards(op::RemoveIndex, b, from, to, deferred) =
    Juango.drop_index_spec_sql(b, only(filter(i -> i.name == op.name, from[op.table].indexes)))
backwards(op::RemoveIndex, b, from, to, deferred) =
    Juango.index_spec_sql(b, op.table, only(filter(i -> i.name == op.name, from[op.table].indexes)))

forwards(op::RenameModel, b, from, to, deferred) = rename_table_sql(b, from[op.old], to[op.new])
backwards(op::RenameModel, b, from, to, deferred) = rename_table_sql(b, to[op.new], from[op.old])

forwards(op::AddField, b, from, to, deferred) = add_column_sql(b, to[op.table], op.column, deferred)
backwards(op::AddField, b, from, to, deferred) = drop_column_sql(b, to[op.table], from[op.table], op.column.name)

forwards(op::RemoveField, b, from, to, deferred) = drop_column_sql(b, from[op.table], to[op.table], op.name)
backwards(op::RemoveField, b, from, to, deferred) = add_column_sql(b, from[op.table], getcolumn(from[op.table], op.name), deferred)

forwards(op::AlterField, b, from, to, deferred) = alter_column_sql(b, from[op.table], to[op.table], op.column.name, deferred)
backwards(op::AlterField, b, from, to, deferred) = alter_column_sql(b, to[op.table], from[op.table], op.column.name, deferred)

forwards(op::RenameField, b, from, to, deferred) = rename_column_sql(b, from[op.table], to[op.table], op.old, op.new)
backwards(op::RenameField, b, from, to, deferred) = rename_column_sql(b, to[op.table], from[op.table], op.new, op.old)

forwards(op::AlterUniqueTogether, b, from, to, deferred) =
    Juango.alter_unique_together_sql(b, op.table, from[op.table].unique_together, to[op.table].unique_together)
backwards(op::AlterUniqueTogether, b, from, to, deferred) =
    Juango.alter_unique_together_sql(b, op.table, to[op.table].unique_together, from[op.table].unique_together)

forwards(op::RunSQL, b, from, to, deferred) = op.forward
function backwards(op::RunSQL, b, from, to, deferred)
    op.backward === nothing && throw(IrreversibleError("RunSQL has no reverse SQL"))
    op.backward
end
forwards(op::RunJulia, b, from, to, deferred) = Any[op.forward]
function backwards(op::RunJulia, b, from, to, deferred)
    op.backward === nothing && throw(IrreversibleError("RunJulia has no reverse function"))
    Any[op.backward]
end

describe(op::CreateModel) = "Create model $(op.model) (table $(op.table))"
describe(op::DeleteModel) = "Delete table $(op.table)"
describe(op::RenameModel) = "Rename table $(op.old) to $(op.new)"
describe(op::AddField) = "Add field $(op.column.name) to $(op.table)"
describe(op::RemoveField) = "Remove field $(op.name) from $(op.table)"
describe(op::AlterField) = "Alter field $(op.column.name) on $(op.table)"
describe(op::RenameField) = "Rename field $(op.old) on $(op.table) to $(op.new)"
describe(op::AlterUniqueTogether) = "Alter unique_together for $(op.table)"
describe(op::AddIndex) = "Create index $(op.index.name) on $(op.table)"
describe(op::RemoveIndex) = "Remove index $(op.name) from $(op.table)"
describe(op::RunSQL) = "Raw SQL operation"
describe(op::RunJulia) = "Raw Julia operation"

# --- loading ------------------------------------------------------------------------------------

const BUILTIN_DIR = joinpath(@__DIR__, "migrations")

"Directory holding `app`'s migrations, or `nothing` if it has none configured."
function migration_dir(app::AbstractString)
    mm = settings.MIGRATION_MODULES
    haskey(mm, app) && return string(mm[app])
    app == "juango" && return BUILTIN_DIR
    app == "project" && return string(settings.MIGRATIONS_DIR)
    nothing
end

"Every app that owns models or has a configured migration directory."
known_apps() = sort(unique(vcat(["juango"], [modelmeta(T).app for T in all_models()],
                                collect(String, keys(settings.MIGRATION_MODULES)))))

const FILE_RE = r"^(\d{4})_([A-Za-z0-9_]+)\.jl$"

migration_files(dir) = (dir === nothing || !isdir(dir)) ? String[] :
    sort([f for f in readdir(dir) if occursin(FILE_RE, f)])

"Evaluate one migration file."
function load_migration(path::AbstractString, app::AbstractString)
    m = Module(:JuangoMigration)
    for n in names(@__MODULE__)
        n === nameof(@__MODULE__) && continue
        Core.eval(m, :(const $n = $(getfield(@__MODULE__, n))))
    end
    Core.eval(m, :(const Juango = $Juango))
    mig = Base.include(m, path)
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

function build_graph(apps = migrated_apps())
    nodes = Dict{Tuple{String,String},Migration}()
    for a in apps, m in load_app(a)
        nodes[key(m)] = m
    end
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
record_unapplied!(k) = execute("DELETE FROM \"juango_migrations\" WHERE \"app\" = ? AND \"name\" = ?", [k[1], k[2]])

# --- executing ----------------------------------------------------------------------------------

run_action(a::AbstractString) = execute(a)
run_action(f::Function) = Base.invokelatest(f)   # defined in a migration file loaded after this code was compiled

"The SQL (and functions) a migration runs, without running it."
function migration_actions(g::Graph, k; backwards = false)
    m = g.nodes[k]
    b = backend()
    states = [state_before(g, k)]
    for op in m.operations
        push!(states, state_forwards!(op, copy_state(states[end]), m.app))
    end
    deferred = String[]
    actions = Any[]
    if backwards
        for i in length(m.operations):-1:1
            append!(actions, Migrations.backwards(m.operations[i], b, states[i], states[i+1], deferred))
        end
    else
        for (i, op) in enumerate(m.operations)
            append!(actions, forwards(op, b, states[i], states[i+1], deferred))
        end
    end
    append!(actions, deferred)
    actions
end

"An initial migration whose tables and columns all exist already (database created before migrations)."
function already_in_database(m::Migration)
    m.initial || return false
    b = backend()
    tables = [op.table for op in m.operations if op isa CreateModel]
    isempty(tables) && return false
    all(t -> table_exists(b, t), tables) || return false
    for op in m.operations
        if op isa CreateModel
            cols = Set(table_columns(b, op.table))
            all(c -> c.name in cols, op.columns) || return false
        elseif op isa AddField
            op.column.name in Set(table_columns(b, op.table)) || return false
        end
    end
    true
end

function apply!(g::Graph, k; backwards = false, fake = false, log = println)
    m = g.nodes[k]
    label = backwards ? "  Unapplying $(m)..." : "  Applying $(m)..."
    if !backwards && !fake && already_in_database(m)
        record_applied!(k)
        log(label * " FAKED (tables already exist)")
        return
    end
    atomic() do
        fake || foreach(run_action, migration_actions(g, k; backwards = backwards))
        backwards ? record_unapplied!(k) : record_applied!(k)
    end
    log(label * (fake ? " FAKED" : " OK"))
end

function resolve_name(g::Graph, app, name)
    ks = sort([k for k in keys(g.nodes) if k[1] == app && (k[2] == name || startswith(k[2], name))])
    exact = filter(k -> k[2] == name, ks)
    length(exact) == 1 && return exact[1]
    isempty(ks) && throw(MigrationError("no migration in app '$app' matches '$name'"))
    length(ks) > 1 && throw(MigrationError("more than one migration in app '$app' matches '$name': " * join(last.(ks), ", ")))
    ks[1]
end

"""
    migration_plan(g, applied; app=nothing, target=nothing) -> Vector{Pair{key,Bool}}

Steps to run, as `key => backwards`. No `target` applies everything pending. A target of
`\"zero\"` unapplies all of `app`; any other target migrates `app` to exactly that point,
unapplying later migrations (and migrations elsewhere that depend on them).
"""
function migration_plan(g::Graph, applied; app = nothing, target = nothing)
    order = topo_order(g)
    target === nothing && return [k => false for k in order if !(k in applied)]
    app === nothing && throw(ArgumentError("a target needs an app"))
    keep = target == "zero" ? Set{Tuple{String,String}}() : ancestors(g, resolve_name(g, app, target))
    undo = Set{Tuple{String,String}}()
    for k in applied
        haskey(g.nodes, k) || continue
        if k[1] == app && !(k in keep)
            push!(undo, k)
            union!(undo, filter(in(applied), descendants(g, k)))
        end
    end
    plan = [k => true for k in reverse(order) if k in undo]
    append!(plan, [k => false for k in order if k in keep && !(k in applied)])
    plan
end

"""
    migrate(; app=nothing, target=nothing, fake=false, sync=false, verbose=true)

Apply migrations. With no arguments, applies every pending migration and then
synchronises apps that have no migration files. `target` (with `app`, default
`\"project\"`) migrates forwards or backwards to that migration; `\"zero\"` unapplies all.
`fake=true` records migrations without running them. `sync=true` skips migration files and
only synchronises tables for every model.
"""
function migrate(; app = nothing, target = nothing, fake = false, sync = false, verbose = true)
    log(msg) = verbose && println(msg)
    if sync
        log("Synchronizing all models (migration files ignored):")
        sync_models!(all_models(); verbose = verbose) || log("  No changes.")
        return nothing
    end
    target !== nothing && app === nothing && (app = "project")
    g = build_graph()
    check_conflicts(g)
    applied = applied_migrations()
    plan = migration_plan(g, applied; app = app, target = target)
    unmigrated = [T for T in all_models() if !(modelmeta(T).app in migrated_apps())]
    log("Operations to perform:")
    isempty(g.nodes) || log("  Apply all migrations: " * join(sort(unique(first.(collect(keys(g.nodes))))), ", "))
    isempty(unmigrated) || target !== nothing ||
        log("  Synchronize unmigrated apps: " * join(sort(unique([modelmeta(T).app for T in unmigrated])), ", "))
    log("Running migrations:")
    isempty(plan) && log("  No migrations to apply.")
    for (k, back) in plan
        apply!(g, k; backwards = back, fake = fake, log = log)
    end
    if target === nothing && !isempty(unmigrated)
        log("Synchronizing apps without migrations:")
        sync_models!(unmigrated; verbose = verbose) || log("  No changes.")
    end
    Juango.update_contenttypes!()
    if verbose && target === nothing
        for a in migrated_apps()
            isempty(detect_changes(g, a; questioner = _ -> false)) && continue
            log("  Your models in app '$a' have changes that are not yet reflected in a migration. " *
                "Run 'manage.jl makemigrations' and then 'manage.jl migrate'.")
        end
    end
    nothing
end

function check_conflicts(g::Graph)
    for a in unique(first.(collect(keys(g.nodes))))
        leaves = leaf_nodes(g, a)
        length(leaves) > 1 && throw(MigrationError("conflicting migrations in app '$a': " * join(last.(leaves), ", ") *
                                                   ". Run 'manage.jl makemigrations --merge' to merge them."))
    end
end

"""
    showmigrations(; io=stdout) -> Vector{Tuple{String,String,Bool}}

List every migration with `[X]` when applied.
"""
function showmigrations(; io = stdout)
    g = build_graph()
    applied = applied_migrations()
    rows = Tuple{String,String,Bool}[]
    for a in known_apps()
        println(io, a)
        ks = [k for k in topo_order(g) if k[1] == a]
        isempty(ks) && println(io, " (no migrations)")
        for k in ks
            push!(rows, (k[1], k[2], k in applied))
            println(io, " [", k in applied ? "X" : " ", "] ", k[2])
        end
    end
    rows
end

"""
    sqlmigrate(app, name; backwards=false) -> String

The SQL a migration would run on the current database backend.
"""
function sqlmigrate(app, name; backwards = false)
    g = build_graph()
    k = resolve_name(g, app, name)
    parts = String[]
    for a in migration_actions(g, k; backwards = backwards)
        push!(parts, a isa AbstractString ? a * ";" : "-- (Julia function $(a))")
    end
    join(parts, "\n")
end

# --- autodetector -------------------------------------------------------------------------------

"Default questioner: ask on a terminal, otherwise answer no."
function ask(question)
    stdin isa Base.TTY || return false
    print(question, " [y/N] ")
    lowercase(strip(readline())) in ("y", "yes")
end

"""
    detect_changes(g, app; questioner=ask) -> Vector{Operation}

Operations that take `app`'s tables from the state its migrations describe to the state
its models describe. `questioner(question) -> Bool` decides whether a removed plus an
added table or column is really a rename.
"""
function detect_changes(g::Graph, app; questioner = ask)
    from = replay(g, keys(g.nodes))
    to = models_state()
    old = Dict(k => v for (k, v) in from if v.app == app)
    new = Dict(k => v for (k, v) in to if v.app == app)
    ops = Operation[]

    # renamed tables: same columns, different name
    removed = sort(setdiff(collect(keys(old)), keys(new)))
    added = sort(setdiff(collect(keys(new)), keys(old)))
    work = copy_state(from)
    for t in copy(added)
        for r in removed
            same = sort(old[r].columns; by = c -> c.name) == sort(new[t].columns; by = c -> c.name) &&
                   old[r].parent == new[t].parent && old[r].pk == new[t].pk
            if same && questioner("Was the table $(r) renamed to $(t) (model $(new[t].model))?")
                op = RenameModel(r, t; model = new[t].model)
                push!(ops, op)
                state_forwards!(op, work, app)
                filter!(!=(r), removed)
                filter!(!=(t), added)
                break
            end
        end
    end
    old = Dict(k => v for (k, v) in work if v.app == app)

    # new tables, created so that referenced tables come first
    for t in creation_order(Table[new[t] for t in added])
        push!(ops, CreateModel(t.name; model = t.model, columns = t.columns, unique_together = t.unique_together,
                               parent = t.parent, pk = t.pk, indexes = t.indexes))
    end

    # columns of tables that exist in both
    for name in sort(collect(intersect(keys(old), keys(new))))
        o, n = old[name], new[name]
        (o.parent != n.parent || o.pk != n.pk) &&
            throw(MigrationError("changing the parent model or primary key type of table '$name' isn't supported; create a new model and move the data"))
        ocols = Dict(c.name => c for c in o.columns)
        ncols = Dict(c.name => c for c in n.columns)
        gone = sort(setdiff(collect(keys(ocols)), keys(ncols)))
        fresh = [c.name for c in n.columns if !haskey(ocols, c.name)]
        for c in copy(fresh)
            for r in gone
                if same_definition(ocols[r], ncols[c]) && questioner("Was $(name).$(r) renamed to $(name).$(c)?")
                    push!(ops, RenameField(name, r, c))
                    filter!(!=(r), gone)
                    filter!(!=(c), fresh)
                    break
                end
            end
        end
        for c in fresh
            push!(ops, AddField(name, ncols[c]))
        end
        for c in n.columns
            haskey(ocols, c.name) && ocols[c.name] != c && push!(ops, AlterField(name, c))
        end
        # unique sets after renames; changed before columns are removed
        renamed = Dict(op.old => op.new for op in ops if op isa RenameField && op.table == name)
        ou = Juango.normalize_unique([[get(renamed, x, x) for x in u] for u in o.unique_together])
        ou == n.unique_together || push!(ops, AlterUniqueTogether(name, n.unique_together))
        oix = Dict(i.name => i for i in o.indexes)
        nix = Dict(i.name => i for i in n.indexes)
        for (k, i) in sort(collect(oix); by = first)
            get(nix, k, nothing) == i || push!(ops, RemoveIndex(name, k))
        end
        for (k, i) in sort(collect(nix); by = first)
            get(oix, k, nothing) == i || push!(ops, AddIndex(name, i))
        end
        for r in gone
            push!(ops, RemoveField(name, r))
        end
    end

    # dropped tables, referencing tables first
    for t in reverse(creation_order(Table[old[r] for r in removed]))
        push!(ops, DeleteModel(t.name))
    end
    ops
end

"Tables ordered so that tables referenced by others (within the list) come first."
function creation_order(tables::Vector{Table})
    names = Set(t.name for t in tables)
    byname = Dict(t.name => t for t in tables)
    out = Table[]
    seen = Set{String}()
    visit(t, path) = begin
        t.name in seen && return
        push!(path, t.name)
        for r in vcat([c.references for c in t.columns], [t.parent])
            (r !== nothing && r in names && !(r in path)) && visit(byname[r], path)
        end
        pop!(path)
        t.name in seen || (push!(seen, t.name); push!(out, t))
    end
    for t in sort(tables; by = t -> t.name)
        visit(t, String[])
    end
    out
end

# --- writing ------------------------------------------------------------------------------------

jl(x) = repr(x)
jl(x::AbstractString) = repr(String(x))

function column_code(c::Column)
    kw = String[]
    c.null && push!(kw, "null = true")
    c.default === nothing || push!(kw, "default = " * jl(c.default))
    c.unique && push!(kw, "unique = true")
    c.index && push!(kw, "index = true")
    c.max_length === nothing || push!(kw, "max_length = $(c.max_length)")
    c.references === nothing || push!(kw, "references = " * jl(c.references))
    c.of === nothing || push!(kw, "of = :$(c.of)")
    "Column($(jl(c.name)), :$(c.kind)" * (isempty(kw) ? ")" : "; " * join(kw, ", ") * ")")
end

index_code(i::Index) = "Index($(jl(i.columns)); name = $(jl(i.name))" * (i.unique ? ", unique = true" : "") *
                       (i.method === :btree ? ")" : ", method = :$(i.method))")
op_code(op::CreateModel) = "CreateModel($(jl(op.table)); model = $(jl(op.model)), columns = [\n" *
    join(["            " * column_code(c) * ",\n" for c in op.columns]) * "        ]" *
    (isempty(op.unique_together) ? "" : ", unique_together = $(jl(op.unique_together))") *
    (op.parent === nothing ? "" : ", parent = $(jl(op.parent))") *
    (op.pk === :auto ? "" : ", pk = :$(op.pk)") *
    (isempty(op.indexes) ? "" : ", indexes = [" * join(index_code.(op.indexes), ", ") * "]") * ")"
op_code(op::AddIndex) = "AddIndex($(jl(op.table)), $(index_code(op.index)))"
op_code(op::RemoveIndex) = "RemoveIndex($(jl(op.table)), $(jl(op.name)))"
op_code(op::AlterUniqueTogether) = "AlterUniqueTogether($(jl(op.table)), $(jl(op.unique_together)))"
op_code(op::DeleteModel) = "DeleteModel($(jl(op.table)))"
op_code(op::RenameModel) = "RenameModel($(jl(op.old)), $(jl(op.new))" * (op.model === nothing ? ")" : "; model = $(jl(op.model)))")
op_code(op::AddField) = "AddField($(jl(op.table)), $(column_code(op.column)))"
op_code(op::RemoveField) = "RemoveField($(jl(op.table)), $(jl(op.name)))"
op_code(op::AlterField) = "AlterField($(jl(op.table)), $(column_code(op.column)))"
op_code(op::RenameField) = "RenameField($(jl(op.table)), $(jl(op.old)), $(jl(op.new)))"
op_code(op::RunSQL) = "RunSQL($(jl(op.forward)), $(op.backward === nothing ? "nothing" : jl(op.backward)))"

function migration_code(m::Migration)
    deps = isempty(m.dependencies) ? "[]" :
           "[" * join(["($(jl(a)), $(jl(n)))" for (a, n) in m.dependencies], ", ") * "]"
    ops = isempty(m.operations) ?
        "        # RunSQL(\"UPDATE ...\", \"UPDATE ...\"),   # forward SQL, reverse SQL\n" *
        "        # RunJulia(() -> ..., () -> ...),         # forward function, reverse function\n" :
        join(["        " * op_code(op) * ",\n" for op in m.operations])
    """
    # Generated by Juango $VERSION_STRING on $(Dates.format(now(), "yyyy-mm-dd HH:MM"))
    using Juango.Migrations

    Migration(
        dependencies = $deps,$(m.initial ? "\n    initial = true," : "")
        operations = [
    $ops    ],
    )
    """
end

function suggest_name(ops, initial)
    initial && return "initial"
    isempty(ops) && return "auto_" * Dates.format(now(), "yyyymmdd_HHMM")
    part(op::CreateModel) = lowercase(op.model)
    part(op::DeleteModel) = "delete_" * op.table
    part(op::RenameModel) = "rename_" * op.old * "_" * op.new
    part(op::AddField) = op.table * "_" * op.column.name
    part(op::RemoveField) = "remove_" * op.table * "_" * op.name
    part(op::AlterField) = "alter_" * op.table * "_" * op.column.name
    part(op::RenameField) = "rename_" * op.table * "_" * op.old * "_" * op.new
    part(op::AlterUniqueTogether) = "alter_" * op.table * "_unique_together"
    part(op::AddIndex) = op.table * "_" * op.index.name
    part(op::RemoveIndex) = "remove_" * op.name
    part(op) = "custom"
    name = join(part.(ops), "_")
    all(op -> op isa AddField, ops) && length(ops) == 1 && (name = "add_" * name)
    s = replace(lowercase(name), r"[^a-z0-9_]+" => "_")
    length(s) > 50 ? "auto_" * Dates.format(now(), "yyyymmdd_HHMM") : s
end

next_number(g::Graph, app) = 1 + maximum([parse(Int, k[2][1:4]) for k in keys(g.nodes) if k[1] == app]; init = 0)

function write_file(app, number, name, m::Migration; dry_run = false, log = println)
    dir = migration_dir(app)
    dir === nothing && throw(MigrationError("app '$app' has no migrations directory; set MIGRATION_MODULES[\"$app\"]"))
    fname = lpad(number, 4, '0') * "_" * name * ".jl"
    path = joinpath(dir, fname)
    log("Migrations for '$app':")
    log("  $(relpath_or_abs(path))")
    for op in m.operations
        log("    - " * describe(op))
    end
    if !dry_run
        mkpath(dir)
        write(path, migration_code(m))
    end
    path
end
relpath_or_abs(p) = (r = relpath(p); startswith(r, "..") ? p : r)

"""
    makemigrations(; app="project", name=nothing, empty=false, merge=false, dry_run=false,
                   check=false, questioner=ask, verbose=true) -> Vector{String}

Write a migration for the changes between `app`'s models and its migrations, and return
the paths written. `check=true` only reports whether a migration is needed (returns the
would-be paths without writing). `merge=true` writes a merge migration for conflicting
branches. `empty=true` writes a migration with no operations, for `RunSQL`/`RunJulia`.
"""
function makemigrations(; app = "project", name = nothing, empty = false, merge = false, dry_run = false,
                        check = false, questioner = ask, verbose = true)
    log(msg) = verbose && println(msg)
    app = string(app)
    g = build_graph(unique(vcat(migrated_apps(), [app])))
    leaves = leaf_nodes(g, app)
    if merge
        length(leaves) > 1 || (log("No conflicts detected to merge."); return String[])
        m = Migration(; dependencies = leaves)
        nm = something(name, "merge_" * join([k[2][1:4] for k in leaves], "_"))
        return [write_file(app, next_number(g, app), nm, m; dry_run = dry_run || check, log = log)]
    end
    check_conflicts(g)
    ops = empty ? Operation[] : detect_changes(g, app; questioner = questioner)
    if isempty(ops) && !empty
        log("No changes detected" * (app == "project" ? "" : " in app '$app'"))
        return String[]
    end
    initial = isempty(leaves)
    deps = Set{Tuple{String,String}}(leaves)
    tables = Dict(modelmeta(T).table => modelmeta(T).app for T in all_models())
    for op in ops, c in (op isa CreateModel ? op.columns : op isa Union{AddField,AlterField} ? [op.column] : Column[])
        c.references === nothing && continue
        other = get(tables, c.references, app)
        other == app && continue
        ol = leaf_nodes(g, other)
        isempty(ol) && (log("  Warning: $(c.references) belongs to app '$other', which has no migrations."); continue)
        union!(deps, ol)
    end
    for op in ops
        if op isa AddField && !op.column.null && op.column.default === nothing
            bf = backfill_value(op.column)
            log(bf === nothing ?
                "  Warning: $(op.table).$(op.column.name) is NOT NULL with no default; existing rows have no value for it. Give the field a default or null=true." :
                "  Note: existing rows get $(repr(bf)) for the new NOT NULL column $(op.table).$(op.column.name).")
        end
    end
    m = Migration(; dependencies = sort(collect(deps)), operations = ops, initial = initial)
    [write_file(app, next_number(g, app), something(name, suggest_name(ops, initial)), m;
                dry_run = dry_run || check, log = log)]
end

end # module Migrations

using .Migrations: makemigrations, showmigrations, sqlmigrate
migrate(; kw...) = Migrations.migrate(; kw...)
