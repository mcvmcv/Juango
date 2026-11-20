# Authentication -------------------------------------------------------------------------------

"""
    UnicodeUsernameValidator(value)    ASCIIUsernameValidator(value)

Django's username validators (for a field's `validators`): letters of any script (or only
unaccented a-z and A-Z), digits and @/./+/-/_, and nothing after them, not even a newline.
"""
UnicodeUsernameValidator(v) = occursin(r"^[\w.@+-]+\z", v) ||
    gettext("Enter a valid username. This value may contain only letters, numbers, and @/./+/-/_ characters.")
ASCIIUsernameValidator(v) = occursin(r"^[\w.@+-]+\z"a, v) ||
    gettext("Enter a valid username. This value may contain only unaccented lowercase a-z and uppercase A-Z letters, numbers, and @/./+/-/_ characters.")

@abstract_model struct AbstractUser
    # (Django's verbose names and help texts)
    username = CharField(max_length = 150, unique = true, verbose_name = "username",
                         help_text = "Required. 150 characters or fewer. Letters, digits and @/./+/-/_ only.",
                         validators = [UnicodeUsernameValidator],
                         error_messages = Dict("unique" => "A user with that username already exists."))
    password = CharField(max_length = 128, verbose_name = "password")
    email = EmailField(blank = true, verbose_name = "email address")
    first_name = CharField(max_length = 150, blank = true, verbose_name = "first name")
    last_name = CharField(max_length = 150, blank = true, verbose_name = "last name")
    is_staff = BooleanField(default = false, verbose_name = "staff status",
                            help_text = "Designates whether the user can log into this admin site.")
    is_superuser = BooleanField(default = false, verbose_name = "superuser status",
                                help_text = "Designates that this user has all permissions without explicitly assigning them.")
    is_active = BooleanField(default = true, verbose_name = "active",
                             help_text = "Designates whether this user should be treated as active. Unselect this instead of deleting accounts.")
    date_joined = DateTimeField(auto_now_add = true, verbose_name = "date joined")
    last_login = DateTimeField(null = true, blank = true, editable = false, verbose_name = "last login")
    groups = ManyToManyField(:Group; blank = true, related_name = :user_set, verbose_name = "groups",
                             help_text = "The groups this user belongs to. A user will get all permissions granted to each of their groups.")
    user_permissions = ManyToManyField(:Permission; blank = true, related_name = :user_set,
                                       verbose_name = "user permissions", help_text = "Specific permissions for this user.")
    Meta(ordering = ["username"])
end

@doc """
    @abstract_model struct AbstractUser

The fields every user model has (username, password, names, email, the staff/superuser/
active flags, dates, groups and permissions). Juango's `User` extends it; so can your own
user model, selected with `AUTH_USER_MODEL`:

    @model struct Member <: AbstractUser
        phone = CharField(max_length = 20, blank = true)
        Meta(app_label = "accounts")
    end
    configure!(AUTH_USER_MODEL = "accounts.Member")      # or the type itself

Set it before the first `migrate`, and point foreign keys at the user model with
`ForeignKey(USER_MODEL, ...)` so they follow the setting. Users log in with the field
`username_field(Model)` names (`:username`; define a method to use e.g. `:email`).
""" AbstractUser

@model struct User <: AbstractUser
    Meta(table = "auth_user", ordering = ["username"], app_label = "auth")
end
@doc "Juango's user model (the default `AUTH_USER_MODEL`)." User

"""
    get_user_model() -> Type

The user model `AUTH_USER_MODEL` names (a model type or an `"app.Model"` label; `User` by default).
"""
function get_user_model()
    c = USER_MODEL_CACHE[]
    c === nothing || return c
    m = get(settings, :AUTH_USER_MODEL, User)
    T = m isa Type ? m : get_model(string(m))
    T <: AbstractUser || throw(ImproperlyConfigured("AUTH_USER_MODEL must be a model extending AbstractUser, not $T"))
    USER_MODEL_CACHE[] = T
end
const USER_MODEL_CACHE = Ref{Any}(nothing)
push!(SETTINGS_CHANGED_HOOKS, () -> (USER_MODEL_CACHE[] = nothing))
"""
Whether `T` is a user model other than the AUTH_USER_MODEL (Juango's `User` when another one
is chosen): it then has no table, content type or permissions, and no reverse relations.
"""
is_swapped(T) = T isa Type && T <: AbstractUser && T !== get_user_model()

