# Django's check_framework tests, ported (#227, part): tests/check_framework (test_security, test_translation,
# test_caches, test_urls' CheckUrlConfigTests and CheckURLSettingsTests, tests.py's MessageTests, CheckCommandTests
# and SilencingCheckTests).
# julia --project=test test/django_check_framework.jl   (see setup.jl)
#
# Django's middleware are dotted paths; Juango's are the functions (SecurityMiddleware, which also sends
# X-Frame-Options, so Django's XFrameOptionsMiddleware checks are about X_FRAME_OPTIONS = nothing).
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

using Juango: SecurityMiddleware, SessionMiddleware, CsrfViewMiddleware, CommonMiddleware
const DCF_KEY = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ!@#"
"The deployment checks' ids with these settings (the others as a deployed site would have them)."
function dcf_deploy(; kw...)
    base = (DEBUG = false, SECRET_KEY = DCF_KEY, SECRET_KEY_FALLBACKS = String[], ALLOWED_HOSTS = ["example.com"],
            MIDDLEWARE = Any[SecurityMiddleware, SessionMiddleware, CommonMiddleware, CsrfViewMiddleware],
            SECURE_HSTS_SECONDS = 3600, SECURE_HSTS_INCLUDE_SUBDOMAINS = true, SECURE_HSTS_PRELOAD = true,
            SECURE_CONTENT_TYPE_NOSNIFF = true, SECURE_SSL_REDIRECT = true, SECURE_REFERRER_POLICY = "same-origin",
            SECURE_CROSS_ORIGIN_OPENER_POLICY = "same-origin", X_FRAME_OPTIONS = "DENY", SESSION_COOKIE_SECURE = true,
            SESSION_COOKIE_HTTPONLY = true, CSRF_COOKIE_SECURE = true, CSRF_USE_SESSIONS = false, SECURE_CSP = Dict{String,Any}(),
            INSTALLED_APPS = filter(a -> !occursin("sessions", string(a)), collect(settings.INSTALLED_APPS)),
            SERVER_READ_HEADER_TIMEOUT = 10, SERVER_IDLE_TIMEOUT = 60)
    override_settings(; merge(base, values(kw))...) do
        [m.id for m in Juango.deploy_checks() if startswith(m.id, "security.")]
    end
end
const DCF_SESSIONS_APP = [a for a in settings.INSTALLED_APPS if occursin("sessions", string(a))]
nosec(mws...) = Any[m for m in Any[SessionMiddleware, CommonMiddleware, CsrfViewMiddleware] if !(m in mws)]

