# MySQL / MariaDB backend --------------------------------------------------------------------------
#
#     using MySQL                     # loads the driver (ext/JuangoMySQLExt.jl); Pkg.add("MySQL") first
#     configure!(DATABASE = "mysql://user:password@localhost:3306/mydb")
#
# Each connection sets sql_mode to ANSI_QUOTES, PIPES_AS_CONCAT, NO_BACKSLASH_ESCAPES and
# STRICT_TRANS_TABLES, so the standard SQL Juango writes ("double-quoted" names, ||, LIKE ...
# ESCAPE '\') means the same as elsewhere. Things that still differ:
#
# * String comparisons follow the column collation, which is case-insensitive by default:
#   `exact` ignores case (as in Django on MySQL). `contains`/`startswith`/`endswith` are
#   case-sensitive (LIKE BINARY).
# * DDL is not transactional: a migration that fails halfway leaves the finished steps applied.
# * Arrays and ranges are stored as JSON; full-text search falls back to word matching.
# Tested with MariaDB 11; MySQL 8 should work but `DROP INDEX IF EXISTS` is MariaDB-only.

struct MySQLBackend <: DatabaseBackend
    url::String
end
vendor(::MySQLBackend) = "MySQL"

function mysql_params(url)
    m = match(r"^(?:mysql|mariadb)://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?]+)?(?::(\d+))?(?:/([^?]*))?"i, url)
    m === nothing && throw(ImproperlyConfigured("can't parse MySQL URL '$url'"))
    dec(s) = s === nothing ? nothing : HTTP.URIs.unescapeuri(s)
    (user = something(dec(m[1]), "root"), password = something(dec(m[2]), ""), host = something(m[3], "127.0.0.1"),
     port = m[4] === nothing ? 3306 : parse(Int, m[4]), db = something(dec(m[5]), ""))
end

# Implemented by the MySQL package extension.
function mysql_connect end
function mysql_close end
function mysql_exec end       # (conn, sql, params) -> (rows, affected, last_insert_id)

function open_connection(b::MySQLBackend)
    isempty(methods(mysql_connect)) &&
        throw(ImproperlyConfigured("the MySQL backend needs MySQL.jl: Pkg.add(\"MySQL\") and `using MySQL` next to `using Juango`."))
    mysql_connect(mysql_params(b.url))
end
close_connection(::MySQLBackend, conn) = mysql_close(conn)
supports_pooling(::MySQLBackend) = true
connection_usable(::MySQLBackend, conn) = mysql_usable(conn)
ping(::MySQLBackend, conn) = mysql_ping(conn)
function mysql_usable end
function mysql_ping end
driver_rows(::MySQLBackend, conn, sql, params) = mysql_exec(conn, sql, params)[1]
driver_rowcount(::MySQLBackend, conn, sql, params) = mysql_exec(conn, sql, params)[2]
driver_insert_id(::MySQLBackend, conn, sql, params) = Int(mysql_exec(conn, sql, params)[3])

quote_name(::MySQLBackend, s) = "`" * replace(string(s), "`" => "``") * "`"
adapt_param(::MySQLBackend, x::Bool) = Int(x)

function column_type(::MySQLBackend, kind::Symbol, max_length)
    kind in (:int, :fk) && return "BIGINT"
    kind === :bool && return "BOOLEAN"
    kind === :float && return "DOUBLE"
    kind === :datetime && return "DATETIME(6)"
    kind === :date && return "DATE"
    kind in (:json, :array, :intrange, :daterange, :datetimerange) && return "JSON"
    kind === :uuid && return "CHAR(36)"
    kind === :citext && return "VARCHAR($(something(max_length, 255)))"
    max_length === nothing ? "LONGTEXT" : "VARCHAR($max_length)"
end
array_column_type(::MySQLBackend, of, max_length) = "JSON"
autoincrement_pk(b::MySQLBackend) = quote_name(b, "id") * " BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY"
"Type names CAST accepts."
cast_type(b::MySQLBackend, kind::Symbol) = kind in (:int, :fk) ? "SIGNED" : kind === :float ? "DOUBLE" :
    kind === :date ? "DATE" : kind === :datetime ? "DATETIME(6)" : "CHAR"
length_function(::MySQLBackend) = "CHAR_LENGTH"
random_function(::MySQLBackend) = "RAND()"
supports_index_method(::MySQLBackend, m::Symbol) = m === :btree
supports_full_text(::MySQLBackend) = false

insert_sql(b::MySQLBackend, table, cols::Vector{String}) =
    isempty(cols) ? "INSERT INTO $table () VALUES ()" : invoke(insert_sql, Tuple{DatabaseBackend,Any,Vector{String}}, b, table, cols)

function limit_offset_sql(::MySQLBackend, limit, offset)
    (limit === nothing && offset == 0) && return ""
    " LIMIT $(something(limit, "18446744073709551615")) OFFSET $offset"    # MySQL can't OFFSET without LIMIT
end

"MySQL refuses `IN (SELECT ... FROM same_table)` in UPDATE/DELETE and `LIMIT` in IN-subqueries; a derived table avoids both."
in_subquery(::MySQLBackend, sql) = "SELECT * FROM ($sql) AS juango_in"

foreign_key_sql(b::MySQLBackend, table, col, reftable) =
    "ALTER TABLE $(quote_name(b, table)) ADD CONSTRAINT $(quote_name(b, constraint_name(table, col, "fk", reftable, "id"))) " *
    "FOREIGN KEY ($(quote_name(b, col))) REFERENCES $(quote_name(b, reftable)) ($(quote_name(b, "id")))"

lookup_sql(b::MySQLBackend, ::Val{:contains}, col, v) = ("$col LIKE BINARY ? ESCAPE '\\'", Any["%" * escape_like(string(v)) * "%"])
lookup_sql(b::MySQLBackend, ::Val{:startswith}, col, v) = ("$col LIKE BINARY ? ESCAPE '\\'", Any[escape_like(string(v)) * "%"])
lookup_sql(b::MySQLBackend, ::Val{:endswith}, col, v) = ("$col LIKE BINARY ? ESCAPE '\\'", Any["%" * escape_like(string(v))])

table_exists(::MySQLBackend, table) =
    !isempty(execute("SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", [table]))
table_columns(::MySQLBackend, table) =
    [String(r[:column_name]) for r in execute("SELECT column_name AS column_name FROM information_schema.columns " *
                                              "WHERE table_schema = DATABASE() AND table_name = ? ORDER BY ordinal_position", [table])]
foreign_key_names(::MySQLBackend, table, col) =
    [String(r[:n]) for r in execute("SELECT constraint_name AS n FROM information_schema.key_column_usage WHERE table_schema = DATABASE() " *
                                    "AND table_name = ? AND column_name = ? AND referenced_table_name IS NOT NULL", [table, col])]

register_backend!("mysql", MySQLBackend)
register_backend!("mariadb", MySQLBackend)
