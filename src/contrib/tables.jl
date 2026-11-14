# Tables (django-tables2) ------------------------------------------------------------------------------------
#
#     table = Table(filter(Article; published = true), req;
#                   columns = [:title => LinkColumn(),                       # links to get_absolute_url
#                              :author => Column(accessor = "author__name", order_by = "author__name"),
#                              :views,
#                              :published => BooleanColumn(),
#                              :created => DateTimeColumn(format = "Y-m-d"),
#                              :edit => TemplateColumn("<a href=\"{% url 'edit' record.id %}\">Edit</a>"; orderable = false)],
#                   order_by = "-created", per_page = 25, attrs = Dict("class" => "table"))
#     render(req, "articles.html", Dict("table" => table))          # {% render_table table %}
#     export_response(table)                                        # ?_export=csv or xlsx: nothing (no export asked)
#
# Clicking a header sorts by it (?sort=views, ?sort=-views), keeping the page's other parameters;
# querysets are sorted by the database, other data (Dicts, NamedTuples, objects) in Julia. Each
# column's value is the row's field (or the `accessor` path, `author__name`), shown with the
# column's `render(value, record)` or its type's default.

module Tables

# (explicit imports: this file loads before Juango's export list)
import ..Juango: csv_field, render!, __html__, Node, Parser, Token, FilterExpr, Context, parse_filter_expr, split_contents,
                 register_tag!, eval_fe, display_string, truthy, format_date, localtime, model_of, resolve_path,
                 SQLCompiler, modelmeta, label, Field, urlencode, MIME_TYPES, xlsx_bytes, Template, Model, QuerySet,
                 SafeString, HttpResponse, setheader!, content_disposition, get_template, render, objects, order_by,
                 Paginator, get_page, concrete_fields, get_absolute_url, escape_html, QueryDict, TemplateSyntaxError
using Dates, TimeZones

export Table, Column, BooleanColumn, DateColumn, DateTimeColumn, TemplateColumn, LinkColumn, CheckBoxColumn,
       ManyToManyColumn, EmailColumn, URLColumn, render_table, export_response, export_url

"""
    Column(; label = nothing, accessor = nothing, order_by = nothing, orderable = true, linkify = nothing,
           default = "—", empty_values = (nothing, ""), render = nothing, value = nothing, footer = nothing,
           attrs = Dict(), visible = true, exclude_from_export = false)

A table column (django-tables2's): `label` for the header (default: the field's label);
`accessor` the path to the value (`"author__name"`, default the column's name); `order_by` what
sorting by it sorts on (a field name or several, default the accessor; `orderable = false` for
none); `linkify = true` links the cell to the record's `get_absolute_url` (or a function
`record -> url`); `default` for empty values; `render(value, record)` the cell's HTML (escaped
unless it returns a `SafeString`) and `value(value, record)` its plain value for exports;
`footer` a string or `table -> string`; `attrs = Dict("th" => Dict(...), "td" => Dict(...))`.
"""
Base.@kwdef mutable struct Column
    label::Any = nothing
    accessor::Any = nothing
    order_by::Any = nothing
    orderable::Bool = true
    linkify::Any = nothing
    default::Any = "—"
    empty_values::Tuple = (nothing, "")
    render::Any = nothing
    value::Any = nothing
    footer::Any = nothing
    attrs::Dict{String,Any} = Dict{String,Any}()
    visible::Bool = true
    exclude_from_export::Bool = false
    kind::Symbol = :plain                        # :boolean, :date, :template, :checkbox, :m2m, :email, :url
    options::Dict{Symbol,Any} = Dict{Symbol,Any}()
end
Column(c::Column) = c

