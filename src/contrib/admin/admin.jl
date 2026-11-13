# Automatic admin ------------------------------------------------------------------------------
#
#     Admin.register!(Post; list_display=[:title, :author, :published], search_fields=[:title],
#                     list_filter=[:published, :author], date_hierarchy=:created,
#                     list_editable=[:published], prepopulated_fields=Dict(:slug => [:title]),
#                     inlines=[Admin.TabularInline(Comment; fields=[:name, :body])],
#                     actions=[Admin.action(make_published; description="Publish selected posts")])
#     urlpatterns = [path("admin/", Admin.urls()), ...]

module Admin

using ..Juango
import ..Juango: Model, Field, Request, modelmeta, attname, label, findfield, related_model, format_date,
                 SafeString, escape_html, render, NOTFOUND, tattr, urlencode, QueryDict, User, AbstractUser, LoginView,
                 make_password, set_unusable_password!, reverse_relations, Paginator, page, Http404,
                 ProtectedError, RestrictedError, staff_member_required, message!, reverse_url, get_absolute_url, model_name,
                 HttpResponse, LogEntry, log_action!, ADDITION, CHANGE, DELETION, get_for_model, management_form
using Dates

# --- options -----------------------------------------------------------------------------------

"""
    Admin.action(f; name=string(nameof(f)), description=..., permission=:change, confirm=false)

A change-list action. `f(admin, req, queryset)` runs on the selected objects and may return
an `HttpResponse` (a file download, say); otherwise the change list is shown again. With
`confirm=true` the user confirms on an intermediate page first.
"""
struct AdminAction
    name::String
    func::Function
    description::String
    permission::Symbol
    confirm::Bool
end
function action(f::Function; name = string(nameof(f)), description = nothing, permission = :change, confirm = false)
    startswith(name, "#") && throw(ArgumentError("give anonymous action functions a name: Admin.action(f; name=\"...\")"))
    AdminAction(name, f, something(description, uppercasefirst(replace(name, '_' => ' '))), permission, confirm)
end
to_action(a::AdminAction) = a
to_action(f::Function) = action(f)

"""
    TabularInline(Model; fields=nothing, extra=1, can_delete=true, fk=nothing, max_num=1000)
    StackedInline(...)

Edit related objects on the parent's change page: a table row per object, or a stacked
form per object.
"""
struct InlineAdmin
    model::Any
    fields::Union{Nothing,Vector{Symbol}}
    extra::Int
    can_delete::Bool
    fk::Union{Nothing,Symbol}
    max_num::Int
    style::Symbol
end
Base.@nospecializeinfer TabularInline(@nospecialize(T); fields = nothing, extra = 1, can_delete = true, fk = nothing, max_num = 1000) =
    InlineAdmin(T, fields === nothing ? nothing : Symbol.(fields), extra, can_delete, fk === nothing ? nothing : Symbol(fk), max_num, :tabular)
StackedInline(T; kw...) = (i = TabularInline(T; kw...); InlineAdmin(i.model, i.fields, i.extra, i.can_delete, i.fk, i.max_num, :stacked))

"""
Options for one model in the admin (see [`register!`](@ref)).
"""
mutable struct ModelAdmin
    model::Any
    slug::String
    list_display::Vector{Any}
    search_fields::Vector{Symbol}
    list_filter::Vector{Any}             # field names, :field => :empty / :related_only, or ListFilter(...)
    ordering::Vector{String}
    fields::Union{Nothing,Vector{Symbol}}
    exclude::Vector{Symbol}
    list_per_page::Int
    password_fields::Vector{Symbol}
    queryset::Any                        # nothing, or req -> QuerySet (what the admin lists and edits)
    actions::Vector{AdminAction}
    inlines::Vector{InlineAdmin}
    readonly_fields::Vector{Symbol}
    fieldsets::Vector{Pair{String,Vector{Symbol}}}
    prepopulated_fields::Dict{Symbol,Vector{Symbol}}
    raw_id_fields::Vector{Symbol}
    autocomplete_fields::Vector{Symbol}
    list_editable::Vector{Symbol}
    date_hierarchy::Union{Nothing,Symbol}
    save_as::Bool
    add_form::Any                        # nothing, or (data, files) -> Form for the add page
    has_view_permission::Any             # nothing, or (req, obj_or_nothing) -> Bool
    has_change_permission::Any
    has_add_permission::Any
    has_delete_permission::Any
    list_select_related::Any             # nothing (the foreign keys in list_display), true, false or field names
    show_full_result_count::Bool
    extra_urls::Vector{Any}              # path(...)s under the model's URL, wrapped in the admin's checks
    get_list_display::Any                # nothing, or req -> columns (Django's get_list_display)
    get_list_filter::Any
    get_search_fields::Any
    get_ordering::Any
    get_readonly_fields::Any             # nothing, or (req, obj) -> names
    get_fields::Any                      # nothing, or (req, obj) -> names
end

"""
    Admin.ListFilter(title, parameter; lookups, queryset)

A custom change-list filter (Django's `SimpleListFilter`): `lookups(req, admin)` returns the
choices as `value => label` pairs, and `queryset(req, qs, value)` filters by the chosen value
(a string from the URL parameter `parameter`).

    decade = Admin.ListFilter("decade born", "decade";
        lookups = (req, ma) -> ["80s" => "in the eighties", "90s" => "in the nineties"],
        queryset = (req, qs, v) -> v == "80s" ? filter(qs; birthday__year__range = (1980, 1989)) :
                                               filter(qs; birthday__year__range = (1990, 1999)))
    Admin.register!(Person; list_filter = [decade, :is_active, :email => :empty, :team => :related_only])
"""
struct ListFilter
    title::String
    parameter::String
    lookups::Function
    queryset::Function
end
ListFilter(title, parameter; lookups, queryset) = ListFilter(string(title), string(parameter), lookups, queryset)

