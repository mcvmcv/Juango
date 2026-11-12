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

"""
    CheckConstraint(; condition::Q, name, violation_error_message = nothing)

A `CHECK` constraint: every row must satisfy `condition`, written with the usual lookups
(`exact`, `iexact`, `ne`, `gt`, `gte`, `lt`, `lte`, `in`, `isnull`, `range`, `contains`,
`startswith`, `endswith` and their `i` forms) on the model's own fields; compare fields with
`F(:other)`. As in SQL, a condition that is unknown because of a NULL passes.
"""
struct CheckConstraint <: Constraint
    condition::Q
    name::String
    violation_error_message::Union{Nothing,String}
end
CheckConstraint(; condition, name, violation_error_message = nothing) =
    CheckConstraint(condition, string(name), violation_error_message === nothing ? nothing : string(violation_error_message))

"""
    UniqueConstraint(; fields, name, condition = nothing, violation_error_message = nothing)
    UniqueConstraint(Lower(:email), ...; name)

No two rows may have the same values in `fields`. With `condition`, only rows that satisfy
it count (a partial unique index; not on MySQL/MariaDB, where the database can't enforce it
but validation still does). Expressions `Lower(:f)`, `Upper(:f)` and `F(:f)` make a
functional unique index (not on MySQL/MariaDB). Rows with a NULL in the fields never clash.
"""
struct UniqueConstraint <: Constraint
    fields::Vector{Symbol}
    expressions::Vector{Any}
    name::String
    condition::Union{Nothing,Q}
    violation_error_message::Union{Nothing,String}
end
function UniqueConstraint(expressions...; fields = Symbol[], name, condition = nothing, violation_error_message = nothing)
    isempty(fields) == isempty(expressions) &&
        throw(ArgumentError("UniqueConstraint '$name' needs either fields or expressions (not both)"))
    for e in expressions
        (e isa Union{F,Symbol,AbstractString} || e isa Func && e.name in (:lower, :upper) && length(e.args) == 1 && e.args[1] isa F) ||
            throw(ArgumentError("UniqueConstraint '$name': expressions can be F(:field), Lower(:field) or Upper(:field)"))
    end
    UniqueConstraint(Symbol[Symbol(f) for f in fields], collect(Any, expressions), string(name), condition,
                     violation_error_message === nothing ? nothing : string(violation_error_message))
end

"""
    ExclusionConstraint(; name, expressions, index_type = :gist, condition = nothing, violation_error_message = nothing)

PostgreSQL's `EXCLUDE` constraint: no two rows may match each other on all the
`(field, operator)` pairs, e.g. no overlapping bookings of one room:

    ExclusionConstraint(name = "no_double_booking",
                        expressions = [(:room, "="), (:during, "&&")])

(`=` on a non-range column inside a GiST index needs `BtreeGistExtension()` in a migration.)
Other databases skip it. `full_clean` checks it on PostgreSQL when the operators are `=` and `&&`.
"""
struct ExclusionConstraint <: Constraint
    name::String
    expressions::Vector{Tuple{Symbol,String}}
    index_type::Symbol
    condition::Union{Nothing,Q}
    violation_error_message::Union{Nothing,String}
end
function ExclusionConstraint(; name, expressions, index_type = :gist, condition = nothing, violation_error_message = nothing)
    isempty(expressions) && throw(ArgumentError("ExclusionConstraint '$name' needs expressions"))
    Symbol(index_type) in (:gist, :spgist) || throw(ArgumentError("ExclusionConstraint index_type must be :gist or :spgist"))
    ExclusionConstraint(string(name), Tuple{Symbol,String}[(Symbol(f), string(op)) for (f, op) in expressions],
                        Symbol(index_type), condition, violation_error_message === nothing ? nothing : string(violation_error_message))
end

model_constraints(T) = collect(Constraint, get(modelmeta(T).extra, :constraints, Constraint[]))

# --- the schema snapshot -------------------------------------------------------------------------

