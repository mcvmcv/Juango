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
    # common downloads
    ".csv" => "text/csv; charset=utf-8", ".tsv" => "text/tab-separated-values; charset=utf-8",
    ".xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", ".xls" => "application/vnd.ms-excel",
    ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".ods" => "application/vnd.oasis.opendocument.spreadsheet", ".zip" => "application/zip", ".gz" => "application/gzip",
    ".mp4" => "video/mp4", ".mp3" => "audio/mpeg", ".avif" => "image/avif",
)

"Serve a file from STATIC_DIRS or an app's `static/` (used by `runserver` when `DEBUG`)."
function serve_static(req::Request)
    rel = req.path[ncodeunits(settings.STATIC_URL)+1:end]
    p = find_static_file(rel)                         # STATICFILES_FINDERS
    if p !== nothing
        ext = lowercase(splitext(p)[2])
        resp = HttpResponse(read(p); content_type = get(MIME_TYPES, ext, "application/octet-stream"))
        setheader!(resp, "Cache-Control", "no-cache")
        return resp
    end
    throw(Http404("Static file '$rel' not found"))
end

# As Django's: a domain name or IPv4 address, or an IPv6 address in brackets; then perhaps a port.
const HOST_RE = r"^([a-z0-9.-]+|\[[a-f0-9]*:[a-f0-9.:]+\])(:[0-9]+)?$"
"The host name of a Host header without its port (`nothing` if the header isn't a valid host)."
function host_name(h::AbstractString)
    m = match(HOST_RE, lowercase(h))
    m === nothing ? nothing : rstrip(m[1], '.')
end

"""
Whether the request's Host is in ALLOWED_HOSTS. With DEBUG on and ALLOWED_HOSTS empty, only
localhost names are allowed (as in Django), so a page on another site can't reach a development
server through a DNS name it controls (DNS rebinding).
"""
function host_allowed(req::Request)
    get(req.meta, :test_client, false) && return true
    host = host_name(get_host(req))
    host === nothing && return false
    allowed_hosts = settings.ALLOWED_HOSTS
    settings.DEBUG && isempty(allowed_hosts) && (allowed_hosts = [".localhost", "127.0.0.1", "[::1]"])
    for allowed in allowed_hosts
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
        call = () -> to_response(rm.view(req; rm.kwargs...))
        for alias in atomic_request_aliases(rm.view)          # ATOMIC_REQUESTS: the view in a transaction
            inner = call
            call = () -> atomic(inner; db = alias)
        end
        run = () -> (resp = call(); resp.deferred === nothing ? resp : render_template_response!(req, resp))
        # in an include with an app_name, reverse_url("app:...") and {% url %} stay in this instance
        rm.app_name === nothing || rm.namespace === nothing ? run() :
            Base.ScopedValues.with(run, CURRENT_APP => (rm.app_name => rm.namespace))
    catch e
        response_for_exception(req, e, catch_backtrace())
    end
end

"""
    process_template_response(middleware, req, resp) -> resp

Define a method for your middleware function to change a `TemplateResponse` after the view and
before it's rendered (`resp.template_name`, `resp.context_data`), as Django's hook of the same
name: `Juango.process_template_response(::typeof(MyMiddleware), req, resp) = (resp.context_data["x"] = 1; resp)`.
"""
function process_template_response end

"Run the middleware's template response hooks (innermost first), then render the template."
function render_template_response!(req, resp::HttpResponse)
    for mw in Iterators.reverse(settings.MIDDLEWARE)
        hasmethod(process_template_response, Tuple{typeof(mw),Request,HttpResponse}) &&
            (resp = process_template_response(mw, req, resp))
    end
    render_response!(resp)
end

"The middleware chain around `dispatch`, built once per MIDDLEWARE setting (like Django, middleware is instantiated once)."
function build_handler()
    mws = settings.MIDDLEWARE
    c = HANDLER_CACHE[]
    c !== nothing && c[1] === mws && return c[2]
    h = dispatch
    for mw in Iterators.reverse(mws)
        h = mw(h)
    end
    HANDLER_CACHE[] = (mws, h)
    h
end
const HANDLER_CACHE = Ref{Any}(nothing)
push!(SETTINGS_CHANGED_HOOKS, () -> (HANDLER_CACHE[] = nothing))

"""
    handle_request(req::Request) -> HttpResponse

Run a request through URL resolution, middleware and the view. This is what
both the HTTP server and the test `Client` call.
"""
function handle_request(req::Request)
    delete!(task_local_storage(), :juango_template_error)    # a template failure noted for the debug page
    has_receivers(request_started, :handler) && send(request_started, :handler; request = req)
    resp = try
        with_nplusone_tracking(() -> handle_request_inner(req))
    finally
        cleanup_uploads(req)                         # temporary files of big uploads
    end
    has_receivers(request_finished, :handler) && send(request_finished, :handler; request = req, response = resp)
    resp
end

"Whether the request has more parameters than `DATA_UPLOAD_MAX_NUMBER_FIELDS` (Django's TooManyFieldsSent)."
function too_many_fields(req::Request)
    limit = get(settings, :DATA_UPLOAD_MAX_NUMBER_FIELDS, nothing)
    limit === nothing && return false
    n = 0
    for q in (req.GET, req.POST), v in values(q.data)
        n += length(v)
    end
    n > limit
end

"Set while a `with_live_server(; static = true)` block runs: static files are served even without DEBUG."
const LIVE_SERVER_STATIC = Ref(false)

