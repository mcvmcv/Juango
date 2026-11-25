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
    saved_forms::Vector{Form}    # model formsets: the forms save!(fs; commit = false) saved, for save_m2m!(fs)
    edit_only::Bool              # model formsets: save! changes existing objects but makes no new ones
end

"The default `max_num`; `absolute_max` defaults to twice it (Django's DEFAULT_MAX_NUM)."
const DEFAULT_MAX_NUM = 1000

"Form count of a bound formset from its management form (`nothing` if missing or tampered with)."
function management_count(fs::FormSet, key)
    v = get(fs.data, fs.prefix * "-" * key, nothing)
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v === nothing ? nothing : tryparse(Int, strip(string(v)))
end

# (a model formset's initial forms are its objects; its `initial` fills the extra forms, as Django's initial_extra)
initial_form_count(fs::FormSet) = fs.data === nothing ? (fs.model !== nothing ? length(fs.instances) : length(fs.initial)) :
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
        j = fs.model === nothing ? i : i - n0         # (a model formset's initial: its extra forms')
        init = 0 <= j < length(fs.initial) ? fs.initial[j+1] : Dict{Symbol,Any}()
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
        raw = get(fs.data, "$(fs.prefix)-$i-$(row_pk_name(fs))", nothing)
        raw isa AbstractVector && (raw = isempty(raw) ? nothing : first(raw))
        id = raw === nothing ? nothing : parse_pk(fs.model, strip(string(raw)))
        return id === nothing ? nothing : findfirst_instance(fs, id)
    end
    i < length(fs.instances) ? fs.instances[i+1] : nothing
end
findfirst_instance(fs, id) = (j = findfirst(o -> o.id == id, fs.instances); j === nothing ? nothing : fs.instances[j])
"The field naming a model formset row's object: `id`, or a model's own primary key field (which is on the form)."
row_pk_name(fs::FormSet) = natural_pk(fs.model) ? pk_fields(fs.model)[1].name : :id

function add_formset_fields!(fs::FormSet, f::Form, i)
    if fs.model !== nothing && row_pk_name(fs) === :id     # (a model's own primary key field is on the form already)
        idf = IntegerField(blank = true, widget = :hidden, required = false)
        idf.name = :id
        f.instance === nothing || (f.initial[:id] = f.instance.id)
        pushfirst!(f.fields, idf)
    end
    # an inline formset's row has the parent's key in a hidden input, as Django's InlineForeignKeyField:
    # a different value is an error, and the object gets the parent whatever is sent
    if fs.fk !== nothing
        filter!(x -> x.name !== fs.fk.name, f.fields)      # (a row form's own field for the key is replaced, as Django's)
        # (the value the key stores: the parent's id, or its to_field value)
        pv = fs.parent === nothing || fs.parent.id === nothing ? nothing : target_value(fs.fk, fs.parent)
        pid = pv === nothing ? "" : string(pv)
        bad = gettext("The inline value did not match the parent instance.")
        ff = CharField(max_length = nothing, widget = :hidden, required = false, validators = Any[v -> (v == "" || v == pid) || bad])
        ff.name = fs.fk.name
        ff.form = Dict{Symbol,Any}(:inline_fk => fs.parent)
        f.initial[fs.fk.name] = pid
        pushfirst!(f.fields, ff)            # (its hidden input before the row's id, as Django's)
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
        i - 1 < n0 && check_row_id!(fs, f, i - 1)
    end
    total, deleted = length(fs.forms), count(f -> marked_delete(fs, f), fs.forms)
    submitted = something(management_count(fs, "TOTAL_FORMS"), 0)
    if (fs.validate_max && total - deleted > fs.max_num) || submitted > fs.absolute_max
        push!(fs.non_form_errors, fs_message(fs, "too_many_forms",
            replace(ngettext("Please submit at most %d form.", "Please submit at most %d forms.", fs.max_num), "%d" => string(fs.max_num)), fs.max_num))
    elseif fs.validate_min && total - deleted - empty < fs.min_num
        push!(fs.non_form_errors, fs_message(fs, "too_few_forms",
            replace(ngettext("Please submit at least %d form.", "Please submit at least %d forms.", fs.min_num), "%d" => string(fs.min_num)), fs.min_num))
    else
        fs.model === nothing || model_formset_unique!(fs)
        fs.clean === nothing || try
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
__html__(fs::FormSet) = as_div(fs).s          # (as Django 5's default)

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
                     can_delete_extra = true, edit_only::Bool = false)
    max_num = max_num === nothing ? DEFAULT_MAX_NUM : max_num
    absolute_max = absolute_max === nothing ? max_num + DEFAULT_MAX_NUM : absolute_max
    FormSet(make_form, string(prefix), data, Dict{Symbol,Any}[Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(d)) for d in initial],
            collect(Any, instances), extra, min_num, max_num, validate_min, validate_max, can_delete, can_order, clean,
            Form[], String[], false, model, fk, parent, Any[], Any[], Any[], string(name), auto_id,
            Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(something(form_kwargs, Dict()))),
            Dict{String,String}(string(k) => string(v) for (k, v) in pairs_of(something(error_messages, Dict()))),
            absolute_max, can_delete_extra, Form[], edit_only)
