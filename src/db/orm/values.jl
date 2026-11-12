# --- (de)serialisation ------------------------------------------------------------------

from_db(f::Field, ::Nothing) = nothing
function from_db(f::Field, v)
    r = from_db_extra(f, v)
    r === NOTFOUND || return r
    k = f.kind
    k === :fk && pk_kind(related_model(f)) === :uuid && return v isa UUID ? v : UUID(string(v))
    k === :bool && return v isa Bool ? v : v != 0
    k === :int && return v isa Integer ? Int(v) : parse(Int, string(v))
    k === :fk && return Int(v)
    k === :float && return Float64(v)
    k === :datetime && return datetime_from_db(v isa DateTime || v isa TimeZones.ZonedDateTime ? v : something(todatetime(v), v))
    k === :date && return v isa Date ? v : Date(todatetime(v))
    v isa AbstractString ? String(v) : v
end

to_db(f::Field, v::Model) = v.id      # (other values: see fields_extra.jl)

"""
    CompositePrimaryKey(:order, :product)

`Meta(pk = CompositePrimaryKey(...))`: the table's primary key is these fields together, and
there is no `id` column. `obj.pk` (and `obj.id`) is a tuple of their values; look objects up
with `get(Model; pk = (1, 2))` or `filter(Model; pk__in = [(1, 2), (1, 3)])`. As in Django,
other models can't point a ForeignKey or ManyToManyField at such a model, it can't take part
in multi-table inheritance, and the admin doesn't support it.
"""
struct CompositePrimaryKey
    fields::Vector{Symbol}
end
CompositePrimaryKey(fields::Union{Symbol,AbstractString}...) = CompositePrimaryKey(Symbol[Symbol(f) for f in fields])

"Primary key kind of a model's table: `:auto` (integer identity), `:uuid` (`Meta(pk = :uuid)`) or `:composite`."
function pk_kind(T::Type)
    A = concrete_model(T)
    while (P = table_parent(A)) !== nothing
        A = P
    end
    p = get(modelmeta(A).extra, :pk, :auto)
    p isa CompositePrimaryKey ? :composite : p
end
pk_value(T::Type, v) = (v === nothing || pk_kind(T) !== :uuid || v isa UUID) ? v : UUID(string(v))

is_composite(T::Type) = pk_kind(T) === :composite
"The fields of a composite primary key, in order."
pk_fields(T::Type) = Field[getfield_meta(T, n) for n in modelmeta(concrete_model(T)).extra[:pk].fields]
"The primary key of rows at `alias`, as SQL: `alias.id`, or a row value `(alias.a, alias.b)`."
pk_ref(alias, T::Type) = is_composite(T) ? "(" * join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") * ")" : qcol(alias, "id")
"The primary key column(s) of rows at `alias`, for a SELECT list."
pk_select(alias, T::Type) = is_composite(T) ? join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") : qcol(alias, "id")
"A composite key's tuple from an object's data (`nothing` if a part is missing)."
function composite_pk(T::Type, data)
    vals = Any[get(data, attname(f), nothing) for f in pk_fields(T)]
    any(isnothing, vals) ? nothing : Tuple(vals)
end

"""
Parse a primary key from text (URLs, form values); `nothing` if it isn't one. A composite
key is its parts as `pk_string` writes them: `"3,7"`.
"""
function parse_pk(T::Type, s)
    s isa Integer && return pk_kind(T) === :auto ? s : nothing
    s isa UUID && return s
    s isa Tuple && return s
    k = pk_kind(T)
    k === :composite && return parse_composite_pk(T, string(s))
    k === :uuid ? tryparse(UUID, string(s)) : tryparse(Int, string(s))
end
function parse_composite_pk(T::Type, s::AbstractString)
    fs = pk_fields(T)
    bits = split(s, ',')
    length(bits) == length(fs) || return nothing
    vals = Any[]
    for (f, b) in zip(fs, bits)
        b = unquote_pk(b)
        v = f.kind === :fk ? parse_pk(related_model(f), b) : f.kind === :int ? tryparse(Int, b) :
            f.kind === :uuid ? tryparse(UUID, b) : f.kind === :date ? tryparse(Date, b) : String(b)
        v === nothing && return nothing
        push!(vals, v)
    end
    Tuple(vals)
end

"""
    pk_string(obj) -> String

An object's primary key as text for URLs: the id, or a composite key's parts joined with
commas (each escaped as Django's admin does: `,` becomes `_2C`).
"""
pk_string(m::Model) = (pk = m.pk; pk isa Tuple ? join((quote_pk(string(x)) for x in pk), ",") : string(pk))
const PK_QUOTE_CHARS = Set(":/_#?;@&=+\$,\"[]<>%\n\\")
quote_pk(s::AbstractString) = any(in(PK_QUOTE_CHARS), s) ?
    join(c in PK_QUOTE_CHARS ? "_" * uppercase(string(UInt8(c); base = 16, pad = 2)) : string(c) for c in s) : s
unquote_pk(s::AbstractString) = occursin('_', s) ? replace(s, r"_([0-9A-F]{2})" => m -> string(Char(parse(UInt8, m[2:3]; base = 16)))) : String(s)

"""
How a model's fields map to row keys: `(field, row key, attribute name)` per field. Inherited
multi-table fields are labelled per table (`__place__name`). Work it out once per query and
pass it to `from_row` for every row.
"""
function row_plan(@nospecialize(T::Type))
    mytable = modelmeta(T).table
    plan = Tuple{Field,Symbol,Symbol}[]
    for f in all_fields(T)
        t = modelmeta(f.model).table
        push!(plan, (f, t == mytable ? attname(f) : Symbol("__", t, "__", column(f)), attname(f)))
    end
    plan
end

function from_row(::Type{T}, row::Dict{Symbol,Any}, plan = row_plan(T)) where {T<:Model}
    composite = is_composite(T)
    data = Dict{Symbol,Any}()
    sizehint!(data, length(plan) + 1)
    data[:id] = composite ? nothing : pk_value(T, row[:id])
    for (f, key, att) in plan
        v = get(row, key, NOTFOUND)
        v === NOTFOUND && continue               # deferred (only/defer, raw): loaded on first access
        data[att] = from_db(f, v)
    end
    composite && (data[:id] = composite_pk(T, data))
    T(data, Dict{Symbol,Any}())
end
