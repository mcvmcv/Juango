# Field attributes from the template (django-widget-tweaks) ---------------------------------------------
#
#     {% render_field form.title class="input" placeholder="Title" %}
#     {% render_field form.email class+="wide" autofocus="" %}       (+= appends to the field's own class)
#     {{ form.title|add_class:"input"|attr:"placeholder:Title" }}
#     {{ form.title|add_error_class:"is-invalid" }}                   (only when the field has errors)
#
# Styling belongs in the template, not in the form class: Django makes you set widget attributes in
# Python, which is why django-widget-tweaks exists. These work on every widget (inputs, selects,
# textareas, checkboxes, radio lists, template widgets). `name`, `id` and `type` stay the widget's.

"A bound field with attributes added by the template; it renders as its widget, and passes everything else to the field."
struct TweakedField
    bf::BoundField
    attrs::Vector{Pair{String,String}}
end
tweak(x::BoundField, ps) = TweakedField(x, ps)
tweak(x::TweakedField, ps) = TweakedField(x.bf, vcat(x.attrs, ps))
tweak(x, ps) = x                                         # (not a form field: left alone)
bound_field(x::BoundField) = x
bound_field(x::TweakedField) = x.bf
bound_field(x) = nothing

"Render `f()` with the tweaked field's attributes added to its widgets."
with_tweaks(f, t::TweakedField) = Base.ScopedValues.with(f, TEMPLATE_WIDGET_ATTRS => vcat(TEMPLATE_WIDGET_ATTRS[], t.attrs))
__html__(t::TweakedField) = with_tweaks(() -> widget_html(t.bf), t)
function tattr(t::TweakedField, v::Val{S}) where {S}
    S in (:widget, :row, :as_field_group) && return with_tweaks(() -> tattr(t.bf, v), t)
    tattr(t.bf, v)
end
Base.show(io::IO, t::TweakedField) = print(io, __html__(t))

"`\"name:value\"` (or `\"name\"`, for an attribute without a value) as a pair."
function attr_pair(arg, append::Bool = false)
    s = arg === nothing ? "" : display_string(arg)
    i = findfirst(':', s)
    k, v = i === nothing ? (s, "") : (s[1:prevind(s, i)], s[nextind(s, i):end])
    isempty(strip(k)) && throw(TemplateSyntaxError("the attr filters take \"name:value\", got $(repr(s))"))
    (append ? "+" : "") * strip(k) => v
end
has_errors(x) = (bf = bound_field(x); bf !== nothing && !isempty(get(bf.form.errors, bf.field.name, String[])))
is_required(x) = (bf = bound_field(x); bf !== nothing && !bf.field.blank && bf.field.kind !== :bool)

let F = register_filter!
    F("add_class", (v, a) -> tweak(v, ["+class" => display_string(a)]))
    F("attr", (v, a) -> tweak(v, [attr_pair(a)]))
    F("set_attr", (v, a) -> tweak(v, [attr_pair(a)]))
    F("append_attr", (v, a) -> tweak(v, [attr_pair(a, true)]))
    F("set_data", (v, a) -> (p = attr_pair(a); tweak(v, ["data-" * p.first => p.second])))
    F("add_error_class", (v, a) -> has_errors(v) ? tweak(v, ["+class" => display_string(a)]) : v)
    F("add_error_attr", (v, a) -> has_errors(v) ? tweak(v, [attr_pair(a)]) : v)
    F("add_required_class", (v, a) -> is_required(v) ? tweak(v, ["+class" => display_string(a)]) : v)
    F("field_type", (v, _) -> (bf = bound_field(v); bf === nothing ? "" : lowercase(string(bf.field.kind))))
    F("widget_type", (v, _) -> (bf = bound_field(v); bf === nothing ? "" : widget_type(bf.field)))
end

# --- {% render_field field name="value" name+="value" ... %} ---
struct RenderFieldNode <: Node
    field::FilterExpr
    attrs::Vector{Tuple{String,Bool,FilterExpr}}        # (name, append, value)
end
function tag_render_field(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    isempty(bits) && throw(TemplateSyntaxError("'render_field' takes a form field, then name=\"value\" attributes"))
    attrs = Tuple{String,Bool,FilterExpr}[]
    for b in bits[2:end]
        m = match(r"^([A-Za-z_:@][\w\-:.@]*)(\+?=)(.+)$"s, b)
        m === nothing && throw(TemplateSyntaxError("render_field: expected name=\"value\" or name+=\"value\", got '$b'"))
        push!(attrs, (String(m[1]), m[2] == "+=", parse_filter_expr(m[3])))
    end
    RenderFieldNode(parse_filter_expr(bits[1]), attrs)
end
function render!(io::IO, n::RenderFieldNode, ctx::Context)
    f = eval_fe(n.field, ctx)
    bound_field(f) === nothing && throw(TemplateSyntaxError("render_field needs a form field, got $(typeof(f))"))
    ps = Pair{String,String}[(append ? "+" : "") * k => display_string(eval_fe(v, ctx)) for (k, append, v) in n.attrs]
    write(io, __html__(tweak(f, ps)))
end
TAGS["render_field"] = tag_render_field
