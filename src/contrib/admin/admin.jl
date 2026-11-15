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
    options::Dict{Symbol,Any}            # the hooks and options below (save_model, list_display_links, ...)
    app::String                          # the model's app label: its URLs are <app>/<model>/
end
option(ma::ModelAdmin, k::Symbol, default = nothing) = get(ma.options, k, default)

"""
    Admin.display(f; description = nothing, boolean = false, ordering = nothing, empty_value = nothing)

A computed `list_display` column, as Django's `@admin.display`: `f(obj)` gives the value,
`description` the header, `boolean = true` shows it as a ✔/✘ icon, `ordering = "field"` (or
`"-field"`, or a lookup like `"author__name"`) makes the column sortable by that field, and
`empty_value` is shown for `nothing`.

    Admin.register!(Post; list_display = [:title, Admin.display(p -> count(p.comments); description = "Comments")])
"""
struct Display
    f::Function
    description::Union{Nothing,String}
    boolean::Bool
    ordering::Union{Nothing,String}
    empty_value::Union{Nothing,String}
end
display(f::Function; description = nothing, boolean::Bool = false, ordering = nothing, empty_value = nothing) =
    Display(f, description === nothing ? nothing : string(description), boolean, ordering === nothing ? nothing : string(ordering),
            empty_value === nothing ? nothing : string(empty_value))

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

