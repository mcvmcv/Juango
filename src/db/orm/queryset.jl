# --- QuerySet --------------------------------------------------------------------------

"""
Lazy, chainable database query. Created by `objects(Model)` / `filter(Model; ...)`.
Iterate it, `collect` it, index it (`qs[1]`, `qs[1:10]`), or call `count`,
`first`, `exists`, `values`, `update!`, `delete!` on it.
"""
struct QuerySet{T<:Model}
    where::Vector{Q}                    # one entry per filter()/exclude() call
    order::Vector{Any}                  # "field" / "-field" strings and OrderBy terms (Asc, Desc)
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
    annotated_after::Dict{Symbol,Int}              # annotation => filter() calls before it (it reuses their joins)
    values_mode::Symbol                            # values() rows: :dict; values_list: :tuple, :named or :flat
    group_fields::Union{Nothing,Vector{String}}    # values(...) |> annotate(aggregate): the GROUP BY it fixed (#201)
    aliases::Vector{Symbol}                        # annotations made by alias(): usable, not selected (#207)
end
QuerySet{T}(where, order, limit, offset, isnone) where {T} =
    QuerySet{T}(where, order, limit, offset, isnone, Vector{Symbol}[], Prefetch[], nothing, nothing,
                Pair{Symbol,Any}[], nothing, false, Symbol[], nothing, nothing, nothing, nothing, Dict{Symbol,Int}(), :dict, nothing, Symbol[])

"""
    using_db(qs, "replica")

The queryset, run against another database (a key of `DATABASES`). Objects it returns
remember it: saving them and following their relations use the same database.
"""
using_db(qs::QuerySet, alias) = chain(qs; db = string(alias))
Base.@nospecializeinfer using_db(@nospecialize(T::Type{<:Model}), alias) = using_db(objects(T), alias)
using_db(alias::Union{AbstractString,Symbol}) = qs -> using_db(qs, alias)

"The database a queryset runs on (`nothing`: the current one)."
Base.@nospecializeinfer query_db(@nospecialize(qs::QuerySet), write::Bool = false) = qs.db !== nothing ? qs.db : routed_db(model_of(qs), write)
"Run `f()` on the queryset's database."
Base.@nospecializeinfer in_db(f, @nospecialize(qs::QuerySet), write::Bool = false) = with_db(f, query_db(qs, write))

"The database an object was loaded from or saved to (`nothing` if neither yet)."
Base.@nospecializeinfer instance_db(@nospecialize(m::Model)) = get((getfield(m, :_cache)::Dict{Symbol,Any}), :__db, nothing)
Base.@nospecializeinfer set_instance_db!(@nospecialize(m::Model)) = ((getfield(m, :_cache)::Dict{Symbol,Any})[:__db] = current_alias(); m)

model_of(::QuerySet{T}) where {T} = T

"""
    objects(Model) -> QuerySet

All objects of a model through its default queryset, `default_queryset(Model)`.
`objects(Model, :name)` returns a named queryset defined with `Juango.manager`.
"""
Base.@nospecializeinfer objects(@nospecialize(T::Type{<:Model})) = default_queryset(T)

"""
    base_objects(Model) -> QuerySet

Every row of the table, ignoring `default_queryset`. Foreign-key access, cascading
deletes and uniqueness checks use this, like Django's base manager.
"""
Base.@nospecializeinfer base_objects(@nospecialize(T::Type{<:Model})) = QuerySet{T}(Q[], String[], nothing, 0, false)

"""
    default_queryset(::Type{Model})

Override to change what `objects(Model)`, `filter(Model; ...)`, the admin and reverse
relations see, for example to hide soft-deleted rows. Build on `base_objects`:

    Juango.default_queryset(::Type{Post}) = filter(base_objects(Post); deleted = false)
"""
Base.@nospecializeinfer default_queryset(@nospecialize(T::Type{<:Model})) = base_objects(T)

"""
    manager(::Type{Model}, ::Val{name})

Define a named queryset, available as `objects(Model, :name)`:

    Juango.manager(::Type{Post}, ::Val{:published}) = filter(Post; status = "p")
"""
manager(::Type{T}, ::Val{N}) where {T,N} = throw(ArgumentError("$T has no manager named :$N (define Juango.manager(::Type{$T}, ::Val{:$N}))"))
Base.@nospecializeinfer objects(@nospecialize(T::Type{<:Model}), name::Symbol) = manager(T, Val(name))
"An empty queryset."
Base.@nospecializeinfer none(@nospecialize(T::Type{<:Model})) = QuerySet{T}(Q[], String[], nothing, 0, true)
none(qs::QuerySet{T}) where {T} = none(T)

"""
A new queryset with some parts replaced. Cached results and the many-to-many context
never carry over (unless passed explicitly).
"""
#
# Most queryset functions take `@nospecialize(qs)` under `@nospecializeinfer`: they're compiled
# and inferred once (in the precompile workload) for every model, instead of again for each of
# the project's models on its first request. A queryset's model is `model_of(qs)`.
Base.@nospecializeinfer function chain(@nospecialize(qs::QuerySet); kw...)
    vals = Any[haskey(kw, f) ? kw[f] : f in (:cache, :owner) ? nothing : getfield(qs, f) for f in QS_FIELDS]
    QuerySet{model_of(qs)}(vals...)::QuerySet
end
const QS_FIELDS = fieldnames(QuerySet)

"""
    select_related(qs, :author, :author__profile)

Fetch the objects behind forward foreign keys in the same query (with JOINs), so
`post.author` needs no extra query. Paths follow FKs with `__`.
"""
function select_related(@nospecialize(qs::QuerySet), paths...)
    T = model_of(qs)
    qs.values_fields === nothing || throw(ArgumentError("select_related() can't follow values() or values_list()"))
    paths == (nothing,) && return chain(qs; related = Vector{Symbol}[])      # select_related(qs, nothing) clears, as Django's None
    rel = copy(qs.related)
    for p in paths
        segs = Symbol.(split(string(p), "__"))
        M = T
        for s in segs
            f = findfield(modelmeta(M), s)
            if f !== nothing && f.kind === :fk && f.name === s
                M = related_model(f)
                continue
            end
            r = reverse_one_to_one(M, s)          # the other side of a OneToOneField: at most one row
            r === nothing && throw(LookupError("select_related: '$s' is not a foreign key or reverse one-to-one of $M " *
                                               "(use prefetch_related for other reverse relations)"))
            M = r[2]
        end
        segs in rel || push!(rel, segs)
    end
    chain(qs; related = rel)
end
select_related(@nospecialize(T::Type{<:Model}), paths...) = select_related(objects(T), paths...)
select_related(paths::Union{AbstractString,Symbol}...) = qs -> select_related(qs, paths...)

