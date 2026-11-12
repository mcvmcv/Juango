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

    # STARTTLS and implicit TLS, against a fake server with a self-signed certificate
    if Sys.which("openssl") !== nothing
        TCP, TLS = Juango.TCP, Juango.TLS
        dir = mktempdir()
        cert, key = joinpath(dir, "cert.pem"), joinpath(dir, "key.pem")
        run(pipeline(`openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=127.0.0.1
                      -addext subjectAltName=IP:127.0.0.1 -keyout $key -out $cert`; stderr = devnull))
        tls_config = TLS.Config(; cert_file = cert, key_file = key)
        function fake_tls_smtp(implicit)
            listener = TCP.listen(TCP.loopback_addr(0))
            lines = String[]
            task = @async begin
                conn = TCP.accept(listener)
                io = implicit ? TLS.server(conn, tls_config) : conn
                try
                    write(io, "220 fake ESMTP\r\n")
                    indata = false
                    while true
                        l = readline(io)
                        push!(lines, l)
                        if indata
                            l == "." && (indata = false; write(io, "250 queued\r\n"))
                        elseif startswith(l, "EHLO")
                            write(io, io isa TLS.Conn ? "250 fake\r\n" : "250-fake\r\n250 STARTTLS\r\n")
                        elseif l == "STARTTLS"
                            write(io, "220 go ahead\r\n")
                            io = TLS.server(conn, tls_config)
                        elseif startswith(l, "DATA")
                            indata = true; write(io, "354 go\r\n")
                        elseif startswith(l, "QUIT")
                            write(io, "221 bye\r\n"); break
                        elseif isempty(l) && eof(io)
                            break
                        else
                            write(io, "250 ok\r\n")
                        end
                    end
                catch
                finally
                    close(io); close(listener)
                end
            end
            Int(TCP.addr(listener).port), lines, task
        end
        for implicit in (false, true)
            port, lines, task = fake_tls_smtp(implicit)
            configure!(EMAIL_BACKEND = :smtp, EMAIL_HOST = "127.0.0.1", EMAIL_PORT = port,
                       EMAIL_USE_TLS = !implicit, EMAIL_USE_SSL = implicit, EMAIL_TIMEOUT = 10)
            try
                # the certificate is only trusted when we say so
                @test withenv(() -> send_mail("TLS test", "secret", "from@x.io", ["to@x.io"]),
                              "JULIA_SSL_CA_ROOTS_PATH" => cert) == 1
                wait(task)
                @test "Subject: TLS test" in lines && "QUIT" in lines
                @test implicit || "STARTTLS" in lines
            finally
                configure!(EMAIL_BACKEND = :locmem, EMAIL_USE_TLS = false, EMAIL_USE_SSL = false, EMAIL_TIMEOUT = nothing)
            end
        end
        port, lines, task = fake_tls_smtp(true)        # an untrusted certificate is refused
        configure!(EMAIL_BACKEND = :smtp, EMAIL_HOST = "127.0.0.1", EMAIL_PORT = port, EMAIL_USE_SSL = true, EMAIL_TIMEOUT = 10)
        try
            @test_throws Exception send_mail("TLS test", "secret", "from@x.io", ["to@x.io"])
        finally
            configure!(EMAIL_BACKEND = :locmem, EMAIL_USE_SSL = false, EMAIL_TIMEOUT = nothing)
        end
        @test !("Subject: TLS test" in lines)
    end

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
        cache_set("short", 1; timeout = 0.3); cache_set("never", 1; timeout = 0)
        @test cache_has("short") && !cache_has("never")
        sleep(0.4)
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
        cache_set("brief", 1; timeout = 0.3, cache_name = "db"); sleep(0.4)
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
        sleep(0.05); write(joinpath(tdir, "cached.html"), "v2")    # mtimes have sub-ms resolution
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

