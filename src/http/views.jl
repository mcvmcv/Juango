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
    resolve_url(to, args...; kwargs...) -> String

Where `to` points, as Django's: a model instance's `get_absolute_url`, a relative URL
(`"./"`, `"../"`) as it is, a URL pattern name reversed with `args`/`kwargs`, and otherwise text
that looks like a URL (it has a `/` or a `.`). A name that doesn't reverse and doesn't look like a
URL is a `NoReverseMatch`, not a redirect to the misspelled name.
"""
function resolve_url(to, args...; kwargs...)
    if to isa Model
        u = get_absolute_url(to)
        u === nothing && throw(ArgumentError("$(typeof(to)) does not define get_absolute_url"))
        return string(u)
    end
    s = string(to)
    (startswith(s, "./") || startswith(s, "../")) && return s
    # (a URL with a scheme or a path is used as it is without trying it as a name)
    (occursin(r"^[A-Za-z][A-Za-z0-9+.\-]*://", s) || startswith(s, "/")) && return s
    try
        return reverse_url(s, args...; kwargs...)
    catch e
        e isa NoReverseMatch || rethrow()
        (occursin('/', s) || occursin('.', s)) || rethrow()
    end
    s
end

"""
    redirect(to, args...; permanent = false, preserve_request = false, kwargs...)

A redirect to `resolve_url(to, args...; kwargs...)`: a URL (`"/posts/"`, `"https://…"`), a URL
pattern name (reversed with `args`/`kwargs`), or a model instance with `get_absolute_url`.
`preserve_request = true` keeps the method and body (307, or 308 when permanent; Django 5.2).
"""
function redirect(to, args...; permanent = false, preserve_request = false, kwargs...)
    url = resolve_url(to, args...; kwargs...)
    HttpResponseRedirect(url; status = preserve_request ? (permanent ? 308 : 307) : (permanent ? 301 : 302))
end

# (as Django's: a model, its manager's queryset or a QuerySet; anything else is a mistake worth saying so)
function check_queryset_arg(@nospecialize(qs), fname)
    qs isa QuerySet || (qs isa Type && qs <: Model) ||
        throw(ArgumentError("First argument to $fname() must be a Model, Manager, or QuerySet, not '$(qs isa Type ? nameof(qs) : nameof(typeof(qs)))'."))
end
"Get one object or raise `Http404` (more than one is still `MultipleObjectsReturned`)."
function get_object_or_404(@nospecialize(qs), qargs::Q...; kw...)
    check_queryset_arg(qs, "get_object_or_404")
    try
        get(qs, qargs...; kw...)
    catch e
        e isa DoesNotExist && throw(Http404("No $(nameof(e.model)) matches the given query."))
        rethrow()
    end
end
"Filter, raising `Http404` if nothing matches."
function get_list_or_404(@nospecialize(qs), qargs::Q...; kw...)
    check_queryset_arg(qs, "get_list_or_404")
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
"GET and HEAD only (Django's `require_safe`, for views that must not change anything)."
require_safe(view) = require_http_methods(view, ["GET", "HEAD"])

"""
    gzip_page(view)

Compress this view's responses when the client accepts gzip, as GZipMiddleware does for every view.
"""
function gzip_page(view)
    w = (req; kw...) -> GZipMiddleware(r -> to_response(view(r; kw...)))(req)
    propagate_flags!(w, view)
end

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
    orphans::Int
    allow_empty_first_page::Bool
    error_messages::Dict{Symbol,String}
    Paginator(@nospecialize(items), per_page::Int, count::Int, num_pages::Int, orphans::Int = 0, allow_empty_first_page::Bool = true,
              error_messages::Dict{Symbol,String} = Dict{Symbol,String}()) =
        new(items, per_page, count, num_pages, orphans, allow_empty_first_page, error_messages)
end
"""
    Paginator(items, per_page; orphans = 0, allow_empty_first_page = true, error_messages = Dict())

