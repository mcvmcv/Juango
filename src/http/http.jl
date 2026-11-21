# Requests & responses ---------------------------------------------------------------

# The lists of a QueryDict, keeping the order keys were first given in (as Django's, so a query
# string re-encodes as it came). A Dict{String,Vector{String}} otherwise.
struct OrderedLists <: AbstractDict{String,Vector{String}}
    order::Vector{String}
    d::Dict{String,Vector{String}}
end
OrderedLists() = OrderedLists(String[], Dict{String,Vector{String}}())
Base.getindex(l::OrderedLists, k) = l.d[k]
Base.setindex!(l::OrderedLists, v, k) = (k = String(k); haskey(l.d, k) || push!(l.order, k); l.d[k] = v; l)
Base.delete!(l::OrderedLists, k) = (haskey(l.d, k) && (delete!(l.d, k); filter!(!=(k), l.order)); l)
Base.haskey(l::OrderedLists, k) = haskey(l.d, k)
Base.get(l::OrderedLists, k, default) = get(l.d, k, default)
Base.get!(l::OrderedLists, k, default) = haskey(l.d, k) ? l.d[k] : (l[k] = default; default)
Base.length(l::OrderedLists) = length(l.order)
Base.keys(l::OrderedLists) = copy(l.order)
Base.values(l::OrderedLists) = [l.d[k] for k in l.order]
Base.empty!(l::OrderedLists) = (empty!(l.order); empty!(l.d); l)
Base.iterate(l::OrderedLists, i = 1) = i > length(l.order) ? nothing : (l.order[i] => l.d[l.order[i]], i + 1)
Base.copy(l::OrderedLists) = OrderedLists(copy(l.order), Dict(k => copy(v) for (k, v) in l.d))

"""
    QueryDict

A multi-valued dict of form / query-string data. `qd["k"]` returns the last value,
`getlist(qd, "k")` returns all values; keys keep their order. As Django's: `setlist!`,
`appendlist!`, `setlistdefault!`, `lists`, `update!` (which appends) and `urlencode(qd; safe)`.
"""
struct QueryDict <: AbstractDict{String,String}
    data::OrderedLists
end
QueryDict() = QueryDict(OrderedLists())

# (text that isn't UTF-8, from %ff and the like, has U+FFFD in its place, as Django's decoding with errors="replace")
valid_text(s::AbstractString) = isvalid(s) ? String(s) : String(map(c -> isvalid(c) ? c : '\ufffd', s))

function QueryDict(qs::AbstractString)
    q = QueryDict()
    for part in split(qs, '&'; keepempty = false)
        k, v = occursin('=', part) ? split(part, '='; limit = 2) : (part, "")
        push!(get!(q.data, valid_text(urlunquote(k)), String[]), valid_text(urlunquote(v)))
    end
    q
end

function QueryDict(d::Union{AbstractDict,AbstractVector{<:Pair}})
    q = QueryDict()
    for (k, v) in d
        q.data[string(k)] = v isa AbstractVector ? String[string(x) for x in v] : [string(v)]
    end
    q
end

Base.getindex(q::QueryDict, k::AbstractString) = last(q.data[k])
Base.getindex(q::QueryDict, k::Symbol) = q[string(k)]
Base.get(q::QueryDict, k::AbstractString, default) = haskey(q.data, k) ? last(q.data[k]) : default
Base.get(q::QueryDict, k::Symbol, default) = get(q, string(k), default)
Base.haskey(q::QueryDict, k::AbstractString) = haskey(q.data, k)
Base.haskey(q::QueryDict, k::Symbol) = haskey(q.data, string(k))
Base.length(q::QueryDict) = length(q.data)
Base.keys(q::QueryDict) = keys(q.data)
function Base.iterate(q::QueryDict, st...)
    r = iterate(q.data, st...)
    r === nothing && return nothing
    (r[1].first => last(r[1].second)), r[2]
