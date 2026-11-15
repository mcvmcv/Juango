# Components: reusable template pieces with parameters and slots (django-components, django-cotton) ----------
#
#     {# templates/components/card.html #}
#     {% props title size="md" %}
#     <div class="card card-{{ size }}"><h3>{{ title }}</h3>{% slot %}{% endslot %}
#       {% if slots.footer %}<footer>{% slot "footer" %}{% endslot %}</footer>{% endif %}</div>
#
#     {% component "card" title=post.title %}
#       {{ post.summary }}
#       {% fill "footer" %}<a href="{{ post.url }}">Read more</a>{% endfill %}
#     {% endcomponent %}
#     {% component "badge" text="new" / %}                      (no body)
#
# A component is the template `components/<name>.html`, or one declared with `component!` (with
# Julia code computing extra context). It sees only its parameters, its slots and a few globals
# (request, user, csrf_token, perms), not the page's variables; slot contents render with the
# page's variables, where they were written. `{% props %}` (or `component!(...; params)`) declares
# the parameters, with defaults: an unknown or missing one is an error naming it.

struct NoParamDefault end
const REQUIRED_PARAM = NoParamDefault()

struct ComponentDef
    name::String
    template::String
    params::Union{Nothing,Vector{Pair{String,Any}}}   # nothing: any parameters; else name => default (REQUIRED_PARAM)
    context::Any                                      # nothing, or (params::Dict{String,Any}, request) -> Dict of extra variables
end
const COMPONENTS = Dict{String,ComponentDef}()

"""
    component!(name; template = "components/<name>.html", params = nothing, context = nothing)

Declare a component used as `{% component "name" ... %}`. `params` lists its parameters: a
name alone is required, `name => default` optional (`params = [:title, :size => "md"]`); leave
it out to take them from the template's `{% props %}` (or accept any). `context(params,
request)` returns extra variables for the template, for the Julia part of a component.
"""
function component!(name::AbstractString; template = "components/$name.html", params = nothing, context = nothing)
    ps = params === nothing ? nothing :
         Pair{String,Any}[p isa Pair ? string(p.first) => p.second : string(p) => REQUIRED_PARAM for p in params]
    COMPONENTS[String(name)] = ComponentDef(String(name), String(template), ps, context)
    nothing
end

# --- {% props a b="x" %}: a component template's parameters ---
struct PropsNode <: Node
    params::Vector{Tuple{String,Union{Nothing,FilterExpr}}}
end
function tag_props(p::Parser, t::Token)
    ps = Tuple{String,Union{Nothing,FilterExpr}}[]
    for b in split_contents(t.contents)[2:end]
        m = match(r"^(\w+)(?:=(.+))?$"s, b)
        m === nothing && throw(TemplateSyntaxError("'props' takes names and name=default, got '$b'"))
        push!(ps, (String(m[1]), m[2] === nothing ? nothing : parse_filter_expr(m[2])))
    end
    PropsNode(ps)
end
render!(io::IO, ::PropsNode, ::Context) = nothing

# --- {% fill "name" %}...{% endfill %} inside {% component %} ---
struct FillNode <: Node
    name::String
    nodes::Vector{Node}