"""
    prefetch_related(qs, :comment_set, :author, Prefetch(:comments; queryset=..., to_attr=:approved))

After fetching, load related objects with one extra query per lookup: reverse relations
(`author.post_set`, `post.comments`) and forward FKs. `__` follows relations further
(`:comments__author`). Prefetched reverse relations answer `count`, iteration, `first`
and `exists` from memory; further filtering queries the database again.
"""
prefetch_related(@nospecialize(qs::QuerySet), lookups...) =
    lookups == (nothing,) ? chain(qs; prefetch = Prefetch[]) :         # prefetch_related(qs, nothing) clears, as Django's None
    chain(qs; prefetch = vcat(qs.prefetch, Prefetch[l isa Prefetch ? l : Prefetch(l) for l in lookups]))
prefetch_related(@nospecialize(T::Type{<:Model}), lookups...) = prefetch_related(objects(T), lookups...)
prefetch_related(lookups::Union{AbstractString,Symbol,Prefetch}...) = qs -> prefetch_related(qs, lookups...)

Base.@nospecializeinfer function assert_uncombined(@nospecialize(qs::QuerySet), what)
    qs.combinator === nothing ||
        throw(ArgumentError("cannot $what the result of union/intersection/difference; filter the querysets before combining them"))
end

Base.@nospecializeinfer function assert_unsliced(@nospecialize(qs::QuerySet), what)
    (qs.limit === nothing && qs.offset == 0) || error("cannot $what a queryset once it has been sliced")
end

"""
    filter(qs_or_Model, q::Q...; lookups...)

Keep rows matching all lookups (`field`, `field__lookup`, `fk__field__lookup`).
Lookups: exact iexact contains icontains startswith istartswith endswith
iendswith gt gte lt lte in isnull range year month day ne.
"""
function Base.filter(@nospecialize(qs::QuerySet), qargs::Union{Q,Expression}...; kw...)
    assert_unsliced(qs, "filter")
    assert_uncombined(qs, "filter")
    (isempty(qargs) && isempty(kw)) && return chain(qs)
    w = copy(qs.where)
    q = Q(:AND, Any[qargs..., (k => v for (k, v) in kw)...], false)
    push!(w, q)
    # a condition that can't match (id__in = []): no rows, without a query, as Django's EmptyResultSet (#224)
    chain(qs; where = w, isnone = qs.isnone || cannot_match(q))
end
"Whether a condition can never match: an `__in` with no values, in an AND, or in every branch of an OR."
function cannot_match(q::Q)
    q.negated && return false               # (NOT of an impossible condition matches every row)
    q.connector === :XOR && return false
    kids = Bool[ch isa Q ? (!empty_q(ch) && cannot_match(ch)) :
                ch isa Pair && endswith(string(ch.first), "__in") && ch.second isa Union{AbstractArray,Tuple,AbstractSet} &&
                all(v -> v === nothing, ch.second) for ch in q.children if !(ch isa Q && empty_q(ch))]
    q.connector === :OR ? !isempty(kids) && all(kids) : any(kids)
end
Base.filter(@nospecialize(T::Type{<:Model}), qargs::Union{Q,Expression}...; kw...) = filter(objects(T), qargs...; kw...)
Base.filter(qargs::Union{Q,Expression}...; kw...) = qs -> filter(qs, qargs...; kw...)

"Exclude rows matching the lookups."
function exclude(@nospecialize(qs::QuerySet), qargs::Union{Q,Expression}...; kw...)
    assert_unsliced(qs, "exclude")
    assert_uncombined(qs, "exclude")
    (isempty(qargs) && isempty(kw)) && return chain(qs)
    w = copy(qs.where)
    push!(w, Q(:AND, Any[qargs..., (k => v for (k, v) in kw)...], true))
    chain(qs; where = w)
end
exclude(@nospecialize(T::Type{<:Model}), qargs::Q...; kw...) = exclude(objects(T), qargs...; kw...)

"""
    qs1 | qs2
    qs1 & qs2

Querysets of one model combined into one query (Django's `|` and `&`): `|` matches the rows
either matches (an OR of their conditions, not a UNION), `&` those both match. The result keeps
the left queryset's ordering, annotations and options. Sliced and combined (union) querysets,
and a values() queryset with a model one, can't be combined.
"""
# qs1 | qs2[1:1]: a sliced queryset takes part as `pk__in` its rows, as Django's | and ^ do
unslice_for_combining(@nospecialize(q::QuerySet)) = (q.limit === nothing && q.offset == 0) || q.isnone ? q :
    filter(base_objects(model_of(q)); pk__in = q)
function Base.:|(a::QuerySet, b::QuerySet)
    sa, sb = unslice_for_combining(a), unslice_for_combining(b)
    sa === a || (sa = chain(sa; order = a.order))         # (the left side's ordering stays)
    a, b = sa, sb
    check_combinable(a, b, "|")
    (a.isnone || b.isnone) && return a.isnone ? b : a
    (isempty(a.where) || isempty(b.where)) && return chain(a; where = Q[])          # one matches every row
    either = Q(:OR, Any[Q(:SCOPES, Any[a.where...], false), Q(:SCOPES, Any[b.where...], false)], false)
    chain(a; where = Q[either])
end
"qs1 ⊻ qs2: the rows exactly one of them matches (Django's ^)."
function Base.xor(a::QuerySet, b::QuerySet)
    sa, sb = unslice_for_combining(a), unslice_for_combining(b)
    sa === a || (sa = chain(sa; order = a.order))
    a, b = sa, sb
    check_combinable(a, b, "xor")
    a.isnone && return b
    b.isnone && return a
    chain(a; where = Q[xor(Q(:SCOPES, Any[a.where...], false), Q(:SCOPES, Any[b.where...], false))])
end
function Base.:&(a::QuerySet, b::QuerySet)
    check_combinable(a, b, "&")
    chain(a; where = vcat(a.where, b.where), isnone = a.isnone || b.isnone)
end
function check_combinable(@nospecialize(a::QuerySet), @nospecialize(b::QuerySet), op)
    model_of(a) === model_of(b) ||
        throw(ArgumentError("cannot combine querysets of two different models ($(nameof(model_of(a))) $op $(nameof(model_of(b))))"))
    for q in (a, b)
        assert_unsliced(q, "combine ($op)")
        assert_uncombined(q, "combine ($op)")
    end
    (a.values_fields === nothing) == (b.values_fields === nothing) ||
        throw(ArgumentError("cannot combine ($op) a values() queryset with a model queryset"))
end

"""
    reverse(qs)

The queryset in the opposite order (Django's `qs.reverse()`): each `order_by` term flipped, or
the model's `Meta(ordering = ...)` flipped when there's no `order_by`. A queryset without any
ordering stays unordered.
"""
function Base.reverse(@nospecialize(qs::QuerySet))
    assert_unsliced(qs, "reverse")
    order = order_cleared(qs) ? Any[] : isempty(qs.order) ? Any[modelmeta(model_of(qs)).ordering...] : qs.order
    isempty(order) && return chain(qs)
    flip(o) = o isa AbstractString ? (o == "?" ? o : startswith(o, "-") ? o[2:end] : "-" * o) :
              o isa OrderBy ? OrderBy(o.expr, !o.descending, o.nulls_first === nothing ? nothing : !o.nulls_first) : o
    chain(qs; order = Any[flip(o) for o in order])
end

