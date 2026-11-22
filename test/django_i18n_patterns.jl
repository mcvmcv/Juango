# Django's i18n URL pattern tests, ported (#227): tests/i18n/patterns (URLPrefixTests, URLDisabledTests,
# URLTranslationTests, URLNamespaceTests, URLRedirectTests, URLVaryAcceptLanguageTests,
# URLRedirectWithoutTrailingSlashTests, URLResponseTests, URLTagTests) and set_language's translated redirect.
# julia --project=test test/django_i18n_patterns.jl   (see setup.jl)
#
# Django's patterns are re_paths (`_(r"^users/$")`); these are the same routes as paths (`gettext_lazy("users/")`),
# with the same translations. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DIP_LOCALE = mktempdir()
for (loc, pairs) in (("nl", ["translated/" => "vertaald/", "translated/<slug:slug>/" => "vertaald/<slug:slug>/", "users/" => "gebruikers/",
                             "account/" => "profiel/", "register/" => "registreren/", "register-as-path/" => "registreren-als-pad/",
                             "path-translated/<int:id>/" => "pad-vertaald/<int:id>/"]),
                     ("pt_BR", ["users/" => "usuarios/", "account/" => "conta/", "register/" => "registre-se/"]))
    mkpath(joinpath(DIP_LOCALE, loc, "LC_MESSAGES"))
    open(joinpath(DIP_LOCALE, loc, "LC_MESSAGES", "juango.po"), "w") do io
        println(io, "msgid \"\"\nmsgstr \"\"\n\"Content-Type: text/plain; charset=UTF-8\\n\"\n")
        for (k, v) in pairs
            println(io, "msgid \"$k\"\nmsgstr \"$v\"\n")
        end
    end
end
dip_view(req; kw...) = HttpResponse("ok:" * join(["$k=$v" for (k, v) in sort(collect(kw); by = first)], ",") * ":" * string(get(req.meta, :LANGUAGE_CODE, "")))
const DIP_URLS = Any[
    path("not-prefixed/", dip_view; name = "not-prefixed"),
    path(gettext_lazy("translated/"), dip_view; name = "no-prefix-translated"),
    path(gettext_lazy("translated/<slug:slug>/"), dip_view; name = "no-prefix-translated-slug"),
    path("i18n/", i18n_urls()),
    i18n_patterns(
        path("prefixed/", dip_view; name = "prefixed"),
        path("prefixed.xml", dip_view; name = "prefixed_xml"),
        path(gettext_lazy("path-translated/<int:id>/"), dip_view; name = "path-translated"),
        path(gettext_lazy("users/"), dip_view; name = "users"),
        path(gettext_lazy("account/"), include_urls([path(gettext_lazy("register/"), dip_view; name = "register"),
                                                      path(gettext_lazy("register-as-path/"), dip_view; name = "register-as-path")];
                                                     namespace = "account")))]

