# --- SQL compilation -----------------------------------------------------------------------
#
# A query compiles to `SELECT ... FROM base [JOIN ...] WHERE ...`. Lookups across relations
# (`author__name`, reverse `comment__body`) become JOINs:
#
# * Forward FKs: INNER JOIN when the FK is NOT NULL (every row has a match), LEFT OUTER JOIN
#   when it is nullable or hangs off a LEFT JOIN. One join per path, reused by the whole query.
# * Reverse FKs: LEFT OUTER JOIN, and the query becomes SELECT DISTINCT. As in Django,
#   conditions inside one filter() call share the join (one related row must satisfy all of
#   them) while separate filter() calls join again (each may be satisfied by a different row).
# * Under negation (`exclude`, `!Q`) relations compile to correlated EXISTS subqueries, so
#   `exclude(author__name="Ann")` keeps posts that have no author at all.
# * `rel__isnull` on a reverse relation is an EXISTS test (no join needed).

mutable struct SQLCompiler
    T::Type
    table::String               # the base table
    base::String                # its alias (the table name itself at top level)
    joins::Vector{String}
    aliases::Dict{Any,String}   # (parent alias, relation, scope) => alias
    leftjoined::Set{String}
    counter::Base.RefValue{Int}
    distinct::Bool
    scope::Any                  # filter() call index; :expr inside aggregates and Case conditions
    annotations::Dict{Symbol,Any}
    uses_aggregate::Bool        # set when a condition refers to an aggregate annotation (-> HAVING)
    outer::Union{Nothing,SQLCompiler}   # the enclosing query, for OuterRef
    uses_window::Bool           # set when a condition refers to a window annotation (-> wrapping query)
    join_params::Vector{Any}    # parameters in JOIN ... ON clauses (FilteredRelation conditions)
    reuse_upto::Int             # compiling an annotation made after this many filter() calls (0: none)
    outer_refs::Union{Nothing,Vector{String}}   # while compiling an annotation: the columns OuterRefs in it read here
    alias_names::Set{Symbol}    # annotations made by alias(): compiled where used, not selected (#207)
end
Base.@nospecializeinfer function SQLCompiler(@nospecialize(T::Type); outer = nothing)
    table = modelmeta(T).table
    counter = outer === nothing ? Ref(0) : outer.counter
    c = SQLCompiler(T, table, table, String[], Dict{Any,String}(), Set{String}(), counter, false, 0,
                    Dict{Symbol,Any}(), false, outer, false, Any[], 0, nothing, Set{Symbol}())
    outer === nothing || (c.base = new_alias!(c))   # subqueries alias their table: no clash with the outer one
    c
end

new_alias!(c::SQLCompiler) = (c.counter[] += 1; "j$(c.counter[])")

"""
The join key for a multi-valued relation `rn` from `alias`: each filter() call has its own joins
(scope = its index); expressions (annotations, aggregate conditions) use their own, except that an
annotation made after filter() calls reuses the latest of their joins of the same relation.
"""
function scope_key(c::SQLCompiler, alias, rn)
    c.scope === :expr || return (alias, rn, c.scope)
    for k in c.reuse_upto:-1:1
        key = (alias, rn, k)
        haskey(c.aliases, key) && return key
    end
    (alias, rn, :expr)
end
qcol(alias, col) = qname(alias) * "." * qname(col)

"Join `table` (as a new alias) to `parent` on child.`childcol` = parent.`parentcol`; reuse an existing join for `key`."
function join!(c::SQLCompiler, parent, key, table, childcol, parentcol; left::Bool, extra_on = nothing)
    haskey(c.aliases, key) && return c.aliases[key]
    a = new_alias!(c)
    left = left || parent in c.leftjoined
    left && push!(c.leftjoined, a)
    on = "$(qcol(a, childcol)) = $(qcol(parent, parentcol))" * (extra_on === nothing ? "" : " AND " * extra_on(a))
    push!(c.joins, " $(left ? "LEFT OUTER" : "INNER") JOIN $(qname(table)) $(qname(a)) ON $on")
    c.aliases[key] = a
end

