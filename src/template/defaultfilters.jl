# Template engine: built-in filters as Django's defaultfilters --------------------------------------------------
#
# These follow django/template/defaultfilters.py closely: what each filter accepts, what it gives for
# a value it can't handle (usually "" or the value unchanged, never an error), and whether its result
# stays safe when its input was (`is_safe`), as Django's own tests check (test/django_templates.jl).

"Text, safe or not (a lazily translated string is text too)."
stringish(x) = x isa AbstractString || x isa SafeString
"Python's `int(x)`: an integer, a float truncated, or text that is a whole number; else `nothing`."
py_int(x) = x isa Bool ? Int(x) : x isa Integer ? x : x isa AbstractFloat ? (isfinite(x) ? trunc(Int, x) : nothing) :
            stringish(x) ? tryparse(Int, strip(str(x))) : nothing
"Python's `x + y`, or `nothing` where Python raises."
function py_add(x, y)
    stringish(x) && stringish(y) && return str(x) * str(y)
    x isa AbstractVector && y isa AbstractVector && return vcat(x, y)
    x isa Tuple && y isa Tuple && return (x..., y...)
    x isa Number && y isa Number && return x + y
    x isa Union{Date,DateTime} && y isa Union{Dates.Period,Dates.CompoundPeriod} && return x + y
    nothing
end

"Python's `quote(s, safe)`: letters, digits, `_.-~` and the `safe` characters kept, the rest percent-encoded as UTF-8."
function py_quote(s::AbstractString, safe::AbstractString = "/")
    io = IOBuffer()
    for c in s
        if isascii(c) && (isletter(c) || isdigit(c) || c in "_.-~" || c in safe)
            print(io, c)
        else
            for b in codeunits(string(c))
                print(io, '%', uppercase(string(b, base = 16, pad = 2)))
            end
        end
    end
    String(take!(io))
end

"Python's `str.title()`: each run of letters starts upper case, the rest lower."
function py_title(s::AbstractString)
    io = IOBuffer()
    prev = false
    for c in s
        print(io, isletter(c) ? (prev ? lowercase(c) : uppercase(c)) : c)
        prev = isletter(c)
    end
    String(take!(io))
end

"Python's `json.dumps` (`\", \"` and `\": \"` between items, non-ASCII as `\\u` escapes), for `json_script`."
function py_json(x)
    x === nothing && return "null"
    x isa Bool && return x ? "true" : "false"
    x isa Number && return JSON.json(x)
    x isa AbstractDict && return "{" * join((py_json(string(k)) * ": " * py_json(v) for (k, v) in x), ", ") * "}"
    (x isa AbstractVector || x isa Tuple) && return "[" * join((py_json(v) for v in x), ", ") * "]"
    s = JSON.json(stringish(x) ? str(x) : string(x))
    io = IOBuffer()
    for c in s
        if isascii(c)
            print(io, c)
        else
            u = UInt32(c)
            if u > 0xffff                   # (a UTF-16 surrogate pair, as Python writes it)
                u -= 0x10000
                print(io, "\\u", string(0xd800 + (u >> 10), base = 16, pad = 4), "\\u", string(0xdc00 + (u & 0x3ff), base = 16, pad = 4))
            else
                print(io, "\\u", string(u, base = 16, pad = 4))
            end
        end
    end
    String(take!(io))
end

"Python's slice of a sequence of length `n`: 1-based indices, or `nothing` for a step of 0."
function py_slice(n, start, stop, step)
    step = something(step, 1)
    step == 0 && return nothing
    if step > 0
        lo = start === nothing ? 0 : start < 0 ? max(start + n, 0) : min(start, n)
        hi = stop === nothing ? n : stop < 0 ? max(stop + n, 0) : min(stop, n)
        return (lo + 1):step:hi
    end
    lo = start === nothing ? n - 1 : start < 0 ? max(start + n, -1) : min(start, n - 1)
    hi = stop === nothing ? -1 : stop < 0 ? max(stop + n, -1) : min(stop, n - 1)
    (lo + 1):step:(hi + 2)
end

