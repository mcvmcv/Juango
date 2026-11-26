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
                 ProtectedError, RestrictedError, staff_member_required, message!, reverse_url, get_absolute_url, absolute_url, model_name,
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
    TabularInline(Model; fields=nothing, extra=1, can_delete=true, fk=nothing, max_num=1000, ordering=[], ...)
    StackedInline(...)

Edit related objects on the parent's change page: a table row per object, or a stacked
form per object. `ordering` orders the inline's objects (else the model's Meta.ordering), as Django's.
Django's InlineModelAdmin options too:
- `exclude`, `readonly_fields` (shown as values, not inputs), and the hooks `get_exclude`,
  `get_readonly_fields = (req, obj) -> names`;
- `min_num`, and `get_extra`, `get_min_num`, `get_max_num = (req, obj) -> n`;
- `verbose_name`, `verbose_name_plural` (default: the model's; a `verbose_name` alone gets an "s");
- `show_change_link = true`: a link to each saved object's own change page, when the admin has its model;
- `classes = ["collapse"]`: CSS classes on the inline's group;
- `has_view_permission`, `has_add_permission`, `has_change_permission`,
  `has_delete_permission = (req, obj) -> Bool` (`obj` is the parent, or `nothing` on the add page);
  by default the model permissions. Without change permission the objects are shown read-only.
"""
struct InlineAdmin
    model::Any
    fields::Union{Nothing,Vector{Symbol}}
    extra::Int
    can_delete::Bool
    fk::Union{Nothing,Symbol}
    max_num::Int
    style::Symbol
    ordering::Vector{Any}
    options::Dict{Symbol,Any}
end
"An admin ordering: field names as strings (\"-rank\"), expressions (`Desc(F(:rank))`) as they are."
admin_ordering_terms(xs) = Any[x isa Union{AbstractString,Symbol} ? string(x) : x for x in xs]
const INLINE_OPTIONS = (:exclude, :readonly_fields, :get_exclude, :get_readonly_fields, :min_num, :get_extra, :get_min_num, :get_max_num,
                        :verbose_name, :verbose_name_plural, :show_change_link, :classes, :view_on_site,
                        :has_view_permission, :has_add_permission, :has_change_permission, :has_delete_permission, :generic)
Base.@nospecializeinfer function TabularInline(@nospecialize(T); fields = nothing, extra = 1, can_delete = true, fk = nothing, max_num = 1000,
                                               ordering = (), style = :tabular, kw...)
    for k in keys(kw)
        k in INLINE_OPTIONS || throw(ArgumentError("TabularInline: unknown option '$k'"))
    end
    o = Dict{Symbol,Any}(kw)
    haskey(o, :exclude) && (o[:exclude] = Symbol.(collect(o[:exclude])))
    haskey(o, :readonly_fields) && (o[:readonly_fields] = Symbol.(collect(o[:readonly_fields])))
    InlineAdmin(T, fields === nothing ? nothing : Symbol.(fields), extra, can_delete, fk === nothing ? nothing : Symbol(fk), max_num, Symbol(style),
                admin_ordering_terms(ordering), o)
end
StackedInline(T; kw...) = TabularInline(T; kw..., style = :stacked)
"""
    GenericTabularInline(Model; ct_field = :content_type, ct_fk_field = :object_id, options...)
    GenericStackedInline(...)

An inline of objects that point at the parent through a generic foreign key (Django's contenttypes admin):
`generic_inlineformset_factory`'s rows, with the inline's options.
"""
GenericTabularInline(T; ct_field = :content_type, ct_fk_field = :object_id, kw...) =
    TabularInline(T; kw..., generic = (Symbol(ct_field), Symbol(ct_fk_field)))
GenericStackedInline(T; kw...) = GenericTabularInline(T; kw..., style = :stacked)
inline_option(ia::InlineAdmin, k::Symbol, default = nothing) = get(ia.options, k, default)
"The inline's verbose names, as Django's: its own, else the model's (a `verbose_name` alone gets an \"s\")."
function inline_verbose_names(ia::InlineAdmin)
    m = modelmeta(ia.model)
    vn = inline_option(ia, :verbose_name)
    vnp = inline_option(ia, :verbose_name_plural)
    (something(vn, m.verbose_name), string(something(vnp, vn === nothing ? m.verbose_name_plural : string(vn, "s"))))
end
"""
The other model of an automatic many-to-many join model `M` seen from `P` (`Book` for Author's
`through(Author, :books)`), or `nothing` when `M` isn't one.
"""
Base.@nospecializeinfer function auto_through_target(@nospecialize(M), @nospecialize(P))
    (P === nothing || !(M <: Juango.AutoThrough)) && return nothing
    for r in Juango.m2m_relations(P)
        Juango.through_model(r[2]) === M && return r[3] ? related_model(r[2]) : r[2].model
    end
    nothing
end

"""
Whether the user may `action` the inline's objects (Django's InlineModelAdmin.has_<action>_permission(req, obj)):
the inline's hook, else the model permission. An automatic many-to-many join model has none of its own: as Django's,
adding, changing and deleting its rows takes change permission on the other model, viewing them view or change.
"""
Base.@nospecializeinfer function inline_can(req, ia::InlineAdmin, action::Symbol, @nospecialize(obj); parent = nothing)
    h = inline_option(ia, Symbol(:has_, action, :_permission))
    h !== nothing && return Bool(h(req, obj))
    target = auto_through_target(ia.model, parent)
    if target !== nothing
        return can_model(req, target, :change) || (action === :view && can_model(req, target, :view))
    end
    action === :view ? (can_model(req, ia.model, :view) || inline_can(req, ia, :change, obj)) : can_model(req, ia.model, action)
end
Base.@nospecializeinfer inline_readonly(ia::InlineAdmin, req, @nospecialize(obj)) =
    (h = inline_option(ia, :get_readonly_fields); h === nothing ? inline_option(ia, :readonly_fields, Symbol[]) : Symbol.(collect(h(req, obj))))
Base.@nospecializeinfer inline_exclude(ia::InlineAdmin, req, @nospecialize(obj)) =
    (h = inline_option(ia, :get_exclude); h === nothing ? inline_option(ia, :exclude, Symbol[]) : Symbol.(collect(h(req, obj))))
inline_num(ia::InlineAdmin, k::Symbol, default, req, obj) = (h = inline_option(ia, Symbol(:get_, k)); h === nothing ? default : Int(h(req, obj)))
"An inline's objects (Django's `InlineModelAdmin.get_queryset`): the model's, by the inline's ordering when it has one."
inline_queryset(ia::InlineAdmin, req = nothing) = isempty(ia.ordering) ? objects(ia.model) : order_by(objects(ia.model), ia.ordering...)

"""
Options for one model in the admin (see [`register!`](@ref)).
"""
mutable struct ModelAdmin
    model::Any
    slug::String
    list_display::Vector{Any}
    search_fields::Vector{Symbol}
    list_filter::Vector{Any}             # field names, :field => :empty / :related_only, or ListFilter(...)
    ordering::Vector{Any}                # field names ("-rank") and expressions (Desc(F(:rank)))
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
    ordering::Any                   # a field name ("-date"), or an expression (F(:date), Lower(:title)) or OrderBy, as Django's admin_order_field
    empty_value::Union{Nothing,String}
end
display(f::Function; description = nothing, boolean::Bool = false, ordering = nothing, empty_value = nothing) =
    Display(f, description === nothing ? nothing : string(description), boolean,
            ordering === nothing ? nothing : ordering isa Union{AbstractString,Symbol} ? string(ordering) : ordering,
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
`index_template`, `app_index_template`, `login_template`, `logout_template`: the site's own templates for
those pages (Django's AdminSite attributes).
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
    templates::Dict{Symbol,Any}          # :index, :app_index, :login, :logout: the site's own templates (Django's index_template & co.)
end
AdminSite(name::AbstractString = "admin"; site_header = nothing, site_title = nothing, index_title = nothing,
          has_permission = nothing, urls = Any[], registry = Dict{String,ModelAdmin}(), order = String[],
          index_template = nothing, app_index_template = nothing, login_template = nothing, logout_template = nothing) =
    AdminSite(String(name), registry, order, site_header, site_title, index_title, has_permission, collect(Any, urls),
              Dict{Symbol,Any}(k => v for (k, v) in (:index => index_template, :app_index => app_index_template,
                                                    :login => login_template, :logout => logout_template) if v !== nothing))
Base.show(io::IO, st::AdminSite) = print(io, "AdminSite(name='", st.name, "')")
"The site's template for a page, else the admin's (a name or a list of names)."
site_template(st::AdminSite, which::Symbol, default) = get(st.templates, which, default)

"""
What the admin lists and edits (Django's `ModelAdmin.get_queryset`): the `queryset` option's, else the model's,
ordered by the admin's ordering (`ordering`, or `get_ordering(req)`) when it has one.
"""
function admin_queryset(ma::ModelAdmin, req)
    qs = ma.queryset === nothing ? objects(ma.model) : ma.queryset(req)
    ords = ordering(ma, req)
    isempty(ords) ? qs : order_by(qs, ords...)
end

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
* `get_search_results = (req, queryset, term) -> (queryset, may_have_duplicates)`: a search of your own
  (Django's get_search_results); `Admin.search_results(Model, queryset, search_fields, term)` is the default one.
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
* `view_on_site = false` hides the change form's "View on site" link (shown for an object with
  `get_absolute_url`, through `admin/r/<content type>/<id>/`); a function `obj -> url` sets it.
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
                   filter_horizontal = Symbol[], filter_vertical = Symbol[], import_export = nothing, view_on_site = true,
                   lookup_allowed = nothing, get_search_results = nothing, delete_confirmation_max_display = nothing,
                   save_as_continue = true, response_post_save_add = nothing, response_post_save_change = nothing)
    modelmeta(T)  # validates T is a model
    slug = model_name(T)
    key = admin_key(T)
    acts = AdminAction[to_action(a) for a in actions]
    delete_action && pushfirst!(acts, action(delete_selected; description = "Delete selected $(modelmeta(T).verbose_name_plural)",
                                             permission = :delete))
    for f in list_editable
        Symbol(f) in Symbol.(collect(list_display)) || throw(ArgumentError("list_editable field '$f' must also be in list_display"))
    end
    site.registry[key] = ModelAdmin(T, slug, collect(Any, list_display), Symbol.(collect(search_fields)),
                                Any[x isa Union{AbstractString,Symbol} ? Symbol(x) : x for x in list_filter],
                                admin_ordering_terms(ordering), fields === nothing ? nothing : Symbol.(fields),
                                Symbol.(collect(exclude)), list_per_page, Symbol.(collect(password_fields)), queryset, acts,
                                collect(InlineAdmin, inlines), Symbol.(collect(readonly_fields)),
                                Pair{String,Vector{Symbol}}[string(k) => Symbol.(collect(v)) for (k, v) in fieldsets],
                                Dict{Symbol,Vector{Symbol}}(Symbol(k) => Symbol.(collect(v)) for (k, v) in prepopulated_fields),
                                Symbol.(collect(raw_id_fields)), Symbol.(collect(autocomplete_fields)), Symbol.(collect(list_editable)),
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
                                                 :view_on_site => view_on_site,
                                                 :lookup_allowed => lookup_allowed, :get_search_results => get_search_results,
                                                 :delete_confirmation_max_display => delete_confirmation_max_display,
                                                 :save_as_continue => save_as_continue,
                                                 :response_post_save_add => response_post_save_add, :response_post_save_change => response_post_save_change,
                                                 :import_export => import_export === true ? Juango.ModelResource(T) : import_export), modelmeta(T).app)
    filter!(!=(key), site.order)
    push!(site.order, key)
    any(x -> x === site, ALL_SITES) || push!(ALL_SITES, site)
    T
end
"A model's key in an admin registry: `\"app_label.model_name\"` (Django's label_lower)."
Base.@nospecializeinfer admin_key(@nospecialize(T::Type)) = modelmeta(T).app * "." * model_name(T)

"A model that isn't in an admin site (Django's NotRegistered)."
struct NotRegistered <: Exception
    msg::String
end
Base.showerror(io::IO, e::NotRegistered) = print(io, "NotRegistered: ", e.msg)

"Remove a model (or a list of them) from the admin (`site` defaults to `Admin.site`); one that isn't there is an error, as Django's."
Base.@nospecializeinfer function unregister!(@nospecialize(T::Type); site::AdminSite = Admin.site)
    key = admin_key(T)
    haskey(site.registry, key) || throw(NotRegistered("The model $(nameof(T)) is not registered"))
    delete!(site.registry, key)
    filter!(!=(key), site.order)
    nothing
end
unregister!(Ts::Union{AbstractVector,Tuple}; site::AdminSite = Admin.site) = foreach(T -> unregister!(T; site), Ts)
"Register several models with the same options (Django's site.register([A, B], ...))."
register!(Ts::Union{AbstractVector,Tuple}; kw...) = foreach(T -> register!(T; kw...), Ts)
is_registered(T::Type; site::AdminSite = Admin.site) = haskey(site.registry, admin_key(T))
"A model's ModelAdmin on a site (Django's get_model_admin); a model that isn't there is NotRegistered."
function get_model_admin(T::Type; site::AdminSite = Admin.site)
    ma = get(site.registry, admin_key(T), nothing)
    ma === nothing && throw(NotRegistered("The model $(nameof(T)) is not registered."))
    ma
end
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
ordering(ma::ModelAdmin, req) = ma.get_ordering === nothing ? ma.ordering : admin_ordering_terms(collect(ma.get_ordering(req)))
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
# (any permission on the model lists it, delete only too, as Django's has_module_permission and the index's perms)
visible_models(req) = (st = current_site(); [s for s in st.order if listed_on_index(req, st.registry[s])])
listed_on_index(req, ma) = can_view(req, ma) || can(req, ma, :add) || can(req, ma, :delete)

function base_context(req, title)
    st = current_site()
    Dict{String,Any}(
        "title" => title, "site_header" => something(st.site_header, settings.SITE_NAME * " administration"),
        "site_title" => something(st.site_title, settings.SITE_NAME * " site admin"),
        "models" => [opts(st.registry[s]) for s in visible_models(req)], "is_popup" => is_popup(req))
end

# --- views -------------------------------------------------------------------------------------

admin_url_for(e::LogEntry) = (e.content_type === nothing || e.object_id === nothing || e.action_flag == DELETION) ? nothing :
    (T = Juango.model_class(e.content_type); T === nothing || !is_registered(T; site = current_site()) ? nothing :
     reverse_url("admin:change"; app = modelmeta(T).app, model = model_name(T), id = admin_quote(e.object_id)))

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
    render(req, app === nothing ? site_template(st, :index, "admin/index.html") :
                site_template(st, :app_index, ["admin/$app/app_index.html", "admin/app_index.html"]), ctx)
end
"An app's page in the admin (`/admin/<app_label>/`): its models."
app_index(req::Request; app) = index(req; app = app)

function admin_login(req::Request)
    # (already logged in with access: on to where the login would go, as Django's)
    if req.method == "GET" && Juango.is_authenticated(req.user) && req.user.is_active && site_access(current_site(), req)
        return Juango.HttpResponseRedirect(Juango.safe_next(req, reverse_url("admin:index")))
    end
    LoginView(template = site_template(current_site(), :login, "admin/login.html"), redirect_url = reverse_url("admin:index"), require_staff = true)(req)
end
"Whether the request's user may use this admin site."
site_access(st, req) = st.has_permission === nothing ? req.user.is_staff : st.has_permission(req)

function admin_logout(req::Request)
    req.method == "POST" || return Juango.HttpResponseNotAllowed(["POST"])
    Juango.logout!(req)
    render(req, site_template(current_site(), :logout, "admin/logged_out.html"), base_context(req, gettext("Logged out")))
end

function header_label(ma::ModelAdmin, col)
    col isa Pair && return string(col.first)
    col isa Display && return something(col.description, "")
    col === :__str__ && return uppercasefirst(modelmeta(ma.model).verbose_name)
    rf = related_column_field(ma.model, col)
    rf === nothing || return label(rf)                          # ("parent__name": the field's label, as Django's)
    f = findfield(modelmeta(ma.model), Symbol(col))
    f === nothing ? uppercasefirst(replace(string(col), '_' => ' ')) : label(f)
end

"""
The field at the end of a list_display column through relations (`:parent__name`, Django 5.1's
related-field columns), or nothing for other columns.
"""
Base.@nospecializeinfer function related_column_field(@nospecialize(T::Type), col)
    col isa Union{Symbol,AbstractString} || return nothing
    parts = split(string(col), "__")
    length(parts) > 1 || return nothing
    M = T
    for (i, part) in enumerate(parts)
        f = findfield(modelmeta(M), Symbol(part))
        f === nothing && return nothing
        i == length(parts) && return f
        f.kind in (:fk, :o2o) || return nothing
        M = related_model(f)
    end
    nothing
end
"The value of a related-field column: through the relations, nothing where one is empty."
Base.@nospecializeinfer function related_column_value(@nospecialize(obj), col)
    v = obj
    for part in split(string(col), "__")
        v === nothing && return nothing
        v = getproperty(v, Symbol(part))
    end
    v
end

Base.@nospecializeinfer function raw_cell(ma::ModelAdmin, @nospecialize(obj), col)
    col isa Pair && return col.second(obj)
    col isa Display && return col.f(obj)
    col === :__str__ && return string(obj)
    rf = related_column_field(ma.model, col)
    if rf !== nothing
        v = related_column_value(obj, col)
        return rf.choices !== nothing && v !== nothing ? Juango.choice_label(Juango.field_choices(rf), v) : v
    end
    f = findfield(modelmeta(ma.model), Symbol(col))
    val = getproperty(obj, Symbol(col))
    f !== nothing && f.choices !== nothing && return Juango.choice_label(Juango.field_choices(f), val)
    val
end
Base.@nospecializeinfer function cell_value(ma::ModelAdmin, @nospecialize(obj), col)
    empty = col isa Display && col.empty_value !== nothing ? col.empty_value : option(ma, :empty_value_display, "-")
    # a model field's value as Django's display_for_field (its choices, kind and decimal places)
    f = col isa Union{Symbol,AbstractString} && col !== :__str__ ?
        something(related_column_field(ma.model, col), findfield(modelmeta(ma.model), Symbol(col)), Some(nothing)) : nothing
    if f isa Field && f.kind ∉ (:fk, :m2m)
        v = related_column_field(ma.model, col) === nothing ? getproperty(obj, Symbol(col)) : related_column_value(obj, col)
        return display_for_field(v, f, empty)
    end
    v = raw_cell(ma, obj, col)
    display_for_value(v, empty; boolean = col isa Display && col.boolean)
end

"The ORDER BY a list_display column sorts by (`nothing`: not sortable): a field's name, or a display's `ordering`."
function column_ordering(ma::ModelAdmin, col)
    sb = option(ma, :sortable_by)
    name = col isa Symbol ? col : col isa Display ? nothing : col isa AbstractString ? Symbol(col) : nothing
    sb !== nothing && !(name in sb) && !(col isa Display && col.ordering isa AbstractString && Symbol(lstrip(col.ordering, '-')) in sb) && return nothing
    col isa Display && return col.ordering
    (name === nothing || name === :__str__) && return nothing
    related_column_field(ma.model, name) === nothing || return string(name)      # (sorted by the lookup)
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
    out = Any[]
    for (i, desc) in spec
        o = column_ordering(ma, cols[i])
        if o isa AbstractString
            d = startswith(o, "-")
            push!(out, (desc != d ? "-" : "") * lstrip(o, '-'))
        elseif o isa Juango.OrderBy         # (reversed for a descending sort, as Django's reverse_ordering)
            push!(out, desc ? Juango.OrderBy(o.expr, !o.descending, o.nulls_first === nothing ? nothing : !o.nulls_first) : o)
        else                                # an expression: ascending, or descending
            push!(out, Juango.OrderBy(o, desc, nothing))
        end
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

"A boolean as the admin shows it: ✔, ✘, or ? for unknown (Django's _boolean_icon)."
boolean_icon(v) = v === true ? format_value(true) : v === false ? format_value(false) :
                  SafeString("<span class=\"unknown\" title=\"None\">?</span>")
"JSON as Python's json.dumps writes it (`\", \"` and `\": \"` between items), as Django's admin shows a JSONField."
py_json(v::AbstractDict) = "{" * join((Juango.JSON.json(string(k)) * ": " * py_json(x) for (k, x) in v), ", ") * "}"
py_json(v::Union{AbstractVector,Tuple}) = "[" * join((py_json(x) for x in v), ", ") * "]"
py_json(v) = Juango.JSON.json(v)

"""
    display_for_value(value, empty_value_display; boolean = false)

How the admin shows a value that isn't a model field's (Django's `admin.utils.display_for_value`): `empty_value_display`
for nothing, `DB_DEFAULT` or blank text (text is shown stripped), a list joined with commas, numbers in the
language's format, booleans as True/False (or as icons with `boolean`).
"""
function display_for_value(@nospecialize(v), empty; boolean::Bool = false)
    boolean && return boolean_icon(v === Juango.DB_DEFAULT ? nothing : v)
    (v === nothing || v === Juango.DB_DEFAULT) && return empty
    v isa Union{AbstractVector,Tuple,AbstractDict} && isempty(v) && return empty          # (Django's EMPTY_VALUES)
    v isa SafeString && return v
    v isa Bool && return v ? "True" : "False"
    v isa Union{Date,DateTime,Juango.TimeZones.ZonedDateTime} && return format_value(v)
    v isa Real && return Juango.number_format(v)
    v isa Union{AbstractVector,Tuple} && return join((Juango.display_string(x) for x in v), ", ")
    v isa AbstractString && return (t = strip(v); isempty(t) ? empty : String(t))
    v
end

"""
    display_for_field(value, field, empty_value_display)

How the admin shows a model field's value (Django's `admin.utils.display_for_field`): a choice's label (a choice
for nothing too), a boolean's icon (? for unknown), a decimal with the field's decimal places, a URL as a link
when it's a safe one, JSON as JSON, else as `display_for_value`.
"""
function display_for_field(@nospecialize(v), f::Field, empty)
    if f.choices !== nothing
        for c in Juango.field_choices(f)
            isequal(c.first, v) && return string(c.second)
        end
        (v === nothing || v === Juango.DB_DEFAULT) && return empty
        return string(v)
    end
    f.kind === :bool && return boolean_icon(v === Juango.DB_DEFAULT ? nothing : v)
    (v === nothing || v === Juango.DB_DEFAULT || (v isa AbstractString && isempty(v))) && return empty
    (v isa Union{AbstractVector,AbstractDict} && isempty(v)) && return empty          # (Django's empty_values)
    f.kind === :json && return py_json(v)
    f.kind === :decimal && f.decimal_places !== nothing && return Juango.number_format(v; decimals = f.decimal_places)
    if f.kind === :url
        u = string(v)
        return occursin(r"^(https?|ftps?)://"i, u) ? SafeString("<a href=\"$(Juango.escape_html(u))\">$(Juango.escape_html(u))</a>") : u
    end
    display_for_value(v, empty)
end

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
The change list's filters, as Django's `FieldListFilter`s, each a NamedTuple `(title, params,
choices, apply)`: the query parameters it reads, its choices (a label and the parameters it sets),
and `apply(qs, values)` with the values of its parameters that the request has. For a field (or a
path through relations, `"author__name"`) by its kind, with Django's parameter names:

* a boolean: `f__exact` = 1/0 (and `f__isnull` = True for a nullable one: "Unknown")
* choices: `f__exact`, one per choice (and `f__isnull` when a choice is `nothing`)
* a date or datetime: `f__gte` / `f__lt` for Today, Past 7 days, This month, This year (and
  `f__isnull` for No date / Has date when nullable)
* a foreign key, many-to-many or reverse relation: `f__id__exact`, one per related object in its
  admin's (or model's) order, and `f__isnull` = True for none; `:f => :related_only` lists only
  the objects in use
* any other field: `f`, one per value in use (and `f__isnull` = True for rows without one)
* `:f => :empty`: `f__isempty` = 1/0
* an `Admin.ListFilter`: its own parameter
"""
function list_filters(req::Request, ma::ModelAdmin)
    out = Any[]
    for entry in list_filter(ma, req)
        if entry isa ListFilter
            ch = Tuple{String,Dict{String,String}}[(string(l), Dict(entry.parameter => string(v))) for (v, l) in entry.lookups(req, ma)]
            push!(out, (title = entry.title, params = [entry.parameter], choices = ch,
                        apply = (qs, vals) -> something(entry.queryset(req, qs, vals[entry.parameter]), qs)))
            continue
        end
        name, mode = entry isa Pair ? (string(entry.first), Symbol(entry.second)) : (string(entry), :field)
        r = filter_field(ma.model, name)
        r === nothing && continue
        fl = field_list_filter(req, ma, name, r..., mode)
        fl === nothing || push!(out, fl)
    end
    out
end

"""
The field a list filter path ends at: `(field, kind, related, nullable, title)`, where `kind` is
`:field` for a model field, `:m2m` for a many-to-many field and `:reverse` for a reverse relation
(`related` is the model at the other end of a relation), or nothing for an unknown path.
"""
Base.@nospecializeinfer function filter_field(@nospecialize(T::Type), path::String)
    M = T
    parts = split(path, "__")
    for (i, part) in enumerate(parts)
        last = i == length(parts)
        f = findfield(modelmeta(M), Symbol(part))
        if f !== nothing
            last && return (f, :field, f.kind in (:fk, :o2o) ? related_model(f) : nothing, f.null, label(f))
            f.kind in (:fk, :o2o) || return nothing
            M = related_model(f)
            continue
        end
        m = findfirst_m2m(modelmeta(M), Symbol(part))
        if m !== nothing
            last && return (m, :m2m, related_model(m), true, label(m))
            M = related_model(m)
            continue
        end
        # the reverse side of a many-to-many field (books_contributed)
        rm = findfirst(r -> !r[3] && string(something(r[2].related_query_name, r[2].related_name,
                                                      Juango.default_related_name(r[2].model),
                                                      Symbol(lowercase(modelmeta(r[2].model).name)))) == part, Juango.m2m_relations(M))
        if rm !== nothing
            r = Juango.m2m_relations(M)[rm]
            last && return (r[2], :m2m, r[2].model, true, modelmeta(r[2].model).verbose_name_plural)
            M = r[2].model
            continue
        end
        rev = Juango.find_reverse(M, part)
        rev === nothing && return nothing
        last && return (rev[3], :reverse, rev[2], true, modelmeta(rev[2]).verbose_name)
        M = rev[2]
    end
    nothing
end

"A filter parameter's value as a value of the field (nothing when it isn't one)."
function filter_value(f, v::AbstractString)
    k = f.kind
    k in (:int, :bigint, :smallint, :posint, :posbigint, :possmallint, :fk, :o2o, :auto) && return tryparse(Int, v)
    k === :float && return tryparse(Float64, v)
    k === :decimal && return (try Juango.Decimal(v) catch; nothing end)
    k === :bool && return v in ("1", "True", "true") ? true : v in ("0", "False", "false") ? false : nothing
    k === :date && return tryparse(Date, v)
    k === :datetime && return something(tryparse(DateTime, replace(v, ' ' => 'T')), (d = tryparse(Date, v); d === nothing ? nothing : DateTime(d)), Some(nothing))
    k === :uuid && return tryparse(Juango.UUIDs.UUID, v)
    String(v)
end
isnull_value(v) = v in ("True", "true", "1") ? true : v in ("False", "false", "0") ? false : nothing

"A date filter's bound as a value of a date or datetime field (midnight in the current time zone)."
function date_bound(f, d::Date)
    f.kind === :date && return d
    dt = DateTime(d)
    settings.USE_TZ ? Juango.TimeZones.ZonedDateTime(dt, Juango.get_current_timezone()) : dt
end

struct BadFilterValue <: Exception
    param::String
end

Base.@nospecializeinfer function field_list_filter(req, ma::ModelAdmin, path::String, @nospecialize(f), kind::Symbol, @nospecialize(rel), nullable::Bool, title, mode::Symbol)
    empty_label = option(ma, :empty_value_display, "-")
    P(x) = path * "__" * x
    sym(k) = Symbol(k)
    choice(l, ps...) = (string(l), Dict{String,String}(string(k) => string(v) for (k, v) in ps))
    if mode === :empty                                  # Django's EmptyFieldListFilter
        key = P("isempty")
        text = kind === :field && (f.kind in Juango.STRING_KINDS || f.kind === :citext)
        empty_q = text ? Q(sym(P("isnull")) => true) | Q(sym(path) => "") : Q(sym(P("isnull")) => true)
        return (title = title, params = [key], choices = [choice(gettext("Empty"), key => "1"), choice(gettext("Not empty"), key => "0")],
                apply = (qs, vals) -> vals[key] == "1" ? filter(qs, empty_q) : vals[key] == "0" ? filter(qs, !empty_q) : throw(BadFilterValue(key)))
    end
    isnull_apply(qs, vals) = haskey(vals, P("isnull")) ?
        (b = isnull_value(vals[P("isnull")]); b === nothing ? throw(BadFilterValue(P("isnull"))) : filter(qs, Q(sym(P("isnull")) => b))) : qs
    if rel !== nothing                                  # RelatedFieldListFilter / RelatedOnlyFieldListFilter
        # (a key to another field than the id filters on it: department__code__exact, as Django's target_field)
        tf = kind === :field && f.kind === :fk ? Juango.fk_to_field(f) : nothing
        key = tf === nothing ? P("id__exact") : P(string(tf) * "__exact")
        objs = if mode === :related_only
            ids = unique(x for x in values_list(admin_queryset(ma, req), sym(P("id")); flat = true) if x !== nothing)
            collect(filter(objects(rel); id__in = collect(Any, ids)))
        else
            # (a foreign key's limit_choices_to leaves out what it couldn't point at, as Django's get_choices)
            lc = kind === :field ? limit_choices_of(f) : nothing
            lc isa Function && (lc = lc())
            collect(lc === nothing ? objects(rel) : Juango.complex_filter(objects(rel), lc))
        end
        relma = get(current_site().registry, admin_key(rel), nothing)
        ords = relma !== nothing ? ordering(relma, req) : Any[]
        isempty(ords) || (objs = collect(order_by(filter(objects(rel); id__in = Any[o.id for o in objs]), ords...)))
        ch = [choice(string(o), key => (tf === nothing ? Juango.pk_string(o) : string(Juango.target_value(f, o)))) for o in objs]
        nullable && push!(ch, choice(empty_label, P("isnull") => "True"))
        return (title = title, params = [key, P("isnull")], choices = ch,
                apply = (qs, vals) -> begin
                    if haskey(vals, key)
                        v = tf === nothing ? Juango.parse_pk(rel, vals[key]) : filter_value(Juango.getfield_meta(rel, tf), vals[key])
                        v === nothing && throw(BadFilterValue(key))
                        qs = filter(qs, Q(sym(key) => v))
                    end
                    isnull_apply(qs, vals)
                end)
    end
    if f.kind === :bool                                  # BooleanFieldListFilter
        key = P("exact")
        ch = f.choices !== nothing ? [choice(string(c.second), key => (c.first ? "1" : "0")) for c in Juango.field_choices(f) if c.first isa Bool] :
             [choice(gettext("Yes"), key => "1"), choice(gettext("No"), key => "0")]
        f.null && push!(ch, choice(gettext("Unknown"), P("isnull") => "True"))
        return (title = title, params = [key, P("isnull")], choices = ch,
                apply = (qs, vals) -> begin
                    if haskey(vals, key)
                        b = filter_value(f, vals[key])
                        b === nothing && throw(BadFilterValue(key))
                        qs = filter(qs, Q(sym(path) => b))
                    end
                    isnull_apply(qs, vals)
                end)
    end
    if f.choices !== nothing                             # ChoicesFieldListFilter
        key = P("exact")
        ch = Tuple{String,Dict{String,String}}[]
        none = nothing
        for c in Juango.field_choices(f)
            c.first === nothing ? (none = string(c.second)) : push!(ch, choice(c.second, key => c.first))
        end
        none === nothing || push!(ch, choice(none, P("isnull") => "True"))
        return (title = title, params = [key, P("isnull")], choices = ch,
                apply = (qs, vals) -> begin
                    if haskey(vals, key)
                        v = filter_value(f, vals[key])
                        v === nothing && throw(BadFilterValue(key))
                        qs = filter(qs, Q(sym(path) => v))
                    end
                    isnull_apply(qs, vals)
                end)
    end
    if f.kind in (:date, :datetime)                      # DateFieldListFilter
        gte, lt = P("gte"), P("lt")
        today = Juango.localdate()
        month1 = Date(year(today), month(today), 1)
        bound(d) = f.kind === :date ? string(d) : string(d)     # (the date; midnight in the current time zone)
        ch = [choice(gettext("Today"), gte => bound(today), lt => bound(today + Day(1))),
              choice(gettext("Past 7 days"), gte => bound(today - Day(7)), lt => bound(today + Day(1))),
              choice(gettext("This month"), gte => bound(month1), lt => bound(month1 + Month(1))),
              choice(gettext("This year"), gte => bound(Date(year(today), 1, 1)), lt => bound(Date(year(today) + 1, 1, 1)))]
        if f.null
            push!(ch, choice(gettext("No date"), P("isnull") => "True"), choice(gettext("Has date"), P("isnull") => "False"))
        end
        return (title = title, params = [gte, lt, P("isnull")], choices = ch,
                apply = (qs, vals) -> begin
                    for k in (gte, lt)
                        haskey(vals, k) || continue
                        d = tryparse(Date, first(vals[k], 10))
                        d === nothing && throw(BadFilterValue(k))
                        qs = filter(qs, Q(sym(k) => date_bound(f, d)))
                    end
                    isnull_apply(qs, vals)
                end)
    end
    # AllValuesFieldListFilter: the values in use
    vals_ = collect(values_list(order_by(distinct(values_list(admin_queryset(ma, req), sym(path))), path), sym(path); flat = true))
    has_null = any(isnothing, vals_)
    ch = [choice(string(v), path => string(v)) for v in unique(vals_) if v !== nothing]
    has_null && push!(ch, choice(empty_label, P("isnull") => "True"))
    (title = title, params = [path, P("isnull")], choices = ch,
     apply = (qs, vals) -> begin
         if haskey(vals, path)
             v = filter_value(f, vals[path])
             v === nothing && throw(BadFilterValue(path))
             qs = filter(qs, Q(sym(path) => v))
         end
         isnull_apply(qs, vals)
     end)
end

"The values a request has for a filter's parameters."
filter_values(req::Request, fl) = Dict{String,String}(p => req.GET[p] for p in fl.params if haskey(req.GET, p) && !isempty(req.GET[p]))

"""
The filter sidebar. With `base` (the searched queryset) and facets on, each choice shows how many
rows it would leave, counting the search and the other filters (Django 5's facets).
"""
function filter_specs(req::Request, ma::ModelAdmin, filters = list_filters(req, ma); base = nothing, facets::Bool = false)
    specs = Any[]
    for fl in filters
        cur = filter_values(req, fl)
        others = nothing
        if facets && base !== nothing                 # the queryset with every other filter applied
            others = base
            for f2 in filters
                f2 === fl && continue
                v2 = filter_values(req, f2)
                isempty(v2) || (others = try f2.apply(others, v2) catch e; e isa BadFilterValue ? others : rethrow() end)
            end
        end
        clear = [p => nothing for p in fl.params]
        choices = Any[Dict{String,Any}("label" => others === nothing ? gettext("All") : string(gettext("All"), " (", count(others), ")"),
                                       "url" => query_with(req, clear...), "selected" => isempty(cur))]
        for (l, ps) in fl.choices
            n = others === nothing ? nothing : (try count(fl.apply(others, ps)) catch e; e isa BadFilterValue ? 0 : rethrow() end)
            push!(choices, Dict{String,Any}("label" => n === nothing ? l : string(l, " (", n, ")"),
                                            "url" => query_with(req, clear..., ps...), "selected" => !isempty(cur) && cur == ps))
        end
        push!(specs, Dict{String,Any}("title" => fl.title, "choices" => choices))
    end
    specs
end

"""
One step of a lookup path from model `M`: `(is_relation, next_model, is_key, to_field, parent_link)`,
or `nothing` when `part` names no field or relation (a lookup such as `exact`, or a custom filter's parameter).
"""
Base.@nospecializeinfer function lookup_step(@nospecialize(M::Type), part::AbstractString)
    meta = modelmeta(M)
    if part in ("id", "pk") && !Juango.natural_pk(M)
        return (false, nothing, true, nothing, false)          # the automatic key (Django's auto_field)
    end
    f = part == "pk" ? Juango.pk_fields(M)[1] : findfield(meta, Symbol(part))
    if f !== nothing
        rel = f.kind in (:fk, :o2o)
        return (rel, rel ? related_model(f) : nothing, f.primary_key, rel ? f.to_field : nothing, false)
    end
    P = Juango.table_parent(M)
    P !== nothing && Symbol(part) === Juango.parent_accessor(M) && return (true, P, false, nothing, true)
    m = Juango.find_m2m_query(M, part)
    m !== nothing && return (true, m[3] ? related_model(m[2]) : m[2].model, false, nothing, false)
    r = Juango.find_reverse(M, part)
    r !== nothing && return (true, r[2], false, nothing, false)
    nothing
end

"Whether every name in `lookup` after a relation is a field, relation or lookup of the related model."
Base.@nospecializeinfer function lookup_path_ok(@nospecialize(T::Type), lookup::AbstractString)
    M = T
    for (i, p) in enumerate(split(lookup, "__"))
        st = lookup_step(M, p)
        st === nothing && return i == 1 || is_lookup_name(p)
        st[1] || return true
        M = st[2]
    end
    true
end

"""
    Admin.lookup_allowed(ma, lookup, value, req) -> Bool

Whether the change list may filter by the query parameter `lookup` (Django's
`ModelAdmin.lookup_allowed`): a lookup on the model's own fields, or through a single relation
to the related object's key (`?author__id__exact=1`, `?author__isnull=True`), always; one that
goes further through relations only when a list filter (or the date hierarchy) names that path,
so `list_filter = ["author__name"]` doesn't open `?author__password__startswith=`. Others are
refused with 400. Override it with `register!(...; lookup_allowed = (lookup, value, req) -> ...)`.
"""
Base.@nospecializeinfer function lookup_allowed(ma::ModelAdmin, lookup::AbstractString, @nospecialize(value), req)
    h = option(ma, :lookup_allowed)
    h === nothing || return h(lookup, value, req) === true
    M = ma.model
    # a raw id widget's lookup popup filters by its foreign key's limit_choices_to (Django's related_fkey_lookups)
    any(p -> p == (lookup => string(value)), related_fkey_lookups(M)) && return true
    relation_parts = String[]
    prev = nothing
    part = ""
    for p in split(lookup, "__")
        part = String(p)
        st = lookup_step(M, part)
        st === nothing && break                                # a lookup, or a name that isn't a field
        is_rel, next, is_key, _, parent_link = st
        # (as Django's: the first name, then a relation or a field that isn't the related model's key, its to_field or a parent link)
        if prev === nothing || (prev[1] && !parent_link && !(is_key && !is_rel) && Symbol(part) !== prev[4] && (is_rel || !is_key))
            push!(relation_parts, part)
        end
        is_rel || break
        prev = st
        M = next
    end
    length(relation_parts) <= 1 && return true
    valid = Set{String}()
    ma.date_hierarchy === nothing || push!(valid, string(ma.date_hierarchy))
    for item in list_filter(ma, req)
        push!(valid, item isa ListFilter ? item.parameter : item isa Pair ? string(item.first) : string(item))
    end
    !isdisjoint(valid, (join(relation_parts, "__"), join(vcat(relation_parts, part), "__")))
end

"The `limit_choices_to` query parameters of the relations to `T` (Django's Options.related_fkey_lookups)."
Base.@nospecializeinfer function related_fkey_lookups(@nospecialize(T))
    out = Pair{String,String}[]
    for M in Juango.MODEL_LIST, f in vcat(Juango.all_fields(M), Juango.many_to_many(M))
        f.kind in (:fk, :m2m) && related_model(f) === T && (l = limit_choices_of(f)) !== nothing || continue
        append!(out, url_params_from_lookup_dict(l))
    end
    out
end

# Query parameters of the change list itself (Django's IGNORED_PARAMS and the date hierarchy's)
const CHANGELIST_PARAMS = Set(["q", "o", "page", "p", "all", "e", "_facets", "_popup", "_to_field", "_changelist_filters", "action",
                               "_selected_action", "select_across", "index"])

"""
Query parameters no filter used, applied as lookups (Django's ChangeList, which bookmarks
`?name__startswith=A`) when `lookup_allowed` allows them. Others are refused (400, Django's DisallowedModelAdminLookup); a value
that doesn't fit its field is a `BadFilterValue` (the page drops the filters, `?e=1`).
"""
Base.@nospecializeinfer function lookup_params(req::Request, ma::ModelAdmin, @nospecialize(qs), used::Set{String})
    T = ma.model
    dh = ma.date_hierarchy === nothing ? Set{String}() : Set(string(ma.date_hierarchy, "__", x) for x in ("year", "month", "day"))
    dups = false
    for k in collect(keys(req.GET.data))
        (k in used || k in CHANGELIST_PARAMS || k in dh || startswith(k, "_")) && continue
        v = req.GET[k]
        parts = split(k, "__")
        f = findfield(modelmeta(T), Symbol(parts[1]))
        if f === nothing && !(parts[1] in ("id", "pk"))       # not a field nor a relation: a bad lookup (?e=1)
            filter_field(T, String(parts[1])) === nothing && throw(BadFilterValue(k))
        end
        if !lookup_allowed(ma, k, v, req)          # (logged as Django's SuspiciousOperation DisallowedModelAdminLookup)
            Juango.log!("juango.security.DisallowedModelAdminLookup", :error, "Filtering by $k not allowed"; request = req)
            throw(Juango.BadRequest("Filtering by $k not allowed"))
        end
        lookup_path_ok(T, k) || throw(BadFilterValue(k))        # (a name past a relation that isn't a field there: ?e=1)
        lk = String(parts[end])
        # (converted for the model's own field: f, or f__<lookup> for a lookup that compares values)
        own = f !== nothing && (length(parts) == 1 || (length(parts) == 2 && is_lookup_name(lk) &&
                                                       lk in ("exact", "gt", "gte", "lt", "lte", "ne")))
        val = lk == "isnull" ? isnull_value(v) : lk == "in" ? split(v, ",") : own ? filter_value(f, v) : v
        val === nothing && throw(BadFilterValue(k))
        qs = filter(qs, Q(Symbol(k) => val))
        dups |= search_spawns_duplicates(T, k)
    end
    qs, dups
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
    dates = [Date(x isa Juango.TimeZones.ZonedDateTime ? Juango.localtime(x) : x) for x in values_list(qs, f; flat = true) if x !== nothing]
    key(k) = "$(f)__$k"
    # (with nothing chosen, it starts at the months of a single year or the days of a single month, as Django's)
    ly, lm = y, m
    if y === nothing && m === nothing && d === nothing && !isempty(dates)
        lo, hi = extrema(dates)
        if year(lo) == year(hi)
            ly = year(lo)
            month(lo) == month(hi) && (lm = month(lo))
        end
    end
    links, back = Any[], nothing
    if ly === nothing
        links = [Dict("label" => string(v), "url" => date_query(req, key("year") => v)) for v in sort(unique(year.(dates)))]
    elseif lm === nothing
        y === nothing || (back = Dict("label" => "‹ " * gettext("All dates"), "url" => date_query(req, key("year") => nothing)))
        links = [Dict("label" => "$(MONTHS[v]) $ly", "url" => date_query(req, key("year") => ly, key("month") => v))
                 for v in sort(unique(month.(dates)))]
    else
        m === nothing || (back = Dict("label" => "‹ $ly", "url" => date_query(req, key("month") => nothing, key("day") => nothing)))
        d === nothing && (links = [Dict("label" => "$(MONTHS[lm]) $v", "url" => date_query(req, key("year") => ly, key("month") => lm, key("day") => v))
                                   for v in sort(unique(day.(dates)))])
    end
    qs, Dict{String,Any}("links" => links, "back" => back)
end

"A query string for a date hierarchy link: the request's parameters with these changed, sorted (as Django's get_query_string)."
function date_query(req::Request, changes::Pair...)
    q = copy(req.GET)
    delete!(q.data, "page")
    for (k, v) in changes
        v === nothing ? delete!(q.data, string(k)) : (q.data[string(k)] = [string(v)])
    end
    parts = String[]
    for k in sort(collect(keys(q.data))), v in q.data[k]
        push!(parts, Juango.urlquote(k) * "=" * Juango.urlquote(v))
    end
    "?" * join(parts, "&")
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

# --- search (Django's ModelAdmin.get_search_results) ----------------------------------------------

"""
    search_results(T, qs, search_fields, term) -> (queryset, may_have_duplicates)

The admin's search, as Django's: the term is split into words (a quoted phrase is one), and each
word must match at least one of the search fields. A field is searched with `icontains`, or
`"^name"` with `istartswith`, `"=name"` with `iexact`, `"@name"` with `search`, and a field that
ends in a lookup (`"age__exact"`, `"author__name__startswith"`) with that lookup; an exact lookup
on a field that isn't text skips words that aren't a value of it ("abc" for a number). The
second value says whether the search crosses a many-to-many or reverse relation, which can
repeat rows (the caller makes the queryset distinct).
"""
Base.@nospecializeinfer function search_results(@nospecialize(T::Type), qs, search_fields, term)
    (isempty(search_fields) || isempty(term)) && return qs, false
    lookups = [search_lookup(T, string(f)) for f in search_fields]
    terms = Q[]
    for bit in search_words(term)
        if length(bit) >= 2 && bit[1] in ('"', '\'') && bit[end] == bit[1]
            bit = replace(bit[2:end-1], "\\" * bit[1] => string(bit[1]), "\\\\" => "\\")
        end
        qs_bit = Q[]
        for (lk, vf) in lookups
            v = vf === nothing ? bit : search_value(vf, bit)
            v === nothing && continue                  # (not a value of that field)
            push!(qs_bit, Q(Symbol(lk) => v))
        end
        push!(terms, isempty(qs_bit) ? Q(id__in = Any[]) : reduce(|, qs_bit))
    end
    qs = isempty(terms) ? qs : filter(qs, reduce(&, terms))
    qs, any(((lk, _),) -> search_spawns_duplicates(T, lk), lookups)
end

"A search term's words, as Django's smart_split: a quoted phrase (with \\-escaped quotes) is one word, with what touches it."
const SMART_SPLIT_RE = r"""((?:[^\s'"]*(?:(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')[^\s'"]*)+)|\S+)"""
search_words(term) = String[m.match for m in eachmatch(SMART_SPLIT_RE, term)]

is_lookup_name(s) = s in Juango.LOOKUPS || haskey(Juango.CUSTOM_LOOKUPS, s)

"A search field as a lookup, and the field a word must be a value of (exact lookups on non-text fields)."
Base.@nospecializeinfer function search_lookup(@nospecialize(T::Type), f::String)
    startswith(f, "^") && return f[2:end] * "__istartswith", nothing
    startswith(f, "=") && return f[2:end] * "__iexact", nothing
    startswith(f, "@") && return f[2:end] * "__search", nothing
    meta = modelmeta(T)
    prev = nothing
    for part in split(f, "__")
        fld = part in ("pk", "id") ? nothing : findfield(meta, Symbol(part))
        fld === nothing && (fld = findfirst_m2m(meta, Symbol(part)))
        part in ("pk", "id") && (fld = (kind = :auto, null = false, name = :id))     # the automatic key
        if fld === nothing
            if prev !== nothing && is_lookup_name(part)
                part == "exact" && !(prev.kind in Juango.STRING_KINDS || prev.kind === :citext) && return f, prev
                return f, nothing
            end
            break
        end
        prev = fld
        fld.kind in (:fk, :o2o, :m2m) && (meta = modelmeta(related_model(fld)))
    end
    f * "__icontains", nothing
end
findfirst_m2m(meta, name) = (i = findfirst(x -> x.name === name, meta.m2m); i === nothing ? nothing : meta.m2m[i])

"A search word as a value of a field, or nothing when it isn't one (strict booleans, as Django's)."
function search_value(f, bit::AbstractString)
    k = f.kind
    k in (:int, :bigint, :smallint, :posint, :posbigint, :possmallint, :fk, :o2o, :auto) && return tryparse(Int, bit)
    k === :float && return tryparse(Float64, bit)
    k === :decimal && return (try Juango.Decimal(bit) catch; nothing end)
    if k === :bool
        bit in ("True", "true", "1") && return true
        bit in ("False", "false", "0") && return false
        f.null && bit in ("None", "null") && return nothing    # (as no value: skipped)
        return nothing
    end
    k === :date && return tryparse(Date, bit)
    k === :uuid && return tryparse(Juango.UUIDs.UUID, bit)
    bit
end

"Whether a lookup path crosses a many-to-many or reverse relation (Django's lookup_spawns_duplicates)."
Base.@nospecializeinfer function search_spawns_duplicates(@nospecialize(T::Type), lookup::AbstractString)
    M = T
    for part in split(lookup, "__")
        part in ("pk", "id") && return false
        f = findfield(modelmeta(M), Symbol(part))
        if f === nothing
            # a many-to-many relation (either side) or a reverse foreign key can repeat rows
            any(r -> string(r[1]) == part || (!r[3] && string(something(r[2].related_query_name, r[2].related_name,
                                                                         Juango.default_related_name(r[2].model),
                                                                         Symbol(lowercase(modelmeta(r[2].model).name)))) == part),
                Juango.m2m_relations(M)) && return true
            rev = Juango.find_reverse(M, part)
            rev === nothing && return false            # a lookup, or a custom filter's parameter
            rev[3].one_to_one || return true
            M = rev[2]
            continue
        end
        f.kind in (:fk, :o2o) || return false
        M = related_model(f)
    end
    false
end

function changelist(req::Request; app, model)
    ma = get_admin(app, model)
    T = ma.model
    meta = modelmeta(T)
    require_perm(req, ma, :view, :change)
    popup = is_popup(req)
    to_field = check_to_field(ma, req)
    back = req.path * (isempty(req.query_string) ? "" : "?" * req.query_string)
    if !popup && req.method == "POST" && haskey(req.POST, "action") && !haskey(req.POST, "_save")
        r = run_action(req, ma)
        r isa HttpResponse && return r
        return Juango.HttpResponseRedirect(back)
    end
    qs = admin_queryset(ma, req)
    q = strip(get(req.GET, "q", ""))
    sfields = search_fields(ma, req)
    # (a pluggable search, Django's get_search_results: (req, queryset, term) -> (queryset, may_have_duplicates);
    # Admin.search_results(T, qs, search_fields, term) is the default)
    gsr = option(ma, :get_search_results)
    qs, dups = gsr === nothing ? search_results(T, qs, sfields, q) : gsr(req, qs, q)
    searched = qs
    filters = list_filters(req, ma)
    used = Set{String}()
    try
        for fl in filters
            vals = filter_values(req, fl)
            union!(used, fl.params)
            isempty(vals) && continue
            qs = fl.apply(qs, vals)
            any(p -> search_spawns_duplicates(T, p), keys(vals)) && (dups = true)   # (across a many-to-many relation)
        end
        # other parameters are lookups, as Django's: on the model's own fields, or through a relation
        # a list filter names; anything else is refused
        qs, extra_dups = lookup_params(req, ma, qs, used)
        dups |= extra_dups
    catch e
        e isa BadFilterValue || rethrow()
        haskey(req.GET, "e") || return Juango.HttpResponseRedirect(req.path * "?e=1" * (popup ? "&_popup=1" : "") *
                                                                    (to_field === nothing ? "" : "&_to_field=" * Juango.urlquote(to_field)))
        qs = admin_queryset(ma, req)
    end
    haskey(req.GET, "e") && message!(req, :error, gettext("The filters in the address weren't valid, so they were left out."))
    dups && (qs = distinct(qs))
    qs, drill = date_drilldown(req, ma, qs)
    # As Django's ChangeList: the admin's ordering, else the model's Meta.ordering given explicitly (a queryset with
    # an aggregate annotate leaves Meta.ordering out), then the primary key, so pages are in a total order
    cols = list_display(ma, req)
    ords = Any[o for o in ordering(ma, req)]
    isempty(ords) && append!(ords, meta.ordering)
    # (and the admin queryset's own ordering, get_queryset's order_by, after them, as Django's)
    append!(ords, Any[o for o in qs.order if !(o in ords)])
    spec = sort_spec(req, ma, cols)                    # clicked column headers come first
    if !isempty(spec)
        chosen = spec_ordering(ma, cols, spec)
        names = [lstrip(c, '-') for c in chosen if c isa AbstractString]
        ords = vcat(Any[chosen...], Any[o for o in ords if !(o isa AbstractString && lstrip(o, '-') in names)])
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
    editable = !popup && !isempty(ma.list_editable) && can(req, ma, :change)     # (a popup picks a row: no editing, no actions)
    fs = nothing
    if editable
        FS = modelformset_factory(T; fields = ma.list_editable, extra = 0, edit_only = true)
        fs = FS(req.method == "POST" ? req.POST : nothing; queryset = objs)
        if req.method == "POST" && haskey(req.POST, "_save")
            if is_valid(fs)
                sm, sr = option(ma, :save_model), option(ma, :save_related)
                for (i, f) in enumerate(fs.forms)
                    ch = changed_fields(f)
                    isempty(ch) && continue
                    # (a row that isn't one of the listed objects would add one: refused, as Django's)
                    f.instance === nothing && throw(Juango.BadRequest("list_editable does not allow adding."))
                    can(req, ma, :change, f.instance) || continue        # (an object the user may not change, per object)
                    # (the admin's save_model and save_related hooks, as Django's changelist_view)
                    if sm === nothing && sr === nothing
                        save!(f)
                    else
                        o = save!(f; commit = false)
                        sm === nothing ? save!(o) : sm(req, o, f, true)
                        sr === nothing ? Juango.save_m2m!(f) : sr(req, f, Any[], true)
                    end
                    log_action!(req.user, f.instance, CHANGE, "Changed " * changed_labels(f, ch) * ".")
                end
                n = count(f -> !isempty(changed_fields(f)) && f.instance !== nothing && can(req, ma, :change, f.instance), fs.forms)
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
    # (each object's form: by its instance, as a posted form set may have fewer rows than the page)
    form_of(o) = forms === nothing ? nothing :
        (j = findfirst(f -> f.instance !== nothing && Juango.pk_string(f.instance) == Juango.pk_string(o), forms); j === nothing ? nothing : forms[j])
    for (k, o) in enumerate(objs)
        cells = Any[]
        fo = form_of(o)
        for (i, c) in enumerate(cols)
            if fo !== nothing && c isa Symbol && c in ma.list_editable && can(req, ma, :change, o)
                bf = fo[c]
                errs = get(fo.errors, c, String[])
                push!(cells, (value = SafeString((isempty(errs) ? "" : Juango.errors_html(errs)) * Juango.widget_html(bf)), link = false))
            else
                push!(cells, (value = cell_value(ma, o, c), link = linked(i, c)))
            end
        end
        hidden = fo === nothing ? "" : hidden_id_html(fo)
        pk = Juango.pk_string(o)
        # a NamedTuple, not a Dict: the template reads row.id, row.cells ..., and this is per row
        # (a row's errors that aren't a field's, unique_together: on a row of their own above it, as Django's)
        nonfield = fo === nothing ? "" : Juango.errors_html(get(fo.errors, :__all__, String[]); class = "nonfield")
        push!(rows, (id = pk, cells = cells, hidden = SafeString(hidden), nonfield = SafeString(nonfield), ncols = length(cells) + 1,
                     url = reverse_url("admin:change"; app = ma.app, model = ma.slug, id = admin_quote(pk)) * back_q,
                     popup_value = popup ? popup_value(o, to_field) : nothing))
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
        "actions" => popup ? Any[] : [Dict("name" => a.name, "description" => a.description) for a in ma.actions if can(req, ma, a.permission)],
        "to_field" => to_field, "add_query" => popup ? "?" * encode_params(vcat(["_popup" => "1"], to_field === nothing ? Pair{String,String}[] : ["_to_field" => to_field])) : "",
        "list_editable" => fs !== nothing, "management_form" => fs === nothing ? "" : management_form(fs),
        "date_hierarchy" => drill,
        "prev_url" => pg.has_previous ? query_with(req, "page" => pg.previous_page_number) : nothing,
        "next_url" => pg.has_next ? query_with(req, "page" => pg.next_page_number) : nothing,
        "show_all_url" => !show_all && p.num_pages > 1 && p.count <= max_all ? query_with(req, "all" => "") : nothing))
    render(req, "admin/change_list.html", ctx)
