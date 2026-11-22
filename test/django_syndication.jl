# Django's syndication tests, ported (#227): tests/syndication_tests (SyndicationFeedTest: the RSS 2.0 and
# Atom feeds, latest post dates, time zones, enclosures, templates, add_domain, get_object).
# julia --project=test test/django_syndication.jl   (see setup.jl)
#
# Juango's feeds are values (`Feed(; title, items, item_pubdate, ...)`), not classes; the tests check the
# XML Django's tests check, by element. Differences kept: a guid other than the link is marked
# isPermaLink="false" unless item_guid_is_permalink says otherwise (Django leaves the attribute out), and
# there are no RSS 0.91 feeds or custom feed generators. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DsyEntry
    title = CharField(max_length = 200)
    updated = DateTimeField()
    published = DateTimeField()
    Meta(table = "dsy_entry", ordering = ["updated"])
end
Juango.get_absolute_url(e::DsyEntry) = "/blog/$(e.id)/"
Base.show(io::IO, e::DsyEntry) = print(io, e.title)
@model struct DsyArticle            # no get_absolute_url
    title = CharField(max_length = 200)
    entry = ForeignKey(DsyEntry; on_delete = :CASCADE)
    Meta(table = "dsy_article")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DsyEntry, DsyArticle]); append!(PORT_MODELS, [DsyEntry, DsyArticle])
end

"The text of each `<tag>...</tag>` in `x`, in order."
dsy_all(x, tag) = [m[1] for m in eachmatch(Regex("<$tag(?:\\s[^>]*)?>(.*?)</$tag>", "s"), x)]
dsy_one(x, tag) = (v = dsy_all(x, tag); isempty(v) ? nothing : v[1])
dsy_items(x, tag = "item") = dsy_all(x, tag)

