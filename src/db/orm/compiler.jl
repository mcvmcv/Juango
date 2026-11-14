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
end
Base.@nospecializeinfer function SQLCompiler(@nospecialize(T::Type); outer = nothing)
    table = modelmeta(T).table
    counter = outer === nothing ? Ref(0) : outer.counter
    c = SQLCompiler(T, table, table, String[], Dict{Any,String}(), Set{String}(), counter, false, 0,
                    Dict{Symbol,Any}(), false, outer, false, Any[], 0)
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
        return related_model(f), "id", column(f), false
    end
    find_m2m_query(T, rel) === nothing ||
        throw(ArgumentError("FilteredRelation('$rel'): many-to-many relations are not supported; filter the through model"))
    r = find_reverse(T, rel)
    r === nothing && throw(lookup_error(T, rel))
    _, M, rf = r
    M, column(rf), "id", true
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
            string(something(rf.related_query_name, Symbol(lowercase(modelmeta(M).name)))) == name) && return (rn, M, rf)
    end
    nothing
end

function lookup_error(T, fname)
    meta = modelmeta(T)
    names = join(vcat(["id"], [string(x.name) for x in meta.fields], [string(r[1]) for r in reverse_relations(T)]), ", ")
    LookupError("cannot resolve keyword '$fname' into a field of $T. Choices are: $names")
end

"Compile one `field__path__lookup = value` against model `T` whose table is reachable as `alias`."
Base.@nospecializeinfer function compile_lookup(c::SQLCompiler, alias, @nospecialize(T::Type), key, @nospecialize(value), negated::Bool)
    parts = split(string(key), "__")
    lookup = "exact"
    (length(parts) > 1 && is_lookup_name(parts[end])) && (lookup = String(pop!(parts)))
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
    else
        f = findfield(meta, Symbol(fname))
        if f === nothing && (mm = find_m2m_query(T, fname)) !== nothing
            # tags__name on Post -> through the join model: +post_tags_src__tag__name
            step1, step2 = m2m_path(mm[2], mm[3])
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
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, "id")))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lookup), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                return ("EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(qcol(a, column(rf))) = $(qcol(alias, "id")) AND $sql)", ps)
            end
            a = join!(c, alias, scope_key(c, alias, rn), modelmeta(M).table, column(rf), "id"; left = true)
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
            f.kind === :fk || throw(LookupError("'$fname' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
            if rest in (["id"], ["pk"])
                col = qcol(alias, column(f))     # author__id is just author_id: no join
            else
                R = related_model(f)
                subkey = join(vcat(rest, lookup), "__")
                if negated
                    a = new_alias!(c)
                    sql, ps = compile_lookup(c, a, R, subkey, value, negated)
                    return ("EXISTS (SELECT 1 FROM $(qname(modelmeta(R).table)) $(qname(a)) WHERE $(qcol(a, "id")) = $(qcol(alias, column(f))) AND $sql)", ps)
                end
                a = join!(c, alias, (alias, f.name), modelmeta(R).table, "id", column(f); left = f.null)
                return compile_lookup(c, a, R, subkey, value, negated)
            end
        else
            col = qcol(alias, column(f))
        end
    end
    conv(v) = v isa Model ? v.id : (f === nothing || f.kind === :fk ? dbparam(v) : to_db(f, v))
    f === nothing || (kind = f.kind)
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
    sql, ps = lookup_condition(c, col, lookup, value, conv)
    sql, isempty(colps) ? ps : vcat(colps, ps)
end

const COMPARISON_OPS = Dict("exact" => "=", "ne" => "!=", "gt" => ">", "gte" => ">=", "lt" => "<", "lte" => "<=")

Base.@nospecializeinfer function lookup_condition(c::SQLCompiler, col, lookup, @nospecialize(value), @nospecialize(conv))
    if value isa SearchQuery && lookup == "exact"
        q, qps = compile_expr(c, value)
        return "$col @@ $q", qps
    end
    if value isa Expression && lookup in ("exact", "ne", "gt", "gte", "lt", "lte", "iexact")
        vsql, vps = compile_expr(c, value)
        lookup == "iexact" && return ("LOWER($col) = LOWER($vsql)", vps)
        return ("$col $(COMPARISON_OPS[lookup]) ($vsql)", vps)
    end
    if lookup == "exact"
        value === nothing && return ("$col IS NULL", Any[])
        return ("$col = ?", Any[conv(value)])
    elseif lookup == "ne"
        value === nothing && return ("$col IS NOT NULL", Any[])
        return ("($col != ? OR $col IS NULL)", Any[conv(value)])
    elseif lookup in ("iexact", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith")
        return lookup_sql(backend(), Val(Symbol(lookup)), col, value)
    elseif lookup in ("gt", "gte", "lt", "lte")
        return ("$col $(COMPARISON_OPS[lookup]) ?", Any[conv(value)])
    elseif lookup in ("regex", "iregex")
        return regex_sql(backend(), col, string(value isa Regex ? value.pattern : value), lookup == "iregex")
    elseif lookup == "in"
        if value isa QuerySet
            sql, ps = value.values_fields === nothing ? subquery_sql(c, value; columns = nothing, idonly = true) :
                      subquery_sql(c, value)
            return ("$col IN ($(in_subquery(backend(), sql)))", ps)
        elseif value isa Subquery
            sql, ps = compile_expr(c, value)
            return ("$col IN $sql", ps)
        end
        vals = collect(value)
        isempty(vals) && return (sql_false(backend()), Any[])
        return ("$col IN (" * join(fill("?", length(vals)), ", ") * ")", Any[conv(v) for v in vals])
    elseif lookup == "isnull"
        return (truthy(value) ? "$col IS NULL" : "$col IS NOT NULL", Any[])
    elseif lookup == "range"
        lo, hi = value
        return ("$col BETWEEN ? AND ?", Any[conv(lo), conv(hi)])
    end
    throw(LookupError("unsupported lookup '$lookup'"))
end

Base.@nospecializeinfer function compile_q(c::SQLCompiler, alias, @nospecialize(T::Type), q::Q, negated::Bool)
    q.connector === :XOR && return compile_xor(c, alias, T, q)
    neg = negated ⊻ q.negated
    parts = String[]
    params = Any[]
    for ch in q.children
        sql, ps = ch isa Q ? compile_q(c, alias, T, ch, neg) :
                  ch isa Expression ? compile_expr(c, ch) :
                  compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
        push!(parts, sql)
        append!(params, ps)
    end
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