Hooks (Django's ModelAdmin methods):
* `save_model = (req, obj, form, change) -> ...` saves the object (`save!(obj)` by default): set
  `obj.created_by = req.user` here. `save_related = (req, form, inlines, change) -> ...` saves the
  many-to-many fields and inlines after it. `delete_model = (req, obj) -> ...` and
  `delete_queryset = (req, qs) -> ...` delete (the latter for "Delete selected").
* `response_add` / `response_change = (req, obj) -> response`, `response_delete = (req, name) -> response`:
  where to go after saving or deleting.
* `get_form = (req, obj, data, files) -> form` builds the change form.
* `formfield_for_foreignkey`, `formfield_for_manytomany`, `formfield_for_choice_field =
  (req, field) -> field or nothing`: replace a field of the form, to narrow a select's queryset
  per request (`ModelChoiceField(filter(...))`). `formfield_overrides = Dict(:text => Dict(:widget => ...))`
  changes every form field of a kind. `radio_fields = [:status]` shows choices as radio buttons.

Change list options:
* `list_display_links`: the columns that link to the change page (default the first; `[]` for
  none). Columns of model fields, and `Admin.display(...; ordering = ...)` ones, sort when their
  header is clicked (`?o=2.-1`); `sortable_by = [...]` limits which.
* `empty_value_display = "-"`, `search_help_text`, `save_on_top = true` (save buttons above the
  form too).
* `list_max_show_all = 200`: a "Show all" link when the whole list is no longer than that.
* `filter_horizontal = [:tags]` / `filter_vertical`: a many-to-many field as two lists, available
  and chosen, with a filter box (Django's widget); a plain multiple select without JavaScript.
* `show_facets = :allow` (a "Show counts" link), `:always` or `:never`: each filter choice with the
  number of rows it would leave (Django 5's facets; one count query per choice).
* `preserve_filters = true`: after saving or deleting, back to the change list with the filters,
  search and sorting it had.
* `get_fieldsets`, `get_inlines`, `get_exclude`, `get_prepopulated_fields = (req, obj) -> ...`:
  those options per request and object.
* `password_change_page = true` (the user admin's): the password isn't an input on the change
  page but a summary with a link to its own page (`AdminPasswordChangeForm`).
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
                   get_search_fields = nothing, get_ordering = nothing, get_readonly_fields = nothing, get_fields = nothing,
                   save_model = nothing, save_related = nothing, delete_model = nothing, delete_queryset = nothing,
                   response_add = nothing, response_change = nothing, response_delete = nothing, get_form = nothing,
                   formfield_for_foreignkey = nothing, formfield_for_manytomany = nothing, formfield_for_choice_field = nothing,
                   formfield_overrides = Dict{Symbol,Any}(), radio_fields = Symbol[], list_display_links = nothing,
                   sortable_by = nothing, empty_value_display = "-", search_help_text = nothing, save_on_top = false,
                   get_fieldsets = nothing, get_inlines = nothing, get_exclude = nothing, get_prepopulated_fields = nothing,
                   list_max_show_all = 200, preserve_filters = true, password_change_page = false, show_facets = :allow,
                   filter_horizontal = Symbol[], filter_vertical = Symbol[], import_export = nothing)
    modelmeta(T)  # validates T is a model
    slug = model_name(T)
    key = admin_key(T)
    acts = AdminAction[to_action(a) for a in actions]
    delete_action && pushfirst!(acts, action(delete_selected; description = "Delete selected $(modelmeta(T).verbose_name_plural)",
                                             permission = :delete))
    for f in list_editable
        Symbol(f) in Symbol.(collect(list_display)) || throw(ArgumentError("list_editable field '$f' must also be in list_display"))
    end
    site.registry[key] = ModelAdmin(T, slug, collect(Any, list_display), Symbol.(search_fields),
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
                                get_list_filter, get_search_fields, get_ordering, get_readonly_fields, get_fields,
                                Dict{Symbol,Any}(:save_model => save_model, :save_related => save_related, :delete_model => delete_model,
                                                 :delete_queryset => delete_queryset, :response_add => response_add,
                                                 :response_change => response_change, :response_delete => response_delete,
                                                 :get_form => get_form, :formfield_for_foreignkey => formfield_for_foreignkey,
                                                 :formfield_for_manytomany => formfield_for_manytomany,
                                                 :formfield_for_choice_field => formfield_for_choice_field,
                                                 :formfield_overrides => formfield_overrides, :radio_fields => Symbol.(collect(radio_fields)),
                                                 :list_display_links => list_display_links === nothing ? nothing : collect(Any, list_display_links),
                                                 :sortable_by => sortable_by === nothing ? nothing : Symbol.(collect(sortable_by)),
                                                 :empty_value_display => string(empty_value_display), :search_help_text => search_help_text,
                                                 :save_on_top => save_on_top, :get_fieldsets => get_fieldsets,
                                                 :get_inlines => get_inlines, :get_exclude => get_exclude,
                                                 :get_prepopulated_fields => get_prepopulated_fields,
                                                 :list_max_show_all => list_max_show_all, :preserve_filters => preserve_filters,
                                                 :password_change_page => password_change_page,
                                                 :show_facets => Symbol(show_facets),
                                                 :filter_horizontal => Symbol.(collect(filter_horizontal)),
                                                 :filter_vertical => Symbol.(collect(filter_vertical)),
                                                 :import_export => import_export === true ? Juango.ModelResource(T) : import_export), modelmeta(T).app)
    filter!(!=(key), site.order)
    push!(site.order, key)
    T
end
"A model's key in an admin registry: `\"app_label.model_name\"` (Django's label_lower)."
Base.@nospecializeinfer admin_key(@nospecialize(T::Type)) = modelmeta(T).app * "." * model_name(T)

"Remove a model from the admin (`site` defaults to `Admin.site`)."
Base.@nospecializeinfer function unregister!(@nospecialize(T::Type); site::AdminSite = Admin.site)
    key = admin_key(T)
    delete!(site.registry, key)
    filter!(!=(key), site.order)
    nothing
end
is_registered(T::Type; site::AdminSite = Admin.site) = haskey(site.registry, admin_key(T))
"The `ModelAdmin` of a model on the current site (for custom admin views)."
model_admin(T::Type) = get_admin(modelmeta(T).app, model_name(T))

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
              list_filter = [:is_staff, :is_superuser, :is_active], password_fields = [:password], password_change_page = true,
              add_form = (data, files) -> Juango.UserCreationForm(data), kw...)
end

get_admin(app, model) = (ma = get(current_site().registry, string(app, ".", model), nothing);
                         ma === nothing ? throw(Http404("No admin for model '$app.$model'")) : ma)

# options that can depend on the request (Django's get_list_display & co.)
list_display(ma::ModelAdmin, req) = ma.get_list_display === nothing ? ma.list_display : collect(Any, ma.get_list_display(req))
list_filter(ma::ModelAdmin, req) = ma.get_list_filter === nothing ? ma.list_filter :
    Any[x isa Union{AbstractString,Symbol} ? Symbol(x) : x for x in ma.get_list_filter(req)]
search_fields(ma::ModelAdmin, req) = ma.get_search_fields === nothing ? ma.search_fields : Symbol.(collect(ma.get_search_fields(req)))
ordering(ma::ModelAdmin, req) = ma.get_ordering === nothing ? ma.ordering : String.(string.(collect(ma.get_ordering(req))))
Base.@nospecializeinfer readonly_fields(ma::ModelAdmin, req, @nospecialize(obj)) = ma.get_readonly_fields === nothing ? ma.readonly_fields : Symbol.(collect(ma.get_readonly_fields(req, obj)))

opts(ma::ModelAdmin) = (m = modelmeta(ma.model);
    Dict{String,Any}("slug" => ma.slug, "verbose_name" => m.verbose_name, "verbose_name_plural" => m.verbose_name_plural,
                     "name" => m.name, "app_label" => ma.app, "app_name" => app_verbose_name(ma.app)))
"An app's name as the admin shows it: its `App`'s verbose_name, else the label in title case."
app_verbose_name(label) = (a = get(Juango.APP_DEFS, label, nothing); a === nothing ? titlecase(replace(label, '_' => ' ')) : a.verbose_name)

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
     reverse_url("admin:change"; app = modelmeta(T).app, model = model_name(T), id = e.object_id))

function index(req::Request; app = nothing)
    st = current_site()
    keys_ = [k for k in visible_models(req) if app === nothing || st.registry[k].app == app]
    app === nothing || !isempty(keys_) || throw(Http404("No app '$app' in this admin"))
    title = app === nothing ? something(st.index_title, gettext("Site administration")) :
            replace(gettext("%(app)s administration"), "%(app)s" => app_verbose_name(app))
    ctx = base_context(req, title)
    ctx["model_list"] = [merge(opts(st.registry[s]), Dict{String,Any}(
                             "count" => can_view(req, st.registry[s]) ? count(admin_queryset(st.registry[s], req)) : nothing,
                             "can_add" => can(req, st.registry[s], :add), "can_view" => can_view(req, st.registry[s]),
                             "can_change" => can(req, st.registry[s], :change)))
                         for s in keys_]
    # grouped by app, as Django's: apps by name, models in the order they were registered
    labels = unique(m["app_label"] for m in ctx["model_list"])
    ctx["app_list"] = sort([Dict{String,Any}("app_label" => l, "name" => app_verbose_name(l),
                                             "app_url" => reverse_url("admin:app_list"; app = l),
                                             "models" => [m for m in ctx["model_list"] if m["app_label"] == l]) for l in labels];
                           by = a -> lowercase(a["name"]))
    ctx["app_label"] = app
    if app === nothing
        recent = req.user isa AbstractUser ? collect(select_related(filter(LogEntry; user = req.user), :content_type)[1:10]) : LogEntry[]
        ctx["recent_actions"] = [Dict{String,Any}("entry" => e, "url" => admin_url_for(e),
                                                  "type" => e.content_type === nothing ? "" : e.content_type.model) for e in recent]
    else
        ctx["recent_actions"] = Dict{String,Any}[]
    end
    render(req, app === nothing ? "admin/index.html" : ["admin/$app/app_index.html", "admin/app_index.html"], ctx)
end
"An app's page in the admin (`/admin/<app_label>/`): its models."
app_index(req::Request; app) = index(req; app = app)

admin_login(req::Request) =
    LoginView(template = "admin/login.html", redirect_url = reverse_url("admin:index"), require_staff = true)(req)

function admin_logout(req::Request)
    req.method == "POST" || return Juango.HttpResponseNotAllowed(["POST"])
    Juango.logout!(req)
    render(req, "admin/logged_out.html", base_context(req, gettext("Logged out")))
end

function header_label(ma::ModelAdmin, col)
    col isa Pair && return string(col.first)
    col isa Display && return something(col.description, "")
    col === :__str__ && return uppercasefirst(modelmeta(ma.model).verbose_name)
    f = findfield(modelmeta(ma.model), Symbol(col))
    f === nothing ? uppercasefirst(replace(string(col), '_' => ' ')) : label(f)
end

Base.@nospecializeinfer function raw_cell(ma::ModelAdmin, @nospecialize(obj), col)
    col isa Pair && return col.second(obj)
    col isa Display && return col.f(obj)
    col === :__str__ && return string(obj)
    f = findfield(modelmeta(ma.model), Symbol(col))
    val = getproperty(obj, Symbol(col))
    f !== nothing && f.choices !== nothing && return Juango.choice_label(Juango.field_choices(f), val)
    val
end
Base.@nospecializeinfer function cell_value(ma::ModelAdmin, @nospecialize(obj), col)
    v = raw_cell(ma, obj, col)
    if v === nothing || v == ""
        return col isa Display && col.empty_value !== nothing ? col.empty_value : option(ma, :empty_value_display, "-")
    end
    col isa Display && col.boolean && return format_value(Bool(v))
    format_value(v)
end

"The ORDER BY a list_display column sorts by (`nothing`: not sortable): a field's name, or a display's `ordering`."
function column_ordering(ma::ModelAdmin, col)
    sb = option(ma, :sortable_by)
    name = col isa Symbol ? col : col isa Display ? nothing : col isa AbstractString ? Symbol(col) : nothing
    sb !== nothing && !(name in sb) && !(col isa Display && col.ordering !== nothing && Symbol(lstrip(col.ordering, '-')) in sb) && return nothing
    col isa Display && return col.ordering
    (name === nothing || name === :__str__) && return nothing
    f = findfield(modelmeta(ma.model), name)
    f === nothing || f.kind in (:m2m, :gfk, :grel) ? nothing : string(attname(f))
end

"The change list's column headers: the label, and for sortable columns the link that sorts by it (or flips it)."
function column_headers(req::Request, ma::ModelAdmin, cols, spec)
    out = Any[]
    for (i, c) in enumerate(cols)
        if column_ordering(ma, c) === nothing
            push!(out, (label = header_label(ma, c), url = nothing, sorted = nothing, priority = 0))
            continue
        end
        k = findfirst(x -> x[1] == i, spec)
        # clicking a column sorts by it first; clicking the first sorted column flips it
        new = k === nothing ? vcat([(i, false)], spec) : k == 1 ? vcat([(i, !spec[1][2])], spec[2:end]) : vcat([spec[k]], deleteat!(copy(spec), k))
        push!(out, (label = header_label(ma, c), url = query_with(req, "o" => spec_string(new)),
                    sorted = k === nothing ? nothing : spec[k][2] ? "desc" : "asc", priority = k === nothing ? 0 : k))
    end
    out
end

"`?o=2.-1` (Django's format): the list_display columns to sort by, 1-based, `-` for descending."
function sort_spec(req::Request, ma::ModelAdmin, cols)
    raw = get(req.GET, "o", "")
    spec = Tuple{Int,Bool}[]
    for part in split(raw, '.'; keepempty = false)
        desc = startswith(part, "-")
        i = tryparse(Int, lstrip(part, '-'))
        (i === nothing || !(1 <= i <= length(cols)) || column_ordering(ma, cols[i]) === nothing) && continue
        any(x -> x[1] == i, spec) || push!(spec, (i, desc))
    end
    spec
end
function spec_ordering(ma::ModelAdmin, cols, spec)
    out = String[]
    for (i, desc) in spec
        o = column_ordering(ma, cols[i])
        d = startswith(o, "-")
        push!(out, (desc != d ? "-" : "") * lstrip(o, '-'))
    end
    out
end
spec_string(spec) = join([(d ? "-" : "") * string(i) for (i, d) in spec], ".")

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

"""
The filter sidebar. With `base` (the searched queryset) and facets on, each choice shows how many
rows it would leave, counting the search and the other filters (Django 5's facets).
"""
function filter_specs(req::Request, ma::ModelAdmin, filters = list_filters(req, ma); base = nothing, facets::Bool = false)
    specs = Any[]
    for (title, key, opts_, apply) in filters
        cur = get(req.GET, key, nothing)
        others = nothing
        if facets && base !== nothing                 # the queryset with every other filter applied
            others = base
            for (_, k2, _, ap2) in filters
                k2 == key && continue
                v2 = get(req.GET, k2, nothing)
                (v2 === nothing || isempty(v2)) || (others = ap2(others, v2))
            end
        end
        choices = [Dict{String,Any}("label" => others === nothing ? l : string(l, " (", count(v === nothing ? others : apply(others, v)), ")"),
                                    "url" => query_with(req, key => v),
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
            foreach(o -> log_action!(req.user, o, DELETION), objs)
            dq = option(ma, :delete_queryset)
            if dq === nothing
                foreach(delete!, objs)
            else
                dq(req, filter(objects(ma.model), Q(pk__in = [o.pk for o in objs])))
            end
        end
        n = length(objs)
        message!(req, :success, "Successfully deleted $n $(n == 1 ? meta.verbose_name : meta.verbose_name_plural).")
    catch e
        e isa Union{ProtectedError,RestrictedError} || rethrow()
        message!(req, :error, Juango.protected_message(e))
    end
    nothing
end

# (text that starts like a formula gets a leading ', so spreadsheets don't run it)
csv_cell(v) = v isa Number ? Juango.csv_field(v) :
    Juango.csv_field(replace(v isa SafeString ? v.s : v === nothing ? "" : string(v), r"<[^>]*>" => ""))

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

function changelist(req::Request; app, model)
    ma = get_admin(app, model)
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
    searched = qs
    filters = list_filters(req, ma)
    for (_, key, _, apply) in filters
        v = get(req.GET, key, nothing)
        (v === nothing || isempty(v)) && continue
        qs = apply(qs, v)
    end
    qs, drill = date_drilldown(req, ma, qs)
    # As Django's ChangeList: the admin's ordering, else the model's Meta.ordering given explicitly (a queryset with
    # an aggregate annotate leaves Meta.ordering out), then the primary key, so pages are in a total order
    cols = list_display(ma, req)
    ords = Any[o for o in ordering(ma, req)]
    isempty(ords) && append!(ords, meta.ordering)
    spec = sort_spec(req, ma, cols)                    # clicked column headers come first
    if !isempty(spec)
        chosen = spec_ordering(ma, cols, spec)
        ords = vcat(Any[chosen...], Any[o for o in ords if !(o isa AbstractString && lstrip(o, '-') in lstrip.(chosen, '-'))])
    end
    if !Juango.is_composite(ma.model) && !any(o -> o isa AbstractString && lstrip(o, '-') in ("id", "pk"), ords)
        push!(ords, "-id")
    end
    qs = order_by(qs, ords...)
    # Load the objects behind foreign-key columns in the same query (no query per row): list_select_related
    sr = ma.list_select_related
    fks = sr === false ? Symbol[] : sr === true ? Symbol[f.name for f in meta.fields if f.kind === :fk] :
          sr !== nothing ? Symbol.(collect(sr)) :
          Symbol[c for c in cols if c isa Symbol && (f = findfield(meta, c)) !== nothing && f.kind === :fk && f.name === c]
    isempty(fks) || (qs = Juango.select_related(qs, fks...))
    p = Paginator(qs, ma.list_per_page)
    max_all = option(ma, :list_max_show_all, 200)
    show_all = haskey(req.GET, "all") && p.count <= max_all              # "Show all": one page
    show_all && (p = Paginator(qs, max(p.count, 1)))
    # preserve_filters: the change page remembers this list's filters, search and sorting
    back_q = option(ma, :preserve_filters, true) && !isempty(req.query_string) ? "?_changelist_filters=" * Juango.urlquote(req.query_string) : ""
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
    links = option(ma, :list_display_links)
    linked(i, c) = links === nothing ? i == 1 : any(l -> l == c || (c isa Symbol && string(l) == string(c)), links)
    rows = Any[]
    for (k, o) in enumerate(objs)
        cells = Any[]
        for (i, c) in enumerate(cols)
            if fs !== nothing && c isa Symbol && c in ma.list_editable
                bf = forms[k][c]
                errs = get(forms[k].errors, c, String[])
                push!(cells, (value = SafeString((isempty(errs) ? "" : Juango.errors_html(errs)) * Juango.widget_html(bf)), link = false))
            else
                push!(cells, (value = cell_value(ma, o, c), link = linked(i, c)))
            end
        end
        hidden = fs === nothing ? "" : Juango.widget_html(forms[k][:id])
        pk = Juango.pk_string(o)
        # a NamedTuple, not a Dict: the template reads row.id, row.cells ..., and this is per row
        push!(rows, (id = pk, cells = cells, hidden = SafeString(hidden), url = reverse_url("admin:change"; app = ma.app, model = ma.slug, id = pk) * back_q))
    end
    sf = option(ma, :show_facets, :allow)
    facets_on = sf === :always || (sf === :allow && haskey(req.GET, "_facets"))
    ctx = base_context(req, interpolate(can(req, ma, :change) ? gettext("Select %(model)s to change") : gettext("Select %(model)s to view"),
                                        Dict("model" => meta.verbose_name)))
    merge!(ctx, Dict{String,Any}(
        "opts" => opts(ma), "headers" => column_headers(req, ma, cols, spec), "rows" => rows,
        "search_help_text" => option(ma, :search_help_text),
        "page_obj" => pg, "paginator" => p, "q" => q, "has_search" => !isempty(sfields),
        "filters" => filter_specs(req, ma, filters; base = searched, facets = facets_on), "result_count" => p.count,
        "facets_toggle" => option(ma, :show_facets, :allow) === :allow && !isempty(filters) ?
            (facets_on ? (label = gettext("Hide counts"), url = query_with(req, "_facets" => nothing)) :
                         (label = gettext("Show counts"), url = query_with(req, "_facets" => "1"))) : nothing,
        "show_full_count" => ma.show_full_result_count, "total" => ma.show_full_result_count ? count(admin_queryset(ma, req)) : nothing,
        "can_add" => can(req, ma, :add), "can_delete" => can(req, ma, :delete),
        "can_import" => option(ma, :import_export) !== nothing && can(req, ma, :add) && can(req, ma, :change),
        "can_export" => option(ma, :import_export) !== nothing,
        "actions" => [Dict("name" => a.name, "description" => a.description) for a in ma.actions if can(req, ma, a.permission)],
        "list_editable" => fs !== nothing, "management_form" => fs === nothing ? "" : management_form(fs),
        "date_hierarchy" => drill,
        "prev_url" => pg.has_previous ? query_with(req, "page" => pg.previous_page_number) : nothing,
        "next_url" => pg.has_next ? query_with(req, "page" => pg.next_page_number) : nothing,
        "show_all_url" => !show_all && p.num_pages > 1 && p.count <= max_all ? query_with(req, "all" => "") : nothing))
    render(req, "admin/change_list.html", ctx)
end

# --- change form ---------------------------------------------------------------------------------------

Base.@nospecializeinfer function admin_fields(ma::ModelAdmin, req = nothing, @nospecialize(obj = nothing))
    fs = ma.get_fields !== nothing ? Symbol.(collect(ma.get_fields(req, obj))) : ma.fields !== nothing ? ma.fields :
         [f.name for f in vcat(Juango.all_fields(ma.model), modelmeta(ma.model).m2m)
          if f.editable && !(f.name in admin_exclude(ma, req, obj)) && !(f.name in ma.password_fields)]
    ro = req === nothing ? ma.readonly_fields : readonly_fields(ma, req, obj)
    [f for f in fs if !(f in ro)]
end

Base.@nospecializeinfer admin_exclude(ma::ModelAdmin, req, @nospecialize(obj)) =
    (h = option(ma, :get_exclude); h === nothing || req === nothing ? ma.exclude : Symbol.(collect(h(req, obj))))

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
Base.@nospecializeinfer function form_groups(ma::ModelAdmin, form, @nospecialize(obj), editable; locked = Symbol[], readonly = ma.readonly_fields,
                                             fieldsets = ma.fieldsets)
    row(name) = if editable && any(f -> f.name === name, form.fields)
        Dict{String,Any}("readonly" => false, "field" => form[name])
    else
        readonly_row(ma, obj, name)
    end
    layout = isempty(fieldsets) ?
        ["" => vcat(locked, [f.name for f in form.fields], readonly)] : fieldsets
    [Dict{String,Any}("name" => name, "rows" => [row(n) for n in names]) for (name, names) in layout]
end

Base.@nospecializeinfer function inline_formsets(ma::ModelAdmin, req, @nospecialize(obj), data)
    out = Any[]
    h = option(ma, :get_inlines)
    for ia in (h === nothing ? ma.inlines : collect(InlineAdmin, h(req, obj)))
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

function configure_widgets!(ma::ModelAdmin, form, req = nothing)
    overrides = option(ma, :formfield_overrides, Dict{Symbol,Any}())
    radios = option(ma, :radio_fields, Symbol[])
    for (i, f) in enumerate(form.fields)
        # formfield_for_*: the admin's hook may replace the field (keeping its name)
        hook = f.kind === :fk ? option(ma, :formfield_for_foreignkey) : f.kind === :m2m ? option(ma, :formfield_for_manytomany) :
               f.choices !== nothing ? option(ma, :formfield_for_choice_field) : nothing
        if hook !== nothing && req !== nothing
            g = hook(req, f)
            if g !== nothing && g !== f
                g = deepcopy(g)
                g.name = f.name
                form.fields[i] = f = g
            end
        end
        for (k, v) in get(overrides, f.kind, Dict{Symbol,Any}())
            setproperty!(f, Symbol(k), v)
        end
        f.name in radios && (f.widget = :radio)
        for (opt, dir) in ((:filter_horizontal, "horizontal"), (:filter_vertical, "vertical"))
            f.kind === :m2m && f.name in option(ma, opt, Symbol[]) &&
                (f.widget = Juango.Widget(; attrs = Dict("data-filter-box" => dir, "data-filter-label" => string(label(f)))))
        end
        f.name in ma.raw_id_fields && (f.widget = :raw_id)
        f.name in ma.autocomplete_fields && (f.widget = :autocomplete)
        f.kind === :fk && Juango.widget_kind(f.widget) === nothing && (w = big_fk_widget(f)) !== nothing && (f.widget = w)
    end
    form
end

"""
A foreign key to a table with more than `ADMIN_FK_SELECT_LIMIT` rows (1000; `nothing` turns this
off) would render a select of every row: use the search box when the related model is in the
admin with `search_fields`, else an id box.
"""
function big_fk_widget(f)
    limit = get(settings, :ADMIN_FK_SELECT_LIMIT, 1000)
    limit === nothing && return nothing
    R = related_model(f)
    count(objects(R)[1:limit+1]) > limit || return nothing        # (a capped count: cheap on a big table)
    ra = get(current_site().registry, admin_key(R), nothing)
    ra !== nothing && !isempty(ra.search_fields) ? :autocomplete : :raw_id
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
    gf = option(ma, :get_form)
    form = configure_widgets!(ma, custom_add ? ma.add_form(data, req.FILES) :
                                  gf !== nothing ? gf(req, obj, data, req.FILES) :
                                  Juango.ModelForm(T; data = data, files = req.FILES, instance = obj,
                                                   fields = filter(!in(locked), admin_fields(ma, req, obj))), req)
    pfs = custom_add || (!adding && option(ma, :password_change_page, false)) ? Symbol[] : ma.password_fields
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
            sm = option(ma, :save_model)
            sm === nothing ? save!(o) : sm(req, o, form, !adding)          # save_model(req, obj, form, change)
            foreach(x -> x[2].parent = o, inlines)
            sr = option(ma, :save_related)
            if sr === nothing
                Juango.save_m2m!(form)
                foreach(x -> save!(x[2]), inlines)
            else
                sr(req, form, [x[2] for x in inlines], !adding)
            end
            o
        end
        log_action!(req.user, o, adding ? ADDITION : CHANGE, adding ? "Added." : change_message(form, inlines))
        resp_hook = option(ma, adding ? :response_add : :response_change)
        resp_hook === nothing || return Juango.to_response(resp_hook(req, o))
        verb = adding ? "added" : "changed"
        if haskey(req.POST, "_continue") || save_as_new || custom_add
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may edit it again below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; app = ma.app, model = ma.slug, id = Juango.pk_string(o)) * keep_filters(req))
        elseif haskey(req.POST, "_addanother")
            message!(req, :success, "The $(meta.verbose_name) “$(o)” was $verb successfully. You may add another $(meta.verbose_name) below.")
            return Juango.HttpResponseRedirect(reverse_url("admin:add"; app = ma.app, model = ma.slug))
        end
        message!(req, :success, interpolate(adding ? gettext("The %(model)s “%(object)s” was added successfully.") :
                                                     gettext("The %(model)s “%(object)s” was changed successfully."),
                                            Dict("model" => meta.verbose_name, "object" => o)))
        return Juango.HttpResponseRedirect(changelist_url(ma, req))
    end
    auto_readonly = adding ? Any[] :
        [Dict{String,Any}("label" => label(f), "value" => format_value(getproperty(obj, attname(f))))
         for f in Juango.all_fields(T) if !f.editable && !(f.name in ro)]
    ctx = base_context(req, interpolate(adding ? gettext("Add %(model)s") : editable ? gettext("Change %(model)s") : gettext("View %(model)s"),
                                        Dict("model" => meta.verbose_name)))
    prepop = adding ? [Dict("target" => "id_" * string(k), "sources" => ["id_" * string(s) for s in v])
                       for (k, v) in (h = option(ma, :get_prepopulated_fields); h === nothing ? ma.prepopulated_fields : h(req, obj))] : Any[]
    merge!(ctx, Dict{String,Any}(
        "editable" => editable, "can_delete" => !adding && can(req, ma, :delete, obj), "can_add" => can(req, ma, :add),
        "opts" => opts(ma), "form" => form, "object" => obj, "adding" => adding, "readonly" => auto_readonly,
        "groups" => custom_add ? [Dict{String,Any}("name" => "", "rows" => [Dict{String,Any}("readonly" => false, "field" => form[f.name]) for f in form.fields])] :
                    form_groups(ma, form, obj, editable; locked = locked, readonly = ro,
                                fieldsets = (h = option(ma, :get_fieldsets); h === nothing ? ma.fieldsets :
                                             Pair{String,Vector{Symbol}}[string(k) => Symbol.(collect(v)) for (k, v) in h(req, obj)])),
        "inlines" => editable ? [inline_context(ia, fs) for (ia, fs) in inlines] : Any[],
        "prepopulated" => Juango.JSON.json(prepop), "save_as" => ma.save_as && !adding && can(req, ma, :add),
        "password_fields" => [Dict("name" => string(pf), "label" => uppercasefirst(string(pf))) for pf in pfs],
        "view_on_site" => adding ? nothing : get_absolute_url(obj), "save_on_top" => option(ma, :save_on_top, false),
        "password_change" => adding || !option(ma, :password_change_page, false) ? nothing :
            Dict("summary" => Juango.password_summary(obj), "url" => reverse_url("admin:password_change"; app = ma.app, model = ma.slug, id = Juango.pk_string(obj))),
        "history_url" => adding ? nothing : reverse_url("admin:history"; app = ma.app, model = ma.slug, id = Juango.pk_string(obj))))
    render(req, "admin/change_form.html", ctx)
end

"The change list to go back to: with the filters it had (`_changelist_filters`, preserve_filters)."
function changelist_url(ma::ModelAdmin, req::Request)
    f = get(req.GET, "_changelist_filters", "")
    reverse_url("admin:changelist"; app = ma.app, model = ma.slug) * (option(ma, :preserve_filters, true) && !isempty(f) ? "?" * f : "")
end
"`?_changelist_filters=...` to carry on to the next admin page."
keep_filters(req::Request) = (f = get(req.GET, "_changelist_filters", ""); isempty(f) ? "" : "?_changelist_filters=" * Juango.urlquote(f))

"The user admin's \"Change password\" page (`password_change_page = true`): `AdminPasswordChangeForm`."
function password_change_view(req::Request; app, model, id)
    ma = get_admin(app, model)
    option(ma, :password_change_page, false) || throw(Http404("No password page for $(ma.slug)"))
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :change; obj = obj)
    form = Juango.AdminPasswordChangeForm(req.method == "POST" ? req.POST : nothing)
    if req.method == "POST" && is_valid(form) && Juango.check_new_password!(form, obj)
        Juango.set_password!(obj, form.cleaned_data[:password1])
        save!(obj)
        log_action!(req.user, obj, CHANGE, "Changed password.")
        obj.id == req.user.id && Juango.update_session_auth_hash!(req, obj)       # changing your own: stay logged in
        message!(req, :success, gettext("Password changed successfully."))
        return Juango.HttpResponseRedirect(reverse_url("admin:change"; app = ma.app, model = ma.slug, id = Juango.pk_string(obj)))
    end
    ctx = base_context(req, interpolate(gettext("Change password: %(username)s"), Dict("username" => string(obj))))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "form" => form, "object" => obj))
    render(req, "admin/change_password.html", ctx)
