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
render!(io::IO, n::VarNode, ctx::Context) = write_value(io, eval_fe(n.fe, ctx), ctx.autoescape)
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
    render_nodes(t.nodes, ctx)
end

# --- loaders --------------------------------------------------------------------------

const BUILTIN_TEMPLATE_DIR = joinpath(@__DIR__, "templates")
const TEMPLATE_CACHE = Dict{String,Tuple{Float64,Template}}()
const TEMPLATE_LOCK = ReentrantLock()

"Where templates are looked up: TEMPLATE_DIRS, each installed app's `templates/` (APP_DIRS), Juango's own."
template_dirs() = vcat(String[abspath(d) for d in settings.TEMPLATE_DIRS], app_dirs("templates"), [BUILTIN_TEMPLATE_DIR])

function find_template(name::AbstractString)
    tried = String[]
    for d in template_dirs()
        p = normpath(joinpath(d, name))
        startswith(p, normpath(d)) || continue
        isfile(p) && return p
        push!(tried, p)
    end
    throw(TemplateDoesNotExist(String(name), tried))
end

"""
    get_template(name) -> Template

Load a template from `settings.TEMPLATE_DIRS` (then Juango's built-in templates).
Templates are cached and reloaded automatically when the file changes. With
`TEMPLATE_CACHE_CHECK_MTIME = false` (for production) a template is read once and the file
isn't checked again.
"""
const TEMPLATE_BY_NAME = Dict{String,Any}()
clear_template_cache!() = lock(() -> (empty!(TEMPLATE_CACHE); empty!(TEMPLATE_BY_NAME); nothing), TEMPLATE_LOCK)
push!(SETTINGS_CHANGED_HOOKS, clear_template_cache!)
function get_template(name::AbstractString)
    occursin('#', name) && return partial_template(name)         # "page.html#partial"
    if !settings.TEMPLATE_CACHE_CHECK_MTIME
        t = lock(() -> get(TEMPLATE_BY_NAME, name, nothing), TEMPLATE_LOCK)
        t === nothing || return t
    end
    p = find_template(name)
    mt = mtime(p)
    lock(TEMPLATE_LOCK) do
        c = get(TEMPLATE_CACHE, p, nothing)
        c !== nothing && c[1] == mt && return c[2]
        t = Template(read(p, String); name = String(name), origin = p)
        TEMPLATE_CACHE[p] = (mt, t)
        TEMPLATE_BY_NAME[String(name)] = t
        t
    end
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

# ======================================================================================
# Built-in tags
# ======================================================================================

# --- if -------------------------------------------------------------------------------

abstract type Cond end
struct CondValue <: Cond
    fe::FilterExpr
end
struct CondOp <: Cond
    op::Symbol
    args::Vector{Cond}
end
CondOp(op::AbstractString, args) = CondOp(Symbol(op), args)
const OP_NOT_IN, OP_IS_NOT = Symbol("not in"), Symbol("is not")

mutable struct CondParser
    toks::Vector{String}
    i::Int
end
peekt(cp::CondParser) = cp.i <= length(cp.toks) ? cp.toks[cp.i] : nothing
nextt!(cp::CondParser) = (t = peekt(cp); cp.i += 1; t)

function parse_cond(toks::Vector{String})
    isempty(toks) && throw(TemplateSyntaxError("'if' statement requires a condition"))
    cp = CondParser(toks, 1)
    c = parse_or(cp)
    peekt(cp) === nothing || throw(TemplateSyntaxError("unused '$(peekt(cp))' in if expression"))
    c
end
function parse_or(cp)
    l = parse_and(cp)
    while peekt(cp) == "or"
        nextt!(cp)
        l = CondOp("or", [l, parse_and(cp)])
    end
    l
end
function parse_and(cp)
    l = parse_not(cp)
    while peekt(cp) == "and"
        nextt!(cp)
        l = CondOp("and", [l, parse_not(cp)])
    end
    l
end
function parse_not(cp)
    if peekt(cp) == "not"
        nextt!(cp)
        return CondOp("not", [parse_not(cp)])
    end
    parse_cmp(cp)
end
const CMP_OPS = ("==", "!=", "<", ">", "<=", ">=", "in", "is", "=")
function parse_cmp(cp)
    t = nextt!(cp)
    t === nothing && throw(TemplateSyntaxError("unexpected end of if expression"))
    t in ("and", "or", "not") && throw(TemplateSyntaxError("unexpected '$t' in if expression"))
    l = CondValue(parse_filter_expr(t))
    op = peekt(cp)
    if op == "not" && cp.i + 1 <= length(cp.toks) && cp.toks[cp.i+1] == "in"
        cp.i += 2
        return CondOp("not in", [l, parse_operand_cond(cp)])
    elseif op == "is" && cp.i + 1 <= length(cp.toks) && cp.toks[cp.i+1] == "not"
        cp.i += 2
        return CondOp("is not", [l, parse_operand_cond(cp)])
    elseif op !== nothing && op in CMP_OPS
        nextt!(cp)
        return CondOp(op == "=" ? "==" : op, [l, parse_operand_cond(cp)])
    end
    l
