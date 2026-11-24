# ORM: models: metadata, registry, @model, abstract models, instance properties --------------

mutable struct ModelMeta
    model::Type
    name::String
    table::String
    fields::Vector{Field}
    ordering::Vector{Any}            # strings ("-created") and OrderBy terms
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
const RELATION_CACHE = Dict{Symbol,IdDict{Any,Any}}()       # kind => model => value (no tuple key to build per lookup)
const RELATION_LOCK = ReentrantLock()
invalidate_relations!() = (lock(() -> empty!(RELATION_CACHE), RELATION_LOCK); nothing)
push!(SETTINGS_CHANGED_HOOKS, invalidate_relations!)
# (No closures over `T`: they'd capture its exact type, and compile again for every model.)
Base.@nospecializeinfer function cached_relations(@nospecialize(f), kind::Symbol, @nospecialize(T))
    lock(RELATION_LOCK)
    try
        byT = get(RELATION_CACHE, kind, nothing)
        byT === nothing && (byT = RELATION_CACHE[kind] = IdDict{Any,Any}())
        v = get(byT, T, NOTFOUND)
        v === NOTFOUND || return v
        return byT[T] = f(T)
    finally
        unlock(RELATION_LOCK)
    end
end

"""
App a model belongs to for migrations: `Meta(app_label=...)`, else `\"juango\"` for Juango's
built-in models, the label of the `App` whose module defines it, or `\"project\"`.
"""
default_app_label(T) = parentmodule(T) === (@__MODULE__) ? "juango" : something(module_app_label(parentmodule(T)), "project")

"Remove a model from the registry (mostly for tests that redefine models), with its many-to-many fields' automatic through models."
Base.@nospecializeinfer function unregister_model!(@nospecialize(T::Type))
    delete!(MODEL_REGISTRY, T)
    filter!(x -> x !== T, MODEL_LIST)
    # (an automatic through model with a foreign key to it would otherwise outlive it)
    for Th in [X for X in MODEL_LIST if X <: AutoThrough && any(f -> f.kind === :fk && f.related === T, modelmeta(X).fields)]
        delete!(MODEL_REGISTRY, Th)
        filter!(x -> x !== Th, MODEL_LIST)
    end
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
    meta.parent === nothing && return nothing
    # multi-table inheritance: the parent's fields too (a proxy of a multi-table child reaches them through it)
    findfield(modelmeta(meta.parent), name)
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

"""
The related model's field a foreign key stores, when not its id: its `to_field` (#220), or the related
model's natural primary key (`primary_key = true`, #221). `nothing` for an id.
"""
fk_to_field(f::Field) = getfield(f, :to_field) !== nothing ? getfield(f, :to_field) :
    f.kind === :fk && (R = related_model(f); natural_pk(R)) ? pk_fields(related_model(f))[1].name : nothing
"`child.parent = x`: `x` must be the related model (or a proxy, parent or child of it), as Django checks."
function check_related_assignment(f::Field, @nospecialize(T), @nospecialize(v::Model))
    R = related_model(f)
    a, b = concrete_model(R), concrete_model(typeof(v))
    (a === b || a in lineage(b) || b in lineage(a)) ||
        throw(ArgumentError("cannot assign $(repr(v)): \"$(nameof(T)).$(f.name)\" must be a \"$(nameof(R))\" instance"))