"A number written in decimal (`\"-1.5e3\"`) as sign, digits and exponent, or `nothing`."
function parse_decimal_text(s::AbstractString)
    m = match(r"^\s*([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\s*$", s)
    (m === nothing || (isempty(m[2]) && (m[3] === nothing || isempty(m[3])))) && return nothing
    frac = something(m[3], "")
    digits = lstrip(m[2] * frac, '0')
    (m[1] == "-", parse(BigInt, isempty(digits) ? "0" : digits), (m[4] === nothing ? 0 : parse(Int, m[4])) - length(frac),
     length(m[2] * frac))
end

"A number's text with the active language's decimal separator, and thousands separators when `grouping`."
function localize_number_text(s::AbstractString, decimals::Int; grouping::Bool = false, l10n::Bool = true)
    f = l10n ? get_format() : (decimal = ".", thousand = ",")
    grouping = grouping || (l10n && settings.USE_THOUSAND_SEPARATOR)
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    ip, fp = occursin('.', s) ? split(s, '.'; limit = 2) : (s, "")
    grouping && (ip = reverse(join([reverse(ip)[i:min(end, i + 2)] for i in 1:3:length(ip)], reverse(f.thousand))))
    (neg ? "-" : "") * ip * (decimals > 0 ? f.decimal * fp : "")
end

"Django's `floatformat`: exact decimal rounding (half up), for floats as Python writes them."
function floatformat_filter(v, a)
    arg = a === nothing ? -1 : a
    grouping, l10n = false, true
    if arg isa AbstractString
        if length(arg) >= 2 && arg[end-1:end] in ("gu", "ug")
            grouping, l10n, arg = true, false, arg[1:end-2]
        elseif endswith(arg, "g")
            grouping, arg = true, arg[1:end-1]
        elseif endswith(arg, "u")
            l10n, arg = false, arg[1:end-1]
        end
        isempty(arg) && (arg = -1)
    end
    input = v isa AbstractFloat ? py_float_repr(v) : str(v)
    v isa AbstractFloat && !isfinite(v) && return input
    stringish(v) && lowercase(strip(str(v))) in ("inf", "+inf", "-inf", "nan", "infinity", "-infinity") && return input
    dec = parse_decimal_text(input)
    if dec === nothing
        f = v isa Real ? Float64(v) : nothing
        f === nothing && return ""
        input = py_float_repr(f)
        dec = parse_decimal_text(input)
    end
    p = py_int(arg)
    p === nothing && return input
    neg, coeff, exp, ndigits = dec
    ndigits + abs(exp) > 200 && return input      # (as Django: very long numbers as they are)
    if exp >= 0 || coeff % big(10)^(-exp) == 0
        if p <= 0
            n = exp >= 0 ? coeff * big(10)^exp : coeff ÷ big(10)^(-exp)
            return SafeString(localize_number_text((neg && n != 0 ? "-" : "") * string(n), 0; grouping, l10n))
        end
    end
    q = abs(p)
    # coeff × 10^exp rounded half up to q decimals, as an integer of units of 10^-q
    shift = exp + q
    units = shift >= 0 ? coeff * big(10)^shift : (let d = big(10)^(-shift); r = coeff ÷ d; 2 * (coeff % d) >= d ? r + 1 : r end)
    s = string(units)
    length(s) <= q && (s = "0"^(q - length(s) + 1) * s)
    text = q == 0 ? s : s[1:end-q] * "." * s[end-q+1:end]
    neg && units != 0 && (text = "-" * text)
    SafeString(localize_number_text(text, q; grouping, l10n))
end
"A float as Python's `str()` writes it (`1e+199`, `inf`, `nan`)."
function py_float_repr(x::AbstractFloat)
    isnan(x) && return "nan"
    isinf(x) && return x > 0 ? "inf" : "-inf"
    s = string(Float64(x))
    m = match(r"^(-?\d+(?:\.\d+)?)e(-?\d+)$", s)
    m === nothing && return s
    mant = endswith(m[1], ".0") ? m[1][1:end-2] : m[1]
    e = parse(Int, m[2])
    mant * "e" * (e < 0 ? "-" : "+") * lpad(abs(e), 2, '0')
end

