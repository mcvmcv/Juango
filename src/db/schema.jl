# Schema state and DDL ------------------------------------------------------------------------
#
# A `Table` / `Column` snapshot describes the database schema independently of the live
# model structs. Migrations replay operations on these snapshots ("project state"), the
# autodetector compares them, and the functions below turn them into DDL for the current
# backend. Only schema-relevant attributes are tracked (type, NULL, DB default, unique,
# index, foreign key target). Choices, help text and validators never cause migrations.

"A column default that is SQL rather than a value (`db_default = Now()` → `CURRENT_TIMESTAMP`)."
struct SQLDefault
    sql::String
end
Base.show(io::IO, d::SQLDefault) = print(io, "Juango.SQLDefault(", repr(d.sql), ")")
sql_literal(::DatabaseBackend, d::SQLDefault) = d.sql

"How a generated column is computed: an expression over column names, stored or virtual."
struct GeneratedSpec
    expression::Any
    persisted::Bool
end
Base.:(==)(a::GeneratedSpec, b::GeneratedSpec) = a.persisted == b.persisted && expr_code(a.expression) == expr_code(b.expression)
Base.hash(g::GeneratedSpec, h::UInt) = hash(expr_code(g.expression), hash(g.persisted, h))

"Julia code for an expression in a migration file."
expr_code(e::F) = "F($(repr(e.name)))"
expr_code(e::Value) = "Value($(e.value isa Union{Integer,AbstractFloat,Bool,AbstractString,Nothing} ? repr(e.value) : throw(ArgumentError("generated expressions take numbers, strings and booleans as literals"))))"
expr_code(e::CombinedExpression) = "CombinedExpression($(repr(e.op)), $(expr_code(e.lhs)), $(expr_code(e.rhs)))"
expr_code(e::Func) = "Func($(repr(e.name)), Any[" * join([a isa Expression ? expr_code(a) : repr(a) for a in e.args], ", ") * "])"
expr_code(e) = throw(ArgumentError("generated expressions can use F, literals, + - * /, Lower, Upper, Length, Coalesce and Concat, not $(typeof(e))"))

"An expression over field names rewritten over the columns of `T`."
expr_to_columns(T, e::F) = F(constraint_column(T, e.name))
expr_to_columns(T, e::Value) = e
expr_to_columns(T, e::CombinedExpression) = CombinedExpression(e.op, expr_to_columns(T, e.lhs), expr_to_columns(T, e.rhs))
function expr_to_columns(T, e::Func)
    e.name in (:lower, :upper, :length, :coalesce, :concat) || expr_code(e.name)
    Func(e.name, Any[a isa Expression ? expr_to_columns(T, a) : a for a in e.args])
end
expr_to_columns(T, e) = (expr_code(e); e)

"SQL for a generated column's expression."
gen_sql(b::DatabaseBackend, e::F) = quote_name(b, e.name)
gen_sql(b::DatabaseBackend, e::Value) = lit(b, e.value)
gen_sql(b::DatabaseBackend, e::CombinedExpression) = "(" * gen_sql(b, e.lhs) * " " * e.op * " " * gen_sql(b, e.rhs) * ")"
function gen_sql(b::DatabaseBackend, e::Func)
    a = [gen_sql(b, x) for x in e.args if x isa Expression]
    e.name === :lower && return "LOWER($(a[1]))"
    e.name === :upper && return "UPPER($(a[1]))"
    e.name === :length && return "$(length_function(b))($(a[1]))"
    e.name === :coalesce && return "COALESCE($(join(a, ", ")))"
    "(" * join(["COALESCE(CAST($s AS $(cast_type(b, :text))), '')" for s in a], " || ") * ")"     # concat
end

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
    generated::Union{Nothing,GeneratedSpec}
    comment::Union{Nothing,String}   # db_comment
    max_digits::Union{Nothing,Int}   # decimals: NUMERIC(max_digits, decimal_places)
    decimal_places::Union{Nothing,Int}
end
Column(name, kind::Symbol; null = false, default = nothing, unique = false, index = false,
       max_length = nothing, references = nothing, of = nothing, generated = nothing, comment = nothing,
       max_digits = nothing, decimal_places = nothing) =
    Column(string(name), kind, null, default, unique, index && !unique, max_length,
           references === nothing ? nothing : string(references), of === nothing ? nothing : Symbol(of),
           generated === nothing || generated isa GeneratedSpec ? generated : GeneratedSpec(generated...),
           comment === nothing ? nothing : string(comment), max_digits === nothing ? nothing : Int(max_digits),
           decimal_places === nothing ? nothing : Int(decimal_places))

