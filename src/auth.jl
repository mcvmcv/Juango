# Authentication -------------------------------------------------------------------------------

@abstract_model struct AbstractUser
    username = CharField(max_length = 150, unique = true,
                         help_text = "Required. 150 characters or fewer. Letters, digits and @/./+/-/_ only.",
                         validators = [v -> occursin(r"^[\w.@+-]+$", v) || gettext("Enter a valid username.")])
    password = CharField(max_length = 128)
    email = EmailField(blank = true)
    first_name = CharField(max_length = 150, blank = true)
    last_name = CharField(max_length = 150, blank = true)
    is_staff = BooleanField(default = false, help_text = "Designates whether the user can log into the admin site.")
    is_superuser = BooleanField(default = false)
    is_active = BooleanField(default = true)
    date_joined = DateTimeField(auto_now_add = true)
    last_login = DateTimeField(null = true, blank = true, editable = false)
    groups = ManyToManyField(:Group; blank = true, related_name = :user_set,
                             help_text = "The user gets every permission of these groups.")
    user_permissions = ManyToManyField(:Permission; blank = true, related_name = :user_set,
                                       verbose_name = "User permissions")
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
tattr(u::AbstractUser, ::Val{:full_name}) = strip(u.first_name * " " * u.last_name)

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

is_authenticated(u) = u isa AbstractUser
is_authenticated(req::Request) = req.user isa AbstractUser

# --- password hashing (PBKDF2-SHA256, Django-compatible format) ------------------------------

function pbkdf2_sha256(password::AbstractVector{UInt8}, salt::AbstractVector{UInt8}, iterations::Int)
    password = Vector{UInt8}(password)
    u = hmac_sha256(password, vcat(salt, UInt8[0, 0, 0, 1]))
    t = copy(u)
    for _ in 2:iterations
        u = hmac_sha256(password, u)
        t .⊻= u
    end
    t
end

"""
    make_password(raw) -> String

Hash a password as `pbkdf2_sha256\$iterations\$salt\$hash` (the same format
Django uses, so hashes are interchangeable).
"""
function make_password(raw::AbstractString; iterations = settings.PASSWORD_ITERATIONS, salt = random_string(22))
    dk = pbkdf2_sha256(codeunits(raw), codeunits(salt), iterations)
    "pbkdf2_sha256\$$iterations\$$salt\$$(base64encode(dk))"
end

"Check a raw password against an encoded hash (or a `User`)."
function check_password(raw::AbstractString, encoded::AbstractString)
    parts = split(encoded, '$')
    (length(parts) == 4 && parts[1] == "pbkdf2_sha256") || return false
    iters = tryparse(Int, parts[2])
    iters === nothing && return false
    dk = pbkdf2_sha256(codeunits(raw), codeunits(parts[3]), iters)
    consteq(base64encode(dk), parts[4])
end
check_password(u::AbstractUser, raw::AbstractString) = check_password(raw, u.password)

"Set (hash) a user's password. Call `save!(user)` afterwards."
set_password!(u::AbstractUser, raw::AbstractString) = (u.password = make_password(raw); u)
"Mark the password as unusable."
set_unusable_password!(u::AbstractUser) = (u.password = "!" * random_string(40); u)
has_usable_password(u::AbstractUser) = startswith(u.password, "pbkdf2_sha256\$")

"Create and save a regular user of the `AUTH_USER_MODEL` (`username` fills its `username_field`)."
function create_user(username::AbstractString, password = nothing; kw...)
    T = get_user_model()
    uf = username_field(T)
    u = T(; uf => username, (uf === :username ? () : (:username => username,))..., kw...)
    password === nothing ? set_unusable_password!(u) : set_password!(u, password)
    errs = full_clean(u)
    isempty(errs) || throw(ArgumentError("invalid user: $(errs)"))
    save!(u)
end
"Create and save a user with `is_staff` and `is_superuser` set."
create_superuser(username::AbstractString, password = nothing; kw...) =
    create_user(username, password; is_staff = true, is_superuser = true, kw...)

# --- authentication backends -----------------------------------------------------------------
#
# `AUTHENTICATION_BACKENDS` lists backend values (default `[ModelBackend()]`). A backend's type
# has methods of some of these functions; each returns `nothing` when it has no opinion:
#
#     backend_authenticate(b, req; credentials...) -> user or nothing   (throw PermissionDenied to stop)
#     backend_get_user(b, id) -> user or nothing                       (for the session's user id)
#     backend_has_perm(b, user, perm, obj) -> true / false / nothing   (obj: object-level checks)
#     backend_get_all_permissions(b, user, obj) -> Set{String}

backend_authenticate(b, req; kw...) = nothing
backend_get_user(b, id) = nothing
backend_has_perm(b, user, perm, obj) = nothing
backend_get_all_permissions(b, user, obj) = Set{String}()

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
    u.is_active && check_password(u, password) ? u : nothing
end
backend_get_user(::ModelBackend, id) = first(filter(objects(get_user_model()); id = id, is_active = true))
function backend_has_perm(::ModelBackend, u, perm, obj)
    (u isa AbstractUser && u.is_active && obj === nothing) || return nothing
    perm in model_permissions(u) ? true : nothing
end
backend_get_all_permissions(::ModelBackend, u, obj) =
    u isa AbstractUser && u.is_active && obj === nothing ? model_permissions(u) : Set{String}()

