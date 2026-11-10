# Database layer -------------------------------------------------------------------------------
#
# Everything above this file (the ORM, sessions, auth, admin) talks to the database
# through a `DatabaseBackend`. A backend owns three things:
#
#   1. the driver: opening connections and running statements,
#   2. the SQL dialect: quoting, column types, lookups, LIMIT, inserts that return ids,
#   3. introspection used by `migrate()`.
#
# SQL is written by hand. The ORM builds statements with `?` placeholders. Before a
# statement runs, the backend rewrites them with `placeholder(b, i)`, skipping
# placeholders inside quoted strings and identifiers. Raw `execute(sql, params)` works
# the same way, so `?` is portable across backends.
#
# To add a backend, subtype `DatabaseBackend`, implement the "driver" methods, override
# whatever dialect methods differ from the defaults, and register a URL scheme:
#
#     register_backend!("postgresql", url -> PostgresBackend(url))
#
# After that, `configure!(DATABASE = "postgresql://user@host/db")` selects it.

"Supertype of all database backends. See `src/db.jl` for the interface."
abstract type DatabaseBackend end

"Raised for constraint violations (unique, foreign key, not null) on every backend."
struct IntegrityError <: Exception
    msg::String
end
Base.showerror(io::IO, e::IntegrityError) = print(io, "IntegrityError: ", e.msg)

"Raised when `settings.DATABASE` cannot be mapped to a backend."
struct ImproperlyConfigured <: Exception
    msg::String
end
Base.showerror(io::IO, e::ImproperlyConfigured) = print(io, "ImproperlyConfigured: ", e.msg)

# --- backend registry ---------------------------------------------------------------------

const BACKEND_SCHEMES = Dict{String,Any}()

"""
    register_backend!(scheme, constructor)

Map a URL scheme (`\"postgresql\"`) to a function `url::String -> DatabaseBackend`.
"""
register_backend!(scheme::AbstractString, f) = (BACKEND_SCHEMES[lowercase(scheme)] = f; nothing)

const PLANNED_BACKENDS = Dict(
    "postgres" => "PostgreSQL support is planned (https://github.com/mcvmcv/Juango/issues/2)",
    "postgresql" => "PostgreSQL support is planned (https://github.com/mcvmcv/Juango/issues/2)",
    "mysql" => "MySQL support is planned (https://github.com/mcvmcv/Juango/issues/11)",
)

"""
    backend_from_setting(x) -> DatabaseBackend

Interpret `settings.DATABASE`: a backend instance is used as-is, a string with a
`scheme://` prefix is looked up with `register_backend!`, and any other string is a
SQLite file path (or `\":memory:\"`).
"""
backend_from_setting(b::DatabaseBackend) = b
function backend_from_setting(s::AbstractString)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://", s)
    m === nothing && return SQLiteBackend(String(s))
    scheme = lowercase(m.captures[1])
    f = get(BACKEND_SCHEMES, scheme, nothing)
    if f === nothing
        hint = get(PLANNED_BACKENDS, scheme, "Registered schemes: " * join(sort(collect(keys(BACKEND_SCHEMES))), ", "))
        throw(ImproperlyConfigured("no database backend for '$scheme://'. $hint"))
    end
    f(String(s))
end
backend_from_setting(x) = throw(ImproperlyConfigured("settings.DATABASE must be a path, a URL or a DatabaseBackend, got $(typeof(x))"))

# --- driver interface (every backend implements these) -----------------------------------

"Open and return a new driver connection."
function open_connection end
"Close a driver connection."
function close_connection end
"Run a statement whose SQL already uses this backend's placeholders; return rows as `Vector{Dict{Symbol,Any}}` with `NULL` as `nothing`."
function driver_rows end
"Run a statement and return the number of rows it changed."
function driver_rowcount end
"Run an INSERT (built with `insert_sql`) and return the new primary key."
function driver_insert_id end

"Convert driver exceptions to Juango ones (`IntegrityError`). Return `e` unchanged if unknown."
translate_error(::DatabaseBackend, e) = e

# --- dialect (defaults follow standard SQL; override where a database differs) ------------

"Name for logs and error messages."
vendor(b::DatabaseBackend) = string(nameof(typeof(b)))

"The `i`-th (1-based) parameter placeholder."
placeholder(::DatabaseBackend, i::Int) = "?"

"Quote an identifier."
quote_name(::DatabaseBackend, s) = "\"" * replace(string(s), "\"" => "\"\"") * "\""

