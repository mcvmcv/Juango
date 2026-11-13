# --- bulk_create, bulk_update, iterator, select_for_update, set operations ---------------------

struct TransactionManagementError <: Exception
    msg::String
end
Base.showerror(io::IO, e::TransactionManagementError) = print(io, "TransactionManagementError: ", e.msg)

"Prepare objects for a bulk insert as `save!` would: timestamps, UUID keys, uploaded files."
function prepare_for_insert!(objs, T)
    ts = timezone_now()
    for o in objs
        data = getfield(o, :_data)
        for f in all_fields(T)
            a = attname(f)
            if f.auto_now || (f.auto_now_add && get(data, a, nothing) === nothing)
                data[a] = auto_now_value(f, ts)
            end
        end
        data[:id] === nothing && pk_kind(T) === :uuid && (data[:id] = uuid4())
        store_uploaded_files!(o, data)
    end
end

"""
    bulk_create(objs; batch_size, ignore_conflicts, update_conflicts, update_fields, unique_fields)

Insert many objects with multi-row INSERTs (no `save!`, no signals) and return them. New
ids are set on SQLite, PostgreSQL and MariaDB (not on MySQL, nor when conflicts are ignored
or updated).

- `ignore_conflicts = true` skips rows that break a unique constraint.
- `update_conflicts = true` updates `update_fields` of the existing row instead; PostgreSQL
  and SQLite also need the `unique_fields` that conflict.
"""
bulk_create(objs::AbstractVector{T}; db = nothing, kw...) where {T<:Model} =
    with_db(() -> (bulk_create_here(objs; kw...); foreach(set_instance_db!, objs); objs), something(db, routed_db(T, true), Some(nothing)))
function bulk_create_here(objs::AbstractVector{T}; batch_size = nothing, ignore_conflicts = false,
                     update_conflicts = false, update_fields = nothing, unique_fields = nothing) where {T<:Model}
    isempty(objs) && return objs
    table_parent(concrete_model(T)) === nothing ||
        throw(ArgumentError("bulk_create can't be used with multi-table inheritance ($(nameof(T)))"))
    ignore_conflicts && update_conflicts && throw(ArgumentError("bulk_create: pass ignore_conflicts or update_conflicts, not both"))
    b = backend()
    meta = modelmeta(concrete_model(T))
    fieldsof(names) = [let f = findfield(meta, Symbol(n)); f === nothing ? throw(LookupError("$(nameof(T)) has no field '$n'")) : f end
                       for n in names]
    conflict = ""
    if update_conflicts
        update_fields === nothing && throw(ArgumentError("bulk_create(update_conflicts = true) needs update_fields"))
        ups = [qname(column(f)) for f in fieldsof(update_fields)]
        if b isa MySQLBackend
            conflict = " ON DUPLICATE KEY UPDATE " * join(["$c = VALUES($c)" for c in ups], ", ")
        else
            unique_fields === nothing && throw(ArgumentError("bulk_create(update_conflicts = true) needs unique_fields on $(vendor(b))"))
            target = [Symbol(n) in (:id, :pk) ? qname("id") : qname(column(fieldsof([n])[1])) for n in unique_fields]
            conflict = " ON CONFLICT (" * join(target, ", ") * ") DO UPDATE SET " * join(["$c = EXCLUDED.$c" for c in ups], ", ")
        end
    elseif ignore_conflicts && !(b isa MySQLBackend)
        conflict = " ON CONFLICT DO NOTHING"
    end
    verb = ignore_conflicts && b isa MySQLBackend ? "INSERT IGNORE INTO" : "INSERT INTO"
    prepare_for_insert!(objs, T)
    fields = [f for f in meta.fields if f.generated === nothing]
    if isempty(fields)                       # nothing to put in VALUES: one row at a time
        foreach(o -> (save_table!(concrete_model(T), getfield(o, :_data), true); refresh_computed!(o)), objs)
        return objs
    end
    tbl = qname(meta.table)
    isdef(o, f) = get(getfield(o, :_data), attname(f), nothing) === DB_DEFAULT
    for with_id in (true, false)
        group = [o for o in objs if (getfield(o, :_data)[:id] !== nothing) == with_id]
        isempty(group) && continue
        n = batch_size === nothing ? max(1, 999 ÷ (length(fields) + 1)) : Int(batch_size)
        returning = !with_id && conflict == "" && verb == "INSERT INTO" && supports_insert_returning(b) && !is_composite(T)
        for batch in Iterators.partition(group, n)
            # db_default columns left out when no row of the batch sets them; DEFAULT where some do
            bf = [f for f in fields if !all(o -> isdef(o, f), batch)]
            if any(f -> any(o -> isdef(o, f), batch), bf) && occursin("SQLite", vendor(b))
                throw(ArgumentError("bulk_create on SQLite: give every object of a batch a value for a db_default field, or none"))
            end
            cols = vcat(with_id ? [qname("id")] : String[], [qname(column(f)) for f in bf])
            ps, rows_sql = Any[], String[]
            for o in batch
                data = getfield(o, :_data)
                marks = String[]
                with_id && (push!(ps, data[:id]); push!(marks, "?"))
                for f in bf
                    if isdef(o, f)
                        push!(marks, "DEFAULT")
                    else
                        push!(ps, to_db(f, get(data, attname(f), nothing))); push!(marks, "?")
                    end
                end
                push!(rows_sql, "(" * join(marks, ", ") * ")")
            end
            sql = isempty(cols) ? "$verb $tbl DEFAULT VALUES" :
                  "$verb $tbl (" * join(cols, ", ") * ") VALUES " * join(rows_sql, ", ") * conflict
            isempty(cols) && length(batch) > 1 && (foreach(o -> save_table!(concrete_model(T), getfield(o, :_data), true), batch); continue)
            if returning
                rows = execute(sql * " RETURNING " * qname("id"), ps)
                for (o, r) in zip(batch, rows)
                    getfield(o, :_data)[:id] = pk_value(T, r[:id])
                end
            else
                execute_changes(sql, ps)
            end
        end
        with_id && sync_sequence(b, meta.table)
    end
    is_composite(T) && foreach(o -> (getfield(o, :_data)[:id] = composite_pk(T, getfield(o, :_data))), objs)
    objs
