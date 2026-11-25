# Forms ----------------------------------------------------------------------------------------
#
#     @form ContactForm begin
#         name    = CharField(max_length=100)
#         email   = EmailField()
#         message = TextField()
#     end
#
#     form = ContactForm(req.POST)
#     if is_valid(form)
#         send(form.cleaned_data[:email], ...)
#     end
#
#     form = ModelForm(Post; data=req.POST, instance=post, fields=[:title, :body])
#     is_valid(form) && save!(form)

"""
An HTML form: a list of fields, optionally bound to submitted `data`.
Fields are rendered with `as_div(form)` (`{{ form }}` in templates, as Django 5's default; `as_p`,
`as_ul` and `as_table` too), or individually as `{{ form.fieldname }}`.
"""
mutable struct Form
    name::String
    fields::Vector{Field}
    data::Union{Nothing,AbstractDict}
    initial::Dict{Symbol,Any}
    errors::Dict{Symbol,Vector{String}}
    cleaned_data::Dict{Symbol,Any}
    model::Any
    instance::Any
    prefix::String
    validated::Bool
    clean::Any
    files::Any            # uploaded files (req.FILES) for file fields
    media::Any            # Media (formsextra.jl): the form's own CSS and JavaScript
    use_required_attribute::Bool   # false: no HTML `required` (the browser won't block a partly filled formset)
    auto_id::Any          # the inputs' ids: "id_%s" (the default), a format with %s, true (the name), or false (no ids)
    label_suffix::Union{Nothing,String}   # after each label: nothing for a colon (unless the label ends in punctuation)
    empty_permitted::Bool                 # an unchanged form is valid (with no cleaned data), as a formset's extra forms
    error_css_class::Union{Nothing,String}      # a class on the rows (and labels) of fields with errors, as Django's
    required_css_class::Union{Nothing,String}   # a class on the rows and labels of required fields
    nonfield_error_messages::Dict{String,String}  # a ModelForm's Meta.error_messages[NON_FIELD_ERRORS]: code => message
end

"""
    Form(fields::Vector{Pair{Symbol,Field}}; data=nothing, initial=Dict(), prefix="", clean=nothing, name="Form")

`clean`, if given, is called as `clean(form)` after field validation and may call
`add_error!(form, field_or_nothing, msg)` or modify `form.cleaned_data`.
"""
function Form(fields::Vector; data = nothing, initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
              name = "Form", model = nothing, instance = nothing, files = nothing, media = nothing,
              use_required_attribute::Bool = true, field_order = nothing, auto_id = "id_%s", label_suffix = nothing,
              empty_permitted::Bool = false, error_css_class = nothing, required_css_class = nothing, nonfield_error_messages = nothing)
    empty_permitted && use_required_attribute &&
        throw(ArgumentError("The empty_permitted and use_required_attribute arguments may not both be True."))
    fs = Field[]
    for (n, f) in fields
        f = deepcopy(f)
        f.name = Symbol(n)
        push!(fs, f)
    end
    form = Form(string(name), fs, data, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)),
                Dict{Symbol,Vector{String}}(), Dict{Symbol,Any}(), model, instance, string(prefix), false, clean, files,
                media === nothing ? Media() : media, use_required_attribute, auto_id, label_suffix === nothing ? nothing : string(label_suffix),
                empty_permitted, error_css_class === nothing ? nothing : string(error_css_class),
                required_css_class === nothing ? nothing : string(required_css_class),
                nonfield_error_messages === nothing ? Dict{String,String}() :
                    Dict{String,String}(string(k) => string(v) for (k, v) in nonfield_error_messages))
    field_order === nothing || order_fields!(form, field_order)
    form
end

# --- form-only fields --------------------------------------------------------------------------------

"What a ModelChoiceField chooses from."
struct ModelChoiceSpec
    queryset::Any                    # a QuerySet (or a model: all its objects), read each time it's needed
    to_field_name::Union{Nothing,Symbol}
    empty_label::Union{Nothing,String}
    label_from_instance::Any         # nothing (string(obj)) or obj -> label
end
"A ModelChoiceField's empty choice label: its own, or the blank choice label when it's \"\"."
empty_choice_label(s::ModelChoiceSpec) = s.empty_label == "" || s.empty_label === nothing ? get_blank_choice_label() : s.empty_label
choice_queryset(s::ModelChoiceSpec) = s.queryset isa Type ? objects(s.queryset) : s.queryset
choice_key(s::ModelChoiceSpec, o) = s.to_field_name === nothing ? pk_string(o) : string(getproperty(o, s.to_field_name))
instance_label(s::ModelChoiceSpec, o) = s.label_from_instance === nothing ? string(o) : string(s.label_from_instance(o))

"""
    ModelChoiceField(queryset; to_field_name = nothing, empty_label = "", label_from_instance = nothing, kw...)

A select of model objects for any form (a `ModelForm` makes these for foreign keys itself). The
cleaned value is the object; `to_field_name` submits another unique field instead of the primary
key. The queryset is read when the form is rendered and validated. `empty_label` is the empty
choice's label: "" for `get_blank_choice_label()`, `nothing` for no empty choice.
"""
Base.@nospecializeinfer ModelChoiceField(@nospecialize(qs); to_field_name = nothing, empty_label = "", label_from_instance = nothing, kw...) =
    Field(:modelchoice; related = ModelChoiceSpec(qs, to_field_name === nothing ? nothing : Symbol(to_field_name),
                                                  empty_label === nothing ? nothing : string(empty_label), label_from_instance), kw...)
"A multiple select of model objects; the cleaned value is a vector of objects."
Base.@nospecializeinfer ModelMultipleChoiceField(@nospecialize(qs); to_field_name = nothing, label_from_instance = nothing, kw...) =
    Field(:modelmultichoice; related = ModelChoiceSpec(qs, to_field_name === nothing ? nothing : Symbol(to_field_name), nothing,
                                                       label_from_instance), kw...)

"""
    TypedChoiceField(choices; coerce = identity, empty_value = "", kw...)
    TypedMultipleChoiceField(choices; coerce = identity, kw...)
    MultipleChoiceField(choices; kw...)

Choices whose cleaned value is converted with `coerce` (`TypedChoiceField(["1" => "One"]; coerce = x -> parse(Int, x))`),
and the multiple-select versions.
"""
TypedChoiceField(choices; coerce = identity, empty_value = "", any_value::Bool = false, kw...) =
    Field(:typedchoice; choices = choices, related = any_value ? (coerce = coerce, empty_value = empty_value, any_value = true) :
                                                                 (coerce = coerce, empty_value = empty_value), kw...)
TypedMultipleChoiceField(choices; coerce = identity, kw...) = Field(:multichoice; choices = choices, related = (coerce = coerce,), kw...)
MultipleChoiceField(choices; kw...) = TypedMultipleChoiceField(choices; kw...)
"""
    ChoiceField(choices; kw...)   or   ChoiceField(; choices, kw...)

One of `choices` (pairs, tuples, a Dict, groups, or a function returning them), cleaned to its
value as text, as Django's `ChoiceField`.
"""
ChoiceField(c = nothing; choices = Any[], kw...) = TypedChoiceField(c === nothing ? choices : c; kw...)
"""
    NullBooleanField(; kw...)

Yes, no or unknown (`true`, `false`, `nothing`), as Django's, shown as a select (Django's
`NullBooleanSelect`). It also accepts "1"/"0" and "True"/"False".
"""
NullBooleanField(; kw...) =
    TypedChoiceField(["unknown" => gettext_lazy("Unknown"), "true" => gettext_lazy("Yes"), "false" => gettext_lazy("No")];
                     coerce = v -> v in ("true", "True", "1", "2") ? true : v in ("false", "False", "0", "3") ? false : nothing,
                     empty_value = nothing, any_value = true, blank = true, kw...)

"""
    RegexField(regex; max_length = nothing, error_message = "Enter a valid value.", kw...)

A text field whose value must match `regex`. As Django's, the value isn't stripped of
surrounding whitespace unless `strip = true`.
"""
RegexField(rx; max_length = nothing, error_message = nothing, validators = Any[], strip::Bool = false, kw...) =
    Field(:char; max_length = max_length, strip = strip,
          validators = vcat(Any[RegexValidator(rx; message = error_message)], collect(Any, validators)), kw...)

"""
    ComboField(fields; kw...)

A value that every one of `fields` must accept (Django's `ComboField`), e.g.
`ComboField([CharField(max_length = 20), EmailField()])`; the cleaned value is the last field's.
"""
ComboField(fields; kw...) = Field(:combo; related = collect(Field, fields), kw...)

const MULTI_KINDS = (:m2m, :modelmultichoice, :multichoice)

"""
    @form Name begin
        field = CharField(...)
        ...
    end

Defines a constructor `Name(data=nothing; initial=Dict(), prefix="")` returning a
`Form`. Add cross-field validation by defining
`Juango.clean_form(f::Form, ::Val{:Name})`.
"""
macro form(name, body)
    pairs_ = Expr[]
    for line in body.args
        line isa LineNumberNode && continue
        (line isa Expr && line.head === :(=)) || error("@form: expected `field = FieldType(...)`, got $line")
        lhs = line.args[1]
        fname = lhs isa Symbol ? lhs : lhs.args[1]
        push!(pairs_, :($(QuoteNode(fname)) => $(esc(line.args[2]))))
    end
    F = GlobalRef(@__MODULE__, :Form)
    quote
        Base.@__doc__ function $(esc(name))(data = nothing; initial = Dict{Symbol,Any}(), prefix = "", clean = nothing, files = nothing, media = nothing,
                                            kw...)
            $F(Pair{Symbol,Any}[$(pairs_...)]; data = data, initial = initial, prefix = prefix,
               clean = clean, name = $(string(name)), files = files, media = media, kw...)
        end
    end
end

"Hook for cross-field validation of `@form`-defined forms (dispatch on `Val{:FormName}`)."
clean_form(f::Form, ::Val) = nothing
"""
    Juango.clean_field(form, ::Val{:FormName}, ::Val{:field}, value) -> value

Django's `clean_<field>()`: define a method for a field of a `@form` (or `Form(...; name = ...)`) to
check or change its cleaned value; return the value to keep, or throw `ValidationError` for the
field's errors. It runs after the field's own checks, in the order of the fields, so
`form.cleaned_data` has the fields before it.
"""
clean_field(f::Form, ::Val, ::Val, v) = v
function run_clean_field!(f::Form, fld::Field, v)
    f.cleaned_data[fld.name] = v
    try
        f.cleaned_data[fld.name] = clean_field(f, Val(Symbol(f.name)), Val(fld.name), v)
    catch e
        e isa ValidationError || rethrow()
        delete!(f.cleaned_data, fld.name)
        foreach(m -> add_error!(f, fld.name, m), reduce(vcat, collect(values(e.errors)); init = String[]))
    end
end
"Hook run by `save!(form)` on the instance before it is saved (dispatch on `Val{:FormName}`)."
Base.@nospecializeinfer form_save_hook(f::Form, ::Val, @nospecialize(obj)) = nothing

"""
    ModelForm(Model; data=nothing, instance=nothing, fields=nothing, exclude=[], initial=Dict(), widgets=Dict())

A form generated from a model's fields. `save!(form)` writes the cleaned data
into the instance (creating one if needed) and saves it.

`error_messages = Dict(:title => Dict("required" => "Give it a title."))` replaces messages by
code, over the model field's own `error_messages`. Other keywords (`auto_id`, `media`,
`label_suffix`, ...) are the `Form`'s.

`extra_fields = [:scope => TypedChoiceField(...)]` adds fields that aren't on the model: placed
where `fields` lists their names (else at the end), cleaned into `cleaned_data`, and left alone
by `save!`.
"""
Base.@nospecializeinfer function ModelForm(@nospecialize(T::Type{<:Model}); data = nothing, files = nothing, @nospecialize(instance = nothing), fields = nothing, exclude = Symbol[],
                   initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
                   labels = Dict{Symbol,String}(), help_texts = Dict{Symbol,String}(),
                   widgets = Dict{Symbol,Symbol}(), field_classes = Dict{Symbol,Any}(),
                   formfield_callback = nothing, extra_fields = Pair{Symbol,Any}[], error_messages = Dict{Symbol,Any}(),
                   localized_fields = nothing, kw...)
    fs = fields_for_model(T; fields, exclude, labels, help_texts, widgets, field_classes, formfield_callback, extra_fields, error_messages,
                          localized_fields)
    meta = modelmeta(T)
    init = Dict{Symbol,Any}()
    if instance !== nothing
        for (n, f) in fs
            mf = something(findfield(meta, n), Some(findfirst(x -> x.name === n, meta.m2m)))
            mf === nothing && continue                                           # not the model's
            m2m = !(mf isa Field)
            # (a declared ModelChoiceField or ModelMultipleChoiceField shows the objects by its to_field_name)
            init[n] = f.kind === :modelmultichoice ? (instance.id === nothing ? Any[] : collect(Any, getproperty(instance, n))) :
                      f.kind === :modelchoice ? getproperty(instance, n) :
                      m2m ? (instance.id === nothing ? Any[] : [o.id for o in getproperty(instance, n)]) :
                      mf.kind === :fk ? getproperty(instance, attname(mf)) :
                      getproperty(instance, n)
            init[n] === DB_DEFAULT && (init[n] = nothing)
        end
    end
    merge!(init, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)))
    Form(fs; data = data, initial = init, prefix = prefix, clean = clean, name = "$(nameof(T))Form",
         model = T, instance = instance, files = files,
         nonfield_error_messages = get(error_messages, :__all__, get(error_messages, "__all__", nothing)), kw...)
