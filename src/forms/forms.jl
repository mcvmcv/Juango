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
Fields are rendered with `as_p(form)` (or `{{ form }}` / `{{ form.as_p }}` in
templates), or individually as `{{ form.fieldname }}`.
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
end

"""
    Form(fields::Vector{Pair{Symbol,Field}}; data=nothing, initial=Dict(), prefix="", clean=nothing, name="Form")

`clean`, if given, is called as `clean(form)` after field validation and may call
`add_error!(form, field_or_nothing, msg)` or modify `form.cleaned_data`.
"""
function Form(fields::Vector; data = nothing, initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
              name = "Form", model = nothing, instance = nothing, files = nothing, media = nothing)
    fs = Field[]
    for (n, f) in fields
        f = deepcopy(f)
        f.name = Symbol(n)
        push!(fs, f)
    end
    Form(string(name), fs, data, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)),
         Dict{Symbol,Vector{String}}(), Dict{Symbol,Any}(), model, instance, string(prefix), false, clean, files,
         media === nothing ? Media() : media)
end

# --- form-only fields --------------------------------------------------------------------------------

"What a ModelChoiceField chooses from."
struct ModelChoiceSpec
    queryset::Any                    # a QuerySet (or a model: all its objects), read each time it's needed
    to_field_name::Union{Nothing,Symbol}
    empty_label::Union{Nothing,String}
    label_from_instance::Any         # nothing (string(obj)) or obj -> label
end
choice_queryset(s::ModelChoiceSpec) = s.queryset isa Type ? objects(s.queryset) : s.queryset
choice_key(s::ModelChoiceSpec, o) = s.to_field_name === nothing ? pk_string(o) : string(getproperty(o, s.to_field_name))
instance_label(s::ModelChoiceSpec, o) = s.label_from_instance === nothing ? string(o) : string(s.label_from_instance(o))

"""
    ModelChoiceField(queryset; to_field_name = nothing, empty_label = "---------", label_from_instance = nothing, kw...)

A select of model objects for any form (a `ModelForm` makes these for foreign keys itself). The
cleaned value is the object; `to_field_name` submits another unique field instead of the primary
key. The queryset is read when the form is rendered and validated.
"""
Base.@nospecializeinfer ModelChoiceField(@nospecialize(qs); to_field_name = nothing, empty_label = "---------", label_from_instance = nothing, kw...) =
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
TypedChoiceField(choices; coerce = identity, empty_value = "", kw...) =
    Field(:typedchoice; choices = choices, related = (coerce = coerce, empty_value = empty_value), kw...)
TypedMultipleChoiceField(choices; coerce = identity, kw...) = Field(:multichoice; choices = choices, related = (coerce = coerce,), kw...)
MultipleChoiceField(choices; kw...) = TypedMultipleChoiceField(choices; kw...)

"""
    RegexField(regex; max_length = nothing, error_message = "Enter a valid value.", kw...)

A text field whose value must match `regex`.
"""
RegexField(rx; max_length = nothing, error_message = nothing, validators = Any[], kw...) =
    Field(:char; max_length = max_length,
          validators = vcat(Any[v -> occursin(rx isa Regex ? rx : Regex(string(rx)), string(v)) ||
                                     something(error_message, gettext("Enter a valid value."))], collect(Any, validators)), kw...)

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
        function $(esc(name))(data = nothing; initial = Dict{Symbol,Any}(), prefix = "", clean = nothing, files = nothing, media = nothing)
            $F(Pair{Symbol,Any}[$(pairs_...)]; data = data, initial = initial, prefix = prefix,
               clean = clean, name = $(string(name)), files = files, media = media)
        end
    end
end

"Hook for cross-field validation of `@form`-defined forms (dispatch on `Val{:FormName}`)."
clean_form(f::Form, ::Val) = nothing
"Hook run by `save!(form)` on the instance before it is saved (dispatch on `Val{:FormName}`)."
Base.@nospecializeinfer form_save_hook(f::Form, ::Val, @nospecialize(obj)) = nothing