"Strip `prefix__` from the lookups of a FilteredRelation condition."
function strip_relation(q::Q, prefix::AbstractString, rel::AbstractString)
    kids = Any[]
    for ch in q.children
        if ch isa Q
            push!(kids, strip_relation(ch, prefix, rel))
        elseif ch isa Pair
            k = string(ch.first)
            startswith(k, prefix) ||
                throw(ArgumentError("FilteredRelation condition '$k' must start with the relation name '$rel'"))
            push!(kids, Symbol(chopprefix(k, prefix)) => ch.second)
        else
            throw(ArgumentError("FilteredRelation conditions must be lookups, not $(typeof(ch))"))
        end
    end
    Q(q.connector, kids, q.negated)
end

"""
The relation of FilteredRelation annotation `name` on `T`: `(model, related column, base column)`,
joined as related.col = base.col.
"""
Base.@nospecializeinfer function filtered_target(@nospecialize(T::Type), fr)
    rel = fr.relation
    occursin("__", rel) && throw(ArgumentError("FilteredRelation('$rel'): nested relations are not supported"))
    f = findfield(modelmeta(T), Symbol(rel))
    if f !== nothing
        f.kind === :fk || throw(ArgumentError("FilteredRelation('$rel'): '$rel' is not a relation of $T"))
        modelmeta(f.model).table == modelmeta(T).table ||
            throw(ArgumentError("FilteredRelation('$rel'): relations inherited from a parent model are not supported"))
        return related_model(f), target_column(f), column(f), false
    end
    find_m2m_query(T, rel) === nothing ||
        throw(ArgumentError("FilteredRelation('$rel'): many-to-many relations are not supported; filter the through model"))
    r = find_reverse(T, rel)
    r === nothing && throw(lookup_error(T, rel))
    _, M, rf = r
    M, column(rf), target_column(rf), true
end

"""
Join FilteredRelation annotation `name` (once per query) and return `(alias, model)`. The
condition goes in the ON clause, so rows of the base model without a match survive
(LEFT JOIN) and aggregates see only matching related rows.
"""
Base.@nospecializeinfer function filtered_join!(c::SQLCompiler, alias, @nospecialize(T::Type), name::Symbol)
    key = (alias, :__filtered, name)
    fr = c.annotations[name]::FilteredRelation
    M, childcol, parentcol, reverse = filtered_target(T, fr)
    reverse && c.scope !== :expr && c.scope != 0 && (c.distinct = true)
    haskey(c.aliases, key) && return c.aliases[key], M
    a = new_alias!(c)
    njoins = length(c.joins)
    csql, cps = compile_q(c, a, M, strip_relation(fr.condition, fr.relation * "__", fr.relation), false)
    length(c.joins) == njoins ||
        throw(ArgumentError("FilteredRelation('$(fr.relation)'): the condition may only use $(nameof(M))'s own fields"))
    push!(c.leftjoined, a)
    push!(c.joins, " LEFT OUTER JOIN $(qname(modelmeta(M).table)) $(qname(a)) ON $(qcol(a, childcol)) = $(qcol(alias, parentcol)) AND $csql")
    append!(c.join_params, cps)
    c.aliases[key] = a
    a, M
end

"""
Alias of the table holding field `f` when querying `T` at `alias`: `alias` itself, or a
join up the multi-table inheritance chain.
"""
function field_alias!(c::SQLCompiler, alias, T::Type, f::Field)
    target = modelmeta(f.model).table
    A = concrete_model(T)
    while modelmeta(A).table != target
        P = table_parent(A)
        P === nothing && error("field $(f.name) does not belong to $T")
        alias = join!(c, alias, (alias, :__parent), modelmeta(P).table, "id", "id"; left = alias in c.leftjoined)
        A = P
    end
    alias
end

Base.@nospecializeinfer function find_reverse(@nospecialize(T::Type), name)
    for (rn, M, rf) in reverse_relations(T)
        (string(rn) == name || !startswith(string(rn), "+") &&
            string(something(rf.related_query_name, rf.related_name === nothing ? default_related_name(M) : nothing,
                             Symbol(lowercase(modelmeta(M).name)))) == name) && return (rn, M, rf)
    end
    nothing
end

