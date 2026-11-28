# Template engine: built-in filters -----------------------------------------------------------

str(x) = display_string(x)
tonum(x::Number) = x
tonum(x) = (s = str(x); something(tryparse(Int, s), tryparse(Float64, s), 0))

const MONTH_ABBR_AP = ["Jan.", "Feb.", "March", "April", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."]

# A date's parts in templates, as Django's attribute lookup on Python's date and datetime:
# {{ d.year }}, {% url 'day' d.year d.month d.day %}. weekday counts Monday as 0, isoweekday as 1.
tattr(d::Union{Date,DateTime}, ::Val{:year}) = Dates.year(d)
tattr(d::Union{Date,DateTime}, ::Val{:month}) = Dates.month(d)
tattr(d::Union{Date,DateTime}, ::Val{:day}) = Dates.day(d)
tattr(d::Union{Date,DateTime}, ::Val{:weekday}) = Dates.dayofweek(d) - 1
tattr(d::Union{Date,DateTime}, ::Val{:isoweekday}) = Dates.dayofweek(d)
tattr(d::DateTime, ::Val{:hour}) = Dates.hour(d)
tattr(d::DateTime, ::Val{:minute}) = Dates.minute(d)
tattr(d::DateTime, ::Val{:second}) = Dates.second(d)
tattr(d::DateTime, ::Val{:microsecond}) = Dates.millisecond(d) * 1000
tattr(d::DateTime, ::Val{:date}) = Date(d)
tattr(t::Dates.Time, ::Val{:hour}) = Dates.hour(t)
tattr(t::Dates.Time, ::Val{:minute}) = Dates.minute(t)
tattr(t::Dates.Time, ::Val{:second}) = Dates.second(t)

todatetime(x::DateTime) = x
todatetime(x::Date) = DateTime(x)
todatetime(x::Dates.Time) = DateTime(Date(1900, 1, 1), x)      # the `time` filter on a TimeField
function todatetime(x)
    x === nothing && return nothing
    s = str(x)
    for f in (dateformat"yyyy-mm-ddTHH:MM:SS.s", dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-dd HH:MM:SS", dateformat"yyyy-mm-dd")
        d = tryparse(DateTime, s, f)
        d !== nothing && return d
    end
    nothing
end

"The `join` filter, written into one buffer (Base's join allocates several objects per call)."
function join_filter(v, a, ae)
    v === nothing && return ""
    sep = ae ? conditional_escape(something(a, "")) : str(a)
    io = IOBuffer()
    first = true
    for x in to_iterable(v)
        first || write(io, sep)
        first = false
        write(io, ae ? conditional_escape(x) : str(x))
    end
    SafeString(String(take!(io)))
end

"Write a non-negative integer with leading zeros to `width` digits, without allocating."
function write_padded(io::IO, n::Integer, width::Int)
    n = Int(n)
    d = n == 0 ? 1 : ndigits(n)
    for _ in d+1:width
        write(io, UInt8('0'))
    end
    write_int(io, n)
end

"The ISO 8601 year of a date (the year its ISO week belongs to)."
isoyear(d::Date) = (w = Dates.week(d); m = Dates.month(d); w >= 52 && m == 1 ? Dates.year(d) - 1 : w == 1 && m == 12 ? Dates.year(d) + 1 : Dates.year(d))
"A naive time in the default time zone (`TIME_ZONE`), or nothing where it's ambiguous or doesn't exist there (Django's)."
naive_zone(dt::DateTime) = try TimeZones.ZonedDateTime(dt, default_timezone()) catch; nothing end
"The Unix time of a naive time read in the default time zone (Python's `time.mktime`, with Django's TZ)."
naive_epoch(dt::DateTime) = (z = naive_zone(dt); z === nothing && (z = try TimeZones.ZonedDateTime(dt, default_timezone(), 1) catch; nothing end);
                             z === nothing ? round(Int, datetime2unix(dt)) : round(Int, datetime2unix(DateTime(TimeZones.astimezone(z, UTC_TZ)))))
zone_offset(z) = Dates.value(Second(z.zone.offset.std + z.zone.offset.dst))
const RFC5322_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
const RFC5322_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
"Format characters that need a time: a date's format may not have them (Django's TimeFormat's)."
const TIME_FORMAT_CHARS = "aAefgGhHiOPsTuZ"

"""
Format a date with Django `date` filter format characters. As Django's, a naive datetime's time zone characters (`O`,
`T`, `Z`, `I`, `U`, `r`) are its default time zone's (`TIME_ZONE`; none where the time is ambiguous there), and a
date's format may not have the characters that need a time (an `ArgumentError`, Django's TypeError).
"""
function format_date(d, fmt::AbstractString)
    dt = todatetime(d)
    dt === nothing && return ""
    z = d isa PinnedTime ? d.z : d isa TimeZones.ZonedDateTime ? (get(task_local_storage(), :juango_localtime_off, false) ? d : localtime(d)) : nothing
    tzz = z !== nothing ? z : d isa DateTime ? naive_zone(dt) : nothing        # (the time zone the characters use)
    if d isa Date
        esc0 = false
        for c in fmt
            esc0 && (esc0 = false; continue)
            c == '\\' && (esc0 = true; continue)
            c in TIME_FORMAT_CHARS && throw(ArgumentError("The format for date objects may not contain time-related format specifiers (found '$c')."))
        end
    end
    io = IOBuffer()
    esc = false
    for c in fmt
        if esc
            print(io, c)
            esc = false
            continue
        end
        h = hour(dt)
        h12 = h % 12 == 0 ? 12 : h % 12
        if c == '\\'
            esc = true
        elseif c == 'd'; write_padded(io, day(dt), 2)
        elseif c == 'j'; print(io, day(dt))
        elseif c == 'D'; print(io, gettext(dayabbr(dt)))
        elseif c == 'l'; print(io, gettext(dayname(dt)))
        elseif c == 'm'; write_padded(io, month(dt), 2)
        elseif c == 'n'; print(io, month(dt))
        elseif c == 'M'; print(io, pgettext("abbrev. month", monthabbr(dt)))
        elseif c == 'b'; print(io, lowercase(pgettext("abbrev. month", monthabbr(dt))))
        elseif c == 'F'; print(io, gettext(monthname(dt)))
        elseif c == 'N'; print(io, pgettext("alt. month", MONTH_ABBR_AP[month(dt)]))
        elseif c == 'y'; print(io, lpad(year(dt) % 100, 2, '0'))
        elseif c == 'Y'; write_padded(io, year(dt), 4)
        elseif c == 'H'; write_padded(io, h, 2)
        elseif c == 'G'; print(io, h)
        elseif c == 'h'; write_padded(io, h12, 2)
        elseif c == 'g'; print(io, h12)
        elseif c == 'i'; write_padded(io, minute(dt), 2)
        elseif c == 's'; write_padded(io, second(dt), 2)
        elseif c == 'A'; print(io, h < 12 ? "AM" : "PM")
        elseif c == 'a'; print(io, h < 12 ? "a.m." : "p.m.")
        elseif c == 'U'; print(io, z === nothing ? naive_epoch(dt) : round(Int, datetime2unix(DateTime(TimeZones.astimezone(z, UTC_TZ)))))
        elseif c == 'e'; z === nothing || print(io, (tz = TimeZones.timezone(z); tz isa TimeZones.FixedTimeZone ? tz.name : tz))
        elseif c == 'T'; tzz === nothing || print(io, string(tzz.zone.name))
        elseif c == 'O'
            if tzz !== nothing
                off = zone_offset(tzz)
                print(io, off < 0 ? "-" : "+", lpad(abs(off) ÷ 3600, 2, '0'), lpad((abs(off) % 3600) ÷ 60, 2, '0'))
            end
        elseif c == 'o'; print(io, isoyear(Date(dt)))
        elseif c == 'W'; print(io, Dates.week(dt))
        elseif c == 'w'; print(io, Dates.dayofweek(dt) % 7)
        elseif c == 'z'; print(io, Dates.dayofyear(dt))
        elseif c == 't'; print(io, Dates.daysinmonth(dt))
        elseif c == 'L'; print(io, Dates.isleapyear(dt) ? "True" : "False")
        elseif c == 'E'; print(io, pgettext("alt. month", monthname(dt)))
        elseif c == 'u'; write_padded(io, Dates.millisecond(dt) * 1000, 6)
        elseif c == 'f'; print(io, h12, minute(dt) == 0 ? "" : ":" * lpad(minute(dt), 2, '0'))
        elseif c == 'P'      # 1 a.m., 1:30 p.m., noon, midnight
            print(io, minute(dt) == 0 && h == 0 ? gettext("midnight") : minute(dt) == 0 && h == 12 ? gettext("noon") :
                      string(h12, minute(dt) == 0 ? "" : ":" * lpad(minute(dt), 2, '0'), " ", h < 12 ? "a.m." : "p.m."))
        elseif c == 'Z'
            tzz === nothing || print(io, zone_offset(tzz))
        elseif c == 'I'
            tzz === nothing || print(io, Dates.value(tzz.zone.offset.dst) != 0 ? "1" : "0")
        elseif c == 'c'                         # (Python's isoformat: microseconds when there are any, an aware time's offset)
            ms = Dates.millisecond(dt)
            print(io, format_date(DateTime(Date(dt), Dates.Time(dt)), "Y-m-d\\TH:i:s"), ms == 0 ? "" : "." * lpad(ms * 1000, 6, '0'))
            z === nothing || (o = format_date(z, "O"); print(io, o[1:3], ":", o[4:5]))
        elseif c == 'r'                         # (RFC 5322, in English whatever the language; a date at midnight in TIME_ZONE)
            rz = z !== nothing ? z : d isa Date ? naive_zone(DateTime(Date(dt))) : tzz
            print(io, RFC5322_DAYS[Dates.dayofweek(dt)], ", ", lpad(day(dt), 2, '0'), " ", RFC5322_MONTHS[month(dt)], " ", lpad(year(dt), 4, '0'),
                  " ", lpad(hour(dt), 2, '0'), ":", lpad(minute(dt), 2, '0'), ":", lpad(second(dt), 2, '0'))
            if rz !== nothing
                off = zone_offset(rz)
                print(io, " ", off < 0 ? "-" : "+", lpad(abs(off) ÷ 3600, 2, '0'), lpad((abs(off) % 3600) ÷ 60, 2, '0'))
            end
        elseif c == 'S'
            dd = day(dt)
            print(io, dd in (11, 12, 13) ? "th" : dd % 10 == 1 ? "st" : dd % 10 == 2 ? "nd" : dd % 10 == 3 ? "rd" : "th")
        else
            print(io, c)
        end
    end
    String(take!(io))
end

const TIME_STRINGS = ["year" => ("%(num)d year", "%(num)d years"), "month" => ("%(num)d month", "%(num)d months"),
                      "week" => ("%(num)d week", "%(num)d weeks"), "day" => ("%(num)d day", "%(num)d days"),
                      "hour" => ("%(num)d hour", "%(num)d hours"), "minute" => ("%(num)d minute", "%(num)d minutes")]
const TIME_CHUNKS = (7 * 86400, 86400, 3600, 60)
const MONTHS_DAYS = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)

"""
    timesince(d, now = nothing; reversed = false, time_strings = nothing, depth = 2) -> String

The time from `d` to `now` (by default the current time), as Django's: `"2\u00a0weeks, 3\u00a0days"`. Up to `depth`
adjacent units (years, months, weeks, days, hours, minutes; seconds are ignored), each number and unit kept together by a
no-break space and translated; years and months are calendar ones (from 10 February to 10 March is a month). `d` after
`now` is `"0\u00a0minutes"`. Aware times are compared in `d`'s time zone. `time_strings` replaces the units' texts: a
`Dict` from `"year"`, ... to a function of the number. `d` that isn't a date or time gives "".
"""
function timesince(d, now = nothing; reversed::Bool = false, time_strings = nothing, depth::Integer = 2)
    depth <= 0 && throw(ArgumentError("depth must be greater than 0."))
    unit(name, n) = (f = time_strings === nothing ? nothing : get(time_strings, name, nothing);
                     t = f === nothing ? (ms = Dict(TIME_STRINGS)[name]; interpolate(ngettext(ms[1], ms[2], n), Dict("num" => n))) : f(n);
                     replace(t, ' ' => '\u00a0'))
    local dt::DateTime, nw::DateTime
    if d isa TimeZones.ZonedDateTime
        dt = DateTime(d)                                       # (wall times in d's zone)
        nw = now === nothing ? DateTime(TimeZones.astimezone(TimeZones.now(UTC_TZ), TimeZones.timezone(d))) :
             now isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(now, TimeZones.timezone(d))) : todatetime(now)
    else
        x = todatetime(d)
        x === nothing && return ""
        dt = x
        nw = now === nothing ? Dates.now() : now isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(now, UTC_TZ)) : todatetime(now)
    end
    reversed && ((dt, nw) = (nw, dt))
    since = fld(Dates.value(nw - dt), 1000)                    # (microseconds ignored)
    since <= 0 && return unit("minute", 0)
    total_months = (year(nw) - year(dt)) * 12 + (month(nw) - month(dt))
    (day(dt) > day(nw) || (day(dt) == day(nw) && Time(dt) > Time(nw))) && (total_months -= 1)
    years, months = fldmod(total_months, 12)
    pivot = if years != 0 || months != 0
        py, pm = year(dt) + years, month(dt) + months
        pm > 12 && (pm -= 12; py += 1)
        DateTime(py, pm, min(MONTHS_DAYS[pm], day(dt)), hour(dt), minute(dt), second(dt))
    else
        dt
    end
    remaining = Dates.value(nw - pivot) / 1000
    partials = Int[years, months]
    for chunk in TIME_CHUNKS
        c = floor(Int, remaining / chunk)
        push!(partials, c)
        remaining -= chunk * c
    end
    i = findfirst(!=(0), partials)
    i === nothing && return unit("minute", 0)
    out = String[]
    while i <= length(TIME_STRINGS) && length(out) < depth && partials[i] != 0
        push!(out, unit(TIME_STRINGS[i].first, partials[i]))
        i += 1
    end
    join(out, gettext(", "))
