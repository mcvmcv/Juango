# Query expressions --------------------------------------------------------------------------
#
#     update!(filter(Post; id=1); views = F(:views) + 1)            # atomic increment
#     filter(Post; updated__gt = F(:created))
#     annotate(objects(Author); n = Count(:posts)) |> filter(n__gt = 2) |> order_by("-n")
#     values(objects(Post), :status) |> annotate(n = Count(:id))   # GROUP BY status
#     aggregate(objects(Post); total = Sum(:views), avg = Avg(:views))
#     annotate(objects(Post); rank = Window(RowNumber(); partition_by = [:author], order_by = ["-views"]))
#
# Strings and Symbols passed to functions are field references (`Lower(:title)`); use
# `Value("text")` for a literal. Field references follow relations with `__`.

"A field reference: `F(:views)`, `F(\"author__name\")`."
struct F <: Expression
    name::String
end
F(s::Symbol) = F(string(s))

"A literal value in an expression."
struct Value <: Expression
    value::Any
end

struct CombinedExpression <: Expression
    op::String
    lhs::Expression
    rhs::Expression
end

"Turn a function argument into an expression: names are field references, the rest literals."
ref(x::Expression) = x
ref(x::Union{Symbol,AbstractString}) = F(string(x))
ref(x) = Value(x)
lit_expr(x::Expression) = x
lit_expr(x) = Value(x)

for op in (:+, :-, :*, :/)
    @eval Base.$op(a::Expression, b::Expression) = CombinedExpression($(string(op)), a, b)
    @eval Base.$op(a::Expression, b) = CombinedExpression($(string(op)), a, lit_expr(b))
    @eval Base.$op(a, b::Expression) = CombinedExpression($(string(op)), lit_expr(a), b)
end
Base.:-(a::Expression) = CombinedExpression("-", Value(0), a)

"A SQL function call."
struct Func <: Expression
    name::Symbol
    args::Vector{Any}
end
"Lower-case text."
Lower(x) = Func(:lower, [ref(x)])
"Upper-case text."
Upper(x) = Func(:upper, [ref(x)])
"Length of text."
Length(x) = Func(:length, [ref(x)])
"The first argument that is not NULL."
Coalesce(xs...) = Func(:coalesce, Any[ref(x) for x in xs])
"Join values as text (NULL counts as empty)."
Concat(xs...) = Func(:concat, Any[ref(x) for x in xs])
"Convert to a field kind: `Cast(:views, :float)`, `Cast(:n, :string)`."
Cast(x, kind::Symbol) = Func(:cast, Any[ref(x), kind])
"The current local date and time (Julia's `now()`, the same clock `auto_now` uses)."
Now() = Func(:now, Any[])
"Year, month or day of a date column."
ExtractYear(x) = Func(:extract, Any[ref(x), :year])
ExtractMonth(x) = Func(:extract, Any[ref(x), :month])
ExtractDay(x) = Func(:extract, Any[ref(x), :day])

"An aggregate: `Count`, `Sum`, `Avg`, `Min`, `Max`."
struct Aggregate <: Expression
    func::String
    arg::Union{Nothing,Expression}
    distinct::Bool
    filter::Union{Nothing,Q}
end
"""
    Count(field=nothing; distinct=false, filter=nothing)

Count rows (`Count()`), non-NULL values of a field, or related objects (`Count(:posts)`).
`filter=Q(...)` counts only matching rows.
"""
Count(x = nothing; distinct = false, filter = nothing) = Aggregate("COUNT", x === nothing ? nothing : ref(x), distinct, filter)
Sum(x; distinct = false, filter = nothing) = Aggregate("SUM", ref(x), distinct, filter)
Avg(x; distinct = false, filter = nothing) = Aggregate("AVG", ref(x), distinct, filter)
Min(x; filter = nothing) = Aggregate("MIN", ref(x), false, filter)
Max(x; filter = nothing) = Aggregate("MAX", ref(x), false, filter)

"`When(Q(...); then=value)` or `When(; then=value, lookups...)`, used inside `Case`."
struct When
    cond::Q
    then::Expression
end
When(cond::Q; then) = When(cond, lit_expr(then))
When(; then, kw...) = When(Q(; kw...), lit_expr(then))

"`Case(When(...), When(...); default=value)`: SQL CASE WHEN ... END."
struct Case <: Expression
    whens::Vector{When}
    default::Expression
end
Case(whens::When...; default = nothing) = Case(collect(When, whens), lit_expr(default))

"Inside a `Subquery`/`Exists`, a field of the outer query: `filter(Post; author = OuterRef(:id))`."
struct OuterRef <: Expression
    name::String
