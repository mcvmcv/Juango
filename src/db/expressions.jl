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

"""
    FilteredRelation(relation; condition = Q())

A relation joined with an extra condition in its ON clause, for `annotate`:

    qs = annotate(Author; approved = FilteredRelation(:post; condition = Q(post__status = "p")))
    filter(qs; approved__title__contains = "Julia")       # authors with a matching published post
    annotate(qs; n = Count(:approved))                   # count only published posts

The relation is a forward foreign key or a reverse relation of the model (one level). The
condition's lookups start with the relation's name and use only the related model's own
fields.
"""
struct FilteredRelation
    relation::String
    condition::Q
end
FilteredRelation(relation; condition::Q = Q()) = FilteredRelation(string(relation), condition)

"Whether an annotation is a `FilteredRelation` (a join, not a selected value)."
is_filtered_relation(x) = x isa FilteredRelation

"Turn a function argument into an expression: names are field references, the rest literals."
ref(x::FilteredRelation) = x
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

"An aggregate: `Count`, `Sum`, `Avg`, `Min`, `Max`."
struct Aggregate <: Expression
    func::String
    arg::Union{Nothing,Expression}
    distinct::Bool
    filter::Union{Nothing,Q}
    default::Any                    # COALESCE(aggregate, default) when there are no rows
    ordering::Vector{String}        # ORDER BY inside the aggregate (StringAgg, ArrayAgg): "name", "-created"
    delimiter::Union{Nothing,String}   # StringAgg
end
Aggregate(func, arg, distinct, filter; default = nothing, ordering = String[], delimiter = nothing) =
    Aggregate(func, arg, distinct, filter, default, ordering isa AbstractString ? [String(ordering)] : String[string(o) for o in ordering], delimiter)
"""
    Count(field=nothing; distinct=false, filter=nothing)

Count rows (`Count()`), non-NULL values of a field, or related objects (`Count(:posts)`).
`filter=Q(...)` counts only matching rows.
"""
Count(x = nothing; distinct = false, filter = nothing) = Aggregate("COUNT", x === nothing ? nothing : ref(x), distinct, filter)
Sum(x; distinct = false, filter = nothing, default = nothing) = Aggregate("SUM", ref(x), distinct, filter; default = default)
Avg(x; distinct = false, filter = nothing, default = nothing) = Aggregate("AVG", ref(x), distinct, filter; default = default)
Min(x; filter = nothing, default = nothing) = Aggregate("MIN", ref(x), false, filter; default = default)
Max(x; filter = nothing, default = nothing) = Aggregate("MAX", ref(x), false, filter; default = default)
"Standard deviation: of the population, or with `sample = true` of a sample."
StdDev(x; sample = false, filter = nothing, default = nothing) = Aggregate(sample ? "STDDEV_SAMP" : "STDDEV_POP", ref(x), false, filter; default = default)
"Variance: of the population, or with `sample = true` of a sample."
Variance(x; sample = false, filter = nothing, default = nothing) = Aggregate(sample ? "VAR_SAMP" : "VAR_POP", ref(x), false, filter; default = default)
"""
    ArrayAgg(x; distinct = false, ordering = [], filter = nothing, default = nothing)

The values as a `Vector` (a JSON array in the database, so it works everywhere; dates come back as
text). `ordering` sorts them: `ordering = "-created"`. MySQL ignores `ordering` (MariaDB sorts).
"""
ArrayAgg(x; distinct = false, ordering = String[], filter = nothing, default = nothing) =
    Aggregate("ARRAY_AGG", ref(x), distinct, filter; default = default, ordering = ordering)
"Like `ArrayAgg` (PostgreSQL's JSONBAgg: a JSON array of the values)."
JSONBAgg(x; kw...) = ArrayAgg(x; kw...)
"The values joined into one string with `delimiter` (STRING_AGG / GROUP_CONCAT)."
StringAgg(x, delimiter::AbstractString; distinct = false, ordering = String[], filter = nothing, default = nothing) =
    Aggregate("STRING_AGG", ref(x), distinct, filter; default = default, ordering = ordering, delimiter = String(delimiter))
