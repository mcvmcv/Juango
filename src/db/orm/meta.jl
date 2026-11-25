# A model's fields by name, as Django's Model._meta.get_field / get_fields ------------------------------------

"""
The other side of a relation, as Django's ForeignObjectRel (`ManyToOneRel`, `OneToOneRel`,
`ManyToManyRel`): what `get_field`/`get_fields` give for a reverse relation. `name` is its query name
(`filter(Author; book__title = ...)`), `accessor` the attribute (`author.book_set`), `related_model` the model
the relation comes from, `field` that model's foreign key or many-to-many field.
"""
struct RelatedObject
    name::Symbol
    accessor::Symbol
    model::Any                 # the model this is a relation of
    related_model::Any         # the model with the field
    field::Field
    one_to_many::Bool
    one_to_one::Bool
    many_to_many::Bool
    hidden::Bool               # related_name = "+": no accessor, left out by get_fields unless include_hidden
end
Base.show(io::IO, r::RelatedObject) =
    print(io, "<", r.many_to_many ? "ManyToManyRel" : r.one_to_one ? "OneToOneRel" : "ManyToOneRel", ": ",
          model_label(r.related_model), ".", r.field.name, ">")
is_relation(::RelatedObject) = true

"The reverse relations of `T`, as RelatedObjects (hidden ones too)."
Base.@nospecializeinfer function related_objects(@nospecialize(T::Type))
    out = RelatedObject[]
    for (rn, M, f) in reverse_relations(T)
        hidden = startswith(string(rn), "+")
        q = something(f.related_query_name, f.related_name === nothing ? default_related_name(M) : f.related_name,
                      Symbol(lowercase(modelmeta(M).name)))
        push!(out, RelatedObject(Symbol(q), rn, T, M, f, !f.one_to_one, f.one_to_one, false, hidden))
    end
    for (rn, f, fwd) in m2m_relations(T)
        fwd && continue
        hidden = startswith(string(rn), "+")
        q = something(f.related_query_name, f.related_name, default_related_name(f.model), Symbol(lowercase(modelmeta(f.model).name)))
        push!(out, RelatedObject(Symbol(q), rn, T, f.model, f, false, false, true, hidden))
    end
    out
end

"""
    get_fields(T; include_parents = true, include_hidden = false) -> Vector

A model's fields, as Django's `Model._meta.get_fields()`: its own fields (with a multi-table child's
parents' unless `include_parents = false`), its many-to-many fields, then the relations of other models to it
(`RelatedObject`s; with `include_hidden`, also those with `related_name = "+"`). The automatic `id` isn't a
field in Juango.
"""
Base.@nospecializeinfer function get_fields(@nospecialize(T::Type); include_parents::Bool = true, include_hidden::Bool = false)
    own = include_parents ? all_fields(T) : modelmeta(T).fields
    out = Any[f for f in own]
    append!(out, include_parents ? many_to_many(T) : modelmeta(T).m2m)
    append!(out, [r for r in related_objects(T) if include_hidden || !r.hidden])
    out
end

"""
    get_field(T, name) -> Field or RelatedObject

A field of the model by name, or a reverse relation by its query name, as Django's
`Model._meta.get_field()`. Throws `FieldDoesNotExist` ("Band has no field named 'x'") otherwise.
"""
Base.@nospecializeinfer function get_field(@nospecialize(T::Type), name)
    s = Symbol(name)
    i = findfirst(x -> x.name === s, all_fields(T))           # (a multi-table child's parents' fields too)
    i !== nothing && return all_fields(T)[i]
    m2m = many_to_many(T)
    i = findfirst(x -> x.name === s, m2m)
    i !== nothing && return m2m[i]
    for r in related_objects(T)
        r.name === s && return r
    end
    throw(FieldDoesNotExist("$(nameof(T)) has no field named '$name'"))
end

"The model's label in lowercase, as Django's `_meta.label_lower` (`\"blog.post\"`)."
model_label_lower(T::Type) = lowercase(model_label(T))
