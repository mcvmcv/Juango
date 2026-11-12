# File storage, FileField and ImageField ---------------------------------------------------------------
#
#     @model struct Document
#         title = CharField(max_length = 100)
#         file  = FileField(upload_to = "docs/%Y/%m/", validators = [FileExtensionValidator(["pdf"])])
#         photo = ImageField(upload_to = "photos/", blank = true)
#     end
#     form = ModelForm(Document; data = req.POST, files = req.FILES)    # enctype="multipart/form-data"
#     doc.file.url, doc.file.size, doc.photo.width
#
# Files are stored by a Storage (`FileSystemStorage` under `MEDIA_ROOT`, served at `MEDIA_URL`);
# the database column holds the stored name. Assign an `UploadedFile` (from `req.FILES`) to a
# file field and `save!` stores it.

"""
A place to keep files. A storage implements `save_file(s, name, bytes) -> stored name`,
`Base.read(s, name)`, `exists(s, name)`, `Base.size(s, name)`, `delete_file(s, name)` and
`url(s, name)`, and optionally `path(s, name)` (a local file path) and `listdir(s, dir)`.
Juango has `FileSystemStorage` and `InMemoryStorage`; others (e.g. a cloud bucket) plug in
by defining those methods and being named in the `STORAGES` setting.
"""
abstract type Storage end

"""
    FileSystemStorage(location=settings.MEDIA_ROOT, base_url=settings.MEDIA_URL)

Files on disk under `location`, with URLs under `base_url`. Names are sanitised and kept
inside `location`; an existing name gets a random suffix instead of being overwritten.
"""
struct FileSystemStorage <: Storage
    location::Union{Nothing,String}
    base_url::Union{Nothing,String}
end
FileSystemStorage(; location = nothing, base_url = nothing) = FileSystemStorage(location, base_url)
FileSystemStorage(location::AbstractString, base_url = nothing) = FileSystemStorage(String(location), base_url)

"""
    InMemoryStorage(; base_url = settings.MEDIA_URL)

Files kept in memory (for tests: nothing touches the disk). Like Django's `InMemoryStorage`.
"""
struct InMemoryStorage <: Storage
    files::Dict{String,Vector{UInt8}}
    base_url::Union{Nothing,String}
    lock::ReentrantLock
end
InMemoryStorage(; base_url = nothing, location = nothing) = InMemoryStorage(Dict{String,Vector{UInt8}}(), base_url, ReentrantLock())

memname(name) = (n = valid_path(name); isempty(n) ? throw(ArgumentError("'$name' is not a valid file name")) : n)
exists(s::InMemoryStorage, name) = lock(() -> haskey(s.files, memname(name)), s.lock)
Base.read(s::InMemoryStorage, name) = lock(s.lock) do
    get(() -> throw(SystemError("no file '$name' in InMemoryStorage", 2)), s.files, memname(name))
end
Base.size(s::InMemoryStorage, name) = length(read(s, name))
delete_file(s::InMemoryStorage, name) = lock(() -> (delete!(s.files, memname(name)); nothing), s.lock)
path(::InMemoryStorage, name) = throw(ArgumentError("InMemoryStorage files have no path on disk"))
url(s::InMemoryStorage, name) = rstrip(something(s.base_url, string(settings.MEDIA_URL)), '/') * "/" *
                                join(URIs.escapeuri.(split(name, '/')), "/")
function save_file(s::InMemoryStorage, name::AbstractString, data::AbstractVector{UInt8})
    name = valid_path(name)
    isempty(name) && (name = "file")
    stem, ext = splitext(name)
    lock(s.lock) do
        candidate = name
        while haskey(s.files, candidate)
            candidate = stem * "_" * random_string(7) * ext
        end
        s.files[candidate] = Vector{UInt8}(data)
        candidate
    end
end

"""
    listdir(storage, dir = "") -> (directories, files)

The subdirectories and files directly inside `dir`.
"""
function listdir(s::FileSystemStorage, dir::AbstractString = "")
    p = path(s, isempty(dir) ? "." : dir)
    isdir(p) || return (String[], String[])
    names = readdir(p)
    (filter(n -> isdir(joinpath(p, n)), names), filter(n -> isfile(joinpath(p, n)), names))
end
function listdir(s::InMemoryStorage, dir::AbstractString = "")
    prefix = isempty(dir) ? "" : rstrip(valid_path(dir), '/') * "/"
    dirs, files = Set{String}(), String[]
    lock(s.lock) do
        for k in keys(s.files)
            startswith(k, prefix) || continue
            rest = k[ncodeunits(prefix)+1:end]
            i = findfirst('/', rest)
            i === nothing ? push!(files, rest) : push!(dirs, rest[1:i-1])
        end
    end
    (sort!(collect(dirs)), sort!(files))