"""
    order_by(qs, "field", "-other", ...)
    qs |> order_by("-created")

Order the results. Prefix with `-` for descending, `\"?\"` for random order.
"""
order_by(@nospecialize(qs::QuerySet), fields...) =
    (assert_unsliced(qs, "order_by"); chain(qs; order = isempty(fields) ? Any[NO_ORDER] : Any[order_item(f) for f in fields]))
order_by(@nospecialize(T::Type{<:Model}), fields...) = order_by(objects(T), fields...)
order_by(fields::Union{AbstractString,Symbol}...) = qs -> order_by(qs, fields...)

"`order_by()` with no fields: no ordering at all, not even the model's `Meta(ordering = ...)` (as Django)."
struct NoOrder end
const NO_ORDER = NoOrder()
"Whether the queryset's ordering was cleared with `order_by()`."
Base.@nospecializeinfer order_cleared(@nospecialize(qs::QuerySet)) = length(qs.order) == 1 && qs.order[1] isa NoOrder

"""
An ordering term that ends at a foreign key (`"author"`, `"-note"`), as Django orders it: by the
related model's Meta.ordering (`"-note__note"`), each term's direction flipped for `-`; by the key
itself when that model has no ordering. Other terms are returned as they are.
"""
function expand_fk_ordering(@nospecialize(T::Type), o::AbstractString, depth::Int = 0, seen::Vector{Any} = Any[])
    desc = startswith(o, "-")
    path = lstrip(o, '-')
    segs = split(path, "__")
    M = T
    f = nothing
    for s in segs
        f = findfield(modelmeta(M), Symbol(s))
        f !== nothing && f.kind === :fk || return [String(o)]       # not a path of foreign keys: as it is
        M = related_model(f)
    end
    R = M
    ord = modelmeta(R).ordering
    (isempty(ord) || !all(x -> x isa AbstractString, ord)) && return [String(o)]
    # LoopX ordered by y, LoopY by x: Django's "Infinite loop caused by ordering"
    R in seen && throw(LookupError("infinite loop caused by ordering: $(nameof(T)) by '$path' comes back to $(nameof(R))'s Meta(ordering)"))
    out = String[]
    for r in ord
        rdesc = startswith(r, "-")
        term = (desc ⊻ rdesc ? "-" : "") * path * "__" * lstrip(r, '-')
        append!(out, expand_fk_ordering(T, term, depth + 1, Any[seen; R]))
    end
    out
end

"""
ORDER BY clause plus extra SELECT columns (needed with DISTINCT when ordering by joined columns).
With no ordering given, the model's `Meta(ordering = ...)` applies when `meta_ordering` is true.
"""
function order_clause(c::SQLCompiler, order::Vector; meta_ordering::Bool = true, add_cols::Bool = false)
    T = c.T
    length(order) == 1 && order[1] isa NoOrder && return "", String[], Any[]
    isempty(order) && meta_ordering && (order = modelmeta(T).ordering)
    isempty(order) && return "", String[], Any[]
    # order_by("author") and Meta(ordering = ["-note"]): the related model's ordering, as Django
    order = Any[x for o in order for x in (o isa AbstractString && o != "?" && !haskey(c.annotations, Symbol(lstrip(o, '-'))) ?
                                            expand_fk_ordering(T, o) : Any[o])]
    parts, extra, ps = String[], String[], Any[]
    for o in order
        if o isa OrderBy                          # an expression (Asc, Desc), with joins as needed
            sql, ops = compile_order_item(c, o; by_alias = true)
            push!(parts, sql); append!(ps, ops)
            continue
        end
        o == "?" && (push!(parts, random_function(backend())); continue)
        desc = startswith(o, "-")
        if haskey(c.annotations, Symbol(lstrip(o, '-'))) && !is_filtered_relation(c.annotations[Symbol(lstrip(o, '-'))])
            if Symbol(lstrip(o, '-')) in c.alias_names        # alias(): not selected, so its expression
                sql, aps = compile_expr(c, F(lstrip(o, '-')))
                push!(parts, sql * (desc ? " DESC" : " ASC")); append!(ps, aps)
            else
                push!(parts, qname(lstrip(o, '-')) * (desc ? " DESC" : " ASC"))
            end
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
            if f !== nothing && f.kind === :json         # order_by("data__run"): a key inside a JSON field
                push!(parts, json_order_sql(backend(), qcol(field_alias!(c, alias, M, f), column(f)), String.(segs[i+1:end]), desc))
                @goto next_order
            end
            if f === nothing || f.kind !== :fk
                # a reverse relation or a many-to-many (order_by("article__headline")): joined as values() joins
                # it, one row per related row, as Django (#209)
                f === nothing || throw(LookupError("cannot order $T by '$o': '$s' is not a relation of $M"))
                col = first(resolve_path(c, alias, M, join(segs[i:end], "__")))
                alias = ""
                @goto ordered_col
            end
            alias = field_alias!(c, alias, M, f)
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, target_column(f), column(f); left = true)
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
            if f === nothing           # order_by("categoryitem"): a reverse relation, by the related row's key
                rc = first(resolve_path(c, alias, M, name))
                alias = ""
                rc
            else
                alias = field_alias!(c, alias, M, f)
                qcol(alias, column(f))
            end
        end
        @label ordered_col
        if (alias != c.base && c.distinct) || add_cols
            push!(extra, "$col AS $(qname("__order$(length(extra) + 1)"))")
        end
        push!(parts, col * (desc ? " DESC" : " ASC"))
        @label next_order
    end
    " ORDER BY " * join(parts, ", "), extra, ps
end

