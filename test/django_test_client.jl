# Django's test client tests, ported (#227): tests/test_client (ClientTest, RequestFactoryTest) and
# the redirect parts of test_client_regress.
# julia --project=test test/django_test_client.jl   (see setup.jl)
#
# Juango's Client returns the 500 page for an error in a view unless raise_request_exception = true
# (Django's raises by default: a difference kept, Juango's own tests check 500 pages). Each test
# keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

write(joinpath(TPL, "dtc_get.html"), "This is a test. {{ var }} is the value.")
dtc_get(req) = render(req, "dtc_get.html", Dict("var" => get(req.GET, "var", "")))
dtc_post(req) = req.method == "POST" ? HttpResponse("Data received: " * join(["$k=$v" for (k, v) in sort(collect(req.POST))], ",") *
                                                     " | GET: " * join(["$k=$v" for (k, v) in sort(collect(req.GET))], ",")) :
                                       HttpResponse("Viewing $(req.method) page.")
dtc_json(req) = HttpResponse("$(req.method) value: $(Juango.json_body(req)["value"]) GET: " * join(["$k=$v" for (k, v) in sort(collect(req.GET))], ","))
dtc_raw(req) = HttpResponse("raw: " * String(copy(req.body)) * " type: " * something(Juango.header(req, "content-type"), ""))
dtc_header(req) = (r = HttpResponse("ok"); setheader!(r, "X-DJANGO-TEST", "Slartibartfast"); r)
dtc_redirect(req) = HttpResponseRedirect("/get_view/" * (isempty(req.query_string) ? "" : "?" * req.query_string))
dtc_double(req) = HttpResponseRedirect("/redirect_view/")
dtc_permanent(req) = HttpResponsePermanentRedirect("/get_view/")
dtc_307(req) = HttpResponseRedirect("/post_view/"; status = 307)
dtc_308(req) = HttpResponseRedirect("/post_view/"; status = 308)
dtc_relative(req) = HttpResponseRedirect("../../../get_view/")
dtc_query_only(req) = haskey(req.GET, "var") ? HttpResponse("got " * req.GET["var"]) : HttpResponseRedirect("?var=fromquery")
dtc_absolute(req) = HttpResponseRedirect("http://testserver/get_view/?var=abs")
dtc_self(req) = HttpResponseRedirect("/redirect_to_self/")
dtc_changing(req) = HttpResponseRedirect("/redirect_to_self_with_changing_query_view/?counter=$(parse(Int, get(req.GET, "counter", "0")) + 1)")
dtc_session_set(req) = (req.session["tobacconist"] = "hovercraft"; HttpResponse("set"))
dtc_session_check(req) = HttpResponse(string(get(req.session, "tobacconist", "NO")))
dtc_broken(req) = Dict("a" => 1)["b"]
dtc_protected = login_required(req -> HttpResponse("hello " * get_username(req.user)))
dtc_host(req) = HttpResponse(Juango.get_host(req))