"A ✔/✘ (or `yesno = (\"Yes\", \"No\")`) column."
BooleanColumn(; yesno = ("✔", "✘"), kw...) = Column(; kind = :boolean, options = Dict{Symbol,Any}(:yesno => yesno), kw...)
"Dates shown with the `date` filter's format (`format = \"N j, Y\"`)."
DateColumn(; format = "N j, Y", kw...) = Column(; kind = :date, options = Dict{Symbol,Any}(:format => format), kw...)
DateTimeColumn(; format = "N j, Y, P", kw...) = Column(; kind = :date, options = Dict{Symbol,Any}(:format => format), kw...)
"""
    TemplateColumn(template_code; kw...)    TemplateColumn(; template_name, kw...)

Cells rendered by a template, with `record`, `value`, `column` and `table` in the context (and
the request's context processors).
"""
TemplateColumn(code::AbstractString; kw...) = Column(; kind = :template, options = Dict{Symbol,Any}(:code => String(code)), orderable = false, kw...)
TemplateColumn(; template_name, kw...) = Column(; kind = :template, options = Dict{Symbol,Any}(:name => String(template_name)), orderable = false, kw...)
"A link to the record (or `linkify = record -> url`): its text is the value."
LinkColumn(; linkify = true, kw...) = Column(; linkify = linkify, kw...)
"A checkbox per row (`name=\"<column>\" value=\"<pk>\"`) and one in the header that selects all, for bulk actions."
CheckBoxColumn(; kw...) = Column(; kind = :checkbox, orderable = false, exclude_from_export = true, label = "", kw...)
"The related objects of a many-to-many field, joined with `separator` (each linked with `linkify_item = true`)."
ManyToManyColumn(; separator = ", ", linkify_item = false, kw...) =
    Column(; kind = :m2m, orderable = false, options = Dict{Symbol,Any}(:separator => separator, :linkify_item => linkify_item), kw...)
"A `mailto:` link."
EmailColumn(; kw...) = Column(; kind = :email, kw...)
"A link to the value."
URLColumn(; kw...) = Column(; kind = :url, kw...)

"""
    Table(data, req = nothing; columns = nothing, exclude = [], sequence = nothing, order_by = nothing,
          per_page = 25, orderable = true, attrs = Dict("class" => "table"), empty_text = "No data",
          prefix = "", template_name = nothing, row_attrs = nothing, export_formats = (:csv, :xlsx),
          export_name = "table")

A table of `data`: a model, a queryset, or a vector of rows (Dicts, NamedTuples or objects).
`columns` lists them in order, each a name (`:title`) or `name => Column(...)`; for a model or
queryset, `nothing` means all its concrete fields. `exclude` leaves some out and `sequence`
reorders (`[:title, :..., :edit]`, `:...` for the rest). `order_by` is the default sort, `per_page`
the page size (`nothing` for one page), `prefix` keeps two tables on a page apart (`?<prefix>sort`).
`row_attrs = record -> Dict(...)` gives each `<tr>` attributes.
"""
mutable struct Table
    data::Any
    request::Any
    columns::Vector{Pair{Symbol,Column}}
    order_by::Vector{String}
    per_page::Union{Nothing,Int}
    orderable::Bool
    attrs::Dict{String,Any}
    empty_text::String
    prefix::String
    template_name::Union{Nothing,String}
    row_attrs::Any
    export_formats::Tuple
    export_name::String
    model::Any
    paginator::Any
    page::Any
end

