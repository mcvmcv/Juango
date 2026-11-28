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
    expr_negated::Bool          # compiling a negated lookup inside a Case/aggregate condition (its NULL guard)
    fr_override::Vector{Any}    # compiling a FilteredRelation's condition: (alias, relation path, its join's alias, model)
    fr_models::Dict{Any,Any}    # FilteredRelation join key => its model
    qualify::Union{Nothing,Set{Symbol}}   # recompiling a condition on a window for the wrapping query: the annotations it reads
    having::Bool                # compiling a HAVING condition
    having_cols::Vector{String} # the joined columns its non-aggregate conditions read: grouped by too, as Django
    compiling::Vector{Symbol}   # the annotations being compiled: in its own expression, a name is the field (values(...);
                                # friends = Count("friends"))
end
Base.@nospecializeinfer function SQLCompiler(@nospecialize(T::Type); outer = nothing)
    table = modelmeta(T).table
    counter = outer === nothing ? Ref(0) : outer.counter
    c = SQLCompiler(T, table, table, String[], Dict{Any,String}(), Set{String}(), counter, false, 0,
                    Dict{Symbol,Any}(), false, outer, false, Any[], 0, nothing, Set{Symbol}(), false, Any[], Dict{Any,Any}(), nothing, false, String[], Symbol[])
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
function join!(c::SQLCompiler, parent, key, table, childcol, parentcol; left::Bool, extra_on = nothing, as_text::Bool = false)
    haskey(c.aliases, key) && return c.aliases[key]
    a = new_alias!(c)
    left = left || parent in c.leftjoined
    left && push!(c.leftjoined, a)
    pref = as_text ? "CAST($(qcol(parent, parentcol)) AS $(cast_type(backend(), :text)))" : qcol(parent, parentcol)
    on = "$(qcol(a, childcol)) = $pref" * (extra_on === nothing ? "" : " AND " * extra_on(a))
    push!(c.joins, " $(left ? "LEFT OUTER" : "INNER") JOIN $(qname(table)) $(qname(a)) ON $on")
    c.aliases[key] = a
end

"""
One step of a FilteredRelation's path from `M` at `alias`: LEFT JOIN relation `seg` (a foreign key, reverse
relation or generic relation; many-to-many ones are split into their two steps first) and return
`(alias, model, multi)`. `on(alias, model)`, when given, adds SQL to the ON clause.
"""
Base.@nospecializeinfer function fr_step!(c::SQLCompiler, alias, @nospecialize(M::Type), seg::AbstractString, key; on = nothing)
    f = findfield(modelmeta(M), Symbol(seg))
    if f !== nothing && f.kind === :fk
        alias = field_alias!(c, alias, M, f)
        R = related_model(f)
        return join!(c, alias, key, modelmeta(R).table, target_column(f), column(f); left = true,
                     extra_on = on === nothing ? nothing : (x -> on(x, R))), R, false
    end
    g = f === nothing ? find_generic(generic_relations(M), seg) : nothing
    if g !== nothing
        R = related_model(g)
        ctf, fkf = g.through
        ctcol, ctid = column(getfield_meta(R, ctf)), generic_ct(M, g).id::Integer
        return join!(c, alias, key, modelmeta(R).table, column(getfield_meta(R, fkf)), owner_pk_column(M); left = true,
                     as_text = getfield_meta(R, fkf).kind in STRING_KINDS, extra_on = x -> "$(qcol(x, ctcol)) = $ctid" * (on === nothing ? "" : " AND " * on(x, R))), R, true
    end
    r = f === nothing ? find_reverse(M, seg) : nothing
    r === nothing && throw(lookup_error(M, seg))
    _, R, rf = r
    join!(c, alias, key, modelmeta(R).table, column(rf), target_column(rf); left = true,
          extra_on = on === nothing ? nothing : (x -> on(x, R))), R, true
end

"A FilteredRelation's path from `M` as join steps: many-to-many relations become their two steps (via the through model)."
Base.@nospecializeinfer function fr_segments(@nospecialize(M::Type), parts)
    segs, ends = String[], Int[]           # (ends: each part's last step)
    for p in parts
        mm = findfield(modelmeta(M), Symbol(p)) === nothing ? find_m2m_query(M, p) : nothing
        if mm !== nothing
            s1, s2 = m2m_path(mm[2], mm[3])
            push!(segs, string(s1), string(s2))
        else
            push!(segs, String(p))
        end
        push!(ends, length(segs))
        M = fr_target(M, p)
        M === nothing && break
    end
    segs, ends
end
"The model relation `p` of `M` leads to (generic relations too), or nothing."
Base.@nospecializeinfer function fr_target(@nospecialize(M::Type), p)
    R = relation_target(M, [p])
    R !== nothing && return R
    g = find_generic(generic_relations(M), p)
    g === nothing ? nothing : related_model(g)
end

