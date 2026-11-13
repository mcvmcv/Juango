# Times of day and durations ----------------------------------------------------------------------------
#
# TimeField values are `Dates.Time`; DurationField values are durations: any fixed `Period`
# (`Hour(2)`, `Minute(90)`) or `CompoundPeriod` (`Day(1) + Hour(2)`), read back as a
# canonical `CompoundPeriod` (`1 day, 2 hours`). Months and years aren't fixed lengths, so a
# duration can't hold them (as Python's timedelta can't). Durations are stored as INTERVAL on
# PostgreSQL and as a whole number of microseconds elsewhere.

"`HH:MM:SS` with microseconds when there are any (Python's `time.isoformat()`)."
function time_string(t::Dates.Time)
    s = Printf.@sprintf("%02d:%02d:%02d", Dates.hour(t), Dates.minute(t), Dates.second(t))
    us = Dates.millisecond(t) * 1000 + Dates.microsecond(t)
    us == 0 ? s : s * Printf.@sprintf(".%06d", us)
end

const TIME_RE = r"^\s*(\d{1,2}):(\d{2})(?::(\d{2})(?:[.,](\d{1,9}))?)?\s*$"
"A time of day from text (`12:30`, `12:30:05`, `12:30:05.250`), or nothing."
function parse_time(s::AbstractString)
    m = match(TIME_RE, s)
    m === nothing && return nothing
    h, mi, se = parse(Int, m[1]), parse(Int, m[2]), m[3] === nothing ? 0 : parse(Int, m[3])
    (h < 24 && mi < 60 && se < 60) || return nothing
    frac = m[4] === nothing ? 0 : parse(Int, rpad(m[4], 9, '0')[1:9])          # nanoseconds
    Dates.Time(h, mi, se) + Dates.Nanosecond(frac - frac % 1000)                 # to the microsecond
end
to_time(v::Dates.Time) = v
to_time(v::DateTime) = Dates.Time(v)
to_time(v::AbstractString) = (t = parse_time(v); t === nothing ? throw(ArgumentError("invalid time $(repr(v))")) : t)
to_time(v) = to_time(string(v))

const Duration = Union{Dates.Period,Dates.CompoundPeriod}

"A duration as a whole number of microseconds (months and years aren't durations)."
function duration_us(p::Dates.Period)
    p isa Union{Dates.Month,Dates.Year,Dates.Quarter} &&
        throw(ArgumentError("a duration can't contain months or years ($p): they have no fixed length"))
    div(Dates.value(convert(Dates.Nanosecond, p)), 1000)
end
duration_us(p::Dates.CompoundPeriod) = sum(duration_us, p.periods; init = 0)
"A canonical `CompoundPeriod` for a number of microseconds: `1 day, 2 hours`."
duration_from_us(us::Integer) = Dates.canonicalize(Dates.CompoundPeriod(Dates.Microsecond(us)))

"`P1DT2H30M`: the ISO 8601 form PostgreSQL prints with `intervalstyle = iso_8601`."
const ISO_DURATION_RE = r"^(-)?P(?:(-?\d+)Y)?(?:(-?\d+)M)?(?:(-?\d+)W)?(?:(-?\d+)D)?(?:T(?:(-?\d+)H)?(?:(-?\d+)M)?(?:(-?\d+(?:\.\d+)?)S)?)?$"
function parse_iso_duration(s::AbstractString)
    m = match(ISO_DURATION_RE, strip(s))
    m === nothing && throw(ArgumentError("invalid duration $(repr(s))"))
    (m[2] !== nothing || m[3] !== nothing) && throw(ArgumentError("a duration with months or years ($s) can't be read as a fixed length"))
    n(i) = m[i] === nothing ? 0 : parse(Int, m[i])
    us = ((n(4) * 7 + n(5)) * 24 + n(6)) * 3_600_000_000 + n(7) * 60_000_000
    if m[8] !== nothing
        whole, _, frac = partition_str(m[8], '.')
        sec = parse(Int, whole)
        f = isempty(frac) ? 0 : parse(Int, rpad(frac, 6, '0')[1:6])
        us += sec * 1_000_000 + (startswith(m[8], "-") ? -f : f)
    end
    m[1] === nothing ? us : -us
end
partition_str(s, c) = (i = findfirst(c, s); i === nothing ? (s, "", "") : (s[1:prevind(s, i)], string(c), s[nextind(s, i):end]))

"A duration value from a driver, a form or a fixture."
to_duration(v::Duration) = duration_from_us(duration_us(v))
to_duration(v::Integer) = duration_from_us(v)                     # microseconds (MySQL, SQLite)
to_duration(v::Real) = duration_from_us(round(Int, v))   # floats and decimals (averages)
to_duration(v::AbstractString) = duration_from_us(parse_duration_us(v))
to_duration(v) = to_duration(string(v))

const DURATION_TEXT_RE = r"^\s*(-)?(?:(\d+)\s+days?,?\s*)?(\d+):(\d{2}):(\d{2})(?:\.(\d{1,6}))?\s*$"
"""
Microseconds from text: Django's `[DD] [HH:[MM:]]ss[.uuuuuu]` and `1 day, 2:00:00` forms, ISO
8601 (`P1DT2H`), or a plain number of seconds.
"""
function parse_duration_us(s::AbstractString)
    t = strip(s)
    (startswith(t, "P") || startswith(t, "-P")) && return parse_iso_duration(t)
    m = match(DURATION_TEXT_RE, t)
    if m !== nothing
        days = m[2] === nothing ? 0 : parse(Int, m[2])
        us = (((days * 24 + parse(Int, m[3])) * 60 + parse(Int, m[4])) * 60 + parse(Int, m[5])) * 1_000_000 +
             (m[6] === nothing ? 0 : parse(Int, rpad(m[6], 6, '0')))
        return m[1] === nothing ? us : -us
    end
    m = match(r"^\s*(-)?(?:(\d+)\s+)?(?:(?:(\d+):)?(\d+):)?(\d+)(?:\.(\d{1,6}))?\s*$", t)     # Django's form input
    m === nothing && throw(ArgumentError("invalid duration $(repr(s))"))
    g(i) = m[i] === nothing ? 0 : parse(Int, m[i])
    us = (((g(2) * 24 + g(3)) * 60 + g(4)) * 60 + g(5)) * 1_000_000 + (m[6] === nothing ? 0 : parse(Int, rpad(m[6], 6, '0')))
    m[1] === nothing ? us : -us
end

"""
    duration_string(p; serial = false)

A duration as text: `1 day, 2:03:04` (Python's `str(timedelta)`, for display and form inputs),
or with `serial = true` `1 02:03:04` (Django's `duration_string`, for fixtures).
"""
function duration_string(p::Duration; serial::Bool = false)
    us = duration_us(p)
    neg = us < 0
    us = abs(us)
    days, rest = divrem(us, 86_400_000_000)
    h, rest = divrem(rest, 3_600_000_000)
    mi, rest = divrem(rest, 60_000_000)
    se, frac = divrem(rest, 1_000_000)
    s = Printf.@sprintf("%d:%02d:%02d", h, mi, se) * (frac == 0 ? "" : Printf.@sprintf(".%06d", frac))
    serial && (s = Printf.@sprintf("%02d", h) * s[findfirst(':', s):end])
    days == 0 || (s = serial ? string(days, " ", s) : string(days, days == 1 ? " day, " : " days, ", s))
    neg ? "-" * s : s
end

display_string(t::Dates.Time) = time_string(t)
display_string(p::Dates.CompoundPeriod) = duration_string(p)
