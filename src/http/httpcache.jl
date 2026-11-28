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
    for (k, v) in cache_control_entries(s)
        d[k] = v isa AbstractString ? strip(v, '"') : v
    end
    d
end
"A Cache-Control header's directives in order, as (lowercased name, raw value or `true`) pairs."
cache_control_entries(s::AbstractString) =
    [(lowercase(String(kv[1])), length(kv) == 2 ? String(kv[2]) : true)
     for kv in (split(strip(part), '='; limit = 2) for part in split(s, ','; keepempty = false)) if !isempty(kv[1])]

"""
    patch_cache_control!(resp; max_age = 300, private = true, no_cache = true, ...)

Add Cache-Control directives to a response, as Django's `patch_cache_control` (underscores become
dashes; `true` writes the bare directive, `false` removes it). Directives keep their order, new ones
are added at the end. `max_age` keeps the smaller of the old and new values; `public` and `private`
replace each other; `no_cache` may name fields (`no_cache = "Set-Cookie"`), which add up, and a bare
`no-cache` wins over them.
"""
function patch_cache_control!(resp::HttpResponse; kw...)
    names = String[]                       # the directives, in order
    vals = Dict{String,Any}()              # name => value; no-cache => a vector of values
    put!(k, v) = (k in names || push!(names, k);
                  k == "no-cache" ? push!(get!(() -> Any[], vals, k), v) : (vals[k] = v))
    foreach(((k, v),) -> put!(k, v), cache_control_entries(something(getheader(resp, "Cache-Control"), "")))
    haskey(kw, :public) && kw[:public] !== false && "private" in names && (filter!(!=("private"), names); delete!(vals, "private"))
    haskey(kw, :private) && kw[:private] !== false && "public" in names && (filter!(!=("public"), names); delete!(vals, "public"))
    for (k, v) in kw
        name = replace(string(k), '_' => '-')
        if v === false
            filter!(!=(name), names); delete!(vals, name)
        elseif name == "max-age" && haskey(vals, "max-age") && (old = tryparse(Int, string(vals["max-age"]))) !== nothing
            vals[name] = min(old, Int(v))
        else
            put!(name, v)
        end
    end
    parts = String[]
    for k in names
        v = vals[k]
        if k == "no-cache"
            any(x -> x === true, v) ? push!(parts, k) : append!(parts, ["$k=$x" for x in unique(v)])
        else
            push!(parts, v === true ? k : "$k=$v")
        end
    end
    setheader!(resp, "Cache-Control", join(parts, ", "))
    resp
end

"The response's Cache-Control max-age in seconds, or `nothing` (Django's `get_max_age`)."
function get_max_age(resp::HttpResponse)
    v = get(parse_cache_control(something(getheader(resp, "Cache-Control"), "")), "max-age", nothing)
    v === nothing ? nothing : tryparse(Int, string(v))
end

"""
    patch_response_headers!(resp; cache_timeout = settings.CACHE_MIDDLEWARE_SECONDS)

Django's `patch_response_headers`: an `Expires` header (unless there is one) and `max-age`, for
`cache_timeout` seconds (a negative one is 0).
"""
function patch_response_headers!(resp::HttpResponse; cache_timeout = nothing)
    t = max(0, round(Int, something(cache_timeout, settings.CACHE_MIDDLEWARE_SECONDS)))
    hasheader(resp, "Expires") || setheader!(resp, "Expires", http_date(now(Dates.UTC) + Second(t)))
    patch_cache_control!(resp; max_age = t)
end

"Headers that keep a response out of every cache (Django's `add_never_cache_headers`)."
add_never_cache_headers!(resp::HttpResponse) =
    patch_cache_control!(patch_response_headers!(resp; cache_timeout = -1); no_cache = true, no_store = true, must_revalidate = true, private = true)

"""
    never_cache(view)

Tell browsers and proxies not to cache the view's responses.
"""
function never_cache(view)
    w = (req; kw...) -> add_never_cache_headers!(to_response(view(req; kw...)))
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
const HTTP_MONTHS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
const RFC1123_DATE = r"^\w{3}, (?<day>[0-9]{2}) (?<mon>\w{3}) (?<year>[0-9]{4}) (?<hour>[0-9]{2}):(?<min>[0-9]{2}):(?<sec>[0-9]{2}) GMT$"
const RFC850_DATE = r"^\w{6,9}, (?<day>[0-9]{2})-(?<mon>\w{3})-(?<year>[0-9]{2}) (?<hour>[0-9]{2}):(?<min>[0-9]{2}):(?<sec>[0-9]{2}) GMT$"
const ASCTIME_DATE = r"^\w{3} (?<mon>\w{3}) (?<day>[ 0-9][0-9]) (?<hour>[0-9]{2}):(?<min>[0-9]{2}):(?<sec>[0-9]{2}) (?<year>[0-9]{4})$"
"""
    parse_http_date(s; now = Dates.now(Dates.UTC)) -> DateTime or nothing

A date in one of HTTP's three formats (RFC 9110: `Sun, 06 Nov 1994 08:49:37 GMT`, `Sunday, 06-Nov-94 08:49:37 GMT`,
`Sun Nov  6 08:49:37 1994`), as Django's, in UTC. A two-digit year is the one within 50 years of `now`'s. Nothing for
anything else (Django's `parse_http_date_safe`; its `parse_http_date` raises).
"""
function parse_http_date(s; now::DateTime = Dates.now(Dates.UTC))
    s === nothing && return nothing
    s = String(s)
    m = nothing
    for re in (RFC1123_DATE, RFC850_DATE, ASCTIME_DATE)
        m = match(re, s)
        m === nothing || break
    end
    m === nothing && return nothing
    year = parse(Int, m[:year])
    if year < 100
        cy = Dates.year(now)
        century = cy - cy % 100
        year += year - cy % 100 > 50 ? century - 100 : century
    end
    mon = findfirst(==(lowercase(m[:mon])), HTTP_MONTHS)
    mon === nothing && return nothing
    try
        DateTime(year, mon, parse(Int, strip(m[:day])), parse(Int, m[:hour]), parse(Int, m[:min]), parse(Int, m[:sec]))
    catch
        nothing
    end
