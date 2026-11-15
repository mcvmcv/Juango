# Form templates and layouts (django-crispy-forms) ---------------------------------------------------------
#
#     {% form form %}                                     every field through the pack's field template
#     {% form form pack="bootstrap5" layout=contact_layout %}
#     {% field form.email placeholder="you@example.com" %}  one field: label, widget, help text, errors
#
#     configure!(FORM_TEMPLATE_PACK = "bootstrap5")         "plain" (default), "bootstrap5", "tailwind"
#
#     using Juango.Layout
#     contact_layout = FormLayout(Fieldset("Contact", :name, :email),
#                                 Row(Column(:city), Column(:postcode; class = "col-3")),
#                                 FormField(:notes; rows = "3"), Submit("Send"))
#
# A pack is `juango/forms/packs/<name>/field.html` and `form.html`: a project can override either, or
# add a pack of its own, in its templates directory. The field template renders the widget with
# `{% render_field %}`, so classes from the template (and `add_class` & co.) combine with the pack's.

"CSS classes each pack gives the parts of a form (a pack of your own gets none unless you add it here)."
const PACK_CLASSES = Dict{String,Dict{String,String}}(
    "plain" => Dict("errors" => "errorlist nonfield", "row" => "form-row", "column" => "form-column", "fieldset" => "",
                    "submit" => "button"),
    "bootstrap5" => Dict("errors" => "alert alert-danger", "row" => "row", "column" => "col", "fieldset" => "mb-3",
                         "submit" => "btn btn-primary"),
    "tailwind" => Dict("errors" => "mb-4 rounded border border-red-300 bg-red-50 p-3 text-sm text-red-700",
                       "row" => "flex gap-4", "column" => "flex-1", "fieldset" => "mb-4",
                       "submit" => "rounded-md bg-blue-600 px-4 py-2 text-sm font-medium text-white"))
pack_classes(pack) = get(PACK_CLASSES, string(pack), Dict{String,String}())
default_pack() = string(something(get(SETTINGS, :FORM_TEMPLATE_PACK, "plain"), "plain"))

"""
    field_html(field; pack = FORM_TEMPLATE_PACK) -> SafeString

One field (a bound field, or one with template attributes) through the pack's field template:
its label, widget (with the pack's classes), help text and errors.
"""
function field_html(@nospecialize(x); pack = default_pack())
    bound_field(x) === nothing && throw(ArgumentError("field_html needs a form field, got $(typeof(x))"))
    SafeString(render(get_template("juango/forms/packs/$(pack)/field.html"), Dict{String,Any}("field" => x)))
end

"""
    form_html(form; pack = FORM_TEMPLATE_PACK, layout = nothing) -> SafeString

A form through a template pack: its non-field errors, every visible field through the pack's field
template (or the fields `layout` places, arranged as it says), and its hidden fields.
"""
function form_html(f::Form; pack = default_pack(), layout = nothing)
    visible = [bf for bf in f if widget_kind(bf.field.widget) !== :hidden]
    hidden = [bf for bf in f if widget_kind(bf.field.widget) === :hidden]
    body = layout === nothing ? join(field_html(bf; pack = pack).s for bf in visible) : layout_html(layout, f, string(pack))
    SafeString(render(get_template("juango/forms/packs/$(pack)/form.html"),
                      Dict{String,Any}("form" => f, "errors" => non_field_errors(f), "body" => SafeString(body),
                                       "hidden_fields" => hidden, "classes" => pack_classes(pack))))
end
layout_html(layout, f, pack) = throw(ArgumentError("a form layout is a Juango.Layout.FormLayout, not $(typeof(layout))"))

# --- {% form form [pack="..."] [layout=...] %} and {% field form.x [pack="..."] [name="value" ...] %} ---
struct FormTagNode <: Node
    form::FilterExpr
    kwargs::Vector{Tuple{String,FilterExpr}}
