# Django's sessions tests, ported (#227): tests/sessions_tests.
# julia --project=test test/django_sessions.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

djs_set(req; kw...) = (req.session["hello"] = "world"; HttpResponse("set"))
djs_flush(req; kw...) = (Juango.flush!(req.session); HttpResponse("flushed"))
djs_read(req; kw...) = HttpResponse(string(get(req.session, "hello", "-")))
djs_500(req; kw...) = (req.session["hello"] = "world"; HttpResponse("boom"; status = 500))
djs_expiry(req; kw...) = (set_expiry!(req.session, parse(Int, req.GET["s"])); req.session["x"] = 1; HttpResponse("ok"))

@testset "django sessions: SessionTestsMixin" begin
    for engine in (:db, :cache, :cached_db, :file, :signed_cookies)
        old = Juango.settings.SESSION_ENGINE
        configure!(SESSION_ENGINE = engine)
        try
            # test_new_session, test_get_empty, test_store, test_pop, test_pop_default, test_setdefault, test_update,
            # test_has_key, test_values, test_keys, test_items, test_clear
            s = Juango.Session()
            @test !s.modified && isempty(s) && get(s, "cat", nothing) === nothing
            s["cat"] = "dog"
            @test s.modified && pop!(s, "cat", nothing) == "dog" && pop!(s, "some key", "does not exist") == "does not exist"
            @test get!(s, "foo", "bar") == "bar" && get!(s, "foo", "baz") == "bar"
            merge!(s, Dict("update key" => 1))
            @test s["update key"] == 1 && haskey(s, "foo") && !haskey(s, "nope")
            @test Set(keys(s)) == Set(["foo", "update key"])
            empty!(s)
            @test isempty(s) && s.modified
            # test_save, test_delete, test_flush, test_cycle, test_save_doesnt_clear_data
            s["a"] = "b"
            Juango.save_session!(s)
            key = s.key
            @test Juango.load_session(key)["a"] == "b"
            Juango.cycle_key!(s)
            Juango.save_session!(s)
            # (signed cookies: the key is the data, signed; it can't be revoked, so Django skips this, CookieSessionTests.test_cycle)
            @test (engine === :signed_cookies || s.key != key) && Juango.load_session(s.key)["a"] == "b"
            engine === :signed_cookies || @test !haskey(Juango.load_session(key), "a")        # (the old key is gone)
            Juango.flush!(s)
            @test s.key === nothing && isempty(s)
            # test_invalid_key, test_session_key_too_short_invalid, test_session_key_empty_string_invalid
            @test isempty(Juango.load_session("1234567")) && isempty(Juango.load_session("")) && isempty(Juango.load_session("0"^40))
            # test_default_expiry, test_custom_expiry_seconds, test_custom_expiry_timedelta, test_custom_expiry_datetime,
            # test_custom_expiry_reset, test_get_expire_at_browser_close
            s = Juango.Session()
            age = Juango.settings.SESSION_COOKIE_AGE
            @test get_expiry_age(s) == age && abs(Dates.value(get_expiry_date(s) - (Juango.timezone_now() + Second(age)))) < 2000
            set_expiry!(s, 10)
            @test get_expiry_age(s) == 10
            set_expiry!(s, Dates.Second(10))
            @test get_expiry_age(s) == 10
            future = Juango.timezone_now() + Second(10)
            set_expiry!(s, future)
            @test 9 <= get_expiry_age(s) <= 10
            set_expiry!(s, nothing)
            @test get_expiry_age(s) == age
            @test !get_expire_at_browser_close(s)
            set_expiry!(s, 0); @test get_expire_at_browser_close(s)
            set_expiry!(s, 10); @test !get_expire_at_browser_close(s)
            set_expiry!(s, nothing)
            configure!(SESSION_EXPIRE_AT_BROWSER_CLOSE = true)
            @test get_expire_at_browser_close(s)
            set_expiry!(s, 10); @test !get_expire_at_browser_close(s)
            configure!(SESSION_EXPIRE_AT_BROWSER_CLOSE = false)
            # SessionBaseTests.test_test_cookie, test_is_empty
            s = Juango.Session()
            @test Juango.is_empty(s)
            set_test_cookie!(s); @test test_cookie_worked(s)
            delete_test_cookie!(s); @test !test_cookie_worked(s)
        finally
            configure!(SESSION_ENGINE = old, SESSION_EXPIRE_AT_BROWSER_CLOSE = false)
        end
    end
    # (a :db session saved with a custom expiry keeps it in its row)
    configure!(SESSION_ENGINE = :db)
    s = Juango.Session(); set_expiry!(s, 60); s["k"] = 1; Juango.save_session!(s)
    rec = get(Juango.SessionRecord; session_key = s.key)
    @test 55 <= round(Int, Dates.value(convert(Dates.Millisecond, rec.expire_date - Juango.timezone_now())) / 1000) <= 60
