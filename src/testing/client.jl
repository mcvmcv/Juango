# Test client -----------------------------------------------------------------------------------
#
#     c = Client()
#     r = get(c, "/posts/")
#     @test r.status == 200
#     r = post(c, "/posts/new/", Dict("title" => "Hi"); follow=true)

"""
    Client(; enforce_csrf = false, host = "testserver", headers = Dict(), raise_request_exception = false)

Simulates a browser without opening a socket: keeps cookies between requests and
calls `handle_request` directly. Responses carry `context` and `templates` from
`render`. With `raise_request_exception = true` an error in a view is thrown in the test
(Django's default), instead of becoming the 500 page. `c.session` is the client's session (save
it with `save_session!` after changing it), as Django's `client.session`.
"""
mutable struct Client
    cookies::Dict{String,String}
    enforce_csrf::Bool
    host::String
    default_headers::Dict{String,String}
    raise_request_exception::Bool
end
function Client(; enforce_csrf = false, host = "testserver", headers = Dict{String,String}(), raise_request_exception::Bool = false)
    # tests shouldn't send real mail: like Django's test runner, collect it in `Juango.outbox`
    settings.EMAIL_BACKEND === :smtp && configure!(EMAIL_BACKEND = :locmem)
    Client(Dict{String,String}(), enforce_csrf, host, Dict{String,String}(string(k) => string(v) for (k, v) in headers), raise_request_exception)
end
# c.session: the session of the client's cookie, or a new saved one whose cookie the client now has (Django's)
function Base.getproperty(c::Client, s::Symbol)
    s === :session || return getfield(c, s)
    key = get(getfield(c, :cookies), settings.SESSION_COOKIE_NAME, nothing)
    key === nothing || return load_session(key)
    sess = save_session!(Session())
    getfield(c, :cookies)[settings.SESSION_COOKIE_NAME] = sess.key
    sess
end

"""
A redirect chain the test client won't follow (Django's RedirectCycleError): back to a URL it has
already been to, or more than 20 redirects. `last_response` is the last redirect.
"""
struct RedirectCycleError <: Exception
    msg::String
    last_response::Any
end
Base.showerror(io::IO, e::RedirectCycleError) = print(io, "RedirectCycleError: ", e.msg)

function store_cookies!(c::Client, resp::HttpResponse)
    for sc in resp.cookies
        nv = first(split(sc, ';'))
        name, value = split(nv, '='; limit = 2)
        if occursin(r"Max-Age=0\b", sc) || occursin("Expires=Thu, 01 Jan 1970", sc)
            delete!(c.cookies, name)
        else
            c.cookies[name] = value
        end
    end
end

"A `Request` as a test client builds it (form data, JSON, files, headers and cookies)."
function make_test_request(method::AbstractString, target::AbstractString; host = "testserver", default_headers = Dict{String,String}(),
                           cookies = Dict{String,String}(), data = nothing, json = nothing, headers = Dict{String,String}(),
                           content_type = nothing, body = nothing)
    method = uppercase(method)
    hs = merge(Dict{String,String}("host" => host), default_headers,
               Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in pairs_of(headers)))
    payload = UInt8[]
    # (as Django's: a dict or list posted with a JSON content type is sent as JSON, text as it is)
    if json === nothing && data !== nothing && content_type !== nothing && !(method in ("GET", "HEAD"))
        if occursin(r"^application/(.+\+)?json"i, content_type) && (data isa AbstractDict || data isa AbstractVector || data isa Tuple || data isa NamedTuple)
            body, data = JSON.json(data), nothing
        elseif data isa Union{AbstractString,AbstractVector{UInt8}}
            body, data = data, nothing
        end
    end
    if json !== nothing
        payload = Vector{UInt8}(codeunits(JSON.json(json)))
        hs["content-type"] = "application/json"
    elseif body !== nothing
        payload = body isa AbstractString ? Vector{UInt8}(codeunits(body)) : Vector{UInt8}(body)
        content_type === nothing || (hs["content-type"] = content_type)
    elseif data !== nothing
        if method in ("GET", "HEAD", "DELETE")
            q = urlencode(data)
            isempty(q) || (target *= (occursin('?', target) ? "&" : "?") * q)
        elseif any(p -> (v = last(p); v isa UploadedFile || v isa AbstractVector && any(x -> x isa UploadedFile, v)), collect(pairs_of(data)))
            payload, ctype = multipart_body(data)
            hs["content-type"] = ctype
        else
            payload = Vector{UInt8}(codeunits(urlencode(data)))
            hs["content-type"] = "application/x-www-form-urlencoded"
        end
    end
    isempty(cookies) || (hs["cookie"] = join(["$k=$v" for (k, v) in cookies], "; "))
    Request(method, target; headers = hs, body = payload)
