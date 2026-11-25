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
# (natural keys, as Django's: a permission by codename, app label and model; a group by name)
natural_key(p::Permission) = (p.codename, p.content_type.app_label, p.content_type.model)
get_by_natural_key(::Type{Permission}, codename, app_label, model) =
    get(Permission; codename = codename, content_type = get_by_natural_key(ContentType, app_label, model))
# listing permissions shows their content types: load them in the same query
default_queryset(::Type{Permission}) = select_related(base_objects(Permission), :content_type)

@model struct Group
    name = CharField(max_length = 150, unique = true)
    permissions = ManyToManyField(Permission; blank = true)
    Meta(table = "auth_group", ordering = ["name"], app_label = "auth")
end
Base.show(io::IO, g::Group) = print(io, g.name)
natural_key(g::Group) = (g.name,)
get_by_natural_key(::Type{Group}, name) = get(Group; name = name)

const DEFAULT_PERMISSIONS = ("add", "change", "delete", "view")

"The permission string for an action on a model: `perm_name(Post, :change) == \"project.change_post\"`."
perm_name(T::Type, action) = (m = modelmeta(T); "$(modelmeta(concrete_model(T)).app).$(action)_$(lowercase(m.name))")

"Create missing permissions for every model (run by `migrate`), or for these models."
function update_permissions!(models = MODEL_LIST)
    table_exists(backend(), modelmeta(Permission).table) || return
    for T in models
        (T <: AutoThrough || !model_in_use(T)) && continue
        m = modelmeta(T)
        ct = get_for_model(T)
        actions = String.(collect(get(m.extra, :default_permissions, DEFAULT_PERMISSIONS)))    # Meta(default_permissions = (...))
        wanted = [(a * "_" * lowercase(m.name), "Can $a $(m.verbose_name)") for a in actions]
        append!(wanted, [(string(c), string(n)) for (c, n) in get(m.extra, :permissions, [])])
        have = Set(values_list(filter(base_objects(Permission); content_type = ct), :codename; flat = true))
        for (code, name) in wanted
            code in have && continue
            create(Permission; content_type = ct, codename = code, name = name)
            push!(have, code)
        end
    end
end

# --- the auth app's system checks (Django's auth.E002-E012, auth.W004) ------------------------------

"""
The auth app's checks, as Django's: the user model's `username_field` must be unique (auth.E003, or
the warning auth.W004 with authentication backends other than ModelBackend alone) and not one of its
`required_fields` (auth.E002); permission names and codenames must fit their columns (auth.E007,
E008, E011, E012) and not repeat a built-in or another custom one (auth.E005, E006).
Returns `(level, message, id, hint)` tuples.
"""
function auth_check_issues(models = MODEL_LIST)
    out = Tuple{Symbol,String,String,Union{Nothing,String}}[]
    U = try get_user_model() catch; nothing end
    if U !== nothing && any(T -> T === U, models)
        uf = username_field(U)
        label = "$(nameof(U)).$uf"
        if uf in required_fields(U)
            push!(out, (:error, "The field named as the 'USERNAME_FIELD' for a custom user model must not be included in 'REQUIRED_FIELDS'.",
                        "auth.E002", "The 'USERNAME_FIELD' is currently set to '$uf', you should remove '$uf' from the 'REQUIRED_FIELDS'."))
        end
        f = findfield(modelmeta(U), uf)
        alone = c -> c isa UniqueConstraint && c.fields == [uf] && c.condition === nothing && isempty(c.expressions)
        unique = f !== nothing && (f.unique || f.primary_key || any(alone, model_constraints(U)) ||
                                   any(u -> u == [uf], modelmeta(U).unique_together))
        if !unique
            bs = get(settings, :AUTHENTICATION_BACKENDS, Any[ModelBackend()])
            if length(bs) == 1 && only(bs) isa ModelBackend
                push!(out, (:error, "'$label' must be unique because it is named as the 'USERNAME_FIELD'.", "auth.E003", nothing))
            else
                push!(out, (:warning, "'$label' is named as the 'USERNAME_FIELD', but it is not unique.", "auth.W004",
                            "Ensure that your authentication backend(s) can handle non-unique usernames."))
            end
        end
    end
    name_max, code_max = 255, 100
    for T in models
        (T <: AutoThrough || !model_in_use(T)) && continue
        m = modelmeta(T)
        label = "$(m.app).$(nameof(T))"
        actions = String.(collect(get(m.extra, :default_permissions, DEFAULT_PERMISSIONS)))
        builtin = Set(a * "_" * lowercase(m.name) for a in actions)
        if !isempty(actions)
            vmax = name_max - maximum(length("Can $a ") for a in actions)
            length(m.verbose_name) > vmax &&
                push!(out, (:error, "The verbose_name of model '$label' must be at most $vmax characters for its builtin permission names to be at most $name_max characters.", "auth.E007", nothing))
            cmax = code_max - maximum(length("$(a)_") for a in actions)
            length(lowercase(m.name)) > cmax &&
                push!(out, (:error, "The name of model '$label' must be at most $cmax characters for its builtin permission codenames to be at most $code_max characters.", "auth.E011", nothing))
        end
        seen = Set{String}()
        for (code, name) in get(m.extra, :permissions, [])
            code, name = string(code), string(name)
            length(name) > name_max &&
                push!(out, (:error, "The permission named '$name' of model '$label' is longer than $name_max characters.", "auth.E008", nothing))
            length(code) > code_max &&
                push!(out, (:error, "The permission codenamed '$code' of model '$label' is longer than $code_max characters.", "auth.E012", nothing))
            if code in builtin
                push!(out, (:error, "The permission codenamed '$code' clashes with a builtin permission for model '$label'.", "auth.E005", nothing))
            elseif code in seen
                push!(out, (:error, "The permission codenamed '$code' is duplicated for model '$label'.", "auth.E006", nothing))
            end
            push!(seen, code)
        end
    end
    out
