# YAML and XML fixtures -----------------------------------------------------------------------------------
#
# Django's other two serialization formats, written and read without extra packages:
#
#     serialize(:yaml, objects(Post))          - model: blog.post
#                                                pk: 1
#                                                fields:
#                                                  title: Hello
#                                                  tags: [1, 2]
#
#     serialize(:xml, objects(Post))           <django-objects version="1.0">
#                                                <object model="blog.post" pk="1">
#                                                  <field name="title" type="CharField">Hello</field> ...
#
# Both convert to and from the same dicts as the JSON format, so natural keys and every
# field type work the same way. The YAML reader handles block and flow collections, quoted,
# plain and block (`|`, `>`) scalars, and comments; not anchors, aliases or tags.

# --- YAML writer ---

const YAML_SPECIAL = r"^[\s\-?:,\[\]{}#&*!|>'\"%@`]|[:#]\s|:$|\s$|[\n\r\t]"
const YAML_RESERVED = Set(["", "~", "null", "Null", "NULL", "true", "True", "TRUE", "false", "False", "FALSE",
                           "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF"])

"A scalar or a collection as YAML (collections in flow style: JSON is valid YAML)."
function yaml_value(io::IO, v)
    if v === nothing
        print(io, "null")
    elseif v isa Bool || v isa Integer
        print(io, v)
    elseif v isa AbstractFloat
        print(io, isnan(v) ? ".nan" : isinf(v) ? (v > 0 ? ".inf" : "-.inf") : string(v))
    elseif v isa AbstractString
        needs_quotes = v in YAML_RESERVED || occursin(YAML_SPECIAL, v) || yaml_scalar(v) isa Union{Real,Nothing}
        needs_quotes ? JSON.json(io, v) : print(io, v)
    else
        JSON.json(io, v)
    end
end

function yaml_dump(ds::Vector{Dict{String,Any}})
    io = IOBuffer()
    isempty(ds) && return "[]\n"
    for d in ds
        print(io, "- model: ", d["model"], '\n')
        haskey(d, "pk") && (print(io, "  pk: "); yaml_value(io, d["pk"]); print(io, '\n'))
        fs = d["fields"]
        if isempty(fs)
            print(io, "  fields: {}\n")
        else
            print(io, "  fields:\n")
            for k in sort!(collect(keys(fs)))
                print(io, "    ", k, ": ")
                yaml_value(io, fs[k])
                print(io, '\n')
            end
        end
    end
    String(take!(io))
end

# --- YAML reader ---

struct YAMLError <: Exception
    msg::String
end
Base.showerror(io::IO, e::YAMLError) = print(io, "YAMLError: ", e.msg)

"A plain (unquoted) scalar's value: null, a Bool, an Int, a Float64 or the string (YAML 1.2 core schema)."
function yaml_scalar(s::AbstractString)
    s in ("", "~", "null", "Null", "NULL") && return nothing
    s in ("true", "True", "TRUE") && return true
    s in ("false", "False", "FALSE") && return false
    if occursin(r"^[-+]?[0-9]+$", s)
        n = tryparse(Int, s)
        return n === nothing ? parse(BigInt, s) : n
    end
    occursin(r"^0x[0-9a-fA-F]+$", s) && return parse(Int, s[3:end]; base = 16)
    occursin(r"^0o[0-7]+$", s) && return parse(Int, s[3:end]; base = 8)
    occursin(r"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$", s) && return parse(Float64, s)
    s in (".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF") && return Inf
    s in ("-.inf", "-.Inf", "-.INF") && return -Inf
    s in (".nan", ".NaN", ".NAN") && return NaN
    String(s)
end

