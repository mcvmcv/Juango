# Content types and generic relations -------------------------------------------------------------
#
#     @model struct Comment
#         content_type   = ForeignKey(ContentType)
#         object_id      = IntegerField()
#         content_object = GenericForeignKey()          # :content_type and :object_id by default
#         text           = TextField()
#     end
#     @model struct Post
#         title    = CharField(max_length=100)
#         comments = GenericRelation(:Comment)          # post.comments, filter(Post; comments__text=...)
#     end
#
#     create(Comment; content_object = post, text = "Nice")
#     comment.content_object                            # the Post (or whatever it points at)

# One row per model (`app_label`, lower-case `model` name). Used by generic relations, and
# later by permissions and the admin history.
@model struct ContentType
    app_label = CharField(max_length = 100)
    model = CharField(max_length = 100)
    Meta(table = "juango_content_type", app_label = "contenttypes", unique_together = [(:app_label, :model)], verbose_name = "content type")
end
Base.show(io::IO, ct::ContentType) = print(io, ct.app_label, " | ", ct.model)

const CT_CACHE = Dict{Any,Any}()          # (database alias, model type) => ContentType
const CT_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(CT_CACHE), CT_LOCK))

"""
    get_for_model(Model) -> ContentType

The content type of a model (created on first use). Proxy models share their concrete
model's content type.
"""
Base.@nospecializeinfer function get_for_model(@nospecialize(T::Type))
    C = concrete_model(T)
    key = (current_alias(), C)
    ct = lock(() -> get(CT_CACHE, key, nothing), CT_LOCK)
    ct === nothing || return ct
    m = modelmeta(C)
    ct = first(get_or_create(ContentType; app_label = m.app, model = lowercase(m.name)))
    lock(() -> get!(CT_CACHE, key, ct), CT_LOCK)
end
Base.@nospecializeinfer get_for_model(@nospecialize(obj::Model)) = get_for_model(typeof(obj))

"A prefetched generic key whose row is gone (for the key it was prefetched with)."
struct GenericGone
    key::Tuple{Any,String}
end

"""
    get_for_id(id) -> ContentType

A content type by its id, cached like `get_for_model`'s (Django's `ContentType.objects.get_for_id`):
following generic keys doesn't query the content types again.
"""
function get_for_id(id)
    a = current_alias()
    ct = lock(CT_LOCK) do
        for ((al, _), c) in CT_CACHE
            al == a && c.id == id && return c
        end
        nothing
    end
    ct === nothing || return ct
    ct = get(base_objects(ContentType); id = id)
    M = model_class(ct)
    M === nothing || lock(() -> get!(CT_CACHE, (a, M), ct), CT_LOCK)
    ct
end

"""
A generic key's stored value as the target model's key: an object id kept in a text column
(`object_pk = TextField()`, as Django's comments framework does) is parsed for an integer or UUID key.
"""
Base.@nospecializeinfer function generic_key(@nospecialize(M::Type), v)
    v isa AbstractString || return v
    k = pk_kind(M)
    k === :uuid ? something(tryparse(UUID, v), v) : natural_pk(M) ? v : something(tryparse(Int, v), v)
end

"The model class a content type stands for, or `nothing` if it no longer exists."
function model_class(ct::ContentType)
    for T in MODEL_LIST
        m = modelmeta(T)
        (!m.proxy && m.app == ct.app_label && lowercase(m.name) == ct.model) && return T
    end
    nothing
end

"Make sure every model has a content type (run by `migrate`)."
function update_contenttypes!()
    table_exists(backend(), modelmeta(ContentType).table) || return
    for T in MODEL_LIST
        (modelmeta(T).proxy || T <: AutoThrough || !model_in_use(T)) && continue
        get_for_model(T)
    end
end

"""
    GenericForeignKey(ct_field=:content_type, fk_field=:object_id)

A relation to an object of any model, stored as a `ForeignKey(ContentType)` field and an
integer id field of the same model. Read and assign it like a foreign key:
`comment.content_object = post`. It isn't a column, so it can't be used in lookups;
filter on the two fields instead.
"""
GenericForeignKey(ct_field = :content_type, fk_field = :object_id) =
    Field(:gfk; related = (Symbol(ct_field), Symbol(fk_field)), editable = false, blank = true)

"""
    GenericRelation(Model; content_type_field=:content_type, object_id_field=:object_id, related_query_name=nothing)

The reverse side of a `GenericForeignKey`: `post.comments` is a queryset of the comments
pointing at `post`, lookups like `filter(Post; comments__text="x")` work, and deleting the
post deletes them.
"""
GenericRelation(to; content_type_field = :content_type, object_id_field = :object_id, related_query_name = nothing) =
    Field(:grel; related = to, through = (Symbol(content_type_field), Symbol(object_id_field)), editable = false, blank = true,
          related_query_name = related_query_name)

