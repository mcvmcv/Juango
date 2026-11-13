# Applications ---------------------------------------------------------------------------------------------
#
# An app bundles models, views, URLs, templates, static files, translations, migrations and
# management commands, and a project installs it as a unit:
#
#     module Blog                                   # blog/Blog.jl, made by `manage.jl startapp blog`
#     using Juango
#     const APP = App("blog"; mod = @__MODULE__, path = @__DIR__, ready = () -> connect!(post_save, ...))
#     include("models.jl"); include("views.jl"); include("urls.jl"); include("admin.jl")
#     end
#
#     configure!(INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes",
#                                  "juango.sessions", "juango.messages", Blog.APP], ...)
#     urlpatterns = [path("blog/", include_urls(Blog.APP)), ...]
#
# Models defined in an app's module get its label (`blog.Post`), and with it migrations in
# `blog/migrations/`, content types and permission names. With APP_DIRS (the default) each app's
# `templates/`, `static/` and `locale/` directories are searched after the project's own.

"""
    App(label; mod=nothing, path=nothing, verbose_name, ready=nothing, urls=nothing,
        commands=Dict(), requires=String[], name=label)

An installable application. `path` is its directory (holding `templates/`, `static/`,
`locale/`, `migrations/`); `mod` the module its models are defined in; `ready()` runs once,
when the app is installed (connect signals there); `urls` are patterns for
`include_urls(app)`; `commands` maps names to `(help, args -> ...)` for `manage.jl`;
`requires` lists apps that must be installed too.
"""
mutable struct App
    label::String
    name::String
    verbose_name::String
    mod::Union{Nothing,Module}
    path::Union{Nothing,String}
    ready::Any
    urls::Any
    commands::Dict{String,Tuple{String,Function}}
    requires::Vector{String}
    is_ready::Bool
    default_auto_field::Any     # nothing (settings.DEFAULT_AUTO_FIELD), or :AutoField / :BigAutoField / :SmallAutoField
end

"Every app defined so far, by label (INSTALLED_APPS may name them by label or name)."
const APP_DEFS = Dict{String,App}()
"Modules whose models belong to an app."
const MODULE_APPS = IdDict{Module,String}()

function App(label::AbstractString; mod = nothing, path = nothing, verbose_name = nothing, ready = nothing, urls = nothing,
             commands = Dict{String,Tuple{String,Function}}(), requires = String[], name = label, default_auto_field = nothing)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", label) || throw(ImproperlyConfigured("app label '$label' must be a valid identifier"))
    cmds = Dict{String,Tuple{String,Function}}(string(k) => (string(v[1]), v[2]) for (k, v) in commands)
    a = App(String(label), String(name), something(verbose_name, titlecase(replace(String(label), "_" => " "))),
            mod, path === nothing ? nothing : abspath(string(path)), ready, urls, cmds, String[string(r) for r in requires], false,
            default_auto_field)
    APP_DEFS[a.label] = a
    mod === nothing || (MODULE_APPS[mod] = a.label)
    a
end
Base.show(io::IO, a::App) = print(io, "<App: ", a.label, ">")

# Juango's own apps. Each owns its models (auth.User, sessions.SessionRecord, ...) and their
# migrations (src/migrations/<label>/); an app left out of INSTALLED_APPS gets no tables,
# URLs or commands.
const ADMIN_APP = App("admin"; name = "juango.admin", verbose_name = "Administration", requires = ["auth", "contenttypes", "sessions", "messages"])
const AUTH_APP = App("auth"; name = "juango.auth", verbose_name = "Authentication and Authorization", requires = ["contenttypes"])
const CONTENTTYPES_APP = App("contenttypes"; name = "juango.contenttypes", verbose_name = "Content Types")
const SESSIONS_APP = App("sessions"; name = "juango.sessions", verbose_name = "Sessions")
const MESSAGES_APP = App("messages"; name = "juango.messages", verbose_name = "Messages")
const BUILTIN_APPS = (ADMIN_APP, AUTH_APP, CONTENTTYPES_APP, SESSIONS_APP, MESSAGES_APP)
default_installed_apps() = Any["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages"]

is_builtin(a::App) = any(b -> b === a, BUILTIN_APPS) || a.label in ("flatpages", "sites", "redirects", "admindocs", "tasks")
"Labels of Juango's own apps (flatpages, sites and redirects are defined in their own files)."
const BUILTIN_LABELS = ("admin", "auth", "contenttypes", "sessions", "messages", "flatpages", "sites", "redirects", "tasks")

"""
Whether a model takes part in migrations, content types and permissions: models of Juango's
own apps only while their app is installed; every other model always.
"""
model_in_use(T) = (a = modelmeta(T).app; (!(a in BUILTIN_LABELS) || is_installed(a)) && !is_swapped(T) && !swapped_through(T))
"The join model of a swapped user model's many-to-many fields."
swapped_through(T) = T <: AutoThrough && any(f -> f.kind === :fk && is_swapped(related_model(f)), modelmeta(T).fields)

const INSTALLED = Ref{Union{Nothing,Vector{App}}}(nothing)
const APPS_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> (INSTALLED[] = nothing), APPS_LOCK))

