# Database connection (SQLite) -------------------------------------------------------------

const DB_LOCK = ReentrantLock()
const DB_CONN = Ref{Any}(nothing)
const DB_PATH = Ref{String}("")
const ATOMIC_DEPTH = Ref(0)

function close_connection!()
    lock(DB_LOCK) do
        DB_CONN[] === nothing || try
            DBInterface.close!(DB_CONN[])
        catch
        end
        DB_CONN[] = nothing
        DB_PATH[] = ""
    end
end
push!(SETTINGS_CHANGED_HOOKS, () -> (DB_CONN[] !== nothing && DB_PATH[] != string(settings.DATABASE)) && close_connection!())

"The shared SQLite connection for `settings.DATABASE` (`\":memory:\"` for an in-memory DB)."
function connection()
    lock(DB_LOCK) do
        p = string(settings.DATABASE)
        if DB_CONN[] === nothing || DB_PATH[] != p
            db = p == ":memory:" ? SQLite.DB() : SQLite.DB(p)
            p == ":memory:" || SQLite.execute(db, "PRAGMA journal_mode=WAL")
            DB_CONN[] = db
            DB_PATH[] = p
        end
        DB_CONN[]
    end
end

dbparam(x::Nothing) = missing
dbparam(x::Bool) = Int(x)
dbparam(x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS.sss")
dbparam(x::Date) = string(x)
dbparam(x::SafeString) = x.s
dbparam(x::Symbol) = string(x)
dbparam(x::AbstractString) = String(x)
dbparam(x) = x

"""
    execute(sql, params=[]) -> Vector{Dict{Symbol,Any}}

Run raw SQL with `?` placeholders. SQL `NULL` comes back as `nothing`.
"""
function execute(sql::AbstractString, params = Any[])
    lock(DB_LOCK) do
        settings.SQL_DEBUG && @info "SQL" sql params
        stmt = DBInterface.prepare(connection(), sql)
        rows = Dict{Symbol,Any}[]
        try
            q = DBInterface.execute(stmt, Any[dbparam(p) for p in params])
            for r in q
                d = Dict{Symbol,Any}()
                for n in propertynames(r)
                    v = getproperty(r, n)
                    d[n] = v === missing ? nothing : v
                end
                push!(rows, d)
            end
        finally
            DBInterface.close!(stmt)
        end
        rows
    end
end

"Execute an INSERT and return the new row id."
function execute_insert(sql::AbstractString, params = Any[])
    lock(DB_LOCK) do
        execute(sql, params)
        SQLite.last_insert_rowid(connection())
    end
end

"Execute a statement and return the number of rows changed."
function execute_changes(sql::AbstractString, params = Any[])
    lock(DB_LOCK) do
        execute(sql, params)
        execute("SELECT changes() AS n")[1][:n]
    end
end

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
        depth = ATOMIC_DEPTH[]
        sp = "juango_sp_$(depth)"
        execute(depth == 0 ? "BEGIN" : "SAVEPOINT $sp")
        ATOMIC_DEPTH[] = depth + 1
        try
            r = f()
            ATOMIC_DEPTH[] = depth
            execute(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT $sp")
            r
        catch
            ATOMIC_DEPTH[] = depth
            execute(depth == 0 ? "ROLLBACK" : "ROLLBACK TO SAVEPOINT $sp")
            depth == 0 || execute("RELEASE SAVEPOINT $sp")
            rethrow()
        end
    end
end

qname(s) = "\"" * replace(string(s), "\"" => "\"\"") * "\""