"""
    USER_MODEL

Use as a foreign key target to point at whatever `AUTH_USER_MODEL` is:
`author = ForeignKey(USER_MODEL, on_delete = :CASCADE)`. Migrations record the reference as
swappable, so they work whichever user model a project chooses.
"""
const USER_MODEL = :__user_model__
const USER_MODEL_TABLE = "__user_model__"

"The field a user logs in with (define a method for your user model to change it)."
username_field(::Type) = :username

Base.show(io::IO, u::AbstractUser) = print(io, getproperty(u, username_field(typeof(u))))
tattr(::AbstractUser, ::Val{:is_authenticated}) = true
tattr(::AbstractUser, ::Val{:is_anonymous}) = false
tattr(u::AbstractUser, ::Val{:full_name}) = get_full_name(u)
tattr(u::AbstractUser, ::Val{:get_full_name}) = get_full_name(u)
tattr(u::AbstractUser, ::Val{:get_short_name}) = get_short_name(u)
tattr(u::AbstractUser, ::Val{:get_username}) = get_username(u)

"The value of the user's `username_field` (Django's `get_username()`); `\"\"` for an anonymous user."
get_username(u) = string(getproperty(u, username_field(typeof(u))))
"First and last name, with a space between (Django's `get_full_name()`)."
get_full_name(u) = String(strip(string(getproperty(u, :first_name), " ", getproperty(u, :last_name))))
"The first name (Django's `get_short_name()`)."
get_short_name(u) = string(getproperty(u, :first_name))

"The user of a request that is not logged in."
Base.@kwdef struct AnonymousUser
    id::Nothing = nothing
    pk::Nothing = nothing
    username::String = ""
    is_authenticated::Bool = false
    is_anonymous::Bool = true
    is_staff::Bool = false
    is_superuser::Bool = false
    is_active::Bool = false
end
Base.show(io::IO, ::AnonymousUser) = print(io, "AnonymousUser")
get_username(::AnonymousUser) = ""
get_full_name(::AnonymousUser) = ""
get_short_name(::AnonymousUser) = ""
tattr(u::AnonymousUser, ::Val{:get_username}) = ""
tattr(u::AnonymousUser, ::Val{:get_full_name}) = ""
tattr(u::AnonymousUser, ::Val{:get_short_name}) = ""

is_authenticated(u) = u isa AbstractUser
is_authenticated(req::Request) = req.user isa AbstractUser

"The user's natural key, their `username_field` (Django's); `get_by_natural_key(User, name)` finds them."
natural_key(u::AbstractUser) = (getproperty(u, username_field(typeof(u))),)
get_by_natural_key(T::Type{<:AbstractUser}, name) = get(filter(objects(T), Q(username_field(T) => name)))

"An email address with its domain in lower case (Django's `BaseUserManager.normalize_email`)."
function normalize_email(email)
    email === nothing && return ""
    e = String(email)
    i = findlast('@', e)
    i === nothing ? e : e[1:prevind(e, i)] * "@" * lowercase(e[nextind(e, i):end])
end

"As Django's AbstractUser.clean: the username in NFKC form, the email's domain in lower case."
function clean(u::AbstractUser)
    uf = username_field(typeof(u))
    v = getproperty(u, uf)
    v isa AbstractString && setproperty!(u, uf, normalize_username(v))
    u.email isa AbstractString && (u.email = normalize_email(u.email))
    nothing
end

"Send the user an email (Django's `email_user`); `from_email = nothing` is `DEFAULT_FROM_EMAIL`."
email_user(u::AbstractUser, subject, message, from_email = nothing; kw...) = send_mail(subject, message, from_email, [u.email]; kw...)

# Password hashing and validation live in passwords.jl.

"""
    check_password(user, raw) -> Bool

Whether `raw` is the user's password. A password stored with an older hasher (or weaker
settings than the first of `PASSWORD_HASHERS`) is re-hashed and saved.
"""
check_password(u::AbstractUser, raw::AbstractString) =
    check_password(raw, u.password; setter = r -> (u.id === nothing ? set_password!(u, r) : (set_password!(u, r); save!(u))))

"Set (hash) a user's password. Call `save!(user)` afterwards."
# (the validators hear of it, for a password history: password_changed, as Django's save does)
set_password!(u::AbstractUser, raw::AbstractString) = (u.password = make_password(raw); password_changed(raw; user = u); u)
"Mark the password as unusable."
set_unusable_password!(u::AbstractUser) = (u.password = "!" * random_string(40); u)
has_usable_password(u::AbstractUser) = !startswith(u.password, "!") && identify_hasher(u.password) !== nothing