end

"`timeuntil(d, now = nothing; time_strings, depth = 2)`: the time from `now` until `d`, as `timesince` (Django's)."
timeuntil(d, now = nothing; time_strings = nothing, depth::Integer = 2) = timesince(d, now; reversed = true, time_strings, depth)

function linebreaks_html(s::AbstractString, autoescape::Bool)
    s = replace(s, "\r\n" => "\n", "\r" => "\n")
    paras = split(s, r"\n{2,}")
    join(["<p>" * replace(autoescape ? escape_html(strip(p)) : strip(p), "\n" => "<br>") * "</p>" for p in paras if !isempty(strip(p))], "\n\n")
end

"""
    get_text_list(items, last_word = "or") -> String

`["a", "b", "c"]` as `"a, b or c"` (Django's `django.utils.text.get_text_list`): `last_word` is
translated, so `get_text_list(names, "and")` reads "a, b und c" in German. Also the template
filter `{{ names|text_list:"and" }}`.
"""
function get_text_list(items, last_word::AbstractString = "or")
    xs = [display_string(x) for x in items]
    isempty(xs) && return ""
    length(xs) == 1 && return xs[1]
    join(xs[1:end-1], gettext(", ")) * " " * gettext(String(last_word)) * " " * xs[end]     # (the separator translated too, "، ")