Base.:(==)(a::Column, b::Column) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Column))
Base.hash(c::Column, h::UInt) = hash(c.name, hash(c.kind, h))
"Same definition apart from the name (used to detect renames)."
same_definition(a::Column, b::Column) = all(isequal(getfield(a, f), getfield(b, f)) for f in fieldnames(Column) if f !== :name)
"A copy of `c` with some attributes changed: `with_column(c; name=\"new\")`."
function with_column(c::Column; name = c.name, kw...)
    attrs = merge((null = c.null, default = c.default, unique = c.unique, index = c.index,
                   max_length = c.max_length, references = c.references, of = c.of, generated = c.generated,
                   comment = c.comment, max_digits = c.max_digits, decimal_places = c.decimal_places), NamedTuple(kw))
    Column(name, c.kind; attrs...)
end

"""
    Index(fields...; name=nothing, unique=false, method=:btree, condition=nothing, include=[], opclasses=[])
    Index(Lower(:email), ...; name)
    GinIndex(fields...; name=nothing)

An index for `Meta(indexes=[...])`. `method=:gin` (`GinIndex`) is a PostgreSQL GIN index,
for JSON, array and full-text columns; other databases skip it.

* `condition = Q(...)`: a partial index over the rows that satisfy it (PostgreSQL and
  SQLite; MySQL/MariaDB skip the index), written like a `CheckConstraint` condition.
* Expressions `Lower(:f)`, `Upper(:f)` or `F(:f)` instead of fields make a functional
  index (needs `name`; not on MySQL/MariaDB).
* `include = [:f, ...]`: non-key columns stored in the index (PostgreSQL `INCLUDE`).
* `opclasses = ["varchar_pattern_ops", ...]`: one operator class per field (PostgreSQL).
"""
struct Index
    columns::Vector{String}
    name::Union{Nothing,String}
    unique::Bool
    method::Symbol
    expressions::Vector{Tuple{String,String}}   # (function, field/column); function "" = the column itself
    condition::Union{Nothing,Q}
    include::Vector{String}
    opclasses::Vector{String}
end
function Index(cols...; name = nothing, unique = false, method = :btree, condition = nothing, include = String[],
               opclasses = String[], expressions = Tuple{String,String}[])
    items = length(cols) == 1 && cols[1] isa AbstractVector ? cols[1] : cols
    columns = String[]
    exprs = Tuple{String,String}[(string(a), string(b)) for (a, b) in expressions]
    for c in items
        if c isa Func
            (c.name in (:lower, :upper) && length(c.args) == 1 && c.args[1] isa F) ||
                throw(ArgumentError("Index expressions can be F(:field), Lower(:field) or Upper(:field)"))
            push!(exprs, (uppercase(string(c.name)), c.args[1].name))
        elseif c isa F
            push!(exprs, ("", c.name))
        else
            push!(columns, string(c))
        end
    end
    isempty(columns) || isempty(exprs) || throw(ArgumentError("Index: give either fields or expressions, not both"))
    isempty(exprs) || name !== nothing || throw(ArgumentError("Index: an index on expressions needs a name"))
    isempty(opclasses) || length(opclasses) == length(columns) ||
        throw(ArgumentError("Index: give one operator class per field"))
    Index(columns, name === nothing ? nothing : string(name), unique, Symbol(method), exprs, condition,
          String[string(c) for c in include], String[string(c) for c in opclasses])
end
GinIndex(cols...; name = nothing, kw...) = Index(cols...; name = name, method = :gin, kw...)
index_key(i::Index) = (i.columns, i.name, i.unique, i.method, i.expressions,
                       i.condition === nothing ? nothing : q_code(i.condition), i.include, i.opclasses)
Base.:(==)(a::Index, b::Index) = index_key(a) == index_key(b)
Base.hash(i::Index, h::UInt) = hash(i.name, h)

