# Django's view tests, ported (#227): tests/view_tests (test_i18n's SetLanguageTests, test_csrf,
# test_defaults) and utils_tests/test_encoding's iri_to_uri.
# julia --project=test test/django_view_tests.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dvt_cookie(r, name) = (c = findfirst(c -> startswith(c, name * "="), r.cookies);
                       c === nothing ? nothing : Dict{String,String}(lowercase(strip(first(split(p, '=')))) => (occursin('=', p) ? split(p, '='; limit = 2)[2] : "true")
                                                                    for p in split(r.cookies[c], "; ")))
dvt_raise(req) = error("boom")
dvt_bad(req) = throw(BadRequest("bad"))
dvt_denied(req) = throw(PermissionDenied("nope"))
dvt_form(req) = HttpResponse("ok")

@testset "django view_tests: SetLanguageTests" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("i18n/", i18n_urls())])
    try
        c = Client()
        @test reverse_url("set_language") == "/i18n/setlang/"                                   # test_setlang_reversal
        r = post(c, "/i18n/setlang/", Dict("language" => "de", "next" => "/"))                  # test_setlang
        @test r.status == 302 && getheader(r, "Location") == "/"
        ck = dvt_cookie(r, "juango_language")
        @test ck["juango_language"] == "de" && ck["path"] == "/" && !haskey(ck, "domain") && !haskey(ck, "secure") &&
              !haskey(ck, "httponly") && !haskey(ck, "samesite")
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de", "next" => "//unsafe/redirection/"))   # test_setlang_unsafe_next
        @test getheader(r, "Location") == "/" && dvt_cookie(r, "juango_language")["juango_language"] == "de"
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"); headers = Dict("Referer" => "/i18n_referer/"))   # test_setlang_redirect_to_referer
        @test getheader(r, "Location") == "/i18n_referer/"
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"); headers = Dict("Referer" => "http://evil.example/"))
        @test getheader(r, "Location") == "/"                                                   # (an unsafe Referer)
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"))                          # test_setlang_default_redirect
        @test r.status == 302 && getheader(r, "Location") == "/"
        json = Dict("Accept" => "application/json")
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de", "next" => "/"); headers = json)   # ..._for_ajax_if_explicitly_requested
        @test r.status == 302 && getheader(r, "Location") == "/"
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"); headers = merge(json, Dict("Referer" => "/i18n_referer/")))
        @test r.status == 204 && dvt_cookie(r, "juango_language")["juango_language"] == "de"     # test_setlang_doesnt_perform_a_redirect_to_referer_for_ajax
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"); headers = json)          # ..._doesnt_perform_a_default_redirect_for_ajax
        @test r.status == 204
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de", "next" => "//unsafe/redirection/"); headers = json)   # test_setlang_unsafe_next_for_ajax
        @test r.status == 302 && getheader(r, "Location") == "/"
        r = get(Client(), "/i18n/setlang/?language=de&next=/somewhere/")                         # (a GET changes nothing)
        @test r.status == 302 && getheader(r, "Location") == "/somewhere/" && dvt_cookie(r, "juango_language") === nothing
        r = post(Client(), "/i18n/setlang/", Dict("language" => "xx", "next" => "/"))           # (an unknown language)
        @test r.status == 302 && dvt_cookie(r, "juango_language") === nothing
        r = post(Client(), "/i18n/setlang/", Dict("language" => "de"); headers = Dict("Referer" => "/te%C3%A9st/"))   # test_setlang_decodes_http_referer_url
        @test getheader(r, "Location") == "/te%C3%A9st/"
        override_settings(LANGUAGE_COOKIE_AGE = 3600 * 7 * 2, LANGUAGE_COOKIE_DOMAIN = ".example.com", LANGUAGE_COOKIE_PATH = "/test/",
                          LANGUAGE_COOKIE_SECURE = true, LANGUAGE_COOKIE_HTTPONLY = true, LANGUAGE_COOKIE_SAMESITE = "Strict") do   # test_setlang_cookie
            ck = dvt_cookie(post(Client(), "/i18n/setlang/", Dict("language" => "de", "next" => "/")), "juango_language")
            @test ck["max-age"] == string(3600 * 7 * 2) && ck["domain"] == ".example.com" && ck["path"] == "/test/" &&
                  haskey(ck, "secure") && haskey(ck, "httponly") && ck["samesite"] == "Strict"
        end
        # (Juango's LANGUAGE_COOKIE_AGE is a year, where Django's is a session cookie: a difference kept)
        @test dvt_cookie(post(Client(), "/i18n/setlang/", Dict("language" => "de", "next" => "/")), "juango_language")["max-age"] == string(365 * 24 * 3600)
        # accepts (Django's HttpRequest.accepts, which set_language uses)
        rf(h) = get(RequestFactory(; headers = h), "/")
        @test accepts(rf(Dict()), "text/html") && accepts(rf(Dict("Accept" => "*/*")), "text/html")
        @test accepts(rf(Dict("Accept" => "text/*")), "text/html") && !accepts(rf(Dict("Accept" => "application/json")), "text/html")
        @test accepts(rf(Dict("Accept" => "text/html,application/xhtml+xml;q=0.9,*/*;q=0.8")), "application/json")
        @test !accepts(rf(Dict("Accept" => "text/html;q=0, application/json")), "text/html")
        # not translated: translated (non-prefix) URL patterns, the JavaScriptCatalog tests (in services.jl)
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end