end
function parse_operand_cond(cp)
    t = nextt!(cp)
    t === nothing && throw(TemplateSyntaxError("missing right-hand operand in if expression"))
    CondValue(parse_filter_expr(t))
end

function value_eq(a, b)
    a isa SafeString && (a = a.s)
    b isa SafeString && (b = b.s)
    try
        return isequal(a, b) || a == b
    catch
        return false
    end
end
function value_in(a, b)
    a isa SafeString && (a = a.s)
    b isa SafeString && (b = b.s)
    b === nothing && return false
    try
        b isa AbstractString && return occursin(string(a), b)
        b isa AbstractDict && return haskey(b, a) || (a isa AbstractString && haskey(b, Symbol(a)))
        return any(x -> value_eq(a, x), b)
    catch
        return false
    end
end

function eval_cond(c::CondValue, ctx)
    v = eval_fe(c.fe, ctx)
    v === UNDEF ? nothing : v
end
function eval_cond(c::CondOp, ctx)
    op = c.op
    op === :not && return !truthy(eval_cond(c.args[1], ctx))
    op === :and && return truthy(eval_cond(c.args[1], ctx)) && truthy(eval_cond(c.args[2], ctx))
    op === :or && return truthy(eval_cond(c.args[1], ctx)) || truthy(eval_cond(c.args[2], ctx))
    a = eval_cond(c.args[1], ctx)
    b = eval_cond(c.args[2], ctx)
    op === :(==) && return value_eq(a, b)
    op === :(!=) && return !value_eq(a, b)
    op === :in && return value_in(a, b)
    op === OP_NOT_IN && return !value_in(a, b)
    op === :is && return a === b
    op === OP_IS_NOT && return a !== b
    a isa SafeString && (a = a.s)
    b isa SafeString && (b = b.s)
    try
        op === :< && return a < b
        op === :> && return a > b
        op === :<= && return a <= b
        op === :>= && return a >= b
    catch
        return false
    end
    false
end

struct IfNode <: Node
    branches::Vector{Tuple{Union{Nothing,Cond},Vector{Node}}}
end
child_nodelists(n::IfNode) = [b[2] for b in n.branches]

function tag_if(p::Parser, t::Token)
    branches = Tuple{Union{Nothing,Cond},Vector{Node}}[]
    cond = parse_cond(split_contents(t.contents)[2:end])
    while true
        nodes, endtag = parse_nodes(p, ["elif", "else", "endif"])
        push!(branches, (cond, nodes))
        cmd = first(split(endtag))
        if cmd == "elif"
            cond = parse_cond(split_contents(endtag)[2:end])
        elseif cmd == "else"
            nodes, _ = parse_nodes(p, ["endif"])
            push!(branches, (nothing, nodes))
            break
        else
            break
        end
    end
    IfNode(branches)
end
function render!(io::IO, n::IfNode, ctx::Context)
    for (cond, nodes) in n.branches
        if cond === nothing || truthy(eval_cond(cond, ctx))
            render_nodes(io, nodes, ctx)
            return
        end
    end
end

# --- for ------------------------------------------------------------------------------

struct ForNode <: Node
    loopvars::Vector{String}
    iterable::FilterExpr
    reversed::Bool
    body::Vector{Node}
    empty::Vector{Node}
end
child_nodelists(n::ForNode) = (n.body, n.empty)