end

# --- the STORAGES setting ---------------------------------------------------------------------------
#
#     configure!(STORAGES = Dict(
#         "default"     => Dict(:BACKEND => FileSystemStorage, :OPTIONS => Dict(:location => "/srv/media")),
#         "staticfiles" => Dict(:BACKEND => :manifest),
#         "avatars"     => Dict(:BACKEND => InMemoryStorage),
#     ))
#
# A BACKEND is a Storage value, a type or function called with the OPTIONS as keywords, or
# one of the names :filesystem, :memory; for "staticfiles" also :static (plain copies) and
# :manifest (hashed names, see staticfiles.jl). `storages("name")` returns the instance.

const STORAGE_CACHE = Dict{String,Tuple{Any,Any}}()     # name => (setting entry, instance)
const STORAGE_LOCK = ReentrantLock()

function make_storage(name, entry)
    backend = get(entry, :BACKEND, get(entry, "BACKEND", :filesystem))
    opts = get(entry, :OPTIONS, get(entry, "OPTIONS", Dict{Symbol,Any}()))
    kw = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(opts))
    backend isa Storage && return backend
    backend === :filesystem && return FileSystemStorage(; kw...)
    backend === :memory && return InMemoryStorage(; kw...)
    if backend in (:static, :manifest)
        name == "staticfiles" || throw(ImproperlyConfigured("STORAGES[\"$name\"]: :$backend is for \"staticfiles\""))
        return FileSystemStorage(; location = get(kw, :location, string(settings.STATIC_ROOT)),
                                   base_url = get(kw, :base_url, string(settings.STATIC_URL)))
    end
    backend isa Symbol && throw(ImproperlyConfigured("STORAGES[\"$name\"]: unknown backend :$backend"))
    s = backend(; kw...)
    s isa Storage || throw(ImproperlyConfigured("STORAGES[\"$name\"]: the backend made a $(typeof(s)), not a Storage"))
    s
end

"""
    storages(name = "default") -> Storage

The storage configured as `name` in the `STORAGES` setting (one instance per configuration,
so an `InMemoryStorage` keeps its files). Without `STORAGES["default"]`, `default` is
`DEFAULT_FILE_STORAGE` or a `FileSystemStorage` under `MEDIA_ROOT`.
"""
function storages(name::AbstractString = "default")
    conf = get(settings, :STORAGES, nothing)
    entry = conf === nothing ? nothing : get(conf, name, get(conf, Symbol(name), nothing))
    if entry === nothing
        name == "default" && return something(settings.DEFAULT_FILE_STORAGE, FileSystemStorage())
        name == "staticfiles" && return FileSystemStorage(; location = string(settings.STATIC_ROOT), base_url = string(settings.STATIC_URL))
        throw(ImproperlyConfigured("no storage \"$name\" in STORAGES"))
    end
    lock(STORAGE_LOCK) do
        cached = get(STORAGE_CACHE, name, nothing)
        cached !== nothing && cached[1] === entry && return cached[2]
        s = make_storage(name, entry)
        STORAGE_CACHE[name] = (entry, s)
        s
    end
end

"The storage files are saved to: `STORAGES[\"default\"]`, else `DEFAULT_FILE_STORAGE`, else a `FileSystemStorage`."
default_storage() = storages("default")

function root(s::FileSystemStorage)
    loc = something(s.location, string(settings.MEDIA_ROOT))
    isempty(loc) && throw(ImproperlyConfigured("set MEDIA_ROOT (a directory for uploaded files) to use file fields"))
    normpath(abspath(loc))
end

"""
A safe file name: no directories, `..` or control characters; spaces become underscores and
anything but letters, digits, `-`, `_` and `.` is dropped.
"""
function get_valid_name(name::AbstractString)
    s = basename(replace(strip(name), '\\' => '/'))
    s = replace(s, r"\s+" => "_")
    s = replace(s, r"[^\w.\-]" => "")
    s = lstrip(s, '.')
    isempty(s) ? "file" : s
end
valid_path(name) = join([get_valid_name(p) for p in split(replace(name, '\\' => '/'), '/') if !isempty(p) && p != "." && p != ".."], "/")

