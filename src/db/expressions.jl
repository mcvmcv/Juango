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
ref(x::Q) = Condition(x)
ref(x::Union{Symbol,AbstractString}) = F(string(x))
ref(x) = Value(x)
lit_expr(x::Expression) = x
lit_expr(x::Q) = Condition(x)
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
Cast(x, kind::Symbol) = Func(:cast, Any[ref(x), kind === :integer ? :int : kind])
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

"""
`When(Q(...); then=value)` or `When(; then=value, lookups...)`, used inside `Case`; a Q or a boolean
expression (`Exists`, `GreaterThan`...) and lookups together are ANDed (`When(Q(a = 1); b = 2, then = x)`).
"""
struct When
    cond::Q
    then::Expression
    When(cond::Q, then::Expression) = new(cond, then)
end
const WHEN_CONDITION_ERROR = "When() supports a Q object, a boolean expression, or lookups as a condition."
function when_condition(cond, kw)
    bad = sort([string(k) for k in keys(kw) if startswith(string(k), "_")])
    isempty(bad) || throw(ArgumentError("The following kwargs are invalid: " * join(["'$b'" for b in bad], ", ")))
    cond === nothing && isempty(kw) && throw(ArgumentError(WHEN_CONDITION_ERROR))
    cond === nothing || cond isa Conditional || throw(ArgumentError(WHEN_CONDITION_ERROR))
    q = cond === nothing ? Q(; kw...) : isempty(kw) ? as_q(cond) : as_q(cond) & Q(; kw...)
    (q.connector === :AND && isempty(q.children)) && throw(ArgumentError("An empty Q() can't be used as a When() condition."))
    q
end
When(cond; then = nothing, kw...) = When(when_condition(cond, kw), lit_expr(then))
When(; then = nothing, condition = nothing, kw...) = When(when_condition(condition, kw), lit_expr(then))
Base.:(==)(a::When, b::When) = a.cond == b.cond && a.then == b.then
Base.hash(w::When, h::UInt) = hash(expr_hash_key(w.then), hash(expr_hash_key(w.cond), hash(:When, h)))

"""
`Case(When(...), When(...); default = value, output_field = nothing)`: SQL CASE WHEN ... END. The
values' type comes from `output_field`, else from the first `then` (or the default) with one: a field,
or a literal's (`true`, a `Date`...).
"""
struct Case <: Expression
    whens::Vector{When}
    default::Expression
    output::Any                     # output_field: a Field, or nothing
    Case(whens::Vector{When}, default::Expression, output) = new(whens, default, output)
end
Case(whens::When...; default = nothing, output_field = nothing) = Case(collect(When, whens), lit_expr(default), output_field)
Case(args...; kw...) = throw(ArgumentError("Positional arguments must all be When objects."))
output_kind(o) = o isa Field ? o.kind : o
Base.:(==)(a::Case, b::Case) = a.whens == b.whens && a.default == b.default && output_kind(a.output) === output_kind(b.output)
Base.hash(c::Case, h::UInt) = hash(output_kind(c.output), hash(expr_hash_key(c.default), hash(c.whens, hash(:Case, h))))
# What two expressions built alike hash as: a Q's lists and tuples alike (as Django's make_hashable).
expr_hash_key(x::Tuple) = Any[expr_hash_key(v) for v in x]
expr_hash_key(x::AbstractVector) = Any[expr_hash_key(v) for v in x]
expr_hash_key(x::Pair) = expr_hash_key(x.first) => expr_hash_key(x.second)
expr_hash_key(q::Q) = (q.connector, q.negated, expr_hash_key(q.children))
expr_hash_key(x) = x

"Inside a `Subquery`/`Exists`, a field of the outer query: `filter(Post; author = OuterRef(:id))`."
struct OuterRef <: Expression
    name::String
    nested::Any       # OuterRef(OuterRef(:name)): a field two queries out (#208); nothing otherwise
end
OuterRef(s::AbstractString) = OuterRef(String(s), nothing)
OuterRef(s::Symbol) = OuterRef(string(s), nothing)
OuterRef(o::OuterRef) = OuterRef(o.name, o)

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

"""
A condition used as a value, true or false: what a `Q` becomes in `annotate`, as a `When`'s
`then`, or as a lookup's value (Django's `Q` in annotate, or `ExpressionWrapper(Q(...),
output_field = BooleanField())`). `annotate(qs; big = Q(num_employees__gt = 100))` (#199).
"""
struct Condition <: Expression
    q::Q
end
Base.:!(e::Exists) = Exists(e.qs, !e.negated)

"""
    Exact(lhs, rhs), IExact, GreaterThan, GreaterThanOrEqual, LessThan, LessThanOrEqual, In, Range, IsNull,
    Contains, IContains, StartsWith, IStartsWith, EndsWith, IEndsWith

A lookup as a boolean expression, for `annotate`, `filter`, `order_by`, `When` and aggregates
(Django's lookup classes): `annotate(qs; modern = GreaterThan(F(:year), 1900))`,
`filter(qs, Exact(F(:year), 1942) | GreaterThan(F(:year), 2000))`. Either side may be a field
(`F`), an expression or a value (#206).
"""
struct LookupExpr <: Expression
    lookup::String
    lhs::Expression
    rhs::Any
