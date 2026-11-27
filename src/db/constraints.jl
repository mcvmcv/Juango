# Model constraints ----------------------------------------------------------------------------------
#
#     @model struct Booking
#         room = ForeignKey(Room, on_delete = :CASCADE)
#         start = DateField()
#         stop = DateField()
#         cancelled = BooleanField(default = false)
#         Meta(constraints = [
#             CheckConstraint(condition = Q(stop__gte = F(:start)), name = "stop_after_start"),
#             UniqueConstraint(fields = [:room, :start], condition = Q(cancelled = false), name = "one_booking_per_day"),
#             UniqueConstraint(Lower(:code), name = "code_ci_unique"),
#         ])
#     end
#
# The database enforces them (CHECK constraints, unique indexes), migrations add and remove
# them, and `full_clean` and model forms report a violation before saving.

abstract type Constraint end

"When a deferrable constraint is checked: `Deferrable.DEFERRED` (at commit) or `Deferrable.IMMEDIATE` (Django's `Deferrable`)."
struct DeferrableMode
    name::Symbol
end
Base.show(io::IO, d::DeferrableMode) = print(io, "Deferrable.", uppercase(string(d.name)))
"`Deferrable.DEFERRED`, `Deferrable.IMMEDIATE`: for `UniqueConstraint` and `ExclusionConstraint` (PostgreSQL)."
module Deferrable
import ..DeferrableMode
const DEFERRED = DeferrableMode(:deferred)
const IMMEDIATE = DeferrableMode(:immediate)
end
"PostgreSQL's range operators, for `ExclusionConstraint` expressions (Django's `RangeOperators`)."
module RangeOperators
const EQUAL = "="
const NOT_EQUAL = "<>"
const CONTAINS = "@>"
const CONTAINED_BY = "<@"
const OVERLAPS = "&&"
const FULLY_LT = "<<"
const FULLY_GT = ">>"
const NOT_LT = "&>"
const NOT_GT = "&<"
const ADJACENT_TO = "-|-"
end
"""
    OpClass(expr, name)

An expression with a PostgreSQL operator class, in a `UniqueConstraint`, an `ExclusionConstraint` or an index:
`OpClass(Lower(:scene), "text_pattern_ops")`, `OpClass(:during, name = "range_ops")`.
"""
struct OpClass <: Expression
    expr::Any
    name::String
    OpClass(expr, name::AbstractString) = new(expr isa OrderBy ? expr : ref(expr), String(name))   # (Desc(...) too, in an index)
end
OpClass(expr; name) = OpClass(expr, name)
Base.:(==)(a::OpClass, b::OpClass) = a.name == b.name && expr_code(a.expr) == expr_code(b.expr)
Base.hash(o::OpClass, h::UInt) = hash(o.name, hash(expr_code(o.expr), h))
compile_expr(c::SQLCompiler, e::OpClass) = compile_expr(c, e.expr isa OrderBy ? e.expr.expr : e.expr)        # (the operator class is DDL only)
expr_code(e::OpClass) = "OpClass($(e.expr isa OrderBy ? index_item_code(e.expr) : expr_code(e.expr)), $(repr(e.name)))"

"""
    CheckConstraint(; condition::Q, name, violation_error_message = nothing, violation_error_code = nothing)

A `CHECK` constraint: every row must satisfy `condition`, written with the usual lookups
(`exact`, `iexact`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `isnull`, `range`, `contains`,
`startswith`, `endswith` and their `i` forms) on the model's own fields; compare fields with
`F(:other)`. As in SQL, a condition that is unknown because of a NULL passes.

The name may hold `%(app_label)s` and `%(class)s` (for an abstract model's constraints), and
`violation_error_code` is the `ValidationError`'s code when it's violated (`Juango.validate`).
"""
struct CheckConstraint <: Constraint
    condition::Q
    name::String
    violation_error_message::Union{Nothing,String}
    violation_error_code::Union{Nothing,String}
end
function CheckConstraint(; condition, name, violation_error_message = nothing, violation_error_code = nothing)
    condition isa Q || throw(ArgumentError("CheckConstraint.condition must be a Q instance or boolean expression."))
    CheckConstraint(condition, string(name), optstring(violation_error_message), optstring(violation_error_code))
end
optstring(x) = x === nothing ? nothing : string(x)

"""
    UniqueConstraint(; fields, name, condition = nothing, violation_error_message = nothing, violation_error_code = nothing)
    UniqueConstraint(Lower(:email), ...; name)

No two rows may have the same values in `fields`. With `condition`, only rows that satisfy
it count (a partial unique index; not on MySQL/MariaDB, where the database can't enforce it
but validation still does). Expressions `Lower(:f)`, `Upper(:f)` and `F(:f)` make a
functional unique index (not on MySQL/MariaDB), each one also in `OpClass(expr, "text_pattern_ops")`. Rows with a
NULL in the fields never clash.

PostgreSQL only: `opclasses = [...]` gives each field an operator class; `include = [...]` adds non-key columns
(a covering index); `deferrable = Deferrable.DEFERRED` (or `IMMEDIATE`) makes it a real `UNIQUE` constraint that
can be checked at commit (not with a condition, include, opclasses or expressions).
"""
struct UniqueConstraint <: Constraint
    fields::Vector{Symbol}
    expressions::Vector{Any}
    name::String
    condition::Union{Nothing,Q}
    violation_error_message::Union{Nothing,String}
    violation_error_code::Union{Nothing,String}
    opclasses::Vector{String}
    include::Vector{String}
    deferrable::Union{Nothing,DeferrableMode}
end
UniqueConstraint(fields, expressions, name, condition, msg, code) =
    UniqueConstraint(fields, expressions, name, condition, msg, code, String[], String[], nothing)