end

# --- change form ---------------------------------------------------------------------------------------

"The change form's fieldsets (Django's `get_fieldsets`): the `get_fieldsets` hook's, else `fieldsets` (empty: none declared)."
Base.@nospecializeinfer admin_fieldsets(ma::ModelAdmin, req = nothing, @nospecialize(obj = nothing)) =
    (h = option(ma, :get_fieldsets); h === nothing ? ma.fieldsets :
     Pair{String,Vector{Symbol}}[string(something(k, "")) => Symbol.(collect(v)) for (k, v) in h(req, obj)])

"""
The change form's editable fields, as Django's `get_form`: the fieldsets' fields when there are
fieldsets (so a field they leave out isn't a hidden required one), else `get_fields`, `fields`
or the model's editable fields; without the excluded, read-only and password ones.
"""
Base.@nospecializeinfer function admin_fields(ma::ModelAdmin, req = nothing, @nospecialize(obj = nothing))
    fsets = admin_fieldsets(ma, req, obj)
    fs = !isempty(fsets) ? unique!(reduce(vcat, (last(x) for x in fsets); init = Symbol[])) :
         ma.get_fields !== nothing ? Symbol.(collect(ma.get_fields(req, obj))) : ma.fields !== nothing ? ma.fields :
         [f.name for f in vcat(Juango.all_fields(ma.model), modelmeta(ma.model).m2m) if f.editable]
    ro = req === nothing ? ma.readonly_fields : readonly_fields(ma, req, obj)
    ex = admin_exclude(ma, req, obj)
    [f for f in fs if !(f in ro) && !(f in ex) && !(f in ma.password_fields)]
