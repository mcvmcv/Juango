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

"A docstring rendered from Markdown to HTML (a `SafeString`; empty when there is none)."
function docstring_html(x)
    d = docstring(x)
    isempty(d) && return SafeString("")
    SafeString(Markdown.html(Markdown.parse(d)))
end

field_type_label(f::Field) = f.kind === :fk ? "ForeignKey to " * modelmeta(related_model(f)).name :
    f.kind === :m2m ? "ManyToMany to " * modelmeta(related_model(f)).name :
    f.generated !== nothing ? "Generated ($(f.kind))" : uppercasefirst(string(f.kind)) * (f.max_length === nothing ? "" : " ($(f.max_length))")

doc_models() = sort([T for T in all_models() if model_in_use(T) && !modelmeta(T).proxy && !(T <: AutoThrough)]; by = model_label)
"Whether the user may read a model's documentation: view or change permission on it, as Django's."
doc_can_see(req, T) = has_perm(req.user, perm_name(T, "view")) || has_perm(req.user, perm_name(T, "change"))
"A view's documentation name and URL part: its module and name (`Main.article_detail`), Django's get_view_name."
view_path(v) = v isa Function ? string(parentmodule(v), ".", haskey(VIEW_NAMES, v) ? VIEW_NAMES[v] : nameof(v)) :
               string(parentmodule(typeof(v)), ".", nameof(typeof(v)))
"Where a model's documentation is: `/admin/doc/models/app.model/`."
doc_model_url(T) = reverse_url("admindocs:model"; label = lowercase(model_label(T)))
"A link to a model's documentation, as Django's (a `SafeString`)."
doc_model_link(T) = SafeString("<a class=\"reference external\" href=\"$(doc_model_url(T))\">$(model_label(T))</a>")

doc_page(req, template, title, ctx) = (require_app("admindocs", "the admin documentation");
    render(req, template, merge(Admin.base_context(req, title), Dict{String,Any}(ctx))))

function admindocs_index(req::Request; kw...)
    sec(t, u, w) = Dict{String,Any}("title" => t, "url" => reverse_url(u), "what" => w)
    doc_page(req, "admin_doc/index.html", "Documentation", Dict("sections" => [
        sec("Models", "admindocs:models", "the models and their fields and relations"),
        sec("Views", "admindocs:views", "the URL patterns and the views behind them"),
        sec("Tags", "admindocs:tags", "the template tags"),
        sec("Filters", "admindocs:filters", "the template filters"),
        sec("Bookmarklets", "admindocs:bookmarklets", "tools for your browser to jump to a page's view")]))
end

function admindocs_models(req::Request; kw...)
    rows = [Dict{String,Any}("label" => model_label(T), "app" => modelmeta(T).app, "name" => modelmeta(T).name,
                             "summary" => first(split(docstring(T) * "\n", '\n')),
                             "url" => doc_model_url(T)) for T in doc_models() if doc_can_see(req, T)]   # (the user's models only, as Django's)
    doc_page(req, "admin_doc/model_index.html", "Models", Dict("models" => rows))
end

function admindocs_model(req::Request; label, kw...)
    # (Django's messages for an app or a model that isn't there)
    app, name = occursin('.', label) ? split(label, '.'; limit = 2) : (label, "")
    is_installed(app) || any(T -> modelmeta(T).app == app, all_models()) || throw(Http404("App '$app' not found"))
    T = try get_model(label) catch; throw(Http404("Model '$name' not found in app '$app'")) end
    doc_can_see(req, T) || throw(PermissionDenied())
    m = modelmeta(T)
    describe(f) = f.kind === :fk ? SafeString("the related $(doc_model_link(related_model(f))) object") :
                  f.kind === :m2m ? SafeString("all related $(doc_model_link(related_model(f))) objects") : label_of(f)
    fields = [Dict{String,Any}("name" => string(f.name), "type" => field_type_label(f), "verbose_name" => describe(f),
                               "help" => string(f.help_text), "null" => f.null, "unique" => f.unique)
              for f in vcat(all_fields(T), modelmeta(concrete_model(T)).m2m)]
    rel = [Dict{String,Any}("name" => string(n), "model" => model_label(M), "field" => string(f.name),
                            "all" => SafeString("all related $(doc_model_link(M)) objects"),
                            "count" => SafeString("number of related $(doc_model_link(M)) objects"))
           for (n, M, f) in reverse_relations(T) if !endswith(string(n), "+")]     # (related_name = "+": none, as Django's)
    doc_page(req, "admin_doc/model_detail.html", m.name,
             Dict("model" => Dict("label" => model_label(T), "name" => m.name, "table" => m.table, "doc" => docstring_html(T),
                                   "verbose_name" => string(m.verbose_name)), "fields" => fields, "relations" => rel))
