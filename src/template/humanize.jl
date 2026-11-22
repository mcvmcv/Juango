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

"""
Group the integer part of a number with commas: `1234567.5` → `\"1,234,567.5\"`. As Django's, it works
on the number's digits (a string's digits as they are), so `\"1234567.1234567\"` keeps all of them.
"""
function intcomma(v)
    s = v isa AbstractFloat ? plain_float_string(v) : v isa Real ? string(v) : strip(str(v))
    m = match(r"^(-?)(\d+)(?:\.(\d+))?$", s)
    m === nothing && return str(v)
    int, frac = m[2], m[3]
    sep, dec = thousand_separator(), decimal_separator()
    groups = String[]
    while length(int) > 3
        pushfirst!(groups, int[end-2:end])
        int = int[1:end-3]
    end
    pushfirst!(groups, int)
    m[1] * join(groups, sep) * (frac === nothing ? "" : dec * frac)
end
"A float's shortest digits without an exponent: `1.23456725e6` → `\"1234567.25\"` (Python's str doesn't use one below 1e16)."
function plain_float_string(x::AbstractFloat)
    s = string(x)
    occursin('e', s) || return s
    mant, ex = split(s, 'e')
    neg = startswith(mant, "-")
    mant = lstrip(mant, '-')
    i = something(findfirst('.', mant), length(mant) + 1)
    digits_ = replace(mant, "." => "")
    point = i - 1 + parse(Int, ex)                 # digits before the decimal point
    out = point <= 0 ? "0." * "0"^(-point) * digits_ :
          point >= length(digits_) ? digits_ * "0"^(point - length(digits_)) * ".0" :
          digits_[1:point] * "." * digits_[point+1:end]
    (neg ? "-" : "") * out
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
    abs(n) >= big(10)^103 && return str(v)          # (past a thousand googol: unchanged, as Django's)
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
    secs = Dates.value(ref - t) ÷ 1000             # (whole seconds, as Django's timedelta.seconds: 0.6 s is "now")
    future = secs < 0
    s = abs(secs)
    # (a no-break space between a number and its unit, as Django's)
    phrase = if s == 0
        return gettext("now")
    elseif s < 60
        s == 1 ? gettext("a second") : interpolate(ngettext("%(count)s\u00a0second", "%(count)s\u00a0seconds", s), Dict("count" => s))
    elseif s < 3600
        m = s ÷ 60
        m == 1 ? gettext("a minute") : interpolate(ngettext("%(count)s\u00a0minute", "%(count)s\u00a0minutes", m), Dict("count" => m))
    elseif s < 86400
        h = s ÷ 3600
        h == 1 ? gettext("an hour") : interpolate(ngettext("%(count)s\u00a0hour", "%(count)s\u00a0hours", h), Dict("count" => h))
    else
        future ? timesince(ref, t) : timesince(t, ref)
    end
    interpolate(future ? gettext("%(delta)s from now") : gettext("%(delta)s ago"), Dict("delta" => phrase))
end

"`{% load humanize %}`: intcomma, intword, apnumber, ordinal, naturalday, naturaltime."
const HUMANIZE_LIBRARY = TagLibrary("humanize")
filter!(HUMANIZE_LIBRARY, "intcomma", (v, _) -> intcomma(v))
filter!(HUMANIZE_LIBRARY, "intword", (v, _) -> intword(v))
filter!(HUMANIZE_LIBRARY, "apnumber", (v, _) -> apnumber(v))
filter!(HUMANIZE_LIBRARY, "ordinal", (v, _) -> ordinal(v))
filter!(HUMANIZE_LIBRARY, "naturalday", (v, a) -> naturalday(v, a))
filter!(HUMANIZE_LIBRARY, "naturaltime", (v, _) -> naturaltime(v))