# An authentication backend: a secret token logs "tokenuser" in, and authors may change their own articles.
struct TokenBackend end
Juango.backend_authenticate(::TokenBackend, req; token = nothing, kw...) =
    token == "letmein" ? first(filter(objects(get_user_model()); username = "tokenuser")) :
    token == "blocked" ? throw(PermissionDenied("no")) : nothing
Juango.backend_get_user(::TokenBackend, id) = first(filter(objects(get_user_model()); id = id))
Juango.backend_has_perm(::TokenBackend, u, perm, obj) =
    perm == "project.change_article" && obj isa Article && obj.author.name == u.username ? true : nothing
Juango.backend_get_all_permissions(::TokenBackend, u, obj) =
    obj isa Article && obj.author.name == u.username ? Set(["project.change_article"]) : Set{String}()

@model struct Member <: AbstractUser
    nickname = CharField(max_length = 20, blank = true)
    Meta(table = "cu_member", app_label = "project")
end
Juango.username_field(::Type{Member}) = :email

@testset "authentication backends and custom user models" begin
    tu = create_user("tokenuser", "token-pw-123")
    mine = create(Article; title = "tokens", author = create(Author; name = "tokenuser"))
    other = create(Article; title = "not mine", author = ann_author())
    try
        configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend(), TokenBackend()])
        @test authenticate(; token = "letmein").id == tu.id
        @test authenticate(; token = "wrong") === nothing && authenticate(; token = "blocked") === nothing
        @test authenticate("tokenuser", "token-pw-123").id == tu.id && authenticate("tokenuser", "nope") === nothing
        # per-object permissions come from the backend; ModelBackend adds none per object
        @test has_perm(tu, "project.change_article"; obj = mine) && !has_perm(tu, "project.change_article"; obj = other)
        @test !has_perm(tu, "project.change_article")
        @test get_all_permissions(tu; obj = mine) == Set(["project.change_article"]) && isempty(get_all_permissions(tu))
        # the session remembers the backend; removing it from the settings logs the user out
        c = Client()
        force_login!(c, tu; backend = TokenBackend())
        @test text(get(c, "/whoami/")) == "user:tokenuser"
        configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend()])
        @test text(get(c, "/whoami/")) == "anon"
        configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend(), TokenBackend()])
        @test text(get(c, "/whoami/")) == "user:tokenuser"
        # logging in through the login view stores the backend that accepted the password
        c2 = Client()
        post(c2, "/accounts/login/", Dict("username" => "tokenuser", "password" => "token-pw-123"))
        @test text(get(c2, "/whoami/")) == "user:tokenuser"
    finally
        configure!(AUTHENTICATION_BACKENDS = Any[ModelBackend()])
    end

    # a custom user model that logs in with its email
    try
        configure!(AUTH_USER_MODEL = "project.Member")
        @test get_user_model() === Member && Juango.is_swapped(User) && !Juango.model_in_use(User)
        redirect_stdout(() -> migrate(verbose = false), devnull)
        m = create_user("m@example.com", "member-pw-1"; nickname = "Em")
        @test m isa Member && m.email == "m@example.com" && m.username == "m@example.com"
        @test authenticate("m@example.com", "member-pw-1").id == m.id && authenticate(; email = "m@example.com", password = "x") === nothing
        g = create(Group; name = "members-group")
        add!(m.groups, g)
        add!(g.permissions, get(Permission; codename = "view_article"))
        @test [u.nickname for u in g.user_set] == ["Em"] && has_perm(get(Member; id = m.id), "project.view_article")
        @test Juango.related_model(Juango.findfield(Juango.modelmeta(LogEntry), :user)) === Member
        c = Client()
        force_login!(c, m)
        @test text(get(c, "/whoami/")) == "user:m@example.com"
        Admin.register_user_model!()
        @test Admin.is_registered(Member) && !Admin.is_registered(User)
        @test_throws Juango.ImproperlyConfigured (configure!(AUTH_USER_MODEL = Article); get_user_model())
    finally
        configure!(AUTH_USER_MODEL = User)
        Admin.unregister!(Member)
        Admin.register_user_model!()
    end
    @test get_user_model() === User && Admin.is_registered(User) && Juango.model_in_use(User)
