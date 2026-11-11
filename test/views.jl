# views: julia --project=test test/views.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "auth" begin
    h = make_password("s3cret")
    @test startswith(h, "pbkdf2_sha256\$1000\$")
    @test check_password("s3cret", h) && !check_password("nope", h)
    # Reference: base64(hashlib.pbkdf2_hmac("sha256", b"password", b"seasalt", 1000)), as Django computes it
    @test make_password("password"; salt = "seasalt", iterations = 1000) ==
          "pbkdf2_sha256\$1000\$seasalt\$" * "YIWkt6M1JFXrHg5s0jZjBSc7C2Cz6QvchSJ0h8Y+i7c="
    u = create_user("alice", "wonderland"; email = "a@x.io")
    @test authenticate("alice", "wonderland") == u
    @test authenticate("alice", "wrong") === nothing
    @test authenticate("nobody", "x") === nothing
    u.is_active = false
    save!(u)
    @test authenticate("alice", "wonderland") === nothing
    u.is_active = true
    save!(u)
    @test_throws ArgumentError create_user("bad name!", "x")
end

@testset "client: views, sessions, messages" begin
    c = Client()
    r = get(c, "/")
    @test r.status == 200 && occursin("Hello World", text(r)) && r.templates == ["child.html"]
    @test getheader(r, "X-Frame-Options") == "DENY"

    @test text(get(c, "/counter/")) == "1"
    @test text(get(c, "/counter/")) == "2"
    @test text(get(Client(), "/counter/")) == "1"

    r = get(c, "/articles")                                            # APPEND_SLASH
    @test r.status == 301 && getheader(r, "Location") == "/articles/"

    r = get(c, "/nope/")
    @test r.status == 404 && occursin("Page not found", text(r)) && occursin("articles/&lt;int:id&gt;/", text(r))
    configure!(DEBUG = false)
    r = get(c, "/nope/")
    @test r.status == 404 && text(r) == "custom 404 for /nope/"
    r = get(c, "/boom/")
    @test r.status == 500 && occursin("Server Error", text(r))
    configure!(DEBUG = true)
    r = @test_logs (:error,) match_mode = :any get(c, "/boom/")
    @test r.status == 500 && occursin("kaboom", text(r))
    @test get(c, "/forbidden/").status == 403

    r = get(c, "/api/"; data = Dict("q" => "a b"))
    @test r.status == 200 && getheader(r, "Content-Type") == "application/json" && occursin("\"q\":\"a b\"", text(r))
    @test post(c, "/api/").status == 405
    @test text(request(c, "POST", "/json/"; json = Dict("x" => 42))) == "{\"got\":42}"

    r = get(c, "/contact/")
    @test r.status == 200 && r.context["form"] isa Form
    r = post(c, "/contact/", Dict("name" => "Zoe", "email" => "z@x.io", "password" => "p", "confirm" => "p"); follow = true)
    @test r.status == 200 && occursin("<p class=\"success\">Thanks, Zoe!</p>", text(r))
    @test !occursin("Thanks", text(get(c, "/contact/")))                # messages are one-shot
    r = post(c, "/contact/", Dict("name" => "Zoe"))
    @test r.status == 200 && occursin("errorlist", text(r))
end

@testset "client: csrf" begin
    c = Client(enforce_csrf = true)
    @test post(c, "/contact/", Dict("name" => "x")).status == 403
    r = get(c, "/contact/")
    tok = match(r"name=\"csrfmiddlewaretoken\" value=\"(\w+)\"", text(r))[1]
    @test haskey(c.cookies, "csrftoken") && c.cookies["csrftoken"] == tok
    r = post(c, "/contact/", Dict("csrfmiddlewaretoken" => tok, "name" => "Q", "email" => "q@x.io",
                                  "password" => "p", "confirm" => "p"))
    @test r.status == 302
    @test post(c, "/contact/", Dict("csrfmiddlewaretoken" => "wrong")).status == 403
    @test request(c, "POST", "/contact/"; headers = Dict("X-CSRFToken" => tok), data = Dict("name" => "")).status == 200
    @test post(c, "/hook/").status == 200                                # csrf_exempt
end

