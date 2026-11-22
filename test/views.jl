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
    r = post(c, "/contact/", Dict("name" => "Zoe", "email" => "z@x.io", "password" => "p", "confirm" => "p", "agree" => "on"); follow = true)   # (agree must be ticked, #247)
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
    @test haskey(c.cookies, "csrftoken") && length(tok) == 64 && Juango.unmask_csrf(tok) == c.cookies["csrftoken"]   # masked
    r = post(c, "/contact/", Dict("csrfmiddlewaretoken" => tok, "name" => "Q", "email" => "q@x.io",
                                  "password" => "p", "confirm" => "p", "agree" => "on"))
    @test r.status == 302
    @test post(c, "/contact/", Dict("csrfmiddlewaretoken" => "wrong")).status == 403
    @test request(c, "POST", "/contact/"; headers = Dict("X-CSRFToken" => tok), data = Dict("name" => "")).status == 200
    @test post(c, "/hook/").status == 200                                # csrf_exempt
end

@testset "client: auth flow" begin
    c = Client()
    @test text(get(c, "/whoami/")) == "anon"
    r = get(c, "/secret/")
    @test r.status == 302 && getheader(r, "Location") == "/accounts/login/?next=/secret/"
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
        @test get(pc, "/gv-edit/$(party.id)/").status == 403             # test_func fails for a logged-in user: 403 (UserPassesTestMixin)
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

@testset "live test server" begin
    sdir = mktempdir()
    write(joinpath(sdir, "live.css"), "body{}")
    @test live_server_url() === nothing
    override_settings(STATIC_DIRS = [sdir], DEBUG = false, ALLOWED_HOSTS = ["example.com"]) do
        with_live_server() do s
            @test startswith(s.url, "http://127.0.0.1:") && live_server_url() == s.url
            @test "127.0.0.1" in Juango.settings.ALLOWED_HOSTS                    # added for the block
            r = Juango.HTTP.get(s.url * "/articles/"; status_exception = false)
            @test r.status == 200
            r = Juango.HTTP.get(s.url * "/static/live.css"; status_exception = false)
            @test r.status == 200 && String(r.body) == "body{}"                     # static without DEBUG
        end
        @test live_server_url() === nothing && Juango.settings.ALLOWED_HOSTS == ["example.com"]
        with_live_server(static = false) do s
            @test Juango.HTTP.get(s.url * "/static/live.css"; status_exception = false).status == 404
        end
    end
end

@testset "lazy session and user" begin
    anon, logged = Client(), Client()
    force_login!(logged, create_user("lazyuser", "lazy-pass-123"))
    get(anon, "/articles/"); get(logged, "/articles/")                         # warm up
    _, n_anon = count_queries(() -> get(anon, "/articles/"))
    _, n_logged = count_queries(() -> get(logged, "/articles/"))
    @test n_logged == n_anon                       # the view never uses them: no session or user query
    @test text(get(logged, "/whoami/")) == "user:lazyuser"       # loaded on first use
    _, n_who = count_queries(() -> get(logged, "/whoami/"))
    @test n_who >= 2                                # session, then user
    s = Juango.lazy_session("nonexistent-key")
    @test !Juango.session_loaded(s) && s.key === nothing && Juango.session_loaded(s) && isempty(s)
    req = Request("GET", "/"); req.user = Juango.LAZY_USER
    @test req.user isa AnonymousUser               # no session: anonymous
    ctx = Juango.Context(Dict{String,Any}("u" => Juango.LazyValue(() -> "computed")))
    @test Juango.lookup(ctx, "u") == "computed" && ctx.stack[1]["u"] == "computed"
end

@testset "lazy CSRF token" begin
    c = Client()
    r = get(c, "/articles/")                    # renders a template with the request, no {% csrf_token %}
    @test r.status == 200 && !any(x -> startswith(x, "csrftoken="), r.cookies)
end

@testset "request size limits" begin
    override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE = 1000, DATA_UPLOAD_MAX_NUMBER_FIELDS = 5) do
        with_live_server() do s
            post_(body; ct = "application/x-www-form-urlencoded") =
                Juango.HTTP.post(s.url * "/articles/", ["Content-Type" => ct], body; status_exception = false)
            @test post_("a=" * "x"^2000).status == 400                                   # body too big
            @test occursin("size limit", String(post_("a=" * "x"^2000).body))
            r = post_(join(["f$i=1" for i in 1:6], "&"))                                  # too many fields
            @test r.status == 400
            @test Juango.HTTP.get(s.url * "/articles/"; status_exception = false).status == 200   # still serving
        end
    end
    c = Client()
    @test get(c, "/articles/?" * join(["q$i=1" for i in 1:1001], "&")).status == 400
    @test get(c, "/articles/?q=1").status == 200
end

@testset "server roundtrip" begin
    port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)       # a free port
        p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
    end
    server = runserver("127.0.0.1", port; block = false, quiet = true)
    try
        r = Juango.HTTP.get("http://127.0.0.1:$port/articles/"; status_exception = false)
        @test r.status == 200 && r.proto_major == 1
        h1_body = String(r.body)
        r = Juango.HTTP.get("http://127.0.0.1:$port/nope/"; status_exception = false)
        @test r.status == 404
        r = Juango.HTTP.get("http://127.0.0.1:$port/articles/"; protocol = :h2)     # cleartext HTTP/2
        @test r.status == 200 && r.proto_major == 2 && String(r.body) == h1_body
    finally
        close(server)
    end
    # HTTPS, where clients negotiate HTTP/2
    if Sys.which("openssl") !== nothing
        dir = mktempdir()
        cert, key = joinpath(dir, "cert.pem"), joinpath(dir, "key.pem")
        run(pipeline(`openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost -keyout $key -out $cert`;
                     stderr = devnull))
        server = runserver("127.0.0.1", port; block = false, quiet = true, certfile = cert, keyfile = key)
        try
            r = Juango.HTTP.get("https://127.0.0.1:$port/articles/"; require_ssl_verification = false)
            @test r.status == 200 && r.proto_major == 2
            r = Juango.HTTP.get("https://127.0.0.1:$port/articles/"; require_ssl_verification = false, protocol = :h1)
            @test r.status == 200 && r.proto_major == 1
        finally
            close(server)
        end
    end
    @test_throws ArgumentError runserver("127.0.0.1", port; block = false, quiet = true, certfile = "x.pem")
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
        write(io, "first\n"); sleep(0.4); write(io, "second\n")
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
        @test !Juango.is_streaming(r) && String(copy(r.body)) == read(fpath, String)     # read at once: its length is known (#134)
        @test text(r) == read(fpath, String) && getheader(r, "Content-Length") == string(filesize(fpath))
        @test getheader(r, "Content-Type") == "text/csv; charset=utf-8"
        @test getheader(r, "Content-Disposition") == "attachment; filename*=utf-8''report%20%C3%BC.csv"
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
            r = H.get("http://$base/gen/"; protocol = :h2)           # streamed over HTTP/2
            @test r.proto_major == 2 && String(r.body) == "row 1\nrow 2\nrow 3\n"
            r = H.get("http://$base/file/"; protocol = :h2)
            @test r.body == read(fpath)
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
            @test time() - first_at[] > 0.25          # "first" came ~0.4 s before the end
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
        @test occursin("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\" xmlns:xhtml=\"http://www.w3.org/1999/xhtml\">", x)
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
        @test occursin("<published>" * Dates.format(date_of(a3), "yyyy-mm-ddTHH:MM:SS") * "+00:00</published>", x)
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
        @test get(c, "/admin/flatpages/flatpage/").status == 200
        r = post(c, "/admin/flatpages/flatpage/add/", Dict("url" => "/new/", "title" => "New", "content" => "Fresh", "template_name" => ""))
        @test r.status == 302 && occursin("Fresh", text(get(Client(), "/new/")))
    finally
        configure!(INSTALLED_APPS = old_apps, MIDDLEWARE = old_mw, ROOT_URLCONF = old_urls)
        Admin.unregister!(FlatPage)
        Juango.execute("DELETE FROM " * Juango.qname("juango_flatpage"))
    end
end

@testset "caching headers, conditional requests and gzip" begin
    rq(method = "GET"; kw...) = Request(method, "/x/"; headers = Dict{String,String}(string(k) => v for (k, v) in kw))
    body(req) = HttpResponse("hello")
    # Cache-Control and Vary
    r = never_cache(body)(rq())
    cc = Juango.parse_cache_control(getheader(r, "Cache-Control"))
    @test all(haskey(cc, k) for k in ("no-cache", "no-store", "must-revalidate", "private")) && cc["max-age"] == "0" && Juango.hasheader(r, "Expires")
    r = cache_control(body; max_age = 600, public = true)(rq())
    @test getheader(r, "Cache-Control") == "max-age=600, public"
    r = cache_control(; private = true)(cache_control(body; max_age = 600, public = true))(rq())
    @test getheader(r, "Cache-Control") == "max-age=600, private"
    patch_cache_control!(r; max_age = 60)
    @test occursin("max-age=60", getheader(r, "Cache-Control"))
    patch_cache_control!(r; max_age = 900)                   # the smaller max-age wins
    @test occursin("max-age=60", getheader(r, "Cache-Control"))
    @test getheader(vary_on_cookie(vary_on_headers(body, "Accept-Language"))(rq()), "Vary") == "Accept-Language, Cookie"

    # etag / last_modified / condition
    changed = DateTime(2024, 5, 1, 12, 0, 0)
    calls = Ref(0)
    v = condition((req; kw...) -> (calls[] += 1; HttpResponse("page")); etag_func = (req; kw...) -> "v1",
                  last_modified_func = (req; kw...) -> changed)
    r = v(rq())
    @test r.status == 200 && getheader(r, "ETag") == "\"v1\"" && getheader(r, "Last-Modified") == "Wed, 01 May 2024 12:00:00 GMT"
    @test v(rq(; var"if-none-match" = "\"v1\"")).status == 304 && v(rq(; var"if-none-match" = "W/\"v1\", \"v0\"")).status == 304
    @test v(rq(; var"if-none-match" = "\"v2\"")).status == 200
    @test v(rq(; var"if-modified-since" = "Wed, 01 May 2024 12:00:00 GMT")).status == 304
    @test v(rq(; var"if-modified-since" = "Wed, 01 May 2024 11:59:59 GMT")).status == 200
    @test v(rq("POST"; var"if-match" = "\"v0\"")).status == 412 && v(rq("POST"; var"if-match" = "\"v1\"")).status == 200
    @test v(rq("PUT"; var"if-unmodified-since" = "Tue, 30 Apr 2024 00:00:00 GMT")).status == 412
    @test v(rq("POST"; var"if-none-match" = "*")).status == 412
    n = calls[]
    v(rq(; var"if-none-match" = "\"v1\""))
    @test calls[] == n                                        # a 304 doesn't run the view
    @test etag(body, (req; kw...) -> "abc")(rq(; var"if-none-match" = "\"abc\"")).status == 304
    @test last_modified(body, (req; kw...) -> changed)(rq()).status == 200

    # ConditionalGetMiddleware
    cg = ConditionalGetMiddleware(req -> HttpResponse("content"))
    r = cg(rq())
    e = getheader(r, "ETag")
    @test r.status == 200 && startswith(e, "\"")
    r2 = cg(rq(; var"if-none-match" = e))
    @test r2.status == 304 && isempty(r2.body) && getheader(r2, "ETag") == e
    @test cg(rq("POST"; var"if-none-match" = e)).status == 200          # only GET/HEAD
    @test cg(rq(; var"if-none-match" = "\"other\"")).status == 200

    # GZipMiddleware
    long = repeat("compress me please ", 50)
    gz = GZipMiddleware(req -> (r = HttpResponse(long); setheader!(r, "ETag", "\"x\""); r))
    r = gz(rq(; var"accept-encoding" = "gzip, deflate"))
    @test getheader(r, "Content-Encoding") == "gzip" && length(r.body) < length(long)
    @test String(Juango.CodecZlib.transcode(Juango.CodecZlib.GzipDecompressor, r.body)) == long
    @test getheader(r, "Vary") == "Accept-Encoding" && getheader(r, "ETag") == "W/\"x\""
    sizes = Set(length(gz(rq(; var"accept-encoding" = "gzip")).body) for _ in 1:10)
    @test length(sizes) > 1                                     # random padding against BREACH
    @test !Juango.hasheader(gz(rq()), "Content-Encoding")              # client doesn't accept gzip
    @test !Juango.hasheader(GZipMiddleware(req -> HttpResponse("short"))(rq(; var"accept-encoding" = "gzip")), "Content-Encoding")
    # streaming responses: one gzip file, a compressed chunk for each chunk of the view
    chunks = ["chunk $i " * repeat("data ", 40) for i in 1:5]
    sr = GZipMiddleware(req -> (r = StreamingHttpResponse(chunks); setheader!(r, "Content-Length", "999"); r))(rq(; var"accept-encoding" = "gzip"))
    @test getheader(sr, "Content-Encoding") == "gzip" && !Juango.hasheader(sr, "Content-Length") && Juango.is_streaming(sr)
    sent = Vector{UInt8}[]
    Juango.each_chunk(b -> push!(sent, b), sr.stream)
    @test length(sent) == 2 + length(chunks)                    # header, one per chunk, then the trailer
    @test String(Juango.CodecZlib.transcode(Juango.CodecZlib.GzipDecompressor, reduce(vcat, sent))) == join(chunks)
    fr = GZipMiddleware(req -> StreamingHttpResponse(io -> foreach(c -> write(io, c), chunks)))(rq(; var"accept-encoding" = "gzip"))
    @test String(Juango.CodecZlib.transcode(Juango.CodecZlib.GzipDecompressor, Vector{UInt8}(codeunits(text(fr))))) == join(chunks)
    @test !Juango.hasheader(GZipMiddleware(req -> StreamingHttpResponse([long]))(rq()), "Content-Encoding")
    @test Juango.crc32(UInt8[0x35, 0x36, 0x37, 0x38, 0x39], Juango.crc32(UInt8[0x31, 0x32, 0x33, 0x34])) == 0xcbf43926
    @test Juango.crc32(Vector{UInt8}(codeunits("123456789"))) == 0xcbf43926
    # through the whole stack
    old = settings.MIDDLEWARE
    try
        configure!(MIDDLEWARE = vcat(Any[GZipMiddleware, ConditionalGetMiddleware], old))
        c = Client()
        r = get(c, "/articles/"; headers = Dict("Accept-Encoding" => "gzip"))
        @test r.status == 200 && (length(r.body) < 200 || getheader(r, "Content-Encoding") == "gzip")
    finally
        configure!(MIDDLEWARE = old)
    end
end

@testset "security: HTTPS, HSTS, Content-Security-Policy, check --deploy" begin
    rq(path = "/x/"; kw...) = Request("GET", path; headers = Dict{String,String}("host" => "example.com", (string(k) => v for (k, v) in kw)...))
    ok(req) = HttpResponse("ok")
    old = Dict(k => getproperty(settings, k) for k in (:SECURE_PROXY_SSL_HEADER, :SECURE_SSL_REDIRECT, :SECURE_HSTS_SECONDS,
               :SECURE_HSTS_INCLUDE_SUBDOMAINS, :SECURE_HSTS_PRELOAD, :SECURE_REDIRECT_EXEMPT, :SECURE_SSL_HOST,
               :SECURE_CSP, :SECURE_CSP_REPORT_ONLY, :ALLOWED_HOSTS, :MIDDLEWARE))
    try
        configure!(ALLOWED_HOSTS = ["example.com", "testserver"])
        # X-Forwarded-Proto counts only when SECURE_PROXY_SSL_HEADER says so
        @test !is_secure(rq(; var"x-forwarded-proto" = "https"))
        configure!(SECURE_PROXY_SSL_HEADER = ("HTTP_X_FORWARDED_PROTO", "https"))
        @test is_secure(rq(; var"x-forwarded-proto" = "https")) && !is_secure(rq(; var"x-forwarded-proto" = "http"))
        mw = Juango.SecurityMiddleware(ok)
        @test !Juango.hasheader(mw(rq()), "Strict-Transport-Security")
        configure!(SECURE_HSTS_SECONDS = 3600, SECURE_HSTS_INCLUDE_SUBDOMAINS = true, SECURE_HSTS_PRELOAD = true)
        r = mw(rq(; var"x-forwarded-proto" = "https"))
        @test getheader(r, "Strict-Transport-Security") == "max-age=3600; includeSubDomains; preload"
        @test getheader(r, "X-Content-Type-Options") == "nosniff" && getheader(r, "X-Frame-Options") == "DENY" &&
              getheader(r, "Cross-Origin-Opener-Policy") == "same-origin"
        @test !Juango.hasheader(mw(rq()), "Strict-Transport-Security")              # only over HTTPS
        # redirecting to HTTPS
        configure!(SECURE_SSL_REDIRECT = true, SECURE_REDIRECT_EXEMPT = ["^health/"])
        r = mw(Request("GET", "/a/?q=1"; headers = Dict("host" => "example.com")))
        @test r.status == 301 && getheader(r, "Location") == "https://example.com/a/?q=1"
        @test mw(rq("/health/")).status == 200 && mw(rq(; var"x-forwarded-proto" = "https")).status == 200
        configure!(SECURE_SSL_HOST = "secure.example.com")
        @test getheader(mw(rq()), "Location") == "https://secure.example.com/x/"
        configure!(SECURE_SSL_REDIRECT = false)

        # Content-Security-Policy with a nonce
        configure!(SECURE_CSP = Dict("default-src" => [CSP.SELF], "script-src" => [CSP.SELF, CSP.NONCE],
                                     "upgrade-insecure-requests" => true),
                   SECURE_CSP_REPORT_ONLY = Dict("img-src" => "'self' data:"))
        csp = ContentSecurityPolicyMiddleware
        r = csp(ok)(rq())
        @test getheader(r, "Content-Security-Policy") == "default-src 'self'; script-src 'self'; upgrade-insecure-requests"
        @test getheader(r, "Content-Security-Policy-Report-Only") == "img-src 'self' data:"
        page = (req) -> render(req, Template("<script nonce=\"{{ csp_nonce }}\">x()</script>"), Dict{String,Any}())
        req = rq()
        r = csp(page)(req)
        n = csp_nonce(req)
        @test occursin("nonce=\"$n\"", text(r)) && occursin("script-src 'self' 'nonce-$n'", getheader(r, "Content-Security-Policy"))
        @test csp_nonce(rq()) != n
        r = csp(csp_override(ok, nothing))(rq())
        @test !Juango.hasheader(r, "Content-Security-Policy") && Juango.hasheader(r, "Content-Security-Policy-Report-Only")
        r = csp(csp_override(ok, Dict("default-src" => [CSP.NONE])))(rq())
        @test getheader(r, "Content-Security-Policy") == "default-src 'none'"

        # check --deploy
        configure!(SECURE_CSP = Dict{String,Any}(), SECURE_HSTS_SECONDS = 0)
        issues = deploy_issues()
        @test any(occursin("SECURE_HSTS_SECONDS", i) for i in issues) && any(occursin("SESSION_COOKIE_SECURE", i) for i in issues)
        @test any(occursin("DEBUG", i) for i in issues) == settings.DEBUG
    finally
        configure!(; old...)
    end
end

