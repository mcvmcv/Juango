# services: julia --project=test test/services.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "email, signing and password reset" begin
    import Sockets
    c = Client()
    @test settings.EMAIL_BACKEND === :locmem                       # the test Client keeps mail in memory
    empty!(outbox)
    @test send_mail("Hi", "Body", "a@x.io", ["b@x.io", "c@x.io"]) == 1
    @test only(outbox).subject == "Hi" && only(outbox).to == ["b@x.io", "c@x.io"] && only(outbox).from_email == "a@x.io"
    @test send_mail("Nobody", "x", nothing, String[]) == 0

    msg = EmailMessage("Ünïcode subject", "body text"; to = ["t@x.io"], cc = ["c@x.io"], bcc = ["secret@x.io"], reply_to = ["r@x.io"])
    attach!(msg, "r.csv", "a,b", "text/csv")
    attach_alternative!(msg, "<p>hi</p>")
    s = Juango.message_string(msg)
    @test occursin("Subject: =?utf-8?b?", s) && occursin("Cc: c@x.io", s) && occursin("Reply-To: r@x.io", s) && !occursin("secret@x.io", s)
    @test occursin("multipart/mixed", s) && occursin("multipart/alternative", s) && occursin("filename=\"r.csv\"", s)
    @test occursin(Juango.base64encode("body text"), s) && occursin(Juango.base64encode("<p>hi</p>"), s)
    @test Juango.recipients(msg) == ["t@x.io", "c@x.io", "secret@x.io"]
    @test !occursin("\r\nBcc: evil", Juango.message_string(EmailMessage("a\r\nBcc: evil@x.io", "b"; to = ["t@x.io"])))

    # backends
    configure!(EMAIL_BACKEND = :console)
    path_, io = mktemp()
    redirect_stdout(() -> send_mail("Console", "printed", nothing, ["t@x.io"]), io); close(io)
    @test occursin("Subject: Console", read(path_, String))
    dir = mktempdir()
    configure!(EMAIL_BACKEND = :file, EMAIL_FILE_PATH = dir)
    send_mail("Filed", "x", nothing, ["t@x.io"])
    @test length(readdir(dir)) == 1 && occursin("Subject: Filed", read(joinpath(dir, only(readdir(dir))), String))
    configure!(EMAIL_BACKEND = :dummy)
    @test send_mail("Dropped", "x", nothing, ["t@x.io"]) == 1
    configure!(EMAIL_BACKEND = :locmem, ADMINS = [("Admin", "admin@x.io")])
    empty!(outbox)
    mail_admins("Oops", "details")
    @test only(outbox).subject == "[Juango] Oops" && only(outbox).to == ["admin@x.io"]

    # 500 errors are mailed to ADMINS when DEBUG is off
    empty!(outbox)
    configure!(DEBUG = false)
    try
        @test get(c, "/boom/").status == 500
    finally
        configure!(DEBUG = true)
    end
    @test occursin("Internal Server Error: /boom/", only(outbox).subject) && occursin("boom", only(outbox).body)
    configure!(ADMINS = Any[])

    # SMTP against a tiny fake server
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    transcript = String[]
    srv = @async begin
        sock = Sockets.accept(server)
        write(sock, "220 fake ESMTP\r\n")
        indata = false
        while isopen(sock)
            l = readline(sock)
            push!(transcript, l)
            if indata
                l == "." && (indata = false; write(sock, "250 queued\r\n"))
            elseif startswith(l, "EHLO")
                write(sock, "250-fake\r\n250 AUTH PLAIN\r\n")
            elseif startswith(l, "AUTH")
                write(sock, "235 ok\r\n")
            elseif startswith(l, "DATA")
                indata = true; write(sock, "354 go\r\n")
            elseif startswith(l, "QUIT")
                write(sock, "221 bye\r\n"); close(sock)
            elseif !isempty(l)
                write(sock, "250 ok\r\n")
            end
        end
    end
    configure!(EMAIL_BACKEND = :smtp, EMAIL_HOST = "127.0.0.1", EMAIL_PORT = port, EMAIL_HOST_USER = "u", EMAIL_HOST_PASSWORD = "p")
    try
        @test send_mail("SMTP test", "hello", "Site <from@x.io>", ["to@x.io"]; html_message = "<b>hello</b>") == 1
        wait(srv)
    finally
        close(server)
        configure!(EMAIL_BACKEND = :locmem, EMAIL_HOST_USER = "", EMAIL_HOST_PASSWORD = "")
    end
    @test "MAIL FROM:<from@x.io>" in transcript && "RCPT TO:<to@x.io>" in transcript
    @test ("AUTH PLAIN " * Juango.base64encode("\0u\0p")) in transcript && "Subject: SMTP test" in transcript && "QUIT" in transcript

    # signing
    t = signing_dumps(Dict("a" => 1, "b" => [1, 2]))
    @test signing_loads(t) == Dict("a" => 1, "b" => [1, 2]) && signing_loads(t; max_age = 60)["a"] == 1
    @test_throws BadSignature signing_loads(t[1:end-1] * (t[end] == 'A' ? "B" : "A"))
    @test_throws BadSignature signing_loads(t; salt = "other")
    @test_throws SignatureExpired signing_loads(t; max_age = -1)
    @test unsign_value(sign_value("hello")) == "hello"
    @test_throws BadSignature unsign_value("hello:nope")

    # password reset
    u = create_user("resetme", "oldpassword1"; email = "reset@x.io")
    empty!(outbox)
    r = post(c, "/accounts/password_reset/", Dict("email" => "RESET@x.io"))
    @test r.status == 302 && getheader(r, "Location") == "/accounts/password_reset/done/"
    @test only(outbox).to == ["reset@x.io"] && only(outbox).subject == "Password reset on $(settings.SITE_NAME)"
    link = match(r"http://testserver(/accounts/reset/\S+/)", only(outbox).body)[1]
    @test occursin("resetme", only(outbox).body)
    @test post(c, "/accounts/password_reset/", Dict("email" => "nobody@x.io")).status == 302 && length(outbox) == 1
    @test occursin("Password reset sent", text(get(c, "/accounts/password_reset/done/")))
    @test occursin("Enter new password", text(get(c, link)))
    r = post(c, link, Dict("new_password1" => "newpassword9", "new_password2" => "different9"))
    @test occursin("didn’t match", text(r))
    r = post(c, link, Dict("new_password1" => "123", "new_password2" => "123"))
    @test occursin("too short", text(r)) && occursin("entirely numeric", text(r))
    r = post(c, link, Dict("new_password1" => "newpassword9", "new_password2" => "newpassword9"))
    @test r.status == 302 && getheader(r, "Location") == "/accounts/reset/done/"
    @test authenticate("resetme", "newpassword9") !== nothing && authenticate("resetme", "oldpassword1") === nothing
    @test occursin("unsuccessful", text(get(c, link)))                # used: the password hash changed
    @test !check_reset_token(get(User; id = u.id), "garbage") && occursin("unsuccessful", text(get(c, "/accounts/reset/xx/1-abc/")))
    @test check_reset_token(get(User; id = u.id), make_reset_token(get(User; id = u.id)))
