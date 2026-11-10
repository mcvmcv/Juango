# Driver for Juango's PostgreSQL backend. Loaded automatically by `using LibPQ`.
module JuangoLibPQExt

import Juango
import LibPQ

function Juango.pg_connect(url::String)
    conn = LibPQ.Connection(url)
    # Silence NOTICEs such as "relation already exists, skipping" from CREATE ... IF NOT EXISTS.
    LibPQ.execute(conn, "SET client_min_messages TO warning")
    conn
end

Juango.pg_close(conn) = close(conn)

# numeric (from SUM/AVG/EXTRACT) arrives as text so we don't need Decimals: whole numbers
# become Int (or BigInt), everything else Float64.
function parse_numeric(s::AbstractString)
    occursin(r"^-?\d+$", s) ? something(tryparse(Int, s), parse(BigInt, s)) : parse(Float64, s)
end
const TYPE_MAP = Dict{Symbol,Type}(:numeric => String, :jsonb => String, :json => String, :uuid => String,
                                   :int8range => String, :daterange => String, :tsrange => String)

# Row count for INSERT/UPDATE/DELETE; 0 for commands without one (BEGIN, CREATE, SET...).
affected_rows(res) = try
    LibPQ.num_affected_rows(res)
catch e
    e isa ArgumentError || rethrow()
    0
end

function Juango.pg_exec(conn, sql::String, params::Vector{Any})
    res = LibPQ.execute(conn, sql, params; throw_error = false, type_map = TYPE_MAP, not_null = false)
    try
        st = LibPQ.status(res)
        if st in (LibPQ.libpq_c.PGRES_FATAL_ERROR, LibPQ.libpq_c.PGRES_BAD_RESPONSE)
            err = LibPQ.Errors.PQResultError(res)
            err isa LibPQ.Errors.PQResultError{LibPQ.Errors.C23} && throw(Juango.IntegrityError(strip(err.msg)))
            throw(err)
        end
        names = Symbol.(LibPQ.column_names(res))
        numeric = [o == LibPQ.oid(:numeric) for o in LibPQ.column_oids(res)]
        rows = Vector{Dict{Symbol,Any}}(undef, LibPQ.num_rows(res))
        for i in eachindex(rows)
            d = Dict{Symbol,Any}()
            for (j, n) in enumerate(names)
                v = res[i, j]
                d[n] = v === missing ? nothing : numeric[j] ? parse_numeric(v) : v
            end
            rows[i] = d
        end
        affected = st == LibPQ.libpq_c.PGRES_COMMAND_OK ? affected_rows(res) : length(rows)
        return rows, affected
    finally
        close(res)
    end
end

function __init__()
    # pg_exec raises its own errors. Without this, LibPQ would also log a warning for every
    # failed statement (for example each IntegrityError a form validation catches).
    LibPQ.Memento.setlevel!(LibPQ.LOGGER, "error")
end

end
