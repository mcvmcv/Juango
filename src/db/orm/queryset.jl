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
        getfield(o, :_data)[k] = expr_value(T, v, get(r, k, nothing))
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
            is_filtered_relation(v) || (d[k] = expr_value(T, v, get(r, k, nothing)))
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
