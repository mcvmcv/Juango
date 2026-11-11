# Formsets ------------------------------------------------------------------------------------------
#
#     ContactFormSet = formset_factory(ContactForm; extra = 2, can_delete = true)
#     fs = ContactFormSet(req.method == "POST" ? req.POST : nothing)
#     if req.method == "POST" && is_valid(fs)
#         for d in cleaned_data(fs) ... end
#     end
#     render(req, "contacts.html", Dict("formset" => fs))
#
#     {{ formset.management_form }}
#     {% for form in formset %}{{ form.as_p }}{% endfor %}
#
#     PostFormSet = modelformset_factory(Post; fields = [:title, :published], extra = 1)
#     CommentFormSet = inlineformset_factory(Post, Comment; fields = [:name, :body])
#     fs = CommentFormSet(req.POST; instance = post); is_valid(fs) && save!(fs)

"""
Several copies of a form on one page, tied together by a management form
(`<prefix>-TOTAL_FORMS`, `-INITIAL_FORMS`, `-MIN_NUM_FORMS`, `-MAX_NUM_FORMS`).
"""
mutable struct FormSet
    make_form::Function          # (data, prefix, initial, instance) -> Form
    prefix::String
    data::Union{Nothing,AbstractDict}
    initial::Vector{Dict{Symbol,Any}}
    instances::Vector{Any}       # model formsets: objects behind the initial forms
    extra::Int
    min_num::Int
    max_num::Int
    validate_min::Bool
    validate_max::Bool
    can_delete::Bool
    can_order::Bool
    clean::Any                   # formset-level clean(fs), may call add_error!(fs, msg)
    forms::Vector{Form}
    non_form_errors::Vector{String}
    validated::Bool
    model::Any                   # model formsets
    fk::Union{Nothing,Field}     # inline formsets: the FK to the parent
    parent::Any
    new_objects::Vector{Any}
    changed_objects::Vector{Any}
    deleted_objects::Vector{Any}
end

const MAX_ABSOLUTE_FORMS = 1000

"Form count of a bound formset from its management form (`nothing` if missing or tampered with)."
function management_count(fs::FormSet, key)
    v = get(fs.data, fs.prefix * "-" * key, nothing)
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v === nothing ? nothing : tryparse(Int, strip(string(v)))
end

initial_form_count(fs::FormSet) = fs.data === nothing ? max(length(fs.initial), length(fs.instances)) :
    something(management_count(fs, "INITIAL_FORMS"), 0)
function total_form_count(fs::FormSet)
    if fs.data !== nothing
        n = something(management_count(fs, "TOTAL_FORMS"), 0)
        return min(n, MAX_ABSOLUTE_FORMS)      # validate_max reports too many; this only stops abuse
    end
    n = initial_form_count(fs)
    min(max(n + fs.extra, fs.min_num + fs.extra), max(n, fs.max_num))
end

function build_forms!(fs::FormSet)
    isempty(fs.forms) || return fs.forms
    n = total_form_count(fs)
    for i in 0:n-1
        init = i < length(fs.initial) ? fs.initial[i+1] : Dict{Symbol,Any}()
        inst = instance_for(fs, i)
        f = fs.make_form(fs.data, "$(fs.prefix)-$i", init, inst)
        add_formset_fields!(fs, f, i)
        push!(fs.forms, f)
    end
    fs.forms
end

function instance_for(fs::FormSet, i)
    fs.model === nothing && return nothing
    i < initial_form_count(fs) || return nothing
    if fs.data !== nothing
        # bound: match the submitted id against the queryset, never trust it blindly
        raw = get(fs.data, "$(fs.prefix)-$i-id", nothing)
        raw isa AbstractVector && (raw = isempty(raw) ? nothing : first(raw))
        id = raw === nothing ? nothing : parse_pk(fs.model, strip(string(raw)))
        return id === nothing ? nothing : findfirst_instance(fs, id)
    end
    i < length(fs.instances) ? fs.instances[i+1] : nothing
