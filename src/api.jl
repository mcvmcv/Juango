# The public API ---------------------------------------------------------------------------------
#
# `using Juango` brings in the everyday API: settings, requests and responses, URLs, templates,
# models, fields, querysets and expressions, forms, views, auth, messages, signals, caching,
# mail and translations. Everything else that's part of the API is declared `public`: use it
# as `Juango.name` (or `using Juango: name`). Specialised areas have their own modules, which
# export their names:
#
#     using Juango.Testing      # Client, RequestFactory, assertions, override_settings, outbox ...
#     using Juango.GIS          # geometry fields and types, distances, GeoJSON and WKT
#     using Juango.Postgres     # hstore, citext, full-text search, trigrams, exclusion constraints
#
# plus `Juango.Admin` and `Juango.Migrations`. Functions that projects add methods to
# (`get_absolute_url`, `tattr`, `natural_key`, router and auth-backend hooks ...) are public too.

# --- exported --------------------------------------------------------------------------------------

# settings
export settings, configure!
# requests and responses
export Request, HttpResponse, JsonResponse, HttpResponseRedirect, HttpResponsePermanentRedirect,
       HttpResponseNotFound, HttpResponseForbidden, HttpResponseBadRequest, HttpResponseNotAllowed,
       StreamingHttpResponse, FileResponse, Http404, PermissionDenied, BadRequest, QueryDict, getlist,
       set_cookie!, delete_cookie!, getheader, setheader!, json_body
export EventStreamResponse, sse_event, websocket, ws_send, ws_receive, ws_close, ws_isopen
# urls
export path, re_path, include_urls, reverse_url, resolve
# templates
export Template, render_to_string, get_template, mark_safe, SafeString, escape_html, tattr,
       register_filter!, register_tag!, TagLibrary, simple_tag!, inclusion_tag!, tag!, TemplateSyntaxError
# models and fields
export Model, @model, @abstract_model, Field, CharField, TextField, EmailField, SlugField, URLField,
       IntegerField, FloatField, BooleanField, DateTimeField, DateField, JSONField, ArrayField, UUIDField,
       IntegerRangeField, DateRangeField, DateTimeRangeField, ValueRange, FileField, ImageField, UploadedFile,
       FileExtensionValidator, MaxFileSizeValidator,
       ForeignKey, OneToOneField, ManyToManyField, ForeignObject, GeneratedField, DB_DEFAULT,
       CompositePrimaryKey, CheckConstraint, UniqueConstraint, Index, get_absolute_url
export ContentType, GenericForeignKey, GenericRelation
# querysets
export QuerySet, objects, base_objects, Q, exclude, order_by, exists, values_list, annotate, aggregate,
       select_related, prefetch_related, Prefetch, FilteredRelation, defer, distinct, latest, earliest,
       none, in_bulk, dates, datetimes, raw, explain, iterator, select_for_update, intersection,
       difference, create, get_or_create, update_or_create, update!, save!, refresh!, full_clean, bulk_create,
       bulk_update, add!, remove!, set!, clear!, atomic, on_commit, using_db,
       DoesNotExist, MultipleObjectsReturned, ProtectedError, IntegrityError, TransactionManagementError
export run_async, sync_to_async, aget, acreate, acount, aexists, afirst, alast, acollect, aget_or_create,
       aupdate_or_create, abulk_create, abulk_update, aaggregate, ain_bulk, aupdate!, adelete!, asave!,
       arefresh!, aauthenticate, aiterator
# expressions
export F, Value, Count, Sum, Avg, Min, Max, Lower, Upper, Length, Coalesce, Concat, Cast, Now,
       ExtractYear, ExtractMonth, ExtractDay, When, Case, OuterRef, Subquery, Exists, Window,
       RowNumber, Rank, DenseRank, Lag, Lead
# migrations
export migrate, makemigrations
# forms
export Form, @form, ModelForm, is_valid, add_error!, as_p, cleaned_data, save_m2m!, has_changed,
       changed_fields, FormSet, formset_factory, modelformset_factory, inlineformset_factory,
       Widget, MultiWidget, MultiValueField, SplitDateTimeField, Media
# views
export render, redirect, get_object_or_404, get_list_or_404, TemplateView, RedirectView, ListView,
       DetailView, CreateView, UpdateView, DeleteView, FormView, ArchiveIndexView, YearArchiveView,
       MonthArchiveView, DayArchiveView, DateDetailView, ViewCall, default_hook, Paginator, page,
       require_http_methods, require_GET, require_POST, csrf_exempt, get_csrf_token,
       LoginRequiredMixin, PermissionRequiredMixin, UserPassesTestMixin
# auth and messages
export User, AbstractUser, AnonymousUser, USER_MODEL, get_user_model, authenticate, login!, logout!,
       create_user, create_superuser, set_password!, check_password, make_password, is_authenticated, login_required,
       staff_member_required, Permission, Group, has_perm, has_perms, permission_required, ModelBackend,
       validate_password, update_session_auth_hash!, UserCreationForm, UserChangeForm,
       PasswordChangeView, PasswordChangeDoneView, PasswordResetView, PasswordResetConfirmView
export message!, get_messages
# signals
export Signal, connect!, disconnect!, receiver, send, pre_save, post_save, pre_delete, post_delete,
       m2m_changed, request_started, request_finished, user_logged_in, user_logged_out,
       user_login_failed, pre_migrate, post_migrate
# translations and time zones
export gettext, ngettext, pgettext, npgettext, gettext_lazy, ngettext_lazy, pgettext_lazy, @t_str,
       interpolate, get_language, activate!, deactivate!, with_language, LocaleMiddleware, i18n_patterns,
       i18n_urls, timezone_now, make_aware, make_naive, localtime, with_timezone, activate_timezone!,
       deactivate_timezone!, get_current_timezone, TimezoneMiddleware
