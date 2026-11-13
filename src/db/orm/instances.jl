# --- instance operations ----------------------------------------------------------------

"""
    save!(obj) -> obj

INSERT (when `obj.id === nothing`) or UPDATE the object. Sets `auto_now` /
`auto_now_add` timestamps.
"""
function save!(obj::T; db = nothing) where {T<:Model}
    alias = write_db(obj, db)
    with_db(alias) do
        check_relations_db(obj)
        save_here!(obj)
        set_instance_db!(obj)
    end
end

"Where to write an object: `db`, else the enclosing `using_db` block, else where it came from, else the routers."
write_db(obj::Model, db) = db !== nothing ? db : db_pinned() ? nothing : something(instance_db(obj), routed_db(typeof(obj), true), Some(nothing))

"Refuse to save an object whose related objects (already loaded) live in another database."
function check_relations_db(obj::Model)
    me = current_alias()
    for (k, v) in getfield(obj, :_cache)
        v isa Model || continue
        other = instance_db(v)
        (other === nothing || other == me) && continue
        ok = ask_routers(allow_relation, obj, v)
        ok === true && continue
        throw(ArgumentError("$(nameof(typeof(obj))).$k is an object from database '$other'; this one is saved to '$me' " *
                            "(a router's allow_relation can permit it)"))
    end
end

function save_here!(obj::T) where {T<:Model}
    data = getfield(obj, :_data)
    ts = timezone_now()
    for f in all_fields(T)
        a = attname(f)
        if f.auto_now || (f.auto_now_add && (data[:id] === nothing || get(data, a, missing) === nothing))
            data[a] = auto_now_value(f, ts)
        end
    end
    created = data[:id] === nothing
    has_receivers(pre_save, T) && send(pre_save, T; instance = obj, created = created)
    store_uploaded_files!(obj, data)
    chain_ = reverse(vcat([concrete_model(T)], ancestors(T)))     # root table first
    fresh = false
    if data[:id] === nothing && pk_kind(T) === :uuid
        data[:id] = uuid4()           # UUID keys are made here, so the row is inserted directly
        fresh = true
    end
    length(chain_) == 1 ? save_table!(chain_[1], data, true, fresh) :
        atomic(() -> foreach(M -> save_table!(M, data, M === chain_[1], fresh), chain_))
    refresh_computed!(obj)
    has_receivers(post_save, T) && send(post_save, T; instance = obj, created = created)
    obj
end

"Read back the values the database computed: generated fields, and db_default fields just filled in."
function refresh_computed!(obj::T) where {T<:Model}
    data = getfield(obj, :_data)
    fs = [f for f in all_fields(T) if f.generated !== nothing || get(data, attname(f), nothing) === DB_DEFAULT]
    isempty(fs) && return obj
    for tbl in unique(modelmeta(f.model).table for f in fs)
        mine = [f for f in fs if modelmeta(f.model).table == tbl]
        row = execute("SELECT " * join([qname(column(f)) for f in mine], ", ") * " FROM $(qname(tbl)) WHERE $(qname("id")) = ?", [data[:id]])
        isempty(row) && continue
        for f in mine
            data[attname(f)] = from_db(f, row[1][Symbol(column(f))])
        end
    end
    obj
end

