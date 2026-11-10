# Schema state and DDL ------------------------------------------------------------------------
#
# A `Table` / `Column` snapshot describes the database schema independently of the live
# model structs. Migrations replay operations on these snapshots ("project state"), the
# autodetector compares them, and the functions below turn them into DDL for the current
# backend. Only schema-relevant attributes are tracked (type, NULL, DB default, unique,
# index, foreign key target). Choices, help text and validators never cause migrations.

"""
    Column(name, kind; null=false, default=nothing, unique=false, index=false,
           max_length=nothing, references=nothing)

One column in a migration snapshot. `kind` is `:string :int :float :bool :datetime :date :fk`.
`references` is the table a foreign key points at.
"""
struct Column
    name::String
    kind::Symbol
    null::Bool
    default::Any
    unique::Bool
    index::Bool
    max_length::Union{Nothing,Int}
    references::Union{Nothing,String}
    of::Union{Nothing,Symbol}        # arrays: element kind; foreign keys: :uuid when the target's pk is a UUID
end
Column(name, kind::Symbol; null = false, default = nothing, unique = false, index = false,
       max_length = nothing, references = nothing, of = nothing) =
    Column(string(name), kind, null, default, unique, index && !unique, max_length,
           references === nothing ? nothing : string(references), of === nothing ? nothing : Symbol(of))

Base.:(==)(a::Column, b::Column) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Column))
Base.hash(c::Column, h::UInt) = hash(c.name, hash(c.kind, h))
"Same definition apart from the name (used to detect renames)."
same_definition(a::Column, b::Column) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Column) if f !== :name)
"A copy of `c` with some attributes changed: `with_column(c; name=\"new\")`."
function with_column(c::Column; name = c.name, kw...)
    attrs = merge((null = c.null, default = c.default, unique = c.unique, index = c.index,
                   max_length = c.max_length, references = c.references, of = c.of), NamedTuple(kw))
    Column(name, c.kind; attrs...)
end

"""
    Index(fields...; name=nothing, unique=false, method=:btree)
    GinIndex(fields...; name=nothing)

An index for `Meta(indexes=[...])`. `method=:gin` (`GinIndex`) is a PostgreSQL GIN index,
for JSON, array and full-text columns; other databases skip it.
"""
struct Index
    columns::Vector{String}
    name::Union{Nothing,String}
    unique::Bool
    method::Symbol
end
Index(cols...; name = nothing, unique = false, method = :btree) =
    Index(String[string(c) for c in (length(cols) == 1 && cols[1] isa AbstractVector ? cols[1] : cols)],
          name === nothing ? nothing : string(name), unique, Symbol(method))
GinIndex(cols...; name = nothing) = Index(cols...; name = name, method = :gin)
Base.:(==)(a::Index, b::Index) = a.columns == b.columns && a.name == b.name && a.unique == b.unique && a.method == b.method
Base.hash(i::Index, h::UInt) = hash(i.name, h)

"A table in a migration snapshot."
mutable struct Table
    name::String
    app::String
    model::String
    columns::Vector{Column}
    unique_together::Vector{Vector{String}}     # column names; each set gets a unique index
    parent::Union{Nothing,String}               # multi-table inheritance: `id` references this table
    pk::Symbol                                  # :auto (integer identity) or :uuid
    indexes::Vector{Index}                      # Meta(indexes=...), with names filled in
end
Table(name, app, model, columns, unique_together = Vector{String}[]; parent = nothing, pk = :auto, indexes = Index[]) =
    Table(name, app, model, columns, unique_together, parent === nothing ? nothing : string(parent), Symbol(pk), collect(Index, indexes))
Base.copy(t::Table) = Table(t.name, t.app, t.model, copy(t.columns), [copy(u) for u in t.unique_together],
                            t.parent, t.pk, copy(t.indexes))
normalize_unique(sets) = sort([collect(String, string.(u)) for u in sets])
function getcolumn(t::Table, name)
    i = findfirst(c -> c.name == name, t.columns)
    i === nothing && error("table '$(t.name)' has no column '$name' in the migration state")
    t.columns[i]
