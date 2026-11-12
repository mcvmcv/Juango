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
end
Catalog(msgs, plural) = Catalog(msgs, plural, "n != 1")
Catalog() = Catalog(Dict{Tuple{String,String},Vector{String}}(), n -> n == 1 ? 0 : 1)
plural_expr(header) = (m = match(r"plural\s*=\s*([^;]+)", header); m === nothing ? "n != 1" : strip(m[1]))

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
    Catalog(msgs, plural_rule(header_of(entries)), plural_expr(header_of(entries)))
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

"`\"pt-br\"` -> `\"pt_BR\"` (the locale name used for directories)."
function to_locale(lang)
    parts = split(lowercase(string(lang)), r"[-_]")
    length(parts) == 1 ? parts[1] : parts[1] * "_" * (length(parts[2]) > 2 ? titlecase(parts[2]) : uppercase(parts[2]))
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
            rule, expr = nothing, "n != 1"
            for dir in reverse(locale_dirs()), name in reverse(names)      # later (higher priority) entries overwrite
                entries = load_catalog_file(dir, name)
                entries === nothing && continue
                c = catalog_from_entries(entries)
                merge!(msgs, c.messages)
                isempty(header_of(entries)) || (rule = c.plural; expr = c.plural_expr)
            end
            Catalog(msgs, something(rule, n -> n == 1 ? 0 : 1), expr)
        end
    end
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
"Whether the language reads right to left."
get_language_bidi(lang = get_language()) = split(lowercase(lang), '-')[1] in ("ar", "fa", "he", "ur")

# --- translating -------------------------------------------------------------------------------------------------

function translate(context, msgid, plural = nothing, n = 1)
    settings.USE_I18N || return plural === nothing || n == 1 ? msgid : plural
    c = catalog(get_language())
    forms = get(c.messages, (context, msgid), nothing)
    if forms === nothing
        return plural === nothing || n == 1 ? msgid : plural
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
)
"Number and date formats of the active language (falling back to English)."
get_format(lang = get_language()) = get(FORMATS, split(lowercase(lang), r"[-_]")[1], FORMATS["en"])

"""
    number_format(x; decimals=nothing, lang=get_language(), grouping=settings.USE_THOUSAND_SEPARATOR)

A number with the language's decimal separator (and thousands separators when `grouping`).
"""
function number_format(x::Real; decimals = nothing, lang = get_language(), grouping = settings.USE_THOUSAND_SEPARATOR)
    f = get_format(lang)
    s = if x isa Decimal
        string(decimals === nothing ? x : round(x, RoundNearestTiesAway; digits = decimals))
    else
        decimals === nothing ? (x isa Integer ? string(x) : string(Float64(x))) : Printf.format(Printf.Format("%.$(decimals)f"), x)
    end
    neg = startswith(s, "-")
    neg && (s = s[2:end])
    ip, fp = occursin('.', s) ? split(s, '.'; limit = 2) : (s, "")
    if grouping
        ip = reverse(join([reverse(ip)[i:min(end, i + 2)] for i in 1:3:length(ip)], reverse(f.thousand)))
    end
    (neg ? "-" : "") * ip * (isempty(fp) ? "" : f.decimal * fp)
end

"Format a number or date for the active language (the `localize` template filter)."
localize(x::Real) = x isa Bool ? string(x) : number_format(x)
localize(x::Union{Date,DateTime}) = format_date(x, x isa Date ? get_format().date : get_format().datetime)
localize(x) = x

"Parse a number typed in the active language's format (`\"1.234,5\"` in German)."
function parse_localized_number(s::AbstractString)
    f = get_format()
    t = replace(strip(s), f.thousand => "")
    f.decimal == "." || (t = replace(t, f.decimal => "."))
    t
end

# --- choosing the language for a request ------------------------------------------------------------------------------

supported_codes() = [lowercase(string(first(l))) for l in settings.LANGUAGES]

"Pick a supported language for `code` (exact, then without the region, then any with the same base)."
function supported_language(code)
    c = lowercase(string(code))
    codes = supported_codes()
    c in codes && return c
    base = split(c, '-')[1]
    base in codes && return base
    i = findfirst(x -> split(x, '-')[1] == base, codes)
    i === nothing ? nothing : codes[i]