"""
    Admin.AdminSite(name = "admin"; site_header, site_title, index_title, has_permission, urls = [])

An admin site: its own registry of models, titles, permission check and URL namespace. The
default one is `Admin.site`; make others for, say, a staff area with fewer models:

    staff = Admin.AdminSite("staff"; site_header = "Staff area", has_permission = req -> req.user.is_staff)
    Admin.register!(Order; site = staff)
    urlpatterns = [path("admin/", Admin.urls()), path("staff/", Admin.urls(staff))]

`urls` adds site-wide views (`path("stats/", stats_view; name = "stats")`), behind the same
login and permission checks, reversed as `"staff:stats"` (or `"admin:stats"` from its pages).
"""
mutable struct AdminSite
    name::String
    registry::Dict{String,ModelAdmin}
    order::Vector{String}
    site_header::Union{Nothing,String}
    site_title::Union{Nothing,String}
    index_title::Union{Nothing,String}
    has_permission::Any                  # nothing (active staff users), or req -> Bool
    extra_urls::Vector{Any}
end
AdminSite(name::AbstractString = "admin"; site_header = nothing, site_title = nothing, index_title = nothing,
          has_permission = nothing, urls = Any[], registry = Dict{String,ModelAdmin}(), order = String[]) =
    AdminSite(String(name), registry, order, site_header, site_title, index_title, has_permission, collect(Any, urls))

"The objects this admin shows: `objects(Model)` or the `queryset` option."
admin_queryset(ma::ModelAdmin, req) = ma.queryset === nothing ? objects(ma.model) : ma.queryset(req)

const REGISTRY = Dict{String,ModelAdmin}()
const ORDER = String[]
"The default admin site (`Admin.urls()`); its registry is `REGISTRY`."
const site = AdminSite("admin"; registry = REGISTRY, order = ORDER)
"The site handling the current request (`Admin.site` outside one)."
const CURRENT_SITE = Base.ScopedValues.ScopedValue{AdminSite}(site)
current_site() = CURRENT_SITE[]

"""
    Admin.register!(Model; list_display=[:__str__], search_fields=[], list_filter=[], ordering=[],
                    fields=nothing, exclude=[], fieldsets=[], readonly_fields=[], list_per_page=25,
                    password_fields=[], queryset=nothing, actions=[], delete_action=true, inlines=[],
                    prepopulated_fields=Dict(), raw_id_fields=[], autocomplete_fields=[],
                    list_editable=[], date_hierarchy=nothing, save_as=false)

Expose a model in the admin.

* `list_display`: field names, `:__str__`, or `"Header" => obj -> value` pairs.
* `fieldsets`: `["Title" => [:a, :b], "Advanced" => [:c]]` groups the change form.
* `readonly_fields`: shown as values, not editable.
* `prepopulated_fields`: `Dict(:slug => [:title])` fills the slug while typing (when adding).
* `raw_id_fields` / `autocomplete_fields`: foreign keys as an id box / a search box, for big tables
  (autocomplete needs the related model registered with `search_fields`).
* `list_editable`: fields edited directly in the change list.
* `date_hierarchy`: a date field to drill down by year, month and day.
* `actions`: functions `(admin, req, queryset) -> ...` or `Admin.action(...)`; "Delete selected"
  is built in (`delete_action=false` removes it). `Admin.export_csv` is ready to add.
* `inlines`: `[TabularInline(Comment), StackedInline(Photo)]`.
* `save_as`: a "Save as new" button on the change form.
* `add_form = (data, files) -> form`: a different form for the add page (the user admin uses
  `UserCreationForm`); after adding, the change page opens.
* `password_fields`: rendered as password inputs and hashed on save (unchanged when blank).
* `queryset = req -> ...`: what the admin lists and edits (default `objects(Model)`).
"""
function register!(T::Type; list_display = Any[:__str__], search_fields = Symbol[], list_filter = Symbol[],
                   ordering = String[], fields = nothing, exclude = Symbol[], list_per_page = 25,
                   password_fields = Symbol[], queryset = nothing, actions = Any[], delete_action = true,
                   inlines = InlineAdmin[], readonly_fields = Symbol[], fieldsets = Pair{String,Vector{Symbol}}[],
                   prepopulated_fields = Dict{Symbol,Vector{Symbol}}(), raw_id_fields = Symbol[],
                   autocomplete_fields = Symbol[], list_editable = Symbol[], date_hierarchy = nothing, save_as = false,
                   add_form = nothing, site::AdminSite = Admin.site, has_view_permission = nothing, has_change_permission = nothing,
                   has_add_permission = nothing, has_delete_permission = nothing, list_select_related = nothing,
                   show_full_result_count = true, urls = Any[], get_list_display = nothing, get_list_filter = nothing,
                   get_search_fields = nothing, get_ordering = nothing, get_readonly_fields = nothing, get_fields = nothing)
    modelmeta(T)  # validates T is a model
    slug = model_name(T)
    acts = AdminAction[to_action(a) for a in actions]
    delete_action && pushfirst!(acts, action(delete_selected; description = "Delete selected $(modelmeta(T).verbose_name_plural)",
                                             permission = :delete))
    for f in list_editable
        Symbol(f) in Symbol.(collect(list_display)) || throw(ArgumentError("list_editable field '$f' must also be in list_display"))
    end
    site.registry[slug] = ModelAdmin(T, slug, collect(Any, list_display), Symbol.(search_fields),
                                Any[x isa Union{AbstractString,Symbol} ? Symbol(x) : x for x in list_filter],
                                String.(string.(ordering)), fields === nothing ? nothing : Symbol.(fields),
                                Symbol.(exclude), list_per_page, Symbol.(password_fields), queryset, acts,
                                collect(InlineAdmin, inlines), Symbol.(readonly_fields),
                                Pair{String,Vector{Symbol}}[string(k) => Symbol.(collect(v)) for (k, v) in fieldsets],
                                Dict{Symbol,Vector{Symbol}}(Symbol(k) => Symbol.(collect(v)) for (k, v) in prepopulated_fields),
                                Symbol.(raw_id_fields), Symbol.(autocomplete_fields), Symbol.(list_editable),
                                date_hierarchy === nothing ? nothing : Symbol(date_hierarchy), save_as, add_form,
                                has_view_permission, has_change_permission, has_add_permission, has_delete_permission,
                                list_select_related, show_full_result_count, collect(Any, urls), get_list_display,
                                get_list_filter, get_search_fields, get_ordering, get_readonly_fields, get_fields)
    filter!(!=(slug), site.order)
    push!(site.order, slug)
    T