end

let F = register_filter!
    F("text_list", (v, a) -> get_text_list(v isa AbstractString ? [v] : v, a === nothing ? "or" : display_string(a)))
    F("lower", (v, _) -> lowercase(str(v)); is_safe = true)
    F("capfirst", (v, _) -> uppercasefirst(str(v)); is_safe = true)
    F("default", (v, a) -> truthy(v) ? v : a)
    F("default_if_none", (v, a) -> v === nothing ? a : v)
    F("safe", (v, _) -> SafeString(str(v)))
    F("escape", (v, _) -> SafeString(conditional_escape(v)))     # already-safe text isn't escaped twice
    F("force_escape", (v, _) -> SafeString(escape_html(str(v))))
    F("striptags", (v, _) -> strip_tags(str(v)))
    F("join", join_filter; needs_autoescape = true)
    F("linebreaks", (v, _, ae) -> SafeString(linebreaks_html(str(v), ae && !(v isa SafeString))); needs_autoescape = true)
    F("yesno", (v, a) -> begin
        opts = split(a === nothing ? "yes,no,maybe" : str(a), ',')
        v === nothing ? (length(opts) > 2 ? opts[3] : opts[2]) : truthy(v) ? opts[1] : opts[2]
    end)
    F("slugify", (v, _) -> slugify(str(v)); is_safe = true)
    F("wordcount", (v, _) -> length(split(str(v))))
    F("divisibleby", (v, a) -> tonum(v) % tonum(a) == 0)
    F("filesizeformat", (v, _) -> begin
        b = Float64(tonum(v))
        for (u, n) in (("PB", 1024.0^5), ("TB", 1024.0^4), ("GB", 1024.0^3), ("MB", 1024.0^2), ("KB", 1024.0))
            b >= n && return @sprintf("%.1f %s", b / n, u)
        end
        "$(round(Int, b)) bytes"
    end)
end
