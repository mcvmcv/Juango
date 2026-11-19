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
    name::String                 # for repr: "ChoiceFormSet"
    auto_id::Any                 # given to each form (nothing: the form's default)
    form_kwargs::Dict{Symbol,Any}   # more keyword arguments for each form (Django's form_kwargs)
    error_messages::Dict{String,String}   # too_many_forms, too_few_forms, missing_management_form
    absolute_max::Int            # the most forms a bound formset makes, whatever TOTAL_FORMS says
    can_delete_extra::Bool       # false: only the initial forms get a DELETE box
end

"The default `max_num`; `absolute_max` defaults to twice it (Django's DEFAULT_MAX_NUM)."
const DEFAULT_MAX_NUM = 1000

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
        return min(n, fs.absolute_max)      # validation reports too many; this only stops abuse
    end
    n = initial_form_count(fs)
    min(max(n + fs.extra, fs.min_num + fs.extra), max(n, fs.max_num))
end

function build_forms!(fs::FormSet)
    built = getfield(fs, :forms)
    isempty(built) || return built
    n = total_form_count(fs)
    n0 = initial_form_count(fs)
    for i in 0:n-1
        init = i < length(fs.initial) ? fs.initial[i+1] : Dict{Symbol,Any}()
        inst = instance_for(fs, i)
        f = make_row(fs, fs.data, "$(fs.prefix)-$i", init, inst)
        if f isa Form
            f.use_required_attribute = false     # as Django: an extra form left empty mustn't block submitting
            # (an extra form beyond min_num may be left empty: valid, with nothing cleaned, as Django's)
            f.empty_permitted = i >= n0 && i >= fs.min_num
        end
        add_formset_fields!(fs, f, i)
        push!(built, f)
    end
    built
end
"A form of the formset, with the formset's `auto_id` and `form_kwargs` (when it has any)."
function make_row(fs::FormSet, data, prefix, init, inst)
    kw = copy(fs.form_kwargs)
    fs.auto_id === nothing || (kw[:auto_id] = fs.auto_id)
    isempty(kw) ? fs.make_form(data, prefix, init, inst) : fs.make_form(data, prefix, init, inst; kw...)
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
        o = IntegerField(blank = true, required = false, label = "Order")
        o.name = :ORDER
        i < initial_form_count(fs) && (f.initial[:ORDER] = i + 1)
        push!(f.fields, o)
    end
    if fs.can_delete && (fs.can_delete_extra || i < initial_form_count(fs))
        d = BooleanField(label = "Delete", required = false)
        d.name = :DELETE
        push!(f.fields, d)
    end
    f
end

"An extra form with `__prefix__` in place of the index, for adding forms with JavaScript."
function empty_form(fs::FormSet)
    f = make_row(fs, nothing, "$(fs.prefix)-__prefix__", Dict{Symbol,Any}(), nothing)
    f isa Form && (f.use_required_attribute = false; f.empty_permitted = true)
    add_formset_fields!(fs, f, typemax(Int))
    f
end

const MANAGEMENT_KEYS = ("TOTAL_FORMS", "INITIAL_FORMS", "MIN_NUM_FORMS", "MAX_NUM_FORMS")
"""
The hidden management form inputs: the counts, or a bound formset's submitted values (as Django's
bound `ManagementForm`), with ids from the formset's `auto_id`.
"""
function management_form(fs::FormSet)
    p = escape_html(fs.prefix)
    a = fs.auto_id === nothing ? "id_%s" : fs.auto_id
    idfor(k) = (a === false || a === nothing || a == "") ? "" : a === true ? "$p-$k" : replace(string(a), "%s" => "$p-$k")
    vals = Dict("TOTAL_FORMS" => total_form_count(fs), "INITIAL_FORMS" => initial_form_count(fs),
                "MIN_NUM_FORMS" => fs.min_num, "MAX_NUM_FORMS" => fs.max_num)
    val(k) = if fs.data === nothing
        vals[k]
    else
        v = get(fs.data, fs.prefix * "-" * k, nothing)
        v isa AbstractVector ? (isempty(v) ? nothing : first(v)) : v
    end
    SafeString(join(["<input type=\"hidden\" name=\"$p-$k\"" * ((v = val(k)) === nothing ? "" : " value=\"" * escape_html(string(v)) * "\"") *
                     id_attr(idfor(k)) * ">" for k in MANAGEMENT_KEYS]))