Base.@nospecializeinfer function Table(@nospecialize(data), req = nothing; columns = nothing, exclude = Symbol[], sequence = nothing,
                                       order_by = nothing, per_page = 25, orderable = true,
                                       attrs = Dict{String,Any}("class" => "table"), empty_text = "No data", prefix = "",
                                       template_name = nothing, row_attrs = nothing, export_formats = (:csv, :xlsx),
                                       export_name = "table")
    data isa Type && data <: Model && (data = objects(data))
    M = data isa QuerySet ? model_of(data) : nothing
    cols = Pair{Symbol,Column}[]
    if columns === nothing
        M === nothing && throw(ArgumentError("Table: give `columns` for data that isn't a model or queryset"))
        for f in concrete_fields(M)
            f.generated === nothing || continue
            push!(cols, f.name => Column())
        end
    else
        for c in columns
            c isa Pair ? push!(cols, Symbol(c.first) => deepcopy(Column(c.second))) : push!(cols, Symbol(c) => Column())
        end
    end
    filter!(p -> !(p.first in Symbol.(collect(exclude))), cols)
    if sequence !== nothing
        seq = Symbol.(collect(sequence))
        rest = [p for p in cols if !(p.first in seq)]
        out = Pair{Symbol,Column}[]
        for s in seq
            s === Symbol("...") ? append!(out, rest) : (k = findfirst(p -> p.first === s, cols); k === nothing || push!(out, cols[k]))
        end
        cols = out
    end
    for (name, c) in cols                               # labels from the model's fields
        c.label === nothing || continue
        fieldat(p) = M === nothing ? nothing : (try last(resolve_path(SQLCompiler(M), modelmeta(M).table, M, p)) catch; nothing end)
        f = fieldat(string(name))                      # a column named after a field: that field's label
        f isa Field || (f = fieldat(string(something(c.accessor, name))))
        c.label = f isa Field ? uppercasefirst(string(label(f))) : uppercasefirst(replace(string(name), '_' => ' '))
    end
    t = Table(data, req, cols, order_by === nothing ? String[] : String.(string.(order_by isa Union{Symbol,AbstractString} ? [order_by] : order_by)),
              per_page, orderable, Dict{String,Any}(string(k) => v for (k, v) in attrs), string(empty_text), string(prefix),
              template_name, row_attrs, Tuple(Symbol.(export_formats)), string(export_name), M, nothing, nothing)
    paginate!(t)
    t
end

param(t::Table, name) = t.prefix * name
table_column(t::Table, name::Symbol) = (k = findfirst(p -> p.first === name, t.columns); k === nothing ? nothing : t.columns[k].second)
accessor(name::Symbol, c::Column) = string(something(c.accessor, name))
column_orderable(t::Table, name::Symbol, c::Column) = t.orderable && c.orderable && c.kind ∉ (:template, :checkbox, :m2m)
order_fields(name::Symbol, c::Column) = (o = something(c.order_by, accessor(name, c));
                                          o isa Union{AbstractString,Symbol} ? [string(o)] : String.(string.(collect(o))))

"The sort asked for in the request (`?sort=-views`), checked against the columns: [(column, descending)]."
function requested_sort(t::Table)
    t.request === nothing && return Tuple{Symbol,Bool}[]
    raw = get(t.request.GET, param(t, "sort"), "")
    out = Tuple{Symbol,Bool}[]
    for part in split(raw, ','; keepempty = false)
        desc = startswith(part, "-")
        name = Symbol(lstrip(part, '-'))
        c = table_column(t, name)
        c !== nothing && column_orderable(t, name, c) && push!(out, (name, desc))
    end
    out
end

"The rows in display order (the request's sort, else `order_by`), all of them."
Base.@nospecializeinfer function sorted_rows(t::Table)
    sort_ = requested_sort(t)
    keys_ = String[]
    for (name, desc) in sort_, f in order_fields(name, table_column(t, name))
        push!(keys_, desc ? (startswith(f, "-") ? f[2:end] : "-" * f) : f)
    end
    isempty(keys_) && (keys_ = t.order_by)
    d = t.data
    if d isa QuerySet
        isempty(keys_) ? d : order_by(d, keys_..., "id")
    else
        rows = collect(Any, d)
        for k in reverse(keys_)                          # stable sorts, last key first
            desc = startswith(k, "-")
            path = lstrip(k, '-')
            sort!(rows; by = r -> sort_key(row_value(r, path)), rev = desc, alg = Base.Sort.DEFAULT_STABLE)
        end
        rows
    end
end
sort_key(v) = v === nothing ? (0, "") : v isa Union{Number,Dates.TimeType,AbstractString,Bool} ? (1, v) : (1, string(v))

