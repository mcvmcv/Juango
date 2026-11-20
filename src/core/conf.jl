# Settings ------------------------------------------------------------------------
#
# Settings live in a global Dict and are accessed through the `settings` proxy:
#
#     configure!(DEBUG=false, DATABASE="site.sqlite3", ROOT_URLCONF=urlpatterns)
#     settings.DEBUG   # => false

const SETTINGS = Dict{Symbol,Any}()
struct NoSetting end
const NO_SETTING = NoSetting()

"Hooks run whenever settings change (used to invalidate caches)."
const SETTINGS_CHANGED_HOOKS = Function[]

function default_settings()
    Dict{Symbol,Any}(
        :DEBUG => true,
        :SECRET_KEY => "juango-insecure-change-me-in-production",
        :SECRET_KEY_FALLBACKS => String[],
        :USE_X_FORWARDED_HOST => false,            # behind a proxy that sets X-Forwarded-Host (get_host)
        :USE_X_FORWARDED_PORT => false,            # and X-Forwarded-Port (get_port)         # old keys still accepted when checking signatures (key rotation)
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
        :USE_BLANK_CHOICE_DASH => false,     # true: "---------" as the empty choice (Django 6.1's transitional setting), else "- Select an option -"
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
        :NPLUSONE => :warn,                            # N+1 queries: :warn (in DEBUG), :raise (tests), false
        :NPLUSONE_THRESHOLD => 5,
        :AUTO_PREFETCH => false,
        :MIGRATION_LINT => :warn,
        :FORM_TEMPLATE_PACK => "plain",                # {% form %} / {% field %}: "plain", "bootstrap5", "tailwind" or your own
        :SERVE_STATIC => false,                        # serve STATIC_ROOT with DEBUG off (hashed, cached, pre-compressed)
        :STATIC_COMPRESS => true,                      # collectstatic writes .gz copies of text files
        :STATIC_MAX_AGE => 60,                         # Cache-Control max-age for static files without a hash in the name
        :STATIC_MAX_MEMORY_FILE => 1_048_576,          # SERVE_STATIC keeps files up to this size in memory                      # unsafe migrations: :warn, :error (fail `check`), false                       # load a foreign key for a whole fetched queryset on first read                      # lazy loads of one relation in one request before it's reported
        :ADMIN_FK_SELECT_LIMIT => 1000,                # admin: a foreign key to a bigger table gets a search (or id) box
    )
end

function reset_settings!()
    empty!(SETTINGS)
    merge!(SETTINGS, default_settings())
    foreach(h -> h(), SETTINGS_CHANGED_HOOKS)
    nothing
end

# --- known settings: misspelled and mistyped ones are reported -----------------------------------------

"Settings Juango reads that have no default (it looks them up with `get(settings, ...)`)."
const OPTIONAL_SETTINGS = Set([:AUTHENTICATION_BACKENDS, :AUTH_PASSWORD_VALIDATORS, :AUTH_USER_MODEL, :DATABASES,
    :FILE_UPLOAD_HANDLERS, :FIXTURE_DIRS, :FORM_RENDERER, :LOGGING, :PASSWORD_HASHERS, :STATICFILES_FINDERS,
    :STATICFILES_STORAGE, :STORAGES, :TASKS, :EXTRA_SETTINGS])
"Settings declared by apps and libraries (`declare_settings!`, `App(...; settings = ...)`): name => default."
const DECLARED_SETTINGS = Dict{Symbol,Any}()

"""
    declare_settings!(:BLOG_PAGE_SIZE => 20, :BLOG_FEED_TITLE => "Blog", :BLOG_API_KEY)

Declare settings of your own, so the `settings.W001` check doesn't report them as unknown. A
`name => default` pair also gives the setting a default, read by `settings.NAME` until
`configure!` sets it; a bare name has none. Apps can declare theirs with `App(...; settings = ...)`;
a project can instead list names in `configure!(EXTRA_SETTINGS = [:MY_SETTING, "MYPREFIX_*"])`.
"""
function declare_settings!(names...)
    for x in names
        x isa Pair ? (DECLARED_SETTINGS[Symbol(x.first)] = x.second) : (DECLARED_SETTINGS[Symbol(x)] = NO_SETTING)
    end
    nothing
end

"Whether `k` is a setting Juango, an app or the project knows (`EXTRA_SETTINGS` entries ending in * are prefixes)."
function is_known_setting(k::Symbol, defaults = default_settings())
    (haskey(defaults, k) || k in OPTIONAL_SETTINGS || haskey(DECLARED_SETTINGS, k)) && return true
    s = string(k)
    for e in get(SETTINGS, :EXTRA_SETTINGS, ())
        e = string(e)
        (endswith(e, '*') ? startswith(s, chop(e)) : s == e) && return true
    end
    false
end

"The Levenshtein distance between two strings."
function edit_distance(a::AbstractString, b::AbstractString)
    a, b = collect(a), collect(b)
    prev = collect(0:length(b))
    for i in 1:length(a)
        cur = similar(prev); cur[1] = i
        for j in 1:length(b)
            cur[j+1] = min(prev[j+1] + 1, cur[j] + 1, prev[j] + (a[i] == b[j] ? 0 : 1))
        end
        prev = cur
    end
    prev[end]