As Django's: the last page takes up to `orphans` more items rather than leaving them on a page of
their own; with `allow_empty_first_page = false` an empty list has no pages. `error_messages`
replaces the messages of `:invalid_page`, `:min_page` and `:no_results` (Django 5.0).
`p.page_range` is `1:p.num_pages`.
"""
Base.@nospecializeinfer function Paginator(@nospecialize(items), per_page::Integer; orphans::Integer = 0, allow_empty_first_page::Bool = true,
                                           error_messages = Dict{Symbol,String}())
    items isa QuerySet && warn_unordered(items, "Paginating")          # (Django's UnorderedObjectListWarning)
    n = items isa QuerySet ? count(items) : length(items)
    pages = n == 0 && !allow_empty_first_page ? 0 : cld(max(1, n - orphans), per_page)
    Paginator(items, Int(per_page), n, pages, Int(orphans), allow_empty_first_page,
              Dict{Symbol,String}(Symbol(k) => string(v) for (k, v) in pairs_of(error_messages)))
end
Base.getproperty(p::Paginator, s::Symbol) = s === :page_range ? (1:getfield(p, :num_pages)) : getfield(p, s)
tattr(p::Paginator, ::Val{:page_range}) = collect(1:p.num_pages)

"""
A page number a paginator can't give (Django's InvalidPage): `PageNotAnInteger` for one that isn't
a number, `EmptyPage` for one out of range. A view that lets one through answers 404.
"""
abstract type InvalidPage <: Exception end
struct PageNotAnInteger <: InvalidPage
    msg::String
end
struct EmptyPage <: InvalidPage
    msg::String
end
Base.showerror(io::IO, e::InvalidPage) = print(io, nameof(typeof(e)), ": ", e.msg)
page_message(p::Paginator, k::Symbol, default) = gettext(get(p.error_messages, k, default))

"""
    validate_number(paginator, n) -> Int

The page number `n` (an integer, a whole float, its text, or `"last"`), as Django's: `PageNotAnInteger`
if it isn't one, `EmptyPage` if it's below 1 or past the last page (page 1 of an empty list is fine
unless `allow_empty_first_page = false`).
"""
function validate_number(p::Paginator, n)
    num = n isa Integer ? Int(n) : n isa AbstractFloat ? (isinteger(n) ? Int(n) : nothing) :
          n == "last" ? p.num_pages : n isa AbstractString ? tryparse(Int, strip(n)) : nothing
    num === nothing && throw(PageNotAnInteger(page_message(p, :invalid_page, "That page number is not an integer")))
    num < 1 && throw(EmptyPage(page_message(p, :min_page, "That page number is less than 1")))
    if num > p.num_pages
        (num == 1 && p.allow_empty_first_page) || throw(EmptyPage(page_message(p, :no_results, "That page contains no results")))
    end
    num
end

"""
    get_elided_page_range(paginator, number = 1; on_each_side = 3, on_ends = 2)

The page numbers to show around page `number`, with `Paginator.ELLIPSIS` ("…") for the gaps, as
Django's: `[1, 2, "…", 7, 8, 9, 10, 11, 12, 13, "…", 49, 50]`.
"""
function get_elided_page_range(p::Paginator, number = 1; on_each_side::Integer = 3, on_ends::Integer = 2)
    number = validate_number(p, number)
    n = p.num_pages
    n <= (on_each_side + on_ends) * 2 && return Any[i for i in 1:n]
    out = Any[]
    if number > 1 + on_each_side + on_ends + 1
        append!(out, 1:on_ends); push!(out, PAGINATOR_ELLIPSIS); append!(out, (number - on_each_side):number)
    else
        append!(out, 1:number)
    end
    if number < n - on_each_side - on_ends - 1
        append!(out, (number + 1):(number + on_each_side)); push!(out, PAGINATOR_ELLIPSIS); append!(out, (n - on_ends + 1):n)
    else
        append!(out, (number + 1):n)
    end
    out
end
const PAGINATOR_ELLIPSIS = "\u2026"

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

Like `page`, but lenient (Django's `get_page`): a number that isn't one gives the first page, and
one out of range (0, negative, past the end) the last page. For `?page=` values from URLs that go
stale. (Only an empty list with `allow_empty_first_page = false` has no page to give.)
"""
function get_page(p::Paginator, n)
    num = try
        validate_number(p, n)
    catch e
        e isa PageNotAnInteger ? 1 : e isa EmptyPage ? p.num_pages : rethrow()
    end
    page(p, num)