@testset "testing helpers" begin
    # rollback_after undoes everything, including what requests did
    before = count(objects(Topic))
    v = rollback_after() do
        create(Topic; name = "rolled-1")
        @test count(objects(Topic)) == before + 1
        rollback_after(() -> create(Topic; name = "rolled-inner"))      # nested: a savepoint
        @test !exists(filter(Topic; name = "rolled-inner"))
        :done
    end
    @test v === :done && count(objects(Topic)) == before
    @test_throws ErrorException rollback_after(() -> error("boom"))

    # override_settings
    old = settings.APPEND_SLASH
    override_settings(APPEND_SLASH = !old, BRAND_NEW_SETTING = 3) do
        @test settings.APPEND_SLASH == !old && settings.BRAND_NEW_SETTING == 3
    end
    @test settings.APPEND_SLASH == old && !haskey(Juango.SETTINGS, :BRAND_NEW_SETTING)
    @test_throws ErrorException override_settings(() -> error("x"); APPEND_SLASH = !old)
    @test settings.APPEND_SLASH == old

    # RequestFactory: a request for calling a view directly
    rf = RequestFactory()
    req = get(rf, "/articles/"; data = Dict("page" => "2"))
    @test req.method == "GET" && req.GET["page"] == "2" && req.user isa AnonymousUser && req.resolver_match !== nothing
    req = post(rf, "/contact/", Dict("name" => "Ann"))
    @test req.POST["name"] == "Ann"
    @test text(whoami(get(rf, "/whoami/"))) == "anon"

    # assertions
    c = Client()
    r = get(c, "/whoami/")
    @test assert_contains(r, "anon") && assert_contains(r, "anon"; count = 1) && assert_not_contains(r, "user:")
    @test_throws AssertionError assert_contains(r, "missing")
    @test_throws AssertionError assert_contains(r, "anon"; status = 404)
    @test assert_template_used(r, "whoami.html") && assert_template_not_used(r, "base.html")
    @test_throws AssertionError assert_template_used(r, "other.html")
    r = get(c, "/secret/")
    @test assert_redirects(r, settings.LOGIN_URL * "?next=/secret/") && assert_redirects(r, settings.LOGIN_URL * "?next=/secret/"; client = c)
    @test_throws AssertionError assert_redirects(r, "/elsewhere/")
    @test assert_num_queries(() -> count(objects(Topic)), 1)
    @test_throws AssertionError assert_num_queries(() -> nothing, 1)
    f = ModelForm(Topic; data = Dict("name" => ""))
    @test assert_form_error(f, :name, "This field is required.") && assert_form_error(f, nothing, String[])
    @test_throws AssertionError assert_form_error(f, :name, [])
end

@testset "sites and redirects" begin
    req = Request("GET", "/x/"; headers = Dict("host" => "shop.example.org"))
    @test get_current_site(req) isa RequestSite && get_current_site(req).domain == "shop.example.org"
    old_apps, old_mw = settings.INSTALLED_APPS, settings.MIDDLEWARE
    try
        configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.sites", "juango.redirects"]),
                   MIDDLEWARE = vcat(old_mw, [RedirectFallbackMiddleware]))
        redirect_stdout(() -> migrate(verbose = false), devnull)
        @test get(Site; id = 1).domain == "example.com"                      # migrate made the default site
        s = get_current_site(req)
        @test s isa Site && s.id == 1 && get_current_site() === s           # cached
        @test Admin.is_registered(Site) && Admin.is_registered(Redirect)
        # SITE_ID = nothing: the site whose domain is the host
        shop = create(Site; domain = "shop.example.org", name = "Shop")
        override_settings(SITE_ID = nothing) do
            @test get_current_site(req).id == shop.id
            @test_throws Juango.ImproperlyConfigured get_current_site(Request("GET", "/"; headers = Dict("host" => "nope.example")))
        end
        # sitemaps and feeds use the site's domain
        r = Juango.sitemap_view(Dict("static" => Sitemap(items = () -> ["/about/"])))(Request("GET", "/sitemap.xml"; headers = Dict("host" => "testserver")))
        @test occursin("<loc>http://example.com/about/</loc>", text(r))
        # redirects
        create(Redirect; site = s, old_path = "/old-page/", new_path = "/articles/")
        create(Redirect; site = s, old_path = "/retired/", new_path = "")
        create(Redirect; site = s, old_path = "/q/?a=1", new_path = "https://elsewhere.example/q")
        create(Redirect; site = shop, old_path = "/shop-only/", new_path = "/x/")
        c = Client()
        r = get(c, "/old-page/")
        @test r.status == 301 && getheader(r, "Location") == "/articles/"
        @test get(c, "/retired/").status == 410
        @test getheader(get(c, "/q/?a=1"), "Location") == "https://elsewhere.example/q"
        @test get(c, "/old-page").status == 301                               # APPEND_SLASH
        @test get(c, "/shop-only/").status == 404 && get(c, "/nothing/").status == 404
        @test get(c, "/articles/").status == 200
        @test_throws IntegrityError create(Redirect; site = s, old_path = "/old-page/", new_path = "/y/")
    finally
        configure!(INSTALLED_APPS = old_apps, MIDDLEWARE = old_mw)
        Admin.unregister!(Site); Admin.unregister!(Redirect)
    end
    @test get_current_site(req) isa RequestSite
end

@testset "hashed static files and the JavaScript catalog" begin
    src, root = mktempdir(), mktempdir()
    mkpath(joinpath(src, "css")); mkpath(joinpath(src, "img"))
    write(joinpath(src, "img", "logo.png"), "PNGDATA")
    write(joinpath(src, "css", "base.css"), "body { color: red }")
    write(joinpath(src, "css", "site.css"), """@import "base.css";\n.logo { background: url("../img/logo.png") } .x { background: url(data:image/png;base64,AAA) }""")
    override_settings(STATIC_DIRS = [src], STATIC_ROOT = root, STATICFILES_STORAGE = :manifest) do
        @test collectstatic() == 3 + length(readdir(joinpath(Juango.ASSETS_DIR, "static", "juango")))   # with Juango's own (htmx, live views)
        paths = JSON.parse(read(joinpath(root, "staticfiles.json"), String))["paths"]
        logo, site, base = paths["img/logo.png"], paths["css/site.css"], paths["css/base.css"]
        @test haskey(paths, "juango/htmx.min.js")
        @test occursin(r"^img/logo\.[0-9a-f]{12}\.png$", logo) && isfile(joinpath(root, logo)) && isfile(joinpath(root, "img", "logo.png"))
        css = read(joinpath(root, site), String)
        @test occursin("url(\"../" * logo * "\")", css) && occursin("@import \"" * basename(base) * "\"", css)
        @test occursin("url(data:image/png;base64,AAA)", css)                 # left alone
        override_settings(DEBUG = false) do
            @test Juango.static_url("css/site.css") == "/static/" * site
            @test tr("{% load static %}{% static 'img/logo.png' %}") == "/static/" * logo
            @test Juango.static_url("img/logo.png?v=2#x") == "/static/" * logo * "?v=2#x"
            @test_throws Juango.ImproperlyConfigured Juango.static_url("missing.js")
        end
        @test Juango.static_url("css/site.css") == "/static/css/site.css"          # DEBUG: the plain names
        # a changed file gets a new name
        write(joinpath(src, "img", "logo.png"), "NEWPNG")
        collectstatic()
        paths2 = JSON.parse(read(joinpath(root, "staticfiles.json"), String))["paths"]
        @test paths2["img/logo.png"] != logo && paths2["css/site.css"] != site
        # #164: SERVE_STATIC serves STATIC_ROOT with DEBUG off: hashed names immutable, .gz copies, ETags, ranges
        @test isfile(joinpath(root, "juango", "htmx.min.js.gz")) && !isfile(joinpath(root, "img", "logo.png.gz"))
        override_settings(DEBUG = false, SERVE_STATIC = true) do
            c = Client()
            r = get(c, "/static/" * paths2["img/logo.png"])
            @test r.status == 200 && String(copy(r.body)) == "NEWPNG" && getheader(r, "Cache-Control") == "public, max-age=31536000, immutable"
            @test getheader(r, "Content-Type") == "image/png"
            r = get(c, "/static/css/base.css")
            @test r.status == 200 && getheader(r, "Cache-Control") == "public, max-age=60"
            et = getheader(r, "ETag")
            r304 = get(c, "/static/css/base.css"; headers = Dict("If-None-Match" => et))
            @test r304.status == 304 && isempty(r304.body)
            plain = get(c, "/static/juango/htmx.min.js")
            z = get(c, "/static/juango/htmx.min.js"; headers = Dict("Accept-Encoding" => "gzip, br"))
            @test getheader(z, "Content-Encoding") == "gzip" && length(z.body) < length(plain.body) && getheader(z, "Vary") == "Accept-Encoding"
            @test getheader(plain, "Content-Encoding") === nothing
            @test String(transcode(Juango.CodecZlib.GzipDecompressor, Vector{UInt8}(z.body))) == String(copy(plain.body))
            rg = get(c, "/static/css/base.css"; headers = Dict("Range" => "bytes=0-3"))
            @test rg.status == 206 && String(copy(rg.body)) == "body" && getheader(rg, "Content-Range") == "bytes 0-3/19"
            @test get(c, "/static/css/base.css"; headers = Dict("Range" => "bytes=50-60")).status == 416
            @test get(c, "/static/nope.css").status == 404 && get(c, "/static/..%2F..%2Fetc%2Fpasswd").status == 404
            @test get(c, "/static/juango/htmx.min.js.gz").status == 404                 # .gz copies aren't served by name
        end
        override_settings(DEBUG = false, SERVE_STATIC = false) do
            @test get(Client(), "/static/css/base.css").status == 404                # off by default
        end
    end

    # the JavaScript catalog
    js = JavaScriptCatalog()
    r = js(Request("GET", "/jsi18n/"))
    @test getheader(r, "Content-Type") == "text/javascript; charset=utf-8"
    @test occursin("juango.pluralidx", text(r)) && occursin("globals[k] = juango[k]", text(r))
    de = with_language(() -> js(Request("GET", "/jsi18n/")), "de")
    @test occursin("\"Save\":\"Sichern\"", text(de)) && occursin("const v = ((n != 1));", text(de))
    j = with_language(() -> JSONCatalog(; prefixes = ["Sa"])(Request("GET", "/jsi18n.json")), "de")
    d = JSON.parse(text(j))
    @test d["catalog"]["Save"] == "Sichern" && all(startswith(k, "Sa") for k in keys(d["catalog"])) && d["plural"] == "(n != 1)"
end

"""
An essay about a topic (shown by the admin documentation), with *Markdown*:

    documented_view(req)

Uses `HttpResponse` & <b>raw</b> text.
"""
function documented_view(req) HttpResponse("doc") end

@testset "admin documentation" begin
    old_apps, old_urls = settings.INSTALLED_APPS, settings.ROOT_URLCONF
    try
        configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.admindocs"]),
                   ROOT_URLCONF = vcat([path("admin/doc/", admindocs_urls()), path("documented/", documented_view; name = "documented")], old_urls))
        @test get(Client(), "/admin/doc/").status == 302                       # staff only
        c = Client()
        force_login!(c, root_user())
        r = get(c, "/admin/doc/")
        @test r.status == 200 && occursin("/admin/doc/models/", text(r))
        r = get(c, "/admin/doc/models/")
        @test occursin("project.Article", text(r)) || occursin(">Article<", text(r))
        r = get(c, "/admin/doc/models/project.article/")
        @test r.status == 200 && occursin("ForeignKey to Author", text(r)) && occursin("<code>project_article</code>", text(r))
        @test get(c, "/admin/doc/models/project.nosuch/").status == 404
        r = get(c, "/admin/doc/views/")
        @test occursin("/documented/", text(r)) && occursin("An essay about a topic", text(r))
        @test occursin("<em>Markdown</em>", text(r)) && occursin("<pre><code>documented_view&#40;req&#41;</code></pre>", text(r)) &&
              occursin("<code>HttpResponse</code> &amp;", text(r)) && !occursin("<b>raw</b>", text(r))
        @test occursin("id=\"for\"", text(get(c, "/admin/doc/tags/"))) && occursin("id=\"upper\"", text(get(c, "/admin/doc/filters/")))
        @test occursin("load humanize", text(get(c, "/admin/doc/filters/"))) && occursin("id=\"humanize-intcomma\"", text(get(c, "/admin/doc/filters/")))
    finally
        configure!(INSTALLED_APPS = old_apps, ROOT_URLCONF = old_urls)
    end
end

# a backend with an object-level rule: authors may change their own articles
struct OwnArticlesBackend end
Juango.backend_has_perm(::OwnArticlesBackend, u, perm, obj) =
    perm == "project.change_article" && obj isa Article && obj.author.name == u.username ? true : nothing

@testset "LoginRequiredMiddleware, remote users, scrypt, object permissions" begin
    # scrypt: RFC 7914 test vectors, and a hash made by Python's hashlib (Django's format)
    @test bytes2hex(Juango.scrypt(UInt8[], UInt8[], 16, 1, 1, 64)) ==
          "77d6576238657b203b19ca42c18a0497f16b4844e3074ae8dfdffa3fede21442fcd0069ded0948f8326a753a0fc81f17e8d3e0fb2e0d3628cf35e20c38d18906"
    @test bytes2hex(Juango.scrypt(codeunits("password"), codeunits("NaCl"), 1024, 8, 16, 64)) ==
          "fdbabe1c9d3472007856e7190d01e9fe7c6ad7cbc8237830e77376634b3731622eaf30d92e22a3886ff109279d9830dac727afb94a83ee6d8360cbdfa2cc0640"
    old_hashers = get(settings, :PASSWORD_HASHERS, nothing)
    configure!(PASSWORD_HASHERS = [ScryptPasswordHasher(work_factor = 2^10), Juango.PBKDF2Hasher()])
    try
        django = "scrypt\$1024\$seasalt\$8\$1\$mBdsVxZCf6G+Bs1aXMjSdR6I0Vt8atpmM4Gvd0hAgnod0ZyMUPDbZ9Z0534FznWrdtrH3Ifd/FCn7Akjoe9Wrg=="
        @test check_password("secret", django) && !check_password("Secret", django)
        h = make_password("hunter2")
        @test startswith(h, "scrypt\$1024\$") && check_password("hunter2", h)
    finally
        old_hashers === nothing ? delete!(Juango.SETTINGS, :PASSWORD_HASHERS) : configure!(PASSWORD_HASHERS = old_hashers)
    end

    # LoginRequiredMiddleware
    mw = settings.MIDDLEWARE
    configure!(MIDDLEWARE = vcat(mw, [LoginRequiredMiddleware]))
    try
        c = Client()
        r = get(c, "/whoami/")
        @test r.status == 302 && getheader(r, "Location") == "/accounts/login/?next=/whoami/"
        @test get(c, "/accounts/login/").status == 200 && get(c, "/accounts/password_reset/").status == 200
        r = get(c, "/admin/")
        @test r.status == 302 && startswith(getheader(r, "Location"), "/admin/login/")          # the admin's own login
        @test get(c, "/no/such/page/").status == 404
        create_user("lr_user", "pw-lr-12345")
        force_login!(c, get(User; username = "lr_user"))
        @test text(get(c, "/whoami/")) == "user:lr_user"
        @test Juango.is_login_not_required(Juango.login_not_required(req -> HttpResponse("open")))
    finally
        configure!(MIDDLEWARE = mw)
    end

    # remote users: a proxy authenticates, Juango trusts its header
    configure!(MIDDLEWARE = vcat(mw, [RemoteUserMiddleware]),
               AUTHENTICATION_BACKENDS = Any[RemoteUserBackend(), ModelBackend()])
    try
        c = Client()
        @test text(get(c, "/whoami/"; headers = Dict("Remote-User" => "proxied"))) == "user:proxied"
        u = get(User; username = "proxied")
        @test !Juango.has_usable_password(u)
        @test text(get(c, "/whoami/")) == "anon"                                  # header gone: logged out
        @test text(get(c, "/whoami/"; headers = Dict("Remote-User" => "proxied"))) == "user:proxied"
        @test text(get(c, "/whoami/"; headers = Dict("Remote-User" => "other"))) == "user:other"   # a different user
        configure!(AUTHENTICATION_BACKENDS = Any[RemoteUserBackend(create_unknown_user = false), ModelBackend()])
        @test text(get(Client(), "/whoami/"; headers = Dict("Remote-User" => "stranger"))) == "anon"
        @test !exists(filter(User; username = "stranger"))
        configure!(MIDDLEWARE = vcat(mw, [PersistentRemoteUserMiddleware]))
        c2 = Client()
        get(c2, "/whoami/"; headers = Dict("Remote-User" => "proxied"))
        @test text(get(c2, "/whoami/")) == "user:proxied"                         # kept without the header
    finally
        configure!(MIDDLEWARE = mw, AUTHENTICATION_BACKENDS = Any[ModelBackend()])
    end

    # object-level permissions from a backend, and in generic views
    configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend(), OwnArticlesBackend()])
    try
        writer = create_user("objwriter", "pw-ow-12345")
        mine = create(Article; title = "Mine", author = create(Author; name = "objwriter"))
        theirs = create(Article; title = "Theirs", author = create(Author; name = "someone else"))
        @test has_perm(writer, "project.change_article"; obj = mine) && !has_perm(writer, "project.change_article"; obj = theirs)
        @test !has_perm(writer, "project.change_article")                       # no model-wide permission
        v = UpdateView(Article; fields = [:title], object_permission_required = "project.change_article", login_required = true)
        rq(o) = (r = RequestFactory(); req = get(r, "/x/"); req.user = writer; req)
        @test v(rq(mine); id = mine.id).status == 200
        @test_throws PermissionDenied v(rq(theirs); id = theirs.id)
    finally
        configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend()])
    end
end

"A middleware with a TemplateResponse hook: adds to the context before rendering."
TplHookMiddleware(get_response) = req -> get_response(req)
Juango.process_template_response(::typeof(TplHookMiddleware), req, resp) = (resp.context_data["name"] = "Hooked"; resp)
struct RefusingUploads end
Juango.upload_file(::RefusingUploads, field, name, ctype, data) = endswith(name, ".exe") ? throw(BadRequest("no executables")) : nothing

