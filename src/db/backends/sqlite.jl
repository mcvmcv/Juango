# SQLite backend ---------------------------------------------------------------------------------

"""
    SQLiteBackend(path)

The default backend. `path` is a file or `\":memory:\"`. Selected by any
`settings.DATABASE` string without a `scheme://` prefix, or by `sqlite:///path`.
"""
struct SQLiteBackend <: DatabaseBackend
    path::String
end

vendor(::SQLiteBackend) = "SQLite"

function open_connection(b::SQLiteBackend)
    db = b.path == ":memory:" ? SQLite.DB() : SQLite.DB(b.path)
    if b.path != ":memory:"
        SQLite.execute(db, "PRAGMA journal_mode=WAL")
    end
    SQLite.execute(db, "PRAGMA foreign_keys=OFF")   # cascades are done by the ORM (on_delete)
    db
end

close_connection(::SQLiteBackend, db) = DBInterface.close!(db)

function sqlite_run(db, sql, params, collect_rows::Bool)
    stmt = DBInterface.prepare(db, sql)
    rows = Dict{Symbol,Any}[]
    try
        q = DBInterface.execute(stmt, params)
        if collect_rows
            for r in q
                d = Dict{Symbol,Any}()
                for n in propertynames(r)
                    v = getproperty(r, n)
                    d[n] = v === missing ? nothing : v
                end
                push!(rows, d)
            end
        end
    finally
        DBInterface.close!(stmt)
    end
    rows
end

driver_rows(::SQLiteBackend, db, sql, params) = sqlite_run(db, sql, params, true)
driver_rowcount(::SQLiteBackend, db, sql, params) =
    (sqlite_run(db, sql, params, false); Int(SQLite.C.sqlite3_changes(db.handle)))
driver_insert_id(::SQLiteBackend, db, sql, params) =
    (sqlite_run(db, sql, params, false); Int(SQLite.last_insert_rowid(db)))

function translate_error(::SQLiteBackend, e)
    e isa SQLite.SQLiteException || return e
    m = e.msg
    occursin(r"UNIQUE constraint failed|NOT NULL constraint failed|FOREIGN KEY constraint failed|CHECK constraint failed", m) ?
        IntegrityError(m) : e
end

# SQLite has no native bool/date types: store 0/1 and ISO-8601 text.
adapt_param(::SQLiteBackend, x::Bool) = Int(x)
adapt_param(::SQLiteBackend, x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS.sss")
adapt_param(::SQLiteBackend, x::Date) = string(x)

function column_type(::SQLiteBackend, kind::Symbol, max_length)
    (kind in INT_KINDS || kind in (:bool, :fk, :duration)) && return "INTEGER"
    kind === :float && return "REAL"
    kind === :citext && return "TEXT COLLATE NOCASE"
    kind === :decimal && return "DECIMAL"      # NUMERIC affinity: compares as numbers
    "TEXT"
end

encode_duration(::SQLiteBackend, us::Integer) = us
duration_param_sql(::SQLiteBackend) = "?"

autoincrement_pk(b::SQLiteBackend, int = :bigint) = quote_name(b, "id") * " INTEGER PRIMARY KEY AUTOINCREMENT"

sql_literal(::SQLiteBackend, p::Bool) = p ? "1" : "0"
inline_foreign_keys(::SQLiteBackend) = true   # SQLite can't add constraints to an existing table
can_alter_table(::SQLiteBackend) = false      # no ALTER COLUMN; migrations rebuild the table

function limit_offset_sql(::SQLiteBackend, limit, offset)
    (limit === nothing && offset == 0) && return ""
    " LIMIT $(something(limit, -1)) OFFSET $offset"     # SQLite needs LIMIT before OFFSET
end

# LIKE is case-insensitive for ASCII in SQLite, so case-sensitive lookups use instr/substr.
lookup_sql(::SQLiteBackend, ::Val{:contains}, col, v) = ("instr($col, ?) > 0", Any[string(v)])
lookup_sql(::SQLiteBackend, ::Val{:startswith}, col, v) = ("substr($col, 1, ?) = ?", Any[length(string(v)), string(v)])
function lookup_sql(b::SQLiteBackend, ::Val{:endswith}, col, v)
    s = string(v)
    isempty(s) ? (sql_true(b), Any[]) : ("substr($col, -?) = ?", Any[length(s), s])
end
function date_part_sql(::SQLiteBackend, part, col, v)
    fmt = Dict(:year => "%Y", :month => "%m", :day => "%d")[part]
    ("CAST(strftime('$fmt', $col) AS INTEGER) = ?", Any[Int(v)])
end

extract_sql(::SQLiteBackend, part::Symbol, expr) =
    "CAST(strftime('$(Dict(:year => "%Y", :month => "%m", :day => "%d")[part])', $expr) AS INTEGER)"

supports_index_method(::SQLiteBackend, m::Symbol) = m === :btree

table_exists(::SQLiteBackend, table) =
    !isempty(execute("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [table]))
table_columns(b::SQLiteBackend, table) =
    [String(r[:name]) for r in execute("PRAGMA table_info($(quote_name(b, table)))")]

# SQLAlchemy-style URLs: sqlite:///relative.db, sqlite:////absolute/path.db, sqlite:///:memory:
function sqlite_from_url(url)
    m = match(r"^sqlite:///(.+)$"i, url)
    m === nothing && throw(ImproperlyConfigured("SQLite URLs look like sqlite:///relative.db or sqlite:////absolute/path.db, got '$url'"))
    SQLiteBackend(String(m.captures[1]))
end
register_backend!("sqlite", sqlite_from_url)

supports_insert_returning(::SQLiteBackend) = true            # SQLite 3.35+
