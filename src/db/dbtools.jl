# Database tools: flush, dbshell, inspectdb -------------------------------------------------------------

"The tables Juango manages (models in use, their join tables), without the migration records."
managed_tables() = unique([modelmeta(T).table for T in all_models()
                           if !modelmeta(T).proxy && model_in_use(T) && is_managed(T)])

"""
    flush_sql(; reset_sequences = true) -> Vector{String}

The statements `flush!` runs (`manage.jl sqlflush` prints them): empty every managed table, and
restart the ids where the database allows.
"""
function flush_sql(; reset_sequences = true)
    b = backend()
    tables = [t for t in managed_tables() if table_exists(b, t)]
    isempty(tables) && return String[]
    q(t) = quote_name(b, t)
    b isa PostgresBackend && return ["TRUNCATE " * join(q.(tables), ", ") * (reset_sequences ? " RESTART IDENTITY" : "") * " CASCADE"]
    if b isa MySQLBackend
        return vcat(["SET FOREIGN_KEY_CHECKS = 0"], [reset_sequences ? "TRUNCATE TABLE $(q(t))" : "DELETE FROM $(q(t))" for t in tables],
                    ["SET FOREIGN_KEY_CHECKS = 1"])
    end
    out = ["DELETE FROM $(q(t))" for t in tables]
    if reset_sequences && table_exists(b, "sqlite_sequence")
        push!(out, "DELETE FROM sqlite_sequence WHERE name IN (" * join([sql_string_literal(b, t) for t in tables], ", ") * ")")
    end
    out
end

"""
    sequence_reset_sql(apps = nothing) -> Vector{String}

PostgreSQL: statements that move each table's id sequence past its largest id (after rows were
loaded with explicit ids; `manage.jl sqlsequencereset app`). Other databases keep their counters
right themselves, so there are none.
"""
function sequence_reset_sql(apps = nothing; models = nothing)
    b = backend()
    b isa PostgresBackend || return String[]
    out = String[]
    for T in something(models, all_models())
        m = modelmeta(T)
        (m.proxy || !model_in_use(T) || is_composite(T) || pk_kind(T) === :uuid || natural_pk(T)) && continue
        apps === nothing || m.app in apps || continue
        t = quote_name(b, m.table)
        push!(out, "SELECT setval(pg_get_serial_sequence($(sql_string_literal(b, t)), 'id'), GREATEST(COALESCE(MAX(\"id\"), 1), 1), COALESCE(MAX(\"id\") >= 1, false)) FROM $t")
    end
    out
end

"""
    flush!(; reset_sequences = true) -> Int

Delete every row of every table Juango manages (not the record of applied migrations), then
recreate content types and permissions; returns the number of tables emptied. Ids start
from 1 again where the database allows.
"""
function flush!(; reset_sequences = true)
    b = backend()
    stmts = flush_sql(; reset_sequences = reset_sequences)
    isempty(stmts) && return 0
    if b isa MySQLBackend                                 # one connection, so SET FOREIGN_KEY_CHECKS applies
        atomic() do
            try
                foreach(execute, stmts[1:end-1])
            finally
                execute(stmts[end])                       # SET FOREIGN_KEY_CHECKS = 1
            end
        end
    else
        atomic(() -> foreach(execute, stmts))
    end
    tables = [t for t in managed_tables() if table_exists(b, t)]
    lock(() -> empty!(CT_CACHE), CT_LOCK)
    update_contenttypes!()
    update_permissions!()
    length(tables)
end

"""
    dbshell_cmd() -> Cmd

The command-line client for the current database (`sqlite3`, `psql` or `mysql`), as
`manage.jl dbshell` runs it.
"""
function dbshell_cmd()
    b = backend()
    if b isa PostgresBackend
        `psql $(b.url)`
    elseif b isa MySQLBackend
        p = mysql_params(b.url)
        args = ["-h", p.host, "-P", string(p.port), "-u", p.user]
        isempty(p.password) || push!(args, "--password=$(p.password)")
        isempty(p.db) || push!(args, p.db)
        `mysql $args`
    elseif b isa SQLiteBackend
        `sqlite3 $(b.path)`
    else
        throw(ArgumentError("dbshell doesn't know the client for $(vendor(b))"))
    end
