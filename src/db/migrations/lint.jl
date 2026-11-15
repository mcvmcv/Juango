# Migration safety: operations that lock or break a running site -------------------------------------------
#
# Fine on a laptop, painful in production: a NOT NULL column without a default fails the
# inserts of the code still running during a deploy; renaming or dropping a column breaks
# that code; changing a column's type rewrites the table under a lock; an index built without
# CONCURRENTLY blocks writes on PostgreSQL. `makemigrations` warns about these when it writes a
# migration, and `manage.jl check --tag migrations` about unapplied ones. A migration file
# containing `# juango: allow-unsafe` is accepted as it is; `MIGRATION_LINT = :error` makes the
# check fail CI, `false` turns it off.

"One problem the linter found: the operation (by its place in the migration), an id, a message and the safe way."
struct LintWarning
    migration::String
    op::Int
    id::String
    msg::String
    hint::String
end
Base.show(io::IO, w::LintWarning) = print(io, w.migration, " (operation ", w.op, "): ", w.msg, "\n    ", w.hint)

const LINT_DOCS = "See \"Migration safety\" in the README."

"Whether a migration file says its unsafe operations are deliberate (`# juango: allow-unsafe`)."
allows_unsafe(m::Migration) = !isempty(m.path) && isfile(m.path) && occursin(r"#\s*juango:\s*allow-unsafe"i, read(m.path, String))

"""
    lint_migration(m, state_before; backend = Juango.backend()) -> Vector{LintWarning}

The operations of migration `m` that are unsafe for a site running while it's applied (see
the file's header), given the schema before it. Tables the migration creates itself are empty,
so changes to them are fine; so is everything in an initial migration.
"""
function lint_migration(m::Migration, state; backend = Juango.backend())
    out = LintWarning[]
    (m.initial || allows_unsafe(m)) && return out
    label = string(m)
    pg, my = backend isa Juango.PostgresBackend, backend isa Juango.MySQLBackend
    fresh = Set{String}()                      # tables created by this migration
    st = copy_state(state)
    warn(i, id, msg, hint) = push!(out, LintWarning(label, i, id, msg, hint * " " * LINT_DOCS))
    for (i, op) in enumerate(m.operations)
        t = hasfield(typeof(op), :table) ? getfield(op, :table) : nothing
        if op isa CreateModel
            push!(fresh, op.table)
        elseif t !== nothing && t in fresh
            # a table made in this migration: nothing to lock or break
        elseif op isa AddField
            c = op.column
            if !c.null && c.default === nothing && c.generated === nothing
                warn(i, "migrations.W001", "Adding NOT NULL column $t.$(c.name) without a database default: inserts by the code still running fail.",
                     "Add it with null = true (or a db_default), deploy, backfill, then make it NOT NULL.")
            end
            if pg && (c.unique || c.index)
                warn(i, "migrations.W005", "Adding $t.$(c.name) with an index builds it while blocking writes to $t.",
                     "Add the column without the index, then add the index with AddIndexConcurrently in a migration of its own.")
            end
        elseif op isa RemoveField
            warn(i, "migrations.W002", "Removing column $t.$(op.name): the code still running reads and writes it.",
                 "Deploy the code without the field first (SeparateDatabaseAndState can drop it from the state), then drop the column in a later migration.")
        elseif op isa DeleteModel
            warn(i, "migrations.W002", "Dropping table $t: the code still running uses it.",
                 "Deploy the code without the model first, then drop the table in a later migration.")
        elseif op isa RenameField
            warn(i, "migrations.W003", "Renaming column $t.$(op.old) to $(op.new): the code still running uses the old name.",
                 "Add the new column, write both, backfill, switch the reads, then drop the old one (or keep the column name with db_column).")
        elseif op isa RenameModel
            warn(i, "migrations.W003", "Renaming table $(op.old) to $(op.new): the code still running uses the old name.",
                 "Keep the table name (Meta(table = ...)) and rename only the model, or migrate in steps.")
        elseif op isa AlterField
            old = haskey(st, t) && hascolumn(st[t], op.column.name) ? getcolumn(st[t], op.column.name) : nothing
            c = op.column
            if old !== nothing
                if Juango.full_column_type(backend, old) != Juango.full_column_type(backend, c)
                    warn(i, "migrations.W004", "Changing the type of $t.$(c.name) rewrites the table under a lock (and the running code expects the old type).",
                         "Add a new column of the new type, backfill it, switch the code over, then drop the old one.")
                elseif my
                    warn(i, "migrations.W007", "Altering $t.$(c.name) on MySQL/MariaDB may rebuild the table and lock it.",
                         "Check the change is INSTANT or INPLACE for your server, or run it at a quiet time.")
                end
                if old.null && !c.null
                    warn(i, "migrations.W006", "Making $t.$(c.name) NOT NULL scans the whole table under a lock, and fails the inserts of code that leaves it empty.",
                         pg ? "Add CHECK ($(c.name) IS NOT NULL) NOT VALID, VALIDATE CONSTRAINT it (no write lock), then SET NOT NULL (RunSQL)." :
                              "Backfill first, deploy code that always sets it, and run this at a quiet time.")
                end
                if pg && ((c.unique && !old.unique) || (c.index && !old.index))
                    warn(i, "migrations.W005", "Adding an index on $t.$(c.name) blocks writes to $t while it builds.",
                         "Leave the field's index off and add it with AddIndexConcurrently in a migration of its own.")
                end
            end
        elseif op isa AddIndex && pg
            warn(i, "migrations.W005", "AddIndex on $t blocks writes to $t while it builds.",
                 "Use AddIndexConcurrently, in a migration of its own (it can't run in a transaction).")
        elseif op isa AddConstraint && pg && op.constraint.kind === :unique
            warn(i, "migrations.W005", "Adding unique constraint $(op.constraint.name) on $t builds an index while blocking writes.",
                 "Build a unique index with AddIndexConcurrently first, or run this at a quiet time.")
        elseif op isa AlterUniqueTogether && pg
            warn(i, "migrations.W005", "Changing unique_together on $t builds indexes while blocking writes.",
                 "Run it at a quiet time, or create the unique indexes concurrently first (RunSQL ... CONCURRENTLY).")
        end
        st = state_forwards!(op, st, m.app)
    end
    out
end

"Lint migration `k` of graph `g` (with the schema before it)."
lint_migration(g::Graph, k; backend = Juango.backend()) = lint_migration(g.nodes[k], state_before(g, k); backend = backend)

"Lint the migrations not applied to the current database yet."
function lint_unapplied(; backend = Juango.backend())
    g = build_graph()
    done = applied_migrations()
    out = LintWarning[]
    for k in topo_order(g)
        k in done && continue
        append!(out, lint_migration(g, k; backend = backend))
    end
    out
end
