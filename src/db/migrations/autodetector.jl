# --- autodetector -------------------------------------------------------------------------------

"Default questioner: ask on a terminal, otherwise answer no."
function ask(question)
    stdin isa Base.TTY || return false
    print(question, " [y/N] ")
    lowercase(strip(readline())) in ("y", "yes")
end

"""
    detect_changes(g, app; questioner=ask) -> Vector{Operation}

Operations that take `app`'s tables from the state its migrations describe to the state
its models describe. `questioner(question) -> Bool` decides whether a removed plus an
added table or column is really a rename.
"""
function detect_changes(g::Graph, app; questioner = ask)
    from = replay(g, keys(g.nodes))
    to = models_state()
    old = Dict(k => v for (k, v) in from if v.app == app)
    new = Dict(k => v for (k, v) in to if v.app == app)
    ops = Operation[]

    # renamed tables: same columns, different name
    removed = sort(setdiff(collect(keys(old)), keys(new)))
    added = sort(setdiff(collect(keys(new)), keys(old)))
    work = copy_state(from)
    for t in copy(added)
        for r in removed
            same = sort(old[r].columns; by = c -> c.name) == sort(new[t].columns; by = c -> c.name) &&
                   old[r].parent == new[t].parent && old[r].pk == new[t].pk
            if same && questioner("Was the table $(r) renamed to $(t) (model $(new[t].model))?")
                op = RenameModel(r, t; model = new[t].model)
                push!(ops, op)
                state_forwards!(op, work, app)
                filter!(!=(r), removed)
                filter!(!=(t), added)
                break
            end
        end
    end
    old = Dict(k => v for (k, v) in work if v.app == app)

    # new tables, created so that referenced tables come first
    for t in creation_order(Table[new[t] for t in added])
        push!(ops, CreateModel(t.name; model = t.model, columns = t.columns, unique_together = t.unique_together,
                               parent = t.parent, pk = t.pk, indexes = t.indexes, constraints = t.constraints,
                               pk_columns = t.pk_columns, comment = t.comment))
    end

    # the size of automatic keys first, so foreign keys follow
    for name in sort(collect(intersect(keys(old), keys(new))))
        o, n = old[name], new[name]
        (o.pk != n.pk && Juango.is_auto_pk(o.pk) && Juango.is_auto_pk(n.pk)) && push!(ops, AlterPrimaryKey(name, n.pk))
    end

    # columns of tables that exist in both
    for name in sort(collect(intersect(keys(old), keys(new))))
        o, n = old[name], new[name]
        (o.parent != n.parent || (o.pk != n.pk && !(Juango.is_auto_pk(o.pk) && Juango.is_auto_pk(n.pk))) || o.pk_columns != n.pk_columns) &&
            throw(MigrationError("changing the parent model or primary key type of table '$name' isn't supported; create a new model and move the data"))
        ocols = Dict(c.name => c for c in o.columns)
        ncols = Dict(c.name => c for c in n.columns)
        gone = sort(setdiff(collect(keys(ocols)), keys(ncols)))
        fresh = [c.name for c in n.columns if !haskey(ocols, c.name)]
        for c in copy(fresh)
            for r in gone
                if same_definition(ocols[r], ncols[c]) && questioner("Was $(name).$(r) renamed to $(name).$(c)?")
                    push!(ops, RenameField(name, r, c))
                    filter!(!=(r), gone)
                    filter!(!=(c), fresh)
                    break
                end
            end
        end
        for c in fresh
            push!(ops, AddField(name, ncols[c]))
        end
        for c in n.columns
            haskey(ocols, c.name) && ocols[c.name] != c && push!(ops, AlterField(name, c))
        end
        # unique sets after renames; changed before columns are removed
        renamed = Dict(op.old => op.new for op in ops if op isa RenameField && op.table == name)
        ou = Juango.normalize_unique([[get(renamed, x, x) for x in u] for u in o.unique_together])
        ou == n.unique_together || push!(ops, AlterUniqueTogether(name, n.unique_together))
        o.comment == n.comment || push!(ops, AlterModelTableComment(name, n.comment))
        oix = Dict(i.name => i for i in o.indexes)
        nix = Dict(i.name => i for i in n.indexes)
        for (k, i) in sort(collect(oix); by = first)
            get(nix, k, nothing) == i || push!(ops, RemoveIndex(name, k))
        end
        for (k, i) in sort(collect(nix); by = first)
            get(oix, k, nothing) == i || push!(ops, AddIndex(name, i))
        end
        ocs = Dict(c.name => c for c in o.constraints)
        ncs = Dict(c.name => c for c in n.constraints)
        for (k, c) in sort(collect(ocs); by = first)
            get(ncs, k, nothing) == c || push!(ops, RemoveConstraint(name, k))
        end
        for (k, c) in sort(collect(ncs); by = first)
            get(ocs, k, nothing) == c || push!(ops, AddConstraint(name, c))
        end
        for r in gone
            push!(ops, RemoveField(name, r))
        end
    end

    # dropped tables, referencing tables first
    for t in reverse(creation_order(Table[old[r] for r in removed]))
        push!(ops, DeleteModel(t.name))
    end
    ops
end

"Tables ordered so that tables referenced by others (within the list) come first."
function creation_order(tables::Vector{Table})
    names = Set(t.name for t in tables)
    byname = Dict(t.name => t for t in tables)
    out = Table[]
    seen = Set{String}()
    visit(t, path) = begin
        t.name in seen && return
        push!(path, t.name)
        for r in vcat([c.references === nothing ? nothing : Juango.ref_table(c.references) for c in t.columns], [t.parent])
            (r !== nothing && r in names && !(r in path)) && visit(byname[r], path)
        end
        pop!(path)
        t.name in seen || (push!(seen, t.name); push!(out, t))
    end
    for t in sort(tables; by = t -> t.name)
        visit(t, String[])
    end
    out
end
