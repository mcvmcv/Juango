# Nested forms: a form with child formsets, to any depth (#188) --------------------------------------------
#
# Over a document (dicts and vectors, such as a JSONField's value):
#
#     spec = (; plates = nested_formset(PlateForm; extra = 1, can_delete = true, can_order = true,
#                                       children = (; blocks = nested_formset(BlockForm; extra = 1, can_delete = true))))
#     tree = nested_form(SheetForm; data = req.method == "POST" ? req.POST : nothing, initial = format.specification,
#                        children = spec)
#     if is_valid(tree)
#         format.specification = cleaned_data(tree)        # the same shape as the document, in its order
#         save!(format)
#     end
#
#     {{ tree.form.as_p }}                                   (or {{ tree.as_p }} for all of it)
#     {{ tree.plates.management_form }}
#     {% for plate in tree.plates %}
#       {{ plate.form.as_p }}
#       {{ plate.blocks.management_form }}
#       {% for block in plate.blocks %}{{ block.form.as_p }}{% endfor %}
#     {% endfor %}
#
# Prefixes are built from the path (`plates-0-blocks-2-label`). Every level can delete and order
# its rows, `has_changed(tree)` says whether anything below changed, and keys of the document no
# form edits are kept. Over models, `nested_model_form(Order; nested = [:items])` edits an object and
# its children (an inline formset per relation), and `save!(tree)` saves all of it in one transaction.

"How a child formset is built: its form, formset options and its own children."
struct NestedSetSpec
    form::Any                         # F(data; prefix, initial) -> Form, as formset_factory takes
    options::NamedTuple
    children::Vector{Pair{Symbol,NestedSetSpec}}
end

children_pairs(c) = Pair{Symbol,NestedSetSpec}[Symbol(k) => v for (k, v) in pairs(c)]

"""
    nested_formset(F; extra = 1, can_delete = false, can_order = false, min_num = 0, max_num = 1000,
                   validate_min = false, validate_max = false, clean = nothing, children = (;))

A child formset of a nested form: rows made with `F(data; prefix, initial)` (a `@form` constructor,
or any function taking those, so a row can be customised from its initial values), each with its
own `children`.
"""
nested_formset(F; children = (;), kw...) = NestedSetSpec(F, (; kw...), children_pairs(children))

"One node of a nested form: a form and its named child formsets."
mutable struct NestedForm
    form::Form
    children::Vector{Pair{Symbol,Any}}      # name => NestedFormSet
    doc::Dict{String,Any}                   # this node's initial document (its rows' and unedited keys)
end

"A child formset of a nested form: the formset and a node per row."
mutable struct NestedFormSet
    formset::FormSet
    spec::Union{Nothing,NestedSetSpec}
    rows::Vector{NestedForm}
end

"A document (a Dict, a NamedTuple, nothing) as a Dict with String keys."
as_doc(d) = d === nothing ? Dict{String,Any}() : Dict{String,Any}(string(k) => v for (k, v) in pairs_of(d))
"The keys of a document a form edits (all but the child lists), as a form's initial values."
form_initial(doc, names) = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in doc if !(Symbol(k) in names))
child_prefix(prefix, name) = isempty(prefix) ? string(name) : prefix * "-" * string(name)

"""
    nested_form(F; data = nothing, initial = Dict(), prefix = "", children = (;)) -> NestedForm

A form made with `F(data; prefix, initial)` from the document `initial` (its keys other than the
children's), and a child formset per entry of `children` (`nested_formset(...)`), each filled from
the document's list under that name. See the comment at the top of this file.
"""
function nested_form(F; data = nothing, initial = Dict{String,Any}(), prefix::AbstractString = "", children = (;))
    kids = children_pairs(children)
    doc = as_doc(initial)
    names = first.(kids)
    form = F(data; prefix = prefix, initial = form_initial(doc, names))
    NestedForm(form, Pair{Symbol,Any}[name => bind_set(spec, data, child_prefix(prefix, name), get(doc, string(name), nothing))
                                      for (name, spec) in kids], doc)
end

function bind_set(spec::NestedSetSpec, data, prefix, rows_doc)
    docs = Dict{String,Any}[as_doc(r) for r in something(rows_doc, Any[])]
    names = first.(spec.children)
    o = spec.options
    fs = new_formset((d, p, init, _) -> spec.form(d; prefix = p, initial = init); prefix = prefix, data = data,
                     initial = [form_initial(d, names) for d in docs], instances = Any[], extra = get(o, :extra, 1),
                     min_num = get(o, :min_num, 0), max_num = get(o, :max_num, 1000), validate_min = get(o, :validate_min, false),
                     validate_max = get(o, :validate_max, false), can_delete = get(o, :can_delete, false),
                     can_order = get(o, :can_order, false), clean = get(o, :clean, nothing))
    rows = NestedForm[]
    for (i, f) in enumerate(build_forms!(fs))
        d = i <= length(docs) ? docs[i] : Dict{String,Any}()
        push!(rows, NestedForm(f, Pair{Symbol,Any}[n => bind_set(s, data, child_prefix(f.prefix, n), get(d, string(n), nothing))
                                                   for (n, s) in spec.children], d))
    end
    NestedFormSet(fs, spec, rows)