end

# --- inspectdb ------------------------------------------------------------------------------------------

"Tables of the current database (not Juango's migration records), sorted; views too with `include_views`."
function introspect_tables(; include_views::Bool = false)
    b = backend()
    types = include_views ? "('BASE TABLE', 'VIEW')" : "('BASE TABLE')"
    rows = b isa PostgresBackend ?
        execute("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type IN $types") :
        b isa MySQLBackend ?
        execute("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type IN $types") :
        execute("SELECT name FROM sqlite_master WHERE type IN ($(include_views ? "'table', 'view'" : "'table'")) AND name NOT LIKE 'sqlite_%'")
    sort([String(r[:name]) for r in rows if String(r[:name]) != "juango_migrations"])
end

"""
    django_table_names(; only_existing = false) -> Vector{String}

The tables of the installed models Juango manages, join tables too (Django's `introspection.django_table_names`),
sorted; with `only_existing`, only those the database has.
"""
function django_table_names(; only_existing::Bool = false)
    ts = sort(managed_tables())
    only_existing || return ts
    have = Set(introspect_tables())
    [t for t in ts if t in have]
end

"The installed models whose tables are among `tables` (Django's `introspection.installed_models`)."
installed_models(tables) = Set{Any}(T for T in all_models()
                                    if !(T <: AutoThrough) && !modelmeta(T).proxy && model_in_use(T) && modelmeta(T).table in tables)

"A table's primary key column (the first, for a composite key), or `nothing` (Django's `get_primary_key_column`)."
function introspect_primary_key_column(table)
    for c in values(introspect_constraints(table))
        c.primary_key && !isempty(c.columns) && return c.columns[1]
    end
    nothing
end

"A table's foreign keys: column => `(referenced column, referenced table)` (Django's `get_relations`)."
function introspect_relations(table)
    Dict(c.columns[1] => (c.foreign_key[2], c.foreign_key[1]) for c in values(introspect_constraints(table))
         if c.foreign_key !== nothing && length(c.columns) == 1)
end

"""
    introspect_comments(table) -> (table = comment or nothing, columns = Dict(column => comment))

The table's and its columns' comments (`Meta(db_table_comment)`, `db_comment`) in the database. SQLite keeps none.
"""
function introspect_comments(table)
    b = backend()
    cols = Dict{String,String}()
    tc = nothing
    if b isa PostgresBackend
        for r in execute("SELECT a.attname AS c, col_description(a.attrelid, a.attnum) AS d FROM pg_attribute a " *
                         "JOIN pg_class cl ON cl.oid = a.attrelid JOIN pg_namespace n ON n.oid = cl.relnamespace " *
                         "WHERE cl.relname = ? AND n.nspname = current_schema() AND a.attnum > 0 AND NOT a.attisdropped", [table])
            r[:d] === nothing || r[:d] === missing || (cols[String(r[:c])] = String(r[:d]))
        end
        rows = execute("SELECT obj_description(cl.oid, 'pg_class') AS d FROM pg_class cl JOIN pg_namespace n ON n.oid = cl.relnamespace " *
                       "WHERE cl.relname = ? AND n.nspname = current_schema()", [table])
        isempty(rows) || rows[1][:d] === nothing || rows[1][:d] === missing || (tc = String(rows[1][:d]))
    elseif b isa MySQLBackend
        for r in execute("SELECT column_name AS c, column_comment AS d FROM information_schema.columns " *
                         "WHERE table_schema = DATABASE() AND table_name = ?", [table])
            isempty(String(r[:d])) || (cols[String(r[:c])] = String(r[:d]))
        end
        rows = execute("SELECT table_comment AS d FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ?", [table])
        isempty(rows) || isempty(String(rows[1][:d])) || (tc = String(rows[1][:d]))
    end
    (table = tc, columns = cols)
