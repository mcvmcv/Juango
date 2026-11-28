# Django's utils_tests test_http.py, ported (#227): urlencode, base36, url_has_allowed_host_and_scheme, URL-safe base64,
# is_same_domain, split_header_value, split_directive_names, ETags, HTTP dates, escape_leading_slashes,
# parse_header_parameters and content_disposition_header.
# julia --project=test test/django_utils_http.jl   (see setup.jl; no database needed)
#
# Juango's urlencode takes `doseq` as Django's but defaults it to true; its parse_http_date gives a DateTime (UTC) or
# nothing (Django's parse_http_date_safe), taking `now` for the two-digit years Django's test mocks. Not translated:
# bytearray values (a Julia byte vector is text), Python's TypeErrors for non-integers (Julia's methods refuse them).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_http: URLEncodeTests" begin
    none_msg = "Cannot encode None for key 'a' in a query string. Did you mean to pass an empty string or omit the value?"
    @test Juango.urlencode([("a", 1), ("b", 2), ("c", 3)]) == "a=1&b=2&c=3"
    @test Juango.urlencode(["a" => 1, "b" => 2, "c" => 3]) == "a=1&b=2&c=3"
    @test Juango.urlencode(Dict("a" => [1, 2]); doseq = false) == "a=%5B1%2C+2%5D"
    @test Juango.urlencode(Dict("a" => (1, 2)); doseq = false) == "a=%281%2C+2%29"
    @test Juango.urlencode(Dict("a" => [1, 2]); doseq = true) == "a=1&a=2"
    @test Juango.urlencode(Dict("a" => []); doseq = true) == ""
    q = QueryDict(""); appendlist!(q, "name", "Adrian"); appendlist!(q, "name", "Simon"); appendlist!(q, "position", "Developer")
    @test Juango.urlencode(q) == "name=Adrian&name=Simon&position=Developer"
    @test Juango.urlencode(Dict("a" => Vector{UInt8}("abc")); doseq = true) == "a=abc"
    @test Juango.urlencode(Dict("a" => [Vector{UInt8}("spam"), Vector{UInt8}("eggs"), Vector{UInt8}("bacon")]); doseq = true) == "a=spam&a=eggs&a=bacon"
    @test Juango.urlencode(Dict("a" => 0:1); doseq = true) == "a=0&a=1"
    @test Juango.urlencode(Dict("a" => 0:1); doseq = false) == "a=range%280%2C+2%29"
    @test Juango.urlencode(Dict("a" => (x for x in 0:1)); doseq = true) == "a=0&a=1"
    @test_throws none_msg Juango.urlencode(Dict("a" => nothing))
    @test_throws none_msg Juango.urlencode(Dict("a" => [nothing]); doseq = true)
    @test_throws none_msg Juango.urlencode(Dict("a" => (x for x in [nothing])); doseq = true)
end

@testset "django utils_tests test_http: Base36IntTests" begin
    for n in (0, 1, 1000, 1000000)
        @test Juango.base36_to_int(Juango.int_to_base36(n)) == n
    end
    @test_throws "Negative base36 conversion input." Juango.int_to_base36(-1)
    for n in ("1", "foo", Dict(1 => 2), (1, 2, 3), 3.141)
        @test_throws MethodError Juango.int_to_base36(n)
    end
    for n in ("#", " ")
        @test_throws "invalid literal for int() with base 36: '$n'" Juango.base36_to_int(n)
    end
    @test_throws "Base36 input too large" Juango.base36_to_int("1"^14)
    for n in (123, Dict(1 => 2), (1, 2, 3), 3.141)
        @test_throws MethodError Juango.base36_to_int(n)
    end
    for (n, b36) in ((0, "0"), (1, "1"), (42, "16"), (818469960, "django"))
        @test Juango.int_to_base36(n) == b36 && Juango.base36_to_int(b36) == n
    end
end