end

marked_delete(fs::FormSet, f::Form) = fs.can_delete && (j = findlast(x -> x.name === :DELETE, f.fields); j !== nothing &&
                                       (r = raw_value(f, f.fields[j]); r !== nothing && lowercase(string(r isa AbstractVector ? first(r) : r)) in ("on", "true", "1", "yes")))
"Extra forms left blank don't count and aren't validated."
blank_extra(fs::FormSet, f::Form, i) = i >= initial_form_count(fs) && !has_changed(f)

fs_valid(fs::FormSet) = isempty(fs.non_form_errors) && all(f -> marked_delete(fs, f) || isempty(f.errors), fs.forms)
fs_message(fs::FormSet, code, default, n) =
    (m = get(fs.error_messages, code, nothing); m === nothing ? default : replace(m, r"%\(num\)[ds]" => string(n)))

"""
    is_valid(formset) -> Bool

Validate every form, as Django's `full_clean`: a form ticked for deletion is cleaned but its errors
don't count; an extra form left empty is valid. Then `validate_max`/`validate_min` (forms ticked
for deletion, and for `min_num` empty ones, don't count) and the formset's `clean`.
"""
function is_valid(fs::FormSet)
    fs.data === nothing && return false
    fs.validated && return fs_valid(fs)
    empty!(fs.non_form_errors)
    fs.validated = true
    bad = [fs.prefix * "-" * k for k in ("TOTAL_FORMS", "INITIAL_FORMS") if management_count(fs, k) === nothing]
    if !isempty(bad)
        push!(fs.non_form_errors, interpolate(get(fs.error_messages, "missing_management_form",
            gettext("ManagementForm data is missing or has been tampered with. Missing fields: %(field_names)s. You may need to file a bug report if the issue persists.")),
            Dict("field_names" => join(bad, ", "))))
        return false
    end
    build_forms!(fs)
    n0, empty = initial_form_count(fs), 0
    for (i, f) in enumerate(fs.forms)
        i - 1 >= n0 && !has_changed(f) && (empty += 1)
        is_valid(f)
    end
    total, deleted = length(fs.forms), count(f -> marked_delete(fs, f), fs.forms)
    submitted = something(management_count(fs, "TOTAL_FORMS"), 0)
    if (fs.validate_max && total - deleted > fs.max_num) || submitted > fs.absolute_max
        push!(fs.non_form_errors, fs_message(fs, "too_many_forms",
            replace(ngettext("Please submit at most %d form.", "Please submit at most %d forms.", fs.max_num), "%d" => string(fs.max_num)), fs.max_num))
    elseif fs.validate_min && total - deleted - empty < fs.min_num
        push!(fs.non_form_errors, fs_message(fs, "too_few_forms",
            replace(ngettext("Please submit at least %d form.", "Please submit at least %d forms.", fs.min_num), "%d" => string(fs.min_num)), fs.min_num))
    elseif fs.clean !== nothing
        try
            fs.clean(fs)
        catch e
            e isa ValidationError || rethrow()
            append!(fs.non_form_errors, reduce(vcat, collect(values(e.errors)); init = String[]))
        end
    end
    fs_valid(fs)
end

"Add an error to the formset as a whole."
add_error!(fs::FormSet, msg) = (push!(fs.non_form_errors, string(msg)); nothing)