end

# --- validation, changes, the cleaned document ---

"Whether the row takes part: not deleted, and not a blank extra row (unless something below it was filled in)."
function row_active(s::NestedFormSet, i)
    fs, row = s.formset, s.rows[i]
    marked_delete(fs, row.form) && return false
    !blank_extra(fs, row.form, i - 1) || any(c -> has_changed(c.second), row.children)
end

"Validate the form and everything below it (every error is found, not only the first)."
function is_valid(n::NestedForm)
    ok = is_valid(n.form)
    for (_, s) in n.children
        ok = is_valid(s) & ok
    end
    ok
end
function is_valid(s::NestedFormSet)
    ok = is_valid(s.formset)
    for (i, row) in enumerate(s.rows)
        row_active(s, i) || continue
        if blank_extra(s.formset, row.form, i - 1)          # an extra row whose children were filled in: it counts
            row.form.validated = false
            row.form.empty_permitted = false
            ok = is_valid(row.form) & ok
        end
        for (_, c) in row.children
            ok = is_valid(c) & ok
        end
    end
    ok && isempty(s.formset.non_form_errors) && all(r -> isempty(r.form.errors), s.rows)
end

"""
    has_changed(tree) -> Bool

Whether anything in the nested form changed from its initial document: a field anywhere below,
a row added, deleted or (with `can_order`) moved.
"""
has_changed(n::NestedForm) = has_changed(n.form) || any(c -> has_changed(c.second), n.children)
function has_changed(s::NestedFormSet)
    fs = s.formset
    fs.data === nothing && return false
    n0 = initial_form_count(fs)
    for (i, row) in enumerate(s.rows)
        marked_delete(fs, row.form) && return true
        (has_changed(row.form) || any(c -> has_changed(c.second), row.children)) && return true
    end
    if fs.can_order                                         # moved: an ORDER that differs from the row's place
        for (i, row) in enumerate(s.rows)
            i <= n0 || continue
            f = findfirst(x -> x.name === :ORDER, row.form.fields)
            f === nothing && continue
            r = raw_value(row.form, row.form.fields[f])
            r isa AbstractVector && (r = isempty(r) ? nothing : first(r))
            r === nothing || tryparse(Int, strip(string(r))) == i || return true
        end
    end
    false
end

"""
    cleaned_data(tree) -> Dict{String,Any}

The cleaned document: the node's keys (those no form edits are kept from the initial document,
the form's cleaned values replace the rest) and, under each child's name, the list of its active
rows: in their order (sorted by ORDER with `can_order`), without deleted and blank rows.
"""
function cleaned_data(n::NestedForm)
    names = first.(n.children)
    out = Dict{String,Any}(k => v for (k, v) in n.doc if !(Symbol(k) in names))
    for (k, v) in n.form.cleaned_data
        k in (:DELETE, :ORDER, :__all__) && continue
        out[string(k)] = v
    end
    for (name, s) in n.children
        out[string(name)] = cleaned_data(s)
    end
    out
end
function cleaned_data(s::NestedFormSet)
    active = [i for i in eachindex(s.rows) if row_active(s, i)]
    if s.formset.can_order
        key(i) = something(get(s.rows[i].form.cleaned_data, :ORDER, nothing), typemax(Int) ÷ 2 + i)
        sort!(active; by = key)
    end
    Dict{String,Any}[cleaned_data(s.rows[i]) for i in active]
end

# --- access from Julia and templates ---

function nested_child(n::NestedForm, name)
    i = findfirst(c -> c.first === Symbol(name), n.children)
    i === nothing ? nothing : n.children[i].second
end
Base.getindex(n::NestedForm, name::Union{Symbol,AbstractString}) =
    (c = nested_child(n, name); c === nothing ? n.form[name] : c)
"`tree.plates`: a child formset by name (the node's own fields, `form`, `children` and `doc`, come first)."
Base.getproperty(n::NestedForm, s::Symbol) =
    s in (:form, :children, :doc) ? getfield(n, s) : (c = nested_child(n, s); c === nothing ? getfield(n, s) : c)
Base.getindex(s::NestedFormSet, i::Integer) = s.rows[i]
Base.iterate(s::NestedFormSet, i = 1) = i > length(s.rows) ? nothing : (s.rows[i], i + 1)
Base.length(s::NestedFormSet) = length(s.rows)
management_form(s::NestedFormSet) = management_form(s.formset)

