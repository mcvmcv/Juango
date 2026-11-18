# Form media, multi-value fields and template renderers ---------------------------------------------------
#
#     form = ContactForm(; media = Media(css = Dict("all" => ["css/forms.css"]), js = ["js/forms.js"]))
#     {{ form.media }}                     <link ...> and <script ...> tags (widget media included)
#
#     when = SplitDateTimeField()          two inputs (date, time), one DateTime
#     MultiValueField([CharField(), CharField()]; compress = vs -> join(vs, " "), decompress = s -> split(s))
#
#     configure!(FORM_RENDERER = TemplateFormRenderer())     # {{ form }} through juango/forms/div.html

"""
    Media(; css = Dict("all" => [...]), js = [...])

CSS and JavaScript a form or widget needs. `+` combines them (keeping order, without
duplicates); `{{ form.media }}` renders the tags. Relative paths go through `{% static %}`.
"""
struct Media
    css::Vector{Pair{String,String}}     # (media type, path)
    js::Vector{String}
end
Media(; css = Dict{String,Vector{String}}(), js = String[]) =
    Media(Pair{String,String}[string(m) => string(p) for (m, ps) in pairs(css) for p in (ps isa AbstractString ? [ps] : ps)],
          String[string(p) for p in js])
Base.:+(a::Media, b::Media) = Media(unique(vcat(a.css, b.css)), unique(vcat(a.js, b.js)))
Base.isempty(m::Media) = isempty(m.css) && isempty(m.js)
media_url(p) = occursin(r"^(/|https?://)", p) ? p : static_url(p)
function render_media(m::Media)
    tags = String[]
    for (kind, p) in m.css
        push!(tags, "<link href=\"$(escape_html(media_url(p)))\" media=\"$(escape_html(kind))\" rel=\"stylesheet\">")
    end
    for p in m.js
        push!(tags, "<script src=\"$(escape_html(media_url(p)))\"></script>")
    end
    SafeString(join(tags, "\n"))
end
display_string(m::Media) = render_media(m).s
__html__(m::Media) = render_media(m).s
tattr(m::Media, ::Val{:css}) = render_media(Media(m.css, String[]))
tattr(m::Media, ::Val{:js}) = render_media(Media(Pair{String,String}[], m.js))

"The media of a widget value (define `widget_media` for widget types that need CSS or JavaScript)."
widget_media(::Any) = Media()

"""
    Widget(kind; attrs = Dict(), media = Media(), template_name = nothing, context = nothing, option_attrs = nothing)

A widget value for a field's `widget`: a kind (`:textarea`, `:password`, `:radio`, `:checkboxes` ...)
with extra HTML attributes and media.

- `option_attrs = (value, label) -> Dict(...)`: attributes for each option of a select, radio or
  checkbox list (`data-marker="12"`, so a script can show only some of them).
- `template_name = "widgets/tick_table.html"`: render the widget with a template of your own,
  wherever the field is rendered (`{{ field }}`, `as_field_group`, `as_p` ...). Its context has
  `widget` (`name`, `id`, `value`, `required`, `attrs`, and for choice fields `options`, each with
  `value`, `label`, `selected`, `id`, `index` and `attrs`), `field` (the bound field), and whatever
  `context = bf -> Dict(...)` adds.
"""
struct Widget
    kind::Union{Nothing,Symbol}
    attrs::Dict{String,String}
    media::Media
    template_name::Union{Nothing,String}
    context::Any                      # nothing, or bf -> Dict of extra template variables
    option_attrs::Any                 # nothing, or (value, label) -> Dict of attributes
end
Widget(kind = nothing; attrs = Dict{String,String}(), media = Media(), template_name = nothing, context = nothing, option_attrs = nothing) =
    Widget(kind === nothing ? nothing : Symbol(kind), Dict{String,String}(string(k) => string(v) for (k, v) in attrs), media,
           template_name === nothing ? nothing : String(template_name), context, option_attrs)
"Extra attributes of one option (from the widget's `option_attrs`), as HTML."
option_attrs_html(w, value, label) = w isa Widget && w.option_attrs !== nothing ?
    join([" $(escape_html(string(k)))=\"$(escape_html(string(v)))\"" for (k, v) in sort!(collect(w.option_attrs(value, label)); by = first)]) : ""
widget_media(w::Widget) = w.media
widget_kind(w) = w isa Widget ? w.kind : w isa MultiWidget ? :multi : w isa SelectDateWidget ? :selectdate : w
"""
Attributes a template adds to the widgets it renders (`{% render_field %}`, `add_class`, `attr`, ...),
as `name => value` pairs; a name starting with `+` appends to the value (`+class`).
"""
const TEMPLATE_WIDGET_ATTRS = Base.ScopedValues.ScopedValue{Vector{Pair{String,String}}}(Pair{String,String}[])
"Attributes the widget itself renders, never set from a template (they'd be duplicated)."
const FIXED_WIDGET_ATTRS = ("name", "id", "type")
"A widget's attributes with the template's additions."
function merged_widget_attrs(w)
    d = Dict{String,String}()
    w isa Widget && for (k, v) in w.attrs
        d[string(k)] = string(v)
    end
    for (k, v) in TEMPLATE_WIDGET_ATTRS[]
        append = startswith(k, "+")
        k = append ? k[2:end] : k
        k in FIXED_WIDGET_ATTRS && continue
        d[k] = append && !isempty(get(d, k, "")) ? d[k] * " " * v : v
    end
    d