end

"""
The editable fields of a model in the order they're declared (many-to-many ones among them, a
multi-table parent's first): the fields a ModelForm takes when it isn't told which.
"""
Base.@nospecializeinfer function editable_field_names(@nospecialize(T::Type{<:Model}))
    meta = modelmeta(T)
    names = Symbol[f.name for f in all_fields(T) if f.editable]
    m2ms = Symbol[f.name for f in meta.m2m if f.editable]
    own = get(meta.extra, :field_order, Symbol[])
    out = Symbol[n for n in names if !(n in own)]
    for n in own
        (n in names || n in m2ms) && !(n in out) && push!(out, n)
    end
    append!(out, [n for n in vcat(names, m2ms) if !(n in out)])
end

all_fields_option(x) = x === nothing || x == "__all__" || x === :__all__
function check_field_list(T, what, x)
    x isa AbstractString && x != "__all__" &&
        throw(ArgumentError("$(nameof(T))Form $what cannot be a string. Did you mean to type: [:$x]?"))
end

"""
    fields_for_model(Model; fields = nothing, exclude = [], widgets, labels, help_texts, error_messages,
                     field_classes, formfield_callback, extra_fields) -> Vector{Pair{Symbol,Any}}

The form fields a `ModelForm` of `Model` has, as `name => field` pairs (Django's `fields_for_model`):
the model's editable fields (or those `fields` names, in its order; `"__all__"` for all), less
`exclude`, with `extra_fields` (declared fields) replacing the model's or added. A name in `fields`
that is neither the model's nor an extra field is an error, as Django's FieldError.

`field_classes = Dict(:url => URLField)` makes the field with another form field constructor,
keeping the model field's label, help text, `max_length` and whether it's required; a field
given as a value is used as it is. `formfield_callback(field)` can change each field, or return
`nothing` to leave it out.
"""
Base.@nospecializeinfer function fields_for_model(@nospecialize(T::Type{<:Model}); fields = nothing, exclude = Symbol[],
                   labels = Dict{Symbol,String}(), help_texts = Dict{Symbol,String}(),
                   widgets = Dict{Symbol,Any}(), field_classes = Dict{Symbol,Any}(),
                   formfield_callback = nothing, extra_fields = Pair{Symbol,Any}[], error_messages = Dict{Symbol,Any}(),
                   localized_fields = nothing)
    check_field_list(T, "fields", fields)
    check_field_list(T, "exclude", exclude)
    check_field_list(T, "localized_fields", localized_fields)
    meta = modelmeta(T)
    extras = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in extra_fields)
    exclude = Symbol[Symbol(x) for x in exclude]
    chosen = all_fields_option(fields) ? editable_field_names(T) : Symbol[Symbol(x) for x in fields]
    m2m_field(n) = (i = findfirst(x -> x.name === n, meta.m2m); i === nothing ? nothing : meta.m2m[i])
    unknown = [n for n in chosen if !(n in exclude) && !haskey(extras, n) && findfield(meta, n) === nothing && m2m_field(n) === nothing]
    isempty(unknown) || throw(LookupError("Unknown field(s) ($(join(unknown, ", "))) specified for $(nameof(T))"))
    for n in chosen          # (a field that isn't editable can't be on the form, as Django's FieldError)
        n in exclude || haskey(extras, n) || (mf = findfield(meta, n)) === nothing || mf.editable ||
            throw(LookupError("'$n' cannot be specified for $(nameof(T)) model form as it is a non-editable field"))
    end
    # fields that aren't on the model: where `fields` lists them, else at the end
    append!(chosen, [Symbol(k) for (k, _) in extra_fields if !(Symbol(k) in chosen)])
    fs = Pair{Symbol,Any}[]
    for n in chosen
        n in exclude && continue
        if haskey(extras, n)
            push!(fs, n => deepcopy(extras[n]))
            continue
        end
        mf = something(m2m_field(n), Some(nothing))
        f = deepcopy(mf === nothing ? getfield_meta(T, n) : mf)
        f.kind === :bool && (f.blank = true)        # (a model's checkbox needn't be checked, as Django's BooleanField.formfield())
        # a default that's a function: its value is sent back in a hidden input, so has_changed compares
        # with the value the form was shown with (Django's show_hidden_initial for callable defaults)
        f.default isa Function && (f.form = something(f.form, Dict{Symbol,Any}()); f.form[:show_hidden_initial] = true)
        if haskey(field_classes, n)                  # a different form field for it
            fc = field_classes[n]
            f = fc isa Field ? deepcopy(fc) : form_field_for(fc, f)
        end
        haskey(labels, n) && (f.verbose_name = labels[n])
        haskey(help_texts, n) && (f.help_text = help_texts[n])
        if haskey(error_messages, n)                 # Meta.error_messages: per field, code => message, over the model field's
            em = something(f.error_messages, Dict{String,String}())
            f.error_messages = merge(em, Dict{String,String}(string(k) => string(v) for (k, v) in error_messages[n]))
        end
        haskey(widgets, n) && (f.widget = widgets[n])
        localized_fields !== nothing && (localized_fields == "__all__" || n in Symbol.(localized_fields)) && localize!(f)
        if formfield_callback !== nothing
            f = formfield_callback(f)                                          # nothing leaves the field out
            f === nothing && continue
        end
        push!(fs, n => f)
    end
    fs
end

"Whether a form field shows and reads numbers and dates in the current language's format (`localize = true`)."
is_localized(f::Field) = f.related isa NamedTuple && get(f.related, :localize, false)
function localize!(f::Field)
    f.related === nothing ? (f.related = (input_formats = nothing, localize = true)) :
        f.related isa NamedTuple && haskey(f.related, :localize) && (f.related = merge(f.related, (localize = true,)))
    f
end

# field_classes = Dict(:url => URLField): that form field, with the model field's label, help text, length and requiredness
function form_field_for(ctor, mf::Field)
    g = ctor()
    g.name, g.model = mf.name, mf.model
    g.verbose_name, g.help_text, g.blank, g.null = mf.verbose_name, mf.help_text, mf.blank, mf.null
    mf.max_length === nothing || (g.max_length = mf.max_length)
    mf.error_messages === nothing || (g.error_messages = mf.error_messages)
    g
end

"""
    modelform_factory(Model; fields, exclude, widgets, labels, ...) -> constructor

Django's `modelform_factory`: a constructor `(data = nothing; kw...)` of `ModelForm(Model; ...)`
with these options (and the keywords it's given). Unknown field names are an error here already.
"""
struct ModelFormFactory
    model::Type
    options::Dict{Symbol,Any}
end
Base.@nospecializeinfer function modelform_factory(@nospecialize(T::Type{<:Model}); kw...)
    m = ModelFormFactory(T, Dict{Symbol,Any}(kw))
    m()                                                    # (checks the options now, as Django's)
    m
end
(m::ModelFormFactory)(data = nothing; kw...) = ModelForm(m.model; data, m.options..., kw...)

is_empty_value(v) = v === nothing || (v isa AbstractString && isempty(v)) || ((v isa AbstractVector || v isa Tuple || v isa AbstractDict) && isempty(v))

"""
Whether the submitted data leaves out field `fld` (Django's `value_omitted_from_data`): a
checkbox, or a list of checkboxes or a multiple select, never is, as a browser sends nothing for
them when they're unticked.
"""
function value_omitted(f::Form, fld::Field)
    f.data === nothing && return true
    name = html_name(f, fld)
    fld.kind in FILE_KINDS && return f.files === nothing || !haskey(f.files, name)
    wk = widget_kind(fld.widget)
    fld.kind === :bool && wk === nothing && return false
    (fld.kind in MULTI_KINDS || wk in (:checkboxes, :selectmultiple)) && return false
    fld.kind === :multi && return !any(i -> haskey(f.data, name * "_$(i - 1)"), eachindex(fld.related.fields))
    fld.widget isa SelectDateWidget && return !any(s -> haskey(f.data, name * s), ("_year", "_month", "_day"))
    !haskey(f.data, name)
end

"""
    construct_instance(form, instance; fields = nothing, exclude = nothing) -> instance

Set a model instance's fields from a valid ModelForm's `cleaned_data` (Django's
`construct_instance`), not saving it; `save!(form)` uses it. A field the submitted data leaves
out, that is empty and has a default, keeps the instance's value (the default), as Django's.
Many-to-many fields are left to `save_m2m!`.
"""
Base.@nospecializeinfer function construct_instance(f::Form, @nospecialize(obj); fields = nothing, exclude = nothing)
    meta = modelmeta(typeof(obj))
    for (k, v) in f.cleaned_data
        k === :__all__ && continue
        mf = findfield(meta, k)
        mf === nothing && continue
        fields !== nothing && !(k in Symbol.(fields)) && continue
        exclude !== nothing && k in Symbol.(exclude) && continue
        i = findfirst(x -> x.name === k, f.fields)
        if i !== nothing && (mf.default !== NO_DEFAULT || mf.db_default !== nothing) && is_empty_value(v) && value_omitted(f, f.fields[i])
            continue
        end
        mf.kind in FILE_KINDS && v isa AbstractString && (v = file_from_db(mf, v))       # (a stored file's name)
        i !== nothing && (p = form_option(f.fields[i], :inline_fk)) !== false && (v = p)  # (an inline formset's parent)
        setproperty!(obj, k, v)
    end
    obj
end

"""
    model_to_dict(instance; fields = nothing, exclude = nothing) -> Dict{Symbol,Any}

An instance's editable fields as a dict (Django's `model_to_dict`): its `id` (unless another field is
the primary key), a foreign key as the related object's key, a many-to-many field as a vector of
the related objects.
"""
Base.@nospecializeinfer function model_to_dict(@nospecialize(obj::Model); fields = nothing, exclude = nothing)
    T = typeof(obj)
    meta = modelmeta(T)
    d = Dict{Symbol,Any}()
    names = editable_field_names(T)
    any(f -> f.primary_key, all_fields(T)) || pushfirst!(names, :id)
    for n in names
        if n === :id && findfield(meta, :id) === nothing
            (fields === nothing || :id in Symbol.(fields)) && (exclude === nothing || !(:id in Symbol.(exclude))) && (d[:id] = obj.id)
            continue
        end
        fields !== nothing && !(n in Symbol.(fields)) && continue
        exclude !== nothing && n in Symbol.(exclude) && continue
        i = findfirst(x -> x.name === n, meta.m2m)
        if i !== nothing
            d[n] = obj.id === nothing ? Any[] : collect(Any, getproperty(obj, n))
        else
            f = getfield_meta(T, n)
            d[n] = f.kind === :fk ? getproperty(obj, attname(f)) : getproperty(obj, n)
        end
    end
    d
end

# (as Django's repr: whether it's valid is Unknown until it's validated; showing it doesn't validate)
Base.show(io::IO, f::Form) = print(io, "<", f.name, " bound=", f.data !== nothing ? "True" : "False", ", valid=",
                                   !f.validated ? "Unknown" : isempty(f.errors) ? "True" : "False", ", fields=(",
                                   join(string.(getfield.(f.fields, :name)), ";"), ")>")
"Whether the form has a file input, so needs `enctype=\"multipart/form-data\"` (Django's `is_multipart()`)."
is_multipart(f::Form) = any(x -> x.kind in FILE_KINDS, f.fields)

html_name(f::Form, fld::Field) = isempty(f.prefix) ? string(fld.name) : f.prefix * "-" * string(fld.name)
"""
The id of a field's input: the widget's own `attrs["id"]`, else from the form's `auto_id`
(`"id_%s"` by default; a format with `%s`, `true` for the name itself, `false` for none: "").
"""
function html_id(f::Form, fld::Field)
    fld.widget isa Widget && haskey(fld.widget.attrs, "id") && return fld.widget.attrs["id"]
    a = f.auto_id
    (a === false || a === nothing || a == "") && return ""
    a === true && return html_name(f, fld)
    s = string(a)
    occursin("%s", s) ? replace(s, "%s" => html_name(f, fld)) : html_name(f, fld)
end
"` id=\"...\"`, or nothing when there's no id (`auto_id = false`)."
id_attr(id) = isempty(id) ? "" : " id=\"" * escape_html(id) * "\""

"""
    flatatt(attrs) -> String

HTML attributes from a dict, as Django's `flatatt`: ` name="value"` pairs, sorted, then the
attributes set to `true` as bare names (sorted); `false` and `nothing` are left out.
"""
function flatatt(attrs)
    kv = sort!([(string(k), v) for (k, v) in attrs if !(v isa Bool) && v !== nothing]; by = first)
    bools = sort!([string(k) for (k, v) in attrs if v === true])
    join((" " * escape_html(k) * "=\"" * escape_html(v) * "\"" for (k, v) in kv)) * join((" " * escape_html(k) for k in bools))
end
"`pretty_name(\"john_doe\")` is \"John doe\": a field name as a label, as Django's (\"\" for `nothing`)."
pretty_name(name) = name === nothing ? "" : uppercasefirst(replace(string(name), '_' => ' '))

