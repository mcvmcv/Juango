# JSON, array, UUID, range and case-insensitive fields; full-text search ---------------------------
#
# The equivalent of django.contrib.postgres, but cross-backend where it can be: PostgreSQL uses
# native types (jsonb, arrays, uuid, ranges, citext, tsvector); SQLite stores JSON text and
# answers the same lookups with its JSON functions. Full-text search expressions need
# PostgreSQL; the `__search` lookup falls back to word matching on SQLite.
#
#     @model struct Event
#         id_     = UUIDField(default = uuid4)            # or Meta(pk = :uuid) for a UUID primary key
#         data    = JSONField(default = Dict)              # filter(Event; data__owner__name = "Ann")
#         tags    = ArrayField(CharField(max_length=20))   # filter(Event; tags__contains = ["julia"])
#         during  = DateTimeRangeField(null = true)        # filter(Event; during__contains = now())
#         email   = CICharField(max_length = 200)          # case-insensitive comparisons
#     end

const RANGE_KINDS = (:intrange, :daterange, :datetimerange, :decimalrange)

"A JSON value (`Dict`, `Vector`, numbers, strings, `nothing`): `jsonb` on PostgreSQL, text on SQLite."
JSONField(; kw...) = Field(:json; kw...)

"""
    ArrayField(base_field; kw...)

A list of values of the base field's kind (`ArrayField(IntegerField())`,
`ArrayField(CharField(max_length=20))`): a native array on PostgreSQL, JSON text on SQLite.
Lookups: `contains`, `contained_by`, `overlap`, `len` (`tags__len__gt=2`) and indexes (`tags__0="x"`,
`grid__0__1` in a nested array). The base field may be an ArrayField itself (a nested array, as Django's), and
`size` is the most items the array may hold (checked when the model is validated).
"""
function ArrayField(base::Field; size = nothing, kw...)
    inner = base
    while inner.kind === :array
        inner = array_base(inner)
    end
    f = Field(:array; max_length = inner.max_length, max_digits = inner.max_digits, decimal_places = inner.decimal_places, kw...)
    f.related = schema_kind(inner.kind)          # the innermost items' kind (PostgreSQL's arrays of any depth have one type)
    opts = something(f.form, Dict{Symbol,Any}())
    opts[:array_base] = base
    size === nothing || (opts[:array_size] = Int(size))
    f.form = opts
    f
end
"""
    SimpleArrayField(base_field; delimiter = ",", max_length = nothing, min_length = nothing, kw...)

A form field for a list typed as text, its items separated by `delimiter` and each cleaned as `base_field`
cleans a value (Django's `SimpleArrayField`): `clean(SimpleArrayField(IntegerField()), "1,2")` is `[1, 2]`.
`max_length` and `min_length` are the most and fewest items. Nest one for a list of lists
(`SimpleArrayField(SimpleArrayField(CharField()); delimiter = "|")` reads `"a,b|c,d"`).
"""
function SimpleArrayField(base::Field; delimiter = ",", max_length = nothing, min_length = nothing, kw...)
    f = ArrayField(base; size = max_length, kw...)
    f.form[:array_delimiter] = string(delimiter)
    min_length === nothing || (f.form[:array_min_length] = Int(min_length))
    f
end

"An ArrayField's base field (an ArrayField again in a nested array), or nothing."
array_base(f::Field) = f.form === nothing ? nothing : get(f.form, :array_base, nothing)
"The most items an ArrayField may hold (its `size`), or nothing."
array_size(f::Field) = f.form === nothing ? nothing : get(f.form, :array_size, nothing)
array_nested(f::Field) = (b = array_base(f); b !== nothing && b.kind === :array)

"An array's items as the base field takes them (numbers given as text become numbers, as Django's get_prep_value)."
function prep_array(f::Field, v)
    v isa AbstractString && return v
    nested = array_nested(f)
    Any[x === nothing ? nothing : nested ? prep_array(array_base(f), x) : prep_array_elem(f.related, x) for x in v]
end
prep_array_elem(kind, x) = x isa Value ? prep_array_elem(kind, x.value) : kind in INT_KINDS || kind in (:float, :decimal, :uuid, :time) ? convert_elem(kind, x) : x

"""
    HStoreField(; kw...)

A string-to-string map (`Dict("color" => "red", "size" => nothing)`): PostgreSQL's `hstore`
(the extension is created with the table), JSON elsewhere. Lookups: `has_key`, `has_keys`,
`has_any_keys`, `contains`, `contained_by`, exact matches and keys (`attrs__color = "red"`).
"""
HStoreField(; kw...) = Field(:hstore; kw...)

"A UUID (`using UUIDs: uuid4` for `default = uuid4`): `uuid` on PostgreSQL, text on SQLite."
UUIDField(; kw...) = Field(:uuid; kw...)

"Case-insensitive text: `citext` on PostgreSQL, `COLLATE NOCASE` on SQLite."
CICharField(; max_length = 255, kw...) = Field(:citext; max_length = max_length, kw...)

"Integer range (`ValueRange(1, 10)`, or a tuple `(1, 10)`): `int8range` on PostgreSQL."
IntegerRangeField(; default_bounds = nothing, kw...) = range_field(:intrange, "IntegerRangeField", default_bounds; kw...)
"The same as `IntegerRangeField` (Juango's integer ranges are 64-bit already)."
BigIntegerRangeField(; default_bounds = nothing, kw...) = range_field(:intrange, "BigIntegerRangeField", default_bounds; kw...)
"Date range: `daterange` on PostgreSQL."
DateRangeField(; default_bounds = nothing, kw...) = range_field(:daterange, "DateRangeField", default_bounds; kw...)
"""
DateTime range: `tsrange` on PostgreSQL. `default_bounds` (`"[)"`, `"(]"`, `"()"` or `"[]"`) are the bounds of a
`(lower, upper)` tuple assigned to it, as Django's.
"""
DateTimeRangeField(; default_bounds = nothing, kw...) = range_field(:datetimerange, "DateTimeRangeField", default_bounds; kw...)
# discrete ranges (integers, dates) are always stored as [): only continuous ones take other default bounds, as Django's
function range_field(kind::Symbol, cls, default_bounds; kw...)
    f = Field(kind; kw...)
    if default_bounds !== nothing
        kind in (:intrange, :daterange) && throw(ArgumentError("Cannot use 'default_bounds' with $cls."))
        default_bounds in ("[)", "(]", "()", "[]") || throw(ArgumentError("default_bounds must be one of '[)', '(]', '()', or '[]'."))
        f.form = merge(something(f.form, Dict{Symbol,Any}()), Dict{Symbol,Any}(:default_bounds => String(default_bounds)))
    end
    f
end
"""
Decimal range (`ValueRange(Decimal("1.5"), Decimal("9.75"))`): `numrange` on PostgreSQL, exact.
SQLite and MySQL keep ranges as JSON, where the bounds are numbers (about 15 significant digits).
"""
DecimalRangeField(; default_bounds = nothing, kw...) = range_field(:decimalrange, "DecimalRangeField", default_bounds; kw...)

"""
    ValueRange(lower, upper; bounds="[)")

A range for the range fields. `nothing` is unbounded. Integer and date ranges are stored in
the canonical `[)` form, as PostgreSQL does (`ValueRange(1, 10; bounds="[]") == ValueRange(1, 11)`).
"""
struct ValueRange{T}
    lower::Union{Nothing,T}
    upper::Union{Nothing,T}
    bounds::String
end
function ValueRange(lo, hi; bounds = "[)")
    bounds == "empty" && return ValueRange{Any}(nothing, nothing, "empty")
    bounds in ("[)", "(]", "()", "[]") || throw(ArgumentError("bounds must be one of '[)', '(]', '()', or '[]'."))
    T = lo === nothing ? typeof(hi) : typeof(lo)
    lo2, hi2, b2 = canonical(lo, hi, bounds)
    # (nothing between the bounds: the empty range, as PostgreSQL stores [5,5) or (1,2) of integers)
    lo2 !== nothing && hi2 !== nothing && (lo2 > hi2 || (lo2 == hi2 && b2 != "[]")) && return ValueRange{Any}(nothing, nothing, "empty")
    ValueRange{T}(lo2, hi2, b2)
end
# Django's window frame class has this name too: with keywords only, it's a RANGE frame (see RowRange);
# ValueRange(empty = true) is the empty range (Django's NumericRange(empty=True))
ValueRange(; start = nothing, stop = nothing, exclusion = nothing, empty::Bool = false) =
    empty ? ValueRange{Any}(nothing, nothing, "empty") : WindowFrame("RANGE", start, stop, exclusion)
