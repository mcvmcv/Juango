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
    get_for_model(Model; for_concrete_model = true) -> ContentType

The content type of a model (created on first use). Proxy models share their concrete
model's content type, unless `for_concrete_model = false` (as Django's): then a proxy has its own.
"""
Base.@nospecializeinfer function get_for_model(@nospecialize(T::Type); for_concrete_model::Bool = true)
    C = for_concrete_model ? concrete_model(T) : T
    key = (current_alias(), C)
    ct = lock(() -> get(CT_CACHE, key, nothing), CT_LOCK)
    ct === nothing || return ct
    m = modelmeta(C)
    # one query when it exists (a transaction around get_or_create only when it has to be made)
    ct = first(filter(base_objects(ContentType); app_label = m.app, model = lowercase(m.name)))
    ct === nothing && (ct = first(get_or_create(ContentType; app_label = m.app, model = lowercase(m.name))))
    lock(() -> get!(CT_CACHE, key, ct), CT_LOCK)
end
Base.@nospecializeinfer get_for_model(@nospecialize(obj::Model); for_concrete_model::Bool = true) =
    get_for_model(typeof(obj); for_concrete_model = for_concrete_model)
"""
The content type a generic key or relation `f` uses for `T`: the concrete model's, or with
`for_concrete_model = false` the proxy's own (kept in the field's `symmetrical` flag, unused otherwise).
"""
Base.@nospecializeinfer generic_ct(@nospecialize(T::Type), f::Field) = get_for_model(T; for_concrete_model = !f.symmetrical)

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
    get_for_models(Models...; for_concrete_models = true) -> Dict{Type,ContentType}

The content types of several models at once, cached as `get_for_model`'s (Django's
`ContentType.objects.get_for_models`).
"""
get_for_models(Ts::Type...; for_concrete_models::Bool = true) =
    Dict{Type,ContentType}(T => get_for_model(T; for_concrete_model = for_concrete_models) for T in Ts)

"A content type by its app label and model name, cached (Django's `ContentType.objects.get_by_natural_key`)."
function get_by_natural_key(::Type{ContentType}, app_label::AbstractString, model::AbstractString)
    a = current_alias()
    ct = lock(CT_LOCK) do
        for ((al, _), c) in CT_CACHE
            al == a && c.app_label == app_label && c.model == model && return c
        end
        nothing
    end
    ct === nothing || return ct
    ct = get(base_objects(ContentType); app_label = app_label, model = model)
    M = model_class(ct)
    M === nothing || lock(() -> get!(CT_CACHE, (a, M), ct), CT_LOCK)
    ct
end
natural_key(ct::ContentType) = (ct.app_label, ct.model)

"Forget the cached content types (Django's `ContentType.objects.clear_cache()`): the next lookups query again."
clear_contenttype_cache!() = (lock(() -> empty!(CT_CACHE), CT_LOCK); nothing)

"A content type's model's verbose name, or the stored model name if that model is gone (Django's `ContentType.name`)."
function content_type_name(ct::ContentType)
    M = model_class(ct)
    M === nothing ? ct.model : string(modelmeta(M).verbose_name)
end

"`\"<app's verbose name> | <model's verbose name>\"`, or the stored labels if the model is gone (Django's `app_labeled_name`)."
function app_labeled_name(ct::ContentType)
    M = model_class(ct)
    M === nothing && return string(ct.app_label, " | ", ct.model)
    a = get(APP_DEFS, ct.app_label, nothing)
    string(a === nothing ? titlecase(ct.app_label) : a.verbose_name, " | ", modelmeta(M).verbose_name)
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
    # the concrete model; failing that a proxy with its own content type (for_concrete_model = false)
    proxy = nothing
    for T in MODEL_LIST
        m = modelmeta(T)
        (m.app == ct.app_label && lowercase(m.name) == ct.model) || continue
        m.proxy || return T
        proxy === nothing && (proxy = T)
    end
    proxy
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
GenericForeignKey(ct_field = :content_type, fk_field = :object_id; for_concrete_model::Bool = true) =
    Field(:gfk; related = (Symbol(ct_field), Symbol(fk_field)), editable = false, blank = true, symmetrical = !for_concrete_model)

