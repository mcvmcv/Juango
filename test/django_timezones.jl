# Django's time zone tests, ported (#227): tests/utils_tests/test_timezone.py (TimezoneTests) and the
# template parts of tests/timezones (TemplateTests).
# julia --project=test test/django_timezones.jl   (see setup.jl)
#
# Differences kept: Juango's make_aware leaves an aware datetime as it is and localtime/localdate pass
# a naive one through (Django: ValueError). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DTZ_EAT = Juango.TimeZones.TimeZone("Africa/Nairobi")     # UTC+3
const DTZ_ICT = Juango.TimeZones.TimeZone("Asia/Bangkok")       # UTC+7
const DTZ_PARIS = Juango.TimeZones.TimeZone("Europe/Paris")
dtz_utc(args...) = Juango.TimeZones.ZonedDateTime(DateTime(args...), Juango.UTC_TZ)

@testset "django timezones: TimezoneTests" begin
    override_settings(USE_TZ = false) do                                                  # test_now
        @test timezone_now() isa DateTime
    end
    override_settings(USE_TZ = true) do
        @test timezone_now() isa Juango.TimeZones.ZonedDateTime && Juango.TimeZones.timezone(timezone_now()) == Juango.UTC_TZ
    end
    override_settings(TIME_ZONE = "Africa/Nairobi") do                                    # test_override
        @test get_current_timezone() == DTZ_EAT
        with_timezone(DTZ_ICT) do
            @test get_current_timezone() == DTZ_ICT
            with_timezone(nothing) do                                                     # test_override_decorator / override(None)
                @test get_current_timezone() == DTZ_EAT
            end
            @test get_current_timezone() == DTZ_ICT
        end
        @test get_current_timezone() == DTZ_EAT
        activate_timezone!(DTZ_ICT)                                                       # test_override_string_tz / activate
        try
            with_timezone("Asia/Tokyo") do
                @test string(get_current_timezone()) == "Asia/Tokyo"
            end
            @test get_current_timezone() == DTZ_ICT
        finally
            deactivate_timezone!()
        end
        @test get_current_timezone() == DTZ_EAT
    end
    aware = Juango.TimeZones.ZonedDateTime(DateTime(2015, 1, 1, 0, 0, 1), DTZ_ICT)               # test_localdate
    @test localdate(aware, DTZ_EAT) == Date(2014, 12, 31)
    @test localdate(aware, DTZ_ICT) == Date(2015, 1, 1)
    with_timezone(DTZ_EAT) do
        @test localdate(aware) == Date(2014, 12, 31)
    end
    @test localtime(aware, DTZ_EAT) == aware && DateTime(localtime(aware, DTZ_EAT)) == DateTime(2014, 12, 31, 20, 0, 1)
    z = make_aware(DateTime(2011, 9, 1, 13, 20, 30), DTZ_EAT)                             # test_make_aware
    @test z == Juango.TimeZones.ZonedDateTime(DateTime(2011, 9, 1, 13, 20, 30), DTZ_EAT) && Juango.is_aware(z)
    @test make_naive(Juango.TimeZones.ZonedDateTime(DateTime(2011, 9, 1, 13, 20, 30), DTZ_EAT), DTZ_EAT) == DateTime(2011, 9, 1, 13, 20, 30)   # test_make_naive
    @test make_naive(Juango.TimeZones.ZonedDateTime(DateTime(2011, 9, 1, 17, 20, 30), DTZ_ICT), DTZ_EAT) == DateTime(2011, 9, 1, 13, 20, 30)
    with_timezone(DTZ_EAT) do                                                             # test_make_aware_no_tz
        @test make_aware(DateTime(2011, 9, 1, 13, 20, 30)) == Juango.TimeZones.ZonedDateTime(DateTime(2011, 9, 1, 13, 20, 30), DTZ_EAT)
        @test make_naive(dtz_utc(2011, 9, 1, 10, 20, 30)) == DateTime(2011, 9, 1, 13, 20, 30)   # test_make_naive_no_tz
    end
    amb = make_aware(DateTime(2015, 10, 25, 2, 30), DTZ_PARIS)                            # test_make_aware_zoneinfo_ambiguous (fold 0: the first)
    @test Juango.TimeZones.astimezone(amb, Juango.UTC_TZ) == dtz_utc(2015, 10, 25, 0, 30)
    gap = make_aware(DateTime(2015, 3, 29, 2, 30), DTZ_PARIS)                             # test_make_aware_zoneinfo_non_existent (the offset before)
    @test Juango.TimeZones.astimezone(gap, Juango.UTC_TZ) == dtz_utc(2015, 3, 29, 1, 30)
    @test DateTime(gap) == DateTime(2015, 3, 29, 3, 30)
    @test make_aware(DateTime(2015, 3, 29, 2, 30), "Europe/Paris") == gap                 # (a name will do)
end