end

"""
    bulk_update(objs, [:title, :views]; batch_size) -> Int

Write these fields of many saved objects with a few UPDATE statements (no `save!`, no
signals); returns the number of rows changed.
"""
bulk_update(objs::AbstractVector{T}, fields; db = nothing, kw...) where {T<:Model} =
    with_db(() -> bulk_update_here(objs, fields; kw...),
            isempty(objs) ? db : write_db(first(objs), db))
function bulk_update_here(objs::AbstractVector{T}, fields; batch_size = nothing) where {T<:Model}
    isempty(objs) && return 0
    names = Symbol[Symbol(f) for f in fields]
    isempty(names) && throw(ArgumentError("bulk_update needs at least one field"))
    flds = Field[]
    for n in names
        n in (:id, :pk) && throw(ArgumentError("bulk_update can't change the primary key"))
        f = findfield(modelmeta(T), n)
        f === nothing && (i = findfirst(g -> g.name === n, all_fields(T)); f = i === nothing ? nothing : all_fields(T)[i])
        (f === nothing || f.kind in (:m2m, :gfk, :grel)) && throw(LookupError("bulk_update: $(nameof(T)) has no concrete field '$n'"))
        f.generated === nothing || throw(ArgumentError("bulk_update: '$n' is generated by the database"))
        push!(flds, f)
    end
    any(o -> o.id === nothing, objs) && throw(ArgumentError("bulk_update: all objects must be saved first"))
    b = backend()
    cast(f) = b isa PostgresBackend ? "CAST(? AS $(column_type_for(b, column_state(f))))" : "?"
    total = 0
    bytable = Dict{String,Vector{Field}}()
    for f in flds
        push!(get!(bytable, modelmeta(f.model).table, Field[]), f)
    end
    for (table, tf) in bytable
        n = batch_size === nothing ? max(1, 900 ÷ (2 * length(tf) + 1)) : Int(batch_size)
        for batch in Iterators.partition(objs, n)
            sets, ps = String[], Any[]
            for f in tf
                push!(sets, qname(column(f)) * " = CASE " * qname("id") * join([" WHEN ? THEN " * cast(f) for _ in batch]) * " END")
                for o in batch
                    push!(ps, o.id, to_db(f, field_data(o, attname(f))))
                end
            end
            append!(ps, Any[o.id for o in batch])
            sql = "UPDATE $(qname(table)) SET " * join(sets, ", ") * " WHERE " * qname("id") * " IN (" * join(fill("?", length(batch)), ", ") * ")"
            total += execute_changes(sql, ps)
        end
    end
    total