"""
Join FilteredRelation annotation `name` (once per query) and return `(alias, model)`. The
condition goes in the last join's ON clause, so rows of the base model without a match survive
(LEFT JOIN) and aggregates see only matching related rows. It is compiled against the base model,
with the relation's path standing for this join (Django's filtered relation).
"""
Base.@nospecializeinfer function filtered_join!(c::SQLCompiler, alias, @nospecialize(T::Type), name::Symbol)
    key = (alias, :__filtered, name)
    haskey(c.aliases, key) && return c.aliases[key], c.fr_models[key]
    fr = c.annotations[name]::FilteredRelation
    parts = String.(split(fr.relation, "__"))
    a, M, rest = alias, T, parts
    # a path that starts with another filtered relation starts from its join
    if Symbol(parts[1]) != name && is_filtered_relation(get(c.annotations, Symbol(parts[1]), nothing))
        a, M = filtered_join!(c, alias, T, Symbol(parts[1]))
        rest = parts[2:end]
    end
    isempty(rest) && throw(ArgumentError("FilteredRelation('$(fr.relation)'): not a relation"))
    segs, ends = fr_segments(M, rest)
    steps = Any[]                    # (path prefix, its join, model): the condition's paths through them reuse them
    for (i, sg) in enumerate(segs[1:end-1])
        a, M, _ = fr_step!(c, a, M, sg, (a, :__filtered_step, name, i))
        j = findfirst(==(i), ends)                         # the end of the path's j-th part
        rest === parts && j !== nothing && push!(steps, (parts[1:j], a, M))
    end
    on = isempty(fr.condition.children) ? nothing : function (x, R)
        for st in steps
            push!(c.fr_override, (alias, st...))
        end
        push!(c.fr_override, (alias, parts, x, R))
        sc, ru, dst = c.scope, c.reuse_upto, c.distinct
        c.scope, c.reuse_upto = :expr, 0
        try
            csql, cps = compile_q(c, alias, T, fr.condition, false)
            append!(c.join_params, cps)
            csql
        finally
            for _ in 0:length(steps)
                pop!(c.fr_override)
            end
            c.scope, c.reuse_upto, c.distinct = sc, ru, dst     # (the condition's joins don't make rows distinct)
        end
    end
    a, M, _ = fr_step!(c, a, M, segs[end], key; on)
    # (no DISTINCT: as Django, a multi-valued filtered relation gives a row per related row)
    c.fr_models[key] = M
    a, M
end

"""
Django's checks on a FilteredRelation annotation `name` of a query on `T` (`anns`: the query's other
annotations): the alias, the relation path and the condition's lookups.
"""
Base.@nospecializeinfer function validate_filtered_relation(@nospecialize(T::Type), name, fr, anns)
    occursin('.', string(name)) && throw(ArgumentError("FilteredRelation doesn't support aliases with periods (got '$name')."))
    rparts = String.(split(fr.relation, "__"))
    M = T
    for (i, p) in enumerate(rparts)
        if i == 1 && haskey(anns, Symbol(p)) && is_filtered_relation(anns[Symbol(p)])
            M = relation_target(T, String.(split(anns[Symbol(p)].relation, "__")))
            M === nothing && break                     # (a chained path through a generic relation: not checked further)
            continue
        end
        R = fr_target(M, p)
        if R === nothing
            (is_lookup_name(p) || findfield(modelmeta(M), Symbol(p)) !== nothing) &&
                throw(ArgumentError("FilteredRelation's relation_name cannot contain lookups (got '$(fr.relation)')."))
            throw(lookup_error(M, p))
        end
        M = R
    end
    check(q::Q) = foreach(check, q.children)
    check(@nospecialize(x)) = nothing
    function check(ch::Pair)
        ch.second isa QuerySet && throw(ArgumentError("Passing a QuerySet within a FilteredRelation is not supported."))
        k = string(ch.first)
        ps = String.(split(k, "__"))
        explicit = length(ps) > 1 && is_lookup_name(ps[end]) && ends_in_lookup(T, ps)
        fparts = explicit ? ps[1:end-1] : ps
        path = fparts[1:max(length(fparts) - (explicit ? 1 : 2), 0)]
        for (i, p) in enumerate(path)
            i <= length(rparts) && rparts[i] != p && throw(ArgumentError(
                "FilteredRelation's condition doesn't support relations outside the '$(fr.relation)' (got '$k')."))
        end
        startswith(k, fr.relation * "__") && length(fparts) > length(rparts) + 1 && throw(ArgumentError(
            "FilteredRelation's condition doesn't support nested relations deeper than the relation_name (got '$k' for '$(fr.relation)')."))
    end
    check(fr.condition)
    nothing
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
        # (Django's query name: related_query_name, else related_name, else the model's name; with a related_name the
        # model's name isn't one (#275). The accessor's name works too when there's no related_query_name.)
        ((rf.related_query_name === nothing && string(rn) == name) || !startswith(string(rn), "+") &&
            string(something(rf.related_query_name, rf.related_name === nothing ? default_related_name(M) : rn,
                             Symbol(lowercase(modelmeta(M).name)))) == name) && return (rn, M, rf)
    end
    nothing
end

