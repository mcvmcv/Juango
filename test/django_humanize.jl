# Django's humanize tests, ported (#227): tests/humanize_tests (HumanizeTests).
# julia --project=test test/django_humanize.jl   (see setup.jl)
#
# Django runs each value through `{{ value|filter }}`; so do these. None renders as "" in both.
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

function dhz_check(filter, values, results)
    t = Template("{% load humanize %}{{ v|" * filter * " }}")
    for (v, want) in zip(values, results)
        got = render(t, Dict{String,Any}("v" => v))
        got == want || @info "humanize mismatch" filter v got want
        @test got == want
    end
end

@testset "django humanize" begin
    dhz_check("ordinal",                                                                  # test_ordinal
              ["1", "2", "3", "4", "11", "12", "13", "101", "102", "103", "111", "something else", nothing, 0, 21, 1012],
              ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "101st", "102nd", "103rd", "111th", "something else", "", "0th", "21st", "1012th"])
    dhz_check("intcomma",                                                                 # test_intcomma
              Any[100, 1000, 10123, 10311, 1000000, 1234567.25, "100", "1000", "10123", "10311", "1000000", "1234567.1234567",
                  Juango.Decimal("1234567.1234567"), nothing, "-1234567.1234567", Juango.Decimal("-1234567.1234567"), -1000, 1000.0, "abc"],
              ["100", "1,000", "10,123", "10,311", "1,000,000", "1,234,567.25", "100", "1,000", "10,123", "10,311", "1,000,000",
               "1,234,567.1234567", "1,234,567.1234567", "", "-1,234,567.1234567", "-1,234,567.1234567", "-1,000", "1,000.0", "abc"])
    @test Juango.plain_float_string(1.0e20) == "100000000000000000000.0" && Juango.plain_float_string(1.5e-5) == "0.000015" &&
          Juango.plain_float_string(-1.23456725e6) == "-1234567.25"
    dhz_check("intword",                                                                  # test_intword
              Any["100", "1000000", "1200000", "1290000", "1000000000", "2000000000", "6000000000000", "1300000000000000",
                  "3500000000000000000000", "8100000000000000000000000000000000", "1" * "0"^100, "1" * "0"^104, nothing,
                  -100, -1000000, -1200000, 999999999],
              ["100", "1.0 million", "1.2 million", "1.3 million", "1.0 billion", "2.0 billion", "6.0 trillion", "1.3 quadrillion",
               "3.5 sextillion", "8.1 decillion", "1.0 googol", "1" * "0"^104, "", "-100", "-1.0 million", "-1.2 million", "1000.0 million"])
    dhz_check("apnumber", Any[1:10..., nothing, "x"],                                     # test_apnumber
              ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "10", "", "x"])
    today = Date(now())                                                                   # test_naturalday
    dhz_check("naturalday", Any[today, today - Day(1), today + Day(1), "I'm not a date value", nothing],
              ["today", "yesterday", "tomorrow", "I&#x27;m not a date value", ""])   # (autoescaped, as Django's)
    someday = today - Day(10)
    @test render(Template("{% load humanize %}{{ d|naturalday:'Y-m-d' }}"), Dict{String,Any}("d" => someday)) == Dates.format(someday, "yyyy-mm-dd")
    t = now()                                                                             # test_naturaltime (the times nearest now)
    nb = " "
    for (delta, want) in ((Second(1), "a second ago"), (Second(30), "30$(nb)seconds ago"), (Second(90), "a minute ago"),
                          (Minute(2), "2$(nb)minutes ago"), (Hour(1) + Minute(30) + Second(30), "an hour ago"),
                          (Hour(23) + Minute(50) + Second(50), "23$(nb)hours ago"), (Day(1), "1$(nb)day ago"),
                          (Day(2) + Hour(6), "2$(nb)days, 6$(nb)hours ago"))
        @test Juango.naturaltime(t - delta) == want || Juango.naturaltime(t - delta - Second(1)) == want   # (a tick may pass)
    end
    for (delta, want) in ((Second(30), "30$(nb)seconds from now"), (Minute(2) + Second(5), "2$(nb)minutes from now"),
                          (Hour(1) + Minute(30) + Second(30), "an hour from now"), (Day(2) + Hour(6) + Second(30), "2$(nb)days, 6$(nb)hours from now"))
        @test Juango.naturaltime(now() + delta) == want
    end
    @test Juango.naturaltime(now() - Millisecond(600)) in ("now", "a second ago")                # (part of a second is "now")
    @test Juango.naturaltime(now() + Millisecond(1)) == "now"
    @test render(Template("{% load humanize %}{{ v|naturaltime }}"), Dict{String,Any}("v" => "not a date")) == "not a date"   # test_naturaltime_as_documented (non-dates unchanged)
    # not translated: the translated filters (with_language("fr") etc. are in templates.jl), the
    # localized intcomma under USE_THOUSAND_SEPARATOR, naturaltime for times a year or more away
end