end
OuterRef(s::Symbol) = OuterRef(string(s))

"""
    Subquery(qs)

A queryset used as a value. It should produce one column and at most one row, e.g.
`Subquery(values(order_by(filter(Post; author=OuterRef(:id)), "-created"), :title)[1:1])`.
"""
struct Subquery <: Expression
    qs::Any
end

"`Exists(qs)`: true when the (usually correlated) queryset has rows. Negate with `!`."
struct Exists <: Expression
    qs::Any
    negated::Bool
end
Exists(qs) = Exists(qs, false)
Base.:!(e::Exists) = Exists(e.qs, !e.negated)

"A window function: `RowNumber()`, `Rank()`, `DenseRank()`, `Lag(x)`, `Lead(x)`."
struct WindowFunc <: Expression
    name::String
    args::Vector{Any}
end
RowNumber() = WindowFunc("ROW_NUMBER", Any[])
Rank() = WindowFunc("RANK", Any[])
DenseRank() = WindowFunc("DENSE_RANK", Any[])
Lag(x, offset::Integer = 1) = WindowFunc("LAG", Any[ref(x), Value(offset)])
Lead(x, offset::Integer = 1) = WindowFunc("LEAD", Any[ref(x), Value(offset)])

"""
    Window(expr; partition_by=[], order_by=[])

`expr OVER (PARTITION BY ... ORDER BY ...)`. `expr` is a window function or an aggregate
(`Window(Sum(:views); partition_by=[:author])`). `order_by` takes strings like `"-views"`.
"""
struct Window <: Expression
    expr::Expression
    partition_by::Vector{Any}
    order_by::Vector{String}
end
Window(expr; partition_by = [], order_by = []) =
    Window(expr, Any[ref(p) for p in partition_by], String[string(o) for o in order_by])

# --- analysis -------------------------------------------------------------------------------

contains_aggregate(::Any) = false
contains_aggregate(::Aggregate) = true
contains_aggregate(e::CombinedExpression) = contains_aggregate(e.lhs) || contains_aggregate(e.rhs)
contains_aggregate(e::Func) = any(contains_aggregate, e.args)
contains_aggregate(e::Case) = any(w -> contains_aggregate(w.then), e.whens) || contains_aggregate(e.default)
contains_aggregate(::Window) = false

# --- compilation ----------------------------------------------------------------------------

