# Shortcuts & generic views --------------------------------------------------------------------

"""
    render(req, template_name, context=Dict(); status=200, content_type="text/html; charset=utf-8")

Render a template with the request's context processors and return an `HttpResponse`.
`template_name` may also be a list (first existing is used) or a `Template`.
"""
function render(req::Request, template, context = Dict{String,Any}(); status = 200,
                content_type = "text/html; charset=utf-8")
    t = template isa Template ? template : select_template(template)
    ctx = to_context_dict(context)
    resp = HttpResponse(render(t, ctx; request = req); status = status, content_type = content_type)
    resp.context = ctx
    push!(resp.templates, t.name)
    resp
end

"""
    redirect(to, args...; permanent=false, kwargs...)

`to` can be a URL (`"/posts/"`, `"https://…"`), a URL pattern name (reversed with
`args`/`kwargs`), or a model instance with `get_absolute_url` defined.
"""
function redirect(to, args...; permanent = false, kwargs...)
    url = if to isa Model
        u = get_absolute_url(to)
        u === nothing && error("$(typeof(to)) does not define get_absolute_url")
        u
    elseif to isa AbstractString && (occursin('/', to) || startswith(to, ".") || occursin(r"^\w+:", to) && occursin("//", to))
        to
    else
        try
            reverse_url(string(to), args...; kwargs...)
        catch e
            e isa NoReverseMatch || rethrow()
            string(to)
        end
    end
    permanent ? HttpResponsePermanentRedirect(url) : HttpResponseRedirect(url)
end

"Get one object or raise `Http404`."
function get_object_or_404(qs, qargs::Q...; kw...)
    try
        get(qs, qargs...; kw...)
    catch e
        e isa DoesNotExist && throw(Http404("No $(nameof(e.model)) matches the given query."))
        rethrow()
    end
end
"Filter, raising `Http404` if nothing matches."
function get_list_or_404(qs, qargs::Q...; kw...)
    v = collect(filter(qs isa Type ? objects(qs) : qs, qargs...; kw...))
    isempty(v) && throw(Http404("No objects match the given query."))
    v
end

# --- method decorators ---------------------------------------------------------------------

"Restrict a view to the given HTTP methods (405 otherwise)."
function require_http_methods(view, methods)
    ms = uppercase.(string.(collect(methods)))
    w = (req; kw...) -> req.method in ms ? view(req; kw...) : HttpResponseNotAllowed(ms)
    propagate_flags!(w, view)
end
require_http_methods(methods) = view -> require_http_methods(view, methods)
require_GET(view) = require_http_methods(view, ["GET", "HEAD"])
require_POST(view) = require_http_methods(view, ["POST"])

# --- pagination ------------------------------------------------------------------------------

"""
    Paginator(items, per_page)

Split a queryset (or vector) into pages; get one with `page(p, n)`.
"""
struct Paginator
    items::Any
    per_page::Int
    count::Int
    num_pages::Int
end
function Paginator(items, per_page::Integer)
    n = items isa QuerySet ? count(items) : length(items)
    Paginator(items, per_page, n, max(1, cld(n, per_page)))
end

struct Page
    object_list::Vector{Any}
    number::Int
    paginator::Paginator
    has_next::Bool
    has_previous::Bool
    has_other_pages::Bool
    next_page_number::Union{Nothing,Int}
    previous_page_number::Union{Nothing,Int}
    start_index::Int
    end_index::Int
    page_range::Vector{Int}
end

"Page `n` (1-based); accepts a string such as `req.GET[\"page\"]`. Raises `Http404` if out of range."
function page(p::Paginator, n)
    num = n isa Integer ? Int(n) : n == "last" ? p.num_pages : something(tryparse(Int, string(n)), 0)
    (1 <= num <= p.num_pages) || throw(Http404("Invalid page ($n)"))
    lo = (num - 1) * p.per_page + 1
    hi = min(num * p.per_page, p.count)
    objs = p.items isa QuerySet ? collect(Any, p.items[lo:max(hi, lo - 1)]) : collect(Any, p.items[lo:hi])
    Page(objs, num, p, num < p.num_pages, num > 1, p.num_pages > 1,
         num < p.num_pages ? num + 1 : nothing, num > 1 ? num - 1 : nothing,
         p.count == 0 ? 0 : lo, hi, collect(1:p.num_pages))
end
Base.iterate(pg::Page, st...) = iterate(pg.object_list, st...)
Base.length(pg::Page) = length(pg.object_list)
truthy(pg::Page) = !isempty(pg.object_list)

# --- generic views ---------------------------------------------------------------------------

model_name(T) = lowercase(string(nameof(T)))
resolve_value(x, req) = x isa Function ? x(req) : x

"`TemplateView(\"about.html\"; extra_context=Dict())` — just render a template."
TemplateView(template; extra_context = Dict{String,Any}()) =
    name_view!((req; kw...) -> render(req, template, merge(to_context_dict(resolve_value(extra_context, req)),
                                                           Dict{String,Any}(string(k) => v for (k, v) in kw))),
               "TemplateView($(repr(template)))")

"`RedirectView(url_or_name; permanent=false)`."
RedirectView(to; permanent = false) =
    name_view!((req; kw...) -> redirect(to; permanent = permanent, kw...), "RedirectView($(repr(to)))")

