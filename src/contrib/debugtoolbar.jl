# Debug toolbar --------------------------------------------------------------------------------
#
# django-debug-toolbar's most useful panels: the SQL a request ran (with timings, duplicates,
# "similar" queries that differ only in their parameters, which is what an N+1 looks like, and
# where in your code each query came from), the templates it rendered and their context, the
# request and response, and timings. Add the middleware and list your address in INTERNAL_IPS:
#
#     configure!(DEBUG = true, INTERNAL_IPS = ["127.0.0.1", "::1"],
#                MIDDLEWARE = [DebugToolbarMiddleware, Juango.default_settings()[:MIDDLEWARE]...])
#
# HTML pages get the toolbar before `</body>`. Every recorded request (htmx partials and JSON
# responses too) is also kept for /__debug__/ (DEBUG_TOOLBAR_PREFIX), the last
# DEBUG_TOOLBAR_HISTORY of them, and its response carries an `X-Juango-Debug` header with its
# page there.
#
# The recording is task-local, so requests served at the same time don't mix, and queries run
# by tasks a view starts with `run_async` count for the request too.

const DEBUG_HISTORY = Pair{String,DebugRecord}[]
const DEBUG_HISTORY_LOCK = ReentrantLock()
const DEBUG_MAX_QUERIES = 5000                # per request; after that only the count goes up
const JUANGO_SRC = normpath(joinpath(@__DIR__, ".."))

"""
    show_debug_toolbar(req) -> Bool

Whether to record `req` and show it the toolbar: `DEBUG_TOOLBAR_SHOW(req)` when that setting is
a function, otherwise `DEBUG` is on and the client's address is in `INTERNAL_IPS`.
"""
function show_debug_toolbar(req::Request)
    f = settings.DEBUG_TOOLBAR_SHOW
    f === nothing || return f(req)::Bool
    settings.DEBUG && string(get(req.meta, :remote_addr, "")) in settings.INTERNAL_IPS
end

function record_query!(rec::DebugRecord, sql::AbstractString, @nospecialize(params), seconds::Float64, err)
    bt = rec.stacktraces ? backtrace() : Union{Ptr{Nothing},Base.InterpreterIP}[]
    lock(rec.lock) do
        q = DebugQuery(String(sql), Any[p for p in params], seconds, current_alias(), bt, err, length(rec.templates))
        if length(rec.queries) < DEBUG_MAX_QUERIES
            push!(rec.queries, q)
        else
            rec.info[:dropped_queries] = get(rec.info, :dropped_queries, 0)::Int + 1
            rec.info[:dropped_seconds] = get(rec.info, :dropped_seconds, 0.0)::Float64 + seconds
        end
    end
    nothing
end

function record_template!(rec::DebugRecord, name::AbstractString, how::String, @nospecialize(stack))
    ctx = Pair{String,String}[]
    if stack !== nothing
        seen = Set{String}()
        for layer in Iterators.reverse(stack), (k, v) in layer       # innermost first, as the template sees it
            k = string(k)
            k in seen && continue
            push!(seen, k)
            push!(ctx, k => debug_repr(v))
        end
        sort!(ctx; by = first)
    end
    lock(() -> push!(rec.templates, DebugTemplate(String(name), how, ctx)), rec.lock)
    nothing
end

"""
A short description of a value for the toolbar, which never runs a query or evaluates anything
lazy (querysets, the lazy user, lazy translations are described by their type).
"""
function debug_repr(@nospecialize(v))
    s = try
        if v isa Union{AbstractString,Number,Bool,Nothing,Symbol,Dates.TimeType,Char}
            repr(v)
        elseif v isa Model
            string("<", nameof(typeof(v)), ": pk=", repr(get(getfield(v, :_data)::Dict{Symbol,Any}, :id, nothing)), ">")
        elseif v isa QuerySet
            sprint(show, v)
        elseif v isa Union{AbstractVector,AbstractSet,Tuple}
            n = length(v)
            string(typeof(v) <: Tuple ? "Tuple" : nameof(typeof(v)), " with ", n, n == 1 ? " item" : " items",
                   n == 0 ? "" : ": " * join((debug_repr(x) for x in Iterators.take(v, 3)), ", ") * (n > 3 ? ", …" : ""))
        elseif v isa AbstractDict
            n = length(v)
            string(nameof(typeof(v)), " with ", n, n == 1 ? " key" : " keys",
                   n == 0 ? "" : ": " * join((repr(string(k)) for k in Iterators.take(keys(v), 6)), ", ") * (n > 6 ? ", …" : ""))
        else
            string(typeof(v))
        end
    catch
        string(typeof(v))
    end
    length(s) > 300 ? first(s, 300) * "…" : s
