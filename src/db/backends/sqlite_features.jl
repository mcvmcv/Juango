# --- JSON, arrays, ranges, full-text on SQLite (stored as JSON text) ---------------------------------

# durations are microseconds; datetimes are text in the format Juango writes (2026-01-02T03:04:05.000)
temporal_value_sql(::SQLiteBackend, kind, sql) = sql
alter_pk_sql(::SQLiteBackend, st, table) = String[]          # every integer is INTEGER
datetime_add_sql(::SQLiteBackend, op, a, d) = "strftime('%Y-%m-%dT%H:%M:%f', julianday($a) $op ($d) / 86400000000.0)"
datetime_diff_sql(::SQLiteBackend, ka, a, kb, b) = "CAST(ROUND((julianday($a) - julianday($b)) * 86400000000.0) AS INTEGER)"

sqlite_json_path(keys) = "\$" * join([all(isdigit, k) ? "[$k]" : "." * "\"" * replace(k, "\"" => "\\\"") * "\"" for k in keys])

encode_array(::SQLiteBackend, v, kind = nothing) = JSON.json(json_scalar_tree(collect(v)))
encode_range(::SQLiteBackend, r::ValueRange) =
    JSON.json(Dict("lower" => json_scalar(r.lower), "upper" => json_scalar(r.upper), "bounds" => r.bounds))

json_path_sql(b::SQLiteBackend, col, keys; sortable = false) =
    "($col " * (sortable ? "->>" : "->") * " " * sql_string_literal(b, sqlite_json_path(keys)) * ")"
# (->> gives a number as a number: text, as on the other databases)
json_text_sql(b::SQLiteBackend, col, keys) = "CAST($col ->> " * sql_string_literal(b, sqlite_json_path(keys)) * " AS TEXT)"
json_key_sql(::SQLiteBackend, col, keys, numeric::Bool; boolean = false) = "json_extract($col, ?)", Any[sqlite_json_path(keys)]
json_key_isnull_sql(::SQLiteBackend, col, keys) = "json_type($col, ?) IS NULL", Any[sqlite_json_path(keys)]
json_exact_sql(::SQLiteBackend, col, v) = "json($col) = json(?)", Any[JSON.json(json_scalar_tree(v))]
function json_contains_sql(::SQLiteBackend, col, v)
    v isa AbstractDict || throw(LookupError("on SQLite, JSON contains takes a Dict of plain values"))
    parts, ps = String[], Any[]
    for (k, x) in v
        (x isa AbstractDict || x isa AbstractVector) && throw(LookupError("on SQLite, JSON contains supports only plain values (key $k)"))
        push!(parts, x === nothing ? "json_type($col, ?) = 'null'" : "json_extract($col, ?) = ?")
        push!(ps, sqlite_json_path([string(k)]))
        x === nothing || push!(ps, x)
    end
    isempty(parts) ? ("$col IS NOT NULL", Any[]) : ("(" * join(parts, " AND ") * ")", ps)
end
json_contained_by_sql(::SQLiteBackend, col, v) = throw(LookupError("contained_by on JSON needs PostgreSQL"))
json_has_key_sql(::SQLiteBackend, col, k) = "json_type($col, ?) IS NOT NULL", Any[sqlite_json_path([string(k)])]
function json_has_keys_sql(b::SQLiteBackend, col, ks, all_::Bool)
    parts = [json_has_key_sql(b, col, k) for k in ks]
    isempty(parts) && return (all_ ? sql_true(b) : sql_false(b)), Any[]
    "(" * join(first.(parts), all_ ? " AND " : " OR ") * ")", reduce(vcat, last.(parts))
end

function array_op_sql(b::SQLiteBackend, op, col, f::Field, v)
    p = Any[encode_array(b, v)]
    op == "@>" && return "NOT EXISTS (SELECT 1 FROM json_each(?) AS jv WHERE jv.value NOT IN (SELECT value FROM json_each($col)))", p
    op == "<@" && return "($col IS NOT NULL AND NOT EXISTS (SELECT 1 FROM json_each($col) AS jv WHERE jv.value NOT IN (SELECT value FROM json_each(?))))", p
    op == "&&" && return "EXISTS (SELECT 1 FROM json_each($col) AS ja JOIN json_each(?) AS jb ON ja.value = jb.value)", p
    "json($col) = json(?)", p