end

"Columns of a table: `(name, type, max_length, null, pk, precision, scale)`."
function introspect_columns(table)
    b = backend()
    if b isa SQLiteBackend
        return [(name = String(r[:name]), type = lowercase(String(r[:type])), max_length = nothing,
                 null = r[:notnull] == 0 && r[:pk] == 0, pk = r[:pk] != 0, precision = nothing, scale = nothing)   # (a key is never NULL)
                for r in execute("PRAGMA table_info($(quote_name(b, table)))")]
    end
    schema = b isa PostgresBackend ? "current_schema()" : "DATABASE()"
    pks = Set(String(r[:c]) for r in execute(
        "SELECT kcu.column_name AS c FROM information_schema.table_constraints tc JOIN information_schema.key_column_usage kcu " *
        "ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema AND tc.table_name = kcu.table_name " *
        "WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_schema = $schema AND tc.table_name = ?", [table]))
    rows = execute("SELECT column_name AS c, data_type AS t, character_maximum_length AS l, is_nullable AS n, " *
                   "numeric_precision AS np, numeric_scale AS ns" *
                   (b isa MySQLBackend ? ", column_type AS ct" : "") *
                   " FROM information_schema.columns WHERE table_schema = $schema AND table_name = ? ORDER BY ordinal_position", [table])
    [(name = String(r[:c]), type = lowercase(String(b isa MySQLBackend ? r[:ct] : r[:t])),
      max_length = r[:l] === nothing ? nothing : Int(r[:l]), null = String(r[:n]) == "YES", pk = String(r[:c]) in pks,
      precision = r[:np] === nothing ? nothing : Int(r[:np]), scale = r[:ns] === nothing ? nothing : Int(r[:ns])) for r in rows]
end

"Foreign keys of a table: column => referenced table."
function introspect_foreign_keys(table)
    b = backend()
    rows = if b isa SQLiteBackend
        [(c = String(r[:from]), t = String(r[:table])) for r in execute("PRAGMA foreign_key_list($(quote_name(b, table)))")]
    elseif b isa PostgresBackend
        [(c = String(r[:c]), t = String(r[:t])) for r in execute(
            "SELECT kcu.column_name AS c, ccu.table_name AS t FROM information_schema.table_constraints tc " *
            "JOIN information_schema.key_column_usage kcu ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema " *
            "JOIN information_schema.constraint_column_usage ccu ON tc.constraint_name = ccu.constraint_name AND tc.table_schema = ccu.table_schema " *
            "WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_schema = current_schema() AND tc.table_name = ?", [table])]
    else
        [(c = String(r[:c]), t = String(r[:t])) for r in execute(
            "SELECT column_name AS c, referenced_table_name AS t FROM information_schema.key_column_usage " *
            "WHERE table_schema = DATABASE() AND table_name = ? AND referenced_table_name IS NOT NULL", [table])]
    end
    Dict(r.c => r.t for r in rows)
end