end

"""
Page `n` (1-based); accepts a string such as `req.GET[\"page\"]` and `"last"`. Throws
`PageNotAnInteger` or `EmptyPage` (a 404 if a view lets it through), as Django's.
"""
function page(p::Paginator, n)
    num = validate_number(p, n)
    lo = (num - 1) * p.per_page + 1
    hi = num * p.per_page + p.orphans >= p.count ? p.count : num * p.per_page      # (the last page takes the orphans)
    objs = p.items isa QuerySet ? any_vector(fetch(p.items[lo:max(hi, lo - 1)])) : collect(Any, p.items[lo:hi])
    Page(objs, num, p, num < p.num_pages, num > 1, p.num_pages > 1,
         num < p.num_pages ? num + 1 : nothing, num > 1 ? num - 1 : nothing,
         p.count == 0 ? 0 : lo, hi, collect(1:p.num_pages))
end
Base.iterate(pg::Page, st...) = iterate(pg.object_list, st...)
Base.length(pg::Page) = length(pg.object_list)
Base.getindex(pg::Page, i) = pg.object_list[i]
Base.lastindex(pg::Page) = lastindex(pg.object_list)
Base.show(io::IO, pg::Page) = print(io, "<Page ", pg.number, " of ", pg.paginator.num_pages, ">")
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
    # (as Django's View: methods the view doesn't handle get 405 with an Allow header, OPTIONS the Allow header)
    allowed = String[uppercase(string(m)) for m in get(o, :http_method_names, VIEW_METHODS[kind])]
    "GET" in allowed && !("HEAD" in allowed) && push!(allowed, "HEAD")
    "OPTIONS" in allowed || push!(allowed, "OPTIONS")
    view = function (req::Request; kw...)
        req.method in allowed || return HttpResponseNotAllowed(allowed)
        if req.method == "OPTIONS"
            r = HttpResponse("")
            setheader!(r, "Allow", join(allowed, ", "))
            setheader!(r, "Content-Length", "0")
            return r
        end
        run(ViewCall(kind, model, req, Dict{Symbol,Any}(kw), copy(o), nothing, nothing, nothing))
    end
    test = get(o, :test_func, nothing)
    # (Django's UserPassesTestMixin: a logged-in user who fails it gets 403, an anonymous one the login page)
    test === nothing || (view = UserPassesTestMixin(view, test; login_url = get(o, :login_url, nothing),
                                                    raise_exception = get(o, :raise_exception, false)))
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
    :form, :object_permission_required, :week_format, :month_format, :http_method_names, :ordering, :page_kwarg,
    :paginate_orphans, :query_pk_and_slug, :template_name_suffix])

# The methods each view answers, as Django's (HEAD with GET, and OPTIONS, are added); `http_method_names` replaces them.
const READ_METHODS = ("GET",)
const VIEW_METHODS = Dict{Symbol,Any}(:TemplateView => READ_METHODS, :ListView => READ_METHODS, :DetailView => READ_METHODS,
    :ArchiveIndexView => READ_METHODS, :YearArchiveView => READ_METHODS, :MonthArchiveView => READ_METHODS,
    :DayArchiveView => READ_METHODS, :WeekArchiveView => READ_METHODS, :TodayArchiveView => READ_METHODS,
    :DateDetailView => READ_METHODS, :CreateView => ("GET", "POST", "PUT"), :UpdateView => ("GET", "POST", "PUT"),
    :FormView => ("GET", "POST", "PUT"), :DeleteView => ("GET", "POST", "DELETE"))

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
    :MonthArchiveView => "_archive_month", :DayArchiveView => "_archive_day", :DateDetailView => "_detail",
    :WeekArchiveView => "_archive_week", :TodayArchiveView => "_archive_day")

