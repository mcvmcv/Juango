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
Converter(regex::AbstractString, to_julia, to_url) = Converter(String(regex), to_julia, to_url, Regex("^(?:" * regex * ")\$"))

const CONVERTERS = Dict{String,Converter}(
    "str" => Converter("[^/]+", identity, string),
    "int" => Converter("[0-9]+", s -> parse(Int, s), string),
    "slug" => Converter("[-a-zA-Z0-9_]+", identity, string),
    "path" => Converter(".+", identity, string),
    "uuid" => Converter("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", identity, string),
)

"Register a custom path converter, e.g. `register_converter!(\"year\", \"[0-9]{4}\", s->parse(Int,s))`."
register_converter!(name, regex, to_julia = identity, to_url = string) =
    (CONVERTERS[string(name)] = Converter(regex, to_julia, to_url); nothing)

const ROUTE_PARAM = r"<(?:(?<conv>[a-zA-Z_][a-zA-Z0-9_]*):)?(?<name>[a-zA-Z_][a-zA-Z0-9_]*)>"

regex_escape(s::AbstractString) = replace(s, r"([\\.^$|?*+()\[\]{}])" => s"\\\1")

"Compile a route like `\"posts/<int:id>/\"` into a regex and its parameter list."
function compile_route(route::AbstractString; endpoint::Bool)
    io = IOBuffer()
    print(io, "^")
    params = Tuple{Symbol,String}[]
    last = 1
    for m in eachmatch(ROUTE_PARAM, route)
        print(io, regex_escape(route[last:prevind(route, m.offset)]))
        conv = m[:conv] === nothing ? "str" : String(m[:conv])
        haskey(CONVERTERS, conv) || error("URL route '$route' uses unknown converter '$conv'")
        name = String(m[:name])
        print(io, "(?<", name, ">", CONVERTERS[conv].regex, ")")
        push!(params, (Symbol(name), conv))
        last = m.offset + ncodeunits(m.match)
    end
    print(io, regex_escape(route[last:end]))
    endpoint && print(io, "\$")
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
end

"A set of patterns mounted under a prefix (see [`include_urls`](@ref))."
struct URLResolver
    route::String
    regex::Regex
    params::Vector{Tuple{Symbol,String}}
    patterns::Vector{Any}
    namespace::Union{Nothing,String}
end

struct Include
    patterns::Vector{Any}
    namespace::Union{Nothing,String}
end

"A URL pattern (or a whole included set) with every view wrapped by `f` (e.g. a permission check)."
wrap_view(p::URLPattern, f) = URLPattern(p.route, p.regex, p.params, f(p.view), p.name, p.defaults)
wrap_view(r::URLResolver, f) = URLResolver(r.route, r.regex, r.params, Any[wrap_view(x, f) for x in r.patterns], r.namespace)
wrap_view(x, f) = x

"""
    include_urls(patterns; namespace=nothing)

Mount another list of URL patterns, optionally namespaced (`reverse_url("ns:name")`).
"""
include_urls(patterns; namespace = nothing) =
    Include(collect(Any, patterns), namespace === nothing ? nothing : string(namespace))

"""
    path(route, view; name=nothing, kwargs...)
    path(route, include_urls(...))

Create a URL pattern. `route` uses Django syntax: `"posts/<int:id>/<slug:slug>/"`.
Captured values are passed to the view as keyword arguments, together with any
extra `kwargs`.
"""
function path(route::AbstractString, view; name = nothing, kwargs...)
    startswith(route, "/") && @warn "URL route '$route' starts with '/'; routes should be relative (e.g. \"posts/\")."
    rx, params = compile_route(route; endpoint = true)
    URLPattern(String(route), rx, params, view, name === nothing ? nothing : string(name),
               Dict{Symbol,Any}(kwargs))
end

function path(route::AbstractString, inc::Include)
    rx, params = compile_route(route; endpoint = false)
    URLResolver(String(route), rx, params, inc.patterns, inc.namespace)
end

"""
    re_path(regex, view; name=nothing)

Pattern from a raw regular expression; named groups become keyword arguments
(as strings). Reversing `re_path` patterns is not supported.
"""
function re_path(rx::AbstractString, view; name = nothing, kwargs...)
    r = startswith(rx, "^") ? Regex(rx) : Regex("^" * rx)
    params = Tuple{Symbol,String}[(Symbol(n), "str") for n in Base.PCRE.capture_names(r.regex) |> values]
    URLPattern(String(rx), r, params, view, name === nothing ? nothing : string(name), Dict{Symbol,Any}(kwargs))
end

"Result of resolving a path."
struct ResolverMatch
    view::Any
    kwargs::Dict{Symbol,Any}
    url_name::Union{Nothing,String}
    namespace::Union{Nothing,String}
    route::String
    language::Union{Nothing,String}      # the language prefix matched by i18n_patterns
end
ResolverMatch(view, kwargs, name, ns, route) = ResolverMatch(view, kwargs, name, ns, route, nothing)

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
        kw[name] = CONVERTERS[conv].to_julia(String(v))
    end
    kw
end

joinns(a, b) = a === nothing ? b : b === nothing ? a : a * ":" * b