end
for (name, lk) in ((:Exact, "exact"), (:IExact, "iexact"), (:GreaterThan, "gt"), (:GreaterThanOrEqual, "gte"),
                   (:LessThan, "lt"), (:LessThanOrEqual, "lte"), (:In, "in"), (:Range, "range"), (:IsNull, "isnull"),
                   (:Contains, "contains"), (:IContains, "icontains"), (:StartsWith, "startswith"),
                   (:IStartsWith, "istartswith"), (:EndsWith, "endswith"), (:IEndsWith, "iendswith"))
    @eval $name(lhs, rhs) = LookupExpr($lk, ref(lhs), rhs isa Q ? Condition(rhs) : rhs)    # a name on the left is a field
end

"""
    RawSQL(sql, params = []; output = nothing)

An SQL fragment as an expression, with `?` (or Django's `%s`) placeholders for `params`: in
`annotate`, `filter` (a boolean one), `order_by` (`Desc(RawSQL(...))`) and aggregates. `output`
(`:bool`, `:int`, `:datetime`, ..., or a field) converts its values. Never put user input in `sql`:
pass it as a parameter (#215).
"""
struct RawSQL <: Expression
    sql::String
    params::Vector{Any}
    output::Any
end
RawSQL(sql::AbstractString, params = Any[]; output = nothing) =
    RawSQL(replace(String(sql), "%s" => "?"), collect(Any, params), output_of(output))

"""
    ExpressionWrapper(expr; output)

An expression with a given output type (`:duration`, `:bool`, `:datetime`, ... or a field), so its
values convert: `ExpressionWrapper(F(:start) + F(:estimated_time); output = :datetime)` (#215).
"""
struct ExpressionWrapper <: Expression
    expr::Expression
    output::Any
end
ExpressionWrapper(e; output) = ExpressionWrapper(ref(e), output_of(output))
output_of(::Nothing) = nothing
output_of(f) = f
function output_of(k::Symbol)
    k === :bool ? BooleanField() : k in (:int, :integer) ? IntegerField() : k === :bigint ? BigIntegerField() :
    k === :float ? FloatField() : k === :decimal ? DecimalField(max_digits = 65, decimal_places = 15) :
    k in (:text, :string) ? TextField() : k === :date ? DateField() : k === :datetime ? DateTimeField() :
    k === :time ? TimeField() : k === :duration ? DurationField() : k === :uuid ? UUIDField() :
    k === :json ? JSONField() : throw(ArgumentError("output: unknown kind :$k"))
end
compile_expr(c::SQLCompiler, e::RawSQL) = ("($(e.sql))", copy(e.params))
function compile_expr(c::SQLCompiler, e::ExpressionWrapper)
    sql, ps = compile_expr(c, e.expr)
    # a date or datetime parameter: PostgreSQL can't tell its type (EXTRACT(YEAR FROM $1) is ambiguous)
    k = e.output isa Field ? e.output.kind : nothing
    backend() isa PostgresBackend && e.expr isa Value && k in (:date, :datetime) && (sql = temporal_value_sql(backend(), k, sql))
    sql, ps
end
contains_aggregate(e::ExpressionWrapper) = contains_aggregate(e.expr)
contains_window(e::ExpressionWrapper) = contains_window(e.expr)
bare_refs(e::ExpressionWrapper) = bare_refs(e.expr)
refs_columns(::RawSQL) = true
refs_columns(e::ExpressionWrapper) = refs_columns(e.expr)

"`~F(:flag)`, `~Value(false)`: a boolean expression negated (Django's `~F()`, #218)."
struct NegatedExpr <: Expression
    expr::Expression
end
Base.:~(e::Union{F,Value,Func,Case,Subquery}) = NegatedExpr(e)
Base.:~(e::NegatedExpr) = e.expr
Base.:!(e::NegatedExpr) = e.expr
function compile_expr(c::SQLCompiler, e::NegatedExpr)
    # ~F(:name) on a text field: Django's "Cannot negate non-conditional expressions" (SQLite would compute NOT 'd0')
    if e.expr isa F
        of = try output_field(c.T, e.expr) catch; nothing end
        of === nothing || of.kind === :bool ||
            throw(ArgumentError("~F(:$(e.expr.name)): only a boolean can be negated, not a $(of.kind) field"))
    end
    sql, ps = compile_expr(c, e.expr)
    "(NOT $(boolean_operand(backend(), sql)))", ps
end
boolean_operand(::DatabaseBackend, sql) = "($sql)"