Base.@nospecializeinfer function where_clause(c::SQLCompiler, @nospecialize(qs::QuerySet))
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
        left = false
        for (i, s) in enumerate(path)
            f = findfield(modelmeta(M), s)
            if f === nothing                      # reverse one-to-one: LEFT JOIN other.fk = this.id
                _, R, rf = reverse_one_to_one(M, s)
                left = true
                alias = join!(c, alias, (alias, s, :rev), modelmeta(R).table, column(rf), target_column(rf); left = true)
                M = R
            else
                left = left || f.null
                alias = field_alias!(c, alias, M, f)
                alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, target_column(f), column(f); left = left)
                M = related_model(f)
            end
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
                palias = join!(c, palias, (palias, :__parent), modelmeta(P).table, "id", "id"; left = left)
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
Base.@nospecializeinfer function build_select(@nospecialize(qs::QuerySet); columns = nothing, ordered = true, outer = nothing, idonly = false)
    T = queryset_model(qs)
    qs.combinator === nothing || return build_combined(qs; columns = columns, ordered = ordered, idonly = idonly)
    c = SQLCompiler(T; outer = outer)
    for (k, v) in qs.annotations
        c.annotations[k] = v
    end
    union!(c.alias_names, qs.aliases)
    grouped = any(p -> contains_aggregate(p.second), qs.annotations)
    # WHERE is compiled first, so values() and annotations can reuse its joins (its SQL still goes after them)
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
    # select list first: it may add joins, and its parameters come first in the SQL
    sel, sel_ps = String[], Any[]
    related = Tuple{Vector{Symbol},Any,String}[]
    group = String[]
    group_ps = Dict{String,Vector{Any}}()     # the parameters of a GROUP BY entry that has some
    if idonly
        push!(sel, pk_select(c.base, T))
    elseif columns !== nothing
        push!(sel, columns)
    elseif qs.values_fields !== nothing
        for f in qs.values_fields
            if haskey(c.annotations, Symbol(f))
                a = c.annotations[Symbol(f)]
                # values(annotate(qs; m = TruncMonth(:created)), :m): group by the computed value (its alias)
                is_filtered_relation(a) || aggregating(a, qs.annotations) || push!(group, qname(string(f)))
                continue
            end
            c.reuse_upto = length(qs.where)               # a value read through a filtered relation uses its join
            col, _ = resolve_path(c, c.base, T, f)
            c.reuse_upto = 0
            push!(sel, "$col AS $(qname(f))")
            push!(group, col)
        end
        if qs.group_fields !== nothing              # grouped by the values() an aggregate followed, not the latest
            group = String[]
            for f in qs.group_fields
                if haskey(c.annotations, Symbol(f))
                    a = c.annotations[Symbol(f)]
                    is_filtered_relation(a) || aggregating(a, qs.annotations) || push!(group, qname(f))
                else
                    c.reuse_upto = length(qs.where)    # the filter's join, as the SELECT uses it (#225)
                    push!(group, first(resolve_path(c, c.base, T, f)))
                    c.reuse_upto = 0
                end
            end
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
    # values() rows have only the fields asked for: an annotation made before values() is selected only
    # when values() names it, the GROUP BY uses it or the query is ordered by it (#201)
    vsel = qs.values_fields === nothing || columns !== nothing || idonly ? nothing :
           Set{String}(vcat(qs.values_fields, something(qs.group_fields, String[]),
                            [lstrip(o, '-') for o in qs.order if o isa AbstractString],
                            [o.expr.name for o in qs.order if o isa OrderBy && o.expr isa F]))
    for (k, v) in qs.annotations
        (is_filtered_relation(v) || k in qs.aliases) && continue           # alias(): not selected, not grouped by
        vsel === nothing || string(k) in vsel || contains_window(v) || continue      # (a window one may be filtered on, outside)
        # ordered by but neither asked for nor an aggregate: grouped by too, as Django adds it
        if vsel !== nothing && (grouped || qs.group_fields !== nothing) && !aggregating(v, qs.annotations) && !(string(k) in qs.values_fields) &&
           (qs.group_fields === nothing || !(string(k) in qs.group_fields))
            push!(group, qname(string(k)))
        end
        # an annotation made after filter() calls reuses their joins of the same relations (as in
        # Django), so Count(:book) after filter(book__shelf = 1) counts the books on that shelf
        c.reuse_upto = get(qs.annotated_after, k, 0)
        c.outer_refs = String[]
        sql, p = compile_expr(c, v)
        # a subquery annotation that reads the outer query (OuterRef(:book__name), across joins) is grouped by,
        # as Django does: PostgreSQL refuses the joined table's columns in it otherwise (#219). By its value,
        # not the columns it reads: those would split an object's group by each related row.
        if grouped && qs.values_fields === nothing && columns === nothing && !idonly && !isempty(c.outer_refs) &&
           !aggregating(v, qs.annotations) && !(sql in group)
            push!(group, sql); group_ps[sql] = p
        end
        c.outer_refs = nothing
        if grouped && aggregating(v, qs.annotations)
            # Sum(:age) + F(:age), Coalesce(:min_age, :contact__age): the fields read outside the aggregates are
            # grouped by too, as Django does (PostgreSQL requires it); compiled here, so they use the same joins
            for r in bare_refs(v)
                a = get(c.annotations, Symbol(r), nothing)
                a === nothing || !aggregating(a, qs.annotations) || continue
                g = a === nothing ? first(compile_expr(c, F(r))) : qname(r)
                g in group || push!(group, g)
            end
        end
        c.reuse_upto = 0
        push!(ann_sel, "$sql AS $(qname(string(k)))")
        append!(ann_ps, p)
    end
    if columns === nothing && !idonly
        if qs.values_fields !== nothing
            # values() rows group by an annotation's position in the select list, not its alias: the alias can
            # be ambiguous, a column of a joined table with the same name (Django does the same)
            ord = Dict{String,String}()
            for (i, s) in enumerate(ann_sel)
                m = match(r" AS (\S+)$", s)
                m === nothing || (ord[m[1]] = string(length(sel) + i))
            end
            group = [get(ord, g, g) for g in group]
        end
        append!(sel, ann_sel)
        append!(sel_ps, ann_ps)
    end
    if grouped && columns !== nothing && !idonly && qs.values_fields === nothing
        group = [pk_select(c.base, T)]
    end
    # As Django ≥ 3.1, a query that groups (an aggregate annotate) ignores the model's Meta.ordering: its columns
    # would join ORDER BY, which PostgreSQL refuses for values() groups (and they'd change the groups). An explicit
    # order_by still applies.
    # objects are made distinct after a multi-valued join; values() rows aren't (as in Django, equal rows
    # are all returned, and PostgreSQL would refuse ORDER BY on columns not selected)
    distinct = ((c.distinct && qs.values_fields === nothing) || qs.distinct_fields !== nothing) && !grouped
    # distinct(values(...)) leaves Meta.ordering out too: its columns aren't selected, so PostgreSQL refuses the
    # ORDER BY (and Django's way, selecting them, makes the rows no longer distinct). An explicit order_by applies.
    # distinct(values(:misc)) ordered by note: the ordering's columns are selected too (and rows are distinct
    # over them), as Django does; PostgreSQL requires it, and the rows leave them out
    o, extra, ops_order = ordered ? order_clause(c, qs.order; meta_ordering = !grouped && !(distinct && qs.values_fields !== nothing),
                                                 add_cols = distinct && columns === nothing && !idonly) :
                                    ("", String[], Any[])
    (columns === nothing && !idonly && !grouped) && append!(sel, extra)
    gps = grouped ? Any[x for g in unique(group) for x in get(group_ps, g, Any[])] : Any[]
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
        return sql, vcat(inner_ps, c.join_params, wps, gps, hps, ops, ops_order), c, related
    end
    if qs.for_update !== nothing && columns === nothing && !idonly && qs.values_fields === nothing
        sql *= for_update_sql(backend(), qs.for_update, c, related)
    end
    sql, vcat(sel_ps, c.join_params, wps, gps, hps, ops_order), c, related
end

