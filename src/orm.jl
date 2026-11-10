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
end

normchoices(::Nothing) = nothing
normchoices(cs) = Pair{Any,String}[c isa Pair ? (c.first => string(c.second)) : (c => string(c)) for c in cs]

function Field(kind::Symbol; null = false, blank = false, default = NO_DEFAULT, unique = false,
               max_length = nothing, choices = nothing, related = nothing, on_delete = :CASCADE,
               related_name = nothing, auto_now = false, auto_now_add = false, verbose_name = "",
               help_text = "", validators = Any[], widget = nothing, editable = true,
               db_index = false, required = nothing, label = nothing)
    required === nothing || (blank = !required)
    label === nothing || (verbose_name = string(label))
    if auto_now || auto_now_add
        editable = false
        blank = true
    end
    Field(kind, :_, null, blank, default, unique, max_length, normchoices(choices), related,
          Symbol(uppercase(string(on_delete))), related_name === nothing ? nothing : Symbol(related_name),
          auto_now, auto_now_add, string(verbose_name), string(help_text), collect(Any, validators),
          widget === nothing ? nothing : Symbol(widget), editable, db_index, nothing)
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
    nothing
end
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
    fs = Field[]
    for (name, f) in fields
        f isa Field || error("$T.$name must be a field (CharField(...), ForeignKey(...), ...)")
        f = deepcopy(f)
        f.name = name
        f.model = T
        name in (:id, :pk) && error("$T: '$name' is reserved for the automatic primary key")
        push!(fs, f)
    end
    name = string(nameof(T))
    vname = get(meta, :verbose_name, lowercase(replace(name, r"(?<=[a-z])(?=[A-Z])" => " ")))
    m = ModelMeta(T, name, string(get(meta, :table, lowercase(name))), fs,
                  String[string(o) for o in get(meta, :ordering, String[])],
                  string(vname), string(get(meta, :verbose_name_plural, vname * "s")),
                  string(get(meta, :app_label, default_app_label(T))))
    MODEL_REGISTRY[T] = m
    filter!(x -> !(x === T || string(nameof(x)) == name && parentmodule(x) == parentmodule(T)), MODEL_LIST)
    push!(MODEL_LIST, T)
    T
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
    name = expr.args[2]
    name isa Expr && name.head === :(<:) && (name = name.args[1])
    name isa Symbol || error("@model: unsupported struct name $(name)")
    fieldpairs = Expr[]
    metaexpr = :(NamedTuple())
    for line in expr.args[3].args
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
    M = GlobalRef(@__MODULE__, :Model)
    structdef = Expr(:struct, true, Expr(:(<:), name, M),
                     Expr(:block, :(_data::Dict{Symbol,Any}), :(_cache::Dict{Symbol,Any})))
    quote
        $(esc(structdef))
        $(esc(name))(; kwargs...) = $(GlobalRef(@__MODULE__, :construct))($(esc(name)); kwargs...)
        $(GlobalRef(@__MODULE__, :register_model!))($(esc(name)), Pair{Symbol,Any}[$(fieldpairs...)], $metaexpr)
        $(esc(name))
    end
end

function default_value(f::Field)
    d = f.default
    d isa NoDefault || return d isa Function ? d() : d
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
    for f in meta.fields
        if haskey(kw, f.name)
            setproperty!(obj, f.name, pop!(kw, f.name))
        elseif f.kind === :fk && haskey(kw, attname(f))
            data[attname(f)] = pop!(kw, attname(f))
        else
            data[attname(f)] = default_value(f)
        end
    end
    isempty(kw) || throw(ArgumentError("$T got unexpected field(s): $(join(keys(kw), ", "))"))
    obj
end