"Whether a range is the empty range (no values at all)."
Base.isempty(r::ValueRange) = r.bounds == "empty"
"""
A range field's value from what's assigned (a ValueRange, or a `(lower, upper)` tuple with the field's
`default_bounds`), with aware datetimes in UTC as stored.
"""
function range_value(f::Field, v)
    v isa Tuple && length(v) == 2 && (v = ValueRange(v[1], v[2]; bounds = range_default_bounds(f)))
    v isa ValueRange || return v
    isempty(v) && return v
    utc(x) = x isa TimeZones.ZonedDateTime ? to_utc_naive(x) : x
    f.kind === :datetimerange && (v.lower isa TimeZones.ZonedDateTime || v.upper isa TimeZones.ZonedDateTime) ?
        ValueRange(utc(v.lower), utc(v.upper); bounds = v.bounds) : v
end
range_default_bounds(f::Field) = f.form === nothing ? "[)" : get(f.form, :default_bounds, "[)")
step_of(x::Integer) = 1
step_of(x::Date) = Day(1)
step_of(x) = nothing
function canonical(lo, hi, bounds)
    s = lo === nothing ? step_of(hi) : step_of(lo)
    s === nothing && return (lo, hi, bounds)
    lo !== nothing && bounds[1] == '(' && (lo += s)
    hi !== nothing && bounds[2] == ']' && (hi += s)
    (lo, hi, "[)")
end
Base.:(==)(a::ValueRange, b::ValueRange) = a.lower == b.lower && a.upper == b.upper && a.bounds == b.bounds
Base.hash(r::ValueRange, h::UInt) = hash((r.lower, r.upper, r.bounds), h)
function Base.in(x, r::ValueRange)
    isempty(r) && return false
    lo_ok = r.lower === nothing || (r.bounds[1] == '[' ? x >= r.lower : x > r.lower)
    hi_ok = r.upper === nothing || (r.bounds[2] == ']' ? x <= r.upper : x < r.upper)
    lo_ok && hi_ok
end
Base.show(io::IO, r::ValueRange) = isempty(r) ? print(io, "empty") :
    print(io, r.bounds[1], something(r.lower, ""), ", ", something(r.upper, ""), r.bounds[2])
display_string(r::ValueRange) = sprint(show, r)

# --- encoding values ---------------------------------------------------------------------------

"Element/parameter text for PostgreSQL array and range literals."
pg_elem(x::AbstractString) = "\"" * replace(x, "\\" => "\\\\", "\"" => "\\\"") * "\""
pg_elem(x::DateTime) = "\"" * Dates.format(x, "yyyy-mm-dd HH:MM:SS.sss") * "\""
pg_elem(x::Date) = string(x)
pg_elem(x::Bool) = x ? "t" : "f"
pg_elem(::Nothing) = "NULL"
pg_elem(x::AbstractVector) = pg_array_literal(x)
pg_elem(x::Dates.Time) = time_string(x)
pg_elem(x) = string(x)
pg_array_literal(v) = "{" * join([pg_elem(x) for x in v], ",") * "}"
"An array literal whose items are JSON or ranges (written as quoted text), at any depth."
pg_array_literal(b, v, kind) =
    "{" * join([x === nothing ? "NULL" : x isa AbstractVector && kind !== :json ? pg_array_literal(b, x, kind) :
                kind === :json ? pg_elem(JSON.json(json_scalar_tree(x))) :
                kind in RANGE_KINDS && x isa ValueRange ? pg_elem(encode_range(b, x)) :
                kind === :hstore && x isa AbstractDict ? pg_elem(encode_hstore(b, x)) : pg_elem(x) for x in v], ",") * "}"

