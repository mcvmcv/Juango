# Django's cache tests, ported (#227): tests/cache (BaseCacheTests run against the locmem, database
# and file backends; DummyCacheTests; LocMemCacheTests; a few of CacheMiddlewareTest's cache_page tests).
# julia --project=test test/django_cache.jl   (see setup.jl)
#
# Juango's cache API is functions with a cache_name (cache_get(k; cache_name)), not cache objects.
# Differences kept: incr/incr_version of a missing key throw KeyError (Django: ValueError), and keys
# memcached can't store (spaces, more than 250 characters) are hashed instead of warned about.
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DchPoll
    question = CharField(max_length = 200)
    answer = CharField(max_length = 200, default = "")
    Meta(table = "dch_poll")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DchPoll]); push!(PORT_MODELS, DchPoll)
end

dch_custom_key(key, prefix, version) = "CUSTOM-" * join([prefix, string(version), key], "-")

"BaseCacheTests for one backend: `opts` are the backend's options, the aliases are prefixed with `n`."
function dch_base(n, opts)
    D, P, V2, CK, CULL, ZERO = n, n * "_prefix", n * "_v2", n * "_custom", n * "_cull", n * "_zero"
    g(k, d = nothing; c = D, kw...) = cache_get(k, d; cache_name = c, kw...)
    s(k, v; c = D, kw...) = cache_set(k, v; cache_name = c, kw...)
    @testset "BaseCacheTests ($n)" begin
        s("key", "value")                                                                 # test_simple
        @test g("key") == "value"
        s("key_default_none", nothing)                                                    # test_default_used_when_none_is_set
        @test g("key_default_none", "default") === nothing
        s("addkey1", "value")                                                             # test_add
        @test cache_add("addkey1", "newvalue"; cache_name = D) == false && g("addkey1") == "value"
        @test cache_add("addkey2", "new"; cache_name = D) == true && g("addkey2") == "new"
        s("somekey", "value")                                                             # test_prefix
        @test !cache_has("somekey"; cache_name = P)
        s("somekey", "value2"; c = P)
        @test g("somekey") == "value" && g("somekey"; c = P) == "value2"
        @test g("does_not_exist") === nothing && g("does_not_exist", "bang!") == "bang!"  # test_non_existent
        s("a", "a"); s("b", "b"); s("c", "c"); s("d", "d")                                 # test_get_many
        @test cache_get_many(["a", "c", "d"]; cache_name = D) == Dict("a" => "a", "c" => "c", "d" => "d")
        @test cache_get_many(["a", "b", "e"]; cache_name = D) == Dict("a" => "a", "b" => "b")
        @test cache_get_many(String[]; cache_name = D) == Dict()
        s("key1", "spam"); s("key2", "eggs")                                              # test_delete
        @test cache_delete("key1"; cache_name = D) == true && g("key1") === nothing && g("key2") == "eggs"
        @test cache_delete("nonexistent_key"; cache_name = D) == false
        s("hello1", "goodbye1")                                                           # test_has_key
        @test cache_has("hello1"; cache_name = D) && !cache_has("goodbye1"; cache_name = D)
        s("no_expiry", "here"; timeout = nothing)
        @test cache_has("no_expiry"; cache_name = D)
        s("null", nothing)
        @test cache_has("null"; cache_name = D)
        s("answer", 41)                                                                   # test_incr
        @test incr("answer"; cache_name = D) == 42 && g("answer") == 42
        @test incr("answer", 10; cache_name = D) == 52 && incr("answer", -10; cache_name = D) == 42
        @test_throws KeyError incr("does_not_exist"; cache_name = D)
        @test_throws KeyError incr("does_not_exist", -1; cache_name = D)
        s("answer", 43)                                                                   # test_decr
        @test decr("answer"; cache_name = D) == 42 && decr("answer", 10; cache_name = D) == 32 && decr("answer", -10; cache_name = D) == 42
        @test_throws KeyError decr("does_not_exist"; cache_name = D)

        stuff = Dict{String,Any}("string" => "this is a string", "int" => 42, "bool" => true, "list" => [1, 2, 3, 4],   # test_data_types
                                 "tuple" => (1, 2, 3, 4), "dict" => Dict("A" => 1, "B" => 2), "float" => 1.5, "none" => nothing)
        s("stuff", stuff)
        @test g("stuff") == stuff
        @test port_block() do                                                             # test_cache_read_for_model_instance
            p = save!(DchPoll(question = "What?"))
            s("question", p)
            got = g("question")
            got == p && got.question == "What?" && got !== p
        end
        s("binary1", UInt8[0x00, 0xff, 0x10]); s("binary1-text", "text")                  # test_binary_string
        @test g("binary1") == UInt8[0x00, 0xff, 0x10] && cache_add("binary1-add", UInt8[0x01]; cache_name = D) && g("binary1-add") == UInt8[0x01]
        for (k, v) in ("ascii" => "ascii_value", "unicode_ascii" => "Iñtërnâtiônàlizætiøn1",   # test_unicode
                       "Iñtërnâtiônàlizætiøn" => "Iñtërnâtiônàlizætiøn2", "ascii2" => Dict("x" => 1))
            s(k, v)
            @test g(k) == v
            cache_delete(k; cache_name = D)
            @test cache_add(k, v; cache_name = D) && g(k) == v
        end

        @test cache_set_many(Dict("key1" => "spam", "key2" => "eggs"); cache_name = D) == String[]   # test_set_many_returns_empty_list_on_success
        @test g("key1") == "spam" && g("key2") == "eggs"                                  # test_set_many
        s("key1", "spam"); s("key2", "eggs"); s("key3", "ham")                            # test_delete_many
        @test cache_delete_many(["key1", "key2", "key4"]; cache_name = D) === nothing
        @test g("key1") === nothing && g("key2") === nothing && g("key3") == "ham"
        s("key1", "spam"); s("key2", "eggs")                                              # test_clear
        cache_clear(; cache_name = D)
        @test g("key1") === nothing && g("key2") === nothing

        s("key1", "eggs"; timeout = 60 * 60 * 24 * 30 + 1)                                # test_long_timeout (past memcached's 30 days)
        @test g("key1") == "eggs"
        @test cache_add("key2", "ham"; cache_name = D, timeout = 60 * 60 * 24 * 30 + 1) && g("key2") == "ham"
        cache_set_many(Dict("key3" => "sausage", "key4" => "lobster bisque"); cache_name = D, timeout = 60 * 60 * 24 * 30 + 1)
        @test g("key3") == "sausage" && g("key4") == "lobster bisque"
        s("key1", "eggs"; timeout = nothing)                                              # test_forever_timeout
        @test g("key1") == "eggs"
        @test cache_add("key2_forever", "ham"; cache_name = D, timeout = nothing) && g("key2_forever") == "ham"
        @test !cache_add("key1", "new eggs"; cache_name = D, timeout = nothing) && g("key1") == "eggs"
        cache_set_many(Dict("key3" => "sausage", "key4" => "lobster bisque"); cache_name = D, timeout = nothing)
        @test g("key3") == "sausage" && g("key4") == "lobster bisque"
        s("key1", "spam"; timeout = 100)                                                  # (touch to forever)
        @test cache_touch("key1"; timeout = nothing, cache_name = D) && g("key1") == "spam"
        s("key1", "eggs"; timeout = 0)                                                    # test_zero_timeout
        @test g("key1") === nothing
        @test cache_add("key2_zero", "ham"; cache_name = D, timeout = 0) && g("key2_zero") === nothing
        cache_set_many(Dict("key3" => "sausage", "key4" => "lobster bisque"); cache_name = D, timeout = 0)
        @test g("key3") === nothing && g("key4") === nothing
        @test get_or_set("key5", "belgian waffle"; cache_name = D, timeout = 0) == "belgian waffle" && g("key5") === nothing
        s("key1", "spam"; timeout = 100.2)                                                # test_float_timeout
        @test g("key1") == "spam"

        @test g("projector") === nothing                                                  # test_get_or_set
        @test get_or_set("projector", 42; cache_name = D) == 42 && g("projector") == 42
        @test get_or_set("null", nothing; cache_name = D) === nothing
        @test g("null", "default") === nothing                                            # (the get_or_set stored nothing)
        my_callable() = "value"                                                           # test_get_or_set_callable
        @test get_or_set("mykey", my_callable; cache_name = D) == "value"
        @test get_or_set("mykey", my_callable; cache_name = D) == "value"
        @test get_or_set("mykey2"; cache_name = D) do; "do-block"; end == "do-block"
        get_or_set("brian", 1979; cache_name = D, version = 2)                            # test_get_or_set_version
        @test g("brian"; version = 1) === nothing && get_or_set("brian", 42; cache_name = D, version = 1) == 42
        @test get_or_set("brian", 1979; cache_name = D, version = 2) == 1979 && g("brian"; version = 3) === nothing

        s("expire1", "very quickly"; timeout = 100)                                       # test_touch
        @test cache_touch("expire1"; timeout = 400, cache_name = D) && g("expire1") == "very quickly"
        @test cache_touch("expire1"; timeout = 0, cache_name = D) && g("expire1") === nothing
        @test !cache_touch("nonexistent"; cache_name = D)

        s("expire1", "very quickly"; timeout = 0.4)                                       # test_expiration, test_set_many_expiration
        s("expire2", "very quickly"; timeout = 0.4)
        s("expire3", "very quickly"; timeout = 0.4)
        cache_set_many(Dict("many1" => "x", "many2" => "y"); cache_name = D, timeout = 0.4)
        sleep(0.6)
        @test g("expire1") === nothing && g("many1") === nothing && g("many2") === nothing
        @test cache_add("expire2", "newvalue"; cache_name = D) && g("expire2") == "newvalue"
        @test !cache_has("expire3"; cache_name = D)

        key = "key with spaces and 清"                                                    # test_invalid_key_characters (hashed: stored all the same)
        s(key, "value")
        @test g(key) == "value"
        key = "a"^251                                                                     # test_invalid_key_length
        s(key, "value")
        @test g(key) == "value" && cache_delete(key; cache_name = D)

        s("answer1", 42)                                                                  # test_cache_versioning_get_set
        @test g("answer1") == 42 && g("answer1"; version = 1) == 42 && g("answer1"; version = 2) === nothing
        @test g("answer1"; c = V2) === nothing && g("answer1"; c = V2, version = 1) == 42
        s("answer2", 42; version = 2)
        @test g("answer2") === nothing && g("answer2"; version = 2) == 42 && g("answer2"; c = V2) == 42
        s("answer3", 42; c = V2)
        @test g("answer3") === nothing && g("answer3"; version = 2) == 42 && g("answer3"; c = V2, version = 1) === nothing
        cache_add("answer1", 42; cache_name = D, version = 2)                             # test_cache_versioning_add
        @test g("answer1"; version = 2) == 42 && !cache_add("answer1", 37; cache_name = D, version = 2)
        @test cache_add("answer1", 37; cache_name = D, version = 1) == false && cache_add("answer1", 37; cache_name = D, version = 3)
        @test cache_has("answer1"; cache_name = D, version = 3) && !cache_has("answer1"; cache_name = D, version = 4)   # test_cache_versioning_has_key
        s("answer1", 37; version = 1); s("answer1", 42; version = 2)                      # test_cache_versioning_delete
        @test cache_delete("answer1"; cache_name = D) && g("answer1"; version = 1) === nothing && g("answer1"; version = 2) == 42
        @test cache_delete("answer1"; cache_name = D, version = 2) && g("answer1"; version = 2) === nothing
        s("answer1", 37; version = 1); s("answer1", 42; version = 2)                      # test_cache_versioning_incr_decr
        incr("answer1"; cache_name = D)
        @test g("answer1"; version = 1) == 38 && g("answer1"; version = 2) == 42
        decr("answer1"; cache_name = D, version = 2)
        @test g("answer1"; version = 1) == 38 && g("answer1"; version = 2) == 41
        cache_set_many(Dict("ford1" => 37, "arthur1" => 42); cache_name = D)              # test_cache_versioning_get_set_many
        @test cache_get_many(["ford1", "arthur1"]; cache_name = D) == Dict("ford1" => 37, "arthur1" => 42)
        @test cache_get_many(["ford1", "arthur1"]; cache_name = D, version = 2) == Dict()
        @test cache_get_many(["ford1", "arthur1"]; cache_name = V2, version = 1) == Dict("ford1" => 37, "arthur1" => 42)
        cache_set_many(Dict("ford2" => 37, "arthur2" => 42); cache_name = D, version = 2)
        @test cache_get_many(["ford2", "arthur2"]; cache_name = V2) == Dict("ford2" => 37, "arthur2" => 42)
        s("answer", 42; version = 2)                                                      # test_incr_version
        @test incr_version("answer"; cache_name = D, version = 2) == 3
        @test g("answer"; version = 2) === nothing && g("answer"; version = 3) == 42
        s("answer2", 42; c = V2)
        @test incr_version("answer2"; cache_name = V2) == 3 && g("answer2"; c = V2) === nothing && g("answer2"; c = V2, version = 3) == 42
        @test_throws KeyError incr_version("does_not_exist"; cache_name = D)
        s("answer", 42; version = 2)                                                      # test_decr_version
        @test decr_version("answer"; cache_name = D, version = 2) == 1
        @test g("answer"; version = 2) === nothing && g("answer"; version = 1) == 42
        @test_throws KeyError decr_version("does_not_exist"; cache_name = D, version = 2)

        s("answer1", 42)                                                                  # test_custom_key_func
        @test g("answer1"; c = CK) === nothing
        s("answer2", 42; c = CK)
        @test g("answer2"; c = CK) == 42 && g("answer2") === nothing
        @test Juango.make_key(cache(CK), "answer2", nothing) == "CUSTOM--1-answer2"

        for (name, final) in ((CULL, n == "dc_db" ? 29 : 29), (ZERO, n == "dc_db" ? 18 : 19))   # test_cull, test_zero_cull
            for i in 1:49
                s("cull$i", "value"; c = name, timeout = 1000)
            end
            @test count(i -> cache_has("cull$i"; cache_name = name), 1:49) == final
        end
    end