@testset "django utils_tests test_http: URLHasAllowedHostAndSchemeTests" begin
    uh(url, hosts; kw...) = Juango.url_has_allowed_host_and_scheme(url, hosts; kw...)
    for bad in ("http://example.com", "http:///example.com", "https://example.com", "ftp://example.com", "\\\\example.com",
                "\\\\\\example.com", "/\\\\/example.com", "\\\\\\example.com", "\\\\example.com", "\\\\//example.com", "/\\/example.com",
                "\\/example.com", "/\\example.com", "http:///example.com", "http:/\\//example.com", "http:\\/example.com", "http:/\\example.com",
                "javascript:alert(\"XSS\")", "\njavascript:alert(x)", "java\nscript:alert(x)", "\x08//example.com",
                "http://otherserver\\@example.com", "http:\\\\testserver\\@example.com", "http://testserver\\me:pass@example.com",
                "http://testserver\\@example.com", "http:\\\\testserver\\confirm\\me@example.com", "http:999999999", "ftp:9999999999", "\n",
                "http://[2001:cdba:0000:0000:0000:0000:3257:9652/", "http://2001:cdba:0000:0000:0000:0000:3257:9652]/")
        @test uh(bad, Set(["testserver", "testserver2"])) === false
    end
    for good in ("/view/?param=http://example.com", "/view/?param=https://example.com", "/view?param=ftp://example.com",
                 "view/?param=//example.com", "https://testserver/", "HTTPS://testserver/", "//testserver/",
                 "http://testserver/confirm?email=me@example.com", "/url%20with%20spaces/", "path/http:2222222222")
        @test uh(good, Set(["otherserver", "testserver"])) === true
    end
    # test_basic_auth / test_no_allowed_hosts / test_allowed_hosts_str
    @test uh("http://user:pass@testserver/", Set(["user:pass@testserver"])) === true
    @test uh("/confirm/me@example.com", nothing) === true
    @test uh("http://testserver\\@example.com", nothing) === false
    @test uh("http://good.com/good", "good.com") === true
    @test uh("http://good.co/evil", "good.com") === false
    # test_secure_param_https_urls / test_secure_param_non_https_urls
    for url in ("https://example.com/p", "HTTPS://example.com/p", "/view/?param=http://example.com")
        @test uh(url, Set(["example.com"]); require_https = true) === true
    end
    for url in ("http://example.com/p", "ftp://example.com/p", "//example.com/p")
        @test uh(url, Set(["example.com"]); require_https = true) === false
    end
    # test_max_url_length
    boundary = "example.com/" * "é"^(Juango.MAX_URL_LENGTH - length("example.com") - 1)
    @test uh(boundary, Set(["example.com"])) === true
    @test uh(boundary * "ú", Set(["example.com"])) === false
end

@testset "django utils_tests test_http: base64, domains, header values, ETags" begin
    # URLSafeBase64Tests
    @test Juango.urlsafe_base64_decode(Juango.urlsafe_base64_encode(Vector{UInt8}("foo"))) == Vector{UInt8}("foo")
    # IsSameDomainTests
    for pair in (("example.com", "example.com"), ("example.com", ".example.com"), ("foo.example.com", ".example.com"),
                 ("example.com:8888", "example.com:8888"), ("example.com:8888", ".example.com:8888"), ("foo.example.com:8888", ".example.com:8888"))
        @test Juango.is_same_domain(pair...) === true
    end
    for pair in (("example2.com", "example.com"), ("foo.example.com", "example.com"), ("example.com:9999", "example.com:8888"), ("foo.example.com:8888", ""))
        @test Juango.is_same_domain(pair...) === false
    end
    # SplitHeaderValueTests
    for (v, expected) in (("", String[]), ("no-store", ["no-store"]), ("no-store, max-age=0", ["no-store", "max-age=0"]), ("no-store,", ["no-store"]),
                          (",no-store", ["no-store"]), (" no-store , max-age=0 ", ["no-store", "max-age=0"]),
                          ("text/html; charset=utf-8", ["text/html; charset=utf-8"]), ("a; b, c; d", ["a; b", "c; d"]))
        @test Juango.split_header_value(v) == expected
    end
    for (v, expected) in (("", String[]), ("text/html", ["text/html"]), ("text/html; charset=utf-8", ["text/html", "charset=utf-8"]),
                          ("text/html;", ["text/html"]), (";text/html", ["text/html"]), (" text/html ; charset=utf-8 ", ["text/html", "charset=utf-8"]))
        @test Juango.split_header_value(v, ";") == expected
    end
    # SplitDirectiveNamesTests
    for (v, expected) in (("", String[]), ("no-store", ["no-store"]), ("No-Store, PRIVATE", ["no-store", "private"]), ("private=\"Set-Cookie\"", ["private"]),
                          ("no-cache=\"Set-Cookie\", max-age=0", ["no-cache", "max-age"]), ("private =\"Set-Cookie\"", ["private"]),
                          ("no-cache = foo", ["no-cache"]), ("myprivate", ["myprivate"]), ("=\"Set-Cookie\"", [""]))
        @test Juango.split_directive_names(v) == expected
    end
    # ETagProcessingTests
    @test Juango.parse_etags("\"\" ,  \"etag\", \"e\\\\tag\", W/\"weak\"") == ["\"\"", "\"etag\"", "\"e\\\\tag\"", "W/\"weak\""]
    @test Juango.parse_etags("*") == ["*"]
    @test Juango.parse_etags("\"etag\", \"e\\\"t\\\"ag\"") == ["\"etag\""]
    @test Juango.quote_etag("etag") == "\"etag\"" && Juango.quote_etag("\"etag\"") == "\"etag\"" && Juango.quote_etag("W/\"etag\"") == "W/\"etag\""
