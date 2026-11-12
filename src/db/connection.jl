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
adapt_param(::DatabaseBackend, x::Decimal) = string(x)
adapt_param(::DatabaseBackend, x) = x

"Column type for an ORM field kind (`:int`, `:bool`, `:fk`, `:float`, `:datetime`, `:date`, `:char`, `:text`, ...)."
function column_type(::DatabaseBackend, kind::Symbol, max_length)
    kind in (:int, :fk) && return "BIGINT"
    kind === :bool && return "BOOLEAN"
    kind === :float && return "DOUBLE PRECISION"
    kind === :datetime && return settings.USE_TZ ? "TIMESTAMP WITH TIME ZONE" : "TIMESTAMP"
    kind === :date && return "DATE"
    kind === :json && return "JSONB"
    kind === :hstore && return "HSTORE"
    kind === :uuid && return "UUID"
    kind === :citext && return "CITEXT"
    kind === :intrange && return "INT8RANGE"
    kind === :daterange && return "DATERANGE"
    kind === :datetimerange && return "TSRANGE"
    kind === :decimal && return "NUMERIC"
    max_length === nothing ? "TEXT" : "VARCHAR($max_length)"
end
"Column type of a decimal (NUMERIC(p, s) by default)."
decimal_column_type(::DatabaseBackend, max_digits, decimal_places) = "NUMERIC($max_digits, $decimal_places)"

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

"Whether `INSERT ... RETURNING` works (bulk_create uses it to learn the new ids)."
supports_insert_returning(::DatabaseBackend) = false

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

"Wrap a subquery used as `x IN (subquery)` (MySQL needs a derived table)."
in_subquery(::DatabaseBackend, sql) = sql
"Type name for CAST(x AS ...)."
cast_type(b::DatabaseBackend, kind::Symbol) = column_type(b, kind, nothing)
"SQL function for the length of text in characters."
length_function(::DatabaseBackend) = "LENGTH"
"A column inside CREATE INDEX (MySQL needs a prefix length for text)."
index_column(b::DatabaseBackend, c) = quote_name(b, c.name)
"DROP INDEX statement."
drop_index_stmt(b::DatabaseBackend, table, name) = "DROP INDEX IF EXISTS " * quote_name(b, name)

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
    s = String(sql)
    occursin('?', s) || return s
    # The characters that matter (quotes, comments, ?) are ASCII, so scan bytes and copy runs.
    cu = codeunits(s)
    len = length(cu)
    io = IOBuffer(; sizehint = len + 16)
    n = 0
    start = 1                       # first byte not yet copied
    i = 1
    @inbounds while i <= len
        c = cu[i]
        if c == UInt8('\'') || c == UInt8('"') || c == UInt8('`')
            j = i + 1                # skip to the closing quote (a doubled quote re-enters next round)
            while j <= len && cu[j] != c
                j += 1
            end
            i = j + 1
        elseif c == UInt8('-') && i < len && cu[i+1] == UInt8('-')
            j = i + 2
            while j <= len && cu[j] != UInt8('\n')
                j += 1
            end
            i = j + 1
        elseif c == UInt8('/') && i < len && cu[i+1] == UInt8('*')
            j = i + 2
            while j < len && !(cu[j] == UInt8('*') && cu[j+1] == UInt8('/'))
                j += 1
            end
            i = j + 2
        elseif c == UInt8('?')
            write(io, view(cu, start:i-1))
            n += 1
            print(io, placeholder(b, n))
            i += 1
            start = i
        else
            i += 1
        end
    end
    start <= len && write(io, view(cu, start:len))
    String(take!(io))
end

# --- connection state ---------------------------------------------------------------------
#
# Backends that support pooling (PostgreSQL, MySQL) keep a pool of connections: a statement
# borrows one and gives it back, and a transaction keeps one for its whole duration, so tasks
# run queries in parallel and one task's transaction is invisible to the others until it
# commits. SQLite keeps a single connection behind a lock (one writer at a time anyway).

const DB_LOCK = ReentrantLock()