"Convert a Julia value to something the driver can bind."
adapt_param(::DatabaseBackend, ::Nothing) = missing
adapt_param(::DatabaseBackend, x::SafeString) = x.s
adapt_param(::DatabaseBackend, x::Symbol) = string(x)
adapt_param(::DatabaseBackend, x::AbstractString) = String(x)
adapt_param(::DatabaseBackend, x::UUID) = string(x)
adapt_param(::DatabaseBackend, x) = x

"Column type for an ORM field kind (`:int`, `:bool`, `:fk`, `:float`, `:datetime`, `:date`, `:char`, `:text`, ...)."
function column_type(::DatabaseBackend, kind::Symbol, max_length)
    kind in (:int, :fk) && return "BIGINT"
    kind === :bool && return "BOOLEAN"
    kind === :float && return "DOUBLE PRECISION"
    kind === :datetime && return "TIMESTAMP"
    kind === :date && return "DATE"
    kind === :json && return "JSONB"
    kind === :uuid && return "UUID"
    kind === :citext && return "CITEXT"
    kind === :intrange && return "INT8RANGE"
    kind === :daterange && return "DATERANGE"
    kind === :datetimerange && return "TSRANGE"
    max_length === nothing ? "TEXT" : "VARCHAR($max_length)"
end

"Column type of an array of `of` values."
array_column_type(b::DatabaseBackend, of, max_length) = column_type(b, of === :string ? :char : of, max_length) * "[]"

"Statements a column needs before it can be created (e.g. `CREATE EXTENSION citext`)."
column_prereqs(::DatabaseBackend, kind::Symbol) = String[]

"Definition of the auto-incrementing `id` primary key column."
autoincrement_pk(b::DatabaseBackend) = quote_name(b, "id") * " BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"

"SQL literal for a value that has already been through `adapt_param` (used in DEFAULT clauses)."
function sql_literal(::DatabaseBackend, p)
    (p === missing || p === nothing) && return "NULL"
    p isa Bool && return p ? "TRUE" : "FALSE"
    p isa Number && return string(p)
    "'" * replace(string(p), "'" => "''") * "'"
end

"An INSERT statement; `cols` are already quoted. An empty `cols` inserts a row of defaults."
function insert_sql(b::DatabaseBackend, table, cols::Vector{String})
    isempty(cols) && return "INSERT INTO $table DEFAULT VALUES"
    "INSERT INTO $table (" * join(cols, ", ") * ") VALUES (" * join(fill("?", length(cols)), ", ") * ")"
end

"Called after an INSERT with an explicit id, so the id generator moves past it."
sync_sequence(::DatabaseBackend, table) = nothing

"""
Whether foreign keys are declared inside CREATE TABLE (`true`, SQLite) or added afterwards
with `foreign_key_sql` once every table exists (`false`, the default). Adding them afterwards
lets tables reference each other in any order.
"""
inline_foreign_keys(::DatabaseBackend) = false

"ALTER TABLE statement adding a foreign key constraint. Arguments are unquoted names."
function foreign_key_sql(b::DatabaseBackend, table, col, reftable)
    name = constraint_name(table, col, "fk", reftable, "id")
    "ALTER TABLE $(quote_name(b, table)) ADD CONSTRAINT $(quote_name(b, name)) FOREIGN KEY ($(quote_name(b, col))) " *
    "REFERENCES $(quote_name(b, reftable)) ($(quote_name(b, "id"))) DEFERRABLE INITIALLY DEFERRED"
end

"A constraint or index name of at most 63 bytes (Postgres's limit), stable across runs."
function constraint_name(parts...)
    s = join(string.(parts), "_")
    ncodeunits(s) <= 63 && return s
    h = bytes2hex(SHA.sha256(s))[1:8]
    first(s, 54) * "_" * h
end

"""
Whether `ALTER TABLE` can drop and alter columns. When `false` (SQLite), migrations rebuild
the table instead (create a copy, move the rows, swap).
"""
can_alter_table(::DatabaseBackend) = true

"Change a column's type."
alter_column_type_sql(b::DatabaseBackend, table, col, ty) =
    "ALTER TABLE $(quote_name(b, table)) ALTER COLUMN $(quote_name(b, col)) TYPE $ty"

"Names of the foreign key constraints on a column (needed to drop them)."
foreign_key_names(::DatabaseBackend, table, col) = String[]

"LIMIT/OFFSET clause (with leading space), or an empty string."
function limit_offset_sql(::DatabaseBackend, limit, offset)
    s = limit === nothing ? "" : " LIMIT $limit"
    offset > 0 && (s *= " OFFSET $offset")
    s