@testset "django view_tests: test_csrf, test_defaults" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("form/", dvt_form), path("raises500/", dvt_raise), path("raises400/", dvt_bad),
                               path("raises403/", dvt_denied)])
    try
        override_settings(DEBUG = false) do
            r = post(Client(; enforce_csrf = true), "/form/", Dict("x" => "1"))                 # test_no_cookies
            @test r.status == 403 && occursin("CSRF verification failed. Request aborted.", text(r))
            @test occursin("You are seeing this message because this site requires a CSRF cookie when submitting forms.", text(r))
            @test occursin("More information is available with DEBUG=True.", text(r)) && !occursin("Reason given for failure", text(r))
            req = post(RequestFactory(), "/form/")
            r = Juango.csrf_failure_response(req, "Referer checking failed - no Referer.")      # test_no_referer
            @test r.status == 403 && occursin("this HTTPS site requires a “Referer header” to be sent by your web browser", text(r))
            @test occursin("If you have configured your browser to disable “Referer” headers", text(r))
            @test occursin("&lt;meta name=&quot;referrer&quot; content=&quot;no-referrer&quot;&gt;", text(r))   # (escaped, as Django's)
            write(joinpath(TPL, "403_csrf.html"), "Test template for CSRF failure: {{ reason }} {% if no_cookie %}no cookie{% endif %}")
            try
                r = post(Client(; enforce_csrf = true), "/form/", Dict("x" => "1"))             # test_custom_template
                @test r.status == 403 && text(r) == "Test template for CSRF failure: CSRF cookie not set. no cookie"
            finally
                rm(joinpath(TPL, "403_csrf.html"))
                Juango.clear_template_cache!()
            end
        end
        override_settings(DEBUG = true) do                                                       # (with DEBUG, the help)
            r = post(Client(; enforce_csrf = true), "/form/", Dict("x" => "1"))
            @test occursin("Reason given for failure:", text(r)) && occursin("CSRF cookie not set.", text(r)) &&
                  occursin("{% csrf_token %}", text(r))
        end
        # test_defaults: the error pages without templates of the project's own (setup.jl has a 404.html)
        override_settings(DEBUG = false) do
            r = get(Client(), "/nonexistent_url/")                                               # test_page_not_found (setup's 404.html)
            @test r.status == 404 && text(r) == "custom 404 for /nonexistent_url/"
            r = get(Client(), "/raises500/")                                                     # test_server_error
            @test r.status == 500 && occursin("Server Error (500)", text(r)) && startswith(getheader(r, "Content-Type"), "text/html")
            r = get(Client(), "/raises400/")                                                     # test_bad_request
            @test r.status == 400 && occursin("Bad Request (400)", text(r))
            r = get(Client(), "/raises403/")                                                     # test_permission_denied
            @test r.status == 403 && occursin("403 Forbidden", text(r))
            write(joinpath(TPL, "403.html"), "This is a test template for a 403 error ({{ exception }}).")
            write(joinpath(TPL, "400.html"), "This is a test template for a 400 error.")
            write(joinpath(TPL, "500.html"), "This is a test template for a 500 error.")
            try
                Juango.clear_template_cache!()
                @test text(get(Client(), "/raises403/")) == "This is a test template for a 403 error (nope)."   # test_custom_templates
                @test text(get(Client(), "/raises400/")) == "This is a test template for a 400 error."
                @test text(get(Client(), "/raises500/")) == "This is a test template for a 500 error."
            finally
                foreach(n -> rm(joinpath(TPL, n)), ("403.html", "400.html", "500.html"))
                Juango.clear_template_cache!()
            end
            write(joinpath(TPL, "404.html"), "{% csrf_token %}")                                 # test_csrf_token_in_404
            try
                Juango.clear_template_cache!()
                r = get(Client(), "/nonexistent_url/")
                @test r.status == 404 && occursin("csrfmiddlewaretoken", text(r))
            finally
                write(joinpath(TPL, "404.html"), """custom 404 for {{ request_path }}""")
                Juango.clear_template_cache!()
            end
        end
        # not translated: the DEBUG technical pages' details (test_debug: Python tracebacks; Juango's are in
        # views.jl), the translation of the CSRF page, a template engine other than Juango's
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end

@testset "django utils_tests: iri_to_uri" begin
    for (iri, uri) in [("red%09rosé#red", "red%09ros%C3%A9#red"), ("/blog/for/Jürgen Münster/", "/blog/for/J%C3%BCrgen%20M%C3%BCnster/"),
                       ("locations/?place=Président%20Hayes", "locations/?place=Pr%C3%A9sident%20Hayes"),
                       ("/admin/foo/bar/", "/admin/foo/bar/"), ("http://example.com/?q=a+b&x=1", "http://example.com/?q=a+b&x=1"),
                       ("/a\"b<c>d", "/a%22b%3Cc%3Ed")]                                          # test_iri_to_uri
        @test iri_to_uri(iri) == uri
    end
    @test getheader(HttpResponseRedirect("/café/"), "Location") == "/caf%C3%A9/"            # (redirects are ASCII)
    @test getheader(redirect("/祖/"), "Location") == "/%E7%A5%96/"
end
