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
        :DATA_UPLOAD_MAX_MEMORY_SIZE => 2_621_440,     # bytes of a non-multipart body (nothing: no limit)
        :DATA_UPLOAD_MAX_NUMBER_FIELDS => 1000,        # GET + POST parameters (nothing: no limit)
        :DATA_UPLOAD_MAX_NUMBER_FILES => 100,            # files in one multipart request (nothing: no limit)
        :SERVER_READ_HEADER_TIMEOUT => 10,             # runserver: seconds a client may take to send its headers (slow clients)
        :SERVER_IDLE_TIMEOUT => 120,                   # runserver: seconds a kept-alive connection may wait for its next request
        :SERVER_READ_TIMEOUT => nothing,               # runserver: seconds to read a whole request, body included (nothing: no limit)
        :FILE_UPLOAD_MAX_SIZE => 100 * 1024 * 1024,    # bytes of a multipart (file upload) body (nothing: no limit)
        :MANAGERS => Any[],
        :IGNORABLE_404_URLS => Any[],
        :PASSWORD_RESET_TIMEOUT => 60 * 60 * 24 * 3,
        :PASSWORD_MIN_LENGTH => 8,
        :CACHES => Dict("default" => Dict(:backend => :locmem)),
        :CACHE_MIDDLEWARE_SECONDS => 600,
        :TEMPLATE_CACHE_CHECK_MTIME => nothing,        # read templates again when they change (nothing: only with DEBUG)
        :HTMX_OOB_MESSAGES => true,                    # after htmx requests, send queued messages as an out-of-band swap
        :ACCESS_LOG => true,                           # runserver prints a line to stderr for each request
        :LIVE_MAX_STATE_BYTES => 1_000_000,            # live views: a view's size (Base.summarysize) past which it's closed
        :LIVE_MAX_VIEWS_PER_SESSION => 20,             # live views open at once per session
        :LIVE_MAX_VIEWS => 10_000,                     # live views open at once in this process
        :LIVE_MAX_MESSAGE_BYTES => 262_144,            # one message from the browser
        :LIVE_MAX_UPLOAD_BYTES => 10_485_760,          # one file uploaded over a live view's socket
        :LIVE_SNAPSHOT_MAX_AGE => 3600,                # seconds a reconnecting browser's state snapshot stays valid
        :LIVE_PUBSUB => nothing,                       # nothing: publish in this process; :postgres: to every process, by LISTEN/NOTIFY
        :TEST_DATABASE => nothing,                     # the test runner's database (nothing: SQLite in memory, or test_<name> on the same server)
        :TEMPLATE_COMPILE => nothing,                  # compile templates into Julia functions, in the background (nothing: when DEBUG is off; :eager: on first render)
        :TEMPLATES => nothing,                         # template engines (nothing: Juango's, with TEMPLATE_DIRS)
        :TEMPLATE_STRING_IF_INVALID => "",             # what unknown variables render as ("%s" is the name)
        :SITE_ID => 1,
        :SESSION_ENGINE => :db,
        :SESSION_FILE_PATH => nothing,
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
        :DATE_INPUT_FORMATS => nothing,                # strftime formats forms accept, for languages without their own (nothing: Django's English ones)
        :DATETIME_INPUT_FORMATS => nothing,            # nothing: each date format, with each time format
        :TIME_INPUT_FORMATS => nothing,                # nothing: %H:%M:%S, %H:%M:%S.%f, %H:%M
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
            HtmxMiddleware,
        ],
        :CONTEXT_PROCESSORS => Any[
            cp_request, cp_auth, cp_csrf, cp_messages, cp_static, cp_csp,
        ],
        :SECURE_SSL_REDIRECT => false,
        :SECURE_SSL_HOST => nothing,
        :SECURE_REDIRECT_EXEMPT => String[],
        :SECURE_PROXY_SSL_HEADER => nothing,
        :SECURE_HSTS_SECONDS => 0,
        :SECURE_HSTS_INCLUDE_SUBDOMAINS => false,
        :SECURE_HSTS_PRELOAD => false,
        :SECURE_CONTENT_TYPE_NOSNIFF => true,
        :SECURE_REFERRER_POLICY => "same-origin",
        :SECURE_CROSS_ORIGIN_OPENER_POLICY => "same-origin",
        :X_FRAME_OPTIONS => "DENY",
        :SECURE_CSP => Dict{String,Any}(),
        :SECURE_CSP_REPORT_ONLY => Dict{String,Any}(),
        :LOGIN_URL => "/accounts/login/",
        :LOGIN_REDIRECT_URL => "/",
        :LOGOUT_REDIRECT_URL => "/",
        :SESSION_COOKIE_NAME => "sessionid",
        :SESSION_COOKIE_AGE => 60 * 60 * 24 * 14,
        :SESSION_COOKIE_SECURE => false,
        :CSRF_COOKIE_NAME => "csrftoken",
        :CSRF_COOKIE_SECURE => false,
        :CSRF_COOKIE_HTTPONLY => false,
        :CSRF_COOKIE_SAMESITE => "Lax",
        :CSRF_COOKIE_DOMAIN => nothing,
        :CSRF_COOKIE_PATH => "/",
        :CSRF_COOKIE_AGE => 60 * 60 * 24 * 365,
        :CSRF_HEADER_NAME => "X-CSRFToken",                # also Django's spelling, HTTP_X_CSRFTOKEN
        :CSRF_USE_SESSIONS => false,                        # the secret in the session instead of a cookie
        :CSRF_FAILURE_VIEW => nothing,                      # a view (req; reason) -> response for CSRF failures (403)
        :MESSAGE_STORAGE => :session,                       # :session, :cookie or :fallback (the cookie ones need MessageMiddleware)
        :MESSAGE_LEVEL => 20,                               # messages below this level (info) are dropped
        :MESSAGE_TAGS => Dict{Int,String}(),                # level => CSS tag, added to or replacing debug/info/success/warning/error
        :CSRF_TRUSTED_ORIGINS => String[],
        :PASSWORD_ITERATIONS => 260_000,
        :SQL_DEBUG => false,
        :INTERNAL_IPS => String[],                     # addresses shown the debug toolbar (when DEBUG)
        :DEBUG_TOOLBAR_SHOW => nothing,                # nothing: DEBUG and an INTERNAL_IPS client; or a function req -> Bool
        :DEBUG_TOOLBAR_PREFIX => "/__debug__/",        # the history of recorded requests
        :DEBUG_TOOLBAR_HISTORY => 25,                  # how many recorded requests to keep
        :DEBUG_TOOLBAR_STACKTRACES => true,            # where each query came from (costs a backtrace per query)
        :MIGRATIONS_DIR => "migrations",
        :DEFAULT_AUTO_FIELD => :BigAutoField,               # the automatic primary key: AutoField, BigAutoField or SmallAutoField
        :REMOTE_USER_HEADER => "Remote-User",             # RemoteUserMiddleware's header (set only by your proxy)
        :SILENCED_SYSTEM_CHECKS => String[],           # check ids to leave out ("security.W004", ...)
        :ATOMIC_REQUESTS => false,                     # true (the default database) or database aliases: each view in a transaction
        :HANDLER400 => nothing, :HANDLER403 => nothing, :HANDLER404 => nothing, :HANDLER500 => nothing,   # custom error views
        :FILE_UPLOAD_MAX_MEMORY_SIZE => 2_621_440,     # bigger uploads go to temporary files
        :FILE_UPLOAD_TEMP_DIR => nothing,              # nothing: the system's temporary directory
        :FILE_UPLOAD_PERMISSIONS => 0o644,             # mode of uploaded files saved by FileSystemStorage (nothing: leave it)
        :FILE_UPLOAD_DIRECTORY_PERMISSIONS => nothing, # mode of directories it creates
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
configure!(; kwargs...) = apply_settings!(kwargs, true)

