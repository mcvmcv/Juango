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
end

"""
    Form(fields::Vector{Pair{Symbol,Field}}; data=nothing, initial=Dict(), prefix="", clean=nothing, name="Form")

`clean`, if given, is called as `clean(form)` after field validation and may call
`add_error!(form, field_or_nothing, msg)` or modify `form.cleaned_data`.
"""
function Form(fields::Vector; data = nothing, initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
              name = "Form", model = nothing, instance = nothing)
    fs = Field[]
    for (n, f) in fields
        f = deepcopy(f)
        f.name = Symbol(n)
        push!(fs, f)
    end
    Form(string(name), fs, data, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)),
         Dict{Symbol,Vector{String}}(), Dict{Symbol,Any}(), model, instance, string(prefix), false, clean)
end

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
        function $(esc(name))(data = nothing; initial = Dict{Symbol,Any}(), prefix = "", clean = nothing)
            $F(Pair{Symbol,Any}[$(pairs_...)]; data = data, initial = initial, prefix = prefix,
               clean = clean, name = $(string(name)))
        end
    end
end

"Hook for cross-field validation of `@form`-defined forms (dispatch on `Val{:FormName}`)."
clean_form(f::Form, ::Val) = nothing

"""
    ModelForm(Model; data=nothing, instance=nothing, fields=nothing, exclude=[], initial=Dict(), widgets=Dict())

A form generated from a model's fields. `save!(form)` writes the cleaned data
into the instance (creating one if needed) and saves it.
"""
function ModelForm(::Type{T}; data = nothing, instance = nothing, fields = nothing, exclude = Symbol[],
                   initial = Dict{Symbol,Any}(), prefix = "", clean = nothing,
                   labels = Dict{Symbol,String}(), help_texts = Dict{Symbol,String}(),
                   widgets = Dict{Symbol,Symbol}()) where {T<:Model}
    meta = modelmeta(T)
    chosen = fields === nothing ? vcat([f.name for f in meta.fields if f.editable], [f.name for f in meta.m2m if f.editable]) :
             Symbol.(collect(fields))
    fs = Pair{Symbol,Any}[]
    for n in chosen
        n in exclude && continue
        i = findfirst(x -> x.name === n, meta.m2m)
        f = deepcopy(i === nothing ? getfield_meta(T, n) : meta.m2m[i])
        haskey(labels, n) && (f.verbose_name = labels[n])
        haskey(help_texts, n) && (f.help_text = help_texts[n])
        haskey(widgets, n) && (f.widget = widgets[n])
        push!(fs, n => f)
    end
    init = Dict{Symbol,Any}()
    if instance !== nothing
        for (n, f) in fs
            init[n] = f.kind === :fk ? getproperty(instance, attname(f)) :
                      f.kind === :m2m ? (instance.id === nothing ? Any[] : [o.id for o in getproperty(instance, n)]) :
                      getproperty(instance, n)
        end
    end
    merge!(init, Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs_of(initial)))
    Form(fs; data = data, initial = init, prefix = prefix, clean = clean, name = "$(nameof(T))Form",
         model = T, instance = instance)
end

Base.show(io::IO, f::Form) = print(io, "<", f.name, " bound=", f.data !== nothing, " fields=(",
                                   join(string.(getfield.(f.fields, :name)), ", "), ")>")

html_name(f::Form, fld::Field) = isempty(f.prefix) ? string(fld.name) : f.prefix * "-" * string(fld.name)
html_id(f::Form, fld::Field) = "id_" * html_name(f, fld)