end

struct QuerySetIterator
    qs::QuerySet
    chunk_size::Int
end

"""
    iterator(qs; chunk_size = 2000)

Iterate over a large queryset without loading it all: rows are fetched `chunk_size` at a
time (LIMIT/OFFSET pages, ordered with the id as a tie-breaker so pages don't overlap).
`prefetch_related` runs per chunk.
"""
function iterator(qs::QuerySet; chunk_size::Integer = 2000)
    chunk_size > 0 || throw(ArgumentError("chunk_size must be positive"))
    "?" in qs.order && throw(ArgumentError("iterator() can't page through a randomly ordered queryset"))
    order = default_order(qs)
    any(o -> lstrip(o, '-') in ("id", "pk"), order) || (order = vcat(order, ["id"]))
    QuerySetIterator(qs.combinator === nothing ? chain(qs; order = order) : qs, Int(chunk_size))
end
iterator(::Type{T}; kw...) where {T<:Model} = iterator(objects(T); kw...)
Base.IteratorSize(::Type{QuerySetIterator}) = Base.SizeUnknown()
Base.eltype(it::QuerySetIterator) = it.qs.values_fields === nothing ? model_of(it.qs) : Dict{Symbol,Any}
function Base.iterate(it::QuerySetIterator, st = (Any[], 1, 0, false))
    buf, i, pos, done = st
    if i > length(buf)
        done && return nothing
        buf = fetch(it.qs[pos+1:pos+it.chunk_size])
        isempty(buf) && return nothing
        i, pos, done = 1, pos + length(buf), length(buf) < it.chunk_size
    end
    buf[i], (buf, i + 1, pos, done)
end

"""
    select_for_update(qs; nowait = false, skip_locked = false, of = ())

Lock the selected rows until the end of the transaction (`SELECT ... FOR UPDATE`). Must be
evaluated inside `atomic()`. `nowait` fails instead of waiting for a lock, `skip_locked`
leaves locked rows out, and `of = ("self", "author")` (PostgreSQL) locks only those tables
of a `select_related` query. SQLite locks the whole database for a write transaction, so
there it only checks for the transaction.
"""
function select_for_update(qs::QuerySet; nowait = false, skip_locked = false, of = ())
    nowait && skip_locked && throw(ArgumentError("select_for_update: nowait and skip_locked can't both be set"))
    chain(qs; for_update = (nowait = nowait, skip_locked = skip_locked, of = collect(of)))
end
select_for_update(::Type{T}; kw...) where {T<:Model} = select_for_update(objects(T); kw...)

function combine(op, qs::QuerySet{T}, others; keep_all = false) where {T}
    isempty(others) && return qs
    parts = QuerySet[]
    for q in (qs, others...)
        model_of(q) === T || throw(ArgumentError("$op: all querysets must be of $(nameof(T))"))
        (q.limit === nothing && q.offset == 0) || throw(ArgumentError("$op: slice the combined queryset, not its parts"))
        isempty(q.related) || throw(ArgumentError("$op: select_related isn't supported in combined querysets"))
        if q.combinator !== nothing && q.combinator[1] === op && q.combinator[3] == keep_all
            append!(parts, q.combinator[2])          # (a ∪ b) ∪ c is one UNION of three parts
        else
            push!(parts, q)
        end
    end
    vf = first(parts).values_fields
    all(p -> p.values_fields == vf, parts) || throw(ArgumentError("$op: the querysets must select the same fields"))
    QuerySet{T}(Q[], String[], nothing, 0, false, Vector{Symbol}[], copy(qs.prefetch), nothing, nothing,
                Pair{Symbol,Any}[], vf, false, Symbol[], nothing, nothing, (op, parts, keep_all), qs.db)
