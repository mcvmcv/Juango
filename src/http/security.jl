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
        s.X_FRAME_OPTIONS === nothing || hasheader(resp, "X-Frame-Options") || setheader!(resp, "X-Frame-Options", string(s.X_FRAME_OPTIONS))
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
csp_nonce(req::Request) = get!(() -> base64encode(rand(RandomDevice(), UInt8, 16)), req.meta, :csp_nonce)::String

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

"The deployment checks as CheckMessages, with Django's ids (`check --deploy`)."
function deploy_checks()
    s = settings
    out = CheckMessage[]
    w(id, msg) = push!(out, CheckMessage(:warning, msg; id = id))
    s.DEBUG && w("security.W018", "DEBUG is true: error pages show code and settings. Set DEBUG = false in production.")
    (s.SECRET_KEY == default_settings()[:SECRET_KEY] || length(s.SECRET_KEY) < 50 || length(Set(s.SECRET_KEY)) < 5) &&
        w("security.W009", "SECRET_KEY is the default, or shorter than 50 characters or with fewer than 5 different ones. Generate a long random key.")
    all(h -> h in ("localhost", "127.0.0.1", "[::1]"), s.ALLOWED_HOSTS) &&
        w("security.W020", "ALLOWED_HOSTS has only local addresses: set it to the site's domain names.")
    mws = s.MIDDLEWARE
    SecurityMiddleware in mws || w("security.W001", "SecurityMiddleware isn't in MIDDLEWARE: the security headers and HTTPS settings do nothing.")
    s.SECURE_HSTS_SECONDS == 0 &&
        w("security.W004", "SECURE_HSTS_SECONDS is 0. Once the whole site is on HTTPS, set it (for instance to 31536000) so browsers refuse plain HTTP.")
    s.SECURE_HSTS_SECONDS > 0 && !s.SECURE_HSTS_INCLUDE_SUBDOMAINS &&
        w("security.W005", "SECURE_HSTS_INCLUDE_SUBDOMAINS is false: subdomains can still be reached over plain HTTP.")
    s.SECURE_SSL_REDIRECT || w("security.W008", "SECURE_SSL_REDIRECT is false: plain-HTTP requests aren't redirected to HTTPS (unless your proxy does it).")
    s.SESSION_COOKIE_SECURE || w("security.W012", "SESSION_COOKIE_SECURE is false: the session cookie can be sent over plain HTTP.")
    s.CSRF_COOKIE_SECURE || w("security.W016", "CSRF_COOKIE_SECURE is false: the CSRF cookie can be sent over plain HTTP.")
    s.X_FRAME_OPTIONS == "DENY" || w("security.W019", "X_FRAME_OPTIONS isn't DENY: pages can be framed by other sites unless they need to be.")
    ContentSecurityPolicyMiddleware in mws || isempty(s.SECURE_CSP) ||
        w("security.W026", "SECURE_CSP is set but ContentSecurityPolicyMiddleware isn't in MIDDLEWARE.")
    CsrfViewMiddleware in mws || w("security.W003", "CsrfViewMiddleware isn't in MIDDLEWARE: forms and other unsafe requests aren't protected against cross-site request forgery.")
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
