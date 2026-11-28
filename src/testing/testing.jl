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
            # durable atomic blocks inside are allowed (as in Django's TestCase)
            tls = task_local_storage()
            old = get(tls, :juango_test_atomic_depth, nothing)
            tls[:juango_test_atomic_depth] = commit_holder().depth
            try
                result[] = f()
            finally
                old === nothing ? delete!(tls, :juango_test_atomic_depth) : (tls[:juango_test_atomic_depth] = old)
            end
            throw(RollbackTest())
        end
    catch e
        e isa RollbackTest || rethrow()
    end
    result[]
end

"""
    serialize_database(; database = nothing) -> String

The data in every table of the database's models, as JSON (Django's `serialize_db_to_string`, which the test
runner calls after migrating). `deserialize_database!` puts it back.
"""
function serialize_database(; database = nothing)
    with_db(database) do
        b = backend()
        models = [T for T in all_models() if !modelmeta(T).proxy && model_in_use(T) && !(T <: AutoThrough) &&
                                             table_exists(b, modelmeta(T).table)]
        objs = Any[]
        for T in dependency_order(models)
            append!(objs, collect(order_by(base_objects(T), "pk")))
        end
        serialize(:json, objs)
    end
end

"""
    deserialize_database!(data; database = nothing) -> Int

Load what `serialize_database` returned, in one transaction, as `loaddata` does (Django's
`deserialize_db_from_string`). Returns the number of objects.
"""
function deserialize_database!(data::AbstractString; database = nothing)
    path, io = mktemp(); close(io)
    json = path * ".json"
    mv(path, json)
    try
        write(json, data)
        loaddata(json; database = database)
    finally
        rm(json; force = true)
    end
end

"""
    serialized_rollback(f; database = nothing)

Run `f()`, which may commit and may empty the database (`flush!`), then put the data back as it was before:
the database is flushed and its earlier data loaded again (Django's `TransactionTestCase` with
`serialized_rollback = True`, which keeps the data that migrations loaded). Returns `f()`'s value.

    serialized_rollback() do
        flush!()
        with_live_server() do ... end      # (committed data, seen by other connections)
    end
    count(objects(Book))                   # the books from before, again
"""
function serialized_rollback(f; database = nothing)
    data = serialize_database(; database = database)
    try
        f()
    finally
        with_db(() -> flush!(; inhibit_post_migrate = true), database)   # (the content types come back with the data)
        deserialize_database!(data; database = database)
        with_db(() -> lock(() -> empty!(CT_CACHE), CT_LOCK), database)
    end
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
free port; `server.url` (also `live_server_url()`) is the address. Uploads (MEDIA_ROOT) are served; with
`static = true` static files are found as in DEBUG (`StaticLiveServerTestCase`), without it only the collected
STATIC_ROOT is served (`LiveServerTestCase`). `host` is added to `ALLOWED_HOSTS` for the block.

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
    old_static, old_url, old_running = LIVE_SERVER_STATIC[], LIVE_SERVER_URL[], LIVE_SERVER_RUNNING[]
    LIVE_SERVER_STATIC[] = static
    LIVE_SERVER_URL[] = url
    LIVE_SERVER_RUNNING[] = true
    try
        extra === nothing ? f(LiveServer(url, host, port, server)) :
            override_settings(() -> f(LiveServer(url, host, port, server)); ALLOWED_HOSTS = extra)
    finally
        LIVE_SERVER_STATIC[], LIVE_SERVER_URL[], LIVE_SERVER_RUNNING[] = old_static, old_url, old_running
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
    explicit = Set{Symbol}(k for (k, _) in kw if k in EXPLICIT_SETTINGS)
    for (k, _) in kw
        haskey(SETTINGS, k) ? (saved[k] = SETTINGS[k]) : push!(missing_, k)
    end
    try
        configure!(; kw...)        # (inside: settings refused halfway are put back too)
        f()
    finally
        for (k, _) in kw
            k in explicit || delete!(EXPLICIT_SETTINGS, k)
        end
        foreach(k -> delete!(SETTINGS, k), missing_)
        apply_settings!(saved, false)
        if any_receivers(setting_changed)
            foreach(k -> send(setting_changed, :settings; setting = k, value = nothing, enter = false), missing_)
        end
    end
end