end

add_view(req::Request; app, model) = change_form(req, get_admin(app, model), nothing)
"The object with this primary key (from the URL), or a 404."
function admin_object(ma::ModelAdmin, req, id)
    pk = Juango.parse_pk(ma.model, id)
    pk === nothing && throw(Http404("No $(modelmeta(ma.model).verbose_name) with id '$id'"))
    Juango.get_object_or_404(admin_queryset(ma, req); pk = pk)
end

change_view(req::Request; app, model, id) = (ma = get_admin(app, model); change_form(req, ma, admin_object(ma, req, id)))

function delete_view(req::Request; app, model, id)
    ma = get_admin(app, model)
    meta = modelmeta(ma.model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :delete; obj = obj)
    if req.method == "POST"
        name = string(obj)
        try
            Juango.atomic() do
                log_action!(req.user, obj, DELETION)
                dm = option(ma, :delete_model)
                dm === nothing ? delete!(obj) : dm(req, obj)
            end
            rd = option(ma, :response_delete)
            rd === nothing || return Juango.to_response(rd(req, name))
            message!(req, :success, interpolate(gettext("The %(model)s “%(object)s” was deleted successfully."),
                                                Dict("model" => meta.verbose_name, "object" => name)))
            return Juango.HttpResponseRedirect(changelist_url(ma, req))
        catch e
            e isa Union{ProtectedError,RestrictedError} || rethrow()
            message!(req, :error, Juango.protected_message(e))
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; app = ma.app, model = ma.slug, id = id))
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
function history_view(req::Request; app, model, id)
    ma = get_admin(app, model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :view, :change; obj = obj)
    entries = collect(select_related(order_by(filter(LogEntry; content_type = get_for_model(ma.model), object_id = Juango.pk_string(obj)),
                                              "action_time", "id"), :user))
    ctx = base_context(req, interpolate(gettext("Change history: %(object)s"), Dict("object" => obj)))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "entries" => entries))
    render(req, "admin/object_history.html", ctx)
