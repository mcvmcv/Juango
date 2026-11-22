# Django's i18n tests, ported (#227), first part: tests/i18n (TranslationTests' API, MiscTests: Accept-Language
# parsing, supported variants, languages from paths, cookies and headers) and tests/utils_tests/test_numberformat.py.
# julia --project=test test/django_i18n.jl   (see setup.jl)
#
# Juango throws KeyError where Django raises LookupError. Not translated here (later parts): the
# formatting and localization tests (FormattingTests), URL patterns with language prefixes, makemessages
# and compilemessages, the JavaScript catalog. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django i18n: TranslationTests" begin
    for (lang, loc) in (("en", "en"), ("EN", "en"), ("en-us", "en_US"), ("EN-US", "en_US"), ("en_US", "en_US"),   # test_to_locale
                        ("sr-latn", "sr_Latn"), ("sr-LATN", "sr_Latn"), ("sr_Latn", "sr_Latn"),
                        ("ber-MA", "ber_MA"), ("BER-MA", "ber_MA"), ("BER_MA", "ber_MA"), ("ber_MA", "ber_MA"),
                        ("nl-nl-x-informal", "nl_NL-x-informal"), ("NL-NL-X-INFORMAL", "nl_NL-x-informal"),
                        ("sr-latn-x-informal", "sr_Latn-x-informal"), ("SR-LATN-X-INFORMAL", "sr_Latn-x-informal"))
        @test Juango.to_locale(lang) == loc
    end
    @test Juango.to_language("en_US") == "en-us" && Juango.to_language("sr_Lat") == "sr-lat"   # test_to_language
    with_language("ar") do                                                                # test_language_bidi
        @test Juango.get_language_bidi()
    end
    @test !Juango.get_language_bidi("en") && Juango.get_language_bidi("he") && Juango.get_language_bidi("ckb") && Juango.get_language_bidi("ug")
    override_settings(LANGUAGES_BIDI = ["en"]) do
        @test Juango.get_language_bidi("en-gb") && !Juango.get_language_bidi("ar")
    end
    @test gettext("") == ""                                                               # test_empty_value
    with_language("de") do
        @test gettext("") == "" && pgettext("ctx", "") == ""                              # (not the catalog's header)
        s = gettext(mark_safe("Password"))                                                # test_safe_status
        @test s isa Juango.SafeString
        @test pgettext("ctx", mark_safe("Password")) isa Juango.SafeString
        @test ngettext(mark_safe("Password"), "Passwords", 1) isa Juango.SafeString
    end
    @test gettext("not translated at all") == "not translated at all"
    l = gettext_lazy("Password")                                                          # test_lazy_objects
    @test l == "Password" && "Password" == l
    with_language("de") do
        @test string(l) == gettext("Password")                                            # (translated when used)
    end
    nl = ngettext_lazy("%(num)d good result", "%(num)d good results", 4)                  # test_ngettext_lazy
    @test interpolate(nl, Dict("num" => 4)) == "4 good results"
    @test interpolate(ngettext("%(num)d good result", "%(num)d good results", 1), Dict("num" => 1)) == "1 good result"
    @test pgettext("unexisting context", "May") == "May"                                  # test_pgettext
end