"""
A constraint in a table snapshot (and in migration files): field names already turned into
column names, so it no longer depends on the model code.
"""
struct ConstraintSpec
    kind::Symbol                              # :check, :unique or :exclusion
    name::String
    columns::Vector{String}                   # unique: the columns
    expressions::Vector{Tuple{String,String}} # unique: (function, column), function "" = the column; exclusion: (column, operator)
    condition::Union{Nothing,Q}               # over column names
    index_type::String                        # exclusion: "gist" or "spgist"
end
ConstraintSpec(kind, name; columns = String[], expressions = Tuple{String,String}[], condition = nothing, index_type = "") =
    ConstraintSpec(Symbol(kind), string(name), collect(String, columns),
                   Tuple{String,String}[(string(a), string(b)) for (a, b) in expressions], condition, string(index_type))
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
            occursin("__", name) && throw(ArgumentError("$(modelmeta(T).name): constraints can't follow relations ('$(c.first)')"))
            v = c.second
            v isa Model && (v = v.id)
            v isa F && (v = F(constraint_column(T, v.name)))
            push!(kids, Symbol(constraint_column(T, name), lookup == "exact" ? "" : "__" * lookup) => v)
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
    for e in c.expressions
        e isa Func ? push!(exprs, (uppercase(string(e.name)), constraint_column(T, e.args[1].name))) :
                     push!(exprs, ("", constraint_column(T, e isa F ? e.name : e)))
    end
    ConstraintSpec(:unique, c.name; columns = [constraint_column(T, f) for f in c.fields], expressions = exprs,
                   condition = c.condition === nothing ? nothing : condition_to_columns(T, c.condition))
end

function constraint_spec(T, c::ExclusionConstraint)
    ConstraintSpec(:exclusion, c.name; expressions = [(constraint_column(T, f), op) for (f, op) in c.expressions],
                   condition = c.condition === nothing ? nothing : condition_to_columns(T, c.condition),
                   index_type = string(c.index_type))
end

# --- code for migration files ----------------------------------------------------------------------

value_code(v::Union{Integer,AbstractFloat,Bool,AbstractString,Nothing,Symbol}) = repr(v)
value_code(v::F) = "F($(repr(v.name)))"
value_code(v::Date) = "Juango.Dates.Date($(Dates.year(v)), $(Dates.month(v)), $(Dates.day(v)))"
value_code(v::DateTime) = "Juango.Dates.DateTime($(repr(Dates.format(v, "yyyy-mm-ddTHH:MM:SS.sss"))))"
value_code(v::Union{AbstractVector,Tuple}) = "Any[" * join(value_code.(v), ", ") * "]"
value_code(v) = throw(ArgumentError("constraint values must be numbers, strings, booleans, dates, F(...) or lists of them, not $(typeof(v))"))

q_code(q::Q) = "Q($(repr(q.connector)), Any[" *
               join([c isa Q ? q_code(c) : "$(repr(c.first)) => $(value_code(c.second))" for c in q.children], ", ") *
               "], $(q.negated))"

function constraint_code(c::ConstraintSpec)
    s = "ConstraintSpec($(repr(c.kind)), $(repr(c.name))"
    isempty(c.columns) || (s *= "; columns = $(repr(c.columns))")
    isempty(c.expressions) || (s *= (occursin(";", s) ? ", " : "; ") * "expressions = [" * join(["($(repr(a)), $(repr(b)))" for (a, b) in c.expressions], ", ") * "]")
    c.condition === nothing || (s *= (occursin(";", s) ? ", " : "; ") * "condition = " * q_code(c.condition))
    isempty(c.index_type) || (s *= (occursin(";", s) ? ", " : "; ") * "index_type = " * repr(c.index_type))
    s * ")"
end

# --- SQL ----------------------------------------------------------------------------------------

function like_literal(b, v, pre, post)
    s = replace(string(v), "\\" => "\\\\", "%" => "\\%", "_" => "\\_")
    lit(b, pre * s * post) * " ESCAPE '\\'"
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
    s = join(parts, q.connector === :OR ? " OR " : " AND ")
    q.negated ? "NOT (" * s * ")" : s
end