"""
    non_form_errors(formset) -> ErrorList

The formset's own errors (the management form's, `validate_max`/`validate_min`'s, its `clean`'s),
validating it first, as an `ErrorList` with the class `nonform`.
"""
non_form_errors(fs::FormSet) = (fs.data !== nothing && !fs.validated && is_valid(fs); ErrorList(fs.non_form_errors; error_class = "nonform"))
"The number of errors: the formset's own and every counted form's (Django's `total_error_count()`)."
total_error_count(fs::FormSet) = length(non_form_errors(fs)) + sum((sum(length, values(e); init = 0) for e in errors(fs)); init = 0)
"Whether any form's data differs from its initial values."
has_changed(fs::FormSet) = fs.data !== nothing && any(has_changed, build_forms!(fs))
"Whether a form needs a multipart encoding (a file input): its forms', or the empty form's when it has none."
is_multipart(fs::FormSet) = (fs_ = build_forms!(fs); isempty(fs_) ? is_multipart(empty_form(fs)) : any(is_multipart, fs_))
"Validate every formset or form (all of them, even after one fails); whether all are valid (Django's `all_valid`)."
all_valid(xs) = foldl((ok, x) -> is_valid(x) & ok, xs; init = true)
Base.show(io::IO, fs::FormSet) = print(io, "<", fs.name, ": bound=", fs.data !== nothing ? "True" : "False", " valid=",
    !fs.validated ? "Unknown" : fs_valid(fs) ? "True" : "False", " total_forms=", total_form_count(fs), ">")

"Whether a formset row is ticked for deletion (Django's `_should_delete_form`, made public)."
is_deleted(fs::FormSet, f::Form) = marked_delete(fs, f)
"Whether a formset row is an extra row left blank: it doesn't count and isn't validated or saved."
function is_blank_extra(fs::FormSet, f::Form)
    i = findfirst(x -> x === f, build_forms!(fs))
    i !== nothing && blank_extra(fs, f, i - 1)
end
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
"Each counted form's errors (not those ticked for deletion), validating the formset first, as Django's `formset.errors`."
errors(fs::FormSet) = (fs.data !== nothing && !fs.validated && is_valid(fs);
                       [f.errors for f in build_forms!(fs) if !marked_delete(fs, f)])

as_p(fs::FormSet) = SafeString(management_form(fs).s * join([as_p(f).s for f in fs], "\n"))
as_table(fs::FormSet) = SafeString(management_form(fs).s * join([as_table(f).s for f in fs], "\n"))
as_ul(fs::FormSet) = SafeString(management_form(fs).s * join([as_ul(f).s for f in fs], "\n"))
as_div(fs::FormSet) = SafeString(management_form(fs).s * join([as_div(f).s for f in fs], "\n"))
__html__(fs::FormSet) = as_p(fs).s

"`fs.forms` builds the forms on first use, as Django's formset.forms does (the field holds them once built)."
Base.getproperty(fs::FormSet, s::Symbol) = s === :forms ? build_forms!(fs) : getfield(fs, s)

function tattr(fs::FormSet, ::Val{S}) where {S}
    S === :management_form && return management_form(fs)
    S === :forms && return build_forms!(fs)
    S === :empty_form && return empty_form(fs)
    S === :non_form_errors && return non_form_errors(fs)
    S === :errors && return errors(fs)
    S === :total_form_count && return total_form_count(fs)
    S === :initial_form_count && return initial_form_count(fs)
    S === :prefix && return fs.prefix
    S === :as_p && return as_p(fs)
    S === :as_table && return as_table(fs)
    S === :as_ul && return as_ul(fs)
    S === :as_div && return as_div(fs)
    S === :is_bound && return fs.data !== nothing
    S === :total_error_count && return total_error_count(fs)
    S === :can_delete && return fs.can_delete
    S === :can_order && return fs.can_order
    NOTFOUND
end

