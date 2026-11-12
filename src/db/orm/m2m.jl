# --- many-to-many ----------------------------------------------------------------------------

"Context carried by a many-to-many queryset: the join model and which FK points at `id`."
struct M2MOwner
    through::Type
    mine::Field      # FK in the join model pointing at the instance
    other::Field     # FK pointing at the related objects
    id::Any
    forward::Bool    # changed from the side that declares the ManyToManyField
    symmetrical::Bool  # also keep the mirrored rows (other -> instance)
end

function m2m_queryset(m::Model, f::Field, forward::Bool)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    id = getfield(m, :_data)[:id]
    step1, step2 = m2m_path(f, !forward)      # from the other model back to this instance
    qs = filter(objects(Other), Q(Symbol(step1, "__", step2) => id))
    chain(qs; owner = M2MOwner(through_model(f), mine, other, id, forward, f.symmetrical), db = instance_db(m))
end

function m2m_owner(qs::QuerySet)
    qs.owner isa M2MOwner || throw(ArgumentError("add!/remove!/set!/clear! need a many-to-many relation such as post.tags"))
    qs.owner.id === nothing && throw(ArgumentError("save the object before changing its many-to-many relations"))
    qs.owner
end
objid(x::Model) = (x.id === nothing && throw(ArgumentError("cannot relate an unsaved $(typeof(x))")); x.id)
objid(x) = x

"Send m2m_changed for a many-to-many change (only when someone listens)."
function m2m_signal(o, action, ids)
    has_receivers(m2m_changed, o.through) || return
    owner = related_model(o.mine)
    send(m2m_changed, o.through; action = action, instance = get(base_objects(owner); id = o.id),
         model = related_model(o.other), pk_set = ids === nothing ? nothing : Set(ids), reverse = !o.forward)
end

"""
    add!(post.tags, tag1, tag2; through_defaults=Dict())

Add objects (or ids) to a many-to-many relation. Already related objects are skipped.
`through_defaults` fills extra fields of a custom `through` model.
"""
function add!(qs::QuerySet, objs...; through_defaults = Dict{Symbol,Any}())
    o = m2m_owner(qs)
    ids = unique(objid.(collect(objs)))
    isempty(ids) && return qs
    atomic() do
        have = Set(values_list(filter(base_objects(o.through), Q(attname(o.mine) => o.id), Q(Symbol(attname(o.other), "__in") => ids)),
                               attname(o.other); flat = true))
        new = [id for id in ids if !(id in have)]
        isempty(new) && return
        m2m_signal(o, :pre_add, new)
        for id in new
            save!(o.through(; attname(o.mine) => o.id, attname(o.other) => id,
                            (Symbol(k) => v for (k, v) in pairs(through_defaults))...))
        end
        if o.symmetrical          # and the other way round
            back = Set(values_list(filter(base_objects(o.through), Q(attname(o.other) => o.id), Q(Symbol(attname(o.mine), "__in") => new)),
                                   attname(o.mine); flat = true))
            for id in new
                id in back || id == o.id || save!(o.through(; attname(o.mine) => id, attname(o.other) => o.id))
            end
        end
        m2m_signal(o, :post_add, new)
    end
    qs
end

"Remove objects (or ids) from a many-to-many relation."
function remove!(qs::QuerySet, objs...)
    o = m2m_owner(qs)
    ids = objid.(collect(objs))
    isempty(ids) && return qs
    m2m_signal(o, :pre_remove, ids)
    delete!(filter(base_objects(o.through), Q(attname(o.mine) => o.id), Q(Symbol(attname(o.other), "__in") => ids)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(attname(o.other) => o.id), Q(Symbol(attname(o.mine), "__in") => ids)))
    m2m_signal(o, :post_remove, ids)
    qs
end

"Remove every object from a many-to-many relation."
function clear!(qs::QuerySet)
    o = m2m_owner(qs)
    m2m_signal(o, :pre_clear, nothing)
    delete!(filter(base_objects(o.through), Q(attname(o.mine) => o.id)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(attname(o.other) => o.id)))
    m2m_signal(o, :post_clear, nothing)
    qs
end

"Make a many-to-many relation contain exactly `objs`."
function set!(qs::QuerySet, objs; through_defaults = Dict{Symbol,Any}())
    o = m2m_owner(qs)
    want = unique(objid.(collect(objs)))
    atomic() do
        have = values_list(filter(base_objects(o.through), Q(attname(o.mine) => o.id)), attname(o.other); flat = true)
        gone = setdiff(have, want)
        isempty(gone) || remove!(qs, gone...)
        add!(qs, setdiff(want, have)...; through_defaults = through_defaults)
    end
    qs
end

function prefetch_m2m!(objs::Vector, name, f::Field, forward::Bool, qs, to_attr)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    ids = [o.id for o in objs]
    pairs_ = values_list(filter(base_objects(through_model(f)), Q(Symbol(attname(mine), "__in") => ids)), attname(mine), attname(other))
    owners_of = Dict{Any,Vector{Any}}()
    for (mid, oid) in pairs_
        push!(get!(() -> Any[], owners_of, oid), mid)
    end
    targets = isempty(owners_of) ? Other[] : fetch(filter(something(qs, objects(Other)); id__in = collect(keys(owners_of))))
    groups = Dict{Any,Vector{Other}}()
    for t in targets, mid in get(owners_of, t.id, Any[])
        push!(get!(() -> Other[], groups, mid), t)
    end
    for o in objs
        getfield(o, :_cache)[something(to_attr, name)] = PrefetchedList(get(groups, o.id, Other[]))
    end
    targets
end
