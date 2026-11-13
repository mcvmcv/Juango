# --- executing ----------------------------------------------------------------------------------

run_action(a::AbstractString) = execute(a)
run_action(f::Function) = Base.invokelatest(f)   # defined in a migration file loaded after this code was compiled

"""
Tables of Juango's `User` (and its many-to-many join tables) when `AUTH_USER_MODEL` names
another model: migrations keep them in their state but don't touch the database, as Django
does for swappable models.
"""
function swapped_tables()
    U = Juango.User
    Juango.get_user_model() === U && return Set{String}()
    t = Juango.modelmeta(U).table
    Set{String}([t; [t * "_" * string(f.name) for f in Juango.modelmeta(U).m2m]])
end
skips_database(op::Operation, swapped) = !isempty(swapped) && hasfield(typeof(op), :table) && getfield(op, :table) in swapped

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
    swapped = swapped_tables()
    if backwards
        for i in length(m.operations):-1:1
            skips_database(m.operations[i], swapped) && continue
            append!(actions, Migrations.backwards(m.operations[i], b, states[i], states[i+1], deferred))
        end
    else
        for (i, op) in enumerate(m.operations)
            skips_database(op, swapped) && continue
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
    swapped = swapped_tables()
    tables = [op.table for op in m.operations if op isa CreateModel && !(op.table in swapped)]
    isempty(tables) && return false
    all(t -> table_exists(b, t), tables) || return false
    for op in m.operations
        skips_database(op, swapped) && continue
        if op isa CreateModel
            cols = Set(table_columns(b, op.table))
            all(c -> c.name in cols, op.columns) || return false
        elseif op isa AddField
            op.column.name in Set(table_columns(b, op.table)) || return false
        end
    end
    true
end

function apply!(g::Graph, k; backwards = false, fake = false, fake_initial = true, log = println)
    m = g.nodes[k]
    label = backwards ? "  Unapplying $(m)..." : "  Applying $(m)..."
    if !backwards && !fake && fake_initial && already_in_database(m)
        record_applied_all!(m)
        log(label * " FAKED (tables already exist)")
        return
    end
    atomic() do
        fake || foreach(run_action, migration_actions(g, k; backwards = backwards))
        backwards ? record_unapplied_all!(m) : record_applied_all!(m)
    end
    log(label * (fake ? " FAKED" : " OK"))
end

"""
`migrate(app = ..., prune = true)`: forget migrations recorded as applied whose files no longer
exist, e.g. after deleting the migrations a squashed one replaced (Django's `migrate --prune`).
"""
function prune_migrations(app; log = println)
    app === nothing && throw(MigrationError("migrations can be pruned only for an app: migrate(app = \"...\", prune = true)"))
    g = build_graph(; applied = Set{Tuple{String,String}}())
    gone = sort([k for k in applied_migrations() if k[1] == app && !haskey(g.nodes, k)])
    still_replaced = Set(r for m in values(g.nodes) if m.app == app for r in m.replaces)
    log("Pruning migrations:")
    isempty(gone) && log("  No migrations to prune.")
    for k in gone
        if k in still_replaced
            log("  Skipping $(k[1]).$(k[2]): a squashed migration still lists it in `replaces`; remove that line first.")
        else
            record_unapplied!(k)
            log("  Pruning $(k[1]).$(k[2]) OK")
        end
    end
    nothing
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
only synchronises tables for every model. `database` picks one of `DATABASES` (default
"default"); the routers' `allow_migrate` decides which apps' migrations really run there
(the others are only recorded).
"""
migrate(; database = nothing, kw...) = Juango.with_db(() -> migrate_here(; kw...), database)

function migrate_here(; app = nothing, target = nothing, fake = false, fake_initial = true, sync = false, prune = false,
                      verbose = true)
    log(msg) = verbose && println(msg)
    prune && return prune_migrations(app; log = log)
    db = Juango.current_alias()
    allowed(T) = Juango.migrate_allowed(db, modelmeta(T).app; model = T)
    if sync
        log("Synchronizing all models (migration files ignored):")
        sync_models!(filter(T -> Juango.model_in_use(T) && allowed(T), all_models()); verbose = verbose) || log("  No changes.")
        return nothing
    end
    target !== nothing && app === nothing && (app = "project")
    applied = applied_migrations()
    g = build_graph(; applied = applied)
    check_conflicts(g)
    for m in values(g.nodes)       # a squashed migration whose originals all ran counts as applied
        if !isempty(m.replaces) && !(key(m) in applied) && all(in(applied), m.replaces)
            record_applied!(key(m)); push!(applied, key(m))
        end
    end
    plan = migration_plan(g, applied; app = app, target = target)
    unmigrated = [T for T in all_models() if Juango.model_in_use(T) && !(modelmeta(T).app in migrated_apps()) && allowed(T)]
    log("Operations to perform:")
    isempty(g.nodes) || log("  Apply all migrations: " * join(sort(unique(first.(collect(keys(g.nodes))))), ", "))
    isempty(unmigrated) || target !== nothing ||
        log("  Synchronize unmigrated apps: " * join(sort(unique([modelmeta(T).app for T in unmigrated])), ", "))
    labels = migrate_labels(g)
    emit(sig, st) = for a in labels
        Juango.send(sig, a; app_label = a, database = db, plan = plan, apps = Juango.HistoricalApps(st))
    end
    emit(Juango.pre_migrate, replay(g, filter(in(applied), keys(g.nodes))))
    log("Running migrations:")
    isempty(plan) && log("  No migrations to apply.")
    for (k, back) in plan
        apply!(g, k; backwards = back, fake = fake || !Juango.migrate_allowed(db, k[1]), fake_initial = fake_initial, log = log)
    end
    if target === nothing && !isempty(unmigrated)
        log("Synchronizing apps without migrations:")
        sync_models!(unmigrated; verbose = verbose) || log("  No changes.")
    end
    emit(Juango.post_migrate, replay(g, filter(in(applied_migrations()), keys(g.nodes))))
    if verbose && target === nothing
        for a in migrated_apps()
            isempty(detect_changes(g, a; questioner = _ -> false)) && continue
            log("  Your models in app '$a' have changes that are not yet reflected in a migration. " *
                "Run 'manage.jl makemigrations' and then 'manage.jl migrate'.")
        end
    end
    nothing
end

"""
The app labels `pre_migrate`/`post_migrate` are sent for: apps with models in use or
migrations, with contenttypes, auth and sites first (their receivers set up what other
apps' receivers may need).
"""
function migrate_labels(g::Graph)
    s = Set{String}(modelmeta(T).app for T in all_models() if Juango.model_in_use(T))
    union!(s, first.(collect(keys(g.nodes))))
    union!(s, ("contenttypes", "auth", "sites"))
    firsts = [a for a in ("contenttypes", "auth", "sites") if a in s]
    vcat(firsts, sort!([a for a in s if !(a in firsts)]))
end

# Juango's own post_migrate receivers
function builtin_post_migrate(label; database, kw...)
    label == "contenttypes" && Juango.migrate_allowed(database, "contenttypes") && Juango.update_contenttypes!()
    label == "auth" && Juango.migrate_allowed(database, "auth") && Juango.update_permissions!()
    label == "sites" && Juango.migrate_allowed(database, "sites") && Juango.create_default_site!()
    nothing
end
Juango.connect!(Juango.post_migrate, builtin_post_migrate; dispatch_uid = :juango_builtin_post_migrate)

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
