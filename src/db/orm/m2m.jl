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

Base.@nospecializeinfer function m2m_queryset(@nospecialize(m::Model), f::Field, forward::Bool)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    id = (getfield(m, :_data)::Dict{Symbol,Any})[:id]
    step1, step2 = m2m_path(f, !forward)      # from the other model back to this instance
    qs = filter(objects(Other), Q(Symbol(step1, "__", step2) => id))
    chain(qs; owner = M2MOwner(through_model(f), mine, other, id, forward, f.symmetrical), db = instance_db(m))
end

function m2m_owner(qs::QuerySet)
    qs.owner isa M2MOwner || throw(ArgumentError("add!/remove!/set!/clear! need a many-to-many relation such as post.tags"))
    qs.owner.id === nothing && throw(ArgumentError("save the object before changing its many-to-many relations"))
    qs.owner
end
# The join model's keys may store another field than the id (to_field, #220): conditions go through the
# related id (`mine__id`, which is the column itself without a to_field), and new rows get the stored value.
idkey(f::Field) = Symbol(f.name, "__id")
idkeys(f::Field) = Symbol(f.name, "__id__in")
stored_value(f::Field, id) = fk_to_field(f) === nothing ? id : getproperty(get(base_objects(related_model(f)); id = id), fk_to_field(f))
Base.@nospecializeinfer objid(@nospecialize(x::Model)) = (x.id === nothing && throw(ArgumentError("cannot relate an unsaved $(typeof(x))")); x.id)
objid(x) = x

"Send m2m_changed for a many-to-many change (only when someone listens)."
function m2m_signal(o, action, ids)
    m2m = has_receivers(m2m_changed, o.through)
    w = startswith(string(action), "post_") && has_receivers(post_write, o.through)
    pw = startswith(string(action), "pre_") && has_receivers(pre_write, o.through)
    (m2m || w || pw) || return
    owner = related_model(o.mine)
    inst = get(base_objects(owner); id = o.id)
    pks = ids === nothing ? nothing : Set(ids)
    m2m && send(m2m_changed, o.through; action = action, instance = inst, model = related_model(o.other), pk_set = pks, reverse = !o.forward)
    pw && send(pre_write, o.through; action = :m2m, via = action, ids = nothing, fields = nothing, instances = nothing,
               instance = inst, model = related_model(o.other), pk_set = pks)
    w && send(post_write, o.through; action = :m2m, via = action, ids = nothing, fields = nothing, instances = nothing,
              instance = inst, model = related_model(o.other), pk_set = pks)
end