end

"JSON search for autocomplete widgets: `?term=...` over the model's search_fields."
function autocomplete_view(req::Request; app, model)
    ma = get_admin(app, model)
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

# --- import and export (Admin.register!(T; import_export = true or a ModelResource)) ---

function import_export_resource(ma)
    r = option(ma, :import_export)
    r === nothing && throw(Http404("$(ma.slug) has no import or export"))
    r
end

"Download the model's rows (`?format=csv|xlsx|json`), or a page to choose the format."
function export_view(req::Request; app, model)
    ma = get_admin(app, model)
    can_view(req, ma) || throw(PermissionDenied())
    r = import_export_resource(ma)
    fmt = get(req.GET, "format", nothing)
    if fmt !== nothing
        fmt in ("csv", "xlsx", "json") || throw(Juango.BadRequest("format is csv, xlsx or json"))
        return Juango.export_download(r, admin_queryset(ma, req); format = Symbol(fmt))
    end
    m = modelmeta(ma.model)
    ctx = base_context(req, interpolate(gettext("Export %(name)s"), Dict("name" => m.verbose_name_plural)))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "formats" => ["csv", "xlsx", "json"], "count" => count(admin_queryset(ma, req))))
    render(req, "admin/export.html", ctx)
end

import_result_context(res) = Dict{String,Any}("errors" => res.errors, "ignored_columns" => res.ignored_columns,
                                               "totals" => Dict{String,Any}(string(k) => v for (k, v) in res.totals))
