# ORM: models: metadata, registry, @model, abstract models, instance properties --------------

mutable struct ModelMeta
    model::Type
    name::String
    table::String
    fields::Vector{Field}
    ordering::Vector{String}
    verbose_name::AbstractString
    verbose_name_plural::AbstractString
    app::String
    m2m::Vector{Field}
    unique_together::Vector{Vector{Symbol}}
    parent::Any          # multi-table parent or proxy target (a concrete model), else nothing
    proxy::Bool
    extra::Dict{Symbol,Any}   # other Meta options (e.g. indexes)
end

const MODEL_REGISTRY = Dict{Any,ModelMeta}()
const MODEL_LIST = Any[]

# Relations between models (reverse foreign keys, many-to-many, multi-table children) are
# found by scanning every registered model. They change only when models are registered or
# the settings change (INSTALLED_APPS, AUTH_USER_MODEL), so the results are cached. The
# cached vectors are shared: callers must not modify them.
const RELATION_CACHE = Dict{Tuple{Symbol,Any},Any}()
const RELATION_LOCK = ReentrantLock()
invalidate_relations!() = (lock(() -> empty!(RELATION_CACHE), RELATION_LOCK); nothing)
push!(SETTINGS_CHANGED_HOOKS, invalidate_relations!)
# (No closures over `T`: they'd capture its exact type, and compile again for every model.)
Base.@nospecializeinfer function cached_relations(@nospecialize(f), kind::Symbol, @nospecialize(T))
    key = (kind, T)
    lock(RELATION_LOCK)
    try
        v = get(RELATION_CACHE, key, NOTFOUND)
        v === NOTFOUND || return v
        return RELATION_CACHE[key] = f(T)
    finally
        unlock(RELATION_LOCK)
    end
end

"""
App a model belongs to for migrations: `Meta(app_label=...)`, else `\"juango\"` for Juango's
built-in models, the label of the `App` whose module defines it, or `\"project\"`.
"""
default_app_label(T) = parentmodule(T) === (@__MODULE__) ? "juango" : something(module_app_label(parentmodule(T)), "project")

"Remove a model from the registry (mostly for tests that redefine models)."
Base.@nospecializeinfer function unregister_model!(@nospecialize(T::Type))
    delete!(MODEL_REGISTRY, T)
    filter!(x -> x !== T, MODEL_LIST)
    invalidate_relations!()
    nothing
end

const ABSTRACT_MODELS = Dict{Any,Tuple{Vector{Pair{Symbol,Any}},NamedTuple}}()

"""
    model_supertype(S)

The Julia supertype for `@model struct X <: S`: `S` itself when it is an abstract model,
otherwise `Model` (a concrete parent becomes a multi-table parent or proxy target).
"""
model_supertype(S::Type) = isabstracttype(S) ? (S <: Model ? S : error("$S is not a Juango abstract model")) : Model

"""
    @abstract_model struct TimeStamped
        created = DateTimeField(auto_now_add = true)
        Meta(ordering = ["-created"])
    end

An abstract base model: no table, just fields and `Meta` options that models declared
with `@model struct Post <: TimeStamped` inherit. Abstract models can extend each other.
"""
macro abstract_model(expr)
    (expr isa Expr && expr.head === :struct) || error("@abstract_model expects a struct definition")
    name, super = expr.args[2], nothing
    if name isa Expr && name.head === :(<:)
        name, super = name.args
    end
    fieldpairs, metaexpr = parse_model_body(expr.args[3])
    M = GlobalRef(@__MODULE__, :Model)
    sup = super === nothing ? M : esc(super)
    quote
        Base.@__doc__ abstract type $(esc(name)) <: $sup end      # (a docstring before @abstract_model documents the type)
        $(GlobalRef(@__MODULE__, :ABSTRACT_MODELS))[$(esc(name))] = (Pair{Symbol,Any}[$(fieldpairs...)], $metaexpr)
        $(esc(name))
    end
end