@testset "client: auth flow" begin
    c = Client()
    @test text(get(c, "/whoami/")) == "anon"
    r = get(c, "/secret/")
    @test r.status == 302 && getheader(r, "Location") == "/accounts/login/?next=%2Fsecret%2F"
    r = post(c, "/accounts/login/?next=/secret/", Dict("username" => "alice", "password" => "bad"))
    @test r.status == 200 && occursin("correct username and password", text(r))
    r = post(c, "/accounts/login/?next=/secret/", Dict("username" => "alice", "password" => "wonderland"); follow = true)
    @test text(r) == "secret for alice"
    @test text(get(c, "/whoami/")) == "user:alice"
    r = post(c, "/accounts/logout/")
    @test r.status == 302
    @test text(get(c, "/whoami/")) == "anon"
    c2 = Client()
    force_login!(c2, get(User; username = "alice"))
    @test text(get(c2, "/secret/")) == "secret for alice"
    # changing the password invalidates existing sessions
    u = get(User; username = "alice"); set_password!(u, "new-pass"); save!(u)
    @test text(get(c2, "/whoami/")) == "anon"
end

@testset "generic views" begin
    ann = ann_author()
    for i in 1:3
        create(Article; title = "GV $i", author = ann)
    end
    c = Client()
    r = get(c, "/articles/")
    @test r.status == 200 && occursin("<li>GV 3</li>", text(r))
    r = get(c, "/blog/?page=2")
    @test r.status == 200 && occursin("page 2/", text(r))
    @test get(c, "/blog/?page=999").status == 404
    a = first(filter(Article; title = "GV 1"))
    r = get(c, "/articles/$(a.id)/")
    @test occursin("<h1>GV 1</h1><p>Ann</p><a href=\"/articles/$(a.id)/\">", text(r))
    @test get(c, "/articles/999999/").status == 404
    r = post(c, "/articles/new/", Dict("title" => "Created", "author" => string(ann.id), "status" => "d"))
    new = get(Article; title = "Created")
    @test r.status == 302 && getheader(r, "Location") == "/articles/$(new.id)/"
    r = post(c, "/articles/new/", Dict("title" => ""))
    @test r.status == 200 && occursin("This field is required.", text(r))
    r = post(c, "/articles/$(new.id)/edit/", Dict("title" => "Updated", "author" => string(ann.id)))
    @test r.status == 302 && refresh!(new).title == "Updated"
    @test occursin("Delete Updated?", text(get(c, "/articles/$(new.id)/delete/")))
    r = post(c, "/articles/$(new.id)/delete/")
    @test r.status == 302 && !exists(filter(Article; id = new.id))
end

