# Template engine -------------------------------------------------------------------------
#
# A Django-compatible template language:
#   {{ var.attr|filter:"arg" }}   {% if %}{% elif %}{% else %}{% endif %}
#   {% for x in xs %}{% empty %}{% endfor %}   {% extends %} {% block %} {% include %}
#   {% url %} {% csrf_token %} {% with %} {% static %} {% cycle %} {% firstof %} {% now %}
#   {% comment %} {% autoescape %} {% spaceless %} {% verbatim %} {# comments #}

"A template that can't be parsed. `template`, `origin` (its file), `line` and `source` say where."
mutable struct TemplateSyntaxError <: Exception
    msg::String
    template::Union{Nothing,String}
    origin::Union{Nothing,String}
    line::Int
    source::Union{Nothing,String}
end
TemplateSyntaxError(msg::AbstractString) = TemplateSyntaxError(String(msg), nothing, nothing, 0, nothing)
Base.showerror(io::IO, e::TemplateSyntaxError) = print(io, "TemplateSyntaxError: ", e.msg)
struct TemplateDoesNotExist <: Exception
    name::String
    tried::Vector{String}
end
Base.showerror(io::IO, e::TemplateDoesNotExist) =
    print(io, "TemplateDoesNotExist: ", e.name, isempty(e.tried) ? "" : " (tried: " * join(e.tried, ", ") * ")")

"Sentinel for a variable that could not be resolved."
struct Undefined end
const UNDEF = Undefined()
struct NotFound end
const NOTFOUND = NotFound()

"""
    tattr(obj, ::Val{name})

Extension point for computed attributes visible in templates (and, for models,
through `obj.name`). Return `Juango.NOTFOUND` when not applicable.

    Juango.tattr(p::Post, ::Val{:summary}) = first(p.body, 100)
"""
tattr(obj, ::Val) = NOTFOUND

# --- tokens ---------------------------------------------------------------------------

struct Token
    kind::Symbol      # :text, :var, :block, :comment
    contents::String
    line::Int
end

const TAG_RE = r"{%.*?%}|{{.*?}}|{#.*?#}"s

function tokenize(src::AbstractString)
    tokens = Token[]
    pos = 1
    line = 1
    verbatim = nothing
    for m in eachmatch(TAG_RE, src)
        if m.offset > pos
            t = src[pos:prevind(src, m.offset)]
            push!(tokens, Token(:text, t, line))
            line += count('\n', t)
        end
        tag = m.match
        inner = strip(tag[3:end-2])
        if verbatim !== nothing
            if startswith(tag, "{%") && inner == verbatim
                verbatim = nothing
                push!(tokens, Token(:block, inner, line))
            else
                push!(tokens, Token(:text, tag, line))
            end
        elseif startswith(tag, "{{")
            push!(tokens, Token(:var, inner, line))
        elseif startswith(tag, "{%")
            push!(tokens, Token(:block, inner, line))
            if startswith(inner, "verbatim")
                verbatim = "end" * inner
            end
        else
            push!(tokens, Token(:comment, inner, line))
        end
        line += count('\n', tag)
        pos = m.offset + ncodeunits(tag)
    end
    pos <= ncodeunits(src) && push!(tokens, Token(:text, src[pos:end], line))
    tokens
end

"Split tag contents on whitespace, keeping quoted strings intact."
function split_contents(s::AbstractString)
    parts = String[]
    buf = IOBuffer()
    q = nothing
    for c in s
        if q !== nothing
            print(buf, c)
            c == q && (q = nothing)
        elseif c == '"' || c == '\''
            q = c
            print(buf, c)
        elseif isspace(c)
            buf.size > 0 && push!(parts, String(take!(buf)))
        else
            print(buf, c)
        end
    end
    buf.size > 0 && push!(parts, String(take!(buf)))
    parts
end

# --- filters registry -----------------------------------------------------------------

struct TemplateFilter
    fn::Function
    is_safe::Bool
    needs_autoescape::Bool
end

const FILTERS = Dict{String,TemplateFilter}()
"Filters that `{% load %}` made available in the template being parsed (library filters)."
const LOADED_FILTERS = Base.ScopedValues.ScopedValue(Dict{String,TemplateFilter}())

