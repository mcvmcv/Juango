# Middleware -----------------------------------------------------------------------------------
#
# A middleware is a factory `get_response -> (req -> response)`, exactly like Django:
#
#     function TimingMiddleware(get_response)
#         function (req)
#             t = time()
#             resp = get_response(req)
#             setheader!(resp, "X-Elapsed", string(time() - t))
#             resp
#         end
#     end
#
#     configure!(MIDDLEWARE = [Juango.default_settings()[:MIDDLEWARE]..., TimingMiddleware])

# SecurityMiddleware: see security.jl

"Loads `req.session` from the session cookie and saves it after the view runs."
function SessionMiddleware(get_response)
    function (req::Request)
        name = settings.SESSION_COOKIE_NAME
        req.session = lazy_session(get(req.COOKIES, name, nothing))
        resp = get_response(req)
        s = req.session
        if s isa Session
            st = settings
            path, domain = get(st, :SESSION_COOKIE_PATH, "/"), get(st, :SESSION_COOKIE_DOMAIN, nothing)
            if s.flushed && haskey(req.COOKIES, name)
                delete_cookie!(resp, name; path = path, domain = domain)
            end
            # (SESSION_SAVE_EVERY_REQUEST: a session with data is saved, and its cookie renewed, every time)
            save = s.modified || (get(st, :SESSION_SAVE_EVERY_REQUEST, false) && session_loaded(s) && !isempty(s.data))
            if save && !(resp.status >= 500)
                if isempty(s.data) && s.key === nothing
                    # nothing to store
                else
                    save_session!(s)
                    # browsers drop cookies over about 4 KB, which loses a signed-cookie session silently
                    ncodeunits(s.key) > 4000 && log!("juango.security.SessionCookieTooLarge", :warning,
                        "The session cookie is $(ncodeunits(s.key)) bytes: browsers may drop it. Store less in signed-cookie sessions."; request = req)
                    browser = get_expire_at_browser_close(s)       # (no Max-Age: gone when the browser closes)
                    age = browser ? nothing : get_expiry_age(s)
                    set_cookie!(resp, name, s.key; max_age = age, expires = age === nothing ? nothing : now(Dates.UTC) + Second(age),
                                httponly = get(st, :SESSION_COOKIE_HTTPONLY, true), secure = st.SESSION_COOKIE_SECURE,
                                samesite = get(st, :SESSION_COOKIE_SAMESITE, "Lax"), path = path, domain = domain)
                end
            end
            s.modified && patch_vary!(resp, "Cookie")
        end
        resp
    end
end

patch_vary!(resp, h) = (v = getheader(resp, "Vary"); v === nothing ? setheader!(resp, "Vary", h) :
                        occursin(h, v) ? resp : setheader!(resp, "Vary", v * ", " * h))

"Handles `APPEND_SLASH`: redirects `/foo` to `/foo/` when only the latter matches."
function CommonMiddleware(get_response)
    function (req::Request)
        if settings.APPEND_SLASH && req.resolver_match === nothing && !endswith(req.path, "/") &&
           (m = resolve(req.path * "/"); m !== nothing && !haskey(NO_APPEND_SLASH, m.view))
            if req.method in ("POST", "PUT", "PATCH") && settings.DEBUG
                error("You called this URL via $(req.method), but the URL doesn't end in a slash and APPEND_SLASH is set. " *
                      "Juango can't redirect to the slash URL while maintaining $(req.method) data. " *
                      "Change your form to point to $(req.path)/ (note the trailing slash).")
            end
            q = isempty(req.query_string) ? "" : "?" * req.query_string
            return HttpResponsePermanentRedirect(req.path * "/" * q)
        end
        get_response(req)
    end
end

