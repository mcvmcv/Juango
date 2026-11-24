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
    sticky::Any      # the relation's own condition (in qs.where): the next filter() shares its joins, as Django's
end

Base.@nospecializeinfer function m2m_queryset(@nospecialize(m::Model), f::Field, forward::Bool, name::Symbol = f.name; base = nothing)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    id = (getfield(m, :_data)::Dict{Symbol,Any})[:id]
    step1, step2 = m2m_path(f, !forward)      # from the other model back to this instance
    # (a to_field through key holds another field than the id: compared through the related id then)
    qs = filter(something(base, objects(Other)), Q((fk_to_field(mine) === nothing ? Symbol(step1, "__", step2) : Symbol(step1, "__", step2, "__id")) => id))
    chain(qs; owner = M2MOwner(through_model(f), mine, other, id, forward, f.symmetrical, m, name, qs.where[end]), db = instance_db(m))
end

function m2m_owner(qs::QuerySet)
    qs.owner isa M2MOwner || throw(ArgumentError("add!/remove!/set!/clear! need a many-to-many relation such as post.tags"))
    qs.owner.id === nothing && throw(m2m_unsaved_error(qs.owner))
    qs.owner
end
"Django's error for a many-to-many relation of an object without its key (or its to_field's value)."
function m2m_unsaved_error(o::M2MOwner)
    tf = fk_to_field(o.mine)
    inst = o.instance
    tf !== nothing && inst isa Model && field_data(inst, tf) === nothing &&
        return ArgumentError("\"$(repr(inst))\" needs to have a value for field \"$tf\" before this many-to-many relationship can be used.")
    ArgumentError("'$(nameof(typeof(inst)))' instance needs to have a primary key value before a many-to-many relationship can be used.")
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
        x.id === nothing && throw(ArgumentError("Cannot add \"$(repr(x))\": the value for field \"$(o.other.name)\" is None"))
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
m2m_changed!(o) = forget_prefetched!(o.instance, o.name)
Base.@nospecializeinfer objid(@nospecialize(x::Model)) = (x.id === nothing && throw(ArgumentError("cannot relate an unsaved $(typeof(x))")); x.id)
objid(x) = x

"Send m2m_changed for a many-to-many change (only when someone listens)."
function m2m_signal(o, action, ids)
    m2m = has_receivers(m2m_changed, o.through)
    w = startswith(string(action), "post_") && has_receivers(post_write, o.through)
    pw = startswith(string(action), "pre_") && has_receivers(pre_write, o.through)
    (m2m || w || pw) || return
    owner = related_model(o.mine)
    inst = o.instance isa Model ? o.instance : get(base_objects(owner); id = o.id)   # (the object itself, as Django sends it)
    pks = ids === nothing ? nothing : Set(ids)
    m2m && send(m2m_changed, o.through; action = action, instance = inst, model = related_model(o.other), pk_set = pks, reverse = !o.forward,
                raw = SAVE_RAW[], database = current_alias())                             # (raw: loading a fixture, as Django's set_base(raw = true))
    pw && send(pre_write, o.through; action = :m2m, via = action, ids = nothing, fields = nothing, instances = nothing,
               instance = inst, model = related_model(o.other), pk_set = pks)
    w && send(post_write, o.through; action = :m2m, via = action, ids = nothing, fields = nothing, instances = nothing,
              instance = inst, model = related_model(o.other), pk_set = pks)
end

"""
    add!(post.tags, tag1, tag2; through_defaults=Dict())

Add objects (or ids) to a many-to-many relation. Already related objects are skipped.
`through_defaults` fills extra fields of a custom `through` model. The new through rows are
inserted together, as Django's `bulk_create`: `m2m_changed` is sent (`:pre_add`, `:post_add`), not
`pre_save`/`post_save` for each row.
"""
# `<Book: Dive into Python>`, as Django's messages show an object
obj_repr(@nospecialize(x)) = "<$(nameof(typeof(x))): $(string(x))>"
# Run `f` on the database a relation's change goes to: with routers, theirs told the owner (Django's instance hint;
# the join model's for a many-to-many), falling back to the owner's database; else the relation's own.
function in_rel_write_db(f, qs::QuerySet)
    o = qs.owner
    (o === nothing || isempty(routers()) || db_pinned()) && return in_db(f, qs, true)
    T = o isa M2MOwner ? o.through : model_of(qs)
    with_db(f, route_write(T; instance = o.instance))
end

