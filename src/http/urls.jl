# URL routing --------------------------------------------------------------------------
#
#     urlpatterns = [
#         path("", home; name="home"),
#         path("articles/<int:id>/", article_detail; name="article"),
#         path("blog/", include_urls(blog_urls; namespace="blog")),
#     ]

struct Converter
    regex::String
    to_julia::Function
    to_url::Function
    full::Regex             # ^regex$, compiled once (checks values when reversing)
end
Converter(regex::AbstractString, to_julia, to_url) = Converter(String(regex), to_julia, to_url, Regex("^(?:" * regex * ")\\z"))

const CONVERTERS = Dict{String,Converter}(
    "str" => Converter("[^/]+", identity, string),
    "int" => Converter("[0-9]+", s -> parse(Int, s), string),
    "slug" => Converter("[-a-zA-Z0-9_]+", identity, string),
    "path" => Converter(".+", identity, string),
    "uuid" => Converter("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", identity, string),
)

"""
Register a custom path converter, e.g. `register_converter!(\"year\", \"[0-9]{4}\", s->parse(Int,s))`.
As Django's: a name already registered is an error. `to_julia` (or `to_url`) throwing an
`ArgumentError` means the value doesn't match (another pattern may); other errors propagate.
"""
function register_converter!(name, regex, to_julia = identity, to_url = string)
    haskey(CONVERTERS, string(name)) && throw(ArgumentError("Converter '$name' is already registered."))
    CONVERTERS[string(name)] = Converter(regex, to_julia, to_url)
    nothing
end
"A value a converter doesn't take: no match, not an error (Django's ValueError)."
no_match_error(e) = e isa ArgumentError || e isa OverflowError || e isa InexactError

const ROUTE_PARAM = r"<(?:(?<conv>[^>:]+):)?(?<name>[^>]+)>"

regex_escape(s::AbstractString) = replace(s, r"([\\.^$|?*+()\[\]{}])" => s"\\\1")

"Compile a route like `\"posts/<int:id>/\"` into a regex and its parameter list."
function compile_route(route::AbstractString; endpoint::Bool)
    io = IOBuffer()
    print(io, "^")
    params = Tuple{Symbol,String}[]
    last = 1
    for m in eachmatch(ROUTE_PARAM, route)
        print(io, regex_escape(route[last:prevind(route, m.offset)]))
        # (as Django's: no whitespace in the brackets, a known converter, a name that's an identifier)
        any(isspace, m.match) && throw(ImproperlyConfigured("URL route $(repr(String(route))) cannot contain whitespace in angle brackets <…>"))
        conv = m[:conv] === nothing ? "str" : String(m[:conv])
        haskey(CONVERTERS, conv) || throw(ImproperlyConfigured("URL route '$route' uses invalid converter '$conv'."))
        name = String(m[:name])
        Base.isidentifier(name) ||
            throw(ImproperlyConfigured("URL route '$route' uses parameter name '$name' which isn't a valid Python identifier."))
        print(io, "(?<", name, ">", CONVERTERS[conv].regex, ")")
        push!(params, (Symbol(name), conv))
        last = m.offset + ncodeunits(m.match)
    end
    print(io, regex_escape(route[last:end]))
    endpoint && print(io, "\\z")          # (\z, not $: a trailing newline doesn't match, as Django's)
    Regex(String(take!(io))), params
end

"A single route → view mapping."
struct URLPattern
    route::String
    regex::Regex
    params::Vector{Tuple{Symbol,String}}
    view::Any
    name::Union{Nothing,String}
    defaults::Dict{Symbol,Any}
    lazy::Any                     # a translated route (gettext_lazy), or nothing
end
URLPattern(route, regex, params, view, name, defaults) = URLPattern(route, regex, params, view, name, defaults, nothing)

"A set of patterns mounted under a prefix (see [`include_urls`](@ref))."
struct URLResolver
    route::String
    regex::Regex
    params::Vector{Tuple{Symbol,String}}
    patterns::Vector{Any}
    namespace::Union{Nothing,String}     # the instance namespace
    app_name::Union{Nothing,String}      # the application namespace
    lazy::Any                            # a translated route (gettext_lazy), or nothing
end
URLResolver(route, regex, params, patterns, namespace) = URLResolver(route, regex, params, patterns, namespace, nothing, nothing)
URLResolver(route, regex, params, patterns, namespace, app_name) = URLResolver(route, regex, params, patterns, namespace, app_name, nothing)

"""
A pattern's route, regex and parameters in the active language: a translated route (`path(gettext_lazy(\"about/\"), ...)`)
is translated and compiled once per translation.
"""
function current_route(pat)
    pat.lazy === nothing && return (pat.route, pat.regex, pat.params)
    tr = string(pat.lazy)
    tr == pat.route && return (pat.route, pat.regex, pat.params)
    rx, params = lock(REVERSE_LOCK) do
        get!(() -> compile_route(tr; endpoint = pat isa URLPattern), TRANSLATED_ROUTES, (tr, pat isa URLPattern))
    end
    (tr, rx, params)
end
const TRANSLATED_ROUTES = Dict{Tuple{String,Bool},Tuple{Regex,Vector{Tuple{Symbol,String}}}}()

struct Include
    patterns::Vector{Any}
    namespace::Union{Nothing,String}
    app_name::Union{Nothing,String}
end

"A URL pattern (or a whole included set) with every view wrapped by `f` (e.g. a permission check)."
wrap_view(p::URLPattern, f) = URLPattern(p.route, p.regex, p.params, f(p.view), p.name, p.defaults, p.lazy)
wrap_view(r::URLResolver, f) = URLResolver(r.route, r.regex, r.params, Any[wrap_view(x, f) for x in r.patterns], r.namespace, r.app_name, r.lazy)
wrap_view(x, f) = x

