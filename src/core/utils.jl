# Small shared helpers ---------------------------------------------------------------

"""
    SafeString(s)

A string that has been marked as safe for HTML output, so the template engine will
not escape it again. Create one with [`mark_safe`](@ref).
"""
struct SafeString
    s::String
end
SafeString(s::SafeString) = s
Base.print(io::IO, s::SafeString) = print(io, s.s)
Base.show(io::IO, s::SafeString) = print(io, "SafeString(", repr(s.s), ")")
Base.string(s::SafeString) = s.s
Base.:(==)(a::SafeString, b::SafeString) = a.s == b.s
Base.:(==)(a::SafeString, b::AbstractString) = a.s == b
Base.:(==)(a::AbstractString, b::SafeString) = a == b.s
Base.isempty(s::SafeString) = isempty(s.s)
Base.length(s::SafeString) = length(s.s)
Base.:*(a::SafeString, b::SafeString) = SafeString(a.s * b.s)

"Mark `s` as safe HTML that must not be escaped by templates."
mark_safe(s) = SafeString(string(s))

const HTML_ESCAPES = ('&' => "&amp;", '<' => "&lt;", '>' => "&gt;", '"' => "&quot;", '\'' => "&#x27;")

@inline needs_html_escape(b::UInt8) = b == UInt8('&') || b == UInt8('<') || b == UInt8('>') || b == UInt8('"') || b == UInt8('\'')
@inline html_entity(b::UInt8) = b == UInt8('&') ? "&amp;" : b == UInt8('<') ? "&lt;" : b == UInt8('>') ? "&gt;" :
                                b == UInt8('"') ? "&quot;" : "&#x27;"

"""
    escape_html(s) -> String
    escape_html(io, s)

Escape `&`, `<`, `>` and quotes for safe inclusion in HTML. The two-argument form writes
straight to `io` (the template engine uses it, so rendering doesn't build extra strings).
"""
escape_html(s::AbstractString) = escape_html(String(s))
function escape_html(s::String)
    any(needs_html_escape, codeunits(s)) || return s        # the common case: nothing to escape
    io = IOBuffer(; sizehint = ncodeunits(s) + 32)
    escape_html(io, s)
    String(take!(io))
end
escape_html(s::SafeString) = escape_html(s.s)
escape_html(x) = escape_html(string(x))
escape_html(io::IO, s::AbstractString) = escape_html(io, String(s))
function escape_html(io::IO, s::String)
    cu = codeunits(s)
    start = 1
    @inbounds for i in eachindex(cu)
        b = cu[i]
        needs_html_escape(b) || continue
        i > start && write(io, view(cu, start:i-1))
        write(io, html_entity(b))
        start = i + 1
    end
    start <= length(cu) && write(io, view(cu, start:length(cu)))
    nothing
end

"""
    __html__(x)

Return the HTML representation of `x` as a `String` if `x` knows how to render
itself as HTML (and therefore must not be escaped), or `nothing` otherwise.
"""
__html__(x) = nothing
__html__(x::SafeString) = x.s

"Escape `x` unless it is already safe. Returns a `String`."
conditional_escape(x) = (h = __html__(x); h === nothing ? escape_html(display_string(x)) : h)

"Write `x` to `io` as template output: escaped unless it is safe (or `autoescape` is off)."
function write_value(io::IO, x, autoescape::Bool)
    x isa Union{Integer,AbstractFloat} && !(x isa Bool) && return (print(io, x); nothing)
    autoescape || return (write(io, display_string(x)); nothing)
    h = __html__(x)
    h === nothing ? escape_html(io, display_string(x)) : write(io, h)
    nothing
end

"""
    format_html(fmt, args...; kwargs...) -> SafeString

Build HTML safely (Django's `format_html`): `{}` (or `{1}`, `{name}`) placeholders in `fmt` are
replaced by the arguments, HTML-escaped unless they're already safe; `fmt` itself is trusted.

    format_html("<a href=\"{}\">{}</a>", url, title)
"""
function format_html(fmt::AbstractString, args...; kwargs...)
    kw = Dict(string(k) => v for (k, v) in kwargs)
    i = 0
    out = replace(fmt, r"\{(\w*)\}" => function (m)
        key = m[2:end-1]
        v = isempty(key) ? args[i += 1] : all(isdigit, key) ? args[parse(Int, key) + 1] : kw[key]
        v isa SafeString ? v.s : escape_html(display_string(v))
    end)
    SafeString(out)
end