end

@testset "caching" begin
    import Sockets
    old_caches = settings.CACHES
    try
        configure!(CACHES = Dict("default" => Dict(:backend => :locmem, :max_entries => 3, :timeout => 300),
                                 "nothing" => Dict(:backend => :dummy),
                                 "db" => Dict(:backend => :db, :location => "juango_cache_test")))
        cache_clear()
        @test cache_get("missing") === nothing && cache_get("missing", 7) == 7
        cache_set("a", Dict("x" => [1, 2]))
        v = cache_get("a"); push!(v["x"], 3)
        @test cache_get("a") == Dict("x" => [1, 2])                      # stored values are copies
        cache_set("short", 1; timeout = 2); cache_set("never", 1; timeout = 0)
        @test cache_has("short") && !cache_has("never")
        sleep(2.2)
        @test !cache_has("short")
        @test cache_add("k", 1) && !cache_add("k", 2) && cache_get("k") == 1
        @test cache_delete("k") && !cache_delete("k")
        calls = Ref(0)
        @test get_or_set("computed", () -> (calls[] += 1; 42)) == 42 && get_or_set("computed", () -> (calls[] += 1; 0)) == 42 && calls[] == 1
        cache_set("n", 10)
        @test incr("n") == 11 && incr("n", 5) == 16 && decr("n") == 15
        @test_throws KeyError incr("no such key")
        cache_set("v", "one"; version = 1); cache_set("v", "two"; version = 2)
        @test cache_get("v"; version = 1) == "one" && cache_get("v"; version = 2) == "two"
        cache_set("menu", "old")
        @test incr_version("menu") == 2 && cache_get("menu") === nothing && cache_get("menu"; version = 2) == "old"
        cache_clear()
        for k in ("p", "q", "r"); cache_set(k, 1); end
        cache_get("p")                                                    # p is now the most recently used
        cache_set("s", 1)                                                 # evicts q, the least recently used
        @test cache_has("p") && !cache_has("q") && cache_has("r") && cache_has("s")
        cache_set_many(Dict("m1" => 1, "m2" => 2))
        @test cache_get_many(["m1", "m2", "zz"]) == Dict("m1" => 1, "m2" => 2)
        longkey = repeat("long key ", 50)                                 # long or odd keys are hashed
        cache_set(longkey, 1)
        @test cache_get(longkey) == 1

        cache_set("x", 1; cache_name = "nothing")
        @test cache_get("x"; cache_name = "nothing") === nothing

        create_cache_table("db")
        @test Juango.table_exists(Juango.backend(), "juango_cache_test")
        cache_set("obj", (a = 1, b = "two", c = [1.5]); cache_name = "db")
        @test cache_get("obj"; cache_name = "db") == (a = 1, b = "two", c = [1.5])
        cache_set("obj", "replaced"; cache_name = "db")
        @test cache_get("obj"; cache_name = "db") == "replaced"
        cache_set("brief", 1; timeout = 1, cache_name = "db"); sleep(1.2)
        @test cache_get("brief"; cache_name = "db") === nothing
        cache_set("n", 1; cache_name = "db")
        @test incr("n"; cache_name = "db") == 2
        cache_clear(cache_name = "db")
        @test cache_get("obj"; cache_name = "db") === nothing
        Juango.execute("DROP TABLE " * Juango.qname("juango_cache_test"))

        # Redis, against a fake server speaking RESP
        server = Sockets.listen(Sockets.localhost, 0)
        port = Int(Sockets.getsockname(server)[2])
        store = Dict{String,String}()
        commands = String[]
        bulk(v) = v === nothing ? "\$-1\r\n" : string("\$", ncodeunits(v), "\r\n", v, "\r\n")
        srv = @async begin
            sock = Sockets.accept(server)
            while isopen(sock) && !eof(sock)
                args = Juango.resp_read(sock)
                cmd = uppercase(args[1])
                push!(commands, cmd)
                if cmd == "GET"
                    write(sock, bulk(get(store, args[2], nothing)))
                elseif cmd == "SET"
                    store[args[2]] = args[3]; write(sock, "+OK\r\n")
                elseif cmd == "DEL"
                    write(sock, string(":", pop!(store, args[2], nothing) === nothing ? 0 : 1, "\r\n"))
                elseif cmd == "FLUSHDB"
                    empty!(store); write(sock, "+OK\r\n")
                else
                    write(sock, "+OK\r\n")
                end
            end
        end
        configure!(CACHES = Dict("default" => Dict(:backend => :redis, :location => "redis://127.0.0.1:$port/2")))
        cache_set("r", Dict("deep" => [1, 2]); timeout = 60)
        @test cache_get("r") == Dict("deep" => [1, 2]) && cache_get("absent") === nothing
        @test cache_delete("r") && !cache_has("r")
        cache_set("n", 1)
        @test incr("n") == 2
        cache_clear()
        @test isempty(store) && "SELECT" in commands && "FLUSHDB" in commands
        configure!(CACHES = Dict("default" => Dict(:backend => :locmem)))     # closes the Redis connection
        close(server)

        # cached views and the per-site middleware
        hits = Ref(0)
        view = cache_page((req) -> (hits[] += 1; HttpResponse("page $(hits[])")); timeout = 60)
        req(path) = Request("GET", path; headers = Dict("host" => "testserver"))
        @test text(view(req("/c/"))) == "page 1" && text(view(req("/c/"))) == "page 1" && hits[] == 1
        @test occursin("max-age=60", getheader(view(req("/c/")), "Cache-Control"))
        @test text(view(req("/c/?page=2"))) == "page 2"
        cookie_view = cache_page((req) -> (hits[] += 1; r = HttpResponse("c"); set_cookie!(r, "x", "1"); r))
        cookie_view(req("/k/")); cookie_view(req("/k/"))
        @test hits[] == 4                                                  # responses setting cookies aren't cached
        mw = CacheMiddleware(r -> (hits[] += 1; HttpResponse("site")))
        mw(req("/m/")); mw(req("/m/"))
        @test hits[] == 5
        mw(Request("POST", "/m/"))
        @test hits[] == 6

        # {% cache %} template fragments
        tpl = "{% cache 60 \"sidebar\" uid %}{{ text }}{% endcache %}"
        @test tr(tpl, Dict("uid" => 1, "text" => "first")) == "first"
        @test tr(tpl, Dict("uid" => 1, "text" => "second")) == "first"
        @test tr(tpl, Dict("uid" => 2, "text" => "second")) == "second"

        # templates read once when TEMPLATE_CACHE_CHECK_MTIME is off
        tdir = mktempdir()
        write(joinpath(tdir, "cached.html"), "v1")
        old_dirs = settings.TEMPLATE_DIRS
        configure!(TEMPLATE_DIRS = vcat([tdir], old_dirs), TEMPLATE_CACHE_CHECK_MTIME = false)
        @test render_to_string("cached.html") == "v1"
        sleep(1.1); write(joinpath(tdir, "cached.html"), "v2")
        @test render_to_string("cached.html") == "v1"
        configure!(TEMPLATE_CACHE_CHECK_MTIME = true)
        @test render_to_string("cached.html") == "v2"
        configure!(TEMPLATE_DIRS = old_dirs)

        # cache-backed sessions
        for engine in (:cache, :cached_db)
            configure!(SESSION_ENGINE = engine)
            sess = Juango.Session(); sess["cart"] = [1, 2]
            Juango.save_session!(sess)
            @test Juango.load_session(sess.key)["cart"] == [1, 2]
            @test exists(filter(Juango.SessionRecord; session_key = sess.key)) == (engine === :cached_db)
            Juango.flush!(sess)
        end
        configure!(SESSION_ENGINE = :db)
        c = Client()
        force_login!(c, root_user())
        @test get(c, "/admin/").status == 200
    finally
        configure!(CACHES = old_caches, SESSION_ENGINE = :db)
    end
