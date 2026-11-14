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

"""
    assert_htmx(resp; redirect, refresh, location, push_url, replace_url, retarget, reswap, reselect,
                trigger, trigger_after_settle, trigger_after_swap, status)

Check the HX-* headers of a response: each keyword given must match its header exactly
(`refresh = true` for `HX-Refresh: true`). `trigger = "saved"` only needs that event among the
`HX-Trigger` events; pass a Dict to check details too.
"""
function assert_htmx(r::HttpResponse; status = nothing, kw...)
    status === nothing || r.status == status || fail("response status was $(r.status), expected $status")
    for (k, want) in kw
        name = "HX-" * join(uppercasefirst.(split(string(k), '_')), "-")
        got = getheader(r, name)
        got === nothing && fail("the response has no $name header")
        if startswith(string(k), "trigger")
            evs = startswith(strip(got), "{") ? JSON.parse(got) : Dict{String,Any}(strip(e) => nothing for e in split(got, ','))
            wanted = want isa AbstractDict ? Dict{String,Any}(string(e) => d for (e, d) in pairs(want)) :
                     Dict{String,Any}(string(e) => missing for e in (want isa Union{AbstractString,Symbol} ? [want] : want))
            for (e, d) in wanted
                haskey(evs, e) || fail("$name doesn't trigger $(repr(e)); it has $(repr(got))")
                d === missing || evs[e] == d || fail("$name gives $(repr(e)) the detail $(repr(evs[e])), expected $(repr(d))")
            end
        else
            got == (want === true ? "true" : want === false ? "false" : string(want)) || fail("$name was $(repr(got)), expected $(repr(want))")
        end
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

# --- a throwaway test database ---------------------------------------------------------------------
#
#     manage.jl test [--keepdb] [file ...]       # does this around the run
#
#     # or, in test/runtests.jl run with `julia` / `Pkg.test()`:
#     db = Juango.Testing.setup_test_database()
#     try ... include("test_models.jl") ... finally Juango.Testing.teardown_test_database(db) end
#
# The tests then never touch the development database: SQLite runs in memory, and PostgreSQL and
# MySQL get a `test_<name>` database on the same server, migrated, and dropped afterwards.

"""
    test_database_setting(setting) -> String

The test database for a database setting (`TEST_DATABASE` overrides it for the default database):
`":memory:"` for SQLite, and `test_<name>` on the same server for a PostgreSQL or MySQL URL.
"""
function test_database_setting(s)
    s isa AbstractString || throw(ImproperlyConfigured("set TEST_DATABASE: can't derive a test database from a $(typeof(s))"))
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*://[^/?]*)(?:/([^?]*))?(\?.*)?$", s)
    (m === nothing || lowercase(split(s, "://")[1]) == "sqlite") && return ":memory:"
    name = something(m[2], "")
    test = "test_" * (isempty(name) ? "juango" : name)       # always prefixed: never the database itself
    m[1] * "/" * test * something(m[3], "")
end