# Conditions combine with & | ~ and xor whatever they are: Q objects, Exists, lookups, a Q's condition
# (Django's conditional expressions: Q(genre = "poetry") & ~Exists(...), #223)
const Conditional = Union{Q,Exists,LookupExpr,Condition,NegatedExpr}
as_q(x::Q) = x
as_q(x::Expression) = Q(:AND, Any[x], false)
Base.:&(a::Conditional, b::Conditional) = Q(:AND, Any[as_q(a), as_q(b)], false)
Base.:|(a::Conditional, b::Conditional) = Q(:OR, Any[as_q(a), as_q(b)], false)
Base.:!(e::Union{LookupExpr,Condition}) = Q(:AND, Any[e], true)
Base.:~(e::Union{Exists,LookupExpr,Condition}) = !e
Base.xor(a::Conditional, b::Conditional, rest::Conditional...) =
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
function compile_order_item(c::SQLCompiler, o; by_alias::Bool = false)
    ob = o isa OrderBy ? o : OrderBy(F(lstrip(string(o), '-')), startswith(string(o), "-"), nothing)
    # by_alias (a query's ORDER BY): Asc(:n) for an annotation n is its alias, as order_by("n") (compiled again,
    # its joins and grouping would differ: #219)
    e = ob.expr
    sql, ps = by_alias && e isa F && !occursin("__", e.name) && haskey(c.annotations, Symbol(e.name)) &&
              !(Symbol(e.name) in c.alias_names) && !is_filtered_relation(c.annotations[Symbol(e.name)]) ? (qname(e.name), Any[]) : compile_expr(c, e)
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

"Whether an expression reads a column of the row (an `F`, a condition): such a value can update a row, not insert one (#214)."
refs_columns(@nospecialize(e)) = false
refs_columns(::F) = true
refs_columns(::Condition) = true
refs_columns(e::CombinedExpression) = refs_columns(e.lhs) || refs_columns(e.rhs)
refs_columns(e::Func) = any(refs_columns, e.args)
refs_columns(::Case) = true

"""
The fields an expression reads outside its aggregates (`F(:age)` in `Sum(:age) + F(:age)`): a
grouped values() query groups by them too, as Django does (PostgreSQL requires it).
"""
bare_refs(@nospecialize(e)) = String[]
bare_refs(e::F) = [e.name]
bare_refs(e::CombinedExpression) = vcat(bare_refs(e.lhs), bare_refs(e.rhs))
bare_refs(e::Func) = reduce(vcat, (bare_refs(a) for a in e.args); init = String[])
bare_refs(e::Case) = vcat(reduce(vcat, (bare_refs(w.then) for w in e.whens); init = String[]), bare_refs(e.default))

contains_aggregate(::Any) = false
contains_aggregate(::Aggregate) = true
contains_aggregate(e::CombinedExpression) = contains_aggregate(e.lhs) || contains_aggregate(e.rhs)
contains_aggregate(e::Func) = any(contains_aggregate, e.args)
contains_aggregate(e::Case) = any(w -> contains_aggregate(w.then), e.whens) || contains_aggregate(e.default)
contains_aggregate(::Window) = false

# --- compilation ----------------------------------------------------------------------------

"An expression with its field references taken through `prefix` (`Lower(:name)` → `Lower(:parent__name)`), or nothing if it can't be."
prefix_refs(e::F, prefix) = F(prefix * "__" * e.name)
prefix_refs(e::Value, prefix) = e
prefix_refs(e::Func, prefix) = (a = [x isa Expression ? prefix_refs(x, prefix) : x for x in e.args]; any(isnothing, a) ? nothing : Func(e.name, a))
prefix_refs(e::CombinedExpression, prefix) = (l = prefix_refs(e.lhs, prefix); r = prefix_refs(e.rhs, prefix); l === nothing || r === nothing ? nothing : CombinedExpression(e.op, l, r))
prefix_refs(@nospecialize(e), prefix) = nothing

"""
An annotation (or alias) with transforms applied to its value: `values(qs, :published__year)` for
`annotate(qs; published = TruncMonth(:pubdate))`, `order_by(qs, "-pubdate_alias__year")`, as Django.
"""
struct AnnotationTransform <: Expression
    name::Symbol            # the annotation
    transforms::Vector{String}
end
"The field kind an expression gives, as far as transforms need it (:date, :datetime, :char, ...), or nothing."
function expr_kind(c, @nospecialize(e))
    e isa ExpressionWrapper && return e.output isa Symbol ? e.output : (e.output isa Field ? e.output.kind : nothing)
    if e isa F
        a = get(c.annotations, Symbol(e.name), nothing)
        a === nothing || return expr_kind(c, a)
        f = output_field(c.T, e)
        return f === nothing ? nothing : f.kind
    end
    if e isa Func && e.name === :trunc
        ink = expr_kind(c, e.args[1])
        return trunc_output(e.args[2], something(ink, :datetime))
    end
    e isa Value && e.value isa Date && return :date
    e isa Value && e.value isa DateTime && return :datetime
    e isa Value && e.value isa AbstractString && return :char
    f = output_field(c.T, e)
    f === nothing ? nothing : f.kind