"Read a double-quoted scalar starting at `s[i] == '\"'`; returns (string, index after the quote)."
function yaml_double_quoted(s::AbstractString, i::Int)
    io = IOBuffer()
    i = nextind(s, i)
    while i <= ncodeunits(s)
        c = s[i]
        if c == '"'
            return String(take!(io)), nextind(s, i)
        elseif c == '\\'
            i = nextind(s, i)
            i > ncodeunits(s) && break
            e = s[i]
            hex(n) = (h = s[nextind(s, i):nextind(s, i, n)]; i = nextind(s, i, n); Char(parse(UInt32, h; base = 16)))
            print(io, e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == '0' ? '\0' : e == 'b' ? '\b' :
                      e == 'f' ? '\f' : e == 'e' ? '\e' : e == 'a' ? '\a' : e == 'v' ? '\v' : e == ' ' ? ' ' :
                      e == '_' ? ' ' : e == 'N' ? '\u0085' : e == 'L' ? ' ' : e == 'P' ? ' ' :
                      e == 'x' ? hex(2) : e == 'u' ? hex(4) : e == 'U' ? hex(8) :
                      e in ('"', '\\', '/') ? e : throw(YAMLError("unknown escape \\$e")))
        else
            print(io, c)
        end
        i = nextind(s, i)
    end
    throw(YAMLError("unterminated double-quoted string"))
end

"Read a single-quoted scalar starting at `s[i] == '\\''` (`''` is a quote)."
function yaml_single_quoted(s::AbstractString, i::Int)
    io = IOBuffer()
    i = nextind(s, i)
    while i <= ncodeunits(s)
        c = s[i]
        if c == '\''
            j = nextind(s, i)
            j <= ncodeunits(s) && s[j] == '\'' || return String(take!(io)), j
            print(io, '\'')
            i = nextind(s, j)
            continue
        end
        print(io, c)
        i = nextind(s, i)
    end
    throw(YAMLError("unterminated single-quoted string"))
end

skip_space(s, i) = (while i <= ncodeunits(s) && s[i] in (' ', '\t', '\n', '\r'); i = nextind(s, i); end; i)

"Parse a flow value (`[...]`, `{...}` or a scalar) at `s[i]`; returns (value, next index)."
function yaml_flow(s::AbstractString, i::Int, inflow::Bool)
    i = skip_space(s, i)
    i > ncodeunits(s) && return nothing, i
    c = s[i]
    if c == '[' || c == '{'
        seq = c == '['
        close = seq ? ']' : '}'
        out = seq ? Any[] : Dict{String,Any}()
        i = skip_space(s, nextind(s, i))
        while true
            i > ncodeunits(s) && throw(YAMLError("unterminated flow collection"))
            s[i] == close && return out, nextind(s, i)
            if seq
                v, i = yaml_flow(s, i, true)
                push!(out, v)
            else
                k, i = yaml_flow(s, i, true)
                i = skip_space(s, i)
                v = nothing
                if i <= ncodeunits(s) && s[i] == ':'
                    v, i = yaml_flow(s, nextind(s, i), true)
                end
                out[string(k)] = v
            end
            i = skip_space(s, i)
            i <= ncodeunits(s) && s[i] == ',' && (i = skip_space(s, nextind(s, i)))
        end
    elseif c == '"'
        return yaml_double_quoted(s, i)
    elseif c == '\''
        return yaml_single_quoted(s, i)
    elseif c in ('&', '*', '!')
        throw(YAMLError("anchors, aliases and tags are not supported"))
    else
        j = i
        while j <= ncodeunits(s)
            ch = s[j]
            inflow && (ch in (',', ']', '}') || (ch == ':' && (j == ncodeunits(s) || s[nextind(s, j)] in (' ', ',', ']', '}')))) && break
            j = nextind(s, j)
        end
        return yaml_scalar(strip(s[i:prevind(s, j)])), j
    end
end

"A whole scalar or flow value written on one (logical) line."
function yaml_inline(s::AbstractString)
    v, i = yaml_flow(s, 1, false)
    skip_space(s, i) > ncodeunits(s) || throw(YAMLError("unexpected text after value: '$(s[i:end])'"))
    v
end

mutable struct YAMLLines
    lines::Vector{Tuple{Int,String}}    # (indent, text without the indent), comments and blank lines removed
    raw::Vector{String}                 # the original lines, for block scalars
    rawidx::Vector{Int}                 # where each entry of `lines` is in `raw`
    pos::Int
end