function raw_value(f::Form, fld::Field)
    f.data === nothing && return nothing
    form_option(fld, :disabled) && return initial_for(f, fld)      # (a disabled field keeps its initial value, as Django)
    fld.kind === :multi && return multi_raw(f, fld)
    if fld.widget isa SelectDateWidget                 # three selects: name_year, name_month, name_day
        n = html_name(f, fld)
        y, m, d = (string(something(get(f.data, n * s, nothing), "")) for s in ("_year", "_month", "_day"))
        isempty(y) && isempty(m) && isempty(d) && return get(f.data, n, nothing)
        return (isempty(y) || isempty(m) || isempty(d)) ? "invalid" : "$y-$(lpad(m, 2, '0'))-$(lpad(d, 2, '0'))"
    end
    if fld.kind === :m2m && widget_kind(fld.widget) === :raw_id           # "1,2,3" (Django's ManyToManyRawIdWidget)
        v = get(f.data, html_name(f, fld), nothing)
        return v === nothing || v == "" ? (v === nothing ? nothing : String[]) : String[strip(x) for x in split(string(v), ',') if !isempty(strip(x))]
    end
    fld.kind in MULTI_KINDS && return raw_list(f.data, html_name(f, fld))
    v = get(f.data, html_name(f, fld), nothing)
    # a checkbox as Django's CheckboxInput reads it: "false" and "" are unchecked, any other value sent is checked ("0" too, #16820)
    fld.kind === :bool && widget_kind(fld.widget) === nothing && v isa AbstractString && return !isempty(v) && lowercase(v) != "false"
    v
end
"All submitted values for a multi-valued field."
raw_list(d::QueryDict, k) = getlist(d, k)
function raw_list(d::AbstractDict, k)
    v = get(d, k, String[])
    v isa AbstractVector ? collect(v) : [v]
end

"A validator's limit as an HTML attribute (min=\"0.5\", max=\"10\")."
limit_attr(x) = string(x)

"A URL typed without a scheme (\"example.com\", \"//example.com\") gets https, as Django's form `URLField`."
function assume_url_scheme(s)
    s = String(s)
    occursin(r"^[A-Za-z][A-Za-z0-9+.\-]*:", s) && return s
    startswith(s, "//") ? "https:" * s : "https://" * s
end

const ISO_INPUT_FORMATS = ["%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S",
                           "%Y-%m-%d %H:%M", "%Y-%m-%d"]

"A whole number as a form takes one, as Django: \"５０\" (other scripts' digits), \"1.0\" and \"1.\" too."
function parse_form_int(s)
    s = Base.Unicode.normalize(String(s), :NFKC)
    v = tryparse(Int, s)
    v === nothing || return v
    # (beyond an Int's range: a BigInt, so the field's range check gives its message, as Django's)
    occursin(r"^[+-]?\d+$", s) && return tryparse(BigInt, s)
    m = match(r"^([+-]?\d+)\.0*$", s)
    m === nothing ? nothing : something(tryparse(Int, m[1]), tryparse(BigInt, m[1]), Some(nothing))
end

"Convert submitted text into a typed value. Returns `(value, error_or_nothing)`."
function to_julia(fld::Field, raw)
    k = fld.kind
    k === :multi && return clean_multi(fld, raw)
    if k in (:modelmultichoice, :multichoice)
        vals = String[strip(string(r)) for r in (raw === nothing ? [] : raw) if !isempty(strip(string(r)))]
        if k === :multichoice
            keys_ = Set(string(c.first) for c in field_choices(fld))
            for v in vals
                v in keys_ || return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v))
            end
            out = Any[]
            for v in vals              # (a value coerce can't convert is an invalid choice, as Django's)
                cv = try fld.related.coerce(v) catch e
                    e isa Union{ArgumentError,InexactError,MethodError} || rethrow()
                    return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v))
                end
                push!(out, cv)
            end
            return out, nothing
        end
        s = fld.related
        objs = Dict(choice_key(s, o) => o for o in choice_queryset(s))
        model = queryset_model(choice_queryset(s))
        for v in vals
            occursin('\0', v) && return nothing, coded("null_characters_not_allowed", gettext("Null characters are not allowed."), Dict("value" => v))
        end
        for v in vals          # (a value that can't be a primary key: Django's invalid_pk_value)
            s.to_field_name === nothing && parse_pk(model, v) === nothing &&
                return nothing, coded("invalid_pk_value", gettext("“%(pk)s” is not a valid value."), Dict("pk" => v))
            haskey(objs, v) || return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v))
        end
        return Any[objs[v] for v in unique(vals)], nothing
    end
    if k === :m2m
        ids = Any[]
        for r in (raw === nothing ? [] : raw)
            sr = strip(string(r))
            isempty(sr) && continue
            id = parse_pk(related_model(fld), sr)
            id === nothing && return nothing, coded("invalid_list", gettext("Enter a list of values."))
            push!(ids, id)
        end
        objs = isempty(ids) ? Any[] : collect(filter(choices_queryset(fld); id__in = unique(ids)))
        length(objs) == length(unique(ids)) || return nothing, gettext("Select a valid choice. One of the selected values is not one of the available choices.")
        return objs, nothing
    end
    if k === :bool          # as Django: "false", "0" and empty are false, any other value true
        return !(raw === nothing || raw === false || lowercase(strip(string(raw))) in ("", "false", "0")), nothing
    end
    s = raw === nothing ? "" : (widget_kind(fld.widget) === :password || !form_option(fld, :strip) ? string(raw) : strip(string(raw)))
    k === :typedchoice && isempty(s) && return fld.related.empty_value, nothing     # not coerced, as in Django
    ev = form_option(fld, :empty_value)
    isempty(s) && ev !== NO_DEFAULT && return ev, nothing
    isempty(s) && return ((k in STRING_KINDS || k in (:filepath, :combo)) && !fld.null ? "" : nothing), nothing
    k in STRING_KINDS && occursin('\0', s) && return nothing, coded("null_characters_not_allowed", gettext("Null characters are not allowed."), Dict("value" => s))
    opts = fld.related isa NamedTuple && haskey(fld.related, :localize) ? fld.related : nothing
    opts !== nothing && opts.localize && k in (INT_KINDS..., :float, :decimal) && (s = parse_localized_number(s))
    if k in STRING_KINDS
        k === :url && return assume_url_scheme(s), nothing
        return String(s), nothing
    elseif k in INT_KINDS
        v = parse_form_int(s)
        return v, v === nothing ? gettext("Enter a whole number.") : nothing
    elseif k === :float
        v = tryparse(Float64, Base.Unicode.normalize(String(s), :NFKC))
        (v === nothing || !isfinite(v)) && return nothing, gettext("Enter a number.")
        return v, nothing
    elseif k === :decimal
        v = tryparse(Decimal, s)
        return v, v === nothing ? gettext("Enter a number.") : nothing
    elseif k === :datetime
        v = parse_input_datetime(s, :datetime; formats = opts === nothing ? nothing : opts.input_formats)
        # ISO 8601 is taken whatever the input formats, as Django's DateTimeField
        v === nothing && opts !== nothing && opts.input_formats !== nothing && (v = parse_input_datetime(s, :datetime; formats = ISO_INPUT_FORMATS))
        v === nothing || return (settings.USE_TZ ? make_aware(v) : v), nothing      # typed in the current time zone
        return nothing, gettext("Enter a valid date/time.")
    elseif k === :date
        v = parse_input_datetime(s, :date; formats = opts === nothing ? nothing : opts.input_formats)
        return v, v === nothing ? gettext("Enter a valid date.") : nothing
    elseif k === :ipaddress
        r = clean_ip(s, fld.related.protocol, fld.related.unpack_ipv4)
        return r isa Tuple ? (nothing, r[1]) : (r, nothing)
    elseif k === :filepath
        any(c -> c.first == s, filepath_choices(fld)) ||
            return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => s))
        return String(s), nothing
    elseif k === :time
        v = opts !== nothing && opts.input_formats !== nothing ? parse_input_datetime(s, :time; formats = opts.input_formats) : parse_time(s)
        return v, v === nothing ? gettext("Enter a valid time.") : nothing
    elseif k === :duration
        us = try parse_duration_us(s) catch; nothing end
        return us === nothing ? (nothing, gettext("Enter a valid duration.")) : (duration_from_us(us), nothing)
    elseif k === :json || k === :hstore
        v = try
            plainjson(JSON.parse(s))
        catch
            return nothing, gettext("Enter a valid JSON.")
        end
        return v, nothing
    elseif k === :array
        try
            return Any[convert_elem(fld.related, strip(x)) for x in split(s, ',') if !isempty(strip(x))], nothing
        catch
            return nothing, gettext("Enter a comma-separated list of valid values.")
        end
    elseif k === :geometry
        try
            return parse_geometry_input(fld, s), nothing
        catch e
            return nothing, e isa ArgumentError && startswith(e.msg, "Expected") ? e.msg : gettext("Enter a valid geometry (WKT or GeoJSON).")
        end
    elseif k === :uuid             # (with or without hyphens, as Django's)
        v = tryparse(UUID, s)
        v === nothing && length(s) == 32 && all(isxdigit, s) && (v = UUID(parse(UInt128, s; base = 16)))
        return v, v === nothing ? gettext("Enter a valid UUID.") : nothing
    elseif k in RANGE_KINDS
        parts = strip.(split(s, ','))
        length(parts) == 2 || return nothing, "Enter the lower and upper bounds, separated by a comma."
        try
            ek = range_elem_kind(k)
            conv(x) = isempty(x) ? nothing : convert_elem(ek, x)
            return ValueRange(conv(parts[1]), conv(parts[2])), nothing
        catch
            return nothing, "Enter valid range bounds."
        end
    elseif k === :modelchoice
        sp = fld.related
        obj = sp.to_field_name === nothing ? (id = parse_pk(queryset_model(choice_queryset(sp)), s); id === nothing ? nothing : first(filter(choice_queryset(sp); pk = id))) :
              first(filter(choice_queryset(sp), Q(sp.to_field_name => s)))
        return obj, obj === nothing ? coded("invalid_choice", gettext("Select a valid choice. That choice is not one of the available choices."), Dict("value" => s)) : nothing
    elseif k === :typedchoice
        # (NullBooleanField takes any value: one it doesn't know is unknown)
        haskey(fld.related, :any_value) || any(c -> string(c.first) == s, field_choices(fld)) ||
            return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => s))
        # a value coerce can't convert is an invalid choice, as Django's
        cv = try fld.related.coerce(String(s)) catch e
            e isa Union{ArgumentError,InexactError,MethodError} || rethrow()
            return nothing, coded("invalid_choice", gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => s))
        end
        return cv, nothing
    elseif k === :combo
        v = String(s)
        for sub in fld.related
            v2, err = to_julia(sub, v)
            err === nothing || return nothing, err
            errs = validate_field(sub, v2)
            isempty(errs) || return nothing, errs[1]
            v = v2
        end
        return v, nothing
    elseif k === :fk && fk_to_field(fld) !== nothing           # the to_field's value is submitted (#220)
        obj = first(filter(choices_queryset(fld), Q(fk_to_field(fld) => s)))
        return obj, obj === nothing ? coded("invalid_choice", gettext("Select a valid choice. That choice is not one of the available choices."), Dict("value" => s)) : nothing
    elseif k === :fk
        id = parse_pk(related_model(fld), s)
        obj = id === nothing ? nothing : first(filter(choices_queryset(fld); id = id))
        return obj, obj === nothing ? coded("invalid_choice", gettext("Select a valid choice. That choice is not one of the available choices."), Dict("value" => s)) : nothing
    end
    String(s), nothing
end

"""
    clean(field, value) -> cleaned value

Clean one value as a form would for `field` (Django's `Field.clean`): convert it from what a
browser submits and run the field's checks and validators, or throw a `ValidationError` with
the messages.

    clean(IntegerField(max_value = 10), "7")    # 7
    clean(EmailField(), "x")                     # ValidationError: Enter a valid email address.

A file field takes an `UploadedFile` (or nothing), and the stored file's name as `initial`.
"""
function clean(fld::Field, value, initial = nothing)
    fld.kind in FILE_KINDS && return clean_file_value(fld, value, initial)
    listy = fld.kind in MULTI_KINDS || fld.kind === :multi
    listy && value == "" && (value = nothing)
    listy && !(value isa Union{Nothing,AbstractVector,Tuple}) &&
        throw(ValidationError([field_message(fld, "invalid_list", gettext("Enter a list of values."))]))
    typed = typed_form_value(fld, value)
    v, err = typed === nothing ? to_julia(fld, value) : (typed, nothing)
    err === nothing || throw(ValidationError(err isa AbstractVector ? err : [parse_message(fld, err, value)]))
    errs = form_value_errors(fld, v)
    isempty(errs) || throw(ValidationError(errs))
    v
end

"The message for a value `to_julia` couldn't convert: by its code (\"invalid\" unless `coded`), with the value as %(value)s."
parse_message(fld::Field, err, raw) = field_message(fld, "invalid", err, Dict{String,Any}("value" => raw isa AbstractVector ? raw : string(something(raw, ""))))

"""
The checks of a form field's converted value: required (a list must have an item, a required
checkbox must be checked, as Django's), then the field's own checks and validators.
"""
function form_value_errors(fld::Field, v)
    required() = [field_message(fld, "required", gettext("This field is required."))]
    fld.kind in MULTI_KINDS && return isempty(v) && !fld.blank ? required() : validator_errors(fld, v)
    fld.kind === :bool && v === false && !fld.blank && return required()
    validate_field(fld, v isa Model ? v.id : v)
