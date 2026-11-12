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
    verbose_name::AbstractString      # may be gettext_lazy(...)
    help_text::AbstractString
    validators::Vector{Any}
    widget::Any                       # nothing, a Symbol (:textarea, :password, ...) or a widget value
    editable::Bool
    db_index::Bool
    model::Any
    through::Any        # ManyToManyField: the intermediate model (generated when not given)
    one_to_one::Bool    # OneToOneField: a unique FK whose reverse side is a single object
    db_default::Any     # value (or Now()) the database fills in when a new row leaves the field out
    generated::Any      # GeneratedField: (expression, persisted) computed by the database
    symmetrical::Bool   # ManyToManyField(:self): a relation in one direction is one in both
    db_comment::Union{Nothing,String}   # a comment on the column in the database
    att::Symbol         # attname for the name in `attfor` (see `attname`)
    col::String         # string(att): the column name
    attfor::Symbol      # the name `att` and `col` were worked out for
end

# `attname`/`column` are looked up constantly (row loading, attribute access, SQL), so they're
# stored rather than rebuilt each time, and worked out again when the field's name changes.
# (A `setproperty!` method on Field would do it eagerly, but extending Base.setproperty!
# invalidates a large amount of compiled code.)
field_att(kind::Symbol, name::Symbol) = kind === :fk ? Symbol(name, :_id) : name
function refresh_att!(f)
    name = getfield(f, :name)
    a = field_att(getfield(f, :kind), name)
    setfield!(f, :att, a)
    setfield!(f, :col, string(a))
    setfield!(f, :attfor, name)
    a
end

"The value of a field with `db_default` until the row is saved and the database has filled it in."
struct DatabaseDefault end
const DB_DEFAULT = DatabaseDefault()
Base.show(io::IO, ::DatabaseDefault) = print(io, "DB_DEFAULT")

normchoices(::Nothing) = nothing
normchoices(cs) = Pair{Any,String}[c isa Pair ? (c.first => string(c.second)) : (c => string(c)) for c in cs]

function Field(kind::Symbol; null = false, blank = false, default = NO_DEFAULT, unique = false,
               max_length = nothing, choices = nothing, related = nothing, on_delete = :CASCADE,
               related_name = nothing, auto_now = false, auto_now_add = false, verbose_name = "",
               help_text = "", validators = Any[], widget = nothing, editable = true,
               db_index = false, required = nothing, label = nothing, through = nothing, one_to_one = false,
               db_default = nothing, generated = nothing, symmetrical = false, db_comment = nothing)
    required === nothing || (blank = !required)
    label === nothing || (verbose_name = string(label))
    if auto_now || auto_now_add
        editable = false
        blank = true
    end
    Field(kind, :_, null, blank, default, unique, max_length, normchoices(choices), related,
          Symbol(uppercase(string(on_delete))), related_name === nothing ? nothing : Symbol(related_name),
          auto_now, auto_now_add, verbose_name isa AbstractString ? verbose_name : string(verbose_name),
          help_text isa AbstractString ? help_text : string(help_text), collect(Any, validators),
          widget isa Union{AbstractString,Symbol} ? Symbol(widget) : widget, editable, db_index, nothing, through, one_to_one,
          db_default, generated, symmetrical, db_comment === nothing ? nothing : string(db_comment),
          field_att(kind, :_), string(field_att(kind, :_)), :_)
end

"""
    GeneratedField(; expression, output_field, db_persist = true)

A column the database computes from other columns of the row, e.g.
`total = GeneratedField(expression = F(:price) * F(:quantity), output_field = FloatField())`.
It can't be assigned; the value is read back after every `save!`. Expressions use `F`,
literals, `+ - * /`, `Lower`, `Upper`, `Length`, `Coalesce` and `Concat`. `db_persist = true`
stores the value (PostgreSQL supports only that); `false` computes it on read.
"""
function GeneratedField(; expression, output_field::Field, db_persist::Bool = true, kw...)
    f = deepcopy(output_field)
    f.generated = (expression isa Expression ? expression : ref(expression), db_persist)
    f.editable = false
    f.blank = true
    f.null = true
    f.default = NO_DEFAULT
    for (k, v) in kw
        setfield!(f, k, v)
    end
    f
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

A relation of a model to itself (`friends = ManyToManyField(:self)`) is symmetrical: when
`a` is a friend of `b`, `b` is a friend of `a` (adding or removing either way changes both).
Pass `symmetrical = false` for one-way relations such as "follows".
"""
function ManyToManyField(to; symmetrical = nothing, kw...)
    sym = something(symmetrical, to === :self)
    sym && to !== :self && throw(ArgumentError("symmetrical = true is for a ManyToManyField(:self)"))
    sym && haskey(kw, :through) && kw[:through] !== nothing &&
        throw(ArgumentError("a symmetrical ManyToManyField can't have a custom through model; use symmetrical = false"))
    Field(:m2m; related = to, symmetrical = sym, kw...)
end

const STRING_KINDS = (:char, :text, :email, :slug, :url)

"Attribute name under which the raw value is stored (`author_id` for a FK)."
attname(f::Field) = getfield(f, :attfor) === getfield(f, :name) ? getfield(f, :att) : refresh_att!(f)
"The field's column name (`string(attname(f))`)."
column(f::Field) = (attname(f); getfield(f, :col))
label(f::Field) = isempty(f.verbose_name) ? gettext(uppercasefirst(replace(string(f.name), '_' => ' '))) : String(f.verbose_name)

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
cached_relations(f, kind::Symbol, @nospecialize(T)) =
    lock(() -> get!(() -> f(T), RELATION_CACHE, (kind, T)), RELATION_LOCK)

"""
App a model belongs to for migrations: `Meta(app_label=...)`, else `\"juango\"` for Juango's
built-in models, the label of the `App` whose module defines it, or `\"project\"`.
"""
default_app_label(T) = parentmodule(T) === (@__MODULE__) ? "juango" : something(module_app_label(parentmodule(T)), "project")

"Remove a model from the registry (mostly for tests that redefine models)."
function unregister_model!(T::Type)
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
child_models(T::Type) = cached_relations(:children, T) do T
    Any[C for C in MODEL_LIST if (m = modelmeta(C); !m.proxy && m.parent === concrete_model(T))]
end
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
    r === :__user_model__ && return get_user_model()        # ForeignKey(USER_MODEL)
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
m2m_relations(T::Type) = cached_relations(compute_m2m_relations, :m2m, T)
function compute_m2m_relations(T::Type)
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
    f.generated === nothing || return nothing
    d = f.default
    d isa NoDefault && f.db_default !== nothing && return DB_DEFAULT
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
    for g in foreign_objects(T)
        haskey(kw, g.name) && set_fobj!(obj, g, pop!(kw, g.name))
    end
    isempty(kw) || throw(ArgumentError("$T got unexpected field(s): $(join(keys(kw), ", "))"))
    obj
end

"Reverse FK relations pointing at model `T`: Vector of (name, Model, Field)."
reverse_relations(T::Type) = cached_relations(compute_reverse_relations, :reverse, T)
function compute_reverse_relations(T::Type)
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
function field_data(m::Model, a::Symbol)
    data = getfield(m, :_data)
    v = get(data, a, NOTFOUND)
    v === NOTFOUND || return v
    load_deferred!(m)
    data[a]
end

"Fetch an object's unloaded fields from the database (keeping the values already loaded)."
function load_deferred!(m::Model)
    T = typeof(m)
    data = getfield(m, :_data)
    data[:id] === nothing && throw(ArgumentError("$(nameof(T)) has no value for a deferred field and isn't saved"))
    fresh = getfield(with_db(() -> get(base_objects(T); id = data[:id]), instance_db(m)), :_data)
    for (k, v) in fresh
        haskey(data, k) || (data[k] = v)
    end
    m
end

"The fields of an object that `only`/`defer` (or `raw`) left unloaded."
deferred_fields(m::Model) = Symbol[attname(f) for f in all_fields(typeof(m)) if !haskey(getfield(m, :_data), attname(f))]

function Base.getproperty(m::Model, s::Symbol)
    data = getfield(m, :_data)
    v = get(data, s, NOTFOUND)
    v === NOTFOUND || return v
    s === :pk && return data[:id]
    s in (:_data, :_cache) && return getfield(m, s)
    T = typeof(m)
    any(f -> attname(f) === s, all_fields(T)) && return field_data(m, s)
    f = findfield(modelmeta(T), s)
    if f !== nothing && f.kind === :fk
        id = field_data(m, attname(f))
        id === nothing && return nothing
        cache = getfield(m, :_cache)
        c = get(cache, s, nothing)
        (c !== nothing && getfield(c, :_data)[:id] == id) && return c
        obj = with_db(() -> get(base_objects(related_model(f)); id = id), instance_db(m))
        cache[s] = obj
        return obj
    end
    cache = getfield(m, :_cache)
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
    r = tattr(m, Val(s))
    r === NOTFOUND || return r
    throw(ArgumentError("$(T) has no attribute '$s'"))
end

function Base.setproperty!(m::Model, s::Symbol, v)
    data = getfield(m, :_data)
    s === :pk && (s = :id)
    g = find_generic(generic_fks(typeof(m)), s)
    g === nothing || return set_generic!(m, g, v)
    g = find_generic(foreign_objects(typeof(m)), s)
    g === nothing || return set_fobj!(m, g, v)
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
    append!(names, [g.name for g in vcat(generic_fks(typeof(m)), generic_relations(typeof(m)), foreign_objects(typeof(m)))])
    append!(names, first.(reverse_foreign_objects(typeof(m))))
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
tattr(m::Model, ::Val{:pk_string}) = pk_string(m)

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
    k === :datetime && return datetime_from_db(v isa DateTime || v isa TimeZones.ZonedDateTime ? v : something(todatetime(v), v))
    k === :date && return v isa Date ? v : Date(todatetime(v))
    v isa AbstractString ? String(v) : v
end

to_db(f::Field, v::Model) = v.id      # (other values: see fields_extra.jl)

"""
    CompositePrimaryKey(:order, :product)

