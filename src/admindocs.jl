# Admin documentation (juango.admindocs) ---------------------------------------------------------------
#
#     INSTALLED_APPS = [..., "juango.admindocs"]
#     path("admin/doc/", admindocs_urls()),      # before path("admin/", Admin.urls())
#
# Pages for staff listing the project's models (fields, relations, docstrings), URL patterns and
# their views, and template tags and filters, from Julia docstrings.

"A function's or type's docstring as text (empty when it has none). Reads Base.Docs directly (no REPL needed)."
function docstring(x)
    (x isa Function || x isa Type) || return ""
    T = x isa Function ? typeof(x) : x
    isdefined(T, :name) || return ""
    name = x isa Function ? nameof(x) : nameof(x)
    b = Base.Docs.Binding(parentmodule(x), name)
    m = get(Base.Docs.meta(b.mod), b, nothing)
    m === nothing && return ""
    strip(join([join(string.(d.text)) for d in values(m.docs)], "\n\n"))
end

field_type_label(f::Field) = f.kind === :fk ? "ForeignKey to " * modelmeta(related_model(f)).name :
    f.kind === :m2m ? "ManyToMany to " * modelmeta(related_model(f)).name :
    f.generated !== nothing ? "Generated ($(f.kind))" : uppercasefirst(string(f.kind)) * (f.max_length === nothing ? "" : " ($(f.max_length))")

doc_models() = sort([T for T in all_models() if model_in_use(T) && !modelmeta(T).proxy && !(T <: AutoThrough)]; by = model_label)

doc_page(req, template, title, ctx) = (require_app("admindocs", "the admin documentation");
    render(req, template, merge(Admin.base_context(req, title), Dict{String,Any}(ctx))))

function admindocs_index(req::Request; kw...)
    sec(t, u, w) = Dict{String,Any}("title" => t, "url" => reverse_url(u), "what" => w)
    doc_page(req, "admin_doc/index.html", "Documentation", Dict("sections" => [
        sec("Models", "admindocs:models", "the models and their fields and relations"),
        sec("Views", "admindocs:views", "the URL patterns and the views behind them"),
        sec("Tags", "admindocs:tags", "the template tags"),
        sec("Filters", "admindocs:filters", "the template filters")]))
end

function admindocs_models(req::Request; kw...)
    rows = [Dict{String,Any}("label" => model_label(T), "app" => modelmeta(T).app, "name" => modelmeta(T).name,
                             "summary" => first(split(docstring(T) * "\n", '\n')),
                             "url" => reverse_url("admindocs:model"; label = lowercase(model_label(T)))) for T in doc_models()]
    doc_page(req, "admin_doc/model_index.html", "Models", Dict("models" => rows))
end

function admindocs_model(req::Request; label, kw...)
    T = try get_model(label) catch; throw(Http404("No model '$label'")) end
    m = modelmeta(T)
    fields = [Dict{String,Any}("name" => string(f.name), "type" => field_type_label(f), "verbose_name" => label_of(f),
                               "help" => string(f.help_text), "null" => f.null, "unique" => f.unique)
              for f in vcat(all_fields(T), modelmeta(concrete_model(T)).m2m)]
    rel = [Dict{String,Any}("name" => string(n), "model" => model_label(M), "field" => string(f.name)) for (n, M, f) in reverse_relations(T)]
    doc_page(req, "admin_doc/model_detail.html", m.name,
             Dict("model" => Dict("label" => model_label(T), "name" => m.name, "table" => m.table, "doc" => docstring(T),
                                   "verbose_name" => string(m.verbose_name)), "fields" => fields, "relations" => rel))
end
label_of(f::Field) = label(f)

function admindocs_views(req::Request; kw...)
    rows = [Dict{String,Any}("route" => "/" * r, "name" => something(n, ""), "view" => view_label(v),
                             "doc" => docstring(v isa Function ? v : typeof(v))) for (r, n, v) in all_routes()]
    doc_page(req, "admin_doc/view_index.html", "Views", Dict("views" => rows))
end

function admindocs_tags(req::Request; kw...)
    rows = [Dict{String,Any}("name" => n, "doc" => docstring(f)) for (n, f) in sort!(collect(TAGS); by = first)]
    libs = [Dict{String,Any}("library" => l.name, "tags" => sort(collect(keys(l.tags)))) for l in sort!(collect(values(TAG_LIBRARIES)); by = l -> l.name)]
    doc_page(req, "admin_doc/template_tag_index.html", "Template tags", Dict("tags" => rows, "libraries" => libs))
end

function admindocs_filters(req::Request; kw...)
    rows = [Dict{String,Any}("name" => n, "doc" => docstring(f.fn)) for (n, f) in sort!(collect(FILTERS); by = first)]
    doc_page(req, "admin_doc/template_filter_index.html", "Template filters", Dict("filters" => rows))
end

const ADMINDOCS_APP = App("admindocs"; name = "juango.admindocs", verbose_name = "Administrative Documentation", requires = ["admin"])

"""
    admindocs_urls()

URL patterns for the admin documentation (staff only): `path("admin/doc/", admindocs_urls())`,
before `path("admin/", Admin.urls())`. Needs "juango.admindocs" in INSTALLED_APPS.
"""
function admindocs_urls()
    s(v) = staff_member_required(v)
    include_urls([
        path("", s(admindocs_index); name = "index"),
        path("models/", s(admindocs_models); name = "models"),
        path("models/<str:label>/", s(admindocs_model); name = "model"),
        path("views/", s(admindocs_views); name = "views"),
        path("tags/", s(admindocs_tags); name = "tags"),
        path("filters/", s(admindocs_filters); name = "filters"),
    ]; namespace = "admindocs")
end