function handle_request_inner(req::Request)
    try
        # in DEBUG, uploads are served as they are, unless a URL pattern of the project's takes the path
        # (protected_media(), a login check): its route wins, as Django's opt-in static() lets it (#226)
        if settings.DEBUG && !isempty(string(settings.MEDIA_ROOT)) && startswith(req.path, settings.MEDIA_URL) &&
           resolve(req.path) === nothing
            return serve_media(req)
        end
        if (settings.DEBUG || LIVE_SERVER_STATIC[]) && startswith(req.path, settings.STATIC_URL) && !isempty(static_dirs())
            return serve_static(req)
        end
        if !settings.DEBUG && get(SETTINGS, :SERVE_STATIC, false) === true && startswith(req.path, settings.STATIC_URL) &&
           !isempty(string(settings.STATIC_ROOT))
            return serve_static_root(req)                # (contrib/staticfiles.jl: hashed, cached, pre-compressed)
        end
        haskey(req.meta, :upload_error) && throw(req.meta[:upload_error])
        too_many_fields(req) && throw(BadRequest("The number of GET/POST parameters exceeded DATA_UPLOAD_MAX_NUMBER_FIELDS."))
        host_allowed(req) || (log!("juango.security.DisallowedHost", :warning, "Invalid HTTP_HOST header: '$(get_host(req))'"; request = req);
                              throw(BadRequest("Invalid HTTP_HOST header: '$(get_host(req))'. You may need to add it to ALLOWED_HOSTS.")))
        req.resolver_match = resolve(req.path)
        req.resolver_match === nothing || req.resolver_match.language === nothing ||
            (req.meta[:language_prefix] = req.resolver_match.language)
        resp = build_handler()(req)
        resp.deferred === nothing || render_response!(resp)       # a middleware returned a TemplateResponse
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

"""
The response of a custom error view (`HANDLER404` & co.), or `nothing` when there's none or it
fails (then the built-in page is used). 400/403/404 views are called as `view(req; exception)`,
the 500 view as `view(req)`.
"""
function custom_error_response(req::Request, status::Int, e)
    h = get(settings, Symbol("HANDLER", status), nothing)
    h === nothing && return nothing
    try
        r = to_response(status == 500 ? h(req) : h(req; exception = e))
        r.deferred === nothing ? r : render_response!(r)
    catch err
        @error "The HANDLER$status view failed" exception = (err, catch_backtrace())
        nothing
    end
end

"Problems with the HANDLER400/403/404/500 settings, for `manage.jl check`."
function error_handler_issues()
    issues = String[]
    for status in (400, 403, 404, 500)
        h = get(settings, Symbol("HANDLER", status), nothing)
        h === nothing && continue
        ok = status == 500 ? hasmethod(h, Tuple{Request}) || hasmethod(h, Tuple{Any}) :
             any(m -> :exception in Base.kwarg_decl(m) || any(endswith("..."), string.(Base.kwarg_decl(m))), methods(h))
        ok || push!(issues, status == 500 ? "HANDLER500 must be a view taking just the request: view(req)." :
                                          "HANDLER$status must be a view taking the request and an `exception` keyword: view(req; exception).")
    end
    issues
end

function response_for_exception(req::Request, e, bt)
    e isa NPlusOneError && get(req.meta, :test_client, false) === true && throw(e)     # (NPLUSONE = :raise fails the test itself)
    # (as Django's SuspiciousOperations: logged to the security logger and answered with 400)
    if e isa DisallowedRedirect
        log!("juango.security.DisallowedRedirect", :error, e.msg; request = req)
        e = BadRequest(e.msg)
    end
    if e isa Http404
        log!("juango.request", :warning, "Not Found: $(req.path)"; request = req, status_code = 404)
        settings.DEBUG && return technical_404(req, e)
        c = custom_error_response(req, 404, e)
        c === nothing || return c
        r = try_render("404.html", Dict("request_path" => req.path, "exception" => e.msg), 404)
        return something(r, HttpResponseNotFound("<h1>Not Found</h1><p>The requested resource was not found on this server.</p>"))
    elseif e isa PermissionDenied
        log!("juango.request", :warning, "Forbidden (Permission denied): $(req.path)"; request = req, status_code = 403)
        c = custom_error_response(req, 403, e)
        c === nothing || return c
        r = try_render("403.html", Dict("exception" => e.msg), 403)
        return something(r, HttpResponseForbidden())
    elseif e isa BadRequest
        log!("juango.request", :warning, "Bad Request: $(req.path): $(e.msg)"; request = req, status_code = 400)
        c = custom_error_response(req, 400, e)
        c === nothing || return c
        r = try_render("400.html", Dict("exception" => e.msg), 400)
        return something(r, HttpResponseBadRequest(settings.DEBUG ? "<h1>Bad Request (400)</h1><p>$(escape_html(e.msg))</p>" :
                                                                    "<h1>Bad Request (400)</h1>"))
    end
    any_receivers(got_request_exception) && send_robust(got_request_exception, :handler; request = req, exception = e)
    # logged to juango.request: Julia's logger, and mailed to ADMINS when DEBUG is false (see LOGGING)
    log!("juango.request", :error, "Internal Server Error: $(req.path)"; exception = (e, bt), request = req, status_code = 500)
    settings.DEBUG && return technical_500(req, e, bt)
    c = custom_error_response(req, 500, e)
    c === nothing || return c
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

