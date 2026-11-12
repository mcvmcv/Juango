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
"""
mutable struct Session <: AbstractDict{String,Any}
    key::Union{Nothing,String}
    data::Dict{String,Any}
    modified::Bool
    flushed::Bool
end
Session() = Session(nothing, Dict{String,Any}(), false, false)

Base.getindex(s::Session, k::AbstractString) = s.data[k]
Base.get(s::Session, k::AbstractString, default) = get(s.data, k, default)
Base.haskey(s::Session, k::AbstractString) = haskey(s.data, k)
Base.setindex!(s::Session, v, k::AbstractString) = (s.data[k] = v; s.modified = true; s)
Base.delete!(s::Session, k::AbstractString) = (haskey(s.data, k) && (delete!(s.data, k); s.modified = true); s)
Base.pop!(s::Session, k::AbstractString, default) = haskey(s.data, k) ? (s.modified = true; pop!(s.data, k)) : default
Base.length(s::Session) = length(s.data)
Base.iterate(s::Session, st...) = iterate(s.data, st...)
Base.keys(s::Session) = keys(s.data)
Base.empty!(s::Session) = (empty!(s.data); s.modified = true; s)

session_expiry() = timezone_now() + Second(settings.SESSION_COOKIE_AGE)

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
    write(tmp, JSON.json(Dict("expire" => time() + settings.SESSION_COOKIE_AGE, "data" => s.data)))
    mv(tmp, f; force = true)                     # atomic: readers never see half a file
end

"""
Load a session from the store `SESSION_ENGINE` picks (see the top of sessions.jl).
"""
function load_session(key::Union{Nothing,AbstractString})
    key === nothing && return Session()
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
    cache_sessions() && cache_set(session_cache_key(s.key), s.data; timeout = settings.SESSION_COOKIE_AGE)
    db_sessions() || (s.modified = false; return s)
    rec = first(filter(objects(SessionRecord); session_key = s.key))
    rec === nothing && (rec = SessionRecord(session_key = s.key))
    rec.session_data = JSON.json(s.data)
    rec.expire_date = session_expiry()
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
