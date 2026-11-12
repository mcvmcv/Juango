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
# Rows have the columns as properties (`p.author_id`) and their relations as they were then:
#
#     p.author                  # the related row (`p.author = a` sets author_id)
#     a.post_set                # reverse foreign key: iterate, `count`, `filter(a.post_set; ...)`, `create`
#     p.tags                    # many-to-many (auto-created join table): iterate, `add!`, `remove!`, `clear!`
#     t.post_set                # ... and its reverse
#
# `filter` takes column lookups (`exact`, `in`, `isnull`, `gt`, `gte`, `lt`, `lte`, `ne`).
# Reverse accessors are `<model>_set` (historical states don't keep `related_name`). Models
# with a composite primary key are not supported here.

"The models of a project at one point in its migration history."
struct HistoricalApps
    state::SchemaState
end

"A table as it was at that point: query and change its rows."
struct HistoricalModel
    table::Table
    state::SchemaState          # the whole schema then, for relations
end
Base.show(io::IO, m::HistoricalModel) = print(io, "<historical model ", m.table.app, ".", m.table.model, ">")

"One row of a historical model, with its columns as properties."
struct HistoricalRow
    model::HistoricalModel
    data::Dict{Symbol,Any}
end
function Base.getproperty(r::HistoricalRow, s::Symbol)
    s === :pk && (s = :id)
    d = getfield(r, :data)
    haskey(d, s) && return d[s]                  # columns first: a table may have a "model" column
    s in (:model, :data) && return getfield(r, s)
    historical_relation(r, s)
end
function Base.setproperty!(r::HistoricalRow, s::Symbol, v)
    s === :pk && (s = :id)
    m = getfield(r, :model)
    if !(s === :id || hascolumn(m.table, string(s)))
        c = fk_column(m.table, s)
        c === nothing && throw(ArgumentError("$(m.table.model) had no column '$s' at this point in history"))
        s, v = Symbol(c.name), v isa HistoricalRow ? v.id : v
    end
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
        t.app == string(app_label) && lowercase(t.model) == lowercase(string(model_name)) && return HistoricalModel(t, apps.state)
    end
    throw(LookupError("no model $(app_label).$(model_name) at this point in the migration history"))
end

function historical_value(c::Column, v)
    v === nothing && return nothing
    c.kind === :bool && return v isa Bool ? v : v != 0
    c.kind === :datetime && return v isa DateTime || v isa TimeZones.ZonedDateTime ? v : something(todatetime(v), v)
    c.kind === :date && return v isa Date ? v : Date(todatetime(v))
    c.kind in (:int, :fk) && c.of !== :uuid && return v isa Integer ? Int(v) : parse(Int, string(v))
    c.kind === :decimal && return c.decimal_places === nothing ? to_decimal(v) : round(to_decimal(v); digits = c.decimal_places)
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

# --- relations ---

"The foreign key column behind relation `name` (`author` → `author_id`), if there is one."
function fk_column(t::Table, name::Symbol)
    n = string(name) * "_id"
    hascolumn(t, n) || return nothing
    c = getcolumn(t, n)
    c.kind === :fk ? c : nothing
end
fk_columns(t::Table) = [c for c in t.columns if c.kind === :fk && c.references !== nothing]
references(c::Column, t::Table) = ref_table(c.references) == t.name

function related_model(m::HistoricalModel, c::Column)
    t = get(m.state, ref_table(c.references), nothing)
    t === nothing && throw(ArgumentError("$(m.table.model).$(c.name) references table '$(c.references)', which didn't exist at this point in history"))
    HistoricalModel(t, m.state)
end

"Rows of `model` whose `column` is `id`: a reverse foreign key."
struct HistoricalRelated
    model::HistoricalModel
    column::Symbol
    id::Any
end
"Rows of `target` joined to `id` through an auto-created many-to-many table."
struct HistoricalManyToMany
    through::HistoricalModel
    source::Symbol           # the join table's column for this side
    dest::Symbol             # ... and for the other side
    target::HistoricalModel
    id::Any
end
const HistoricalRelationSet = Union{HistoricalRelated,HistoricalManyToMany}

related_rows(r::HistoricalRelated) = filter(r.model; NamedTuple{(r.column,)}((r.id,))...)
function related_rows(r::HistoricalManyToMany)
    ids = [getfield(x, :data)[r.dest] for x in filter(r.through; NamedTuple{(r.source,)}((r.id,))...)]
    filter(r.target; id__in = ids)