"""
Whether an annotation aggregates, itself or through another annotation it refers to
(`Coalesce(:min_age, :contact__age)` after `min_age = Min(:authors__age)`): such a one isn't grouped by.
"""
function aggregating(@nospecialize(v), anns::Vector{Pair{Symbol,Any}}, depth::Int = 0)
    contains_aggregate(v) && return true
    depth > 8 && return false
    for r in bare_refs(v)
        i = findfirst(p -> string(p.first) == r, anns)
        i !== nothing && !is_filtered_relation(anns[i].second) && aggregating(anns[i].second, anns, depth + 1) && return true
    end
    false
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
Base.@nospecializeinfer function build_combined(@nospecialize(qs::QuerySet); columns = nothing, ordered = true, idonly = false)
    T = queryset_model(qs)
    op, parts, all_ = qs.combinator
    sqls, ps = String[], Any[]
    for p in parts
        sql, pp = select_sql(p; ordered = false)
        # a values part selects only its named columns (its other annotations would change the column count)
        if p.values_fields !== nothing && any(a -> !is_filtered_relation(a.second) && !(string(a.first) in p.values_fields), p.annotations)
            sql = "SELECT " * join([qname(f) for f in p.values_fields], ", ") * " FROM ($sql) AS juango_part"
        end
        push!(sqls, sql); append!(ps, pp)
    end
    word = op === :union ? "UNION" : op === :intersection ? "INTERSECT" : "EXCEPT"
    inner = join(sqls, " $word$(all_ ? " ALL" : "") ")
    sel = idonly ? qname("id") : columns !== nothing ? replace(columns, r"^.*\." => "") : "*"
    order = String[]
    if ordered
        for o in qs.order
            o isa NoOrder && continue
            o isa OrderBy && throw(ArgumentError("order_by expressions aren't supported on union/intersection/difference; order by field names"))
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
Base.@nospecializeinfer needs_wrapping(@nospecialize(qs::QuerySet)) = qs.values_fields !== nothing || any(p -> contains_aggregate(p.second), qs.annotations)

Base.@nospecializeinfer function select_sql(@nospecialize(qs::QuerySet); columns = nothing, ordered = true)
    sql, ps, _, _ = build_select(qs; columns = columns, ordered = ordered)
    sql, ps
end

"Build a model from columns labelled `prefix*column` (as produced for `select_related`)."
Base.@nospecializeinfer function from_prefixed_row(@nospecialize(T::Type), row::Dict{Symbol,Any}, prefix::String)
    idkey, plan = prefixed_plan(T, prefix)
    id = get(row, idkey, nothing)
    id === nothing && return nothing
    data = Dict{Symbol,Any}(:id => pk_value(T, id))
    sizehint!(data, length(plan) + 1)
    for (f, key, att) in plan                    # inherited fields too (joined from the parent tables)
        data[att] = from_db(f, get(row, key, nothing))
    end
    T(data, Dict{Symbol,Any}())
end
# The column labels of `T`'s fields under `prefix` (Symbols made once, not for every row).
const PREFIXED_PLANS = Dict{Tuple{Any,String},Tuple{Symbol,Vector{Tuple{Field,Symbol,Symbol}}}}()
const PREFIXED_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(PREFIXED_PLANS), PREFIXED_LOCK))
Base.@nospecializeinfer function prefixed_plan(@nospecialize(T::Type), prefix::String)
    key = (T, prefix)
    lock(PREFIXED_LOCK)
    try
        p = get(PREFIXED_PLANS, key, nothing)
        p === nothing || return p
        plan = Tuple{Field,Symbol,Symbol}[(f, Symbol(prefix, column(f)), attname(f)) for f in all_fields(T)]
        return PREFIXED_PLANS[key] = (Symbol(prefix, "id"), plan)
    finally
        unlock(PREFIXED_LOCK)
    end
end

"Execute the query and return a `Vector` of model instances."
Base.@nospecializeinfer fetch(@nospecialize(qs::QuerySet)) = in_db(() -> fetch_here(qs), qs)

Base.@nospecializeinfer function fetch_here(@nospecialize(qs::QuerySet))
    T = model_of(qs)
    qs.cache === nothing || return Vector{T}(qs.cache)
    qs.for_update === nothing || in_atomic() ||
        throw(TransactionManagementError("select_for_update() must be evaluated inside atomic()"))
    qs.values_fields === nothing || return fetch_values(qs)
    qs.isnone && return T[]
    sql, ps, _, related = build_select(qs)
    rows = execute(sql, ps)
    plan = row_plan(T)
    objs = Vector{T}(undef, length(rows))
    for i in eachindex(rows)
        objs[i] = set_instance_db!(from_row(T, rows[i], plan))
    end
    for (k, v) in qs.annotations
        (is_filtered_relation(v) || k in qs.aliases) && continue
        of = typed_output(T, v)
        for (o, r) in zip(objs, rows)
            (getfield(o, :_data)::Dict{Symbol,Any})[k] = expr_value(T, v, get(r, k, nothing), of)
        end
    end
    if !isempty(related)
        isempty(objs) || foreach(r -> note_eager_load(T, r[1][1], :select_related), related)
        for (obj, row) in zip(objs, rows)
            for (path, M, alias) in related
                parent = obj
                for s in path[1:end-1]
                    parent = get((getfield(parent, :_cache)::Dict{Symbol,Any}), s, nothing)
                    parent isa PrefetchedList && (parent = isempty(parent.items) ? nothing : parent.items[1])
                    parent === nothing && break
                end
                parent === nothing && continue
                r = from_prefixed_row(M, row, alias * "__")
                if findfield(modelmeta(typeof(parent)), path[end]) === nothing
                    # a reverse one-to-one: remember that there's no row too, so the accessor doesn't query
                    (getfield(parent, :_cache)::Dict{Symbol,Any})[path[end]] = PrefetchedList(r === nothing ? Any[] : Any[r])
                else
                    r === nothing || ((getfield(parent, :_cache)::Dict{Symbol,Any})[path[end]] = r)
                end
            end
        end
    end
    for p in qs.prefetch
        do_prefetch!(objs, p)
    end
    remember_siblings!(objs)
    objs
end

"Rows of a `values()` queryset, with column values converted like model fields."
Base.@nospecializeinfer function fetch_values(@nospecialize(qs::QuerySet))
    T = model_of(qs)
    qs.isnone && return Dict{Symbol,Any}[]
    sql, ps, c, _ = build_select(qs)
    # a union's rows: the annotations are its parts' (the first's, as the columns are)
    anns = qs.combinator === nothing ? qs.annotations : first(qs.combinator[2]).annotations
    convs = Dict{Symbol,Any}()
    for f in qs.values_fields
        (haskey(c.annotations, Symbol(f)) || any(p -> p.first === Symbol(f), anns)) && continue
        _, fld = resolve_path(SQLCompiler(T), modelmeta(T).table, T, f)
        fld === nothing || (convs[Symbol(f)] = fld)
    end
    outs = Dict{Symbol,Union{Nothing,Field}}(k => typed_output(T, v) for (k, v) in anns if !is_filtered_relation(v))
    out = Dict{Symbol,Any}[]
    for r in execute(sql, ps)
        d = Dict{Symbol,Any}()
        for f in qs.values_fields
            k = Symbol(f)
            v = get(r, k, nothing)
            d[k] = haskey(convs, k) ? from_db(convs[k], v) : v
        end
        for (k, v) in anns                               # only those asked for (#201)
            is_filtered_relation(v) || !haskey(d, k) || (d[k] = expr_value(T, v, get(r, k, nothing), outs[k]))
        end
        push!(out, d)
    end
    shape_values(qs, out)