"""
    ModelForm(Model; data=nothing, instance=nothing, fields=nothing, exclude=[], initial=Dict(), widgets=Dict())

A form generated from a model's fields. `save!(form)` writes the cleaned data
into the instance (creating one if needed) and saves it.
"""
Base.@nospecializeinfer function ModelForm(@nospecialize(T::Type{<:Model}); data = nothing, files = nothing, @nospecialize(instance = nothing), fields = nothing, exclude = Symbol[],
                   initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
                   labels = Dict{Symbol,String}(), help_texts = Dict{Symbol,String}(),
                   widgets = Dict{Symbol,Symbol}(), field_classes = Dict{Symbol,Any}(),
                   formfield_callback = nothing)
    meta = modelmeta(T)
    chosen = fields === nothing ? vcat([f.name for f in all_fields(T) if f.editable], [f.name for f in meta.m2m if f.editable]) :
             Symbol.(collect(fields))
    fs = Pair{Symbol,Any}[]
    for n in chosen
        n in exclude && continue
        i = findfirst(x -> x.name === n, meta.m2m)
        f = deepcopy(i === nothing ? getfield_meta(T, n) : meta.m2m[i])
        haskey(labels, n) && (f.verbose_name = labels[n])
        haskey(help_texts, n) && (f.help_text = help_texts[n])
        haskey(widgets, n) && (f.widget = widgets[n])
        haskey(field_classes, n) && (f = deepcopy(field_classes[n]))            # a different form field for it
        if formfield_callback !== nothing
            f = formfield_callback(f)                                          # nothing leaves the field out
            f === nothing && continue
        end
        push!(fs, n => f)
    end
    init = Dict{Symbol,Any}()
    if instance !== nothing
        for (n, f) in fs
            init[n] = f.kind === :fk ? getproperty(instance, attname(f)) :
                      f.kind === :m2m ? (instance.id === nothing ? Any[] : [o.id for o in getproperty(instance, n)]) :
                      getproperty(instance, n)
            init[n] === DB_DEFAULT && (init[n] = nothing)
        end
    end
    merge!(init, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)))
    Form(fs; data = data, initial = init, prefix = prefix, clean = clean, name = "$(nameof(T))Form",
         model = T, instance = instance, files = files)
end

Base.show(io::IO, f::Form) = print(io, "<", f.name, " bound=", f.data !== nothing, " fields=(",
                                   join(string.(getfield.(f.fields, :name)), ", "), ")>")

html_name(f::Form, fld::Field) = isempty(f.prefix) ? string(fld.name) : f.prefix * "-" * string(fld.name)
html_id(f::Form, fld::Field) = "id_" * html_name(f, fld)

function raw_value(f::Form, fld::Field)
    f.data === nothing && return nothing
    fld.kind === :multi && return multi_raw(f, fld)
    fld.kind in MULTI_KINDS && return raw_list(f.data, html_name(f, fld))
    get(f.data, html_name(f, fld), nothing)