end
hascolumn(t::Table, name) = any(c -> c.name == name, t.columns)

"A full schema snapshot: table name => `Table`."
const SchemaState = Dict{String,Table}
copy_state(s::SchemaState) = SchemaState(k => copy(v) for (k, v) in s)

schema_kind(kind::Symbol) = kind in STRING_KINDS ? :string : kind

"The snapshot `Column` for a model field."
function column_state(f::Field)
    d = f.default isa NoDefault || f.default isa Function || f.default isa Type ? nothing : f.default
    d !== nothing && f.kind in (:json, :array, :intrange, :daterange, :datetimerange, :uuid) && (d = nothing)  # set by Julia, not the DB
    ref = f.kind === :fk ? modelmeta(related_model(f)).table : nothing
    of = f.kind === :array ? f.related : f.kind === :fk && pk_kind(related_model(f)) === :uuid ? :uuid : nothing
    Column(column(f), schema_kind(f.kind); null = f.null, default = d, unique = f.unique,
           index = f.db_index, max_length = schema_kind(f.kind) in (:string, :citext) || (f.kind === :array && f.related === :string) ? f.max_length : nothing,
           references = ref, of = of)
end

"The snapshot `Table` for a model."
function table_state(T::Type)
    m = modelmeta(T)
    col(n) = (f = findfield(m, Symbol(n)); f === nothing ? error("$(m.name): Meta names unknown field '$n'") : column(f))
    P = table_parent(T)
    root = isempty(ancestors(T)) ? T : last(ancestors(T))
    idx = Index[]
    for ix in get(m.extra, :indexes, Index[])
        cols = [col(c) for c in ix.columns]
        push!(idx, Index(cols, something(ix.name, constraint_name(m.table, cols..., ix.method === :gin ? "gin" : "idx")),
                         ix.unique, ix.method))
    end
    Table(m.table, m.app, m.name, [column_state(f) for f in m.fields],
          normalize_unique([[col(n) for n in u] for u in m.unique_together]);
          parent = P === nothing ? nothing : modelmeta(P).table, pk = get(modelmeta(root).extra, :pk, :auto),
          indexes = sort(idx; by = i -> i.name))
end

"The schema the given models describe."
models_state(models = all_models()) = SchemaState(modelmeta(T).table => table_state(T) for T in models if !modelmeta(T).proxy)

# --- DDL --------------------------------------------------------------------------------------

lit(b::DatabaseBackend, v) = v === nothing ? "NULL" : sql_literal(b, adapt_param(b, v))

"Value given to existing rows when a NOT NULL column without a default is added."
function backfill_value(c::Column)
    c.default !== nothing && return c.default
    c.null && return nothing
    c.kind === :string ? "" : c.kind in (:int,) ? 0 : c.kind === :float ? 0.0 : c.kind === :bool ? false :
    c.kind === :datetime ? DateTime(1970) : c.kind === :date ? Date(1970) : nothing
end

"The SQL type of a snapshot column."
function column_type_for(b::DatabaseBackend, c::Column)
    c.kind === :array && return array_column_type(b, c.of, c.max_length)
    c.kind === :fk && c.of === :uuid && return column_type(b, :uuid, nothing)
    column_type(b, c.kind === :string ? :char : c.kind, c.max_length)
end

function column_sql(b::DatabaseBackend, c::Column; adding = false, inline_fk = inline_foreign_keys(b))
    s = quote_name(b, c.name) * " " * column_type_for(b, c)
    c.null || (s *= " NOT NULL")
    d = c.default
    (d === nothing && adding && !c.null) && (d = backfill_value(c))
    d === nothing || (s *= " DEFAULT " * lit(b, d))
    (c.references !== nothing && inline_fk) && (s *= " REFERENCES $(quote_name(b, c.references)) ($(quote_name(b, "id")))")
    s
end

index_name(table, c::Column) = constraint_name(table, c.name, c.unique ? "uniq" : "idx")

