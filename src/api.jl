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
#     using Juango.Functions    # Greatest, Replace, LPad, Round, Sqrt, StdDev, StringAgg ... (Django's db.models.functions)
#
# plus `Juango.Admin` and `Juango.Migrations`. Functions that projects add methods to
# (`get_absolute_url`, `tattr`, `natural_key`, router and auth-backend hooks ...) are public too.

# --- exported --------------------------------------------------------------------------------------

# settings
export settings, configure!, declare_settings!
# requests and responses
export Request, HttpResponse, JsonResponse, HttpResponseRedirect, HttpResponsePermanentRedirect,
       HttpResponseNotFound, HttpResponseForbidden, HttpResponseBadRequest, HttpResponseNotAllowed,
       HttpResponseGone, HttpResponseNotModified, HttpResponseServerError, set_signed_cookie!, get_signed_cookie,
       StreamingHttpResponse, FileResponse, protected_media, content_disposition, TemplateResponse, Http404, PermissionDenied, BadRequest, QueryDict, getlist,
       set_cookie!, delete_cookie!, getheader, setheader!, json_body
export EventStreamResponse, sse_event, websocket, ws_send, ws_receive, ws_close, ws_isopen
# urls
export path, re_path, include_urls, reverse_url, resolve
# templates
export Template, render_to_string, get_template, mark_safe, SafeString, escape_html, format_html, format_html_join, tattr, tattr!, instance_cache,
       register_filter!, register_tag!, TagLibrary, simple_tag!, inclusion_tag!, tag!, TemplateSyntaxError
# models and fields
export Model, @model, @abstract_model, Field, CharField, TextField, EmailField, SlugField, URLField,
       IntegerField, BigIntegerField, SmallIntegerField, PositiveIntegerField, PositiveBigIntegerField,
       PositiveSmallIntegerField, AutoField, BigAutoField, SmallAutoField, FloatField, DecimalField,
       BooleanField, DateTimeField, DateField, TimeField, DurationField, JSONField, ArrayField,
       UUIDField, BinaryField, GenericIPAddressField, FilePathField, IntegerRangeField, DateRangeField,
       DateTimeRangeField, DecimalRangeField, ValueRange, FileField, ImageField, UploadedFile, FileExtensionValidator,
       Validator, RegexValidator, EmailValidator, URLValidator, MinValueValidator, MaxValueValidator, MinLengthValidator,
       MaxLengthValidator, StepValueValidator, DecimalValidator, ProhibitNullCharactersValidator, validate_email, validate_slug,
       validate_unicode_slug, validate_ipv4_address, validate_ipv6_address, validate_ipv46_address, int_list_validator,
       validate_comma_separated_integer_list,
       MaxFileSizeValidator, ForeignKey, OneToOneField, ManyToManyField, ForeignObject, GeneratedField,
       DB_DEFAULT, CompositePrimaryKey, CheckConstraint, UniqueConstraint, Index, get_absolute_url,
       Decimal, @dec_str, @choices, Choice, ChoiceSet, get_display
export ContentType, GenericForeignKey, GenericRelation
# querysets
export QuerySet, objects, base_objects, Q, exclude, order_by, exists, values_list, annotate, alias, aggregate,
       select_related, prefetch_related, prefetch_related_objects, Prefetch, FilteredRelation, defer, distinct, latest, earliest,
       none, in_bulk, totally_ordered, dates, datetimes, raw, explain, iterator, select_for_update, intersection,
       difference, create, get_or_create, update_or_create, update!, save!, refresh!, full_clean,
       clean_fields, validate_unique, validate_constraints, get_next_by, get_previous_by, bulk_create,
       bulk_update, add!, remove!, set!, clear!, through, atomic, advisory_lock, swap_user_model, with_nplusone_allowed, deploy_task!, deploy_waiting, run_deploy_tasks, on_commit, using_db, set_rollback!, get_rollback,
       get_order, set_order!, get_next_in_order, get_previous_in_order,
       get_autocommit, savepoint, savepoint_commit, savepoint_rollback, mark_for_rollback_on_error, execute_wrapper,
       DoesNotExist, MultipleObjectsReturned, ProtectedError, RestrictedError, protected_message, SET, IntegrityError, DatabaseError, ValidationError, TransactionManagementError, NotSupportedError
export run_async, sync_to_async, aget, acreate, acount, aexists, afirst, alast, acollect, aget_or_create,
       aupdate_or_create, abulk_create, abulk_update, aaggregate, ain_bulk, aupdate!, adelete!, asave!,
       arefresh!, aauthenticate, aiterator