"""
    include_urls(patterns; namespace = nothing, app_name = nothing)

Mount another list of URL patterns, optionally namespaced (`reverse_url("ns:name")`).

`app_name` is the application namespace, as Django's `app_name` in an app's urls.py; `namespace`
is the instance namespace, which defaults to it. An app mounted twice gets one `app_name` and two
instance namespaces, and `reverse_url("app:name")` picks the instance: `current_app = "..."` when
given, else the one the current request was resolved in, else the instance named like the app,
else the last one mounted.

    path("blog/", include_urls(blog_urls; app_name = "blog")),                     # reverse_url("blog:post", 1)
    path("news/", include_urls(blog_urls; app_name = "blog", namespace = "news")),  # also "news:post"
"""
function include_urls(patterns; namespace = nothing, app_name = nothing)
    any(p -> p isa LocalePrefix, patterns) && throw(ImproperlyConfigured("Using i18n_patterns in an included URLconf is not allowed."))
    include_urls_(patterns, namespace, app_name)
end
include_urls_(patterns, namespace, app_name) =
    Include(collect(Any, patterns), something(namespace, app_name, Some(nothing)) === nothing ? nothing : string(something(namespace, app_name)),
            app_name === nothing ? nothing : string(app_name))

# (as Django's: a view that isn't callable is refused when the pattern is made; a string isn't a view in Juango)
check_view(view) =
    view isa AbstractString ? throw(ArgumentError("view must be a callable or a list/tuple in the case of include(), but got str.")) :
    isempty(methods(view)) ? throw(ArgumentError("view must be a callable or a list/tuple in the case of include(), but got $(typeof(view)).")) : nothing

# (a broken regex says which pattern, as Django's ImproperlyConfigured; Juango finds it when the pattern is made)
function url_regex(rx, body)
    try
        Regex(body)
    catch e
        e isa ErrorException || rethrow()
        throw(ImproperlyConfigured("\"$rx\" is not a valid regular expression: $(replace(e.msg, r"^PCRE compilation error: " => ""))"))
    end
end

"""
    path(route, view; name=nothing, kwargs...)
    path(route, include_urls(...))

Create a URL pattern. `route` uses Django syntax: `"posts/<int:id>/<slug:slug>/"`.
Captured values are passed to the view as keyword arguments, together with any
extra `kwargs`.
"""
function path(route::AbstractString, view; name = nothing, kwargs...)
    check_view(view)
    startswith(route, "/") && @warn "URL route '$route' starts with '/'; routes should be relative (e.g. \"posts/\")."
    rx, params = compile_route(route; endpoint = true)
    URLPattern(String(route), rx, params, view, name === nothing ? nothing : string(name),
               Dict{Symbol,Any}(kwargs))
end

function path(route::AbstractString, inc::Include)
    rx, params = compile_route(route; endpoint = false)
    URLResolver(String(route), rx, params, inc.patterns, inc.namespace, inc.app_name)
end

"""
    re_path(regex, view; name=nothing)

Pattern from a raw regular expression; named groups become keyword arguments
(as strings). Reversing fills in its groups: named ones from keyword arguments, others from positional ones.
"""
function re_path(rx::AbstractString, view; name = nothing, kwargs...)
    check_view(view)
    # (a closing $ is \z, so a trailing newline doesn't match, as Django's)
    body = endswith(rx, "\$") && !endswith(rx, "\\\$") ? rx[1:prevind(rx, lastindex(rx))] * "\\z" : rx
    r = url_regex(rx, startswith(body, "^") ? body : "^" * body)
    params = Tuple{Symbol,String}[(Symbol(n), "str") for n in Base.PCRE.capture_names(r.regex) |> values]
    URLPattern(String(rx), r, params, view, name === nothing ? nothing : string(name), Dict{Symbol,Any}(kwargs))
end

"A regex prefix for an included set (`re_path(raw\"^outer/(?P<outer>[0-9]+)/\", include_urls(...))`): its named groups go to the views."
function re_path(rx::AbstractString, inc::Include)
    r = url_regex(rx, startswith(rx, "^") ? rx : "^" * rx)
    params = Tuple{Symbol,String}[(Symbol(n), "str") for n in Base.PCRE.capture_names(r.regex) |> values]
    URLResolver(String(rx), r, params, inc.patterns, inc.namespace, inc.app_name)
end

"Result of resolving a path."
struct ResolverMatch
    view::Any
    kwargs::Dict{Symbol,Any}
    url_name::Union{Nothing,String}
    namespace::Union{Nothing,String}
    route::String
    language::Union{Nothing,String}      # the language prefix matched by i18n_patterns
    app_name::Union{Nothing,String}      # the application namespaces of the includes it's in ("blog")
    args::Vector{Any}                    # a re_path's unnamed groups, when it has no named ones (Django's args)
end
ResolverMatch(view, kwargs, name, ns, route) = ResolverMatch(view, kwargs, name, ns, route, nothing, nothing, Any[])
ResolverMatch(view, kwargs, name, ns, route, language) = ResolverMatch(view, kwargs, name, ns, route, language, nothing, Any[])
ResolverMatch(view, kwargs, name, ns, route, language, app) = ResolverMatch(view, kwargs, name, ns, route, language, app, Any[])
"A regex's unnamed groups as Django's args: all its groups when it has no named ones, else none."
capture_args(m::RegexMatch, rx::Regex) = isempty(Base.PCRE.capture_names(rx.regex)) ? Any[c === nothing ? nothing : String(c) for c in m.captures] : Any[]