end

"""
    DebugToolbarMiddleware

Records the SQL, templates and timings of each request shown the toolbar (see
`show_debug_toolbar`), adds the toolbar to HTML pages, and serves the history of recorded
requests at `DEBUG_TOOLBAR_PREFIX`. Put it after any middleware that compresses or encodes the
body (GZipMiddleware) and after ContentSecurityPolicyMiddleware, as early as possible otherwise
so the queries of later middleware (sessions, authentication) are recorded too.
"""
function DebugToolbarMiddleware(get_response)
    function (req::Request)
        show_debug_toolbar(req) || return get_response(req)
        prefix = settings.DEBUG_TOOLBAR_PREFIX
        startswith(req.path, prefix) && return debug_history_response(req, req.path[ncodeunits(prefix)+1:end])
        rec = DebugRecord(settings.DEBUG_TOOLBAR_STACKTRACES)
        gc0, bytes0 = Base.gc_num(), Base.gc_bytes()
        t0 = time()
        resp = task_local_storage(:juango_debug, rec) do
            r = get_response(req)
            r.deferred === nothing || render_template_response!(req, r)   # so its queries and templates are recorded
            r
        end
        elapsed = time() - t0
        gc1 = Base.gc_num()
        fill_debug_info!(rec, req, resp, elapsed, Base.gc_bytes() - bytes0, (gc1.total_time - gc0.total_time) / 1e9)
        id = string(time_ns(); base = 36)
        lock(DEBUG_HISTORY_LOCK) do
            push!(DEBUG_HISTORY, id => rec)
            n = length(DEBUG_HISTORY) - max(1, settings.DEBUG_TOOLBAR_HISTORY)
            n > 0 && deleteat!(DEBUG_HISTORY, 1:n)
        end
        setheader!(resp, "X-Juango-Debug", prefix * id * "/")
        inject_debug_toolbar!(resp, req, rec, id)
        resp
    end
end

function fill_debug_info!(rec::DebugRecord, req::Request, resp::HttpResponse, elapsed, allocated, gctime)
    rm = req.resolver_match
    mask(k, v) = occursin(r"pass|secret|token|key|signature"i, k) ? "********" : v
    info = rec.info
    info[:method] = req.method
    info[:path] = req.path * (isempty(req.query_string) ? "" : "?" * req.query_string)
    info[:view] = rm === nothing ? "" : debug_view_name(rm.view)
    info[:url_name] = rm === nothing || rm.url_name === nothing ? "" :
                      (rm.namespace === nothing || isempty(rm.namespace) ? rm.url_name : rm.namespace * ":" * rm.url_name)
    info[:route] = rm === nothing ? "" : rm.route
    info[:kwargs] = rm === nothing ? Pair{String,String}[] : [string(k) => debug_repr(v) for (k, v) in rm.kwargs]
    info[:GET] = [k => join(v, ", ") for (k, v) in req.GET.data]
    info[:POST] = [k => mask(k, join(v, ", ")) for (k, v) in req.POST.data]
    info[:cookies] = sort!(collect(keys(req.COOKIES)))
    info[:request_headers] = sort!([k => (k in ("cookie", "authorization") ? "********" : v) for (k, v) in req.headers]; by = first)
    s = req.session
    info[:session] = s isa Session && s.loaded ? sort!([k => debug_repr(v) for (k, v) in s.data]; by = first) : nothing
    u = getfield(req, :user)                   # not req.user, which would look the user up
    info[:user] = u === nothing || u isa LazyUser ? "" : debug_repr(u)
    info[:status] = resp.status
    info[:response_headers] = [k => v for (k, v) in resp.headers]
    info[:content_type] = something(getheader(resp, "Content-Type"), "")
    info[:elapsed] = elapsed
    info[:allocated] = allocated
    info[:gctime] = gctime
    info[:when] = Dates.now()
    nothing
