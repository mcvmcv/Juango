# Serializers and fixtures ----------------------------------------------------------------------------
#
#     s = serialize(:json, objects(Post); indent = 2)       # Django's format:
#     # [{"model": "blog.post", "pk": 1, "fields": {"title": "...", "author": 3, "tags": [1, 2]}}]
#     for d in deserialize(:json, s); save!(d); end
#
#     dumpdata("blog"; output = "blog.json")                # manage.jl dumpdata blog --indent 2
#     loaddata("blog.json")                                 # manage.jl loaddata initial_data
#
# Formats: `:json` (a list), `:jsonl` (one object per line), `:yaml` and `:xml` (fixtureformats.jl). Foreign keys and many-to-many
# values are primary keys, or natural keys when asked (`natural_foreign = true`) for models
# that define them:
#
#     Juango.natural_key(a::Author) = (a.email,)
#     Juango.get_by_natural_key(::Type{Author}, email) = get(Author; email = email)

"A model's natural key (a tuple identifying an object without its id); define a method for your models."
natural_key(obj) = nothing
"The object with this natural key; define a method alongside `natural_key`."
get_by_natural_key(T::Type, args...) = throw(ArgumentError("$(nameof(T)) has no get_by_natural_key method"))
has_natural_key(T::Type) = hasmethod(natural_key, Tuple{T}) && which(natural_key, Tuple{T}).sig != Tuple{typeof(natural_key),Any}

serial_label(T::Type) = lowercase(model_label(T))

function serial_value(f::Field, v)
    v === nothing && return nothing
    v isa Model && return v.id
    v isa DateTime && return Dates.format(v, "yyyy-mm-ddTHH:MM:SS.sss")
    v isa TimeZones.ZonedDateTime && return string(TimeZones.astimezone(v, UTC_TZ))
    v isa Date && return string(v)
    v isa UUID && return string(v)
    v isa Dates.Time && return time_string(v)
    f.kind === :binary && return base64encode(v)                      # as Django
    v isa Duration && return duration_string(v; serial = true)   # Django's "1 02:00:00"
    v isa Decimal && return string(v)                  # as Django: "19.90", exactly
    v isa FieldFile && return v.name
    f.kind === :geometry && return ewkt(v)
    v isa ValueRange && return Dict("lower" => serial_value(f, v.lower), "upper" => serial_value(f, v.upper), "bounds" => v.bounds)
    v isa Symbol && return string(v)
    v
end

"One object as Django's serialized dict."
function serialize_object(obj::T; fields = nothing, natural_foreign = false, natural_primary = false) where {T<:Model}
    d = Dict{String,Any}("model" => serial_label(T))
    if !natural_primary || natural_key(obj) === nothing
        pk = obj.pk
        d["pk"] = pk isa Tuple ? collect(pk) : pk isa UUID ? string(pk) : pk
    end
    fs = Dict{String,Any}()
    for f in all_fields(T)
        (fields === nothing || f.name in fields) || continue
        f.generated === nothing || continue
        if f.kind === :fk
            id = field_data(obj, attname(f))
            R = related_model(f)
            fs[string(f.name)] = id !== nothing && natural_foreign && has_natural_key(R) ?
                collect(natural_key(get(base_objects(R); id = id))) : serial_value(f, id)
        else
            fs[string(f.name)] = serial_value(f, field_data(obj, attname(f)))
        end
    end
    for f in modelmeta(concrete_model(T)).m2m
        (fields === nothing || f.name in fields) || continue
        R = related_model(f)
        rel = collect(getproperty(obj, f.name))
        fs[string(f.name)] = natural_foreign && has_natural_key(R) ? [collect(natural_key(r)) for r in rel] : [r.id for r in rel]
    end
    d["fields"] = fs
    d
end