# expressions
export F, Value, Count, Sum, Avg, Min, Max, Lower, Upper, Length, Coalesce, Concat, Cast, Now,
       Extract, ExtractYear, ExtractQuarter, ExtractMonth, ExtractWeek, ExtractWeekDay, ExtractIsoWeekDay,
       ExtractIsoYear, ExtractDay, ExtractHour, ExtractMinute, ExtractSecond, Trunc, TruncYear,
       TruncQuarter, TruncMonth, TruncWeek, TruncDay, TruncDate, TruncTime, TruncHour, TruncMinute,
       TruncSecond, When, Case, OuterRef, Subquery, Exists, RawSQL, ExpressionWrapper, Exact, IExact, GreaterThan, GreaterThanOrEqual, LessThan, LessThanOrEqual, In, Range, IsNull,
       Contains, IContains, StartsWith, IStartsWith, EndsWith, IEndsWith, Window, Asc, Desc, RowRange, FirstValue, LastValue, NthValue,
       Ntile, PercentRank, CumeDist, JSONObject,
       RowNumber, Rank, DenseRank, Lag, Lead
# migrations
export migrate, makemigrations
# forms
export Form, @form, ModelForm, is_valid, add_widget_attrs!, add_error!, as_p, cleaned_data, save_m2m!, has_changed,
       changed_fields, FormSet, formset_factory, active_forms, is_deleted, is_blank_extra, nested_form, nested_formset, nested_model_form, nested_row, NestedForm, form_html, field_html, modelformset_factory, inlineformset_factory,
       Widget, MultiWidget, MultiValueField, SplitDateTimeField, Media, ModelChoiceField,
       ModelMultipleChoiceField, ChoiceField, TypedChoiceField, TypedMultipleChoiceField, MultipleChoiceField, MultipleFileField, RegexField,
       ComboField, as_field_group, as_div, as_ul, as_table, NullBooleanField, SelectDateWidget, SplitHiddenDateTimeWidget,
       order_fields!, non_field_errors, has_error, errors_json_data, errors_as_json, legend_tag, set_field!, delete_field!
# views
export recording, recorded, undo_recorded!, undo_problem, UndoProblem, not_recording, undoing, undoing_recorded, has_changes,
       render, redirect, query_param, component!, get_text_list, ModelResource, export_data, export_rows, export_download, import_data,
       read_table, parse_csv, read_xlsx, excel_date, has_errors, ImportResult, API, route!, add_router!, api_urls, ModelSchema, openapi_schema,
       paginate_api, api_key_auth, bearer_auth, session_auth, get_object_or_404, get_list_or_404, TemplateView, RedirectView, ListView,
       DetailView, CreateView, UpdateView, DeleteView, FormView, ArchiveIndexView, YearArchiveView,
       MonthArchiveView, DayArchiveView, DateDetailView, WeekArchiveView, TodayArchiveView, ViewCall, default_hook, Paginator, page, get_page,
       require_http_methods, require_GET, require_POST, require_safe, csrf_exempt, non_atomic_requests, get_csrf_token,
       ensure_csrf_cookie, csrf_protect, requires_csrf_token, xframe_options_exempt, xframe_options_deny,
       xframe_options_sameorigin, gzip_page, no_append_slash, sensitive_post_parameters,
       LoginRequiredMixin, PermissionRequiredMixin, UserPassesTestMixin
# auth and messages
export User, AbstractUser, AnonymousUser, USER_MODEL, get_user_model, authenticate, login!, logout!,
       create_user, create_superuser, get_username, get_full_name, get_short_name, set_password!, check_password, make_password, is_authenticated, login_required,
       staff_member_required, Permission, Group, has_perm, has_perms, permission_required, ModelBackend,
       validate_password, update_session_auth_hash!, UserCreationForm, UserChangeForm, AdminPasswordChangeForm, AllowAllUsersModelBackend, login_not_required,
       LoginRequiredMiddleware, RemoteUserMiddleware, PersistentRemoteUserMiddleware, RemoteUserBackend,
       PasswordChangeView, PasswordChangeDoneView, PasswordResetView, PasswordResetConfirmView
export message!, get_messages, peek_messages, MessageMiddleware, url_has_allowed_host_and_scheme
export HtmxDetails, is_htmx, hx_redirect, hx_refresh, hx_location, hx_stop_polling, hx_push_url, hx_replace_url,
       hx_retarget, hx_reswap, hx_reselect, hx_trigger, form_status, HtmxMiddleware, HTMX_STOP_POLLING