"Whether the backend uses a connection pool (otherwise one shared connection)."
supports_pooling(::DatabaseBackend) = false
"Cheap local check that a connection is still open (no round trip)."
connection_usable(::DatabaseBackend, conn) = true
"A round trip to check a connection works (before reusing one that sat idle)."
ping(::DatabaseBackend, conn) = true

mutable struct PooledConnection
    conn::Any
    created::Float64
    last_used::Float64
end

mutable struct ConnectionPool
    backend::DatabaseBackend
    idle::Vector{PooledConnection}
    total::Int
    lock::ReentrantLock
end

struct PoolTimeout <: Exception
    msg::String
end
Base.showerror(io::IO, e::PoolTimeout) = print(io, "PoolTimeout: ", e.msg)

# --- databases by alias -------------------------------------------------------------------------
#
# `DATABASES = Dict("default" => ..., "replica" => ...)` names several databases; without it,
# `DATABASE` is the "default" one. Each alias has its own backend, connection (or pool) and
# transaction depth. Queries go to the task's current alias: `using_db("replica") do ... end`,
# a queryset's `using_db(qs, "replica")`, the database an object was loaded from, or the
# DATABASE_ROUTERS' choice, else "default".

"A callback registered with `on_commit`, at transaction depth `level`."
struct CommitHook
    level::Int
    f::Any
    robust::Bool
end

"Connection state of one database alias."
mutable struct DatabaseState
    alias::String
    setting::Any
    backend::DatabaseBackend
    conn::Any                                  # the single connection of non-pooled backends
    depth::Int                                 # transaction depth of non-pooled backends
    pool::Union{Nothing,ConnectionPool}
    hooks::Vector{CommitHook}                  # on_commit callbacks of non-pooled backends
end
DatabaseState(alias, setting, backend, conn, depth, pool) =
    DatabaseState(alias, setting, backend, conn, depth, pool, CommitHook[])
const DB_STATES = Dict{String,DatabaseState}()

"The configured databases: alias => setting (`DATABASES`, with `DATABASE` as \"default\")."
function database_settings()
    out = Dict{String,Any}()
    d = get(settings, :DATABASES, nothing)
    d === nothing || for (k, v) in pairs(d)
        out[string(k)] = v
    end
    haskey(out, "default") || (out["default"] = settings.DATABASE)
    out
end

"The task's current database alias."
current_alias() = get(task_local_storage(), :juango_db_alias, "default")::String
"Whether a `using_db(alias) do ... end` block chose the database for this task."
db_pinned() = haskey(task_local_storage(), :juango_db_alias)

"Run `f()` with `alias` as the current database (`nothing` leaves it as it is)."
function with_db(f, alias)
    alias === nothing && return f()
    a = string(alias)
    a == current_alias() && db_pinned() && return f()
    task_local_storage(f, :juango_db_alias, a)
end

"""
    using_db(alias) do ... end

Run the block against database `alias` (a key of `DATABASES`): every query, save and
transaction in it, unless a queryset or object says otherwise.
"""
using_db(f::Function, alias) = with_db(f, string(alias))

# --- routers ---------------------------------------------------------------------------------

"""
Database routers, listed in `DATABASE_ROUTERS`, decide where queries go. A router is any
value; define methods of these functions for its type, returning an alias, or `nothing` to
leave the decision to the next router (and finally to "default"):

    struct PrimaryReplica end
    Juango.db_for_read(::PrimaryReplica, ::Type) = "replica"
    Juango.db_for_write(::PrimaryReplica, ::Type) = "default"
    Juango.allow_relation(::PrimaryReplica, a, b) = true
    Juango.allow_migrate(::PrimaryReplica, db, app_label; model = nothing) = db == "default"

    configure!(DATABASES = Dict("default" => "postgresql://...", "replica" => "postgresql://..."),
               DATABASE_ROUTERS = [PrimaryReplica()])
"""
db_for_read(router, model) = nothing
"See `db_for_read`."
db_for_write(router, model) = nothing
"Whether objects `a` and `b` may be related (`nothing`: no opinion). See `db_for_read`."
allow_relation(router, a, b) = nothing
"Whether migrations of `app_label` (or `model`) run on database `db` (`nothing`: no opinion). See `db_for_read`."
allow_migrate(router, db, app_label; model = nothing) = nothing

