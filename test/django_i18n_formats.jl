# Django's i18n formatting tests, ported (#227): tests/i18n FormattingTests (get_format, sanitize_separators,
# localize_input, {% localize %} and |unlocalize, the locale's separators in number formatting).
# julia --project=test test/django_i18n_formats.jl   (see setup.jl)
#
# Django 5 localizes template output by default; Juango only inside {% localize on %} or with |localize
# (#271). Juango has formats for fewer locales than Django; the others use the settings. Each test keeps
# its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django i18n: FormattingTests" begin
    t(s, d = Dict{String,Any}()) = render(Template(s), Dict{String,Any}(d))
    n, f, dt, d = 66666, 99999.999, DateTime(2009, 12, 31, 20, 50), Date(2009, 12, 31)
    @test Juango.get_format("DEBUG") == "DEBUG"                                           # test_format_arbitrary_settings
    @test Juango.get_format("SECRET_KEY") == "SECRET_KEY"
    with_language("de") do                                                                # test_get_format (the locale's)
        @test Juango.get_format("DECIMAL_SEPARATOR") == "," && Juango.get_format("THOUSAND_SEPARATOR") == "."
        @test Juango.get_format("DATE_FORMAT") == "j. F Y" && Juango.get_format("SHORT_DATE_FORMAT") == "d.m.Y"
        @test Juango.get_format("FIRST_DAY_OF_WEEK") == 1 && Juango.get_format("NUMBER_GROUPING") == 3
        @test "%d.%m.%Y" in Juango.get_format("DATE_INPUT_FORMATS")
    end
    @test Juango.get_format("DECIMAL_SEPARATOR", "fr") == "," && Juango.get_format("THOUSAND_SEPARATOR", "fr") == " "
    override_settings(DECIMAL_SEPARATOR = "!", THOUSAND_SEPARATOR = "#", NUMBER_GROUPING = 2, FIRST_DAY_OF_WEEK = 5) do   # (a language without formats: the settings)
        with_language("ja") do
            @test Juango.get_format("DECIMAL_SEPARATOR") == "!" && Juango.get_format("THOUSAND_SEPARATOR") == "#"
            @test Juango.get_format("NUMBER_GROUPING") == 2 && Juango.get_format("FIRST_DAY_OF_WEEK") == 5
            @test Juango.get_format("DATE_FORMAT") == "N j, Y"
        end
    end
    @test Juango.get_format("de").decimal == ","                                          # (Juango's: a language's formats at once)

    @test Juango.sanitize_separators(123) == 123                                         # test_sanitize_separators
    with_language("ru") do
        override_settings(USE_THOUSAND_SEPARATOR = true) do
            @test Juango.sanitize_separators("1 234 567") == "1234567"
            @test Juango.sanitize_separators("77 777,777") == "77777.777"
            @test Juango.sanitize_separators("12 345") == "12345"                         # (a plain space for the non-breaking one)
            @test Juango.sanitize_separators("77 777,777") == "77777.777"
        end
    end
    with_language("de") do
        override_settings(USE_THOUSAND_SEPARATOR = true) do
            @test Juango.sanitize_separators("10.234") == "10234"
            @test Juango.sanitize_separators("10.10") == "10.10"                          # (#22171: a dot meant as a decimal point)
            @test Juango.sanitize_separators("1.001,10") == "1001.10"
        end
        @test Juango.sanitize_separators("1001,10") == "1001.10"                          # (no USE_THOUSAND_SEPARATOR: dots stay)
    end
    override_settings(DECIMAL_SEPARATOR = ",", THOUSAND_SEPARATOR = ".", USE_THOUSAND_SEPARATOR = true) do
        with_language("ja") do
            @test Juango.sanitize_separators("1.001,10") == "1001.10" && Juango.sanitize_separators("1001,10") == "1001.10"
            @test Juango.sanitize_separators("1001.10") == "1001.10"
            @test Juango.sanitize_separators("1,001.10") == "1.001.10"                    # (invalid output, as Django's)
        end
    end

    with_language("de") do                                                                # test_localize_input
        @test Juango.localize_input(99999.999) == "99999,999" && Juango.localize_input(n) == "66666"
        @test Juango.localize_input("A string") == "A string" && Juango.localize_input(true) == "True"
        @test Juango.localize_input(d) == "31.12.2009"
        @test Juango.localize_input(dt) == "31.12.2009 20:50:00"
        @test Juango.localize_input(dt, "%Y-%m-%d") == "2009-12-31"                      # (a default format)
        override_settings(USE_THOUSAND_SEPARATOR = true) do
            @test Juango.localize_input(1234567.5) == "1.234.567,5"
        end
    end

    with_language("de") do                                                                # test_localize_templatetag_and_filter
        ctx = Dict{String,Any}("n" => n, "f" => f, "dt" => dt, "d" => d)
        @test t("{% load l10n %}{{ f }}", ctx) == "99999,999"                             # (localized by default, as Django 5's: #271)
        @test t("{% load l10n %}{% localize off %}{{ f }}{% endlocalize %} {{ f|unlocalize }}", ctx) == "99999.999 99999.999"
        @test t("{% load l10n %}{{ f|localize }}", ctx) == "99999,999"
        @test t("{% load l10n %}{% localize on %}{{ f }}{% endlocalize %}", ctx) == "99999,999"
        @test t("{% load l10n %}{% localize %}{{ f }} {{ d }}{% endlocalize %}", ctx) == "99999,999 31. Dezember 2009"
        @test t("{% load l10n %}{% localize on %}{{ f|unlocalize }}{% endlocalize %}", ctx) == "99999.999"
        @test t("{% load l10n %}{% localize off %}{{ f }}{% endlocalize %}", ctx) == "99999.999"
        @test t("{% load l10n %}{% localize on %}{% localize off %}{{ f }}{% endlocalize %}{{ f }}{% endlocalize %}", ctx) == "99999.99999999,999"
        @test t("{% load l10n %}{{ n|unlocalize }}", ctx) == "66666"
        override_settings(USE_THOUSAND_SEPARATOR = true) do
            @test t("{% load l10n %}{% localize on %}{{ n }}{% endlocalize %}", ctx) == "66.666"
            @test t("{% load l10n %}{% localize on %}{{ n|unlocalize }}{% endlocalize %}", ctx) == "66666"
        end
        @test t("{% load l10n %}{% localize on %}{{ b }}{% endlocalize %}", Dict{String,Any}("b" => true)) == "True"   # (booleans aren't numbers)
        @test_throws TemplateSyntaxError Template("{% load l10n %}{% localize maybe %}{% endlocalize %}")   # test_localize_templatetag_invalid
        @test_throws TemplateSyntaxError Template("{% load l10n %}{% localize on off %}{% endlocalize %}")
    end
    with_language("ru") do                                                                # (Russian: a non-breaking space between thousands)
        override_settings(USE_THOUSAND_SEPARATOR = true) do
            @test Juango.number_format(1234567) == "1 234 567"
        end
    end
    # not translated: Django's 90-odd locale format modules (FORMAT_MODULE_PATH, iter_format_modules), the
    # USE_L10N deprecation tests, the admin's JavaScript input formats, localized form widgets (forms tests)
end
