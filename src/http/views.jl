# Shortcuts & generic views --------------------------------------------------------------------

"""
    render(req, template_name, context=Dict(); status=200, content_type="text/html; charset=utf-8")

Render a template with the request's context processors and return an `HttpResponse`.
`template_name` may also be a list (first existing is used) or a `Template`.

`htmx_partial = "name"` renders only the partial `{% partialdef name %}` of the template for
htmx requests (not for `hx-boost` ones or history restores, which want the whole page), and
the whole template otherwise; the response varies on `HX-Request`.
"""
function render(req::Request, template, context = Dict{String,Any}(); status = 200,
                content_type = "text/html; charset=utf-8", htmx_partial = nothing)
    if htmx_partial !== nothing && is_htmx(req; boosted = false)      # contrib/htmx.jl
        template isa AbstractString || throw(ArgumentError("render: htmx_partial needs a template name"))
        template = string(template, "#", htmx_partial)
    end
    t = template isa Template ? template : select_template(template)
    ctx = to_context_dict(context)
    # for the test client, response.context is what the template saw: the context processors' values, then the view's
    # (other engines' templates may not take processor_values)
    seen = get(req.meta, :test_client, false) && t isa Union{Template,MustacheTemplate} ? Dict{String,Any}() : nothing
    html = seen === nothing ? render(t, ctx; request = req) : render(t, ctx; request = req, processor_values = seen)
    resp = HttpResponse(html; status = status, content_type = content_type)
    resp.context = seen === nothing ? ctx : merge(seen, ctx)
    push!(resp.templates, t.name)
    resp
end

"""
    TemplateResponse(req, template, context = Dict(); status = 200, content_type = "text/html; charset=utf-8")

A response whose template is rendered at the last moment (Django's `TemplateResponse`): after
the view returns, middleware with a `process_template_response` method can still change
`resp.template_name` and `resp.context_data`. Once rendered, it's an ordinary response
(`resp.is_rendered`).
"""
function TemplateResponse(req::Request, template, context = Dict{String,Any}(); status = 200,
                          content_type = "text/html; charset=utf-8")
    r = HttpResponse(""; status = status, content_type = content_type)
    r.deferred = DeferredTemplate(req, template, to_context_dict(context))
    r
end

"Render a `TemplateResponse` now (nothing to do for other responses)."
function render_response!(r::HttpResponse)
    d = r.deferred
    d === nothing && return r
    out = render(d.request, d.template_name, d.context_data; status = r.status)
    r.body = out.body
    r.context = out.context
    append!(r.templates, out.templates)
    r.deferred = nothing
    r
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
Base.@nospecializeinfer function get_object_or_404(@nospecialize(qs), qargs::Q...; kw...)
    try
        get(qs, qargs...; kw...)
    catch e
        e isa DoesNotExist && throw(Http404("No $(nameof(e.model)) matches the given query."))
        rethrow()
    end
end
"Filter, raising `Http404` if nothing matches."
Base.@nospecializeinfer function get_list_or_404(@nospecialize(qs), qargs::Q...; kw...)
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
    Paginator(@nospecialize(items), per_page::Int, count::Int, num_pages::Int) = new(items, per_page, count, num_pages)
end
Base.@nospecializeinfer function Paginator(@nospecialize(items), per_page::Integer)
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

"""
    get_page(paginator, n) -> Page

Like `page`, but never raises (Django's `get_page`): a number that isn't one gives the first page,
and one past the end the last page. For `?page=` values from URLs that go stale.
"""
function get_page(p::Paginator, n)
    num = n isa Integer ? Int(n) : n == "last" ? p.num_pages : tryparse(Int, strip(string(n)))
    page(p, num === nothing ? 1 : clamp(num, 1, p.num_pages))
end