"""
    register_filter!(name, f; is_safe=false, needs_autoescape=false)

Register a template filter. `f(value, arg)` receives `arg === nothing` when no
argument was given. With `needs_autoescape=true`, `f(value, arg, autoescape)`.

    register_filter!("shout", (v, _) -> uppercase(string(v)) * "!")
"""
function register_filter!(name, f; is_safe = false, needs_autoescape = false)
    FILTERS[string(name)] = TemplateFilter(f, is_safe, needs_autoescape)
    clear_template_cache!()          # parsed templates hold the filters they use
    nothing
end

# --- expressions ----------------------------------------------------------------------

struct Literal
    value::Any
end
"""
A variable path `a.b.0`. The attribute steps are prepared when the template is parsed: their
Symbol, a `Val` instance for `tattr`, and the index for numeric steps (-1 otherwise).
"""
struct Variable
    parts::Vector{String}
    syms::Vector{Symbol}
    vals::Vector{Any}
    idx::Vector{Int}
end
function Variable(parts::AbstractVector{<:AbstractString})
    ps = String[String(p) for p in parts]
    syms = Symbol[Symbol(p) for p in ps]
    Variable(ps, syms, Any[Val(s) for s in syms], Int[all(isdigit, p) && !isempty(p) ? parse(Int, p) + 1 : -1 for p in ps])
end
struct FilterExpr
    base::Union{Literal,Variable}
    filters::Vector{Tuple{TemplateFilter,Any}}   # (filter, nothing | Literal | Variable)
end

function parse_operand(s::AbstractString)
    s = strip(s)
    isempty(s) && throw(TemplateSyntaxError("empty variable"))
    if length(s) >= 2 && (s[1] == '"' || s[1] == '\'') && s[end] == s[1]
        return Literal(SafeString(unescape_string(s[2:prevind(s, end)])))
    elseif s in ("True", "true")
        return Literal(true)
    elseif s in ("False", "false")
        return Literal(false)
    elseif s in ("None", "nothing")
        return Literal(nothing)
    end
    n = tryparse(Int, s)
    n !== nothing && return Literal(n)
    f = tryparse(Float64, s)
    (f !== nothing && occursin(r"^-?[0-9.]+(e-?[0-9]+)?$", s)) && return Literal(f)
    occursin(r"^[\w.]+$", s) || throw(TemplateSyntaxError("could not parse '$s'"))
    Variable(split(s, '.'))
end

"Read an operand starting at index `i` of `s`; returns (operand_string, next_index)."
function read_operand(s::AbstractString, i::Int)
    n = ncodeunits(s)
    start = i
    if i <= n && (s[i] == '"' || s[i] == '\'')
        q = s[i]
        i = nextind(s, i)
        while i <= n && s[i] != q
            s[i] == '\\' && (i = nextind(s, i))
            i = nextind(s, i)
        end
        i <= n || throw(TemplateSyntaxError("unterminated string in '$s'"))
        i = nextind(s, i)
    else
        while i <= n && !(s[i] in ('|', ':') || isspace(s[i]))
            i = nextind(s, i)
        end
    end
    s[start:prevind(s, i)], i
end

function parse_filter_expr(s::AbstractString)
    s = strip(s)
    tok, i = read_operand(s, 1)
    base = parse_operand(tok)
    filters = Tuple{TemplateFilter,Any}[]
    n = ncodeunits(s)
    while true
        while i <= n && isspace(s[i])
            i = nextind(s, i)
        end
        i > n && break
        s[i] == '|' || throw(TemplateSyntaxError("could not parse the remainder: '$(s[i:end])' from '$s'"))
        i = nextind(s, i)
        j = i
        while j <= n && (isletter(s[j]) || isdigit(s[j]) || s[j] == '_')
            j = nextind(s, j)
        end
        name = s[i:prevind(s, j)]
        isempty(name) && throw(TemplateSyntaxError("missing filter name in '$s'"))
        filt = get(LOADED_FILTERS[], name, nothing)
        filt === nothing && (filt = get(FILTERS, name, nothing))
        filt === nothing && throw(TemplateSyntaxError("invalid filter: '$name'" * load_hint(name)))
        i = j
        arg = nothing
        if i <= n && s[i] == ':'
            tok, i = read_operand(s, nextind(s, i))
            arg = parse_operand(tok)
        end
        push!(filters, (filt, arg))
    end
    FilterExpr(base, filters)
end

# --- context --------------------------------------------------------------------------

mutable struct Context
    stack::Vector{Dict{String,Any}}
    autoescape::Bool
    render_ctx::Dict{Symbol,Any}
    request::Any
