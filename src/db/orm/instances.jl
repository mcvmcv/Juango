# --- instance operations ----------------------------------------------------------------

"""
    save!(obj; db = nothing, update_fields = nothing) -> obj

INSERT (when `obj.id === nothing`) or UPDATE the object. Sets `auto_now` /
`auto_now_add` timestamps.

`update_fields = [:status, :approved_at]` writes only those columns (Django's
`save(update_fields=...)`), so concurrent changes to other fields aren't overwritten:
`auto_now` fields are written with them (unlike Django; `touch_auto_now = false` leaves them
out unless listed), an empty list saves nothing (and sends no signals),
an unknown name is an error, and so is a row that no longer exists. `pre_save` and
`post_save` receive `update_fields` (a `Set{Symbol}`, or `nothing`).

`force_insert = true` INSERTs even when the object has a primary key (an IntegrityError if the row
exists); `force_update = true` UPDATEs, and it's an error if no row was there to update (Django's
`save(force_insert=..., force_update=...)`).
"""
Base.@nospecializeinfer function save!(@nospecialize(obj::Model); db = nothing, update_fields = nothing, touch_auto_now::Bool = true,
                                      force_insert::Bool = false, force_update::Bool = false)
    T = typeof(obj)
    force_insert && force_update && throw(ArgumentError("Cannot force both insert and updating in model saving."))
    force_insert && update_fields !== nothing && throw(ArgumentError("Cannot force an insert with update_fields."))
    if force_update
        (getfield(obj, :_data)::Dict{Symbol,Any})[:id] === nothing && throw(ArgumentError("Cannot force an update in save!() with no primary key."))
        d = getfield(obj, :_data)::Dict{Symbol,Any}
        update_fields === nothing && (update_fields = [attname(f) for f in all_fields(T) if haskey(d, attname(f)) && f.generated === nothing])
    end
    only = update_fields === nothing ? nothing : update_field_set(T, update_fields)
    only !== nothing && isempty(only) && return obj
    # an object loaded with only()/defer() saves the fields it has (loaded or set since), as Django's
    # save(update_fields = <loaded fields>): tables with none of them aren't written
    if only === nothing && (getfield(obj, :_data)::Dict{Symbol,Any})[:id] !== nothing && !is_composite(T)
        data_ = getfield(obj, :_data)::Dict{Symbol,Any}
        if any(f -> !haskey(data_, attname(f)), all_fields(T))
            only = Set{Symbol}(attname(f) for f in all_fields(T) if haskey(data_, attname(f)))
            isempty(only) && return obj
        end
    end
    if only !== nothing && touch_auto_now          # updated_at is stamped with the listed fields
        foreach(f -> f.auto_now && f.generated === nothing && push!(only, attname(f)), all_fields(T))
    end
    only !== nothing && (getfield(obj, :_data)::Dict{Symbol,Any})[:id] === nothing &&
        throw(ArgumentError("save!(::$(nameof(T)); update_fields) needs an object that's already saved"))
    alias = write_db(obj, db)
    with_db(alias) do
        check_relations_db(obj)
        number_in_order!(obj)
        save_here!(obj, only; force_insert = force_insert)
        set_instance_db!(obj)
    end
end

# --- Meta(order_with_respect_to = :parent) ------------------------------------------------------------

"The foreign key a model is ordered with respect to (`Meta(order_with_respect_to = ...)`), or nothing."
Base.@nospecializeinfer function order_wrt_field(@nospecialize(T::Type))
    k = get(modelmeta(concrete_model(T)).extra, :order_with_respect_to, nothing)
    k === nothing ? nothing : getfield_meta(T, Symbol(k))
end

"The next `_order` among the objects with `pv` as their order_with_respect_to field's value (Django's Max(_order) + 1, else 0)."
Base.@nospecializeinfer function next_in_order(@nospecialize(T::Type), f::Field, pv)
    m = aggregate(filter(base_objects(T), Q(attname(f) => pv)); m = Max(:_order))[:m]
    m === nothing ? 0 : Int(m) + 1
end

"A new object of an ordered model goes last among its parent's (one past the highest `_order`, as Django's)."
Base.@nospecializeinfer function number_in_order!(@nospecialize(obj::Model))
    T = typeof(obj)
    f = order_wrt_field(T)
    f === nothing && return
    data = getfield(obj, :_data)::Dict{Symbol,Any}
    data[:id] === nothing || return
    data[:_order] = next_in_order(T, f, get(data, attname(f), nothing))
    nothing
end

"bulk_create's numbering: the objects without an `_order` go last among their parent's, in the order given (one query per parent)."
Base.@nospecializeinfer function number_in_order!(@nospecialize(objs::AbstractVector), @nospecialize(T::Type))
    f = order_wrt_field(T)
    f === nothing && return
    next = Dict{Any,Int}()
    for o in objs
        data = getfield(o, :_data)::Dict{Symbol,Any}
        get(data, :_order, nothing) === nothing || continue
        pv = get(data, attname(f), nothing)
        n = get!(() -> next_in_order(T, f, pv), next, pv)
        data[:_order] = n
        next[pv] = n + 1
    end
    nothing
end

"""
    get_order(parent, Child) -> Vector of ids

The ids of `parent`'s `Child` objects in their order (Django's `parent.get_child_order()`), for a
model with `Meta(order_with_respect_to = :parent_field)`.
"""
Base.@nospecializeinfer function get_order(@nospecialize(parent::Model), @nospecialize(T::Type{<:Model}))
    f = order_wrt_field(T)
    f === nothing && throw(ArgumentError("$(nameof(T)) has no Meta(order_with_respect_to = ...)"))
    collect(values_list(order_by(filter(base_objects(T), Q(attname(f) => target_value(f, parent))), "_order", "id"), :id; flat = true))
end

