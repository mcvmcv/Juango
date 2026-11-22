# Django's messages tests, ported (#227): tests/messages_tests (BaseTests run against the session,
# cookie and fallback storages, CookieTests, FallbackTests, SessionTests, ApiTests, MessageTests).
# julia --project=test test/django_messages.jl   (see setup.jl)
#
# Juango's storages aren't objects a test adds to and updates: messages are added with message! in a
# view and read with get_messages, so the tests go through the Client. Each test keeps its Django
# name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

write(joinpath(TPL, "dmsg_show.html"),
      "{% for m in messages %}[{{ m.tags }}|{{ m.level }}|{{ m }}]{% endfor %}{% if DEFAULT_MESSAGE_LEVELS.ERROR == 40 %}E{% endif %}")
const DMSG_LEVELS = Dict("debug" => :debug, "info" => :info, "success" => :success, "warning" => :warning, "error" => :error)
function dmsg_add(req; level)
    for m in split(get(req.POST, "messages", ""), "|")
        message!(req, DMSG_LEVELS[level], m)
    end
    HttpResponseRedirect("/dmsg/show/")
end
dmsg_show(req) = render(req, "dmsg_show.html")
dmsg_tagged(req) = (message!(req, :info, "tagged"; extra_tags = "a b"); message!(req, :error, mark_safe("<b>safe</b>")); HttpResponse(""))
dmsg_empty(req) = (message!(req, :info, ""); HttpResponse(""))
dmsg_levelled(req) = (Juango.set_level!(req, 5); message!(req, 5, "five"); message!(req, :debug, "debug"); HttpResponse(""))

function dmsg_cycle(storage)          # BaseTests, for one storage
    @testset "BaseTests ($storage)" begin
        c = Client()
        msgs = ["Test message $i" for i in 1:2]
        for level in keys(DMSG_LEVELS)                                                    # test_full_request_response_cycle
            r = post(c, "/dmsg/add/$level/", Dict("messages" => join(msgs, "|")); follow = true)
            lv = Juango.MESSAGE_LEVELS[DMSG_LEVELS[level]]
            want = join(["[$(level)|$(lv)|$m]" for m in msgs])
            if level == "debug"
                @test text(r) == "E"                                                      # (below MESSAGE_LEVEL: dropped)
            else
                @test text(r) == want * "E"
            end
            @test text(get(c, "/dmsg/show/")) == "E"                                      # (shown once)
        end
        post(c, "/dmsg/add/info/", Dict("messages" => "one"))                             # test_multiple_posts
        post(c, "/dmsg/add/error/", Dict("messages" => "two"))
        @test text(get(c, "/dmsg/show/")) == "[info|20|one][error|40|two]E"
        get(c, "/dmsg/tagged/")                                                           # test_tags, test_safedata, test_extra_tags
        @test text(get(c, "/dmsg/show/")) == "[a b info|20|tagged][error|40|<b>safe</b>]E"
        get(c, "/dmsg/empty/")                                                            # test_add (an empty message is ignored)
        @test text(get(c, "/dmsg/show/")) == "E"
        get(c, "/dmsg/levelled/")                                                         # test_low_level (set_level per request)
        @test text(get(c, "/dmsg/show/")) == "[|5|five][debug|10|debug]E"
        override_settings(MESSAGE_LEVEL = 30) do                                         # test_settings_level
            post(c, "/dmsg/add/info/", Dict("messages" => "low"))
            post(c, "/dmsg/add/warning/", Dict("messages" => "high"))
            @test text(get(c, "/dmsg/show/")) == "[warning|30|high]E"
        end
        override_settings(MESSAGE_TAGS = Dict(20 => "info", 10 => "", 30 => "", 40 => "bad", 29 => "custom")) do   # test_custom_tags
            post(c, "/dmsg/add/info/", Dict("messages" => "i"))
            post(c, "/dmsg/add/error/", Dict("messages" => "e"))
            post(c, "/dmsg/add/warning/", Dict("messages" => "w"))
            @test text(get(c, "/dmsg/show/")) == "[info|20|i][bad|40|e][|30|w]E"
        end
        # test_existing_read_add_update: messages read, then one added in the same request, leave only the new one
        r = get(c, "/dmsg/readadd/")
        @test text(get(c, "/dmsg/show/")) == "[success|25|added after reading]E"
    end
end

