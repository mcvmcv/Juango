# Django's utils_tests test_timesince.py, ported (#227): timesince and timeuntil (calendar years and months, depth,
# dates, aware times), for naive and aware times (TimesinceTests, TZAwareTimesinceTests).
# julia --project=test test/django_utils_timesince.jl   (see setup.jl; no database needed)
#
# Not translated: the Czech time_strings test (Juango ships a German catalog only: a custom time_strings is tested
# instead) and the tzinfo-without-offset class (Python's).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Juango.TimeZones

dts_onemicro, dts_onesec, dts_onemin, dts_onehour = Millisecond(0), Second(1), Minute(1), Hour(1)
dts_oneday, dts_oneweek, dts_onemonth, dts_oneyear = Day(1), Day(7), Day(31), Day(366)

for (label, base) in (("TimesinceTests", DateTime(2007, 8, 14, 13, 46, 0)),
                      ("TZAwareTimesinceTests", ZonedDateTime(DateTime(2007, 8, 14, 13, 46, 0), tz"America/Chicago")))
    @testset "django utils_tests test_timesince: $label" begin
        t = base
        ts(a, b; kw...) = Juango.timesince(a, b; kw...)
        tu(a, b; kw...) = Juango.timeuntil(a, b; kw...)
        # test_equal_datetimes / test_ignore_microseconds_and_seconds
        @test ts(t, t) == "0 minutes"
        @test ts(t, t + Millisecond(1)) == "0 minutes" && ts(t, t + dts_onesec) == "0 minutes"
        # test_other_units
        @test ts(t, t + dts_onemin) == "1 minute"
        @test ts(t, t + dts_onehour) == "1 hour"
        @test ts(t, t + dts_oneday) == "1 day"
        @test ts(t, t + dts_oneweek) == "1 week"
        @test ts(t, t + dts_onemonth) == "1 month"
        @test ts(t, t + dts_oneyear) == "1 year"
        # test_multiple_units / test_display_first_unit
        @test ts(t, t + 2dts_oneday + 6dts_onehour) == "2 days, 6 hours"
        @test ts(t, t + 2dts_oneweek + 2dts_oneday) == "2 weeks, 2 days"
        @test ts(t, t + 2dts_oneweek + 3dts_onehour + 4dts_onemin) == "2 weeks"
        @test ts(t, t + 4dts_oneday + 5dts_onemin) == "4 days"
        # test_display_second_before_first
        for d in (Millisecond(1), dts_onesec, dts_onemin, dts_onehour, dts_oneday, dts_oneweek, dts_onemonth, dts_oneyear,
                  2dts_oneday + 6dts_onehour, 2dts_oneweek + 2dts_oneday, 2dts_oneweek + 3dts_onehour + 4dts_onemin, 4dts_oneday + 5dts_onemin)
            @test ts(t, t - d) == "0 minutes"
        end
        # (test_second_before_equal_first_humanize_time_strings: a custom time_strings)
        strs = Dict("minute" => n -> "$n minut")
        for now_ in (t, t - Millisecond(1), t - dts_oneday)
            @test ts(t, now_; time_strings = strs) == "0 minut"
        end
        # test_thousand_years_ago
        t1000 = t - Year(1000)
        @test ts(t1000, t) == "1000 years" && tu(t, t1000) == "1000 years"
        # test_depth
        tt = t + dts_oneyear + dts_onemonth + dts_oneweek + dts_oneday + dts_onehour
        for (value, depth, expected) in ((tt, 1, "1 year"), (tt, 2, "1 year, 1 month"), (tt, 3, "1 year, 1 month, 1 week"),
                                         (tt, 4, "1 year, 1 month, 1 week, 1 day"),
                                         (tt, 5, "1 year, 1 month, 1 week, 1 day, 1 hour"),
                                         (tt, 6, "1 year, 1 month, 1 week, 1 day, 1 hour"),
                                         (t + dts_onehour, 5, "1 hour"), (t + 4dts_onemin, 3, "4 minutes"),
                                         (t + dts_onehour + dts_onemin, 1, "1 hour"), (t + dts_oneday + dts_onehour, 1, "1 day"),
                                         (t + dts_oneweek + dts_oneday, 1, "1 week"), (t + dts_onemonth + dts_oneweek, 1, "1 month"),
                                         (t + dts_oneyear + dts_onemonth, 1, "1 year"), (t + dts_oneyear + dts_oneweek + dts_oneday, 3, "1 year"))
            @test ts(t, value; depth) == expected
            @test tu(value, t; depth) == expected
        end
        # test_depth_invalid
        @test_throws "depth must be greater than 0." ts(t, t; depth = 0)
    end
