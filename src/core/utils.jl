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
# (as Django's: safe text joined to unsafe text is unsafe)
Base.:*(a::SafeString, b::AbstractString) = a.s * b
Base.:*(a::AbstractString, b::SafeString) = a * b.s

"""
    mark_safe(s)

Mark `s` as safe HTML that must not be escaped by templates. As Django's, a value that renders itself as HTML (has an
`__html__` method) is returned as it is, and a function is wrapped so that what it returns is marked safe.
"""
mark_safe(s) = __html__(s) !== nothing ? s : SafeString(string(s))
mark_safe(f::Function) = (args...; kw...) -> mark_safe(f(args...; kw...))

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

"Write an Int's digits without allocating."
function write_int(io::IO, n::Int)
    n == typemin(Int) && return (print(io, n); nothing)
    n < 0 && (write(io, UInt8('-')); n = -n)
    n >= 10 && write_int(io, div(n, 10))
    write(io, UInt8('0') + UInt8(rem(n, 10)))
    nothing
end

"Escape `x` unless it is already safe. Returns a `String`."
conditional_escape(x) = (h = __html__(x); h === nothing ? escape_html(display_string(x)) : h)

"Write `x` to `io` as template output: escaped unless it is safe (or `autoescape` is off)."
function write_value(io::IO, x, autoescape::Bool)
    x isa Int && return write_int(io, x)                      # (print makes a String first)
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
    isempty(args) && isempty(kwargs) && throw(ArgumentError("args or kwargs must be provided."))   # (Django's: an f-string isn't escaped)
    kw = Dict(string(k) => v for (k, v) in kwargs)
    i = 0
    out = replace(fmt, r"\{(\w*)\}" => function (m)
        key = m[2:end-1]
        v = isempty(key) ? args[i += 1] : all(isdigit, key) ? args[parse(Int, key) + 1] : kw[key]
        v isa SafeString ? v.s : escape_html(display_string(v))
    end)
    SafeString(out)
end

"""
`format_html_join(sep, fmt, rows)`: `format_html(fmt, row...)` for each row (a tuple or a value), or
`format_html(fmt; row...)` for a dictionary's (`{id}`), joined by `sep`.
"""
format_html_join(sep::AbstractString, fmt::AbstractString, rows) =
    SafeString(join([(r isa AbstractDict ? format_html(fmt; (Symbol(k) => v for (k, v) in r)...) :
                      format_html(fmt, (r isa Tuple ? r : (r,))...)).s for r in rows], escape_html(sep)))

"How values are turned into text in templates."
display_string(::Nothing) = ""
display_string(x::Bool) = x ? "True" : "False"        # (as Django's templates, Python's str)
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

"""
    slugify(s; allow_unicode = false)

A slug, as Django's: `"Hello, World!"` → `"hello-world"`. Lowercased, accents dropped (with `allow_unicode`, kept: NFKC),
anything but letters, digits, `_`, `-` and whitespace taken out, runs of whitespace and dashes made one dash, and dashes
and underscores stripped from the ends. (Other non-ASCII letters are kept, where Django's default drops them: #310.)
"""
function slugify(s; allow_unicode::Bool = false)
    s = allow_unicode ? Base.Unicode.normalize(string(s), :NFKC) : Base.Unicode.normalize(string(s), compat = true, stripmark = true)
    s = replace(lowercase(s), r"[^\w\s-]" => "")
    s = replace(s, r"[-\s]+" => "-")
    String(strip(s, ['-', '_']))
end

"Django's `normalize_newlines`: `\\r\\n` and `\\r` made `\\n`."
normalize_newlines(s) = replace(String(display_string(s)), "\r\n" => "\n", "\r" => "\n")

const SMART_SPLIT_RE = r"""((?:[^\s'"]*(?:(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')[^\s'"]*)+)|\S+)"""
"""
    smart_split(text) -> Vector{String}

Django's `smart_split`: `text` split at whitespace, but not inside quotes (`'a "b c" d'` → `["a", "\"b c\"", "d"]`); the
quotes stay, and a backslash escapes a quote within them.
"""
smart_split(text) = String[m.match for m in eachmatch(SMART_SPLIT_RE, String(display_string(text)))]

"Python's `repr` of a string."
function py_str_repr(s::AbstractString)
    q = occursin('\'', s) && !occursin('"', s) ? '"' : '\''
    string(q, replace(s, "\\" => "\\\\", string(q) => string('\\', q)), q)
end

