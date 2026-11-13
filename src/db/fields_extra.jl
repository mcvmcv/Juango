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

const RANGE_KINDS = (:intrange, :daterange, :datetimerange)

"A JSON value (`Dict`, `Vector`, numbers, strings, `nothing`): `jsonb` on PostgreSQL, text on SQLite."
JSONField(; kw...) = Field(:json; kw...)

"""
    ArrayField(base_field; kw...)

A list of values of the base field's kind (`ArrayField(IntegerField())`,
`ArrayField(CharField(max_length=20))`): a native array on PostgreSQL, JSON text on SQLite.
Lookups: `contains`, `contained_by`, `overlap`, `len` (`tags__len__gt=2`) and indexes (`tags__0="x"`).
"""
function ArrayField(base::Field; kw...)
    f = Field(:array; max_length = base.max_length, kw...)
    f.related = schema_kind(base.kind)
    f
end

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

"Integer range (`ValueRange(1, 10)`): `int8range` on PostgreSQL."
IntegerRangeField(; kw...) = Field(:intrange; kw...)
"Date range: `daterange` on PostgreSQL."
DateRangeField(; kw...) = Field(:daterange; kw...)
"DateTime range: `tsrange` on PostgreSQL."
DateTimeRangeField(; kw...) = Field(:datetimerange; kw...)

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
    T = lo === nothing ? typeof(hi) : typeof(lo)
    ValueRange{T}(canonical(lo, hi, bounds)...)
end
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
    lo_ok = r.lower === nothing || (r.bounds[1] == '[' ? x >= r.lower : x > r.lower)
    hi_ok = r.upper === nothing || (r.bounds[2] == ']' ? x <= r.upper : x < r.upper)
    lo_ok && hi_ok
end
Base.show(io::IO, r::ValueRange) =
    print(io, r.bounds[1], something(r.lower, ""), ", ", something(r.upper, ""), r.bounds[2])
display_string(r::ValueRange) = sprint(show, r)

# --- encoding values ---------------------------------------------------------------------------

"Element/parameter text for PostgreSQL array and range literals."
pg_elem(x::AbstractString) = "\"" * replace(x, "\\" => "\\\\", "\"" => "\\\"") * "\""
pg_elem(x::DateTime) = "\"" * Dates.format(x, "yyyy-mm-dd HH:MM:SS.sss") * "\""
pg_elem(x::Date) = string(x)
pg_elem(x::Bool) = x ? "t" : "f"
pg_elem(::Nothing) = "NULL"
pg_elem(x) = string(x)
pg_array_literal(v) = "{" * join([pg_elem(x) for x in v], ",") * "}"

json_scalar(x::DateTime) = Dates.format(x, "yyyy-mm-ddTHH:MM:SS.sss")
json_scalar(x::Union{Date,UUID}) = string(x)
json_scalar(x) = x

"Array value as the backend stores it: PostgreSQL array literal, or JSON text."
encode_array(::DatabaseBackend, v) = pg_array_literal(v)
"Range value as the backend stores it."
function encode_range(::DatabaseBackend, r::ValueRange)
    lo = r.lower === nothing ? "" : pg_elem(r.lower)
    hi = r.upper === nothing ? "" : pg_elem(r.upper)
    string(r.bounds[1], lo, ",", hi, r.bounds[2])
end

function to_db(f::Field, v)
    f.kind in (:file, :image) && return v === nothing ? "" : file_to_db(f, v)     # no file is stored as ''
    v === nothing && return dbparam(v)
    k = f.kind
    k === :datetime && return dbparam(to_utc_naive(v))
    k === :json && return JSON.json(json_scalar_tree(v))
    k === :hstore && return encode_hstore(backend(), v)
    k === :array && return encode_array(backend(), v)
    k in RANGE_KINDS && return encode_range(backend(), v)
    k === :uuid && return string(v)
    k === :time && return time_string(to_time(v))
    k === :duration && return encode_duration(backend(), duration_us(v isa Duration ? v : to_duration(v)))
    k === :decimal && return string(f.decimal_places === nothing ? to_decimal(v) : round(to_decimal(v); digits = f.decimal_places))
    k === :geometry && return encode_geometry(v)
    dbparam(v)
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
        if inner[i] == '"'
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
    kind in (:int, :fk) && return x isa Integer ? Int(x) : parse(Int, string(x))
    kind === :float && return x isa Real ? Float64(x) : parse(Float64, string(x))
    kind === :bool && return x isa Bool ? x : x isa Integer ? x != 0 : string(x) in ("t", "true")
    kind === :date && return x isa Date ? x : Date(string(x)[1:10])
    kind === :datetime && return x isa DateTime ? x : something(todatetime(string(x)), string(x))
    kind === :uuid && return x isa UUID ? x : UUID(string(x))
    x isa AbstractString ? String(x) : x