end

"Remove a model from the admin (`site` defaults to `Admin.site`)."
Base.@nospecializeinfer function unregister!(@nospecialize(T::Type); site::AdminSite = Admin.site)
    slug = model_name(T)
    delete!(site.registry, slug)
    filter!(!=(slug), site.order)
    nothing
end
is_registered(T::Type; site::AdminSite = Admin.site) = haskey(site.registry, model_name(T))
"The `ModelAdmin` of a model on the current site (for custom admin views)."
model_admin(T::Type) = get_admin(model_name(T))

function register_builtin!()
    register_user_model!()
    is_registered(Juango.Group) || register!(Juango.Group; list_display = [:name], search_fields = [:name])
end

"""
    Admin.register_user_model!(T = get_user_model(); options...)

Register a user model with the options Juango's `User` has (password hashing, search,
filters). Done for the AUTH_USER_MODEL when the admin's URLs are built; call it yourself to
change the options.
"""
function register_user_model!(T = Juango.get_user_model(); kw...)
    is_registered(T) && isempty(kw) && return
    T !== User && is_registered(User) && unregister!(User)
    register!(T; list_display = [:username, :email, :first_name, :last_name, :is_staff],
              search_fields = [:username, :first_name, :last_name, :email],
              list_filter = [:is_staff, :is_superuser, :is_active], password_fields = [:password],
              add_form = (data, files) -> Juango.UserCreationForm(data), kw...)
end

get_admin(slug) = (ma = get(current_site().registry, slug, nothing); ma === nothing ? throw(Http404("No admin for model '$slug'")) : ma)

# options that can depend on the request (Django's get_list_display & co.)
list_display(ma::ModelAdmin, req) = ma.get_list_display === nothing ? ma.list_display : collect(Any, ma.get_list_display(req))
list_filter(ma::ModelAdmin, req) = ma.get_list_filter === nothing ? ma.list_filter :
    Any[x isa Union{AbstractString,Symbol} ? Symbol(x) : x for x in ma.get_list_filter(req)]
search_fields(ma::ModelAdmin, req) = ma.get_search_fields === nothing ? ma.search_fields : Symbol.(collect(ma.get_search_fields(req)))
ordering(ma::ModelAdmin, req) = ma.get_ordering === nothing ? ma.ordering : String.(string.(collect(ma.get_ordering(req))))
Base.@nospecializeinfer readonly_fields(ma::ModelAdmin, req, @nospecialize(obj)) = ma.get_readonly_fields === nothing ? ma.readonly_fields : Symbol.(collect(ma.get_readonly_fields(req, obj)))

opts(ma::ModelAdmin) = (m = modelmeta(ma.model);
    Dict{String,Any}("slug" => ma.slug, "verbose_name" => m.verbose_name, "verbose_name_plural" => m.verbose_name_plural,
                     "name" => m.name))

# --- permissions: superusers may do everything; staff need the model's permissions ----------------

"""
Whether the user may `action` (:view, :change, :add, :delete) the model, or one object: the
ModelAdmin's `has_<action>_permission(req, obj)` when given, else the model permission.
"""
Base.@nospecializeinfer function can(req, ma::ModelAdmin, action, @nospecialize(obj = nothing))
    hook = action === :view ? ma.has_view_permission : action === :change ? ma.has_change_permission :
           action === :add ? ma.has_add_permission : action === :delete ? ma.has_delete_permission : nothing
    hook === nothing ? Juango.has_perm(req.user, Juango.perm_name(ma.model, action)) : Bool(hook(req, obj))
end
can_model(req, T::Type, action) = Juango.has_perm(req.user, Juango.perm_name(T, action))
Base.@nospecializeinfer can_view(req, ma, @nospecialize(obj = nothing)) = can(req, ma, :view, obj) || can(req, ma, :change, obj)
"Throw 403 unless the user may do one of `actions` on the model (or on `obj`)."
Base.@nospecializeinfer require_perm(req, ma, actions...; obj = nothing) = any(a -> can(req, ma, a, obj), actions) ||
    throw(Juango.PermissionDenied("You don't have permission to $(join(string.(actions), " or ")) $(modelmeta(ma.model).verbose_name_plural)."))
visible_models(req) = (st = current_site(); [s for s in st.order if can_view(req, st.registry[s]) || can(req, st.registry[s], :add)])

function base_context(req, title)
    st = current_site()
    Dict{String,Any}(
        "title" => title, "site_header" => something(st.site_header, settings.SITE_NAME * " administration"),
        "site_title" => something(st.site_title, settings.SITE_NAME * " site admin"),
        "models" => [opts(st.registry[s]) for s in visible_models(req)])
end

# --- views -------------------------------------------------------------------------------------

admin_url_for(e::LogEntry) = (e.content_type === nothing || e.object_id === nothing || e.action_flag == DELETION) ? nothing :
    (T = Juango.model_class(e.content_type); T === nothing || !is_registered(T; site = current_site()) ? nothing :
     reverse_url("admin:change"; model = model_name(T), id = e.object_id))

function index(req::Request)
    st = current_site()
    ctx = base_context(req, something(st.index_title, gettext("Site administration")))
    ctx["model_list"] = [merge(opts(st.registry[s]), Dict{String,Any}(
                             "count" => can_view(req, st.registry[s]) ? count(admin_queryset(st.registry[s], req)) : nothing,
                             "can_add" => can(req, st.registry[s], :add), "can_view" => can_view(req, st.registry[s]),
                             "can_change" => can(req, st.registry[s], :change)))
                         for s in visible_models(req)]
    recent = req.user isa AbstractUser ? collect(select_related(filter(LogEntry; user = req.user), :content_type)[1:10]) : LogEntry[]
    ctx["recent_actions"] = [Dict{String,Any}("entry" => e, "url" => admin_url_for(e),
                                              "type" => e.content_type === nothing ? "" : e.content_type.model) for e in recent]
    render(req, "admin/index.html", ctx)