function parse_model_body(body)
    fieldpairs = Expr[]
    metaexpr = :(NamedTuple())
    for line in body.args
        line isa LineNumberNode && continue
        if line isa Expr && line.head === :(=)
            lhs = line.args[1]
            fname = lhs isa Symbol ? lhs : (lhs isa Expr && lhs.head === :(::)) ? lhs.args[1] :
                    error("@model: cannot parse field '$lhs'")
            push!(fieldpairs, :($(QuoteNode(fname)) => $(esc(line.args[2]))))
        elseif line isa Expr && line.head === :call && line.args[1] === :Meta
            kws = [a.head === :kw ? a : error("Meta(...) takes keyword arguments") for a in line.args[2:end]]
            metaexpr = esc(Expr(:tuple, Expr(:parameters, kws...)))
        else
            error("@model: unsupported line in model body: $line")
        end
    end
    fieldpairs, metaexpr
end

"Abstract models above `T`, outermost first."
Base.@nospecializeinfer function abstract_bases(@nospecialize(T::Type))
    out = Any[]
    S = supertype(T)
    while S !== Any
        haskey(ABSTRACT_MODELS, S) && pushfirst!(out, S)
        S = supertype(S)
    end
    out
end

"Metadata for a model type."
Base.@nospecializeinfer function modelmeta(@nospecialize(T::Type))
    m = get(MODEL_REGISTRY, T, nothing)
    m === nothing && error("$T is not a registered model")
    m
end
"All registered model types."
all_models() = copy(MODEL_LIST)

function findfield(meta::ModelMeta, name::Symbol)
    for f in meta.fields
        (f.name === name || attname(f) === name) && return f
    end
    (meta.parent === nothing || meta.proxy) && return nothing
    findfield(modelmeta(meta.parent), name)      # multi-table inheritance: the parent's fields too
end

"The model that owns `T`'s table (a proxy's concrete model, else `T`)."
Base.@nospecializeinfer concrete_model(@nospecialize(T::Type)) = (m = modelmeta(T); m.proxy ? concrete_model(m.parent) : T)
"Multi-table parent of `T` (not for proxies), or `nothing`."
Base.@nospecializeinfer table_parent(@nospecialize(T::Type)) = (m = modelmeta(concrete_model(T)); m.parent)
"Multi-table ancestors of `T`, nearest first."
Base.@nospecializeinfer function ancestors(@nospecialize(T::Type))
    out = Any[]
    P = table_parent(T)
    while P !== nothing
        push!(out, P)
        P = table_parent(P)
    end
    out
end
"`T`, its proxy target and its multi-table ancestors: every model whose rows `T`'s rows also are."
Base.@nospecializeinfer lineage(@nospecialize(T::Type)) = unique(vcat(Any[T, concrete_model(T)], ancestors(T)))
"Multi-table children of `T` (models whose table extends `T`'s)."
Base.@nospecializeinfer child_models(@nospecialize(T::Type)) = cached_relations(compute_child_models, :children, T)
Base.@nospecializeinfer compute_child_models(@nospecialize(T::Type)) = Any[C for C in MODEL_LIST if (m = modelmeta(C); !m.proxy && m.parent === concrete_model(T))]
"All fields of `T` including inherited multi-table fields, ancestors' first."
Base.@nospecializeinfer function all_fields(@nospecialize(T::Type))
    C = concrete_model(T)
    P = table_parent(C)
    P === nothing ? modelmeta(C).fields : vcat(all_fields(P), modelmeta(C).fields)
end
"Name of the accessor from a parent instance to its multi-table child (`place.restaurant`)."
child_accessor(C::Type) = Symbol(lowercase(modelmeta(C).name))
"Name of the accessor from a child to its parent instance (`restaurant.place_ptr`)."
Base.@nospecializeinfer parent_accessor(@nospecialize(T::Type)) = Symbol(lowercase(modelmeta(table_parent(T)).name), :_ptr)
Base.@nospecializeinfer function getfield_meta(@nospecialize(T::Type), name::Symbol)
    f = findfield(modelmeta(T), name)
    f === nothing && throw(LookupError("$T has no field named '$name'"))
    f
end

function related_model(f::Field)
    r = f.related
    r === :self && return f.model
    r === :__user_model__ && return get_user_model()        # ForeignKey(USER_MODEL)
    r isa Symbol || r isa AbstractString || return r
    for T in MODEL_LIST
        string(nameof(T)) == string(r) && return T
    end
    error("ForeignKey target '$r' is not a registered model")
end