function new_formset(make_form; prefix, data, initial, instances, extra, min_num, max_num, validate_min, validate_max,
                     can_delete, can_order, clean, model = nothing, fk = nothing, parent = nothing, name = "FormSet",
                     auto_id = nothing, form_kwargs = nothing, error_messages = nothing, absolute_max = nothing,
                     can_delete_extra = true)
    max_num = max_num === nothing ? DEFAULT_MAX_NUM : max_num
    absolute_max = absolute_max === nothing ? max_num + DEFAULT_MAX_NUM : absolute_max
    FormSet(make_form, string(prefix), data, Dict{Symbol,Any}[Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(d)) for d in initial],
            collect(Any, instances), extra, min_num, max_num, validate_min, validate_max, can_delete, can_order, clean,
            Form[], String[], false, model, fk, parent, Any[], Any[], Any[], string(name), auto_id,
            Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(something(form_kwargs, Dict()))),
            Dict{String,String}(string(k) => string(v) for (k, v) in pairs_of(something(error_messages, Dict()))),
            absolute_max, can_delete_extra)
end
"The name a formset shows as: the form's name and \"FormSet\" (Django's), else \"FormSet\"."
formset_name(F) = (n = try string(nameof(F)) catch; "" end; isempty(n) || startswith(n, "#") ? "FormSet" : n * "FormSet")
"Django's check: `absolute_max` may not be below `max_num`."
check_absolute_max(max_num, absolute_max) =
    absolute_max !== nothing && absolute_max < something(max_num, DEFAULT_MAX_NUM) &&
        throw(ArgumentError("'absolute_max' must be greater or equal to 'max_num'."))

"""
    formset_factory(FormConstructor; extra=1, can_delete=false, can_delete_extra=true, can_order=false, min_num=0,
                    max_num=1000, absolute_max=max_num+1000, validate_min=false, validate_max=false, clean=nothing)

Returns `(data=nothing; initial=[], prefix="form", auto_id, form_kwargs, error_messages) -> FormSet`.
`FormConstructor` is a `@form` constructor (anything callable as `F(data; prefix, initial)`, and with
`auto_id` and `form_kwargs` as keyword arguments when they're given). `clean(fs)` may call
`add_error!(fs, msg)` or throw a `ValidationError`. A bound formset makes at most `absolute_max`
forms.
"""
function formset_factory(F; extra = 1, can_delete = false, can_order = false, min_num = 0, max_num = nothing,
                         validate_min = false, validate_max = false, clean = nothing, absolute_max = nothing,
                         can_delete_extra = true, name = formset_name(F))
    check_absolute_max(max_num, absolute_max)
    (data = nothing; initial = [], prefix = "form", auto_id = nothing, form_kwargs = nothing, error_messages = nothing) -> new_formset(
        (d, p, init, _; kw...) -> F(d; prefix = p, initial = init, kw...); prefix = prefix, data = data,
        initial = initial === nothing ? [] : collect(initial),
        instances = [], extra = extra, min_num = min_num, max_num = max_num, validate_min = validate_min,
        validate_max = validate_max, can_delete = can_delete, can_order = can_order, clean = clean, name = name,
        auto_id = auto_id, form_kwargs = form_kwargs, error_messages = error_messages, absolute_max = absolute_max,
        can_delete_extra = can_delete_extra)
end