end

admin_login(req::Request) =
    LoginView(template = "admin/login.html", redirect_url = reverse_url("admin:index"), require_staff = true)(req)

function admin_logout(req::Request)
    req.method == "POST" || return Juango.HttpResponseNotAllowed(["POST"])
    Juango.logout!(req)
    render(req, "admin/logged_out.html", base_context(req, gettext("Logged out")))
end

function header_label(ma::ModelAdmin, col)
    col isa Pair && return string(col.first)
    col === :__str__ && return uppercasefirst(modelmeta(ma.model).verbose_name)
    f = findfield(modelmeta(ma.model), Symbol(col))
    f === nothing ? uppercasefirst(replace(string(col), '_' => ' ')) : label(f)
end

Base.@nospecializeinfer function raw_cell(ma::ModelAdmin, @nospecialize(obj), col)
    col isa Pair && return col.second(obj)
    col === :__str__ && return string(obj)
    f = findfield(modelmeta(ma.model), Symbol(col))
    val = getproperty(obj, Symbol(col))
    f !== nothing && f.choices !== nothing && return Juango.choice_label(Juango.field_choices(f), val)
    val
end
Base.@nospecializeinfer cell_value(ma::ModelAdmin, @nospecialize(obj), col) = format_value(raw_cell(ma, obj, col))

format_value(::Nothing) = "-"
format_value(v::Bool) = SafeString(v ? "<span class=\"yes\" title=\"True\">✔</span>" : "<span class=\"no\" title=\"False\">✘</span>")
format_value(v::DateTime) = format_date(v, "N j, Y, g:i a")
format_value(v::Date) = format_date(v, "N j, Y")
format_value(v::Juango.TimeZones.ZonedDateTime) = format_date(v, "N j, Y, g:i a T")
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

"""
The change list's filters, each as `(title, key, options, apply)`: `options` are `(label, value)`
pairs for the URL parameter `key` (value `nothing` is "All"), and `apply(qs, value)` filters.
"""
function list_filters(req::Request, ma::ModelAdmin)
    out = Any[]
    meta = modelmeta(ma.model)
    for entry in list_filter(ma, req)
        if entry isa ListFilter
            opts_ = Tuple{String,Any}[(string(l), string(v)) for (v, l) in entry.lookups(req, ma)]
            push!(out, (entry.title, entry.parameter, opts_, (qs, v) -> something(entry.queryset(req, qs, v), qs)))
            continue
        end
        name, mode = entry isa Pair ? (Symbol(entry.first), Symbol(entry.second)) : (entry, :field)
        f = findfield(meta, name)
        f === nothing && continue
        if mode === :empty                     # Django's EmptyFieldListFilter
            key = string(attname(f), "__isempty")
            text = f.kind in Juango.STRING_KINDS
            empty_q = text ? Q(Symbol(attname(f), "__isnull") => true) | Q(attname(f) => "") : Q(Symbol(attname(f), "__isnull") => true)
            push!(out, (label(f), key, [("Empty", "1"), ("Not empty", "0")],
                        (qs, v) -> v == "1" ? filter(qs, empty_q) : filter(qs, !empty_q)))
            continue
        end
        key = string(attname(f))
        opts_ = Tuple{String,Any}[]
        if f.kind === :bool
            append!(opts_, [("Yes", "1"), ("No", "0")])
        elseif f.choices !== nothing
            append!(opts_, [(string(c.second), string(c.first)) for c in Juango.field_choices(f)])
        elseif f.kind === :fk && mode === :related_only          # RelatedOnlyFieldListFilter: only the ones in use
            ids = unique(x for x in values_list(admin_queryset(ma, req), attname(f); flat = true) if x !== nothing)
            append!(opts_, [(string(o), string(o.id)) for o in filter(objects(related_model(f)); id__in = ids)])
        elseif f.kind === :fk
            append!(opts_, [(string(o), string(o.id)) for o in objects(related_model(f))[1:100]])
        else
            vals = unique(values_list(order_by(admin_queryset(ma, req), string(name)), name; flat = true))
            append!(opts_, [(string(v), string(v)) for v in first(vals, 50) if v !== nothing])
        end
        apply = f.kind === :bool ? ((qs, v) -> filter(qs, Q(f.name => v == "1"))) :
                f.kind === :fk ? ((qs, v) -> filter(qs, Q(attname(f) => Juango.parse_pk(related_model(f), v)))) :
                ((qs, v) -> filter(qs, Q(f.name => v)))
        push!(out, (label(f), key, opts_, apply))
    end
    out
end

function filter_specs(req::Request, ma::ModelAdmin, filters = list_filters(req, ma))
    specs = Any[]
    for (title, key, opts_, _) in filters
        cur = get(req.GET, key, nothing)
        choices = [Dict{String,Any}("label" => l, "url" => query_with(req, key => v),
                                    "selected" => (v === nothing ? cur === nothing : cur == v))
                   for (l, v) in vcat(Tuple{String,Any}[("All", nothing)], opts_)]
        push!(specs, Dict{String,Any}("title" => title, "choices" => choices))
    end
    specs
end

# --- date hierarchy ---------------------------------------------------------------------------------

const MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

"Filter by the date_hierarchy GET parameters; return (queryset, drill-down context)."
Base.@nospecializeinfer function date_drilldown(req, ma::ModelAdmin, @nospecialize(qs))
    ma.date_hierarchy === nothing && return qs, nothing
    f = ma.date_hierarchy
    p(k) = (v = get(req.GET, "$(f)__$k", nothing); v === nothing ? nothing : tryparse(Int, v))
    y, m, d = p("year"), p("month"), p("day")
    y === nothing || (qs = filter(qs, Q(Symbol(f, "__year") => y)))
    m === nothing || (qs = filter(qs, Q(Symbol(f, "__month") => m)))
    d === nothing || (qs = filter(qs, Q(Symbol(f, "__day") => d)))
    dates = [x for x in values_list(qs, f; flat = true) if x !== nothing]
    key(k) = "$(f)__$k"
    links, back = Any[], nothing
    if y === nothing
        links = [Dict("label" => string(v), "url" => query_with(req, key("year") => v)) for v in sort(unique(year.(dates)))]
    elseif m === nothing
        back = Dict("label" => "‹ All dates", "url" => query_with(req, key("year") => nothing))
        links = [Dict("label" => "$(MONTHS[v]) $y", "url" => query_with(req, key("month") => v)) for v in sort(unique(month.(dates)))]
    else
        back = Dict("label" => "‹ $y", "url" => query_with(req, key("month") => nothing, key("day") => nothing))
        d === nothing && (links = [Dict("label" => "$(MONTHS[m]) $v", "url" => query_with(req, key("day") => v))
                                   for v in sort(unique(day.(dates)))])
    end
    qs, Dict{String,Any}("links" => links, "back" => back)
