# Sitemaps ---------------------------------------------------------------------------------------------------
#
#     posts = Sitemap(() -> filter(Post; published = true); lastmod = :updated, changefreq = "weekly", priority = 0.6)
#     pages = Sitemap(["home", "about"]; location = name -> reverse_url(name))
#     urlpatterns = [..., sitemap_urls(Dict("posts" => posts, "pages" => pages))...]
#
# `sitemap_urls` serves /sitemap.xml: a sitemap index pointing at /sitemap-<section>.xml when
# there are several sections, else the single urlset. A section with more than `limit`
# (50,000) URLs is split into pages (?p=2).

"""
    Sitemap(items; location=get_absolute_url, lastmod=nothing, changefreq=nothing, priority=nothing,
            protocol=nothing, limit=50_000)

One section of a sitemap. `items` is a collection, a `QuerySet` or a function returning one.
`location`, `lastmod`, `changefreq` and `priority` are each a value, a function of the item,
or a `Symbol` naming the item's field. Without a `location`, items that are strings are used
as URLs and other items need `get_absolute_url`. `location` gives a path (or absolute URL); paths are
made absolute with the request's host and `protocol` (default: the request's).
"""
Base.@kwdef struct Sitemap
    items::Any
    location::Any = nothing
    lastmod::Any = nothing
    changefreq::Any = nothing
    priority::Any = nothing
    protocol::Union{Nothing,String} = nothing
    limit::Int = 50_000
end
Sitemap(items; kw...) = Sitemap(; items = items, kw...)

item_value(f, item) = f === nothing ? nothing : f isa Symbol ? getproperty(item, f) : f isa Function ? f(item) : f
sitemap_items(s::Sitemap) = (x = s.items isa Function ? s.items() : s.items; x isa QuerySet ? x : collect(x))
sitemap_count(items) = items isa QuerySet ? count(items) : length(items)
num_pages(s::Sitemap, items) = max(1, cld(sitemap_count(items), s.limit))

"W3C datetime for <lastmod>."
w3c_date(d::Date) = Dates.format(d, "yyyy-mm-dd")
w3c_date(d::DateTime) = Dates.format(d, "yyyy-mm-ddTHH:MM:SS") * "+00:00"
w3c_date(z::TimeZones.ZonedDateTime) = Dates.format(DateTime(TimeZones.astimezone(z, UTC_TZ)), "yyyy-mm-ddTHH:MM:SS") * "+00:00"
w3c_date(x) = (d = todatetime(x); d === nothing ? string(x) : w3c_date(d))
utc_datetime(d::Date) = DateTime(d)
utc_datetime(d::DateTime) = d
utc_datetime(z::TimeZones.ZonedDateTime) = DateTime(TimeZones.astimezone(z, UTC_TZ))
utc_datetime(x) = todatetime(x)

absolute(req::Request, url::AbstractString, protocol) =
    occursin(r"^[a-z][a-z0-9+.-]*://"i, url) ? String(url) :
    something(protocol, is_secure(req) ? "https" : "http") * "://" * site_domain(req) * (startswith(url, "/") ? url : "/" * url)

"The `<url>` entries of one page of a section: (loc, lastmod, changefreq, priority) tuples."
function sitemap_entries(req::Request, s::Sitemap, items, page::Int)
    lo = (page - 1) * s.limit + 1
    hi = min(page * s.limit, sitemap_count(items))
    lo > hi && return NamedTuple[]
    slice = items isa QuerySet ? collect(items[lo:hi]) : items[lo:hi]
    [(loc = absolute(req, string(something(item_value(something(s.location, get_absolute_url_or_error), item), "")), s.protocol),
      lastmod = item_value(s.lastmod, item), changefreq = item_value(s.changefreq, item), priority = item_value(s.priority, item))
     for item in slice]
end
function get_absolute_url_or_error(item)
    item isa AbstractString && return item                   # a list of URLs or paths
    u = applicable(get_absolute_url, item) ? get_absolute_url(item) : nothing
    u === nothing && throw(ImproperlyConfigured("give the Sitemap a location, or define get_absolute_url for $(typeof(item))"))
    u
end