"""
    add!(post.tags, tag1, tag2; through_defaults=Dict())

Add objects (or ids) to a many-to-many relation. Already related objects are skipped.
`through_defaults` fills extra fields of a custom `through` model.
"""
function add!(qs::QuerySet, objs...; through_defaults = Dict{Symbol,Any}(), bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_add!(qs, objs...; bulk = bulk)
    o = m2m_owner(qs)
    ids = unique(objid.(collect(objs)))
    isempty(ids) && return qs
    atomic() do
        have = Set(values_list(filter(base_objects(o.through), Q(idkey(o.mine) => o.id), Q(idkeys(o.other) => ids)),
                               idkey(o.other); flat = true))
        new = [id for id in ids if !(id in have)]
        isempty(new) && return
        m2m_signal(o, :pre_add, new)
        for id in new
            save!(o.through(; attname(o.mine) => stored_value(o.mine, o.id), attname(o.other) => stored_value(o.other, id),
                            (Symbol(k) => v for (k, v) in pairs(through_defaults))...))
        end
        if o.symmetrical          # and the other way round
            back = Set(values_list(filter(base_objects(o.through), Q(idkey(o.other) => o.id), Q(idkeys(o.mine) => new)),
                                   idkey(o.mine); flat = true))
            for id in new
                id in back || id == o.id || save!(o.through(; attname(o.mine) => stored_value(o.mine, id), attname(o.other) => stored_value(o.other, o.id)))
            end
        end
        m2m_signal(o, :post_add, new)
    end
    qs
end

"Remove objects (or ids) from a many-to-many relation."
function remove!(qs::QuerySet, objs...; bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_remove!(qs, objs...; bulk = bulk)
    o = m2m_owner(qs)
    ids = objid.(collect(objs))
    isempty(ids) && return qs
    m2m_signal(o, :pre_remove, ids)
    delete!(filter(base_objects(o.through), Q(idkey(o.mine) => o.id), Q(idkeys(o.other) => ids)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(idkey(o.other) => o.id), Q(idkeys(o.mine) => ids)))
    m2m_signal(o, :post_remove, ids)
    qs
end

"Remove every object from a many-to-many relation."
function clear!(qs::QuerySet; bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_clear!(qs; bulk = bulk)
    o = m2m_owner(qs)
    m2m_signal(o, :pre_clear, nothing)
    delete!(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(idkey(o.other) => o.id)))
    m2m_signal(o, :post_clear, nothing)
    qs
end

"Make a many-to-many relation contain exactly `objs`."
function set!(qs::QuerySet, objs; through_defaults = Dict{Symbol,Any}(), bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_set!(qs, objs; bulk = bulk)
    o = m2m_owner(qs)
    want = unique(objid.(collect(objs)))
    atomic() do
        have = collect(values_list(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)), idkey(o.other); flat = true))
        gone = setdiff(have, want)
        isempty(gone) || remove!(qs, gone...)
        add!(qs, setdiff(want, have)...; through_defaults = through_defaults)
    end
    qs
end

# --- reverse foreign keys: reporter.article as a related manager -------------------------------------------

"Context carried by a reverse foreign key's queryset (`reporter.article`): the key and the object it points at."
struct ReverseFKOwner
    fk::Field        # Article.reporter
    model::Type      # Article
    instance::Any    # the reporter
    name::Symbol     # the relation's name on the instance (:article): its prefetched rows are dropped by a change
end
"After a change through a relation, its prefetched rows are stale: the next access queries (as Django)."
rev_changed!(o::ReverseFKOwner) = (delete!((getfield(o.instance, :_cache)::Dict{Symbol,Any}), o.name); nothing)

function rev_check(o::ReverseFKOwner, @nospecialize(obj))
    obj isa Model && check_model_type(o.model, obj) isa Model ||
        throw(ArgumentError("'$(nameof(o.model))' instance expected, got $(repr(obj))"))
    obj
end
function rev_nullable(o::ReverseFKOwner, what)
    o.fk.null || throw(ArgumentError("$what: $(nameof(o.model)).$(o.fk.name) isn't nullable, so its objects can't be removed " *
                                     "from $(nameof(typeof(o.instance))) (delete them, or give them another)"))
end

"""
    add!(reporter.article, a1, a2; bulk = true)

Point the objects' foreign key at the owner (Django's `RelatedManager.add`): one UPDATE, or with
`bulk = false` a `save!` of each (the way to add unsaved objects).
"""
function rev_add!(qs::QuerySet, objs...; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    foreach(x -> rev_check(o, x), objs)
    isempty(objs) && return qs
    v = target_value(o.fk, o.instance)
    v === nothing && throw(ArgumentError("save the $(nameof(typeof(o.instance))) before adding objects to its $(o.fk.name) relation"))
    if bulk
        any(x -> x.pk === nothing, objs) &&
            throw(ArgumentError("$(repr(first(x for x in objs if x.pk === nothing))) isn't saved: use bulk = false or save it first"))
        update!(filter(base_objects(o.model); pk__in = [x.pk for x in objs]); attname(o.fk) => v)
        foreach(x -> setproperty!(x, o.fk.name, o.instance), objs)
    else
        atomic() do
            foreach(x -> (setproperty!(x, o.fk.name, o.instance); save!(x)), objs)
        end
    end
    rev_changed!(o)
    qs
end
"`remove!(reporter.article, a)`: set the objects' foreign key to NULL (a nullable key only), as Django."
function rev_remove!(qs::QuerySet, objs...; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    rev_nullable(o, "remove!")
    foreach(x -> rev_check(o, x), objs)
    isempty(objs) && return qs
    v = target_value(o.fk, o.instance)
    for x in objs
        field_data(x, attname(o.fk)) == v || throw(DoesNotExist(o.model, "$(repr(x)) is not related to $(repr(o.instance))"))
    end
    if bulk
        update!(filter(base_objects(o.model); pk__in = [x.pk for x in objs]); attname(o.fk) => nothing)
        foreach(x -> setproperty!(x, o.fk.name, nothing), objs)
    else
        atomic(() -> foreach(x -> (setproperty!(x, o.fk.name, nothing); save!(x)), objs))
    end
    rev_changed!(o)
    qs
end
"`clear!(reporter.article)`: set every related object's foreign key to NULL (a nullable key only)."
function rev_clear!(qs::QuerySet; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    rev_nullable(o, "clear!")
    rel = filter(base_objects(o.model), Q(attname(o.fk) => target_value(o.fk, o.instance)))
    bulk ? update!(rel; attname(o.fk) => nothing) : atomic(() -> foreach(x -> (setproperty!(x, o.fk.name, nothing); save!(x)), fetch(rel)))
    rev_changed!(o)
    qs
end
"""
    set!(reporter.article, [a1, a2])

Make the relation contain these objects: the others are removed when the key is nullable (else they
stay, as Django can't take them away), and the new ones added.
"""
function rev_set!(qs::QuerySet, objs; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    want = collect(objs)
    foreach(x -> rev_check(o, x), want)
    atomic() do
        if o.fk.null
            keep = Set(x.pk for x in want)
            gone = [x for x in fetch(filter(base_objects(o.model), Q(attname(o.fk) => target_value(o.fk, o.instance)))) if !(x.pk in keep)]
            isempty(gone) || rev_remove!(qs, gone...; bulk = bulk)
        end
        v = target_value(o.fk, o.instance)
        new = [x for x in want if x.pk === nothing || field_data(x, attname(o.fk)) != v]
        isempty(new) || rev_add!(qs, new...; bulk = bulk)
    end
    qs
end

"""
    create(reporter.article; headline = "...")      # an Article whose reporter is `reporter`
    create(post.tags; name = "julia")               # a Tag, added to the post's tags

A new object in a relation (Django's `RelatedManager.create`).
"""
function create(qs::QuerySet; kw...)
    if qs.owner isa ReverseFKOwner
        o = qs.owner::ReverseFKOwner
        obj = create(o.model; kw..., (o.fk.name => o.instance,)...)
        rev_changed!(o)
        return obj
    elseif qs.owner isa M2MOwner
        obj = create(model_of(qs); kw...)
        add!(qs, obj)
        return obj
    end
    throw(ArgumentError("create(qs; ...) needs a relation such as reporter.article or post.tags; use create(Model; ...)"))
end

function prefetch_m2m!(objs::Vector, name, f::Field, forward::Bool, qs, to_attr)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    ids = [o.id for o in objs]
    pairs_ = collect(values_list(filter(base_objects(through_model(f)), Q(Symbol(attname(mine), "__in") => ids)), attname(mine), attname(other)))
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
        (getfield(o, :_cache)::Dict{Symbol,Any})[something(to_attr, name)] = PrefetchedList(get(groups, o.id, Other[]))
    end
    targets
end