supports_partial_indexes(b::DatabaseBackend) = !(b isa MySQLBackend)
supports_expression_indexes(b::DatabaseBackend) = !(b isa MySQLBackend)

"`CONSTRAINT name CHECK (...)` for CREATE TABLE."
check_clause(b::DatabaseBackend, c::ConstraintSpec) = "CONSTRAINT $(quote_name(b, c.name)) CHECK (" * condition_sql(b, c.condition) * ")"

"The unique index of a UniqueConstraint (nothing where the database can't build it)."
function unique_constraint_sql(b::DatabaseBackend, table, c::ConstraintSpec; if_not_exists = false)
    c.condition === nothing || supports_partial_indexes(b) || return String[]
    isempty(c.expressions) || supports_expression_indexes(b) || return String[]
    keys_ = isempty(c.expressions) ? [quote_name(b, x) for x in c.columns] :
            [f == "" ? quote_name(b, x) : "($f($(quote_name(b, x))))" for (f, x) in c.expressions]
    ["CREATE UNIQUE INDEX $(if_not_exists ? "IF NOT EXISTS " : "")$(quote_name(b, c.name)) ON $(quote_name(b, table)) (" *
     join(keys_, ", ") * ")" * (c.condition === nothing ? "" : " WHERE " * condition_sql(b, c.condition))]
end

"The `ALTER TABLE ... ADD CONSTRAINT ... EXCLUDE` of an ExclusionConstraint (PostgreSQL only)."
function exclusion_sql(b::DatabaseBackend, table, c::ConstraintSpec; if_not_exists = false)
    b isa PostgresBackend || return String[]
    sql = "ALTER TABLE $(quote_name(b, table)) ADD CONSTRAINT $(quote_name(b, c.name)) EXCLUDE USING $(c.index_type) (" *
          join(["$(quote_name(b, col)) WITH $op" for (col, op) in c.expressions], ", ") * ")" *
          (c.condition === nothing ? "" : " WHERE (" * condition_sql(b, c.condition) * ")")
    if_not_exists || return [sql]
    ["DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = " * lit(b, c.name) *
     ") THEN " * sql * "; END IF; END \$\$"]
end

"Statements that add a constraint to an existing table (`to` is the table with it)."
function add_constraint_sql(b::DatabaseBackend, from::Table, to::Table, c::ConstraintSpec)
    c.kind === :unique && return unique_constraint_sql(b, to.name, c)
    c.kind === :exclusion && return exclusion_sql(b, to.name, c)
    can_alter_table(b) || return remake_table_sql(b, from, to)
    ["ALTER TABLE $(quote_name(b, to.name)) ADD " * check_clause(b, c)]
end

"Statements that drop a constraint (`to` is the table without it)."
function remove_constraint_sql(b::DatabaseBackend, from::Table, to::Table, c::ConstraintSpec)
    c.kind === :exclusion && return b isa PostgresBackend ?
        ["ALTER TABLE $(quote_name(b, from.name)) DROP CONSTRAINT $(quote_name(b, c.name))"] : String[]
    if c.kind === :unique
        isempty(unique_constraint_sql(b, from.name, c)) && return String[]
        return [drop_index_stmt(b, from.name, c.name)]
    end
    can_alter_table(b) || return remake_table_sql(b, from, to)
    ["ALTER TABLE $(quote_name(b, from.name)) DROP CONSTRAINT $(quote_name(b, c.name))"]
end

# --- validation ----------------------------------------------------------------------------------

"Three-valued (`missing` = unknown) value of a condition over field names, for `values`."
function condition_value(T, q::Q, value)
    acc = q.connector === :OR ? false : true
    for c in q.children
        r = if c isa Q
            condition_value(T, c, value)
        else
            name, lookup = split_lookup(c.first)
            x = value(name)
            v = c.second
            v isa Model && (v = v.id)
            v isa F && (v = value(v.name))
            lookup_value(x, lookup, v)
        end
        acc = q.connector === :OR ? (acc | r) : (acc & r)
    end
    q.negated ? !acc : acc
end