end
"The related model's field a foreign key stores: its id, or its `to_field` (#220)."
target_name(f::Field) = something(fk_to_field(f), :id)
"The related table's column a foreign key refers to (\"id\", or the `to_field`'s column)."
target_column(f::Field) = fk_to_field(f) === nothing ? "id" : column(getfield_meta(related_model(f), fk_to_field(f)))
"What a foreign key stores for the related object `v`: its id, or its `to_field` value."
# (the stored value: for a to_field that is itself a foreign key, such as a OneToOneField primary key, its id)
target_value(f::Field, v::Model) = fk_to_field(f) === nothing ? (getfield(v, :_data)::Dict{Symbol,Any})[:id] :
    field_data(v, attname(getfield_meta(related_model(f), fk_to_field(f))))

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
        # (verbose names are inherited too, as Django's abstract Meta: Meta(verbose_name_plural = "Audits"))
        meta = merge(Base.structdiff(metaS, NamedTuple{(:table, :name)}), meta)
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
        # (a form's DecimalField may leave these out; a column needs both, as Django's check fields.E130/E132)
        f.kind === :decimal && (f.max_digits === nothing || f.decimal_places === nothing) &&
            throw(ArgumentError("$T.$name: a model's DecimalField needs max_digits and decimal_places"))
        # related_name = "attached_%(class)s_set" (an abstract model's field): this model's name and app filled in
        for k in (:related_name, :related_query_name)
            v = getfield(f, k)
            v === nothing && continue
            str = string(v)
            occursin("%(", str) || continue
            app = string(get(meta, :app_label, default_app_label(T)))
            setfield!(f, k, Symbol(replace(str, "%(class)s" => lowercase(string(nameof(T))), "%(app_label)s" => lowercase(app))))
        end
        push!(f.kind === :m2m ? m2m : f.kind === :gfk ? gfks : f.kind === :grel ? grels : f.kind === :fobj ? fobjs : fs, f)
    end
    # Meta(constraints = [...]) names with %(app_label)s and %(class)s (an abstract model's constraints)
    if haskey(meta, :constraints) && any(c -> c isa Constraint && occursin("%(", c.name), meta.constraints)
        app = string(get(meta, :app_label, default_app_label(T)))
        meta = merge(meta, (constraints = Any[c isa Constraint ? constraint_for_model(c, app, nameof(T)) : c for c in meta.constraints],))
    end
    # Meta(indexes = [...]) names with %(app_label)s and %(class)s (an abstract model's indexes), as Django's
    if haskey(meta, :indexes) && any(ix -> ix isa Index && ix.name !== nothing && occursin("%(", ix.name), meta.indexes)
        app = lowercase(string(get(meta, :app_label, default_app_label(T))))
        meta = merge(meta, (indexes = Any[ix isa Index && ix.name !== nothing ?
            Index((n === :name ? replace(ix.name, "%(app_label)s" => app, "%(class)s" => lowercase(string(nameof(T)))) : getfield(ix, n)
                   for n in fieldnames(Index))...) : ix for ix in meta.indexes],))
    end
    # code = CharField(max_length = 10, primary_key = true): the key is that field, as Django's (#221)
    pkfs = [f for f in fs if f.primary_key]
    if !isempty(pkfs)
        length(pkfs) == 1 || error("$T: only one field can be primary_key = true (use Meta(pk = CompositePrimaryKey(...)))")
        haskey(meta, :pk) && error("$T: give primary_key = true or Meta(pk = ...), not both")
        parent === nothing || error("$T: a multi-table child can't have its own primary key field")
        pkfs[1].null = false; pkfs[1].db_index = false
        meta = merge(meta, (pk = CompositePrimaryKey(pkfs[1].name),))
    end
    # Meta(order_with_respect_to = :fk): a hidden `_order` column numbering the objects of each parent (Django's)
    owrt = get(meta, :order_with_respect_to, nothing)
    if owrt !== nothing
        k = findfirst(f -> f.name === Symbol(owrt) && f.kind === :fk, fs)
        k === nothing && error("$T: order_with_respect_to = :$owrt must name one of its foreign keys")
        # (no default: a new object is numbered when saved; bulk_create keeps an _order given by hand)
        of = Field(:int; default = nothing, editable = false, blank = true)
        of.name = :_order
        of.model = T
        push!(fs, of)
        haskey(meta, :ordering) || (meta = merge(meta, (ordering = ["_order"],)))
    end
    name = string(get(meta, :name, nameof(T)))
    vname = get(meta, :verbose_name, lowercase(replace(name, r"(?<=[a-z])(?=[A-Z])" => " ")))
    # the table: Meta(table = ...), else <app label>_<model name> as Django's (#240), shortened with a
    # hash past 63 bytes (PostgreSQL's limit for a name)
    app_label = string(get(meta, :app_label, default_app_label(T)))
    m = ModelMeta(T, name, string(get(meta, :table, constraint_name(lowercase(app_label), lowercase(name)))), fs,
                  Any[order_item(o) for o in get(meta, :ordering, String[])],
                  vname isa AbstractString ? vname : string(vname),
                  (vp = get(meta, :verbose_name_plural, nothing); vp === nothing ? string(vname) * "s" : vp isa AbstractString ? vp : string(vp)),
                  string(get(meta, :app_label, default_app_label(T))), m2m,
                  [Symbol.(collect(u)) for u in get(meta, :unique_together, [])],
                  parent, proxy,
                  Dict{Symbol,Any}(k => v for (k, v) in pairs(meta)
                                   if !(k in (:table, :name, :verbose_name, :verbose_name_plural, :ordering, :app_label,
                                              :unique_together, :_parent, :proxy))))
    m.extra[:field_order] = Symbol[name for (name, _) in fields]     # (as declared, many-to-many fields among them)
    isempty(gfks) || (m.extra[:generic_fks] = gfks)
    isempty(grels) || (m.extra[:generic_relations] = grels)
    isempty(fobjs) || (m.extra[:foreign_objects] = fobjs)
    proxy && (m.fields = modelmeta(parent).fields; m.m2m = modelmeta(parent).m2m)
    MODEL_REGISTRY[T] = m
    filter!(x -> !(x === T || modelmeta_or_nothing(x) === nothing ||
                   modelmeta(x).name == name && parentmodule(x) == parentmodule(T)), MODEL_LIST)
    push!(MODEL_LIST, T)
    invalidate_relations!()
    any_receivers(class_prepared) && send(class_prepared, T)
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
    table = something(getfield(f, :db_column), m.table * "_" * string(f.name))    # (ManyToManyField(...; db_table))
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
    if f.through_fields !== nothing           # through_fields = (:event, :invitee): which keys, as Django's
        return getfield_meta(Th, f.through_fields[1]), getfield_meta(Th, f.through_fields[2])
    end
    fks = [g for g in modelmeta(Th).fields if g.kind === :fk]
    # two keys to the same side (an inviter and an invitee) are ambiguous: Django refuses them without through_fields
    if owner !== target && (count(g -> related_model(g) === target, fks) > 1 || count(g -> related_model(g) === owner, fks) > 1)
        error("$(nameof(owner)).$(f.name): $(nameof(Th)) has more than one foreign key to $(nameof(count(g -> related_model(g) === target, fks) > 1 ? target : owner)); " *
              "say which with through_fields = (:to_$(lowercase(string(nameof(owner)))), :to_$(lowercase(string(nameof(target)))))")
    end
    owner === target && f.through !== nothing && count(g -> related_model(g) === owner, fks) > 2 &&
        error("$(nameof(owner)).$(f.name): $(nameof(Th)) has more than two foreign keys to $(nameof(owner)); say which with through_fields = (:source, :target)")
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
    something(default_related_name(fk.model),
              fk.one_to_one ? Symbol(lowercase(modelmeta(fk.model).name)) : Symbol(lowercase(modelmeta(fk.model).name), :_set))