end

"The known setting closest to `k` within `maxdist` edits (or a known name with `k`'s spelling in another case), or nothing."
function closest_setting(k::Symbol; maxdist::Int = 2, defaults = default_settings())
    s = uppercase(string(k))
    best, bestd = nothing, maxdist + 1
    for n in Iterators.flatten((keys(defaults), OPTIONAL_SETTINGS, keys(DECLARED_SETTINGS)))
        n === k && continue
        d = edit_distance(s, string(n))
        d < bestd && ((best, bestd) = (n, d))
    end
    best
end

"Settings warned about already (once per name)."
const WARNED_SETTINGS = Set{Symbol}()

"""
    settings_issues() -> Vector{Tuple{Symbol,String,String,Union{Nothing,String}}}

The problems the `settings` system check reports: unknown names (`settings.W001`, with the closest
known one), and values of the wrong type for DEBUG and the other true/false settings
(`settings.E001`), list settings given a string (`settings.E002`), number settings given a string
(`settings.E003`) and DATABASE / DATABASES (`settings.E004`), each as (level, message, id, hint).
"""
function settings_issues()
    defaults = default_settings()
    out = Tuple{Symbol,String,String,Union{Nothing,String}}[]
    for (k, v) in SETTINGS
        if !is_known_setting(k, defaults)
            c = closest_setting(k; maxdist = 3, defaults = defaults)
            push!(out, (:warning, "Unknown setting $k" * (c === nothing ? "." : ": did you mean $c?"), "settings.W001",
                        c === nothing ? "If it's a setting of your own, declare it: declare_settings!(:$k) or EXTRA_SETTINGS = [:$k]." : nothing))
            continue
        end
        haskey(defaults, k) || continue
        d = defaults[k]
        if d isa Bool && !(v isa Bool) && k !== :ACCESS_LOG
            push!(out, (:error, "$k must be true or false, not $(repr(v)).", "settings.E001",
                        v isa AbstractString ? "Read it with env(\"$k\", Bool), which understands \"true\", \"1\", \"off\", ..." : nothing))
        elseif d isa AbstractVector && v isa AbstractString
            push!(out, (:error, "$k must be a list, not the string $(repr(v)).", "settings.E002",
                        "Write [$(repr(v))]; a string is read as a list of its characters."))
        elseif d isa Integer && !(d isa Bool) && v isa AbstractString
            push!(out, (:error, "$k must be a number, not the string $(repr(v)).", "settings.E003",
                        "Read it with env(\"$k\", Int)."))
        end
    end
    dbs = Any[("DATABASE", get(SETTINGS, :DATABASE, nothing))]
    x = get(SETTINGS, :DATABASES, nothing)
    x isa AbstractDict && append!(dbs, [("DATABASES[$(repr(a))]", u) for (a, u) in x])
    x === nothing || x isa AbstractDict ||
        push!(out, (:error, "DATABASES must be a Dict of alias => database, not $(typeof(x)).", "settings.E004", nothing))
    for (name, u) in dbs
        u === nothing && continue
        msg = database_setting_issue(u)
        msg === nothing || push!(out, (:error, "$name: $msg", "settings.E004", nothing))
    end
    out
end
# (database_setting_issue is in db/connection.jl)

function warn_misspelled_settings(kwargs)
    get(SETTINGS, :DEBUG, false) === true || return
    defaults = nothing
    for (k, _) in kwargs
        k in WARNED_SETTINGS && continue
        defaults === nothing && (defaults = default_settings())
        is_known_setting(k, defaults) && continue
        c = closest_setting(k; defaults = defaults)
        c === nothing && continue
        push!(WARNED_SETTINGS, k)
        @warn "Unknown setting $k: did you mean $c? (declare_settings!(:$k) if it's yours)"
    end
end

"""
    configure!(; kwargs...)

Update settings. Any keyword is accepted: names Juango doesn't know are custom settings,
readable through `settings.NAME`. When DEBUG is on, a name a letter or two away from a known one
(`DEBG`, `ALLOWED_HOST`) gets a warning, and `manage.jl check` reports every unknown name
(`settings.W001`; declare your own with `declare_settings!` or `EXTRA_SETTINGS`).
"""
configure!(; kwargs...) = apply_settings!(kwargs, true)

"Set settings (`enter = false` when override_settings restores them, for `setting_changed`)."
function apply_settings!(kwargs, enter::Bool)
    isempty(SETTINGS) && merge!(SETTINGS, default_settings())
    for (k, v) in kwargs
        SETTINGS[k] = v
    end
    enter && warn_misspelled_settings(kwargs)
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
    d = get(DECLARED_SETTINGS, k, NO_SETTING)
    d === NO_SETTING || return d
    throw(KeyError("setting $k is not defined"))
end
Base.propertynames(::SettingsProxy) = Tuple(keys(SETTINGS))
function Base.get(::SettingsProxy, k::Symbol, default)
    v = get(SETTINGS, k, NO_SETTING)
    v === NO_SETTING || return v
    d = get(DECLARED_SETTINGS, k, NO_SETTING)
    d === NO_SETTING ? default : d
end
Base.show(io::IO, ::SettingsProxy) = print(io, "Juango.settings(", length(SETTINGS), " values)")