end

@testset "django sessions: SessionMiddlewareTests" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("set/", djs_set), path("flush/", djs_flush), path("read/", djs_read), path("boom/", djs_500),
                               path("expiry/", djs_expiry)])
    cookie(r) = (h = filter(x -> startswith(x, "sessionid="), r.cookies); isempty(h) ? nothing : h[1])
    try
        c = Client()
        r = get(c, "/set/")
        sc = cookie(r)
        # test_httponly_session_cookie, test_samesite_session_cookie, test_secure_session_cookie
        @test sc !== nothing && occursin("HttpOnly", sc) && occursin("SameSite=Lax", sc) && !occursin("Secure", sc) && occursin("Max-Age=", sc)
        configure!(SESSION_COOKIE_SECURE = true, SESSION_COOKIE_SAMESITE = "Strict", SESSION_COOKIE_HTTPONLY = false)
        sc = cookie(get(Client(), "/set/"))
        @test occursin("Secure", sc) && occursin("SameSite=Strict", sc) && !occursin("HttpOnly", sc)  # test_no_httponly_session_cookie
        configure!(SESSION_COOKIE_SECURE = false, SESSION_COOKIE_SAMESITE = "Lax", SESSION_COOKIE_HTTPONLY = true)
        # test_session_save_on_500, test_session_save_on_5xx (a failed response doesn't save the session)
        @test cookie(get(Client(), "/boom/")) === nothing
        # test_session_delete_on_end, test_session_delete_on_end_with_custom_domain_and_path
        @test text(get(c, "/read/")) == "world"
        sc = cookie(get(c, "/flush/"))
        @test sc !== nothing && occursin("Max-Age=0", sc)
        c = Client(); get(c, "/set/")
        configure!(SESSION_COOKIE_DOMAIN = ".example.local", SESSION_COOKIE_PATH = "/example/")
        sc = cookie(get(c, "/flush/"))
        @test occursin("Domain=.example.local", sc) && occursin("Path=/example/", sc)
        configure!(SESSION_COOKIE_DOMAIN = nothing, SESSION_COOKIE_PATH = "/")
        # test_flush_empty_without_session_cookie_doesnt_set_cookie
        @test cookie(get(Client(), "/flush/")) === nothing
        # test_empty_session_saved (nothing stored: no cookie)
        @test cookie(get(Client(), "/read/")) === nothing
        # test_save_every_request_with_non_empty_session_renews_session_cookie
        c = Client(); get(c, "/set/")
        @test cookie(get(c, "/read/")) === nothing
        configure!(SESSION_SAVE_EVERY_REQUEST = true)
        @test cookie(get(c, "/read/")) !== nothing
        configure!(SESSION_SAVE_EVERY_REQUEST = false)
        # (set_expiry(0): a browser-session cookie, without Max-Age)
        sc = cookie(get(Client(), "/expiry/?s=0"))
        @test sc !== nothing && !occursin("Max-Age", sc)
        sc = cookie(get(Client(), "/expiry/?s=300"))
        @test occursin("Max-Age=300", sc)
        # not translated: the backend classes' internals (CustomDatabaseSession, the cache failure tests), logging
    finally
        configure!(ROOT_URLCONF = old_urls, SESSION_COOKIE_SECURE = false, SESSION_COOKIE_SAMESITE = "Lax", SESSION_COOKIE_HTTPONLY = true,
                   SESSION_COOKIE_DOMAIN = nothing, SESSION_COOKIE_PATH = "/", SESSION_SAVE_EVERY_REQUEST = false)
    end
end