@testset "django check_framework: test_security" begin
    @test dcf_deploy() == String[]                                                                       # (a deployed site: none)
    # CheckSessionCookieSecureTest: test_session_cookie_secure_with_installed_app, ..._with_middleware, ..._both, ..._true
    app = vcat(filter(a -> !occursin("sessions", string(a)), collect(settings.INSTALLED_APPS)), DCF_SESSIONS_APP)
    @test dcf_deploy(SESSION_COOKIE_SECURE = false, INSTALLED_APPS = app, MIDDLEWARE = Any[SecurityMiddleware, CsrfViewMiddleware]) == ["security.W010"]
    @test dcf_deploy(SESSION_COOKIE_SECURE = false) == ["security.W011"]
    @test dcf_deploy(SESSION_COOKIE_SECURE = false, INSTALLED_APPS = app) == ["security.W012"]
    @test dcf_deploy(SESSION_COOKIE_SECURE = false, MIDDLEWARE = Any[SecurityMiddleware, CsrfViewMiddleware]) == String[]   # (no sessions)
    # CheckSessionCookieHttpOnlyTest
    @test dcf_deploy(SESSION_COOKIE_HTTPONLY = false, INSTALLED_APPS = app, MIDDLEWARE = Any[SecurityMiddleware, CsrfViewMiddleware]) == ["security.W013"]
    @test dcf_deploy(SESSION_COOKIE_HTTPONLY = false) == ["security.W014"]
    @test dcf_deploy(SESSION_COOKIE_HTTPONLY = false, INSTALLED_APPS = app) == ["security.W015"]
    # CheckCSRFMiddlewareTest, CheckCSRFCookieSecureTest (test_use_sessions_with_csrf_cookie_secure_false, test_with_csrf_cookie_secure_false_no_middleware)
    @test dcf_deploy(MIDDLEWARE = Any[SecurityMiddleware, SessionMiddleware]) == ["security.W003"]
    @test dcf_deploy(CSRF_COOKIE_SECURE = false) == ["security.W016"]
    @test dcf_deploy(CSRF_COOKIE_SECURE = false, CSRF_USE_SESSIONS = true) == String[]
    @test dcf_deploy(CSRF_COOKIE_SECURE = false, MIDDLEWARE = Any[SecurityMiddleware, SessionMiddleware]) == ["security.W003"]
    # CheckSecurityMiddlewareTest: without it, W001 and none of the header checks
    @test dcf_deploy(MIDDLEWARE = nosec(), SECURE_HSTS_SECONDS = 0, SECURE_SSL_REDIRECT = false, SECURE_CONTENT_TYPE_NOSNIFF = false,
                     SECURE_REFERRER_POLICY = nothing, X_FRAME_OPTIONS = "SAMEORIGIN") == ["security.W001"]
    # CheckStrictTransportSecurityTest, ...SubdomainsTest, ...PreloadTest
    @test dcf_deploy(SECURE_HSTS_SECONDS = 0) == ["security.W004"]
    @test dcf_deploy(SECURE_HSTS_INCLUDE_SUBDOMAINS = false) == ["security.W005"]
    @test dcf_deploy(SECURE_HSTS_INCLUDE_SUBDOMAINS = false, SECURE_HSTS_SECONDS = 0) == ["security.W004"]   # test_no_sts_subdomains_no_seconds
    @test dcf_deploy(SECURE_HSTS_PRELOAD = false) == ["security.W021"]
    # CheckXFrameOptionsMiddlewareTest, CheckXFrameOptionsDenyTest
    @test dcf_deploy(X_FRAME_OPTIONS = nothing) == ["security.W002"]
    @test dcf_deploy(X_FRAME_OPTIONS = "SAMEORIGIN") == ["security.W019"]
    # CheckContentTypeNosniffTest, CheckSSLRedirectTest
    @test dcf_deploy(SECURE_CONTENT_TYPE_NOSNIFF = false) == ["security.W006"]
    @test dcf_deploy(SECURE_SSL_REDIRECT = false) == ["security.W008"]
    # CheckSecretKeyTest: test_none_secret_key, test_low_length_secret_key, test_low_entropy_secret_key, test_insecure_secret_key
    @test dcf_deploy(SECRET_KEY = "a"^60) == ["security.W009"]
    @test dcf_deploy(SECRET_KEY = DCF_KEY[1:49]) == ["security.W009"]
    @test dcf_deploy(SECRET_KEY = "django-insecure-" * DCF_KEY) == ["security.W009"]
    @test dcf_deploy(SECRET_KEY = Juango.default_settings()[:SECRET_KEY]) == ["security.W009"]
    # CheckSecretKeyFallbacksTest: each weak fallback, by index
    r = override_settings(SECRET_KEY_FALLBACKS = [DCF_KEY, "short"], DEBUG = false) do
        [m.msg for m in Juango.deploy_checks() if m.id == "security.W025"]
    end
    @test length(r) == 1 && occursin("SECRET_KEY_FALLBACKS[1]", r[1])
    # CheckDebugTest, CheckAllowedHostsTest
    @test dcf_deploy(DEBUG = true) == ["security.W018"]
    @test dcf_deploy(ALLOWED_HOSTS = String[]) == ["security.W020"]
    # CheckReferrerPolicyTest: test_no_referrer_policy, test_with_referrer_policy (a list, a comma-separated string), test_with_invalid_referrer_policy
    @test dcf_deploy(SECURE_REFERRER_POLICY = nothing) == ["security.W022"]
    @test dcf_deploy(SECURE_REFERRER_POLICY = "strict-origin, no-referrer") == String[]
    @test dcf_deploy(SECURE_REFERRER_POLICY = ["strict-origin", "no-referrer"]) == String[]
    @test dcf_deploy(SECURE_REFERRER_POLICY = "invalid-value") == ["security.E023"]
    @test dcf_deploy(SECURE_REFERRER_POLICY = "invalid-value", MIDDLEWARE = nosec()) == ["security.W001"]
    # CheckCrossOriginOpenerPolicyTest
    @test dcf_deploy(SECURE_CROSS_ORIGIN_OPENER_POLICY = nothing) == String[]
    @test dcf_deploy(SECURE_CROSS_ORIGIN_OPENER_POLICY = "invalid-value") == ["security.E024"]
    e = override_settings(SECURE_CROSS_ORIGIN_OPENER_POLICY = "bad", MIDDLEWARE = Any[SecurityMiddleware]) do
        first(m for m in Juango.deploy_checks() if m.id == "security.E024")
    end
    @test e.level === :error && e.hint == "Valid values are: same-origin, same-origin-allow-popups, unsafe-none."
    # CheckSecureCSPTests: test_secure_csp_not_dict, test_secure_csp_report_only_not_dict
    sec_ids(; kw...) = override_settings(; kw...) do; [m.id for m in Juango.run_checks(tags = [:security])] end
    @test "security.E026" in sec_ids(SECURE_CSP = "default-src 'self'") && "security.E026" in sec_ids(SECURE_CSP_REPORT_ONLY = ["x"])
    @test !("security.E026" in sec_ids())
    # not translated: CSRFFailureViewTest (Juango's CSRF_FAILURE_VIEW is a function, checked by security.E101 in views.jl),
    # CSP.NONCE without the context processor (Juango's context processor list differs)