`Meta(pk = CompositePrimaryKey(...))`: the table's primary key is these fields together, and
there is no `id` column. `obj.pk` (and `obj.id`) is a tuple of their values; look objects up
with `get(Model; pk = (1, 2))` or `filter(Model; pk__in = [(1, 2), (1, 3)])`. As in Django,
other models can't point a ForeignKey or ManyToManyField at such a model, it can't take part
in multi-table inheritance, and the admin doesn't support it.
"""
struct CompositePrimaryKey
    fields::Vector{Symbol}
end
CompositePrimaryKey(fields::Union{Symbol,AbstractString}...) = CompositePrimaryKey(Symbol[Symbol(f) for f in fields])

"Primary key kind of a model's table: `:auto` (integer identity), `:uuid` (`Meta(pk = :uuid)`) or `:composite`."
function pk_kind(T::Type)
    A = concrete_model(T)
    while (P = table_parent(A)) !== nothing
        A = P
    end
    p = get(modelmeta(A).extra, :pk, :auto)
    p isa CompositePrimaryKey ? :composite : p
end
pk_value(T::Type, v) = (v === nothing || pk_kind(T) !== :uuid || v isa UUID) ? v : UUID(string(v))

is_composite(T::Type) = pk_kind(T) === :composite
"The fields of a composite primary key, in order."
pk_fields(T::Type) = Field[getfield_meta(T, n) for n in modelmeta(concrete_model(T)).extra[:pk].fields]
"The primary key of rows at `alias`, as SQL: `alias.id`, or a row value `(alias.a, alias.b)`."
pk_ref(alias, T::Type) = is_composite(T) ? "(" * join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") * ")" : qcol(alias, "id")
"The primary key column(s) of rows at `alias`, for a SELECT list."
pk_select(alias, T::Type) = is_composite(T) ? join([qcol(alias, column(f)) for f in pk_fields(T)], ", ") : qcol(alias, "id")
"A composite key's tuple from an object's data (`nothing` if a part is missing)."
function composite_pk(T::Type, data)
    vals = Any[get(data, attname(f), nothing) for f in pk_fields(T)]
    any(isnothing, vals) ? nothing : Tuple(vals)
end

"""
Parse a primary key from text (URLs, form values); `nothing` if it isn't one. A composite
key is its parts as `pk_string` writes them: `"3,7"`.
"""
function parse_pk(T::Type, s)
    s isa Integer && return pk_kind(T) === :auto ? s : nothing
    s isa UUID && return s
    s isa Tuple && return s
    k = pk_kind(T)
    k === :composite && return parse_composite_pk(T, string(s))
    k === :uuid ? tryparse(UUID, string(s)) : tryparse(Int, string(s))
end
function parse_composite_pk(T::Type, s::AbstractString)
    fs = pk_fields(T)
    bits = split(s, ',')
    length(bits) == length(fs) || return nothing
    vals = Any[]
    for (f, b) in zip(fs, bits)
        b = unquote_pk(b)
        v = f.kind === :fk ? parse_pk(related_model(f), b) : f.kind === :int ? tryparse(Int, b) :
            f.kind === :uuid ? tryparse(UUID, b) : f.kind === :date ? tryparse(Date, b) : String(b)
        v === nothing && return nothing
        push!(vals, v)
    end
    Tuple(vals)
end

"""
    pk_string(obj) -> String