"Django's `dictsort`: sorted by a key path (`\"a.b\"`) or an index; \"\" for what can't be sorted that way."
function dictsort_filter(v, a; rev::Bool = false)
    (a === nothing || v === nothing || v isa AbstractDict || stringish(v) || v isa Number) && return ""
    key = if a isa Integer
        x -> x isa AbstractDict ? x[a] : collect(x)[a+1]
    else
        s = str(a)
        # (a number given as text is a key, as Django's itemgetter: x["0"])
        tryparse(Float64, s) === nothing || return (try sort(collect(to_iterable(v)); by = x -> x[s], rev = rev) catch; "" end)
        (occursin("._", s) || startswith(s, "_")) && return ""      # (private attributes, as Django)
        parts = String.(split(s, '.'))
        x -> foldl(parts; init = x) do o, p
            r = getattr(o, p)
            (r === UNDEF || r === NOTFOUND) && error("no $p")
            r
        end
    end
    try
        sort(collect(to_iterable(v)); by = key, rev = rev)
    catch
        ""
    end
end

function slice_filter(v, a)
    v === nothing && return ""
    v isa AbstractDict && return v
    parts = split(str(a), ':')
    length(parts) > 3 && return v
    bits = Any[]
    for x in parts
        if isempty(x)
            push!(bits, nothing)
        else
            n = tryparse(Int, x)
            n === nothing && return v
            push!(bits, n)
        end
    end
    start, stop, step = length(bits) == 1 ? (nothing, bits[1], nothing) : (bits[1], bits[2], length(bits) == 3 ? bits[3] : nothing)
    seq = stringish(v) ? collect(str(v)) : collect(to_iterable(v))
    idx = py_slice(length(seq), start, stop, step)
    idx === nothing && return v
    stringish(v) ? join(seq[idx]) : seq[idx]
end

function pluralize_filter(v, a)
    arg = a === nothing ? "s" : str(a)
    occursin(',', arg) || (arg = "," * arg)
    bits = split(arg, ',')
    length(bits) > 2 && return ""
    singular, plural = bits[1], bits[2]
    if v isa Number || stringish(v)
        f = v isa Number ? Float64(v) : tryparse(Float64, strip(str(v)))
        f === nothing && return ""              # text that isn't a number
        return f == 1 ? singular : plural
    end
    v === nothing && return ""
    applicable(iterate, v) || v isa QuerySet || return ""
    length(collect(to_iterable(v))) == 1 ? singular : plural
end

"Python's `str.expandtabs()`: tabs to the next multiple of 8 columns."
function expand_tabs(s::AbstractString)
    io, col = IOBuffer(), 0
    for c in s
        if c == '\t'
            n = 8 - col % 8
            print(io, " "^n); col += n
        else
            print(io, c); col += 1
        end
    end
    String(take!(io))
end
"One line wrapped as Python's TextWrapper (long words kept whole, a break uses up its space)."
function wrap_line(line::AbstractString, width::Int)
    chunks = [String(m.match) for m in eachmatch(r"\s+|\S+", expand_tabs(line))]
    lines, i = String[], 1
    while i <= length(chunks)
        !isempty(lines) && all(isspace, chunks[i]) && (i += 1; continue)      # (no space at the start of a new line)
        cur, len = String[], 0
        while i <= length(chunks) && len + length(chunks[i]) <= width
            push!(cur, chunks[i]); len += length(chunks[i]); i += 1
        end
        isempty(cur) && i <= length(chunks) && (push!(cur, chunks[i]); i += 1)  # (a word longer than the width)
        !isempty(cur) && all(isspace, cur[end]) && pop!(cur)
        isempty(cur) || push!(lines, join(cur))
    end
    lines
end
"Django's `wrap` (the `wordwrap` filter): existing line breaks kept, each line wrapped at `width`."
function wrap_text(text::AbstractString, width::Int)
    out = String[]
    for line in split(text, r"\r\n|\r|\n")
        w = wrap_line(line, width)
        isempty(w) ? push!(out, line) : append!(out, w)
    end
    # (a text ending in a line break: split gives an empty last line, as Django's added "")
    join(out, "\n")
end