"Page `n` (1-based); accepts a string such as `req.GET[\"page\"]`. Raises `Http404` if out of range."
function page(p::Paginator, n)
    num = n isa Integer ? Int(n) : n == "last" ? p.num_pages : something(tryparse(Int, string(n)), 0)
    (1 <= num <= p.num_pages) || throw(Http404("Invalid page ($n)"))
    lo = (num - 1) * p.per_page + 1
    hi = min(num * p.per_page, p.count)
    objs = p.items isa QuerySet ? any_vector(fetch(p.items[lo:max(hi, lo - 1)])) : collect(Any, p.items[lo:hi])
    Page(objs, num, p, num < p.num_pages, num > 1, p.num_pages > 1,
         num < p.num_pages ? num + 1 : nothing, num > 1 ? num - 1 : nothing,
         p.count == 0 ? 0 : lo, hi, collect(1:p.num_pages))
end
Base.iterate(pg::Page, st...) = iterate(pg.object_list, st...)
Base.length(pg::Page) = length(pg.object_list)
truthy(pg::Page) = !isempty(pg.object_list)

# --- generic views ---------------------------------------------------------------------------
#
# Each generic view is a keyword constructor, and every step can be replaced with a hook:
#
#     ListView(Post; paginate_by = 10,
#              get_queryset = v -> filter(objects(Post); author = v.request.user),
#              get_context_data = (v, ctx) -> (ctx["now"] = now(); ctx))
#     CreateView(Post; fields = [:title, :body],
#                form_valid = (v, form) -> (form.instance.author = v.request.user; default_hook(:form_valid, v, form)),
#                login_required = true, success_message = "Created “%(title)s”.")
#
# A hook gets the `ViewCall` `v` (`v.request`, `v.kwargs` from the URL, `v.object`,
# `v.object_list`, `v.form`, `v.model`) and `default_hook(name, v, args...)` runs the built-in
# step (like `super()` in Django). Hooks: get_queryset, get_object, get_context_data,
# get_template_names, get_success_url, get_initial, get_form, form_valid, form_invalid.
# Access options on every view: login_required, permission_required, test_func (user -> Bool).

"The state of one call of a generic view, passed to its hooks."
mutable struct ViewCall
    kind::Symbol
    model::Any
    request::Request
    kwargs::Dict{Symbol,Any}
    opts::Dict{Symbol,Any}
    object::Any
    object_list::Any
    form::Any
end
Base.getproperty(v::ViewCall, s::Symbol) = s === :req ? getfield(v, :request) : getfield(v, s)
Base.show(io::IO, v::ViewCall) = print(io, "<", v.kind, v.model === nothing ? "" : "($(nameof(v.model)))", ">")

const HOOKS = (:get_queryset, :get_object, :get_context_data, :get_template_names, :get_success_url,
               :get_initial, :get_form, :form_valid, :form_invalid)
const HOOK_DEFAULTS = Dict{Symbol,Function}()

"Run a generic view's built-in step `name` (e.g. from inside your own hook)."
default_hook(name::Symbol, v::ViewCall, args...) = HOOK_DEFAULTS[name](v, args...)
"Run step `name`: the view's hook if given, else the default."
function hook(name::Symbol, v::ViewCall, args...)
    f = get(v.opts, name, nothing)
    f === nothing ? default_hook(name, v, args...) : f(v, args...)
end

model_name(T) = lowercase(string(nameof(T)))
resolve_value(x, req) = x isa Function ? x(req) : x
opt(v::ViewCall, k, default = nothing) = get(v.opts, k, default)

"""
Build a generic view: `run(v::ViewCall)` does the work. The access options are applied as
the matching decorators, so they run before anything else.
"""
Base.@nospecializeinfer function generic_view(run, kind::Symbol, @nospecialize(model), opts; label = string(kind, model === nothing ? "" : "($(nameof(model)))"))
    o = Dict{Symbol,Any}(pairs(opts))
    for k in keys(o)
        k in HOOKS || k in GENERIC_OPTIONS || throw(ArgumentError("$kind: unknown option '$k'"))
    end
    view = (req::Request; kw...) -> run(ViewCall(kind, model, req, Dict{Symbol,Any}(kw), copy(o), nothing, nothing, nothing))
    test = get(o, :test_func, nothing)
    test === nothing || (view = user_passes_test(view, test; login_url = get(o, :login_url, nothing)))
    perms = get(o, :permission_required, nothing)
    perms === nothing || (view = permission_required(view, (perms isa AbstractString ? [perms] : perms)...;
                                                     login_url = get(o, :login_url, nothing),
                                                     raise_exception = get(o, :raise_exception, true)))
    get(o, :login_required, false) && (view = login_required(view; login_url = get(o, :login_url, nothing)))
    name_view!(view, label)
