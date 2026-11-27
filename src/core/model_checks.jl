# Model system checks, as Django's (models.E0xx, fields.E30x) ----------------------------------------------------
#
# What a model's definition can't check alone: names in Meta that aren't fields, an ordering that
# doesn't resolve, two fields on one column, and relations whose reverse accessors or query names
# clash with each other or with the related model's fields.

model_check_label(T) = model_label(T)
own_field(T, n) = (i = findfirst(f -> f.name === Symbol(n) || attname(f) === Symbol(n), modelmeta(T).fields); i === nothing ? nothing : modelmeta(T).fields[i])

"The problems of the names in one of `T`'s Meta options (models.E012, E013, E016)."
Base.@nospecializeinfer function meta_field_issues(@nospecialize(T::Type), option::AbstractString, names)
    out = CheckMessage[]
    label = model_check_label(T)
    for n in names
        s = String(lstrip(string(n), '-'))
        s in ("id", "pk") && continue
        if own_field(T, s) !== nothing
            continue
        elseif any(f -> f.name === Symbol(s), many_to_many(T))
            push!(out, CheckMessage(:error, "$label: '$option' refers to a ManyToManyField '$s', but ManyToManyFields are not permitted in '$option'."; id = "models.E013"))
        elseif any(f -> f.name === Symbol(s) || attname(f) === Symbol(s), all_fields(T))
            push!(out, CheckMessage(:error, "$label: '$option' refers to field '$s' which is not local to model '$(nameof(T))'.";
                                    id = "models.E016", hint = "This issue may be caused by multi-table inheritance."))
        else
            push!(out, CheckMessage(:error, "$label: '$option' refers to the nonexistent field '$s'."; id = "models.E012"))
        end
    end
    out
end

"""
The model system checks for `T`: Meta names (unique_together, indexes, constraints, ordering), columns
used twice, and reverse accessor / query name clashes of its relations, with Django's ids and messages.
"""
Base.@nospecializeinfer function model_check_issues(@nospecialize(T::Type))
    m = modelmeta(T)
    out = CheckMessage[]
    label = model_check_label(T)
    m.proxy && return out
    for u in m.unique_together
        append!(out, meta_field_issues(T, "unique_together", u))
    end
    for ix in get(m.extra, :indexes, Any[])
        ix isa Index && append!(out, meta_field_issues(T, "indexes", ix.columns))
    end
    for c in model_constraints(T)
        c isa UniqueConstraint && append!(out, meta_field_issues(T, "constraints", c.fields))
        if c isa ExclusionConstraint
            # the fields its expressions name: own fields only (a transform after one is fine, a relation followed isn't)
            paths = String[]
            foreach(x -> expr_paths(x[1], paths), c.expressions)
            for p in unique(paths)
                parts = split(p, "__")
                f = own_field(T, parts[1])
                if f === nothing
                    append!(out, meta_field_issues(T, "constraints", [parts[1]]))
                elseif length(parts) > 1 && f.kind in (:fk, :o2o)
                    push!(out, CheckMessage(:error, "$label: 'constraints' refers to the joined field '$p'."; id = "models.E041"))
                end
            end
        end
    end
    # ordering (models.E015): each name as the ORM resolves it
    for o in m.ordering
        o isa AbstractString || continue
        o == "?" && continue
        try
            select_sql(order_by(base_objects(T), o))
        catch e
            e isa InterruptException && rethrow()          # (whatever the ORM refuses the name with)
            push!(out, CheckMessage(:error, "$label: 'ordering' refers to the nonexistent field, related field, or lookup '$(lstrip(o, '-'))'."; id = "models.E015"))
        end
    end
    # a column used by two fields (models.E007)
    seen = Dict{String,Symbol}()
    for f in m.fields
        c = column(f)
        haskey(seen, c) && push!(out, CheckMessage(:error, "$label: Field '$(f.name)' has column name '$c' that is used by another field.";
                                                   id = "models.E007", hint = "Specify a 'db_column' for the field."))
        seen[c] = f.name
    end
    # a JSON, array or hstore field whose default is a value rather than a function (fields.E010): one dict or list
    # would be shared by every instance
    for f in m.fields
        f.kind in (:json, :array, :hstore) || continue
        d = f.default
        d isa Union{AbstractDict,AbstractVector} || continue
        cls = f.kind === :json ? "JSONField" : f.kind === :array ? "ArrayField" : "HStoreField"
        eg = d isa AbstractDict ? "use `Dict` instead of `Dict()`" : "use `Vector{Any}` instead of `[]`"
        push!(out, CheckMessage(:warning, "$label.$(f.name): $cls default should be a callable instead of an instance so that it's not shared between all field instances.";
                                id = "fields.E010", hint = "Use a callable instead, e.g., $eg."))
    end
    # reverse accessor and query name clashes (fields.E302-E305)
    rels = [(f, false) for f in m.fields if f.kind === :fk]
    append!(rels, [(f, true) for f in m.m2m])
    for (f, ism2m) in rels
        R = try related_model(f) catch; continue end
        ism2m && f.symmetrical && R === T && continue           # (a symmetrical relation has no reverse side)
        acc = ism2m ? something(f.related_name, default_related_name(T), Symbol(lowercase(m.name), :_set)) : reverse_name(f)
        (startswith(string(acc), "+") || endswith(string(acc), "+")) && continue
        q = something(f.related_query_name, f.related_name === nothing ? default_related_name(T) : f.related_name, Symbol(lowercase(m.name)))
        fname = "$label.$(f.name)"
        rlabel = model_check_label(R)
        rnames = Set(vcat([g.name for g in all_fields(R)], [g.name for g in many_to_many(R)]))
        if Symbol(acc) in rnames
            push!(out, CheckMessage(:error, "Reverse accessor '$(nameof(R)).$acc' for '$fname' clashes with field name '$rlabel.$acc'.";
                                    id = "fields.E302", hint = "Rename field '$rlabel.$acc', or add/change a related_name argument to the definition for field '$fname'."))
        end
        if Symbol(q) in rnames
            push!(out, CheckMessage(:error, "Reverse query name for '$fname' clashes with field name '$rlabel.$q'.";
                                    id = "fields.E303", hint = "Rename field '$rlabel.$q', or add/change a related_name argument to the definition for field '$fname'."))
        end
        for r in related_objects(R)
            r.field === f && continue
            r.hidden && continue
            other = "$(model_check_label(r.related_model)).$(r.field.name)"
            if r.accessor === Symbol(acc)
                push!(out, CheckMessage(:error, "Reverse accessor '$(nameof(R)).$acc' for '$fname' clashes with reverse accessor for '$other'.";
                                        id = "fields.E304", hint = "Add or change a related_name argument to the definition for '$fname' or '$other'."))
            end
            if r.name === Symbol(q)
                push!(out, CheckMessage(:error, "Reverse query name for '$fname' clashes with reverse query name for '$other'.";
                                        id = "fields.E305", hint = "Add or change a related_name argument to the definition for '$fname' or '$other'."))
            end
        end
    end
    out
end

register_check!(tags = [:models]) do
    out = CheckMessage[]
    for T in MODEL_LIST
        model_in_use(T) || continue
        T <: AutoThrough && continue
        append!(out, model_check_issues(T))
    end
    out
end
