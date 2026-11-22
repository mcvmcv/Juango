# Django's decorator tests, ported (#227): tests/decorators (cache, clickjacking, common, csrf, gzip, http,
# vary, csp), tests/conditional_processing (ConditionalGet) and the cache utilities of tests/cache
# (CacheUtils: patch_cache_control, patch_vary_headers, get_max_age).
# julia --project=test test/django_decorators.jl   (see setup.jl)
#
# Juango's decorators wrap views (`never_cache(view)`); Django's tests of decorated methods, async views
# and function attributes are Python's and aren't translated. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dde_req(method = "GET", path = "/"; headers...) =
    Request(method, path; headers = Dict{String,String}("host" => "testserver", (replace(string(k), "_" => "-") => string(v) for (k, v) in headers)...))
dde_view(req; kw...) = HttpResponse("response")

@testset "django decorators: cache" begin
    r = cache_control(dde_view; a = "b")(dde_req())                                     # CacheControlDecoratorTest
    @test getheader(r, "Cache-Control") == "a=b"
    r = never_cache(dde_view)(dde_req())                                                  # test_never_cache_decorator_headers
    @test getheader(r, "Cache-Control") == "max-age=0, no-cache, no-store, must-revalidate, private"
    @test Juango.parse_http_date(getheader(r, "Expires")) !== nothing
    exp_view(req) = (r = HttpResponse("x"); setheader!(r, "Expires", "tomorrow"); r)       # test_never_cache_decorator_expires_not_overridden
    @test getheader(never_cache(exp_view)(dde_req()), "Expires") == "tomorrow"
    old = settings.CACHES                                                                 # CachePageDecoratorTest
    configure!(CACHES = merge(old, Dict("default" => Dict(:backend => :locmem))))
    try
        n = Ref(0)
        v = cache_page(req -> (n[] += 1; HttpResponse("$(n[])")); timeout = 60)
        @test text(v(dde_req("GET", "/cp/"))) == "1" && text(v(dde_req("GET", "/cp/"))) == "1" && n[] == 1
    finally
        configure!(CACHES = old)
    end
end

@testset "django cache utilities: CacheUtils" begin
    for (initial, kw, want) in (                                                          # test_patch_cache_control
            (nothing, (; private = true), ["private"]), ("", (; private = true), ["private"]),
            ("", (; no_cache = "Set-Cookie"), ["no-cache=Set-Cookie"]),
            ("no-cache=Set-Cookie", (; no_cache = true), ["no-cache"]),
            ("no-cache=Set-Cookie,no-cache=Link", (; no_cache = true), ["no-cache"]),
            ("no-cache=Set-Cookie", (; no_cache = "Link"), ["no-cache=Set-Cookie", "no-cache=Link"]),
            ("no-cache=Set-Cookie,no-cache=Link", (; no_cache = "Custom"), ["no-cache=Set-Cookie", "no-cache=Link", "no-cache=Custom"]),
            ("private", (; private = true), ["private"]), ("private", (; public = true), ["public"]),
            ("public", (; public = true), ["public"]), ("public", (; private = true), ["private"]),
            ("must-revalidate,max-age=60,private", (; public = true), ["must-revalidate", "max-age=60", "public"]),
            ("must-revalidate,max-age=60,public", (; private = true), ["must-revalidate", "max-age=60", "private"]),
            ("must-revalidate,max-age=60", (; public = true), ["must-revalidate", "max-age=60", "public"]))
        r = HttpResponse("")
        initial === nothing || setheader!(r, "Cache-Control", initial)
        patch_cache_control!(r; kw...)
        @test Set(strip.(split(getheader(r, "Cache-Control"), ","))) == Set(want)
    end
    r = HttpResponse(""); setheader!(r, "Cache-Control", "max-age=60")                    # (the smaller max-age)
    @test getheader(patch_cache_control!(r; max_age = 3600), "Cache-Control") == "max-age=60"
    for (initial, headers, want) in (                                                     # test_patch_vary_headers
            (nothing, ("Accept-Encoding",), "Accept-Encoding"),
            ("Accept-Encoding", ("accept-encoding",), "Accept-Encoding"),
            ("Accept-Encoding", ("ACCEPT-ENCODING",), "Accept-Encoding"),
            ("Cookie", ("Accept-Encoding",), "Cookie, Accept-Encoding"),
            ("Cookie, Accept-Encoding", ("Accept-Encoding",), "Cookie, Accept-Encoding"),
            ("Cookie, Accept-Encoding", ("Accept-Encoding", "cookie"), "Cookie, Accept-Encoding"),
            (nothing, ("Accept-Encoding", "COOKIE"), "Accept-Encoding, COOKIE"),
            ("Cookie,     Accept-Encoding", ("Accept-Encoding", "cookie"), "Cookie, Accept-Encoding"),
            ("Cookie    ,     Accept-Encoding", ("Accept-Encoding", "cookie"), "Cookie, Accept-Encoding"),
            ("*", ("Accept-Language", "Cookie"), "*"),
            ("Accept-Language, Cookie", ("*",), "*"),
            ("Set-Cookie", ("Cookie",), "Set-Cookie, Cookie"))                            # (a substring isn't the header)
        r = HttpResponse("")
        initial === nothing || setheader!(r, "Vary", initial)
        patch_vary_headers!(r, headers)
        @test getheader(r, "Vary") == want
    end
    r = HttpResponse(""); setheader!(r, "Vary", "Accept-Encoding, Cookie")
    @test has_vary_header(r, "cookie") && !has_vary_header(r, "Accept-Language")
    for (cc, want) in (("max-age=1", 1), ("max-age=2, private", 2), ("public", nothing), ("max-age=abc", nothing), (nothing, nothing))   # test_get_max_age
        r = HttpResponse("")
        cc === nothing || setheader!(r, "Cache-Control", cc)
        @test get_max_age(r) === want
    end
    r = patch_response_headers!(HttpResponse(""); cache_timeout = 30)                     # test_patch_response_headers
    @test get_max_age(r) == 30 && Juango.hasheader(r, "Expires")
    @test get_max_age(patch_response_headers!(HttpResponse(""); cache_timeout = -5)) == 0