export LiveView, live, mount, handle_event, handle_info, live_context, live_redirect, subscribe, unsubscribe, publish,
       LiveForm, live_change!, live_submit!
export DebugToolbarMiddleware, show_debug_toolbar
export FilterSet, Filter, CharFilter, NumberFilter, BooleanFilter, ChoiceFilter, MultipleChoiceFilter, ModelChoiceFilter,
       ModelMultipleChoiceFilter, DateFilter, DateTimeFilter, DateFromToRangeFilter, NumberRangeFilter, IsNullFilter, OrderingFilter
# signals
export Signal, connect!, disconnect!, receiver, send, pre_save, post_save, pre_delete, post_delete,
       m2m_changed, post_write, pre_write, request_started, request_finished, user_logged_in, user_logged_out,
       user_login_failed, pre_migrate, post_migrate, connection_created, got_request_exception, setting_changed,
       pre_init, post_init, class_prepared
# translations and time zones
export gettext, ngettext, pgettext, npgettext, gettext_lazy, ngettext_lazy, pgettext_lazy, @t_str, get_language_info,
       interpolate, get_language, activate!, deactivate!, with_language, LocaleMiddleware, i18n_patterns,
       i18n_urls, timezone_now, make_aware, make_naive, localtime, localdate, with_timezone, activate_timezone!,
       deactivate_timezone!, get_current_timezone, TimezoneMiddleware
# caching, HTTP caching and security headers
export cache_get, cache_set, cache_add, cache_delete, cache_has, cache_clear, get_or_set, cache_get_many,
       cache_set_many, cache_page, CacheMiddleware, never_cache, cache_control, vary_on_headers,
       vary_on_cookie, condition, etag, last_modified, ConditionalGetMiddleware, GZipMiddleware,
       ContentSecurityPolicyMiddleware, CSP, csp_nonce
# mail
export send_mail, mail_admins, mail_managers, EmailMessage, EmailMultiAlternatives, send!, attach!, attach_file,
       send_mass_mail, get_connection, send_messages,
       XlsxResponse, write_xlsx, xlsx_bytes, csv_field,
       attach_alternative!
# apps, contrib apps, tasks
export App, get_model, lookup_value, concrete_fields, many_to_many, attname, column, is_relation, is_primary_key, related_model,
       value_from_object, value_to_json, value_from_json, Admin, Sitemap, sitemap_urls, Feed, FlatPage, Site, get_current_site,
       @background, enqueue, get_result, TaskResult
# server and commands
export runserver, execute_from_command_line

# --- public, not exported ----------------------------------------------------------------------------

# requests, responses and streaming
public clean, live_snapshot, header, text, render_response!, process_template_response, temporary_file_path, TemporaryUploadedFile,
       MemoryFileUploadHandler, TemporaryFileUploadHandler, upload_file, sse_comment, WebSocketView, is_streaming, build_absolute_uri, handle_request
# templates
public render_form, TemplateFormRenderer, JuangoTemplates, MustacheTemplates, engine_template
# models, files, querysets
public uuid4, FieldFile, FileSystemStorage, InMemoryStorage, storages, default_storage, save_file, delete_file, image_size,
       register_lookup, register_transform, deferred_fields, PoolTimeout, pool_status,
       get_for_model, get_for_id, get_for_models, clear_contenttype_cache!, content_type_name, app_labeled_name, GenericPrefetch, model_class, natural_key, get_by_natural_key, manager, default_queryset,
       DatabaseBackend, register_backend!, execute, db_for_read, db_for_write, allow_migrate, allow_relation
# migrations and database tools
public showmigrations, sqlmigrate, squashmigrations, optimizemigration, flush!, inspectdb, dbshell_cmd,
       serialize, deserialize, dumpdata, loaddata, load_fixtures
# forms
public management_form, empty_form, deleted_forms, ordered_forms, clean_form
# auth
public username_field, has_module_perms, get_all_permissions, perm_name, auth_urls,
       PBKDF2Hasher, Argon2Hasher, BCryptSHA256Hasher, BCryptHasher, ScryptPasswordHasher, scrypt, MinimumLengthValidator,
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
public cache, incr, decr, incr_version, create_cache_table, CacheSerializationError, patch_cache_control!,
       BrokenLinkEmailsMiddleware, is_secure, csp_override, csp_report_only_override, deploy_issues
