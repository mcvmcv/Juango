# Syndication feeds (RSS 2.0 and Atom 1.0) -------------------------------------------------------------------
#
#     latest = Feed(title = "My blog", link = "/blog/", description = "New posts",
#                   items = () -> filter(Post; published = true)[1:10],
#                   item_description = p -> p.body, item_pubdate = :created)
#     atom = Feed(latest; feed_type = :atom)                         # the same feed as Atom
#     urlpatterns = [path("feed/", latest), path("feed/atom/", atom), ...]
#
# A feed is a view. For feeds about one object, `get_object(req; url_kwargs...)` finds it and
# the feed-level functions receive it: `title = author -> "Posts by $(author.name)"`.

"""
    Feed(; title, link, items, description="", subtitle=nothing, item_title=string, item_description=nothing,
         item_link=get_absolute_url, item_pubdate=nothing, item_updateddate=nothing,
         item_author_name=nothing, item_author_email=nothing, item_author_link=nothing,
         item_guid=nothing, item_guid_is_permalink=nothing, item_categories=nothing, item_comments=nothing,
         item_enclosures=nothing, item_copyright=nothing, get_object=nothing, feed_type=:rss, language=nothing,
         author_name=nothing, author_email=nothing, author_link=nothing, categories=nothing, feed_copyright=nothing,
         feed_url=nothing, ttl=nothing, title_template=nothing, description_template=nothing,
         geometry=nothing, item_geometry=nothing, geo_format=:georss)

A syndication feed, usable directly as a view. Feed-level options are values or functions
(of the object from `get_object`, or of nothing); item options are values, functions of
the item, or `Symbol`s naming one of its fields. Links may be paths: they are made absolute
with the request's host (`add_domain`). `title_template`/`description_template` render each item's title or
description with `obj` (the item) and `site` (the host) in the context. `item_enclosures` gives
`(url, length, mime_type)` tuples (RSS allows one per item). Naive datetimes are taken to be in TIME_ZONE.

Geographic feeds (Django's `django.contrib.gis.feeds`): `item_geometry` gives each item a point, line or polygon (a
GIS geometry in SRID 4326, or `(lon, lat)`), and `geometry` the feed a box (`(xmin, ymin, xmax, ymax)` or
`((xmin, ymin), (xmax, ymax))`), written as GeoRSS elements (`georss:point`, ...), or, with `geo_format = :w3c`, as
W3C Geo's `geo:lat`/`geo:lon` (points only, on RSS).
"""
Base.@kwdef struct Feed
    title::Any
    link::Any
    items::Any
    description::Any = ""
    subtitle::Any = nothing
    item_title::Any = nothing
    item_description::Any = nothing
    item_link::Any = nothing
    item_pubdate::Any = nothing
    item_updateddate::Any = nothing
    item_author_name::Any = nothing
    item_author_email::Any = nothing
    item_author_link::Any = nothing
    item_guid::Any = nothing
    item_guid_is_permalink::Any = nothing
    item_categories::Any = nothing
    item_comments::Any = nothing
    item_enclosures::Any = nothing
    item_copyright::Any = nothing
    get_object::Any = nothing
    feed_type::Symbol = :rss
    language::Any = nothing
    author_name::Any = nothing
    author_email::Any = nothing
    author_link::Any = nothing
    categories::Any = nothing
    feed_copyright::Any = nothing
    feed_url::Any = nothing
    ttl::Any = nothing
    title_template::Any = nothing
    description_template::Any = nothing
    geometry::Any = nothing
    item_geometry::Any = nothing
    geo_format::Symbol = :georss
end
"A copy of a feed with some options changed: `Feed(rss_feed; feed_type = :atom)`."
Feed(f::Feed; kw...) = Feed(; (k => getfield(f, k) for k in fieldnames(Feed))..., kw...)

feed_value(f, obj) = f isa Function ? (applicable(f, obj) ? f(obj) : f()) : f
item_attr(f, item, default = nothing) = f === nothing ? default : f isa Symbol ? getproperty(item, f) : f isa Function ? f(item) : f

"""
    add_domain(domain, url; secure = false) -> String

Django's syndication `add_domain`: a URL with a scheme (`http:`, `https:`, `mailto:` ...) stays as it is,
`//host/path` gets `http:` (or `https:`), and a path gets the scheme and `domain`.
"""
function add_domain(domain::AbstractString, url::AbstractString; secure::Bool = false)
    scheme = secure ? "https" : "http"
    occursin(r"^[a-z][a-z0-9+.-]*:"i, url) && return String(url)
    startswith(url, "//") && return scheme * ":" * url
    scheme * "://" * domain * (startswith(url, "/") ? url : "/" * url)