"""
The GenericRelation that `name` reaches from the related model `T` (`filter(TaggedItem; animal__name = ...)`
for `GenericRelation(TaggedItem; related_query_name = "animal")` on Animal): `(owner model, field)`, or nothing.
"""
Base.@nospecializeinfer function find_reverse_generic(@nospecialize(T::Type), name)
    C = concrete_model(T)
    for M in MODEL_LIST
        (modelmeta(M).proxy || !model_in_use(M)) && continue
        for g in generic_relations(M)
            g.related_query_name !== nothing && string(g.related_query_name) == string(name) &&
                concrete_model(related_model(g)) === C && return (M, g)
        end
    end
    nothing
end

Base.@nospecializeinfer generic_fks(@nospecialize(T::Type)) = get(modelmeta(concrete_model(T)).extra, :generic_fks, Field[])
Base.@nospecializeinfer generic_relations(@nospecialize(T::Type)) = get(modelmeta(concrete_model(T)).extra, :generic_relations, Field[])
find_generic(list, name) = (i = findfirst(f -> string(f.name) == string(name), list); i === nothing ? nothing : list[i])

Base.@nospecializeinfer function get_generic(@nospecialize(m::Model), f::Field)
    ctf, fkf = f.related
    data, cache = (getfield(m, :_data)::Dict{Symbol,Any}), (getfield(m, :_cache)::Dict{Symbol,Any})
    ctid, oid = data[Symbol(ctf, :_id)], data[fkf]
    (ctid === nothing || oid === nothing) && return nothing
    c = get(cache, f.name, NOTFOUND)
    c isa GenericGone && c.key == (ctid, string(oid)) && return nothing     # prefetched: the row it points at is gone
    (c isa Model && string(c.id) == string(oid) && get_for_model(c).id == ctid) && return c
    M = model_class(get_for_id(ctid))
    M === nothing && return nothing
    obj = first(filter(base_objects(M); id = generic_key(M, oid)))
    obj === nothing || (cache[f.name] = obj)
    obj
end

Base.@nospecializeinfer function set_generic!(@nospecialize(m::Model), f::Field, v)
    ctf, fkf = f.related
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    if v === nothing
        data[Symbol(ctf, :_id)] = nothing
        data[fkf] = nothing
        delete!((getfield(m, :_cache)::Dict{Symbol,Any}), f.name)
    else
        v.id === nothing && throw(ArgumentError("save the $(typeof(v)) before pointing a generic relation at it"))
        data[Symbol(ctf, :_id)] = get_for_model(v).id
        data[fkf] = getfield_meta(typeof(m), fkf).kind in STRING_KINDS ? string(v.id) : v.id   # (a text key column)
        (getfield(m, :_cache)::Dict{Symbol,Any})[f.name] = v
    end
    v
end

Base.@nospecializeinfer function generic_queryset(@nospecialize(m::Model), f::Field)
    ctf, fkf = f.through
    M = related_model(f)
    id = (getfield(m, :_data)::Dict{Symbol,Any})[:id]
    qs = filter(objects(M), Q(Symbol(ctf, :_id) => get_for_model(m).id), Q(fkf => getfield_meta(M, fkf).kind in STRING_KINDS ? string(id) : id))
    chain(qs; owner = GenericOwner(f, M, m, f.name), db = instance_db(m))
end

# --- writing through a GenericRelation (Django's GenericRelatedObjectManager) ---------------------------

"The owner of a generic relation's queryset (`animal.tags`): what create/add!/remove!/set!/clear! act for."
struct GenericOwner
    field::Field     # Animal.tags (the GenericRelation)
    model::Type      # TaggedItem
    instance::Any    # the animal
    name::Symbol
end
gen_changed!(o::GenericOwner) = forget_prefetched!(o.instance, o.name)
"The content type and object id fields' values that point at the owner."
function gen_target(o::GenericOwner)
    ctf, fkf = o.field.through
    o.instance.id === nothing && throw(ArgumentError("save the $(nameof(typeof(o.instance))) before relating objects to its $(o.name)"))
    id = o.instance.id
    (Symbol(ctf, :_id) => get_for_model(o.instance).id, fkf => getfield_meta(o.model, fkf).kind in STRING_KINDS ? string(id) : id)
end
function gen_check(o::GenericOwner, @nospecialize(x))
    x isa Model && check_model_type(o.model, x) isa Model || throw(ArgumentError("'$(nameof(o.model))' instance expected, got $(repr(x))"))
    x
end
"`add!(animal.tags, t1, t2)`: point the objects at the owner, with one UPDATE (or `bulk = false`: a save of each, for unsaved ones)."
function gen_add!(qs::QuerySet, objs...; bulk::Bool = true)
    o = qs.owner::GenericOwner
    foreach(x -> gen_check(o, x), objs)
    isempty(objs) && return qs
    t = gen_target(o)
    if bulk
        any(x -> x.pk === nothing, objs) &&
            throw(ArgumentError("$(repr(first(x for x in objs if x.pk === nothing))) isn't saved: use bulk = false or save it first"))
        update!(filter(base_objects(o.model); pk__in = [x.pk for x in objs]); t...)
        foreach(x -> setproperty!(x, Juango.generic_fk_name(o), o.instance), objs)
    else
        atomic(() -> foreach(x -> (setproperty!(x, Juango.generic_fk_name(o), o.instance); save!(x)), objs))
    end
    gen_changed!(o)
    qs