end

perm_strings(qs) = Set{String}(string(r[:content_type__app_label], ".", r[:codename])
                               for r in values(qs, :content_type__app_label, :codename))

# ModelBackend's permissions, each set cached on the user object, as Django's (reload the user after a change);
# superusers get every one; inactive users and per-object checks none.
function model_perm_set(u, which::Symbol)
    (u isa AbstractUser && u.is_active) || return Set{String}()
    get!((getfield(u, :_cache)::Dict{Symbol,Any}), which) do
        u.is_superuser ? perm_strings(base_objects(Permission)) :
        which === :_user_perm_cache ? perm_strings(filter(base_objects(Permission); user_set = u)) :
        which === :_group_perm_cache ? perm_strings(filter(base_objects(Permission); group_set__user_set = u)) :
            union(model_perm_set(u, :_user_perm_cache), model_perm_set(u, :_group_perm_cache))
    end
end
"The permissions of a user's groups and their own; superusers get every one."
model_permissions(u::AbstractUser) = model_perm_set(u, :_perm_cache)

# (each asks every backend, as Django's PermissionsMixin; a backend throwing PermissionDenied stops it: no)
function perms_from_backends(f, u, obj)
    out = Set{String}()
    for b in auth_backends()
        union!(out, Set{String}(f(b, u, obj)))
    end
    out
end

"Permissions a user has directly, as `\"app.codename\"` strings (from every backend)."
get_user_permissions(u::Union{AbstractUser,AnonymousUser}; obj = nothing) = perms_from_backends(backend_get_user_permissions, u, obj)
"Permissions a user has through groups (from every backend)."
get_group_permissions(u::Union{AbstractUser,AnonymousUser}; obj = nothing) = perms_from_backends(backend_get_group_permissions, u, obj)

"""
    get_all_permissions(user; obj = nothing) -> Set{String}

Everything the user may do, as far as `AUTHENTICATION_BACKENDS` say (ModelBackend's are cached on
the user object; reload the user after changing permissions). ModelBackend gives inactive and
anonymous users none, and has no per-object permissions; a backend of your own may.
"""
get_all_permissions(u::Union{AbstractUser,AnonymousUser}; obj = nothing) = perms_from_backends(backend_get_all_permissions, u, obj)

"""
    has_perm(user, "app.codename"; obj = nothing) -> Bool

Active superusers have every permission. Otherwise the user has it if a backend says so
(`backend_has_perm`); a backend that throws `PermissionDenied` ends the search with no, as
Django's. The default `ModelBackend` gives inactive users nothing and has no per-object rules,
so with `obj` (or for an anonymous or inactive user) only a backend of your own can grant it.
"""
function has_perm(u::Union{AbstractUser,AnonymousUser}, perm::AbstractString; obj = nothing)
    u.is_active && u.is_superuser && return true
    ask_backends(b -> backend_has_perm(b, u, perm, obj))
