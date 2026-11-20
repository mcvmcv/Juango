# Django's CSRF tests, ported (#227): tests/csrf_tests.
# julia --project=test test/django_csrf.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

djc_post(req; kw...) = HttpResponse("ok")
djc_token(req; kw...) = HttpResponse(Juango.get_csrf_token(req))
djc_exempt(req; kw...) = HttpResponse("exempt")          # (csrf_exempt marks the function itself)

@testset "django csrf: CsrfFunctionTests" begin
    # test_unmask_cipher_token, test_mask_cipher_secret (masking round-trips; every mask differs)
    secret = Juango.random_string(32)
    m1, m2 = Juango.mask_csrf(secret), Juango.mask_csrf(secret)
    @test length(m1) == 64 && m1 != m2 && Juango.unmask_csrf(m1) == secret == Juango.unmask_csrf(m2)
    # test_check_token_format_valid / invalid (a secret, or a masked one, of letters and digits)
    @test Juango.unmask_csrf(secret) == secret
    @test Juango.unmask_csrf("a"^31) === nothing && Juango.unmask_csrf("a"^65) === nothing && Juango.unmask_csrf("@"^32) === nothing
    # is_same_domain (Django's utils.http.is_same_domain)
    @test Juango.is_same_domain("example.com", "example.com") && Juango.is_same_domain("www.example.com", ".example.com") &&
          Juango.is_same_domain("example.com", ".example.com") && !Juango.is_same_domain("example.com", "www.example.com") &&
          !Juango.is_same_domain("evilexample.com", ".example.com") && !Juango.is_same_domain("example.com", "")
end