"Write the columns of one table (`M`'s own fields) for an object's data."
function save_table!(M::Type, data, root::Bool, fresh::Bool = false)
    meta = modelmeta(M)
    # deferred fields keep their stored values; generated and not-yet-filled db_default ones are the database's
    fields = [f for f in meta.fields if haskey(data, attname(f)) && f.generated === nothing && data[attname(f)] !== DB_DEFAULT]
    cols = [qname(column(f)) for f in fields]
    vals = Any[to_db(f, data[attname(f)]) for f in fields]
    tbl = qname(meta.table)
    if is_composite(M)
        # Like a changed primary key elsewhere: saving under a new key writes a new row.
        key = composite_pk(M, data)
        key === nothing && throw(ArgumentError("$(nameof(M)): every part of the composite primary key needs a value"))
        if data[:id] !== nothing          # loaded or saved before: UPDATE, else (no such row) INSERT
            cond = join([qname(column(f)) * " = ?" for f in pk_fields(M)], " AND ")
            n = execute_changes("UPDATE $tbl SET " * join(["$c = ?" for c in cols], ", ") * " WHERE $cond", vcat(vals, collect(Any, key)))
            n > 0 && (data[:id] = key; return)
        end
        execute_changes(insert_sql(backend(), tbl, cols) |> s -> replace(s, r" RETURNING .*$" => ""), vals)
        data[:id] = composite_pk(M, data)
        return
    end
    if fresh
        execute(insert_sql(backend(), tbl, vcat(qname("id"), cols)) |> s -> replace(s, r" RETURNING .*$" => ""),
                vcat(data[:id], vals))
        return
    end
    if data[:id] !== nothing
        n = isempty(cols) ? length(execute("SELECT 1 FROM $tbl WHERE $(qname("id")) = ?", [data[:id]])) :
            execute_changes("UPDATE $tbl SET " * join(["$c = ?" for c in cols], ", ") * " WHERE $(qname("id")) = ?",
                            vcat(vals, data[:id]))
        n > 0 && return
        execute_insert(insert_sql(backend(), tbl, vcat(qname("id"), cols)), vcat(data[:id], vals))
        root && sync_sequence(backend(), meta.table)
        return
    end
    root || error("internal: child table saved before its parent")
    data[:id] = execute_insert(insert_sql(backend(), tbl, cols), vals)
end

"Delete the object (and cascade to related objects)."
function Base.delete!(obj::T; db = nothing) where {T<:Model}
    id = obj.id
    id === nothing && error("cannot delete an unsaved $(T)")
    with_db(() -> atomic(() -> delete_ids!(T, [id])), write_db(obj, db))
    getfield(obj, :_data)[:id] = nothing
    obj
end

"Reload field values from the database."
function refresh!(obj::T) where {T<:Model}
    db = instance_db(obj)
    fresh = with_db(() -> get(base_objects(T); id = obj.id), db)
    merge!(getfield(obj, :_data), getfield(fresh, :_data))
    empty!(getfield(obj, :_cache))
    db === nothing || (getfield(obj, :_cache)[:__db] = db)
    obj
end

"Create and save a new object."
create(::Type{T}; kw...) where {T<:Model} = save!(T(; kw...))

"`(obj, created::Bool)` — fetch by lookups or create with lookups + `defaults`."
function get_or_create(::Type{T}; defaults = Dict{Symbol,Any}(), kw...) where {T<:Model}
    atomic() do
        o = first(filter(objects(T); kw...))
        o === nothing || return (o, false)
        (create(T; kw..., pairs_of(defaults)...), true)
    end
end

"`(obj, created::Bool)` — update the object matching lookups with `defaults`, or create it."
function update_or_create(::Type{T}; defaults = Dict{Symbol,Any}(), kw...) where {T<:Model}
    atomic() do
        o = first(filter(objects(T); kw...))
        o === nothing && return (create(T; kw..., pairs_of(defaults)...), true)
        for (k, v) in pairs_of(defaults)
            setproperty!(o, Symbol(k), v)
        end
        (save!(o), false)
    end
end

# --- validation --------------------------------------------------------------------------

const EMAIL_RE = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
const SLUG_RE = r"^[-a-zA-Z0-9_]+$"
const URL_RE = r"^https?://[^\s/$.?#].[^\s]*$"i

"The value an `auto_now` field gets: the timestamp, or its date or time in the current time zone."
function auto_now_value(f::Field, ts)
    f.kind in (:date, :time) || return ts
    local_ = ts isa TimeZones.ZonedDateTime ? make_naive(ts) : ts
    f.kind === :date ? Date(local_) : Dates.Time(local_)
end

"The `step` of a number input for a decimal with `places` digits after the point (\"0.01\")."
decimal_step(places) = places === nothing ? "any" : places == 0 ? "1" : "0." * "0"^(places - 1) * "1"

"Django's DecimalValidator: too many digits in total, after the point, or before it."
function decimal_errors(f::Field, v)
    d = v isa Decimal ? v : something(tryparse(Decimal, string(v)), Some(nothing))
    d === nothing && return [gettext("Enter a number.")]
    digits, decimals = decimal_digits(d)
    md, dp = f.max_digits, f.decimal_places
    if md !== nothing && digits > md
        return [interpolate(ngettext("Ensure that there are no more than %(max)s digit in total.",
                                     "Ensure that there are no more than %(max)s digits in total.", md), Dict("max" => md))]
    elseif dp !== nothing && decimals > dp
        return [interpolate(ngettext("Ensure that there are no more than %(max)s decimal place.",
                                     "Ensure that there are no more than %(max)s decimal places.", dp), Dict("max" => dp))]
    elseif md !== nothing && dp !== nothing && digits - decimals > md - dp
        return [interpolate(ngettext("Ensure that there are no more than %(max)s digit before the decimal point.",
                                     "Ensure that there are no more than %(max)s digits before the decimal point.", md - dp),
                            Dict("max" => md - dp))]
    end
    String[]