end

@testset "password hashers, validators and password change" begin
    # the algorithms against published test vectors
    @test bytes2hex(Juango.blake2b(Vector{UInt8}(codeunits("abc")))) ==
          "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
    tag = Juango.argon2id(fill(0x01, 32), fill(0x02, 16); t = 3, m = 32, p = 4, len = 32, secret = fill(0x03, 8), ad = fill(0x04, 12))
    @test bytes2hex(tag) == "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"     # RFC 9106, 5.3
    @test Juango.bcrypt("U*U", "CCCCCCCCCCCCCCCCCCCCC.", 5)[4:end] == "\$05\$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW"
    @test Juango.bcrypt("", "DCq7YPn5Rq63x1Lad4cll.", 6)[4:end] == "\$06\$DCq7YPn5Rq63x1Lad4cll.TV4S6ytwfsfvkgY8jIucDrjc8deX1s."

    small = Any[Argon2Hasher(time_cost = 1, memory_cost = 64, parallelism = 2), BCryptSHA256Hasher(rounds = 4),
                BCryptHasher(rounds = 4), PBKDF2Hasher(iterations = 1000)]
    for h in small
        e = make_password("s3cret-pass"; hasher = h)
        @test startswith(e, Juango.algorithm(h) * "\$")
        configure!(PASSWORD_HASHERS = small)
        @test check_password("s3cret-pass", e) && !check_password("wrong", e)
    end
    @test occursin(r"^argon2\$argon2id\$v=19\$m=64,t=1,p=2\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$", make_password("x"; hasher = small[1]))
    @test occursin(r"^bcrypt_sha256\$\$2b\$04\$[./A-Za-z0-9]{53}$", make_password("x"; hasher = small[2]))

    # a password stored by an older hasher is upgraded at the next login
    configure!(PASSWORD_HASHERS = Any[PBKDF2Hasher(iterations = 1000)])
    u = create_user("hasheruser", "first-pass-123")
    @test startswith(u.password, "pbkdf2_sha256\$1000\$")
    configure!(PASSWORD_HASHERS = small)
    @test authenticate("hasheruser", "first-pass-123") !== nothing
    @test startswith(get(User; id = u.id).password, "argon2\$") && Juango.has_usable_password(get(User; id = u.id))
    configure!(PASSWORD_HASHERS = Any[Argon2Hasher(time_cost = 2, memory_cost = 64, parallelism = 2)])
    @test authenticate("hasheruser", "first-pass-123") !== nothing
    @test occursin("t=2", get(User; id = u.id).password)                 # stronger settings re-hash too
    configure!(PASSWORD_HASHERS = Any[PBKDF2Hasher()])
    @test authenticate("hasheruser", "first-pass-123") === nothing        # argon2 isn't accepted any more

    # validators
    configure!(PASSWORD_HASHERS = Any[PBKDF2Hasher(iterations = 1000)])
    @test validate_password("short") == ["This password is too short. It must contain at least 8 characters."]
    @test validate_password("12345678") == ["This password is entirely numeric."] && isempty(validate_password("a good long one"))
    all4 = Any[MinimumLengthValidator(min_length = 6), CommonPasswordValidator(), NumericPasswordValidator(),
               UserAttributeSimilarityValidator()]
    try
        configure!(AUTH_PASSWORD_VALIDATORS = all4)
        @test validate_password("Password123") == ["This password is too common."]
        person = (username = "alicewonder", first_name = "", last_name = "", email = "alice@example.com")
        @test validate_password("alicewonder1"; user = person) == ["The password is too similar to the username."]
        @test validate_password("Alice12"; user = person) == ["The password is too similar to the email."]
        @test isempty(validate_password("tangerine-kayak-77"; user = person))
        @test Juango.similarity("abcd", "bcde") ≈ 0.75 && Juango.similarity("", "") == 1.0
    finally
        configure!(AUTH_PASSWORD_VALIDATORS = Any[MinimumLengthValidator(), NumericPasswordValidator()])
    end

    # UserCreationForm / UserChangeForm
    f = UserCreationForm(Dict("username" => "signup", "password1" => "123", "password2" => "123"))
    @test !is_valid(f) && occursin("too short", join(f.errors[:password2])) && occursin("entirely numeric", join(f.errors[:password2]))
    f = UserCreationForm(Dict("username" => "signup", "password1" => "tangerine-kayak-77", "password2" => "tangerine-kayak-78"))
    @test !is_valid(f) && f.errors[:password2] == ["The two password fields didn’t match."]
    @test !is_valid(UserCreationForm(Dict("username" => "changer0", "password1" => "", "password2" => "")))
    f = UserCreationForm(Dict("username" => "signup", "password1" => "tangerine-kayak-77", "password2" => "tangerine-kayak-77"))
    @test is_valid(f)
    su = save!(f)
    @test su.id !== nothing && authenticate("signup", "tangerine-kayak-77") == su
    @test startswith(Juango.password_summary(su), "algorithm: pbkdf2_sha256 iterations: 1000 salt: ") &&
          !occursin(split(su.password, '\$')[4], Juango.password_summary(su))
    @test Juango.password_summary("!unusable") == "No password set."
    @test is_valid(UserCreationForm(Dict("username" => "signup", "password1" => "tangerine-kayak-77", "password2" => "tangerine-kayak-77"))) == false   # username taken
    cf = UserChangeForm(Dict("username" => "signup2", "email" => "s@x.io", "is_active" => "on"); instance = su)
    @test !any(fl -> fl.name === :password, cf.fields) && is_valid(cf)
    save!(cf)
    @test refresh!(su).username == "signup2" && authenticate("signup2", "tangerine-kayak-77") == su

    # changing the password keeps this session and ends the others
    pu = create_user("changer", "old-password-1")
    c, other = Client(), Client()
    force_login!(c, pu); force_login!(other, pu)
    @test get(c, "/accounts/password_change/").status == 200
    @test get(Client(), "/accounts/password_change/").status == 302              # login required
    r = post(c, "/accounts/password_change/", Dict("old_password" => "nope", "new_password1" => "new-password-2", "new_password2" => "new-password-2"))
    @test r.status == 200 && occursin("Your old password was entered incorrectly", text(r))
    r = post(c, "/accounts/password_change/", Dict("old_password" => "old-password-1", "new_password1" => "123", "new_password2" => "123"))
    @test r.status == 200 && occursin("too short", text(r)) && occursin("entirely numeric", text(r))
    r = post(c, "/accounts/password_change/", Dict("old_password" => "old-password-1", "new_password1" => "new-password-2", "new_password2" => "other"))
    @test occursin("didn’t match", text(r))
    r = post(c, "/accounts/password_change/", Dict("old_password" => "old-password-1", "new_password1" => "new-password-2", "new_password2" => "new-password-2"))
    @test r.status == 302 && getheader(r, "Location") == "/accounts/password_change/done/"
    @test occursin("Password change successful", text(get(c, "/accounts/password_change/done/")))
    @test text(get(c, "/whoami/")) == "user:changer" && text(get(other, "/whoami/")) == "anon"
    @test authenticate("changer", "new-password-2") !== nothing && authenticate("changer", "old-password-1") === nothing