"""
The names a lookup on `T` may start with, sorted as Django lists them: fields (inherited too) and
a key's `_id` attribute, many-to-many fields, reverse relations by their query names, multi-table children. Hidden ones
(`related_name = "+"`, auto-created through tables) are left out.
"""
function lookup_choices(T)
    names = Set{String}(["id"])
    foreach(f -> push!(names, string(f.name)), all_fields(T))
    # (and a key's column attribute, author_id, as Django's)
    foreach(f -> attname(f) === f.name || push!(names, string(attname(f))), all_fields(T))
    for r in m2m_relations(T)
        f = r[2]
        !r[3] && f.symmetrical && continue          # a symmetrical self relation has no reverse name
        n = r[3] ? string(r[1]) : string(something(f.related_query_name, f.related_name, default_related_name(f.model), Symbol(lowercase(modelmeta(f.model).name))))
        startswith(n, "+") || push!(names, n)
    end
    for (rn, M, rf) in reverse_relations(T)
        startswith(string(rn), "+") && continue
        # (Django's query name: related_query_name, else related_name, else the model's name)
        push!(names, string(something(rf.related_query_name, rf.related_name === nothing ? default_related_name(M) : rn,
                                      Symbol(lowercase(modelmeta(M).name)))))
    end
    foreach(C -> push!(names, string(child_accessor(C))), child_models(concrete_model(T)))
    foreach(g -> push!(names, string(g.name)), generic_relations(T))        # (GenericRelations: tags)
    foreach(g -> push!(names, string(g.name)), foreign_objects(T))          # (ForeignObjects, both ways)
    for (_, M, f) in reverse_foreign_objects(T)
        n = string(fobj_query_name(M, f))
        endswith(n, "+") || push!(names, n)
    end
    sort!(collect(names))
end
lookup_error(T, fname) =
    LookupError("cannot resolve keyword '$fname' into a field of $T. Choices are: $(join(lookup_choices(T), ", "))")

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

# Marks the lookup of a key compiled again (`rest__lookup` of a relation): `tag__exact` is the lookup exact on the
# tag, even when the related model has a field named exact (Django's #23940).
const LK = "\x01"
lk(lookup) = LK * lookup

const AGG_CALL = r"^(?i:COUNT|SUM|AVG|MIN|MAX|STDDEV_[A-Z]+|STDDEV|VARIANCE|VAR_[A-Z]+|GROUP_CONCAT|STRING_AGG|ARRAY_AGG|JSONB?_AGG|JSON_GROUP_[A-Z]+|JSON_[A-Z]*AGG|BOOL_AND|BOOL_OR|BIT_AND|BIT_OR|BIT_XOR|EVERY|REGR_[A-Z]+|COVAR_[A-Z]+|CORR|PERCENTILE_[A-Z]+|ST_EXTENT|ST_COLLECT|ST_MAKELINE)\s*\("
"""
The table columns (`"alias"."col"`, of one of `aliases`) an SQL fragment reads outside aggregate calls (and their
FILTER clauses) and subqueries: what a grouped query groups by too, as Django's `get_group_by_cols` (PostgreSQL
refuses the others). A window's PARTITION BY and ORDER BY columns count; its aggregate's argument doesn't.
"""
function group_cols(sql::AbstractString, aliases)
    buf = IOBuffer()
    i, n = firstindex(sql), lastindex(sql)
    skip_parens(j) = (depth = 0; while j <= n
                          ch = sql[j]
                          ch == '(' && (depth += 1)
                          ch == ')' && (depth -= 1; depth == 0 && return nextind(sql, j))
                          j = nextind(sql, j)
                      end; j)
    while i <= n
        ch = sql[i]
        prev = i == firstindex(sql) ? ' ' : sql[prevind(sql, i)]
        if isletter(ch) && !(isletter(prev) || isdigit(prev) || prev in ('_', '"', '`', '.')) &&
           (m = match(AGG_CALL, SubString(sql, i))) !== nothing
            j = skip_parens(i + ncodeunits(m.match) - 1)
            f = match(r"^\s*FILTER\s*\(", SubString(sql, min(j, n + 1)))
            f === nothing || (j = skip_parens(j + ncodeunits(f.match) - 1))
            i = j
        elseif ch == '(' && startswith(lstrip(SubString(sql, nextind(sql, i))), r"(?i)SELECT\b")
            i = skip_parens(i)
        else
            write(buf, ch); i = nextind(sql, i)
        end
    end
    rest = String(take!(buf))
    unique(String[m.match for m in eachmatch(r"([\"`][^\"`]+[\"`])\.[\"`][^\"`]+[\"`]", rest) if m[1] in aliases])
end

"The aliases of a compiler's own tables: its base table and its joins (not a subquery's)."
query_aliases(c) = Set(vcat(qname(c.base), [m[1] for m in eachmatch(r" ([\"`][^\"`]+[\"`]) ON ", join(c.joins))]))

# The key column of a GenericRelation's owner: `id`, or its own primary key's (Person.account).
Base.@nospecializeinfer owner_pk_column(@nospecialize(T::Type)) = natural_pk(T) ? column(pk_fields(T)[1]) : "id"

"""
A path from a multi-table child through its parent links (`darbook_ptr__pages` from HardbackBook): the child has
its parents' fields, so the links drop out (as Django's join to the parent).
"""
Base.@nospecializeinfer function strip_parent_links(@nospecialize(T::Type), segs::Vector)
    M = concrete_model(T)
    while length(segs) > 1 && table_parent(M) !== nothing && segs[1] == string(parent_accessor(M)) &&
          findfield(modelmeta(M), Symbol(segs[1])) === nothing
        segs = segs[2:end]
        M = table_parent(M)
    end
    segs
end

