# Hashed static files (ManifestStaticFilesStorage) -------------------------------------------------------
#
#     configure!(STATICFILES_STORAGE = :manifest, STATIC_ROOT = "staticfiles")
#     collectstatic()          # css/site.css -> also css/site.55e7cbb9ba48.css, plus staticfiles.json
#
# With DEBUG off, `{% static "css/site.css" %}` then gives the hashed name, so browsers can cache
# static files forever and still get new versions. CSS `url(...)` and `@import` references are
# rewritten to the hashed names too.

function manifest_storage()
    conf = get(settings, :STORAGES, nothing)
    entry = conf === nothing ? nothing : get(conf, "staticfiles", get(conf, :staticfiles, nothing))
    entry === nothing && return get(settings, :STATICFILES_STORAGE, :plain) === :manifest
    get(entry, :BACKEND, get(entry, "BACKEND", :static)) === :manifest
end
const MANIFEST_NAME = "staticfiles.json"
const MANIFEST_CACHE = Ref{Union{Nothing,Tuple{String,Float64,Dict{String,String}}}}(nothing)

"The manifest's original name => hashed name map (cached until the file changes)."
function static_manifest()
    f = joinpath(string(settings.STATIC_ROOT), MANIFEST_NAME)
    isfile(f) || throw(ImproperlyConfigured("no $MANIFEST_NAME in STATIC_ROOT; run collectstatic"))
    c = MANIFEST_CACHE[]
    (c !== nothing && c[1] == f && c[2] == mtime(f)) && return c[3]
    d = JSON.parse(read(f, String))
    paths = Dict{String,String}(string(k) => string(v) for (k, v) in d["paths"])
    MANIFEST_CACHE[] = (f, mtime(f), paths)
    paths
end

"The name `{% static %}` serves for a path: hashed under manifest storage (unless DEBUG); a directory (\"path/\") as it is."
function stored_static_name(p::AbstractString)
    (manifest_storage() && !settings.DEBUG) || return p
    clean = first(split(p, r"[?#]"))
    endswith(clean, "/") && return p
    suffix = p[ncodeunits(clean)+1:end]
    h = get(static_manifest(), clean, nothing)
    h === nothing && throw(ImproperlyConfigured("Missing staticfiles manifest entry for '$clean'"))
    h * suffix
end

hashed_name(name, content) = (parts = splitext(name); parts[1] * "." * bytes2hex(sha256(content))[1:12] * parts[2])

