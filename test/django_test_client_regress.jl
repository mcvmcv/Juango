# Django's test client regression tests, ported (#227): tests/test_client_regress (AssertContainsTests,
# AssertTemplateUsedTests, AssertRedirectsTests, ExceptionTests, TemplateExceptionTests, ContextTests,
# SessionTests, RequestMethodTests, QueryStringTests, UploadedFileEncodingTest).
# julia --project=test test/django_test_client_regress.jl   (see setup.jl)
#
# Juango's assertions throw AssertionError with Django's messages (Julia's repr quotes with "). Each test
# keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

write(joinpath(TPL, "dcr_base.html"), "{% block content %}{% endblock %}")
write(joinpath(TPL, "dcr_child.html"), "{% extends 'dcr_base.html' %}{% block content %}{% include 'dcr_inc.html' %}{{ getfoo }}{% endblock %}")
write(joinpath(TPL, "dcr_inc.html"), "[inc {{ data }}]")
write(joinpath(TPL, "dcr_bad.html"), "{% if %}")
dcr_msg(f) = try f(); "" catch e; e isa AssertionError ? e.msg : rethrow() end

dcr_text(req) = HttpResponse("once twice twice <b>Hello</b> world. Ｈ, unicode: €")
dcr_404(req) = HttpResponseNotFound("not here")
dcr_template(req) = render(req, "dcr_child.html", Dict{String,Any}("data" => "sausage", "get-foo" => get(req.GET, "foo", ""), "getfoo" => get(req.GET, "foo", "")))
dcr_templresp(req) = TemplateResponse(req, "dcr_inc.html", Dict{String,Any}("data" => "deferred"))
dcr_redirect(req) = HttpResponseRedirect("/dcr/get_view/" * (isempty(req.query_string) ? "" : "?" * req.query_string))
dcr_permanent(req) = HttpResponsePermanentRedirect("/dcr/get_view/")
dcr_to_nowhere(req) = HttpResponseRedirect("/dcr/non_existent_view/")
dcr_double(req) = HttpResponseRedirect("/dcr/redirect/")
dcr_absolute(req) = HttpResponseRedirect("http://testserver/dcr/get_view/")
dcr_get(req) = HttpResponse("The GET view " * get(req.GET, "var", ""))
dcr_boom(req) = error("dcr view failed")
dcr_badtpl(req) = render(req, "dcr_bad.html")
dcr_method(req) = HttpResponse("request method: $(req.method)|$(String(copy(req.body)))")
dcr_session(req) = (req.session["tobacconist"] = "hovercraft"; HttpResponse("set"))
dcr_session_read(req) = HttpResponse(string(get(req.session, "tobacconist", "NO SESSION")))

