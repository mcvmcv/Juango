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

const CT_CACHE = Dict{Any,Any}()          # model type => ContentType, per database
const CT_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(CT_CACHE), CT_LOCK))

"""
    get_for_model(Model) -> ContentType

The content type of a model (created on first use). Proxy models share their concrete
model's content type.
"""
function get_for_model(T::Type)
    C = concrete_model(T)
    ct = lock(() -> get(CT_CACHE, C, nothing), CT_LOCK)
    ct === nothing || return ct
    m = modelmeta(C)
    ct = first(get_or_create(ContentType; app_label = m.app, model = lowercase(m.name)))
    lock(() -> get!(CT_CACHE, C, ct), CT_LOCK)
end
get_for_model(obj::Model) = get_for_model(typeof(obj))

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

generic_fks(T::Type) = get(modelmeta(concrete_model(T)).extra, :generic_fks, Field[])
generic_relations(T::Type) = get(modelmeta(concrete_model(T)).extra, :generic_relations, Field[])
find_generic(list, name) = (i = findfirst(f -> string(f.name) == string(name), list); i === nothing ? nothing : list[i])

function get_generic(m::Model, f::Field)
    ctf, fkf = f.related
    data, cache = getfield(m, :_data), getfield(m, :_cache)
    ctid, oid = data[Symbol(ctf, :_id)], data[fkf]
    (ctid === nothing || oid === nothing) && return nothing
    c = get(cache, f.name, nothing)
    (c !== nothing && c.id == oid && get_for_model(c).id == ctid) && return c
    M = model_class(get(base_objects(ContentType); id = ctid))
    M === nothing && return nothing
    obj = first(filter(base_objects(M); id = oid))
    obj === nothing || (cache[f.name] = obj)
    obj
end

function set_generic!(m::Model, f::Field, v)
    ctf, fkf = f.related
    data = getfield(m, :_data)
    if v === nothing
        data[Symbol(ctf, :_id)] = nothing
        data[fkf] = nothing
        delete!(getfield(m, :_cache), f.name)
    else
        v.id === nothing && throw(ArgumentError("save the $(typeof(v)) before pointing a generic relation at it"))
        data[Symbol(ctf, :_id)] = get_for_model(v).id
        data[fkf] = v.id
        getfield(m, :_cache)[f.name] = v
    end
    v
end

function generic_queryset(m::Model, f::Field)
    ctf, fkf = f.through
    M = related_model(f)
    filter(objects(M), Q(Symbol(ctf, :_id) => get_for_model(m).id), Q(fkf => getfield(m, :_data)[:id]))
end

function prefetch_generic_fk!(objs::Vector, f::Field)
    ctf, fkf = f.related
    bytype = Dict{Any,Vector{Any}}()
    for o in objs
        d = getfield(o, :_data)
        (d[Symbol(ctf, :_id)] === nothing || d[fkf] === nothing) && continue
        push!(get!(() -> Any[], bytype, d[Symbol(ctf, :_id)]), d[fkf])
    end
    found = Dict{Tuple{Any,Any},Any}()
    out = Any[]
    for (ctid, ids) in bytype
        M = model_class(get(base_objects(ContentType); id = ctid))
        M === nothing && continue
        for r in filter(base_objects(M); id__in = unique(ids))
            found[(ctid, r.id)] = r
            push!(out, r)
        end
    end
    for o in objs
        d = getfield(o, :_data)
        r = get(found, (d[Symbol(ctf, :_id)], d[fkf]), nothing)
        r === nothing || (getfield(o, :_cache)[f.name] = r)
    end
    out
end

function prefetch_generic_relation!(objs::Vector, f::Field, qs, to_attr)
    ctf, fkf = f.through
    M = related_model(f)
    T = typeof(first(objs))
    rows = fetch(filter(something(qs, objects(M)), Q(Symbol(ctf, :_id) => get_for_model(T).id),
                        Q(Symbol(fkf, "__in") => [o.id for o in objs])))
    groups = Dict{Any,Vector{M}}()
    for r in rows
        push!(get!(() -> M[], groups, getfield(r, :_data)[fkf]), r)
    end
    for o in objs
        getfield(o, :_cache)[something(to_attr, f.name)] = PrefetchedList(get(groups, o.id, M[]))
    end
    rows
end