end

"""
    request(c::Client, method, path; data=nothing, json=nothing, headers=Dict(), follow=false, htmx=false)

`htmx = true` sends the request as htmx would (`HX-Request: true`); a NamedTuple or Dict adds
other HX-* headers too: `htmx = (target = "results", trigger = "search", boosted = true)`.
"""
function request(c::Client, method::AbstractString, target::AbstractString; data = nothing, json = nothing,
                 headers = Dict{String,String}(), follow = false, content_type = nothing, body = nothing, htmx = false,
                 query_params = nothing, host = nothing)
    method = uppercase(method)
    # (Django 5.1's query_params: the query string for any method)
    if query_params !== nothing
        method in ("GET", "HEAD") && data !== nothing && throw(ArgumentError("query_params and data arguments are mutually exclusive."))
        q = urlencode(query_params)
        isempty(q) || (target *= (occursin('?', target) ? "&" : "?") * q)
    end
    if htmx !== false
        hx = Dict{String,String}("HX-Request" => "true")
        htmx === true || foreach(((k, v),) -> hx["HX-" * join(uppercasefirst.(split(string(k), '_')), "-")] = string(v), pairs(htmx))
        headers = merge(hx, Dict{String,String}(string(k) => string(v) for (k, v) in pairs_of(headers)))
    end
    req = make_test_request(method, target; host = something(host, c.host), default_headers = c.default_headers, cookies = c.cookies,
                            data = data, json = json, headers = headers, content_type = content_type, body = body)
    req.meta[:test_client] = true
    c.raise_request_exception && (req.meta[:raise_request_exception] = true)
    c.enforce_csrf || (req.meta[:dont_enforce_csrf] = true)
    resp = handle_request(req)
    # a stream of known length (FileResponse) is read now, so resp.body has it; endless ones
    # (server-sent events) stay streams until text(r) or consume_stream!(r)
    is_streaming(resp) && getheader(resp, "Content-Length") !== nothing && consume_stream!(resp)
    store_cookies!(c, resp)
    if follow
        chain = Tuple{String,Int}[]
        path = first(split(target, '?'))
        while resp.status in (301, 302, 303, 307, 308)
            loc = getheader(resp, "Location")
            push!(chain, (loc, resp.status))
            # (as Django's: an absolute URL's host is the next request's; a relative one is joined to the path)
            m_ = match(r"^(?:[A-Za-z][A-Za-z0-9+.\-]*:)?//([^/?#]*)(.*)$", loc)
            h, rest = m_ === nothing ? (nothing, loc) : (m_[1], isempty(m_[2]) ? "/" : m_[2])
            startswith(rest, "/") || startswith(rest, "?") || (rest = join_relative(path, rest))
            startswith(rest, "?") && (rest = path * rest)
            m = resp.status in (307, 308) ? method : "GET"
            next_ = first(split(rest, '?'))
            resp = request(c, m, rest; data = m in ("GET", "HEAD") ? nothing : data, host = h === nothing || isempty(h) ? nothing : h,
                           content_type = m in ("GET", "HEAD") ? nothing : content_type, json = m in ("GET", "HEAD") ? nothing : json)
            path = next_
            last(chain) in chain[1:end-1] && throw(RedirectCycleError("Redirect loop detected.", resp))
            length(chain) > 20 && throw(RedirectCycleError("Too many redirects.", resp))
        end
        resp.context === nothing && (resp.context = Dict{String,Any}())
        resp.context isa AbstractDict && (resp.context["__redirect_chain__"] = chain)
    end
    resp