end

"An aware datetime for a feed: naive ones are taken to be in TIME_ZONE (Django's), dates are midnight."
feed_datetime(d::TimeZones.ZonedDateTime) = d
feed_datetime(d::DateTime) = make_aware(d, default_timezone())
feed_datetime(d::Date) = feed_datetime(DateTime(d))
feed_datetime(x) = (d = todatetime(x); d === nothing ? nothing : feed_datetime(d))
utc_of(z) = DateTime(TimeZones.astimezone(z, UTC_TZ))
"RFC 2822 (RSS), in the datetime's own offset: `Thu, 03 Jan 2008 12:30:00 +0100`."
rfc822(d) = (z = feed_datetime(d); z === nothing ? "" : Dates.format(DateTime(z), "e, dd u yyyy HH:MM:SS") * " " * replace(offset_string(z), ":" => ""))
"RFC 3339 (Atom), in the datetime's own offset: `2008-01-03T12:30:00+01:00`."
rfc3339(d) = (z = feed_datetime(d); z === nothing ? "" : Dates.format(DateTime(z), "yyyy-mm-ddTHH:MM:SS") * offset_string(z))

# (django.utils.feedgenerator's: a naive datetime as it is, marked -0000 or Z; a date at midnight)
"Django's `rfc2822_date`: `Fri, 14 Nov 2008 13:37:00 +0100` (an aware time's offset; `-0000` for a naive one or a date)."
function rfc2822_date(d)
    dt = d isa TimeZones.ZonedDateTime ? DateTime(d) : todatetime(d)
    Dates.format(dt, "e, dd u yyyy HH:MM:SS") * " " * (d isa TimeZones.ZonedDateTime ? replace(offset_string(d), ":" => "") : "-0000")
end
"Django's `rfc3339_date`: `2008-11-14T13:37:00+02:00` (an aware time's offset; `Z` for a naive one or a date)."
function rfc3339_date(d)
    dt = d isa TimeZones.ZonedDateTime ? DateTime(d) : todatetime(d)
    Dates.format(dt, "yyyy-mm-ddTHH:MM:SS") * (d isa TimeZones.ZonedDateTime ? offset_string(d) : "Z")
end
"Django's `get_tag_uri`: a TagURI for an item's link and date (`tag:example.org,2004-10-25:/foo/bar/headline`)."
function get_tag_uri(url::AbstractString, date)
    m = match(r"^(?:[a-zA-Z][a-zA-Z0-9+.-]*:)?(?://(?:[^@/?#]*@)?(\[[^\]]*\]|[^:/?#]*)(?::\d*)?)?([^?#]*)(?:\?[^#]*)?(?:#(.*))?$", url)
    host, path, frag = lowercase(something(m[1], "")), m[2], something(m[3], "")
    d = date === nothing ? "" : "," * Dates.format(Date(todatetime(date)), "yyyy-mm-dd")
    "tag:$host$d:$path/$frag"
end

