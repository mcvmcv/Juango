# The script prefix (#292), with the Django tests left out of earlier ports for want of it (#227): urlpatterns_reverse's
# override_script_prefix tests, settings_tests' MediaURLStaticURLPrefixTest, handlers' and requests' FORCE_SCRIPT_NAME
# tests, and a site served under a sub-path end to end (resolving, reversing, redirects, APPEND_SLASH, i18n_patterns).
# julia --project=test test/django_script_prefix.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dsp_view(req; kw...) = HttpResponse("path=$(req.path) info=$(req.path_info) name=$(req.script_name) url=$(reverse_url("dsp-places", 1))")
dsp_go(req) = HttpResponseRedirect(reverse_url("dsp-home"))
const DSP_URLS = Any[path("", dsp_view; name = "dsp-home"), path("places/<int:id>/", dsp_view; name = "dsp-places"),
                     path("optional/<str:x>/", dsp_view; name = "dsp-optional"), path("go/", dsp_go), path("slash/", dsp_view),
                     path("includes/", include_urls(Any[path("non_path_include/", dsp_view; name = "dsp-npi")]))]

@testset "django script prefix: urlpatterns_reverse (override_script_prefix)" begin
    override_settings(ROOT_URLCONF = DSP_URLS) do
        @test get_script_prefix() == "/" && reverse_url("dsp-npi") == "/includes/non_path_include/"
        override_script_prefix("/{{invalid}}/") do                                                        # test_prefix_braces
            @test reverse_url("dsp-npi") == "/%7B%7Binvalid%7D%7D/includes/non_path_include/"
        end
        override_script_prefix("/bogus)/") do                                                             # test_prefix_parenthesis
            @test reverse_url("dsp-npi") == "/bogus)/includes/non_path_include/"
        end
        override_script_prefix("/bump%20map/") do                                                         # test_prefix_format_char
            @test reverse_url("dsp-npi") == "/bump%2520map/includes/non_path_include/"
        end
        override_script_prefix("/%7Eme/") do                                                              # test_non_urlsafe_prefix_with_args
            @test reverse_url("dsp-places", 1) == "/%257Eme/places/1/"
        end
        override_script_prefix("/script:name/") do                                                        # test_script_name_escaping
            @test reverse_url("dsp-optional", "foo:bar") == "/script:name/optional/foo:bar/"
        end
        override_script_prefix("/app") do                                                                 # (a trailing slash is added)
            @test get_script_prefix() == "/app/" && reverse_url("dsp-home") == "/app/"
        end
        @test get_script_prefix() == "/"
        # flatpages' test_get_absolute_url_urlencodes, test_get_absolute_url_honors_script_prefix
        page = Juango.FlatPage(title = "Café!", url = "/café/")
        @test Juango.get_absolute_url(page) == "/caf%C3%A9/"
        override_script_prefix("/prefix/") do
            @test Juango.get_absolute_url(page) == "/prefix/caf%C3%A9/"
        end
    end
end

@testset "django script prefix: settings_tests MediaURLStaticURLPrefixTest" begin
    # test_not_prefixed: absolute paths and URLs are left alone
    for p in ("/path/", "http://myhost.com/path/", "http://myhost/path/", "https://myhost/path/"), setting in (:STATIC_URL, :MEDIA_URL)
        override_settings(; (setting => p,)...) do
            for sn in ("/somesubpath", "/somesubpath/", "/", "", nothing)
                override_script_prefix(sn) do
                    @test getproperty(settings, setting) == p
                end
            end
        end
    end
    # test_add_script_name_prefix: a relative one is under the script prefix
    for (sn, expected) in (("/somesubpath", "/somesubpath/path/"), ("/somesubpath/", "/somesubpath/path/"), ("/", "/path/"), (nothing, "/path/"))
        for setting in (:STATIC_URL, :MEDIA_URL)
            override_settings(; (setting => "path/",)...) do
                override_script_prefix(sn) do
                    @test getproperty(settings, setting) == expected
                end
            end
        end
    end
end

@testset "django script prefix: FORCE_SCRIPT_NAME (handlers, requests)" begin
    rf = RequestFactory()
    # test_wsgirequest_with_force_script_name, ..._path_with_force_script_name_trailing_slash (requests)
    for fsn in ("/FORCED_PREFIX", "/FORCED_PREFIX/")
        override_settings(FORCE_SCRIPT_NAME = fsn) do
            req = Juango.apply_script_name!(get(rf, "/somepath/"))
            @test req.path == "/FORCED_PREFIX/somepath/" && req.path_info == "/somepath/" && req.script_name == "/FORCED_PREFIX"
            # (a proxy that passes the prefix on: kept, not doubled)
            req = Juango.apply_script_name!(get(rf, "/FORCED_PREFIX/somepath/"))
            @test req.path == "/FORCED_PREFIX/somepath/" && req.path_info == "/somepath/"
            req = Juango.apply_script_name!(get(rf, "/FORCED_PREFIX"))
            @test req.path_info == "/"
            # (only at a segment boundary: /FORCED_PREFIXother isn't under it)
            @test Juango.apply_script_name!(get(rf, "/FORCED_PREFIXother/")).path == "/FORCED_PREFIX/FORCED_PREFIXother/"
            @test get_script_prefix() == "/FORCED_PREFIX/"
        end
    end
    @test get(rf, "/x/").path_info == "/x/" && get(rf, "/x/").script_name == ""
end

@testset "django script prefix: a site under a sub-path" begin
    override_settings(ROOT_URLCONF = DSP_URLS, FORCE_SCRIPT_NAME = "/app", MIDDLEWARE = Any[Juango.CommonMiddleware], APPEND_SLASH = true) do
        c = Client()
        # resolved against path_info; req.path is the whole path; reversing adds the prefix
        @test text(get(c, "/places/7/")) == "path=/app/places/7/ info=/places/7/ name=/app url=/app/places/1/"
        @test text(get(c, "/app/places/7/")) == "path=/app/places/7/ info=/places/7/ name=/app url=/app/places/1/"
        # redirects to reversed URLs, and APPEND_SLASH, keep the prefix
        r = get(c, "/go/")
        @test r.status == 302 && getheader(r, "Location") == "/app/"
        r = get(c, "/slash")
        @test r.status == 301 && getheader(r, "Location") == "/app/slash/"
        @test get(c, "/nope/").status == 404
    end
    # i18n_patterns: the language redirect is under the prefix too
    urls = Any[i18n_patterns(path("about/", dsp_view; name = "dsp-about"))]
    override_settings(ROOT_URLCONF = urls, FORCE_SCRIPT_NAME = "/app", USE_I18N = true, LANGUAGE_CODE = "en",
                      MIDDLEWARE = Any[Juango.SessionMiddleware, Juango.LocaleMiddleware, Juango.CommonMiddleware]) do
        r = get(Client(), "/about/")
        @test r.status == 302 && getheader(r, "Location") == "/app/en/about/"
        @test reverse_url("dsp-about") == "/app/en/about/"
    end
end
