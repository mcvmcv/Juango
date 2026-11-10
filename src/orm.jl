# ORM ----------------------------------------------------------------------------------------
#
#     @model struct Post
#         title    = CharField(max_length=200)
#         body     = TextField(blank=true)
#         author   = ForeignKey(Author, on_delete=:CASCADE)
#         created  = DateTimeField(auto_now_add=true)
#         Meta(ordering=["-created"])
#     end
#
#     p = create(Post; title="Hi", author=bob)
#     filter(Post; title__icontains="hi", author__name="Bob") |> order_by("-created")

"Abstract supertype of every model defined with [`@model`](@ref)."
abstract type Model end

struct NoDefault end
const NO_DEFAULT = NoDefault()

"""
Field definition shared by models and forms. Construct with `CharField`,
`IntegerField`, `ForeignKey`, ...
"""
mutable struct Field
    kind::Symbol
    name::Symbol
    null::Bool
    blank::Bool
    default::Any
    unique::Bool
    max_length::Union{Nothing,Int}
    choices::Union{Nothing,Vector{Pair{Any,String}}}
    related::Any
    on_delete::Symbol
    related_name::Union{Nothing,Symbol}
    auto_now::Bool
    auto_now_add::Bool
    verbose_name::String
    help_text::String
    validators::Vector{Any}
    widget::Union{Nothing,Symbol}
    editable::Bool
    db_index::Bool
    model::Any
    through::Any        # ManyToManyField: the intermediate model (generated when not given)
    one_to_one::Bool    # OneToOneField: a unique FK whose reverse side is a single object
end

normchoices(::Nothing) = nothing
normchoices(cs) = Pair{Any,String}[c isa Pair ? (c.first => string(c.second)) : (c => string(c)) for c in cs]

function Field(kind::Symbol; null = false, blank = false, default = NO_DEFAULT, unique = false,
               max_length = nothing, choices = nothing, related = nothing, on_delete = :CASCADE,
               related_name = nothing, auto_now = false, auto_now_add = false, verbose_name = "",
               help_text = "", validators = Any[], widget = nothing, editable = true,
               db_index = false, required = nothing, label = nothing, through = nothing, one_to_one = false)
    required === nothing || (blank = !required)
    label === nothing || (verbose_name = string(label))
    if auto_now || auto_now_add
        editable = false
        blank = true
    end
    Field(kind, :_, null, blank, default, unique, max_length, normchoices(choices), related,
          Symbol(uppercase(string(on_delete))), related_name === nothing ? nothing : Symbol(related_name),
          auto_now, auto_now_add, string(verbose_name), string(help_text), collect(Any, validators),
          widget === nothing ? nothing : Symbol(widget), editable, db_index, nothing, through, one_to_one)
end

CharField(; max_length = 255, kw...) = Field(:char; max_length = max_length, kw...)
TextField(; kw...) = Field(:text; kw...)
EmailField(; max_length = 254, kw...) = Field(:email; max_length = max_length, kw...)
SlugField(; max_length = 50, kw...) = Field(:slug; max_length = max_length, db_index = true, kw...)
URLField(; max_length = 200, kw...) = Field(:url; max_length = max_length, kw...)
IntegerField(; kw...) = Field(:int; kw...)
FloatField(; kw...) = Field(:float; kw...)
BooleanField(; default = false, kw...) = Field(:bool; default = default, blank = true, kw...)
DateTimeField(; kw...) = Field(:datetime; kw...)
DateField(; kw...) = Field(:date; kw...)
"""
    ForeignKey(Model; on_delete=:CASCADE, related_name=nothing, kw...)

`Model` may be a type, `:self`, or a `Symbol` naming a model defined later.
`on_delete` is one of `:CASCADE`, `:SET_NULL`, `:PROTECT`, `:DO_NOTHING`.
"""
ForeignKey(to; on_delete = :CASCADE, kw...) = Field(:fk; related = to, on_delete = on_delete, db_index = true, kw...)

"""
    OneToOneField(Model; on_delete=:CASCADE, related_name=nothing, kw...)

A foreign key with a unique constraint. The reverse side is a single object (or
`nothing`): `user.profile` instead of a queryset. Its default name is the lower-case
model name.
"""
OneToOneField(to; on_delete = :CASCADE, kw...) =
    Field(:fk; related = to, on_delete = on_delete, unique = true, one_to_one = true, kw...)

"""
    ManyToManyField(Model; related_name=nothing, through=nothing, blank=false, kw...)

A many-to-many relation. Juango creates the join table (`<table>_<field>`, with a unique
pair) unless `through` names your own intermediate model with two foreign keys. Access it
as `post.tags` (a queryset) and change it with `add!`, `remove!`, `set!` and `clear!`.
The other side gets `tag.post_set` (or `related_name`).
"""
ManyToManyField(to; kw...) = Field(:m2m; related = to, kw...)

const STRING_KINDS = (:char, :text, :email, :slug, :url)

"Attribute name under which the raw value is stored (`author_id` for a FK)."
attname(f::Field) = f.kind === :fk ? Symbol(f.name, :_id) : f.name
column(f::Field) = string(attname(f))
label(f::Field) = isempty(f.verbose_name) ? uppercasefirst(replace(string(f.name), '_' => ' ')) : f.verbose_name

mutable struct ModelMeta
    model::Type
    name::String
    table::String
    fields::Vector{Field}
    ordering::Vector{String}
    verbose_name::String
    verbose_name_plural::String
    app::String
    m2m::Vector{Field}
    unique_together::Vector{Vector{Symbol}}
    parent::Any          # multi-table parent or proxy target (a concrete model), else nothing
    proxy::Bool
    extra::Dict{Symbol,Any}   # other Meta options (e.g. indexes)
end

const MODEL_REGISTRY = Dict{Any,ModelMeta}()
const MODEL_LIST = Any[]

"""
App a model belongs to for migrations: `Meta(app_label=...)`, else `\"juango\"` for Juango's
built-in models and `\"project\"` for everything else.
"""
default_app_label(T) = parentmodule(T) === (@__MODULE__) ? "juango" : "project"

"Remove a model from the registry (mostly for tests that redefine models)."
function unregister_model!(T::Type)
    delete!(MODEL_REGISTRY, T)
    filter!(x -> x !== T, MODEL_LIST)
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
        abstract type $(esc(name)) <: $sup end
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
function abstract_bases(T::Type)
    out = Any[]
    S = supertype(T)
    while S !== Any
        haskey(ABSTRACT_MODELS, S) && pushfirst!(out, S)
        S = supertype(S)
    end
    out
end

"Metadata for a model type."
function modelmeta(T::Type)
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
concrete_model(T::Type) = (m = modelmeta(T); m.proxy ? concrete_model(m.parent) : T)
"Multi-table parent of `T` (not for proxies), or `nothing`."
table_parent(T::Type) = (m = modelmeta(concrete_model(T)); m.parent)
"Multi-table ancestors of `T`, nearest first."
function ancestors(T::Type)
    out = Any[]
    P = table_parent(T)
    while P !== nothing
        push!(out, P)
        P = table_parent(P)
    end
    out
end
"`T`, its proxy target and its multi-table ancestors: every model whose rows `T`'s rows also are."
lineage(T::Type) = unique(vcat([T, concrete_model(T)], ancestors(T)))
"Multi-table children of `T` (models whose table extends `T`'s)."
child_models(T::Type) = [C for C in MODEL_LIST if (m = modelmeta(C); !m.proxy && m.parent === concrete_model(T))]
"All fields of `T` including inherited multi-table fields, ancestors' first."
function all_fields(T::Type)
    C = concrete_model(T)
    P = table_parent(C)
    P === nothing ? modelmeta(C).fields : vcat(all_fields(P), modelmeta(C).fields)
end
"Name of the accessor from a parent instance to its multi-table child (`place.restaurant`)."
child_accessor(C::Type) = Symbol(lowercase(modelmeta(C).name))
"Name of the accessor from a child to its parent instance (`restaurant.place_ptr`)."
parent_accessor(T::Type) = Symbol(lowercase(modelmeta(table_parent(T)).name), :_ptr)
function getfield_meta(T::Type, name::Symbol)
    f = findfield(modelmeta(T), name)
    f === nothing && throw(LookupError("$T has no field named '$name'"))
    f
end

function related_model(f::Field)
    r = f.related
    r === :self && return f.model
    r isa Symbol || r isa AbstractString || return r
    for T in MODEL_LIST
        string(nameof(T)) == string(r) && return T
    end
    error("ForeignKey target '$r' is not a registered model")
end

