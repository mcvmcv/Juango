# HTTP caching headers, conditional requests and compression ------------------------------------------
#
#     never_cache(view)                              # Cache-Control: max-age=0, no-cache, no-store, ...
#     cache_control(view; max_age = 3600, public = true)
#     vary_on_headers(view, "Accept-Language")       vary_on_cookie(view)
#     etag(view, (req; kw...) -> post_version(kw[:id]))
#     last_modified(view, (req; kw...) -> latest(objects(Post), :updated).updated)
#     condition(view; etag_func, last_modified_func)
#
#     MIDDLEWARE = [GZipMiddleware, ConditionalGetMiddleware, ...]

# --- Cache-Control and Vary -----------------------------------------------------------------------

"Parse a Cache-Control header into directive => value (`true` for directives without a value)."
function parse_cache_control(s::AbstractString)
    d = Dict{String,Any}()
    for part in split(s, ','; keepempty = false)
        kv = split(strip(part), '='; limit = 2)
        isempty(kv[1]) && continue
        d[lowercase(kv[1])] = length(kv) == 2 ? strip(kv[2], '"') : true
    end
    d
end

"""
    patch_cache_control!(resp; max_age = 300, private = true, no_cache = true, ...)

Add Cache-Control directives to a response (underscores become dashes; `true` writes the
bare directive, `false` removes it). `max_age` keeps the smaller of the old and new values;
`public` and `private` replace each other.
"""
function patch_cache_control!(resp::HttpResponse; kw...)
    d = parse_cache_control(something(getheader(resp, "Cache-Control"), ""))
    for (k, v) in kw
        name = replace(string(k), '_' => '-')
        name == "private" && v === true && delete!(d, "public")
        name == "public" && v === true && delete!(d, "private")
        if v === false
            delete!(d, name)
        elseif name == "max-age" && haskey(d, "max-age")
            old = tryparse(Int, string(d["max-age"]))
            d[name] = old === nothing ? v : min(old, Int(v))
        else
            d[name] = v
        end
    end
    setheader!(resp, "Cache-Control", join([v === true ? k : "$k=$v" for (k, v) in sort!(collect(d); by = first)], ", "))
    resp
end

"""
    never_cache(view)

Tell browsers and proxies not to cache the view's responses.
"""
function never_cache(view)
    w = function (req; kw...)
        resp = to_response(view(req; kw...))
        patch_cache_control!(resp; max_age = 0, no_cache = true, no_store = true, must_revalidate = true, private = true)
        hasheader(resp, "Expires") || setheader!(resp, "Expires", http_date(now(Dates.UTC)))
        resp
    end
    propagate_flags!(w, view)
end

"""
    cache_control(view; max_age = 600, public = true, ...)
    cache_control(; directives...)(view)

Add Cache-Control directives to the view's responses (see `patch_cache_control!`).
"""
function cache_control(view; kw...)
    w = (req; vkw...) -> patch_cache_control!(to_response(view(req; vkw...)); kw...)
    propagate_flags!(w, view)
end
cache_control(; kw...) = view -> cache_control(view; kw...)

"""
    vary_on_headers(view, "Accept-Language", ...)    vary_on_cookie(view)

Add request headers to the responses' `Vary`, so caches keep a copy per value.
"""
function vary_on_headers(view, headers::AbstractString...)
    w = function (req; kw...)
        resp = to_response(view(req; kw...))
        foreach(h -> patch_vary!(resp, h), headers)
        resp
    end
    propagate_flags!(w, view)
end
vary_on_headers(headers::AbstractString...) = view -> vary_on_headers(view, headers...)
vary_on_cookie(view) = vary_on_headers(view, "Cookie")

# --- conditional requests (RFC 9110) ---------------------------------------------------------------