end
has_perm(::Nothing, perm::AbstractString; obj = nothing) = false
function ask_backends(f)
    for b in auth_backends()
        r = try
            f(b)
        catch e
            e isa PermissionDenied || rethrow()
            return false
        end
        r === true && return true
    end
    false
end

"All of the permissions (a list: one name on its own is an error, as Django's)."
function has_perms(u, perms; obj = nothing)
    perms isa AbstractString && throw(ArgumentError("perm_list must be an iterable of permissions."))
    all(p -> has_perm(u, p; obj = obj), perms)
end

"Whether the user has any permission in an app (`has_module_perms(user, \"project\")`): active superusers, or a backend says so."
function has_module_perms(u::Union{AbstractUser,AnonymousUser}, app::AbstractString)
    u.is_active && u.is_superuser && return true
    ask_backends(b -> backend_has_module_perms(b, u, app))
end
has_module_perms(::Nothing, app::AbstractString) = false

"""
    with_perm(perm; is_active = true, include_superusers = true, backend = nothing, obj = nothing) -> QuerySet

The users with a permission (`"app.codename"` or a `Permission`), as a backend sees it (Django's
`UserManager.with_perm`): ModelBackend's are those granted it directly or through a group, and the
superusers unless `include_superusers = false`; only active users, or only inactive ones with
`is_active = false`, or both with `nothing`. With several `AUTHENTICATION_BACKENDS`, say which
(a backend or its name); a backend without `backend_with_perm` finds no one.
"""
function with_perm(perm; is_active = true, include_superusers = true, backend = nothing, obj = nothing)
    perm isa Union{AbstractString,Permission} || throw(ArgumentError("The `perm` argument must be a string or a permission instance."))
    perm isa AbstractString && count('.', perm) != 1 &&
        throw(ArgumentError("Permission name should be in the form app_label.permission_codename."))
    bs = auth_backends()
    b = if backend === nothing
        length(bs) == 1 || throw(ArgumentError("You have multiple authentication backends configured and therefore must provide the `backend` argument."))
        bs[1]
    elseif backend isa AbstractString
        i = findfirst(x -> backend_name(x) == backend, bs)
        i === nothing ? throw(ArgumentError("No authentication backend named '$backend' in AUTHENTICATION_BACKENDS.")) : bs[i]
    else
        backend
    end
    r = backend_with_perm(b, perm; is_active = is_active, include_superusers = include_superusers, obj = obj)
    r === nothing ? none(objects(get_user_model())) : r
end

"""
    permission_required(perms...; login_url=nothing, raise_exception=true)(view)
    permission_required(view, perms...)

Require all of `perms`. Anonymous users are sent to the login page; logged-in users
without the permissions get 403 Forbidden (or the login page with `raise_exception=false`).
"""
function permission_required(view, perms::AbstractString...; login_url = nothing, raise_exception = true, redirect_field_name = "next")
    ps = collect(String, perms)
    w = function (req; kw...)
        u = req.user
        is_authenticated(u) || return redirect_to_login(req, something(login_url, settings.LOGIN_URL); redirect_field_name = redirect_field_name)
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
"`permission_required([\"app.a\", \"app.b\"])`: the permissions as a list, as Django takes them."
permission_required(perms::AbstractVector; kw...) = view -> permission_required(view, String.(perms)...; kw...)

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
# (as Django's: "auth" in perms is any permission in the app, "auth.add_user" in perms that one;
# "add_user" in perms.auth is auth.add_user)
Base.in(perm::AbstractString, w::PermWrapper) = occursin('.', perm) ? has_perm(w.user, perm) : has_module_perms(w.user, perm)
Base.in(perm::AbstractString, l::PermLookup) = has_perm(l.user, l.app * "." * perm)
value_in(perm, w::Union{PermWrapper,PermLookup}) = (perm isa SafeString && (perm = perm.s); perm isa AbstractString && perm in w)
Base.show(io::IO, l::PermLookup) = print(io, "PermLookup(", repr(l.app), ")")
Base.iterate(::PermWrapper) = throw(ArgumentError("PermWrapper is not iterable."))