# admin log, contrib apps, tasks
public LogEntry, log_action!, ADDITION, CHANGE, DELETION, admindocs_urls, sitemap_view,
       sitemap_index_view, flatpage, flatpage_urls, FlatpageFallbackMiddleware, RequestSite,
       clear_site_cache!, Redirect, RedirectFallbackMiddleware, background, TaskDef, db_worker
# apps, settings, commands
public build, build_workload, project_include, on_reload!, CheckMessage, register_check!, run_checks, diffsettings, sendtestemail, findstatic,
       remove_stale_contenttypes, installed_apps, is_installed, get_app, model_label, app_models, static_dirs, default_settings,
       startproject, startapp, collectstatic, register_command!, slugify

# --- Juango.Testing, Juango.GIS, Juango.Postgres ----------------------------------------------------

"""
`using Juango.Environ` for settings from the environment and .env files (django-environ):
`read_env`, `env(name, T; default)`, `env_db`, `env_cache` and `env_email`. They're kept out of
Juango's own exports because `env` is a short, common name.
"""
module Environ
using ..Juango: env, read_env, env_db, env_cache, env_email
export env, read_env, env_db, env_cache, env_email
end

module Testing
using ..Juango: Client, RequestFactory, request, post, force_login!, text, outbox, rollback_after,
    capture_on_commit_callbacks, with_live_server, live_server_url, override_settings, assert_contains,
    assert_not_contains, assert_redirects, assert_template_used, assert_template_not_used,
    assert_num_queries, assert_form_error, count_queries, dummy_results, assert_htmx,
    live_test, live_event!, live_info!, live_flush!, setup_test_database, teardown_test_database, consume_stream!,
    assert_html_equal, assert_html_not_equal, assert_in_html, assert_json_equal, assert_json_not_equal,
    assert_queryset_equal, assert_formset_error, assert_field_output, assert_matches_snapshot
export Client, RequestFactory, request, post, force_login!, text, outbox, rollback_after,
    capture_on_commit_callbacks, with_live_server, live_server_url, override_settings, assert_contains,
    assert_not_contains, assert_redirects, assert_template_used, assert_template_not_used,
    assert_num_queries, assert_form_error, count_queries, dummy_results, assert_htmx,
    live_test, live_event!, live_info!, live_flush!, setup_test_database, teardown_test_database, consume_stream!,
    assert_html_equal, assert_html_not_equal, assert_in_html, assert_json_equal, assert_json_not_equal,
    assert_queryset_equal, assert_formset_error, assert_field_output, assert_matches_snapshot
end

module Functions
using ..Juango: Lower, Upper, Length, Coalesce, Concat, Cast, Now, Greatest, Least, NullIf, Collate, Replace,
    Substr, Left, Right, Trim, LTrim, RTrim, LPad, RPad, Repeat, Reverse, StrIndex, MD5, SHA256, SHA1, SHA224, SHA384, SHA512, Random, Chr, Ord, Abs,
    Round, Ceil, Floor, Mod, Power, Sqrt, Sign, Ln, Log, Exp, Sin, Cos, Tan, Cot, ASin, ACos, ATan, ATan2,
    Degrees, Radians, Pi, StdDev, Variance, ArrayAgg, JSONBAgg, StringAgg, BoolAnd, BoolOr, BitAnd, BitOr
export Lower, Upper, Length, Coalesce, Concat, Cast, Now, Greatest, Least, NullIf, Collate, Replace,
    Substr, Left, Right, Trim, LTrim, RTrim, LPad, RPad, Repeat, Reverse, StrIndex, MD5, SHA256, SHA1, SHA224, SHA384, SHA512, Random, Chr, Ord, Abs,
    Round, Ceil, Floor, Mod, Power, Sqrt, Sign, Ln, Log, Exp, Sin, Cos, Tan, Cot, ASin, ACos, ATan, ATan2,
    Degrees, Radians, Pi, StdDev, Variance, ArrayAgg, JSONBAgg, StringAgg, BoolAnd, BoolOr, BitAnd, BitOr
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
    ExclusionConstraint, GinIndex, GistIndex, BrinIndex, SpGistIndex, HashIndex, BloomIndex
export HStoreField, CICharField, SearchVector, SearchQuery, SearchRank, TrigramSimilarity,
    TrigramWordSimilarity, TrigramStrictWordSimilarity, TrigramDistance, TrigramWordDistance, Unaccent,
    ExclusionConstraint, GinIndex, GistIndex, BrinIndex, SpGistIndex, HashIndex, BloomIndex
end

public Testing, GIS, Postgres, Functions, Migrations