end
"values() rows as values_list gives them: tuples, named tuples or plain values."
Base.@nospecializeinfer function shape_values(@nospecialize(qs::QuerySet), rows::Vector{Dict{Symbol,Any}})
    m = qs.values_mode
    m === :dict && return rows
    ks = Symbol[Symbol(f) for f in qs.values_fields]
    m === :flat && return Any[r[ks[1]] for r in rows]
    m === :named && return [NamedTuple{Tuple(ks)}(Tuple(r[k] for k in ks)) for r in rows]
    Tuple[Tuple(r[k] for k in ks) for r in rows]
end

Base.@nospecializeinfer function do_prefetch!(@nospecialize(objs::Vector), p::Prefetch)
    segs = Symbol.(split(p.path, "__"))
    isempty(objs) || p.to_attr !== nothing || note_eager_load(typeof(first(objs)), segs[1], :prefetch_related)
    level = objs
    for (i, s) in enumerate(segs)
        last_ = i == length(segs)
        qs, to = last_ ? p.queryset : nothing, last_ ? p.to_attr : nothing
        # already loaded on every object (select_related, or an earlier lookup sharing the path): reused, not
        # queried again, as Django ("books" and "books__read_by" load the books once)
        cached = qs === nothing && to === nothing ? cached_level(level, s) : nothing
        level = cached === nothing ? prefetch_level!(level, s, qs, to) : cached
    end
    nothing
end
"The related objects of `name` cached on every one of `objs` (prefetched or selected), or `nothing` if any lacks them."
Base.@nospecializeinfer function cached_level(@nospecialize(objs::Vector), name::Symbol)
    out = Any[]
    for o in objs
        c = get((getfield(o, :_cache)::Dict{Symbol,Any}), name, NOTFOUND)
        c === NOTFOUND && return nothing
        c isa PrefetchedList ? append!(out, c.items) : c isa Model ? push!(out, c) : c === nothing || return nothing
    end
    out
end

"Load relation `name` for all `objs` with one query; return the related objects."
Base.@nospecializeinfer function prefetch_level!(@nospecialize(objs::Vector), name::Symbol, @nospecialize(qs), to_attr)
    isempty(objs) && return Any[]
    T = typeof(first(objs))
    f = findfield(modelmeta(T), name)
    if f !== nothing && f.kind === :fk && f.name === name
        R = related_model(f)
        ids = unique([field_data(o, attname(f)) for o in objs if field_data(o, attname(f)) !== nothing])
        rel = isempty(ids) ? R[] : fetch(filter(something(qs, base_objects(R)); (Symbol(target_name(f), "__in") => ids,)...))
        byid = Dict(target_value(f, r) => r for r in rel)
        for o in objs
            id = field_data(o, attname(f))
            r = id === nothing ? nothing : get(byid, id, nothing)
            if to_attr !== nothing
                (getfield(o, :_cache)::Dict{Symbol,Any})[to_attr] = r
            elseif r !== nothing
                (getfield(o, :_cache)::Dict{Symbol,Any})[name] = r
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
    ids = [target_value(rf, o) for o in objs]
    rows = fetch(filter(something(qs, objects(M)), Q(Symbol(attname(rf), "__in") => ids)))
    groups = Dict{Any,Vector{M}}()
    owner_of = Dict{Any,Any}(target_value(rf, o) => o for o in objs)
    for r in rows
        k = field_data(r, attname(rf))
        push!(get!(() -> M[], groups, k), r)
        # each related row points back at its owner (bio.author: no query), as Django sets it
        o = get(owner_of, k, nothing)
        o === nothing || ((getfield(r, :_cache)::Dict{Symbol,Any})[rf.name] = o)
    end
    for o in objs
        (getfield(o, :_cache)::Dict{Symbol,Any})[something(to_attr, rn)] = PrefetchedList(get(groups, target_value(rf, o), M[]))
    end
    rows
end

Base.@nospecializeinfer Base.collect(@nospecialize(qs::QuerySet)) = fetch(qs)
# a queryset equals a vector of the same rows (`values_list(qs, :id; flat = true) == [1, 2]`)
Base.@nospecializeinfer Base.:(==)(@nospecialize(qs::QuerySet), v::AbstractVector) = fetch(qs) == v
Base.@nospecializeinfer Base.:(==)(v::AbstractVector, @nospecialize(qs::QuerySet)) = v == fetch(qs)
# A queryset reaching the driver as a parameter would be bound as its string ("<QuerySet{...}>"):
# a vector of querysets (`[qs1; qs2]`) given to `__in`, for example. Say so instead.
adapt_param(::DatabaseBackend, @nospecialize(qs::QuerySet)) =
    throw(ArgumentError("a QuerySet{$(nameof(model_of(qs)))} was used as a query value: give it on its own to `__in` " *
                        "(a subquery), combine querysets with union(...) or Q(...) | Q(...), or collect(...) it first"))
# values() and values_list querysets as JSON: their rows
Base.@nospecializeinfer JsonResponse(@nospecialize(qs::QuerySet); kw...) = JsonResponse(fetch(qs); kw...)
Base.@nospecializeinfer Base.sort(@nospecialize(qs::QuerySet); kw...) = sort(fetch(qs); kw...)
Base.IteratorEltype(::Type{<:QuerySet}) = Base.EltypeUnknown()     # objects, or values()/values_list rows
Base.IteratorSize(::Type{<:QuerySet}) = Base.SizeUnknown()
Base.@nospecializeinfer function Base.iterate(@nospecialize(qs::QuerySet))
    v = fetch(qs)
    r = iterate(v)
    r === nothing ? nothing : (r[1], (v, r[2]))
end
Base.@nospecializeinfer function Base.iterate(@nospecialize(::QuerySet), st)
    r = iterate(st[1], st[2])
    r === nothing ? nothing : (r[1], (st[1], r[2]))
end

"Number of matching rows (a `SELECT COUNT(*)`)."
Base.@nospecializeinfer Base.count(@nospecialize(qs::QuerySet)) = in_db(() -> count_here(qs), qs)
Base.@nospecializeinfer function count_here(@nospecialize(qs::QuerySet))
    T = model_of(qs)
    qs.cache === nothing || return length(qs.cache)
    qs.isnone && return 0
    sql, ps = needs_wrapping(qs) ? select_sql(qs; ordered = false) : select_sql(qs; columns = pk_select(modelmeta(T).table, T), ordered = false)
    execute("SELECT COUNT(*) AS n FROM ($sql) AS juango_sub", ps)[1][:n]
end
Base.@nospecializeinfer Base.count(@nospecialize(T::Type{<:Model})) = count(objects(T))
Base.@nospecializeinfer Base.length(@nospecialize(qs::QuerySet)) = count(qs)

"Whether any row matches."
Base.@nospecializeinfer exists(@nospecialize(qs::QuerySet)) = in_db(() -> exists_here(qs), qs)
Base.@nospecializeinfer function exists_here(@nospecialize(qs::QuerySet))
    qs.cache === nothing || return !isempty(qs.cache)
    qs.isnone && return false
    sql, ps = select_sql(chain(qs; limit = 1); columns = "1", ordered = false)
    !isempty(execute(sql, ps))