"Reverse FK relations pointing at model `T`: Vector of (name, Model, Field)."
function reverse_relations(T::Type)
    out = Tuple{Symbol,Any,Field}[]
    for M in MODEL_LIST
        for f in modelmeta(M).fields
            f.kind === :fk || continue
            related_model(f) === T || continue
            rn = f.related_name === nothing ? Symbol(lowercase(string(nameof(M))), :_set) : f.related_name
            push!(out, (rn, M, f))
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
        obj = get(objects(related_model(f)); id = id)
        cache[s] = obj
        return obj
    end
    cache = getfield(m, :_cache)
    pre = get(cache, s, NOTFOUND)
    for (rn, M, rf) in reverse_relations(T)
        rn === s || continue
        qs = filter(objects(M), Q(attname(rf) => data[:id]))
        pre isa PrefetchedList && return QuerySet{M}(qs.where, qs.order, nothing, 0, false, Vector{Symbol}[], Prefetch[], pre.items)
        return qs
    end
    pre === NOTFOUND || return pre isa PrefetchedList ? pre.items : pre    # Prefetch(...; to_attr)
    r = tattr(m, Val(s))
    r === NOTFOUND || return r
    throw(ArgumentError("$(T) has no attribute '$s'"))
end

function Base.setproperty!(m::Model, s::Symbol, v)
    data = getfield(m, :_data)
    s === :pk && (s = :id)
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
    meta = modelmeta(typeof(m))
    names = Symbol[:id, :pk]
    for f in meta.fields
        push!(names, attname(f))
        f.kind === :fk && push!(names, f.name)
    end
    append!(names, first.(reverse_relations(typeof(m))))
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
    k = f.kind
    k === :bool && return v isa Bool ? v : v != 0
    k === :int && return v isa Integer ? Int(v) : parse(Int, string(v))
    k === :fk && return Int(v)
    k === :float && return Float64(v)
    k === :datetime && return v isa DateTime ? v : something(todatetime(v), v)
    k === :date && return v isa Date ? v : Date(todatetime(v))
    v isa AbstractString ? String(v) : v
end

to_db(f::Field, v::Model) = v.id
to_db(f::Field, v) = dbparam(v)

function from_row(::Type{T}, row::Dict{Symbol,Any}) where {T<:Model}
    obj = T(Dict{Symbol,Any}(:id => row[:id]), Dict{Symbol,Any}())
    data = getfield(obj, :_data)
    for f in modelmeta(T).fields
        data[attname(f)] = from_db(f, get(row, attname(f), nothing))
    end
    obj
end

# --- Q objects & lookups -------------------------------------------------------------------

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
                     "year", "month", "day", "ne"])


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
    base::String                # unquoted table name; base columns are "table"."col"
    joins::Vector{String}
    aliases::Dict{Any,String}   # (parent alias, relation, scope) => alias
    leftjoined::Set{String}
    counter::Base.RefValue{Int}
    distinct::Bool
    scope::Int
end
SQLCompiler(T::Type) = SQLCompiler(T, modelmeta(T).table, String[], Dict{Any,String}(), Set{String}(), Ref(0), false, 0)

new_alias!(c::SQLCompiler) = (c.counter[] += 1; "j$(c.counter[])")
qcol(alias, col) = qname(alias) * "." * qname(col)

"Join `table` (as a new alias) to `parent` on child.`childcol` = parent.`parentcol`; reuse an existing join for `key`."
function join!(c::SQLCompiler, parent, key, table, childcol, parentcol; left::Bool)
    haskey(c.aliases, key) && return c.aliases[key]
    a = new_alias!(c)
    left = left || parent in c.leftjoined
    left && push!(c.leftjoined, a)
    push!(c.joins, " $(left ? "LEFT OUTER" : "INNER") JOIN $(qname(table)) $(qname(a)) ON $(qcol(a, childcol)) = $(qcol(parent, parentcol))")
    c.aliases[key] = a
end

