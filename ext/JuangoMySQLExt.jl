# Driver for Juango's MySQL/MariaDB backend. Loaded automatically by `using MySQL`.
module JuangoMySQLExt

import Juango
import MySQL
using Dates
const DBI = MySQL.DBInterface

const SQL_MODE = "ANSI_QUOTES,PIPES_AS_CONCAT,NO_BACKSLASH_ESCAPES,STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION"

function Juango.mysql_connect(p)
    # found_rows: UPDATE reports matched rows, not changed ones (save! relies on it)
    conn = DBI.connect(MySQL.Connection, p.host, p.user, p.password; port = p.port,
                       db = isempty(p.db) ? nothing : p.db, found_rows = true)
    DBI.execute(conn, "SET SESSION sql_mode = '$SQL_MODE'")
    DBI.execute(conn, "SET NAMES utf8mb4")
    conn
end
Juango.mysql_close(conn) = DBI.close!(conn)
Juango.mysql_usable(conn) = isopen(conn)
function Juango.mysql_ping(conn)
    isopen(conn) || return false
    try
        DBI.execute(conn, "SELECT 1"); true
    catch
        false
    end
end

# MySQL.jl 2.x returns its own string/bytes/decimal/timestamp types; turn them into plain values.
plain(::Missing) = nothing
plain(v::AbstractString) = String(v)
plain(v::AbstractVector{UInt8}) = String(copy(v))
plain(v::Union{Int8,Int16,Int32,UInt8,UInt16,UInt32}) = Int(v)
function plain(v)
    T = typeof(v)
    s = string(nameof(T))
    s == "Timestamp" && return DateTime(string(v)[1:min(end, 23)])
    s == "DecimalValue" && (t = string(v); return occursin(r"^-?\d+$", t) ? something(tryparse(Int, t), parse(BigInt, t)) : parse(Juango.Decimal, t))
    v
end
plain(v::Date) = v
plain(v::DateTime) = v

function Juango.mysql_exec(conn, sql::String, params::Vector{Any})
    stmt = nothing
    try
        if isempty(params)
            cur = DBI.execute(conn, sql)
        else
            stmt = DBI.prepare(conn, sql)
            cur = DBI.execute(stmt, Any[p === nothing ? missing : p for p in params])
        end
        rows = Dict{Symbol,Any}[]
        names = cur.names
        if names !== nothing && !isempty(names)
            for r in cur
                d = Dict{Symbol,Any}()
                for n in propertynames(r)
                    d[n] = plain(getproperty(r, n))
                end
                push!(rows, d)
            end
        end
        lastid = try
            DBI.lastrowid(cur)
        catch
            0
        end
        return rows, Int(something(cur.rows_affected, 0)), Int(something(lastid, 0))
    catch e
        if e isa MySQL.Protocol.StmtError || hasproperty(e, :sqlstate)
            st = string(getproperty(e, :sqlstate))
            startswith(st, "23") && throw(Juango.IntegrityError(string(getproperty(e, :msg))))
        end
        rethrow()
    finally
        stmt === nothing || DBI.close!(stmt)
    end
end

end
