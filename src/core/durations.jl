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
function tryparse_time(s::AbstractString)
    m = match(TIME_RE, s)
    m === nothing && return nothing
    h, mi, se = parse(Int, m[1]), parse(Int, m[2]), m[3] === nothing ? 0 : parse(Int, m[3])
    (h < 24 && mi < 60 && se < 60) || return nothing
    frac = m[4] === nothing ? 0 : parse(Int, rpad(m[4], 9, '0')[1:9])          # nanoseconds
    Dates.Time(h, mi, se) + Dates.Nanosecond(frac - frac % 1000)                 # to the microsecond
end
to_time(v::Dates.Time) = v
to_time(v::DateTime) = Dates.Time(v)
to_time(v::AbstractString) = (t = tryparse_time(v); t === nothing ? throw(ArgumentError("invalid time $(repr(v))")) : t)
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
    us = django_duration_us(t)                  # (Django's forms first: "-1 01:00:00" is minus a day plus an hour)
    us !== nothing && return us
    (startswith(t, "P") || startswith(t, "-P")) && return parse_iso_duration(t)       # (PostgreSQL's, signed fields)
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
    days, rest = fldmod(us, 86_400_000_000)     # (as Python's timedelta: whole days, negative or not, and the time after)
    h, rest = divrem(rest, 3_600_000_000)
    mi, rest = divrem(rest, 60_000_000)
    se, frac = divrem(rest, 1_000_000)
    s = (serial ? Printf.@sprintf("%02d:%02d:%02d", h, mi, se) : Printf.@sprintf("%d:%02d:%02d", h, mi, se)) *
        (frac == 0 ? "" : Printf.@sprintf(".%06d", frac))
    days == 0 ? s : serial ? string(days, " ", s) : string(days, abs(days) == 1 ? " day, " : " days, ", s)
end

display_string(t::Dates.Time) = time_string(t)
display_string(p::Dates.CompoundPeriod) = duration_string(p)

# --- Django's dateparse: parse_date, parse_time, parse_datetime, parse_duration ---------------------------------------

const DP_DATE_RE = r"^(\d{4})-(\d{1,2})-(\d{1,2})$"
const DP_TIME_RE = r"^(\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:[.,](\d{1,6})\d{0,6})?)?$"
const DP_DATETIME_RE = r"^(\d{4})-(\d{1,2})-(\d{1,2})[T ](\d{1,2}):(\d{1,2})(?::(\d{1,2})(?:[.,](\d{1,6})\d{0,6})?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"
# (Python's fromisoformat, which Django's tries first)
const ISO_DATE_RE = r"^(\d{4})-(\d{2})-(\d{2})$|^(\d{4})(\d{2})(\d{2})$"
const ISO_TIME_RE = r"^(\d{2})(?:(:?)(\d{2})(?:\2(\d{2})(?:[.,](\d+))?)?)?(Z|[+-]\d{2}(?::?\d{2}(?::?\d{2}(?:[.,]\d+)?)?)?)?$"

dp_int(x) = x === nothing ? 0 : parse(Int, x)
dp_us(x) = x === nothing ? 0 : parse(Int, rpad(first(x, 6), 6, '0'))
function dp_date(y, m, d)
    1 <= m <= 12 || throw(ArgumentError("month must be in 1..12"))
    1 <= d <= Dates.daysinmonth(y, m) || throw(ArgumentError("day is out of range for month"))
    Date(y, m, d)
end
function dp_time(h, mi, s, us)
    0 <= h <= 23 || throw(ArgumentError("hour must be in 0..23"))
    0 <= mi <= 59 || throw(ArgumentError("minute must be in 0..59"))
    0 <= s <= 59 || throw(ArgumentError("second must be in 0..59"))
    Dates.Time(h, mi, s) + Dates.Microsecond(us)