end

function decode_array(f::Field, v)
    kind = f.related
    items = v isa AbstractVector ? v :
            startswith(v, "[") ? JSON.parse(v) : parse_pg_array(v)
    Any[convert_elem(kind, x) for x in items]
end

range_elem_kind(k) = k === :intrange ? :int : k === :daterange ? :date : :datetime

function decode_range(f::Field, v)
    ek = range_elem_kind(f.kind)
    if v isa AbstractString && startswith(v, "{")
        d = JSON.parse(v)
        return ValueRange(convert_elem(ek, d["lower"]), convert_elem(ek, d["upper"]); bounds = d["bounds"])
    end
    s = string(v)
    s == "empty" && return ValueRange{Any}(nothing, nothing, "()")
    parts = parse_pg_array("{" * s[2:end-1] * "}")
    conv(x) = (x === nothing || x == "") ? nothing : convert_elem(ek, x)
    ValueRange(conv(parts[1]), conv(parts[2]); bounds = string(s[1], s[end]))
end

function from_db_extra(f::Field, v)
    k = f.kind
    k === :json && return v isa AbstractString ? plainjson(JSON.parse(v)) : plainjson(v)
    k === :hstore && return decode_hstore(v)
    k === :array && return decode_array(f, v)
    k in RANGE_KINDS && return decode_range(f, v)
    k === :uuid && return v isa UUID ? v : UUID(string(v))
    k === :citext && return String(string(v))
    k === :geometry && return decode_geometry(v)
    k in (:file, :image) && return file_from_db(f, v)
    NOTFOUND
end

# --- lookups ---------------------------------------------------------------------------------------

"SQL for a JSON key path value (`data__owner__name`). `numeric` casts for number comparisons."
function json_key_sql(::DatabaseBackend, col, keys, numeric::Bool; boolean = false)
    sql = "($col #>> CAST(? AS TEXT[]))"
    (numeric ? "CAST($sql AS NUMERIC)" : sql), Any[pg_array_literal(keys)]
end
json_key_isnull_sql(::DatabaseBackend, col, keys) = "($col #> CAST(? AS TEXT[])) IS NULL", Any[pg_array_literal(keys)]
json_contains_sql(::DatabaseBackend, col, v) = "$col @> CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_contained_by_sql(::DatabaseBackend, col, v) = "$col <@ CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_exact_sql(::DatabaseBackend, col, v) = "$col = CAST(? AS JSONB)", Any[JSON.json(json_scalar_tree(v))]
json_has_key_sql(::DatabaseBackend, col, k) = "jsonb_exists($col, ?)", Any[string(k)]
json_has_keys_sql(::DatabaseBackend, col, ks, all_::Bool) =
    "$(all_ ? "jsonb_exists_all" : "jsonb_exists_any")($col, CAST(? AS TEXT[]))", Any[pg_array_literal(string.(ks))]

array_cast(::DatabaseBackend, f::Field) = column_type(backend(), f.related === :string ? :char : f.related, f.max_length) * "[]"
array_op_sql(b::DatabaseBackend, op, col, f::Field, v) = "$col $op CAST(? AS $(array_cast(b, f)))", Any[encode_array(b, v)]
array_len_sql(::DatabaseBackend, col) = "COALESCE(array_length($col, 1), 0)"
array_index_sql(::DatabaseBackend, col, i::Int) = "$col[$(i + 1)]", Any[]