@testset "django test_client_regress" begin
    old = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = vcat(old, [path("dcr/text/", dcr_text), path("dcr/404/", dcr_404), path("dcr/template/", dcr_template),
        path("dcr/templresp/", dcr_templresp), path("dcr/redirect/", dcr_redirect), path("dcr/permanent/", dcr_permanent),
        path("dcr/to_nowhere/", dcr_to_nowhere), path("dcr/double/", dcr_double), path("dcr/absolute/", dcr_absolute),
        path("dcr/get_view/", dcr_get), path("dcr/boom/", dcr_boom), path("dcr/badtpl/", dcr_badtpl),
        path("dcr/method/", csrf_exempt(dcr_method)), path("dcr/session/", dcr_session), path("dcr/session_read/", dcr_session_read)]))
    try
        c = Client()
        @testset "AssertContainsTests" begin
            r = get(c, "/dcr/text/")                                                      # test_contains
            @test assert_contains(r, "once") && assert_contains(r, "once"; count = 1) && assert_contains(r, "twice"; count = 2)
            @test assert_not_contains(r, "never") && assert_contains(r, "never"; count = 0)
            @test startswith(dcr_msg(() -> assert_contains(r, "never")), "Couldn't find \"never\" in the following response\n")
            @test dcr_msg(() -> assert_contains(r, "once"; count = 2)) == "Found 1 instances of \"once\" in response (expected 2)"
            @test startswith(dcr_msg(() -> assert_not_contains(r, "once")), "\"once\" unexpectedly found in the following response\n")
            @test startswith(dcr_msg(() -> assert_contains(r, "never"; msg_prefix = "abc")), "abc: Couldn't find \"never\"")
            @test dcr_msg(() -> assert_contains(r, "twice"; count = 1, msg_prefix = "abc")) == "abc: Found 2 instances of \"twice\" in response (expected 1)"
            r4 = get(c, "/dcr/404/")
            @test dcr_msg(() -> assert_contains(r4, "not here")) == "Couldn't retrieve content: Response code was 404 (expected 200)"
            @test dcr_msg(() -> assert_not_contains(r4, "x"; msg_prefix = "abc")) == "abc: Couldn't retrieve content: Response code was 404 (expected 200)"
            @test assert_contains(r4, "not here"; status = 404)
            @test assert_contains(r, "<b>Hello</b>"; html = true) && assert_not_contains(r, "<i>Hello</i>"; html = true)   # (html = true)
            @test assert_contains(r, "€") && assert_contains(r, "Ｈ")                     # test_unicode_contains
            @test assert_contains(get(c, "/dcr/templresp/"), "[inc deferred]")            # test_assert_contains_renders_template_response
            @test assert_not_contains(get(c, "/dcr/templresp/"), "Hello")                 # test_assert_not_contains_renders_template_response
        end

        @testset "AssertTemplateUsedTests" begin
            r = get(c, "/dcr/text/")                                                      # test_no_context
            @test dcr_msg(() -> assert_template_used(r, "dcr_base.html")) == "No templates used to render the response"
            @test assert_template_not_used(r, "dcr_base.html")
            r = get(c, "/dcr/template/")                                                  # test_single_context / test_multiple_context
            @test assert_template_used(r, "dcr_child.html") && assert_template_used(r, "dcr_base.html") && assert_template_used(r, "dcr_inc.html")
            @test assert_template_used(r, "dcr_child.html"; count = 1)
            @test startswith(dcr_msg(() -> assert_template_used(r, "Valid POST Template")),
                             "Template 'Valid POST Template' was not a template used to render the response. Actual template(s) used: ")
            @test dcr_msg(() -> assert_template_used(r, "dcr_child.html"; count = 2)) ==
                  "Template 'dcr_child.html' was expected to be rendered 2 time(s) but was actually rendered 1 time(s)."
            @test dcr_msg(() -> assert_template_not_used(r, "dcr_inc.html"; msg_prefix = "abc")) ==
                  "abc: Template 'dcr_inc.html' was used unexpectedly in rendering the response"
        end

        @testset "AssertRedirectsTests" begin
            r = get(c, "/dcr/redirect/")                                                  # test_redirect_page
            @test assert_redirects(r, "/dcr/get_view/"; client = c)
            @test dcr_msg(() -> assert_redirects(get(c, "/dcr/permanent/"), "/dcr/get_view/")) ==
                  "Response didn't redirect as expected: Response code was 301 (expected 302)"
            @test assert_redirects(get(c, "/dcr/permanent/"), "/dcr/get_view/"; status = 301)
            @test assert_redirects(get(c, "/dcr/redirect/?var=value"), "/dcr/get_view/?var=value")   # test_lost_query
            @test dcr_msg(() -> assert_redirects(get(c, "/dcr/redirect/?var=value"), "/dcr/get_view/")) ==
                  "Response redirected to '/dcr/get_view/?var=value', expected '/dcr/get_view/'"
            @test dcr_msg(() -> assert_redirects(get(c, "/dcr/to_nowhere/"), "/dcr/non_existent_view/"; client = c)) ==   # test_incorrect_target
                  "Couldn't retrieve redirection page '/dcr/non_existent_view/': response code was 404 (expected 200)"
            @test assert_redirects(get(c, "/dcr/absolute/"), "/dcr/get_view/")            # (http://testserver/x/ is /x/)
            @test assert_redirects(get(c, "/dcr/redirect/"), "http://testserver/dcr/get_view/")
            @test dcr_msg(() -> assert_redirects(get(c, "/dcr/text/"), "/dcr/get_view/")) ==   # test_redirect_on_non_redirect_page
                  "Response didn't redirect as expected: Response code was 200 (expected 302)"
            @test dcr_msg(() -> assert_redirects(get(c, "/dcr/text/"), "/dcr/get_view/"; msg_prefix = "abc")) ==
                  "abc: Response didn't redirect as expected: Response code was 200 (expected 302)"
            r = get(c, "/dcr/double/"; follow = true)                                      # test_redirect_chain
            @test assert_redirects(r, "/dcr/get_view/") && length(redirect_chain(r)) == 2 && text(r) == "The GET view "
            r = get(c, "/dcr/to_nowhere/"; follow = true)                                  # test_redirect_chain_to_non_existent
            @test dcr_msg(() -> assert_redirects(r, "/dcr/non_existent_view/")) ==
                  "Response didn't redirect as expected: Final Response code was 404 (expected 200)"
            r = get(c, "/dcr/permanent/"; follow = true)                                   # (the first step's status is checked)
            @test dcr_msg(() -> assert_redirects(r, "/dcr/get_view/")) ==
                  "Initial response didn't redirect as expected: Response code was 301 (expected 302)"
            @test assert_redirects(r, "/dcr/get_view/"; status = 301)
            r = head(c, "/dcr/redirect/"; follow = true)                                   # test_redirect_chain_head
            @test r.status == 200 && length(redirect_chain(r)) == 1
        end

        @testset "ExceptionTests, TemplateExceptionTests" begin
            e = try get(Client(; raise_request_exception = true), "/dcr/boom/") catch e; e end   # test_exception_cleared
            @test e isa ErrorException && e.msg == "dcr view failed"
            @test get(Client(), "/dcr/boom/").status == 500                               # (raise_request_exception = false)
            e = try get(Client(; raise_request_exception = true), "/dcr/badtpl/") catch e; e end   # test_bad_404_template / TemplateSyntaxError
            @test e isa TemplateSyntaxError
        end

        @testset "ContextTests" begin
            r = get(c, "/dcr/template/?foo=whiz")                                         # test_single_context
            @test r.context["get-foo"] == "whiz" && r.context["data"] == "sausage"
            @test text(r) == "[inc sausage]whiz"
            @test !haskey(r.context, "does-not-exist")                                    # (a missing key)
        end

        @testset "SessionTests, RequestMethodTests, QueryStringTests" begin
            sc = Client()                                                                 # test_session
            @test text(get(sc, "/dcr/session_read/")) == "NO SESSION"
            get(sc, "/dcr/session/")
            @test text(get(sc, "/dcr/session_read/")) == "hovercraft"
            @test text(get(Client(), "/dcr/session_read/")) == "NO SESSION"               # (another client: another session)
            for (f, m) in ((get, "GET"), (post, "POST"), (put, "PUT"), (patch, "PATCH"), (delete, "DELETE"), (options, "OPTIONS"))   # RequestMethodTests
                @test startswith(text(f(c, "/dcr/method/")), "request method: $m|")
            end
            @test head(c, "/dcr/method/").status == 200 && isempty(text(head(c, "/dcr/method/")))   # (HEAD: no body)
            @test trace(c, "/dcr/method/").status == 200
            @test text(put(c, "/dcr/method/", "raw body"; content_type = "text/plain")) == "request method: PUT|raw body"   # RequestMethodStringDataTests
            @test text(patch(c, "/dcr/method/", Dict("a" => 1); content_type = "application/json")) == "request method: PATCH|{\"a\":1}"
            @test text(get(c, "/dcr/get_view/"; data = Dict("var" => "1 2"))) == "The GET view 1 2"   # QueryStringTests
            @test text(get(c, "/dcr/get_view/?var=in+path")) == "The GET view in path"
            @test text(post(c, "/dcr/get_view/?var=query", Dict("var" => "form"))) == "The GET view query"   # (POST: the query string is GET)
        end

        @testset "UploadedFileEncodingTest" begin
            up = UploadedFile("test_file.txt", "hello"; content_type = "text/plain")
            body, ct = Juango.multipart_body(Dict("file" => up))                          # test_file_encoding
            s = String(body)
            @test startswith(ct, "multipart/form-data; boundary=")
            @test occursin("Content-Disposition: form-data; name=\"file\"; filename=\"test_file.txt\"", s) && occursin("Content-Type: text/plain", s)
        end
    finally
        configure!(ROOT_URLCONF = old)
    end
end