json_scalar(x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS.sss")
json_scalar(x::Union{Date,UUID}) = string(x)
json_scalar(x::Decimal) = Float64(x)          # a JSON number, so the bounds compare as numbers
json_scalar(x::Dates.Time) = time_string(x)
json_scalar(r::ValueRange) = Dict("lower" => json_scalar(r.lower), "upper" => json_scalar(r.upper), "bounds" => r.bounds)  # (in arrays)
json_scalar(x) = x

"Array value as the backend stores it: PostgreSQL array literal, or JSON text. `kind`: the items' (innermost) kind."
encode_array(b::DatabaseBackend, v, kind = nothing) =
    kind === :json || kind === :hstore || kind in RANGE_KINDS ? pg_array_literal(b, v, kind) : pg_array_literal(v)
"Range value as the backend stores it."
function encode_range(::DatabaseBackend, r::ValueRange)
    isempty(r) && return "empty"
    lo = r.lower === nothing ? "" : pg_elem(r.lower)
    hi = r.upper === nothing ? "" : pg_elem(r.upper)
    string(r.bounds[1], lo, ",", hi, r.bounds[2])
end

"""
A string given for a date or datetime field, in a query (`pub_date = "2005-07-27 00:00:00"`) or a
save, as the value: parsed as a form would (the ISO formats and the others it accepts), else a
ValidationError, as Django's `get_prep_value` (#202).
"""
function parse_temporal_string(f::Field, s::AbstractString)
    if f.kind === :datetime                       # with a UTC offset ("2026-01-02T03:04:05+13:00", "...Z")
        z = parse_aware_datetime(s)
        z === nothing || return z
    end
    v, err = to_julia(f, s)
    err === nothing && v !== nothing && return v
    what = f.kind === :date ? "date (YYYY-MM-DD)" : "date and time (YYYY-MM-DD HH:MM[:ss])"
    throw(ValidationError(Dict(f.name => ["\u201c$s\u201d isn't a valid $what."])))
end

function to_db(f::Field, v)
    h = field_hook(f, :get_prep_value)
    h === nothing || (v = h(v))
    f.kind in (:file, :image) && return v === nothing ? "" : file_to_db(f, v)     # no file is stored as ''
    v === nothing && return dbparam(v)
    f.kind === :fk && fk_to_field(f) !== nothing && return to_db(getfield_meta(related_model(f), fk_to_field(f)), v)   # (#220)
    k = f.kind
    v isa AbstractString && k in (:date, :datetime) && (v = parse_temporal_string(f, v))
    k === :datetime && return dbparam(to_utc_naive(v))
    if k === :json
        p = json_nonfinite_path(v)
        p === nothing || throw(ArgumentError("$(f.name): JSON can't hold NaN or infinity (at $p)"))
        return JSON.json(json_scalar_tree(v))
    end
    k === :hstore && return encode_hstore(backend(), v)
    k === :array && return encode_array(backend(), prep_array(f, v), f.related)
    k in RANGE_KINDS && return encode_range(backend(), range_value(f, v))
    k === :uuid && return string(uuid_value(f, v))
    # numbers given as text are taken as numbers; other text is refused, as Django's get_prep_value
    k in INT_KINDS && v isa AbstractString && return dbparam(prep_number(f, Int, v))
    k === :float && v isa AbstractString && return dbparam(prep_number(f, Float64, v))
    k === :time && return time_string(to_time(v))
    k === :binary && return dbparam(Vector{UInt8}(v isa AbstractString ? codeunits(v) : v))
    if k === :ipaddress
        v == "" && return dbparam(nothing)
        ip = clean_ip(string(v), f.related.protocol, f.related.unpack_ipv4)
        # an invalid IPv6 address is refused (as Django); others go as typed (full_clean reports them)
        ip isa Tuple && occursin(':', string(v)) && throw(ValidationError(Dict(f.name => [gettext("Enter a valid IPv6 address.")])))
        return ip isa Tuple ? string(v) : ip
    end
    k === :duration && return encode_duration(backend(), duration_us(v isa Duration ? v : to_duration(v)))
    k === :decimal && return string(f.decimal_places === nothing ? to_decimal(v) : round(to_decimal(v); digits = f.decimal_places))
    k === :geometry && return encode_geometry(v)
    dbparam(v)
end
"A number field's value given as text, or an error naming the field (Django's message)."
function prep_number(f::Field, ::Type{T}, v::AbstractString) where {T}
    t = strip(v)
    x = tryparse(T, t)
    T === Int && x === nothing && (y = tryparse(Float64, t); y !== nothing && isfinite(y) && (x = trunc(Int, y)))
    x === nothing && throw(ArgumentError("Field '$(f.name)' expected a number but got $(repr(String(v)))."))
    x
end

"A UUID field's value: a UUID, its text with or without hyphens (anywhere), or an integer below 2^128."
function uuid_value(f::Field, v)
    v isa UUID && return v
    bad() = throw(ValidationError(Dict(f.name => ["“$(v)” is not a valid UUID."])))
    if v isa Integer
        0 <= v < big(2)^128 || bad()
        return UUID(UInt128(v))
    end
    v isa AbstractString || bad()
    h = lowercase(replace(strip(v), "-" => ""))
    (length(h) == 32 && all(c -> c in "0123456789abcdef", h)) || bad()
    UUID(parse(UInt128, h; base = 16))
end

"Where a value for a JSON field holds NaN or ±Inf (`\"data.runs[2]\"`, or `\"value\"` at the top), or nothing."
function json_nonfinite_path(v, path = "value")
    v isa AbstractFloat && return isfinite(v) ? nothing : path
    if v isa AbstractDict
        for (k, x) in v
            p = json_nonfinite_path(x, path == "value" ? string(k) : path * "." * string(k))
            p === nothing || return p
        end
    elseif v isa Union{AbstractVector,Tuple}
        for (i, x) in enumerate(v)
            p = json_nonfinite_path(x, path * "[" * string(i - 1) * "]")
            p === nothing || return p
        end
    end
    nothing
end
json_scalar_tree(v::AbstractDict) = Dict{String,Any}(string(k) => json_scalar_tree(x) for (k, x) in v)
json_scalar_tree(v::AbstractVector) = Any[json_scalar_tree(x) for x in v]
json_scalar_tree(v) = json_scalar(v)

# --- decoding values -----------------------------------------------------------------------------

# --- hstore ---------------------------------------------------------------------------------------

const HStoreDict = Dict{String,Union{Nothing,String}}

"A map as an hstore value: string keys, string or `nothing` values."
hstore_dict(d) = HStoreDict(string(k) => (v === nothing ? nothing : string(v)) for (k, v) in d)

function hstore_quote(io::IO, s::AbstractString)
    print(io, '"')
    for ch in s
        (ch == '"' || ch == '\\') && print(io, '\\')
        print(io, ch)
    end
    print(io, '"')
end

# hstore off PostgreSQL is a JSON object of strings (or nulls): its keys are always an object's keys (a JSON path
# would take "2" for an array index), and its values are compared as text.
"A JSON path naming one object key (`\$.\"2\"`)."
hstore_json_path(k) = "\$.\"" * replace(string(k), "\\" => "\\\\", "\"" => "\\\"") * "\""
"An hstore key's value, as text or NULL, as SQL with no parameters (F(), values(), order_by() and lookups)."
hstore_key_expr(b::DatabaseBackend, col, key) = "($col -> " * sql_string_literal(b, string(key)) * ")"
"An hstore's keys (`which = :keys`) or values (`:values`) as an array of text (Django's `field__keys`, `field__values`)."
hstore_array_expr(b::DatabaseBackend, col, which::Symbol) =
    "CAST($(which === :keys ? "akeys" : "avals")($col) AS $(array_cast(b, hstore_array_field())))"
const HSTORE_ARRAY_FIELD = Ref{Any}(nothing)
"The field of `field__keys` / `field__values` (an array of text)."
hstore_array_field() = (x = HSTORE_ARRAY_FIELD[]; x === nothing ? (HSTORE_ARRAY_FIELD[] = ArrayField(TextField())) : x)
"A map contained by another (every key of the column's is the value's, with the same value), off PostgreSQL."
hstore_contained_by_sql(b::DatabaseBackend, col, v) = "$col <@ CAST(? AS hstore)", Any[encode_hstore(b, v)]
hstore_contains_sql(b::DatabaseBackend, col, v) = json_contains_sql(b, col, hstore_dict(v))
hstore_exact_sql(b::DatabaseBackend, col, v) = json_exact_sql(b, col, hstore_dict(v))
hstore_has_key_sql(b::DatabaseBackend, col, k) = json_has_key_sql(b, col, k)

"An hstore literal (`\"a\"=>\"1\", \"b\"=>NULL`) on PostgreSQL, JSON elsewhere."
function encode_hstore(b::DatabaseBackend, d)
    b isa PostgresBackend || return JSON.json(hstore_dict(d))
    io = IOBuffer()
    first_ = true
    for (k, v) in d
        first_ || print(io, ", ")
        first_ = false
        hstore_quote(io, string(k))
        print(io, "=>")
        v === nothing ? print(io, "NULL") : hstore_quote(io, string(v))
    end
    String(take!(io))
end

"Parse an hstore literal (or the JSON object other databases store)."
function decode_hstore(v)
    v isa AbstractDict && return hstore_dict(v)
    s = String(v)
    startswith(lstrip(s), "{") && return hstore_dict(JSON.parse(s))
    out = HStoreDict()
    i, n = firstindex(s), lastindex(s)
    function token()
        while i <= n && isspace(s[i]); i = nextind(s, i); end
        if s[i] == '"'
            buf = IOBuffer()
            i = nextind(s, i)
            while s[i] != '"'
                s[i] == '\\' && (i = nextind(s, i))
                print(buf, s[i])
                i = nextind(s, i)
            end
            i = nextind(s, i)
            return String(take!(buf))
        end
        j = i
        while j <= n && !(s[j] in (',', '=')) && !isspace(s[j]); j = nextind(s, j); end
        t = s[i:prevind(s, j)]
        i = j
        uppercase(t) == "NULL" ? nothing : t
    end
    while i <= n
        while i <= n && (isspace(s[i]) || s[i] == ','); i = nextind(s, i); end
        i > n && break
        k = token()
        while s[i] != '>'; i = nextind(s, i); end
        i = nextind(s, i)
        out[string(k)] = token()
    end
    out
end

hstore_has_keys_sql(col, ks, all_::Bool) =
    "$(all_ ? "exists_all" : "exists_any")($col, CAST(? AS TEXT[]))", Any[pg_array_literal(string.(ks))]

"Parse a PostgreSQL array literal (`{a,\"b c\",NULL}`) into strings/`nothing`."
function parse_pg_array(s::AbstractString)
    out = Any[]
    inner = s[2:end-1]
    isempty(inner) && return out
    i, n = 1, lastindex(inner)
    while i <= n
        if inner[i] == '{'                       # a nested array: up to its closing brace
            j, depth, inq = i, 0, false
            while true
                c = inner[j]
                if inq
                    c == '\\' ? (j = nextind(inner, j)) : c == '"' && (inq = false)
                elseif c == '"'
                    inq = true
                elseif c == '{'
                    depth += 1
                elseif c == '}'
                    depth -= 1
                    depth == 0 && break
                end
                j = nextind(inner, j)
            end
            push!(out, parse_pg_array(inner[i:j]))
            i = nextind(inner, j)
        elseif inner[i] == '"'
            buf = IOBuffer()
            i = nextind(inner, i)
            while inner[i] != '"'
                inner[i] == '\\' && (i = nextind(inner, i))
                print(buf, inner[i])
                i = nextind(inner, i)
            end
            push!(out, String(take!(buf)))
            i = nextind(inner, i)
        else
            j = something(findnext(',', inner, i), n + 1)
            tok = inner[i:prevind(inner, j)]
            push!(out, tok == "NULL" ? nothing : tok)
            i = j
        end
        i <= n && inner[i] == ',' && (i = nextind(inner, i))
    end
    out
end

function convert_elem(kind::Symbol, x)
    (x === nothing || x === missing) && return nothing
    (kind in INT_KINDS || kind === :fk) && return x isa Integer ? Int(x) : parse(Int, string(x))
    kind === :float && return x isa Real ? Float64(x) : parse(Float64, string(x))
    kind === :decimal && return x isa Decimal ? x : to_decimal(x isa AbstractFloat ? round(x; sigdigits = 15) : x)
    kind === :bool && return x isa Bool ? x : x isa Integer ? x != 0 : string(x) in ("t", "true")
    kind === :date && return x isa Date ? x : Date(string(x)[1:10])
    kind === :datetime && return x isa DateTime ? x : something(todatetime(replace(string(x), ' ' => 'T'; count = 1)), string(x))   # (PostgreSQL's array items: "2026-01-02 03:04:05.678")
    kind === :uuid && return x isa UUID ? x : UUID(string(x))
    kind === :time && return to_time(x)
    x isa AbstractString ? String(x) : x
end

function decode_array(f::Field, v)
    pgtext = !(v isa AbstractVector) && !startswith(v, "[")      # PostgreSQL's literal (items are text), else JSON
    items = v isa AbstractVector ? v : pgtext ? parse_pg_array(v) : JSON.parse(v)
    decode_array_items(f, items, pgtext)
end
function decode_array_items(f::Field, items, pgtext::Bool)
    nested = array_nested(f)
    Any[x === nothing ? nothing : nested ? decode_array_items(array_base(f), x, pgtext) : decode_array_elem(f.related, x, pgtext)
        for x in items]
end
function decode_array_elem(kind, x, pgtext::Bool)
    kind === :json && return plainjson(pgtext && x isa AbstractString ? JSON.parse(x) : x)
    kind === :hstore && return decode_hstore(x)
    kind in RANGE_KINDS && return decode_range_value(kind, x)
    convert_elem(kind, x)
end

range_elem_kind(k) = k === :intrange ? :bigint : k === :daterange ? :date : k === :decimalrange ? :decimal : :datetime

decode_range(f::Field, v) = decode_range_value(f.kind, v)
function decode_range_value(kind::Symbol, v)
    ek = range_elem_kind(kind)
    if v isa AbstractDict || v isa AbstractString && startswith(v, "{")
        d = v isa AbstractDict ? v : JSON.parse(v)
        d["bounds"] == "empty" && return ValueRange(; empty = true)
        return ValueRange(convert_elem(ek, d["lower"]), convert_elem(ek, d["upper"]); bounds = d["bounds"])
    end
    s = string(v)
    s == "empty" && return ValueRange(; empty = true)
    # "[1,10)", "[20,)" or "(,5]": an empty side is unbounded (a PostgreSQL array parse would drop it)
    lo, hi = split(s[nextind(s, 1):prevind(s, lastindex(s))], ','; limit = 2)
    conv(x) = (x = strip(x, '"'); isempty(x) ? nothing : convert_elem(ek, replace(x, "\\\"" => "\"")))
    ValueRange(conv(lo), conv(hi); bounds = string(s[1], s[end]))
end

function from_db_extra(f::Field, v)
    k = f.kind
    k === :json && return v isa AbstractString ? plainjson(JSON.parse(v)) : plainjson(v)
    k === :hstore && return decode_hstore(v)
    k === :array && return decode_array(f, v)
    k in RANGE_KINDS && return decode_range(f, v)
    k === :uuid && return v isa UUID ? v : UUID(string(v))
    k === :citext && return String(string(v))
    k === :geometry && return decode_geometry(v; srid = geo_spec(f)[2])
    k in (:file, :image) && return file_from_db(f, v)
    NOTFOUND
end

# --- lookups ---------------------------------------------------------------------------------------

"""
A key path of a JSON column as SQL with the keys inlined (no parameters), for values(), values_list()
and order_by(): the value as JSON text (decoded when read), or with `sortable` something that
orders numbers as numbers.
"""
json_path_sql(b::DatabaseBackend, col, keys; sortable = false) = "($col #> " * sql_string_literal(b, pg_array_literal(keys)) * ")"
"An ORDER BY term for a JSON key path (numbers ordered as numbers)."
json_order_sql(b::DatabaseBackend, col, keys, desc::Bool) = json_path_sql(b, col, keys; sortable = true) * (desc ? " DESC" : " ASC")

"SQL for a JSON key path value (`data__owner__name`). `numeric` casts for number comparisons."
function json_key_sql(::DatabaseBackend, col, keys, numeric::Bool; boolean = false)
    sql = "($col #>> CAST(? AS TEXT[]))"
    (numeric ? "CAST($sql AS NUMERIC)" : sql), Any[pg_array_literal(keys)]
end
"A JSON key path's value as text, with the keys written in (KT, Django's KeyTextTransform): PostgreSQL's #>>."
json_text_sql(b::DatabaseBackend, col, keys) = "($col #>> " * sql_string_literal(b, pg_array_literal(keys)) * ")"
json_key_isnull_sql(::DatabaseBackend, col, keys) = "($col #> CAST(? AS TEXT[])) IS NULL", Any[pg_array_literal(keys)]
json_contains_sql(::DatabaseBackend, col, v) = "$col @> CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_contained_by_sql(::DatabaseBackend, col, v) = "$col <@ CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_exact_sql(::DatabaseBackend, col, v) = "$col = CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_has_key_sql(::DatabaseBackend, col, k) = "jsonb_exists($col, ?)", Any[string(k)]
json_has_keys_sql(::DatabaseBackend, col, ks, all_::Bool) =
    "$(all_ ? "jsonb_exists_all" : "jsonb_exists_any")($col, CAST(? AS TEXT[]))", Any[pg_array_literal(string.(ks))]

array_cast(::DatabaseBackend, f::Field) = column_type(backend(), f.related === :string ? :char : f.related, f.max_length) * "[]"
array_op_sql(b::DatabaseBackend, op, col, f::Field, v) = "$col $op CAST(? AS $(array_cast(b, f)))", Any[encode_array(b, v, f.related)]
array_len_sql(::DatabaseBackend, col) = "CASE WHEN $col IS NULL THEN NULL ELSE COALESCE(array_length($col, 1), 0) END"   # (no array has no length)
"Items `a` to `z - 1` of an array (Django's `field__a_z`), as an array."
array_slice_sql(::DatabaseBackend, col, a::Int, z::Int) = "$col[$(a + 1):$z]"
"`(a, z)` for a slice segment (`\"0_2\"`), or nothing."
function array_slice_bounds(s::AbstractString)
    m = match(r"^(\d+)_(\d+)$", s)
    m === nothing ? nothing : (parse(Int, m[1]), parse(Int, m[2]))
end
"""
An array transform's path (`["1"]`, `["0", "1"]`, `["0_2"]`, `["len"]`) as SQL with no parameters and the field its
result is (an item's field, the array's for a slice, nothing for a length), or nothing when it isn't one.
"""
function array_transform(b::DatabaseBackend, f::Field, col, rest)
    isempty(rest) && return nothing
    rest == ["len"] && return array_len_sql(b, col), nothing
    sl = array_slice_bounds(rest[end])
    if sl !== nothing
        length(rest) == 1 || return nothing           # (Django can't slice inside a nested array either)
        return array_slice_sql(b, col, sl...), f
    end
    all(r -> !isempty(r) && all(isdigit, r), rest) || return nothing
    item = array_item_field(f, length(rest))
    array_item_expr(b, array_index_expr(b, col, parse.(Int, rest)), item), item
end
"An array item read for F(), values() and order_by(), as the item's kind (MySQL reads JSON items as text)."
array_item_expr(::DatabaseBackend, sql, item) = sql
"An array transform as an ORDER BY term (MySQL's items are text: numbers are ordered as numbers)."
array_order_sql(::DatabaseBackend, sql, item) = sql
"An array index (or nested indexes) as SQL with no parameters, for F(), values() and order_by()."
function array_index_expr(b::DatabaseBackend, col, is::Vector{Int})
    sql, ps = array_index_sql(b, col, is)
    isempty(ps) ? sql : replace(sql, "?" => sql_string_literal(b, ps[1]); count = 1)
end
const ARRAY_COMPARE_OPS = Dict("gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")
"""
An array column compared with array `v` as PostgreSQL compares arrays (`field__gt = [0]`): item by item, the first
different item deciding, and a shorter array that's the start of the other before it. For databases that keep arrays as
JSON (#296): the comparison is written out for each of `v`'s items.
"""
function array_compare_sql(b::DatabaseBackend, op::String, col, f::Field, v::AbstractVector)
    item = array_item_field(f, 1)
    it(i) = array_item_expr(b, array_index_expr(b, col, [i]), item)
    len = array_len_sql(b, col)
    n, lt, strict = length(v), op in ("<", "<="), op in ("<", ">")
    parts, ps = String[], Any[]
    eqs(i) = (for j in 0:i-1; push!(ps, v[j+1]); end; String["$(it(j)) = ?" for j in 0:i-1])
    for i in 0:n-1
        cs = eqs(i)
        push!(cs, lt ? "($len = $i OR $(it(i)) < ?)" : "($len > $i AND $(it(i)) > ?)")
        push!(ps, v[i+1])
        push!(parts, "(" * join(cs, " AND ") * ")")
    end
    # (equal on all of v's items: decided by the lengths)
    if !(lt && strict)
        cs = eqs(n)
        push!(cs, lt ? "$len = $n" : strict ? "$len > $n" : "$len >= $n")
        push!(parts, "(" * join(cs, " AND ") * ")")
    end
    "($col IS NOT NULL AND (" * (isempty(parts) ? sql_false(b) : join(parts, " OR ")) * "))", ps
end
"The field of an array's items `n` levels down (its base field, the base's base, ...)."
function array_item_field(f::Field, n::Int)
    for _ in 1:n
        f.kind === :array || return nothing
        f = array_base(f)
        f === nothing && return nothing
    end
    f
end
array_index_sql(::DatabaseBackend, col, is::Vector{Int}) = "$col" * join("[$(i + 1)]" for i in is), Any[]

range_type(::DatabaseBackend, kind) = kind === :intrange ? "INT8RANGE" : kind === :daterange ? "DATERANGE" :
                                       kind === :decimalrange ? "NUMRANGE" : "TSRANGE"
range_elem_type(b::DatabaseBackend, kind) = column_type(b, range_elem_kind(kind), nothing)
const RANGE_OPS = Dict("contains" => "@>", "contained_by" => "<@", "overlap" => "&&", "exact" => "=", "fully_lt" => "<<",
                       "fully_gt" => ">>", "not_lt" => "&>", "not_gt" => "&<", "adjacent_to" => "-|-")
"""
    RangeBoundary(; inclusive_lower = true, inclusive_upper = false)

A range's bounds (`'[)'`) as an expression, for building a range in SQL: `SQLFunction("TSTZRANGE", :start, :stop,
RangeBoundary())` (Django's `RangeBoundary`).
"""
RangeBoundary(; inclusive_lower::Bool = true, inclusive_upper::Bool = false) =
    Value((inclusive_lower ? "[" : "(") * (inclusive_upper ? "]" : ")"))
"Lookups on a range field besides contains, contained_by, overlap and exact (Django's RangeField lookups)."
const RANGE_LOOKUPS = ("fully_lt", "fully_gt", "not_lt", "not_gt", "adjacent_to", "isempty", "lower_inc", "lower_inf",
                       "upper_inc", "upper_inf", "startswith", "endswith")
"A bound or an element compared with a range column: as the range's kind stores it (a datetime's date for dates)."
function range_elem_value(kind, x)
    x isa Value && (x = x.value)
    x isa TimeZones.ZonedDateTime && (x = to_utc_naive(x))
    kind === :daterange && x isa DateTime && return Date(x)
    kind === :decimalrange && x isa Real && !(x isa Decimal) && return to_decimal(x)
    x
end
range_param(kind, v) = v isa Tuple && length(v) == 2 ? ValueRange(range_elem_value(kind, v[1]), range_elem_value(kind, v[2])) :
                       v isa ValueRange ? v : range_elem_value(kind, v)
function range_lookup_sql(b::DatabaseBackend, op::String, col, kind, v)
    v = range_param(kind, v)
    if op in ("isempty", "lower_inc", "lower_inf", "upper_inc", "upper_inf")
        return "$op($col) = ?", Any[truthy(v)]
    end
    op == "startswith" && return "lower($col) = CAST(? AS $(range_elem_type(b, kind)))", Any[v]
    op == "endswith" && return "upper($col) = CAST(? AS $(range_elem_type(b, kind)))", Any[v]
    if v isa ValueRange
        return "$col $(RANGE_OPS[op]) CAST(? AS $(range_type(b, kind)))", Any[encode_range(b, v)]
    end
    op == "contains" || throw(LookupError("range lookup '$op' needs a ValueRange"))
    "$col @> CAST(? AS $(range_elem_type(b, kind)))", Any[v]
end
"A range's lower (`which = :lower`) or upper bound as SQL (Django's `startswith` / `endswith` transforms)."
range_bound_expr(b::DatabaseBackend, col, which::Symbol) = "$which($col)"

# Off PostgreSQL a range is JSON ({"lower", "upper", "bounds"}, bounds "empty" for the empty range): lookups compare
# its parts with the value's, which are known (a constant), so each comparison is written out for them.
"""
SQL for a range lookup off PostgreSQL, from the column's parts `p` (`lo`, `hi`: the bounds, NULL when unbounded;
`loinc`, `hiinc`, `empty`: conditions) and the value. As PostgreSQL's operators, inclusive and exclusive bounds included.
"""
function range_parts_sql(b::DatabaseBackend, p, op::String, col, kind, v)
    v = range_param(kind, v)
    s(x) = json_scalar(x)
    T, Fa = sql_true(b), sql_false(b)
    ne = "NOT $(p.empty)"
    if op in ("isempty", "lower_inc", "lower_inf", "upper_inc", "upper_inf")
        e = op == "isempty" ? p.empty : op == "lower_inc" ? "($ne AND $(p.lo) IS NOT NULL AND $(p.loinc))" : op == "lower_inf" ? "($ne AND $(p.lo) IS NULL)" :
            op == "upper_inc" ? "($ne AND $(p.hi) IS NOT NULL AND $(p.hiinc))" : "($ne AND $(p.hi) IS NULL)"
        return (truthy(v) ? e : "NOT $e"), Any[]
    end
    op == "startswith" && return "($ne AND $(p.lo) = ?)", Any[s(v)]
    op == "endswith" && return "($ne AND $(p.hi) = ?)", Any[s(v)]
    if !(v isa ValueRange)                     # an element
        op == "contains" || throw(LookupError("range lookup '$op' needs a ValueRange"))
        x = s(v)
        return "($ne AND ($(p.lo) IS NULL OR $(p.lo) < ? OR ($(p.loinc) AND $(p.lo) = ?)) AND ($(p.hi) IS NULL OR ? < $(p.hi) OR ($(p.hiinc) AND $(p.hi) = ?)))",
               Any[x, x, x, x]
    end
    op == "exact" && return range_exact_sql(b, col, v)
    lo, hi = s(v.lower), s(v.upper)
    li, hinc = !isempty(v) && v.bounds[1] == '[', !isempty(v) && v.bounds[2] == ']'
    # the column's lower bound <= / >= the value's, and its upper bound >= / <=
    lower_le() = v.lower === nothing ? ("$(p.lo) IS NULL", Any[]) :
        ("($(p.lo) IS NULL OR $(p.lo) < ? OR ($(p.lo) = ?" * (li ? " AND $(p.loinc)" : "") * "))", Any[lo, lo])
    lower_ge() = v.lower === nothing ? (T, Any[]) :
        ("($(p.lo) IS NOT NULL AND ($(p.lo) > ? OR ($(p.lo) = ?" * (li ? "" : " AND NOT $(p.loinc)") * ")))", Any[lo, lo])
    upper_ge() = v.upper === nothing ? ("$(p.hi) IS NULL", Any[]) :
        ("($(p.hi) IS NULL OR $(p.hi) > ? OR ($(p.hi) = ?" * (hinc ? " AND $(p.hiinc)" : "") * "))", Any[hi, hi])
    upper_le() = v.upper === nothing ? (T, Any[]) :
        ("($(p.hi) IS NOT NULL AND ($(p.hi) < ? OR ($(p.hi) = ?" * (hinc ? "" : " AND NOT $(p.hiinc)") * ")))", Any[hi, hi])
    both(a, c) = ("($ne AND " * a[1] * " AND " * c[1] * ")", vcat(a[2], c[2]))
    if op == "contains"
        isempty(v) && return T, Any[]
        return both(lower_le(), upper_ge())
    elseif op == "contained_by"
        isempty(v) && return p.empty, Any[]
        x = both(lower_ge(), upper_le())
        return "($(p.empty) OR $(x[1]))", x[2]
    end
    isempty(v) && return Fa, Any[]                  # the empty range overlaps, adjoins and is beside nothing
    if op == "overlap"
        a = v.upper === nothing ? (T, Any[]) :
            ("($(p.lo) IS NULL OR $(p.lo) < ?" * (hinc ? " OR ($(p.lo) = ? AND $(p.loinc))" : "") * ")", hinc ? Any[hi, hi] : Any[hi])
        c = v.lower === nothing ? (T, Any[]) :
            ("($(p.hi) IS NULL OR ? < $(p.hi)" * (li ? " OR ($(p.hi) = ? AND $(p.hiinc))" : "") * ")", li ? Any[lo, lo] : Any[lo])
        return both(a, c)
    elseif op == "fully_lt"
        v.lower === nothing && return Fa, Any[]
        return "($ne AND $(p.hi) IS NOT NULL AND ($(p.hi) < ? OR ($(p.hi) = ?" * (li ? " AND NOT $(p.hiinc)" : "") * ")))", Any[lo, lo]
    elseif op == "fully_gt"
        v.upper === nothing && return Fa, Any[]
        return "($ne AND $(p.lo) IS NOT NULL AND ($(p.lo) > ? OR ($(p.lo) = ?" * (hinc ? " AND NOT $(p.loinc)" : "") * ")))", Any[hi, hi]
    elseif op == "not_lt"
        x = lower_ge(); return "($ne AND $(x[1]))", x[2]
    elseif op == "not_gt"
        x = upper_le(); return "($ne AND $(x[1]))", x[2]
    elseif op == "adjacent_to"
        parts, ps = String[], Any[]
        v.lower === nothing || (push!(parts, "($(p.hi) = ? AND " * (li ? "NOT $(p.hiinc)" : "$(p.hiinc)") * ")"); push!(ps, lo))
        v.upper === nothing || (push!(parts, "($(p.lo) = ? AND " * (hinc ? "NOT $(p.loinc)" : "$(p.loinc)") * ")"); push!(ps, hi))
        isempty(parts) && return Fa, Any[]
        return "($ne AND (" * join(parts, " OR ") * "))", ps
    end
    throw(LookupError("unsupported range lookup '$op'"))
end
"A scalar column within a range (Django's `contained_by` on an integer, decimal, date or datetime field)."
function scalar_in_range_sql(col, r::ValueRange; s = identity)
    isempty(r) && return sql_false(backend()), Any[]
    parts, ps = String[], Any[]
    r.lower === nothing || (push!(parts, "$col $(r.bounds[1] == '[' ? ">=" : ">") ?"); push!(ps, s(r.lower)))
    r.upper === nothing || (push!(parts, "$col $(r.bounds[2] == ']' ? "<=" : "<") ?"); push!(ps, s(r.upper)))
    isempty(parts) ? ("$col IS NOT NULL", ps) : ("(" * join(parts, " AND ") * ")", ps)
end

search_sql(::DatabaseBackend, col, text) = "to_tsvector(COALESCE($col, '')) @@ plainto_tsquery(?)", Any[string(text)]
supports_full_text(::DatabaseBackend) = true

"""
Lookups that depend on the field type (JSON, arrays, ranges, full-text). Returns `nothing`
when the field/lookup pair isn't special.
"""
Base.@nospecializeinfer function special_lookup(c::SQLCompiler, f::Field, col, lookup, @nospecialize(value))
    b = backend()
    k = f.kind
    if k === :geometry
        return spatial_lookup(c, f, col, lookup, value)
    elseif lookup == "search"
        # dialogue__search = SearchQuery(...) (or F, Lexemes): the column's vector in the query's configuration
        if value isa Union{SearchQueryLike,Expression,LexemeLike}
            q = as_search_query(value)
            cfg = search_query_config(q)
            csql, cps = cfg === nothing ? ("", Any[]) : ((x = compile_expr(c, cfg)); (x[1] * ", ", x[2]))
            qsql, qps = compile_expr(c, q)
            return "to_tsvector($csql COALESCE($col, '')) @@ $qsql", vcat(cps, qps)
        end
        return search_sql(b, col, value)
    elseif k === :tsvector && lookup == "exact" && value !== nothing
        qsql, qps = compile_expr(c, as_search_query(value))      # (text or Lexemes: a plain query)
        return "$col @@ $qsql", qps
    elseif k === :hstore && b isa PostgresBackend
        lookup == "exact" && value !== nothing && return "$col = CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "contains" && return "$col @> CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "contained_by" && return "$col <@ CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "has_key" && return "exist($col, ?)", Any[string(value)]
        lookup == "has_keys" && return hstore_has_keys_sql(col, value, true)
        lookup == "has_any_keys" && return hstore_has_keys_sql(col, value, false)
    elseif k === :hstore && value isa AbstractDict && lookup in ("exact", "contains", "contained_by")
        lookup == "exact" && return hstore_exact_sql(b, col, value)
        lookup == "contains" && return hstore_contains_sql(b, col, value)
        return hstore_contained_by_sql(b, col, hstore_dict(value))
    elseif k === :hstore && lookup in ("has_key", "has_keys", "has_any_keys")
        lookup == "has_key" && return hstore_has_key_sql(b, col, string(value))
        parts = [hstore_has_key_sql(b, col, string(x)) for x in value]
        isempty(parts) && return (lookup == "has_keys" ? sql_true(b) : sql_false(b)), Any[]
        return "(" * join(first.(parts), lookup == "has_keys" ? " AND " : " OR ") * ")", reduce(vcat, last.(parts))
    elseif k === :json || k === :hstore
        k === :hstore && value isa AbstractDict && (value = hstore_dict(value))
        lookup == "exact" && value !== nothing && return json_exact_sql(b, col, value)
        lookup == "contains" && return json_contains_sql(b, col, value)
        lookup == "contained_by" && return json_contained_by_sql(b, col, value)
        lookup == "has_key" && return json_has_key_sql(b, col, value)
        lookup == "has_keys" && return json_has_keys_sql(b, col, value, true)
        lookup == "has_any_keys" && return json_has_keys_sql(b, col, value, false)
    elseif k === :array
        if lookup == "in" && value isa Union{AbstractVector,Tuple}
            value = Any[x isa Union{AbstractVector,Tuple} ? prep_array(f, x) : x for x in value]
        elseif value isa Union{AbstractVector,Tuple}
            value = prep_array(f, value)
        end
        lookup == "contains" && return array_op_sql(b, "@>", col, f, value)
        lookup == "contained_by" && return array_op_sql(b, "<@", col, f, value)
        lookup == "overlap" && return array_op_sql(b, "&&", col, f, value)
        lookup == "exact" && value !== nothing && return array_op_sql(b, "=", col, f, value)
        # (PostgreSQL compares its arrays item by item; elsewhere they're JSON text: compared item by item here, #296)
        haskey(ARRAY_COMPARE_OPS, lookup) && !(b isa PostgresBackend) && value isa AbstractVector &&
            return array_compare_sql(b, ARRAY_COMPARE_OPS[lookup], col, f, value)
    elseif k in RANGE_KINDS
        # dates__contains = F(:inner) on PostgreSQL: the other side compiled (a range or an element column); a Value is
        # a plain value
        if b isa PostgresBackend && value isa Expression && !(value isa Value) && haskey(RANGE_OPS, lookup)
            vsql, vps = compile_expr(c, value)
            return "$col $(RANGE_OPS[lookup]) ($vsql)", vps
        end
        lookup in ("contains", "contained_by", "overlap") && return range_lookup_sql(b, lookup, col, k, value)
        lookup in RANGE_LOOKUPS && return range_lookup_sql(b, lookup, col, k, value)
        lookup == "exact" && value !== nothing && return range_lookup_sql(b, "exact", col, k, value)
    end
    nothing
end

"""
Resolve `field__rest...` into a column expression for JSON key paths and array `len`/indexes.
Returns `(sql, params)` or `nothing`.
"""
Base.@nospecializeinfer function transform_column(f::Field, col, rest::Vector{String}, lookup, @nospecialize(value))
    b = backend()
    if f.kind === :hstore && !isempty(rest)
        length(rest) == 1 || return nothing
        rest[1] in ("keys", "values") && return hstore_array_expr(b, col, Symbol(rest[1])), Any[]      # field__keys, field__values
        e = hstore_key_expr(b, col, rest[1])         # field__a: the key's value, text (a key with a NULL value is NULL)
        lookup == "isnull" && return "$e IS NULL", Any[]
        return e, Any[]
    end
    if (f.kind === :json || f.kind === :hstore) && !isempty(rest)
        lookup == "isnull" && return json_key_isnull_sql(b, col, rest)
        nums = value isa Number && !(value isa Bool) || value isa AbstractVector && !isempty(value) &&
               all(x -> x isa Number && !(x isa Bool), value) || value isa Tuple
        return json_key_sql(b, col, rest, nums; boolean = value isa Bool)
    elseif f.kind in RANGE_KINDS && rest in (["startswith"], ["endswith"])       # ints__startswith__gte = 0: the bound
        return range_bound_expr(b, col, rest[1] == "startswith" ? :lower : :upper), Any[]
    elseif f.kind === :array && rest == ["len"]
        return array_len_sql(b, col), Any[]
    elseif f.kind === :array && !isempty(rest) && all(r -> all(isdigit, r), rest)     # (nested: grid__0__1)
        return array_index_expr(b, col, parse.(Int, rest)), Any[]
    elseif f.kind === :array && length(rest) == 1 && (sl = array_slice_bounds(rest[1])) !== nothing    # field__0_2
        return array_slice_sql(b, col, sl...), Any[]
    end
    nothing
end

# --- full-text search expressions (PostgreSQL) --------------------------------------------------------

"""
    SearchConfig(name)

A text search configuration (`"english"`, `"french"`, `"simple"`), or an expression naming one per row
(`SearchConfig(F(:config))`): PostgreSQL's `regconfig`. `config =` options take a name, an `F()` or one of these.
"""
struct SearchConfig <: Expression
    config::Expression
    SearchConfig(c::Expression) = new(c)
end
SearchConfig(c::SearchConfig) = c
SearchConfig(c) = SearchConfig(Value(string(c)))
Base.:(==)(a::SearchConfig, b::SearchConfig) = a.config == b.config
"A `config =` value as a SearchConfig, or nothing (Django's `SearchConfig.from_parameter`)."
search_config(::Nothing) = nothing
search_config(c) = SearchConfig(c)
function compile_expr(c::SQLCompiler, e::SearchConfig)
    sql, ps = compile_expr(c, e.config)
    "CAST($sql AS regconfig)", ps
end

"""
    SearchVector(fields...; config=nothing, weight=nothing)

A `tsvector` of text fields for full-text search (PostgreSQL). Combine with `+`.
`filter(annotate(qs; search = SearchVector(:title, :body)); search = SearchQuery("julia web"))`, or
`search = "julia web"` (a plain query in the vector's configuration). `config` is a name, `F()` or SearchConfig;
`weight` is "A", "B", "C" or "D" (for SearchRank).
"""
struct SearchVector <: Expression
    parts::Vector{Tuple{Vector{Any},Any,Union{Nothing,Char}}}   # (fields, config: nothing or a SearchConfig, weight)
    SearchVector(parts::Vector{<:Tuple}) = new(parts)
end
SearchVector(fields...; config = nothing, weight = nothing) =
    SearchVector([(Any[ref(x) for x in fields], search_config(config),
                   weight === nothing ? nothing : uppercase(string(weight))[1])])
Base.:+(a::SearchVector, b::SearchVector) = SearchVector(vcat(a.parts, b.parts))
Base.:+(a::SearchVector, b) = throw(ArgumentError("SearchVector can only be combined with other SearchVector instances, got $(nameof(typeof(b)))."))
Base.:+(a, b::SearchVector) = throw(ArgumentError("SearchVector can only be combined with other SearchVector instances, got $(nameof(typeof(a)))."))
"The configuration of a vector (its first part's), for a plain query compared with it."
search_vector_config(v::SearchVector) = v.parts[1][2]

"""
    Lexeme(value; invert = false, prefix = false, weight = nothing)

One word of a raw text search query, quoted so it can't be read as query syntax (Django's Lexeme). Combine
with `&`, `|` and `~` (`~(a | b)` is `~a & ~b`); `prefix = true` matches words starting with it, `weight` (A-D) only
in parts of the vector with that weight. `SearchQuery(Lexeme("cadeaux"); config = "french")`.
"""
struct Lexeme
    value::String
    invert::Bool
    prefix::Bool
    weight::Union{Nothing,String}
end
function Lexeme(value; invert::Bool = false, prefix::Bool = false, weight = nothing)
    value isa AbstractString || throw(ArgumentError("Lexeme value must be a string, got $(nameof(typeof(value)))."))
    isempty(value) && throw(ArgumentError("Lexeme value cannot be empty."))
    if weight !== nothing
        weight isa AbstractString && weight in ("A", "B", "C", "D") ||
            throw(ArgumentError("Weight must be one of 'A', 'B', 'C', and 'D', got $(repr(weight))."))
    end
    Lexeme(String(value), invert, prefix, weight === nothing ? nothing : String(weight))
end
struct CombinedLexeme
    op::String                   # "&" or "|"
    a::Union{Lexeme,CombinedLexeme}
    b::Union{Lexeme,CombinedLexeme}
end
const LexemeLike = Union{Lexeme,CombinedLexeme}
Base.:&(a::LexemeLike, b::LexemeLike) = CombinedLexeme("&", a, b)
Base.:|(a::LexemeLike, b::LexemeLike) = CombinedLexeme("|", a, b)
for op in (:&, :|)
    @eval Base.$op(a::LexemeLike, b) = throw(ArgumentError("A Lexeme can only be combined with another Lexeme, got $(nameof(typeof(b)))."))
    @eval Base.$op(a, b::LexemeLike) = throw(ArgumentError("A Lexeme can only be combined with another Lexeme, got $(nameof(typeof(a)))."))
end
Base.:~(l::Lexeme) = Lexeme(l.value, !l.invert, l.prefix, l.weight)
Base.:~(l::CombinedLexeme) = CombinedLexeme(l.op == "&" ? "|" : "&", ~l.a, ~l.b)      # (De Morgan, as Django's)
Base.:!(l::LexemeLike) = ~l
"""
    quote_lexeme(s)

A word as a quoted tsquery lexeme: characters that are query syntax (`'`, `&`, `|`, `!`, `:`, `*`, ...) become spaces,
and nothing left is `NULL` (Django's `quote_lexeme`).
"""
function quote_lexeme(s::AbstractString)
    t = strip(replace(s, r"['\0\[\]()|&:*!@<>\\]" => " "))
    isempty(t) && return "NULL"
    "'" * replace(replace(t, r"\s{2,}" => " "), "'" => "''") * "'"
end
"A Lexeme (or a combination of them) as tsquery text (`!'a':*D`, `('a' | ('b' & !'c'))`)."
function lexeme_text(l::Lexeme)
    label = (l.prefix ? "*" : "") * something(l.weight, "")
    (l.invert ? "!" : "") * quote_lexeme(l.value) * (isempty(label) ? "" : ":" * label)
end
lexeme_text(l::CombinedLexeme) = "(" * lexeme_text(l.a) * " " * l.op * " " * lexeme_text(l.b) * ")"

abstract type SearchQueryLike <: Expression end
const SEARCH_TYPES = Dict(:plain => "plainto_tsquery", :phrase => "phraseto_tsquery", :websearch => "websearch_to_tsquery",
                          :raw => "to_tsquery")
"""
    SearchQuery(value; config=nothing, search_type=:plain)

A `tsquery`: of text (`search_type` `:plain`, all words; `:phrase`; `:websearch`, quotes, `or` and `-word`; `:raw`,
tsquery syntax), of an `F()` (a query per row), or of `Lexeme`s. Combine with `&`, `|` and `~`.
"""
struct SearchQuery <: SearchQueryLike
    value::Any                       # text, an Expression, or Lexemes
    config::Union{Nothing,SearchConfig}
    search_type::Symbol
    invert::Bool
end
function SearchQuery(value; config = nothing, search_type = :plain, invert::Bool = false)
    st = Symbol(search_type)
    haskey(SEARCH_TYPES, st) || throw(ArgumentError("Unknown search_type argument '$search_type'."))
    value isa Union{Expression,LexemeLike} || (value = string(value))
    SearchQuery(value, search_config(config), st, invert)
end
struct CombinedSearchQuery <: SearchQueryLike
    op::String                       # "&&" or "||"
    a::SearchQueryLike
    b::SearchQueryLike
    invert::Bool
end
Base.:&(a::SearchQueryLike, b::SearchQueryLike) = CombinedSearchQuery("&&", a, b, false)
Base.:|(a::SearchQueryLike, b::SearchQueryLike) = CombinedSearchQuery("||", a, b, false)
for op in (:&, :|)
    @eval Base.$op(a::SearchQueryLike, b) = throw(ArgumentError("SearchQuery can only be combined with other SearchQuery instances, got $(nameof(typeof(b)))."))
    @eval Base.$op(a, b::SearchQueryLike) = throw(ArgumentError("SearchQuery can only be combined with other SearchQuery instances, got $(nameof(typeof(a)))."))
end
Base.:~(q::SearchQuery) = SearchQuery(q.value, q.config, q.search_type, !q.invert)
Base.:~(q::CombinedSearchQuery) = CombinedSearchQuery(q.op, q.a, q.b, !q.invert)
Base.:!(q::SearchQueryLike) = ~q
"A query's configuration (a combination's: its first query's)."
search_query_config(q::SearchQuery) = q.config
search_query_config(q::CombinedSearchQuery) = search_query_config(q.a)
# (Django's repr: SearchQuery(Value('a')), ~SearchQuery(...), (A || B) && C)
Base.show(io::IO, q::SearchQuery) = print(io, q.invert ? "~" : "", "SearchQuery(", q.value isa AbstractString ? "Value('$(q.value)')" : q.value, ")")
Base.show(io::IO, q::CombinedSearchQuery) = print(io, q.invert ? "~" : "", "(", q.a, " ", q.op, " ", q.b, ")")
"A value compared with a tsvector as a query: text, an F() or Lexemes become a plain (or raw) SearchQuery in `config`."
as_search_query(v::SearchQueryLike, config = nothing) = v
as_search_query(v, config = nothing) = SearchQuery(v; config = config)

need_full_text() = supports_full_text(backend()) ||
    throw(ArgumentError("full-text search expressions need PostgreSQL (the __search lookup works everywhere)"))

function compile_expr(c::SQLCompiler, e::SearchVector)
    need_full_text()
    parts, ps = String[], Any[]
    for (fields, config, weight) in e.parts
        cfg, cps = config === nothing ? ("", Any[]) : ((x = compile_expr(c, config)); (x[1] * ", ", x[2]))
        cols = [compile_expr(c, x) for x in fields]
        # (one COALESCE per field: nothing more, as Django's single coalesce)
        text = join([(x isa Value ? s : "COALESCE(CAST($(s) AS TEXT), '')") for ((s, _), x) in zip(cols, fields)], " || ' ' || ")
        append!(ps, cps)
        append!(ps, reduce(vcat, last.(cols); init = Any[]))
        v = "to_tsvector($cfg$text)"
        push!(parts, weight === nothing ? v : "setweight($v, '$weight')")
    end
    "(" * join(parts, " || ") * ")", ps
end
repr_sql_string(s) = "'" * replace(s, "'" => "''") * "'"

function compile_expr(c::SQLCompiler, e::SearchQuery)
    need_full_text()
    cfg, cps = e.config === nothing ? ("", Any[]) : ((x = compile_expr(c, e.config)); (x[1] * ", ", x[2]))
    sql, ps = if e.value isa LexemeLike
        "to_tsquery($cfg?)", vcat(cps, Any[lexeme_text(e.value)])
    elseif e.value isa Expression
        v, vps = compile_expr(c, e.value)
        "$(SEARCH_TYPES[e.search_type])($cfg$v)", vcat(cps, vps)
    else
        "$(SEARCH_TYPES[e.search_type])($cfg?)", vcat(cps, Any[e.value])
    end
    (e.invert ? "!!($sql)" : sql), ps
end
function compile_expr(c::SQLCompiler, e::CombinedSearchQuery)
    a, aps = compile_expr(c, e.a)
    b, bps = compile_expr(c, e.b)
    sql = "(($a) $(e.op) ($b))"
    (e.invert ? "!!$sql" : sql), vcat(aps, bps)
end

"""
    SearchRank(vector, query; weights = nothing, normalization = nothing, cover_density = false)

Relevance for ordering (`ts_rank`, or `ts_rank_cd` with `cover_density`). `vector` and `query` may be a field name
and text. `weights`: the D, C, B, A weights' factors (`[0.1, 0.2, 0.4, 1.0]`); `normalization`: PostgreSQL's
bit mask (2: divided by the document's length).
"""
struct SearchRank <: Expression
    vector::Expression
    query::SearchQueryLike
    weights::Union{Nothing,Vector{Float64}}
    normalization::Any
    cover_density::Bool
end
SearchRank(v, q; weights = nothing, normalization = nothing, cover_density::Bool = false) =
    SearchRank(v isa Expression ? v : SearchVector(v), as_search_query(q), weights === nothing ? nothing : Float64.(collect(weights)),
               normalization, cover_density)

function compile_expr(c::SQLCompiler, e::SearchRank)
    v, vps = compile_expr(c, e.vector)
    q, qps = compile_expr(c, e.query)
    args, ps = String[], Any[]
    e.weights === nothing || (push!(args, "CAST(? AS float4[])"); push!(ps, "{" * join(e.weights, ",") * "}"))
    push!(args, v, q); append!(ps, vps); append!(ps, qps)
    if e.normalization !== nothing
        n, nps = compile_expr(c, lit_expr(e.normalization))
        push!(args, "CAST($n AS integer)"); append!(ps, nps)
    end
    "$(e.cover_density ? "ts_rank_cd" : "ts_rank")($(join(args, ", ")))", ps
end

"""
    SearchHeadline(expression, query; config, start_sel, stop_sel, max_words, min_words, short_word, highlight_all,
                   max_fragments, fragment_delimiter)

The text with the query's words marked (`<b>...</b>` by default): PostgreSQL's `ts_headline` and its options.
"""
struct SearchHeadline <: Expression
    expr::Expression
    query::SearchQueryLike
    config::Union{Nothing,SearchConfig}
    options::Vector{Pair{String,Any}}
end
function SearchHeadline(expression, query; config = nothing, start_sel = nothing, stop_sel = nothing, max_words = nothing,
                        min_words = nothing, short_word = nothing, highlight_all = nothing, max_fragments = nothing,
                        fragment_delimiter = nothing)
    opts = Pair{String,Any}[k => v for (k, v) in ("StartSel" => start_sel, "StopSel" => stop_sel, "MaxWords" => max_words,
                                                    "MinWords" => min_words, "ShortWord" => short_word, "HighlightAll" => highlight_all,
                                                    "MaxFragments" => max_fragments, "FragmentDelimiter" => fragment_delimiter) if v !== nothing]
    SearchHeadline(ref(expression), as_search_query(query), search_config(config), opts)
end
headline_option(v::Bool) = v ? "true" : "false"
headline_option(v::AbstractString) = "'" * replace(v, "'" => "''") * "'"
headline_option(v) = string(v)
function compile_expr(c::SQLCompiler, e::SearchHeadline)
    need_full_text()
    args, ps = String[], Any[]
    if e.config !== nothing
        s, p = compile_expr(c, e.config); push!(args, s); append!(ps, p)
    end
    s, p = compile_expr(c, e.expr); push!(args, s); append!(ps, p)
    s, p = compile_expr(c, e.query); push!(args, s); append!(ps, p)
    if !isempty(e.options)
        push!(args, "?"); push!(ps, join(["$k=$(headline_option(v))" for (k, v) in e.options], ", "))
    end
    "ts_headline($(join(args, ", ")))", ps
end

"A tsvector column (Django's SearchVectorField): set it with `SearchVector(...)`, filter it with a SearchQuery or text."
SearchVectorField(; kw...) = Field(:tsvector; kw...)

# --- trigram similarity and unaccent (PostgreSQL: pg_trgm, unaccent) ---------------------------------
#
# Install the extensions in a migration with `TrigramExtension()` / `UnaccentExtension()`.

const TEXT_KINDS = vcat(collect(STRING_KINDS), :citext)

register_lookup((lhs, rhs) -> "$lhs % $rhs", "trigram_similar"; kinds = TEXT_KINDS)
register_lookup((lhs, rhs) -> "$rhs <% $lhs", "trigram_word_similar"; kinds = TEXT_KINDS)
register_lookup((lhs, rhs) -> "$rhs <<% $lhs", "trigram_strict_word_similar"; kinds = TEXT_KINDS)
register_transform(lhs -> "UNACCENT($lhs)", "unaccent"; kinds = TEXT_KINDS, bilateral = true)   # (the value too, as Django's)

"`SIMILARITY(field, text)`: trigram similarity from 0 to 1 (PostgreSQL `pg_trgm`)."
TrigramSimilarity(x, text) = Func(:similarity, [ref(x), lit_expr(text)])
"`WORD_SIMILARITY(text, field)` (PostgreSQL `pg_trgm`)."
TrigramWordSimilarity(text, x) = Func(:word_similarity, [lit_expr(text), ref(x)])
"`STRICT_WORD_SIMILARITY(text, field)` (PostgreSQL `pg_trgm`)."
TrigramStrictWordSimilarity(text, x) = Func(:strict_word_similarity, [lit_expr(text), ref(x)])
"`field <-> text`: trigram distance, 1 - similarity (PostgreSQL `pg_trgm`)."
TrigramDistance(x, text) = CombinedExpression("<->", ref(x), lit_expr(text))
"`text <<-> field`: trigram word distance (PostgreSQL `pg_trgm`)."
TrigramWordDistance(text, x) = CombinedExpression("<<->", lit_expr(text), ref(x))
"`text <<<-> field`: trigram strict word distance (PostgreSQL `pg_trgm`)."
TrigramStrictWordDistance(text, x) = CombinedExpression("<<<->", lit_expr(text), ref(x))
"`CURRENT_TIMESTAMP`: the time the current transaction started, the same for every statement in it (PostgreSQL's, Django's `TransactionNow`)."
TransactionNow() = Func(:transaction_now, Any[])
"`gen_random_uuid()`: a random version-4 UUID per row (PostgreSQL 13+; `UUID()` on MySQL)."
RandomUUID() = Func(:random_uuid, Any[])
"`UNACCENT(field)`: text without accents (PostgreSQL `unaccent`)."
Unaccent(x) = Func(:unaccent, [ref(x)])