end

Base.@nospecializeinfer admin_exclude(ma::ModelAdmin, req, @nospecialize(obj)) =
    (h = option(ma, :get_exclude); h === nothing || req === nothing ? ma.exclude : Symbol.(collect(h(req, obj))))

"""
A read-only value as Django's AdminReadonlyField.contents: a related object linked to its change page when its model
is in the admin (a foreign key, a reverse one-to-one), many-to-many objects listed, a choice's label (a choice of
nothing too), else the value escaped with its line breaks as <br>.
"""
Base.@nospecializeinfer function readonly_value(@nospecialize(obj), f::Field)
    obj === nothing && return "-"
    v = getproperty(obj, f.name)
    f.kind === :m2m && return join(string.(collect(v)), ", ")
    if f.choices !== nothing
        ch = Juango.field_choices(f)
        i = findfirst(c -> isequal(c.first, v), ch)
        i === nothing || return string(ch[i].second)          # (a choice of nothing too: "No opinion")
        return v === nothing ? "-" : string(Juango.choice_label(ch, v))
    end
    readonly_display(v)
end
"A value read-only: a model object linked (if its model is in the admin), else escaped with <br> for line breaks."
function readonly_display(@nospecialize(v))
    v isa Model && return admin_link(v)
    s = format_value(v)
    s isa SafeString && return s
    SafeString(replace(escape_html(string(s)), r"\r\n|\r|\n" => "<br>"))