@testset "ATOMIC_REQUESTS, error views, TemplateResponse, uploads" begin
    function make_then_fail(req)
        create(Author; name = "atomic-" * req.GET["n"])
        get(req.GET, "fail", "") == "1" && error("boom")
        HttpResponse("made")
    end
    calm(req) = HttpResponse("tpl")
    files_view(req) = (f = req.FILES["doc"]; HttpResponse(string(f.size, " ", temporary_file_path(f) !== nothing, " ", read(f, String),
                                                                 " ", something(temporary_file_path(f), ""))))
    extra = [path("atomic/", make_then_fail), path("nonatomic/", non_atomic_requests(req -> make_then_fail(req))),
             path("tplresp/", req -> TemplateResponse(req, "child.html", Dict("name" => "Plain"))),
             path("upload/", csrf_exempt(files_view)), path("deny/", req -> throw(PermissionDenied("nope")))]
    old = (settings.ROOT_URLCONF, settings.MIDDLEWARE, settings.DEBUG)
    configure!(ROOT_URLCONF = vcat(extra, old[1]), ATOMIC_REQUESTS = true, DEBUG = false)
    try
        c = Client()
        @test get(c, "/atomic/"; data = Dict("n" => "ok")).status == 200 && exists(filter(Author; name = "atomic-ok"))
        @test get(c, "/atomic/"; data = Dict("n" => "rolled", "fail" => "1")).status == 500
        @test !exists(filter(Author; name = "atomic-rolled"))                    # the view's transaction was rolled back
        get(c, "/nonatomic/"; data = Dict("n" => "kept", "fail" => "1"))
        @test exists(filter(Author; name = "atomic-kept"))                       # non_atomic_requests: no transaction

        # custom error views
        configure!(HANDLER404 = (req; exception) -> HttpResponse("custom 404 for $(req.path)"; status = 404),
                   HANDLER500 = req -> HttpResponse("custom 500"; status = 500),
                   HANDLER403 = (req; exception) -> HttpResponse("custom 403: $(exception.msg)"; status = 403))
        r = get(c, "/no-such-page/")
        @test r.status == 404 && text(r) == "custom 404 for /no-such-page/"
        r = get(c, "/atomic/"; data = Dict("n" => "x", "fail" => "1"))
        @test r.status == 500 && text(r) == "custom 500"
        @test text(get(c, "/deny/")) == "custom 403: nope"
        @test isempty(Juango.error_handler_issues())
        configure!(HANDLER404 = req -> HttpResponse("no exception keyword"), HANDLER500 = (a, b) -> nothing)
        @test length(Juango.error_handler_issues()) == 2
        configure!(HANDLER404 = (req; exception) -> error("broken handler"), HANDLER500 = nothing, HANDLER403 = nothing)
        @test get(c, "/no-such-page/").status == 404                             # a failing handler falls back to the built-in page
        configure!(HANDLER404 = nothing)

        # TemplateResponse: rendered after the middleware's hook
        r = get(c, "/tplresp/")
        @test occursin("Plain", text(r)) && r.is_rendered && r.templates == ["child.html"]
        configure!(MIDDLEWARE = vcat(old[2], [TplHookMiddleware]))
        r = get(c, "/tplresp/")
        @test occursin("Hooked", text(r)) && !occursin("Plain", text(r))
        tr = TemplateResponse(get(RequestFactory(), "/"), "child.html", Dict("name" => "Direct"))
        @test !tr.is_rendered && tr.template_name == "child.html"
        tr.context_data = Dict("name" => "Changed")
        @test occursin("Changed", text(Juango.render_response!(tr)))
        configure!(MIDDLEWARE = old[2])

        # uploads: big files go to a temporary file, removed after the request
        configure!(FILE_UPLOAD_MAX_MEMORY_SIZE = 10)
        r = post(c, "/upload/", Dict("doc" => UploadedFile("small.txt", "tiny")))
        @test text(r) == "4 false tiny "
        r = post(c, "/upload/", Dict("doc" => UploadedFile("big.txt", "a much longer file body")))
        size_, ondisk, body, tmp = split(text(r), " "; limit = 4)[1], split(text(r), " ")[2], "a much longer file body", split(text(r), " ")[end]
        @test size_ == "23" && ondisk == "true" && occursin(body, text(r)) && !isfile(tmp)
        configure!(FILE_UPLOAD_HANDLERS = Any[RefusingUploads(), Juango.MemoryFileUploadHandler()], FILE_UPLOAD_MAX_MEMORY_SIZE = 2_621_440)
        @test post(c, "/upload/", Dict("doc" => UploadedFile("virus.exe", "MZ"))).status == 400
        @test text(post(c, "/upload/", Dict("doc" => UploadedFile("ok.txt", "fine")))) == "4 false fine "

        # FileSystemStorage moves temporary uploads into place, with FILE_UPLOAD_PERMISSIONS
        dir = mktempdir()
        tmpf = tempname(); write(tmpf, "on disk")
        configure!(FILE_UPLOAD_PERMISSIONS = 0o600)
        st = Juango.FileSystemStorage(dir)
        name = Juango.save_upload(st, "docs/a.txt", Juango.TemporaryUploadedFile("a.txt", tmpf))
        @test read(joinpath(dir, name), String) == "on disk" && (filemode(joinpath(dir, name)) & 0o777) == 0o600
    finally
        configure!(ROOT_URLCONF = old[1], MIDDLEWARE = old[2], DEBUG = old[3], ATOMIC_REQUESTS = false, HANDLER404 = nothing,
                   HANDLER403 = nothing, HANDLER500 = nothing, FILE_UPLOAD_MAX_MEMORY_SIZE = 2_621_440,
                   FILE_UPLOAD_HANDLERS = Any[Juango.MemoryFileUploadHandler(), Juango.TemporaryFileUploadHandler()],
                   FILE_UPLOAD_PERMISSIONS = 0o644)
    end
end

@form HxNameForm begin
    name = CharField(max_length = 10)
end

@testset "htmx" begin
    write(joinpath(TPL, "hx_page.html"), "<html>{% htmx_script %}<div id=\"messages\"></div>" *
          "<ul>{% partialdef rows inline %}{% for x in xs %}<li>{{ x }}</li>{% endfor %}{% endpartialdef %}</ul></html>")
    write(joinpath(TPL, "hx_form.html"), "<main>{% partialdef form inline %}<form>{{ form.name.errors }}</form>{% endpartialdef %}</main>")
    function hx_list(req)
        q = get(req.GET, "q", "")
        render(req, "hx_page.html", Dict("xs" => filter(x -> occursin(q, x), ["apple", "banana", "cherry"])); htmx_partial = "rows")
    end
    function hx_info(req)
        h = req.htmx
        JsonResponse(Dict("htmx" => is_htmx(req), "boosted" => h.boosted, "target" => h.target, "trigger" => h.trigger,
                          "trigger_name" => h.trigger_name, "prompt" => h.prompt, "path" => h.current_url_abs_path,
                          "restore" => h.history_restore_request))
    end
    function hx_form(req)
        form = HxNameForm(req.method == "POST" ? req.POST : nothing)
        req.method == "POST" && is_valid(form) && return hx_trigger(hx_redirect("/done/"), Dict("saved" => Dict("id" => 7)))
        render(req, "hx_form.html", Dict("form" => form); htmx_partial = "form", status = form_status(form))
    end
    function hx_msg(req)
        message!(req, :success, "Saved <ok>")
        render(req, "hx_form.html", Dict("form" => HxNameForm(nothing)); htmx_partial = "form")
    end
    plain(req) = HttpResponse("plain")
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("hx/list/", hx_list), path("hx/info/", hx_info), path("hx/form/", hx_form),
                               path("hx/msg/", hx_msg), path("hx/plain/", plain)])
    try
        c = Client()
        # the whole page normally; the partial for htmx, but not for boosted requests; Vary either way
        r = get(c, "/hx/list/")
        @test occursin("<html>", text(r)) && occursin("htmx.min.js", text(r)) && occursin("htmx:configRequest", text(r))
        @test occursin("HX-Request", something(getheader(r, "Vary"), ""))
        r = get(c, "/hx/list/?q=an"; htmx = true)
        @test text(r) == "<li>banana</li>" && occursin("HX-Request", getheader(r, "Vary"))
        @test occursin("<html>", text(get(c, "/hx/list/"; htmx = (boosted = true,))))
        @test occursin("<html>", text(get(c, "/hx/list/"; htmx = (history_restore_request = true,))))
        @test getheader(get(c, "/hx/plain/"), "Vary") === nothing || !occursin("HX-Request", getheader(get(c, "/hx/plain/"), "Vary"))
        # the htmx script tag: config, the vendored file (served from Juango's static files), the CSRF header
        @test occursin("\"code\":\"422\",\"swap\":true", text(get(c, "/hx/list/")))
        @test get(c, settings.STATIC_URL * "juango/htmx.min.js").status == 200
        override_settings(SECURE_CSP = Dict("script-src" => [CSP.SELF, CSP.NONCE]),          # the inline script gets the nonce
                          MIDDLEWARE = [Juango.default_settings()[:MIDDLEWARE]..., ContentSecurityPolicyMiddleware]) do
            r = get(c, "/hx/list/")
            nonce = match(r"<script nonce=\"([^\"]+)\">document", text(r))
            @test nonce !== nothing && occursin("'nonce-" * nonce[1] * "'", getheader(r, "Content-Security-Policy"))
        end
        @test !occursin("nonce", text(get(c, "/hx/list/")))

        # request details, including URI-encoded headers
        d = Juango.JSON.parse(text(get(c, "/hx/info/"; htmx = (target = "results", trigger = "search", trigger_name = "q",
                                                                  current_url = "http://testserver/hx/list/?q=a", prompt = "yes"))))
        @test d["htmx"] && !d["boosted"] && d["target"] == "results" && d["trigger"] == "search" && d["trigger_name"] == "q"
        @test d["prompt"] == "yes" && d["path"] == "/hx/list/?q=a" && !d["restore"]
        d = Juango.JSON.parse(text(get(c, "/hx/info/")))
        @test !d["htmx"] && d["target"] === nothing && d["path"] === nothing
        d = Juango.JSON.parse(text(get(c, "/hx/info/"; headers = Dict("HX-Request" => "true", "HX-Prompt" => "caf%C3%A9",
                                                                        "HX-Prompt-URI-AutoEncoded" => "true",
                                                                        "HX-Current-URL" => "https://elsewhere.example/x"))))
        @test d["prompt"] == "café" && d["path"] === nothing
        @test Juango.truthy(HtmxDetails(Request("GET", "/"; headers = Dict("HX-Request" => "true"))))
        @test tr("{% if request.htmx %}hx{% else %}page{% endif %}", Dict("request" => Request("GET", "/"))) == "page"

        # forms: errors re-render the partial with 422; success redirects the browser and triggers an event
        r = post(c, "/hx/form/", Dict("name" => "far too long a name"); htmx = true)
        @test r.status == 422 && startswith(text(r), "<form>") && occursin("at most", text(r))
        r = post(c, "/hx/form/", Dict("name" => "Ann"); htmx = true)
        @test assert_htmx(r; redirect = "/done/", trigger = Dict("saved" => Dict("id" => 7)), status = 200)
        @test_throws Exception assert_htmx(r; refresh = true)
        @test get(c, "/hx/form/").status == 200

        # messages queued during an htmx request arrive as an out-of-band swap, once
        r = get(c, "/hx/msg/"; htmx = true)
        @test occursin("<div id=\"messages\" hx-swap-oob=\"true\"><p class=\"message success\">Saved &lt;ok&gt;</p></div>", text(r))
        @test !occursin("hx-swap-oob", text(get(c, "/hx/form/"; htmx = true)))
        override_settings(HTMX_OOB_MESSAGES = false) do
            @test !occursin("hx-swap-oob", text(get(c, "/hx/msg/"; htmx = true)))
        end

        # response helpers
        r = hx_trigger(HttpResponse("x"), "a")
        hx_trigger(r, ["b", "a"])
        @test getheader(r, "HX-Trigger") == "a, b"
        hx_trigger(r, Dict("c" => 1))
        @test Juango.JSON.parse(getheader(r, "HX-Trigger")) == Dict("a" => nothing, "b" => nothing, "c" => 1)
        @test getheader(hx_trigger(HttpResponse(""), :done; after = :settle), "HX-Trigger-After-Settle") == "done"
        @test getheader(hx_trigger(HttpResponse(""), "done"; after = :swap), "HX-Trigger-After-Swap") == "done"
        @test_throws ArgumentError hx_trigger(HttpResponse(""), "x"; after = :later)
        @test getheader(hx_refresh(), "HX-Refresh") == "true"
        @test getheader(hx_location("/a/"), "HX-Location") == "/a/"
        @test Juango.JSON.parse(getheader(hx_location("/a/"; target = "#main"), "HX-Location")) == Dict("path" => "/a/", "target" => "#main")
        r = hx_reselect(hx_reswap(hx_retarget(hx_replace_url(hx_push_url(HttpResponse(""), false), "/b/"), "#t"), "outerHTML"), ".x")
        @test assert_htmx(r; push_url = false, replace_url = "/b/", retarget = "#t", reswap = "outerHTML", reselect = ".x")
        @test hx_stop_polling().status == HTMX_STOP_POLLING == 286
    finally
        configure!(ROOT_URLCONF = old_urls)
        rm(joinpath(TPL, "hx_page.html"); force = true); rm(joinpath(TPL, "hx_form.html"); force = true)
    end
end

Base.@kwdef mutable struct LiveCounter <: LiveView
    count::Int = 0
    step::Int = 1
    room::String = ""
    log::Vector{String} = String[]
end
function Juango.mount(v::LiveCounter, req, params)
    get(params, "start", "") == "forbidden" && throw(PermissionDenied())
    v.count = parse(Int, get(params, "start", "0"))
    v.room = string(get(params, "room", "lobby"))
    subscribe("room:" * v.room)
end
function Juango.handle_event(v::LiveCounter, name, params)
    name == "inc" && (v.count += parse(Int, get(params, "by", string(v.step))))
    name == "leave" && return live_redirect("/bye/")
    name == "boom" && error("boom")
    nothing
end
Juango.handle_info(v::LiveCounter, msg) = push!(v.log, string(msg))

@testset "live views" begin
    write(joinpath(TPL, "live_counter.html"), "<html><h1>Counter</h1>{% liveview %}<p id=\"n\">{{ count }}</p>" *
          "<button j-click=\"inc\" j-value-by=\"5\">+5</button><ul>{% for m in log %}<li>{{ m }}</li>{% endfor %}</ul>{% endliveview %}</html>")
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [live("live/<str:room>/", LiveCounter, "live_counter.html"; name = "counter")])
    try
        # the page: ordinary HTML with the live part and the scripts; the page's view doesn't stay subscribed
        c = Client()
        r = get(c, "/live/kitchen/?start=3")
        @test r.status == 200 && occursin("<div id=\"j-live\" data-j-live=\"/live/kitchen/\"><p id=\"n\">3</p>", text(r))
        @test occursin("juango/live.js", text(r)) && occursin("juango/idiomorph.min.js", text(r)) && occursin("<h1>Counter</h1>", text(r))
        @test publish("room:kitchen", "nobody") == 0
        @test get(c, "/live/kitchen/?start=forbidden").status == 403
        @test reverse_url("counter"; room = "x") == "/live/x/"
        @test get(c, settings.STATIC_URL * "juango/live.js").status == 200

        # without a browser: events, messages, redirects
        lt = live_test(LiveCounter, "live_counter.html"; params = Dict("start" => "1", "room" => "t"))
        @test occursin("<p id=\"n\">1</p>", lt.html) && !occursin("<h1>", lt.html) && startswith(lt.html, "<div id=\"j-live\"")
        @test occursin("<p id=\"n\">6</p>", live_event!(lt, "inc", Dict("by" => "5")))
        live_event!(lt, "inc")
        @test lt.view.count == 7
        @test occursin("<li>hello</li>", live_info!(lt, "hello"))
        @test publish("room:t", "from elsewhere") == 1 && publish("room:other", "x") == 0
        @test occursin("<li>from elsewhere</li>", live_flush!(lt))
        live_event!(lt, "leave")
        @test lt.redirect == "/bye/"
        close(lt)
        @test publish("room:t", "gone") == 0
        @test_throws ArgumentError subscribe("x")              # only inside a live view

        # over a real socket
        H = Juango.HTTP
        port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)
            p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
        end
        server = runserver("127.0.0.1", port; block = false, quiet = true)
        try
            msgs = H.WebSockets.open("ws://127.0.0.1:$port/live/den/") do ws
                out = Any[]
                ws_send(ws, Dict("type" => "join", "params" => Dict("start" => "10")))
                push!(out, Juango.JSON.parse(ws_receive(ws)))
                ws_send(ws, Dict("type" => "event", "event" => "inc", "params" => Dict("by" => "5")))
                push!(out, Juango.JSON.parse(ws_receive(ws)))
                sleep(0.2)
                push!(out, publish("room:den", "news"))                # delivered to this page's view
                push!(out, Juango.JSON.parse(ws_receive(ws)))
                ws_send(ws, Dict("type" => "event", "event" => "leave", "params" => Dict()))
                push!(out, Juango.JSON.parse(ws_receive(ws)))
                out
            end
            @test msgs[1]["type"] == "render" && occursin("<p id=\"n\">10</p>", msgs[1]["html"])
            @test occursin("<p id=\"n\">15</p>", msgs[2]["html"])
            @test msgs[3] == 1 && occursin("<li>news</li>", msgs[4]["html"])
            @test msgs[5] == Dict("type" => "redirect", "url" => "/bye/")
            sleep(0.3)
            @test publish("room:den", "after close") == 0                    # unsubscribed when the page closed
            # a refused mount closes the socket with 4403
            code = H.WebSockets.open("ws://127.0.0.1:$port/live/den/") do ws
                ws_send(ws, Dict("type" => "join", "params" => Dict("start" => "forbidden")))
                try ws_receive(ws); nothing catch e; e end
            end
            @test code isa H.WebSockets.WebSocketError && code.message.code == 4403
        finally
            close(server)
        end
    finally
        configure!(ROOT_URLCONF = old_urls)
        rm(joinpath(TPL, "live_counter.html"); force = true)
    end
end