xml_escape(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;", "'" => "&apos;")

function sitemap_response(xml, lastmod)
    r = HttpResponse(xml; content_type = "application/xml; charset=utf-8")
    setheader!(r, "X-Robots-Tag", "noindex, noodp, noarchive")
    lastmod === nothing || setheader!(r, "Last-Modified", Dates.format(lastmod, Dates.RFC1123Format) * " GMT")
    r
end

page_param(req) = (p = tryparse(Int, get(req.GET, "p", "1")); p === nothing || p < 1 ? throw(Http404("Page $(get(req.GET, "p", "")) empty")) : p)

"A view for one sitemap urlset: all `sitemaps` (a Dict or Vector of `Sitemap`s), or the `section` in the URL."
function sitemap_view(sitemaps)
    name_view!(function (req::Request; section = nothing, kw...)
        selected = section === nothing ? collect(values_of(sitemaps)) :
                   (haskey_of(sitemaps, section) ? [get_of(sitemaps, section)] : throw(Http404("No sitemap available for section: '$section'")))
        page = page_param(req)
        entries = NamedTuple[]
        for s in selected
            items = sitemap_items(s)
            page > num_pages(s, items) && (length(selected) == 1 ? throw(Http404("Page $page empty")) : continue)
            append!(entries, sitemap_entries(req, s, items, page))
        end
        io = IOBuffer()
        print(io, """<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n""")
        for e in entries
            print(io, "<url><loc>", xml_escape(e.loc), "</loc>")
            e.lastmod === nothing || print(io, "<lastmod>", w3c_date(e.lastmod), "</lastmod>")
            e.changefreq === nothing || print(io, "<changefreq>", xml_escape(e.changefreq), "</changefreq>")
            e.priority === nothing || print(io, "<priority>", string(e.priority), "</priority>")
            print(io, "</url>\n")
        end
        print(io, "</urlset>\n")
        mods = [utc_datetime(e.lastmod) for e in entries]
        sitemap_response(String(take!(io)), !isempty(mods) && all(!isnothing, mods) ? maximum(mods) : nothing)
    end, "sitemap")
end

"""
A sitemap index view: one `<sitemap>` per section page, pointing at `section_url(section)`
(by default `sitemap-<section>.xml` next to the index's own URL).
"""
function sitemap_index_view(sitemaps; section_url = nothing)
    name_view!(function (req::Request; kw...)
        io = IOBuffer()
        print(io, """<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n""")
        for (name, s) in sort(collect(pairs_of_sitemaps(sitemaps)); by = first)
            items = sitemap_items(s)
            loc = absolute(req, section_url === nothing ? replace(req.path, r"[^/]*$" => "sitemap-$name.xml") : section_url(name), s.protocol)
            for p in 1:num_pages(s, items)
                print(io, "<sitemap><loc>", xml_escape(p == 1 ? loc : "$loc?p=$p"), "</loc>")
                if s.lastmod !== nothing && p == 1
                    mods = filter(!isnothing, Any[item_value(s.lastmod, x) for x in (items isa QuerySet ? collect(items) : items)])
                    isempty(mods) || print(io, "<lastmod>", w3c_date(mods[argmax(utc_datetime.(mods))]), "</lastmod>")
                end
                print(io, "</sitemap>\n")
            end
        end
        print(io, "</sitemapindex>\n")
        sitemap_response(String(take!(io)), nothing)
    end, "sitemap_index")
end

values_of(d::AbstractDict) = values(d)
values_of(v) = v
haskey_of(d::AbstractDict, k) = haskey(d, string(k))
haskey_of(v, k) = false
get_of(d::AbstractDict, k) = d[string(k)]
pairs_of_sitemaps(d::AbstractDict) = [string(k) => v for (k, v) in d]
pairs_of_sitemaps(v) = ["$i" => s for (i, s) in enumerate(v)]

"""
    sitemap_urls(sitemaps; index = length(sitemaps) > 1)

URL patterns for `sitemap.xml` (an index of the sections, or with one section its urlset)
and `sitemap-<section>.xml`. Splice them into urlpatterns: `[..., sitemap_urls(maps)...]`.
"""
function sitemap_urls(sitemaps::AbstractDict; index = length(sitemaps) > 1)
    d = Dict{String,Sitemap}(string(k) => v for (k, v) in sitemaps)
    [path("sitemap.xml", index ? sitemap_index_view(d) : sitemap_view(d); name = "sitemap"),
     path("sitemap-<str:section>.xml", sitemap_view(d); name = "sitemap_section")]
end