function UniqueConstraint(expressions...; fields = Symbol[], name, condition = nothing, violation_error_message = nothing,
                          violation_error_code = nothing, opclasses = String[], include = nothing, deferrable = nothing)
    islist(x) = x isa AbstractVector || x isa Tuple
    isempty(fields) && isempty(expressions) &&
        throw(ArgumentError("At least one field or expression is required to define a unique constraint."))
    isempty(fields) || isempty(expressions) ||
        throw(ArgumentError("UniqueConstraint.fields and expressions are mutually exclusive."))
    condition === nothing || condition isa Q || throw(ArgumentError("UniqueConstraint.condition must be a Q instance."))
    # Django's checks, in its order and words
    condition !== nothing && deferrable !== nothing && throw(ArgumentError("UniqueConstraint with conditions cannot be deferred."))
    include !== nothing && !isempty(include) && deferrable !== nothing &&
        throw(ArgumentError("UniqueConstraint with include fields cannot be deferred."))
    !isempty(opclasses) && deferrable !== nothing && throw(ArgumentError("UniqueConstraint with opclasses cannot be deferred."))
    !isempty(expressions) && deferrable !== nothing && throw(ArgumentError("UniqueConstraint with expressions cannot be deferred."))
    !isempty(expressions) && !isempty(opclasses) &&
        throw(ArgumentError("UniqueConstraint.opclasses cannot be used with expressions. Use django.contrib.postgres.indexes.OpClass() instead."))
    deferrable === nothing || deferrable isa DeferrableMode ||
        throw(ArgumentError("UniqueConstraint.deferrable must be a Deferrable instance."))
    include === nothing || islist(include) || throw(ArgumentError("UniqueConstraint.include must be a list or tuple."))
    islist(opclasses) || throw(ArgumentError("UniqueConstraint.opclasses must be a list or tuple."))
    isempty(opclasses) || length(opclasses) == length(fields) ||
        throw(ArgumentError("UniqueConstraint.fields and UniqueConstraint.opclasses must have the same number of elements."))
    for e in expressions
        x = e isa OpClass ? e.expr : e
        (x isa Union{F,Symbol,AbstractString} || x isa Func && x.name in (:lower, :upper) && length(x.args) == 1 && x.args[1] isa F) ||
            throw(ArgumentError("UniqueConstraint '$name': expressions can be F(:field), Lower(:field) or Upper(:field)"))
    end
    UniqueConstraint(Symbol[Symbol(f) for f in fields], collect(Any, expressions), string(name), condition,
                     optstring(violation_error_message), optstring(violation_error_code), String[string(o) for o in opclasses],
                     String[string(x) for x in something(include, String[])], deferrable)
end
"A unique constraint's expression without its operator class."
unique_expr(e) = e isa OpClass ? e.expr : e

"""
    ExclusionConstraint(; name, expressions, index_type = "GIST", condition = nothing, deferrable = nothing,
                        include = [], violation_error_message = nothing, violation_error_code = nothing)

PostgreSQL's `EXCLUDE` constraint: no two rows may match each other on all the `(expression, operator)`
pairs, e.g. no overlapping bookings of one room:

    ExclusionConstraint(name = "no_double_booking",
                        expressions = [(:room, RangeOperators.EQUAL), (:during, RangeOperators.OVERLAPS)],
                        condition = Q(cancelled = false))

An expression is a field name, `F(...)` (transforms too: `"field__0"`, `"published__year"`, a JSON key), any
expression over the model's own fields (`Lower(:name)`, `Cast(:number, :int)`, `SQLFunction("TSTZRANGE", :start,
:stop, RangeBoundary())`), or one of those in `OpClass(expr, "range_ops")`. `index_type` is `"gist"`, `"spgist"`
or `"hash"` (one expression, `=` only); `deferrable = Deferrable.DEFERRED` checks it at commit; `include` adds
non-key columns to its index. (`=` on a non-range column inside a GiST index needs `BtreeGistExtension()`.) Other
databases skip it; `full_clean` checks it on PostgreSQL with a query.
"""
struct ExclusionConstraint <: Constraint
    name::String
    expressions::Vector{Tuple{Any,String}}   # (F, expression or OpClass; operator)
    index_type::String                       # as given ("GIST" by default); compared without case
    condition::Union{Nothing,Q}
    deferrable::Union{Nothing,DeferrableMode}
    include::Vector{String}
    violation_error_message::Union{Nothing,String}
    violation_error_code::Union{Nothing,String}
end
function ExclusionConstraint(; name, expressions = nothing, index_type = nothing, condition = nothing, deferrable = nothing,
                             include = nothing, violation_error_message = nothing, violation_error_code = nothing)
    it = index_type === nothing ? "GIST" : string(index_type)
    lowercase(it) in ("gist", "spgist", "hash") ||
        throw(ArgumentError("Exclusion constraints only support GiST, Hash, or SP-GiST indexes."))
    (expressions === nothing || isempty(expressions)) &&
        throw(ArgumentError("At least one expression is required to define an exclusion constraint."))
    all(e -> e isa Tuple && length(e) == 2, expressions) || throw(ArgumentError("The expressions must be a list of 2-tuples."))
    condition === nothing || condition isa Q || throw(ArgumentError("ExclusionConstraint.condition must be a Q instance."))
    deferrable === nothing || deferrable isa DeferrableMode ||
        throw(ArgumentError("ExclusionConstraint.deferrable must be a Deferrable instance."))
    include === nothing || include isa Union{AbstractVector,Tuple} || throw(ArgumentError("ExclusionConstraint.include must be a list or tuple."))
    incl = include === nothing ? String[] : String[string(x) for x in include]
    if lowercase(it) == "hash"
        isempty(incl) || throw(ArgumentError("Covering exclusion constraints using Hash indexes are not supported."))
        length(expressions) == 1 || throw(ArgumentError("Composite exclusion constraints using Hash indexes are not supported."))
        string(expressions[1][2]) == "=" || throw(ArgumentError("Exclusion constraints using Hash indexes only support the EQUAL operator."))
    end
    exprs = Tuple{Any,String}[(e isa Union{Symbol,AbstractString} ? F(string(e)) : e isa OpClass || e isa Expression ? e :
                               throw(ArgumentError("ExclusionConstraint '$name': $(repr(e)) is not an expression")), string(op))
                              for (e, op) in expressions]
    ExclusionConstraint(string(name), exprs, it, condition, deferrable, incl, optstring(violation_error_message),
                        optstring(violation_error_code))
