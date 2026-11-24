# --- Q objects & lookups -------------------------------------------------------------------

"Supertype of query expressions (`F`, `Value`, aggregates, functions...). See expressions.jl."
abstract type Expression end

"""
    Q(; lookups...)

Composable query condition. Combine with `|`, `&` and `xor` (`⊻`: an odd number true), and
negate with `!` (or `~`).

    filter(Post, Q(title__icontains="julia") | Q(body__icontains="julia"))
"""
struct Q
    connector::Symbol
    children::Vector{Any}
    negated::Bool
end
Q(; kw...) = Q(:AND, Any[k => v for (k, v) in kw], false)
# equal when built alike (as Django's Q.__eq__): constraints holding conditions compare too
Base.:(==)(a::Q, b::Q) = a.connector === b.connector && a.negated == b.negated && a.children == b.children
Base.hash(q::Q, h::UInt) = hash(q.children, hash(q.negated, hash(q.connector, hash(:Q, h))))
Q(p::Pair) = Q(:AND, Any[Symbol(p.first) => p.second], false)
Q(q::Q) = Q(:AND, Any[q], false)
# conditional expressions too, as Django's Q(Exact(F("x"), 1), Value(true), y = 2)
Q(a::Union{Q,Expression}, rest::Union{Q,Expression}...; kw...) = Q(:AND, Any[a, rest..., (k => v for (k, v) in kw)...], false)
# Django's repr: (AND: ('pages__gt', 400)), (NOT (AND: ...))
py_repr(x::AbstractString) = "'" * x * "'"
py_repr(x::Bool) = x ? "True" : "False"
py_repr(::Nothing) = "None"
py_repr(x) = repr(x)
function Base.show(io::IO, q::Q)
    kids = join((ch isa Pair ? "('$(ch.first)', $(py_repr(ch.second)))" : sprint(show, ch) for ch in q.children), ", ")
    s = "($(q.connector): $kids)"
    print(io, q.negated ? "(NOT $s)" : s)
end
Base.:|(a::Q, b::Q) = Q(:OR, Any[a, b], false)
Base.:&(a::Q, b::Q) = Q(:AND, Any[a, b], false)
Base.:!(a::Q) = Q(a.connector, a.children, !a.negated)
Base.:~(a::Q) = !a
# xor(a, b, ...) / a ⊻ b: true when an odd number of the conditions are (Django's Q ^ Q)
xor_children(q::Q) = q.connector === :XOR && !q.negated ? q.children : Any[q]
xor_children(e) = Any[e]
Base.xor(a::Q, b::Q, rest::Q...) = Q(:XOR, Any[c for x in (a, b, rest...) for c in xor_children(x)], false)

const LOOKUPS = Set(["exact", "iexact", "contains", "icontains", "startswith", "istartswith",
                     "endswith", "iendswith", "gt", "gte", "lt", "lte", "in", "isnull", "range",
                     "ne", "regex", "iregex", "contained_by", "overlap", "has_key", "has_keys",
                     "has_any_keys", "search", "intersects", "within", "covers", "coveredby", "disjoint", "touches",
                     "crosses", "overlaps", "equals", "distance_lt", "distance_lte", "distance_gt", "distance_gte", "dwithin"])

# --- custom lookups and transforms ---------------------------------------------------------------

"A value expression through a lookup's bilateral transforms (see `register_transform`)."
struct Bilateral <: Expression
    expr::Any
    sqls::Vector{Any}
end

struct CustomLookup
    kinds::Union{Nothing,Vector{Symbol}}   # field kinds it applies to (nothing: all)
    sql::Any                               # (lhs, rhs) -> SQL, or (lhs, rhs, inner) after a transform
    prepare::Any                           # value -> parameter
    fields::Union{Nothing,Vector{Any}}     # only these model fields (Django's instance lookups), or nothing
    transform::Union{Nothing,String}       # only right after this transform (Django's Transform.register_lookup)
end
struct CustomTransform
    kinds::Union{Nothing,Vector{Symbol}}
    sql::Any                               # lhs -> SQL
    output::Union{Nothing,Symbol}          # kind of the result (nothing: same as the input)
    fields::Union{Nothing,Vector{Any}}
    bilateral::Bool                        # applied to the value too (Django's Transform.bilateral)
end
const CUSTOM_LOOKUPS = Dict{String,Vector{CustomLookup}}()
const CUSTOM_TRANSFORMS = Dict{String,Vector{CustomTransform}}()

kinds_vec(k) = k === nothing ? nothing : k isa Symbol ? [k] : Symbol[Symbol(x) for x in k]
fields_vec(f) = f === nothing ? nothing : f isa AbstractVector ? collect(Any, f) : Any[f]
applies(x, kind) = x.kinds === nothing || kind !== nothing && kind in x.kinds
"""
The registration of `name` for a column of `kind`: one for this very field (`field`) first, as Django's instance
lookups override the class's, then the latest of the others; a lookup registered for a transform applies only
right after it (`after`, the last transform's name), and before any registered for the kind.
"""
function find_custom(d, name, kind; field = nothing, after = nothing)
    v = get(d, name, nothing)
    v === nothing && return nothing
    tr(x) = hasfield(typeof(x), :transform) ? x.transform : nothing
    for pass in 1:2, x in Iterators.reverse(v)              # the latest registration wins
        fs = x.fields
        (pass == 1) == (fs !== nothing || tr(x) !== nothing) || continue
        fs === nothing || field !== nothing && any(g -> g === field, fs) || continue
        t = tr(x)
        t === nothing || t == after || continue
        (t !== nothing || applies(x, kind)) && return x
    end
    nothing
