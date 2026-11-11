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
using PrecompileTools: @setup_workload, @compile_workload
import Reseau
using Reseau: TCP, TLS
import SQLite
import DBInterface
import JSON

const VERSION_STRING = "0.1.0"

include("conf.jl")
include("utils.jl")
include("apps.jl")
include("http.jl")
include("urls.jl")
include("template.jl")
include("templatetags.jl")
include("i18n.jl")
include("signals.jl")
include("db.jl")
include("backends/sqlite.jl")
include("backends/postgres.jl")
include("backends/mysql.jl")
include("timezones.jl")
include("orm.jl")
include("expressions.jl")
include("fields_extra.jl")
include("gis.jl")
include("files.jl")
include("backends/sqlite_extra.jl")
include("schema.jl")
include("constraints.jl")
include("backends/mysql_extra.jl")
include("migrations.jl")
include("forms.jl")
include("formsets.jl")
include("sessions.jl")
include("auth.jl")
include("contenttypes.jl")
include("permissions.jl")
include("adminlog.jl")
include("mail.jl")
include("passwordreset.jl")
include("messages.jl")
include("middleware.jl")
include("views.jl")
include("streaming.jl")
include("sitemaps.jl")
include("feeds.jl")
include("cache.jl")
include("handler.jl")
include("server.jl")
include("testclient.jl")
include("admin.jl")
include("flatpages.jl")
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
       register_tag!, tattr, escape_html, TagLibrary, simple_tag!, inclusion_tag!, tag!, TemplateSyntaxError
# orm
export GeometryField, PointField, LineStringField, PolygonField, MultiPointField, MultiLineStringField, MultiPolygonField,
       Point, LineString, Polygon, MultiPoint, MultiLineString, MultiPolygon, D, Distance, Area, GeoLength, AsGeoJSON,
       geojson, from_geojson, wkt, ewkt, parse_wkt, parse_wkb
export FileField, ImageField, UploadedFile, FieldFile, FileSystemStorage, FileExtensionValidator, MaxFileSizeValidator,
       save_file, delete_file, image_size, default_storage
export JSONField, ArrayField, UUIDField, CICharField, IntegerRangeField, DateRangeField, DateTimeRangeField,
       ValueRange, SearchVector, SearchQuery, SearchRank, uuid4, UUID
export gettext, ngettext, pgettext, npgettext, gettext_lazy, ngettext_lazy, pgettext_lazy, @t_str, get_language,
       activate!, deactivate!, with_language, LocaleMiddleware, i18n_patterns, set_language, i18n_urls, number_format,
       localize, interpolate, language_name, makemessages, compilemessages
export timezone_now, activate_timezone!, deactivate_timezone!, with_timezone, get_current_timezone, make_aware,
       make_naive, localtime, is_aware, TimezoneMiddleware, convert_naive_datetimes
export Signal, connect!, disconnect!, receiver, send, send_robust, has_receivers, pre_save, post_save, pre_delete,
       post_delete, m2m_changed, request_started, request_finished, user_logged_in, user_logged_out, user_login_failed
export cache, cache_get, cache_set, cache_add, cache_delete, cache_has, cache_clear, get_or_set, cache_get_many,
       cache_set_many, incr, decr, incr_version, cache_page, CacheMiddleware, create_cache_table
export EmailMessage, EmailMultiAlternatives, send!, send_mail, mail_admins, attach!, attach_alternative!, outbox,
       signing_dumps, signing_loads, sign_value, unsign_value, BadSignature, SignatureExpired,
       PasswordResetView, PasswordResetConfirmView, make_reset_token, check_reset_token
export LogEntry, log_action!, ADDITION, CHANGE, DELETION
export Permission, Group, has_perm, has_perms, has_module_perms, get_all_permissions, permission_required, perm_name
export ContentType, GenericForeignKey, GenericRelation, get_for_model, model_class
export CheckConstraint, UniqueConstraint, GeneratedField, DB_DEFAULT, CompositePrimaryKey
export Model, @model, @abstract_model, OneToOneField, Index, GinIndex, Field, ManyToManyField, add!, remove!, set!, clear!, base_objects, CharField, TextField, EmailField, SlugField, URLField, IntegerField,
       FloatField, BooleanField, DateTimeField, DateField, ForeignKey, Q, QuerySet, objects,
       exclude, order_by, exists, values_list, update!, create, get_or_create, update_or_create,
       save!, refresh!, full_clean, aggregate, none, migrate, makemigrations, showmigrations, sqlmigrate,
       atomic, IntegrityError, PoolTimeout, pool_status, select_related, prefetch_related, Prefetch, count_queries, DoesNotExist,
       annotate, F, Value, Count, Sum, Avg, Min, Max, Lower, Upper, Length, Coalesce, Concat, Cast, Now,
       ExtractYear, ExtractMonth, ExtractDay, When, Case, OuterRef, Subquery, Exists, Window, RowNumber,
       Rank, DenseRank, Lag, Lead,
       MultipleObjectsReturned, ProtectedError, get_absolute_url,
       defer, distinct, latest, earliest, in_bulk, dates, datetimes, raw, explain, deferred_fields,
       bulk_create, bulk_update, iterator, select_for_update, intersection, difference, TransactionManagementError
# forms
export Form, @form, ModelForm, is_valid, add_error!, as_p, cleaned_data, save_m2m!, has_changed, changed_fields,
       FormSet, formset_factory, modelformset_factory, inlineformset_factory, management_form, empty_form,
       deleted_forms, ordered_forms
# auth & sessions
export User, AnonymousUser, authenticate, login!, logout!, create_user, create_superuser,
       set_password!, check_password, make_password, login_required, staff_member_required,
       is_authenticated
# messages
export message!, get_messages
# views & shortcuts
export FormView, ArchiveIndexView, YearArchiveView, MonthArchiveView, DayArchiveView, DateDetailView, ViewCall, default_hook,
       LoginRequiredMixin, PermissionRequiredMixin, UserPassesTestMixin
export render, redirect, get_object_or_404, get_list_or_404, TemplateView, RedirectView,
       ListView, DetailView, CreateView, UpdateView, DeleteView, Paginator, page,
       require_http_methods, require_GET, require_POST, csrf_exempt, get_csrf_token
# server, testing, management
export Sitemap, sitemap_urls, sitemap_view, sitemap_index_view, Feed
export FlatPage, FlatpageFallbackMiddleware, flatpage, flatpage_urls
export StreamingHttpResponse, FileResponse, EventStreamResponse, sse_event, sse_comment, websocket, WebSocketView,
       ws_send, ws_receive, ws_close, ws_isopen, is_streaming
export runserver, handle_request, Client, post, request, force_login!, execute_from_command_line,
       startproject, startapp, collectstatic
export App, installed_apps, is_installed, get_app, get_model, model_label, app_models, static_dirs
export Admin

include("precompile.jl")    # last: the workload needs the exports above

function __init__()
    # Type-keyed registries were filled while precompiling; make sure their hashes are valid.
    Base.rehash!(MODEL_REGISTRY)
    Base.rehash!(Admin.REGISTRY)
    reset_settings!()
    Admin.register_builtin!()
end

end # module