"Whether all the values are true."
BoolAnd(x; filter = nothing, default = nothing) = Aggregate("BOOL_AND", ref(x), false, filter; default = default)
"Whether any of the values is true."
BoolOr(x; filter = nothing, default = nothing) = Aggregate("BOOL_OR", ref(x), false, filter; default = default)
"Bitwise AND of the values."
BitAnd(x; filter = nothing, default = nothing) = Aggregate("BIT_AND", ref(x), false, filter; default = default)
"Bitwise OR of the values."
BitOr(x; filter = nothing, default = nothing) = Aggregate("BIT_OR", ref(x), false, filter; default = default)

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
Base.xor(a::Union{Q,Exists}, b::Union{Q,Exists}, rest::Union{Q,Exists}...) =
    Q(:XOR, Any[c for x in (a, b, rest...) for c in xor_children(x)], false)

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

contains_window(::Any) = false
contains_window(::Window) = true
contains_window(e::CombinedExpression) = contains_window(e.lhs) || contains_window(e.rhs)
contains_window(e::Func) = any(contains_window, e.args)

contains_aggregate(::Any) = false
contains_aggregate(::Aggregate) = true
contains_aggregate(e::CombinedExpression) = contains_aggregate(e.lhs) || contains_aggregate(e.rhs)
contains_aggregate(e::Func) = any(contains_aggregate, e.args)
contains_aggregate(e::Case) = any(w -> contains_aggregate(w.then), e.whens) || contains_aggregate(e.default)
contains_aggregate(::Window) = false

# --- compilation ----------------------------------------------------------------------------

"Resolve a field path for expressions: returns (SQL column, Field or nothing)."
Base.@nospecializeinfer function resolve_path(c::SQLCompiler, alias, @nospecialize(T::Type), path::AbstractString)
    segs = String.(split(path, "__"))
    for (i, s) in enumerate(segs)
        last_ = i == length(segs)
        s == "pk" && (s = "id")
        if s == "id"
            last_ || throw(LookupError("'id' is not a relation in '$path'"))
            return qcol(alias, "id"), nothing
        end
        if i == 1 && alias == c.base && is_filtered_relation(get(c.annotations, Symbol(s), nothing))
            alias, T = filtered_join!(c, alias, T, Symbol(s))
            last_ && return qcol(alias, "id"), nothing
            continue
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
value_sql(b, v::Duration) = (duration_param_sql(b), Any[v])
value_sql(b, v) = ("?", Any[v])

compile_expr(c::SQLCompiler, e::Value) = value_sql(backend(), e.value)

function compile_expr(c::SQLCompiler, e::F)
    if !occursin("__", e.name) && haskey(c.annotations, Symbol(e.name)) && !is_filtered_relation(c.annotations[Symbol(e.name)])
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
    if e.op in ("+", "-")
        bk = backend()
        ka, kb = temporal_kind(c, e.lhs), temporal_kind(c, e.rhs)
        e.lhs isa Value && ka in (:datetime, :date) && (a = temporal_value_sql(bk, ka, a))
        e.rhs isa Value && kb in (:datetime, :date) && (b = temporal_value_sql(bk, kb, b))
        sql = temporal_sql(bk, e.op, ka, a, kb, b)
        sql === nothing || return sql, vcat(pa, pb)
    end
    "($a $(e.op) $b)", vcat(pa, pb)
end

# --- dates, times and durations in expressions ----------------------------------------------------------
#
#     annotate(Event; ends = F(:start) + F(:length))            # a datetime
#     filter(Event; finish__gt = F(:start) + Value(Hour(2)))
#     annotate(Event; took = F(:finish) - F(:start))            # a duration
#
# PostgreSQL does this natively (timestamps and intervals); MySQL and SQLite store durations as
# microseconds, so they get their own SQL.

