# Django's utils_tests test_feedgenerator.py, ported (#227): get_tag_uri, rfc2822_date and rfc3339_date.
# julia --project=test test/django_utils_feedgenerator.jl   (see setup.jl; no database needed)
#
# Not translated: the low-level feed classes (Rss201rev2Feed, Atom1Feed, Stylesheet: Juango's Feed writes the feeds;
# their output is the syndication tests', test/django_syndication.jl).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Juango.TimeZones

@testset "django utils_tests test_feedgenerator: FeedgeneratorTests" begin
    @test Juango.get_tag_uri("http://example.org/foo/bar#headline", Date(2004, 10, 25)) == "tag:example.org,2004-10-25:/foo/bar/headline"
    @test Juango.get_tag_uri("http://www.example.org:8000/2008/11/14/django#headline", DateTime(2008, 11, 14, 13, 37, 0)) ==
          "tag:www.example.org,2008-11-14:/2008/11/14/django/headline"
    @test Juango.rfc2822_date(DateTime(2008, 11, 14, 13, 37, 0)) == "Fri, 14 Nov 2008 13:37:00 -0000"
    @test Juango.rfc2822_date(ZonedDateTime(DateTime(2008, 11, 14, 13, 37, 0), Juango.fixed_timezone(60))) == "Fri, 14 Nov 2008 13:37:00 +0100"
    @test Juango.rfc2822_date(Date(2008, 11, 14)) == "Fri, 14 Nov 2008 00:00:00 -0000"
    @test Juango.rfc3339_date(DateTime(2008, 11, 14, 13, 37, 0)) == "2008-11-14T13:37:00Z"
    @test Juango.rfc3339_date(ZonedDateTime(DateTime(2008, 11, 14, 13, 37, 0), Juango.fixed_timezone(120))) == "2008-11-14T13:37:00+02:00"
    @test Juango.rfc3339_date(Date(2008, 11, 14)) == "2008-11-14T00:00:00Z"
end