end

@testset "signals" begin
    log = Any[]
    function on_save(sender; instance, created, signal, kw...)
        push!(log, (signal.name, sender, instance isa Topic ? instance.name : instance, created))
    end
    on_delete(sender; instance, signal, kw...) = push!(log, (signal.name, sender, instance.name))
    connect!(pre_save, on_save; sender = Topic)
    connect!(post_save, on_save; sender = Topic)
    connect!(post_save, on_save; sender = Topic)                       # connecting twice has no effect
    connect!(pre_delete, on_delete; sender = Topic)
    connect!(post_delete, on_delete; sender = Topic)
    try
        t = create(Topic; name = "sig-a")
        @test log == [("pre_save", Topic, "sig-a", true), ("post_save", Topic, "sig-a", true)]
        empty!(log)
        t.name = "sig-b"; save!(t)
        @test log == [("pre_save", Topic, "sig-b", false), ("post_save", Topic, "sig-b", false)]
        empty!(log)
        create(Author; name = "Sig Author")                           # other senders don't reach these receivers
        @test isempty(log)
        delete!(t)
        @test log == [("pre_delete", Topic, "sig-b"), ("post_delete", Topic, "sig-b")]
        empty!(log)

        # cascaded deletes send signals too
        deleted = String[]
        on_art(sender; instance, kw...) = push!(deleted, instance.title)
        connect!(post_delete, on_art; sender = Article)
        a = create(Author; name = "Sig Cascade")
        create(Article; title = "sig-child", author = a)
        delete!(a)
        @test deleted == ["sig-child"]
        disconnect!(post_delete, on_art; sender = Article)

        # many-to-many changes
        changes = Any[]
        on_m2m(sender; action, instance, model, pk_set, reverse, kw...) = push!(changes, (action, instance isa Essay ? instance.title : instance.name, model, pk_set, reverse))
        through = Juango.through_model(only(Juango.modelmeta(Essay).m2m))
        connect!(m2m_changed, on_m2m; sender = through)
        e = create(Essay; title = "sig-essay")
        t1, t2 = create(Topic; name = "sig-t1"), create(Topic; name = "sig-t2")
        empty!(log)
        add!(e.topics, t1, t2)
        add!(e.topics, t1)                                               # nothing new: no signal
        remove!(e.topics, t2)
        clear!(t1.essays)
        @test changes == [(:pre_add, "sig-essay", Topic, Set([t1.id, t2.id]), false), (:post_add, "sig-essay", Topic, Set([t1.id, t2.id]), false),
                          (:pre_remove, "sig-essay", Topic, Set([t2.id]), false), (:post_remove, "sig-essay", Topic, Set([t2.id]), false),
                          (:pre_clear, "sig-t1", Essay, nothing, true), (:post_clear, "sig-t1", Essay, nothing, true)]
        disconnect!(m2m_changed, on_m2m; sender = through)

        # dispatch_uid, any sender, robust sending, do-block receivers
        sig = Signal("custom")
        seen = Any[]
        receiver(sig) do sender, args
            push!(seen, (sender, args.value))
            args.value * 2
        end
        connect!(sig, (s; kw...) -> error("broken receiver"); dispatch_uid = "broken")
        @test_throws ErrorException send(sig, :me; value = 1)
        res = send_robust(sig, :me; value = 2)
        @test last(res[1]) == 4 && last(res[2]) isa ErrorException && (:me, 2) in seen
        @test disconnect!(sig; dispatch_uid = "broken") && !disconnect!(sig; dispatch_uid = "broken")
        @test [last(r) for r in send(sig, :other; value = 5)] == [10]
        @test has_receivers(sig, :anyone) && !has_receivers(Signal(), :anyone)

        # requests and authentication
        events = Any[]
        rs(sender; request, kw...) = push!(events, (:started, request.path))
        rf(sender; request, response, kw...) = push!(events, (:finished, response.status))
        li(sender; request, user, kw...) = push!(events, (:in, user.username))
        lo(sender; request, user, kw...) = push!(events, (:out, user.username))
        lf(sender; credentials, kw...) = push!(events, (:failed, credentials["username"]))
        connect!(request_started, rs); connect!(request_finished, rf)
        connect!(user_logged_in, li; sender = User); connect!(user_logged_out, lo; sender = User)
        connect!(user_login_failed, lf; sender = :authenticate)
        create_user("sigu", "pw123456")
        c = Client()
        post(c, "/accounts/login/", Dict("username" => "sigu", "password" => "wrong"))
        post(c, "/accounts/login/", Dict("username" => "sigu", "password" => "pw123456"))
        post(c, "/accounts/logout/")
        @test (:started, "/accounts/login/") in events && (:finished, 302) in events
        @test (:failed, "sigu") in events && (:in, "sigu") in events && (:out, "sigu") in events
        @test !any(e -> e == (:failed, "pw123456"), events)
        foreach(((s, f),) -> disconnect!(s, f; sender = s === request_started || s === request_finished ? nothing : s === user_login_failed ? :authenticate : User),
                [(request_started, rs), (request_finished, rf), (user_logged_in, li), (user_logged_out, lo), (user_login_failed, lf)])
        @test !has_receivers(request_started, :handler)
    finally
        disconnect!(pre_save, on_save; sender = Topic); disconnect!(post_save, on_save; sender = Topic)
        disconnect!(pre_delete, on_delete; sender = Topic); disconnect!(post_delete, on_delete; sender = Topic)
    end