function lookup_error(T, fname)
    meta = modelmeta(T)
    names = join(vcat(["id"], [string(x.name) for x in meta.fields], [string(r[1]) for r in reverse_relations(T)]), ", ")
    LookupError("cannot resolve keyword '$fname' into a field of $T. Choices are: $names")
end

"""
The model at the end of the relation path `parts` from `T` (foreign keys, many-to-many and
reverse relations), or `nothing` when some part isn't a relation.
"""
Base.@nospecializeinfer function relation_target(@nospecialize(T::Type), parts)
    M = T
    for p in parts
        f = findfield(modelmeta(M), Symbol(p))
        if f !== nothing
            f.kind === :fk || return nothing
            M = related_model(f)
        elseif (mm = find_m2m_query(M, p)) !== nothing
            M = mm[3] ? related_model(mm[2]) : mm[2].model
        elseif (r = find_reverse(M, p)) !== nothing
            M = r[2]
        else
            return nothing
        end
    end
    M
end

"""
Whether the last part of a lookup key is a lookup (`season__year__gt`) rather than a field of the
related model that has a lookup's name (`season__gt`, when Season has a field `gt`): Django
resolves the field first (#197).
"""
Base.@nospecializeinfer function ends_in_lookup(@nospecialize(T::Type), parts)
    (length(parts) > 1 && is_lookup_name(parts[end])) || return false
    R = relation_target(T, @view parts[1:end-1])
    R === nothing || findfield(modelmeta(R), Symbol(parts[end])) === nothing
end