import_rows_context(res) = [Dict{String,Any}("number" => x.number, "kind" => string(x.kind), "object" => x.object_repr,
                                              "diff" => [Dict("field" => d[1], "old" => d[2] === nothing ? "" : string(d[2]),
                                                              "new" => d[3] === nothing ? "" : string(d[3])) for d in x.diff],
                                              "errors" => [Dict("field" => k, "messages" => v) for (k, v) in x.errors])
                            for x in res.rows]

"""
Upload a CSV, XLSX or JSON file: a dry run shows what would change, row by row, and the errors;
confirming imports it (in one transaction). Needs the add and change permissions.
"""
function import_view(req::Request; app, model)
    ma = get_admin(app, model)
    (can(req, ma, :add) && can(req, ma, :change)) || throw(PermissionDenied())
    r = import_export_resource(ma)
    m = modelmeta(ma.model)
    ctx = base_context(req, interpolate(gettext("Import %(name)s"), Dict("name" => m.verbose_name_plural)))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "fields" => [Juango.header_of(r, n) for n in r.fields],
                                 "id_fields" => [Juango.header_of(r, n) for n in r.import_id_fields]))
    if req.method == "POST"
        if haskey(req.POST, "confirm")
            token = string(req.POST["confirm"])
            info = occursin(r"^[0-9a-f]{32}$", token) ? get(req.session, "juango_import_" * token, nothing) : nothing
            info === nothing && throw(Juango.BadRequest("This import has expired; upload the file again."))
            path, fmt = string(info["path"]), Symbol(info["format"])
            res = Juango.import_data(r, read(path); format = fmt, dry_run = false)
            rm(path; force = true)
            delete!(req.session, "juango_import_" * token)
            if !Juango.has_errors(res)
                t = res.totals
                message!(req, :success, interpolate(gettext("Import finished: %(new)d new, %(update)d updated, %(delete)d deleted, %(skip)d unchanged."),
                                                    Dict("new" => t[:new], "update" => t[:update], "delete" => t[:delete], "skip" => t[:skip])))
                return Juango.HttpResponseRedirect(changelist_url(ma, req))
            end
            ctx["result"] = import_result_context(res); ctx["rows"] = import_rows_context(res)
        else
            ups = Juango.getlist(req.FILES, "import_file")
            up = isempty(ups) ? nothing : first(ups)
            if up === nothing
                ctx["upload_error"] = gettext("Choose a file to import.")
            else
                fmt = Juango.format_of(up.name)
                if fmt === nothing
                    ctx["upload_error"] = gettext("Upload a .csv, .xlsx or .json file.")
                else
                    data = read(up)
                    res = try
                        Juango.import_data(r, data; format = fmt)
                    catch e
                        ctx["upload_error"] = gettext("The file couldn't be read: ") * sprint(showerror, e)
                        nothing
                    end
                    if res !== nothing
                        ctx["result"] = import_result_context(res); ctx["rows"] = import_rows_context(res)
                        if !Juango.has_errors(res)
                            token = bytes2hex(rand(Juango.SECURE_RNG, UInt8, 16))
                            path = joinpath(tempdir(), "juango-import-" * token)
                            write(path, data)
                            req.session["juango_import_" * token] = Dict("path" => path, "format" => string(fmt))
                            ctx["token"] = token
                        end
                    end
                end
            end
        end
    end
    render(req, "admin/import.html", ctx)
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
    custom = Any[path(ma.app * "/" * ma.slug * "/", include_urls([wrap(p) for p in ma.extra_urls])) for ma in values(st.registry) if !isempty(ma.extra_urls)]
    SITES[st.name] = st             # (Django's per-model URL names resolve through django_url_name)
    include_urls(vcat(Any[
        path("", s(index); name = "index"),
        path("login/", site_view(st, admin_login; public = true); name = "login"),
        path("logout/", site_view(st, admin_logout; public = true); name = "logout")],
        Any[wrap(p) for p in st.extra_urls], custom, Any[
        path("<slug:app>/", s(app_index); name = "app_list"),
        path("<slug:app>/<slug:model>/", s(changelist); name = "changelist"),
        path("<slug:app>/<slug:model>/add/", s(add_view); name = "add"),
        path("<slug:app>/<slug:model>/autocomplete/", s(autocomplete_view); name = "autocomplete"),
        path("<slug:app>/<slug:model>/import/", s(import_view); name = "import"),
        path("<slug:app>/<slug:model>/export/", s(export_view); name = "export"),
        path("<slug:app>/<slug:model>/<str:id>/change/", s(change_view); name = "change"),
        path("<slug:app>/<slug:model>/<str:id>/delete/", s(delete_view); name = "delete"),
        path("<slug:app>/<slug:model>/<str:id>/history/", s(history_view); name = "history"),
        path("<slug:app>/<slug:model>/<str:id>/password/", s(password_change_view); name = "password_change"),
    ]); namespace = st.name)
