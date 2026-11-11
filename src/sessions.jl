# Sessions (database-backed) --------------------------------------------------------------------

@model struct SessionRecord
    session_key = CharField(max_length = 40, unique = true)
    session_data = TextField(blank = true)
    expire_date = DateTimeField(db_index = true)
    Meta(table = "juango_session", verbose_name = "session")
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

session_expiry() = now() + Second(settings.SESSION_COOKIE_AGE)

session_cache_key(k) = "juango.session:" * k
cache_sessions() = settings.SESSION_ENGINE in (:cache, :cached_db)
db_sessions() = settings.SESSION_ENGINE in (:db, :cached_db)

"""
Load a session. `SESSION_ENGINE` chooses the store: `:db` (the default), `:cache` (the
default cache only; fast, but sessions vanish with the cache) or `:cached_db` (cache in
front of the database).
"""
function load_session(key::Union{Nothing,AbstractString})
    key === nothing && return Session()
    if cache_sessions()
        d = cache_get(session_cache_key(key))
        d === nothing || return Session(String(key), d, false, false)
        db_sessions() || return Session()
    end
    rec = first(filter(objects(SessionRecord); session_key = key, expire_date__gt = now()))
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
    if s.key === nothing
        s.key = random_string(32)
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
end

"Remove expired session rows (the `clearsessions` command)."
clear_expired_sessions!() = delete!(filter(objects(SessionRecord); expire_date__lt = now()))