end
function compile_expr(c::SQLCompiler, e::AnnotationTransform)
    a = c.annotations[e.name]
    sql, ps = compile_expr(c, a)
    kind = something(expr_kind(c, a), haskey(DATE_TRANSFORMS, e.transforms[1]) ? :datetime : :char)
    tr = apply_transforms("($sql)", kind, e.transforms)
    tr === nothing && throw(LookupError("Unsupported lookup '$(join(e.transforms, "__"))' for $kind or join on the field not permitted."))
    tr[1], ps
end
"`name__year` as an annotation and transforms of it, when `name` is one of `anns` (longest name first); else nothing."
function annotation_transform(anns, path::AbstractString)
    occursin("__", path) || return nothing
    names = sort!([string(p.first) for p in anns if !is_filtered_relation(p.second)]; by = length, rev = true)
    for n in names
        startswith(path, n * "__") || continue
        return AnnotationTransform(Symbol(n), String.(split(path[length(n)+3:end], "__")))
    end
    nothing
end

"Resolve a field path for expressions: returns (SQL column, Field or nothing)."
Base.@nospecializeinfer function resolve_path(c::SQLCompiler, alias, @nospecialize(T::Type), path::AbstractString)
    segs = String.(split(path, "__"))
    for (i, s) in enumerate(segs)
        last_ = i == length(segs)
        s == "pk" && (s = "id")
        if s == "id"
            last_ || throw(LookupError("'id' is not a relation in '$path'"))
            natural_pk(T) && return qcol(alias, column(pk_fields(T)[1])), pk_fields(T)[1]     # (#221)
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
                last_ && return qcol(alias, column(f)), f
                # opened__month, finish__date__month: transforms of the field, wherever an F() goes (#205)
                tr = apply_transforms(qcol(alias, column(f)), f.kind, segs[i+1:end])
                tr === nothing && throw(LookupError("'$s' is not a relation in '$path', and '$(join(segs[i+1:end], "__"))' isn't a transform of it"))
                return tr[1], nothing
            end
            # author__id (or the to_field's name): the key column itself, no join (as Django)
            if i == length(segs) - 1 && (segs[end] == string(target_name(f)) || (fk_to_field(f) === nothing && segs[end] == "pk"))
                return qcol(alias, column(f)), f
            end
            alias = join!(c, alias, (alias, f.name), modelmeta(related_model(f)).table, target_column(f), column(f); left = f.null)
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
            ctcol, ctid = column(getfield_meta(M, ctf)), generic_ct(T, g).id::Integer
            alias = join!(c, alias, expr_key(c, alias, g.name), modelmeta(M).table, column(getfield_meta(M, fkf)), "id";
                          left = true, extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            T = M
            last_ && return qcol(alias, "id"), nothing
            continue
        end
        rg = find_reverse_generic(T, s)
        if rg !== nothing                      # tag.animal (a GenericRelation's related_query_name): LEFT JOIN the owner
            O, g = rg
            ctf, fkf = g.through
            ctcol, ctid = column(getfield_meta(T, ctf)), generic_ct(O, g).id::Integer
            prev = alias
            alias = join!(c, alias, expr_key(c, alias, Symbol(s)), modelmeta(O).table,
                          natural_pk(O) ? column(pk_fields(O)[1]) : "id", column(getfield_meta(T, fkf));
                          left = true, extra_on = a -> "$(qcol(prev, ctcol)) = $ctid")
            T = O
            last_ && return resolve_path(c, alias, T, "id")
            continue
        end
        rel = find_reverse(T, s)
        rel === nothing && throw(lookup_error(T, s))
        rn, M, rf = rel
        alias = join!(c, alias, expr_key(c, alias, rn), modelmeta(M).table, column(rf), target_column(rf); left = true)
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
    # F(:published__year): a transform of an annotation
    if occursin("__", e.name) && !haskey(c.annotations, Symbol(e.name)) && (at = annotation_transform(c.annotations, e.name)) !== nothing
        sql, ps = compile_expr(c, at)
        return "($sql)", ps
    end
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
    sql, ps = e.nested === nothing ? compile_expr(c.outer, F(e.name)) : compile_expr(c.outer, e.nested)
    c.outer.outer_refs === nothing || push!(c.outer.outer_refs, sql)
    sql, ps
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
    e.op in ("&", "|", "#", "<<", ">>") && return bitwise_sql(backend(), e.op, a, b), vcat(pa, pb)
    # integers divide as on PostgreSQL and SQLite (37, not MySQL's 37.4444), as Django has them
    e.op == "/" && integer_expr(c, e.lhs) && integer_expr(c, e.rhs) && return int_div_sql(backend(), a, b), vcat(pa, pb)
    "($a $(e.op) $b)", vcat(pa, pb)
end

"Bitwise operators (#217): `#` is XOR (PostgreSQL's spelling); MySQL's results are unsigned, so made signed, as Django does."
bitwise_sql(::DatabaseBackend, op, a, b) = op == "#" ? "(($a | $b) - ($a & $b))" : "($a $op $b)"

"Whether an expression's values are integers: an integer field or literal, a count, a sum/min/max of integers, +, -, * and / of integers."
integer_expr(c::SQLCompiler, @nospecialize(e)) = false
integer_expr(c::SQLCompiler, e::Value) = e.value isa Integer && !(e.value isa Bool)
function integer_expr(c::SQLCompiler, e::F)
    if !occursin("__", e.name) && haskey(c.annotations, Symbol(e.name))
        a = c.annotations[Symbol(e.name)]
        return !is_filtered_relation(a) && integer_expr(c, a)
    end
    e.name in ("id", "pk") && return true
    f = try last(resolve_path(c, c.base, c.T, e.name)) catch; nothing end
    f isa Field && (f.kind in INT_KINDS || f.kind === :fk)
end
integer_expr(c::SQLCompiler, e::Aggregate) = e.func == "COUNT" || (e.func in ("SUM", "MIN", "MAX") && e.arg !== nothing && integer_expr(c, e.arg))
integer_expr(c::SQLCompiler, e::CombinedExpression) = e.op in ("+", "-", "*", "/") && integer_expr(c, e.lhs) && integer_expr(c, e.rhs)
"Integer division, truncating (MySQL's `/` gives a decimal: it has `DIV`)."
int_div_sql(::DatabaseBackend, a, b) = "($a / $b)"

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
    # PostgreSQL has MOD only for integers and numeric: other operands go through numeric, as Django casts them
    n === :mod && b isa PostgresBackend && !all(a -> integer_expr(c, a), e.args) &&
        return "MOD(CAST($(sqls[1]) AS NUMERIC), CAST($(sqls[2]) AS NUMERIC))", ps
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
    if n === :extract
        tk = temporal_kind(c, e.args[1])
        tk === :duration && e.args[2] in (:year, :iso_year, :month, :week, :week_day, :iso_week_day, :quarter) &&
            throw(ArgumentError("Cannot extract component '$(e.args[2])' from DurationField '$(e.args[1] isa F ? e.args[1].name : "")'."))
        return date_part_expr(b, e.args[2], sqls[1], something(tk, :datetime)), ps
    end
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
    isempty(e.whens) && return compile_expr(c, e.default)              # (no WHEN: the default, as Django)
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

"""
A queryset as a subquery (`__in`, `Subquery`, `Exists`). As Django, its ordering is dropped
unless it's sliced (then the order decides which rows are in it) or uses DISTINCT ON: the
model's Meta.ordering would otherwise add columns under DISTINCT (#186). A `values`/`values_list`
query selects only its named columns, even when it has other annotations (they still filter).
"""
function subquery_sql(c::SQLCompiler, qs::QuerySet; columns = nothing, idonly = false)
    unsliced = qs.limit === nothing && qs.offset == 0
    keep_order = !unsliced || (qs.distinct_fields !== nothing && !isempty(qs.distinct_fields))
    keep_order || (qs = chain(qs; order = Any[NO_ORDER]))
    # distinct, ordered and sliced: the ordering's columns are selected too (DISTINCT needs them), so the
    # subquery is wrapped to select only its one column
    wrap_distinct = !unsliced && qs.distinct_fields !== nothing && columns === nothing && !is_composite(model_of(qs))
    if idonly && wrap_distinct && qs.values_fields === nothing
        sql, ps, _, _ = build_select(qs; outer = c)
        return "SELECT $(qname("id")) FROM ($sql) AS juango_sub", ps
    end
    sql, ps, _, _ = build_select(qs; columns = columns, outer = c, idonly = idonly)
    if columns === nothing && !idonly && qs.values_fields !== nothing &&
       (wrap_distinct || any(p -> !is_filtered_relation(p.second) && !(string(p.first) in qs.values_fields), qs.annotations))
        sql = "SELECT " * join([qname(f) for f in qs.values_fields], ", ") * " FROM ($sql) AS juango_sub"
    end
    sql, ps
end

function compile_expr(c::SQLCompiler, e::Subquery)
    sql, ps = subquery_sql(c, e.qs)
    "($sql)", ps
end

function compile_expr(c::SQLCompiler, e::Condition)
    sql, ps = expr_condition(c, e.q)
    "($sql)", ps
end

function compile_expr(c::SQLCompiler, e::LookupExpr)
    lsql, lps = compile_expr(c, e.lhs)
    if !isempty(lps)              # a value on the left: a literal number inline, so the left side can repeat (x != y OR x IS NULL)
        e.lhs isa Value && e.lhs.value isa Real && !(e.lhs.value isa Bool) || throw(ArgumentError(
            "$(e.lookup) lookup: the left side must be a field, an expression or a number"))
        lsql, lps = string(e.lhs.value), Any[]
    end
    e.lookup == "isnull" && !(e.rhs isa Bool) && throw(ArgumentError("IsNull takes true or false, not $(repr(e.rhs))"))
    lookup, rhs = e.rhs isa AbstractFloat && integer_expr(c, e.lhs) ? int_float_bound(e.lookup, e.rhs) : (e.lookup, e.rhs)
    sql, ps = lookup_condition(c, "($lsql)", lookup, rhs, identity)
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
        check_alias_name(k)
        # an annotation or alias of that name is replaced; F(k) in the new one means the old one (as Django)
        i = findlast(p -> p.first === k, anns)
        e = ref(v)
        i === nothing || (e = subst_ref(e, string(k), anns[i].second))
        filter!(p -> p.first !== k, anns)
        push!(anns, k => e)
    end
    after = copy(qs.annotated_after)
    for (k, _) in kw
        after[k] = length(qs.where)
    end
    als = setdiff(qs.aliases, collect(keys(kw)))      # annotate(alias(qs; x = ...); x = F(:x)): selected now
    qs.values_fields === nothing && return chain(qs; annotations = anns, annotated_after = after, aliases = als)
    # on a values() query: the new annotations are columns of its rows (values_list's tuples too), and
    # the first aggregate fixes the GROUP BY to the fields values() named (#201)
    vf = qs.values_fields
    qs.values_mode === :flat || (vf = vcat(vf, [string(k) for (k, _) in kw if !(string(k) in vf)]))
    gf = qs.group_fields
    if gf === nothing && !qs.group_by_object && any(p -> contains_aggregate(ref(p.second)), kw)
        gf = [f for f in qs.values_fields if !any(p -> string(p.first) == f && contains_aggregate(p.second), qs.annotations)]
    end
    chain(qs; annotations = anns, annotated_after = after, values_fields = vf, group_fields = gf, aliases = als)
end
Base.@nospecializeinfer annotate(@nospecialize(T::Type{<:Model}); kw...) = annotate(objects(T); kw...)

"`e` with references to `name` replaced by `old` (an annotation redefined in terms of its previous self)."
subst_ref(e::F, name, old) = e.name == name ? old : e
subst_ref(e::Func, name, old) = Func(e.name, Any[x isa Expression ? subst_ref(x, name, old) : x for x in e.args])
subst_ref(e::CombinedExpression, name, old) = CombinedExpression(e.op, subst_ref(e.lhs, name, old), subst_ref(e.rhs, name, old))
subst_ref(e::ExpressionWrapper, name, old) = ExpressionWrapper(subst_ref(e.expr, name, old), e.output)
subst_ref(@nospecialize(e), name, old) = e

"Refuse an annotation or alias name that could break out of its quoting (as Django)."
function check_alias_name(k)
    s = string(k)
    (any(ch -> isspace(ch) || iscntrl(ch) || ch in ('"', '\'', '`', ';', '#'), s) || occursin("--", s) || occursin("/*", s)) &&
        throw(ArgumentError("Column aliases cannot contain whitespace characters, hashes, control characters, quotation marks, semicolons, or SQL comments."))
end

"""
    alias(qs; name = expression, ...)

Like `annotate`, a name for an expression that `filter`, `exclude`, `order_by`, `annotate` and
`update!` can use, but not selected: the rows don't have it (Django's `QuerySet.alias`).
`filter(alias(objects(Book); n = Count(:authors)); n__gt = 1)`.
"""
Base.@nospecializeinfer function alias(@nospecialize(qs::QuerySet); kw...)
    T = model_of(qs)
    anns = copy(qs.annotations)
    after = copy(qs.annotated_after)
    for (k, v) in kw
        (findfield(modelmeta(T), k) !== nothing || k in (:id, :pk)) &&
            throw(ArgumentError("alias '$k' conflicts with a field of $T"))
        check_alias_name(k)
        i = findlast(p -> p.first === k, anns)
        e = ref(v)
        i === nothing || (e = subst_ref(e, string(k), anns[i].second))
        filter!(p -> p.first !== k, anns)
        push!(anns, k => e); after[k] = length(qs.where)
    end
    chain(qs; annotations = anns, annotated_after = after, aliases = unique!(vcat(qs.aliases, collect(keys(kw)))))
end
Base.@nospecializeinfer alias(@nospecialize(T::Type{<:Model}); kw...) = alias(objects(T); kw...)
annotate(; kw...) = qs -> annotate(qs; kw...)

"""
    values(qs, fields...) -> QuerySet

The results as `Dict{Symbol,Any}` rows instead of objects. Fields may follow relations
(`:author__name`). With aggregate annotations the rows are grouped by these fields:
`values(objects(Post), :status) |> annotate(n = Count(:id))`.
"""
function Base.values(@nospecialize(qs::QuerySet), fields::Union{Symbol,AbstractString}...)
    T = model_of(qs)
    if qs.combinator !== nothing && !isempty(fields)       # values_list(union(a, b), :x): each part's values, as Django
        op, parts, keep_all = qs.combinator
        return chain(qs; combinator = (op, Any[values(p, fields...) for p in parts], keep_all),
                     values_fields = String[string(f) for f in fields], values_mode = :dict)
    end
    fs = isempty(fields) ? vcat(["id"], [string(attname(f)) for f in all_fields(T)],                  # values(): the annotations too
                                [string(p.first) for p in qs.annotations if !is_filtered_relation(p.second) && !(p.first in qs.aliases)]) :
         String[string(f) for f in fields]
    # an alias can't be selected: annotate() promotes it (as Django); an annotation's transform is one of its own
    extra = Pair{Symbol,Any}[]
    for f in fs
        any(p -> string(p.first) == f, qs.annotations) && (Symbol(f) in qs.aliases) &&
            throw(LookupError("Cannot select the '$f' alias. Use annotate() to promote it."))
        any(p -> string(p.first) == f, qs.annotations) && continue
        at = annotation_transform(qs.annotations, f)
        at === nothing && continue
        (at.name in qs.aliases || (qs.values_fields !== nothing && !(string(at.name) in qs.values_fields))) &&
            throw(LookupError("Cannot select the '$(at.name)' alias. " * (at.name in qs.aliases ? "Use annotate() to promote it." :
                  "It was excluded by a previous values() or values_list() call. Include '$(at.name)' in that call to select it.")))
        push!(extra, Symbol(f) => at)
    end
    isempty(extra) || (qs = chain(qs; annotations = vcat(qs.annotations, extra)))
    # an annotation an earlier values() left out can't come back (as Django)
    if qs.values_fields !== nothing
        for f in fs
            Symbol(f) in map(first, qs.annotations) && !(f in qs.values_fields) &&
                throw(LookupError("Cannot select the '$f' alias. It was excluded by a previous values() or values_list() call. " *
                                  "Include '$f' in that call to select it."))
        end
    end
    chain(qs; values_fields = fs, values_mode = :dict,
          group_by_object = qs.group_fields === nothing && any(p -> contains_aggregate(p.second), qs.annotations))
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
    flat && length(fields) > 1 && throw(ArgumentError("values_list: flat=true takes one field"))
    T = model_of(qs)
    flat && isempty(fields) && (fields = Any[:id])      # as Django: the first field, the primary key (#213)
    fs = isempty(fields) ? Any[:id; [attname(f) for f in all_fields(T)];          # the annotations too, as Django
                               [p.first for p in qs.annotations if !is_filtered_relation(p.second) && !(p.first in qs.aliases)]] : fields
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
Base.@nospecializeinfer function output_field(@nospecialize(T), e::Case)
    e.output isa Field && return e.output
    for x in vcat(Any[w.then for w in e.whens], Any[e.default])
        f = x isa Value ? literal_field(x.value) : output_field(T, x)
        f === nothing || return f
    end
    nothing
end
"The field a literal value has the type of (a Case's `then`): booleans, dates, times, UUIDs, durations."
literal_field(v::Bool) = BooleanField()
literal_field(v::Date) = DateField()
literal_field(v::DateTime) = DateTimeField()
literal_field(v::Time) = TimeField()
literal_field(v::UUID) = UUIDField()
literal_field(v::Dates.Period) = DurationField()
literal_field(v) = nothing
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
    e isa Union{RawSQL,ExpressionWrapper} && return e.output isa Field ? e.output : nothing
    e isa Union{F,Aggregate,Func,Subquery,Window,WindowFunc,Case} || return nothing
    of = output_field(T, e)
    of !== nothing && of.kind in TYPED_OUTPUT_KINDS ? of : nothing
end
Base.@nospecializeinfer function expr_value(@nospecialize(T), e, v, of::Union{Nothing,Field})
    v === nothing && return nothing
    e isa Union{RawSQL,ExpressionWrapper} && e.output isa Field && e.output.kind === :bool && return v isa Bool ? v : v != 0
    e isa ExpressionWrapper && e.output === nothing && return expr_value(T, e.expr, v, typed_output(T, e.expr))
    e isa Union{Exists,Condition,LookupExpr,NegatedExpr} && return v isa Bool ? v : v != 0          # SQLite and MySQL give 0/1
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
    isempty(kw) && return Dict{Symbol,Any}()
    for (k, v) in kw                                     # Django: "fail is not an aggregate expression" (#203)
        v isa Expression || throw(ArgumentError("aggregate received a non-expression: $k = $(repr(v))"))
        contains_aggregate(v) || throw(ArgumentError("aggregate: $k is not an aggregate expression ($(repr(v)))"))
    end
    if qs.isnone                                         # none(): what the aggregates give over no rows, without a query
        vals = Dict{Symbol,Any}(k => empty_aggregate(v) for (k, v) in kw)
        any(v -> v === NOTFOUND, values(vals)) || return vals
    end
    # over an annotation (Avg(:num_authors) after annotate(num_authors = Count(...))): over the annotated query,
    # as a subquery, as Django (#204); over another aggregate of the same call: an error, as Django
    anames = Set(string(p.first) for p in qs.annotations if !is_filtered_relation(p.second))
    for (k, v) in kw, r in all_refs(v)
        (r in anames || findfield(modelmeta(T), Symbol(r)) !== nothing) && continue
        r in (string(k2) for (k2, _) in kw) &&
            throw(ArgumentError("aggregate: cannot compute $k over '$r': '$r' is an aggregate of the same call"))
    end
    any(p -> any(in(anames), all_refs(p.second)), kw) && return aggregate_over(qs, anames; kw...)
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
    # a sliced queryset keeps its order, which decides which rows are in the slice (#200)
    sub, sps = select_sql(qs; columns = pk_select(c.table, T), ordered = !(qs.limit === nothing && qs.offset == 0))
    row = execute("SELECT $(join(sel, ", ")) FROM $(qname(c.table))$(join(c.joins)) WHERE $(pk_ref(c.base, T)) IN ($(in_subquery(backend(), sub)))",
                  vcat(ps, c.join_params, sps))[1]
    Dict{Symbol,Any}(k => expr_value(T, ref(v), row[k]) for (k, v) in kw)
end
"Aggregates over a queryset's annotations: `SELECT agg FROM (the query) AS table`, the annotations its columns (#204)."
Base.@nospecializeinfer function aggregate_over(@nospecialize(qs::QuerySet), anames; kw...)
    T = model_of(qs)
    inner, ips = select_sql(qs; ordered = !(qs.limit === nothing && qs.offset == 0))
    c = SQLCompiler(T)                     # the subquery is named like the table, so the model's columns resolve too
    for n in anames
        c.annotations[Symbol(n)] = ColRef(qcol(c.base, n))
    end
    sel, ps = String[], Any[]
    for (k, v) in kw
        sql, p = compile_expr(c, ref(v))
        push!(sel, "$sql AS $(qname(string(k)))")
        append!(ps, p)
    end
    row = execute("SELECT $(join(sel, ", ")) FROM ($inner) AS $(qname(c.base))$(join(c.joins))", vcat(ps, ips, c.join_params))[1]
    Dict{Symbol,Any}(k => expr_value(T, ref(v), row[k], nothing) for (k, v) in kw)
end
"A column of an enclosing query's FROM, as an expression (aggregate_over)."
struct ColRef <: Expression
    sql::String
end
compile_expr(c::SQLCompiler, e::ColRef) = (e.sql, Any[])
"Every field name an expression reads, inside aggregates too."
all_refs(@nospecialize(e)) = (out = String[]; walk_refs!(out, e); out)
walk_refs!(out, e::F) = push!(out, e.name)
walk_refs!(out, e::Union{Expression,When,OrderBy}) = (for f in fieldnames(typeof(e)); walk_refs!(out, getfield(e, f)); end)
walk_refs!(out, v::AbstractVector) = foreach(x -> walk_refs!(out, x), v)
walk_refs!(out, @nospecialize(x)) = nothing

"An aggregate's value over no rows (a count's 0, a default, Coalesce of those), or NOTFOUND when it needs the database."
empty_aggregate(@nospecialize(e)) = NOTFOUND
empty_aggregate(e::Value) = e.value
empty_aggregate(e::Aggregate) = e.func == "COUNT" ? 0 : e.default === nothing ? nothing : empty_aggregate(lit_expr(e.default))
function empty_aggregate(e::Func)
    e.name === :coalesce || return NOTFOUND
    for a in e.args
        v = empty_aggregate(a)
        v === NOTFOUND && return NOTFOUND
        v === nothing || return v
    end
    nothing
end

"""
The name Django gives an aggregate passed without one: `Avg(:age)` is `:age__avg`,
`Count(:authors)` is `:authors__count` (`aggregate(qs, Avg(:age))`, `annotate(qs, Count(:authors))`).
"""
function default_alias(e::Aggregate)
    e.arg isa F || throw(ArgumentError("Complex aggregates require an alias: give $(repr(e)) a name (name = ...)"))
    f = Dict("STDDEV_POP" => "stddev", "STDDEV_SAMP" => "stddev", "VAR_POP" => "variance", "VAR_SAMP" => "variance",
             "GROUP_CONCAT" => "stringagg", "STRING_AGG" => "stringagg", "ARRAY_AGG" => "arrayagg")
    Symbol(replace(e.arg.name, "." => "__"), "__", get(f, e.func, lowercase(e.func)))
end
default_alias(e) = throw(ArgumentError("Complex aggregates require an alias: give $(repr(e)) a name (name = ...)"))
aggregate(qs::QuerySet, a::Expression, more::Expression...; kw...) =
    aggregate(qs; (default_alias(x) => x for x in (a, more...))..., kw...)
annotate(qs::QuerySet, a::Expression, more::Expression...; kw...) =
    annotate(qs; (default_alias(x) => x for x in (a, more...))..., kw...)

function aggregate(qs::QuerySet, func::Symbol, field::Symbol)
    func in (:count, :sum, :avg, :min, :max) || throw(ArgumentError("unknown aggregate $func"))
    agg = Dict(:count => Count, :sum => Sum, :avg => Avg, :min => Min, :max => Max)[func]
    aggregate(qs; r = agg(field == :pk ? :id : field))[:r]
end