Base.@nospecializeinfer function register_model!(@nospecialize(T::Type), fields::Vector, meta::NamedTuple = NamedTuple())
    # inherited from abstract models: their fields come first, their Meta options are defaults
    inherited = Pair{Symbol,Any}[]
    for S in abstract_bases(T)
        fsS, metaS = ABSTRACT_MODELS[S]
        filter!(p -> !any(q -> q.first === p.first, fsS), inherited)
        append!(inherited, fsS)
        meta = merge(Base.structdiff(metaS, NamedTuple{(:table, :name, :verbose_name, :verbose_name_plural)}), meta)
    end
    fields = vcat(filter(p -> !any(q -> q.first === p.first, fields), inherited), fields)
    parent = get(meta, :_parent, nothing)
    parent = parent === nothing || isabstracttype(parent) ? nothing : parent
    proxy = get(meta, :proxy, false)
    proxy && parent === nothing && error("$T: Meta(proxy=true) needs a concrete parent model (struct $T <: Parent)")
    proxy && !isempty(fields) && error("$T: a proxy model can't add fields")
    if parent !== nothing
        pm = modelmeta(parent)
        haskey(meta, :ordering) || (meta = merge(meta, (ordering = pm.ordering,)))
        proxy && (meta = merge(meta, (table = pm.table,)))
        haskey(meta, :app_label) || (meta = merge(meta, (app_label = pm.app,)))
    end
    fs = Field[]
    m2m = Field[]
    gfks, grels, fobjs = Field[], Field[], Field[]
    for (name, f) in fields
        f isa Field || error("$T.$name must be a field (CharField(...), ForeignKey(...), ...)")
        f = deepcopy(f)
        f.name = name
        f.model = T
        name in (:id, :pk) && error("$T: '$name' is reserved for the automatic primary key")
        push!(f.kind === :m2m ? m2m : f.kind === :gfk ? gfks : f.kind === :grel ? grels : f.kind === :fobj ? fobjs : fs, f)
    end
    name = string(get(meta, :name, nameof(T)))
    vname = get(meta, :verbose_name, lowercase(replace(name, r"(?<=[a-z])(?=[A-Z])" => " ")))
    m = ModelMeta(T, name, string(get(meta, :table, lowercase(name))), fs,
                  String[string(o) for o in get(meta, :ordering, String[])],
                  vname isa AbstractString ? vname : string(vname),
                  (vp = get(meta, :verbose_name_plural, nothing); vp === nothing ? string(vname) * "s" : vp isa AbstractString ? vp : string(vp)),
                  string(get(meta, :app_label, default_app_label(T))), m2m,
                  [Symbol.(collect(u)) for u in get(meta, :unique_together, [])],
                  parent, proxy,
                  Dict{Symbol,Any}(k => v for (k, v) in pairs(meta)
                                   if !(k in (:table, :name, :verbose_name, :verbose_name_plural, :ordering, :app_label,
                                              :unique_together, :_parent, :proxy))))
    isempty(gfks) || (m.extra[:generic_fks] = gfks)
    isempty(grels) || (m.extra[:generic_relations] = grels)
    isempty(fobjs) || (m.extra[:foreign_objects] = fobjs)
    proxy && (m.fields = modelmeta(parent).fields; m.m2m = modelmeta(parent).m2m)
    MODEL_REGISTRY[T] = m
    filter!(x -> !(x === T || modelmeta_or_nothing(x) === nothing ||
                   modelmeta(x).name == name && parentmodule(x) == parentmodule(T)), MODEL_LIST)
    push!(MODEL_LIST, T)
    invalidate_relations!()
    for f in m2m
        f.through === nothing && (f.through = make_through_model(T, m, f))
    end
    T
end
modelmeta_or_nothing(T) = get(MODEL_REGISTRY, T, nothing)

"""
Join model generated for a `ManyToManyField` without `through=`. Each join table is its
own type, `AutoThrough{:post_tags}`, so it is a normal model to the ORM and migrations.
"""
mutable struct AutoThrough{N} <: Model
    _data::Dict{Symbol,Any}
    _cache::Dict{Symbol,Any}
end
(::Type{AutoThrough{N}})(; kwargs...) where {N} = construct(AutoThrough{N}; kwargs...)

# (a many-to-many to USER_MODEL names its join column `user_id`, whichever model AUTH_USER_MODEL names)
target_name(f::Field, owner) = f.related === :self ? string(nameof(owner)) : f.related === :__user_model__ ? "User" :
                               f.related isa Type ? string(nameof(f.related)) : string(f.related)