"""
    i18n_patterns(patterns...; prefix_default_language=true)

URL patterns under a language prefix (`/de/about/`). `LocaleMiddleware` activates that
language, and `reverse_url` adds the active language's prefix. With
`prefix_default_language=false`, the default language (`LANGUAGE_CODE`) has no prefix.
"""
struct LocalePrefix
    patterns::Vector{Any}
    prefix_default::Bool
end
i18n_patterns(patterns...; prefix_default_language = true) =
    LocalePrefix(collect(Any, length(patterns) == 1 && patterns[1] isa AbstractVector ? patterns[1] : patterns), prefix_default_language)
const LANG_ALWAYS, LANG_OPTIONAL = "\0lang1\0", "\0lang0\0"
"Whether the root URLconf uses `i18n_patterns`."
uses_i18n_patterns(patterns = settings.ROOT_URLCONF) = any(p -> p isa LocalePrefix || p isa AbstractVector && uses_i18n_patterns(p), patterns)
default_language() = something(supported_language(settings.LANGUAGE_CODE), lowercase(string(settings.LANGUAGE_CODE)))

function Base.getproperty(m::ResolverMatch, s::Symbol)
    s === :view_name || return getfield(m, s)
    n, ns = getfield(m, :url_name), getfield(m, :namespace)
    n === nothing ? nothing : ns === nothing ? n : ns * ":" * n
end

function capture_kwargs(m::RegexMatch, params)
    kw = Dict{Symbol,Any}()
    for (name, conv) in params
        v = m[string(name)]
        v === nothing && continue
        kw[name] = try
            CONVERTERS[conv].to_julia(String(v))
        catch e
            no_match_error(e) || rethrow()
            return nothing                     # (the converter refuses it: no match)
        end
    end
    kw
end

joinns(a, b) = a === nothing ? b : b === nothing ? a : a * ":" * b

# _resolve in a language, without a closure (a closure that recurses into _resolve made inference of the whole
# request path explode: #279)
function _resolve_in(lang, patterns, p, kwargs, ns, prefix, app)
    old = get(task_local_storage(), :juango_language, nothing)
    activate!(lang)
    try
        _resolve(patterns, p, kwargs, ns, prefix, app)
    finally
        old === nothing ? deactivate!() : activate!(old)
    end
end
function _resolve(patterns, p::AbstractString, kwargs, ns, prefix, app = nothing)
    for pat in patterns
        if pat isa URLPattern
            route, rx, params = current_route(pat)
            m = match(rx, p)
            m === nothing && continue
            ck = capture_kwargs(m, params)
            ck === nothing && continue
            kw = merge(kwargs, ck, pat.defaults)
            return ResolverMatch(pat.view, kw, pat.name, ns, prefix * route, nothing, app, capture_args(m, rx))
        elseif pat isa URLResolver
            route, rx, params = current_route(pat)
            m = match(rx, p)
            m === nothing && continue
            rest = p[ncodeunits(m.match)+1:end]
            ck = capture_kwargs(m, params)
            ck === nothing && continue
            r = _resolve(pat.patterns, rest, merge(kwargs, ck),
                         joinns(ns, pat.namespace), prefix * route, joinns(app, pat.app_name))
            # (the prefix's unnamed groups come first when nothing is named, as Django's)
            r === nothing || return isempty(r.kwargs) ?
                ResolverMatch(r.view, r.kwargs, r.url_name, r.namespace, r.route, r.language, r.app_name, vcat(capture_args(m, rx), r.args)) : r
        elseif pat isa AbstractVector
            r = _resolve(pat, p, kwargs, ns, prefix, app)
            r === nothing || return r
        elseif pat isa LocalePrefix && !settings.USE_I18N            # (without i18n: the patterns, unprefixed, as Django's)
            r = _resolve(pat.patterns, p, kwargs, ns, prefix, app)
            r === nothing || return r
        elseif pat isa LocalePrefix
            m = match(r"^([A-Za-z]{2}(?:-[A-Za-z0-9]+)?)/", p)
            # (translated routes under the prefix are read in the prefix's language, as LocaleMiddleware activates it)
            if m !== nothing && lowercase(m[1]) in supported_codes() && (pat.prefix_default || lowercase(m[1]) != default_language())
                r = _resolve_in(lowercase(m[1]), pat.patterns, p[ncodeunits(m.match)+1:end], kwargs, ns, prefix * m.match, app)
                r === nothing || return ResolverMatch(r.view, r.kwargs, r.url_name, r.namespace, r.route, lowercase(m[1]), r.app_name, r.args)
            elseif !pat.prefix_default
                r = _resolve_in(default_language(), pat.patterns, p, kwargs, ns, prefix, app)
                r === nothing || return ResolverMatch(r.view, r.kwargs, r.url_name, r.namespace, r.route, default_language(), r.app_name, r.args)
            end
        end
    end
    nothing
end

"""
The URLconf a request uses, while it's handled: one a middleware set (`req.urlconf = inner_urls`, Django's
`request.urlconf`), else ROOT_URLCONF. `reverse_url` and `resolve` use it, the response middleware too.
"""
const URLCONF_REF = Base.ScopedValues.ScopedValue{Union{Nothing,Base.RefValue{Any}}}(nothing)
"The URLconf in use: the request's (`req.urlconf`), else ROOT_URLCONF."
current_urlconf() = (r = URLCONF_REF[]; r === nothing || r[] === nothing ? settings.ROOT_URLCONF : r[])
"The URLconf a middleware set for the current request, or nothing (Django's `get_urlconf`)."
get_urlconf() = (r = URLCONF_REF[]; r === nothing ? nothing : r[])