end

"Languages from an Accept-Language header, best first."
function parse_accept_language(h)
    out = Tuple{String,Float64}[]
    for part in split(h, ',')
        bits = split(strip(part), ';')
        code = strip(bits[1])
        (isempty(code) || code == "*") && continue
        q = 1.0
        for b in bits[2:end]
            m = match(r"q\s*=\s*([0-9.]+)", b)
            m === nothing || (q = something(tryparse(Float64, m[1]), 0.0))
        end
        push!(out, (code, q))
    end
    [c for (c, _) in sort(out; by = x -> -x[2])]
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
        if resp.status == 404 && get(req.meta, :language_prefix, nothing) === nothing && uses_i18n_patterns()
            target = "/" * lang * req.path
            resolve(target) === nothing || return HttpResponseRedirect(target * (isempty(req.query_string) ? "" : "?" * req.query_string))
        end
        hasheader(resp, "Content-Language") || setheader!(resp, "Content-Language", lang)
        patch_vary!(resp, "Accept-Language")
        resp
    end
end

"""
`set_language` view: POST `language` (and `next`) to choose a language; it is remembered in
a cookie and the user goes back to `next`, with its language prefix swapped.
"""
function set_language(req)
    nxt = safe_next(req, "/")
    lang = supported_language(get(req.POST, "language", get(req.GET, "language", "")))
    resp = HttpResponseRedirect(lang === nothing ? nxt : swap_language_prefix(nxt, lang))
    lang === nothing || set_cookie!(resp, settings.LANGUAGE_COOKIE_NAME, lang; max_age = 365 * 24 * 3600)
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
                  "language" => tag_language)
    register_tag!(name, f)
end
# Library filters ({% load l10n %}, {% load i18n %}); the i18n tags are always available
const L10N_LIBRARY = filter!(TagLibrary("l10n"), "localize", (v, _) -> localize(v))
const I18N_LIBRARY = filter!(TagLibrary("i18n"), "language_name", (v, _) -> language_name(string(v)))

# --- makemessages / compilemessages ---------------------------------------------------------------------------------

const JL_STR = "\"((?:[^\"\\\\]|\\\\.)*)\""
jl_unescape(s) = po_unescape(s)