# The references post-processing rewrites (Django's HashedFilesMixin.patterns): CSS url() (written back as
# url("...")), @import "..." (as @import url("...")) and source maps, JS source maps; each skips what's inside a
# comment or a string (Django's ignored blocks).
const CSS_IGNORED_RE = r"/\*.*?\*/|\\.|'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\""s
const JS_IGNORED_RE = r"/\*.*?\*/|//[^\n]*|\\.|'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"|`(?:[^`\\]|\\.)*`"s
const STATIC_PATTERNS = Dict(
    ".css" => [(r"""(?<matched>url\((?<quote>['"]{0,1})\s*(?<url>.*?)\k<quote>\))"""i, "url(\"%s\")", CSS_IGNORED_RE),
               (r"""(?<matched>@import\s*["']\s*(?<url>.*?)["'])"""i, "@import url(\"%s\")", CSS_IGNORED_RE),
               (r"(?m)^(?<matched>/\*#[ \t](?-i:sourceMappingURL)=(?<url>.*?)[ \t]*\*/)$"i, "/*# sourceMappingURL=%s */", CSS_IGNORED_RE)],
    ".js" => [(r"(?m)^(?<matched>//# (?-i:sourceMappingURL)=(?<url>.*?))[ \t]*$"i, "//# sourceMappingURL=%s", JS_IGNORED_RE)])
adjustable(name) = haskey(STATIC_PATTERNS, lowercase(splitext(name)[2]))

"A reference post-processing couldn't follow: the file isn't among the collected ones."
struct MissingStaticReference <: Exception
    name::String
    msg::String
end
Base.showerror(io::IO, e::MissingStaticReference) = print(io, e.msg)

"""
Rewrite a file's references to other static files with their hashed names, as Django's url_converter: the
path as written with the last part hashed, the fragment kept; URLs, data: and other schemes, #fragments, and
absolute paths outside STATIC_URL are left alone. `lookup(target)` gives a collected file's hashed name, or
`nothing` when there's no such file.
"""
function rewrite_static(content::String, name::String, lookup; strict::Bool = false)
    ext = lowercase(splitext(name)[2])
    dir = dirname(name)
    for (rx, template, ignored) in get(STATIC_PATTERNS, ext, Any[])
        blocks = [(m.offset, m.offset + ncodeunits(m.match)) for m in eachmatch(ignored, content)]
        in_block(pos) = any(b -> b[1] < pos < b[2], blocks)
        out = IOBuffer()
        last = 1
        for m in eachmatch(rx, content)
            matched, url = m[:matched], m[:url]
            print(out, SubString(content, last, prevind(content, m.offset)))
            last = m.offset + ncodeunits(m.match)
            keep() = print(out, m.match)
            if in_block(m.offset) || occursin(r"^[a-z]+:"i, url) || startswith(url, "//") || startswith(url, "#") ||
               (startswith(url, "/") && !startswith(url, settings.STATIC_URL))
                keep(); continue
            end
            i = findfirst('#', url)
            url_path, fragment = i === nothing ? (url, "") : (url[1:prevind(url, i)], url[nextind(url, i):end])
            isempty(url_path) && (keep(); continue)
            qi = findfirst('?', url_path)
            path_only, query = qi === nothing ? (url_path, "") : (url_path[1:prevind(url_path, qi)], url_path[qi:end])
            query == "?" && occursin("?#", url) && (query = "")        # ("font.eot?#iefix": the ?# is put back below)
            target = startswith(path_only, "/") ? path_only[ncodeunits(settings.STATIC_URL)+1:end] :
                     replace(normpath(joinpath(isempty(dir) ? "." : dir, URIs.unescapeuri(path_only))), '\\' => '/')
            h = lookup(target)
            if h === nothing
                strict && throw(MissingStaticReference(name, "The file '$target' could not be found ('$name' contains this reference '$matched')."))
                @warn "collectstatic: '$name' refers to '$target', which isn't a static file; left as it is."
                keep(); continue
            end
            parts = split(path_only, '/')
            parts[end] = basename(h)
            t = join(parts, '/') * query
            isempty(fragment) || (t *= (occursin("?#", url) ? "?#" : "#") * fragment)
            print(out, replace(m.match, matched => replace(template, "%s" => t)))
        end
        print(out, SubString(content, last))
        content = String(take!(out))
    end
    content
end
"Kept for callers of the CSS-only version: CSS references rewritten from a name => hashed name map."
rewrite_css(content::String, name::String, hashed::Dict{String,String}) = rewrite_static(content, name, t -> get(hashed, t, nothing))

"""
Add hashed copies of the collected files in `root` and write the manifest (called by `collectstatic`), as
Django's ManifestStaticFilesStorage: other files are hashed as they are; CSS and JS have their references
rewritten first, in passes until the names settle (`STATICFILES_MAX_POST_PROCESS_PASSES`, 5: more is an
error, a reference loop). `STATICFILES_STRICT_REFERENCES = true` makes a reference to a missing file an
error, as Django's; by default it's left as it is, with a warning.
"""
function post_process_manifest!(root::AbstractString, names::Vector{String})
    hashed = Dict{String,String}()
    strict = get(settings, :STATICFILES_STRICT_REFERENCES, false) === true
    adj = sort([n for n in names if adjustable(n)])
    nameset = Set(names)
    for n in names
        adjustable(n) && continue
        h = hashed_name(n, read(joinpath(root, n)))
        cp(joinpath(root, n), joinpath(root, h); force = true)
        hashed[n] = h
    end
    # (a file not hashed yet: its name from what it holds now; the next pass corrects it)
    lookup(t) = haskey(hashed, t) ? hashed[t] : t in nameset || isfile(joinpath(root, t)) ? hashed_name(t, read(joinpath(root, t))) : nothing
    settled = false
    unresolved = String[]
    for _ in 1:get(settings, :STATICFILES_MAX_POST_PROCESS_PASSES, 5)
        changed = false
        unresolved = String[]
        for n in adj
            content = rewrite_static(read(joinpath(root, n), String), n, lookup; strict = strict)
            h = hashed_name(n, codeunits(content))
            if get(hashed, n, nothing) != h
                old = get(hashed, n, nothing)
                old === nothing || rm(joinpath(root, old); force = true)
                write(joinpath(root, h), content)
                hashed[n] = h
                changed = true
                push!(unresolved, n)
            end
        end
        changed || (settled = true; break)
    end
    settled || throw(PostProcessError(join(sort(unresolved), ", "), "Max post-process passes exceeded."))
    write(joinpath(root, MANIFEST_NAME), JSON.json(Dict("paths" => hashed, "version" => "1.1")))
    MANIFEST_CACHE[] = nothing
    hashed
end
"A failure post-processing these files (Django's \"Post-processing '...' failed!\")."
struct PostProcessError <: Exception
    paths::String
    msg::String
end
Base.showerror(io::IO, e::PostProcessError) = print(io, e.msg)

# --- serving STATIC_ROOT in production (WhiteNoise built in) -----------------------------------------
#
#     configure!(DEBUG = false, SERVE_STATIC = true, STATICFILES_STORAGE = :manifest, STATIC_ROOT = "staticfiles")
#     manage.jl collectstatic        # copies, hashed names, and .gz copies of text files
#
# Juango then serves STATIC_URL from STATIC_ROOT itself, so no nginx or CDN is needed in front:
# hashed names (css/site.55e7cbb9ba48.css) are cached for a year as immutable, others get a short
# max-age and an ETag (304 when unchanged); clients that accept gzip get the .gz copy; byte ranges
# work; small files are kept in memory.

"Extensions worth a .gz copy (text; images and archives are compressed already)."
const COMPRESSIBLE_STATIC = (".css", ".js", ".mjs", ".map", ".json", ".svg", ".txt", ".html", ".htm", ".xml", ".csv", ".ico", ".wasm", ".ttf", ".otf", ".eot")
const HASHED_NAME_RE = r"\.[0-9a-f]{12}\.[A-Za-z0-9]+$"

"Write `.gz` copies of the compressible files under `root` (smaller ones than 256 bytes aren't worth it); returns how many."
function compress_static!(root::AbstractString)
    n = 0
    for (dir, _, files) in walkdir(root), f in files
        lowercase(splitext(f)[2]) in COMPRESSIBLE_STATIC || continue
        p = joinpath(dir, f)
        data = read(p)
        length(data) < 256 && continue
        z = gzip_compress(data; max_random_bytes = 0)
        length(z) < length(data) || continue
        write(p * ".gz", z)
        n += 1
    end
    n
end

struct StaticEntry
    mtime::Float64
    size::Int
    etag::String
    data::Union{Nothing,Vector{UInt8}}      # in memory when small
    gz::Union{Nothing,Vector{UInt8}}
    gzpath::Union{Nothing,String}
end
const STATIC_CACHE = Dict{String,StaticEntry}()
const STATIC_CACHE_LOCK = ReentrantLock()

function static_entry(p::String)
    st = stat(p)
    lock(STATIC_CACHE_LOCK) do
        e = get(STATIC_CACHE, p, nothing)
        e !== nothing && e.mtime == st.mtime && e.size == st.size && return e
        small = st.size <= something(get(SETTINGS, :STATIC_MAX_MEMORY_FILE, 1_048_576), 0)
        gzp = isfile(p * ".gz") ? p * ".gz" : nothing
        e = StaticEntry(st.mtime, st.size, "\"" * string(st.size, base = 16) * "-" * string(round(Int, st.mtime * 1000), base = 16) * "\"",
                        small ? read(p) : nothing, small && gzp !== nothing ? read(gzp) : nothing, gzp)
        STATIC_CACHE[p] = e
        e
    end
end

"""
    serve_static_root(req) -> HttpResponse

Serve a file of STATIC_ROOT for STATIC_URL (`SERVE_STATIC = true`; DEBUG off): see the comment above.
"""
function serve_static_root(req::Request)
    req.method in ("GET", "HEAD") || return HttpResponseNotAllowed(["GET", "HEAD"])
    root = normpath(abspath(string(settings.STATIC_ROOT)))
    rel = URIs.unescapeuri(req.path[ncodeunits(settings.STATIC_URL)+1:end])
    p = normpath(joinpath(root, rel))
    (startswith(p, root * Base.Filesystem.path_separator) && isfile(p) && !endswith(p, ".gz")) || throw(Http404("Static file '$rel' not found"))
    e = static_entry(p)
    ext = lowercase(splitext(p)[2])
    ctype = get(MIME_TYPES, ext, "application/octet-stream")
    headers = Pair{String,String}["ETag" => e.etag,
        "Cache-Control" => occursin(HASHED_NAME_RE, basename(p)) ? "public, max-age=31536000, immutable" :
                           "public, max-age=$(something(get(SETTINGS, :STATIC_MAX_AGE, 60), 0))",
        "Accept-Ranges" => "bytes"]
    e.gzpath === nothing || push!(headers, "Vary" => "Accept-Encoding")
    inm = header(req, "if-none-match", nothing)
    if inm !== nothing && (strip(inm) == "*" || e.etag in strip.(split(inm, ',')))
        r = HttpResponse(""; status = 304)
        filter!(h -> !header_eq(h.first, "Content-Type"), r.headers)
        foreach(h -> setheader!(r, h.first, h.second), headers)
        return r
    end
    rng = header(req, "range", nothing)
    if rng !== nothing && (m = match(r"^bytes=(\d*)-(\d*)$", strip(rng))) !== nothing
        a, b = m[1], m[2]
        first_, last_ = isempty(a) ? (max(0, e.size - parse(Int, b)), e.size - 1) :
                        (parse(Int, a), isempty(b) ? e.size - 1 : min(parse(Int, b), e.size - 1))
        if isempty(a) && isempty(b) || first_ > last_ || first_ >= e.size
            r = HttpResponse(""; status = 416)
            setheader!(r, "Content-Range", "bytes */$(e.size)")
            return r
        end
        body = e.data !== nothing ? e.data[first_+1:last_+1] : open(io -> (seek(io, first_); read(io, last_ - first_ + 1)), p)
        r = HttpResponse(body; status = 206, content_type = ctype)
        setheader!(r, "Content-Range", "bytes $first_-$last_/$(e.size)")
        foreach(h -> setheader!(r, h.first, h.second), headers)
        return r
    end
    gz = e.gzpath !== nothing && occursin(r"\bgzip\b"i, header(req, "accept-encoding", ""))
    r = if gz
        HttpResponse(something(e.gz, read(e.gzpath)); content_type = ctype)
    elseif e.data !== nothing
        HttpResponse(e.data; content_type = ctype)
    else
        FileResponse(p; content_type = ctype)
    end
    gz && setheader!(r, "Content-Encoding", "gzip")
    foreach(h -> setheader!(r, h.first, h.second), headers)
    r
end