function paginate!(t::Table)
    rows = sorted_rows(t)
    t.paginator = Paginator(rows, something(t.per_page, max(1, rows isa QuerySet ? count(rows) : length(rows))))
    n = t.request === nothing ? 1 : get(t.request.GET, param(t, "page"), "1")
    t.page = get_page(t.paginator, n)
    t
end

"The value at `path` (`author__name` or `author.name`) of a row: a model object, a Dict, a NamedTuple."
function row_value(@nospecialize(r), path::AbstractString)
    v = r
    for part in split(path, r"__|\.")
        v === nothing && return nothing
        k = Symbol(part)
        v = v isa AbstractDict ? get(v, string(part), get(v, k, nothing)) :
            v isa NamedTuple ? get(v, k, nothing) :
            v isa Model ? (try getproperty(v, k) catch e; e isa Union{ErrorException,KeyError,ArgumentError} || rethrow(); nothing end) :
            hasproperty(v, k) ? getproperty(v, k) : nothing
    end
    v
end

cell_raw(t::Table, @nospecialize(r), name::Symbol, c::Column) = row_value(r, accessor(name, c))
isempty_value(c::Column, v) = any(e -> isequal(v, e), c.empty_values) || (v isa AbstractVector && isempty(v))

"A cell's HTML."
function cell_html(t::Table, @nospecialize(r), name::Symbol, c::Column)
    c.kind === :checkbox && return "<input type=\"checkbox\" name=\"" * escape_html(string(name)) * "\" value=\"" *
                                   escape_html(string(row_value(r, "pk"))) * "\">"
    if c.kind === :template
        ctx = Dict{String,Any}("record" => r, "value" => cell_raw(t, r, name, c), "column" => c, "table" => t)
        tpl = haskey(c.options, :code) ? cached_column_template(c.options[:code]) : get_template(c.options[:name])
        return render(tpl, ctx; request = t.request)
    end
    v = cell_raw(t, r, name, c)
    if c.kind === :m2m && v isa QuerySet
        items = collect(v)
        isempty(items) && return escape_html(string(c.default))
        sep = escape_html(string(c.options[:separator]))
        return join([c.options[:linkify_item] && (u = get_absolute_url(o)) !== nothing ?
                     "<a href=\"" * escape_html(u) * "\">" * escape_html(string(o)) * "</a>" : escape_html(string(o)) for o in items], sep)
    end
    c.render === nothing || return (h = c.render(v, r); h isa SafeString ? h.s : escape_html(display_string(h)))
    isempty_value(c, v) && return escape_html(string(c.default))
    text = if c.kind === :boolean
        yn = c.options[:yesno]
        escape_html(truthy(v) ? yn[1] : yn[2])
    elseif c.kind === :date && v isa Union{Dates.TimeType,TimeZones.ZonedDateTime}
        escape_html(format_date(v isa TimeZones.ZonedDateTime ? localtime(v) : v, c.options[:format]))
    elseif c.kind === :email
        "<a href=\"mailto:" * escape_html(string(v)) * "\">" * escape_html(string(v)) * "</a>"
    elseif c.kind === :url
        "<a href=\"" * escape_html(string(v)) * "\">" * escape_html(string(v)) * "</a>"
    elseif v isa Model
        escape_html(string(v))
    else
        h = __html__(v)
        h === nothing ? escape_html(display_string(v)) : h
    end
    url = c.linkify === nothing || c.linkify === false ? nothing : c.linkify === true ? link_target(r, v) : c.linkify(r)
    url === nothing ? text : "<a href=\"" * escape_html(string(url)) * "\">" * text * "</a>"
end
link_target(@nospecialize(r), @nospecialize(v)) = r isa Model ? get_absolute_url(r) : v isa Model ? get_absolute_url(v) : nothing