"""
    introspect_constraints(table) -> Dict{String,NamedTuple}

A table's constraints and indexes in the database, by name (Django's
`connection.introspection.get_constraints`): each has `columns` (column names; an expression is
`""`), `primary_key`, `unique`, `foreign_key` (`(table, column)` or `nothing`), `check`, `index`
and `type` (the index method as Django names it: `"idx"` for a B-tree index, else e.g. "gin", "hash"; or `nothing`). A primary key with no name of its own
(SQLite) is `"__primary__"`; SQLite's unnamed foreign keys are `"fk_<n>"`.
"""
index_type(method) = (m = lowercase(method); m == "btree" ? "idx" : m)      # (Django's Index.suffix for a B-tree)
function introspect_constraints(table)
    b = backend()
    out = Dict{String,NamedTuple{(:columns, :primary_key, :unique, :foreign_key, :check, :index, :type),
                                 Tuple{Vector{String},Bool,Bool,Union{Nothing,Tuple{String,String}},Bool,Bool,Union{Nothing,String}}}}()
    entry(cols; pk = false, unique = false, fk = nothing, check = false, index = false, type = nothing) =
        (columns = collect(String, cols), primary_key = pk, unique = unique, foreign_key = fk, check = check, index = index, type = type)
    splitcols(x) = x === nothing || x === missing ? String[] : String.(split(String(x), ','; keepempty = true))
    if b isa SQLiteBackend
        q = quote_name(b, table)
        pk = [String(r[:name]) for r in sort(execute("PRAGMA table_info($q)"); by = r -> r[:pk]) if r[:pk] != 0]
        isempty(pk) || (out["__primary__"] = entry(pk; pk = true, unique = true))
        for r in execute("PRAGMA index_list($q)")
            name = String(r[:name])
            cols = [r2[:name] === nothing || r2[:name] === missing ? "" : String(r2[:name]) for r2 in execute("PRAGMA index_info($(quote_name(b, name)))")]
            if String(r[:origin]) == "pk"
                out["__primary__"] = entry(cols; pk = true, unique = true); continue
            end
            out[name] = entry(cols; unique = r[:unique] != 0, index = true, type = "idx")
        end
        for r in execute("PRAGMA foreign_key_list($q)")
            name = "fk_$(r[:id])"
            prev = get(out, name, nothing)
            cols = prev === nothing ? String[String(r[:from])] : [prev.columns; String(r[:from])]
            out[name] = entry(cols; fk = (String(r[:table]), r[:to] === nothing || r[:to] === missing ? "id" : String(r[:to])))
        end
        # named CHECK and UNIQUE constraints, from the CREATE TABLE statement
        rows = execute("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", [table])
        if !isempty(rows) && rows[1][:sql] !== nothing
            sql = String(rows[1][:sql])
            for m in eachmatch(r"CONSTRAINT\s+[\"`]?(\w+)[\"`]?\s+(CHECK|UNIQUE)\s*\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)"i, sql)
                if uppercase(m[2]) == "CHECK"
                    out[m[1]] = entry(String[]; check = true)
                else
                    out[m[1]] = entry([strip(c, ['"', '`', ' ']) for c in split(m[3], ',')]; unique = true)
                end
            end
        end
    elseif b isa PostgresBackend
        for r in execute("SELECT con.conname AS name, con.contype AS type, ft.relname AS ftable, " *
                         "(SELECT string_agg(a.attname, ',' ORDER BY u.ord) FROM unnest(con.conkey) WITH ORDINALITY u(attnum, ord) " *
                         " JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = u.attnum) AS cols, " *
                         "(SELECT string_agg(a.attname, ',' ORDER BY u.ord) FROM unnest(con.confkey) WITH ORDINALITY u(attnum, ord) " *
                         " JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = u.attnum) AS fcols " *
                         "FROM pg_constraint con JOIN pg_class cl ON cl.oid = con.conrelid JOIN pg_namespace n ON n.oid = cl.relnamespace " *
                         "LEFT JOIN pg_class ft ON ft.oid = con.confrelid WHERE cl.relname = ? AND n.nspname = current_schema()", [table])
            t = String(r[:type])
            out[String(r[:name])] = entry(splitcols(r[:cols]); pk = t == "p", unique = t in ("p", "u"), check = t == "c",
                                          fk = t == "f" ? (String(r[:ftable]), first(splitcols(r[:fcols]))) : nothing)
        end
        for r in execute("SELECT ic.relname AS name, ix.indisunique AS uniq, ix.indisprimary AS pk, am.amname AS method, " *
                         "(SELECT string_agg(COALESCE(a.attname, ''), ',' ORDER BY u.ord) FROM unnest(ix.indkey::int2[]) WITH ORDINALITY u(attnum, ord) " *
                         " LEFT JOIN pg_attribute a ON a.attrelid = ix.indrelid AND a.attnum = u.attnum) AS cols " *
                         "FROM pg_index ix JOIN pg_class ic ON ic.oid = ix.indexrelid JOIN pg_class t ON t.oid = ix.indrelid " *
                         "JOIN pg_namespace n ON n.oid = t.relnamespace JOIN pg_am am ON am.oid = ic.relam " *
                         "WHERE t.relname = ? AND n.nspname = current_schema()", [table])
            name = String(r[:name])
            prev = get(out, name, nothing)
            if prev === nothing
                out[name] = entry(splitcols(r[:cols]); pk = r[:pk] == true, unique = r[:uniq] == true, index = true, type = index_type(String(r[:method])))
            else                                       # the index behind a primary key or unique constraint
                out[name] = merge(prev, (index = true, type = index_type(String(r[:method]))))
            end
        end
    else
        for r in execute("SELECT tc.constraint_name AS name, tc.constraint_type AS type, kcu.column_name AS col, " *
                         "kcu.referenced_table_name AS ftable, kcu.referenced_column_name AS fcol " *
                         "FROM information_schema.table_constraints tc LEFT JOIN information_schema.key_column_usage kcu " *
                         "ON kcu.constraint_name = tc.constraint_name AND kcu.table_schema = tc.table_schema AND kcu.table_name = tc.table_name " *
                         "WHERE tc.table_schema = DATABASE() AND tc.table_name = ? ORDER BY tc.constraint_name, kcu.ordinal_position", [table])
            name, t = String(r[:name]), uppercase(String(r[:type]))
            prev = get(out, name, nothing)
            col = r[:col] === nothing || r[:col] === missing ? String[] : String[String(r[:col])]
            cols = prev === nothing ? col : [prev.columns; col]
            out[name] = entry(cols; pk = t == "PRIMARY KEY", unique = t in ("PRIMARY KEY", "UNIQUE"), check = t == "CHECK",
                              fk = t == "FOREIGN KEY" ? (String(r[:ftable]), String(r[:fcol])) : nothing)
        end
        keyed = Set(keys(out))                         # constraints whose columns are known already
        for r in execute("SELECT index_name AS name, non_unique AS nu, column_name AS col, index_type AS method " *
                         "FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = ? " *
                         "ORDER BY index_name, seq_in_index", [table])
            name = String(r[:name])
            col = r[:col] === nothing || r[:col] === missing ? "" : String(r[:col])
            prev = get(out, name, nothing)
            if name in keyed                           # the index behind a key constraint
                out[name] = merge(prev, (index = true, type = index_type(String(r[:method]))))
            elseif prev === nothing
                out[name] = entry([col]; pk = name == "PRIMARY", unique = r[:nu] == 0, index = true, type = index_type(String(r[:method])))
            else
                out[name] = merge(prev, (columns = [prev.columns; col],))
            end
        end
    end
    out