end

@testset "django check_framework: test_translation" begin
    tr(; kw...) = override_settings(; kw...) do; [(m.id, m.msg) for m in Juango.translation_check_issues()] end
    for tag in ["en", "mas", "sgn-ase", "fr-CA", "es-419", "zh-Hans", "ca-ES-valencia", "sr@latin"]                  # test_valid_language_code
        @test isempty(filter(x -> x[1] == "translation.E001", tr(LANGUAGE_CODE = tag)))
    end
    for tag in [nothing, 123, b"en", "eü", "en_US", "en--us", "-en", "en-", "en-US.UTF-8", "en_US.UTF-8", "ca_ES@valencia"]   # test_invalid_language_code
        @test ("translation.E001", "You have provided an invalid value for the LANGUAGE_CODE setting: $(repr(tag)).") in tr(LANGUAGE_CODE = tag)
    end
    @test isempty(tr(LANGUAGES = [("en", "English"), ("fr", "French")], LANGUAGE_CODE = "en"))                       # test_valid_languages
    @test ("translation.E002", "You have provided an invalid language code in the LANGUAGES setting: \"en--us\".") in    # test_invalid_languages
          tr(LANGUAGES = [("en--us", "x"), ("en", "English")], LANGUAGE_CODE = "en")
    @test isempty(tr(LANGUAGES_BIDI = ["he", "ar-dz"]))                                                                # test_valid_languages_bidi
    @test ("translation.E003", "You have provided an invalid language code in the LANGUAGES_BIDI setting: \"x-\".") in tr(LANGUAGES_BIDI = ["x-"])
    # test_inconsistent_language_settings, test_valid_variant_consistent_language_settings
    @test tr(LANGUAGE_CODE = "fr", LANGUAGES = [("en", "English")]) ==
          [("translation.E004", "You have provided a value for the LANGUAGE_CODE setting that is not in the LANGUAGES setting.")]
    for (code, langs) in [("fr-CA", [("fr", "French")]), ("es-419", [("es", "Spanish")]), ("de-at", [("de", "German")]),
                          ("ca-ES-valencia", [("ca", "Catalan")])]
        @test isempty(tr(LANGUAGE_CODE = code, LANGUAGES = langs))
    end
end

@testset "django check_framework: test_caches" begin
    ca(; kw...) = override_settings(; kw...) do; [(m.id, m.msg) for m in Juango.cache_check_issues()] end
    @test isempty(ca(CACHES = Dict("default" => Dict(:backend => :locmem))))                                          # test_default_cache_included
    @test ca(CACHES = Dict("other" => Dict(:backend => :locmem))) ==                                                   # test_default_cache_not_included
          [("caches.E001", "You must define a 'default' cache in your CACHES setting.")]
    # CheckCacheLocationTest: test_cache_path_matches_media_static_setting, ..._inside_..., ..._contains_..., test_cache_path_not_conflict
    root = mktempdir()
    for (loc, media, rel) in [(joinpath(root, "m"), joinpath(root, "m"), "matches"), (joinpath(root, "m", "c"), joinpath(root, "m"), "is inside"),
                              (root, joinpath(root, "m"), "contains")]
        @test ("caches.W002", "Your 'default' cache configuration might expose your cache or lead to corruption of your data because its LOCATION $rel MEDIA_ROOT.") in
              ca(CACHES = Dict("default" => Dict(:backend => :file, :location => loc)), MEDIA_ROOT = media, STATIC_ROOT = "")
        @test any(x -> x[1] == "caches.W002" && occursin("STATIC_ROOT", x[2]),
                  ca(CACHES = Dict("default" => Dict(:backend => :file, :location => loc)), STATIC_ROOT = media, MEDIA_ROOT = ""))
    end
    @test isempty(ca(CACHES = Dict("default" => Dict(:backend => :file, :location => joinpath(root, "cache"))), MEDIA_ROOT = joinpath(root, "media"), STATIC_ROOT = ""))
    # CheckCacheAbsolutePath: test_absolute_path, test_relative_path
    @test ca(CACHES = Dict("default" => Dict(:backend => :file, :location => "cache")), MEDIA_ROOT = "", STATIC_ROOT = "") ==
          [("caches.W003", "Your 'default' cache LOCATION path is relative. Use an absolute path instead.")]
    rm(root; recursive = true)
