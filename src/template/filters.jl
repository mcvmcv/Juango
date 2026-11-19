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
"Format a date with Django `date` filter format characters."
function format_date(d, fmt::AbstractString)
    dt = todatetime(d)
    dt === nothing && return ""
    z = d isa PinnedTime ? d.z : d isa TimeZones.ZonedDateTime ? (get(task_local_storage(), :juango_localtime_off, false) ? d : localtime(d)) : nothing
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
        elseif c == 'Y'; write_int(io, year(dt))
        elseif c == 'H'; write_padded(io, h, 2)
        elseif c == 'G'; print(io, h)
        elseif c == 'h'; write_padded(io, h12, 2)
        elseif c == 'g'; print(io, h12)
        elseif c == 'i'; write_padded(io, minute(dt), 2)
        elseif c == 's'; write_padded(io, second(dt), 2)
        elseif c == 'A'; print(io, h < 12 ? "AM" : "PM")
        elseif c == 'a'; print(io, h < 12 ? "a.m." : "p.m.")
        elseif c == 'U'; print(io, round(Int, datetime2unix(z === nothing ? dt : DateTime(TimeZones.astimezone(z, UTC_TZ)))))
        elseif c == 'e'; z === nothing || print(io, TimeZones.timezone(z))
        elseif c == 'T'; z === nothing || print(io, string(z.zone.name))
        elseif c == 'O'
            if z !== nothing
                off = Dates.value(Second(z.zone.offset.std + z.zone.offset.dst))
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
            z === nothing || print(io, Dates.value(Second(z.zone.offset.std + z.zone.offset.dst)))
        elseif c == 'I'
            z === nothing || print(io, Dates.value(z.zone.offset.dst) != 0 ? "1" : "0")
        elseif c == 'c'; print(io, format_date(d, "Y-m-d\\TH:i:s"), z === nothing ? "" : format_date(d, "O")[1:3] * ":" * format_date(d, "O")[4:5])
        elseif c == 'r'; print(io, format_date(d, "D, d M Y H:i:s"), z === nothing ? "" : " " * format_date(d, "O"))
        elseif c == 'S'
            dd = day(dt)
            print(io, dd in (11, 12, 13) ? "th" : dd % 10 == 1 ? "st" : dd % 10 == 2 ? "nd" : dd % 10 == 3 ? "rd" : "th")
        else
            print(io, c)
        end
    end
    String(take!(io))
end

function timesince(d, ref = nothing)
    if d isa TimeZones.ZonedDateTime        # compare aware times in UTC
        dt = DateTime(TimeZones.astimezone(d, UTC_TZ))
        ref = ref === nothing ? now(Dates.UTC) : ref isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(ref, UTC_TZ)) : ref
    else
        dt = todatetime(d)
        ref = something(ref, now())
    end
    dt === nothing && return ""
    secs = max(0, round(Int, Dates.value(ref - dt) / 1000))
    units = ((365 * 86400, "year"), (30 * 86400, "month"), (7 * 86400, "week"), (86400, "day"), (3600, "hour"), (60, "minute"))
    # (as Django's: up to two adjacent units, "4 days, 6 hours", each number and unit kept together by a no-break space)
    part(k, unit) = "$k\u00a0$(unit)$(k == 1 ? "" : "s")"
    for (i, (n, unit)) in enumerate(units)
        secs >= n || continue
        k = secs ÷ n
        out = part(k, unit)
        if i < length(units)
            n2, unit2 = units[i+1]
            k2 = (secs - k * n) ÷ n2
            k2 > 0 && (out *= ", " * part(k2, unit2))
        end
        return out
    end
    part(0, "minute")
end

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
    join(xs[1:end-1], ", ") * " " * gettext(String(last_word)) * " " * xs[end]
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
    F("striptags", (v, _) -> replace(str(v), r"<[^>]*>" => ""))
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
