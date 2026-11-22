# Internationalisation and localisation ------------------------------------------------------------------
#
#     gettext("Welcome")                  # translated into the active language
#     t"Welcome"                          # the same, shorter
#     ngettext("%(n)d comment", "%(n)d comments", n)
#     pgettext("month name", "May")
#     gettext_lazy("Title")               # for labels: translated when shown
#     with_language("de") do ... end
#
#     {% translate "Welcome" %}  {% blocktranslate count n=items|length %}{{ n }} item{% plural %}{{ n }} items{% endblocktranslate %}
#
# Catalogues are gettext .po/.mo files at <path>/<locale>/LC_MESSAGES/juango.{po,mo}, looked up in
# LOCALE_PATHS (first wins), then Juango's own (src/locale). `manage.jl makemessages -l de` writes
# them, `compilemessages` builds the .mo files.

# --- catalogues ------------------------------------------------------------------------------------------

struct Catalog
    messages::Dict{Tuple{String,String},Vector{String}}   # (context, msgid) => translations (plural forms)
    plural::Function                                      # n -> index of the plural form
    plural_expr::String                                   # the same rule as a C expression (for JavaScriptCatalog)
    nplurals::Int                                         # the number of plural forms (the header's nplurals)
end
Catalog(msgs, plural, expr) = Catalog(msgs, plural, expr, 2)
Catalog(msgs, plural) = Catalog(msgs, plural, "n != 1")
Catalog() = Catalog(Dict{Tuple{String,String},Vector{String}}(), n -> n == 1 ? 0 : 1)
plural_expr(header) = (m = match(r"plural\s*=\s*([^;]+)", header); m === nothing ? "n != 1" : strip(m[1]))
plural_count(header) = (m = match(r"nplurals\s*=\s*(\d+)", header); m === nothing ? 2 : parse(Int, m[1]))

function po_unescape(s)
    io = IOBuffer()
    i = 1
    while i <= lastindex(s)
        c = s[i]
        if c == '\\' && i < lastindex(s)
            n = s[nextind(s, i)]
            print(io, n == 'n' ? '\n' : n == 't' ? '\t' : n == 'r' ? '\r' : n)
            i = nextind(s, nextind(s, i))
        else
            print(io, c)
            i = nextind(s, i)
        end
    end
    String(take!(io))
end
po_escape(s) = replace(s, "\\" => "\\\\", "\"" => "\\\"", "\n" => "\\n", "\t" => "\\t")

"One entry of a .po file."
mutable struct POEntry
    context::String
    msgid::String
    msgid_plural::String
    msgstr::Vector{String}
    fuzzy::Bool
    comments::Vector{String}
end
POEntry() = POEntry("", "", "", String[""], false, String[])

"Read the entries of a .po file (fuzzy and obsolete entries are kept but flagged/skipped)."
function parse_po(text::AbstractString)
    entries = POEntry[]
    e = POEntry()
    field = nothing
    started = false
    flush_entry() = (started && push!(entries, e); e = POEntry(); field = nothing; started = false)
    for raw in split(text, '\n')
        line = strip(raw)
        if isempty(line)
            flush_entry()
        elseif startswith(line, "#~")
            continue
        elseif startswith(line, "#,")
            occursin("fuzzy", line) && (e.fuzzy = true)
        elseif startswith(line, "#")
            started && field !== nothing && flush_entry()
            push!(e.comments, String(line))
        elseif (m = match(r"^(msgctxt|msgid_plural|msgid|msgstr(?:\[(\d+)\])?)\s+\"(.*)\"$", line)) !== nothing
            kw = m[1]
            kw == "msgctxt" && started && field !== nothing && field != :msgctxt && flush_entry()
            kw == "msgid" && started && field !== nothing && !(field in (:msgctxt,)) && flush_entry()
            started = true
            val = po_unescape(m[3])
            if kw == "msgctxt"
                e.context = val; field = :msgctxt
            elseif kw == "msgid"
                e.msgid = val; field = :msgid
            elseif kw == "msgid_plural"
                e.msgid_plural = val; field = :msgid_plural
            else
                i = m[2] === nothing ? 0 : parse(Int, m[2])
                while length(e.msgstr) <= i; push!(e.msgstr, ""); end
                e.msgstr[i+1] = val; field = (:msgstr, i)
            end
        elseif startswith(line, "\"") && endswith(line, "\"") && field !== nothing
            val = po_unescape(line[2:end-1])
            if field == :msgctxt; e.context *= val
            elseif field == :msgid; e.msgid *= val
            elseif field == :msgid_plural; e.msgid_plural *= val
            else; e.msgstr[field[2]+1] *= val
            end
        end
    end
    flush_entry()
    entries
end

"Write entries as a .po file."
function write_po(io::IO, entries; header = nothing)
    if header !== nothing
        println(io, "msgid \"\"\nmsgstr \"\"")
        for l in split(header, '\n'; keepempty = false)
            println(io, "\"", po_escape(l), "\\n\"")
        end
        println(io)
    end
    for e in entries
        foreach(c -> println(io, c), e.comments)
        e.fuzzy && println(io, "#, fuzzy")
        isempty(e.context) || println(io, "msgctxt \"", po_escape(e.context), "\"")
        println(io, "msgid \"", po_escape(e.msgid), "\"")
        if isempty(e.msgid_plural)
            println(io, "msgstr \"", po_escape(first(e.msgstr)), "\"")
        else
            println(io, "msgid_plural \"", po_escape(e.msgid_plural), "\"")
            for (i, s) in enumerate(e.msgstr)
                println(io, "msgstr[", i - 1, "] \"", po_escape(s), "\"")
            end
        end
        println(io)
    end
end

header_of(entries) = (i = findfirst(e -> isempty(e.msgid) && isempty(e.context), entries); i === nothing ? "" : first(entries[i].msgstr))
function plural_rule(header)
    m = match(r"plural\s*=\s*([^;]+)", header)
    m === nothing && return n -> n == 1 ? 0 : 1
    plural_function(m[1])
end

function catalog_from_entries(entries)
    msgs = Dict{Tuple{String,String},Vector{String}}()
    for e in entries
        (isempty(e.msgid) || e.fuzzy || all(isempty, e.msgstr)) && continue
        msgs[(e.context, e.msgid)] = e.msgstr
    end
    Catalog(msgs, plural_rule(header_of(entries)), plural_expr(header_of(entries)), plural_count(header_of(entries)))
end

# --- .mo (GNU gettext binary catalogue) --------------------------------------------------------------------

mo_key(e) = (isempty(e.context) ? "" : e.context * "\x04") * e.msgid * (isempty(e.msgid_plural) ? "" : "\0" * e.msgid_plural)

"Compile .po entries into .mo bytes."
function write_mo(entries)
    items = sort([(mo_key(e), join(e.msgstr, "\0")) for e in entries if !e.fuzzy && (isempty(e.msgid) || !all(isempty, e.msgstr))]; by = first)
    n = length(items)
    keys_ = [Vector{UInt8}(codeunits(k)) for (k, _) in items]
    vals = [Vector{UInt8}(codeunits(v)) for (_, v) in items]
    otab, ttab = 28, 28 + 8n
    off = 28 + 16n
    io = IOBuffer()
    write(io, htol(UInt32(0x950412de)), htol(UInt32(0)), htol(UInt32(n)), htol(UInt32(otab)), htol(UInt32(ttab)),
          htol(UInt32(0)), htol(UInt32(off)))
    pos = off
    korig = Int[]
    for k in keys_; push!(korig, pos); pos += length(k) + 1; end
    vpos = Int[]
    for v in vals; push!(vpos, pos); pos += length(v) + 1; end
    for (k, p) in zip(keys_, korig); write(io, htol(UInt32(length(k))), htol(UInt32(p))); end
    for (v, p) in zip(vals, vpos); write(io, htol(UInt32(length(v))), htol(UInt32(p))); end
    for k in keys_; write(io, k, UInt8(0)); end
    for v in vals; write(io, v, UInt8(0)); end
    take!(io)
end

"Read a .mo file into entries."
function read_mo(bytes::AbstractVector{UInt8})
    magic = reinterpret(UInt32, bytes[1:4])[1]
    swap = magic == 0xde120495
    (magic == 0x950412de || swap) || throw(ArgumentError("not a .mo file"))
    u32(i) = (v = reinterpret(UInt32, bytes[i+1:i+4])[1]; Int(swap ? bswap(v) : v))
    n, otab, ttab = u32(8), u32(12), u32(16)
    entries = POEntry[]
    for i in 0:n-1
        kl, ko = u32(otab + 8i), u32(otab + 8i + 4)
        vl, vo = u32(ttab + 8i), u32(ttab + 8i + 4)
        k, v = String(bytes[ko+1:ko+kl]), String(bytes[vo+1:vo+vl])
        e = POEntry()
        if occursin('\x04', k)
            e.context, k = split(k, '\x04'; limit = 2)
        end
        parts = split(k, '\0')
        e.msgid = parts[1]
        length(parts) > 1 && (e.msgid_plural = parts[2])
        e.msgstr = String.(split(v, '\0'))
        push!(entries, e)
    end
    entries
end

# --- plural forms: a tiny evaluator for the C expressions in Plural-Forms ---------------------------------------