"""
    set_order!(parent, Child, ids)

Put `parent`'s `Child` objects in this order (Django's `parent.set_child_order(ids)`): the `i`th id's
`_order` becomes `i - 1`, in one UPDATE. Ids of other parents' objects are ignored.
"""
Base.@nospecializeinfer function set_order!(@nospecialize(parent::Model), @nospecialize(T::Type{<:Model}), ids)
    f = order_wrt_field(T)
    f === nothing && throw(ArgumentError("$(nameof(T)) has no Meta(order_with_respect_to = ...)"))
    want = collect(ids)
    isempty(want) && return nothing
    # one UPDATE of this parent's objects, as Django's bulk_update: an id that isn't one of them is left alone
    update!(filter(base_objects(T), Q(attname(f) => target_value(f, parent)), Q(id__in = want));
            _order = Case((When(Q(id = id); then = Value(i - 1)) for (i, id) in enumerate(want))...; output_field = IntegerField()))
    nothing
end

"The next object in its parent's order (`get_previous_in_order` the previous one), or nothing."
Base.@nospecializeinfer get_next_in_order(@nospecialize(obj::Model)) = neighbour_in_order(obj, 1)
Base.@nospecializeinfer get_previous_in_order(@nospecialize(obj::Model)) = neighbour_in_order(obj, -1)
Base.@nospecializeinfer function neighbour_in_order(@nospecialize(obj::Model), step::Int)
    T = typeof(obj)
    f = order_wrt_field(T)
    f === nothing && throw(ArgumentError("$(nameof(T)) has no Meta(order_with_respect_to = ...)"))
    o = getproperty(obj, :_order)
    sibs = filter(base_objects(T), Q(attname(f) => getproperty(obj, attname(f))))
    step > 0 ? first(order_by(filter(sibs; _order__gt = o), "_order", "id")) :
               first(order_by(filter(sibs; _order__lt = o), "-_order", "-id"))
end

"The attribute names (`author_id` for `author`) of the fields in `update_fields`, checked."
Base.@nospecializeinfer function update_field_set(@nospecialize(T::Type), names)
    out = Set{Symbol}()
    for n in names
        s = Symbol(n)
        f = findfirst(f -> f.name === s || attname(f) === s, all_fields(T))
        f === nothing && throw(ArgumentError("$(nameof(T)) has no field '$s' (in update_fields)"))
        push!(out, attname(all_fields(T)[f]))
    end
    out
end

"Where to write an object: `db`, else the enclosing `using_db` block, else where it came from, else the routers."
Base.@nospecializeinfer write_db(@nospecialize(obj::Model), db) = db !== nothing ? db : db_pinned() ? nothing : something(instance_db(obj), routed_db(typeof(obj), true), Some(nothing))

"Refuse to save an object whose related objects (already loaded) live in another database."
Base.@nospecializeinfer function check_relations_db(@nospecialize(obj::Model))
    me = current_alias()
    for (k, v) in (getfield(obj, :_cache)::Dict{Symbol,Any})
        v isa Model || continue
        other = instance_db(v)
        (other === nothing || other == me) && continue
        ok = ask_routers(allow_relation, obj, v)
        ok === true && continue
        throw(ArgumentError("$(nameof(typeof(obj))).$k is an object from database '$other'; this one is saved to '$me' " *
                            "(a router's allow_relation can permit it)"))
    end
end

"""
Before a save, the keys of related objects assigned while they were unsaved: one saved since gives its key
now (Child(parent = p); save!(p); save!(child)), one still unsaved refuses the save, as Django ("save()
prohibited to prevent data loss due to unsaved related object"), instead of writing NULL.
"""
Base.@nospecializeinfer function sync_related_keys!(@nospecialize(obj::Model), only)
    cache = (getfield(obj, :_cache)::Dict{Symbol,Any})
    isempty(cache) && return
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    for f in all_fields(typeof(obj))
        f.kind === :fk || continue
        (only === nothing || attname(f) in only) || continue
        rel = get(cache, f.name, nothing)
        rel isa Model || continue
        get(data, attname(f), nothing) === nothing || continue          # (a key given directly stands)
        (getfield(rel, :_data)::Dict{Symbol,Any})[:id] === nothing &&
            throw(ArgumentError("save!() prohibited to prevent data loss due to unsaved related object '$(f.name)'"))
        data[attname(f)] = target_value(f, rel)
    end
    # a generic key assigned an object that wasn't saved then: refused now, or its id picked up if it's saved since
    for g in generic_fks(typeof(obj))
        rel = get(cache, g.name, nothing)
        rel isa Model || continue
        ctf, fkf = g.related
        (only === nothing || fkf in only) || continue
        get(data, fkf, nothing) === nothing || continue
        rel.id === nothing && throw(ArgumentError("save!() prohibited to prevent data loss due to unsaved related object '$(g.name)'"))
        data[fkf] = getfield_meta(typeof(obj), fkf).kind in STRING_KINDS ? string(rel.id) : rel.id
    end
end

"Whether the object is being saved as loaded from a fixture: pre_save and post_save's `raw` (Django's)."
const SAVE_RAW = Base.ScopedValues.ScopedValue(false)