function lookup_value(x, lookup, v)
    lookup == "isnull" && return (x === nothing) == v
    lookup == "exact" && v === nothing && return x === nothing
    (x === nothing || v === nothing) && return missing
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
            push!(out, split_lookup(c.first)[1])
            c.second isa F && push!(out, c.second.name)
        end
    end
    out
end

constraint_fields(c::CheckConstraint) = condition_fields(c.condition)
function constraint_fields(c::ExclusionConstraint)
    s = Set{String}(string(f) for (f, _) in c.expressions)
    c.condition === nothing || condition_fields(c.condition, s)
    s
end
function constraint_fields(c::UniqueConstraint)
    s = Set{String}(string.(c.fields))
    for e in c.expressions
        push!(s, e isa Func ? e.args[1].name : e isa F ? e.name : string(e))
    end
    c.condition === nothing || condition_fields(c.condition, s)
    s
end

"""
    constraint_errors(Model, values, id) -> Vector{String}

Messages for the model's constraints that `values` (field name => value, a `Function` or a
`Dict`) would violate, for the object with `id` (`nothing` if unsaved). Constraints that use
a field missing from `values` are skipped. Unique constraints are checked with a query.
"""
function constraint_errors(::Type{T}, values, id) where {T<:Model}
    has(name) = values isa AbstractDict ? haskey(values, Symbol(name)) : true
    get_(name) = (v = values isa AbstractDict ? values[Symbol(name)] : values(name); v isa Model ? v.id : v)
    errs = String[]
    vname = uppercasefirst(string(modelmeta(T).verbose_name))
    for c in model_constraints(T)
        all(has, constraint_fields(c)) || continue
        if c isa CheckConstraint
            condition_value(T, c.condition, get_) === false || continue
            push!(errs, something(c.violation_error_message, interpolate(gettext("Constraint “%(name)s” is violated."), Dict("name" => c.name))))
        elseif c isa ExclusionConstraint
            # enforced by PostgreSQL only; checked with a query when the operators have lookups
            backend() isa PostgresBackend && all(x -> x[2] in ("=", "&&"), c.expressions) || continue
            c.condition === nothing || condition_value(T, c.condition, get_) === true || continue
            lookups = Pair{Symbol,Any}[]
            for (f, op) in c.expressions
                v = get_(f); v === nothing && @goto next
                push!(lookups, Symbol(f, op == "=" ? "" : "__overlap") => v)
            end
            qs = filter(base_objects(T), Q(:AND, Any[lookups...], false))
            c.condition === nothing || (qs = filter(qs, c.condition))
            id === nothing || (qs = filter(qs, !Q(id = id)))
            exists(qs) && push!(errs, something(c.violation_error_message,
                                               interpolate(gettext("Constraint “%(name)s” is violated."), Dict("name" => c.name))))
        else
            c.condition === nothing || condition_value(T, c.condition, get_) === true || continue
            lookups = Pair{Symbol,Any}[]
            for f in c.fields
                v = get_(f); v === nothing && @goto next
                push!(lookups, f => v)
            end
            for e in c.expressions
                name = e isa Func ? e.args[1].name : e isa F ? e.name : string(e)
                v = get_(name); v === nothing && @goto next
                push!(lookups, Symbol(name, e isa Func ? "__iexact" : "") => v)
            end
            qs = filter(base_objects(T), Q(:AND, Any[lookups...], false))
            c.condition === nothing || (qs = filter(qs, c.condition))
            id === nothing || (qs = filter(qs, !Q(id = id)))
            if exists(qs)
                msg = c.violation_error_message
                if msg === nothing
                    labels = [label(findfield(modelmeta(T), f)) for f in c.fields]
                    msg = isempty(labels) || c.condition !== nothing ?
                        interpolate(gettext("Constraint “%(name)s” is violated."), Dict("name" => c.name)) :
                        interpolate(gettext("%(model)s with this %(fields)s already exists."),
                                    Dict("model" => vname, "fields" => join(labels, " and ")))
                end
                push!(errs, msg)
            end
            @label next
        end
    end
    errs
end