function find_reverse(T::Type, name)
    for (rn, M, rf) in reverse_relations(T)
        (string(rn) == name || lowercase(string(nameof(M))) == name) && return (rn, M, rf)
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
    if fname == "id"
        isempty(rest) || throw(LookupError("'id' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        col = qcol(alias, "id")
    else
        f = findfield(meta, Symbol(fname))
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
        if !isempty(rest)
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
            sql, ps = select_sql(value; columns = qcol(modelmeta(model_of(value)).table, "id"))
            return ("$col IN ($sql)", ps)
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
        sql, ps = ch isa Q ? compile_q(c, alias, T, ch, neg) : compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
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
    cache::Union{Nothing,Vector}        # results already known (prefetched reverse relations)
end
QuerySet{T}(where, order, limit, offset, isnone) where {T} =
    QuerySet{T}(where, order, limit, offset, isnone, Vector{Symbol}[], Prefetch[], nothing)

model_of(::QuerySet{T}) where {T} = T

"All objects of model `T` as a `QuerySet`."
objects(::Type{T}) where {T<:Model} = QuerySet{T}(Q[], String[], nothing, 0, false)
"An empty queryset."
none(::Type{T}) where {T<:Model} = QuerySet{T}(Q[], String[], nothing, 0, true)
none(qs::QuerySet{T}) where {T} = none(T)

"A new queryset with some parts replaced. Cached results never carry over."
function chain(qs::QuerySet{T}; where = qs.where, order = qs.order, limit = qs.limit, offset = qs.offset,
               related = qs.related, prefetch = qs.prefetch) where {T}
    QuerySet{T}(where, order, limit, offset, qs.isnone, related, prefetch, nothing)
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
function Base.filter(qs::QuerySet{T}, qargs::Q...; kw...) where {T}
    assert_unsliced(qs, "filter")
    (isempty(qargs) && isempty(kw)) && return chain(qs)
    w = copy(qs.where)
    push!(w, Q(:AND, Any[qargs..., (k => v for (k, v) in kw)...], false))
    chain(qs; where = w)
end
Base.filter(::Type{T}, qargs::Q...; kw...) where {T<:Model} = filter(objects(T), qargs...; kw...)

"Exclude rows matching the lookups."
function exclude(qs::QuerySet{T}, qargs::Q...; kw...) where {T}
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
        segs = split(lstrip(o, '-'), "__")
        alias, M = c.base, T
        for s in segs[1:end-1]     # follow forward FKs: order_by("author__name")
            f = findfield(modelmeta(M), Symbol(s))
            (f !== nothing && f.kind === :fk) || throw(LookupError("cannot order $T by '$o': '$s' is not a foreign key of $M"))
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = true)
            M = related_model(f)
        end
        name = segs[end]
        col = if name in ("id", "pk")
            qcol(alias, "id")
        else
            f = findfield(modelmeta(M), Symbol(name))
            f === nothing && throw(LookupError("cannot order $T by unknown field '$o'"))
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
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = f.null)
            M = related_model(f)
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
    build_select(qs; columns=nothing, ordered=true) -> (sql, params, compiler, related)

The SELECT for a queryset. `columns` replaces the default `table.*` (plus `select_related`
columns).
"""
function build_select(qs::QuerySet{T}; columns = nothing, ordered = true) where {T}
    c = SQLCompiler(T)
    w, ps = where_clause(c, qs)
    related, rcols = columns === nothing ? related_columns!(c, qs.related) : (Tuple{Vector{Symbol},Any,String}[], String[])
    o, extra = ordered ? order_clause(c, qs.order) : ("", String[])
    sel = join(vcat([something(columns, qname(c.base) * ".*")], rcols, extra), ", ")
    sql = "SELECT $(c.distinct ? "DISTINCT " : "")$sel FROM $(qname(c.base))$(join(c.joins))$w$o" *
          limit_offset_sql(backend(), qs.limit, qs.offset)
    sql, ps, c, related
end

function select_sql(qs::QuerySet; columns = nothing, ordered = true)
    sql, ps, _, _ = build_select(qs; columns = columns, ordered = ordered)
    sql, ps
end

"Build a model from columns labelled `prefix*column` (as produced for `select_related`)."
function from_prefixed_row(::Type{T}, row, prefix) where {T<:Model}
    id = get(row, Symbol(prefix, "id"), nothing)
    id === nothing && return nothing
    obj = T(Dict{Symbol,Any}(:id => id), Dict{Symbol,Any}())
    data = getfield(obj, :_data)
    for f in modelmeta(T).fields
        data[attname(f)] = from_db(f, get(row, Symbol(prefix, column(f)), nothing))
    end
    obj
end

"Execute the query and return a `Vector` of model instances."
function fetch(qs::QuerySet{T}) where {T}
    qs.cache === nothing || return Vector{T}(qs.cache)
    qs.isnone && return T[]
    sql, ps, _, related = build_select(qs)
    rows = execute(sql, ps)
    objs = T[from_row(T, r) for r in rows]
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
        rel = isempty(ids) ? R[] : fetch(filter(something(qs, objects(R)); id__in = ids))
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
    sql, ps = select_sql(qs; columns = qcol(modelmeta(T).table, "id"), ordered = false)
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
    values(qs, fields...) -> Vector{Dict{Symbol,Any}}

Rows as dicts (all concrete columns if no fields given).
"""
function Base.values(qs::QuerySet{T}, fields::Symbol...) where {T}
    objs = fetch(qs)
    names = isempty(fields) ? vcat([:id], [attname(f) for f in modelmeta(T).fields]) : collect(fields)
    [Dict{Symbol,Any}(n => getproperty(o, n) for n in names) for o in objs]
