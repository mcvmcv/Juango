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
"""
    JSONObject(; name = :name, total = F(:price) * 2, ...)

A JSON object built in the database (Django 3.2), which comes back as a Dict: the keys are the
keyword names, the values expressions (a field name, `F(...)`, a function, ...).
"""
JSONObject(; kw...) = Func(:jsonobject, Any[x for (k, v) in kw for x in (string(k), ref(v))])
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
    ordering::Vector{Any}           # ORDER BY inside the aggregate (StringAgg, ArrayAgg): "name", "-created", Desc(...)
    delimiter::Union{Nothing,String}   # StringAgg
end
Aggregate(func, arg, distinct, filter; default = nothing, ordering = String[], delimiter = nothing) =
    Aggregate(func, arg, distinct, filter, default, ordering isa Union{AbstractString,Symbol,OrderBy,Expression} ? Any[order_item(ordering)] : Any[order_item(o) for o in ordering], delimiter)
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
"The value of `x` in the first row of the window frame."
FirstValue(x) = WindowFunc("FIRST_VALUE", Any[ref(x)])
"The value of `x` in the last row of the window frame (give the Window a frame to the end: `frame = RowRange()`)."
LastValue(x) = WindowFunc("LAST_VALUE", Any[ref(x)])
"The value of `x` in the `n`th row of the window frame (1-based)."
NthValue(x, n::Integer = 1) = (n >= 1 || throw(ArgumentError("NthValue: n must be at least 1")); WindowFunc("NTH_VALUE", Any[ref(x), Value(n)]))
"Which of `n` roughly equal buckets the row is in (1 to n)."
Ntile(n::Integer = 1) = (n >= 1 || throw(ArgumentError("Ntile: n must be at least 1")); WindowFunc("NTILE", Any[Value(n)]))
"The row's relative rank, from 0 to 1: (rank - 1) / (rows - 1)."
PercentRank() = WindowFunc("PERCENT_RANK", Any[])
"The fraction of rows up to and including the row's peers, from 0 to 1."
CumeDist() = WindowFunc("CUME_DIST", Any[])

"""
    RowRange(; start = nothing, stop = nothing, exclusion = nothing)
    ValueRange(; start = nothing, stop = nothing, exclusion = nothing)

A window frame, as Django's: `Window(Sum(:amount); order_by = ["day"], frame = RowRange(start = -2, stop = 0))`
is a sum over the row and the two before it (`ROWS BETWEEN 2 PRECEDING AND CURRENT ROW`).
`ValueRange` (`RANGE`) counts in the ordering's values instead of rows. `start`/`stop`: `nothing`
is unbounded, 0 the current row, a negative number rows (or values) before, a positive number after.
`exclusion` (PostgreSQL and SQLite): `:current_row`, `:group`, `:ties` or `:no_others`.
"""
struct WindowFrame
    kind::String                      # "ROWS" or "RANGE"
    start::Union{Nothing,Int}
    stop::Union{Nothing,Int}
    exclusion::Union{Nothing,Symbol}
    function WindowFrame(kind, start, stop, exclusion)
        exclusion === nothing || exclusion in (:current_row, :group, :ties, :no_others) ||
            throw(ArgumentError("exclusion must be :current_row, :group, :ties or :no_others"))
        start !== nothing && stop !== nothing && start > stop && throw(ArgumentError("a window frame's start must not be after its stop"))
        new(string(kind), start, stop, exclusion)
    end
end
RowRange(; start = nothing, stop = nothing, exclusion = nothing) = WindowFrame("ROWS", start, stop, exclusion)
frame_bound(n, unbounded) = n === nothing ? "UNBOUNDED $unbounded" : n == 0 ? "CURRENT ROW" : n < 0 ? "$(-n) PRECEDING" : "$n FOLLOWING"
function frame_sql(b::DatabaseBackend, f::WindowFrame)
    s = "$(f.kind) BETWEEN $(frame_bound(f.start, "PRECEDING")) AND $(frame_bound(f.stop, "FOLLOWING"))"
    if f.exclusion !== nothing
        b isa MySQLBackend && throw(ArgumentError("MySQL and MariaDB don't support window frame exclusion"))
        s *= " EXCLUDE " * uppercase(replace(string(f.exclusion), "_" => " "))
    end
    s
