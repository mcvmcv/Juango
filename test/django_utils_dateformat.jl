# Django's utils_tests test_dateformat.py, ported (#227): the date format characters (Juango's format_date, which the
# date and time filters use), with TIME_ZONE = Europe/Copenhagen: naive datetimes in it, aware ones in their own zone,
# dates refusing time characters, the r format in English.
# julia --project=test test/django_utils_dateformat.jl   (see setup.jl; no database needed)
#
# Django's dateformat.format doesn't convert an aware time to the current time zone (the date filter does): `duf`
# formats as it, under {% localtime off %}'s switch. Julia's times hold milliseconds, so the microsecond tests use
# them. Not translated: the tzinfo without a name (Python's).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Juango.TimeZones

duf(d, fmt) = (old = get(task_local_storage(), :juango_localtime_off, false); task_local_storage(:juango_localtime_off, true);
               try Juango.format_date(d, fmt) finally task_local_storage(:juango_localtime_off, old) end)

@testset "django utils_tests test_dateformat: DateFormatTests" begin
    override_settings(TIME_ZONE = "Europe/Copenhagen") do
        cph = Juango.tz_named("Europe/Copenhagen")
        fromts(u) = astimezone(ZonedDateTime(unix2datetime(parse(Int, u)), tz"UTC"), cph)
        # test_date / test_naive_datetime / test_datetime_with_local_tzinfo / test_epoch
        @test Date(fromts(duf(Date(2009, 5, 16), "U"))) == Date(2009, 5, 16)
        @test DateTime(fromts(duf(DateTime(2009, 5, 16, 5, 30, 30), "U"))) == DateTime(2009, 5, 16, 5, 30, 30)
        aware = ZonedDateTime(DateTime(2009, 5, 16, 5, 30, 30), cph)
        @test fromts(duf(aware, "U")) == aware
        @test DateTime(astimezone(fromts(duf(aware, "U")), Juango.fixed_timezone(-510))) == DateTime(astimezone(aware, Juango.fixed_timezone(-510)))
        @test duf(ZonedDateTime(DateTime(1970, 1, 1), tz"UTC"), "U") == "0"
        # test_naive_ambiguous_datetime
        amb = DateTime(2015, 10, 25, 2, 30, 0)
        @test duf(amb, "I") == "" && duf(amb, "O") == "" && duf(amb, "T") == "" && duf(amb, "Z") == ""
        # test_empty_format / test_am_pm / test_microsecond
        my_birthday = DateTime(1979, 7, 8, 22, 0)
        @test duf(my_birthday, "") == ""
        @test duf(Dates.Time(7), "a") == "a.m." && duf(Dates.Time(19), "a") == "p.m."
        @test duf(Dates.Time(7), "A") == "AM" && duf(Dates.Time(19), "A") == "PM"
        @test duf(DateTime(2009, 5, 16, 0, 0, 0, 123), "u") == "123000"
        # test_date_formats
        for (spec, expected) in (("b", "jul"), ("d", "08"), ("D", "Sun"), ("E", "July"), ("F", "July"), ("j", "8"), ("l", "Sunday"),
                                 ("L", "False"), ("m", "07"), ("M", "Jul"), ("n", "7"), ("N", "July"), ("o", "1979"), ("S", "th"), ("t", "31"),
                                 ("w", "0"), ("W", "27"), ("y", "79"), ("Y", "1979"), ("z", "189"))
            @test duf(my_birthday, spec) == expected
        end
        # test_date_formats_c_format
        @test duf(DateTime(2008, 5, 19, 11, 45, 23, 123), "c") == "2008-05-19T11:45:23.123000"
        # test_time_formats
        for (spec, expected) in (("a", "p.m."), ("A", "PM"), ("f", "10"), ("g", "10"), ("G", "22"), ("h", "10"), ("H", "22"), ("i", "00"),
                                 ("P", "10 p.m."), ("s", "00"), ("u", "000000"))
            @test duf(my_birthday, spec) == expected
        end
        # test_dateformat / test_futuredates / test_day_of_year_leap
        @test duf(my_birthday, "Y z \\C\\E\\T") == "1979 189 CET"
        @test duf(my_birthday, "jS \\o\\f F") == "8th of July"
        @test duf(DateTime(2100, 10, 25), "Y") == "2100"
        @test duf(DateTime(2000, 12, 31), "z") == "366"
        # test_timezones
        summertime, wintertime = DateTime(2005, 10, 30, 1, 0), DateTime(2005, 10, 30, 4, 0)
        aware_dt = ZonedDateTime(DateTime(2009, 5, 16, 5, 30, 30), Juango.fixed_timezone(-210))
        for (spec, expected) in (("e", ""), ("O", "+0100"), ("r", "Sun, 08 Jul 1979 22:00:00 +0100"), ("T", "CET"), ("U", "300315600"), ("Z", "3600"))
            @test duf(my_birthday, spec) == expected
        end
        @test duf(aware_dt, "e") == "-0330"
        @test duf(aware_dt, "r") == "Sat, 16 May 2009 05:30:30 -0330"
        @test duf(summertime, "I") == "1" && duf(summertime, "O") == "+0200"
        @test duf(wintertime, "I") == "0" && duf(wintertime, "O") == "+0100"
        for spec in ("e", "O", "T", "Z")
            @test duf(Dates.Time(12), spec) == ""
        end
        @test duf(aware_dt, "O") == "-0330"
        # test_invalid_time_format_specifiers
        for spec in ("a", "A", "f", "g", "G", "h", "H", "i", "P", "s", "u")
            @test_throws "The format for date objects may not contain time-related format specifiers (found '$spec')." duf(Date(1984, 8, 7), spec)
        end
        # test_e_format_with_named_time_zone
        @test duf(ZonedDateTime(DateTime(1970, 1, 1), tz"UTC"), "e") == "UTC"
        # test_P_format
        for (expected, t) in (("midnight", Dates.Time(0)), ("noon", Dates.Time(12)), ("4 a.m.", Dates.Time(4)), ("8:30 a.m.", Dates.Time(8, 30)),
                              ("4 p.m.", Dates.Time(16)), ("8:30 p.m.", Dates.Time(20, 30)))
            @test duf(t, "P") == expected
        end
        # test_r_format_with_date / test_r_format_with_non_en_locale
        @test duf(Date(2022, 7, 1), "r") == "Fri, 01 Jul 2022 00:00:00 +0200"
        @test Juango.with_language("fr") do
            duf(my_birthday, "r")
        end == "Sun, 08 Jul 1979 22:00:00 +0100"
        # test_S_format
        for (expected, days) in (("st", (1, 21, 31)), ("nd", (2, 22)), ("rd", (3, 23)), ("th", [n for n in 4:30 if !(n in (21, 22, 23))]))
            for dd in days
                @test duf(Date(1970, 1, dd), "S") == expected
            end
        end
        # test_y_format_year_before_1000 / test_Y_format_year_before_1000
        for (y, expected) in ((476, "76"), (42, "42"), (4, "04"))
            @test duf(DateTime(y, 9, 8, 5, 0), "y") == expected
        end
        @test duf(DateTime(1, 1, 1), "Y") == "0001" && duf(DateTime(999, 1, 1), "Y") == "0999"
        # test_twelve_hour_format
        for (h, g, hh) in ((0, "12", "12"), (1, "1", "01"), (11, "11", "11"), (12, "12", "12"), (13, "1", "01"), (23, "11", "11"))
            @test duf(DateTime(2000, 1, 1, h), "g") == g && duf(DateTime(2000, 1, 1, h), "h") == hh
        end
    end
end
