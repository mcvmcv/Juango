# Automatic admin ------------------------------------------------------------------------------
#
#     Admin.register!(Post; list_display=[:title, :author, :published], search_fields=[:title],
#                     list_filter=[:published, :author])
#     urlpatterns = [path("admin/", Admin.urls()), ...]

module Admin

using ..Juango
import ..Juango: Model, Field, Request, modelmeta, attname, label, findfield, related_model, format_date,
                 SafeString, escape_html, render, NOTFOUND, tattr, urlencode, QueryDict, User, LoginView,
                 make_password, set_unusable_password!, reverse_relations, Paginator, page, Http404,
                 ProtectedError, staff_member_required, message!, reverse_url, get_absolute_url, model_name
using Dates

"""
Options for one model in the admin (see [`register!`](@ref)).
"""
mutable struct ModelAdmin
    model::Any
    slug::String
    list_display::Vector{Any}
    search_fields::Vector{Symbol}
    list_filter::Vector{Symbol}
    ordering::Vector{String}
    fields::Union{Nothing,Vector{Symbol}}
    exclude::Vector{Symbol}
    list_per_page::Int
    password_fields::Vector{Symbol}
    queryset::Any        # nothing, or req -> QuerySet (what the admin lists and edits)
end

"The objects this admin shows: `objects(Model)` or the `queryset` option."
admin_queryset(ma::ModelAdmin, req) = ma.queryset === nothing ? objects(ma.model) : ma.queryset(req)

const REGISTRY = Dict{String,ModelAdmin}()
const ORDER = String[]

"""
    Admin.register!(Model; list_display=[:__str__], search_fields=[], list_filter=[],
                    ordering=[], fields=nothing, exclude=[], list_per_page=25, password_fields=[])

Expose a model in the admin. `list_display` entries are field names, `:__str__`,
or `"Header" => obj -> value` pairs. `password_fields` are rendered as password
inputs and hashed with `make_password` on save (left unchanged when blank).
`queryset = req -> filter(...)` limits what the admin lists and edits (by default
`objects(Model)`, i.e. the model's `default_queryset`).
"""
function register!(T::Type; list_display = Any[:__str__], search_fields = Symbol[], list_filter = Symbol[],
                   ordering = String[], fields = nothing, exclude = Symbol[], list_per_page = 25,
                   password_fields = Symbol[], queryset = nothing)
    modelmeta(T)  # validates T is a model
    slug = model_name(T)
    REGISTRY[slug] = ModelAdmin(T, slug, collect(Any, list_display), Symbol.(search_fields), Symbol.(list_filter),
                                String.(string.(ordering)), fields === nothing ? nothing : Symbol.(fields),
                                Symbol.(exclude), list_per_page, Symbol.(password_fields), queryset)
    filter!(!=(slug), ORDER)
    push!(ORDER, slug)
    T
end

"Remove a model from the admin."
function unregister!(T::Type)
    slug = model_name(T)
    delete!(REGISTRY, slug)
    filter!(!=(slug), ORDER)
    nothing
end
is_registered(T::Type) = haskey(REGISTRY, model_name(T))

register_builtin!() = is_registered(User) || register!(User;
    list_display = [:username, :email, :first_name, :last_name, :is_staff],
    search_fields = [:username, :first_name, :last_name, :email],
    list_filter = [:is_staff, :is_superuser, :is_active], password_fields = [:password])

get_admin(slug) = (ma = get(REGISTRY, slug, nothing); ma === nothing ? throw(Http404("No admin for model '$slug'")) : ma)

opts(ma::ModelAdmin) = (m = modelmeta(ma.model);
    Dict{String,Any}("slug" => ma.slug, "verbose_name" => m.verbose_name, "verbose_name_plural" => m.verbose_name_plural,
                     "name" => m.name))

base_context(req, title) = Dict{String,Any}(
    "title" => title, "site_header" => settings.SITE_NAME * " administration",
    "site_title" => settings.SITE_NAME * " site admin",
    "models" => [opts(REGISTRY[s]) for s in ORDER])

# --- views -------------------------------------------------------------------------------------

function index(req::Request)
    ctx = base_context(req, "Site administration")
    ctx["model_list"] = [merge(opts(REGISTRY[s]), Dict{String,Any}("count" => count(REGISTRY[s].model))) for s in ORDER]
    render(req, "admin/index.html", ctx)
end

admin_login(req::Request) =
    LoginView(template = "admin/login.html", redirect_url = reverse_url("admin:index"), require_staff = true)(req)

function admin_logout(req::Request)
    req.method == "POST" || return Juango.HttpResponseNotAllowed(["POST"])
    Juango.logout!(req)
    render(req, "admin/logged_out.html", base_context(req, "Logged out"))
end

function header_label(ma::ModelAdmin, col)
    col isa Pair && return string(col.first)
    col === :__str__ && return uppercasefirst(modelmeta(ma.model).verbose_name)
    f = findfield(modelmeta(ma.model), Symbol(col))
    f === nothing ? uppercasefirst(replace(string(col), '_' => ' ')) : label(f)