end

const ETAG_MATCH = r"^((?:W/)?\"[^\"]*\")$"
"Django's `quote_etag`: an ETag as it is when it's quoted already (`W/\"x\"`), else in quotes, a strong one."
quote_etag(e::AbstractString) = occursin(ETAG_MATCH, e) ? String(e) : "\"" * e * "\""
"""
Django's `parse_etags`: an If-None-Match or If-Match header's ETags, as written (quoted, `W/` for weak ones), or `["*"]`;
those that aren't valid ETags (RFC 9110: no quotes inside) are left out.
"""
function parse_etags(s)
    strip(s) == "*" && return ["*"]
    String[m[1] for m in (match(ETAG_MATCH, e) for e in split_header_value(s)) if m !== nothing]
end
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
"CRC-32 of `data`; pass the previous result as `crc` to continue over several chunks."
function crc32(data::AbstractVector{UInt8}, crc::UInt32 = 0x00000000)
    c = ~crc
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
    vcat(gzip_header(max_random_bytes), transcode(CodecZlib.DeflateCompressor, Vector{UInt8}(data)),
         le32bytes(crc32(data)), le32bytes(UInt32(length(data) % 2^32)))
end
function gzip_header(max_random_bytes::Integer)
    head = UInt8[0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff]
    if max_random_bytes > 0
        head[4] = 0x08                                   # FNAME
        n = rand(RandomDevice(), 1:max_random_bytes)
        append!(head, UInt8.(rand(RandomDevice(), [UInt8('a'):UInt8('z'); UInt8('A'):UInt8('Z')], n)), UInt8[0])
    end
    head
end

"Run raw deflate over `data` with `flush` (sync flush or finish) and return what zlib produced."
function deflate_chunk!(z::CodecZlib.ZStream, data::Vector{UInt8}, buf::Vector{UInt8}, flush::Cint)
    out = UInt8[]
    GC.@preserve data buf begin
        z.next_in = pointer(data)
        z.avail_in = length(data)
        while true
            z.next_out = pointer(buf)
            z.avail_out = length(buf)
            code = CodecZlib.deflate!(z, flush)
            code in (CodecZlib.Z_OK, CodecZlib.Z_STREAM_END, CodecZlib.Z_BUF_ERROR) || error("zlib deflate failed ($code)")
            append!(out, view(buf, 1:length(buf)-Int(z.avail_out)))
            (flush == CodecZlib.Z_FINISH ? code == CodecZlib.Z_STREAM_END : z.avail_out != 0) && break
        end
    end
    out
end

"""
    gzip_stream(body::StreamBody; max_random_bytes = 100) -> StreamBody

A streaming body compressed as one gzip file, chunk by chunk: each chunk is flushed
(`Z_SYNC_FLUSH`), so it still goes out as soon as the view produces it.
"""
function gzip_stream(sb::StreamBody; max_random_bytes::Integer = 100)
    StreamBody(Pair{Symbol,Any}[]) do io
        z = CodecZlib.ZStream()
        code = CodecZlib.deflate_init!(z, CodecZlib.Z_DEFAULT_COMPRESSION, -15)     # raw deflate: our own header
        code == CodecZlib.Z_OK || error("zlib deflateInit failed ($code)")
        buf = Vector{UInt8}(undef, 16 * 1024)
        crc, len = 0x00000000, UInt32(0)
        try
            write(io, gzip_header(max_random_bytes))
            each_chunk(sb) do b
                crc = crc32(b, crc)
                len += length(b) % UInt32
                out = deflate_chunk!(z, b, buf, CodecZlib.Z_SYNC_FLUSH)
                isempty(out) || write(io, out)
            end
            write(io, vcat(deflate_chunk!(z, UInt8[], buf, CodecZlib.Z_FINISH), le32bytes(crc), le32bytes(len)))
        finally
            CodecZlib.deflate_end!(z)
        end
    end
end


"""
    GZipMiddleware

Compress responses for clients that accept gzip: bodies of at least 200 bytes, and streaming
responses chunk by chunk, unless they are compressed already. Adds `Vary: Accept-Encoding`
and makes a strong ETag weak.
"""
function GZipMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        patch_vary!(resp, "Accept-Encoding")
        (hasheader(resp, "Content-Encoding") || resp.status == 206) && return resp     # not a byte range either
        streaming = is_streaming(resp)
        streaming || length(resp.body) >= 200 || return resp
        occursin(r"\bgzip\b"i, header(req, "accept-encoding", "")) || return resp
        if streaming
            resp.stream = gzip_stream(resp.stream)
            filter!(h -> !header_eq(h.first, "Content-Length"), resp.headers)
        else
            z = gzip_compress(resp.body)
            length(z) >= length(resp.body) && return resp
            resp.body = z
            hasheader(resp, "Content-Length") && setheader!(resp, "Content-Length", string(length(z)))
        end
        setheader!(resp, "Content-Encoding", "gzip")
        e = getheader(resp, "ETag")
        e === nothing || startswith(e, "W/") || setheader!(resp, "ETag", "W/" * e)
        resp
    end
end