"A table in a migration snapshot."
mutable struct Table
    name::String
    app::String
    model::String
    columns::Vector{Column}
    unique_together::Vector{Vector{String}}     # column names; each set gets a unique index
    parent::Union{Nothing,String}               # multi-table inheritance: `id` references this table
    pk::Symbol                                  # :auto (integer identity), :uuid, or :composite (no id column)
    indexes::Vector{Index}                      # Meta(indexes=...), with names filled in
    constraints::Vector{Any}                    # ConstraintSpecs (constraints.jl), by name
    pk_columns::Vector{String}                  # pk = :composite: the primary key's columns
    comment::Union{Nothing,String}              # Meta(db_table_comment = ...)
end
Table(name, app, model, columns, unique_together = Vector{String}[]; parent = nothing, pk = :auto, indexes = Index[], constraints = Any[],
      pk_columns = String[], comment = nothing) =
    Table(name, app, model, columns, unique_together, parent === nothing ? nothing : string(parent), Symbol(pk), collect(Index, indexes),
          sort(collect(Any, constraints); by = c -> c.name), collect(String, pk_columns), comment === nothing ? nothing : string(comment))
Base.copy(t::Table) = Table(t.name, t.app, t.model, copy(t.columns), [copy(u) for u in t.unique_together],
                            t.parent, t.pk, copy(t.indexes), copy(t.constraints), copy(t.pk_columns), t.comment)
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

schema_kind(kind::Symbol) = kind in STRING_KINDS || kind in (:file, :image, :filepath) ? :string : kind

"The table a column references: `\"__user_model__\"` (a `ForeignKey(USER_MODEL)`) is the AUTH_USER_MODEL's."
ref_table(name) = name == "__user_model__" ? modelmeta(get_user_model()).table : name

"`Column.of` for a foreign key: the target's key type when it isn't the default 64-bit integer."
Base.@nospecializeinfer function fk_of(@nospecialize(R))
    k = pk_kind(R)
    k === :uuid ? :uuid : k === :intauto ? :int : k === :smallauto ? :smallint : nothing
end

"The snapshot `Column` for a model field."
function column_state(f::Field)
    d = f.default isa NoDefault || f.default isa Function || f.default isa Type ? nothing : f.default
    d isa Choice && (d = d.value)
    f.db_default === nothing || (d = db_default_value(f.db_default))
    gen = f.generated === nothing ? nothing : GeneratedSpec(expr_to_columns(f.model, f.generated[1]), f.generated[2])
    gen === nothing || (d = nothing)
    d !== nothing && f.kind in (:json, :hstore, :array, :intrange, :daterange, :datetimerange, :uuid) && (d = nothing)  # set by Julia, not the DB
    ref = f.kind !== :fk ? nothing : f.related === :__user_model__ ? "__user_model__" : modelmeta(related_model(f)).table
    f.kind === :fk && is_composite(related_model(f)) &&
        throw(ArgumentError("$(nameof(f.model)).$(f.name): foreign keys to $(nameof(related_model(f))) has a composite primary key; point at it with ForeignObject(...; from_fields = ...)"))
    of = f.kind === :array ? f.related : f.kind === :geometry ? geo_of(f) : f.kind === :fk ? fk_of(related_model(f)) : nothing
    Column(column(f), schema_kind(f.kind); null = f.null, default = d, unique = f.unique,
           index = f.db_index, max_length = schema_kind(f.kind) in (:string, :citext, :binary) || (f.kind === :array && f.related === :string) ? f.max_length : nothing,
           references = ref, of = of, generated = gen, comment = f.db_comment,
           max_digits = f.kind === :decimal ? f.max_digits : nothing, decimal_places = f.kind === :decimal ? f.decimal_places : nothing)
end

"The column default for a field's `db_default`: a value, or SQL for `Now()`."
db_default_value(v::Func) = v.name === :now ? SQLDefault("CURRENT_TIMESTAMP") :
    throw(ArgumentError("db_default takes a value or Now(), not $(v.name)()"))
db_default_value(v::Value) = v.value
db_default_value(v::Expression) = throw(ArgumentError("db_default takes a value or Now()"))
db_default_value(v) = v