"Compile one `field__path__lookup = value` against model `T` whose table is reachable as `alias`."
Base.@nospecializeinfer function compile_lookup(c::SQLCompiler, alias, @nospecialize(T::Type), key, @nospecialize(value), negated::Bool)
    parts = split(string(key), "__")
    lookup = "exact"
    ends_in_lookup(T, parts) && (lookup = String(pop!(parts)))
    # inside an aggregate's filter or a Case condition, ~Q(store__name = "x") is a condition on the joined
    # row (Django's FILTER (WHERE NOT ...)), not exclude()'s "no related row matches" subquery
    c.scope === :expr && (negated = false)
    lookup == "isnull" && !(value isa Bool) &&
        throw(ArgumentError("the value for an isnull lookup must be true or false, not $(repr(value)) ($key)"))
    meta = modelmeta(T)
    fname = parts[1] == "pk" ? "id" : String(parts[1])
    rest = String.(parts[2:end])
    f = nothing
    colps = Any[]
    kind = nothing                     # the compared value's field kind, for custom lookups
    if alias == c.base && is_filtered_relation(get(c.annotations, Symbol(fname), nothing))
        subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
        if negated
            # exclude(): no matching related row, as an EXISTS over the filtered relation
            fr = c.annotations[Symbol(fname)]::FilteredRelation
            M, childcol, parentcol, _ = filtered_target(T, fr)
            a = new_alias!(c)
            csql, cps = compile_q(c, a, M, strip_relation(fr.condition, fr.relation * "__", fr.relation), false)
            sql, ps = compile_lookup(c, a, M, subkey, value, negated)
            return ("EXISTS (SELECT 1 FROM $(qname(modelmeta(M).table)) $(qname(a)) WHERE $(qcol(a, childcol)) = $(qcol(alias, parentcol)) AND $csql AND $sql)",
                    vcat(cps, ps))
        end
        a, M = filtered_join!(c, alias, T, Symbol(fname))
        return compile_lookup(c, a, M, subkey, value, negated)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname)) && contains_window(c.annotations[Symbol(fname)])
        # Window functions can't appear in WHERE: the query is wrapped and this compares the column.
        c.uses_window = true
        col = qname(fname)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname))
        a = c.annotations[Symbol(fname)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, colps = compile_expr(c, a)
        col = "($sql)"
    elseif fname == "id" && is_composite(T)
        isempty(rest) || throw(LookupError("'pk' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        fs = pk_fields(T)
        # a natural key (#221): pk is its field, with any lookup
        length(fs) == 1 && return compile_lookup(c, alias, T, Symbol(fs[1].name, "__", lookup), value isa Model ? value.pk : value, negated)
        part(tup) = (length(tup) == length(fs) || throw(ArgumentError("$(nameof(T)) has a $(length(fs))-part primary key; got $(repr(tup))"));
                     Q(:AND, Any[f.name => v for (f, v) in zip(fs, tup)], false))
        if lookup == "exact"
            value === nothing && return (sql_false(backend()), Any[])
            return compile_q(c, alias, T, part(value), negated)
        elseif lookup == "in"
            isempty(value) && return (sql_false(backend()), Any[])
            return compile_q(c, alias, T, Q(:OR, Any[part(t) for t in value], false), negated)
        elseif lookup == "isnull"
            return (truthy(value) ? sql_false(backend()) : sql_true(backend()), Any[])
        end
        throw(LookupError("composite primary keys support the pk, pk__in and pk__isnull lookups, not '$lookup'"))
    elseif fname == "id"
        isempty(rest) || throw(LookupError("'id' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        col = qcol(alias, "id")
        kind = pk_kind(T) === :uuid ? :uuid : :int
    else
        f = findfield(meta, Symbol(fname))
        if f === nothing && (mm = find_m2m_query(T, fname)) !== nothing
            # tags__name on Post -> through the join model: +post_tags_src__tag__name
            step1, step2 = m2m_path(mm[2], mm[3])
            isempty(rest) && lookup == "exact" && value === nothing && (lookup = "isnull"; value = true)   # tags = nothing: no link
            if isempty(rest) && lookup == "isnull"
                return compile_lookup(c, alias, T, string(step1, "__isnull"), value, negated)
            end
            return compile_lookup(c, alias, T, join(vcat([string(step1), string(step2)], rest, [lookup]), "__"), value, negated)
        end
        if f === nothing && (C = findfirst(C -> string(child_accessor(C)) == fname, child_models(T))) !== nothing
            # place -> restaurant (multi-table child): one-to-one join on id
            Cm = child_models(T)[C]
            ct = qname(modelmeta(Cm).table)
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $ct $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, "id")))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, Cm, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $ct $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, "id")) AND $sql)", ps)
            end
            a = join!(c, alias, (alias, child_accessor(Cm)), modelmeta(Cm).table, "id", "id"; left = true)
            return compile_lookup(c, a, Cm, subkey, value, negated)
        end
        if f === nothing && (g = find_generic(foreign_objects(T), fname)) !== nothing
            return compile_fobj_lookup(c, alias, g, related_model(g), rest, lookup, value, negated, false, (alias, g.name))
        end
        if f === nothing && (r = find_reverse_fobj(T, fname)) !== nothing
            return compile_fobj_lookup(c, alias, r[3], r[2], rest, lookup, value, negated, true, scope_key(c, alias, r[1]))
        end
        if f === nothing && (g = find_generic(generic_relations(T), fname)) !== nothing
            # post.comments (GenericRelation): join on object id AND content type
            M = related_model(g)
            ctf, fkf = g.through
            ctcol, fkcol = column(getfield_meta(M, ctf)), column(getfield_meta(M, fkf))
            ctid = get_for_model(T).id::Integer
            mt = qname(modelmeta(M).table)
            cond(a) = "$(qcol(a, fkcol)) = $(qcol(alias, "id")) AND $(qcol(a, ctcol)) = $ctid"
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)) AND $sql)", ps)
            end
            a = join!(c, alias, scope_key(c, alias, g.name), modelmeta(M).table, fkcol, "id"; left = true,
                      extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            c.distinct = true
            return compile_lookup(c, a, M, subkey, value, negated)
        end
        if f !== nothing && modelmeta(f.model).table != modelmeta(T).table
            # a field inherited from a multi-table parent: look it up on the parent's table
            P = table_parent(T)
            a = join!(c, alias, (alias, :__parent), modelmeta(P).table, "id", "id"; left = alias in c.leftjoined)
            return compile_lookup(c, a, P, key, value, negated)
        end
        if f === nothing
            rel = find_reverse(T, fname)
            rel === nothing && throw(lookup_error(T, fname))
            rn, M, rf = rel
            mt = qname(modelmeta(M).table)
            # children = nothing: no related row, as children__isnull = true (Django)
            isempty(rest) && lookup == "exact" && value === nothing && (lookup = "isnull"; value = true)
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, target_column(rf))))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, target_column(rf))) AND $sql)"
                # exclude(program__channel = nothing): with no related row at all the path is NULL, so the row
                # matches (and is excluded), as through Django's LEFT JOIN; the forward case is handled below too
                if (lookup == "isnull" && value === true) || (lookup == "exact" && value === nothing)
                    b = new_alias!(c)
                    ex = "(NOT EXISTS (SELECT 1 FROM $mt $(qname(b)) WHERE $(qcol(b, column(rf))) = $(qcol(alias, target_column(rf)))) OR $ex)"
                end
                return (ex, ps)
            end
            a = join!(c, alias, scope_key(c, alias, rn), modelmeta(M).table, column(rf), target_column(rf); left = true)
            rf.one_to_one || (c.distinct = true)               # (a reverse one-to-one can't repeat rows)
            return compile_lookup(c, a, M, subkey, value, negated)
        end
        if !isempty(rest) && f.kind in (:json, :hstore, :array)
            # data__owner__name (JSON key path), tags__len, tags__0
            tr = transform_column(f, qcol(alias, column(f)), rest, lookup, value)
            tr === nothing && throw(LookupError("unsupported lookup '$(join(rest, "__"))' on $(f.kind) field '$fname'"))
            col, colps = tr
            lookup == "isnull" && f.kind in (:json, :hstore) && return truthy(value) ? (col, colps) : ("NOT " * col, colps)
            f = nothing
        elseif !isempty(rest) && (tr = apply_transforms(qcol(alias, column(f)), f.kind, rest)) !== nothing
            col, kind = tr                  # registered transforms: name__lower__...
            kind === f.kind || (f = nothing)
        elseif !isempty(rest)
            f.kind === :fk || throw(LookupError("unsupported lookup '$(join(rest, "__"))' for $(f.kind) field '$fname'" *
                                                suggest_lookup(rest[1])))
            if rest == [string(target_name(f))] || (fk_to_field(f) === nothing && rest == ["pk"])
                col = qcol(alias, column(f))     # author__id is just author_id: no join
            else
                R = related_model(f)
                subkey = join(vcat(rest, lookup), "__")
                if negated
                    a = new_alias!(c)
                    sql, ps = compile_lookup(c, a, R, subkey, value, negated)
                    ex = "EXISTS (SELECT 1 FROM $(qname(modelmeta(R).table)) $(qname(a)) WHERE $(qcol(a, target_column(f))) = $(qcol(alias, column(f))) AND $sql)"
                    # exclude(parent__parent__isnull = true): with no parent, the path is NULL, so the row matches
                    # (and is excluded), as through Django's LEFT JOIN
                    if f.null && ((lookup == "isnull" && truthy(value)) || (lookup == "exact" && value === nothing))
                        ex = "($(qcol(alias, column(f))) IS NULL OR $ex)"
                    end
                    return (ex, ps)
                end
                a = join!(c, alias, (alias, f.name), modelmeta(R).table, target_column(f), column(f); left = f.null)
                return compile_lookup(c, a, R, subkey, value, negated)
            end
        else
            col = qcol(alias, column(f))
        end
    end
    # an object of another model, or text for a numeric key, is refused, as Django: it would compare
    # unrelated values (or none) without an error
    keymodel = f !== nothing && f.kind === :fk ? related_model(f) : f === nothing && fname == "id" ? T : nothing
    conv(v) = v isa Model ? saved_key(f !== nothing && f.kind === :fk ? target_value(f, check_model_type(keymodel, v)) :
                                      check_model_type(keymodel, v).id, v) :
              (f === nothing || f.kind === :fk ? dbparam(check_key_value(keymodel, f, v)) : to_db(f, check_number(f, v)))
    # food__in = filter(Food; ...), for a key with a to_field: the subquery selects that field (#220)
    f !== nothing && f.kind === :fk && fk_to_field(f) !== nothing && value isa QuerySet && value.values_fields === nothing &&
        (value = values(value, fk_to_field(f)))
    f === nothing || (kind = f.kind)
    f !== nothing && f.kind in INT_KINDS && value isa AbstractFloat && ((lookup, value) = int_float_bound(lookup, value))
    cl = isempty(CUSTOM_LOOKUPS) ? nothing : find_custom(CUSTOM_LOOKUPS, lookup, kind)
    if cl !== nothing
        if value isa Expression
            vsql, vps = compile_expr(c, value)
            return cl.sql(col, "(" * vsql * ")")::AbstractString, vcat(colps, vps)
        end
        return cl.sql(col, "?")::AbstractString, vcat(colps, Any[conv(cl.prepare(value))])
    end
    if f !== nothing || lookup == "search"
        sl = special_lookup(c, something(f, Field(:text)), col, lookup, value)
        sl === nothing || return sl[1], vcat(colps, sl[2])
    end
    # id__iexact = "12", gt__regex = "^4": a text lookup on a number, date or UUID column compares its text
    # (PostgreSQL has no LOWER(bigint) or integer ~ text; Django casts there too)
    if lookup in TEXT_LOOKUPS && kind !== nothing && !(kind in TEXT_KINDS)
        col = text_cast(backend(), col)
    end
    sql, ps = lookup_condition(c, col, lookup, value, conv)
    # Under exclude()/~Q, a NULL in a nullable column doesn't make the condition true, so the row is kept, as
    # Django does (NOT (x = 1) alone is NULL there and would drop it); a None in an __in list matches NULL
    if negated && !(lookup in ("isnull", "ne")) && !(lookup == "exact" && value === nothing)
        if f !== nothing && f.null
            sql = lookup == "in" && value isa Union{AbstractArray,Tuple,AbstractSet} && any(isnothing, value) ?
                  "($sql OR $col IS NULL)" : "($sql AND $col IS NOT NULL)"
        end
        # exclude(x = F(:y)) with y nullable: the same for the other side
        if value isa F && !occursin("__", value.name) && !haskey(c.annotations, Symbol(value.name))
            rf = findfield(modelmeta(c.T), Symbol(value.name))
            rf !== nothing && rf.null && (sql = "($sql AND $(first(compile_expr(c, value))) IS NOT NULL)")
        end
    end
    sql, isempty(colps) ? ps : vcat(colps, ps)