end
Context(d::Dict{String,Any} = Dict{String,Any}(); request = nothing) =
    Context([d], true, Dict{Symbol,Any}(), request)

"""
A context value computed when a template first uses it (and then kept), e.g. the auth
context processor's `user`, so pages that don't show it don't load it.
"""
struct LazyValue
    f::Any
end

function lookup(ctx::Context, name::AbstractString)
    for d in Iterators.reverse(ctx.stack)
        v = get(d, name, NOTFOUND)
        v === NOTFOUND && continue
        v isa LazyValue && (v = d[name] = v.f())
        return v
    end
    UNDEF
end
Base.setindex!(ctx::Context, v, k::AbstractString) = (ctx.stack[end][k] = v)
Base.getindex(ctx::Context, k::AbstractString) = lookup(ctx, k)
push_scope!(ctx::Context, d = Dict{String,Any}()) = push!(ctx.stack, d)
pop_scope!(ctx::Context) = pop!(ctx.stack)
function with_scope(f, ctx::Context, d = Dict{String,Any}())
    push_scope!(ctx, d)
    try
        f()
    finally
        pop_scope!(ctx)
    end
end

"Attribute/key/index lookup used by `{{ a.b.c }}`."
function getattr(obj, part::AbstractString)
    sym = Symbol(part)
    getattr(obj, part, sym, Val(sym), all(isdigit, part) && !isempty(part) ? parse(Int, part) + 1 : -1)
end
# `sym`, `val` (Val(sym)) and `idx` (1-based index, or -1) are prepared at parse time (Variable).
function getattr(obj, part::AbstractString, sym::Symbol, val, idx::Int)
    (obj === nothing || obj === UNDEF) && return UNDEF
    if obj isa AbstractDict
        haskey(obj, part) && return obj[part]
        haskey(obj, sym) && return obj[sym]
    end
    r = tattr(obj, val)
    r === NOTFOUND || return r
    if idx > 0 && (obj isa AbstractVector || obj isa Tuple)
        return checkbounds(Bool, obj, idx) ? obj[idx] : UNDEF
    end
    if obj isa AbstractDict
        part == "items" && return collect(pairs(obj))
        part == "keys" && return collect(keys(obj))
        part == "values" && return collect(values(obj))
    end
    (obj isa Pair && part in ("first", "key")) && return obj.first
    (obj isa Pair && part in ("second", "value")) && return obj.second
    (obj isa Union{AbstractVector,Tuple,AbstractString} && part in ("length", "count")) && return length(obj)
    if !(obj isa AbstractDict) && hasproperty(obj, sym)
        return getproperty(obj, sym)
    end
    UNDEF
end

function resolve_var(v::Variable, ctx::Context)
    val = lookup(ctx, v.parts[1])
    for i in 2:length(v.parts)
        val = getattr(val, v.parts[i], v.syms[i], v.vals[i], v.idx[i])
        val === UNDEF && break
    end
    val
end
resolve_var(l::Literal, ::Context) = l.value

function eval_fe(fe::FilterExpr, ctx::Context)
    val = resolve_var(fe.base, ctx)
    val === UNDEF && (val = nothing)
    for (f, arg) in fe.filters
        a = arg === nothing ? nothing : resolve_var(arg, ctx)
        a === UNDEF && (a = nothing)
        was_safe = val isa SafeString
        val = f.needs_autoescape ? f.fn(val, a, ctx.autoescape) : f.fn(val, a)
        if f.is_safe && was_safe && val isa AbstractString
            val = SafeString(val)
        end
    end
    val
end

"Django truthiness."
truthy(x) = true
truthy(::Nothing) = false
truthy(::Undefined) = false
truthy(x::Bool) = x
truthy(x::Number) = !iszero(x)
truthy(x::AbstractString) = !isempty(x)
truthy(x::SafeString) = !isempty(x.s)
truthy(x::Union{AbstractArray,AbstractDict,Tuple,AbstractSet,NamedTuple}) = !isempty(x)

# --- nodes ----------------------------------------------------------------------------

abstract type Node end

struct TextNode <: Node
    s::String
end
struct VarNode <: Node
    fe::FilterExpr
    line::Int
end

"A parsed template."
struct Template
    name::String
    nodes::Vector{Node}
    origin::Union{Nothing,String}
end