end

# --- actions -------------------------------------------------------------------------------------

"Built-in action: delete the selected objects after a confirmation page."
Base.@nospecializeinfer function delete_selected(ma::ModelAdmin, req::Request, @nospecialize(qs))
    meta = modelmeta(ma.model)
    objs = collect(qs)
    if get(req.POST, "post", "") != "yes"
        ctx = base_context(req, gettext("Are you sure?"))
        merge!(ctx, Dict{String,Any}("opts" => opts(ma), "objects" => objs, "action" => "delete_selected",
                                     "ids" => [Juango.pk_string(o) for o in objs], "deleting" => true))
        return render(req, "admin/action_confirmation.html", ctx)
    end
    try
        Juango.atomic() do
            for o in objs
                log_action!(req.user, o, DELETION)
                delete!(o)
            end
        end
        n = length(objs)
        message!(req, :success, "Successfully deleted $n $(n == 1 ? meta.verbose_name : meta.verbose_name_plural).")
    catch e
        e isa Union{ProtectedError,RestrictedError} || rethrow()
        message!(req, :error, e.msg)
    end
    nothing
end

csv_cell(v) = (s = v isa SafeString ? v.s : v === nothing ? "" : string(v);
    s = replace(s, r"<[^>]*>" => "");
    occursin(r"[\",\n]", s) ? "\"" * replace(s, "\"" => "\"\"") * "\"" : s)

"""
    Admin.export_csv

An action that downloads the selected objects as CSV (the `list_display` columns):
`Admin.register!(Post; actions = [Admin.export_csv])`.
"""
const export_csv = action((ma, req, qs) -> begin
        cols = list_display(ma, req)
        lines = [join([csv_cell(header_label(ma, c)) for c in cols], ",")]
        for o in qs
            push!(lines, join([csv_cell(c === :__str__ ? string(o) : raw_cell(ma, o, c)) for c in cols], ","))
        end
        r = HttpResponse(join(lines, "\r\n") * "\r\n"; content_type = "text/csv; charset=utf-8")
        Juango.setheader!(r, "Content-Disposition", "attachment; filename=\"$(ma.slug).csv\"")
        r
    end; name = "export_csv", description = "Export selected as CSV", permission = :view)

function run_action(req, ma::ModelAdmin)
    name = get(req.POST, "action", "")
    i = findfirst(a -> a.name == name, ma.actions)
    i === nothing && (message!(req, :warning, "No action selected."); return nothing)
    a = ma.actions[i]
    require_perm(req, ma, a.permission)
    ids = filter(!isnothing, [Juango.parse_pk(ma.model, x) for x in Juango.getlist(req.POST, "_selected_action")])
    if isempty(ids)
        message!(req, :warning, "Items must be selected in order to perform actions on them. No items have been changed.")
        return nothing
    end
    qs = filter(admin_queryset(ma, req); pk__in = ids)
    if a.confirm && get(req.POST, "post", "") != "yes"
        ctx = base_context(req, gettext("Are you sure?"))
        merge!(ctx, Dict{String,Any}("opts" => opts(ma), "objects" => collect(qs), "action" => a.name,
                                     "description" => a.description, "ids" => [string(x) for x in ids], "deleting" => false))
        return render(req, "admin/action_confirmation.html", ctx)
    end
    a.func(ma, req, qs)
end

# --- change list -------------------------------------------------------------------------------------