end

function cell_value(ma::ModelAdmin, obj, col)
    v = if col isa Pair
        col.second(obj)
    elseif col === :__str__
        string(obj)
    else
        f = findfield(modelmeta(ma.model), Symbol(col))
        val = getproperty(obj, Symbol(col))
        if f !== nothing && f.choices !== nothing
            i = findfirst(c -> string(c.first) == string(val), f.choices)
            i === nothing ? val : f.choices[i].second
        else
            val
        end
    end
    format_value(v)
end

format_value(::Nothing) = "-"
format_value(v::Bool) = SafeString(v ? "<span class=\"yes\" title=\"True\">✔</span>" : "<span class=\"no\" title=\"False\">✘</span>")
format_value(v::DateTime) = format_date(v, "N j, Y, g:i a")
format_value(v::Date) = format_date(v, "N j, Y")
format_value(v::AbstractString) = isempty(v) ? "-" : v
format_value(v) = v

function query_with(req::Request, changes::Pair...)
    q = copy(req.GET)
    delete!(q.data, "page")
    for (k, v) in changes
        v === nothing ? delete!(q.data, string(k)) : (q.data[string(k)] = [string(v)])
    end
    s = urlencode(q)
    isempty(s) ? "?" : "?" * s
end

function filter_specs(req::Request, ma::ModelAdmin)
    specs = Any[]
    for name in ma.list_filter
        f = findfield(modelmeta(ma.model), name)
        f === nothing && continue
        key = string(attname(f))
        cur = get(req.GET, key, nothing)
        opts_ = Tuple{String,Any}[("All", nothing)]
        if f.kind === :bool
            append!(opts_, [("Yes", "1"), ("No", "0")])
        elseif f.choices !== nothing
            append!(opts_, [(c.second, string(c.first)) for c in f.choices])
        elseif f.kind === :fk
            append!(opts_, [(string(o), string(o.id)) for o in objects(related_model(f))[1:100]])
        else
            vals = unique(values_list(order_by(admin_queryset(ma, req), string(name)), name; flat = true))
            append!(opts_, [(string(v), string(v)) for v in first(vals, 50) if v !== nothing])
        end
        choices = [Dict{String,Any}("label" => l, "url" => query_with(req, key => v),
                                    "selected" => (v === nothing ? cur === nothing : cur == v)) for (l, v) in opts_]
        push!(specs, Dict{String,Any}("title" => label(f), "choices" => choices))
    end
    specs
end

function changelist(req::Request; model)
    ma = get_admin(model)
    T = ma.model
    meta = modelmeta(T)
    if req.method == "POST" && get(req.POST, "action", "") == "delete_selected"
        ids = [parse(Int, i) for i in Juango.getlist(req.POST, "_selected_action") if tryparse(Int, i) !== nothing]
        if isempty(ids)
            message!(req, :warning, "Items must be selected in order to perform actions on them. No items have been changed.")
        else
            try
                n = delete!(filter(admin_queryset(ma, req); id__in = ids))
                message!(req, :success, "Successfully deleted $n $(n == 1 ? meta.verbose_name : meta.verbose_name_plural).")
            catch e
                e isa ProtectedError || rethrow()
                message!(req, :error, e.msg)
            end
        end
        return Juango.HttpResponseRedirect(req.path * (isempty(req.query_string) ? "" : "?" * req.query_string))
    end
    qs = admin_queryset(ma, req)
    q = strip(get(req.GET, "q", ""))
    if !isempty(q) && !isempty(ma.search_fields)
        qs = filter(qs, reduce(|, [Q(Symbol(f, "__icontains") => q) for f in ma.search_fields]))
    end
    for name in ma.list_filter
        f = findfield(meta, name)
        f === nothing && continue
        v = get(req.GET, string(attname(f)), nothing)
        (v === nothing || isempty(v)) && continue
        qs = f.kind === :bool ? filter(qs, Q(f.name => v == "1")) :
             f.kind === :fk ? filter(qs, Q(attname(f) => something(tryparse(Int, v), 0))) :
             filter(qs, Q(f.name => v))
    end
    isempty(ma.ordering) || (qs = order_by(qs, ma.ordering...))
    # Load the objects behind foreign-key columns in the same query (no query per row).
    fks = [c for c in ma.list_display if c isa Symbol && (f = findfield(meta, c)) !== nothing && f.kind === :fk && f.name === c]
    isempty(fks) || (qs = Juango.select_related(qs, fks...))
    p = Paginator(qs, ma.list_per_page)
    pg = try
        page(p, get(req.GET, "page", "1"))
    catch
        page(p, 1)
    end
    rows = [Dict{String,Any}("id" => o.id, "cells" => [cell_value(ma, o, c) for c in ma.list_display],
                             "url" => reverse_url("admin:change"; model = ma.slug, id = o.id)) for o in pg]
    ctx = base_context(req, "Select $(meta.verbose_name) to change")
    merge!(ctx, Dict{String,Any}(
        "opts" => opts(ma), "headers" => [header_label(ma, c) for c in ma.list_display], "rows" => rows,
        "page_obj" => pg, "paginator" => p, "q" => q, "has_search" => !isempty(ma.search_fields),
        "filters" => filter_specs(req, ma), "total" => count(admin_queryset(ma, req)), "result_count" => p.count,
        "prev_url" => pg.has_previous ? query_with(req, "page" => pg.previous_page_number) : nothing,
        "next_url" => pg.has_next ? query_with(req, "page" => pg.next_page_number) : nothing))
    render(req, "admin/change_list.html", ctx)
