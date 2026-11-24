# Sites and redirects -------------------------------------------------------------------------------------
#
# "juango.sites": a `Site` per domain the project serves, and `get_current_site(req)` (SITE_ID, or
# the request's host). Sitemaps, feeds and password-reset emails use its domain.
#
# "juango.redirects": old URLs kept in the database and edited in the admin;
# `RedirectFallbackMiddleware` turns a 404 for one into a 301 to its new path (410 Gone when the
# new path is empty). Needs juango.sites.

"Django's: a domain name has no spaces or tabs (or other whitespace)."
site_domain_validator(v) = any(isspace, v) ? gettext("The domain name cannot contain any spaces or tabs.") : true

@model struct Site
    domain = CharField(max_length = 100, unique = true, verbose_name = "domain name", validators = [site_domain_validator])
    name = CharField(max_length = 50, verbose_name = "display name")
    Meta(table = "juango_site", app_label = "sites", ordering = ["domain"], verbose_name = "site", verbose_name_plural = "sites")
end
Base.show(io::IO, s::Site) = print(io, s.domain)
natural_key(s::Site) = (s.domain,)
get_by_natural_key(::Type{Site}, domain::AbstractString) = get(objects(Site); domain = domain)

"A site for a request when juango.sites isn't installed: the request's host as both domain and name."
struct RequestSite
    domain::String
    name::String
end
RequestSite(req::Request) = (h = get_host(req); RequestSite(h, h))
Base.show(io::IO, s::RequestSite) = print(io, s.domain)
save!(::RequestSite; kw...) = throw(ErrorException("RequestSite cannot be saved."))
Base.delete!(::RequestSite) = throw(ErrorException("RequestSite cannot be deleted."))
tattr(s::RequestSite, ::Val{:domain}) = s.domain
tattr(s::RequestSite, ::Val{:name}) = s.name

const SITE_CACHE = Dict{Any,Site}()
const SITE_CACHE_LOCK = ReentrantLock()
push!(SETTINGS_CHANGED_HOOKS, () -> lock(() -> empty!(SITE_CACHE), SITE_CACHE_LOCK))
"Forget the cached sites (after changing `Site` rows outside the admin)."
clear_site_cache!() = lock(() -> empty!(SITE_CACHE), SITE_CACHE_LOCK)

"""
    get_current_site(req = nothing) -> Site or RequestSite

The `Site` with `SITE_ID`, or (with `SITE_ID = nothing`) the one whose domain is the request's
host. Without juango.sites, a `RequestSite` for the host. Sites are cached.
"""
function get_current_site(req = nothing)
    if !is_installed("sites")
        req === nothing && throw(ImproperlyConfigured("get_current_site() needs a request when juango.sites isn't installed"))
        return RequestSite(req)
    end
    id = get(settings, :SITE_ID, nothing)
    # the host without a trailing dot ("example.com." is example.com), as Django's split_domain_port
    host = req === nothing ? "" : (h = lowercase(get_host(req)); m = match(r"^(.*?)\.?(:\d+)?$", h); m[1] * something(m[2], ""))
    key = id !== nothing ? (current_alias(), id) : (req === nothing ? throw(ImproperlyConfigured("SITE_ID is nothing: get_current_site needs a request")) :
                                                   (current_alias(), host))
    c = lock(() -> get(SITE_CACHE, key, nothing), SITE_CACHE_LOCK)
    c === nothing || return c
    # (Django's Site.DoesNotExist when there's no such site)
    s = id !== nothing ? first(filter(Site; id = id)) :
        something(first(filter(Site; domain__iexact = host)), first(filter(Site; domain__iexact = first(split(host, ':')))), Some(nothing))
    s === nothing && throw(DoesNotExist(Site, id !== nothing ? "id = $id (SITE_ID)" : "the host '$(get_host(req))'"))
    lock(() -> (SITE_CACHE[key] = s), SITE_CACHE_LOCK)
end

"The current site's domain (the request's host without juango.sites)."
site_domain(req) = is_installed("sites") ? get_current_site(req).domain : get_host(req)

"""
    create_default_site!(; verbosity = 2, db = nothing)

Create the `example.com` site, with `SITE_ID` as its key (else 1), if there is none (run by `migrate`
when juango.sites is installed, on each database the router lets sites migrate to). Says so at
verbosity 2 and up.
"""
function create_default_site!(; verbosity::Integer = 2, db = nothing)
    run() = begin
        (is_installed("sites") && table_exists(backend(), "juango_site") && !exists(objects(Site))) || return
        verbosity >= 2 && println("Creating example.com Site object")
        save!(Site(; id = something(get(settings, :SITE_ID, nothing), 1), domain = "example.com", name = "example.com"))
        foreach(execute, sequence_reset_sql(; models = [Site]))      # (the key was given: the next automatic one follows it)
    end
    db === nothing ? run() : with_db(run, db)