"""
The model's `Meta(default_related_name = "...")`, the reverse name of its relations that don't name
one (Django's), with `%(class)s` (or `%(model_name)s`) and `%(app_label)s` filled in; `nothing` without it.
"""
Base.@nospecializeinfer function default_related_name(@nospecialize(M))
    M isa Type || return nothing
    m = modelmeta_or_nothing(M)
    m === nothing && return nothing
    d = get(m.extra, :default_related_name, nothing)
    d === nothing && return nothing
    Symbol(replace(string(d), "%(class)s" => lowercase(m.name), "%(model_name)s" => lowercase(m.name), "%(app_label)s" => lowercase(m.app)))
end

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
        push!(out, (f.related_name === nothing ? something(default_related_name(M), Symbol(lowercase(modelmeta(M).name), :_set)) : f.related_name, f, false))
    end
    # a multi-table child has its parents' relations too (its id is the parent row's id): child.related
    P = table_parent(T)
    if P !== nothing
        for r in m2m_relations(P)
            any(x -> x[1] === r[1], out) || push!(out, r)
        end
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
            string(something(f.related_query_name, f.related_name, default_related_name(f.model), Symbol(lowercase(modelmeta(f.model).name))))
        # (the accessor's name too, unless a related_query_name replaces it, as for reverse foreign keys)
        (q == name || (string(r[1]) == name && (r[3] || f.related_query_name === nothing))) && return r
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
    if !(d isa NoDefault)
        v = d isa Function || d isa Type ? d() : d
        # (a file field's default names a stored file: FileField(default = "default.txt"))
        return f.kind in FILE_KINDS && v isa AbstractString ? file_from_db(f, v) : v
    end
    f.null && return nothing
    (f.kind in STRING_KINDS || f.kind === :filepath) && return ""
    f.kind === :bool && return false
    nothing