end

"""
    union(qs, others...; all = false)
    intersection(qs, others...)
    difference(qs, others...)

Combine querysets of the same model with SQL `UNION`, `INTERSECT` or `EXCEPT` (`all = true`
keeps duplicates). The result can be ordered (by field names), sliced, counted and
iterated, but not filtered further. `values` querysets combine too.
"""
Base.union(qs::QuerySet, others::QuerySet...; all = false) = combine(:union, qs, others; keep_all = all)
intersection(qs::QuerySet, others::QuerySet...; all = false) = combine(:intersection, qs, others; keep_all = all)
difference(qs::QuerySet, others::QuerySet...; all = false) = combine(:difference, qs, others; keep_all = all)

struct DoesNotExist <: Exception
    model::Any
    lookup::String
end
Base.showerror(io::IO, e::DoesNotExist) = print(io, nameof(e.model), ".DoesNotExist: no object matches ", e.lookup)
struct MultipleObjectsReturned <: Exception
    model::Any
    lookup::String
end
Base.showerror(io::IO, e::MultipleObjectsReturned) = print(io, nameof(e.model), ".MultipleObjectsReturned: more than one object matches ", e.lookup)

"""
    get(qs_or_Model; lookups...)

Exactly one matching object. Throws `DoesNotExist` or `MultipleObjectsReturned`.
"""
function Base.get(qs::QuerySet{T}, qargs::Q...; kw...) where {T}
    q = filter(qs, qargs...; kw...)
    v = fetch(chain(q; limit = 2))
    desc = join(["$k=$(repr(v))" for (k, v) in kw], ", ")
    isempty(v) && throw(DoesNotExist(T, desc))
    length(v) > 1 && throw(MultipleObjectsReturned(T, desc))
    v[1]
end
Base.get(::Type{T}, qargs::Q...; kw...) where {T<:Model} = get(objects(T), qargs...; kw...)

"""
    update!(qs; field=value, ...) -> Int

Bulk SQL UPDATE of all matching rows; returns the number of rows changed.
Does not call `save!` or touch `auto_now` fields.
"""
update!(qs::QuerySet; kw...) = in_db(() -> update_here!(qs; kw...), qs, true)
function update_here!(qs::QuerySet{T}; kw...) where {T}
    qs.isnone && return 0
    meta = modelmeta(T)
    sets, ps = String[], Any[]
    mytable = modelmeta(T).table
    if any(k -> modelmeta(getfield_meta(T, k).model).table != mytable, keys(kw))
        # fields live in several tables (multi-table inheritance): one UPDATE per table, same ids
        ids = values_list(qs, :id; flat = true)
        n = 0
        for M in vcat([concrete_model(T)], ancestors(T))
            mine = [k => v for (k, v) in kw if modelmeta(getfield_meta(T, k).model).table == modelmeta(M).table]
            isempty(mine) && continue
            n = max(n, update!(filter(base_objects(M); id__in = ids); mine...))
        end
        return n
    end
    c = SQLCompiler(T)
    for (k, v) in kw
        f = getfield_meta(T, k)
        if v isa Expression
            sql, p = compile_expr(c, v)
            isempty(c.joins) || throw(ArgumentError("update!: expressions can only use the model's own fields"))
            push!(sets, qname(column(f)) * " = " * sql)
            append!(ps, p)
        else
            push!(sets, qname(column(f)) * " = ?")
            push!(ps, to_db(f, v))
        end
    end
    isempty(sets) && return 0
    sub, sps = select_sql(qs; columns = pk_select(meta.table, T), ordered = false)
    target = is_composite(T) ? "(" * join([qname(column(f)) for f in pk_fields(T)], ", ") * ")" : qname("id")
    execute_changes("UPDATE $(qname(meta.table)) SET $(join(sets, ", ")) WHERE $target IN ($(in_subquery(backend(), sub)))", vcat(ps, sps))
end

struct ProtectedError <: Exception
    msg::String
end
Base.showerror(io::IO, e::ProtectedError) = print(io, "ProtectedError: ", e.msg)