@testset "django csrf: CsrfViewMiddlewareTests" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("post/", djc_post), path("token/", djc_token), path("exempt/", csrf_exempt(djc_exempt))])
    try
        c = Client(enforce_csrf = true)
        secret = text(get(c, "/token/"))
        cookie = c.cookies["csrftoken"]
        @test length(cookie) == 32 && Juango.unmask_csrf(secret) == cookie        # test_process_response_get_token_used
        # test_no_csrf_cookie, test_csrf_cookie_bad_or_missing_token
        @test post(Client(enforce_csrf = true), "/post/").status == 403
        @test post(c, "/post/").status == 403
        @test post(c, "/post/", Dict("csrfmiddlewaretoken" => "x"^64)).status == 403
        # test_process_request_csrf_cookie_and_token (masked or bare: both accepted)
        @test post(c, "/post/", Dict("csrfmiddlewaretoken" => secret)).status == 200
        @test post(c, "/post/", Dict("csrfmiddlewaretoken" => cookie)).status == 200
        # test_process_request_csrf_cookie_no_token_exempt_view
        @test post(c, "/exempt/").status == 200
        # test_csrf_token_in_header, test_csrf_token_in_header_with_customized_name
        @test post(c, "/post/"; headers = Dict("X-CSRFToken" => secret)).status == 200
        configure!(CSRF_HEADER_NAME = "HTTP_X_CSRFTOKEN_CUSTOMIZED")
        @test post(c, "/post/"; headers = Dict("X-CSRFToken-Customized" => secret)).status == 200
        configure!(CSRF_HEADER_NAME = "HTTP_X_CSRFTOKEN")
        # test_put_and_delete_rejected, test_put_and_delete_allowed
        @test Juango.request(c, "PUT", "/post/").status == 403 && Juango.request(c, "DELETE", "/post/").status == 403
        @test Juango.request(c, "PUT", "/post/"; headers = Dict("X-CSRFToken" => secret)).status == 200
        # test_bad_csrf_cookie_characters, test_bad_csrf_cookie_length (a malformed cookie is replaced, the POST refused)
        c2 = Client(enforce_csrf = true); c2.cookies["csrftoken"] = "(" * "a"^31
        @test post(c2, "/post/", Dict("csrfmiddlewaretoken" => "(" * "a"^31)).status == 403
        get(c2, "/token/"); @test c2.cookies["csrftoken"] != "(" * "a"^31 && length(c2.cookies["csrftoken"]) == 32
        # Origin: test_bad_origin_bad_domain, test_bad_origin_null_origin, test_bad_origin_bad_protocol,
        # test_good_origin_insecure, test_good_origin_csrf_trusted_origin_allowed, ..._wildcard_...
        hdr(o) = Dict("X-CSRFToken" => secret, "Origin" => o)
        @test post(c, "/post/"; headers = hdr("https://www.evil.org")).status == 403
        @test post(c, "/post/"; headers = hdr("null")).status == 403
        @test post(c, "/post/"; headers = hdr("https://testserver")).status == 403              # (https origin, http request)
        @test post(c, "/post/"; headers = hdr("http://testserver")).status == 200
        configure!(CSRF_TRUSTED_ORIGINS = ["https://dashboard.example.com"])
        @test post(c, "/post/"; headers = hdr("https://dashboard.example.com")).status == 200
        @test post(c, "/post/"; headers = hdr("http://dashboard.example.com")).status == 403    # (another scheme)
        configure!(CSRF_TRUSTED_ORIGINS = ["https://*.example.com"])
        @test post(c, "/post/"; headers = hdr("https://foo.example.com")).status == 200
        @test post(c, "/post/"; headers = hdr("https://example.com")).status == 200
        @test post(c, "/post/"; headers = hdr("http://foo.example.com")).status == 403
        @test post(c, "/post/"; headers = hdr("https://foo.example.org")).status == 403
        configure!(CSRF_TRUSTED_ORIGINS = String[])
        # Referer over HTTPS: test_https_no_referer, test_https_bad_referer, test_https_malformed_referer,
        # test_https_good_referer, test_https_csrf_trusted_origin_allowed, test_https_csrf_wildcard_trusted_origin_allowed,
        # test_https_good_referer_matches_cookie_domain(_with_different_port), test_https_reject_insecure_referer
        hs(ref; host = "www.example.com") = (h = Dict("X-CSRFToken" => secret, "X-Forwarded-Proto" => "https", "Host" => host);
                                             ref === nothing || (h["Referer"] = ref); h)
        old_proxy, old_hosts = get(Juango.SETTINGS, :SECURE_PROXY_SSL_HEADER, nothing), Juango.settings.ALLOWED_HOSTS
        configure!(SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https"), ALLOWED_HOSTS = ["*"])
        try
            @test post(c, "/post/"; headers = hs(nothing)).status == 403
            @test post(c, "/post/"; headers = hs("https://www.evil.org/somepage")).status == 403
            @test post(c, "/post/"; headers = hs("http://www.example.com/")).status == 403          # (insecure)
            @test post(c, "/post/"; headers = hs("https://")).status == 403 && post(c, "/post/"; headers = hs("not a url")).status == 403
            @test post(c, "/post/"; headers = hs("https://www.example.com/somepage")).status == 200
            configure!(CSRF_TRUSTED_ORIGINS = ["https://dashboard.example.com"])
            @test post(c, "/post/"; headers = hs("https://dashboard.example.com")).status == 200
            configure!(CSRF_TRUSTED_ORIGINS = ["https://*.example.com"])
            @test post(c, "/post/"; headers = hs("https://dashboard.example.com")).status == 200
            configure!(CSRF_TRUSTED_ORIGINS = String[], CSRF_COOKIE_DOMAIN = ".example.com")
            @test post(c, "/post/"; headers = hs("https://foo.example.com/")).status == 200
            @test post(c, "/post/"; headers = hs("https://foo.example.com:4443/"; host = "www.example.com:4443")).status == 200
            @test post(c, "/post/"; headers = hs("https://foo.example.com/"; host = "www.example.com:4443")).status == 403
            # test_https_good_referer_behind_proxy (USE_X_FORWARDED_HOST / PORT)
            configure!(CSRF_COOKIE_DOMAIN = nothing, USE_X_FORWARDED_HOST = true, USE_X_FORWARDED_PORT = true)
            h = hs("https://foo.example.com/"; host = "10.0.0.2")
            h["X-Forwarded-Host"] = "foo.example.com"; h["X-Forwarded-Port"] = "443"
            @test post(c, "/post/"; headers = h).status == 200
            rq = Juango.Request("GET", "/"); rq.headers["x-forwarded-port"] = "8443"
            @test Juango.get_port(rq) == "8443"
        finally
            configure!(SECURE_PROXY_SSL_HEADER = old_proxy, ALLOWED_HOSTS = old_hosts, CSRF_TRUSTED_ORIGINS = String[],
                       CSRF_COOKIE_DOMAIN = nothing, USE_X_FORWARDED_HOST = false, USE_X_FORWARDED_PORT = false)
        end
        # not translated: the TestingHttpRequest and session-store internals, the logging assertions,
        # the UnreadablePostError/OSError tests, CSRF_USE_SESSIONS (in views.jl)
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end