end

function clean_file_value(fld::Field, value, initial)
    # false: clear the file (Django's ClearableFileInput); a required field can't be cleared, so it's as nothing
    if value === false
        fld.blank && return false
        value = nothing
    end
    nofile = gettext("No file was submitted. Check the encoding type on the form.")
    if (value isa UploadedFile && isempty(value.name)) || (value isa AbstractString && !isempty(value))
        throw(ValidationError([field_message(fld, "invalid", nofile)]))
    end
    form = Form([:f => fld]; data = Dict{String,Any}(), files = value isa Union{UploadedFile,AbstractVector} ? Dict{String,Any}("f" => value) : Dict{String,Any}(),
                initial = initial === nothing || initial == "" ? Dict{Symbol,Any}() : Dict{Symbol,Any}(:f => initial))
    v, errs = clean_file_field(form, form.fields[1])
    isempty(errs) || throw(ValidationError(errs))
    v
end

# a date, time or duration given as one (not as text): taken as it is, as Django's fields do
function typed_form_value(fld::Field, v)
    k = fld.kind
    k === :date && v isa Union{Date,DateTime} && return Date(v)
    k === :datetime && v isa DateTime && return v
    k === :datetime && v isa Date && return DateTime(v)
    k === :time && v isa Dates.Time && return v
    k === :duration && v isa Union{Dates.Period,Dates.CompoundPeriod} && return duration_from_us(duration_us(v))
    k === :duration && v isa Integer && !(v isa Bool) && return duration_from_us(Int64(v) * 1_000_000)     # (seconds)
    k === :json && v !== nothing && !(v isa AbstractString) && return v          # (already decoded)
    nothing
end

"""
    is_valid(form) -> Bool

Validate bound data; populates `form.cleaned_data` and `form.errors`.
"""
function is_valid(f::Form)
    f.data === nothing && return false
    f.validated && return isempty(f.errors)
    empty!(f.errors)
    empty!(f.cleaned_data)
    # an empty form that may be: valid, with nothing cleaned (Django's empty_permitted)
    f.empty_permitted && !has_changed(f) && (f.validated = true; return true)
    for fld in f.fields
        if fld.kind in FILE_KINDS
            v, errs = clean_file_field(f, fld)
            foreach(e -> add_error!(f, fld.name, e), errs)
            isempty(errs) && run_clean_field!(f, fld, v)
            continue
        end
        v, err = to_julia(fld, raw_value(f, fld))
        if err !== nothing
            err isa AbstractVector ? foreach(e -> add_error!(f, fld.name, e), err) : add_error!(f, fld.name, parse_message(fld, err, raw_value(f, fld)))
            continue
        end
        errs = form_value_errors(fld, v)
        foreach(e -> add_error!(f, fld.name, e), errs)
        isempty(errs) && run_clean_field!(f, fld, v)
    end
    f.model !== nothing && model_form_unique_errors!(f)
    f.model !== nothing && isempty(f.errors) && model_form_constraint_errors!(f)
    f.model !== nothing && model_form_clean!(f)
    f.clean === nothing || form_clean_hook(f)
    form_clean_hook(f, ff -> clean_form(ff, Val(Symbol(ff.name))))
    f.validated = true
    isempty(f.errors)
end

"""
Check the model's `unique_together` and `Meta(constraints = ...)` against the values the form
would save: the instance's, with the cleaned data on top. Constraints that use a field the
form doesn't have (and no instance supplies) are skipped.
"""
function model_form_constraint_errors!(f::Form)
    T = f.model
    inst = f.instance
    values = Dict{Symbol,Any}()
    if inst !== nothing
        for fld in all_fields(T)
            values[fld.name] = field_data(inst, attname(fld))
        end
    end
    for (k, v) in f.cleaned_data
        findfield(modelmeta(T), Symbol(k)) === nothing && continue
        j = findfirst(x -> x.name === Symbol(k), f.fields)
        j !== nothing && (p = form_option(f.fields[j], :inline_fk)) !== false && (v = p)     # (an inline formset's parent)
        values[Symbol(k)] = v
    end
    id = inst === nothing ? nothing : inst.id
    for e in constraint_errors(T, values, id)
        add_error!(f, nothing, e)
    end
end

"""
A ModelForm's uniqueness checks, as Django's: the model's `validate_unique` on an instance with
the cleaned data, leaving out the model fields that aren't on the form, that failed, or that
are empty and allowed to be (so a `unique_together` only partly on the form isn't checked).
Messages come from the form fields' `error_messages` and the form's non-field ones.
"""
function model_form_unique_errors!(f::Form)
    T = f.model
    meta = modelmeta(T)
    inst = f.instance
    obj = inst === nothing ? T() : T(copy(getfield(inst, :_data)), Dict{Symbol,Any}())
    for (k, v) in f.cleaned_data
        mf = k === :__all__ ? nothing : findfield(meta, k)
        (mf === nothing || mf.kind === :m2m || mf.kind in FILE_KINDS) && continue
        ff = findfirst(x -> x.name === k, f.fields)
        ff !== nothing && (p = form_option(f.fields[ff], :inline_fk)) !== false && (v = p)     # (an inline formset's parent)
        setproperty!(obj, k, v)
    end
    formfields = Dict{Symbol,Field}(x.name => x for x in f.fields)
    exclude = Symbol[]
    for mf in all_fields(T)
        n = mf.name
        ff = get(formfields, n, nothing)
        if ff === nothing || haskey(f.errors, n) || !haskey(f.cleaned_data, n) || (!mf.blank && ff.blank && is_empty_value(f.cleaned_data[n]))
            push!(exclude, n)
        end
    end
    errs = validate_unique(obj; exclude, message_fields = formfields,
                           unique_together_message = get(f.nonfield_error_messages, "unique_together", nothing))
    for (k, msgs) in errs, m in msgs
        add_error!(f, k === :__all__ ? nothing : k, m)
    end
end

"""
Run the model's `Juango.clean` (if it has one) on the instance with the form's cleaned data
applied, as Django's ModelForm does: its errors go to the named fields, or to the form when the
field isn't on it.
"""
function model_form_clean!(f::Form)
    T = f.model
    which(clean, Tuple{T}).sig === Tuple{typeof(clean),Model} && return       # no clean of its own
    obj = f.instance === nothing ? T() : f.instance
    for (k, v) in f.cleaned_data
        (k === :__all__ || findfield(modelmeta(T), k) === nothing) && continue
        setproperty!(obj, k, v)
    end
    f.instance === nothing && (f.instance = obj)
    names = Set(fld.name for fld in f.fields)
    errs = model_clean_errors(obj)
    for (k, msgs) in errs, m in msgs
        add_error!(f, k in names ? k : nothing, m)
    end
    # what clean() set (a default it filled in) is what save! writes, as Django's instance built before clean()
    if isempty(errs)
        for k in collect(keys(f.cleaned_data))
            (k === :__all__ || (g = findfield(modelmeta(T), k)) === nothing || g.kind === :m2m) && continue
            f.cleaned_data[k] = getproperty(obj, k)
        end
    end
end

"A form's `clean` function (or its `clean_form` method); a `ValidationError` it throws becomes form errors."
function form_clean_hook(f::Form, fn = f.clean)
    try
        r = fn(f)
        # (a dict returned replaces the cleaned data, as Django's clean())
        r isa AbstractDict && r !== f.cleaned_data && (f.cleaned_data = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in r))
    catch e
        e isa ValidationError || rethrow()
        names = Set(fld.name for fld in f.fields)
        for (k, msgs) in e.errors, m in msgs
            add_error!(f, k in names ? k : nothing, m)
        end
    end
end

"""
    add_error!(form, field, error)

Attach an error to a field (or to the whole form with `field = nothing`), as Django's
`Form.add_error`: `error` is a message or a `ValidationError`, whose messages for other fields
go to those fields (then `field` must be `nothing`).
"""
function add_error!(f::Form, field, msg)
    if msg isa ValidationError
        if any(k -> k !== :__all__, keys(msg.errors))
            field === nothing || throw(ArgumentError("The argument `field` must be `None` when the `error` argument is a dictionary."))
            for (k, ms) in msg.errors, m in ms
                add_error!(f, k === :__all__ ? nothing : k, m)
            end
        else
            foreach(m -> add_error!(f, field, m), get(msg.errors, :__all__, String[]))
        end
        return nothing
    end
    field === nothing || any(x -> x.name === Symbol(field), f.fields) ||
        throw(ArgumentError("'$(f.name)' has no field named '$field'."))
    k = field === nothing ? :__all__ : Symbol(field)
    push!(get!(f.errors, k, String[]), string(msg))
    delete!(f.cleaned_data, k)
    nothing
end

cleaned_data(f::Form) = f.cleaned_data

"The form's hidden fields, as bound fields (Django's `Form.hidden_fields`)."
hidden_fields(f::Form) = [bf for bf in f if is_hidden_field(bf.field)]
"The form's other fields, as bound fields (Django's `Form.visible_fields`)."
visible_fields(f::Form) = [bf for bf in f if !is_hidden_field(bf.field)]

"""
    has_error(form, field = nothing)

Whether the field (`nothing`: the form itself) has errors, validating a bound form first
(Django's `Form.has_error`; Juango's errors don't keep their codes yet, #234).
"""
has_error(f::Form, field = nothing) = !isempty(get(ensure_validated(f).errors, field === nothing ? :__all__ : Symbol(field), String[]))

"The value a field starts with: the form's initial data, else the field's default."
function initial_for(f::Form, fld::Field)
    v = get(f.initial, fld.name, nothing)
    v isa Function && (v = v())
    v === nothing && !(fld.default isa NoDefault) && (v = fld.default isa Function || fld.default isa Type ? fld.default() : fld.default)
    v
end

Base.@nospecializeinfer normalized(@nospecialize(x::Model)) = x.id
normalized(x::AbstractVector) = Set(normalized.(x))
normalized(x::AbstractString) = isempty(x) ? nothing : String(x)
normalized(x) = x

"""
    has_changed(form) -> Bool

Whether submitted data differs from the initial values (used by formsets to skip blank
extra forms and unchanged objects).
"""
has_changed(f::Form) = f.data !== nothing && !isempty(changed_fields(f))

"The file uploaded for a field, or `nothing`."
function file_upload(f::Form, fld::Field)
    f.files === nothing && return nothing
    if is_multiple_file(fld)
        raw = f.files isa FileDict ? getlist(f.files, html_name(f, fld)) : get(f.files, html_name(f, fld), nothing)
        raw isa UploadedFile && (raw = [raw])
        ups = UploadedFile[u for u in something(raw, UploadedFile[]) if u isa UploadedFile && !isempty(u.name)]
        return isempty(ups) ? nothing : ups
    end
    v = get(f.files, html_name(f, fld), nothing)
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v isa UploadedFile ? v : nothing
end
file_cleared(f::Form, fld::Field) = f.data !== nothing && haskey(f.data, html_name(f, fld) * "-clear")

"A file field's value: the upload, `nothing` when cleared, else the current file."
function clean_file_field(f::Form, fld::Field)
    is_multiple_file(fld) && return clean_multiple_files(f, fld)
    up = file_upload(f, fld)
    if up === nothing && f.files !== nothing && (x = get(f.files, html_name(f, fld), nothing)) !== nothing &&
       !(x isa UploadedFile || x isa AbstractVector) && !(x isa AbstractString && isempty(x))
        return nothing, [field_message(fld, "invalid", gettext("No file was submitted. Check the encoding type on the form."))]
    end
    current = initial_for(f, fld)
    v = up !== nothing ? up : file_cleared(f, fld) ? nothing : current
    errs = String[]
    if up !== nothing && file_cleared(f, fld)
        push!(errs, field_message(fld, "contradiction", gettext("Please either submit a file or check the clear checkbox, not both.")))
    elseif v === nothing
        fld.blank || push!(errs, field_message(fld, "required", gettext("This field is required.")))
    elseif up !== nothing
        up.size == 0 && push!(errs, field_message(fld, "empty", gettext("The submitted file is empty.")))      # (not read: it may be on disk)
        fld.max_length !== nothing && length(up.name) > fld.max_length &&
            push!(errs, interpolate(gettext("Ensure this filename has at most %(max)d characters (it has %(len)d)."), Dict("max" => fld.max_length, "len" => length(up.name))))
        fld.kind === :image && image_size(up.data) === nothing &&
            push!(errs, field_message(fld, "invalid_image", gettext("Upload a valid image. The file you uploaded was either not an image or a corrupted image.")))
        append!(errs, validator_errors(fld, up))
    end
    v, errs