"A date in HTTP's format (`Sun, 06 Nov 1994 08:49:37 GMT`)."
http_date(t) = Dates.format(http_utc(t), Dates.RFC1123Format) * " GMT"
http_utc(t::DateTime) = t
http_utc(t::Date) = DateTime(t)
http_utc(t::TimeZones.ZonedDateTime) = DateTime(TimeZones.astimezone(t, UTC_TZ))
http_utc(t::Real) = Dates.unix2datetime(t)
function parse_http_date(s)
    s === nothing && return nothing
    s = strip(replace(s, r"\s*GMT\s*$" => ""))
    for f in (Dates.RFC1123Format, dateformat"e, dd-u-yy HH:MM:SS", dateformat"e u d HH:MM:SS yyyy")
        d = tryparse(DateTime, s, f)
        d === nothing || return d
    end
    nothing
end

quote_etag(e::AbstractString) = occursin(r"^(W/)?\".*\"$", e) ? String(e) : "\"" * replace(e, "\"" => "\\\"") * "\""
parse_etags(s) = [String(strip(m.match)) for m in eachmatch(r"(?:W/)?\"[^\"]*\"", s)]
strip_weak(e) = startswith(e, "W/") ? e[3:end] : e
etag_matches_weak(etag, header) = strip(header) == "*" || any(e -> strip_weak(e) == strip_weak(etag), parse_etags(header))
etag_matches_strong(etag, header) = strip(header) == "*" ||
    (!startswith(etag, "W/") && any(e -> !startswith(e, "W/") && e == etag, parse_etags(header)))

"""
The response a conditional request gets without running the view: 304 Not Modified, 412
Precondition Failed, or `nothing` to go on. `etag` (quoted) and `last_mod` (UTC) describe
the current version of the resource.
"""
function conditional_response(req::Request, etag, last_mod)
    im, ius = header(req, "if-match"), parse_http_date(header(req, "if-unmodified-since"))
    inm, ims = header(req, "if-none-match"), parse_http_date(header(req, "if-modified-since"))
    safe = req.method in ("GET", "HEAD")
    if im !== nothing
        (etag !== nothing && etag_matches_strong(etag, im)) || return precondition_failed()
    elseif ius !== nothing && last_mod !== nothing && floor(last_mod, Second) > ius
        return precondition_failed()
    end
    if inm !== nothing
        etag !== nothing && etag_matches_weak(etag, inm) && return safe ? not_modified(etag, last_mod) : precondition_failed()
    elseif ims !== nothing && safe && last_mod !== nothing && floor(last_mod, Second) <= ims
        return not_modified(etag, last_mod)
    end
    nothing
end
precondition_failed() = HttpResponse("<h1>Precondition Failed (412)</h1>"; status = 412)
function not_modified(etag, last_mod)
    r = HttpResponse(""; status = 304)
    etag === nothing || setheader!(r, "ETag", etag)
    last_mod === nothing || setheader!(r, "Last-Modified", http_date(last_mod))
    r
end

"""
    condition(view; etag_func = nothing, last_modified_func = nothing)

Answer conditional requests without running the view when the resource hasn't changed.
`etag_func(req; kw...)` returns a version string and `last_modified_func(req; kw...)` a
date (either may return `nothing`). Responses get the `ETag` and `Last-Modified` headers.
"""
function condition(view; etag_func = nothing, last_modified_func = nothing)
    w = function (req; kw...)
        e = etag_func === nothing ? nothing : etag_func(req; kw...)
        e === nothing || (e = quote_etag(string(e)))
        lm = last_modified_func === nothing ? nothing : last_modified_func(req; kw...)
        lm === nothing || (lm = http_utc(lm))
        early = conditional_response(req, e, lm)
        early === nothing || return early
        resp = to_response(view(req; kw...))
        if req.method in ("GET", "HEAD") && resp.status == 200
            e === nothing || hasheader(resp, "ETag") || setheader!(resp, "ETag", e)
            lm === nothing || hasheader(resp, "Last-Modified") || setheader!(resp, "Last-Modified", http_date(lm))
        end
        resp
    end
    propagate_flags!(w, view)