end
"An object linked to its change page when its model is registered here (Django's get_admin_url), else its name."
Base.@nospecializeinfer function admin_link(@nospecialize(o))
    ra = get(current_site().registry, admin_key(typeof(o)), nothing)
    ra === nothing && return escape_html(string(o))
    SafeString("<a href=\"" * escape_html(reverse_url("admin:change"; app = ra.app, model = ra.slug, id = admin_pk(o))) * "\">" *
               escape_html(string(o)) * "</a>")
end
Base.@nospecializeinfer readonly_row(ma, @nospecialize(obj), name) = (f = findfield(modelmeta(ma.model), name);
    f === nothing && (f = findfirst(x -> x.name === name, modelmeta(ma.model).m2m) |> i -> i === nothing ? nothing : modelmeta(ma.model).m2m[i]);
    Dict{String,Any}("readonly" => true, "label" => f === nothing ? uppercasefirst(replace(string(name), '_' => ' ')) : label(f),
                     "value" => f === nothing ? readonly_display(obj === nothing ? nothing : readonly_attr(obj, name)) : readonly_value(obj, f)))
"An attribute shown read-only: a reverse one-to-one with no object is nothing, not an error."
readonly_attr(@nospecialize(obj), name) = try getproperty(obj, name) catch e; e isa Juango.DoesNotExist ? nothing : rethrow() end

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