range_type(::DatabaseBackend, kind) = kind === :intrange ? "INT8RANGE" : kind === :daterange ? "DATERANGE" : "TSRANGE"
range_elem_type(b::DatabaseBackend, kind) = column_type(b, range_elem_kind(kind), nothing)
function range_lookup_sql(b::DatabaseBackend, op::String, col, kind, v)
    if v isa ValueRange
        sqlop = Dict("contains" => "@>", "contained_by" => "<@", "overlap" => "&&", "exact" => "=")[op]
        return "$col $sqlop CAST(? AS $(range_type(b, kind)))", Any[encode_range(b, v)]
    end
    op == "contains" || throw(LookupError("range lookup '$op' needs a ValueRange"))
    "$col @> CAST(? AS $(range_elem_type(b, kind)))", Any[v]
end

search_sql(::DatabaseBackend, col, text) = "to_tsvector(COALESCE($col, '')) @@ plainto_tsquery(?)", Any[string(text)]
supports_full_text(::DatabaseBackend) = true

"""
Lookups that depend on the field type (JSON, arrays, ranges, full-text). Returns `nothing`
when the field/lookup pair isn't special.
"""
function special_lookup(c::SQLCompiler, f::Field, col, lookup, @nospecialize(value))
    b = backend()
    k = f.kind
    if k === :geometry
        return spatial_lookup(f, col, lookup, value)
    elseif lookup == "search"
        return search_sql(b, col, value)
    elseif k === :hstore && b isa PostgresBackend
        lookup == "exact" && value !== nothing && return "$col = CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "contains" && return "$col @> CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "contained_by" && return "$col <@ CAST(? AS hstore)", Any[encode_hstore(b, value)]
        lookup == "has_key" && return "exist($col, ?)", Any[string(value)]
        lookup == "has_keys" && return hstore_has_keys_sql(col, value, true)
        lookup == "has_any_keys" && return hstore_has_keys_sql(col, value, false)
    elseif k === :json || k === :hstore
        k === :hstore && value isa AbstractDict && (value = hstore_dict(value))
        lookup == "exact" && value !== nothing && return json_exact_sql(b, col, value)
        lookup == "contains" && return json_contains_sql(b, col, value)
        lookup == "contained_by" && return json_contained_by_sql(b, col, value)
        lookup == "has_key" && return json_has_key_sql(b, col, value)
        lookup == "has_keys" && return json_has_keys_sql(b, col, value, true)
        lookup == "has_any_keys" && return json_has_keys_sql(b, col, value, false)
    elseif k === :array
        lookup == "contains" && return array_op_sql(b, "@>", col, f, value)
        lookup == "contained_by" && return array_op_sql(b, "<@", col, f, value)
        lookup == "overlap" && return array_op_sql(b, "&&", col, f, value)
        lookup == "exact" && value !== nothing && return array_op_sql(b, "=", col, f, value)
    elseif k in RANGE_KINDS
        lookup in ("contains", "contained_by", "overlap") && return range_lookup_sql(b, lookup, col, k, value)
        lookup == "exact" && value !== nothing && return range_lookup_sql(b, "exact", col, k, value)
    end
    nothing
end

"""
Resolve `field__rest...` into a column expression for JSON key paths and array `len`/indexes.
Returns `(sql, params)` or `nothing`.
"""
function transform_column(f::Field, col, rest::Vector{String}, lookup, @nospecialize(value))
    b = backend()
    if f.kind === :hstore && b isa PostgresBackend && !isempty(rest)
        length(rest) == 1 || return nothing
        lookup == "isnull" && return "($col -> ?) IS NULL", Any[rest[1]]
        return "($col -> ?)", Any[rest[1]]
    end
    if (f.kind === :json || f.kind === :hstore) && !isempty(rest)
        lookup == "isnull" && return json_key_isnull_sql(b, col, rest)
        nums = value isa Number && !(value isa Bool) || value isa AbstractVector && !isempty(value) &&
               all(x -> x isa Number && !(x isa Bool), value) || value isa Tuple
        return json_key_sql(b, col, rest, nums; boolean = value isa Bool)
    elseif f.kind === :array && rest == ["len"]
        return array_len_sql(b, col), Any[]
    elseif f.kind === :array && length(rest) == 1 && all(isdigit, rest[1])
        return array_index_sql(b, col, parse(Int, rest[1]))
    end
    nothing
end

# --- full-text search expressions (PostgreSQL) --------------------------------------------------------