end

@testset "internationalisation" begin
    J = Juango
    # plural rules from Plural-Forms
    pl = J.plural_function("n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2")   # Polish
    @test [pl(n) for n in (1, 2, 4, 5, 12, 22, 25)] == [0, 1, 1, 2, 2, 1, 2]
    @test J.plural_function("(n != 1)")(1) == 0 && J.plural_function("n > 1")(0) == 0

    # .po and .mo round trips
    po = """
    msgid ""
    msgstr ""
    "Plural-Forms: nplurals=2; plural=(n > 1);\\n"

    #: x.jl
    msgid "Hello"
    msgstr "Bonjour"

    msgctxt "verb"
    msgid "Book"
    msgstr "Réserver"

    msgid "%(n)d apple"
    msgid_plural "%(n)d apples"
    msgstr[0] "%(n)d pomme"
    msgstr[1] "%(n)d pommes"

    msgid "%(n)s apple"
    msgid_plural "%(n)s apples"
    msgstr[0] "%(n)s pomme"
    msgstr[1] "%(n)s pommes"

    #, fuzzy
    msgid "Unsure"
    msgstr "Pas sûr"

    msgid "Multi"
    "line"
    msgstr "Multi\\n"
    "ligne"
    """
    es = J.parse_po(po)
    cat = J.catalog_from_entries(es)
    @test cat.messages[("", "Hello")] == ["Bonjour"] && cat.messages[("verb", "Book")] == ["Réserver"]
    @test cat.messages[("", "%(n)d apple")] == ["%(n)d pomme", "%(n)d pommes"] && !haskey(cat.messages, ("", "Unsure"))
    @test cat.messages[("", "Multiline")] == ["Multi\nligne"] && cat.plural(0) == 0 && cat.plural(2) == 1
    @test J.catalog_from_entries(J.read_mo(J.write_mo(es))).messages == cat.messages
    io = IOBuffer(); J.write_po(io, es; header = J.header_of(es))
    @test J.catalog_from_entries(J.parse_po(String(take!(io)))).messages == cat.messages

    # Juango's own German catalogue
    with_language("de") do
        @test gettext("This field is required.") == "Dieses Feld ist zwingend erforderlich."
        @test pgettext("abbrev. month", "Oct") == "Okt" && J.format_date(Date(2024, 10, 3), "l, j. F Y") == "Donnerstag, 3. Oktober 2024"
        @test tr("{{ d|date }}", Dict("d" => Date(2024, 3, 5))) == "5. März 2024"
        f = ModelForm(Author; data = Dict("name" => ""))
        @test !is_valid(f) && f.errors[:name] == ["Dieses Feld ist zwingend erforderlich."]
        @test get_language() == "de"
    end
    @test get_language() == "en" && gettext("This field is required.") == "This field is required."
    lazy = gettext_lazy("Save")
    @test lazy == "Save" && with_language(() -> string(lazy), "de") == "Sichern" && with_language(() -> uppercase(lazy), "de") == "SICHERN"
    fld = CharField(max_length = 10, verbose_name = gettext_lazy("Search"))
    fld.name = :q
    @test with_language(() -> J.label(fld), "de") == "Suchen" && J.label(fld) == "Search"
    @test interpolate("%(n)d items for %(who)s", Dict("n" => 3, "who" => "Ann")) == "3 items for Ann"

    # project catalogues in LOCALE_PATHS override Juango's own
    ldir = mktempdir()
    mkpath(joinpath(ldir, "fr", "LC_MESSAGES")); write(joinpath(ldir, "fr", "LC_MESSAGES", "juango.po"), po)
    mkpath(joinpath(ldir, "de", "LC_MESSAGES"))
    write(joinpath(ldir, "de", "LC_MESSAGES", "juango.po"), "msgid \"Save\"\nmsgstr \"Speichern\"\n")
    configure!(LOCALE_PATHS = [ldir])
    try
        with_language("fr") do
            @test gettext("Hello") == "Bonjour" && pgettext("verb", "Book") == "Réserver" && gettext("Book") == "Book"
            @test interpolate(ngettext("%(n)d apple", "%(n)d apples", 0), Dict("n" => 0)) == "0 pomme"
            @test interpolate(ngettext("%(n)d apple", "%(n)d apples", 3), Dict("n" => 3)) == "3 pommes"
            @test t"Hello" == "Bonjour"
        end
        with_language("de") do
            @test gettext("Save") == "Speichern" && gettext("Delete") == "Löschen"
        end
        @test with_language(() -> gettext("Hello"), "fr-ca") == "Bonjour"          # region falls back to the language

        # templates
        with_language("fr") do
            @test tr("{% load i18n %}{% translate \"Hello\" %} {% trans 'Book' context 'verb' %}") == "Bonjour Réserver"
            @test tr("{% translate \"Hello\" as hi %}[{{ hi }}]") == "[Bonjour]"
            @test tr("{% translate \"Hello\" noop %}") == "Hello"
            b = "{% blocktranslate count n=items|length %}{{ n }} apple{% plural %}{{ n }} apples{% endblocktranslate %}"
            @test tr(b, Dict("items" => [1])) == "1 pomme" && tr(b, Dict("items" => [1, 2, 3])) == "3 pommes"
            @test tr("{% blocktranslate with who=name %}Hi {{ who }}{% endblocktranslate %}", Dict("name" => "<b>")) == "Hi &lt;b&gt;"
            @test tr("{% get_current_language as L %}{{ L }}") == "fr"
            @test tr("{% language 'de' %}{% translate 'Save' %}{% endlanguage %} {% translate 'Hello' %}") == "Speichern Bonjour"
        end
        @test tr("{% blocktranslate trimmed %}\n  Hello\n{% endblocktranslate %}") == "Hello"
        @test tr("{{ x|localize }}", Dict("x" => 1234.5)) == "1234.5" && with_language(() -> tr("{{ x|localize }}", Dict("x" => 1234.5)), "de") == "1234,5"
        @test number_format(1234567.891; decimals = 2, lang = "de", grouping = true) == "1.234.567,89"
        @test number_format(-1234; lang = "en", grouping = true) == "-1,234"

        # makemessages / compilemessages
        proj = mktempdir()
        write(joinpath(proj, "views.jl"), """
            greet() = gettext("Hello")
            other() = t"World"
            cats(n) = ngettext("%(n)d cat", "%(n)d cats", n)
            book() = pgettext("verb", "Book")
            # gettext("not this one: a comment")
            """)
        mkpath(joinpath(proj, "templates"))
        write(joinpath(proj, "templates", "page.html"),
              "{% translate \"Title\" %}{% blocktranslate trimmed count n=k %}\n {{ n }} dog\n{% plural %}{{ n }} dogs{% endblocktranslate %}")
        out = makemessages("nl"; root = proj, locale_dir = joinpath(proj, "locale"))
        ids = Dict((e.context, e.msgid) => e for e in J.parse_po(read(out, String)))
        @test haskey(ids, ("", "Hello")) && haskey(ids, ("", "World")) && haskey(ids, ("verb", "Book")) && haskey(ids, ("", "Title"))
        @test ids[("", "%(n)d cat")].msgid_plural == "%(n)d cats" && ids[("", "%(n)s dog")].msgid_plural == "%(n)s dogs"
        @test !any(k -> occursin("comment", k[2]), keys(ids))
        write(out, replace(read(out, String), "msgid \"Hello\"\nmsgstr \"\"" => "msgid \"Hello\"\nmsgstr \"Hallo\""))
        makemessages("nl"; root = proj, locale_dir = joinpath(proj, "locale"))           # keeps translations
        @test occursin("msgstr \"Hallo\"", read(out, String))
        configure!(LOCALE_PATHS = [joinpath(proj, "locale")])
        @test only(compilemessages([joinpath(proj, "locale")])) == joinpath(dirname(out), "juango.mo")
        @test with_language(() -> gettext("Hello"), "nl") == "Hallo"
    finally
        configure!(LOCALE_PATHS = String[])
    end

    # choosing the language for a request
    hello(req) = HttpResponse(gettext("Save") * " " * reverse_url("i18n_hello") * " " * get_language())
    old_urls, old_mw = settings.ROOT_URLCONF, settings.MIDDLEWARE
    try
        configure!(ROOT_URLCONF = [i18n_patterns(path("hello/", hello; name = "i18n_hello")), path("i18n/", i18n_urls())],
                   MIDDLEWARE = vcat(old_mw, [LocaleMiddleware]))
        c = Client()
        r = get(c, "/de/hello/")
        @test text(r) == "Sichern /de/hello/ de" && getheader(r, "Content-Language") == "de"
        @test text(get(c, "/en/hello/")) == "Save /en/hello/ en"
        r = get(Client(; headers = Dict("Accept-Language" => "fr-CH, fr;q=0.9, de;q=0.8")), "/hello/")
        @test r.status == 302 && getheader(r, "Location") == "/fr/hello/"
        @test J.parse_accept_language("de;q=0.5, en-GB, *") == ["en-GB", "de"]
        r = post(c, "/i18n/setlang/", Dict("language" => "de", "next" => "/en/hello/"))
        @test r.status == 302 && getheader(r, "Location") == "/de/hello/" && c.cookies["juango_language"] == "de"
        @test getheader(get(c, "/hello/"), "Location") == "/de/hello/"                # the cookie wins now
        @test get(c, "/xx/hello/").status == 404
        configure!(ROOT_URLCONF = [i18n_patterns(path("hello/", hello; name = "i18n_hello"); prefix_default_language = false)])
        @test text(get(Client(), "/hello/")) == "Save /hello/ en" && text(get(Client(), "/de/hello/")) == "Sichern /de/hello/ de"
        @test get(Client(), "/en/hello/").status == 404

        # the admin in German
        configure!(ROOT_URLCONF = old_urls)
        ac = Client(; headers = Dict("Accept-Language" => "de"))
        force_login!(ac, root_user())
        r = get(ac, "/admin/")
        @test occursin("Website-Verwaltung", text(r)) && occursin("Neueste Aktionen", text(r)) && occursin("lang=\"de\"", text(r))
        @test occursin("Sichern und weiter bearbeiten", text(get(ac, "/admin/author/add/")))
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw)
    end