Base.@nospecializeinfer function inline_formsets(ma::ModelAdmin, req, @nospecialize(obj), data; parent_editable::Bool = true,
                                                 save_as_new::Bool = false)
    out = Any[]
    prefixes = Dict{String,Int}()
    h = option(ma, :get_inlines)
    for ia in (h === nothing ? ma.inlines : collect(InlineAdmin, h(req, obj)))
        M = ia.model
        (inline_can(req, ia, :view, obj; parent = ma.model) || inline_can(req, ia, :add, obj; parent = ma.model)) || continue
        # (a parent the user may only view shows its inlines read-only too)
        can_change = parent_editable && inline_can(req, ia, :change, obj; parent = ma.model)
        can_add = parent_editable && inline_can(req, ia, :add, obj; parent = ma.model)
        ro = inline_readonly(ia, req, obj)
        ex = inline_exclude(ia, req, obj)
        editable(f) = !(f in ro) && !(f in ex)
        fields = ia.fields === nothing ? nothing : filter(editable, ia.fields)
        gen = inline_option(ia, :generic)
        factory(; kw...) = gen === nothing ? inlineformset_factory(ma.model, M; fk = ia.fk, kw...) :
                                           Juango.generic_inlineformset_factory(M; ct_field = gen[1], fk_field = gen[2], kw...)
        FS = factory(; fields = fields, exclude = fields === nothing ? vcat(ex, ro) : Symbol[],
                                   extra = can_add ? inline_num(ia, :extra, ia.extra, req, obj) : 0,
                                   min_num = can_add ? inline_num(ia, :min_num, inline_option(ia, :min_num, 0), req, obj) : 0,
                                   can_delete = can_change && ia.can_delete && inline_can(req, ia, :delete, obj; parent = ma.model),
                                   # (without add permission no new objects, as Django's: max_num 0, and posted ones ignored)
                                   max_num = can_add ? inline_num(ia, :max_num, ia.max_num, req, obj) : 0, edit_only = !can_add)
        qs = inline_queryset(ia, req)
        # (two inlines with the same prefix, the same relation: the second is prefix-2, as Django's _create_formsets)
        p0 = FS(nothing; instance = nothing).prefix
        prefixes[p0] = get(prefixes, p0, 0) + 1
        pfx = prefixes[p0] == 1 ? p0 : "$p0-$(prefixes[p0])"
        if can_change
            fs = isempty(ia.ordering) ? FS(data; instance = obj, prefix = pfx, save_as_new) : FS(data; instance = obj, queryset = qs, prefix = pfx, save_as_new)
            push!(out, (ia, fs, (readonly = ro, existing = Any[], shown = Symbol[], can_change = true, can_add = can_add)))
        else
            # (no change permission: the objects are shown as values, outside the formset, so a POST can't change
            # them; the formset has just the new ones the user may add, as Django's)
            fs = FS(data; instance = obj, queryset = Juango.none(qs), prefix = pfx)
            existing = obj === nothing ? Any[] : gen !== nothing ? collect(filter(qs, Q(gen[1] => Juango.get_for_model(typeof(obj))), Q(gen[2] => obj.pk))) :
                       collect(filter(qs, Q(attname(fs.fk) => Juango.target_value(fs.fk, obj))))
            push!(out, (ia, fs, (readonly = ro, existing = existing, shown = inline_shown_fields(ia, fs, ex), can_change = false, can_add = can_add)))
        end
    end
    out
end

"The fields a view-only inline shows: its `fields`, else the model's editable ones but the key to the parent."
Base.@nospecializeinfer function inline_shown_fields(ia::InlineAdmin, fs, ex)
    ia.fields !== nothing && return filter(!in(ex), ia.fields)
    skip = fs.fk !== nothing ? (fs.fk.name,) : something(inline_option(ia, :generic), ())
    [f.name for f in Juango.all_fields(ia.model) if f.editable && !(f.name in skip) && !(f.name in ex)]
end

function inline_context(req, ia::InlineAdmin, fs, info = (readonly = Symbol[], existing = Any[], shown = Symbol[], can_change = true, can_add = true))
    forms = Juango.build_forms!(fs)
    ef = Juango.empty_form(fs)
    names = [f.name for f in ef.fields if f.name !== :id]
    ro = info.readonly
    rofield(n) = (fld = findfield(modelmeta(ia.model), n); fld === nothing ? uppercasefirst(replace(string(n), '_' => ' ')) : label(fld))
    rovalue(o, n) = (fld = findfield(modelmeta(ia.model), n); fld === nothing ? readonly_display(o === nothing ? nothing : readonly_attr(o, n)) : readonly_value(o, fld))
    vn, vnp = inline_verbose_names(ia)
    sub = get(current_site().registry, admin_key(ia.model), nothing)
    link(o) = (inline_option(ia, :show_change_link, false) === true && sub !== nothing && o !== nothing && can_view(req, sub, o)) ?
              (try reverse_url("admin:change"; app = sub.app, model = sub.slug, id = admin_pk(o)) catch; nothing end) : nothing
    headers = Any[n === :DELETE ? "Delete?" : label(only(filter(f -> f.name === n, ef.fields))) for n in names if n !== :DELETE]
    append!(headers, [rofield(n) for n in ro])
    :DELETE in names && push!(headers, "Delete?")
    Dict{String,Any}("style" => string(ia.style), "verbose_name_plural" => vnp, "verbose_name" => vn,
                     "classes" => join(string.(inline_option(ia, :classes, String[])), " "),
                     "management_form" => management_form(fs), "non_form_errors" => fs.non_form_errors,
                     "headers" => headers,
                     "forms" => [Dict{String,Any}("form" => f, "hidden" => SafeString(hidden_id_html(f)),
                                                  "title" => f.instance === nothing ? "" : string(f.instance),
                                                  "change_link" => link(f.instance),
                                                  # (a saved row's "View on site", the inline's view_on_site, as Django's)
                                                  "view_on_site" => f.instance === nothing || f.instance.pk === nothing ? nothing :
                                                                    view_on_site_link(inline_option(ia, :view_on_site, true), f.instance),
                                                  "fields" => [f[n] for n in names if n !== :DELETE],
                                                  "readonly" => [Dict("label" => rofield(n), "value" => rovalue(f.instance, n)) for n in ro],
                                                  "delete" => :DELETE in names ? f[:DELETE] : nothing) for f in forms],
                     "can_add" => info.can_add,
                     "existing_headers" => [rofield(n) for n in info.shown],
                     "existing" => [Dict{String,Any}("title" => string(o), "change_link" => link(o),
                                                     "readonly" => [Dict("label" => rofield(n), "value" => rovalue(o, n)) for n in info.shown])
                                    for o in info.existing])
end

changed_labels(form, ch) = Juango.get_text_list([string(label(f)) for f in form.fields if f.name in ch], gettext("and"))
"A form set row's hidden id input (none for a model whose own primary key field is on the form: code, index)."
hidden_id_html(f) = any(x -> x.name === :id, f.fields) ? Juango.widget_html(f[:id]) : ""
change_message(form, inlines) = begin
    parts = String[]
    ch = changed_fields(form)
    # (the fields' labels as written, "A, B and C", as Django's get_change_message)
    isempty(ch) || push!(parts, "Changed " * changed_labels(form, ch) * ".")
    for (ia, fs) in inlines
        vn = inline_verbose_names(ia)[1]
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
        replaced = false
        if hook !== nothing && req !== nothing
            g = hook(req, f)
            if g !== nothing && g !== f
                g = deepcopy(g)
                g.name = f.name
                form.fields[i] = f = g
                replaced = true
            end
        end
        # a related model's choices in its own admin's ordering, when it has one (Django's get_field_queryset);
        # a field the hook gave keeps its queryset
        if !replaced && f.kind in (:fk, :m2m) && (relma = get(current_site().registry, admin_key(Juango.related_model(f)), nothing)) !== nothing
            ords = ordering(relma, req)
            isempty(ords) || (form.fields[i] = f = (g = deepcopy(f); g.form = merge(something(g.form, Dict{Symbol,Any}()), Dict{Symbol,Any}(:choices_ordering => ords)); g))
        end
        ov = get(overrides, f.kind, Dict{Symbol,Any}())
        for (k, v) in ov
            setproperty!(f, Symbol(k), v)
        end
        # (a widget formfield_overrides gives wins over radio_fields, filter_*, raw_id_fields and autocomplete_fields, as Django's)
        if !any(k -> Symbol(k) === :widget, keys(ov))
            f.name in radios && (f.widget = :radio)
            for (opt, dir) in ((:filter_horizontal, "horizontal"), (:filter_vertical, "vertical"))
                f.kind === :m2m && f.name in option(ma, opt, Symbol[]) &&
                    (f.widget = Juango.Widget(; attrs = Dict("data-filter-box" => dir, "data-filter-label" => string(label(f)))))
            end
            f.name in ma.raw_id_fields && (f.widget = :raw_id)
            f.name in ma.autocomplete_fields && (f.widget = :autocomplete)
            f.kind === :fk && Juango.widget_kind(f.widget) === nothing && (w = big_fk_widget(f)) !== nothing && (f.widget = w)
        end
        # the raw id box's lookup link, or the add / change / delete links beside a relation's select
        if f.kind in (:fk, :m2m)
            if Juango.widget_kind(f.widget) === :raw_id
                wrap_widget!(f, raw_id_links(req, f))
            elseif (w = related_links(req, ma, f)) !== nothing
                wrap_widget!(f, w)
            end
        end
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

# --- related-object links and popups (Django's RelatedFieldWidgetWrapper, raw id widgets' lookups) ------------

"A page opened as a popup from a related-object link (`_popup`, Django's IS_POPUP_VAR)."
is_popup(req) = req isa Request && (haskey(req.GET, "_popup") || (req.method == "POST" && haskey(req.POST, "_popup")))

"""
    url_params_from_lookup_dict(lookups) -> Vector{Pair{String,String}}

A foreign key's `limit_choices_to` as the change list's query parameters (Django's): a list as
comma-separated values, a boolean as 1 or 0, a function called. A `Q` gives none.
"""
function url_params_from_lookup_dict(lookups)
    lookups isa Function && (lookups = lookups())
    lookups isa AbstractDict || return Pair{String,String}[]
    out = Pair{String,String}[]
    for k in sort!(collect(keys(lookups)); by = string)
        v = lookups[k]
        v isa Function && (v = v())
        push!(out, string(k) => v isa Bool ? (v ? "1" : "0") :
                               v isa Union{AbstractVector,Tuple,AbstractSet} ? join(string.(collect(v)), ",") : string(v))
    end
    out
