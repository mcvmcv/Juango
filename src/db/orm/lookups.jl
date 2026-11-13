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
Q(p::Pair) = Q(:AND, Any[Symbol(p.first) => p.second], false)
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

struct CustomLookup
    kinds::Union{Nothing,Vector{Symbol}}   # field kinds it applies to (nothing: all)
    sql::Any                               # (lhs, rhs) -> SQL
    prepare::Any                           # value -> parameter
end
struct CustomTransform
    kinds::Union{Nothing,Vector{Symbol}}
    sql::Any                               # lhs -> SQL
    output::Union{Nothing,Symbol}          # kind of the result (nothing: same as the input)
end
const CUSTOM_LOOKUPS = Dict{String,Vector{CustomLookup}}()
const CUSTOM_TRANSFORMS = Dict{String,Vector{CustomTransform}}()

kinds_vec(k) = k === nothing ? nothing : k isa Symbol ? [k] : Symbol[Symbol(x) for x in k]
applies(x, kind) = x.kinds === nothing || kind !== nothing && kind in x.kinds
function find_custom(d, name, kind)
    v = get(d, name, nothing)
    v === nothing && return nothing
    for x in Iterators.reverse(v)              # the latest registration wins
        applies(x, kind) && return x
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
function register_lookup(sql, name::Union{AbstractString,Symbol}; kinds = nothing, prepare = identity)
    push!(get!(Vector{CustomLookup}, CUSTOM_LOOKUPS, string(name)), CustomLookup(kinds_vec(kinds), sql, prepare))
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
function register_transform(sql, name::Union{AbstractString,Symbol}; kinds = nothing, output = nothing)
    push!(get!(Vector{CustomTransform}, CUSTOM_TRANSFORMS, string(name)),
          CustomTransform(kinds_vec(kinds), sql, output === nothing ? nothing : Symbol(output)))
    nothing
end

"Remove a lookup or transform registered under `name` (all registrations)."
unregister_lookup(name) = (delete!(CUSTOM_LOOKUPS, string(name)); delete!(CUSTOM_TRANSFORMS, string(name)); nothing)

is_lookup_name(s) = s in LOOKUPS || haskey(CUSTOM_LOOKUPS, s)

"Apply registered transforms `names` to `col` of kind `kind`: `(sql, kind)`, or `nothing` if one doesn't apply."
function apply_transforms(col::String, kind, names)
    for n in names
        t = find_custom(CUSTOM_TRANSFORMS, n, kind)
        if t === nothing                    # the built-in date transforms: year, hour, date, week_day, ...
            d = date_transform(col, kind, n)
            d === nothing && return nothing
            col, kind = d
            continue
        end
        col = t.sql(col)::AbstractString
        t.output === nothing || (kind = t.output)
    end
    String(col), kind
end


struct LookupError <: Exception
    msg::String
end
Base.showerror(io::IO, e::LookupError) = print(io, "FieldError: ", e.msg)