"""
    resolve(path, urlpatterns = <the current URLconf>) -> Union{ResolverMatch,Nothing}
"""
resolve(p::AbstractString, patterns = current_urlconf()) =
    _resolve(patterns, lstrip(p, '/'), Dict{Symbol,Any}(), nothing, "")

"All routes as `(route, name)` tuples, used by the debug 404 page and `showurls`."
function all_routes(patterns = settings.ROOT_URLCONF, prefix = "", ns = nothing)
    out = Tuple{String,Union{Nothing,String},Any}[]
    for pat in patterns
        if pat isa URLPattern
            push!(out, (prefix * pat.route, pat.name === nothing ? nothing : joinns(ns, pat.name), pat.view))
        elseif pat isa URLResolver
            append!(out, all_routes(pat.patterns, prefix * pat.route, joinns(ns, pat.namespace)))
        elseif pat isa AbstractVector
            append!(out, all_routes(pat, prefix, ns))
        elseif pat isa LocalePrefix
            append!(out, all_routes(pat.patterns, prefix * "<language>/", ns))
        end
    end
    out
end

# --- reversing ------------------------------------------------------------------------
#
# As Django's: each named pattern's whole regex (its includes' prefixes, then its own) is turned into the URLs it
# can match (`regex_normalize`, Django's regex_helper.normalize: an optional part both ways, `x+` once, `x{2,4}`
# twice, a character class its first character, \d "0"), with the groups to fill in. A candidate URL is kept
# only if the whole regex matches it.

"One way to reverse a pattern: literal text and parameter references, in order."
struct ReverseEntry
    shown::String                       # the pattern, for NoReverseMatch's "pattern(s) tried"
    params::Vector{Symbol}              # the groups to fill in (positional ones are :_0, :_1, ...)
    pieces::Vector{Any}                 # String (literal text) or Symbol (a parameter's value)
    convs::Dict{Symbol,String}          # path() parameters' converters (but str: the whole regex checks it)
    check_src::String                   # the whole pattern, which the candidate URL must match (compiled when first used)
    check::Base.RefValue{Union{Nothing,Regex}}
    defaults::Dict{Symbol,Any}          # the pattern's extra kwargs (a reverse's kwargs must agree with them)
end

const REVERSE_CACHE = IdDict{Any,Dict{String,Dict{Any,Vector{ReverseEntry}}}}()     # urlconf => language => name or view => entries
"Per URLconf: application namespace => its instance namespaces, in the order they're mounted."
const APP_INSTANCES = IdDict{Any,Dict{String,Vector{String}}}()
const REVERSE_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> (empty!(REVERSE_CACHE); empty!(APP_INSTANCES); empty!(TRANSLATED_ROUTES)), REVERSE_LOCK))

function collect_app_instances!(apps, patterns, ns, app)
    for pat in patterns
        if pat isa URLResolver
            ns2, app2 = joinns(ns, pat.namespace), joinns(app, pat.app_name)
            if pat.app_name !== nothing && ns2 !== nothing
                v = get!(apps, app2, String[])
                ns2 in v || push!(v, ns2)
            end
            collect_app_instances!(apps, pat.patterns, ns2, app2)
        elseif pat isa AbstractVector
            collect_app_instances!(apps, pat, ns, app)
        elseif pat isa LocalePrefix
            collect_app_instances!(apps, pat.patterns, ns, app)
        end
    end
    apps
end

"""
The instance namespace to reverse `app:...` in: `current_app` if it's one of the app's instances,
else the current request's (CURRENT_APP), else the instance named like the app, else the last
one mounted (Django's rules). `nothing` when `app` isn't an application namespace.
"""
function pick_instance(apps, app::AbstractString, current_app)
    insts = get(apps, app, nothing)
    insts === nothing && return nothing
    current_app !== nothing && string(current_app) in insts && return string(current_app)
    cur = CURRENT_APP[]
    cur !== nothing && cur.first == app && cur.second in insts && return cur.second
    app in insts && return app
    insts[end]
end

"""
A level's namespaces, as Django's resolver has them: instance namespace => its patterns (the first include of a name
wins), and application namespace => its instances (the last mounted first). Includes without a namespace are part
of the level.
"""
function level_namespaces(patterns)
    lock(REVERSE_LOCK) do
        get!(NAMESPACE_CACHE, patterns) do
            nsd, appd = Dict{String,Vector{Any}}(), Dict{String,Vector{String}}()
            add!(ps) = for pat in ps
                if pat isa URLResolver && pat.namespace !== nothing
                    haskey(nsd, pat.namespace) || (nsd[pat.namespace] = pat.patterns)
                    pat.app_name === nothing || (v = get!(appd, pat.app_name, String[]); pat.namespace in v || pushfirst!(v, pat.namespace))
                elseif pat isa URLResolver || pat isa LocalePrefix
                    add!(pat.patterns)
                elseif pat isa AbstractVector
                    add!(pat)
                end
            end
            add!(patterns)
            (nsd, appd)
        end
    end
end
const NAMESPACE_CACHE = IdDict{Any,Tuple{Dict{String,Vector{Any}},Dict{String,Vector{String}}}}()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(NAMESPACE_CACHE), REVERSE_LOCK))