end
admin_pk_name(@nospecialize(T)) = Juango.natural_pk(T) ? Juango.pk_fields(T)[1].name : :id
limit_choices_of(f) = f.form === nothing ? nothing : get(f.form, :limit_choices_to, nothing)
"The field of the related model a relation points at (its `to_field`, else the primary key)."
related_to_field(f) = f.kind === :fk ? something(Juango.fk_to_field(f), admin_pk_name(related_model(f))) : admin_pk_name(related_model(f))
encode_params(ps) = join((Juango.urlquote(k) * "=" * Juango.urlquote(v) for (k, v) in ps), "&")

"""
The admin's raw id box (Django's ForeignKeyRawIdWidget / ManyToManyRawIdWidget): a lookup link to the
related model's change list (opened as a popup to pick a row), and a foreign key's current object
linked to its change page. Without an admin for the related model, the plain box.
"""
struct RawIdLinks
    lookup::Union{String,Nothing}
    change::Union{String,Nothing}           # the change page's URL with __fk__ for the key
end
function (w::RawIdLinks)(bf, html)
    w.lookup === nothing && return html
    fld = bf.field
    m2m = fld.kind === :m2m
    R = related_model(fld)
    cls = m2m ? "vManyToManyRawIdAdminField" : "vForeignKeyRawIdAdminField" *
          ((g = Juango.findfield(modelmeta(R), related_to_field(fld))) !== nothing && g.kind === :uuid ? " vUUIDField" : "")
    io = IOBuffer()
    print(io, "<div>", Juango.raw_id_input(bf; class = cls), "<a href=\"", escape_html(w.lookup), "\" class=\"related-lookup\" id=\"lookup_",
          escape_html(Juango.html_id(bf.form, fld)), "\" title=\"", escape_html(gettext("Lookup")), "\"></a>")
    if !m2m && (cur = Juango.raw_id_current(bf)) !== nothing
        print(io, "&nbsp;<strong>", w.change === nothing ? escape_html(string(cur)) :
                  "<a href=\"" * escape_html(replace(w.change, "__fk__" => admin_pk(cur))) * "\">" * escape_html(string(cur)) * "</a>", "</strong>")
    end
    print(io, "</div>")
    String(take!(io))
end
function raw_id_links(req, f)
    R = related_model(f)
    ra = get(current_site().registry, admin_key(R), nothing)
    ra === nothing && return RawIdLinks(nothing, nothing)
    ps = url_params_from_lookup_dict(limit_choices_of(f))
    f.kind === :m2m || push!(ps, "_to_field" => string(related_to_field(f)))
    lookup = reverse_url("admin:changelist"; app = ra.app, model = ra.slug) * (isempty(ps) ? "" : "?" * encode_params(ps))
    change = req !== nothing && (can(req, ra, :change) || can(req, ra, :view)) ?
             reverse_url("admin:change"; app = ra.app, model = ra.slug, id = "__fk__") : nothing
    RawIdLinks(lookup, change)
end

"""
Links beside a relation's select to add, change, delete or view the related object in a popup
(Django's RelatedFieldWidgetWrapper), each when the user may, the related model has an admin, and
(change, delete, view) the select picks one object; delete not when deleting it would cascade here.
"""
struct RelatedLinks
    model_ref::String
    verbose_name::String
    params::String                         # _to_field=...&_popup=1
    source_model::String
    add::Union{String,Nothing}
    change::Union{String,Nothing}          # URLs with __fk__ for the selected key
    delete::Union{String,Nothing}
    view::Union{String,Nothing}
end
function (w::RelatedLinks)(bf, html)
    Juango.is_hidden_field(bf.field) && return html
    id = escape_html(Juango.html_id(bf.form, bf.field))
    io = IOBuffer()
    print(io, "<div class=\"related-widget-wrapper\" data-model-ref=\"", escape_html(w.model_ref), "\">", html)
    link(kind, url, title, glyph; template = true, popup = true) =
        print(io, "<a class=\"related-widget-wrapper-link ", kind, "-related\" id=\"", kind, "_", id, "\"",
              template ? " data-href-template=\"" : " href=\"", escape_html(url * "?" * w.params * (kind == "add" ? "&_source_model=" * w.source_model : "")), "\"",
              popup ? " data-popup=\"yes\"" : "", " title=\"", escape_html(title), "\"><span aria-hidden=\"true\">", glyph, "</span></a>")
    vn = w.verbose_name
    w.change === nothing || link("change", w.change, interpolate(gettext("Change selected %(model)s"), Dict("model" => vn)), "✎")
    w.add === nothing || link("add", w.add, interpolate(gettext("Add another %(model)s"), Dict("model" => vn)), "+"; template = false)
    w.delete === nothing || link("delete", w.delete, interpolate(gettext("Delete selected %(model)s"), Dict("model" => vn)), "✕")
    w.view === nothing || link("view", w.view, interpolate(gettext("View selected %(model)s"), Dict("model" => vn)), "👁"; popup = false)
    print(io, "</div>")
    String(take!(io))
end
Base.@nospecializeinfer function related_links(req, ma::ModelAdmin, f)
    R = related_model(f)
    ra = get(current_site().registry, admin_key(R), nothing)
    (ra === nothing || req === nothing) && return nothing
    wk = Juango.widget_kind(f.widget)
    single = f.kind !== :m2m && !(wk in (:radio, :checkboxes, :hidden)) && !(f.widget isa Juango.Widget && haskey(f.widget.attrs, "data-filter-box"))
    url(kind) = reverse_url("admin:" * kind; app = ra.app, model = ra.slug, id = "__fk__")
    cascade = f.kind !== :m2m && f.on_delete === :CASCADE
    rm = modelmeta(R)
    RelatedLinks(model_name(R), rm.verbose_name, "_to_field=" * Juango.urlquote(string(related_to_field(f))) * "&_popup=1",
                 lowercase(Juango.model_label(ma.model)),
                 can(req, ra, :add) ? reverse_url("admin:add"; app = ra.app, model = ra.slug) : nothing,
                 single && can(req, ra, :change) ? url("change") : nothing,
                 single && !cascade && can(req, ra, :delete) ? url("delete") : nothing,
                 single && !can(req, ra, :change) && can(req, ra, :view) ? url("change") : nothing)
end
wrap_widget!(f, w) = (f.form = merge(something(f.form, Dict{Symbol,Any}()), Dict{Symbol,Any}(:wrap_widget => w)); f)

"""
`_to_field` (a popup picking objects by a field other than the key) must be the primary key, or a
field a relation from a model in this admin points at (Django's to_field_allowed); else a 400.
"""
Base.@nospecializeinfer function check_to_field(ma::ModelAdmin, req)
    tf = req.method == "POST" && haskey(req.POST, "_to_field") ? req.POST["_to_field"] : get(req.GET, "_to_field", nothing)
    (tf === nothing || isempty(tf)) && return nothing
    if !to_field_allowed(ma, tf)                   # (logged as Django's DisallowedModelAdminToField)
        Juango.log!("juango.security.DisallowedModelAdminToField", :error, "The field $tf cannot be referenced."; request = req)
        throw(Juango.BadRequest("The field $tf cannot be referenced."))
    end
    tf
end
Base.@nospecializeinfer function to_field_allowed(ma::ModelAdmin, name::AbstractString)
    T = ma.model
    n = Symbol(name)
    (n === :pk || n === admin_pk_name(T)) && return true
    Juango.findfield(modelmeta(T), n) === nothing && return false
    st = current_site()
    registered = Set{Any}()
    for (_, a) in st.registry
        push!(registered, a.model)
        foreach(ia -> push!(registered, ia.model), a.inlines)
    end
    any(Juango.related_objects(T)) do r
        r.field.kind in (:fk, :o2o) && any(M -> M <: r.related_model || M === r.related_model, registered) && related_to_field(r.field) === n
    end
end
"The value a popup hands back for an object: its `_to_field` value, else its key."
popup_value(@nospecialize(o), tf) = tf === nothing ? Juango.pk_string(o) : string(getproperty(o, Symbol(tf)))
"""
What an add popup hands back (Django's response_add): the new object's value and name, and, when the form that opened
it (`_source_model`, "app.model") has a field named after this model's plural with grouped choices, the group the new
object is in (`optgroup`). An unknown source model is an error message for the next page.
"""
function popup_add_data(req, ma::ModelAdmin, @nospecialize(o), to_field)
    d = Dict{String,Any}("value" => popup_value(o, to_field), "obj" => string(o))
    src = get(req.POST, "_source_model", "")
    isempty(src) && return d
    S = try
        occursin('.', src) ? Juango.get_model(src) : nothing
    catch e
        e isa Juango.ImproperlyConfigured || rethrow()
        nothing
    end
    if S === nothing
        message!(req, :error, "The app \"$src\" could not be found.")
        return d
    end
    sma = get(current_site().registry, admin_key(S), nothing)
    sma === nothing && return d
    form = configure_widgets!(sma, Juango.ModelForm(S; fields = admin_fields(sma, req, nothing)), req)
    name = Symbol(modelmeta(ma.model).verbose_name_plural)
    i = findfirst(f -> f.name === name, form.fields)
    i === nothing && return d
    groups = form.fields[i].choices === nothing ? nothing : Juango.choice_groups(form.fields[i])
    groups === nothing && return d
    for (g, cs) in groups
        g === nothing && continue
        any(c -> string(c.second) == string(o), cs) && (d["optgroup"] = string(g); break)
    end
    d
end
"The page that closes a popup and hands its object back to the form that opened it (Django's popup_response.html)."
popup_response(req, data) = render(req, "admin/popup_response.html", Dict{String,Any}("popup_response_data" => Juango.JSON.json(data)))

"The add form's initial values from the query string (Django's get_changeform_initial_data; many-to-many as 1,2,3)."
function changeform_initial(ma::ModelAdmin, req::Request)
    req.method == "GET" || return Dict{Symbol,Any}()
    meta = modelmeta(ma.model)
    out = Dict{Symbol,Any}()
    for (k, vs) in req.GET.data
        isempty(vs) && continue
        m = findfirst_m2m(meta, Symbol(k))
        if m !== nothing
            out[Symbol(k)] = split(vs[end], ",")
        elseif findfield(meta, Symbol(k)) !== nothing
            out[Symbol(k)] = vs[end]
        end
    end
    out
end

Base.@nospecializeinfer function change_form(req::Request, ma::ModelAdmin, @nospecialize(obj))
    T = ma.model
    meta = modelmeta(T)
    save_as_new = req.method == "POST" && ma.save_as && haskey(req.POST, "_saveasnew")
    save_as_new && (obj = nothing)
    adding = obj === nothing
    adding ? require_perm(req, ma, :add) : require_perm(req, ma, :view, :change; obj = obj)
    popup = is_popup(req)
    to_field = check_to_field(ma, req)
    old_value = !popup || adding ? nothing : popup_value(obj, to_field)
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
                                                   fields = filter(!in(locked), admin_fields(ma, req, obj)),
                                                   initial = adding ? changeform_initial(ma, req) : Dict{Symbol,Any}()), req)
    pfs = custom_add || (!adding && option(ma, :password_change_page, false)) ? Symbol[] : ma.password_fields
    # ("Save as new": the inlines' rows are copied to the new object, and validated, as Django's save_as_new form sets)
    inlines = custom_add ? Any[] : inline_formsets(ma, req, obj, data; parent_editable = editable, save_as_new)
    # (the form and every inline are validated, so all their errors show at once, as Django's all_valid)
    if req.method == "POST" && (fv = is_valid(form); ivs = [is_valid(x[2]) for x in inlines]; fv && all(ivs))
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
        # opened from a related-object link: close, handing the object back (Django's response_add / response_change)
        haskey(req.POST, "_popup") && return popup_response(req, adding ? popup_add_data(req, ma, o, to_field) :
                                                     Dict("action" => "change", "value" => old_value, "obj" => string(o),
                                                          "new_value" => popup_value(o, to_field)))
        # (the object linked: to its change page after adding, if the user may change it; to this page after changing, as Django's)
        obj_url = reverse_url("admin:change"; app = ma.app, model = ma.slug, id = admin_pk(o))
        shown = escape_html(isempty(string(o)) ? "-" : string(o))
        objlink = adding && !can(req, ma, :change, o) ? shown :
                  "<a href=\"" * escape_html(adding ? obj_url : Juango.iri_to_uri(req.path)) * "\">" * shown * "</a>"
        msg(t; more = "") = SafeString(interpolate(gettext(t), Dict("model" => escape_html(meta.verbose_name), "object" => objlink)) *
                                       (isempty(more) ? "" : " " * escape_html(interpolate(gettext(more), Dict("model" => meta.verbose_name)))))
        added_or_changed = adding ? "The %(model)s “%(object)s” was added successfully." : "The %(model)s “%(object)s” was changed successfully."
        # (an add form of its own, the user admin's, goes on to the change page unless "Save and add another", as Django's UserAdmin)
        # ("Save as new" goes on to the new object unless save_as_continue = false or the user may not change it, as Django's)
        if haskey(req.POST, "_continue") || (save_as_new && option(ma, :save_as_continue, true) && can(req, ma, :change, o)) ||
           (custom_add && !haskey(req.POST, "_addanother"))
            message!(req, :success, msg(added_or_changed; more = !adding || can(req, ma, :change, o) ? "You may edit it again below." : ""))
            return Juango.HttpResponseRedirect(obj_url * kept_query(req))
        elseif haskey(req.POST, "_addanother")
            message!(req, :success, msg(added_or_changed; more = "You may add another %(model)s below."))
            return Juango.HttpResponseRedirect(reverse_url("admin:add"; app = ma.app, model = ma.slug) * kept_query(req))
        end
        message!(req, :success, msg(added_or_changed))
        # (where a plain "Save" goes, Django's response_post_save_add / response_post_save_change)
        pss = option(ma, adding ? :response_post_save_add : :response_post_save_change)
        pss === nothing || return Juango.to_response(pss(req, o))
        # (to the change list if the user may see it, else the index, as Django's)
        can_view(req, ma) || can(req, ma, :change) || return Juango.HttpResponseRedirect(reverse_url("admin:index"))
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
        "opts" => opts(ma), "form" => form, "object" => obj, "object_display" => obj === nothing ? "" : object_display(obj), "adding" => adding, "readonly" => auto_readonly,
        "groups" => custom_add ? [Dict{String,Any}("name" => "", "rows" => [Dict{String,Any}("readonly" => false, "field" => form[f.name]) for f in form.fields])] :
                    form_groups(ma, form, obj, editable; locked = locked, readonly = ro,
                                fieldsets = admin_fieldsets(ma, req, obj)),
        "inlines" => [inline_context(req, ia, fs, info) for (ia, fs, info) in inlines],
        # (an inline's file field makes the whole form multipart, as Django's has_file_field)
        "has_file_field" => Juango.is_multipart(form) || any(x -> Juango.is_multipart(x[2]), inlines),
        "prepopulated" => Juango.JSON.json(prepop), "save_as" => ma.save_as && !adding && can(req, ma, :add),
        "password_fields" => [Dict("name" => string(pf), "label" => uppercasefirst(string(pf))) for pf in pfs],
        "view_on_site" => adding ? nothing : view_on_site_url(ma, obj), "save_on_top" => option(ma, :save_on_top, false),
        "password_change" => adding || !option(ma, :password_change_page, false) ? nothing :
            Dict("summary" => Juango.password_summary(obj), "url" => reverse_url("admin:password_change"; app = ma.app, model = ma.slug, id = admin_pk(obj))),
        # (the history, delete and close links keep the change list's filters, as Django's add_preserved_filters)
        "history_url" => adding ? nothing : reverse_url("admin:history"; app = ma.app, model = ma.slug, id = admin_pk(obj)) * keep_filters(req),
        "delete_url" => adding ? nothing : reverse_url("admin:delete"; app = ma.app, model = ma.slug, id = admin_pk(obj)) * keep_filters(req),
        "close_url" => changelist_url(ma, req),
        "to_field" => to_field, "source_model" => popup ? get(req.GET, "_source_model", get(req.POST, "_source_model", nothing)) : nothing))
    # (a "Save as new" that failed: only "Save as new" again, as Django's submit row)
    save_as_new && (ctx["save_as_only"] = true; ctx["save_as"] = true)
    if popup        # (in a popup: Save only, as Django's submit row)
        ctx["can_delete"] = false; ctx["save_as"] = false; ctx["can_add"] = false
    end
    render(req, "admin/change_form.html", ctx)