end
findfirst_instance(fs, id) = (j = findfirst(o -> o.id == id, fs.instances); j === nothing ? nothing : fs.instances[j])

function add_formset_fields!(fs::FormSet, f::Form, i)
    if fs.model !== nothing
        idf = IntegerField(blank = true, widget = :hidden, required = false)
        idf.name = :id
        f.instance === nothing || (f.initial[:id] = f.instance.id)
        pushfirst!(f.fields, idf)
    end
    if fs.can_order
        o = IntegerField(blank = true, label = "Order")
        o.name = :ORDER
        i < initial_form_count(fs) && (f.initial[:ORDER] = i + 1)
        push!(f.fields, o)
    end
    if fs.can_delete
        d = BooleanField(label = "Delete")
        d.name = :DELETE
        push!(f.fields, d)
    end
    f
end

"An extra form with `__prefix__` in place of the index, for adding forms with JavaScript."
function empty_form(fs::FormSet)
    f = fs.make_form(nothing, "$(fs.prefix)-__prefix__", Dict{Symbol,Any}(), nothing)
    add_formset_fields!(fs, f, typemax(Int))
    f
end

"The hidden management form inputs."
function management_form(fs::FormSet)
    vals = ("TOTAL_FORMS" => total_form_count(fs), "INITIAL_FORMS" => initial_form_count(fs),
            "MIN_NUM_FORMS" => fs.min_num, "MAX_NUM_FORMS" => fs.max_num)
    SafeString(join(["<input type=\"hidden\" name=\"$(escape_html(fs.prefix))-$k\" value=\"$v\" id=\"id_$(escape_html(fs.prefix))-$k\">"
                     for (k, v) in vals]))
end

marked_delete(fs::FormSet, f::Form) = fs.can_delete && (r = raw_value(f, f.fields[end]); f.fields[end].name === :DELETE &&
                                       r !== nothing && lowercase(string(r isa AbstractVector ? first(r) : r)) in ("on", "true", "1", "yes"))
"Extra forms left blank don't count and aren't validated."
blank_extra(fs::FormSet, f::Form, i) = i >= initial_form_count(fs) && !has_changed(f)

function is_valid(fs::FormSet)
    fs.data === nothing && return false
    fs.validated && return isempty(fs.non_form_errors) && all(f -> isempty(f.errors), fs.forms)
    empty!(fs.non_form_errors)
    if management_count(fs, "TOTAL_FORMS") === nothing || management_count(fs, "INITIAL_FORMS") === nothing
        push!(fs.non_form_errors, "ManagementForm data is missing or has been tampered with.")
        fs.validated = true
        return false
    end
    build_forms!(fs)
    counted = 0
    for (i, f) in enumerate(fs.forms)
        if marked_delete(fs, f) || blank_extra(fs, f, i - 1)
            f.validated = true          # not validated, no errors
            continue
        end
        is_valid(f)
        counted += 1
    end
    fs.validate_max && counted > fs.max_num && push!(fs.non_form_errors, "Please submit at most $(fs.max_num) form$(fs.max_num == 1 ? "" : "s").")
    fs.validate_min && counted < fs.min_num && push!(fs.non_form_errors, "Please submit at least $(fs.min_num) form$(fs.min_num == 1 ? "" : "s").")
    fs.clean === nothing || fs.clean(fs)
    fs.validated = true
    isempty(fs.non_form_errors) && all(f -> isempty(f.errors), fs.forms)
end

"Add an error to the formset as a whole."
add_error!(fs::FormSet, msg) = (push!(fs.non_form_errors, string(msg)); nothing)