"""
    GenericRelation(Model; content_type_field=:content_type, object_id_field=:object_id, related_query_name=nothing)

The reverse side of a `GenericForeignKey`: `post.comments` is a queryset of the comments
pointing at `post`, lookups like `filter(Post; comments__text="x")` work, and deleting the
post deletes them.
"""
GenericRelation(to; content_type_field = :content_type, object_id_field = :object_id, related_query_name = nothing,
                for_concrete_model::Bool = true) =
    Field(:grel; related = to, through = (Symbol(content_type_field), Symbol(object_id_field)), editable = false, blank = true,
          related_query_name = related_query_name, symmetrical = !for_concrete_model)

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

# (a multi-table child has its parents' generic keys too: their fields are its fields)
Base.@nospecializeinfer function generic_fks(@nospecialize(T::Type))
    C = concrete_model(T)
    own = get(modelmeta(C).extra, :generic_fks, Field[])
    P = table_parent(C)
    P === nothing ? own : vcat(own, generic_fks(P))
end
# (a multi-table child has its parents' generic relations too: carrot.tags, filter(Carrot; tags__tag = ...))
Base.@nospecializeinfer function generic_relations(@nospecialize(T::Type))
    C = concrete_model(T)
    own = get(modelmeta(C).extra, :generic_relations, Field[])
    P = table_parent(C)
    P === nothing && return own
    inherited = [g for g in generic_relations(P) if !any(x -> x.name === g.name, own)]
    isempty(inherited) ? own : vcat(own, inherited)
end
find_generic(list, name) = (i = findfirst(f -> string(f.name) == string(name), list); i === nothing ? nothing : list[i])

# (on the object's database: its content types, and the row its key points at, are there)
Base.@nospecializeinfer function get_generic(@nospecialize(m::Model), f::Field)
    with_db(() -> get_generic_here(m, f), instance_db(m))
end
Base.@nospecializeinfer function get_generic_here(@nospecialize(m::Model), f::Field)
    ctf, fkf = f.related
    data, cache = (getfield(m, :_data)::Dict{Symbol,Any}), (getfield(m, :_cache)::Dict{Symbol,Any})
    ctid, oid = data[Symbol(ctf, :_id)], data[fkf]
    c = get(cache, f.name, NOTFOUND)
    oid === nothing && c isa Model && c.id === nothing && return c        # assigned before it was saved
    (ctid === nothing || oid === nothing) && return nothing
    c isa GenericGone && c.key == (ctid, string(oid)) && return nothing     # prefetched: the row it points at is gone
    (c isa Model && string(c.id) == string(oid) && generic_ct(typeof(c), f).id == ctid) && return c
    M = model_class(get_for_id(ctid))
    M === nothing && return nothing
    obj = first(filter(base_objects(M); id = generic_key(M, oid)))
    # (a row that's gone is remembered too: asking again doesn't query, as Django)
    cache[f.name] = obj === nothing ? GenericGone((ctid, string(oid))) : obj
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
        # an unsaved object may be assigned (as Django); saving refuses it unless it's been saved by then
        cache = (getfield(m, :_cache)::Dict{Symbol,Any})
        # one without a database takes the related object's (through the routers, as Django's content type assignment)
        if instance_db(m) === nothing && data[:id] === nothing && instance_db(v) !== nothing && !db_pinned()
            cache[:__db] = hinted_write_db(m, v)
        end
        data[Symbol(ctf, :_id)] = generic_ct(typeof(v), f).id
        data[fkf] = v.id === nothing ? nothing : getfield_meta(typeof(m), fkf).kind in STRING_KINDS ? string(v.id) : v.id   # (a text key column)
        cache[f.name] = v
    end
    v
end

