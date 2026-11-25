# Security: HTTPS redirects, HSTS, Content-Security-Policy, deployment checks ----------------------------
#
#     configure!(SECURE_SSL_REDIRECT = true, SECURE_HSTS_SECONDS = 31536000,
#                SECURE_PROXY_SSL_HEADER = ("X-Forwarded-Proto", "https"),     # behind a proxy that sets it
#                SECURE_CSP = Dict("default-src" => [CSP.SELF], "script-src" => [CSP.SELF, CSP.NONCE]),
#                MIDDLEWARE = [SecurityMiddleware, ContentSecurityPolicyMiddleware, ...])
#
#     <script nonce="{{ csp_nonce }}">...</script>

"Request header name in Django's `HTTP_X_FORWARDED_PROTO` form or plain `X-Forwarded-Proto`, as Juango stores it."
function header_key(name)
    s = string(name)
    startswith(s, "HTTP_") && (s = replace(s[6:end], '_' => '-'))
    lowercase(s)
end

"""
    is_secure(req) -> Bool

Whether the request came over HTTPS: served by `runserver` with a certificate, or (behind a
proxy) carrying the header and value named by `SECURE_PROXY_SSL_HEADER`, e.g.
`("X-Forwarded-Proto", "https")`. Only set that when the proxy always sets or strips the
header, or clients could claim HTTPS.
"""
function is_secure(req::Request)
    get(req.meta, :secure, false) === true && return true
    h = settings.SECURE_PROXY_SSL_HEADER
    h === nothing && return false
    v = get(req.headers, header_key(h[1]), nothing)
    v !== nothing && strip(first(split(v, ','))) == h[2]
end

"""
    SecurityMiddleware

Security headers and HTTPS:

- `SECURE_SSL_REDIRECT`: redirect plain-HTTP requests to HTTPS (to `SECURE_SSL_HOST` if set),
  except paths matching a regex in `SECURE_REDIRECT_EXEMPT`.
- `SECURE_HSTS_SECONDS` (with `SECURE_HSTS_INCLUDE_SUBDOMAINS`, `SECURE_HSTS_PRELOAD`):
  `Strict-Transport-Security` on HTTPS responses.
- `X-Content-Type-Options: nosniff` (`SECURE_CONTENT_TYPE_NOSNIFF`), `X-Frame-Options`
  (`X_FRAME_OPTIONS`), `Referrer-Policy` (`SECURE_REFERRER_POLICY`) and
  `Cross-Origin-Opener-Policy` (`SECURE_CROSS_ORIGIN_OPENER_POLICY`).
"""
function SecurityMiddleware(get_response)
    function (req::Request)
        if settings.SECURE_SSL_REDIRECT && !is_secure(req) &&
           !any(p -> occursin(Regex(p), lstrip(req.path, '/')), settings.SECURE_REDIRECT_EXEMPT)
            host = something(settings.SECURE_SSL_HOST, get_host(req))
            return HttpResponsePermanentRedirect("https://" * host * full_path(req))
        end
        resp = get_response(req)
        s = settings
        if s.SECURE_HSTS_SECONDS > 0 && is_secure(req) && !hasheader(resp, "Strict-Transport-Security")
            setheader!(resp, "Strict-Transport-Security", "max-age=$(s.SECURE_HSTS_SECONDS)" *
                       (s.SECURE_HSTS_INCLUDE_SUBDOMAINS ? "; includeSubDomains" : "") * (s.SECURE_HSTS_PRELOAD ? "; preload" : ""))
        end
        s.SECURE_CONTENT_TYPE_NOSNIFF && !hasheader(resp, "X-Content-Type-Options") && setheader!(resp, "X-Content-Type-Options", "nosniff")
        s.X_FRAME_OPTIONS === nothing || get(req.meta, :xframe_options_exempt, false) || hasheader(resp, "X-Frame-Options") ||
            setheader!(resp, "X-Frame-Options", string(s.X_FRAME_OPTIONS))
        s.SECURE_REFERRER_POLICY === nothing || hasheader(resp, "Referrer-Policy") ||
            setheader!(resp, "Referrer-Policy", s.SECURE_REFERRER_POLICY isa AbstractString ? s.SECURE_REFERRER_POLICY : join(s.SECURE_REFERRER_POLICY, ","))
        s.SECURE_CROSS_ORIGIN_OPENER_POLICY === nothing || hasheader(resp, "Cross-Origin-Opener-Policy") ||
            setheader!(resp, "Cross-Origin-Opener-Policy", string(s.SECURE_CROSS_ORIGIN_OPENER_POLICY))
        resp
    end