end
Base.setindex!(q::QueryDict, v, k::AbstractString) = (q.data[k] = [string(v)]; q)
Base.setindex!(q::QueryDict, v, k::Symbol) = (q[string(k)] = v)
Base.delete!(q::QueryDict, k) = (delete!(q.data, string(k)); q)
Base.empty!(q::QueryDict) = (empty!(q.data); q)
"The key's last value, removed with its list (`default` if missing)."
Base.pop!(q::QueryDict, k) = (v = q[string(k)]; delete!(q, k); v)
Base.pop!(q::QueryDict, k, default) = haskey(q, string(k)) ? pop!(q, k) : default
"The key's last value, setting it to `default` first if it's missing (Django's setdefault)."
Base.get!(q::QueryDict, k, default) = (haskey(q, string(k)) || (q[string(k)] = default); q[string(k)])
"All values submitted for key `k`."
getlist(q::QueryDict, k) = get(q.data, string(k), String[])
"Replace the key's values (Django's setlist)."
setlist!(q::QueryDict, k, vs) = (q.data[string(k)] = String[string(v) for v in vs]; q)
"Add a value to the key's list (Django's appendlist)."
appendlist!(q::QueryDict, k, v) = (push!(get!(q.data, string(k), String[]), string(v)); q)
"The key's list, set to `default` first if it's missing (Django's setlistdefault)."
setlistdefault!(q::QueryDict, k, default = String[]) = get!(q.data, string(k), String[string(v) for v in default])
"Each key with all its values, in order (Django's lists())."
lists(q::QueryDict) = [k => copy(v) for (k, v) in q.data]
"Add another dict's values to the lists, as Django's QueryDict.update (it appends, not replaces)."
function update!(q::QueryDict, other)
    for (k, v) in (other isa QueryDict ? lists(other) : pairs_of(other))
        for x in (v isa AbstractVector ? v : [v])
            appendlist!(q, k, x)
        end
    end
    q
end

"""
    get(q::QueryDict, key, T) -> T or nothing
    getlist(q::QueryDict, key, T) -> Vector{T}

A parameter as a `T` (`Int` and other integers, `Float64`, `Decimal`, `Bool`, `Date`, `DateTime`,
`UUID`, `String`), or `nothing` when it's missing, blank or doesn't parse: `get(req.POST, "id", Int)`.
`getlist` drops the values that don't parse. (For a 400 on junk instead, see `query_param`.)
"""
Base.get(q::QueryDict, k::AbstractString, ::Type{T}) where {T<:Union{Number,Bool,Dates.TimeType,UUID,AbstractString}} =
    parse_param(T, get(q, string(k), nothing))
getlist(q::QueryDict, k, ::Type{T}) where {T} = T[v for v in (parse_param(T, s) for s in getlist(q, k)) if v !== nothing]
parse_param(::Type, ::Nothing) = nothing
function parse_param(::Type{T}, raw::AbstractString) where {T}
    s = strip(raw)
    isempty(s) && return nothing
    T <: AbstractString && return T(s)
    T === Bool && return lowercase(s) in ("1", "true", "on", "yes", "y") ? true : lowercase(s) in ("0", "false", "off", "no", "n") ? false : nothing
    T <: Union{Number,UUID} && return tryparse(T, s)
    T === Date && return parse_input_datetime(s, :date)
    T === DateTime && return parse_input_datetime(s, :datetime)
    nothing
end
Base.copy(q::QueryDict) = QueryDict(copy(q.data))
"""
    urlencode(q::QueryDict; safe = "")

Re-encode as a query string, keys in their order, as Django's: characters in `safe` (e.g. "/")
are left as they are.
"""
function urlencode(q::QueryDict; safe::AbstractString = "")
    enc(s) = (e = urlquote(s); isempty(safe) ? e : foldl((t, c) -> replace(t, urlquote(string(c)) => string(c)), safe; init = e))
    join([enc(k) * "=" * enc(v) for (k, vs) in q.data for v in vs], "&")
end

"""
    Request

An incoming HTTP request. Notable fields: `method`, `path`, `GET`, `POST`,
`COOKIES`, `session`, `user`, `resolver_match`, and `meta` for arbitrary
per-request data set by middleware.
"""
mutable struct Request
    method::String
    path::String
    query_string::String
    headers::Dict{String,String}
    body::Vector{UInt8}
    GET::QueryDict
    POST::QueryDict
    COOKIES::Dict{String,String}
    session::Any
    user::Any
    resolver_match::Any
    meta::Dict{Symbol,Any}
end

function Request(method::AbstractString, target::AbstractString;
                 headers = Dict{String,String}(), body = UInt8[], remote_addr = "127.0.0.1")
    p, q = occursin('?', target) ? split(target, '?'; limit = 2) : (target, "")
    hdrs = Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in pairs_of(headers))
    body = body isa AbstractString ? Vector{UInt8}(codeunits(body)) : Vector{UInt8}(body)
    path = URIs.unescapeuri(String(p))
    isempty(path) && (path = "/")
    req = Request(uppercase(method), path, String(q), hdrs, body, QueryDict(q), QueryDict(),
                  parse_cookies(get(hdrs, "cookie", "")), nothing, nothing, nothing,
                  Dict{Symbol,Any}(:remote_addr => remote_addr))
    ctype = lowercase(get(hdrs, "content-type", ""))
    if startswith(ctype, "application/x-www-form-urlencoded") ||
       (isempty(ctype) && req.method in ("POST", "PUT", "PATCH") && !isempty(body))
        req.POST = QueryDict(String(copy(body)))
    elseif startswith(ctype, "multipart/form-data")
        req.POST = parse_multipart_fields(req)
    end
    req
