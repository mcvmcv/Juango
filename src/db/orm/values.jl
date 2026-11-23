# --- (de)serialisation ------------------------------------------------------------------

"A custom field's `from_db_value` / `get_prep_value` function, or nothing."
field_hook(f::Field, k::Symbol) = (o = f.form; o === nothing ? nothing : get(o, k, nothing))
function from_db(f::Field, v)
    h = field_hook(f, :from_db_value)
    r = from_db_builtin(f, v)
    h === nothing ? r : h(r)
end
from_db_builtin(f::Field, ::Nothing) = nothing
# An integer column's value, or an expression's declared to be one: a float or decimal text (pages + rating on
# SQLite gives 451.5) is truncated, as Python's int() in Django's converter.
db_int(v) = v isa Integer ? Int(v) : v isa Real ? trunc(Int, v) :
           (s = strip(string(v)); something(tryparse(Int, s), trunc(Int, parse(Float64, s))))

function from_db_builtin(f::Field, v)
    f.kind === :fk && fk_to_field(f) !== nothing && return from_db(getfield_meta(related_model(f), fk_to_field(f)), v)   # (#220)
    r = from_db_extra(f, v)
    r === NOTFOUND || return r
    k = f.kind
    k === :fk && pk_kind(related_model(f)) === :uuid && return v isa UUID ? v : UUID(string(v))
    k === :bool && return v isa Bool ? v : v != 0
    k in INT_KINDS && return db_int(v)
    k === :fk && return Int(v)
    k === :float && return Float64(v)
    k === :time && return to_time(v)
    k === :binary && return v isa Vector{UInt8} ? v : v isa AbstractVector{UInt8} ? Vector{UInt8}(v) :
                            v isa AbstractString ? Vector{UInt8}(codeunits(v)) : Vector{UInt8}(v)
    k === :duration && return to_duration(v)
    if k === :decimal
        # SQLite computes F() arithmetic in doubles (0.5 - 0.4 is stored as 0.09999999999999998):
        # keep the 15 digits a double holds, as Django's SQLite converter does
        v isa AbstractFloat && (v = round(v; sigdigits = 15))
        return f.decimal_places === nothing ? to_decimal(v) : round(to_decimal(v); digits = f.decimal_places)
    end
    k === :datetime && return datetime_from_db(v isa DateTime || v isa TimeZones.ZonedDateTime ? v :
                                               something(parse_aware_datetime(v), todatetime(v), v))
    k === :date && return v isa Date ? v : Date(todatetime(v))
    v isa AbstractString ? String(v) : v
end

function to_db(f::Field, v::Model)                                                     # (other values: see fields_extra.jl)
    # an object for a plain value is a mistake (as Django: a TypeError)
    (f.kind === :float || f.kind === :decimal || f.kind in STRING_KINDS || f.kind === :bool) &&
        throw(ArgumentError("Tried to update field $(f.name) with a model instance, $(repr(v)). Use a value compatible with the field."))
    saved_key(f.kind === :fk ? target_value(f, v) : v.id, v)
end
to_db(f::Field, c::Choice) = to_db(f, c.value)

"""
    CompositePrimaryKey(:order, :product)

`Meta(pk = CompositePrimaryKey(...))`: the table's primary key is these fields together, and
there is no `id` column. `obj.pk` (and `obj.id`) is a tuple of their values; look objects up
with `get(Model; pk = (1, 2))` or `filter(Model; pk__in = [(1, 2), (1, 3)])`. As in Django,
other models can't point a ForeignKey or ManyToManyField at such a model, it can't take part
in multi-table inheritance, and the admin doesn't support it.

With one field (or a field declared `primary_key = true`) it's a natural key: `obj.pk` is that
field's value, and foreign keys and many-to-many fields can point at the model (#221).
"""
struct CompositePrimaryKey
    fields::Vector{Symbol}