function resolve_app(x)
    x isa App && return x
    if x isa Module
        for a in values(APP_DEFS)
            a.mod === x && return a
        end
        isdefined(x, :APP) && getfield(x, :APP) isa App && return getfield(x, :APP)
        dir = pkgdir(x)
        dir === nothing && throw(ImproperlyConfigured("module $x has no `const APP = App(...)`; define one to install it"))
        return App(lowercase(string(nameof(x))); mod = x, path = dir, name = string(nameof(x)))
    end
    s = string(x)
    haskey(APP_DEFS, s) && return APP_DEFS[s]
    for a in values(APP_DEFS)
        a.name == s && return a
    end
    throw(ImproperlyConfigured("INSTALLED_APPS: no app named '$s' (define it with App(\"$s\"; ...) first)"))
end

"""
    installed_apps() -> Vector{App}

The apps in INSTALLED_APPS, in order. Their `ready` hooks have run.
"""
function installed_apps()
    apps = INSTALLED[]
    apps === nothing || return apps
    apps = lock(APPS_LOCK) do
        INSTALLED[] === nothing || return INSTALLED[]
        list = App[resolve_app(x) for x in get(settings, :INSTALLED_APPS, default_installed_apps())]
        seen = Set{String}()
        for a in list
            a.label in seen && throw(ImproperlyConfigured("INSTALLED_APPS: the label '$(a.label)' is used twice"))
            push!(seen, a.label)
        end
        INSTALLED[] = list
    end
    for a in apps
        if !a.is_ready
            a.is_ready = true
            a.ready === nothing || a.ready()
        end
    end
    apps
end

"Whether an app (by label, name, `App` or module) is installed."
function is_installed(x)
    a = try
        resolve_app(x)
    catch
        return false
    end
    any(b -> b === a, installed_apps())
end

"The installed app with this label (or name)."
function get_app(x)
    a = resolve_app(x)
    any(b -> b === a, installed_apps()) || throw(ImproperlyConfigured("app '$(a.label)' is not in INSTALLED_APPS"))
    a
end

"Throw unless the app is installed: for features of an optional app."
require_app(label, feature) = is_installed(label) ||
    throw(ImproperlyConfigured("$feature needs \"juango.$label\" in INSTALLED_APPS"))

"The app label for models defined in `m` (or a module inside it), if it belongs to an app."
function module_app_label(m::Module)
    while true
        haskey(MODULE_APPS, m) && return MODULE_APPS[m]
        p = parentmodule(m)
        p === m && return nothing
        m = p
    end
end

app_dir(a::App, sub) = a.path === nothing ? nothing : (d = joinpath(a.path, sub); isdir(d) ? d : nothing)
app_dirs(sub) = get(settings, :APP_DIRS, true) ? String[d for d in (app_dir(a, sub) for a in installed_apps()) if d !== nothing] : String[]

"Static directories: STATIC_DIRS, then each installed app's `static/`."
static_dirs() = vcat(String[abspath(string(d)) for d in settings.STATIC_DIRS], app_dirs("static"))
app_locale_dirs() = app_dirs("locale")

"Management commands: Juango's own, plus those of installed apps."
function all_commands()
    cmds = copy(COMMANDS)
    for a in installed_apps()
        merge!(cmds, a.commands)
    end
    cmds
end

"Include an app's URL patterns, namespaced by its label: `path(\"blog/\", include_urls(Blog.APP))`."
function include_urls(a::App; namespace = a.label)
    a.urls === nothing && throw(ImproperlyConfigured("app '$(a.label)' has no urls"))
    include_urls(a.urls isa Function ? a.urls() : a.urls; namespace = namespace)
end

"Problems with INSTALLED_APPS: missing requirements, middleware whose app is not installed."
function app_issues()
    issues = String[]
    apps = try
        installed_apps()
    catch e
        return [sprint(showerror, e)]
    end
    labels = Set(a.label for a in apps)
    for a in apps, r in a.requires
        r in labels || push!(issues, "App '$(a.label)' requires '$r' in INSTALLED_APPS.")
    end
    for (mw, app) in MIDDLEWARE_APPS
        any(m -> m === mw, settings.MIDDLEWARE) && !(app in labels) &&
            push!(issues, "$(nameof(mw)) is in MIDDLEWARE but \"juango.$app\" is not in INSTALLED_APPS.")
    end
    for a in apps
        a.path === nothing || isdir(a.path) || push!(issues, "App '$(a.label)': directory '$(a.path)' does not exist.")
    end
    issues
end
"Middleware => the app it needs (filled in where the middleware are defined)."
const MIDDLEWARE_APPS = Pair{Any,String}[]

# --- models by app ---------------------------------------------------------------------------------------

"`\"app.Model\"`, e.g. `\"blog.Post\"` (Juango's own models are `juango.User` etc.)."
model_label(T::Type) = modelmeta(T).app * "." * modelmeta(T).name
model_label(obj) = model_label(typeof(obj))

"The model registered under `\"app.Model\"` (the model name is case-insensitive)."
function get_model(label::AbstractString)
    app, _, name = rpartition(label, '.')
    for T in all_models()
        m = modelmeta(T)
        (m.app == app && lowercase(m.name) == lowercase(name)) && return T
    end
    throw(ImproperlyConfigured("no model '$label'"))
end
rpartition(s, c) = (i = findlast(c, s); i === nothing ? ("", "", String(s)) : (String(s[1:prevind(s, i)]), string(c), String(s[nextind(s, i):end])))

"The models of an app (by label or `App`)."
app_models(a::App) = app_models(a.label)
app_models(label::AbstractString) = Type[T for T in all_models() if modelmeta(T).app == label]