@testset "security review (#100)" begin
    # paths: a sibling directory isn't inside the root
    @test Juango.within("/srv/static", "/srv/static/css/a.css") && Juango.within("/srv/static/", "/srv/static")
    @test !Juango.within("/srv/static", "/srv/static_private/x") && !Juango.within("/srv/static", "/srv")
    parent = mktempdir()
    sdir, private = joinpath(parent, "static"), joinpath(parent, "static_private")
    mkpath(sdir); mkpath(private)
    write(joinpath(sdir, "ok.txt"), "public"); write(joinpath(private, "secret.txt"), "secret")
    override_settings(STATIC_DIRS = [sdir]) do
        c = Client()
        @test text(get(c, "/static/ok.txt")) == "public"
        @test get(c, "/static/../static_private/secret.txt").status == 404
        @test get(c, "/static/%2e%2e/static_private/secret.txt").status == 404
    end
    write(joinpath(parent, "static_private", "t.html"), "private template")
    @test Juango.find_template("../static_private/t.html", [sdir]; throw_missing = false) === nothing

    # hosts: DEBUG with no ALLOWED_HOSTS allows only localhost names; malformed hosts never pass
    hreq(h) = Request("GET", "/"; headers = Dict("Host" => h))
    override_settings(DEBUG = true, ALLOWED_HOSTS = String[]) do
        @test all(h -> Juango.host_allowed(hreq(h)), ["localhost", "localhost:8000", "app.localhost", "127.0.0.1:8000", "[::1]:8000"])
        @test !any(h -> Juango.host_allowed(hreq(h)), ["evil.example", "rebind.attacker.example:8000"])
    end
    override_settings(DEBUG = false, ALLOWED_HOSTS = [".example.com"]) do
        @test Juango.host_allowed(hreq("www.example.com")) && Juango.host_allowed(hreq("example.com:443"))
        @test !any(h -> Juango.host_allowed(hreq(h)), ["evilexample.com", "example.com@evil.org", "exa mple.com", "example.com/x", ""])
    end

    # redirects: only this site
    ok = ["/next/", "/a?b=//c", "http://testserver/x", "https://testserver/x"]
    bad = ["//evil.example", "/\\evil.example", "\\\\evil.example", "/\t/evil.example", "https:evil.example", "javascript:alert(1)",
           "http://evil.example", "http://testserver@evil.example/", "///evil.example", "", "ftp://testserver/x"]
    @test all(u -> url_has_allowed_host_and_scheme(u, ["testserver"]), ok)
    @test !any(u -> url_has_allowed_host_and_scheme(u, ["testserver"]), bad)
    @test !url_has_allowed_host_and_scheme("http://testserver/x", ["testserver"]; require_https = true)
    create_user("redirect-tester", "pw-redirect-1"; email = "rt@x.io")
    c = Client()
    r = post(c, "/accounts/login/?next=/\\evil.example", Dict("username" => "redirect-tester", "password" => "pw-redirect-1"))
    @test r.status == 302 && !occursin("evil", getheader(r, "Location"))

    # CSRF: masked tokens, scheme-aware Origin, Referer over HTTPS, every unsafe method, malformed cookies
    secret = Juango.random_string(32)
    m1, m2 = Juango.mask_csrf(secret), Juango.mask_csrf(secret)
    @test m1 != m2 && Juango.unmask_csrf(m1) == secret == Juango.unmask_csrf(m2) && Juango.unmask_csrf(secret) == secret
    @test Juango.unmask_csrf("short") === nothing && Juango.unmask_csrf("\"" ^ 64) === nothing
    function creq(; method = "POST", origin = nothing, referer = nothing, secure = false, token = Juango.mask_csrf(secret), cookie = secret)
        h = Dict("Host" => "testserver", "Cookie" => "csrftoken=$cookie", "X-CSRFToken" => token)
        origin === nothing || (h["Origin"] = origin)
        referer === nothing || (h["Referer"] = referer)
        r = Request(method, "/"; headers = h)
        secure && (r.meta[:secure] = true)
        r
    end
    passes(r) = try Juango.check_csrf(r); true catch e; e isa Juango.CsrfFailure || rethrow(); false end
    @test passes(creq()) && passes(creq(token = secret)) && !passes(creq(token = Juango.mask_csrf(Juango.random_string(32))))
    @test passes(creq(origin = "http://testserver")) && !passes(creq(origin = "https://evil.example")) && !passes(creq(origin = "null"))
    @test passes(creq(secure = true, origin = "https://testserver")) && !passes(creq(secure = true, origin = "http://testserver"))
    @test !passes(creq(secure = true)) && passes(creq(secure = true, referer = "https://testserver/form/"))
    @test !passes(creq(secure = true, referer = "http://testserver/form/")) && !passes(creq(secure = true, referer = "https://evil.example/"))
    override_settings(CSRF_TRUSTED_ORIGINS = ["https://app.example"]) do
        @test passes(creq(secure = true, referer = "https://app.example/x")) && passes(creq(origin = "https://app.example"))
    end
    override_settings(ROOT_URLCONF = [path("csrf-form/", req -> render(req, Template("<form>{% csrf_token %}</form>")))]) do
        c = Client(enforce_csrf = true)
        @test request(c, "PROPFIND", "/csrf-form/").status == 403                    # not just POST/PUT/PATCH/DELETE
        r = get(c, "/csrf-form/"; headers = Dict("Cookie" => "csrftoken=\"<script>"))  # a malformed cookie is replaced
        @test r.status == 200 && length(c.cookies["csrftoken"]) == 32 && !occursin("<script>", text(r))
    end

    # output: the *_html truncation filters keep unsafe input escaped
    @test tr("{{ s|truncatechars_html:20 }}", Dict("s" => "<script>x</script>")) == "&lt;script&gt;x&lt;/script&gt;"
    @test tr("{{ s|truncatewords_html:2 }}", Dict("s" => "<b>a</b> b c")) == "&lt;b&gt;a&lt;/b&gt; b …"
    @test tr("{{ s|safe|truncatewords_html:2 }}", Dict("s" => "<b>a</b> b c")) == "<b>a</b> b …"

    # request limits: the number of uploaded files
    override_settings(DATA_UPLOAD_MAX_NUMBER_FILES = 2) do
        files = Dict("f$i" => Juango.UploadedFile("f$i.txt", "x"; content_type = "text/plain") for i in 1:3)
        @test post(Client(), "/contact/", files).status == 400
    end
    @test Juango.server_timeouts().read_header_timeout == 10 && Juango.server_timeouts().idle_timeout == 120

    # timing: an inactive user's password is still checked
    @test authenticate("alice", "nope") === nothing

    # check --deploy names the new risks
    override_settings(ALLOWED_HOSTS = ["*"], DATA_UPLOAD_MAX_NUMBER_FILES = nothing, SERVER_IDLE_TIMEOUT = nothing,
                      CACHES = Dict("default" => Dict(:backend => :redis, :serializer => :serialization)),
                      MIDDLEWARE = filter(!=(Juango.CsrfViewMiddleware), Juango.default_settings()[:MIDDLEWARE])) do
        ids = [m.id for m in Juango.deploy_checks()]
        @test all(in(ids), ["juango.W101", "juango.W102", "juango.W103", "juango.W104", "security.W003"])
    end
    @test !any(in(["juango.W101", "juango.W102", "juango.W103", "juango.W104", "security.W003"]), [m.id for m in Juango.deploy_checks()])
    rm(parent; recursive = true)
end

@testset "from porting a Django app: auth names, sessions, dates, filters, forms, test context, through" begin
    # #119: create_user's password keyword; get_username / get_full_name / get_short_name
    u = create_user("kwpass"; password = "Kw-pass-123", first_name = "Kay", last_name = "Doe")
    @test check_password(u, "Kw-pass-123")
    @test_throws ArgumentError create_user("twice", "a-Pass-123"; password = "b-Pass-123")
    s = create_superuser("kwsuper"; password = "Kw-pass-456")
    @test s.is_superuser && check_password(s, "Kw-pass-456")
    @test get_username(u) == "kwpass" && get_full_name(u) == "Kay Doe" && get_short_name(u) == "Kay"
    @test tr("{{ u.get_username }}|{{ u.get_full_name }}|{{ u.get_short_name }}|{{ a.get_username }}|{{ a.is_anonymous }}",
             Dict("u" => u, "a" => Juango.AnonymousUser())) == "kwpass|Kay Doe|Kay||True"

    # #120: list filters on a missing value; lists print as Django prints them
    @test tr("[{{ missing|slice:\":2\" }}][{{ missing|slice:\":2\"|upper }}][{{ missing|first }}][{{ missing|join:\", \" }}]", Dict()) == "[][][][]"
    @test tr("{{ xs }}", Dict("xs" => Any["a", 1])) == "[&#x27;a&#x27;, 1]" && tr("{{ xs }}", Dict("xs" => Any[])) == "[]"

    # #118: get(f, session, k), get!(session, k, v), get!(f, session, k)
    sess = Juango.Session()
    @test get(() -> 0, sess, "n") == 0 && !sess.modified
    @test get!(sess, "cart", Any[]) == Any[] && sess.modified && haskey(sess, "cart")
    push!(get!(() -> Any[], sess, "seen"), 7)
    @test sess["seen"] == [7] && get!(() -> error("not called"), sess, "seen") == [7]

    # #114: localdate() and localtime()
    @test localdate() isa Date && localtime() isa Union{DateTime,Juango.TimeZones.ZonedDateTime}
    override_settings(USE_TZ = true, TIME_ZONE = "Pacific/Auckland") do
        z = Juango.TimeZones.ZonedDateTime(2025, 12, 31, 12, Juango.TimeZones.tz"UTC")     # already 1 January there
        @test localdate(z) == Date(2026, 1, 1) && localdate() isa Date
        @test Juango.TimeZones.timezone(localtime()) == Juango.TimeZones.TimeZone("Pacific/Auckland")
    end

    # #121: the test client's response.context has the context processors' values too
    r = get(Client(), "/")
    @test r.context["name"] == "World" && haskey(r.context, "user") && haskey(r.context, "csrf_token")

    # #123: TypedChoiceField's empty_value
    f = Form([:source => TypedChoiceField(["a" => "A", "" => "None"]; blank = true)]; data = QueryDict("source="))
    @test is_valid(f) && f.cleaned_data[:source] == ""
    f = Form([:n => TypedChoiceField(["1" => "One"]; coerce = x -> parse(Int, x), blank = true, empty_value = nothing)]; data = QueryDict("n="))
    @test is_valid(f) && f.cleaned_data[:n] === nothing
    f = Form([:n => TypedChoiceField(["1" => "One"]; coerce = x -> parse(Int, x))]; data = QueryDict("n=1"))
    @test is_valid(f) && f.cleaned_data[:n] == 1

    # #122: BoundField attributes, radio/checkbox lists, iterating the options, add_widget_attrs!
    F = Form([:days => MultipleChoiceField(["mon" => "Monday", "tue" => "Tuesday"]; widget = Widget(:checkboxes)),
              :size => CharField(max_length = 1, choices = ["s" => "Small", "l" => "Large"], widget = :radio),
              :colour => CharField(max_length = 1, choices = ["r" => "Red", "g" => "Green"]),
              :agree => BooleanField(), :note => TextField(blank = true), :name => CharField(max_length = 10)];
             data = QueryDict("p-days=tue&p-size=l&p-name=x"), prefix = "p")
    @test [bf.widget_type for bf in F] == ["checkboxselectmultiple", "radioselect", "select", "checkbox", "textarea", "text"]
    @test F[:days].auto_id == "id_p-days" && F[:days].html_name == "p-days" && F[:days].use_fieldset && !F[:name].use_fieldset
    @test F[:name].data == "x" && F[:name].initial === nothing
    opts = collect(F[:days])
    @test length(opts) == 2 && opts[2].choice_label == "Tuesday" && opts[2].id_for_label == "id_p-days_1" && opts[2].selected
    @test opts[2].tag.s == "<input type=\"checkbox\" name=\"p-days\" value=\"tue\" id=\"id_p-days_1\" checked>"
    html = tr("{% for c in f.size %}[{{ c.tag }}|{{ c.choice_label }}]{% endfor %}", Dict("f" => F))
    @test occursin("type=\"radio\" name=\"p-size\" value=\"l\" id=\"id_p-size_1\" required checked", html) && occursin("|Small]", html)
    @test occursin("<div id=\"id_p-size\"><div><label for=\"id_p-size_0\"><input type=\"radio\"", tr("{{ f.size }}", Dict("f" => F)))
    @test occursin("<option value=\"g\">Green</option>", tr("{% for c in f.colour %}{{ c.tag }}{% endfor %}", Dict("f" => F)))
    add_widget_attrs!(F) do bf
        bf.widget_type == "checkbox" ? Dict("class" => "form-check-input") :
        bf.widget_type == "select" ? Dict("class" => "form-select") : Dict("class" => "form-control")
    end
    @test occursin("class=\"form-check-input\"", tr("{{ f.agree }}", Dict("f" => F))) &&
          occursin("class=\"form-select\"", tr("{{ f.colour }}", Dict("f" => F)))
    add_widget_attrs!(bf -> Dict("class" => "big"), F)
    @test occursin("class=\"form-control big\"", tr("{{ f.name }}", Dict("f" => F)))

    # #117: through(Model, :field)
    Th = through(Essay, :topics)
    @test Th === Juango.through_model(only(filter(f -> f.name === :topics, Juango.modelmeta(Essay).m2m)))
    e = create(Essay; title = "through"); t1 = create(Topic; name = "th1"); t2 = create(Topic; name = "th2")
    bulk_create([Th(essay = e, topic = t1), Th(essay = e, topic = t2)])
    @test count(e.topics) == 2 && count(filter(Th; essay = e)) == 2
    @test_throws ArgumentError through(Essay, :nope)
end

# --- live views, part 2 (#103) ------------------------------------------------------------------------

Base.@kwdef mutable struct LiveKeep <: LiveView
    count::Int = 0
    note::String = ""
    files::Vector{String} = String[]
end
Juango.live_snapshot(::Type{LiveKeep}) = true
function Juango.handle_event(v::LiveKeep, name, params)
    name == "inc" && (v.count += 1)
    name == "note" && (v.note = string(params["text"]))
    name == "grow" && (v.note = "x" ^ 5000)
    name == "send" && (f = params["file"]; push!(v.files, "$(f.name):$(f.size):$(read(f, String)[1:3])"))
    nothing
end
Base.@kwdef mutable struct LiveContact <: LiveView
    form::LiveForm = LiveForm(d -> Form([:name => CharField(max_length = 5), :email => EmailField()]; data = d))
    sent::Bool = false
end
function Juango.handle_event(v::LiveContact, name, params)
    name == "validate" && live_change!(v.form, params)
    name == "save" && (v.sent = live_submit!(v.form, params))
    nothing
end

@testset "live views, part 2: patches, limits, snapshots, uploads, forms, pub-sub (#103)" begin
    # patches are computed in UTF-16 code units, as the browser slices strings
    apply(old, p) = (u = transcode(UInt16, old); transcode(String, vcat(u[1:p[1]], transcode(UInt16, p[3]), u[p[1]+p[2]+1:end])))
    for (a, b) in [("<p>1</p>", "<p>12</p>"), ("héllo wörld", "héllo wörld!"), ("a😀b", "a😁b"), ("", "x"), ("same", "same"),
                   ("<ul><li>1</li></ul>", "<ul><li>0</li><li>1</li></ul>")]
        @test apply(a, Juango.live_patch(a, b)) == b
    end
    @test Juango.live_patch("<p>1</p>", "<p>2</p>") == (3, 1, "2")

    write(joinpath(TPL, "live_keep.html"), "<html>{% liveview %}<p id=\"n\">{{ count }}</p><p>{{ note }}</p>{{ files|join:\",\" }}" *
          "<div>" * "padding " ^ 40 * "</div>{% endliveview %}</html>")
    write(joinpath(TPL, "live_contact.html"), "<html>{% liveview %}{{ form.form.as_p }}{% if sent %}SENT{% endif %}{% endliveview %}</html>")
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [live("keep/", LiveKeep, "live_keep.html"), live("contact/", LiveContact, "live_contact.html")])
    H = Juango.HTTP
    port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)
        p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
    end
    server = runserver("127.0.0.1", port; block = false, quiet = true)
    recv(ws) = Juango.JSON.parse(ws_receive(ws))
    try
        # patches: a small change goes as a patch against the last HTML; a resync gets it all
        out = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
            ws_send(ws, Dict("type" => "join", "diff" => true, "params" => Dict()))
            r1 = recv(ws)
            ws_send(ws, Dict("type" => "event", "event" => "inc", "params" => Dict()))
            r2 = recv(ws)
            ws_send(ws, Dict("type" => "resync"))
            r3 = recv(ws)
            (r1, r2, r3)
        end
        r1, r2, r3 = out
        @test r1["type"] == "render" && r1["seq"] == 1 && occursin("<p id=\"n\">0</p>", r1["html"])
        @test r2["type"] == "patch" && r2["base"] == 1 && r2["seq"] == 2 && length(r2["ins"]) < 10
        @test occursin("<p id=\"n\">1</p>", apply(r1["html"], (r2["start"], r2["del"], r2["ins"])))
        @test r3["type"] == "render" && r3["html"] == apply(r1["html"], (r2["start"], r2["del"], r2["ins"]))
        @test haskey(r2, "snap")                                                   # LiveKeep keeps snapshots

        # a reconnect with the snapshot gets the state back; a tampered one is ignored
        snap = r2["snap"]
        back = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
            ws_send(ws, Dict("type" => "join", "diff" => true, "params" => Dict(), "snap" => snap))
            recv(ws)
        end
        @test occursin("<p id=\"n\">1</p>", back["html"])
        bad = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
            ws_send(ws, Dict("type" => "join", "params" => Dict(), "snap" => snap[1:end-2] * "xx"))
            recv(ws)
        end
        @test occursin("<p id=\"n\">0</p>", bad["html"])

        # uploads over the socket: chunks, then the event names the file
        data = "abc" * "z" ^ 100
        up = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
            ws_send(ws, Dict("type" => "join", "params" => Dict()))
            recv(ws)
            ws_send(ws, Dict("type" => "upload", "ref" => "u1", "name" => "../x.csv", "content_type" => "text/csv",
                             "chunk" => Juango.base64encode(data[1:50]), "last" => false))
            ws_send(ws, Dict("type" => "upload", "ref" => "u1", "name" => "../x.csv", "chunk" => Juango.base64encode(data[51:end]), "last" => true))
            ws_send(ws, Dict("type" => "event", "event" => "send", "params" => Dict("file" => Dict("__upload__" => "u1"))))
            recv(ws)
        end
        @test occursin("x.csv:103:abc", up["html"])

        # limits: the size of a view's state, and live views per session
        override_settings(LIVE_MAX_STATE_BYTES = 2000) do
            code = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
                ws_send(ws, Dict("type" => "join", "params" => Dict()))
                recv(ws)
                ws_send(ws, Dict("type" => "event", "event" => "grow", "params" => Dict()))
                try recv(ws); nothing catch e; e end
            end
            @test code isa H.WebSockets.WebSocketError && code.message.code == 4413
        end
        override_settings(LIVE_MAX_VIEWS = 1) do                                  # (no session here: only the total counts)
            code = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws1
                ws_send(ws1, Dict("type" => "join", "params" => Dict()))
                recv(ws1)
                H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws2
                    ws_send(ws2, Dict("type" => "join", "params" => Dict()))
                    try recv(ws2); nothing catch e; e end
                end
            end
            @test code isa H.WebSockets.WebSocketError && code.message.code == 4429
        end
        override_settings(LIVE_MAX_MESSAGE_BYTES = 100) do
            code = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
                ws_send(ws, Dict("type" => "join", "params" => Dict()))
                recv(ws)
                ws_send(ws, Dict("type" => "event", "event" => "note", "params" => Dict("text" => "y" ^ 200)))
                try recv(ws); nothing catch e; e end
            end
            @test code isa H.WebSockets.WebSocketError && code.message.code == 4413
        end
        sleep(0.2)
        @test isempty(Juango.LIVE_OPEN) && Juango.LIVE_OPEN_TOTAL[] == 0           # released when the sockets closed
        # per session; visitors without one (all behind a proxy share an address) only count in the total
        override_settings(LIVE_MAX_VIEWS_PER_SESSION = 2) do
            @test Juango.live_claim!("session:a") && Juango.live_claim!("session:a") && !Juango.live_claim!("session:a")
            @test all(_ -> Juango.live_claim!(nothing), 1:5)
            Juango.live_release!("session:a"); Juango.live_release!("session:a")
            foreach(_ -> Juango.live_release!(nothing), 1:5)
        end
        @test isempty(Juango.LIVE_OPEN) && Juango.LIVE_OPEN_TOTAL[] == 0
        # at most DATA_UPLOAD_MAX_NUMBER_FILES uploads waiting at once
        override_settings(DATA_UPLOAD_MAX_NUMBER_FILES = 1) do
            code = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws
                ws_send(ws, Dict("type" => "join", "params" => Dict()))
                recv(ws)
                for r in ("a", "b")
                    ws_send(ws, Dict("type" => "upload", "ref" => r, "name" => "x", "chunk" => Juango.base64encode("x"), "last" => false))
                end
                try recv(ws); nothing catch e; e end
            end
            @test code isa H.WebSockets.WebSocketError && code.message.code == 4413
        end
    finally
        close(server)
    end

    # LiveForm: errors only for the fields touched, all of them on submit
    lt = live_test(LiveContact, "live_contact.html")
    live_event!(lt, "validate", Dict("name" => "toolongname", "email" => "", "_target" => "name"))
    @test occursin("at most 5 characters", lt.html) && !occursin("This field is required", lt.html)
    live_event!(lt, "save", Dict("name" => "ann", "email" => ""))
    @test occursin("This field is required", lt.html) && !occursin("SENT", lt.html)
    live_event!(lt, "save", Dict("name" => "ann", "email" => "a@b.co"))
    @test occursin("SENT", lt.html) && lt.view.form.form.cleaned_data[:name] == "ann"
    close(lt)

    # pub-sub across processes through PostgreSQL's LISTEN/NOTIFY
    if IS_POSTGRES
        write(joinpath(TPL, "live_counter.html"), "{% liveview %}<p>{{ count }}</p><ul>{% for m in log %}<li>{{ m }}</li>{% endfor %}</ul>{% endliveview %}")
        override_settings(LIVE_PUBSUB = :postgres) do
            lt = live_test(LiveCounter, "live_counter.html"; params = Dict("start" => "1", "room" => "pg"))
            try
                @test publish("room:pg", "via postgres") === nothing
                t0 = time()
                while !isready(getfield(lt, :session).inbox) && time() - t0 < 10
                    sleep(0.05)
                end
                @test occursin("<li>via postgres</li>", live_flush!(lt))
            finally
                close(lt)
            end
        end
        @test Juango.LIVE_LISTENER[] === nothing                                  # stopped with the setting
        rm(joinpath(TPL, "live_counter.html"); force = true)
    end
    configure!(ROOT_URLCONF = old_urls)
    rm(joinpath(TPL, "live_keep.html"); force = true); rm(joinpath(TPL, "live_contact.html"); force = true)