"""
    modify_settings(f; NAME = (append = items, prepend = items, remove = items), ...)

Run `f()` with list settings changed, as Django's `modify_settings`: each operation, in the order
given, appends or prepends the items not already there, or removes them (a single item or a list).
The list is the setting's value when `modify_settings` runs, so it can be nested in
`override_settings`.

    modify_settings(MIDDLEWARE = (append = MyMiddleware, remove = [CsrfViewMiddleware])) do ... end
"""
function modify_settings(f; kw...)
    changes = Dict{Symbol,Any}()
    for (name, ops) in kw
        value = Any[x for x in something(get(settings, name, Any[]), Any[])]
        for (action, items) in pairs(ops)
            items = items isa Union{AbstractVector,Tuple} ? collect(Any, items) : Any[items]
            a = Symbol(action)
            if a === :append
                append!(value, [x for x in items if !(x in value)])
            elseif a === :prepend
                value = vcat(Any[x for x in items if !(x in value)], value)
            elseif a === :remove
                value = Any[x for x in value if !(x in items)]
            else
                throw(ArgumentError("Unsupported action: $action"))
            end
        end
        changes[name] = value
    end
    override_settings(f; changes...)
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
    req.resolver_match = resolve(req.path_info)
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

prefix(msg_prefix) = isempty(msg_prefix) ? "" : msg_prefix * ": "

"""
    assert_contains(resp, text; count = nothing, status = 200, html = false, msg_prefix = "")

The response has `status` and contains `text` (exactly `count` times, if given). With
`html = true` both are compared as HTML (see `assert_html_equal`). Failures read as Django's, after
`msg_prefix: `.
"""
function assert_contains(r::HttpResponse, needle::AbstractString; count = nothing, status = 200, html = false, msg_prefix = "")
    p = prefix(msg_prefix)
    r.status == status || fail(p * "Couldn't retrieve content: Response code was $(r.status) (expected $status)")
    hay = response_text(r)
    n = html ? count_html(parse_html_arg(needle, "First"), parse_html_arg(hay, "Second")) : length(findall(needle, hay; overlap = false))
    if count === nothing
        n > 0 || fail(p * "Couldn't find $(repr(needle)) in the following response\n$(repr(hay))")
    else
        n == count || fail(p * "Found $n instances of $(repr(needle)) in response (expected $count)")
    end
    true
end

"The response has `status` and doesn't contain `text`."
function assert_not_contains(r::HttpResponse, needle::AbstractString; status = 200, html = false, msg_prefix = "")
    p = prefix(msg_prefix)
    r.status == status || fail(p * "Couldn't retrieve content: Response code was $(r.status) (expected $status)")
    hay = response_text(r)
    found = html ? count_html(parse_html_arg(needle, "First"), parse_html_arg(hay, "Second")) > 0 : occursin(needle, hay)
    found && fail(p * "$(repr(needle)) unexpectedly found in the following response\n$(repr(hay))")
    true
end

"A URL as the test client sees it: `http://testserver/x/` is `/x/` (Django's assertRedirects compares them so)."
local_url(u, host = "testserver") = (m = match(Regex("^https?://\\Q$(host)\\E(?=/|\$|\\?)"), u); m === nothing ? String(u) : (rest = u[ncodeunits(m.match)+1:end]; isempty(rest) ? "/" : rest))

"""
    assert_redirects(resp, url; status = 302, target_status = 200, client = nothing, msg_prefix = "")

The response redirects to `url` with `status` (`http://testserver/x/` and `/x/` are the same URL). With a
`client`, the target is fetched too and must answer `target_status`. For a response from
`get(c, url; follow = true)`, the redirect chain is checked: its first step's status and its last URL.
"""
function assert_redirects(r::HttpResponse, url::AbstractString; status = 302, target_status = 200, client = nothing, msg_prefix = "",
                          status_code = nothing, target_status_code = nothing)
    status = something(status_code, status)                       # (Django's names too)
    target_status = something(target_status_code, target_status)
    p = prefix(msg_prefix)
    chain = redirect_chain(r)
    if !isempty(chain)
        chain[1][2] == status || fail(p * "Initial response didn't redirect as expected: Response code was $(chain[1][2]) (expected $status)")
        loc = chain[end][1]
        r.status == target_status || fail(p * "Response didn't redirect as expected: Final Response code was $(r.status) (expected $target_status)")
    else
        r.status == status || fail(p * "Response didn't redirect as expected: Response code was $(r.status) (expected $status)")
        loc = getheader(r, "Location")
    end
    local_url(something(loc, "")) == local_url(url) || fail(p * "Response redirected to '$loc', expected '$url'")
    if client !== nothing && isempty(chain)
        t = get(client, local_url(url))
        t.status == target_status || fail(p * "Couldn't retrieve redirection page '$url': response code was $(t.status) (expected $target_status)")
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