end
"An offset (`Z`, `+02`, `-0320`, `+02:30`) in minutes, or nothing past ±24 hours."
function dp_offset(tz::AbstractString)
    tz == "Z" && return 0
    t = replace(tz[2:end], ":" => "")
    mins = parse(Int, t[1:2]) * 60 + (length(t) >= 4 ? parse(Int, t[3:4]) : 0)
    mins < 24 * 60 || return nothing
    tz[1] == '-' ? -mins : mins
end
"Django's `get_fixed_timezone`: a fixed offset of `minutes`, named `+0230`."
fixed_timezone(minutes::Integer) =
    TimeZones.FixedTimeZone(string(minutes < 0 ? "-" : "+", lpad(abs(minutes) ÷ 60, 2, '0'), lpad(abs(minutes) % 60, 2, '0')), 60 * minutes)

function iso_date(s::AbstractString)
    m = match(ISO_DATE_RE, s)
    m === nothing && return nothing
    y, mo, d = m[1] === nothing ? (m[4], m[5], m[6]) : (m[1], m[2], m[3])
    try dp_date(parse(Int, y), parse(Int, mo), parse(Int, d)) catch; nothing end
end
"Python's `time.fromisoformat`: `(time, offset minutes or nothing)`, or nothing."
function iso_time(s::AbstractString)
    m = match(ISO_TIME_RE, s)
    m === nothing && return nothing
    off = m[6] === nothing ? nothing : dp_offset(m[6])
    m[6] !== nothing && off === nothing && return nothing
    t = try dp_time(dp_int(m[1]), dp_int(m[3]), dp_int(m[4]), dp_us(m[5])) catch; return nothing end
    (t, off)
end

"""
    parse_date(value) -> Date or nothing

Django's `parse_date`: `2012-04-23`, `20120423` or `2012-4-9`. Nothing when it isn't a date's form; an `ArgumentError`
when it is but isn't a date (`2012-04-56`).
"""
function parse_date(value::AbstractString)
    d = iso_date(value)
    d !== nothing && return d
    m = match(DP_DATE_RE, value)
    m === nothing ? nothing : dp_date(dp_int(m[1]), dp_int(m[2]), dp_int(m[3]))
end

"""
    parse_time(value) -> Dates.Time or nothing

Django's `parse_time`: `09:15:00`, `091500`, `10:10`, `10:20:30.400` (or `,400`), `4:8:16`; a time zone offset is ignored.
Nothing when it isn't a time's form; an `ArgumentError` when it is but isn't a time (`09:15:90`).
"""
function parse_time(value::AbstractString)
    t = iso_time(value)
    t !== nothing && return t[1]
    m = match(DP_TIME_RE, value)
    m === nothing ? nothing : dp_time(dp_int(m[1]), dp_int(m[2]), dp_int(m[3]), dp_us(m[4]))
end

"""
    parse_datetime(value) -> DateTime, ZonedDateTime or nothing

Django's `parse_datetime`: `2012-04-23T09:15:00`, `2012-4-9 4:8:16`, a date alone (midnight); with an offset (`Z`, `+02`,
`-0320`, `+02:30`), a `ZonedDateTime` in a fixed time zone. Nothing when it isn't a date and time's form; an
`ArgumentError` when it is but isn't one (`2012-04-56T09:15:90`). (Times are to the millisecond, as Julia's.)
"""
function parse_datetime(value::AbstractString)
    mk(d, t, off) = (dt = DateTime(d) + Dates.Millisecond(div(Dates.value(t), 1_000_000));
                     off === nothing ? dt : TimeZones.ZonedDateTime(dt, fixed_timezone(off)))
    d = iso_date(value)
    d !== nothing && return DateTime(d)
    k = findfirst(c -> c == 'T' || c == ' ', value)
    if k !== nothing && (d = iso_date(value[1:prevind(value, k)])) !== nothing
        t = iso_time(value[nextind(value, k):end])
        t !== nothing && return mk(d, t[1], t[2])
    end
    m = match(DP_DATETIME_RE, value)
    m === nothing && return nothing
    d = dp_date(dp_int(m[1]), dp_int(m[2]), dp_int(m[3]))
    t = dp_time(dp_int(m[4]), dp_int(m[5]), dp_int(m[6]), dp_us(m[7]))
    off = m[8] === nothing ? nothing : dp_offset(m[8])
    m[8] !== nothing && off === nothing && throw(ArgumentError("offset must be a timedelta strictly between -timedelta(hours=24) and timedelta(hours=24)"))
    mk(d, t, off)