end


"Admin sites by name, once their URLs are built."
const SITES = Dict{String,AdminSite}()

"""
Django's per-model URL names (`admin:<app>_<model>_changelist`, `_add`, `_change`, `_delete`,
`_history`) as the generic ones with `app`, `model` and `id` (from `object_id` or the first
argument): a reverse fallback, so they work for models registered after the URLs were built.
"""
function django_url_name(name, args, kw)
    i = findlast(':', name)
    i === nothing && return nothing
    st = get(SITES, name[1:prevind(name, i)], nothing)
    st === nothing && return nothing
    m = match(r"^(.+)_(changelist|add|change|delete|history)$", name[nextind(name, i):end])
    m === nothing && return nothing
    for ma in values(st.registry)
        ma.app * "_" * ma.slug == m[1] || continue
        target = name[1:i] * m[2]
        m[2] in ("changelist", "add") && return (target, (), (app = ma.app, model = ma.slug))
        id = !isempty(args) ? args[1] : haskey(kw, :object_id) ? kw[:object_id] : haskey(kw, :id) ? kw[:id] : nothing
        id === nothing && return nothing
        return (target, (), (app = ma.app, model = ma.slug, id = string(id)))
    end
    nothing
end
push!(Juango.REVERSE_FALLBACKS, django_url_name)

end # module Admin