end

@testset "django utils_tests test_http: HttpDateProcessingTests, EscapeLeadingSlashesTests" begin
    @test Juango.http_date(1167616461.0) == "Mon, 01 Jan 2007 01:54:21 GMT"
    @test Juango.parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT") == DateTime(1994, 11, 6, 8, 49, 37)
    # test_parsing_rfc850: a two-digit year within 50 years of now's
    now1, now2, now3 = DateTime(2019, 11, 6, 8, 49, 37), DateTime(2020, 11, 6, 8, 49, 37), DateTime(2048, 11, 6, 8, 49, 37)
    for (now_, s, expected) in ((now1, "Tuesday, 31-Dec-69 08:49:37 GMT", DateTime(2069, 12, 31, 8, 49, 37)),
                                (now1, "Tuesday, 10-Nov-70 08:49:37 GMT", DateTime(1970, 11, 10, 8, 49, 37)),
                                (now1, "Sunday, 06-Nov-94 08:49:37 GMT", DateTime(1994, 11, 6, 8, 49, 37)),
                                (now2, "Wednesday, 31-Dec-70 08:49:37 GMT", DateTime(2070, 12, 31, 8, 49, 37)),
                                (now2, "Friday, 31-Dec-71 08:49:37 GMT", DateTime(1971, 12, 31, 8, 49, 37)),
                                (now3, "Sunday, 31-Dec-00 08:49:37 GMT", DateTime(2000, 12, 31, 8, 49, 37)),
                                (now3, "Friday, 31-Dec-99 08:49:37 GMT", DateTime(1999, 12, 31, 8, 49, 37)))
        @test Juango.parse_http_date(s; now = now_) == expected
    end
    @test Juango.parse_http_date("Sun Nov  6 08:49:37 1994") == DateTime(1994, 11, 6, 8, 49, 37)
    # test_parsing_asctime_nonascii_digits (nothing, as Django's parse_http_date_safe)
    @test Juango.parse_http_date("Sun Nov  6 08:49:37 １９９４") === nothing
    @test Juango.parse_http_date("Sun Nov １２ 08:49:37 1994") === nothing
    @test Juango.parse_http_date("Sun Nov  6 08:49:37 0037") == DateTime(2037, 11, 6, 8, 49, 37)
    @test Juango.escape_leading_slashes("//example.com") == "/%2Fexample.com"
    @test Juango.escape_leading_slashes("//") == "/%2F"
end