end

Base.@nospecializeinfer function construct(@nospecialize(T::Type{<:Model}); kwargs...)
    any_receivers(pre_init) && send(pre_init, T; kwargs = Dict{Symbol,Any}(kwargs))
    meta = modelmeta(T)
    obj = T(Dict{Symbol,Any}(:id => nothing), Dict{Symbol,Any}())
    data = (getfield(obj, :_data)::Dict{Symbol,Any})
    kw = Dict{Symbol,Any}(kwargs)
    haskey(kw, :pk) && (kw[natural_pk(T) ? pk_fields(T)[1].name : :id] = pop!(kw, :pk))     # (a natural key's field)
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
    any_receivers(post_init) && send(post_init, T; instance = obj)
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
            # (a key to a proxy of this model, or of a parent, is a relation of it too, as Django)
            R = related_model(f)
            R in lin || any(L -> concrete_model(R) === concrete_model(L), lin) || continue
            push!(out, (reverse_name(f), M, f))
        end
    end
    out
end

"""
The foreign keys a deletion of `T`'s rows has to deal with: those pointing at `T`'s concrete model or
any proxy of it (`FooImage.my_image` to the proxy `Image` refers to `File`'s rows), or at a
multi-table ancestor's rows through `T`. (`reverse_relations` gives a model's own accessors.)
"""
Base.@nospecializeinfer deletion_referrers(@nospecialize(T::Type)) = cached_relations(compute_deletion_referrers, :delref, T)
Base.@nospecializeinfer function compute_deletion_referrers(@nospecialize(T::Type))
    out = Tuple{Symbol,Any,Field}[]
    C = concrete_model(T)
    for M in MODEL_LIST
        (modelmeta(M).proxy || !model_in_use(M)) && continue
        for f in modelmeta(M).fields
            f.kind === :fk || continue
            concrete_model(related_model(f)) === C || continue
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
    load_deferred!(m)              # (all the deferred fields, in one query: Django loads one at a time)
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
        (c !== nothing && target_value(f, c) == id) && (note_eager_use(T, s); return c)
        sib = get(cache, :__siblings, nothing)
        if sib !== nothing                               # AUTO_PREFETCH: load it for the whole queryset at once
            auto_prefetch!(sib, f, s, instance_db(m))
            c = get(cache, s, nothing)
            c === nothing || return c
        end
        note_lazy_load(T, s, :fk, m)
        obj = with_db(() -> get(base_objects(related_model(f)); (target_name(f) => id,)...), instance_db(m))
        cache[s] = obj
        f.one_to_one && ((getfield(obj, :_cache)::Dict{Symbol,Any})[reverse_name(f)] = PrefetchedList(Any[m]))   # (r.place.restaurant: no query)
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
        return pre isa PrefetchedList ? chain(qs; cache = pre.items, owner = qs.owner) : qs
    end
    mm = find_m2m(T, string(s))
    if mm !== nothing
        qs = m2m_queryset(m, mm[2], mm[3], s)
        pre isa PrefetchedList && (note_eager_use(T, s); return chain(qs; cache = pre.items, owner = qs.owner))
        note_lazy_load(T, s, :reverse, m)
        return qs
    end
    for (rn, M, rf) in reverse_relations(T)
        rn === s || continue
        # an unsaved object's related manager can't be queried, as Django's (4.1+) (#274); a key whose (to_field)
        # value is still NULL has no related rows; add! asks for a value
        base = !rf.one_to_one && getproperty(m, :pk) === nothing ?
                   filter(objects(M), Q(:AND, Any[UnsavedRelation("'$(nameof(T))' instance needs to have a primary key value before this relationship can be used.")], false)) :
               target_value(rf, m) === nothing ? none(M) : filter(objects(M), Q(attname(rf) => target_value(rf, m)))
        qs = chain(base; db = instance_db(m),
                   owner = rf.one_to_one ? nothing : ReverseFKOwner(rf, M, m, rn),
                   known = target_value(rf, m) === nothing ? nothing : Dict{Symbol,Dict{Any,Any}}(rf.name => Dict{Any,Any}(target_value(rf, m) => m)))
        if rf.one_to_one
            pre isa PrefetchedList && (note_eager_use(T, s); return isempty(pre.items) ? nothing : pre.items[1])
            note_lazy_load(T, s, :fk, m)
            r = first(qs)
            # remembered either way (a missing one too: no second query), and the other side points back
            (getfield(m, :_cache)::Dict{Symbol,Any})[s] = PrefetchedList(r === nothing ? Any[] : Any[r])
            r === nothing || ((getfield(r, :_cache)::Dict{Symbol,Any})[rf.name] = m)
            return r
        end
        pre isa PrefetchedList && (note_eager_use(T, s); return chain(qs; cache = pre.items, owner = qs.owner))
        note_lazy_load(T, s, :reverse, m)
        return qs
    end
    for C in child_models(T)
        child_accessor(C) === s || continue
        # prefetch_related(:child) or select_related(:child): the child, or nothing
        pre isa PrefetchedList && return isempty(pre.items) ? nothing : pre.items[1]
        pre === NOTFOUND || return pre
        c = first(filter(base_objects(C); id = data[:id]))
        # the parent's loaded relations go with it (grand_parent.parent.place: no query), as Django
        if c !== nothing
            ccache = getfield(c, :_cache)::Dict{Symbol,Any}
            for (k, v) in getfield(m, :_cache)::Dict{Symbol,Any}
                (startswith(string(k), "__") || haskey(ccache, k) || mti_child(T, k) !== nothing) && continue
                ccache[k] = v
            end
        end
        return c
    end
    if table_parent(T) !== nothing && s === parent_accessor(T)
        pre === NOTFOUND || return pre
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
    rg = find_reverse_generic(T, s)          # link.targets (a GenericRelation's related_query_name): its owners
    rg === nothing || return filter(objects(rg[1]), Q(rg[2].name => m))
    throw(ArgumentError("$(T) has no attribute '$s'"))