end

"Integer year/month/day of a date expression."
extract_sql(::DatabaseBackend, part::Symbol, expr) = "EXTRACT($(uppercase(string(part))) FROM $expr)"

"Whether the database supports an index method (`:btree`, `:gin`)."
supports_index_method(::DatabaseBackend, m::Symbol) = m in (:btree, :gin)

"Expression for random ordering."
random_function(::DatabaseBackend) = "RANDOM()"

"Always-false and always-true conditions."
sql_false(::DatabaseBackend) = "1 = 0"
sql_true(::DatabaseBackend) = "1 = 1"

"""
    lookup_sql(b, Val(lookup), col, value) -> (sql, params)

SQL for the string and date lookups whose spelling differs between databases:
`iexact contains icontains startswith istartswith endswith iendswith year month day`.
`col` is the qualified, quoted column. The comparison lookups (`exact`, `gt`, `in`, ...)
are standard SQL and are built by the ORM directly.
"""
lookup_sql(b::DatabaseBackend, ::Val{:iexact}, col, v) = ("LOWER($col) = LOWER(?)", Any[string(v)])
lookup_sql(b::DatabaseBackend, ::Val{:contains}, col, v) = ("$col LIKE ? ESCAPE '\\'", Any["%" * escape_like(string(v)) * "%"])
lookup_sql(b::DatabaseBackend, ::Val{:icontains}, col, v) = ("LOWER($col) LIKE ? ESCAPE '\\'", Any["%" * escape_like(lowercase(string(v))) * "%"])
lookup_sql(b::DatabaseBackend, ::Val{:startswith}, col, v) = ("$col LIKE ? ESCAPE '\\'", Any[escape_like(string(v)) * "%"])
lookup_sql(b::DatabaseBackend, ::Val{:istartswith}, col, v) = ("LOWER($col) LIKE ? ESCAPE '\\'", Any[escape_like(lowercase(string(v))) * "%"])
lookup_sql(b::DatabaseBackend, ::Val{:endswith}, col, v) = ("$col LIKE ? ESCAPE '\\'", Any["%" * escape_like(string(v))])
lookup_sql(b::DatabaseBackend, ::Val{:iendswith}, col, v) = ("LOWER($col) LIKE ? ESCAPE '\\'", Any["%" * escape_like(lowercase(string(v)))])
for part in (:year, :month, :day)
    @eval lookup_sql(b::DatabaseBackend, ::Val{$(QuoteNode(part))}, col, v) = date_part_sql(b, $(QuoteNode(part)), col, v)
end
"`year`/`month`/`day` lookups: compare part of a date column with an integer."
date_part_sql(::DatabaseBackend, part, col, v) = ("EXTRACT($(uppercase(string(part))) FROM $col) = ?", Any[Int(v)])

escape_like(s) = replace(s, "\\" => "\\\\", "%" => "\\%", "_" => "\\_")

# transactions
begin_sql(::DatabaseBackend) = "BEGIN"
commit_sql(::DatabaseBackend) = "COMMIT"
rollback_sql(::DatabaseBackend) = "ROLLBACK"
savepoint_sql(b::DatabaseBackend, name) = "SAVEPOINT " * quote_name(b, name)
release_savepoint_sql(b::DatabaseBackend, name) = "RELEASE SAVEPOINT " * quote_name(b, name)
rollback_savepoint_sql(b::DatabaseBackend, name) = "ROLLBACK TO SAVEPOINT " * quote_name(b, name)

# introspection (used by `migrate`)
"Whether a table exists."
function table_exists end
"Column names of an existing table."
function table_columns end

"""
Rewrite `?` placeholders as `placeholder(b, i)`, leaving `?` inside '…' strings,
\"…\" / `…` identifiers, `--` comments and `/* */` comments untouched.
"""
function rewrite_placeholders(b::DatabaseBackend, sql::AbstractString)
    placeholder(b, 1) == "?" && return String(sql)
    io = IOBuffer()
    n = 0
    quote_char = nothing
    chars = collect(sql)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if quote_char !== nothing
            print(io, c)
            c == quote_char && (quote_char = nothing)   # doubled quotes re-enter on the next char
        elseif c in ('\'', '"', '`')
            quote_char = c
            print(io, c)
        elseif c == '-' && i < length(chars) && chars[i+1] == '-'
            j = something(findnext(==('\n'), chars, i), length(chars))
            print(io, String(chars[i:j]))
            i = j
        elseif c == '/' && i < length(chars) && chars[i+1] == '*'
            j = 0
            for k in i+2:length(chars)-1
                chars[k] == '*' && chars[k+1] == '/' && (j = k + 1; break)
            end
            j == 0 && (j = length(chars))
            print(io, String(chars[i:j]))
            i = j
        elseif c == '?'
            n += 1
            print(io, placeholder(b, n))
        else
            print(io, c)
        end
        i += 1
    end
    String(take!(io))