@testset "django messages" begin
    old_urls, old_mw = settings.ROOT_URLCONF, settings.MIDDLEWARE
    dmsg_readadd(req) = (get_messages(req); message!(req, :success, "added after reading"); HttpResponse(""))
    configure!(ROOT_URLCONF = vcat(old_urls, [path("dmsg/add/<str:level>/", dmsg_add), path("dmsg/show/", dmsg_show),
                                              path("dmsg/tagged/", dmsg_tagged), path("dmsg/empty/", dmsg_empty),
                                              path("dmsg/levelled/", dmsg_levelled), path("dmsg/readadd/", dmsg_readadd)]))
    try
        dmsg_cycle(:session)
        configure!(MESSAGE_STORAGE = :cookie, MIDDLEWARE = vcat(old_mw, Any[MessageMiddleware]))
        dmsg_cycle(:cookie)
        configure!(MESSAGE_STORAGE = :fallback)
        dmsg_cycle(:fallback)

        @testset "CookieTests" begin
            configure!(MESSAGE_STORAGE = :cookie)
            override_settings(SESSION_COOKIE_DOMAIN = ".example.com", SESSION_COOKIE_SECURE = true, SESSION_COOKIE_HTTPONLY = true,
                              SESSION_COOKIE_SAMESITE = "Strict") do                       # test_cookie_settings
                r = post(Client(), "/dmsg/add/info/", Dict("messages" => "test"))
                sc = only(filter(h -> startswith(h, "messages="), r.cookies))
                @test occursin("Domain=.example.com", sc) && occursin("Secure", sc) && occursin("HttpOnly", sc) && occursin("SameSite=Strict", sc)
                c = Client(); post(c, "/dmsg/add/info/", Dict("messages" => "test"))       # (deleting the cookie: the same domain)
                r = get(c, "/dmsg/show/")
                sc = only(filter(h -> startswith(h, "messages="), r.cookies))
                @test occursin("Domain=.example.com", sc) && occursin("Max-Age=0", sc) && occursin("SameSite=Strict", sc)
            end
            c = Client()                                                                  # test_get_bad_cookie
            c.cookies["messages"] = "test:bad"
            @test text(get(c, "/dmsg/show/")) == "E"
            c = Client()                                                                  # test_max_cookie_length (the oldest are dropped)
            msgs = ["$i " * "x"^500 for i in 1:6]
            r = post(c, "/dmsg/add/info/", Dict("messages" => join(msgs, "|")))      # (logs "Messages dropped" to juango.messages)
            @test ncodeunits(c.cookies["messages"]) <= 2048
            body = text(get(c, "/dmsg/show/"))
            @test !occursin("[info|20|1 x", body) && occursin("[info|20|6 x", body)
            c = Client()                                                                  # test_message_rfc6265: a cookie-safe value
            post(c, "/dmsg/add/info/", Dict("messages" => "\\te,st\"; \u2019"))
            @test !any(ch -> ch in "\\,;\" ", c.cookies["messages"])
            @test text(get(c, "/dmsg/show/")) == "[info|20|\\te,st&quot;; \u2019]E"
            c = Client()                                                                  # test_no_update: nothing read or added, no cookie written
            r = get(c, "/dmsg/empty/")
            @test isempty(filter(h -> startswith(h, "messages="), r.cookies))
        end

        @testset "FallbackTests" begin
            configure!(MESSAGE_STORAGE = :fallback)
            c = Client()                                                                  # test_get_fallback / test_session_fallback
            msgs = ["$i " * "x"^500 for i in 1:6]
            post(c, "/dmsg/add/info/", Dict("messages" => join(msgs, "|")))
            @test haskey(c.cookies, "messages") && haskey(c.session.data, Juango.MESSAGE_SESSION_KEY)
            body = text(get(c, "/dmsg/show/"))
            @test all(i -> occursin("[info|20|$i x", body), 1:6)                          # (all of them, in order)
            @test findfirst("[info|20|1 x", body)[1] < findfirst("[info|20|6 x", body)[1]
            @test !haskey(c.session.data, Juango.MESSAGE_SESSION_KEY) && text(get(c, "/dmsg/show/")) == "E"
            c = Client()                                                                  # test_flush_used_backends: few messages, no session
            post(c, "/dmsg/add/info/", Dict("messages" => "small"))
            @test haskey(c.cookies, "messages") && !haskey(c.cookies, Juango.settings.SESSION_COOKIE_NAME)
        end

        @testset "ApiTests and middleware" begin
            configure!(MESSAGE_STORAGE = :session, MIDDLEWARE = old_mw)
            req = Request("GET", "/")                                                     # test_middleware_missing
            e = try message!(req, :info, "x") catch e; e end
            @test e isa MessageFailure && startswith(e.msg, "You cannot add messages without installing")
            @test message!(req, :info, "x"; fail_silently = true) === nothing             # test_middleware_missing_silently
            configure!(MESSAGE_STORAGE = :cookie)
            @test_throws MessageFailure message!(Request("GET", "/"), :info, "x")
            @test message!(Request("GET", "/"), :info, "x"; fail_silently = true) === nothing
            configure!(MESSAGE_STORAGE = :session)
            @test isempty(get_messages(Request("GET", "/")))                              # (no storage: no messages)
        end
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw, MESSAGE_STORAGE = :session, MESSAGE_LEVEL = 20)
    end
end

@testset "django messages: MessageTests" begin
    m = Juango.Message(:info, "Test message")                                             # test_eq, test_repr
    @test m == Juango.Message(20, "Test message") && m != Juango.Message(:info, "other") && m != "Test message"
    @test repr(m) == "Message(level=20, message=\"Test message\")" && string(m) == "Test message"
    for (lvl, tag) in ((:debug, "debug"), (:info, "info"), (:success, "success"), (:warning, "warning"), (:error, "error"), (12, ""))   # test_level_tag
        @test Juango.tattr(Juango.Message(lvl, "x"), Val(:level_tag)) == tag
    end
    override_settings(MESSAGE_TAGS = Dict(20 => "information", 12 => "custom")) do      # test_override_settings_level_tags
        @test Juango.tattr(Juango.Message(:info, "x"), Val(:level_tag)) == "information"
        @test Juango.tattr(Juango.Message(12, "x"; extra_tags = "extra"), Val(:tags)) == "extra custom"
    end
    @test Juango.tattr(Juango.Message(:info, "x"), Val(:level_tag)) == "info"            # (back after the override)
    @test DEFAULT_MESSAGE_LEVELS["ERROR"] == 40 && DEFAULT_MESSAGE_LEVELS["DEBUG"] == 10
    # not translated: the storages as objects (storage.add/update/used, the cookie's not-finished sentinel),
    # the legacy cookie hash formats, MessageEncoder/MessageDecoder (Juango stores dicts as JSON)
end