"The snapshot `Table` for a model."
Base.@nospecializeinfer function table_state(@nospecialize(T::Type))
    m = modelmeta(T)
    col(n) = (f = findfield(m, Symbol(n)); f === nothing ? error("$(m.name): Meta names unknown field '$n'") : column(f))
    P = table_parent(T)
    root = isempty(ancestors(T)) ? T : last(ancestors(T))
    idx = Index[]
    for ix in get(m.extra, :indexes, Index[])
        cols = [col(c) for c in ix.columns]
        push!(idx, Index(cols, something(ix.name, constraint_name(m.table, cols..., ix.method === :gin ? "gin" : "idx")),
                         ix.unique, ix.method, Tuple{String,String}[(f, col(x)) for (f, x) in ix.expressions],
                         ix.condition === nothing ? nothing : condition_to_columns(T, ix.condition),
                         String[col(c) for c in ix.include], ix.opclasses))
    end
    pk = get(modelmeta(root).extra, :pk, nothing)
    pk isa CompositePrimaryKey || (pk = meta_pk_kind(root))
    pkcols = String[]
    if pk isa CompositePrimaryKey
        (P === nothing && isempty(child_models(T))) ||
            throw(ArgumentError("$(m.name): a model with a composite primary key can't take part in multi-table inheritance"))
        pkcols = [col(n) for n in pk.fields]
        pk = :composite
    end
    Table(m.table, m.app, m.name, [column_state(f) for f in m.fields],
          normalize_unique([[col(n) for n in u] for u in m.unique_together]);
          parent = P === nothing ? nothing : modelmeta(P).table, pk = pk, pk_columns = pkcols,
          indexes = sort(idx; by = i -> i.name), constraints = Any[constraint_spec(T, c) for c in model_constraints(T)],
          comment = get(m.extra, :db_table_comment, nothing))
end

"The schema the given models describe."
models_state(models = all_models()) = SchemaState(modelmeta(T).table => table_state(T) for T in models if !modelmeta(T).proxy && is_managed(T))
"Whether migrations create and change the model's table (`Meta(managed = false)` says no)."
is_managed(T) = get(modelmeta(T).extra, :managed, true) !== false

# --- DDL --------------------------------------------------------------------------------------

lit(b::DatabaseBackend, v) = v === nothing ? "NULL" : sql_literal(b, adapt_param(b, v))

"Value given to existing rows when a NOT NULL column without a default is added."
function backfill_value(c::Column)
    c.default !== nothing && return c.default
    c.null && return nothing
    c.kind === :string ? "" : c.kind in INT_KINDS ? 0 : c.kind === :float ? 0.0 : c.kind === :bool ? false :
    c.kind === :datetime ? DateTime(1970) : c.kind === :date ? Date(1970) : nothing
end

"The SQL type of a snapshot column."
function column_type_for(b::DatabaseBackend, c::Column)
    c.kind === :decimal && return decimal_column_type(b, c.max_digits, c.decimal_places)
    c.kind === :array && return array_column_type(b, c.of, c.max_length)
    c.kind === :geometry && return geometry_column_type(b, c.of)
    c.kind === :fk && c.of !== nothing && return column_type(b, c.of, nothing)        # uuid, int or smallint keys
    column_type(b, c.kind === :string ? :char : c.kind, c.max_length)
end

function column_sql(b::DatabaseBackend, c::Column; adding = false, inline_fk = inline_foreign_keys(b))
    s = quote_name(b, c.name) * " " * column_type_for(b, c)
    if c.generated !== nothing
        c.generated.persisted || !(b isa PostgresBackend) ||
            throw(ArgumentError("PostgreSQL only has stored generated columns: use db_persist = true for '$(c.name)'"))
        return s * " GENERATED ALWAYS AS (" * gen_sql(b, c.generated.expression) * ")" * (c.generated.persisted ? " STORED" : " VIRTUAL")
    end
    c.null || (s *= " NOT NULL")
    d = c.default
    (d === nothing && adding && !c.null) && (d = backfill_value(c))
    d === nothing || (s *= " DEFAULT " * lit(b, d))
    is_positive_kind(c.kind) && positive_check(b) && (s *= " CHECK (" * quote_name(b, c.name) * " >= 0)")
    (c.references !== nothing && inline_fk) && (s *= " REFERENCES $(quote_name(b, ref_table(c.references))) ($(quote_name(b, "id")))")
    (c.comment !== nothing && b isa MySQLBackend) && (s *= " COMMENT " * lit(b, c.comment))
    s
end

"`COMMENT ON COLUMN` (PostgreSQL; MySQL puts comments in the column definition, SQLite has none)."
column_comment_sql(b::DatabaseBackend, table, name, comment) = b isa PostgresBackend ?
    ["COMMENT ON COLUMN $(quote_name(b, table)).$(quote_name(b, name)) IS " * lit(b, comment)] : String[]