end

function debug_view_name(@nospecialize(v))
    try
        v isa Function ? string(parentmodule(v), ".", nameof(v)) : string(typeof(v))
    catch
        string(typeof(v))
    end
end

"Add the toolbar before the last `</body>` of an HTML response (left alone otherwise)."
function inject_debug_toolbar!(resp::HttpResponse, req::Request, rec::DebugRecord, id::String)
    resp.stream === nothing || return
    hasheader(resp, "Content-Encoding") && return
    occursin("text/html", lowercase(something(getheader(resp, "Content-Type"), ""))) || return
    body = String(copy(resp.body))
    m = nothing
    for x in eachmatch(r"</body\s*>"i, body)
        m = x
    end
    m === nothing && return
    io = IOBuffer()
    write(io, SubString(body, 1, prevind(body, m.offset)))
    write_debug_toolbar(io, req, rec, id; open = false)
    write(io, SubString(body, m.offset))
    resp.body = take!(io)
    hasheader(resp, "Content-Length") && setheader!(resp, "Content-Length", string(length(resp.body)))
    nothing
end

# --- the history pages ----------------------------------------------------------------------

function debug_history_response(req::Request, rest::AbstractString)
    rest = strip(rest, '/')
    hist = lock(() -> copy(DEBUG_HISTORY), DEBUG_HISTORY_LOCK)
    io = IOBuffer()
    write(io, "<!doctype html><html><head><meta charset=\"utf-8\"><title>Juango debug</title></head><body>")
    if isempty(rest)
        write(io, "<div class=\"jdt-history\"><h1>Recorded requests</h1>")
        if isempty(hist)
            write(io, "<p>Nothing recorded yet.</p>")
        else
            write(io, "<table><tr><th>When</th><th>Request</th><th>Status</th><th>Queries</th><th>SQL ms</th><th>Total ms</th></tr>")
            for (id, rec) in Iterators.reverse(hist)
                i = rec.info
                n, secs = query_totals(rec)
                print(io, "<tr><td>", Dates.format(i[:when], "HH:MM:SS"), "</td><td><a href=\"", escape_html(id), "/\">",
                      escape_html(i[:method]), " ", escape_html(i[:path]), "</a></td><td>", i[:status], "</td><td>", n,
                      "</td><td>", ms(secs), "</td><td>", ms(i[:elapsed]), "</td></tr>")
            end
            write(io, "</table>")
        end
        write(io, "</div>")
        write(io, "<style>", DEBUG_HISTORY_CSS, "</style>")
    else
        k = findfirst(p -> p.first == rest, hist)
        k === nothing && return HttpResponse("This request is no longer in the debug toolbar's history."; status = 404,
                                             content_type = "text/plain; charset=utf-8")
        print(io, "<p class=\"jdt-back\"><a href=\"", escape_html(settings.DEBUG_TOOLBAR_PREFIX), "\">← all recorded requests</a></p>")
        write_debug_toolbar(io, req, hist[k].second, rest; open = true)
    end
    write(io, "</body></html>")
    HttpResponse(take!(io))
end

const DEBUG_HISTORY_CSS = """
body{font:14px/1.4 system-ui,sans-serif;margin:0 0 4em;padding:1em;background:#fff;color:#222}
.jdt-history table{border-collapse:collapse}.jdt-history td,.jdt-history th{padding:.25em .75em;border-bottom:1px solid #ddd;text-align:left}
"""

# --- rendering --------------------------------------------------------------------------------

ms(secs) = string(round(secs * 1000; digits = 2))

function query_totals(rec::DebugRecord)
    n = length(rec.queries) + get(rec.info, :dropped_queries, 0)::Int
    secs = sum((q.seconds for q in rec.queries); init = 0.0) + get(rec.info, :dropped_seconds, 0.0)::Float64
    n, secs
end

"Line breaks before the main SQL clauses, so long statements can be read."
function format_sql(sql::AbstractString)
    replace(sql, r"\s+(FROM|WHERE|INNER JOIN|LEFT OUTER JOIN|LEFT JOIN|GROUP BY|HAVING|ORDER BY|LIMIT|UNION ALL|UNION|RETURNING|VALUES|SET)\b" =>
                 s"\n\1")
