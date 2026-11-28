# Django's utils_tests test_dateparse.py and test_duration.py, ported (#227): parse_date, parse_time, parse_datetime and
# parse_duration; duration_string (serial, Django's) and duration_iso_string, and their round trips.
# julia --project=test test/django_utils_dateparse.jl   (see setup.jl; no database needed)
#
# Durations are canonical CompoundPeriods (compared here by their microseconds, Juango.duration_us); a timedelta's
# negative days are Python's: "-1 01:03:05" is minus a day plus an hour and a bit. Julia's DateTime holds milliseconds.
# Not translated: test_duration's timedelta.max/min (Python's limits).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Juango.TimeZones

dup_us(; days = 0, hours = 0, minutes = 0, seconds = 0, milliseconds = 0, microseconds = 0, weeks = 0) =
    round(Int, ((((weeks * 7 + days) * 24 + hours) * 60 + minutes) * 60 + seconds) * 1e6 + milliseconds * 1e3 + microseconds)
dup_parse(s) = (d = Juango.parse_duration(s); d === nothing ? nothing : Juango.duration_us(d))
dup_tz(mins) = Juango.fixed_timezone(mins)

@testset "django utils_tests test_dateparse: DateParseTests" begin
    # test_parse_date
    @test Juango.parse_date("2012-04-23") == Date(2012, 4, 23)
    @test Juango.parse_date("2012-4-9") == Date(2012, 4, 9)
    @test Juango.parse_date("20120423") == Date(2012, 4, 23)
    @test Juango.parse_date("2012423") === nothing
    @test_throws ArgumentError Juango.parse_date("2012-04-56")
    # test_parse_time
    @test Juango.parse_time("09:15:00") == Dates.Time(9, 15)
    @test Juango.parse_time("091500") == Dates.Time(9, 15)
    @test Juango.parse_time("10:10") == Dates.Time(10, 10)
    @test Juango.parse_time("10:20:30.400") == Dates.Time(10, 20, 30, 400)
    @test Juango.parse_time("10:20:30,400") == Dates.Time(10, 20, 30, 400)
    @test Juango.parse_time("4:8:16") == Dates.Time(4, 8, 16)
    @test Juango.parse_time("00:05:23+04:00") == Dates.Time(0, 5, 23)
    for bad in ("00:05:", "00:05:23,", "00:05:23+", "00:05:23+25:00", "4:18:101", "91500")
        @test Juango.parse_time(bad) === nothing
    end
    @test_throws ArgumentError Juango.parse_time("09:15:90")
    # test_parse_datetime
    for (source, expected) in (("2012-04-23", DateTime(2012, 4, 23)), ("2012-04-23T09:15:00", DateTime(2012, 4, 23, 9, 15)),
                               ("2012-4-9 4:8:16", DateTime(2012, 4, 9, 4, 8, 16)),
                               ("2012-04-23T09:15:00Z", ZonedDateTime(DateTime(2012, 4, 23, 9, 15), dup_tz(0))),
                               ("2012-4-9 4:8:16-0320", ZonedDateTime(DateTime(2012, 4, 9, 4, 8, 16), dup_tz(-200))),
                               ("2012-04-23T10:20:30.400+02:30", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(150))),
                               ("2012-04-23T10:20:30.400+02", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(120))),
                               ("2012-04-23T10:20:30.400-02", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(-120))),
                               ("2012-04-23T10:20:30,400-02", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(-120))),
                               ("2012-04-23T10:20:30.400 +0230", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(150))),
                               ("2012-04-23T10:20:30,400 +00", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30, 400), dup_tz(0))),
                               ("2012-04-23T10:20:30   -02", ZonedDateTime(DateTime(2012, 4, 23, 10, 20, 30), dup_tz(-120))))
        got = Juango.parse_datetime(source)
        @test typeof(got) == typeof(expected) && got == expected
        expected isa ZonedDateTime && @test TimeZones.timezone(got) == TimeZones.timezone(expected)
    end
    @test Juango.parse_datetime("20120423091500") === nothing
    @test_throws ArgumentError Juango.parse_datetime("2012-04-56T09:15:90")
end

