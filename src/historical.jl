# Historical models for data migrations -----------------------------------------------------------
#
# A data migration should work with the schema as it was at that point in history, not with
# today's model structs (a later migration may have renamed or dropped a column). A
# `RunJulia` function that takes one argument gets the schema at its place in the history:
#
#     RunJulia(apps -> begin
#         Post = get_model(apps, "blog", "Post")
#         for p in objects(Post)
#             p.slug = lowercase(replace(p.title, " " => "-"))
#             save!(p)
#         end
#     end)
#
# A historical model knows its table and columns only: rows have the columns as properties
# (`p.author_id` for a foreign key), and `filter` takes column lookups (`exact`, `in`,
# `isnull`, `gt`, `gte`, `lt`, `lte`, `ne`). Models with a composite primary key are not
# supported here.

"The models of a project at one point in its migration history."
struct HistoricalApps
    state::SchemaState
end

"A table as it was at that point: query and change its rows."
struct HistoricalModel
    table::Table
end
Base.show(io::IO, m::HistoricalModel) = print(io, "<historical model ", m.table.app, ".", m.table.model, ">")

"One row of a historical model, with its columns as properties."
struct HistoricalRow
    model::HistoricalModel
    data::Dict{Symbol,Any}
end
function Base.getproperty(r::HistoricalRow, s::Symbol)
    s in (:model, :data) && return getfield(r, s)
    s === :pk && (s = :id)
    d = getfield(r, :data)
    haskey(d, s) || throw(ArgumentError("$(getfield(r, :model).table.model) had no column '$s' at this point in history"))
    d[s]
end
function Base.setproperty!(r::HistoricalRow, s::Symbol, v)
    s === :pk && (s = :id)
    m = getfield(r, :model)
    (s === :id || hascolumn(m.table, string(s))) ||
        throw(ArgumentError("$(m.table.model) had no column '$s' at this point in history"))
    getfield(r, :data)[s] = v
end
Base.propertynames(r::HistoricalRow, private::Bool = false) = collect(keys(getfield(r, :data)))
Base.show(io::IO, r::HistoricalRow) = print(io, getfield(r, :model).table.model, "(id=", repr(get(getfield(r, :data), :id, nothing)), ")")

"""
    get_model(apps, app_label, model_name) -> HistoricalModel

A model as it was at this point of the migration history (`apps` is what a one-argument
`RunJulia` function receives).
"""
function get_model(apps::HistoricalApps, app_label, model_name)
    for t in values(apps.state)
        t.app == string(app_label) && lowercase(t.model) == lowercase(string(model_name)) && return HistoricalModel(t)
    end
    throw(LookupError("no model $(app_label).$(model_name) at this point in the migration history"))
end

function historical_value(c::Column, v)
    v === nothing && return nothing
    c.kind === :bool && return v isa Bool ? v : v != 0
    c.kind === :datetime && return v isa DateTime || v isa TimeZones.ZonedDateTime ? v : something(todatetime(v), v)
    c.kind === :date && return v isa Date ? v : Date(todatetime(v))
    c.kind in (:int, :fk) && c.of !== :uuid && return v isa Integer ? Int(v) : parse(Int, string(v))
    v isa AbstractString ? String(v) : v
end

function historical_row(m::HistoricalModel, row)
    d = Dict{Symbol,Any}(:id => get(row, :id, nothing))
    for c in m.table.columns
        k = Symbol(c.name)
        d[k] = historical_value(c, get(row, k, nothing))
    end
    HistoricalRow(m, d)
end

check_historical(m::HistoricalModel) = m.table.pk === :composite &&
    throw(ArgumentError("historical models with a composite primary key aren't supported; use Juango.execute"))

