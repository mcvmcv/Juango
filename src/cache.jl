# Caching ----------------------------------------------------------------------------------------------
#
#     cache_set("greeting", "hi"; timeout = 60)        # seconds; nothing = forever, 0 = don't store
#     cache_get("greeting")                             # "hi" (or the default once expired)
#     get_or_set("stats", () -> expensive(); timeout = 300)
#     incr("hits")
#     const home = cache_page(home_view; timeout = 60)   # cache whole GET responses
#     {% cache 600 "sidebar" user.id %} ... {% endcache %}
#
#     configure!(CACHES = Dict("default" => Dict(:backend => :locmem, :max_entries => 1000),
#                              "shared"  => Dict(:backend => :redis, :location => "redis://localhost:6379/0")))
#
# Backends: :locmem (per process, LRU), :db (a table; run `manage.jl createcachetable`),
# :redis (a small built-in client) and :dummy (stores nothing).

abstract type CacheBackend end

"Options shared by every backend: default timeout, key prefix and version."
struct CacheConfig
    timeout::Union{Nothing,Float64}
    key_prefix::String
    version::Int
end

mutable struct LocMemCache <: CacheBackend
    conf::CacheConfig
    store::Dict{String,Tuple{Any,Union{Nothing,Float64}}}     # key => (value, expires)
    order::Vector{String}                                   # least recently used first
    max_entries::Int
    lock::ReentrantLock
end
struct DummyCache <: CacheBackend
    conf::CacheConfig
end
struct DatabaseCache <: CacheBackend
    conf::CacheConfig
    table::String
end
mutable struct RedisCache <: CacheBackend
    conf::CacheConfig
    host::String
    port::Int
    db::Int
    password::Union{Nothing,String}
    sock::Any
    lock::ReentrantLock
end

const CACHE_INSTANCES = Dict{String,CacheBackend}()
const CACHE_INSTANCES_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> (foreach(close_cache, values(CACHE_INSTANCES)); empty!(CACHE_INSTANCES)), CACHE_INSTANCES_LOCK))
close_cache(::CacheBackend) = nothing
close_cache(c::RedisCache) = (c.sock === nothing || try close(c.sock) catch end; c.sock = nothing)

opt(d, k, default) = haskey(d, k) ? d[k] : haskey(d, string(k)) ? d[string(k)] : default

function make_cache(d)
    t = opt(d, :timeout, 300)
    conf = CacheConfig(t === nothing ? nothing : Float64(t), string(opt(d, :key_prefix, "")), Int(opt(d, :version, 1)))
    b = Symbol(opt(d, :backend, :locmem))
    b === :locmem && return LocMemCache(conf, Dict{String,Tuple{Any,Union{Nothing,Float64}}}(), String[], Int(opt(d, :max_entries, 300)), ReentrantLock())
    b === :dummy && return DummyCache(conf)
    b === :db && return DatabaseCache(conf, string(opt(d, :location, "juango_cache")))
    if b === :redis
        m = match(r"^redis://(?::([^@]*)@)?([^:/]+)(?::(\d+))?(?:/(\d+))?$", string(opt(d, :location, "redis://127.0.0.1:6379/0")))
        m === nothing && throw(ImproperlyConfigured("bad Redis location; use redis://[:password@]host[:port][/db]"))
        return RedisCache(conf, m[2], m[3] === nothing ? 6379 : parse(Int, m[3]), m[4] === nothing ? 0 : parse(Int, m[4]),
                          m[1], nothing, ReentrantLock())
    end
    throw(ImproperlyConfigured("unknown cache backend $(repr(b))"))
end

"""
    cache(name="default") -> CacheBackend

The cache configured under `name` in `settings.CACHES`.
"""
function cache(name::AbstractString = "default")
    lock(CACHE_INSTANCES_LOCK) do
        get!(CACHE_INSTANCES, string(name)) do
            conf = settings.CACHES
            haskey(conf, name) || throw(ImproperlyConfigured("no cache named '$name' in CACHES"))
            make_cache(conf[name])
        end
    end
end

function make_key(c::CacheBackend, key, version)
    k = string(key)
    (length(k) > 250 || occursin(r"[\x00-\x20\x7f]", k)) && (k = "hashed:" * bytes2hex(sha256(k)))
    c.conf.key_prefix * ":" * string(something(version, c.conf.version)) * ":" * k