function register_model!(T::Type, fields::Vector, meta::NamedTuple = NamedTuple())
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
    gfks, grels = Field[], Field[]
    for (name, f) in fields
        f isa Field || error("$T.$name must be a field (CharField(...), ForeignKey(...), ...)")
        f = deepcopy(f)
        f.name = name
        f.model = T
        name in (:id, :pk) && error("$T: '$name' is reserved for the automatic primary key")
        push!(f.kind === :m2m ? m2m : f.kind === :gfk ? gfks : f.kind === :grel ? grels : fs, f)
    end
    name = string(get(meta, :name, nameof(T)))
    vname = get(meta, :verbose_name, lowercase(replace(name, r"(?<=[a-z])(?=[A-Z])" => " ")))
    m = ModelMeta(T, name, string(get(meta, :table, lowercase(name))), fs,
                  String[string(o) for o in get(meta, :ordering, String[])],
                  string(vname), string(get(meta, :verbose_name_plural, vname * "s")),
                  string(get(meta, :app_label, default_app_label(T))), m2m,
                  [Symbol.(collect(u)) for u in get(meta, :unique_together, [])],
                  parent, proxy,
                  Dict{Symbol,Any}(k => v for (k, v) in pairs(meta)
                                   if !(k in (:table, :name, :verbose_name, :verbose_name_plural, :ordering, :app_label,
                                              :unique_together, :_parent, :proxy))))
    isempty(gfks) || (m.extra[:generic_fks] = gfks)
    isempty(grels) || (m.extra[:generic_relations] = grels)
    proxy && (m.fields = modelmeta(parent).fields; m.m2m = modelmeta(parent).m2m)
    MODEL_REGISTRY[T] = m
    filter!(x -> !(x === T || modelmeta_or_nothing(x) === nothing ||
                   modelmeta(x).name == name && parentmodule(x) == parentmodule(T)), MODEL_LIST)
    push!(MODEL_LIST, T)
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

target_name(f::Field, owner) = f.related === :self ? string(nameof(owner)) :
                               f.related isa Type ? string(nameof(f.related)) : string(f.related)

function make_through_model(T::Type, m::ModelMeta, f::Field)
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
function m2m_relations(T::Type)
    out = Tuple{Symbol,Field,Bool}[]
    for f in modelmeta(T).m2m
        push!(out, (f.name, f, true))
    end
    for M in MODEL_LIST, f in modelmeta(M).m2m
        related_model(f) === T || continue
        push!(out, (f.related_name === nothing ? Symbol(lowercase(modelmeta(M).name), :_set) : f.related_name, f, false))
    end
    out
end
function find_m2m(T::Type, name)
    for r in m2m_relations(T)
        string(r[1]) == name && return r
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
        $(esc(structdef))
        $(esc(name))(; kwargs...) = $(GlobalRef(@__MODULE__, :construct))($(esc(name)); kwargs...)
        $(GlobalRef(@__MODULE__, :register_model!))($(esc(name)), Pair{Symbol,Any}[$(fieldpairs...)], $metaexpr)
        $(esc(name))
    end
end

function default_value(f::Field)
    d = f.default
    d isa NoDefault || return d isa Function || d isa Type ? d() : d
    f.null && return nothing
    f.kind in STRING_KINDS && return ""
    f.kind === :bool && return false
    nothing
end

function construct(::Type{T}; kwargs...) where {T<:Model}
    meta = modelmeta(T)
    obj = T(Dict{Symbol,Any}(:id => nothing), Dict{Symbol,Any}())
    data = getfield(obj, :_data)
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
    isempty(kw) || throw(ArgumentError("$T got unexpected field(s): $(join(keys(kw), ", "))"))
    obj
end

"Reverse FK relations pointing at model `T`: Vector of (name, Model, Field)."
function reverse_relations(T::Type)
    out = Tuple{Symbol,Any,Field}[]
    lin = lineage(T)
    for M in MODEL_LIST
        modelmeta(M).proxy && continue
        for f in modelmeta(M).fields
            f.kind === :fk || continue
            related_model(f) in lin || continue
            push!(out, (reverse_name(f), M, f))
        end
    end
    out
end

function Base.getproperty(m::Model, s::Symbol)
    data = getfield(m, :_data)
    v = get(data, s, NOTFOUND)
    v === NOTFOUND || return v
    s === :pk && return data[:id]
    s in (:_data, :_cache) && return getfield(m, s)
    T = typeof(m)
    f = findfield(modelmeta(T), s)
    if f !== nothing && f.kind === :fk
        id = data[attname(f)]
        id === nothing && return nothing
        cache = getfield(m, :_cache)
        c = get(cache, s, nothing)
        (c !== nothing && getfield(c, :_data)[:id] == id) && return c
        obj = get(base_objects(related_model(f)); id = id)
        cache[s] = obj
        return obj
    end
    cache = getfield(m, :_cache)
    pre = get(cache, s, NOTFOUND)
    g = find_generic(generic_fks(T), s)
    g === nothing || return get_generic(m, g)
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
        qs = filter(objects(M), Q(attname(rf) => data[:id]))
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
    r = tattr(m, Val(s))
    r === NOTFOUND || return r
    throw(ArgumentError("$(T) has no attribute '$s'"))
end

function Base.setproperty!(m::Model, s::Symbol, v)
    data = getfield(m, :_data)
    s === :pk && (s = :id)
    g = find_generic(generic_fks(typeof(m)), s)
    g === nothing || return set_generic!(m, g, v)
    f = findfield(modelmeta(typeof(m)), s)
    if f !== nothing && f.kind === :fk && s === f.name
        if v === nothing
            data[attname(f)] = nothing
            delete!(getfield(m, :_cache), s)
        elseif v isa Model
            data[attname(f)] = getfield(v, :_data)[:id]
            getfield(m, :_cache)[s] = v
        else
            data[attname(f)] = v
        end
        return v
    end
    (f !== nothing || s === :id) || throw(ArgumentError("$(typeof(m)) has no field '$s'"))
    data[s] = f === nothing ? v : coerce_value(f, v)
end

coerce_value(f::Field, v) = v
coerce_value(f::Field, v::SafeString) = v.s

function Base.propertynames(m::Model, private::Bool = false)
    names = Symbol[:id, :pk]
    for f in all_fields(typeof(m))
        push!(names, attname(f))
        f.kind === :fk && push!(names, f.name)
    end
    append!(names, [r[1] for r in reverse_relations(typeof(m)) if !startswith(string(r[1]), "+")])
    append!(names, first.(m2m_relations(typeof(m))))
    append!(names, child_accessor.(child_models(typeof(m))))
    append!(names, [g.name for g in vcat(generic_fks(typeof(m)), generic_relations(typeof(m)))])
    table_parent(typeof(m)) === nothing || push!(names, parent_accessor(typeof(m)))
    Tuple(names)
end

Base.:(==)(a::Model, b::Model) = typeof(a) === typeof(b) && a.id !== nothing && a.id == b.id
Base.hash(m::Model, h::UInt) = m.id === nothing ? objectid(m) ⊻ h : hash((typeof(m), m.id), h)
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
function tattr(m::Model, ::Val{:get_absolute_url})
    u = get_absolute_url(m)
    u === nothing ? NOTFOUND : u
end
tattr(m::Model, ::Val{:verbose_name}) = modelmeta(typeof(m)).verbose_name

# --- (de)serialisation ------------------------------------------------------------------

from_db(f::Field, ::Nothing) = nothing
function from_db(f::Field, v)
    r = from_db_extra(f, v)
    r === NOTFOUND || return r
    k = f.kind
    k === :fk && pk_kind(related_model(f)) === :uuid && return v isa UUID ? v : UUID(string(v))
    k === :bool && return v isa Bool ? v : v != 0
    k === :int && return v isa Integer ? Int(v) : parse(Int, string(v))
    k === :fk && return Int(v)
    k === :float && return Float64(v)
    k === :datetime && return v isa DateTime ? v : something(todatetime(v), v)
    k === :date && return v isa Date ? v : Date(todatetime(v))
    v isa AbstractString ? String(v) : v
end

to_db(f::Field, v::Model) = v.id      # (other values: see fields_extra.jl)

"Primary key kind of a model's table: `:auto` (integer identity) or `:uuid` (`Meta(pk = :uuid)`)."
function pk_kind(T::Type)
    A = concrete_model(T)
    while (P = table_parent(A)) !== nothing
        A = P
    end
    get(modelmeta(A).extra, :pk, :auto)
end
pk_value(T::Type, v) = (v === nothing || pk_kind(T) !== :uuid || v isa UUID) ? v : UUID(string(v))