end

@testset "django utils_tests test_timesince: TimesinceTests (dates, months, time zones)" begin
    # test_months_edge
    t = DateTime(2022, 1, 1)
    for (value, expected) in ((DateTime(2022, 1, 31), "4 weeks, 2 days"), (DateTime(2022, 2, 1), "1 month"),
                              (DateTime(2022, 2, 28), "1 month, 3 weeks"), (DateTime(2022, 3, 1), "2 months"),
                              (DateTime(2022, 3, 31), "2 months, 4 weeks"), (DateTime(2022, 4, 1), "3 months"),
                              (DateTime(2022, 4, 30), "3 months, 4 weeks"), (DateTime(2022, 5, 1), "4 months"),
                              (DateTime(2022, 5, 31), "4 months, 4 weeks"), (DateTime(2022, 6, 1), "5 months"),
                              (DateTime(2022, 6, 30), "5 months, 4 weeks"), (DateTime(2022, 7, 1), "6 months"),
                              (DateTime(2022, 7, 31), "6 months, 4 weeks"), (DateTime(2022, 8, 1), "7 months"),
                              (DateTime(2022, 8, 31), "7 months, 4 weeks"), (DateTime(2022, 9, 1), "8 months"),
                              (DateTime(2022, 9, 30), "8 months, 4 weeks"), (DateTime(2022, 10, 1), "9 months"),
                              (DateTime(2022, 10, 31), "9 months, 4 weeks"), (DateTime(2022, 11, 1), "10 months"),
                              (DateTime(2022, 11, 30), "10 months, 4 weeks"), (DateTime(2022, 12, 1), "11 months"),
                              (DateTime(2022, 12, 31), "11 months, 4 weeks"))
        @test Juango.timesince(t, value) == expected
    end
    # test_date_objects / test_both_date_objects
    today = Dates.today()
    @test Juango.timesince(today + Day(1)) == "0 minutes"
    @test Juango.timeuntil(today - Day(1)) == "0 minutes"
    @test Juango.timeuntil(today + Day(1), today) == "1 day"
    @test Juango.timeuntil(today - Day(1), today) == "0 minutes"
    @test Juango.timeuntil(today + Day(7), today) == "1 week"
    # test_leap_year / test_leap_year_new_years_eve
    sd = Date(2016, 12, 25)
    @test Juango.timeuntil(sd + Day(7), sd) == "1 week" && Juango.timesince(sd, sd + Day(7)) == "1 week"
    t = Date(2016, 12, 31)
    now_ = DateTime(2016, 12, 31, 18, 0, 0)
    @test Juango.timesince(t + Day(1), now_) == "0 minutes" && Juango.timeuntil(t - Day(1), now_) == "0 minutes"
    # test_different_timezones
    nowz = now(tz"UTC")
    nowz_i = astimezone(nowz, FixedTimeZone("+0315", 195 * 60))
    @test Juango.timesince(nowz) == "0 minutes" && Juango.timesince(nowz_i) == "0 minutes"
    @test Juango.timesince(nowz, nowz_i) == "0 minutes"
    @test Juango.timeuntil(nowz) == "0 minutes" && Juango.timeuntil(nowz_i) == "0 minutes"
    @test Juango.timeuntil(nowz, nowz_i) == "0 minutes"
    # test_less_than_a_day_with_zoneinfo / test_less_than_a_day_cross_day_with_zoneinfo
    ktm = astimezone(now(tz"UTC"), tz"Asia/Kathmandu")
    for (value, expected) in ((ktm, "0 minutes"), (ktm - Millisecond(1), "0 minutes"), (ktm - Second(1), "0 minutes"),
                              (ktm - Minute(1), "1 minute"), (ktm - Hour(1), "1 hour"))
        @test Juango.timesince(value) == expected
    end
    ktm = ZonedDateTime(DateTime(2023, 4, 14, 1, 30, 30), tz"Asia/Kathmandu")
    ktm_utc = astimezone(ktm, tz"UTC")
    for (value, expected) in ((ktm, "0 minutes"), (ktm - Millisecond(1), "0 minutes"), (ktm - Second(1), "0 minutes"),
                              (ktm - Minute(1), "1 minute"), (ktm - Hour(1), "1 hour"))
        @test Juango.timesince(value, ktm_utc) == expected
    end
end