"Compile a Plural-Forms expression like `(n != 1)` or `n%10==1 && n%100!=11 ? 0 : 1` into a function of n."
function plural_function(src::AbstractString)
    toks = [m.match for m in eachmatch(r"\d+|n|==|!=|<=|>=|&&|\|\||[<>?:%()!+\-*/]", src)]
    pos = Ref(1)
    peek() = pos[] <= length(toks) ? toks[pos[]] : ""
    next() = (t = peek(); pos[] += 1; t)
    prec = Dict("||" => 1, "&&" => 2, "==" => 3, "!=" => 3, "<" => 4, ">" => 4, "<=" => 4, ">=" => 4,
                "+" => 5, "-" => 5, "*" => 6, "/" => 6, "%" => 6)
    function primary()
        t = next()
        t == "(" && (e = ternary(); next(); return e)
        t == "!" && (e = primary(); return n -> e(n) == 0 ? 1 : 0)
        t == "n" && return n -> n
        v = parse(Int, t)
        n -> v
    end
    function binary(minp)
        lhs = primary()
        while haskey(prec, peek()) && prec[peek()] >= minp
            op = next()
            rhs = binary(prec[op] + 1)
            l = lhs
            lhs = op == "||" ? (n -> (l(n) != 0 || rhs(n) != 0) ? 1 : 0) :
                  op == "&&" ? (n -> (l(n) != 0 && rhs(n) != 0) ? 1 : 0) :
                  op == "==" ? (n -> l(n) == rhs(n) ? 1 : 0) : op == "!=" ? (n -> l(n) != rhs(n) ? 1 : 0) :
                  op == "<" ? (n -> l(n) < rhs(n) ? 1 : 0) : op == ">" ? (n -> l(n) > rhs(n) ? 1 : 0) :
                  op == "<=" ? (n -> l(n) <= rhs(n) ? 1 : 0) : op == ">=" ? (n -> l(n) >= rhs(n) ? 1 : 0) :
                  op == "+" ? (n -> l(n) + rhs(n)) : op == "-" ? (n -> l(n) - rhs(n)) :
                  op == "*" ? (n -> l(n) * rhs(n)) : op == "/" ? (n -> div(l(n), rhs(n))) : (n -> mod(l(n), rhs(n)))
        end
        lhs
    end
    function ternary()
        c = binary(1)
        peek() == "?" || return c
        next(); a = ternary(); next(); b = ternary()
        n -> c(n) != 0 ? a(n) : b(n)
    end
    f = ternary()
    n -> Int(f(Int(n)))
end

# --- languages --------------------------------------------------------------------------------------------------

"""
`\"pt-br\"` -> `\"pt_BR\"` (the locale name used for directories), as Django's: a region of more than two
letters is title-cased (`sr-latn` -> `sr_Latn`), a private-use tail is kept (`nl-nl-x-informal` ->
`nl_NL-x-informal`), and a name that is already a locale stays one (`en_US`).
"""
function to_locale(lang)
    language = string(lang)
    l, _, country = partition_str(lowercase(language), '-')
    isempty(country) && return lowercase(first(language, 3)) * language[nextind(language, 0, min(3, length(language)) + 1):end]
    country, _, tail = partition_str(country, '-')
    country = length(country) > 2 ? uppercasefirst(country) : uppercase(country)
    isempty(tail) || (country *= "-" * tail)
    l * "_" * country
end
"`\"pt_BR\"` -> `\"pt-br\"` (the language code used in URLs and headers)."
to_language(locale) = lowercase(replace(string(locale), '_' => '-'))

const BUILTIN_LOCALE_DIR = joinpath(ASSETS_DIR, "locale")
const CATALOGS = Dict{String,Catalog}()
const CATALOG_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(CATALOGS), CATALOG_LOCK))
"Forget loaded catalogues (after editing .po/.mo files)."
reload_translations!() = lock(() -> empty!(CATALOGS), CATALOG_LOCK)

locale_dirs() = vcat(String[string(p) for p in settings.LOCALE_PATHS], app_locale_dirs(), [BUILTIN_LOCALE_DIR])

function load_catalog_file(dir, loc)
    base = joinpath(dir, loc, "LC_MESSAGES", "juango")
    isfile(base * ".mo") && return read_mo(read(base * ".mo"))
    isfile(base * ".po") && return parse_po(read(base * ".po", String))
    nothing
end

"The merged catalogue for a language (LOCALE_PATHS first, Juango's own last)."
function catalog(lang)
    lock(CATALOG_LOCK) do
        get!(CATALOGS, string(lang)) do
            loc = to_locale(lang)
            names = unique([loc, split(loc, '_')[1]])
            msgs = Dict{Tuple{String,String},Vector{String}}()
            rule, expr, np = nothing, "n != 1", 2
            for dir in reverse(locale_dirs()), name in reverse(names)      # later (higher priority) entries overwrite
                entries = load_catalog_file(dir, name)
                entries === nothing && continue
                c = catalog_from_entries(entries)
                merge!(msgs, c.messages)
                isempty(header_of(entries)) || (rule = c.plural; expr = c.plural_expr; np = c.nplurals)
            end
            Catalog(msgs, something(rule, n -> n == 1 ? 0 : 1), expr, np)
        end
    end
end

"""
    fallback_catalog(lang) -> Catalog or nothing

The catalogue a language's missing messages come from, as Django's: LANGUAGE_CODE's, unless `lang`
is LANGUAGE_CODE or an English variant.
"""
function fallback_catalog(lang)
    l, d = lowercase(string(lang)), lowercase(string(settings.LANGUAGE_CODE))
    (l == d || startswith(l, "en")) ? nothing : catalog(d)
end

"The active language: set per task by `activate!`/`LocaleMiddleware`, else `LANGUAGE_CODE`."
get_language() = (l = get(task_local_storage(), :juango_language, nothing); l === nothing ? string(settings.LANGUAGE_CODE) : l)
"Make `lang` the active language for the current task."
activate!(lang) = (task_local_storage(:juango_language, string(lang)); nothing)
"Go back to `LANGUAGE_CODE`."
deactivate!() = (delete!(task_local_storage(), :juango_language); nothing)
"Run `f()` with `lang` active: `with_language(\"de\") do ... end`."
function with_language(f, lang)
    old = get(task_local_storage(), :juango_language, nothing)
    activate!(lang)
    try
        f()
    finally
        old === nothing ? deactivate!() : activate!(old)
    end
end
"The language's name from `LANGUAGES`."
language_name(code) = (i = findfirst(l -> first(l) == code, settings.LANGUAGES); i === nothing ? code : last(settings.LANGUAGES[i]))
"Whether the language reads right to left (its base code is in `LANGUAGES_BIDI`)."
get_language_bidi(lang = get_language()) = split(lowercase(string(lang)), '-')[1] in get(settings, :LANGUAGES_BIDI, ["he", "ar", "ar-dz", "ckb", "fa", "ug", "ur"])

# --- translating -------------------------------------------------------------------------------------------------

function translate(context, msgid, plural = nothing, n = 1)
    settings.USE_I18N || return plural === nothing || n == 1 ? msgid : plural
    isempty(msgid) && plural === nothing && return msgid        # (the catalog's "" entry is its header, not a translation)
    lang = get_language()
    c = catalog(lang)
    forms = get(c.messages, (context, msgid), nothing)
    if forms === nothing                                        # (then LANGUAGE_CODE's translation, as Django's fallback)
        fb = fallback_catalog(lang)
        forms = fb === nothing ? nothing : get(fb.messages, (context, msgid), nothing)
        forms === nothing && return plural === nothing || n == 1 ? msgid : plural
        c = fb
    end
    plural === nothing && return isempty(forms[1]) ? msgid : forms[1]
    i = clamp(c.plural(n), 0, length(forms) - 1)
    s = forms[i+1]
    isempty(s) ? (n == 1 ? msgid : plural) : s
end

"Translate a message into the active language."
gettext(msgid::AbstractString) = translate("", String(msgid))
"Translate singular/plural forms for count `n`: `ngettext(\"%(n)d file\", \"%(n)d files\", n)`."
ngettext(singular::AbstractString, plural::AbstractString, n::Integer) = translate("", String(singular), String(plural), n)
"Translate with a disambiguating context: `pgettext(\"month name\", \"May\")`."
pgettext(context::AbstractString, msgid::AbstractString) = translate(String(context), String(msgid))
npgettext(context, singular, plural, n::Integer) = translate(String(context), String(singular), String(plural), n)
# a safe message stays safe once translated (Django's), so marked-safe HTML isn't escaped afterwards
gettext(msgid::SafeString) = mark_safe(translate("", msgid.s))
ngettext(singular::SafeString, plural::AbstractString, n::Integer) = mark_safe(translate("", singular.s, String(plural), n))
pgettext(context::AbstractString, msgid::SafeString) = mark_safe(translate(String(context), msgid.s))

"`t\"Welcome\"` is `gettext(\"Welcome\")`."
macro t_str(s)
    :(gettext($s))
end

"""
A string translated when it is used (printed, compared, measured), not when it is created.
Use it for text defined at load time: model and field labels, help texts.
"""
struct LazyText <: AbstractString
    context::String
    msgid::String
    plural::Union{Nothing,String}
    n::Int
end
Base.String(l::LazyText) = translate(l.context, l.msgid, l.plural, l.n)
Base.string(l::LazyText) = String(l)
Base.print(io::IO, l::LazyText) = print(io, String(l))
Base.show(io::IO, l::LazyText) = show(io, String(l))
Base.ncodeunits(l::LazyText) = ncodeunits(String(l))
Base.codeunit(l::LazyText) = UInt8
Base.codeunit(l::LazyText, i::Integer) = codeunit(String(l), i)
Base.isvalid(l::LazyText, i::Integer) = isvalid(String(l), i)
Base.iterate(l::LazyText, i::Integer = 1) = iterate(String(l), i)
Base.:(==)(a::LazyText, b::AbstractString) = String(a) == b
Base.:(==)(a::AbstractString, b::LazyText) = a == String(b)
Base.hash(l::LazyText, h::UInt) = hash(String(l), h)
"Translate when used (labels defined at load time)."
gettext_lazy(msgid) = LazyText("", string(msgid), nothing, 1)
pgettext_lazy(context, msgid) = LazyText(string(context), string(msgid), nothing, 1)
ngettext_lazy(singular, plural, n) = LazyText("", string(singular), string(plural), Int(n))

# --- translated URL routes: path(gettext_lazy("about/"), view) ------------------------------------------------
# The route is matched and reversed in the active language (under i18n_patterns: the prefix's); it's compiled
# once per translation (urls.jl's current_route).
function path(route::LazyText, view; name = nothing, kwargs...)
    p = path(route.msgid, view; name = name, kwargs...)
    URLPattern(p.route, p.regex, p.params, p.view, p.name, p.defaults, route)
end
function path(route::LazyText, inc::Include)
    r = path(route.msgid, inc)
    URLResolver(r.route, r.regex, r.params, r.patterns, r.namespace, r.app_name, route)
end