"The statement that sets (or with `nothing` removes) a table's comment."
table_comment_sql(b::DatabaseBackend, table, comment) =
    b isa PostgresBackend ? ["COMMENT ON TABLE $(quote_name(b, table)) IS " * lit(b, comment)] :
    b isa MySQLBackend ? ["ALTER TABLE $(quote_name(b, table)) COMMENT = " * lit(b, something(comment, ""))] : String[]

index_name(table, c::Column) = constraint_name(table, c.name, c.unique ? "uniq" : "idx")

function index_sql(b::DatabaseBackend, table, c::Column; if_not_exists = true)
    (c.unique || c.index) || return String[]
    ine = if_not_exists ? "IF NOT EXISTS " : ""
    c.kind === :geometry &&       # spatial index
        return ["CREATE INDEX $ine$(quote_name(b, index_name(table, c))) ON $(quote_name(b, table)) USING GIST ($(quote_name(b, c.name)))"]
    ["CREATE $(c.unique ? "UNIQUE " : "")INDEX $ine$(quote_name(b, index_name(table, c))) ON $(quote_name(b, table)) ($(index_column(b, c)))"]
end

unique_together_name(table, cols) = constraint_name(table, cols..., "uniq")
unique_together_sql(b::DatabaseBackend, table, cols; if_not_exists = false) =
    "CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(quote_name(b, unique_together_name(table, cols))) ON " *
    "$(quote_name(b, table)) (" * join([quote_name(b, c) for c in cols], ", ") * ")"
drop_unique_together_sql(b::DatabaseBackend, table, cols) = drop_index_stmt(b, table, unique_together_name(table, cols))

"Statements that change a table's unique-together indexes from `old` to `new` sets."
function alter_unique_together_sql(b::DatabaseBackend, table, old, new)
    stmts = [drop_unique_together_sql(b, table, u) for u in old if !(u in new)]
    append!(stmts, [unique_together_sql(b, table, u) for u in new if !(u in old)])
    stmts
end

"Give an index a new name: drop and recreate by default (`create` are the statements creating it anew)."
rename_index_stmts(b::DatabaseBackend, table, oldname, newname, create) = vcat([drop_index_stmt(b, table, oldname)], create)

drop_index_sql(b::DatabaseBackend, table, c::Column) =
    [drop_index_stmt(b, table, constraint_name(table, c.name, s)) for s in ("uniq", "idx")]

fk_sql(b::DatabaseBackend, table, c::Column) =
    (c.references === nothing || inline_foreign_keys(b)) ? String[] : [foreign_key_sql(b, table, c.name, ref_table(c.references))]

"""
    create_table_sql(b, t; if_not_exists=false) -> (statements, foreign_keys)

DDL for a table and its indexes. Foreign keys that the backend adds separately are
returned on their own so they can run once every table exists.
"""
function create_table_sql(b::DatabaseBackend, t::Table; if_not_exists = false)
    ine = if_not_exists ? "IF NOT EXISTS " : ""
    stmts = unique(String[s for c in t.columns for s in column_prereqs(b, c.kind)])
    checks = [check_clause(b, c) for c in t.constraints if c.kind === :check]
    defs = [column_sql(b, c) for c in t.columns]
    t.pk === :composite ? push!(defs, "PRIMARY KEY (" * join([quote_name(b, x) for x in t.pk_columns], ", ") * ")") :
                          pushfirst!(defs, pk_column_sql(b, t))
    push!(stmts, "CREATE TABLE $ine$(quote_name(b, t.name)) (" * join(vcat(defs, checks), ", ") * ")" *
                 (t.comment !== nothing && b isa MySQLBackend ? " COMMENT = " * lit(b, t.comment) : ""))
    if b isa PostgresBackend
        t.comment === nothing || append!(stmts, table_comment_sql(b, t.name, t.comment))
        for c in t.columns
            c.comment === nothing || append!(stmts, column_comment_sql(b, t.name, c.name, c.comment))
        end
    end
    for c in t.columns
        append!(stmts, index_sql(b, t.name, c; if_not_exists = if_not_exists))
    end
    for u in t.unique_together
        push!(stmts, unique_together_sql(b, t.name, u; if_not_exists = if_not_exists))
    end
    for ix in t.indexes
        append!(stmts, index_spec_sql(b, t.name, ix; if_not_exists = if_not_exists))
    end
    for c in t.constraints
        c.kind === :unique && append!(stmts, unique_constraint_sql(b, t.name, c; if_not_exists = if_not_exists))
        c.kind === :exclusion && append!(stmts, exclusion_sql(b, t.name, c; if_not_exists = if_not_exists))
    end
    fks = String[s for c in t.columns for s in fk_sql(b, t.name, c)]
    (t.parent !== nothing && !inline_foreign_keys(b)) && push!(fks, foreign_key_sql(b, t.name, "id", t.parent))
    stmts, fks