"Parse a primary key from text (URLs, form values); `nothing` if it isn't one."
function parse_pk(T::Type, s)
    s isa Integer && return pk_kind(T) === :auto ? s : nothing
    s isa UUID && return s
    pk_kind(T) === :uuid ? tryparse(UUID, string(s)) : tryparse(Int, string(s))
end

function from_row(::Type{T}, row::Dict{Symbol,Any}) where {T<:Model}
    obj = T(Dict{Symbol,Any}(:id => pk_value(T, row[:id])), Dict{Symbol,Any}())
    data = getfield(obj, :_data)
    mytable = modelmeta(T).table
    for f in all_fields(T)
        t = modelmeta(f.model).table
        key = t == mytable ? attname(f) : Symbol("__", t, "__", column(f))   # inherited: labelled per table
        data[attname(f)] = from_db(f, get(row, key, nothing))
    end
    obj
end

# --- Q objects & lookups -------------------------------------------------------------------

"Supertype of query expressions (`F`, `Value`, aggregates, functions...). See expressions.jl."
abstract type Expression end

"""
    Q(; lookups...)

Composable query condition. Combine with `|`, `&` and negate with `!` (or `~`).

    filter(Post, Q(title__icontains="julia") | Q(body__icontains="julia"))
"""
struct Q
    connector::Symbol
    children::Vector{Any}
    negated::Bool
end
Q(; kw...) = Q(:AND, Any[k => v for (k, v) in kw], false)
Q(p::Pair) = Q(:AND, Any[Symbol(p.first) => p.second], false)
Base.:|(a::Q, b::Q) = Q(:OR, Any[a, b], false)
Base.:&(a::Q, b::Q) = Q(:AND, Any[a, b], false)
Base.:!(a::Q) = Q(a.connector, a.children, !a.negated)
Base.:~(a::Q) = !a

const LOOKUPS = Set(["exact", "iexact", "contains", "icontains", "startswith", "istartswith",
                     "endswith", "iendswith", "gt", "gte", "lt", "lte", "in", "isnull", "range",
                     "year", "month", "day", "ne", "contained_by", "overlap", "has_key", "has_keys",
                     "has_any_keys", "search"])


struct LookupError <: Exception
    msg::String
end
Base.showerror(io::IO, e::LookupError) = print(io, "FieldError: ", e.msg)

# --- SQL compilation -----------------------------------------------------------------------
#
# A query compiles to `SELECT ... FROM base [JOIN ...] WHERE ...`. Lookups across relations
# (`author__name`, reverse `comment__body`) become JOINs:
#
# * Forward FKs: INNER JOIN when the FK is NOT NULL (every row has a match), LEFT OUTER JOIN
#   when it is nullable or hangs off a LEFT JOIN. One join per path, reused by the whole query.
# * Reverse FKs: LEFT OUTER JOIN, and the query becomes SELECT DISTINCT. As in Django,
#   conditions inside one filter() call share the join (one related row must satisfy all of
#   them) while separate filter() calls join again (each may be satisfied by a different row).
# * Under negation (`exclude`, `!Q`) relations compile to correlated EXISTS subqueries, so
#   `exclude(author__name="Ann")` keeps posts that have no author at all.
# * `rel__isnull` on a reverse relation is an EXISTS test (no join needed).

mutable struct SQLCompiler
    T::Type
    table::String               # the base table
    base::String                # its alias (the table name itself at top level)
    joins::Vector{String}
    aliases::Dict{Any,String}   # (parent alias, relation, scope) => alias
    leftjoined::Set{String}
    counter::Base.RefValue{Int}
    distinct::Bool
    scope::Any                  # filter() call index; :expr inside aggregates and Case conditions
    annotations::Dict{Symbol,Any}
    uses_aggregate::Bool        # set when a condition refers to an aggregate annotation (-> HAVING)
    outer::Union{Nothing,SQLCompiler}   # the enclosing query, for OuterRef
end
function SQLCompiler(T::Type; outer = nothing)
    table = modelmeta(T).table
    counter = outer === nothing ? Ref(0) : outer.counter
    c = SQLCompiler(T, table, table, String[], Dict{Any,String}(), Set{String}(), counter, false, 0,
                    Dict{Symbol,Any}(), false, outer)
    outer === nothing || (c.base = new_alias!(c))   # subqueries alias their table: no clash with the outer one
    c
end

new_alias!(c::SQLCompiler) = (c.counter[] += 1; "j$(c.counter[])")
qcol(alias, col) = qname(alias) * "." * qname(col)

"Join `table` (as a new alias) to `parent` on child.`childcol` = parent.`parentcol`; reuse an existing join for `key`."
function join!(c::SQLCompiler, parent, key, table, childcol, parentcol; left::Bool, extra_on = nothing)
    haskey(c.aliases, key) && return c.aliases[key]
    a = new_alias!(c)
    left = left || parent in c.leftjoined
    left && push!(c.leftjoined, a)
    on = "$(qcol(a, childcol)) = $(qcol(parent, parentcol))" * (extra_on === nothing ? "" : " AND " * extra_on(a))
    push!(c.joins, " $(left ? "LEFT OUTER" : "INNER") JOIN $(qname(table)) $(qname(a)) ON $on")
    c.aliases[key] = a
end

"""
Alias of the table holding field `f` when querying `T` at `alias`: `alias` itself, or a
join up the multi-table inheritance chain.
"""
function field_alias!(c::SQLCompiler, alias, T::Type, f::Field)
    target = modelmeta(f.model).table
    A = concrete_model(T)
    while modelmeta(A).table != target
        P = table_parent(A)
        P === nothing && error("field $(f.name) does not belong to $T")
        alias = join!(c, alias, (alias, :__parent), modelmeta(P).table, "id", "id"; left = alias in c.leftjoined)
        A = P
    end
    alias
end

function find_reverse(T::Type, name)
    for (rn, M, rf) in reverse_relations(T)
        (string(rn) == name || !startswith(string(rn), "+") && lowercase(modelmeta(M).name) == name) && return (rn, M, rf)
    end
    nothing
end

function lookup_error(T, fname)
    meta = modelmeta(T)
    names = join(vcat(["id"], [string(x.name) for x in meta.fields], [string(r[1]) for r in reverse_relations(T)]), ", ")
    LookupError("cannot resolve keyword '$fname' into a field of $T. Choices are: $names")
end