Base.@nospecializeinfer function make_through_model(@nospecialize(T::Type), m::ModelMeta, f::Field)
    table = m.table * "_" * string(f.name)
    tname = target_name(f, T)
    src, dst = lowercase(m.name), lowercase(tname)
    if src == dst
        src, dst = "from_" * src, "to_" * dst
    end
    # Reverse names starting with '+' are hidden (not listed in propertynames).
    srcf = ForeignKey(T; on_delete = :CASCADE, related_name = Symbol("+", table, "_src"))
    dstf = ForeignKey(f.related === :self ? T : f.related; on_delete = :CASCADE, related_name = Symbol("+", table, "_dst"))
    Th = AutoThrough{Symbol(m.app, ".", table)}
    register_model!(Th, Pair{Symbol,Any}[Symbol(src) => srcf, Symbol(dst) => dstf],
                    (table = table, name = m.name * "_" * string(f.name), app_label = m.app,
                     unique_together = [(Symbol(src), Symbol(dst))],
                     verbose_name = m.name * "-" * tname * " relationship"))
    Th
end

"A many-to-many's intermediate model (`through` may name a model defined later)."
function through_model(f::Field)
    t = f.through
    t isa Type && return t
    for T in MODEL_LIST
        modelmeta(T).name == string(t) && return (f.through = T)
    end
    error("ManyToManyField $(f.name): through model '$t' is not a registered model")
end

"""
    through(Model, :field) -> join model

The model behind a many-to-many field (Django's `Post.tags.through`): its join table's model, or the
`through` model you gave. It's an ordinary model, so `objects`, `filter`, `bulk_create` and
`values_list` work on it, and it's the sender of `m2m_changed`:

    connect!(m2m_changed, tags_changed; sender = through(Post, :tags))
    bulk_create([through(Post, :tags)(post_id = p.id, tag_id = t.id) for (p, t) in links])

An automatic join model's two foreign keys are named after the models in lowercase (`post`/`tag`),
or `from_post`/`to_post` for a relation from a model to itself.
"""
Base.@nospecializeinfer function through(@nospecialize(T::Type{<:Model}), name)
    i = findfirst(f -> f.name === Symbol(name), modelmeta(T).m2m)
    i === nothing && throw(ArgumentError("$(nameof(T)) has no many-to-many field '$name'"))
    through_model(modelmeta(T).m2m[i])
end

"The two foreign keys of a many-to-many's intermediate model: (to the owner, to the target)."
function through_fks(f::Field)
    Th, owner, target = through_model(f), f.model, related_model(f)
    fks = [g for g in modelmeta(Th).fields if g.kind === :fk]
    if owner === target
        length(fks) >= 2 || error("$(nameof(Th)) needs two foreign keys to $(nameof(owner))")
        return fks[1], fks[2]
    end
    src = findfirst(g -> related_model(g) === owner, fks)
    dst = findfirst(g -> related_model(g) === target, fks)
    (src === nothing || dst === nothing) && error("$(nameof(Th)) needs foreign keys to both $(nameof(owner)) and $(nameof(target))")
    fks[src], fks[dst]
end

"Name of a foreign key's reverse relation (`post_set` or its `related_name`)."
reverse_name(fk::Field) = fk.related_name !== nothing ? fk.related_name :
    fk.one_to_one ? Symbol(lowercase(modelmeta(fk.model).name)) : Symbol(lowercase(modelmeta(fk.model).name), :_set)

"Many-to-many relations reachable from `T`: (name, field, forward::Bool)."
Base.@nospecializeinfer m2m_relations(@nospecialize(T::Type)) = cached_relations(compute_m2m_relations, :m2m, T)
Base.@nospecializeinfer function compute_m2m_relations(@nospecialize(T::Type))
    out = Tuple{Symbol,Field,Bool}[]
    for f in modelmeta(T).m2m
        push!(out, (f.name, f, true))
    end
    for M in MODEL_LIST, f in modelmeta(M).m2m
        model_in_use(M) || continue
        related_model(f) === T || continue
        push!(out, (f.related_name === nothing ? Symbol(lowercase(modelmeta(M).name), :_set) : f.related_name, f, false))
    end
    out
end
Base.@nospecializeinfer function find_m2m(@nospecialize(T::Type), name)
    for r in m2m_relations(T)
        string(r[1]) == name && return r
    end
    nothing