"""
    SearchVector(fields...; config=nothing, weight=nothing)

A `tsvector` of text fields for full-text search (PostgreSQL). Combine with `+`.
`filter(annotate(qs; search = SearchVector(:title, :body)); search = SearchQuery("julia web"))`.
"""
struct SearchVector <: Expression
    parts::Vector{Tuple{Vector{Any},Union{Nothing,String},Union{Nothing,Char}}}   # (fields, config, weight)
    SearchVector(parts::Vector{<:Tuple}) = new(parts)
end
SearchVector(fields...; config = nothing, weight = nothing) =
    SearchVector([(Any[ref(x) for x in fields], config === nothing ? nothing : string(config),
                   weight === nothing ? nothing : uppercase(string(weight))[1])])
Base.:+(a::SearchVector, b::SearchVector) = SearchVector(vcat(a.parts, b.parts))

"""
    SearchQuery(text; config=nothing, search_type=:plain)

A `tsquery`. `search_type` is `:plain` (all words), `:phrase`, `:websearch` (quotes, `or`,
`-word`) or `:raw` (tsquery syntax).
"""
struct SearchQuery <: Expression
    text::String
    config::Union{Nothing,String}
    search_type::Symbol
end
SearchQuery(text; config = nothing, search_type = :plain) =
    SearchQuery(string(text), config === nothing ? nothing : string(config), Symbol(search_type))

"`SearchRank(vector, query)`: relevance for ordering (`ts_rank`)."
struct SearchRank <: Expression
    vector::Expression
    query::SearchQuery
end
SearchRank(v, q::SearchQuery) = SearchRank(v isa Expression ? v : SearchVector(v), q)

need_full_text() = supports_full_text(backend()) ||
    throw(ArgumentError("full-text search expressions need PostgreSQL (the __search lookup works everywhere)"))

function compile_expr(c::SQLCompiler, e::SearchVector)
    need_full_text()
    parts, ps = String[], Any[]
    for (fields, config, weight) in e.parts
        cols = [compile_expr(c, x) for x in fields]
        text = join(["COALESCE(CAST($(s) AS TEXT), '')" for (s, _) in cols], " || ' ' || ")
        append!(ps, reduce(vcat, last.(cols); init = Any[]))
        v = config === nothing ? "to_tsvector($text)" : "to_tsvector(CAST($(repr_sql_string(config)) AS regconfig), $text)"
        push!(parts, weight === nothing ? v : "setweight($v, '$weight')")
    end
    "(" * join(parts, " || ") * ")", ps
end
repr_sql_string(s) = "'" * replace(s, "'" => "''") * "'"

function compile_expr(c::SQLCompiler, e::SearchQuery)
    need_full_text()
    fn = Dict(:plain => "plainto_tsquery", :phrase => "phraseto_tsquery", :websearch => "websearch_to_tsquery",
              :raw => "to_tsquery")[e.search_type]
    (e.config === nothing ? "$fn(?)" : "$fn(CAST($(repr_sql_string(e.config)) AS regconfig), ?)"), Any[e.text]
end

function compile_expr(c::SQLCompiler, e::SearchRank)
    v, vps = compile_expr(c, e.vector)
    q, qps = compile_expr(c, e.query)
    "ts_rank($v, $q)", vcat(vps, qps)
end

# --- trigram similarity and unaccent (PostgreSQL: pg_trgm, unaccent) ---------------------------------
#
# Install the extensions in a migration with `TrigramExtension()` / `UnaccentExtension()`.

const TEXT_KINDS = vcat(collect(STRING_KINDS), :citext)

register_lookup((lhs, rhs) -> "$lhs % $rhs", "trigram_similar"; kinds = TEXT_KINDS)
register_lookup((lhs, rhs) -> "$rhs <% $lhs", "trigram_word_similar"; kinds = TEXT_KINDS)
register_lookup((lhs, rhs) -> "$rhs <<% $lhs", "trigram_strict_word_similar"; kinds = TEXT_KINDS)
register_transform(lhs -> "UNACCENT($lhs)", "unaccent"; kinds = TEXT_KINDS)

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
"`UNACCENT(field)`: text without accents (PostgreSQL `unaccent`)."
Unaccent(x) = Func(:unaccent, [ref(x)])