end

dcf_view(req) = HttpResponse("x")
@testset "django check_framework: test_urls" begin
    u(pats; kw...) = override_settings(; ROOT_URLCONF = pats, kw...) do; [(m.id, m.msg) for m in Juango.url_check_issues()] end
    ok = Any[path("", dcf_view; name = "home"), path("blog/", include_urls(Any[path("<int:id>/", dcf_view; name = "post")]; namespace = "blog"))]
    @test isempty(u(ok))                                                                                               # test_no_warnings
    @test isempty(u(Any[i18n_patterns(path("about/", dcf_view; name = "about"))]))                                      # test_no_warnings_i18n
    # test_include_with_dollar, test_check_resolver_recursive (a nested include is checked)
    @test u(Any[re_path("^include-with-dollar\$", include_urls(Any[path("x/", dcf_view)]))]) ==
          [("urls.W001", "Your URL pattern '^include-with-dollar\$' uses include with a route ending with a '\$'. Remove the dollar from the route to avoid problems including URLs.")]
    @test only(u(Any[path("a/", include_urls(Any[path("b/", include_urls(Any[path("/c", dcf_view; name = "c")]))]))]))[1] == "urls.W002"
    # test_beginning_with_slash, test_beginning_with_slash_append_slash
    w = u(Any[path("/path-starting-with-slash/", dcf_view), re_path("^/starting-with-slash\$", dcf_view)])
    @test w == [("urls.W002", "Your URL pattern '^/starting-with-slash\$' has a route beginning with a '/'. Remove this slash as it is unnecessary. If this pattern is targeted in an include(), ensure the include() pattern has a trailing '/'.")]
    @test isempty(u(Any[re_path("^/starting-with-slash\$", dcf_view)]; APPEND_SLASH = false))
    # test_name_with_colon
    @test u(Any[path("x/", dcf_view; name = "name_with:colon")]) ==
          [("urls.W003", "Your URL pattern 'x/' [name='name_with:colon'] has a name including a ':'. Remove the colon, to avoid ambiguous namespace references.")]
    # test_contains_tuple_not_url_instance, test_get_warning_for_invalid_pattern_string, ..._other
    @test u(Any[("^tuple/\$", dcf_view)])[1][1] == "urls.E004"
    @test occursin("is invalid. Ensure that urlpatterns is a list of path() and/or re_path() instances.", u(Any["^\$"])[1][2])
    # test_check_non_unique_namespaces, test_check_unique_namespaces
    inner = Any[path("x/", dcf_view; name = "x")]
    w = u(Any[path("a/", include_urls(inner; namespace = "app-ns1")), path("b/", include_urls(inner; namespace = "app-ns1")),
              path("c/", include_urls(inner; app_name = "app", namespace = "common")), path("d/", include_urls(inner; app_name = "app", namespace = "common"))])
    @test w == [("urls.W005", "URL namespace 'app-ns1' isn't unique. You may not be able to reverse all URLs in this namespace"),
                ("urls.W005", "URL namespace 'app:common' isn't unique. You may not be able to reverse all URLs in this namespace")]
    @test isempty(u(Any[path("a/", include_urls(inner; app_name = "app", namespace = "ns1")), path("b/", include_urls(inner; app_name = "app", namespace = "ns2"))]))
    # CheckURLSettingsTests: test_slash_no_errors, test_empty_string_no_errors, test_static_url_no_slash, ..._double_slash_allowed, test_media_url_no_slash
    @test isempty(u(ok; STATIC_URL = "/static/", MEDIA_URL = "/media/")) && isempty(u(ok; STATIC_URL = "", MEDIA_URL = ""))
    @test u(ok; STATIC_URL = "/static") == [("urls.E006", "The STATIC_URL setting must end with a slash.")]
    @test isempty(u(ok; STATIC_URL = "http://cdn.example.com//"))
    @test u(ok; MEDIA_URL = "/media") == [("urls.E006", "The MEDIA_URL setting must end with a slash.")]
    # not translated: test_check_view_not_class (Juango's views are functions), test_no_root_urlconf_in_settings,
    # UpdatedToPathTests and the unmatched angle brackets (Juango's path() refuses those routes when made), and
    # CheckCustomErrorHandlersTests (urls.E007, tested in views.jl)