"Remove a trailing comment (` #...` outside quotes)."
function strip_comment(s::AbstractString)
    q = '\0'
    prev = ' '
    escaped = false
    for (i, c) in pairs(s)
        if q != '\0'
            if escaped
                escaped = false
            elseif q == '"' && c == '\\'
                escaped = true
            elseif c == q
                q = '\0'
            end
        elseif c == '"' || c == '\''
            prev in (' ', '\t', '[', '{', ',', ':', '-') && (q = c)
        elseif c == '#' && prev in (' ', '\t')
            return rstrip(s[1:prevind(s, i)])
        end
        prev = c
    end
    rstrip(s)
end

function YAMLLines(src::AbstractString)
    raw = split(replace(src, "\r\n" => "\n"), '\n')
    lines, idx = Tuple{Int,String}[], Int[]
    for (n, l) in enumerate(raw)
        t = lstrip(l, ' ')
        ind = ncodeunits(l) - ncodeunits(t)
        (isempty(t) || startswith(t, '#')) && continue
        startswith(t, '\t') && throw(YAMLError("tabs can't indent YAML (line $n)"))
        t = strip_comment(t)
        (isempty(t) || t == "---" || t == "..." || startswith(t, "--- ") || startswith(t, '%')) && continue
        push!(lines, (ind, String(t)))
        push!(idx, n)
    end
    YAMLLines(lines, String.(raw), idx, 1)
end
peek_line(y::YAMLLines) = y.pos <= length(y.lines) ? y.lines[y.pos] : (-1, "")
is_seq_item(t) = t == "-" || startswith(t, "- ")

"Split `key: value` at the first `:` followed by a space or the end, outside quotes; `nothing` if not a mapping entry."
function split_key(t::AbstractString)
    if startswith(t, '"') || startswith(t, '\'')
        k, i = startswith(t, '"') ? yaml_double_quoted(t, 1) : yaml_single_quoted(t, 1)
        i <= ncodeunits(t) && t[i] == ':' && (i == ncodeunits(t) || t[nextind(t, i)] == ' ') || return nothing
        return k, strip(t[nextind(t, i):end])
    end
    (startswith(t, '[') || startswith(t, '{')) && return nothing
    m = match(r"^([^#][^:]*?|):(?: (.*)|)$"s, t)
    m === nothing && return nothing
    String(strip(m[1])), m[2] === nothing ? "" : strip(m[2])
end

"Parse the block (mapping, sequence or scalar) whose lines are indented by `ind`."
function yaml_block(y::YAMLLines, ind::Int)
    i, t = peek_line(y)
    is_seq_item(t) ? yaml_seq(y, i) : split_key(t) !== nothing ? yaml_map(y, i) :
        (y.pos += 1; yaml_inline(continued(y, t, ind - 1)))
end

"A value that may continue on more-indented lines (a multi-line flow collection or plain scalar)."
function continued(y::YAMLLines, t::AbstractString, ind::Int)
    parts = [t]
    while (n = peek_line(y))[1] > ind
        push!(parts, n[2])
        y.pos += 1
    end
    startswith(t, '[') || startswith(t, '{') || startswith(t, '"') || startswith(t, '\'') ? join(parts, "\n") : join(parts, " ")
end

function yaml_seq(y::YAMLLines, ind::Int)
    out = Any[]
    while (l = peek_line(y))[1] == ind && is_seq_item(l[2])
        rest = l[2] == "-" ? "" : lstrip(l[2][3:end], ' ')
        if isempty(rest)
            y.pos += 1
            ni = peek_line(y)[1]
            push!(out, ni > ind ? yaml_block(y, ni) : nothing)
        else
            # "- key: value" or "- - x": the item's content starts a block at its own column
            col = ind + ncodeunits(l[2]) - ncodeunits(rest)
            y.lines[y.pos] = (col, String(rest))
            push!(out, is_seq_item(rest) || split_key(rest) !== nothing ? yaml_block(y, col) :
                       yaml_value_at(y, rest, ind))
        end
    end
    out
end