end
"All submitted values for a multi-valued field."
raw_list(d::QueryDict, k) = getlist(d, k)
function raw_list(d::AbstractDict, k)
    v = get(d, k, String[])
    v isa AbstractVector ? collect(v) : [v]
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
                v in keys_ || return nothing, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v))
            end
            return Any[fld.related.coerce(v) for v in vals], nothing
        end
        s = fld.related
        objs = Dict(choice_key(s, o) => o for o in choice_queryset(s))
        for v in vals
            haskey(objs, v) || return nothing, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => v))
        end
        return Any[objs[v] for v in unique(vals)], nothing
    end
    if k === :m2m
        ids = Any[]
        for r in (raw === nothing ? [] : raw)
            sr = strip(string(r))
            isempty(sr) && continue
            id = parse_pk(related_model(fld), sr)
            id === nothing && return nothing, gettext("Enter a list of values.")
            push!(ids, id)
        end
        objs = isempty(ids) ? Any[] : collect(filter(objects(related_model(fld)); id__in = unique(ids)))
        length(objs) == length(unique(ids)) || return nothing, gettext("Select a valid choice. One of the selected values is not one of the available choices.")
        return objs, nothing
    end
    if k === :bool
        return (raw !== nothing && lowercase(string(raw)) in ("on", "true", "1", "yes")), nothing
    end
    s = raw === nothing ? "" : (widget_kind(fld.widget) === :password ? string(raw) : strip(string(raw)))
    isempty(s) && return ((k in STRING_KINDS || k === :filepath) && !fld.null ? "" : nothing), nothing
    if k in STRING_KINDS
        return String(s), nothing
    elseif k in INT_KINDS
        v = tryparse(Int, s)
        return v, v === nothing ? gettext("Enter a whole number.") : nothing
    elseif k === :float
        v = tryparse(Float64, s)
        return v, v === nothing ? gettext("Enter a number.") : nothing
    elseif k === :decimal
        v = tryparse(Decimal, s)
        return v, v === nothing ? gettext("Enter a number.") : nothing
    elseif k === :datetime
        for fmt in (dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-ddTHH:MM", dateformat"yyyy-mm-dd HH:MM:SS",
                    dateformat"yyyy-mm-dd HH:MM", dateformat"yyyy-mm-ddTHH:MM:SS.s", dateformat"yyyy-mm-dd")
            v = tryparse(DateTime, s, fmt)
            v === nothing || return (settings.USE_TZ ? make_aware(v) : v), nothing      # typed in the current time zone
        end
        return nothing, gettext("Enter a valid date/time.")
    elseif k === :date
        v = tryparse(Date, s, dateformat"yyyy-mm-dd")
        return v, v === nothing ? gettext("Enter a valid date.") : nothing
    elseif k === :ipaddress
        r = clean_ip(s, fld.related.protocol, fld.related.unpack_ipv4)
        return r isa Tuple ? (nothing, r[1]) : (r, nothing)
    elseif k === :filepath
        any(c -> c.first == s, filepath_choices(fld)) ||
            return nothing, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => s))
        return String(s), nothing
    elseif k === :time
        v = parse_time(s)
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
    elseif k === :uuid
        v = tryparse(UUID, s)
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
        return obj, obj === nothing ? gettext("Select a valid choice. That choice is not one of the available choices.") : nothing
    elseif k === :typedchoice
        any(c -> string(c.first) == s, field_choices(fld)) ||
            return nothing, interpolate(gettext("Select a valid choice. %(value)s is not one of the available choices."), Dict("value" => s))
        return fld.related.coerce(String(s)), nothing
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
    elseif k === :fk
        id = parse_pk(related_model(fld), s)
        obj = id === nothing ? nothing : first(filter(objects(related_model(fld)); id = id))
        return obj, obj === nothing ? gettext("Select a valid choice. That choice is not one of the available choices.") : nothing
    end
    String(s), nothing
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
    for fld in f.fields
        if fld.kind in FILE_KINDS
            v, errs = clean_file_field(f, fld)
            foreach(e -> add_error!(f, fld.name, e), errs)
            isempty(errs) && (f.cleaned_data[fld.name] = v)
            continue
        end
        v, err = to_julia(fld, raw_value(f, fld))
        if err !== nothing
            add_error!(f, fld.name, err)
            continue
        end
        errs = fld.kind in MULTI_KINDS ? (isempty(v) && !fld.blank ? [gettext("This field is required.")] : String[]) :
               validate_field(fld, v isa Model ? v.id : v)
        if isempty(errs) && f.model !== nothing && fld.unique && v !== nothing && v != ""
            q = filter(objects(f.model), Q(attname(fld) => v))
            (f.instance !== nothing && f.instance.id !== nothing) && (q = filter(q, !Q(id = f.instance.id)))
            exists(q) && push!(errs, interpolate(gettext("%(model)s with this %(field)s already exists."), Dict("model" => uppercasefirst(string(modelmeta(f.model).verbose_name)), "field" => label(fld))))
        end
        foreach(e -> add_error!(f, fld.name, e), errs)
        isempty(errs) && (f.cleaned_data[fld.name] = v)
    end
    f.model !== nothing && isempty(f.errors) && model_form_constraint_errors!(f)
    f.clean === nothing || f.clean(f)
    clean_form(f, Val(Symbol(f.name)))
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
        findfield(modelmeta(T), Symbol(k)) === nothing || (values[Symbol(k)] = v)
    end
    id = inst === nothing ? nothing : inst.id
    for e in vcat(unique_together_errors(T, values, id), constraint_errors(T, values, id))
        add_error!(f, nothing, e)
    end
end

