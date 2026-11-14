# PostgreSQL driver: libpq (from LibPQ_jll) through ccall ------------------------------------------
#
# Juango talks to libpq directly rather than through LibPQ.jl. LibPQ.jl's dependencies (Intervals,
# Infinity, CEnum, Decimals, ...) invalidate thousands of compiled methods when they load, which
# made a PostgreSQL project's start-up and first requests several times slower than SQLite's, and
# Juango only needs a small part of it: connect, run a statement with text parameters, read the
# text results. Values come back as:
#
#   bool                                  Bool
#   int2, int4, int8, oid                 Int
#   float4, float8                        Float64
#   numeric                               Int (or BigInt) when whole, else Juango.Decimal
#   bytea                                 Vector{UInt8}
#   date / timestamp / timestamptz        Date / DateTime / ZonedDateTime (to the millisecond)
#   int2[], int4[], int8[], float[], numeric[] (one dimension)   Vector{Any}, NULL as nothing
#   everything else (text, json, uuid, time, interval, ranges, other arrays, ...)   String

"A PostgreSQL error that isn't a constraint violation (those raise `IntegrityError`)."
struct DatabaseError <: Exception
    msg::String
    sqlstate::String          # SQLSTATE code ("" when unknown), e.g. "42P01" for an undefined table
end
Base.showerror(io::IO, e::DatabaseError) = print(io, "DatabaseError", isempty(e.sqlstate) ? "" : " ($(e.sqlstate))", ": ", e.msg)

"A libpq connection. Used by one task at a time (the connection pool's), but locked anyway."
mutable struct PGConn
    ptr::Ptr{Cvoid}
    lock::ReentrantLock
end

const PG_CONNECTION_OK = Cint(0)
const PGRES_COMMAND_OK = Cint(1)
const PGRES_TUPLES_OK = Cint(2)
const PGRES_BAD_RESPONSE = Cint(5)
const PGRES_NONFATAL_ERROR = Cint(6)
const PGRES_FATAL_ERROR = Cint(7)
const PG_DIAG_SQLSTATE = Cint('C')

pq_error_message(ptr::Ptr{Cvoid}) = strip(unsafe_string(ccall((:PQerrorMessage, LIBPQ_HANDLE), Cstring, (Ptr{Cvoid},), ptr)))

# Session settings sent with the connection (no extra round trips): ISO dates (the parsers below
# expect them), naive timestamps sent and read as UTC, ISO 8601 intervals (DurationField), and no
# NOTICEs such as "relation already exists, skipping" from CREATE ... IF NOT EXISTS.
const PG_OPTIONS = "-c DateStyle=ISO,YMD -c TimeZone=UTC -c IntervalStyle=iso_8601 -c client_min_messages=warning"

function pg_connect(url::String)
    keys = ["dbname", "client_encoding", "options"]
    vals = [url, "UTF8", PG_OPTIONS]
    # expand_dbname = 1: `dbname` may be a URL or "key=value" string; the other keys add to it
    kptrs = Ptr{UInt8}[pointer.(keys); Ptr{UInt8}(C_NULL)]
    vptrs = Ptr{UInt8}[pointer.(vals); Ptr{UInt8}(C_NULL)]
    ptr = GC.@preserve keys vals kptrs vptrs ccall((:PQconnectdbParams, LIBPQ_HANDLE), Ptr{Cvoid},
                                                   (Ptr{Ptr{UInt8}}, Ptr{Ptr{UInt8}}, Cint), kptrs, vptrs, 1)
    ptr == C_NULL && throw(DatabaseError("out of memory connecting to PostgreSQL", ""))
    if ccall((:PQstatus, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), ptr) != PG_CONNECTION_OK
        msg = pq_error_message(ptr)
        ccall((:PQfinish, LIBPQ_HANDLE), Cvoid, (Ptr{Cvoid},), ptr)
        throw(DatabaseError("could not connect to PostgreSQL: " * msg, "08001"))
    end
    conn = PGConn(ptr, ReentrantLock())
    finalizer(pg_close, conn)