end
"""
A many-to-many relation of `T` by its name in lookups (`filter`, `Count`, `values` paths): the
field's name, or for the reverse side its query name: `related_query_name`, else
`related_name`, else the other model's name in lowercase (`filter(Lot; sample__name = "x")`).
"""
Base.@nospecializeinfer function find_m2m_query(@nospecialize(T::Type), name)
    for r in m2m_relations(T)
        f = r[2]
        q = r[3] ? string(r[1]) :
            string(something(f.related_query_name, f.related_name, Symbol(lowercase(modelmeta(f.model).name))))
        (q == name || string(r[1]) == name) && return r
    end
    nothing
end

"""
The lookup path that reaches the other side of a many-to-many through its join model:
`tags` on Post becomes `+post_tags_src__tag`.
"""
function m2m_path(f::Field, forward::Bool)
    src, dst = through_fks(f)
    forward ? (reverse_name(src), dst.name) : (reverse_name(dst), src.name)
end

"""
    @model struct Name
        field = CharField(...)
        other::Int = IntegerField(...)   # type annotations are optional & informational
        Meta(ordering=["-id"], table="custom_table", verbose_name="...")
    end

Define a database-backed model. Instances behave like mutable objects with the
declared fields plus `id`/`pk`. ForeignKeys are exposed as both `obj.author`
(the related object, fetched lazily) and `obj.author_id`. Reverse relations are
available as `obj.post_set` (or the `related_name`).
"""
macro model(expr)
    (expr isa Expr && expr.head === :struct) || error("@model expects a struct definition")
    name, super = expr.args[2], nothing
    if name isa Expr && name.head === :(<:)
        name, super = name.args
    end
    name isa Symbol || error("@model: unsupported struct name $(name)")
    fieldpairs, metaexpr = parse_model_body(expr.args[3])
    M = GlobalRef(@__MODULE__, :Model)
    sup = super === nothing ? M : :($(GlobalRef(@__MODULE__, :model_supertype))($super))
    structdef = Expr(:struct, true, Expr(:(<:), name, sup),
                     Expr(:block, :(_data::Dict{Symbol,Any}), :(_cache::Dict{Symbol,Any})))
    metaexpr = super === nothing ? metaexpr : :(merge((_parent = $(esc(super)),), $metaexpr))
    quote
        Base.@__doc__ $(esc(structdef))                          # (a docstring before @model documents the struct)
        $(esc(name))(; kwargs...) = $(GlobalRef(@__MODULE__, :construct))($(esc(name)); kwargs...)
        $(GlobalRef(@__MODULE__, :register_model!))($(esc(name)), Pair{Symbol,Any}[$(fieldpairs...)], $metaexpr)
        $(esc(name))
    end
end

function default_value(f::Field)
    f.generated === nothing || return nothing
    d = f.default
    d isa NoDefault && f.db_default !== nothing && return DB_DEFAULT
    d isa NoDefault || return d isa Function || d isa Type ? d() : d
    f.null && return nothing
    (f.kind in STRING_KINDS || f.kind === :filepath) && return ""
    f.kind === :bool && return false
    nothing
end

Base.@nospecializeinfer function construct(@nospecialize(T::Type{<:Model}); kwargs...)
    meta = modelmeta(T)
    obj = T(Dict{Symbol,Any}(:id => nothing), Dict{Symbol,Any}())
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    kw = Dict{Symbol,Any}(kwargs)
    haskey(kw, :pk) && (kw[:id] = pop!(kw, :pk))
    haskey(kw, :id) && (data[:id] = pop!(kw, :id))
    for f in all_fields(T)
        if haskey(kw, f.name)
            setproperty!(obj, f.name, pop!(kw, f.name))
        elseif f.kind === :fk && haskey(kw, attname(f))
            data[attname(f)] = pop!(kw, attname(f))
        else
            data[attname(f)] = default_value(f)
        end
    end
    for g in generic_fks(T)
        haskey(kw, g.name) && set_generic!(obj, g, pop!(kw, g.name))
    end
    for g in foreign_objects(T)
        haskey(kw, g.name) && set_fobj!(obj, g, pop!(kw, g.name))
    end
    for k in collect(keys(kw))                   # computed attributes with a setter (tattr!)
        tattr!(obj, Val(k), kw[k]) === NOTFOUND || delete!(kw, k)
    end
    isempty(kw) || throw(ArgumentError("$T got unexpected field(s): $(join(keys(kw), ", "))"))
    obj