end
function clean_multiple_files(f::Form, fld::Field)
    ups = something(file_upload(f, fld), UploadedFile[])
    errs = String[]
    if isempty(ups)
        fld.blank || push!(errs, field_message(fld, "required", gettext("This field is required.")))
        return ups, errs
    end
    mx = fld.related[5].max_files
    mx !== nothing && length(ups) > mx &&
        push!(errs, interpolate(ngettext("Upload at most %(max)d file (you chose %(n)d).", "Upload at most %(max)d files (you chose %(n)d).", mx),
                                Dict("max" => mx, "n" => length(ups))))
    for up in ups
        pre = up.name * ": "
        up.size == 0 && push!(errs, pre * field_message(fld, "empty", gettext("The submitted file is empty.")))
        fld.max_length !== nothing && length(up.name) > fld.max_length &&
            push!(errs, pre * interpolate(gettext("Ensure this filename has at most %(max)d characters (it has %(len)d)."), Dict("max" => fld.max_length, "len" => length(up.name))))
        fld.kind === :image && image_size(up.data) === nothing &&
            push!(errs, pre * field_message(fld, "invalid_image", gettext("Upload a valid image. The file you uploaded was either not an image or a corrupted image.")))
        append!(errs, [pre * e for e in validator_errors(fld, up)])
    end
    ups, errs
end

"Names of the fields whose submitted value differs from the initial value."
function changed_fields(f::Form)
    out = Symbol[]
    f.data === nothing && return out
    for fld in f.fields
        fld.name in (:DELETE, :ORDER, :id) && continue
        form_option(fld, :inline_fk) === false || continue      # (an inline formset's parent key never changes, as Django's)
        if fld.kind in FILE_KINDS
            (file_upload(f, fld) !== nothing || file_cleared(f, fld)) && push!(out, fld.name)
            continue
        end
        v, err = to_julia(fld, raw_value(f, fld))
        init = initial_for(f, fld)
        if form_option(fld, :show_hidden_initial)       # (the initial value the page was rendered with)
            iv, ierr = to_julia(fld, get(f.data, "initial-" * html_name(f, fld), nothing))
            ierr !== nothing && (push!(out, fld.name); continue)
            init = iv
        end
        fld.kind === :bool && (init = truthy(init))
        fld.kind === :m2m && init === nothing && (init = Any[])
        (err !== nothing || !isequal(normalized(v), normalized(init))) && push!(out, fld.name)
    end
    out
end
non_field_errors(f::Form) = get(f.errors, :__all__, String[])

"""
    save!(form::Form; commit=true) -> instance

For a `ModelForm`: copy cleaned data onto the instance and save it.
"""
function save!(f::Form; commit = true)
    f.model === nothing && error("save! is only available for ModelForms")
    # (as Django's ValueError)
    is_valid(f) || throw(ArgumentError("The $(nameof(f.model)) could not be $(f.instance === nothing || f.instance.id === nothing ? "created" : "changed") because the data didn't validate."))
    obj = construct_instance(f, f.instance === nothing ? f.model() : f.instance)
    form_save_hook(f, Val(Symbol(f.name)), obj)
    f.instance = obj
    if commit
        save!(obj)
        save_m2m!(f)
    end
    obj
end

"""
    save_m2m!(form)

Save a ModelForm's many-to-many fields. `save!(form)` does this itself; call it after
`save!(form; commit=false)` once the instance has been saved.
"""
function save_m2m!(f::Form)
    obj = f.instance
    (obj === nothing || obj.id === nothing) && error("save the instance before its many-to-many fields")
    # by the model's many-to-many fields, whatever form field stands for each (field_classes may
    # put a ModelMultipleChoiceField there, to narrow the queryset or change the widget)
    m2m = f.model === nothing ? Set{Symbol}() : Set(g.name for g in modelmeta(f.model).m2m)
    for fld in f.fields
        ((fld.kind === :m2m || fld.name in m2m) && haskey(f.cleaned_data, fld.name)) || continue
        set!(getproperty(obj, fld.name), f.cleaned_data[fld.name])
    end
    obj
end

# --- rendering ----------------------------------------------------------------------------

"A form field bound to a form, for rendering (`{{ form.title }}`)."
struct BoundField
    form::Form
    field::Field
end

function Base.getindex(f::Form, name::Union{Symbol,AbstractString})
    i = findfirst(x -> x.name === Symbol(name), f.fields)
    # (as Django's message, naming the fields there are)
    i === nothing && throw(KeyError("Key '$name' not found in '$(f.name)'. Choices are: " * join(sort([string(x.name) for x in f.fields]), ", ") * "."))
    BoundField(f, f.fields[i])
end
Base.iterate(f::Form, i = 1) = i > length(f.fields) ? nothing : (BoundField(f, f.fields[i]), i + 1)
Base.length(f::Form) = length(f.fields)

function display_value(bf::BoundField)
    f, fld = bf.form, bf.field
    if f.data !== nothing && !form_option(fld, :disabled)      # (a disabled field shows its initial value)
        return raw_value(f, fld)
    end
    v = get(f.initial, fld.name, nothing)
    v isa Function && (v = v())          # (a function as the initial value is called, as Django's)
    v === nothing && (v = fld.default isa NoDefault ? nothing : (fld.default isa Function ? fld.default() : fld.default))
    fld.kind === :m2m && return v === nothing ? Any[] : collect(v)
    fld.kind === :modelmultichoice && return v === nothing ? Any[] : [x isa Model ? choice_key(fld.related, x) : string(x) for x in v]
    fld.kind === :multichoice && return v === nothing ? Any[] : [string(x) for x in v]
    fld.kind === :modelchoice && v isa Model && return choice_key(fld.related, v)
    v === nothing && return v
    fld.kind in (:json, :hstore) && return JSON.json(json_scalar_tree(v))
    fld.kind === :array && return join(string.(v), ", ")
    v isa ValueRange && return string(something(v.lower, ""), ", ", something(v.upper, ""))
    v isa Model && return v.id
    v isa TimeZones.ZonedDateTime && (v = make_naive(v))          # shown in the current time zone
    v isa DateTime && return Dates.format(v, "yyyy-mm-ddTHH:MM")
    v isa Duration && return duration_string(v; serial = true)      # 01:00:00, as Django's prepare_value
    v isa Bool && widget_kind(fld.widget) === :hidden && return v ? "True" : "False"
    v
end

"A list of errors as Django's `ErrorList.as_ul`: `class` adds a class (\"nonfield\"), `id` an id."
errors_html(errs; class = nothing, id = nothing, safe = nothing) = isempty(errs) ? "" :
    "<ul class=\"errorlist" * (class === nothing ? "" : " " * class) * "\"" * (id === nothing ? "" : id_attr(id)) * ">" *
    join(["<li>" * (safe !== nothing && safe[i] ? string(e) : escape_html(e)) * "</li>" for (i, e) in enumerate(errs)]) * "</ul>"

"""
    ErrorList(messages; error_class=nothing, id=nothing)

A list of error messages that renders itself, as Django's `ErrorList`: `{{ form.name.errors }}` and
`{{ form.non_field_errors }}` in a template are a `<ul class="errorlist">` (`as_ul`), and
`.as_text` gives `* message` lines. It is a vector of strings otherwise. Messages are escaped
unless they're safe strings (`mark_safe`); `ErrorList(e::ValidationError)` takes its messages.
"""
struct ErrorList <: AbstractVector{String}
    messages::Vector{String}
    error_class::Union{Nothing,String}
    id::Union{Nothing,String}
    safe::Vector{Bool}
end
ErrorList(ms = String[]; error_class = nothing, id = nothing) =
    ErrorList(String[m isa SafeString ? m.s : m isa ValidationError ? join(m.messages, " ") : string(m) for m in ms],
              error_class === nothing ? nothing : string(error_class), id === nothing ? nothing : string(id),
              Bool[m isa SafeString for m in ms])
ErrorList(e::ValidationError; kw...) = ErrorList(e.messages; kw...)
Base.copy(e::ErrorList) = ErrorList(copy(e.messages), e.error_class, e.id, copy(e.safe))
Base.size(e::ErrorList) = size(e.messages)
Base.getindex(e::ErrorList, i::Int) = e.messages[i]
as_ul(e::ErrorList) = SafeString(errors_html(e.messages; class = e.error_class, id = e.id, safe = e.safe))
"The errors as `* message` lines (Django's `ErrorList.as_text`)."
errors_text(e::ErrorList) = join(("* " * m for m in e.messages), "\n")
__html__(e::ErrorList) = as_ul(e).s
tattr(e::ErrorList, ::Val{S}) where {S} = S === :as_ul ? as_ul(e) : S === :as_text ? errors_text(e) : NOTFOUND

"""
A form's errors in a template (`{{ form.errors }}`), as Django's `ErrorDict`: a `<ul>` of the fields
with each one's own list (`as_ul`), or `* field` lines (`as_text`). A dict of field => `ErrorList` otherwise;
`ErrorDict(Dict("name" => "message"))` makes one from messages or lists of them.
"""
struct ErrorDict <: AbstractDict{Symbol,ErrorList}
    lists::Vector{Pair{Symbol,ErrorList}}
end
ErrorDict() = ErrorDict(Pair{Symbol,ErrorList}[])
Base.copy(e::ErrorDict) = ErrorDict(copy(e.lists))
ErrorDict(d::AbstractDict) = ErrorDict(Pair{Symbol,ErrorList}[Symbol(k) => error_list(v) for (k, v) in d])
error_list(v) = v isa ErrorList ? v : ErrorList(v isa AbstractString || v isa SafeString || v isa ValidationError ? [v] : v)
function Base.setindex!(e::ErrorDict, v, k)
    i = findfirst(p -> p.first === Symbol(k), e.lists)
    i === nothing ? push!(e.lists, Symbol(k) => error_list(v)) : (e.lists[i] = Symbol(k) => error_list(v))
    e
end
function ErrorDict(f::Form)
    ensure_validated(f)
    names = [x.name for x in f.fields if haskey(f.errors, x.name)]
    haskey(f.errors, :__all__) && push!(names, :__all__)
    append!(names, sort!([k for k in keys(f.errors) if !(k in names)]))
    ErrorDict([k => (k === :__all__ ? ErrorList(f.errors[k]; error_class = "nonfield") :
                     (i = findfirst(x -> x.name === k, f.fields); id = i === nothing ? "" : html_id(f, f.fields[i]);
                      ErrorList(f.errors[k]; id = isempty(id) ? nothing : id * "_error"))) for k in names])
end
Base.length(e::ErrorDict) = length(e.lists)
Base.iterate(e::ErrorDict, i = 1) = i > length(e.lists) ? nothing : (e.lists[i], i + 1)
Base.get(e::ErrorDict, k, default) = (i = findfirst(p -> p.first === Symbol(k), e.lists); i === nothing ? default : e.lists[i].second)
as_ul(e::ErrorDict) = SafeString(isempty(e.lists) ? "" : "<ul class=\"errorlist\">" *
    join("<li>" * escape_html(string(k)) * as_ul(v).s * "</li>" for (k, v) in e.lists) * "</ul>")
errors_text(e::ErrorDict) = join(("* " * string(k) * "\n" * join(("  * " * m for m in v), "\n") for (k, v) in e.lists), "\n")
__html__(e::ErrorDict) = as_ul(e).s
tattr(e::ErrorDict, ::Val{S}) where {S} = S === :as_ul ? as_ul(e) : S === :as_text ? errors_text(e) :
                                          (v = get(e, S, nothing); v === nothing ? NOTFOUND : v)

input_type(fld::Field) = fld.widget isa Widget && haskey(fld.widget.attrs, "type") ? fld.widget.attrs["type"] :    # (TextInput(attrs = type => email))
    widget_kind(fld.widget) === :password ? "password" : widget_kind(fld.widget) === :hidden ? "hidden" : widget_kind(fld.widget) === :text ? "text" :
    fld.kind === :email ? "email" : fld.kind === :url ? "url" : fld.kind in INT_KINDS || fld.kind in (:float, :decimal) ? "number" :
    fld.kind === :datetime ? "datetime-local" : fld.kind === :date ? "date" : fld.kind === :time ? "time" : "text"

"The three selects of a SelectDateWidget, in the order the language writes dates (day first unless English)."
function select_date_html(bf::BoundField)
    f, fld, w = bf.form, bf.field, bf.field.widget
    name, id = html_name(f, fld), html_id(f, fld)
    val = display_value(bf)
    y, m, d = "", "", ""
    if f.data !== nothing
        y, m, d = (string(something(get(f.data, name * s, nothing), "")) for s in ("_year", "_month", "_day"))
    elseif val isa Union{Date,DateTime}
        y, m, d = string(Dates.year(val)), string(Dates.month(val)), string(Dates.day(val))
    elseif val isa AbstractString && (dv = tryparse(Date, val)) !== nothing
        y, m, d = string(Dates.year(dv)), string(Dates.month(dv)), string(Dates.day(dv))
    end
    months = something(w.months, [Dates.monthname(i) for i in 1:12])
    sel(part, opts, cur) = begin
        io = IOBuffer()
        print(io, "<select name=\"", escape_html(name * "_" * part), "\" id=\"", escape_html(id * "_" * part), "\"",
              fld.blank || !f.use_required_attribute ? "" : " required", widget_attrs(Widget(; attrs = w.attrs)), ">")
        print(io, "<option value=\"\"", isempty(cur) ? " selected" : "", ">", escape_html(w.empty_label), "</option>")
        for (v, lbl) in opts
            print(io, "<option value=\"", v, "\"", string(v) == cur ? " selected" : "", ">", escape_html(string(lbl)), "</option>")
        end
        print(io, "</select>")
        String(take!(io))
    end
    parts = Dict("day" => sel("day", [(i, i) for i in 1:31], d), "month" => sel("month", [(i, months[i]) for i in 1:12], m),
                 "year" => sel("year", [(yy, yy) for yy in w.years], y))
    join((parts[p] for p in select_date_order()), "")
