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
    Widget(kind; attrs = Dict(), media = Media())

A widget value for a field's `widget`: a kind (`:textarea`, `:password`, ...) with extra HTML
attributes and media.
"""
struct Widget
    kind::Union{Nothing,Symbol}
    attrs::Dict{String,String}
    media::Media
end
Widget(kind = nothing; attrs = Dict{String,String}(), media = Media()) =
    Widget(kind === nothing ? nothing : Symbol(kind), Dict{String,String}(string(k) => string(v) for (k, v) in attrs), media)
widget_media(w::Widget) = w.media
widget_kind(w) = w isa Widget ? w.kind : w isa MultiWidget ? :multi : w
widget_attrs(w) = w isa Widget ? join([" $(escape_html(k))=\"$(escape_html(v))\"" for (k, v) in sort!(collect(w.attrs))]) : ""

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

"Renders a multi-value field's parts side by side (optionally with its own media)."
struct MultiWidget
    media::Media
end
MultiWidget(; media = Media()) = MultiWidget(media)
widget_media(w::MultiWidget) = w.media

struct MultiSpec
    fields::Vector{Field}
    compress::Function
    decompress::Function
end

"""
    MultiValueField(fields; compress, decompress, kw...)

One value from several inputs (named `name_0`, `name_1`, ...): each part is cleaned by its
field, then `compress(values)` makes the value (it may throw `ArgumentError` with a message).
`decompress(value)` splits an initial value into the parts' values.
"""
function MultiValueField(fields::AbstractVector; compress, decompress, widget = MultiWidget(), kw...)
    f = Field(:multi; kw...)
    f.related = MultiSpec(Field[deepcopy(x) for x in fields], compress, decompress)
    f.widget = widget
    f
end

parse_time(s) = (t = tryparse(Dates.Time, s, dateformat"HH:MM:SS"); t === nothing ? tryparse(Dates.Time, s, dateformat"HH:MM") : t)

"A date and a time input making one `DateTime` (aware in the current time zone with `USE_TZ`)."
SplitDateTimeField(; kw...) = MultiValueField([DateField(), Field(:char; max_length = 8, widget = Widget(:time))];
    compress = vs -> begin
        d, t = vs
        tm = parse_time(t)
        tm === nothing && throw(ArgumentError(gettext("Enter a valid time.")))
        dt = DateTime(d) + Dates.Hour(tm) + Dates.Minute(tm) + Dates.Second(tm)
        settings.USE_TZ ? make_aware(dt) : dt
    end,
    decompress = v -> v === nothing ? [nothing, nothing] :
        (dt = v isa TimeZones.ZonedDateTime ? make_naive(v) : DateTime(v); [Date(dt), Dates.format(dt, "HH:MM")]), kw...)

multi_raw(f::Form, fld::Field) = f.data === nothing ? nothing :
    [get(f.data, html_name(f, fld) * "_$(i - 1)", nothing) for i in eachindex(fld.related.fields)]

"Clean a multi-value field's parts and compress them: `(value, error_or_nothing)`."
function clean_multi(fld::Field, raws)
    spec = fld.related
    raws === nothing && (raws = fill(nothing, length(spec.fields)))
    all(r -> r === nothing || isempty(strip(string(r))), raws) && return nothing, nothing
    vals = Any[]
    for (sub, r) in zip(spec.fields, raws)
        v, err = to_julia(sub, r)
        err === nothing || return nothing, err
        (v === nothing || v == "") && return nothing, gettext("Enter a complete value.")
        errs = validate_field(sub, v)
        isempty(errs) || return nothing, first(errs)
        push!(vals, v)
    end
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
        t = widget_kind(sub.widget) === :time ? "time" : input_type(sub)
        v = vals === nothing || i > length(vals) || vals[i] === nothing ? "" :
            " value=\"" * escape_html(vals[i] isa Date ? string(vals[i]) : display_string(vals[i])) * "\""
        req = fld.blank ? "" : " required"
        push!(parts, "<input type=\"$t\" name=\"$(escape_html(name))\" id=\"$(escape_html(html_id(f, fld) * "_$(i - 1)"))\"$req$v$(widget_attrs(sub.widget))>")
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
