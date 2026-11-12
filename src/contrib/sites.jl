# Sites and redirects -------------------------------------------------------------------------------------
#
# "juango.sites": a `Site` per domain the project serves, and `get_current_site(req)` (SITE_ID, or
# the request's host). Sitemaps, feeds and password-reset emails use its domain.
#
# "juango.redirects": old URLs kept in the database and edited in the admin;
# `RedirectFallbackMiddleware` turns a 404 for one into a 301 to its new path (410 Gone when the
# new path is empty). Needs juango.sites.

@model struct Site
    domain = CharField(max_length = 100, unique = true, verbose_name = "domain name")
    name = CharField(max_length = 50, verbose_name = "display name")
    Meta(table = "juango_site", app_label = "sites", ordering = ["domain"], verbose_name = "site", verbose_name_plural = "sites")
end
Base.show(io::IO, s::Site) = print(io, s.domain)

"A site for a request when juango.sites isn't installed: the request's host as both domain and name."
struct RequestSite
    domain::String
    name::String
end
RequestSite(req::Request) = (h = get_host(req); RequestSite(h, h))
Base.show(io::IO, s::RequestSite) = print(io, s.domain)
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
    id = settings.SITE_ID
    key = id !== nothing ? (current_alias(), id) : (req === nothing ? throw(ImproperlyConfigured("SITE_ID is nothing: get_current_site needs a request")) :
                                                   (current_alias(), lowercase(first(split(get_host(req), ':')))))
    c = lock(() -> get(SITE_CACHE, key, nothing), SITE_CACHE_LOCK)
    c === nothing || return c
    s = id !== nothing ? first(filter(Site; id = id)) :
        something(first(filter(Site; domain__iexact = get_host(req))), first(filter(Site; domain__iexact = key[2])), Some(nothing))
    s === nothing && throw(ImproperlyConfigured(id !== nothing ? "no Site with SITE_ID = $id; create one or change SITE_ID" :
                                                "no Site matches the host '$(get_host(req))'"))
    lock(() -> (SITE_CACHE[key] = s), SITE_CACHE_LOCK)
end

"The current site's domain (the request's host without juango.sites)."
site_domain(req) = is_installed("sites") ? get_current_site(req).domain : get_host(req)

"Create the `example.com` site (id 1) if there is none (run by `migrate` when juango.sites is installed)."
function create_default_site!()
    (is_installed("sites") && table_exists(backend(), "juango_site") && !exists(objects(Site))) || return
    save!(Site(; id = 1, domain = "example.com", name = "example.com"))
end

const SITES_APP = App("sites"; name = "juango.sites", verbose_name = "Sites", ready = function ()
    is_installed("admin") && !Admin.is_registered(Site) &&
        Admin.register!(Site; list_display = [:domain, :name], search_fields = [:domain, :name])
end)

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
answer 301 to its `new_path`, or 410 Gone if that is empty. Put it last in MIDDLEWARE.
"""
function RedirectFallbackMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        resp.status == 404 || return resp
        is_installed("redirects") || return resp
        site = get_current_site(req)
        candidates = unique([full_path(req), req.path])
        settings.APPEND_SLASH && !endswith(req.path, "/") && push!(candidates, req.path * "/")
        for p in candidates
            r = first(filter(Redirect; site = site, old_path = p))
            r === nothing && continue
            isempty(r.new_path) && return HttpResponse("<h1>Gone</h1>"; status = 410)
            return HttpResponsePermanentRedirect(r.new_path)
        end
        resp
    end
end
push!(MIDDLEWARE_APPS, RedirectFallbackMiddleware => "redirects")