Base.@nospecializeinfer function generic_queryset(@nospecialize(m::Model), f::Field)
    ctf, fkf = f.through
    M = related_model(f)
    id = (getfield(m, :_data)::Dict{Symbol,Any})[:id]
    ctid = with_db(() -> generic_ct(typeof(m), f).id, instance_db(m))         # (the content type of the object's database)
    qs = filter(objects(M), Q(Symbol(ctf, :_id) => ctid), Q(fkf => getfield_meta(M, fkf).kind in STRING_KINDS ? string(id) : id))
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
    (Symbol(ctf, :_id) => generic_ct(typeof(o.instance), o.field).id, fkf => getfield_meta(o.model, fkf).kind in STRING_KINDS ? string(id) : id)
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
    rel = chain(qs; owner = nothing, cache = nothing)             # (what this relation's queryset sees, as Django)
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
    gen_changed!(o)            # (even when nothing changed: the prefetched rows may not have been these)
    qs
end
"`create(animal.tags; tag = \"x\")`: a new object pointing at the owner."
function gen_create(qs::QuerySet; kw...)
    o = qs.owner::GenericOwner
    obj = create(o.model; kw..., gen_target(o)...)
    gen_changed!(o)
    obj
end

"""
    GenericPrefetch(:content_object, [objects(Vegetable), only(objects(Animal), :common_name)])

Prefetch a GenericForeignKey with a queryset for each model it may point at (Django 5's
GenericPrefetch); models without one are loaded whole.
"""
function GenericPrefetch(path, querysets)
    qs = collect(querysets)
    # one queryset per content type (as Django)
    cts = [concrete_model(model_of(q)) for q in qs]          # (no query: compared by model)
    allunique(cts) || throw(ArgumentError("Only one queryset is allowed for each content type."))
    Prefetch(string(path), GenericQuerysets(qs), nothing)
end
struct GenericQuerysets
    querysets::Vector
end

function prefetch_generic_fk!(objs::Vector, f::Field, qs = nothing)
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
        base = base_objects(M)
        if qs isa GenericQuerysets
            i = findfirst(q -> model_of(q) === M || concrete_model(model_of(q)) === M, qs.querysets)
            i === nothing || (base = qs.querysets[i])
        end
        for r in filter(base; id__in = unique([generic_key(M, i) for i in ids]))
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

"""
A generic relation prefetched for objects of several models (`content_object__tags`, reached through a
generic key): one query, a content type condition for each model joined with OR (as Django 5).
"""
function prefetch_generic_relation_mixed!(objs::Vector, name::Symbol, qs, to_attr)
    gs = Dict{Any,Field}(U => find_generic(generic_relations(U), name) for U in unique(map(typeof, objs)))
    M = related_model(first(values(gs)))
    conds = Q[]
    for (U, g) in gs
        ctf, fkf = g.through
        ids = [o.id for o in objs if typeof(o) === U]
        textkey = getfield_meta(M, fkf).kind in STRING_KINDS
        push!(conds, Q(Symbol(ctf, :_id) => generic_ct(U, g).id) & Q(Symbol(fkf, "__in") => [textkey ? string(i) : i for i in ids]))
    end
    rows = fetch(filter(something(qs, objects(M)), reduce(|, conds)))
    groups = Dict{Tuple{Any,String},Vector{M}}()
    for r in rows
        d = getfield(r, :_data)::Dict{Symbol,Any}
        for (U, g) in gs
            ctf, fkf = g.through
            d[Symbol(ctf, :_id)] == generic_ct(U, g).id && push!(get!(() -> M[], groups, (U, string(d[fkf]))), r)
        end
    end
    for o in objs
        (getfield(o, :_cache)::Dict{Symbol,Any})[something(to_attr, name)] = PrefetchedList(get(groups, (typeof(o), string(o.id)), M[]))
    end
    rows
end