end

function pg_close(conn::PGConn)
    if conn.ptr != C_NULL
        ccall((:PQfinish, LIBPQ_HANDLE), Cvoid, (Ptr{Cvoid},), conn.ptr)
        conn.ptr = C_NULL
    end
    nothing
end
pg_usable(conn::PGConn) = conn.ptr != C_NULL && ccall((:PQstatus, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), conn.ptr) == PG_CONNECTION_OK
function pg_ping(conn::PGConn)
    try
        pg_exec(conn, "SELECT 1", Any[])
        true
    catch
        false
    end
end

# --- parameters: text, as LibPQ.jl sent them -------------------------------------------------------

pg_param(x::AbstractString) = String(x)
pg_param(x) = string(x)
pg_param(v::AbstractVector) = "{" * join((pg_array_element(x) for x in v), ",") * "}"
pg_array_element(x::AbstractString) = "\"" * replace(x, "\\" => "\\\\", "\"" => "\\\"") * "\""
pg_array_element(x) = (x === nothing || x === missing) ? "NULL" : pg_param(x)

# --- running a statement ---------------------------------------------------------------------------
#
# The statement is sent without blocking, then for the first millisecond the result is waited for
# with poll(2) (a GC-safe call, so it holds up only this thread, never the garbage collector), and
# after that cooperatively, so other tasks on the thread run while a slow query works. (Waiting
# cooperatively from the start adds about 2 ms of wake-up latency to every query, where a simple
# one takes 0.1 ms.)

struct PollFD
    fd::Cint
    events::Cshort
    revents::Cshort
end
const POLLIN = Cshort(1)
const PG_FAST_WAIT_NS = 1_000_000

"Wait up to `ms` milliseconds for the socket to be readable, blocking only this thread."
function poll_readable(fd::Cint, ms::Int)
    pfd = Ref(PollFD(fd, POLLIN, 0))
    @static if VERSION >= v"1.12"
        @ccall gc_safe = true poll(pfd::Ptr{PollFD}, 1::Culong, ms::Cint)::Cint
    else
        @ccall poll(pfd::Ptr{PollFD}, 1::Culong, ms::Cint)::Cint
    end
end

connection_lost(conn::PGConn) = DatabaseError("lost the connection to PostgreSQL: " * pq_error_message(conn.ptr), "08006")

"Send the statement and wait for its result (a `PGresult*` the caller must clear)."
function pg_send_and_wait(conn::PGConn, sql::String, params::Vector{Any})
    strs = Union{Nothing,String}[(p === nothing || p === missing) ? nothing : pg_param(p) for p in params]
    ptrs = Ptr{UInt8}[s === nothing ? Ptr{UInt8}(C_NULL) : pointer(s) for s in strs]
    pg = conn.ptr
    pg == C_NULL && throw(DatabaseError("the PostgreSQL connection is closed", "08003"))
    sent = GC.@preserve strs ptrs sql ccall((:PQsendQueryParams, LIBPQ_HANDLE), Cint,
        (Ptr{Cvoid}, Cstring, Cint, Ptr{Cuint}, Ptr{Ptr{UInt8}}, Ptr{Cint}, Ptr{Cint}, Cint),
        pg, sql, length(ptrs), C_NULL, ptrs, C_NULL, C_NULL, 0)
    sent == 1 || throw(connection_lost(conn))
    t0 = time_ns()
    watcher = nothing
    try
        while true
            ccall((:PQconsumeInput, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), pg) == 1 || throw(connection_lost(conn))
            ccall((:PQisBusy, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), pg) == 0 && break
            fd = ccall((:PQsocket, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), pg)
            if !Sys.iswindows() && time_ns() - t0 < PG_FAST_WAIT_NS
                poll_readable(fd, 1)
            else
                watcher === nothing && (watcher = FileWatching.FDWatcher(RawFD(fd), true, false))
                wait(watcher)
            end
        end
    finally
        watcher === nothing || close(watcher)
    end
    # the last result is the statement's (earlier ones, if any, are dropped)
    res = ccall((:PQgetResult, LIBPQ_HANDLE), Ptr{Cvoid}, (Ptr{Cvoid},), pg)
    while true
        next = ccall((:PQgetResult, LIBPQ_HANDLE), Ptr{Cvoid}, (Ptr{Cvoid},), pg)
        next == C_NULL && break
        ccall((:PQclear, LIBPQ_HANDLE), Cvoid, (Ptr{Cvoid},), res)
        res = next
    end
    res == C_NULL && throw(connection_lost(conn))
    res