"Attach an error to a field (or to the whole form with `field=nothing`)."
function add_error!(f::Form, field, msg)
    k = field === nothing ? :__all__ : Symbol(field)
    push!(get!(f.errors, k, String[]), string(msg))
    delete!(f.cleaned_data, k)
    nothing
end

cleaned_data(f::Form) = f.cleaned_data

"The value a field starts with: the form's initial data, else the field's default."
function initial_for(f::Form, fld::Field)
    v = get(f.initial, fld.name, nothing)
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
    v = get(f.files, html_name(f, fld), nothing)
    v isa AbstractVector && (v = isempty(v) ? nothing : first(v))
    v isa UploadedFile ? v : nothing
end
file_cleared(f::Form, fld::Field) = f.data !== nothing && haskey(f.data, html_name(f, fld) * "-clear")

"A file field's value: the upload, `nothing` when cleared, else the current file."
function clean_file_field(f::Form, fld::Field)
    up = file_upload(f, fld)
    current = initial_for(f, fld)
    v = up !== nothing ? up : file_cleared(f, fld) ? nothing : current
    errs = String[]
    if up !== nothing && file_cleared(f, fld)
        push!(errs, gettext("Please either submit a file or check the clear checkbox, not both."))
    elseif v === nothing
        fld.blank || push!(errs, gettext("This field is required."))
    elseif up !== nothing
        isempty(up.data) && push!(errs, gettext("The submitted file is empty."))
        fld.max_length !== nothing && length(up.name) > fld.max_length &&
            push!(errs, interpolate(gettext("Ensure this filename has at most %(max)d characters (it has %(len)d)."), Dict("max" => fld.max_length, "len" => length(up.name))))
        fld.kind === :image && image_size(up.data) === nothing &&
            push!(errs, gettext("Upload a valid image. The file you uploaded was either not an image or a corrupted image."))
        for val in fld.validators
            r = val(up)
            r isa AbstractString && push!(errs, r)
            r === false && push!(errs, gettext("Enter a valid value."))
        end
    end
    v, errs
end

"Names of the fields whose submitted value differs from the initial value."
function changed_fields(f::Form)
    out = Symbol[]
    f.data === nothing && return out
    for fld in f.fields
        fld.name in (:DELETE, :ORDER, :id) && continue
        if fld.kind in FILE_KINDS
            (file_upload(f, fld) !== nothing || file_cleared(f, fld)) && push!(out, fld.name)
            continue
        end
        v, err = to_julia(fld, raw_value(f, fld))
        init = initial_for(f, fld)
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
    is_valid(f) || error("cannot save a form with errors: $(f.errors)")
    obj = f.instance === nothing ? f.model() : f.instance
    for (k, v) in f.cleaned_data
        k === :__all__ && continue
        findfield(modelmeta(f.model), k) === nothing && continue
        setproperty!(obj, k, v)
    end
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
    for fld in f.fields
        (fld.kind === :m2m && haskey(f.cleaned_data, fld.name)) || continue
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
    i === nothing && throw(KeyError(name))
    BoundField(f, f.fields[i])
end
Base.iterate(f::Form, i = 1) = i > length(f.fields) ? nothing : (BoundField(f, f.fields[i]), i + 1)
Base.length(f::Form) = length(f.fields)

function display_value(bf::BoundField)
    f, fld = bf.form, bf.field
    if f.data !== nothing
        return raw_value(f, fld)
    end
    v = get(f.initial, fld.name, nothing)
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
    v
end

errors_html(errs) = isempty(errs) ? "" :
    "<ul class=\"errorlist\">" * join(["<li>" * escape_html(e) * "</li>" for e in errs]) * "</ul>"

input_type(fld::Field) = widget_kind(fld.widget) === :password ? "password" : widget_kind(fld.widget) === :hidden ? "hidden" :
    fld.kind === :email ? "email" : fld.kind === :url ? "url" : fld.kind in INT_KINDS || fld.kind in (:float, :decimal) ? "number" :
    fld.kind === :datetime ? "datetime-local" : fld.kind === :date ? "date" : fld.kind === :time ? "time" : "text"