end

@testset "ModelForm: replaced m2m fields saved, extra fields, template widgets, option attributes; get_page (#129-#131)" begin
    # #129: a many-to-many replaced through field_classes is still saved
    t1 = create(Topic; name = "mf-a"); t2 = create(Topic; name = "mf-b"); t3 = create(Topic; name = "mf-c")
    F = ModelForm(Essay; fields = [:title, :topics], data = QueryDict("title=mf&topics=$(t1.id)&topics=$(t2.id)"),
                  field_classes = Dict(:topics => ModelMultipleChoiceField(filter(Topic; name__startswith = "mf-"); widget = Widget(:checkboxes))))
    @test is_valid(F)
    e = save!(F)
    @test Set(t.name for t in e.topics) == Set(["mf-a", "mf-b"])
    F2 = ModelForm(Essay; instance = e, fields = [:title, :topics], data = QueryDict("title=mf2&topics=$(t3.id)"),
                   field_classes = Dict(:topics => ModelMultipleChoiceField(filter(Topic; name__startswith = "mf-"))))
    obj = save!(F2; commit = false); save!(obj); save_m2m!(F2)
    @test [t.name for t in e.topics] == ["mf-c"]

    # #130: extra fields, placed where `fields` lists them, cleaned and not saved
    F3 = ModelForm(Essay; fields = [:title, :scope, :topics], data = QueryDict("title=x&scope=all"),
                   extra_fields = [:scope => TypedChoiceField(["all" => "All", "some" => "Some"])])
    @test [f.name for f in F3.fields] == [:title, :scope, :topics]
    @test is_valid(F3) && F3.cleaned_data[:scope] == "all" && save!(F3).title == "x"
    # per-option attributes, and a widget drawn by a template of its own
    write(joinpath(TPL, "tick_table.html"), "<table data-n=\"{{ n }}\">{% for o in widget.options %}<tr><td><input type=\"checkbox\" name=\"{{ widget.name }}\" value=\"{{ o.value }}\"{% if o.selected %} checked{% endif %} data-m=\"{{ o.attrs.marker }}\"></td><td>{{ o.label }}</td></tr>{% endfor %}</table>")
    try
        G = Form([:call => CharField(max_length = 2, choices = ["a" => "A", "b" => "B"], widget = Widget(nothing; option_attrs = (v, l) -> Dict("data-marker" => "m" * v))),
                  :ticks => MultipleChoiceField(["x" => "Ex", "y" => "Why"]; widget = Widget(:checkboxes; template_name = "tick_table.html",
                                                                                           context = bf -> Dict("n" => 2), option_attrs = (v, l) -> Dict("marker" => uppercase(v))))];
                 data = QueryDict("ticks=y"))
        @test occursin("<option value=\"a\" data-marker=\"ma\">A</option>", tr("{{ f.call }}", Dict("f" => G)))
        html = tr("{{ f.ticks }}", Dict("f" => G))
        @test occursin("<table data-n=\"2\">", html) && occursin("value=\"y\" checked data-m=\"Y\"", html) && occursin("<td>Ex</td>", html)
        @test occursin("<table", as_p(G).s)                                     # used wherever the field is rendered
    finally
        rm(joinpath(TPL, "tick_table.html"); force = true)
    end

    # #131: get_page clamps
    p = Paginator(collect(1:25), 10)
    @test get_page(p, "2").number == 2 && get_page(p, "99").number == 3 && get_page(p, "x").number == 1
    @test get_page(p, 0).number == 3 && get_page(p, "last").number == 3 && get_page(Paginator(Int[], 10), 5).number == 1
    @test_throws EmptyPage page(p, 99)
end

@testset "FileResponse from a stored file or an IO; content_disposition (#133)" begin
    body(r) = String(copy(Juango.consume_stream!(r).body))
    ms = Juango.InMemoryStorage()
    name = Juango.save_file(ms, "reports/r.csv", Vector{UInt8}(codeunits("a,b\n1,2\n")))
    r = FileResponse(Juango.FieldFile(name, ms); as_attachment = true, filename = "report.csv")
    @test getheader(r, "Content-Disposition") == "attachment; filename=\"report.csv\"" && getheader(r, "Content-Length") == "8"
    @test startswith(getheader(r, "Content-Type"), "text/csv") && body(r) == "a,b\n1,2\n"
    @test_throws Juango.Http404 FileResponse(Juango.FieldFile("missing.txt", ms))
    dir = mktempdir(); write(joinpath(dir, "d.txt"), "on disk")
    fs = FileSystemStorage(location = dir)
    r2 = FileResponse(Juango.FieldFile("d.txt", fs))
    @test body(r2) == "on disk" && getheader(r2, "Content-Disposition") == "inline; filename=\"d.txt\""
    io = IOBuffer("streamed"); r3 = FileResponse(io; filename = "s.bin", as_attachment = true)
    @test body(r3) == "streamed" && getheader(r3, "Content-Length") == "8" && !isopen(io)
    @test content_disposition("Résumé.pdf"; attachment = true) == "attachment; filename*=utf-8''R%C3%A9sum%C3%A9.pdf"
end

@testset "FilterSet (#137)" begin
    a1 = create(Author; name = "FS Ann", email = "ann@x"); a2 = create(Author; name = "FS Bob", email = "bob@x")
    t0 = DateTime(2025, 3, 1, 12)
    arts = [create(Article; title = "fs alpha", author = a1, status = "p", views = 5, published = true),
            create(Article; title = "fs beta", author = a1, status = "d", views = 50, published = false, rating = 4.0),
            create(Article; title = "fs gamma", author = a2, status = "p", views = 500, published = true)]
    for (i, a) in enumerate(arts)                                      # created on 1, 2 and 3 March
        update!(filter(Article; id = a.id); created = t0 + Day(i - 1))
    end
    base = filter(Article; title__startswith = "fs ")
    PF(data; req = nothing) = FilterSet(Article, [
            :title => CharFilter(lookup = "icontains"),
            :status => ChoiceFilter(),
            :author => ModelChoiceFilter(r -> filter(Author; name__startswith = "FS")),
            :published => BooleanFilter(),
            :views__gte => NumberFilter(field_name = :views, lookup = "gte"),
            :created => DateFromToRangeFilter(),
            :unrated => IsNullFilter(field_name = :rating),
            :q => CharFilter(method = (qs, name, v) -> filter(qs, Q(title__icontains = v) | Q(author__name__icontains = v))),
            :o => OrderingFilter([:views, :title, "author__name" => "author"]; field_labels = Dict("author" => "Writer")),
        ]; data = data === nothing ? nothing : QueryDict(data), queryset = base, request = req)
    titles(fs) = [a.title for a in order_by(fs.qs, "title")]
    @test titles(PF(nothing)) == ["fs alpha", "fs beta", "fs gamma"] && !PF(nothing).is_bound
    @test titles(PF("title=ALP")) == ["fs alpha"]
    @test titles(PF("status=p")) == ["fs alpha", "fs gamma"]
    @test titles(PF("author=$(a2.id)")) == ["fs gamma"]
    @test titles(PF("published=false")) == ["fs beta"] && titles(PF("published=")) == ["fs alpha", "fs beta", "fs gamma"]
    @test titles(PF("views__gte=50")) == ["fs beta", "fs gamma"]
    @test titles(PF("created_after=2025-03-02")) == ["fs beta", "fs gamma"]
    @test titles(PF("created_before=2025-03-02")) == ["fs alpha", "fs beta"]           # the whole last day
    @test titles(PF("unrated=true")) == ["fs alpha", "fs gamma"]
    @test titles(PF("q=bob")) == ["fs gamma"]
    @test titles(PF("status=p&published=true&views__gte=100")) == ["fs gamma"]
    # an invalid value leaves its filter out and shows the error; the others still apply
    f = PF("views__gte=lots&status=p")
    @test titles(f) == ["fs alpha", "fs gamma"] && haskey(f.form.errors, :views__gte)
    @test titles(PF("status=nonsense")) == ["fs alpha", "fs beta", "fs gamma"]
    @test titles(PF("author=999999")) == ["fs alpha", "fs beta", "fs gamma"]
    # ordering, one or several fields, unknown ones ignored
    @test [a.title for a in PF("o=-views").qs] == ["fs gamma", "fs beta", "fs alpha"]
    @test [a.title for a in PF("o=author,-views").qs] == ["fs beta", "fs alpha", "fs gamma"] && isempty(PF("o=author,-views").form.errors)
    @test length(collect(PF("o=password").qs)) == 3
    # chainable, and with get_page
    @test count(filter(PF("status=p").qs; views__lt = 100)) == 1
    @test get_page(Paginator(PF("status=p").qs, 1), "9").number == 2
    # the form renders field by field
    html = tr("{{ f.form.status }}|{{ f.form.created_after }}|{{ f.form.o }}", Dict("f" => PF("status=p")))
    @test occursin("<option value=\"p\" selected>", html) && occursin("name=\"created_after\"", html) && occursin(">Writer (descending)<", html)
    # generated from model fields
    g = FilterSet(Article; fields = Dict(:status => ["exact"], :views => ["gte", "lte"], :author => ["exact"], :title => ["icontains"]),
                  data = QueryDict("views__gte=10&views__lte=100&title__icontains=fs"), queryset = base)
    @test [a.title for a in g.qs] == ["fs beta"] && Set(first.(g.filters)) == Set([:status, :views__gte, :views__lte, :author, :title__icontains])
    # many-to-many
    tA = create(Topic; name = "fs-t1"); tB = create(Topic; name = "fs-t2")
    e1 = create(Essay; title = "fs-e1"); e2 = create(Essay; title = "fs-e2")
    add!(e1.topics, tA, tB); add!(e2.topics, tB)
    m = FilterSet(Essay, [:topics => ModelMultipleChoiceFilter(filter(Topic; name__startswith = "fs-"))];
                  data = QueryDict("topics=$(tA.id)&topics=$(tB.id)"), queryset = filter(Essay; title__startswith = "fs-"))
    @test sort([e.title for e in m.qs]) == ["fs-e1", "fs-e2"]                                   # distinct: e1 once
end

@testset "security fixes after the review of #101-#137" begin
    # literals: quotes doubled (MySQL connections set NO_BACKSLASH_ESCAPES, so backslashes are plain there)
    @test Juango.sql_string_literal(Juango.SQLiteBackend(":memory:"), "a'b\\c") == "'a''b\\c'"
    # and on the database under test, hostile JSON keys are only ever keys
    g = create(Gadget; nick = "sec", data = Dict("run" => 1))
    for k in ("x' OR 1=1 -- ", "x\\' OR 1=1 -- ", "x\") OR 1=1 -- ", "a\\\\", "{a,b}")
        @test values_list(filter(Gadget; id = g.id), Symbol("data__" * k); flat = true) == [nothing]
        @test length(collect(order_by(filter(Gadget; id = g.id), "data__" * k))) == 1
    end
    # the test database is never the real one
    @test Juango.test_database_setting("postgresql://h/test_lab") == "postgresql://h/test_test_lab"
    if IS_POSTGRES || IS_MYSQL
        override_settings(TEST_DATABASE = settings.DATABASE) do
            @test_throws Juango.ImproperlyConfigured setup_test_database()
        end
    end
    # snapshots belong to one user and session
    req1 = Request("GET", "/keep/"); req2 = Request("GET", "/keep/")
    req1.user = create_user("snap-a", "snap-Pass-1"); req2.user = create_user("snap-b", "snap-Pass-2")
    s1 = Juango.LiveSession(LiveKeep(count = 5), req1, "live_keep.html")
    tok = Juango.live_snapshot_token(s1)
    s2 = Juango.LiveSession(LiveKeep(), req2, "live_keep.html")
    @test !Juango.live_restore!(s2, tok) && s2.view.count == 0
    s3 = Juango.LiveSession(LiveKeep(), req1, "live_keep.html")
    @test Juango.live_restore!(s3, tok) && s3.view.count == 5
    # uploads are released once their event has been handled
    s4 = Juango.LiveSession(LiveKeep(), Request("GET", "/keep/"), "live_keep.html")
    override_settings(FILE_UPLOAD_MAX_MEMORY_SIZE = 10) do
        Juango.live_upload_chunk!(s4, Dict("ref" => "r", "name" => "big.txt", "chunk" => Juango.base64encode("y" ^ 50), "last" => true))
    end
    path = s4.uploads["r"]["path"]
    @test isfile(path)
    params = Dict{String,Any}("file" => Dict("__upload__" => "r"))
    used = Juango.live_attach_uploads!(s4, params)
    @test params["file"] isa UploadedFile && read(params["file"], String) == "y" ^ 50
    Juango.live_release_uploads!(s4, used)
    @test isempty(s4.uploads) && !isfile(path)
end

@testset "debug toolbar" begin
    old_mw, old_urls = settings.MIDDLEWARE, settings.ROOT_URLCONF
    a1 = create(Author; name = "DT Ann", email = "dtann@x"); a2 = create(Author; name = "DT Bob", email = "dtbob@x")
    create(Article; title = "dt one", author = a1); create(Article; title = "dt two", author = a2)
    write(joinpath(TPL, "dt_page.html"), "<html><body>{% for a in arts %}{{ a.author.name }};{% endfor %}{% include \"dt_part.html\" with n=3 %}</body></html>")
    write(joinpath(TPL, "dt_part.html"), "[{{ n }}]")
    function dt_page(req)
        arts = collect(order_by(filter(Article; title__startswith = "dt "), "title"))    # 1 query, then one per author: an N+1
        render(req, "dt_page.html", Dict("arts" => arts, "label" => "<x>", "qs" => filter(Article; id = 0)))
    end
    dt_json(req) = JsonResponse(Dict("n" => count(filter(Author; name__startswith = "DT"))))
    try
        configure!(MIDDLEWARE = vcat(Any[DebugToolbarMiddleware], old_mw), INTERNAL_IPS = ["127.0.0.1"],
                   ROOT_URLCONF = vcat(old_urls, [path("dt/", dt_page; name = "dt-page"), path("dt.json", dt_json)]))
        c = Client()
        r = get(c, "/dt/")
        body = text(r)
        @test r.status == 200 && occursin("DT Ann;DT Bob;[3]", body)
        @test occursin("<div id=\"jdt\"", body) && endswith(body, "</body></html>")
        @test occursin("3 queries", body)                          # the articles, then each author
        @test occursin("2 similar queries", body)                  # the N+1 is flagged
        @test occursin("dt_page.html", body) && occursin("dt_part.html", body) && occursin("include", body)
        @test occursin("&lt;QuerySet{Article}&gt;", body)          # a queryset in the context is described, not run
        @test occursin("&quot;&lt;x&gt;&quot;", body)              # context values are escaped
        @test occursin("from dt_page", body)                       # where each query came from: the view,
        @test occursin("in template <code>dt_page.html</code>", body)   # and for the N+1, the template that ran it
        @test !occursin("SessionMiddleware", body)                 # but not the request plumbing
        @test occursin("dt-page", body)                            # URL name
        link = getheader(r, "X-Juango-Debug")
        @test link !== nothing && startswith(link, "/__debug__/")

        r2 = get(c, "/dt.json")                                    # not HTML: left alone, but recorded
        @test !occursin("jdt", text(r2)) && text(r2) == "{\"n\":2}"
        hist = text(get(c, "/__debug__/"))
        @test occursin("/dt.json", hist) && occursin("/dt/", hist)
        page = get(c, getheader(r2, "X-Juango-Debug"))
        @test page.status == 200 && occursin("SQL (1)", text(page)) && occursin("Juango debug", text(page))
        @test get(c, "/__debug__/nope/").status == 404

        # duplicated queries
        configure!(ROOT_URLCONF = vcat(old_urls, [path("dup/", req -> (get(Author; id = a1.id); get(Author; id = a1.id); HttpResponse("<body>ok</body>")))]))
        @test occursin("duplicated ×2", text(get(c, "/dup/")))

        # not an internal address, or DEBUG off: nothing recorded or shown
        configure!(INTERNAL_IPS = String[])
        r3 = get(c, "/dt/")
        @test !occursin("jdt", text(r3)) && getheader(r3, "X-Juango-Debug") === nothing
        @test get(c, "/__debug__/").status == 404
        configure!(DEBUG_TOOLBAR_SHOW = req -> true, DEBUG_TOOLBAR_STACKTRACES = false, DEBUG_TOOLBAR_HISTORY = 1)
        @test occursin("jdt", text(get(c, "/dt/")))
        @test length(Juango.DEBUG_HISTORY) == 1
        @test Juango.current_debug_record() === nothing           # nothing left recording on this task
    finally
        configure!(MIDDLEWARE = old_mw, ROOT_URLCONF = old_urls, INTERNAL_IPS = String[], DEBUG_TOOLBAR_SHOW = nothing,
                   DEBUG_TOOLBAR_STACKTRACES = true, DEBUG_TOOLBAR_HISTORY = 25)
        rm(joinpath(TPL, "dt_page.html"); force = true); rm(joinpath(TPL, "dt_part.html"); force = true)
    end
end

@testset "messages keep their safeness (#152)" begin
    old_urls = settings.ROOT_URLCONF
    tpl_path = joinpath(TPL, "msg152.html")
    write(tpl_path, "<ul>{% for m in messages %}<li class=\"{{ m.tags }}\">{{ m }}</li>{% endfor %}</ul>")
    function add152(req)
        message!(req, :success, format_html("Recorded: <a href=\"{}\">{}</a>.", "/events/12/", "Extract <12>"))
        message!(req, :info, "plain <b>text</b>")
        message!(req, :warning, mark_safe("<button>Undo</button>"))
        HttpResponse("ok")
    end
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("m152/add/", add152), path("m152/", req -> render(req, "msg152.html"))]))
        for engine in (:db, :signed_cookies)
            configure!(SESSION_ENGINE = engine)
            c = Client()
            get(c, "/m152/add/")
            body = text(get(c, "/m152/"))
            @test occursin("<li class=\"success\">Recorded: <a href=\"/events/12/\">Extract &lt;12&gt;</a>.</li>", body)
            @test occursin("<li class=\"info\">plain &lt;b&gt;text&lt;/b&gt;</li>", body)        # plain text is still escaped
            @test occursin("<li class=\"warning\"><button>Undo</button></li>", body)
        end
        @test Juango.Message(:info, mark_safe("<i>x</i>")).safe && !Juango.Message(:info, "<i>x</i>").safe
    finally
        configure!(ROOT_URLCONF = old_urls, SESSION_ENGINE = Juango.default_settings()[:SESSION_ENGINE])
        rm(tpl_path; force = true)
    end
end

struct Exploder140 end
Juango.tattr(::Exploder140, ::Val{:explode}) = error("exploded in a template")