@testset "django i18n: MiscTests" begin
    good = [("de", [("de", 1.0)]), ("en-AU", [("en-au", 1.0)]), ("es-419", [("es-419", 1.0)]),   # test_parse_spec_http_header
            ("*;q=1.00", [("*", 1.0)]), ("en-AU;q=0.123", [("en-au", 0.123)]), ("en-au;q=0.5", [("en-au", 0.5)]),
            ("en-au;q=1.0", [("en-au", 1.0)]), ("da, en-gb;q=0.25, en;q=0.5", [("da", 1.0), ("en", 0.5), ("en-gb", 0.25)]),
            ("en-au-xx", [("en-au-xx", 1.0)]),
            ("de,en-au;q=0.75,en-us;q=0.5,en;q=0.25,es;q=0.125,fa;q=0.125",
             [("de", 1.0), ("en-au", 0.75), ("en-us", 0.5), ("en", 0.25), ("es", 0.125), ("fa", 0.125)]),
            ("*", [("*", 1.0)]), ("de;q=0.", [("de", 0.0)]), ("en; q=1,", [("en", 1.0)]),
            ("en; q=1.0, * ; q=0.5", [("en", 1.0), ("*", 0.5)]),
            ("en" * "-x"^20, [("en-" * "x-"^19 * "x", 1.0)]),
            ("en-US;q=0.9, de;q=0.8, fr;q=0.7, it;q=0.6, pt;q=0.5, sk;q=0.4",
             [("en-us", 0.9), ("de", 0.8), ("fr", 0.7), ("it", 0.6), ("pt", 0.5), ("sk", 0.4)]),
            (join(fill("en; q=1.0", 20), ", "), fill(("en", 1.0), 20))]
    for (h, want) in good
        @test Juango.parse_accept_lang_header(h) == want
    end
    bad = ["en-gb;q=1.0000", "en;q=0.1234", "en;q=.2", "abcdefghi-au", "**", "en,,gb", "en-au;q=0.1.0",
           "X"^97 * "Z,en", "da, en-gb;q=0.8, en;q=0.7,#", "de;q=2.0", "de;q=0.a", "12-345", "", "en;q=1e0", "en-au;q=１.０",
           "xxxxxxxx" * "-xxxxxxxx"^500]                                                  # (too long: nothing)
    for h in bad
        @test isempty(Juango.parse_accept_lang_header(h))
    end
    @test length(Juango.parse_accept_lang_header(join(fill("en; q=1.0", 100), ", "))) < 100   # (only the first 500 characters)

    override_settings(LANGUAGES = [("en", "English"), ("en-gb", "British English"), ("de", "German"), ("de-at", "Austrian German"),
                                   ("pl", "Polish"), ("pt-br", "Portuguese (Brazil)")]) do
        g = Juango.get_supported_language_variant                                         # test_get_supported_language_variant_real
        @test g("en") == "en" && g("en-gb") == "en-gb" && g("en-gb"; strict = true) == "en-gb"
        @test g("de") == "de" && g("de-at") == "de-at" && g("de-de") == "de" && g("de-de"; strict = true) == "de"
        @test g("pl") == "pl" && g("pl"; strict = true) == "pl"
        @test g("pt") == "pt-br"                                                          # (another variant of the base)
        @test_throws KeyError g("pt"; strict = true)
        for x in ("xyz", "xy-zz", "", "x"^501)
            @test_throws KeyError g(x)
        end
        gp = Juango.get_language_from_path                                                # test_get_language_from_path_real
        @test gp("/pl/") == "pl" && gp("/pl") == "pl" && gp("/xyz/") === nothing && gp("/en-gb/") == "en-gb"
        @test gp("/de-at/") == "de-at" && gp("/de/") == "de" && gp("/de-simple-page-test/") === nothing
        req(h = Dict{String,String}(); cookies = Dict{String,String}()) =
            (r = Request("GET", "/"; headers = merge(Dict("host" => "testserver"), h)); merge!(r.COOKIES, cookies); r)
        lr = Juango.language_from_request                                                 # test_parse_literal_http_header
        @test lr(req(Dict("accept-language" => "pt-br"))) == "pt-br"
        @test lr(req(Dict("accept-language" => "pt"))) == "pt-br"                         # (a variant of the base)
        @test lr(req(Dict("accept-language" => "es,de"))) == "de"
        @test lr(req(Dict("accept-language" => "de-at,en;q=0.5"))) == "de-at"
        @test lr(req(Dict("accept-language" => "en-gb;q=0.8, de;q=0.9"))) == "de"         # (by q)
        @test lr(req(Dict("accept-language" => "*, de"))) == "en"                         # (* ends the list: LANGUAGE_CODE)
        @test lr(req(Dict("accept-language" => "xyz"))) == "en"
        @test lr(req(Dict("accept-language" => "de"); cookies = Dict(settings.LANGUAGE_COOKIE_NAME => "pl"))) == "pl"   # test_parse_language_cookie
        @test lr(req(Dict("accept-language" => "de"); cookies = Dict(settings.LANGUAGE_COOKIE_NAME => "xyz"))) == "de"
        @test lr(req(; cookies = Dict(settings.LANGUAGE_COOKIE_NAME => "de-ch"))) == "de"
    end
end