end

"""
    parse_cookies(header) -> Dict{String,String}

A Cookie header's cookies, as Django's `parse_cookie` (and the browsers) read it: `;`-separated
`name=value` pairs, a chunk without `=` being a value with an empty name, later names winning,
and quoted values unquoted (`"a\\073b"` is `a;b`).
"""
function parse_cookies(s::AbstractString)
    d = Dict{String,String}()
    for chunk in split(s, ';')
        k, v = occursin('=', chunk) ? split(chunk, '='; limit = 2) : ("", chunk)
        k, v = strip(k), strip(v)
        (isempty(k) && isempty(v)) || (d[String(k)] = cookie_unquote(v))
    end
    d
end
"Python's http.cookies._unquote: a quoted value without its quotes, \\ooo (octal) and \\x escapes read."
function cookie_unquote(v::AbstractString)
    (length(v) >= 2 && startswith(v, '"') && endswith(v, '"')) || return String(v)
    s = v[nextind(v, 1):prevind(v, lastindex(v))]
    replace(s, r"\\[0-3][0-7][0-7]" => m -> string(Char(parse(Int, m[2:end]; base = 8))), r"\\(.)" => s"\1")
end
# Python's http.cookies._LegalChars: other characters make the value quoted, with octal escapes
const COOKIE_LEGAL = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#\$%&'*+-.^_`|~:")
"A cookie value as Python's SimpleCookie writes it: as it is, or quoted with `;`, `,`, spaces and the like as \\ooo."
function cookie_quote(v::AbstractString)
    all(in(COOKIE_LEGAL), v) && return String(v)
    io = IOBuffer()
    print(io, '"')
    for c in v
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c in COOKIE_LEGAL || UInt32(c) > 0xff
            print(io, c)
        else
            print(io, '\\', string(UInt32(c); base = 8, pad = 3))
        end
    end
    print(io, '"')
    String(take!(io))
end

"""
    UploadedFile(name, data; content_type="application/octet-stream")

A file from a multipart upload (`req.FILES["avatar"]`): `name`, `content_type`, `size` and
the bytes (`read(f)`). Also used to post files with the test `Client`.
"""
struct UploadedFile
    name::String
    content_type::String
    bytes::Union{Nothing,Vector{UInt8}}   # in memory, or
    path::Union{Nothing,String}           # a temporary file (big uploads; see FILE_UPLOAD_HANDLERS)
    filesize::Int
end
UploadedFile(name, data; content_type = "application/octet-stream") =
    (b = data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data);
     UploadedFile(string(name), string(content_type), b, nothing, length(b)))
"An upload kept in a temporary file (Django's `TemporaryUploadedFile`)."
TemporaryUploadedFile(name, path; content_type = "application/octet-stream") =
    UploadedFile(string(name), string(content_type), nothing, String(path), filesize(path))
Base.read(f::UploadedFile) = (b = getfield(f, :bytes); b === nothing ? read(getfield(f, :path)) : copy(b))
Base.read(f::UploadedFile, ::Type{String}) = String(read(f))
Base.size(f::UploadedFile) = getfield(f, :filesize)
"The temporary file holding a big upload, or `nothing` when it's in memory."
temporary_file_path(f::UploadedFile) = getfield(f, :path)
Base.getproperty(f::UploadedFile, s::Symbol) = s === :size ? getfield(f, :filesize) : s === :data ? read(f) : getfield(f, s)
Base.show(io::IO, f::UploadedFile) = print(io, "<UploadedFile ", repr(f.name), " (", f.size, " bytes", f.path === nothing ? "" : ", on disk", ")>")

# --- upload handlers: what becomes of each uploaded file -----------------------------------------------
#
# FILE_UPLOAD_HANDLERS (default: MemoryFileUploadHandler(), TemporaryFileUploadHandler()) are asked in
# turn; the first that returns an UploadedFile wins. A handler of your own is any value with a method
# `Juango.upload_file(handler, field_name, file_name, content_type, data::Vector{UInt8})` returning an
# UploadedFile, or `nothing` to pass it on (throw BadRequest to refuse the upload).

