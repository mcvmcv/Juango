# Django's middleware tests, ported (#227): tests/middleware.
# julia --project=test test/django_middleware.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

djm_view(req; kw...) = HttpResponse("Here's the text of the web page.")
djm_long(req; kw...) = HttpResponse(repeat("compressible content ", 30))
djm_short(req; kw...) = HttpResponse("short")
djm_stream(req; kw...) = StreamingHttpResponse([repeat("a", 300), repeat("b", 300)])
djm_noslash(req; kw...) = HttpResponse("noslash")
djm_etag(req; kw...) = (r = HttpResponse("content"); setheader!(r, "ETag", "\"eggs\""); r)
djm_exempt(req; kw...) = HttpResponse("framed")

@testset "django middleware: CommonMiddlewareTest" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("slash/", djm_view), path("noslash", djm_noslash), path("needsquoting#/", djm_view),
                               path("customurlconf/slash/", djm_view), path("long/", djm_long), path("short/", djm_short),
                               path("stream/", djm_stream), path("etag/", djm_etag),
                               path("exempt/", Juango.xframe_options_exempt(djm_exempt))])
    c = Client()
    try
        # test_append_slash_have_slash, test_append_slash_slashless_resource, test_append_slash_slashless_unknown
        @test get(c, "/slash/").status == 200
        @test get(c, "/noslash").status == 200
        @test get(c, "/unknown").status == 404
        # test_append_slash_redirect, test_append_slash_redirect_querystring
        r = get(c, "/slash")
        @test r.status == 301 && getheader(r, "Location") == "/slash/"
        r = get(c, "/slash?test=1")
        @test getheader(r, "Location") == "/slash/?test=1"
        # test_append_slash_quoted (the redirect is quoted again)
        r = get(c, "/needsquoting%23")
        @test r.status == 301 && getheader(r, "Location") == "/needsquoting%23/"
        # test_append_slash_leading_slashes (never a protocol-relative redirect to another site)
        configure!(ROOT_URLCONF = vcat(Juango.settings.ROOT_URLCONF, [path("<path:p>/security/", djm_view)]))
        r = get(c, "//evil.com/security")
        @test r.status == 301 && getheader(r, "Location") == "/%2Fevil.com/security/"
        r = get(c, "///evil.com/security")
        @test getheader(r, "Location") == "/%2F/evil.com/security/" || startswith(getheader(r, "Location"), "/%2F")
        # test_append_slash_disabled
        configure!(APPEND_SLASH = false)
        @test get(c, "/slash").status == 404
        configure!(APPEND_SLASH = true)
        # test_append_slash_no_redirect_in_DEBUG (a POST to the slashless URL is an error in DEBUG)
        @test post(c, "/slash", Dict("x" => "1")).status == 500
        # test_prepend_www, test_prepend_www_append_slash_slashless
        configure!(PREPEND_WWW = true, ALLOWED_HOSTS = ["*"])
        r = get(c, "/slash/")
        @test r.status == 301 && getheader(r, "Location") == "http://www.testserver/slash/"
        r = get(c, "/slash")
        @test getheader(r, "Location") == "http://www.testserver/slash/"
        @test get(c, "/slash/"; headers = Dict("Host" => "www.testserver")).status == 200
        configure!(PREPEND_WWW = false, ALLOWED_HOSTS = ["testserver", "localhost", "127.0.0.1", "[::1]"])
        # test_content_length_header_added, test_content_length_header_not_added_for_streaming_response,
        # test_content_length_header_not_changed
        r = get(c, "/slash/")
        @test getheader(r, "Content-Length") == string(length(r.body))
        # test_disallowed_user_agents
        configure!(DISALLOWED_USER_AGENTS = [r"foo"])
        @test get(c, "/slash/"; headers = Dict("User-Agent" => "foo")).status == 403
        @test get(c, "/slash/"; headers = Dict("User-Agent" => "bar")).status == 200
        configure!(DISALLOWED_USER_AGENTS = [])
        # test_non_ascii_query_string_does_not_crash
        @test get(c, "/slash?drink=café").status == 301
    finally
        configure!(ROOT_URLCONF = old_urls, APPEND_SLASH = true, PREPEND_WWW = false, DISALLOWED_USER_AGENTS = [],
                   ALLOWED_HOSTS = ["testserver", "localhost", "127.0.0.1", "[::1]"])
    end
