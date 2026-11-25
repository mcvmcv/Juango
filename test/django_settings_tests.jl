# Django's settings_tests, ported (#227, part): tests/settings_tests (SettingsTests' overrides, nesting and
# the setting_changed signal, the empty SECRET_KEY, SecureProxySslHeaderTest, IsOverriddenTest,
# OverrideSettingsIsolationOnExceptionTests, modify_settings, TestListSettings).
# julia --project=test test/django_settings_tests.jl   (see setup.jl)
#
# Juango's settings are `configure!` keywords read through `settings.NAME` (a missing one is a KeyError, Django's
# AttributeError); `override_settings(f; ...)` and `modify_settings(f; ...)` take a function (Django's context
# manager / decorator). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dst_missing(k) = (try getproperty(settings, k); false catch e; e isa KeyError end)
@testset "django settings_tests: SettingsTests" begin
    # test_override, test_override_change, test_override_doesnt_leak
    @test dst_missing(:DST_TEST)
    override_settings(DST_TEST = "override") do
        @test settings.DST_TEST == "override"
        configure!(DST_TEST = "test2")                      # (changed inside: the override still ends)
    end
    @test dst_missing(:DST_TEST)
    configure!(DST_TEST2 = "test")
    override_settings(DST_TEST2 = "override") do
        @test settings.DST_TEST2 == "override"
    end
    @test settings.DST_TEST2 == "test"
    delete!(Juango.SETTINGS, :DST_TEST2); delete!(Juango.EXPLICIT_SETTINGS, :DST_TEST2)
    # test_override_settings_nested: the inner override restores the outer one's values
    override_settings(DST_TEST = "override") do
        override_settings(DST_TEST2 = "override") do
            @test settings.DST_TEST == "override" && settings.DST_TEST2 == "override"
        end
        @test settings.DST_TEST == "override" && dst_missing(:DST_TEST2)
    end
    @test dst_missing(:DST_TEST) && dst_missing(:DST_TEST2)
    # test_signal_callback_context_manager: setting_changed on entering (the value) and leaving (nothing: gone)
    got = Any[]
    receiver(setting_changed; dispatch_uid = "dst_sc") do sender, args
        args.setting === :DST_TEST && push!(got, (args.value, args.enter))
    end
    try
        override_settings(() -> nothing; DST_TEST = "override")
        @test got == [("override", true), (nothing, false)]
    finally
        disconnect!(setting_changed; dispatch_uid = "dst_sc")
    end
    # test_no_secret_key
    override_settings(SECRET_KEY = "") do
        @test_throws "The SECRET_KEY setting must not be empty." settings.SECRET_KEY
        @test any(m -> m.id == "security.W009", Juango.deploy_checks())             # (the check says so, it doesn't crash)
    end
    # not translated: deleting settings (`del settings.X`), class decorators, the settings module and LazySettings,
    # configure()'s uppercase rule, the TIME_ZONE check at startup (TimeZones checks it when used)
end

@testset "django settings_tests: SecureProxySslHeaderTest" begin
    rf = RequestFactory()
    sec(h; secure = false) = (r = get(rf, "/"; headers = h === nothing ? Dict() : Dict("X-Forwarded-Proto" => h)); secure && (r.meta[:secure] = true); Juango.is_secure(r))
    override_settings(SECURE_PROXY_SSL_HEADER = nothing) do                                    # test_none
        @test !sec("https")
    end
    override_settings(SECURE_PROXY_SSL_HEADER = ("X-Forwarded-Proto", "https")) do
        @test !sec(nothing)                                                                   # test_set_without_xheader
        @test !sec("wrongvalue")                                                              # test_set_with_xheader_wrong
        @test sec("https")                                                                    # test_set_with_xheader_right
        @test sec("https, http") && sec("https  , http")                                      # test_set_with_xheader_leftmost_right
        @test !sec("http, https")                                                             # test_set_with_xheader_leftmost_not_secure
        @test !sec("http ,wrongvalue,http,http")                                              # test_set_with_xheader_multiple_not_secure
    end
    # test_xheader_preferred_to_underlying_request: Django trusts the header over the connection; Juango's
    # connection-level HTTPS (a TLS listener) counts as secure whatever the header says, so a proxy can't downgrade it
end