end

model_name_for(table) = join(uppercasefirst.(split(replace(table, r"[^A-Za-z0-9]+" => "_"), '_'; keepempty = false)))

"The field definition for an introspected column (and a note when the type is a guess)."
function field_for(col)
    t = col.type
    m = match(r"^(?:character varying|varchar|nvarchar|char|character)\s*(?:\((\d+)\))?", t)
    m !== nothing && return "CharField(max_length = $(something(col.max_length, m[1] === nothing ? nothing : parse(Int, m[1]), 255)))", ""
    occursin(r"^tinyint\(1\)|^bool", t) && return "BooleanField()", ""
    t == "interval" && return "DurationField()", ""               # before "int"
    if occursin(r"int|serial", t)
        pos = occursin("unsigned", t)                       # MySQL
        occursin(r"^(smallint|int2|smallserial|tinyint|mediumint)", t) && return (pos ? "PositiveSmallIntegerField()" : "SmallIntegerField()"), ""
        occursin(r"^(bigint|int8|bigserial)", t) && return (pos ? "PositiveBigIntegerField()" : "BigIntegerField()"), ""
        return (pos ? "PositiveIntegerField()" : "IntegerField()"), ""
    end
    occursin(r"^(text|clob|longtext|mediumtext|tinytext|citext)", t) && return "TextField()", ""
    if occursin(r"^(numeric|decimal)", t)
        m = match(r"\((\d+)\s*,\s*(\d+)\)", t)          # SQLite and MySQL spell it out in the type
        p, s = m !== nothing ? (parse(Int, m[1]), parse(Int, m[2])) : (col.precision, col.scale)
        p === nothing ? (return "DecimalField(max_digits = 30, decimal_places = 10)", "  # TODO: max_digits and decimal_places are a guess") :
                        (return "DecimalField(max_digits = $p, decimal_places = $(something(s, 0)))", "")
    end
    occursin(r"real|double|float|numeric|decimal", t) && return "FloatField()", ""
    occursin(r"^timestamp|^datetime", t) && return "DateTimeField()", ""
    t == "date" && return "DateField()", ""
    occursin(r"^time(\(\d\))?( without time zone)?$", t) && return "TimeField()", ""
    occursin(r"^json", t) && return "JSONField()", ""
    t == "uuid" && return "UUIDField()", ""
    occursin(r"^(bytea|blob|longblob|mediumblob|tinyblob|binary|varbinary)", t) && return "BinaryField()", ""
    t == "inet" && return "GenericIPAddressField()", ""
    "TextField()", "  # TODO: check the type (was $(t))"