let F = register_filter!
    F("add", (v, a) -> (iv = py_int(v); ia = py_int(a); iv !== nothing && ia !== nothing ? iv + ia : something(py_add(v, a), "")))
    F("addslashes", (v, _) -> replace(str(v), "\\" => "\\\\", "\"" => "\\\"", "'" => "\\'"); is_safe = true)
    F("center", (v, a) -> (s = str(v); n = something(py_int(a), 0); p = max(n - length(s), 0); " "^(p ÷ 2) * s * " "^(p - p ÷ 2)); is_safe = true)
    F("ljust", (v, a) -> rpad(str(v), something(py_int(a), 0)); is_safe = true)
    F("rjust", (v, a) -> lpad(str(v), something(py_int(a), 0)); is_safe = true)
    # (removing ";" can break an entity, so the result isn't safe then)
    F("cut", (v, a) -> (s = replace(str(v), str(a) => ""); v isa SafeString && str(a) != ";" ? SafeString(s) : s))
    F("upper", (v, _) -> uppercase(str(v)))
    F("title", (v, _) -> replace(replace(py_title(str(v)), r"([a-z])'([A-Z])" => lowercase), r"\d([A-Z])" => lowercase); is_safe = true)
    F("first", (v, _) -> v === nothing ? "" : stringish(v) ? (s = str(v); isempty(s) ? "" : string(first(s))) :
                         (it = to_iterable(v); isempty(it) ? "" : first(it)))
    F("last", (v, _) -> v === nothing ? "" : stringish(v) ? (s = str(v); isempty(s) ? "" : string(last(s))) :
                        (it = to_iterable(v); isempty(it) ? "" : last(it)); is_safe = true)
    F("random", (v, _) -> v === nothing ? "" : (it = to_iterable(v); isempty(it) ? "" : rand(it)); is_safe = true)
    F("length", (v, _) -> v === nothing || v isa Number ? 0 : stringish(v) ? length(str(v)) : v isa QuerySet ? length(collect(v)) :
                          applicable(length, v) ? length(v) : 0)
    F("make_list", (v, _) -> [string(c) for c in str(v)])
    F("dictsort", (v, a) -> dictsort_filter(v, a))
    F("dictsortreversed", (v, a) -> dictsort_filter(v, a; rev = true))
    F("slice", slice_filter; is_safe = true)
    F("pluralize", pluralize_filter)
    F("floatformat", floatformat_filter; is_safe = true)
    # (%s writes the value as Python's str() would: a list as ['a', 'b'])
    F("stringformat", (v, a) -> try Printf.format(Printf.Format("%" * str(a)), endswith(str(a), "s") && !(v isa Number) ? display_string(v) :
                                                 v isa Tuple ? string(v) : stringish(v) ? str(v) : v) catch; "" end;
      is_safe = true)
    F("iriencode", (v, _) -> py_quote(str(v), "/#%[]=:;\$&()+,!?*@'~"); is_safe = true)
    F("urlencode", (v, a) -> py_quote(str(v), a === nothing ? "/" : str(a)))
    F("phone2numeric", (v, _) -> map(c -> get(PHONE_LETTERS, lowercase(c), c), str(v)); is_safe = true)
    F("json_script", (v, a) -> SafeString("<script" * (a === nothing || isempty(str(a)) ? "" : " id=\"" * escape_html(str(a)) * "\"") *
                                          " type=\"application/json\">" *
                                          replace(py_json(v), "<" => "\\u003C", ">" => "\\u003E", "&" => "\\u0026") * "</script>"); is_safe = true)
    F("linebreaksbr", (v, _, ae) -> begin
        s = replace(str(v), "\r\n" => "\n", "\r" => "\n")
        SafeString(replace(ae && !(v isa SafeString) ? escape_html(s) : s, "\n" => "<br>"))
    end; is_safe = true, needs_autoescape = true)
    F("linenumbers", (v, _, ae) -> begin
        lines = split(str(v), '\n'); w = length(string(length(lines)))
        esc = ae && !(v isa SafeString)
        SafeString(join(["$(lpad(i, w, '0')). $(esc ? escape_html(l) : l)" for (i, l) in enumerate(lines)], "\n"))
    end; is_safe = true, needs_autoescape = true)
    F("truncatechars", (v, a) -> (n = py_int(a); n === nothing ? v : (s = str(v); n <= 0 ? "" : length(s) <= n ? s : first(s, n - 1) * "…"));
      is_safe = true)
    F("truncatewords", (v, a) -> (n = py_int(a); n === nothing ? v : (w = split(str(v)); n <= 0 ? "" : length(w) <= n ? join(w, " ") :
                                                                   join(w[1:n], " ") * " …")); is_safe = true)
    F("wordwrap", (v, a) -> wrap_text(str(v), something(py_int(a), 0)); is_safe = true)
    F("date", (v, a) -> v === nothing || v == "" ? "" : format_date(v, a === nothing ? get_format().date : str(a)))
    F("time", (v, a) -> v === nothing || v == "" ? "" : format_date(v, a === nothing ? "g:i a" : str(a)))
    F("timesince", (v, a) -> !truthy(v) ? "" : (r = try a === nothing ? timesince(v) : timesince(v, a) catch; "" end; something(r, "")))