end

"Juango's files left out of query stack traces: the query runner and request plumbing (handler, middleware, test client)."
const DEBUG_HIDDEN_FILES = ("core/utils.jl", "http/handler.jl", "http/server.jl", "http/middleware.jl", "http/security.jl",
                            "http/httpcache.jl", "contrib/htmx.jl", "contrib/debugtoolbar.jl", "testing/client.jl",
                            "template/engine.jl")

"Frames of a query's backtrace worth showing: the caller's code and Juango's views, templates and admin, not the ORM's internals, Base or packages."
function query_frames(q::DebugQuery, cache::Dict{Any,Vector{Base.StackTraces.StackFrame}})
    out = Base.StackTraces.StackFrame[]
    for ip in q.backtrace
        frames = get!(() -> Base.StackTraces.lookup(ip), cache, ip)
        for f in frames
            f.from_c && continue
            file = string(f.file)
            if within(JUANGO_SRC, file)
                rel = relpath(file, JUANGO_SRC)
                (startswith(rel, "db") || rel in DEBUG_HIDDEN_FILES) && continue
            elseif startswith(file, "./") || startswith(file, "/cache/build/") || occursin("/share/julia/", file) ||
                   occursin("/packages/", file) || file == "none" || startswith(file, "REPL[")
                continue
            end
            push!(out, f)
            length(out) >= 12 && return out
        end
    end
    out
end

"A query's origin, in one line: the first frame of the caller's code, and the template it ran in, if any."
function write_query_origin(io::IO, rec::DebugRecord, q::DebugQuery, frames)
    k = findfirst(f -> !within(JUANGO_SRC, string(f.file)), frames)
    f = frames[something(k, 1)]
    print(io, "from ", escape_html(string(f.func)), " <span class=\"jdt-loc\">", escape_html(basename(string(f.file))), ":", f.line, "</span>")
    intemplate = any(f -> within(JUANGO_SRC, string(f.file)) && startswith(relpath(string(f.file), JUANGO_SRC), "template"), frames)
    if intemplate && q.templates_started > 0
        print(io, ", in template <code>", escape_html(rec.templates[q.templates_started].name), "</code>")
    end
end

function write_frames(io::IO, frames)
    for f in frames
        file = string(f.file)
        juango = within(JUANGO_SRC, file)
        print(io, "<div", juango ? " class=\"jdt-dim\"" : "", ">", escape_html(string(f.func)), " <span class=\"jdt-loc\">",
              escape_html(juango ? "Juango/src/" * relpath(file, JUANGO_SRC) : file), ":", f.line, "</span></div>")
    end
end

function write_pairs(io::IO, title, ps)
    print(io, "<h4>", title, "</h4>")
    if ps === nothing || isempty(ps)
        write(io, "<p class=\"jdt-dim\">None</p>")
        return
    end
    write(io, "<table class=\"jdt-kv\">")
    for (k, v) in ps
        print(io, "<tr><th>", escape_html(k), "</th><td><code>", escape_html(v), "</code></td></tr>")
    end
    write(io, "</table>")
end