end
"The GenericForeignKey of the related model that this relation is the other side of (`content_object`)."
function generic_fk_name(o::GenericOwner)
    ctf, fkf = o.field.through
    i = findfirst(g -> g.related == (ctf, fkf), generic_fks(o.model))
    i === nothing && throw(ArgumentError("$(nameof(o.model)) has no GenericForeignKey on ($ctf, $fkf)"))
    generic_fks(o.model)[i].name
end
"`remove!(animal.tags, t)`: delete the objects (a generic key can't be emptied), as Django."
function gen_remove!(qs::QuerySet, objs...; bulk::Bool = true)
    o = qs.owner::GenericOwner
    foreach(x -> gen_check(o, x), objs)
    isempty(objs) && return qs
    rel = filter(qs; pk__in = [x.pk for x in objs])
    bulk ? delete!(rel) : atomic(() -> foreach(delete!, fetch(rel)))
    gen_changed!(o)
    qs
end
"`clear!(animal.tags)`: delete every related object."
function gen_clear!(qs::QuerySet; bulk::Bool = true)
    o = qs.owner::GenericOwner
    rel = filter(base_objects(o.model), (Q(p) for p in gen_target(o))...)
    bulk ? delete!(rel) : atomic(() -> foreach(delete!, fetch(rel)))
    gen_changed!(o)
    qs
end
"`set!(animal.tags, [t1, t2])`: the others are deleted, the new ones added (`clear = true`: clear!, then add!)."
function gen_set!(qs::QuerySet, objs; bulk::Bool = true, clear::Bool = false)
    o = qs.owner::GenericOwner
    want = collect(objs)
    foreach(x -> gen_check(o, x), want)
    atomic() do
        if clear
            gen_clear!(qs; bulk = bulk)
            isempty(want) || gen_add!(qs, want...; bulk = bulk)
        else
            have = fetch(filter(base_objects(o.model), (Q(p) for p in gen_target(o))...))
            keep = Set(x.pk for x in want if x.pk !== nothing)
            gone = [x for x in have if !(x.pk in keep)]
            isempty(gone) || gen_remove!(qs, gone...; bulk = bulk)
            havepk = Set(x.pk for x in have)
            new = [x for x in want if x.pk === nothing || !(x.pk in havepk)]
            isempty(new) || gen_add!(qs, new...; bulk = bulk)
        end
    end
    qs
end
"`create(animal.tags; tag = \"x\")`: a new object pointing at the owner."
function gen_create(qs::QuerySet; kw...)
    o = qs.owner::GenericOwner
    obj = create(o.model; kw..., gen_target(o)...)
    gen_changed!(o)
    obj
end

function prefetch_generic_fk!(objs::Vector, f::Field)
    ctf, fkf = f.related
    bytype = Dict{Any,Vector{Any}}()
    for o in objs
        d = (getfield(o, :_data)::Dict{Symbol,Any})
        (d[Symbol(ctf, :_id)] === nothing || d[fkf] === nothing) && continue
        push!(get!(() -> Any[], bytype, d[Symbol(ctf, :_id)]), d[fkf])
    end
    found = Dict{Tuple{Any,Any},Any}()
    out = Any[]
    # one query per content type (the content types themselves come from the cache); keys compared as
    # strings, so an id kept in a text column matches
    for (ctid, ids) in bytype
        M = model_class(get_for_id(ctid))
        M === nothing && continue
        for r in filter(base_objects(M); id__in = unique([generic_key(M, i) for i in ids]))
            found[(ctid, string(r.id))] = r
            push!(out, r)
        end
    end
    for o in objs
        d = (getfield(o, :_data)::Dict{Symbol,Any})
        (d[Symbol(ctf, :_id)] === nothing || d[fkf] === nothing) && continue
        # (a key to a row that's gone is remembered too, so reading it doesn't query again)
        key = (d[Symbol(ctf, :_id)], string(d[fkf]))
        (getfield(o, :_cache)::Dict{Symbol,Any})[f.name] = get(found, key, GenericGone(key))
    end
    out
end

function prefetch_generic_relation!(objs::Vector, f::Field, qs, to_attr)
    ctf, fkf = f.through
    M = related_model(f)
    T = typeof(first(objs))
    # the object key column may be text (favorite_fkey = CharField): compare as the column holds it
    textkey = getfield_meta(M, fkf).kind in STRING_KINDS
    rows = fetch(filter(something(qs, objects(M)), Q(Symbol(ctf, :_id) => get_for_model(T).id),
                        Q(Symbol(fkf, "__in") => [textkey ? string(o.id) : o.id for o in objs])))
    groups = Dict{String,Vector{M}}()
    for r in rows
        push!(get!(() -> M[], groups, string((getfield(r, :_data)::Dict{Symbol,Any})[fkf])), r)
    end
    for o in objs
        (getfield(o, :_cache)::Dict{Symbol,Any})[something(to_attr, f.name)] = PrefetchedList(get(groups, string(o.id), M[]))
    end
    rows
end