function delete_ids!(T::Type, ids::Vector)
    isempty(ids) && return 0
    T = concrete_model(T)
    delete_fobj_refs!(T, ids)
    is_composite(T) && return delete_composite!(T, ids)
    for g in generic_relations(T)    # objects pointing here through a GenericForeignKey
        M = related_model(g)
        ctf, fkf = g.through
        rel = filter(base_objects(M), Q(Symbol(ctf, :_id) => get_for_model(T).id), Q(Symbol(fkf, "__in") => ids))
        delete_ids!(M, row_keys(rel))
    end
    for C in child_models(T)        # rows of subclasses that extend these rows
        delete_ids!(C, values_list(filter(base_objects(C); id__in = ids), :id; flat = true))
    end
    for (_, M, f) in reverse_relations(T)
        rel = filter(base_objects(M), Q(Symbol(attname(f), "__in") => ids))
        if f.on_delete === :CASCADE
            delete_ids!(M, row_keys(rel))
        elseif f.on_delete === :SET_NULL
            update!(rel; Symbol(attname(f)) => nothing)
        elseif f.on_delete === :PROTECT
            exists(rel) && throw(ProtectedError("cannot delete $(nameof(T)) objects because they are referenced through protected foreign key $(nameof(M)).$(f.name)"))
        end
    end
    signal = has_receivers(pre_delete, T) || has_receivers(post_delete, T)
    doomed = signal ? fetch(filter(base_objects(T); id__in = ids)) : T[]
    foreach(o -> send(pre_delete, T; instance = o), doomed)
    n = 0
    for chunk in Iterators.partition(ids, 500)
        n += execute_changes("DELETE FROM $(qname(modelmeta(T).table)) WHERE $(qname("id")) IN (" *
                             join(fill("?", length(chunk)), ",") * ")", collect(chunk))
    end
    foreach(o -> send(post_delete, T; instance = o), doomed)
    P = table_parent(T)
    P === nothing || delete_ids!(P, ids)     # the parent rows these rows extend
    n
end

"The primary keys of a queryset's rows: ids, or tuples for a composite key."
row_keys(qs::QuerySet{T}) where {T} = is_composite(T) ? Any[o.pk for o in fetch(qs)] : values_list(qs, :id; flat = true)

"Delete rows of a model with a composite primary key (only ForeignObjects can refer to them; see `delete_fobj_refs!`)."
function delete_composite!(T::Type, keys::Vector)
    signal = has_receivers(pre_delete, T) || has_receivers(post_delete, T)
    doomed = signal ? fetch(filter(base_objects(T); pk__in = keys)) : T[]
    foreach(o -> send(pre_delete, T; instance = o), doomed)
    cond = join([qname(column(f)) * " = ?" for f in pk_fields(T)], " AND ")
    n = 0
    for k in keys
        n += execute_changes("DELETE FROM $(qname(modelmeta(T).table)) WHERE $cond", collect(Any, k))
    end
    foreach(o -> send(post_delete, T; instance = o), doomed)
    n
end

"Delete all matching rows (with `on_delete` handling for related objects). Returns the count."
Base.delete!(qs::QuerySet{T}) where {T} =
    in_db(() -> atomic(() -> delete_ids!(T, row_keys(qs))), qs, true)

Base.show(io::IO, qs::QuerySet{T}) where {T} = print(io, "<QuerySet{", nameof(T), "}>")
function Base.show(io::IO, ::MIME"text/plain", qs::QuerySet{T}) where {T}
    items = fetch(qs[1:min(something(qs.limit, 21), 21)])
    print(io, "<QuerySet [", join([repr(x) for x in first(items, 20)], ", "), length(items) > 20 ? ", ...(remaining elements truncated)..." : "", "]>")
end
tattr(qs::QuerySet, ::Val{:count}) = count(qs)
tattr(qs::QuerySet, ::Val{:all}) = qs
tattr(qs::QuerySet, ::Val{:exists}) = exists(qs)
tattr(qs::QuerySet, ::Val{:first}) = first(qs)
tattr(qs::QuerySet, ::Val{:last}) = last(qs)
