"""
    Juango

A Django-inspired web framework for Julia.

Batteries included: URL routing, a Django-compatible template language, an ORM on
pluggable database backends (SQLite built in), forms, sessions, authentication, CSRF protection, middleware, messages,
generic views, an automatic admin, a test client and a management CLI.
"""
module Juango

using Dates
using Random
using Base64
using Printf
using SHA
using UUIDs
import Sockets
import Serialization
import TimeZones
import HTTP
import URIs
import CodecZlib
using PrecompileTools: @setup_workload, @compile_workload
import Reseau
using Reseau: TCP, TLS
import SQLite
import DBInterface
import JSON
import Markdown
import TOML

const VERSION_STRING = "0.1.0"

# Files are included in dependency order; the folders group them by topic.
const ASSETS_DIR = joinpath(@__DIR__, "assets")     # built-in templates, translations, migrations, data

# core: settings, helpers, apps, HTTP basics, URLs, templates, translations
include("core/conf.jl")
include("core/utils.jl")
include("core/decimal.jl")
include("core/durations.jl")
include("core/checks.jl")
include("core/apps.jl")
include("http/http.jl")
include("core/logging.jl")
include("http/urls.jl")
include("template/engine.jl")
include("template/tags.jl")
include("template/filters.jl")
include("template/templatetags.jl")
include("i18n/i18n.jl")
include("core/signals.jl")
include("core/signing.jl")

# database layer and ORM
include("db/connection.jl")
include("db/backends/sqlite.jl")
include("db/backends/postgres.jl")
include("db/backends/mysql.jl")
include("i18n/timezones.jl")
include("template/humanize.jl")
include("db/orm/fields.jl")
include("db/orm/models.jl")
include("db/orm/values.jl")
include("db/orm/lookups.jl")
include("db/orm/compiler.jl")
include("db/orm/queryset.jl")
include("db/orm/bulk.jl")
include("db/orm/instances.jl")
include("db/orm/m2m.jl")
include("db/expressions.jl")
include("db/datefunctions.jl")
include("db/functions.jl")
include("db/foreignobject.jl")
include("db/fields_extra.jl")
include("contrib/gis.jl")
include("core/files.jl")
include("db/schema.jl")
include("db/constraints.jl")
# backend methods for the field types and schema changes defined above
include("db/backends/sqlite_features.jl")
include("db/backends/mysql_features.jl")
include("db/historical.jl")
include("db/migrations/Migrations.jl")

# forms
include("forms/forms.jl")
include("forms/formsets.jl")
include("forms/media.jl")

# sessions, auth and the apps they need
include("contrib/sessions.jl")
include("contrib/auth/passwords.jl")
include("contrib/auth/auth.jl")
include("contrib/contenttypes.jl")
include("contrib/auth/permissions.jl")
include("contrib/admin/log.jl")
include("core/mail.jl")
include("contrib/auth/passwordreset.jl")
include("contrib/messages.jl")
include("contrib/htmx.jl")

# request handling, views and the server
include("http/middleware.jl")
include("http/security.jl")
include("http/views.jl")
include("http/streaming.jl")
include("contrib/live.jl")
include("contrib/sitemaps.jl")
include("contrib/feeds.jl")
include("core/cache.jl")
include("http/httpcache.jl")
include("http/handler.jl")
include("http/server.jl")
include("testing/client.jl")
include("testing/testing.jl")

# contrib apps and tools
include("contrib/admin/admin.jl")
include("contrib/flatpages.jl")
include("contrib/sites.jl")
include("contrib/admin/docs.jl")
include("contrib/tasks.jl")
include("core/async.jl")
include("db/serializers.jl")
include("db/fixtureformats.jl")
include("db/dbtools.jl")
include("contrib/staticfiles.jl")
include("i18n/jscatalog.jl")
include("core/management.jl")
include("core/build.jl")

include("api.jl")           # exports, public names, Juango.Testing / GIS / Postgres
include("precompile.jl")    # last: the workload needs the exports above

function __init__()
    # Type-keyed registries were filled while precompiling; make sure their hashes are valid.
    Base.rehash!(MODEL_REGISTRY)
    Base.rehash!(Admin.REGISTRY)
    reset_settings!()
    Admin.register_builtin!()
end

end # module