"Absolute path of a stored name, refusing anything outside the storage root."
function path(s::FileSystemStorage, name::AbstractString)
    r = root(s)
    p = normpath(joinpath(r, name))
    (p == r || startswith(p, rstrip(r, '/') * "/")) || throw(ArgumentError("'$name' is outside the storage location"))
    p
end

exists(s::FileSystemStorage, name) = isfile(path(s, name))
Base.size(s::FileSystemStorage, name) = filesize(path(s, name))
Base.read(s::FileSystemStorage, name) = read(path(s, name))
"Delete a stored file (no error if it is already gone)."
delete_file(s::FileSystemStorage, name) = (p = path(s, name); isfile(p) && rm(p); nothing)
url(s::FileSystemStorage, name) = rstrip(something(s.base_url, string(settings.MEDIA_URL)), '/') * "/" *
                                  join(URIs.escapeuri.(split(name, '/')), "/")

"""
    save_file(storage, name, bytes) -> stored name

Store bytes under a sanitised version of `name` (directories allowed); a name that exists
gets a random suffix (`report_a8Xk2Lq.pdf`).
"""
function save_file(s::FileSystemStorage, name::AbstractString, data::AbstractVector{UInt8})
    name = valid_path(name)
    isempty(name) && (name = "file")
    stem, ext = splitext(name)
    candidate = name
    while exists(s, candidate)
        candidate = stem * "_" * random_string(7) * ext
    end
    p = path(s, candidate)
    mkpath(dirname(p))
    write(p, data)
    candidate
end

# --- field values -------------------------------------------------------------------------------------

"""
The value of a file field: the stored `name`, with `url`, `size`, `path` and (for images)
`width` and `height`. `read(f)` gives the bytes. An empty name means no file.
"""
struct FieldFile
    name::String
    storage::Storage
end
Base.show(io::IO, f::FieldFile) = print(io, f.name)
display_string(f::FieldFile) = f.name
truthy(f::FieldFile) = !isempty(f.name)
Base.isempty(f::FieldFile) = isempty(f.name)
Base.:(==)(a::FieldFile, b::FieldFile) = a.name == b.name
Base.read(f::FieldFile) = read(f.storage, f.name)
function Base.getproperty(f::FieldFile, s::Symbol)
    s === :url && return url(getfield(f, :storage), getfield(f, :name))
    s === :size && return size(getfield(f, :storage), getfield(f, :name))
    s === :path && return path(getfield(f, :storage), getfield(f, :name))
    if s in (:width, :height)
        d = image_size(read(f))
        return d === nothing ? nothing : (s === :width ? d[1] : d[2])
    end
    getfield(f, s)
end
tattr(f::FieldFile, ::Val{S}) where {S} = S in (:url, :size, :path, :width, :height, :name) ? getproperty(f, S) : NOTFOUND

# --- fields ---------------------------------------------------------------------------------------------

"""
    FileField(; upload_to="", storage=nothing, max_length=100, kw...)

`upload_to` is a directory with optional date codes (`"docs/%Y/%m/"`) or a function
`(obj, filename) -> name`. The column stores the name (up to `max_length` characters).
"""
function FileField(; upload_to = "", storage = nothing, max_length = 100, kw...)
    f = Field(:file; max_length = max_length, kw...)
    f.related = (upload_to, storage, nothing, nothing)
    f
end

"""
    ImageField(; upload_to="", width_field=nothing, height_field=nothing, kw...)

A `FileField` that only accepts PNG, GIF, JPEG and WebP images. `width_field` and
`height_field` name integer fields filled in when an image is saved.
"""
function ImageField(; upload_to = "", storage = nothing, width_field = nothing, height_field = nothing, max_length = 100, kw...)
    f = Field(:image; max_length = max_length, kw...)
    f.related = (upload_to, storage, width_field === nothing ? nothing : Symbol(width_field),
                 height_field === nothing ? nothing : Symbol(height_field))
    f
end

const FILE_KINDS = (:file, :image)
"A field's storage: its `storage` option (a Storage, or the name of one in `STORAGES`), else the default."
function field_storage(f::Field)
    s = f.related[2]
    s === nothing ? default_storage() : s isa Union{AbstractString,Symbol} ? storages(string(s)) : s
end

function upload_name(f::Field, obj, filename)
    up = f.related[1]
    up isa Function && return string(up(obj, filename))
    dir = string(up)
    dir = replace(dir, "%Y" => Dates.format(now(), "yyyy"), "%m" => Dates.format(now(), "mm"), "%d" => Dates.format(now(), "dd"))
    joinpath(dir, get_valid_name(filename))
end