const COLUMN_TEMPLATES = Dict{String,Template}()
const COLUMN_TEMPLATES_LOCK = ReentrantLock()
cached_column_template(code::String) = lock(() -> get!(() -> Template(code), COLUMN_TEMPLATES, code), COLUMN_TEMPLATES_LOCK)

"A cell's plain value, for exports: the column's `value(value, record)`, else the value as text."
function cell_export(t::Table, @nospecialize(r), name::Symbol, c::Column)
    c.kind === :template && return strip(replace(cell_html(t, r, name, c), r"<[^>]*>" => ""))    # the rendered text
    v = cell_raw(t, r, name, c)
    c.value === nothing || return c.value(v, r)
    c.kind === :m2m && v isa QuerySet && return join(string.(collect(v)), string(c.options[:separator]))
    isempty_value(c, v) && return nothing
    v isa Model ? string(v) : v isa TimeZones.ZonedDateTime ? DateTime(localtime(v)) : v isa SafeString ? v.s : v
end

attrs_html(d) = join([" " * escape_html(string(k)) * "=\"" * escape_html(string(v)) * "\"" for (k, v) in sort!(collect(d); by = first)])
query_url(t::Table, changes::Pair...) = begin
    q = t.request === nothing ? QueryDict() : copy(t.request.GET)
    for (k, v) in changes
        v === nothing ? delete!(q.data, k) : (q.data[k] = [string(v)])
    end
    s = urlencode(q)
    isempty(s) ? "?" : "?" * s
end

"""
    render_table(table) -> SafeString

The table's HTML: `{% render_table table %}`. With `template_name` it's that template's (context
`table`); otherwise a `<table>` with sortable headers, the page's rows, footers and pagination.
"""
function render_table(t::Table)
    t.template_name === nothing || return SafeString(render(get_template(t.template_name), Dict{String,Any}("table" => t); request = t.request))
    sort_ = requested_sort(t)
    vis = [(n, c) for (n, c) in t.columns if c.visible]
    io = IOBuffer()
    print(io, "<table", attrs_html(t.attrs), "><thead><tr>")
    for (name, c) in vis
        th = Dict{String,Any}(get(c.attrs, "th", Dict{String,Any}()))
        k = findfirst(x -> x[1] === name, sort_)
        if column_orderable(t, name, c)
            th["class"] = strip(string(get(th, "class", ""), " orderable", k === nothing ? "" : sort_[k][2] ? " desc" : " asc"))
        end
        print(io, "<th", attrs_html(th), ">")
        if c.kind === :checkbox
            print(io, "<input type=\"checkbox\" aria-label=\"Select all\" onclick=\"for(const b of this.closest('table').querySelectorAll('tbody input[name=&quot;",
                  escape_html(string(name)), "&quot;]'))b.checked=this.checked\">")
        elseif column_orderable(t, name, c)
            next_ = k !== nothing && k == 1 && !sort_[1][2] ? "-" * string(name) : string(name)     # click again: descending
            print(io, "<a href=\"", escape_html(query_url(t, param(t, "sort") => next_, param(t, "page") => nothing)), "\">",
                  escape_html(string(c.label)), "</a>")
        else
            print(io, escape_html(string(c.label)))
        end
        print(io, "</th>")
    end
    print(io, "</tr></thead><tbody>")
    rows = t.page.object_list
    isempty(rows) && print(io, "<tr><td colspan=\"", length(vis), "\" class=\"empty\">", escape_html(t.empty_text), "</td></tr>")
    for r in rows
        print(io, "<tr", t.row_attrs === nothing ? "" : attrs_html(t.row_attrs(r)), ">")
        for (name, c) in vis
            print(io, "<td", attrs_html(get(c.attrs, "td", Dict{String,Any}())), ">", cell_html(t, r, name, c), "</td>")
        end
        print(io, "</tr>")
    end
    print(io, "</tbody>")
    if any(x -> x[2].footer !== nothing, vis)
        print(io, "<tfoot><tr>")
        for (_, c) in vis
            f = c.footer isa Function ? c.footer(t) : c.footer
            print(io, "<td>", f === nothing ? "" : f isa SafeString ? f.s : escape_html(string(f)), "</td>")
        end
        print(io, "</tr></tfoot>")
    end
    print(io, "</table>")
    p, pg = t.paginator, t.page
    if p.num_pages > 1
        print(io, "<nav class=\"pagination\">")
        pg.has_previous && print(io, "<a href=\"", escape_html(query_url(t, param(t, "page") => pg.previous_page_number)), "\" rel=\"prev\">‹ previous</a> ")
        print(io, "<span>Page ", pg.number, " of ", p.num_pages, "</span>")
        pg.has_next && print(io, " <a href=\"", escape_html(query_url(t, param(t, "page") => pg.next_page_number)), "\" rel=\"next\">next ›</a>")
        print(io, "</nav>")
    end
    SafeString(String(take!(io)))
