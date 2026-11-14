# --- JSON, arrays, ranges and full-text on MySQL/MariaDB (JSON columns) --------------------------------

# durations are microseconds
temporal_value_sql(::MySQLBackend, kind, sql) = sql
# MySQL/MariaDB won't change a column that a foreign key references, so the foreign keys
# pointing at the table are dropped first and added again afterwards.
function alter_pk_sql(b::MySQLBackend, st, table)
    t = st[table]
    ty = column_type(b, auto_pk_int(t.pk), nothing)
    q = s -> quote_name(b, s)
    refs = [(x, c) for x in values(st) for c in x.columns
            if c.kind === :fk && c.references !== nothing && ref_table(c.references) == table]
    children = [x for x in values(st) if x.parent == table]
    drops = String["ALTER TABLE $(q(x.name)) DROP FOREIGN KEY $(q(n))" for (x, c) in refs for n in foreign_key_names(b, x.name, c.name)]
    append!(drops, ["ALTER TABLE $(q(x.name)) DROP FOREIGN KEY $(q(n))" for x in children for n in foreign_key_names(b, x.name, "id")])
    stmts = vcat(drops, ["ALTER TABLE $(q(table)) MODIFY $(q("id")) $ty NOT NULL" * (t.parent === nothing ? " AUTO_INCREMENT" : "")])
    append!(stmts, ["ALTER TABLE $(q(x.name)) MODIFY $(q("id")) $ty NOT NULL" for x in children])
    append!(stmts, ["ALTER TABLE $(q(x.name)) MODIFY " * column_sql(b, c; inline_fk = false) for (x, c) in refs])
    append!(stmts, [s for (x, c) in refs for s in fk_sql(b, x.name, c)])
    append!(stmts, [foreign_key_sql(b, x.name, "id", table) for x in children])
    stmts
end
datetime_add_sql(::MySQLBackend, op, a, d) = (op == "+" ? "DATE_ADD" : "DATE_SUB") * "($a, INTERVAL ($d) MICROSECOND)"
datetime_diff_sql(::MySQLBackend, ka, a, kb, b) = "TIMESTAMPDIFF(MICROSECOND, $b, $a)"

encode_array(::MySQLBackend, v) = JSON.json(json_scalar_tree(collect(v)))
encode_range(::MySQLBackend, r::ValueRange) =
    JSON.json(Dict("lower" => json_scalar(r.lower), "upper" => json_scalar(r.upper), "bounds" => r.bounds))

mysql_jtext(col, path_ph = "?") = "JSON_UNQUOTE(JSON_EXTRACT($col, $path_ph))"
json_path_sql(::MySQLBackend, col, keys; sortable = false) = "JSON_EXTRACT($col, " * sql_string_literal(sqlite_json_path(keys)) * ")"
# MariaDB keeps JSON as text, so a plain JSON_EXTRACT sorts "10" before "2": by the number first, then the text
function json_order_sql(b::MySQLBackend, col, keys, desc::Bool)
    x = "JSON_UNQUOTE(" * json_path_sql(b, col, keys) * ")"
    d = desc ? " DESC" : " ASC"
    "CAST($x AS DOUBLE)$d, $x$d"
end
function json_key_sql(::MySQLBackend, col, keys, numeric::Bool; boolean = false)
    p = Any[sqlite_json_path(keys)]
    boolean && return "($(mysql_jtext(col)) = 'true')", p      # JSON true/false compared with 1/0
    numeric ? ("JSON_EXTRACT($col, ?)", p) : (mysql_jtext(col), p)
end
json_key_isnull_sql(::MySQLBackend, col, keys) = "JSON_CONTAINS_PATH($col, 'one', ?) = 0", Any[sqlite_json_path(keys)]
mysql_json_param(v) = JSON.json(json_scalar_tree(v))
json_exact_sql(::MySQLBackend, col, v) =
    "(JSON_CONTAINS($col, ?) AND JSON_CONTAINS(?, $col))", Any[mysql_json_param(v), mysql_json_param(v)]
json_contains_sql(::MySQLBackend, col, v) = "JSON_CONTAINS($col, ?)", Any[mysql_json_param(v)]
json_contained_by_sql(::MySQLBackend, col, v) = "JSON_CONTAINS(?, $col)", Any[mysql_json_param(v)]
json_has_key_sql(::MySQLBackend, col, k) = "JSON_CONTAINS_PATH($col, 'one', ?)", Any[sqlite_json_path([string(k)])]
function json_has_keys_sql(b::MySQLBackend, col, ks, all_::Bool)
    isempty(ks) && return (all_ ? sql_true(b) : sql_false(b)), Any[]
    "JSON_CONTAINS_PATH($col, '$(all_ ? "all" : "one")', $(join(fill("?", length(ks)), ", ")))",
        Any[sqlite_json_path([string(k)]) for k in ks]
end