"""
A username in Unicode's NFKC form, as Django's `normalize_username`: names that look the same
(the ohm sign Ω and the Greek capital omega Ω) are the same name.
"""
normalize_username(s::AbstractString) = Base.Unicode.normalize(String(s), :NFKC)
normalize_username(s) = s

"Create and save a regular user of the `AUTH_USER_MODEL` (`username` fills its `username_field`)."
function create_user(username::AbstractString, password = nothing; kw...)
    if haskey(kw, :password)          # create_user(name; password = "..."), as Django code calls it
        password === nothing || throw(ArgumentError("create_user: the password is given twice"))
        password = kw[:password]
        kw = Dict{Symbol,Any}(k => v for (k, v) in kw if k !== :password)
    end
    isempty(username) && throw(ArgumentError("The given username must be set"))
    haskey(kw, :email) && (kw = merge(Dict{Symbol,Any}(kw), Dict{Symbol,Any}(:email => normalize_email(kw[:email]))))
    T = get_user_model()
    uf = username_field(T)
    username = normalize_username(username)
    u = T(; uf => username, (uf === :username ? () : (:username => username,))..., kw...)
    password === nothing ? set_unusable_password!(u) : set_password!(u, password)
    errs = full_clean(u)
    isempty(errs) || throw(ArgumentError("invalid user: $(errs)"))
    save!(u)
end
"Create and save a user with `is_staff` and `is_superuser` set."
function create_superuser(username::AbstractString, password = nothing; kw...)
    kw = merge(Dict{Symbol,Any}(:is_staff => true, :is_superuser => true), Dict{Symbol,Any}(kw))
    kw[:is_staff] === true || throw(ArgumentError("Superuser must have is_staff=True."))
    kw[:is_superuser] === true || throw(ArgumentError("Superuser must have is_superuser=True."))
    create_user(username, password; kw...)
end

# --- authentication backends -----------------------------------------------------------------
#
# `AUTHENTICATION_BACKENDS` lists backend values (default `[ModelBackend()]`). A backend's type
# has methods of some of these functions; each returns `nothing` when it has no opinion:
#
#     backend_authenticate(b, req; credentials...) -> user or nothing   (throw PermissionDenied to stop)
#     backend_get_user(b, id) -> user or nothing                       (for the session's user id)
#     backend_has_perm(b, user, perm, obj) -> true / false / nothing   (obj: object-level checks)
#     backend_get_user_permissions(b, user, obj), backend_get_group_permissions(b, user, obj),
#     backend_get_all_permissions(b, user, obj) -> Set{String}
#     backend_has_module_perms(b, user, app_label) -> true / false / nothing
#     backend_with_perm(b, perm; is_active, include_superusers, obj) -> users' QuerySet or nothing
#
# The user may be an AnonymousUser or an inactive user: a backend may grant them permissions too.
# Throwing PermissionDenied from backend_has_perm or backend_has_module_perms means no, whatever
# the backends after it say.

backend_authenticate(b, req; kw...) = nothing
backend_get_user(b, id) = nothing
backend_has_perm(b, user, perm, obj) = nothing
backend_get_user_permissions(b, user, obj) = Set{String}()
backend_get_group_permissions(b, user, obj) = Set{String}()
# (by default, as Django's BaseBackend: the user's and the groups' permissions)
backend_get_all_permissions(b, user, obj) = union(Set{String}(backend_get_user_permissions(b, user, obj)),
                                                  Set{String}(backend_get_group_permissions(b, user, obj)))
backend_has_module_perms(b, user, app) = nothing
backend_with_perm(b, perm; kw...) = nothing

"""
    ModelBackend()

The default backend: users of `AUTH_USER_MODEL` log in with their `username_field` and
password, and get the permissions of their groups and their own (not per object). Inactive
users can't log in.
"""
struct ModelBackend end

function backend_authenticate(::ModelBackend, req; password = nothing, kw...)
    T = get_user_model()
    uf = username_field(T)
    name = get(kw, uf, get(kw, :username, nothing))
    (name === nothing || password === nothing) && return nothing
    u = first(filter(objects(T), Q(uf => name)))
    if u === nothing
        make_password(password)   # equalise timing
        return nothing
    end
    ok = check_password(u, password)          # checked for inactive users too, so timing doesn't tell them apart
    u.is_active && ok ? u : nothing
end
backend_get_user(::ModelBackend, id) = first(filter(objects(get_user_model()); id = id, is_active = true))

