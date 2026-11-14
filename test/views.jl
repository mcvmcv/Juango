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
    @test haskey(c.cookies, "csrftoken") && length(tok) == 64 && Juango.unmask_csrf(tok) == c.cookies["csrftoken"]   # masked
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
    @test assert_redirects(r, settings.LOGIN_URL * "?next=%2Fsecret%2F") && assert_redirects(r, settings.LOGIN_URL * "?next=%2Fsecret%2F"; client = c)
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
        @test r.status == 200 && occursin("ForeignKey to Author", text(r)) && occursin("<code>article</code>", text(r))
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
        old_hashers === nothing ? configure!(PASSWORD_HASHERS = Any[Juango.PBKDF2Hasher()]) : configure!(PASSWORD_HASHERS = old_hashers)
    end

    # LoginRequiredMiddleware
    mw = settings.MIDDLEWARE
    configure!(MIDDLEWARE = vcat(mw, [LoginRequiredMiddleware]))
    try
        c = Client()
        r = get(c, "/whoami/")
        @test r.status == 302 && getheader(r, "Location") == "/accounts/login/?next=%2Fwhoami%2F"
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
             Dict("u" => u, "a" => Juango.AnonymousUser())) == "kwpass|Kay Doe|Kay||true"

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
        override_settings(LIVE_MAX_VIEWS_PER_SESSION = 1) do
            code = H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws1
                ws_send(ws1, Dict("type" => "join", "params" => Dict()))
                recv(ws1)
                H.WebSockets.open("ws://127.0.0.1:$port/keep/") do ws2                 # the same client address
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
        @test isempty(Juango.LIVE_OPEN)                                           # released when the sockets closed
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
    @test get_page(p, 0).number == 1 && get_page(p, "last").number == 3 && get_page(Paginator(Int[], 10), 5).number == 1
    @test_throws Juango.Http404 page(p, 99)
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
    @test content_disposition("Résumé.pdf"; attachment = true) == "attachment; filename*=UTF-8''R%C3%A9sum%C3%A9.pdf"
end