end
expiry(c::CacheBackend, timeout) = (t = timeout === :default ? c.conf.timeout : timeout; t === nothing ? nothing : time() + t)

# --- backend primitives: raw_get(c, k) -> (found, value); raw_set(c, k, v, expires); raw_delete(c, k); raw_clear(c) ---

function raw_get(c::LocMemCache, k)
    lock(c.lock) do
        haskey(c.store, k) || return (false, nothing)
        v, exp = c.store[k]
        if exp !== nothing && exp <= time()
            delete!(c.store, k); filter!(!=(k), c.order)
            return (false, nothing)
        end
        filter!(!=(k), c.order); push!(c.order, k)
        (true, deepcopy(v))
    end
end
function raw_set(c::LocMemCache, k, v, exp)
    lock(c.lock) do
        haskey(c.store, k) && filter!(!=(k), c.order)
        while length(c.order) >= c.max_entries                   # evict least recently used
            delete!(c.store, popfirst!(c.order))
        end
        c.store[k] = (deepcopy(v), exp)
        push!(c.order, k)
    end
end
raw_delete(c::LocMemCache, k) = lock(() -> (filter!(!=(k), c.order); pop!(c.store, k, nothing) !== nothing), c.lock)
raw_clear(c::LocMemCache) = lock(() -> (empty!(c.store); empty!(c.order)), c.lock)

raw_get(::DummyCache, k) = (false, nothing)
raw_set(::DummyCache, k, v, exp) = nothing
raw_delete(::DummyCache, k) = false
raw_clear(::DummyCache) = nothing

serialize_value(v) = (io = IOBuffer(); Serialization.serialize(io, v); base64encode(take!(io)))
deserialize_value(s) = Serialization.deserialize(IOBuffer(base64decode(s)))

function raw_get(c::DatabaseCache, k)
    rows = execute("SELECT \"value\", \"expires\" FROM \"$(c.table)\" WHERE \"cache_key\" = ?", [k])
    isempty(rows) && return (false, nothing)
    exp = rows[1][:expires]
    if exp !== nothing && Float64(exp) <= time()
        raw_delete(c, k)
        return (false, nothing)
    end
    (true, deserialize_value(String(rows[1][:value])))
end
function raw_set(c::DatabaseCache, k, v, exp)
    atomic() do
        execute("DELETE FROM \"$(c.table)\" WHERE \"cache_key\" = ?", [k])
        execute("INSERT INTO \"$(c.table)\" (\"cache_key\", \"value\", \"expires\") VALUES (?, ?, ?)", [k, serialize_value(v), exp])
    end
end
raw_delete(c::DatabaseCache, k) = execute_changes("DELETE FROM \"$(c.table)\" WHERE \"cache_key\" = ?", [k]) > 0
raw_clear(c::DatabaseCache) = execute("DELETE FROM \"$(c.table)\"")

"Create the database cache table (`manage.jl createcachetable`)."
function create_cache_table(name = "default")
    c = cache(name)
    c isa DatabaseCache || return nothing
    b = backend()
    t = Table(c.table, "juango", "CacheEntry",
              [Column("cache_key", :string; max_length = 255, unique = true), Column("value", :string), Column("expires", :float; null = true)])
    table_exists(b, c.table) || foreach(execute, first(create_table_sql(b, t; if_not_exists = true)))
    nothing
end

# Redis: just enough of the RESP protocol
resp_encode(args) = "*$(length(args))\r\n" * join(["\$$(ncodeunits(a))\r\n$a\r\n" for a in string.(args)])
function resp_read(io)
    l = readline(io)
    isempty(l) && throw(ErrorException("Redis connection closed"))
    t, rest = l[1], l[2:end]
    t == '+' && return rest
    t == '-' && throw(ErrorException("Redis error: $rest"))
    t == ':' && return parse(Int, rest)
    if t == '$'
        n = parse(Int, rest)
        n < 0 && return nothing
        s = String(read(io, n)); read(io, 2)
        return s
    end
    t == '*' && (n = parse(Int, rest); return n < 0 ? nothing : Any[resp_read(io) for _ in 1:n])
    throw(ErrorException("bad Redis reply: $l"))