function index_sql(b::DatabaseBackend, table, c::Column; if_not_exists = true)
    (c.unique || c.index) || return String[]
    ine = if_not_exists ? "IF NOT EXISTS " : ""
    ["CREATE $(c.unique ? "UNIQUE " : "")INDEX $ine$(quote_name(b, index_name(table, c))) ON $(quote_name(b, table)) ($(quote_name(b, c.name)))"]
end

unique_together_name(table, cols) = constraint_name(table, cols..., "uniq")
unique_together_sql(b::DatabaseBackend, table, cols; if_not_exists = false) =
    "CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(quote_name(b, unique_together_name(table, cols))) ON " *
    "$(quote_name(b, table)) (" * join([quote_name(b, c) for c in cols], ", ") * ")"
drop_unique_together_sql(b::DatabaseBackend, table, cols) = "DROP INDEX IF EXISTS " * quote_name(b, unique_together_name(table, cols))

"Statements that change a table's unique-together indexes from `old` to `new` sets."
function alter_unique_together_sql(b::DatabaseBackend, table, old, new)
    stmts = [drop_unique_together_sql(b, table, u) for u in old if !(u in new)]
    append!(stmts, [unique_together_sql(b, table, u) for u in new if !(u in old)])
    stmts
end

drop_index_sql(b::DatabaseBackend, table, c::Column) =
    ["DROP INDEX IF EXISTS " * quote_name(b, constraint_name(table, c.name, s)) for s in ("uniq", "idx")]

fk_sql(b::DatabaseBackend, table, c::Column) =
    (c.references === nothing || inline_foreign_keys(b)) ? String[] : [foreign_key_sql(b, table, c.name, c.references)]

"""
    create_table_sql(b, t; if_not_exists=false) -> (statements, foreign_keys)

DDL for a table and its indexes. Foreign keys that the backend adds separately are
returned on their own so they can run once every table exists.
"""
function create_table_sql(b::DatabaseBackend, t::Table; if_not_exists = false)
    ine = if_not_exists ? "IF NOT EXISTS " : ""
    stmts = unique(String[s for c in t.columns for s in column_prereqs(b, c.kind)])
    push!(stmts, "CREATE TABLE $ine$(quote_name(b, t.name)) ($(pk_column_sql(b, t))" *
                 join(", " .* [column_sql(b, c) for c in t.columns]) * ")")
    for c in t.columns
        append!(stmts, index_sql(b, t.name, c; if_not_exists = if_not_exists))
    end
    for u in t.unique_together
        push!(stmts, unique_together_sql(b, t.name, u; if_not_exists = if_not_exists))
    end
    for ix in t.indexes
        append!(stmts, index_spec_sql(b, t.name, ix; if_not_exists = if_not_exists))
    end
    fks = String[s for c in t.columns for s in fk_sql(b, t.name, c)]
    (t.parent !== nothing && !inline_foreign_keys(b)) && push!(fks, foreign_key_sql(b, t.name, "id", t.parent))
    stmts, fks
end

"The `id` column: an identity, a UUID, or (multi-table child) a copy of the parent's id."
function pk_column_sql(b::DatabaseBackend, t::Table)
    t.parent === nothing && t.pk === :auto && return autoincrement_pk(b)
    s = quote_name(b, "id") * " " * column_type(b, t.pk === :uuid ? :uuid : :int, nothing) * " NOT NULL PRIMARY KEY"
    (t.parent !== nothing && inline_foreign_keys(b)) && (s *= " REFERENCES $(quote_name(b, t.parent)) ($(quote_name(b, "id")))")
    s
end

"CREATE INDEX for a `Meta(indexes=...)` entry (nothing where the method isn't supported)."
function index_spec_sql(b::DatabaseBackend, table, ix::Index; if_not_exists = false)
    supports_index_method(b, ix.method) || return String[]
    using_ = ix.method === :btree ? "" : " USING $(ix.method)"
    ["CREATE $(ix.unique ? "UNIQUE " : "")INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(quote_name(b, ix.name)) ON " *
     "$(quote_name(b, table))$using_ (" * join([quote_name(b, c) for c in ix.columns], ", ") * ")"]