routers() = get(settings, :DATABASE_ROUTERS, Any[])
function ask_routers(f, args...; kw...)
    for r in routers()
        a = f(r, args...; kw...)
        a === nothing || return a
    end
    nothing
end
route_read(T) = string(something(ask_routers(db_for_read, T), "default"))
route_write(T) = string(something(ask_routers(db_for_write, T), "default"))
migrate_allowed(db, app; model = nothing) = something(ask_routers(allow_migrate, db, app; model = model), true)

"""
The database for an operation on model `T` when nothing more specific says: the enclosing
`using_db` block, else the routers. `nothing` means "stay on the current database".
"""
routed_db(T, write::Bool) = db_pinned() || isempty(routers()) ? nothing : write ? route_write(T) : route_read(T)

"The state of database `alias`, set up (no connection opened) on first use or after its setting changed."
function db_state(alias::AbstractString = current_alias())
    lock(DB_LOCK) do
        confs = database_settings()
        haskey(confs, alias) || throw(ImproperlyConfigured("no database '$alias' in DATABASES (have: $(join(sort(collect(keys(confs))), ", ")))"))
        s = confs[alias]
        st = get(DB_STATES, alias, nothing)
        if st === nothing || !isequal(st.setting, s)
            st === nothing || close_state!(st)
            st = DB_STATES[alias] = DatabaseState(alias, s, backend_from_setting(s), nothing, 0, nothing)
        end
        st
    end
end

"The backend of the current database (no connection is opened)."
backend() = db_state().backend

"Per-task database state for pooled backends: the connection a transaction holds, and its depth."
mutable struct TaskDB
    conn::Union{Nothing,PooledConnection}
    depth::Int
    hooks::Vector{CommitHook}
end
TaskDB(conn, depth) = TaskDB(conn, depth, CommitHook[])
function task_db(alias::AbstractString = current_alias())
    d = get!(() -> Dict{String,TaskDB}(), task_local_storage(), :juango_db)::Dict{String,TaskDB}
    get!(() -> TaskDB(nothing, 0), d, alias)
end

function pool(b::DatabaseBackend)
    st = db_state()
    lock(DB_LOCK) do
        (st.pool === nothing || st.pool.backend !== b) && (st.pool = ConnectionPool(b, PooledConnection[], 0, ReentrantLock()))
        st.pool
    end
end

expired(pc::PooledConnection) = (age = settings.CONN_MAX_AGE; age !== nothing && time() - pc.last_used > age)
discard(p::ConnectionPool, pc::PooledConnection) =
    (try close_connection(p.backend, pc.conn) catch end; lock(() -> (p.total -= 1), p.lock); nothing)

"Borrow a connection, waiting up to DATABASE_POOL_TIMEOUT seconds for one to be free."
function checkout(b::DatabaseBackend)
    p = pool(b)
    deadline = time() + settings.DATABASE_POOL_TIMEOUT
    while true
        pc = nothing
        create = false
        lock(p.lock) do
            while !isempty(p.idle) && p.total > settings.DATABASE_POOL_SIZE     # the pool was made smaller
                try close_connection(b, popfirst!(p.idle).conn) catch end
                p.total -= 1
            end
            while pc === nothing && !isempty(p.idle)
                c = pop!(p.idle)
                if expired(c)
                    try close_connection(b, c.conn) catch end
                    p.total -= 1
                else
                    pc = c
                end
            end
            if pc === nothing && p.total < settings.DATABASE_POOL_SIZE
                p.total += 1
                create = true
            end
        end
        if pc !== nothing
            # health check: a connection idle for a while may have been dropped by the server
            healthy = connection_usable(b, pc.conn) &&
                      (!settings.CONN_HEALTH_CHECKS || time() - pc.last_used < 1 || ping(b, pc.conn))
            healthy && return pc
            discard(p, pc)                     # broken (server restarted?): drop it and try again
            continue
        end
        if create
            try
                return PooledConnection(open_connection(b), time(), time())
            catch
                lock(() -> (p.total -= 1), p.lock)
                rethrow()
            end
        end
        time() > deadline && throw(PoolTimeout("no database connection became free within $(settings.DATABASE_POOL_TIMEOUT) seconds " *
                                               "(DATABASE_POOL_SIZE = $(settings.DATABASE_POOL_SIZE)); is a transaction being held open?"))
        sleep(0.005)
    end