function historical_where(m::HistoricalModel, kw)
    parts, ps = String[], Any[]
    for (k, v) in kw
        name, lookup = split_lookup(k)
        (name == "id" || name == "pk" || hascolumn(m.table, name)) ||
            throw(LookupError("$(m.table.model) had no column '$name' at this point in history"))
        col = qname(name == "pk" ? "id" : name)
        if lookup == "exact"
            v === nothing ? push!(parts, "$col IS NULL") : (push!(parts, "$col = ?"); push!(ps, v))
        elseif lookup == "isnull"
            push!(parts, v ? "$col IS NULL" : "$col IS NOT NULL")
        elseif lookup == "in"
            isempty(v) ? push!(parts, sql_false(backend())) :
                (push!(parts, "$col IN (" * join(fill("?", length(v)), ", ") * ")"); append!(ps, collect(v)))
        elseif lookup in ("gt", "gte", "lt", "lte", "ne")
            push!(parts, "$col $(Dict("gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=", "ne" => "<>")[lookup]) ?")
            push!(ps, v)
        else
            throw(LookupError("historical models support exact, in, isnull, gt, gte, lt, lte and ne lookups, not '$lookup'"))
        end
    end
    isempty(parts) ? "" : " WHERE " * join(parts, " AND "), ps
end

"All rows of a historical model, by id."
function objects(m::HistoricalModel)
    check_historical(m)
    HistoricalRow[historical_row(m, r) for r in execute("SELECT * FROM $(qname(m.table.name)) ORDER BY $(qname("id"))")]
end

"Rows of a historical model matching column lookups."
function Base.filter(m::HistoricalModel; kw...)
    check_historical(m)
    w, ps = historical_where(m, kw)
    HistoricalRow[historical_row(m, r) for r in execute("SELECT * FROM $(qname(m.table.name))$w ORDER BY $(qname("id"))", ps)]
end

function Base.get(m::HistoricalModel; kw...)
    rows = filter(m; kw...)
    isempty(rows) && throw(DoesNotExist(m.table.model, join(["$k=$(repr(v))" for (k, v) in kw], ", ")))
    length(rows) > 1 && throw(MultipleObjectsReturned(m.table.model, join(["$k=$(repr(v))" for (k, v) in kw], ", ")))
    rows[1]
end

function Base.count(m::HistoricalModel; kw...)
    w, ps = historical_where(m, kw)
    Int(execute("SELECT COUNT(*) AS n FROM $(qname(m.table.name))$w", ps)[1][:n])
end

"Insert a row; columns left out get their default (or NULL)."
function create(m::HistoricalModel; kw...)
    check_historical(m)
    r = HistoricalRow(m, Dict{Symbol,Any}(:id => nothing))
    for c in m.table.columns
        getfield(r, :data)[Symbol(c.name)] = c.default isa SQLDefault ? nothing : c.default
    end
    for (k, v) in kw
        setproperty!(r, Symbol(k), v)
    end
    save!(r)
end

"Write a row back (INSERT when it has no id yet)."
function save!(r::HistoricalRow)
    m = getfield(r, :model)
    d = getfield(r, :data)
    cols = [c for c in m.table.columns if c.generated === nothing]
    vals = Any[d[Symbol(c.name)] for c in cols]
    tbl = qname(m.table.name)
    if d[:id] === nothing
        d[:id] = execute_insert(insert_sql(backend(), tbl, [qname(c.name) for c in cols]), vals)
    else
        execute_changes("UPDATE $tbl SET " * join(["$(qname(c.name)) = ?" for c in cols], ", ") * " WHERE $(qname("id")) = ?",
                        vcat(vals, d[:id]))
    end
    r
end

"Update columns of every row matching the lookups in `where`; returns the count."
function update!(m::HistoricalModel, where::Union{NamedTuple,AbstractDict} = (;); kw...)
    check_historical(m)
    isempty(kw) && return 0
    for k in keys(kw)
        hascolumn(m.table, string(k)) || throw(ArgumentError("$(m.table.model) had no column '$k' at this point in history"))
    end
    w, wps = historical_where(m, pairs(where))
    execute_changes("UPDATE $(qname(m.table.name)) SET " * join(["$(qname(string(k))) = ?" for k in keys(kw)], ", ") * w,
                    vcat(Any[v for v in values(kw)], wps))
end

function Base.delete!(r::HistoricalRow)
    m = getfield(r, :model)
    execute_changes("DELETE FROM $(qname(m.table.name)) WHERE $(qname("id")) = ?", [getfield(r, :data)[:id]])
    getfield(r, :data)[:id] = nothing
    r
end