end

# --- HTML entities, truncating HTML, urlize -----------------------------------------------------------------

# the named entities of ISO 8859-1 (&nbsp; ... &yuml;, U+00A0 to U+00FF), and the common others
const LATIN1_ENTITY_NAMES = split("nbsp iexcl cent pound curren yen brvbar sect uml copy ordf laquo not shy reg macr deg plusmn sup2 sup3 " *
    "acute micro para middot cedil sup1 ordm raquo frac14 frac12 frac34 iquest Agrave Aacute Acirc Atilde Auml Aring AElig Ccedil " *
    "Egrave Eacute Ecirc Euml Igrave Iacute Icirc Iuml ETH Ntilde Ograve Oacute Ocirc Otilde Ouml times Oslash Ugrave Uacute Ucirc " *
    "Uuml Yacute THORN szlig agrave aacute acirc atilde auml aring aelig ccedil egrave eacute ecirc euml igrave iacute icirc iuml " *
    "eth ntilde ograve oacute ocirc otilde ouml divide oslash ugrave uacute ucirc uuml yacute thorn yuml")
const ENTITIES = merge(Dict{String,String}(String(n) => string(Char(0xa0 + i - 1)) for (i, n) in enumerate(LATIN1_ENTITY_NAMES)),
                       Dict("amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "hellip" => "…", "mdash" => "—",
                            "ndash" => "–", "lsquo" => "‘", "rsquo" => "’", "ldquo" => "“", "rdquo" => "”", "euro" => "€"),
                       # (HTML5's names for ASCII punctuation, as Python's: "..&sol;x" is "../x")
                       Dict("sol" => "/", "bsol" => "\\", "period" => ".", "comma" => ",", "colon" => ":", "semi" => ";", "excl" => "!",
                            "quest" => "?", "num" => "#", "dollar" => "\$", "percnt" => "%", "lpar" => "(", "rpar" => ")", "ast" => "*",
                            "midast" => "*", "plus" => "+", "equals" => "=", "lowbar" => "_", "UnderBar" => "_", "Hat" => "^",
                            "grave" => "`", "DiacriticalGrave" => "`", "lsqb" => "[", "lbrack" => "[", "rsqb" => "]", "rbrack" => "]",
                            "lcub" => "{", "lbrace" => "{", "rcub" => "}", "rbrace" => "}", "verbar" => "|", "vert" => "|",
                            "VerticalLine" => "|", "commat" => "@", "Tab" => "\t", "NewLine" => "\n"))
"Python's `html.unescape`: character references and named entities to characters."
html_unescape(s::AbstractString) = replace(s, r"&(?:#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);|&(?:amp|lt|gt|quot)(?![A-Za-z0-9;])" => function (m)
    endswith(m, ';') || return ENTITIES[m[2:end]]             # (&amp without a semicolon, as Python's legacy entities)
    e = m[2:end-1]
    if startswith(e, "#")
        n = tryparse(Int, startswith(e, "#x") || startswith(e, "#X") ? e[3:end] : e[2:end]; base = startswith(e, "#x") || startswith(e, "#X") ? 16 : 10)
        return n === nothing || !isvalid(Char, n) ? m : string(Char(n))
    end
    get(ENTITIES, e, m)
end)

const TRUNCATE_VOID_ELEMENTS = Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"])