end

const STANDARD_DURATION_RE = r"^(?:(?<days>-?\d+) (days?, )?)?(?<sign>-?)((?:(?<hours>\d+):)(?=\d+:\d+))?(?:(?<minutes>\d+):)?(?<seconds>\d+)(?:[.,](?<microseconds>\d{1,6})\d{0,6})?$"
const ISO8601_DURATION_RE = r"^(?<sign>[-+]?)P(?:(?<weeks>\d+([.,]\d+)?)W)?(?:(?<days>\d+([.,]\d+)?)D)?(?:T(?:(?<hours>\d+([.,]\d+)?)H)?(?:(?<minutes>\d+([.,]\d+)?)M)?(?:(?<seconds>\d+([.,]\d+)?)S)?)?$"
const POSTGRES_INTERVAL_RE = r"^(?:(?<days>-?\d+) (days? ?))?(?:(?<sign>[-+])?(?<hours>\d+):(?<minutes>\d\d):(?<seconds>\d\d)(?:\.(?<microseconds>\d{1,6}))?)?$"

"Microseconds from Django's duration forms, or nothing."
function django_duration_us(value::AbstractString)
    iso = false
    m = match(STANDARD_DURATION_RE, value)
    m === nothing && (m = match(ISO8601_DURATION_RE, value); iso = m !== nothing)
    m === nothing && (m = match(POSTGRES_INTERVAL_RE, value))
    m === nothing && return nothing
    g(k) = (v = try m[k] catch; nothing end; v === nothing ? 0.0 : parse(Float64, replace(v, ',' => '.')))
    sign = (try m[:sign] catch; nothing end) == "-" ? -1 : 1
    us = (try m[:microseconds] catch; nothing end)
    micro = us === nothing ? 0.0 : parse(Float64, rpad(us, 6, '0'))
    days = g(:days) * 86_400e6
    iso && (days *= sign)
    round(Int, days + sign * (g(:weeks) * 7 * 86_400e6 + g(:hours) * 3_600e6 + g(:minutes) * 60e6 + g(:seconds) * 1e6 + micro))
end

"""
    parse_duration(value) -> CompoundPeriod or nothing

Django's `parse_duration`: its own `4 10:15:30.5` form (and Python's `4 days, 10:15:30`), ISO 8601 without years and
months (`P4DT1H`, `-P0.5W`) and PostgreSQL's (`-1 day +0:00:01`). As Python's timedelta, `-4 15:30` is minus four days
plus fifteen and a half minutes. Nothing when it's none of them.
"""
parse_duration(value::AbstractString) = (us = django_duration_us(value); us === nothing ? nothing : duration_from_us(us))

"""
    duration_iso_string(p)

Django's `duration_iso_string`: `P1DT01H03M05S` (`-P...` when negative).
"""
function duration_iso_string(p::Duration)
    us = duration_us(p)
    sign = us < 0 ? "-" : ""
    days, rest = divrem(abs(us), 86_400_000_000)
    h, rest = divrem(rest, 3_600_000_000)
    mi, rest = divrem(rest, 60_000_000)
    se, frac = divrem(rest, 1_000_000)
    string(sign, "P", days, "DT", lpad(h, 2, '0'), "H", lpad(mi, 2, '0'), "M", lpad(se, 2, '0'), frac == 0 ? "" : "." * lpad(frac, 6, '0'), "S")
end
