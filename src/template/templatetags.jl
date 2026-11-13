# More template tags and filters, custom tag libraries, partials -------------------------------------------
#
# Tags: ifchanged, regroup, widthratio, templatetag, querystring, filter, lorem, resetcycle, debug,
# partialdef / partial. Libraries:
#
#     lib = TagLibrary("shop_tags")
#     price(amount; currency = "€") = "$currency$(round(amount; digits = 2))"
#     simple_tag!(price, lib, "price")
#     inclusion_tag!(lib, "cart_summary", "shop/cart_summary.html"; takes_context = true) do ctx
#         Dict("items" => ctx["cart"].items)
#     end
#     filter!(lib, "cents", (v, _) -> round(Int, 100v))
#
#     {% load shop_tags %}{% price item.cost currency="£" %} {% price 3 as p %}{{ p }} {% cart_summary %} {{ x|cents }}

# --- ifchanged ---

struct IfChangedNode <: Node
    exprs::Vector{FilterExpr}
    body::Vector{Node}
    otherwise::Vector{Node}
end
child_nodelists(n::IfChangedNode) = (n.body, n.otherwise)
function tag_ifchanged(p::Parser, t::Token)
    exprs = [parse_filter_expr(b) for b in split_contents(t.contents)[2:end]]
    body, endtag = parse_nodes(p, ["else", "endifchanged"])
    otherwise = endtag == "else" ? first(parse_nodes(p, ["endifchanged"])) : Node[]
    IfChangedNode(exprs, body, otherwise)
end
function render!(io::IO, n::IfChangedNode, ctx::Context)
    state = get!(Dict{UInt,Any}, ctx.render_ctx, :ifchanged)
    loop = lookup(ctx, "forloop")
    first_iteration = loop isa ForLoop && loop.first
    rendered = isempty(n.exprs) ? render_nodes(n.body, ctx) : nothing
    current = isempty(n.exprs) ? rendered : Any[eval_fe(fe, ctx) for fe in n.exprs]
    k = objectid(n)
    if first_iteration || !haskey(state, k) || state[k] != current
        state[k] = current
        rendered === nothing ? render_nodes(io, n.body, ctx) : write(io, rendered)
    else
        render_nodes(io, n.otherwise, ctx)
    end
end

# --- regroup ---

struct RegroupNode <: Node
    list::FilterExpr
    by::FilterExpr
    asvar::String
end
function tag_regroup(p::Parser, t::Token)
    m = match(r"^regroup\s+(.+?)\s+by\s+(.+?)\s+as\s+(\w+)$"s, t.contents)
    m === nothing && throw(TemplateSyntaxError("'regroup' should be 'regroup <list> by <attribute> as <name>'"))
    RegroupNode(parse_filter_expr(m[1]), parse_filter_expr("__regroup_item." * m[2]), m[3])
end
function render!(io::IO, n::RegroupNode, ctx::Context)
    groups = Dict{String,Any}[]
    for item in to_iterable(eval_fe(n.list, ctx))
        key = with_scope(() -> eval_fe(n.by, ctx), ctx, Dict{String,Any}("__regroup_item" => item))
        if !isempty(groups) && isequal(groups[end]["grouper"], key)
            push!(groups[end]["list"], item)
        else
            push!(groups, Dict{String,Any}("grouper" => key, "list" => Any[item]))
        end
    end
    ctx[n.asvar] = groups
    nothing
end

# --- widthratio / templatetag / lorem / debug ---

struct WidthRatioNode <: Node
    value::FilterExpr
    max::FilterExpr
    width::FilterExpr
    asvar::Union{Nothing,String}
