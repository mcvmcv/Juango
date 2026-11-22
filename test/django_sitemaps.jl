# Django's sitemap tests, ported (#227): tests/sitemaps_tests (HTTPSitemapTests, HTTPSSitemapTests,
# GenericViewsSitemapTests' equivalent, the flatpages sitemap).
# julia --project=test test/django_sitemaps.jl   (see setup.jl)
#
# Juango's sitemaps are values (`Sitemap(items; location, lastmod, ...)`) served by sitemap_urls, not
# classes with methods. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DsmTestModel
    name = CharField(max_length = 100)
    lastmod = DateTimeField(null = true)
    Meta(table = "dsm_testmodel", ordering = ["id"])
end
redirect_stdout(devnull) do
    Juango.sync_models!([DsmTestModel]); push!(PORT_MODELS, DsmTestModel)
end

const DSM_NS = """<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">"""
dsm_urlset(body) = """<?xml version="1.0" encoding="UTF-8"?>\n$DSM_NS\n$body</urlset>\n"""
dsm_index(body) = """<?xml version="1.0" encoding="UTF-8"?>\n<sitemapindex xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n$body</sitemapindex>\n"""

@testset "django sitemaps" begin
    port_block() do
        save!(DsmTestModel(name = "Test Object", lastmod = DateTime(2013, 3, 13, 10)))
        # SimpleSitemap: one location, changefreq "never", priority 0.5, lastmod now (here: a fixed day)
        simple = Sitemap(["/location/"]; changefreq = "never", priority = 0.5, lastmod = DateTime(2013, 3, 13, 10))
        simple_paged = Sitemap(["/location/", "/location2/"]; limit = 1)
        empty_ = Sitemap(String[])
        fixed = Sitemap(["/location/"]; lastmod = DateTime(2013, 3, 13, 10))
        fixed_date = Sitemap(["/location/"]; lastmod = Date(2013, 3, 13))
        fixed_tz = Sitemap(["/location/"]; lastmod = Juango.TimeZones.ZonedDateTime(DateTime(2013, 3, 13, 10), Juango.TimeZones.TimeZone("Asia/Bangkok")))
        mixed = Sitemap([(u = "/a/", m = DateTime(2013, 3, 13, 10)), (u = "/b/", m = nothing)]; location = x -> x.u, lastmod = x -> x.m)
        asc = Sitemap([(u = "/a/", m = DateTime(2013, 3, 12)), (u = "/b/", m = DateTime(2013, 3, 13))]; location = x -> x.u, lastmod = x -> x.m)
        desc = Sitemap([(u = "/b/", m = DateTime(2013, 3, 13)), (u = "/a/", m = DateTime(2013, 3, 12))]; location = x -> x.u, lastmod = x -> x.m)
        model_sm = Sitemap(() -> objects(DsmTestModel); location = o -> "/testmodel/$(o.id)/", lastmod = :lastmod)
        https_sm = Sitemap(["/location/"]; protocol = "https", changefreq = "never", priority = 0.5)
        old = settings.ROOT_URLCONF
        mk(prefix, d; kw...) = path(prefix, include_urls(sitemap_urls(d; kw...)))
        configure!(ROOT_URLCONF = vcat(old, [
            mk("simple/", Dict("simple" => simple); index = true), mk("single/", Dict("simple" => simple)),
            mk("paged/", Dict("simple" => simple_paged)), mk("empty/", Dict("empty" => empty_)),
            mk("lastmod/", Dict("fixed" => fixed)), mk("lastmod-date/", Dict("fixed" => fixed_date)),
            mk("lastmod-tz/", Dict("fixed" => fixed_tz)), mk("lastmod-mixed/", Dict("mixed" => mixed)),
            mk("lastmod-asc/", Dict("s" => asc)), mk("lastmod-desc/", Dict("s" => desc)),
            mk("models/", Dict("m" => model_sm)), mk("https/", Dict("simple" => https_sm); index = true),
            mk("two/", Dict("simple" => simple, "fixed" => fixed))]))
        try
            c = Client()
            r = get(c, "/simple/sitemap.xml")                                             # test_simple_sitemap_index
            @test text(r) == dsm_index("<sitemap><loc>http://testserver/simple/sitemap-simple.xml</loc><lastmod>2013-03-13T10:00:00</lastmod></sitemap>\n")
            r = get(c, "/simple/sitemap-simple.xml")                                      # test_simple_sitemap_section
            want = dsm_urlset("<url><loc>http://testserver/location/</loc><lastmod>2013-03-13</lastmod><changefreq>never</changefreq><priority>0.5</priority></url>\n")
            @test text(r) == want
            @test text(get(c, "/single/sitemap.xml")) == want                             # test_simple_sitemap
            r = get(c, "/simple/sitemap-simple2.xml")                                     # test_no_section
            @test r.status == 404
            @test get(c, "/single/sitemap.xml?p=0").status == 404                         # test_empty_page
            @test get(c, "/single/sitemap.xml?p=test").status == 404                      # test_page_not_int
            @test_throws Http404 Juango.page_param(Request("GET", "/x/?p=test"))
            e = try Juango.page_param(Request("GET", "/x/?p=test")) catch e; e end
            @test occursin("No page 'test'", sprint(showerror, e))
            e = try Juango.page_param(Request("GET", "/x/?p=0")) catch e; e end
            @test occursin("Page 0 empty", sprint(showerror, e))
            x = text(get(c, "/paged/sitemap.xml?p=2"))                                    # test_paged_sitemap
            @test occursin("<loc>http://testserver/location2/</loc>", x) && !occursin("/location/<", x)
            @test get(c, "/paged/sitemap.xml?p=3").status == 404
            @test text(get(c, "/empty/sitemap.xml")) == dsm_urlset("")                     # test_empty_sitemap
            r = get(c, "/single/sitemap.xml")                                              # test_x_robots_sitemap
            @test getheader(r, "X-Robots-Tag") == "noindex, noodp, noarchive"
            @test getheader(get(c, "/lastmod/sitemap.xml"), "Last-Modified") == "Wed, 13 Mar 2013 10:00:00 GMT"   # test_sitemap_last_modified
            @test getheader(get(c, "/lastmod-date/sitemap.xml"), "Last-Modified") == "Wed, 13 Mar 2013 00:00:00 GMT"   # test_sitemap_last_modified_date
            @test getheader(get(c, "/lastmod-tz/sitemap.xml"), "Last-Modified") == "Wed, 13 Mar 2013 03:00:00 GMT"     # test_sitemap_last_modified_tz
            @test getheader(get(c, "/empty/sitemap.xml"), "Last-Modified") === nothing   # test_sitemap_last_modified_missing
            @test getheader(get(c, "/lastmod-mixed/sitemap.xml"), "Last-Modified") === nothing   # test_sitemap_last_modified_mixed
            @test getheader(get(c, "/lastmod-asc/sitemap.xml"), "Last-Modified") == "Wed, 13 Mar 2013 00:00:00 GMT"   # test_sitemaps_lastmod_ascending
            @test getheader(get(c, "/lastmod-desc/sitemap.xml"), "Last-Modified") == "Wed, 13 Mar 2013 00:00:00 GMT"  # test_sitemaps_lastmod_descending
            x = text(get(c, "/models/sitemap.xml"))                                        # test_sitemap_item (model items, lastmod field)
            id = only(objects(DsmTestModel)).id
            @test occursin("<url><loc>http://testserver/testmodel/$id/</loc><lastmod>2013-03-13</lastmod></url>", x)
            x = text(get(c, "/two/sitemap.xml"))                                           # test_sitemap_index_with_two_sections (sorted)
            @test findfirst("sitemap-fixed.xml", x)[1] < findfirst("sitemap-simple.xml", x)[1]
            x = text(get(c, "/https/sitemap.xml"))                                         # HTTPSSitemapTests: test_sitemap_index
            @test occursin("<loc>https://testserver/https/sitemap-simple.xml</loc>", x)
            @test occursin("<loc>https://testserver/location/</loc>", text(get(c, "/https/sitemap-simple.xml")))   # test_sitemap_section
            r = get(c, "/single/sitemap.xml"; secure = true)                              # HTTPSDetectionSitemapTests
            @test occursin("<loc>https://testserver/location/</loc>", text(r))
            mixed_tz = Sitemap(["/x/"]; lastmod = Juango.TimeZones.ZonedDateTime(DateTime(2013, 3, 13, 10), Juango.TimeZones.TimeZone("Asia/Bangkok")))
            x = text(Juango.sitemap_index_view(Dict("s" => mixed_tz))(Request("GET", "/sitemap.xml"; headers = Dict("host" => "testserver"))))
            @test occursin("<lastmod>2013-03-13T10:00:00+07:00</lastmod>", x)             # (an index lastmod keeps its offset: Django's date:"c")
        finally
            configure!(ROOT_URLCONF = old)
        end
    end
    # not translated: i18n sitemaps (alternates, x_default, languages), Sitemap.get_urls(site=...),
    # the sites framework's domain (Juango uses the request's host unless SITE_DOMAIN is set), ping_google
    # (removed in Django 5), cached index views
end