end
function redis(c::RedisCache, args...)
    lock(c.lock) do
        if c.sock === nothing || !isopen(c.sock)
            c.sock = Sockets.connect(c.host, c.port)
            c.password === nothing || (write(c.sock, resp_encode(["AUTH", c.password])); resp_read(c.sock))
            c.db == 0 || (write(c.sock, resp_encode(["SELECT", c.db])); resp_read(c.sock))
        end
        write(c.sock, resp_encode(collect(args)))
        resp_read(c.sock)
    end
end
function raw_get(c::RedisCache, k)
    v = redis(c, "GET", k)
    v === nothing ? (false, nothing) : (true, deserialize_value(v))
end
function raw_set(c::RedisCache, k, v, exp)
    exp === nothing ? redis(c, "SET", k, serialize_value(v)) :
        redis(c, "SET", k, serialize_value(v), "PX", max(1, round(Int, (exp - time()) * 1000)))
    nothing
end
raw_delete(c::RedisCache, k) = redis(c, "DEL", k) > 0
raw_clear(c::RedisCache) = (redis(c, "FLUSHDB"); nothing)

# --- the API --------------------------------------------------------------------------------------------------

"Get a cached value (or `default`)."
function cache_get(key, default = nothing; version = nothing, cache_name = "default")
    c = cache(cache_name)
    found, v = raw_get(c, make_key(c, key, version))
    found ? v : default
end

"""
    cache_set(key, value; timeout=:default, version=nothing, cache_name="default")

Store a value. `timeout` is in seconds (`nothing` for ever, `0` to not store); `:default`
uses the cache's configured timeout.
"""
function cache_set(key, value; timeout = :default, version = nothing, cache_name = "default")
    c = cache(cache_name)
    timeout == 0 && return (raw_delete(c, make_key(c, key, version)); nothing)
    raw_set(c, make_key(c, key, version), value, expiry(c, timeout))
    nothing
end

"Store only if the key isn't cached yet; returns whether it stored."
function cache_add(key, value; timeout = :default, version = nothing, cache_name = "default")
    c = cache(cache_name)
    k = make_key(c, key, version)
    first(raw_get(c, k)) && return false
    raw_set(c, k, value, expiry(c, timeout))
    true
end

"Remove a key; returns whether it was cached."
cache_delete(key; version = nothing, cache_name = "default") = (c = cache(cache_name); raw_delete(c, make_key(c, key, version)))
"Whether a key is cached."
cache_has(key; version = nothing, cache_name = "default") = (c = cache(cache_name); first(raw_get(c, make_key(c, key, version))))
"Empty the whole cache."
cache_clear(; cache_name = "default") = raw_clear(cache(cache_name))

"The cached value for `key`, computing and storing `f()` on a miss."
function get_or_set(key, f; timeout = :default, version = nothing, cache_name = "default")
    c = cache(cache_name)
    k = make_key(c, key, version)
    found, v = raw_get(c, k)
    found && return v
    v = f()
    timeout == 0 || raw_set(c, k, v, expiry(c, timeout))
    v
end

"Several values at once: a `Dict` of the keys that are cached."
cache_get_many(keys; version = nothing, cache_name = "default") =
    Dict(k => v for (k, v) in ((k, cache_get(k, NOTFOUND; version = version, cache_name = cache_name)) for k in keys) if v !== NOTFOUND)
"Set several values: `cache_set_many(Dict(\"a\" => 1, \"b\" => 2))`."
cache_set_many(d; timeout = :default, version = nothing, cache_name = "default") =
    (foreach(((k, v),) -> cache_set(k, v; timeout = timeout, version = version, cache_name = cache_name), d); nothing)

"""
    incr(key, delta=1) -> new value

Add to a cached number (it must exist). Atomic on :locmem and :redis.
"""
function incr(key, delta::Integer = 1; version = nothing, cache_name = "default")
    c = cache(cache_name)
    k = make_key(c, key, version)
    c isa RedisCache && first(raw_get(c, k)) == false && throw(KeyError(key))
    lock(c isa LocMemCache ? c.lock : CACHE_INCR_LOCK) do
        found, v = raw_get(c, k)
        found || throw(KeyError(key))
        nv = v + delta
        exp = c isa LocMemCache ? c.store[k][2] : expiry(c, :default)
        raw_set(c, k, nv, exp)
        nv
    end