Base.@nospecializeinfer function save_here!(@nospecialize(obj::Model), only::Union{Nothing,Set{Symbol}} = nothing; force_insert::Bool = false)
    T = typeof(obj)
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    sync_related_keys!(obj, only)
    ts = timezone_now()
    for f in all_fields(T)
        a = attname(f)
        only === nothing || a in only || continue
        if f.auto_now || (f.auto_now_add && (data[:id] === nothing || get(data, a, missing) === nothing))
            data[a] = auto_now_value(f, ts)
        end
    end
    created = data[:id] === nothing
    has_receivers(pre_save, T) && send(pre_save, T; instance = obj, created = created, update_fields = only, raw = SAVE_RAW[])
    has_receivers(pre_write, T) && send(pre_write, T; action = created ? :insert : :update, via = :save, ids = Any[data[:id]],
                                        fields = only === nothing ? nothing : collect(only), instances = [obj])
    store_uploaded_files!(obj, data)
    exprs = [f for f in all_fields(T) if get(data, attname(f), nothing) isa Expression && (only === nothing || attname(f) in only)]
    chain_ = reverse(vcat([concrete_model(T)], ancestors(T)))     # root table first
    fresh = force_insert && data[:id] !== nothing      # save!(...; force_insert): INSERT with the key given
    if data[:id] === nothing && pk_kind(T) === :uuid
        data[:id] = uuid4()           # UUID keys are made here, so the row is inserted directly
        fresh = true
    end
    if only !== nothing
        # only the tables with a listed field; the row must be there
        tables = [M for M in chain_ if any(f -> attname(f) in only, modelmeta(M).fields)]
        # one table: one UPDATE, no transaction around it (as Django)
        length(tables) == 1 ? mark_for_rollback_on_error(() -> update_columns!(tables[1], data, only)) :
            atomic(() -> foreach(M -> update_columns!(M, data, only), tables); savepoint = false)
    else
        length(chain_) == 1 ? mark_for_rollback_on_error(() -> save_table!(chain_[1], data, true, fresh)) :
            # a new object: its parent row is inserted first, then each child table's row straight after (an
            # INSERT, not an UPDATE that finds nothing, as Django)
            atomic(() -> foreach(M -> save_table!(M, data, M === chain_[1], fresh || (created && M !== chain_[1])), chain_); savepoint = false)
    end
    refresh_computed!(obj)
    refresh_expression_fields!(obj, exprs)
    has_receivers(post_save, T) && send(post_save, T; instance = obj, created = created, update_fields = only, raw = SAVE_RAW[])
    has_receivers(post_write, T) && send(post_write, T; action = created ? :insert : :update, via = :save, ids = Any[obj.pk],
                                         fields = only === nothing ? nothing : collect(only), instances = [obj])
    obj
end

"Read back the values the database computed: generated fields, and db_default fields just filled in."
Base.@nospecializeinfer function refresh_computed!(@nospecialize(obj::Model))
    T = typeof(obj)
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    fs = [f for f in all_fields(T) if f.generated !== nothing || get(data, attname(f), nothing) === DB_DEFAULT]
    isempty(fs) && return obj
    for tbl in unique(modelmeta(f.model).table for f in fs)
        mine = [f for f in fs if modelmeta(f.model).table == tbl]
        row = execute("SELECT " * join([qname(column(f)) for f in mine], ", ") * " FROM $(qname(tbl)) WHERE $(qname("id")) = ?", [data[:id]])
        isempty(row) && continue
        for f in mine
            data[attname(f)] = from_db(f, row[1][Symbol(column(f))])
        end
    end
    obj
end

# --- expressions as field values: obj.views = F(:views) + 1; save!(obj) (#214) ---

"""
The placeholders and parameters for writing `fields` of a row of `M`: `?` and the value, or, for an
expression (`F(:views) + 1`, `Lower(Value("X"))`), its SQL and parameters, as Django compiles one
into the UPDATE or INSERT. Refused, as in Django: aggregates, references through a join, and a
column reference in an INSERT.
"""
Base.@nospecializeinfer function write_values(@nospecialize(M::Type), fields, data, insert::Bool)
    phs, vals = String[], Any[]
    for f in fields
        v = data[attname(f)]
        if v isa Expression
            contains_aggregate(v) && throw(ArgumentError("Aggregate functions are not allowed in this query ($(f.name) = $(repr(v)))"))
            insert && refs_columns(v) && throw(ArgumentError(
                "$(nameof(M)).$(f.name) = $(repr(v)): F() expressions can only be used to update, not to insert"))
            c = SQLCompiler(M)
            sql, ps = compile_expr(c, v)
            isempty(c.joins) || throw(ArgumentError("Joined field references are not permitted in this query ($(f.name) = $(repr(v)))"))
            push!(phs, "($sql)"); append!(vals, ps)
        else
            push!(phs, "?"); push!(vals, to_db(f, v))
        end
    end
    phs, vals
end
"An INSERT's `?` placeholders, in order, replaced by `phs` (expressions' SQL, or `?`)."
function fill_placeholders(sql::AbstractString, phs::Vector{String})
    all(==("?"), phs) && return String(sql)
    i = 0
    replace(sql, "?" => _ -> (i += 1; i <= length(phs) ? phs[i] : "?"))
end
"After a save with expression values: read the values the database computed into the object."
Base.@nospecializeinfer function refresh_expression_fields!(@nospecialize(obj::Model), exprs)
    isempty(exprs) && return
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    for tbl in unique(modelmeta(f.model).table for f in exprs)
        mine = [f for f in exprs if modelmeta(f.model).table == tbl]
        row = execute("SELECT " * join([qname(column(f)) for f in mine], ", ") * " FROM $(qname(tbl)) WHERE $(qname("id")) = ?", [data[:id]])
        isempty(row) && continue
        for f in mine
            data[attname(f)] = from_db(f, row[1][Symbol(column(f))])
        end
    end
end

"UPDATE some columns of one table's row for `save!(...; update_fields)`; the row must exist."
Base.@nospecializeinfer function update_columns!(@nospecialize(M::Type), data, only::Set{Symbol})
    fields = [f for f in modelmeta(M).fields if attname(f) in only && haskey(data, attname(f)) &&     # (not deferred)
                                               f.generated === nothing && data[attname(f)] !== DB_DEFAULT]
    isempty(fields) && return
    phs, vals = write_values(M, fields, data, false)
    sets = join(["$(qname(column(f))) = $ph" for (f, ph) in zip(fields, phs)], ", ")
    if is_composite(M)
        cond = join([qname(column(f)) * " = ?" for f in pk_fields(M)], " AND ")
        n = execute_changes("UPDATE $(qname(modelmeta(M).table)) SET $sets WHERE $cond", vcat(vals, pk_parts(data[:id])))
    else
        n = execute_changes("UPDATE $(qname(modelmeta(M).table)) SET $sets WHERE $(qname("id")) = ?", vcat(vals, data[:id]))
    end
    n == 0 && throw(ArgumentError("save!(...; update_fields or force_update) didn't affect any rows: no $(nameof(M)) with key $(repr(data[:id]))"))
    nothing