"The toolbar's HTML for one recorded request."
function write_debug_toolbar(io::IO, req::Request, rec::DebugRecord, id::AbstractString; open::Bool)
    info = rec.info
    nq, sql_secs = query_totals(rec)
    queries = rec.queries
    nonce = csp_nonce(req)
    # duplicates (same SQL and parameters) and similar queries (same SQL)
    by_sql = Dict{String,Int}()
    by_both = Dict{Tuple{String,String},Int}()
    preps = [repr(q.params) for q in queries]
    for (q, p) in zip(queries, preps)
        by_sql[q.sql] = get(by_sql, q.sql, 0) + 1
        by_both[(q.sql, p)] = get(by_both, (q.sql, p), 0) + 1
    end
    ndup = sum((c - 1 for c in values(by_both)); init = 0)
    print(io, "<div id=\"jdt\"", open ? " class=\"jdt-page\"" : "", "><details", open ? " open" : "", "><summary>Juango debug · ",
          nq, nq == 1 ? " query" : " queries", ndup > 0 ? " ($ndup duplicated)" : "", " · ", ms(sql_secs), " ms SQL · ",
          ms(info[:elapsed]), " ms</summary><div class=\"jdt-body\">")

    # timing
    print(io, "<details open><summary>Timing</summary><table class=\"jdt-kv\">",
          "<tr><th>Total</th><td>", ms(info[:elapsed]), " ms</td></tr>",
          "<tr><th>SQL</th><td>", ms(sql_secs), " ms in ", nq, nq == 1 ? " query" : " queries", "</td></tr>",
          "<tr><th>GC</th><td>", ms(info[:gctime]), " ms</td></tr>",
          "<tr><th>Allocated</th><td>", Base.format_bytes(info[:allocated]), " (by the whole process meanwhile)</td></tr>",
          "</table></details>")

    # SQL
    print(io, "<details", isempty(queries) ? "" : " open", "><summary>SQL (", nq, ")</summary>")
    similar = sort!([(c, s) for (s, c) in by_sql if c > 1]; rev = true)
    for (c, s) in similar
        print(io, "<p class=\"jdt-warn\">", c, " similar queries (same SQL, different parameters: an N+1?): <code>",
              escape_html(first(s, 160)), length(s) > 160 ? "…" : "", "</code></p>")
    end
    if get(info, :dropped_queries, 0)::Int > 0
        print(io, "<p class=\"jdt-warn\">Only the first ", DEBUG_MAX_QUERIES, " queries are shown.</p>")
    end
    if !isempty(queries)
        cache = Dict{Any,Vector{Base.StackTraces.StackFrame}}()
        write(io, "<table class=\"jdt-sql\"><tr><th>#</th><th>ms</th><th>Query</th></tr>")
        for (i, (q, p)) in enumerate(zip(queries, preps))
            dups = by_both[(q.sql, p)]
            sims = by_sql[q.sql]
            print(io, "<tr><td>", i, "</td><td>", ms(q.seconds), "</td><td>")
            q.alias == "default" || print(io, "<span class=\"jdt-badge\">", escape_html(q.alias), "</span> ")
            dups > 1 && print(io, "<span class=\"jdt-badge jdt-bad\">duplicated ×", dups, "</span> ")
            sims > 1 && dups < sims && print(io, "<span class=\"jdt-badge\">similar ×", sims, "</span> ")
            q.error === nothing || print(io, "<span class=\"jdt-badge jdt-bad\">error</span> ")
            print(io, "<pre>", escape_html(format_sql(q.sql)), "</pre>")
            isempty(q.params) || print(io, "<div class=\"jdt-params\">params: <code>", escape_html(p), "</code></div>")
            q.error === nothing || print(io, "<div class=\"jdt-err\">", escape_html(q.error), "</div>")
            if rec.stacktraces
                frames = query_frames(q, cache)
                if !isempty(frames)
                    write(io, "<details class=\"jdt-stack\"><summary>")
                    write_query_origin(io, rec, q, frames)
                    write(io, "</summary>")
                    write_frames(io, frames)
                    write(io, "</details>")
                end
            end
            write(io, "</td></tr>")
        end
        write(io, "</table>")
    end
    write(io, "</details>")

    # templates
    print(io, "<details><summary>Templates (", length(rec.templates), ")</summary>")
    isempty(rec.templates) && write(io, "<p class=\"jdt-dim\">No templates were rendered.</p>")
    for t in rec.templates
        print(io, "<details class=\"jdt-tpl\"><summary><code>", escape_html(t.name), "</code> <span class=\"jdt-dim\">",
              t.how, "</span></summary>")
        if isempty(t.context)
            write(io, "<p class=\"jdt-dim\">", t.how == "render" ? "Empty context." : "Same context as the template that uses it.", "</p>")
        else
            write_pairs(io, "Context", t.context)
        end
        write(io, "</details>")
    end
    write(io, "</details>")

    # request
    write(io, "<details><summary>Request</summary><table class=\"jdt-kv\">")
    for (label, key) in (("Request", :path), ("View", :view), ("URL name", :url_name), ("Route", :route), ("User", :user))
        v = info[key]
        key == :path && (v = info[:method] * " " * v)
        isempty(v) || print(io, "<tr><th>", label, "</th><td><code>", escape_html(v), "</code></td></tr>")
    end
    write(io, "</table>")
    write_pairs(io, "URL arguments", info[:kwargs])
    write_pairs(io, "GET", info[:GET])
    write_pairs(io, "POST", info[:POST])
    write_pairs(io, "Cookies (names)", [c => "" for c in info[:cookies]])
    write_pairs(io, info[:session] === nothing ? "Session (not loaded by this request)" : "Session", info[:session])
    write_pairs(io, "Headers", info[:request_headers])
    write(io, "</details>")

    # response
    print(io, "<details><summary>Response (", info[:status], ")</summary>")
    write_pairs(io, "Headers", info[:response_headers])
    write(io, "</details>")

    print(io, "<p class=\"jdt-foot\"><a href=\"", escape_html(settings.DEBUG_TOOLBAR_PREFIX), "\">History</a>",
          open ? "" : " · <a href=\"" * escape_html(settings.DEBUG_TOOLBAR_PREFIX * id) * "/\">This request</a>", "</p>")
    write(io, "</div></details></div>")
    print(io, "<style nonce=\"", nonce, "\">", DEBUG_TOOLBAR_CSS, "</style>")
    nothing