function changelist(req::Request; model)
    ma = get_admin(model)
    T = ma.model
    meta = modelmeta(T)
    require_perm(req, ma, :view, :change)
    back = req.path * (isempty(req.query_string) ? "" : "?" * req.query_string)
    if req.method == "POST" && haskey(req.POST, "action") && !haskey(req.POST, "_save")
        r = run_action(req, ma)
        r isa HttpResponse && return r
        return Juango.HttpResponseRedirect(back)
    end
    qs = admin_queryset(ma, req)
    q = strip(get(req.GET, "q", ""))
    sfields = search_fields(ma, req)
    if !isempty(q) && !isempty(sfields)
        qs = filter(qs, reduce(|, [Q(Symbol(f, "__icontains") => q) for f in sfields]))
    end
    filters = list_filters(req, ma)
    for (_, key, _, apply) in filters
        v = get(req.GET, key, nothing)
        (v === nothing || isempty(v)) && continue
        qs = apply(qs, v)
    end
    qs, drill = date_drilldown(req, ma, qs)
    ords = ordering(ma, req)
    isempty(ords) || (qs = order_by(qs, ords...))
    cols = list_display(ma, req)
    # Load the objects behind foreign-key columns in the same query (no query per row): list_select_related
    sr = ma.list_select_related
    fks = sr === false ? Symbol[] : sr === true ? Symbol[f.name for f in meta.fields if f.kind === :fk] :
          sr !== nothing ? Symbol.(collect(sr)) :
          Symbol[c for c in cols if c isa Symbol && (f = findfield(meta, c)) !== nothing && f.kind === :fk && f.name === c]
    isempty(fks) || (qs = Juango.select_related(qs, fks...))
    p = Paginator(qs, ma.list_per_page)
    pg = try
        page(p, get(req.GET, "page", "1"))
    catch
        page(p, 1)
    end
    objs = collect(pg)
    editable = !isempty(ma.list_editable) && can(req, ma, :change)
    fs = nothing
    if editable
        FS = modelformset_factory(T; fields = ma.list_editable, extra = 0)
        fs = FS(req.method == "POST" ? req.POST : nothing; queryset = objs)
        if req.method == "POST" && haskey(req.POST, "_save")
            if is_valid(fs)
                for (i, f) in enumerate(fs.forms)
                    ch = changed_fields(f)
                    isempty(ch) && continue
                    save!(f)
                    log_action!(req.user, f.instance, CHANGE, "Changed " * join([lowercase(label(x)) for x in f.fields if x.name in ch], ", ") * ".")
                end
                n = count(f -> !isempty(changed_fields(f)), fs.forms)
                message!(req, :success, "$n $(n == 1 ? meta.verbose_name : meta.verbose_name_plural) $(n == 1 ? "was" : "were") changed successfully.")
                return Juango.HttpResponseRedirect(back)
            end
            message!(req, :error, "Please correct the errors below.")
        end
    end
    forms = fs === nothing ? nothing : Juango.build_forms!(fs)
    rows = Any[]
    for (k, o) in enumerate(objs)
        cells = Any[]
        for c in cols
            if fs !== nothing && c isa Symbol && c in ma.list_editable
                bf = forms[k][c]
                errs = get(forms[k].errors, c, String[])
                push!(cells, SafeString((isempty(errs) ? "" : Juango.errors_html(errs)) * Juango.widget_html(bf)))
            else
                push!(cells, cell_value(ma, o, c))
            end
        end
        hidden = fs === nothing ? "" : Juango.widget_html(forms[k][:id])
        push!(rows, Dict{String,Any}("id" => Juango.pk_string(o), "cells" => cells, "hidden" => SafeString(hidden),
                                     "url" => reverse_url("admin:change"; model = ma.slug, id = Juango.pk_string(o))))
    end
    ctx = base_context(req, interpolate(can(req, ma, :change) ? gettext("Select %(model)s to change") : gettext("Select %(model)s to view"),
                                        Dict("model" => meta.verbose_name)))
    merge!(ctx, Dict{String,Any}(
        "opts" => opts(ma), "headers" => [header_label(ma, c) for c in cols], "rows" => rows,
        "page_obj" => pg, "paginator" => p, "q" => q, "has_search" => !isempty(sfields),
        "filters" => filter_specs(req, ma, filters), "result_count" => p.count,
        "show_full_count" => ma.show_full_result_count, "total" => ma.show_full_result_count ? count(admin_queryset(ma, req)) : nothing,
        "can_add" => can(req, ma, :add), "can_delete" => can(req, ma, :delete),
        "actions" => [Dict("name" => a.name, "description" => a.description) for a in ma.actions if can(req, ma, a.permission)],
        "list_editable" => fs !== nothing, "management_form" => fs === nothing ? "" : management_form(fs),
        "date_hierarchy" => drill,
        "prev_url" => pg.has_previous ? query_with(req, "page" => pg.previous_page_number) : nothing,
        "next_url" => pg.has_next ? query_with(req, "page" => pg.next_page_number) : nothing))
    render(req, "admin/change_list.html", ctx)
end

# --- change form ---------------------------------------------------------------------------------------

Base.@nospecializeinfer function admin_fields(ma::ModelAdmin, req = nothing, @nospecialize(obj = nothing))
    fs = ma.get_fields !== nothing ? Symbol.(collect(ma.get_fields(req, obj))) : ma.fields !== nothing ? ma.fields :
         [f.name for f in vcat(Juango.all_fields(ma.model), modelmeta(ma.model).m2m)
          if f.editable && !(f.name in ma.exclude) && !(f.name in ma.password_fields)]
    ro = req === nothing ? ma.readonly_fields : readonly_fields(ma, req, obj)
    [f for f in fs if !(f in ro)]
end

Base.@nospecializeinfer function readonly_value(@nospecialize(obj), f::Field)
    obj === nothing && return "-"
    v = getproperty(obj, f.name)
    f.kind === :m2m && return join(string.(collect(v)), ", ")
    f.choices !== nothing && v !== nothing && return string(Juango.choice_label(Juango.field_choices(f), v))
    format_value(v)
end
Base.@nospecializeinfer readonly_row(ma, @nospecialize(obj), name) = (f = findfield(modelmeta(ma.model), name);
    f === nothing && (f = findfirst(x -> x.name === name, modelmeta(ma.model).m2m) |> i -> i === nothing ? nothing : modelmeta(ma.model).m2m[i]);
    Dict{String,Any}("readonly" => true, "label" => f === nothing ? uppercasefirst(replace(string(name), '_' => ' ')) : label(f),
                     "value" => f === nothing ? format_value(obj === nothing ? nothing : getproperty(obj, name)) : readonly_value(obj, f)))

"The change form as groups of rows (fieldsets), each row a bound field or a read-only value."
Base.@nospecializeinfer function form_groups(ma::ModelAdmin, form, @nospecialize(obj), editable; locked = Symbol[], readonly = ma.readonly_fields)
    row(name) = if editable && any(f -> f.name === name, form.fields)
        Dict{String,Any}("readonly" => false, "field" => form[name])
    else
        readonly_row(ma, obj, name)
    end
    layout = isempty(ma.fieldsets) ?
        ["" => vcat(locked, [f.name for f in form.fields], readonly)] : ma.fieldsets
    [Dict{String,Any}("name" => name, "rows" => [row(n) for n in names]) for (name, names) in layout]
end

Base.@nospecializeinfer function inline_formsets(ma::ModelAdmin, req, @nospecialize(obj), data)
    out = Any[]
    for ia in ma.inlines
        M = ia.model
        (can_model(req, M, :view) || can_model(req, M, :change) || can_model(req, M, :add)) || continue
        FS = inlineformset_factory(ma.model, M; fk = ia.fk, fields = ia.fields,
                                   extra = can_model(req, M, :add) ? ia.extra : 0,
                                   can_delete = ia.can_delete && can_model(req, M, :delete), max_num = ia.max_num)
        fs = FS(data; instance = obj)
        push!(out, (ia, fs))
    end
    out