end

admin_fields(ma::ModelAdmin) = ma.fields !== nothing ? ma.fields :
    [f.name for f in vcat(modelmeta(ma.model).fields, modelmeta(ma.model).m2m)
     if f.editable && !(f.name in ma.exclude) && !(f.name in ma.password_fields)]

function change_form(req::Request, ma::ModelAdmin, obj)
    T = ma.model
    meta = modelmeta(T)
    adding = obj === nothing
    form = Juango.ModelForm(T; data = req.method == "POST" ? req.POST : nothing, instance = obj, fields = admin_fields(ma))
    if req.method == "POST" && is_valid(form)
        o = save!(form; commit = false)
        for pf in ma.password_fields
            raw = get(req.POST, string(pf), "")
            if !isempty(raw)
                setproperty!(o, pf, make_password(raw))
            elseif adding
                setproperty!(o, pf, "!" * Juango.random_string(40))
            end
        end
        save!(o)
        Juango.save_m2m!(form)
        verb = adding ? "added" : "changed"
        if haskey(req.POST, "_continue")
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may edit it again below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; model = ma.slug, id = o.id))
        elseif haskey(req.POST, "_addanother")
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may add another $(meta.verbose_name) below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:add"; model = ma.slug))
        end
        message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully.")
        return Juango.HttpResponseRedirect(reverse_url("admin:changelist"; model = ma.slug))
    end
    readonly = adding ? Any[] :
        [Dict{String,Any}("label" => label(f), "value" => format_value(getproperty(obj, attname(f))))
         for f in meta.fields if !f.editable]
    ctx = base_context(req, (adding ? "Add " : "Change ") * meta.verbose_name)
    merge!(ctx, Dict{String,Any}(
        "opts" => opts(ma), "form" => form, "object" => obj, "adding" => adding, "readonly" => readonly,
        "password_fields" => [Dict("name" => string(pf), "label" => uppercasefirst(string(pf))) for pf in ma.password_fields],
        "view_on_site" => adding ? nothing : get_absolute_url(obj)))
    render(req, "admin/change_form.html", ctx)
end

add_view(req::Request; model) = change_form(req, get_admin(model), nothing)
change_view(req::Request; model, id) =
    (ma = get_admin(model); change_form(req, ma, Juango.get_object_or_404(admin_queryset(ma, req); id = id)))

function delete_view(req::Request; model, id)
    ma = get_admin(model)
    meta = modelmeta(ma.model)
    obj = Juango.get_object_or_404(admin_queryset(ma, req); id = id)
    if req.method == "POST"
        name = string(obj)
        try
            delete!(obj)
            message!(req, :success, "The $(meta.verbose_name) “$(name)” was deleted successfully.")
            return Juango.HttpResponseRedirect(reverse_url("admin:changelist"; model = ma.slug))
        catch e
            e isa ProtectedError || rethrow()
            message!(req, :error, e.msg)
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; model = ma.slug, id = id))
        end
    end
    related = Any[]
    for (rn, M, f) in reverse_relations(ma.model)
        n = count(filter(objects(M), Q(attname(f) => obj.id)))
        n > 0 && push!(related, Dict{String,Any}("name" => modelmeta(M).verbose_name_plural, "count" => n,
                                                 "action" => f.on_delete === :CASCADE ? "deleted" :
                                                             f.on_delete === :SET_NULL ? "unlinked" :
                                                             f.on_delete === :PROTECT ? "protected (blocks deletion)" : "left untouched"))
    end
    ctx = base_context(req, "Are you sure?")
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "related" => related))
    render(req, "admin/delete_confirmation.html", ctx)
end

"""
    Admin.urls()

URL patterns for the admin, namespaced `admin`: `path("admin/", Admin.urls())`.
"""
function urls()
    s(v) = staff_member_required(v)
    include_urls([
        path("", s(index); name = "index"),
        path("login/", admin_login; name = "login"),
        path("logout/", admin_logout; name = "logout"),
        path("<slug:model>/", s(changelist); name = "changelist"),
        path("<slug:model>/add/", s(add_view); name = "add"),
        path("<slug:model>/<int:id>/change/", s(change_view); name = "change"),
        path("<slug:model>/<int:id>/delete/", s(delete_view); name = "delete"),
    ]; namespace = "admin")
end

end # module Admin