end
"An expression as Django's repr writes it (`F(room)`, `OpClass(F(span), name=range_ops)`)."
django_expr_repr(e::F) = "F($(e.name))"
django_expr_repr(e::OpClass) = "OpClass($(django_expr_repr(e.expr)), name=$(e.name))"
django_expr_repr(e) = repr(e)
function Base.show(io::IO, c::ExclusionConstraint)
    print(io, "<ExclusionConstraint: index_type='", c.index_type, "' expressions=[",
          join(("($(django_expr_repr(e)), '$op')" for (e, op) in c.expressions), ", "), "] name='", c.name, "'")
    c.condition === nothing || print(io, " condition=", c.condition)
    c.deferrable === nothing || print(io, " deferrable=", c.deferrable)
    isempty(c.include) || print(io, " include=(", join(("'$x'" for x in c.include), ", "), length(c.include) == 1 ? ",)" : ")")
    c.violation_error_message === nothing || print(io, " violation_error_message='", c.violation_error_message, "'")
    c.violation_error_code === nothing || print(io, " violation_error_code='", c.violation_error_code, "'")
    print(io, ">")
end
exclusion_key(c::ExclusionConstraint) = (c.name, [(expr_code(e), op) for (e, op) in c.expressions], lowercase(c.index_type),
                                         c.condition === nothing ? nothing : q_code(c.condition), c.deferrable, c.include,
                                         c.violation_error_message, c.violation_error_code)
Base.:(==)(a::ExclusionConstraint, b::ExclusionConstraint) = exclusion_key(a) == exclusion_key(b)
Base.hash(c::ExclusionConstraint, h::UInt) = hash(exclusion_key(c), h)

model_constraints(T) = collect(Constraint, get(modelmeta(T).extra, :constraints, Constraint[]))

# Constraints are equal when all their parts are (as Django's __eq__)
Base.:(==)(a::C, b::C) where {C<:Constraint} = all(n -> getfield(a, n) == getfield(b, n), fieldnames(C))
Base.hash(c::Constraint, h::UInt) = foldl((h, n) -> hash(getfield(c, n), h), fieldnames(typeof(c)); init = hash(typeof(c), h))

"A constraint with `%(app_label)s` and `%(class)s` in its name filled in for model `T` (at registration)."
function constraint_for_model(c::Constraint, app, cls)
    occursin("%(", c.name) || return c
    name = replace(c.name, "%(app_label)s" => lowercase(string(app)), "%(class)s" => lowercase(string(cls)))
    typeof(c)((n === :name ? name : getfield(c, n) for n in fieldnames(typeof(c)))...)
end

"""
    Juango.validate(constraint, Model, obj; exclude = Symbol[])

Check one constraint for an object's values, as Django's `constraint.validate(model, instance)`:
throws `ValidationError` with the constraint's message and `violation_error_code` (or Django's
`unique` code for a unique constraint over fields) when they violate it. Skipped when it uses an
excluded field.
"""
Base.@nospecializeinfer function validate(c::Constraint, @nospecialize(T::Type{<:Model}), @nospecialize(obj::Model); exclude = Symbol[])
    values = Dict{Symbol,Any}(f.name => field_data(obj, attname(f)) for f in all_fields(T) if !(f.name in exclude))
    r = constraint_error(T, c, values, obj.id)
    r === nothing && return nothing
    msg, code = r
    throw(ValidationError(msg; code = code))
end

# --- the schema snapshot -------------------------------------------------------------------------

"""
A constraint in a table snapshot (and in migration files): field names already turned into
column names, so it no longer depends on the model code.
"""
struct ConstraintSpec
    kind::Symbol                              # :check, :unique or :exclusion
    name::String
    columns::Vector{String}                   # unique: the columns
    expressions::Vector{Tuple{Any,String}}    # unique: (function, column), function "" = the column; exclusion: (column, or an
                                              # expression over field names; operator)
    condition::Union{Nothing,Q}               # over column names
    index_type::String                        # exclusion: "gist", "spgist" or "hash"
    opclasses::Vector{String}                 # unique: one per column or expression; exclusion: one per expression ("" = none)
    include::Vector{String}                   # columns of a covering index (INCLUDE)
    deferrable::String                        # "", "deferred" or "immediate"
end
ConstraintSpec(kind, name, columns, expressions, condition, index_type) =
    ConstraintSpec(kind, name, columns, expressions, condition, index_type, String[], String[], "")
ConstraintSpec(kind, name; columns = String[], expressions = Tuple{String,String}[], condition = nothing, index_type = "",
               opclasses = String[], include = String[], deferrable = "") =
    ConstraintSpec(Symbol(kind), string(name), collect(String, columns),
                   Tuple{Any,String}[(a isa Expression ? a : string(a), string(b)) for (a, b) in expressions], condition,
                   string(index_type), collect(String, opclasses), collect(String, include), string(deferrable))
Base.:(==)(a::ConstraintSpec, b::ConstraintSpec) = constraint_code(a) == constraint_code(b)
Base.hash(c::ConstraintSpec, h::UInt) = hash(constraint_code(c), h)

"The column a field name stands for in a constraint (own fields only, FKs by their id column)."
function constraint_column(T, name)
    s = string(name)
    s in ("id", "pk") && return "id"
    f = findfield(modelmeta(T), Symbol(s))
    (f === nothing || f.kind in (:m2m, :gfk, :grel)) &&
        throw(ArgumentError("$(modelmeta(T).name): constraint names unknown field '$s' (constraints can use the model's own fields)"))
    column(f)
end

const CONSTRAINT_LOOKUPS = ("exact", "iexact", "ne", "gt", "gte", "lt", "lte", "in", "isnull", "range",
                            "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith")

"`field__transform__lookup` with the field's column for its name; following a relation is refused."
function column_path(T, path::AbstractString)
    parts = split(path, "__")
    length(parts) == 1 && return constraint_column(T, path)
    f = findfield(modelmeta(T), Symbol(parts[1]))
    f !== nothing && f.kind in (:fk, :o2o) &&
        throw(ArgumentError("$(modelmeta(T).name): constraints can't follow relations ('$path')"))
    join([constraint_column(T, parts[1]); parts[2:end]], "__")
end

