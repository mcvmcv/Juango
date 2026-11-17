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
    GenericRelation(Model; content_type_field=:content_type, object_id_field=:object_id)

The reverse side of a `GenericForeignKey`: `post.comments` is a queryset of the comments
pointing at `post`, lookups like `filter(Post; comments__text="x")` work, and deleting the
post deletes them.
"""
GenericRelation(to; content_type_field = :content_type, object_id_field = :object_id) =
    Field(:grel; related = to, through = (Symbol(content_type_field), Symbol(object_id_field)), editable = false, blank = true)

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
    filter(objects(M), Q(Symbol(ctf, :_id) => get_for_model(m).id), Q(fkf => getfield_meta(M, fkf).kind in STRING_KINDS ? string(id) : id))
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
