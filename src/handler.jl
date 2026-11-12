# Request handling -------------------------------------------------------------------------------

const MIME_TYPES = Dict(
    ".html" => "text/html; charset=utf-8", ".htm" => "text/html; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
    ".mjs" => "text/javascript; charset=utf-8", ".json" => "application/json",
    ".png" => "image/png", ".jpg" => "image/jpeg", ".jpeg" => "image/jpeg", ".gif" => "image/gif",
    ".svg" => "image/svg+xml", ".ico" => "image/x-icon", ".webp" => "image/webp",
    ".woff" => "font/woff", ".woff2" => "font/woff2", ".ttf" => "font/ttf",
    ".txt" => "text/plain; charset=utf-8", ".pdf" => "application/pdf", ".map" => "application/json",
    ".wasm" => "application/wasm", ".xml" => "application/xml",
)

"Serve a file from STATIC_DIRS or an app's `static/` (used by `runserver` when `DEBUG`)."
function serve_static(req::Request)
    rel = req.path[ncodeunits(settings.STATIC_URL)+1:end]
    for dir in static_dirs()
        root = normpath(abspath(dir))
        p = normpath(joinpath(root, rel))
        (startswith(p, root) && isfile(p)) || continue
        ext = lowercase(splitext(p)[2])
        resp = HttpResponse(read(p); content_type = get(MIME_TYPES, ext, "application/octet-stream"))
        setheader!(resp, "Cache-Control", "no-cache")
        return resp
    end
    throw(Http404("Static file '$rel' not found"))
end

function host_allowed(req::Request)
    settings.DEBUG && return true
    get(req.meta, :test_client, false) && return true
    host = lowercase(first(split(get_host(req), ':')))
    for allowed in settings.ALLOWED_HOSTS
        allowed == "*" && return true
        a = lowercase(allowed)
        (host == a || (startswith(a, ".") && (endswith(host, a) || host == a[2:end]))) && return true
    end
    false
end

"Innermost handler: call the resolved view, converting exceptions to responses."
function dispatch(req::Request)
    try
        rm = req.resolver_match
        rm === nothing && throw(Http404("No URL pattern matches '$(req.path)'"))
        to_response(rm.view(req; rm.kwargs...))
    catch e
        response_for_exception(req, e, catch_backtrace())
    end
end

function build_handler()
    h = dispatch
    for mw in Iterators.reverse(settings.MIDDLEWARE)
        h = mw(h)
    end
    h
end

"""
    handle_request(req::Request) -> HttpResponse

Run a request through URL resolution, middleware and the view. This is what
both the HTTP server and the test `Client` call.
"""
function handle_request(req::Request)
    has_receivers(request_started, :handler) && send(request_started, :handler; request = req)
    resp = handle_request_inner(req)
    has_receivers(request_finished, :handler) && send(request_finished, :handler; request = req, response = resp)
    resp
end

"Set while a `with_live_server(; static = true)` block runs: static files are served even without DEBUG."
const LIVE_SERVER_STATIC = Ref(false)

function handle_request_inner(req::Request)
    try
        if settings.DEBUG && !isempty(string(settings.MEDIA_ROOT)) && startswith(req.path, settings.MEDIA_URL)
            return serve_media(req)
        end
        if (settings.DEBUG || LIVE_SERVER_STATIC[]) && startswith(req.path, settings.STATIC_URL) && !isempty(static_dirs())
            return serve_static(req)
        end
        host_allowed(req) || (log!("juango.security.DisallowedHost", :warning, "Invalid HTTP_HOST header: '$(get_host(req))'"; request = req);
                              throw(BadRequest("Invalid HTTP_HOST header: '$(get_host(req))'. You may need to add it to ALLOWED_HOSTS.")))
        req.resolver_match = resolve(req.path)
        req.resolver_match === nothing || req.resolver_match.language === nothing ||
            (req.meta[:language_prefix] = req.resolver_match.language)
        resp = build_handler()(req)
        req.method == "HEAD" && (resp.body = UInt8[]; resp.stream = nothing)
        resp
    catch e
        response_for_exception(req, e, catch_backtrace())
    end
end

function try_render(names, ctx, status)
    try
        return HttpResponse(render_to_string(names, ctx); status = status)
    catch e
        e isa TemplateDoesNotExist || @error "Error rendering error page" exception = e
        return nothing
    end
end

function response_for_exception(req::Request, e, bt)
    if e isa Http404
        log!("juango.request", :warning, "Not Found: $(req.path)"; request = req, status_code = 404)
        settings.DEBUG && return technical_404(req, e)
        r = try_render("404.html", Dict("request_path" => req.path, "exception" => e.msg), 404)
        return something(r, HttpResponseNotFound("<h1>Not Found</h1><p>The requested resource was not found on this server.</p>"))
    elseif e isa PermissionDenied
        log!("juango.request", :warning, "Forbidden (Permission denied): $(req.path)"; request = req, status_code = 403)
        r = try_render("403.html", Dict("exception" => e.msg), 403)
        return something(r, HttpResponseForbidden())
    elseif e isa BadRequest
        log!("juango.request", :warning, "Bad Request: $(req.path): $(e.msg)"; request = req, status_code = 400)
        r = try_render("400.html", Dict("exception" => e.msg), 400)
        return something(r, HttpResponseBadRequest(settings.DEBUG ? "<h1>Bad Request (400)</h1><p>$(escape_html(e.msg))</p>" :
                                                                    "<h1>Bad Request (400)</h1>"))
    end
    # logged to juango.request: Julia's logger, and mailed to ADMINS when DEBUG is false (see LOGGING)
    log!("juango.request", :error, "Internal Server Error: $(req.path)"; exception = (e, bt), request = req, status_code = 500)
    settings.DEBUG && return technical_500(req, e, bt)
    r = try_render("500.html", Dict{String,Any}(), 500)
    something(r, HttpResponse("<h1>Server Error (500)</h1>"; status = 500))
