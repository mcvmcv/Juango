# Testing helpers ---------------------------------------------------------------------------------------
#
#     @testset "posts" begin
#         rollback_after() do                          # like Django's TestCase: changes are undone
#             create(Post; title = "x")
#             override_settings(DEBUG = false) do
#                 r = get(Client(), "/posts/")
#                 @test assert_contains(r, "x")
#                 @test assert_template_used(r, "posts/list.html")
#             end
#         end
#     end

struct RollbackTest <: Exception end

"""
    rollback_after(f)

Run `f()` in a transaction that is rolled back afterwards, so the test leaves the database
as it found it (like Django's `TestCase`). Returns `f()`'s value. `Client` requests made
inside see the changes (they run in the same task and transaction); code that starts other
tasks doesn't. Transactions inside become savepoints.
"""
function rollback_after(f)
    result = Ref{Any}(nothing)
    try
        atomic() do
            result[] = f()
            throw(RollbackTest())
        end
    catch e
        e isa RollbackTest || rethrow()
    end
    result[]
end

"""
    capture_on_commit_callbacks(f; execute = false) -> (result, callbacks)

Run `f()` and return the `on_commit` callbacks it registered (like Django's
`captureOnCommitCallbacks`). Inside `rollback_after` the transaction never commits, so this
is how a test checks or runs them; with `execute = true` they are called (and removed).
"""
function capture_on_commit_callbacks(f; execute::Bool = false)
    h = commit_holder()
    n = length(h.hooks)
    r = f()
    new = h.hooks[n+1:end]
    execute && (resize!(h.hooks, n); foreach(run_hook, new))
    r, Any[k.f for k in new]
end

"""
A running live test server (see `with_live_server`): `url` is `http://host:port`.
"""
struct LiveServer
    url::String
    host::String
    port::Int
    server::Any
end
Base.show(io::IO, s::LiveServer) = print(io, "LiveServer(", s.url, ")")

const LIVE_SERVER_URL = Ref{Union{Nothing,String}}(nothing)

"A free TCP port on `host` (the OS picks one)."
function free_port(host = "127.0.0.1")
    s = Sockets.listen(Sockets.getaddrinfo(host), 0)
    port = Int(Sockets.getsockname(s)[2])
    close(s)
    port
end

"""
    with_live_server(f; host = "127.0.0.1", port = 0, static = true)

Run the app on a real HTTP server for the duration of `f(server)`, like Django's
`LiveServerTestCase`, for browser automation or any external HTTP client. `port = 0` picks a
free port; `server.url` (also `live_server_url()`) is the address. With `static = true`
static files are served even when `DEBUG` is off (`StaticLiveServerTestCase`), and `host` is
added to `ALLOWED_HOSTS` for the block.

The server answers requests in other tasks, so on PostgreSQL and MySQL it sees only
committed data: create test data outside `rollback_after` (and clean up afterwards).

    with_live_server() do s
        r = HTTP.get(s.url * "/articles/")
        @test r.status == 200
    end
"""
function with_live_server(f; host::AbstractString = "127.0.0.1", port::Integer = 0, static::Bool = true)
    port == 0 && (port = free_port(host))
    hosts = settings.ALLOWED_HOSTS
    extra = "*" in hosts || host in hosts ? nothing : vcat(hosts, String[host])
    server = runserver(host, port; block = false, quiet = true)
    url = "http://" * (occursin(':', host) ? "[$host]" : host) * ":$port"
    old_static, old_url = LIVE_SERVER_STATIC[], LIVE_SERVER_URL[]
    LIVE_SERVER_STATIC[] = static
    LIVE_SERVER_URL[] = url
    try
        extra === nothing ? f(LiveServer(url, host, port, server)) :
            override_settings(() -> f(LiveServer(url, host, port, server)); ALLOWED_HOSTS = extra)
    finally
        LIVE_SERVER_STATIC[], LIVE_SERVER_URL[] = old_static, old_url
        close(server)
    end
end

"The address of the running `with_live_server` server (`nothing` outside one)."
live_server_url() = LIVE_SERVER_URL[]

"""
    override_settings(f; settings...)

Run `f()` with some settings changed, and put them back afterwards (even if it throws).
"""
function override_settings(f; kw...)
    saved = Dict{Symbol,Any}()
    missing_ = Symbol[]
    for (k, _) in kw
        haskey(SETTINGS, k) ? (saved[k] = SETTINGS[k]) : push!(missing_, k)
    end
    configure!(; kw...)
    try
        f()
    finally
        foreach(k -> delete!(SETTINGS, k), missing_)
        configure!(; saved...)
    end
end

