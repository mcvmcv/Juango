# Settings from the environment and .env files (django-environ) --------------------------------------------
#
#     read_env(joinpath(BASE_DIR, ".env"))               # KEY=value lines into ENV (set variables win)
#     configure!(
#         DEBUG = env("DEBUG", Bool; default = false),
#         SECRET_KEY = env("SECRET_KEY"),                    # required: a clear error when it's missing
#         ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost"]),
#         DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
#         CACHES = Dict("default" => env_cache(; default = "locmem://")),
#         env_email(; default = "consolemail://")...,      # EMAIL_BACKEND, EMAIL_HOST, ... as keywords
#     )
#
# Twelve-factor style: the code holds the defaults, each deployment its own environment (or a
# .env file kept out of version control).

const ENV_TRUE = ("true", "on", "ok", "y", "yes", "1")
const ENV_FALSE = ("false", "off", "n", "no", "0", "")
struct NoEnvDefault end
const NO_ENV_DEFAULT = NoEnvDefault()

"""
    env(name, T = String; default) -> T

The environment variable `name` as a `T` (django-environ's `env.str`, `env.bool`, ...):
- `String`; `Bool` (true, on, ok, y, yes, 1 / false, off, n, no, 0); `Int`, `Float64`, `Decimal`;
- `Vector{String}`, `Vector{Int}`, ...: comma-separated values;
- `Dict{String,String}` or `Dict{String,Int}`: `key=value,key2=value2`;
- `Any`: parsed as JSON.

Without `default`, a missing variable throws `ImproperlyConfigured` naming it (a setting the
deployment must give); `default` is returned as it is when the variable isn't set.
"""
function env(name::AbstractString, ::Type{T} = String; default = NO_ENV_DEFAULT) where {T}
    raw = get(ENV, string(name), nothing)
    if raw === nothing
        default === NO_ENV_DEFAULT && throw(ImproperlyConfigured("Set the $name environment variable"))
        return default
    end
    try
        env_parse(T, raw)
    catch e
        e isa ImproperlyConfigured && rethrow()
        throw(ImproperlyConfigured("The $name environment variable isn't a valid $T: $(repr(raw))"))
    end
end
env(name::Symbol, T::Type = String; kw...) = env(string(name), T; kw...)

env_parse(::Type{String}, s) = String(s)
function env_parse(::Type{Bool}, s)
    v = lowercase(strip(s))
    v in ENV_TRUE && return true
    v in ENV_FALSE && return false
    throw(ArgumentError("not a boolean"))
end
env_parse(::Type{T}, s) where {T<:Integer} = parse(T, strip(s))
env_parse(::Type{T}, s) where {T<:AbstractFloat} = parse(T, strip(s))
env_parse(::Type{Decimal}, s) = parse(Decimal, strip(s))
env_parse(::Type{Vector{T}}, s) where {T} =
    T[env_parse(T, strip(x)) for x in split(s, ','; keepempty = false) if !isempty(strip(x))]
function env_parse(::Type{Dict{K,V}}, s) where {K,V}
    d = Dict{K,V}()
    for item in split(s, ','; keepempty = false)
        occursin('=', item) || throw(ArgumentError("not key=value"))
        k, v = split(item, '='; limit = 2)
        d[env_parse(K, strip(k))] = env_parse(V, strip(v))
    end
    d
end
env_parse(::Type{Any}, s) = plainjson(JSON.parse(s))

"""
    read_env(path = ".env"; overwrite = false) -> Int

Load `KEY=value` lines from a .env file into `ENV`; returns how many were set. Blank lines and
`#` comments are skipped, an `export ` prefix is allowed, values may be in single quotes (taken
as they are) or double quotes (with `\\n`, `\\t`, `\\"` escapes), and `\${OTHER}` in an unquoted or
double-quoted value is replaced by that variable. A variable already in the environment is kept
unless `overwrite = true`, so the deployment's own environment wins. A missing file is fine
(returns 0).
"""
function read_env(path::AbstractString = ".env"; overwrite::Bool = false)
    isfile(path) || return 0
    n = 0
    for (i, line) in enumerate(eachline(path))
        s = strip(line)
        (isempty(s) || startswith(s, '#')) && continue
        startswith(s, "export ") && (s = strip(s[8:end]))
        m = match(r"^([A-Za-z_][A-Za-z0-9_.]*)\s*=\s*(.*)$", s)
        m === nothing && throw(ImproperlyConfigured("$path, line $i: expected KEY=value, got $(repr(line))"))
        key, raw = String(m[1]), String(m[2])
        value = if startswith(raw, '\'')
            endswith(raw, '\'') && length(raw) >= 2 || throw(ImproperlyConfigured("$path, line $i: unclosed quote"))
            raw[2:prevind(raw, lastindex(raw))]
        elseif startswith(raw, '"')
            q = findlast('"', raw)
            q == 1 && throw(ImproperlyConfigured("$path, line $i: unclosed quote"))
            expand_env(replace(raw[2:prevind(raw, q)], "\\n" => "\n", "\\t" => "\t", "\\\"" => "\"", "\\\\" => "\\"))
        else
            expand_env(strip(replace(raw, r"\s+#.*$" => "")))          # a trailing comment
        end
        (overwrite || !haskey(ENV, key)) || continue
        ENV[key] = value
        n += 1
    end
    n
end
expand_env(s) = replace(s, r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}" => m -> get(ENV, m[3:end-1], ""))