"""
    BrokenLinkEmailsMiddleware

Emails `MANAGERS` when a page returns 404 and the request came from a link (it has a
Referer), unless `DEBUG` is on. Links from this site are reported as "Broken INTERNAL link".
Like Django it ignores requests without a referer, referers equal to the URL, `APPEND_SLASH`
redirect leftovers, external referers with a query string (search engines), and paths
matching a regex in `IGNORABLE_404_URLS`.
"""
function BrokenLinkEmailsMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        if resp.status == 404 && !settings.DEBUG
            domain = get_host(req)
            uri = req.path * (isempty(req.query_string) ? "" : "?" * req.query_string)
            referer = get(req.headers, "referer", "")
            if !ignorable_404(uri, domain, referer)
                internal = is_internal_referer(domain, referer)
                mail_managers((internal ? "Broken INTERNAL link on " : "Broken link on ") * domain,
                              "Referrer: $referer\nRequested URL: $uri\n" *
                              "User agent: $(get(req.headers, "user-agent", "<none>"))\n" *
                              "IP address: $(get(req.meta, :remote_addr, ""))\n"; fail_silently = true)
            end
        end
        resp
    end
end

"Whether `referer` is a page of this site (`http(s)://domain/...`)."
is_internal_referer(domain, referer) =
    startswith(referer, "http://" * domain * "/") || startswith(referer, "https://" * domain * "/")