end
widget_attrs(w) = join([isempty(v) && k in BOOLEAN_HTML_ATTRS ? " $(escape_html(k))" : " $(escape_html(k))=\"$(escape_html(v))\""
                        for (k, v) in sort!(collect(merged_widget_attrs(w))) if !(k in ("id", "type"))])     # (id and type are the input's own)
const BOOLEAN_HTML_ATTRS = ("autofocus", "disabled", "readonly", "required", "multiple", "hidden", "novalidate", "checked", "selected")

"The media of a form: its own, then each field's widget's."
function form_media(f::Form)
    m = f.media
    for fld in f.fields
        m = m + widget_media(fld.widget)
        fld.kind === :multi && (m = m + reduce(+, (widget_media(s.widget) for s in fld.related.fields); init = Media()))
    end
    m
end

# --- multi-value fields -----------------------------------------------------------------------------------

"Renders a multi-value field's parts side by side (optionally with its own media); `hidden = true` as hidden inputs."
struct MultiWidget
    media::Media
    hidden::Bool
end
MultiWidget(; media = Media(), hidden::Bool = false) = MultiWidget(media, hidden)
"`SplitDateTimeField(widget = SplitHiddenDateTimeWidget())`: its date and time as hidden inputs (Django's widget)."
SplitHiddenDateTimeWidget(; media = Media()) = MultiWidget(media, true)

"""
    SelectDateWidget(; years = this year and the next 9, months = nothing, empty_label = "---")

A `DateField`'s widget of three selects, day, month and year, as Django's (submitted as
`name_day`, `name_month` and `name_year`). `months` replaces the month names (12 labels).
"""
struct SelectDateWidget
    years::Vector{Int}
    months::Union{Nothing,Vector{String}}
    empty_label::String
    attrs::Dict{String,String}
end
SelectDateWidget(; years = Dates.year(Dates.today()):Dates.year(Dates.today()) + 9, months = nothing, empty_label = "---",
                 attrs = Dict{String,String}()) =
    SelectDateWidget(collect(Int, years), months === nothing ? nothing : String.(collect(months)), string(empty_label),
                     Dict{String,String}(string(k) => string(v) for (k, v) in attrs))
widget_media(w::MultiWidget) = w.media

struct MultiSpec
    fields::Vector{Field}
    compress::Function
    decompress::Function
    require_all::Bool        # every part must be given (else a required part left empty is "incomplete")
end

"""
    MultiValueField(fields; compress, decompress, require_all_fields = true, kw...)

One value from several inputs (named `name_0`, `name_1`, ...): each part is cleaned by its
field, then `compress(values)` makes the value (it may throw `ArgumentError` with a message).
`decompress(value)` splits an initial value into the parts' values.

As Django's: with `require_all_fields` (the default) a part left empty makes a required field's
"This field is required." (and is `nothing` when the field isn't required); without it, only the
parts whose fields are required must be given, and each one left empty reports its field's
`error_messages["incomplete"]` ("Enter a complete value.").
"""
function MultiValueField(fields::AbstractVector; compress, decompress, widget = MultiWidget(), require_all_fields::Bool = true, kw...)
    f = Field(:multi; kw...)
    f.related = MultiSpec(Field[deepcopy(x) for x in fields], compress, decompress, require_all_fields)
    f.widget = widget
    f
end


"A date and a time input making one `DateTime` (aware in the current time zone with `USE_TZ`)."
SplitDateTimeField(; kw...) = MultiValueField([DateField(error_messages = Dict("incomplete" => gettext("Enter a valid date."))),
                                                 Field(:char; max_length = 8, widget = Widget(:time),
                                                       validators = Any[t -> parse_time(t) !== nothing || gettext("Enter a valid time.")],
                                                       error_messages = Dict("incomplete" => gettext("Enter a valid time.")))];
    compress = vs -> begin
        d, t = vs
        tm = parse_time(t)
        tm === nothing && throw(ArgumentError(gettext("Enter a valid time.")))
        dt = DateTime(d) + Dates.Hour(tm) + Dates.Minute(tm) + Dates.Second(tm)
        settings.USE_TZ ? make_aware(dt) : dt
    end,
    decompress = v -> v === nothing ? [nothing, nothing] :
        (dt = v isa TimeZones.ZonedDateTime ? make_naive(v) : DateTime(v); [Date(dt), Dates.format(dt, "HH:MM")]),
    require_all_fields = false, kw...)