"A value after `key:` or `- ` on the current line (consumes the line and any continuation)."
function yaml_value_at(y::YAMLLines, v::AbstractString, ind::Int)
    rawline = y.rawidx[y.pos]
    y.pos += 1
    m = match(r"^([|>])([-+]?)([1-9]?)([-+]?)$", v)
    m === nothing || return block_scalar(y, rawline, ind, m[1] == "|", m[2] * m[4])
    yaml_inline(continued(y, v, ind))
end

"A literal (`|`) or folded (`>`) block scalar: the more-indented raw lines after `rawline`."
function block_scalar(y::YAMLLines, rawline::Int, ind::Int, literal::Bool, chomp::AbstractString)
    body = String[]
    n = rawline + 1
    bind = -1
    while n <= length(y.raw)
        l = y.raw[n]
        t = lstrip(l, ' ')
        li = ncodeunits(l) - ncodeunits(t)
        if isempty(t)
            push!(body, "")
        else
            li <= ind && break
            bind < 0 && (bind = li)
            li < bind && break
            push!(body, l[bind+1:end])
        end
        n += 1
    end
    while y.pos <= length(y.lines) && y.rawidx[y.pos] < n      # skip the lines we took
        y.pos += 1
    end
    trailing = 0
    while !isempty(body) && isempty(body[end])
        pop!(body); trailing += 1
    end
    text = literal ? join(body, "\n") : fold_lines(body)
    chomp == "-" ? text : chomp == "+" ? text * "\n"^(trailing + 1) : (isempty(text) ? "" : text * "\n")
end
function fold_lines(body)
    io = IOBuffer()
    for (k, l) in enumerate(body)
        k > 1 && print(io, isempty(l) || isempty(body[k-1]) || startswith(l, ' ') ? "\n" : " ")
        print(io, l)
    end
    replace(String(take!(io)), "\n\n" => "\n")
end

function yaml_map(y::YAMLLines, ind::Int)
    out = Dict{String,Any}()
    while (l = peek_line(y))[1] == ind && !is_seq_item(l[2])
        kv = split_key(l[2])
        kv === nothing && throw(YAMLError("expected 'key: value', got '$(l[2])'"))
        k, v = kv
        if isempty(v)
            y.pos += 1
            ni, nt = peek_line(y)
            out[k] = ni > ind ? yaml_block(y, ni) : ni == ind && is_seq_item(nt) ? yaml_seq(y, ind) : nothing
        else
            out[k] = yaml_value_at(y, v, ind)
        end
    end
    out
end

"""
    parse_yaml(src) -> value

Parse a YAML document (the subset fixtures use: block and flow collections, quoted, plain
and block scalars, comments) into `Vector{Any}`, `Dict{String,Any}` and scalars.
"""
function parse_yaml(src::AbstractString)
    y = YAMLLines(src)
    isempty(y.lines) && return nothing
    v = yaml_block(y, y.lines[1][1])
    y.pos <= length(y.lines) && throw(YAMLError("unexpected line: '$(y.lines[y.pos][2])'"))
    v
end

# --- XML writer ---

const XML_JSON_KINDS = (:json, :array, :hstore, :intrange, :daterange, :datetimerange)

"Django's field type names, for the XML `type` attribute."
xml_type(f::Field) = get(XML_TYPE_NAMES, f.kind, titlecase(string(f.kind)) * "Field")
const XML_TYPE_NAMES = Dict(:char => "CharField", :text => "TextField", :int => "IntegerField", :float => "FloatField",
                            :bool => "BooleanField", :date => "DateField", :datetime => "DateTimeField",
                            :email => "EmailField", :slug => "SlugField", :url => "URLField", :json => "JSONField",
                            :uuid => "UUIDField", :file => "FileField", :image => "ImageField", :array => "ArrayField",
                            :hstore => "HStoreField", :citext => "CICharField", :geometry => "GeometryField",
                            :intrange => "BigIntegerRangeField", :daterange => "DateRangeField",
                            :datetimerange => "DateTimeRangeField", :decimal => "DecimalField", :time => "TimeField",
                            :duration => "DurationField", :bigint => "BigIntegerField", :smallint => "SmallIntegerField",
                            :posint => "PositiveIntegerField", :posbigint => "PositiveBigIntegerField",
                            :possmallint => "PositiveSmallIntegerField")