"Resolve a field path for expressions: returns (SQL column, Field or nothing)."
function resolve_path(c::SQLCompiler, alias, @nospecialize(T::Type), path::AbstractString)
    segs = String.(split(path, "__"))
    for (i, s) in enumerate(segs)
        last_ = i == length(segs)
        s == "pk" && (s = "id")
        if s == "id"
            last_ || throw(LookupError("'id' is not a relation in '$path'"))
            return qcol(alias, "id"), nothing
        end
        f = findfield(modelmeta(T), Symbol(s))
        if f !== nothing
            alias = field_alias!(c, alias, T, f)
            if last_ || f.kind !== :fk
                last_ || throw(LookupError("'$s' is not a relation in '$path'"))
                return qcol(alias, column(f)), f
            end
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = f.null)
            T = related_model(f)
            continue
        end
        mm = find_m2m(T, s)
        if mm !== nothing
            s1, s2 = m2m_path(mm[2], mm[3])
            return resolve_path(c, alias, T, join(vcat([string(s1), string(s2)], segs[i+1:end], last_ ? ["id"] : String[]), "__"))
        end
        g = find_generic(generic_relations(T), s)
        if g !== nothing
            M = related_model(g)
            ctf, fkf = g.through
            ctcol, ctid = column(getfield_meta(M, ctf)), get_for_model(T).id::Integer
            alias = join!(c, alias, (alias, g.name, :expr), modelmeta(M).table, column(getfield_meta(M, fkf)), "id";
                          left = true, extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            T = M
            last_ && return qcol(alias, "id"), nothing
            continue
        end
        rel = find_reverse(T, s)
        rel === nothing && throw(lookup_error(T, s))
        rn, M, rf = rel
        alias = join!(c, alias, (alias, rn, :expr), modelmeta(M).table, column(rf), "id"; left = true)
        T = M
        last_ && return qcol(alias, "id"), nothing
    end
end

value_sql(b, v::Bool) = (sql_literal(b, adapt_param(b, v)), Any[])
value_sql(b, v::Integer) = (string(v), Any[])
value_sql(b, v::AbstractFloat) = (isfinite(v) ? repr(Float64(v)) : throw(ArgumentError("non-finite value $v")), Any[])
value_sql(b, ::Nothing) = ("NULL", Any[])
value_sql(b, v) = ("?", Any[v])

compile_expr(c::SQLCompiler, e::Value) = value_sql(backend(), e.value)

function compile_expr(c::SQLCompiler, e::F)
    if !occursin("__", e.name) && haskey(c.annotations, Symbol(e.name))
        a = c.annotations[Symbol(e.name)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, ps = compile_expr(c, a)
        return "($sql)", ps
    end
    col, _ = resolve_path(c, c.base, c.T, e.name)
    col, Any[]
end

function compile_expr(c::SQLCompiler, e::OuterRef)
    c.outer === nothing && throw(ArgumentError("OuterRef($(repr(e.name))) used outside a Subquery/Exists"))
    compile_expr(c.outer, F(e.name))
end

function compile_expr(c::SQLCompiler, e::CombinedExpression)
    a, pa = compile_expr(c, e.lhs)
    b, pb = compile_expr(c, e.rhs)
    "($a $(e.op) $b)", vcat(pa, pb)
end

function compile_expr(c::SQLCompiler, e::Func)
    b = backend()
    parts = [compile_expr(c, a) for a in e.args if a isa Expression]
    sqls, ps = first.(parts), reduce(vcat, last.(parts); init = Any[])
    n = e.name
    n === :lower && return "LOWER($(sqls[1]))", ps
    n === :upper && return "UPPER($(sqls[1]))", ps
    n === :length && return "$(length_function(b))($(sqls[1]))", ps
    n === :coalesce && return "COALESCE($(join(sqls, ", ")))", ps
    n === :concat && return "(" * join(["COALESCE(CAST($s AS $(cast_type(b, :text))), '')" for s in sqls], " || ") * ")", ps
    n === :cast && return "CAST($(sqls[1]) AS $(cast_type(b, e.args[2] === :string ? :text : e.args[2])))", ps
    n === :now && return "?", Any[timezone_now()]     # Julia's clock and local time, like the DateTimes Juango stores
    n === :extract && return extract_sql(b, e.args[2], sqls[1]), ps
    throw(ArgumentError("unknown function $n"))
end

"Compile a condition inside an expression; relations reuse the expression's joins."
function expr_condition(c::SQLCompiler, q::Q)
    old = c.scope
    c.scope = :expr
    try
        compile_q(c, c.base, c.T, q, false)
    finally
        c.scope = old
    end
end

function compile_expr(c::SQLCompiler, e::Aggregate)
    arg, ps = e.arg === nothing ? ("*", Any[]) : compile_expr(c, e.arg)
    if e.filter !== nothing
        cond, cps = expr_condition(c, e.filter)
        arg = "CASE WHEN $cond THEN $(e.arg === nothing ? "1" : arg) END"
        ps = vcat(cps, ps)
    end
    "$(e.func)($(e.distinct ? "DISTINCT " : "")$arg)", ps
end

function compile_expr(c::SQLCompiler, e::Case)
    io, ps = IOBuffer(), Any[]
    print(io, "CASE")
    for w in e.whens
        cond, cps = expr_condition(c, w.cond)
        then, tps = compile_expr(c, w.then)
        print(io, " WHEN ", cond, " THEN ", then)
        append!(ps, cps); append!(ps, tps)
    end
    d, dps = compile_expr(c, e.default)
    print(io, " ELSE ", d, " END")
    String(take!(io)), vcat(ps, dps)
end

function subquery_sql(c::SQLCompiler, qs::QuerySet; columns = nothing, idonly = false)
    sql, ps, _, _ = build_select(qs; columns = columns, outer = c, idonly = idonly)
    sql, ps
end

function compile_expr(c::SQLCompiler, e::Subquery)
    sql, ps = subquery_sql(c, e.qs)
    "($sql)", ps
end

function compile_expr(c::SQLCompiler, e::Exists)
    sql, ps = subquery_sql(c, e.qs; columns = "1")
    (e.negated ? "NOT EXISTS" : "EXISTS") * " ($sql)", ps
end

function compile_expr(c::SQLCompiler, e::WindowFunc)
    parts = [compile_expr(c, a) for a in e.args]
    "$(e.name)($(join(first.(parts), ", ")))", reduce(vcat, last.(parts); init = Any[])
end

function compile_expr(c::SQLCompiler, e::Window)
    sql, ps = compile_expr(c, e.expr)
    over = String[]
    if !isempty(e.partition_by)
        parts = [compile_expr(c, p) for p in e.partition_by]
        push!(over, "PARTITION BY " * join(first.(parts), ", "))
        append!(ps, reduce(vcat, last.(parts); init = Any[]))
    end
    if !isempty(e.order_by)
        os = String[]
        for o in e.order_by
            col, ops = compile_expr(c, F(lstrip(o, '-')))
            push!(os, col * (startswith(o, "-") ? " DESC" : " ASC"))
            append!(ps, ops)
        end
        push!(over, "ORDER BY " * join(os, ", "))
    end
    "$sql OVER ($(join(over, " ")))", ps
end

compile_expr(c::SQLCompiler, x) = throw(ArgumentError("not an expression: $(repr(x))"))

# --- queryset API ---------------------------------------------------------------------------

"""
    annotate(qs; name = expression, ...)

Add computed values to each result, available as `obj.name` (or as keys in `values`).
Aggregates group the results: `annotate(objects(Author); n_posts = Count(:posts))`. Filter
and order by annotations like fields: `filter(qs; n_posts__gt = 1)`, `order_by(qs, "-n_posts")`.
"""
function annotate(qs::QuerySet{T}; kw...) where {T}
    anns = copy(qs.annotations)
    for (k, v) in kw
        (findfield(modelmeta(T), k) !== nothing || k in (:id, :pk)) &&
            throw(ArgumentError("annotation '$k' conflicts with a field of $T"))
        push!(anns, k => ref(v))
    end
    chain(qs; annotations = anns)
end
annotate(::Type{T}; kw...) where {T<:Model} = annotate(objects(T); kw...)
annotate(; kw...) = qs -> annotate(qs; kw...)

"""
    values(qs, fields...) -> QuerySet

The results as `Dict{Symbol,Any}` rows instead of objects. Fields may follow relations
(`:author__name`). With aggregate annotations the rows are grouped by these fields:
`values(objects(Post), :status) |> annotate(n = Count(:id))`.
"""
function Base.values(qs::QuerySet{T}, fields::Union{Symbol,AbstractString}...) where {T}
    fs = isempty(fields) ? vcat(["id"], [column(f) for f in all_fields(T)]) : String[string(f) for f in fields]
    chain(qs; values_fields = fs, group_by_object = any(p -> contains_aggregate(p.second), qs.annotations))
end
Base.values(::Type{T}, fields::Union{Symbol,AbstractString}...) where {T<:Model} = values(objects(T), fields...)

"""
    values_list(qs, fields...; flat=false) -> Vector

Field values as tuples, or as plain values with `flat=true` (one field). Fields may follow
relations and name annotations.
"""
function values_list(qs::QuerySet, fields::Union{Symbol,AbstractString}...; flat = false)
    flat && length(fields) != 1 && throw(ArgumentError("flat=true requires exactly one field"))
    rows = fetch(values(qs, fields...))
    keys_ = [Symbol(f) for f in fields]
    flat ? [r[keys_[1]] for r in rows] : [Tuple(r[k] for k in keys_) for r in rows]
end

"""
    aggregate(qs; name = Aggregate(...), ...) -> Dict{Symbol,Any}
    aggregate(qs, func, field)

Aggregate over the whole queryset: `aggregate(objects(Post); total = Sum(:views), n = Count())`.
The positional form (`:count`, `:sum`, `:avg`, `:min`, `:max`) returns a single value.
"""
function aggregate(qs::QuerySet{T}; kw...) where {T}
    isempty(kw) && throw(ArgumentError("aggregate needs at least one name = Aggregate(...)"))
    c = SQLCompiler(T)
    sel, ps = String[], Any[]
    for (k, v) in kw
        sql, p = compile_expr(c, ref(v))
        push!(sel, "$sql AS $(qname(string(k)))")
        append!(ps, p)
    end
    sub, sps = select_sql(qs; columns = qcol(c.table, "id"), ordered = false)
    row = execute("SELECT $(join(sel, ", ")) FROM $(qname(c.table))$(join(c.joins)) WHERE $(qcol(c.base, "id")) IN ($(in_subquery(backend(), sub)))",
                  vcat(ps, sps))[1]
    Dict{Symbol,Any}(k => row[k] for k in keys(kw))
end
function aggregate(qs::QuerySet, func::Symbol, field::Symbol)
    func in (:count, :sum, :avg, :min, :max) || throw(ArgumentError("unknown aggregate $func"))
    agg = Dict(:count => Count, :sum => Sum, :avg => Avg, :min => Min, :max => Max)[func]
    aggregate(qs; r = agg(field == :pk ? :id : field))[:r]
end