end
CompositePrimaryKey(fields::Union{Symbol,AbstractString}...) = CompositePrimaryKey(Symbol[Symbol(f) for f in fields])

"""
Primary key kind of a model's table: an integer identity (`:auto` 64-bit, `:intauto` 32-bit,
`:smallauto` 16-bit), `:uuid` (`Meta(pk = :uuid)`) or `:composite`.
"""
# Asked for every row loaded (pk_value, is_composite), so worked out once per model (with the relations).
Base.@nospecializeinfer pk_kind(@nospecialize(T::Type)) = cached_relations(compute_pk_kind, :pk_kind, T)::Symbol
Base.@nospecializeinfer function compute_pk_kind(@nospecialize(T::Type))
    A = concrete_model(T)
    while (P = table_parent(A)) !== nothing
        A = P
    end
    meta_pk_kind(A)
end
"The pk kind a root model declares, or the default for its app."
Base.@nospecializeinfer function meta_pk_kind(@nospecialize(A))
    m = modelmeta(A)
    p = get(m.extra, :pk, nothing)
    p isa CompositePrimaryKey && return :composite
    p isa AutoPK && return p.kind
    p === nothing || return p
    default_pk_kind(m.app)
end
"The automatic key of an app's models: the App's `default_auto_field`, else `DEFAULT_AUTO_FIELD` (Juango's own apps: 64-bit)."
function default_pk_kind(app)
    (app in BUILTIN_LABELS || app in ("juango", "admindocs")) && return :auto
    a = get(APP_DEFS, app, nothing)
    auto_pk_kind(a === nothing || a.default_auto_field === nothing ? settings.DEFAULT_AUTO_FIELD : a.default_auto_field)
end
Base.@nospecializeinfer pk_value(@nospecialize(T::Type), v) = (v === nothing || pk_kind(T) !== :uuid || v isa UUID) ? v : UUID(string(v))

Base.@nospecializeinfer is_composite(@nospecialize(T::Type)) = pk_kind(T) === :composite
"The fields of a composite primary key, in order."
Base.@nospecializeinfer pk_fields(@nospecialize(T::Type)) = Field[getfield_meta(T, n) for n in modelmeta(concrete_model(T)).extra[:pk].fields]
"The primary key of rows at `alias`, as SQL: `alias.id`, or a row value `(alias.a, alias.b)`."
pk_ref(alias, T::Type) = is_composite(T) ? "(" * join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") * ")" : qcol(alias, "id")
"The column of a model's single-column primary key: `id`, or a natural key's column."
Base.@nospecializeinfer pk_colname(@nospecialize(T::Type)) = natural_pk(T) ? column(pk_fields(T)[1]) : "id"
"The primary key column(s) of rows at `alias`, for a SELECT list."
pk_select(alias, T::Type) = is_composite(T) ? join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") : qcol(alias, "id")
"A composite key's tuple from an object's data (`nothing` if a part is missing); a natural key's one value."
Base.@nospecializeinfer function composite_pk(@nospecialize(T::Type), data)
    vals = Any[get(data, attname(f), nothing) for f in pk_fields(T)]
    any(isnothing, vals) ? nothing : length(vals) == 1 ? vals[1] : Tuple(vals)
end
"""
Whether `T`'s primary key is one of its fields (`primary_key = true`, or a one-field CompositePrimaryKey):
a natural key, as Django's `CharField(primary_key=True)`. `obj.pk` is then that field's value (#221).
"""
Base.@nospecializeinfer natural_pk(@nospecialize(T::Type)) = is_composite(T) && length(modelmeta(concrete_model(T)).extra[:pk].fields) == 1
"A key's parts as a vector: a composite key's tuple, or a natural key's one value."
pk_parts(k) = k isa Tuple ? collect(Any, k) : Any[k]