function prefetch_generic_relation!(objs::Vector, f::Field, qs, to_attr)
    ctf, fkf = f.through
    M = related_model(f)
    T = typeof(first(objs))
    # the object key column may be text (favorite_fkey = CharField): compare as the column holds it
    textkey = getfield_meta(M, fkf).kind in STRING_KINDS
    rows = fetch(filter(something(qs, objects(M)), Q(Symbol(ctf, :_id) => generic_ct(T, f).id),
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

# --- generic inline formsets (Django's generic_inlineformset_factory) ---------------------------------------

"""
    generic_inlineformset_factory(Model; ct_field = :content_type, fk_field = :object_id, fields, exclude,
                                  extra = 3, can_delete = true, min_num = 0, max_num = 1000, for_concrete_model = true, ...)

Like `inlineformset_factory`, for the objects of `Model` that point at a parent through a generic foreign key
(`ct_field` a ForeignKey to ContentType, `fk_field` the object's id): `(data; instance = parent, prefix,
queryset, save_as_new) -> FormSet`. The two fields aren't on the forms; `save!` sets them to the parent. The
default prefix is "app-model-ct_field-fk_field", as Django's.
"""
function generic_inlineformset_factory(T::Type; ct_field = :content_type, fk_field = :object_id, fields = nothing, exclude = Symbol[],
                                       extra = 3, can_delete = true, can_order = false, min_num = 0, max_num = 1000,
                                       validate_min = false, validate_max = false, clean = nothing, form = nothing,
                                       widgets = Dict{Symbol,Symbol}(), labels = Dict{Symbol,String}(), help_texts = Dict{Symbol,String}(),
                                       field_classes = Dict{Symbol,Any}(), extra_fields = Pair{Symbol,Any}[], formfield_callback = nothing,
                                       error_messages = Dict{Symbol,Any}(), edit_only::Bool = false, absolute_max = nothing,
                                       can_delete_extra::Bool = true, for_concrete_model::Bool = true)
    ctf = getfield_meta(T, Symbol(ct_field))
    (ctf === nothing || ctf.kind !== :fk || related_model(ctf) !== ContentType) &&
        throw(ArgumentError("fk_name '$ct_field' is not a ForeignKey to ContentType"))
    getfield_meta(T, Symbol(fk_field)) === nothing && throw(ArgumentError("'$(nameof(T))' has no field named '$fk_field'."))
    ct, fk = Symbol(ct_field), Symbol(fk_field)
    excl = vcat(Symbol.(collect(exclude)), [ct, fk])
    flds = all_fields_option(fields) ? fields : [Symbol(f) for f in fields if !(Symbol(f) in (ct, fk))]
    make = row_form(T, form; fields = flds, exclude = excl, widgets, labels, help_texts, field_classes, extra_fields,
                    formfield_callback, error_messages)
    m = modelmeta(T)
    default_prefix = "$(m.app)-$(lowercase(m.name))-$ct-$fk"
    textkey = getfield_meta(T, fk).kind in STRING_KINDS
    key(p) = textkey ? string(p.pk) : p.pk
    function (data = nothing; instance = nothing, prefix = default_prefix, queryset = nothing, save_as_new::Bool = false, initial = [])
        qs = instance === nothing || instance.pk === nothing || save_as_new ? none(T) :
             filter(something(queryset, objects(T)), Q(ct => get_for_model(typeof(instance); for_concrete_model)), Q(fk => key(instance)))
        if save_as_new && data !== nothing            # (every row a new object: the ids dropped)
            d = Dict{String,Any}(k => data isa QueryDict ? getlist(data, k) : v for (k, v) in data)
            foreach(k -> d[k] isa AbstractVector && length(d[k]) == 1 && (d[k] = d[k][1]), collect(keys(d)))
            d["$prefix-INITIAL_FORMS"] = "0"
            for k in collect(keys(d))
                startswith(k, prefix * "-") && endswith(k, "-id") && delete!(d, k)
            end
            data = d
        end
        new_formset(make; prefix = prefix, data = data, initial = collect(initial), instances = collect(qs), extra = extra,
                    min_num = min_num, max_num = max_num, validate_min = validate_min, validate_max = validate_max,
                    can_delete = can_delete, can_order = can_order, clean = clean, model = T, parent = instance, edit_only,
                    absolute_max, can_delete_extra,
                    set_parent = (obj, p) -> (setproperty!(obj, ct, get_for_model(typeof(p); for_concrete_model)); setproperty!(obj, fk, key(p))))
    end
end
