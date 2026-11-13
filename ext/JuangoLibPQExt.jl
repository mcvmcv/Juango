# Driver for Juango's PostgreSQL backend. Loaded automatically by `using LibPQ`.
module JuangoLibPQExt

import Juango
import LibPQ

function Juango.pg_connect(url::String)
    conn = LibPQ.Connection(url)
    # Silence NOTICEs such as "relation already exists, skipping" from CREATE ... IF NOT EXISTS.
    LibPQ.execute(conn, "SET client_min_messages TO warning")
    LibPQ.execute(conn, "SET TIME ZONE 'UTC'")          # naive timestamps are sent and read as UTC
    LibPQ.execute(conn, "SET intervalstyle = 'iso_8601'")   # intervals read back as P1DT2H (DurationField)
    conn
end

Juango.pg_close(conn) = close(conn)
Juango.pg_usable(conn) = isopen(conn) && LibPQ.status(conn) == LibPQ.libpq_c.CONNECTION_OK
function Juango.pg_ping(conn)
    try
        r = LibPQ.execute(conn, "SELECT 1"; throw_error = false)
        ok = LibPQ.status(r) == LibPQ.libpq_c.PGRES_TUPLES_OK
        close(r)
        ok
    catch
        false
    end
end

# numeric (DecimalField columns, SUM/AVG/EXTRACT) arrives as text: whole numbers become Int (or
# BigInt), everything else an exact Juango.Decimal (expressions that aren't decimal fields are
# turned into Float64 by the ORM).
function parse_numeric(s::AbstractString)
    occursin(r"^-?\d+$", s) ? something(tryparse(Int, s), parse(BigInt, s)) : parse(Juango.Decimal, s)
end
const TYPE_MAP = Dict{Symbol,Type}(:numeric => String, :jsonb => String, :json => String, :uuid => String,
                                   :int8range => String, :daterange => String, :tsrange => String,
                                   :interval => String, :time => String)

# Row count for INSERT/UPDATE/DELETE; 0 for commands without one (BEGIN, CREATE, SET...).
affected_rows(res) = try
    LibPQ.num_affected_rows(res)
catch e
    e isa ArgumentError || rethrow()
    0
end

# Running a query: it's sent without blocking, then for the first millisecond the result is waited
# for with poll(2) (a GC-safe call, so it holds up only this thread, never the garbage collector),
# and after that cooperatively, so other tasks on the thread run while a slow query works.
# LibPQ.async_execute waits cooperatively from the start, which adds about 2 ms of wake-up latency
# to every query (where a simple one takes 0.1 ms).
const C = LibPQ.libpq_c
struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end
const POLLIN = Cshort(1)
const FAST_WAIT_NS = 1_000_000

"Wait up to `ms` milliseconds for the socket to be readable, blocking only this thread."
function poll_readable(fd::Cint, ms::Int)
    pfd = Ref(PollFD(fd, POLLIN, 0))
    @static if VERSION >= v"1.12"
        @ccall gc_safe = true poll(pfd::Ptr{PollFD}, 1::Culong, ms::Cint)::Cint
    else
        @ccall poll(pfd::Ptr{PollFD}, 1::Culong, ms::Cint)::Cint
    end
end

function exec_params(conn::LibPQ.Connection, sql::String, params::Vector{Any})
    strs = LibPQ.string_parameters(params)
    ptrs = LibPQ.parameter_pointers(strs)
    lock(conn) do
        pg = conn.conn
        sent = GC.@preserve strs ptrs sql C.PQsendQueryParams(pg, sql, length(ptrs), C_NULL, ptrs, C_NULL, C_NULL, 0)
        sent == 1 || throw(LibPQ.Errors.PQConnectionError(conn))
        t0 = time_ns()
        watcher = nothing
        try
            while true
                C.PQconsumeInput(pg) == 1 || throw(LibPQ.Errors.PQConnectionError(conn))
                C.PQisBusy(pg) == 0 && break
                if !Sys.iswindows() && time_ns() - t0 < FAST_WAIT_NS
                    poll_readable(C.PQsocket(pg), 1)
                else
                    watcher === nothing && (watcher = LibPQ.FileWatching.FDWatcher(LibPQ.socket(conn), true, false))
                    wait(watcher)
                end
            end
        finally
            watcher === nothing || close(watcher)
        end
        # the last result is the statement's (earlier ones, if any, are dropped)
        ptr = C.PQgetResult(pg)
        while true
            next = C.PQgetResult(pg)
            next == C_NULL && break
            C.PQclear(ptr)
            ptr = next
        end
        ptr == C_NULL && throw(LibPQ.Errors.PQConnectionError(conn))
        LibPQ.Result{false}(ptr, conn; type_map = TYPE_MAP, not_null = false)
    end
end

function read_column!(rows, name::Symbol, res, j::Int, ::Type{P}, parse, numeric::Bool) where {P}
    for i in eachindex(rows)
        rows[i][name] = LibPQ.isnull(res, i, j) ? nothing : numeric ? parse_numeric(parse(P(res, i, j))) : parse(P(res, i, j))
    end
end

function Juango.pg_exec(conn, sql::String, params::Vector{Any})
    res = exec_params(conn, sql, params)
    try
        st = LibPQ.status(res)
        if st in (LibPQ.libpq_c.PGRES_FATAL_ERROR, LibPQ.libpq_c.PGRES_BAD_RESPONSE)
            err = LibPQ.Errors.PQResultError(res)
            err isa LibPQ.Errors.PQResultError{LibPQ.Errors.C23} && throw(Juango.IntegrityError(strip(err.msg)))
            throw(err)
        end
        names = Symbol.(LibPQ.column_names(res))
        rows = Dict{Symbol,Any}[sizehint!(Dict{Symbol,Any}(), length(names)) for _ in 1:LibPQ.num_rows(res)]
        if !isempty(rows)
            oids = LibPQ.column_oids(res)
            for (j, n) in enumerate(names)
                # once per column: the value type and parser (res[i, j] works them out for every cell)
                read_column!(rows, n, res, j, LibPQ.PQValue{oids[j]}, res.column_funcs[j], oids[j] == LibPQ.oid(:numeric))
            end
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