"`:datetime`, `:date`, `:time` or `:duration` when an expression has that type, else nothing."
temporal_kind(c::SQLCompiler, e) = nothing
function temporal_kind(c::SQLCompiler, e::F)
    if !occursin("__", e.name) && haskey(c.annotations, Symbol(e.name))
        a = c.annotations[Symbol(e.name)]
        return is_filtered_relation(a) ? nothing : temporal_kind(c, a)
    end
    f = try
        last(resolve_path(c, c.base, c.T, e.name))
    catch
        nothing
    end
    f isa Field && f.kind in (:datetime, :date, :time, :duration) ? f.kind : nothing
end
function temporal_kind(c::SQLCompiler, e::Func)
    e.name === :trunc || return nothing
    trunc_output(e.args[2], something(temporal_kind(c, e.args[1]), :datetime))
end
temporal_kind(c::SQLCompiler, e::Value) = e.value isa Union{DateTime,TimeZones.ZonedDateTime} ? :datetime :
    e.value isa Date ? :date : e.value isa Dates.Time ? :time : e.value isa Duration ? :duration : nothing
function temporal_kind(c::SQLCompiler, e::Aggregate)
    e.arg === nothing && return nothing
    k = temporal_kind(c, e.arg)
    k === :duration && e.func in ("SUM", "AVG", "MIN", "MAX") ? k : k !== nothing && e.func in ("MIN", "MAX") ? k : nothing
end
function temporal_kind(c::SQLCompiler, e::CombinedExpression)
    ka, kb = temporal_kind(c, e.lhs), temporal_kind(c, e.rhs)
    dt(k) = k in (:datetime, :date)
    e.op in ("+", "-") && dt(ka) && kb === :duration && return :datetime
    e.op == "+" && ka === :duration && dt(kb) && return :datetime
    e.op == "-" && dt(ka) && dt(kb) && return :duration
    ka === :duration && (kb === :duration || (kb === nothing && e.op in ("*", "/"))) && return :duration
    kb === :duration && ka === nothing && e.op == "*" && return :duration
    nothing
end

"SQL for `a op b` when it adds a duration to a datetime or subtracts datetimes, else nothing."
function temporal_sql(b::DatabaseBackend, op, ka, a, kb, bsql)
    dt(k) = k in (:datetime, :date)
    dt(ka) && kb === :duration && return datetime_add_sql(b, op, a, bsql)
    op == "+" && ka === :duration && dt(kb) && return datetime_add_sql(b, "+", bsql, a)
    op == "-" && dt(ka) && dt(kb) && return datetime_diff_sql(b, ka, a, kb, bsql)
    nothing
end
"A datetime or date parameter in date arithmetic, cast so PostgreSQL knows its type."
temporal_value_sql(b::DatabaseBackend, kind, sql) = "CAST($sql AS $(cast_type(b, kind)))"
datetime_add_sql(::DatabaseBackend, op, a, d) = "($a $op $d)"
datetime_diff_sql(::DatabaseBackend, ka, a, kb, b) = ka === :date && kb === :date ? "(($a - $b) * INTERVAL '1 day')" : "($a - $b)"

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
    n === :extract && return date_part_expr(b, e.args[2], sqls[1], something(temporal_kind(c, e.args[1]), :datetime)), ps
    n === :trunc && return trunc_expr(b, e.args[2], sqls[1], something(temporal_kind(c, e.args[1]), :datetime)), ps
    n in (:similarity, :word_similarity, :strict_word_similarity, :unaccent) &&
        return uppercase(string(n)) * "(" * join(sqls, ", ") * ")", ps
    sql = function_sql(b, n, sqls, e)                 # functions.jl: Greatest, Replace, Round, Sqrt, ...
    sql === nothing || return sql, ps
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
    order = String[]
    for o in e.ordering
        osql, ops = compile_expr(c, F(lstrip(o, '-')))
        push!(order, osql * (startswith(o, "-") ? " DESC" : " ASC"))
        append!(ps, ops)
    end
    sql = aggregate_sql(backend(), e.func, (e.distinct ? "DISTINCT " : "") * arg, order, e)
    if e.default !== nothing
        dsql, dps = compile_expr(c, lit_expr(e.default))
        sql = "COALESCE($sql, $dsql)"
        append!(ps, dps)
    end
    sql, ps
