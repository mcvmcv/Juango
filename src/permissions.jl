# Permissions and groups ----------------------------------------------------------------------------
#
#     has_perm(user, "project.change_post")              # app label . codename
#     const edit_post = permission_required("project.change_post")(edit_post_view)
#     {% if perms.project.add_post %}<a href="...">New post</a>{% endif %}
#
# `migrate` creates add_/change_/delete_/view_ permissions for every model, plus the ones
# declared with `Meta(permissions = [("publish_post", "Can publish posts")])`. Users get
# permissions directly (`user.user_permissions`) or through groups (`user.groups`).
# Active superusers have every permission.

@model struct Permission
    name = CharField(max_length = 255)
    content_type = ForeignKey(ContentType, on_delete = :CASCADE)
    codename = CharField(max_length = 100)
    Meta(table = "auth_permission", app_label = "auth", unique_together = [(:content_type, :codename)],
         ordering = ["content_type__app_label", "content_type__model", "codename"])
end
Base.show(io::IO, p::Permission) = print(io, p.content_type.app_label, " | ", p.content_type.model, " | ", p.name)
# listing permissions shows their content types: load them in the same query
default_queryset(::Type{Permission}) = select_related(base_objects(Permission), :content_type)

@model struct Group
    name = CharField(max_length = 150, unique = true)
    permissions = ManyToManyField(Permission; blank = true)
    Meta(table = "auth_group", ordering = ["name"], app_label = "auth")
end
Base.show(io::IO, g::Group) = print(io, g.name)

const DEFAULT_PERMISSIONS = ("add", "change", "delete", "view")

"The permission string for an action on a model: `perm_name(Post, :change) == \"project.change_post\"`."
perm_name(T::Type, action) = (m = modelmeta(T); "$(modelmeta(concrete_model(T)).app).$(action)_$(lowercase(m.name))")

"Create missing permissions for every model (run by `migrate`)."
function update_permissions!()
    table_exists(backend(), modelmeta(Permission).table) || return
    for T in MODEL_LIST
        (T <: AutoThrough || !model_in_use(T)) && continue
        m = modelmeta(T)
        ct = get_for_model(T)
        wanted = [(a * "_" * lowercase(m.name), "Can $a $(m.verbose_name)") for a in DEFAULT_PERMISSIONS]
        append!(wanted, [(string(c), string(n)) for (c, n) in get(m.extra, :permissions, [])])
        have = Set(values_list(filter(base_objects(Permission); content_type = ct), :codename; flat = true))
        for (code, name) in wanted
            code in have && continue
            create(Permission; content_type = ct, codename = code, name = name)
            push!(have, code)
        end
    end
end

perm_strings(qs) = Set{String}(string(r[:content_type__app_label], ".", r[:codename])
                               for r in values(qs, :content_type__app_label, :codename))

"Permissions a user has directly, as `\"app.codename\"` strings."
get_user_permissions(u::User) = perm_strings(filter(base_objects(Permission); user_set = u))
"Permissions a user has through groups."
get_group_permissions(u::User) = perm_strings(filter(base_objects(Permission); group_set__user_set = u))

"""
    get_all_permissions(user) -> Set{String}

Everything the user may do (cached on the user object; reload the user after changing
permissions). Superusers get every permission in the database.
"""
function get_all_permissions(u::User)
    u.is_active || return Set{String}()
    get!(getfield(u, :_cache), :_perm_cache) do
        u.is_superuser ? perm_strings(base_objects(Permission)) :
            perm_strings(filter(base_objects(Permission), Q(user_set = u) | Q(group_set__user_set = u)))
    end
end
get_all_permissions(::AnonymousUser) = Set{String}()

"""
    has_perm(user, "app.codename"; obj=nothing) -> Bool

Active superusers have every permission; inactive users have none. Object-level checks
(`obj`) aren't provided by the default rules and return `false` (superusers excepted).
"""
function has_perm(u::User, perm::AbstractString; obj = nothing)
    u.is_active || return false
    u.is_superuser && return true
    obj === nothing || return false
    perm in get_all_permissions(u)
end
has_perm(::AnonymousUser, perm::AbstractString; obj = nothing) = false
has_perm(::Nothing, perm::AbstractString; obj = nothing) = false

"All of the permissions."
has_perms(u, perms; obj = nothing) = all(p -> has_perm(u, p; obj = obj), perms)

"Whether the user has any permission in an app (`has_module_perms(user, \"project\")`)."
function has_module_perms(u::User, app::AbstractString)
    u.is_active || return false
    u.is_superuser && return true
    any(p -> startswith(p, app * "."), get_all_permissions(u))
end
has_module_perms(::Union{AnonymousUser,Nothing}, app::AbstractString) = false

"""
    permission_required(perms...; login_url=nothing, raise_exception=true)(view)
    permission_required(view, perms...)

Require all of `perms`. Anonymous users are sent to the login page; logged-in users
without the permissions get 403 Forbidden (or the login page with `raise_exception=false`).
"""
function permission_required(view, perms::AbstractString...; login_url = nothing, raise_exception = true)
    ps = collect(String, perms)
    w = function (req; kw...)
        u = req.user
        is_authenticated(u) || return redirect_to_login(req, something(login_url, settings.LOGIN_URL))
        if !has_perms(u, ps)
            raise_exception && throw(PermissionDenied("You don't have permission to do this."))
            return redirect_to_login(req, something(login_url, settings.LOGIN_URL))
        end
        view(req; kw...)
    end
    propagate_flags!(w, view)
end
permission_required(perm::AbstractString, perms::AbstractString...; kw...) =
    view -> permission_required(view, perm, perms...; kw...)

# --- templates: {{ perms.app.codename }} -----------------------------------------------------------

"The `perms` template variable."
struct PermWrapper
    user::Any
end
struct PermLookup
    user::Any
    app::String
end
tattr(w::PermWrapper, ::Val{S}) where {S} = PermLookup(w.user, string(S))
tattr(l::PermLookup, ::Val{S}) where {S} = has_perm(l.user, l.app * "." * string(S))
truthy(l::PermLookup) = has_module_perms(l.user, l.app)
Base.in(perm::AbstractString, w::PermWrapper) = has_perm(w.user, perm)
value_in(perm, w::PermWrapper) = (perm isa SafeString && (perm = perm.s); perm isa AbstractString && has_perm(w.user, perm))
