# Switching AUTH_USER_MODEL after the first migration --------------------------------------------------------
#
# Django's best-known trap: the user model must be chosen before the first migration. Juango's
# way out, with the old model still in AUTH_USER_MODEL:
#
#   1. write the new model (`@model struct Member <: AbstractUser ... end`, app "accounts"), run
#      makemigrations and migrate: its table (and its groups/permissions join tables) exist, empty;
#   2. `manage.jl swap_user_model accounts.Member` (`--dry-run` prints the plan): copies the users
#      with their ids, their groups and permissions, moves every foreign key that points at the old
#      user table to the new one (admin's LogEntry and your models), and moves the id sequence on;
#   3. set AUTH_USER_MODEL = "accounts.Member" and deploy. Logged-in sessions stay valid (same ids).
#
# Migrations refer to the user model as "__user_model__", so they need no change. The old table
# is left as it was (drop it later with a migration when you're sure).

"""
    swap_user_model(new; dry_run = false, log = println) -> Vector{String}

Move the users of the current AUTH_USER_MODEL to the model `new` (a type or "app.Model"): see
the comment above. Returns the statements it ran (or would run). Refuses if the new table already
has rows, or if `new` is already AUTH_USER_MODEL.
"""
function swap_user_model(new; dry_run::Bool = false, log = println)
    Old = get_user_model()
    New = new isa Type ? new : get_model(string(new))
    New <: AbstractUser || throw(ArgumentError("$New doesn't extend AbstractUser"))
    New === Old && throw(ArgumentError("$New is already AUTH_USER_MODEL: run this before switching the setting"))
    b = backend()
    otab, ntab = modelmeta(Old).table, modelmeta(New).table
    table_exists(b, ntab) || throw(ImproperlyConfigured("$ntab doesn't exist: run makemigrations and migrate for $(nameof(New)) first"))
    dry_run || count(base_objects(New)) == 0 || throw(ArgumentError("$ntab already has rows; swap_user_model copies into an empty table"))
    q(x) = quote_name(b, x)
    stmts = String[]
    # 1. the users, ids kept: the columns both tables have
    ocols = Set(c.name for c in table_state(Old).columns)
    cols = [c.name for c in table_state(New).columns if c.name in ocols]
    push!(stmts, "INSERT INTO $(q(ntab)) (" * join(q.(cols), ", ") * ") SELECT " * join(q.(cols), ", ") * " FROM $(q(otab))")
    # 2. their groups and permissions (and any other many-to-many both models have)
    for f in modelmeta(New).m2m
        g = findfirst(x -> x.name === f.name, modelmeta(Old).m2m)
        g === nothing && continue
        of = modelmeta(Old).m2m[g]
        (osrc, odst), (nsrc, ndst) = through_fks(of), through_fks(f)
        push!(stmts, "INSERT INTO $(q(modelmeta(through_model(f)).table)) ($(q(attname(nsrc))), $(q(attname(ndst)))) " *
                     "SELECT $(q(attname(osrc))), $(q(attname(odst))) FROM $(q(modelmeta(through_model(of)).table))")
    end
    # 3. foreign keys pointing at the old table move to the new one
    moves = Tuple{Table,Table,String}[]
    keep = Set(vcat([otab, ntab], [modelmeta(through_model(f)).table for f in modelmeta(Old).m2m]))   # (the old links stay as they were)
    for (tname, t) in models_state()
        tname in keep && continue
        changed = false
        old_t, new_t = copy(t), copy(t)
        for (i, c) in enumerate(t.columns)
            c.references === nothing && continue
            ref_table(c.references) == otab || c.references == otab || c.references == "__user_model__" || continue
            old_t.columns[i] = with_column(c; references = otab)
            new_t.columns[i] = with_column(c; references = ntab)
            changed = true
        end
        changed || continue
        for c in new_t.columns
            c.references == ntab && push!(moves, (old_t, new_t, c.name))
        end
    end
    deferred = String[]
    for (old_t, new_t, cname) in moves
        # (for SQLite each column change rebuilds the table, so later moves start from the rebuilt one)
        append!(stmts, alter_column_sql(b, old_t, new_t, cname, deferred))
        idx = findfirst(c -> c.name == cname, old_t.columns)
        old_t.columns[idx] = new_t.columns[idx]
    end
    append!(stmts, deferred)
    log("Moving $(count(base_objects(Old))) user(s) from $otab to $ntab:")
    foreach(s -> log("  ", s), stmts)
    dry_run && return stmts
    schema_atomic() do                         # (SQLite rebuilds the tables: their keys are checked at the end)
        foreach(s -> execute(s, Any[]), stmts)
        sync_sequence(b, ntab)
    end
    log("Done. Now set AUTH_USER_MODEL = \"$(modelmeta(New).app).$(nameof(New))\" and restart.")
    stmts
end

"""
The `auth.W020` check: AUTH_USER_MODEL names a model whose table is empty while Juango's own
user table still holds users, the sign of a switch without moving them (`swap_user_model`).
"""
function user_model_swap_issues()
    T = get_user_model()
    T === User && return String[]
    b = backend()
    try
        ut = modelmeta(User).table
        (table_exists(b, ut) && table_exists(b, modelmeta(T).table)) || return String[]
        n_old = execute("SELECT COUNT(*) AS n FROM $(quote_name(b, ut))", Any[])[1][:n]
        (n_old > 0 && count(base_objects(T)) == 0) || return String[]
        ["AUTH_USER_MODEL is $(modelmeta(T).app).$(nameof(T)), whose table is empty, while $ut still has $n_old user(s) " *
         "(and foreign keys may still point there). Set AUTH_USER_MODEL back, run `manage.jl swap_user_model " *
         "$(modelmeta(T).app).$(nameof(T))`, then switch it again."]
    catch
        String[]
    end
end