end

const DEBUG_TOOLBAR_CSS = """
#jdt{all:initial;position:fixed;right:8px;bottom:8px;z-index:2147483647;font:13px/1.4 system-ui,sans-serif;color:#1d1d1f;
  max-width:min(960px,calc(100vw - 16px))}
#jdt.jdt-page{position:static;max-width:none}
#jdt *{box-sizing:border-box}
#jdt>details{background:#fff;border:1px solid #c9c9cf;border-radius:6px;box-shadow:0 2px 10px rgba(0,0,0,.18)}
#jdt>details>summary{cursor:pointer;padding:6px 10px;background:#0b6e4f;color:#fff;border-radius:5px;font-weight:600;white-space:nowrap}
#jdt>details[open]>summary{border-radius:5px 5px 0 0}
#jdt .jdt-body{max-height:75vh;overflow:auto;padding:6px 10px}
#jdt.jdt-page .jdt-body{max-height:none}
#jdt .jdt-body>details>summary{cursor:pointer;font-weight:600;padding:4px 0;border-bottom:1px solid #e3e3e8}
#jdt table{border-collapse:collapse;width:100%;margin:4px 0}
#jdt td,#jdt th{text-align:left;vertical-align:top;padding:3px 6px;border-bottom:1px solid #eee}
#jdt .jdt-kv th{width:12em;font-weight:500;color:#555;word-break:break-all}
#jdt pre{margin:2px 0;white-space:pre-wrap;word-break:break-word;font:12px/1.35 ui-monospace,monospace}
#jdt code{font:12px ui-monospace,monospace;word-break:break-word}
#jdt h4{margin:8px 0 2px;font-size:13px}
#jdt p{margin:4px 0}
#jdt a{color:#0b6e4f}
#jdt .jdt-dim{color:#777}
#jdt .jdt-loc{color:#777;font-size:12px}
#jdt .jdt-warn{background:#fff4d6;border-left:3px solid #e0a800;padding:3px 6px}
#jdt .jdt-err{color:#b00020}
#jdt .jdt-badge{display:inline-block;font-size:11px;padding:0 5px;border-radius:8px;background:#e6e6eb}
#jdt .jdt-bad{background:#fbd5d5;color:#8a1010}
#jdt .jdt-params{color:#555}
#jdt .jdt-stack summary{cursor:pointer;color:#555;font-size:12px}
#jdt .jdt-stack div{font:12px ui-monospace,monospace;padding-left:1em}
#jdt .jdt-foot{margin-top:8px}
@media (prefers-color-scheme:dark){
  #jdt{color:#e6e6e6}#jdt>details{background:#1e1f22;border-color:#3a3b40}
  #jdt td,#jdt th,#jdt .jdt-body>details>summary{border-color:#33343a}#jdt .jdt-kv th,#jdt .jdt-dim,#jdt .jdt-loc,#jdt .jdt-params{color:#a0a0a8}
  #jdt .jdt-warn{background:#3a3115}#jdt .jdt-badge{background:#33343a}#jdt .jdt-bad{background:#5a1e1e;color:#ffd0d0}
  #jdt a{color:#5fd3a8}#jdt .jdt-err{color:#ff8a8a}}
"""