end

@testset "django decorators: clickjacking, common, vary, http, gzip" begin
    sec = Juango.SecurityMiddleware
    override_settings(X_FRAME_OPTIONS = "SAMEORIGIN") do
        @test getheader(sec(xframe_options_deny(dde_view))(dde_req()), "X-Frame-Options") == "DENY"   # test_deny_decorator
        @test getheader(sec(xframe_options_sameorigin(dde_view))(dde_req()), "X-Frame-Options") == "SAMEORIGIN"   # test_sameorigin_decorator
        @test getheader(sec(xframe_options_exempt(dde_view))(dde_req()), "X-Frame-Options") === nothing          # test_exempt_decorator
    end
    override_settings(X_FRAME_OPTIONS = "DENY") do
        @test getheader(sec(xframe_options_sameorigin(dde_view))(dde_req()), "X-Frame-Options") == "SAMEORIGIN"   # (the decorator wins over the setting)
    end
    @test getheader(vary_on_headers(dde_view, "Header", "Another-header")(dde_req()), "Vary") == "Header, Another-header"   # VaryOnHeadersTests
    @test getheader(vary_on_cookie(dde_view)(dde_req()), "Vary") == "Cookie"              # VaryOnCookieTests
    for m in ("GET", "HEAD")                                                              # test_require_safe_accepts_only_safe_methods
        @test require_safe(dde_view)(dde_req(m)).status == 200
    end
    for m in ("POST", "PUT", "DELETE")
        r = require_safe(dde_view)(dde_req(m))
        @test r.status == 405 && getheader(r, "Allow") == "GET, HEAD"
    end
    @test require_POST(dde_view)(dde_req("GET")).status == 405 && require_POST(dde_view)(dde_req("POST")).status == 200
    @test require_http_methods(dde_view, ["PUT"])(dde_req("PUT")).status == 200
    big(req) = HttpResponse("a"^500)                                                      # GzipPageTests
    r = gzip_page(big)(dde_req("GET"; accept_encoding = "gzip"))
    @test getheader(r, "Content-Encoding") == "gzip"
    @test getheader(gzip_page(big)(dde_req("GET")), "Content-Encoding") === nothing
    old = (settings.ROOT_URLCONF, settings.APPEND_SLASH)                                 # NoAppendSlashTests
    configure!(ROOT_URLCONF = vcat(old[1], [path("dde/slash/", dde_view), path("dde/noslash/", no_append_slash(req -> HttpResponse("x")))]), APPEND_SLASH = true)
    try
        @test get(Client(), "/dde/slash").status == 301
        @test get(Client(), "/dde/noslash").status == 404
    finally
        configure!(ROOT_URLCONF = old[1], APPEND_SLASH = old[2])
    end
end

