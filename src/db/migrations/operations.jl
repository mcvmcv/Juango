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
    constraints::Vector{ConstraintSpec}
    pk_columns::Vector{String}        # pk = :composite
    comment::Union{Nothing,String}    # db_table_comment
end
function CreateModel(table; model = table, columns = Column[], unique_together = [], parent = nothing, pk = :auto, indexes = Index[],
                     constraints = ConstraintSpec[], pk_columns = String[], comment = nothing)
    seen = Set{String}()
    for c in columns                   # (as Django's)
        c.name in seen && throw(ArgumentError("Found duplicate value $(c.name) in CreateModel fields argument."))
        push!(seen, c.name)
    end
    CreateModel(string(table), string(model), collect(Column, columns), Juango.normalize_unique(unique_together),
                parent === nothing ? nothing : string(parent), Symbol(pk), collect(Index, indexes), collect(ConstraintSpec, constraints),
                collect(String, pk_columns), comment === nothing ? nothing : string(comment))
end
to_table(op::CreateModel, app) = Table(op.table, app, op.model, copy(op.columns), [copy(u) for u in op.unique_together];
                                       parent = op.parent, pk = op.pk, indexes = copy(op.indexes), constraints = copy(op.constraints),
                                       pk_columns = copy(op.pk_columns), comment = op.comment)

"""
Change the size of a table's automatic integer key (`:auto` 64-bit, `:intauto` 32-bit,
`:smallauto` 16-bit), after `DEFAULT_AUTO_FIELD`, an app's `default_auto_field` or
`Meta(pk = ...)` changed. Foreign keys pointing at the table change with it.
"""
struct AlterPrimaryKey <: Operation
    table::String
    pk::Symbol
    AlterPrimaryKey(table, pk) = new(string(table), Symbol(pk))
end

"""
    SeparateDatabaseAndState(; database_operations = [], state_operations = [])

Run `database_operations` against the database and apply `state_operations` to the migration
state, separately (Django's operation of the same name): for example to start managing a table
that already exists, or to move a model between apps without touching its table.
"""
struct SeparateDatabaseAndState <: Operation
    database_operations::Vector{Operation}
    state_operations::Vector{Operation}
end
SeparateDatabaseAndState(; database_operations = Operation[], state_operations = Operation[]) =
    SeparateDatabaseAndState(collect(Operation, database_operations), collect(Operation, state_operations))

"Set or remove (`nothing`) a table's comment (`Meta(db_table_comment = ...)`)."
struct AlterModelTableComment <: Operation
    table::String
    comment::Union{Nothing,String}
    AlterModelTableComment(table, comment) = new(string(table), comment === nothing ? nothing : string(comment))
end

"Add a constraint (`ConstraintSpec`, from the model's `Meta(constraints = ...)`) to a table."
struct AddConstraint <: Operation
    table::String
    constraint::ConstraintSpec
end
AddConstraint(table, c::ConstraintSpec) = AddConstraint(string(table), c)

"Drop a constraint by name."
struct RemoveConstraint <: Operation
    table::String
    name::String
end

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

"""
    AddIndexConcurrently(table, index)    RemoveIndexConcurrently(table, name)

AddIndex / RemoveIndex with PostgreSQL's `CONCURRENTLY`: the table stays writable while the
index builds, which matters on big tables in production. PostgreSQL can't do that inside a
transaction, so a migration with one of these runs without one (as Django's `atomic = False`);
keep such a migration to that one operation. Other databases do a plain AddIndex / RemoveIndex.
"""
struct AddIndexConcurrently <: Operation
    table::String
    index::Index
end
AddIndexConcurrently(table, ix::Index) = AddIndexConcurrently(string(table), ix)
struct RemoveIndexConcurrently <: Operation
    table::String
    name::String
end
"Whether an operation must run outside a transaction on this backend."
needs_no_transaction(op, b) = false
needs_no_transaction(::Union{AddIndexConcurrently,RemoveIndexConcurrently}, b) = b isa Juango.PostgresBackend

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
    CreateExtension(name)