function (f::Feed)(req::Request; kw...)
    obj = f.get_object === nothing ? nothing : f.get_object(req; kw...)
    site = site_domain(req)
    abs_(u) = u === nothing ? nothing : add_domain(site, string(u); secure = is_secure(req))
    link = abs_(feed_value(f.link, obj))
    self = abs_(something(feed_value(f.feed_url, obj), full_path(req)))
    items = collect(feed_value(f.items, obj))
    render_item(tpl, item, fallback) = tpl === nothing ? fallback :
        render_to_string(tpl, Dict{String,Any}("obj" => item, "site" => site); request = req)
    function item_link(item)
        l = item_attr(f.item_link, item, nothing)
        l !== nothing && return l
        item isa AbstractString && return item
        u = absolute_url(item)
        u === nothing && throw(ImproperlyConfigured("Give your $(nameof(typeof(item))) class a get_absolute_url() method, or define an item_link in your Feed."))
        u
    end
    entries = map(items) do item
        l = abs_(item_link(item))
        (title = string(render_item(f.title_template, item, item_attr(f.item_title, item, item))),
         description = (d = render_item(f.description_template, item, item_attr(f.item_description, item)); d === nothing ? nothing : string(d)),
         link = l, pubdate = item_attr(f.item_pubdate, item), updated = item_attr(f.item_updateddate, item),
         author = item_attr(f.item_author_name, item), author_email = item_attr(f.item_author_email, item),
         author_link = item_attr(f.item_author_link, item), guid = item_attr(f.item_guid, item),
         permalink = item_attr(f.item_guid_is_permalink, item), comments = item_attr(f.item_comments, item),
         enclosures = collect(something(item_attr(f.item_enclosures, item), Any[])),
         copyright = item_attr(f.item_copyright, item), categories = something(item_attr(f.item_categories, item), String[]),
         geo = georss_element(item_attr(f.item_geometry, item), f.geo_format === :w3c))
    end
    geo = f.geometry !== nothing || f.item_geometry !== nothing
    geo_ns = !geo ? "" : f.geo_format === :w3c ? " xmlns:geo=\"http://www.w3.org/2003/01/geo/wgs84_pos#\"" : " xmlns:georss=\"http://www.georss.org/georss\""
    feed_geo = georss_element(feed_value(f.geometry, obj), f.geo_format === :w3c)
    # the latest item date (updated, else published), as Django's latest_post_date: the feed's date and Last-Modified
    stamps = [feed_datetime(something(e.updated, e.pubdate)) for e in entries if something(e.updated, e.pubdate, missing) !== missing]
    latest = isempty(stamps) ? nothing : stamps[argmax(utc_of.(stamps))]
    built = something(latest, TimeZones.now(UTC_TZ))
    x = xml_escape
    io = IOBuffer()
    title, desc, lang = feed_value(f.title, obj), feed_value(f.description, obj), feed_value(f.language, obj)
    author, aemail, alink = feed_value(f.author_name, obj), feed_value(f.author_email, obj), feed_value(f.author_link, obj)
    cats, copyright, ttl = something(feed_value(f.categories, obj), String[]), feed_value(f.feed_copyright, obj), feed_value(f.ttl, obj)
    if f.feed_type === :atom
        subtitle = something(feed_value(f.subtitle, obj), desc, "")
        print(io, """<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom"$(geo_ns)$(lang === nothing ? "" : " xml:lang=\"$(x(lang))\"")>""")
        print(io, "<title>", x(title), "</title><link href=\"", x(link), "\" rel=\"alternate\"/><link href=\"", x(self), "\" rel=\"self\"/>")
        print(io, "<id>", x(link), "</id><updated>", rfc3339(built), "</updated>")
        isempty(string(subtitle)) || print(io, "<subtitle>", x(subtitle), "</subtitle>")
        if author !== nothing
            print(io, "<author><name>", x(author), "</name>")
            aemail === nothing || print(io, "<email>", x(aemail), "</email>")
            alink === nothing || print(io, "<uri>", x(alink), "</uri>")
            print(io, "</author>")
        end
        foreach(c -> print(io, "<category term=\"", x(c), "\"/>"), cats)
        copyright === nothing || print(io, "<rights>", x(copyright), "</rights>")
        print(io, feed_geo)
        for e in entries
            print(io, "<entry><title>", x(e.title), "</title><link href=\"", x(e.link), "\" rel=\"alternate\"/>")
            e.pubdate === nothing || print(io, "<published>", rfc3339(e.pubdate), "</published>")
            print(io, "<updated>", rfc3339(something(e.updated, e.pubdate, built)), "</updated>")
            print(io, "<id>", x(something(e.guid, e.link)), "</id>")
            if e.author !== nothing
                print(io, "<author><name>", x(e.author), "</name>")
                e.author_email === nothing || print(io, "<email>", x(e.author_email), "</email>")
                e.author_link === nothing || print(io, "<uri>", x(e.author_link), "</uri>")
                print(io, "</author>")
            end
            e.description === nothing || print(io, "<summary type=\"html\">", x(e.description), "</summary>")
            for (u, len, mime) in e.enclosures
                print(io, "<link href=\"", x(abs_(u)), "\" rel=\"enclosure\" length=\"", x(len), "\" type=\"", x(mime), "\"/>")
            end
            foreach(c -> print(io, "<category term=\"", x(c), "\"/>"), e.categories)
            e.copyright === nothing || print(io, "<rights>", x(e.copyright), "</rights>")
            print(io, e.geo, "</entry>")
        end
        print(io, "</feed>")
        ct = "application/atom+xml; charset=utf-8"
    else
        print(io, """<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"$(geo_ns)><channel>""")
        print(io, "<title>", x(title), "</title><link>", x(link), "</link><description>", x(something(desc, "")), "</description>")
        print(io, "<atom:link href=\"", x(self), "\" rel=\"self\"/>")
        lang === nothing || print(io, "<language>", x(lang), "</language>")
        foreach(c -> print(io, "<category>", x(c), "</category>"), cats)
        copyright === nothing || print(io, "<copyright>", x(copyright), "</copyright>")
        print(io, "<lastBuildDate>", rfc822(built), "</lastBuildDate>")
        ttl === nothing || print(io, "<ttl>", ttl, "</ttl>")
        print(io, feed_geo)
        for e in entries
            print(io, "<item><title>", x(e.title), "</title><link>", x(e.link), "</link>")
            e.description === nothing || print(io, "<description>", x(e.description), "</description>")
            # RSS's author is an address (with the name in parentheses); a name alone goes in dc:creator (as Django)
            if e.author_email !== nothing
                print(io, "<author>", x(e.author === nothing ? e.author_email : "$(e.author_email) ($(e.author))"), "</author>")
            elseif e.author !== nothing
                print(io, "<dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", x(e.author), "</dc:creator>")
            end
            e.pubdate === nothing || print(io, "<pubDate>", rfc822(e.pubdate), "</pubDate>")
            e.comments === nothing || print(io, "<comments>", x(e.comments), "</comments>")
            # a guid other than the link isn't a permalink unless item_guid_is_permalink says so
            perma = e.permalink isa Bool ? " isPermaLink=\"$(e.permalink)\"" : e.guid === nothing ? "" : " isPermaLink=\"false\""
            print(io, "<guid", perma, ">", x(something(e.guid, e.link)), "</guid>")
            length(e.enclosures) > 1 && throw(ArgumentError(
                "RSS feed items may only have one enclosure, see http://www.rssboard.org/rss-profile#element-channel-item-enclosure"))
            for (u, len, mime) in e.enclosures
                print(io, "<enclosure url=\"", x(abs_(u)), "\" length=\"", x(len), "\" type=\"", x(mime), "\"/>")
            end
            foreach(c -> print(io, "<category>", x(c), "</category>"), e.categories)
            print(io, e.geo, "</item>")
        end
        print(io, "</channel></rss>")
        ct = "application/rss+xml; charset=utf-8"
    end
    resp = HttpResponse(String(take!(io)); content_type = ct)
    latest === nothing || setheader!(resp, "Last-Modified", http_date(utc_of(latest)))
    resp