@testset "django decorators: csrf" begin
    old = (settings.ROOT_URLCONF, settings.MIDDLEWARE)
    plain(req) = HttpResponse("ok")
    configure!(ROOT_URLCONF = vcat(old[1], [path("dde/protected/", csrf_protect(plain)), path("dde/ensure/", ensure_csrf_cookie(plain)),
                                            path("dde/exempt/", csrf_exempt(req -> HttpResponse("ok"))), path("dde/plain/", plain)]))
    try
        configure!(MIDDLEWARE = filter(m -> m !== Juango.CsrfViewMiddleware, old[2]))             # (without the middleware)
        c = Client(; enforce_csrf = true)
        @test post(c, "/dde/protected/", Dict("a" => "b")).status == 403                  # test_csrf_protect (no token: refused)
        @test post(c, "/dde/plain/", Dict("a" => "b")).status == 200                      # (no middleware, no decorator: allowed)
        r = get(c, "/dde/ensure/")                                                        # test_ensure_csrf_cookie
        @test any(h -> startswith(h, settings.CSRF_COOKIE_NAME * "="), r.cookies)
        configure!(MIDDLEWARE = old[2])
        @test post(Client(; enforce_csrf = true), "/dde/exempt/", Dict("a" => "b")).status == 200   # test_csrf_exempt
        @test post(Client(; enforce_csrf = true), "/dde/plain/", Dict("a" => "b")).status == 403
        @test requires_csrf_token(plain) === plain                                       # test_requires_csrf_token (the token is always available)
    finally
        configure!(ROOT_URLCONF = old[1], MIDDLEWARE = old[2])
    end
end

@testset "django decorators: csp" begin
    pol = Dict("default-src" => ["'self'"])
    v = csp_override(dde_view, pol)
    req = dde_req()
    v(req)
    @test req.meta[:csp_override] == pol                                                  # test_csp_override
    req = dde_req()
    csp_report_only_override(dde_view, pol)(req)
    @test req.meta[:csp_report_only_override] == pol                                      # test_csp_report_only_override
end

const DDE_LAST_MODIFIED = DateTime(2007, 10, 21, 23, 21, 47)
const DDE_LAST_MODIFIED_STR = "Sun, 21 Oct 2007 23:21:47 GMT"
const DDE_LAST_MODIFIED_NEWER_STR = "Mon, 18 Oct 2010 16:56:23 GMT"
const DDE_LAST_MODIFIED_INVALID_STR = "Mon, 32 Oct 2010 16:56:23 GMT"
const DDE_EXPIRED_LAST_MODIFIED_STR = "Sat, 20 Oct 2007 23:21:47 GMT"
const DDE_ETAG = "\"b4246ffc4f62314ca13147c9d4f76974\""
const DDE_WEAK_ETAG = "W/\"b4246ffc4f62314ca13147c9d4f76974\""
const DDE_EXPIRED_ETAG = "\"7fae4cd4b0f81e7d2914700043aa8ed6\""
const DDE_FULL = "Test conditional get response"