end

# --- Content-Security-Policy -------------------------------------------------------------------------

"""
Source keywords for `SECURE_CSP`: `CSP.SELF`, `CSP.NONE`, `CSP.NONCE` (the request's nonce),
`CSP.UNSAFE_INLINE`, `CSP.UNSAFE_EVAL`, `CSP.STRICT_DYNAMIC`, `CSP.REPORT_SAMPLE`,
`CSP.UNSAFE_HASHES`, `CSP.WASM_UNSAFE_EVAL`.
"""
const CSP = (SELF = "'self'", NONE = "'none'", NONCE = "<CSP_NONCE_SENTINEL>", UNSAFE_INLINE = "'unsafe-inline'",
             UNSAFE_EVAL = "'unsafe-eval'", STRICT_DYNAMIC = "'strict-dynamic'", REPORT_SAMPLE = "'report-sample'",
             UNSAFE_HASHES = "'unsafe-hashes'", WASM_UNSAFE_EVAL = "'wasm-unsafe-eval'")

"The request's CSP nonce (made on first use; only then does the header carry it)."
csp_nonce(req::Request) = get!(() -> b64url(rand(RandomDevice(), UInt8, 16)), req.meta, :csp_nonce)::String

"`{{ csp_nonce }}` in templates: the nonce, made only if a template uses it."
struct CspNonce
    req::Request
end
display_string(n::CspNonce) = csp_nonce(n.req)
Base.print(io::IO, n::CspNonce) = print(io, csp_nonce(n.req))
cp_csp(req) = Dict("csp_nonce" => CspNonce(req))

"""
    csp_header(policy, nonce) -> String

A policy `Dict` (directive => source list, a string, or `true` for a bare directive such as
`"upgrade-insecure-requests"`) as a header value. `CSP.NONCE` becomes `'nonce-...'`, or is
left out when no nonce was used.
"""
function csp_header(policy, nonce)
    parts = String[]
    for (d, v) in sort!(collect(pairs(policy)); by = p -> string(first(p)))
        (v === false || v === nothing) && continue
        if v === true || (v isa AbstractVector && isempty(v))
            push!(parts, string(d))
            continue
        end
        srcs = String[]
        for x in (v isa AbstractString ? split(v) : v)
            x == CSP.NONCE ? (nonce === nothing || push!(srcs, "'nonce-$nonce'")) : push!(srcs, string(x))
        end
        isempty(srcs) || push!(parts, string(d) * " " * join(unique(srcs), " "))
    end
    join(parts, "; ")
end

"""
    ContentSecurityPolicyMiddleware

Adds `Content-Security-Policy` from `SECURE_CSP` and `Content-Security-Policy-Report-Only`
from `SECURE_CSP_REPORT_ONLY` (empty = no header) to responses that don't set their own.
Views can change the policy for their responses with `csp_override(view, policy)` (or
`nothing` to send none).
"""
function ContentSecurityPolicyMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        nonce = get(req.meta, :csp_nonce, nothing)
        for (setting, h, key) in ((:SECURE_CSP, "Content-Security-Policy", :csp_override),
                                  (:SECURE_CSP_REPORT_ONLY, "Content-Security-Policy-Report-Only", :csp_report_only_override))
            hasheader(resp, h) && continue
            policy = haskey(req.meta, key) ? req.meta[key] : getproperty(settings, setting)
            (policy === nothing || isempty(policy)) && continue
            v = csp_header(policy, nonce)
            isempty(v) || setheader!(resp, h, v)
        end
        resp
    end
end

"""
    csp_override(view, policy)    csp_report_only_override(view, policy)

Use another policy (a `Dict` like `SECURE_CSP`, or `nothing` for no header) for the view's responses.
"""
function csp_override(view, policy; key = :csp_override)
    w = (req; kw...) -> (req.meta[key] = policy; view(req; kw...))
    propagate_flags!(w, view)
end
csp_report_only_override(view, policy) = csp_override(view, policy; key = :csp_report_only_override)

# --- check --deploy ------------------------------------------------------------------------------------

"""
    deploy_issues() -> Vector{String}

Settings that are unsafe in production (`manage.jl check --deploy`).
"""
function deploy_issues()
    [m.msg for m in deploy_checks()]
end

const REFERRER_POLICY_VALUES = Set(["no-referrer", "no-referrer-when-downgrade", "origin", "origin-when-cross-origin", "same-origin",
                                    "strict-origin", "strict-origin-when-cross-origin", "unsafe-url"])