end
"The forms for existing objects or initial data (Django's `initial_forms`)."
initial_forms(fs::FormSet) = (fs_ = build_forms!(fs); fs_[1:min(initial_form_count(fs), length(fs_))])
"The forms after the initial ones (Django's `extra_forms`)."
extra_forms(fs::FormSet) = (fs_ = build_forms!(fs); fs_[min(initial_form_count(fs), length(fs_))+1:end])
"A formset's form on its own, with no prefix (Django's `FormSet.form()`), bound to `data` if given."
formset_form(fs::FormSet; data = nothing) = fs.make_form(data, "", Dict{Symbol,Any}(), nothing)
"A model formset's objects, those its initial forms edit (Django's `get_queryset()`)."
get_queryset(fs::FormSet) = fs.instances

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
                              formfield_callback = nothing, error_messages = Dict{Symbol,Any}(), edit_only::Bool = false,
                              absolute_max = nothing, can_delete_extra::Bool = true)
    make = row_form(T, form; fields, exclude, widgets, labels, help_texts, field_classes, extra_fields, formfield_callback, error_messages)
    (data = nothing; queryset = objects(T), prefix = "form", initial = []) -> new_formset(
        make;
        prefix = prefix, data = data, initial = collect(initial), instances = collect(queryset), extra = extra,
        min_num = min_num, max_num = max_num, validate_min = validate_min, validate_max = validate_max,
        can_delete = can_delete, can_order = can_order, clean = clean, model = T, edit_only, absolute_max, can_delete_extra)
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
                               extra_fields = Pair{Symbol,Any}[], formfield_callback = nothing, error_messages = Dict{Symbol,Any}(),
                               edit_only::Bool = false, absolute_max = nothing, can_delete_extra::Bool = true)
    if fk !== nothing         # (Django's messages)
        g = findfield(modelmeta(T), Symbol(fk))
        g === nothing && throw(ArgumentError("'$(nameof(T))' has no field named '$fk'."))
        (g.kind !== :fk || !(P in lineage(related_model(g)))) && throw(ArgumentError("fk_name '$fk' is not a ForeignKey to '$(nameof(P))'."))
    end
    fks = [f for f in all_fields(T) if f.kind === :fk && P in lineage(related_model(f)) && (fk === nothing || f.name === Symbol(fk))]
    isempty(fks) && throw(ArgumentError("'$(nameof(T))' has no ForeignKey to '$(nameof(P))'."))
    length(fks) > 1 && throw(ArgumentError("'$(nameof(T))' has more than one ForeignKey to '$(nameof(P))'. You must specify a 'fk_name' attribute."))
    fkf = only(fks)
    (fkf.unique || fkf.one_to_one) && (max_num = 1)        # (one child at most, as Django's)
    excl = vcat(Symbol.(collect(exclude)), [fkf.name])
    flds = all_fields_option(fields) ? fields : [Symbol(f) for f in fields if Symbol(f) !== fkf.name]
    make = row_form(T, form; fields = flds, exclude = excl, widgets, labels, help_texts, field_classes, extra_fields,
                    formfield_callback, error_messages)
    # (a multi-table child's inherited key: its related_name, else the child's own name, as Django's alternatebook_set)
    default_prefix = fkf.model === T || fkf.related_name !== nothing ? string(reverse_name(fkf)) : lowercase(modelmeta(T).name) * "_set"
    function (data = nothing; instance = nothing, prefix = default_prefix, queryset = nothing, save_as_new::Bool = false, initial = [])
        # (a queryset given is narrowed to the parent's objects too, as Django's)
        qs = instance === nothing || instance.id === nothing ? none(T) :
             filter(something(queryset, objects(T)), Q(attname(fkf) => target_value(fkf, instance)))
        # save_as_new: every row is a new object for this parent (the admin's "save as new"); the data isn't changed
        if save_as_new
            qs = none(T)
            if data !== nothing
                d = Dict{String,Any}(k => data isa QueryDict ? getlist(data, k) : v for (k, v) in data)
                foreach(k -> d[k] isa AbstractVector && length(d[k]) == 1 && (d[k] = d[k][1]), collect(keys(d)))
                d["$prefix-INITIAL_FORMS"] = "0"
                for k in collect(keys(d))
                    endswith(k, "-id") && startswith(k, prefix * "-") && delete!(d, k)
                end
                data = d
            end
        end
        new_formset(make;
                    prefix = prefix, data = data, initial = collect(initial), instances = collect(qs), extra = extra, min_num = min_num,
                    max_num = max_num, validate_min = validate_min, validate_max = validate_max, can_delete = can_delete,
                    can_order = can_order, clean = clean, model = T, fk = fkf, parent = instance, edit_only, absolute_max,
                    can_delete_extra)
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
    empty!(fs.new_objects); empty!(fs.changed_objects); empty!(fs.deleted_objects); empty!(fs.saved_forms)
    saved = Any[]
    atomic() do
        for (i, f) in enumerate(fs.forms)
            if marked_delete(fs, f)
                f.instance === nothing || (push!(fs.deleted_objects, f.instance); commit && delete!(f.instance))
                continue
            end
            blank_extra(fs, f, i - 1) && continue
            # (an initial row for an object outside the queryset changes nothing, and edit_only makes no new objects)
            f.instance === nothing && (i - 1 < initial_form_count(fs) || fs.edit_only) && continue
            (f.instance !== nothing && !has_changed(f)) && continue
            isnew = f.instance === nothing
            obj = save!(f; commit = false)
            fs.fk === nothing || setproperty!(obj, fs.fk.name, fs.parent)
            if commit
                save!(obj)
                save_m2m!(f)
            else
                push!(fs.saved_forms, f)          # (their many-to-many fields: save_m2m!(fs) once the objects are saved)
            end
            push!(isnew ? fs.new_objects : fs.changed_objects, obj)
            push!(saved, obj)
        end
    end
    saved