"""
    unescape_string_literal(s)

Django's `unescape_string_literal`: a quoted string literal's text (`"'ab\\\'c'"` → `"ab'c"`), only `\\'` (or `\\"`) and `\\\\`
being escapes. Anything not quoted at both ends is an `ArgumentError`.
"""
function unescape_string_literal(s)
    s = String(display_string(s))
    (isempty(s) || !(s[1] in "\"'") || s[end] != s[1]) && throw(ArgumentError("Not a string literal: " * py_str_repr(s)))
    q = s[1]
    replace(replace(s[nextind(s, 1):prevind(s, lastindex(s))], "\\" * q => string(q)), "\\\\" => "\\")   # (one after the other, as Python's)
end

"""
    get_valid_filename(name)

Django's `get_valid_filename`: spaces made underscores, and anything but letters, digits, `-`, `_` and `.` taken out.
What leaves nothing (or `.`, `..`) is refused (a 400, Django's SuspiciousFileOperation). The storages' `get_valid_name`
goes further (no directories, no leading dots).
"""
function get_valid_filename(name)
    s = replace(strip(String(display_string(name))), ' ' => '_')
    s = replace(s, r"[^-\w.]" => "")
    s in ("", ".", "..") && throw(BadRequest("Could not derive file name from '$(display_string(name))'"))
    String(s)
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

"""
    iri_to_uri(iri) -> String

An IRI as a URI, as Django's: non-ASCII characters (as UTF-8) and the few ASCII ones a URL can't
hold (spaces, quotes, `<>\\^`{|}`) percent-encoded; `%XX` escapes already there are kept. Redirects
use it, so a `Location` header is always ASCII.
"""
function iri_to_uri(iri)
    s = string(iri)
    keep(b) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) || (UInt8('0') <= b <= UInt8('9')) ||
              b in codeunits("_.-~/#%[]=:;\$&()+,!?*@'")
    all(keep, codeunits(s)) && return s
    join(keep(b) ? string(Char(b)) : "%" * uppercase(string(b; base = 16, pad = 2)) for b in codeunits(s))
end

"""
    filepath_to_uri(path) -> String

A file path as a URL path (Django's): backslashes become slashes and everything but letters, digits
and `_ . - ~ / ! * ( ) '` is percent-encoded.
"""
function filepath_to_uri(path)
    s = replace(string(path), '\\' => '/')
    keep(b) = (UInt8('a') <= b <= UInt8('z')) || (UInt8('A') <= b <= UInt8('Z')) || (UInt8('0') <= b <= UInt8('9')) ||
              b in codeunits("_.-~/!*()'")
    join(keep(b) ? string(Char(b)) : "%" * uppercase(string(b; base = 16, pad = 2)) for b in codeunits(s))
end
iri_to_uri(::Nothing) = nothing
filepath_to_uri(::Nothing) = nothing

"""
    repercent_broken_unicode(bytes) -> Vector{UInt8}

Django's (RFC 3987 3.2 step 3): bytes with each octet that isn't part of valid UTF-8 percent-encoded again (`\\xfc` →
`%FC`).
"""
function repercent_broken_unicode(path::AbstractVector{UInt8})
    io = IOBuffer()
    for c in String(copy(path))
        if isvalid(c)
            print(io, c)
        else
            for b in codeunits(string(c))
                print(io, '%', uppercase(string(b; base = 16, pad = 2)))
            end
        end
    end
    take!(io)
end

"""
    uri_to_iri(uri) -> String

Django's (RFC 3987 3.2): a URI with its percent-encoded UTF-8 decoded (`/%E2%99%A5/` → `/♥/`), but not the escapes of
reserved or other unsafe ASCII (`%20`, `%25`, digits) nor broken UTF-8, which stay encoded. Nothing gives nothing.
"""
function uri_to_iri(uri)
    uri === nothing && return nothing
    b = Vector{UInt8}(codeunits(string(uri)))
    out = UInt8[]
    hexval(x) = UInt8('0') <= x <= UInt8('9') ? x - UInt8('0') : UInt8('a') <= x <= UInt8('f') ? x - UInt8('a') + 0x0a :
                UInt8('A') <= x <= UInt8('F') ? x - UInt8('A') + 0x0a : nothing
    i = 1
    while i <= length(b)
        if b[i] == UInt8('%') && i + 2 <= length(b) && (h = hexval(b[i+1])) !== nothing && (l = hexval(b[i+2])) !== nothing
            v = h * 0x10 + l
            # (Django's: letters, -._~, and everything from 0x80, as their bytes)
            if v >= 0x80 || (UInt8('A') <= v <= UInt8('Z')) || (UInt8('a') <= v <= UInt8('z')) || v in codeunits("-._~")
                push!(out, v); i += 3
                continue
            end
        end
        push!(out, b[i]); i += 1
    end
    String(repercent_broken_unicode(out))
end