"Split `field__lookup` into the field name and the lookup (default `exact`)."
function split_lookup(key)
    parts = split(string(key), "__")
    length(parts) > 1 && parts[end] in CONSTRAINT_LOOKUPS ? (join(parts[1:end-1], "__"), String(parts[end])) : (string(key), "exact")
end

"A condition over field names rewritten over column names."
function condition_to_columns(T, q::Q)
    kids = Any[]
    for c in q.children
        if c isa Q
            push!(kids, condition_to_columns(T, c))
        elseif c isa Pair
            name, lookup = split_lookup(c.first)
            v = c.second
            v isa Model && (v = v.id)
            v isa F && (v = F(column_path(T, v.name)))
            if occursin("__", name)               # a transform or a lookup of the field's own (ints__contained_by, field__len__gt)
                push!(kids, Symbol(column_path(T, string(c.first))) => v)
            else
                push!(kids, Symbol(constraint_column(T, name), lookup == "exact" ? "" : "__" * lookup) => v)
            end
        else
            throw(ArgumentError("$(modelmeta(T).name): constraint conditions take Q(...) lookups, not $(typeof(c))"))
        end
    end
    Q(q.connector, kids, q.negated)
end

function constraint_spec(T, c::CheckConstraint)
    ConstraintSpec(:check, c.name; condition = condition_to_columns(T, c.condition))
end
function constraint_spec(T, c::UniqueConstraint)
    exprs = Tuple{String,String}[]
    for e0 in c.expressions
        e = unique_expr(e0)
        e isa Func ? push!(exprs, (uppercase(string(e.name)), constraint_column(T, e.args[1].name))) :
                     push!(exprs, ("", constraint_column(T, e isa F ? e.name : e)))
    end
    opcs = !isempty(c.opclasses) ? c.opclasses :
           any(e -> e isa OpClass, c.expressions) ? [e isa OpClass ? e.name : "" for e in c.expressions] : String[]
    ConstraintSpec(:unique, c.name; columns = [constraint_column(T, f) for f in c.fields], expressions = exprs,
                   condition = c.condition === nothing ? nothing : condition_to_columns(T, c.condition),
                   opclasses = opcs, include = [constraint_column(T, f) for f in c.include],
                   deferrable = c.deferrable === nothing ? "" : string(c.deferrable.name))
end

"An exclusion expression in a table snapshot: a plain field is its column; anything else stays an expression over field names."
function exclusion_spec_expr(T, e)
    e isa OpClass && (e = e.expr)
    e isa F && !occursin("__", e.name) && return constraint_column(T, e.name)
    e
end
function constraint_spec(T, c::ExclusionConstraint)
    ConstraintSpec(:exclusion, c.name; expressions = [(exclusion_spec_expr(T, e), op) for (e, op) in c.expressions],
                   condition = c.condition === nothing ? nothing : condition_to_columns(T, c.condition),
                   index_type = lowercase(c.index_type),
                   opclasses = any(x -> x[1] isa OpClass, c.expressions) ? [e isa OpClass ? e.name : "" for (e, _) in c.expressions] : String[],
                   include = [constraint_column(T, f) for f in c.include],
                   deferrable = c.deferrable === nothing ? "" : string(c.deferrable.name))
end

# --- code for migration files ----------------------------------------------------------------------

value_code(v::Union{Integer,AbstractFloat,Bool,AbstractString,Nothing,Symbol}) = repr(v)
value_code(v::F) = "F($(repr(v.name)))"
value_code(v::Date) = "Juango.Dates.Date($(Dates.year(v)), $(Dates.month(v)), $(Dates.day(v)))"
value_code(v::DateTime) = "Juango.Dates.DateTime($(repr(Dates.format(v, "yyyy-mm-ddTHH:MM:SS.sss"))))"
value_code(v::Union{AbstractVector,Tuple}) = "Any[" * join(value_code.(v), ", ") * "]"
value_code(v::ValueRange) = isempty(v) ? "Juango.ValueRange(nothing, nothing; bounds = \"empty\")" :
                            "Juango.ValueRange($(value_code(v.lower)), $(value_code(v.upper)); bounds = $(repr(v.bounds)))"
value_code(v) = throw(ArgumentError("constraint values must be numbers, strings, booleans, dates, F(...) or lists of them, not $(typeof(v))"))

q_code(q::Q) = "Q($(repr(q.connector)), Any[" *
               join([c isa Q ? q_code(c) : "$(repr(c.first)) => $(value_code(c.second))" for c in q.children], ", ") *
               "], $(q.negated))"

function constraint_code(c::ConstraintSpec)
    s = "ConstraintSpec($(repr(c.kind)), $(repr(c.name))"
    isempty(c.columns) || (s *= "; columns = $(repr(c.columns))")
    isempty(c.expressions) || (s *= (occursin(";", s) ? ", " : "; ") * "expressions = [" *
                                     join(["($(a isa Expression ? expr_code(a) : repr(a)), $(repr(b)))" for (a, b) in c.expressions], ", ") * "]")
    c.condition === nothing || (s *= (occursin(";", s) ? ", " : "; ") * "condition = " * q_code(c.condition))
    isempty(c.index_type) || (s *= (occursin(";", s) ? ", " : "; ") * "index_type = " * repr(c.index_type))
    isempty(c.opclasses) || (s *= (occursin(";", s) ? ", " : "; ") * "opclasses = " * repr(c.opclasses))
    isempty(c.include) || (s *= (occursin(";", s) ? ", " : "; ") * "include = " * repr(c.include))
    isempty(c.deferrable) || (s *= (occursin(";", s) ? ", " : "; ") * "deferrable = " * repr(c.deferrable))
    s * ")"
end

# --- SQL ----------------------------------------------------------------------------------------

function like_literal(b, v, pre, post)
    s = replace(string(v), "\\" => "\\\\", "%" => "\\%", "_" => "\\_")
    lit(b, pre * s * post) * " ESCAPE " * backslash_literal(b)
end