multi_raw(f::Form, fld::Field) = f.data === nothing ? nothing : multi_parts(f.data, html_name(f, fld), fld)
# name_0, name_1, ...: a multiple choice part's list, a multi-value part's own name_1_0, name_1_1, ...
multi_parts(d, name, fld::Field) =
    Any[(sub = fld.related.fields[i]; n = name * "_$(i - 1)";
         sub.kind === :multi ? multi_parts(d, n, sub) : sub.kind in MULTI_KINDS ? raw_list(d, n) : get(d, n, nothing))
        for i in eachindex(fld.related.fields)]

"""
Clean a multi-value field's parts and compress them: `(value, error_or_nothing)`. As Django's
`MultiValueField`, every part's error is reported (the error is then a vector of messages), and a
required part left empty is "incomplete" (its field's `error_messages["incomplete"]`).
"""
function clean_multi(fld::Field, raws)
    spec = fld.related
    raws === nothing && (raws = fill(nothing, length(spec.fields)))
    raws = Any[i <= length(raws) ? raws[i] : nothing for i in eachindex(spec.fields)]
    all(r -> r === nothing || isempty(strip(string(r))), raws) && return nothing, nothing
    vals, errs = Any[], String[]
    for (sub, r) in zip(spec.fields, raws)
        if r === nothing || (r isa AbstractString && isempty(strip(r))) || (r isa Union{AbstractVector,Tuple} && isempty(r))
            if spec.require_all
                fld.blank || return nothing, [field_message(fld, "required", gettext("This field is required."))]
                push!(vals, nothing)
            elseif !sub.blank
                m = field_message(sub, "incomplete", field_message(fld, "incomplete", gettext("Enter a complete value.")))
                m in errs || push!(errs, m)
            else
                push!(vals, nothing)
            end
            continue
        end
        v, err = to_julia(sub, r)
        if err !== nothing
            append!(errs, err isa AbstractVector ? err : [field_message(sub, "invalid", err)])
        else
            e = sub.kind in MULTI_KINDS ? validator_errors(sub, v) : validate_field(sub, v)
            isempty(e) ? push!(vals, v) : append!(errs, e)
        end
    end
    isempty(errs) || return nothing, (length(errs) == 1 ? errs[1] : unique(errs))
    try
        spec.compress(vals), nothing
    catch e
        e isa ArgumentError ? (nothing, e.msg) : rethrow()
    end
end

function multi_widget_html(bf::BoundField)
    f, fld = bf.form, bf.field
    spec = fld.related
    vals = f.data !== nothing ? multi_raw(f, fld) : spec.decompress(get(f.initial, fld.name, fld.default isa NoDefault ? nothing : fld.default))
    parts = String[]
    for (i, sub) in enumerate(spec.fields)
        name = html_name(f, fld) * "_$(i - 1)"
        t = fld.widget isa MultiWidget && fld.widget.hidden ? "hidden" : widget_kind(sub.widget) === :time ? "time" : input_type(sub)
        v = vals === nothing || i > length(vals) || vals[i] === nothing ? "" :
            " value=\"" * escape_html(vals[i] isa Date ? string(vals[i]) : display_string(vals[i])) * "\""
        req = fld.blank || !f.use_required_attribute ? "" : " required"
        id = html_id(f, fld)
        push!(parts, "<input type=\"$t\" name=\"$(escape_html(name))\"" * (isempty(id) ? "" : id_attr(id * "_$(i - 1)")) * "$req$v$(widget_attrs(sub.widget))>")
    end
    join(parts, " ")
end

# --- template form renderers -------------------------------------------------------------------------------

"""
    TemplateFormRenderer(; form_template = "juango/forms/div.html")

`FORM_RENDERER = TemplateFormRenderer()` renders `{{ form }}` with a template (context:
`form`, `fields`, `hidden_fields`, `errors`). Juango ships `juango/forms/div.html` and
`juango/forms/p.html`; use your own for your site's markup. Each field in the template has
`label_tag`, `errors_html`, `help_text` and renders its widget as `{{ field }}`.
"""
Base.@kwdef struct TemplateFormRenderer
    form_template::String = "juango/forms/div.html"
end

"Render a form with a template (default: the FORM_RENDERER's)."
function render_form(f::Form; template = nothing)
    r = get(settings, :FORM_RENDERER, nothing)
    tname = something(template, r isa TemplateFormRenderer ? r.form_template : "juango/forms/div.html")
    ctx = Dict{String,Any}("form" => f, "fields" => [bf for bf in f if widget_kind(bf.field.widget) !== :hidden],
                           "hidden_fields" => [bf for bf in f if widget_kind(bf.field.widget) === :hidden],
                           "errors" => non_field_errors(f))
    SafeString(render(get_template(tname), ctx))
end