end

@testset "time zones" begin
    TZ = Juango.TimeZones
    utc, akl, tokyo = TZ.TimeZone("UTC"), TZ.TimeZone("Pacific/Auckland"), TZ.TimeZone("Asia/Tokyo")
    quiet(f) = redirect_stdout(f, devnull)
    # naive data written before USE_TZ, converted afterwards
    @eval @model struct TzEvent
        name = CharField(max_length = 20)
        at = DateTimeField(null = true)
        Meta(table = "tz_event", app_label = "tztest")
    end
    quiet(() -> Juango.sync_models!([TzEvent]))
    old = create(TzEvent; name = "old", at = DateTime(2024, 1, 1, 12))     # Auckland wall-clock time, naive
    configure!(USE_TZ = true, TIME_ZONE = "Pacific/Auckland")
    try
        @test quiet(() -> convert_naive_datetimes(; from_tz = "Pacific/Auckland")) >= 1
        @test get(TzEvent; id = old.id).at == TZ.ZonedDateTime(2023, 12, 31, 23, utc)

        # aware values in, UTC stored, aware values out
        au = create(Author; name = "TZ Author")
        a = create(Article; title = "tz", author = au)
        @test a.created isa TZ.ZonedDateTime && TZ.timezone(a.created) == utc
        @test abs(get(Article; id = a.id).created - timezone_now()) < Dates.Minute(1)
        e = create(TzEvent; name = "naive", at = DateTime(2024, 6, 1, 12))      # naive: taken as Auckland time
        @test get(TzEvent; id = e.id).at == TZ.ZonedDateTime(2024, 6, 1, 0, utc)
        ny = create(TzEvent; name = "ny", at = TZ.ZonedDateTime(2024, 6, 1, 12, TZ.TimeZone("America/New_York")))
        @test get(TzEvent; id = ny.id).at == TZ.ZonedDateTime(2024, 6, 1, 16, utc)
        @test [x.name for x in order_by(filter(TzEvent; at__gt = TZ.ZonedDateTime(2024, 6, 1, 1, utc)), "name")] == ["ny"]
        @test count(filter(TzEvent; at__lt = DateTime(2024, 6, 1, 12, 30))) == 2          # naive bound in Auckland time

        # shown in the current time zone
        ctx = Dict("t" => TZ.ZonedDateTime(2024, 6, 1, 0, utc))
        @test tr("{{ t|date:\"Y-m-d H:i T\" }}", ctx) == "2024-06-01 12:00 NZST"
        @test with_timezone(() -> tr("{{ t|date:\"H:i e O\" }}", ctx), "Asia/Tokyo") == "09:00 Asia/Tokyo +0900"
        @test tr("{% timezone \"Europe/London\" %}{{ t|date:\"H:i T\" }}{% endtimezone %} {{ t|date:\"H:i\" }}", ctx) == "01:00 BST 12:00"
        @test tr("{% localtime off %}{{ t|date:\"H:i\" }}{% endlocaltime %} {{ t|utc|date:\"H:i e\" }}", ctx) == "00:00 00:00 UTC"
        @test tr("{{ t|timezone:\"Asia/Tokyo\"|date:\"H:i\" }}", ctx) == "09:00"
        @test Juango.timesince(timezone_now() - Dates.Hour(3)) == "3 hours"
        @test make_naive(TZ.ZonedDateTime(2024, 6, 1, 0, utc)) == DateTime(2024, 6, 1, 12)
        @test make_aware(DateTime(2024, 6, 1, 12)) == TZ.ZonedDateTime(2024, 6, 1, 12, akl)
        @test get_current_timezone() == akl && with_timezone(get_current_timezone, tokyo) == tokyo && get_current_timezone() == akl

        # forms read and show times in the current time zone
        @eval @form TzForm begin
            when = DateTimeField()
        end
        f = TzForm(Dict("when" => "2024-01-01T12:00"))
        @test is_valid(f) && f.cleaned_data[:when] == TZ.ZonedDateTime(2023, 12, 31, 23, utc)
        f = with_timezone(() -> (g = TzForm(Dict("when" => "2024-01-01T12:00")); is_valid(g); g), "Asia/Tokyo")
        @test f.cleaned_data[:when] == TZ.ZonedDateTime(2024, 1, 1, 3, utc)
        @test occursin("value=\"2024-06-01T12:00\"", string(as_p(TzForm(; initial = Dict(:when => TZ.ZonedDateTime(2024, 6, 1, 0, utc))))))

        # sessions, logins and the admin keep working with aware times
        c = Client()
        force_login!(c, root_user())
        @test get(c, "/admin/").status == 200 && root_user().date_joined isa TZ.ZonedDateTime
        r = get(c, "/admin/article/$(a.id)/change/")
        @test r.status == 200 && occursin(r"NZ[SD]T", text(r))

        # TimezoneMiddleware activates the session's time zone
        mw = TimezoneMiddleware(req -> HttpResponse(string(get_current_timezone())))
        req = Request("GET", "/"); req.session = Juango.Session(); req.session["juango_timezone"] = "Asia/Tokyo"
        @test text(mw(req)) == "Asia/Tokyo"
        req.session["juango_timezone"] = "Not/AZone"
        @test text(mw(req)) == "Pacific/Auckland"
    finally
        configure!(USE_TZ = false, TIME_ZONE = "UTC")
        Juango.unregister_model!(TzEvent)
        Juango.execute("DROP TABLE " * Juango.qname("tz_event"))
    end
    @test !(get(Article; title = "tz").created isa TZ.ZonedDateTime)      # naive again without USE_TZ
end
