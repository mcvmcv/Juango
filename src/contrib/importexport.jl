# Import and export of model rows: CSV, XLSX, JSON (django-import-export) ------------------------------------
#
#     r = ModelResource(Sample; fields = [:id, :name, :plate, :volume], fk = Dict(:plate => :label))
#     write("samples.xlsx", export_data(r, filter(Sample; plate__project = p); format = :xlsx))
#     res = import_data(r, read("samples.xlsx"); format = :xlsx)          # a dry run: nothing is kept
#     res.totals                       # Dict(:new => 3, :update => 10, :skip => 40, :invalid => 0, ...)
#     has_errors(res) || import_data(r, read("samples.xlsx"); format = :xlsx, dry_run = false)
#
# Rows match existing records by `import_id_fields` (the id by default; a natural key such as
# `[:code]` is often better for reference data maintained in spreadsheets). Each value goes through
# the field's form conversion and the model's validation; foreign keys are given by id, or by a
# field of the related model (`fk = Dict(:plate => :label)`), as are many-to-many fields (a
# comma-separated list). An import runs in one transaction: a dry run, or any invalid row, rolls all
# of it back, and the result says row by row what would change and why a row is refused. The admin
# offers it as Import and Export buttons (`Admin.register!(Sample; import_export = r)`).

"How a model's rows are exported and imported: see `ModelResource(...)`."
struct ModelResource
    model::Any
    fields::Vector{Symbol}
    import_id_fields::Vector{Symbol}
    headers::Dict{Symbol,String}
    fk::Dict{Symbol,Symbol}
    skip_unchanged::Bool
    delete_column::Union{Nothing,String}
    before_save::Any                     # nothing, or (obj, row::Dict{Symbol,Any}) -> anything
end

"""
    ModelResource(Model; fields = nothing, exclude = [], import_id_fields = [:id], headers = Dict(),
                  fk = Dict(), skip_unchanged = true, delete_column = nothing, before_save = nothing)

- `fields`: the columns, in order (default: the id and every concrete field and many-to-many).
- `import_id_fields`: the fields that find a row's existing record; a row matching none is new.
- `headers`: column headers other than the field names (`Dict(:volume => "Volume (µl)")`); on
  import a column is matched by its header, the field's name or its label, ignoring case.
- `fk`: foreign keys and many-to-many fields given by a field of the related model, not its id.
- `skip_unchanged`: rows that change nothing are reported as skipped and not saved.
- `delete_column`: a column whose true values (1, yes, true, x) delete the row's record.
- `before_save(obj, row)`: called on each record before it's validated and saved (set a user, a default).
"""
function ModelResource(T::Type; fields = nothing, exclude = Symbol[], import_id_fields = [:id], headers = Dict(),
                       fk = Dict(), skip_unchanged::Bool = true, delete_column = nothing, before_save = nothing)
    meta = modelmeta(T)
    default = vcat([:id], Symbol[f.name for f in concrete_fields(T) if f.name !== :id && f.kind !== :m2m], Symbol[f.name for f in meta.m2m])
    names = filter(!in(Symbol.(collect(exclude))), fields === nothing ? default : Symbol.(collect(fields)))
    for n in names
        n === :id || findfield(meta, n) !== nothing || any(f -> f.name === n, meta.m2m) ||
            throw(ArgumentError("ModelResource: $(nameof(T)) has no field '$n'"))
    end
    ModelResource(T, names, Symbol.(collect(import_id_fields)), Dict{Symbol,String}(Symbol(k) => string(v) for (k, v) in headers),
                  Dict{Symbol,Symbol}(Symbol(k) => Symbol(v) for (k, v) in fk), skip_unchanged,
                  delete_column === nothing ? nothing : string(delete_column), before_save)
end
Base.show(io::IO, r::ModelResource) = print(io, "<ModelResource ", nameof(r.model), ": ", join(r.fields, ", "), ">")

resource_field(r, n) = n === :id ? nothing : something(findfield(modelmeta(r.model), n),
                                                         (i = findfirst(f -> f.name === n, modelmeta(r.model).m2m); i === nothing ? nothing : modelmeta(r.model).m2m[i]))
header_of(r::ModelResource, n::Symbol) = get(r.headers, n, string(n))

# --- export ---

