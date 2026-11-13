# The benchmark app in Django (the Juango one is in ../juango): see ../README.md.
import os
from pathlib import Path
from urllib.parse import urlparse

BASE_DIR = Path(__file__).resolve().parent.parent
SECRET_KEY = "benchmark-only-not-secret"
DEBUG = False
ALLOWED_HOSTS = ["127.0.0.1", "localhost"]

INSTALLED_APPS = [
    "django.contrib.admin", "django.contrib.auth", "django.contrib.contenttypes",
    "django.contrib.sessions", "django.contrib.messages", "benchapp",
]
# Juango's default middleware, plus MessageMiddleware, which Django's admin requires
MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.auth.middleware.AuthenticationMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
]
ROOT_URLCONF = "benchproj.urls"
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "DIRS": [BASE_DIR.parent / "templates"],
    "APP_DIRS": True,
    "OPTIONS": {"context_processors": [
        "django.template.context_processors.request",
        "django.contrib.auth.context_processors.auth",
        "django.contrib.messages.context_processors.messages",
    ]},
}]
WSGI_APPLICATION = "benchproj.wsgi.application"

_db = os.environ.get("BENCH_DB", str(BASE_DIR.parent / "data" / "django.sqlite3"))
if _db.startswith("postgres"):
    u = urlparse(_db)
    DATABASES = {"default": {"ENGINE": "django.db.backends.postgresql", "NAME": u.path.lstrip("/"),
                             "USER": u.username or "", "PASSWORD": u.password or "",
                             "HOST": u.hostname or "", "PORT": str(u.port or ""), "CONN_MAX_AGE": None}}
else:
    DATABASES = {"default": {"ENGINE": "django.db.backends.sqlite3", "NAME": _db, "CONN_MAX_AGE": None}}
# Under ASGI Django's docs advise against persistent connections (each sync view runs in a new thread)
if os.environ.get("BENCH_ASGI"):
    DATABASES["default"]["CONN_MAX_AGE"] = 0
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
USE_TZ = True
TIME_ZONE = "UTC"
STATIC_URL = "static/"