"A condition (over column names) as SQL with the values written in as literals."
function condition_sql(b::DatabaseBackend, q::Q)
    parts = String[]
    for c in q.children
        if c isa Q
            push!(parts, "(" * condition_sql(b, c) * ")")
            continue
        end
        col, lookup = split_lookup(c.first)
        v = c.second
        qc = quote_name(b, col)
        rhs(x) = x isa F ? quote_name(b, x.name) : lit(b, x)
        sql = if lookup == "exact"
            v === nothing ? "$qc IS NULL" : "$qc = $(rhs(v))"
        elseif lookup == "iexact"
            "LOWER($qc) = LOWER($(rhs(v)))"
        elseif lookup == "ne"
            "$qc <> $(rhs(v))"
        elseif lookup in ("gt", "gte", "lt", "lte")
            "$qc $(Dict("gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")[lookup]) $(rhs(v))"
        elseif lookup == "in"
            isempty(v) ? sql_false(b) : "$qc IN (" * join(rhs.(v), ", ") * ")"
        elseif lookup == "isnull"
            v ? "$qc IS NULL" : "$qc IS NOT NULL"
        elseif lookup == "range"
            "$qc BETWEEN $(rhs(v[1])) AND $(rhs(v[2]))"
        else
            ci = startswith(lookup, "i")
            base = ci ? lookup[2:end] : lookup
            pre, post = base == "contains" ? ("%", "%") : base == "startswith" ? ("", "%") : ("%", "")
            (ci ? "LOWER($qc) LIKE LOWER(" * like_literal(b, v, pre, post) * ")" : "$qc LIKE " * like_literal(b, v, pre, post))
        end
        push!(parts, sql)
    end
    isempty(parts) && push!(parts, b isa SQLiteBackend ? "1" : "TRUE")
    s = q.connector === :XOR ? xor_sql(b, parts) : join(parts, q.connector === :OR ? " OR " : " AND ")
    q.negated ? "NOT (" * s * ")" : s
end

supports_partial_indexes(b::DatabaseBackend) = !(b isa MySQLBackend)
supports_expression_indexes(b::DatabaseBackend) = !(b isa MySQLBackend)

"`CONSTRAINT name CHECK (...)` for CREATE TABLE."
check_clause(b::DatabaseBackend, c::ConstraintSpec, table = nothing) =
    "CONSTRAINT $(quote_name(b, c.name)) CHECK (" * (table === nothing ? condition_sql(b, c.condition) : ddl_condition_sql(b, table, c.condition)) * ")"

"Whether a unique constraint is a real `UNIQUE ... DEFERRABLE` constraint here (PostgreSQL), not a unique index."
deferrable_unique(b::DatabaseBackend, c::ConstraintSpec) = b isa PostgresBackend && !isempty(c.deferrable)

"The unique index of a UniqueConstraint (nothing where the database can't build it)."
function unique_constraint_sql(b::DatabaseBackend, table, c::ConstraintSpec; if_not_exists = false)
    c.condition === nothing || supports_partial_indexes(b) || return String[]
    isempty(c.expressions) || supports_expression_indexes(b) || return String[]
    if deferrable_unique(b, c)
        sql = "ALTER TABLE $(quote_name(b, table)) ADD CONSTRAINT $(quote_name(b, c.name)) UNIQUE (" *
              join([quote_name(b, x) for x in c.columns], ", ") * ")" * deferrable_sql(c)
        if_not_exists || return [sql]
        return ["DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = " * lit(b, c.name) *
                ") THEN " * sql * "; END IF; END \$\$"]
    end
    keys_ = isempty(c.expressions) ? [quote_name(b, x) for x in c.columns] :
            [f == "" ? quote_name(b, x) : "($f($(quote_name(b, x))))" for (f, x) in c.expressions]
    pg = b isa PostgresBackend
    pg && !isempty(c.opclasses) && (keys_ = [isempty(o) ? k : k * " " * o for (k, o) in zip(keys_, c.opclasses)])
    ["CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(quote_name(b, c.name)) ON $(quote_name(b, table)) (" *
     join(keys_, ", ") * ")" * (pg && !isempty(c.include) ? " INCLUDE (" * join([quote_name(b, x) for x in c.include], ", ") * ")" : "") *
     (c.condition === nothing ? "" : " WHERE " * ddl_condition_sql(b, table, c.condition))]
end

"The registered model on `table` (for compiling the expressions of its constraints), or `nothing`."
model_for_table(table) = (i = findlast(T -> !modelmeta(T).proxy && modelmeta(T).table == table, MODEL_LIST); i === nothing ? nothing : MODEL_LIST[i])

"`?` placeholders in `sql` replaced by `params` as SQL literals (DDL takes no parameters)."
function inline_params(b::DatabaseBackend, sql::AbstractString, params)
    isempty(params) && return String(sql)
    i = Ref(0)
    replace_placeholders(() -> lit(b, params[i[] += 1]), sql)
end

"""
An expression over the fields of the model on `table` as SQL for DDL: unqualified columns, values written in.
A column name stays a quoted column.
"""
function ddl_expr_sql(b::DatabaseBackend, table, e)
    e isa AbstractString && return quote_name(b, e)
    T = model_for_table(table)
    T === nothing && return gen_sql(b, e)
    c = SQLCompiler(T)
    sql, ps = compile_expr(c, e)
    isempty(c.joins) || throw(ArgumentError("$(modelmeta(T).name): a constraint can't use a joined field ($(expr_code(e)))"))
    sql = replace(sql, quote_name(b, table) * "." => "")
    inline_params(b, sql, ps)
end

"""
A constraint's condition (over column names) as SQL for DDL: compiled as a filter on the model on `table`, so any lookup
and transform it has works (`ints__contained_by`, `dates__contains = F(:inner)`, `field__len`); without a registered
model, the plain lookups only.
"""
function ddl_condition_sql(b::DatabaseBackend, table, q::Q)
    T = model_for_table(table)
    (T === nothing || plain_condition(q, T)) && return condition_sql(b, q)
    c = SQLCompiler(T)
    sql, ps = compile_q(c, c.base, T, q, false)
    isempty(c.joins) || throw(ArgumentError("$(modelmeta(T).name): a constraint's condition can't use a joined field ($q)"))
    inline_params(b, replace(sql, quote_name(b, table) * "." => ""), ps)
end