end
label_of(f::Field) = label(f)

function admindocs_views(req::Request; kw...)
    rows = [Dict{String,Any}("route" => "/" * r, "name" => something(n, ""), "view" => view_label(v),
                             "url" => reverse_url("admindocs:view"; view = view_path(v)),
                             "doc" => docstring_html(v isa Function ? v : typeof(v))) for (r, n, v) in all_routes()]
    doc_page(req, "admin_doc/view_index.html", "Views", Dict("views" => rows))
end

"One view's documentation (Django's view_detail): a view that isn't in the URL patterns is a 404."
function admindocs_view(req::Request; view, kw...)
    i = findfirst(x -> view_path(x[3]) == view, all_routes())
    i === nothing && throw(Http404("No view '$view'"))
    r, n, v = all_routes()[i]
    doc_page(req, "admin_doc/view_detail.html", view, Dict("name" => view, "route" => "/" * r, "urlname" => something(n, ""),
                                                           "doc" => docstring_html(v isa Function ? v : typeof(v))))
end

"""
Where a template is looked for, in each template directory (Django's template_detail): its file there,
whether it exists, and its source. An absolute path or one going up (`..`) is a 400.
"""
function admindocs_template(req::Request; template, kw...)
    (isabspath(template) || startswith(template, "/") || ".." in splitpath(template)) && throw(BadRequest("Invalid template path"))   # (a 400, as Django's SuspiciousOperation)
    files = Dict{String,Any}[]
    for d in template_dirs()
        p = joinpath(d, template)
        ex = isfile(p)
        push!(files, Dict{String,Any}("file" => p, "exists" => ex, "contents" => ex ? read(p, String) : "", "order" => length(files) + 1))
    end
    doc_page(req, "admin_doc/template_detail.html", "Template: $template", Dict("name" => template, "templates" => files))
end

"Bookmarklets: a link to drag to the bookmarks bar, which shows the documentation of the current page's view (with XViewMiddleware)."
admindocs_bookmarklets(req::Request; kw...) =
    doc_page(req, "admin_doc/bookmarklets.html", "Bookmarklets", Dict("admin_url" => reverse_url("admindocs:views")))

"""
    XViewMiddleware

Answers a HEAD request from a staff user or an INTERNAL_IPS address with an `X-View` header naming the
view behind the URL (`Main.article_detail`), for the admin documentation's bookmarklets (Django's).
Needs AuthenticationMiddleware before it.
"""
XViewMiddleware(get_response) = get_response
function process_view(::typeof(XViewMiddleware), req::Request, view, kwargs)
    getfield(req, :user) === nothing && throw(ImproperlyConfigured("The XView middleware requires authentication middleware to be installed. " *
        "Edit your MIDDLEWARE setting to insert AuthenticationMiddleware."))
    req.method == "HEAD" || return nothing
    u = req.user
    (string(get(req.meta, :remote_addr, "")) in something(get(settings, :INTERNAL_IPS, nothing), String[]) ||
     (is_authenticated(u) && u.is_active && u.is_staff)) || return nothing
    r = HttpResponse()
    setheader!(r, "X-View", view_path(view))
    r
end

function admindocs_tags(req::Request; kw...)
    rows = [Dict{String,Any}("name" => n, "doc" => docstring_html(f)) for (n, f) in sort!(collect(TAGS); by = first)]
    libs = [Dict{String,Any}("library" => l.name, "tags" => sort!(collect(keys(l.tags))), "filters" => sort!(collect(keys(l.filters))))
            for l in sort!(collect(values(TAG_LIBRARIES)); by = l -> l.name)]
    doc_page(req, "admin_doc/template_tag_index.html", "Template tags", Dict("tags" => rows, "libraries" => libs))
end

function admindocs_filters(req::Request; kw...)
    rows = [Dict{String,Any}("name" => n, "doc" => docstring_html(f.fn)) for (n, f) in sort!(collect(FILTERS); by = first)]
    libs = [Dict{String,Any}("library" => l.name,
                             "filters" => [Dict{String,Any}("name" => n, "doc" => docstring_html(f.fn)) for (n, f) in sort!(collect(l.filters); by = first)])
            for l in sort!(collect(values(TAG_LIBRARIES)); by = l -> l.name) if !isempty(l.filters)]
    doc_page(req, "admin_doc/template_filter_index.html", "Template filters", Dict("filters" => rows, "libraries" => libs))
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
        path("bookmarklets/", s(admindocs_bookmarklets); name = "bookmarklets"),
        path("views/<str:view>/", s(admindocs_view); name = "view"),
        path("templates/<path:template>/", s(admindocs_template); name = "template"),
    ]; namespace = "admindocs")
end