end

@testset "django check_framework: tests (MessageTests, CheckCommandTests, SilencingCheckTests)" begin
    # MessageTests: test_printing, test_printing_no_hint, test_equal_to_same_constructed_check, ..._different_..., test_invalid_level
    m = CheckMessage(:error, "Message"; id = "ID", hint = "Hint")
    @test sprint(show, m) == "(ID) Message\n\tHINT: Hint"
    @test sprint(show, CheckMessage(:error, "Message"; id = "ID")) == "(ID) Message"
    @test m == CheckMessage(:error, "Message"; id = "ID", hint = "Hint") && m != CheckMessage(:error, "Message"; id = "ID", hint = "Other")
    @test m != CheckMessage(:warning, "Message"; id = "ID", hint = "Hint")
    @test_throws "The first argument should be level" CheckMessage(:loud, "Message")
    @test Juango.is_serious(m) && !Juango.is_serious(CheckMessage(:warning, "x"))
    n0 = length(Juango.CHECKS)
    try
        register_check!(() -> [CheckMessage(:error, "MyError"; id = "dcf.E001")]; tags = [:dcf_tag])
        register_check!(() -> [CheckMessage(:warning, "MyWarning"; id = "dcf.W001")]; tags = [:dcf_warn])
        register_check!(() -> [CheckMessage(:warning, "DeployOnly"; id = "dcf.W002")]; tags = [:dcf_deploy], deploy = true)
        cc(args...; kw...) = (io = IOBuffer(); call_command("check", args...; stdout = io, kw...); String(take!(io)))
        # test_given_tag: only that tag's checks; an error fails the command (SystemCheckError)
        e = try cc("--tag", "dcf_tag"); nothing catch e; e end
        @test e isa CommandError && e.returncode == 1 && startswith(e.msg, "SystemCheckError: System check identified 1 issue (0 silenced):") && occursin("(dcf.E001) MyError", e.msg)
        @test occursin("1 issue (0 silenced)", cc("--tag", "dcf_warn")) && occursin("(dcf.W001) MyWarning", cc(; tags = ["dcf_warn"]))
        # test_invalid_tag
        @test_throws "There is no system check with the 'missingtag' tag." cc("--tag", "missingtag")
        # test_list_tags, test_list_deployment_check_omitted, test_list_deployment_check_included
        t = split(cc("--list-tags"))
        @test "dcf_tag" in t && "dcf_warn" in t && !("dcf_deploy" in t) && "security" in t && issorted(t)
        @test "dcf_deploy" in split(cc("--list-tags", "--deploy"))
        # test_tags_deployment_check_omitted, test_tags_deployment_check_included
        @test_throws "There is no system check with the 'dcf_deploy' tag." cc("--tag", "dcf_deploy")
        @test occursin("(dcf.W002) DeployOnly", cc("--deploy", "--tag", "dcf_deploy"))
        # test_fail_level: a warning fails with --fail-level WARNING
        @test_throws "SystemCheckError" cc("--tag", "dcf_warn", "--fail-level", "WARNING")
        @test_throws "SystemCheckError" cc(; tags = ["dcf_warn"], fail_level = "WARNING")
        @test_throws "invalid choice" cc("--fail-level", "LOUD")
        # SilencingCheckTests: test_silenced_error, test_silenced_warning
        override_settings(SILENCED_SYSTEM_CHECKS = ["dcf.E001"]) do
            @test cc("--tag", "dcf_tag") == "System check identified no issues (1 silenced).\n"
        end
        override_settings(SILENCED_SYSTEM_CHECKS = ["dcf.W001"]) do
            @test cc("--tag", "dcf_warn") == "System check identified no issues (1 silenced).\n"
        end
        # (comma-separated tags, as Juango's check took them)
        @test occursin("(dcf.W001)", cc("--tag", "dcf_warn,dcf_deploy", "--deploy"))
    finally
        resize!(Juango.CHECKS, n0)
    end
    # not translated: test_given_app (Juango's checks aren't per app), test_database_system_checks, the
    # reserved names (CheckFrameworkReservedNamesTests: Juango's models have no check method), ChecksRunDuringTests
end