"""
    translate_url(url, lang) -> String

The same page in another language (Django's): `url`'s path is resolved and reversed with `lang` active, so
its language prefix and translated routes change (`/en/account/register/` -> `/nl/profiel/registreren/`); the
query string and fragment are kept. A URL that doesn't resolve or reverse comes back unchanged.
"""
function translate_url(url::AbstractString, lang)
    m = match(r"^(?<head>[a-z][a-z0-9+.-]*://[^/?#]*)?(?<path>[^?#]*)(?<rest>.*)$"si, url)
    m === nothing && return String(url)
    rm = resolve(URIs.unescapeuri(m[:path]))
    (rm === nothing || rm.url_name === nothing) && return String(url)
    target = rm.namespace === nothing ? rm.url_name : rm.namespace * ":" * rm.url_name
    t = try
        with_language(() -> reverse_url(target; rm.kwargs...), string(lang))
    catch e
        e isa NoReverseMatch || rethrow()
        return String(url)
    end
    something(m[:head], "") * t * m[:rest]
end

"Fill `%(name)s`/`%(name)d` placeholders: `interpolate(\"%(n)d items\", Dict(\"n\" => 3))`."
interpolate(s::AbstractString, vars) =
    replace(s, r"%\((\w+)\)[sd]" => m -> string(get(vars, match(r"\((\w+)\)", m)[1], get(vars, Symbol(match(r"\((\w+)\)", m)[1]), ""))))

# --- formats -------------------------------------------------------------------------------------------------------

const FORMATS = Dict(
    "en" => (decimal = ".", thousand = ",", date = "N j, Y", datetime = "N j, Y, g:i a", short_date = "m/d/Y"),
    "de" => (decimal = ",", thousand = ".", date = "j. F Y", datetime = "j. F Y H:i", short_date = "d.m.Y"),
    "fr" => (decimal = ",", thousand = "\u202f", date = "j F Y", datetime = "j F Y H:i", short_date = "d/m/Y"),
    "es" => (decimal = ",", thousand = ".", date = "j \\d\\e F \\d\\e Y", datetime = "j \\d\\e F \\d\\e Y \\a \\l\\a\\s H:i", short_date = "d/m/Y"),
    "it" => (decimal = ",", thousand = ".", date = "j F Y", datetime = "l d F Y H:i", short_date = "d/m/Y"),
    "nl" => (decimal = ",", thousand = ".", date = "j F Y", datetime = "j F Y H:i", short_date = "j-n-Y"),
    "pt" => (decimal = ",", thousand = ".", date = "j \\d\\e F \\d\\e Y", datetime = "j \\d\\e F \\d\\e Y à\\s H:i", short_date = "d/m/Y"),
    "ru" => (decimal = ",", thousand = "\u00a0", date = "j E Y г.", datetime = "j E Y г. G:i", short_date = "d.m.Y"),
    "pl" => (decimal = ",", thousand = " ", date = "j E Y", datetime = "j E Y H:i", short_date = "d-m-Y"),
    "sv" => (decimal = ",", thousand = "\u00a0", date = "j F Y", datetime = "j F Y H:i", short_date = "Y-m-d"),
)
# a language's NUMBER_GROUPING and FIRST_DAY_OF_WEEK where they differ from the settings (Django's locale formats)
const FORMAT_EXTRAS = Dict("de" => (grouping = 3, first_day = 1), "fr" => (grouping = 3, first_day = 1), "es" => (grouping = 3, first_day = 1),
                           "it" => (grouping = 3, first_day = 1), "nl" => (grouping = 3, first_day = 1), "pt" => (grouping = 3, first_day = 0),
                           "ru" => (grouping = 3, first_day = 1), "pl" => (grouping = 3, first_day = 1), "sv" => (grouping = 3, first_day = 1),
                           "en" => (grouping = 3, first_day = 0))
"""
    get_format(lang = get_language())         -> the language's formats (decimal, thousand, date, datetime, short_date)
    get_format("DECIMAL_SEPARATOR"; lang)     -> one format by Django's name

The active language's formats: Juango's for the languages it has them for, else from the settings
(`DECIMAL_SEPARATOR`, `THOUSAND_SEPARATOR`, `DATE_FORMAT`...), as Django's `get_format`. The names are
Django's: `DATE_FORMAT`, `DATETIME_FORMAT`, `SHORT_DATE_FORMAT`, `DECIMAL_SEPARATOR`, `THOUSAND_SEPARATOR`,
`NUMBER_GROUPING`, `FIRST_DAY_OF_WEEK`, `DATE_INPUT_FORMATS`, `DATETIME_INPUT_FORMATS`, `TIME_INPUT_FORMATS`;
any other name comes back as it is.
"""
get_format(lang = get_language()) = is_format_name(lang) ? get_format(lang, get_language()) :
    get(FORMATS, split(lowercase(string(lang)), r"[-_]")[1], settings_formats())
is_format_name(s) = s isa AbstractString && length(s) > 3 && s == uppercase(s) && occursin(r"^[A-Z_]+$", s)
settings_formats() = (decimal = string(get(settings, :DECIMAL_SEPARATOR, ".")), thousand = string(get(settings, :THOUSAND_SEPARATOR, ",")),
                      date = string(get(settings, :DATE_FORMAT, "N j, Y")), datetime = string(get(settings, :DATETIME_FORMAT, "N j, Y, P")),
                      short_date = string(get(settings, :SHORT_DATE_FORMAT, "m/d/Y")))
function get_format(name::AbstractString, lang)
    is_format_name(name) || return get_format(name)
    name in FORMAT_SETTINGS || return name
    base = split(lowercase(string(lang)), r"[-_]")[1]
    f = get(FORMATS, base, nothing)
    ex = get(FORMAT_EXTRAS, base, nothing)
    if f === nothing                                        # (no locale formats: the settings, as Django)
        name == "NUMBER_GROUPING" && return get(settings, :NUMBER_GROUPING, 0)
        name == "FIRST_DAY_OF_WEEK" && return get(settings, :FIRST_DAY_OF_WEEK, 0)
        f = settings_formats()
    end
    name == "DECIMAL_SEPARATOR" && return f.decimal
    name == "THOUSAND_SEPARATOR" && return f.thousand
    name == "DATE_FORMAT" && return f.date
    name == "DATETIME_FORMAT" && return f.datetime
    name == "SHORT_DATE_FORMAT" && return f.short_date
    name == "NUMBER_GROUPING" && return ex === nothing ? get(settings, :NUMBER_GROUPING, 0) : ex.grouping
    name == "FIRST_DAY_OF_WEEK" && return ex === nothing ? get(settings, :FIRST_DAY_OF_WEEK, 0) : ex.first_day
    name == "DATE_INPUT_FORMATS" && return with_language(() -> input_formats(:date), lang)
    name == "DATETIME_INPUT_FORMATS" && return with_language(() -> input_formats(:datetime), lang)
    name == "TIME_INPUT_FORMATS" && return with_language(() -> input_formats(:time), lang)
    something(get(settings, Symbol(name), nothing), get(FORMAT_DEFAULTS, name, name))
end
# Django's global defaults for the format settings Juango has no per-language value for.
const FORMAT_DEFAULTS = Dict("TIME_FORMAT" => "P", "MONTH_DAY_FORMAT" => "F j", "YEAR_MONTH_FORMAT" => "F Y",
                             "SHORT_DATETIME_FORMAT" => "m/d/Y P")
"Django's FORMAT_SETTINGS: the settings `get_format` reads; any other name comes back as it is."
const FORMAT_SETTINGS = Set(["DECIMAL_SEPARATOR", "THOUSAND_SEPARATOR", "NUMBER_GROUPING", "FIRST_DAY_OF_WEEK", "MONTH_DAY_FORMAT",
    "TIME_FORMAT", "DATE_FORMAT", "DATETIME_FORMAT", "SHORT_DATE_FORMAT", "SHORT_DATETIME_FORMAT", "YEAR_MONTH_FORMAT",
    "DATE_INPUT_FORMATS", "TIME_INPUT_FORMATS", "DATETIME_INPUT_FORMATS"])

# The date formats forms accept, per language, as Django's locale formats (strftime directives);
# ISO 8601 is always accepted too. DATE_INPUT_FORMATS & co. are used for languages not listed here.
const EN_DATE_INPUT = ["%Y-%m-%d", "%m/%d/%Y", "%m/%d/%y", "%b %d %Y", "%b %d, %Y", "%d %b %Y", "%d %b, %Y",
                       "%B %d %Y", "%B %d, %Y", "%d %B %Y", "%d %B, %Y"]
const LOCALE_DATE_INPUT = Dict(
    "en" => EN_DATE_INPUT,
    "de" => ["%d.%m.%Y", "%d.%m.%y"],
    "fr" => ["%d/%m/%Y", "%d/%m/%y", "%d.%m.%Y", "%d.%m.%y"],
    "es" => ["%d/%m/%Y", "%d/%m/%y"],
    "it" => ["%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y", "%d-%m-%y", "%d/%m/%y"],
    "nl" => ["%d-%m-%Y", "%d-%m-%y", "%d/%m/%Y", "%d/%m/%y"],
    "pt" => ["%d/%m/%Y", "%d/%m/%y"],
)
const TIME_INPUT = ["%H:%M:%S", "%H:%M:%S.%f", "%H:%M"]