@testset "django utils_tests test_dateparse: DurationParseTests" begin
    # test_parse_python_format (Python's str(timedelta))
    for (s, us) in (("4 days, 0:15:30.100000", dup_us(days = 4, minutes = 15, seconds = 30, milliseconds = 100)),
                    ("10:15:30", dup_us(hours = 10, minutes = 15, seconds = 30)), ("4 days, 0:15:30", dup_us(days = 4, minutes = 15, seconds = 30)),
                    ("1 day, 0:00:00", dup_us(days = 1)), ("-4 days, 0:15:30", dup_us(days = -4, minutes = 15, seconds = 30)),
                    ("0:15:30", dup_us(minutes = 15, seconds = 30)), ("0:00:30", dup_us(seconds = 30)))
        @test dup_parse(s) == us
        @test Juango.duration_string(Juango.duration_from_us(us)) == s           # (and Juango writes Python's form back)
    end
    # test_parse_postgresql_format
    for (s, us) in (("1 day", dup_us(days = 1)), ("-1 day", dup_us(days = -1)), ("1 day 0:00:01", dup_us(days = 1, seconds = 1)),
                    ("1 day -0:00:01", dup_us(days = 1, seconds = -1)), ("-1 day -0:00:01", dup_us(days = -1, seconds = -1)),
                    ("-1 day +0:00:01", dup_us(days = -1, seconds = 1)),
                    ("4 days 0:15:30.1", dup_us(days = 4, minutes = 15, seconds = 30, milliseconds = 100)),
                    ("4 days 0:15:30.0001", dup_us(days = 4, minutes = 15, seconds = 30, microseconds = 100)),
                    ("-4 days -15:00:30", dup_us(days = -4, hours = -15, seconds = -30)))
        @test dup_parse(s) == us
    end
    # test_seconds / test_minutes_seconds / test_hours_minutes_seconds / test_days
    @test dup_parse("30") == dup_us(seconds = 30)
    @test dup_parse("15:30") == dup_us(minutes = 15, seconds = 30) && dup_parse("5:30") == dup_us(minutes = 5, seconds = 30)
    @test dup_parse("10:15:30") == dup_us(hours = 10, minutes = 15, seconds = 30)
    @test dup_parse("1:15:30") == dup_us(hours = 1, minutes = 15, seconds = 30)
    @test dup_parse("100:200:300") == dup_us(hours = 100, minutes = 200, seconds = 300)
    @test dup_parse("4 15:30") == dup_us(days = 4, minutes = 15, seconds = 30)
    @test dup_parse("4 10:15:30") == dup_us(days = 4, hours = 10, minutes = 15, seconds = 30)
    # test_fractions_of_seconds
    for (s, us) in (("15:30.1", dup_us(minutes = 15, seconds = 30, milliseconds = 100)), ("15:30.01", dup_us(minutes = 15, seconds = 30, milliseconds = 10)),
                    ("15:30.001", dup_us(minutes = 15, seconds = 30, milliseconds = 1)), ("15:30.0001", dup_us(minutes = 15, seconds = 30, microseconds = 100)),
                    ("15:30.00001", dup_us(minutes = 15, seconds = 30, microseconds = 10)), ("15:30.000001", dup_us(minutes = 15, seconds = 30, microseconds = 1)),
                    ("15:30,000001", dup_us(minutes = 15, seconds = 30, microseconds = 1)))
        @test dup_parse(s) == us
    end
    # test_negative
    for (s, us) in (("-4 15:30", dup_us(days = -4, minutes = 15, seconds = 30)), ("-172800", dup_us(days = -2)),
                    ("-15:30", dup_us(minutes = -15, seconds = -30)), ("-1:15:30", dup_us(hours = -1, minutes = -15, seconds = -30)),
                    ("-30.1", dup_us(seconds = -30, milliseconds = -100)), ("-30,1", dup_us(seconds = -30, milliseconds = -100)),
                    ("-00:01:01", dup_us(minutes = -1, seconds = -1)), ("-01:01", dup_us(seconds = -61)), ("-01:-01", nothing))
        @test dup_parse(s) == us
    end
    # test_iso_8601
    for (s, us) in (("P4Y", nothing), ("P4M", nothing), ("P4W", dup_us(weeks = 4)), ("P0.5W", dup_us(weeks = 0.5)), ("P0,5W", dup_us(weeks = 0.5)),
                    ("-P0.5W", dup_us(weeks = -0.5)), ("P1W1D", dup_us(weeks = 1, days = 1)), ("P4D", dup_us(days = 4)), ("-P1D", dup_us(days = -1)),
                    ("P0.5D", dup_us(hours = 12)), ("P0,5D", dup_us(hours = 12)), ("-P0.5D", dup_us(hours = -12)), ("-P0,5D", dup_us(hours = -12)),
                    ("PT5H", dup_us(hours = 5)), ("-PT5H", dup_us(hours = -5)), ("PT5M", dup_us(minutes = 5)), ("-PT5M", dup_us(minutes = -5)),
                    ("PT5S", dup_us(seconds = 5)), ("-PT5S", dup_us(seconds = -5)), ("PT0.000005S", dup_us(microseconds = 5)),
                    ("PT0,000005S", dup_us(microseconds = 5)), ("-PT0.000005S", dup_us(microseconds = -5)), ("-PT0,000005S", dup_us(microseconds = -5)),
                    ("-P4DT1H", dup_us(days = -4, hours = -1)), ("P3(3D", nothing), ("PT3)3H", nothing), ("PT3|3M", nothing), ("PT3/3S", nothing))
        @test dup_parse(s) == us
    end
end

@testset "django utils_tests test_duration: duration_string, duration_iso_string" begin
    d(; kw...) = Juango.duration_from_us(dup_us(; kw...))
    simple, days = d(hours = 1, minutes = 3, seconds = 5), d(days = 1, hours = 1, minutes = 3, seconds = 5)
    micro, neg = d(hours = 1, minutes = 3, seconds = 5, microseconds = 12345), d(days = -1, hours = 1, minutes = 3, seconds = 5)
    # TestDurationString
    @test Juango.duration_string(simple; serial = true) == "01:03:05"
    @test Juango.duration_string(days; serial = true) == "1 01:03:05"
    @test Juango.duration_string(micro; serial = true) == "01:03:05.012345"
    @test Juango.duration_string(neg; serial = true) == "-1 01:03:05"
    # TestParseDurationRoundtrip
    for x in (simple, days, micro, neg)
        @test Juango.parse_duration(Juango.duration_string(x; serial = true)) == x
        @test Juango.to_duration(Juango.duration_string(x; serial = true)) == x      # (a fixture's value read back)
    end
    # TestISODurationString / TestParseISODurationRoundtrip
    @test Juango.duration_iso_string(simple) == "P0DT01H03M05S"
    @test Juango.duration_iso_string(days) == "P1DT01H03M05S"
    @test Juango.duration_iso_string(micro) == "P0DT01H03M05.012345S"
    @test Juango.duration_iso_string(-1 * Juango.duration_us(days) |> Juango.duration_from_us) == "-P1DT01H03M05S"
    for x in (simple, days, micro, neg)
        @test Juango.duration_us(Juango.parse_duration(Juango.duration_iso_string(x))) == Juango.duration_us(x)
    end
end