"Keep uploads of up to `FILE_UPLOAD_MAX_MEMORY_SIZE` bytes in memory."
struct MemoryFileUploadHandler end
"Write uploads to a temporary file in `FILE_UPLOAD_TEMP_DIR` (removed when the request is done)."
struct TemporaryFileUploadHandler end
upload_file(h, field, name, content_type, data) = nothing
upload_file(::MemoryFileUploadHandler, field, name, content_type, data) =
    length(data) <= something(get(settings, :FILE_UPLOAD_MAX_MEMORY_SIZE, nothing), typemax(Int)) ?
        UploadedFile(name, data; content_type = content_type) : nothing
function upload_file(::TemporaryFileUploadHandler, field, name, content_type, data)
    dir = something(get(settings, :FILE_UPLOAD_TEMP_DIR, nothing), tempdir())
    p, io = mktemp(dir; cleanup = false)
    write(io, data); close(io)
    TemporaryUploadedFile(name, p; content_type = content_type)
end
"Turn an uploaded part into an UploadedFile with the configured handlers."
function handle_upload(field, name, content_type, data)
    for h in get(settings, :FILE_UPLOAD_HANDLERS, Any[MemoryFileUploadHandler(), TemporaryFileUploadHandler()])
        f = upload_file(h, field, name, content_type, data)
        f === nothing || return f
    end
    UploadedFile(name, data; content_type = content_type)
end
"Remove the temporary files of a request's uploads."
cleanup_uploads(req) = for fs in values(get(req.meta, :FILES, FileDict()).data), f in fs
    p = getfield(f, :path)
    p === nothing || rm(p; force = true)
end

"Uploaded files by field name (several per name for `multiple` inputs): `get(req.FILES, \"doc\", nothing)`, `getlist`."
struct FileDict
    data::Dict{String,Vector{UploadedFile}}
end
FileDict() = FileDict(Dict{String,Vector{UploadedFile}}())
Base.get(d::FileDict, k, default) = (v = get(d.data, string(k), nothing); v === nothing || isempty(v) ? default : first(v))
Base.getindex(d::FileDict, k) = (v = get(d, k, nothing); v === nothing ? throw(KeyError(k)) : v)
Base.haskey(d::FileDict, k) = haskey(d.data, string(k))
Base.keys(d::FileDict) = keys(d.data)
Base.isempty(d::FileDict) = isempty(d.data)
Base.length(d::FileDict) = length(d.data)
getlist(d::FileDict, k) = get(d.data, string(k), UploadedFile[])

"`req.user` before it is needed: AuthenticationMiddleware sets this, and the first read of `req.user` looks the user up."
struct LazyUser end
const LAZY_USER = LazyUser()

function Base.getproperty(r::Request, s::Symbol)
    s === :FILES && return get(getfield(r, :meta), :FILES, FileDict())
    s === :htmx && return htmx_details(r)                 # contrib/htmx.jl
    if s === :user
        u = getfield(r, :user)
        u isa LazyUser || return u
        u = get_user(r)
        setfield!(r, :user, u)
        return u
    end
    getfield(r, s)
end
Base.propertynames(r::Request, private::Bool = false) = (fieldnames(Request)..., :FILES, :htmx)

"Parse a multipart body: fields into `req.POST`, files into `req.FILES`."
function parse_multipart_fields(req::Request)
    q = QueryDict()
    files = FileDict()
    try
        parts = HTTP.parse_multipart_form(header(req, "content-type"), req.body)
        parts === nothing && return q
        maxfiles = get(settings, :DATA_UPLOAD_MAX_NUMBER_FILES, nothing)
        maxfiles === nothing || count(p -> p.filename !== nothing, parts) <= maxfiles ||
            throw(BadRequest("The number of files exceeded DATA_UPLOAD_MAX_NUMBER_FILES."))
        for p in parts
            if p.filename === nothing
                push!(get!(q.data, p.name, String[]), String(read(p.data)))
            else
                isempty(p.filename) && continue      # an empty file input
                push!(get!(files.data, p.name, UploadedFile[]),
                      handle_upload(p.name, p.filename, isempty(p.contenttype) ? "application/octet-stream" : p.contenttype, read(p.data)))
            end
        end
    catch e
        e isa BadRequest && (req.meta[:upload_error] = e)     # an upload handler refused: a 400 from the handler
    end
    req.meta[:FILES] = files
    q
end

"Case-insensitive request header lookup."
header(req::Request, name::AbstractString, default = nothing) = get(req.headers, lowercase(name), default)