end
drop_index_spec_sql(b::DatabaseBackend, ix::Index) =
    supports_index_method(b, ix.method) ? ["DROP INDEX IF EXISTS " * quote_name(b, ix.name)] : String[]


drop_table_sql(b::DatabaseBackend, t::Table) = ["DROP TABLE $(quote_name(b, t.name))"]

function rename_table_sql(b::DatabaseBackend, old::Table, new::Table)
    stmts = ["ALTER TABLE $(quote_name(b, old.name)) RENAME TO $(quote_name(b, new.name))"]
    for c in old.columns
        (c.unique || c.index) || continue
        append!(stmts, drop_index_sql(b, old.name, c))
        append!(stmts, index_sql(b, new.name, c))
    end
    for u in old.unique_together
        push!(stmts, drop_unique_together_sql(b, old.name, u))
        push!(stmts, unique_together_sql(b, new.name, u))
    end
    stmts
end

function add_column_sql(b::DatabaseBackend, t::Table, c::Column, deferred::Vector{String})
    stmts = vcat(column_prereqs(b, c.kind), ["ALTER TABLE $(quote_name(b, t.name)) ADD COLUMN " * column_sql(b, c; adding = true)])
    # The backfill default only exists for the existing rows; drop it where the database allows.
    if can_alter_table(b) && c.default === nothing && !c.null && backfill_value(c) !== nothing
        push!(stmts, "ALTER TABLE $(quote_name(b, t.name)) ALTER COLUMN $(quote_name(b, c.name)) DROP DEFAULT")
    end
    append!(stmts, index_sql(b, t.name, c; if_not_exists = false))
    append!(deferred, fk_sql(b, t.name, c))
    stmts
end

function drop_column_sql(b::DatabaseBackend, old::Table, new::Table, name)
    can_alter_table(b) || return remake_table_sql(b, old, new)
    # Dropping a column also drops its indexes and foreign key constraints.
    ["ALTER TABLE $(quote_name(b, old.name)) DROP COLUMN $(quote_name(b, name))"]
end

function rename_column_sql(b::DatabaseBackend, old::Table, new::Table, oldname, newname)
    c0, c1 = getcolumn(old, oldname), getcolumn(new, newname)
    stmts = ["ALTER TABLE $(quote_name(b, old.name)) RENAME COLUMN $(quote_name(b, oldname)) TO $(quote_name(b, newname))"]
    if c0.unique || c0.index
        append!(stmts, drop_index_sql(b, old.name, c0))
        append!(stmts, index_sql(b, new.name, c1))
    end
    append!(stmts, alter_unique_together_sql(b, new.name, old.unique_together, new.unique_together))
    stmts
end

function alter_column_sql(b::DatabaseBackend, old::Table, new::Table, name, deferred::Vector{String})
    can_alter_table(b) || return remake_table_sql(b, old, new)
    c0, c1 = getcolumn(old, name), getcolumn(new, name)
    t, col = quote_name(b, new.name), quote_name(b, name)
    stmts = String[]
    if c0.references != c1.references
        for fk in foreign_key_names(b, new.name, name)
            push!(stmts, "ALTER TABLE $t DROP CONSTRAINT $(quote_name(b, fk))")
        end
    end
    (c0.unique, c0.index) != (c1.unique, c1.index) && append!(stmts, drop_index_sql(b, old.name, c0))
    ty0, ty1 = column_type_for(b, c0), column_type_for(b, c1)
    ty0 != ty1 && push!(stmts, alter_column_type_sql(b, new.name, name, ty1))
    if !isequal(c0.default, c1.default)
        push!(stmts, "ALTER TABLE $t ALTER COLUMN $col " * (c1.default === nothing ? "DROP DEFAULT" : "SET DEFAULT " * lit(b, c1.default)))
    end
    if c0.null && !c1.null
        bf = backfill_value(c1)
        bf === nothing || push!(stmts, "UPDATE $t SET $col = $(lit(b, bf)) WHERE $col IS NULL")
        push!(stmts, "ALTER TABLE $t ALTER COLUMN $col SET NOT NULL")
    elseif !c0.null && c1.null
        push!(stmts, "ALTER TABLE $t ALTER COLUMN $col DROP NOT NULL")
    end
    (c0.unique, c0.index) != (c1.unique, c1.index) && append!(stmts, index_sql(b, new.name, c1; if_not_exists = false))
    (c0.references != c1.references) && append!(deferred, fk_sql(b, new.name, c1))
    stmts
