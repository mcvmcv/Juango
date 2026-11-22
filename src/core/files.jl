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
# (a field given a storage shares it, as Django's: @model and forms copy their fields, but not the files)
Base.deepcopy_internal(s::Storage, ::IdDict) = s

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
    times::Dict{String,Tuple{Float64,Float64}}     # name => (created, modified), as Unix times
end
InMemoryStorage(; base_url = nothing, location = nothing) =
    InMemoryStorage(Dict{String,Vector{UInt8}}(), base_url, ReentrantLock(), Dict{String,Tuple{Float64,Float64}}())

memname(name) = (n = valid_path(name); isempty(n) ? throw(ArgumentError("'$name' is not a valid file name")) : n)
"Whether a file, or a directory (a prefix of stored names), exists (Django's `exists`)."
exists(s::InMemoryStorage, name) = lock(s.lock) do
    n = memname(name)
    haskey(s.files, n) || any(k -> startswith(k, n * "/"), keys(s.files))
end
Base.read(s::InMemoryStorage, name) = lock(s.lock) do
    # (a copy: String(bytes) takes over the vector it's given, which would empty the stored file)
    copy(get(() -> throw(SystemError("no file '$name' in InMemoryStorage", 2)), s.files, memname(name)))
end
Base.size(s::InMemoryStorage, name) = length(read(s, name))
function delete_file(s::InMemoryStorage, name)
    isempty(string(name)) && throw(ArgumentError("The name must be given to delete()."))
    lock(() -> (n = memname(name); delete!(s.files, n); delete!(s.times, n); nothing), s.lock)
end
path(::InMemoryStorage, name) = throw(ArgumentError("InMemoryStorage files have no path on disk"))
url(s::InMemoryStorage, name) = storage_url(something(s.base_url, string(settings.MEDIA_URL)), name)
function save_file(s::InMemoryStorage, name::AbstractString, data::AbstractVector{UInt8}; max_length = nothing)
    name = valid_path(name)
    isempty(name) && (name = "file")
    lock(s.lock) do
        candidate = get_available_name(s, name; max_length = max_length)
        s.files[candidate] = Vector{UInt8}(data)
        t = time()
        s.times[candidate] = (get(s.times, candidate, (t, t))[1], t)
        candidate
    end
end
in_memory_time(s::InMemoryStorage, name, i) = lock(s.lock) do
    n = memname(name)
    haskey(s.times, n) || throw(SystemError("no file '$name' in InMemoryStorage", 2))
    s.times[n][i]
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
    s = replace(s, ' ' => '_')                  # (each space, as Django's get_valid_filename)
    s = replace(s, r"[^\w.\-]" => "")
    s = lstrip(s, '.')
    isempty(s) ? "file" : s
end
valid_path(name) = join([get_valid_name(p) for p in split(replace(name, '\\' => '/'), '/') if !isempty(p) && p != "." && p != ".."], "/")

"Absolute path of a stored name, refusing anything outside the storage root."
function path(s::FileSystemStorage, name::AbstractString)
    r = root(s)
    p = normpath(joinpath(r, name))
    within(r, p) || throw(ArgumentError("'$name' is outside the storage location"))
    p
end

"Whether a file or directory exists (Django's `exists`)."
exists(s::FileSystemStorage, name) = (p = path(s, name); ispath(p) || islink(p))
Base.size(s::FileSystemStorage, name) = filesize(path(s, name))
Base.read(s::FileSystemStorage, name) = read(path(s, name))
"Delete a stored file, or an empty directory (no error if it is already gone)."
function delete_file(s::FileSystemStorage, name)
    isempty(string(name)) && throw(ArgumentError("The name must be given to delete()."))
    p = path(s, name)
    isdir(p) ? rm(p) : isfile(p) || islink(p) ? rm(p) : nothing
    nothing
end
url(s::FileSystemStorage, name) = storage_url(something(s.base_url, string(settings.MEDIA_URL)), name)
"""
A stored name's URL under `base` (Django's `url`): quoted as `filepath_to_uri`, backslashes as slashes, and
leading slashes dropped, so a name can't make a URL to another host (`//evil.com`). `nothing`: the base.
"""
storage_url(base, name) = rstrip(base, '/') * "/" * (name === nothing ? "" : lstrip(filepath_to_uri(name), '/'))

"""
    get_available_name(storage, name; max_length = nothing) -> String

A name not taken in the storage (Django's): `name`, or with `_` and 7 random characters before its
extensions (`report_a8Xk2Lq.tar.gz`). With `max_length` the name's stem is shortened to fit; when nothing
fits, an `ArgumentError` asks for a longer `max_length`.
"""
function get_available_name(s::Storage, name::AbstractString; max_length = nothing)
    name = replace(String(name), '\\' => '/')
    dir, file = splitdir(name)
    i = findnext('.', file, nextind(file, firstindex(file)))      # (the extensions; a leading dot isn't one)
    ext = i === nothing ? "" : file[i:end]
    stem = i === nothing ? file : file[1:prevind(file, i)]
    while exists(s, name) || (max_length !== nothing && length(name) > max_length)
        name = joinpath_(dir, stem * "_" * random_string(7) * ext)
        max_length === nothing && continue
        cut = length(name) - max_length
        if cut > 0
            stem = first(stem, max(0, length(stem) - cut))
            isempty(stem) && throw(ArgumentError("Storage can not find an available filename for \"$name\". Please make sure that the corresponding file field allows sufficient \"max_length\"."))
            name = joinpath_(dir, stem * "_" * random_string(7) * ext)
        end
    end
    name