mutable struct Parser
    tokens::Vector{Token}
    pos::Int
    name::String
    current::Union{Nothing,Token}
    extra::Dict{Symbol,Any}     # :origin, :source, :tags (from {% load %}), :partials
end

const TAGS = Dict{String,Function}()

"""
    register_tag!(name, f)

Register a custom block tag. `f(parser, token)` must return a `Node`; implement
`Juango.render!(io, node, ctx)` for it. Use `parse_nodes(parser, [\"endname\"])`
to parse an enclosed block.
"""
register_tag!(name, f) = (TAGS[string(name)] = f; nothing)

function tsyntax(p::Parser, msg)
    origin = get(p.extra, :origin, nothing)
    line = p.current === nothing ? 0 : p.current.line
    where_ = "in template '$(p.name)'" * (origin === nothing || origin == p.name ? "" : " ($origin)") * (line == 0 ? "" : ", line $line")
    throw(TemplateSyntaxError("$msg ($where_)", p.name, origin, line, get(p.extra, :source, nothing)))
end

"Parse nodes until one of the `until` block tags; returns `(nodes, end_token_contents)`."
function parse_nodes(p::Parser, until::Vector{String} = String[])
    nodes = Node[]
    while p.pos <= length(p.tokens)
        t = p.tokens[p.pos]
        p.pos += 1
        p.current = t
        if t.kind === :text
            push!(nodes, TextNode(t.contents))
        elseif t.kind === :var
            isempty(t.contents) && tsyntax(p, "empty variable tag")
            fe = try
                parse_filter_expr(t.contents)
            catch e
                e isa TemplateSyntaxError ? tsyntax(p, e.msg) : rethrow()
            end
            push!(nodes, VarNode(fe, t.line))
        elseif t.kind === :block
            isempty(t.contents) && tsyntax(p, "empty block tag")
            cmd = first(split(t.contents))
            cmd in until && return nodes, t.contents
            handler = get(TAGS, cmd, nothing)
            handler === nothing && (handler = get(get(p.extra, :tags, Dict{String,Function}()), cmd, nothing))
            handler === nothing && tsyntax(p, isempty(until) ? "invalid block tag '$cmd'" :
                                               "invalid block tag '$cmd', expected $(join(until, " or "))")
            node = try
                handler(p, t)
            catch e
                e isa TemplateSyntaxError && !occursin("in template", e.msg) ? tsyntax(p, e.msg) : rethrow()
            end
            node === nothing || push!(nodes, node)
        end
    end
    isempty(until) || tsyntax(p, "unclosed tag; expected $(join(until, " or "))")
    nodes, nothing
end

function Template(src::AbstractString; name = "<string>", origin = nothing)
    p = Parser(tokenize(src), 1, name, nothing, Dict{Symbol,Any}(:origin => origin, :source => src))
    # {% load %} adds library filters for this template only (not for templates it includes or extends)
    nodes, _ = Base.ScopedValues.with(() -> parse_nodes(p), LOADED_FILTERS => Dict{String,TemplateFilter}())
    Template(name, nodes, origin)
end

Base.show(io::IO, t::Template) = print(io, "<Template ", repr(t.name), ">")

# --- rendering ------------------------------------------------------------------------

render!(io::IO, n::TextNode, ::Context) = write(io, n.s)
"`TEMPLATE_STRING_IF_INVALID`: what an unknown variable renders as (`%s` is its name), kept for speed."
const STRING_IF_INVALID = Ref("")
push!(SETTINGS_CHANGED_HOOKS, () -> (STRING_IF_INVALID[] = string(something(get(settings, :TEMPLATE_STRING_IF_INVALID, ""), ""))))
function render!(io::IO, n::VarNode, ctx::Context)
    inv = STRING_IF_INVALID[]
    if !isempty(inv) && n.fe.base isa Variable && resolve_var(n.fe.base, ctx) === UNDEF
        return write(io, replace(inv, "%s" => join(n.fe.base.parts, ".")))     # filters aren't applied, as in Django
    end
    write_value(io, eval_fe(n.fe, ctx), ctx.autoescape)
end
function render_nodes(io::IO, nodes::Vector{Node}, ctx::Context)
    for n in nodes
        render!(io, n, ctx)
    end
end
function render_nodes(nodes::Vector{Node}, ctx::Context)
    io = IOBuffer()
    render_nodes(io, nodes, ctx)
    String(take!(io))
end