# The relation's queryset on the current database when routers chose it (in_rel_write_db), as Django's related
# get_or_create looks on the write database.
rel_here(qs::QuerySet) = isempty(routers()) ? qs : chain(qs; db = current_alias(), owner = qs.owner)

"""
Refuse to relate objects of two databases (unless a router's allow_relation permits it), as Django's related
managers: `Cannot add "<Book: ...>": instance is on database "default", value is on database "other"`, and for a
reverse foreign key `Cannot assign "<Person: ...>": the current database router prevents this relation.`
"""
function check_relation_dbs(qs::QuerySet, objs, verb)
    owner = qs.owner
    owner isa Union{M2MOwner,ReverseFKOwner} || return
    inst = owner.instance
    me = something(instance_db(inst), "default")
    for x in objs
        x isa Model || continue
        d = something(instance_db(x), "default")
        d == me && continue
        ask_routers(allow_relation, inst, x) === true && continue
        owner isa ReverseFKOwner ?
            throw(ArgumentError("Cannot assign \"$(obj_repr(inst))\": the current database router prevents this relation.")) :
            throw(ArgumentError("Cannot $verb \"$(obj_repr(x))\": instance is on database \"$me\", value is on database \"$d\""))
    end
end

function add!(qs::QuerySet, objs...; through_defaults = Dict{Symbol,Any}(), bulk::Bool = true)
    check_relation_dbs(qs, objs, "add")
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        qs.owner isa ReverseFKOwner && return rev_add!(qs, objs...; bulk = bulk)
        qs.owner isa GenericOwner && return gen_add!(qs, objs...; bulk = bulk)
        o = m2m_owner(qs)
        m2m_add_ids!(o, unique(Any[m2m_obj_id(o, x) for x in objs]), through_defaults)
        qs
    end
end
function m2m_add_ids!(o, ids, through_defaults)
    isempty(ids) && return
    # a callable default is called once for the call, every new link getting the same value (as Django)
    through_defaults = Dict{Symbol,Any}(Symbol(k) => (v isa Function ? v() : v) for (k, v) in pairs(through_defaults))
    atomic(savepoint = false) do     # (no savepoint of its own, as Django's)
        have = Set(values_list(filter(base_objects(o.through), Q(idkey(o.mine) => o.id), Q(idkeys(o.other) => ids)),
                               idkey(o.other); flat = true))
        new = [id for id in ids if !(id in have)]
        # nothing new: the signals still go, with an empty pk_set, as Django's
        isempty(new) && (m2m_signal(o, :pre_add, new); m2m_signal(o, :post_add, new); return)
        m2m_signal(o, :pre_add, new)
        # the through rows in one insert, as Django's bulk_create: no pre_save/post_save for them, only m2m_changed (#253)
        rows = [o.through(; attname(o.mine) => stored_value(o.mine, o.id), attname(o.other) => stored_value(o.other, id),
                          (Symbol(k) => v for (k, v) in pairs(through_defaults))...) for id in new]
        if o.symmetrical          # and the other way round
            back = Set(values_list(filter(base_objects(o.through), Q(idkey(o.other) => o.id), Q(idkeys(o.mine) => new)),
                                   idkey(o.mine); flat = true))
            append!(rows, [o.through(; attname(o.mine) => stored_value(o.mine, id), attname(o.other) => stored_value(o.other, o.id),
                                     (Symbol(k) => v for (k, v) in pairs(through_defaults))...)
                           for id in new if !(id in back || id == o.id)])
        end
        bulk_create(rows)
        m2m_signal(o, :post_add, new)
    end
    m2m_changed!(o)
end

"Remove objects (or ids) from a many-to-many relation."
function remove!(qs::QuerySet, objs...; bulk::Bool = true)
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        qs.owner isa ReverseFKOwner && return rev_remove!(qs, objs...; bulk = bulk)
        qs.owner isa GenericOwner && return gen_remove!(qs, objs...; bulk = bulk)
        o = m2m_owner(qs)
        m2m_remove_ids!(o, Any[m2m_obj_id(o, x) for x in objs])
        qs
    end
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
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        qs.owner isa ReverseFKOwner && return rev_clear!(qs; bulk = bulk)
        qs.owner isa GenericOwner && return gen_clear!(qs; bulk = bulk)
        o = m2m_owner(qs)
        m2m_signal(o, :pre_clear, nothing)
        delete!(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)))
        o.symmetrical && delete!(filter(base_objects(o.through), Q(idkey(o.other) => o.id)))
        m2m_signal(o, :post_clear, nothing)
        m2m_changed!(o)
        qs
    end