"""
The instance namespaces `path` (`["inc-ns1", "testapp"]`) reverses in, joined, as Django's reverse: an application
namespace is its instance in `current_app` (followed while it agrees), else the request's (CURRENT_APP), else the
instance named like it, else the last mounted. `(nothing, message)` for a namespace that isn't there.
"""
function resolve_namespaces(urlconf, path, current_app)
    level, resolved = urlconf, String[]
    cur = current_app === nothing ? nothing : String.(split(string(current_app), ':'))
    for (k, n) in enumerate(path)
        ns = String(n)
        cns = cur !== nothing && !isempty(cur) ? popfirst!(cur) : nothing
        nsd, appd = level_namespaces(level)
        lst = get(appd, ns, nothing)
        if lst !== nothing
            req = CURRENT_APP[]
            if cns !== nothing && cns in lst
                ns = cns
            elseif k == 1 && cns === nothing && req !== nothing && req.first == ns && req.second in lst
                ns = req.second
            elseif !(ns in lst)
                ns = lst[1]
            end
        end
        ns != cns && (cur = nothing)
        if !haskey(nsd, ns)
            return nothing, isempty(resolved) ? "'$ns' is not a registered namespace" :
                                                "'$ns' is not a registered namespace inside '$(join(resolved, ':'))'"
        end
        push!(resolved, ns)
        level = nsd[ns]
    end
    join(resolved, ':'), nothing
end

# Django's regex_helper.normalize ------------------------------------------------------

const REGEX_ESCAPES = Dict{Char,Union{Nothing,Char}}('A' => nothing, 'b' => nothing, 'B' => nothing, 'd' => '0', 'D' => 'x',
                                                     's' => ' ', 'S' => 'x', 'w' => 'x', 'W' => '!', 'Z' => nothing, 'z' => nothing)
struct RxGroup                  # a group: the text is `ref`'s value; `param` is what the caller passes (nothing: a backreference)
    ref::Symbol
    param::Union{Nothing,Symbol}
end
struct RxNonCapture
    items::Vector{Any}
end
struct RxChoice                 # either of `items` (nothing: no text)
    items::Vector{Any}
end

"A regex's characters with their escapes resolved: `(char, escaped)`, `\\d` as an escaped '0', `\\b` dropped."
function regex_tokens(p::AbstractString)
    cs, out, i = collect(p), Tuple{Char,Bool}[], 1
    while i <= length(cs)
        c = cs[i]
        if c != '\\'
            push!(out, (c, false)); i += 1; continue
        end
        i == length(cs) && break
        r = get(REGEX_ESCAPES, cs[i+1], cs[i+1])
        i += 2
        r === nothing || push!(out, (r, true))
    end
    out
end
rx_contains_group(x) = x isa RxGroup || (x isa RxNonCapture && any(rx_contains_group, x.items))

"""
The URLs a regular expression can match, for reversing: `[(pieces, params)]`, the pieces literal text (String) and
group references (Symbol), as Django's `normalize`. A regex with an alternation (`a|b`) gives one empty way.
"""
function regex_normalize(pattern::AbstractString)
    toks = regex_tokens(pattern)
    isempty(toks) && return [(Any[""], Symbol[])]
    pos = Ref(0)
    nxt() = (pos[] += 1; pos[] > length(toks) ? throw(EOFError()) : toks[pos[]])
    peek() = pos[] < length(toks) ? toks[pos[]+1] : nothing
    function walk_to_end(ch)
        nesting = ch == '(' ? 1 : 0
        while true
            c, esc = nxt()
            esc && continue
            if c == '('
                nesting += 1
            elseif c == ')'
                nesting == 0 && return
                nesting -= 1
            end
        end
    end
    function quantifier(ch)
        if ch in "*?+"
            t = peek() === nothing ? nothing : nxt()
            t !== nothing && t[1] == '?' && (t = nothing)            # (a lazy quantifier)
            return (ch == '+' ? 1 : 0), t
        end
        q = Char[]
        while ch != '}'
            ch, _ = nxt()
            push!(q, ch)
        end
        n = parse(Int, split(String(q[1:end-1]), ",")[1])
        t = peek() === nothing ? nothing : nxt()
        t !== nothing && t[1] == '?' && (t = nothing)
        n, t
    end
    result, ncg, nargs = Any[], Int[], 0
    ch, escaped = nxt()
    try
        while true
            consume = true
            if escaped
                push!(result, string(ch))
            elseif ch == '.'
                push!(result, ".")
            elseif ch == '|'
                return [(Any[""], Symbol[])]                          # (not reversible: Django's NotImplementedError)
            elseif ch == '^'
            elseif ch == '$'
                break
            elseif ch == ')'
                isempty(ncg) && throw(ArgumentError("unbalanced parenthesis in $(repr(pattern))"))
                start = pop!(ncg)
                result = vcat(result[1:start], Any[RxNonCapture(result[start+1:end])])
            elseif ch == '['                                          # a character class: its first character
                ch, escaped = nxt()
                push!(result, string(ch))
                ch, escaped = nxt()
                while escaped || ch != ']'
                    ch, escaped = nxt()
                end
            elseif ch == '('
                ch, escaped = nxt()
                if ch != '?' || escaped
                    name = Symbol("_", nargs); nargs += 1
                    push!(result, RxGroup(name, name))
                    walk_to_end(ch)
                else
                    ch, escaped = nxt()
                    pk = peek()
                    if ch in "!=" || (ch == '<' && pk !== nothing && pk[1] in "!=")    # lookahead, lookbehind
                        walk_to_end(ch)
                    elseif ch == ':'
                        push!(ncg, length(result))
                    elseif ch == '<' || ch == 'P'                         # (?<name>...), (?P<name>...), (?P=name)
                        ch == 'P' && ((ch, escaped) = nxt())
                        ch in ('<', '=') || throw(ArgumentError("Non-reversible reg-exp portion: '(?P$ch'"))
                        terminal = ch == '<' ? '>' : ')'
                        name = Char[]
                        ch, escaped = nxt()
                        while ch != terminal
                            push!(name, ch)
                            ch, escaped = nxt()
                        end
                        p = Symbol(String(name))
                        if terminal != ')'
                            push!(result, RxGroup(p, p))
                            walk_to_end(ch)
                        else
                            push!(result, RxGroup(p, nothing))
                        end
                    else
                        throw(ArgumentError("Non-reversible reg-exp portion: '(?$ch'"))
                    end
                end
            elseif ch in "*?+{"
                n, t = quantifier(ch)
                t === nothing || ((ch, escaped) = t; consume = false)
                if n == 0
                    isempty(result) || (rx_contains_group(result[end]) ? (result[end] = RxChoice(Any[nothing, result[end]])) : pop!(result))
                elseif n > 1
                    append!(result, fill(result[end], n - 1))
                end
            else
                push!(result, string(ch))
            end
            consume && ((ch, escaped) = nxt())
        end
    catch e
        e isa EOFError || rethrow()
    end
    r, a = rx_flatten(result)
    collect(zip(r, a))