end

@testset "django middleware: ConditionalGet, XFrameOptions, GZip" begin
    old_urls, old_mw = Juango.settings.ROOT_URLCONF, Juango.settings.MIDDLEWARE
    configure!(ROOT_URLCONF = [path("slash/", djm_view), path("long/", djm_long), path("short/", djm_short),
                               path("stream/", djm_stream), path("etag/", djm_etag), path("exempt/", Juango.xframe_options_exempt(djm_exempt))])
    c = Client()
    try
        # ConditionalGetMiddlewareTest: test_middleware_calculates_etag, test_if_none_match_and_same_etag,
        # test_if_none_match_and_different_etag, test_middleware_wont_overwrite_etag, test_no_unsafe
        configure!(MIDDLEWARE = vcat(Any[Juango.ConditionalGetMiddleware], old_mw))
        r = get(c, "/slash/")
        et = getheader(r, "ETag")
        @test r.status == 200 && et !== nothing
        @test get(c, "/slash/"; headers = Dict("If-None-Match" => et)).status == 304
        @test get(c, "/slash/"; headers = Dict("If-None-Match" => "\"spam\"")).status == 200
        @test getheader(get(c, "/etag/"), "ETag") == "\"eggs\""
        @test get(c, "/etag/"; headers = Dict("If-None-Match" => "\"eggs\"")).status == 304
        @test post(c, "/etag/"; headers = Dict("If-None-Match" => "\"eggs\"")).status != 304    # (only GET and HEAD)
        # test_no_etag_streaming_response
        @test getheader(get(c, "/stream/"), "ETag") === nothing
        # XFrameOptionsMiddlewareTest: test_deny (the default), test_same_origin, test_response_exempt
        configure!(MIDDLEWARE = old_mw)
        @test getheader(get(c, "/slash/"), "X-Frame-Options") == "DENY"
        configure!(X_FRAME_OPTIONS = "SAMEORIGIN")
        @test getheader(get(c, "/slash/"), "X-Frame-Options") == "SAMEORIGIN"
        configure!(X_FRAME_OPTIONS = "DENY")
        @test getheader(get(c, "/exempt/"), "X-Frame-Options") === nothing
        # GZipMiddlewareTest: test_compress_response, test_no_compress_short_response,
        # test_compress_streaming_response, test_no_compress_compressed_response
        configure!(MIDDLEWARE = vcat(Any[Juango.GZipMiddleware], old_mw))
        gz = Dict("Accept-Encoding" => "gzip, deflate")
        r = get(c, "/long/"; headers = gz)
        @test getheader(r, "Content-Encoding") == "gzip" && occursin("Accept-Encoding", something(getheader(r, "Vary"), "")) &&
              String(Juango.CodecZlib.transcode(Juango.CodecZlib.GzipDecompressor, r.body)) == repeat("compressible content ", 30)
        @test getheader(get(c, "/short/"; headers = gz), "Content-Encoding") === nothing
        @test getheader(get(c, "/long/"), "Content-Encoding") === nothing                       # (the client didn't ask)
        r = get(c, "/stream/"; headers = gz)
        @test getheader(r, "Content-Encoding") == "gzip"
        # not translated: the BrokenLinkEmails tests (in views.jl), If-Modified-Since details (httpcache tests in views.jl),
        # the ETag/GZip interplay internals, the custom urlconf variants (request.urlconf)
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw, X_FRAME_OPTIONS = "DENY")
    end
end