"An empty row with `__prefix__` in place of its index (its children's rows are its own extra rows), for adding rows in the page."
function empty_form(s::NestedFormSet)
    f = empty_form(s.formset)
    NestedForm(f, Pair{Symbol,Any}[n => bind_set(sp, nothing, child_prefix(f.prefix, n), nothing) for (n, sp) in s.spec.children],
               Dict{String,Any}())
end

"""
    nested_row(spec::NestedSetSpec, prefix, index) -> NestedForm

A new, empty row of a child formset at `index` (0-based, as in the prefixes), for adding rows
with htmx: `nested_row(spec.plates, "plates", 3)` renders as `plates-3-...`, with its own child
formsets' extra rows. The page then raises its `plates-TOTAL_FORMS` by one.
"""
function nested_row(spec::NestedSetSpec, prefix::AbstractString, index::Integer)
    s = bind_set(NestedSetSpec(spec.form, merge(spec.options, (; extra = 0)), spec.children), nothing, prefix, nothing)
    f = s.formset.make_form(nothing, "$(prefix)-$(index)", Dict{Symbol,Any}(), nothing)
    add_formset_fields!(s.formset, f, typemax(Int))
    NestedForm(f, Pair{Symbol,Any}[n => bind_set(sp, nothing, child_prefix(f.prefix, n), nothing) for (n, sp) in spec.children],
               Dict{String,Any}())
end

"All of a nested form as paragraphs: the form, then each child formset's management form and rows."
function as_p(n::NestedForm)
    io = IOBuffer()
    print(io, as_p(n.form).s)
    for (name, s) in n.children
        print(io, "<fieldset class=\"nested-", escape_html(string(name)), "\">", management_form(s).s)
        foreach(e -> print(io, "<p class=\"errorlist nonform\">", escape_html(e), "</p>"), s.formset.non_form_errors)
        foreach(r -> print(io, "<div class=\"nested-row\">", as_p(r).s, "</div>"), s.rows)
        print(io, "</fieldset>")
    end
    SafeString(String(take!(io)))
end
__html__(n::NestedForm) = as_p(n).s

function tattr(n::NestedForm, ::Val{S}) where {S}
    c = nested_child(n, S)
    c === nothing || return c
    S === :form && return n.form
    S === :as_p && return as_p(n)
    S === :has_changed && return has_changed(n)
    tattr(n.form, Val(S))                                 # the form's fields and the rest
end
function tattr(s::NestedFormSet, ::Val{S}) where {S}
    S === :rows && return s.rows
    S === :empty_form && return empty_form(s)
    S === :management_form && return management_form(s)
    S === :non_form_errors && return s.formset.non_form_errors
    S === :prefix && return s.formset.prefix
    S === :can_delete && return s.formset.can_delete
    S === :can_order && return s.formset.can_order
    NOTFOUND
end

# --- over models ---

"""
    nested_model_form(Model; data = nothing, instance = nothing, fields = nothing, exclude = [], prefix = "",
                      nested = [:items], ...) -> NestedForm

A model form with an inline formset per reverse relation in `nested`: `[:items]`, or
`[:items => (fields = [:product, :qty], extra = 1, can_delete = true, form = ...)]` with the options
`inlineformset_factory` takes. `save!(tree)` saves the object and its children in one
transaction. Other keywords go to `ModelForm`.
"""
function nested_model_form(T::Type; data = nothing, instance = nothing, prefix::AbstractString = "", nested = Symbol[], kw...)
    form = ModelForm(T; data = data, instance = instance, prefix = prefix, kw...)
    kids = Pair{Symbol,Any}[]
    for item in nested
        name, opts = item isa Pair ? (Symbol(item.first), item.second) : (Symbol(item), (;))
        rel = findfirst(r -> r[1] === name, reverse_relations(T))
        rel === nothing && throw(ArgumentError("nested_model_form: $(nameof(T)) has no reverse relation '$name'"))
        _, M, fk = reverse_relations(T)[rel]
        factory = inlineformset_factory(T, M; fk = fk.name, pairs(opts)...)
        fs = factory(data; instance = instance, prefix = child_prefix(prefix, name))
        push!(kids, name => NestedFormSet(fs, nothing, NestedForm[NestedForm(f, Pair{Symbol,Any}[], Dict{String,Any}()) for f in build_forms!(fs)]))
    end
    NestedForm(form, kids, Dict{String,Any}())
end

"""
    save!(tree::NestedForm) -> the saved object

For `nested_model_form`: save the object, then each child formset with its foreign key set to it
(new, changed and deleted rows), in one transaction.
"""
function save!(n::NestedForm)
    n.form.model === nothing && error("save! needs a nested_model_form (a plain nested form gives cleaned_data(tree))")
    is_valid(n) || error("cannot save a nested form with errors")
    atomic() do
        obj = save!(n.form)
        for (_, s) in n.children
            s.formset.parent = obj
            save!(s.formset)
        end
        obj
    end
end