end

"""
    Window(expr; partition_by=[], order_by=[])

`expr OVER (PARTITION BY ... ORDER BY ...)`. `expr` is a window function or an aggregate
(`Window(Sum(:views); partition_by=[:author])`). `order_by` takes strings like `"-views"`.
"""
struct Window <: Expression
    expr::Expression
    partition_by::Vector{Any}
    order_by::Vector{Any}            # "field" / "-field" strings and OrderBy terms
    frame::Union{Nothing,WindowFrame}
end
Window(expr; partition_by = [], order_by = [], frame = nothing) =
    Window(expr, Any[ref(p) for p in partition_by], Any[order_item(o) for o in order_by], frame)

"""
    Asc(expr; nulls_first = false, nulls_last = false)
    Desc(expr; nulls_first = false, nulls_last = false)

An ordering term, for `order_by`, `Window(order_by = ...)`, `Meta(ordering = ...)` and aggregates'
`ordering`: any expression (a field name is an `F`), ascending or descending, with NULLs placed first
or last (otherwise each database's default: last for ascending on PostgreSQL, first on SQLite and
MySQL).

    order_by(qs, Asc(Coalesce(:started, :planned); nulls_last = true), "id")
    order_by(qs, Desc(:upper_bound; nulls_last = true))
"""
struct OrderBy
    expr::Any                         # an Expression
    descending::Bool
    nulls_first::Union{Nothing,Bool}  # nothing: the database's default
end
function order_nulls(nulls_first::Bool, nulls_last::Bool)
    nulls_first && nulls_last && throw(ArgumentError("nulls_first and nulls_last can't both be true"))
    nulls_first ? true : nulls_last ? false : nothing
end
Asc(x; nulls_first::Bool = false, nulls_last::Bool = false) = OrderBy(ref(x), false, order_nulls(nulls_first, nulls_last))
Desc(x; nulls_first::Bool = false, nulls_last::Bool = false) = OrderBy(ref(x), true, order_nulls(nulls_first, nulls_last))
"An `order_by` argument as stored: strings stay strings (\"-name\"), expressions become `Asc(expr)`."
order_item(o::OrderBy) = o
order_item(o::Expression) = OrderBy(o, false, nothing)
order_item(o) = string(o)
"The term for the opposite direction (`last`, `latest`): NULL placement flips too, as in Django."
reverse_order(o::OrderBy) = OrderBy(o.expr, !o.descending, o.nulls_first === nothing ? nothing : !o.nulls_first)
reverse_order(o::AbstractString) = startswith(o, "-") ? o[2:end] : "-" * o

"SQL for an ordering term, with its parameters."
function compile_order_item(c::SQLCompiler, o)
    ob = o isa OrderBy ? o : OrderBy(F(lstrip(string(o), '-')), startswith(string(o), "-"), nothing)
    sql, ps = compile_expr(c, ob.expr)
    order_term_sql(backend(), sql, ps, ob.descending, ob.nulls_first)
end
order_term_sql(::DatabaseBackend, sql, ps, desc, nf) =
    sql * (desc ? " DESC" : " ASC") * (nf === nothing ? "" : nf ? " NULLS FIRST" : " NULLS LAST"), ps