"""
    modelformset_factory(Model; fields=nothing, exclude=[], extra=1, can_delete=false, form=nothing, ...)

Returns `(data=nothing; queryset=objects(Model), prefix="form") -> FormSet` of `ModelForm`s,
one per object plus `extra` blank ones. `save!(formset)` saves changed and new objects and
deletes those marked for deletion.

Each row is `ModelForm(Model; fields, exclude, widgets, labels, help_texts, field_classes,
extra_fields, formfield_callback, error_messages)`, or, with `form`, what that function builds
(Django's `form=`): `form(; data, instance, prefix, initial)` returning a ModelForm of the model,
for rows with their own fields, `clean` or initial values worked out from the instance:

    row(; data, instance, prefix, initial) = (f = ModelForm(Setting; data, instance, prefix, initial, fields = [:name, :value]);
                                              set_field!(f, :value, CharField(); after = :name); f)
    SettingsFormSet = modelformset_factory(Setting; form = row, extra = 0)
"""
function modelformset_factory(T::Type; fields = nothing, exclude = Symbol[], extra = 1, can_delete = false,
                              can_order = false, min_num = 0, max_num = 1000, validate_min = false,
                              validate_max = false, clean = nothing, widgets = Dict{Symbol,Symbol}(),
                              labels = Dict{Symbol,String}(), form = nothing, help_texts = Dict{Symbol,String}(),
                              field_classes = Dict{Symbol,Any}(), extra_fields = Pair{Symbol,Any}[],
                              formfield_callback = nothing, error_messages = Dict{Symbol,Any}())
    make = row_form(T, form; fields, exclude, widgets, labels, help_texts, field_classes, extra_fields, formfield_callback, error_messages)
    (data = nothing; queryset = objects(T), prefix = "form", initial = []) -> new_formset(
        make;
        prefix = prefix, data = data, initial = collect(initial), instances = collect(queryset), extra = extra,
        min_num = min_num, max_num = max_num, validate_min = validate_min, validate_max = validate_max,
        can_delete = can_delete, can_order = can_order, clean = clean, model = T)
end

"How a model formset makes its rows: the `form` function, else a ModelForm with these options."
function row_form(T, form; fields, exclude, widgets, labels, help_texts, field_classes, extra_fields, formfield_callback, error_messages)
    form === nothing || return (d, p, init, inst) -> form(; data = d, instance = inst, prefix = p, initial = init)
    (d, p, init, inst) -> ModelForm(T; data = d, instance = inst, fields = fields, exclude = exclude, prefix = p, initial = init,
                                    widgets = widgets, labels = labels, help_texts = help_texts, field_classes = field_classes,
                                    extra_fields = extra_fields, formfield_callback = formfield_callback, error_messages = error_messages)
end

"""
    inlineformset_factory(Parent, Child; fk=nothing, fields=nothing, extra=3, can_delete=true, form=nothing, ...)

A model formset of `Child` objects belonging to one `Parent` (through the FK `fk`, found
automatically when there is only one). Returns `(data=nothing; instance=parent, prefix=...) -> FormSet`.
The FK isn't a form field; `save!` sets it to the parent. `form` and the ModelForm options are as
for `modelformset_factory`.
"""
function inlineformset_factory(P::Type, T::Type; fk = nothing, fields = nothing, exclude = Symbol[], extra = 3,
                               can_delete = true, can_order = false, min_num = 0, max_num = 1000,
                               validate_min = false, validate_max = false, clean = nothing,
                               widgets = Dict{Symbol,Symbol}(), labels = Dict{Symbol,String}(), form = nothing,
                               help_texts = Dict{Symbol,String}(), field_classes = Dict{Symbol,Any}(),
                               extra_fields = Pair{Symbol,Any}[], formfield_callback = nothing, error_messages = Dict{Symbol,Any}())
    fks = [f for f in all_fields(T) if f.kind === :fk && P in lineage(related_model(f)) && (fk === nothing || f.name === Symbol(fk))]
    length(fks) == 1 || throw(ArgumentError("$T needs exactly one foreign key to $P (pass fk=:name), found $(length(fks))"))
    fkf = only(fks)
    excl = vcat(Symbol.(collect(exclude)), [fkf.name])
    flds = fields === nothing ? nothing : [Symbol(f) for f in fields if Symbol(f) !== fkf.name]
    make = row_form(T, form; fields = flds, exclude = excl, widgets, labels, help_texts, field_classes, extra_fields,
                    formfield_callback, error_messages)
    function (data = nothing; instance = nothing, prefix = string(reverse_name(fkf)), queryset = nothing)
        qs = instance === nothing || instance.id === nothing ? none(T) :
             something(queryset, filter(objects(T), Q(attname(fkf) => instance.id)))
        new_formset(make;
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