end
joinpath_(dir, file) = isempty(dir) ? file : dir * "/" * file

"""
    get_modified_time(storage, name)    get_created_time(storage, name)

When a stored file was last changed, or created (Django's): aware and in UTC with USE_TZ, else naive in
TIME_ZONE. (`get_created_time` is the inode change time on a FileSystemStorage, as Python's getctime.)
"""
get_modified_time(s::FileSystemStorage, name) = storage_time(mtime(path(s, name)))
get_created_time(s::FileSystemStorage, name) = storage_time(ctime(path(s, name)))
get_modified_time(s::InMemoryStorage, name) = storage_time(in_memory_time(s, name, 2))
get_created_time(s::InMemoryStorage, name) = storage_time(in_memory_time(s, name, 1))
function storage_time(t::Real)
    z = TimeZones.ZonedDateTime(Dates.unix2datetime(t), UTC_TZ)
    settings.USE_TZ ? z : DateTime(TimeZones.astimezone(z, default_timezone()))
end

"""
Store an upload: big ones are moved from their temporary file rather than read into memory. With
`max_length` (the file field's), the stored name is kept within it, as Django's `get_available_name`.
"""
function save_upload(s::Storage, name::AbstractString, f; max_length = nothing)
    max_length === nothing || (name = get_available_name(s, valid_path(name); max_length = max_length))
    save_file(s, name, read(f))
end
function save_upload(s::FileSystemStorage, name::AbstractString, f; max_length = nothing)
    max_length === nothing || (name = get_available_name(s, valid_path(name); max_length = max_length))
    temporary_file_path(f) === nothing && return save_file(s, name, read(f))
    save_file(s, name, f)
end

"""
    save_file(storage, name, bytes) -> stored name

Store bytes under a sanitised version of `name` (directories allowed); a name that exists
gets a random suffix (`report_a8Xk2Lq.pdf`).
"""
function save_file(s::FileSystemStorage, name::AbstractString, data)
    name = valid_path(name)
    isempty(name) && (name = "file")
    candidate = get_available_name(s, name)
    p = path(s, candidate)
    dir = dirname(p)
    if !isdir(dir)
        mkpath(dir)
        dperm = get(settings, :FILE_UPLOAD_DIRECTORY_PERMISSIONS, nothing)
        dperm === nothing || chmod(dir, dperm)
    end
    data isa UploadedFile ? cp(temporary_file_path(data), p) : write(p, data)
    perm = get(settings, :FILE_UPLOAD_PERMISSIONS, nothing)
    perm === nothing || chmod(p, perm)
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

"""
    MultipleFileField(; max_files = nothing, images = false, blank = false, kw...)

A form field for several files at once (`<input type="file" multiple>`), which Django leaves
you to write. Its cleaned value is a `Vector{UploadedFile}`; each file is checked as a
`FileField`'s is (not empty, name length, `validators`, and with `images = true`, a valid
image). When required, choosing nothing is an error (browsers send an empty list, which
Django's required check misses). `max_files` limits how many. For forms only: save the
files yourself (`save_file`), say to a related model, one row per file.
"""
MultipleFileField(; max_files = nothing, images::Bool = false, max_length = 100, kw...) =
    (f = Field(images ? :image : :file; max_length = max_length, kw...);
     f.related = ("", nothing, nothing, nothing, (multiple = true, max_files = max_files)); f)
"Whether a file field takes several files (`MultipleFileField`)."
is_multiple_file(fld) = fld.related isa Tuple && length(fld.related) >= 5 && fld.related[5] isa NamedTuple && get(fld.related[5], :multiple, false)
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
        data[attname(f)] = FieldFile(save_upload(st, upload_name(f, obj, v.name), v; max_length = f.max_length), st)
        if f.kind === :image
            d = image_size(read(v))
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

"""
    FileExtensionValidator(["pdf", "txt"]; message, code = "invalid_extension")

Only allow these file extensions (any, with `nothing`). A field's `error_messages` can name
%(extension)s, %(allowed_extensions)s and %(value)s (the file name).
"""
struct FileExtensionValidator <: Validator
    allowed::Union{Nothing,Vector{String}}
    message::Any
    code::String
end
FileExtensionValidator(allowed = nothing; message = nothing, code = "invalid_extension") =
    FileExtensionValidator(allowed === nothing ? nothing : lowercase.(string.(allowed)), message, string(code))