"Store `UploadedFile` values of an object's file fields (called by `save!`)."
function store_uploaded_files!(obj::Model, data)
    for f in all_fields(typeof(obj))
        f.kind in FILE_KINDS || continue
        v = data[attname(f)]
        v isa UploadedFile || continue
        st = field_storage(f)
        data[attname(f)] = FieldFile(save_file(st, upload_name(f, obj, v.name), v.data), st)
        if f.kind === :image
            d = image_size(v.data)
            wf, hf = f.related[3], f.related[4]
            d === nothing || (wf === nothing || (data[wf] = d[1]); hf === nothing || (data[hf] = d[2]))
        end
    end
end

file_to_db(f::Field, v::FieldFile) = v.name
file_to_db(f::Field, v::AbstractString) = String(v)
file_to_db(f::Field, v::UploadedFile) = throw(ArgumentError("save! the object to store the uploaded file for $(f.name)"))
file_from_db(f::Field, v) = (s = string(v); isempty(s) ? nothing : FieldFile(s, field_storage(f)))

# --- validators -------------------------------------------------------------------------------------------

"`FileExtensionValidator([\"pdf\", \"txt\"])`: only allow these file extensions."
FileExtensionValidator(allowed) = v -> begin
    v isa UploadedFile || return true
    ext = lowercase(lstrip(splitext(v.name)[2], '.'))
    ext in lowercase.(string.(allowed)) ||
        "File extension “$(ext)” is not allowed. Allowed extensions are: $(join(lowercase.(string.(allowed)), ", "))."
end
"`MaxFileSizeValidator(2_000_000)`: reject uploads larger than this many bytes."
MaxFileSizeValidator(n::Integer) = v -> !(v isa UploadedFile) || length(v.data) <= n ||
    "Ensure this file is at most $(n) bytes (it is $(length(v.data)) bytes)."

# --- image dimensions ---------------------------------------------------------------------------------------

be16(b, i) = (Int(b[i]) << 8) | Int(b[i+1])
le16(b, i) = Int(b[i]) | (Int(b[i+1]) << 8)
be32(b, i) = (Int(b[i]) << 24) | (Int(b[i+1]) << 16) | (Int(b[i+2]) << 8) | Int(b[i+3])
le24(b, i) = Int(b[i]) | (Int(b[i+1]) << 8) | (Int(b[i+2]) << 16)

"Width and height of a PNG, GIF, JPEG or WebP image, or `nothing` if the bytes aren't one."
function image_size(b::AbstractVector{UInt8})
    n = length(b)
    if n >= 24 && b[1:8] == UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        return (be32(b, 17), be32(b, 21))                                   # PNG IHDR
    elseif n >= 10 && b[1:3] == UInt8['G', 'I', 'F']
        return (le16(b, 7), le16(b, 9))                                     # GIF screen size
    elseif n >= 4 && b[1] == 0xff && b[2] == 0xd8                           # JPEG: find a SOFn marker
        i = 3
        while i + 9 <= n
            b[i] == 0xff || return nothing
            m = b[i+1]
            m == 0xff && (i += 1; continue)
            if m in (0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf)
                return (be16(b, i + 7), be16(b, i + 5))
            end
            i += 2 + be16(b, i + 2)
        end
    elseif n >= 30 && b[1:4] == UInt8['R', 'I', 'F', 'F'] && b[9:12] == UInt8['W', 'E', 'B', 'P']
        chunk = String(b[13:16])
        chunk == "VP8 " && return (le16(b, 27) & 0x3fff, le16(b, 29) & 0x3fff)
        chunk == "VP8L" && (bits = Int(b[22]) | Int(b[23]) << 8 | Int(b[24]) << 16 | Int(b[25]) << 24;
                            return ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1))
        chunk == "VP8X" && return (le24(b, 25) + 1, le24(b, 28) + 1)
    end
    nothing
end

# --- serving media in development ---------------------------------------------------------------------------

"Serve a file from MEDIA_ROOT (development server, DEBUG only)."
function serve_media(req::Request)
    rel = req.path[ncodeunits(settings.MEDIA_URL)+1:end]
    st = FileSystemStorage()
    p = try
        path(st, URIs.unescapeuri(rel))
    catch
        throw(Http404("Media file '$rel' not found"))
    end
    isfile(p) || throw(Http404("Media file '$rel' not found"))
    resp = HttpResponse(read(p); content_type = get(MIME_TYPES, lowercase(splitext(p)[2]), "application/octet-stream"))
    setheader!(resp, "X-Content-Type-Options", "nosniff")
    resp
end
