# Sessions --------------------------------------------------------------------------------------
#
# SESSION_ENGINE picks where session data lives:
#   :db (default)      a row per session (sessions.SessionRecord)
#   :cache             the default cache only (fast; sessions vanish with the cache)
#   :cached_db         the cache in front of the database
#   :file              a file per session in SESSION_FILE_PATH
#   :signed_cookies    the data itself, signed, in the cookie (no server storage; keep it small,
#                      and note a session can't be revoked before it expires)

@model struct SessionRecord
    session_key = CharField(max_length = 40, unique = true)
    session_data = TextField(blank = true)
    expire_date = DateTimeField(db_index = true)
    Meta(table = "juango_session", verbose_name = "session", app_label = "sessions")
end

"""
Per-visitor key/value storage, available as `req.session`. Values must be
JSON-serialisable. Behaves like a `Dict{String,Any}`.

`SessionMiddleware` gives each request a session that isn't loaded yet: the store is only
read when the view first uses its data or key (like Django's SessionStore), so requests
that never touch the session cost no query.
"""
mutable struct Session <: AbstractDict{String,Any}
    key::Union{Nothing,String}
    data::Dict{String,Any}
    modified::Bool
    flushed::Bool
    loaded::Bool
    pending::Union{Nothing,String}      # the cookie value to load from, until loaded
end
Session(key, data, modified, flushed) = Session(key, data, modified, flushed, true, nothing)
Session() = Session(nothing, Dict{String,Any}(), false, false)

"A session for the cookie value `key`, loaded from the store on first use."
lazy_session(key) = key === nothing ? Session() : Session(nothing, Dict{String,Any}(), false, false, false, String(key))
"Whether the session has been read from its store (or never needed to be)."
session_loaded(s::Session) = getfield(s, :loaded)

function ensure_loaded!(s::Session)
    getfield(s, :loaded) && return s
    setfield!(s, :loaded, true)
    r = load_session(getfield(s, :pending))
    setfield!(s, :key, getfield(r, :key))
    setfield!(s, :data, getfield(r, :data))
    setfield!(s, :pending, nothing)
    s
end
function Base.getproperty(s::Session, f::Symbol)
    (f === :data || f === :key) && ensure_loaded!(s)
    getfield(s, f)
end
function Base.setproperty!(s::Session, f::Symbol, v)
    (f === :data || f === :key) && ensure_loaded!(s)
    setfield!(s, f, convert(fieldtype(Session, f), v))
end

Base.getindex(s::Session, k::AbstractString) = s.data[k]
Base.get(s::Session, k::AbstractString, default) = get(s.data, k, default)
Base.get(f::Base.Callable, s::Session, k::AbstractString) = haskey(s, k) ? s.data[k] : f()
Base.get!(s::Session, k::AbstractString, default) = haskey(s, k) ? s.data[k] : (s[k] = default; default)
Base.get!(f::Base.Callable, s::Session, k::AbstractString) = haskey(s, k) ? s.data[k] : (v = f(); s[k] = v; v)
Base.haskey(s::Session, k::AbstractString) = haskey(s.data, k)
Base.setindex!(s::Session, v, k::AbstractString) = (s.data[k] = v; s.modified = true; s)
Base.delete!(s::Session, k::AbstractString) = (haskey(s.data, k) && (delete!(s.data, k); s.modified = true); s)
Base.pop!(s::Session, k::AbstractString, default) = haskey(s.data, k) ? (s.modified = true; pop!(s.data, k)) : default
Base.length(s::Session) = length(s.data)
Base.iterate(s::Session, st...) = iterate(s.data, st...)
Base.keys(s::Session) = keys(s.data)
Base.empty!(s::Session) = (empty!(s.data); s.modified = true; s)

session_expiry() = timezone_now() + Second(settings.SESSION_COOKIE_AGE)

# --- per-session expiry (Django's set_expiry), kept in the data as "_session_expiry" -----------------