end

"""
    set!(post.tags, objs; clear = false)

Make the relation contain exactly `objs`: only the differences are written, or with `clear = true` every
link is removed and the new ones added (Django's `set(clear=True)`).
"""
function set!(qs::QuerySet, objs; through_defaults = Dict{Symbol,Any}(), bulk::Bool = true, clear::Bool = false)
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        # a lone value is a mistake, not a one-item list (Julia iterates a number or a string): Django's
        # "'int' object is not iterable", before any link is touched
        objs isa Union{Number,AbstractString,Symbol,Model,Nothing} &&
            throw(ArgumentError("set!(relation, objs): objs must be a collection of objects or keys, not $(repr(objs)); use set!(rel, [x])"))
        check_relation_dbs(qs, objs, "add")
        qs.owner isa ReverseFKOwner && return rev_set!(qs, objs; bulk = bulk, clear = clear)
        qs.owner isa GenericOwner && return gen_set!(qs, objs; bulk = bulk, clear = clear)
        o = m2m_owner(qs)
        want = unique(Any[m2m_obj_id(o, x) for x in collect(objs)])
        clear && return atomic(() -> (clear!(qs); m2m_add_ids!(o, want, through_defaults); qs); savepoint = false)
        atomic(savepoint = false) do
            have = collect(values_list(filter(base_objects(o.through), Q(idkey(o.mine) => o.id)), idkey(o.other); flat = true))
            m2m_remove_ids!(o, setdiff(have, want))
            m2m_add_ids!(o, setdiff(want, have), through_defaults)
        end
        qs
    end
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
rev_changed!(o::ReverseFKOwner) = forget_prefetched!(o.instance, o.name)

function rev_check(o::ReverseFKOwner, @nospecialize(obj))
    obj isa Model && check_model_type(o.model, obj) isa Model ||
        throw(ArgumentError("'$(nameof(o.model))' instance expected, got $(repr(obj))"))
    obj
end
"The owner's key the relation stores, refusing an owner without one (Django's message)."
function rev_key(o::ReverseFKOwner)
    v = target_value(o.fk, o.instance)
    v === nothing && throw(ArgumentError("\"$(repr(o.instance))\" needs to have a value for field \"$(something(fk_to_field(o.fk), :id))\" " *
                                         "before this relationship can be used."))
    v
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
    v = rev_key(o)
    foreach(x -> rev_check(o, x), objs)
    isempty(objs) && return qs
    if bulk
        any(x -> x.pk === nothing, objs) &&
            throw(ArgumentError("$(repr(first(x for x in objs if x.pk === nothing))) isn't saved: use bulk = false or save it first"))
        update!(filter(base_objects(o.model); pk__in = [x.pk for x in objs]); attname(o.fk) => v)
        foreach(x -> setproperty!(x, o.fk.name, o.instance), objs)
    else
        atomic(savepoint = false) do
            foreach(x -> (setproperty!(x, o.fk.name, o.instance); save!(x)), objs)
        end
    end
    rev_changed!(o)
    qs