end

"Write the columns of one table (`M`'s own fields) for an object's data."
Base.@nospecializeinfer function save_table!(@nospecialize(M::Type), data, root::Bool, fresh::Bool = false)
    meta = modelmeta(M)
    # deferred fields keep their stored values; generated and not-yet-filled db_default ones are the database's
    fields = [f for f in meta.fields if haskey(data, attname(f)) && f.generated === nothing && data[attname(f)] !== DB_DEFAULT]
    cols = [qname(column(f)) for f in fields]
    tbl = qname(meta.table)
    # an UPDATE (Django's blind overwrite, save!(M(id = 1))) sets a db_default field left unset to its db_default
    dbd = [f for f in meta.fields if f.generated === nothing && get(data, attname(f), nothing) === DB_DEFAULT]
    function upd()
        ufs = vcat(fields, dbd)
        d = isempty(dbd) ? data : merge(data, Dict{Symbol,Any}(attname(f) => f.db_default for f in dbd))
        w = write_values(M, ufs, d, false)
        (join(["$(qname(column(f))) = $ph" for (f, ph) in zip(ufs, w[1])], ", "), w[2])
    end
    ins() = write_values(M, fields, data, true)
    if is_composite(M)
        # Like a changed primary key elsewhere: saving under a new key writes a new row.
        key = composite_pk(M, data)
        key === nothing && throw(ArgumentError("$(nameof(M)): every part of the composite primary key needs a value"))
        if data[:id] !== nothing          # loaded or saved before: UPDATE, else (no such row) INSERT
            cond = join([qname(column(f)) * " = ?" for f in pk_fields(M)], " AND ")
            sets, vals = upd()
            n = execute_changes("UPDATE $tbl SET $sets WHERE $cond", vcat(vals, pk_parts(key)))
            n > 0 && (data[:id] = key; return)
        end
        phs, vals = ins()
        execute_changes(fill_placeholders(insert_sql(backend(), tbl, cols), phs) |> s -> replace(s, r" RETURNING .*$" => ""), vals)
        data[:id] = composite_pk(M, data)
        return
    end
    if fresh
        phs, vals = ins()
        execute(fill_placeholders(insert_sql(backend(), tbl, vcat(qname("id"), cols)), vcat("?", phs)) |> s -> replace(s, r" RETURNING .*$" => ""),
                vcat(data[:id], vals))
        return
    end
    if data[:id] !== nothing
        n = if isempty(cols) && isempty(dbd)
            length(execute("SELECT 1 FROM $tbl WHERE $(qname("id")) = ?", [data[:id]]))
        else
            sets, vals = upd()
            execute_changes("UPDATE $tbl SET $sets WHERE $(qname("id")) = ?", vcat(vals, data[:id]))
        end
        n > 0 && return
        phs, vals = ins()
        execute_insert(fill_placeholders(insert_sql(backend(), tbl, vcat(qname("id"), cols)), vcat("?", phs)), vcat(data[:id], vals))
        root && sync_sequence(backend(), meta.table)
        return
    end
    root || error("internal: child table saved before its parent")
    phs, vals = ins()
    data[:id] = execute_insert(fill_placeholders(insert_sql(backend(), tbl, cols), phs), vals)
end

"Delete the object (and cascade to related objects)."
Base.@nospecializeinfer function Base.delete!(@nospecialize(obj::Model); db = nothing)
    T = typeof(obj)
    id = obj.id
    id === nothing && error("cannot delete an unsaved $(T)")
    # nothing to cascade to: one DELETE, no transaction (Django's fast delete)
    with_db(() -> fast_deletable(T) ? delete_ids!(T, [id]) :
                  Base.ScopedValues.with(() -> atomic(() -> delete_rows!(T, [id]); savepoint = false), DELETE_ORIGIN => obj),
            write_db(obj, db))
    (getfield(obj, :_data)::Dict{Symbol,Any})[:id] = nothing
    obj
end

"Reload field values from the database."
Base.@nospecializeinfer function refresh!(@nospecialize(obj::Model); fields = nothing)
    T = typeof(obj)
    db = instance_db(obj)
    if fields !== nothing                     # only these fields (Django's refresh_from_db(fields=...))
        names = Symbol.(collect(fields))
        any(n -> occursin("__", string(n)), names) &&
            throw(ArgumentError("Found \"__\" in fields argument. Relations and transforms are not allowed in fields."))
        cache = (getfield(obj, :_cache)::Dict{Symbol,Any})
        # a relation that isn't a column (reverse keys, many-to-many, a reverse one-to-one): its cached rows go
        rels = [n for n in names if findfield(modelmeta(T), n) === nothing]
        foreach(n -> forget_prefetched!(obj, n), rels)
        names = setdiff(names, rels)
        isempty(names) && return obj
        atts = [attname(getfield_meta(T, n)) for n in names]
        row = with_db(() -> only(values(filter(base_objects(T); id = obj.id), String.(atts)...)), db)
        data = (getfield(obj, :_data)::Dict{Symbol,Any})
        cache = (getfield(obj, :_cache)::Dict{Symbol,Any})
        for (n, a) in zip(names, atts)
            data[a] = row[a]
            delete!(cache, n)                 # a related object loaded through this field
        end
        return obj
    end
    fresh = with_db(() -> get(base_objects(T); id = obj.id), db)
    merge!((getfield(obj, :_data)::Dict{Symbol,Any}), (getfield(fresh, :_data)::Dict{Symbol,Any}))
    empty!((getfield(obj, :_cache)::Dict{Symbol,Any}))
    db === nothing || ((getfield(obj, :_cache)::Dict{Symbol,Any})[:__db] = db)
    obj