end
"A relative URL joined to a path, as urljoin does: `join_relative(\"/a/b/c\", \"../d\") == \"/a/d\"`."
function join_relative(base::AbstractString, rel::AbstractString)
    q = findfirst('?', rel)
    p, query = q === nothing ? (rel, "") : (rel[1:prevind(rel, q)], rel[q:end])
    segs = split(base, '/')[1:end-1]                  # (the directory of the base)
    for s in split(p, '/')
        s == "." ? nothing : s == ".." ? (length(segs) > 1 && pop!(segs)) : push!(segs, s)
    end
    j = join(segs, '/')
    (endswith(p, "/.") || endswith(p, "/..") || p in (".", "..")) && (j *= "/")
    (startswith(j, "/") ? j : "/" * j) * query
end

"Encode form data (with `UploadedFile` values) as multipart/form-data."
function multipart_body(data)
    boundary = "----JuangoBoundary" * random_string(16)
    io = IOBuffer()
    for (k, v) in pairs_of(data)
        for x in (v isa AbstractVector ? v : [v])
            print(io, "--", boundary, "\r\n")
            if x isa UploadedFile
                print(io, "Content-Disposition: form-data; name=\"", k, "\"; filename=\"", x.name, "\"\r\n")
                print(io, "Content-Type: ", x.content_type, "\r\n\r\n")
                write(io, x.data)
            else
                print(io, "Content-Disposition: form-data; name=\"", k, "\"\r\n\r\n", x)
            end
            print(io, "\r\n")
        end
    end
    print(io, "--", boundary, "--\r\n")
    take!(io), "multipart/form-data; boundary=" * boundary
end

"GET request with the test client: `get(client, \"/path\"; data=Dict(...))`."
Base.get(c::Client, path::AbstractString; kw...) = request(c, "GET", path; kw...)
"POST request with the test client: `post(client, \"/path\", Dict(\"field\" => \"value\"))`."
post(c::Client, path::AbstractString, data = Dict{String,Any}(); kw...) = request(c, "POST", path; data = data, kw...)

"Log a user in without a password check (creates a session and sets the cookie)."
function force_login!(c::Client, u::AbstractUser; backend = nothing)
    s = Session()
    s["_auth_user_id"] = u.id
    # (the backend that authenticated the user, or the first, as Django's Client.force_login)
    s["_auth_user_backend"] = backend isa AbstractString ? String(backend) : backend !== nothing ? backend_name(backend) :
        get(getfield(u, :_cache)::Dict{Symbol,Any}, :__auth_backend, backend_name(first(auth_backends())))
    s["_auth_user_hash"] = session_auth_hash(u)
    save_session!(s)
    c.cookies[settings.SESSION_COOKIE_NAME] = s.key
    u
end

"Authenticate with username/password and log the client in. Returns `true` on success."
function login!(c::Client; username, password)
    u = authenticate(username, password)
    u === nothing && return false
    force_login!(c, u)
    true
end

"""
Log the client out, as Django's `Client.logout`: the user is logged out of the session (which is
emptied, and `user_logged_out` sent), and the client forgets all its cookies.
"""
function logout!(c::Client)
    key = get(c.cookies, settings.SESSION_COOKIE_NAME, nothing)
    req = make_test_request("GET", "/"; host = c.host)
    req.session = key === nothing ? Session() : load_session(key)
    req.user = get_user(req)
    logout!(req)
    empty!(c.cookies)
    nothing
end

"Redirect chain recorded by `follow=true`: vector of `(url, status)`."
redirect_chain(r::HttpResponse) = r.context isa AbstractDict ? get(r.context, "__redirect_chain__", Tuple{String,Int}[]) : Tuple{String,Int}[]