end

const GENERIC_OPTIONS = Set([:template, :extra_context, :queryset, :paginate_by, :context_object_name, :allow_empty,
    :pk_kwarg, :slug_kwarg, :slug_field, :fields, :success_url, :success_message, :initial, :login_required,
    :permission_required, :test_func, :login_url, :raise_exception, :date_field, :allow_future, :make_object_list,
    :form, :object_permission_required])

"""
The view's object (the `get_object` hook), refused with 403 unless the user has every
`object_permission_required` permission *for that object* (`has_perm(user, perm; obj)`,
which a backend of your own decides; combine with `login_required = true`).
"""
function get_checked_object(v)
    obj = hook(:get_object, v)
    perms = opt(v, :object_permission_required)
    if perms !== nothing
        u = v.request.user
        all(p -> has_perm(u, p; obj = obj), perms isa AbstractString ? [perms] : perms) ||
            throw(PermissionDenied("You don't have permission to do this."))
    end
    obj
end

# --- the default steps ---

const TEMPLATE_SUFFIX = Dict(:ListView => "_list", :DetailView => "_detail", :CreateView => "_form", :UpdateView => "_form",
    :DeleteView => "_confirm_delete", :ArchiveIndexView => "_archive", :YearArchiveView => "_archive_year",
    :MonthArchiveView => "_archive_month", :DayArchiveView => "_archive_day", :DateDetailView => "_detail")

HOOK_DEFAULTS[:get_template_names] = function (v)
    t = opt(v, :template)
    t !== nothing && return t
    v.model === nothing && throw(ImproperlyConfigured("$(v.kind) needs a template"))
    model_name(v.model) * TEMPLATE_SUFFIX[v.kind] * ".html"
end

HOOK_DEFAULTS[:get_queryset] = function (v)
    qs = opt(v, :queryset)
    qs === nothing ? objects(v.model) : resolve_value(qs, v.request)
end

HOOK_DEFAULTS[:get_object] = function (v)
    qs = hook(:get_queryset, v)
    pk, slug = opt(v, :pk_kwarg, :id), opt(v, :slug_kwarg, :slug)
    haskey(v.kwargs, pk) && return get_object_or_404(qs; id = v.kwargs[pk])
    haskey(v.kwargs, slug) && return get_object_or_404(qs, Q(opt(v, :slug_field, :slug) => v.kwargs[slug]))
    error("Generic detail view $(v.kind) must be called with either an object pk ($pk) or a slug ($slug) in the URLconf.")
end

HOOK_DEFAULTS[:get_context_data] = (v, ctx) -> ctx

HOOK_DEFAULTS[:get_success_url] = function (v)
    url = opt(v, :success_url)
    url isa Function && return url(v.object)
    url === nothing || return string(url)
    u = v.object === nothing ? nothing : get_absolute_url(v.object)
    u === nothing && throw(ImproperlyConfigured("No URL to redirect to. Provide success_url" *
                                                (v.object === nothing ? "." : " or define get_absolute_url for $(typeof(v.object)).")))
    u
end

HOOK_DEFAULTS[:get_initial] = v -> to_symbol_dict(resolve_value(opt(v, :initial, Dict{Symbol,Any}()), v.request))
to_symbol_dict(d) = Dict{Symbol,Any}(Symbol(k) => x for (k, x) in pairs_of(d))