function ignorable_404(uri, domain, referer)
    isempty(referer) && return true
    settings.APPEND_SLASH && endswith(uri, "/") && referer == uri[1:end-1] && return true
    !is_internal_referer(domain, referer) && occursin('?', referer) && return true
    m = match(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?(?://([^/?#]*))?([^?#]*)", referer)
    if m !== nothing
        netloc, p = something(m[1], ""), m[2]
        (netloc == "" || netloc == domain) && p == uri && return true
    end
    any(pat -> occursin(pat isa Regex ? pat : Regex(string(pat)), uri), settings.IGNORABLE_404_URLS)
end

"Sets `req.user` from the session, lazily: the user is looked up when `req.user` is first read."
function AuthenticationMiddleware(get_response)
    function (req::Request)
        req.user = LAZY_USER
        get_response(req)
    end
end

# --- CSRF --------------------------------------------------------------------------------------

const CSRF_EXEMPT = IdDict{Any,Bool}()
const UNSAFE_METHODS = ("POST", "PUT", "PATCH", "DELETE")
"Methods CSRF protection lets through (RFC 9110's safe methods); every other one is checked, as in Django."
const SAFE_METHODS = ("GET", "HEAD", "OPTIONS", "TRACE")

"Mark a view as exempt from CSRF checks (e.g. a webhook endpoint)."
csrf_exempt(view) = (CSRF_EXEMPT[view] = true; view)
is_csrf_exempt(view) = haskey(CSRF_EXEMPT, view)

const NO_APPEND_SLASH = IdDict{Any,Bool}()
"""
    no_append_slash(view)

Don't redirect `/path` to this view's `/path/` under APPEND_SLASH (Django 3.2), for views whose
URLs are probed without the slash (APIs, health checks): `/path` stays a 404.
"""
no_append_slash(view) = (NO_APPEND_SLASH[view] = true; view)

"""
    ensure_csrf_cookie(view)

Send the CSRF cookie with this view's response even if its page has no `{% csrf_token %}`: for
pages whose forms are made by JavaScript, which reads the cookie.
"""
function ensure_csrf_cookie(view)
    w = (req; kw...) -> (get_csrf_token(req); view(req; kw...))
    propagate_flags!(w, view)
end

"""
    csrf_protect(view)

CSRF protection for this view alone, as CsrfViewMiddleware gives every view: for projects
without the middleware. With it installed, this does nothing more.
"""
function csrf_protect(view)
    w = (req; kw...) -> csrf_process(req, () -> to_response(view(req; kw...)); enforce = true)
    propagate_flags!(w, view)
end

"""
    requires_csrf_token(view)

Django's decorator for views (custom error views) that render `{% csrf_token %}` without the
middleware's checks. In Juango the token is always available to templates, so this returns the
view unchanged; it exists so ported code reads the same.
"""
requires_csrf_token(view) = view

"""
    xframe_options_exempt(view)    xframe_options_deny(view)    xframe_options_sameorigin(view)

Per-view `X-Frame-Options`: leave the header off this view's responses (so other sites may frame
it), or set it to `DENY` / `SAMEORIGIN` whatever `X_FRAME_OPTIONS` says.
"""
function xframe_options_exempt(view)
    w = (req; kw...) -> (req.meta[:xframe_options_exempt] = true; view(req; kw...))
    propagate_flags!(w, view)
end
xframe_options_deny(view) = xframe_header(view, "DENY")
xframe_options_sameorigin(view) = xframe_header(view, "SAMEORIGIN")
function xframe_header(view, value)
    w = (req; kw...) -> (r = to_response(view(req; kw...)); hasheader(r, "X-Frame-Options") || setheader!(r, "X-Frame-Options", value); r)
    propagate_flags!(w, view)
end

"""
    sensitive_post_parameters(view, names...)

Mask these POST parameters (all of them when no names are given) in the DEBUG error page and the
error emails, as Django's decorator: `sensitive_post_parameters(signup, "password", "card")`.
Parameters whose names look secret (password, token, key...) are masked anyway.
"""
function sensitive_post_parameters(view, names::AbstractString...)
    hide = isempty(names) ? :all : Set(String.(collect(names)))
    w = (req; kw...) -> (req.meta[:sensitive_post_parameters] = hide; view(req; kw...))
    propagate_flags!(w, view)
end
sensitive_post_parameters(names::AbstractString...) = view -> sensitive_post_parameters(view, names...)

const LOGIN_NOT_REQUIRED = IdDict{Any,Bool}()
"""
    login_not_required(view)

Let anonymous users reach a view when `LoginRequiredMiddleware` is on (Django 5.1). Juango's
login, password reset and admin views are marked already.
"""
login_not_required(view) = (LOGIN_NOT_REQUIRED[view] = true; view)
is_login_not_required(view) = haskey(LOGIN_NOT_REQUIRED, view)

const NON_ATOMIC = IdDict{Any,Any}()
"""
    non_atomic_requests(view; databases = nothing)

Leave a view out of `ATOMIC_REQUESTS` transactions (for all databases, or the aliases in `databases`).
"""
non_atomic_requests(view; databases = nothing) =
    (NON_ATOMIC[view] = databases === nothing ? :all : Set(string.(databases isa AbstractString ? [databases] : databases)); view)

"The databases whose ATOMIC_REQUESTS transaction a view runs in."
function atomic_request_aliases(view)
    a = get(settings, :ATOMIC_REQUESTS, false)
    aliases = a === true ? ["default"] : a === false || a === nothing ? String[] : String[string(x) for x in a]
    skip = get(NON_ATOMIC, view, nothing)
    skip === :all ? String[] : skip === nothing ? aliases : filter(x -> !(x in skip), aliases)
end

"""
Require login for every view (Django 5.1's `LoginRequiredMiddleware`): anonymous users are sent
to `settings.LOGIN_URL`, except for views marked `login_not_required` and the login page itself.
Put it after `AuthenticationMiddleware`. Unknown URLs still give 404.
"""
function LoginRequiredMiddleware(get_response)
    function (req::Request)
        rm = req.resolver_match
        (rm === nothing || is_login_not_required(rm.view) || is_authenticated(req.user)) && return get_response(req)
        # (a view's own login_required(login_url, redirect_field_name) wins, as Django's)
        o = get(LOGIN_REQUIRED_OPTS, rm.view, nothing)
        url = something(o === nothing ? nothing : o.login_url, settings.LOGIN_URL, Some(nothing))
        url === nothing && throw(ImproperlyConfigured("No login URL to redirect to. Define settings.LOGIN_URL or provide a login_url via the login_required decorator."))
        login = resolve_login_url(url)
        req.path == login && return get_response(req)
        redirect_to_login(req, login; redirect_field_name = o === nothing ? "next" : o.redirect_field_name)
    end
end

"The login_url and redirect_field_name a view was given by `login_required`."
const LOGIN_REQUIRED_OPTS = IdDict{Any,Any}()
"A login URL that may be a URL name (`\"login\"`, `\"accounts:login\"`), as Django's resolve_url."
function resolve_login_url(url)
    s = string(url)
    (startswith(s, "/") || occursin("://", s) || startswith(s, ".")) && return s
    try
        reverse_url(s)
    catch
        s
    end
end

const VIEW_NAMES = IdDict{Any,String}()

"Human-readable name of a view (used by `showurls` and error pages)."
view_label(v) = haskey(VIEW_NAMES, v) ? VIEW_NAMES[v] : v isa Function ? string(nameof(v)) : string(typeof(v))
"Give a (closure) view a readable name."
name_view!(v, name) = (VIEW_NAMES[v] = string(name); v)

"Copy marker flags (CSRF exemption, display name) from a wrapped view onto its wrapper."
function propagate_flags!(wrapper, view)
    is_csrf_exempt(view) && (CSRF_EXEMPT[wrapper] = true)
    is_login_not_required(view) && (LOGIN_NOT_REQUIRED[wrapper] = true)
    haskey(NON_ATOMIC, view) && (NON_ATOMIC[wrapper] = NON_ATOMIC[view])
    haskey(NO_APPEND_SLASH, view) && (NO_APPEND_SLASH[wrapper] = true)
    haskey(LOGIN_REQUIRED_OPTS, view) && !haskey(LOGIN_REQUIRED_OPTS, wrapper) && (LOGIN_REQUIRED_OPTS[wrapper] = LOGIN_REQUIRED_OPTS[view])
    VIEW_NAMES[wrapper] = view_label(view)
    wrapper
end

"""
    get_csrf_token(req) -> String

The CSRF token for this request (also available in templates as `csrf_token`,
or as a hidden input via `{% csrf_token %}`).
"""
function get_csrf_token(req::Request)
    tok = get(req.meta, :csrf_token, nothing)
    if tok === nothing
        tok = random_string(32)
        req.meta[:csrf_token] = tok
        req.meta[:csrf_cookie_needs_update] = true
    end
    req.meta[:csrf_used] = true
    tok
end

function rotate_csrf_token!(req::Request)
    req.meta[:csrf_token] = random_string(32)
    req.meta[:csrf_cookie_needs_update] = true
    nothing
end

struct CsrfFailure <: Exception
    reason::String
end

# The token in pages is masked: a random 32-character mask followed by the secret shifted by it,
# different each time it's rendered, so compression (GZipMiddleware) can't be used to guess the
# secret from responses (BREACH). The cookie holds the secret itself; both forms are accepted.
const CSRF_SECRET_LENGTH = 32
const CSRF_INDEX = Dict(c => i - 1 for (i, c) in enumerate(ALNUM))
"`mask_csrf(secret)`: a masked form of the CSRF secret, for pages."
function mask_csrf(secret::AbstractString)
    mask = random_string(CSRF_SECRET_LENGTH)
    n = length(ALNUM)
    mask * String([ALNUM[(CSRF_INDEX[s] + CSRF_INDEX[m]) % n + 1] for (s, m) in zip(secret, mask)])
end
"The secret in a submitted token (masked or not); `nothing` if it isn't a well-formed token."
function unmask_csrf(tok::AbstractString)
    all(c -> haskey(CSRF_INDEX, c), tok) || return nothing
    length(tok) == CSRF_SECRET_LENGTH && return String(tok)
    length(tok) == 2CSRF_SECRET_LENGTH || return nothing
    n = length(ALNUM)
    mask, cipher = tok[1:CSRF_SECRET_LENGTH], tok[CSRF_SECRET_LENGTH+1:end]
    String([ALNUM[mod(CSRF_INDEX[c] - CSRF_INDEX[m], n) + 1] for (c, m) in zip(cipher, mask)])
end

"The request's own origin, `scheme://host`."
request_origin(req::Request) = (is_secure(req) ? "https://" : "http://") * get_host(req)

const CSRF_SESSION_KEY = "_csrftoken"

"The CSRF secret the client holds: its cookie, or with CSRF_USE_SESSIONS the session's (`nothing` if none)."
function client_csrf_secret(req::Request)
    if settings.CSRF_USE_SESSIONS
        s = req.session
        s === nothing && throw(ImproperlyConfigured("CSRF_USE_SESSIONS needs SessionMiddleware before CsrfViewMiddleware"))
        v = get(s, CSRF_SESSION_KEY, nothing)
        return v isa AbstractString ? String(v) : nothing
    end
    get(req.COOKIES, settings.CSRF_COOKIE_NAME, nothing)
end

"The request header the token may come in (CSRF_HEADER_NAME, written either `X-CSRFToken` or Django's `HTTP_X_CSRFTOKEN`)."
csrf_header_name() = lowercase(replace(replace(string(settings.CSRF_HEADER_NAME), r"^HTTP_" => ""), '_' => '-'))

"Give the client the CSRF secret: in the cookie (with the CSRF_COOKIE_* settings), or in the session."
function store_csrf_secret!(req::Request, resp::HttpResponse)
    tok = get_csrf_token(req)
    if settings.CSRF_USE_SESSIONS
        req.session[CSRF_SESSION_KEY] = tok
    else
        s = settings
        set_cookie!(resp, s.CSRF_COOKIE_NAME, tok; max_age = s.CSRF_COOKIE_AGE, secure = s.CSRF_COOKIE_SECURE,
                    httponly = s.CSRF_COOKIE_HTTPONLY, samesite = s.CSRF_COOKIE_SAMESITE, domain = s.CSRF_COOKIE_DOMAIN,
                    path = s.CSRF_COOKIE_PATH)
        patch_vary!(resp, "Cookie")
    end
    nothing
end

"""
Whether `host` is `pattern` or, for a pattern starting with a dot, one of its subdomains
(Django's is_same_domain): `.example.com` matches `example.com` and `www.example.com`.
"""
function is_same_domain(host::AbstractString, pattern::AbstractString)
    isempty(pattern) && return false
    pattern = lowercase(pattern); host = lowercase(host)
    pattern[1] == '.' ? (endswith(host, pattern) || host == pattern[2:end]) : host == pattern
end
split_origin(o) = (m = match(r"^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]*)", o); m === nothing ? nothing : (lowercase(m[1]), m[2]))
"""
Whether an Origin is trusted, as Django's: this site's own, one of CSRF_TRUSTED_ORIGINS, or a
subdomain of a wildcard one (`https://*.example.com`) with the same scheme.
"""
function origin_trusted(req::Request, origin::AbstractString)
    origin == request_origin(req) && return true
    trusted = collect(String, settings.CSRF_TRUSTED_ORIGINS)
    any(t -> !occursin('*', t) && t == origin, trusted) && return true
    p = split_origin(origin)
    p === nothing && return false
    any(trusted) do t
        occursin('*', t) || return false
        tp = split_origin(t)
        tp !== nothing && tp[1] == p[1] && is_same_domain(p[2], lstrip(tp[2], '*'))
    end
end

function check_csrf(req::Request)
    cookie = client_csrf_secret(req)
    cookie === nothing && throw(CsrfFailure(settings.CSRF_USE_SESSIONS ? "CSRF token not in the session." : "CSRF cookie not set."))
    origin = header(req, "origin")
    if origin !== nothing
        # the same scheme as the request: an http:// page can't post to the https:// site
        origin_trusted(req, origin) || throw(CsrfFailure("Origin checking failed - $origin does not match any trusted origins."))
    elseif is_secure(req)
        # as Django: over HTTPS without an Origin, the Referer must be this site (or trusted), so a
        # man-in-the-middle on plain HTTP can't set the cookie and post a matching token
        ref = header(req, "referer")
        ref === nothing && throw(CsrfFailure("Referer checking failed - no Referer."))
        m = match(r"^([a-zA-Z][a-zA-Z0-9+.-]*)://([^/?#]+)", ref)
        m === nothing && throw(CsrfFailure("Referer checking failed - Referer is malformed."))
        lowercase(m[1]) == "https" || throw(CsrfFailure("Referer checking failed - Referer is insecure while host is secure."))
        # this host (or the cookie's domain, with the port when it isn't 80 or 443), or a trusted
        # origin's host (a wildcard one's subdomains), as Django's
        dom = settings.CSRF_USE_SESSIONS ? get(settings, :SESSION_COOKIE_DOMAIN, nothing) : settings.CSRF_COOKIE_DOMAIN
        good = if dom === nothing
            get_host(req)
        else
            port = get_port(req)
            port in ("443", "80") ? string(dom) : string(dom, ":", port)
        end
        hosts = vcat([lstrip(something(split_origin(t), ("", ""))[2], '*') for t in settings.CSRF_TRUSTED_ORIGINS], [good])
        any(h -> is_same_domain(m[2], h), hosts) ||
            throw(CsrfFailure("Referer checking failed - $ref does not match any trusted origins."))
    end
    tok = get(req.POST, "csrfmiddlewaretoken", nothing)
    tok === nothing && (tok = header(req, csrf_header_name()))
    tok === nothing && throw(CsrfFailure("CSRF token missing."))
    secret = unmask_csrf(tok)
    (secret !== nothing && consteq(secret, cookie)) || throw(CsrfFailure("CSRF token incorrect."))
end

"""
Rejects unsafe requests (POST/PUT/PATCH/DELETE) that lack a valid CSRF token, and
sets the CSRF cookie when a token was used.
"""
CsrfViewMiddleware(get_response) = req::Request -> csrf_process(req, () -> get_response(req); enforce = nothing)

"""
CSRF protection around `call()` (the rest of the request): check an unsafe request's token, then
give the client the secret if a token was used. Done once per request, by the middleware or by
`csrf_protect`. `enforce = nothing` follows the view's `csrf_exempt` mark; `true` checks anyway.
"""
function csrf_process(req::Request, call; enforce::Union{Nothing,Bool} = nothing)
    get(req.meta, :csrf_processing_done, false) && return call()
    req.meta[:csrf_processing_done] = true
    cookie = client_csrf_secret(req)
    # a malformed secret (not one Juango set) is replaced with a new one
    cookie !== nothing && (length(cookie) != CSRF_SECRET_LENGTH || unmask_csrf(cookie) === nothing) && (cookie = nothing)
    cookie === nothing || (req.meta[:csrf_token] = cookie)
    rm = req.resolver_match
    exempt = enforce === nothing ? rm !== nothing && is_csrf_exempt(rm.view) : !enforce
    if !(req.method in SAFE_METHODS) && !get(req.meta, :dont_enforce_csrf, false) && !exempt
        try
            check_csrf(req)
        catch e
            e isa CsrfFailure || rethrow()
            return csrf_failure_response(req, e.reason)
        end
    end
    resp = call()
    if get(req.meta, :csrf_cookie_needs_update, false) || (get(req.meta, :csrf_used, false) && cookie === nothing)
        store_csrf_secret!(req, resp)
    end
    resp
end

function csrf_failure_response(req, reason)
    log!("juango.security.csrf", :warning, "Forbidden (CSRF): $reason: $(req.path)"; request = req, status_code = 403)
    v = settings.CSRF_FAILURE_VIEW
    v === nothing || return to_response(v(req; reason = reason))
    body = """<!doctype html><html><head><title>403 Forbidden</title></head><body>
    <h1>Forbidden <span style="color:#666">(403)</span></h1><p>CSRF verification failed. Request aborted.</p>""" *
           (settings.DEBUG ? "<p>Reason given for failure: <code>$(escape_html(reason))</code></p>" *
                             "<p>Make sure your form includes <code>{% csrf_token %}</code>.</p>" : "") *
           "</body></html>"
    HttpResponseForbidden(body)
end

# --- context processors --------------------------------------------------------------------------

cp_request(req) = Dict("request" => req)
# lazy, so templates that don't use `user`/`perms` don't load the user
cp_auth(req) = Dict{String,Any}("user" => LazyValue(() -> something(req.user, AnonymousUser())),
                                "perms" => LazyValue(() -> PermWrapper(something(req.user, AnonymousUser()))))
"""
The `csrf_token` of a template context: the token is only created (and the CSRF cookie only
set) when a template actually uses it, as with Django's lazy token, so pages without forms
stay cacheable.
"""
struct LazyCsrfToken
    req::Request
end
display_string(t::LazyCsrfToken) = mask_csrf(get_csrf_token(t.req))        # masked: see mask_csrf
Base.string(t::LazyCsrfToken) = mask_csrf(get_csrf_token(t.req))
Base.print(io::IO, t::LazyCsrfToken) = print(io, mask_csrf(get_csrf_token(t.req)))
cp_csrf(req) = Dict("csrf_token" => LazyCsrfToken(req))
cp_messages(req) = Dict("messages" => LazyMessages(req, nothing))
cp_static(req) = Dict("STATIC_URL" => settings.STATIC_URL, "DEBUG" => settings.DEBUG)

tattr(req::Request, ::Val{:get_full_path}) = full_path(req)

push!(MIDDLEWARE_APPS, SessionMiddleware => "sessions", AuthenticationMiddleware => "auth")