@testset "django test_client: ClientTest" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("get_view/", dtc_get), path("post_view/", dtc_post), path("json_view/", dtc_json),
        path("raw_post_view/", dtc_raw), path("header_view/", dtc_header), path("redirect_view/", dtc_redirect),
        path("double_redirect_view/", dtc_double), path("permanent_redirect_view/", dtc_permanent),
        path("redirect_view_307/", dtc_307), path("redirect_view_308/", dtc_308), path("nested/deep/relative/", dtc_relative),
        path("query_only/", dtc_query_only), path("absolute/", dtc_absolute), path("redirect_to_self/", dtc_self),
        path("redirect_to_self_with_changing_query_view/", dtc_changing), path("session_view/", dtc_session_set),
        path("check_session_view/", dtc_session_check), path("broken_view/", dtc_broken),
        path("login_protected_view/", dtc_protected), path("host_view/", dtc_host), path("accounts/", auth_urls())])
    try
        c = Client()
        r = get(c, "/get_view/?var=1")                                                       # test_get_view
        @test r.status == 200 && text(r) == "This is a test. 1 is the value." && r.context["var"] == "1"
        assert_template_used(r, "dtc_get.html")
        r = get(c, "/get_view/"; data = Dict("var" => "☃"))                             # test_query_string_encoding
        @test text(r) == "This is a test. ☃ is the value."
        r = get(c, "/get_view/"; query_params = Dict("var" => "data"))                       # test_query_params (Django 5.1)
        @test text(r) == "This is a test. data is the value."
        r = post(c, "/post_view/", Dict("value" => "37"); query_params = Dict("example" => "data"))
        @test text(r) == "Data received: value=37 | GET: example=data"
        @test_throws ArgumentError get(c, "/get_view/"; data = Dict("a" => "1"), query_params = Dict("b" => "2"))
        @test text(get(c, "/post_view/")) == "Viewing GET page."                             # test_get_post_view
        r = post(c, "/post_view/", Dict("value" => "37"))                                    # test_post
        @test r.status == 200 && text(r) == "Data received: value=37 | GET: "
        for ct in ("application/json", "application/vnd.api+json")                          # test_json_serialization
            r = post(c, "/json_view/", Dict("value" => 37); content_type = ct)
            @test text(r) == "POST value: 37 GET: "
            r = request(c, "PUT", "/json_view/"; data = Dict("value" => 37), content_type = ct)
            @test text(r) == "PUT value: 37 GET: "
        end
        r = post(c, "/raw_post_view/", "<test><title>Hello</title></test>"; content_type = "text/xml")   # test_raw_post
        @test text(r) == "raw: <test><title>Hello</title></test> type: text/xml"
        @test getheader(get(c, "/header_view/"), "X-DJANGO-TEST") == "Slartibartfast"        # test_response_headers
        r = get(c, "/redirect_view/")                                                        # test_redirect
        assert_redirects(r, "/get_view/"; client = c)
        assert_redirects(get(c, "/redirect_view/"; data = Dict("var" => "value")), "/get_view/?var=value"; client = c)   # test_redirect_with_query
        assert_redirects(get(c, "/permanent_redirect_view/"), "/get_view/"; status = 301, client = c)   # test_permanent_redirect
        r = get(c, "/double_redirect_view/"; follow = true)                                  # test_follow_redirect
        @test r.status == 200 && text(r) == "This is a test.  is the value."
        @test redirect_chain(r) == [("/redirect_view/", 302), ("/get_view/", 302)]
        r = get(c, "/nested/deep/relative/"; follow = true)                                  # test_follow_relative_redirect
        @test r.status == 200 && redirect_chain(r) == [("../../../get_view/", 302)]
        r = get(c, "/query_only/"; follow = true)                                            # test_redirect_to_querystring_only
        @test text(r) == "got fromquery" && redirect_chain(r) == [("?var=fromquery", 302)]
        r = get(c, "/absolute/"; follow = true)                                              # test_redirect_http (an absolute URL)
        @test text(r) == "This is a test. abs is the value."
        for v in ("/redirect_view_307/", "/redirect_view_308/")                              # test_follow_307_and_308_redirect
            r = post(c, v, Dict("value" => "test"); follow = true)
            @test text(r) == "Data received: value=test | GET: " && last(redirect_chain(r))[2] in (307, 308)
        end
        r = post(c, "/redirect_view/", Dict("value" => "test"); follow = true)               # (a 302 is followed with GET)
        @test text(r) == "This is a test.  is the value."
        e = try get(c, "/redirect_to_self/"; follow = true) catch e; e end                    # test_redirect_loop
        @test e isa RedirectCycleError && e.msg == "Redirect loop detected." && e.last_response.status == 302
        e = try get(c, "/redirect_to_self_with_changing_query_view/"; data = Dict("counter" => "0"), follow = true) catch e; e end
        @test e isa RedirectCycleError && e.msg == "Too many redirects."                    # test_redirect_to_self_with_changing_query
        @test get(c, "/unknown_view/").status == 404                                          # test_notfound_response

        # sessions and logins
        c = Client()
        post(c, "/session_view/")                                                            # test_session_modifying_view
        @test c.session["tobacconist"] == "hovercraft"
        c2 = Client()
        s = c2.session                                                                        # (Django's client.session, then save)
        s["tobacconist"] = "spam"
        Juango.save_session!(s)
        @test text(get(c2, "/check_session_view/")) == "spam"
        u = create_user("dtc_testclient", "password")
        c = Client()
        @test Juango.login!(c; username = "dtc_testclient", password = "password")           # test_view_with_login
        @test text(get(c, "/login_protected_view/")) == "hello dtc_testclient"
        @test !Juango.login!(Client(); username = "dtc_testclient", password = "wrong")       # test_view_with_bad_login
        r = get(Client(), "/login_protected_view/")
        @test r.status == 302 && startswith(getheader(r, "Location"), "/accounts/login/")
        out = Any[]
        lo(sender; user, kw...) = push!(out, user === nothing ? nothing : get_username(user))
        connect!(user_logged_out, lo)
        try
            key = c.cookies[Juango.settings.SESSION_COOKIE_NAME]
            Juango.logout!(c)                                                                 # test_logout
            @test isempty(c.cookies) && out == ["dtc_testclient"]
            r = get(c, "/login_protected_view/")
            @test r.status == 302
            @test isempty(Juango.load_session(key).data)                                      # (the session is gone from the store)
            c = Client(); force_login!(c, u)                                                  # test_logout_with_force_login
            @test text(get(c, "/login_protected_view/")) == "hello dtc_testclient"
            Juango.logout!(c)
            @test get(c, "/login_protected_view/").status == 302
        finally
            disconnect!(user_logged_out, lo)
            delete!(filter(User; username = "dtc_testclient"))
        end

        # test_view_with_exception: raise_request_exception
        @test get(Client(), "/broken_view/").status == 500
        @test_throws KeyError get(Client(; raise_request_exception = true), "/broken_view/")
        @test get(Client(; raise_request_exception = true), "/unknown_view/").status == 404   # (a 404 is a response all the same)

        # RequestFactoryTest
        rf = RequestFactory()
        for m in ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE")         # test_request_factory
            req = request(rf, m, "/somewhere/")
            @test req.method == m && req.path == "/somewhere/"
        end
        req = get(rf, "/somewhere/?a=1")
        @test req.GET["a"] == "1"
        req = post(rf, "/somewhere/", Dict("x" => "y"))
        @test req.POST["x"] == "y"
        # not translated: secure (https) requests, file uploads (forms.jl), the client's handler
        # internals (response.request, resolver_match, exc_info), the async client, sessions with
        # the cookie backend, the unicode and binary payload variants
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end

@testset "django test_client: join_relative (urljoin)" begin
    jr = Juango.join_relative
    @test jr("/a/b/c", "d") == "/a/b/d" && jr("/a/b/c/", "d") == "/a/b/c/d" && jr("/a/b/c", "../d") == "/a/d"
    @test jr("/a/b/c", "./d") == "/a/b/d" && jr("/a/b/", "..") == "/a/" && jr("/a", "../../x") == "/x"
    @test jr("/a/b", "c?x=1") == "/a/c?x=1"
end