end

@testset "file and signed-cookie sessions" begin
    sdir = mktempdir()
    try
        configure!(SESSION_ENGINE = :file, SESSION_FILE_PATH = sdir)
        s = Juango.Session(); s["cart"] = [1, 2]
        Juango.save_session!(s)
        @test isfile(joinpath(sdir, "juangosess" * s.key)) && Juango.load_session(s.key)["cart"] == [1, 2]
        @test isempty(Juango.load_session("../../etc/passwd")) && isempty(Juango.load_session("nosuchsessionkey00000000"))
        old = s.key
        Juango.cycle_key!(s); Juango.save_session!(s)
        @test !isfile(joinpath(sdir, "juangosess" * old)) && Juango.load_session(s.key)["cart"] == [1, 2]
        # an expired file is ignored and removed by clearsessions
        write(joinpath(sdir, "juangosess" * "a"^32), JSON.json(Dict("expire" => time() - 1, "data" => Dict("x" => 1))))
        @test isempty(Juango.load_session("a"^32)) && Juango.clear_expired_sessions!() == 1
        @test isfile(joinpath(sdir, "juangosess" * s.key))
        c = Client()
        force_login!(c, root_user())
        @test get(c, "/admin/").status == 200 && length(readdir(sdir)) == 2
        k = s.key
        Juango.flush!(s)
        @test !isfile(joinpath(sdir, "juangosess" * k))

        configure!(SESSION_ENGINE = :signed_cookies)
        s = Juango.Session(); s["n"] = 7
        Juango.save_session!(s)
        @test Juango.load_session(s.key)["n"] == 7
        tampered = s.key[1:end-1] * (s.key[end] == 'A' ? "B" : "A")
        @test isempty(Juango.load_session(tampered))
        @test Juango.clear_expired_sessions!() == 0
        c = Client()
        force_login!(c, root_user())
        @test get(c, "/admin/").status == 200
        r = post(c, "/accounts/logout/")                         # the cookie is all there is
        @test get(c, "/admin/").status == 302
        c2 = Client()
        post(c2, "/accounts/login/", Dict("username" => "root", "password" => "rootpw"))
        @test text(get(c2, "/whoami/")) == "user:root"
        @test !exists(filter(Juango.SessionRecord; session_key = c2.cookies[settings.SESSION_COOKIE_NAME]))
    finally
        configure!(SESSION_ENGINE = :db, SESSION_FILE_PATH = nothing)
    end