"Sub-node lists of a node (for finding blocks)."
child_nodelists(::Node) = ()

function nodes_of_type(::Type{T}, nodes::Vector{Node}, out = T[]) where {T}
    for n in nodes
        n isa T && push!(out, n)
        for nl in child_nodelists(n)
            nodes_of_type(T, nl, out)
        end
    end
    out
end

"""
    render(t::Template, context=Dict(); request=nothing) -> String

Render a template. If `request` is given, context processors run as well.
"""
function render(t::Template, context = Dict{String,Any}(); request = nothing, autoescape = true)
    base = Dict{String,Any}()
    if request !== nothing
        for cp in settings.CONTEXT_PROCESSORS
            merge!(base, to_context_dict(cp(request)))
        end
    end
    ctx = Context([base, to_context_dict(context)], autoescape, Dict{Symbol,Any}(), request)
    io = IOBuffer()
    run_nodes(io, t.nodes, ctx)
    String(take!(io))
end

# --- compiled templates --------------------------------------------------------------------------------
#
# With TEMPLATE_COMPILE (default: when DEBUG is off), each list of nodes a template renders (its
# body, its blocks, an included or parent template) becomes a Julia function the first time it's
# rendered: text is written directly, `{% if %}` and `{% for %}` become Julia branches and loops,
# and every other node is a call to its `render!` method on a constant node, so nothing is
# dispatched at run time. Nodes without a generator (custom tags included) keep their own
# `render!`, so behaviour and error messages (template name and line) are the same as when
# interpreting.

"Where compiled templates' functions live."
module CompiledTemplates end

# Compiled functions by node list identity (objectid => (weak ref to the list, function)): the
# weak ref lets a template made from a string at run time be collected, and tells a reused
# objectid from the list it was compiled for. Entries for collected lists are swept now and then.
const COMPILED_NODES = Dict{UInt,Tuple{WeakRef,Any}}()
const COMPILED_LOCK = ReentrantLock()
const COMPILED_SWEEP = Ref(1024)
"Whether templates are compiled: TEMPLATE_COMPILE, or by default when DEBUG is off (kept for speed)."
const COMPILE_TEMPLATES = Ref(false)
push!(SETTINGS_CHANGED_HOOKS, () -> (COMPILE_TEMPLATES[] = something(get(settings, :TEMPLATE_COMPILE, nothing), !settings.DEBUG)))
compile_templates() = COMPILE_TEMPLATES[]

"Render a list of nodes: through its compiled function when templates are compiled."
function run_nodes(io::IO, nodes::Vector{Node}, ctx::Context)
    compile_templates() || return render_nodes(io, nodes, ctx)
    Base.invokelatest(compiled_function(nodes), io, ctx)
    nothing
end

"The compiled function `(io, ctx) -> nothing` for a node list, compiling it the first time."
function compiled_function(nodes::Vector{Node})
    id = objectid(nodes)
    lock(COMPILED_LOCK) do
        e = get(COMPILED_NODES, id, nothing)
        e !== nothing && e[1].value === nodes && return e[2]
        if length(COMPILED_NODES) >= COMPILED_SWEEP[]
            filter!(kv -> kv[2][1].value !== nothing, COMPILED_NODES)
            COMPILED_SWEEP[] = max(1024, 2 * length(COMPILED_NODES))
        end
        f = Core.eval(CompiledTemplates, :((io::IO, ctx) -> ($(gen_nodes(nodes)); nothing)))
        COMPILED_NODES[id] = (WeakRef(nodes), f)
        f
    end
end

"The Julia code that renders `nodes` (with `io` and `ctx` in scope)."
gen_nodes(nodes) = Expr(:block, Any[gen_node(n) for n in nodes]...)
gen_node(n::TextNode) = :($(GlobalRef(Base, :write))(io, $(n.s)))
gen_node(n::Node) = :($(GlobalRef(@__MODULE__, :render!))(io, $(QuoteNode(n)), ctx))   # a constant node: static dispatch