An object's primary key as text for URLs: the id, or a composite key's parts joined with
commas (each escaped as Django's admin does: `,` becomes `_2C`).
"""
pk_string(m::Model) = (pk = m.pk; pk isa Tuple ? join((quote_pk(string(x)) for x in pk), ",") : string(pk))
const PK_QUOTE_CHARS = Set(":/_#?;@&=+\$,\"[]<>%\n\\")
quote_pk(s::AbstractString) = any(in(PK_QUOTE_CHARS), s) ?
    join(c in PK_QUOTE_CHARS ? "_" * uppercase(string(UInt8(c); base = 16, pad = 2)) : string(c) for c in s) : s
unquote_pk(s::AbstractString) = occursin('_', s) ? replace(s, r"_([0-9A-F]{2})" => m -> string(Char(parse(UInt8, m[2:3]; base = 16)))) : String(s)

"""
How a model's fields map to row keys: `(field, row key, attribute name)` per field. Inherited
multi-table fields are labelled per table (`__place__name`). Work it out once per query and
pass it to `from_row` for every row.
"""
function row_plan(@nospecialize(T::Type))
    mytable = modelmeta(T).table
    plan = Tuple{Field,Symbol,Symbol}[]
    for f in all_fields(T)
        t = modelmeta(f.model).table
        push!(plan, (f, t == mytable ? attname(f) : Symbol("__", t, "__", column(f)), attname(f)))
    end
    plan
end

function from_row(::Type{T}, row::Dict{Symbol,Any}, plan = row_plan(T)) where {T<:Model}
    composite = is_composite(T)
    data = Dict{Symbol,Any}()
    sizehint!(data, length(plan) + 1)
    data[:id] = composite ? nothing : pk_value(T, row[:id])
    for (f, key, att) in plan
        v = get(row, key, NOTFOUND)
        v === NOTFOUND && continue               # deferred (only/defer, raw): loaded on first access
        data[att] = from_db(f, v)
    end
    composite && (data[:id] = composite_pk(T, data))
    T(data, Dict{Symbol,Any}())
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
                     "has_any_keys", "search", "intersects", "within", "covers", "coveredby", "disjoint", "touches",
                     "crosses", "overlaps", "equals", "distance_lt", "distance_lte", "distance_gt", "distance_gte", "dwithin"])

# --- custom lookups and transforms ---------------------------------------------------------------

struct CustomLookup
    kinds::Union{Nothing,Vector{Symbol}}   # field kinds it applies to (nothing: all)
    sql::Any                               # (lhs, rhs) -> SQL
    prepare::Any                           # value -> parameter
end
struct CustomTransform
    kinds::Union{Nothing,Vector{Symbol}}
    sql::Any                               # lhs -> SQL
    output::Union{Nothing,Symbol}          # kind of the result (nothing: same as the input)
end
const CUSTOM_LOOKUPS = Dict{String,Vector{CustomLookup}}()
const CUSTOM_TRANSFORMS = Dict{String,Vector{CustomTransform}}()

kinds_vec(k) = k === nothing ? nothing : k isa Symbol ? [k] : Symbol[Symbol(x) for x in k]
applies(x, kind) = x.kinds === nothing || kind !== nothing && kind in x.kinds
function find_custom(d, name, kind)
    v = get(d, name, nothing)
    v === nothing && return nothing
    for x in Iterators.reverse(v)              # the latest registration wins
        applies(x, kind) && return x
    end
    nothing
end

"""
    register_lookup(sql, name; kinds = nothing, prepare = identity)

Add a lookup usable in `filter`, `exclude` and `Q` (Django's `register_lookup`). `sql(lhs, rhs)`
returns the condition, given the column's SQL and the value's placeholder. `kinds` limits it
to some field kinds (`:char`, `:text`, `:int`, ...); `prepare` converts the value first.
A registered lookup takes precedence over a built-in one of the same name.

    Juango.register_lookup("notequal"; kinds = [:char, :text]) do lhs, rhs
        "\$lhs <> \$rhs"
    end
    filter(Author; name__notequal = "Ann")
"""
function register_lookup(sql, name::Union{AbstractString,Symbol}; kinds = nothing, prepare = identity)
    push!(get!(Vector{CustomLookup}, CUSTOM_LOOKUPS, string(name)), CustomLookup(kinds_vec(kinds), sql, prepare))
    nothing
end

"""
    register_transform(sql, name; kinds = nothing, output = nothing)

Add a transform: `field__name__lookup` applies `sql(lhs)` to the column before the lookup,
and transforms chain (`name__lower__length__gte = 3`). `output` is the field kind of the
result (`:int` for a length), which decides how values are converted and which custom
lookups apply after it.

    Juango.register_transform("lower"; kinds = [:char, :text]) do lhs
        "LOWER(\$lhs)"
    end
    filter(Author; name__lower__startswith = "an")
"""
function register_transform(sql, name::Union{AbstractString,Symbol}; kinds = nothing, output = nothing)
    push!(get!(Vector{CustomTransform}, CUSTOM_TRANSFORMS, string(name)),
          CustomTransform(kinds_vec(kinds), sql, output === nothing ? nothing : Symbol(output)))
    nothing
end

"Remove a lookup or transform registered under `name` (all registrations)."
unregister_lookup(name) = (delete!(CUSTOM_LOOKUPS, string(name)); delete!(CUSTOM_TRANSFORMS, string(name)); nothing)

is_lookup_name(s) = s in LOOKUPS || haskey(CUSTOM_LOOKUPS, s)

"Apply registered transforms `names` to `col` of kind `kind`: `(sql, kind)`, or `nothing` if one doesn't apply."
function apply_transforms(col::String, kind, names)
    for n in names
        t = find_custom(CUSTOM_TRANSFORMS, n, kind)
        t === nothing && return nothing
        col = t.sql(col)::AbstractString
        t.output === nothing || (kind = t.output)
    end
    String(col), kind
end


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
    uses_window::Bool           # set when a condition refers to a window annotation (-> wrapping query)
    join_params::Vector{Any}    # parameters in JOIN ... ON clauses (FilteredRelation conditions)
end
function SQLCompiler(@nospecialize(T::Type); outer = nothing)
    table = modelmeta(T).table
    counter = outer === nothing ? Ref(0) : outer.counter
    c = SQLCompiler(T, table, table, String[], Dict{Any,String}(), Set{String}(), counter, false, 0,
                    Dict{Symbol,Any}(), false, outer, false, Any[])
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

"Strip `prefix__` from the lookups of a FilteredRelation condition."
function strip_relation(q::Q, prefix::AbstractString, rel::AbstractString)
    kids = Any[]
    for ch in q.children
        if ch isa Q
            push!(kids, strip_relation(ch, prefix, rel))
        elseif ch isa Pair
            k = string(ch.first)
            startswith(k, prefix) ||
                throw(ArgumentError("FilteredRelation condition '$k' must start with the relation name '$rel'"))
            push!(kids, Symbol(chopprefix(k, prefix)) => ch.second)
        else
            throw(ArgumentError("FilteredRelation conditions must be lookups, not $(typeof(ch))"))
        end
    end
    Q(q.connector, kids, q.negated)
end

"""
The relation of FilteredRelation annotation `name` on `T`: `(model, related column, base column)`,
joined as related.col = base.col.
"""
function filtered_target(T::Type, fr)
    rel = fr.relation
    occursin("__", rel) && throw(ArgumentError("FilteredRelation('$rel'): nested relations are not supported"))
    f = findfield(modelmeta(T), Symbol(rel))
    if f !== nothing
        f.kind === :fk || throw(ArgumentError("FilteredRelation('$rel'): '$rel' is not a relation of $T"))
        modelmeta(f.model).table == modelmeta(T).table ||
            throw(ArgumentError("FilteredRelation('$rel'): relations inherited from a parent model are not supported"))
        return related_model(f), "id", column(f), false
    end
    find_m2m(T, rel) === nothing ||
        throw(ArgumentError("FilteredRelation('$rel'): many-to-many relations are not supported; filter the through model"))
    r = find_reverse(T, rel)
    r === nothing && throw(lookup_error(T, rel))
    _, M, rf = r
    M, column(rf), "id", true
end

"""
Join FilteredRelation annotation `name` (once per query) and return `(alias, model)`. The
condition goes in the ON clause, so rows of the base model without a match survive
(LEFT JOIN) and aggregates see only matching related rows.
"""
function filtered_join!(c::SQLCompiler, alias, @nospecialize(T::Type), name::Symbol)
    key = (alias, :__filtered, name)
    fr = c.annotations[name]::FilteredRelation
    M, childcol, parentcol, reverse = filtered_target(T, fr)
    reverse && c.scope !== :expr && c.scope != 0 && (c.distinct = true)
    haskey(c.aliases, key) && return c.aliases[key], M
    a = new_alias!(c)
    njoins = length(c.joins)
    csql, cps = compile_q(c, a, M, strip_relation(fr.condition, fr.relation * "__", fr.relation), false)
    length(c.joins) == njoins ||
        throw(ArgumentError("FilteredRelation('$(fr.relation)'): the condition may only use $(nameof(M))'s own fields"))
    push!(c.leftjoined, a)
    push!(c.joins, " LEFT OUTER JOIN $(qname(modelmeta(M).table)) $(qname(a)) ON $(qcol(a, childcol)) = $(qcol(alias, parentcol)) AND $csql")
    append!(c.join_params, cps)
    c.aliases[key] = a
    a, M
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
function compile_lookup(c::SQLCompiler, alias, @nospecialize(T::Type), key, @nospecialize(value), negated::Bool)
    parts = split(string(key), "__")
    lookup = "exact"
    (length(parts) > 1 && is_lookup_name(parts[end])) && (lookup = String(pop!(parts)))
    meta = modelmeta(T)
    fname = parts[1] == "pk" ? "id" : String(parts[1])
    rest = String.(parts[2:end])
    f = nothing
    colps = Any[]
    kind = nothing                     # the compared value's field kind, for custom lookups
    if alias == c.base && is_filtered_relation(get(c.annotations, Symbol(fname), nothing))
        subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
        if negated
            # exclude(): no matching related row, as an EXISTS over the filtered relation
            fr = c.annotations[Symbol(fname)]::FilteredRelation
            M, childcol, parentcol, _ = filtered_target(T, fr)
            a = new_alias!(c)
            csql, cps = compile_q(c, a, M, strip_relation(fr.condition, fr.relation * "__", fr.relation), false)
            sql, ps = compile_lookup(c, a, M, subkey, value, negated)
            return ("EXISTS (SELECT 1 FROM $(qname(modelmeta(M).table)) $(qname(a)) WHERE $(qcol(a, childcol)) = $(qcol(alias, parentcol)) AND $csql AND $sql)",
                    vcat(cps, ps))
        end
        a, M = filtered_join!(c, alias, T, Symbol(fname))
        return compile_lookup(c, a, M, subkey, value, negated)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname)) && contains_window(c.annotations[Symbol(fname)])
        # Window functions can't appear in WHERE: the query is wrapped and this compares the column.
        c.uses_window = true
        col = qname(fname)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname))
        a = c.annotations[Symbol(fname)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, colps = compile_expr(c, a)
        col = "($sql)"
    elseif fname == "id" && is_composite(T)
        isempty(rest) || throw(LookupError("'pk' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        fs = pk_fields(T)
        part(tup) = (length(tup) == length(fs) || throw(ArgumentError("$(nameof(T)) has a $(length(fs))-part primary key; got $(repr(tup))"));
                     Q(:AND, Any[f.name => v for (f, v) in zip(fs, tup)], false))
        if lookup == "exact"
            value === nothing && return (sql_false(backend()), Any[])
            return compile_q(c, alias, T, part(value), negated)
        elseif lookup == "in"
            isempty(value) && return (sql_false(backend()), Any[])
            return compile_q(c, alias, T, Q(:OR, Any[part(t) for t in value], false), negated)
        elseif lookup == "isnull"
            return (truthy(value) ? sql_false(backend()) : sql_true(backend()), Any[])
        end
        throw(LookupError("composite primary keys support the pk, pk__in and pk__isnull lookups, not '$lookup'"))
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
        if f === nothing && (g = find_generic(foreign_objects(T), fname)) !== nothing
            return compile_fobj_lookup(c, alias, g, related_model(g), rest, lookup, value, negated, false, (alias, g.name))
        end
        if f === nothing && (r = find_reverse_fobj(T, fname)) !== nothing
            return compile_fobj_lookup(c, alias, r[3], r[2], rest, lookup, value, negated, true, (alias, r[1], c.scope))
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
        if !isempty(rest) && f.kind in (:json, :hstore, :array)
            # data__owner__name (JSON key path), tags__len, tags__0
            tr = transform_column(f, qcol(alias, column(f)), rest, lookup, value)
            tr === nothing && throw(LookupError("unsupported lookup '$(join(rest, "__"))' on $(f.kind) field '$fname'"))
            col, colps = tr
            lookup == "isnull" && f.kind in (:json, :hstore) && return truthy(value) ? (col, colps) : ("NOT " * col, colps)
            f = nothing
        elseif !isempty(rest) && (tr = apply_transforms(qcol(alias, column(f)), f.kind, rest)) !== nothing
            col, kind = tr                  # registered transforms: name__lower__...
            kind === f.kind || (f = nothing)
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
    f === nothing || (kind = f.kind)
    cl = isempty(CUSTOM_LOOKUPS) ? nothing : find_custom(CUSTOM_LOOKUPS, lookup, kind)
    if cl !== nothing
        if value isa Expression
            vsql, vps = compile_expr(c, value)
            return cl.sql(col, "(" * vsql * ")")::AbstractString, vcat(colps, vps)
        end
        return cl.sql(col, "?")::AbstractString, vcat(colps, Any[conv(cl.prepare(value))])
    end
    if f !== nothing || lookup == "search"
        sl = special_lookup(c, something(f, Field(:text)), col, lookup, value)
        sl === nothing || return sl[1], vcat(colps, sl[2])
    end
    sql, ps = lookup_condition(c, col, lookup, value, conv)
    sql, isempty(colps) ? ps : vcat(colps, ps)
end

const COMPARISON_OPS = Dict("exact" => "=", "ne" => "!=", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")

function lookup_condition(c::SQLCompiler, col, lookup, @nospecialize(value), @nospecialize(conv))
    if value isa SearchQuery && lookup == "exact"
        q, qps = compile_expr(c, value)
        return "$col @@ $q", qps
    end
    if value isa Expression && lookup in ("exact", "ne", "gt", "gte", "lt", "lte", "iexact")
        vsql, vps = compile_expr(c, value)
        lookup == "iexact" && return ("LOWER($col) = LOWER($vsql)", vps)
        return ("$col $(COMPARISON_OPS[lookup]) ($vsql)", vps)
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
        return ("$col $(COMPARISON_OPS[lookup]) ?", Any[conv(value)])
    elseif lookup == "in"
        if value isa QuerySet
            sql, ps = value.values_fields === nothing ? subquery_sql(c, value; columns = nothing, idonly = true) :
                      subquery_sql(c, value)
            return ("$col IN ($(in_subquery(backend(), sql)))", ps)
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

function compile_q(c::SQLCompiler, alias, @nospecialize(T::Type), q::Q, negated::Bool)
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
    deferred::Vector{Symbol}                       # fields left out of the SELECT (only/defer), loaded on access
    distinct_fields::Union{Nothing,Vector{String}} # distinct(): nothing = off, [] = DISTINCT, fields = DISTINCT ON
    for_update::Any                                # select_for_update options (a NamedTuple) or nothing
    combinator::Any                                # (op, querysets, all) for union/intersection/difference, or nothing
    db::Union{Nothing,String}                      # using_db(qs, alias): the database to query
end
QuerySet{T}(where, order, limit, offset, isnone) where {T} =
    QuerySet{T}(where, order, limit, offset, isnone, Vector{Symbol}[], Prefetch[], nothing, nothing,
                Pair{Symbol,Any}[], nothing, false, Symbol[], nothing, nothing, nothing, nothing)

"""
    using_db(qs, "replica")

The queryset, run against another database (a key of `DATABASES`). Objects it returns
remember it: saving them and following their relations use the same database.
"""
using_db(qs::QuerySet, alias) = chain(qs; db = string(alias))
using_db(::Type{T}, alias) where {T<:Model} = using_db(objects(T), alias)
using_db(alias::Union{AbstractString,Symbol}) = qs -> using_db(qs, alias)

"The database a queryset runs on (`nothing`: the current one)."
query_db(qs::QuerySet{T}, write::Bool = false) where {T} = qs.db !== nothing ? qs.db : routed_db(T, write)
"Run `f()` on the queryset's database."
in_db(f, qs::QuerySet, write::Bool = false) = with_db(f, query_db(qs, write))

"The database an object was loaded from or saved to (`nothing` if neither yet)."
instance_db(m::Model) = get(getfield(m, :_cache), :__db, nothing)
set_instance_db!(m::Model) = (getfield(m, :_cache)[:__db] = current_alias(); m)

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

function assert_uncombined(qs::QuerySet, what)
    qs.combinator === nothing ||
        throw(ArgumentError("cannot $what the result of union/intersection/difference; filter the querysets before combining them"))
end

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
    assert_uncombined(qs, "filter")
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
    assert_uncombined(qs, "exclude")
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
        if haskey(c.annotations, Symbol(lstrip(o, '-'))) && !is_filtered_relation(c.annotations[Symbol(lstrip(o, '-'))])
            push!(parts, qname(lstrip(o, '-')) * (desc ? " DESC" : " ASC"))
            continue
        end
        segs = split(lstrip(o, '-'), "__")
        alias, M = c.base, T
        for (i, s) in enumerate(segs[1:end-1])     # follow forward FKs: order_by("author__name")
            if i == 1 && is_filtered_relation(get(c.annotations, Symbol(s), nothing))
                alias, M = filtered_join!(c, alias, M, Symbol(s))
                continue
            end
            f = findfield(modelmeta(M), Symbol(s))
            (f !== nothing && f.kind === :fk) || throw(LookupError("cannot order $T by '$o': '$s' is not a foreign key of $M"))
            alias = field_alias!(c, alias, M, f)
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = true)
            M = related_model(f)
        end
        name = segs[end]
        if name in ("id", "pk") && is_composite(M)
            for g in pk_fields(M)
                push!(parts, qcol(alias, column(g)) * (desc ? " DESC" : " ASC"))
            end
            continue
        end
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
            sub = path[1:i]
            any(x -> x[1] == sub, out) && continue
            push!(out, (sub, M, alias))
            push!(cols, "$(qcol(alias, "id")) AS $(qname(alias * "__id"))")
            for g in modelmeta(M).fields
                push!(cols, "$(qcol(alias, column(g))) AS $(qname(alias * "__" * column(g)))")
            end
            # a model that extends another table: join its parents for the inherited fields
            palias, A = alias, concrete_model(M)
            while (P = table_parent(A)) !== nothing
                palias = join!(c, palias, (palias, :__parent), modelmeta(P).table, "id", "id"; left = f.null)
                for g in modelmeta(P).fields
                    push!(cols, "$(qcol(palias, column(g))) AS $(qname(alias * "__" * column(g)))")
                end
                A = P
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
queryset_model(::QuerySet{T}) where {T} = T

# Not specialized on the model: one compiled copy serves every model (and lives in the package image).
function build_select(@nospecialize(qs::QuerySet); columns = nothing, ordered = true, outer = nothing, idonly = false)
    T = queryset_model(qs)
    qs.combinator === nothing || return build_combined(qs; columns = columns, ordered = ordered, idonly = idonly)
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
        push!(sel, pk_select(c.base, T))
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
        qs.group_by_object && pushfirst!(group, pk_select(c.base, T))
    else
        if isempty(qs.deferred)
            push!(sel, qname(c.base) * ".*")
        else
            is_composite(T) || push!(sel, qcol(c.base, "id"))
            for f in modelmeta(concrete_model(T)).fields
                f.name in qs.deferred || push!(sel, qcol(c.base, column(f)))
            end
        end
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
        push!(group, pk_select(c.base, T))
        append!(group, [qcol(a, "id") for (_, _, a) in related])
    end
    pre_ann = copy(sel)            # the select list without annotations (for a wrapping query)
    ann_sel, ann_ps = String[], Any[]
    for (k, v) in qs.annotations
        is_filtered_relation(v) && continue
        sql, p = compile_expr(c, v)
        push!(ann_sel, "$sql AS $(qname(string(k)))")
        append!(ann_ps, p)
    end
    if columns === nothing && !idonly
        append!(sel, ann_sel)
        append!(sel_ps, ann_ps)
    end
    # WHERE, HAVING for conditions on aggregate annotations, or an outer WHERE for window ones
    wparts, wps, hparts, hps, oparts, ops = String[], Any[], String[], Any[], String[], Any[]
    if qs.isnone
        push!(wparts, sql_false(backend()))
    else
        for (i, q) in enumerate(qs.where)
            c.scope = i
            c.uses_aggregate = false
            c.uses_window = false
            sql, p = compile_q(c, c.base, T, q, false)
            if c.uses_window
                push!(oparts, sql); append!(ops, p)
            elseif c.uses_aggregate
                push!(hparts, sql); append!(hps, p)
            else
                push!(wparts, sql); append!(wps, p)
            end
        end
        c.scope = 0
    end
    if grouped && columns !== nothing && !idonly && qs.values_fields === nothing
        group = [pk_select(c.base, T)]
    end
    o, extra = ordered ? order_clause(c, qs.order) : ("", String[])
    (columns === nothing && !idonly && !grouped) && append!(sel, extra)
    distinct = (c.distinct || qs.distinct_fields !== nothing) && !grouped
    dkw = distinct ? "DISTINCT " : ""
    if distinct && qs.distinct_fields !== nothing && !isempty(qs.distinct_fields)
        backend() isa PostgresBackend ||
            throw(ArgumentError("distinct(fields...) (DISTINCT ON) is only supported on PostgreSQL"))
        dkw = "DISTINCT ON (" * join([resolve_path(c, c.base, T, f)[1] for f in qs.distinct_fields], ", ") * ") "
    end
    sql = "SELECT $dkw$(join(sel, ", ")) FROM $(qname(c.table))" *
          (c.base == c.table ? "" : " " * qname(c.base)) * join(c.joins) *
          (isempty(wparts) ? "" : " WHERE " * join(wparts, " AND ")) *
          (grouped && !isempty(group) ? " GROUP BY " * join(unique(group), ", ") : "") *
          (isempty(hparts) ? "" : " HAVING " * join(hparts, " AND ")) *
          o * limit_offset_sql(backend(), qs.limit, qs.offset)
    if !isempty(oparts)
        # Conditions on window annotations: compute them in a subquery (named like the base table,
        # so conditions on the model's own columns still resolve) and filter outside it.
        inner_sel = vcat(columns !== nothing || idonly ? [qname(c.base) * ".*"] : pre_ann, ann_sel)
        inner_ps = ann_ps
        inner = "SELECT $dkw$(join(inner_sel, ", ")) FROM $(qname(c.table))" *
                (c.base == c.table ? "" : " " * qname(c.base)) * join(c.joins) *
                (isempty(wparts) ? "" : " WHERE " * join(wparts, " AND ")) *
                (grouped && !isempty(group) ? " GROUP BY " * join(unique(group), ", ") : "") *
                (isempty(hparts) ? "" : " HAVING " * join(hparts, " AND "))
        outer_sel = idonly ? pk_select(c.base, T) : columns !== nothing ? columns : "*"
        sql = "SELECT $outer_sel FROM ($inner) AS $(qname(c.base)) WHERE " * join(oparts, " AND ") *
              o * limit_offset_sql(backend(), qs.limit, qs.offset)
        return sql, vcat(inner_ps, c.join_params, wps, hps, ops), c, related
    end
    if qs.for_update !== nothing && columns === nothing && !idonly && qs.values_fields === nothing
        sql *= for_update_sql(backend(), qs.for_update, c, related)
    end
    sql, vcat(sel_ps, c.join_params, wps, hps), c, related
end

"The `FOR UPDATE ...` clause of `select_for_update` (nothing on SQLite, which locks the whole database)."
function for_update_sql(b::DatabaseBackend, opts, c, related)
    occursin("SQLite", vendor(b)) && return ""
    s = " FOR UPDATE"
    if !isempty(opts.of)
        b isa PostgresBackend || throw(ArgumentError("select_for_update(of = ...) is only supported on PostgreSQL"))
        aliases = String[]
        for name in opts.of
            name = string(name)
            if name == "self"
                push!(aliases, qname(c.base))
            else
                i = findfirst(r -> join(string.(r[1]), "__") == name, related)
                i === nothing && throw(ArgumentError("select_for_update(of = ...): '$name' is not 'self' or a select_related path"))
                push!(aliases, qname(related[i][3]))
            end
        end
        s *= " OF " * join(aliases, ", ")
    end
    opts.nowait && (s *= " NOWAIT")
    opts.skip_locked && (s *= " SKIP LOCKED")
    s
end

"SQL for union/intersection/difference: the parts joined by the set operator, wrapped so the
result can be ordered and sliced the same way on every database."
function build_combined(@nospecialize(qs::QuerySet); columns = nothing, ordered = true, idonly = false)
    T = queryset_model(qs)
    op, parts, all_ = qs.combinator
    sqls, ps = String[], Any[]
    for p in parts
        sql, pp = select_sql(p; ordered = false)
        push!(sqls, sql); append!(ps, pp)
    end
    word = op === :union ? "UNION" : op === :intersection ? "INTERSECT" : "EXCEPT"
    inner = join(sqls, " $word$(all_ ? " ALL" : "") ")
    sel = idonly ? qname("id") : columns !== nothing ? replace(columns, r"^.*\." => "") : "*"
    order = String[]
    if ordered
        for o in qs.order
            name = lstrip(o, '-')
            f = name in ("id", "pk") ? nothing : findfield(modelmeta(T), Symbol(name))
            col = f === nothing || qs.values_fields !== nothing ? (name == "pk" ? "id" : name) : column(f)
            push!(order, qname(col) * (startswith(o, "-") ? " DESC" : " ASC"))
        end
    end
    sql = "SELECT $sel FROM ($inner) AS juango_combined" * (isempty(order) ? "" : " ORDER BY " * join(order, ", ")) *
          limit_offset_sql(backend(), qs.limit, qs.offset)
    sql, ps, SQLCompiler(T), Tuple{Vector{Symbol},Any,String}[]
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
    for f in all_fields(T)                       # inherited fields too (joined from the parent tables)
        data[attname(f)] = from_db(f, get(row, Symbol(prefix, column(f)), nothing))
    end
    obj
end

"Execute the query and return a `Vector` of model instances."
fetch(qs::QuerySet) = in_db(() -> fetch_here(qs), qs)

function fetch_here(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return Vector{T}(qs.cache)
    qs.for_update === nothing || in_atomic() ||
        throw(TransactionManagementError("select_for_update() must be evaluated inside atomic()"))
    qs.values_fields === nothing || return fetch_values(qs)
    qs.isnone && return T[]
    sql, ps, _, related = build_select(qs)
    rows = execute(sql, ps)
    plan = row_plan(T)
    objs = T[from_row(T, r, plan) for r in rows]
    foreach(set_instance_db!, objs)
    for (k, v) in qs.annotations, (o, r) in zip(objs, rows)
        is_filtered_relation(v) && continue
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
        for (k, v) in qs.annotations
            is_filtered_relation(v) || (d[k] = get(r, k, nothing))
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
        ids = unique([field_data(o, attname(f)) for o in objs if field_data(o, attname(f)) !== nothing])
        rel = isempty(ids) ? R[] : fetch(filter(something(qs, base_objects(R)); id__in = ids))
        byid = Dict(r.id => r for r in rel)
        for o in objs
            id = field_data(o, attname(f))
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
        push!(get!(() -> M[], groups, field_data(r, attname(rf))), r)
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
Base.count(qs::QuerySet) = in_db(() -> count_here(qs), qs)
function count_here(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return length(qs.cache)
    qs.isnone && return 0
    sql, ps = needs_wrapping(qs) ? select_sql(qs; ordered = false) : select_sql(qs; columns = pk_select(modelmeta(T).table, T), ordered = false)
    execute("SELECT COUNT(*) AS n FROM ($sql) AS juango_sub", ps)[1][:n]
end
Base.count(::Type{T}) where {T<:Model} = count(objects(T))
Base.length(qs::QuerySet) = count(qs)

"Whether any row matches."
exists(qs::QuerySet) = in_db(() -> exists_here(qs), qs)
function exists_here(qs::QuerySet{T}) where {T}
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

# --- only/defer, distinct, latest/earliest, in_bulk, dates, raw, explain -----------------------

function check_deferrable(T, names)
    own = Set(f.name for f in modelmeta(concrete_model(T)).fields)
    for n in names
        n in (:id, :pk) && throw(ArgumentError("the primary key can't be deferred"))
        n in own || throw(LookupError("$(nameof(T)) has no field '$n' that can be deferred"))
    end
end

"""
    defer(qs, :body, :notes)

Leave these fields out of the query; reading one later loads the object's deferred fields
with one more query. `defer(qs, nothing)` clears the list.
"""
function defer(qs::QuerySet{T}, fields...) where {T}
    fields == (nothing,) && return chain(qs; deferred = Symbol[])
    names = Symbol[Symbol(f) for f in fields]
    check_deferrable(T, names)
    chain(qs; deferred = unique(vcat(qs.deferred, names)))
end
defer(::Type{T}, fields...) where {T<:Model} = defer(objects(T), fields...)

"""
    only(qs, :title, :author)

(Extends `Base.only`.) Load only these fields (and the id); the others are deferred, as with `defer`.
"""
function Base.only(qs::QuerySet{T}, field::Union{Symbol,AbstractString}, fields::Union{Symbol,AbstractString}...) where {T}
    keep = Symbol[Symbol(field); Symbol.(collect(fields))]
    check_deferrable(T, keep)
    chain(qs; deferred = Symbol[f.name for f in modelmeta(concrete_model(T)).fields if !(f.name in keep)])
end
Base.only(::Type{T}, field::Union{Symbol,AbstractString}, fields::Union{Symbol,AbstractString}...) where {T<:Model} =
    only(objects(T), field, fields...)

"""
    distinct(qs)
    distinct(qs, :author, :published)     # PostgreSQL only: SELECT DISTINCT ON (...)

Remove duplicate rows (`SELECT DISTINCT`). With fields, keep the first row of each group of
equal values: order by those fields first.
"""
distinct(qs::QuerySet, fields::Union{Symbol,AbstractString}...) = chain(qs; distinct_fields = String[string(f) for f in fields])
distinct(::Type{T}, fields::Union{Symbol,AbstractString}...) where {T<:Model} = distinct(objects(T), fields...)

function latest_order(qs::QuerySet{T}, fields, what) where {T}
    fs = isempty(fields) ? get(modelmeta(T).extra, :get_latest_by, nothing) : fields
    fs === nothing && throw(ArgumentError("$what needs field names or Meta(get_latest_by = ...) on $(nameof(T))"))
    String[string(f) for f in (fs isa Union{Symbol,AbstractString} ? (fs,) : fs)]
end

"""
    latest(qs, :published)    earliest(qs, :published)

The object with the largest (smallest) value of the fields, which default to the model's
`Meta(get_latest_by = ...)`. Throws `DoesNotExist` when there are no objects.
"""
function latest(qs::QuerySet{T}, fields::Union{Symbol,AbstractString}...) where {T}
    order = [startswith(o, "-") ? o[2:end] : "-" * o for o in latest_order(qs, fields, "latest")]
    o = first(chain(qs; order = order))
    o === nothing && throw(DoesNotExist(T, "latest"))
    o
end
function earliest(qs::QuerySet{T}, fields::Union{Symbol,AbstractString}...) where {T}
    o = first(chain(qs; order = latest_order(qs, fields, "earliest")))
    o === nothing && throw(DoesNotExist(T, "earliest"))
    o
end
latest(::Type{T}, fields...) where {T<:Model} = latest(objects(T), fields...)
earliest(::Type{T}, fields...) where {T<:Model} = earliest(objects(T), fields...)

"""
    in_bulk(qs)                          # Dict id => object
    in_bulk(qs, [1, 2, 3])
    in_bulk(qs, ["a", "b"]; field_name = :slug)

The objects as a `Dict` keyed by `field_name` (which must be unique), optionally limited to
those keys.
"""
function in_bulk(qs::QuerySet{T}, keys = nothing; field_name = :id) where {T}
    field_name = Symbol(field_name)
    if !(field_name in (:id, :pk))
        f = findfield(modelmeta(T), field_name)
        (f !== nothing && f.unique) || throw(ArgumentError("in_bulk's field_name must be a unique field, not '$field_name'"))
    end
    field_name === :pk && (field_name = :id)
    keys !== nothing && isempty(keys) && return Dict{Any,T}()
    q = keys === nothing ? qs : filter(qs; Symbol(field_name, "__in") => collect(keys))
    Dict{Any,T}(getproperty(o, field_name) => o for o in fetch(q))
end
in_bulk(::Type{T}, keys = nothing; kw...) where {T<:Model} = in_bulk(objects(T), keys; kw...)

const DATE_KINDS = (:year, :month, :week, :day)
const DATETIME_KINDS = (:year, :month, :week, :day, :hour, :minute, :second)

function truncate_datetime(v, kind::Symbol)
    d = Date(v)
    kind === :year && return DateTime(Dates.year(d), 1, 1)
    kind === :month && return DateTime(Dates.year(d), Dates.month(d), 1)
    kind === :week && return DateTime(Dates.firstdayofweek(d))
    kind === :day && return DateTime(d)
    dt = DateTime(v)
    floor(dt, kind === :hour ? Dates.Hour : kind === :minute ? Dates.Minute : Dates.Second)
end

function distinct_dates(qs::QuerySet, field, kind, order, kinds, what)
    kind = Symbol(kind)
    kind in kinds || throw(ArgumentError("$what: kind must be one of $(join(kinds, ", ")), not :$kind"))
    order in (:asc, :desc) || throw(ArgumentError("$what: order must be :asc or :desc"))
    vals = DateTime[]
    for v in values_list(chain(qs; order = String[]), field; flat = true)
        v === nothing && continue
        v isa TimeZones.ZonedDateTime && (v = DateTime(localtime(v), TimeZones.Local))
        push!(vals, truncate_datetime(v, kind))
    end
    sort!(unique!(vals); rev = order === :desc)
end

"""
    dates(qs, :published, :month; order = :asc) -> Vector{Date}

The distinct dates, truncated to `:year`, `:month`, `:week` (starting Monday) or `:day`, on
which the objects' date or datetime field falls.
"""
dates(qs::QuerySet, field, kind = :day; order = :asc) =
    Date.(distinct_dates(qs, field, kind, order, DATE_KINDS, "dates"))
dates(::Type{T}, args...; kw...) where {T<:Model} = dates(objects(T), args...; kw...)

"""
    datetimes(qs, :created, :hour; order = :asc) -> Vector{DateTime}

Like `dates`, for a datetime field, truncated down to `:hour`, `:minute` or `:second` too.
Aware values are converted to the current time zone first.
"""
datetimes(qs::QuerySet, field, kind = :day; order = :asc) =
    distinct_dates(qs, field, kind, order, DATETIME_KINDS, "datetimes")
datetimes(::Type{T}, args...; kw...) where {T<:Model} = datetimes(objects(T), args...; kw...)

"""
    raw(Model, sql, params = [])

Run hand-written SQL (with `?` placeholders) and build model instances from the rows. The
rows must include `id`; fields missing from them are deferred, and extra columns become
attributes, like annotations.
"""
raw(::Type{T}, sql::AbstractString, params = Any[]; db = nothing) where {T<:Model} =
    with_db(() -> raw_here(T, sql, params), something(db, routed_db(T, false), Some(nothing)))
function raw_here(::Type{T}, sql::AbstractString, params = Any[]) where {T<:Model}
    rows = execute(sql, collect(Any, params))
    known = Set{Symbol}([:id; [attname(f) for f in all_fields(T)]])
    out = T[]
    plan = row_plan(T)
    for r in rows
        is_composite(T) || haskey(r, :id) || throw(ArgumentError("raw(): the query must select the id column"))
        o = set_instance_db!(from_row(T, r, plan))
        for (k, v) in r
            k in known || (getfield(o, :_data)[k] = v)
        end
        push!(out, o)
    end
    out
end

"""
    explain(qs) -> String

The database's query plan for the queryset (`EXPLAIN QUERY PLAN` on SQLite, `EXPLAIN` on
PostgreSQL and MySQL).
"""
explain(qs::QuerySet) = in_db(() -> explain_here(qs), qs)
function explain_here(qs::QuerySet)
    sql, ps = select_sql(qs)
    prefix = occursin("SQLite", vendor(backend())) ? "EXPLAIN QUERY PLAN " : "EXPLAIN "
    lines = String[]
    for r in execute(prefix * sql, ps)
        if haskey(r, :detail)
            push!(lines, string(r[:detail]))
        elseif length(r) == 1
            push!(lines, string(first(values(r))))
        else
            push!(lines, join(["$k=$(something(v, "NULL"))" for (k, v) in sort!(collect(r); by = first)], " "))
        end
    end
    join(lines, "\n")
end

# --- bulk_create, bulk_update, iterator, select_for_update, set operations ---------------------

struct TransactionManagementError <: Exception
    msg::String
end
Base.showerror(io::IO, e::TransactionManagementError) = print(io, "TransactionManagementError: ", e.msg)

"Prepare objects for a bulk insert as `save!` would: timestamps, UUID keys, uploaded files."
function prepare_for_insert!(objs, T)
    ts = timezone_now()
    for o in objs
        data = getfield(o, :_data)
        for f in all_fields(T)
            a = attname(f)
            if f.auto_now || (f.auto_now_add && get(data, a, nothing) === nothing)
                data[a] = f.kind === :date ? Date(ts isa TimeZones.ZonedDateTime ? make_naive(ts) : ts) : ts
            end
        end
        data[:id] === nothing && pk_kind(T) === :uuid && (data[:id] = uuid4())
        store_uploaded_files!(o, data)
    end
end

"""
    bulk_create(objs; batch_size, ignore_conflicts, update_conflicts, update_fields, unique_fields)

Insert many objects with multi-row INSERTs (no `save!`, no signals) and return them. New
ids are set on SQLite, PostgreSQL and MariaDB (not on MySQL, nor when conflicts are ignored
or updated).

- `ignore_conflicts = true` skips rows that break a unique constraint.
- `update_conflicts = true` updates `update_fields` of the existing row instead; PostgreSQL
  and SQLite also need the `unique_fields` that conflict.
"""
bulk_create(objs::AbstractVector{T}; db = nothing, kw...) where {T<:Model} =
    with_db(() -> (bulk_create_here(objs; kw...); foreach(set_instance_db!, objs); objs), something(db, routed_db(T, true), Some(nothing)))
function bulk_create_here(objs::AbstractVector{T}; batch_size = nothing, ignore_conflicts = false,
                     update_conflicts = false, update_fields = nothing, unique_fields = nothing) where {T<:Model}
    isempty(objs) && return objs
    table_parent(concrete_model(T)) === nothing ||
        throw(ArgumentError("bulk_create can't be used with multi-table inheritance ($(nameof(T)))"))
    ignore_conflicts && update_conflicts && throw(ArgumentError("bulk_create: pass ignore_conflicts or update_conflicts, not both"))
    b = backend()
    meta = modelmeta(concrete_model(T))
    fieldsof(names) = [let f = findfield(meta, Symbol(n)); f === nothing ? throw(LookupError("$(nameof(T)) has no field '$n'")) : f end
                       for n in names]
    conflict = ""
    if update_conflicts
        update_fields === nothing && throw(ArgumentError("bulk_create(update_conflicts = true) needs update_fields"))
        ups = [qname(column(f)) for f in fieldsof(update_fields)]
        if b isa MySQLBackend
            conflict = " ON DUPLICATE KEY UPDATE " * join(["$c = VALUES($c)" for c in ups], ", ")
        else
            unique_fields === nothing && throw(ArgumentError("bulk_create(update_conflicts = true) needs unique_fields on $(vendor(b))"))
            target = [Symbol(n) in (:id, :pk) ? qname("id") : qname(column(fieldsof([n])[1])) for n in unique_fields]
            conflict = " ON CONFLICT (" * join(target, ", ") * ") DO UPDATE SET " * join(["$c = EXCLUDED.$c" for c in ups], ", ")
        end
    elseif ignore_conflicts && !(b isa MySQLBackend)
        conflict = " ON CONFLICT DO NOTHING"
    end
    verb = ignore_conflicts && b isa MySQLBackend ? "INSERT IGNORE INTO" : "INSERT INTO"
    prepare_for_insert!(objs, T)
    fields = [f for f in meta.fields if f.generated === nothing]
    if isempty(fields)                       # nothing to put in VALUES: one row at a time
        foreach(o -> (save_table!(concrete_model(T), getfield(o, :_data), true); refresh_computed!(o)), objs)
        return objs
    end
    tbl = qname(meta.table)
    isdef(o, f) = get(getfield(o, :_data), attname(f), nothing) === DB_DEFAULT
    for with_id in (true, false)
        group = [o for o in objs if (getfield(o, :_data)[:id] !== nothing) == with_id]
        isempty(group) && continue
        n = batch_size === nothing ? max(1, 999 ÷ (length(fields) + 1)) : Int(batch_size)
        returning = !with_id && conflict == "" && verb == "INSERT INTO" && supports_insert_returning(b) && !is_composite(T)
        for batch in Iterators.partition(group, n)
            # db_default columns left out when no row of the batch sets them; DEFAULT where some do
            bf = [f for f in fields if !all(o -> isdef(o, f), batch)]
            if any(f -> any(o -> isdef(o, f), batch), bf) && occursin("SQLite", vendor(b))
                throw(ArgumentError("bulk_create on SQLite: give every object of a batch a value for a db_default field, or none"))
            end
            cols = vcat(with_id ? [qname("id")] : String[], [qname(column(f)) for f in bf])
            ps, rows_sql = Any[], String[]
            for o in batch
                data = getfield(o, :_data)
                marks = String[]
                with_id && (push!(ps, data[:id]); push!(marks, "?"))
                for f in bf
                    if isdef(o, f)
                        push!(marks, "DEFAULT")
                    else
                        push!(ps, to_db(f, get(data, attname(f), nothing))); push!(marks, "?")
                    end
                end
                push!(rows_sql, "(" * join(marks, ", ") * ")")
            end
            sql = isempty(cols) ? "$verb $tbl DEFAULT VALUES" :
                  "$verb $tbl (" * join(cols, ", ") * ") VALUES " * join(rows_sql, ", ") * conflict
            isempty(cols) && length(batch) > 1 && (foreach(o -> save_table!(concrete_model(T), getfield(o, :_data), true), batch); continue)
            if returning
                rows = execute(sql * " RETURNING " * qname("id"), ps)
                for (o, r) in zip(batch, rows)
                    getfield(o, :_data)[:id] = pk_value(T, r[:id])
                end
            else
                execute_changes(sql, ps)
            end
        end
        with_id && sync_sequence(b, meta.table)
    end
    is_composite(T) && foreach(o -> (getfield(o, :_data)[:id] = composite_pk(T, getfield(o, :_data))), objs)
    objs
end

"""
    bulk_update(objs, [:title, :views]; batch_size) -> Int

Write these fields of many saved objects with a few UPDATE statements (no `save!`, no
signals); returns the number of rows changed.
"""
bulk_update(objs::AbstractVector{T}, fields; db = nothing, kw...) where {T<:Model} =
    with_db(() -> bulk_update_here(objs, fields; kw...),
            isempty(objs) ? db : write_db(first(objs), db))
function bulk_update_here(objs::AbstractVector{T}, fields; batch_size = nothing) where {T<:Model}
    isempty(objs) && return 0
    names = Symbol[Symbol(f) for f in fields]
    isempty(names) && throw(ArgumentError("bulk_update needs at least one field"))
    flds = Field[]
    for n in names
        n in (:id, :pk) && throw(ArgumentError("bulk_update can't change the primary key"))
        f = findfield(modelmeta(T), n)
        f === nothing && (i = findfirst(g -> g.name === n, all_fields(T)); f = i === nothing ? nothing : all_fields(T)[i])
        (f === nothing || f.kind in (:m2m, :gfk, :grel)) && throw(LookupError("bulk_update: $(nameof(T)) has no concrete field '$n'"))
        f.generated === nothing || throw(ArgumentError("bulk_update: '$n' is generated by the database"))
        push!(flds, f)
    end
    any(o -> o.id === nothing, objs) && throw(ArgumentError("bulk_update: all objects must be saved first"))
    b = backend()
    cast(f) = b isa PostgresBackend ? "CAST(? AS $(column_type_for(b, column_state(f))))" : "?"
    total = 0
    bytable = Dict{String,Vector{Field}}()
    for f in flds
        push!(get!(bytable, modelmeta(f.model).table, Field[]), f)
    end
    for (table, tf) in bytable
        n = batch_size === nothing ? max(1, 900 ÷ (2 * length(tf) + 1)) : Int(batch_size)
        for batch in Iterators.partition(objs, n)
            sets, ps = String[], Any[]
            for f in tf
                push!(sets, qname(column(f)) * " = CASE " * qname("id") * join([" WHEN ? THEN " * cast(f) for _ in batch]) * " END")
                for o in batch
                    push!(ps, o.id, to_db(f, field_data(o, attname(f))))
                end
            end
            append!(ps, Any[o.id for o in batch])
            sql = "UPDATE $(qname(table)) SET " * join(sets, ", ") * " WHERE " * qname("id") * " IN (" * join(fill("?", length(batch)), ", ") * ")"
            total += execute_changes(sql, ps)
        end
    end
    total
end

struct QuerySetIterator
    qs::QuerySet
    chunk_size::Int
end

"""
    iterator(qs; chunk_size = 2000)

Iterate over a large queryset without loading it all: rows are fetched `chunk_size` at a
time (LIMIT/OFFSET pages, ordered with the id as a tie-breaker so pages don't overlap).
`prefetch_related` runs per chunk.
"""
function iterator(qs::QuerySet; chunk_size::Integer = 2000)
    chunk_size > 0 || throw(ArgumentError("chunk_size must be positive"))
    "?" in qs.order && throw(ArgumentError("iterator() can't page through a randomly ordered queryset"))
    order = default_order(qs)
    any(o -> lstrip(o, '-') in ("id", "pk"), order) || (order = vcat(order, ["id"]))
    QuerySetIterator(qs.combinator === nothing ? chain(qs; order = order) : qs, Int(chunk_size))
end
iterator(::Type{T}; kw...) where {T<:Model} = iterator(objects(T); kw...)
Base.IteratorSize(::Type{QuerySetIterator}) = Base.SizeUnknown()
Base.eltype(it::QuerySetIterator) = it.qs.values_fields === nothing ? model_of(it.qs) : Dict{Symbol,Any}
function Base.iterate(it::QuerySetIterator, st = (Any[], 1, 0, false))
    buf, i, pos, done = st
    if i > length(buf)
        done && return nothing
        buf = fetch(it.qs[pos+1:pos+it.chunk_size])
        isempty(buf) && return nothing
        i, pos, done = 1, pos + length(buf), length(buf) < it.chunk_size
    end
    buf[i], (buf, i + 1, pos, done)
end

"""
    select_for_update(qs; nowait = false, skip_locked = false, of = ())

Lock the selected rows until the end of the transaction (`SELECT ... FOR UPDATE`). Must be
evaluated inside `atomic()`. `nowait` fails instead of waiting for a lock, `skip_locked`
leaves locked rows out, and `of = ("self", "author")` (PostgreSQL) locks only those tables
of a `select_related` query. SQLite locks the whole database for a write transaction, so
there it only checks for the transaction.
"""
function select_for_update(qs::QuerySet; nowait = false, skip_locked = false, of = ())
    nowait && skip_locked && throw(ArgumentError("select_for_update: nowait and skip_locked can't both be set"))
    chain(qs; for_update = (nowait = nowait, skip_locked = skip_locked, of = collect(of)))
end
select_for_update(::Type{T}; kw...) where {T<:Model} = select_for_update(objects(T); kw...)

function combine(op, qs::QuerySet{T}, others; keep_all = false) where {T}
    isempty(others) && return qs
    parts = QuerySet[]
    for q in (qs, others...)
        model_of(q) === T || throw(ArgumentError("$op: all querysets must be of $(nameof(T))"))
        (q.limit === nothing && q.offset == 0) || throw(ArgumentError("$op: slice the combined queryset, not its parts"))
        isempty(q.related) || throw(ArgumentError("$op: select_related isn't supported in combined querysets"))
        if q.combinator !== nothing && q.combinator[1] === op && q.combinator[3] == keep_all
            append!(parts, q.combinator[2])          # (a ∪ b) ∪ c is one UNION of three parts
        else
            push!(parts, q)
        end
    end
    vf = first(parts).values_fields
    all(p -> p.values_fields == vf, parts) || throw(ArgumentError("$op: the querysets must select the same fields"))
    QuerySet{T}(Q[], String[], nothing, 0, false, Vector{Symbol}[], copy(qs.prefetch), nothing, nothing,
                Pair{Symbol,Any}[], vf, false, Symbol[], nothing, nothing, (op, parts, keep_all), qs.db)
end

"""
    union(qs, others...; all = false)
    intersection(qs, others...)
    difference(qs, others...)

Combine querysets of the same model with SQL `UNION`, `INTERSECT` or `EXCEPT` (`all = true`
keeps duplicates). The result can be ordered (by field names), sliced, counted and
iterated, but not filtered further. `values` querysets combine too.
"""
Base.union(qs::QuerySet, others::QuerySet...; all = false) = combine(:union, qs, others; keep_all = all)
intersection(qs::QuerySet, others::QuerySet...; all = false) = combine(:intersection, qs, others; keep_all = all)
difference(qs::QuerySet, others::QuerySet...; all = false) = combine(:difference, qs, others; keep_all = all)

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
update!(qs::QuerySet; kw...) = in_db(() -> update_here!(qs; kw...), qs, true)
function update_here!(qs::QuerySet{T}; kw...) where {T}
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
    sub, sps = select_sql(qs; columns = pk_select(meta.table, T), ordered = false)
    target = is_composite(T) ? "(" * join([qname(column(f)) for f in pk_fields(T)], ", ") * ")" : qname("id")
    execute_changes("UPDATE $(qname(meta.table)) SET $(join(sets, ", ")) WHERE $target IN ($(in_subquery(backend(), sub)))", vcat(ps, sps))
end

struct ProtectedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ProtectedError) = print(io, "ProtectedError: ", e.msg)

function delete_ids!(T::Type, ids::Vector)
    isempty(ids) && return 0
    T = concrete_model(T)
    delete_fobj_refs!(T, ids)
    is_composite(T) && return delete_composite!(T, ids)
    for g in generic_relations(T)    # objects pointing here through a GenericForeignKey
        M = related_model(g)
        ctf, fkf = g.through
        rel = filter(base_objects(M), Q(Symbol(ctf, :_id) => get_for_model(T).id), Q(Symbol(fkf, "__in") => ids))
        delete_ids!(M, row_keys(rel))
    end
    for C in child_models(T)        # rows of subclasses that extend these rows
        delete_ids!(C, values_list(filter(base_objects(C); id__in = ids), :id; flat = true))
    end
    for (_, M, f) in reverse_relations(T)
        rel = filter(base_objects(M), Q(Symbol(attname(f), "__in") => ids))
        if f.on_delete === :CASCADE
            delete_ids!(M, row_keys(rel))
        elseif f.on_delete === :SET_NULL
            update!(rel; Symbol(attname(f)) => nothing)
        elseif f.on_delete === :PROTECT
            exists(rel) && throw(ProtectedError("cannot delete $(nameof(T)) objects because they are referenced through protected foreign key $(nameof(M)).$(f.name)"))
        end
    end
    signal = has_receivers(pre_delete, T) || has_receivers(post_delete, T)
    doomed = signal ? fetch(filter(base_objects(T); id__in = ids)) : T[]
    foreach(o -> send(pre_delete, T; instance = o), doomed)
    n = 0
    for chunk in Iterators.partition(ids, 500)
        n += execute_changes("DELETE FROM $(qname(modelmeta(T).table)) WHERE $(qname("id")) IN (" *
                             join(fill("?", length(chunk)), ",") * ")", collect(chunk))
    end
    foreach(o -> send(post_delete, T; instance = o), doomed)
    P = table_parent(T)
    P === nothing || delete_ids!(P, ids)     # the parent rows these rows extend
    n
end

"The primary keys of a queryset's rows: ids, or tuples for a composite key."
row_keys(qs::QuerySet{T}) where {T} = is_composite(T) ? Any[o.pk for o in fetch(qs)] : values_list(qs, :id; flat = true)

"Delete rows of a model with a composite primary key (only ForeignObjects can refer to them; see `delete_fobj_refs!`)."
function delete_composite!(T::Type, keys::Vector)
    signal = has_receivers(pre_delete, T) || has_receivers(post_delete, T)
    doomed = signal ? fetch(filter(base_objects(T); pk__in = keys)) : T[]
    foreach(o -> send(pre_delete, T; instance = o), doomed)
    cond = join([qname(column(f)) * " = ?" for f in pk_fields(T)], " AND ")
    n = 0
    for k in keys
        n += execute_changes("DELETE FROM $(qname(modelmeta(T).table)) WHERE $cond", collect(Any, k))
    end
    foreach(o -> send(post_delete, T; instance = o), doomed)
    n
end

"Delete all matching rows (with `on_delete` handling for related objects). Returns the count."
Base.delete!(qs::QuerySet{T}) where {T} =
    in_db(() -> atomic(() -> delete_ids!(T, row_keys(qs))), qs, true)

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
function save!(obj::T; db = nothing) where {T<:Model}
    alias = write_db(obj, db)
    with_db(alias) do
        check_relations_db(obj)
        save_here!(obj)
        set_instance_db!(obj)
    end
end

"Where to write an object: `db`, else the enclosing `using_db` block, else where it came from, else the routers."
write_db(obj::Model, db) = db !== nothing ? db : db_pinned() ? nothing : something(instance_db(obj), routed_db(typeof(obj), true), Some(nothing))

"Refuse to save an object whose related objects (already loaded) live in another database."
function check_relations_db(obj::Model)
    me = current_alias()
    for (k, v) in getfield(obj, :_cache)
        v isa Model || continue
        other = instance_db(v)
        (other === nothing || other == me) && continue
        ok = ask_routers(allow_relation, obj, v)
        ok === true && continue
        throw(ArgumentError("$(nameof(typeof(obj))).$k is an object from database '$other'; this one is saved to '$me' " *
                            "(a router's allow_relation can permit it)"))
    end
end

function save_here!(obj::T) where {T<:Model}
    data = getfield(obj, :_data)
    ts = timezone_now()
    for f in all_fields(T)
        a = attname(f)
        if f.auto_now || (f.auto_now_add && (data[:id] === nothing || get(data, a, missing) === nothing))
            data[a] = f.kind === :date ? Date(ts isa TimeZones.ZonedDateTime ? make_naive(ts) : ts) : ts
        end
    end
    created = data[:id] === nothing
    has_receivers(pre_save, T) && send(pre_save, T; instance = obj, created = created)
    store_uploaded_files!(obj, data)
    chain_ = reverse(vcat([concrete_model(T)], ancestors(T)))     # root table first
    fresh = false
    if data[:id] === nothing && pk_kind(T) === :uuid
        data[:id] = uuid4()           # UUID keys are made here, so the row is inserted directly
        fresh = true
    end
    length(chain_) == 1 ? save_table!(chain_[1], data, true, fresh) :
        atomic(() -> foreach(M -> save_table!(M, data, M === chain_[1], fresh), chain_))
    refresh_computed!(obj)
    has_receivers(post_save, T) && send(post_save, T; instance = obj, created = created)
    obj
end

"Read back the values the database computed: generated fields, and db_default fields just filled in."
function refresh_computed!(obj::T) where {T<:Model}
    data = getfield(obj, :_data)
    fs = [f for f in all_fields(T) if f.generated !== nothing || get(data, attname(f), nothing) === DB_DEFAULT]
    isempty(fs) && return obj
    for tbl in unique(modelmeta(f.model).table for f in fs)
        mine = [f for f in fs if modelmeta(f.model).table == tbl]
        row = execute("SELECT " * join([qname(column(f)) for f in mine], ", ") * " FROM $(qname(tbl)) WHERE $(qname("id")) = ?", [data[:id]])
        isempty(row) && continue
        for f in mine
            data[attname(f)] = from_db(f, row[1][Symbol(column(f))])
        end
    end
    obj
end

"Write the columns of one table (`M`'s own fields) for an object's data."
function save_table!(M::Type, data, root::Bool, fresh::Bool = false)
    meta = modelmeta(M)
    # deferred fields keep their stored values; generated and not-yet-filled db_default ones are the database's
    fields = [f for f in meta.fields if haskey(data, attname(f)) && f.generated === nothing && data[attname(f)] !== DB_DEFAULT]
    cols = [qname(column(f)) for f in fields]
    vals = Any[to_db(f, data[attname(f)]) for f in fields]
    tbl = qname(meta.table)
    if is_composite(M)
        # Like a changed primary key elsewhere: saving under a new key writes a new row.
        key = composite_pk(M, data)
        key === nothing && throw(ArgumentError("$(nameof(M)): every part of the composite primary key needs a value"))
        if data[:id] !== nothing          # loaded or saved before: UPDATE, else (no such row) INSERT
            cond = join([qname(column(f)) * " = ?" for f in pk_fields(M)], " AND ")
            n = execute_changes("UPDATE $tbl SET " * join(["$c = ?" for c in cols], ", ") * " WHERE $cond", vcat(vals, collect(Any, key)))
            n > 0 && (data[:id] = key; return)
        end
        execute_changes(insert_sql(backend(), tbl, cols) |> s -> replace(s, r" RETURNING .*$" => ""), vals)
        data[:id] = composite_pk(M, data)
        return
    end
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
function Base.delete!(obj::T; db = nothing) where {T<:Model}
    id = obj.id
    id === nothing && error("cannot delete an unsaved $(T)")
    with_db(() -> atomic(() -> delete_ids!(T, [id])), write_db(obj, db))
    getfield(obj, :_data)[:id] = nothing
    obj
end

"Reload field values from the database."
function refresh!(obj::T) where {T<:Model}
    db = instance_db(obj)
    fresh = with_db(() -> get(base_objects(T); id = obj.id), db)
    merge!(getfield(obj, :_data), getfield(fresh, :_data))
    empty!(getfield(obj, :_cache))
    db === nothing || (getfield(obj, :_cache)[:__db] = db)
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
        (!f.blank && f.kind !== :bool) && push!(errs, gettext("This field is required."))
        return errs
    end
    if f.max_length !== nothing && v isa AbstractString && length(v) > f.max_length
        push!(errs, interpolate(gettext("Ensure this value has at most %(max)d characters (it has %(len)d)."), Dict("max" => f.max_length, "len" => length(v))))
    end
    f.kind === :email && !occursin(EMAIL_RE, string(v)) && push!(errs, gettext("Enter a valid email address."))
    f.kind === :slug && !occursin(SLUG_RE, string(v)) && push!(errs, gettext("Enter a valid “slug” consisting of letters, numbers, underscores or hyphens."))
    f.kind === :url && !occursin(URL_RE, string(v)) && push!(errs, gettext("Enter a valid URL."))
    if f.choices !== nothing && !any(c -> value_eq(c.first, v) || string(c.first) == string(v), f.choices)
        push!(errs, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v)))
    end
    for val in f.validators
        r = val(v)
        r isa AbstractString && push!(errs, r)
        r === false && push!(errs, gettext("Enter a valid value."))
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
        v === DB_DEFAULT && continue                  # the database supplies it
        errs = validate_field(f, v)
        if isempty(errs) && f.unique && v !== nothing
            q = filter(base_objects(f.model), Q(attname(f) => v))
            obj.id === nothing || (q = filter(q, !Q(id = obj.id)))
            exists(q) && push!(errs, interpolate(gettext("%(model)s with this %(field)s already exists."), Dict("model" => uppercasefirst(string(modelmeta(T).verbose_name)), "field" => label(f))))
        end
        isempty(errs) || (errors[f.name] = errs)
    end
    # constraints and unique_together, when their fields are clean and not excluded
    skip = Set(string.(union(exclude, keys(errors))))
    values = Dict{Symbol,Any}(f.name => field_data(obj, attname(f)) for f in all_fields(T) if !(string(f.name) in skip))
    errs = vcat(unique_together_errors(T, values, obj.id), constraint_errors(T, values, obj.id))
    isempty(errs) || append!(get!(errors, :__all__, String[]), errs)
    errors
end

"Messages for `Meta(unique_together = ...)` sets that `values` would duplicate."
function unique_together_errors(::Type{T}, values, id) where {T<:Model}
    errs = String[]
    for u in modelmeta(T).unique_together
        all(n -> haskey(values, n), u) || continue
        vals = [values[n] isa Model ? values[n].id : values[n] for n in u]
        any(isnothing, vals) && continue
        qs = filter(base_objects(T), Q(:AND, Any[n => v for (n, v) in zip(u, vals)], false))
        id === nothing || (qs = filter(qs, !Q(id = id)))
        exists(qs) && push!(errs, interpolate(gettext("%(model)s with this %(fields)s already exists."),
            Dict("model" => uppercasefirst(string(modelmeta(T).verbose_name)),
                 "fields" => join([label(findfield(modelmeta(T), n)) for n in u], " and "))))
    end
    errs
end


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