"""
    AllowAllUsersModelBackend()

ModelBackend that also lets inactive users log in (Django's), for projects that show an inactive
account its own page ("your account is suspended") instead of refusing the login. Inactive users
still have no permissions.
"""
struct AllowAllUsersModelBackend end
function backend_authenticate(::AllowAllUsersModelBackend, req; password = nothing, kw...)
    T = get_user_model()
    uf = username_field(T)
    name = get(kw, uf, get(kw, :username, nothing))
    (name === nothing || password === nothing) && return nothing
    u = first(filter(objects(T), Q(uf => name)))
    u === nothing && (make_password(password); return nothing)
    check_password(u, password) ? u : nothing
end
backend_get_user(::AllowAllUsersModelBackend, id) = first(filter(objects(get_user_model()); id = id))
# (its permissions are ModelBackend's: none for inactive users)
backend_has_perm(::AllowAllUsersModelBackend, u, perm, obj) = backend_has_perm(ModelBackend(), u, perm, obj)
backend_get_user_permissions(::AllowAllUsersModelBackend, u, obj) = backend_get_user_permissions(ModelBackend(), u, obj)
backend_get_group_permissions(::AllowAllUsersModelBackend, u, obj) = backend_get_group_permissions(ModelBackend(), u, obj)
backend_get_all_permissions(::AllowAllUsersModelBackend, u, obj) = backend_get_all_permissions(ModelBackend(), u, obj)
backend_has_module_perms(::AllowAllUsersModelBackend, u, app) = backend_has_module_perms(ModelBackend(), u, app)
backend_with_perm(::AllowAllUsersModelBackend, perm; kw...) = backend_with_perm(ModelBackend(), perm; kw...)

function backend_has_perm(::ModelBackend, u, perm, obj)
    (u isa AbstractUser && u.is_active && obj === nothing) || return nothing
    perm in model_permissions(u) ? true : nothing
end
model_backend_perms(u, obj, which) = obj === nothing ? model_perm_set(u, which) : Set{String}()
backend_get_user_permissions(::ModelBackend, u, obj) = model_backend_perms(u, obj, :_user_perm_cache)
backend_get_group_permissions(::ModelBackend, u, obj) = model_backend_perms(u, obj, :_group_perm_cache)
backend_get_all_permissions(::ModelBackend, u, obj) = model_backend_perms(u, obj, :_perm_cache)
backend_has_module_perms(::ModelBackend, u, app) =
    u isa AbstractUser && u.is_active && any(p -> startswith(p, app * "."), model_permissions(u))
function backend_with_perm(::ModelBackend, perm; is_active = true, include_superusers = true, obj = nothing)
    T = get_user_model()
    obj === nothing || return none(objects(T))
    app, code = perm isa Permission ? (perm.content_type.app_label, perm.codename) : split(perm, '.'; limit = 2)
    ps = filter(base_objects(Permission); codename = code, content_type__app_label = app)
    # (ids from each route, so the joins don't repeat users)
    ids = union(Set(values_list(filter(objects(T); user_permissions__in = ps), :id; flat = true)),
                Set(values_list(filter(objects(T); groups__permissions__in = ps), :id; flat = true)))
    q = Q(id__in = collect(ids))
    include_superusers && (q = q | Q(is_superuser = true))
    qs = filter(objects(T), q)
    is_active === nothing ? qs : filter(qs; is_active = is_active)
end

"""
    RemoteUserBackend(; create_unknown_user = true)
    AllowAllUsersRemoteUserBackend(; create_unknown_user = true)

Trust the user name a front-end server or proxy has authenticated (`RemoteUserMiddleware`
passes it as `remote_user`): the user with that `username_field`, created with an unusable
password if there is none and `create_unknown_user`. Inactive users are refused, except by
`AllowAllUsersRemoteUserBackend`. Permissions as `ModelBackend`.

A backend of your own that is a subtype of `AbstractRemoteUserBackend` (with a
`create_unknown_user` field) can define, as Django's hooks:

    remote_clean_username(b, name)                     # e.g. strip a realm: "alice@EXAMPLE" -> "alice"
    remote_configure_user(b, req, user; created)       # set up the user (created: just made); return it
    remote_user_can_authenticate(b, user)              # default: user.is_active
"""
abstract type AbstractRemoteUserBackend end
Base.@kwdef struct RemoteUserBackend <: AbstractRemoteUserBackend
    create_unknown_user::Bool = true