@testset "DEBUG error page (#140)" begin
    old_urls = settings.ROOT_URLCONF
    tpl_path = joinpath(TPL, "dp140.html")
    write(tpl_path, "<p>one</p>\n<p>two</p>\n<p>{{ thing.explode }}</p>\n<p>four</p>")
    dp_view(req) = error("dp140 failure <b>")                         # this file's frame must show, with its source
    function dp_chain(req)
        try
            parse(Int, "not a number")
        catch
            error("while handling the parse error")
        end
    end
    dp_tpl(req) = render(req, "dp140.html", Dict("thing" => Exploder140()))
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("dp/view/", dp_view; name = "dp-view"), path("dp/chain/", dp_chain),
                                                  path("dp/tpl/", dp_tpl)]),
                   SECRET_KEY = "s3cret-value-not-shown", DATABASE_PASSWORD_FOR_TEST = "pw-not-shown",
                   EMAIL_HOST = "smtp://user:hunter2@mail.example")
        c = Client()
        c.cookies["theme"] = "dark"; c.cookies["csrftoken"] = "zq" ^ 16
        r = @test_logs (:error,) match_mode = :any get(c, "/dp/view/?q=1")
        body = text(r)
        @test r.status == 500 && occursin("<title>ErrorException at /dp/view/</title>", body)
        @test occursin("dp140 failure &lt;b&gt;", body) && !occursin("dp140 failure <b>", body)     # escaped
        @test occursin("<code>dp_view(req::Request)</code>", body)        # frames with their signatures
        @test occursin("<li class=\"user\"><details open>", body)          # your frame open
        @test occursin("dp_view(req) = error(&quot;dp140 failure &lt;b&gt;&quot;)", body)   # with its source line
        @test occursin("library frame", body)                              # Base's folded away
        @test occursin("dp-view", body) && occursin("<th>q</th>", body)    # request: URL name, GET
        masked = "<td><code>&quot;********************&quot;</code></td>"
        @test occursin("<th>theme</th><td><code>dark</code>", body)
        @test occursin("<th>csrftoken</th><td><code>********************</code>", body)          # the CSRF cookie masked
        @test occursin("<th>SECRET_KEY</th>" * masked, body) && occursin("<th>DATABASE_PASSWORD_FOR_TEST</th>" * masked, body)
        @test occursin("<th>EMAIL_HOST</th><td><code>&quot;smtp://user:********@mail.example&quot;", body)
        @test occursin("Copy-and-paste view", body) && occursin("Traceback (innermost first):", body)

        r = @test_logs (:error,) match_mode = :any get(c, "/dp/chain/")
        @test occursin("While handling the exception above", text(r)) && occursin("ArgumentError", text(r)) &&
              occursin("while handling the parse error", text(r))

        r = override_settings(TEMPLATE_COMPILE = false) do      # interpreted, as with DEBUG (compiled templates know the template, not the line)
            @test_logs (:error,) match_mode = :any get(c, "/dp/tpl/")
        end
        body = text(r)
        @test occursin("Error during template rendering", body) && occursin("error at line 3", body)
        @test occursin("<tr class=\"hl\"><td class=\"ln\">3</td><td><code>&lt;p&gt;{{ thing.explode }}&lt;/p&gt;</code>", body)
        # the next error, without a template, doesn't reuse that note
        r = @test_logs (:error,) match_mode = :any get(c, "/dp/view/")
        @test !occursin("<h2>Error during template rendering</h2>", text(r))

        # DEBUG off: the report goes to ADMINS as text
        empty!(outbox)
        old_backend = settings.EMAIL_BACKEND
        configure!(DEBUG = false, ADMINS = Any[("Ops", "ops@example.com")], EMAIL_BACKEND = :locmem)
        try
            @test_logs (:error,) match_mode = :any get(c, "/dp/view/")
        finally
            configure!(DEBUG = true, ADMINS = Any[], EMAIL_BACKEND = old_backend)
        end
        b = only(outbox).body
        @test occursin("Traceback (innermost first):", b) && occursin("\n  dp_view(req::Request)\n", b) && occursin("Request URL:", b)
        @test occursin("\n  SessionMiddleware(req::Request)\n", b) && !occursin("{Juango.var", b)    # closures by name
    finally
        configure!(ROOT_URLCONF = old_urls, SECRET_KEY = Juango.default_settings()[:SECRET_KEY],
                   EMAIL_HOST = Juango.default_settings()[:EMAIL_HOST])
        delete!(Juango.SETTINGS, :DATABASE_PASSWORD_FOR_TEST)
        rm(tpl_path; force = true)
    end
end

@testset "HTTP odds: responses, signed cookies, decorators, CSRF settings, app_name (#148)" begin
    # responses
    @test HttpResponseGone().status == 410 && HttpResponseServerError().status == 500
    nm = HttpResponseNotModified()
    @test nm.status == 304 && getheader(nm, "Content-Type") === nothing && isempty(nm.body)

    # signed cookies
    resp = set_signed_cookie!(HttpResponse(""), "pref", "dark; théme"; salt = "ui", max_age = 60)
    raw = split(split(only(resp.cookies), ';')[1], '='; limit = 2)[2]
    req = Request("GET", "/"; headers = Dict("Cookie" => "pref=$raw"))
    @test get_signed_cookie(req, "pref"; salt = "ui") == "dark; théme"
    @test_throws Juango.BadSignature get_signed_cookie(req, "pref")                  # another salt
    @test get_signed_cookie(req, "pref"; default = "none") == "none"
    @test_throws KeyError get_signed_cookie(req, "missing")
    @test get_signed_cookie(req, "missing"; default = nothing) === nothing
    tampered = Request("GET", "/"; headers = Dict("Cookie" => "pref=" * (raw[1] == 'A' ? "B" : "A") * raw[2:end]))
    @test get_signed_cookie(tampered, "pref"; salt = "ui", default = "bad") == "bad"

    old_urls, old_mw = settings.ROOT_URLCONF, settings.MIDDLEWARE
    blog = [path("", req -> HttpResponse(reverse_url("blog:index") * "|" * reverse_url("blog:index"; current_app = "blog")); name = "index")]
    plain(req) = HttpResponse("<p>ok</p>")
    js_form = ensure_csrf_cookie(plain)
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [
            path("h148/plain/", plain), path("h148/js/", js_form),
            path("h148/exempt/", xframe_options_exempt(plain)), path("h148/same/", xframe_options_sameorigin(plain)),
            path("h148/safe/", require_safe(plain)), path("h148/gz/", gzip_page(req -> HttpResponse("z" ^ 500))),
            path("h148/noslash/", no_append_slash(req -> HttpResponse("n"))), path("h148/slash/", req -> HttpResponse("s")),   # (it marks the function)
            path("h148/protected/", csrf_protect(req -> HttpResponse("posted"))),
            path("h148/secret/", sensitive_post_parameters(req -> error("boom148"), "card")),
            path("b148/", include_urls(blog; app_name = "blog")),
            path("n148/", include_urls(blog; app_name = "blog", namespace = "news"))]))
        c = Client()
        @test !any(startswith("csrftoken="), get(c, "/h148/plain/").cookies)
        r = get(c, "/h148/js/")
        @test any(startswith("csrftoken="), r.cookies)                                  # ensure_csrf_cookie
        @test getheader(get(c, "/h148/plain/"), "X-Frame-Options") == "DENY"
        @test getheader(get(c, "/h148/exempt/"), "X-Frame-Options") === nothing
        @test getheader(get(c, "/h148/same/"), "X-Frame-Options") == "SAMEORIGIN"
        @test get(c, "/h148/safe/").status == 200 && post(c, "/h148/safe/").status == 405
        @test getheader(get(c, "/h148/gz/"; headers = Dict("Accept-Encoding" => "gzip")), "Content-Encoding") == "gzip"
        @test get(c, "/h148/slash").status == 301 && get(c, "/h148/noslash").status == 404     # no_append_slash
        # application namespaces: each instance reverses to itself; elsewhere "blog:" is the default instance
        @test text(get(c, "/b148/")) == "/b148/|/b148/" && text(get(c, "/n148/")) == "/n148/|/b148/"
        @test reverse_url("blog:index") == "/b148/" && reverse_url("news:index") == "/n148/"
        @test reverse_url("blog:index"; current_app = "news") == "/n148/"
        @test Juango.resolve("/n148/").app_name == "blog" && Juango.resolve("/n148/").namespace == "news"

        # csrf_protect without the middleware
        configure!(MIDDLEWARE = filter(m -> m !== Juango.CsrfViewMiddleware, old_mw))
        strict = Client(; enforce_csrf = true)
        @test post(strict, "/h148/protected/").status == 403
        @test post(strict, "/h148/plain/").status == 200                                 # no middleware, no check
        configure!(MIDDLEWARE = old_mw)

        # CSRF settings: header name, cookie attributes, failure view, the secret in the session
        configure!(CSRF_HEADER_NAME = "HTTP_X_MY_TOKEN", CSRF_COOKIE_HTTPONLY = true, CSRF_COOKIE_SAMESITE = "Strict",
                   CSRF_FAILURE_VIEW = (req; reason) -> HttpResponseForbidden("custom: " * reason))
        strict = Client(; enforce_csrf = true)
        ck = only(filter(startswith("csrftoken="), get(strict, "/h148/js/").cookies))
        @test occursin("HttpOnly", ck) && occursin("SameSite=Strict", ck)
        tok = strict.cookies["csrftoken"]
        @test post(strict, "/h148/plain/"; headers = Dict("X-My-Token" => tok)).status == 200
        r = post(strict, "/h148/plain/"; headers = Dict("X-CSRFToken" => tok))           # the default header no longer
        @test r.status == 403 && startswith(text(r), "custom: CSRF token missing")
        configure!(CSRF_USE_SESSIONS = true, CSRF_HEADER_NAME = "X-CSRFToken")
        s = Client(; enforce_csrf = true)
        r = get(s, "/h148/js/")
        @test !any(startswith("csrftoken="), r.cookies) && haskey(s.cookies, "sessionid")    # no CSRF cookie: it's in the session
        sess = Juango.lazy_session(s.cookies["sessionid"])
        tok = get(sess, "_csrftoken", nothing)
        @test tok isa String && post(s, "/h148/plain/"; headers = Dict("X-CSRFToken" => tok)).status == 200
        @test post(s, "/h148/plain/"; headers = Dict("X-CSRFToken" => "x" ^ 32)).status == 403

        # sensitive_post_parameters masks those fields on the error page
        configure!(CSRF_USE_SESSIONS = false, CSRF_FAILURE_VIEW = nothing)
        r = @test_logs (:error,) match_mode = :any post(Client(), "/h148/secret/"; data = Dict("card" => "4111-1111", "name" => "Ann"))
        @test occursin("<th>card</th><td><code>********************", text(r)) && occursin("<th>name</th><td><code>Ann", text(r))
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw, CSRF_HEADER_NAME = "X-CSRFToken", CSRF_COOKIE_HTTPONLY = false,
                   CSRF_COOKIE_SAMESITE = "Lax", CSRF_FAILURE_VIEW = nothing, CSRF_USE_SESSIONS = false)
    end
end

@testset "messages: levels, tags, cookie and fallback storage (#149)" begin
    old_urls, old_mw = settings.ROOT_URLCONF, settings.MIDDLEWARE
    tpl = joinpath(TPL, "msg149.html")
    write(tpl, "{% for m in messages %}[{{ m.tags }}|{{ m.level }}|{{ m }}]{% endfor %}")
    n_big = Ref(0)
    function add149(req)
        Juango.Messages.success!(req, "saved")
        message!(req, :debug, "hidden")                               # below MESSAGE_LEVEL
        message!(req, 35, "custom level"; extra_tags = "sticky")
        message!(req, :error, "bad")
        for i in 1:n_big[]
            message!(req, :info, "long message number $i " * "x" ^ 60)
        end
        HttpResponse("ok")
    end
    peek149(req) = HttpResponse(string(length(peek_messages(req))) * "/" * string(length(peek_messages(req))))
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("m149/add/", add149), path("m149/", req -> render(req, "msg149.html")),
                                                  path("m149/peek/", peek149)]),
                   MESSAGE_TAGS = Dict(35 => "notice", 40 => "danger"))
        c = Client()
        get(c, "/m149/add/")
        @test text(get(c, "/m149/peek/")) == "3/3"                     # peeking doesn't consume
        @test text(get(c, "/m149/")) == "[success|25|saved][sticky notice|35|custom level][danger|40|bad]"
        @test text(get(c, "/m149/")) == ""
        configure!(MESSAGE_LEVEL = 10)
        get(c, "/m149/add/")
        @test occursin("[debug|10|hidden]", text(get(c, "/m149/")))
        configure!(MESSAGE_LEVEL = 20)
        @test_throws ArgumentError message!(Request("GET", "/"), :loud, "x")
        @test message!(Request("GET", "/"), :info, "x"; fail_silently = true) === nothing     # no session: dropped
        @test_throws MessageFailure message!(Request("GET", "/"), :info, "x")

        # cookie storage: no session involved
        configure!(MESSAGE_STORAGE = :cookie, MIDDLEWARE = vcat(old_mw, Any[MessageMiddleware]))
        @test isempty(Juango.run_checks(tags = [:messages]))
        c = Client()
        get(c, "/m149/add/")
        @test haskey(c.cookies, "messages") && !haskey(c.cookies, "sessionid")
        @test text(get(c, "/m149/peek/")) == "3/3" && haskey(c.cookies, "messages")
        @test text(get(c, "/m149/")) == "[success|25|saved][sticky notice|35|custom level][danger|40|bad]"
        @test !haskey(c.cookies, "messages") && text(get(c, "/m149/")) == ""
        c.cookies["messages"] = "forged"                               # a bad signature is ignored
        @test text(get(c, "/m149/")) == ""

        # fallback: what doesn't fit in the cookie goes to the session
        configure!(MESSAGE_STORAGE = :fallback)
        n_big[] = 40
        c = Client()
        get(c, "/m149/add/")
        @test haskey(c.cookies, "messages") && haskey(c.cookies, "sessionid")
        body = text(get(c, "/m149/"))
        @test count("long message number", body) == 40 && occursin("[success|25|saved]", body)
        @test occursin("number 40 ", body) && text(get(c, "/m149/")) == ""
        n_big[] = 0

        configure!(MIDDLEWARE = old_mw)
        @test only(Juango.run_checks(tags = [:messages])).id == "messages.E001"
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw, MESSAGE_STORAGE = :session, MESSAGE_LEVEL = 20,
                   MESSAGE_TAGS = Dict{Int,String}())
        rm(tpl; force = true)
    end
end