end
Base.collect(r::HistoricalRelationSet) = related_rows(r)
Base.IteratorSize(::Type{<:HistoricalRelationSet}) = Base.SizeUnknown()
Base.eltype(::Type{<:HistoricalRelationSet}) = HistoricalRow
function Base.iterate(r::HistoricalRelationSet, st = (related_rows(r), 1))
    rows, i = st
    i > length(rows) ? nothing : (rows[i], (rows, i + 1))
end
Base.count(r::HistoricalRelated) = count(r.model; NamedTuple{(r.column,)}((r.id,))...)
Base.count(r::HistoricalManyToMany) = count(r.through; NamedTuple{(r.source,)}((r.id,))...)
Base.length(r::HistoricalRelationSet) = count(r)
Base.filter(r::HistoricalRelated; kw...) = filter(r.model; NamedTuple{(r.column,)}((r.id,))..., kw...)
create(r::HistoricalRelated; kw...) = create(r.model; NamedTuple{(r.column,)}((r.id,))..., kw...)
Base.show(io::IO, r::HistoricalRelationSet) = print(io, "<historical relation to ", r isa HistoricalRelated ? r.model.table.model : r.target.table.model, ">")

row_id(x) = x isa HistoricalRow ? x.id : x
function add!(r::HistoricalManyToMany, rows...)
    have = Set(getfield(x, :data)[r.dest] for x in filter(r.through; NamedTuple{(r.source,)}((r.id,))...))
    for x in rows
        i = row_id(x)
        i in have && continue
        create(r.through; NamedTuple{(r.source, r.dest)}((r.id, i))...)
        push!(have, i)
    end
    nothing
end
function remove!(r::HistoricalManyToMany, rows...)
    ids = Any[row_id(x) for x in rows]
    isempty(ids) && return nothing
    execute_changes("DELETE FROM $(qname(r.through.table.name)) WHERE $(qname(string(r.source))) = ? AND " *
                    "$(qname(string(r.dest))) IN (" * join(fill("?", length(ids)), ", ") * ")", vcat(Any[r.id], ids))
    nothing
end
clear!(r::HistoricalManyToMany) =
    (execute_changes("DELETE FROM $(qname(r.through.table.name)) WHERE $(qname(string(r.source))) = ?", Any[r.id]); nothing)

"An auto-created join table: two foreign keys, named `<owner table>_<field>`; returns (owner column, other column)."
function join_columns(t::Table, state)
    fks = fk_columns(t)
    length(fks) == 2 && length(t.columns) == 2 || return nothing
    for (a, b) in ((fks[1], fks[2]), (fks[2], fks[1]))
        owner = ref_table(a.references)
        startswith(t.name, owner * "_") && haskey(state, owner) || continue
        ref_table(a.references) == ref_table(b.references) && startswith(b.name, "from_") && ((a, b) = (b, a))   # self-referential
        return a, b
    end
    nothing
end

"A relation of a historical row: a foreign key, a many-to-many field or a reverse accessor (`<model>_set`)."
function historical_relation(r::HistoricalRow, s::Symbol)
    m = getfield(r, :model)
    t = m.table
    id = getfield(r, :data)[:id]
    c = fk_column(t, s)
    if c !== nothing                                      # forward foreign key
        v = getfield(r, :data)[Symbol(c.name)]
        return v === nothing ? nothing : get(related_model(m, c); id = v)
    end
    jt = get(m.state, t.name * "_" * string(s), nothing)
    if jt !== nothing && (jc = join_columns(jt, m.state)) !== nothing && references(jc[1], t)    # many-to-many
        return HistoricalManyToMany(HistoricalModel(jt, m.state), Symbol(jc[1].name), Symbol(jc[2].name), related_model(m, jc[2]), id)
    end
    name = string(s)
    if endswith(name, "_set")                             # reverse foreign key or many-to-many
        found = Any[]
        for o in values(m.state)
            jc = join_columns(o, m.state)
            if jc !== nothing
                owner = m.state[ref_table(jc[1].references)]
                lowercase(owner.model) * "_set" == name && references(jc[2], t) &&
                    push!(found, HistoricalManyToMany(HistoricalModel(o, m.state), Symbol(jc[2].name), Symbol(jc[1].name),
                                                      HistoricalModel(owner, m.state), id))
            elseif lowercase(o.model) * "_set" == name
                for fc in fk_columns(o)
                    references(fc, t) && push!(found, HistoricalRelated(HistoricalModel(o, m.state), Symbol(fc.name), id))
                end
            end
        end
        length(found) == 1 && return found[1]
        length(found) > 1 && throw(ArgumentError("$(t.model).$name is ambiguous at this point in history (several foreign keys); " *
                                                 "filter the other model by its column instead"))
    end
    throw(ArgumentError("$(t.model) had no column or relation '$s' at this point in history"))
end