end

"Return a borrowed connection (closing it if CONN_MAX_AGE is 0 or it no longer works)."
function checkin(b::DatabaseBackend, pc::PooledConnection)
    p = pool(b)
    pc.last_used = time()
    if settings.CONN_MAX_AGE == 0 || p.total > settings.DATABASE_POOL_SIZE || !connection_usable(b, pc.conn)
        discard(p, pc)
    else
        lock(() -> push!(p.idle, pc), p.lock)
    end
    nothing
end

function close_state!(st::DatabaseState)
    if st.conn !== nothing
        try close_connection(st.backend, st.conn) catch end
    end
    st.conn = nothing
    st.depth = 0
    if st.pool !== nothing
        p = st.pool
        lock(p.lock) do
            foreach(pc -> (try close_connection(p.backend, pc.conn) catch end), p.idle)
            p.total -= length(p.idle)
            empty!(p.idle)
        end
        st.pool = nothing
    end
end

"Close every connection, of every database (a new one opens on the next query)."
close_connection!() = lock(() -> foreach(close_state!, values(DB_STATES)), DB_LOCK)
"Close the connections of one database alias."
close_connection!(alias::AbstractString) = lock(() -> (st = get(DB_STATES, alias, nothing); st === nothing || close_state!(st)), DB_LOCK)

push!(SETTINGS_CHANGED_HOOKS, function ()
    lock(DB_LOCK) do
        confs = database_settings()
        for (a, st) in collect(DB_STATES)
            isequal(get(confs, a, nothing), st.setting) && continue
            close_state!(st)
            delete!(DB_STATES, a)
        end
    end
end)

"Connection pool statistics of the current database: `(size, in_use, idle)`."
function pool_status()
    st = get(DB_STATES, current_alias(), nothing)
    p = st === nothing ? nothing : st.pool
    p === nothing ? (size = settings.DATABASE_POOL_SIZE, in_use = 0, idle = 0) :
        lock(() -> (size = settings.DATABASE_POOL_SIZE, in_use = p.total - length(p.idle), idle = length(p.idle)), p.lock)
end

"The shared driver connection of a non-pooled backend (SQLite), opened on first use."
function connection()
    st = db_state()
    lock(DB_LOCK) do
        supports_pooling(st.backend) && error("connection() is for single-connection backends; pooled backends lend connections per statement")
        st.conn === nothing && (st.conn = open_connection(st.backend))
        st.conn
    end
end

const QUERY_COUNT = Threads.Atomic{Int}(0)

"""
    count_queries(f) -> (result, n)

Run `f()` and count the SQL statements it executed (useful for catching N+1 queries in tests).
"""
function count_queries(f)
    n0 = QUERY_COUNT[]
    r = f()
    r, QUERY_COUNT[] - n0
end

function run_on(@nospecialize(f), b, conn, sql, @nospecialize(params))
    Threads.atomic_add!(QUERY_COUNT, 1)
    settings.SQL_DEBUG && @info "SQL" sql params
    ps = Any[adapt_param(b, p) for p in params]
    logged = log_enabled("juango.db.backends", 10)
    t0 = logged ? time() : 0.0
    try
        r = f(b, conn, rewrite_placeholders(b, sql), ps)
        logged && log!("juango.db.backends", :debug, "($(round((time() - t0) * 1000; digits = 3)) ms) $sql; args=$(repr(params))";
                       sql = sql, params = params, duration = time() - t0, alias = current_alias())
        r
    catch e
        e2 = translate_error(b, e)
        e2 === e ? rethrow() : throw(e2)
    end
end

function run_driver(f, sql, params)
    b = backend()
    supports_pooling(b) || return lock(() -> run_on(f, b, connection(), sql, params), DB_LOCK)
    st = task_db()
    st.conn === nothing || return run_on(f, b, st.conn.conn, sql, params)      # inside this task's transaction
    pc = checkout(b)
    try
        run_on(f, b, pc.conn, sql, params)
    finally
        checkin(b, pc)
    end