function raw_value(f::Form, fld::Field)
    f.data === nothing && return nothing
    fld.kind === :m2m && return raw_list(f.data, html_name(f, fld))
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
    if k === :m2m
        ids = Int[]
        for r in (raw === nothing ? [] : raw)
            sr = strip(string(r))
            isempty(sr) && continue
            id = tryparse(Int, sr)
            id === nothing && return nothing, "Enter a list of values."
            push!(ids, id)
        end
        objs = isempty(ids) ? Any[] : collect(filter(objects(related_model(fld)); id__in = unique(ids)))
        length(objs) == length(unique(ids)) || return nothing, "Select a valid choice. One of the selected values is not one of the available choices."
        return objs, nothing
    end
    if k === :bool
        return (raw !== nothing && lowercase(string(raw)) in ("on", "true", "1", "yes")), nothing
    end
    s = raw === nothing ? "" : (fld.widget === :password ? string(raw) : strip(string(raw)))
    isempty(s) && return (k in STRING_KINDS && !fld.null ? "" : nothing), nothing
    if k in STRING_KINDS
        return String(s), nothing
    elseif k === :int
        v = tryparse(Int, s)
        return v, v === nothing ? "Enter a whole number." : nothing
    elseif k === :float
        v = tryparse(Float64, s)
        return v, v === nothing ? "Enter a number." : nothing
    elseif k === :datetime
        for fmt in (dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-ddTHH:MM", dateformat"yyyy-mm-dd HH:MM:SS",
                    dateformat"yyyy-mm-dd HH:MM", dateformat"yyyy-mm-ddTHH:MM:SS.s", dateformat"yyyy-mm-dd")
            v = tryparse(DateTime, s, fmt)
            v === nothing || return v, nothing
        end
        return nothing, "Enter a valid date/time."
    elseif k === :date
        v = tryparse(Date, s, dateformat"yyyy-mm-dd")
        return v, v === nothing ? "Enter a valid date." : nothing
    elseif k === :fk
        id = tryparse(Int, s)
        obj = id === nothing ? nothing : first(filter(objects(related_model(fld)); id = id))
        return obj, obj === nothing ? "Select a valid choice. That choice is not one of the available choices." : nothing
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
        v, err = to_julia(fld, raw_value(f, fld))
        if err !== nothing
            add_error!(f, fld.name, err)
            continue
        end
        errs = fld.kind === :m2m ? (isempty(v) && !fld.blank ? ["This field is required."] : String[]) :
               validate_field(fld, v isa Model ? v.id : v)
        if isempty(errs) && f.model !== nothing && fld.unique && v !== nothing && v != ""
            q = filter(objects(f.model), Q(attname(fld) => v))
            (f.instance !== nothing && f.instance.id !== nothing) && (q = filter(q, !Q(id = f.instance.id)))
            exists(q) && push!(errs, "$(uppercasefirst(modelmeta(f.model).verbose_name)) with this $(label(fld)) already exists.")
        end
        foreach(e -> add_error!(f, fld.name, e), errs)
        isempty(errs) && (f.cleaned_data[fld.name] = v)
    end
    f.clean === nothing || f.clean(f)
    clean_form(f, Val(Symbol(f.name)))
    f.validated = true
    isempty(f.errors)
end

"Attach an error to a field (or to the whole form with `field=nothing`)."
function add_error!(f::Form, field, msg)
    k = field === nothing ? :__all__ : Symbol(field)
    push!(get!(f.errors, k, String[]), string(msg))
    delete!(f.cleaned_data, k)
    nothing
end

cleaned_data(f::Form) = f.cleaned_data
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
    v isa Model && return v.id
    v isa DateTime && return Dates.format(v, "yyyy-mm-ddTHH:MM")
    v
end

errors_html(errs) = isempty(errs) ? "" :
    "<ul class=\"errorlist\">" * join(["<li>" * escape_html(e) * "</li>" for e in errs]) * "</ul>"

input_type(fld::Field) = fld.widget === :password ? "password" : fld.widget === :hidden ? "hidden" :
    fld.kind === :email ? "email" : fld.kind === :url ? "url" : fld.kind in (:int, :float) ? "number" :
    fld.kind === :datetime ? "datetime-local" : fld.kind === :date ? "date" : "text"