end
array_len_sql(::SQLiteBackend, col) = "json_array_length($col)"
array_index_sql(::SQLiteBackend, col, is::Vector{Int}) = "json_extract($col, ?)", Any["\$" * join("[$i]" for i in is)]

# a range's parts in its JSON ({"lower", "upper", "bounds"}; bounds "empty" for the empty range)
function sqlite_range_parts(col)
    bounds = "json_extract($col, '\$.bounds')"
    (lo = "json_extract($col, '\$.lower')", hi = "json_extract($col, '\$.upper')", loinc = "(substr($bounds, 1, 1) = '[')",
     hiinc = "(substr($bounds, 2, 1) = ']')", empty = "($bounds = 'empty')")
end
function range_lookup_sql(b::SQLiteBackend, op::String, col, kind, v)
    sql, ps = range_parts_sql(b, sqlite_range_parts(col), op, col, kind, v)
    "($col IS NOT NULL AND $sql)", ps          # NULL is no range at all, not an unbounded one
end
range_exact_sql(b::SQLiteBackend, col, v) = "json($col) = json(?)", Any[encode_range(b, v)]
range_bound_expr(::SQLiteBackend, col, which::Symbol) = "json_extract($col, '\$.$which')"

function search_sql(b::SQLiteBackend, col, text)
    words = split(lowercase(string(text)))
    isempty(words) && return sql_true(b), Any[]
    "(" * join(fill("LOWER($col) LIKE ? ESCAPE '\\'", length(words)), " AND ") * ")", Any["%" * escape_like(w) * "%" for w in words]
end
supports_full_text(::SQLiteBackend) = false
array_column_type(::SQLiteBackend, of, max_length) = "TEXT"

# an array's slice: its items from a to z - 1, in order (nested arrays and objects kept as JSON, not text)
array_slice_sql(::SQLiteBackend, col, a::Int, z::Int) =
    "(CASE WHEN $col IS NULL THEN NULL ELSE (SELECT json_group_array(CASE WHEN js.type IN ('array', 'object') THEN json(js.value) ELSE js.value END) " *
    "FROM (SELECT value, type FROM json_each($col) WHERE key >= $a AND key < $z ORDER BY key) AS js) END)"

hstore_key_expr(b::SQLiteBackend, col, key) = "json_extract($col, " * sql_string_literal(b, hstore_json_path(key)) * ")"
hstore_array_expr(::SQLiteBackend, col, which::Symbol) =
    "(CASE WHEN $col IS NULL THEN NULL ELSE (SELECT json_group_array($(which === :keys ? "hk.key" : "hk.value")) FROM json_each($col) AS hk) END)"
hstore_has_key_sql(::SQLiteBackend, col, k) = "json_type($col, ?) IS NOT NULL", Any[hstore_json_path(k)]
# every key of map `a` is one of map `b`'s, with the same value (NULL matching NULL)
sqlite_hstore_subset(a, b) = "NOT EXISTS (SELECT 1 FROM json_each($a) AS hj WHERE NOT EXISTS (SELECT 1 FROM json_each($b) AS hp " *
                             "WHERE hp.key = hj.key AND hp.value IS hj.value))"
hstore_contained_by_sql(::SQLiteBackend, col, v) = "($col IS NOT NULL AND $(sqlite_hstore_subset(col, "?")))", Any[JSON.json(hstore_dict(v))]
hstore_contains_sql(::SQLiteBackend, col, v) = "($col IS NOT NULL AND $(sqlite_hstore_subset("?", col)))", Any[JSON.json(hstore_dict(v))]
hstore_exact_sql(b::SQLiteBackend, col, v) =
    (s1 = hstore_contained_by_sql(b, col, v); s2 = hstore_contains_sql(b, col, v); ("(" * s1[1] * " AND " * s2[1] * ")", vcat(s1[2], s2[2])))