"""
    serialize(format, objects; fields = nothing, natural_foreign = false, natural_primary = false, indent = nothing) -> String

Serialize model instances (a queryset or any collection) as `:json`, `:jsonl`, `:yaml` or
`:xml` (Django's formats). `indent` applies to JSON and XML.
"""
function serialize(format::Symbol, objs; fields = nothing, natural_foreign = false, natural_primary = false, indent = nothing)
    format in SERIAL_FORMATS || throw(ArgumentError("unknown serialization format :$format (have $(join(SERIAL_FORMATS, ", ")))"))
    objs = collect(objs)
    ds = Dict{String,Any}[serialize_object(o; fields = fields === nothing ? nothing : Symbol.(fields),
                                           natural_foreign = natural_foreign, natural_primary = natural_primary) for o in objs]
    format === :json ? (indent === nothing ? JSON.json(ds) : JSON.json(ds; pretty = indent)) :
    format === :jsonl ? join(JSON.json(d) * "\n" for d in ds) :
    format === :yaml ? yaml_dump(ds) : xml_dump(ds, objs; indent = indent)
end
const SERIAL_FORMATS = (:json, :jsonl, :yaml, :xml)
"The serialization format of a fixture file, from its extension."
fixture_format(path::AbstractString) = endswith(path, ".jsonl") ? :jsonl : endswith(path, ".yaml") || endswith(path, ".yml") ? :yaml :
                                       endswith(path, ".xml") ? :xml : :json

"An object read by `deserialize`: `save!` it to write it with its many-to-many values."
struct DeserializedObject
    object::Model
    m2m::Dict{Symbol,Vector{Any}}
end
Base.show(io::IO, d::DeserializedObject) = print(io, "<DeserializedObject: ", typeof(d.object), " ", repr(d.object.pk), ">")

resolve_ref(R::Type, v) = v isa AbstractVector && has_natural_key(R) ? get_by_natural_key(R, v...).id : v

function deserialize_one(d::AbstractDict)
    T = get_model(String(d["model"]))
    fs = get(d, "fields", Dict{String,Any}())
    data = Dict{Symbol,Any}()
    m2m = Dict{Symbol,Vector{Any}}()
    for f in all_fields(T)
        f.generated === nothing || continue
        haskey(fs, string(f.name)) || continue
        v = fs[string(f.name)]
        if f.kind === :fk
            data[attname(f)] = v === nothing ? nothing : pk_value(related_model(f), resolve_ref(related_model(f), v))
        elseif v === nothing
            data[attname(f)] = nothing
        elseif f.kind in RANGE_KINDS && v isa AbstractDict
            conv(x) = x === nothing ? nothing : f.kind === :intrange ? Int(x) : f.kind === :daterange ? Date(x) : todatetime(x)
            data[attname(f)] = ValueRange(conv(get(v, "lower", nothing)), conv(get(v, "upper", nothing)); bounds = get(v, "bounds", "[)"))
        elseif f.kind === :binary && v isa AbstractString
            data[attname(f)] = base64decode(v)
        elseif f.kind === :array && v isa AbstractVector
            data[attname(f)] = collect(v)
        else
            data[attname(f)] = from_db(f, v)
        end
    end
    for f in modelmeta(concrete_model(T)).m2m
        haskey(fs, string(f.name)) || continue
        m2m[f.name] = Any[resolve_ref(related_model(f), v) for v in fs[string(f.name)]]
    end
    obj = T()
    od = getfield(obj, :_data)
    for (k, v) in data
        od[k] = v
    end
    pk = get(d, "pk", nothing)
    if pk === nothing && has_natural_key(T)          # natural primary key: find the existing row, if any
        existing = try get_by_natural_key(T, natural_key(obj)...) catch; nothing end
        existing === nothing || (pk = existing.id)
    end
    is_composite(T) || (od[:id] = pk === nothing ? nothing : pk_value(T, pk))
    DeserializedObject(obj, m2m)
end

"""
    deserialize(format, data) -> Vector{DeserializedObject}

Read objects written by `serialize` (or Django's `dumpdata`). Nothing is saved until you
call `save!` on each.
"""
function deserialize(format::Symbol, data::AbstractString)
    items = format === :json ? JSON.parse(data) :
            format === :jsonl ? [JSON.parse(l) for l in split(data, '\n') if !isempty(strip(l))] :
            format === :yaml ? something(parse_yaml(data), Any[]) :
            format === :xml ? xml_objects(data) :
            throw(ArgumentError("unknown serialization format :$format (have $(join(SERIAL_FORMATS, ", ")))"))
    items isa AbstractVector || throw(ArgumentError("a fixture is a list of objects"))
    [deserialize_one(d) for d in items]
end