"""
Whether `condition_sql` writes a condition (over the columns of model `T`): plain lookups on columns of plain kinds
(not arrays, ranges, JSON: their `contains` isn't text's), with plain values.
"""
function plain_condition(q::Q, T)
    plainv(v) = v === nothing || v isa Union{Number,AbstractString,Bool,Date,DateTime,Symbol} || v isa F && !occursin("__", v.name)
    function plaincol(name)
        i = findfirst(f -> column(f) == name, modelmeta(T).fields)
        i === nothing || !(modelmeta(T).fields[i].kind in (:array, :json, :hstore, RANGE_KINDS...))
    end
    all(q.children) do c
        c isa Q && return plain_condition(c, T)
        c isa Pair || return false
        name, lookup = split_lookup(c.first)
        !occursin("__", name) && plaincol(name) &&
            (lookup in ("in", "range") ? c.second isa Union{AbstractVector,Tuple} && all(plainv, c.second) : plainv(c.second))
    end
end

deferrable_sql(c::ConstraintSpec) = c.deferrable == "deferred" ? " DEFERRABLE INITIALLY DEFERRED" :
                                    c.deferrable == "immediate" ? " DEFERRABLE INITIALLY IMMEDIATE" : ""

"The `ALTER TABLE ... ADD CONSTRAINT ... EXCLUDE` of an ExclusionConstraint (PostgreSQL only)."
function exclusion_sql(b::DatabaseBackend, table, c::ConstraintSpec; if_not_exists = false)
    b isa PostgresBackend || return String[]
    items = String[]
    for (i, (e, op)) in enumerate(c.expressions)
        sql = ddl_expr_sql(b, table, e)
        e isa AbstractString || (sql = "(" * sql * ")")
        opc = isempty(c.opclasses) ? "" : c.opclasses[i]
        push!(items, sql * (isempty(opc) ? "" : " " * opc) * " WITH " * op)
    end
    sql = "ALTER TABLE $(quote_name(b, table)) ADD CONSTRAINT $(quote_name(b, c.name)) EXCLUDE USING $(c.index_type) (" *
          join(items, ", ") * ")" *
          (isempty(c.include) ? "" : " INCLUDE (" * join([quote_name(b, x) for x in c.include], ", ") * ")") *
          (c.condition === nothing ? "" : " WHERE (" * ddl_condition_sql(b, table, c.condition) * ")") * deferrable_sql(c)
    if_not_exists || return [sql]
    ["DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = " * lit(b, c.name) *
     ") THEN " * sql * "; END IF; END \$\$"]
end

"Statements that add a constraint to an existing table (`to` is the table with it)."
function add_constraint_sql(b::DatabaseBackend, from::Table, to::Table, c::ConstraintSpec)
    c.kind === :unique && return unique_constraint_sql(b, to.name, c)
    c.kind === :exclusion && return exclusion_sql(b, to.name, c)
    can_alter_table(b) || return remake_table_sql(b, from, to)
    ["ALTER TABLE $(quote_name(b, to.name)) ADD " * check_clause(b, c, to.name)]
end

"Statements that drop a constraint (`to` is the table without it)."
function remove_constraint_sql(b::DatabaseBackend, from::Table, to::Table, c::ConstraintSpec)
    c.kind === :exclusion && return b isa PostgresBackend ?
        ["ALTER TABLE $(quote_name(b, from.name)) DROP CONSTRAINT $(quote_name(b, c.name))"] : String[]
    if c.kind === :unique
        isempty(unique_constraint_sql(b, from.name, c)) && return String[]
        deferrable_unique(b, c) && return ["ALTER TABLE $(quote_name(b, from.name)) DROP CONSTRAINT $(quote_name(b, c.name))"]
        return [drop_index_stmt(b, from.name, c.name)]
    end
    can_alter_table(b) || return remake_table_sql(b, from, to)
    ["ALTER TABLE $(quote_name(b, from.name)) DROP CONSTRAINT $(quote_name(b, c.name))"]
end

# --- validation ----------------------------------------------------------------------------------

"Three-valued (`missing` = unknown) value of a condition over field names, for `values`."
function condition_value(T, q::Q, value)
    acc = q.connector === :AND
    for c in q.children
        r = if c isa Q
            condition_value(T, c, value)
        else
            name, transforms, lookup = condition_parts(c.first)
            x = transformed_value(value(name), transforms)
            v = c.second
            v isa Model && (v = v.id)
            if v isa F
                vn, vt, _ = condition_parts(v.name; lookups = false)
                v = transformed_value(value(vn), vt)
            end
            # a range's startswith/endswith are its bounds (Django's RangeStartsWith/RangeEndsWith transforms)
            x isa ValueRange && lookup in ("startswith", "endswith") && ((x, lookup) = (transformed_value(x, [lookup]), "exact"))
            check_lookup_value(x, lookup, v)
        end
        acc = q.connector === :OR ? (acc | r) : q.connector === :XOR ? xor(acc, r) : (acc & r)
    end
    q.negated ? !acc : acc
end

"Lookups a constraint's condition can end with (besides the plain ones): arrays', ranges', JSON's."
const CONDITION_LOOKUPS = (CONSTRAINT_LOOKUPS..., "contained_by", "overlap", "isempty", "lower_inc", "lower_inf", "upper_inc",
                           "upper_inf", "fully_lt", "fully_gt", "not_lt", "not_gt", "adjacent_to", "has_key", "has_keys", "has_any_keys")
"`field__transform...__lookup` as (field, transforms, lookup); the lookup is `exact` when the last part isn't one."
function condition_parts(key; lookups = true)
    parts = String.(split(string(key), "__"))
    lookup = lookups && length(parts) > 1 && parts[end] in CONDITION_LOOKUPS ? pop!(parts) : "exact"
    (parts[1], parts[2:end], lookup)
end
"A field's value through transforms, as the database computes them (`len`, `lower`, a range's `startswith`, `year`, an index)."
function transformed_value(x, transforms)
    for t in transforms
        x === nothing && return nothing
        x = if t == "len"
            length(x)
        elseif t in ("startswith", "lower") && x isa ValueRange
            isempty(x) ? nothing : x.lower
        elseif t in ("endswith", "upper") && x isa ValueRange
            isempty(x) ? nothing : x.upper
        elseif t == "lower" && x isa AbstractString
            lowercase(x)
        elseif t == "upper" && x isa AbstractString
            uppercase(x)
        elseif t in ("year", "month", "day", "hour", "minute", "second") && x isa Union{Date,DateTime}
            getfield(Dates, Symbol(t))(x)
        elseif x isa AbstractVector && all(isdigit, t)
            i = parse(Int, t) + 1
            i <= length(x) ? x[i] : nothing
        elseif x isa AbstractDict
            get(x, t, nothing)
        else
            throw(ArgumentError("constraint conditions can't apply '$t' to a $(typeof(x))"))
        end
    end
    x