"Django's `escape_uri_path`: a URI's path with what's unsafe in one percent-encoded (`/foo#bar` → `/foo%23bar`)."
escape_uri_path(path::AbstractString) = py_quote(path, "/:@&+\$,-_.!~*'()")

"""
    urlencode(data; doseq = true)

A dict, NamedTuple or pairs as `application/x-www-form-urlencoded` text, as Django's `urlencode`: keys and values quoted
(spaces as `+`), bytes as text. A value that's `nothing` is refused (an `ArgumentError`, Django's TypeError). With
`doseq`, each of a vector's (tuple's, range's, ...) values becomes its own `key=value`; without, the vector is written as
Python prints it (`[1, 2]`). (Django's `doseq` defaults to false: Juango's to true, as Julia's vectors have no
meaningful text.)
"""
function urlencode(data; doseq::Bool = true)
    parts = String[]
    none(k) = throw(ArgumentError("Cannot encode None for key '$(display_string(k))' in a query string. Did you mean to pass an empty string or omit the value?"))
    q(x) = quote_plus(x isa AbstractVector{UInt8} ? String(copy(x)) : display_string(x))
    seq(v) = !(v isa AbstractString) && !(v isa AbstractVector{UInt8}) &&
             (v isa AbstractVector || v isa Tuple || v isa AbstractSet || v isa AbstractRange || v isa Base.Generator)
    for (k, v) in pairs_of(data)
        v === nothing && none(k)
        if doseq && seq(v)
            for x in v
                x === nothing && none(k)
                push!(parts, q(k) * "=" * q(x))
            end
        else
            push!(parts, q(k) * "=" * q(seq(v) ? py_str(v) : v))
        end
    end
    join(parts, "&")
end
"Python's `quote_plus`: as `quote(s, safe = \"\")`, spaces as `+`."
quote_plus(s::AbstractString) = replace(py_quote(s, " "), " " => "+")
"Python's `str` of a list, tuple or range (`[1, 'a']`, `(1, 2)`, `range(0, 2)`); of anything else, its text."
py_str(v::AbstractRange) = step(v) == 1 ? "range($(first(v)), $(last(v) + 1))" : "range($(first(v)), $(last(v) + step(v)), $(step(v)))"
py_str(v::AbstractVector) = "[" * join((py_elem(x) for x in v), ", ") * "]"
py_str(v::Tuple) = "(" * join((py_elem(x) for x in v), ", ") * (length(v) == 1 ? ",)" : ")")
py_str(v) = display_string(v)
py_elem(x::AbstractString) = py_str_repr(x)
py_elem(x) = py_str(x)
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

"""
    safe_join(base, paths...) -> String

Django's `safe_join`: the absolute path of `paths` joined onto `base`, refusing (a 400, Django's SuspiciousFileOperation)
one that ends up outside `base` (`"../def"`).
"""
function safe_join(base::AbstractString, paths::AbstractString...)
    pyabs(p) = (a = normpath(abspath(p)); length(a) > 1 ? rstrip(a, '/') : a)        # (Python's abspath: no trailing /)
    final, b = pyabs(joinpath(base, paths...)), pyabs(base)
    sep = Base.Filesystem.path_separator
    (startswith(final, b * sep) || final == b || dirname(b) == b) ||
        throw(BadRequest("The joined path ($final) is located outside of the base path component ($b)"))
    String(final)
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

# --- debug toolbar recording (contrib/debugtoolbar.jl) ------------------------------------------
#
# Defined here because the query runner and the template engine, which are loaded before the
# toolbar, record into it.

"One SQL statement the debug toolbar recorded."
struct DebugQuery
    sql::String
    params::Vector{Any}
    seconds::Float64
    alias::String
    backtrace::Vector{Union{Ptr{Nothing},Base.InterpreterIP}}
    error::Union{Nothing,String}
    templates_started::Int                   # how many templates had started rendering when it ran
end

"One template the debug toolbar recorded: its name, how it was rendered and its context (already made safe to show)."
struct DebugTemplate
    name::String
    how::String                              # "render", "include" or "extends"
    context::Vector{Pair{String,String}}
end

"What the debug toolbar records while a request runs (on the request's task and the tasks it spawns)."
mutable struct DebugRecord
    const queries::Vector{DebugQuery}
    const templates::Vector{DebugTemplate}
    const lock::ReentrantLock
    const stacktraces::Bool
    info::Dict{Symbol,Any}                   # request, response and timing, filled in when the request is done
end
DebugRecord(stacktraces::Bool) = DebugRecord(DebugQuery[], DebugTemplate[], ReentrantLock(), stacktraces, Dict{Symbol,Any}())

"The current task's debug toolbar record, or `nothing` when nothing is recording."
current_debug_record() = get(task_local_storage(), :juango_debug, nothing)::Union{Nothing,DebugRecord}