auth_backends() = get(settings, :AUTHENTICATION_BACKENDS, Any[ModelBackend()])
backend_name(b) = string(parentmodule(typeof(b)), ".", nameof(typeof(b)))

"""
    authenticate(req = nothing; credentials...) -> user or nothing
    authenticate(username, password)

Ask each of `AUTHENTICATION_BACKENDS` in turn; the first user one returns is the answer (and
remembers which backend accepted it, for `login!`). A backend that throws `PermissionDenied`
stops the search.
"""
function authenticate(req = nothing; kw...)
    for b in auth_backends()
        u = try
            backend_authenticate(b, req; kw...)
        catch e
            e isa PermissionDenied || rethrow()
            break
        end
        if u !== nothing
            getfield(u, :_cache)[:__auth_backend] = backend_name(b)
            return u
        end
    end
    creds = Dict{String,Any}(string(k) => v for (k, v) in kw if !occursin(r"pass|token|secret|key"i, string(k)))
    has_receivers(user_login_failed, :authenticate) && send(user_login_failed, :authenticate; credentials = creds, request = req)
    nothing
end
authenticate(username::AbstractString, password::AbstractString) = authenticate(nothing; username = username, password = password)
authenticate(::Nothing, ::Any) = nothing
authenticate(::Any, ::Nothing) = nothing

session_auth_hash(u::AbstractUser) = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits(settings.SECRET_KEY * "auth")), Vector{UInt8}(codeunits(u.password))))

"""
    login!(req, user; backend = nothing)

Log the user in: rotate the session key and remember the user, and the backend that
authenticated them, in the session.
"""
function login!(req::Request, u::AbstractUser; backend = nothing)
    s = req.session
    s isa Session || error("login! requires SessionMiddleware")
    bname = backend !== nothing ? backend_name(backend) :
            get(getfield(u, :_cache), :__auth_backend, backend_name(first(auth_backends())))
    if get(s, "_auth_user_id", nothing) != u.id
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

"Log the current user out and flush the session."
function logout!(req::Request)
    u = req.user
    u isa AbstractUser && has_receivers(user_logged_out, typeof(u)) && send(user_logged_out, typeof(u); request = req, user = u)
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
    (u === nothing || !consteq(get(s, "_auth_user_hash", ""), session_auth_hash(u))) && return AnonymousUser()
    u
end

# --- decorators ------------------------------------------------------------------------------

redirect_to_login(req::Request, login_url = settings.LOGIN_URL) =
    HttpResponseRedirect(login_url * (occursin('?', login_url) ? "&" : "?") * "next=" * urlquote(full_path(req)))

"""
    login_required(view; login_url=settings.LOGIN_URL)

Wrap a view so anonymous users are redirected to the login page.
"""
function login_required(view; login_url = nothing)
    w = function (req; kw...)
        is_authenticated(req.user) || return redirect_to_login(req, something(login_url, settings.LOGIN_URL))
        view(req; kw...)
    end
    propagate_flags!(w, view)
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
function user_passes_test(view, test; login_url = nothing)
    w = (req; kw...) -> test(req.user) ? view(req; kw...) : redirect_to_login(req, something(login_url, settings.LOGIN_URL))
    propagate_flags!(w, view)
end

# --- built-in auth views -----------------------------------------------------------------------

@form AuthenticationForm begin
    username = CharField(max_length = 150)
    password = CharField(widget = :password, max_length = 4096)
end

safe_next(req, fallback) = (n = get(req.GET, "next", get(req.POST, "next", "")); startswith(n, "/") && !startswith(n, "//") ? n : fallback)

"""
    LoginView(; template="registration/login.html", redirect_url=settings.LOGIN_REDIRECT_URL)

A login page view. The template gets `form` and `next`.
"""
function LoginView(; template = "registration/login.html", redirect_url = nothing, require_staff = false)
    name_view!(function (req::Request; kw...)
        form = AuthenticationForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form)
            u = authenticate(form.cleaned_data[:username], form.cleaned_data[:password])
            if u === nothing || (require_staff && !u.is_staff)
                add_error!(form, nothing, require_staff ?
                    "Please enter the correct username and password for a staff account. Note that both fields may be case-sensitive." :
                    "Please enter a correct username and password. Note that both fields may be case-sensitive.")
            else
                login!(req, u)
                return HttpResponseRedirect(safe_next(req, something(redirect_url, settings.LOGIN_REDIRECT_URL)))
            end
        end
        render(req, template, Dict("form" => form, "next" => safe_next(req, "")))
    end, "LoginView")
end

"Log out (POST) and redirect to `settings.LOGOUT_REDIRECT_URL`."
function LogoutView(; redirect_url = nothing, template = nothing)
    v = function (req::Request; kw...)
        req.method == "POST" || return HttpResponseNotAllowed(["POST"])
        logout!(req)
        template === nothing ? HttpResponseRedirect(safe_next(req, something(redirect_url, settings.LOGOUT_REDIRECT_URL))) :
                               render(req, template)
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
    path("password_reset/", PasswordResetView(); name = "password_reset"),
    path("password_reset/done/", template_page("registration/password_reset_done.html", "PasswordResetDoneView"); name = "password_reset_done"),
    path("reset/<str:uidb64>/<str:token>/", PasswordResetConfirmView(); name = "password_reset_confirm"),
    path("reset/done/", template_page("registration/password_reset_complete.html", "PasswordResetCompleteView"); name = "password_reset_complete"),
]))