"The strftime input formats for `kind` (:date, :datetime, :time) in the active language."
function input_formats(kind::Symbol)
    lang = split(lowercase(get_language()), r"[-_]")[1]
    dates = get(() -> String.(something(get(settings, :DATE_INPUT_FORMATS, nothing), EN_DATE_INPUT)), LOCALE_DATE_INPUT, lang)
    times = String.(something(get(settings, :TIME_INPUT_FORMATS, nothing), TIME_INPUT))
    kind === :date && return vcat(dates, ["%Y-%m-%d"])
    kind === :time && return vcat(times, ["%H:%M:%S", "%H:%M"])
    custom = get(settings, :DATETIME_INPUT_FORMATS, nothing)
    dts = custom !== nothing ? String.(custom) : vcat([d * " " * t for d in dates for t in times], dates)
    vcat(dts, ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d"])
end

const STRFTIME_CODES = Dict('Y' => "yyyy", 'm' => "mm", 'd' => "dd", 'y' => "yy", 'H' => "HH", 'M' => "MM", 'S' => "SS",
                            'f' => "s", 'b' => "u", 'B' => "U", 'I' => "I", 'p' => "p")
const STRFTIME_CACHE = Dict{String,Union{Nothing,DateFormat}}()

"A strftime format (Django's input formats: \"%d.%m.%Y\") as a Julia `DateFormat`; `nothing` if it has directives Julia can't parse."
function strftime_dateformat(fmt::AbstractString)
    get!(STRFTIME_CACHE, fmt) do
        io = IOBuffer()
        i = firstindex(fmt)
        while i <= lastindex(fmt)
            c = fmt[i]
            if c == '%' && i < lastindex(fmt)
                d = fmt[nextind(fmt, i)]
                code = get(STRFTIME_CODES, d, nothing)
                code === nothing && d != '%' && return nothing
                print(io, d == '%' ? "%" : code)
                i = nextind(fmt, nextind(fmt, i))
                continue
            end
            isletter(c) ? print(io, '\\', c) : print(io, c)          # a literal letter is escaped
            i = nextind(fmt, i)
        end
        DateFormat(String(take!(io)))
    end
end

"""
    parse_input_datetime(s, kind; formats = nothing) -> Date / DateTime / Time or nothing

Parse what someone typed into a date, datetime or time field: `formats` (strftime, or Julia
`DateFormat`s) if given, else the active language's input formats, then ISO 8601. A two-digit
year is in 1969-2068, as Python's.
"""
function parse_input_datetime(s::AbstractString, kind::Symbol; formats = nothing)
    T = kind === :date ? Date : kind === :time ? Dates.Time : DateTime
    fmts = formats === nothing ? input_formats(kind) : collect(formats)      # (given formats replace the language's, as Django's)
    # runs of spaces as one, and fractions of a second to milliseconds (all a DateTime keeps), as strptime reads them
    s = replace(replace(String(s), r"\s+" => " "), r"(:\d\d\.\d{1,3})\d+" => s"\1")
    for f in fmts
        df = f isa DateFormat ? f : strftime_dateformat(string(f))
        df === nothing && continue
        v = tryparse(kind === :datetime && !occursin('H', string(df)) && !occursin('I', string(df)) ? Date : T, s, df)
        v === nothing && continue
        v isa Date && kind === :datetime && (v = DateTime(v))
        f isa AbstractString && occursin("%Y", f) && !(v isa Dates.Time) && Dates.year(v) < 1000 && continue   # %Y: four digits
        if !(v isa Dates.Time) && f isa AbstractString && occursin("%y", f) && Dates.year(v) < 100     # two-digit year
            y = Dates.year(v)
            v += Dates.Year(y < 69 ? 2000 : 1900)
        end
        return v
    end
    nothing
end

"""
    number_format(x; decimals=nothing, lang=get_language(), grouping=settings.USE_THOUSAND_SEPARATOR)

A number with the language's decimal separator (and thousands separators when `grouping`).
"""
function number_format(x::Real; decimals = nothing, lang = get_language(), grouping = settings.USE_THOUSAND_SEPARATOR)
    f = get_format(lang)
    s = if x isa Decimal
        string(decimals === nothing ? x : round(x, RoundNearestTiesAway; digits = decimals))
    else
        decimals === nothing ? (x isa Integer ? string(x) : !isfinite(x) ? string(Float64(x)) : (signbit(x) ? "-" : "") * fixed_digits(float_digits(x)...; min_fraction = 1)) : Printf.format(Printf.Format("%.$(decimals)f"), x)
    end
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    ip, fp = occursin('.', s) ? split(s, '.'; limit = 2) : (s, "")
    if grouping
        ip = reverse(join([reverse(ip)[i:min(end, i + 2)] for i in 1:3:length(ip)], reverse(f.thousand)))
    end
    (neg ? "-" : "") * ip * (isempty(fp) ? "" : f.decimal * fp)
end

"""
    numberformat(number, decimal_sep = "."; decimal_pos = nothing, grouping = 0, thousand_sep = "",
                 force_grouping = false, use_l10n = nothing) -> String

Django's `django.utils.numberformat.format`: `number` (an integer, float, Decimal or numeric string)
with `decimal_sep`, cut (not rounded) or padded to `decimal_pos` decimals, and the integer part grouped
by `grouping` (a size, or sizes from the right such as `(3, 2, 0)`, where 0 repeats the one before)
with `thousand_sep`. Grouping happens with `force_grouping`, or when `USE_THOUSAND_SEPARATOR` is on
and `use_l10n` isn't false. A Decimal of more than 200 digits is written in scientific notation.
"""
function numberformat(number, decimal_sep::AbstractString = "."; decimal_pos = nothing, grouping = 0, thousand_sep::AbstractString = "",
                      force_grouping::Bool = false, use_l10n = nothing)
    use_grouping = (use_l10n === nothing || use_l10n === true) && settings.USE_THOUSAND_SEPARATOR
    use_grouping = (use_grouping || force_grouping) && grouping != 0
    number isa Integer && !use_grouping && decimal_pos === nothing && return string(number)
    again(x) = numberformat(x, decimal_sep; decimal_pos, grouping, thousand_sep, force_grouping, use_l10n)
    str = if number isa AbstractFloat
        digits, point = float_digits(number)
        e10 = point - 1
        if -4 <= e10 < 16                   # Python's str(float) writes these in fixed notation (always with a fraction)
            (signbit(number) ? "-" : "") * fixed_digits(digits, point; min_fraction = 1)
        else                                # and the others through Decimal(str(float)), as Django
            return again(Decimal(parse(BigInt, digits) * (signbit(number) ? -1 : 1), point - length(digits), Val(:raw)))
        end
    elseif number isa Decimal
        d = number
        if decimal_pos !== nothing && abs(d) < Decimal(1, -max(decimal_pos, 1), Val(:raw))
            d = Decimal(0, 0, Val(:raw))
        end
        digits = string(abs(d.c))
        if abs(d.q) + length(digits) > 200   # ("{:e}": every digit of the coefficient)
            adj = d.q + length(digits) - 1
            coeff = (d.c < 0 ? "-" : "") * digits[1:1] * (length(digits) > 1 ? "." * digits[2:end] : "")
            return again(coeff) * "e" * (adj < 0 ? "-" : "+") * string(abs(adj))
        end
        (d.c < 0 ? "-" : "") * fixed_digits(digits, length(digits) + d.q)
    else
        string(number)
    end
    sign = ""
    startswith(str, "-") && (sign = "-"; str = str[2:end])
    ip, dp = occursin('.', str) ? split(str, '.'; limit = 2) : (str, "")
    decimal_pos === nothing || (dp = first(dp, decimal_pos))
    decimal_pos === nothing || (dp *= "0"^max(0, decimal_pos - length(dp)))
    dp = isempty(dp) ? "" : decimal_sep * dp
    if use_grouping
        intervals = grouping isa Integer ? Int[grouping, 0] : collect(Int, grouping)
        active = popfirst!(intervals)
        out = IOBuffer(); cnt = 0
        for ch in reverse(ip)
            if cnt != 0 && cnt == active
                isempty(intervals) || (nxt = popfirst!(intervals); nxt == 0 || (active = nxt))
                print(out, reverse(thousand_sep)); cnt = 0
            end
            print(out, ch); cnt += 1
        end
        ip = reverse(String(take!(out)))
    end
    sign * ip * dp
end
"A float's shortest round-trip digits (no leading or trailing zeros) and where the point goes in them."
function float_digits(x::AbstractFloat)
    m = match(r"^(\d+)\.(\d+)(?:e([-+]?\d+))?$", repr(abs(Float64(x))))
    ip, fp = m[1], m[2]
    point = length(ip) + (m[3] === nothing ? 0 : parse(Int, m[3]))
    digits = ip * fp
    lead = length(digits) - length(lstrip(digits, '0'))
    digits = rstrip(lstrip(digits, '0'), '0')
    isempty(digits) ? ("0", 1) : (String(digits), point - lead)
end
"Digits with the point after `point` of them, in fixed notation (`min_fraction` zeros at least after the point)."
function fixed_digits(digits, point; min_fraction = 0)
    ip = point <= 0 ? "0" : length(digits) >= point ? digits[1:point] : digits * "0"^(point - length(digits))
    fp = point <= 0 ? "0"^(-point) * digits : length(digits) > point ? digits[point+1:end] : ""
    length(fp) < min_fraction && (fp *= "0"^(min_fraction - length(fp)))
    isempty(fp) ? ip : ip * "." * fp
end

"Format a number or date for the active language (the `localize` template filter)."
localize(x::Real) = x isa Bool ? string(x) : number_format(x)
localize(x::Union{Date,DateTime}) = format_date(x, x isa Date ? get_format().date : get_format().datetime)
localize(x) = x

"""
    sanitize_separators(value)

A number typed in the active language's format as one with a `.` decimal point (Django's): the decimal
separator becomes `.`, and with `USE_THOUSAND_SEPARATOR` the thousands separators go (a non-breaking space
also as a plain space), unless a lone `.` separator without three digits after it looks like a decimal
point. Anything but a string is returned as it is.
"""
sanitize_separators(value) = value
function sanitize_separators(value::AbstractString; thousands = settings.USE_THOUSAND_SEPARATOR)
    parts = String[]
    dec = get_format("DECIMAL_SEPARATOR")
    v = String(value)
    if occursin(dec, v)
        v, decimals = split(v, dec; limit = 2)
        push!(parts, decimals)
    end
    if thousands
        t = get_format("THOUSAND_SEPARATOR")
        if !(t == "." && count(==('.'), v) == 1 && length(split(v, '.')[end]) != 3)     # (#22171: a dot meant as a decimal point)
            for r in unique([t, Base.Unicode.normalize(t; compat = true)])
                v = replace(v, r => "")
            end
        end
    end
    push!(parts, v)
    join(reverse(parts), ".")
end
"""
Parse a number typed in the active language's format (`\"1.234,5\"` in German): `sanitize_separators` after
trimming, with thousands separators always removed. (Django removes them only with USE_THOUSAND_SEPARATOR
and rejects `1.234,5` otherwise; Juango's forms have always accepted it.)
"""
parse_localized_number(s::AbstractString) = sanitize_separators(strip(s); thousands = true)

"""
    localize_input(value, default = nothing)

A value as a form input shows it (Django's): numbers in the language's format, dates and times in the
first of its input formats (or `default`, a strftime format), strings as they are.
"""
localize_input(value::AbstractString, default = nothing) = value
localize_input(value::Bool, default = nothing) = value ? "True" : "False"
localize_input(value::Real, default = nothing) = number_format(value)
localize_input(value::DateTime, default = nothing) = Dates.format(value, strftime_dateformat(something(default, first(input_formats(:datetime)))))
localize_input(value::Date, default = nothing) = Dates.format(value, strftime_dateformat(something(default, first(input_formats(:date)))))
localize_input(value::Dates.Time, default = nothing) = Dates.format(value, strftime_dateformat(something(default, first(input_formats(:time)))))
localize_input(value, default = nothing) = value

"Whether template output is localized here: `{% localize on %}` (true), `off` (false), else Juango's default (false)."
localize_output() = get(task_local_storage(), :juango_localize, false) === true
"`{{ x }}` inside `{% localize on %}`: numbers and dates in the language's format."
localized_output(x::Real) = x isa Bool ? x : number_format(x)
localized_output(x::Union{Date,DateTime}) = localize(x)
localized_output(x) = x

# --- choosing the language for a request ------------------------------------------------------------------------------

supported_codes() = [lowercase(string(first(l))) for l in settings.LANGUAGES]

"Pick a supported language for `code` (exact, then without the region, then any with the same base), or `nothing`."
supported_language(code) = supported_variant_or_nothing(code)

"""
    parse_accept_lang_header(h) -> Vector{Tuple{String,Float64}}

An Accept-Language header as Django parses it: `(language, q)` pairs, lowercased, best first (ties in
header order). A malformed header gives none at all. Only the first 500 characters are read (up to
the last whole entry), so a huge header costs nothing.
"""
function parse_accept_lang_header(h)
    s = lowercase(string(h))
    if length(s) > ACCEPT_LANGUAGE_HEADER_MAX_LENGTH
        cut = first(s, ACCEPT_LANGUAGE_HEADER_MAX_LENGTH)
        i = findlast(',', cut)
        s = i === nothing ? "" : cut[1:prevind(cut, i)]
    end
    out = Tuple{String,Float64}[]
    pos = 1
    re = r"\G\s*([a-z]{1,8}(?:-[a-z0-9]{1,8})*|\*)(?:\s*;\s*q=(0(?:\.[0-9]{0,3})?|1(?:\.0{0,3})?))?\s*(?:,|$)"
    while pos <= ncodeunits(s)
        m = match(re, s, pos)
        m === nothing && return Tuple{String,Float64}[]
        push!(out, (String(m[1]), m[2] === nothing ? 1.0 : parse(Float64, m[2])))
        pos = m.offset + ncodeunits(m.match)
        pos > ncodeunits(s) && break
        ncodeunits(m.match) == 0 && return Tuple{String,Float64}[]
    end
    sort!(out; by = x -> -x[2])           # (stable: equal q keep the header's order)
end
const ACCEPT_LANGUAGE_HEADER_MAX_LENGTH = 500

"Languages from an Accept-Language header, best first (`*` and what follows it left out)."
function parse_accept_language(h)
    out = String[]
    for (code, _) in parse_accept_lang_header(h)
        code == "*" && break
        push!(out, code)
    end
    out
end

"""
    get_supported_language_variant(code; strict = false) -> String

The language of `LANGUAGES` to use for `code` (Django's): the code itself, its base language (`de-at` ->
`de`), or (unless `strict`) another variant of that base (`pt` -> `pt-br`). Throws `KeyError` if none.
"""
function get_supported_language_variant(code; strict::Bool = false)
    c = lowercase(string(code))
    (isempty(c) || length(c) > 500) && throw(KeyError(code))
    codes = supported_codes()
    base = split(c, '-')[1]
    for x in (c, base)
        x in codes && return x
    end
    strict || for x in codes
        startswith(x, base * "-") && return x
    end
    throw(KeyError(code))
end
supported_variant_or_nothing(code; strict = false) = try get_supported_language_variant(code; strict = strict) catch e; e isa KeyError ? nothing : rethrow() end

"""
    get_language_from_path(path; strict = false) -> String or nothing

The supported language a path starts with (`/de/about/` -> `"de"`), as Django's.
"""
function get_language_from_path(path; strict::Bool = false)
    m = match(r"^/(\w+(?:[@-]\w+){0,2})(?:/|$)", string(path))
    m === nothing ? nothing : supported_variant_or_nothing(m[1]; strict = strict)
end

"The language for a request: URL prefix (i18n_patterns), then cookie, then Accept-Language, then LANGUAGE_CODE."
function language_from_request(req)
    p = get(req.meta, :language_prefix, nothing)
    p === nothing || return p
    c = get(req.COOKIES, settings.LANGUAGE_COOKIE_NAME, nothing)
    c === nothing || (l = supported_language(c); l === nothing || return l)
    for code in parse_accept_language(something(header(req, "accept-language"), ""))
        l = supported_language(code)
        l === nothing || return l
    end
    something(supported_language(settings.LANGUAGE_CODE), string(settings.LANGUAGE_CODE))
end

"""
Activates the request's language (see `language_from_request`) and sets `Content-Language`.
With `i18n_patterns`, a URL without a language prefix redirects to the prefixed one.
"""
function LocaleMiddleware(get_response)
    function (req::Request)
        lang = language_from_request(req)
        req.meta[:LANGUAGE_CODE] = lang
        resp = with_language(() -> get_response(req), lang)
        prefixed = get(req.meta, :language_prefix, nothing) !== nothing
        if resp.status == 404 && !prefixed && uses_i18n_patterns()
            # (the language's prefix, and a missing slash under APPEND_SLASH, as Django's)
            target = "/" * lang * req.path
            ok = resolve(target) !== nothing
            !ok && settings.APPEND_SLASH && !endswith(target, "/") && resolve(target * "/") !== nothing && (target *= "/"; ok = true)
            if ok
                resp = HttpResponseRedirect(target * (isempty(req.query_string) ? "" : "?" * req.query_string))
                patch_vary_headers!(resp, ("Accept-Language", "Cookie"))      # (the language came from these)
                return resp
            end
        end
        hasheader(resp, "Content-Language") || setheader!(resp, "Content-Language", lang)
        # a page whose language comes from its URL doesn't vary with Accept-Language (Django's)
        (prefixed && uses_i18n_patterns()) || patch_vary!(resp, "Accept-Language")
        resp
    end
end

"""
`set_language` view, as Django's: POST `language` (and `next`) to choose a language. It's
remembered in the `LANGUAGE_COOKIE_NAME` cookie (with the `LANGUAGE_COOKIE_AGE`, `_PATH`,
`_DOMAIN`, `_SECURE`, `_HTTPONLY` and `_SAMESITE` settings), and the user goes back to `next`
(or the Referer, or `/`, when `next` isn't safe), its language prefix swapped. A GET changes
nothing. A request that doesn't accept HTML (fetch, ajax) and gives no `next` gets 204.
"""
function set_language(req)
    host = [get_host(req)]
    ok(u) = u !== nothing && !isempty(u) && url_has_allowed_host_and_scheme(u, host; require_https = is_secure(req))
    nxt = get(req.POST, "next", get(req.GET, "next", nothing))
    if (nxt !== nothing || accepts(req, "text/html")) && !ok(nxt)
        ref = header(req, "referer")
        nxt = ref === nothing ? nothing : urlunquote(ref)       # (the Referer may be encoded)
        ok(nxt) || (nxt = "/")
    end
    resp = nxt === nothing ? HttpResponse(""; status = 204) : HttpResponseRedirect(nxt)
    if req.method == "POST"
        lang = supported_language(get(req.POST, "language", ""))
        if lang !== nothing
            if nxt !== nothing
                t = translate_url(nxt, lang)                      # (translated routes too, as Django's)
                t == nxt && (t = swap_language_prefix(nxt, lang))
                t == nxt || (resp = HttpResponseRedirect(t))
            end
            st = settings
            set_cookie!(resp, st.LANGUAGE_COOKIE_NAME, lang; max_age = get(st, :LANGUAGE_COOKIE_AGE, nothing),
                        path = get(st, :LANGUAGE_COOKIE_PATH, "/"), domain = get(st, :LANGUAGE_COOKIE_DOMAIN, nothing),
                        secure = get(st, :LANGUAGE_COOKIE_SECURE, false), httponly = get(st, :LANGUAGE_COOKIE_HTTPONLY, false),
                        samesite = get(st, :LANGUAGE_COOKIE_SAMESITE, nothing))
        end
    end
    resp
end
function swap_language_prefix(path, lang)
    m = match(r"^/([a-z]{2}(?:-[a-z0-9]+)?)(/.*)$"i, path)
    (m !== nothing && lowercase(m[1]) in supported_codes()) ? "/" * lang * m[2] : path
end
"URL patterns for the language switcher: `path(\"i18n/\", i18n_urls())` gives `setlang/` (name `set_language`)."
i18n_urls() = include_urls([path("setlang/", set_language; name = "set_language")])

# --- template tags ------------------------------------------------------------------------------------------------

"`{% translate \"text\" [context \"ctx\"] [noop] [as var] %}` (also `{% trans %}`)."
struct TranslateNode <: Node
    value::Any               # FilterExpr
    context::Union{Nothing,String}
    noop::Bool
    asvar::Union{Nothing,String}
end
function tag_translate(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) >= 2 || tsyntax(p, "'$(bits[1])' needs a string to translate")
    ctx, noop, asvar = nothing, false, nothing
    i = 3
    while i <= length(bits)
        b = bits[i]
        if b == "noop"; noop = true
        elseif b == "context" && i < length(bits); ctx = strip(bits[i+1], ['"', '\'']); i += 1
        elseif b == "as" && i < length(bits); asvar = bits[i+1]; i += 1
        else tsyntax(p, "unknown argument '$b' to $(bits[1])")
        end
        i += 1
    end
    TranslateNode(parse_filter_expr(bits[2]), ctx, noop, asvar)
end
function render!(io::IO, n::TranslateNode, ctx::Context)
    v = eval_fe(n.value, ctx)
    s = n.noop ? display_string(v) : translate(something(n.context, ""), display_string(v))
    if n.asvar !== nothing
        ctx.stack[end][n.asvar] = s
        return
    end
    write(io, ctx.autoescape ? conditional_escape(s) : s)
end

"""
`{% blocktranslate [count n=expr] [with a=b ...] [context "c"] [trimmed] [asvar x] %}...{% plural %}...{% endblocktranslate %}`
Variables inside are written `{{ name }}` (plain names only).
"""
struct BlockTranslateNode <: Node
    singular::String
    plural::Union{Nothing,String}
    names::Vector{String}
    counter::Union{Nothing,Tuple{String,Any}}
    extra::Vector{Tuple{String,Any}}
    context::Union{Nothing,String}
    asvar::Union{Nothing,String}
end

"Build the msgid (`%(name)s` placeholders) of a blocktranslate body from template tokens."
function blocktrans_msgid(tokens, trimmed)
    io, names = IOBuffer(), String[]
    for tk in tokens
        if tk.kind === :text
            print(io, replace(tk.contents, "%" => "%%"))
        elseif tk.kind === :var
            name = strip(tk.contents)
            occursin(r"^[\w.]+$", name) || throw(TemplateSyntaxError("blocktranslate only allows plain variables, not '{{ $name }}'"))
            push!(names, name)
            print(io, "%(", name, ")s")
        end
    end
    s = String(take!(io))
    trimmed && (s = strip(replace(s, r"\s*\n\s*" => " ")))
    s, names
end

function tag_blocktranslate(p::Parser, t::Token)
    bits = split_contents(t.contents)
    counter, extra, ctxname, asvar, trimmed = nothing, Tuple{String,Any}[], nothing, nothing, false
    i = 2
    while i <= length(bits)
        b = bits[i]
        if b == "count"
            k, v = split(bits[i+1], '='; limit = 2); counter = (String(k), parse_filter_expr(v)); i += 1
        elseif b == "with"
            while i + 1 <= length(bits) && occursin('=', bits[i+1])
                k, v = split(bits[i+1], '='; limit = 2); push!(extra, (String(k), parse_filter_expr(v))); i += 1
            end
        elseif b == "context"; ctxname = strip(bits[i+1], ['"', '\'']); i += 1
        elseif b == "asvar"; asvar = bits[i+1]; i += 1
        elseif b == "trimmed"; trimmed = true
        elseif occursin('=', b)
            k, v = split(b, '='; limit = 2); push!(extra, (String(k), parse_filter_expr(v)))
        else tsyntax(p, "unknown argument '$b' to blocktranslate")
        end
        i += 1
    end
    endname = "end" * bits[1]
    singular, plural = Token[], nothing
    while true
        p.pos > length(p.tokens) && tsyntax(p, "unclosed $(bits[1])")
        tk = p.tokens[p.pos]; p.pos += 1
        if tk.kind === :block
            c = strip(tk.contents)
            c == endname && break
            if c == "plural"
                counter === nothing && tsyntax(p, "{% plural %} needs 'count' in blocktranslate")
                plural = Token[]
                continue
            end
            tsyntax(p, "no block tags allowed inside blocktranslate ({% $c %})")
        end
        push!(plural === nothing ? singular : plural, tk)
    end
    s, names = blocktrans_msgid(singular, trimmed)
    pl = plural === nothing ? nothing : first(blocktrans_msgid(plural, trimmed))
    plural === nothing || append!(names, last(blocktrans_msgid(plural, trimmed)))
    BlockTranslateNode(s, pl, unique(names), counter, extra, ctxname, asvar)
end

function render!(io::IO, n::BlockTranslateNode, ctx::Context)
    vars = Dict{String,Any}()
    for (k, fe) in n.extra
        vars[k] = eval_fe(fe, ctx)
    end
    count = 1
    if n.counter !== nothing
        count = eval_fe(n.counter[2], ctx)
        count = count isa Integer ? count : something(tryparse(Int, string(count)), 0)
        vars[n.counter[1]] = count
    end
    s = n.plural === nothing ? translate(something(n.context, ""), n.singular) :
                               translate(something(n.context, ""), n.singular, n.plural, count)
    out = with_scope(() -> begin
            vals = Dict{String,String}()
            for name in n.names
                v = haskey(vars, name) ? vars[name] : eval_fe(parse_filter_expr(name), ctx)
                vals[name] = ctx.autoescape ? conditional_escape(v) : display_string(v)
            end
            replace(replace(s, r"%\(([\w.]+)\)s" => m -> vals[match(r"%\(([\w.]+)\)s", m)[1]]), "%%" => "%")
        end, ctx, vars)
    n.asvar === nothing ? write(io, out) : (ctx.stack[end][n.asvar] = SafeString(out); nothing)
end

"`{% get_current_language as LANGUAGE_CODE %}`, `{% get_available_languages as LANGUAGES %}`, `{% get_current_language_bidi as bidi %}`."
struct LanguageInfoNode <: Node
    what::Symbol
    var::String
end
function tag_language_info(p::Parser, t::Token)
    bits = split_contents(t.contents)
    (length(bits) == 3 && bits[2] == "as") || tsyntax(p, "use {% $(bits[1]) as variable %}")
    LanguageInfoNode(Symbol(bits[1]), bits[3])
end
render!(io::IO, n::LanguageInfoNode, ctx::Context) = (ctx.stack[end][n.var] =
    n.what === :get_current_language ? get_language() :
    n.what === :get_current_language_bidi ? get_language_bidi() :
    [Any[first(l), last(l)] for l in settings.LANGUAGES]; nothing)

# --- language info (Django's LANG_INFO) -----------------------------------------------------------------------

const LANG_INFO = Dict(
    "ar" => ("Arabic", "العربيّة", true), "bg" => ("Bulgarian", "български", false), "ca" => ("Catalan", "català", false),
    "cs" => ("Czech", "česky", false), "da" => ("Danish", "dansk", false), "de" => ("German", "Deutsch", false),
    "el" => ("Greek", "Ελληνικά", false), "en" => ("English", "English", false), "en-gb" => ("British English", "British English", false),
    "es" => ("Spanish", "español", false), "et" => ("Estonian", "eesti", false), "fa" => ("Persian", "فارسی", true),
    "fi" => ("Finnish", "suomi", false), "fr" => ("French", "français", false), "he" => ("Hebrew", "עברית", true),
    "hi" => ("Hindi", "हिंदी", false), "hr" => ("Croatian", "Hrvatski", false), "hu" => ("Hungarian", "Magyar", false),
    "id" => ("Indonesian", "Bahasa Indonesia", false), "it" => ("Italian", "italiano", false), "ja" => ("Japanese", "日本語", false),
    "ko" => ("Korean", "한국어", false), "lt" => ("Lithuanian", "Lietuviškai", false), "lv" => ("Latvian", "latviešu", false),
    "mi" => ("Māori", "Te Reo Māori", false), "nb" => ("Norwegian Bokmål", "norsk (bokmål)", false), "nl" => ("Dutch", "Nederlands", false),
    "pl" => ("Polish", "polski", false), "pt" => ("Portuguese", "Português", false), "pt-br" => ("Brazilian Portuguese", "Português Brasileiro", false),
    "ro" => ("Romanian", "Română", false), "ru" => ("Russian", "Русский", false), "sk" => ("Slovak", "Slovensky", false),
    "sl" => ("Slovenian", "Slovenščina", false), "sr" => ("Serbian", "српски", false), "sv" => ("Swedish", "svenska", false),
    "th" => ("Thai", "ภาษาไทย", false), "tr" => ("Turkish", "Türkçe", false), "uk" => ("Ukrainian", "Українська", false),
    "ur" => ("Urdu", "اردو", true), "vi" => ("Vietnamese", "Tiếng Việt", false),
    "zh-hans" => ("Simplified Chinese", "简体中文", false), "zh-hant" => ("Traditional Chinese", "繁體中文", false),
)

"""
    get_language_info(code) -> NamedTuple

Django's: `(code, name, name_local, name_translated, bidi)` for a language code (`"pt-br"`,
`"de"`), falling back from a regional code to its base language. `name_translated` is the name in
the active language when a translation has it. Unknown codes throw `KeyError`.
"""
function get_language_info(code::AbstractString)
    c = lowercase(replace(string(code), '_' => '-'))
    k = haskey(LANG_INFO, c) ? c : (b = split(c, '-')[1]; haskey(LANG_INFO, b) ? b : throw(KeyError(code)))
    name, local_name, bidi = LANG_INFO[k]
    (code = k, name = name, name_local = local_name, name_translated = gettext(name), bidi = bidi)
end

"`{% get_language_info for \"de\" as lang %}` (lang.name_local, lang.bidi ...) and `{% get_language_info_list for LANGUAGES as langs %}`."
struct LanguageInfoForNode <: Node
    list::Bool
    code::Any
    var::String
end
function tag_language_info_for(p::Parser, t::Token)
    bits = split_contents(t.contents)
    (length(bits) == 5 && bits[2] == "for" && bits[4] == "as") || tsyntax(p, "use {% $(bits[1]) for code as variable %}")
    LanguageInfoForNode(bits[1] == "get_language_info_list", parse_filter_expr(bits[3]), bits[5])
end
function render!(io::IO, n::LanguageInfoForNode, ctx::Context)
    v = eval_fe(n.code, ctx)
    info(x) = get_language_info(string(x isa Union{AbstractVector,Tuple,Pair} ? first(x) : x))
    ctx.stack[end][n.var] = n.list ? [info(x) for x in to_iterable(v)] : info(v)
    nothing
end

"`{% language \"de\" %}...{% endlanguage %}`: render a part in another language."
struct LanguageNode <: Node
    lang::Any
    nodes::Vector{Node}
end
child_nodelists(n::LanguageNode) = (n.nodes,)
tag_language(p::Parser, t::Token) = LanguageNode(parse_filter_expr(split_contents(t.contents)[2]), first(parse_nodes(p, ["endlanguage"])))
render!(io::IO, n::LanguageNode, ctx::Context) = write(io, with_language(() -> render_nodes(n.nodes, ctx), string(eval_fe(n.lang, ctx))))

for (name, f) in ("translate" => tag_translate, "trans" => tag_translate, "blocktranslate" => tag_blocktranslate,
                  "blocktrans" => tag_blocktranslate, "get_current_language" => tag_language_info,
                  "get_available_languages" => tag_language_info, "get_current_language_bidi" => tag_language_info,
                  "language" => tag_language, "get_language_info" => tag_language_info_for,
                  "get_language_info_list" => tag_language_info_for)
    register_tag!(name, f)
end
# Library filters ({% load l10n %}, {% load i18n %}); the i18n tags are always available
const L10N_LIBRARY = filter!(TagLibrary("l10n"), "localize", (v, _) -> localize(v))
# unlocalize: a number as plain text whatever the language (Django's)
filter!(L10N_LIBRARY, "unlocalize", (v, _) -> v isa Real && !(v isa Bool) ? (v isa AbstractFloat ? string(v) : string(v)) : v)

"`{% localize on %}...{% endlocalize %}` (or `off`): whether `{{ value }}` shows numbers and dates in the language's format."
struct LocalizeNode <: Node
    on::Bool
    nodes::Vector{Node}
end
child_nodelists(n::LocalizeNode) = (n.nodes,)
function tag_localize(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) <= 2 || throw(TemplateSyntaxError("localize tag accepts at most one argument (on or off)"))
    length(bits) == 2 && !(bits[2] in ("on", "off")) && throw(TemplateSyntaxError("localize argument should be 'on' or 'off'"))
    LocalizeNode(length(bits) == 1 || bits[2] == "on", first(parse_nodes(p, ["endlocalize"])))
end
function render!(io::IO, n::LocalizeNode, ctx::Context)
    old = get(task_local_storage(), :juango_localize, nothing)
    task_local_storage(:juango_localize, n.on)
    try
        render_nodes(io, n.nodes, ctx)
    finally
        old === nothing ? delete!(task_local_storage(), :juango_localize) : task_local_storage(:juango_localize, old)
    end
end
tag!(L10N_LIBRARY, "localize", tag_localize)
const I18N_LIBRARY = filter!(TagLibrary("i18n"), "language_name", (v, _) -> language_name(string(v)))
filter!(I18N_LIBRARY, "language_name_local", (v, _) -> get_language_info(string(v)).name_local)
filter!(I18N_LIBRARY, "language_name_translated", (v, _) -> get_language_info(string(v)).name_translated)
filter!(I18N_LIBRARY, "language_bidi", (v, _) -> get_language_info(string(v)).bidi)

# --- makemessages / compilemessages ---------------------------------------------------------------------------------

const JL_STR = "\"((?:[^\"\\\\]|\\\\.)*)\""
jl_unescape(s) = po_unescape(s)

"The `#:` reference for a message at `line` of `file`, as `add_location` asks (\"full\", \"file\" or \"never\")."
po_location(file, line, location) = location == "never" ? String[] : String["#: $file" * (location == "full" ? ":$line" : "")]

"""
Messages in Julia source: gettext("..") (and gettext_lazy, gettext_noop), ngettext, pgettext, npgettext (and
their _lazy forms) and t"..". A comment block starting with `# Translators:` right above the call becomes
the message's `#.` comment, as xgettext's.
"""
function extract_julia(src::AbstractString, file; location = "full")
    out = Tuple{Int,POEntry}[]
    lines = split(src, '\n')
    iscomment = [startswith(lstrip(l), "#") for l in lines]
    code = join([c ? "" : l for (l, c) in zip(lines, iscomment)], '\n')     # (comments blanked; line numbers kept)
    nls = findall(==('\n'), code)
    function translators(line)
        i = line - 1
        while i >= 1 && iscomment[i]; i -= 1; end
        block = [strip(lstrip(lstrip(lines[j]), '#')) for j in i+1:line-1]
        k = findfirst(l -> startswith(l, "Translators"), block)
        k === nothing ? String[] : String["#. " * l for l in block[k:end]]
    end
    function add(off, ctx, id, pl = "")
        line = searchsortedfirst(nls, off)
        e = POEntry(); e.context = ctx; e.msgid = id; e.msgid_plural = pl
        e.msgstr = isempty(pl) ? [""] : ["", ""]
        e.comments = vcat(translators(line), po_location(file, line, location))
        push!(out, (off, e))
    end
    u = jl_unescape
    for m in eachmatch(Regex("\\b(?:gettext|gettext_lazy|gettext_noop)\\(\\s*" * JL_STR), code); add(m.offset, "", u(m[1])); end
    for m in eachmatch(Regex("(?<![\\w\$\"\\\\])t" * JL_STR), code); add(m.offset, "", u(m[1])); end
    for m in eachmatch(Regex("\\b(?:pgettext|pgettext_lazy)\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), code); add(m.offset, u(m[1]), u(m[2])); end
    for m in eachmatch(Regex("\\b(?:ngettext|ngettext_lazy)\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), code); add(m.offset, "", u(m[1]), u(m[2])); end
    for m in eachmatch(Regex("\\b(?:npgettext|npgettext_lazy)\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), code)
        add(m.offset, u(m[1]), u(m[2]), u(m[3]))
    end
    POEntry[e for (_, e) in sort(out; by = first)]
end

const TEMPLATE_LITERAL_RE = r"\b_\(\s*(?:\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)')\s*\)"
template_literal(s) = (m = match(r"^(?:\"((?:[^\"\\]|\\.)*)\"|'((?:[^'\\]|\\.)*)')", s); m === nothing ? nothing : something(m[1], m[2]))

"""
Messages in a template: {% translate %} (also with `noop`) and {% blocktranslate %} blocks, and `_("..")`
literals. A `{# Translators: .. #}` comment (the last item on its line) or a `{% comment %}Translators: ..`
block right before a message becomes its `#.` comment, as Django's.
"""
function extract_template(src::AbstractString, file; location = "full")
    out = POEntry[]
    toks = tokenize(src)
    pending = String[]
    function add(tk, ctx, id, pl = "")
        e = POEntry(); e.context = ctx; e.msgid = id; e.msgid_plural = pl; e.msgstr = isempty(pl) ? [""] : ["", ""]
        e.comments = vcat(pending, po_location(file, tk.line, location))
        empty!(pending)
        push!(out, e)
    end
    note(text) = (empty!(pending); append!(pending, ["#. " * strip(l) for l in split(strip(text), '\n')]))
    context_of(bits) = (j = findfirst(==("context"), bits); j === nothing || j == length(bits) ? "" : something(template_literal(bits[j+1]), ""))
    i = 1
    while i <= length(toks)
        tk = toks[i]
        i += 1
        if tk.kind === :text
            isempty(strip(tk.contents)) || empty!(pending)
            continue
        elseif tk.kind === :comment
            startswith(strip(tk.contents), "Translators") || continue
            nxt = i <= length(toks) ? toks[i] : nothing
            last_on_line = nxt === nothing || (nxt.kind === :text && occursin('\n', nxt.contents) && isempty(strip(first(split(nxt.contents, '\n')))))
            if last_on_line
                note(tk.contents)
            else
                @warn "The translator-targeted comment '$(strip(tk.contents))' (file $file, line $(tk.line)) was ignored, because it wasn't the last item on the line."
            end
            continue
        elseif tk.kind === :var
            for m in eachmatch(TEMPLATE_LITERAL_RE, tk.contents); add(tk, "", something(m[1], m[2])); end
            continue
        end
        bits = split_contents(tk.contents)
        isempty(bits) && continue
        if bits[1] == "comment"
            body = IOBuffer()
            while i <= length(toks) && !(toks[i].kind === :block && strip(toks[i].contents) == "endcomment")
                toks[i].kind === :text && print(body, toks[i].contents)
                i += 1
            end
            i += 1
            text = String(take!(body))
            startswith(lstrip(text), "Translators") ? note(text) : empty!(pending)
        elseif bits[1] in ("translate", "trans") && length(bits) >= 2 && template_literal(bits[2]) !== nothing
            add(tk, context_of(bits), template_literal(bits[2]))
        elseif bits[1] in ("blocktranslate", "blocktrans")
            singular, plural = Token[], nothing
            while i <= length(toks)
                t2 = toks[i]; i += 1
                if t2.kind === :block
                    c2 = strip(t2.contents)
                    c2 == "end" * bits[1] && break
                    c2 == "plural" && (plural = Token[]; continue)
                    throw(TemplateSyntaxError("Translation blocks must not include other block tags: $c2 (file $file, line $(t2.line))"))
                end
                push!(plural === nothing ? singular : plural, t2)
            end
            trimmed = "trimmed" in bits
            add(tk, context_of(bits), first(blocktrans_msgid(singular, trimmed)),
                plural === nothing ? "" : first(blocktrans_msgid(plural, trimmed)))
        else
            found = false
            for m in eachmatch(TEMPLATE_LITERAL_RE, tk.contents); add(tk, "", something(m[1], m[2])); found = true; end
            found || empty!(pending)
        end
    end
    out
end

# The plural rule a new catalogue gets when Juango has none of its own for the language (gettext's).
const PLURAL_FORMS = let ru = "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
                         one = "nplurals=1; plural=0;", gt1 = "nplurals=2; plural=(n > 1);", cs = "nplurals=3; plural=(n==1) ? 0 : (n>=2 && n<=4) ? 1 : 2;"
    Dict("ja" => one, "zh" => one, "ko" => one, "vi" => one, "th" => one, "id" => one, "ms" => one,
         "fr" => gt1, "pt_BR" => gt1, "tr" => gt1, "oc" => gt1,
         "ru" => ru, "uk" => ru, "be" => ru, "sr" => ru, "hr" => ru, "bs" => ru, "cs" => cs, "sk" => cs,
         "pl" => "nplurals=3; plural=(n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2);",
         "lt" => "nplurals=3; plural=(n%10==1 && n%100!=11 ? 0 : n%10>=2 && (n%100<10 || n%100>=20) ? 1 : 2);",
         "ro" => "nplurals=3; plural=(n==1 ? 0 : (n==0 || (n%100 > 0 && n%100 < 20)) ? 1 : 2);",
         "sl" => "nplurals=4; plural=(n%100==1 ? 0 : n%100==2 ? 1 : n%100==3 || n%100==4 ? 2 : 3);",
         "ar" => "nplurals=6; plural=(n==0 ? 0 : n==1 ? 1 : n==2 ? 2 : n%100>=3 && n%100<=10 ? 3 : n%100>=11 ? 4 : 5);")
end

"The Plural-Forms header line for a locale: Juango's own catalogue's (as Django copies its own), else gettext's rule."
function plural_forms(loc)
    for name in unique([loc, split(loc, '_')[1]])
        entries = load_catalog_file(BUILTIN_LOCALE_DIR, name)
        entries === nothing && continue
        m = match(r"Plural-Forms:[^\n]*", header_of(entries))
        m === nothing || return String(m.match)
    end
    "Plural-Forms: " * get(PLURAL_FORMS, loc, get(PLURAL_FORMS, split(loc, '_')[1], "nplurals=2; plural=(n != 1);"))
end

po_header(loc) = """Project-Id-Version: PACKAGE VERSION
Language: $loc
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit
$(plural_forms(loc))"""

"Shell-style pattern match (`*`, `?`, `[..]`), as Python's fnmatch."
function fnmatch(pat::AbstractString, name::AbstractString)
    rx = replace(pat, r"[.+^$(){}|\\]" => s"\\\0")
    rx = replace(rx, "*" => ".*", "?" => ".")
    occursin(Regex("^" * rx * "\$"), name)
end
const MAKEMESSAGES_DEFAULT_IGNORE = ["CVS", ".*", "*~"]
"Whether a path (relative to the root) is ignored: a pattern matching a name in it, or the whole path."
path_ignored(rel, patterns) = any(p -> fnmatch(p, rel) || any(part -> fnmatch(p, part), splitpath(rel)), patterns)

"The catalogues' obsolete (`#~`) entries."
parse_po_obsolete(text) = parse_po(join([startswith(l, "#~") ? replace(l, r"^#~\s?" => "") : "" for l in split(text, '\n')], '\n'))

"""
    makemessages(lang; root=pwd(), locale_dir=first(LOCALE_PATHS) or root/locale, ...) -> path
    makemessages(langs::Vector; ...) / makemessages(; all = true, ...) -> paths

Collect translatable strings from `.jl` files and templates under `root` into
`locale_dir/<locale>/LC_MESSAGES/juango.po`, keeping existing translations, as Django's makemessages:

- `all`: every locale already in `locale_dir` (`exclude` leaves some out);
- `extensions`: the template extensions (default `.html` and `.txt`; `.jl` files are always read);
- `ignore`: shell patterns of files and directories to skip (with `.*`, `*~` and `CVS`, unless `no_default_ignore`);
- `add_location`: `"full"` (`#: file:line`, the default), `"file"` or `"never"` (also `no_location = true`);
- translations of strings no longer found are kept as obsolete `#~` entries, unless `no_obsolete`.
"""
function makemessages(lang = nothing; root = pwd(), locale_dir = isempty(settings.LOCALE_PATHS) ? joinpath(root, "locale") : string(first(settings.LOCALE_PATHS)),
                      all = false, exclude = String[], extensions = nothing, ignore = String[], no_default_ignore = false,
                      add_location = "full", no_location = false, no_obsolete = false)
    langs = lang isa AbstractString ? [String(lang)] : lang === nothing ? String[] : String.(collect(lang))
    if all
        isdir(locale_dir) && append!(langs, sort([d for d in readdir(locale_dir) if isdir(joinpath(locale_dir, d, "LC_MESSAGES"))]))
    end
    excluded = Set(to_locale.(exclude))
    langs = unique(filter(l -> !(to_locale(l) in excluded), langs))
    isempty(langs) && !all && isempty(exclude) && throw(ArgumentError("makemessages needs a locale (-l <locale>) or all = true (-a)"))
    location = no_location ? "never" : string(add_location)
    location in ("full", "file", "never") || throw(ArgumentError("add_location must be \"full\", \"file\" or \"never\""))
    exts = extensions === nothing ? [".html", ".txt"] :
           [startswith(e, ".") ? e : "." * e for x in extensions for e in strip.(split(x, ',')) if !isempty(e)]
    patterns = vcat(String.(ignore), no_default_ignore ? String[] : MAKEMESSAGES_DEFAULT_IGNORE)
    found = POEntry[]
    locale_prefix = rstrip(abspath(locale_dir), '/') * "/"
    for (dir, _, files) in walkdir(root)
        for f in sort(files)
            p = joinpath(dir, f)
            rel = relpath(p, root)
            (path_ignored(rel, patterns) || startswith(abspath(p), locale_prefix) || first(splitpath(rel)) == "locale") && continue
            isjl = endswith(f, ".jl")
            (isjl || any(e -> endswith(f, e), exts)) || continue
            src = read(p, String)
            if !isvalid(src)
                @warn "UnicodeDecodeError: skipped file $f in $(relpath(dir, root)) (reason: not valid UTF-8)"
                continue
            end
            append!(found, isjl ? extract_julia(src, rel; location) : extract_template(src, rel; location))
        end
    end
    merged = Dict{Tuple{String,String},POEntry}()
    order = Tuple{String,String}[]
    for e in found
        k = (e.context, e.msgid)
        if haskey(merged, k)
            old = merged[k]
            for c in e.comments; c in old.comments || push!(old.comments, c); end
            isempty(old.msgid_plural) && !isempty(e.msgid_plural) && (old.msgid_plural = e.msgid_plural; old.msgstr = e.msgstr)
        else
            merged[k] = e; push!(order, k)
        end
    end
    for k in order                                              # (#. comments before the #: references, as xgettext)
        c = merged[k].comments
        merged[k].comments = vcat(filter(x -> startswith(x, "#."), c), filter(x -> !startswith(x, "#."), c))
    end
    paths = String[]
    for l in langs
        loc = to_locale(l)
        path = joinpath(locale_dir, loc, "LC_MESSAGES", "juango.po")
        header = po_header(loc)
        oldmap, obsolete = Dict{Tuple{String,String},POEntry}(), POEntry[]
        if isfile(path)
            text = read(path, String)
            old = parse_po(text)
            isempty(header_of(old)) || (header = header_of(old))
            for e in vcat(parse_po_obsolete(text), old)        # (an active entry wins over an obsolete one)
                isempty(e.msgid) || (oldmap[(e.context, e.msgid)] = e)
            end
        end
        np = plural_count(header)
        entries = POEntry[]
        for k in order
            src = merged[k]
            e = POEntry(src.context, src.msgid, src.msgid_plural, isempty(src.msgid_plural) ? [""] : fill("", np), false, copy(src.comments))
            o = get(oldmap, k, nothing)
            if o !== nothing && isempty(o.msgid_plural) == isempty(e.msgid_plural)
                e.msgstr = copy(o.msgstr); e.fuzzy = o.fuzzy
            end
            push!(entries, e)
        end
        if !no_obsolete
            seen = Set(order)
            for (k, o) in sort(collect(oldmap); by = x -> x[1])
                (k in seen || Base.all(isempty, o.msgstr)) && continue
                push!(obsolete, POEntry(o.context, o.msgid, o.msgid_plural, o.msgstr, o.fuzzy, String[]))
            end
        end
        mkpath(dirname(path))
        open(path, "w") do io
            write_po(io, entries; header = header)
            if !isempty(obsolete)
                buf = IOBuffer()
                write_po(buf, obsolete)
                for line in split(String(take!(buf)), '\n')
                    println(io, isempty(line) ? "" : "#~ " * line)
                end
            end
        end
        push!(paths, path)
    end
    lang isa AbstractString ? only(paths) : paths
end

"Lines of a .po file that aren't a comment, a keyword or a string continuation: (line number, text)."
function po_syntax_errors(text)
    errs = Tuple{Int,String}[]
    for (n, raw) in enumerate(split(text, '\n'))
        l = strip(raw)
        (isempty(l) || startswith(l, "#") || occursin(r"^(msgctxt|msgid_plural|msgid|msgstr(\[\d+\])?)\s+\".*\"$", l) ||
         occursin(r"^\".*\"$", l)) && continue
        push!(errs, (n, String(l)))
    end
    errs
end

"""
    compilemessages(dirs = LOCALE_PATHS + ./locale; locale = nothing, exclude = [], use_fuzzy = false, ignore = []) -> mo files written

Compile every juango.po under `dirs` into juango.mo, as Django's compilemessages: only the given
locales (`locale`, minus `exclude`), skipping `ignore` patterns and catalogues whose .mo is newer.
Fuzzy translations are left out unless `use_fuzzy`. A .po with a BOM or a syntax error is reported
and the others are compiled; then a CommandError is thrown.
"""
function compilemessages(dirs = vcat(String[string(p) for p in settings.LOCALE_PATHS], [joinpath(pwd(), "locale")]);
                         locale = nothing, exclude = String[], use_fuzzy = false, ignore = String[], verbose = false)
    written, errors = String[], String[]
    wanted = locale === nothing ? nothing : Set(to_locale.(locale isa AbstractString ? [locale] : locale))
    excluded = Set(to_locale.(exclude))
    for d in unique(dirs)
        isdir(d) || continue
        for (dir, _, files) in walkdir(d), f in files
            f == "juango.po" || continue
            loc = basename(dirname(dir))
            (wanted !== nothing && !(loc in wanted)) && continue
            (loc in excluded || path_ignored(relpath(joinpath(dir, f), d), ignore)) && continue
            po, mo = joinpath(dir, f), joinpath(dir, "juango.mo")
            if isfile(mo) && mtime(mo) >= mtime(po)
                verbose && println("File “$(po)” is already compiled and up to date.")
                continue
            end
            bytes = read(po)
            if length(bytes) >= 3 && bytes[1:3] == [0xef, 0xbb, 0xbf]
                push!(errors, "The $(po) file has a BOM (Byte Order Mark). Juango only supports .po files encoded in UTF-8 and without any BOM.")
                continue
            end
            text = String(bytes)
            bad = po_syntax_errors(text)
            if !isempty(bad)
                append!(errors, ["$po:$n: syntax error: $l" for (n, l) in bad])
                continue
            end
            entries = parse_po(text)
            use_fuzzy && foreach(e -> e.fuzzy = false, entries)
            try
                write(mo, write_mo(entries))
            catch e
                e isa SystemError || e isa Base.IOError || rethrow()
                push!(errors, "The po files under $dir are in a seemingly not writable location. mo files will not be updated/created.")
                continue
            end
            push!(written, mo)
        end
    end
    reload_translations!()
    isempty(errors) || throw(CommandError(join(errors, "\n") * "\ncompilemessages generated one or more errors."))
    written
end