end
Base.@kwdef struct AllowAllUsersRemoteUserBackend <: AbstractRemoteUserBackend
    create_unknown_user::Bool = true
end
remote_clean_username(b, name) = name
remote_configure_user(b, req, u; created = true) = u
remote_user_can_authenticate(b, u) = u.is_active
remote_user_can_authenticate(::AllowAllUsersRemoteUserBackend, u) = true
function backend_authenticate(b::AbstractRemoteUserBackend, req; remote_user = nothing, kw...)
    remote_user === nothing && return nothing
    isempty(strip(string(remote_user))) && return nothing
    name = String(remote_clean_username(b, strip(string(remote_user))))
    T = get_user_model()
    uf = username_field(T)
    u = first(filter(objects(T), Q(uf => name)))
    created = false
    if u === nothing
        b.create_unknown_user || return nothing
        u = T(; uf => name, (uf === :username ? () : (:username => name,))...)
        set_unusable_password!(u)
        save!(u)
        created = true
    end
    u = remote_configure_user(b, req, u; created = created)
    remote_user_can_authenticate(b, u) ? u : nothing
end
backend_get_user(::AbstractRemoteUserBackend, id) = backend_get_user(ModelBackend(), id)
backend_get_user(::AllowAllUsersRemoteUserBackend, id) = backend_get_user(AllowAllUsersModelBackend(), id)
backend_has_perm(::AbstractRemoteUserBackend, u, perm, obj) = backend_has_perm(ModelBackend(), u, perm, obj)
backend_get_user_permissions(::AbstractRemoteUserBackend, u, obj) = backend_get_user_permissions(ModelBackend(), u, obj)
backend_get_group_permissions(::AbstractRemoteUserBackend, u, obj) = backend_get_group_permissions(ModelBackend(), u, obj)
backend_get_all_permissions(::AbstractRemoteUserBackend, u, obj) = backend_get_all_permissions(ModelBackend(), u, obj)
backend_has_module_perms(::AbstractRemoteUserBackend, u, app) = backend_has_module_perms(ModelBackend(), u, app)
backend_with_perm(::AbstractRemoteUserBackend, perm; kw...) = backend_with_perm(ModelBackend(), perm; kw...)

"""
    RemoteUserMiddleware, PersistentRemoteUserMiddleware

Log in the user a front-end server authenticated, from the `REMOTE_USER_HEADER` request header
(default `Remote-User`), with `RemoteUserBackend` in `AUTHENTICATION_BACKENDS`. Put it after
`AuthenticationMiddleware`. Without the header, `RemoteUserMiddleware` logs out a user that it
logged in; `PersistentRemoteUserMiddleware` keeps the session (for a header sent only on the
login page). The proxy must remove the header from clients' requests, or anyone can send it.
"""
RemoteUserMiddleware(get_response) = remote_user_middleware(get_response; force_logout_if_no_header = true)
PersistentRemoteUserMiddleware(get_response) = remote_user_middleware(get_response; force_logout_if_no_header = false)
# (the backend that logged the session's user in, if it's a remote-user one: only those users are logged out)
function session_remote_backend(req)
    req.session isa Session || return nothing
    bname = get(req.session, "_auth_user_backend", nothing)
    i = bname === nothing ? nothing : findfirst(b -> backend_name(b) == bname, auth_backends())
    i === nothing ? nothing : (b = auth_backends()[i]; b isa AbstractRemoteUserBackend ? b : nothing)
end
function remote_user_middleware(get_response; force_logout_if_no_header::Bool)
    function (req::Request)
        name = header(req, settings.REMOTE_USER_HEADER)
        if name === nothing || isempty(strip(name))
            force_logout_if_no_header && is_authenticated(req.user) && session_remote_backend(req) !== nothing && logout!(req)
            return get_response(req)
        end
        if is_authenticated(req.user)
            b = session_remote_backend(req)
            # (the name as the backend cleans it, as Django's)
            clean = b === nothing ? strip(name) : remote_clean_username(b, strip(name))
            get_username(req.user) == clean && return get_response(req)
            b === nothing || logout!(req)          # another user than the header names
        end
        u = authenticate(req; remote_user = name)
        u === nothing || login!(req, u)
        get_response(req)
    end
end

function auth_backends()
    bs = get(settings, :AUTHENTICATION_BACKENDS, Any[ModelBackend()])
    isempty(bs) && throw(ImproperlyConfigured("No authentication backends have been defined. Does AUTHENTICATION_BACKENDS contain anything?"))
    bs
