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

"The name `{% static %}` serves for a path: hashed under manifest storage (unless DEBUG)."
function stored_static_name(p::AbstractString)
    (manifest_storage() && !settings.DEBUG) || return p
    clean = first(split(p, r"[?#]"))
    suffix = p[ncodeunits(clean)+1:end]
    h = get(static_manifest(), clean, nothing)
    h === nothing && throw(ImproperlyConfigured("missing staticfiles manifest entry for '$clean' (run collectstatic)"))
    h * suffix
end

hashed_name(name, content) = (parts = splitext(name); parts[1] * "." * bytes2hex(sha256(content))[1:12] * parts[2])

const CSS_URL_RE = r"""(url\(\s*(['"]?)\s*)([^'")\s]+)(\s*\2\s*\))|(@import\s*(['"]))([^'"]+)(['"])"""

"Rewrite a CSS file's references to other static files with their hashed names."
function rewrite_css(content::String, name::String, hashed::Dict{String,String})
    dir = dirname(name)
    replace(content, CSS_URL_RE => function (m)
        mm = match(CSS_URL_RE, m)
        pre, ref, post = mm[1] !== nothing ? (mm[1], mm[3], mm[4]) : (mm[5], mm[7], mm[8])
        (startswith(ref, "data:") || startswith(ref, "#") || occursin(r"^[a-z]+:|^//"i, ref)) && return m
        target, frag = (i = findfirst(r"[?#]", ref); i === nothing ? (ref, "") : (ref[1:first(i)-1], ref[first(i):end]))
        abs_ = startswith(target, "/") ? lstrip(replace(target, settings.STATIC_URL => "/"; count = 1), '/') :
                                          normpath(joinpath(dir, target))
        abs_ = replace(abs_, '\\' => '/')
        h = get(hashed, abs_, nothing)
        h === nothing && return m
        newref = startswith(target, "/") ? settings.STATIC_URL * h : relpath(h, isempty(dir) ? "." : dir)
        pre * replace(newref, '\\' => '/') * frag * post
    end)
end

"Add hashed copies of the collected files in `root` and write the manifest (called by `collectstatic`)."
function post_process_manifest!(root::AbstractString, names::Vector{String})
    hashed = Dict{String,String}()
    css = sort([n for n in names if endswith(lowercase(n), ".css")])
    for n in names
        endswith(lowercase(n), ".css") && continue
        h = hashed_name(n, read(joinpath(root, n)))
        cp(joinpath(root, n), joinpath(root, h); force = true)
        hashed[n] = h
    end
    # CSS refers to other files (CSS too): rewrite and hash until the names settle
    for _ in 1:5
        changed = false
        for n in css
            content = rewrite_css(read(joinpath(root, n), String), n, hashed)
            h = hashed_name(n, codeunits(content))
            if get(hashed, n, nothing) != h
                old = get(hashed, n, nothing)
                old === nothing || rm(joinpath(root, old); force = true)
                write(joinpath(root, h), content)
                hashed[n] = h
                changed = true
            end
        end
        changed || break
    end
    write(joinpath(root, MANIFEST_NAME), JSON.json(Dict("paths" => hashed, "version" => "1.1")))
    MANIFEST_CACHE[] = nothing
    hashed
end