# MySQL/MariaDB have no NULLS FIRST/LAST: order by whether it's NULL first, as Django does
order_term_sql(::MySQLBackend, sql, ps, desc, nf) = nf === nothing ? (sql * (desc ? " DESC" : " ASC"), ps) :
    ("($sql) IS NULL " * (nf ? "DESC" : "ASC") * ", " * sql * (desc ? " DESC" : " ASC"), vcat(ps, ps))

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
            # data__run__0: a key path inside a JSON field (values, values_list, order_by, F)
            f.kind === :json && !last_ && return json_path_sql(backend(), qcol(alias, column(f)), segs[i+1:end]), f
            if last_ || f.kind !== :fk
                last_ || throw(LookupError("'$s' is not a relation in '$path'"))
                return qcol(alias, column(f)), f
            end
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, "id", column(f); left = f.null)
            T = related_model(f)
            continue
        end
        mm = find_m2m_query(T, s)
        if mm !== nothing
            s1, s2 = m2m_path(mm[2], mm[3])
            return resolve_path(c, alias, T, join(vcat([string(s1), string(s2)], segs[i+1:end], last_ ? ["id"] : String[]), "__"))
        end
        g = find_generic(generic_relations(T), s)
        if g !== nothing
            M = related_model(g)
            ctf, fkf = g.through
            ctcol, ctid = column(getfield_meta(M, ctf)), get_for_model(T).id::Integer
            alias = join!(c, alias, expr_key(c, alias, g.name), modelmeta(M).table, column(getfield_meta(M, fkf)), "id";
                          left = true, extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            T = M
            last_ && return qcol(alias, "id"), nothing
            continue
        end
        rel = find_reverse(T, s)
        rel === nothing && throw(lookup_error(T, s))
        rn, M, rf = rel
        alias = join!(c, alias, expr_key(c, alias, rn), modelmeta(M).table, column(rf), "id"; left = true)
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
    if n === :jsonobject                               # keys are literals (PostgreSQL can't type a parameter here)
        keys_ = [sql_string_literal(b, string(e.args[i])) for i in 1:2:length(e.args)]
        items = join([k * ", " * v for (k, v) in zip(keys_, sqls)], ", ")
        return (b isa PostgresBackend ? "JSON_BUILD_OBJECT(" : "JSON_OBJECT(") * items * ")", ps
    end
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

"The join key of a multi-valued relation in an expression (see `scope_key`)."
function expr_key(c::SQLCompiler, alias, rn)
    old = c.scope
    c.scope = :expr
    try
        scope_key(c, alias, rn)
    finally
        c.scope = old
    end
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
        osql, ops = compile_order_item(c, o)
        push!(order, osql)
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
            col, ops = compile_order_item(c, o)
            push!(os, col)
            append!(ps, ops)
        end
        push!(over, "ORDER BY " * join(os, ", "))
    end
    e.frame === nothing || push!(over, frame_sql(backend(), e.frame))
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
    after = copy(qs.annotated_after)
    for (k, _) in kw
        after[k] = length(qs.where)
    end
    chain(qs; annotations = anns, annotated_after = after)
end
Base.@nospecializeinfer annotate(@nospecialize(T::Type{<:Model}); kw...) = annotate(objects(T); kw...)
annotate(; kw...) = qs -> annotate(qs; kw...)

"""
    values(qs, fields...) -> QuerySet

The results as `Dict{Symbol,Any}` rows instead of objects. Fields may follow relations
(`:author__name`). With aggregate annotations the rows are grouped by these fields:
`values(objects(Post), :status) |> annotate(n = Count(:id))`.
"""
function Base.values(@nospecialize(qs::QuerySet), fields::Union{Symbol,AbstractString}...)
    T = model_of(qs)
    fs = isempty(fields) ? vcat(["id"], [column(f) for f in all_fields(T)]) : String[string(f) for f in fields]
    chain(qs; values_fields = fs, values_mode = :dict, group_by_object = any(p -> contains_aggregate(p.second), qs.annotations))
end
Base.values(@nospecialize(T::Type{<:Model}), fields::Union{Symbol,AbstractString}...) = values(objects(T), fields...)

"""
    values_list(qs, fields...; flat = false, named = false) -> QuerySet

The rows as tuples of field values, as named tuples with `named = true`, or as plain values
with `flat = true` (one field). Fields may follow relations and name annotations.

Like Django's, the result is a lazy QuerySet: nothing runs until it's iterated, collected or
compared, so it chains (`order_by`, `distinct`, slicing, `count`, `exists`), `first` and `last`
give `nothing` when there are no rows, and `filter(Plate; id__in = values_list(qs, :plate_id; flat = true))`
is one query with a subquery. `collect` it for a `Vector`.

Since it isn't a `Vector`, some vector code needs `collect` first: `[qs1; qs2]` makes a vector of
two querysets (not their rows; using it as a query value is an error), `filter(pred, qs)` is the
ORM's `filter`, and `findfirst`/indexing by position need `keys`. `union(qs1, qs2)` or
`Q(...) | Q(...)` combine querysets in the database.
"""
# A plain method that gathers the fields, and a despecialized one with fixed arguments: a
# @nospecializeinfer method with both a vararg and keywords lost its last field in some
# precompiled callers (#185).
values_list(qs::QuerySet, fields::Union{Symbol,AbstractString}...; flat::Bool = false, named::Bool = false) =
    values_list_of(qs, Any[f for f in fields], flat, named)
Base.@nospecializeinfer function values_list_of(@nospecialize(qs::QuerySet), fields::Vector{Any}, flat::Bool, named::Bool)
    flat && named && throw(ArgumentError("values_list: pass flat or named, not both"))
    flat && length(fields) != 1 && throw(ArgumentError("flat=true requires exactly one field"))
    T = model_of(qs)
    fs = isempty(fields) ? Any[:id; [Symbol(column(f)) for f in all_fields(T)]] : fields
    vq = values(qs, fs...)
    length(vq.values_fields) == length(fs) || error("values_list: asked for $(length(fs)) fields, got $(length(vq.values_fields))")
    chain(vq; values_mode = flat ? :flat : named ? :named : :tuple)
end
values_list(@nospecialize(T::Type{<:Model}), fields::Union{Symbol,AbstractString}...; kw...) = values_list(objects(T), fields...; kw...)

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
    output_field(T, e) -> Field or nothing

The field an expression's values have the type of, as Django's `output_field`: a field reference
(through annotations too), `Max`/`Min` of one, `Coalesce`/`Greatest`/`Least`/`NullIf` (their first
argument with a field), and a `Subquery` selecting one value (the selected field, in the
subquery's model). `nothing` for anything else (counts, sums and arithmetic have their own rules).
"""
Base.@nospecializeinfer output_field(@nospecialize(T), @nospecialize(e)) = nothing
Base.@nospecializeinfer function output_field(@nospecialize(T), e::F)
    name = e.name
    try
        f = last(resolve_path(SQLCompiler(T), modelmeta(T).table, T, name))
        f isa Field ? f : nothing
    catch
        nothing
    end
end
Base.@nospecializeinfer output_field(@nospecialize(T), e::Aggregate) =
    e.func in ("MIN", "MAX") && e.arg !== nothing ? output_field(T, e.arg) : nothing
Base.@nospecializeinfer function output_field(@nospecialize(T), e::Func)
    e.name in (:coalesce, :greatest, :least, :nullif) || return nothing
    for a in e.args
        f = output_field(T, a)
        f === nothing || return f
    end
    nothing
end
Base.@nospecializeinfer output_field(@nospecialize(T), e::WindowFunc) =
    e.name in ("FIRST_VALUE", "LAST_VALUE", "NTH_VALUE", "LAG", "LEAD") ? output_field(T, e.args[1]) : nothing
Base.@nospecializeinfer output_field(@nospecialize(T), e::Window) = output_field(T, e.expr)
Base.@nospecializeinfer function output_field(@nospecialize(T), e::Subquery)
    qs = e.qs
    qs isa QuerySet && qs.values_fields !== nothing && length(qs.values_fields) == 1 || return nothing
    M = model_of(qs)
    name = Symbol(qs.values_fields[1])
    for (k, a) in qs.annotations                     # values() of one of the subquery's annotations
        k === name && return output_field(M, a)
    end
    output_field(M, F(string(name)))
end

"Field kinds a computed value is converted to through its `output_field` (the text and numbers some backends give back)."
const TYPED_OUTPUT_KINDS = (:date, :datetime, :time, :uuid, :bool, :duration)

"""
A computed value (annotation or aggregate) as Julia sees it: through its `output_field` for
dates, times, UUIDs and booleans (SQLite gives text and integers), Decimals for expressions over
a DecimalField (rounded to its places, except for averages and arithmetic), other non-integer
numbers as Float64.
"""
Base.@nospecializeinfer expr_value(@nospecialize(T), e, v) = expr_value(T, e, v, typed_output(T, e))
"The output field to convert an expression's values through (`expr_value`), or nothing: work it out once per query."
Base.@nospecializeinfer function typed_output(@nospecialize(T), @nospecialize(e))
    e isa Union{F,Aggregate,Func,Subquery,Window,WindowFunc} || return nothing
    of = output_field(T, e)
    of !== nothing && of.kind in TYPED_OUTPUT_KINDS ? of : nothing
end
Base.@nospecializeinfer function expr_value(@nospecialize(T), e, v, of::Union{Nothing,Field})
    v === nothing && return nothing
    e isa Exists && return v isa Bool ? v : v != 0          # SQLite and MySQL give 0/1
    if e isa Aggregate
        e.func == "ARRAY_AGG" && return v isa AbstractString ? JSON.parse(v) : v
        e.func in ("BOOL_AND", "BOOL_OR") && return v isa Bool ? v : v != 0
    end
    of === nothing || return from_db(of, v)
    e isa Func && e.name === :jsonobject && return v isa AbstractString ? JSON.parse(v) : v
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
"Whether an aggregate's argument goes through a relation (`Count(:book)`, `Sum(\"book__pages\")`)."
Base.@nospecializeinfer function aggregates_relation(@nospecialize(T::Type), v)
    a = v isa Aggregate ? v.arg : nothing
    a isa F || return false
    s = first(split(a.name, "__"))
    s in ("id", "pk") && return false
    f = findfield(modelmeta(T), Symbol(s))
    f === nothing || (f.kind === :fk && occursin("__", a.name))
end

"""
Aggregates over relations, after filter() calls on them: computed over the filters' joins (as in
Django), so `aggregate(filter(Author; book__shelf = 1); n = Count(:book))` counts the books on
that shelf. Only for a plain filtered queryset (no slicing, distinct, annotations or combining).
"""
Base.@nospecializeinfer function aggregate_joined(@nospecialize(qs::QuerySet), kw)
    T = model_of(qs)
    c = SQLCompiler(T)
    wsql, wps = where_clause(c, qs)                # each filter() call's joins, as in the query itself
    c.reuse_upto = length(qs.where)
    sel, ps = String[], Any[]
    for (k, v) in kw
        sql, p = compile_expr(c, ref(v))
        push!(sel, "$sql AS $(qname(string(k)))")
        append!(ps, p)
    end
    row = execute("SELECT $(join(sel, ", ")) FROM $(qname(c.table))$(join(c.joins))$wsql", vcat(ps, c.join_params, wps))[1]
    Dict{Symbol,Any}(k => expr_value(T, ref(v), row[k]) for (k, v) in kw)
end

Base.@nospecializeinfer function aggregate_here(@nospecialize(qs::QuerySet); kw...)
    T = model_of(qs)
    isempty(kw) && throw(ArgumentError("aggregate needs at least one name = Aggregate(...)"))
    plain = !isempty(qs.where) && qs.limit === nothing && qs.offset == 0 && qs.distinct_fields === nothing &&
            qs.combinator === nothing && isempty(qs.annotations) && qs.values_fields === nothing && !qs.isnone
    rel = plain ? [k for (k, v) in kw if aggregates_relation(T, ref(v))] : Symbol[]
    if !isempty(rel)
        out = aggregate_joined(qs, [k => v for (k, v) in kw if k in rel])
        rest = [k => v for (k, v) in kw if !(k in rel)]
        isempty(rest) || merge!(out, aggregate_here(qs; rest...))
        return out
    end
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
