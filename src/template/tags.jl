# Template engine: built-in tags --------------------------------------------------------------

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
    compare(op, eval_cond(c.args[1], ctx), eval_cond(c.args[2], ctx))
end
"A comparison in `{% if %}`: `==`, `!=`, `in`, `not in`, `is`, `is not`, `<`, `>`, `<=`, `>=`."
function compare(op::Symbol, a, b)
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

# Compiled conditions: `and`/`or`/`not` become Julia's, values and comparisons are inlined.
gen_cond(c::CondValue) = (v = gensym("c"); :(let $v = $(gen_fe(c.fe)); $v === $(GlobalRef(_M, :UNDEF)) ? nothing : $v end))
function gen_cond(c::CondOp)
    t(x) = :($(GlobalRef(_M, :truthy))($(gen_cond(x))))
    c.op === :not && return :(!$(t(c.args[1])))
    c.op === :and && return :($(t(c.args[1])) && $(t(c.args[2])))
    c.op === :or && return :($(t(c.args[1])) || $(t(c.args[2])))
    :($(GlobalRef(_M, :compare))($(QuoteNode(c.op)), $(gen_cond(c.args[1])), $(gen_cond(c.args[2]))))
end

function gen_node(n::IfNode)                     # compiled: if / elseif / else
    ex = nothing
    for (cond, nodes) in Iterators.reverse(n.branches)
        body = gen_nodes(nodes)
        ex = cond === nothing ? body :
             Expr(:if, :($(GlobalRef(_M, :truthy))($(gen_cond(cond)))),
                  body, (ex === nothing ? () : (ex,))...)
    end
    something(ex, :nothing)
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
to_iterable(x::AbstractVector) = x            # (callers don't change it)
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
# `{{ forloop.counter }}` is looked up on every iteration: no dispatch on the Val
function getattr(l::ForLoop, part::AbstractString, sym::Symbol, @nospecialize(val), idx::Int)
    sym === :counter && return l.counter
    sym === :counter0 && return l.counter0
    sym === :first && return l.first
    sym === :last && return l.last
    sym === :revcounter && return l.revcounter
    sym === :revcounter0 && return l.revcounter0
    sym === :length && return l.length
    sym === :parentloop && return l.parentloop
    getattr_other(l, part, sym, val, idx)
end

render!(io::IO, n::ForNode, ctx::Context) =
    run_for(io, n, ctx, (io, ctx) -> render_nodes(io, n.body, ctx), (io, ctx) -> render_nodes(io, n.empty, ctx))
gen_node(n::ForNode) =                             # compiled: the body and empty part as closures
    :($(GlobalRef(@__MODULE__, :run_for))(io, $(QuoteNode(n)), ctx,
        (io, ctx) -> ($(gen_nodes(n.body)); nothing), (io, ctx) -> ($(gen_nodes(n.empty)); nothing)))
"A `{% for %}` loop with its body and `{% empty %}` part given as functions `(io, ctx) -> nothing` (compiled or not)."
function run_for(io::IO, n::ForNode, ctx::Context, body, empty)
    raw = eval_fe(n.iterable, ctx)
    items = if raw isa AbstractDict
        length(n.loopvars) == 1 ? collect(keys(raw)) : collect(pairs(raw))
    else
        to_iterable(raw)
    end
    n.reversed && (items = Base.reverse(items))
    if isempty(items)
        empty(io, ctx)
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
            body(io, ctx)
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
            run_nodes(io, n.nodes, ctx)
        else
            b = pop_block!(bc, n.name)
            b === nothing && (b = n)
            ctx["block"] = BlockRef(b, ctx)
            try
                run_nodes(io, b.nodes, ctx)
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
    run_nodes(io, parent.nodes, ctx)
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
        with_scope(() -> run_nodes(io, t.nodes, ctx), ctx, values)
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