"Parse the request body as JSON."
json_body(req::Request) = JSON.parse(String(copy(req.body)))

"""
The request's host (and port): its Host header, or with `USE_X_FORWARDED_HOST` (behind a proxy
that sets it) X-Forwarded-Host, as Django's get_host. ALLOWED_HOSTS is checked on it.
"""
function get_host(req::Request)
    if get(settings, :USE_X_FORWARDED_HOST, false)
        f = get(req.headers, "x-forwarded-host", nothing)
        f === nothing || return strip(String(first(split(f, ','))))
    end
    get(req.headers, "host", "testserver")
end
"""
The port the request came to (Django's get_port): with `USE_X_FORWARDED_PORT`, X-Forwarded-Port;
otherwise the Host's, or 443 / 80.
"""
function get_port(req::Request)
    if get(settings, :USE_X_FORWARDED_PORT, false)
        f = get(req.headers, "x-forwarded-port", nothing)
        f === nothing || return strip(String(f))
    end
    m = match(r":(\d+)$", get_host(req))
    m === nothing ? (is_secure(req) ? "443" : "80") : String(m[1])
end

"""
    url_has_allowed_host_and_scheme(url, allowed_hosts; require_https = false) -> Bool

Whether redirecting to `url` (from a `next` parameter, say) is safe: a path on this site, or an
absolute http(s) URL on one of `allowed_hosts`. As Django's, it refuses what browsers would read
as another site: `//evil.example`, `/\\evil.example`, `/\t/evil.example`, `https:evil.example`,
`javascript:...`.
"""
function url_has_allowed_host_and_scheme(url, allowed_hosts; require_https::Bool = false)
    url === nothing && return false
    u = strip(string(url))
    isempty(u) && return false
    any(c -> c < ' ' || c == '\x7f', u) && return false           # browsers drop tabs and newlines
    u = replace(u, '\\' => '/')                                     # and read \ as /
    startswith(u, "///") && return false
    m = match(r"^(?:([a-zA-Z][a-zA-Z0-9+.-]*):)?(?://([^/?#]*))?", u)
    scheme, netloc = m[1], m[2]
    if netloc === nothing
        return scheme === nothing                                    # a path; "javascript:", "https:evil" aren't
    end
    scheme === nothing || lowercase(scheme) in (require_https ? ("https",) : ("http", "https")) || return false
    host = host_name(String(last(split(netloc, '@'))))               # without user:password@
    host === nothing && return false
    hosts = Set(something(host_name(string(h)), "") for h in (allowed_hosts isa AbstractString ? [allowed_hosts] : allowed_hosts))
    host in hosts
end
full_path(req::Request) = isempty(req.query_string) ? req.path : req.path * "?" * req.query_string
build_absolute_uri(req::Request, loc = full_path(req)) =
    (is_secure(req) ? "https://" : "http://") * get_host(req) * loc
is_ajax(req::Request) = header(req, "x-requested-with", "") == "XMLHttpRequest"
Base.show(io::IO, r::Request) = print(io, "<Request: ", r.method, " ", repr(full_path(r)), ">")

# --- responses ------------------------------------------------------------------------

"""
    HttpResponse(content=""; status=200, content_type="text/html; charset=utf-8")

An outgoing HTTP response. `context` and `templates` are filled in by `render` so
tests can inspect them.
"""
mutable struct HttpResponse
    status::Int
    headers::Vector{Pair{String,String}}
    body::Vector{UInt8}
    cookies::Vector{String}
    context::Any
    templates::Vector{String}
    stream::Any             # an iterable of chunks for a streaming response (see streaming.jl), else nothing
    deferred::Any           # a TemplateResponse not rendered yet: DeferredTemplate, else nothing
end

"What a `TemplateResponse` renders, kept until it's rendered."
mutable struct DeferredTemplate
    request::Any
    template_name::Any       # a name, a list of names (the first that exists) or a Template
    context_data::Dict{String,Any}
end

"""
A response body's bytes, as Django's make_bytes: text or bytes as they are, anything else iterable
(a vector of chunks, a generator) its chunks joined, any other value its text (`12345`).
"""
content_bytes(c::AbstractVector{UInt8}) = Vector{UInt8}(c)
content_bytes(c::AbstractString) = Vector{UInt8}(codeunits(c))
content_bytes(c::Union{AbstractVector,Base.Generator,Tuple}) = reduce(vcat, (content_bytes(x) for x in c); init = UInt8[])
content_bytes(c) = Vector{UInt8}(codeunits(string(c)))