"A field's value of an object as exported: foreign keys as ids or their `fk` field, many-to-many as a comma-separated list."
function export_value(r::ModelResource, @nospecialize(obj), n::Symbol, typed::Bool)
    n === :id && return obj.pk
    f = resource_field(r, n)
    if f.kind === :m2m
        lf = get(r.fk, n, :id)
        return join([string(lf === :id ? o.pk : getproperty(o, lf)) for o in getproperty(obj, n)], ", ")
    elseif f.kind === :fk
        id = field_data(obj, attname(f))
        id === nothing && return nothing
        lf = get(r.fk, n, nothing)
        return lf === nothing ? id : (rel = getproperty(obj, n); rel === nothing ? nothing : getproperty(rel, lf))
    end
    v = field_data(obj, attname(f))
    v === nothing && return nothing
    typed && (v isa Union{Number,Bool,Date,DateTime,AbstractString}) && return v
    value_to_json(f, v)
end

"""
    export_rows(resource, queryset) -> Vector{Vector{Any}}

The header row and a row per object, as the resource defines them.
"""
function export_rows(r::ModelResource, qs; typed::Bool = false)
    rows = Vector{Vector{Any}}()
    push!(rows, Any[header_of(r, n) for n in r.fields])
    for o in (qs isa QuerySet ? fetch(qs) : qs)
        push!(rows, Any[export_value(r, o, n, typed) for n in r.fields])
    end
    rows
end

"""
    export_data(resource, queryset; format = :csv) -> Vector{UInt8}

The objects as a CSV (with formula protection, `csv_field`), XLSX or JSON (a list of objects keyed
by header) file.
"""
function export_data(r::ModelResource, qs; format = :csv)
    fmt = Symbol(lowercase(string(format)))
    if fmt === :csv
        rows = export_rows(r, qs)
        return Vector{UInt8}(codeunits(join([join(csv_field.(row), ",") for row in rows], "\r\n") * "\r\n"))
    elseif fmt === :xlsx
        return xlsx_bytes(export_rows(r, qs; typed = true); sheet = string(modelmeta(r.model).verbose_name_plural))
    elseif fmt === :json
        rows = export_rows(r, qs)
        hs = string.(rows[1])
        return Vector{UInt8}(codeunits(JSON.json([Dict(zip(hs, row)) for row in rows[2:end]])))
    end
    throw(ArgumentError("export_data: format is :csv, :xlsx or :json, not $(repr(format))"))
end
const EXPORT_TYPES = Dict(:csv => "text/csv; charset=utf-8", :xlsx => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                          :json => "application/json")

"A download of `export_data(resource, queryset; format)` named `filename` (default: the model's plural name and the date)."
function export_download(r::ModelResource, qs; format = :csv, filename = nothing)
    fmt = Symbol(lowercase(string(format)))
    name = something(filename, replace(string(modelmeta(r.model).verbose_name_plural), ' ' => '-') * "-" * string(today()) * "." * string(fmt))
    resp = HttpResponse(export_data(r, qs; format = fmt); content_type = EXPORT_TYPES[fmt])
    setheader!(resp, "Content-Disposition", content_disposition(name; attachment = true))
    resp
end

# --- import ---

"One row of an import: what happened (`:new`, `:update`, `:skip`, `:delete` or `:invalid`), the changes and the errors."
struct RowResult
    number::Int                                   # the row's line in the file (the header is line 1)
    kind::Symbol
    object_repr::String
    diff::Vector{Tuple{String,Any,Any}}           # (field, old value, new value)
    errors::Dict{String,Vector{String}}           # field (or "row") => messages
end
"What an import did (or would do): the rows, totals per kind, columns it didn't use and errors about the file itself."
struct ImportResult
    rows::Vector{RowResult}
    totals::Dict{Symbol,Int}
    ignored_columns::Vector{String}
    errors::Vector{String}
    dry_run::Bool
end
"Whether an import refused anything: a file error or an invalid row (then nothing was kept)."
has_errors(res::ImportResult) = !isempty(res.errors) || any(r -> r.kind === :invalid, res.rows)