end

@testset "logging" begin
    mem, sqlmem = MemoryHandler(), MemoryHandler()
    logfile = joinpath(mktempdir(), "site.log")
    conf = Dict(
        "handlers" => Dict("mem" => Dict("class" => mem, "level" => "WARNING"),
                           "sql" => Dict("class" => sqlmem),
                           "file" => Dict("class" => "file", "filename" => logfile, "level" => "ERROR", "format" => "{levelname}|{name}|{message}"),
                           "mail" => Dict("class" => "mail_admins", "level" => "ERROR", "filters" => ["require_debug_false"])),
        "loggers" => Dict("juango.db.backends" => Dict("handlers" => ["sql"], "level" => "DEBUG", "propagate" => false),
                          "juango.request" => Dict("handlers" => ["mail", "file"], "level" => "WARNING"),
                          "quiet" => Dict("handlers" => String[], "level" => "ERROR", "propagate" => false)),
        "root" => Dict("handlers" => ["mem"], "level" => "INFO"))
    override_settings(LOGGING = conf, ADMINS = [("Admin", "admin@example.com")], ALLOWED_HOSTS = ["testserver"]) do
        log!("myapp.sub", :info, "too low for the handler")
        log!("myapp.sub", :warning, "careful"; order = 7)
        @test length(mem.records) == 1 && mem.records[1].name == "myapp.sub" && mem.records[1].data[:order] == 7
        log!("quiet", :warning, "dropped")                          # below the logger's own level
        @test length(mem.records) == 1 && !log_enabled("quiet", :warning) && log_enabled("myapp", :info)
        # every SQL statement, with its duration, on juango.db.backends (and not propagated)
        count(objects(Topic))
        @test any(r -> occursin("SELECT COUNT(*)", r.message) && haskey(r.data, :duration), sqlmem.records)
        @test !any(r -> r.name == "juango.db.backends", mem.records)
        # requests: 4xx warnings, 5xx errors (mailed to ADMINS when DEBUG is false)
        c = Client()
        get(c, "/no-such-page/")
        @test any(r -> r.message == "Not Found: /no-such-page/" && r.level == 30 && r.data[:status_code] == 404, mem.records)
        empty!(Juango.outbox)
        override_settings(DEBUG = false) do
            @test get(c, "/boom/").status == 500
        end
        err = only(filter(r -> r.level == 40, mem.records))
        @test err.name == "juango.request" && err.exception !== nothing && err.data[:request] isa Request
        @test endswith(only(Juango.outbox).subject, "ERROR: Internal Server Error: /boom/") && occursin("GET /boom/", only(Juango.outbox).body)
        @test startswith(read(logfile, String), "ERROR|juango.request|Internal Server Error: /boom/")
        # CSRF failures on juango.security.csrf
        post(Client(; enforce_csrf = true), "/contact/", Dict("name" => "x"))
        @test any(r -> r.name == "juango.security.csrf" && occursin("CSRF", r.message), mem.records)
        @test_throws Juango.ImproperlyConfigured (configure!(LOGGING = Dict("root" => Dict("handlers" => ["nope"]))); log!("x", :error, "y"))
    end
    # the default: a 500 with DEBUG on isn't mailed
    empty!(Juango.outbox)
    override_settings(ADMINS = [("Admin", "admin@example.com")]) do
        redirect_stderr(devnull) do
            get(Client(), "/boom/")
        end
    end
    @test isempty(Juango.outbox)