@testset "generic views: hooks, FormView, date archives" begin
    quiet(f) = redirect_stdout(f, devnull)
    @eval @model struct GvEvent
        name = CharField(max_length = 40)
        slug = CharField(max_length = 40, blank = true)
        day = DateField()
        at = DateTimeField(null = true)
        Meta(table = "gv_event", ordering = ["day"])
    end
    @eval @form ContactForm begin
        email = EmailField()
        message = CharField(max_length = 200)
    end
    quiet(() -> Juango.sync_models!([GvEvent]))
    for (n, d) in [("a", Date(2023, 12, 30)), ("b", Date(2024, 1, 5)), ("c", Date(2024, 1, 20)), ("d", Date(2024, 3, 1)),
                   ("future", today() + Day(800))]
        create(GvEvent; name = n, slug = n, day = d, at = DateTime(d) + Hour(12))
    end
    tpl(name, s) = write(joinpath(TPL, name), s)
    tpl("gvevent_archive.html", "{% for d in date_list %}{{ d|date:'Y' }} {% endfor %}|{% for e in latest %}{{ e.name }}{% endfor %}")
    tpl("gvevent_archive_year.html", "{{ year|date:'Y' }}:{% for d in date_list %}{{ d|date:'m' }} {% endfor %}|{% for e in object_list %}{{ e.name }}{% endfor %}|{{ next_year|date:'Y' }}<{{ previous_year|date:'Y' }}")
    tpl("gvevent_archive_month.html", "{{ month|date:'Y-m' }}:{% for d in date_list %}{{ d|date:'d' }} {% endfor %}|{% for e in object_list %}{{ e.name }}{% endfor %}|{{ next_month|date:'Y-m' }}<{{ previous_month|date:'Y-m' }}")
    tpl("gvevent_archive_day.html", "{{ day|date:'Y-m-d' }}|{% for e in object_list %}{{ e.name }}{% endfor %}|{{ next_day|date:'Y-m-d' }}<{{ previous_day|date:'Y-m-d' }}")
    tpl("gvevent_detail.html", "<h1>{{ object.name }}</h1>{{ extra }}{% for m in messages %}[{{ m }}]{% endfor %}")
    tpl("gvevent_list.html", "{% for e in object_list %}{{ e.name }},{% endfor %}{{ now }} {{ view.kind }}")
    tpl("gvevent_form.html", "FORM{% if form.errors %} invalid{% endif %}")
    tpl("gvevent_confirm_delete.html", "Delete {{ gvevent.name }}?")
    tpl("contact.html", "{% if form.errors %}invalid{% endif %}[{{ form.initial.email }}]")
    sent = Ref{Any}(nothing)
    A(view; kw...) = view(GvEvent; date_field = :day, kw...)
    urls = [
        path("gv/", ListView(GvEvent; get_queryset = v -> exclude(objects(GvEvent), name = "future"),
                             get_context_data = (v, ctx) -> (ctx["now"] = "NOW"; ctx))),
        path("gv/<str:slug>/", DetailView(GvEvent; extra_context = Dict("extra" => "+x"),
                                          get_object = v -> get_object_or_404(objects(GvEvent); slug = v.kwargs[:slug]))),
        path("gv-new/", CreateView(GvEvent; fields = [:name, :day], login_required = true, success_message = "Made %(name)s",
                                   form_valid = (v, f) -> (f.instance.slug = lowercase(f.cleaned_data[:name]) * "-s";
                                                           default_hook(:form_valid, v, f)),
                                   success_url = obj -> "/gv/$(obj.slug)/")),
        path("gv-new2/", CreateView(GvEvent; fields = [:name, :day], form_invalid = (v, f) -> HttpResponse("bad"; status = 422),
                                    template = "gvevent_form.html", initial = Dict(:name => "preset"))),
        path("gv-edit/<int:id>/", UpdateView(GvEvent; fields = [:name, :day], test_func = u -> u.is_superuser,
                                             get_success_url = v -> "/edited/$(v.object.name)/")),
        path("gv-perm/<int:id>/", UpdateView(GvEvent; fields = [:name], permission_required = "project.change_gvevent")),
        path("gv-del/<int:id>/", DeleteView(GvEvent; get_success_url = v -> "/gone/$(v.object.name)/")),
        path("gv-private/<str:slug>/", LoginRequiredMixin(DetailView(GvEvent; slug_field = :slug))),
        path("contact/", FormView(ContactForm; template = "contact.html", success_url = "/thanks/",
                                  initial = Dict(:email => "me@example.com"),
                                  form_valid = (v, f) -> (sent[] = f.cleaned_data; default_hook(:form_valid, v, f)))),
        path("arch/", A(ArchiveIndexView)),
        path("arch/<int:year>/", A(YearArchiveView)),
        path("arch-ol/<int:year>/", A(YearArchiveView; make_object_list = true)),
        path("arch/<int:year>/<int:month>/", A(MonthArchiveView)),
        path("arch/<int:year>/<int:month>/<int:day>/", A(DayArchiveView)),
        path("arch/<int:year>/<int:month>/<int:day>/<str:slug>/", A(DateDetailView)),
        path("arch-at/<int:year>/<int:month>/", MonthArchiveView(GvEvent; date_field = :at)),
        path("arch-future/", A(ArchiveIndexView; allow_future = true)),
        path("arch-empty/<int:year>/<int:month>/", A(MonthArchiveView; allow_empty = true)),
    ]
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = urls)
    try
        c = Client()
        # hooks
        @test text(get(c, "/gv/")) == "a,b,c,d,NOW ListView"
        r = get(c, "/gv/b/")
        @test text(r) == "<h1>b</h1>+x" && get(c, "/gv/zzz/").status == 404
        r = get(c, "/gv-new/")
        @test r.status == 302 && startswith(getheader(r, "Location"), settings.LOGIN_URL)
        root = create_superuser("gvroot", "gvroot-password-1")
        force_login!(c, root)
        @test text(get(c, "/gv-new/")) == "FORM"
        r = post(c, "/gv-new/", Dict("name" => "Party", "day" => "2024-05-05"); follow = true)
        @test text(r) == "<h1>Party</h1>+x[Made Party]" && get(GvEvent; name = "Party").slug == "party-s"
        @test post(c, "/gv-new/", Dict("name" => "")).status == 200 && occursin("invalid", text(post(c, "/gv-new/", Dict("name" => ""))))
        @test post(c, "/gv-new2/", Dict("name" => "")).status == 422
        party = get(GvEvent; name = "Party")
        r = post(c, "/gv-edit/$(party.id)/", Dict("name" => "Fete", "day" => "2024-05-05"))
        @test r.status == 302 && getheader(r, "Location") == "/edited/Fete/"
        pleb = create_user("gvpleb", "pleb-password-1")
        pc = Client()
        force_login!(pc, pleb)
        @test get(pc, "/gv-edit/$(party.id)/").status == 302             # test_func fails: to the login page
        @test get(pc, "/gv-perm/$(party.id)/").status == 403             # no permission
        @test get(c, "/gv-perm/$(party.id)/").status == 200              # superuser
        @test text(get(c, "/gv-del/$(party.id)/")) == "Delete Fete?"
        r = post(c, "/gv-del/$(party.id)/")
        @test getheader(r, "Location") == "/gone/Fete/" && !exists(filter(GvEvent; id = party.id))
        @test get(Client(), "/gv-private/b/").status == 302 && get(c, "/gv-private/b/").status == 200
        @test_throws ArgumentError ListView(GvEvent; paginate = 3)

        # FormView
        @test text(get(c, "/contact/")) == "[me@example.com]"
        @test text(post(c, "/contact/", Dict("email" => "nope"))) == "invalid[me@example.com]"
        r = post(c, "/contact/", Dict("email" => "a@b.org", "message" => "hi"))
        @test getheader(r, "Location") == "/thanks/" && sent[][:message] == "hi"

        # date archives (the future event is left out)
        @test text(get(c, "/arch/")) == "2024 2023 |dcba"
        @test occursin("future", text(get(c, "/arch-future/")))
        @test text(get(c, "/arch/2024/")) == "2024:01 03 ||<2023"
        @test text(get(c, "/arch-ol/2024/")) == "2024:01 03 |bcd|<2023"
        @test text(get(c, "/arch/2023/")) == "2023:12 ||2024<"
        @test text(get(c, "/arch/2024/1/")) == "2024-01:05 20 |bc|2024-03<2023-12"
        @test text(get(c, "/arch/2024/1/5/")) == "2024-01-05|b|2024-01-20<2023-12-30"
        @test text(get(c, "/arch/2024/1/5/b/")) == "<h1>b</h1>"
        @test get(c, "/arch/2024/1/6/b/").status == 404
        @test get(c, "/arch/2024/2/").status == 404 && get(c, "/arch/2024/13/").status == 404
        @test get(c, "/arch/$(year(today()) + 2)/").status == 404
        @test text(get(c, "/arch-empty/2024/2/")) == "2024-02:||2024-03<2024-01"
        @test text(get(c, "/arch-at/2024/1/")) == "2024-01:05 20 |bc|2024-03<2023-12"
        configure!(USE_TZ = true, TIME_ZONE = "Pacific/Auckland")          # 12:00 UTC is the next day there
        try
            @test text(get(c, "/arch-at/2024/1/")) == "2024-01:06 21 |bc|2024-03<2023-12"
        finally
            configure!(USE_TZ = false, TIME_ZONE = "UTC")
        end
    finally
        configure!(ROOT_URLCONF = old_urls)
        Juango.unregister_model!(GvEvent)
        Juango.execute("DROP TABLE " * Juango.qname("gv_event"))
    end