end
function tag_form(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    isempty(bits) && throw(TemplateSyntaxError("'form' takes a form, then pack=\"...\" and layout=..."))
    kw = parse_kwargs(bits[2:end])
    for (k, _) in kw
        k in ("pack", "layout") || throw(TemplateSyntaxError("'form' takes pack= and layout=, not '$k'"))
    end
    FormTagNode(parse_filter_expr(bits[1]), kw)
end
function render!(io::IO, n::FormTagNode, ctx::Context)
    f = eval_fe(n.form, ctx)
    f isa Form || throw(TemplateSyntaxError("'form' needs a form, got $(typeof(f))"))
    kw = Dict(k => eval_fe(v, ctx) for (k, v) in n.kwargs)
    write(io, form_html(f; pack = haskey(kw, "pack") ? display_string(kw["pack"]) : default_pack(), layout = get(kw, "layout", nothing)).s)
end

struct FieldTagNode <: Node
    field::FilterExpr
    pack::Union{Nothing,FilterExpr}
    attrs::Vector{Tuple{String,Bool,FilterExpr}}
end
function tag_field(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    isempty(bits) && throw(TemplateSyntaxError("'field' takes a form field, then name=\"value\" attributes"))
    pack, attrs = nothing, Tuple{String,Bool,FilterExpr}[]
    for b in bits[2:end]
        m = match(r"^([A-Za-z_:@][\w\-:.@]*)(\+?=)(.+)$"s, b)
        m === nothing && throw(TemplateSyntaxError("field: expected name=\"value\" or name+=\"value\", got '$b'"))
        m[1] == "pack" && m[2] == "=" ? (pack = parse_filter_expr(m[3])) : push!(attrs, (String(m[1]), m[2] == "+=", parse_filter_expr(m[3])))
    end
    FieldTagNode(parse_filter_expr(bits[1]), pack, attrs)
end
function render!(io::IO, n::FieldTagNode, ctx::Context)
    f = eval_fe(n.field, ctx)
    bound_field(f) === nothing && throw(TemplateSyntaxError("'field' needs a form field, got $(typeof(f))"))
    ps = Pair{String,String}[(append ? "+" : "") * k => display_string(eval_fe(v, ctx)) for (k, append, v) in n.attrs]
    pack = n.pack === nothing ? default_pack() : display_string(eval_fe(n.pack, ctx))
    write(io, field_html(isempty(ps) ? f : tweak(f, ps); pack = pack).s)
end
TAGS["form"] = tag_form
TAGS["field"] = tag_field

"""
Form layouts, as django-crispy-forms' `Layout`: `using Juango.Layout` (opt-in, since the names are
short). Field names are Symbols; `FormField(:name; class = "x", placeholder = "...")` adds widget
attributes (`add_class = "x"` appends to the pack's class).
"""
module Layout
import ..Juango
import ..Juango: Form, BoundField, field_html, escape_html, tweak, pack_classes
export FormLayout, Fieldset, Row, Column, Div, RawHTML, Submit, FormField

"A form's layout: `{% form form layout=... %}` or `form_html(form; layout)` renders only the fields it places."
struct FormLayout
    items::Vector{Any}
    FormLayout(items...) = new(collect(Any, items))       # (inner: so one item isn't taken as the vector itself)
end
"A `<fieldset>` with a legend."
struct Fieldset
    legend::String
    items::Vector{Any}
    Fieldset(legend, items...) = new(string(legend), collect(Any, items))
end
"Items side by side: a row of columns (a field placed directly in a row gets a column of its own)."
struct Row
    items::Vector{Any}
    Row(items...) = new(collect(Any, items))
end
"A column of a row; `class` replaces the pack's column class (`\"col-4\"`)."
struct Column
    items::Vector{Any}
    class::Union{Nothing,String}
end
Column(items...; class = nothing) = Column(collect(Any, items), class === nothing ? nothing : string(class))
"A `<div>` around items, with a class."
struct Div
    items::Vector{Any}
    class::String
end
Div(items...; class = "") = Div(collect(Any, items), string(class))
"HTML as it is (trusted: yours, not user input)."
struct RawHTML
    html::String
end
"A submit button."
struct Submit
    label::String
    name::String
    class::Union{Nothing,String}
end
Submit(label = "Submit"; name = "submit", class = nothing) = Submit(string(label), string(name), class === nothing ? nothing : string(class))
"A field with widget attributes: `FormField(:notes; rows = \"3\", add_class = \"wide\")`."
struct FormField
    name::Symbol
    attrs::Vector{Pair{String,String}}
end
FormField(name; kw...) = FormField(Symbol(name), Pair{String,String}[(k === :add_class ? "+class" : replace(string(k), '_' => '-')) => string(v) for (k, v) in kw])

render_item(io, x::Symbol, f, pack, cls) = print(io, field_html(f[x]; pack = pack).s)
render_item(io, x::AbstractString, f, pack, cls) = render_item(io, Symbol(x), f, pack, cls)
render_item(io, x::FormField, f, pack, cls) = print(io, field_html(tweak(f[x.name], x.attrs); pack = pack).s)
render_item(io, x::RawHTML, f, pack, cls) = print(io, x.html)
render_items(io, items, f, pack, cls) = foreach(i -> render_item(io, i, f, pack, cls), items)
function render_item(io, x::Fieldset, f, pack, cls)
    c = get(cls, "fieldset", "")
    print(io, "<fieldset", isempty(c) ? "" : " class=\"$(escape_html(c))\"", "><legend>", escape_html(x.legend), "</legend>")
    render_items(io, x.items, f, pack, cls)
    print(io, "</fieldset>")
end
function render_item(io, x::Row, f, pack, cls)
    print(io, "<div class=\"", escape_html(get(cls, "row", "")), "\">")
    for i in x.items
        i isa Column ? render_item(io, i, f, pack, cls) : render_item(io, Column([i], nothing), f, pack, cls)
    end
    print(io, "</div>")
end
function render_item(io, x::Column, f, pack, cls)
    print(io, "<div class=\"", escape_html(something(x.class, get(cls, "column", ""))), "\">")
    render_items(io, x.items, f, pack, cls)
    print(io, "</div>")
end
function render_item(io, x::Div, f, pack, cls)
    print(io, "<div", isempty(x.class) ? "" : " class=\"$(escape_html(x.class))\"", ">")
    render_items(io, x.items, f, pack, cls)
    print(io, "</div>")
end
render_item(io, x::Submit, f, pack, cls) =
    print(io, "<button type=\"submit\" name=\"", escape_html(x.name), "\" class=\"", escape_html(something(x.class, get(cls, "submit", ""))), "\">",
          escape_html(x.label), "</button>")
render_item(io, x, f, pack, cls) = throw(ArgumentError("not a layout item: $(repr(x))"))

function Juango.layout_html(l::FormLayout, f::Form, pack::String)
    io = IOBuffer()
    render_items(io, l.items, f, pack, pack_classes(pack))
    String(take!(io))
end
end # module Layout