@testset "django syndication: SyndicationFeedTest" begin
    port_block() do
        e1 = save!(DsyEntry(title = "My first entry", updated = DateTime(1980, 1, 1, 12, 30), published = DateTime(1986, 9, 25, 20, 15)))
        e2 = save!(DsyEntry(title = "My second entry", updated = DateTime(2008, 1, 2, 12, 30), published = DateTime(2006, 3, 17, 18, 0)))
        e3 = save!(DsyEntry(title = "My third entry", updated = DateTime(2008, 1, 2, 13, 30), published = DateTime(2005, 6, 14, 10, 45)))
        e4 = save!(DsyEntry(title = "A & B < C > D", updated = DateTime(2008, 1, 3, 13, 30), published = DateTime(2005, 11, 25, 12, 11, 23)))
        e5 = save!(DsyEntry(title = "My last entry", updated = DateTime(2013, 1, 20, 0, 0), published = DateTime(2013, 3, 25, 20, 0)))
        a1 = save!(DsyArticle(title = "My first article", entry = e1))
        rss = Feed(title = "My blog", description = "A more thorough description of my blog.", link = "/blog/",
                   items = () -> objects(DsyEntry), author_name = "Sally Smith", author_email = "test@example.com",
                   author_link = "http://www.example.com/", categories = ["python", "django"],
                   feed_copyright = "Copyright (c) 2007, Sally Smith", ttl = 600,
                   item_title = :title, item_description = e -> "Overridden description: $(e.title)",
                   item_pubdate = :published, item_updateddate = :updated,
                   item_author_name = "Sally Smith", item_author_email = "test@example.com", item_author_link = "http://www.example.com/",
                   item_comments = e -> get_absolute_url(e) * "article/$(e.id)/comments",
                   item_categories = ["python", "testing"], item_copyright = "Copyright (c) 2007, Sally Smith")
        atom = Feed(rss; feed_type = :atom, subtitle = "A more thorough description of my blog.")
        latest_pub = Feed(rss; item_updateddate = nothing)          # (the latest pubdate)
        naive = Feed(rss; items = () -> filter(objects(DsyEntry); id = e1.id))
        guid_false = Feed(rss; item_guid = e -> "/blog/$(e.id)/guid", item_guid_is_permalink = false)
        guid_true = Feed(rss; item_guid = e -> "http://example.com/blog/$(e.id)/", item_guid_is_permalink = true)
        enc1 = Feed(rss; items = () -> filter(objects(DsyEntry); id = e1.id), item_enclosures = [("http://example.com/file.mp3", "0", "audio/mpeg")])
        enc2 = Feed(enc1; item_enclosures = [("http://example.com/hello.png", "0", "image/png"), ("http://example.com/goodbye.png", "0", "image/png")])
        noabs = Feed(rss; items = () -> objects(DsyArticle))
        write(joinpath(TPL, "dsy_title.html"), "Title in your templates: {{ obj }}")
        write(joinpath(TPL, "dsy_description.html"), "Description in your templates: {{ obj.title }}")
        templated = Feed(rss; title_template = "dsy_title.html", description_template = "dsy_description.html",
                         items = () -> filter(objects(DsyEntry); id = e1.id))
        self_url = Feed(rss; feed_url = "/customfeedurl/")
        secure_links = Feed(rss; link = "https://djangoproject.com/blog/", items = () -> filter(objects(DsyEntry); id = e1.id))
        by_entry = Feed(rss; get_object = (req; id) -> get_object_or_404(objects(DsyEntry); id = id),
                        title = e -> "Feed about $(e.title)", items = e -> filter(objects(DsyArticle); entry = e), item_link = a -> "/a/$(a.id)/",
                        item_pubdate = nothing, item_updateddate = nothing, item_comments = nothing)
        old = settings.ROOT_URLCONF
        configure!(ROOT_URLCONF = vcat(old, [path("syndication/rss2/", rss), path("syndication/atom/", atom),
            path("syndication/latest/", latest_pub), path("syndication/naive/", naive), path("syndication/guid-false/", guid_false),
            path("syndication/guid-true/", guid_true), path("syndication/enc1/", enc1), path("syndication/enc2/", enc2),
            path("syndication/atom-enc1/", Feed(enc1; feed_type = :atom)), path("syndication/atom-enc2/", Feed(enc2; feed_type = :atom)),
            path("syndication/noabs/", noabs), path("syndication/template/", templated), path("syndication/custom-url/", self_url),
            path("syndication/secure/", secure_links), path("syndication/rss2/articles/<int:id>/", by_entry)]))
        try
            c = Client()
            r = get(c, "/syndication/rss2/")                                              # test_rss2_feed
            x = text(r)
            @test getheader(r, "Content-Type") == "application/rss+xml; charset=utf-8"
            @test occursin("<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\"><channel>", x)
            ch = x[1:first(findfirst("<item>", x)) - 1]
            @test dsy_one(ch, "title") == "My blog" && dsy_one(ch, "description") == "A more thorough description of my blog."
            @test dsy_one(ch, "link") == "http://testserver/blog/" && dsy_one(ch, "lastBuildDate") == "Sun, 20 Jan 2013 00:00:00 +0000"
            @test dsy_one(ch, "ttl") == "600" && dsy_one(ch, "copyright") == "Copyright (c) 2007, Sally Smith"
            @test dsy_all(ch, "category") == ["python", "django"]
            @test occursin("<atom:link href=\"http://testserver/syndication/rss2/\" rel=\"self\"/>", ch)
            items = dsy_items(x)
            @test length(items) == 5
            it = items[1]
            @test dsy_one(it, "title") == "My first entry" && dsy_one(it, "description") == "Overridden description: My first entry"
            @test dsy_one(it, "link") == "http://testserver/blog/$(e1.id)/" && dsy_one(it, "guid") == "http://testserver/blog/$(e1.id)/"
            @test dsy_one(it, "pubDate") == "Thu, 25 Sep 1986 20:15:00 +0000"
            @test dsy_one(it, "author") == "test@example.com (Sally Smith)" && dsy_one(it, "comments") == "/blog/$(e1.id)/article/$(e1.id)/comments"
            @test dsy_all(it, "category") == ["python", "testing"]
            @test count("<guid>", x) == 5                                                 # (a link guid: no isPermaLink)
            @test getheader(r, "Last-Modified") == "Sun, 20 Jan 2013 00:00:00 GMT"         # test_feed_last_modified_time

            x = text(get(c, "/syndication/guid-false/"))                                  # test_rss2_feed_guid_permalink_false
            @test occursin("<guid isPermaLink=\"false\">/blog/$(e1.id)/guid</guid>", x)
            x = text(get(c, "/syndication/guid-true/"))                                   # test_rss2_feed_guid_permalink_true
            @test occursin("<guid isPermaLink=\"true\">http://example.com/blog/$(e1.id)/</guid>", x)
            x = text(get(c, "/syndication/enc1/"))                                        # test_rss2_single_enclosure
            @test occursin("<enclosure url=\"http://example.com/file.mp3\" length=\"0\" type=\"audio/mpeg\"/>", x)
            e = try get(Client(; raise_request_exception = true), "/syndication/enc2/") catch e; e end   # test_rss2_multiple_enclosures
            @test e isa ArgumentError && occursin("RSS feed items may only have one enclosure", e.msg)

            r = get(c, "/syndication/atom/")                                              # test_atom_feed
            x = text(r)
            @test getheader(r, "Content-Type") == "application/atom+xml; charset=utf-8"
            head = x[1:first(findfirst("<entry>", x)) - 1]
            @test dsy_one(head, "title") == "My blog" && dsy_one(head, "subtitle") == "A more thorough description of my blog."
            @test occursin("<link href=\"http://testserver/blog/\" rel=\"alternate\"/>", head) && dsy_one(head, "id") == "http://testserver/blog/"
            @test dsy_one(head, "updated") == "2013-01-20T00:00:00+00:00"
            @test occursin("<author><name>Sally Smith</name><email>test@example.com</email><uri>http://www.example.com/</uri></author>", head)
            @test occursin("<category term=\"python\"/><category term=\"django\"/>", head) && dsy_one(head, "rights") == "Copyright (c) 2007, Sally Smith"
            entries = dsy_items(x, "entry")
            @test length(entries) == 5
            en = entries[1]
            @test dsy_one(en, "title") == "My first entry" && dsy_one(en, "id") == "http://testserver/blog/$(e1.id)/"
            @test dsy_one(en, "summary") == "Overridden description: My first entry"
            @test dsy_one(en, "published") == "1986-09-25T20:15:00+00:00" && dsy_one(en, "updated") == "1980-01-01T12:30:00+00:00"   # test_atom_feed_published_and_updated_elements
            @test occursin("<author><name>Sally Smith</name><email>test@example.com</email><uri>http://www.example.com/</uri></author>", en)
            @test occursin("<category term=\"python\"/><category term=\"testing\"/>", en) && dsy_one(en, "rights") == "Copyright (c) 2007, Sally Smith"
            x = text(get(c, "/syndication/atom-enc1/"))                                   # test_atom_single_enclosure
            @test occursin("<link href=\"http://example.com/file.mp3\" rel=\"enclosure\" length=\"0\" type=\"audio/mpeg\"/>", x)
            x = text(get(c, "/syndication/atom-enc2/"))                                   # test_atom_multiple_enclosures
            @test count("rel=\"enclosure\"", x) == 2

            x = text(get(c, "/syndication/latest/"))                                      # test_latest_post_date (the latest pubdate)
            @test dsy_one(x, "lastBuildDate") == "Mon, 25 Mar 2013 20:00:00 +0000"
            @test getheader(get(c, "/syndication/latest/"), "Last-Modified") == "Mon, 25 Mar 2013 20:00:00 GMT"
            x = text(get(c, "/syndication/rss2/"))                                         # test_title_escaping
            @test occursin("<title>A &amp; B &lt; C &gt; D</title>", x)
            override_settings(TIME_ZONE = "Europe/Paris") do                              # test_naive_datetime_conversion (naive: in TIME_ZONE)
                x = text(get(c, "/syndication/naive/"))
                @test dsy_one(x, "pubDate") == "Thu, 25 Sep 1986 20:15:00 +0200" && dsy_one(x, "lastBuildDate") == "Tue, 01 Jan 1980 12:30:00 +0100"
            end
            aware = Feed(naive; item_pubdate = e -> Juango.TimeZones.ZonedDateTime(DateTime(2008, 1, 2, 12, 30), Juango.TimeZones.FixedTimeZone("X", 42 * 60)))
            x = text(aware(Request("GET", "/f/"; headers = Dict("host" => "testserver"))))  # test_aware_datetime_conversion (the offset kept)
            @test dsy_one(x, "pubDate") == "Wed, 02 Jan 2008 12:30:00 +0042"

            x = text(get(c, "/syndication/custom-url/"))                                  # test_feed_url
            @test occursin("<atom:link href=\"http://testserver/customfeedurl/\" rel=\"self\"/>", x)
            x = text(get(c, "/syndication/secure/"))                                       # test_secure_urls
            @test dsy_one(x, "link") == "https://djangoproject.com/blog/"
            x = text(get(c, "/syndication/rss2/"; secure = true))                          # (a secure request: https links)
            @test occursin("<link>https://testserver/blog/</link>", x)
            e = try get(Client(; raise_request_exception = true), "/syndication/noabs/") catch e; e end   # test_item_link_error
            @test e isa Juango.ImproperlyConfigured && occursin("Give your DsyArticle class a get_absolute_url() method, or define an item_link", e.msg)
            x = text(get(c, "/syndication/template/"))                                    # test_template_feed
            @test dsy_one(x, "title") == "My blog" && occursin("<item><title>Title in your templates: My first entry</title>", x)
            @test occursin("<description>Description in your templates: My first entry</description>", x)
            x = text(get(c, "/syndication/rss2/articles/$(e1.id)/"))                      # test_get_object
            @test dsy_one(x, "title") == "Feed about My first entry" && occursin("<link>http://testserver/a/$(a1.id)/</link>", x)
            @test get(c, "/syndication/rss2/articles/0/").status == 404                   # test_get_non_existent_object
        finally
            configure!(ROOT_URLCONF = old)
        end
    end
    # test_add_domain
    @test add_domain("example.com", "/foo/?arg=value") == "http://example.com/foo/?arg=value"
    @test add_domain("example.com", "/foo/?arg=value"; secure = true) == "https://example.com/foo/?arg=value"
    @test add_domain("example.com", "http://djangoproject.com/doc/") == "http://djangoproject.com/doc/"
    @test add_domain("example.com", "https://djangoproject.com/doc/") == "https://djangoproject.com/doc/"
    @test add_domain("example.com", "mailto:uhoh@djangoproject.com") == "mailto:uhoh@djangoproject.com"
    @test add_domain("example.com", "//example.com/foo/?arg=value") == "http://example.com/foo/?arg=value"
    # not translated: RSS 0.91, custom feed generators and their extra elements, stylesheets (Django 5.2),
    # get_context_data, decorated methods (Python's), feed_guid
end