end

"""
    execute(sql, params=[]) -> Vector{Dict{Symbol,Any}}

Run raw SQL with `?` placeholders (portable across backends). SQL `NULL` comes back
as `nothing`.
"""
execute(sql::AbstractString, params = Any[]) = run_driver(driver_rows, sql, params)

"Whether the current task is inside `atomic()`."
in_atomic() = commit_holder().depth > 0

"Run a statement and return the number of rows changed."
execute_changes(sql::AbstractString, params = Any[]) = run_driver(driver_rowcount, sql, params)

"Run an INSERT built with `insert_sql` and return the new row id."
execute_insert(sql::AbstractString, params = Any[]) = run_driver(driver_insert_id, sql, params)

"""
    atomic(f)

Run `f()` inside a transaction (nested calls use savepoints) on the current database, or on
`db` (an alias of `DATABASES`). Any exception rolls
back the changes and is rethrown. On pooled backends the transaction keeps one
connection for the current task; other tasks don't see its changes until it commits.

    atomic() do
        save!(order); save!(invoice)
    end
"""
function atomic(f; db = nothing)
    db === nothing || return with_db(() -> atomic(f), db)
    st0 = db_state()
    b = st0.backend
    supports_pooling(b) || return lock(DB_LOCK) do
        r = transaction(f, b, st0)
        st0.depth == 0 && run_commit_hooks!(st0)
        r
    end
    st = task_db()
    outer = st.depth == 0
    outer && (st.conn = checkout(b))
    r = try
        transaction(f, b, st)
    finally
        if outer
            pc = st.conn
            st.conn = nothing
            st.depth = 0
            pc === nothing || checkin(b, pc)
        end
    end
    outer && run_commit_hooks!(st)
    r
end

# `h` is the DatabaseState (non-pooled) or TaskDB (pooled) holding the depth and hooks.
function transaction(@nospecialize(f), b, h::Union{DatabaseState,TaskDB})
    depth = h.depth
    sp = "juango_sp_$(depth)"
    execute(depth == 0 ? begin_sql(b) : savepoint_sql(b, sp))
    h.depth = depth + 1
    try
        r = f()
        h.depth = depth
        execute(depth == 0 ? commit_sql(b) : release_savepoint_sql(b, sp))
        r
    catch
        h.depth = depth
        filter!(k -> k.level <= depth, h.hooks)            # callbacks of the rolled-back block
        try
            execute(depth == 0 ? rollback_sql(b) : rollback_savepoint_sql(b, sp))
            depth == 0 || execute(release_savepoint_sql(b, sp))
        catch
        end
        rethrow()
    end
end

commit_holder() = supports_pooling(backend()) ? task_db() : db_state()

function run_commit_hooks!(h)
    isempty(h.hooks) && return nothing
    hooks = copy(h.hooks)
    empty!(h.hooks)
    foreach(run_hook, hooks)
    nothing
end

function run_hook(k::CommitHook)
    k.robust || return k.f()
    try
        k.f()
    catch e
        log!("juango.db.backends", :error, "on_commit callback failed: " * sprint(showerror, e))
    end
end

"""
    on_commit(f; robust = false, db = nothing)

Run `f()` after the current transaction commits, like Django's `transaction.on_commit`:
send mail or enqueue a task only once the data it depends on is saved. If the transaction
(or the savepoint `f` was registered in) rolls back, `f` is dropped. Outside a transaction
`f()` runs at once. With `robust = true` an exception from `f` is logged instead of
propagating (and the remaining callbacks still run).

    atomic() do
        save!(order)
        on_commit(() -> send_mail("Order received", ...))
    end
"""
function on_commit(f; robust::Bool = false, db = nothing)
    db === nothing || return with_db(() -> on_commit(f; robust = robust), db)
    h = commit_holder()
    if h.depth == 0
        robust ? run_hook(CommitHook(0, f, true)) : f()
    else
        push!(h.hooks, CommitHook(h.depth, f, robust))
    end
    nothing
end

"Quote an identifier for the current backend."
qname(s) = quote_name(backend(), s)
"Adapt a value for the current backend."
dbparam(x) = adapt_param(backend(), x)