HOOK_DEFAULTS[:get_form] = function (v)
    data = v.request.method in ("POST", "PUT") ? v.request.POST : nothing
    files = v.request.method in ("POST", "PUT") ? v.request.FILES : nothing
    if v.kind === :FormView
        return opt(v, :form)(data; initial = hook(:get_initial, v), files = files)
    end
    form = ModelForm(v.model; data = data, files = files, instance = v.object, fields = opt(v, :fields), initial = hook(:get_initial, v))
    # CreateView: an unsaved instance, so a form_valid hook can set fields the form doesn't have
    # (`form.instance.author = v.request.user`) before the default step saves it
    form.instance === nothing && (form.instance = v.model())
    form
end

"The success message with `%(field)s` filled in from the form's cleaned data (or a function of it)."
function success_message!(v::ViewCall, form)
    msg = opt(v, :success_message)
    msg === nothing && return
    data = form === nothing ? Dict{String,Any}() : Dict{String,Any}(string(k) => x for (k, x) in form.cleaned_data)
    message!(v.request, :success, msg isa Function ? msg(data) : interpolate(string(msg), data))
end

HOOK_DEFAULTS[:form_valid] = function (v, form)
    if v.kind === :DeleteView
        delete!(v.object)
    elseif v.kind !== :FormView
        v.object = save!(form)
    end
    success_message!(v, form)
    HttpResponseRedirect(hook(:get_success_url, v))
end

HOOK_DEFAULTS[:form_invalid] = (v, form) -> render_view(v, Dict{String,Any}("form" => form))

"Render the view's template with `ctx` plus extra_context, `view` and the object, through get_context_data."
function render_view(v::ViewCall, ctx::Dict{String,Any})
    base = to_context_dict(resolve_value(opt(v, :extra_context, Dict{String,Any}()), v.request))
    base["view"] = v
    if v.object !== nothing
        base["object"] = v.object
        v.model === nothing || (base[something(opt(v, :context_object_name), model_name(v.model))] = v.object)
    end
    merge!(base, ctx)
    render(v.request, hook(:get_template_names, v), hook(:get_context_data, v, base))
end

"Paginate `v.object_list` into `ctx` (object_list, <model>_list, page_obj, paginator, is_paginated)."
Base.@nospecializeinfer function list_context!(ctx, v::ViewCall, @nospecialize(objs); cname = v.model === nothing ? nothing : "$(model_name(v.model))_list")
    n = opt(v, :paginate_by)
    cname = something(opt(v, :context_object_name), cname, "object_list")
    if n !== nothing
        p = Paginator(objs, n)
        pg = page(p, get(v.request.GET, "page", "1"))
        merge!(ctx, Dict{String,Any}("paginator" => p, "page_obj" => pg, "is_paginated" => p.num_pages > 1,
                                     "object_list" => pg.object_list, cname => pg.object_list))
    else
        list = collect(objs)
        merge!(ctx, Dict{String,Any}("object_list" => list, cname => list, "is_paginated" => false))
    end
    ctx
end

# --- the views ---

"`TemplateView(\"about.html\"; extra_context=Dict(), get_context_data=...)`: render a template (URL kwargs go into the context)."
TemplateView(template; kw...) =
    generic_view(:TemplateView, nothing, (; template, kw...); label = "TemplateView($(repr(template)))") do v
        render_view(v, Dict{String,Any}(string(k) => x for (k, x) in v.kwargs))
    end

"`RedirectView(url_or_name; permanent=false)`."
RedirectView(to; permanent = false) =
    name_view!((req; kw...) -> redirect(to; permanent = permanent, kw...), "RedirectView($(repr(to)))")

"""
    ListView(Model; template="<model>_list.html", queryset=nothing, paginate_by=nothing,
             context_object_name="<model>_list", allow_empty=true, extra_context=Dict(), hooks...)

`queryset` may be a `QuerySet` or a function `req -> QuerySet` (or use the `get_queryset`
hook). The template gets `object_list`, `<model>_list` and, when paginating, `page_obj`,
`paginator` and `is_paginated`.
"""
ListView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:ListView, T, kw) do v
        v.object_list = hook(:get_queryset, v)
        opt(v, :allow_empty, true) || exists_any(v.object_list) || throw(Http404("Empty list and allow_empty is false."))
        render_view(v, list_context!(Dict{String,Any}(), v, v.object_list))
    end