end

"""
    register_lookup(sql, name; kinds = nothing, prepare = identity)

Add a lookup usable in `filter`, `exclude` and `Q` (Django's `register_lookup`). `sql(lhs, rhs)`
returns the condition, given the column's SQL and the value's placeholder. `kinds` limits it
to some field kinds (`:char`, `:text`, `:int`, ...); `prepare` converts the value first.
A registered lookup takes precedence over a built-in one of the same name.

    Juango.register_lookup("notequal"; kinds = [:char, :text]) do lhs, rhs
        "\$lhs <> \$rhs"
    end
    filter(Author; name__notequal = "Ann")
"""
function register_lookup(sql, name::Union{AbstractString,Symbol}; kinds = nothing, prepare = identity, field = nothing,
                         transform = nothing)
    push!(get!(Vector{CustomLookup}, CUSTOM_LOOKUPS, string(name)),
          CustomLookup(kinds_vec(kinds), sql, prepare, fields_vec(field), transform === nothing ? nothing : string(transform)))
    nothing
end

"""
    register_transform(sql, name; kinds = nothing, output = nothing)

Add a transform: `field__name__lookup` applies `sql(lhs)` to the column before the lookup,
and transforms chain (`name__lower__length__gte = 3`). `output` is the field kind of the
result (`:int` for a length), which decides how values are converted and which custom
lookups apply after it.

    Juango.register_transform("lower"; kinds = [:char, :text]) do lhs
        "LOWER(\$lhs)"
    end
    filter(Author; name__lower__startswith = "an")
"""
function register_transform(sql, name::Union{AbstractString,Symbol}; kinds = nothing, output = nothing, field = nothing,
                            bilateral::Bool = false)
    push!(get!(Vector{CustomTransform}, CUSTOM_TRANSFORMS, string(name)),
          CustomTransform(kinds_vec(kinds), sql, output === nothing ? nothing : Symbol(output), fields_vec(field), bilateral))
    nothing
end

"Remove a lookup or transform registered under `name` (all registrations)."
unregister_lookup(name) = (delete!(CUSTOM_LOOKUPS, string(name)); delete!(CUSTOM_TRANSFORMS, string(name)); nothing)

is_lookup_name(s) = s in LOOKUPS || haskey(CUSTOM_LOOKUPS, s)

"Similarity of two names, as Python's difflib ratio: twice the longest common subsequence over the total length."
function name_ratio(a::AbstractString, b::AbstractString)
    x, y = collect(a), collect(b)
    L = zeros(Int, length(x) + 1, length(y) + 1)
    for i in 1:length(x), j in 1:length(y)
        L[i+1, j+1] = x[i] == y[j] ? L[i, j] + 1 : max(L[i, j+1], L[i+1, j])
    end
    2 * L[end, end] / max(1, length(x) + length(y))
end

"The lookup or transform names closest to a misspelled one (Django's \"perhaps you meant startswith?\")."
function suggest_lookup(name::AbstractString)
    names = union(LOOKUPS, keys(CUSTOM_LOOKUPS), keys(CUSTOM_TRANSFORMS), keys(DATE_TRANSFORMS))
    scored = sort!([(name_ratio(name, n), n) for n in names if name_ratio(name, n) >= 0.6]; rev = true)
    isempty(scored) ? "" : ", perhaps you meant " * join(last.(scored[1:min(end, 2)]), " or ") * "?"
end

"""
Apply registered transforms `names` to `col` of kind `kind`: `(sql, kind)`, or `nothing` if one doesn't apply.
`field` is the model field the column is (for transforms registered on a field); `bilateral` collects the
bilateral transforms' SQL functions, in order, to apply to the value too.
"""
function apply_transforms(col::String, kind, names; field = nothing, bilateral = nothing)
    for n in names
        t = find_custom(CUSTOM_TRANSFORMS, n, kind; field = field)
        field = nothing
        if t === nothing                    # the built-in date transforms: year, hour, date, week_day, ...
            d = date_transform(col, kind, n)
            d === nothing && return nothing
            col, kind = d
            continue
        end
        col = t.sql(col)::AbstractString
        t.bilateral && bilateral !== nothing && push!(bilateral, t.sql)
        t.output === nothing || (kind = t.output)
    end
    String(col), kind
end


struct LookupError <: Exception
    msg::String
end
Base.showerror(io::IO, e::LookupError) = print(io, "FieldError: ", e.msg)

"""
Where `names` stop being transforms of a column of `kind`: `(the names left, the kind there)`, for Django's
"Unsupported lookup 'junk' for IntegerField or join on the field not permitted."
"""
function failed_transform(kind, names; field = nothing)
    for (i, n) in enumerate(names)
        t = find_custom(CUSTOM_TRANSFORMS, n, kind; field = field)
        field = nothing
        if t === nothing
            d = date_transform("x", kind, n)
            d === nothing && return names[i:end], kind
            kind = d[2]
        else
            t.output === nothing || (kind = t.output)
        end
    end
    String[], kind
end
"A field kind as Django's field class name (:int is IntegerField)."
kind_class_name(kind) = (k = kind === nothing ? nothing : get(XML_TYPE_NAMES, kind, nothing); k === nothing ? string(kind) : k)
