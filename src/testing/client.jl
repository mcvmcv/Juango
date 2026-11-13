# Test client -----------------------------------------------------------------------------------
#
#     c = Client()
#     r = get(c, "/posts/")
#     @test r.status == 200
#     r = post(c, "/posts/new/", Dict("title" => "Hi"); follow=true)

"""
    Client(; enforce_csrf=false, host="testserver")

Simulates a browser without opening a socket: keeps cookies between requests and
calls `handle_request` directly. Responses carry `context` and `templates` from
`render`.
"""
mutable struct Client
    cookies::Dict{String,String}
    enforce_csrf::Bool
    host::String
    default_headers::Dict{String,String}
end
function Client(; enforce_csrf = false, host = "testserver", headers = Dict{String,String}())
    # tests shouldn't send real mail: like Django's test runner, collect it in `Juango.outbox`
    settings.EMAIL_BACKEND === :smtp && configure!(EMAIL_BACKEND = :locmem)
    Client(Dict{String,String}(), enforce_csrf, host, Dict{String,String}(string(k) => string(v) for (k, v) in headers))
end

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
                 headers = Dict{String,String}(), follow = false, content_type = nothing, body = nothing, htmx = false)
    method = uppercase(method)
    if htmx !== false
        hx = Dict{String,String}("HX-Request" => "true")
        htmx === true || foreach(((k, v),) -> hx["HX-" * join(uppercasefirst.(split(string(k), '_')), "-")] = string(v), pairs(htmx))
        headers = merge(hx, Dict{String,String}(string(k) => string(v) for (k, v) in pairs_of(headers)))
    end
    req = make_test_request(method, target; host = c.host, default_headers = c.default_headers, cookies = c.cookies,
                            data = data, json = json, headers = headers, content_type = content_type, body = body)
    req.meta[:test_client] = true
    c.enforce_csrf || (req.meta[:dont_enforce_csrf] = true)
    resp = handle_request(req)
    store_cookies!(c, resp)
    if follow
        chain = Tuple{String,Int}[]
        while resp.status in (301, 302, 303, 307, 308) && length(chain) < 20
            loc = getheader(resp, "Location")
            push!(chain, (loc, resp.status))
            m = resp.status in (307, 308) ? method : "GET"
            resp = request(c, m, loc; data = m == "GET" ? nothing : data)
        end
        resp.context === nothing && (resp.context = Dict{String,Any}())
        resp.context isa AbstractDict && (resp.context["__redirect_chain__"] = chain)
    end
    resp
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
function force_login!(c::Client, u::AbstractUser; backend = first(auth_backends()))
    s = Session()
    s["_auth_user_id"] = u.id
    s["_auth_user_backend"] = backend_name(backend)
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

"Forget the session cookie."
logout!(c::Client) = (delete!(c.cookies, settings.SESSION_COOKIE_NAME); nothing)

"Redirect chain recorded by `follow=true`: vector of `(url, status)`."
redirect_chain(r::HttpResponse) = r.context isa AbstractDict ? get(r.context, "__redirect_chain__", Tuple{String,Int}[]) : Tuple{String,Int}[]