end
Base.@nospecializeinfer Base.isempty(@nospecialize(qs::QuerySet)) = !exists(qs)
Base.@nospecializeinfer truthy(@nospecialize(qs::QuerySet)) = exists(qs)

"Whether the queryset has an ordering, its own or the model's `Meta(ordering)` (Django's `qs.ordered`)."
Base.@nospecializeinfer is_ordered(@nospecialize(qs::QuerySet)) =
    qs.isnone || (!order_cleared(qs) && (!isempty(qs.order) ||
                  # a grouped query (an aggregate annotation) ignores Meta.ordering, as Django
                  (!isempty(modelmeta(model_of(qs)).ordering) && !any(p -> contains_aggregate(p.second), qs.annotations))))
const WARNED_UNORDERED = Set{Tuple{Any,String}}()
"In DEBUG, warn (once per model and use) that the rows of an unordered queryset come in any order, so pages can overlap or skip rows."
Base.@nospecializeinfer function warn_unordered(@nospecialize(qs::QuerySet), what::String)
    get(SETTINGS, :DEBUG, false) === true || return
    (qs.cache === nothing && qs.combinator === nothing && !is_ordered(qs)) || return
    key = (model_of(qs), what)
    key in WARNED_UNORDERED && return
    push!(WARNED_UNORDERED, key)
    @warn "$what an unordered $(nameof(model_of(qs))) queryset: the database may return its rows in any order, so pages can overlap or miss rows. Add order_by(...) or Meta(ordering = ...)."
end

# `end` in qs[3:end]: from row 3 on, without a limit (Django's qs[2:]); the count isn't known without a query
const OPEN_END = typemax(Int) >> 4
Base.lastindex(@nospecialize(qs::QuerySet)) = OPEN_END
Base.@nospecializeinfer function Base.getindex(@nospecialize(qs::QuerySet), r::AbstractUnitRange{<:Integer})
    first(r) >= 1 || throw(ArgumentError("queryset slices are 1-based"))
    first(r) > 1 && warn_unordered(qs, "Slicing (from row $(first(r)))")
    open = last(r) >= OPEN_END ÷ 2
    n = open ? nothing : length(r)
    qs.limit !== nothing && (n = max(0, min(something(n, typemax(Int)), qs.limit - (first(r) - 1))))
    # an empty slice (qs[5:4]) has no rows: no query, as Django
    chain(qs; offset = qs.offset + first(r) - 1, limit = n, isnone = qs.isnone || n == 0)
end
"qs[1:2:end]: every second row, as Django's qs[::2] (it runs the query: a step can't be done in SQL)."
Base.@nospecializeinfer function Base.getindex(@nospecialize(qs::QuerySet), r::StepRange{<:Integer})
    step(r) > 0 || throw(ArgumentError("queryset slices take a positive step"))
    rows = fetch(qs[first(r):last(r)])
    rows[1:step(r):end]
end
Base.@nospecializeinfer function Base.getindex(@nospecialize(qs::QuerySet), i::Integer)
    qs.cache === nothing || return qs.cache[i]
    v = fetch(qs[i:i])
    isempty(v) && throw(BoundsError(qs, i))
    v[1]
end

"""
    contains(qs, obj) -> Bool    (also `obj in qs`)

Whether the queryset includes `obj` (Django 4.0's `QuerySet.contains`): one query, or none if
the queryset has already been evaluated.
"""
Base.@nospecializeinfer function Base.contains(@nospecialize(qs::QuerySet), @nospecialize(obj::Model))
    obj isa model_of(qs) || concrete_model(typeof(obj)) === concrete_model(model_of(qs)) ||
        throw(ArgumentError("contains: $(typeof(obj)) isn't a $(model_of(qs))"))
    obj.pk === nothing && throw(ArgumentError("contains: the object isn't saved"))
    qs.cache === nothing || return any(o -> o isa Model && o.pk == obj.pk, qs.cache)
    exists(filter(qs; pk = obj.pk))
end
Base.@nospecializeinfer Base.in(@nospecialize(obj::Model), @nospecialize(qs::QuerySet)) = contains(qs, obj)

Base.@nospecializeinfer default_order(@nospecialize(qs::QuerySet)) =
    order_cleared(qs) ? Any["id"] :
    isempty(qs.order) ? (isempty(modelmeta(model_of(qs)).ordering) ? Any["id"] : modelmeta(model_of(qs)).ordering) : qs.order

"First object (by the queryset's ordering, or by id), or `nothing`."
Base.@nospecializeinfer function Base.first(@nospecialize(qs::QuerySet))
    qs.cache === nothing || return isempty(qs.cache) ? nothing : qs.cache[1]
    v = fetch(chain(qs[1:1]; order = default_order(qs)))
    isempty(v) ? nothing : v[1]
end
"Last object, or `nothing`."
Base.@nospecializeinfer function Base.last(@nospecialize(qs::QuerySet))
    assert_unsliced(qs, "take last of")
    flipped = Any[reverse_order(o) for o in default_order(qs)]
    first(chain(qs; order = flipped))
end
Base.@nospecializeinfer Base.first(@nospecialize(T::Type{<:Model})) = first(objects(T))
Base.@nospecializeinfer Base.last(@nospecialize(T::Type{<:Model})) = last(objects(T))

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
function defer(@nospecialize(qs::QuerySet), fields...)
    qs.values_fields === nothing || throw(ArgumentError("defer() can't follow values() or values_list()"))
    T = model_of(qs)
    fields == (nothing,) && return chain(qs; deferred = Symbol[])
    names = Symbol[Symbol(f) for f in fields]
    check_deferrable(T, names)
    chain(qs; deferred = unique(vcat(qs.deferred, names)))
end
defer(@nospecialize(T::Type{<:Model}), fields...) = defer(objects(T), fields...)

"""
    only(qs, :title, :author)

(Extends `Base.only`.) Load only these fields (and the id); the others are deferred, as with `defer`.
"""
function Base.only(@nospecialize(qs::QuerySet), field::Union{Symbol,AbstractString}, fields::Union{Symbol,AbstractString}...)
    qs.values_fields === nothing || throw(ArgumentError("only() can't follow values() or values_list()"))
    T = model_of(qs)
    keep = Symbol[Symbol(field); Symbol.(collect(fields))]
    check_deferrable(T, keep)
    chain(qs; deferred = Symbol[f.name for f in modelmeta(concrete_model(T)).fields if !(f.name in keep)])
end
Base.only(@nospecialize(T::Type{<:Model}), field::Union{Symbol,AbstractString}, fields::Union{Symbol,AbstractString}...) =
    only(objects(T), field, fields...)

"""
    distinct(qs)
    distinct(qs, :author, :published)     # PostgreSQL only: SELECT DISTINCT ON (...)

Remove duplicate rows (`SELECT DISTINCT`). With fields, keep the first row of each group of
equal values: order by those fields first.
"""
distinct(qs::QuerySet, fields::Union{Symbol,AbstractString}...) = chain(qs; distinct_fields = String[string(f) for f in fields])
distinct(@nospecialize(T::Type{<:Model}), fields::Union{Symbol,AbstractString}...) = distinct(objects(T), fields...)