exists_any(qs::QuerySet) = exists(qs)
exists_any(xs) = !isempty(xs)

"""
    DetailView(Model; template="<model>_detail.html", pk_kwarg=:id, slug_kwarg=:slug, slug_field=:slug, hooks...)

The template gets `object` and `<model>`.
"""
DetailView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:DetailView, T, kw) do v
        v.object = get_checked_object(v)
        render_view(v, Dict{String,Any}())
    end

function run_form_view(v::ViewCall)
    v.form = hook(:get_form, v)
    v.request.method in ("POST", "PUT") || return render_view(v, Dict{String,Any}("form" => v.form))
    is_valid(v.form) ? hook(:form_valid, v, v.form) : hook(:form_invalid, v, v.form)
end

"""
    CreateView(Model; fields=nothing, template="<model>_form.html", success_url=nothing,
               success_message=nothing, initial=Dict(), hooks...)

`success_url` may be a function of the new object; without one, its `get_absolute_url` is used.
`success_message` may use `%(field)s` placeholders from the cleaned data.
"""
CreateView(::Type{T}; kw...) where {T<:Model} = generic_view(run_form_view, :CreateView, T, kw)

"""
    UpdateView(Model; fields=nothing, template="<model>_form.html", success_url=nothing, pk_kwarg=:id, hooks...)
"""
UpdateView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:UpdateView, T, kw) do v
        v.object = get_checked_object(v)
        run_form_view(v)
    end

"""
    DeleteView(Model; success_url, template="<model>_confirm_delete.html", pk_kwarg=:id, hooks...)

GET shows a confirmation page; POST deletes (the `form_valid` step, with `form === nothing`)
and redirects.
"""
DeleteView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:DeleteView, T, kw) do v
        v.object = get_checked_object(v)
        v.request.method == "POST" ? hook(:form_valid, v, nothing) : render_view(v, Dict{String,Any}())
    end

"""
    FormView(FormType; template, success_url, initial=Dict(), form_valid=..., hooks...)

Show a form (made with `@form`); on a valid POST run `form_valid(v, form)`, which by default
just redirects to `success_url`. Override it to do the work:

    contact = FormView(ContactForm; template = "contact.html", success_url = "/thanks/",
                       form_valid = (v, f) -> (send_mail(...); default_hook(:form_valid, v, f)))
"""
FormView(form; kw...) = generic_view(run_form_view, :FormView, nothing, (; form, kw...); label = "FormView($form)")

# --- date-based archives ---
#
#     path("archive/", ArchiveIndexView(Post; date_field = :published)),
#     path("archive/<int:year>/", YearArchiveView(Post; date_field = :published)),
#     path("archive/<int:year>/<int:month>/", MonthArchiveView(Post; date_field = :published)),
#     path("archive/<int:year>/<int:month>/<int:day>/", DayArchiveView(Post; date_field = :published)),
#     path("archive/<int:year>/<int:month>/<int:day>/<slug:slug>/", DateDetailView(Post; date_field = :published)),
#
# Objects dated in the future are left out unless `allow_future = true`; an empty period is a
# 404 unless `allow_empty = true`. With USE_TZ, periods are days in the current time zone.

"The local calendar date of a stored date or datetime."
function local_date(x)
    x isa TimeZones.ZonedDateTime && return Date(make_naive(x))
    x isa DateTime && return Date(x)
    x isa Date && return x
    x === nothing && return nothing
    d = todatetime(string(x))
    d === nothing ? nothing : Date(d)
end

date_field(v::ViewCall) = opt(v, :date_field) === nothing ? throw(ImproperlyConfigured("$(v.kind) needs date_field")) :
    Symbol(opt(v, :date_field))