end
backend_name(b) = string(parentmodule(typeof(b)), ".", nameof(typeof(b)))

"""
    authenticate(req = nothing; credentials...) -> user or nothing
    authenticate(username, password)

Ask each of `AUTHENTICATION_BACKENDS` in turn; the first user one returns is the answer (and
remembers which backend accepted it, for `login!`). A backend that throws `PermissionDenied`
stops the search; one whose `backend_authenticate` method doesn't take these keyword arguments
is skipped (define it with `kw...` to take any).
"""
function authenticate(req = nothing; kw...)
    names = Tuple(keys(kw))
    for b in auth_backends()
        # (a backend whose method doesn't take these credentials is skipped, as Django's)
        hasmethod(backend_authenticate, Tuple{typeof(b),typeof(req)}, names) || continue
        u = try
            backend_authenticate(b, req; kw...)
        catch e
            e isa PermissionDenied || rethrow()
            break
        end
        if u !== nothing
            (getfield(u, :_cache)::Dict{Symbol,Any})[:__auth_backend] = backend_name(b)
            return u
        end
    end
    # (sensitive values replaced by stars, as Django's _clean_credentials)
    creds = Dict{String,Any}(string(k) => occursin(r"api|token|key|secret|pass|signature"i, string(k)) ? "********************" : v
                             for (k, v) in kw)
    has_receivers(user_login_failed, :authenticate) && send(user_login_failed, :authenticate; credentials = creds, request = req)
    nothing
end
authenticate(username::AbstractString, password::AbstractString) = authenticate(nothing; username = username, password = password)
authenticate(::Nothing, ::Any) = nothing
authenticate(::Any, ::Nothing) = nothing

session_auth_hash(u::AbstractUser; key = settings.SECRET_KEY) = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits(key * "auth")), Vector{UInt8}(codeunits(u.password))))

"""
    login!(req, user; backend = nothing)

Log the user in: rotate the session key and remember the user, and the backend that
authenticated them, in the session. A user that `authenticate` didn't return needs `backend` (a
backend or its name) when there are several `AUTHENTICATION_BACKENDS`, as Django's.
"""
function login!(req::Request, u::AbstractUser; backend = nothing)
    s = req.session
    s isa Session || error("login! requires SessionMiddleware")
    bname = login_backend_name(u, backend)
    # (as Django's: another user's session is emptied, not reused; otherwise a new key for the same data)
    if haskey(s, "_auth_user_id")
        (s["_auth_user_id"] != u.id || !consteq(string(get(s, "_auth_user_hash", "")), session_auth_hash(u))) && flush!(s)
    else
        s.key === nothing || cycle_key!(s)
    end
    s["_auth_user_id"] = u.id
    s["_auth_user_backend"] = bname
    s["_auth_user_hash"] = session_auth_hash(u)
    u.last_login = timezone_now()
    save!(u)
    req.user = u
    rotate_csrf_token!(req)
    T = typeof(u)
    has_receivers(user_logged_in, T) && send(user_logged_in, T; request = req, user = u)
    u
end

function login_backend_name(u, backend)
    backend isa AbstractString && return String(backend)
    backend === nothing || return backend_name(backend)
    c = getfield(u, :_cache)::Dict{Symbol,Any}
    haskey(c, :__auth_backend) && return c[:__auth_backend]
    bs = auth_backends()
    length(bs) == 1 || throw(ArgumentError("You have multiple authentication backends configured and therefore must provide the `backend` argument or set the `backend` attribute on the user."))
    backend_name(bs[1])
end

"Log the current user out and flush the session (`user_logged_out` is sent with `user = nothing` for an anonymous one, as Django's)."
function logout!(req::Request)
    u = req.user
    if u isa AbstractUser
        has_receivers(user_logged_out, typeof(u)) && send(user_logged_out, typeof(u); request = req, user = u)
    else
        has_receivers(user_logged_out, Nothing) && send(user_logged_out, Nothing; request = req, user = nothing)
    end
    req.session isa Session && flush!(req.session)
    req.user = AnonymousUser()
    nothing
end