function widget_html(bf::BoundField)
    f, fld = bf.form, bf.field
    name, id = escape_html(html_name(f, fld)), escape_html(html_id(f, fld))
    val = display_value(bf)
    req = !fld.blank && fld.kind !== :bool ? " required" : ""
    attrs = " name=\"$name\" id=\"$id\"$req"
    haskey(f.errors, fld.name) && (attrs *= " aria-invalid=\"true\"")
    if fld.kind === :bool
        checked = f.data !== nothing ? (val !== nothing && lowercase(string(val)) in ("on", "true", "1", "yes")) : truthy(val)
        return "<input type=\"checkbox\"$attrs$(checked ? " checked" : "")>"
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
    elseif fld.kind === :fk || fld.choices !== nothing
        opts = fld.kind === :fk ? Pair{Any,String}[o.id => string(o) for o in objects(related_model(fld))] : fld.choices
        io = IOBuffer()
        print(io, "<select$attrs>")
        (fld.blank || fld.kind === :fk) && print(io, "<option value=\"\">---------</option>")
        for (k, lbl) in opts
            sel = val !== nothing && string(val) == string(k) ? " selected" : ""
            print(io, "<option value=\"", escape_html(string(k)), "\"", sel, ">", escape_html(lbl), "</option>")
        end
        print(io, "</select>")
        return String(take!(io))
    elseif fld.kind === :text && fld.widget === nothing || fld.widget === :textarea
        return "<textarea$attrs cols=\"40\" rows=\"10\">" * escape_html(display_string(val)) * "</textarea>"
    end
    t = input_type(fld)
    extra = fld.max_length !== nothing && t in ("text", "email", "url", "password") ? " maxlength=\"$(fld.max_length)\"" : ""
    t == "number" && fld.kind === :float && (extra *= " step=\"any\"")
    v = (t == "password" || val === nothing) ? "" : " value=\"" * escape_html(display_string(val)) * "\""
    "<input type=\"$t\"$attrs$extra$v>"
end

label_tag(bf::BoundField) = "<label for=\"" * escape_html(html_id(bf.form, bf.field)) * "\">" *
                            escape_html(label(bf.field)) * ":</label>"

function field_row(bf::BoundField; tag = "p")
    fld = bf.field
    fld.widget === :hidden && return widget_html(bf)
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

__html__(f::Form) = as_p(f).s
__html__(bf::BoundField) = widget_html(bf)
Base.show(io::IO, bf::BoundField) = print(io, "<BoundField ", bf.field.name, ">")

function tattr(f::Form, ::Val{S}) where {S}
    S === :as_p && return as_p(f)
    S === :as_div && return as_div(f)
    S === :as_table && return as_table(f)
    S === :errors && return f.errors
    S === :non_field_errors && return non_field_errors(f)
    S === :is_bound && return f.data !== nothing
    S === :cleaned_data && return f.cleaned_data
    S === :instance && return f.instance
    S === :hidden_fields && return [bf for bf in f if bf.field.widget === :hidden]
    S === :visible_fields && return [bf for bf in f if bf.field.widget !== :hidden]
    i = findfirst(x -> x.name === S, f.fields)
    i === nothing ? NOTFOUND : BoundField(f, f.fields[i])
end

function tattr(bf::BoundField, ::Val{S}) where {S}
    S === :label && return label(bf.field)
    S === :label_tag && return SafeString(label_tag(bf))
    S === :errors && return get(bf.form.errors, bf.field.name, String[])
    S === :name && return html_name(bf.form, bf.field)
    S === :id_for_label && return html_id(bf.form, bf.field)
    S === :value && return display_value(bf)
    S === :help_text && return bf.field.help_text
    S === :widget && return SafeString(widget_html(bf))
    S === :row && return SafeString(field_row(bf))
    S === :is_hidden && return bf.field.widget === :hidden
    S === :field && return bf.field
    NOTFOUND
end