"The response was rendered with template `name` (by `render`; exactly `count` times, if given), as Django's assertTemplateUsed."
function assert_template_used(r::HttpResponse, name::AbstractString; count = nothing, msg_prefix = "")
    p = prefix(msg_prefix)
    isempty(r.templates) && fail(p * "No templates used to render the response")
    name in r.templates || fail(p * "Template '$name' was not a template used to render the response. Actual template(s) used: $(join(r.templates, ", "))")
    n = Base.count(==(name), r.templates)
    count === nothing || n == count || fail(p * "Template '$name' was expected to be rendered $count time(s) but was actually rendered $n time(s).")
    true
end
function assert_template_not_used(r::HttpResponse, name::AbstractString; msg_prefix = "")
    name in r.templates && fail(prefix(msg_prefix) * "Template '$name' was used unexpectedly in rendering the response")
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

# --- HTML compared as Django's assertHTMLEqual ----------------------------------------------------
#
# Both sides are parsed into a tree: whitespace between and around tags is ignored and runs of it
# inside text count as one space, attributes compare in any order (and `class` in any token order),
# `<br>` equals `<br/>`, character references are decoded, and comments are left out.

const VOID_ELEMENTS = Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"])

struct HtmlElement
    tag::String
    attrs::Vector{Pair{String,String}}      # sorted; a boolean attribute has the value ""
    children::Vector{Any}                   # HtmlElement and String
end

"Character references and named entities decoded (Python's html.unescape, as Django's parser)."
decode_entities(s::AbstractString) = html_unescape(s)

"HTML's boolean attributes, as Django's: `checked`, `checked=\"\"` and `checked=\"checked\"` are the same."
const BOOLEAN_ATTRIBUTES = Set(["allowfullscreen", "async", "autofocus", "autoplay", "checked", "controls", "default", "defer", "disabled",
                                "formnovalidate", "hidden", "ismap", "itemscope", "loop", "multiple", "muted", "nomodule", "novalidate",
                                "open", "playsinline", "readonly", "required", "reversed", "selected", "truespeed"])
"HTML that isn't well formed (a stray end tag), as Django's HTMLParseError: `msg` says where."
struct HTMLParseError <: Exception
    msg::String
end
Base.showerror(io::IO, e::HTMLParseError) = print(io, "HTMLParseError: ", e.msg)

"Parse HTML into a list of nodes (HtmlElement and text), normalised for comparison."
function parse_html(s::AbstractString)
    root = HtmlElement("", Pair{String,String}[], Any[])
    stack = HtmlElement[root]
    i = firstindex(s)
    rx_tag = r"\G<(/?)([A-Za-z][A-Za-z0-9:-]*)((?:\s+[^\s\"'>/=]+(?:\s*=\s*(?:\"[^\"]*\"|'[^']*'|[^\s\"'=<>`]+))?)*)\s*(/?)>"s
    rx_attr = r"([^\s\"'>/=]+)(?:\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+)))?"
    text = IOBuffer()
    flush_text!() = (t = String(take!(text)); isempty(t) || push!(stack[end].children, stack[end].tag in ("script", "style") ? t : decode_entities(t)))
    while i <= lastindex(s)
        if s[i] == '<'
            if !isempty(stack) && stack[end].tag in ("script", "style")     # raw text up to its end tag, as Django's
                j = findnext(Regex("</" * stack[end].tag * "\\s*>", "i"), s, i)
                if j !== nothing && first(j) != i
                    write(text, SubString(s, i, prevind(s, first(j))))
                    i = first(j)
                    continue
                end
            end
            if startswith(SubString(s, i), "<!--")
                j = findnext("-->", s, i)
                i = j === nothing ? lastindex(s) + 1 : last(j) + 1
                continue
            elseif startswith(SubString(s, i), "<!")                # doctype
                j = findnext('>', s, i)
                i = j === nothing ? lastindex(s) + 1 : j + 1
                continue
            end
            m = match(rx_tag, s, i)
            if m !== nothing
                flush_text!()
                tag = lowercase(m[2])
                if m[1] == "/"
                    k = findlast(e -> e.tag == tag, stack)
                    if k === nothing || k == 1
                        line = count(==('\n'), SubString(s, firstindex(s), prevind(s, i))) + 1
                        ls = findprev('\n', s, prevind(s, i))
                        col = length(SubString(s, ls === nothing ? firstindex(s) : nextind(s, ls), prevind(s, i)))
                        throw(HTMLParseError("Unexpected end tag `$tag` (Line $line, Column $col)"))
                    end
                    resize!(stack, k - 1)
                else
                    attrs = Pair{String,String}[]
                    for a in eachmatch(rx_attr, m[3])
                        name = lowercase(a[1])
                        v = decode_entities(something(a[2], a[3], a[4], ""))
                        name == "class" && (v = join(sort(split(v)), " "))
                        name in BOOLEAN_ATTRIBUTES && v == name && (v = "")      # (checked="checked" is checked)
                        push!(attrs, name => v)
                    end
                    el = HtmlElement(tag, sort!(attrs; by = first), Any[])
                    push!(stack[end].children, el)
                    (m[4] == "/" || tag in VOID_ELEMENTS) || push!(stack, el)
                end
                i += ncodeunits(m.match)
                continue
            end
        end
        write(text, s[i])
        i = nextind(s, i)
    end
    flush_text!()
    normalize_html!(root)
    root.children