end

const JULIA_KEYWORDS = Set(["baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end", "export",
    "false", "finally", "for", "function", "global", "if", "import", "let", "local", "macro", "module", "quote", "return",
    "struct", "true", "try", "using", "while", "public", "abstract", "primitive", "mutable", "type"])

"""
    normalize_col_name(col, used, is_relation) -> (name, db_column or nothing, notes)

A column's field name, as Django's inspectdb makes it: lowercased; a key's `_id` dropped (else its column is
kept as db_column); characters that can't be in a name, runs of `_`, a leading or trailing `_`, a Julia keyword
and a leading digit fixed; a name already used numbered. When the name isn't the column, `db_column` keeps it.
"""
function normalize_col_name(col::AbstractString, used, is_relation::Bool)
    notes = String[]
    dbcol = nothing
    name = lowercase(col)
    name != col && push!(notes, "Field name made lowercase.")
    if is_relation
        endswith(name, "_id") ? (name = name[1:end-3]) : (dbcol = String(col))
    end
    n2 = replace(name, r"\W" => "_")
    n2 != name && push!(notes, "Field renamed to remove unsuitable characters.")
    name = n2
    if occursin("__", name)
        while occursin("__", name)
            name = replace(name, "__" => "_")
        end
        occursin("__", lowercase(col)) && push!(notes, "Field renamed because it contained more than one '_' in a row.")
    end
    startswith(name, "_") && (name = "field" * name; push!(notes, "Field renamed because it started with '_'."))
    endswith(name, "_") && (name = name * "field"; push!(notes, "Field renamed because it ended with '_'."))
    (name in JULIA_KEYWORDS || name in ("pk", "objects")) &&
        (name *= "_field"; push!(notes, "Field renamed because it was a Julia reserved word."))
    isdigit(first(name)) && (name = "number_" * name; push!(notes, "Field renamed because it wasn't a valid Julia identifier."))
    if name in used
        k = 0
        while "$(name)_$k" in used
            k += 1
        end
        name = "$(name)_$k"; push!(notes, "Field renamed because of name conflict.")
    end
    col != name && !isempty(notes) && (dbcol = String(col))
    name, dbcol, notes
end

