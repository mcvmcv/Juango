# Database tools: flush, dbshell, inspectdb -------------------------------------------------------------

"The tables Juango manages (models in use, their join tables), without the migration records."
managed_tables() = unique([modelmeta(T).table for T in all_models()
                           if !modelmeta(T).proxy && model_in_use(T) && get(modelmeta(T).extra, :managed, true) !== false])

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

"Tables of the current database (not Juango's migration records)."
function introspect_tables()
    b = backend()
    rows = b isa PostgresBackend ?
        execute("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'") :
        b isa MySQLBackend ?
        execute("SELECT table_name AS name FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'") :
        execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")
    sort([String(r[:name]) for r in rows if String(r[:name]) != "juango_migrations"])
end

"Columns of a table: `(name, type, max_length, null, pk, precision, scale)`."
function introspect_columns(table)
    b = backend()
    if b isa SQLiteBackend
        return [(name = String(r[:name]), type = lowercase(String(r[:type])), max_length = nothing,
                 null = r[:notnull] == 0, pk = r[:pk] != 0, precision = nothing, scale = nothing)
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
and `type` (the index method, e.g. "btree", or `nothing`). A primary key with no name of its own
(SQLite) is `"__primary__"`; SQLite's unnamed foreign keys are `"fk_<n>"`.
"""
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
            out[name] = entry(cols; unique = r[:unique] != 0, index = true, type = "btree")
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
                out[name] = entry(splitcols(r[:cols]); pk = r[:pk] == true, unique = r[:uniq] == true, index = true, type = String(r[:method]))
            else                                       # the index behind a primary key or unique constraint
                out[name] = merge(prev, (index = true, type = String(r[:method])))
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
                out[name] = merge(prev, (index = true, type = lowercase(String(r[:method]))))
            elseif prev === nothing
                out[name] = entry([col]; pk = name == "PRIMARY", unique = r[:nu] == 0, index = true, type = lowercase(String(r[:method])))
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

"""
    inspectdb(tables = nothing; io = stdout) -> String

Write `@model` definitions for existing tables (all of them, or the ones named), for
working with a database Juango didn't create. They get `Meta(managed = false)`, so
migrations leave the tables alone; review the generated fields before use.
"""
function inspectdb(tables = nothing; app_label = "project")
    names = tables === nothing ? introspect_tables() : collect(String, tables)
    known = Set(introspect_tables())
    io = IOBuffer()
    println(io, "# Generated by `manage.jl inspectdb`. Check the field types, then remove `managed = false`")
    println(io, "# from models whose tables Juango should create and migrate.\nusing Juango\n")
    for t in names
        t in known || throw(ArgumentError("no table '$t' in the database"))
        cols = introspect_columns(t)
        fks = introspect_foreign_keys(t)
        println(io, "@model struct ", model_name_for(t))
        pkcols = [c.name for c in cols if c.pk]
        fieldname(c) = haskey(fks, c) && endswith(c, "_id") ? c[1:end-3] : c
        for c in cols
            (c.pk && c.name == "id") && continue
            opts = c.null ? ", null = true, blank = true" : ""
            if haskey(fks, c.name)
                name = endswith(c.name, "_id") ? c.name[1:end-3] : c.name
                println(io, "    ", name, " = ForeignKey(:", model_name_for(fks[c.name]), "; on_delete = :DO_NOTHING", opts, ")")
            else
                def, note = field_for(c)
                isempty(opts) || (def = replace(def, r"\)$" => (endswith(def, "()") ? opts[3:end] : opts) * ")"))
                println(io, "    ", c.name, " = ", def, note)
            end
        end
        meta = "table = $(repr(t)), app_label = $(repr(app_label)), managed = false"
        if pkcols != ["id"]
            meta *= isempty(pkcols) ? "  # TODO: the table has no primary key; Juango needs an id column" :
                    ", pk = CompositePrimaryKey(" * join(":" .* fieldname.(pkcols), ", ") * ")"
        end
        println(io, "    Meta(", meta, ")")
        println(io, "end\n")
    end
    String(take!(io))
end