const CROSS_ORIGIN_OPENER_POLICY_VALUES = Set(["same-origin", "same-origin-allow-popups", "unsafe-none"])
"A secret key long and varied enough (Django's: 50 characters, 5 different ones, not the default or django-insecure-)."
strong_secret_key(k) = k isa AbstractString && k != default_settings()[:SECRET_KEY] && length(k) >= 50 && length(Set(k)) >= 5 &&
                       !startswith(k, "django-insecure-")

"""
The deployment checks as CheckMessages, with Django's ids and conditions (`check --deploy`): the HTTPS,
HSTS, nosniff, referrer and opener policy checks only when SecurityMiddleware (which sends those headers,
and X-Frame-Options) is in MIDDLEWARE; the session cookie checks when sessions are used; the CSRF
cookie's when CsrfViewMiddleware is used with a cookie.
"""
function deploy_checks()
    s = settings
    out = CheckMessage[]
    w(id, msg; level = :warning, hint = nothing) = push!(out, CheckMessage(level, msg; id = id, hint = hint))
    mws = s.MIDDLEWARE
    sec = SecurityMiddleware in mws
    s.DEBUG && w("security.W018", "You should not have DEBUG set to true in deployment.")
    strong_secret_key(s.SECRET_KEY) ||
        w("security.W009", "Your SECRET_KEY has less than 50 characters, less than 5 unique characters, or is the default. Please generate a long and random value, otherwise many of Juango's security-critical features will be vulnerable to attack.")
    for (i, k) in enumerate(something(get(s, :SECRET_KEY_FALLBACKS, String[]), String[]))
        strong_secret_key(k) ||
            w("security.W025", "Your SECRET_KEY_FALLBACKS[$(i-1)] has less than 50 characters, less than 5 unique characters, or is the default. Please generate a long and random value, otherwise many of Juango's security-critical features will be vulnerable to attack.")
    end
    all(h -> h in ("localhost", "127.0.0.1", "[::1]"), s.ALLOWED_HOSTS) &&
        w("security.W020", "ALLOWED_HOSTS has only local addresses (or none): set it to the site's domain names.")
    sec || w("security.W001", "You do not have SecurityMiddleware in your MIDDLEWARE so the SECURE_HSTS_SECONDS, SECURE_CONTENT_TYPE_NOSNIFF, SECURE_REFERRER_POLICY, SECURE_CROSS_ORIGIN_OPENER_POLICY, X_FRAME_OPTIONS and SECURE_SSL_REDIRECT settings will have no effect.")
    if sec
        s.X_FRAME_OPTIONS === nothing &&
            w("security.W002", "X_FRAME_OPTIONS is nothing, so your pages will not be served with an 'x-frame-options' header. Unless there is a good reason for your site to be served in a frame, you should consider enabling this header to help prevent clickjacking attacks.")
        s.X_FRAME_OPTIONS === nothing || s.X_FRAME_OPTIONS == "DENY" ||
            w("security.W019", "X_FRAME_OPTIONS is not set to 'DENY'. Unless there is a good reason for your site to serve other parts of itself in a frame, you should change it to 'DENY'.")
        hsts = something(s.SECURE_HSTS_SECONDS, 0)
        hsts == 0 &&
            w("security.W004", "You have not set a value for the SECURE_HSTS_SECONDS setting. If your entire site is served only over SSL, you may want to consider setting a value and enabling HTTP Strict Transport Security. Be sure to read the documentation first; enabling HSTS carelessly can cause serious, irreversible problems.")
        hsts > 0 && s.SECURE_HSTS_INCLUDE_SUBDOMAINS !== true &&
            w("security.W005", "You have not set the SECURE_HSTS_INCLUDE_SUBDOMAINS setting to true. Without this, your site is potentially vulnerable to attack via an insecure connection to a subdomain. Only set this to true if you are certain that all subdomains of your domain should be served exclusively via SSL.")
        hsts > 0 && s.SECURE_HSTS_PRELOAD !== true &&
            w("security.W021", "You have not set the SECURE_HSTS_PRELOAD setting to true. Without this, your site cannot be submitted to the browser preload list.")
        s.SECURE_CONTENT_TYPE_NOSNIFF === true ||
            w("security.W006", "Your SECURE_CONTENT_TYPE_NOSNIFF setting is not set to true, so your pages will not be served with an 'X-Content-Type-Options: nosniff' header. You should consider enabling this header to prevent the browser from identifying content types incorrectly.")
        s.SECURE_SSL_REDIRECT === true ||
            w("security.W008", "Your SECURE_SSL_REDIRECT setting is not set to true. Unless your site should be available over both SSL and non-SSL connections, you may want to either set this setting true or configure a load balancer or reverse-proxy server to redirect all connections to HTTPS.")
        rp = s.SECURE_REFERRER_POLICY
        if rp === nothing
            w("security.W022", "You have not set the SECURE_REFERRER_POLICY setting. Without this, your site will not send a Referrer-Policy header. You should consider enabling this header to protect user privacy.")
        else
            vals = rp isa AbstractString ? Set(strip.(split(rp, ','))) : Set(string.(collect(rp)))
            vals ⊆ REFERRER_POLICY_VALUES ||
                w("security.E023", "You have set the SECURE_REFERRER_POLICY setting to an invalid value."; level = :error,
                  hint = "Valid values are: $(join(sort!(collect(REFERRER_POLICY_VALUES)), ", ")).")
        end
        coop = s.SECURE_CROSS_ORIGIN_OPENER_POLICY
        coop === nothing || coop in CROSS_ORIGIN_OPENER_POLICY_VALUES ||
            w("security.E024", "You have set the SECURE_CROSS_ORIGIN_OPENER_POLICY setting to an invalid value."; level = :error,
              hint = "Valid values are: $(join(sort!(collect(CROSS_ORIGIN_OPENER_POLICY_VALUES)), ", ")).")
    end
    # the session cookie (Django's W010-W015): by the sessions app, the middleware, or both
    session_app = is_installed("sessions")
    session_mw = SessionMiddleware in mws
    for (setting, ids, why) in ((:SESSION_COOKIE_SECURE, ("W010", "W011", "W012"),
                                 "Using a secure-only session cookie makes it more difficult for network traffic sniffers to hijack user sessions."),
                                (:SESSION_COOKIE_HTTPONLY, ("W013", "W014", "W015"),
                                 "Using an HttpOnly session cookie makes it more difficult for cross-site scripting attacks to hijack user sessions."))
        get(s, setting, false) === true && continue
        if session_app && session_mw
            w("security." * ids[3], "$setting is not set to true. $why")
        elseif session_app
            w("security." * ids[1], "You have the sessions app in your INSTALLED_APPS, but you have not set $setting to true. $why")
        elseif session_mw
            w("security." * ids[2], "You have SessionMiddleware in your MIDDLEWARE, but you have not set $setting to true. $why")
        end
    end
    ContentSecurityPolicyMiddleware in mws || isempty(s.SECURE_CSP) ||
        w("security.W026", "SECURE_CSP is set but ContentSecurityPolicyMiddleware isn't in MIDDLEWARE.")
    csrf = CsrfViewMiddleware in mws
    csrf || w("security.W003", "You don't appear to be using Juango's built-in cross-site request forgery protection via the middleware (CsrfViewMiddleware is not in your MIDDLEWARE). Enabling the middleware is the safest approach to ensure you don't leave any holes.")
    csrf && !s.CSRF_USE_SESSIONS && s.CSRF_COOKIE_SECURE !== true &&
        w("security.W016", "You have CsrfViewMiddleware in your MIDDLEWARE, but you have not set CSRF_COOKIE_SECURE to true. Using a secure-only CSRF cookie makes it more difficult for network traffic sniffers to steal the CSRF token.")
    "*" in s.ALLOWED_HOSTS && w("juango.W101", "ALLOWED_HOSTS contains \"*\": any Host header is accepted, so links built from it (password reset emails, absolute URLs) can point elsewhere.")
    for (alias, c) in pairs(s.CACHES)
        get(c, :serializer, :json) === :serialization && get(c, :backend, :locmem) !== :locmem &&
            w("juango.W102", "Cache \"$alias\" stores Julia's Serialization format in a shared store: anyone who can write to it can make Juango deserialise arbitrary values. Use the JSON serializer unless the store is trusted.")
    end
    limits = [k for k in (:DATA_UPLOAD_MAX_MEMORY_SIZE, :FILE_UPLOAD_MAX_SIZE, :DATA_UPLOAD_MAX_NUMBER_FIELDS, :DATA_UPLOAD_MAX_NUMBER_FILES)
              if get(s, k, 0) === nothing]
    isempty(limits) || w("juango.W103", "Request limits are off ($(join(limits, ", ")) = nothing): a client can send requests big enough to exhaust memory.")
    something(get(s, :SERVER_READ_HEADER_TIMEOUT, nothing), 0) > 0 && something(get(s, :SERVER_IDLE_TIMEOUT, nothing), 0) > 0 ||
        w("juango.W104", "SERVER_READ_HEADER_TIMEOUT or SERVER_IDLE_TIMEOUT is off: slow or idle clients can hold runserver's connections open indefinitely.")
    out
end