end

rx_flatten(::Nothing) = ([Any[]], [Symbol[]])
rx_flatten(s::String) = ([Any[s]], [Symbol[]])
rx_flatten(g::RxGroup) = ([Any[g.ref]], [g.param === nothing ? Symbol[] : Symbol[g.param]])
rx_flatten(n::RxNonCapture) = rx_flatten(n.items)
function rx_flatten(source::Vector{Any})
    result, rargs = [Any[]], [Symbol[]]
    last = 1
    for (pos, elt) in enumerate(source)
        elt isa String && continue
        piece = Any[source[last:pos-1]...]
        last = pos + 1
        for i in eachindex(result)
            append!(result[i], piece)
            if elt isa RxGroup
                push!(result[i], elt.ref)
                elt.param === nothing || push!(rargs[i], elt.param)
            end
        end
        if elt isa RxChoice || elt isa RxNonCapture
            items = elt isa RxNonCapture ? Any[elt] : elt.items
            ir, ia = Vector{Any}[], Vector{Symbol}[]
            for item in items
                r, a = rx_flatten(item)
                append!(ir, r); append!(ia, a)
            end
            nr, na = Vector{Any}[], Vector{Symbol}[]
            for (r, ra) in zip(result, rargs), (x, xa) in zip(ir, ia)
                push!(nr, vcat(r, x)); push!(na, vcat(ra, xa))
            end
            result, rargs = nr, na
        end
    end
    for r in result
        append!(r, source[last:end])
    end
    result, rargs
end

"A level's regex source without its leading `^` (levels are joined into one regex, as Django's resolver does)."
level_source(rx::Regex) = (s = rx.pattern; startswith(s, "^") ? s[2:end] : s)
"How a pattern is shown in NoReverseMatch's message: a re_path's regex as written, a path's regex."
level_shown(route, rx) = (s = is_regex_route(route) ? String(route) : rx.pattern; startswith(s, "^") ? s[2:end] : s)
const LANG_CHECK = "(?:[A-Za-z]{2,3}(?:-[A-Za-z0-9]+)*/)?"

"Add the reverse entries of `patterns` under the prefix (its regex source, check source, shown text, converters)."
function build_reverse_index!(idx, patterns, src, chk, shown, convs, ns, seen = Set{String}())
    for pat in patterns
        if pat isa URLPattern
            (pat.name === nothing && ns !== nothing) && continue
            route, rx, params = current_route(pat)
            level = level_source(rx)
            cv = merge(convs, Dict{Symbol,String}(n => c for (n, c) in params if c != "str"))
            ways = try
                regex_normalize(src * level)
            catch e
                e isa ArgumentError || rethrow()
                continue                                              # (a regex that can't be reversed)
            end
            check = "^/" * chk * level
            sh = shown * level_shown(route, rx)
            # (reverse_url tries a name's entries last first: a pattern's ways go in backwards, so it tries them in order)
            es = [ReverseEntry(sh, a, merge_pieces(p), cv, check, Ref{Union{Nothing,Regex}}(nothing), pat.defaults) for (p, a) in Iterators.reverse(ways)]
            pat.name === nothing || append!(get!(idx, joinns(ns, pat.name), ReverseEntry[]), es)
            ns === nothing && append!(get!(idx, pat.view, ReverseEntry[]), es)        # (by the view too, as Django)
        elseif pat isa URLResolver
            route, rx, params = current_route(pat)
            level = level_source(rx)
            cv = merge(convs, Dict{Symbol,String}(n => c for (n, c) in params if c != "str"))
            # (a namespace mounted twice in a level: the first one, as Django's)
            pat.namespace === nothing || !(joinns(ns, pat.namespace) in seen) || continue
            pat.namespace === nothing || push!(seen, joinns(ns, pat.namespace))
            build_reverse_index!(idx, pat.patterns, src * level, chk * level, shown * level_shown(route, rx), cv,
                                 joinns(ns, pat.namespace), seen)
        elseif pat isa AbstractVector
            build_reverse_index!(idx, pat, src, chk, shown, convs, ns, seen)
        elseif pat isa LocalePrefix
            build_reverse_index!(idx, pat.patterns, src * (pat.prefix_default ? LANG_ALWAYS : LANG_OPTIONAL), chk * LANG_CHECK,
                                 shown, convs, ns, seen)
        end
    end
    idx