"""
HTML truncated after `n` characters or words of its text, as Django's Truncator with `html = True`:
tags are kept and those left open are closed, entities count as one character, comments go.
"""
function truncate_html(text::AbstractString, n::Int; words::Bool)
    n <= 0 && return ""
    words || (text = Base.Unicode.normalize(String(text), :NFC))
    remaining = words ? n : n - 1                          # (room for the ellipsis)
    out, tags, processed = String[], String[], 0
    for m in eachmatch(r"<!--.*?-->|<[!?][^>]*>|</?[A-Za-z][^>]*>|[^<]+|<"s, text)
        tok = m.match
        if startswith(tok, "<!") || startswith(tok, "<?")
            continue                                        # comments, doctypes, processing instructions
        elseif (t = match(r"^</\s*([A-Za-z][\w:-]*)", tok)) !== nothing
            name = lowercase(t[1])
            name in TRUNCATE_VOID_ELEMENTS && continue
            push!(out, "</$name>")
            !isempty(tags) && tags[end] == name && pop!(tags)
        elseif (t = match(r"^<([A-Za-z][\w:-]*)", tok)) !== nothing
            name = lowercase(t[1])
            push!(out, tok)
            if endswith(tok, "/>")
                name in TRUNCATE_VOID_ELEMENTS || push!(out, "</$name>")
            else
                name in TRUNCATE_VOID_ELEMENTS || push!(tags, name)
            end
        else
            data = html_unescape(tok)
            if words
                units = split(data, r"(?<=\S)\s+(?=\S)")
                output = escape_html(join(units[1:min(remaining, length(units))], " "))
            else
                processed += length(data)
                if processed == n && sum(length, out; init = 0) + length(data) == length(text)
                    push!(out, data)                       # (exactly n characters: nothing truncated)
                    break
                end
                units = data
                output = escape_html(first(data, max(remaining, 0)))
            end
            if remaining < length(units)
                push!(out, output * (words ? " …" : "…"))
                append!(out, ["</$t>" for t in reverse(tags)])
                return join(out)
            end
            remaining -= length(units)
            push!(out, output)
        end
    end
    join(out)
end

const URLIZE_TRAILING = ".,:;!"
const URLIZE_WRAPPING = (('(', ')'), ('[', ']'))
const URLIZE_HOST = "[a-z¡-￿0-9](?:[a-z¡-￿0-9-]{0,61}[a-z¡-￿0-9])?"
const URLIZE_DOMAIN = "(?:\\.(?!-)[a-z¡-￿0-9-]{1,63}(?<!-))*"
const URLIZE_SIMPLE = r"^https?://\[?\w"i
const URLIZE_SIMPLE_2 = Regex("^www\\.|^(?!http)(?:$URLIZE_HOST)(?:$URLIZE_DOMAIN)\\.(com|edu|gov|int|mil|net|org)(\$|/.*)\$", "i")
const URL_SAFE = "!\$&'()*+,;=:/?#[]@~"                  # RFC 3986 sub- and gen-delimiters, and ~

"Python's `unquote`: %XX escapes back to the bytes they stand for."
py_unquote(s::AbstractString) = String(replace(s, r"%[0-9a-fA-F]{2}" => m -> String([parse(UInt8, m[2:3]; base = 16)])))
"A URL quoted unless it already is (Django's `smart_urlquote`): host, path and fragment percent-encoded, the query re-encoded."
function smart_urlquote(url::AbstractString)
    uq(seg) = py_quote(py_unquote(seg), URL_SAFE)
    m = match(r"^([A-Za-z][A-Za-z0-9+.-]*:)?(//[^/?#]*)?([^?#]*)(\?[^#]*)?(#.*)?$", url)
    m === nothing && return uq(url)
    scheme, netloc, path, query, frag = lowercase(something(m[1], "")), something(m[2], ""), m[3], something(m[4], ""), something(m[5], "")
    if !isempty(query)
        parts = [split(p, '='; limit = 2) for p in split(query[2:end], r"[&;]") if !isempty(p)]
        qp(x) = replace(py_quote(py_unquote(replace(x, '+' => ' ')), " "), " " => "+")
        query = "?" * join((qp(p[1]) * "=" * (length(p) > 1 ? qp(p[2]) : "") for p in parts), "&")
    end
    scheme * (isempty(netloc) ? "" : "//" * uq(netloc[3:end])) * uq(path) * query * (isempty(frag) ? "" : "#" * uq(frag[2:end]))
end