end
"Whether range `a` contains all of range `b`."
function range_contains(a::ValueRange, b::ValueRange)
    isempty(b) && return true
    isempty(a) && return false
    lo = a.lower === nothing || b.lower !== nothing && (b.lower > a.lower || b.lower == a.lower && (a.bounds[1] == '[' || b.bounds[1] == '('))
    hi = a.upper === nothing || b.upper !== nothing && (b.upper < a.upper || b.upper == a.upper && (a.bounds[2] == ']' || b.bounds[2] == ')'))
    lo && hi
end
function ranges_overlap(a::ValueRange, b::ValueRange)
    (isempty(a) || isempty(b)) && return false
    before(x, y) = x.upper !== nothing && y.lower !== nothing && (x.upper < y.lower || x.upper == y.lower && !(x.bounds[2] == ']' && y.bounds[1] == '['))
    !before(a, b) && !before(b, a)
end
"A range's sort key, as PostgreSQL orders ranges: by lower bound, then upper (an unbounded side first / last)."
range_sort_key(r::ValueRange) = isempty(r) ? (0, nothing, 0, nothing) :
    (r.lower === nothing ? 0 : 1, r.lower, r.upper === nothing ? 1 : 0, r.upper)
function range_less(a::ValueRange, b::ValueRange)
    ka, kb = range_sort_key(a), range_sort_key(b)
    isempty(a) && return !isempty(b)
    isempty(b) && return false
    ka[1] != kb[1] && return ka[1] < kb[1]
    ka[1] == 1 && a.lower != b.lower && return a.lower < b.lower
    ka[3] != kb[3] && return ka[3] < kb[3]
    ka[3] == 0 && a.upper != b.upper && return a.upper < b.upper
    false
end
as_range(x, like::ValueRange) = x isa ValueRange ? x : x isa Tuple && length(x) == 2 ? ValueRange(x[1], x[2]) : x

function check_lookup_value(x, lookup, v)
    lookup == "isnull" && return (x === nothing) == v
    lookup == "exact" && v === nothing && return x === nothing
    (x === nothing || v === nothing) && return missing
    if x isa ValueRange
        v = as_range(v, x)
        lookup == "contains" && return v isa ValueRange ? range_contains(x, v) : v in x
        lookup == "contained_by" && return range_contains(v, x)
        lookup == "overlap" && return ranges_overlap(x, v)
        lookup == "isempty" && return isempty(x) == v
        lookup == "lower_inf" && return (!isempty(x) && x.lower === nothing) == v
        lookup == "upper_inf" && return (!isempty(x) && x.upper === nothing) == v
        lookup == "lower_inc" && return (!isempty(x) && x.lower !== nothing && x.bounds[1] == '[') == v
        lookup == "upper_inc" && return (!isempty(x) && x.upper !== nothing && x.bounds[2] == ']') == v
        lookup == "lt" && return range_less(x, v)
        lookup == "gt" && return range_less(v, x)
        lookup == "lte" && return !range_less(v, x)
        lookup == "gte" && return !range_less(x, v)
    elseif x isa AbstractVector
        lookup == "contains" && return all(in(x), v)
        lookup == "contained_by" && return all(in(v), x)
        lookup == "overlap" && return any(in(x), v)
    elseif x isa AbstractDict
        lookup == "contains" && return all(k -> haskey(x, k) && x[k] == v[k], keys(v))
        lookup == "contained_by" && return all(k -> haskey(v, k) && v[k] == x[k], keys(x))
        lookup == "has_key" && return haskey(x, v)
        lookup == "has_keys" && return all(k -> haskey(x, k), v)
        lookup == "has_any_keys" && return any(k -> haskey(x, k), v)
    end
    lookup in ("contained_by", "overlap", "isempty", "lower_inc", "lower_inf", "upper_inc", "upper_inf", "fully_lt", "fully_gt",
               "not_lt", "not_gt", "adjacent_to", "has_key", "has_keys", "has_any_keys") && return missing   # (unknown here: passes)
    lookup == "exact" && return x == v
    lookup == "iexact" && return lowercase(string(x)) == lowercase(string(v))
    lookup == "ne" && return x != v
    lookup == "gt" && return x > v
    lookup == "gte" && return x >= v
    lookup == "lt" && return x < v
    lookup == "lte" && return x <= v
    lookup == "in" && return x in v
    lookup == "range" && return v[1] <= x <= v[2]
    ci = startswith(lookup, "i")
    s, t = ci ? (lowercase(string(x)), lowercase(string(v))) : (string(x), string(v))
    base = ci ? lookup[2:end] : lookup
    base == "contains" ? occursin(t, s) : base == "startswith" ? startswith(s, t) : endswith(s, t)
end

"Field names a condition uses (for skipping constraints whose fields aren't all known)."
function condition_fields(q::Q, out = Set{String}())
    for c in q.children
        if c isa Q
            condition_fields(c, out)
        else
            push!(out, condition_parts(c.first)[1])
            c.second isa F && push!(out, condition_parts(c.second.name; lookups = false)[1])
        end
    end
    out
end