end

@testset "server roundtrip" begin
    port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)       # a free port
        p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
    end
    server = runserver("127.0.0.1", port; block = false, quiet = true)
    try
        r = Juango.HTTP.get("http://127.0.0.1:$port/articles/"; status_exception = false)
        @test r.status == 200
        r = Juango.HTTP.get("http://127.0.0.1:$port/nope/"; status_exception = false)
        @test r.status == 404
    finally
        close(server)
    end
end

@testset "streaming, server-sent events and websockets" begin
    H = Juango.HTTP
    # the value of `f(ws)` (WebSockets.open returns the handshake response)
    wsrun(f, url; kw...) = (out = Ref{Any}(nothing); H.WebSockets.open(ws -> (out[] = f(ws)), url; kw...); out[])
    # streaming responses through the test client
    gen(req) = StreamingHttpResponse(("row $i\n" for i in 1:3); content_type = "text/plain")
    writer(req) = StreamingHttpResponse(content_type = "text/plain") do io
        print(io, gettext("Save")); write(io, UInt8[0x21])
    end
    events(req) = EventStreamResponse() do io
        write(io, sse_event("hi"))
        write(io, sse_event(Dict("n" => 1); event = "tick", id = 7))
        write(io, sse_comment("keepalive"))
    end
    slow(req) = StreamingHttpResponse(content_type = "text/plain") do io
        write(io, "first\n"); sleep(0.8); write(io, "second\n")
    end
    fdir = mktempdir()
    fpath = joinpath(fdir, "report ü.csv")
    write(fpath, repeat("a,b,c\n", 30_000))            # 180 KB: several blocks
    file(req) = FileResponse(fpath; as_attachment = true)
    plainfile(req) = FileResponse(joinpath(fdir, "missing.txt"))
    function echo_handler(ws, req; prefix)
        for msg in ws
            msg == "who" ? ws_send(ws, req.user.is_authenticated ? req.user.username : "anon") :
                           ws_send(ws, prefix * (msg isa String ? msg : "<$(length(msg)) bytes>"))
        end
    end
    echo = websocket(echo_handler)
    private = login_required(websocket((ws, req) -> ws_send(ws, "secret")))
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("gen/", gen), path("writer/", writer), path("events/", events), path("slow/", slow),
                               path("file/", file), path("missing/", plainfile),
                               path("ws/<str:prefix>/", echo), path("private-ws/", private)])
    try
        c = Client()
        r = get(c, "/gen/")
        @test is_streaming(r) && text(r) == "row 1\nrow 2\nrow 3\n" && !is_streaming(r)
        @test with_language(() -> text(get(c, "/writer/")), "de") == "Sichern!"          # the view's language while streaming
        r = get(c, "/events/")
        @test getheader(r, "Content-Type") == "text/event-stream; charset=utf-8" && getheader(r, "Cache-Control") == "no-cache"
        @test text(r) == "data: hi\n\nevent: tick\nid: 7\ndata: {\"n\":1}\n\n: keepalive\n\n"
        @test sse_event("a\nb"; retry = 3000) == "retry: 3000\ndata: a\ndata: b\n\n"
        r = get(c, "/file/")
        @test text(r) == read(fpath, String) && getheader(r, "Content-Length") == string(filesize(fpath))
        @test getheader(r, "Content-Type") == "application/octet-stream"
        @test getheader(r, "Content-Disposition") == "attachment; filename*=UTF-8''report%20%C3%BC.csv"
        @test Juango.content_disposition("a\"b.txt") == "inline; filename=\"a\\\"b.txt\""
        @test get(c, "/missing/").status == 404
        @test isempty(text(request(c, "HEAD", "/gen/")))
        r = get(c, "/ws/x/")
        @test r.status == 426 && getheader(r, "Upgrade") == "websocket"

        # caching skips streaming responses
        @test !Juango.cacheable(Request("GET", "/gen/"), gen(nothing))

        # over a real server
        port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)
            p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
        end
        server = runserver("127.0.0.1", port; block = false, quiet = true)
        base = "127.0.0.1:$port"
        try
            r = H.get("http://$base/gen/")
            @test String(r.body) == "row 1\nrow 2\nrow 3\n"
            r = H.get("http://$base/file/")
            @test r.body == read(fpath) && H.header(r, "Content-Length") == string(filesize(fpath))
            r = H.get("http://$base/events/")
            @test occursin("event: tick", String(r.body))
            # the first chunk arrives before the view has finished
            first_at = Ref(0.0); got = IOBuffer()
            H.open("GET", "http://$base/slow/") do s
                H.startread(s)
                while !eof(s)
                    b = readavailable(s)
                    isempty(b) && continue
                    position(got) == 0 && (first_at[] = time())
                    write(got, b)
                end
            end
            @test String(take!(got)) == "first\nsecond\n"
            @test time() - first_at[] > 0.5           # "first" came ~0.8 s before the end
            @test H.get("http://$base/articles/"; status_exception = false).status == 404       # urlconf swapped
            @test H.get("http://$base/ws/x/"; status_exception = false).status == 426

            # websockets: echo, binary frames, the url kwargs, the session's user
            H.WebSockets.open("ws://$base/ws/echo:/") do ws
                ws_send(ws, "hello")
                @test ws_receive(ws) == "echo:hello"
                ws_send(ws, UInt8[1, 2, 3])
                @test ws_receive(ws) == "echo:<3 bytes>"
                ws_send(ws, "who")
                @test ws_receive(ws) == "anon"
            end
            # several connections at once
            replies = asyncmap(1:5) do i
                wsrun("ws://$base/ws/n/") do ws
                    ws_send(ws, string(i)); ws_receive(ws)
                end
            end
            @test replies == ["n$i" for i in 1:5]
            # foreign origins are refused, trusted ones allowed
            refused = try
                H.WebSockets.open(ws -> nothing, "ws://$base/ws/x/"; headers = ["Origin" => "http://evil.example"]); false
            catch e
                true
            end
            @test refused
            configure!(CSRF_TRUSTED_ORIGINS = ["https://app.example"])
            @test wsrun("ws://$base/ws/ok/"; headers = ["Origin" => "https://app.example"]) do ws
                ws_send(ws, "1"); ws_receive(ws)
            end == "ok1"
            @test wsrun("ws://$base/ws/ok/"; headers = ["Origin" => "http://$base"]) do ws
                ws_send(ws, "2"); ws_receive(ws)
            end == "ok2"
            # login_required refuses the handshake; with a session cookie it goes through
            @test try
                H.WebSockets.open(ws -> nothing, "ws://$base/private-ws/"); false
            catch
                true
            end
            lc = Client()
            force_login!(lc, root_user())
            cookie = "$(settings.SESSION_COOKIE_NAME)=$(lc.cookies[settings.SESSION_COOKIE_NAME])"
            @test wsrun(ws -> ws_receive(ws), "ws://$base/private-ws/"; headers = ["Cookie" => cookie]) == "secret"
            @test wsrun("ws://$base/ws/x/"; headers = ["Cookie" => cookie]) do ws
                ws_send(ws, "who"); ws_receive(ws)
            end == "root"

            # concurrent requests are served in parallel (each takes 0.8 s)
            t = @elapsed asyncmap(_ -> H.get("http://$base/slow/"), 1:6)
            @test t < 2.5
        finally
            close(server)
        end
    finally
        configure!(ROOT_URLCONF = old_urls, CSRF_TRUSTED_ORIGINS = String[])
    end