"""
Parse a primary key from text (URLs, form values); `nothing` if it isn't one. A composite
key is its parts as `pk_string` writes them: `"3,7"`.
"""
Base.@nospecializeinfer function parse_pk(@nospecialize(T::Type), s)
    natural_pk(T) && !(s isa AbstractString) && return s               # a natural key's value, as it is (#221)
    s isa Integer && return is_auto_pk(pk_kind(T)) ? s : nothing
    s isa UUID && return s
    s isa Tuple && return s
    k = pk_kind(T)
    # (a natural key is its one value, as obj.pk is: #221)
    k === :composite && return natural_pk(T) ? (t = parse_composite_pk(T, string(s)); t === nothing ? nothing : t[1]) :
                                                parse_composite_pk(T, string(s))
    k === :uuid ? tryparse(UUID, string(s)) : tryparse(Int, string(s))
end
Base.@nospecializeinfer function parse_composite_pk(@nospecialize(T::Type), s::AbstractString)
    fs = pk_fields(T)
    bits = length(fs) == 1 ? [s] : split(s, ',')        # a natural key is one value, commas and all
    length(bits) == length(fs) || return nothing
    vals = Any[]
    for (f, b) in zip(fs, bits)
        length(fs) == 1 || (b = unquote_pk(b))           # (pk_string writes a natural key as it is)
        v = f.kind === :fk ? parse_pk(related_model(f), b) : f.kind in INT_KINDS ? tryparse(Int, b) :
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
Base.@nospecializeinfer pk_string(@nospecialize(m::Model)) = (pk = m.pk; pk isa Tuple ? join((quote_pk(string(x)) for x in pk), ",") : string(pk))
const PK_QUOTE_CHARS = Set(":/_#?;@&=+\$,\"[]<>%\n\\")
quote_pk(s::AbstractString) = any(in(PK_QUOTE_CHARS), s) ?
    join(c in PK_QUOTE_CHARS ? "_" * uppercase(string(UInt8(c); base = 16, pad = 2)) : string(c) for c in s) : s
unquote_pk(s::AbstractString) = occursin('_', s) ? replace(s, r"_([0-9A-F]{2})" => m -> string(Char(parse(UInt8, m[2:3]; base = 16)))) : String(s)

"""
How a model's fields map to row keys: `(field, row key, attribute name)` per field. Inherited
multi-table fields are labelled per table (`__place__name`). Work it out once per query and
pass it to `from_row` for every row.
"""
Base.@nospecializeinfer function row_plan(@nospecialize(T::Type))::Vector{Tuple{Field,Symbol,Symbol}}
    mytable = modelmeta(T).table
    plan = Tuple{Field,Symbol,Symbol}[]
    for f in all_fields(T)
        t = modelmeta(f.model).table
        push!(plan, (f, t == mytable ? Symbol(column(f)) : Symbol("__", t, "__", column(f)), attname(f)))
    end
    plan
end

Base.@nospecializeinfer function from_row(@nospecialize(T::Type{<:Model}), row::Dict{Symbol,Any}, plan::Vector{Tuple{Field,Symbol,Symbol}} = row_plan(T))
    composite = is_composite(T)
    # When every column is under its field's own name (no parent tables), the row's Dict becomes the
    # object's data, converted in place, rather than being copied into a new one. Other columns in
    # it (select_related's prefixed ones, annotations) stay, unused by the object.
    inplace = all(p -> p[2] === p[3], plan)
    data = inplace ? row : sizehint!(Dict{Symbol,Any}(), length(plan) + 1)
    data[:id] = composite ? nothing : pk_value(T, get(row, :id, nothing))
    for (f, key, att) in plan
        v = get(row, key, NOTFOUND)
        v === NOTFOUND && continue               # deferred (only/defer, raw): loaded on first access
        data[att] = from_db(f, v)
    end
    composite && (data[:id] = composite_pk(T, data))
    obj = T(data, Dict{Symbol,Any}())
    any_receivers(post_init) && send(post_init, T; instance = obj)
    obj
end