end

"Create and save a new object."
Base.@nospecializeinfer create(@nospecialize(T::Type{<:Model}); kw...) = save!(T(; kw...))

"""
What get_or_create/update_or_create create an object with, as Django's `_extract_model_params`: the
lookups that aren't lookups through a relation or a transform (`name__exact` is left out; spell it
in `defaults`), then `defaults`, a callable default called. Names that aren't fields, attnames, `pk`
or a `tattr!` setter are refused, all of them in one message.
"""
Base.@nospecializeinfer function create_params(@nospecialize(T::Type{<:Model}), kw, defaults)
    ps = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(kw) if !occursin("__", string(k)))
    for (k, v) in pairs_of(defaults)
        ps[Symbol(k)] = v isa Base.Callable && !(v isa Type) ? v() : v
    end
    bad = String[]
    for k in keys(ps)
        k in (:pk, :id) && continue
        any(f -> f.name === k || attname(f) === k, all_fields(T)) && continue
        any(g -> g.name === k, generic_fks(T)) && continue            # content_object = obj
        which(tattr!, Tuple{concrete_model(T),Val{k},Any}).sig !== Tuple{typeof(tattr!),Any,Val,Any} && continue
        push!(bad, "'$k'")
    end
    isempty(bad) || throw(LookupError("Invalid field name(s) for model $(nameof(T)): $(join(sort(bad), ", "))."))
    ps
end

"""
Create under a savepoint; if that breaks a unique constraint because another request created the row
meanwhile, return that row instead (Django's get_or_create race handling). Any other IntegrityError,
or one with no row to find, is rethrown.
"""
function create_or_find(make, find)
    try
        (atomic(make), true)
    catch err
        err isa IntegrityError || rethrow()
        o = try find() catch; nothing end
        o === nothing && rethrow()
        (o, false)
    end
end

"`(obj, created::Bool)` — fetch by lookups or create with lookups + `defaults`."
Base.@nospecializeinfer function get_or_create(@nospecialize(T::Type{<:Model}); defaults = Dict{Symbol,Any}(), kw...)
    atomic() do
        o = first(filter(objects(T); kw...))
        o === nothing || return (o, false)
        ps = create_params(T, kw, defaults)
        create_or_find(() -> create(T; ps...), () -> first(filter(objects(T); kw...)))
    end
end

"`(obj, created::Bool)` — update the object matching lookups with `defaults`, or create it."
Base.@nospecializeinfer function update_or_create(@nospecialize(T::Type{<:Model}); defaults = Dict{Symbol,Any}(), create_defaults = nothing, kw...)
    atomic() do
        o = first(filter(objects(T); kw...))
        # create_defaults (Django 5.0): what a new object gets instead of defaults
        if o === nothing
            ps = create_params(T, kw, something(create_defaults, defaults))
            return create_or_find(() -> create(T; ps...), () -> first(filter(objects(T); kw...)))
        end
        for (k, v) in create_params(T, (;), defaults)
            setproperty!(o, k, v)
        end
        (save!(o), false)
    end
end

# --- validation --------------------------------------------------------------------------

const EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
const SLUG_RE = r"^[-a-zA-Z0-9_]+$"
const UNICODE_SLUG_RE = r"^[-\p{L}\p{N}_]+$"
const URL_RE = r"^https?://[^\s/$.?#].[^\s]*$"i

"""
    clean_ip(s, protocol = "both", unpack_ipv4 = false) -> String or (error,)

An IP address in its normal form (`2001:DB8::0:1` → `2001:db8::1`), or a one-element tuple
holding Django's error message.
"""
# eight groups of up to four hex digits (the last two may be a dotted IPv4 address), or fewer with one "::"
function ipv6_shape(t)
    gs = split(t, ':')
    v4 = occursin('.', gs[end])
    all(g -> isempty(g) || (length(g) <= 4 && all(isxdigit, g)), v4 ? gs[1:end-1] : gs) || return false
    n = count(!isempty, v4 ? gs[1:end-1] : gs) + (v4 ? 2 : 0)
    occursin("::", t) ? count("::", t) == 1 && n <= 7 : n == 8
end
function clean_ip(s::AbstractString, protocol = "both", unpack_ipv4 = false)
    p = lowercase(string(protocol))
    msg = p == "ipv4" ? gettext("Enter a valid IPv4 address.") : p == "ipv6" ? gettext("Enter a valid IPv6 address.") :
          gettext("Enter a valid IPv4 or IPv6 address.")
    t = strip(s)
    # IPv4 must be a full dotted quad (the parser also takes the BSD shorthand "1.2.3")
    occursin(':', t) || occursin(r"^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}$", t) || return (msg,)
    # text with a colon that isn't an IPv6 address gets Django's own message
    bad6 = occursin(':', t) && p != "ipv4" ? (gettext("This is not a valid IPv6 address."),) : (msg,)
    occursin(':', t) && !ipv6_shape(t) && return bad6
    ip = try
        parse(Sockets.IPAddr, t)
    catch
        return bad6
    end
    ip isa Sockets.IPv4 && p == "ipv6" && return (msg,)
    ip isa Sockets.IPv6 && p == "ipv4" && return (msg,)
    if ip isa Sockets.IPv6 && unpack_ipv4 && (ip.host >> 32) == 0xffff
        ip = Sockets.IPv4(UInt32(ip.host & 0xffffffff))
    end
    string(ip)
end

"The value an `auto_now` field gets: the timestamp, or its date or time in the current time zone."
function auto_now_value(f::Field, ts)
    f.kind in (:date, :time) || return ts
    local_ = ts isa TimeZones.ZonedDateTime ? make_naive(ts) : ts
    f.kind === :date ? Date(local_) : Dates.Time(local_)
end

"The `step` of a number input for a decimal with `places` digits after the point (\"0.01\")."
# (written as Python writes Decimal(1).scaleb(-places), as Django's: 0.01, then 1e-7 from seven places)
decimal_step(places) = places === nothing ? "any" : places == 0 ? "1" : places <= 6 ? "0." * "0"^(places - 1) * "1" : "1e-$places"