function xml_text(f::Field, v)
    v isa Bool && return v ? "True" : "False"
    f.kind in XML_JSON_KINDS && return JSON.json(v)
    string(v)
end

function xml_ref(io::IO, v)
    if v isa AbstractVector                   # a natural key
        foreach(x -> print(io, "<natural>", xml_escape(string(x)), "</natural>"), v)
    else
        print(io, xml_escape(string(v)))
    end
end

function xml_dump(ds::Vector{Dict{String,Any}}, objs; indent = nothing)
    io = IOBuffer()
    nl(level) = indent === nothing ? nothing : print(io, '\n', ' '^(indent * level))
    print(io, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<django-objects version=\"1.0\">")
    for (d, obj) in zip(ds, objs)
        T = typeof(obj)
        nl(1)
        print(io, "<object model=\"", d["model"], '"')
        haskey(d, "pk") && print(io, " pk=\"", xml_escape(d["pk"] isa AbstractVector ? JSON.json(d["pk"]) : string(d["pk"])), '"')
        print(io, '>')
        fs = d["fields"]
        m2m = Set(f.name for f in modelmeta(concrete_model(T)).m2m)
        for f in vcat(all_fields(T), modelmeta(concrete_model(T)).m2m)
            k = string(f.name)
            haskey(fs, k) || continue
            v = fs[k]
            nl(2)
            if f.name in m2m
                print(io, "<field name=\"", k, "\" rel=\"ManyToManyRel\" to=\"", serial_label(related_model(f)), "\">")
                foreach(x -> (x isa AbstractVector ? (print(io, "<object>"); xml_ref(io, x); print(io, "</object>")) :
                                                     print(io, "<object pk=\"", xml_escape(string(x)), "\"></object>")), v)
            elseif f.kind === :fk
                print(io, "<field name=\"", k, "\" rel=\"ManyToOneRel\" to=\"", serial_label(related_model(f)), "\">")
                v === nothing ? print(io, "<None></None>") : xml_ref(io, v)
            else
                print(io, "<field name=\"", k, "\" type=\"", xml_type(f), "\">")
                v === nothing ? print(io, "<None></None>") : print(io, xml_escape(xml_text(f, v)))
            end
            print(io, "</field>")
        end
        nl(1)
        print(io, "</object>")
    end
    indent === nothing || print(io, '\n')
    print(io, "</django-objects>\n")
    String(take!(io))
end

# --- XML reader (the elements fixtures use: no namespaces or DTDs) ---

struct XMLElement
    tag::String
    attrs::Dict{String,String}
    children::Vector{Any}          # XMLElement or String
end
xml_text(e::XMLElement) = join(c for c in e.children if c isa String)
xml_elements(e::XMLElement, tag) = [c for c in e.children if c isa XMLElement && c.tag == tag]

function xml_unescape(s::AbstractString)
    occursin('&', s) || return String(s)
    replace(s, r"&(#x[0-9a-fA-F]+|#[0-9]+|amp|lt|gt|quot|apos);" => function (m)
        e = m[2:end-1]
        e == "amp" ? "&" : e == "lt" ? "<" : e == "gt" ? ">" : e == "quot" ? "\"" : e == "apos" ? "'" :
        string(Char(startswith(e, "#x") ? parse(UInt32, e[3:end]; base = 16) : parse(UInt32, e[2:end])))
    end)
end