end

sql_string_literal(s) = "'" * replace(s, "'" => "''") * "'"
obsql(order) = isempty(order) ? "" : " ORDER BY " * join(order, ", ")
"SQL for an aggregate (`arg` already has DISTINCT); PostgreSQL's spelling by default."
function aggregate_sql(::DatabaseBackend, func, arg, order, e)
    func == "ARRAY_AGG" && return "CAST(JSON_AGG($arg$(obsql(order))) AS TEXT)"
    func == "STRING_AGG" && return "STRING_AGG(CAST($arg AS TEXT), $(sql_string_literal(e.delimiter))$(obsql(order)))"
    "$func($arg)"
end
function aggregate_sql(::MySQLBackend, func, arg, order, e)
    func == "ARRAY_AGG" && return "JSON_ARRAYAGG($arg$(occursin("MariaDB", vendor(backend())) ? obsql(order) : ""))"
    func == "STRING_AGG" && return "GROUP_CONCAT($arg$(obsql(order)) SEPARATOR $(sql_string_literal(e.delimiter)))"
    func == "BOOL_AND" && return "MIN($arg)"
    func == "BOOL_OR" && return "MAX($arg)"
    "$func($arg)"
end
function aggregate_sql(::SQLiteBackend, func, arg, order, e)
    func == "ARRAY_AGG" && return "json_group_array($arg$(obsql(order)))"
    func == "STRING_AGG" && return "GROUP_CONCAT($arg, $(sql_string_literal(e.delimiter))$(obsql(order)))"
    func == "BOOL_AND" && return "MIN($arg)"
    func == "BOOL_OR" && return "MAX($arg)"
    func in ("STDDEV_POP", "STDDEV_SAMP", "VAR_POP", "VAR_SAMP", "BIT_AND", "BIT_OR") && return "juango_$(lowercase(func))($arg)"
    "$func($arg)"
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
Base.@nospecializeinfer function annotate(@nospecialize(qs::QuerySet); kw...)
    T = model_of(qs)
    anns = copy(qs.annotations)
    for (k, v) in kw
        (findfield(modelmeta(T), k) !== nothing || k in (:id, :pk)) &&
            throw(ArgumentError("annotation '$k' conflicts with a field of $T"))
        push!(anns, k => ref(v))
    end
    chain(qs; annotations = anns)
end
Base.@nospecializeinfer annotate(@nospecialize(T::Type{<:Model}); kw...) = annotate(objects(T); kw...)
annotate(; kw...) = qs -> annotate(qs; kw...)

"""
    values(qs, fields...) -> QuerySet

The results as `Dict{Symbol,Any}` rows instead of objects. Fields may follow relations
(`:author__name`). With aggregate annotations the rows are grouped by these fields:
`values(objects(Post), :status) |> annotate(n = Count(:id))`.
"""
Base.@nospecializeinfer function Base.values(@nospecialize(qs::QuerySet), fields::Union{Symbol,AbstractString}...)
    T = model_of(qs)
    fs = isempty(fields) ? vcat(["id"], [column(f) for f in all_fields(T)]) : String[string(f) for f in fields]
    chain(qs; values_fields = fs, group_by_object = any(p -> contains_aggregate(p.second), qs.annotations))
end
Base.@nospecializeinfer Base.values(@nospecialize(T::Type{<:Model}), fields::Union{Symbol,AbstractString}...) = values(objects(T), fields...)

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
aggregate(qs::QuerySet; kw...) = in_db(() -> aggregate_here(qs; kw...), qs)

