# Django's utils_tests test_encoding.py, ported (#227): repercent_broken_unicode, filepath_to_uri, iri_to_uri, uri_to_iri
# (and their complementarity) and escape_uri_path.
# julia --project=test test/django_utils_encoding.jl   (see setup.jl; no database needed)
#
# Not translated: force_str, force_bytes, smart_str, smart_bytes and get_system_encoding (Python's bytes and str; Julia's
# strings are UTF-8 bytes already), lazy strings.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_encoding: TestEncodingUtils, TestRFC3987IEncodingUtils" begin
    # test_repercent_broken_unicode_recursion_error / _small_fragments
    @test Juango.repercent_broken_unicode(fill(0xfc, 1000)) == Vector{UInt8}("%FC"^1000)
    @test Juango.repercent_broken_unicode(Vector{UInt8}("test\xfctest\xfctest\xfc")) == Vector{UInt8}("test%FCtest%FCtest%FC")
    # test_filepath_to_uri
    @test Juango.filepath_to_uri(nothing) === nothing
    @test Juango.filepath_to_uri("upload\\чубака.mp4") == "upload/%D1%87%D1%83%D0%B1%D0%B0%D0%BA%D0%B0.mp4"
    @test Juango.filepath_to_uri("upload/test.png") == "upload/test.png" && Juango.filepath_to_uri("upload\\test.png") == "upload/test.png"
    # test_iri_to_uri
    for (iri, uri) in (("red%09rosé#red", "red%09ros%C3%A9#red"), ("/blog/for/Jürgen Münster/", "/blog/for/J%C3%BCrgen%20M%C3%BCnster/"),
                       ("locations/" * Juango.quote_plus("Paris & Orléans"), "locations/Paris+%26+Orl%C3%A9ans"), ("%&", "%&"),
                       ("red&♥ros%#red", "red&%E2%99%A5ros%#red"))
        @test Juango.iri_to_uri(iri) == uri
        @test Juango.iri_to_uri(Juango.iri_to_uri(iri)) == uri
    end
    # test_uri_to_iri
    @test Juango.uri_to_iri(nothing) === nothing
    for (uri, iri) in (("/%e2%89%Ab%E2%99%a5%E2%89%aB/", "/≫♥≫/"), ("/%E2%99%A5%E2%99%A5/?utf8=%E2%9C%93", "/♥♥/?utf8=✓"), ("/%41%5a%6B/", "/AZk/"),
                       ("/%25%20%02%41%7b/", "/%25%20%02A%7b/"), ("/%AAd%AAj%AAa%AAn%AAg%AAo%AA/", "/%AAd%AAj%AAa%AAn%AAg%AAo%AA/"),
                       ("/%E2%99%A5%E2%E2%99%A5/", "/♥%E2♥/"), ("/%E2%99%A5%E2%99%E2%99%A5/", "/♥%E2%99♥/"), ("/%E2%E2%99%A5%E2%99%A5%99/", "/%E2♥♥%99/"),
                       ("/%E2%99%A5%E2%99%A5/?utf8=%9C%93%E2%9C%93%9C%93", "/♥♥/?utf8=%9C%93✓%9C%93"))
        @test Juango.uri_to_iri(uri) == iri
        @test Juango.uri_to_iri(Juango.uri_to_iri(uri)) == iri
    end
    # test_complementarity
    for (uri, iri) in (("/blog/for/J%C3%BCrgen%20M%C3%BCnster/", "/blog/for/Jürgen%20Münster/"), ("%&", "%&"),
                       ("red&%E2%99%A5ros%#red", "red&♥ros%#red"), ("/%E2%99%A5%E2%99%A5/", "/♥♥/"), ("/%E2%99%A5%E2%99%A5/?utf8=%E2%9C%93", "/♥♥/?utf8=✓"),
                       ("/%25%20%02%7b/", "/%25%20%02%7b/"), ("/%AAd%AAj%AAa%AAn%AAg%AAo%AA/", "/%AAd%AAj%AAa%AAn%AAg%AAo%AA/"),
                       ("/%E2%99%A5%E2%E2%99%A5/", "/♥%E2♥/"), ("/%E2%99%A5%E2%99%E2%99%A5/", "/♥%E2%99♥/"), ("/%E2%E2%99%A5%E2%99%A5%99/", "/%E2♥♥%99/"),
                       ("/%E2%99%A5%E2%99%A5/?utf8=%9C%93%E2%9C%93%9C%93", "/♥♥/?utf8=%9C%93✓%9C%93"))
        @test Juango.iri_to_uri(Juango.uri_to_iri(uri)) == uri
        @test Juango.uri_to_iri(Juango.iri_to_uri(iri)) == iri
    end
    # test_escape_uri_path
    for (uri, expected) in (("/;some/=awful/?path/:with/@lots/&of/+awful/chars", "/%3Bsome/%3Dawful/%3Fpath/:with/@lots/&of/+awful/chars"),
                            ("/foo#bar", "/foo%23bar"), ("/foo?bar", "/foo%3Fbar"))
        @test Juango.escape_uri_path(uri) == expected
    end
end