end

Base.@nospecializeinfer function Base.setproperty!(@nospecialize(m::Model), s::Symbol, @nospecialize(v))
    data = (getfield(m, :_data)::Dict{Symbol,Any})
    # (pk = ... on a model with a natural primary key sets that field, as Django)
    s === :pk && (s = natural_pk(typeof(m)) ? pk_fields(typeof(m))[1].name : :id)
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
            check_related_assignment(f, typeof(m), v)
            f.one_to_one && ((getfield(v, :_cache)::Dict{Symbol,Any})[reverse_name(f)] = PrefetchedList(Any[m]))
            # an unsaved object's key isn't known yet (a to_field may hold a value it will change): taken at save
            data[attname(f)] = (getfield(v, :_data)::Dict{Symbol,Any})[:id] === nothing ? nothing : target_value(f, v)
            (getfield(m, :_cache)::Dict{Symbol,Any})[s] = v
        else
            data[attname(f)] = v
        end
        return v
    end
    if f === nothing && s !== :id && (v isa Model || v === nothing)
        # place.restaurant = r: the reverse side of a one-to-one points r's key at place (not saved), as Django;
        # = nothing clears the key of the one it had (if loaded), which the caller then saves
        for (rn, R, rf) in reverse_relations(typeof(m))
            (rn === s && rf.one_to_one) || continue
            cache = (getfield(m, :_cache)::Dict{Symbol,Any})
            if v === nothing
                old = get(cache, s, nothing)
                old isa PrefetchedList && !isempty(old.items) && setproperty!(old.items[1], rf.name, nothing)
                cache[s] = PrefetchedList(Any[])
            else
                a, b = concrete_model(R), concrete_model(typeof(v))
                (a === b || a in lineage(b) || b in lineage(a)) ||
                    throw(ArgumentError("cannot assign $(repr(v)): \"$(nameof(typeof(m))).$s\" must be a \"$(nameof(R))\" instance"))
                setproperty!(v, rf.name, m)
                cache[s] = PrefetchedList(Any[v])
            end
            return v
        end
    end
    if f === nothing && s !== :id
        tattr!(m, Val(s), v) === NOTFOUND && throw(ArgumentError(
            "$(typeof(m)) has no field '$s' (for a value that isn't saved use Juango.instance_cache(obj)[:$s] = v; " *
            "for a computed attribute define Juango.tattr!(::$(nameof(typeof(m))), ::Val{:$s}, v))"))
        return v
    end
    f !== nothing && f.kind === :m2m &&
        throw(ArgumentError("direct assignment to the many-to-many set '$s' is prohibited: use set!(obj.$s, ...) instead"))
    # parent.bestchild_id = x: a cached bestchild for another key is dropped (as Django), so it isn't saved back
    if f !== nothing && f.kind === :fk && s === attname(f)
        cache = (getfield(m, :_cache)::Dict{Symbol,Any})
        c = get(cache, f.name, nothing)
        (c isa Model && (v === nothing || target_value(f, c) != v)) && delete!(cache, f.name)
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
    s in (cached_relations(property_set, :propertyset, typeof(m))::Set{Symbol}) || extra_value(m, s) !== NOTFOUND ||
    haskey((getfield(m, :_data)::Dict{Symbol,Any}), s)          # an annotation or extra() value the row has (#190)
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