const DATETIME_RESULT = Field(:datetime)       # converts computed datetimes like a DateTimeField's values

"The DecimalField an expression's values come from (`F(:price)`, `Sum(:price)`, `F(:price) * 2`), else nothing."
Base.@nospecializeinfer decimal_source(@nospecialize(T), e) = nothing
Base.@nospecializeinfer function decimal_source(@nospecialize(T), e::F)
    f = try
        last(resolve_path(SQLCompiler(T), modelmeta(T).table, T, e.name))
    catch
        nothing
    end
    f isa Field && f.kind === :decimal ? f : nothing
end
Base.@nospecializeinfer decimal_source(@nospecialize(T), e::Aggregate) = e.func in ("SUM", "MIN", "MAX", "AVG") && e.arg !== nothing ? decimal_source(T, e.arg) : nothing
Base.@nospecializeinfer decimal_source(@nospecialize(T), e::CombinedExpression) = something(decimal_source(T, e.lhs), decimal_source(T, e.rhs), Some(nothing))

"""
A computed value (annotation or aggregate) as Julia sees it: Decimals for expressions over a
DecimalField (rounded to its places, except for averages and arithmetic), other non-integer
numbers as Float64.
"""
Base.@nospecializeinfer function expr_value(@nospecialize(T), e, v)
    v === nothing && return nothing
    if e isa Aggregate
        e.func == "ARRAY_AGG" && return v isa AbstractString ? JSON.parse(v) : v
        e.func in ("BOOL_AND", "BOOL_OR") && return v isa Bool ? v : v != 0
    end
    if e isa Union{CombinedExpression,Aggregate} || (e isa Func && e.name === :trunc)
        k = try temporal_kind(SQLCompiler(T), e) catch; nothing end
        k === :duration && return to_duration(v)
        k === :datetime && e isa Union{CombinedExpression,Func} && return from_db(DATETIME_RESULT, v)
        k === :date && e isa Func && return v isa Date ? v : Date(todatetime(v))
        k === :time && e isa Func && return to_time(v)
    end
    f = decimal_source(T, e)
    if f !== nothing
        # SQLite computes with doubles: keep the 15 digits they hold, not the binary noise
        d = to_decimal(v isa AbstractFloat ? round(v; sigdigits = 15) : v)
        return (e isa Aggregate && e.func == "AVG") || e isa CombinedExpression ? d : round(d; digits = f.decimal_places)
    end
    v isa Decimal ? Float64(v) : v
end
Base.@nospecializeinfer function aggregate_here(@nospecialize(qs::QuerySet); kw...)
    T = model_of(qs)
    isempty(kw) && throw(ArgumentError("aggregate needs at least one name = Aggregate(...)"))
    c = SQLCompiler(T)
    for (k, v) in qs.annotations
        is_filtered_relation(v) && (c.annotations[k] = v)
    end
    sel, ps = String[], Any[]
    for (k, v) in kw
        sql, p = compile_expr(c, ref(v))
        push!(sel, "$sql AS $(qname(string(k)))")
        append!(ps, p)
    end
    sub, sps = select_sql(qs; columns = pk_select(c.table, T), ordered = false)
    row = execute("SELECT $(join(sel, ", ")) FROM $(qname(c.table))$(join(c.joins)) WHERE $(pk_ref(c.base, T)) IN ($(in_subquery(backend(), sub)))",
                  vcat(ps, c.join_params, sps))[1]
    Dict{Symbol,Any}(k => expr_value(T, ref(v), row[k]) for (k, v) in kw)
end
function aggregate(qs::QuerySet, func::Symbol, field::Symbol)
    func in (:count, :sum, :avg, :min, :max) || throw(ArgumentError("unknown aggregate $func"))
    agg = Dict(:count => Count, :sum => Sum, :avg => Avg, :min => Min, :max => Max)[func]
    aggregate(qs; r = agg(field == :pk ? :id : field))[:r]
end