"Messages in Julia source: gettext(\"..\"), gettext_lazy, ngettext, pgettext, npgettext and t\"..\"."
function extract_julia(src::AbstractString, file)
    out = POEntry[]
    add(ctx, id, pl = "") = (e = POEntry(); e.context = ctx; e.msgid = id; e.msgid_plural = pl;
                             e.msgstr = isempty(pl) ? [""] : ["", ""]; e.comments = ["#: $file"]; push!(out, e))
    src = join([l for l in split(src, '\n') if !startswith(lstrip(l), "#")], '\n')     # not in comments
    for m in eachmatch(Regex("\\b(?:gettext|gettext_lazy)\\(\\s*" * JL_STR), src); add("", jl_unescape(m[1])); end
    for m in eachmatch(Regex("(?<![\\w\$\"\\\\])t" * JL_STR), src); add("", jl_unescape(m[1])); end
    for m in eachmatch(Regex("\\b(?:pgettext|pgettext_lazy)\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), src); add(jl_unescape(m[1]), jl_unescape(m[2])); end
    for m in eachmatch(Regex("\\b(?:ngettext|ngettext_lazy)\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), src); add("", jl_unescape(m[1]), jl_unescape(m[2])); end
    for m in eachmatch(Regex("\\bnpgettext\\(\\s*" * JL_STR * "\\s*,\\s*" * JL_STR * "\\s*,\\s*" * JL_STR), src)
        add(jl_unescape(m[1]), jl_unescape(m[2]), jl_unescape(m[3]))
    end
    out
end

"Messages in a template: {% translate %} and {% blocktranslate %} blocks."
function extract_template(src::AbstractString, file)
    out = POEntry[]
    toks = tokenize(src)
    i = 1
    while i <= length(toks)
        tk = toks[i]
        i += 1
        tk.kind === :block || continue
        bits = split_contents(tk.contents)
        isempty(bits) && continue
        if bits[1] in ("translate", "trans") && length(bits) >= 2 && (startswith(bits[2], "\"") || startswith(bits[2], "'")) && !("noop" in bits)
            e = POEntry(); e.msgid = bits[2][2:end-1]; e.comments = ["#: $file:$(tk.line)"]
            j = findfirst(==("context"), bits)
            j === nothing || (e.context = strip(bits[j+1], ['"', '\'']))
            push!(out, e)
        elseif bits[1] in ("blocktranslate", "blocktrans")
            singular, plural = Token[], nothing
            while i <= length(toks)
                t2 = toks[i]; i += 1
                t2.kind === :block && strip(t2.contents) == "end" * bits[1] && break
                t2.kind === :block && strip(t2.contents) == "plural" && (plural = Token[]; continue)
                push!(plural === nothing ? singular : plural, t2)
            end
            trimmed = "trimmed" in bits
            e = POEntry(); e.msgid = first(blocktrans_msgid(singular, trimmed)); e.comments = ["#: $file:$(tk.line)"]
            if plural !== nothing
                e.msgid_plural = first(blocktrans_msgid(plural, trimmed)); e.msgstr = ["", ""]
            end
            j = findfirst(==("context"), bits)
            j === nothing || (e.context = strip(bits[j+1], ['"', '\'']))
            push!(out, e)
        end
    end
    out
end

const PO_HEADER = """Project-Id-Version: PACKAGE VERSION
Language: LANG
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 8bit
Plural-Forms: nplurals=2; plural=(n != 1);"""

"""
    makemessages(lang; root=pwd(), locale_dir=first(LOCALE_PATHS) or root/locale) -> path

Collect translatable strings from `.jl` files and templates under `root` into
`locale_dir/<locale>/LC_MESSAGES/juango.po`, keeping existing translations.
"""
function makemessages(lang; root = pwd(), locale_dir = isempty(settings.LOCALE_PATHS) ? joinpath(root, "locale") : string(first(settings.LOCALE_PATHS)))
    found = POEntry[]
    for (dir, _, files) in walkdir(root), f in sort(files)
        p = joinpath(dir, f)
        (occursin("/.git", p) || startswith(relpath(p, root), "locale")) && continue
        rel = relpath(p, root)
        if endswith(f, ".jl")
            append!(found, extract_julia(read(p, String), rel))
        elseif endswith(f, ".html") || endswith(f, ".txt")
            append!(found, extract_template(read(p, String), rel))
        end
    end
    merged = Dict{Tuple{String,String},POEntry}()
    order = Tuple{String,String}[]
    for e in found
        k = (e.context, e.msgid)
        if haskey(merged, k)
            append!(merged[k].comments, e.comments)
        else
            merged[k] = e; push!(order, k)
        end
    end
    path = joinpath(locale_dir, to_locale(lang), "LC_MESSAGES", "juango.po")
    header = replace(PO_HEADER, "LANG" => to_locale(lang))
    if isfile(path)
        old = parse_po(read(path, String))
        isempty(header_of(old)) || (header = header_of(old))
        oldmap = Dict((e.context, e.msgid) => e for e in old if !isempty(e.msgid))
        for k in order
            haskey(oldmap, k) || continue
            merged[k].msgstr = oldmap[k].msgstr
            merged[k].fuzzy = oldmap[k].fuzzy
        end
    end
    mkpath(dirname(path))
    open(path, "w") do io
        write_po(io, [merged[k] for k in order]; header = header)
    end
    path
end

"Compile every juango.po under `dirs` into juango.mo; returns the files written."
function compilemessages(dirs = vcat(String[string(p) for p in settings.LOCALE_PATHS], [joinpath(pwd(), "locale")]))
    written = String[]
    for d in unique(dirs)
        isdir(d) || continue
        for (dir, _, files) in walkdir(d), f in files
            f == "juango.po" || continue
            po = joinpath(dir, f)
            write(joinpath(dir, "juango.mo"), write_mo(parse_po(read(po, String))))
            push!(written, joinpath(dir, "juango.mo"))
        end
    end
    reload_translations!()
    written
end