# (as Django's: "<app_label>/<model><suffix>.html" first, then Juango's "<model><suffix>.html")
HOOK_DEFAULTS[:get_template_names] = function (v)
    t = opt(v, :template)
    t !== nothing && return t
    v.model === nothing && throw(ImproperlyConfigured("$(v.kind) requires either a definition of 'template' or an implementation of 'get_template_names'"))
    name = model_name(v.model) * string(opt(v, :template_name_suffix, TEMPLATE_SUFFIX[v.kind])) * ".html"
    [modelmeta(v.model).app * "/" * name, name]
end

HOOK_DEFAULTS[:get_queryset] = function (v)
    qs = opt(v, :queryset)
    qs = qs === nothing ? objects(v.model) : resolve_value(qs, v.request)
    o = opt(v, :ordering)                      # (Django's MultipleObjectMixin.ordering)
    o === nothing ? qs : order_by(qs, (o isa AbstractString || o isa Symbol ? (o,) : o)...)
end

# (the pk comes from pk_kwarg, or Django's `pk` or Juango's `id` when it isn't given; with both a pk
# and a slug, the slug is checked too only with query_pk_and_slug, as Django's)
HOOK_DEFAULTS[:get_object] = function (v)
    qs = hook(:get_queryset, v)
    pkk = opt(v, :pk_kwarg)
    pk = pkk !== nothing ? Symbol(pkk) : haskey(v.kwargs, :pk) ? :pk : :id
    slug = Symbol(opt(v, :slug_kwarg, :slug))
    if haskey(v.kwargs, pk)
        q = Q(pk = v.kwargs[pk])
        haskey(v.kwargs, slug) && opt(v, :query_pk_and_slug, false) && (q = q & Q(Symbol(opt(v, :slug_field, :slug)) => v.kwargs[slug]))
        return get_object_or_404(qs, q)
    end
    haskey(v.kwargs, slug) && return get_object_or_404(qs, Q(Symbol(opt(v, :slug_field, :slug)) => v.kwargs[slug]))
    throw(ArgumentError("Generic detail view $(v.kind) must be called with either an object pk or a slug in the URLconf."))
end

HOOK_DEFAULTS[:get_context_data] = (v, ctx) -> ctx

# "{field}" in a success_url is the object's value (Django's success_url.format(**object.__dict__))
function format_success_url(url::AbstractString, obj)
    obj === nothing && return String(url)
    replace(url, r"\{(\w+)\}" => m -> (f = Symbol(m[2:end-1]); string(something(getproperty(obj, f), ""))))
end
HOOK_DEFAULTS[:get_success_url] = function (v)
    url = opt(v, :success_url)
    url isa Function && return url(v.object)
    url === nothing || return format_success_url(string(url), v.object)
    # (as Django's: a deleted object's own URL is no place to go)
    u = v.object === nothing || v.kind === :DeleteView ? nothing : get_absolute_url(v.object)
    u === nothing && throw(ImproperlyConfigured(v.object === nothing || v.kind === :DeleteView ? "No URL to redirect to. Provide a success_url." :
        "No URL to redirect to.  Either provide a url or define a get_absolute_url method on the Model."))
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
        url = hook(:get_success_url, v)              # (before the delete, as Django's: "{id}" still has a value)
        delete!(v.object)
        success_message!(v, form)
        return HttpResponseRedirect(url)
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
        p = Paginator(objs, n; orphans = opt(v, :paginate_orphans, 0), allow_empty_first_page = opt(v, :allow_empty, true))
        pk = string(opt(v, :page_kwarg, "page"))
        # (the page from the URL's kwargs, else the query string, as Django's)
        raw = something(get(v.kwargs, Symbol(pk), nothing), get(v.request.GET, pk, nothing), "1")
        pg = try
            page(p, raw)
        catch e
            e isa InvalidPage || rethrow()
            throw(Http404("Invalid page ($raw): $(e.msg)"))     # (Django's message)
        end
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