function tag_for(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    length(bits) >= 3 || throw(TemplateSyntaxError("'for' statements should have at least four words: $(t.contents)"))
    reversed = bits[end] == "reversed"
    reversed && pop!(bits)
    inpos = findlast(==("in"), bits)
    inpos === nothing && throw(TemplateSyntaxError("'for' statements should use the format 'for x in y'"))
    loopvars = String.(filter(!isempty, strip.(split(join(bits[1:inpos-1], " "), ','))))
    iterable = parse_filter_expr(join(bits[inpos+1:end], " "))
    body, endtag = parse_nodes(p, ["empty", "endfor"])
    empty = Node[]
    if endtag == "empty"
        empty, _ = parse_nodes(p, ["endfor"])
    end
    ForNode(loopvars, iterable, reversed, body, empty)
end

"Materialise something iterable for `{% for %}`."
to_iterable(::Nothing) = Any[]
to_iterable(::Undefined) = Any[]
to_iterable(x::AbstractString) = collect(x)
to_iterable(x::SafeString) = collect(x.s)
to_iterable(x) = collect(x)

"""
`forloop` inside `{% for %}`: `counter`, `counter0`, `revcounter`, `revcounter0`, `first`,
`last`, `length` and `parentloop`. One object per loop, updated in place each iteration (as
Django updates its dict).
"""
mutable struct ForLoop
    counter::Int
    counter0::Int
    revcounter::Int
    revcounter0::Int
    first::Bool
    last::Bool
    length::Int
    parentloop::Any
end
function tattr(l::ForLoop, ::Val{S}) where {S}
    S in (:counter, :counter0, :revcounter, :revcounter0, :first, :last, :length, :parentloop) ? getfield(l, S) : NOTFOUND
end
Base.getindex(l::ForLoop, k::AbstractString) = getfield(l, Symbol(k))     # forloop["counter"], as with the old Dict

function render!(io::IO, n::ForNode, ctx::Context)
    raw = eval_fe(n.iterable, ctx)
    items = if raw isa AbstractDict
        length(n.loopvars) == 1 ? collect(keys(raw)) : collect(pairs(raw))
    else
        to_iterable(raw)
    end
    n.reversed && (items = Base.reverse(items))
    if isempty(items)
        render_nodes(io, n.empty, ctx)
        return
    end
    parent = lookup(ctx, "forloop")
    len = length(items)
    loop = ForLoop(0, 0, 0, 0, false, false, len, parent === UNDEF ? nothing : parent)
    with_scope(ctx) do
        ctx["forloop"] = loop
        for (i, item) in enumerate(items)
            loop.counter, loop.counter0, loop.revcounter, loop.revcounter0 = i, i - 1, len - i + 1, len - i
            loop.first, loop.last = i == 1, i == len
            if length(n.loopvars) == 1
                ctx[n.loopvars[1]] = item
            else
                vals = item isa Pair ? (item.first, item.second) : item
                for (j, v) in enumerate(n.loopvars)
                    ctx[v] = j <= length(vals) ? vals[j] : nothing
                end
            end
            render_nodes(io, n.body, ctx)
        end
    end
end

# --- inheritance: extends / block -------------------------------------------------------

struct BlockNode <: Node
    name::String
    nodes::Vector{Node}
end
child_nodelists(n::BlockNode) = (n.nodes,)

struct ExtendsNode <: Node
    parent::FilterExpr
    nodes::Vector{Node}
    blocks::Dict{String,BlockNode}
end
child_nodelists(n::ExtendsNode) = (n.nodes,)

mutable struct BlockContext
    blocks::Dict{String,Vector{BlockNode}}
end
BlockContext() = BlockContext(Dict{String,Vector{BlockNode}}())
add_blocks!(bc::BlockContext, blocks) =
    for (name, b) in blocks
        pushfirst!(get!(bc.blocks, name, BlockNode[]), b)
    end
pop_block!(bc::BlockContext, name) = (v = get(bc.blocks, name, nothing); v === nothing || isempty(v) ? nothing : pop!(v))
push_block!(bc::BlockContext, name, b) = push!(get!(bc.blocks, name, BlockNode[]), b)
get_block(bc::BlockContext, name) = (v = get(bc.blocks, name, nothing); v === nothing || isempty(v) ? nothing : v[end])

"`{{ block.super }}` support."
struct BlockRef
    node::BlockNode
    ctx::Context
end
function tattr(b::BlockRef, ::Val{:super})
    bc = get(b.ctx.render_ctx, :block_context, nothing)
    (bc === nothing || get_block(bc, b.node.name) === nothing) && return SafeString("")
    io = IOBuffer()
    render_block(io, b.node, b.ctx)
    SafeString(String(take!(io)))
end

function tag_block(p::Parser, t::Token)
    bits = split(t.contents)
    length(bits) == 2 || throw(TemplateSyntaxError("'block' tag takes exactly one argument"))
    nodes, endtag = parse_nodes(p, ["endblock"])
    eb = split(endtag)
    length(eb) > 1 && eb[2] != bits[2] &&
        throw(TemplateSyntaxError("mismatched endblock: expected '$(bits[2])', got '$(eb[2])'"))
    BlockNode(String(bits[2]), nodes)
end

function render_block(io::IO, n::BlockNode, ctx::Context)
    bc = get(ctx.render_ctx, :block_context, nothing)
    with_scope(ctx) do
        if bc === nothing
            ctx["block"] = BlockRef(n, ctx)
            render_nodes(io, n.nodes, ctx)
        else
            b = pop_block!(bc, n.name)
            b === nothing && (b = n)
            ctx["block"] = BlockRef(b, ctx)
            try
                render_nodes(io, b.nodes, ctx)
            finally
                push_block!(bc, n.name, b)
            end
        end
    end
end
render!(io::IO, n::BlockNode, ctx::Context) = render_block(io, n, ctx)

function tag_extends(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) == 2 || throw(TemplateSyntaxError("'extends' takes one argument"))
    parent = parse_filter_expr(bits[2])
    nodes, _ = parse_nodes(p)
    blocks = Dict{String,BlockNode}(b.name => b for b in nodes_of_type(BlockNode, nodes))
    ExtendsNode(parent, nodes, blocks)
end

function render!(io::IO, n::ExtendsNode, ctx::Context)
    bc = get!(BlockContext, ctx.render_ctx, :block_context)
    add_blocks!(bc, n.blocks)
    pname = eval_fe(n.parent, ctx)
    parent = pname isa Template ? pname : get_template(display_string(pname))
    if !any(x -> x isa ExtendsNode, parent.nodes)
        add_blocks!(bc, Dict(b.name => b for b in nodes_of_type(BlockNode, parent.nodes)))
    end
    render_nodes(io, parent.nodes, ctx)
end

# --- include --------------------------------------------------------------------------

struct IncludeNode <: Node
    template::FilterExpr
    extra::Vector{Tuple{String,FilterExpr}}
    only::Bool
end

"Parse `a=b c=d` keyword arguments."
function parse_kwargs(bits)
    out = Tuple{String,FilterExpr}[]
    for b in bits
        m = match(r"^(\w+)=(.+)$"s, b)
        m === nothing && throw(TemplateSyntaxError("expected keyword argument, got '$b'"))
        push!(out, (String(m[1]), parse_filter_expr(m[2])))
    end
    out
end

function tag_include(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) >= 2 || throw(TemplateSyntaxError("'include' requires a template name"))
    rest = bits[3:end]
    only = !isempty(rest) && rest[end] == "only"
    only && pop!(rest)
    extra = Tuple{String,FilterExpr}[]
    if !isempty(rest)
        rest[1] == "with" || throw(TemplateSyntaxError("expected 'with' in include tag"))
        extra = parse_kwargs(rest[2:end])
    end
    IncludeNode(parse_filter_expr(bits[2]), extra, only)
end

function render!(io::IO, n::IncludeNode, ctx::Context)
    name = eval_fe(n.template, ctx)
    t = name isa Template ? name : get_template(display_string(name))
    values = Dict{String,Any}(k => eval_fe(fe, ctx) for (k, fe) in n.extra)
    saved_stack, saved_rc = ctx.stack, ctx.render_ctx
    ctx.render_ctx = Dict{Symbol,Any}()
    n.only && (ctx.stack = [Dict{String,Any}()])
    try
        with_scope(() -> render_nodes(io, t.nodes, ctx), ctx, values)
    finally
        ctx.stack, ctx.render_ctx = saved_stack, saved_rc
    end
end

# --- with -----------------------------------------------------------------------------

struct WithNode <: Node
    assigns::Vector{Tuple{String,FilterExpr}}
    nodes::Vector{Node}
end
child_nodelists(n::WithNode) = (n.nodes,)
function tag_with(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    assigns = if length(bits) == 3 && bits[2] == "as"
        [(bits[3], parse_filter_expr(bits[1]))]
    else
        parse_kwargs(bits)
    end
    isempty(assigns) && throw(TemplateSyntaxError("'with' expects at least one variable assignment"))
    nodes, _ = parse_nodes(p, ["endwith"])
    WithNode(assigns, nodes)
end
render!(io::IO, n::WithNode, ctx::Context) =
    with_scope(() -> render_nodes(io, n.nodes, ctx), ctx,
               Dict{String,Any}(k => eval_fe(fe, ctx) for (k, fe) in n.assigns))

# --- url ------------------------------------------------------------------------------

struct URLNode <: Node
    name::FilterExpr
    args::Vector{FilterExpr}
    kwargs::Vector{Tuple{String,FilterExpr}}
    asvar::Union{Nothing,String}
end
function tag_url(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    isempty(bits) && throw(TemplateSyntaxError("'url' takes at least one argument, a URL pattern name"))
    asvar = nothing
    if length(bits) >= 3 && bits[end-1] == "as"
        asvar = bits[end]
        bits = bits[1:end-2]
    end
    args, kwargs = FilterExpr[], Tuple{String,FilterExpr}[]
    for b in bits[2:end]
        if occursin(r"^\w+=", b)
            append!(kwargs, parse_kwargs([b]))
        else
            push!(args, parse_filter_expr(b))
        end
    end
    URLNode(parse_filter_expr(bits[1]), args, kwargs, asvar)
end
function render!(io::IO, n::URLNode, ctx::Context)
    name = display_string(eval_fe(n.name, ctx))
    args = [eval_fe(a, ctx) for a in n.args]
    kw = Dict{Symbol,Any}(Symbol(k) => eval_fe(v, ctx) for (k, v) in n.kwargs)
    url = try
        reverse_url(name, args...; kw...)
    catch e
        (e isa NoReverseMatch && n.asvar !== nothing) ? "" : rethrow()
    end
    if n.asvar === nothing
        write(io, ctx.autoescape ? escape_html(url) : url)
    else
        ctx[n.asvar] = url
    end
end

# --- csrf_token / static / load -------------------------------------------------------

struct CsrfTokenNode <: Node end
tag_csrf_token(p, t) = CsrfTokenNode()
function render!(io::IO, ::CsrfTokenNode, ctx::Context)
    tok = lookup(ctx, "csrf_token")
    (tok === UNDEF || tok === nothing) && return
    write(io, "<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"", escape_html(display_string(tok)), "\">")
end

struct StaticNode <: Node
    path::FilterExpr
    asvar::Union{Nothing,String}
end
function tag_static(p, t)
    bits = split_contents(t.contents)
    length(bits) in (2, 4) || throw(TemplateSyntaxError("'static' takes one argument"))
    StaticNode(parse_filter_expr(bits[2]), length(bits) == 4 ? bits[4] : nothing)
end
static_url(p) = settings.STATIC_URL * stored_static_name(lstrip(string(p), '/'))      # staticfiles.jl
function render!(io::IO, n::StaticNode, ctx::Context)
    url = static_url(display_string(eval_fe(n.path, ctx)))
    n.asvar === nothing ? write(io, escape_html(url)) : (ctx[n.asvar] = url)
end

tag_load(p, t) = load_libraries!(p, t)       # templatetags.jl

# --- comment / verbatim / spaceless / autoescape ----------------------------------------

function tag_comment(p::Parser, t::Token)
    parse_nodes(p, ["endcomment"])
    nothing
end

struct VerbatimNode <: Node
    s::String
end
function tag_verbatim(p::Parser, t::Token)
    endname = "end" * t.contents
    io = IOBuffer()
    while p.pos <= length(p.tokens)
        tok = p.tokens[p.pos]
        p.pos += 1
        tok.kind === :block && tok.contents == endname && return VerbatimNode(String(take!(io)))
        print(io, tok.contents)
    end
    throw(TemplateSyntaxError("unclosed verbatim tag"))
end
render!(io::IO, n::VerbatimNode, ::Context) = write(io, n.s)

struct SpacelessNode <: Node
    nodes::Vector{Node}
end
child_nodelists(n::SpacelessNode) = (n.nodes,)
tag_spaceless(p, t) = SpacelessNode(first(parse_nodes(p, ["endspaceless"])))
render!(io::IO, n::SpacelessNode, ctx::Context) =
    write(io, replace(strip(render_nodes(n.nodes, ctx)), r">\s+<" => "><"))

struct AutoescapeNode <: Node
    on::Bool
    nodes::Vector{Node}
end
child_nodelists(n::AutoescapeNode) = (n.nodes,)
function tag_autoescape(p, t)
    bits = split(t.contents)
    (length(bits) == 2 && bits[2] in ("on", "off")) || throw(TemplateSyntaxError("'autoescape' argument should be 'on' or 'off'"))
    AutoescapeNode(bits[2] == "on", first(parse_nodes(p, ["endautoescape"])))
end
function render!(io::IO, n::AutoescapeNode, ctx::Context)
    old = ctx.autoescape
    ctx.autoescape = n.on
    try
        render_nodes(io, n.nodes, ctx)
    finally
        ctx.autoescape = old
    end
end

# --- cycle / firstof / now --------------------------------------------------------------

struct CycleNode <: Node
    values::Vector{FilterExpr}
    asvar::Union{Nothing,String}
    silent::Bool
end
function tag_cycle(p, t)
    bits = split_contents(t.contents)[2:end]
    silent = !isempty(bits) && bits[end] == "silent"
    silent && pop!(bits)
    asvar = nothing
    if length(bits) >= 3 && bits[end-1] == "as"
        asvar = bits[end]
        bits = bits[1:end-2]
    end
    isempty(bits) && throw(TemplateSyntaxError("'cycle' tag requires at least one argument"))
    CycleNode([parse_filter_expr(b) for b in bits], asvar, silent)
end
function render!(io::IO, n::CycleNode, ctx::Context)
    counters = get!(Dict{UInt,Int}, ctx.render_ctx, :cycles)
    k = objectid(n)
    ctx.render_ctx[:last_cycle] = k                                   # for {% resetcycle %}
    n.asvar === nothing || (get!(Dict{String,UInt}, ctx.render_ctx, :cycle_names)[n.asvar] = k)
    i = get(counters, k, 0)
    counters[k] = i + 1
    v = eval_fe(n.values[mod(i, length(n.values))+1], ctx)
    n.asvar === nothing || (ctx[n.asvar] = v)
    n.silent || write(io, ctx.autoescape ? conditional_escape(v) : display_string(v))
end

struct FirstOfNode <: Node
    values::Vector{FilterExpr}
end
tag_firstof(p, t) = FirstOfNode([parse_filter_expr(b) for b in split_contents(t.contents)[2:end]])
function render!(io::IO, n::FirstOfNode, ctx::Context)
    for fe in n.values
        v = eval_fe(fe, ctx)
        if truthy(v)
            write(io, ctx.autoescape ? conditional_escape(v) : display_string(v))
            return
        end
    end
end

struct NowNode <: Node
    fmt::FilterExpr
end
tag_now(p, t) = NowNode(parse_filter_expr(split_contents(t.contents)[2]))
render!(io::IO, n::NowNode, ctx::Context) =
    write(io, escape_html(format_date(now(), display_string(eval_fe(n.fmt, ctx)))))

for (name, f) in (
    "if" => tag_if, "for" => tag_for, "block" => tag_block, "extends" => tag_extends,
    "include" => tag_include, "with" => tag_with, "url" => tag_url, "csrf_token" => tag_csrf_token,
    "static" => tag_static, "load" => tag_load, "comment" => tag_comment, "verbatim" => tag_verbatim,
    "spaceless" => tag_spaceless, "autoescape" => tag_autoescape, "cycle" => tag_cycle,
    "firstof" => tag_firstof, "now" => tag_now)
    TAGS[name] = f
end

# ======================================================================================
# Built-in filters
# ======================================================================================

str(x) = display_string(x)
tonum(x::Number) = x
tonum(x) = (s = str(x); something(tryparse(Int, s), tryparse(Float64, s), 0))

const MONTH_ABBR_AP = ["Jan.", "Feb.", "March", "April", "May", "June", "July", "Aug.", "Sept.", "Oct.", "Nov.", "Dec."]

todatetime(x::DateTime) = x
todatetime(x::Date) = DateTime(x)
function todatetime(x)
    x === nothing && return nothing
    s = str(x)
    for f in (dateformat"yyyy-mm-ddTHH:MM:SS.s", dateformat"yyyy-mm-ddTHH:MM:SS", dateformat"yyyy-mm-dd HH:MM:SS", dateformat"yyyy-mm-dd")
        d = tryparse(DateTime, s, f)
        d !== nothing && return d
    end
    nothing
end

"Format a date with Django `date` filter format characters."
function format_date(d, fmt::AbstractString)
    dt = todatetime(d)
    dt === nothing && return ""
    z = d isa PinnedTime ? d.z : d isa TimeZones.ZonedDateTime ? (get(task_local_storage(), :juango_localtime_off, false) ? d : localtime(d)) : nothing
    io = IOBuffer()
    esc = false
    for c in fmt
        if esc
            print(io, c)
            esc = false
            continue
        end
        h = hour(dt)
        h12 = h % 12 == 0 ? 12 : h % 12
        if c == '\\'
            esc = true
        elseif c == 'd'; print(io, lpad(day(dt), 2, '0'))
        elseif c == 'j'; print(io, day(dt))
        elseif c == 'D'; print(io, gettext(dayabbr(dt)))
        elseif c == 'l'; print(io, gettext(dayname(dt)))
        elseif c == 'm'; print(io, lpad(month(dt), 2, '0'))
        elseif c == 'n'; print(io, month(dt))
        elseif c == 'M'; print(io, pgettext("abbrev. month", monthabbr(dt)))
        elseif c == 'b'; print(io, lowercase(pgettext("abbrev. month", monthabbr(dt))))
        elseif c == 'F'; print(io, gettext(monthname(dt)))
        elseif c == 'N'; print(io, pgettext("alt. month", MONTH_ABBR_AP[month(dt)]))
        elseif c == 'y'; print(io, lpad(year(dt) % 100, 2, '0'))
        elseif c == 'Y'; print(io, year(dt))
        elseif c == 'H'; print(io, lpad(h, 2, '0'))
        elseif c == 'G'; print(io, h)
        elseif c == 'h'; print(io, lpad(h12, 2, '0'))
        elseif c == 'g'; print(io, h12)
        elseif c == 'i'; print(io, lpad(minute(dt), 2, '0'))
        elseif c == 's'; print(io, lpad(second(dt), 2, '0'))
        elseif c == 'A'; print(io, h < 12 ? "AM" : "PM")
        elseif c == 'a'; print(io, h < 12 ? "a.m." : "p.m.")
        elseif c == 'U'; print(io, round(Int, datetime2unix(z === nothing ? dt : DateTime(TimeZones.astimezone(z, UTC_TZ)))))
        elseif c == 'e'; z === nothing || print(io, TimeZones.timezone(z))
        elseif c == 'T'; z === nothing || print(io, string(z.zone.name))
        elseif c == 'O'
            if z !== nothing
                off = Dates.value(Second(z.zone.offset.std + z.zone.offset.dst))
                print(io, off < 0 ? "-" : "+", lpad(abs(off) ÷ 3600, 2, '0'), lpad((abs(off) % 3600) ÷ 60, 2, '0'))
            end
        elseif c == 'S'
            dd = day(dt)
            print(io, dd in (11, 12, 13) ? "th" : dd % 10 == 1 ? "st" : dd % 10 == 2 ? "nd" : dd % 10 == 3 ? "rd" : "th")
        else
            print(io, c)
        end
    end
    String(take!(io))
end

function timesince(d, ref = nothing)
    if d isa TimeZones.ZonedDateTime        # compare aware times in UTC
        dt = DateTime(TimeZones.astimezone(d, UTC_TZ))
        ref = ref === nothing ? now(Dates.UTC) : ref isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(ref, UTC_TZ)) : ref
    else
        dt = todatetime(d)
        ref = something(ref, now())
    end
    dt === nothing && return ""
    secs = max(0, round(Int, Dates.value(ref - dt) / 1000))
    for (n, unit) in ((365 * 86400, "year"), (30 * 86400, "month"), (7 * 86400, "week"),
                      (86400, "day"), (3600, "hour"), (60, "minute"))
        if secs >= n
            k = secs ÷ n
            return "$k $(unit)$(k == 1 ? "" : "s")"
        end
    end
    "0 minutes"
end

function linebreaks_html(s::AbstractString, autoescape::Bool)
    s = replace(s, "\r\n" => "\n")
    paras = split(s, r"\n{2,}")
    join(["<p>" * replace(autoescape ? escape_html(strip(p)) : strip(p), "\n" => "<br>") * "</p>" for p in paras if !isempty(strip(p))], "\n\n")
end

let F = register_filter!
    F("upper", (v, _) -> uppercase(str(v)); is_safe = true)
    F("lower", (v, _) -> lowercase(str(v)); is_safe = true)
    F("title", (v, _) -> titlecase(str(v)); is_safe = true)
    F("capfirst", (v, _) -> uppercasefirst(str(v)); is_safe = true)
    F("length", (v, _) -> v === nothing ? 0 : v isa SafeString ? length(v.s) : length(v isa QuerySet ? collect(v) : v))
    F("default", (v, a) -> truthy(v) ? v : a)
    F("default_if_none", (v, a) -> v === nothing ? a : v)
    F("safe", (v, _) -> SafeString(str(v)))
    F("escape", (v, _) -> SafeString(conditional_escape(v)))     # already-safe text isn't escaped twice
    F("force_escape", (v, _) -> SafeString(escape_html(str(v))))
    F("striptags", (v, _) -> replace(str(v), r"<[^>]*>" => ""))
    F("truncatechars", (v, a) -> (s = str(v); n = tonum(a); length(s) <= n ? s : first(s, max(n - 1, 0)) * "…"); is_safe = true)
    F("truncatewords", (v, a) -> (w = split(str(v)); n = tonum(a); length(w) <= n ? join(w, " ") : join(w[1:n], " ") * " …"); is_safe = true)
    F("join", (v, a, ae) -> SafeString(join([ae ? conditional_escape(x) : str(x) for x in to_iterable(v)],
                                            ae ? conditional_escape(something(a, "")) : str(a)));
      needs_autoescape = true)
    F("first", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : first(it)))
    F("last", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : last(it)))
    F("random", (v, _) -> (it = to_iterable(v); isempty(it) ? nothing : rand(it)))
    F("slice", (v, a) -> begin
        it = v isa AbstractString || v isa SafeString ? str(v) : to_iterable(v)
        m = match(r"^(-?\d*):(-?\d*)$", str(a))
        m === nothing && return it
        n = length(it)
        lo = isempty(m[1]) ? 0 : parse(Int, m[1]); lo < 0 && (lo += n)
        hi = isempty(m[2]) ? n : parse(Int, m[2]); hi < 0 && (hi += n)
        lo, hi = clamp(lo, 0, n), clamp(hi, 0, n)
        it isa AbstractString ? join(collect(it)[lo+1:hi]) : it[lo+1:hi]
    end)
    F("date", (v, a) -> format_date(v, a === nothing ? get_format().date : str(a)))
    F("time", (v, a) -> format_date(v, a === nothing ? "g:i a" : str(a)))
    F("timesince", (v, _) -> timesince(v))
    F("linebreaksbr", (v, _, ae) -> SafeString(replace(ae && !(v isa SafeString) ? escape_html(str(v)) : str(v), r"\r?\n" => "<br>"));
      needs_autoescape = true)
    F("linebreaks", (v, _, ae) -> SafeString(linebreaks_html(str(v), ae && !(v isa SafeString))); needs_autoescape = true)
    F("pluralize", (v, a) -> begin
        n = v isa Number ? v : (v isa AbstractString || v === nothing) ? tonum(v) : length(to_iterable(v))
        sfx = a === nothing ? ["", "s"] : split(str(a), ',')
        length(sfx) == 1 && (sfx = ["", sfx[1]])
        n == 1 ? sfx[1] : sfx[2]
    end)
    F("add", (v, a) -> begin
        try
            x, y = tonum(v), tonum(a)
            (v isa Number || tryparse(Float64, str(v)) !== nothing) && (a isa Number || tryparse(Float64, str(a)) !== nothing) && return x + y
        catch
        end
        (v isa AbstractVector && a isa AbstractVector) ? vcat(v, a) : str(v) * str(a)
    end)
    F("yesno", (v, a) -> begin
        opts = split(a === nothing ? "yes,no,maybe" : str(a), ',')
        v === nothing ? (length(opts) > 2 ? opts[3] : opts[2]) : truthy(v) ? opts[1] : opts[2]
    end)
    F("slugify", (v, _) -> slugify(str(v)); is_safe = true)
    F("urlencode", (v, _) -> urlquote(str(v)))
    F("floatformat", (v, a) -> begin
        x = Float64(tonum(v))
        d = a === nothing ? -1 : tonum(a)
        if d < 0
            isinteger(x) ? string(round(Int, x)) : Printf.format(Printf.Format("%.$(abs(d))f"), x)
        else
            Printf.format(Printf.Format("%.$(d)f"), x)
        end
    end)
    F("cut", (v, a) -> replace(str(v), str(a) => ""))
    F("wordcount", (v, _) -> length(split(str(v))))
    F("divisibleby", (v, a) -> tonum(v) % tonum(a) == 0)
    F("stringformat", (v, a) -> Printf.format(Printf.Format("%" * str(a)), v))
    F("center", (v, a) -> (s = str(v); n = tonum(a); p = max(n - length(s), 0); " "^(p ÷ 2) * s * " "^(p - p ÷ 2)))
    F("ljust", (v, a) -> rpad(str(v), tonum(a)))
    F("rjust", (v, a) -> lpad(str(v), tonum(a)))
    F("make_list", (v, _) -> collect(str(v)))
    F("dictsort", (v, a) -> sort(collect(v); by = x -> getattr(x, str(a))))
    F("dictsortreversed", (v, a) -> sort(collect(v); by = x -> getattr(x, str(a)), rev = true))
    F("json_script", (v, a) -> SafeString("<script id=\"" * escape_html(str(a)) * "\" type=\"application/json\">" *
                                          replace(JSON.json(v), "<" => "\\u003C", ">" => "\\u003E", "&" => "\\u0026") * "</script>"))
    F("urlize", (v, _, ae) -> SafeString(replace(ae ? escape_html(str(v)) : str(v),
                                                 r"(https?://[^\s<]+)" => s"<a href=\"\1\" rel=\"nofollow\">\1</a>"));
      needs_autoescape = true)
    F("filesizeformat", (v, _) -> begin
        b = Float64(tonum(v))
        for (u, n) in (("PB", 1024.0^5), ("TB", 1024.0^4), ("GB", 1024.0^3), ("MB", 1024.0^2), ("KB", 1024.0))
            b >= n && return @sprintf("%.1f %s", b / n, u)
        end
        "$(round(Int, b)) bytes"
    end)
end
