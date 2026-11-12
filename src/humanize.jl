# humanize: filters that make numbers and dates read naturally ------------------------------------------
#
#     {% load humanize %}
#     {{ 1234567|intcomma }}        1,234,567
#     {{ 1200000|intword }}         1.2 million
#     {{ 4|apnumber }}              four
#     {{ 22|ordinal }}              22nd
#     {{ date|naturalday }}         yesterday / today / tomorrow / the date
#     {{ dt|naturaltime }}          3 minutes ago / an hour from now

function as_number(v)
    v isa Real && return v
    s = strip(str(v))
    something(tryparse(Int, s), tryparse(Float64, s), Some(nothing))
end

"Group the integer part of a number with commas: `1234567.5` → `\"1,234,567.5\"`."
function intcomma(v)
    n = as_number(v)
    n === nothing && return str(v)
    s = n isa Integer ? string(n) : (isinteger(n) && abs(n) < 1e15 ? string(Int(n)) * ".0" : string(n))
    sign = startswith(s, "-") ? "-" : ""
    s = lstrip(s, '-')
    i = findfirst(==('.'), s)
    int, frac = i === nothing ? (s, "") : (s[1:i-1], s[i:end])
    sep, dec = thousand_separator(), decimal_separator()
    groups = String[]
    while length(int) > 3
        pushfirst!(groups, int[end-2:end])
        int = int[1:end-3]
    end
    pushfirst!(groups, int)
    sign * join(groups, sep) * (isempty(frac) ? "" : dec * frac[2:end])
end
thousand_separator() = get_language() in ("de", "es", "it", "nl", "pt", "id", "tr", "da") ? "." :
                       get_language() in ("fr", "ru", "pl", "cs", "sv", "fi", "nb", "uk") ? " " : ","
decimal_separator() = thousand_separator() == "," ? "." : ","

const INTWORD_UNITS = [(6, "million", "million"), (9, "billion", "billion"), (12, "trillion", "trillion"),
                       (15, "quadrillion", "quadrillion"), (18, "quintillion", "quintillion"),
                       (21, "sextillion", "sextillion"), (24, "septillion", "septillion"),
                       (27, "octillion", "octillion"), (30, "nonillion", "nonillion"),
                       (33, "decillion", "decillion"), (100, "googol", "googol")]

"Large numbers in words: `1200000` → `\"1.2 million\"` (numbers below a million are unchanged)."
function intword(v)
    n = as_number(v)
    n === nothing && return str(v)
    abs(n) < 1_000_000 && return string(n)
    for i in length(INTWORD_UNITS):-1:1
        exp, one, many = INTWORD_UNITS[i]
        unit = big(10)^exp
        if abs(n) >= unit
            x = round(Float64(n / unit); digits = 1)
            return interpolate(ngettext("%(value)s $one", "%(value)s $many", x == 1 ? 1 : 2), Dict("value" => string(x)))
        end
    end
    string(n)
end

const AP_NUMBERS = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
"Numbers 1 to 9 in words (Associated Press style); other values are unchanged."
function apnumber(v)
    n = as_number(v)
    (n isa Integer && 1 <= n <= 9) || return str(v)
    gettext(AP_NUMBERS[n])
end

"An integer as an ordinal: `1st`, `2nd`, `3rd`, `4th`, `11th`, `22nd`."
function ordinal(v)
    n = as_number(v)
    n isa Integer || return str(v)
    suffix = 11 <= mod(n, 100) <= 13 ? "th" : (mod(n, 10) == 1 ? "st" : mod(n, 10) == 2 ? "nd" : mod(n, 10) == 3 ? "rd" : "th")
    string(n) * gettext(suffix)
end

"`today`, `tomorrow` or `yesterday` for those dates; other dates formatted (default `DATE_FORMAT`)."
function naturalday(v, fmt = nothing)
    d = v isa TimeZones.ZonedDateTime ? Date(localtime(v)) : (t = todatetime(v); t === nothing ? nothing : Date(t))
    d === nothing && return str(v)
    today = Date(timezone_now() isa TimeZones.ZonedDateTime ? localtime(timezone_now()) : timezone_now())
    delta = Dates.value(d - today)
    delta == 0 && return gettext("today")
    delta == 1 && return gettext("tomorrow")
    delta == -1 && return gettext("yesterday")
    format_date(d, fmt === nothing ? get_format().date : str(fmt))
end

"How long ago (or from now) a datetime is: `now`, `30 seconds ago`, `an hour from now`, `2 days ago`."
function naturaltime(v)
    if v isa TimeZones.ZonedDateTime
        t, ref = DateTime(TimeZones.astimezone(v, UTC_TZ)), now(Dates.UTC)
    else
        t = todatetime(v)
        t === nothing && return str(v)
        ref = now()
    end
    secs = round(Int, Dates.value(ref - t) / 1000)
    future = secs < 0
    s = abs(secs)
    phrase = if s == 0
        return gettext("now")
    elseif s < 60
        s == 1 ? gettext("a second") : interpolate(ngettext("%(count)s second", "%(count)s seconds", s), Dict("count" => s))
    elseif s < 3600
        m = s ÷ 60
        m == 1 ? gettext("a minute") : interpolate(ngettext("%(count)s minute", "%(count)s minutes", m), Dict("count" => m))
    elseif s < 86400
        h = s ÷ 3600
        h == 1 ? gettext("an hour") : interpolate(ngettext("%(count)s hour", "%(count)s hours", h), Dict("count" => h))
    else
        future ? timesince(ref, t) : timesince(t, ref)
    end
    interpolate(future ? gettext("%(delta)s from now") : gettext("%(delta)s ago"), Dict("delta" => phrase))
end

register_filter!("intcomma", (v, _) -> intcomma(v))
register_filter!("intword", (v, _) -> intword(v))
register_filter!("apnumber", (v, _) -> apnumber(v))
register_filter!("ordinal", (v, _) -> ordinal(v))
register_filter!("naturalday", (v, a) -> naturalday(v, a))
register_filter!("naturaltime", (v, _) -> naturaltime(v))