end

@testset "sitemaps" begin
    smauthor = create(Author; name = "Sitemap Author")
    arts = [create(Article; title = "sm-$i", author = smauthor, published = true) for i in 1:5]
    posts = Sitemap(() -> order_by(filter(Article; title__startswith = "sm-"), "id");
                    location = a -> "/articles/$(a.id)/", lastmod = a -> Date(2024, 1, a.id % 28 + 1),
                    changefreq = "weekly", priority = 0.5)
    pages = Sitemap(["home", "article_list"]; location = n -> reverse_url(n), changefreq = n -> n == "home" ? "daily" : nothing)
    small = Sitemap(() -> order_by(filter(Article; title__startswith = "sm-"), "id"); location = a -> "/a/$(a.id)/", limit = 2)
    old_urls = settings.ROOT_URLCONF
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("maps/", include_urls(sitemap_urls(Dict("posts" => posts, "pages" => pages)))),
                                                   path("one/", include_urls(sitemap_urls(Dict("small" => small)))),
                                                   path("abs/", include_urls(sitemap_urls(Dict("p" => Sitemap(["https://cdn.example/x"]; protocol = "https")))))]))
        c = Client()
        r = get(c, "/maps/sitemap.xml")
        x = text(r)
        @test r.status == 200 && startswith(getheader(r, "Content-Type"), "application/xml") && getheader(r, "X-Robots-Tag") == "noindex, noodp, noarchive"
        @test occursin("<sitemapindex", x) && occursin("<loc>http://testserver/maps/sitemap-posts.xml</loc>", x) &&
              occursin("<loc>http://testserver/maps/sitemap-pages.xml</loc>", x)
        @test occursin(r"<sitemap><loc>http://testserver/maps/sitemap-posts.xml</loc><lastmod>2024-01-\d\d</lastmod></sitemap>", x)
        x = text(get(c, "/maps/sitemap-posts.xml"))
        a1 = arts[1]
        @test occursin("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">", x)
        @test occursin("<url><loc>http://testserver/articles/$(a1.id)/</loc><lastmod>2024-01-$(lpad(a1.id % 28 + 1, 2, '0'))</lastmod><changefreq>weekly</changefreq><priority>0.5</priority></url>", x)
        @test count("<url>", x) == 5
        r = get(c, "/maps/sitemap-posts.xml")
        @test getheader(r, "Last-Modified") !== nothing
        x = text(get(c, "/maps/sitemap-pages.xml"))
        @test occursin("<url><loc>http://testserver/</loc><changefreq>daily</changefreq></url>", x) &&
              occursin("<url><loc>http://testserver/articles/</loc></url>", x)
        @test get(c, "/maps/sitemap-nope.xml").status == 404

        # one section: sitemap.xml is the urlset, paginated above `limit`
        x = text(get(c, "/one/sitemap.xml"))
        @test occursin("<urlset", x) && count("<url>", x) == 2 && occursin("/a/$(arts[1].id)/", x)
        @test count("<url>", text(get(c, "/one/sitemap.xml?p=3"))) == 1
        @test get(c, "/one/sitemap.xml?p=4").status == 404 && get(c, "/one/sitemap.xml?p=x").status == 404
        idx = Juango.sitemap_index_view(Dict("small" => small); section_url = s -> "/one/sitemap-$s.xml")
        x = text(idx(Request("GET", "/"; headers = Dict("host" => "example.org"))))
        @test occursin("<loc>http://example.org/one/sitemap-small.xml</loc>", x) && occursin("<loc>http://example.org/one/sitemap-small.xml?p=3</loc>", x)
        @test occursin("<loc>https://cdn.example/x</loc>", text(get(c, "/abs/sitemap.xml")))
        # get_absolute_url is the default location
        @test_throws Juango.ImproperlyConfigured Juango.sitemap_entries(Request("GET", "/"), Sitemap([1]), [1], 1)
        x = text(Juango.sitemap_view(Dict("a" => Sitemap(() -> [a1])))(Request("GET", "/"; headers = Dict("host" => "h"))))
        @test occursin("<loc>http://h/articles/$(a1.id)/</loc>", x)
        @test Juango.w3c_date(DateTime(2024, 2, 3, 4, 5, 6)) == "2024-02-03T04:05:06+00:00"
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end

@testset "syndication feeds" begin
    fa = create(Author; name = "Feed <Author>")
    items = [create(Article; title = "feed-$i & co", body = "<p>Body $i</p>", author = fa, published = true) for i in 1:3]
    date_of(a) = DateTime(2024, 3, a.id % 28 + 1, 12, 30)
    latest = Feed(title = "Latest articles", link = "/articles/", description = "New <stuff>",
                  items = () -> order_by(filter(Article; title__startswith = "feed-"), "-id"),
                  item_description = :body, item_pubdate = date_of, item_author_name = a -> a.author.name,
                  item_categories = a -> ["news", "a&b"], language = "en", ttl = 60)
    atom = Feed(latest; feed_type = :atom, author_name = "Editor")
    by_author = Feed(title = au -> "Articles by $(au.name)", link = au -> "/authors/$(au.id)/",
                     get_object = (req; id) -> get_object_or_404(objects(Author); id = id),
                     items = au -> filter(Article; author = au), item_link = a -> "https://elsewhere.example/a/$(a.id)",
                     item_guid = a -> "urn:article:$(a.id)")
    write(joinpath(TPL, "feed_title.html"), "[{{ obj.title|upper }} @ {{ site }}]")
    templated = Feed(latest; title_template = "feed_title.html", description_template = "feed_title.html")
    old_urls = settings.ROOT_URLCONF
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("feed/", latest), path("feed/atom/", atom),
                                                   path("feed/author/<int:id>/", by_author), path("feed/t/", templated)]))
        c = Client()
        r = get(c, "/feed/")
        x = text(r)
        a3 = items[3]
        @test r.status == 200 && getheader(r, "Content-Type") == "application/rss+xml; charset=utf-8"
        @test startswith(x, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<rss version=\"2.0\"")
        @test occursin("<title>Latest articles</title><link>http://testserver/articles/</link><description>New &lt;stuff&gt;</description>", x)
        @test occursin("<atom:link href=\"http://testserver/feed/\" rel=\"self\"/><language>en</language>", x)
        @test occursin("<ttl>60</ttl>", x) && occursin("<lastBuildDate>", x)
        @test occursin("<item><title>feed-3 &amp; co</title><link>http://testserver/articles/$(a3.id)/</link><description>&lt;p&gt;Body 3&lt;/p&gt;</description>", x)
        @test occursin("<pubDate>" * Dates.format(date_of(a3), "e, dd u yyyy HH:MM:SS") * " +0000</pubDate>", x)
        @test occursin("<dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">Feed &lt;Author&gt;</dc:creator>", x)
        @test occursin("<guid>http://testserver/articles/$(a3.id)/</guid><category>news</category><category>a&amp;b</category>", x)
        @test count("<item>", x) == 3 && findfirst("feed-3", x)[1] < findfirst("feed-1", x)[1]

        r = get(c, "/feed/atom/")
        x = text(r)
        @test getheader(r, "Content-Type") == "application/atom+xml; charset=utf-8"
        @test occursin("<feed xmlns=\"http://www.w3.org/2005/Atom\" xml:lang=\"en\"><title>Latest articles</title>", x)
        @test occursin("<link href=\"http://testserver/articles/\" rel=\"alternate\"/><link href=\"http://testserver/feed/atom/\" rel=\"self\"/>", x)
        @test occursin("<id>http://testserver/articles/</id><updated>", x) && occursin("<subtitle>New &lt;stuff&gt;</subtitle><author><name>Editor</name></author>", x)
        @test occursin("<entry><title>feed-3 &amp; co</title><link href=\"http://testserver/articles/$(a3.id)/\" rel=\"alternate\"/>", x)
        @test occursin("<published>" * Dates.format(date_of(a3), "yyyy-mm-ddTHH:MM:SS") * "Z</published>", x)
        @test occursin("<summary type=\"html\">&lt;p&gt;Body 3&lt;/p&gt;</summary><category term=\"news\"/>", x)

        x = text(get(c, "/feed/author/$(fa.id)/"))
        @test occursin("<title>Articles by Feed &lt;Author&gt;</title><link>http://testserver/authors/$(fa.id)/</link>", x)
        @test occursin("<link>https://elsewhere.example/a/$(a3.id)</link>", x) && occursin("<guid isPermaLink=\"false\">urn:article:$(a3.id)</guid>", x)
        @test get(c, "/feed/author/999999/").status == 404

        x = text(get(c, "/feed/t/"))
        @test occursin("<title>[FEED-3 &amp;amp; CO @ testserver]</title>", x)
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end

@testset "flatpages" begin
    IC = Juango.ImproperlyConfigured
    @test_throws IC flatpage(Request("GET", "/x/"); url = "x/")      # "juango.flatpages" isn't installed
    old_apps, old_mw, old_urls = settings.INSTALLED_APPS, settings.MIDDLEWARE, settings.ROOT_URLCONF
    mkpath(joinpath(TPL, "flatpages"))
    write(joinpath(TPL, "flatpages", "special.html"), "SPECIAL {{ flatpage.title }}")
    fproot = create_superuser("fproot", "fproot-password-1")
    try
        configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.flatpages"]),
                   MIDDLEWARE = vcat(old_mw, [FlatpageFallbackMiddleware]),
                   ROOT_URLCONF = vcat(old_urls, [path("pages/", flatpage_urls())]))
        @test Admin.is_registered(FlatPage) && isempty(Juango.app_issues())
        @test !Juango.table_exists(Juango.backend(), "juango_flatpage")       # not migrated while uninstalled
        migrate(verbose = false)
        @test Juango.table_exists(Juango.backend(), "juango_flatpage")
        create(FlatPage; url = "/about/", title = "About <us>", content = "<p>Hello</p>")
        create(FlatPage; url = "/members/", title = "Members", content = "secret", registration_required = true)
        create(FlatPage; url = "/special/", title = "Special", content = "x", template_name = "flatpages/special.html")
        c = Client()
        r = get(c, "/about/")                                         # the fallback middleware
        @test r.status == 200 && occursin("<title>About <us></title>", text(r)) && occursin("<p>Hello</p>", text(r))
        r = get(c, "/about?x=1")
        @test r.status == 301 && getheader(r, "Location") == "/about/?x=1"
        @test get(c, "/pages/about/").status == 200                   # under a prefix
        @test get(c, "/pages/nope/").status == 404 && get(c, "/nothing-here/").status == 404
        @test text(get(c, "/special/")) == "SPECIAL Special"
        r = get(c, "/members/")
        @test r.status == 302 && startswith(getheader(r, "Location"), settings.LOGIN_URL)
        force_login!(c, fproot)
        @test occursin("secret", text(get(c, "/members/")))
        @test get(c, "/articles/").status == 200                      # other pages are untouched

        # {% get_flatpages %}
        list(src, d = Dict{String,Any}()) = tr("{% load flatpages %}" * src * "{% for p in fp %}{{ p.url }} {% endfor %}", d)
        @test list("{% get_flatpages as fp %}") == "/about/ /special/ "
        @test list("{% get_flatpages for u as fp %}", Dict{String,Any}("u" => fproot)) == "/about/ /members/ /special/ "
        @test list("{% get_flatpages '/s' as fp %}") == "/special/ "
        @test list("{% get_flatpages pre for u as fp %}", Dict{String,Any}("pre" => "/m", "u" => AnonymousUser())) == ""
        @test_throws TemplateSyntaxError Template("{% load flatpages %}{% get_flatpages %}")

        # edited in the admin
        @test get(c, "/admin/flatpage/").status == 200
        r = post(c, "/admin/flatpage/add/", Dict("url" => "/new/", "title" => "New", "content" => "Fresh", "template_name" => ""))
        @test r.status == 302 && occursin("Fresh", text(get(Client(), "/new/")))
    finally
        configure!(INSTALLED_APPS = old_apps, MIDDLEWARE = old_mw, ROOT_URLCONF = old_urls)
        Admin.unregister!(FlatPage)
        Juango.execute("DELETE FROM " * Juango.qname("juango_flatpage"))
    end
end