# The right side of a composite key's comparison: a query's selected columns (its key, or values(...) with as many
# columns as the key), the base query's own key (F(:pk)), or the outer query's (OuterRef(:pk)), as a row value.
function composite_rhs(c::SQLCompiler, v, n::Int, lookup)
    if v isa F
        v.name == "pk" && multi_pk(c.T) || throw(ArgumentError("Composite field lookups only work with composite expressions."))
        return pk_ref(c.base, c.T), Any[]
    elseif v isa OuterRef
        o = c.outer
        o === nothing && throw(ArgumentError("OuterRef($(repr(v.name))) used outside a Subquery/Exists"))
        v.name == "pk" && multi_pk(o.T) || throw(ArgumentError("Composite field lookups only work with composite expressions."))
        sql = pk_ref(o.base, o.T)
        o.outer_refs === nothing || push!(o.outer_refs, sql)
        return sql, Any[]
    end
    qs = v::QuerySet
    M = model_of(qs)
    width(f) = (tf = values_tuple_fields(M, f); tf === nothing ? 1 : length(tf))
    cnt = qs.values_fields === nothing ? (multi_pk(M) ? length(pk_fields(M)) : 1) : sum(width, qs.values_fields; init = 0)
    cnt == n || throw(ArgumentError("The QuerySet value for the '$lookup' lookup must have $n selected fields (received $cnt)"))
    sql, ps = qs.values_fields === nothing ? subquery_sql(c, qs; idonly = true) : subquery_sql(c, qs)
    "($sql)", ps
end