end

const TEXT_LOOKUPS = ("iexact", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith", "regex", "iregex")
const TEXT_KINDS = (:char, :text, :email, :slug, :url, :file, :image, :filepath, :citext)
const COMPARISON_OPS = Dict("exact" => "=", "ne" => "!=", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")

"""
An integer column compared with a float: the integer bound that gives the same rows, as Django rounds
(num__gte = 11.9 is num >= 12), so PostgreSQL isn't asked to read 11.9 as an integer.
"""
function int_float_bound(lookup, x::AbstractFloat)
    lookup in ("gt", "lte") && return lookup, Int(floor(x))
    lookup in ("gte", "lt") && return lookup, Int(ceil(x))
    lookup == "exact" && return isinteger(x) ? ("exact", Int(x)) : ("in", Any[])     # (11.5 equals no integer)
    lookup, x
end

"An object as a value for a key of model `R`: of `R`, a proxy of it, or a parent or child in its multi-table lineage."
function check_model_type(@nospecialize(R), @nospecialize(v::Model))
    R === nothing && return v
    a, b = concrete_model(R), concrete_model(typeof(v))
    (a === b || a in lineage(b) || b in lineage(a)) ||
        throw(ArgumentError("cannot query \"$v\": must be a $(nameof(R)) instance, not $(nameof(typeof(v)))"))
    v
end
"Text given for an automatic integer key: a number in text (\"12\") is accepted, anything else refused (Django's ValueError)."
function check_key_value(@nospecialize(R), f, v)
    (R === nothing || !(v isa AbstractString) || (f !== nothing && fk_to_field(f) !== nothing) || !is_auto_pk(pk_kind(R))) && return v
    n = tryparse(Int, strip(v))
    n === nothing && throw(ArgumentError("field 'id' expected a number but got $(repr(v))"))
    n
end
"Text for an integer field: a number in text is accepted, anything else refused (Django's ValueError)."
function check_number(f, v)
    (f !== nothing && f.kind in INT_KINDS && v isa AbstractString) || return v
    n = tryparse(Int, strip(v))
    n === nothing && throw(ArgumentError("field '$(f.name)' expected a number but got $(repr(v))"))
    n
end

"An object's key as a query value; an unsaved object is refused, as Django: it would compare with NULL."
saved_key(k, @nospecialize(v)) = k === nothing ?
    throw(ArgumentError("an unsaved $(nameof(typeof(v))) can't be used in a query: save it first")) : k

"A queryset used as a value: its primary keys, or the one field values() names (two are refused, as Django: #208)."
Base.@nospecializeinfer function one_column_subquery(c::SQLCompiler, @nospecialize(value))
    value.values_fields === nothing && return subquery_sql(c, value; columns = nothing, idonly = true)
    n = length(value.values_fields)
    n == 1 || throw(ArgumentError("a QuerySet used as a value must select one field, not $n ($(join(value.values_fields, ", ")))"))
    subquery_sql(c, value)
end

Base.@nospecializeinfer function lookup_condition(c::SQLCompiler, col, lookup, @nospecialize(value), @nospecialize(conv))
    value isa Q && (value = Condition(value))          # short = Q(qty__lt = F(:target)): the condition's value (#199)
    if value isa SearchQuery && lookup == "exact"
        q, qps = compile_expr(c, value)
        return "$col @@ $q", qps
    end
    if value isa Expression && lookup in ("exact", "ne", "gt", "gte", "lt", "lte", "iexact")
        vsql, vps = compile_expr(c, value)
        lookup == "iexact" && return ("LOWER($col) = LOWER($vsql)", vps)
        return ("$col $(COMPARISON_OPS[lookup]) ($vsql)", vps)
    end
    if value isa QuerySet && haskey(COMPARISON_OPS, lookup)
        # author = objects(Author)[1:1]: a subquery of one row (#208)
        value.limit == 1 ||
            throw(ArgumentError("a QuerySet as the value of a '$lookup' lookup must be sliced to one row (qs[1:1]); use __in for several"))
        sql, ps = one_column_subquery(c, value)
        return ("$col $(COMPARISON_OPS[lookup]) ($sql)", ps)
    end
    if lookup == "exact"
        value === nothing && return ("$col IS NULL", Any[])
        return ("$col = ?", Any[conv(value)])
    elseif lookup == "ne"
        value === nothing && return ("$col IS NOT NULL", Any[])
        return ("($col != ? OR $col IS NULL)", Any[conv(value)])
    elseif lookup in ("iexact", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith")
        if value isa Expression                     # name__startswith = Substr(:alias, 1, 3): compiled, not a string (#198)
            vsql, vps = compile_expr(c, value)
            sql, uses = expr_lookup_sql(backend(), lookup, col, "($vsql)")
            return sql, Any[p for _ in 1:uses for p in vps]
        end
        return lookup_sql(backend(), Val(Symbol(lookup)), col, value)
    elseif lookup in ("gt", "gte", "lt", "lte")
        return ("$col $(COMPARISON_OPS[lookup]) ?", Any[conv(value)])
    elseif lookup in ("regex", "iregex")
        if value isa Expression                     # name__regex = Subquery(...): compiled, not a string (#198)
            vsql, vps = compile_expr(c, value)
            return regex_expr_sql(backend(), col, "($vsql)", lookup == "iregex"), vps
        end
        return regex_sql(backend(), col, string(value isa Regex ? value.pattern : value), lookup == "iregex")
    elseif lookup == "in"
        if value isa QuerySet
            sql, ps = one_column_subquery(c, value)
            return ("$col IN ($(in_subquery(backend(), sql)))", ps)
        elseif value isa Subquery
            sql, ps = compile_expr(c, value)
            return ("$col IN $sql", ps)
        end
        vals = Any[v for v in value if v !== nothing]      # NULL never matches IN: Django drops None
        isempty(vals) && return (sql_false(backend()), Any[])
        if any(v -> v isa Expression, vals)                # [F(:x) - 10, Value(2), 3]: expressions compiled (#198)
            parts, ps = String[], Any[]
            for v in vals
                if v isa Expression
                    vsql, vps = compile_expr(c, v); push!(parts, "($vsql)"); append!(ps, vps)
                else
                    push!(parts, "?"); push!(ps, conv(v))
                end
            end
            return ("$col IN (" * join(parts, ", ") * ")", ps)
        end
        return ("$col IN (" * join(fill("?", length(vals)), ", ") * ")", Any[conv(v) for v in vals])
    elseif lookup == "isnull"
        return (truthy(value) ? "$col IS NULL" : "$col IS NOT NULL", Any[])
    elseif lookup == "range"
        lo, hi = value
        bound(v) = v isa Expression ? (vs = compile_expr(c, v); ("($(vs[1]))", vs[2])) : ("?", Any[conv(v)])
        (ls, lps), (hs, hps) = bound(lo), bound(hi)
        return ("$col BETWEEN $ls AND $hs", vcat(lps, hps))
    end
    throw(LookupError("unsupported lookup '$lookup'"))
end

empty_q(q::Q) = all(ch -> ch isa Q && empty_q(ch), q.children)
Base.@nospecializeinfer function compile_q(c::SQLCompiler, alias, @nospecialize(T::Type), q::Q, negated::Bool)
    # Q(), ~Q() and combinations of them only (~Q() & ~Q()) match every row: Django drops empty Qs
    empty_q(q) && return (sql_true(backend()), Any[])
    q.connector === :XOR && return compile_xor(c, alias, T, q)
    neg = negated ⊻ q.negated
    parts = String[]
    params = Any[]
    outer = c.scope
    # an empty Q among others drops out (Q(x) | Q() is Q(x)), as Django combines them
    kids = any(ch -> ch isa Q && empty_q(ch), q.children) ? Any[ch for ch in q.children if !(ch isa Q && empty_q(ch))] : q.children
    for (i, ch) in enumerate(kids)
        # :SCOPES (the where clauses of a queryset combined with |): each child is one filter() call, with
        # its own joins of multi-valued relations, as it had in its queryset
        q.connector === :SCOPES && c.scope !== :expr && (c.scope = (outer, i))
        sql, ps = ch isa Q ? compile_q(c, alias, T, ch, neg) :
                  ch isa Expression ? compile_expr(c, ch) :
                  compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
        push!(parts, sql)
        append!(params, ps)
    end
    c.scope = outer
    sql = isempty(parts) ? sql_true(backend()) : "(" * join(parts, q.connector === :OR ? " OR " : " AND ") * ")"
    q.negated ? "NOT $sql" : sql, params
end

"""
    Prefetch(lookup; queryset=nothing, to_attr=nothing)

A `prefetch_related` lookup with a custom queryset for the related objects, optionally
stored under another attribute name (as a plain `Vector`).
"""
struct Prefetch
    path::String
    queryset::Any
    to_attr::Union{Nothing,Symbol}
end
Prefetch(path; queryset = nothing, to_attr = nothing) =
    Prefetch(string(path), queryset, to_attr === nothing ? nothing : Symbol(to_attr))

"Related objects fetched by `prefetch_related`, kept in an instance's cache."
struct PrefetchedList
    items::Vector
end

# XOR as Django's rewrite on every database, an odd count of true operands: MySQL's own XOR is NULL
# when an operand is NULL, where this counts it as false, so results are the same everywhere
Base.@nospecializeinfer function compile_xor(c::SQLCompiler, alias, @nospecialize(T::Type), q::Q)
    parts = String[]
    params = Any[]
    for ch in q.children
        sql, ps = ch isa Q ? compile_q(c, alias, T, ch, false) :
                  ch isa Expression ? compile_expr(c, ch) :
                  compile_lookup(c, alias, T, Symbol(ch.first), ch.second, false)
        push!(parts, sql)
        append!(params, ps)
    end
    sql = xor_sql(backend(), parts)
    q.negated ? "NOT $sql" : sql, params
end
xor_sql(::DatabaseBackend, parts) = "((" * join(["CASE WHEN $p THEN 1 ELSE 0 END" for p in parts], " + ") * ") % 2 = 1)"