"Django's check: a status code is an integer from 100 to 599."
function check_status(status)
    s = status isa Integer ? Int(status) : status isa AbstractString ? tryparse(Int, status) : nothing
    s === nothing && throw(ArgumentError("HTTP status code must be an integer."))
    100 <= s <= 599 || throw(ArgumentError("HTTP status code must be an integer from 100 to 599."))
    s
end

function HttpResponse(content = ""; status = 200,
                      content_type = "text/html; charset=utf-8", headers = Pair{String,String}[])
    body = content_bytes(content)
    hs = Pair{String,String}[header_pair(k, v) for (k, v) in headers]
    any(h -> header_eq(h.first, "content-type"), hs) || pushfirst!(hs, "Content-Type" => content_type)
    HttpResponse(check_status(status), hs, body, String[], nothing, String[], nothing, nothing)
end

"""
Thrown for a header name or value with a newline in it (Django's BadHeaderError): a value from the
request put into a header could otherwise add headers of its own.
"""
struct BadHeaderError <: Exception
    msg::String
end
Base.showerror(io::IO, e::BadHeaderError) = print(io, "BadHeaderError: ", e.msg)
"""
A header as it can be sent, as Django's: a newline in the name or value is a `BadHeaderError`, a
name must be ASCII, and a value that isn't Latin-1 is MIME-encoded (RFC 2047: `=?utf-8?b?...?=`).
"""
function header_pair(name, value)
    k, v = string(name), string(value)
    (occursin('\n', k) || occursin('\r', k)) && throw(BadHeaderError("Header names can't contain newlines (got $(repr(k)))"))
    (occursin('\n', v) || occursin('\r', v)) && throw(BadHeaderError("Header values can't contain newlines (got $(repr(v)))"))
    isascii(k) || throw(ArgumentError("Header names must be ASCII (got $(repr(k)))"))
    all(c -> UInt32(c) <= 0xff, v) || (v = "=?utf-8?b?" * base64encode(v) * "?=")
    k => v
end

function Base.getproperty(r::HttpResponse, s::Symbol)
    s === :template_name && return (d = getfield(r, :deferred); d === nothing ? nothing : d.template_name)
    s === :context_data && return (d = getfield(r, :deferred); d === nothing ? getfield(r, :context) : d.context_data)
    s === :is_rendered && return getfield(r, :deferred) === nothing
    getfield(r, s)
end
function Base.setproperty!(r::HttpResponse, s::Symbol, v)
    if s in (:template_name, :context_data)
        d = getfield(r, :deferred)
        d === nothing && throw(ArgumentError("the response is already rendered"))
        return setfield!(d, s, s === :context_data ? to_context_dict(v) : v)
    end
    setfield!(r, s, convert(fieldtype(HttpResponse, s), v))
end

"Response body as a `String` (a streaming response is read to the end first)."
text(r::HttpResponse) = (consume_stream!(r); String(copy(r.body)))
Base.String(r::HttpResponse) = text(r)
Base.show(io::IO, r::HttpResponse) =
    print(io, "<HttpResponse status=", r.status, " ", repr(something(getheader(r, "Content-Type"), "")), ">")

"Whether two header names are equal ignoring ASCII case (without allocating)."
function header_eq(a::AbstractString, b::AbstractString)
    ca, cb = codeunits(a), codeunits(b)
    length(ca) == length(cb) || return false
    @inbounds for i in eachindex(ca)
        x, y = ca[i], cb[i]
        x == y && continue
        (x | 0x20) == (y | 0x20) && UInt8('a') <= (x | 0x20) <= UInt8('z') || return false
    end
    true
end

function getheader(r::HttpResponse, name::AbstractString, default = nothing)
    for (k, v) in r.headers
        header_eq(k, name) && return v
    end
    default
end
function setheader!(r::HttpResponse, name::AbstractString, value)
    h = header_pair(name, value)
    filter!(h -> !header_eq(h.first, name), r.headers)
    push!(r.headers, h)
    r
end
"Remove a header (Django's `del response[name]`)."
delheader!(r::HttpResponse, name::AbstractString) = (filter!(h -> !header_eq(h.first, name), r.headers); r)
"Add to the body, as Django's HttpResponse.write; returns the number of bytes."
Base.write(r::HttpResponse, x::Union{AbstractString,AbstractVector{UInt8}}) = (b = content_bytes(x); append!(r.body, b); length(b))
"Add each chunk to the body (Django's writelines)."
writelines(r::HttpResponse, xs) = (foreach(x -> write(r, x), xs); nothing)
hasheader(r::HttpResponse, name) = getheader(r, name) !== nothing