# --- URLs: databases, caches, email ----------------------------------------------------------------------

const DB_SCHEME_ALIASES = Dict("psql" => "postgresql", "pgsql" => "postgresql", "postgis" => "postgresql",
                               "postgres" => "postgresql", "mysql2" => "mysql", "sqlite3" => "sqlite")

"""
    env_db(name = "DATABASE_URL"; default) -> String

A database URL from the environment, as a `DATABASE` (or `DATABASES` entry) setting:
`postgresql://user:pass@host:5432/name`, `mysql://...`, `sqlite:////absolute/path.sqlite3`
(four slashes; three for a relative path) or `sqlite://:memory:`. django-environ's scheme names (`psql`, `pgsql`, `postgis`, `mysql2`,
`sqlite3`) are accepted.
"""
function env_db(name::AbstractString = "DATABASE_URL"; default = NO_ENV_DEFAULT)
    url = env(name; default = default)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*)://(.*)$"s, url)
    m === nothing && throw(ImproperlyConfigured("$name isn't a database URL (scheme://...): $(repr(url))"))
    scheme = get(DB_SCHEME_ALIASES, lowercase(m[1]), lowercase(m[1]))
    scheme == "sqlite" && m[2] in ("", ":memory:", "/:memory:") && return "sqlite:///:memory:"
    scheme * "://" * m[2]
end

"""
    env_cache(name = "CACHE_URL"; default) -> Dict

A cache from a URL, as a `CACHES` entry: `locmem://`, `dummy://`, `file:///path/to/dir`,
`db://table_name`, `redis://host:6379/0` or `memcached://host:11211`. Query parameters
`?timeout=300&max_entries=1000&key_prefix=app` set those options.
"""
function env_cache(name::AbstractString = "CACHE_URL"; default = NO_ENV_DEFAULT)
    url = env(name; default = default)
    m = match(r"^([a-z]+)://([^?]*)(?:\?(.*))?$"i, url)
    m === nothing && throw(ImproperlyConfigured("$name isn't a cache URL (scheme://...): $(repr(url))"))
    scheme, rest, query = lowercase(m[1]), m[2], m[3]
    d = Dict{Symbol,Any}()
    if scheme in ("locmem", "dummy")
        d[:backend] = Symbol(scheme)
    elseif scheme == "file"
        d[:backend] = :file; d[:location] = rest
    elseif scheme == "db"
        d[:backend] = :db; d[:location] = rest
    elseif scheme in ("redis", "rediss")
        d[:backend] = :redis; d[:location] = scheme * "://" * rest
    elseif scheme in ("memcached", "memcache", "pymemcache")
        d[:backend] = :memcached; d[:location] = rest
    else
        throw(ImproperlyConfigured("$name: unknown cache scheme '$scheme' (locmem, dummy, file, db, redis, memcached)"))
    end
    if query !== nothing
        for (k, v) in (split(kv, '='; limit = 2) for kv in split(query, '&'; keepempty = false) if occursin('=', kv))
            key = Symbol(lowercase(k))
            d[key] = something(tryparse(Int, v), tryparse(Float64, v), String(v))
        end
    end
    d
end

"""
    env_email(name = "EMAIL_URL"; default) -> NamedTuple

Email settings from a URL, to splat into `configure!(...; env_email()...)`:
`smtp://user:password@host:587` (`smtp+tls://` for STARTTLS, `smtp+ssl://` or `smtps://` for
TLS from the start), `consolemail://`, `filemail:///path/to/dir`, `memorymail://`,
`dummymail://`. The user and password may be percent-encoded.
"""
function env_email(name::AbstractString = "EMAIL_URL"; default = NO_ENV_DEFAULT)
    url = env(name; default = default)
    m = match(r"^([a-z+]+)://(?:([^:@/]*)(?::([^@/]*))?@)?([^:/?]*)(?::(\d+))?(/[^?]*)?$"i, url)
    m === nothing && throw(ImproperlyConfigured("$name isn't an email URL (scheme://...): $(repr(url))"))
    scheme = lowercase(m[1])
    dec(x) = x === nothing ? "" : URIs.unescapeuri(String(x))
    scheme == "consolemail" && return (EMAIL_BACKEND = :console,)
    scheme == "memorymail" && return (EMAIL_BACKEND = :locmem,)
    scheme == "dummymail" && return (EMAIL_BACKEND = :dummy,)
    scheme == "filemail" && return (EMAIL_BACKEND = :file, EMAIL_FILE_PATH = something(m[6], "/"))
    scheme in ("smtp", "smtp+tls", "smtp+ssl", "smtps") ||
        throw(ImproperlyConfigured("$name: unknown email scheme '$scheme' (smtp, smtp+tls, smtp+ssl, consolemail, filemail, memorymail, dummymail)"))
    ssl = scheme in ("smtp+ssl", "smtps")
    tls = scheme == "smtp+tls"
    port = m[5] === nothing ? (ssl ? 465 : tls ? 587 : 25) : parse(Int, m[5])
    (EMAIL_BACKEND = :smtp, EMAIL_HOST = isempty(something(m[4], "")) ? "localhost" : String(m[4]), EMAIL_PORT = port,
     EMAIL_HOST_USER = dec(m[2]), EMAIL_HOST_PASSWORD = dec(m[3]), EMAIL_USE_TLS = tls, EMAIL_USE_SSL = ssl)
end