function array_op_sql(b::MySQLBackend, op, col, f::Field, v)
    p = encode_array(b, v)
    op == "@>" && return "JSON_CONTAINS($col, ?)", Any[p]
    op == "<@" && return "JSON_CONTAINS(?, $col)", Any[p]
    op == "&&" && return "JSON_OVERLAPS($col, ?)", Any[p]
    "(JSON_CONTAINS($col, ?) AND JSON_CONTAINS(?, $col) AND JSON_LENGTH($col) = JSON_LENGTH(?))", Any[p, p, p]
end
array_len_sql(::MySQLBackend, col) = "COALESCE(JSON_LENGTH($col), 0)"
array_index_sql(::MySQLBackend, col, i::Int) = mysql_jtext(col), Any["\$[$i]"]

function range_lookup_sql(b::MySQLBackend, op::String, col, kind, v)
    bound(k) = kind === :intrange ? "CAST(NULLIF($(mysql_jtext(col, "'\$.$k'")), 'null') AS SIGNED)" :
                                    "NULLIF($(mysql_jtext(col, "'\$.$k'")), 'null')"
    lo, hi = bound("lower"), bound("upper")
    s(x) = json_scalar(x)
    sql, ps = if !(v isa ValueRange)
        op == "contains" || throw(LookupError("range lookup '$op' needs a ValueRange"))
        "(($lo IS NULL OR $lo <= ?) AND ($hi IS NULL OR ? < $hi))", Any[s(v), s(v)]
    else
        l, u = s(v.lower), s(v.upper)
        op == "contains" ? ("(($lo IS NULL OR (? IS NOT NULL AND $lo <= ?)) AND ($hi IS NULL OR (? IS NOT NULL AND ? <= $hi)))", Any[l, l, u, u]) :
        op == "contained_by" ? ("((? IS NULL OR ($lo IS NOT NULL AND ? <= $lo)) AND (? IS NULL OR ($hi IS NOT NULL AND $hi <= ?)))", Any[l, l, u, u]) :
        op == "overlap" ? ("((? IS NULL OR $lo IS NULL OR $lo < ?) AND (? IS NULL OR $hi IS NULL OR ? < $hi))", Any[u, u, l, l]) :
        ("(JSON_CONTAINS($col, ?) AND JSON_CONTAINS(?, $col))", Any[encode_range(b, v), encode_range(b, v)])
    end
    "($col IS NOT NULL AND $sql)", ps
end

function search_sql(b::MySQLBackend, col, text)
    words = split(lowercase(string(text)))
    isempty(words) && return sql_true(b), Any[]
    "(" * join(fill("LOWER($col) LIKE ? ESCAPE '\\'", length(words)), " AND ") * ")", Any["%" * escape_like(w) * "%" for w in words]
end

# --- schema changes ---

# Text columns can only be indexed by a prefix.
index_column(b::MySQLBackend, c::Column) =
    quote_name(b, c.name) * ((c.kind in (:string, :citext) && c.max_length === nothing) ? "(191)" : "")
# MySQL won't drop an index a foreign key needs, so rename in place.
rename_index_stmts(b::MySQLBackend, table, oldname, newname, create) =
    oldname == newname ? String[] : ["ALTER TABLE $(quote_name(b, table)) RENAME INDEX $(quote_name(b, oldname)) TO $(quote_name(b, newname))"]
drop_index_stmt(b::MySQLBackend, table, name) = "DROP INDEX IF EXISTS $(quote_name(b, name)) ON $(quote_name(b, table))"

# ALTER: MODIFY COLUMN restates the whole definition; foreign keys must go before their column changes or goes.
function alter_column_sql(b::MySQLBackend, old::Table, new::Table, name, deferred::Vector{String})
    c0, c1 = getcolumn(old, name), getcolumn(new, name)
    t = quote_name(b, new.name)
    stmts = ["ALTER TABLE $t DROP FOREIGN KEY $(quote_name(b, fk))" for fk in foreign_key_names(b, new.name, name)
             if c0.references != c1.references || column_type_for(b, c0) != column_type_for(b, c1)]
    reindex = (c0.unique, c0.index) != (c1.unique, c1.index) || column_type_for(b, c0) != column_type_for(b, c1)
    reindex && append!(stmts, drop_index_sql(b, old.name, c0))
    if c0.null && !c1.null && (bf = backfill_value(c1)) !== nothing
        push!(stmts, "UPDATE $t SET $(quote_name(b, name)) = $(lit(b, bf)) WHERE $(quote_name(b, name)) IS NULL")
    end
    push!(stmts, "ALTER TABLE $t MODIFY COLUMN " * column_sql(b, c1; inline_fk = false))
    reindex && append!(stmts, index_sql(b, new.name, c1; if_not_exists = false))
    if c1.references !== nothing && (c0.references != c1.references || column_type_for(b, c0) != column_type_for(b, c1))
        append!(deferred, fk_sql(b, new.name, c1))
    end
    stmts
end
function drop_column_sql(b::MySQLBackend, old::Table, new::Table, name)
    t = quote_name(b, old.name)
    vcat(["ALTER TABLE $t DROP FOREIGN KEY $(quote_name(b, fk))" for fk in foreign_key_names(b, old.name, name)],
         ["ALTER TABLE $t DROP COLUMN $(quote_name(b, name))"])
end