"""
    ListView(Model; template="<model>_list.html", queryset=nothing, paginate_by=nothing,
             context_object_name="<model>_list", extra_context=Dict())

`queryset` may be a `QuerySet` or a function `req -> QuerySet`. The template gets
`object_list`, `<model>_list` and, when paginating, `page_obj`, `paginator`,
`is_paginated`.
"""
function ListView(::Type{T}; template = nothing, queryset = nothing, paginate_by = nothing,
                  context_object_name = nothing, extra_context = Dict{String,Any}()) where {T<:Model}
    tname = something(template, "$(model_name(T))_list.html")
    cname = something(context_object_name, "$(model_name(T))_list")
    name_view!(function (req::Request; kw...)
        qs = queryset === nothing ? objects(T) : resolve_value(queryset, req)
        ctx = to_context_dict(resolve_value(extra_context, req))
        if paginate_by !== nothing
            p = Paginator(qs, paginate_by)
            pg = page(p, get(req.GET, "page", "1"))
            merge!(ctx, Dict{String,Any}("paginator" => p, "page_obj" => pg, "is_paginated" => p.num_pages > 1,
                                         "object_list" => pg.object_list, cname => pg.object_list))
        else
            objs = collect(qs)
            merge!(ctx, Dict{String,Any}("object_list" => objs, cname => objs, "is_paginated" => false))
        end
        render(req, tname, ctx)
    end, "ListView($(nameof(T)))")
end

function lookup_object(::Type{T}, kw, pk_kwarg, slug_kwarg, slug_field, queryset, req) where {T}
    qs = queryset === nothing ? objects(T) : resolve_value(queryset, req)
    kwd = Dict{Symbol,Any}(kw)
    if haskey(kwd, pk_kwarg)
        return get_object_or_404(qs; id = kwd[pk_kwarg])
    elseif haskey(kwd, slug_kwarg)
        return get_object_or_404(qs, Q(slug_field => kwd[slug_kwarg]))
    end
    error("Generic detail view must be called with either an object pk ($pk_kwarg) or a slug ($slug_kwarg) in the URLconf.")
end

"""
    DetailView(Model; template="<model>_detail.html", pk_kwarg=:id, slug_kwarg=:slug, slug_field=:slug)

The template gets `object` and `<model>`.
"""
function DetailView(::Type{T}; template = nothing, pk_kwarg = :id, slug_kwarg = :slug, slug_field = :slug,
                    queryset = nothing, context_object_name = nothing,
                    extra_context = Dict{String,Any}()) where {T<:Model}
    tname = something(template, "$(model_name(T))_detail.html")
    cname = something(context_object_name, model_name(T))
    name_view!(function (req::Request; kw...)
        obj = lookup_object(T, kw, pk_kwarg, slug_kwarg, slug_field, queryset, req)
        ctx = to_context_dict(resolve_value(extra_context, req))
        merge!(ctx, Dict{String,Any}("object" => obj, cname => obj))
        render(req, tname, ctx)
    end, "DetailView($(nameof(T)))")
end

function success_redirect(success_url, obj)
    url = success_url isa Function ? success_url(obj) : success_url
    url === nothing && (url = get_absolute_url(obj))
    url === nothing && error("No URL to redirect to. Provide success_url or define get_absolute_url for $(typeof(obj)).")
    HttpResponseRedirect(url)
end

function form_view(::Type{T}, req, obj, fields, template, success_url, extra_context, success_message) where {T}
    form = ModelForm(T; data = req.method == "POST" ? req.POST : nothing, files = req.FILES, instance = obj, fields = fields)
    if req.method == "POST" && is_valid(form)
        saved = save!(form)
        success_message === nothing || message!(req, :success, success_message)
        return success_redirect(success_url, saved)
    end
    ctx = to_context_dict(resolve_value(extra_context, req))
    merge!(ctx, Dict{String,Any}("form" => form, "object" => obj))
    obj === nothing || (ctx[model_name(T)] = obj)
    render(req, template, ctx)
end

"""
    CreateView(Model; fields=nothing, template="<model>_form.html", success_url=nothing, success_message=nothing)
"""
CreateView(::Type{T}; fields = nothing, template = nothing, success_url = nothing,
           extra_context = Dict{String,Any}(), success_message = nothing) where {T<:Model} =
    name_view!((req::Request; kw...) -> form_view(T, req, nothing, fields, something(template, "$(model_name(T))_form.html"),
                                                  success_url, extra_context, success_message), "CreateView($(nameof(T)))")

"""
    UpdateView(Model; fields=nothing, template="<model>_form.html", success_url=nothing, pk_kwarg=:id)
"""
UpdateView(::Type{T}; fields = nothing, template = nothing, success_url = nothing, pk_kwarg = :id,
           slug_kwarg = :slug, slug_field = :slug, queryset = nothing, extra_context = Dict{String,Any}(),
           success_message = nothing) where {T<:Model} =
    name_view!((req::Request; kw...) -> form_view(T, req, lookup_object(T, kw, pk_kwarg, slug_kwarg, slug_field, queryset, req),
                                                  fields, something(template, "$(model_name(T))_form.html"),
                                                  success_url, extra_context, success_message), "UpdateView($(nameof(T)))")

"""
    DeleteView(Model; success_url, template="<model>_confirm_delete.html", pk_kwarg=:id)

GET shows a confirmation page; POST deletes and redirects.
"""
function DeleteView(::Type{T}; success_url, template = nothing, pk_kwarg = :id, slug_kwarg = :slug,
                    slug_field = :slug, queryset = nothing, success_message = nothing) where {T<:Model}
    name_view!(function (req::Request; kw...)
        obj = lookup_object(T, kw, pk_kwarg, slug_kwarg, slug_field, queryset, req)
        if req.method == "POST"
            delete!(obj)
            success_message === nothing || message!(req, :success, success_message)
            return HttpResponseRedirect(success_url isa Function ? success_url(obj) : success_url)
        end
        render(req, something(template, "$(model_name(T))_confirm_delete.html"),
               Dict{String,Any}("object" => obj, model_name(T) => obj))
    end, "DeleteView($(nameof(T)))")
end