"""
    set_expiry!(session, value)

When the session expires, as Django's `set_expiry`: a number of seconds (or a `Dates.Period`) of
inactivity, a date and time, `0` for when the browser closes, `nothing` for the default
(`SESSION_COOKIE_AGE`, or the browser closing with `SESSION_EXPIRE_AT_BROWSER_CLOSE`).
"""
function set_expiry!(s::Session, value)
    if value === nothing
        delete!(s, "_session_expiry")
    elseif value isa Dates.Period
        s["_session_expiry"] = round(Int, Dates.value(convert(Dates.Millisecond, value)) / 1000)
    elseif value isa Integer
        s["_session_expiry"] = Int(value)
    else                                           # a DateTime or ZonedDateTime: kept as ISO text
        s["_session_expiry"] = string(value isa Dates.DateTime && settings.USE_TZ ? make_aware(value) : value)
    end
    s
end
parse_expiry(v::Integer) = v
parse_expiry(v::AbstractString) = (z = tryparse(TimeZones.ZonedDateTime, v); z === nothing ? something(tryparse(DateTime, v), nothing) : z)
parse_expiry(v) = nothing

"Seconds until the session expires (Django's get_expiry_age)."
function get_expiry_age(s::Session; modification = timezone_now())
    e = parse_expiry(get(s, "_session_expiry", nothing))
    e === nothing && return settings.SESSION_COOKIE_AGE
    e isa Integer && return e
    m = e isa TimeZones.ZonedDateTime && !(modification isa TimeZones.ZonedDateTime) ? make_aware(modification) :
        !(e isa TimeZones.ZonedDateTime) && modification isa TimeZones.ZonedDateTime ? DateTime(modification) : modification
    round(Int, Dates.value(convert(Dates.Millisecond, e - m)) / 1000)
end
"When the session expires (Django's get_expiry_date)."
function get_expiry_date(s::Session; modification = timezone_now())
    e = parse_expiry(get(s, "_session_expiry", nothing))
    e === nothing || e isa Integer || return e
    modification + Second(e === nothing ? settings.SESSION_COOKIE_AGE : e)
end
"Whether the session's cookie lasts only until the browser closes (Django's get_expire_at_browser_close)."
function get_expire_at_browser_close(s::Session)
    e = get(s, "_session_expiry", nothing)
    e === nothing ? get(settings, :SESSION_EXPIRE_AT_BROWSER_CLOSE, false) : e == 0
end

"Whether the session has no key and no data (Django's is_empty)."
is_empty(s::Session) = s.key === nothing && isempty(s.data)

"Django's test cookie: set it, then see on a later request whether the browser kept cookies."
set_test_cookie!(s::Session) = (s["testcookie"] = "worked"; s)
test_cookie_worked(s::Session) = get(s, "testcookie", nothing) == "worked"
delete_test_cookie!(s::Session) = delete!(s, "testcookie")

session_cache_key(k) = "juango.session:" * k
cache_sessions() = settings.SESSION_ENGINE in (:cache, :cached_db)
db_sessions() = settings.SESSION_ENGINE in (:db, :cached_db)
file_sessions() = settings.SESSION_ENGINE === :file
cookie_sessions() = settings.SESSION_ENGINE === :signed_cookies

const SESSION_SALT = "juango.sessions.signed_cookies"
"The directory of `:file` sessions (`SESSION_FILE_PATH`, default a `juango-sessions` folder in the temp directory)."
session_dir() = something(settings.SESSION_FILE_PATH, joinpath(tempdir(), "juango-sessions"))
"The file of a `:file` session; `nothing` for a key that isn't one Juango makes (no path tricks)."
session_file(key) = occursin(r"^[A-Za-z0-9]{20,64}$", key) ? joinpath(session_dir(), "juangosess" * key) : nothing

function load_file_session(key)
    f = session_file(key)
    (f === nothing || !isfile(f)) && return Session()
    d = try JSON.parse(read(f, String)) catch; nothing end
    (d isa AbstractDict && get(d, "expire", 0) > time()) || return Session()
    Session(String(key), plainjson(get(d, "data", Dict{String,Any}())), false, false)