# caching, HTTP caching and security headers
export cache_get, cache_set, cache_add, cache_delete, cache_has, cache_clear, get_or_set, cache_get_many,
       cache_set_many, cache_page, CacheMiddleware, never_cache, cache_control, vary_on_headers,
       vary_on_cookie, condition, etag, last_modified, ConditionalGetMiddleware, GZipMiddleware,
       ContentSecurityPolicyMiddleware, CSP, csp_nonce
# mail
export send_mail, mail_admins, mail_managers, EmailMessage, EmailMultiAlternatives, send!, attach!,
       attach_alternative!
# apps, contrib apps, tasks
export App, get_model, Admin, Sitemap, sitemap_urls, Feed, FlatPage, Site, get_current_site,
       @background, enqueue, get_result, TaskResult
# server and commands
export runserver, execute_from_command_line

# --- public, not exported ----------------------------------------------------------------------------

# requests, responses and streaming
public header, text, sse_comment, WebSocketView, is_streaming, build_absolute_uri, handle_request
# templates
public render_form, TemplateFormRenderer
# models, files, querysets
public uuid4, FieldFile, FileSystemStorage, InMemoryStorage, storages, default_storage, save_file, delete_file, image_size,
       register_lookup, register_transform, deferred_fields, PoolTimeout, pool_status,
       get_for_model, model_class, natural_key, get_by_natural_key, manager, default_queryset,
       DatabaseBackend, register_backend!, execute, db_for_read, db_for_write, allow_migrate, allow_relation
# migrations and database tools
public showmigrations, sqlmigrate, squashmigrations, flush!, inspectdb, dbshell_cmd,
       serialize, deserialize, dumpdata, loaddata, load_fixtures
# forms
public management_form, empty_form, deleted_forms, ordered_forms, clean_form
# auth
public username_field, has_module_perms, get_all_permissions, perm_name, auth_urls,
       PBKDF2Hasher, Argon2Hasher, BCryptSHA256Hasher, BCryptHasher, MinimumLengthValidator,
       NumericPasswordValidator, CommonPasswordValidator, UserAttributeSimilarityValidator,
       password_summary, password_error, make_reset_token, check_reset_token,
       backend_authenticate, backend_get_user, backend_has_perm
# signing
public signing_dumps, signing_loads, sign_value, unsign_value, BadSignature, SignatureExpired
# signals, logging
public send_robust, has_receivers, emit, log!, log_enabled, MemoryHandler, LogRecord
# translations and time zones
public set_language, number_format, localize, language_name, makemessages, compilemessages,
       is_aware, convert_naive_datetimes, JavaScriptCatalog, JSONCatalog
# caching, HTTP caching, security
public cache, incr, decr, incr_version, create_cache_table, patch_cache_control!,
       BrokenLinkEmailsMiddleware, is_secure, csp_override, csp_report_only_override, deploy_issues
# admin log, contrib apps, tasks
public LogEntry, log_action!, ADDITION, CHANGE, DELETION, admindocs_urls, sitemap_view,
       sitemap_index_view, flatpage, flatpage_urls, FlatpageFallbackMiddleware, RequestSite,
       clear_site_cache!, Redirect, RedirectFallbackMiddleware, background, TaskDef, db_worker
# apps, settings, commands
public installed_apps, is_installed, get_app, model_label, app_models, static_dirs, default_settings,
       startproject, startapp, collectstatic, register_command!, slugify

# --- Juango.Testing, Juango.GIS, Juango.Postgres ----------------------------------------------------

module Testing
using ..Juango: Client, RequestFactory, request, post, force_login!, text, outbox, rollback_after,
    capture_on_commit_callbacks, with_live_server, live_server_url, override_settings, assert_contains,
    assert_not_contains, assert_redirects, assert_template_used, assert_template_not_used,
    assert_num_queries, assert_form_error, count_queries, dummy_results
export Client, RequestFactory, request, post, force_login!, text, outbox, rollback_after,
    capture_on_commit_callbacks, with_live_server, live_server_url, override_settings, assert_contains,
    assert_not_contains, assert_redirects, assert_template_used, assert_template_not_used,
    assert_num_queries, assert_form_error, count_queries, dummy_results
end

module GIS
using ..Juango: GeometryField, PointField, LineStringField, PolygonField, MultiPointField,
    MultiLineStringField, MultiPolygonField, Point, LineString, Polygon, MultiPoint, MultiLineString,
    MultiPolygon, D, Distance, Area, GeoLength, AsGeoJSON, geojson, from_geojson, wkt, ewkt, parse_wkt, parse_wkb
export GeometryField, PointField, LineStringField, PolygonField, MultiPointField,
    MultiLineStringField, MultiPolygonField, Point, LineString, Polygon, MultiPoint, MultiLineString,
    MultiPolygon, D, Distance, Area, GeoLength, AsGeoJSON, geojson, from_geojson, wkt, ewkt, parse_wkt, parse_wkb
end

module Postgres
using ..Juango: HStoreField, CICharField, SearchVector, SearchQuery, SearchRank, TrigramSimilarity,
    TrigramWordSimilarity, TrigramStrictWordSimilarity, TrigramDistance, TrigramWordDistance, Unaccent,
    ExclusionConstraint, GinIndex
export HStoreField, CICharField, SearchVector, SearchQuery, SearchRank, TrigramSimilarity,
    TrigramWordSimilarity, TrigramStrictWordSimilarity, TrigramDistance, TrigramWordDistance, Unaccent,
    ExclusionConstraint, GinIndex
end

public Testing, GIS, Postgres, Migrations