end

@background function add_numbers(a, b; times = 1)
    (a + b) * times
end
@background queue_name = "mail" priority = 5 function failing_task(msg)
    error("task failed: $msg")
end

@testset "background tasks" begin
    @test add_numbers(1, 2) == 3                                          # calling it just runs it
    r = enqueue(add_numbers, 2, 3; times = 2)                             # the immediate backend
    @test r.status === :successful && r.return_value == 10 && r.started_at !== nothing
    r = redirect_stderr(() -> enqueue(failing_task, "x"), devnull)
    @test r.status === :failed && occursin("task failed: x", r.error) && r.queue_name == "mail" && r.priority == 5
    @test_throws ArgumentError enqueue(add_numbers, 1, 2; run_after = now() + Hour(1))

    override_settings(TASKS = Dict("default" => Dict("backend" => :dummy))) do
        empty!(dummy_results())
        r = enqueue(add_numbers, 1, 1)
        @test r.status === :ready && dummy_results() == [r] && r.return_value === nothing
    end
    override_settings(TASKS = Dict("default" => Dict("backend" => :dummy, "queues" => ["default"]))) do
        @test_throws ArgumentError enqueue(failing_task, "y")              # not one of the backend's queues
    end

    old_apps = settings.INSTALLED_APPS
    try
        configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.tasks"]),
                   TASKS = Dict("default" => Dict("backend" => :database)))
        redirect_stdout(() -> migrate(verbose = false), devnull)
        r1 = enqueue(add_numbers, 1, 2)
        r2 = enqueue(failing_task, "z")                                   # priority 5: runs first
        r3 = enqueue(add_numbers, 5, 5; run_after = now() + Hour(1))      # not yet
        @test r1.status === :ready && get_result(r1.id).status === :ready
        @test redirect_stderr(() -> db_worker(; stop_when_empty = true), devnull) == 2
        @test Juango.refresh!(r1).status === :successful && r1.return_value == 3 && r1.finished_at !== nothing
        g2 = get_result(r2.id)
        @test g2.status === :failed && occursin("task failed: z", g2.error) && g2.started_at <= get_result(r1.id).started_at
        @test get_result(r3.id).status === :ready && db_worker(; stop_when_empty = true) == 0
        r4 = enqueue(add_numbers, 1, 1; queue_name = "other")
        @test db_worker(; queues = ["default"], stop_when_empty = true) == 0 && db_worker(; queues = ["other"], max_tasks = 1) == 1
    finally
        configure!(INSTALLED_APPS = old_apps, TASKS = Dict("default" => Dict("backend" => :immediate)))
    end
end