"Compile one `field__path__lookup = value` against model `T` whose table is reachable as `alias`."
function compile_lookup(c::SQLCompiler, alias, T::Type, key, value, negated::Bool)
    parts = split(string(key), "__")
    lookup = "exact"
    (length(parts) > 1 && parts[end] in LOOKUPS) && (lookup = String(pop!(parts)))
    meta = modelmeta(T)
    fname = parts[1] == "pk" ? "id" : String(parts[1])
    rest = String.(parts[2:end])
    f = nothing
    colps = Any[]
    if alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname))
        a = c.annotations[Symbol(fname)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, colps = compile_expr(c, a)
        col = "($sql)"
    elseif fname == "id"
        isempty(rest) || throw(LookupError("'id' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        col = qcol(alias, "id")
    else
        f = findfield(meta, Symbol(fname))
        if f === nothing && (mm = find_m2m(T, fname)) !== nothing
            # tags__name on Post -> through the join model: +post_tags_src__tag__name
            step1, step2 = m2m_path(mm[2], mm[3])
            if isempty(rest) && lookup == "isnull"
                return compile_lookup(c, alias, T, string(step1, "__isnull"), value, negated)
            end
            return compile_lookup(c, alias, T, join(vcat([string(step1), string(step2)], rest, [lookup]), "__"), value, negated)
        end
        if f === nothing && (C = findfirst(C -> string(child_accessor(C)) == fname, child_models(T))) !== nothing
            # place -> restaurant (multi-table child): one-to-one join on id
            Cm = child_models(T)[C]
            ct = qname(modelmeta(Cm).table)
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $ct $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, "id")))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, Cm, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $ct $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, "id")) AND $sql)", ps)
            end
            a = join!(c, alias, (alias, child_accessor(Cm)), modelmeta(Cm).table, "id", "id"; left = true)
            return compile_lookup(c, a, Cm, subkey, value, negated)
        end
        if f === nothing && (g = find_generic(generic_relations(T), fname)) !== nothing
            # post.comments (GenericRelation): join on object id AND content type
            M = related_model(g)
            ctf, fkf = g.through
            ctcol, fkcol = column(getfield_meta(M, ctf)), column(getfield_meta(M, fkf))
            ctid = get_for_model(T).id::Integer
            mt = qname(modelmeta(M).table)
            cond(a) = "$(qcol(a, fkcol)) = $(qcol(alias, "id")) AND $(qcol(a, ctcol)) = $ctid"
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)) AND $sql)", ps)
            end
            a = join!(c, alias, (alias, g.name, c.scope), modelmeta(M).table, fkcol, "id"; left = true,
                      extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            c.distinct = true
            return compile_lookup(c, a, M, subkey, value, negated)
        end
        if f !== nothing && modelmeta(f.model).table != modelmeta(T).table
            # a field inherited from a multi-table parent: look it up on the parent's table
            P = table_parent(T)
            a = join!(c, alias, (alias, :__parent), modelmeta(P).table, "id", "id"; left = alias in c.leftjoined)
            return compile_lookup(c, a, P, key, value, negated)
        end
        if f === nothing
            rel = find_reverse(T, fname)
            rel === nothing && throw(lookup_error(T, fname))
            rn, M, rf = rel
            mt = qname(modelmeta(M).table)
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, "id")))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, "id")) AND $sql)", ps)
            end
            a = join!(c, alias, (alias, rn, c.scope), modelmeta(M).table, column(rf), "id"; left = true)
            c.distinct = true
            return compile_lookup(c, a, M, subkey, value, negated)
        end
        if !isempty(rest) && f.kind in (:json, :array)
            # data__owner__name (JSON key path), tags__len, tags__0
            tr = transform_column(f, qcol(alias, column(f)), rest, lookup, value)
            tr === nothing && throw(LookupError("unsupported lookup '$(join(rest, "__"))' on $(f.kind) field '$fname'"))
            col, colps = tr
            lookup == "isnull" && f.kind === :json && return truthy(value) ? (col, colps) : ("NOT " * col, colps)
            f = nothing
        elseif !isempty(rest)
            f.kind === :fk || throw(LookupError("'$fname' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
            if rest in (["id"], ["pk"])
                col = qcol(alias, column(f))     # author__id is just author_id: no join
            else
                R = related_model(f)
                subkey = join(vcat(rest, lookup), "__")
                if negated
                    a = new_alias!(c)
                    sql, ps = compile_lookup(c, a, R, subkey, value, negated)
                    return ("EXISTS (SELECT 1 FROM $(qname(modelmeta(R).table)) $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, column(f))) AND $sql)", ps)
                end
                a = join!(c, alias, (alias, f.name), modelmeta(R).table, "id", column(f); left = f.null)
                return compile_lookup(c, a, R, subkey, value, negated)
            end
        else
            col = qcol(alias, column(f))
        end
    end
    conv(v) = v isa Model ? v.id : (f === nothing || f.kind === :fk ? dbparam(v) : to_db(f, v))
    if f !== nothing || lookup == "search"
        sl = special_lookup(c, something(f, Field(:text)), col, lookup, value)
        sl === nothing || return sl[1], vcat(colps, sl[2])
    end
    sql, ps = lookup_condition(c, col, lookup, value, conv)
    sql, isempty(colps) ? ps : vcat(colps, ps)
end

function lookup_condition(c::SQLCompiler, col, lookup, value, conv)
    if value isa SearchQuery && lookup == "exact"
        q, qps = compile_expr(c, value)
        return "$col @@ $q", qps
    end
    if value isa Expression && lookup in ("exact", "ne", "gt", "gte", "lt", "lte", "iexact")
        vsql, vps = compile_expr(c, value)
        op = Dict("exact" => "=", "ne" => "!=", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")
        lookup == "iexact" && return ("LOWER($col) = LOWER($vsql)", vps)
        return ("$col $(op[lookup]) ($vsql)", vps)
    end
    if lookup == "exact"
        value === nothing && return ("$col IS NULL", Any[])
        return ("$col = ?", Any[conv(value)])
    elseif lookup == "ne"
        value === nothing && return ("$col IS NOT NULL", Any[])
        return ("($col != ? OR $col IS NULL)", Any[conv(value)])
    elseif lookup in ("iexact", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith")
        return lookup_sql(backend(), Val(Symbol(lookup)), col, value)
    elseif lookup in ("gt", "gte", "lt", "lte")
        op = Dict("gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")[lookup]
        return ("$col $op ?", Any[conv(value)])
    elseif lookup == "in"
        if value isa QuerySet
            sql, ps = value.values_fields === nothing ? subquery_sql(c, value; columns = nothing, idonly = true) :
                      subquery_sql(c, value)
            return ("$col IN ($sql)", ps)
        elseif value isa Subquery
            sql, ps = compile_expr(c, value)
            return ("$col IN $sql", ps)
        end
        vals = collect(value)
        isempty(vals) && return (sql_false(backend()), Any[])
        return ("$col IN (" * join(fill("?", length(vals)), ", ") * ")", Any[conv(v) for v in vals])
    elseif lookup == "isnull"
        return (truthy(value) ? "$col IS NULL" : "$col IS NOT NULL", Any[])
    elseif lookup == "range"
        lo, hi = value
        return ("$col BETWEEN ? AND ?", Any[conv(lo), conv(hi)])
    elseif lookup in ("year", "month", "day")
        return lookup_sql(backend(), Val(Symbol(lookup)), col, value)
    end
    throw(LookupError("unsupported lookup '$lookup'"))
end

function compile_q(c::SQLCompiler, alias, T::Type, q::Q, negated::Bool)
    neg = negated ⊻ q.negated
    parts = String[]
    params = Any[]
    for ch in q.children
        sql, ps = ch isa Q ? compile_q(c, alias, T, ch, neg) :
                  ch isa Expression ? compile_expr(c, ch) :
                  compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
        push!(parts, sql)
        append!(params, ps)
    end
    sql = isempty(parts) ? sql_true(backend()) : "(" * join(parts, q.connector === :OR ? " OR " : " AND ") * ")"
    q.negated ? "NOT $sql" : sql, params
end

"""
    Prefetch(lookup; queryset=nothing, to_attr=nothing)

A `prefetch_related` lookup with a custom queryset for the related objects, optionally
stored under another attribute name (as a plain `Vector`).
"""
struct Prefetch
    path::String
    queryset::Any
    to_attr::Union{Nothing,Symbol}
end
Prefetch(path; queryset = nothing, to_attr = nothing) =
    Prefetch(string(path), queryset, to_attr === nothing ? nothing : Symbol(to_attr))

"Related objects fetched by `prefetch_related`, kept in an instance's cache."
struct PrefetchedList
    items::Vector
end

# --- QuerySet --------------------------------------------------------------------------

"""
Lazy, chainable database query. Created by `objects(Model)` / `filter(Model; ...)`.
Iterate it, `collect` it, index it (`qs[1]`, `qs[1:10]`), or call `count`,
`first`, `exists`, `values`, `update!`, `delete!` on it.
"""
struct QuerySet{T<:Model}
    where::Vector{Q}                    # one entry per filter()/exclude() call
    order::Vector{String}
    limit::Union{Nothing,Int}
    offset::Int
    isnone::Bool
    related::Vector{Vector{Symbol}}     # select_related paths
    prefetch::Vector{Prefetch}          # prefetch_related lookups
    cache::Union{Nothing,Vector}        # results already known (prefetched relations)
    owner::Any                          # many-to-many context for add!/remove!/set!/clear!
    annotations::Vector{Pair{Symbol,Any}}
    values_fields::Union{Nothing,Vector{String}}   # values() mode: rows are Dicts
    group_by_object::Bool                          # values() after an aggregate annotate: still one row per object
end
QuerySet{T}(where, order, limit, offset, isnone) where {T} =
    QuerySet{T}(where, order, limit, offset, isnone, Vector{Symbol}[], Prefetch[], nothing, nothing,
                Pair{Symbol,Any}[], nothing, false)

model_of(::QuerySet{T}) where {T} = T

"""
    objects(Model) -> QuerySet

All objects of a model through its default queryset, `default_queryset(Model)`.
`objects(Model, :name)` returns a named queryset defined with `Juango.manager`.
"""
objects(::Type{T}) where {T<:Model} = default_queryset(T)

"""
    base_objects(Model) -> QuerySet

Every row of the table, ignoring `default_queryset`. Foreign-key access, cascading
deletes and uniqueness checks use this, like Django's base manager.
"""
base_objects(::Type{T}) where {T<:Model} = QuerySet{T}(Q[], String[], nothing, 0, false)

"""
    default_queryset(::Type{Model})

Override to change what `objects(Model)`, `filter(Model; ...)`, the admin and reverse
relations see, for example to hide soft-deleted rows. Build on `base_objects`:

    Juango.default_queryset(::Type{Post}) = filter(base_objects(Post); deleted = false)
"""
default_queryset(::Type{T}) where {T<:Model} = base_objects(T)

"""
    manager(::Type{Model}, ::Val{name})

Define a named queryset, available as `objects(Model, :name)`:

    Juango.manager(::Type{Post}, ::Val{:published}) = filter(Post; status = "p")
"""
manager(::Type{T}, ::Val{N}) where {T,N} = throw(ArgumentError("$T has no manager named :$N (define Juango.manager(::Type{$T}, ::Val{:$N}))"))
objects(::Type{T}, name::Symbol) where {T<:Model} = manager(T, Val(name))
"An empty queryset."
none(::Type{T}) where {T<:Model} = QuerySet{T}(Q[], String[], nothing, 0, true)
none(qs::QuerySet{T}) where {T} = none(T)

"""
A new queryset with some parts replaced. Cached results and the many-to-many context
never carry over (unless passed explicitly).
"""
function chain(qs::QuerySet{T}; kw...) where {T}
    vals = [haskey(kw, f) ? kw[f] : f in (:cache, :owner) ? nothing : getfield(qs, f) for f in fieldnames(QuerySet{T})]
    QuerySet{T}(vals...)
end

"""
    select_related(qs, :author, :author__profile)

Fetch the objects behind forward foreign keys in the same query (with JOINs), so
`post.author` needs no extra query. Paths follow FKs with `__`.
"""
function select_related(qs::QuerySet{T}, paths...) where {T}
    rel = copy(qs.related)
    for p in paths
        segs = Symbol.(split(string(p), "__"))
        M = T
        for s in segs
            f = findfield(modelmeta(M), s)
            (f !== nothing && f.kind === :fk && f.name === s) ||
                throw(LookupError("select_related: '$s' is not a foreign key of $M (use prefetch_related for reverse relations)"))
            M = related_model(f)
        end
        segs in rel || push!(rel, segs)
    end
    chain(qs; related = rel)
end
select_related(::Type{T}, paths...) where {T<:Model} = select_related(objects(T), paths...)
select_related(paths::Union{AbstractString,Symbol}...) = qs -> select_related(qs, paths...)

"""
    prefetch_related(qs, :comment_set, :author, Prefetch(:comments; queryset=..., to_attr=:approved))

After fetching, load related objects with one extra query per lookup: reverse relations
(`author.post_set`, `post.comments`) and forward FKs. `__` follows relations further
(`:comments__author`). Prefetched reverse relations answer `count`, iteration, `first`
and `exists` from memory; further filtering queries the database again.
"""
prefetch_related(qs::QuerySet, lookups...) =
    chain(qs; prefetch = vcat(qs.prefetch, Prefetch[l isa Prefetch ? l : Prefetch(l) for l in lookups]))
prefetch_related(::Type{T}, lookups...) where {T<:Model} = prefetch_related(objects(T), lookups...)
prefetch_related(lookups::Union{AbstractString,Symbol,Prefetch}...) = qs -> prefetch_related(qs, lookups...)

function assert_unsliced(qs::QuerySet, what)
    (qs.limit === nothing && qs.offset == 0) || error("cannot $what a queryset once it has been sliced")
end

"""
    filter(qs_or_Model, q::Q...; lookups...)

Keep rows matching all lookups (`field`, `field__lookup`, `fk__field__lookup`).
Lookups: exact iexact contains icontains startswith istartswith endswith
iendswith gt gte lt lte in isnull range year month day ne.
"""
function Base.filter(qs::QuerySet{T}, qargs::Union{Q,Expression}...; kw...) where {T}
    assert_unsliced(qs, "filter")
    (isempty(qargs) && isempty(kw)) && return chain(qs)
    w = copy(qs.where)
    push!(w, Q(:AND, Any[qargs..., (k => v for (k, v) in kw)...], false))
    chain(qs; where = w)
end
Base.filter(::Type{T}, qargs::Union{Q,Expression}...; kw...) where {T<:Model} = filter(objects(T), qargs...; kw...)
Base.filter(qargs::Union{Q,Expression}...; kw...) = qs -> filter(qs, qargs...; kw...)

"Exclude rows matching the lookups."
function exclude(qs::QuerySet{T}, qargs::Union{Q,Expression}...; kw...) where {T}
    assert_unsliced(qs, "exclude")
    (isempty(qargs) && isempty(kw)) && return chain(qs)
    w = copy(qs.where)
    push!(w, Q(:AND, Any[qargs..., (k => v for (k, v) in kw)...], true))
    chain(qs; where = w)
end
exclude(::Type{T}, qargs::Q...; kw...) where {T<:Model} = exclude(objects(T), qargs...; kw...)

"""
    order_by(qs, "field", "-other", ...)
    qs |> order_by("-created")

Order the results. Prefix with `-` for descending, `\"?\"` for random order.
"""
order_by(qs::QuerySet, fields...) = chain(qs; order = String[string(f) for f in fields])
order_by(::Type{T}, fields...) where {T<:Model} = order_by(objects(T), fields...)
order_by(fields::Union{AbstractString,Symbol}...) = qs -> order_by(qs, fields...)

"ORDER BY clause plus extra SELECT columns (needed with DISTINCT when ordering by joined columns)."
function order_clause(c::SQLCompiler, order::Vector{String})
    T = c.T
    isempty(order) && (order = modelmeta(T).ordering)
    isempty(order) && return "", String[]
    parts, extra = String[], String[]
    for o in order
        o == "?" && (push!(parts, random_function(backend())); continue)
        desc = startswith(o, "-")
        if haskey(c.annotations, Symbol(lstrip(o, '-')))
            push!(parts, qname(lstrip(o, '-')) * (desc ? " DESC" : " ASC"))
            continue
        end
        segs = split(lstrip(o, '-'), "__")
        alias, M = c.base, T
        for s in segs[1:end-1]     # follow forward FKs: order_by("author__name")
            f = findfield(modelmeta(M), Symbol(s))
            (f !== nothing && f.kind === :fk) || throw(LookupError("cannot order $T by '$o': '$s' is not a foreign key of $M"))
            alias = field_alias!(c, alias, M, f)
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = true)
            M = related_model(f)
        end
        name = segs[end]
        col = if name in ("id", "pk")
            qcol(alias, "id")
        else
            f = findfield(modelmeta(M), Symbol(name))
            f === nothing && throw(LookupError("cannot order $T by unknown field '$o'"))
            alias = field_alias!(c, alias, M, f)
            qcol(alias, column(f))
        end
        if alias != c.base && c.distinct
            push!(extra, "$col AS $(qname("__order$(length(extra) + 1)"))")
        end
        push!(parts, col * (desc ? " DESC" : " ASC"))
    end
    " ORDER BY " * join(parts, ", "), extra
end

function where_clause(c::SQLCompiler, qs::QuerySet)
    qs.isnone && return " WHERE " * sql_false(backend()), Any[]
    isempty(qs.where) && return "", Any[]
    parts, ps = String[], Any[]
    for (i, q) in enumerate(qs.where)
        c.scope = i
        sql, p = compile_q(c, c.base, c.T, q, false)
        push!(parts, sql)
        append!(ps, p)
    end
    c.scope = 0
    " WHERE " * join(parts, " AND "), ps
end

"Joins and aliased columns for `select_related`; returns (path, model, alias) per related object."
function related_columns!(c::SQLCompiler, paths)
    out = Tuple{Vector{Symbol},Any,String}[]
    cols = String[]
    for path in sort(paths; by = length)
        alias, M = c.base, c.T
        for (i, s) in enumerate(path)
            f = findfield(modelmeta(M), s)
            alias = field_alias!(c, alias, M, f)
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = f.null)
            M = related_model(f)
            isempty(ancestors(M)) || throw(LookupError("select_related can't load $M, which inherits from another table; use prefetch_related"))
            sub = path[1:i]
            any(x -> x[1] == sub, out) && continue
            push!(out, (sub, M, alias))
            push!(cols, "$(qcol(alias, "id")) AS $(qname(alias * "__id"))")
            for g in modelmeta(M).fields
                push!(cols, "$(qcol(alias, column(g))) AS $(qname(alias * "__" * column(g)))")
            end
        end
    end
    out, cols
end

"""
    build_select(qs; columns=nothing, ordered=true, outer=nothing) -> (sql, params, compiler, related)

The SELECT for a queryset. `columns` replaces the default select list (`table.*`, plus
`select_related` columns and annotations). `outer` is the enclosing query's compiler when
this is a subquery (for `OuterRef`).
"""
function build_select(qs::QuerySet{T}; columns = nothing, ordered = true, outer = nothing, idonly = false) where {T}
    c = SQLCompiler(T; outer = outer)
    for (k, v) in qs.annotations
        c.annotations[k] = v
    end
    grouped = any(p -> contains_aggregate(p.second), qs.annotations)
    # select list first: it may add joins, and its parameters come first in the SQL
    sel, sel_ps = String[], Any[]
    related = Tuple{Vector{Symbol},Any,String}[]
    group = String[]
    if idonly
        push!(sel, qcol(c.base, "id"))
    elseif columns !== nothing
        push!(sel, columns)
    elseif qs.values_fields !== nothing
        for f in qs.values_fields
            if haskey(c.annotations, Symbol(f))
                continue
            end
            col, _ = resolve_path(c, c.base, T, f)
            push!(sel, "$col AS $(qname(f))")
            push!(group, col)
        end
        qs.group_by_object && pushfirst!(group, qcol(c.base, "id"))
    else
        push!(sel, qname(c.base) * ".*")
        let alias = c.base, A = concrete_model(T)
            while (P = table_parent(A)) !== nothing        # multi-table parents' columns
                alias = join!(c, alias, (alias, :__parent), modelmeta(P).table, "id", "id"; left = false)
                pt = modelmeta(P).table
                for g in modelmeta(P).fields
                    push!(sel, "$(qcol(alias, column(g))) AS $(qname("__" * pt * "__" * column(g)))")
                end
                A = P
            end
        end
        related, rcols = related_columns!(c, qs.related)
        append!(sel, rcols)
        push!(group, qcol(c.base, "id"))
        append!(group, [qcol(a, "id") for (_, _, a) in related])
    end
    if columns === nothing && !idonly
        for (k, v) in qs.annotations
            sql, p = compile_expr(c, v)
            push!(sel, "$sql AS $(qname(string(k)))")
            append!(sel_ps, p)
        end
    end
    # WHERE, or HAVING for conditions on aggregate annotations
    wparts, wps, hparts, hps = String[], Any[], String[], Any[]
    if qs.isnone
        push!(wparts, sql_false(backend()))
    else
        for (i, q) in enumerate(qs.where)
            c.scope = i
            c.uses_aggregate = false
            sql, p = compile_q(c, c.base, T, q, false)
            if c.uses_aggregate
                push!(hparts, sql); append!(hps, p)
            else
                push!(wparts, sql); append!(wps, p)
            end
        end
        c.scope = 0
    end
    if grouped && columns !== nothing && !idonly && qs.values_fields === nothing
        group = [qcol(c.base, "id")]
    end
    o, extra = ordered ? order_clause(c, qs.order) : ("", String[])
    (columns === nothing && !idonly && !grouped) && append!(sel, extra)
    distinct = c.distinct && !grouped
    sql = "SELECT $(distinct ? "DISTINCT " : "")$(join(sel, ", ")) FROM $(qname(c.table))" *
          (c.base == c.table ? "" : " " * qname(c.base)) * join(c.joins) *
          (isempty(wparts) ? "" : " WHERE " * join(wparts, " AND ")) *
          (grouped && !isempty(group) ? " GROUP BY " * join(unique(group), ", ") : "") *
          (isempty(hparts) ? "" : " HAVING " * join(hparts, " AND ")) *
          o * limit_offset_sql(backend(), qs.limit, qs.offset)
    sql, vcat(sel_ps, wps, hps), c, related
end

"Is the queryset grouped (aggregate annotations) or in values mode? Then counting wraps the full query."
needs_wrapping(qs::QuerySet) = qs.values_fields !== nothing || any(p -> contains_aggregate(p.second), qs.annotations)

function select_sql(qs::QuerySet; columns = nothing, ordered = true)
    sql, ps, _, _ = build_select(qs; columns = columns, ordered = ordered)
    sql, ps
end

"Build a model from columns labelled `prefix*column` (as produced for `select_related`)."
function from_prefixed_row(::Type{T}, row, prefix) where {T<:Model}
    id = get(row, Symbol(prefix, "id"), nothing)
    id === nothing && return nothing
    obj = T(Dict{Symbol,Any}(:id => pk_value(T, id)), Dict{Symbol,Any}())
    data = getfield(obj, :_data)
    for f in modelmeta(T).fields
        data[attname(f)] = from_db(f, get(row, Symbol(prefix, column(f)), nothing))
    end
    obj
end

"Execute the query and return a `Vector` of model instances."
function fetch(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return Vector{T}(qs.cache)
    qs.values_fields === nothing || return fetch_values(qs)
    qs.isnone && return T[]
    sql, ps, _, related = build_select(qs)
    rows = execute(sql, ps)
    objs = T[from_row(T, r) for r in rows]
    for (k, _) in qs.annotations, (o, r) in zip(objs, rows)
        getfield(o, :_data)[k] = get(r, k, nothing)
    end
    if !isempty(related)
        for (obj, row) in zip(objs, rows)
            for (path, M, alias) in related
                parent = obj
                for s in path[1:end-1]
                    parent = get(getfield(parent, :_cache), s, nothing)
                    parent === nothing && break
                end
                parent === nothing && continue
                r = from_prefixed_row(M, row, alias * "__")
                r === nothing || (getfield(parent, :_cache)[path[end]] = r)
            end
        end
    end
    for p in qs.prefetch
        do_prefetch!(objs, p)
    end
    objs
end

"Rows of a `values()` queryset, with column values converted like model fields."
function fetch_values(qs::QuerySet{T}) where {T}
    qs.isnone && return Dict{Symbol,Any}[]
    sql, ps, c, _ = build_select(qs)
    convs = Dict{Symbol,Any}()
    for f in qs.values_fields
        haskey(c.annotations, Symbol(f)) && continue
        _, fld = resolve_path(SQLCompiler(T), modelmeta(T).table, T, f)
        fld === nothing || (convs[Symbol(f)] = fld)
    end
    out = Dict{Symbol,Any}[]
    for r in execute(sql, ps)
        d = Dict{Symbol,Any}()
        for f in qs.values_fields
            k = Symbol(f)
            v = get(r, k, nothing)
            d[k] = haskey(convs, k) ? from_db(convs[k], v) : v
        end
        for (k, _) in qs.annotations
            d[k] = get(r, k, nothing)
        end
        push!(out, d)
    end
    out
end

function do_prefetch!(objs::Vector, p::Prefetch)
    segs = Symbol.(split(p.path, "__"))
    level = objs
    for (i, s) in enumerate(segs)
        last_ = i == length(segs)
        level = prefetch_level!(level, s, last_ ? p.queryset : nothing, last_ ? p.to_attr : nothing)
    end
    nothing
end

"Load relation `name` for all `objs` with one query; return the related objects."
function prefetch_level!(objs::Vector, name::Symbol, qs, to_attr)
    isempty(objs) && return Any[]
    T = typeof(first(objs))
    f = findfield(modelmeta(T), name)
    if f !== nothing && f.kind === :fk && f.name === name
        R = related_model(f)
        ids = unique([getfield(o, :_data)[attname(f)] for o in objs if getfield(o, :_data)[attname(f)] !== nothing])
        rel = isempty(ids) ? R[] : fetch(filter(something(qs, base_objects(R)); id__in = ids))
        byid = Dict(r.id => r for r in rel)
        for o in objs
            id = getfield(o, :_data)[attname(f)]
            r = id === nothing ? nothing : get(byid, id, nothing)
            if to_attr !== nothing
                getfield(o, :_cache)[to_attr] = r
            elseif r !== nothing
                getfield(o, :_cache)[name] = r
            end
        end
        return rel
    end
    mm = find_m2m(T, string(name))
    mm === nothing || return prefetch_m2m!(objs, mm[1], mm[2], mm[3], qs, to_attr)
    g = find_generic(generic_fks(T), name)
    g === nothing || return prefetch_generic_fk!(objs, g)
    g = find_generic(generic_relations(T), name)
    g === nothing || return prefetch_generic_relation!(objs, g, qs, to_attr)
    rel = find_reverse(T, string(name))
    rel === nothing && throw(LookupError("prefetch_related: '$name' is not a relation of $T"))
    rn, M, rf = rel
    ids = [o.id for o in objs]
    rows = fetch(filter(something(qs, objects(M)), Q(Symbol(attname(rf), "__in") => ids)))
    groups = Dict{Any,Vector{M}}()
    for r in rows
        push!(get!(() -> M[], groups, getfield(r, :_data)[attname(rf)]), r)
    end
    for o in objs
        getfield(o, :_cache)[something(to_attr, rn)] = PrefetchedList(get(groups, o.id, M[]))
    end
    rows
end

Base.collect(qs::QuerySet) = fetch(qs)
Base.eltype(::Type{QuerySet{T}}) where {T} = T
Base.IteratorSize(::Type{<:QuerySet}) = Base.SizeUnknown()
function Base.iterate(qs::QuerySet)
    v = fetch(qs)
    r = iterate(v)
    r === nothing ? nothing : (r[1], (v, r[2]))
end
function Base.iterate(::QuerySet, st)
    r = iterate(st[1], st[2])
    r === nothing ? nothing : (r[1], (st[1], r[2]))
end

"Number of matching rows (a `SELECT COUNT(*)`)."
function Base.count(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return length(qs.cache)
    qs.isnone && return 0
    sql, ps = needs_wrapping(qs) ? select_sql(qs; ordered = false) : select_sql(qs; columns = qcol(modelmeta(T).table, "id"), ordered = false)
    execute("SELECT COUNT(*) AS n FROM ($sql) AS juango_sub", ps)[1][:n]
end
Base.count(::Type{T}) where {T<:Model} = count(objects(T))
Base.length(qs::QuerySet) = count(qs)

"Whether any row matches."
function exists(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return !isempty(qs.cache)
    qs.isnone && return false
    sql, ps = select_sql(chain(qs; limit = 1); columns = "1", ordered = false)
    !isempty(execute(sql, ps))
end
Base.isempty(qs::QuerySet) = !exists(qs)
truthy(qs::QuerySet) = exists(qs)

function Base.getindex(qs::QuerySet, r::AbstractUnitRange{<:Integer})
    first(r) >= 1 || throw(ArgumentError("queryset slices are 1-based"))
    n = length(r)
    qs.limit !== nothing && (n = max(0, min(n, qs.limit - (first(r) - 1))))
    chain(qs; offset = qs.offset + first(r) - 1, limit = n)
end
function Base.getindex(qs::QuerySet, i::Integer)
    qs.cache === nothing || return qs.cache[i]
    v = fetch(qs[i:i])
    isempty(v) && throw(BoundsError(qs, i))
    v[1]
end

default_order(qs::QuerySet{T}) where {T} = isempty(qs.order) ? (isempty(modelmeta(T).ordering) ? ["id"] : modelmeta(T).ordering) : qs.order

"First object (by the queryset's ordering, or by id), or `nothing`."
function Base.first(qs::QuerySet)
    qs.cache === nothing || return isempty(qs.cache) ? nothing : qs.cache[1]
    v = fetch(chain(qs[1:1]; order = default_order(qs)))
    isempty(v) ? nothing : v[1]
end
"Last object, or `nothing`."
function Base.last(qs::QuerySet)
    assert_unsliced(qs, "take last of")
    flipped = [startswith(o, "-") ? o[2:end] : "-" * o for o in default_order(qs)]
    first(chain(qs; order = flipped))
end
Base.first(::Type{T}) where {T<:Model} = first(objects(T))
Base.last(::Type{T}) where {T<:Model} = last(objects(T))

struct DoesNotExist <: Exception
    model::Any
    lookup::String
end
Base.showerror(io::IO, e::DoesNotExist) = print(io, nameof(e.model), ".DoesNotExist: no object matches ", e.lookup)
struct MultipleObjectsReturned <: Exception
    model::Any
    lookup::String
end
Base.showerror(io::IO, e::MultipleObjectsReturned) = print(io, nameof(e.model), ".MultipleObjectsReturned: more than one object matches ", e.lookup)

"""
    get(qs_or_Model; lookups...)

Exactly one matching object. Throws `DoesNotExist` or `MultipleObjectsReturned`.
"""
function Base.get(qs::QuerySet{T}, qargs::Q...; kw...) where {T}
    q = filter(qs, qargs...; kw...)
    v = fetch(chain(q; limit = 2))
    desc = join(["$k=$(repr(v))" for (k, v) in kw], ", ")
    isempty(v) && throw(DoesNotExist(T, desc))
    length(v) > 1 && throw(MultipleObjectsReturned(T, desc))
    v[1]
end
Base.get(::Type{T}, qargs::Q...; kw...) where {T<:Model} = get(objects(T), qargs...; kw...)

"""
    update!(qs; field=value, ...) -> Int

Bulk SQL UPDATE of all matching rows; returns the number of rows changed.
Does not call `save!` or touch `auto_now` fields.
"""
function update!(qs::QuerySet{T}; kw...) where {T}
    qs.isnone && return 0
    meta = modelmeta(T)
    sets, ps = String[], Any[]
    mytable = modelmeta(T).table
    if any(k -> modelmeta(getfield_meta(T, k).model).table != mytable, keys(kw))
        # fields live in several tables (multi-table inheritance): one UPDATE per table, same ids
        ids = values_list(qs, :id; flat = true)
        n = 0
        for M in vcat([concrete_model(T)], ancestors(T))
            mine = [k => v for (k, v) in kw if modelmeta(getfield_meta(T, k).model).table == modelmeta(M).table]
            isempty(mine) && continue
            n = max(n, update!(filter(base_objects(M); id__in = ids); mine...))
        end
        return n
    end
    c = SQLCompiler(T)
    for (k, v) in kw
        f = getfield_meta(T, k)
        if v isa Expression
            sql, p = compile_expr(c, v)
            isempty(c.joins) || throw(ArgumentError("update!: expressions can only use the model's own fields"))
            push!(sets, qname(column(f)) * " = " * sql)
            append!(ps, p)
        else
            push!(sets, qname(column(f)) * " = ?")
            push!(ps, to_db(f, v))
        end
    end
    isempty(sets) && return 0
    sub, sps = select_sql(qs; columns = qcol(meta.table, "id"), ordered = false)
    execute_changes("UPDATE $(qname(meta.table)) SET $(join(sets, ", ")) WHERE $(qname("id")) IN ($sub)", vcat(ps, sps))
end

struct ProtectedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ProtectedError) = print(io, "ProtectedError: ", e.msg)

function delete_ids!(T::Type, ids::Vector)
    isempty(ids) && return 0
    T = concrete_model(T)
    for g in generic_relations(T)    # objects pointing here through a GenericForeignKey
        M = related_model(g)
        ctf, fkf = g.through
        rel = filter(base_objects(M), Q(Symbol(ctf, :_id) => get_for_model(T).id), Q(Symbol(fkf, "__in") => ids))
        delete_ids!(M, values_list(rel, :id; flat = true))
    end
    for C in child_models(T)        # rows of subclasses that extend these rows
        delete_ids!(C, values_list(filter(base_objects(C); id__in = ids), :id; flat = true))
    end
    for (_, M, f) in reverse_relations(T)
        rel = filter(base_objects(M), Q(Symbol(attname(f), "__in") => ids))
        if f.on_delete === :CASCADE
            delete_ids!(M, values_list(rel, :id; flat = true))
        elseif f.on_delete === :SET_NULL
            update!(rel; Symbol(attname(f)) => nothing)
        elseif f.on_delete === :PROTECT
            exists(rel) && throw(ProtectedError("cannot delete $(nameof(T)) objects because they are referenced through protected foreign key $(nameof(M)).$(f.name)"))
        end
    end
    n = 0
    for chunk in Iterators.partition(ids, 500)
        n += execute_changes("DELETE FROM $(qname(modelmeta(T).table)) WHERE $(qname("id")) IN (" *
                             join(fill("?", length(chunk)), ",") * ")", collect(chunk))
    end
    P = table_parent(T)
    P === nothing || delete_ids!(P, ids)     # the parent rows these rows extend
    n
end

"Delete all matching rows (with `on_delete` handling for related objects). Returns the count."
Base.delete!(qs::QuerySet{T}) where {T} = atomic(() -> delete_ids!(T, values_list(qs, :id; flat = true)))

Base.show(io::IO, qs::QuerySet{T}) where {T} = print(io, "<QuerySet{", nameof(T), "}>")
function Base.show(io::IO, ::MIME"text/plain", qs::QuerySet{T}) where {T}
    items = fetch(qs[1:min(something(qs.limit, 21), 21)])
    print(io, "<QuerySet [", join([repr(x) for x in first(items, 20)], ", "), length(items) > 20 ? ", ...(remaining elements truncated)..." : "", "]>")
end
tattr(qs::QuerySet, ::Val{:count}) = count(qs)
tattr(qs::QuerySet, ::Val{:all}) = qs
tattr(qs::QuerySet, ::Val{:exists}) = exists(qs)
tattr(qs::QuerySet, ::Val{:first}) = first(qs)
tattr(qs::QuerySet, ::Val{:last}) = last(qs)

# --- instance operations ----------------------------------------------------------------

"""
    save!(obj) -> obj

INSERT (when `obj.id === nothing`) or UPDATE the object. Sets `auto_now` /
`auto_now_add` timestamps.
"""
function save!(obj::T) where {T<:Model}
    data = getfield(obj, :_data)
    ts = now()
    for f in all_fields(T)
        a = attname(f)
        if f.auto_now || (f.auto_now_add && (data[:id] === nothing || data[a] === nothing))
            data[a] = f.kind === :date ? Date(ts) : ts
        end
    end
    chain_ = reverse(vcat([concrete_model(T)], ancestors(T)))     # root table first
    fresh = false
    if data[:id] === nothing && pk_kind(T) === :uuid
        data[:id] = uuid4()           # UUID keys are made here, so the row is inserted directly
        fresh = true
    end
    length(chain_) == 1 ? save_table!(chain_[1], data, true, fresh) :
        atomic(() -> foreach(M -> save_table!(M, data, M === chain_[1], fresh), chain_))
    obj
end

"Write the columns of one table (`M`'s own fields) for an object's data."
function save_table!(M::Type, data, root::Bool, fresh::Bool = false)
    meta = modelmeta(M)
    cols = [qname(column(f)) for f in meta.fields]
    vals = Any[to_db(f, data[attname(f)]) for f in meta.fields]
    tbl = qname(meta.table)
    if fresh
        execute(insert_sql(backend(), tbl, vcat(qname("id"), cols)) |> s -> replace(s, r" RETURNING .*$" => ""),
                vcat(data[:id], vals))
        return
    end
    if data[:id] !== nothing
        n = isempty(cols) ? length(execute("SELECT 1 FROM $tbl WHERE $(qname("id")) = ?", [data[:id]])) :
            execute_changes("UPDATE $tbl SET " * join(["$c = ?" for c in cols], ", ") * " WHERE $(qname("id")) = ?",
                            vcat(vals, data[:id]))
        n > 0 && return
        execute_insert(insert_sql(backend(), tbl, vcat(qname("id"), cols)), vcat(data[:id], vals))
        root && sync_sequence(backend(), meta.table)
        return
    end
    root || error("internal: child table saved before its parent")
    data[:id] = execute_insert(insert_sql(backend(), tbl, cols), vals)
end

"Delete the object (and cascade to related objects)."
function Base.delete!(obj::T) where {T<:Model}
    id = obj.id
    id === nothing && error("cannot delete an unsaved $(T)")
    atomic(() -> delete_ids!(T, [id]))
    getfield(obj, :_data)[:id] = nothing
    obj
end

"Reload field values from the database."
function refresh!(obj::T) where {T<:Model}
    fresh = get(base_objects(T); id = obj.id)
    merge!(getfield(obj, :_data), getfield(fresh, :_data))
    empty!(getfield(obj, :_cache))
    obj
end

"Create and save a new object."
create(::Type{T}; kw...) where {T<:Model} = save!(T(; kw...))

"`(obj, created::Bool)` — fetch by lookups or create with lookups + `defaults`."
function get_or_create(::Type{T}; defaults = Dict{Symbol,Any}(), kw...) where {T<:Model}
    atomic() do
        o = first(filter(objects(T); kw...))
        o === nothing || return (o, false)
        (create(T; kw..., pairs_of(defaults)...), true)
    end
end

"`(obj, created::Bool)` — update the object matching lookups with `defaults`, or create it."
function update_or_create(::Type{T}; defaults = Dict{Symbol,Any}(), kw...) where {T<:Model}
    atomic() do
        o = first(filter(objects(T); kw...))
        o === nothing && return (create(T; kw..., pairs_of(defaults)...), true)
        for (k, v) in pairs_of(defaults)
            setproperty!(o, Symbol(k), v)
        end
        (save!(o), false)
    end
end

# --- validation --------------------------------------------------------------------------

const EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
const SLUG_RE = r"^[-a-zA-Z0-9_]+$"
const URL_RE = r"^https?://[^\s/$.?#].[^\s]*$"i

"""
Run per-field validation on a cleaned (typed) value; returns a vector of messages.
Validators are functions `v -> true/nothing` (ok) or an error message `String` / `false`.
"""
function validate_field(f::Field, v)
    errs = String[]
    isempty_val = v === nothing || (v isa AbstractString && isempty(v))
    if isempty_val
        (!f.blank && f.kind !== :bool) && push!(errs, "This field is required.")
        return errs
    end
    if f.max_length !== nothing && v isa AbstractString && length(v) > f.max_length
        push!(errs, "Ensure this value has at most $(f.max_length) characters (it has $(length(v))).")
    end
    f.kind === :email && !occursin(EMAIL_RE, string(v)) && push!(errs, "Enter a valid email address.")
    f.kind === :slug && !occursin(SLUG_RE, string(v)) && push!(errs, "Enter a valid “slug” consisting of letters, numbers, underscores or hyphens.")
    f.kind === :url && !occursin(URL_RE, string(v)) && push!(errs, "Enter a valid URL.")
    if f.choices !== nothing && !any(c -> value_eq(c.first, v) || string(c.first) == string(v), f.choices)
        push!(errs, "Select a valid choice. $(v) is not one of the available choices.")
    end
    for val in f.validators
        r = val(v)
        r isa AbstractString && push!(errs, r)
        r === false && push!(errs, "Enter a valid value.")
    end
    errs
end

"""
    full_clean(obj; exclude=Symbol[]) -> Dict{Symbol,Vector{String}}

Validate an instance against its field definitions (required, max_length,
choices, email/slug/url format, custom validators, uniqueness). Empty dict = valid.
"""
function full_clean(obj::T; exclude = Symbol[]) where {T<:Model}
    errors = Dict{Symbol,Vector{String}}()
    for f in all_fields(T)
        (f.name in exclude || !f.editable) && continue
        v = getproperty(obj, attname(f))
        errs = validate_field(f, v)
        if isempty(errs) && f.unique && v !== nothing
            q = filter(base_objects(f.model), Q(attname(f) => v))
            obj.id === nothing || (q = filter(q, !Q(id = obj.id)))
            exists(q) && push!(errs, "$(uppercasefirst(modelmeta(T).verbose_name)) with this $(label(f)) already exists.")
        end
        isempty(errs) || (errors[f.name] = errs)
    end
    errors
end


# --- many-to-many ----------------------------------------------------------------------------

"Context carried by a many-to-many queryset: the join model and which FK points at `id`."
struct M2MOwner
    through::Type
    mine::Field      # FK in the join model pointing at the instance
    other::Field     # FK pointing at the related objects
    id::Any
end

function m2m_queryset(m::Model, f::Field, forward::Bool)
    src, dst = through_fks(f)
    mine, other = forward ? (src, dst) : (dst, src)
    Other = related_model(other)
    id = getfield(m, :_data)[:id]
    step1, step2 = m2m_path(f, !forward)      # from the other model back to this instance
    qs = filter(objects(Other), Q(Symbol(step1, "__", step2) => id))
    chain(qs; owner = M2MOwner(through_model(f), mine, other, id))
end

function m2m_owner(qs::QuerySet)
    qs.owner isa M2MOwner || throw(ArgumentError("add!/remove!/set!/clear! need a many-to-many relation such as post.tags"))
    qs.owner.id === nothing && throw(ArgumentError("save the object before changing its many-to-many relations"))
    qs.owner
end
objid(x::Model) = (x.id === nothing && throw(ArgumentError("cannot relate an unsaved $(typeof(x))")); x.id)
objid(x) = x

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
        for id in ids
            id in have && continue
            save!(o.through(; attname(o.mine) => o.id, attname(o.other) => id,
                            (Symbol(k) => v for (k, v) in pairs(through_defaults))...))
        end
    end
    qs
end

"Remove objects (or ids) from a many-to-many relation."
function remove!(qs::QuerySet, objs...)
    o = m2m_owner(qs)
    ids = objid.(collect(objs))
    isempty(ids) || delete!(filter(base_objects(o.through), Q(attname(o.mine) => o.id), Q(Symbol(attname(o.other), "__in") => ids)))
    qs
end

"Remove every object from a many-to-many relation."
function clear!(qs::QuerySet)
    o = m2m_owner(qs)
    delete!(filter(base_objects(o.through), Q(attname(o.mine) => o.id)))
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