end
function tag_widthratio(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    asvar = length(bits) == 5 && bits[4] == "as" ? bits[5] : nothing
    asvar === nothing || (bits = bits[1:3])
    length(bits) == 3 || throw(TemplateSyntaxError("'widthratio' takes three arguments (and optionally 'as name')"))
    WidthRatioNode(parse_filter_expr(bits[1]), parse_filter_expr(bits[2]), parse_filter_expr(bits[3]), asvar)
end
function render!(io::IO, n::WidthRatioNode, ctx::Context)
    v, m, w = (Float64(tonum(eval_fe(fe, ctx))) for fe in (n.value, n.max, n.width))
    r = m == 0 ? "0" : string(round(Int, v / m * w, RoundNearestTiesAway))
    n.asvar === nothing ? write(io, r) : (ctx[n.asvar] = r; nothing)
end

const TEMPLATETAG_BITS = Dict("openblock" => "{%", "closeblock" => "%}", "openvariable" => "{{", "closevariable" => "}}",
                              "openbrace" => "{", "closebrace" => "}", "opencomment" => "{#", "closecomment" => "#}")
function tag_templatetag(p::Parser, t::Token)
    bits = split_contents(t.contents)
    (length(bits) == 2 && haskey(TEMPLATETAG_BITS, bits[2])) ||
        throw(TemplateSyntaxError("'templatetag' takes one of: $(join(sort(collect(keys(TEMPLATETAG_BITS))), ", "))"))
    TextNode(TEMPLATETAG_BITS[bits[2]])
end

const LOREM_COMMON_P = "Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et " *
    "dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo " *
    "consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. " *
    "Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
const LOREM_COMMON_WORDS = split("lorem ipsum dolor sit amet consectetur adipisicing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua")
const LOREM_WORDS = split("exercitationem perferendis perspiciatis laborum eveniet sunt iure nam nobis eum cum officiis excepturi " *
    "odio consectetur quasi aut quisquam vel eligendi itaque non odit tempore quaerat dignissimos facilis neque nihil expedita " *
    "vitae vero ipsum nisi animi cumque pariatur velit modi natus iusto eaque sequi illo sed ex et voluptatibus tempora veritatis " *
    "ratione assumenda incidunt nostrum placeat aliquid fuga provident praesentium rem necessitatibus suscipit adipisci quidem " *
    "possimus voluptas debitis sint accusantium unde sapiente voluptate qui aspernatur laudantium soluta amet quo aliquam saepe " *
    "culpa libero ipsa dicta reiciendis nesciunt doloribus autem impedit minima maiores repudiandae ipsam obcaecati ullam enim " *
    "totam delectus ducimus quis voluptates dolores molestiae harum dolorem quia voluptatem molestias magni distinctio omnis illum " *
    "dolorum voluptatum ea quas quam corporis quae blanditiis atque deserunt laboriosam earum consequuntur hic cupiditate quibusdam " *
    "accusamus ut rerum error minus eius ab ad nemo fugit officia at in id quos reprehenderit numquam iste fugiat sit inventore " *
    "beatae repellendus magnam recusandae quod explicabo doloremque aperiam consequatur asperiores commodi optio dolor labore " *
    "temporibus repellat veniam architecto est esse mollitia nulla a similique eos alias dolore tenetur deleniti porro facere " *
    "maxime corrupti")

lorem_words(n::Int, common::Bool) = common && n <= length(LOREM_COMMON_WORDS) ? join(LOREM_COMMON_WORDS[1:n], " ") :
    join(vcat(common ? LOREM_COMMON_WORDS : SubString{String}[], [rand(LOREM_WORDS) for _ in 1:(n - (common ? length(LOREM_COMMON_WORDS) : 0))]), " ")
function lorem_sentence()
    sections = [join(rand(LOREM_WORDS, rand(3:12)), " ") for _ in 1:rand(1:5)]
    s = join(sections, ", ")
    uppercasefirst(s) * rand(("?", "."))
end
lorem_paragraph() = join([lorem_sentence() for _ in 1:rand(1:4)], " ")
lorem_paragraphs(n::Int, common::Bool) = [i == 1 && common ? LOREM_COMMON_P : lorem_paragraph() for i in 1:n]

struct LoremNode <: Node
    count::FilterExpr
    method::String
    common::Bool
end
function tag_lorem(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    common = !(!isempty(bits) && bits[end] == "random")
    common || pop!(bits)
    method = !isempty(bits) && bits[end] in ("w", "p", "b") ? pop!(bits) : "b"
    length(bits) <= 1 || throw(TemplateSyntaxError("incorrect format for 'lorem' tag"))
    LoremNode(parse_filter_expr(isempty(bits) ? "1" : bits[1]), method, common)
end
function render!(io::IO, n::LoremNode, ctx::Context)
    k = Int(tonum(eval_fe(n.count, ctx)))
    n.method == "w" && return write(io, lorem_words(k, n.common))
    ps = lorem_paragraphs(k, n.common)
    write(io, n.method == "p" ? join(["<p>$x</p>" for x in ps], "\n\n") : join(ps, "\n\n"))
end

struct DebugNode <: Node end
tag_debug(p::Parser, t::Token) = DebugNode()
function render!(io::IO, ::DebugNode, ctx::Context)
    merged = Dict{String,Any}()
    for d in ctx.stack
        merge!(merged, d)
    end
    lines = ["$(k) => $(repr(v; context = :limit => true))" for (k, v) in sort(collect(merged); by = first)]
    write(io, "<pre>", escape_html(join(lines, "\n")), "</pre>")
end

# --- resetcycle ---

struct ResetCycleNode <: Node
    name::Union{Nothing,String}
end
function tag_resetcycle(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) <= 2 || throw(TemplateSyntaxError("'resetcycle' takes at most one argument"))
    ResetCycleNode(length(bits) == 2 ? bits[2] : nothing)
end
function render!(io::IO, n::ResetCycleNode, ctx::Context)
    counters = get!(Dict{UInt,Int}, ctx.render_ctx, :cycles)
    k = n.name === nothing ? get(ctx.render_ctx, :last_cycle, nothing) :
        get(get(ctx.render_ctx, :cycle_names, Dict{String,UInt}()), n.name, nothing)
    k === nothing || (counters[k] = 0)
    nothing
end

# --- filter / querystring ---

struct FilterBlockNode <: Node
    fe::FilterExpr
    body::Vector{Node}
end
child_nodelists(n::FilterBlockNode) = (n.body,)
function tag_filter(p::Parser, t::Token)
    bits = split(t.contents; limit = 2)
    length(bits) == 2 || throw(TemplateSyntaxError("'filter' needs at least one filter"))
    any(f -> strip(first(split(f, ':'))) in ("escape", "safe"), split(bits[2], '|')) &&
        throw(TemplateSyntaxError("use {% autoescape %} instead of the 'escape' or 'safe' filters in 'filter'"))
    FilterBlockNode(parse_filter_expr("__filter_content|" * bits[2]), first(parse_nodes(p, ["endfilter"])))
end
function render!(io::IO, n::FilterBlockNode, ctx::Context)
    content = render_nodes(n.body, ctx)
    v = with_scope(() -> eval_fe(n.fe, ctx), ctx, Dict{String,Any}("__filter_content" => SafeString(content)))
    write(io, display_string(v))          # the content was escaped as it was rendered
end

"""
`{% querystring page=2 sort=None %}`: the current request's query string with those changes
(`None` removes a key; a list gives repeated values), as `?a=1&b=2`. An optional first
argument (a dict or QueryDict) replaces the request's parameters.
"""
struct QueryStringNode <: Node
    base::Union{Nothing,FilterExpr}
    changes::Vector{Tuple{String,FilterExpr}}
    asvar::Union{Nothing,String}
end
function tag_querystring(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    asvar = length(bits) >= 2 && bits[end-1] == "as" ? bits[end] : nothing
    asvar === nothing || (bits = bits[1:end-2])
    base = !isempty(bits) && !occursin('=', bits[1]) ? parse_filter_expr(popfirst!(bits)) : nothing
    QueryStringNode(base, parse_kwargs(bits), asvar)
end
function render!(io::IO, n::QueryStringNode, ctx::Context)
    params = Dict{String,Vector{String}}()
    order = String[]
    src = n.base !== nothing ? eval_fe(n.base, ctx) : ctx.request === nothing ? nothing : ctx.request.GET
    if src isa QueryDict
        for k in keys(src.data)
            params[k] = copy(src.data[k]); push!(order, k)
        end
    elseif src isa AbstractDict
        for (k, v) in src
            params[string(k)] = v isa AbstractVector ? [display_string(x) for x in v] : [display_string(v)]; push!(order, string(k))
        end
    end
    sort!(order)
    for (k, fe) in n.changes
        v = eval_fe(fe, ctx)
        if v === nothing || v isa Undefined
            delete!(params, k)
        else
            params[k] = v isa AbstractVector ? [display_string(x) for x in v] : [display_string(v)]
            k in order || push!(order, k)
        end
    end
    q = join(["$(URIs.escapeuri(k))=$(URIs.escapeuri(v))" for k in order if haskey(params, k) for v in params[k]], "&")
    out = isempty(q) ? "?" : "?" * q
    n.asvar === nothing ? write(io, ctx.autoescape ? escape_html(out) : out) : (ctx[n.asvar] = out; nothing)
end

# --- partials: {% partialdef name [inline] %}...{% endpartialdef %} and {% partial name %} ---

struct PartialDefNode <: Node
    name::String
    inline::Bool
    body::Vector{Node}
end
child_nodelists(n::PartialDefNode) = (n.body,)
function tag_partialdef(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    (1 <= length(bits) <= 2 && (length(bits) == 1 || bits[2] == "inline")) ||
        throw(TemplateSyntaxError("'partialdef' takes a name and optionally 'inline'"))
    body, _ = parse_nodes(p, ["endpartialdef", "endpartialdef $(bits[1])"])
    partials = get!(Dict{String,PartialDefNode}, p.extra, :partials)
    haskey(partials, bits[1]) && throw(TemplateSyntaxError("partial '$(bits[1])' is defined twice"))
    partials[bits[1]] = PartialDefNode(bits[1], length(bits) == 2, body)
end
render!(io::IO, n::PartialDefNode, ctx::Context) = n.inline ? render_nodes(io, n.body, ctx) : nothing

struct PartialNode <: Node
    name::String
    partials::Dict{String,PartialDefNode}     # the template's own, filled in as it is parsed
    template::String
end
function tag_partial(p::Parser, t::Token)
    bits = split_contents(t.contents)
    length(bits) == 2 || throw(TemplateSyntaxError("'partial' takes one argument: the partial's name"))
    PartialNode(bits[2], get!(Dict{String,PartialDefNode}, p.extra, :partials), p.name)
end
function render!(io::IO, n::PartialNode, ctx::Context)
    d = get(n.partials, n.name, nothing)
    d === nothing && throw(TemplateSyntaxError("partial '$(n.name)' is not defined in template '$(n.template)'"))
    render_nodes(io, d.body, ctx)
end

"`get_template(\"page.html#name\")`: just that partial of the template, as a Template."
function partial_template(fullname::AbstractString)
    base, part = split(fullname, '#'; limit = 2)
    t = get_template(base)
    for d in nodes_of_type(PartialDefNode, t.nodes)
        d.name == part && return Template(String(fullname), d.body, t.origin)
    end
    throw(TemplateDoesNotExist("partial '$part' not found in template '$base'", String[]))
end

# --- custom tag libraries ---

"A set of custom tags and filters that templates load with `{% load name %}`."
struct TagLibrary
    name::String
    tags::Dict{String,Function}
    filters::Dict{String,TemplateFilter}
end
const TAG_LIBRARIES = Dict{String,TagLibrary}()
"Built-in library names: their tags are always available, so `{% load %}` only adds their filters (if any)."
const BUILTIN_LIBRARIES = Set(["static", "i18n", "l10n", "tz", "cache", "humanize", "admin_urls", "admin_list", "admin_modify"])

"`TagLibrary(\"name\")`: create (or replace) the library loaded by `{% load name %}`."
function TagLibrary(name::AbstractString)
    lib = TagLibrary(String(name), Dict{String,Function}(), Dict{String,TemplateFilter}())
    TAG_LIBRARIES[lib.name] = lib
    lib
end

"Register a full tag in a library: `f(parser, token) -> Node`, as for `register_tag!`."
tag!(lib::TagLibrary, name, f) = (lib.tags[string(name)] = f; lib)
tag!(f::Function, lib::TagLibrary, name) = tag!(lib, name, f)

"""
    filter!(lib, name, f; is_safe=false, needs_autoescape=false)

Register a filter that comes with the library: templates use it after `{% load lib %}`
(or `{% load name from lib %}`). Global filters are registered with `register_filter!`.
"""
function Base.filter!(lib::TagLibrary, name, f; is_safe = false, needs_autoescape = false)
    lib.filters[string(name)] = TemplateFilter(f, is_safe, needs_autoescape)
    clear_template_cache!()
    lib
end
Base.filter!(f::Function, lib::TagLibrary, name; kw...) = filter!(lib, name, f; kw...)

"Arguments of a simple/inclusion tag: positional and `name=value`, then an optional `as var`."
function parse_tag_args(bits)
    asvar = length(bits) >= 2 && bits[end-1] == "as" ? bits[end] : nothing
    asvar === nothing || (bits = bits[1:end-2])
    args = FilterExpr[]
    kwargs = Tuple{String,FilterExpr}[]
    for b in bits
        m = match(r"^(\w+)=(.+)$"s, b)
        m === nothing ? (isempty(kwargs) ? push!(args, parse_filter_expr(b)) :
                         throw(TemplateSyntaxError("positional argument '$b' after keyword arguments"))) :
                        push!(kwargs, (String(m[1]), parse_filter_expr(m[2])))
    end
    args, kwargs, asvar
end
"A tag argument's value; string literals arrive as plain `String`s."
tag_arg(fe::FilterExpr, ctx) = (v = eval_fe(fe, ctx); fe.base isa Literal && isempty(fe.filters) && v isa SafeString ? v.s : v)
eval_tag_args(ctx, args, kwargs) = (Any[tag_arg(a, ctx) for a in args],
                                     (; (Symbol(k) => tag_arg(fe, ctx) for (k, fe) in kwargs)...))

struct SimpleTagNode <: Node
    f::Function
    takes_context::Bool
    args::Vector{FilterExpr}
    kwargs::Vector{Tuple{String,FilterExpr}}
    asvar::Union{Nothing,String}
end
function render!(io::IO, n::SimpleTagNode, ctx::Context)
    a, kw = eval_tag_args(ctx, n.args, n.kwargs)
    v = n.takes_context ? n.f(ctx, a...; kw...) : n.f(a...; kw...)
    n.asvar === nothing ? write(io, ctx.autoescape ? conditional_escape(v) : display_string(v)) : (ctx[n.asvar] = v; nothing)
end

"""
    simple_tag!(f, lib, name; takes_context=false)

`{% name arg1 arg2 key=value [as var] %}` calls `f(arg1, arg2; key=value)` (with the
template `Context` first when `takes_context`) and outputs the result, escaped unless it
is a `SafeString`; `as var` stores it instead.
"""
function simple_tag!(f::Function, lib::TagLibrary, name; takes_context = false)
    tag!(lib, name, (p, t) -> SimpleTagNode(f, takes_context, parse_tag_args(split_contents(t.contents)[2:end])...))
end

struct InclusionTagNode <: Node
    f::Function
    template::String
    takes_context::Bool
    args::Vector{FilterExpr}
    kwargs::Vector{Tuple{String,FilterExpr}}
end
function render!(io::IO, n::InclusionTagNode, ctx::Context)
    a, kw = eval_tag_args(ctx, n.args, n.kwargs)
    d = to_context_dict(n.takes_context ? n.f(ctx, a...; kw...) : n.f(a...; kw...))
    t = get_template(n.template)
    sub = Context(d; request = ctx.request)
    sub.autoescape = ctx.autoescape
    haskey(d, "csrf_token") || (tok = lookup(ctx, "csrf_token"); tok === UNDEF || (sub["csrf_token"] = tok))
    run_nodes(io, t.nodes, sub)
end

"""
    inclusion_tag!(f, lib, name, template; takes_context=false)

`{% name args... %}` renders `template` with the Dict that `f(args...; kwargs...)` returns
(only that: the page's variables aren't visible unless `takes_context` passes them on).
"""
function inclusion_tag!(f::Function, lib::TagLibrary, name, template; takes_context = false)
    tag!(lib, name, function (p, t)
        args, kwargs, asvar = parse_tag_args(split_contents(t.contents)[2:end])
        asvar === nothing || throw(TemplateSyntaxError("inclusion tag '$name' doesn't support 'as'"))
        InclusionTagNode(f, string(template), takes_context, args, kwargs)
    end)
end

"`{% load lib1 lib2 %}` or `{% load name1 name2 from lib %}`: make a library's tags and filters available in this template."
function load_libraries!(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    tags = get!(Dict{String,Function}, p.extra, :tags)
    filters = LOADED_FILTERS[]
    lib(name) = haskey(TAG_LIBRARIES, name) ? TAG_LIBRARIES[name] : name in BUILTIN_LIBRARIES ? nothing :
        throw(TemplateSyntaxError("'$name' is not a registered tag library. Known: " *
                                  join(sort!(collect(union(keys(TAG_LIBRARIES), BUILTIN_LIBRARIES))), ", ")))
    if length(bits) >= 3 && bits[end-1] == "from"
        libname = bits[end]
        l = lib(libname)
        for name in bits[1:end-2]
            if l !== nothing && haskey(l.tags, name)
                tags[name] = l.tags[name]
            elseif l !== nothing && haskey(l.filters, name)
                filters[name] = l.filters[name]
            elseif !(libname in BUILTIN_LIBRARIES && haskey(TAGS, name))    # built-in tags are always loaded
                throw(TemplateSyntaxError("'$name' is not a tag or filter in library '$libname'"))
            end
        end
    else
        for name in bits
            l = lib(name)
            l === nothing && continue
            merge!(tags, l.tags)
            merge!(filters, l.filters)
        end
    end
    nothing
end

"For an unknown filter: which library would provide it."
function load_hint(name::AbstractString)
    for l in values(TAG_LIBRARIES)
        haskey(l.filters, name) && return ". Did you forget {% load $(l.name) %}?"
    end
    ""
end

for (name, f) in ("ifchanged" => tag_ifchanged, "regroup" => tag_regroup, "widthratio" => tag_widthratio,
                  "templatetag" => tag_templatetag, "lorem" => tag_lorem, "debug" => tag_debug,
                  "resetcycle" => tag_resetcycle, "filter" => tag_filter, "querystring" => tag_querystring,
                  "partialdef" => tag_partialdef, "partial" => tag_partial)
    TAGS[name] = f
end

# --- filters ---

const PHONE_LETTERS = Dict(c => d for (d, cs) in ('2' => "abc", '3' => "def", '4' => "ghi", '5' => "jkl", '6' => "mno",
                                                   '7' => "pqrs", '8' => "tuv", '9' => "wxyz") for c in cs)

"Text length of HTML in characters (entities count as one) or words."
function html_text_length(s, words)
    txt = replace(replace(s, r"<[^>]*>" => " "), r"&#?\w{1,8};" => "x")
    words ? length(split(txt)) : length(replace(replace(s, r"<[^>]*>" => ""), r"&#?\w{1,8};" => "x"))
end

"Truncate HTML to `n` characters (the ellipsis included) or `n` words of text, closing the tags left open."
function truncate_html(s::AbstractString, n::Int; words::Bool)
    html_text_length(s, words) <= n && return String(s)
    limit = words ? n : n - 1
    out = IOBuffer()
    open_tags = String[]
    count = 0
    in_word = false
    cut, cut_tags = 0, String[]               # output length and open tags just after the last kept text
    i = firstindex(s)
    while i <= lastindex(s)
        c = s[i]
        if c == '<'
            j = findnext('>', s, i)
            j === nothing && break
            tagtxt = s[i:j]
            m = match(r"^<\s*(/)?\s*([a-zA-Z][a-zA-Z0-9]*)[^>]*?(/)?>$"s, tagtxt)
            if m !== nothing
                name = lowercase(m[2])
                if m[1] !== nothing
                    k = findlast(==(name), open_tags)
                    k === nothing || deleteat!(open_tags, k:length(open_tags))
                elseif m[3] === nothing && !(name in ("br", "hr", "img", "input", "meta", "link", "area", "base", "col", "wbr", "source"))
                    push!(open_tags, name)
                end
            end
            print(out, tagtxt)
            i = nextind(s, j)
            continue
        end
        if words
            if isspace(c)
                in_word = false
            elseif !in_word
                in_word = true
                count += 1
                count > limit && break
            end
        else
            j = c == '&' ? findnext(';', s, i) : nothing
            ent = j !== nothing && j - i <= 9 && occursin(r"^&#?\w+;$", s[i:j])
            count += 1
            count > limit && break
            if ent
                print(out, s[i:j]); i = nextind(s, j)
                cut, cut_tags = position(out), copy(open_tags)
                continue
            end
        end
        print(out, c)
        (words ? !isspace(c) : true) && ((cut, cut_tags) = (position(out), copy(open_tags)))
        i = nextind(s, i)
    end
    res = String(take!(out)[1:cut])
    res = words ? res * " …" : res * "…"
    res * join(["</$t>" for t in Iterators.reverse(cut_tags)])
end

function unordered_list_html(items, ae)
    io = IOBuffer()
    function walk(list, indent)
        i = 1
        list = collect(list)
        while i <= length(list)
            item = list[i]
            sub = i < length(list) && list[i+1] isa AbstractVector ? list[i+1] : nothing
            text = ae ? conditional_escape(item) : display_string(item)
            print(io, "\t"^indent, "<li>", text)
            if sub !== nothing
                print(io, "\n", "\t"^indent, "<ul>\n")
                walk(sub, indent + 1)
                print(io, "\t"^indent, "</ul>\n", "\t"^indent)
                i += 1
            end
            print(io, "</li>\n")
            i += 1
        end
    end
    walk(items, 1)
    rstrip(String(take!(io)), '\n')
end

function wordwrap(s::AbstractString, width::Int)
    out = String[]
    for line in split(s, '\n')
        cur = ""
        for w in split(line, ' ')
            if isempty(cur)
                cur = w
            elseif length(cur) + 1 + length(w) <= width
                cur *= " " * w
            else
                push!(out, cur); cur = w
            end
        end
        push!(out, cur)
    end
    join(out, "\n")
end

let F(name, f; kw...) = register_filter!(name, f; kw...)
    F("phone2numeric", (v, _) -> map(c -> get(PHONE_LETTERS, lowercase(c), c), str(v)))
    F("get_digit", (v, a) -> begin
        n = v isa Integer ? v : tryparse(Int, str(v)); k = tonum(a)
        (n === nothing || !(k isa Integer) || k < 1) && return v
        s = string(abs(n)); k > length(s) ? 0 : parse(Int, s[end-k+1])
    end)
    F("unordered_list", (v, _, ae) -> SafeString(unordered_list_html(to_iterable(v), ae)); needs_autoescape = true)
    F("wordwrap", (v, a) -> wordwrap(str(v), Int(tonum(a))))
    F("iriencode", (v, _) -> join(!isascii(c) || isletter(c) || isdigit(c) || c in "/#%[]=:;\$&()+,!?*@'~._-" ? string(c) :
                                  join("%" * uppercase(string(b, base = 16, pad = 2)) for b in codeunits(string(c))) for c in str(v)))
    F("addslashes", (v, _) -> replace(str(v), "\\" => "\\\\", "\"" => "\\\"", "'" => "\\'"))
    F("escapejs", (v, _) -> join(c in "\\'\"<>&=-;`\u2028\u2029" || c < ' ' ? "\\u" * uppercase(string(UInt32(c), base = 16, pad = 4)) : string(c)
                                 for c in str(v)))
    F("truncatechars_html", (v, a) -> SafeString(truncate_html(str(v), Int(tonum(a)); words = false)); is_safe = true)
    F("truncatewords_html", (v, a) -> SafeString(truncate_html(str(v), Int(tonum(a)); words = true)); is_safe = true)
    F("urlizetrunc", (v, a, ae) -> begin
        n = Int(tonum(a))
        s = ae ? escape_html(str(v)) : str(v)
        SafeString(replace(s, r"(https?://[^\s<]+)" => u -> "<a href=\"$u\" rel=\"nofollow\">" *
                                                         (length(u) > n ? first(u, max(n - 1, 0)) * "…" : u) * "</a>"))
    end; needs_autoescape = true)
    F("timeuntil", (v, a) -> begin
        d = v isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(v, UTC_TZ)) : todatetime(v)
        d === nothing && return ""
        ref = a === nothing ? (v isa TimeZones.ZonedDateTime ? now(Dates.UTC) : now()) :
              a isa TimeZones.ZonedDateTime ? DateTime(TimeZones.astimezone(a, UTC_TZ)) : todatetime(a)
        timesince(ref, d)
    end)
    F("escapeseq", (v, _) -> [SafeString(conditional_escape(x)) for x in to_iterable(v)])
    F("safeseq", (v, _) -> [SafeString(display_string(x)) for x in to_iterable(v)])
    F("linenumbers", (v, _, ae) -> begin
        lines = split(str(v), '\n'); w = length(string(length(lines)))
        SafeString(join(["$(lpad(i, w, '0')). $(ae ? escape_html(l) : l)" for (i, l) in enumerate(lines)], "\n"))
    end; needs_autoescape = true)
    F("pprint", (v, _) -> sprint(show, MIME"text/plain"(), v))
end