function is_datetime_field(v::ViewCall)
    f = findfield(modelmeta(v.model), date_field(v))
    f === nothing && throw(ImproperlyConfigured("$(nameof(v.model)) has no field '$(date_field(v))'"))
    f.kind === :datetime
end
"A date as a filter bound: midnight local time for datetime fields."
bound(v::ViewCall, d::Date) = is_datetime_field(v) ? DateTime(d) : d

"The queryset with future objects removed unless allow_future."
function dated_queryset(v::ViewCall)
    qs = hook(:get_queryset, v)
    opt(v, :allow_future, false) && return qs
    df = date_field(v)
    now_ = is_datetime_field(v) ? timezone_now() : today()
    filter(qs, Q(Symbol(df, "__lte") => now_))
end
Base.@nospecializeinfer in_period(v, @nospecialize(qs), lo::Date, hi::Date) =
    filter(qs, Q(Symbol(date_field(v), "__gte") => bound(v, lo)) & Q(Symbol(date_field(v), "__lt") => bound(v, hi)))
Base.@nospecializeinfer dates_of(v, @nospecialize(qs)) = Date[d for d in (local_date(x) for x in values_list(qs, date_field(v); flat = true)) if d !== nothing]

"The start of the period holding the nearest object after `hi` / before `lo` (nothing if none)."
Base.@nospecializeinfer function next_period(v, @nospecialize(qs), hi::Date, start)
    o = first(order_by(filter(qs, Q(Symbol(date_field(v), "__gte") => bound(v, hi))), string(date_field(v))))
    o === nothing ? nothing : start(local_date(getproperty(o, date_field(v))))
end
Base.@nospecializeinfer function previous_period(v, @nospecialize(qs), lo::Date, start)
    o = first(order_by(filter(qs, Q(Symbol(date_field(v), "__lt") => bound(v, lo))), "-" * string(date_field(v))))
    o === nothing ? nothing : start(local_date(getproperty(o, date_field(v))))
end

function url_int(v::ViewCall, k)
    x = get(v.kwargs, k, nothing)
    x isa Integer && return Int(x)
    n = x === nothing ? nothing : tryparse(Int, string(x))
    n === nothing ? throw(Http404("Invalid $k")) : n
end

function period_date(v::ViewCall, parts...)
    try
        Date(parts...)
    catch
        throw(Http404("Invalid date"))
    end
end

Base.@nospecializeinfer function archive_response(v::ViewCall, @nospecialize(objs), ctx::Dict{String,Any})
    nonempty = exists_any(objs)
    opt(v, :allow_empty, false) || nonempty || throw(Http404("No $(nameof(v.model)) objects available"))
    v.object_list = objs
    render_view(v, list_context!(ctx, v, objs; cname = nothing))
end

"""
    ArchiveIndexView(Model; date_field, allow_future=false, allow_empty=false, paginate_by=nothing, hooks...)

The latest objects, newest first. The template (`<model>_archive.html`) gets `latest`,
`object_list` and `date_list` (the first day of each year that has objects, newest first).
"""
ArchiveIndexView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:ArchiveIndexView, T, kw) do v
        qs = order_by(dated_queryset(v), "-" * string(date_field(v)))
        years = sort(unique(Date.(year.(dates_of(v, qs)))); rev = true)
        haskey(v.opts, :context_object_name) || (v.opts[:context_object_name] = "latest")
        archive_response(v, qs, Dict{String,Any}("date_list" => years))
    end