"Set settings (`enter = false` when override_settings restores them, for `setting_changed`)."
function apply_settings!(kwargs, enter::Bool)
    isempty(SETTINGS) && merge!(SETTINGS, default_settings())
    for (k, v) in kwargs
        SETTINGS[k] = v
    end
    foreach(h -> h(), SETTINGS_CHANGED_HOOKS)
    haskey(kwargs, :INSTALLED_APPS) && installed_apps()       # fail early, and run the apps' ready hooks
    if any_receivers(setting_changed)
        for (k, v) in kwargs
            send(setting_changed, :settings; setting = k, value = v, enter = enter)
        end
    end
    nothing
end

struct SettingsProxy end
"Read-only view of the current settings: `settings.DEBUG`, `settings.DATABASE`, ..."
const settings = SettingsProxy()

function Base.getproperty(::SettingsProxy, k::Symbol)
    v = get(SETTINGS, k, NO_SETTING)
    v === NO_SETTING || return v
    isempty(SETTINGS) && (merge!(SETTINGS, default_settings()); return getproperty(settings, k))
    throw(KeyError("setting $k is not defined"))
end
struct NoSetting end
const NO_SETTING = NoSetting()
Base.propertynames(::SettingsProxy) = Tuple(keys(SETTINGS))
Base.get(::SettingsProxy, k::Symbol, default) = get(SETTINGS, k, default)
Base.show(io::IO, ::SettingsProxy) = print(io, "Juango.settings(", length(SETTINGS), " values)")