"Wrapping and trailing punctuation off a word, as Django's Urlizer: `(lead, middle, trail)`."
function urlize_trim(word::AbstractString)
    middle = lstrip(word, ['(', '['])
    lead = word[1:prevind(word, ncodeunits(word) - ncodeunits(middle) + 1)]
    middle = String(middle)
    trail = String[]
    counts = Dict{Char,Int}(c => count(==(c), middle) for c in "()[]")
    trimmed = true
    while trimmed && !isempty(middle)
        trimmed = false
        for (o, c) in URLIZE_WRAPPING
            if counts[o] < counts[c] && endswith(middle, c)
                k = counts[c] - counts[o]
                tail = last(middle, k)
                pushfirst!(trail, tail)
                middle = first(middle, length(middle) - k)
                trimmed = true
                counts[c] -= k
            end
        end
        amp = findlast('&', middle)
        stripped = rstrip(middle, collect(amp === nothing ? URLIZE_TRAILING : replace(URLIZE_TRAILING, ";" => "")))
        if stripped != middle
            pushfirst!(trail, middle[ncodeunits(stripped)+1:end])
            middle = String(stripped)
            trimmed = true
        end
        if endswith(middle, ';')
            potential = amp === nothing ? middle : middle[amp:end]
            unesc = html_unescape(potential)
            if unesc == potential || endswith(unesc, ";")
                stripped = rstrip(middle, collect(URLIZE_TRAILING))
                start = ncodeunits(stripped)
                nsemi = length(middle) - length(rstrip(middle, ';'))
                if amp !== nothing && nsemi > 1
                    rest = middle[start+1:end]
                    k = findfirst(';', rest)
                    pushfirst!(trail, rest[k+1:end])
                    middle = stripped * rest[1:k]
                else
                    pushfirst!(trail, middle[start+1:end])
                    middle = String(stripped)
                end
                trimmed = true
            end
        end
    end
    lead, middle, join(trail)
end

"Django's urlize: URLs, `www.` and bare domain links and email addresses in text made into links."
function urlize_text(text, trim_limit = nothing; nofollow::Bool = true, autoescape::Bool = false)
    safe_input = text isa SafeString
    trim(x) = trim_limit === nothing || length(x) <= trim_limit ? x : first(x, max(0, trim_limit - 1)) * "…"
    function word_html(word)
        if occursin('.', word) || occursin('@', word) || occursin(':', word)
            lead, middle, trail = urlize_trim(word)
            url, rel = nothing, nofollow ? " rel=\"nofollow\"" : ""
            if length(middle) <= 2048 && occursin(URLIZE_SIMPLE, middle)
                url = smart_urlquote(html_unescape(middle))
            elseif length(middle) <= 2048 && occursin(URLIZE_SIMPLE_2, middle)
                url = smart_urlquote("https://" * html_unescape(middle))       # (Django 2028's default: https)
            elseif !occursin(':', middle) && occursin('@', middle) && validation_error(EmailValidator(allowlist = String[]), middle) === nothing
                local_part, domain = rsplit(middle, '@'; limit = 2)
                url = "mailto:" * py_quote(local_part, "") * "@" * py_quote(domain, "")
                rel = ""
            end
            if url !== nothing
                trimmed = trim(middle)
                if autoescape && !safe_input
                    lead, trail, trimmed = escape_html(lead), escape_html(trail), escape_html(trimmed)
                end
                return lead * "<a href=\"" * escape_html(url) * "\"" * rel * ">" * trimmed * "</a>" * trail
            end
        end
        safe_input ? word : autoescape ? escape_html(word) : word
    end
    s = str(text)
    io = IOBuffer()
    last_ = 1
    for m in eachmatch(r"[\s<>\"']+", s)
        print(io, word_html(s[last_:prevind(s, m.offset)]))
        sep = m.match
        print(io, safe_input || !autoescape ? sep : escape_html(sep))
        last_ = m.offset + ncodeunits(sep)
    end
    print(io, word_html(s[last_:end]))
    String(take!(io))
end

let F = register_filter!
    F("truncatechars_html", (v, a) -> (n = py_int(a); n === nothing ? v : truncate_html(str(v), n; words = false)); is_safe = true)
    F("truncatewords_html", (v, a) -> (n = py_int(a); n === nothing ? v : truncate_html(str(v), n; words = true)); is_safe = true)
    F("urlize", (v, _, ae) -> SafeString(urlize_text(v; autoescape = ae)); is_safe = true, needs_autoescape = true)
    F("urlizetrunc", (v, a, ae) -> SafeString(urlize_text(v, something(py_int(a), 0); autoescape = ae)); is_safe = true, needs_autoescape = true)
end