"Compile one `field__path__lookup = value` against model `T` whose table is reachable as `alias`."
Base.@nospecializeinfer function compile_lookup(c::SQLCompiler, alias, @nospecialize(T::Type), key, @nospecialize(value), negated::Bool)
    parts = strip_parent_links(T, split(string(key), "__"))
    lookup = "exact"
    if startswith(parts[end], LK)           # a key built here (lk): its last part is the lookup, not a field so named
        lookup = String(chop(parts[end]; head = 1, tail = 0)); pop!(parts)
        key = replace(string(key), LK => "")
    elseif ends_in_lookup(T, parts)
        lookup = String(pop!(parts))
    end
    # in a FilteredRelation's condition, its relation's path is its join
    for (oa, op, ta, TM) in Iterators.reverse(c.fr_override)
        (alias == oa && length(parts) >= length(op) && parts[1:length(op)] == op) || continue
        rem = String.(parts[length(op)+1:end])
        return compile_lookup(c, ta, TM, join(vcat(isempty(rem) ? ["id"] : rem, [lk(lookup)]), "__"), value, negated)
    end
    # inside an aggregate's filter or a Case condition, ~Q(store__name = "x") is a condition on the joined
    # row (Django's FILTER (WHERE NOT ...)), not exclude()'s "no related row matches" subquery
    # (the NULL guard below still applies there, as Django's, through the relations the lookup follows)
    if c.scope === :expr && negated && !c.expr_negated
        c.expr_negated = true
        try
            return compile_lookup(c, alias, T, key, value, negated)
        finally
            c.expr_negated = false
        end
    end
    expr_negated = c.scope === :expr && c.expr_negated
    c.scope === :expr && (negated = false)
    lookup == "isnull" && !(value isa Bool) &&
        throw(ArgumentError("the value for an isnull lookup must be true or false, not $(repr(value)) ($key)"))
    meta = modelmeta(T)
    fname = parts[1] == "pk" ? "id" : String(parts[1])
    rest = String.(parts[2:end])
    bil = Any[]                 # bilateral transforms' SQL, applied to the value too
    tr_last, tr_inner = nothing, nothing      # the last registered transform, and the column it was applied to
    # an annotation whose name has "__" in it (alias(qs, Sum(:book__pages)) is book__pages__sum): longest name first
    if alias == c.base
        ks = string(key)
        for n in sort!([string(k) for k in keys(c.annotations) if occursin("__", string(k))]; by = length, rev = true)
            (ks == n || startswith(ks, n * "__")) || continue
            rem = ks == n ? String[] : String.(split(ks[length(n)+3:end], "__"))
            if length(rem) <= 1 && (isempty(rem) || rem[1] in LOOKUPS)
                fname, rest, lookup = n, String[], isempty(rem) ? "exact" : rem[1]
                break
            end
        end
    end
    f = nothing
    colps = Any[]
    kind = nothing                     # the compared value's field kind, for custom lookups
    if alias == c.base && is_filtered_relation(get(c.annotations, Symbol(fname), nothing))
        subkey = join(vcat(isempty(rest) ? ["id"] : rest, lk(lookup)), "__")
        if negated
            # exclude(): no row of the base model with a matching row through the filtered relation (EXISTS
            # here: the caller negates it)
            sub = SQLCompiler(T; outer = c)
            merge!(sub.annotations, c.annotations)
            a, M = filtered_join!(sub, sub.base, T, Symbol(fname))
            sql, ps = compile_lookup(sub, a, M, subkey, value, false)
            return ("EXISTS (SELECT 1 FROM $(qname(sub.table)) $(qname(sub.base))$(join(sub.joins)) WHERE " *
                    "$(qcol(sub.base, "id")) = $(qcol(alias, "id")) AND $sql)", vcat(sub.join_params, ps))
        end
        a, M = filtered_join!(c, alias, T, Symbol(fname))
        return compile_lookup(c, a, M, subkey, value, negated)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname)) && c.scope isa Int && c.scope > 0 &&
           windowing(c.annotations[Symbol(fname)], c.annotations)
        # Window functions can't appear in WHERE: the query is wrapped and this compares the column.
        c.uses_window = true
        c.qualify === nothing || push!(c.qualify, Symbol(fname))
        col = qname(fname)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname)) && c.qualify !== nothing && c.scope isa Int && c.scope > 0
        # the same condition reads other annotations too: they are columns of the wrapped query
        push!(c.qualify, Symbol(fname))
        col = qname(fname)
        a = c.annotations[Symbol(fname)]
        (of = annotation_container_field(c, a)) === nothing || (f = of; col = annotation_container_sql(a, of, col))   # (array__overlap: #297)
    elseif alias == c.base && isempty(rest) && haskey(c.annotations, Symbol(fname))
        a = c.annotations[Symbol(fname)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, colps = compile_expr(c, a)
        wrap_array_agg!(c, a, fname) && ((sql, colps) = (qname(fname), Any[]))
        col = "($sql)"
        kind = expr_kind(c, a)               # (custom lookups for its kind: trigram_similar on a Concat)
        # search = "cadeaux" on a SearchVector annotation: a plain query in the vector's configuration, as Django's
        a isa SearchVector && lookup == "exact" && value !== nothing && (value = as_search_query(value, search_vector_config(a)))
        # an annotation that's a JSON, hstore, array or range value takes that field's lookups (array__overlap on an ArrayAgg: #297)
        (of = annotation_container_field(c, a)) === nothing || (f = of; col = annotation_container_sql(a, of, col))
    elseif alias == c.base && !isempty(rest) && haskey(c.annotations, Symbol(fname)) &&
           (of = annotation_container_field(c, c.annotations[Symbol(fname)])) !== nothing &&
           (of.kind in (:json, :hstore, :array) || rest in (["startswith"], ["endswith"]))
        # value__a = "b" on a Subquery of a JSON or hstore field, array__0 on an ArrayAgg: the field's key paths and
        # transforms over the annotation's value, as Django's (#297)
        a = c.annotations[Symbol(fname)]
        contains_aggregate(a) && (c.uses_aggregate = true)
        sql, aps = compile_expr(c, a)
        wrap_array_agg!(c, a, fname) && ((sql, aps) = (qname(fname), Any[]))
        if of.kind === :hstore && length(rest) == 1 && !(rest[1] in ("keys", "values")) && lookup != "isnull"
            value = value isa Number ? string(value) : value isa AbstractVector ? Any[x isa Number ? string(x) : x for x in value] : value
        end
        tr = transform_column(of, annotation_container_sql(a, of, "($sql)"), rest, lookup, value)
        tr === nothing && throw(LookupError("unsupported lookup '$(join(rest, "__"))' on $(of.kind) annotation '$fname'"))
        col, colps = tr[1], vcat(aps, tr[2])
        lookup == "isnull" && of.kind in (:json, :hstore) && return truthy(value) ? (col, colps) : ("NOT " * col, colps)
        f = of.kind === :array && (af = array_transform(backend(), of, "", rest)) !== nothing && af[2] isa Field && af[2].kind === :array ? af[2] :
            of.kind === :hstore && length(rest) == 1 && rest[1] in ("keys", "values") ? hstore_array_field() : nothing
    elseif fname == "id" && is_composite(T)
        isempty(rest) || throw(LookupError("'pk' is not a relation; unsupported lookup '$(join(rest, "__"))'"))
        fs = pk_fields(T)
        # a natural key (#221): pk is its field, with any lookup
        length(fs) == 1 && return compile_lookup(c, alias, T, Symbol(fs[1].name, "__", lookup), value isa Model ? value.pk : value, negated)
        n = length(fs)
        value isa Model && (value = value.pk)
        lookup == "isnull" && return (truthy(value) ? sql_false(backend()) : sql_true(backend()), Any[])
        lookup in ("exact", "in", "gt", "gte", "lt", "lte") ||
            throw(LookupError("composite primary keys support the exact, in, gt, gte, lt, lte and isnull lookups, not '$lookup'"))
        # the key against a query (pk__in = qs, pk = qs[1:1], Subquery), its own F(:pk), or an outer query's key
        sub = value isa Subquery ? value.qs : value
        if sub isa QuerySet || value isa F || value isa OuterRef
            rsql, rps = composite_rhs(c, sub, n, lookup)
            op = lookup == "in" ? "IN" : lookup == "exact" ? "=" : nothing
            op === nothing && throw(NotSupportedError("\"$lookup\" cannot be used to target composite fields through subqueries on this backend"))
            return "$(pk_ref(alias, T)) $op $rsql", rps          # (an exclude()'s NOT is the caller's)
        end
        value isa Expression && throw(ArgumentError("'$lookup' subquery lookup of 'pk' only supports OuterRef and QuerySet objects (received '$(nameof(typeof(value)))')"))
        function part(tup, each = false)
            tup isa Union{Tuple,AbstractVector} || throw(ArgumentError(each ? "'in' lookup of 'pk' must be a collection of tuples or lists" :
                                                                       "'$lookup' lookup of 'pk' must be a tuple or a list"))
            length(tup) == n || throw(ArgumentError(each ? "'in' lookup of 'pk' must have $n elements each" : "'$lookup' lookup of 'pk' must have $n elements"))
            collect(Any, tup)
        end
        if lookup == "exact"
            value === nothing && return (sql_false(backend()), Any[])
            vals = part(value)
            return compile_q(c, alias, T, Q(:AND, Any[f.name => v for (f, v) in zip(fs, vals)], false), negated)
        elseif lookup == "in"
            value isa Union{Tuple,AbstractVector,AbstractSet} || throw(ArgumentError("'in' lookup of 'pk' must be a tuple or a list"))
            # (a key with a part missing matches nothing, as Django's)
            keys_ = [part(t isa Model ? t.pk : t, true) for t in value]
            filter!(k -> !any(isnothing, k), keys_)
            isempty(keys_) && return (sql_false(backend()), Any[])     # (excluded: NOT of it, every row)
            return compile_q(c, alias, T, Q(:OR, Any[Q(:AND, Any[f.name => v for (f, v) in zip(fs, k)], false) for k in keys_], false), negated)
        end
        # gt/gte/lt/lte: tuple order, (a, b) > (x, y) as a > x OR (a = x AND b > y) (Django's fallback, on every backend)
        vals = part(value)
        strict = lookup in ("gt", "lt") ? lookup : lookup == "gte" ? "gt" : "lt"
        q = Q(:AND, Any[Symbol(fs[n].name, "__", lookup) => vals[n]], false)
        for i in n-1:-1:1
            q = Q(:OR, Any[Q(:AND, Any[Symbol(fs[i].name, "__", strict) => vals[i]], false),
                           Q(:AND, Any[fs[i].name => vals[i], q], false)], false)
        end
        return compile_q(c, alias, T, q, negated)
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
            return compile_lookup(c, alias, T, join(vcat([string(step1), string(step2)], rest, [lk(lookup)]), "__"),
                                  value, negated)
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
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lk(lookup)), "__")
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
            ctid = generic_ct(T, g).id::Integer
            mt = qname(modelmeta(getfield_meta(M, fkf).model).table)      # (the table holding the key: a child's parent's)
            opk = owner_pk_column(T)          # (an owner with its own key: Person.account)
            # an object id kept as text is compared as text (PostgreSQL has no varchar = bigint; Django's #16055)
            as_text = getfield_meta(M, fkf).kind in STRING_KINDS
            opkref = as_text ? "CAST($(qcol(alias, opk)) AS $(cast_type(backend(), :text)))" : qcol(alias, opk)
            cond(a) = "$(qcol(a, fkcol)) = $opkref AND $(qcol(a, ctcol)) = $ctid"
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lk(lookup)), "__")
            if negated
                a = new_alias!(c)
                sql, ps = compile_lookup(c, a, M, subkey, value, negated)
                ex = "EXISTS (SELECT 1 FROM $mt $(qname(a)) WHERE $(cond(a)) AND $sql)"
                # exclude(a__flag = nothing): with no related row the path is NULL, so the row matches (and is
                # excluded), as through Django's LEFT JOIN
                if (lookup == "isnull" && value === true) || (lookup == "exact" && value === nothing)
                    b = new_alias!(c)
                    ex = "(NOT EXISTS (SELECT 1 FROM $mt $(qname(b)) WHERE $(cond(b))) OR $ex)"
                end
                return (ex, ps)
            end
            Mf = getfield_meta(M, fkf).model
            if modelmeta(Mf).table != modelmeta(M).table
                # the related model is a multi-table child: its key columns are in the parent's table
                ap = join!(c, alias, scope_key(c, alias, g.name), modelmeta(Mf).table, fkcol, opk; left = true, as_text,
                           extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
                a = join!(c, ap, (ap, :__child, M), modelmeta(M).table, "id", "id"; left = true)
            else
                a = join!(c, alias, scope_key(c, alias, g.name), modelmeta(M).table, fkcol, opk; left = true, as_text,
                          extra_on = a -> "$(qcol(a, ctcol)) = $ctid")
            end
            c.distinct = true
            return compile_lookup(c, a, M, subkey, value, negated)
        end
        if f === nothing && (rg = find_reverse_generic(T, fname)) !== nothing
            # tag.animal (a GenericRelation's related_query_name): the owner whose id is the object id, of its content type
            O, g = rg
            ctf, fkf = g.through
            ctcol, fkcol = column(getfield_meta(T, ctf)), column(getfield_meta(T, fkf))
            ctid = generic_ct(O, g).id::Integer
            ot = qname(modelmeta(O).table)
            # (an object id kept as text is compared as text)
            opk = natural_pk(O) ? column(pk_fields(O)[1]) : "id"
            rgidref(a) = getfield_meta(T, fkf).kind in STRING_KINDS ? "CAST($(qcol(a, opk)) AS $(cast_type(backend(), :text)))" : qcol(a, opk)
            rgcond(a) = "$(rgidref(a)) = $(qcol(alias, fkcol)) AND $(qcol(alias, ctcol)) = $ctid"
            if isempty(rest) && lookup == "isnull"
                a = new_alias!(c)
                ex = "EXISTS (SELECT 1 FROM $ot $(qname(a)) WHERE $(rgcond(a)))"
                return (truthy(value) ? "NOT " * ex : ex, Any[])
            end
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lk(lookup)), "__")
            a = new_alias!(c)
            sql, ps = compile_lookup(c, a, O, subkey, value, negated)
            ex = "EXISTS (SELECT 1 FROM $ot $(qname(a)) WHERE $(rgcond(a)) AND $sql)"
            return (ex, ps)                    # (negated: the caller adds the NOT, as for reverse foreign keys)
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
            subkey = join(vcat(isempty(rest) ? ["id"] : rest, lk(lookup)), "__")
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
        if !isempty(rest) && (f.kind in (:json, :hstore, :array) || f.kind in RANGE_KINDS && rest in (["startswith"], ["endswith"]))
            # data__owner__name (JSON key path), tags__len, tags__0
            # (an hstore's values are text: field__a = 1 is "1", as Django's)
            if f.kind === :hstore && length(rest) == 1 && !(rest[1] in ("keys", "values")) && lookup != "isnull"
                value = value isa Number ? string(value) : value isa AbstractVector ? Any[x isa Number ? string(x) : x for x in value] : value
            end
            tr = transform_column(f, qcol(alias, column(f)), rest, lookup, value)
            tr === nothing && throw(LookupError("unsupported lookup '$(join(rest, "__"))' on $(f.kind) field '$fname'"))
            col, colps = tr
            lookup == "isnull" && f.kind in (:json, :hstore) && return truthy(value) ? (col, colps) : ("NOT " * col, colps)
            # a slice, or an item of a nested array, is an array still: its lookups are an array's (field__0_2 = [2, 3])
            if f.kind === :array && (af = array_transform(backend(), f, "", rest)) !== nothing && af[2] isa Field && af[2].kind === :array
                f = af[2]
            elseif f.kind === :hstore && length(rest) == 1 && rest[1] in ("keys", "values")
                f = hstore_array_field()           # field__keys__contains = ["a"]: an array's lookups
            else
                f = nothing
            end
        elseif !isempty(rest) && (tr = apply_transforms(qcol(alias, column(f)), f.kind, rest; field = f, bilateral = bil)) !== nothing
            tr_last = rest[end]
            tr_inner = something(apply_transforms(qcol(alias, column(f)), f.kind, rest[1:end-1]; field = f), (nothing,))[1]
            col, kind = tr                  # registered transforms: name__lower__...
            kind === f.kind || (f = nothing)
            # when__day = "31": an integer part compared with text given as a number, as Django
            if kind === :int
                pint(v) = v isa AbstractString ? something(tryparse(Int, strip(v)), v) : v
                value = value isa AbstractVector ? map(pint, value) : pint(value)
            end
        elseif !isempty(rest)
            if f.kind !== :fk
                left, k = failed_transform(f.kind, rest; field = f)
                throw(LookupError("Unsupported lookup '$(join(left, "__"))' for $(kind_class_name(k)) or join on the field not permitted" *
                                  (isempty(left) ? "." : (s = suggest_lookup(left[1]); isempty(s) ? "." : s))))
            end
            if rest == [string(target_name(f))] || (fk_to_field(f) === nothing && rest == ["pk"])
                col = qcol(alias, column(f))     # author__id is just author_id: no join
                # restaurant__place where the restaurant's key is its one-to-one place: the column holds a place's
                # key, so values are compared as that relation's (a Place is right here)
                tf = fk_to_field(f) === nothing ? nothing : getfield_meta(related_model(f), fk_to_field(f))
                tf !== nothing && tf.kind === :fk && (f = tf)
            else
                R = related_model(f)
                subkey = join(vcat(rest, lk(lookup)), "__")
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
    # a bound outside the column's range (which PostgreSQL refuses as a parameter): every value is on one side of it,
    # as Django's IntegerFieldOverflow
    if f !== nothing && haskey(INT_RANGES, f.kind) && value isa Integer && !(value isa Bool) && lookup in ("exact", "lt", "lte", "gt", "gte")
        lo, hi = INT_RANGES[f.kind]
        if !(lo <= value <= hi)
            all_on_side = lookup == "exact" ? false : lookup in ("gt", "gte") ? value < lo : value > hi
            return (all_on_side ? "$col IS NOT NULL" : sql_false(backend())), copy(colps)
        end
    end
    # a bilateral transform applies to the value too: name__upper = "doe" is UPPER(name) = UPPER('doe')
    if !isempty(bil)
        value isa QuerySet && throw(ErrorException("Bilateral transformations on nested querysets are not implemented."))
        value isa Expression && (value = Bilateral(value, copy(bil)))
    end
    bwrap(x) = foldl((acc, g) -> String(g(acc)), bil; init = String(x))
    # (exact = nothing is isnull, even with an exact lookup registered, as Django's)
    cl = isempty(CUSTOM_LOOKUPS) || (lookup == "exact" && value === nothing) ? nothing :
         find_custom(CUSTOM_LOOKUPS, lookup, kind; field = f, after = tr_last)
    if cl !== nothing
        rsql, rps = value isa Expression ? ((e = compile_expr(c, value)); ("(" * e[1] * ")", e[2])) : (bwrap("?"), Any[conv(cl.prepare(value))])
        # a lookup registered for a transform may skip it: sql(lhs, rhs, inner) is given the column under the transform
        # (given markers, so a lookup can use its lhs or rhs more than once, as Django's YearLte: each use gets
        # its own copy of that side's parameters, in the order they appear)
        L, R, I = "\0LHS\0", "\0RHS\0", "\0INNER\0"
        sql = cl.transform !== nothing && tr_inner !== nothing && applicable(cl.sql, L, R, tr_inner) ?
              cl.sql(L, R, I) : cl.sql(L, R)
        out, ps = IOBuffer(), Any[]
        for m in eachmatch(r"\0(LHS|RHS|INNER)\0|[^\0]+"s, String(sql::AbstractString))
            m.captures[1] === nothing ? print(out, m.match) :
            m.captures[1] == "LHS" ? (print(out, col); append!(ps, colps)) :
            m.captures[1] == "RHS" ? (print(out, rsql); append!(ps, rps)) : print(out, tr_inner)
        end
        return String(take!(out)), ps
    end
    # integer__contained_by = ValueRange(1, 98): a value within a range (Django's RangeContainedBy, on any field)
    if lookup == "contained_by" && value isa ValueRange && (f === nothing || !(f.kind in RANGE_KINDS))
        r = scalar_in_range_sql(col, value; s = x -> x isa TimeZones.ZonedDateTime ? to_utc_naive(x) : x)
        return r[1], vcat(colps, r[2])
    end
    if f !== nothing || lookup == "search"
        sl = special_lookup(c, something(f, Field(:text)), col, lookup, value)
        sl === nothing || return sl[1], vcat(colps, sl[2])
    end
    # id__iexact = "12", gt__regex = "^4": a text lookup on a number, date or UUID column compares its text
    # (PostgreSQL has no LOWER(bigint) or integer ~ text; Django casts there too)
    if lookup in TEXT_LOOKUPS && kind !== nothing && !(kind in TEXT_KINDS)
        col = text_cast(backend(), col, kind)
    end
    # an expression (an annotation, a Case) compared with a Decimal on SQLite: the Decimal as a number, not text
    f === nothing && value isa Decimal && backend() isa SQLiteBackend && lookup in keys(COMPARISON_OPS) && (value = Value(value))
    if isempty(bil) || value isa Expression
        sql, ps = lookup_condition(c, col, lookup, value, conv)
    else                    # each of the value's placeholders through the bilateral transforms
        mark = "\0COL\0"
        sql, ps = lookup_condition(c, mark, lookup, value, conv)
        sql = replace(replace(sql, "?" => bwrap("?")), mark => col)
    end
    # Under exclude()/~Q, a NULL in a nullable column doesn't make the condition true, so the row is kept, as
    # Django does (NOT (x = 1) alone is NULL there and would drop it); a None in an __in list matches NULL
    if (negated || expr_negated) && !(lookup in ("isnull", "ne")) && !(lookup == "exact" && value === nothing)
        # in a Case/aggregate condition, a column through a reverse, many-to-many or nullable relation is
        # LEFT JOINed and can be NULL too (~Q(fk_rel__integer = 1) matches a row without related rows)
        via_outer = expr_negated && alias in c.leftjoined
        if f !== nothing && (f.null || via_outer)
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
"The field an annotation's value is when it's a JSON, hstore, array or range one (its output field), else nothing."
Base.@nospecializeinfer function annotation_container_field(c, @nospecialize(a))
    if a isa Aggregate && a.func == "ARRAY_AGG"         # (an array of its argument's field)
        base = a.arg === nothing ? nothing : (try output_field(c.T, a.arg) catch; nothing end)
        return ArrayField(base isa Field && !(base.kind in (:array, :json, :hstore)) && !(base.kind in RANGE_KINDS) ? base : TextField())
    end
    of = try output_field(c.T, a) catch; nothing end
    of isa Field && (of.kind in (:json, :hstore, :array) || of.kind in RANGE_KINDS) ? of : nothing
