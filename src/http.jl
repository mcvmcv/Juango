# Requests & responses ---------------------------------------------------------------

"""
    QueryDict

A multi-valued dict of form / query-string data. `qd["k"]` returns the last value,
`getlist(qd, "k")` returns all values.
"""
struct QueryDict <: AbstractDict{String,String}
    data::Dict{String,Vector{String}}
end
QueryDict() = QueryDict(Dict{String,Vector{String}}())

function QueryDict(qs::AbstractString)
    d = Dict{String,Vector{String}}()
    for part in split(qs, '&'; keepempty = false)
        k, v = occursin('=', part) ? split(part, '='; limit = 2) : (part, "")
        push!(get!(d, urlunquote(k), String[]), urlunquote(v))
    end
    QueryDict(d)
end

function QueryDict(d::AbstractDict)
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
"All values submitted for key `k`."
getlist(q::QueryDict, k) = get(q.data, string(k), String[])
Base.copy(q::QueryDict) = QueryDict(Dict(k => copy(v) for (k, v) in q.data))
"Re-encode as a query string."
urlencode(q::QueryDict) = urlencode(Dict(k => v for (k, v) in q.data))

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
    path = HTTP.URIs.unescapeuri(String(p))
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

function parse_cookies(s::AbstractString)
    d = Dict{String,String}()
    for part in split(s, ';'; keepempty = false)
        occursin('=', part) || continue
        k, v = split(part, '='; limit = 2)
        d[strip(k)] = strip(strip(v), '"')
    end
    d
end

"""
    UploadedFile(name, data; content_type="application/octet-stream")

A file from a multipart upload (`req.FILES["avatar"]`): `name`, `content_type`, `size` and
the bytes (`read(f)`). Also used to post files with the test `Client`.
"""
struct UploadedFile
    name::String
    content_type::String
    data::Vector{UInt8}
end
UploadedFile(name, data; content_type = "application/octet-stream") =
    UploadedFile(string(name), string(content_type), data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data))
Base.read(f::UploadedFile) = copy(f.data)
Base.read(f::UploadedFile, ::Type{String}) = String(copy(f.data))
Base.size(f::UploadedFile) = length(f.data)
Base.getproperty(f::UploadedFile, s::Symbol) = s === :size ? length(getfield(f, :data)) : getfield(f, s)
Base.show(io::IO, f::UploadedFile) = print(io, "<UploadedFile ", repr(f.name), " (", length(f.data), " bytes)>")

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

Base.getproperty(r::Request, s::Symbol) = s === :FILES ? get(getfield(r, :meta), :FILES, FileDict()) : getfield(r, s)
Base.propertynames(r::Request, private::Bool = false) = (fieldnames(Request)..., :FILES)

"Parse a multipart body: fields into `req.POST`, files into `req.FILES`."
function parse_multipart_fields(req::Request)
    q = QueryDict()
    files = FileDict()
    try
        hreq = HTTP.Request(req.method, "/", collect(req.headers), req.body)
        parts = HTTP.parse_multipart_form(hreq)
        parts === nothing && return q
        for p in parts
            if p.filename === nothing
                push!(get!(q.data, p.name, String[]), String(read(p.data)))
            else
                isempty(p.filename) && continue      # an empty file input
                push!(get!(files.data, p.name, UploadedFile[]),
                      UploadedFile(p.filename, read(p.data); content_type = something(p.contenttype, "application/octet-stream")))
            end
        end
    catch
    end
    req.meta[:FILES] = files
    q
end

"Case-insensitive request header lookup."
header(req::Request, name::AbstractString, default = nothing) = get(req.headers, lowercase(name), default)

"Parse the request body as JSON."
json_body(req::Request) = JSON.parse(String(copy(req.body)))

get_host(req::Request) = get(req.headers, "host", "testserver")
is_secure(req::Request) = get(req.headers, "x-forwarded-proto", "") == "https"
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
end

function HttpResponse(content = ""; status::Integer = 200,
                      content_type = "text/html; charset=utf-8", headers = Pair{String,String}[])
    body = content isa AbstractVector{UInt8} ? Vector{UInt8}(content) : Vector{UInt8}(codeunits(string(content)))
    hs = Pair{String,String}[string(k) => string(v) for (k, v) in headers]
    any(h -> lowercase(h.first) == "content-type", hs) || pushfirst!(hs, "Content-Type" => content_type)
    HttpResponse(Int(status), hs, body, String[], nothing, String[])
end

"Response body as a `String`."
text(r::HttpResponse) = String(copy(r.body))
Base.String(r::HttpResponse) = text(r)
Base.show(io::IO, r::HttpResponse) =
    print(io, "<HttpResponse status=", r.status, " ", repr(something(getheader(r, "Content-Type"), "")), ">")

function getheader(r::HttpResponse, name::AbstractString, default = nothing)
    n = lowercase(name)
    for (k, v) in r.headers
        lowercase(k) == n && return v
    end
    default
end
function setheader!(r::HttpResponse, name::AbstractString, value)
    filter!(h -> lowercase(h.first) != lowercase(name), r.headers)
    push!(r.headers, string(name) => string(value))
    r
end
hasheader(r::HttpResponse, name) = getheader(r, name) !== nothing

"""
    set_cookie!(resp, name, value; max_age, path="/", domain, secure, httponly, samesite="Lax")
"""
function set_cookie!(r::HttpResponse, name, value; max_age = nothing, expires = nothing, path = "/",
                     domain = nothing, secure = false, httponly = false, samesite = "Lax")
    s = string(name, "=", value, "; Path=", path)
    max_age !== nothing && (s *= "; Max-Age=$(Int(max_age))")
    if expires !== nothing
        s *= "; Expires=" * http_date(expires)
    elseif max_age !== nothing
        s *= "; Expires=" * http_date(now(UTC) + Second(Int(max_age)))
    end
    domain !== nothing && (s *= "; Domain=$domain")
    secure && (s *= "; Secure")
    httponly && (s *= "; HttpOnly")
    samesite !== nothing && (s *= "; SameSite=$samesite")
    filter!(c -> !startswith(c, string(name, "=")), r.cookies)
    push!(r.cookies, s)
    r
end
delete_cookie!(r::HttpResponse, name; path = "/") =
    set_cookie!(r, name, ""; max_age = 0, expires = DateTime(1970, 1, 1), path = path)

"JSON response. `data` may be any JSON-serialisable value."
JsonResponse(data; status = 200, kw...) =
    HttpResponse(JSON.json(data); status = status, content_type = "application/json", kw...)

function HttpResponseRedirect(url; status = 302)
    r = HttpResponse(""; status = status)
    setheader!(r, "Location", url)
end
HttpResponsePermanentRedirect(url) = HttpResponseRedirect(url; status = 301)
HttpResponseNotFound(content = "<h1>Not Found</h1>") = HttpResponse(content; status = 404)
HttpResponseForbidden(content = "<h1>403 Forbidden</h1>") = HttpResponse(content; status = 403)
HttpResponseBadRequest(content = "<h1>Bad Request (400)</h1>") = HttpResponse(content; status = 400)
function HttpResponseNotAllowed(methods)
    r = HttpResponse("<h1>405 Method Not Allowed</h1>"; status = 405)
    setheader!(r, "Allow", join(methods, ", "))
end

"Coerce whatever a view returned into an `HttpResponse`."
to_response(r::HttpResponse) = r
to_response(s::AbstractString) = HttpResponse(s)
to_response(s::SafeString) = HttpResponse(s.s)
to_response(x::Union{AbstractDict,NamedTuple,AbstractVector}) = JsonResponse(x)
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
