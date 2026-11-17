# --- many-to-many ----------------------------------------------------------------------------

"Context carried by a many-to-many queryset: the join model and which FK points at `id`."
struct M2MOwner
    through::Type
    mine::Field      # FK in the join model pointing at the instance
    other::Field     # FK pointing at the related objects
    id::Any
    forward::Bool    # changed from the side that declares the ManyToManyField
    symmetrical::Bool  # also keep the mirrored rows (other -> instance)
    instance::Any    # the object whose relation it is (its prefetched rows are dropped by a change)
    name::Symbol     # the relation's name on it
end

Base.@nospecializeinfer function m2m_queryset(@nospecialize(m::Model), f::Field, forward::Bool, name::Symbol = f.name)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    id = (getfield(m, :_data)::Dict{Symbol,Any})[:id]
    step1, step2 = m2m_path(f, !forward)      # from the other model back to this instance
    # (a to_field through key holds another field than the id: compared through the related id then)
    qs = filter(objects(Other), Q((fk_to_field(mine) === nothing ? Symbol(step1, "__", step2) : Symbol(step1, "__", step2, "__id")) => id))
    chain(qs; owner = M2MOwner(through_model(f), mine, other, id, forward, f.symmetrical, m, name), db = instance_db(m))
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
stored_value(f::Field, id) = fk_to_field(f) === nothing ? id : target_value(f, get(base_objects(related_model(f)); id = id))
"""
An object (or key) added to, removed from or set on a many-to-many relation, as the related id: an
object must be of the related model (Django's TypeError), a key a number for an automatic id, and with
a to_field through model the key may be that field's value (`add!(article.authors, "jean")`).
"""
function m2m_obj_id(o, @nospecialize(x))
    R = related_model(o.other)
    if x isa Model
        check_model_type(R, x)
        x.id === nothing && throw(ArgumentError("cannot relate an unsaved $(typeof(x))"))
        return x.id
    end
    tf = fk_to_field(o.other)
    if tf !== nothing && !natural_pk(R)
        id = first(values_list(filter(base_objects(R), Q(tf => x)), :id; flat = true))
        id === nothing && throw(DoesNotExist(R, "$tf=$(repr(x))"))
        return id
    end
    check_key_value(R, nothing, x)
end
"After a change, the relation's prefetched rows are stale: the next access queries (as Django)."
m2m_changed!(o) = (delete!((getfield(o.instance, :_cache)::Dict{Symbol,Any}), o.name); nothing)
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
    m2m_add_ids!(o, unique(Any[m2m_obj_id(o, x) for x in objs]), through_defaults)
    qs
end
function m2m_add_ids!(o, ids, through_defaults)
    isempty(ids) && return
    # a callable default is called once for the call, every new link getting the same value (as Django)
    through_defaults = Dict{Symbol,Any}(Symbol(k) => (v isa Function ? v() : v) for (k, v) in pairs(through_defaults))
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
    m2m_changed!(o)
end

"Remove objects (or ids) from a many-to-many relation."
function remove!(qs::QuerySet, objs...; bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_remove!(qs, objs...; bulk = bulk)
    o = m2m_owner(qs)
    m2m_remove_ids!(o, Any[m2m_obj_id(o, x) for x in objs])
    qs
end
function m2m_remove_ids!(o, ids)
    isempty(ids) && return
    m2m_signal(o, :pre_remove, ids)
    delete!(filter(base_objects(o.through), Q(idkey(o.mine) => o.id), Q(idkeys(o.other) => ids)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(idkey(o.other) => o.id), Q(idkeys(o.mine) => ids)))
    m2m_signal(o, :post_remove, ids)
    m2m_changed!(o)
end

"Remove every object from a many-to-many relation."
function clear!(qs::QuerySet; bulk::Bool = true)
    qs.owner isa ReverseFKOwner && return rev_clear!(qs; bulk = bulk)
    o = m2m_owner(qs)
    m2m_signal(o, :pre_clear, nothing)
    delete!(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)))
    o.symmetrical && delete!(filter(base_objects(o.through), Q(idkey(o.other) => o.id)))
    m2m_signal(o, :post_clear, nothing)
    m2m_changed!(o)
    qs
end