end

function inline_context(ia::InlineAdmin, fs)
    forms = Juango.build_forms!(fs)
    names = isempty(forms) ? Symbol[] : [f.name for f in Juango.empty_form(fs).fields if f.name !== :id]
    Dict{String,Any}("style" => string(ia.style), "verbose_name_plural" => modelmeta(ia.model).verbose_name_plural,
                     "management_form" => management_form(fs), "non_form_errors" => fs.non_form_errors,
                     "headers" => [n === :DELETE ? "Delete?" : label(only(filter(f -> f.name === n, Juango.empty_form(fs).fields))) for n in names],
                     "forms" => [Dict{String,Any}("form" => f, "hidden" => SafeString(Juango.widget_html(f[:id])),
                                                  "title" => f.instance === nothing ? "" : string(f.instance),
                                                  "fields" => [f[n] for n in names]) for f in forms])
end

change_message(form, inlines) = begin
    parts = String[]
    ch = changed_fields(form)
    isempty(ch) || push!(parts, "Changed " * join([lowercase(label(f)) for f in form.fields if f.name in ch], ", ") * ".")
    for (ia, fs) in inlines
        vn = modelmeta(ia.model).verbose_name
        append!(parts, ["Added $vn “$(o)”." for o in fs.new_objects])
        append!(parts, ["Changed $vn “$(o)”." for o in fs.changed_objects])
        append!(parts, ["Deleted $vn “$(o)”." for o in fs.deleted_objects])
    end
    isempty(parts) ? "No fields changed." : join(parts, " ")
end

function configure_widgets!(ma::ModelAdmin, form)
    for f in form.fields
        f.name in ma.raw_id_fields && (f.widget = :raw_id)
        f.name in ma.autocomplete_fields && (f.widget = :autocomplete)
    end
    form
end

Base.@nospecializeinfer function change_form(req::Request, ma::ModelAdmin, @nospecialize(obj))
    T = ma.model
    meta = modelmeta(T)
    save_as_new = req.method == "POST" && ma.save_as && haskey(req.POST, "_saveasnew")
    save_as_new && (obj = nothing)
    adding = obj === nothing
    adding ? require_perm(req, ma, :add) : require_perm(req, ma, :view, :change; obj = obj)
    editable = adding || can(req, ma, :change, obj)
    req.method == "POST" && !editable && require_perm(req, ma, :change; obj = obj)
    ro = readonly_fields(ma, req, obj)
    data = req.method == "POST" ? req.POST : nothing
    custom_add = adding && ma.add_form !== nothing
    locked = adding || !Juango.is_composite(T) ? Symbol[] : Symbol[f.name for f in Juango.pk_fields(T)]   # a key can't change
    form = configure_widgets!(ma, custom_add ? ma.add_form(data, req.FILES) :
                                  Juango.ModelForm(T; data = data, files = req.FILES, instance = obj,
                                                   fields = filter(!in(locked), admin_fields(ma, req, obj))))
    pfs = custom_add ? Symbol[] : ma.password_fields
    inlines = save_as_new || custom_add ? Any[] : inline_formsets(ma, req, obj, data)
    if req.method == "POST" && is_valid(form) && all(x -> is_valid(x[2]), inlines)
        o = Juango.atomic() do
            o = save!(form; commit = false)
            for pf in pfs
                raw = get(req.POST, string(pf), "")
                if !isempty(raw)
                    setproperty!(o, pf, make_password(raw))
                elseif adding
                    setproperty!(o, pf, "!" * Juango.random_string(40))
                end
            end
            save!(o)
            Juango.save_m2m!(form)
            for (ia, fs) in inlines
                fs.parent = o
                save!(fs)
            end
            o
        end
        log_action!(req.user, o, adding ? ADDITION : CHANGE, adding ? "Added." : change_message(form, inlines))
        verb = adding ? "added" : "changed"
        if haskey(req.POST, "_continue") || save_as_new || custom_add
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may edit it again below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; model = ma.slug, id = Juango.pk_string(o)))
        elseif haskey(req.POST, "_addanother")
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may add another $(meta.verbose_name) below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:add"; model = ma.slug))
        end
        message!(req, :success, interpolate(adding ? gettext("The %(model)s “%(object)s” was added successfully.") :
                                                     gettext("The %(model)s “%(object)s” was changed successfully."),
                                            Dict("model" => meta.verbose_name, "object" => o)))
        return Juango.HttpResponseRedirect(reverse_url("admin:changelist"; model = ma.slug))
    end
    auto_readonly = adding ? Any[] :
        [Dict{String,Any}("label" => label(f), "value" => format_value(getproperty(obj, attname(f))))
         for f in Juango.all_fields(T) if !f.editable && !(f.name in ro)]
    ctx = base_context(req, interpolate(adding ? gettext("Add %(model)s") : editable ? gettext("Change %(model)s") : gettext("View %(model)s"),
                                        Dict("model" => meta.verbose_name)))
    prepop = adding ? [Dict("target" => "id_" * string(k), "sources" => ["id_" * string(s) for s in v])
                       for (k, v) in ma.prepopulated_fields] : Any[]
    merge!(ctx, Dict{String,Any}(
        "editable" => editable, "can_delete" => !adding && can(req, ma, :delete, obj), "can_add" => can(req, ma, :add),
        "opts" => opts(ma), "form" => form, "object" => obj, "adding" => adding, "readonly" => auto_readonly,
        "groups" => custom_add ? [Dict{String,Any}("name" => "", "rows" => [Dict{String,Any}("readonly" => false, "field" => form[f.name]) for f in form.fields])] :
                    form_groups(ma, form, obj, editable; locked = locked, readonly = ro),
        "inlines" => editable ? [inline_context(ia, fs) for (ia, fs) in inlines] : Any[],
        "prepopulated" => Juango.JSON.json(prepop), "save_as" => ma.save_as && !adding && can(req, ma, :add),
        "password_fields" => [Dict("name" => string(pf), "label" => uppercasefirst(string(pf))) for pf in pfs],
        "view_on_site" => adding ? nothing : get_absolute_url(obj),
        "history_url" => adding ? nothing : reverse_url("admin:history"; model = ma.slug, id = Juango.pk_string(obj))))
    render(req, "admin/change_form.html", ctx)