end
select_date_order() = startswith(lowercase(get_language()), "en") ? ("month", "day", "year") : ("day", "month", "year")
"The id a field's label points at: a SelectDateWidget's first select, as Django's `id_for_label`."
label_id(bf::BoundField) = bf.field.widget isa SelectDateWidget ? html_id(bf.form, bf.field) * "_" * first(select_date_order()) :
                                                                 html_id(bf.form, bf.field)

"""
    raw_id_input(bf; class = nothing)

A `raw_id_fields` field's id box: the related object's key (its `to_field` value), or the many-to-many
relation's keys comma-separated. The admin adds `class` and its lookup link.
"""
function raw_id_input(bf::BoundField; class = nothing)
    f, fld = bf.form, bf.field
    val = display_value(bf)
    v = if fld.kind === :m2m
        join((string(x isa Model ? x.pk : x) for x in (val isa AbstractVector ? val : val === nothing ? Any[] : Any[val])), ",")
    else
        val isa Model ? string(getproperty(val, something(fk_to_field(fld), :pk))) : display_string(val)
    end
    req = !fld.blank && f.use_required_attribute ? " required" : ""
    dis = form_option(fld, :disabled) ? " disabled" : ""
    a = " name=\"" * escape_html(html_name(f, fld)) * "\"" * id_attr(html_id(f, fld)) * dis * req * widget_attrs(fld.widget)
    haskey(f.errors, fld.name) && (a *= " aria-invalid=\"true\"")
    "<input type=\"text\"" * a * (class === nothing ? "" : " class=\"" * escape_html(class) * "\"") *
        (isempty(v) ? "" : " value=\"" * escape_html(v) * "\"") * described_by(bf) * ">"
end
"The object a foreign key's raw id box names (by its `to_field`, through the base manager, as Django's label lookup), or `nothing`."
function raw_id_current(bf::BoundField)
    fld = bf.field
    val = display_value(bf)
    val isa Model && return val
    (val === nothing || val == "") && return nothing
    R = related_model(fld)
    tf = something(fk_to_field(fld), :pk)
    v = tf === :pk || tf === :id ? parse_pk(R, val) : string(val)
    v === nothing && return nothing
    try
        first(filter(base_objects(R); (tf => v,)...))
    catch e
        e isa Union{ValidationError,ArgumentError,MethodError} || rethrow()
        nothing
    end
end

"""
The field's widget, with a hidden input holding its initial value after it when the field has
`show_hidden_initial = true` (`initial-<name>`, compared with the data for `changed_fields`, as Django's).
"""
function widget_html(bf::BoundField)
    h = form_option(bf.field, :show_hidden_initial) ? input_html(bf) * initial_hidden_html(bf) : input_html(bf)
    w = form_option(bf.field, :wrap_widget)         # (the admin's related links: `(bf, html) -> html`)
    w === false ? h : w(bf, h)
end
function initial_hidden_html(bf::BoundField)
    f, fld = bf.form, bf.field
    v = initial_for(f, fld)
    id = html_id(f, fld)
    "<input type=\"hidden\" name=\"initial-" * escape_html(html_name(f, fld)) * "\"" *
        (v === nothing || v == "" ? "" : " value=\"" * escape_html(string(v isa Model ? v.pk : v)) * "\"") *
        (isempty(id) ? "" : id_attr("initial-" * id)) * ">"