@testset "django timezones: TemplateTests" begin
    t(s, ctx = Dict{String,Any}()) = render(Template(s), Dict{String,Any}(ctx))
    override_settings(USE_TZ = true, TIME_ZONE = "Africa/Nairobi") do
        dt = dtz_utc(2011, 9, 1, 10, 20, 30)                                             # test_localtime_templatetag_and_filters
        ctx = Dict{String,Any}("dt" => dt, "ict" => DTZ_ICT)
        @test t("{% load tz %}{{ dt|date:'Y-m-d H:i:s O' }}", ctx) == "2011-09-01 13:20:30 +0300"
        @test t("{% load tz %}{{ dt|localtime|date:'Y-m-d H:i:s O' }}", ctx) == "2011-09-01 13:20:30 +0300"
        @test t("{% load tz %}{{ dt|utc|date:'Y-m-d H:i:s O' }}", ctx) == "2011-09-01 10:20:30 +0000"
        @test t("{% load tz %}{{ dt|timezone:ict|date:'Y-m-d H:i:s O' }}", ctx) == "2011-09-01 17:20:30 +0700"
        @test t("{% load tz %}{{ dt|timezone:'Asia/Bangkok'|date:'H:i' }}", ctx) == "17:20"
        @test t("{% load tz %}{% localtime off %}{{ dt|date:'H:i O' }}{% endlocaltime %}", ctx) == "10:20 +0000"
        @test t("{% load tz %}{% localtime off %}{{ dt|localtime|date:'H:i' }}{% endlocaltime %}", ctx) == "13:20"   # (the filter still converts)
        @test t("{% localtime on %}{{ dt|date:'H:i' }}{% endlocaltime %}", ctx) == "13:20"
        @test t("{% load tz %}{{ dt|timezone:'Europe/Paris'|date:'H:i e' }}", ctx) == "12:20 Europe/Paris"   # test_localtime_filters_with_iana
        naive = DateTime(2011, 9, 1, 13, 20, 30)                                          # (a naive datetime: taken to be in TIME_ZONE)
        @test t("{% load tz %}{{ dt|utc|date:'H:i' }}", Dict{String,Any}("dt" => naive)) == "10:20"
        for bad in ("{% load tz %}{{ dt|localtime }}", "{% load tz %}{{ dt|utc }}", "{% load tz %}{{ dt|timezone:tz }}")   # test_localtime_filters_do_not_raise_exceptions
            @test t(bad, Dict{String,Any}("dt" => "2011-09-01T13:20:30", "tz" => "Europe/Paris")) == ""
        end
        @test t("{% load tz %}{{ dt|timezone:tz }}", Dict{String,Any}("dt" => dt, "tz" => "Nowhere/Atlantis")) == ""
        @test t("{% load tz %}{{ dt|timezone:tz }}", Dict{String,Any}("dt" => dt, "tz" => 42)) == ""
        for bad in ("{% localtime foo %}{% endlocaltime %}", "{% localtime on off %}{% endlocaltime %}")   # test_localtime_templatetag_invalid_argument
            @test_throws Juango.TemplateSyntaxError Template(bad)
        end
        tpl = "{% timezone tz %}{{ dt|date:'H:i' }}{% endtimezone %}"                     # test_timezone_templatetag
        @test t(tpl, Dict{String,Any}("dt" => dt, "tz" => DTZ_ICT)) == "17:20"
        @test t(tpl, Dict{String,Any}("dt" => dt, "tz" => "Asia/Bangkok")) == "17:20"
        @test t(tpl, Dict{String,Any}("dt" => dt, "tz" => nothing)) == "13:20"            # (None: TIME_ZONE)
        @test t("{% timezone 'Asia/Bangkok' %}{% timezone 'Europe/Paris' %}{{ dt|date:'H:i' }}{% endtimezone %}{{ dt|date:'H:i' }}{% endtimezone %}",
                Dict{String,Any}("dt" => dt)) == "12:2017:20"
        @test_throws Juango.TemplateSyntaxError Template("{% timezone %}{% endtimezone %}")   # test_timezone_templatetag_invalid_argument
        @test_throws Juango.TemplateSyntaxError Template("{% timezone a b %}{% endtimezone %}")
        tpl = "{% load tz %}{% get_current_timezone as time_zone %}{{ time_zone }}"         # test_get_current_timezone_templatetag
        @test t(tpl) == "Africa/Nairobi"
        @test with_timezone(() -> t(tpl), DTZ_ICT) == "Asia/Bangkok"
        @test t("{% load tz %}{% timezone 'Asia/Bangkok' %}{% get_current_timezone as time_zone %}{% endtimezone %}{{ time_zone }}") == "Asia/Bangkok"
        @test_throws Juango.TemplateSyntaxError Template("{% load tz %}{% get_current_timezone %}")   # test_get_current_timezone_templatetag_invalid_argument
        @test_throws Juango.TemplateSyntaxError Template("{% load tz %}{% get_current_timezone as %}")
        @test Juango.cp_tz(nothing) == Dict("TIME_ZONE" => "Africa/Nairobi")             # test_tz_template_context_processor
        @test with_timezone(() -> Juango.cp_tz(nothing), DTZ_ICT)["TIME_ZONE"] == "Asia/Bangkok"
        @test with_timezone(() -> t("{{ dt|date:'Y-m-d' }} at {{ dt|time:'H:i:s' }}", Dict{String,Any}("dt" => dtz_utc(2011, 9, 1, 20, 20, 20))), DTZ_ICT) ==
              "2011-09-02 at 03:20:20"                                                    # test_date_and_time_template_filters
        @test with_timezone(() -> t("{% localtime off %}{{ dt|date:'Y-m-d' }} at {{ dt|time:'H:i:s' }}{% endlocaltime %}",
                                   Dict{String,Any}("dt" => dtz_utc(2011, 9, 1, 20, 20, 20))), DTZ_ICT) == "2011-09-01 at 20:20:20"   # ..._honor_localtime
        @test with_timezone(() -> t("{% now 'O' %}"), DTZ_ICT) == "+0700"                # test_now_template_tag_uses_current_time_zone
        @test t("{% now 'O' %}") == "+0300"
    end
    # not translated: the database tests (LegacyDatabaseTests, NewDatabaseTests: aware values in queries,
    # USE_TZ = false with a database TIME_ZONE), the form and admin tests, pytz, the serialization tests
end
