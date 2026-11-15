# Model introspection ---------------------------------------------------------------------------
#
# The public way for generic code (an audit log, undo, CSV export, "copy this row") to ask a model
# about its fields, as Django's `Model._meta` and field methods:
#
#     for f in concrete_fields(Material)               # the columns, multi-table parents' first
#         f.name, attname(f), column(f), f.kind        # :plate, :plate_id, "plate_id", :fk
#         is_relation(f) && related_model(f)           # Plate
#         v = value_from_object(f, obj)                # the stored value (a foreign key's id)
#         x = value_to_json(f, v)                      # JSON-ready: strings for dates, decimals, UUIDs...
#         value_from_json(f, x) == v                   # and back
#     end
#     many_to_many(Material)                           # m2m fields; through(Material, f.name) is the join model
#     model_label(Material), get_model("lab.Material")
#
# The automatic `id` primary key isn't a field: read it as `obj.pk`. A CompositePrimaryKey's
# fields are concrete fields with `is_primary_key(T, f)` true.

"""
    concrete_fields(T) -> Vector{Field}

The fields of model `T` that are columns of its table or, for multi-table inheritance, of its
parents' tables (parents' first), in declaration order: foreign keys included, many-to-many
fields and the automatic `id` excluded. GeneratedFields are included (`f.generated !== nothing`;
they can't be written). Don't modify the returned vector.
"""
Base.@nospecializeinfer concrete_fields(@nospecialize(T::Type{<:Model})) = all_fields(T)

"""
    many_to_many(T) -> Vector{Field}

The many-to-many fields of model `T`, its multi-table parents' included. `related_model(f)` is
the other side and `through(T, f.name)` the join model.
"""
Base.@nospecializeinfer function many_to_many(@nospecialize(T::Type{<:Model}))
    C = concrete_model(T)
    own = modelmeta(C).m2m
    P = table_parent(C)
    P === nothing ? own : vcat(many_to_many(P), own)
end

"""
    attname(f) -> Symbol

The attribute and column name of field `f`: `:plate_id` for `plate = ForeignKey(Plate)`, the
field's name otherwise. `obj.plate_id` reads the stored id without loading the Plate.
"""
attname

"""
    column(f) -> String

The database column of field `f` (its `attname` as a string).
"""
column

"    is_relation(f) -> Bool: whether `f` is a ForeignKey, OneToOneField or ManyToManyField."
is_relation(f::Field) = f.kind === :fk || f.kind === :m2m

"    is_primary_key(T, f) -> Bool: whether `f` is part of `T`'s CompositePrimaryKey (the automatic `id` isn't a field)."
Base.@nospecializeinfer is_primary_key(@nospecialize(T::Type{<:Model}), f::Field) =
    is_composite(T) && any(p -> p.name === f.name, pk_fields(T))

"""
    related_model(f) -> Type

The model a ForeignKey, OneToOneField or ManyToManyField points at.
"""
related_model

"""
    value_from_object(f, obj)

The value of concrete field `f` stored on `obj`: a foreign key's id (not the related object, so
nothing is loaded), a datetime, a Decimal, a FieldFile, ... A deferred field is loaded first.
"""
Base.@nospecializeinfer value_from_object(f::Field, @nospecialize(obj::Model)) = field_data(obj, attname(f))

"""
    value_to_json(f, v)

`v`, a value of field `f`, in the JSON-ready form the serializers (`dumpdata`) write: strings
for dates, datetimes (UTC, ending in `Z`), times, durations, Decimals, UUIDs and files, base64
for binary data, ids for related objects; numbers, booleans, strings, vectors and dicts as they
are. `value_from_json(f, value_to_json(f, v)) == v`.
"""
value_to_json(f::Field, v) = serial_value(f, v)

"""
    value_from_json(f, x)

The value of field `f` from its JSON form (`value_to_json`, `dumpdata`, or a string such as
`"2026-11-14T18:21:17Z"` or `"19.90"`): what `value_from_object` would return for it. It can be
assigned to the field (`setproperty!(obj, attname(f), v)`) or passed to `update!`.
"""
value_from_json(f::Field, x) = deserial_value(f, x)

"""
    lookup_value(obj, "author__profile__city"; default = nothing)

Follow a lookup path on an object, as Django does in queries but on an instance: the parts
are attributes or relations (`__` or `.` between them), and dicts and named tuples are
followed by key. Where the chain reaches `nothing` (an empty relation) the result is
`default`. A property that throws is logged as a warning and gives `default`, so one bad row
doesn't break a page or an export.
"""
function lookup_value(@nospecialize(obj), path::AbstractString; default = nothing)
    v = obj
    for part in split(path, r"__|\.")
        v === nothing && return default
        k = Symbol(part)
        v = try
            v isa AbstractDict ? get(v, string(part), get(v, k, nothing)) :
            v isa NamedTuple ? get(v, k, nothing) :
            v isa Model || hasproperty(v, k) ? getproperty(v, k) : nothing
        catch e
            @warn "lookup_value: $(typeof(obj)) $(repr(path)) failed at '$part'" exception = e
            return default
        end
    end
    v === nothing ? default : v
end
lookup_value(@nospecialize(obj), path::Symbol; kw...) = lookup_value(obj, string(path); kw...)

