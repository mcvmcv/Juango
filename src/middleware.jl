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
        req.session = load_session(get(req.COOKIES, name, nothing))
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

"Sets `req.user` from the session."
function AuthenticationMiddleware(get_response)
    function (req::Request)
        req.user = get_user(req)
        get_response(req)
    end
end

# --- CSRF --------------------------------------------------------------------------------------

const CSRF_EXEMPT = IdDict{Any,Bool}()
const UNSAFE_METHODS = ("POST", "PUT", "PATCH", "DELETE")

"Mark a view as exempt from CSRF checks (e.g. a webhook endpoint)."
csrf_exempt(view) = (CSRF_EXEMPT[view] = true; view)
is_csrf_exempt(view) = haskey(CSRF_EXEMPT, view)

const VIEW_NAMES = IdDict{Any,String}()

"Human-readable name of a view (used by `showurls` and error pages)."
view_label(v) = haskey(VIEW_NAMES, v) ? VIEW_NAMES[v] : v isa Function ? string(nameof(v)) : string(typeof(v))
"Give a (closure) view a readable name."
name_view!(v, name) = (VIEW_NAMES[v] = string(name); v)

"Copy marker flags (CSRF exemption, display name) from a wrapped view onto its wrapper."
function propagate_flags!(wrapper, view)
    is_csrf_exempt(view) && (CSRF_EXEMPT[wrapper] = true)
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
cp_auth(req) = (u = something(req.user, AnonymousUser()); Dict("user" => u, "perms" => PermWrapper(u)))
cp_csrf(req) = Dict("csrf_token" => get_csrf_token(req))
cp_messages(req) = Dict("messages" => LazyMessages(req, nothing))
cp_static(req) = Dict("STATIC_URL" => settings.STATIC_URL, "DEBUG" => settings.DEBUG)

tattr(req::Request, ::Val{:get_full_path}) = full_path(req)

push!(MIDDLEWARE_APPS, SessionMiddleware => "sessions", AuthenticationMiddleware => "auth")