"""
    read_table(data; format) -> Vector{Vector{Any}}

The rows of a CSV (`String` or bytes), XLSX (bytes) or JSON (a list of objects: the first one's keys
are the header) file, the header first.
"""
function read_table(data; format)
    fmt = Symbol(lowercase(string(format)))
    fmt === :csv && return Vector{Any}[Vector{Any}(r) for r in parse_csv(data isa AbstractString ? data : String(copy(data)))]
    fmt === :xlsx && return read_xlsx(data isa AbstractString ? Vector{UInt8}(codeunits(data)) : Vector{UInt8}(data))
    if fmt === :json
        items = JSON.parse(data isa AbstractString ? data : String(copy(data)))
        items isa AbstractVector || throw(ArgumentError("a JSON import is a list of objects"))
        isempty(items) && return Vector{Any}[]
        hs = collect(String, keys(items[1]))
        return vcat(Vector{Any}[Any[h for h in hs]], Vector{Any}[Any[get(it, h, nothing) for h in hs] for it in items])
    end
    throw(ArgumentError("format is :csv, :xlsx or :json, not $(repr(format))"))
end
"The import format of a file name (`.csv`, `.xlsx`, `.json`), or nothing."
format_of(filename) = (e = lowercase(splitext(string(filename))[2]); e == ".csv" ? :csv : e == ".xlsx" ? :xlsx : e == ".json" ? :json : nothing)

norm_header(h) = lowercase(replace(strip(string(h)), r"[\s_]+" => " "))
"Which resource field each column is (nothing for a column it doesn't use)."
function column_fields(r::ModelResource, header)
    meta = modelmeta(r.model)
    names = Dict{String,Symbol}()
    for n in r.fields
        names[norm_header(n)] = n
        names[norm_header(header_of(r, n))] = n
        f = resource_field(r, n)
        f === nothing || (names[norm_header(label(f))] = n)
    end
    Union{Nothing,Symbol}[get(names, norm_header(h), nothing) for h in header]
end

truthy_cell(v) = v === true || (v isa Real && v == 1) || (v isa AbstractString && lowercase(strip(v)) in ("1", "true", "yes", "y", "x"))
cell_string(v) = v === nothing ? "" : v isa AbstractFloat && isinteger(v) ? string(Int(v)) : string(v)

"A cell as the field's value: `(value, error)`."
function import_value(r::ModelResource, f::Field, n::Symbol, v)
    if f.kind === :m2m
        R, lf = related_model(f), get(r.fk, n, :id)
        keys_ = [strip(s) for s in split(cell_string(v), ',') if !isempty(strip(s))]
        objs = Any[]
        for k in keys_
            o = first(filter(base_objects(R), Q(lf => (lf === :id ? parse_pk(R, k) : k))))
            o === nothing && return nothing, "No $(modelmeta(R).verbose_name) with $lf $(repr(k))."
            push!(objs, o)
        end
        return objs, nothing
    elseif f.kind === :fk
        s = strip(cell_string(v))
        isempty(s) && return nothing, nothing
        R = related_model(f)
        lf = get(r.fk, n, :id)
        o = first(filter(base_objects(R), Q(lf => (lf === :id ? parse_pk(R, s) : s))))
        o === nothing && return nothing, "No $(modelmeta(R).verbose_name) with $lf $(repr(s))."
        return o, nothing
    end
    f.kind in (:date, :datetime) && v isa Real && !(v isa Bool) && (v = excel_date(v))      # an Excel date serial
    f.kind === :date && v isa DateTime && (v = Date(v))
    v isa Union{Date,DateTime} && return v, nothing
    f.kind === :bool && v isa Bool && return v, nothing
    val, err = to_julia(f, cell_string(v))
    val, err
end

same_value(a, b) = isequal(a, b) || (a isa Model && b isa Model && a.pk == b.pk) ||
                   (a isa AbstractVector && b isa AbstractVector && Set(x isa Model ? x.pk : x for x in a) == Set(x isa Model ? x.pk : x for x in b))
shown(v) = v isa Model ? string(v) : v isa AbstractVector ? join(string.(v), ", ") : v