"""
    inspectdb(tables = nothing; app_label = "project", table_name_filter = nothing, include_views = false) -> String

Write `@model` definitions for existing tables (all of them, or the ones named; `table_name_filter = t -> Bool`
picks them, `include_views` adds views), for working with a database Juango didn't create. They get
`Meta(managed = false)`, so migrations leave the tables alone; review the generated fields before use. As
Django's: field names are made valid (the column kept as `db_column`), a foreign key that's unique or the
primary key is a OneToOneField, one to a column other than the key gets `to_field`, one to its own table is
`:self`, unique columns get `unique = true` and unique sets of columns `unique_together`.
"""
function inspectdb(tables = nothing; app_label = "project", table_name_filter = nothing, include_views::Bool = false)
    known = introspect_tables(; include_views)
    names = tables === nothing ? (table_name_filter === nothing ? known : filter(table_name_filter, known)) : collect(String, tables)
    io = IOBuffer()
    println(io, "# Generated by `manage.jl inspectdb`. Check the field types, then remove `managed = false`")
    println(io, "# from models whose tables Juango should create and migrate.\nusing Juango\n")
    for t in names
        t in known || throw(ArgumentError("no table '$t' in the database"))
        cols = introspect_columns(t)
        rels = introspect_relations(t)
        cons = introspect_constraints(t)
        pkcols = [c.name for c in cols if c.pk]
        unique_cols = Set(only(c.columns) for c in values(cons) if c.unique && !c.primary_key && length(c.columns) == 1)
        println(io, "@model struct ", model_name_for(t))
        used = Set{String}()
        names_of = Dict{String,String}()
        for c in cols
            is_rel = haskey(rels, c.name)
            name, dbcol, notes = normalize_col_name(c.name, used, is_rel)
            push!(used, name); names_of[c.name] = name
            (c.pk && c.name == "id" && !is_rel) && continue
            opts = String[]
            dbcol === nothing || push!(opts, "db_column = $(repr(dbcol))")
            if is_rel
                refcol, reftable = rels[c.name]
                target = reftable == t ? ":self" : ":" * model_name_for(reftable)
                refpk = introspect_primary_key_column(reftable)
                kind = c.pk || c.name in unique_cols ? "OneToOneField" : "ForeignKey"
                c.pk && push!(opts, "primary_key = true")
                refpk === nothing || refcol == refpk || push!(opts, "to_field = :$refcol")
                c.null && push!(opts, "blank = true", "null = true")
                println(io, "    ", name, " = ", kind, "(", target, "; on_delete = :DO_NOTHING",
                        isempty(opts) ? "" : ", " * join(opts, ", "), ")", isempty(notes) ? "" : "  # " * join(notes, " "))
            else
                def, note = field_for(c)
                c.pk && length(pkcols) == 1 && push!(opts, "primary_key = true")
                c.name in unique_cols && push!(opts, "unique = true")
                c.null && push!(opts, "blank = true", "null = true")
                if !isempty(opts)
                    def = endswith(def, "()") ? def[1:end-1] * join(opts, ", ") * ")" : def[1:end-1] * ", " * join(opts, ", ") * ")"
                end
                allnotes = vcat(notes, isempty(note) ? String[] : [strip(lstrip(strip(note), '#'))])
                println(io, "    ", name, " = ", def, isempty(allnotes) ? "" : "  # " * join(allnotes, " "))
            end
        end
        meta = "table = $(repr(t)), app_label = $(repr(app_label)), managed = false"
        ut = [c.columns for c in values(cons) if c.unique && !c.primary_key && length(c.columns) > 1 && all(x -> haskey(names_of, x), c.columns)]
        isempty(ut) || (meta *= ", unique_together = [" * join(["(" * join([":" * names_of[x] for x in u], ", ") * ")" for u in sort(ut)], ", ") * "]")
        if pkcols != ["id"] && length(pkcols) != 1
            meta *= isempty(pkcols) ? "  # TODO: the table has no primary key; Juango needs an id column" :
                    ", pk = CompositePrimaryKey(" * join([":" * names_of[x] for x in pkcols], ", ") * ")"
        end
        println(io, "    Meta(", meta, ")")
        println(io, "end\n")
    end
    String(take!(io))
end
