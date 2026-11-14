# --- JSON, arrays, ranges, full-text on SQLite (stored as JSON text) ---------------------------------

# durations are microseconds; datetimes are text in the format Juango writes (2026-01-02T03:04:05.000)
temporal_value_sql(::SQLiteBackend, kind, sql) = sql
alter_pk_sql(::SQLiteBackend, st, table) = String[]          # every integer is INTEGER
datetime_add_sql(::SQLiteBackend, op, a, d) = "strftime('%Y-%m-%dT%H:%M:%f', julianday($a) $op ($d) / 86400000000.0)"
datetime_diff_sql(::SQLiteBackend, ka, a, kb, b) = "CAST(ROUND((julianday($a) - julianday($b)) * 86400000000.0) AS INTEGER)"

sqlite_json_path(keys) = "\$" * join([all(isdigit, k) ? "[$k]" : "." * "\"" * replace(k, "\"" => "\\\"") * "\"" for k in keys])

encode_array(::SQLiteBackend, v) = JSON.json(json_scalar_tree(collect(v)))
encode_range(::SQLiteBackend, r::ValueRange) =
    JSON.json(Dict("lower" => json_scalar(r.lower), "upper" => json_scalar(r.upper), "bounds" => r.bounds))

json_path_sql(b::SQLiteBackend, col, keys; sortable = false) =
    "($col " * (sortable ? "->>" : "->") * " " * sql_string_literal(b, sqlite_json_path(keys)) * ")"
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
array_len_sql(::SQLiteBackend, col) = "COALESCE(json_array_length($col), 0)"
array_index_sql(::SQLiteBackend, col, i::Int) = "json_extract($col, ?)", Any["\$[$i]"]

function range_lookup_sql(b::SQLiteBackend, op::String, col, kind, v)
    sql, ps = sqlite_range_condition(b, op, col, v)
    "($col IS NOT NULL AND $sql)", ps          # NULL is no range at all, not an unbounded one
end
function sqlite_range_condition(b::SQLiteBackend, op::String, col, v)
    lo, hi = "json_extract($col, '\$.lower')", "json_extract($col, '\$.upper')"
    s(x) = json_scalar(x)
    if !(v isa ValueRange)
        op == "contains" || throw(LookupError("range lookup '$op' needs a ValueRange"))
        return "(($lo IS NULL OR $lo <= ?) AND ($hi IS NULL OR ? < $hi))", Any[s(v), s(v)]
    end
    l, u = s(v.lower), s(v.upper)
    op == "contains" && return "(($lo IS NULL OR (? IS NOT NULL AND $lo <= ?)) AND ($hi IS NULL OR (? IS NOT NULL AND ? <= $hi)))", Any[l, l, u, u]
    op == "contained_by" && return "((? IS NULL OR ($lo IS NOT NULL AND ? <= $lo)) AND (? IS NULL OR ($hi IS NOT NULL AND $hi <= ?)))", Any[l, l, u, u]
    op == "overlap" && return "((? IS NULL OR $lo IS NULL OR $lo < ?) AND (? IS NULL OR $hi IS NULL OR ? < $hi))", Any[u, u, l, l]
    "json($col) = json(?)", Any[encode_range(b, v)]
end

function search_sql(b::SQLiteBackend, col, text)
    words = split(lowercase(string(text)))
    isempty(words) && return sql_true(b), Any[]
    "(" * join(fill("LOWER($col) LIKE ? ESCAPE '\\'", length(words)), " AND ") * ")", Any["%" * escape_like(w) * "%" for w in words]
end
supports_full_text(::SQLiteBackend) = false
array_column_type(::SQLiteBackend, of, max_length) = "TEXT"