"""
    RedirectView(url_or_name; permanent = false, query_string = false)

As Django's: a URL (with `%(kwarg)s` placeholders filled from the URL's kwargs) or a URL name,
reversed with them (Django's `pattern_name`); `query_string = true` keeps the request's query
string. `RedirectView(nothing)` answers 410 Gone. Every method is redirected.
"""
function RedirectView(to; permanent = false, query_string = false)
    view = function (req; kw...)
        to === nothing && return HttpResponseGone("")
        url = to isa AbstractString && occursin('/', to) ? interpolate(to, Dict{String,Any}(string(k) => x for (k, x) in kw)) :
              getheader(redirect(to; kw...), "Location")
        query_string && !isempty(req.query_string) && (url *= "?" * req.query_string)
        permanent ? HttpResponsePermanentRedirect(url) : HttpResponseRedirect(url)
    end
    name_view!(view, "RedirectView($(repr(to)))")
end

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
        v.request.method in ("POST", "DELETE") ? hook(:form_valid, v, nothing) : render_view(v, Dict{String,Any}())
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

"""
The start of the next period (after `hi`) / the previous one (before `lo`), as Django's: with
`allow_empty` simply the adjacent period (none in the future unless `allow_future`), else the
period of the nearest object (nothing if none).
"""
Base.@nospecializeinfer function next_period(v, @nospecialize(qs), hi::Date, start)
    if opt(v, :allow_empty, false)
        return opt(v, :allow_future, false) || hi <= localdate() ? hi : nothing
    end
    o = first(order_by(filter(qs, Q(Symbol(date_field(v), "__gte") => bound(v, hi))), string(date_field(v))))
    o === nothing ? nothing : start(local_date(getproperty(o, date_field(v))))
end
Base.@nospecializeinfer function previous_period(v, @nospecialize(qs), lo::Date, start)
    if opt(v, :allow_empty, false)
        p = start(lo - Day(1))
        return opt(v, :allow_future, false) || p <= localdate() ? p : nothing
    end
    o = first(order_by(filter(qs, Q(Symbol(date_field(v), "__lt") => bound(v, lo))), "-" * string(date_field(v))))
    o === nothing ? nothing : start(local_date(getproperty(o, date_field(v))))
end

function url_int(v::ViewCall, k)
    x = get(v.kwargs, k, nothing)
    x isa Integer && return Int(x)
    n = x === nothing ? nothing : tryparse(Int, string(x))
    n === nothing ? throw(Http404("Invalid $k")) : n
end

const MONTH_ABBRS = ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec")
"""
The URL's month: as `month_format` says, Django's `"%b"` (jan, feb, ...: Django's default) or
`"%m"` (a number); by default either.
"""
function url_month(v::ViewCall)
    x = get(v.kwargs, :month, nothing)
    x === nothing && throw(Http404("No month specified"))
    fmt = opt(v, :month_format)
    if fmt != "%b"
        x isa Integer && return Int(x)
        n = tryparse(Int, string(x))
        n === nothing || return n
        fmt == "%m" && throw(Http404("Invalid month"))
    end
    i = findfirst(==(lowercase(string(x))), MONTH_ABBRS)
    i === nothing ? throw(Http404("Invalid date string '$x' given format '%b'")) : i
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
        m = period_date(v, url_int(v, :year), url_month(v))
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
        d = period_date(v, url_int(v, :year), url_month(v), url_int(v, :day))
        day_archive(v, d)
    end