"""
    YearArchiveView(Model; date_field, make_object_list=false, allow_future=false, allow_empty=false, hooks...)

URL kwarg `year`. The template (`<model>_archive_year.html`) gets `year` (a `Date`),
`date_list` (months with objects), `next_year`/`previous_year` (or `nothing`), and the year's
objects as `object_list` only with `make_object_list = true`.
"""
YearArchiveView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:YearArchiveView, T, kw) do v
        y = period_date(v, url_int(v, :year))
        all_ = dated_queryset(v)
        qs = order_by(in_period(v, all_, y, y + Year(1)), string(date_field(v)))
        months = sort(unique(firstdayofmonth.(dates_of(v, qs))))
        opt(v, :allow_empty, false) || !isempty(months) || throw(Http404("No $(nameof(v.model)) objects in $(year(y))"))
        objs = opt(v, :make_object_list, false) ? qs : Any[]
        v.object_list = objs
        render_view(v, list_context!(Dict{String,Any}("year" => y, "date_list" => months,
            "next_year" => next_period(v, all_, y + Year(1), firstdayofyear),
            "previous_year" => previous_period(v, all_, y, firstdayofyear)), v, objs; cname = nothing))
    end

"""
    MonthArchiveView(Model; date_field, allow_future=false, allow_empty=false, paginate_by=nothing, hooks...)

URL kwargs `year`, `month` (a number). The template (`<model>_archive_month.html`) gets
`month` (a `Date`), `object_list`, `date_list` (days with objects) and `next_month`/`previous_month`.
"""
MonthArchiveView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:MonthArchiveView, T, kw) do v
        m = period_date(v, url_int(v, :year), url_int(v, :month))
        all_ = dated_queryset(v)
        qs = order_by(in_period(v, all_, m, m + Month(1)), string(date_field(v)))
        archive_response(v, qs, Dict{String,Any}("month" => m, "date_list" => sort(unique(dates_of(v, qs))),
            "next_month" => next_period(v, all_, m + Month(1), firstdayofmonth),
            "previous_month" => previous_period(v, all_, m, firstdayofmonth)))
    end

"""
    DayArchiveView(Model; date_field, allow_future=false, allow_empty=false, paginate_by=nothing, hooks...)

URL kwargs `year`, `month`, `day`. The template (`<model>_archive_day.html`) gets `day`,
`object_list` and `next_day`/`previous_day`.
"""
DayArchiveView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:DayArchiveView, T, kw) do v
        d = period_date(v, url_int(v, :year), url_int(v, :month), url_int(v, :day))
        all_ = dated_queryset(v)
        qs = order_by(in_period(v, all_, d, d + Day(1)), string(date_field(v)))
        archive_response(v, qs, Dict{String,Any}("day" => d,
            "next_day" => next_period(v, all_, d + Day(1), identity),
            "previous_day" => previous_period(v, all_, d, identity)))
    end

"""
    DateDetailView(Model; date_field, allow_future=false, pk_kwarg=:id, slug_kwarg=:slug, hooks...)

One object, found by `year`/`month`/`day` plus pk or slug: a 404 unless it is dated that day.
"""
DateDetailView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:DateDetailView, T, kw) do v
        d = period_date(v, url_int(v, :year), url_int(v, :month), url_int(v, :day))
        base = get(v.opts, :get_queryset, nothing)            # v.opts is this call's own copy
        v.opts[:get_queryset] = w -> in_period(w, base === nothing ? dated_queryset_default(w) : base(w), d, d + Day(1))
        v.object = get_checked_object(v)
        render_view(v, Dict{String,Any}())
    end
function dated_queryset_default(v)
    qs = default_hook(:get_queryset, v)
    opt(v, :allow_future, false) ? qs :
        filter(qs, Q(Symbol(date_field(v), "__lte") => (is_datetime_field(v) ? timezone_now() : today())))
end

# --- mixins as wrappers ---

"`LoginRequiredMixin(view)`: the same as `login_required(view)` (or the `login_required = true` option)."
LoginRequiredMixin(view; login_url = nothing) = login_required(view; login_url = login_url)
"`PermissionRequiredMixin(view, \"app.perm\"...)`: the same as `permission_required` (or the option)."
PermissionRequiredMixin(view, perms::AbstractString...; kw...) = permission_required(view, perms...; kw...)
"`UserPassesTestMixin(view, user -> Bool)`: the same as `user_passes_test` (or the `test_func` option)."
UserPassesTestMixin(view, test; kw...) = user_passes_test(view, test; kw...)