end

function save_file_session!(s::Session)
    dir = session_dir()
    mkpath(dir)
    f = session_file(s.key)
    tmp = f * ".tmp" * random_string(6)
    write(tmp, JSON.json(Dict("expire" => time() + get_expiry_age(s), "data" => s.data)))
    mv(tmp, f; force = true)                     # atomic: readers never see half a file
end

"""
Load a session from the store `SESSION_ENGINE` picks (see the top of sessions.jl).
"""
function load_session(key::Union{Nothing,AbstractString})
    key === nothing && return Session()
    # (a key too short to be one Juango made is a new, empty session, as Django's)
    !cookie_sessions() && length(key) < 8 && return Session()
    if cookie_sessions()
        data = try signing_loads(key; salt = SESSION_SALT, max_age = settings.SESSION_COOKIE_AGE) catch; nothing end
        return data isa AbstractDict ? Session(String(key), plainjson(data), false, false) : Session()
    end
    file_sessions() && return load_file_session(key)
    if cache_sessions()
        d = cache_get(session_cache_key(key))
        d === nothing || return Session(String(key), d, false, false)
        db_sessions() || return Session()
    end
    rec = first(filter(objects(SessionRecord); session_key = key, expire_date__gt = timezone_now()))
    rec === nothing && return Session()
    data = try
        plainjson(JSON.parse(rec.session_data))
    catch
        Dict{String,Any}()
    end
    cache_sessions() && cache_set(session_cache_key(key), data; timeout = settings.SESSION_COOKIE_AGE)
    Session(String(key), data, false, false)
end

function save_session!(s::Session)
    if cookie_sessions()
        s.key = signing_dumps(s.data; salt = SESSION_SALT)      # the cookie value is the data
        s.modified = false
        return s
    end
    if s.key === nothing
        s.key = random_string(32)
    end
    if file_sessions()
        save_file_session!(s)
        s.modified = false
        return s
    end
    cache_sessions() && cache_set(session_cache_key(s.key), s.data; timeout = get_expiry_age(s))
    db_sessions() || (s.modified = false; return s)
    rec = first(filter(objects(SessionRecord); session_key = s.key))
    rec === nothing && (rec = SessionRecord(session_key = s.key))
    rec.session_data = JSON.json(s.data)
    rec.expire_date = get_expiry_date(s)
    save!(rec)
    s.modified = false
    s
end

"Give the session a new key, keeping its data (prevents session fixation)."
function cycle_key!(s::Session)
    old = s.key
    old === nothing || drop_session(old)
    s.key = random_string(32)
    s.modified = true
    s
end

"Delete the session data and key."
function flush!(s::Session)
    s.key === nothing || drop_session(s.key)
    empty!(s.data)
    s.key = nothing
    s.modified = false
    s.flushed = true
    s
end

function drop_session(key)
    cache_sessions() && cache_delete(session_cache_key(key))
    db_sessions() && delete!(filter(objects(SessionRecord); session_key = key))
    if file_sessions()
        f = session_file(key)
        f === nothing || rm(f; force = true)
    end
end

"""
Remove expired sessions (the `clearsessions` command) and return how many: rows for `:db`
and `:cached_db`, files for `:file`. Cache and signed-cookie sessions expire by themselves.
"""
function clear_expired_sessions!()
    db_sessions() && return delete!(filter(objects(SessionRecord); expire_date__lt = timezone_now()))
    file_sessions() || return 0
    dir = session_dir()
    isdir(dir) || return 0
    n = 0
    for name in readdir(dir)
        startswith(name, "juangosess") || continue
        f = joinpath(dir, name)
        d = try JSON.parse(read(f, String)) catch; nothing end
        if !(d isa AbstractDict) || get(d, "expire", 0) <= time()
            rm(f; force = true)
            n += 1
        end
    end
    n
end