@testset "django conditional_processing: ConditionalGet" begin
    full(req; kw...) = HttpResponse(DDE_FULL)
    index = condition(full; last_modified_func = (r; kw...) -> DDE_LAST_MODIFIED, etag_func = (r; kw...) -> DDE_ETAG)
    last_mod = last_modified(full, (r; kw...) -> DDE_LAST_MODIFIED)
    etag_only = etag(full, (r; kw...) -> DDE_ETAG)
    weak = etag(full, (r; kw...) -> DDE_WEAK_ETAG)
    no_etag = etag(full, (r; kw...) -> nothing)
    unquoted = etag(full, (r; kw...) -> DDE_ETAG[2:end-1])
    g(v; method = "GET", h...) = v(dde_req(method, "/condition/"; h...))
    full_ok(r) = r.status == 200 && text(r) == DDE_FULL
    notmod(r) = r.status == 304 && isempty(text(r))
    r = g(index)                                                                          # test_without_conditions
    @test full_ok(r) && getheader(r, "Last-Modified") == DDE_LAST_MODIFIED_STR && getheader(r, "ETag") == DDE_ETAG
    @test notmod(g(index; if_modified_since = DDE_LAST_MODIFIED_STR))                     # test_if_modified_since
    @test notmod(g(index; if_modified_since = DDE_LAST_MODIFIED_NEWER_STR))
    @test full_ok(g(index; if_modified_since = DDE_LAST_MODIFIED_INVALID_STR))
    @test full_ok(g(index; if_modified_since = DDE_EXPIRED_LAST_MODIFIED_STR))
    @test full_ok(g(index; if_unmodified_since = DDE_LAST_MODIFIED_STR))                  # test_if_unmodified_since
    @test full_ok(g(index; if_unmodified_since = DDE_LAST_MODIFIED_NEWER_STR))
    @test full_ok(g(index; if_unmodified_since = DDE_LAST_MODIFIED_INVALID_STR))
    @test g(index; if_unmodified_since = DDE_EXPIRED_LAST_MODIFIED_STR).status == 412
    @test notmod(g(index; if_none_match = DDE_ETAG))                                      # test_if_none_match
    @test full_ok(g(index; if_none_match = DDE_EXPIRED_ETAG))
    @test notmod(g(index; if_none_match = "$DDE_EXPIRED_ETAG, $DDE_ETAG"))                # (several etags)
    @test notmod(g(index; if_none_match = DDE_WEAK_ETAG))                                 # test_weak_if_none_match
    @test notmod(g(weak; if_none_match = DDE_ETAG)) && notmod(g(weak; if_none_match = DDE_WEAK_ETAG))
    @test notmod(g(index; if_none_match = "*"))                                           # test_all_if_none_match
    @test full_ok(g(no_etag; if_none_match = "*"))
    @test full_ok(g(index; if_match = DDE_ETAG))                                          # test_if_match
    @test g(index; if_match = DDE_EXPIRED_ETAG).status == 412
    @test g(index; if_match = DDE_WEAK_ETAG).status == 412                                # test_weak_if_match (strong comparison)
    @test g(weak; if_match = DDE_WEAK_ETAG).status == 412
    @test full_ok(g(index; if_match = "*"))                                               # test_all_if_match
    @test g(no_etag; if_match = "*").status == 412
    @test notmod(g(index; if_none_match = DDE_ETAG, if_modified_since = DDE_LAST_MODIFIED_STR))   # test_both_headers
    @test full_ok(g(index; if_none_match = DDE_EXPIRED_ETAG, if_modified_since = DDE_LAST_MODIFIED_STR))
    @test notmod(g(index; if_none_match = DDE_ETAG, if_modified_since = DDE_EXPIRED_LAST_MODIFIED_STR))
    @test full_ok(g(index; if_none_match = DDE_EXPIRED_ETAG, if_modified_since = DDE_EXPIRED_LAST_MODIFIED_STR))
    @test full_ok(g(index; if_match = DDE_ETAG, if_unmodified_since = DDE_LAST_MODIFIED_STR))     # test_both_headers_2
    @test g(index; if_match = DDE_EXPIRED_ETAG, if_unmodified_since = DDE_LAST_MODIFIED_STR).status == 412
    @test full_ok(g(index; if_match = DDE_ETAG, if_unmodified_since = DDE_EXPIRED_LAST_MODIFIED_STR))   # (If-Match wins)
    @test g(index; if_match = DDE_EXPIRED_ETAG, if_unmodified_since = DDE_EXPIRED_LAST_MODIFIED_STR).status == 412
    @test notmod(g(last_mod; if_modified_since = DDE_LAST_MODIFIED_STR))                  # test_single_condition_1..9
    @test full_ok(g(last_mod; if_none_match = DDE_ETAG))
    @test notmod(g(etag_only; if_none_match = DDE_ETAG))
    @test full_ok(g(etag_only; if_modified_since = DDE_LAST_MODIFIED_STR))
    @test full_ok(g(last_mod; if_unmodified_since = DDE_LAST_MODIFIED_STR))
    @test g(last_mod; if_unmodified_since = DDE_EXPIRED_LAST_MODIFIED_STR).status == 412
    @test full_ok(g(etag_only; if_match = DDE_ETAG)) && g(etag_only; if_match = DDE_EXPIRED_ETAG).status == 412
    @test getheader(g(last_mod), "ETag") === nothing && getheader(g(etag_only), "Last-Modified") === nothing
    @test getheader(g(unquoted), "ETag") == DDE_ETAG                                      # test_unquoted (the etag is quoted)
    @test notmod(g(unquoted; if_none_match = DDE_ETAG))
    @test full_ok(g(index; if_none_match = "\"\"\""))                                     # test_invalid_etag
    r = g(index; method = "POST", if_none_match = DDE_ETAG)                               # (an unsafe method: 412, not 304)
    @test r.status == 412
    @test notmod(g(index; method = "HEAD", if_none_match = DDE_ETAG))                     # test_head
end