"User for the request's session (from the backend that logged them in), or `AnonymousUser()`."
function get_user(req::Request)
    s = req.session
    s isa Session || return AnonymousUser()
    id = get(s, "_auth_user_id", nothing)
    id === nothing && return AnonymousUser()
    bname = get(s, "_auth_user_backend", nothing)
    i = bname === nothing ? 1 : findfirst(b -> backend_name(b) == bname, auth_backends())
    i === nothing && return AnonymousUser()            # that backend was removed from the settings
    u = backend_get_user(auth_backends()[i], id)
    # (a session from before a key rotation: valid with a SECRET_KEY_FALLBACKS key, and moved to the new one, as Django's)
    u === nothing && return AnonymousUser()
    h = get(s, "_auth_user_hash", "")
    if !consteq(h, session_auth_hash(u))
        any(k -> consteq(h, session_auth_hash(u; key = k)), collect(get(settings, :SECRET_KEY_FALLBACKS, String[]))) ||
            return AnonymousUser()
        s["_auth_user_hash"] = session_auth_hash(u)
    end
    u
end

# --- decorators ------------------------------------------------------------------------------

"The login page, with where to come back to in `redirect_field_name` (\"next\"; `nothing` for no parameter)."
function redirect_to_login(req::Request, login_url = settings.LOGIN_URL; redirect_field_name = "next")
    login_url = resolve_login_url(login_url)            # (a URL name works too)
    redirect_field_name === nothing && return HttpResponseRedirect(login_url)
    # (the page's / left as it is, as Django's: ?next=/secret/)
    HttpResponseRedirect(login_url * (occursin('?', login_url) ? "&" : "?") * string(redirect_field_name) * "=" * replace(urlquote(full_path(req)), "%2F" => "/"))
end

"""
    login_required(view; login_url=settings.LOGIN_URL, redirect_field_name="next")

Wrap a view so anonymous users are redirected to the login page, with the page they asked for in
`?next=` (`redirect_field_name` renames it; `nothing` leaves it out).
"""
function login_required(view; login_url = nothing, redirect_field_name = "next")
    w = function (req; kw...)
        is_authenticated(req.user) ||
            return redirect_to_login(req, something(login_url, settings.LOGIN_URL); redirect_field_name = redirect_field_name)
        view(req; kw...)
    end
    propagate_flags!(w, view)
    LOGIN_REQUIRED_OPTS[w] = (login_url = login_url, redirect_field_name = redirect_field_name)   # (for LoginRequiredMiddleware)
    w
end

"Like `login_required`, but also requires `is_staff`."
function staff_member_required(view; login_url = nothing)
    w = function (req; kw...)
        u = req.user
        (is_authenticated(u) && u.is_staff && u.is_active) ||
            return redirect_to_login(req, something(login_url, reverse_url("admin:login")))
        view(req; kw...)
    end
    propagate_flags!(w, view)
end

"`user_passes_test(view, test)`: redirect to login unless `test(req.user)`."
function user_passes_test(view, test; login_url = nothing, redirect_field_name = "next")
    w = (req; kw...) -> test(req.user) ? view(req; kw...) :
        redirect_to_login(req, something(login_url, settings.LOGIN_URL); redirect_field_name = redirect_field_name)
    propagate_flags!(w, view)
end

# --- built-in auth views -----------------------------------------------------------------------

@form AuthenticationForm begin
    username = CharField(max_length = 150)
    password = CharField(widget = :password, max_length = 4096, strip = false)
end

"""
AuthenticationForm checks the username and password itself, as Django's: an unknown pair is
"Please enter a correct username and password..." and an inactive account (with a backend that
lets it through, AllowAllUsersModelBackend) "This account is inactive."; `get_user(form)` is the
user once it's valid. `confirm_login_allowed(user)` may refuse others: return a message.
"""
function clean_form(f::Form, ::Val{:AuthenticationForm})
    u, p = get(f.cleaned_data, :username, nothing), get(f.cleaned_data, :password, nothing)
    (u === nothing || p === nothing) && return
    user = authenticate(u, p)
    if user === nothing
        U = get_user_model()
        fld = findfield(modelmeta(U), username_field(U))
        return add_error!(f, nothing, interpolate(gettext("Please enter a correct %(username)s and password. Note that both fields may be case-sensitive."),
                                                  Dict("username" => fld === nothing ? "username" : lowercase(label(fld)))))
    end
    user.is_active || return add_error!(f, nothing, gettext("This account is inactive."))
    f.cleaned_data[:_user] = user
end
"The user an AuthenticationForm authenticated (after `is_valid`), or nothing."
get_user(f::Form) = get(f.cleaned_data, :_user, nothing)