end

"`values_list(qs, :field; flat=true)` → `Vector` of values; otherwise vector of tuples."
function values_list(qs::QuerySet, fields::Symbol...; flat = false)
    objs = fetch(qs)
    if flat
        length(fields) == 1 || throw(ArgumentError("flat=true requires exactly one field"))
        return [getproperty(o, fields[1]) for o in objs]
    end
    [Tuple(getproperty(o, f) for f in fields) for o in objs]
end

"""
    aggregate(qs, func, field)

SQL aggregate over a column: `func` is `:count`, `:sum`, `:avg`, `:min` or `:max`.
"""
function aggregate(qs::QuerySet{T}, func::Symbol, field::Symbol) where {T}
    func in (:count, :sum, :avg, :min, :max) || throw(ArgumentError("unknown aggregate $func"))
    tbl = modelmeta(T).table
    col = qcol(tbl, field in (:id, :pk) ? "id" : column(getfield_meta(T, field)))
    sql, ps = select_sql(qs; columns = qcol(tbl, "id"), ordered = false)
    execute("SELECT $(uppercase(string(func)))($col) AS r FROM $(qname(tbl)) WHERE $(qcol(tbl, "id")) IN ($sql)", ps)[1][:r]
end

"""
    update!(qs; field=value, ...) -> Int

Bulk SQL UPDATE of all matching rows; returns the number of rows changed.
Does not call `save!` or touch `auto_now` fields.
"""
function update!(qs::QuerySet{T}; kw...) where {T}
    qs.isnone && return 0
    meta = modelmeta(T)
    sets, ps = String[], Any[]
    for (k, v) in kw
        f = getfield_meta(T, k)
        push!(sets, qname(column(f)) * " = ?")
        push!(ps, to_db(f, v))
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
    for (_, M, f) in reverse_relations(T)
        rel = filter(objects(M), Q(Symbol(attname(f), "__in") => ids))
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
    meta = modelmeta(T)
    data = getfield(obj, :_data)
    ts = now()
    for f in meta.fields
        a = attname(f)
        if f.auto_now || (f.auto_now_add && (data[:id] === nothing || data[a] === nothing))
            data[a] = f.kind === :date ? Date(ts) : ts
        end
    end
    cols = [qname(column(f)) for f in meta.fields]
    vals = Any[to_db(f, data[attname(f)]) for f in meta.fields]
    tbl = qname(meta.table)
    if data[:id] !== nothing
        n = isempty(cols) ? length(execute("SELECT 1 FROM $tbl WHERE $(qname("id")) = ?", [data[:id]])) :
            execute_changes("UPDATE $tbl SET " * join(["$c = ?" for c in cols], ", ") * " WHERE $(qname("id")) = ?",
                            vcat(vals, data[:id]))
        n > 0 && return obj
        execute_insert(insert_sql(backend(), tbl, vcat(qname("id"), cols)), vcat(data[:id], vals))
        sync_sequence(backend(), meta.table)
        return obj
    end
    data[:id] = execute_insert(insert_sql(backend(), tbl, cols), vals)
    obj
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
    fresh = get(objects(T); id = obj.id)
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
    for f in modelmeta(T).fields
        (f.name in exclude || !f.editable) && continue
        v = getproperty(obj, attname(f))
        errs = validate_field(f, v)
        if isempty(errs) && f.unique && v !== nothing
            q = filter(objects(T), Q(attname(f) => v))
            obj.id === nothing || (q = filter(q, !Q(id = obj.id)))
            exists(q) && push!(errs, "$(uppercasefirst(modelmeta(T).verbose_name)) with this $(label(f)) already exists.")
        end
        isempty(errs) || (errors[f.name] = errs)
    end
    errors
end