@testset "django i18n patterns" begin
    old = (settings.ROOT_URLCONF, settings.MIDDLEWARE, settings.LANGUAGES, settings.LANGUAGE_CODE, get(settings, :LOCALE_PATHS, String[]))
    mw = Any[m for m in old[2]]
    insert!(mw, something(findfirst(==(Juango.SessionMiddleware), mw), 0) + 1, LocaleMiddleware)
    configure!(ROOT_URLCONF = DIP_URLS, MIDDLEWARE = mw, LANGUAGE_CODE = "en", LOCALE_PATHS = [DIP_LOCALE],
               LANGUAGES = [("nl", "Dutch"), ("en", "English"), ("pt-br", "Brazilian Portuguese")])
    Juango.reload_translations!()
    try
        @testset "URLPrefixTests" begin
            with_language("en") do                                                        # test_not_prefixed
                @test reverse_url("not-prefixed") == "/not-prefixed/"
                @test reverse_url("prefixed") == "/en/prefixed/"                          # test_prefixed
            end
            with_language("nl") do
                @test reverse_url("not-prefixed") == "/not-prefixed/" && reverse_url("prefixed") == "/nl/prefixed/"
            end
            @test reverse_url("prefixed") == "/en/prefixed/"                              # (no language active: LANGUAGE_CODE)
            e = try include_urls([i18n_patterns(path("x/", dip_view))]) catch e; e end    # test_invalid_prefix_use
            @test e isa Juango.ImproperlyConfigured && e.msg == "Using i18n_patterns in an included URLconf is not allowed."
        end
        @testset "URLDisabledTests" begin
            override_settings(USE_I18N = false) do                                        # test_prefixed_i18n_disabled
                with_language("nl") do
                    @test reverse_url("prefixed") == "/prefixed/"
                end
                @test get(Client(), "/prefixed/").status == 200
            end
        end
        @testset "URLTranslationTests" begin
            with_language("en") do                                                        # test_no_prefix_translated
                @test reverse_url("no-prefix-translated") == "/translated/"
                @test reverse_url("no-prefix-translated-slug"; slug = "yeah") == "/translated/yeah/"
                @test reverse_url("users") == "/en/users/"                                # test_users_url
            end
            with_language("nl") do
                @test reverse_url("no-prefix-translated") == "/vertaald/"
                @test reverse_url("no-prefix-translated-slug"; slug = "yeah") == "/vertaald/yeah/"
                @test reverse_url("users") == "/nl/gebruikers/"
                @test reverse_url("path-translated"; id = 3) == "/nl/pad-vertaald/3/"
            end
            with_language("pt-br") do
                @test reverse_url("users") == "/pt-br/usuarios/"
            end
            with_language("en") do                                                        # test_translate_url_utility
                @test Juango.translate_url("/en/nonexistent/", "nl") == "/en/nonexistent/"
                @test Juango.translate_url("/en/users/", "nl") == "/nl/gebruikers/"
                @test Juango.translate_url("/en/account/register/", "nl") == "/nl/profiel/registreren/"
                @test Juango.translate_url("/en/account/register-as-path/", "nl") == "/nl/profiel/registreren-als-pad/"
                @test Juango.translate_url("/en/users/?x=1#top", "nl") == "/nl/gebruikers/?x=1#top"   # (query and fragment kept)
                @test Juango.translate_url("https://example.com/en/users/", "nl") == "https://example.com/nl/gebruikers/"
                @test Juango.translate_url("/en/path-translated/5/", "nl") == "/nl/pad-vertaald/5/"
            end
            with_language("nl") do
                @test Juango.translate_url("/nl/gebruikers/", "en") == "/en/users/"
            end
        end
        @testset "URLNamespaceTests" begin
            with_language("en") do                                                        # test_account_register
                @test reverse_url("account:register") == "/en/account/register/"
                @test reverse_url("account:register-as-path") == "/en/account/register-as-path/"
            end
            with_language("nl") do
                @test reverse_url("account:register") == "/nl/profiel/registreren/"
                @test reverse_url("account:register-as-path") == "/nl/profiel/registreren-als-pad/"
            end
        end
        @testset "URLRedirectTests" begin
            c = Client()
            r = get(c, "/not-prefixed/")                                                  # test_no_prefix_response
            @test r.status == 200
            r = get(c, "/account/register/"; headers = Dict("accept-language" => "en"))  # test_en_redirect
            @test assert_redirects(r, "/en/account/register/"; client = c)
            r = get(c, "/profiel/registreren/"; headers = Dict("accept-language" => "en"))   # test_en_redirect_wrong_url
            @test r.status == 404
            r = get(c, "/profiel/registreren/"; headers = Dict("accept-language" => "nl"))   # test_nl_redirect
            @test assert_redirects(r, "/nl/profiel/registreren/"; client = c)
            r = get(c, "/account/register/"; headers = Dict("accept-language" => "nl"))  # test_nl_redirect_wrong_url
            @test r.status == 404
            r = get(c, "/conta/registre-se/"; headers = Dict("accept-language" => "pt-br"))   # test_pt_br_redirect
            @test assert_redirects(r, "/pt-br/conta/registre-se/"; client = c)
            r = get(c, "/account/register/"; headers = Dict("accept-language" => "pl-pl"))   # test_pl_pl_redirect (unsupported: LANGUAGE_CODE)
            @test assert_redirects(r, "/en/account/register/"; client = c)
            r = get(c, "/prefixed/?q=1"; headers = Dict("accept-language" => "nl"))       # (the query string is kept)
            @test assert_redirects(r, "/nl/prefixed/?q=1")
        end
        @testset "URLVaryAcceptLanguageTests" begin
            c = Client()
            r = get(c, "/not-prefixed/")                                                  # test_no_prefix_response
            @test Juango.has_vary_header(r, "Accept-Language")
            r = get(c, "/account/register/"; headers = Dict("accept-language" => "en"))  # test_en_redirect
            @test Juango.has_vary_header(r, "Accept-Language") && Juango.has_vary_header(r, "Cookie")
            r = get(c, getheader(r, "Location"))
            @test r.status == 200 && !Juango.has_vary_header(r, "Accept-Language")        # (once prefixed: no Accept-Language)
        end
        @testset "URLRedirectWithoutTrailingSlashTests" begin
            c = Client()
            r = get(c, "/not-prefixed")                                                   # test_not_prefixed_redirect
            @test assert_redirects(r, "/not-prefixed/"; status = 301)
            r = get(c, "/account/register"; headers = Dict("accept-language" => "en"))   # test_en_redirect
            @test assert_redirects(r, "/en/account/register/"; client = c)
        end
        @testset "URLResponseTests" begin
            c = Client()
            @test get(c, "/en/not-prefixed/").status == 404                               # test_not_prefixed_with_prefix
            r = get(c, "/en/account/register/")                                           # test_en_url
            @test r.status == 200 && getheader(r, "Content-Language") == "en" && endswith(text(r), ":en")
            r = get(c, "/nl/profiel/registreren/")                                        # test_nl_url
            @test r.status == 200 && getheader(r, "Content-Language") == "nl" && endswith(text(r), ":nl")
            @test get(c, "/en/profiel/registreren/").status == 404                        # test_wrong_en_prefix
            @test get(c, "/nl/account/register/").status == 404                           # test_wrong_nl_prefix
            r = get(c, "/pt-br/conta/registre-se/")                                       # test_pt_br_url
            @test r.status == 200 && getheader(r, "Content-Language") == "pt-br"
            r = get(c, "/nl/pad-vertaald/7/")                                             # test_nl_path (a translated path with a converter)
            @test r.status == 200 && startswith(text(r), "ok:id=7")
            @test get(c, "/vertaald/yeah/").status == 404                                 # (unprefixed translated routes: the active language's)
            @test text(get(c, "/translated/yeah/")) == "ok:slug=yeah:en"
        end
        @testset "URLTagTests" begin
            t(s) = render(Template(s), Dict{String,Any}())
            @test t("{% load i18n %}{% language 'nl' %}{% url 'no-prefix-translated' %}{% endlanguage %}") == "/vertaald/"   # test_strings_only
            @test t("{% load i18n %}{% language 'pt-br' %}{% url 'users' %}{% endlanguage %}") == "/pt-br/usuarios/"
            @test t("{% load i18n %}{% language 'nl' %}{% url 'no-prefix-translated-slug' slug='apo' %}{% endlanguage %}") == "/vertaald/apo/"   # test_args
        end
        @testset "set_language (translated)" begin
            r = post(Client(), "/i18n/setlang/", Dict("language" => "nl", "next" => "/en/account/register/"))   # test_lang_from_translated_i18n_pattern
            @test assert_redirects(r, "/nl/profiel/registreren/")
            r = post(Client(), "/i18n/setlang/", Dict("language" => "en", "next" => "/nl/gebruikers/"))
            @test assert_redirects(r, "/en/users/")
        end
    finally
        configure!(ROOT_URLCONF = old[1], MIDDLEWARE = old[2], LANGUAGES = old[3], LANGUAGE_CODE = old[4], LOCALE_PATHS = old[5])
        Juango.reload_translations!()
    end
end