"The `next` parameter (or `field`) if it's safe to redirect to (this site), else `fallback`."
function safe_next(req, fallback, field = "next"; extra_hosts = String[])
    field === nothing && return fallback
    n = get(req.GET, field, get(req.POST, field, ""))
    url_has_allowed_host_and_scheme(n, vcat([get_host(req)], collect(String, extra_hosts)); require_https = is_secure(req)) ? n : fallback
end

"""
    LoginView(; template="registration/login.html", redirect_url=settings.LOGIN_REDIRECT_URL)

A login page view. The template gets `form` and `next` (and `redirect_field_name`, the
parameter's name: `next` unless `redirect_field_name` says otherwise).
"""
function LoginView(; template = "registration/login.html", redirect_url = nothing, require_staff = false, redirect_field_name = "next",
                   next_page = nothing, redirect_authenticated_user = false, success_url_allowed_hosts = String[])
    target(req) = safe_next(req, something(next_page === nothing ? nothing : resolve_login_url(next_page), redirect_url, settings.LOGIN_REDIRECT_URL),
                            redirect_field_name; extra_hosts = success_url_allowed_hosts)
    login_not_required(name_view!(function (req::Request; kw...)
        # (redirect_authenticated_user: a logged-in user goes on, unless that's this page: a loop, as Django's)
        if redirect_authenticated_user && is_authenticated(req.user)
            t = target(req)
            t == req.path && throw(ArgumentError("Redirection loop for authenticated user detected. Check that your LOGIN_REDIRECT_URL doesn't point to a login page."))
            return HttpResponseRedirect(t)
        end
        form = AuthenticationForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST"
            valid = is_valid(form)
            u = valid ? get_user(form) : nothing
            if require_staff && !(valid && u !== nothing && u.is_staff)
                (valid || !isempty(get(form.errors, :__all__, String[]))) && (empty!(form.errors); form.validated = true;
                    add_error!(form, nothing, "Please enter the correct username and password for a staff account. Note that both fields may be case-sensitive."))
            elseif valid
                login!(req, u)
                return HttpResponseRedirect(target(req))
            end
        end
        render(req, template, Dict("form" => form, "next" => safe_next(req, "", redirect_field_name),
                                   "redirect_field_name" => redirect_field_name))
    end, "LoginView"))
end

"Log out (POST) and redirect to `settings.LOGOUT_REDIRECT_URL`."
function LogoutView(; redirect_url = nothing, template = nothing, next_page = nothing, redirect_field_name = "next",
                    success_url_allowed_hosts = String[])
    v = function (req::Request; kw...)
        req.method == "POST" || return HttpResponseNotAllowed(["POST"])
        logout!(req)
        # (as Django's: ?next=, then next_page, then LOGOUT_REDIRECT_URL; with none, the logged-out page)
        fallback = something(next_page === nothing ? nothing : resolve_login_url(next_page), redirect_url,
                             # (with a template it's rendered unless something names a page: LOGOUT_REDIRECT_URL defaults to "/")
                             template !== nothing || get(settings, :LOGOUT_REDIRECT_URL, nothing) === nothing ? nothing :
                                 resolve_login_url(settings.LOGOUT_REDIRECT_URL),
                             Some(nothing))
        nxt = safe_next(req, nothing, redirect_field_name; extra_hosts = success_url_allowed_hosts)
        url = something(nxt, fallback, Some(nothing))
        url !== nothing && return HttpResponseRedirect(url)
        template === nothing ? HttpResponseRedirect("/") : render(req, template)
    end
    name_view!(v, "LogoutView")
end

"""
URL patterns for logging in and out and resetting passwords: `path(\"accounts/\", auth_urls())` gives
`login/`, `logout/`, `password_reset/`, `password_reset/done/`, `reset/<uidb64>/<token>/` and `reset/done/`.
"""
auth_urls() = (require_app("auth", "auth_urls()"); include_urls([
    path("login/", LoginView(); name = "login"),
    path("logout/", LogoutView(); name = "logout"),
    path("password_change/", PasswordChangeView(); name = "password_change"),
    path("password_change/done/", PasswordChangeDoneView(); name = "password_change_done"),
    path("password_reset/", login_not_required(PasswordResetView()); name = "password_reset"),
    path("password_reset/done/", login_not_required(template_page("registration/password_reset_done.html", "PasswordResetDoneView")); name = "password_reset_done"),
    path("reset/<str:uidb64>/<str:token>/", login_not_required(PasswordResetConfirmView()); name = "password_reset_confirm"),
    path("reset/done/", login_not_required(template_page("registration/password_reset_complete.html", "PasswordResetCompleteView")); name = "password_reset_complete"),
]))