end

@testset "django cache" begin
    old = settings.CACHES
    filedir = mktempdir()
    backends = [("dc_locmem", Dict{Symbol,Any}(:backend => :locmem)),
                ("dc_db", Dict{Symbol,Any}(:backend => :db, :location => "dch_cache_table")),
                ("dc_file", Dict{Symbol,Any}(:backend => :file))]
    caches = Dict{String,Any}()
    for (n, o) in backends
        # (the aliases share one store, as Django's: a directory, a table, a locmem :location)
        loc(sfx) = o[:backend] === :file ? Dict{Symbol,Any}(:location => joinpath(filedir, n * sfx)) :
                   o[:backend] === :locmem ? Dict{Symbol,Any}(:location => n * sfx) : Dict{Symbol,Any}()
        caches[n] = merge(o, loc(""))
        caches[n * "_prefix"] = merge(o, loc(""), Dict(:key_prefix => "cacheprefix"))
        caches[n * "_v2"] = merge(o, loc(""), Dict(:version => 2))
        caches[n * "_custom"] = merge(o, loc(""), Dict(:key_function => dch_custom_key))
        caches[n * "_cull"] = merge(o, loc("_cull"), Dict(:max_entries => 30), o[:backend] === :db ? Dict(:location => "dch_cull_table") : Dict())
        caches[n * "_zero"] = merge(o, loc("_zero"), Dict(:max_entries => 30, :cull_frequency => 0),
                                    o[:backend] === :db ? Dict(:location => "dch_zero_table") : Dict())
    end
    caches["dc_dummy"] = Dict(:backend => :dummy)
    caches["dc_lru"] = Dict(:backend => :locmem, :max_entries => 9)
    configure!(CACHES = merge(old, caches))
    try
        foreach(create_cache_table, ("dc_db", "dc_db_cull", "dc_db_zero"))
        for (n, o) in backends
            dch_base(n, o)
        end

        @testset "DummyCacheTests" begin
            D = "dc_dummy"
            cache_set("key", "value"; cache_name = D)                                     # test_simple
            @test cache_get("key"; cache_name = D) === nothing
            @test cache_add("addkey1", "value"; cache_name = D) == true && cache_get("addkey1"; cache_name = D) === nothing   # test_add
            @test cache_get("does_not_exist"; cache_name = D) === nothing                 # test_non_existent
            @test cache_get_many(["a", "b"]; cache_name = D) == Dict()                    # test_get_many
            @test cache_delete("key"; cache_name = D) == false                            # test_delete
            @test !cache_has("hello1"; cache_name = D)                                    # test_has_key
            @test_throws KeyError incr("answer"; cache_name = D)                          # test_incr
            @test_throws KeyError decr("answer"; cache_name = D)
            @test cache_set_many(Dict("a" => 1, "b" => 2); cache_name = D) == String[]    # test_set_many
            @test cache_delete_many(["a", "b"]; cache_name = D) === nothing               # test_delete_many
            @test cache_clear(; cache_name = D) === nothing                               # test_clear
            @test !cache_touch("whatever"; cache_name = D)                                # test_touch
            @test get_or_set("mykey", "default"; cache_name = D) == "default"             # test_get_or_set
            @test get_or_set("mykey", () -> "default"; cache_name = D) == "default"
            @test_throws KeyError incr_version("answer"; cache_name = D)                  # test_incr_version
            @test_throws KeyError decr_version("answer"; cache_name = D)
        end

        @testset "LocMemCacheTests" begin
            D = "dc_lru"
            cache_set("key", "value"; cache_name = "dc_locmem")                           # test_multiple_caches
            @test cache_get("key"; cache_name = D) === nothing
            for key in 0:8                                                                # test_lru_get
                cache_set(key, key; cache_name = D, timeout = nothing)
            end
            @test all(key -> cache_get(key; cache_name = D) == key, 0:5)
            cache_set(9, 9; cache_name = D, timeout = nothing)
            @test all(key -> cache_get(key; cache_name = D) == key, 0:5)
            @test all(key -> cache_get(key; cache_name = D) === nothing, 6:8) && cache_get(9; cache_name = D) == 9
            cache_clear(; cache_name = D)
            for key in 0:8                                                                # test_lru_set
                cache_set(key, key; cache_name = D, timeout = nothing)
            end
            for key in 3:8
                cache_set(key, key; cache_name = D, timeout = nothing)
            end
            cache_set(9, 9; cache_name = D, timeout = nothing)
            @test all(key -> cache_get(key; cache_name = D) == key, 3:9) && all(key -> cache_get(key; cache_name = D) === nothing, 0:2)
            cache_clear(; cache_name = D)
            for key in 0:8                                                                # test_lru_incr
                cache_set(key, key; cache_name = D, timeout = nothing)
            end
            for key in 0:5
                incr(key; cache_name = D)
            end
            cache_set(9, 9; cache_name = D, timeout = nothing)
            @test all(key -> cache_get(key; cache_name = D) == key + 1, 0:5)
            @test all(key -> cache_get(key; cache_name = D) === nothing, 6:8) && cache_get(9; cache_name = D) == 9
            cache_set("expiring", 1; cache_name = "dc_locmem", timeout = 100)             # test_incr_decr_timeout (the expiry is kept)
            c = cache("dc_locmem"); k = Juango.make_key(c, "expiring", nothing)
            exp = c.store[k][2]
            incr("expiring"; cache_name = "dc_locmem"); decr("expiring"; cache_name = "dc_locmem")
            @test c.store[k][2] == exp
        end

        @testset "CacheMiddlewareTest (cache_page)" begin
            configure!(CACHES = merge(old, caches, Dict("default" => Dict(:backend => :locmem))))
            count_ = Ref(0)
            view = req -> (count_[] += 1; HttpResponse("Hello World $(count_[])"))
            cached = cache_page(view; timeout = 3)                                        # test_view_decorator
            other_prefix = cache_page(view; timeout = 3, key_prefix = "prefix2")
            r(v, path = "/view/"; method = "GET") = v(Request(method, path; headers = Dict("host" => "testserver")))
            @test text(r(cached)) == "Hello World 1" && text(r(cached)) == "Hello World 1"   # (the second from the cache)
            @test text(r(other_prefix)) == "Hello World 2" && text(r(other_prefix)) == "Hello World 2"
            @test text(r(cached, "/view/?x=1")) == "Hello World 3"                        # (the query string is part of the key)
            @test text(r(cached; method = "POST")) == "Hello World 4" && text(r(cached; method = "POST")) == "Hello World 5"   # (POST: never cached)
            @test getheader(r(cached), "Cache-Control") == "max-age=3"
            cookie_view = cache_page(req -> (count_[] += 1; resp = HttpResponse("c$(count_[])"); set_cookie!(resp, "k", "v"); resp))   # test_sensitive_cookie_not_cached
            @test text(r(cookie_view, "/c/")) != text(r(cookie_view, "/c/"))
            private_view = cache_page(req -> (count_[] += 1; resp = HttpResponse("p$(count_[])"); setheader!(resp, "Cache-Control", "private"); resp))   # test_cached_control_private_not_cached
            @test text(r(private_view, "/p/")) != text(r(private_view, "/p/"))
            notfound = cache_page(req -> (count_[] += 1; HttpResponseNotFound("n$(count_[])")))   # (only 200 responses)
            @test text(r(notfound, "/n/")) != text(r(notfound, "/n/"))
        end
    finally
        configure!(CACHES = old)
    end
    # not translated: memcached and Redis (they need servers), the pickling tests (Juango's JSON
    # serializer has its own tests in services.jl), cache key warnings, the cache middleware's Vary
    # and i18n key handling and the cache utilities (get_cache_key, learn_cache_key), CacheClosingTests
end