"""
    set_cookie!(resp, name, value; max_age, path="/", domain, secure, httponly, samesite="Lax")
"""
function set_cookie!(r::HttpResponse, name, value; max_age = nothing, expires = nothing, path = "/",
                     domain = nothing, secure = false, httponly = false, samesite = "Lax")
    # (as Django's: an expiry date becomes a Max-Age (so not with max_age as well); a max_age may be a
    # Period or a fraction; SameSite is Lax, Strict or None; the value is quoted when it holds ; , spaces and the like)
    expires isa Union{DateTime,TimeZones.ZonedDateTime} && max_age !== nothing &&
        throw(ArgumentError("'expires' and 'max_age' can't be used together."))
    max_age isa Dates.Period && (max_age = Dates.value(convert(Dates.Millisecond, max_age)) ÷ 1000)
    max_age === nothing || (max_age = trunc(Int, max_age))
    if expires isa Union{DateTime,TimeZones.ZonedDateTime}
        e = expires isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(expires, TimeZones.tz"UTC")) : expires
        max_age = max(0, Dates.value(convert(Dates.Millisecond, e - now(UTC))) ÷ 1000 + 1)
        expires = nothing
    end
    samesite === nothing || lowercase(string(samesite)) in ("lax", "none", "strict") ||
        throw(ArgumentError("samesite must be \"lax\", \"none\", or \"strict\"."))
    s = string(name, "=", cookie_quote(string(value)), "; Path=", path)
    max_age !== nothing && (s *= "; Max-Age=$(max_age)")
    if expires !== nothing
        s *= "; Expires=" * (expires isa AbstractString ? expires : http_date(expires))
    elseif max_age !== nothing
        s *= "; Expires=" * http_date(now(UTC) + Second(max_age))
    end
    domain !== nothing && (s *= "; Domain=$domain")
    secure && (s *= "; Secure")
    httponly && (s *= "; HttpOnly")
    samesite !== nothing && (s *= "; SameSite=$samesite")
    filter!(c -> !startswith(c, string(name, "=")), r.cookies)
    push!(r.cookies, s)
    r
end
"Delete a cookie: Secure for a `__Secure-` or `__Host-` name or with SameSite=None, as browsers require (Django's)."
function delete_cookie!(r::HttpResponse, name; path = "/", domain = nothing, samesite = "Lax")
    secure = startswith(string(name), "__Secure-") || startswith(string(name), "__Host-") ||
             (samesite !== nothing && lowercase(string(samesite)) == "none")
    set_cookie!(r, name, ""; max_age = 0, expires = "Thu, 01 Jan 1970 00:00:00 GMT", path = path, domain = domain,
                samesite = samesite, secure = secure)
end

signed_cookie_salt(name, salt) = string("juango.signed_cookies.", name, salt)

"""
    set_signed_cookie!(resp, name, value; salt = "", kwargs...)

Set a cookie whose value is signed with SECRET_KEY (and `salt`) and timestamped, so it can't be
changed by the client without `get_signed_cookie` noticing. It is not encrypted: the client can
read it. Takes `set_cookie!`'s keywords.
"""
function set_signed_cookie!(r::HttpResponse, name, value; salt = "", kwargs...)
    payload = b64url(Vector{UInt8}(codeunits(string(value)))) * ":" * string(round(Int, time()); base = 36)
    set_cookie!(r, name, sign_value(payload; salt = signed_cookie_salt(name, salt)); kwargs...)
end

"""
    get_signed_cookie(req, name; default, salt = "", max_age = nothing) -> String

The value of a cookie set with `set_signed_cookie!`. Without a `default`, a missing cookie
throws `KeyError`, a tampered one `BadSignature` and one older than `max_age` seconds
`SignatureExpired`; with a `default`, those return it instead (as Django).
"""
function get_signed_cookie(req::Request, name; default = NO_COOKIE_DEFAULT, salt = "", max_age = nothing)
    raw = get(req.COOKIES, string(name), nothing)
    if raw === nothing
        default === NO_COOKIE_DEFAULT && throw(KeyError(name))
        return default
    end
    try
        v = unsign_value(raw; salt = signed_cookie_salt(name, salt))
        i = findlast(':', v)
        i === nothing && throw(BadSignature("no timestamp"))
        ts = parse(Int, v[i+1:end]; base = 36)
        max_age !== nothing && time() - ts > max_age && throw(SignatureExpired("signature is $(round(Int, time() - ts)) seconds old"))
        String(b64url_decode(v[1:i-1]))
    catch e
        (e isa Union{BadSignature,SignatureExpired,ArgumentError} && default !== NO_COOKIE_DEFAULT) || rethrow()
        default
    end