end

"GeoRSS coordinates: each `(x, y)` as `lat lon`, Django's \"%f %f\"."
georss_coords(cs) = join((@sprintf("%f %f", Float64(c[2]), Float64(c[1])) for c in cs), " ")
georss_point(c, w3c) = w3c ? "<geo:lat>$(@sprintf("%f", Float64(c[2])))</geo:lat><geo:lon>$(@sprintf("%f", Float64(c[1])))</geo:lon>" :
                       "<georss:point>$(georss_coords((c,)))</georss:point>"
"""A feed's or an item's geometry as GeoRSS (or W3C Geo) elements (Django's `GeoFeedMixin.add_georss_element`): a
geometry, `(x, y)`, a box `(xmin, ymin, xmax, ymax)` or `((xmin, ymin), (xmax, ymax))`."""
function georss_element(geom, w3c::Bool)
    geom === nothing && return ""
    if geom isa Union{Tuple,AbstractVector}
        box = nothing
        if first(geom) isa Union{Tuple,AbstractVector}
            length(geom) == 2 || throw(ArgumentError("Only should be two sets of coordinates."))
            box = geom
        elseif length(geom) == 2
            return georss_point(geom, w3c)
        elseif length(geom) == 4
            box = ((geom[1], geom[2]), (geom[3], geom[4]))
        else
            throw(ArgumentError("Only should be 2 or 4 numeric elements."))
        end
        w3c && throw(ArgumentError("Cannot use simple GeoRSS box in W3C Geo feeds."))
        return "<georss:box>$(georss_coords(box))</georss:box>"
    end
    geom isa Point && return georss_point((geom.x, geom.y), w3c)
    w3c && throw(ArgumentError("W3C Geo only supports Point geometries."))
    geom isa LineString && return "<georss:line>$(georss_coords(geom.coords))</georss:line>"
    geom isa Polygon && return "<georss:polygon>$(georss_coords(geom.rings[1]))</georss:polygon>"
    throw(ArgumentError("Geometry type \"$(geom_type(geom))\" not supported."))
end