end
condition(; kw...) = view -> condition(view; kw...)
"`etag(view, etag_func)`: `condition` with only an ETag."
etag(view, f) = condition(view; etag_func = f)
etag(f) = view -> etag(view, f)
"`last_modified(view, func)`: `condition` with only a modification date."
last_modified(view, f) = condition(view; last_modified_func = f)
last_modified(f) = view -> last_modified(view, f)

"""
    ConditionalGetMiddleware

Gives successful GET responses an `ETag` (a hash of the body) when they have none, and
answers `If-None-Match` / `If-Modified-Since` with 304 Not Modified.
"""
function ConditionalGetMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        (req.method in ("GET", "HEAD") && resp.status == 200 && !is_streaming(resp)) || return resp
        occursin("no-store", lowercase(something(getheader(resp, "Cache-Control"), ""))) && return resp
        hasheader(resp, "ETag") || setheader!(resp, "ETag", "\"" * bytes2hex(sha256(resp.body))[1:32] * "\"")
        e = getheader(resp, "ETag")
        nm = conditional_response(req, e, parse_http_date(getheader(resp, "Last-Modified")))
        nm === nothing && return resp
        for h in ("Cache-Control", "Content-Location", "Date", "Expires", "Last-Modified", "Vary")
            v = getheader(resp, h)
            v === nothing || setheader!(nm, h, v)
        end
        append!(nm.cookies, resp.cookies)
        nm
    end
end

# --- gzip -------------------------------------------------------------------------------------------

const CRC32_TABLE = let t = Vector{UInt32}(undef, 256)
    for n in 0:255
        c = UInt32(n)
        for _ in 1:8
            c = (c & 1) != 0 ? 0xedb88320 ⊻ (c >> 1) : c >> 1
        end
        t[n+1] = c
    end
    t
end
function crc32(data::AbstractVector{UInt8})
    c = 0xffffffff
    @inbounds for b in data
        c = CRC32_TABLE[((c ⊻ b) & 0xff) + 1] ⊻ (c >> 8)
    end
    ~c
end
le32bytes(x::UInt32) = UInt8[x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, x >> 24]

"""
    gzip_compress(data; max_random_bytes = 100) -> bytes

A gzip file of `data`. Its header carries a file name of 1 to `max_random_bytes` random
letters, so the compressed length varies ("Heal the Breach", as Django does against BREACH).
"""
function gzip_compress(data::AbstractVector{UInt8}; max_random_bytes::Integer = 100)
    head = UInt8[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
    if max_random_bytes > 0
        head[4] = 0x08                                   # FNAME
        n = rand(RandomDevice(), 1:max_random_bytes)
        append!(head, UInt8.(rand(RandomDevice(), [UInt8('a'):UInt8('z'); UInt8('A'):UInt8('Z')], n)), UInt8[0])
    end
    vcat(head, transcode(CodecZlib.DeflateCompressor, Vector{UInt8}(data)), le32bytes(crc32(data)), le32bytes(UInt32(length(data) % 2^32)))
end

"""
    GZipMiddleware

Compress responses for clients that accept gzip: bodies of at least 200 bytes that aren't
compressed already or streamed. Adds `Vary: Accept-Encoding` and makes a strong ETag weak.
"""
function GZipMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        patch_vary!(resp, "Accept-Encoding")
        is_streaming(resp) && return resp
        (length(resp.body) < 200 || hasheader(resp, "Content-Encoding")) && return resp
        occursin(r"\bgzip\b"i, header(req, "accept-encoding", "")) || return resp
        z = gzip_compress(resp.body)
        length(z) >= length(resp.body) && return resp
        resp.body = z
        setheader!(resp, "Content-Encoding", "gzip")
        hasheader(resp, "Content-Length") && setheader!(resp, "Content-Length", string(length(z)))
        e = getheader(resp, "ETag")
        e === nothing || startswith(e, "W/") || setheader!(resp, "ETag", "W/" * e)
        resp
    end
end