"""
    import_data(resource, data; format, dry_run = true) -> ImportResult

Import a CSV, XLSX or JSON file's rows (see the comment at the top of this file). With `dry_run`
(the default) nothing is kept: the result says what would happen. Without it, the rows are saved
in one transaction, unless some row is invalid: then nothing is kept either.
"""
function import_data(r::ModelResource, data; format, dry_run::Bool = true)
    T = r.model
    rows = read_table(data; format = format)
    results, ignored, file_errors = RowResult[], String[], String[]
    isempty(rows) && return ImportResult(results, Dict{Symbol,Int}(), ignored, ["The file has no rows."], dry_run)
    header = rows[1]
    cols = column_fields(r, header)
    append!(ignored, [string(h) for (h, c) in zip(header, cols) if c === nothing && !(r.delete_column !== nothing && norm_header(h) == norm_header(r.delete_column))])
    delcol = r.delete_column === nothing ? nothing : findfirst(h -> norm_header(h) == norm_header(r.delete_column), header)
    for idf in r.import_id_fields
        idf in cols || idf === :id || push!(file_errors, "The file has no column for $(idf), which finds each row's record.")
    end
    isempty(file_errors) || return ImportResult(results, Dict{Symbol,Int}(), ignored, file_errors, dry_run)
    atomic() do
        for (k, row) in enumerate(rows[2:end])
            all(v -> v === nothing || (v isa AbstractString && isempty(strip(v))), row) && continue
            push!(results, import_row(r, cols, row, k + 1, delcol))
        end
        (dry_run || any(x -> x.kind === :invalid, results)) && set_rollback!(true)
    end
    totals = Dict{Symbol,Int}(k => count(x -> x.kind === k, results) for k in (:new, :update, :skip, :delete, :invalid))
    ImportResult(results, totals, ignored, file_errors, dry_run)
end

function import_row(r::ModelResource, cols, row, number, delcol)
    T = r.model
    errors = Dict{String,Vector{String}}()
    vals = Dict{Symbol,Any}()
    for (j, n) in enumerate(cols)
        n === nothing && continue
        v = j <= length(row) ? row[j] : nothing
        if n === :id
            s = strip(cell_string(v))
            vals[:id] = isempty(s) ? nothing : parse_pk(T, s)
            continue
        end
        val, err = import_value(r, resource_field(r, n), n, v)
        err === nothing ? (vals[n] = val) : (errors[string(n)] = [err])
    end
    # the existing record, by the import id fields
    obj = nothing
    keyvals = [n => get(vals, n, nothing) for n in r.import_id_fields]
    if all(p -> p.second !== nothing && p.second != "", keyvals)
        obj = first(filter(base_objects(T), [Q(p.first => (p.second isa Model ? p.second.pk : p.second)) for p in keyvals]...))
    end
    if delcol !== nothing && delcol <= length(row) && truthy_cell(row[delcol])
        obj === nothing && return RowResult(number, :skip, "", Tuple{String,Any,Any}[], errors)
        name = string(obj)
        delete!(obj)
        return RowResult(number, :delete, name, Tuple{String,Any,Any}[], errors)
    end
    isempty(errors) || return RowResult(number, :invalid, obj === nothing ? "" : string(obj), Tuple{String,Any,Any}[], errors)
    new = obj === nothing
    new && (obj = T(); haskey(vals, :id) && vals[:id] !== nothing && setproperty!(obj, :id, vals[:id]))
    diff = Tuple{String,Any,Any}[]
    m2m = Pair{Symbol,Any}[]
    for (n, v) in vals
        n === :id && continue
        f = resource_field(r, n)
        if f.kind === :m2m
            old = new ? Any[] : collect(getproperty(obj, n))
            same_value(old, v) || (push!(diff, (header_of(r, n), shown(old), shown(v))); push!(m2m, n => v))
            continue
        end
        old = new ? nothing : (f.kind === :fk ? getproperty(obj, n) : field_data(obj, attname(f)))
        if new || !same_value(old, v)
            new || push!(diff, (header_of(r, n), shown(old), shown(v)))
            setproperty!(obj, n, v)
        end
    end
    if !new && isempty(diff) && r.skip_unchanged
        return RowResult(number, :skip, string(obj), diff, errors)
    end
    r.before_save === nothing || r.before_save(obj, vals)
    for (k, msgs) in full_clean(obj; exclude = [n for n in keys(vals) if n !== :id && resource_field(r, n).kind === :m2m])
        errors[string(k)] = msgs
    end
    isempty(errors) || return RowResult(number, :invalid, new ? "" : string(obj), diff, errors)
    save!(obj)
    for (n, v) in m2m
        set!(getproperty(obj, n), v)
    end
    if new
        for (n, v) in vals
            n === :id || push!(diff, (header_of(r, n), nothing, shown(v)))
        end
    end
    RowResult(number, new ? :new : :update, string(obj), diff, errors)
end