end

"Run a statement: the rows (column name => value) and the number of rows it affected."
function pg_exec(conn::PGConn, sql::String, params::Vector{Any})
    lock(conn.lock)
    try
        res = pg_send_and_wait(conn, sql, params)
        try
            return pg_read_result(res)
        finally
            ccall((:PQclear, LIBPQ_HANDLE), Cvoid, (Ptr{Cvoid},), res)
        end
    finally
        unlock(conn.lock)
    end
end

function pg_read_result(res::Ptr{Cvoid})
    st = ccall((:PQresultStatus, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), res)
    if st in (PGRES_FATAL_ERROR, PGRES_BAD_RESPONSE, PGRES_NONFATAL_ERROR)
        msg = strip(unsafe_string(ccall((:PQresultErrorMessage, LIBPQ_HANDLE), Cstring, (Ptr{Cvoid},), res)))
        p = ccall((:PQresultErrorField, LIBPQ_HANDLE), Cstring, (Ptr{Cvoid}, Cint), res, PG_DIAG_SQLSTATE)
        code = p == C_NULL ? "" : unsafe_string(p)
        startswith(code, "23") && throw(IntegrityError(msg))
        throw(DatabaseError(msg, code))
    end
    nrows = Int(ccall((:PQntuples, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), res))
    ncols = Int(ccall((:PQnfields, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), res))
    rows = Dict{Symbol,Any}[sizehint!(Dict{Symbol,Any}(), ncols) for _ in 1:nrows]
    for j in 0:ncols-1
        name = Symbol(unsafe_string(ccall((:PQfname, LIBPQ_HANDLE), Cstring, (Ptr{Cvoid}, Cint), res, j)))
        oid = ccall((:PQftype, LIBPQ_HANDLE), Cuint, (Ptr{Cvoid}, Cint), res, j)
        nrows > 0 && read_pg_column!(rows, name, res, j, pg_parser(oid))
    end
    affected = if st == PGRES_COMMAND_OK
        s = unsafe_string(ccall((:PQcmdTuples, LIBPQ_HANDLE), Cstring, (Ptr{Cvoid},), res))
        isempty(s) ? 0 : parse(Int, s)                    # empty for BEGIN, CREATE, SET ...
    else
        nrows
    end
    rows, affected
end

# Once per column: the parser (a function barrier, so each parser's loop is compiled once).
function read_pg_column!(rows::Vector{Dict{Symbol,Any}}, name::Symbol, res::Ptr{Cvoid}, j::Int, parse::F) where {F}
    for i in eachindex(rows)
        r = Cint(i - 1)
        rows[i][name] = if ccall((:PQgetisnull, LIBPQ_HANDLE), Cint, (Ptr{Cvoid}, Cint, Cint), res, r, j) == 1
            nothing
        else
            p = ccall((:PQgetvalue, LIBPQ_HANDLE), Ptr{UInt8}, (Ptr{Cvoid}, Cint, Cint), res, r, j)
            n = Int(ccall((:PQgetlength, LIBPQ_HANDLE), Cint, (Ptr{Cvoid}, Cint, Cint), res, r, j))
            parse(p, n)
        end
    end