end

"""
Rebuild a table with a new definition: create `new__<table>`, copy the rows across,
drop the old table and rename. Used where `ALTER TABLE` can't make the change (SQLite).
Columns are matched by name; new columns get their default or backfill value.
"""
function remake_table_sql(b::DatabaseBackend, old::Table, new::Table)
    tmp = Table("new__" * new.name, new.app, new.model, new.columns; parent = new.parent, pk = new.pk)   # indexes come after the rename
    q(s) = quote_name(b, s)
    cols, exprs = [q("id")], [q("id")]
    for c in new.columns
        push!(cols, q(c.name))
        if hascolumn(old, c.name)
            bf = c.null ? nothing : backfill_value(c)
            push!(exprs, bf === nothing ? q(c.name) : "COALESCE($(q(c.name)), $(lit(b, bf)))")
        else
            push!(exprs, lit(b, c.null ? c.default : backfill_value(c)))
        end
    end
    create = only(filter(x -> startswith(x, "CREATE TABLE"), first(create_table_sql(b, tmp))))
    stmts = [create,
             "INSERT INTO $(q(tmp.name)) ($(join(cols, ", "))) SELECT $(join(exprs, ", ")) FROM $(q(old.name))",
             "DROP TABLE $(q(old.name))",
             "ALTER TABLE $(q(tmp.name)) RENAME TO $(q(new.name))"]
    for c in new.columns
        append!(stmts, index_sql(b, new.name, c; if_not_exists = false))
    end
    for u in new.unique_together
        push!(stmts, unique_together_sql(b, new.name, u))
    end
    for ix in new.indexes
        append!(stmts, index_spec_sql(b, new.name, ix))
    end
    stmts
end

# --- sync mode (no migration files) -------------------------------------------------------------

"""
    sync_models!(models; verbose=true)

Create missing tables, columns and indexes for `models` without migration files. Nothing
is dropped or altered. This is what `migrate()` does for apps that have no migrations.
"""
function sync_models!(models; verbose = true)
    log(msg) = verbose && println(msg)
    b = backend()
    changed = false
    atomic() do
        fks = String[]
        for T in models
            modelmeta(T).proxy && continue
            t = table_state(T)
            if !table_exists(b, t.name)
                stmts, f = create_table_sql(b, t; if_not_exists = true)
                foreach(execute, stmts)
                append!(fks, f)
                log("  Creating table $(t.name)... OK")
                changed = true
            else
                cols = Set(table_columns(b, t.name))
                for c in t.columns
                    c.name in cols && continue
                    execute("ALTER TABLE $(quote_name(b, t.name)) ADD COLUMN " * column_sql(b, c; adding = true))
                    append!(fks, fk_sql(b, t.name, c))
                    log("  Adding column $(t.name).$(c.name)... OK")
                    changed = true
                end
                for c in setdiff(cols, Set(vcat(["id"], [c.name for c in t.columns])))
                    log("  Note: column $(t.name).$c is no longer used by $(t.model) (not dropped)")
                end
                for c in t.columns
                    foreach(execute, index_sql(b, t.name, c))
                end
                for u in t.unique_together
                    execute(unique_together_sql(b, t.name, u; if_not_exists = true))
                end
            end
        end
        foreach(execute, fks)
    end
    changed
end

"The full schema SQL for all registered models (like `sqlmigrate` for the whole project)."
function schema_sql(models = all_models())
    b = backend()
    out, fks = String[], String[]
    for T in models
        modelmeta(T).proxy && continue
        stmts, f = create_table_sql(b, table_state(T); if_not_exists = true)
        append!(out, stmts)
        append!(fks, f)
    end
    join(vcat(out, fks) .* ";", "\n")
end