# (a proxy and its concrete model are equal for the same key, as Django; a multi-table parent and child aren't)
Base.@nospecializeinfer Base.:(==)(@nospecialize(a::Model), @nospecialize(b::Model)) =
    concrete_model(typeof(a)) === concrete_model(typeof(b)) && a.id !== nothing && a.id == b.id
"""
    copy(obj)

Another instance with the same field values (Django's `copy.copy(instance)`): its loaded related
objects aren't shared, so pointing the copy's key elsewhere leaves the original alone.
"""
Base.@nospecializeinfer function Base.copy(@nospecialize(m::Model))
    c = typeof(m)(copy(getfield(m, :_data)::Dict{Symbol,Any}), Dict{Symbol,Any}())
    db = get(getfield(m, :_cache)::Dict{Symbol,Any}, :__db, nothing)
    db === nothing || ((getfield(c, :_cache)::Dict{Symbol,Any})[:__db] = db)
    c
end
Base.@nospecializeinfer Base.hash(@nospecialize(m::Model), h::UInt) = m.id === nothing ? objectid(m) ⊻ h : hash((concrete_model(typeof(m)), m.id), h)
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

"""
    absolute_url(obj)

`obj`'s URL: `settings.ABSOLUTE_URL_OVERRIDES["app.model"](obj)` when that's set for its model (the label in
lowercase, as Django's), else its `get_absolute_url` (`nothing` without one). What Juango's own code calls.
"""
function absolute_url(@nospecialize(x))
    if x isa Model
        ov = get(settings, :ABSOLUTE_URL_OVERRIDES, nothing)
        if ov !== nothing && !isempty(ov)
            f = get(ov, lowercase(model_label(typeof(x))), nothing)
            f === nothing || return f(x)
        end
    end
    applicable(get_absolute_url, x) ? get_absolute_url(x) : nothing
end
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
    u = absolute_url(m)
    u === nothing ? NOTFOUND : u
end
Base.@nospecializeinfer tattr(@nospecialize(m::Model), ::Val{:verbose_name}) = modelmeta(typeof(m)).verbose_name
Base.@nospecializeinfer tattr(@nospecialize(m::Model), ::Val{:pk_string}) = pk_string(m)