end

"""
An initial row of a model formset must name an object (Django's hidden ModelChoiceField for the
key): no id is "required", an id that isn't one of the model's objects isn't a valid choice. (An
object outside the formset's queryset is valid, and left alone by `save!`.)
"""
function check_row_id!(fs::FormSet, f::Form, i)
    (fs.model === nothing || row_pk_name(fs) !== :id) && return
    raw = get(fs.data, "$(fs.prefix)-$i-id", nothing)
    raw isa AbstractVector && (raw = isempty(raw) ? nothing : first(raw))
    s = raw === nothing ? "" : strip(string(raw))
    delete!(f.errors, :id)                 # (the key's own message, not the hidden number field's)
    if isempty(s)
        add_error!(f, :id, gettext("This field is required."))
    else
        id = parse_pk(fs.model, s)
        (id === nothing || !exists(filter(base_objects(fs.model); id = id))) &&
            add_error!(f, :id, gettext("Select a valid choice. That choice is not one of the available choices."))
    end
end

"`a`, `a and b`, `a, b and c` (Django's get_text_list)."
text_list(xs) = length(xs) <= 1 ? join(xs) : join(xs[1:end-1], ", ") * " " * gettext("and") * " " * xs[end]

"""
A model formset's rows mustn't repeat each other where the model says unique (Django's
`BaseModelFormSet.validate_unique`): `unique_together` sets, unique fields and
`unique_for_date`/`_month`/`_year`, among the valid rows not being deleted, for the fields the rows
have. A repeat is a formset error naming the fields, and the row gets "Please correct the
duplicate values below."
"""
function model_formset_unique!(fs::FormSet)
    T = fs.model
    rows = [f for f in fs.forms if !marked_delete(fs, f) && isempty(f.errors) && !isempty(f.cleaned_data)]
    isempty(rows) && return
    onform = Set(x.name for x in rows[1].fields)
    function value(f, n)
        j = findfirst(x -> x.name === n, f.fields)
        if j !== nothing && (p = form_option(f.fields[j], :inline_fk)) !== false
            return p === nothing ? nothing : something(p.id, objectid(p))   # (an inline formset's parent, itself if not saved yet)
        end
        v = get(f.cleaned_data, n, nothing)
        v isa Model ? v.id : v
    end
    checks = Tuple{Vector{Symbol},String}[]
    for M in unique!(Any[concrete_model(T); ancestors(T)]), u in modelmeta(M).unique_together
        all(n -> n in onform, u) || continue
        shown = [n for n in u if fs.fk === nothing || n !== fs.fk.name]      # (an inline formset's parent key isn't named, as Django's)
        push!(checks, (u, interpolate(length(shown) == 1 ? gettext("Please correct the duplicate data for %(field)s.") :
                                      gettext("Please correct the duplicate data for %(field)s, which must be unique."),
                                      Dict("field" => text_list(string.(shown))))))
    end
    for g in all_fields(T)
        (g.unique || g.primary_key) && g.name in onform || continue
        push!(checks, ([g.name], interpolate(gettext("Please correct the duplicate data for %(field)s."), Dict("field" => string(g.name)))))
    end
    errors = String[]
    function repeat!(f, names, msg)
        msg in errors || push!(errors, msg)
        f.errors[:__all__] = [gettext("Please correct the duplicate values below.")]
        foreach(n -> delete!(f.cleaned_data, n), names)
    end
    for (names, msg) in checks
        seen = Set{Any}()
        for f in rows
            all(n -> haskey(f.cleaned_data, n) || value(f, n) !== nothing, names) || continue
            key = Any[value(f, n) for n in names]
            any(v -> v === nothing || v == "", key) && continue
            key in seen ? repeat!(f, names, msg) : push!(seen, key)
        end
    end
    for g in all_fields(T)                      # unique_for_date, _month, _year
        g.unique_for === nothing && continue
        kind, dname = g.unique_for
        (g.name in onform && dname in onform) || continue
        seen = Set{Any}()
        msg = interpolate(gettext("Please correct the duplicate data for %(field_name)s which must be unique for the %(lookup)s in %(date_field)s."),
                          Dict("field_name" => string(g.name), "lookup" => string(kind), "date_field" => string(dname)))
        for f in rows
            v, d = get(f.cleaned_data, g.name, nothing), get(f.cleaned_data, dname, nothing)
            (v === nothing || v == "" || d === nothing) && continue
            key = Any[v, Dates.year(d)]
            kind in (:date, :month) && push!(key, Dates.month(d))
            kind === :date && push!(key, Dates.day(d))
            key in seen ? repeat!(f, [g.name], msg) : push!(seen, key)
        end
    end
    append!(fs.non_form_errors, errors)
end

"""
    save_m2m!(formset)

After `save!(formset; commit = false)` and saving the objects, save their many-to-many fields
(Django's `formset.save_m2m()`).
"""
save_m2m!(fs::FormSet) = (foreach(save_m2m!, fs.saved_forms); fs)