end
build_reverse_index!(idx, patterns, prefix, ns) = build_reverse_index!(idx, patterns, "", "", "", Dict{Symbol,String}(), ns)
"An entry's whole-pattern regex, compiled when first used."
entry_check(e::ReverseEntry) = something(e.check[], lock(REVERSE_LOCK) do
    e.check[] === nothing && (e.check[] = Regex(unique_group_names(e.check_src)))
    e.check[]
end)
"""
A regex with a group name that repeats (nested prefixes each capturing `outer`) renamed so PCRE takes it: a later
group gets a new name, and backreferences after it follow.
"""
function unique_group_names(src::AbstractString)
    seen, cur = Dict{String,Int}(), Dict{String,String}()
    replace(src, r"\(\?P?<([A-Za-z_]\w*)>|\(\?P=([A-Za-z_]\w*)\)" => function (m)
        g = match(r"^\(\?P?<([A-Za-z_]\w*)>$", m)
        if g !== nothing
            n = String(g[1])
            k = get(seen, n, 0)
            seen[n] = k + 1
            cur[n] = k == 0 ? n : "$(n)__$k"
            return "(?P<$(cur[n])>"
        end
        n = String(match(r"^\(\?P=(\w+)\)$", m)[1])
        "(?P=$(get(cur, n, n)))"
    end)
end
"Adjacent literal pieces joined."
function merge_pieces(p)
    out = Any[]
    for x in p
        x isa Symbol ? push!(out, x) : !isempty(out) && out[end] isa String ? (out[end] *= x) : push!(out, String(x))
    end
    out
end

"Whether a route is a `re_path`'s regular expression rather than a `path` route."
is_regex_route(r::AbstractString) = startswith(r, "^") || endswith(r, "\$") || occursin('(', r) || occursin('\\', r)

struct NoReverseMatch <: Exception
    msg::String
end
Base.showerror(io::IO, e::NoReverseMatch) = print(io, "NoReverseMatch: ", e.msg)

"""
The instance namespace in use for an application namespace while a request is handled, as
`app => instance` (Django's `current_app`): an admin site named "staff" sets `"admin" => "staff"`,
so `reverse_url("admin:index")` and `{% url 'admin:index' %}` find that site's pages.
"""
const CURRENT_APP = Base.ScopedValues.ScopedValue{Union{Nothing,Pair{String,String}}}(nothing)

"""
Functions that may translate a view name `reverse_url` doesn't know: `(name, args, kwargs) ->
(name, args, kwargs)` or `nothing`. The admin uses one for Django's per-model names
(`admin:blog_post_change`), so they work for models registered at any time.
"""
const REVERSE_FALLBACKS = Function[]

# Python's repr, for NoReverseMatch's messages as Django's
url_repr(s::AbstractString) = "'" * replace(s, "\\" => "\\\\", "'" => "\\'") * "'"
url_repr(x::Bool) = x ? "True" : "False"
url_repr(::Nothing) = "None"
url_repr(x) = string(x)
url_tuple(xs) = "(" * join(map(url_repr, xs), ", ") * (length(xs) == 1 ? ",)" : ")")