end

"The change list to go back to: with the filters it had (`_changelist_filters`, preserve_filters)."
function changelist_url(ma::ModelAdmin, req::Request)
    f = get(req.GET, "_changelist_filters", "")
    reverse_url("admin:changelist"; app = ma.app, model = ma.slug) * (option(ma, :preserve_filters, true) && !isempty(f) ? "?" * f : "")
end
"The request's query string (initial values, _popup, _to_field, _changelist_filters) for the next page, as Django's preserved_qsl."
kept_query(req::Request) = isempty(req.query_string) ? "" : "?" * req.query_string
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
        return Juango.HttpResponseRedirect(reverse_url("admin:change"; app = ma.app, model = ma.slug, id = admin_pk(obj)))
    end
    ctx = base_context(req, interpolate(gettext("Change password: %(username)s"), Dict("username" => string(obj))))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "form" => form, "object" => obj, "object_display" => object_display(obj)))
    render(req, "admin/change_password.html", ctx)
end

add_view(req::Request; app, model) = change_form(req, get_admin(app, model), nothing)
"The object with this primary key (from the URL), or a 404."
function admin_object(ma::ModelAdmin, req, id)
    key = admin_unquote(id)
    pk = Juango.parse_pk(ma.model, key)
    o = pk === nothing ? nothing : first(filter(admin_queryset(ma, req); pk = pk))
    if o === nothing          # (back to the index with a message, as Django's; permission first)
        can_view(req, ma) || can(req, ma, :change) || can(req, ma, :delete) || throw(PermissionDenied())
        message!(req, :warning, interpolate(gettext("%(name)s with ID “%(key)s” doesn’t exist. Perhaps it was deleted?"),
                                            Dict("name" => modelmeta(ma.model).verbose_name, "key" => key)))
        throw(AdminRedirect(Juango.HttpResponseRedirect(reverse_url("admin:index"))))
    end
    o
end

"Thrown by a view to answer with a redirect (a missing object)."
struct AdminRedirect <: Exception
    response::Any
end

# Django's admin quote: a key in a URL with the characters that mean something there as _XX
const QUOTE_CHARS = Set(collect("\":/_#?;@&=+\$,[]<>%\n\\"))
hex2(c) = uppercase(string(UInt8(c); base = 16, pad = 2))
"A primary key as the admin writes it in URLs (Django's `admin.utils.quote`): `\"a/b\"` is `\"a_2Fb\"`."
admin_quote(s::AbstractString) = join(c in QUOTE_CHARS ? "_" * hex2(c) : string(c) for c in s)
const UNQUOTE_RE = Regex("_(" * join(sort([hex2(c) for c in QUOTE_CHARS]), "|") * ")")
"The primary key from an admin URL (Django's `unquote`)."
admin_unquote(s::AbstractString) = replace(s, UNQUOTE_RE => m -> string(Char(parse(UInt8, m[2:end]; base = 16))))
admin_pk(@nospecialize(o)) = admin_quote(Juango.pk_string(o))
"An object as the admin names it: its string, or \"-\" when that's only whitespace (Django's display_for_value)."
object_display(@nospecialize(o)) = (t = strip(string(o)); isempty(t) ? "-" : String(t))
Juango.tattr(@nospecialize(m::Model), ::Val{:admin_pk}) = admin_pk(m)

"""
The change form's "View on site" link (Django's view_on_site): with `view_on_site = true` (the
default) the site's redirect to the object's `get_absolute_url` when it has one, with a function
what it returns for the object, with `false` none.
"""
Base.@nospecializeinfer view_on_site_url(ma::ModelAdmin, @nospecialize(obj)) = view_on_site_link(option(ma, :view_on_site, true), obj)
"An object's \"View on site\" URL for a view_on_site option (true: by get_absolute_url; false: none; a function of the object)."
Base.@nospecializeinfer function view_on_site_link(v, @nospecialize(obj))
    v === false && return nothing
    v isa Function && return v(obj)
    absolute_url(obj) === nothing && return nothing
    reverse_url("admin:view_on_site"; content_type_id = Juango.get_for_model(typeof(obj)).id, object_id = admin_pk(obj))
end
"`admin/r/<content type>/<id>/`: to the object's `get_absolute_url` (Django's contenttypes shortcut)."
function view_on_site_view(req::Request; content_type_id, object_id)
    ctid = tryparse(Int, string(content_type_id))
    ct = ctid === nothing ? nothing : first(filter(Juango.ContentType; id = ctid))
    ct === nothing && throw(Http404("Content type $content_type_id object has no associated model"))
    T = Juango.model_class(ct)
    T === nothing && throw(Http404("Content type $content_type_id object has no associated model"))
    pk = Juango.parse_pk(T, admin_unquote(object_id))
    o = pk === nothing ? nothing : first(filter(objects(T); pk = pk))
    o === nothing && throw(Http404("Content type $content_type_id object $object_id doesn’t exist"))
    url = absolute_url(o)
    url === nothing && throw(Http404("$(modelmeta(T).verbose_name) objects don’t have a get_absolute_url() method"))
    Juango.HttpResponseRedirect(url)
end

"The old object URL (`.../<id>/`) goes to its change page, as Django's."
object_redirect(req::Request; app, model, id) =
    Juango.HttpResponseRedirect(reverse_url("admin:change"; app = app, model = model, id = id))

change_view(req::Request; app, model, id) = (ma = get_admin(app, model); change_form(req, ma, admin_object(ma, req, id)))

function delete_view(req::Request; app, model, id)
    ma = get_admin(app, model)
    meta = modelmeta(ma.model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :delete; obj = obj)
    to_field = check_to_field(ma, req)
    if req.method == "POST" && isempty(get_deleted_objects(req, obj).protected)    # (protected: the page again, as Django's)
        isempty(get_deleted_objects(req, obj).perms_needed) || throw(PermissionDenied())
        name = string(obj)
        value = popup_value(obj, to_field)
        try
            Juango.atomic() do
                log_action!(req.user, obj, DELETION)
                dm = option(ma, :delete_model)
                dm === nothing ? delete!(obj) : dm(req, obj)
            end
            rd = option(ma, :response_delete)
            rd === nothing || return Juango.to_response(rd(req, name))
            haskey(req.POST, "_popup") && return popup_response(req, Dict("action" => "delete", "value" => value))
            message!(req, :success, interpolate(gettext("The %(model)s “%(object)s” was deleted successfully."),
                                                Dict("model" => meta.verbose_name, "object" => name)))
            return Juango.HttpResponseRedirect(changelist_url(ma, req))
        catch e
            e isa Union{ProtectedError,RestrictedError} || rethrow()
            message!(req, :error, Juango.protected_message(e))
            return Juango.HttpResponseRedirect(reverse_url("admin:change"; app = ma.app, model = ma.slug, id = id))
        end
    end
    d = get_deleted_objects(req, obj; max_display = option(ma, :delete_confirmation_max_display))
    title = isempty(d.perms_needed) && isempty(d.protected) ? gettext("Are you sure?") :
            interpolate(gettext("Cannot delete %(name)s"), Dict("name" => meta.verbose_name))
    ctx = base_context(req, title)
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "object_display" => object_display(obj), "deleted_objects" => d.html,
                                 "model_count" => d.model_count, "perms_lacking" => d.perms_needed, "protected" => d.protected,
                                 "protected_html" => d.protected_html,
                                 "change_url" => reverse_url("admin:change"; app = ma.app, model = ma.slug, id = id) * keep_filters(req),
                                 "show_objects" => (md = option(ma, :delete_confirmation_max_display); md === nothing || md > 0),
                                 "hide_protected" => option(ma, :delete_confirmation_max_display) == 0,
                                 "to_field" => to_field))
    render(req, "admin/delete_confirmation.html", ctx)
end

"""
What deleting `obj` would delete, as Django's `get_deleted_objects`: `html`, the nested list of
the objects the cascade reaches ("Plot: <a>World Domination</a>" with what it takes along under
it, linked to their change pages where the admin has them), `model_count` (verbose name plural =>
count), `perms_needed` (the verbose names of registered models the user may not delete) and
`protected` (the objects behind `:PROTECT` keys, or `:RESTRICT` keys the deletion doesn't reach,
that block it).
"""
Base.@nospecializeinfer function get_deleted_objects(req, @nospecialize(obj); max_display = nothing)
    seen = Set{Tuple{Any,Any}}()
    counts = Dict{String,Int}()
    perms = Set{String}()
    protected = Any[]
    restricted = Any[]
    st = current_site()
    item(o) = begin
        T = typeof(o)
        m = modelmeta(T)
        ma = get(st.registry, admin_key(T), nothing)
        name = uppercasefirst(m.verbose_name)
        ma !== nothing && !can(req, ma, :delete, o) && push!(perms, m.verbose_name)
        link = ma === nothing ? nothing : (try reverse_url("admin:change"; app = ma.app, model = ma.slug, id = admin_pk(o)) catch; nothing end)
        link === nothing ? string(name, ": ", Juango.escape_html(object_display(o))) :
                           string(name, ": <a href=\"", link, "\">", Juango.escape_html(object_display(o)), "</a>")
    end
    function walk(o)
        T = Juango.concrete_model(typeof(o))
        push!(seen, (T, o.pk))
        m = modelmeta(T)
        counts[m.verbose_name_plural] = get(counts, m.verbose_name_plural, 0) + 1
        children = Any[]
        for (_, M, f) in Juango.deletion_referrers(T)
            f.on_delete in (:CASCADE, :PROTECT, :RESTRICT) || continue
            rel = collect(filter(Juango.base_objects(M), Juango.referrers_q(f, Any[o.pk])))
            for r in rel
                if f.on_delete === :PROTECT
                    any(x -> x === r || (typeof(x) === typeof(r) && x.pk == r.pk), protected) || push!(protected, r)
                elseif f.on_delete === :RESTRICT
                    push!(restricted, r)
                elseif !((Juango.concrete_model(typeof(r)), r.pk) in seen)
                    push!(children, walk(r))
                end
            end
        end
        for C in Juango.child_models(T)        # (multi-table children extend the row)
            for c in filter(Juango.base_objects(C); id__in = Any[o.pk])
                (C, c.pk) in seen || push!(children, walk(c))
            end
        end
        # (and a child's parent rows go with it, with what refers to them, as Django's collector)
        P = Juango.table_parent(T)
        if P !== nothing && !((P, o.pk) in seen)
            for p in filter(Juango.base_objects(P); id__in = Any[o.pk])
                push!(children, walk(p))
            end
        end
        (item(o), children)
    end
    tree = walk(obj)
    for r in restricted                       # (a restricted row the deletion doesn't reach blocks it)
        (Juango.concrete_model(typeof(r)), r.pk) in seen || any(x -> typeof(x) === typeof(r) && x.pk == r.pk, protected) || push!(protected, r)
    end
    (html = SafeString(truncated_list([tree], max_display)), model_count = sort(collect(counts); by = first), perms_needed = sort(collect(perms)),
     protected = [SafeString(item(p)) for p in protected],
     protected_html = SafeString(truncated_list([(item(p), Any[]) for p in protected], max_display)))
end

"""
A nested list of (item html, children) as <li>s, at most `max_items` of them counted in order (nothing: all), then
"…and N more objects.", as Django's truncated_unordered_list (delete_confirmation_max_display).
"""
function truncated_list(nodes, max_items)
    n = Ref(0)
    function fmt(ns)
        io = IOBuffer()
        for (html, children) in ns
            n[] += 1
            shown = max_items === nothing || n[] <= max_items
            sub = isempty(children) ? "" : "<ul>" * fmt(children) * "</ul>"
            shown && print(io, "<li>", html, sub, "</li>")
        end
        String(take!(io))
    end
    max_items !== nothing && max_items <= 0 && return ""
    out = fmt(nodes)
    if max_items !== nothing && n[] > max_items
        k = n[] - max_items
        out *= "<li>" * replace(Juango.ngettext("…and %(count)d more object.", "…and %(count)d more objects.", k), "%(count)d" => string(k)) * "</li>"
    end
    out
end

