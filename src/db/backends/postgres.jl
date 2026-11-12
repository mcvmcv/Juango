# PostgreSQL backend -----------------------------------------------------------------------------
#
# The SQL dialect lives here, so `sqlschema` works without a driver. The driver calls come
# from the LibPQ package extension (ext/JuangoLibPQExt.jl), which loads when the project
# does `using LibPQ`. LibPQ is a weak dependency, so SQLite-only projects don't install it.

"""
    PostgresBackend(url)

PostgreSQL through LibPQ.jl. Selected by `settings.DATABASE = \"postgresql://user:pass@host:5432/dbname\"`
(or `postgres://`). The project must also do `using LibPQ`.
"""
struct PostgresBackend <: DatabaseBackend
    url::String
end

vendor(::PostgresBackend) = "PostgreSQL"

# Implemented by the LibPQ extension:
#   pg_connect(url) -> conn
#   pg_close(conn)
#   pg_exec(conn, sql, params) -> (rows::Vector{Dict{Symbol,Any}}, affected::Int)
# pg_exec throws IntegrityError for constraint violations.
function pg_connect end
function pg_close end
function pg_exec end

function open_connection(b::PostgresBackend)
    if isempty(methods(pg_connect))
        throw(ImproperlyConfigured("the PostgreSQL backend needs LibPQ.jl. Add it to your project " *
                                   "(julia --project -e 'using Pkg; Pkg.add(\"LibPQ\")') and put `using LibPQ` " *
                                   "next to `using Juango`."))
    end
    pg_connect(b.url)
end
close_connection(::PostgresBackend, conn) = pg_close(conn)
supports_pooling(::PostgresBackend) = true
connection_usable(::PostgresBackend, conn) = pg_usable(conn)
ping(::PostgresBackend, conn) = pg_ping(conn)
function pg_usable end
function pg_ping end

driver_rows(::PostgresBackend, conn, sql, params) = pg_exec(conn, sql, params)[1]
driver_rowcount(::PostgresBackend, conn, sql, params) = pg_exec(conn, sql, params)[2]
driver_insert_id(::PostgresBackend, conn, sql, params) = Int(only(pg_exec(conn, sql, params)[1])[:id])

placeholder(::PostgresBackend, i::Int) = "\$$i"

insert_sql(b::PostgresBackend, table, cols::Vector{String}) =
    invoke(insert_sql, Tuple{DatabaseBackend,Any,Vector{String}}, b, table, cols) * " RETURNING " * quote_name(b, "id")

# After inserting an explicit id, move the identity sequence past it so later inserts don't collide.
function sync_sequence(b::PostgresBackend, table)
    t = quote_name(b, table)
    execute("SELECT setval(pg_get_serial_sequence(?, 'id'), COALESCE(MAX(\"id\"), 1), MAX(\"id\") IS NOT NULL) FROM $t", [t])
    nothing
end

# Postgres has ILIKE, which can use trigram indexes. LOWER(...) LIKE would also work.
for (L, pre, post) in ((:icontains, "%", "%"), (:istartswith, "", "%"), (:iendswith, "%", ""))
    @eval lookup_sql(::PostgresBackend, ::Val{$(QuoteNode(L))}, col, v) =
        ("$col ILIKE ? ESCAPE '\\'", Any[$pre * escape_like(string(v)) * $post])
end

alter_column_type_sql(b::PostgresBackend, table, col, ty) =
    "ALTER TABLE $(quote_name(b, table)) ALTER COLUMN $(quote_name(b, col)) TYPE $ty USING $(quote_name(b, col))::$ty"

foreign_key_names(::PostgresBackend, table, col) =
    [String(r[:conname]) for r in execute("""
        SELECT con.conname FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        JOIN pg_attribute att ON att.attrelid = rel.oid AND att.attnum = ANY(con.conkey)
        WHERE con.contype = 'f' AND ns.nspname = current_schema() AND rel.relname = ? AND att.attname = ?""", [table, col])]

column_prereqs(::PostgresBackend, kind::Symbol) = kind === :citext ? ["CREATE EXTENSION IF NOT EXISTS citext"] :
    kind === :hstore ? ["CREATE EXTENSION IF NOT EXISTS hstore"] :
    kind === :geometry ? ["CREATE EXTENSION IF NOT EXISTS postgis"] : String[]

table_exists(::PostgresBackend, table) =
    !isempty(execute("SELECT 1 FROM information_schema.tables WHERE table_schema = current_schema() AND table_name = ?", [table]))
table_columns(::PostgresBackend, table) =
    [String(r[:column_name]) for r in execute("SELECT column_name FROM information_schema.columns " *
                                              "WHERE table_schema = current_schema() AND table_name = ? ORDER BY ordinal_position", [table])]

register_backend!("postgresql", PostgresBackend)
register_backend!("postgres", PostgresBackend)

supports_insert_returning(::PostgresBackend) = true