end

add_view(req::Request; model) = change_form(req, get_admin(model), nothing)
"The object with this primary key (from the URL), or a 404."
function admin_object(ma::ModelAdmin, req, id)
    pk = Juango.parse_pk(ma.model, id)
    pk === nothing && throw(Http404("No $(modelmeta(ma.model).verbose_name) with id '$id'"))
    Juango.get_object_or_404(admin_queryset(ma, req); pk = pk)
end

change_view(req::Request; model, id) = (ma = get_admin(model); change_form(req, ma, admin_object(ma, req, id)))

function delete_view(req::Request; model, id)
    ma = get_admin(model)
    meta = modelmeta(ma.model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :delete; obj = obj)
    if req.method == "POST"
        name = string(obj)
        try
            Juango.atomic() do
                log_action!(req.user, obj, DELETION)
                delete!(obj)
            end
            message!(req, :success, interpolate(gettext("The %(model)s “%(object)s” was deleted successfully."),
                                                Dict("model" => meta.verbose_name, "object" => name)))
            return Juango.HttpResponseRedirect(reverse_url("admin:changelist"; model = ma.slug))
        catch e
            e isa Union{ProtectedError,RestrictedError} || rethrow()
            message!(req, :error, e.msg)
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; model = ma.slug, id = id))
        end
    end
    related = Any[]
    for (rn, M, f) in reverse_relations(ma.model)
        startswith(string(rn), "+") && continue
        n = count(filter(objects(M), Q(attname(f) => obj.id)))
        n > 0 && push!(related, Dict{String,Any}("name" => modelmeta(M).verbose_name_plural, "count" => n,
                                                 "action" => f.on_delete === :CASCADE ? "deleted" :
                                                             f.on_delete === :SET_NULL ? "unlinked" :
                                                             f.on_delete === :PROTECT ? "protected (blocks deletion)" :
                                                             f.on_delete === :RESTRICT ? "restricted (blocks deletion unless deleted along with it)" :
                                                             f.on_delete === :SET_DEFAULT || f.on_delete isa Juango.OnDeleteSet ? "reassigned" :
                                                             "left untouched"))
    end
    ctx = base_context(req, gettext("Are you sure?"))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "related" => related))
    render(req, "admin/delete_confirmation.html", ctx)
end

"The change history of one object."
function history_view(req::Request; model, id)
    ma = get_admin(model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :view, :change; obj = obj)
    entries = collect(select_related(order_by(filter(LogEntry; content_type = get_for_model(ma.model), object_id = Juango.pk_string(obj)),
                                              "action_time", "id"), :user))
    ctx = base_context(req, interpolate(gettext("Change history: %(object)s"), Dict("object" => obj)))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "entries" => entries))
    render(req, "admin/object_history.html", ctx)
end

"JSON search for autocomplete widgets: `?term=...` over the model's search_fields."
function autocomplete_view(req::Request; model)
    ma = get_admin(model)
    require_perm(req, ma, :view, :change)
    sfields = search_fields(ma, req)
    isempty(sfields) && throw(Http404("$(ma.slug) has no search_fields for autocomplete"))
    term = strip(get(req.GET, "term", ""))
    qs = admin_queryset(ma, req)
    isempty(term) || (qs = filter(qs, reduce(|, [Q(Symbol(f, "__icontains") => term) for f in sfields])))
    Dict("results" => [Dict("id" => Juango.pk_string(o), "text" => string(o)) for o in qs[1:20]])
end

"""
A view of `site`: runs with the site as the current one (its registry, titles, and `admin:` URL
names resolving to its namespace) and, unless `public`, only for users the site admits.
"""
function site_view(st::AdminSite, view; public = false)
    checked = public ? view : st.has_permission === nothing ? staff_member_required(view) :
        function (req; kw...)
            (Juango.is_authenticated(req.user) && req.user.is_active && st.has_permission(req)) ||
                return Juango.redirect_to_login(req, reverse_url("admin:login"))
            view(req; kw...)
        end
    # the admin checks logins itself, so LoginRequiredMiddleware leaves its views alone (as Django's)
    Juango.login_not_required(function (req; kw...)
        Base.ScopedValues.with(CURRENT_SITE => st, Juango.CURRENT_APP => ("admin" => st.name)) do
            checked(req; kw...)
        end
    end)
end

"""
    Admin.urls(site = Admin.site)

URL patterns for an admin site, namespaced by its name: `path("admin/", Admin.urls())`.
A ModelAdmin's `urls = [path("<str:id>/publish/", publish; name = "post_publish")]` are added
under the model's URL (`admin/post/3/publish/`), and the site's own `urls` at its root; both
go through the site's login and permission checks.
"""
function urls(st::AdminSite = site)
    Juango.require_app("admin", "Admin.urls()")
    st === site && register_user_model!()
    s(v) = site_view(st, v)
    wrap(p) = Juango.wrap_view(p, s)
    custom = Any[path(ma.slug * "/", include_urls([wrap(p) for p in ma.extra_urls])) for ma in values(st.registry) if !isempty(ma.extra_urls)]
    include_urls(vcat(Any[
        path("", s(index); name = "index"),
        path("login/", site_view(st, admin_login; public = true); name = "login"),
        path("logout/", site_view(st, admin_logout; public = true); name = "logout")],
        Any[wrap(p) for p in st.extra_urls], custom, Any[
        path("<slug:model>/", s(changelist); name = "changelist"),
        path("<slug:model>/add/", s(add_view); name = "add"),
        path("<slug:model>/autocomplete/", s(autocomplete_view); name = "autocomplete"),
        path("<slug:model>/<str:id>/change/", s(change_view); name = "change"),
        path("<slug:model>/<str:id>/delete/", s(delete_view); name = "delete"),
        path("<slug:model>/<str:id>/history/", s(history_view); name = "history"),
    ]); namespace = st.name)
end

end # module Admin