"Forms that will be saved/used: valid, not deleted and not blank extras."
active_forms(fs::FormSet) = [f for (i, f) in enumerate(build_forms!(fs)) if !marked_delete(fs, f) && !blank_extra(fs, f, i - 1)]
"Cleaned data of the active forms (in order when `can_order`)."
cleaned_data(fs::FormSet) = [f.cleaned_data for f in (fs.can_order ? ordered_forms(fs) : active_forms(fs))]
"Forms marked for deletion."
deleted_forms(fs::FormSet) = [f for f in build_forms!(fs) if marked_delete(fs, f)]
"Active forms sorted by their ORDER field (blank last)."
ordered_forms(fs::FormSet) =
    sort(active_forms(fs); by = f -> something(get(f.cleaned_data, :ORDER, nothing), typemax(Int)))

Base.iterate(fs::FormSet, i = 1) = (fs_ = build_forms!(fs); i > length(fs_) ? nothing : (fs_[i], i + 1))
Base.length(fs::FormSet) = length(build_forms!(fs))
Base.getindex(fs::FormSet, i::Integer) = build_forms!(fs)[i]
errors(fs::FormSet) = [f.errors for f in build_forms!(fs)]

as_p(fs::FormSet) = SafeString(management_form(fs).s * join([as_p(f).s for f in fs], "\n"))
as_table(fs::FormSet) = SafeString(management_form(fs).s * join([as_table(f).s for f in fs], "\n"))
__html__(fs::FormSet) = as_p(fs).s

function tattr(fs::FormSet, ::Val{S}) where {S}
    S === :management_form && return management_form(fs)
    S === :forms && return build_forms!(fs)
    S === :empty_form && return empty_form(fs)
    S === :non_form_errors && return fs.non_form_errors
    S === :errors && return errors(fs)
    S === :total_form_count && return total_form_count(fs)
    S === :initial_form_count && return initial_form_count(fs)
    S === :prefix && return fs.prefix
    S === :as_p && return as_p(fs)
    S === :as_table && return as_table(fs)
    S === :can_delete && return fs.can_delete
    S === :can_order && return fs.can_order
    NOTFOUND
end

function new_formset(make_form; prefix, data, initial, instances, extra, min_num, max_num, validate_min, validate_max,
                     can_delete, can_order, clean, model = nothing, fk = nothing, parent = nothing)
    FormSet(make_form, string(prefix), data, Dict{Symbol,Any}[Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(d)) for d in initial],
            collect(Any, instances), extra, min_num, max_num, validate_min, validate_max, can_delete, can_order, clean,
            Form[], String[], false, model, fk, parent, Any[], Any[], Any[])
end

"""
    formset_factory(FormConstructor; extra=1, can_delete=false, can_order=false, min_num=0,
                    max_num=1000, validate_min=false, validate_max=false, clean=nothing)

Returns `(data=nothing; initial=[], prefix="form") -> FormSet`. `FormConstructor` is a
`@form` constructor (anything callable as `F(data; prefix, initial)`).
"""
function formset_factory(F; extra = 1, can_delete = false, can_order = false, min_num = 0, max_num = 1000,
                         validate_min = false, validate_max = false, clean = nothing)
    (data = nothing; initial = [], prefix = "form") -> new_formset(
        (d, p, init, _) -> F(d; prefix = p, initial = init); prefix = prefix, data = data, initial = collect(initial),
        instances = [], extra = extra, min_num = min_num, max_num = max_num, validate_min = validate_min,
        validate_max = validate_max, can_delete = can_delete, can_order = can_order, clean = clean)
end