@testset "django utils: numberformat" begin
    nf = Juango.numberformat
    @test nf(1234, ".") == "1234"                                                          # test_format_number
    @test nf(1234.2, ".") == "1234.2"
    @test nf(1234, "."; decimal_pos = 2) == "1234.00"
    @test nf(1234, "."; grouping = 2, thousand_sep = ",") == "1234"
    @test nf(1234, "."; grouping = 2, thousand_sep = ",", force_grouping = true) == "12,34"
    @test nf(-1234.33, "."; decimal_pos = 1) == "-1234.3"
    override_settings(USE_THOUSAND_SEPARATOR = true) do
        @test nf(1234, "."; grouping = 3, thousand_sep = ",", use_l10n = false) == "1234"
        @test nf(1234, "."; grouping = 3, thousand_sep = ",", use_l10n = true) == "1,234"
        @test nf(1234, "."; grouping = 3, thousand_sep = ",") == "1,234"
    end
    @test nf("1234", ".") == "1234" && nf("1234.2", ".") == "1234.2"                       # test_format_string
    @test nf("1234", "."; decimal_pos = 2) == "1234.00"
    @test nf("1234", "."; grouping = 2, thousand_sep = ",", force_grouping = true) == "12,34"
    @test nf("-1234.33", "."; decimal_pos = 1) == "-1234.3"
    @test nf("10000", "."; grouping = 3, thousand_sep = "comma", force_grouping = true) == "10comma000"
    @test nf(1234567, "."; grouping = (3, 2, 0), thousand_sep = ",", force_grouping = true) == "12,34,567"   # (Indian grouping)
    @test nf(12345678901, "."; grouping = (3, 2, 0), thousand_sep = ",", force_grouping = true) == "12,34,56,78,901"
    int_max = BigInt(floatmax(Float64))                                                    # test_large_number
    most_max = "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368"
    @test nf(int_max, ".") == most_max
    @test nf(-int_max, ".") == "-" * most_max
    @test nf(2 * int_max, ".") == string(2 * int_max)
    for (value, pos, want) in ((9e-10, 10, "0.0000000009"), (9e-19, 2, "0.00"), (0.00000000000099, 0, "0"),   # test_float_numbers
                               (0.00000000000099, 13, "0.0000000000009"), (1e16, nothing, "10000000000000000"),
                               (1e16, 2, "10000000000000000.00"), (3.0, nothing, "3.0"), (-1e16, nothing, "-10000000000000000"))
        @test nf(value, "."; decimal_pos = pos) == want
    end
    @test nf(1e16, "."; thousand_sep = ",", grouping = 3, force_grouping = true) == "10,000,000,000,000,000"
    @test nf(1e16, "."; decimal_pos = 2, thousand_sep = ",", grouping = 3, force_grouping = true) == "10,000,000,000,000,000.00"
    D = Juango.Decimal                                                                     # test_decimal_numbers
    @test nf(D("1234"), ".") == "1234" && nf(D("1234.2"), ".") == "1234.2" && nf(D("1234"), "."; decimal_pos = 2) == "1234.00"
    @test nf(D("1234"), "."; grouping = 2, thousand_sep = ",", force_grouping = true) == "12,34"
    @test nf(D("-1234.33"), "."; decimal_pos = 1) == "-1234.3"
    @test nf(D("0.00000001"), "."; decimal_pos = 8) == "0.00000001"
    @test nf(D("9e-19"), "."; decimal_pos = 2) == "0.00" && nf(D(".00000000000099"), "."; decimal_pos = 0) == "0"
    @test nf(D("1e16"), "."; thousand_sep = ",", grouping = 3, force_grouping = true) == "10,000,000,000,000,000"
    @test nf(D("1e16"), "."; decimal_pos = 2, thousand_sep = ",", grouping = 3, force_grouping = true) == "10,000,000,000,000,000.00"
    @test nf(D("3."), ".") == "3" && nf(D("3.0"), ".") == "3.0"
    for (value, pos, want) in (("9e201", nothing, "9e+201"), ("9e200", nothing, "9e+200"), ("1.2345e999", 2, "1.23e+999"),   # (very large & small)
                               ("9e-999", nothing, "9e-999"), ("1e-7", 8, "0.00000010"), ("1e-8", 8, "0.00000001"),
                               ("1e-9", 8, "0.00000000"), ("1e-10", 8, "0.00000000"), ("1e-11", 8, "0.00000000"),
                               ("1" * "0"^300, 3, "1.000e+300"), ("0." * "0"^299 * "1234", 3, "0.000"))
        @test nf(D(value), "."; decimal_pos = pos) == want
    end
end