end

"The `id` column: an identity, a UUID, or (multi-table child) a copy of the parent's id."
function pk_column_sql(b::DatabaseBackend, t::Table)
    t.parent === nothing && is_auto_pk(t.pk) && return autoincrement_pk(b, auto_pk_int(t.pk))
    s = quote_name(b, "id") * " " * column_type(b, t.pk === :uuid ? :uuid : auto_pk_int(t.pk), nothing) * " NOT NULL PRIMARY KEY"
    (t.parent !== nothing && inline_foreign_keys(b)) && (s *= " REFERENCES $(quote_name(b, t.parent)) ($(quote_name(b, "id")))")
    s
end

"""
Statements that give a table's `id` (and the foreign keys pointing at it) the integer size the
schema state `st` has for it.
"""
function alter_pk_sql(b::DatabaseBackend, st, table)
    t = st[table]
    stmts = [alter_column_type_sql(b, table, "id", column_type(b, auto_pk_int(t.pk), nothing))]
    for x in values(st)
        x.parent == table && push!(stmts, alter_column_type_sql(b, x.name, "id", column_type(b, auto_pk_int(t.pk), nothing)))
        for c in x.columns
            c.kind === :fk && c.references !== nothing && ref_table(c.references) == table &&
                push!(stmts, alter_column_type_sql(b, x.name, c.name, column_type_for(b, c)))
        end
    end
    stmts
end

"CREATE INDEX for a `Meta(indexes=...)` entry (nothing where the method isn't supported)."
function index_spec_sql(b::DatabaseBackend, table, ix::Index; if_not_exists = false)
    index_supported(b, ix) || return String[]
    pg = b isa PostgresBackend
    using_ = ix.method === :btree ? "" : " USING $(ix.method)"
    io = IOBuffer()
    print(io, "CREATE ", ix.unique ? "UNIQUE " : "", "INDEX ", if_not_exists ? "IF NOT EXISTS " : "",
          quote_name(b, ix.name), " ON ", quote_name(b, table), using_, " (")
    if isempty(ix.expressions)
        for (i, c) in enumerate(ix.columns)
            i > 1 && print(io, ", ")
            print(io, quote_name(b, c))
            pg && !isempty(ix.opclasses) && print(io, " ", ix.opclasses[i])
        end
    else
        join(io, (f == "" ? quote_name(b, x) : "($f($(quote_name(b, x))))" for (f, x) in ix.expressions), ", ")
    end
    print(io, ")")
    pg && !isempty(ix.include) && print(io, " INCLUDE (", join((quote_name(b, c) for c in ix.include), ", "), ")")
    ix.condition === nothing || print(io, " WHERE ", condition_sql(b, ix.condition))
    [String(take!(io))]
end
"Whether the database builds this index (others skip it, as Django does)."
index_supported(b::DatabaseBackend, ix::Index) = supports_index_method(b, ix.method) &&
    (ix.condition === nothing || supports_partial_indexes(b)) && (isempty(ix.expressions) || supports_expression_indexes(b))
drop_index_spec_sql(b::DatabaseBackend, table, ix::Index) =
    index_supported(b, ix) ? [drop_index_stmt(b, table, ix.name)] : String[]


drop_table_sql(b::DatabaseBackend, t::Table) = ["DROP TABLE $(quote_name(b, t.name))"]

function rename_table_sql(b::DatabaseBackend, old::Table, new::Table)
    stmts = ["ALTER TABLE $(quote_name(b, old.name)) RENAME TO $(quote_name(b, new.name))"]
    # the indexes keep their old names but now live on the renamed table
    for c in old.columns
        (c.unique || c.index) || continue
        append!(stmts, rename_index_stmts(b, new.name, index_name(old.name, c), index_name(new.name, c), index_sql(b, new.name, c)))
    end
    for u in old.unique_together
        append!(stmts, rename_index_stmts(b, new.name, unique_together_name(old.name, u), unique_together_name(new.name, u),
                                          [unique_together_sql(b, new.name, u)]))
    end
    stmts