@testset "testing assertions and test runner options (#150)" begin
    T = Juango.Testing
    # HTML compared as Django does
    @test T.assert_html_equal("<p class=\"b a\" id=x>Hi  <b>there</b></p>", "<p id='x' class='a b'>\n  Hi <b>there</b>\n</p>")
    @test T.assert_html_equal("<br><input disabled type=text>", "<br/><input type=\"text\" disabled />")
    @test T.assert_html_equal("<p>&amp; &lt;x&gt;</p>", "<p>&#38; &#x3C;x&gt;</p>") && T.assert_html_not_equal("<p>a</p>", "<p>b</p>")
    @test_throws AssertionError T.assert_html_equal("<p>a</p>", "<div>a</div>")
    page = "<ul><li class='x'>one</li><li>two</li><li class=\"x\">one</li></ul><!-- one -->"
    @test T.assert_in_html("<li class=\"x\">one</li>", page; count = 2) && T.assert_in_html("two", page)
    @test_throws AssertionError T.assert_in_html("<li>three</li>", page)
    r = HttpResponse("<div>\n  <a href='/x'  title=t>link</a>\n</div>")
    @test assert_contains(r, "<a title=\"t\" href=\"/x\">link</a>"; html = true)
    @test assert_not_contains(r, "<a href=\"/y\">link</a>"; html = true)
    # JSON
    @test T.assert_json_equal("{\"a\": 1, \"b\": [1, 2.0]}", Dict("b" => [1, 2], "a" => 1))
    @test T.assert_json_equal(JsonResponse(Dict("x" => nothing)), "{\"x\": null}") && T.assert_json_not_equal("[1]", "[2]")
    # querysets
    au = create(Author; name = "Q150", email = "q150@x")
    rollback_after() do
        a1 = create(Article; title = "q150 a", author = au); a2 = create(Article; title = "q150 b", author = au)
        qs = filter(Article; title__startswith = "q150")
        @test T.assert_queryset_equal(order_by(qs, "title"), ["q150 a", "q150 b"]; transform = a -> a.title)
        @test T.assert_queryset_equal(order_by(qs, "-title"), [a2, a1])
        @test T.assert_queryset_equal(filter(Bulletin; slug = "none"), []; ordered = false)
        @test_throws AssertionError T.assert_queryset_equal(order_by(qs, "title"), ["q150 b", "q150 a"]; transform = a -> a.title)
        @test T.assert_queryset_equal(order_by(qs, "title"), ["q150 b", "q150 a"]; transform = a -> a.title, ordered = false)
    end
    # form fields
    @test T.assert_field_output(IntegerField(blank = true), Dict("3" => 3, " 7 " => 7), Dict("x" => ["Enter a whole number."]))
    @test_throws AssertionError T.assert_field_output(IntegerField(), Dict("x" => 1), Dict())
    # formsets
    FS = formset_factory((d; prefix, initial) -> Form([:qty => IntegerField()]; data = d, prefix = prefix, initial = initial);
                         extra = 0, min_num = 1, validate_min = true)
    fs = FS(Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-0-qty" => "x"))
    @test T.assert_formset_error(fs, 1, :qty, ["Enter a whole number."]) && T.assert_formset_error(fs, nothing, String[])

    # the runner: -k, --failfast, --reverse, --shuffle (in-memory SQLite only: it sets up its own test database)
    if !IS_MYSQL && !occursin("://", TEST_DB_SETTING)
        dir = mktempdir()
        mkpath(joinpath(dir, "tests"))
        write(joinpath(dir, "tests", "test_a.jl"), "push!(Main.RUN150, \"a\")")
        write(joinpath(dir, "tests", "test_b.jl"), "push!(Main.RUN150, \"b\"); error(\"b150 fails\")")    # (a failing @testset here would count in this one)
        write(joinpath(dir, "tests", "test_c.jl"), "push!(Main.RUN150, \"c\")")
        Core.eval(Main, :(const RUN150 = String[]))
        cd(dir) do
            redirect_stdio(stdout = devnull, stderr = devnull) do
                Juango.cmd_test(["-k", "test_a"])
                @test Main.RUN150 == ["a"]
                empty!(Main.RUN150)
                @test_throws ErrorException Juango.cmd_test(String[])              # b fails, c still runs
                @test Main.RUN150 == ["a", "b", "c"]
                empty!(Main.RUN150)
                @test_throws ErrorException Juango.cmd_test(["--failfast", "--reverse"])
                @test Main.RUN150 == ["c", "b"]
                empty!(Main.RUN150)
                Juango.cmd_test(["--shuffle=7", "-k", "test_a", "-k", "test_c"])
                o1 = copy(Main.RUN150); empty!(Main.RUN150)
                Juango.cmd_test(["--shuffle=7", "-k", "test_a", "-k", "test_c"])
                @test sort(o1) == ["a", "c"] && Main.RUN150 == o1                 # the same seed, the same order
                # #181: a throwaway MEDIA_ROOT for the run, removed afterwards
                empty!(Main.RUN150)
                write(joinpath(dir, "tests", "test_d.jl"), "push!(Main.RUN150, Juango.settings.MEDIA_ROOT)")
                before = settings.MEDIA_ROOT
                Juango.cmd_test(["-k", "test_d"])
                m = only(Main.RUN150)
                @test m != before && !isdir(m) && settings.MEDIA_ROOT == before
            end
        end
    end
    # #181: snapshot tests
    sd = mktempdir()
    redirect_stderr(devnull) do
        @test assert_matches_snapshot("report.csv", "a,b\n1,2\n"; dir = sd)              # first run: written
    end
    @test read(joinpath(sd, "report.csv"), String) == "a,b\n1,2\n" && assert_matches_snapshot("report.csv", "a,b\n1,2\n"; dir = sd)
    e = try assert_matches_snapshot("report.csv", "a,b\n1,3\n"; dir = sd); nothing catch err; err end
    @test e isa AssertionError && occursin("differs at line 2", e.msg) && occursin("\"1,3\"", e.msg)
    @test read(joinpath(sd, "report.csv.new"), String) == "a,b\n1,3\n"
    withenv("JUANGO_UPDATE_SNAPSHOTS" => "1") do
        redirect_stderr(devnull) do
            assert_matches_snapshot("report.csv", HttpResponse("a,b\n1,3\n"); dir = sd)      # approved
        end
    end
    @test read(joinpath(sd, "report.csv"), String) == "a,b\n1,3\n" && !isfile(joinpath(sd, "report.csv.new"))
    # #181: the coverage summary from an LCOV file
    lc = joinpath(sd, "lcov.info")
    write(lc, "SF:$(joinpath(sd, "src", "a.jl"))\nDA:1,3\nDA:2,0\nend_of_record\nSF:$(joinpath(sd, "test", "t.jl"))\nDA:1,1\nend_of_record\n")
    out = sprint(io -> Juango.print_coverage(lc; io = io, root = sd))
    @test occursin("src/a.jl", out) && occursin("50.0%   1/2 lines", out) && !occursin("t.jl", out) && occursin("TOTAL", out)
end

struct Finder151 <: Juango.StaticFinder end
Juango.find_static(::Finder151, path) = path == "virtual.txt" ? [Main.FINDER151_FILE[]] : String[]
Juango.list_static(::Finder151) = [("virtual.txt", Main.FINDER151_FILE[])]
const FINDER151_FILE = Ref("")

@testset "smaller gaps, part 2 (#151)" begin
    # templates: prefixes and fragment keys
    @test tr("{% get_static_prefix %}|{% get_media_prefix as m %}{{ m }}") == settings.STATIC_URL * "|" * settings.MEDIA_URL
    write(joinpath(TPL, "frag151.html"), "{% cache 60 \"side\" who %}[{{ n }}]{% endcache %}")
    try
        @test render_to_string("frag151.html", Dict("who" => 7, "n" => 1)) == "[1]"
        @test render_to_string("frag151.html", Dict("who" => 7, "n" => 2)) == "[1]"         # cached
        Juango.cache_delete(Juango.make_template_fragment_key("side", [7]))
        @test render_to_string("frag151.html", Dict("who" => 7, "n" => 3)) == "[3]"
    finally
        rm(joinpath(TPL, "frag151.html"); force = true)
    end
    # static files: a finder of our own
    FINDER151_FILE[] = tempname(); write(FINDER151_FILE[], "virtual!")
    override_settings(STATICFILES_FINDERS = Any[Juango.FileSystemFinder(), Juango.AppDirectoriesFinder(), Finder151()]) do
        @test Juango.findstatic("virtual.txt") == [FINDER151_FILE[]]
        @test text(get(Client(), settings.STATIC_URL * "virtual.txt")) == "virtual!"
        @test !isempty(Juango.findstatic("juango/htmx.min.js"))                          # the built-in finders too
        @test isempty(Juango.findstatic("../../etc/passwd"))
    end
    # mail: one connection for many messages, a backend per call
    old_backend = settings.EMAIL_BACKEND
    try
        configure!(EMAIL_BACKEND = :locmem); empty!(outbox)
        n = send_mass_mail([("s1", "b1", "a@x.io", ["p@x.io"]), ("s2", "b2", nothing, ["q@x.io", "r@x.io"]), ("s3", "b3", nothing, String[])])
        @test n == 2 && [m.subject for m in outbox] == ["s1", "s2"]
        conn = get_connection(:dummy)
        @test send!(EmailMessage("x", "y"; to = ["z@x.io"]); connection = conn) == 1 && length(outbox) == 2   # (dummy: not kept)
    finally
        configure!(EMAIL_BACKEND = old_backend)
    end
    # auth: the redirect parameter's name, inactive users, the admin's password form
    old_urls = settings.ROOT_URLCONF
    try
        configure!(ROOT_URLCONF = vcat(old_urls, [path("p151/", login_required(req -> HttpResponse("in"); redirect_field_name = "back")),
                                                   path("q151/", login_required(req -> HttpResponse("in"); redirect_field_name = nothing))]))
        r = get(Client(), "/p151/?x=1")
        @test r.status == 302 && occursin("?back=/p151/%3Fx%3D1", getheader(r, "Location"))
        @test !occursin("?", getheader(get(Client(), "/q151/"), "Location"))
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
    rollback_after() do
        u = create_user("inactive151", "pw-151-xyz"); u.is_active = false; save!(u)
        @test authenticate("inactive151", "pw-151-xyz") === nothing
        override_settings(AUTHENTICATION_BACKENDS = Any[AllowAllUsersModelBackend()]) do
            v = authenticate("inactive151", "pw-151-xyz")
            @test v !== nothing && v.username == "inactive151" && !has_perm(v, "project.change_article")
        end
        f = AdminPasswordChangeForm(Dict("password1" => "Correct-Horse-151", "password2" => "Correct-Horse-152"))
        @test !is_valid(f) && haskey(f.errors, :password2)
        f = AdminPasswordChangeForm(Dict("password1" => "Correct-Horse-151", "password2" => "Correct-Horse-151"))
        @test is_valid(f) && Juango.check_new_password!(f, u)
    end
    # i18n
    i = get_language_info("pt-BR")
    @test i.code == "pt-br" && i.name == "Brazilian Portuguese" && !i.bidi && get_language_info("de-at").name_local == "Deutsch"
    @test get_language_info("he").bidi && (try get_language_info("xx"); false catch e; e isa KeyError end)
    @test tr("{% get_language_info for \"fr\" as l %}{{ l.name_local }}|{{ l.bidi }}") == "français|False"
    @test tr("{% get_language_info_list for langs as ls %}{% for l in ls %}{{ l.code }},{% endfor %}", Dict("langs" => [("de", "German"), "nl"])) == "de,nl,"
    @test tr("{% load i18n %}{{ \"ar\"|language_name_local }}{{ \"ar\"|language_bidi }}") == "العربيّة" * "True"
    # date archives: weeks and today
    @test Juango.week_start(2026, 1, "%V") == Date(2025, 12, 29) && Juango.week_start(2026, 1, "%W") == Date(2026, 1, 5)
    @test Juango.week_start(2026, 1, "%U") == Date(2026, 1, 4) && Juango.week_start(2026, 0, "%U") == Date(2025, 12, 28)
    rollback_after() do
        au = create(Author; name = "WK151", email = "wk@x151.io")
        a = create(Article; title = "wk151", author = au)
        write(joinpath(TPL, "article_archive_week.html"), "{{ week }}:{% for o in object_list %}{{ o.title }}{% endfor %}")
        write(joinpath(TPL, "article_archive_day.html"), "{{ day }}:{% for o in object_list %}{{ o.title }}{% endfor %}")
        old = settings.ROOT_URLCONF
        try
            configure!(ROOT_URLCONF = vcat(old, [path("wk/<int:year>/<int:week>/", WeekArchiveView(Article; date_field = :created, week_format = "%V")),
                                                 path("today151/", TodayArchiveView(Article; date_field = :created, allow_empty = true,
                                                                                    queryset = filter(Article; title = "wk151")))]))
            d = Juango.localdate()
            y, w = Dates.year(d - Day(dayofweek(d) - 1) + Day(3)), Dates.week(d)
            @test occursin("wk151", text(get(Client(), "/wk/$y/$w/")))
            @test text(get(Client(), "/today151/")) == "$d:wk151"
        finally
            configure!(ROOT_URLCONF = old)
            rm(joinpath(TPL, "article_archive_week.html"); force = true); rm(joinpath(TPL, "article_archive_day.html"); force = true)
        end
    end
    # commands: sqlflush, sqlsequencereset, migrate --plan; PostgreSQL index types
    sql = Juango.flush_sql()
    @test !isempty(sql) && (IS_POSTGRES ? startswith(sql[1], "TRUNCATE") :
                            IS_MYSQL ? sql[1] == "SET FOREIGN_KEY_CHECKS = 0" && any(s -> startswith(s, "TRUNCATE TABLE"), sql) :
                            any(s -> startswith(s, "DELETE FROM"), sql))
    seqs = Juango.sequence_reset_sql(["project"])
    @test IS_POSTGRES ? any(s -> occursin("setval", s) && occursin("\"project_article\"", s), seqs) : isempty(seqs)
    out = mktemp() do path, io                                       # (redirect_stdout needs a file, not an IOBuffer)
        redirect_stdout(io) do
            Juango.Migrations.migrate(; plan_only = true)
        end
        flush(io)
        read(path, String)
    end
    @test occursin("Planned operations:", out)
    b = Juango.backend()
    for (I, m) in ((GistIndex, "gist"), (BrinIndex, "brin"), (HashIndex, "hash"), (SpGistIndex, "spgist"))
        ix = I(:title; name = "i151_$m")
        s = Juango.index_spec_sql(b, "article", ix)
        @test IS_POSTGRES ? occursin("USING $m", only(s)) : isempty(s)
    end
    op = Juango.Migrations.AddIndexConcurrently("article", GistIndex(:title; name = "c151"))
    @test Juango.Migrations.needs_no_transaction(op, b) == IS_POSTGRES
    if IS_POSTGRES
        sqls = Juango.Migrations.forwards(op, b, nothing, nothing, nothing)
        @test startswith(only(sqls), "CREATE INDEX CONCURRENTLY") && occursin("c151", Juango.Migrations.op_code(op))
    end
end

@testset "tables (django-tables2) and XLSX" begin
    T = Juango.Tables
    rollback_after() do
        au = create(Author; name = "TB Ann", email = "tb@x.io"); bo = create(Author; name = "TB Bob", email = "tbb@x.io")
        for (t, a, v, p) in (("tb c", au, 30, true), ("tb a", bo, 10, false), ("tb b", au, 20, true))
            create(Article; title = t, author = a, views = v, published = p)
        end
        qs = filter(Article; title__startswith = "tb ")
        req(q = "") = Request("GET", "/list/" * (isempty(q) ? "" : "?" * q))
        mk(r; kw...) = T.Table(qs, r; columns = [:title => T.Column(linkify = a -> "/a/$(a.id)/"),
                                                  :author => T.Column(accessor = "author__name", order_by = "author__name"),
                                                  :views => T.Column(footer = t -> sum(a.views for a in qs)),
                                                  :published => T.BooleanColumn(yesno = ("yes", "no")),
                                                  :tag => T.TemplateColumn("<b>{{ record.title|upper }}</b>"),
                                                  :pick => T.CheckBoxColumn()],
                                       order_by = "title", per_page = 2, kw...)
        t = mk(req())
        html = T.render_table(t).s
        @test occursin("<table class=\"table\">", html) && occursin("<th class=\"orderable\"><a href=\"?sort=views\">Views</a></th>", html)
        @test occursin("<a href=\"/a/", html) && occursin(">tb a</a>", html) && occursin("<td>TB Bob</td>", html)
        @test occursin("<b>TB A</b>", html) && occursin("<td>no</td>", html) && occursin("name=\"pick\" value=\"", html)
        @test !occursin("tb c", html) && occursin("Page 1 of 2", html) && occursin("<td>60</td>", html)    # page 1 of 2; footer
        # sorting from the request keeps the other parameters; clicking again flips it
        t2 = mk(req("sort=-views&q=x"))
        h2 = T.render_table(t2).s
        @test [a.title for a in t2.page.object_list] == ["tb c", "tb b"]
        @test occursin("th class=\"orderable desc\"", h2) && occursin("sort=views", h2) && occursin("q=x", h2)
        @test [a.title for a in mk(req("sort=author")).page.object_list] == ["tb c", "tb b"]          # Ann's, by author name
        @test [a.title for a in mk(req("page=2")).page.object_list] == ["tb c"]
        @test [a.title for a in mk(req("sort=tag")).page.object_list] == ["tb a", "tb b"]              # not orderable: ignored
        # in a template
        @test tr("{% render_table t %}", Dict("t" => t)) == html
        # a list of rows, sorted in Julia; columns from a model by default
        rows = [(name = "x", n = 3), (name = "y", n = nothing), (name = "z", n = 1)]
        lt = T.Table(rows, req("sort=n"); columns = [:name, :n => T.Column(default = "none")], per_page = nothing)
        @test [r.name for r in lt.page.object_list] == ["y", "z", "x"] && occursin("<td>none</td>", T.render_table(lt).s)
        mt = T.Table(Author, req(); exclude = [:email])
        @test [c.first for c in mt.columns] == [:name] && mt.columns[1].second.label == "Name"
        # exports: the whole table, in its sort
        @test T.export_response(t) === nothing
        r = T.export_response(mk(req("sort=-views&_export=csv")))
        @test getheader(r, "Content-Type") == "text/csv; charset=utf-8" && occursin("attachment", getheader(r, "Content-Disposition"))
        @test split(text(r), '\n')[1:4] == ["Title,Author,Views,Published,Tag", "tb c,TB Ann,30,true,TB C", "tb b,TB Ann,20,true,TB B", "tb a,TB Bob,10,false,TB A"]
        x = T.export_response(mk(req("_export=xlsx")))
        @test getheader(x, "Content-Type") == Juango.MIME_TYPES[".xlsx"] && x.body[1:4] == UInt8[0x50, 0x4b, 0x03, 0x04]
        @test T.export_url(t, :csv) == "?_export=csv"
        # CSV injection (#182): text that starts like a formula is shown, not run; numbers stay
        @test Juango.csv_field("=HYPERLINK(\"x\")") == "\"'=HYPERLINK(\"\"x\"\")\""
        @test Juango.csv_field("@SUM(A1)") == "'@SUM(A1)" && Juango.csv_field("+1") == "'+1" && Juango.csv_field(-5) == "-5"
        @test Juango.csv_field("=1+1"; formulas = true) == "=1+1" && Juango.csv_field(nothing) == "" && Juango.csv_field("a,b") == "\"a,b\""
        @test T.csv_string(["A"], [["-2 + 3"]]) == "A\n'-2 + 3\n" && T.csv_string(["A"], [["=x"]]; formulas = true) == "A\n=x\n"
    end
    # the XLSX writer itself
    b = Juango.xlsx_bytes([["Name", "Born", "Score", "Ok", "Note"], ["Ann <&>", Date(2000, 1, 2), 3.5, true, nothing]])
    s = String(copy(b))
    @test occursin("<t xml:space=\"preserve\">Ann &lt;&amp;&gt;</t>", s) && occursin("<c r=\"B2\" s=\"1\"><v>36527</v></c>", s)
    @test occursin("<c r=\"C2\"><v>3.5</v></c>", s) && occursin("<c r=\"D2\" t=\"b\"><v>1</v></c>", s) && !occursin("r=\"E2\"", s)
    @test occursin("<c r=\"A1\" t=\"inlineStr\" s=\"3\">", s)                   # the header is bold
    @test Juango.crc32(Vector{UInt8}("123456789")) == 0xCBF43926                # the standard check value
    @test Juango.column_letters(1) == "A" && Juango.column_letters(27) == "AA" && Juango.column_letters(703) == "AAA"
    r = XlsxResponse([["a"], [1]]; filename = "x.xlsx")
    @test occursin("x.xlsx", getheader(r, "Content-Disposition"))
    f = tempname() * ".xlsx"; write_xlsx(f, [["a", "b"], [1, 2]])
    if Sys.which("unzip") !== nothing                                            # a real zip tool can read it
        @test success(pipeline(`unzip -tq $f`; stdout = devnull, stderr = devnull))
    end
end

@testset "typed query parameters (#172)" begin
    rq(q) = Request("GET", "/x/?" * q)
    @test query_param(rq("page=3"), :page, Int; default = 1) == 3 && query_param(rq(""), :page, Int; default = 1) == 1
    @test query_param(rq("page="), :page, Int; default = 1) == 1                       # empty is missing
    @test_throws Juango.BadRequest query_param(rq("page=abc"), :page, Int; default = 1)
    @test_throws Juango.BadRequest query_param(rq(""), :page, Int)                    # required
    @test query_param(rq("on=yes"), :on, Bool) === true && query_param(rq("on=0"), :on, Bool) === false
    @test_throws Juango.BadRequest query_param(rq("on=maybe"), :on, Bool)
    @test query_param(rq("d=2026-11-15"), :d, Date) == Date(2026, 11, 15)
    @test_throws Juango.BadRequest query_param(rq("d=15th"), :d, Date)
    @test query_param(rq("x=1.5"), :x, Float64) == 1.5 && query_param(rq("q=hi"), :q) == "hi"
    @test query_param(rq("sort=date"), :sort, Symbol; choices = (:name, :date)) === :date
    e = try query_param(rq("sort=evil"), :sort, Symbol; choices = (:name, :date)); nothing catch err; err end
    @test e isa Juango.BadRequest && occursin("must be one of name, date", e.msg)
    @test query_param(rq("t=1&t=2&t=5"), :t, Vector{Int}) == [1, 2, 5] && query_param(rq(""), :t, Vector{Int}; default = Int[]) == Int[]
    @test_throws Juango.BadRequest query_param(rq("t=1&t=x"), :t, Vector{Int})
    # through a view: a 400 page, not a 500
    v(req) = HttpResponse(string(query_param(req, :n, Int)))
    override_settings(ROOT_URLCONF = [path("qp/", v)]) do
        c = Client()
        @test text(get(c, "/qp/?n=4")) == "4" && get(c, "/qp/?n=four").status == 400
    end
end

@testset "protected media (#176)" begin
    md = mktempdir()
    write(joinpath(md, "pic.png"), "PNG"); write(joinpath(md, "page.html"), "<script>alert(1)</script>")
    mkpath(joinpath(md, "u")); write(joinpath(md, "u", "r.svg"), "<svg/>"); write(joinpath(md, "secret.txt"), "x")
    mine(req, name) = Juango.is_authenticated(req.user) && !startswith(name, "secret")
    override_settings(MEDIA_ROOT = md, ROOT_URLCONF = [path("files/<path:name>", protected_media(allow = mine)),
                                                      path("acc/<path:name>", protected_media(sendfile = :x_accel_redirect))]) do
        c = Client()
        r = get(c, "/files/pic.png")
        @test r.status == 302 && occursin("next=", getheader(r, "Location"))                 # anonymous: log in first
        force_login!(c, root_user())
        r = get(c, "/files/pic.png")
        @test r.status == 200 && getheader(r, "Content-Type") == "image/png" && getheader(r, "X-Content-Type-Options") == "nosniff"
        @test occursin("sandbox", getheader(r, "Content-Security-Policy")) && !occursin("attachment", getheader(r, "Content-Disposition"))
        r = get(c, "/files/page.html")                                                         # never served as a page
        @test r.status == 200 && occursin("attachment", getheader(r, "Content-Disposition")) && getheader(r, "Content-Type") == "application/octet-stream"
        @test occursin("attachment", getheader(get(c, "/files/u/r.svg"), "Content-Disposition"))   # SVG can hold scripts
        @test get(c, "/files/secret.txt").status == 403
        @test get(c, "/files/nosuch.png").status == 404
        @test get(c, "/files/..%2F..%2Fetc%2Fpasswd").status in (400, 404)
        r = get(c, "/acc/u/r.svg")                                                             # nginx sends it
        @test getheader(r, "X-Accel-Redirect") == "/protected/u/r.svg" && occursin("attachment", getheader(r, "Content-Disposition"))
    end
    @test_throws ArgumentError protected_media(sendfile = :ftp)
    # in DEBUG, a project route at MEDIA_URL wins over serving uploads as they are (#226)
    override_settings(DEBUG = true, MEDIA_ROOT = md, MEDIA_URL = "/media/", ROOT_URLCONF = [path("media/<path:name>", protected_media())]) do
        c = Client()
        r = get(c, "/media/pic.png")
        @test r.status == 302 && occursin("next=", getheader(r, "Location"))                 # its login check runs
        force_login!(c, root_user())
        @test occursin("sandbox", getheader(get(c, "/media/pic.png"), "Content-Security-Policy"))
    end
    override_settings(DEBUG = true, MEDIA_ROOT = md, MEDIA_URL = "/media/", ROOT_URLCONF = Any[]) do
        @test get(Client(), "/media/pic.png").status == 200                                   # no route: served in DEBUG
    end
end

@testset "N+1 queries: detection, raise, unused eager loads, auto-prefetch (#162)" begin
    W = Base.CoreLogging.Warn
    au = create(Author; name = "NP A")
    for i in 1:6
        create(Article; title = "np$i", author = au)
    end
    nps() = filter(Article; title__startswith = "np")
    for i in 1:5
        create(Author; name = "NP R$i")
    end
    lazy(req) = (foreach(a -> a.author.name, nps()); HttpResponse("ok"))
    eager(req) = (foreach(a -> a.author.name, select_related(nps(), :author)); HttpResponse("ok"))
    unused(req) = (collect(select_related(nps(), :author)); HttpResponse("ok"))
    reverse_(req) = (foreach(a -> count(a.articles), filter(Author; name__startswith = "NP R")); HttpResponse("ok"))
    allowed(req) = with_nplusone_allowed(() -> lazy(req))
    # one object's relation used several ways (#195): not an N+1, however many times
    function oneobj(req)
        a = get(Author; name = "NP A")
        update!(a.articles; views = 1); count(a.articles); collect(values_list(a.articles, :id))
        exists(filter(a.articles; title = "np1")); first(a.articles); length(collect(a.articles))
        a2 = get(Author; name = "NP A"); count(a2.articles)                   # the same row, loaded again
        HttpResponse("ok")
    end
    override_settings(DEBUG = true, ROOT_URLCONF = [path("lazy/", lazy), path("eager/", eager), path("unused/", unused),
                                                    path("rev/", reverse_), path("allowed/", allowed), path("one/", oneobj)]) do
        c = Client()
        @test_logs (:warn, r"N\+1 queries: Article\.author was loaded for 6 objects one at a time in one request \(from .*\)\. Add select_related\(:author\)") min_level = W get(c, "/lazy/")
        @test_logs min_level = W get(c, "/eager/")
        @test_logs (:warn, r"Unused eager load: select_related\(:author\) on Article") min_level = W get(c, "/unused/")
        @test_logs (:warn, r"Author\.articles was loaded for 5 objects.*prefetch_related\(:articles\)") min_level = W get(c, "/rev/")
        @test_logs min_level = W get(c, "/allowed/")
        @test_logs min_level = W get(c, "/one/")
        override_settings(NPLUSONE = :raise) do                                     # for test suites
            @test_throws Juango.NPlusOneError get(c, "/lazy/")
            @test get(c, "/one/").status == 200
            @test get(c, "/eager/").status == 200
        end
        override_settings(NPLUSONE = false) do
            @test_logs min_level = W get(c, "/lazy/")
        end
        override_settings(NPLUSONE_THRESHOLD = 10) do
            @test_logs min_level = W get(c, "/lazy/")
        end
        override_settings(DEBUG = false) do                                        # off in production
            @test_logs min_level = W get(c, "/lazy/")
        end
    end
    # AUTO_PREFETCH: one query for the foreign key of the whole queryset
    @test Juango.count_queries(() -> foreach(a -> a.author.name, nps()))[2] == 7
    override_settings(AUTO_PREFETCH = true) do
        @test Juango.count_queries(() -> foreach(a -> a.author.name, nps()))[2] == 2
    end
end

# typed APIs (#161)
@enum ApiColour red green
struct ApiWellIn; row::String; col::Int; end
struct ApiSampleIn; name::String; volume_ul::Float64; colour::ApiColour; wells::Vector{ApiWellIn}; note::Union{String,Nothing}; end
struct ApiSampleOut; id::Int; name::String; volume::Float64; on::Date; end
api_search161(req, q::String, limit::Union{Int,Nothing} = nothing, tags::Vector{String} = String[]) = (q = q, limit = limit, tags = tags)

@testset "typed APIs with OpenAPI (#161)" begin
    api = API(title = "Lab API", version = "2")
    Base.get(api, "/samples/{id}"; response = ApiSampleOut, summary = "One sample") do req, id::Int
        id == 404 && throw(Http404("no"))
        ApiSampleOut(id, "s$id", 1.5, Date(2026, 1, 2))
    end
    post(api, "/samples"; status = 201, response = ApiSampleOut) do req, body::ApiSampleIn
        ApiSampleOut(7, body.name * "/" * string(body.colour) * "/" * string(length(body.wells)), body.volume_ul, Date(2026, 1, 1))
    end
    Base.get(api_search161, api, "/search")
    Base.get(api, "/authors"; response = ModelSchema(Author; fields = [:id, :name], many = true)) do req
        order_by(filter(Author; name__startswith = "API "), "name")
    end
    route!(api, "DELETE", "/samples/{id}"; status = 204) do req, id::Int
        nothing
    end
    secret = API(auth = api_key_auth(k -> k == "s3cret" ? "robot" : nothing))
    Base.get(secret, "/whoami") do req
        Dict("who" => req.meta[:api_auth])
    end
    add_router!(api, "/admin", secret)
    @test_throws ArgumentError Base.get((req, x::Int) -> x, API(), "/a/{id}")         # a path name with no argument
    create(Author; name = "API B"); create(Author; name = "API A")
    override_settings(ROOT_URLCONF = [path("api/", api_urls(api))]) do
        c = Client()
        r = get(c, "/api/samples/3")
        @test r.status == 200 && JSON.parse(text(r)) == Dict("id" => 3, "name" => "s3", "volume" => 1.5, "on" => "2026-01-02")
        @test get(c, "/api/samples/404").status == 404
        r = get(c, "/api/samples/abc")
        @test r.status == 422 && JSON.parse(text(r))["detail"] == [Dict("loc" => ["path", "id"], "msg" => "expected an integer")]
        good = Dict("name" => "n", "volume_ul" => 2, "colour" => "green", "wells" => [Dict("row" => "A", "col" => 1)])
        r = post(c, "/api/samples"; json = good)
        @test r.status == 201 && JSON.parse(text(r))["name"] == "n/green/1" && JSON.parse(text(r))["volume"] == 2.0
        bad = Dict("name" => 5, "volume_ul" => "lots", "colour" => "blue", "wells" => [Dict("row" => "A"), 3], "extra" => 1)
        r = post(c, "/api/samples"; json = bad)
        d = JSON.parse(text(r))["detail"]
        locs = Set(Tuple(x["loc"]) for x in d)
        @test r.status == 422 && (("body", "name") in locs) && (("body", "volume_ul") in locs) && (("body", "colour") in locs) &&
              (("body", "wells", 0, "col") in locs) && (("body", "wells", 1) in locs) && (("body", "extra") in locs)
        @test any(x -> x["msg"] == "expected one of red, green", d)
        @test post(c, "/api/samples").status == 422                                        # no body
        r = get(c, "/api/search?q=pcr&limit=5&tags=a&tags=b")
        @test JSON.parse(text(r)) == Dict("q" => "pcr", "limit" => 5, "tags" => ["a", "b"])
        @test JSON.parse(text(get(c, "/api/search?q=x")))["limit"] === nothing
        @test get(c, "/api/search").status == 422 && get(c, "/api/search?q=x&limit=many").status == 422
        @test JSON.parse(text(get(c, "/api/authors"))) == [Dict("id" => get(Author; name = "API A").id, "name" => "API A"),
                                                           Dict("id" => get(Author; name = "API B").id, "name" => "API B")]
        @test request(c, "DELETE", "/api/samples/3").status == 204 && request(c, "PUT", "/api/samples/3").status == 405
        @test get(c, "/api/admin/whoami").status == 401
        @test JSON.parse(text(get(c, "/api/admin/whoami"; headers = Dict("X-API-Key" => "s3cret")))) == Dict("who" => "robot")
        # the OpenAPI document and the docs page
        doc = JSON.parse(text(get(c, "/api/openapi.json")))
        @test doc["openapi"] == "3.1.0" && doc["info"]["title"] == "Lab API"
        op = doc["paths"]["/api/samples/{id}"]["get"]
        @test op["summary"] == "One sample" && op["parameters"][1]["in"] == "path" && op["parameters"][1]["schema"]["type"] == "integer"
        @test op["responses"]["200"]["content"]["application/json"]["schema"]["\$ref"] == "#/components/schemas/ApiSampleOut"
        sin = doc["components"]["schemas"]["ApiSampleIn"]
        @test sin["properties"]["colour"]["enum"] == ["red", "green"] && !("note" in sin["required"]) && "wells" in sin["required"]
        @test sin["properties"]["wells"]["items"]["\$ref"] == "#/components/schemas/ApiWellIn"
        sp = doc["paths"]["/api/search"]["get"]["parameters"]
        @test [(p["name"], p["required"]) for p in sp] == [("q", true), ("limit", false), ("tags", false)]
        @test haskey(doc["paths"]["/api/admin/whoami"]["get"]["responses"], "401")
        @test occursin("swagger-ui", text(get(c, "/api/docs")))
    end
    # paginate_api
    @test Juango.to_api_json(Dict(:d => Juango.Decimal("1.50"), :x => 1.5, :n => nothing, :t => (1, "a"))) ==
          Dict("d" => "1.50", "x" => 1.5, "n" => nothing, "t" => Any[1, "a"])
    pg = paginate_api(collect(1:10), Request("GET", "/x?limit=3&offset=8"))
    @test pg == Dict("count" => 10, "items" => [9, 10])
end

@testset "import and export: CSV, XLSX, JSON (#112: django-import-export)" begin
    # the readers
    @test parse_csv("a,b\r\n\"x, y\",\"he said \"\"hi\"\"\"\n\"two\nlines\",'=1+1\n\n") == [["a", "b"], ["x, y", "he said \"hi\""], ["two\nlines", "=1+1"]]
    @test parse_csv("﻿a;b\n1;2"; delimiter = ';') == [["a", "b"], ["1", "2"]] && parse_csv("\"'=x\"") == [["'=x"]]   # quoted: kept as written
    x = read_xlsx(xlsx_bytes([["Name", "Born", "N", "Ok"], ["Ann", Date(1990, 5, 1), 3, true], ["Bob & co", nothing, 2.5, false]]))
    @test x[1] == ["Name", "Born", "N", "Ok"] && x[2][1] == "Ann" && excel_date(x[2][2]) == Date(1990, 5, 1) && x[2][3] == 3 && x[2][4] === true
    @test x[3] == Any["Bob & co", nothing, 2.5, false]
    # export
    ie_a = create(Author; name = "IE Ann", email = "ann@ie.io"); ie_b = create(Author; name = "IE Bob")
    a1 = create(Article; title = "IE one", author = ie_a, views = 3, published = true)
    a2 = create(Article; title = "=HYPERLINK(1)", author = ie_b, views = 0)
    r = ModelResource(Article; fields = [:id, :title, :author, :views, :published], fk = Dict(:author => :name), headers = Dict(:views => "Views"))
    qs = order_by(filter(Article; title__in = ["IE one", "=HYPERLINK(1)"]), "id")
    rows = export_rows(r, qs)
    @test rows[1] == ["id", "title", "author", "Views", "published"] && rows[2] == Any[a1.id, "IE one", "IE Ann", 3, true]
    csv = String(export_data(r, qs; format = :csv))
    @test occursin("'=HYPERLINK(1)", csv)                                       # formula-protected
    @test parse_csv(csv)[3][2] == "=HYPERLINK(1)"                               # and back as written
    @test read_xlsx(export_data(r, qs; format = :xlsx))[2] == Any[a1.id, "IE one", "IE Ann", 3, true]
    @test Juango.JSON.parse(String(export_data(r, qs; format = :json)))[1]["author"] == "IE Ann"
    d = export_download(r, qs; format = :xlsx)
    @test occursin("attachment", getheader(d, "Content-Disposition")) && occursin(".xlsx", getheader(d, "Content-Disposition"))
    # import: a dry run says what would happen and keeps nothing
    up = "id,title,author,Views,published\n$(a1.id),IE one,IE Bob,5,true\n$(a2.id),=HYPERLINK(1),IE Bob,0,false\n,IE new,IE Ann,7,false\n"
    res = import_data(r, up; format = :csv)
    @test !has_errors(res) && res.dry_run && res.totals[:update] == 1 && res.totals[:skip] == 1 && res.totals[:new] == 1
    u = only(filter(x -> x.kind === :update, res.rows))
    @test u.number == 2 && Set(u.diff) == Set([("author", "IE Ann", "IE Bob"), ("Views", 3, 5)])
    @test get(Article; id = a1.id).views == 3 && !exists(filter(Article; title = "IE new"))               # nothing kept
    # for real
    res = import_data(r, up; format = :csv, dry_run = false)
    @test !has_errors(res) && get(Article; id = a1.id).views == 5 && get(Article; id = a1.id).author.name == "IE Bob"
    @test get(Article; title = "IE new").author.name == "IE Ann"
    # an invalid row refuses the whole import, with the reasons
    bad = "title,author,Views\nIE good,IE Ann,1\nIE bad,Nobody,lots\n"
    res = import_data(ModelResource(Article; fields = [:title, :author, :views], fk = Dict(:author => :name), headers = Dict(:views => "Views"),
                                    import_id_fields = [:title]), bad; format = :csv, dry_run = false)
    @test has_errors(res) && !exists(filter(Article; title = "IE good"))
    b = only(filter(x -> x.kind === :invalid, res.rows))
    @test b.number == 3 && occursin("No author with name \"Nobody\"", only(b.errors["author"])) && haskey(b.errors, "views")
    # a natural key, XLSX, a column matched by its label, an unknown column ignored, validation errors
    ar = ModelResource(Author; fields = [:name, :email], import_id_fields = [:name])
    file = xlsx_bytes([["Name", "Email", "Shoe size"], ["IE Ann", "ann2@ie.io", 9], ["IE Cat", "cat@ie.io", 7], ["IE Dan", "not an email", 8]])
    res = import_data(ar, file; format = :xlsx)
    @test res.ignored_columns == ["Shoe size"] && res.totals[:update] == 1 && res.totals[:new] == 1 && haskey(only(filter(x -> x.kind === :invalid, res.rows)).errors, "email")
    res = import_data(ar, xlsx_bytes([["Name", "Email"], ["IE Ann", "ann2@ie.io"], ["IE Cat", "cat@ie.io"]]); format = :xlsx, dry_run = false)
    @test !has_errors(res) && get(Author; name = "IE Ann").email == "ann2@ie.io" && exists(filter(Author; name = "IE Cat"))
    # many-to-many by name; JSON
    t1, t2 = create(Topic; name = "IE web"), create(Topic; name = "IE db")
    er = ModelResource(Essay; fields = [:title, :topics], fk = Dict(:topics => :name), import_id_fields = [:title])
    res = import_data(er, """[{"title": "IE essay", "topics": "IE web, IE db"}]"""; format = :json, dry_run = false)
    @test !has_errors(res) && Set(t.name for t in get(Essay; title = "IE essay").topics) == Set(["IE web", "IE db"])
    @test export_rows(er, filter(Essay; title = "IE essay"))[2][2] in ("IE web, IE db", "IE db, IE web")
    @test import_data(er, """[{"title": "IE essay", "topics": "IE db, IE web"}]"""; format = :json).totals[:skip] == 1   # the same set
    # a delete column
    dr = ModelResource(Author; fields = [:name], import_id_fields = [:name], delete_column = "Delete")
    res = import_data(dr, "name,Delete\nIE Cat,yes\nIE Nobody,x\n"; format = :csv, dry_run = false)
    @test res.totals[:delete] == 1 && res.totals[:skip] == 1 && !exists(filter(Author; name = "IE Cat"))
    # a field's own conversion (#196): views stored as a 96-well position, written as the well's name
    wname(p) = string('A' + (p - 1) ÷ 12, (p - 1) % 12 + 1)
    function windex(s)
        m = match(r"^([A-H])(\d{1,2})$", uppercase(strip(string(s))))
        m === nothing && error("not a 96-well name: $s")
        c = parse(Int, m[2]); 1 <= c <= 12 || return nothing
        (m[1][1] - 'A') * 12 + c
    end
    wr = ModelResource(Article; fields = [:title, :views], import_id_fields = [:title], headers = Dict(:views => "well"),
                       convert = Dict(:views => (render = wname, clean = windex)))
    update!(filter(Article; title = "IE one"); views = 14)
    @test export_rows(wr, filter(Article; title = "IE one"))[2] == Any["IE one", "B2"]
    res = import_data(wr, "title,well\nIE one,H12\n"; format = :csv, dry_run = false)
    @test !has_errors(res) && get(Article; title = "IE one").views == 96 && res.rows[1].diff == [("well", 14, 96)]
    res = import_data(wr, "title,well\nIE blank,\n"; format = :csv)               # blank: as the field handles it, not converted
    @test !any(occursin("96-well", m) for m in get(res.rows[1].errors, "views", String[]))
    res = import_data(wr, "title,well\nIE one,Z9\nIE new,A13\n"; format = :csv)
    @test res.totals[:invalid] == 2 && only(res.rows[1].errors["views"]) == "not a 96-well name: Z9"
    @test only(res.rows[2].errors["views"]) == "\"A13\" isn't a valid well."
    @test_throws ArgumentError ModelResource(Article; fields = [:title], convert = Dict(:views => (render = wname,)))
    @test_throws ArgumentError ModelResource(Article; fields = [:views], convert = Dict(:views => wname))
    # file errors
    @test has_errors(import_data(ar, "email\nx@y.io\n"; format = :csv)) && has_errors(import_data(ar, ""; format = :csv))
    @test_throws ArgumentError ModelResource(Author; fields = [:nosuch])
    @test Juango.format_of("x.XLSX") === :xlsx && Juango.format_of("x.txt") === nothing
end

@testset "typed QueryDict get, get_text_list (#192, #191)" begin
    q = Request("GET", "/x/?id=12&n=abc&on=yes&d=2026-11-16&f=1.5&e=&t=1&t=x&t=3&u=6ba7b810-9dad-11d1-80b4-00c04fd430c8").GET
    @test get(q, "id", Int) === 12 && get(q, :id, Int) === 12 && get(q, "n", Int) === nothing && get(q, "e", Int) === nothing
    @test get(q, "missing", Int) === nothing && get(q, "on", Bool) === true && get(q, "d", Date) == Date(2026, 11, 16)
    @test get(q, "f", Float64) == 1.5 && get(q, "id", String) == "12" && get(q, "u", Juango.UUID) isa Juango.UUID
    @test getlist(q, "t", Int) == [1, 3] && get(q, "id", "default") == "12" && get(q, "zz", "default") == "default"
    @test_throws Juango.Http404 get_object_or_404(Author; id = get(q, "n", Int))                 # nothing: 404, no trick needed
    @test get_text_list(["a", "b", "c"]) == "a, b or c" && get_text_list(["a", "b"], "and") == "a and b"
    @test get_text_list(["solo"]) == "solo" && get_text_list(String[]) == "" && get_text_list([1, 2, 3], "and") == "1, 2 and 3"
    @test render(Template("{{ xs|text_list:\"and\" }}"), Dict{String,Any}("xs" => ["x", "y", "z"])) == "x, y and z"
end