"Parse an XML document into its root `XMLElement`."
function parse_xml(src::AbstractString)
    s = String(src)
    stack = XMLElement[XMLElement("", Dict{String,String}(), Any[])]
    i = 1
    n = ncodeunits(s)
    while i <= n
        j = findnext('<', s, i)
        if j === nothing
            isempty(strip(s[i:end])) || push!(stack[end].children, xml_unescape(s[i:end]))
            break
        end
        j > i && push!(stack[end].children, xml_unescape(s[i:prevind(s, j)]))
        if startswith(SubString(s, j), "<!--")
            k = findnext("-->", s, j)
            k === nothing && throw(ArgumentError("unterminated XML comment"))
            i = last(k) + 1
        elseif startswith(SubString(s, j), "<![CDATA[")
            k = findnext("]]>", s, j)
            k === nothing && throw(ArgumentError("unterminated CDATA section"))
            push!(stack[end].children, s[j+9:first(k)-1])
            i = last(k) + 1
        elseif startswith(SubString(s, j), "<?") || startswith(SubString(s, j), "<!")
            k = findnext('>', s, j)
            k === nothing && throw(ArgumentError("unterminated XML declaration"))
            i = k + 1
        else
            k = findnext('>', s, j)
            k === nothing && throw(ArgumentError("unterminated XML tag"))
            body = s[j+1:k-1]
            if startswith(body, '/')
                tag = strip(body[2:end])
                (length(stack) > 1 && stack[end].tag == tag) || throw(ArgumentError("unexpected </$tag>"))
                e = pop!(stack)
                push!(stack[end].children, e)
            else
                selfclose = endswith(body, '/')
                selfclose && (body = body[1:end-1])
                m = match(r"^([\w:.-]+)", body)
                m === nothing && throw(ArgumentError("bad XML tag <$body>"))
                attrs = Dict{String,String}(String(a[1]) => xml_unescape(something(a[2], a[3]))
                                            for a in eachmatch(r"([\w:.-]+)\s*=\s*(?:\"([^\"]*)\"|'([^']*)')", body[ncodeunits(m[1])+1:end]))
                e = XMLElement(String(m[1]), attrs, Any[])
                selfclose ? push!(stack[end].children, e) : push!(stack, e)
            end
            i = k + 1
        end
    end
    length(stack) == 1 || throw(ArgumentError("unclosed XML element <$(stack[end].tag)>"))
    roots = [c for c in stack[1].children if c isa XMLElement]
    length(roots) == 1 || throw(ArgumentError("an XML document needs one root element"))
    roots[1]
end

"A field's text from XML as the JSON format would have it."
function xml_field_value(f::Field, s::AbstractString)
    k = f.kind
    k === :bool && return s in ("True", "true", "1", "t")
    k in INT_KINDS && return parse(Int, s)
    k === :float && return parse(Float64, s)
    k in XML_JSON_KINDS && k !== :json && return JSON.parse(s)
    String(s)
end

xml_ref_value(e::XMLElement) = (nat = xml_elements(e, "natural"); isempty(nat) ? xml_text(e) : Any[xml_text(x) for x in nat])
function xml_pk(R::Type, s::AbstractString)
    is_auto_pk(pk_kind(R)) ? parse(Int, s) : pk_kind(R) === :composite ? JSON.parse(s) : s
end

"The JSON-format dicts for a `<django-objects>` document."
function xml_objects(src::AbstractString)
    root = parse_xml(src)
    root.tag == "django-objects" || throw(ArgumentError("expected <django-objects>, got <$(root.tag)>"))
    out = Dict{String,Any}[]
    for o in xml_elements(root, "object")
        T = get_model(o.attrs["model"])
        d = Dict{String,Any}("model" => o.attrs["model"])
        haskey(o.attrs, "pk") && (d["pk"] = xml_pk(T, o.attrs["pk"]))
        fs = Dict{String,Any}()
        byname = Dict(string(f.name) => f for f in vcat(all_fields(T), modelmeta(concrete_model(T)).m2m))
        for fe in xml_elements(o, "field")
            name = fe.attrs["name"]
            f = get(byname, name, nothing)
            f === nothing && throw(ArgumentError("$(nameof(T)) has no field '$name'"))
            rel = get(fe.attrs, "rel", "")
            fs[name] = if !isempty(xml_elements(fe, "None"))
                nothing
            elseif rel == "ManyToManyRel"
                R = related_model(f)
                Any[haskey(x.attrs, "pk") ? xml_pk(R, x.attrs["pk"]) : xml_ref_value(x) for x in xml_elements(fe, "object")]
            elseif rel == "ManyToOneRel" || f.kind === :fk
                v = xml_ref_value(fe)
                v isa AbstractString ? xml_pk(related_model(f), v) : v
            else
                xml_field_value(f, xml_text(fe))
            end
        end
        d["fields"] = fs
        push!(out, d)
    end
    out
end