end

# --- values ----------------------------------------------------------------------------------------

pg_string(p::Ptr{UInt8}, n::Int) = unsafe_string(p, n)
pg_bool(p::Ptr{UInt8}, n::Int) = unsafe_load(p) == UInt8('t')
pg_int(p::Ptr{UInt8}, n::Int) = parse(Int, unsafe_string(p, n))
pg_float(p::Ptr{UInt8}, n::Int) = parse(Float64, unsafe_string(p, n))
pg_numeric(p::Ptr{UInt8}, n::Int) = parse_pg_numeric(unsafe_string(p, n))
pg_bpchar(p::Ptr{UInt8}, n::Int) = String(rstrip(unsafe_string(p, n), ' '))
pg_date(p::Ptr{UInt8}, n::Int) = parse_pg_date(unsafe_string(p, n))
pg_timestamp(p::Ptr{UInt8}, n::Int) = parse_pg_timestamp(unsafe_string(p, n))
pg_timestamptz(p::Ptr{UInt8}, n::Int) = parse_pg_timestamptz(unsafe_string(p, n))
pg_int_array(p::Ptr{UInt8}, n::Int) = parse_pg_number_array(unsafe_string(p, n), s -> parse(Int, s))
pg_float_array(p::Ptr{UInt8}, n::Int) = parse_pg_number_array(unsafe_string(p, n), s -> parse(Float64, s))
pg_numeric_array(p::Ptr{UInt8}, n::Int) = parse_pg_number_array(unsafe_string(p, n), parse_pg_numeric)
function pg_bytea(p::Ptr{UInt8}, n::Int)
    len = Ref{Csize_t}(0)
    q = ccall((:PQunescapeBytea, LIBPQ_HANDLE), Ptr{UInt8}, (Ptr{UInt8}, Ref{Csize_t}), p, len)
    q == C_NULL && throw(DatabaseError("couldn't decode a bytea value", ""))
    v = copy(unsafe_wrap(Vector{UInt8}, q, len[]))
    ccall((:PQfreemem, LIBPQ_HANDLE), Cvoid, (Ptr{UInt8},), q)
    v
end

"How to read a column of type `oid` (the built-in type OIDs are fixed)."
function pg_parser(oid::Cuint)
    oid == 16 && return pg_bool
    oid in (20, 21, 23, 26) && return pg_int                  # int8 int2 int4 oid
    oid in (700, 701) && return pg_float
    oid == 1700 && return pg_numeric
    oid == 17 && return pg_bytea
    oid == 1042 && return pg_bpchar
    oid == 1082 && return pg_date
    oid == 1114 && return pg_timestamp
    oid == 1184 && return pg_timestamptz
    oid in (1005, 1007, 1016, 1028) && return pg_int_array    # int2[] int4[] int8[] oid[]
    oid in (1021, 1022) && return pg_float_array               # float4[] float8[]
    oid == 1231 && return pg_numeric_array
    pg_string
end

# numeric (DecimalField columns, SUM/AVG/EXTRACT): whole numbers become Int (or BigInt), everything
# else an exact Juango.Decimal (expressions that aren't decimal fields are turned into Float64 by the ORM).
function parse_pg_numeric(s::AbstractString)
    s == "NaN" && return NaN
    occursin(r"^-?\d+$", s) ? something(tryparse(Int, s), parse(BigInt, s)) : parse(Decimal, s)
end

parse_pg_date(s::AbstractString) = s == "infinity" ? typemax(Date) : s == "-infinity" ? typemin(Date) :
                                   endswith(s, " BC") ? Date(s[1:end-3]) : Date(s)