# `{{ var|filter:arg }}`: the variable's parts and the filter functions are constants, so the
# lookups and filter calls aren't looped over or dispatched through `Function` fields.
const _M = @__MODULE__
gen_var(l::Literal) = QuoteNode(l.value)
function gen_var(v::Variable)
    ex = :($(GlobalRef(_M, :lookup))(ctx, $(v.parts[1])))
    length(v.parts) == 1 && return ex
    val = gensym("v")
    body = Any[:($val = $ex)]
    for i in 2:length(v.parts)
        push!(body, :($val === $(GlobalRef(_M, :UNDEF)) || ($val = $(GlobalRef(_M, :getattr))($val, $(v.parts[i]), $(QuoteNode(v.syms[i])), $(v.vals[i]), $(v.idx[i])))))
    end
    push!(body, val)
    Expr(:let, Expr(:block), Expr(:block, body...))
end
function gen_fe(fe::FilterExpr)
    val = gensym("val")
    body = Any[:($val = $(gen_var(fe.base))), :($val === $(GlobalRef(_M, :UNDEF)) && ($val = nothing))]
    for (f, arg) in fe.filters
        a = gensym("arg")
        push!(body, arg === nothing ? :($a = nothing) :
                    :($a = $(gen_var(arg)); $a === $(GlobalRef(_M, :UNDEF)) && ($a = nothing)))
        call = f.needs_autoescape ? :($(f.fn)($val, $a, ctx.autoescape)) : :($(f.fn)($val, $a))
        if f.is_safe
            push!(body, :($val = $(GlobalRef(_M, :keep_safe))($val isa $(GlobalRef(_M, :SafeString)), $call)))
        else
            push!(body, :($val = $call))
        end
    end
    push!(body, val)
    Expr(:let, Expr(:block), Expr(:block, body...))
end
keep_safe(was_safe::Bool, v) = was_safe && v isa AbstractString ? SafeString(v) : v
gen_node(n::VarNode) = quote
    if isempty($(GlobalRef(_M, :STRING_IF_INVALID))[])
        $(GlobalRef(_M, :write_value))(io, $(gen_fe(n.fe)), ctx.autoescape)
    else
        $(GlobalRef(_M, :render!))(io, $(QuoteNode(n)), ctx)
    end
end

# --- loaders --------------------------------------------------------------------------

const BUILTIN_TEMPLATE_DIR = joinpath(ASSETS_DIR, "templates")
const TEMPLATE_CACHE = Dict{String,Tuple{Float64,Template}}()
const TEMPLATE_LOCK = ReentrantLock()

"Where templates are looked up: TEMPLATE_DIRS, each installed app's `templates/` (APP_DIRS), Juango's own."
template_dirs() = vcat(String[abspath(d) for d in settings.TEMPLATE_DIRS], app_dirs("templates"), [BUILTIN_TEMPLATE_DIR])

function find_template(name::AbstractString, dirs = template_dirs(), tried = String[]; throw_missing = true)
    for d in dirs
        p = normpath(joinpath(d, name))
        startswith(p, normpath(d)) || continue
        isfile(p) && return p
        push!(tried, p)
    end
    throw_missing ? throw(TemplateDoesNotExist(String(name), tried)) : nothing
end

# --- template engines ------------------------------------------------------------------------------
#
# TEMPLATES lists the engines templates are looked up in, in order; each gets a chance to find a
# template by name. The default is Juango's own language with TEMPLATE_DIRS:
#
#     configure!(TEMPLATES = [Juango.JuangoTemplates(), Juango.MustacheTemplates(dirs = ["mustache"])])
#
# An engine is any value with a method `Juango.engine_template(engine, name, tried) -> template or
# nothing`; its templates need `render(t, context; request)` and a `name`.

"""
    JuangoTemplates(; dirs = nothing, app_dirs = true)

Juango's template language (Django's): templates from `dirs` (default `TEMPLATE_DIRS`), each
installed app's `templates/` and Juango's own.
"""
Base.@kwdef struct JuangoTemplates
    dirs::Union{Nothing,Vector{String}} = nothing
    app_dirs::Bool = true
end
engine_dirs(e) = vcat(String[abspath(d) for d in something(e.dirs, settings.TEMPLATE_DIRS)], e.app_dirs ? app_dirs("templates") : String[])
template_engines() = (t = get(settings, :TEMPLATES, nothing); t === nothing ? Any[JuangoTemplates()] : collect(Any, t))
"Whether templates are read again when their files change: TEMPLATE_CACHE_CHECK_MTIME, or by default only with DEBUG."
check_template_mtime() = something(get(settings, :TEMPLATE_CACHE_CHECK_MTIME, nothing), settings.DEBUG)

