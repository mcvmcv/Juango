# Template engine: built-in filters -----------------------------------------------------------

str(x) = display_string(x)
tonum(x::Number) = x
tonum(x) = (s = str(x); something(tryparse(Int, s), tryparse(Float64, s), 0))

const MONTH_ABBR_AP = ["Jan.", "Feb.", "March", "April", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."]

todatetime(x::DateTime) = x
todatetime(x::Date) = DateTime(x)
function todatetime(x)
    x === nothing && return nothing
    s = str(x)
    for f in (dateformat"yyyy-mm-ddTHH:MM:SS.s", dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-dd HH:MM:SS", dateformat"yyyy-mm-dd")
        d = tryparse(DateTime, s, f)
        d !== nothing && return d
    end
    nothing
end

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
        elseif c == 'd'; print(io, lpad(day(dt), 2, '0'))
        elseif c == 'j'; print(io, day(dt))
        elseif c == 'D'; print(io, gettext(dayabbr(dt)))
        elseif c == 'l'; print(io, gettext(dayname(dt)))
        elseif c == 'm'; print(io, lpad(month(dt), 2, '0'))
        elseif c == 'n'; print(io, month(dt))
        elseif c == 'M'; print(io, pgettext("abbrev. month", monthabbr(dt)))
        elseif c == 'b'; print(io, lowercase(pgettext("abbrev. month", monthabbr(dt))))
        elseif c == 'F'; print(io, gettext(monthname(dt)))
        elseif c == 'N'; print(io, pgettext("alt. month", MONTH_ABBR_AP[month(dt)]))
        elseif c == 'y'; print(io, lpad(year(dt) % 100, 2, '0'))
        elseif c == 'Y'; print(io, year(dt))
        elseif c == 'H'; print(io, lpad(h, 2, '0'))
        elseif c == 'G'; print(io, h)
        elseif c == 'h'; print(io, lpad(h12, 2, '0'))
        elseif c == 'g'; print(io, h12)
        elseif c == 'i'; print(io, lpad(minute(dt), 2, '0'))
        elseif c == 's'; print(io, lpad(second(dt), 2, '0'))
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
    for (n, unit) in ((365 * 86400, "year"), (30 * 86400, "month"), (7 * 86400, "week"),
                      (86400, "day"), (3600, "hour"), (60, "minute"))
        if secs >= n
            k = secs ÷ n
            return "$k $(unit)$(k == 1 ? "" : "s")"
        end
    end
    "0 minutes"
end

function linebreaks_html(s::AbstractString, autoescape::Bool)
    s = replace(s, "\r\n" => "\n")
    paras = split(s, r"\n{2,}")
    join(["<p>" * replace(autoescape ? escape_html(strip(p)) : strip(p), "\n" => "<br>") * "</p>" for p in paras if !isempty(strip(p))], "\n\n")
end

let F = register_filter!
    F("upper", (v, _) -> uppercase(str(v)); is_safe = true)
    F("lower", (v, _) -> lowercase(str(v)); is_safe = true)
    F("title", (v, _) -> titlecase(str(v)); is_safe = true)
    F("capfirst", (v, _) -> uppercasefirst(str(v)); is_safe = true)
    F("length", (v, _) -> v === nothing ? 0 : v isa SafeString ? length(v.s) : length(v isa QuerySet ? collect(v) : v))
    F("default", (v, a) -> truthy(v) ? v : a)
    F("default_if_none", (v, a) -> v === nothing ? a : v)
    F("safe", (v, _) -> SafeString(str(v)))
    F("escape", (v, _) -> SafeString(conditional_escape(v)))     # already-safe text isn't escaped twice
    F("force_escape", (v, _) -> SafeString(escape_html(str(v))))
    F("striptags", (v, _) -> replace(str(v), r"<[^>]*>" => ""))
    F("truncatechars", (v, a) -> (s = str(v); n = tonum(a); length(s) <= n ? s : first(s, max(n - 1, 0)) * "…"); is_safe = true)
    F("truncatewords", (v, a) -> (w = split(str(v)); n = tonum(a); length(w) <= n ? join(w, " ") : join(w[1:n], " ") * " …"); is_safe = true)
    F("join", (v, a, ae) -> SafeString(join([ae ? conditional_escape(x) : str(x) for x in to_iterable(v)],
                                            ae ? conditional_escape(something(a, "")) : str(a)));
      needs_autoescape = true)
    F("first", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : first(it)))
    F("last", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : last(it)))
    F("random", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : rand(it)))
    F("slice", (v, a) -> begin
        it = v isa AbstractString || v isa SafeString ? str(v) : to_iterable(v)
        m = match(r"^(-?\d*):(-?\d*)$", str(a))
        m === nothing && return it
        n = length(it)
        lo = isempty(m[1]) ? 0 : parse(Int, m[1]); lo < 0 && (lo += n)
        hi = isempty(m[2]) ? n : parse(Int, m[2]); hi < 0 && (hi += n)
        lo, hi = clamp(lo, 0, n), clamp(hi, 0, n)
        it isa AbstractString ? join(collect(it)[lo+1:hi]) : it[lo+1:hi]
    end)
    F("date", (v, a) -> format_date(v, a === nothing ? get_format().date : str(a)))
    F("time", (v, a) -> format_date(v, a === nothing ? "g:i a" : str(a)))
    F("timesince", (v, _) -> timesince(v))
    F("linebreaksbr", (v, _, ae) -> SafeString(replace(ae && !(v isa SafeString) ? escape_html(str(v)) : str(v), r"\r?\n" => "<br>"));
      needs_autoescape = true)
    F("linebreaks", (v, _, ae) -> SafeString(linebreaks_html(str(v), ae && !(v isa SafeString))); needs_autoescape = true)
    F("pluralize", (v, a) -> begin
        n = v isa Number ? v : (v isa AbstractString || v === nothing) ? tonum(v) : length(to_iterable(v))
        sfx = a === nothing ? ["", "s"] : split(str(a), ',')
        length(sfx) == 1 && (sfx = ["", sfx[1]])
        n == 1 ? sfx[1] : sfx[2]
    end)
    F("add", (v, a) -> begin
        try
            x, y = tonum(v), tonum(a)
            (v isa Number || tryparse(Float64, str(v)) !== nothing) && (a isa Number || tryparse(Float64, str(a)) !== nothing) && return x + y
        catch
        end
        (v isa AbstractVector && a isa AbstractVector) ? vcat(v, a) : str(v) * str(a)
    end)
    F("yesno", (v, a) -> begin
        opts = split(a === nothing ? "yes,no,maybe" : str(a), ',')
        v === nothing ? (length(opts) > 2 ? opts[3] : opts[2]) : truthy(v) ? opts[1] : opts[2]
    end)
    F("slugify", (v, _) -> slugify(str(v)); is_safe = true)
    F("urlencode", (v, _) -> urlquote(str(v)))
    F("floatformat", (v, a) -> begin
        d = a === nothing ? -1 : tonum(a)
        if v isa Decimal                  # exact, rounding half up as Django does
            return d < 0 && isinteger(v) ? string(Int(v)) : string(round(v, RoundNearestTiesAway; digits = abs(d)))
        end
        x = Float64(tonum(v))
        if d < 0
            isinteger(x) ? string(round(Int, x)) : Printf.format(Printf.Format("%.$(abs(d))f"), x)
        else
            Printf.format(Printf.Format("%.$(d)f"), x)
        end
    end)
    F("cut", (v, a) -> replace(str(v), str(a) => ""))
    F("wordcount", (v, _) -> length(split(str(v))))
    F("divisibleby", (v, a) -> tonum(v) % tonum(a) == 0)
    F("stringformat", (v, a) -> Printf.format(Printf.Format("%" * str(a)), v))
    F("center", (v, a) -> (s = str(v); n = tonum(a); p = max(n - length(s), 0); " "^(p ÷ 2) * s * " "^(p - p ÷ 2)))
    F("ljust", (v, a) -> rpad(str(v), tonum(a)))
    F("rjust", (v, a) -> lpad(str(v), tonum(a)))
    F("make_list", (v, _) -> collect(str(v)))
    F("dictsort", (v, a) -> sort(collect(v); by = x -> getattr(x, str(a))))
    F("dictsortreversed", (v, a) -> sort(collect(v); by = x -> getattr(x, str(a)), rev = true))
    F("json_script", (v, a) -> SafeString("<script id=\"" * escape_html(str(a)) * "\" type=\"application/json\">" *
                                          replace(JSON.json(v), "<" => "\\u003C", ">" => "\\u003E", "&" => "\\u0026") * "</script>"))
    F("urlize", (v, _, ae) -> SafeString(replace(ae ? escape_html(str(v)) : str(v),
                                                 r"(https?://[^\s<]+)" => s"<a href=\"\1\" rel=\"nofollow\">\1</a>"));
      needs_autoescape = true)
    F("filesizeformat", (v, _) -> begin
        b = Float64(tonum(v))
        for (u, n) in (("PB", 1024.0^5), ("TB", 1024.0^4), ("GB", 1024.0^3), ("MB", 1024.0^2), ("KB", 1024.0))
            b >= n && return @sprintf("%.1f %s", b / n, u)
        end
        "$(round(Int, b)) bytes"
    end)
end