@testset "django settings_tests: IsOverriddenTest" begin
    before = is_overridden(:DST_ISO)
    override_settings(DST_ISO = ["x"]) do
        @test is_overridden(:DST_ISO) && is_overridden("DST_ISO")
    end
    @test !before && !is_overridden(:DST_ISO)
    @test !is_overridden(:ALLOWED_HOSTS) || haskey(Juango.SETTINGS, :ALLOWED_HOSTS)                    # test_override (before)
    @test is_overridden(:DATABASE)                                                                     # test_configure (set by the test setup)
    @test !is_overridden(:SECURE_HSTS_PRELOAD)                                                         # (a default nobody set)
    was = is_overridden(:ROOT_URLCONF)
    override_settings(ROOT_URLCONF = settings.ROOT_URLCONF) do                                         # (already set: still afterwards)
        @test is_overridden(:ROOT_URLCONF)
    end
    @test is_overridden(:ROOT_URLCONF) == was
end

struct DstEnter <: Exception end
struct DstExit <: Exception end
@testset "django settings_tests: OverrideSettingsIsolationOnExceptionTests" begin
    # test_override_settings_both: a receiver raising when entering or leaving: the exception propagates, the settings are put back
    for (which, E) in ((true, DstEnter), (false, DstExit))
        receiver(setting_changed; dispatch_uid = "dst_iso") do sender, args
            args.setting === :DST_SETTING_ENTER && args.enter == which && throw(E())
        end
        try
            old = settings.SECURE_HSTS_SECONDS
            @test_throws E override_settings(() -> nothing; SECURE_HSTS_SECONDS = 99, DST_SETTING_ENTER = 1)
            disconnect!(setting_changed; dispatch_uid = "dst_iso")
            @test settings.SECURE_HSTS_SECONDS == old && dst_missing(:DST_SETTING_ENTER) && !is_overridden(:DST_SETTING_ENTER)
        finally
            disconnect!(setting_changed; dispatch_uid = "dst_iso")
        end
    end
end

dst_mw1(get_response) = get_response
dst_mw2(get_response) = get_response
@testset "django settings_tests: modify_settings (FullyDecoratedTestCase, ClassDecoratedTestCase)" begin
    override_settings(MIDDLEWARE = Any[dst_mw1, Juango.CommonMiddleware]) do
        # test_modify_settings: append, prepend, remove, in the order given; items already there aren't repeated
        modify_settings(MIDDLEWARE = (append = dst_mw2, prepend = [dst_mw2, Juango.SessionMiddleware], remove = dst_mw1)) do
            @test settings.MIDDLEWARE == Any[Juango.SessionMiddleware, Juango.CommonMiddleware, dst_mw2]
            # (nested: the current list, then back to it)
            modify_settings(MIDDLEWARE = (remove = [Juango.SessionMiddleware, Juango.CommonMiddleware],)) do
                @test settings.MIDDLEWARE == Any[dst_mw2]
            end
            @test settings.MIDDLEWARE == Any[Juango.SessionMiddleware, Juango.CommonMiddleware, dst_mw2]
        end
        @test settings.MIDDLEWARE == Any[dst_mw1, Juango.CommonMiddleware]
        modify_settings(ALLOWED_HOSTS = (append = "example.com",), DST_NEW_LIST = (append = ["a", "b"],)) do
            @test "example.com" in settings.ALLOWED_HOSTS && settings.DST_NEW_LIST == ["a", "b"]
        end
        @test dst_missing(:DST_NEW_LIST)
        @test_throws "Unsupported action: replace" modify_settings(() -> nothing; ALLOWED_HOSTS = (replace = "x",))
        # (a Dict of operations works too)
        modify_settings(MIDDLEWARE = Dict(:remove => dst_mw1)) do
            @test settings.MIDDLEWARE == Any[Juango.CommonMiddleware]
        end
    end
end

@testset "django settings_tests: TestListSettings" begin
    # test_tuple_settings: a list setting given a string is reported (Juango checks rather than refusing at startup)
    for name in (:ALLOWED_HOSTS, :TEMPLATE_DIRS, :LOCALE_PATHS, :SECRET_KEY_FALLBACKS)     # (INSTALLED_APPS = "foo" is refused when set)
        issues = override_settings(Juango.settings_issues; (name => "foo",)...)
        @test any(x -> x[3] == "settings.E002" && occursin("$name must be a list", x[2]), issues)
    end
    # not translated: MediaURLStaticURLPrefixTest (Juango has no script prefix, #292), TestComplexSettingOverride
    # (Django warns when overriding ROOT_URLCONF-like settings in a decorator), the transaction test-case decorators
end