"The change history of one object."
function history_view(req::Request; app, model, id)
    ma = get_admin(app, model)
    obj = admin_object(ma, req, id)
    require_perm(req, ma, :view, :change; obj = obj)
    entries = collect(select_related(order_by(filter(LogEntry; content_type = get_for_model(ma.model), object_id = admin_pk(obj)),
                                              "action_time", "id"), :user))
    ctx = base_context(req, interpolate(gettext("Change history: %(object)s"), Dict("object" => obj)))
    merge!(ctx, Dict{String,Any}("opts" => opts(ma), "object" => obj, "object_display" => object_display(obj), "entries" => entries))
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
    # admin pages aren't cached (Django's admin_view is never_cache)
    nc = Juango.never_cache(function (req; kw...)
        try
            checked(req; kw...)
        catch e
            e isa AdminRedirect || rethrow()
            e.response
        end
    end)
    Juango.login_not_required(function (req; kw...)
        Base.ScopedValues.with(CURRENT_SITE => st, Juango.CURRENT_APP => ("admin" => st.name)) do
            nc(req; kw...)
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
    any(x -> x === st, CHECKED_SITES) || push!(CHECKED_SITES, st)
    Juango.require_app("admin", "Admin.urls()")
    st === site && register_user_model!()
    s(v) = site_view(st, v)
    wrap(p) = Juango.wrap_view(p, s)
    custom = Any[path(ma.app * "/" * ma.slug * "/", include_urls([wrap(p) for p in ma.extra_urls])) for ma in values(st.registry) if !isempty(ma.extra_urls)]
    SITES[st.name] = st             # (Django's per-model URL names resolve through django_url_name)
    include_urls(vcat(Any[
        path("", s(index); name = "index"),
        path("login/", site_view(st, admin_login; public = true); name = "login"),
        path("logout/", site_view(st, admin_logout; public = true); name = "logout"),
        path("r/<path:content_type_id>/<path:object_id>/", s(view_on_site_view); name = "view_on_site")],     # (any ids, as Django's)
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
        path("<slug:app>/<slug:model>/<str:id>/", s(object_redirect)),
    ]); namespace = st.name, app_name = "admin")
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

# --- system checks (Django's admin.E0xx-E2xx) -------------------------------------------------------------------

"Admin sites whose URLs are mounted (`Admin.urls(site)`): the ones `manage.jl check` checks, as Django's all_sites."
const CHECKED_SITES = AdminSite[]
"Every admin site a model was registered on (a ModelAdmin's own site, for autocomplete_fields' check)."
const ALL_SITES = AdminSite[]

admin_field(T, name) = (i = findfirst(f -> f.name === Symbol(name), Juango.all_fields(T)); i !== nothing ? Juango.all_fields(T)[i] :
                       (j = findfirst(f -> f.name === Symbol(name), Juango.many_to_many(T)); j === nothing ? nothing : Juango.many_to_many(T)[j]))
admin_label(ma::ModelAdmin) = "<ModelAdmin $(admin_key(ma.model))>"
model_label(T) = modelmeta(T).app * "." * string(nameof(T))
missing_field(ma, option, field, T = ma.model) =
    "The value of '$option' refers to '$field', which is not a field of '$(model_label(T))'."
dups(xs) = length(unique(xs)) != length(xs)

"""
    Admin.check_admin(ma) -> Vector{CheckMessage}

The problems in a ModelAdmin's options, with Django's ids and messages (admin.E002 ...): names that
aren't fields of the model, or the wrong kind of field for the option, duplicates, conflicting options.
`manage.jl check` runs it for every model of every mounted admin site.
"""
Base.@nospecializeinfer function check_admin(ma::ModelAdmin)
    T = ma.model
    out = Juango.CheckMessage[]
    err(msg, id) = push!(out, Juango.CheckMessage(:error, admin_label(ma) * ": " * msg; id = id))
    # raw_id_fields (E002, E003)
    for (i, n) in enumerate(ma.raw_id_fields)
        f = admin_field(T, n)
        f === nothing ? err(missing_field(ma, "raw_id_fields[$(i-1)]", n), "admin.E002") :
        f.kind in (:fk, :o2o, :m2m) || err("The value of 'raw_id_fields[$(i-1)]' must be a foreign key or a many-to-many field.", "admin.E003")
    end
    # fields and fieldsets (E005, E006, E012, E013)
    ma.fields !== nothing && !isempty(ma.fieldsets) && err("Both 'fieldsets' and 'fields' are specified.", "admin.E005")
    ma.fields !== nothing && dups(ma.fields) && err("The value of 'fields' contains duplicate field(s).", "admin.E006")
    seen = Symbol[]
    for (i, (_, names)) in enumerate(ma.fieldsets)
        any(n -> n in seen, names) || dups(names) ? err("There are duplicate field(s) in 'fieldsets[$(i-1)][1]'.", "admin.E012") : nothing
        append!(seen, names)
    end
    m2m_through(n) = (f = findfirst_m2m(modelmeta(T), Symbol(n)); f !== nothing && f.through !== nothing && !(Juango.through_model(f) <: Juango.AutoThrough))
    for (label, names) in vcat(ma.fields === nothing ? Pair{String,Vector{Symbol}}[] : ["fields" => ma.fields],
                               ["fieldsets[$(i-1)][1]['fields']" => last(fs) for (i, fs) in enumerate(ma.fieldsets)])
        for n in names
            m2m_through(n) && err("The value of '$label' cannot include the ManyToManyField '$n', because that field manually specifies a relationship model.", "admin.E013")
        end
    end
    dups(ma.exclude) && err("The value of 'exclude' contains duplicate field(s).", "admin.E015")
    # filter_horizontal / filter_vertical (E019, E020, E013)
    for opt in (:filter_vertical, :filter_horizontal), (i, n) in enumerate(option(ma, opt, Symbol[]))
        f = admin_field(T, n)
        f === nothing ? err(missing_field(ma, "$opt[$(i-1)]", n), "admin.E019") :
        f.kind === :m2m || err("The value of '$opt[$(i-1)]' must be a many-to-many field.", "admin.E020")
    end
    # radio_fields (E022, E023)
    for n in option(ma, :radio_fields, Symbol[])
        f = admin_field(T, n)
        f === nothing ? err(missing_field(ma, "radio_fields", n), "admin.E022") :
        (f.kind in (:fk, :o2o) || f.choices !== nothing) ||
            err("The value of 'radio_fields' refers to '$n', which is not an instance of ForeignKey, and does not have a 'choices' definition.", "admin.E023")
    end
    # prepopulated_fields (E027, E028, E030)
    for (k, vs) in ma.prepopulated_fields
        f = admin_field(T, k)
        if f === nothing
            err(missing_field(ma, "prepopulated_fields", k), "admin.E027")
        elseif f.kind in (:datetime, :fk, :o2o, :m2m)
            err("The value of 'prepopulated_fields' refers to '$k', which must not be a DateTimeField, a ForeignKey, a OneToOneField, or a ManyToManyField.", "admin.E028")
        end
        for (i, v) in enumerate(vs)
            admin_field(T, v) === nothing && err(missing_field(ma, "prepopulated_fields[\"$k\"][$(i-1)]", v), "admin.E030")
        end
    end
    # ordering (E032, E033)
    ords = [x for x in ma.ordering if x isa AbstractString]
    "?" in ords && length(ma.ordering) > 1 &&
        err("The value of 'ordering' has the random ordering marker '?', but contains other fields as well.", "admin.E032")
    for (i, o) in enumerate(ords)
        o == "?" && continue
        n = lstrip(o, '-')
        (n in ("pk", "id") || occursin("__", n) || admin_field(T, n) !== nothing) || err(missing_field(ma, "ordering[$(i-1)]", n), "admin.E033")
    end
    # autocomplete_fields (E037, E038, E039, E040)
    sites = vcat(CHECKED_SITES, [site], ALL_SITES)
    i = findfirst(x -> any(y -> y === ma, values(x.registry)), sites)
    st = i === nothing ? site : sites[i]
    for (i, n) in enumerate(ma.autocomplete_fields)
        f = admin_field(T, n)
        if f === nothing
            err(missing_field(ma, "autocomplete_fields[$(i-1)]", n), "admin.E037")
        elseif !(f.kind in (:fk, :o2o, :m2m))
            err("The value of 'autocomplete_fields[$(i-1)]' must be a foreign key or a many-to-many field.", "admin.E038")
        else
            R = related_model(f)
            rma = get(st.registry, admin_key(R), nothing)
            if rma === nothing
                err("An admin for model \"$(nameof(R))\" has to be registered to be referenced by $(admin_label(ma)).autocomplete_fields.", "admin.E039")
            elseif isempty(rma.search_fields) && rma.get_search_fields === nothing
                err("$(admin_label(rma)) must define \"search_fields\", because it's referenced by $(admin_label(ma)).autocomplete_fields.", "admin.E040")
            end
        end
    end
    # view_on_site (E025): a function or a boolean
    vos = option(ma, :view_on_site, true)
    vos isa Bool || vos isa Function ||
        err("The value of 'view_on_site' must be a callable or a boolean value.", "admin.E025")
    # delete_confirmation_max_display (E041)
    md = option(ma, :delete_confirmation_max_display)
    md === nothing || (md isa Integer && !(md isa Bool) && md >= 0) ||
        err("The value of 'delete_confirmation_max_display' must be a non-negative integer or None.", "admin.E041")
    # list_display (E109), list_display_links (E111)
    for (i, c) in enumerate(ma.list_display)
        c isa Union{Symbol,AbstractString} || continue
        f = admin_field(T, c)
        f !== nothing && f.kind === :m2m &&
            err("The value of 'list_display[$(i-1)]' must not be a many-to-many field or a reverse foreign key.", "admin.E109")
    end
    links = option(ma, :list_display_links)
    if links !== nothing
        names = [x isa Union{Symbol,AbstractString} ? Symbol(x) : x for x in ma.list_display]
        for (i, l) in enumerate(links)
            (l isa Union{Symbol,AbstractString} ? Symbol(l) : l) in names ||
                err("The value of 'list_display_links[$(i-1)]' refers to '$l', which is not defined in 'list_display'.", "admin.E111")
        end
    end
    # list_filter (E116)
    for (i, e) in enumerate(ma.list_filter)
        e isa ListFilter && continue
        name = string(e isa Pair ? e.first : e)
        filter_field(T, name) === nothing &&
            err("The value of 'list_filter[$(i-1)]' refers to '$name', which does not refer to a Field.", "admin.E116")
    end
    # list_editable (E121-E125)
    ld = [x isa Union{Symbol,AbstractString} ? Symbol(x) : nothing for x in ma.list_display]
    for (i, n) in enumerate(ma.list_editable)
        f = admin_field(T, n)
        label = "list_editable[$(i-1)]"
        if f === nothing
            err(missing_field(ma, label, n), "admin.E121")
        elseif !(n in ld)
            err("The value of '$label' refers to '$n', which is not contained in 'list_display'.", "admin.E122")
        elseif links !== nothing && n in [Symbol(x) for x in links if x isa Union{Symbol,AbstractString}]
            err("The value of '$label' cannot be in both 'list_editable' and 'list_display_links'.", "admin.E123")
        elseif links === nothing && !isempty(ld) && ld[1] === n
            err("The value of '$label' refers to the first field in 'list_display' ('$n'), which cannot be used unless 'list_display_links' is set.", "admin.E124")
        elseif !f.editable
            err("The value of '$label' refers to '$n', which is not editable through the admin.", "admin.E125")
        end
    end
    # date_hierarchy (E127, E128)
    if ma.date_hierarchy !== nothing
        f = admin_path_field(T, string(ma.date_hierarchy))
        f === nothing ? err("The value of 'date_hierarchy' refers to '$(ma.date_hierarchy)', which does not refer to a Field.", "admin.E127") :
        f.kind in (:date, :datetime) || err("The value of 'date_hierarchy' must be a DateField or DateTimeField.", "admin.E128")
    end
    # actions (E130)
    names = [a.name for a in ma.actions]
    for n in unique(names)
        count(==(n), names) > 1 && err("__name__ attributes of actions defined in $(admin_label(ma)) must be unique. Name '$n' is not unique.", "admin.E130")
    end
    # inlines (E201, E202)
    for ia in ma.inlines
        ilabel = "<$(ia.style === :tabular ? "TabularInline" : "StackedInline") $(admin_key(ia.model))>"
        if (gen = inline_option(ia, :generic)) !== nothing            # (a generic inline: its content type field, as Django's GenericInlineModelAdminChecks)
            try
                Juango.generic_inlineformset_factory(ia.model; ct_field = gen[1], fk_field = gen[2])
            catch e
                e isa ArgumentError || rethrow()
                push!(out, Juango.CheckMessage(:error, ilabel * ": " * e.msg; id = "admin.E304"))
            end
            continue
        end
        try
            Juango.inlineformset_factory(T, ia.model; fk = ia.fk, fields = ia.fields)      # (Django's messages for a missing or ambiguous key)
            fk = only(f for f in Juango.all_fields(ia.model) if f.kind === :fk && T in Juango.lineage(related_model(f)) &&
                                                               (ia.fk === nothing || f.name === ia.fk))
            fk.name in inline_option(ia, :exclude, Symbol[]) &&
                push!(out, Juango.CheckMessage(:error, ilabel * ": Cannot exclude the field '$(fk.name)', because it is the foreign key to the parent model '$(model_label(T))'."; id = "admin.E201"))
        catch e
            e isa ArgumentError || rethrow()
            push!(out, Juango.CheckMessage(:error, ilabel * ": " * e.msg; id = "admin.E202"))
        end
    end
    out
end

"The field a `field__path` through relations ends at, or `nothing`."
function admin_path_field(T, p::AbstractString)
    M, f = T, nothing
    for part in split(p, "__")
        M === nothing && return nothing
        f = admin_field(M, part)
        f === nothing && return nothing
        M = f.kind in (:fk, :o2o, :m2m) ? related_model(f) : nothing
    end
    f
end

"Every problem in the mounted admin sites' ModelAdmins (`manage.jl check`, tag `admin`)."
admin_check_issues() = reduce(vcat, (check_admin(ma) for st in unique(vcat([site], CHECKED_SITES)) for ma in values(st.registry));
                              init = Juango.CheckMessage[])
Juango.register_check!(() -> Juango.is_installed("admin") ? admin_check_issues() : Juango.CheckMessage[]; tags = [:admin])

end # module Admin