"""
    week_start(year, week, format = "%U") -> Date

The first day of a week as Django's `week_format` numbers them: `"%U"` (weeks start on Sunday,
week 1 has the year's first Sunday), `"%W"` (the same from Monday) or `"%V"` (ISO 8601: Monday,
week 1 holds January 4th; `year` is then the ISO year).
"""
function week_start(year::Integer, week::Integer, format = "%U")
    jan1 = Date(year, 1, 1)
    format == "%V" && (jan4 = Date(year, 1, 4); return jan4 - Day(dayofweek(jan4) - 1) + Week(week - 1))
    first_ = format == "%W" ? jan1 + Day(mod(1 - dayofweek(jan1), 7)) :     # the year's first Monday
             format == "%U" ? jan1 + Day(mod(7 - dayofweek(jan1), 7)) :     # its first Sunday
             throw(ArgumentError("week_format must be \"%U\", \"%W\" or \"%V\""))
    first_ + Week(week - 1)
end

"""
    WeekArchiveView(Model; date_field, week_format="%U", allow_future=false, allow_empty=false, paginate_by=nothing, hooks...)

URL kwargs `year`, `week`. The template (`<model>_archive_week.html`) gets `week` (its first
day), `object_list` and `next_week`/`previous_week`.
"""
WeekArchiveView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:WeekArchiveView, T, kw) do v
        fmt = string(opt(v, :week_format, "%U"))
        w = try
            week_start(url_int(v, :year), url_int(v, :week), fmt)
        catch e
            e isa ArgumentError && rethrow()
            throw(Http404("Invalid week"))
        end
        start_of(d) = d - Day(fmt == "%U" ? mod(dayofweek(d), 7) : dayofweek(d) - 1)
        all_ = dated_queryset(v)
        qs = order_by(in_period(v, all_, w, w + Week(1)), string(date_field(v)))
        archive_response(v, qs, Dict{String,Any}("week" => w,
            "next_week" => next_period(v, all_, w + Week(1), start_of),
            "previous_week" => previous_period(v, all_, w, start_of)))
    end

"""
    TodayArchiveView(Model; date_field, allow_future=false, allow_empty=false, paginate_by=nothing, hooks...)

`DayArchiveView` for today (in the current time zone), with no URL kwargs. Same template and context.
"""
TodayArchiveView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:TodayArchiveView, T, kw) do v
        day_archive(v, localdate())
    end
# (a day's context has its month's neighbours too, as Django's)
function day_archive(v::ViewCall, d::Date)
    all_ = dated_queryset(v)
    qs = order_by(in_period(v, all_, d, d + Day(1)), string(date_field(v)))
    m = firstdayofmonth(d)
    archive_response(v, qs, Dict{String,Any}("day" => d,
        "next_day" => next_period(v, all_, d + Day(1), identity),
        "previous_day" => previous_period(v, all_, d, identity),
        "next_month" => next_period(v, all_, m + Month(1), firstdayofmonth),
        "previous_month" => previous_period(v, all_, m, firstdayofmonth)))
end

"""
    DateDetailView(Model; date_field, allow_future=false, pk_kwarg=:id, slug_kwarg=:slug, hooks...)

One object, found by `year`/`month`/`day` plus pk or slug: a 404 unless it is dated that day.
"""
DateDetailView(::Type{T}; kw...) where {T<:Model} =
    generic_view(:DateDetailView, T, kw) do v
        d = period_date(v, url_int(v, :year), url_month(v), url_int(v, :day))
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

"""
Django's AccessMixin: when a view refuses a request, an anonymous user goes to the login page
(`login_url`, with the page in `redirect_field_name`; `nothing` leaves it out), and a logged-in
user, or anyone with `raise_exception = true`, gets 403 with `permission_denied_message` (a string,
or a function of the request).
"""
function access_mixin(view, allowed; login_url = nothing, redirect_field_name = "next", raise_exception = false,
                      permission_denied_message = "")
    w = function (req; kw...)
        allowed(req) && return view(req; kw...)
        if raise_exception || is_authenticated(req.user)
            msg = permission_denied_message isa Function ? permission_denied_message(req) : permission_denied_message
            throw(PermissionDenied(string(msg)))
        end
        redirect_to_login(req, something(login_url, settings.LOGIN_URL); redirect_field_name = redirect_field_name)
    end
    propagate_flags!(w, view)