end

const DEBUG_CSS = """
<style>
body{font:14px/1.5 system-ui,sans-serif;margin:0;color:#222;background:#fff}
header{background:#ffc;padding:16px 24px;border-bottom:1px solid #ddd}
header.err{background:#fee}
h1{margin:0 0 6px;font-weight:600}
main{padding:16px 24px}
pre{background:#f6f6f6;padding:12px;overflow:auto;font-size:12px;border-radius:4px}
code{background:#f3f3f3;padding:1px 4px;border-radius:3px}
ol li{font-family:ui-monospace,monospace;font-size:13px;margin:2px 0}
.muted{color:#666}
</style>"""

function technical_404(req::Request, e::Http404)
    routes = all_routes()
    items = join(["<li>" * escape_html(r) * (n === nothing ? "" : " <span class=\"muted\">[name='" * escape_html(n) * "']</span>") * "</li>"
                  for (r, n, _) in routes])
    body = """<!doctype html><html><head><meta charset="utf-8"><title>Page not found at $(escape_html(req.path))</title>$DEBUG_CSS</head>
    <body><header><h1>Page not found <span class="muted">(404)</span></h1>
    <p><b>Request Method:</b> $(escape_html(req.method)) &nbsp; <b>Request URL:</b> $(escape_html(build_absolute_uri(req)))</p>
    <p>$(escape_html(e.msg))</p></header><main>""" *
           (req.resolver_match === nothing ?
            "<p>Using the URLconf, Juango tried these URL patterns, in this order:</p><ol>$items</ol><p>The current path, <code>$(escape_html(lstrip(req.path, '/')))</code>, didn’t match any of these.</p>" :
            "<p>Raised by: <code>$(escape_html(view_label(req.resolver_match.view)))</code></p>") *
           """<p class="muted">You’re seeing this error because you have <code>DEBUG = true</code> in your settings. Change that to <code>false</code>, and Juango will display a standard 404 page.</p></main></body></html>"""
    HttpResponseNotFound(body)
end

"For a template syntax error on the debug page: where it is, with the lines around it."
function template_error_html(e)
    (e isa TemplateSyntaxError && e.source !== nothing && e.line > 0) || return ""
    lines = split(e.source, '\n')
    lo, hi = max(1, e.line - 5), min(length(lines), e.line + 5)
    rows = join(["<tr$(i == e.line ? " class=\"hl\"" : "")><td class=\"muted\">$i</td><td><code>$(escape_html(lines[i]))</code></td></tr>"
                 for i in lo:hi])
    """<h2>Template error</h2><p>In template <code>$(escape_html(something(e.origin, e.template, "")))</code>, error at line $(e.line)</p>
    <table class="tpl">$rows</table><style>.tpl td{padding:0 .6em;white-space:pre}.tpl tr.hl{background:#fde8e8}</style>"""
end

function technical_500(req::Request, e, bt)
    msg = sprint(showerror, e)
    trace = sprint() do io
        Base.show_backtrace(io, bt)
    end
    body = """<!doctype html><html><head><meta charset="utf-8"><title>$(escape_html(string(nameof(typeof(e))))) at $(escape_html(req.path))</title>$DEBUG_CSS</head>
    <body><header class="err"><h1>$(escape_html(string(nameof(typeof(e))))) <span class="muted">at $(escape_html(req.path))</span></h1>
    <pre>$(escape_html(msg))</pre>
    <p><b>Request Method:</b> $(escape_html(req.method)) &nbsp; <b>Request URL:</b> $(escape_html(build_absolute_uri(req)))
    &nbsp; <b>Julia:</b> $(VERSION) &nbsp; <b>Juango:</b> $VERSION_STRING</p></header>
    <main>$(template_error_html(e))<h2>Traceback</h2><pre>$(escape_html(trace))</pre>
    <h2>Request</h2><pre>GET: $(escape_html(repr(Dict(req.GET))))\nPOST: $(escape_html(repr(Dict(k => (occursin(r"pass|secret|token|key"i, k) ? "********" : v) for (k, v) in req.POST))))\nCOOKIES: $(escape_html(repr(collect(keys(req.COOKIES)))))</pre>
    <p class="muted">You’re seeing this error because you have <code>DEBUG = true</code> in your settings. Change that to <code>false</code>, and Juango will display a standard page generated by the handler for this status code.</p></main></body></html>"""
    HttpResponse(body; status = 500)
end