end
struct NoCookieDefault end
const NO_COOKIE_DEFAULT = NoCookieDefault()

"JSON response. `data` may be any JSON-serialisable value."
JsonResponse(data; status = 200, kw...) =
    HttpResponse(JSON.json(data); status = status, content_type = "application/json", kw...)

"""
A redirect to a URL Django's redirects refuse (`DisallowedRedirect`, answered with 400): a scheme
other than `allowed_schemes` (`javascript:`, `data:`, `file:`...), or a URL longer than 2048 characters.
"""
struct DisallowedRedirect <: Exception
    msg::String
end
Base.showerror(io::IO, e::DisallowedRedirect) = print(io, "DisallowedRedirect: ", e.msg)
const MAX_REDIRECT_URL_LENGTH = 2048
function check_redirect_url(url::AbstractString, allowed_schemes)
    length(url) > MAX_REDIRECT_URL_LENGTH && throw(DisallowedRedirect("Unsafe redirect exceeding $MAX_REDIRECT_URL_LENGTH characters"))
    # (as Python's urlsplit: leading spaces and control characters, and tabs and newlines anywhere, are ignored)
    u = filter(c -> !(c in ('\t', '\r', '\n')), lstrip(c -> c <= ' ', url))
    m = match(r"^([A-Za-z][A-Za-z0-9+.\-]*):", u)
    m === nothing || lowercase(m[1]) in allowed_schemes ||
        throw(DisallowedRedirect("Unsafe redirect to URL with protocol '$(lowercase(m[1]))'"))
    nothing
end
"""
    HttpResponseRedirect(url; status = 302, allowed_schemes = ("http", "https", "ftp"))

A redirect. As Django's, a URL with another scheme (`javascript:`...) or over 2048 characters is
refused with `DisallowedRedirect`.
"""
function HttpResponseRedirect(url; status = 302, allowed_schemes = ("http", "https", "ftp"))
    check_redirect_url(string(url), allowed_schemes)
    r = HttpResponse(""; status = status)
    setheader!(r, "Location", url)
end
HttpResponsePermanentRedirect(url; kw...) = HttpResponseRedirect(url; status = 301, kw...)
HttpResponseNotFound(content = "<h1>Not Found</h1>") = HttpResponse(content; status = 404)
HttpResponseForbidden(content = "<h1>403 Forbidden</h1>") = HttpResponse(content; status = 403)
HttpResponseBadRequest(content = "<h1>Bad Request (400)</h1>") = HttpResponse(content; status = 400)
HttpResponseGone(content = "<h1>Gone</h1>") = HttpResponse(content; status = 410)
HttpResponseServerError(content = "<h1>Server Error (500)</h1>") = HttpResponse(content; status = 500)
"A 304 response: no body and no Content-Type (as Django's)."
function HttpResponseNotModified()
    r = HttpResponse(""; status = 304)
    filter!(h -> !header_eq(h.first, "Content-Type"), r.headers)
    r
end
function HttpResponseNotAllowed(methods)
    r = HttpResponse("<h1>405 Method Not Allowed</h1>"; status = 405)
    setheader!(r, "Allow", join(methods, ", "))
end

"Coerce whatever a view returned into an `HttpResponse`."
to_response(r::HttpResponse) = r
to_response(s::AbstractString) = HttpResponse(s)
to_response(s::SafeString) = HttpResponse(s.s)
to_response(x::Union{AbstractDict,NamedTuple,AbstractVector}) = JsonResponse(x)
to_response(t::Task) = to_response(await_task(t))      # async views
to_response(::Nothing) = error("The view returned `nothing` instead of an HttpResponse.")
to_response(x) = error("The view returned a $(typeof(x)) instead of an HttpResponse.")

# --- exceptions ----------------------------------------------------------------------

"Raise to produce a 404 response."
struct Http404 <: Exception
    msg::String
end
Http404() = Http404("Not found")
"Raise to produce a 403 response."
struct PermissionDenied <: Exception
    msg::String
end
PermissionDenied() = PermissionDenied("Permission denied")
"Raise to produce a 400 response."
struct BadRequest <: Exception
    msg::String
end
BadRequest() = BadRequest("Bad request")
Base.showerror(io::IO, e::Union{Http404,PermissionDenied,BadRequest}) = print(io, nameof(typeof(e)), ": ", e.msg)