"`format_html_join(sep, fmt, rows)`: `format_html(fmt, row...)` for each row (a tuple or a value), joined by `sep`."
format_html_join(sep::AbstractString, fmt::AbstractString, rows) =
    SafeString(join([format_html(fmt, (r isa Tuple ? r : (r,))...).s for r in rows], escape_html(sep)))

"How values are turned into text in templates."
display_string(::Nothing) = ""
display_string(x::AbstractString) = String(x)
display_string(x::SafeString) = x.s
display_string(x::DateTime) = Dates.format(x, "yyyy-mm-dd HH:MM:SS")
# a list shows as Django shows one (['a', 'b']), not as Julia's Any["a", "b"]
display_string(v::AbstractVector) = "[" * join((x isa AbstractString ? "'" * x * "'" : display_string(x) for x in v), ", ") * "]"
display_string(x) = string(x)

const ALNUM = collect("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
const SECURE_RNG = Random.RandomDevice()

"Cryptographically random alphanumeric string."
random_string(n::Integer = 32) = String(rand(SECURE_RNG, ALNUM, n))

"Constant-time comparison of two strings/byte vectors."
consteq_bytes(x::AbstractVector{UInt8}) = x
consteq_bytes(x::AbstractString) = codeunits(String(x))
consteq_bytes(x) = codeunits(string(x))
function consteq(a, b)
    a, b = consteq_bytes(a), consteq_bytes(b)
    length(a) == length(b) || return false
    r = UInt8(0)
    @inbounds for i in eachindex(a)
        r |= a[i] ⊻ b[i]
    end
    r == 0
end

"Convert to ASCII slug: `\"Hello, World!\"` → `\"hello-world\"`."
function slugify(s)
    s = lowercase(Base.Unicode.normalize(string(s), stripmark = true))
    s = replace(s, r"[^\w\s-]" => "")
    s = replace(strip(s), r"[-\s]+" => "-")
    String(strip(s, '-'))
end

urlquote(s) = URIs.escapeuri(string(s))
"Escape a URL path segment as Django's `reverse` does: RFC 3986 sub-delimiters, `:`, `@` and `~` stay as they are."
function path_quote(s::AbstractString)
    safe(c) = isascii(c) && (isletter(c) || isdigit(c) || c in "-._~!\$&'()*+,;=:@")
    all(safe, s) && return String(s)
    io = IOBuffer()
    for b in codeunits(s)
        c = Char(b)
        b < 0x80 && safe(c) ? write(io, b) : print(io, '%', uppercase(string(b; base = 16, pad = 2)))
    end
    String(take!(io))
end
urlunquote(s) = URIs.unescapeuri(replace(string(s), '+' => ' '))

"Encode a dict / pairs as `application/x-www-form-urlencoded`."
function urlencode(data)
    parts = String[]
    for (k, v) in pairs_of(data)
        vals = v isa AbstractVector ? v : [v]
        for x in vals
            push!(parts, urlquote(string(k)) * "=" * urlquote(x === nothing ? "" : string(x)))
        end
    end
    join(parts, "&")
end
pairs_of(d::AbstractDict) = pairs(d)
pairs_of(d::NamedTuple) = pairs(d)
pairs_of(d) = d

"Recursively convert JSON objects into plain `Dict{String,Any}` / `Vector{Any}`."
plainjson(x::AbstractDict) = Dict{String,Any}(string(k) => plainjson(v) for (k, v) in x)
plainjson(x::AbstractVector) = Any[plainjson(v) for v in x]
plainjson(x) = x

"Normalise a user-supplied context (Dict / NamedTuple / pairs) to `Dict{String,Any}`."
function to_context_dict(x)
    d = Dict{String,Any}()
    x === nothing && return d
    for (k, v) in pairs_of(x)
        d[string(k)] = v
    end
    d
end

"Format seconds since epoch as an HTTP date."
http_date(dt::DateTime) = Dates.format(dt, "e, dd u yyyy HH:MM:SS") * " GMT"

"""
    within(root, p) -> Bool

Whether the normalised path `p` is `root` or inside it. (A plain `startswith` would also accept
a sibling: `/srv/static_private` starts with `/srv/static`.)
"""
function within(root::AbstractString, p::AbstractString)
    r = rstrip(normpath(root), ('/', '\\'))
    p = normpath(p)
    p == r || startswith(p, r * Base.Filesystem.path_separator) || (Sys.iswindows() && startswith(p, r * "/"))
end

"`Vector{Any}` with `v`'s elements, compiled once for every element type."
Base.@nospecializeinfer function any_vector(@nospecialize(v::AbstractVector))
    out = Vector{Any}(undef, length(v))
    i = 0
    for x in v
        out[i += 1] = x
    end
    out
end
