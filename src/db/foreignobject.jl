# Multi-column relations (ForeignObject) ------------------------------------------------------------------
#
# A relation made of fields the model already has, matched against fields of the target:
# Django's `ForeignObject`, which is how a model points at one with a composite primary key.
#
#     @model struct OrderLine
#         order = ForeignKey(Order, on_delete = :CASCADE)
#         product = ForeignKey(Product, on_delete = :CASCADE)
#         quantity = IntegerField()
#         Meta(pk = CompositePrimaryKey(:order, :product))
#     end
#     @model struct Shipment
#         order = ForeignKey(Order, on_delete = :CASCADE)
#         product = ForeignKey(Product, on_delete = :CASCADE)
#         line = ForeignObject(OrderLine; from_fields = (:order, :product), related_name = :shipments)
#     end
#
#     s.line                                    # the OrderLine with s's order and product
#     s.line = other_line                       # sets s.order_id and s.product_id
#     line.shipments                            # a queryset of the shipments pointing at it
#     filter(Shipment; line__quantity__gt = 2)  # joins on both columns
#     filter(OrderLine; shipments__id = 3)
#
# Deleting the target applies `on_delete` (:CASCADE, :SET_NULL, :PROTECT, :DO_NOTHING) to the
# rows pointing at it. As in Django, there is no database constraint (the fields are ordinary
# columns), and the relation isn't a form field: edit the fields it is made of.

"""
    ForeignObject(Model; from_fields, to_fields = <Model's primary key>, on_delete = :CASCADE, related_name = nothing)

A relation through several of this model's fields (`from_fields`) to the fields of `Model`
with the same values (`to_fields`, by default its primary key: the parts of a
`CompositePrimaryKey`, else `:id`).
"""
ForeignObject(to; from_fields, to_fields = nothing, on_delete = :CASCADE, related_name = nothing) =
    Field(:fobj; related = to, through = (Symbol[Symbol(x) for x in from_fields], to_fields === nothing ? nothing : Symbol[Symbol(x) for x in to_fields]),
          on_delete = on_delete, related_name = related_name === nothing ? nothing : Symbol(related_name), editable = false, blank = true)

foreign_objects(T::Type) = get(modelmeta(concrete_model(T)).extra, :foreign_objects, Field[])

"(this model's attname, its column, the target's attname, its column) for each part of a ForeignObject."
function fobj_parts(f::Field)
    M = related_model(f)
    from, to = f.through
    to === nothing && (to = is_composite(M) ? Symbol[g.name for g in pk_fields(M)] : [:id])
    length(from) == length(to) ||
        throw(ArgumentError("$(nameof(f.model)).$(f.name): from_fields and to_fields must have the same length"))
    side(T, n) = n === :id ? (:id, "id") : (g = getfield_meta(T, n); (attname(g), column(g)))
    [(side(f.model, a)..., side(M, b)...) for (a, b) in zip(from, to)]
end

"ForeignObjects pointing at `T`: `(accessor name, model, field)`."
reverse_foreign_objects(T::Type) = cached_relations(:fobj_reverse, T) do T
    out = Tuple{Symbol,Any,Field}[]
    for M in MODEL_LIST, f in foreign_objects(M)
        concrete_model(related_model(f)) === concrete_model(T) || continue
        push!(out, (something(f.related_name, Symbol(lowercase(modelmeta(M).name), :_set)), M, f))
    end
    out
end
find_reverse_fobj(T::Type, name) = (i = findfirst(r -> string(r[1]) == string(name), reverse_foreign_objects(T));
                                    i === nothing ? nothing : reverse_foreign_objects(T)[i])

function get_fobj(m::Model, f::Field)
    parts = fobj_parts(f)
    vals = Any[field_data(m, p[1]) for p in parts]
    any(isnothing, vals) && return nothing
    cache = getfield(m, :_cache)
    c = get(cache, f.name, nothing)
    c !== nothing && all(getfield(c, :_data)[p[3]] == v for (p, v) in zip(parts, vals)) && return c
    M = related_model(f)
    obj = with_db(() -> first(filter(base_objects(M), (Q(p[3] => v) for (p, v) in zip(parts, vals))...)), instance_db(m))
    obj === nothing || (cache[f.name] = obj)
    obj
end