"""
    save!(d::DeserializedObject)

Write the object as it is (UPDATE its row, or INSERT it with its primary key) without
signals or `auto_now`, then set its many-to-many values.
"""
function save!(d::DeserializedObject)
    obj = d.object
    T = typeof(obj)
    data = getfield(obj, :_data)
    if data[:id] === nothing && !is_composite(T)
        save_here!(obj)                                    # no pk in the fixture: a new row
    else
        chain_ = reverse(vcat([concrete_model(T)], ancestors(T)))
        foreach(M -> save_table!(M, data, M === chain_[1], false), chain_)
    end
    for (name, ids) in d.m2m
        set!(getproperty(obj, name), ids)
    end
    obj
end

# --- dumpdata / loaddata ------------------------------------------------------------------------------

"The models a `dumpdata` label stands for: `\"app\"` (its models) or `\"app.Model\"`."
function dump_models(label::AbstractString)
    occursin('.', label) && return [get_model(label)]
    ms = [T for T in all_models() if modelmeta(T).app == label && !modelmeta(T).proxy && model_in_use(T) && !(T <: AutoThrough)]
    isempty(ms) && throw(ImproperlyConfigured("no app '$label' with models"))
    ms
end

"Models in an order where referenced models come first (so fixtures load without dangling keys)."
function dependency_order(models)
    out, seen = Type[], Set{Any}()
    visit(T) = begin
        T in seen && return
        push!(seen, T)
        for f in all_fields(T)
            f.kind === :fk || continue
            R = concrete_model(related_model(f))
            R in models && R !== T && visit(R)
        end
        push!(out, T)
    end
    foreach(visit, models)
    out
end

"""
    dumpdata(labels...; format = :json, indent = nothing, exclude = [], natural_foreign = false,
             natural_primary = false, output = nothing) -> String

Serialize every object of the given apps or `\"app.Model\"`s (all apps when none are given),
referenced models first. With `output`, also writes the file.
"""
function dumpdata(labels::AbstractString...; format = :json, indent = nothing, exclude = String[],
                  natural_foreign = false, natural_primary = false, output = nothing)
    models = isempty(labels) ?
        [T for T in all_models() if !modelmeta(T).proxy && model_in_use(T) && !(T <: AutoThrough)] :
        unique(vcat([dump_models(l) for l in labels]...))
    excl = Set(string.(exclude))
    filter!(T -> !(modelmeta(T).app in excl || model_label(T) in excl || serial_label(T) in excl), models)
    objs = Any[]
    for T in dependency_order(models)
        append!(objs, collect(order_by(base_objects(T), "pk")))
    end
    s = serialize(format, objs; natural_foreign = natural_foreign, natural_primary = natural_primary, indent = indent)
    output === nothing || write(output, s)
    s
end

"Where `loaddata` looks for fixture files: FIXTURE_DIRS, then each installed app's `fixtures/`."
fixture_dirs() = vcat(String[abspath(string(d)) for d in get(settings, :FIXTURE_DIRS, String[])], app_dirs("fixtures"))

function find_fixture(name::AbstractString)
    isfile(name) && return [abspath(name)]
    exts = (".json", ".jsonl", ".yaml", ".yml", ".xml")
    found = String[]
    for dir in fixture_dirs(), cand in (any(e -> endswith(name, e), exts) ? [name] : [name * e for e in exts])
        f = joinpath(dir, cand)
        isfile(f) && push!(found, f)
    end
    isempty(found) && throw(ArgumentError("no fixture named '$name' (looked in: $(join(fixture_dirs(), ", ")))"))
    found
end

"""
    loaddata(fixtures...) -> Int

Load fixture files (paths, or names found in `fixture_dirs()`: `\"initial_data\"` finds
`initial_data.json`, `.jsonl`, `.yaml`, `.yml` or `.xml`) in one transaction; returns the number of objects. Objects
with a primary key replace the row with that key.
"""
function loaddata(names::AbstractString...)
    n = 0
    atomic() do
        for name in names, f in find_fixture(name)
            for d in deserialize(fixture_format(f), read(f, String))
                save!(d)
                n += 1
            end
        end
    end
    n
end

"""
    load_fixtures(names...)

Load fixtures in a test (as `loaddata`).
"""
load_fixtures(names::AbstractString...) = loaddata(names...)