end
Base.show(io::IO, ::MIME"text/html", t::Table) = print(io, render_table(t).s)
__html__(t::Table) = render_table(t).s

# {% render_table table %}
struct RenderTableNode <: Node
    table::FilterExpr
end
function tag_render_table(p::Parser, tok::Token)
    bits = split_contents(tok.contents)
    length(bits) == 2 || throw(TemplateSyntaxError("'render_table' takes one argument: the table"))
    RenderTableNode(parse_filter_expr(bits[2]))
end
function render!(io::IO, n::RenderTableNode, ctx::Context)
    t = eval_fe(n.table, ctx)
    t isa Table || throw(ArgumentError("render_table needs a Table, got $(typeof(t))"))
    write(io, render_table(t).s)
end
register_tag!("render_table", tag_render_table)

# --- exports ----------------------------------------------------------------------------------------------

"Header and rows of the whole table (every page, in its sort), as plain values."
function export_rows(t::Table)
    cols = [(n, c) for (n, c) in t.columns if c.visible && !c.exclude_from_export]
    header = Any[string(c.label) for (_, c) in cols]
    rows = Vector{Any}[Any[cell_export(t, r, n, c) for (n, c) in cols] for r in sorted_rows(t)]
    header, rows
end

"""
    export_response(table; format = nothing) -> HttpResponse or nothing

The whole table as a CSV or XLSX download when the request asks for it (`?_export=csv`, or
`format`), else `nothing`: `r = export_response(table); r === nothing || return r` in a view.
CSV text that starts like a formula (`=`, `+`, `-`, `@`) is prefixed with `'` so spreadsheets don't
run it; `csv_formulas = true` turns that off.
"""
function export_response(t::Table; format = nothing, csv_formulas::Bool = false)
    f = format === nothing ? (t.request === nothing ? nothing : get(t.request.GET, param(t, "_export"), nothing)) : string(format)
    (f === nothing || isempty(f)) && return nothing
    fmt = Symbol(lowercase(f))
    fmt in t.export_formats || return nothing
    header, rows = export_rows(t)
    if fmt === :csv
        r = HttpResponse(csv_string(header, rows; formulas = csv_formulas); content_type = "text/csv; charset=utf-8")
        setheader!(r, "Content-Disposition", content_disposition(t.export_name * ".csv"; attachment = true))
        return r
    elseif fmt === :xlsx
        r = HttpResponse(xlsx_bytes(vcat([header], rows)); content_type = MIME_TYPES[".xlsx"])
        setheader!(r, "Content-Disposition", content_disposition(t.export_name * ".xlsx"; attachment = true))
        return r
    end
    nothing
end
"A link that exports the table in `format`, keeping the page's parameters."
export_url(t::Table, format) = query_url(t, param(t, "_export") => string(format))

csv_string(header, rows; formulas::Bool = false) = sprint() do io
    println(io, join([csv_field(v; formulas) for v in header], ","))
    foreach(r -> println(io, join([csv_field(v; formulas) for v in r], ",")), rows)
end

end # module Tables
