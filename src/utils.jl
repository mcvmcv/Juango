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

"Escape `&`, `<`, `>`, quotes for safe inclusion in HTML."
escape_html(s::AbstractString) = replace(s, HTML_ESCAPES...)
escape_html(s::SafeString) = escape_html(s.s)
escape_html(x) = escape_html(string(x))

"""
    __html__(x)

Return the HTML representation of `x` as a `String` if `x` knows how to render
itself as HTML (and therefore must not be escaped), or `nothing` otherwise.
"""
__html__(x) = nothing
__html__(x::SafeString) = x.s

"Escape `x` unless it is already safe. Returns a `String`."
conditional_escape(x) = (h = __html__(x); h === nothing ? escape_html(display_string(x)) : h)

"How values are turned into text in templates."
display_string(::Nothing) = ""
display_string(x::AbstractString) = String(x)
display_string(x::SafeString) = x.s
display_string(x::DateTime) = Dates.format(x, "yyyy-mm-dd HH:MM:SS")
display_string(x::AbstractFloat) = isinteger(x) && abs(x) < 1e15 ? string(x) : string(x)
display_string(x) = string(x)

const ALNUM = collect("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
const SECURE_RNG = Random.RandomDevice()

"Cryptographically random alphanumeric string."
random_string(n::Integer = 32) = String(rand(SECURE_RNG, ALNUM, n))

"Constant-time comparison of two strings/byte vectors."
function consteq(a, b)
    a = Vector{UInt8}(codeunits(string(a)))
    b = Vector{UInt8}(codeunits(string(b)))
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