"""
    modelformset_factory(Model; fields=nothing, exclude=[], extra=1, can_delete=false, ...)

Returns `(data=nothing; queryset=objects(Model), prefix="form") -> FormSet` of `ModelForm`s,
one per object plus `extra` blank ones. `save!(formset)` saves changed and new objects and
deletes those marked for deletion.
"""
function modelformset_factory(T::Type; fields = nothing, exclude = Symbol[], extra = 1, can_delete = false,
                              can_order = false, min_num = 0, max_num = 1000, validate_min = false,
                              validate_max = false, clean = nothing, widgets = Dict{Symbol,Symbol}(),
                              labels = Dict{Symbol,String}())
    (data = nothing; queryset = objects(T), prefix = "form", initial = []) -> new_formset(
        (d, p, init, inst) -> ModelForm(T; data = d, instance = inst, fields = fields, exclude = exclude, prefix = p,
                                        initial = init, widgets = widgets, labels = labels);
        prefix = prefix, data = data, initial = collect(initial), instances = collect(queryset), extra = extra,
        min_num = min_num, max_num = max_num, validate_min = validate_min, validate_max = validate_max,
        can_delete = can_delete, can_order = can_order, clean = clean, model = T)
end

"""
    inlineformset_factory(Parent, Child; fk=nothing, fields=nothing, extra=3, can_delete=true, ...)

A model formset of `Child` objects belonging to one `Parent` (through the FK `fk`, found
automatically when there is only one). Returns `(data=nothing; instance=parent, prefix=...) -> FormSet`.
The FK isn't a form field; `save!` sets it to the parent.
"""
function inlineformset_factory(P::Type, T::Type; fk = nothing, fields = nothing, exclude = Symbol[], extra = 3,
                               can_delete = true, can_order = false, min_num = 0, max_num = 1000,
                               validate_min = false, validate_max = false, clean = nothing,
                               widgets = Dict{Symbol,Symbol}(), labels = Dict{Symbol,String}())
    fks = [f for f in all_fields(T) if f.kind === :fk && P in lineage(related_model(f)) && (fk === nothing || f.name === Symbol(fk))]
    length(fks) == 1 || throw(ArgumentError("$T needs exactly one foreign key to $P (pass fk=:name), found $(length(fks))"))
    fkf = only(fks)
    excl = vcat(Symbol.(collect(exclude)), [fkf.name])
    flds = fields === nothing ? nothing : [Symbol(f) for f in fields if Symbol(f) !== fkf.name]
    function (data = nothing; instance = nothing, prefix = string(reverse_name(fkf)), queryset = nothing)
        qs = instance === nothing || instance.id === nothing ? none(T) :
             something(queryset, filter(objects(T), Q(attname(fkf) => instance.id)))
        new_formset((d, p, init, inst) -> ModelForm(T; data = d, instance = inst, fields = flds, exclude = excl,
                                                     prefix = p, initial = init, widgets = widgets, labels = labels);
                    prefix = prefix, data = data, initial = [], instances = collect(qs), extra = extra, min_num = min_num,
                    max_num = max_num, validate_min = validate_min, validate_max = validate_max, can_delete = can_delete,
                    can_order = can_order, clean = clean, model = T, fk = fkf, parent = instance)
    end
end

"""
    save!(formset::FormSet; commit=true) -> Vector of saved objects

Model formsets: save new and changed objects, delete those marked for deletion. The lists
are also available as `formset.new_objects`, `changed_objects` and `deleted_objects`.
"""
function save!(fs::FormSet; commit = true)
    fs.model === nothing && error("save! needs a model formset")
    is_valid(fs) || error("cannot save a formset with errors")
    empty!(fs.new_objects); empty!(fs.changed_objects); empty!(fs.deleted_objects)
    saved = Any[]
    atomic() do
        for (i, f) in enumerate(fs.forms)
            if marked_delete(fs, f)
                f.instance === nothing || (push!(fs.deleted_objects, f.instance); commit && delete!(f.instance))
                continue
            end
            blank_extra(fs, f, i - 1) && continue
            (f.instance !== nothing && !has_changed(f)) && continue
            isnew = f.instance === nothing
            obj = save!(f; commit = false)
            fs.fk === nothing || setproperty!(obj, fs.fk.name, fs.parent)
            if commit
                save!(obj)
                save_m2m!(f)
            end
            push!(isnew ? fs.new_objects : fs.changed_objects, obj)
            push!(saved, obj)
        end
    end
    saved
end