Base.@nospecializeinfer function latest_order(@nospecialize(qs::QuerySet), fields, what)
    T = model_of(qs)
    fs = isempty(fields) ? get(modelmeta(T).extra, :get_latest_by, nothing) : fields
    fs === nothing && throw(ArgumentError("$what needs field names or Meta(get_latest_by = ...) on $(nameof(T))"))
    String[string(f) for f in (fs isa Union{Symbol,AbstractString} ? (fs,) : fs)]
end

"""
    latest(qs, :published)    earliest(qs, :published)

The object with the largest (smallest) value of the fields, which default to the model's
`Meta(get_latest_by = ...)`. Throws `DoesNotExist` when there are no objects.
"""
function latest(@nospecialize(qs::QuerySet), fields::Union{Symbol,AbstractString}...)
    T = model_of(qs)
    order = Any[reverse_order(o) for o in latest_order(qs, fields, "latest")]
    o = first(chain(qs; order = order))
    o === nothing && throw(DoesNotExist(T, "latest"))
    o
end
function earliest(@nospecialize(qs::QuerySet), fields::Union{Symbol,AbstractString}...)
    T = model_of(qs)
    o = first(chain(qs; order = latest_order(qs, fields, "earliest")))
    o === nothing && throw(DoesNotExist(T, "earliest"))
    o
end
latest(@nospecialize(T::Type{<:Model}), fields...) = latest(objects(T), fields...)
earliest(@nospecialize(T::Type{<:Model}), fields...) = earliest(objects(T), fields...)

"""
    in_bulk(qs)                          # Dict id => object
    in_bulk(qs, [1, 2, 3])
    in_bulk(qs, ["a", "b"]; field_name = :slug)
    in_bulk(values(qs, :headline), ids)  # id => Dict(:headline => ...); values_list rows too

The objects (or, after `values`/`values_list`, the rows) as a `Dict` keyed by `field_name`, which
must be unique: `unique = true`, or a single-field `UniqueConstraint` without a condition.
Optionally limited to those keys. Not for a sliced queryset.
"""
Base.@nospecializeinfer function in_bulk(@nospecialize(qs::QuerySet), keys = nothing; field_name = :id)
    T = model_of(qs)
    field_name = Symbol(field_name)
    (qs.limit !== nothing || qs.offset != 0) && throw(ArgumentError("in_bulk can't be used on a sliced queryset (limit or offset)"))
    if !(field_name in (:id, :pk))
        f = findfield(modelmeta(T), field_name)
        (f !== nothing && (f.unique || unique_by_constraint(T, field_name))) ||
            throw(ArgumentError("in_bulk's field_name must be a unique field, not '$field_name'"))
    end
    field_name === :pk && (field_name = :id)
    q = keys === nothing ? qs : filter(qs; Symbol(field_name, "__in") => collect(keys))
    qs.values_fields === nothing || return in_bulk_values(q, keys, field_name)
    keys !== nothing && isempty(keys) && return Dict{Any,T}()
    Dict{Any,T}(getproperty(o, field_name) => o for o in fetch(q))
end
"A single-field UniqueConstraint without a condition makes the field unique (as Django's in_bulk)."
Base.@nospecializeinfer unique_by_constraint(@nospecialize(T::Type), name::Symbol) =
    any(c -> c isa UniqueConstraint && c.fields == [name] && c.condition === nothing, model_constraints(T))
# in_bulk after values()/values_list(): the rows keyed by the field (read along with them, and left out
# of them when they didn't name it), as Django 6
Base.@nospecializeinfer function in_bulk_values(@nospecialize(q::QuerySet), keys, field_name::Symbol)
    keys !== nothing && isempty(keys) && return Dict{Any,Any}()
    fields = String.(q.values_fields)
    added = !(string(field_name) in fields)
    rows = collect(values(q, vcat(fields, added ? [string(field_name)] : String[])...))
    out = Dict{Any,Any}()
    for r in rows
        k = r[field_name]
        rest = Any[r[Symbol(f)] for f in fields]
        out[k] = q.values_mode === :flat ? rest[1] :
                 q.values_mode === :tuple ? Tuple(rest) :
                 q.values_mode === :named ? NamedTuple{Tuple(Symbol.(fields))}(Tuple(rest)) :
                 (added ? (delete!(r, field_name); r) : r)
    end
    out
end
Base.@nospecializeinfer in_bulk(@nospecialize(T::Type{<:Model}), keys = nothing; kw...) = in_bulk(objects(T), keys; kw...)

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
    f = findfield(modelmeta(model_of(qs)), Symbol(field))
    (f === nothing || f.kind in (:date, :datetime, :time)) ||
        throw(ArgumentError("$what: '$field' isn't a DateField, TimeField or DateTimeField"))
    vals = DateTime[]
    for v in values_list(order_by(qs), field; flat = true)
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
dates(@nospecialize(T::Type{<:Model}), args...; kw...) = dates(objects(T), args...; kw...)

"""
    datetimes(qs, :created, :hour; order = :asc) -> Vector{DateTime}

Like `dates`, for a datetime field, truncated down to `:hour`, `:minute` or `:second` too.
Aware values are converted to the current time zone first.
"""
datetimes(qs::QuerySet, field, kind = :day; order = :asc) =
    distinct_dates(qs, field, kind, order, DATETIME_KINDS, "datetimes")
datetimes(@nospecialize(T::Type{<:Model}), args...; kw...) = datetimes(objects(T), args...; kw...)

"""
    raw(Model, sql, params = [])

Run hand-written SQL (with `?` placeholders) and build model instances from the rows. The
rows must include `id`; fields missing from them are deferred, and extra columns become
attributes, like annotations.
"""
Base.@nospecializeinfer raw(@nospecialize(T::Type{<:Model}), sql::AbstractString, params = Any[]; db = nothing) =
    with_db(() -> raw_here(T, sql, params), something(db, routed_db(T, false), Some(nothing)))
Base.@nospecializeinfer function raw_here(@nospecialize(T::Type{<:Model}), sql::AbstractString, params = Any[])
    rows = execute(sql, collect(Any, params))
    known = Set{Symbol}([:id; [attname(f) for f in all_fields(T)]])
    out = T[]
    plan = row_plan(T)
    for r in rows
        is_composite(T) || haskey(r, :id) || throw(ArgumentError("raw(): the query must select the id column"))
        o = set_instance_db!(from_row(T, r, plan))
        for (k, v) in r
            k in known || ((getfield(o, :_data)::Dict{Symbol,Any})[k] = v)
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

"The reverse side of a OneToOneField pointing at `T` named `name`: `(name, model, field)`, or nothing."
Base.@nospecializeinfer function reverse_one_to_one(@nospecialize(T::Type), name)
    for (rn, M, rf) in reverse_relations(T)
        rf.one_to_one && string(rn) == string(name) && return (rn, M, rf)
    end
    nothing
end