file_name(v) = v isa UploadedFile || v isa FieldFile ? v.name : nothing
file_extension(name) = lowercase(lstrip(splitext(name)[2], '.'))
function validator_params(v::FileExtensionValidator, x)
    name = something(file_name(x), string(x))
    Dict{String,Any}("extension" => file_extension(name), "value" => name,
                     "allowed_extensions" => v.allowed === nothing ? "" : join(v.allowed, ", "))
end
function validation_error(v::FileExtensionValidator, x)
    name = file_name(x)
    (name === nothing || v.allowed === nothing || file_extension(name) in v.allowed) && return nothing
    (v.code, interpolate(msg_or(v, gettext("File extension “%(extension)s” is not allowed. Allowed extensions are: %(allowed_extensions)s.")),
                         validator_params(v, x)))
end
"The image file extensions (Pillow's), for `validate_image_file_extension`."
const IMAGE_EXTENSIONS = ["apng", "avif", "blp", "bmp", "bufr", "bw", "cur", "dcx", "dds", "dib", "emf", "eps", "fit", "fits",
    "flc", "fli", "ftc", "ftu", "gbr", "gif", "grib", "h5", "hdf", "icb", "icns", "ico", "iim", "im", "j2c", "j2k", "jfif",
    "jp2", "jpc", "jpe", "jpeg", "jpf", "jpg", "jpx", "mpeg", "mpg", "msp", "pbm", "pcd", "pcx", "pfm", "pgm", "png", "pnm",
    "ppm", "ps", "psd", "pxr", "qoi", "ras", "rgb", "rgba", "sgi", "tga", "tif", "tiff", "vda", "vst", "webp", "wmf", "xbm", "xpm"]
"Django's `validate_image_file_extension`: a `FileExtensionValidator` for image file extensions."
const validate_image_file_extension = FileExtensionValidator(IMAGE_EXTENSIONS)
"`MaxFileSizeValidator(2_000_000)`: reject uploads larger than this many bytes."
MaxFileSizeValidator(n::Integer) = v -> !(v isa UploadedFile) || v.size <= n ||
    "Ensure this file is at most $(n) bytes (it is $(v.size) bytes)."

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

# --- serving private uploads in production -------------------------------------------------------------------

"Types a browser shows inline as images and can't run (SVG can hold scripts, so it's an attachment)."
const SAFE_INLINE_MEDIA = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".bmp", ".ico")

"""
    protected_media(; allow = (req, name) -> is_authenticated(req.user), storage = FileSystemStorage(),
                      sendfile = nothing, prefix = "/protected/")

A view serving uploaded files only to users `allow` lets through, for `path("media/<path:name>",
protected_media())`. Anonymous users are sent to the login page; others refused get 403. The file
can't run as one of the site's pages: paths can't leave the storage's directory, the response is
`Content-Security-Policy: sandbox` and `nosniff`, and anything but a plain image (PNG, JPEG, GIF,
WebP...) is sent as a download. `allow(req, name)` sees the file's name, so it can check who owns it.

`sendfile = :x_accel_redirect` (nginx) or `:x_sendfile` (Apache, lighttpd) hands the sending to the
web server: the response carries `X-Accel-Redirect: <prefix><name>` (an `internal` nginx location
serving MEDIA_ROOT) or `X-Sendfile: <path>` and no body.
"""
function protected_media(; allow = (req, name) -> is_authenticated(req.user), storage = nothing, sendfile = nothing,
                         prefix::AbstractString = "/protected/")
    sendfile in (nothing, :x_accel_redirect, :x_sendfile) || throw(ArgumentError("protected_media: sendfile is nothing, :x_accel_redirect or :x_sendfile"))
    function serve_protected(req; name, kw...)
        name = URIs.unescapeuri(string(name))
        if !allow(req, name)
            is_authenticated(req.user) || return redirect_to_login(req)
            throw(PermissionDenied("You can't see this file."))
        end
        st = something(storage, FileSystemStorage())
        p = try path(st, name) catch; throw(Http404("File not found")) end      # (path refuses ../ and absolute names)
        isfile(p) || throw(Http404("File not found"))
        ext = lowercase(splitext(p)[2])
        inline = ext in SAFE_INLINE_MEDIA
        headers = ["X-Content-Type-Options" => "nosniff", "Content-Security-Policy" => "sandbox; default-src 'none'; img-src 'self'",
                   "Cache-Control" => "private, max-age=0", "X-Frame-Options" => "SAMEORIGIN"]
        if sendfile !== nothing
            r = HttpResponse(""; content_type = inline ? get(MIME_TYPES, ext, "application/octet-stream") : "application/octet-stream")
            setheader!(r, sendfile === :x_sendfile ? "X-Sendfile" : "X-Accel-Redirect",
                       sendfile === :x_sendfile ? p : rstrip(prefix, '/') * "/" * join(URIs.escapeuri.(split(name, '/')), "/"))
            setheader!(r, "Content-Disposition", content_disposition(basename(p); attachment = !inline))
        else
            r = FileResponse(p; as_attachment = !inline, content_type = inline ? get(MIME_TYPES, ext, "application/octet-stream") : "application/octet-stream")
        end
        foreach(h -> setheader!(r, h.first, h.second), headers)
        r
    end
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