end

"""
    instance_cache(obj) -> Dict{Symbol,Any}

A place on one model object for values that aren't fields and are never saved: memoised
results, or values a view computes for its template. `obj.name` and `{{ obj.name }}` find them
after the fields and relations.

    get!(() -> expensive_total(order), instance_cache(order), :total)
    instance_cache(post)[:comment_count] = n            # then {{ post.comment_count }}
"""
Base.@nospecializeinfer instance_cache(@nospecialize(m::Model)) =
    get!(Dict{Symbol,Any}, (getfield(m, :_cache)::Dict{Symbol,Any}), :__extra)::Dict{Symbol,Any}
Base.@nospecializeinfer function extra_value(@nospecialize(m::Model), s::Symbol)
    x = get((getfield(m, :_cache)::Dict{Symbol,Any}), :__extra, nothing)
    x === nothing ? NOTFOUND : get(x::Dict{Symbol,Any}, s, NOTFOUND)
end

"Reverse FK relations pointing at model `T`: Vector of (name, Model, Field)."
Base.@nospecializeinfer reverse_relations(@nospecialize(T::Type)) = cached_relations(compute_reverse_relations, :reverse, T)
Base.@nospecializeinfer function compute_reverse_relations(@nospecialize(T::Type))
    out = Tuple{Symbol,Any,Field}[]
    lin = lineage(T)
    for M in MODEL_LIST
        (modelmeta(M).proxy || !model_in_use(M)) && continue
        for f in modelmeta(M).fields
            f.kind === :fk || continue
            related_model(f) in lin || continue
            push!(out, (reverse_name(f), M, f))
        end
    end
    out
end

"""
The stored value of a concrete field (by attribute name), loading the object's deferred
fields (see `only`/`defer`) with one query if it isn't loaded yet.
"""
Base.@nospecializeinfer function field_data(@nospecialize(m::Model), a::Symbol)
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    v = get(data, a, NOTFOUND)
    v === NOTFOUND || return v
    load_deferred!(m)
    data[a]
end

"Fetch an object's unloaded fields from the database (keeping the values already loaded)."
Base.@nospecializeinfer function load_deferred!(@nospecialize(m::Model))
    T = typeof(m)
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    data[:id] === nothing && throw(ArgumentError("$(nameof(T)) has no value for a deferred field and isn't saved"))
    fresh = getfield(with_db(() -> get(base_objects(T); id = data[:id]), instance_db(m)), :_data)
    for (k, v) in fresh
        haskey(data, k) || (data[k] = v)
    end
    m
end

"The fields of an object that `only`/`defer` (or `raw`) left unloaded."
Base.@nospecializeinfer deferred_fields(@nospecialize(m::Model)) = Symbol[attname(f) for f in all_fields(typeof(m)) if !haskey((getfield(m, :_data)::Dict{Symbol,Any}), attname(f))]

# A field's value is a lookup in the object's Dict; everything else (relations, display
# values, ...) goes through `model_property`, compiled once for every model.
function Base.getproperty(m::Model, s::Symbol)        # small: compiled per model
    v = get((getfield(m, :_data)::Dict{Symbol,Any}), s, NOTFOUND)
    v === NOTFOUND ? model_property(m, s) : v