end

# --- connection state ---------------------------------------------------------------------

const DB_LOCK = ReentrantLock()
const DB_BACKEND = Ref{Union{Nothing,DatabaseBackend}}(nothing)
const DB_SETTING = Ref{Any}(nothing)
const DB_CONN = Ref{Any}(nothing)
const ATOMIC_DEPTH = Ref(0)

"The backend selected by `settings.DATABASE` (no connection is opened)."
function backend()
    lock(DB_LOCK) do
        s = settings.DATABASE
        if DB_BACKEND[] === nothing || !isequal(DB_SETTING[], s)
            close_connection!()
            DB_BACKEND[] = backend_from_setting(s)
            DB_SETTING[] = s
        end
        DB_BACKEND[]::DatabaseBackend
    end
end

"Close the current connection (a new one opens on the next query)."
function close_connection!()
    lock(DB_LOCK) do
        if DB_CONN[] !== nothing && DB_BACKEND[] !== nothing
            try
                close_connection(DB_BACKEND[], DB_CONN[])
            catch
            end
        end
        DB_CONN[] = nothing
        ATOMIC_DEPTH[] = 0
    end
end
push!(SETTINGS_CHANGED_HOOKS, () -> (DB_BACKEND[] !== nothing && !isequal(DB_SETTING[], settings.DATABASE)) &&
                                    (close_connection!(); DB_BACKEND[] = nothing))

"The driver connection for the current backend, opened on first use."
function connection()
    lock(DB_LOCK) do
        b = backend()
        DB_CONN[] === nothing && (DB_CONN[] = open_connection(b))
        DB_CONN[]
    end
end

const QUERY_COUNT = Ref(0)

"""
    count_queries(f) -> (result, n)

Run `f()` and count the SQL statements it executed (useful for catching N+1 queries in tests).
"""
function count_queries(f)
    lock(DB_LOCK) do
        n0 = QUERY_COUNT[]
        r = f()
        r, QUERY_COUNT[] - n0
    end
end

function run_driver(f, sql, params)
    lock(DB_LOCK) do
        b = backend()
        conn = connection()
        QUERY_COUNT[] += 1
        settings.SQL_DEBUG && @info "SQL" sql params
        ps = Any[adapt_param(b, p) for p in params]
        try
            f(b, conn, rewrite_placeholders(b, sql), ps)
        catch e
            e2 = translate_error(b, e)
            e2 === e ? rethrow() : throw(e2)
        end
    end
end

"""
    execute(sql, params=[]) -> Vector{Dict{Symbol,Any}}

Run raw SQL with `?` placeholders (portable across backends). SQL `NULL` comes back
as `nothing`.
"""
execute(sql::AbstractString, params = Any[]) = run_driver(driver_rows, sql, params)

"Run a statement and return the number of rows changed."
execute_changes(sql::AbstractString, params = Any[]) = run_driver(driver_rowcount, sql, params)

"Run an INSERT built with `insert_sql` and return the new row id."
execute_insert(sql::AbstractString, params = Any[]) = run_driver(driver_insert_id, sql, params)

"""
    atomic(f)

Run `f()` inside a transaction (nested calls use savepoints). Any exception rolls
back the changes and is rethrown.

    atomic() do
        save!(order); save!(invoice)
    end
"""
function atomic(f)
    lock(DB_LOCK) do
        b = backend()
        depth = ATOMIC_DEPTH[]
        sp = "juango_sp_$(depth)"
        execute(depth == 0 ? begin_sql(b) : savepoint_sql(b, sp))
        ATOMIC_DEPTH[] = depth + 1
        try
            r = f()
            ATOMIC_DEPTH[] = depth
            execute(depth == 0 ? commit_sql(b) : release_savepoint_sql(b, sp))
            r
        catch
            ATOMIC_DEPTH[] = depth
            execute(depth == 0 ? rollback_sql(b) : rollback_savepoint_sql(b, sp))
            depth == 0 || execute(release_savepoint_sql(b, sp))
            rethrow()
        end
    end
end

"Quote an identifier for the current backend."
qname(s) = quote_name(backend(), s)
"Adapt a value for the current backend."
dbparam(x) = adapt_param(backend(), x)