end

"""
Run per-field validation on a cleaned (typed) value; returns a vector of messages.
Validators are functions `v -> true/nothing` (ok) or an error message `String` / `false`.
"""
function validate_field(f::Field, v)
    errs = String[]
    isempty_val = v === nothing || (v isa AbstractString && isempty(v))
    if isempty_val
        (!f.blank && f.kind !== :bool) && push!(errs, gettext("This field is required."))
        return errs
    end
    if f.max_length !== nothing && v isa AbstractString && length(v) > f.max_length
        push!(errs, interpolate(gettext("Ensure this value has at most %(max)d characters (it has %(len)d)."), Dict("max" => f.max_length, "len" => length(v))))
    end
    f.kind === :email && !occursin(EMAIL_RE, string(v)) && push!(errs, gettext("Enter a valid email address."))
    f.kind === :slug && !occursin(SLUG_RE, string(v)) && push!(errs, gettext("Enter a valid “slug” consisting of letters, numbers, underscores or hyphens."))
    f.kind === :url && !occursin(URL_RE, string(v)) && push!(errs, gettext("Enter a valid URL."))
    f.kind === :decimal && append!(errs, decimal_errors(f, v))
    if f.choices !== nothing && !any(c -> value_eq(c.first, v) || string(c.first) == string(v), f.choices)
        push!(errs, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v)))
    end
    for val in f.validators
        r = val(v)
        r isa AbstractString && push!(errs, r)
        r === false && push!(errs, gettext("Enter a valid value."))
    end
    errs
end

"""
    full_clean(obj; exclude=Symbol[]) -> Dict{Symbol,Vector{String}}

Validate an instance against its field definitions (required, max_length,
choices, email/slug/url format, custom validators, uniqueness). Empty dict = valid.
"""
function full_clean(obj::T; exclude = Symbol[]) where {T<:Model}
    errors = Dict{Symbol,Vector{String}}()
    for f in all_fields(T)
        (f.name in exclude || !f.editable) && continue
        v = getproperty(obj, attname(f))
        v === DB_DEFAULT && continue                  # the database supplies it
        errs = validate_field(f, v)
        if isempty(errs) && f.unique && v !== nothing
            q = filter(base_objects(f.model), Q(attname(f) => v))
            obj.id === nothing || (q = filter(q, !Q(id = obj.id)))
            exists(q) && push!(errs, interpolate(gettext("%(model)s with this %(field)s already exists."), Dict("model" => uppercasefirst(string(modelmeta(T).verbose_name)), "field" => label(f))))
        end
        isempty(errs) || (errors[f.name] = errs)
    end
    # constraints and unique_together, when their fields are clean and not excluded
    skip = Set(string.(union(exclude, keys(errors))))
    values = Dict{Symbol,Any}(f.name => field_data(obj, attname(f)) for f in all_fields(T) if !(string(f.name) in skip))
    errs = vcat(unique_together_errors(T, values, obj.id), constraint_errors(T, values, obj.id))
    isempty(errs) || append!(get!(errors, :__all__, String[]), errs)
    errors
end

"Messages for `Meta(unique_together = ...)` sets that `values` would duplicate."
function unique_together_errors(::Type{T}, values, id) where {T<:Model}
    errs = String[]
    for u in modelmeta(T).unique_together
        all(n -> haskey(values, n), u) || continue
        vals = [values[n] isa Model ? values[n].id : values[n] for n in u]
        any(isnothing, vals) && continue
        qs = filter(base_objects(T), Q(:AND, Any[n => v for (n, v) in zip(u, vals)], false))
        id === nothing || (qs = filter(qs, !Q(id = id)))
        exists(qs) && push!(errs, interpolate(gettext("%(model)s with this %(fields)s already exists."),
            Dict("model" => uppercasefirst(string(modelmeta(T).verbose_name)),
                 "fields" => join([label(findfield(modelmeta(T), n)) for n in u], " and "))))
    end
    errs
end
