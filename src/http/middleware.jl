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
            if s.flushed && haskey(req.COOKIES, name)
                delete_cookie!(resp, name)
            end
            if s.modified && !(resp.status >= 500)
                if isempty(s.data) && s.key === nothing
                    # nothing to store
                else
                    save_session!(s)
                    set_cookie!(resp, name, s.key; max_age = settings.SESSION_COOKIE_AGE, httponly = true,
                                secure = settings.SESSION_COOKIE_SECURE)
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
           resolve(req.path * "/") !== nothing
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

"Mark a view as exempt from CSRF checks (e.g. a webhook endpoint)."
csrf_exempt(view) = (CSRF_EXEMPT[view] = true; view)
is_csrf_exempt(view) = haskey(CSRF_EXEMPT, view)

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
        (rm === nothing || is_login_not_required(rm.view) || req.path == settings.LOGIN_URL || is_authenticated(req.user)) &&
            return get_response(req)
        redirect_to_login(req, settings.LOGIN_URL)
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

function check_csrf(req::Request)
    cookie = get(req.COOKIES, settings.CSRF_COOKIE_NAME, nothing)
    cookie === nothing && throw(CsrfFailure("CSRF cookie not set."))
    origin = header(req, "origin")
    if origin !== nothing && origin != "null"
        host = get_host(req)
        allowed = [("http://" * host), ("https://" * host), settings.CSRF_TRUSTED_ORIGINS...]
        origin in allowed || throw(CsrfFailure("Origin checking failed - $origin does not match any trusted origins."))
    end
    tok = get(req.POST, "csrfmiddlewaretoken", nothing)
    tok === nothing && (tok = header(req, "x-csrftoken"))
    tok === nothing && throw(CsrfFailure("CSRF token missing."))
    consteq(tok, cookie) || throw(CsrfFailure("CSRF token incorrect."))
end

"""
Rejects unsafe requests (POST/PUT/PATCH/DELETE) that lack a valid CSRF token, and
sets the CSRF cookie when a token was used.
"""
function CsrfViewMiddleware(get_response)
    function (req::Request)
        cookie = get(req.COOKIES, settings.CSRF_COOKIE_NAME, nothing)
        cookie === nothing || (req.meta[:csrf_token] = cookie)
        rm = req.resolver_match
        if req.method in UNSAFE_METHODS && !get(req.meta, :dont_enforce_csrf, false) &&
           !(rm !== nothing && is_csrf_exempt(rm.view))
            try
                check_csrf(req)
            catch e
                e isa CsrfFailure || rethrow()
                return csrf_failure_response(req, e.reason)
            end
        end
        resp = get_response(req)
        if get(req.meta, :csrf_cookie_needs_update, false) || (get(req.meta, :csrf_used, false) && cookie === nothing)
            set_cookie!(resp, settings.CSRF_COOKIE_NAME, get_csrf_token(req); max_age = 60 * 60 * 24 * 365,
                        secure = settings.CSRF_COOKIE_SECURE)
            patch_vary!(resp, "Cookie")
        end
        resp
    end
end

function csrf_failure_response(req, reason)
    log!("juango.security.csrf", :warning, "Forbidden (CSRF): $reason: $(req.path)"; request = req, status_code = 403)
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
display_string(t::LazyCsrfToken) = get_csrf_token(t.req)
Base.string(t::LazyCsrfToken) = get_csrf_token(t.req)
Base.print(io::IO, t::LazyCsrfToken) = print(io, get_csrf_token(t.req))
cp_csrf(req) = Dict("csrf_token" => LazyCsrfToken(req))
cp_messages(req) = Dict("messages" => LazyMessages(req, nothing))
cp_static(req) = Dict("STATIC_URL" => settings.STATIC_URL, "DEBUG" => settings.DEBUG)

tattr(req::Request, ::Val{:get_full_path}) = full_path(req)

push!(MIDDLEWARE_APPS, SessionMiddleware => "sessions", AuthenticationMiddleware => "auth")