end

function add_column_sql(b::DatabaseBackend, t::Table, c::Column, deferred::Vector{String})
    if c.generated !== nothing && c.generated.persisted && !can_alter_table(b)     # SQLite: ADD COLUMN can't be STORED
        old = copy(t); filter!(x -> x.name != c.name, old.columns)
        return remake_table_sql(b, old, t)
    end
    stmts = vcat(column_prereqs(b, c.kind), ["ALTER TABLE $(quote_name(b, t.name)) ADD COLUMN " * column_sql(b, c; adding = true)])
    # The backfill default only exists for the existing rows; drop it where the database allows.
    if can_alter_table(b) && c.default === nothing && !c.null && backfill_value(c) !== nothing
        push!(stmts, "ALTER TABLE $(quote_name(b, t.name)) ALTER COLUMN $(quote_name(b, c.name)) DROP DEFAULT")
    end
    append!(stmts, index_sql(b, t.name, c; if_not_exists = false))
    c.comment === nothing || append!(stmts, column_comment_sql(b, t.name, c.name, c.comment))
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
        append!(stmts, rename_index_stmts(b, new.name, index_name(old.name, c0), index_name(new.name, c1), index_sql(b, new.name, c1)))
    end
    append!(stmts, alter_unique_together_sql(b, new.name, old.unique_together, new.unique_together))
    stmts
end

function alter_column_sql(b::DatabaseBackend, old::Table, new::Table, name, deferred::Vector{String})
    c0, c1 = getcolumn(old, name), getcolumn(new, name)
    with_column(c0; comment = c1.comment) == c1 && return column_comment_sql(b, new.name, name, c1.comment)  # only the comment
    can_alter_table(b) || return remake_table_sql(b, old, new)
    t, col = quote_name(b, new.name), quote_name(b, name)
    if c0.generated !== nothing || c1.generated !== nothing        # generated: drop and add it again
        return vcat(["ALTER TABLE $t DROP COLUMN $col"], add_column_sql(b, new, c1, deferred))
    end
    stmts = String[]
    if c0.references != c1.references
        for fk in foreign_key_names(b, new.name, name)
            push!(stmts, "ALTER TABLE $t DROP CONSTRAINT $(quote_name(b, fk))")
        end
    end
    (c0.unique, c0.index) != (c1.unique, c1.index) && append!(stmts, drop_index_sql(b, old.name, c0))
    ty0, ty1 = column_type_for(b, c0), column_type_for(b, c1)
    ty0 != ty1 && push!(stmts, alter_column_type_sql(b, new.name, name, ty1))
    p0, p1 = is_positive_kind(c0.kind), is_positive_kind(c1.kind)
    if positive_check(b) && p0 != p1           # the CHECK (col >= 0) of positive integer fields
        cname = quote_name(b, positive_check_name(new.name, name))
        push!(stmts, p1 ? "ALTER TABLE $t ADD CONSTRAINT $cname CHECK ($col >= 0)" : "ALTER TABLE $t DROP CONSTRAINT IF EXISTS $cname")
    end
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
    c0.comment == c1.comment || append!(stmts, column_comment_sql(b, new.name, name, c1.comment))
    stmts
end

"""
Rebuild a table with a new definition: create `new__<table>`, copy the rows across,
drop the old table and rename. Used where `ALTER TABLE` can't make the change (SQLite).
Columns are matched by name; new columns get their default or backfill value.
"""
function remake_table_sql(b::DatabaseBackend, old::Table, new::Table)
    # indexes come after the rename; CHECK constraints are part of the CREATE TABLE
    tmp = Table("new__" * new.name, new.app, new.model, new.columns; parent = new.parent, pk = new.pk,
                constraints = filter(c -> c.kind === :check, new.constraints), pk_columns = new.pk_columns, comment = new.comment)
    q(s) = quote_name(b, s)
    cols, exprs = new.pk === :composite ? (String[], String[]) : ([q("id")], [q("id")])
    for c in new.columns
        c.generated === nothing || continue          # computed again by the new table
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
    for c in new.constraints
        c.kind === :unique && append!(stmts, unique_constraint_sql(b, new.name, c))
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
            (modelmeta(T).proxy || !is_managed(T)) && continue
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