end
Base.@nospecializeinfer function model_property(@nospecialize(m::Model), s::Symbol)
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    s === :pk && return data[:id]
    s in (:_data, :_cache) && return getfield(m, s)
    T = typeof(m)
    any(f -> attname(f) === s, all_fields(T)) && return field_data(m, s)
    f = findfield(modelmeta(T), s)
    if f !== nothing && f.kind === :fk
        id = field_data(m, attname(f))
        id === nothing && return nothing
        cache = (getfield(m, :_cache)::Dict{Symbol,Any})
        c = get(cache, s, nothing)
        (c !== nothing && (getfield(c, :_data)::Dict{Symbol,Any})[:id] == id) && return c
        obj = with_db(() -> get(base_objects(related_model(f)); id = id), instance_db(m))
        cache[s] = obj
        return obj
    end
    cache = (getfield(m, :_cache)::Dict{Symbol,Any})
    pre = get(cache, s, NOTFOUND)
    g = find_generic(generic_fks(T), s)
    g === nothing || return get_generic(m, g)
    g = find_generic(foreign_objects(T), s)
    g === nothing || return get_fobj(m, g)
    r = find_reverse_fobj(T, s)
    if r !== nothing
        qs = fobj_queryset(m, r[2], r[3])
        return pre isa PrefetchedList ? chain(qs; cache = pre.items) : qs
    end
    g = find_generic(generic_relations(T), s)
    if g !== nothing
        qs = generic_queryset(m, g)
        return pre isa PrefetchedList ? chain(qs; cache = pre.items) : qs
    end
    mm = find_m2m(T, string(s))
    if mm !== nothing
        qs = m2m_queryset(m, mm[2], mm[3])
        pre isa PrefetchedList && return chain(qs; cache = pre.items, owner = qs.owner)
        return qs
    end
    for (rn, M, rf) in reverse_relations(T)
        rn === s || continue
        qs = chain(filter(objects(M), Q(attname(rf) => data[:id])); db = instance_db(m))
        if rf.one_to_one
            pre isa PrefetchedList && return isempty(pre.items) ? nothing : pre.items[1]
            return first(qs)
        end
        pre isa PrefetchedList && return chain(qs; cache = pre.items)
        return qs
    end
    for C in child_models(T)
        child_accessor(C) === s && return first(filter(base_objects(C); id = data[:id]))
    end
    if table_parent(T) !== nothing && s === parent_accessor(T)
        return get(base_objects(table_parent(T)); id = data[:id])
    end
    pre === NOTFOUND || return pre isa PrefetchedList ? pre.items : pre    # Prefetch(...; to_attr)
    x = extra_value(m, s)
    x === NOTFOUND || return x                                             # instance_cache(obj)
    df = display_field(T, s)
    df === nothing || return get_display(m, df.name)                     # obj.get_status_display
    nb = adjacent_field(T, s)
    nb === nothing || return adjacent_by(m, nb[1], nb[2])                  # obj.get_next_by_created
    r = tattr(m, Val(s))
    r === NOTFOUND || return r
    throw(ArgumentError("$(T) has no attribute '$s'"))
end

Base.@nospecializeinfer function Base.setproperty!(@nospecialize(m::Model), s::Symbol, @nospecialize(v))
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    s === :pk && (s = :id)
    g = find_generic(generic_fks(typeof(m)), s)
    g === nothing || return set_generic!(m, g, v)
    g = find_generic(foreign_objects(typeof(m)), s)
    g === nothing || return set_fobj!(m, g, v)
    f = findfield(modelmeta(typeof(m)), s)
    if f !== nothing && f.kind === :fk && s === f.name
        if v === nothing
            data[attname(f)] = nothing
            delete!((getfield(m, :_cache)::Dict{Symbol,Any}), s)
        elseif v isa Model
            data[attname(f)] = (getfield(v, :_data)::Dict{Symbol,Any})[:id]
            (getfield(m, :_cache)::Dict{Symbol,Any})[s] = v
        else
            data[attname(f)] = v
        end
        return v
    end
    if f === nothing && s !== :id
        tattr!(m, Val(s), v) === NOTFOUND && throw(ArgumentError(
            "$(typeof(m)) has no field '$s' (for a value that isn't saved use Juango.instance_cache(obj)[:$s] = v; " *
            "for a computed attribute define Juango.tattr!(::$(nameof(typeof(m))), ::Val{:$s}, v))"))
        return v
    end
    data[s] = f === nothing ? v : coerce_value(f, v)
end

coerce_value(f::Field, v) = v
coerce_value(f::Field, v::SafeString) = v.s

# `{{ obj.field }}`: a model's fields are a Dict lookup (relations and the rest go the long way, through getattr_other)
Base.@nospecializeinfer function getattr(@nospecialize(obj::Model), part::AbstractString, sym::Symbol, @nospecialize(val), idx::Int)
    v = get((getfield(obj, :_data)::Dict{Symbol,Any}), sym, NOTFOUND)
    v === NOTFOUND || return v
    v = extra_value(obj, sym)
    v === NOTFOUND ? getattr_other(obj, part, sym, val, idx) : v
end

# The same for every instance of a model, so worked out once per model (with the relations).
Base.@nospecializeinfer Base.propertynames(@nospecialize(m::Model), private::Bool = false) = propertynames_of(typeof(m))
# `{{ obj.attr }}` asks this for each lookup that isn't a field
Base.@nospecializeinfer Base.hasproperty(@nospecialize(m::Model), s::Symbol) =
    s in (cached_relations(property_set, :propertyset, typeof(m))::Set{Symbol}) || extra_value(m, s) !== NOTFOUND