"The server-level connection for creating and dropping a test database: the same URL with an admin database."
function admin_database_setting(url::AbstractString)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*)(://[^/?]*)(?:/[^?]*)?(\?.*)?$", url)
    scheme = lowercase(m[1])
    m[1] * m[2] * (startswith(scheme, "postgres") ? "/postgres" : "/") * something(m[3], "")
end
test_database_name(url::AbstractString) = (m = match(r"://[^/?]*/([^?]*)", url); m === nothing ? "" : String(m[1]))

function admin_sql(admin::AbstractString, sqls)
    b = backend_from_setting(admin)
    conn = open_connection(b)
    try
        foreach(sql -> driver_rowcount(b, conn, sql, Any[]), sqls)
    finally
        close_connection(b, conn)
    end
end

struct TestDatabases
    saved::Dict{Symbol,Any}           # the settings to put back
    created::Vector{String}           # server databases to drop
    keepdb::Bool
end

"""
    setup_test_database(; keepdb = false, verbose = false) -> handle

Point the database settings at throwaway test databases (`TEST_DATABASE`, or derived: SQLite in
memory, `test_<name>` on the same PostgreSQL/MySQL server), create them, and migrate them. With
`keepdb = true` an existing test database is reused (only new migrations run) and kept afterwards.
Undo with `teardown_test_database(handle)`.
"""
function setup_test_database(; keepdb::Bool = false, verbose::Bool = false)
    saved = Dict{Symbol,Any}(:DATABASE => settings.DATABASE, :DATABASES => get(settings, :DATABASES, nothing))
    default = something(get(settings, :TEST_DATABASE, nothing), test_database_setting(settings.DATABASE))
    others = get(settings, :DATABASES, nothing)
    tests = others === nothing ? nothing :
            Dict{String,Any}(string(k) => (string(k) == "default" ? default : test_database_setting(v)) for (k, v) in pairs(others))
    if tests === nothing && default == ":memory:" && settings.DATABASE == ":memory:"     # already a throwaway database
        migrate(verbose = verbose)
        return TestDatabases(saved, String[], true)
    end
    # the test databases are dropped and created again: never one of the real ones
    real = Set(string(v) for v in vcat([settings.DATABASE], others === nothing ? Any[] : collect(values(others))))
    realnames = Set(test_database_name(u) for u in real if occursin("://", u))
    for url in vcat([default], tests === nothing ? Any[] : collect(values(tests)))
        url isa AbstractString && url != ":memory:" || continue
        (url in real || (occursin("://", url) && test_database_name(url) in realnames)) &&
            throw(ImproperlyConfigured("the test database $(repr(url)) is one of DATABASE/DATABASES; it would be dropped. Set TEST_DATABASE to another"))
    end
    created = String[]
    for url in unique(vcat([default], tests === nothing ? String[] : collect(values(tests))))
        url isa AbstractString && occursin("://", url) && !startswith(lowercase(url), "sqlite") || continue
        name = test_database_name(url)
        b = backend_from_setting(url)
        q = quote_name(b, name)
        exists = try
            close_connection(b, open_connection(b)); true
        catch
            false
        end
        if exists && keepdb
            verbose && println("Using existing test database $name")
        else
            verbose && println("Creating test database $name")
            admin_sql(admin_database_setting(url),
                      [b isa PostgresBackend ? "DROP DATABASE IF EXISTS $q WITH (FORCE)" : "DROP DATABASE IF EXISTS $q",
                       b isa MySQLBackend ? "CREATE DATABASE $q CHARACTER SET utf8mb4" : "CREATE DATABASE $q"])
        end
        push!(created, url)
    end
    close_connection!()
    tests === nothing ? configure!(DATABASE = default) : configure!(DATABASE = default, DATABASES = tests)
    migrate(verbose = verbose)
    TestDatabases(saved, created, keepdb)
end

"Drop the test databases (unless `keepdb`) and put the database settings back."
function teardown_test_database(t::TestDatabases; verbose::Bool = false)
    t.saved[:DATABASE] == settings.DATABASE && isempty(t.created) && return nothing    # nothing was swapped
    close_connection!()
    s = t.saved
    s[:DATABASES] === nothing ? (delete!(SETTINGS, :DATABASES); configure!(DATABASE = s[:DATABASE])) :
        configure!(DATABASE = s[:DATABASE], DATABASES = s[:DATABASES])
    t.keepdb && return nothing
    for url in t.created
        b = backend_from_setting(url)
        q = quote_name(b, test_database_name(url))
        verbose && println("Destroying test database $(test_database_name(url))")
        admin_sql(admin_database_setting(url), [b isa PostgresBackend ? "DROP DATABASE IF EXISTS $q WITH (FORCE)" : "DROP DATABASE IF EXISTS $q"])
    end
    nothing
end