function _resolve(patterns, p::AbstractString, kwargs, ns, prefix)
    for pat in patterns
        if pat isa URLPattern
            m = match(pat.regex, p)
            m === nothing && continue
            kw = merge(kwargs, capture_kwargs(m, pat.params), pat.defaults)
            return ResolverMatch(pat.view, kw, pat.name, ns, prefix * pat.route)
        elseif pat isa URLResolver
            m = match(pat.regex, p)
            m === nothing && continue
            rest = p[ncodeunits(m.match)+1:end]
            r = _resolve(pat.patterns, rest, merge(kwargs, capture_kwargs(m, pat.params)),
                         joinns(ns, pat.namespace), prefix * pat.route)
            r === nothing || return r
        elseif pat isa AbstractVector
            r = _resolve(pat, p, kwargs, ns, prefix)
            r === nothing || return r
        elseif pat isa LocalePrefix
            m = match(r"^([A-Za-z]{2}(?:-[A-Za-z0-9]+)?)/", p)
            if m !== nothing && lowercase(m[1]) in supported_codes() && (pat.prefix_default || lowercase(m[1]) != default_language())
                r = _resolve(pat.patterns, p[ncodeunits(m.match)+1:end], kwargs, ns, prefix * m.match)
                r === nothing || return ResolverMatch(r.view, r.kwargs, r.url_name, r.namespace, r.route, lowercase(m[1]))
            elseif !pat.prefix_default
                r = _resolve(pat.patterns, p, kwargs, ns, prefix)
                r === nothing || return ResolverMatch(r.view, r.kwargs, r.url_name, r.namespace, r.route, default_language())
            end
        end
    end
    nothing
end

"""
    resolve(path, urlpatterns=settings.ROOT_URLCONF) -> Union{ResolverMatch,Nothing}
"""
resolve(p::AbstractString, patterns = settings.ROOT_URLCONF) =
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

struct ReverseEntry
    route::String                       # full route with <conv:name> placeholders
    params::Vector{Tuple{Symbol,String}}
    pieces::Vector{String}              # the literal text around the parameters (length(params) + 1)
end
function ReverseEntry(route::AbstractString, params)
    pieces = String[]
    last = 1
    for m in eachmatch(ROUTE_PARAM, route)
        push!(pieces, route[last:prevind(route, m.offset)])
        last = m.offset + ncodeunits(m.match)
    end
    push!(pieces, route[last:end])
    ReverseEntry(String(route), params, pieces)
end

const REVERSE_CACHE = IdDict{Any,Dict{String,Vector{ReverseEntry}}}()
const REVERSE_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(REVERSE_CACHE), REVERSE_LOCK))

function build_reverse_index!(idx, patterns, prefix, ns)
    for pat in patterns
        if pat isa URLPattern
            pat.name === nothing && continue
            _, params = compile_route(prefix * pat.route; endpoint = true)
            push!(get!(idx, joinns(ns, pat.name), ReverseEntry[]), ReverseEntry(prefix * pat.route, params))
        elseif pat isa URLResolver
            build_reverse_index!(idx, pat.patterns, prefix * pat.route, joinns(ns, pat.namespace))
        elseif pat isa AbstractVector
            build_reverse_index!(idx, pat, prefix, ns)
        elseif pat isa LocalePrefix
            build_reverse_index!(idx, pat.patterns, prefix * (pat.prefix_default ? LANG_ALWAYS : LANG_OPTIONAL), ns)
        end
    end
    idx
end

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
    reverse_url(name, args...; urlconf=settings.ROOT_URLCONF, query=nothing, kwargs...)

Build the URL for the named pattern. Use `"namespace:name"` for included patterns.

    reverse_url("article"; id=3)        # "/articles/3/"
    reverse_url("blog:post", 3)         # positional arguments also work
"""
function reverse_url(name::AbstractString, args...; urlconf = settings.ROOT_URLCONF, query = nothing, kwargs...)
    idx = lock(REVERSE_LOCK) do
        get!(() -> build_reverse_index!(Dict{String,Vector{ReverseEntry}}(), urlconf, "", nothing), REVERSE_CACHE, urlconf)
    end
    app = CURRENT_APP[]
    if app !== nothing && startswith(name, app.first * ":")
        alias = app.second * name[length(app.first)+1:end]
        haskey(idx, alias) && (name = alias)
    end
    entries = get(idx, name, nothing)
    entries === nothing && throw(NoReverseMatch("'$name' is not a valid view name"))
    kw = kwargs                                   # (Base.Pairs: haskey, getindex and length, no Dict to build)
    for e in Iterators.reverse(entries)
        if !isempty(args)
            length(args) == length(e.params) || continue
        else
            (length(kw) == length(e.params) && all(p -> haskey(kw, p[1]), e.params)) || continue
        end
        io = IOBuffer(sizehint = 64)
        write(io, '/')
        ok = true
        for (i, (pn, conv)) in enumerate(e.params)
            c = CONVERTERS[conv]
            s = string(c.to_url(isempty(args) ? kw[pn] : args[i]))
            occursin(c.full, s) || (ok = false; break)
            print(io, e.pieces[i], conv == "path" ? join(path_quote.(split(s, '/')), '/') : path_quote(s))
        end
        ok || continue
        print(io, e.pieces[end])
        url = String(take!(io))
        if occursin("\0lang", url)
            lang = something(supported_language(get_language()), default_language())
            url = replace(url, LANG_ALWAYS => lang * "/", LANG_OPTIONAL => lang == default_language() ? "" : lang * "/")
        end
        query === nothing || (url *= "?" * urlencode(query))
        return url
    end
    throw(NoReverseMatch("Reverse for '$name' with arguments $(args) and keyword arguments $(kw) not found"))
end
