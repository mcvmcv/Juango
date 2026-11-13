# Database tools: flush, dbshell, inspectdb -------------------------------------------------------------

"The tables Juango manages (models in use, their join tables), without the migration records."
managed_tables() = unique([modelmeta(T).table for T in all_models()
                           if !modelmeta(T).proxy && model_in_use(T) && get(modelmeta(T).extra, :managed, true) !== false])

"""
    flush!(; reset_sequences = true) -> Int

Delete every row of every table Juango manages (not the record of applied migrations), then
recreate content types and permissions; returns the number of tables emptied. Ids start
from 1 again where the database allows.
"""
function flush!(; reset_sequences = true)
    b = backend()
    tables = [t for t in managed_tables() if table_exists(b, t)]
    isempty(tables) && return 0
    q(t) = quote_name(b, t)
    if b isa PostgresBackend
        execute("TRUNCATE " * join(q.(tables), ", ") * (reset_sequences ? " RESTART IDENTITY" : "") * " CASCADE")
    elseif b isa MySQLBackend
        atomic() do                                       # one connection, so the setting applies
            execute("SET FOREIGN_KEY_CHECKS = 0")
            try
                foreach(t -> execute(reset_sequences ? "TRUNCATE TABLE $(q(t))" : "DELETE FROM $(q(t))"), tables)
            finally
                execute("SET FOREIGN_KEY_CHECKS = 1")
            end
        end
    else
        atomic() do
            foreach(t -> execute("DELETE FROM $(q(t))"), tables)
            if reset_sequences && table_exists(b, "sqlite_sequence")
                execute("DELETE FROM sqlite_sequence WHERE name IN (" * join(fill("?", length(tables)), ", ") * ")", tables)
            end
        end
    end
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

model_name_for(table) = join(uppercasefirst.(split(replace(table, r"[^A-Za-z0-9]+" => "_"), '_'; keepempty = false)))

"The field definition for an introspected column (and a note when the type is a guess)."
function field_for(col)
    t = col.type
    m = match(r"^(?:character varying|varchar|nvarchar|char|character)\s*(?:\((\d+)\))?", t)
    m !== nothing && return "CharField(max_length = $(something(col.max_length, m[1] === nothing ? nothing : parse(Int, m[1]), 255)))", ""
    occursin(r"^tinyint\(1\)|^bool", t) && return "BooleanField()", ""
    t == "interval" && return "DurationField()", ""               # before "int"
    occursin(r"int|serial", t) && return "IntegerField()", ""
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
