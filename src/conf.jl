# Settings ------------------------------------------------------------------------
#
# Settings live in a global Dict and are accessed through the `settings` proxy:
#
#     configure!(DEBUG=false, DATABASE="site.sqlite3", ROOT_URLCONF=urlpatterns)
#     settings.DEBUG   # => false

const SETTINGS = Dict{Symbol,Any}()

"Hooks run whenever settings change (used to invalidate caches)."
const SETTINGS_CHANGED_HOOKS = Function[]

function default_settings()
    Dict{Symbol,Any}(
        :DEBUG => true,
        :SECRET_KEY => "juango-insecure-change-me-in-production",
        :DATABASE => "db.sqlite3",
        :ROOT_URLCONF => Any[],
        :INSTALLED_APPS => default_installed_apps(),
        :APP_DIRS => true,
        :STATIC_ROOT => "",
        :TEMPLATE_DIRS => String[],
        :STATIC_URL => "/static/",
        :STATIC_DIRS => String[],
        :EMAIL_BACKEND => :smtp,
        :EMAIL_HOST => "localhost",
        :EMAIL_PORT => 25,
        :EMAIL_HOST_USER => "",
        :EMAIL_HOST_PASSWORD => "",
        :EMAIL_USE_TLS => false,
        :EMAIL_USE_SSL => false,
        :EMAIL_TIMEOUT => nothing,
        :EMAIL_FILE_PATH => "",
        :EMAIL_SUBJECT_PREFIX => "[Juango] ",
        :DEFAULT_FROM_EMAIL => "webmaster@localhost",
        :SERVER_EMAIL => "root@localhost",
        :ADMINS => Any[],
        :PASSWORD_RESET_TIMEOUT => 60 * 60 * 24 * 3,
        :PASSWORD_MIN_LENGTH => 8,
        :CACHES => Dict("default" => Dict(:backend => :locmem)),
        :CACHE_MIDDLEWARE_SECONDS => 600,
        :TEMPLATE_CACHE_CHECK_MTIME => true,
        :SESSION_ENGINE => :db,
        :DATABASE_ROUTERS => Any[],
        :DATABASE_POOL_SIZE => 10,
        :DATABASE_POOL_TIMEOUT => 30,
        :CONN_MAX_AGE => 600,
        :CONN_HEALTH_CHECKS => true,
        :USE_TZ => false,
        :TIME_ZONE => "UTC",
        :USE_I18N => true,
        :LANGUAGE_CODE => "en",
        :LANGUAGES => [("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
                       ("nl", "Nederlands"), ("pt", "Português"), ("pt-br", "Português Brasileiro"), ("ja", "日本語"),
                       ("zh-hans", "简体中文"), ("ru", "Русский"), ("ar", "العربية")],
        :LOCALE_PATHS => String[],
        :LANGUAGE_COOKIE_NAME => "juango_language",
        :USE_THOUSAND_SEPARATOR => false,
        :MEDIA_ROOT => "",
        :MEDIA_URL => "/media/",
        :DEFAULT_FILE_STORAGE => nothing,
        :ALLOWED_HOSTS => String["localhost", "127.0.0.1", "[::1]"],
        :APPEND_SLASH => true,
        :MIDDLEWARE => Any[
            SecurityMiddleware,
            SessionMiddleware,
            CommonMiddleware,
            CsrfViewMiddleware,
            AuthenticationMiddleware,
        ],
        :CONTEXT_PROCESSORS => Any[
            cp_request, cp_auth, cp_csrf, cp_messages, cp_static,
        ],
        :LOGIN_URL => "/accounts/login/",
        :LOGIN_REDIRECT_URL => "/",
        :LOGOUT_REDIRECT_URL => "/",
        :SESSION_COOKIE_NAME => "sessionid",
        :SESSION_COOKIE_AGE => 60 * 60 * 24 * 14,
        :SESSION_COOKIE_SECURE => false,
        :CSRF_COOKIE_NAME => "csrftoken",
        :CSRF_COOKIE_SECURE => false,
        :CSRF_TRUSTED_ORIGINS => String[],
        :PASSWORD_ITERATIONS => 260_000,
        :SQL_DEBUG => false,
        :MIGRATIONS_DIR => "migrations",
        :MIGRATION_MODULES => Dict{String,String}(),
        :SITE_NAME => "Juango",
    )
end

function reset_settings!()
    empty!(SETTINGS)
    merge!(SETTINGS, default_settings())
    foreach(h -> h(), SETTINGS_CHANGED_HOOKS)
    nothing
end

"""
    configure!(; kwargs...)

Update settings. Any keyword is accepted; unknown names become custom settings
readable through `settings.NAME`.
"""
function configure!(; kwargs...)
    isempty(SETTINGS) && merge!(SETTINGS, default_settings())
    for (k, v) in kwargs
        SETTINGS[k] = v
    end
    foreach(h -> h(), SETTINGS_CHANGED_HOOKS)
    haskey(kwargs, :INSTALLED_APPS) && installed_apps()       # fail early, and run the apps' ready hooks
    nothing
end

struct SettingsProxy end
"Read-only view of the current settings: `settings.DEBUG`, `settings.DATABASE`, ..."
const settings = SettingsProxy()

function Base.getproperty(::SettingsProxy, k::Symbol)
    isempty(SETTINGS) && merge!(SETTINGS, default_settings())
    haskey(SETTINGS, k) || throw(KeyError("setting $k is not defined"))
    SETTINGS[k]
end
Base.propertynames(::SettingsProxy) = Tuple(keys(SETTINGS))
Base.get(::SettingsProxy, k::Symbol, default) = get(SETTINGS, k, default)
Base.show(io::IO, ::SettingsProxy) = print(io, "Juango.settings(", length(SETTINGS), " values)")
