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
import HTTP
import SQLite
import DBInterface
import JSON

const VERSION_STRING = "0.1.0"

include("conf.jl")
include("utils.jl")
include("http.jl")
include("urls.jl")
include("template.jl")
include("db.jl")
include("backends/sqlite.jl")
include("backends/postgres.jl")
include("orm.jl")
include("expressions.jl")
include("fields_extra.jl")
include("backends/sqlite_extra.jl")
include("schema.jl")
include("migrations.jl")
include("forms.jl")
include("sessions.jl")
include("auth.jl")
include("contenttypes.jl")
include("messages.jl")
include("middleware.jl")
include("views.jl")
include("handler.jl")
include("server.jl")
include("testclient.jl")
include("admin.jl")
include("management.jl")

# --- public API -------------------------------------------------------------

# settings
export settings, configure!
# http
export Request, HttpResponse, JsonResponse, HttpResponseRedirect, HttpResponsePermanentRedirect,
       HttpResponseNotFound, HttpResponseForbidden, HttpResponseBadRequest, HttpResponseNotAllowed,
       Http404, PermissionDenied, BadRequest, QueryDict, getlist, set_cookie!, delete_cookie!,
       header, setheader!, getheader, text, json_body
# urls
export path, re_path, include_urls, reverse_url, resolve
# templates
export Template, render_to_string, get_template, mark_safe, SafeString, register_filter!,
       register_tag!, tattr, escape_html
# orm
export JSONField, ArrayField, UUIDField, CICharField, IntegerRangeField, DateRangeField, DateTimeRangeField,
       ValueRange, SearchVector, SearchQuery, SearchRank, uuid4, UUID
export ContentType, GenericForeignKey, GenericRelation, get_for_model, model_class
export Model, @model, @abstract_model, OneToOneField, Index, GinIndex, Field, ManyToManyField, add!, remove!, set!, clear!, base_objects, CharField, TextField, EmailField, SlugField, URLField, IntegerField,
       FloatField, BooleanField, DateTimeField, DateField, ForeignKey, Q, QuerySet, objects,
       exclude, order_by, exists, values_list, update!, create, get_or_create, update_or_create,
       save!, refresh!, full_clean, aggregate, none, migrate, makemigrations, showmigrations, sqlmigrate,
       atomic, IntegrityError, select_related, prefetch_related, Prefetch, count_queries, DoesNotExist,
       annotate, F, Value, Count, Sum, Avg, Min, Max, Lower, Upper, Length, Coalesce, Concat, Cast, Now,
       ExtractYear, ExtractMonth, ExtractDay, When, Case, OuterRef, Subquery, Exists, Window, RowNumber,
       Rank, DenseRank, Lag, Lead,
       MultipleObjectsReturned, ProtectedError, get_absolute_url
# forms
export Form, @form, ModelForm, is_valid, add_error!, as_p, cleaned_data, save_m2m!
# auth & sessions
export User, AnonymousUser, authenticate, login!, logout!, create_user, create_superuser,
       set_password!, check_password, make_password, login_required, staff_member_required,
       is_authenticated
# messages
export message!, get_messages
# views & shortcuts
export render, redirect, get_object_or_404, get_list_or_404, TemplateView, RedirectView,
       ListView, DetailView, CreateView, UpdateView, DeleteView, Paginator, page,
       require_http_methods, require_GET, require_POST, csrf_exempt, get_csrf_token
# server, testing, management
export runserver, handle_request, Client, post, request, force_login!, execute_from_command_line,
       startproject
export Admin

function __init__()
    # Type-keyed registries were filled while precompiling; make sure their hashes are valid.
    Base.rehash!(MODEL_REGISTRY)
    Base.rehash!(Admin.REGISTRY)
    reset_settings!()
    Admin.register_builtin!()
end

end # module