end

const SITES_APP = App("sites"; name = "juango.sites", verbose_name = "Sites", ready = function ()
    is_installed("admin") && !Admin.is_registered(Site) &&
        Admin.register!(Site; list_display = [:domain, :name], search_fields = [:domain, :name])
end)
# a site saved or deleted (in the admin, say) leaves the cache, as Django's pre_save/pre_delete handlers do
site_changed(_...; kw...) = clear_site_cache!()
connect!(post_save, site_changed; sender = Site, dispatch_uid = :juango_site_saved)
connect!(post_delete, site_changed; sender = Site, dispatch_uid = :juango_site_deleted)

"Django's sites.E101: SITE_ID must be an integer (or nothing)."
function check_site_id()
    id = get(settings, :SITE_ID, nothing)
    (id === nothing || id isa Integer) && return CheckMessage[]
    msg = id isa AbstractString && tryparse(Int, id) === nothing ?
          "The SITE_ID setting failed to validate: ['“$(id)” value must be an integer.']." : "The SITE_ID setting must be of type int."
    [CheckMessage(:error, msg; id = "sites.E101")]
end
register_check!(() -> is_installed("sites") ? check_site_id() : CheckMessage[]; tags = [:sites])

"""
    CurrentSiteMiddleware

Puts the current site on the request: `req.site` (Django's).
"""
CurrentSiteMiddleware(get_response) = function (req::Request)
    req.meta[:site] = get_current_site(req)
    get_response(req)
end

# --- redirects ----------------------------------------------------------------------------------------

@model struct Redirect
    site = ForeignKey(Site, on_delete = :CASCADE)
    old_path = CharField(max_length = 200, db_index = true, verbose_name = "redirect from",
                         help_text = "This should be an absolute path, excluding the domain name. Example: “/events/search/”.")
    new_path = CharField(max_length = 200, blank = true, verbose_name = "redirect to",
                         help_text = "This can be either an absolute path (as above) or a full URL starting with a scheme such as “https://”.")
    Meta(table = "juango_redirect", app_label = "redirects", ordering = ["old_path"], unique_together = [(:site, :old_path)],
         verbose_name = "redirect", verbose_name_plural = "redirects")
end
Base.show(io::IO, r::Redirect) = print(io, r.old_path, " ---> ", r.new_path)

const REDIRECTS_APP = App("redirects"; name = "juango.redirects", verbose_name = "Redirects", requires = ["sites"], ready = function ()
    is_installed("admin") && !Admin.is_registered(Redirect) &&
        Admin.register!(Redirect; list_display = [:old_path, :new_path], list_filter = [:site], search_fields = [:old_path, :new_path])
end)

"""
    RedirectFallbackMiddleware

When a response is a 404, look for a `Redirect` of the current site from the request's path
(with the query string first, then without; and with a trailing slash under `APPEND_SLASH`):
answer 301 to its `new_path`, or 410 Gone if that is empty. Put it last in MIDDLEWARE. Needs juango.sites.

Other responses (Django's `response_gone_class` / `response_redirect_class` on a subclass):

    gr -> RedirectFallbackMiddleware(gr; response_gone_class = HttpResponseForbidden,
                                         response_redirect_class = HttpResponseRedirect)
"""
function RedirectFallbackMiddleware(get_response; response_gone_class = HttpResponseGone,
                                    response_redirect_class = HttpResponsePermanentRedirect)
    is_installed("sites") ||
        throw(ImproperlyConfigured("You cannot use RedirectFallbackMiddleware when juango.sites is not installed."))
    function (req::Request)
        resp = get_response(req)
        resp.status == 404 || return resp
        is_installed("redirects") || return resp
        site = get_current_site(req)
        candidates = unique([full_path(req), req.path])
        if settings.APPEND_SLASH && !endswith(req.path, "/")
            # the path with the slash APPEND_SLASH would add, with its query string, then without (as Django's)
            q = isempty(req.query_string) ? "" : "?" * req.query_string
            append!(candidates, unique([req.path * "/" * q, req.path * "/"]))
        end
        for p in candidates
            r = first(filter(Redirect; site = site, old_path = p))
            r === nothing && continue
            isempty(r.new_path) && return response_gone_class()
            return response_redirect_class(r.new_path)
        end
        resp
    end
end
push!(MIDDLEWARE_APPS, RedirectFallbackMiddleware => "redirects")