function set_fobj!(m::Model, f::Field, v)
    data = getfield(m, :_data)
    for p in fobj_parts(f)
        data[p[1]] = v === nothing ? nothing : getfield(v, :_data)[p[3]]
    end
    v === nothing ? delete!(getfield(m, :_cache), f.name) : (getfield(m, :_cache)[f.name] = v)
    v
end

"The rows of `M` whose ForeignObject `f` points at `m`."
function fobj_queryset(m::Model, M::Type, f::Field)
    data = getfield(m, :_data)
    chain(filter(objects(M), (Q(p[1] => data[p[3]]) for p in fobj_parts(f))...); db = instance_db(m))
end

"SQL matching `a` (the ForeignObject's model) to `b` (its target) on every part."
fobj_on(parts, a, b) = join(["$(qcol(a, p[2])) = $(qcol(b, p[4]))" for p in parts], " AND ")

"Lookups through a ForeignObject (forward, `reverse = false`) or back from its target."
function compile_fobj_lookup(c::SQLCompiler, alias, g::Field, M::Type, rest, lookup, value, negated, reverse::Bool, key)
    parts = fobj_parts(g)
    on(a) = reverse ? fobj_on(parts, a, alias) : fobj_on(parts, alias, a)
    mt = qname(modelmeta(M).table)
    if isempty(rest) && lookup == "isnull" && !reverse
        sql = join(["$(qcol(alias, p[2])) IS NULL" for p in parts], " OR ")
        return (truthy(value) ? "($sql)" : "NOT ($sql)", Any[])
    elseif isempty(rest) && lookup == "isnull"
        a = new_alias!(c)
        ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(on(a)))"
        return (truthy(value) ? "NOT " * ex : ex, Any[])
    elseif isempty(rest) && lookup == "exact" && !reverse && (value isa Model || value === nothing)
        value === nothing && return compile_fobj_lookup(c, alias, g, M, rest, "isnull", true, negated, reverse, key)
        return compile_q(c, alias, g.model, Q(:AND, Any[p[1] => getfield(value, :_data)[p[3]] for p in parts], false), negated)
    end
    subkey = join(vcat(isempty(rest) ? ["pk"] : rest, lookup), "__")
    if negated
        a = new_alias!(c)
        sql, ps = compile_lookup(c, a, M, subkey, value, negated)
        return ("EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(on(a)) AND $sql)", ps)
    end
    p1 = parts[1]
    childcol, parentcol = reverse ? (p1[2], p1[4]) : (p1[4], p1[2])
    more = parts[2:end]
    extra = isempty(more) ? nothing : (a -> reverse ? fobj_on(more, a, alias) : fobj_on(more, alias, a))
    a = join!(c, alias, key, modelmeta(M).table, childcol, parentcol; left = true, extra_on = extra)
    reverse && (c.distinct = true)
    compile_lookup(c, a, M, subkey, value, negated)
end

"The rows of `M` whose ForeignObject `f` points at the `T` rows with these keys (nothing if none can)."
function fobj_referrers(@nospecialize(T), @nospecialize(M), f::Field, keys::Vector)
    doomed = fetch(filter(base_objects(T); pk__in = keys))
    isempty(doomed) && return nothing
    parts = fobj_parts(f)
    filter(base_objects(M), reduce(|, [Q(:AND, Any[p[1] => getfield(o, :_data)[p[3]] for p in parts], false) for o in doomed]))
end

"Apply `on_delete` to the rows whose ForeignObjects point at `T` rows with these keys."
function delete_fobj_refs!(T::Type, keys::Vector)
    rels = reverse_foreign_objects(T)
    isempty(rels) && return nothing
    doomed = fetch(filter(base_objects(T); pk__in = keys))
    isempty(doomed) && return nothing
    for (_, M, f) in rels
        parts = fobj_parts(f)
        conds = [Q(:AND, Any[p[1] => getfield(o, :_data)[p[3]] for p in parts], false) for o in doomed]
        rel = filter(base_objects(M), reduce(|, conds))
        if f.on_delete === :CASCADE || f.on_delete === :RESTRICT
            delete_ids!(M, row_keys(rel))
        elseif f.on_delete === :SET_NULL
            update!(rel; (p[1] => nothing for p in parts)...)
        elseif f.on_delete === :PROTECT
            exists(rel) && throw(ProtectedError("cannot delete $(nameof(T)) objects because they are referenced through protected foreign object $(nameof(M)).$(f.name)"))
        end
    end
    nothing
end