@testset "django utils_tests test_http: ParseHeaderParameterTests, ContentDispositionHeaderTests" begin
    D(ps...) = Dict{String,String}(ps...)
    for (header, expected) in (("", ("", D())), (nothing, ("", D())), ("text/plain", ("text/plain", D())),
                               ("text/vnd.just.made.this.up ; ", ("text/vnd.just.made.this.up", D())),
                               ("text/plain;charset=us-ascii", ("text/plain", D("charset" => "us-ascii"))),
                               ("text/plain ; charset=\"us-ascii\"", ("text/plain", D("charset" => "us-ascii"))),
                               ("text/plain ; charset=\"us-ascii\"; another=opt", ("text/plain", D("charset" => "us-ascii", "another" => "opt"))),
                               ("attachment; filename=\"silly.txt\"", ("attachment", D("filename" => "silly.txt"))),
                               ("attachment; filename=\"strange;name\"", ("attachment", D("filename" => "strange;name"))),
                               ("attachment; filename=\"strange;name\";size=123;", ("attachment", D("filename" => "strange;name", "size" => "123"))),
                               ("attachment; filename=\"strange;name\";;;;size=123;;;", ("attachment", D("filename" => "strange;name", "size" => "123"))),
                               ("form-data; name=\"files\"; filename=\"fo\\\"o;bar\"", ("form-data", D("name" => "files", "filename" => "fo\"o;bar"))),
                               ("form-data; name=\"files\"; filename=\"\\\"fo\\\"o;b\\\\ar\\\"\"", ("form-data", D("name" => "files", "filename" => "\"fo\"o;b\\ar\""))))
        @test Juango.parse_header_parameters(header) == expected
    end
    # test_rfc2231_parsing / test_rfc2231_wrong_title
    for (raw, title) in (("Content-Type: application/x-stuff; title*=us-ascii'en-us'This%20is%20%2A%2A%2Afun%2A%2A%2A", "This is ***fun***"),
                         ("Content-Type: application/x-stuff; title*=UTF-8''foo-%c3%a4.html", "foo-ä.html"),
                         ("Content-Type: application/x-stuff; title*=iso-8859-1''foo-%E4.html", "foo-ä.html"),
                         ("Content-Type: application/x-stuff; title*='This%20is%20%2A%2A%2Afun%2A%2A%2A", "'This is ***fun***"),
                         ("Content-Type: application/x-stuff; title*='foo.html", "'foo.html"),
                         ("Content-Type: application/x-stuff; title*=bar.html", "bar.html"))
        @test Juango.parse_header_parameters(raw)[2]["title"] == title
    end
    # test_rfc2231_invalid_encoding
    for h in ("text/plain; charset*=BOGUS''%20", "text/plain; filename*=INVALID''%s%s%s", "text/plain; title*=NOTACODEC''%E2%80%A6")
        @test_throws "Invalid encoding" Juango.parse_header_parameters(h)
    end
    # test_header_max_length / test_header_too_long
    base = "Content-Type: application/x-stuff; title*="
    for (len, kw) in ((Juango.MAX_HEADER_LENGTH, (;)), (Juango.MAX_HEADER_LENGTH, (; max_length = nothing)),
                      (Juango.MAX_HEADER_LENGTH + 1, (; max_length = nothing)), (100, (; max_length = 100)))
        title = "x"^(len - length(base))
        @test Juango.parse_header_parameters(base * title; kw...) == ("content-type: application/x-stuff", D("title" => title))
    end
    @test_throws ArgumentError Juango.parse_header_parameters("x"^(Juango.MAX_HEADER_LENGTH + 1))
    @test_throws ArgumentError Juango.parse_header_parameters("x"^101; max_length = 100)
    # test_many_separators_in_quoted_value
    v = ";"^5000
    @test Juango.parse_header_parameters("attachment; filename=\"$v\"; size=1") == ("attachment", D("filename" => v, "size" => "1"))
    # ContentDispositionHeaderTests
    for ((att, name), expected) in (((false, nothing), nothing), ((false, "example"), "inline; filename=\"example\""), ((true, nothing), "attachment"),
                                    ((true, "example"), "attachment; filename=\"example\""),
                                    ((true, "\"example\" file\\name"), "attachment; filename=\"\\\"example\\\" file\\\\name\""),
                                    ((true, "espécimen"), "attachment; filename*=utf-8''esp%C3%A9cimen"),
                                    ((true, "\"espécimen\" filename"), "attachment; filename*=utf-8''%22esp%C3%A9cimen%22%20filename"),
                                    ((true, "some\nfile"), "attachment; filename*=utf-8''some%0Afile"), ((true, "\n"), "attachment; filename*=utf-8''%0A"),
                                    ((true, "example\n"), "attachment; filename*=utf-8''example%0A"))
        @test Juango.content_disposition_header(att, name) == expected
    end
end