"""
    RequestFactory(; host = "testserver", headers = Dict())

Builds requests for calling a view directly, without middleware or URL routing:

    rf = RequestFactory()
    req = get(rf, "/posts/"; data = Dict("page" => 2))
    req.user = some_user
    resp = post_list(req)

Requests have an `AnonymousUser`, an empty session and CSRF checks turned off.
"""
struct RequestFactory
    host::String
    headers::Dict{String,String}
end
RequestFactory(; host = "testserver", headers = Dict{String,String}()) =
    RequestFactory(host, Dict{String,String}(lowercase(string(k)) => string(v) for (k, v) in headers))

function request(rf::RequestFactory, method::AbstractString, path::AbstractString; kw...)
    req = make_test_request(method, path; host = rf.host, default_headers = rf.headers, kw...)
    req.user = AnonymousUser()
    req.session = Session()
    req.meta[:dont_enforce_csrf] = true
    req.resolver_match = resolve(req.path)
    req
end
Base.get(rf::RequestFactory, path::AbstractString; kw...) = request(rf, "GET", path; kw...)
post(rf::RequestFactory, path::AbstractString, data = Dict{String,Any}(); kw...) = request(rf, "POST", path; data = data, kw...)

# --- assertions -----------------------------------------------------------------------------------
#
# Each returns `true` or throws an `AssertionError` that says what was wrong, so `@test assert_...(...)`
# reports a useful message.

fail(msg) = throw(AssertionError(msg))

function response_text(r::HttpResponse)
    t = text(r)
    t isa AbstractString ? t : String(r.body)
end

"""
    assert_contains(resp, text; count = nothing, status = 200, html = false)

The response has `status` and contains `text` (exactly `count` times, if given). With
`html = true` the comparison ignores whitespace between tags.
"""
function assert_contains(r::HttpResponse, needle::AbstractString; count = nothing, status = 200, html = false)
    r.status == status || fail("response status was $(r.status), expected $status")
    hay = response_text(r)
    norm(s) = html ? replace(strip(s), r">\s+<" => "><", r"\s+" => " ") : s
    hay, needle = norm(hay), norm(needle)
    n = length(findall(needle, hay; overlap = false))
    if count === nothing
        n > 0 || fail("couldn't find $(repr(needle)) in the response")
    else
        n == count || fail("found $(repr(needle)) $n time(s) in the response, expected $count")
    end
    true
end

"The response has `status` and doesn't contain `text`."
function assert_not_contains(r::HttpResponse, needle::AbstractString; status = 200, html = false)
    r.status == status || fail("response status was $(r.status), expected $status")
    hay = response_text(r)
    if html
        hay, needle = replace(hay, r">\s+<" => "><"), replace(needle, r">\s+<" => "><")
    end
    occursin(needle, hay) && fail("found $(repr(needle)) in the response")
    true
end

"""
    assert_redirects(resp, url; status = 302, target_status = 200, client = nothing)

The response redirects to `url` with `status`. With a `client`, the target is fetched too
and must answer `target_status`.
"""
function assert_redirects(r::HttpResponse, url::AbstractString; status = 302, target_status = 200, client = nothing)
    r.status == status || fail("response status was $(r.status), expected a $status redirect")
    loc = getheader(r, "Location")
    loc == url || fail("redirected to $(repr(loc)), expected $(repr(url))")
    if client !== nothing
        t = get(client, url)
        t.status == target_status || fail("the redirect target $url answered $(t.status), expected $target_status")
    end
    true
end

"The response was rendered with template `name` (by `render`)."
function assert_template_used(r::HttpResponse, name::AbstractString)
    name in r.templates || fail("template $(repr(name)) wasn't used; used: $(isempty(r.templates) ? "none" : join(repr.(r.templates), ", "))")
    true
end
function assert_template_not_used(r::HttpResponse, name::AbstractString)
    name in r.templates && fail("template $(repr(name)) was used")
    true
end

"""
    assert_num_queries(f, n)

`f()` runs exactly `n` SQL statements. Returns `true` (the value of `f()` is discarded).
"""
function assert_num_queries(f, n::Integer)
    _, got = count_queries(f)
    got == n || fail("$got queries were run, expected $n")
    true
end

"""
    assert_form_error(form, field, errors)

The form (bound and validated) has exactly these errors for `field` (`nothing` for the
form-wide errors). `errors` is a message or a list of them; `[]` means no errors.
"""
function assert_form_error(form::Form, field, errors)
    is_valid(form)
    want = errors isa AbstractString ? [errors] : collect(String, errors)
    got = get(form.errors, field === nothing ? :__all__ : Symbol(field), String[])
    got == want || fail("$(field === nothing ? "form-wide" : "field '$field'") errors were $(repr(got)), expected $(repr(want))")
    true
end