Install a PostgreSQL extension (`CREATE EXTENSION IF NOT EXISTS`); a no-op on other
databases. Reversing it drops the extension. `HStoreExtension()`, `TrigramExtension()`,
`UnaccentExtension()`, `BtreeGistExtension()`, `BtreeGinExtension()` and `CITextExtension()`
name the common ones.
"""
struct CreateExtension <: Operation
    name::String
end
CreateExtension(name::Symbol) = CreateExtension(string(name))
HStoreExtension() = CreateExtension("hstore")
TrigramExtension() = CreateExtension("pg_trgm")
UnaccentExtension() = CreateExtension("unaccent")
BtreeGistExtension() = CreateExtension("btree_gist")
BtreeGinExtension() = CreateExtension("btree_gin")
CITextExtension() = CreateExtension("citext")
state_forwards!(::CreateExtension, st, app) = st
forwards(op::CreateExtension, b, from, to, deferred) =
    b isa Juango.PostgresBackend ? ["CREATE EXTENSION IF NOT EXISTS " * quote_name(b, op.name)] : String[]
backwards(op::CreateExtension, b, from, to, deferred) =
    b isa Juango.PostgresBackend ? ["DROP EXTENSION IF EXISTS " * quote_name(b, op.name)] : String[]
describe(op::CreateExtension) = "Create extension $(op.name)"
op_code(op::CreateExtension) = "CreateExtension($(jl(op.name)))"

"""
    RunSQL(forward, backward=nothing)

