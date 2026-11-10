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
end

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
end

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
        end
    end
    out
end

# --- reversing ------------------------------------------------------------------------

struct ReverseEntry
    route::String                       # full route with <conv:name> placeholders
    params::Vector{Tuple{Symbol,String}}
end

const REVERSE_CACHE = IdDict{Any,Dict{String,Vector{ReverseEntry}}}()
push!(SETTINGS_CHANGED_HOOKS, () -> empty!(REVERSE_CACHE))

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
        end
    end
    idx
end

struct NoReverseMatch <: Exception
    msg::String
end
Base.showerror(io::IO, e::NoReverseMatch) = print(io, "NoReverseMatch: ", e.msg)

"""
    reverse_url(name, args...; urlconf=settings.ROOT_URLCONF, query=nothing, kwargs...)

Build the URL for the named pattern. Use `"namespace:name"` for included patterns.

    reverse_url("article"; id=3)        # "/articles/3/"
    reverse_url("blog:post", 3)         # positional arguments also work
"""
function reverse_url(name::AbstractString, args...; urlconf = settings.ROOT_URLCONF, query = nothing, kwargs...)
    idx = get!(() -> build_reverse_index!(Dict{String,Vector{ReverseEntry}}(), urlconf, "", nothing),
               REVERSE_CACHE, urlconf)
    entries = get(idx, name, nothing)
    entries === nothing && throw(NoReverseMatch("'$name' is not a valid view name"))
    kw = Dict{Symbol,Any}(kwargs)
    for e in Iterators.reverse(entries)
        values = Dict{Symbol,Any}()
        if !isempty(args)
            length(args) == length(e.params) || continue
            for (i, (pn, _)) in enumerate(e.params)
                values[pn] = args[i]
            end
        else
            Set(keys(kw)) == Set(first.(e.params)) || continue
            values = kw
        end
        url = e.route
        ok = true
        for (pn, conv) in e.params
            c = CONVERTERS[conv]
            s = c.to_url(values[pn])
            occursin(Regex("^" * c.regex * "\$"), s) || (ok = false; break)
            s = conv == "path" ? join(urlquote.(split(s, '/')), '/') : urlquote(s)
            url = replace(url, Regex("<(?:" * conv * ":)?" * string(pn) * ">") => s; count = 1)
        end
        ok || continue
        url = "/" * url
        query === nothing || (url *= "?" * urlencode(query))
        return url
    end
    throw(NoReverseMatch("Reverse for '$name' with arguments $(args) and keyword arguments $(kw) not found"))
end