# "2025-01-02 03:04:05.123456": Julia's DateTime keeps milliseconds
function parse_pg_timestamp(s::AbstractString)
    s == "infinity" && return typemax(DateTime)
    s == "-infinity" && return typemin(DateTime)
    i = findfirst('.', s)
    base = DateTime(s[1:something(i, lastindex(s) + 1)-1], dateformat"yyyy-mm-dd HH:MM:SS")
    i === nothing && return base
    frac = rpad(s[i+1:min(end, i + 3)], 3, '0')
    base + Millisecond(parse(Int, frac))
end

# "2025-01-02 03:04:05.123+00" (or +05:30, -03:00:00): the session's time zone is UTC
function parse_pg_timestamptz(s::AbstractString)
    s == "infinity" && return TimeZones.ZonedDateTime(typemax(DateTime), TimeZones.tz"UTC")
    s == "-infinity" && return TimeZones.ZonedDateTime(typemin(DateTime), TimeZones.tz"UTC")
    k = something(findlast(c -> c == '+' || c == '-', s), 0)
    k > 11 || throw(ArgumentError("not a PostgreSQL timestamptz: $s"))
    dt = parse_pg_timestamp(s[1:k-1])
    parts = parse.(Int, split(s[k+1:end], ':'))
    secs = (s[k] == '-' ? -1 : 1) * (parts[1] * 3600 + (length(parts) > 1 ? parts[2] * 60 : 0) + (length(parts) > 2 ? parts[3] : 0))
    TimeZones.ZonedDateTime(dt - Second(secs), TimeZones.tz"UTC")
end

# "{1,2,NULL}" (one dimension; anything else stays text)
function parse_pg_number_array(s::AbstractString, elparse)
    (startswith(s, "{") && endswith(s, "}") && !occursin('{', s[2:end])) || return String(s)
    inner = s[2:end-1]
    isempty(inner) && return Any[]
    Any[x == "NULL" ? nothing : elparse(x) for x in split(inner, ',')]
end

# --- LISTEN / NOTIFY ------------------------------------------------------------------------------

struct PGnotifyC
    relname::Ptr{UInt8}
    be_pid::Cint
    extra::Ptr{UInt8}
    next::Ptr{Cvoid}
end

"A connection listening on a channel; `close(l)` stops `pg_listen`."
mutable struct PGListener
    conn::Union{Nothing,PGConn}
    watcher::Any
    stopped::Bool
end
PGListener() = PGListener(nothing, nothing, false)

"""
    pg_listen(f, listener, url, channel)

`LISTEN channel` on a connection of its own and call `f(payload)` for each notification, until
`close(listener)` (or the connection fails, which throws).
"""
function pg_listen(f, l::PGListener, url::String, channel::String)
    conn = l.conn = pg_connect(url)
    try
        pg_exec(conn, "LISTEN " * "\"" * replace(channel, "\"" => "\"\"") * "\"", Any[])
        fd = ccall((:PQsocket, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), conn.ptr)
        l.watcher = FileWatching.FDWatcher(RawFD(fd), true, false)
        while !l.stopped
            ccall((:PQconsumeInput, LIBPQ_HANDLE), Cint, (Ptr{Cvoid},), conn.ptr) == 1 || throw(connection_lost(conn))
            while true
                n = ccall((:PQnotifies, LIBPQ_HANDLE), Ptr{PGnotifyC}, (Ptr{Cvoid},), conn.ptr)
                n == C_NULL && break
                payload = unsafe_string(unsafe_load(n).extra)
                ccall((:PQfreemem, LIBPQ_HANDLE), Cvoid, (Ptr{Cvoid},), n)
                try
                    f(payload)
                catch e
                    @error "LISTEN $channel: handling a notification failed" exception = (e, catch_backtrace())
                end
            end
            l.stopped || wait(l.watcher)
        end
    catch e
        l.stopped || rethrow()
    finally
        l.watcher === nothing || try close(l.watcher) catch end
        pg_close(conn)
    end
    nothing
end
function Base.close(l::PGListener)
    l.stopped = true
    l.watcher === nothing || try close(l.watcher) catch end
    nothing
end