Raw SQL. Each of `forward` and `backward` is a string, which may hold several statements
separated by `;` (they're run one by one), or a vector whose items are statements or
`(sql, params)` pairs with `?` placeholders: `("UPDATE t SET x = ? WHERE id = ?", [1, 2])`
(as Django's). Without `backward` the migration can't be unapplied; pass `\"\"` for a no-op reverse.
"""
struct RunSQL <: Operation
    forward::Vector{Any}                      # SQL strings and (sql, params) tuples
    backward::Union{Nothing,Vector{Any}}
    RunSQL(forward, backward = nothing) = new(sqllist(forward), backward === nothing ? nothing : sqllist(backward))
end
sqllist(x::AbstractString) = Any[s for s in split_sql(x)]
sqllist(x) = Any[sql_item(s) for s in x]
sql_item(s::AbstractString) = String(s)
function sql_item(s)
    length(s) == 2 || throw(ArgumentError("Expected a 2-tuple but got $(length(s))"))
    s[2] === nothing ? String(s[1]) : (String(s[1]), collect(Any, s[2]))
end
"The action that runs one RunSQL statement: the SQL, or a function running it with its parameters."
sql_action(s::String) = s
sql_action(s::Tuple) = () -> Juango.execute(s[1], s[2])

"""
    split_sql(s) -> Vector{String}

The statements of a string of SQL, split at the `;`s outside quotes (`'…'`, `"…"`, `` `…` ``),
PostgreSQL dollar quotes (`\$\$…\$\$`, `\$body\$…\$body\$`) and comments; empty ones dropped.
"""
function split_sql(s::AbstractString)
    out = String[]
    buf = IOBuffer()
    i, n = firstindex(s), lastindex(s)
    while i <= n
        c = s[i]
        if c in ('\'', '"', '`')
            j = nextind(s, i)
            while j <= n && !(s[j] == c && !(j < n && s[nextind(s, j)] == c))
                s[j] == c && (j = nextind(s, j))         # a doubled quote inside
                j = nextind(s, j)
            end
            print(buf, SubString(s, i, min(j, n))); i = nextind(s, min(j, n))
        elseif c == '-' && i < n && s[nextind(s, i)] == '-'
            j = something(findnext('\n', s, i), n)
            print(buf, SubString(s, i, j)); i = nextind(s, j)
        elseif c == '/' && i < n && s[nextind(s, i)] == '*'
            r = findnext("*/", s, i)
            j = r === nothing ? n : last(r)
            print(buf, SubString(s, i, j)); i = nextind(s, j)
        elseif c == '$' && (m = match(r"^\$(\w*)\$", SubString(s, i))) !== nothing
            tag = m.match
            r = findnext(tag, s, i + ncodeunits(tag))
            j = r === nothing ? n : last(r)
            print(buf, SubString(s, i, j)); i = nextind(s, j)
        elseif c == ';'
            push!(out, strip(String(take!(buf)))); i = nextind(s, i)
        else
            print(buf, c); i = nextind(s, i)
        end
    end
    push!(out, strip(String(take!(buf))))
    filter!(x -> !isempty(x) && !all(l -> isempty(strip(l)) || startswith(strip(l), "--"), split(x, '\n')), out)
end

"""
    RunJulia(forward, backward=nothing)

Run Julia code as part of a migration, typically a data migration. A function of one
argument gets the models as they were at this point in history (use those, not today's
model structs, whose fields may since have changed):

    RunJulia(apps -> for p in objects(get_model(apps, "blog", "Post"))
                         p.slug = lowercase(p.title); save!(p)
                     end)

A function of no arguments just runs (e.g. `Juango.execute` with raw SQL).
"""
struct RunJulia <: Operation
    forward::Function
    backward::Union{Nothing,Function}
    RunJulia(forward, backward = nothing) = new(forward, backward)
end

"""
    Migration(; dependencies=[], operations=[], initial=false, replaces=[], run_before=[])

The value a migration file evaluates to. `dependencies` are `(app, name)` pairs; a name may be
`"__first__"` (the app's first migration, or nothing when the app has none) or `"__latest__"`
(its latest). `run_before` names migrations that must run after this one, as if they depended
on it (Django's `run_before`, for migrations of apps you don't control). The app and name come
from the file's directory and filename.
"""
mutable struct Migration
    app::String
    name::String
    dependencies::Vector{Tuple{String,String}}
    operations::Vector{Operation}
    initial::Bool
    path::String
    replaces::Vector{Tuple{String,String}}   # a squashed migration: the migrations it stands for
    run_before::Vector{Tuple{String,String}} # migrations that must run after this one (they depend on it)
end
Migration(; dependencies = [], operations = [], initial = false, replaces = [], run_before = []) =
    Migration("", "", Tuple{String,String}[(string(a), string(n)) for (a, n) in dependencies],
              collect(Operation, operations), initial, "", Tuple{String,String}[(string(a), string(n)) for (a, n) in replaces],
              Tuple{String,String}[(string(a), string(n)) for (a, n) in run_before])

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
state_forwards!(op::AlterModelTableComment, st, app) = (table!(st, op.table).comment = op.comment; st)
function state_forwards!(op::AlterPrimaryKey, st, app)
    table!(st, op.table).pk = op.pk
    of = op.pk === :intauto ? :int : op.pk === :smallauto ? :smallint : nothing
    for t in values(st)
        t.parent == op.table && (t.pk = op.pk)            # multi-table children share the key
        for (i, c) in enumerate(t.columns)
            c.kind === :fk && c.references !== nothing && Juango.ref_table(c.references) == op.table &&
                (t.columns[i] = with_column(c; of = of))
        end
    end
    st
end
state_forwards!(op::AddIndex, st, app) = (push!(table!(st, op.table).indexes, op.index); st)
state_forwards!(op::RemoveIndex, st, app) = (filter!(i -> i.name != op.name, table!(st, op.table).indexes); st)
state_forwards!(op::AddIndexConcurrently, st, app) = state_forwards!(AddIndex(op.table, op.index), st, app)
state_forwards!(op::RemoveIndexConcurrently, st, app) = state_forwards!(RemoveIndex(op.table, op.name), st, app)
function state_forwards!(op::AddConstraint, st, app)
    t = table!(st, op.table)
    t.constraints = sort(vcat(filter(c -> c.name != op.constraint.name, t.constraints), [op.constraint]); by = c -> c.name)
    st
end
state_forwards!(op::RemoveConstraint, st, app) = (filter!(c -> c.name != op.name, table!(st, op.table).constraints); st)
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
    # named indexes and constraints follow the column (the database renames it in them); an unnamed
    # index keeps the name it was created with, so it stays as it is and the autodetector replaces it
    ren(x) = x == op.old ? op.new : x
    t.indexes = [ix.name === nothing ? ix :
                 Juango.Index(ren.(ix.columns), ix.name, ix.unique, ix.method, [(f, ren(c)) for (f, c) in ix.expressions],
                              ix.condition, ren.(ix.include), ix.opclasses) for ix in t.indexes]
    t.constraints = [Juango.ConstraintSpec(c.kind, c.name, ren.(c.columns),
                                           [c.kind === :exclusion ? (ren(f), x) : (f, ren(x)) for (f, x) in c.expressions],
                                           c.condition, c.index_type, c.opclasses, ren.(c.include), c.deferrable) for c in t.constraints]
    st
end
state_forwards!(::Union{RunSQL,RunJulia}, st, app) = st
state_forwards!(op::SeparateDatabaseAndState, st, app) = (foreach(o -> state_forwards!(o, st, app), op.state_operations); st)

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

forwards(op::AlterPrimaryKey, b, from, to, deferred) = Juango.alter_pk_sql(b, to, op.table)
backwards(op::AlterPrimaryKey, b, from, to, deferred) = Juango.alter_pk_sql(b, from, op.table)
forwards(op::AlterModelTableComment, b, from, to, deferred) = Juango.table_comment_sql(b, op.table, op.comment)
backwards(op::AlterModelTableComment, b, from, to, deferred) = Juango.table_comment_sql(b, op.table, from[op.table].comment)
forwards(op::AddIndex, b, from, to, deferred) = Juango.index_spec_sql(b, op.table, op.index)
backwards(op::AddIndex, b, from, to, deferred) = Juango.drop_index_spec_sql(b, op.table, op.index)
forwards(op::RemoveIndex, b, from, to, deferred) =
    Juango.drop_index_spec_sql(b, op.table, only(filter(i -> i.name == op.name, from[op.table].indexes)))
forwards(op::AddConstraint, b, from, to, deferred) = Juango.add_constraint_sql(b, from[op.table], to[op.table], op.constraint)
backwards(op::AddConstraint, b, from, to, deferred) = Juango.remove_constraint_sql(b, to[op.table], from[op.table], op.constraint)
forwards(op::RemoveConstraint, b, from, to, deferred) =
    Juango.remove_constraint_sql(b, from[op.table], to[op.table], only(filter(c -> c.name == op.name, from[op.table].constraints)))
backwards(op::RemoveConstraint, b, from, to, deferred) =
    Juango.add_constraint_sql(b, to[op.table], from[op.table], only(filter(c -> c.name == op.name, from[op.table].constraints)))
backwards(op::RemoveIndex, b, from, to, deferred) =
    Juango.index_spec_sql(b, op.table, only(filter(i -> i.name == op.name, from[op.table].indexes)))

# (to the same name: nothing to do, as Django's AlterModelTable)
forwards(op::RenameModel, b, from, to, deferred) = op.old == op.new ? Any[] : rename_table_sql(b, from[op.old], to[op.new])
backwards(op::RenameModel, b, from, to, deferred) = op.old == op.new ? Any[] : rename_table_sql(b, to[op.new], from[op.old])

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

"The states the database operations of a SeparateDatabaseAndState pass through, from `from`."
function db_states(op::SeparateDatabaseAndState, from)
    states = [copy_state(from)]
    for o in op.database_operations
        push!(states, state_forwards!(o, copy_state(states[end]), "_"))
    end
    states
end
function forwards(op::SeparateDatabaseAndState, b, from, to, deferred)
    states = db_states(op, from)
    Any[a for (i, o) in enumerate(op.database_operations) for a in forwards(o, b, states[i], states[i+1], deferred)]
end
function backwards(op::SeparateDatabaseAndState, b, from, to, deferred)
    states = db_states(op, from)              # `from` is the state before the operation, in both directions
    Any[a for i in length(op.database_operations):-1:1
          for a in backwards(op.database_operations[i], b, states[i], states[i+1], deferred)]
end

forwards(op::RunSQL, b, from, to, deferred) = Any[sql_action(s) for s in op.forward]
function backwards(op::RunSQL, b, from, to, deferred)
    op.backward === nothing && throw(IrreversibleError("RunSQL has no reverse SQL"))
    Any[sql_action(s) for s in op.backward]
end
"A RunJulia function as an action: one that takes an argument gets the historical models."
function julia_action(f, st)
    () -> begin
        apps = Juango.HistoricalApps(st)
        Base.invokelatest(applicable, f, apps) ? Base.invokelatest(f, apps) : Base.invokelatest(f)
    end
end
forwards(op::RunJulia, b, from, to, deferred) = Any[julia_action(op.forward, copy_state(from))]
function backwards(op::RunJulia, b, from, to, deferred)
    op.backward === nothing && throw(IrreversibleError("RunJulia has no reverse function"))
    Any[julia_action(op.backward, copy_state(from))]
end

describe(op::CreateModel) = "Create model $(op.model) (table $(op.table))"
describe(op::DeleteModel) = "Delete table $(op.table)"
describe(op::RenameModel) = "Rename table $(op.old) to $(op.new)"
describe(op::AddField) = "Add field $(op.column.name) to $(op.table)"
describe(op::RemoveField) = "Remove field $(op.name) from $(op.table)"
describe(op::AlterField) = "Alter field $(op.column.name) on $(op.table)"
describe(op::RenameField) = "Rename field $(op.old) on $(op.table) to $(op.new)"
describe(op::AlterUniqueTogether) = "Alter unique_together for $(op.table)"
describe(op::AlterPrimaryKey) = "Alter the primary key of $(op.table) to $(op.pk)"
describe(op::AlterModelTableComment) = "Alter the comment of table $(op.table)"
describe(op::AddIndex) = "Create index $(op.index.name) on $(op.table)"
describe(op::RemoveIndex) = "Remove index $(op.name) from $(op.table)"
describe(op::AddIndexConcurrently) = "Concurrently create index $(op.index.name) on $(op.table)"
describe(op::RemoveIndexConcurrently) = "Concurrently remove index $(op.name) from $(op.table)"

# the plain operation's SQL, with CONCURRENTLY on PostgreSQL
sql_list(v) = v isa AbstractString ? [String(v)] : collect(String, v)
create_concurrently(v, b) = b isa Juango.PostgresBackend ?
    [replace(s, r"^CREATE (UNIQUE )?INDEX " => s"CREATE \1INDEX CONCURRENTLY "; count = 1) for s in sql_list(v)] : v
drop_concurrently(v, b) = b isa Juango.PostgresBackend ?
    [replace(s, r"^DROP INDEX " => "DROP INDEX CONCURRENTLY "; count = 1) for s in sql_list(v)] : v
forwards(op::AddIndexConcurrently, b, from, to, deferred) = create_concurrently(forwards(AddIndex(op.table, op.index), b, from, to, deferred), b)
backwards(op::AddIndexConcurrently, b, from, to, deferred) = drop_concurrently(backwards(AddIndex(op.table, op.index), b, from, to, deferred), b)
forwards(op::RemoveIndexConcurrently, b, from, to, deferred) = drop_concurrently(forwards(RemoveIndex(op.table, op.name), b, from, to, deferred), b)
backwards(op::RemoveIndexConcurrently, b, from, to, deferred) = create_concurrently(backwards(RemoveIndex(op.table, op.name), b, from, to, deferred), b)
describe(op::AddConstraint) = "Create constraint $(op.constraint.name) on $(op.table)"
describe(op::RemoveConstraint) = "Remove constraint $(op.name) from $(op.table)"
describe(op::RunSQL) = "Raw SQL operation"
describe(op::SeparateDatabaseAndState) = "Custom state/database change combination"
describe(op::RunJulia) = "Raw Julia operation"