end
const CACHE_INCR_LOCK = ReentrantLock()
decr(key, delta::Integer = 1; kw...) = incr(key, -delta; kw...)

"Bump a key's version, invalidating the old value: `incr_version(\"menu\")`."
function incr_version(key; version = nothing, cache_name = "default")
    c = cache(cache_name)
    v = something(version, c.conf.version)
    found, val = raw_get(c, make_key(c, key, v))
    found || throw(KeyError(key))
    raw_set(c, make_key(c, key, v + 1), val, expiry(c, :default))
    raw_delete(c, make_key(c, key, v))
    v + 1
end

# --- whole responses ---------------------------------------------------------------------------------------

cacheable(req, resp) = req.method in ("GET", "HEAD") && resp.status == 200 && isempty(resp.cookies) && !is_streaming(resp) &&
    !occursin(r"cookie"i, something(getheader(resp, "Vary"), "")) && !occursin(r"no-store|private"i, something(getheader(resp, "Cache-Control"), ""))
page_key(req, prefix) = "views.cache_page:" * prefix * ":" * get_host(req) * full_path(req)

"""
    cache_page(view; timeout=nothing, key_prefix="", cache_name="default")

Cache a view's GET/HEAD 200 responses by URL. Responses that set cookies or vary on
the cookie (session-dependent pages) aren't cached.
"""
function cache_page(view; timeout = nothing, key_prefix = "", cache_name = "default")
    w = function (req; kw...)
        req.method in ("GET", "HEAD") || return to_response(view(req; kw...))
        k = page_key(req, key_prefix)
        hit = cache_get(k; cache_name = cache_name)
        hit === nothing || return hit
        resp = to_response(view(req; kw...))
        if cacheable(req, resp)
            t = something(timeout, cache(cache_name).conf.timeout, 300)
            hasheader(resp, "Cache-Control") || setheader!(resp, "Cache-Control", "max-age=$(round(Int, t))")
            cache_set(k, resp; timeout = t, cache_name = cache_name)
        end
        resp
    end
    propagate_flags!(w, view)
end

"""
Per-site cache middleware: caches every cacheable GET response for
`CACHE_MIDDLEWARE_SECONDS`. Add it near the start of `MIDDLEWARE`.
"""
function CacheMiddleware(get_response)
    function (req::Request)
        req.method in ("GET", "HEAD") || return get_response(req)
        k = page_key(req, "site")
        hit = cache_get(k)
        hit === nothing || return hit
        resp = get_response(req)
        if cacheable(req, resp)
            t = settings.CACHE_MIDDLEWARE_SECONDS
            hasheader(resp, "Cache-Control") || setheader!(resp, "Cache-Control", "max-age=$t")
            cache_set(k, resp; timeout = t)
        end
        resp
    end
end

# --- {% cache seconds "name" vary... %} ... {% endcache %} --------------------------------------------------

struct CacheNode <: Node
    timeout::Any
    name::String
    vary::Vector{Any}
    nodes::Vector{Node}
end
child_nodelists(n::CacheNode) = (n.nodes,)
function tag_cache(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) >= 3 || tsyntax(p, "{% cache %} needs a timeout and a name: {% cache 600 \"sidebar\" %}")
    nodes = first(parse_nodes(p, ["endcache"]))
    CacheNode(parse_filter_expr(bits[2]), strip(bits[3], ['"', '\'']), Any[parse_filter_expr(b) for b in bits[4:end]], nodes)
end
function render!(io::IO, n::CacheNode, ctx::Context)
    t = eval_fe(n.timeout, ctx)
    vary = join([string(eval_fe(v, ctx)) for v in n.vary], ":")
    k = "template.cache:" * n.name * ":" * bytes2hex(sha256(vary))
    hit = cache_get(k)
    hit === nothing || return write(io, hit)
    s = render_nodes(n.nodes, ctx)
    cache_set(k, s; timeout = t isa Number ? t : something(tryparse(Float64, string(t)), 300.0))
    write(io, s)
end
register_tag!("cache", tag_cache)