end
"""
SQLite can't read an aggregate inside the subqueries its array lookups use (json_each), so a condition on an
ArrayAgg annotation wraps the query, as one on a window annotation does, and reads its column: true when the
column is to be read (on the second pass).
"""
function wrap_array_agg!(c, @nospecialize(a), fname)
    backend() isa SQLiteBackend && a isa Aggregate && a.func == "ARRAY_AGG" && c.scope isa Int && c.scope > 0 || return false
    c.uses_window = true
    c.qualify === nothing && return false
    push!(c.qualify, Symbol(fname))
    true
end
"""
An annotation's SQL as the container field `of` takes it: an ArrayAgg on PostgreSQL is JSON text (as everywhere,
read the same way), so it becomes a typed array for the array lookups.
"""
Base.@nospecializeinfer function annotation_container_sql(@nospecialize(a), of, sql)
    a isa Aggregate && a.func == "ARRAY_AGG" && backend() isa PostgresBackend || return sql
    "CAST(ARRAY(SELECT x FROM json_array_elements_text(CAST($sql AS json)) AS x) AS $(array_cast(backend(), of)))"
end
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
    if value isa SearchQueryLike && lookup == "exact"
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
    if value === nothing                # (Django: None is a value for exact and iexact only)
        lookup == "iexact" && return ("$col IS NULL", Any[])
        lookup in ("gt", "gte", "lt", "lte", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith", "regex", "iregex") &&
            throw(ArgumentError("Cannot use nothing as a query value with '$lookup' (only exact, iexact and ne take it; use isnull)"))
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
        if c.having && !(ch isa Q)
            # in HAVING, the columns a condition reads outside aggregates are grouped by (Django's get_group_by of
            # the HAVING's columns): an ungrouped one would be any row's value, and PostgreSQL refuses it
            sql, ps = ch isa Expression ? compile_expr(c, ch) : compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
            for g in group_cols(sql, query_aliases(c))
                g in c.having_cols || push!(c.having_cols, g)
            end
        else
            sql, ps = ch isa Q ? compile_q(c, alias, T, ch, neg) :
                      ch isa Expression ? compile_expr(c, ch) :
                      compile_lookup(c, alias, T, Symbol(ch.first), ch.second, neg)
        end
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