constraint_fields(c::CheckConstraint) = condition_fields(c.condition)
"The fields an expression reads (the first part of each `F`'s name)."
expr_fields(e::F, out) = push!(out, String(first(split(e.name, "__"))))
expr_fields(e::OpClass, out) = expr_fields(e.expr, out)
expr_fields(e::Func, out) = (foreach(a -> expr_fields(a, out), e.args); out)
expr_fields(e::CombinedExpression, out) = (expr_fields(e.lhs, out); expr_fields(e.rhs, out))
expr_fields(e::ExpressionWrapper, out) = expr_fields(e.expr, out)
expr_fields(e, out) = out
"The field paths (`F` names) an expression reads."
expr_paths(e::F, out) = push!(out, e.name)
expr_paths(e::OpClass, out) = expr_paths(e.expr, out)
expr_paths(e::Func, out) = (foreach(a -> expr_paths(a, out), e.args); out)
expr_paths(e::CombinedExpression, out) = (expr_paths(e.lhs, out); expr_paths(e.rhs, out))
expr_paths(e::ExpressionWrapper, out) = expr_paths(e.expr, out)
expr_paths(e, out) = out
function constraint_fields(c::ExclusionConstraint)
    s = Set{String}()
    foreach(x -> expr_fields(x[1], s), c.expressions)
    c.condition === nothing || condition_fields(c.condition, s)
    s
end
function constraint_fields(c::UniqueConstraint)
    s = Set{String}(string.(c.fields))
    for e0 in c.expressions
        e = unique_expr(e0)
        push!(s, e isa Func ? e.args[1].name : e isa F ? e.name : string(e))
    end
    c.condition === nothing || condition_fields(c.condition, s)
    s
end

"An expression over `T`'s fields with each field replaced by the object's value (a database default by its expression)."
function with_values(T, e::F, get_)
    parts = split(e.name, "__")
    v = get_(parts[1])
    if v isa DatabaseDefault
        f = findfield(modelmeta(T), Symbol(parts[1]))
        dv = f === nothing ? nothing : f.db_default
        length(parts) == 1 && dv isa Expression && return dv
        v = dv isa Expression ? nothing : dv
    end
    f = findfield(modelmeta(T), Symbol(parts[1]))
    f !== nothing && f.kind in RANGE_KINDS && v isa Tuple && (v = range_value(f, v))
    v = transformed_value(v, parts[2:end])
    Value(v isa ValueRange ? encode_range(backend(), v) : v)       # (a range as its text: PostgreSQL types it from the operator)
end
with_values(T, e::Func, get_) = Func(e.name, Any[a isa Expression ? with_values(T, a, get_) : a for a in e.args])
with_values(T, e::CombinedExpression, get_) = CombinedExpression(e.op, with_values(T, e.lhs, get_), with_values(T, e.rhs, get_))
with_values(T, e::ExpressionWrapper, get_) = ExpressionWrapper(with_values(T, e.expr, get_), e.output)
with_values(T, e, get_) = e

"""
    constraint_errors(Model, values, id) -> Vector{String}

Messages for the model's constraints that `values` (field name => value, a `Function` or a
`Dict`) would violate, for the object with `id` (`nothing` if unsaved). Constraints that use
a field missing from `values` are skipped. Unique constraints are checked with a query.
"""
Base.@nospecializeinfer constraint_errors(@nospecialize(T::Type{<:Model}), values, id) = String[v[1] for v in constraint_violations(T, values, id)]
"`(message, code, constraint)` of each constraint of `T` (and of its multi-table parents, as Django's) that `values` violate."
Base.@nospecializeinfer function constraint_violations(@nospecialize(T::Type{<:Model}), values, id)
    out = Tuple{String,Any,Constraint}[]
    M = T
    while M !== nothing
        for c in model_constraints(M)
            r = constraint_error(M, c, values, id)
            r === nothing || push!(out, (r[1], r[2], c))
        end
        M = table_parent(M)
    end
    out
end

"`(message, code)` when `values` violate constraint `c` of `T`, else `nothing`."
Base.@nospecializeinfer function constraint_error(@nospecialize(T::Type{<:Model}), c::Constraint, values, id)
    has(name) = values isa AbstractDict ? haskey(values, Symbol(name)) : true
    get_(name) = (v = values isa AbstractDict ? values[Symbol(name)] : values(name); v isa Model ? v.id : v)
    vname = uppercasefirst(string(modelmeta(T).verbose_name))
    violated() = something(c.violation_error_message, interpolate(gettext("Constraint “%(name)s” is violated."), Dict("name" => c.name)))
    code = hasfield(typeof(c), :violation_error_code) ? c.violation_error_code : nothing
    all(has, constraint_fields(c)) || return nothing
    if c isa CheckConstraint
        condition_value(T, c.condition, get_) === false || return nothing
        return (violated(), code)
    elseif c isa ExclusionConstraint
        # enforced by PostgreSQL only: a row the object's values would clash with, found with a query of the constraint's
        # operators between each expression and the same expression of the object's values (Django's validate)
        backend() isa PostgresBackend || return nothing
        c.condition === nothing || condition_value(T, c.condition, get_) === true || return nothing
        conds = Any[]
        for (e, op) in c.expressions
            x = unique_expr(e)
            push!(conds, CombinedExpression(op, x, with_values(T, x, get_)))
        end
        qs = filter(base_objects(T), Q(:AND, conds, false))
        c.condition === nothing || (qs = filter(qs, c.condition))
        id === nothing || (qs = filter(qs, !Q(id = id)))
        return exists(qs) ? (violated(), code) : nothing
    end
    c.condition === nothing || condition_value(T, c.condition, get_) === true || return nothing
    lookups = Pair{Symbol,Any}[]
    for f in c.fields
        v = get_(f); v === nothing && return nothing
        push!(lookups, f => v)
    end
    for e0 in c.expressions
        e = unique_expr(e0)
        name = e isa Func ? e.args[1].name : e isa F ? e.name : string(e)
        v = get_(name); v === nothing && return nothing
        push!(lookups, Symbol(name, e isa Func ? "__iexact" : "") => v)
    end
    qs = filter(base_objects(T), Q(:AND, Any[lookups...], false))
    c.condition === nothing || (qs = filter(qs, c.condition))
    id === nothing || (qs = filter(qs, !Q(id = id)))
    exists(qs) || return nothing
    # a constraint over fields without a condition reads as a unique field does (code "unique"), as Django
    if c.violation_error_message === nothing && !isempty(c.fields) && c.condition === nothing
        labels = [label(findfield(modelmeta(T), f)) for f in c.fields]
        return (interpolate(gettext("%(model)s with this %(fields)s already exists."), Dict("model" => vname, "fields" => join(labels, " and "))),
                something(code, "unique"))
    end
    (violated(), code)
end