end
child_nodelists(n::FillNode) = (n.nodes,)
function tag_fill(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    length(bits) == 1 || throw(TemplateSyntaxError("'fill' takes one argument: the slot's name"))
    nodes, _ = parse_nodes(p, ["endfill"])
    FillNode(strip(bits[1], ['"', '\'']), nodes)
end
render!(io::IO, ::FillNode, ::Context) = nothing          # (rendered by the component's slot)

# --- {% slot ["name"] %}default{% endslot %} inside a component's template ---
struct SlotNode <: Node
    name::String
    nodes::Vector{Node}
end
child_nodelists(n::SlotNode) = (n.nodes,)
function tag_slot(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    length(bits) <= 1 || throw(TemplateSyntaxError("'slot' takes at most one argument: the slot's name"))
    nodes, _ = parse_nodes(p, ["endslot"])
    SlotNode(isempty(bits) ? "default" : strip(bits[1], ['"', '\'']), nodes)
end
struct ComponentSlots
    fills::Dict{String,Vector{Node}}
    caller::Vector{Dict{String,Any}}                 # the page's context stack, for fill contents
end
function render!(io::IO, n::SlotNode, ctx::Context)
    s = lookup(ctx, "__component_slots__")
    fill = s isa ComponentSlots ? get(s.fills, n.name, nothing) : nothing
    if fill === nothing
        render_nodes(io, n.nodes, ctx)                # the slot's default content
    else
        saved = ctx.stack
        ctx.stack = s.caller
        try
            render_nodes(io, fill, ctx)
        finally
            ctx.stack = saved
        end
    end
end

# --- {% component "name" a=b %}...{% endcomponent %} ---
struct ComponentNode <: Node
    name::FilterExpr
    kwargs::Vector{Tuple{String,FilterExpr}}
    fills::Dict{String,Vector{Node}}
end
child_nodelists(n::ComponentNode) = Tuple(values(n.fills))
function tag_component(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    isempty(bits) && throw(TemplateSyntaxError("'component' takes the component's name"))
    selfclosing = bits[end] == "/"
    selfclosing && pop!(bits)
    fills = Dict{String,Vector{Node}}()
    if !selfclosing
        body, _ = parse_nodes(p, ["endcomponent"])
        default = Node[]
        for n in body
            if n isa FillNode
                haskey(fills, n.name) && throw(TemplateSyntaxError("slot '$(n.name)' is filled twice"))
                fills[n.name] = n.nodes
            else
                push!(default, n)
            end
        end
        all(n -> n isa TextNode && isempty(strip(n.s)), default) || (fills["default"] = default)
    end
    ComponentNode(parse_filter_expr(bits[1]), parse_kwargs(bits[2:end]), fills)
end

"A component's definition: declared with `component!`, else from `components/<name>.html` and its `{% props %}`."
function component_def(name::String)
    d = get(COMPONENTS, name, nothing)
    d !== nothing && return d, get_template(d.template)
    t = try
        get_template("components/$name.html")
    catch e
        e isa TemplateDoesNotExist || rethrow()
        throw(TemplateSyntaxError("no component '$name' (component!(\"$name\") or templates/components/$name.html)" *
                                  did_you_mean(name, vcat(collect(keys(COMPONENTS)), component_template_names()))))
    end
    props = nodes_of_type(PropsNode, t.nodes)
    ps = isempty(props) ? nothing : Pair{String,Any}[k => (fe === nothing ? REQUIRED_PARAM : fe) for (k, fe) in first(props).params]
    ComponentDef(name, "components/$name.html", ps, nothing), t
end
component_template_names() = String[splitext(f)[1] for d in template_dirs() for f in (isdir(joinpath(d, "components")) ? readdir(joinpath(d, "components")) : String[])
                                    if endswith(f, ".html")]

function render!(io::IO, n::ComponentNode, ctx::Context)
    name = display_string(eval_fe(n.name, ctx))
    def, t = component_def(name)
    given = Dict{String,Any}(k => eval_fe(fe, ctx) for (k, fe) in n.kwargs)
    scope = Dict{String,Any}()
    for g in ("request", "user", "csrf_token", "perms")         # the few globals a component may need
        v = lookup(ctx, g)
        v === UNDEF || (scope[g] = v)
    end
    if def.params === nothing
        merge!(scope, given)
    else
        known = first.(def.params)
        for k in keys(given)
            k in known || throw(TemplateSyntaxError("component '$name' has no parameter '$k'" * did_you_mean(k, known)))
        end
        for (k, dflt) in def.params
            if haskey(given, k)
                scope[k] = given[k]
            elseif dflt === REQUIRED_PARAM
                throw(TemplateSyntaxError("component '$name' needs the parameter '$k'"))
            else
                scope[k] = dflt isa FilterExpr ? eval_fe(dflt, Context(copy(scope); request = ctx.request)) : dflt
            end
        end
    end
    def.context === nothing || merge!(scope, Dict{String,Any}(string(k) => v for (k, v) in def.context(copy(scope), ctx.request)))
    scope["slots"] = Dict{String,Any}(k => true for k in keys(n.fills))
    scope["__component_slots__"] = ComponentSlots(n.fills, ctx.stack)
    saved_stack, saved_rc = ctx.stack, ctx.render_ctx
    ctx.stack, ctx.render_ctx = [scope], Dict{Symbol,Any}()
    try
        run_nodes(io, t.nodes, ctx)
    catch e
        note_template_name!(e, t)
        rethrow()
    finally
        ctx.stack, ctx.render_ctx = saved_stack, saved_rc
    end
end

for (name, f) in ("component" => tag_component, "fill" => tag_fill, "slot" => tag_slot, "props" => tag_props)
    TAGS[name] = f
end