"""
    set!(post.tags, objs; clear = false)

Make the relation contain exactly `objs`: only the differences are written, or with `clear = true` every
link is removed and the new ones added (Django's `set(clear=True)`).
"""
function set!(qs::QuerySet, objs; through_defaults = Dict{Symbol,Any}(), bulk::Bool = true, clear::Bool = false)
    # a lone value is a mistake, not a one-item list (Julia iterates a number or a string): Django's
    # "'int' object is not iterable", before any link is touched
    objs isa Union{Number,AbstractString,Symbol,Model,Nothing} &&
        throw(ArgumentError("set!(relation, objs): objs must be a collection of objects or keys, not $(repr(objs)); use set!(rel, [x])"))
    qs.owner isa ReverseFKOwner && return rev_set!(qs, objs; bulk = bulk, clear = clear)
    o = m2m_owner(qs)
    want = unique(Any[m2m_obj_id(o, x) for x in collect(objs)])
    clear && return atomic(() -> (clear!(qs); m2m_add_ids!(o, want, through_defaults); qs))
    atomic() do
        have = collect(values_list(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)), idkey(o.other); flat = true))
        m2m_remove_ids!(o, setdiff(have, want))
        m2m_add_ids!(o, setdiff(want, have), through_defaults)
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
function rev_set!(qs::QuerySet, objs; bulk::Bool = true, clear::Bool = false)
    o = qs.owner::ReverseFKOwner
    want = collect(objs)
    foreach(x -> rev_check(o, x), want)
    clear && o.fk.null && return atomic(() -> (rev_clear!(qs; bulk = bulk); isempty(want) || rev_add!(qs, want...; bulk = bulk); qs))
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
function create(qs::QuerySet; through_defaults = Dict{Symbol,Any}(), kw...)
    if qs.owner isa ReverseFKOwner
        o = qs.owner::ReverseFKOwner
        obj = create(o.model; kw..., (o.fk.name => o.instance,)...)
        rev_changed!(o)
        return obj
    elseif qs.owner isa M2MOwner
        obj = create(model_of(qs); kw...)
        add!(qs, obj; through_defaults = through_defaults)
        return obj   # (add! dropped the prefetched rows)
    end
    throw(ArgumentError("create(qs; ...) needs a relation such as reporter.article or post.tags; use create(Model; ...)"))
end

"""
    get_or_create(group.members; name = "Ann", through_defaults = Dict(:role => "chair"))
    update_or_create(reporter.article; headline = "x", defaults = Dict(:pub_date => d))

Through a relation: the object is looked for among the related ones; one made is added to the relation.
"""
function get_or_create(qs::QuerySet; defaults = Dict{Symbol,Any}(), through_defaults = Dict{Symbol,Any}(), kw...)
    qs.owner isa Union{M2MOwner,ReverseFKOwner} || throw(ArgumentError("get_or_create(qs; ...) needs a relation such as group.members; use get_or_create(Model; ...)"))
    atomic() do
        o = first(filter(qs; kw...))
        o === nothing || return (o, false)
        ps = create_params(model_of(qs), kw, defaults)
        (create(qs; through_defaults = through_defaults, ps...), true)
    end
end
function update_or_create(qs::QuerySet; defaults = Dict{Symbol,Any}(), create_defaults = nothing, through_defaults = Dict{Symbol,Any}(), kw...)
    qs.owner isa Union{M2MOwner,ReverseFKOwner} || throw(ArgumentError("update_or_create(qs; ...) needs a relation such as group.members; use update_or_create(Model; ...)"))
    atomic() do
        o = first(filter(qs; kw...))
        o === nothing && return (create(qs; through_defaults = through_defaults,
                                        create_params(model_of(qs), kw, something(create_defaults, defaults))...), true)
        for (k, v) in create_params(model_of(qs), (;), defaults)
            setproperty!(o, k, v)
        end
        (save!(o), false)
    end
end

function prefetch_m2m!(objs::Vector, name, f::Field, forward::Bool, qs, to_attr)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    ids = [o.id for o in objs]
    # one query, as Django: the related rows joined to the through table, each with the owner it's linked to
    step1, step2 = m2m_path(f, !forward)
    path = fk_to_field(mine) === nothing ? Symbol(step1, "__", step2) : Symbol(step1, "__", step2, "__id")
    targets = prefetch_strip!(fetch(prefetch_rows(something(qs, objects(Other)), path, Q(Symbol(path, "__in") => ids); __prefetch_owner = F(string(path)))))
    groups = Dict{Any,Vector{Other}}()
    for t in targets
        mid = pop!((getfield(t, :_data)::Dict{Symbol,Any}), :__prefetch_owner, nothing)
        push!(get!(() -> Other[], groups, mid), t)
    end
    for o in objs
        (getfield(o, :_cache)::Dict{Symbol,Any})[something(to_attr, name)] = PrefetchedList(get(groups, o.id, Other[]))
    end
    targets
end