function widget_html(bf::BoundField)
    f, fld = bf.form, bf.field
    fld.kind === :multi && return multi_widget_html(bf)
    name, id = escape_html(html_name(f, fld)), escape_html(html_id(f, fld))
    val = display_value(bf)
    req = !fld.blank && fld.kind !== :bool ? " required" : ""
    attrs = " name=\"$name\" id=\"$id\"$req" * widget_attrs(fld.widget)
    haskey(f.errors, fld.name) && (attrs *= " aria-invalid=\"true\"")
    if fld.kind === :bool
        checked = f.data !== nothing ? (val !== nothing && lowercase(string(val)) in ("on", "true", "1", "yes")) : truthy(val)
        return "<input type=\"checkbox\"$attrs$(checked ? " checked" : "")>"
    elseif fld.kind === :fk && widget_kind(fld.widget) in (:raw_id, :autocomplete)
        R = related_model(fld)
        cur = (val === nothing || val == "") ? nothing : first(filter(base_objects(R); id = parse_pk(R, val)))
        if widget_kind(fld.widget) === :raw_id     # an id box, with the current object's name
            return "<input type=\"text\"$attrs size=\"10\" class=\"raw-id\" value=\"$(escape_html(display_string(val)))\">" *
                   (cur === nothing ? "" : " <span class=\"muted\">" * escape_html(string(cur)) * "</span>")
        end
        # autocomplete: a select holding the current choice, filled by searching (admin JavaScript)
        opt = cur === nothing ? "" : "<option value=\"$(escape_html(string(cur.id)))\" selected>$(escape_html(string(cur)))</option>"
        return "<select$attrs data-autocomplete=\"$(model_name(R))\"><option value=\"\">---------</option>$opt</select>"
    elseif fld.kind in FILE_KINDS
        cur = get(f.initial, fld.name, nothing)
        io = IOBuffer()
        if cur isa FieldFile && !isempty(cur)
            print(io, "Currently: <a href=\"", escape_html(cur.url), "\">", escape_html(cur.name), "</a>")
            fld.blank && print(io, " <label><input type=\"checkbox\" name=\"$name-clear\" id=\"$id-clear\"> Clear</label>")
            print(io, "<br>Change: ")
        end
        r = (!fld.blank && !(cur isa FieldFile)) ? " required" : ""
        print(io, "<input type=\"file\" name=\"$name\" id=\"$id\"$r", fld.kind === :image ? " accept=\"image/*\"" : "", ">")
        return String(take!(io))
    elseif fld.kind === :geometry
        return geometry_widget(name, id, fld, f.data !== nothing ? val : get(f.initial, fld.name, nothing))
    elseif fld.kind === :m2m
        chosen = Set(string(x isa Model ? x.id : x) for x in (val isa AbstractVector ? val : Any[]))
        io = IOBuffer()
        print(io, "<select$attrs multiple size=\"8\">")
        for o in objects(related_model(fld))
            sel = string(o.id) in chosen ? " selected" : ""
            print(io, "<option value=\"", o.id, "\"", sel, ">", escape_html(string(o)), "</option>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif fld.kind in (:modelchoice, :modelmultichoice, :multichoice)
        multiple = fld.kind !== :modelchoice
        chosen = Set(string(x) for x in (multiple ? (val isa AbstractVector ? val : Any[]) : (val === nothing ? Any[] : Any[val])))
        io = IOBuffer()
        print(io, "<select$attrs", multiple ? " multiple" : "", ">")
        if fld.kind === :multichoice
            opts = Pair{Any,Any}[string(c.first) => c.second for c in field_choices(fld)]
        else
            sp = fld.related
            opts = Pair{Any,Any}[choice_key(sp, o) => instance_label(sp, o) for o in choice_queryset(sp)]
            !multiple && sp.empty_label !== nothing && print(io, "<option value=\"\">", escape_html(sp.empty_label), "</option>")
        end
        for (k, lbl) in opts
            print(io, "<option value=\"", escape_html(string(k)), "\"", string(k) in chosen ? " selected" : "", ">", escape_html(string(lbl)), "</option>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif fld.kind === :fk || fld.choices !== nothing || fld.kind === :filepath
        groups = fld.kind === :fk ? [(nothing, Pair{Any,Any}[o.id => string(o) for o in objects(related_model(fld))])] :
                 fld.kind === :filepath ? [(nothing, filepath_choices(fld))] : choice_groups(fld)
        io = IOBuffer()
        print(io, "<select$attrs>")
        (fld.blank || fld.kind === :fk) && print(io, "<option value=\"\">---------</option>")
        for (glabel, opts) in groups
            glabel === nothing || print(io, "<optgroup label=\"", escape_html(string(glabel)), "\">")
            for (k, lbl) in opts
                sel = val !== nothing && string(val) == string(k) ? " selected" : ""
                print(io, "<option value=\"", escape_html(string(k)), "\"", sel, ">", escape_html(string(lbl)), "</option>")
            end
            glabel === nothing || print(io, "</optgroup>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif (fld.kind in (:text, :json, :hstore) && widget_kind(fld.widget) === nothing) || widget_kind(fld.widget) === :textarea
        return "<textarea$attrs cols=\"40\" rows=\"10\">" * escape_html(display_string(val)) * "</textarea>"
    end
    t = input_type(fld)
    extra = fld.max_length !== nothing && t in ("text", "email", "url", "password") ? " maxlength=\"$(fld.max_length)\"" : ""
    t == "number" && fld.kind === :float && (extra *= " step=\"any\"")
    t == "time" && (extra *= " step=\"1\"")
    t == "number" && is_positive_kind(fld.kind) && (extra *= " min=\"0\"")                  # seconds too
    t == "number" && fld.kind === :decimal && (extra *= " step=\"" * decimal_step(fld.decimal_places) * "\"")
    v = (t == "password" || val === nothing) ? "" : " value=\"" * escape_html(display_string(val)) * "\""
    "<input type=\"$t\"$attrs$extra$v>"
end

label_tag(bf::BoundField) = "<label for=\"" * escape_html(html_id(bf.form, bf.field)) * "\">" *
                            escape_html(label(bf.field)) * ":</label>"

function field_row(bf::BoundField; tag = "p")
    fld = bf.field
    widget_kind(fld.widget) === :hidden && return widget_html(bf)
    errs = errors_html(get(bf.form.errors, fld.name, String[]))
    help = isempty(fld.help_text) ? "" : " <span class=\"helptext\">" * escape_html(fld.help_text) * "</span>"
    body = fld.kind === :bool ? widget_html(bf) * " " * label_tag(bf) : label_tag(bf) * " " * widget_html(bf)
    errs * "<$tag>" * body * help * "</$tag>"
end

"Render the whole form as `<p>` rows (returns a `SafeString`)."
as_p(f::Form) = SafeString(errors_html(non_field_errors(f)) * join([field_row(bf) for bf in f], "\n"))
as_div(f::Form) = SafeString(errors_html(non_field_errors(f)) * join([field_row(bf; tag = "div") for bf in f], "\n"))
function as_table(f::Form)
    rows = String[]
    for bf in f
        errs = errors_html(get(f.errors, bf.field.name, String[]))
        push!(rows, "<tr><th>" * label_tag(bf) * "</th><td>" * errs * widget_html(bf) * "</td></tr>")
    end
    SafeString(errors_html(non_field_errors(f)) * join(rows, "\n"))
end

__html__(f::Form) = get(settings, :FORM_RENDERER, nothing) isa TemplateFormRenderer ? render_form(f).s : as_p(f).s
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
    S === :as_table && return as_table(f)
    S === :errors && return f.errors
    S === :non_field_errors && return non_field_errors(f)
    S === :is_bound && return f.data !== nothing
    S === :is_multipart && return any(x -> x.kind in FILE_KINDS, f.fields)
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
    S === :label_tag && return SafeString(label_tag(bf))
    S === :errors_html && return SafeString(errors_html(get(bf.form.errors, bf.field.name, String[])))
    S === :errors && return get(bf.form.errors, bf.field.name, String[])
    S === :name && return html_name(bf.form, bf.field)
    S === :id_for_label && return html_id(bf.form, bf.field)
    S === :value && return display_value(bf)
    S === :help_text && return bf.field.help_text
    S === :widget && return SafeString(widget_html(bf))
    S === :row && return SafeString(field_row(bf))
    S === :as_field_group && return as_field_group(bf)
    S === :is_hidden && return widget_kind(bf.field.widget) === :hidden
    S === :field && return bf.field
    NOTFOUND
end