Base.@nospecializeinfer propertynames_of(@nospecialize(T)) = cached_relations(compute_propertynames, :propertynames, T)
Base.@nospecializeinfer compute_propertynames(@nospecialize(T)) = Tuple(property_list(T))
Base.@nospecializeinfer property_set(@nospecialize(T)) = Set{Symbol}(property_list(T))
Base.@nospecializeinfer function property_list(@nospecialize(T))
    names = Symbol[:id, :pk]
    for f in all_fields(T)
        push!(names, attname(f))
        f.kind === :fk && push!(names, f.name)
        f.choices === nothing || push!(names, Symbol("get_", f.name, "_display"))
        f.kind in (:date, :datetime) && !f.null && push!(names, Symbol("get_next_by_", f.name), Symbol("get_previous_by_", f.name))
    end
    append!(names, [r[1] for r in reverse_relations(T) if !startswith(string(r[1]), "+")])
    append!(names, first.(m2m_relations(T)))
    append!(names, child_accessor.(child_models(T)))
    append!(names, [g.name for g in vcat(generic_fks(T), generic_relations(T), foreign_objects(T))])
    append!(names, first.(reverse_foreign_objects(T)))
    table_parent(T) === nothing || push!(names, parent_accessor(T))
    names
end

Base.@nospecializeinfer Base.:(==)(@nospecialize(a::Model), @nospecialize(b::Model)) = typeof(a) === typeof(b) && a.id !== nothing && a.id == b.id
Base.@nospecializeinfer Base.hash(@nospecialize(m::Model), h::UInt) = m.id === nothing ? objectid(m) ⊻ h : hash((typeof(m), m.id), h)
Base.show(io::IO, m::Model) = print(io, nameof(typeof(m)), " object (", something(m.id, "unsaved"), ")")
function Base.show(io::IO, ::MIME"text/plain", m::Model)
    print(io, "<", nameof(typeof(m)), ": ")
    show(io, m)
    print(io, ">")
end

"""
    get_absolute_url(obj)

Override for your models to give them a canonical URL (used by generic views and
the admin's "View on site" link). Available in templates as `obj.get_absolute_url`.
"""
get_absolute_url(::Model) = nothing
"`(field, next)` for `get_next_by_<field>` / `get_previous_by_<field>` on a non-null date field."
Base.@nospecializeinfer function adjacent_field(@nospecialize(T), s::Symbol)
    str = string(s)
    for (pre, next) in (("get_next_by_", true), ("get_previous_by_", false))
        startswith(str, pre) || continue
        f = findfield(modelmeta(T), Symbol(str[length(pre)+1:end]))
        f !== nothing && f.kind in (:date, :datetime) && !f.null && return (f.name, next)
    end
    nothing
end

"The field behind `get_<name>_display`, when it has choices."
Base.@nospecializeinfer function display_field(@nospecialize(T), s::Symbol)
    str = string(s)
    (startswith(str, "get_") && endswith(str, "_display")) || return nothing
    f = findfield(modelmeta(T), Symbol(chop(str; head = 4, tail = 8)))
    f !== nothing && f.choices !== nothing ? f : nothing
end

"""
    get_display(obj, :field)

The label of the field's current value (Django's `obj.get_FOO_display()`), or the value itself
when it isn't one of the choices. Also `obj.get_status_display`, in Julia and in templates.
"""
Base.@nospecializeinfer function get_display(@nospecialize(m::Model), name::Symbol)
    f = findfield(modelmeta(typeof(m)), name)
    f === nothing && throw(ArgumentError("$(typeof(m)) has no field '$name'"))
    v = getproperty(m, attname(f))
    v === nothing ? nothing : choice_label(field_choices(f), v)
end

Base.@nospecializeinfer function tattr(@nospecialize(m::Model), ::Val{:get_absolute_url})
    u = get_absolute_url(m)
    u === nothing ? NOTFOUND : u
end
Base.@nospecializeinfer tattr(@nospecialize(m::Model), ::Val{:verbose_name}) = modelmeta(typeof(m)).verbose_name
Base.@nospecializeinfer tattr(@nospecialize(m::Model), ::Val{:pk_string}) = pk_string(m)