end

"`LoginRequiredMixin(view; login_url, redirect_field_name, raise_exception, permission_denied_message)`: Django's (an AccessMixin)."
LoginRequiredMixin(view; kw...) = access_mixin(view, req -> is_authenticated(req.user); kw...)
"""
`PermissionRequiredMixin(view, \"app.perm\"...; ...)`: Django's (an AccessMixin): a logged-in user
without the permissions gets 403, an anonymous one the login page.
"""
PermissionRequiredMixin(view, perms::AbstractString...; kw...) =
    access_mixin(view, req -> is_authenticated(req.user) && has_perms(req.user, collect(String, perms)); kw...)
PermissionRequiredMixin(view, perms::AbstractVector; kw...) = PermissionRequiredMixin(view, perms...; kw...)
"""
`UserPassesTestMixin(view, user -> Bool; ...)`: Django's (an AccessMixin): a logged-in user who
fails the test gets 403 (`user_passes_test` sends anyone who fails it to the login page, as
Django's decorator).
"""
UserPassesTestMixin(view, test; kw...) = access_mixin(view, req -> test(req.user); kw...)

# --- typed query parameters ------------------------------------------------------------------------------

struct NoQueryDefault end
const NO_QUERY_DEFAULT = NoQueryDefault()

"""
    query_param(req, name, T = String; default, choices = nothing) -> T

A query-string parameter (`req.GET`) as a `T`: `String`, `Int` (or another integer type),
`Float64`, `Decimal`, `Bool` (true/false, 1/0, on/off, yes/no), `Date`, `DateTime` (in the
formats forms accept) or `Symbol`. `Vector{T}` gives every value of a repeated parameter
(`?tag=a&tag=b`). A value that doesn't parse, or isn't one of `choices`, is a 400 Bad Request
naming the parameter, rather than a 500 from `parse`; so is a missing (or empty) one without a
`default`.

    page = query_param(req, :page, Int; default = 1)
    sort = query_param(req, :sort, Symbol; default = :name, choices = (:name, :date))
"""
function query_param(req::Request, name, ::Type{T} = String; default = NO_QUERY_DEFAULT, choices = nothing) where {T}
    k = string(name)
    if T <: AbstractVector
        vals = [query_value(eltype(T), k, s, choices) for s in getlist(req.GET, k) if !isempty(strip(s))]
        isempty(vals) && default !== NO_QUERY_DEFAULT && return default
        return convert(T, vals)
    end
    raw = get(req.GET, k, nothing)
    if raw === nothing || isempty(strip(raw))
        default === NO_QUERY_DEFAULT && throw(BadRequest("The query parameter '$k' is required."))
        return default
    end
    query_value(T, k, raw, choices)
end
function query_value(::Type{T}, k, raw, choices) where {T}
    s = strip(raw)
    v = if T === String || T === Any
        String(s)
    elseif T === Symbol
        Symbol(s)
    elseif T === Bool
        l = lowercase(s)
        l in ENV_TRUE ? true : l in ENV_FALSE ? false : nothing
    elseif T <: Integer || T <: AbstractFloat || T === Decimal
        tryparse(T, s)
    elseif T === Date
        parse_input_datetime(s, :date)
    elseif T === DateTime
        parse_input_datetime(s, :datetime)
    else
        throw(ArgumentError("query_param: unsupported type $T"))
    end
    v === nothing && throw(BadRequest("The query parameter '$k' isn't a valid $(T === Bool ? "true/false value" : lowercase(string(nameof(T)))): $(repr(String(raw)))."))
    if choices !== nothing && !(v in choices || string(v) in string.(choices))
        throw(BadRequest("The query parameter '$k' must be one of $(join(string.(choices), ", ")), not $(repr(String(raw)))."))
    end
    v
end
