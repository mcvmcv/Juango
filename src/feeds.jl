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
    Feed(; title, link, items, description="", item_title=string, item_description=nothing,
         item_link=get_absolute_url, item_pubdate=nothing, item_updateddate=nothing,
         item_author_name=nothing, item_guid=nothing, item_categories=nothing,
         get_object=nothing, feed_type=:rss, language=nothing, author_name=nothing,
         feed_url=nothing, ttl=nothing, title_template=nothing, description_template=nothing)

A syndication feed, usable directly as a view. Feed-level options are values or functions
(of the object from `get_object`, or of nothing); item options are values, functions of
the item, or `Symbol`s naming one of its fields. Links may be paths: they are made absolute
with the request's host. `title_template`/`description_template` render each item's title or
description with `obj` (the item) and `site` (the host) in the context.
"""
Base.@kwdef struct Feed
    title::Any
    link::Any
    items::Any
    description::Any = ""
    item_title::Any = nothing
    item_description::Any = nothing
    item_link::Any = nothing
    item_pubdate::Any = nothing
    item_updateddate::Any = nothing
    item_author_name::Any = nothing
    item_guid::Any = nothing
    item_categories::Any = nothing
    get_object::Any = nothing
    feed_type::Symbol = :rss
    language::Any = nothing
    author_name::Any = nothing
    feed_url::Any = nothing
    ttl::Any = nothing
    title_template::Any = nothing
    description_template::Any = nothing
end
"A copy of a feed with some options changed: `Feed(rss_feed; feed_type = :atom)`."
Feed(f::Feed; kw...) = Feed(; (k => getfield(f, k) for k in fieldnames(Feed))..., kw...)

feed_value(f, obj) = f isa Function ? (applicable(f, obj) ? f(obj) : f()) : f
item_attr(f, item, default = nothing) = f === nothing ? default : f isa Symbol ? getproperty(item, f) : f isa Function ? f(item) : f

rfc822(d) = (u = utc_datetime(d); u === nothing ? "" : Dates.format(u, "e, dd u yyyy HH:MM:SS") * " +0000")
rfc3339(d) = (u = utc_datetime(d); u === nothing ? "" : Dates.format(u, "yyyy-mm-ddTHH:MM:SS") * "Z")

function (f::Feed)(req::Request; kw...)
    obj = f.get_object === nothing ? nothing : f.get_object(req; kw...)
    abs_(u) = u === nothing ? nothing : absolute(req, string(u), nothing)
    link = abs_(feed_value(f.link, obj))
    self = abs_(something(feed_value(f.feed_url, obj), full_path(req)))
    items = collect(feed_value(f.items, obj))
    site = get_host(req)
    render_item(tpl, item, fallback) = tpl === nothing ? fallback :
        render_to_string(tpl, Dict{String,Any}("obj" => item, "site" => site); request = req)
    entries = map(items) do item
        (title = string(render_item(f.title_template, item, item_attr(f.item_title, item, item))),
         description = (d = render_item(f.description_template, item, item_attr(f.item_description, item)); d === nothing ? nothing : string(d)),
         link = abs_(item_attr(f.item_link, item, nothing) === nothing ? get_absolute_url_or_error(item) : item_attr(f.item_link, item)),
         pubdate = item_attr(f.item_pubdate, item), updated = item_attr(f.item_updateddate, item),
         author = item_attr(f.item_author_name, item), guid = item_attr(f.item_guid, item),
         categories = something(item_attr(f.item_categories, item), String[]))
    end
    dates = [utc_datetime(something(e.updated, e.pubdate)) for e in entries if something(e.updated, e.pubdate, missing) !== missing]
    latest = isempty(dates) ? nothing : maximum(dates)
    x = xml_escape
    io = IOBuffer()
    title, desc, lang = feed_value(f.title, obj), feed_value(f.description, obj), feed_value(f.language, obj)
    author = feed_value(f.author_name, obj)
    if f.feed_type === :atom
        print(io, """<?xml version="1.0" encoding="utf-8"?>\n<feed xmlns="http://www.w3.org/2005/Atom"$(lang === nothing ? "" : " xml:lang=\"$(x(lang))\"")>""")
        print(io, "<title>", x(title), "</title><link href=\"", x(link), "\" rel=\"alternate\"/><link href=\"", x(self), "\" rel=\"self\"/>")
        print(io, "<id>", x(link), "</id><updated>", rfc3339(something(latest, now(Dates.UTC))), "</updated>")
        isempty(string(something(desc, ""))) || print(io, "<subtitle>", x(desc), "</subtitle>")
        author === nothing || print(io, "<author><name>", x(author), "</name></author>")
        for e in entries
            print(io, "<entry><title>", x(e.title), "</title><link href=\"", x(e.link), "\" rel=\"alternate\"/>")
            e.pubdate === nothing || print(io, "<published>", rfc3339(e.pubdate), "</published>")
            print(io, "<updated>", rfc3339(something(e.updated, e.pubdate, latest, now(Dates.UTC))), "</updated>")
            print(io, "<id>", x(something(e.guid, e.link)), "</id>")
            e.author === nothing || print(io, "<author><name>", x(e.author), "</name></author>")
            e.description === nothing || print(io, "<summary type=\"html\">", x(e.description), "</summary>")
            for c in e.categories
                print(io, "<category term=\"", x(c), "\"/>")
            end
            print(io, "</entry>")
        end
        print(io, "</feed>")
        ct = "application/atom+xml; charset=utf-8"
    else
        print(io, """<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom"><channel>""")
        print(io, "<title>", x(title), "</title><link>", x(link), "</link><description>", x(something(desc, "")), "</description>")
        print(io, "<atom:link href=\"", x(self), "\" rel=\"self\"/>")
        lang === nothing || print(io, "<language>", x(lang), "</language>")
        latest === nothing || print(io, "<lastBuildDate>", rfc822(latest), "</lastBuildDate>")
        ttl = feed_value(f.ttl, obj)
        ttl === nothing || print(io, "<ttl>", ttl, "</ttl>")
        for e in entries
            print(io, "<item><title>", x(e.title), "</title><link>", x(e.link), "</link>")
            e.description === nothing || print(io, "<description>", x(e.description), "</description>")
            e.author === nothing || print(io, "<dc:creator xmlns:dc=\"http://purl.org/dc/elements/1.1/\">", x(e.author), "</dc:creator>")
            e.pubdate === nothing || print(io, "<pubDate>", rfc822(e.pubdate), "</pubDate>")
            print(io, "<guid", e.guid === nothing ? "" : " isPermaLink=\"false\"", ">", x(something(e.guid, e.link)), "</guid>")
            for c in e.categories
                print(io, "<category>", x(c), "</category>")
            end
            print(io, "</item>")
        end
        print(io, "</channel></rss>")
        ct = "application/rss+xml; charset=utf-8"
    end
    HttpResponse(String(take!(io)); content_type = ct)
end