end
"`remove!(reporter.article, a)`: set the objects' foreign key to NULL (a nullable key only), as Django."
function rev_remove!(qs::QuerySet, objs...; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    v = rev_key(o)
    rev_nullable(o, "remove!")
    foreach(x -> rev_check(o, x), objs)
    isempty(objs) && return qs
    for x in objs
        # (as Django: the owner's model's DoesNotExist, Reporter.DoesNotExist)
        field_data(x, attname(o.fk)) == v || throw(DoesNotExist(typeof(o.instance), "$(repr(x)) is not related to $(repr(o.instance))"))
    end
    if bulk
        update!(filter(base_objects(o.model); pk__in = [x.pk for x in objs]); attname(o.fk) => nothing)
        foreach(x -> setproperty!(x, o.fk.name, nothing), objs)
    else
        atomic(() -> foreach(x -> (setproperty!(x, o.fk.name, nothing); save!(x; update_fields = [o.fk.name])), objs); savepoint = false)
    end
    rev_changed!(o)
    qs
end
"`clear!(reporter.article)`: set every related object's foreign key to NULL (a nullable key only)."
function rev_clear!(qs::QuerySet; bulk::Bool = true)
    o = qs.owner::ReverseFKOwner
    rev_key(o)
    rev_nullable(o, "clear!")
    # the rows this relation's queryset sees (its manager's, as Django: clear!(book.readers(manager = :boring)))
    rel = chain(rel_here(qs); owner = nothing, cache = nothing)
    bulk ? update!(rel; attname(o.fk) => nothing) :
        atomic(() -> foreach(x -> (setproperty!(x, o.fk.name, nothing); save!(x; update_fields = [o.fk.name])), fetch(rel)); savepoint = false)
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
    rev_key(o)
    want = collect(objs)
    foreach(x -> rev_check(o, x), want)
    clear && o.fk.null && return atomic(() -> (rev_clear!(qs; bulk = bulk); isempty(want) || rev_add!(qs, want...; bulk = bulk); qs); savepoint = false)
    atomic(savepoint = false) do
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
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        if qs.owner isa ReverseFKOwner
            o = qs.owner::ReverseFKOwner
            rev_key(o)
            obj = create(o.model; kw..., (o.fk.name => o.instance,)...)
            rev_changed!(o)
            return obj
        elseif qs.owner isa GenericOwner
            return gen_create(qs; kw...)
        elseif qs.owner isa M2MOwner
            obj = create(model_of(qs); kw...)
            add!(rel_here(qs), obj; through_defaults = through_defaults)
            return obj   # (add! dropped the prefetched rows)
        end
        throw(ArgumentError("create(qs; ...) needs a relation such as reporter.article or post.tags; use create(Model; ...)"))
    end
end

"""
    get_or_create(group.members; name = "Ann", through_defaults = Dict(:role => "chair"))
    update_or_create(reporter.article; headline = "x", defaults = Dict(:pub_date => d))

Through a relation: the object is looked for among the related ones; one made is added to the relation.
"""
function get_or_create(qs::QuerySet; defaults = Dict{Symbol,Any}(), through_defaults = Dict{Symbol,Any}(), kw...)
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        qs.owner isa Union{M2MOwner,ReverseFKOwner,GenericOwner} || throw(ArgumentError("get_or_create(qs; ...) needs a relation such as group.members; use get_or_create(Model; ...)"))
        atomic() do
            o = first(filter(rel_here(qs); kw...))
            o === nothing || return (o, false)
            ps = create_params(model_of(qs), kw, defaults)
            (create(rel_here(qs); through_defaults = through_defaults, ps...), true)
        end
    end
end
function update_or_create(qs::QuerySet; defaults = Dict{Symbol,Any}(), create_defaults = nothing, through_defaults = Dict{Symbol,Any}(), kw...)
    # (on the database the owner came from: an object of another database relates there)
    in_rel_write_db(qs) do
        qs.owner isa Union{M2MOwner,ReverseFKOwner,GenericOwner} || throw(ArgumentError("update_or_create(qs; ...) needs a relation such as group.members; use update_or_create(Model; ...)"))
        atomic() do
            o = first(filter(rel_here(qs); kw...))
            o === nothing && return (create(rel_here(qs); through_defaults = through_defaults,
                                            create_params(model_of(qs), kw, something(create_defaults, defaults))...), true)
            for (k, v) in create_params(model_of(qs), (;), defaults)
                setproperty!(o, k, v)
            end
            (save!(o), false)
        end
    end
end

"""
    book.authors(manager = :fun_people)
    book.favorite_books(manager = :boring_people)

The relation through another of the related model's managers (`Juango.manager(::Type{M}, ::Val{name})`)
instead of its default queryset, as Django's `book.authors(manager="fun_people")`. It is still the
relation: add!, create and the rest work on it.
"""
function (qs::QuerySet)(; manager::Union{Symbol,AbstractString})
    o = qs.owner
    T = model_of(qs)
    base = objects(T, Symbol(manager))
    rel = if o isa ReverseFKOwner
        filter(base, Q(attname(o.fk) => target_value(o.fk, o.instance)))
    elseif o isa M2MOwner
        mm = find_m2m(typeof(o.instance), string(o.name))
        mm === nothing && throw(ArgumentError("$(o.name) is not a many-to-many relation of $(typeof(o.instance))"))
        return m2m_queryset(o.instance, mm[2], mm[3], o.name; base = base)
    elseif o isa GenericOwner
        filter(base, (Q(p) for p in gen_target(o))...)
    else
        throw(ArgumentError("qs(manager = ...) is for a relation's queryset (book.authors, publisher.books)"))
    end
    chain(rel; owner = o, db = qs.db)
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