end
function input_html(bf::BoundField)
    f, fld = bf.form, bf.field
    fld.kind === :multi && return multi_widget_html(bf)
    widget_kind(fld.widget) === :hidden && fld.kind in MULTI_KINDS && return multiple_hidden_html(bf)
    fld.widget isa SelectDateWidget && return select_date_html(bf)
    fld.widget isa Widget && fld.widget.template_name !== nothing && return widget_template_html(bf)
    widget_kind(fld.widget) in (:radio, :checkboxes) && return choice_list_html(bf)
    name, id = escape_html(html_name(f, fld)), escape_html(html_id(f, fld))
    val = display_value(bf)
    req = !fld.blank && f.use_required_attribute ? " required" : ""      # (a required checkbox too: it must be checked, #247)
    dis = form_option(fld, :disabled) ? " disabled" : ""
    attrs = " name=\"$name\"" * id_attr(html_id(f, fld)) * "$dis$req" * widget_attrs(fld.widget)
    haskey(f.errors, fld.name) && !is_hidden_field(fld) && (attrs *= " aria-invalid=\"true\"")
    attrs *= described_by(bf)
    if fld.kind === :bool
        checked = f.data !== nothing ? (val !== nothing && lowercase(string(val)) in ("on", "true", "1", "yes")) : truthy(val)
        return "<input type=\"checkbox\"$attrs$(checked ? " checked" : "")>"
    elseif fld.kind === :m2m && widget_kind(fld.widget) === :raw_id        # Django's ManyToManyRawIdWidget: ids, comma-separated
        return raw_id_input(bf)
    elseif fld.kind === :fk && widget_kind(fld.widget) in (:raw_id, :autocomplete)
        R = related_model(fld)
        cur = raw_id_current(bf)
        if widget_kind(fld.widget) === :raw_id     # an id box, with the current object's name (Django's ForeignKeyRawIdWidget)
            return raw_id_input(bf) * (cur === nothing ? "" : "&nbsp;<strong>" * escape_html(string(cur)) * "</strong>")
        end
        # autocomplete: a select holding the current choice, filled by searching (admin JavaScript)
        opt = cur === nothing ? "" : "<option value=\"$(escape_html(string(cur.id)))\" selected>$(escape_html(string(cur)))</option>"
        return "<select$attrs data-autocomplete=\"$(modelmeta(R).app)/$(model_name(R))\"><option value=\"\">" * escape_html(get_blank_choice_label()) * "</option>$opt</select>"
    elseif fld.kind in FILE_KINDS
        cur = initial_for(f, fld)
        io = IOBuffer()
        if (cur isa FieldFile && !isempty(cur)) || cur isa UploadedFile
            # (a file not stored yet, on an instance from save!(form; commit = false), has no URL)
            print(io, "Currently: ", cur isa FieldFile ? "<a href=\"" * escape_html(cur.url) * "\">" * escape_html(cur.name) * "</a>" : escape_html(cur.name))
            fld.blank && print(io, " <label><input type=\"checkbox\" name=\"$name-clear\" id=\"$id-clear\"> Clear</label>")
            print(io, "<br>Change: ")
        end
        # (with a file already there the input may be left empty, so it isn't required, as Django's)
        has_file = !(cur === nothing || cur == "" || (cur isa FieldFile && isempty(cur)))
        a = replace(attrs, " required" => ""; count = 1)
        r = (!fld.blank && !has_file && f.use_required_attribute) ? " required" : ""
        print(io, "<input type=\"file\"", a, r, is_multiple_file(fld) ? " multiple" : "",
              fld.kind === :image ? " accept=\"image/*\"" : "", ">")
        return String(take!(io))
    elseif fld.kind === :geometry
        return geometry_widget(name, id, fld, f.data !== nothing ? val : get(f.initial, fld.name, nothing))
    elseif fld.kind === :m2m
        chosen = Set(string(x isa Model ? x.id : x) for x in (val isa AbstractVector ? val : Any[]))
        io = IOBuffer()
        print(io, "<select$attrs multiple>")
        for o in choices_queryset(fld)
            sel = string(o.id) in chosen ? " selected" : ""
            print(io, "<option value=\"", o.id, "\"", sel, ">", escape_html(string(o)), "</option>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif fld.kind in (:modelchoice, :modelmultichoice, :multichoice)
        multiple = fld.kind !== :modelchoice
        chosen = chosen_values(bf)          # (objects by their to_field_name)
        io = IOBuffer()
        print(io, "<select$attrs", multiple ? " multiple" : "", ">")
        if fld.kind === :multichoice
            opts = Pair{Any,Any}[string(c.first) => c.second for c in field_choices(fld)]
        else
            sp = fld.related
            opts = Pair{Any,Any}[choice_key(sp, o) => instance_label(sp, o) for o in choice_queryset(sp)]
            !multiple && sp.empty_label !== nothing &&
                print(io, "<option value=\"\"", val === nothing || val == "" ? " selected" : "", ">", escape_html(empty_choice_label(sp)), "</option>")
        end
        for (k, lbl) in opts
            print(io, "<option value=\"", escape_html(string(k)), "\"", string(k) in chosen ? " selected" : "",
                  option_attrs_html(fld.widget, k, lbl), ">", escape_html(string(lbl)), "</option>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif (fld.kind === :fk || fld.choices !== nothing || fld.kind === :filepath) && widget_kind(fld.widget) !== :hidden
        groups = fld.kind === :fk ? [(nothing, Pair{Any,Any}[target_value(fld, o) => string(o) for o in choices_queryset(fld)])] :
                 fld.kind === :filepath ? [(nothing, filepath_choices(fld))] : choice_groups(fld)
        io = IOBuffer()
        # a required select without an empty first choice has no `required` (Django's Select.use_required_attribute):
        # its first choice is always selected
        firsts = [k for (_, opts) in groups for (k, _) in opts]
        !(fld.blank || fld.kind === :fk) && (isempty(firsts) || string(firsts[1]) != "") && (attrs = replace(attrs, " required" => ""; count = 1))
        # NullBooleanField: unknown is its empty choice, and yes and no are read as Django's NullBooleanSelect reads them
        nb = fld.kind === :typedchoice && fld.related isa NamedTuple && haskey(fld.related, :any_value)
        nb && (val = val === true || val in ("True", "true", "2") ? "true" : val === false || val in ("False", "false", "3") ? "false" : "unknown")
        print(io, "<select$attrs>")
        # (selected when there's no value, as Django's)
        (fld.blank || fld.kind === :fk) && !nb &&
            print(io, "<option value=\"\"", val === nothing || val == "" ? " selected" : "", ">", escape_html(get_blank_choice_label()), "</option>")
        for (glabel, opts) in groups
            glabel === nothing || print(io, "<optgroup label=\"", escape_html(string(glabel)), "\">")
            for (k, lbl) in opts
                # (with no value, an empty-value choice is the one selected, as Django's)
                sel = (val === nothing ? string(k) == "" : string(val) == string(k)) ? " selected" : ""
                print(io, "<option value=\"", escape_html(string(k)), "\"", sel, option_attrs_html(fld.widget, k, lbl), ">", escape_html(string(lbl)), "</option>")
            end
            glabel === nothing || print(io, "</optgroup>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif (fld.kind in (:text, :json, :hstore) && widget_kind(fld.widget) === nothing) || widget_kind(fld.widget) === :textarea
        wa = fld.widget isa Widget ? fld.widget.attrs : Dict{String,String}()      # (the widget's own rows and cols replace these)
        # (a text field's max_length is the textarea's maxlength, as Django's)
        ml = fld.max_length !== nothing && !occursin(" maxlength=", attrs) ? " maxlength=\"$(fld.max_length)\"" : ""
        return "<textarea$attrs$ml" * (haskey(wa, "cols") ? "" : " cols=\"40\"") * (haskey(wa, "rows") ? "" : " rows=\"10\"") * ">" *
               escape_html(display_string(val)) * "</textarea>"
    end
    t = input_type(fld)
    t == "hidden" && (attrs = replace(attrs, " required" => ""; count = 1))       # (a hidden input is never required, as Django's)
    # a localized number is typed as text in the language's format, as Django's
    localized = t == "number" && fld.related isa NamedTuple && get(fld.related, :localize, false)
    localized && (t = "text")
    extra = fld.max_length !== nothing && t in ("text", "email", "url", "password") ? " maxlength=\"$(fld.max_length)\"" : ""
    isempty(extra) || (attrs = replace(attrs, r" maxlength=\"[^\"]*\"" => ""))         # (the field's max_length wins, as Django's)
    # the limits the validators set (min_length, min_value, max_value, step_size), as Django's widget_attrs
    lims = Dict{Symbol,String}()
    for v in fld.validators
        v isa MinLengthValidator && (lims[:minlength] = string(v.limit))
        v isa MinValueValidator && (lims[:min] = limit_attr(v.limit))
        v isa MaxValueValidator && (lims[:max] = limit_attr(v.limit))
        v isa StepValueValidator && (lims[:step] = limit_attr(v.limit))
    end
    t in ("text", "email", "url", "password", "search", "tel") && haskey(lims, :minlength) && !localized &&
        (extra *= " minlength=\"$(lims[:minlength])\"")
    if t == "number"
        step = haskey(lims, :step) ? lims[:step] : fld.kind === :float ? "any" : fld.kind === :decimal ? decimal_step(fld.decimal_places) : nothing
        step === nothing || (extra *= " step=\"$step\"")
        haskey(lims, :min) ? (extra *= " min=\"$(lims[:min])\"") : is_positive_kind(fld.kind) && (extra *= " min=\"0\"")    # seconds too
        haskey(lims, :max) && (extra *= " max=\"$(lims[:max])\"")
    end
    t == "time" && (extra *= " step=\"1\"")
    v = (t == "password" || val === nothing || val == "") ? "" : " value=\"" * escape_html(display_string(val)) * "\""
    "<input type=\"$t\"$attrs$extra$v>"
end

# --- widget types, choice options and their subwidgets ---------------------------------------------

"""
    widget_type(field) -> String

Django's name for the widget a field renders with (`BoundField.widget_type`): "text", "email",
"number", "date", "datetime", "time", "password", "hidden", "textarea", "checkbox", "select",
"selectmultiple", "radioselect", "checkboxselectmultiple", "clearablefile", "multi" ...
"""
function widget_type(fld::Field)
    wk = widget_kind(fld.widget)
    fld.widget isa MultiWidget && fld.widget.hidden && return "splithiddendatetime"
    wk === :multi && return "multi"
    wk === :radio && return "radioselect"
    wk === :checkboxes && return "checkboxselectmultiple"
    wk === :autocomplete && return "autocompleteselect"
    wk === :raw_id && return fld.kind === :m2m ? "manytomanyrawid" : "foreignkeyrawid"
    wk in (:hidden, :password, :textarea) && return string(wk)
    k = fld.kind
    k === :bool && return "checkbox"
    k in FILE_KINDS && return "clearablefile"
    k in (:m2m, :modelmultichoice, :multichoice) && return "selectmultiple"
    (k in (:fk, :modelchoice, :filepath) || fld.choices !== nothing) && return "select"
    k === :geometry && return "geometry"
    k in (:text, :json, :hstore) && return "textarea"
    t = input_type(fld)
    t == "datetime-local" ? "datetime" : t
end

is_multiple_choice(fld::Field) = fld.kind in (:m2m, :modelmultichoice, :multichoice)

"""
The objects a foreign key or many-to-many field can choose from in a form: the related model's,
narrowed by the field's `limit_choices_to` (a `Q`, a dict of lookups, or a function giving one,
called each time), as Django's.
"""
function choices_queryset(fld::Field)
    qs = objects(related_model(fld))
    o = fld.form === nothing ? nothing : get(fld.form, :choices_ordering, nothing)      # (an admin's ordering)
    o === nothing || (qs = order_by(qs, o...))
    l = fld.form === nothing ? nothing : get(fld.form, :limit_choices_to, nothing)
    l === nothing && return qs
    l isa Function && (l = l())
    qs = l isa Q ? filter(qs, l) : filter(qs; (Symbol(k) => v for (k, v) in pairs(l))...)
    distinct(qs)                 # (a limit across a relation can repeat a row)
end

"`(value, label)` pairs of a choice field's options (groups flattened)."
function choice_options(fld::Field)
    k = fld.kind
    k === :multichoice && return Pair{String,String}[string(c.first) => string(c.second) for c in field_choices(fld)]
    if k in (:modelchoice, :modelmultichoice)
        sp = fld.related
        return Pair{String,String}[string(choice_key(sp, o)) => instance_label(sp, o) for o in choice_queryset(sp)]
    end
    k === :fk && return Pair{String,String}[string(target_value(fld, o)) => string(o) for o in choices_queryset(fld)]
    k === :m2m && return Pair{String,String}[string(o.id) => string(o) for o in choices_queryset(fld)]
    k === :filepath && return Pair{String,String}[string(c.first) => string(c.second) for c in filepath_choices(fld)]
    fld.choices === nothing && return Pair{String,String}[]
    Pair{String,String}[string(c.first) => string(c.second) for (_, opts) in choice_groups(fld) for c in opts]
end

"The values of a field that are currently chosen, as strings."
function chosen_values(bf::BoundField)
    val = display_value(bf)
    vals = val isa AbstractVector ? val : val === nothing ? Any[] : Any[val]
    sp = bf.field.kind in (:modelchoice, :modelmultichoice) ? bf.field.related : nothing
    Set{String}(string(x isa Model ? (sp === nothing ? x.id : choice_key(sp, x)) : x) for x in vals)
end

"""
One option of a choice field, for laying the options out by hand (Django's `BoundWidget`):

    {% for choice in form.days %}{{ choice.tag }}<label for="{{ choice.id_for_label }}">{{ choice.choice_label }}</label>{% endfor %}

`{{ choice }}` is the input inside its label.
"""
struct BoundWidget
    bf::BoundField
    index::Int                 # 0-based, as in the ids
    value::String
    label::String
    selected::Bool
end

"The options of a choice field as `BoundWidget`s (with an empty first option for a blank single choice)."
function subwidgets(bf::BoundField)
    fld = bf.field
    opts = choice_options(fld)
    if !is_multiple_choice(fld) && fld.blank && fld.kind !== :bool && !any(o -> isempty(o.first), opts)
        el = fld.kind === :modelchoice ? empty_choice_label(fld.related) : get_blank_choice_label()
        opts = vcat(Pair{String,String}["" => el], opts)
    end
    chosen = chosen_values(bf)
    BoundWidget[BoundWidget(bf, i - 1, v, l, v in chosen) for (i, (v, l)) in enumerate(opts)]
end
Base.iterate(bf::BoundField, st = (subwidgets(bf), 1)) = st[2] > length(st[1]) ? nothing : (st[1][st[2]], (st[1], st[2] + 1))
Base.IteratorSize(::Type{BoundField}) = Base.SizeUnknown()
Base.eltype(::Type{BoundField}) = BoundWidget

subwidget_id(w::BoundWidget) = html_id(w.bf.form, w.bf.field) * "_" * string(w.index)
function subwidget_tag(w::BoundWidget)
    fld = w.bf.field
    wt = widget_type(fld)
    if wt in ("select", "selectmultiple")
        return "<option value=\"" * escape_html(w.value) * "\"" * (w.selected ? " selected" : "") *
               option_attrs_html(fld.widget, w.value, w.label) * ">" * escape_html(w.label) * "</option>"
    end
    t = (wt == "radioselect" || !is_multiple_choice(fld)) ? "radio" : "checkbox"
    req = t == "radio" && !fld.blank && w.bf.form.use_required_attribute ? " required" : ""
    "<input type=\"$t\" name=\"" * escape_html(html_name(w.bf.form, fld)) * "\" value=\"" * escape_html(w.value) *
        "\"" * (isempty(html_id(w.bf.form, fld)) ? "" : id_attr(subwidget_id(w))) * req * widget_attrs(fld.widget) *
        option_attrs_html(fld.widget, w.value, w.label) * (w.selected ? " checked" : "") * ">"
end
subwidget_html(w::BoundWidget) = "<label" * (isempty(html_id(w.bf.form, w.bf.field)) ? "" : " for=\"" * escape_html(subwidget_id(w)) * "\"") * ">" *
                                 subwidget_tag(w) * " " * escape_html(w.label) * "</label>"
function tattr(w::BoundWidget, ::Val{S}) where {S}
    S === :tag && return SafeString(subwidget_tag(w))
    S === :id_for_label && return subwidget_id(w)
    S === :choice_label && return w.label
    S === :data && return Dict{String,Any}("name" => html_name(w.bf.form, w.bf.field), "value" => w.value, "label" => w.label,
                                           "selected" => w.selected, "index" => string(w.index), "attrs" => Dict("id" => subwidget_id(w)))
    NOTFOUND
end
__html__(w::BoundWidget) = subwidget_html(w)
# In Julia too: bf.widget_type, bf.label, choice.tag ... (the template attributes)
function Base.getproperty(bf::BoundField, s::Symbol)
    (s === :form || s === :field) && return getfield(bf, s)
    r = tattr(bf, Val(s))
    r === NOTFOUND && throw(ArgumentError("BoundField has no attribute '$s'"))
    r
end
function Base.getproperty(w::BoundWidget, s::Symbol)
    s in (:bf, :index, :value, :label, :selected) && return getfield(w, s)
    r = tattr(w, Val(s))
    r === NOTFOUND && throw(ArgumentError("BoundWidget has no attribute '$s'"))
    r
end
Base.show(io::IO, w::BoundWidget) = print(io, subwidget_html(w))

"A widget with a `template_name`: rendered with the field's name, value, attributes and options."
function widget_template_html(bf::BoundField)
    f, fld, w = bf.form, bf.field, bf.field.widget
    is_choice = fld.kind in (:m2m, :fk, :modelchoice, :modelmultichoice, :multichoice, :filepath) || fld.choices !== nothing
    opts = is_choice ? [Dict{String,Any}("value" => o.value, "label" => o.label, "selected" => o.selected, "index" => o.index,
                                         "id" => subwidget_id(o),
                                         "attrs" => w.option_attrs === nothing ? Dict{String,Any}() : Dict{String,Any}(string(k) => v for (k, v) in w.option_attrs(o.value, o.label)))
                        for o in subwidgets(bf)] : Any[]
    widget = Dict{String,Any}("name" => html_name(f, fld), "id" => html_id(f, fld), "value" => display_value(bf),
                              "required" => !fld.blank && fld.kind !== :bool, "attrs" => merged_widget_attrs(w), "options" => opts,
                              "type" => widget_type(fld))
    ctx = Dict{String,Any}("widget" => widget, "field" => bf)
    w.context === nothing || merge!(ctx, to_context_dict(w.context(bf)))
    render_to_string(w.template_name, ctx)
end

"A radio or checkbox list (`widget = :radio` or `:checkboxes`), laid out as Django's: a div per option."
function choice_list_html(bf::BoundField)
    io = IOBuffer()
    print(io, "<div", id_attr(html_id(bf.form, bf.field)), ">")
    for w in subwidgets(bf)
        print(io, "<div>", subwidget_html(w), "</div>")
    end
    print(io, "</div>")
    String(take!(io))
end

"""
    add_widget_attrs!(form) do bf
        bf.widget_type == "checkbox" ? Dict("class" => "form-check-input") :
        bf.widget_type in ("select", "selectmultiple") ? Dict("class" => "form-select") : Dict("class" => "form-control")
    end

Add HTML attributes to each field's widget, chosen by looking at the bound field (its
`widget_type`, name, errors ...): the way to give every field of a form Bootstrap's classes.
`class` is appended to any class the widget already has; other attributes replace. Returns the form.
"""
function add_widget_attrs!(f, form::Form)
    for fld in form.fields
        extra = f(BoundField(form, fld))
        (extra === nothing || isempty(extra) || widget_kind(fld.widget) === :multi) && continue
        base = fld.widget isa Widget ? fld.widget : Widget(widget_kind(fld.widget))
        attrs = copy(base.attrs)
        for (k, v) in extra
            k, v = string(k), string(v)
            attrs[k] = k == "class" && haskey(attrs, k) ? attrs[k] * " " * v : v
        end
        fld.widget = Widget(base.kind; attrs = attrs, media = base.media, template_name = base.template_name,
                            context = base.context, option_attrs = base.option_attrs)
    end
    form
end

"""
    set_field!(form, name, field; before = nothing, after = nothing) -> form

Add a field to a built form, or replace the field of that name (Django's `form.fields[name] = ...`):
a replaced field keeps its place unless `before`/`after` (another field's name) say where;
a new one goes there, or at the end. The field is copied, and named `name`.
"""
function set_field!(form::Form, name, field::Field; before = nothing, after = nothing)
    n = Symbol(name)
    f = deepcopy(field)
    f.name = n
    i = findfirst(x -> x.name === n, form.fields)
    if i !== nothing && before === nothing && after === nothing
        form.fields[i] = f
    else
        i === nothing || deleteat!(form.fields, i)
        anchor = something(before, after, Some(nothing))
        k = anchor === nothing ? nothing : findfirst(x -> x.name === Symbol(anchor), form.fields)
        anchor !== nothing && k === nothing && throw(ArgumentError("set_field!: the form has no field '$anchor'"))
        k === nothing ? push!(form.fields, f) : insert!(form.fields, before !== nothing ? k : k + 1, f)
    end
    form.validated = false
    form
end

"Remove a field from a built form (and its errors and cleaned value); returns the form."
function delete_field!(form::Form, name)
    n = Symbol(name)
    filter!(x -> x.name !== n, form.fields)
    delete!(form.errors, n); delete!(form.cleaned_data, n)
    form
end

"""
    order_fields!(form, order)

Put these fields first, in this order (Django's `Form.order_fields`); the rest follow as they were.
Names the form doesn't have are ignored. `Form(...; field_order = [...])` does it on creation.
"""
function order_fields!(form::Form, order)
    names = Symbol.(collect(order))
    first_ = Field[f for n in names for f in form.fields if f.name === n]
    rest = Field[f for f in form.fields if !(f.name in names)]
    form.fields = vcat(first_, rest)
    form
end

"""
    errors_json_data(form) -> Dict{String,Vector{Dict}}    errors_as_json(form) -> String

The form's errors for an API or htmx response, as Django's `form.errors.get_json_data()` and
`as_json()`: `{"field": [{"message": "...", "code": ""}], "__all__": [...]}`.
"""
errors_json_data(form::Form) = (is_valid(form);
    Dict{String,Vector{Dict{String,String}}}(string(k) => [Dict("message" => m, "code" => "") for m in v] for (k, v) in form.errors))
errors_as_json(form::Form) = JSON.json(errors_json_data(form))

"""
    legend_tag(bf)

A `<legend>` with the field's label, for a radio or checkbox group in a `<fieldset>` (Django 4.1's
`BoundField.legend_tag`); `label_tag` is for single inputs.
"""
legend_tag(bf::BoundField, contents = nothing; attrs = nothing, label_suffix = nothing) =
    label_tag(bf, contents; attrs = attrs, label_suffix = label_suffix, tag = "legend")

"""
    label_tag(bf, contents=nothing; attrs=nothing, label_suffix=nothing)

The field's `<label>` (Django's `BoundField.label_tag`): `contents` replaces the label text (escaped
unless a `SafeString`), `attrs` adds attributes, `label_suffix` replaces the form's and field's
suffix. With no id (`auto_id = false`) just the text; a required field's label gets the form's
`required_css_class`.
"""
function label_tag(bf::BoundField, contents = nothing; attrs = nothing, label_suffix = nothing, tag = "label")
    f, fld = bf.form, bf.field
    txt = contents === nothing ? (form_option(fld, :no_label) ? "" : label_html(fld)) : contents isa SafeString ? contents.s : escape_html(string(contents))
    sfx = label_suffix !== nothing ? string(label_suffix) : something(form_option(fld, :label_suffix), f.label_suffix, ":")
    isempty(txt) || last(rstrip(txt)) in (':', '?', '.', '!') || (txt *= escape_html(sfx))
    id = html_id(f, fld)
    isempty(id) && return txt
    a = Dict{String,Any}(string(k) => v for (k, v) in pairs_of(something(attrs, Dict())))
    if !fld.blank && f.required_css_class !== nothing
        a["class"] = haskey(a, "class") ? string(a["class"], " ", f.required_css_class) : f.required_css_class
    end
    # (a radio or checkbox group's label points at no one input, as Django's)
    forattr = tag == "label" && !uses_fieldset(fld) ? " for=\"" * escape_html(label_id(bf)) * "\"" : ""
    "<$tag" * forattr * join(" " * escape_html(k) * "=\"" * escape_html(string(v)) * "\"" for (k, v) in sort!(collect(a); by = first)) *
        ">" * txt * "</$tag>"
end
"A row's label: none for a field with `label = \"\"` (Django's templates show `label_tag` only for a label)."
row_label(bf::BoundField) = form_option(bf.field, :no_label) ? "" : label_tag(bf)

"""
    css_classes(bf; extra_classes="")

The classes of the field's row (Django's `BoundField.css_classes`): `extra_classes`, then the form's
`error_css_class` if the field has errors and its `required_css_class` if it's required.
"""
function css_classes(bf::BoundField; extra_classes = "")
    cs = String[]
    for c in split(string(extra_classes))
        c in cs || push!(cs, c)
    end
    f = bf.form
    f.error_css_class !== nothing && haskey(f.errors, bf.field.name) && push!(cs, f.error_css_class)
    f.required_css_class !== nothing && !bf.field.blank && push!(cs, f.required_css_class)
    join(cs, " ")
end
row_class(bf::BoundField) = (c = css_classes(bf); isempty(c) ? "" : " class=\"" * escape_html(c) * "\"")
"""
The field rendered with another kind of widget, without the widget's own attributes (Django's
`BoundField.as_text()`, `as_textarea()`, `as_hidden()`; `{{ form.name.as_hidden }}` in templates).
"""
function as_widget(bf::BoundField, kind::Symbol)
    g = deepcopy(bf.field)
    g.widget = Widget(kind)
    kind === :text && g.kind in (:text, :json, :hstore) && (g.kind = :char)      # (a text input, not a textarea)
    widget_html(BoundField(bf.form, g))
end

"A multiple choice as hidden inputs, one per chosen value (Django's `MultipleHiddenInput`)."
function multiple_hidden_html(bf::BoundField)
    f, fld = bf.form, bf.field
    vals = display_value(bf)
    vals = vals isa AbstractVector ? vals : vals === nothing ? Any[] : Any[vals]
    id = html_id(f, fld)
    join(["<input type=\"hidden\" name=\"" * escape_html(html_name(f, fld)) * "\" value=\"" * escape_html(string(v isa Model ? v.pk : v)) * "\"" *
          (isempty(id) ? "" : id_attr(id * "_$(i - 1)")) * ">" for (i, v) in enumerate(vals)])
end

"A field's label as HTML: escaped, unless it was given as a `SafeString`."
label_html(fld::Field) = form_option(fld, :safe_label) ? label(fld) : escape_html(label(fld))

"Whether a field's inputs are a group, shown in a `<fieldset>` (radios, checkboxes, a multi-value field)."
uses_fieldset(fld::Field) = widget_type(fld) in ("radioselect", "checkboxselectmultiple", "multi")

"Validate a bound form not validated yet (rendering it and reading its errors do, as Django's `form.errors`)."
ensure_validated(f::Form) = (f.data !== nothing && !f.validated && is_valid(f); f)
is_hidden_field(fld::Field) = widget_kind(fld.widget) === :hidden || (fld.widget isa MultiWidget && fld.widget.hidden)
help_html(bf::BoundField, tag) = isempty(bf.field.help_text) ? "" :
    "<$tag class=\"helptext\"" * (isempty(html_id(bf.form, bf.field)) ? "" : id_attr(html_id(bf.form, bf.field) * "_helptext")) * ">" *
    (bf.field.help_text isa SafeString ? bf.field.help_text.s : escape_html(bf.field.help_text)) * "</$tag>"
field_errors_html(bf::BoundField) = (id = html_id(bf.form, bf.field);
    errors_html(get(bf.form.errors, bf.field.name, String[]); id = isempty(id) ? nothing : id * "_error"))
"""
    aria_describedby(bf) -> String or nothing

The ids of the field's help text and errors (Django's `BoundField.aria_describedby`): `""` when
there are none (or no id, or a hidden input), `nothing` when the widget sets its own.
"""
function aria_describedby(bf::BoundField)
    fld = bf.field
    fld.widget isa Widget && haskey(fld.widget.attrs, "aria-describedby") && return nothing
    id = html_id(bf.form, fld)
    (isempty(id) || is_hidden_field(fld)) && return ""
    ids = String[]
    isempty(fld.help_text) || push!(ids, id * "_helptext")
    haskey(bf.form.errors, fld.name) && push!(ids, id * "_error")
    join(ids, " ")
end
"` aria-describedby=...`, unless empty or the widget sets its own."
described_by(bf::BoundField) = (ids = aria_describedby(bf); ids === nothing || isempty(ids) ? "" : " aria-describedby=\"" * escape_html(ids) * "\"")

function field_row(bf::BoundField; tag = "p")
    fld = bf.field
    is_hidden_field(fld) && return widget_html(bf)
    errs = field_errors_html(bf)
    if tag == "div"            # Django's div.html: label (a group's legend), help text, errors, then the widget
        if uses_fieldset(fld)
            lg = form_option(fld, :no_label) ? "" : legend_tag(bf)
            return "<div" * row_class(bf) * "><fieldset>" * lg * help_html(bf, "div") * errs * widget_html(bf) * "</fieldset></div>"
        end
        return "<div" * row_class(bf) * ">" * row_label(bf) * help_html(bf, "div") * errs * widget_html(bf) * "</div>"
    end
    body = fld.kind === :bool ? widget_html(bf) * " " * row_label(bf) : row_label(bf) * " " * widget_html(bf)
    tag == "li" && return "<li" * row_class(bf) * ">" * errs * body * help_html(bf, "span") * "</li>"
    errs * "<$tag" * row_class(bf) * ">" * body * help_html(bf, "span") * "</$tag>"
end

"""
The rows around the form's own errors: the non-field errors and each hidden field's ("(Hidden
field name) ..."), then the visible rows with the hidden inputs inside the last one, as Django's.
"""
function render_rows(f::Form, row, close, wrap_hidden; wrap_errors = identity)
    ensure_validated(f)          # (a bound form shows its errors, as Django's form.errors validates it)
    top = copy(non_field_errors(f))
    for bf in f
        is_hidden_field(bf.field) || continue
        append!(top, [interpolate(gettext("(Hidden field %(name)s) %(error)s"), Dict("name" => string(bf.field.name), "error" => e))
                      for e in get(f.errors, bf.field.name, String[])])
    end
    rows = [row(bf) for bf in f if !is_hidden_field(bf.field)]
    hidden = join([widget_html(bf) for bf in f if is_hidden_field(bf.field)])
    if !isempty(hidden)
        if isempty(rows)        # (only hidden fields: bare, or in a row after the form's errors, as Django's templates)
            push!(rows, isempty(top) ? hidden : wrap_hidden(hidden))
        else
            last = rows[end]
            i = findlast(close, last)
            rows[end] = i === nothing ? last * hidden : last[1:prevind(last, first(i))] * hidden * last[first(i):end]
        end
    end
    errs = errors_html(top; class = "nonfield")
    SafeString((isempty(errs) ? "" : wrap_errors(errs)) * join(rows, "\n"))
end

"Render the whole form as `<p>` rows (returns a `SafeString`)."
as_p(f::Form) = render_rows(f, bf -> field_row(bf), "</p>", h -> "<p>" * h * "</p>")
"The whole form as `<div>` rows, Django's default layout."
as_div(f::Form) = render_rows(f, bf -> field_row(bf; tag = "div"), "</div>", h -> "<div>" * h * "</div>")
"The whole form as `<li>` rows (put them in a `<ul>`)."
as_ul(f::Form) = render_rows(f, bf -> field_row(bf; tag = "li"), "</li>", h -> "<li>" * h * "</li>"; wrap_errors = e -> "<li>" * e * "</li>")
"The whole form as table rows (put them in a `<table>`)."
as_table(f::Form) = render_rows(f, bf -> "<tr" * row_class(bf) * "><th>" * row_label(bf) * "</th><td>" * field_errors_html(bf) * widget_html(bf) *
                                         (isempty(bf.field.help_text) ? "" : "<br>" * help_html(bf, "span")) * "</td></tr>",
                                "</td></tr>", h -> "<tr><td colspan=\"2\">" * h * "</td></tr>";
                                wrap_errors = e -> "<tr><td colspan=\"2\">" * e * "</td></tr>")

# {{ form }}: as `<div>` rows (Django 5's default; as_p, as_ul and as_table are there too), or the FORM_RENDERER's template
__html__(f::Form) = get(settings, :FORM_RENDERER, nothing) isa TemplateFormRenderer ? render_form(f).s : as_div(f).s
__html__(bf::BoundField) = widget_html(bf)

"""
    as_field_group(bound_field)

The field's label, help text, errors and widget together, rendered with the field's
`template_name` or `juango/forms/field.html` (Django 5's `{{ form.name.as_field_group }}`).
"""
as_field_group(bf::BoundField) =
    SafeString(render(get_template(something(bf.field.template_name, "juango/forms/field.html")), Dict{String,Any}("field" => bf)))
Base.show(io::IO, bf::BoundField) = print(io, "<BoundField ", bf.field.name, ">")

function tattr(f::Form, ::Val{S}) where {S}
    S === :as_p && return as_p(f)
    S === :as_div && return as_div(f)
    S === :as_ul && return as_ul(f)
    S === :as_table && return as_table(f)
    S === :errors && return ErrorDict(f)
    S === :non_field_errors && return ErrorList(non_field_errors(ensure_validated(f)); error_class = "nonfield")
    S === :is_bound && return f.data !== nothing
    S === :is_multipart && return is_multipart(f)
    S === :cleaned_data && return f.cleaned_data
    S === :media && return render_media(form_media(f))
    S === :render && return render_form(f)
    S === :instance && return f.instance
    S === :hidden_fields && return [bf for bf in f if widget_kind(bf.field.widget) === :hidden]
    S === :visible_fields && return [bf for bf in f if widget_kind(bf.field.widget) !== :hidden]
    i = findfirst(x -> x.name === S, f.fields)
    i === nothing ? NOTFOUND : BoundField(f, f.fields[i])
end

function tattr(bf::BoundField, ::Val{S}) where {S}
    S === :label && return label(bf.field)
    S === :label_tag && return SafeString(row_label(bf))
    S === :legend_tag && return SafeString(form_option(bf.field, :no_label) ? "" : legend_tag(bf))
    S === :css_classes && return css_classes(bf)
    S === :aria_describedby && return aria_describedby(bf)
    S === :errors_html && return SafeString(field_errors_html(bf))
    S === :help_html && return SafeString(help_html(bf, "div"))
    S === :errors && return (id = html_id(bf.form, bf.field);
                             ErrorList(get(ensure_validated(bf.form).errors, bf.field.name, String[]); id = isempty(id) ? nothing : id * "_error"))
    S === :name && return string(bf.field.name)        # the field's own name (Django's); html_name is the prefixed one
    S === :id_for_label && return label_id(bf)
    S === :value && return display_value(bf)
    S === :help_text && return bf.field.help_text
    S === :widget && return SafeString(widget_html(bf))
    S === :row && return SafeString(field_row(bf))
    S === :as_field_group && return as_field_group(bf)
    S === :is_hidden && return widget_kind(bf.field.widget) === :hidden
    S === :field && return bf.field
    S === :widget_type && return widget_type(bf.field)
    S === :auto_id && return html_id(bf.form, bf.field)
    S === :required && return !bf.field.blank && bf.field.kind !== :bool
    S === :html_name && return html_name(bf.form, bf.field)
    S === :initial && return initial_for(bf.form, bf.field)
    S === :data && return bf.form.data === nothing ? nothing : raw_value(bf.form, bf.field)
    S === :use_fieldset && return uses_fieldset(bf.field)
    S in (:as_text, :as_textarea, :as_hidden) && return SafeString(as_widget(bf, S === :as_text ? :text : S === :as_textarea ? :textarea : :hidden))
    S === :subwidgets && return subwidgets(bf)
    NOTFOUND
end