"""
    reverse_url(name, args...; urlconf=<the current URLconf>, query=nothing, fragment=nothing, current_app=nothing, kwargs...)

Build the URL for the named pattern (or a view: the pattern it's mounted at). Use `"namespace:name"` for included
patterns. `query` (a Dict, pairs or a QueryDict) is added as the query string and `fragment` after `#`, as Django's.

    reverse_url("article"; id=3)        # "/articles/3/"
    reverse_url("blog:post", 3)         # positional arguments also work
"""
function reverse_url(name, args...; urlconf = current_urlconf(), query = nothing, fragment = nothing, current_app = nothing, kwargs...)
    name === nothing && throw(NoReverseMatch("Reverse for 'None' not found. 'None' is not a valid view function or pattern name."))
    !isempty(args) && !isempty(kwargs) && throw(ArgumentError("Don't mix *args and **kwargs in call to reverse()!"))
    fragment === nothing || fragment isa AbstractString || throw(ArgumentError("fragment must be a string, not $(typeof(fragment))"))
    idx, apps = lock(REVERSE_LOCK) do
        # (one index per language: translated routes reverse to the active language's)
        get!(() -> build_reverse_index!(Dict{Any,Vector{ReverseEntry}}(), urlconf, "", nothing),
             get!(() -> Dict{String,Dict{Any,Vector{ReverseEntry}}}(), REVERSE_CACHE, urlconf), get_language()),
        get!(() -> collect_app_instances!(Dict{String,Vector{String}}(), urlconf, nothing, nothing), APP_INSTANCES, urlconf)
    end
    nserr = nothing
    if name isa AbstractString
        i = findlast(':', name)
        inst = nothing
        nserr = nothing
        if i !== nothing                                   # namespaces: each one an instance, or an application's (Django's walk)
            r, nserr = resolve_namespaces(urlconf, split(name[1:prevind(name, i)], ':'), current_app)
            r === nothing || (inst = r; name = r * name[i:end])
        end
        app = CURRENT_APP[]
        if inst === nothing && app !== nothing && startswith(name, app.first * ":")     # (an admin site's own name)
            alias = app.second * name[length(app.first)+1:end]
            haskey(idx, alias) && (name = alias)
        end
    end
    entries = get(idx, name, nothing)
    shown_name = name isa AbstractString ? name : string(name)
    if entries === nothing
        if name isa AbstractString
            for fb in REVERSE_FALLBACKS
                r = fb(name, args, kwargs)
                r === nothing || return reverse_url(r[1], r[2]...; urlconf = urlconf, query = query, fragment = fragment, current_app = current_app, r[3]...)
            end
        end
        name isa AbstractString && nserr !== nothing && throw(NoReverseMatch(nserr))
        throw(NoReverseMatch("Reverse for '$shown_name' not found. '$shown_name' is not a valid view function or pattern name."))
    end
    kw = kwargs                                   # (Base.Pairs: haskey, getindex and length, no Dict to build)
    for e in Iterators.reverse(entries)
        if !isempty(args)
            length(args) == length(e.params) || continue
        else
            # the kwargs are the parameters, give or take the pattern's defaults, and agree with the defaults (Django's rule)
            all(k -> k in e.params || haskey(e.defaults, k), keys(kw)) || continue
            all(p -> haskey(kw, p) || haskey(e.defaults, p), e.params) || continue
            any(d -> haskey(kw, d.first) && kw[d.first] != d.second, e.defaults) && continue
        end
        text = Dict{Symbol,String}()
        ok = true
        for (i, p) in enumerate(e.params)
            conv = get(e.convs, p, nothing)
            v = !isempty(args) ? args[i] : haskey(kw, p) ? kw[p] : e.defaults[p]
            s = if conv === nothing
                v isa Bool ? url_repr(v) : string(v)
            else
                c = CONVERTERS[conv]
                t = try
                    string(c.to_url(v))
                catch err
                    no_match_error(err) || rethrow()
                    nothing                        # (the converter refuses the value: try the next pattern)
                end
                (t === nothing || !occursin(c.full, t)) && (ok = false; break)
                t
            end
            text[p] = s
        end
        ok || continue
        io = IOBuffer(sizehint = 64)
        write(io, '/')
        for x in e.pieces
            print(io, x isa Symbol ? get(text, x, "") : x)
        end
        url = String(take!(io))
        if occursin("\0lang", url)
            lang = something(supported_language(get_language()), default_language())
            url = !settings.USE_I18N ? replace(url, LANG_ALWAYS => "", LANG_OPTIONAL => "") :
                  replace(url, LANG_ALWAYS => lang * "/", LANG_OPTIONAL => lang == default_language() ? "" : lang * "/")
        end
        occursin(entry_check(e), url) || continue                         # (the whole pattern matches it)
        url = join(path_quote.(split(url, '/')), '/')
        startswith(url, "//") && (url = "/%2F" * url[3:end])            # (not a scheme-relative URL: Django's escape_leading_slashes)
        q = query_string(query)
        isempty(q) || (url *= "?" * q)
        fragment === nothing || (url *= "#" * fragment)
        return url
    end
    tried = unique([e.shown for e in Iterators.reverse(entries)])
    argmsg = !isempty(args) ? "arguments '$(url_tuple(args))'" :
             !isempty(kw) ? "keyword arguments '{" * join(["'$k': $(url_repr(v))" for (k, v) in kw], ", ") * "}'" : "no arguments"
    throw(NoReverseMatch("Reverse for '$shown_name' with $argmsg not found. $(length(tried)) pattern(s) tried: [" *
                         join(map(url_repr, tried), ", ") * "]"))
end
"A reverse's query string: a Dict, NamedTuple, pairs or QueryDict (empty or nothing: none), as Django's."
query_string(::Nothing) = ""
query_string(q::AbstractString) = String(q)
query_string(q::QueryDict) = urlencode(q)
query_string(q::Union{AbstractDict,NamedTuple}) = isempty(q) ? "" : plus_spaces(urlencode(Pair{Any,Any}[k => (v isa Tuple || v isa AbstractSet ? collect(v) : v) for (k, v) in pairs(q)]))
"Spaces as `+` (Python's urlencode, which reverse's query uses)."
plus_spaces(s) = replace(s, "%20" => "+")
function query_string(q::Union{AbstractVector,Tuple,AbstractSet})
    isempty(q) && return ""
    all(x -> x isa Pair || (x isa Tuple && length(x) == 2), q) || throw(ArgumentError("query must be a mapping or a sequence of pairs"))
    plus_spaces(urlencode(Pair{Any,Any}[x isa Pair ? x : (x[1] => x[2]) for x in q]))
end
query_string(q) = throw(ArgumentError("query must be a mapping or a sequence of pairs, not $(typeof(q))"))

"""
    reverse_lazy(name, args...; kwargs...) -> AbstractString

A URL reversed when it's used (printed, compared, redirected to), not when it's created: for URLs given at load
time, before the URLconf is complete (a class's `success_url`, a setting), as Django's `reverse_lazy`.
"""
struct LazyURL <: AbstractString
    name::Any
    args::Tuple
    kwargs::Base.Pairs
end
reverse_lazy(name, args...; kwargs...) = LazyURL(name, args, kwargs)
Base.String(l::LazyURL) = reverse_url(l.name, l.args...; l.kwargs...)
Base.string(l::LazyURL) = String(l)
Base.print(io::IO, l::LazyURL) = print(io, String(l))
Base.show(io::IO, l::LazyURL) = print(io, "reverse_lazy(", repr(l.name), isempty(l.args) ? "" : ", " * join(repr.(l.args), ", "), ")")   # (not reversed: shown before the URLconf exists)
Base.ncodeunits(l::LazyURL) = ncodeunits(String(l))
Base.codeunit(l::LazyURL) = UInt8
Base.codeunit(l::LazyURL, i::Integer) = codeunit(String(l), i)
Base.isvalid(l::LazyURL, i::Integer) = isvalid(String(l), i)
Base.iterate(l::LazyURL, i::Integer = 1) = iterate(String(l), i)
Base.:(==)(a::LazyURL, b::AbstractString) = String(a) == b
Base.:(==)(a::AbstractString, b::LazyURL) = a == String(b)
Base.:(==)(a::LazyURL, b::LazyURL) = String(a) == String(b)
Base.hash(l::LazyURL, h::UInt) = hash(String(l), h)
