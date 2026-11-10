using Juango
using Dates

const BASE_DIR = @__DIR__

include(joinpath(BASE_DIR, "models.jl"))
include(joinpath(BASE_DIR, "forms.jl"))
include(joinpath(BASE_DIR, "views.jl"))
include(joinpath(BASE_DIR, "urls.jl"))
include(joinpath(BASE_DIR, "admin.jl"))
include(joinpath(BASE_DIR, "commands.jl"))

configure!(
    DEBUG = get(ENV, "JUANGO_DEBUG", "true") == "true",
    SECRET_KEY = get(ENV, "JUANGO_SECRET_KEY", "dev-only-not-secret"),
    DATABASE = get(ENV, "BLOG_DB", joinpath(BASE_DIR, "db.sqlite3")),
    ROOT_URLCONF = urlpatterns,
    TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
    STATIC_DIRS = [joinpath(BASE_DIR, "static")],
    LOGIN_URL = "/accounts/login/",
    SITE_NAME = "Juango Blog",
)