end

const ASCII_WS = (' ', '\t', '\n', '\f', '\r')
"Whitespace as in rendered HTML: runs of it count as one space, and none around tags."
function normalize_html!(el::HtmlElement)
    out = Any[]
    for c in el.children
        if c isa AbstractString
            t = replace(c, r"[ \t\n\f\r]+" => " ")       # (ASCII whitespace only, as Django's: &nbsp; stays)
            isempty(strip(t, ASCII_WS)) && continue
            if !isempty(out) && out[end] isa String
                out[end] *= t
            else
                push!(out, t)
            end
        else
            normalize_html!(c)
            push!(out, c)
        end
    end
    for k in eachindex(out)
        out[k] isa AbstractString && (out[k] = String(strip(out[k], ASCII_WS)))   # (a String: count_html matches text by type)
    end
    empty!(el.children)
    append!(el.children, out)
    el
end

html_canonical(io::IO, t::AbstractString) = print(io, replace(t, '&' => "&amp;", '<' => "&lt;", '>' => "&gt;"))   # (text "<br>" isn't a <br>)
function html_canonical(io::IO, el::HtmlElement)
    print(io, "<", el.tag)
    for (k, v) in el.attrs
        print(io, " ", k, "=", repr(v))
    end
    print(io, ">")
    foreach(c -> html_canonical(io, c), el.children)
    el.tag in VOID_ELEMENTS || print(io, "</", el.tag, ">")
end
html_canonical(nodes::Vector) = sprint(io -> foreach(n -> html_canonical(io, n), nodes))

"""
    assert_html_equal(a, b)    assert_html_not_equal(a, b)

The two HTML strings are (aren't) the same document, as Django's `assertHTMLEqual`: whitespace
between tags, attribute order and class order don't matter, and `<br>` equals `<br/>`.
"""
function parse_html_arg(x, which)
    try
        parse_html(x)
    catch e
        e isa HTMLParseError || rethrow()
        fail("$which argument is not valid HTML:\n$(e.msg)")
    end
end
function assert_html_equal(a::AbstractString, b::AbstractString)
    ca, cb = html_canonical(parse_html_arg(a, "First")), html_canonical(parse_html_arg(b, "Second"))
    ca == cb || fail("the HTML differs:\n  $ca\n  $cb")
    true
end
function assert_html_not_equal(a::AbstractString, b::AbstractString)
    html_canonical(parse_html_arg(a, "First")) == html_canonical(parse_html_arg(b, "Second")) && fail("the HTML is the same: $(html_canonical(parse_html(a)))")
    true
end

"How many times the nodes of `needle` appear, in a row, among the children of some element of `hay`."
function count_html(needle::Vector, hay::Vector)
    want = [html_canonical(Any[n]) for n in needle]
    isempty(want) && return 0
    n = 0
    walk(nodes) = begin
        keys_ = [html_canonical(Any[c]) for c in nodes]
        for k in 1:length(keys_)-length(want)+1
            keys_[k:k+length(want)-1] == want && (n += 1)
        end
        # a text needle also matches inside a longer text (as Django, which looks for it in text nodes)
        if length(want) == 1 && needle[1] isa String
            for c in nodes
                c isa String && c != needle[1] && (n += length(findall(needle[1], c)))
            end
        end
        foreach(c -> c isa HtmlElement && walk(c.children), nodes)
    end
    walk(hay)
    n