"""
    get_template(name) -> Template

Load a template from `settings.TEMPLATE_DIRS` (then Juango's built-in templates).
Templates are cached and reloaded automatically when the file changes. With
`TEMPLATE_CACHE_CHECK_MTIME = false` (for production) a template is read once and the file
isn't checked again.
"""
const TEMPLATE_BY_NAME = Dict{String,Any}()
clear_template_cache!() = lock(() -> (empty!(TEMPLATE_CACHE); empty!(TEMPLATE_BY_NAME); empty!(MUSTACHE_CACHE); nothing), TEMPLATE_LOCK)
push!(SETTINGS_CHANGED_HOOKS, clear_template_cache!)
function get_template(name::AbstractString)
    occursin('#', name) && return partial_template(name)         # "page.html#partial"
    tried = String[]
    for e in template_engines()
        t = engine_template(e, name, tried)
        t === nothing || return t
    end
    throw(TemplateDoesNotExist(String(name), tried))
end
function engine_template(e::JuangoTemplates, name::AbstractString, tried)
    key = string(objectid(e.dirs), ":", name)
    if !check_template_mtime()
        t = lock(() -> get(TEMPLATE_BY_NAME, key, nothing), TEMPLATE_LOCK)
        t === nothing || return t
    end
    p = find_template(name, vcat(engine_dirs(e), [BUILTIN_TEMPLATE_DIR]), tried; throw_missing = false)
    p === nothing && return nothing
    mt = mtime(p)
    lock(TEMPLATE_LOCK) do
        c = get(TEMPLATE_CACHE, p, nothing)
        c !== nothing && c[1] == mt && return c[2]
        t = Template(read(p, String); name = String(name), origin = p)
        TEMPLATE_CACHE[p] = (mt, t)
        TEMPLATE_BY_NAME[key] = t
        t
    end
end

"""
    MustacheTemplates(; dirs = String[], app_dirs = true, extension = ".mustache")

Mustache templates (`{{name}}`, `{{#items}}...{{/items}}`) through Mustache.jl, for names ending
in `extension`. Load the package (`using Mustache`) to enable it; context processors apply as for
Juango templates, and `{{ }}` escapes HTML (`{{{ }}}` doesn't).
"""
Base.@kwdef struct MustacheTemplates
    dirs::Vector{String} = String[]
    app_dirs::Bool = true
    extension::String = ".mustache"
end
"A parsed Mustache template."
struct MustacheTemplate
    name::String
    origin::String
    compiled::Any
end
const MUSTACHE_CACHE = Dict{String,Tuple{Float64,MustacheTemplate}}()
"Parse Mustache source (defined by the Mustache extension)."
mustache_compile(src) = throw(ArgumentError("MustacheTemplates needs Mustache.jl: add `using Mustache` to your project"))
"Render parsed Mustache with a context (defined by the Mustache extension)."
function mustache_render end
function engine_template(e::MustacheTemplates, name::AbstractString, tried)
    endswith(name, e.extension) || return nothing
    p = find_template(name, engine_dirs(e), tried; throw_missing = false)
    p === nothing && return nothing
    mt = mtime(p)
    lock(TEMPLATE_LOCK) do
        c = get(MUSTACHE_CACHE, p, nothing)
        c !== nothing && (c[1] == mt || !check_template_mtime()) && return c[2]
        t = MustacheTemplate(String(name), p, mustache_compile(read(p, String)))
        MUSTACHE_CACHE[p] = (mt, t)
        t
    end
end
function render(t::MustacheTemplate, context = Dict{String,Any}(); request = nothing, autoescape = true)
    ctx = Dict{String,Any}()
    if request !== nothing
        for cp in settings.CONTEXT_PROCESSORS
            merge!(ctx, to_context_dict(cp(request)))
        end
    end
    merge!(ctx, to_context_dict(context))
    mustache_render(t.compiled, Dict{String,Any}(k => (v isa SafeString ? v.s : v) for (k, v) in ctx))
end

"First template in `names` that exists."
function select_template(names)
    names isa AbstractString && return get_template(names)
    for n in names
        try
            return get_template(n)
        catch e
            e isa TemplateDoesNotExist || rethrow()
        end
    end
    throw(TemplateDoesNotExist(join(names, ", "), String[]))
end

"""
    render_to_string(template_name, context=Dict(); request=nothing) -> String
"""
render_to_string(name, context = Dict{String,Any}(); request = nothing) =
    render(select_template(name), context; request = request)