"""
Run per-field validation on a cleaned (typed) value; returns a vector of messages.
Validators are functions `v -> true/nothing` (ok) or an error message `String` / `false`.
"""
function validate_field(f::Field, v)
    errs = String[]
    isempty_val = v === nothing || (v isa AbstractString && isempty(v))
    if isempty_val
        (!f.blank && f.kind !== :bool) && push!(errs, field_message(f, "required", gettext("This field is required.")))
        # a BooleanField that isn't nullable must be true or false
        f.kind === :bool && v === nothing && !f.null && push!(errs, field_message(f, "null", gettext("This field cannot be null.")))
        return errs
    end
    if f.kind === :json && (p = json_nonfinite_path(v)) !== nothing
        push!(errs, field_message(f, "invalid", gettext("JSON can't hold NaN or infinity (at %(path)s)."), Dict("path" => p)))
    end
    if f.kind === :ipaddress
        r = clean_ip(string(v), f.related.protocol, f.related.unpack_ipv4)
        r isa Tuple && return [field_message(f, "invalid", r[1], Dict("value" => v))]
    end
    if f.kind === :binary && f.max_length !== nothing && v isa AbstractVector{UInt8} && length(v) > f.max_length
        push!(errs, field_message(f, "max_length", gettext("Ensure this value has at most %(max)d bytes (it has %(len)d)."),
                                  Dict("max" => f.max_length, "len" => length(v), "limit_value" => f.max_length, "show_value" => length(v), "value" => v)))
    end
    if f.max_length !== nothing && v isa AbstractString && f.kind !== :ipaddress && length(v) > f.max_length
        push!(errs, field_message(f, "max_length", gettext("Ensure this value has at most %(max)d characters (it has %(len)d)."),
                                  Dict("max" => f.max_length, "len" => length(v), "limit_value" => f.max_length, "show_value" => length(v), "value" => v)))
    end
    f.kind === :email && validation_error(EmailValidator(), string(v)) !== nothing &&
        push!(errs, field_message(f, "invalid", gettext("Enter a valid email address."), Dict("value" => v)))
    if f.kind === :slug
        uni = f.related isa NamedTuple && get(f.related, :allow_unicode, false)
        occursin(uni ? UNICODE_SLUG_RE : SLUG_RE, string(v)) ||
            push!(errs, field_message(f, "invalid", uni ? gettext("Enter a valid “slug” consisting of Unicode letters, numbers, underscores, or hyphens.") :
                                                         gettext("Enter a valid “slug” consisting of letters, numbers, underscores or hyphens."), Dict("value" => v)))
    end
    f.kind === :url && validation_error(URLValidator(), string(v)) !== nothing && push!(errs, field_message(f, "invalid", gettext("Enter a valid URL."), Dict("value" => v)))
    if f.kind === :decimal
        r = validation_error(DecimalValidator(f.max_digits, f.decimal_places), v)
        r === nothing || push!(errs, field_message(f, r[1], r[2], validator_params(DecimalValidator(f.max_digits, f.decimal_places), v)))
    end
    if f.kind in INT_KINDS && v isa Integer
        lo, hi = INT_RANGES[f.kind]
        v < lo && push!(errs, field_message(f, "min_value", gettext("Ensure this value is greater than or equal to %(limit_value)s."), Dict("limit_value" => lo)))
        v > hi && push!(errs, field_message(f, "max_value", gettext("Ensure this value is less than or equal to %(limit_value)s."), Dict("limit_value" => hi)))
    end
    cs = f.kind === :typedchoice ? nothing : field_choices(f)    # (a typed choice was checked before it was coerced)
    if cs !== nothing && !any(c -> value_eq(c.first, v) || string(c.first) == string(v), cs)
        push!(errs, field_message(f, "invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v)))
    end
    append!(errs, validator_errors(f, v))
    errs
end

"""
    ValidationError(msg; code = nothing, params = nothing)
    ValidationError([msg, ...])
    ValidationError(Dict(:field => ["msg", ...], ...))

Raised by validation hooks such as a model's `Juango.clean` (and accepted from form `clean`
functions). A message on its own belongs to the whole object (`:__all__`); a Dict names fields.
From a validator, `code` lets a field's `error_messages` replace the message, and `params` fill
in its `%(name)s` placeholders.
"""
struct ValidationError <: Exception
    errors::Dict{Symbol,Vector{String}}
    code::Union{Nothing,String}       # for one message: a field's error_messages can replace it by this code
end
ValidationError(errors::Dict{Symbol,Vector{String}}) = ValidationError(errors, nothing)
ValidationError(msg::AbstractString; code = nothing, params = nothing) =
    ValidationError(Dict(:__all__ => [params === nothing ? String(msg) : interpolate(msg, params)]), code === nothing ? nothing : string(code))
# (a dict in the list adds its messages, as Django's)
ValidationError(msgs::AbstractVector) =
    ValidationError(Dict(:__all__ => String[s for m in msgs for s in (m isa AbstractDict ? ValidationError(m).messages :
                                                                      m isa ValidationError ? m.messages : (string(m),))]))
# (a field's messages: a string, a ValidationError, or a list of them, as Django's)
validation_messages(v) = v isa AbstractString ? String[String(v)] : v isa ValidationError ? v.messages :
                         String[m for x in v for m in (x isa ValidationError ? x.messages : (string(x),))]
ValidationError(d::AbstractDict) =
    ValidationError(Dict{Symbol,Vector{String}}(Symbol(k) => validation_messages(v) for (k, v) in d))
# e.messages: all the messages, as Django's ValidationError.messages
Base.getproperty(e::ValidationError, s::Symbol) =
    s === :messages ? String[m for k in sort!(collect(keys(getfield(e, :errors)))) for m in getfield(e, :errors)[k]] : getfield(e, s)
Base.propertynames(::ValidationError) = (:errors, :code, :messages)
Base.showerror(io::IO, e::ValidationError) =
    print(io, "ValidationError: ", join([k === :__all__ ? join(v, " ") : "$k: " * join(v, " ") for (k, v) in e.errors], "; "))

"""
    clean_value(field, value) -> value

A value for one field, converted and validated as Django's `Field.clean(value, instance)`: text
that is a number for a numeric field becomes the number, then the field's checks (required,
choices, range, length, validators) run. Throws `ValidationError` with the field's messages.

    clean_value(IntegerField(), "2")     # 2
    clean_value(IntegerField(), "a")     # ValidationError
"""
function clean_value(f::Field, v)
    x = v
    if v isa AbstractString && !isempty(v)
        t = strip(v)
        bad() = throw(ValidationError(Dict(something(f.name === :_ ? nothing : f.name, :value) =>
                                           [field_message(f, "invalid", gettext("“%(value)s” value must be a number."), Dict("value" => v))])))
        if f.kind in INT_KINDS
            x = something(tryparse(Int, t), Some(nothing)); x === nothing && bad()
        elseif f.kind === :float
            x = something(tryparse(Float64, t), Some(nothing)); x === nothing && bad()
        elseif f.kind === :decimal
            x = try Decimal(t) catch; bad() end
        elseif f.kind === :bool
            l = lowercase(t)
            x = l in ("true", "1", "t", "yes") ? true : l in ("false", "0", "f", "no") ? false : bad()
        end
    end
    errs = validate_field(f, x)
    isempty(errs) || throw(ValidationError(Dict(something(f.name === :_ ? nothing : f.name, :value) => errs)))
    x
end

"""
    Juango.clean(obj)

A model's own validation, for rules across fields or rows (Django's `Model.clean`). Define it
for your model and `throw(ValidationError(...))`; it may also adjust the object's values.
`full_clean` calls it after checking each field (even when some have errors), and ModelForms
call it, so the admin and generic edit views apply it too. A shared rule on an abstract model
runs for its subtypes; a subtype can add its own and call the shared one with
`invoke(Juango.clean, Tuple{MyBase}, obj)`.

    function Juango.clean(b::NumberBlock)
        b.first > b.last && throw(ValidationError("The first number comes after the last."))
    end
"""
clean(@nospecialize(obj::Model)) = nothing

"The errors of `clean(obj)`: a Dict, empty when it passes."
Base.@nospecializeinfer function model_clean_errors(@nospecialize(obj::Model))
    try
        clean(obj)
        Dict{Symbol,Vector{String}}()
    catch e
        e isa ValidationError || rethrow()
        e.errors
    end
end

"""
    full_clean(obj; exclude=Symbol[]) -> Dict{Symbol,Vector{String}}

Validate an instance against its field definitions (required, max_length,
choices, email/slug/url format, custom validators, uniqueness). Empty dict = valid.
"""
Base.@nospecializeinfer function full_clean(@nospecialize(obj::Model); exclude = Symbol[], validate_unique::Bool = true, validate_constraints::Bool = true)
    T = typeof(obj)
    errors = clean_fields(obj; exclude = exclude)
    merge_errors!(errors, model_clean_errors(obj))
    # uniqueness and constraints only for fields that are clean and not excluded
    skip = union(Symbol.(exclude), keys(errors))
    merge_errors!(errors, validate_unique ? Juango.validate_unique(obj; exclude = skip) : Dict{Symbol,Vector{String}}())
    merge_errors!(errors, validate_constraints ? Juango.validate_constraints(obj; exclude = skip) : Dict{Symbol,Vector{String}}())
    errors
end
merge_errors!(a, b) = (foreach(((k, v),) -> append!(get!(a, k, String[]), v), b); a)

"""
    clean_fields(obj; exclude = Symbol[]) -> Dict{Symbol,Vector{String}}

Check each editable field's value on its own: required, length, format, choices, ranges and the
field's validators (the first step of `full_clean`).
"""
Base.@nospecializeinfer function clean_fields(@nospecialize(obj::Model); exclude = Symbol[])
    T = typeof(obj)
    errors = Dict{Symbol,Vector{String}}()
    for f in all_fields(T)
        # (a BinaryField isn't editable by default but is checked, as Django checks every field)
        (f.name in exclude || (!f.editable && f.kind !== :binary)) && continue
        v = getproperty(obj, attname(f))
        !f.editable && (v === nothing || isempty(v)) && continue      # (a non-editable BinaryField: only its length)
        v === DB_DEFAULT && continue                  # the database supplies it
        # (the model's own messages, as Django's Field.validate: a form says "This field is required.")
        if v === nothing && !f.null
            errors[f.name] = [field_message(f, "null", gettext("This field cannot be null."))]
            continue
        elseif v isa AbstractString && isempty(v) && !f.blank
            errors[f.name] = [field_message(f, "blank", gettext("This field cannot be blank."))]
            continue
        end
        errs = validate_field(f, v)
        isempty(errs) || (errors[f.name] = errs)
    end
    errors
end

"""
    validate_unique(obj; exclude = Symbol[]) -> Dict{Symbol,Vector{String}}

Check `unique` fields, `unique_together` and `unique_for_date` / `_month` / `_year` against the
other rows (Django's `Model.validate_unique`). Errors of whole-row checks are under `:__all__`.
A field's messages can be replaced by code ("unique", "unique_for_date") through its
`error_messages`, with Django's parameters (%(model_name)s, %(field_label)s,
%(date_field_label)s, %(lookup_type)s); `message_fields` gives other fields' `error_messages` to
use (a ModelForm's), and `unique_together_message` replaces the `unique_together` one
(%(model_name)s, %(field_labels)s).
"""
Base.@nospecializeinfer function validate_unique(@nospecialize(obj::Model); exclude = Symbol[], message_fields = nothing,
                                                 unique_together_message = nothing)
    T = typeof(obj)
    errors = Dict{Symbol,Vector{String}}()
    others(q) = obj.id === nothing ? q : filter(q, !Q(id = obj.id))
    msgf(f) = message_fields !== nothing && haskey(message_fields, f.name) ? message_fields[f.name] : f
    for f in all_fields(T)
        f.name in exclude && continue
        v = field_data(obj, attname(f))
        (v === nothing || v === DB_DEFAULT) && continue
        vname = uppercasefirst(string(modelmeta(something(f.model, T)).verbose_name))     # (the model with the field: a parent's)
        # (a natural primary key is unique too)
        if (f.unique || f.primary_key) && exists(others(filter(base_objects(f.model), Q(attname(f) => v))))
            push!(get!(errors, f.name, String[]), field_message(msgf(f), "unique", gettext("%(model_name)s with this %(field_label)s already exists."),
                Dict("model_name" => vname, "field_label" => label(f), "model" => vname, "field" => label(f))))
        end
        if f.unique_for !== nothing
            kind, dname = f.unique_for
            dname in exclude && continue
            df = getfield_meta(T, dname)
            d = field_data(obj, attname(df))
            d === nothing && continue
            d isa TimeZones.ZonedDateTime && (d = make_naive(d))
            parts = Any[Symbol(dname, "__year") => Dates.year(d)]
            kind in (:date, :month) && push!(parts, Symbol(dname, "__month") => Dates.month(d))
            kind === :date && push!(parts, Symbol(dname, "__day") => Dates.day(d))
            if exists(others(filter(base_objects(f.model), Q(attname(f) => v), Q(:AND, parts, false))))
                push!(get!(errors, f.name, String[]), field_message(msgf(f), "unique_for_date", gettext("%(field_label)s must be unique for %(date_field_label)s %(lookup_type)s."),
                    Dict("model_name" => vname, "field_label" => label(f), "date_field_label" => label(df), "lookup_type" => string(kind))))
            end
        end
    end
    values = Dict{Symbol,Any}(f.name => field_data(obj, attname(f)) for f in all_fields(T) if !(f.name in exclude))
    errs = unique_together_errors(T, values, obj.id; message = unique_together_message)
    isempty(errs) || append!(get!(errors, :__all__, String[]), errs)
    errors
end

"""
    validate_constraints(obj; exclude = Symbol[]) -> Dict{Symbol,Vector{String}}

Check `Meta(constraints = ...)` (`UniqueConstraint`, `CheckConstraint`, `ExclusionConstraint`
where it can be checked) for the object's values, under `:__all__` (Django's `Model.validate_constraints`).
Constraints that use an excluded field are skipped.
"""
Base.@nospecializeinfer function validate_constraints(@nospecialize(obj::Model); exclude = Symbol[])
    T = typeof(obj)
    values = Dict{Symbol,Any}(f.name => field_data(obj, attname(f)) for f in all_fields(T) if !(f.name in exclude))
    errs = constraint_errors(T, values, obj.id)
    isempty(errs) ? Dict{Symbol,Vector{String}}() : Dict{Symbol,Vector{String}}(:__all__ => errs)
end

"""
    get_next_by(obj, :field; filters...)
    get_previous_by(obj, :field; filters...)

The next (or previous) object by a date or datetime field, among the rows matching `filters`;
ties are broken by primary key (Django's `get_next_by_FOO`). Throws `DoesNotExist` at the end.
Also `obj.get_next_by_created` and `obj.get_previous_by_created`.
"""
Base.@nospecializeinfer get_next_by(@nospecialize(obj::Model), field::Symbol; kw...) = adjacent_by(obj, field, true; kw...)
Base.@nospecializeinfer get_previous_by(@nospecialize(obj::Model), field::Symbol; kw...) = adjacent_by(obj, field, false; kw...)
Base.@nospecializeinfer function adjacent_by(@nospecialize(obj::Model), field::Symbol, next::Bool; kw...)
    T = typeof(obj)
    f = getfield_meta(T, field)
    f.kind in (:date, :datetime) || throw(ArgumentError("get_next_by: $field isn't a date or datetime field"))
    obj.id === nothing && throw(ArgumentError("get_next_by: $T is not saved"))
    v = field_data(obj, attname(f))
    v === nothing && throw(ArgumentError("get_next_by: $field is NULL"))
    op = next ? "gt" : "lt"
    q = Q(Symbol(field, "__", op) => v) | Q(:AND, Any[field => v, Symbol("id__", op) => obj.id], false)
    qs = filter(filter(base_objects(T), q); kw...) |> order_by(next ? string(field) : "-" * string(field), next ? "id" : "-id")
    o = first(qs)
    o === nothing && throw(DoesNotExist(T, "$(next ? "next" : "previous") by $field"))
    o
end

"Messages for `Meta(unique_together = ...)` sets that `values` would duplicate."
Base.@nospecializeinfer function unique_together_errors(@nospecialize(T::Type{<:Model}), values, id; message = nothing)
    errs = String[]
    # a multi-table child is checked against its parents' sets too (in their tables), as Django
    for M in unique!(Any[concrete_model(T); ancestors(T)]), u in modelmeta(M).unique_together
        all(n -> haskey(values, n), u) || continue
        vals = [values[n] isa Model ? values[n].id : values[n] for n in u]
        any(isnothing, vals) && continue
        qs = filter(base_objects(M), Q(:AND, Any[n => v for (n, v) in zip(u, vals)], false))
        id === nothing || (qs = filter(qs, !Q(id = id)))
        if exists(qs)
            mname, labels = uppercasefirst(string(modelmeta(M).verbose_name)), join([label(findfield(modelmeta(M), n)) for n in u], " and ")
            push!(errs, interpolate(something(message, gettext("%(model_name)s with this %(field_labels)s already exists.")),
                                    Dict("model_name" => mname, "field_labels" => labels, "model" => mname, "fields" => labels)))
        end
    end
    unique!(errs)
end