end

"A string as Python's repr shows it (Django's assertion messages): in single quotes, or double when it has a single one."
function pyrepr(x::AbstractString)
    esc(t) = replace(t, "\\" => "\\\\", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r")
    occursin('\'', x) && !occursin('"', x) ? "\"" * esc(x) * "\"" : "'" * replace(esc(x), "'" => "\\'") * "'"
end

"""
    assert_in_html(needle, hay; count = nothing, msg_prefix = "")    assert_not_in_html(needle, hay; msg_prefix = "")

`needle` (HTML) appears in `hay` (HTML or a response), compared as `assert_html_equal` does
(exactly `count` times when given), or doesn't, as Django's `assertInHTML` and `assertNotInHTML`.
"""
function assert_in_html(needle::AbstractString, hay; count = nothing, msg_prefix = "")
    h = hay isa HttpResponse ? response_text(hay) : String(hay)
    n = count_html(parse_html_arg(needle, "First"), parse_html_arg(h, "Second"))
    where_ = " in the following response\n" * pyrepr(h)
    if count === nothing
        n > 0 || fail(prefix(msg_prefix) * "Couldn't find $(pyrepr(needle))" * where_)
    else
        n == count || fail(prefix(msg_prefix) * "Found $n instances of $(pyrepr(needle)) (expected $count)" * where_)
    end
    true
end
function assert_not_in_html(needle::AbstractString, hay; msg_prefix = "")
    h = hay isa HttpResponse ? response_text(hay) : String(hay)
    count_html(parse_html_arg(needle, "First"), parse_html_arg(h, "Second")) == 0 ||
        fail(prefix(msg_prefix) * "$(pyrepr(needle)) unexpectedly found in the following response\n" * pyrepr(h))
    true
end

"""
    assert_json_equal(raw, expected)    assert_json_not_equal(raw, expected)

`raw` (a JSON string, or a response) decodes to `expected`, itself a JSON string or a value:
object key order and number formatting don't matter.
"""
function json_arg(x, which)
    try
        json_value(x)
    catch e
        e isa InterruptException && rethrow()
        fail("$which argument is not valid JSON: $(x isa AbstractString ? repr(x) : x)")
    end
end
function assert_json_equal(raw, expected)
    a, b = json_arg(raw, "First"), json_arg(expected, "Second")
    isequal(a, b) || fail("the JSON differs:\n  $(JSON.json(a))\n  $(JSON.json(b))")
    true
end
function assert_json_not_equal(raw, expected)
    isequal(json_arg(raw, "First"), json_arg(expected, "Second")) && fail("the JSON is the same: $(JSON.json(json_value(raw)))")
    true
end
json_value(r::HttpResponse) = json_value(response_text(r))
json_value(s::AbstractString) = plainjson(JSON.parse(s))
json_value(x) = plainjson(JSON.parse(JSON.json(x)))

"""
    assert_queryset_equal(qs, values; transform = identity, ordered = true)

`[transform(x) for x in qs]` equals `values`; with `ordered = false`, in any order. As Django's
`assertQuerySetEqual`. An unordered queryset compared with `ordered = true` is an error, since
its order isn't defined.
"""
function assert_queryset_equal(qs, values; transform = identity, ordered::Bool = true)
    # (as Django's: comparing an unordered queryset with more than one value in order is an error; one value is fine)
    if ordered && qs isa QuerySet && isempty(qs.order) && isempty(modelmeta(model_of(qs)).ordering) && length(values) > 1
        throw(ArgumentError("Trying to compare non-ordered queryset against more than one ordered value."))
    end
    got = Any[transform(x) for x in qs]
    want = collect(Any, values)
    ok = ordered ? isequal(got, want) : (length(got) == length(want) && isequal(countmap_any(got), countmap_any(want)))
    ok || fail("the queryset gave $(repr(got)), expected $(repr(want))$(ordered ? "" : " (in any order)")")
    true
end
countmap_any(xs) = (d = Dict{Any,Int}(); foreach(x -> (d[x] = get(d, x, 0) + 1), xs); d)

"""
    assert_formset_error(formset, form_index, field, errors)

The formset (validated) has exactly these errors: on form `form_index` (1-based) for `field`
(`nothing` for that form's form-wide errors), or with `form_index = nothing`, its non-form errors
(`assert_formset_error(fs, nothing, errors)` for short).
"""
assert_formset_error(fs::FormSet, ::Nothing, errors) = assert_formset_error(fs, nothing, nothing, errors)
function assert_formset_error(fs::FormSet, form_index, field, errors)
    is_valid(fs)
    want = errors isa AbstractString ? [errors] : collect(String, errors)
    if form_index === nothing
        fs.non_form_errors == want || fail("the formset's non-form errors were $(repr(fs.non_form_errors)), expected $(repr(want))")
        return true
    end
    forms = build_forms!(fs)
    1 <= form_index <= length(forms) || fail("the formset has $(length(forms)) forms, not $form_index")
    got = get(forms[form_index].errors, field === nothing ? :__all__ : Symbol(field), String[])
    got == want || fail("form $form_index's $(field === nothing ? "form-wide" : "field '$field'") errors were $(repr(got)), expected $(repr(want))")
    true
end

"""
    assert_field_output(field, valid, invalid; empty_value = nothing)

As Django's `assertFieldOutput`: a form field cleans each input of `valid` (input => cleaned value)
to that value, gives each input of `invalid` (input => error messages) those errors, and cleans
an empty input to `empty_value` when it isn't required.
"""
function assert_field_output(field, valid::AbstractDict, invalid::AbstractDict; empty_value = nothing)
    check(input) = begin
        F = Form([:f => field]; data = Dict("f" => input))
        is_valid(F), F
    end
    for (input, want) in valid
        ok, F = check(input)
        ok || fail("$(repr(input)) didn't clean: $(repr(get(F.errors, :f, String[])))")
        isequal(F.cleaned_data[:f], want) || fail("$(repr(input)) cleaned to $(repr(F.cleaned_data[:f])), expected $(repr(want))")
    end
    for (input, want) in invalid
        ok, F = check(input)
        ok && fail("$(repr(input)) cleaned to $(repr(F.cleaned_data[:f])), expected errors")
        w = want isa AbstractString ? [want] : collect(String, want)
        got = get(F.errors, :f, String[])
        got == w || fail("$(repr(input)) gave errors $(repr(got)), expected $(repr(w))")
    end
    if field.blank                                 # not required
        ok, F = check("")
        ok && isequal(F.cleaned_data[:f], empty_value) || fail("an empty input cleaned to $(ok ? repr(F.cleaned_data[:f]) : "errors"), expected $(repr(empty_value))")
    end
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

# --- snapshot ("golden master") tests -------------------------------------------------------------------

"""
    assert_matches_snapshot(name, value; dir = "test/snapshots")

Compare `value` (a string, bytes, or an `HttpResponse`'s body) with the approved copy in
`dir/name`, byte for byte: the way to make a big refactor safe is to snapshot every report and
export before it and compare after. The first run (or `manage.jl test --update-snapshots`, or
`JUANGO_UPDATE_SNAPSHOTS=1`) writes the file and passes. A difference fails, naming the first
line that differs, and writes the new output beside the old as `name.new` for a diff tool.
"""
function assert_matches_snapshot(name::AbstractString, value; dir::AbstractString = joinpath("test", "snapshots"))
    bytes = value isa HttpResponse ? Vector{UInt8}(value.body isa AbstractString ? codeunits(value.body) : value.body) :
            value isa AbstractString ? Vector{UInt8}(codeunits(value)) : Vector{UInt8}(value)
    path = joinpath(dir, name)
    if !isfile(path) || get(ENV, "JUANGO_UPDATE_SNAPSHOTS", "") in ("1", "true")
        mkpath(dirname(path))
        write(path, bytes)
        isfile(path * ".new") && rm(path * ".new")
        @info "Wrote snapshot $path"
        return true
    end
    old = read(path)
    old == bytes && (isfile(path * ".new") && rm(path * ".new"); return true)
    write(path * ".new", bytes)
    a, b = split(String(copy(old)), '\n'), split(String(copy(bytes)), '\n')
    i = findfirst(k -> k > length(a) || k > length(b) || a[k] != b[k], 1:max(length(a), length(b)))
    line(v, k) = k <= length(v) ? repr(first(v[k], 200)) : "(no line)"
    fail("Snapshot $name differs at line $i:\n  approved: $(line(a, i))\n  now:      $(line(b, i))\n" *
         "The new output is in $(path).new; run with --update-snapshots (JUANGO_UPDATE_SNAPSHOTS=1) to approve it.")
end
