# Django's request and response tests, ported (#227): tests/httpwrappers, responses (test_cookie,
# test_fileresponse's Content-Disposition) and utils_tests/test_http's content_disposition_header.
# julia --project=test test/django_httpwrappers.jl   (see setup.jl)
#
# Juango's QueryDict is always mutable (Django's is immutable unless copied or made mutable: a
# difference kept), and its pop! returns the last value, as Julia's pop! does (Django's pop returns
# the list). Python's ValueError and TypeError are ArgumentErrors. Each test keeps its Django name.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

"A response's cookie as a Dict of its attributes (lower-case names), its value under \"value\"."
function dhw_cookie(r, name)
    for c in r.cookies
        parts = split(c, "; ")
        k, v = split(parts[1], '='; limit = 2)
        k == name || continue
        d = Dict{String,String}("value" => v)
        for p in parts[2:end]
            a, b = occursin('=', p) ? split(p, '='; limit = 2) : (p, "true")
            d[lowercase(a)] = b
        end
        return d
    end
    nothing
end

@testset "django httpwrappers: QueryDictTests" begin
    q = QueryDict()                                                                     # test_create_with_no_args
    @test isempty(q) && length(q) == 0
    @test_throws KeyError q["foo"]                                                      # test_missing_key
    @test get(q, "foo", "default") == "default"                                          # test_immutable_get_with_default
    @test getlist(q, "foo") == [] && !haskey(q, "foo") && isempty(collect(q)) && urlencode(q) == ""   # test_immutable_basic_operations

    q = QueryDict("foo=bar")                                                            # test_single_key_value
    @test q["foo"] == "bar" && get(q, "foo", "default") == "bar" && get(q, "bar", "default") == "default"
    @test_throws KeyError q["bar"]
    @test getlist(q, "foo") == ["bar"] && getlist(q, "bar") == [] && haskey(q, "foo") && !haskey(q, "bar")
    @test collect(keys(q)) == ["foo"] && lists(q) == ["foo" => ["bar"]] && collect(q) == ["foo" => "bar"]
    @test urlencode(q) == "foo=bar"

    q = QueryDict()                                                                     # test_urlencode
    q["next"] = "/a&b/"
    @test urlencode(q) == "next=%2Fa%26b%2F" && urlencode(q; safe = "/") == "next=/a%26b/"
    q["next"] = "/t\u00ebst&key/"
    @test urlencode(q) == "next=%2Ft%C3%ABst%26key%2F" && urlencode(q; safe = "/") == "next=/t%C3%ABst%26key/"
    q = QueryDict(); q["a"] = 1                                                          # test_urlencode_int
    @test urlencode(q) == "a=1"

    q = QueryDict("foo=bar")                                                            # test_mutable_copy
    c = copy(q); c["foo"] = "baz"; appendlist!(c, "x", "y")
    @test q["foo"] == "bar" && !haskey(q, "x") && c["foo"] == "baz"
    delete!(c, "foo")                                                                    # test_mutable_delete
    @test !haskey(c, "foo")

    q = QueryDict()                                                                     # test_basic_mutable_operations
    q["name"] = "john"
    @test get(q, "foo", "default") == "default" && get(q, "name", "default") == "john"
    @test getlist(q, "name") == ["john"] && getlist(q, "foo") == []
    setlist!(q, "foo", ["bar", "baz"])
    @test get(q, "foo", "default") == "baz" && getlist(q, "foo") == ["bar", "baz"]
    appendlist!(q, "foo", "another")
    @test getlist(q, "foo") == ["bar", "baz", "another"] && q["foo"] == "another" && haskey(q, "foo")
    @test sort(collect(keys(q))) == ["foo", "name"]
    @test lists(q) == ["name" => ["john"], "foo" => ["bar", "baz", "another"]]
    update!(q, Dict("foo" => "hello"))
    @test q["foo"] == "hello" && getlist(q, "foo") == ["bar", "baz", "another", "hello"]
    @test pop!(q, "foo") == "hello"                                                       # (Django's pop: the list)
    @test pop!(q, "foo", "not there") == "not there" && get(q, "foo", "not there") == "not there"
    @test get!(q, "foo", "bar") == "bar" && q["foo"] == "bar" && getlist(q, "foo") == ["bar"]   # (setdefault)
    @test urlencode(q) == "name=john&foo=bar"                                            # (in order: Django's keeps it too)
    @test setlistdefault!(q, "new", ["x"]) == ["x"] && setlistdefault!(q, "new", ["y"]) == ["x"]
    empty!(q)
    @test length(q) == 0

    q = QueryDict("vote=yes&vote=no")                                                   # test_multiple_keys
    @test q["vote"] == "no" && getlist(q, "vote") == ["yes", "no"] && urlencode(q) == "vote=yes&vote=no"
    @test lists(q) == ["vote" => ["yes", "no"]]
    @test QueryDict("foo=bar&foo=%ff")["foo"] == "\ufffd"                                 # test_invalid_input_encoding
    @test getlist(QueryDict("foo=%ff%fe"), "foo") == ["\ufffd\ufffd"]
    x = QueryDict("a=1&a=2"); y = QueryDict("a=3&a=4")                                   # test_update_from_querydict
    update!(x, y)
    @test getlist(x, "a") == ["1", "2", "3", "4"]
    @test QueryDict("a=b+c&d=%2B")["a"] == "b c" && QueryDict("a=b+c&d=%2B")["d"] == "+"   # (+ is a space, as forms send it)
    @test getlist(QueryDict("a"), "a") == [""] && QueryDict("a=1&b")["b"] == ""
    @test collect(keys(QueryDict("z=1&a=2&m=3&a=4"))) == ["z", "a", "m"]                 # (the order kept)
    @test urlencode(QueryDict("z=1&a=2&m=3&a=4")) == "z=1&a=2&a=4&m=3"
    # not translated: immutability (Juango's QueryDicts are mutable), pickling, encodings other than
    # UTF-8, fromkeys
end

@testset "django httpwrappers: HttpResponseTests, HttpResponseSubclassesTests, JsonResponseTests" begin
    r = HttpResponse()                                                                  # test_headers_type
    setheader!(r, "key", "test")
    @test getheader(r, "key") == "test"
    setheader!(r, "key", "caf\u00e9")                                                    # (Latin-1: as it is)
    @test getheader(r, "key") == "caf\u00e9"
    setheader!(r, "key", "\u2020")                                                       # (not Latin-1: MIME-encoded)
    @test getheader(r, "key") == "=?utf-8?b?4oCg?="
    @test_throws ArgumentError setheader!(r, "\u2020", "test")                           # (names are ASCII)
    setheader!(r, "long", "x"^4000)                                                      # test_long_line
    @test length(getheader(r, "long")) == 4000
    for (k, v) in (("test\rstr", "test"), ("test\nstr", "test"), ("test", "test\rstr"), ("test", "test\nstr"))   # test_newlines_in_headers
        @test_throws BadHeaderError setheader!(r, k, v)
    end
    @test_throws BadHeaderError HttpResponse("x"; headers = ["X-Foo" => "a\nSet-Cookie: evil=1"])
    r = HttpResponse()                                                                  # test_dict_behavior / test_header_deletion
    setheader!(r, "X-Foo", "bar")
    @test hasheader(r, "x-foo") && getheader(r, "X-FOO") == "bar"
    delheader!(r, "x-foo")
    @test !hasheader(r, "X-Foo")
    @test text(HttpResponse(12345)) == "12345"                                          # test_non_string_content
    @test text(HttpResponse(["abc", "def", "ghi"])) == "abcdefghi"                      # test_iter_content
    @test text(HttpResponse(x for x in ["hello", "world"])) == "helloworld"
    @test text(HttpResponse(Any["abc", Vector{UInt8}("def"), 12])) == "abcdef12"
    r = HttpResponse()                                                                  # test_file_interface
    @test write(r, "hello") == 5 && write(r, "\u043f\u0440\u0438\u0432\u0435\u0442") == 12 && length(r.body) == 17
    r = HttpResponse(["abc"]); write(r, "def")
    @test text(r) == "abcdef"
    writelines(r, ["foo\n", "bar\n", "baz\n"])
    @test text(r) == "abcdeffoo\nbar\nbaz\n"
    for bad in ("data:text/html,<script>window.alert(\"xss\")</script>", "mailto:test@example.com", "file:///etc/passwd",
                "javascript:alert(1)", " javascript:alert(1)", "java\tscript:alert(1)", "JavaScript:alert(1)")   # test_unsafe_redirect
        @test_throws DisallowedRedirect HttpResponseRedirect(bad)
        @test_throws DisallowedRedirect HttpResponsePermanentRedirect(bad)
    end
    e = try HttpResponseRedirect("javascript:alert(1)") catch e; e end
    @test e.msg == "Unsafe redirect to URL with protocol 'javascript'"
    for ok in ("/redirected/", "https://example.com/", "ftp://example.com/f", "//example.com/", "?a=1", "relative/path")
        @test getheader(HttpResponseRedirect(ok), "Location") == ok
    end
    base = "https://example.com/"                                                       # test_redirect_url_max_length
    @test getheader(HttpResponseRedirect(base * "a"^(2048 - length(base))), "Location") == base * "a"^(2048 - length(base))
    e = try HttpResponseRedirect(base * "a"^(2049 - length(base))) catch e; e end
    @test e isa DisallowedRedirect && e.msg == "Unsafe redirect exceeding 2048 characters"
    @test HttpResponse(; status = 503).status == 503 && HttpResponse(; status = "100").status == 100   # test_valid_status_code_string
    for bad in (99, 600)                                                                # test_invalid_status_code
        e = try HttpResponse(; status = bad) catch e; e end
        @test e isa ArgumentError && e.msg == "HTTP status code must be an integer from 100 to 599."
    end
    e = try HttpResponse(; status = "abc") catch e; e end
    @test e isa ArgumentError && e.msg == "HTTP status code must be an integer."
    r = HttpResponseRedirect("/redirected/")                                            # test_redirect
    @test r.status == 302 && getheader(r, "Location") == "/redirected/"
    @test HttpResponsePermanentRedirect("/x/").status == 301
    r = HttpResponseNotModified()                                                       # test_not_modified
    @test r.status == 304 && !hasheader(r, "Content-Type")
    r = HttpResponseNotAllowed(["GET"])                                                 # test_not_allowed
    @test r.status == 405 && getheader(r, "Allow") == "GET"
    r = HttpResponseNotAllowed(["GET", "POST"])
    @test getheader(r, "Allow") == "GET, POST"
    r = JsonResponse(Dict("key" => "\u03b5\u2113\u2113\u03b7\u03bd\u03b9\u03ba\u03ac"))   # test_json_response_non_ascii
    @test Juango.JSON.parse(text(r))["key"] == "\u03b5\u2113\u2113\u03b7\u03bd\u03b9\u03ba\u03ac" && getheader(r, "Content-Type") == "application/json"
    @test Juango.JSON.parse(text(JsonResponse("foobar"))) == "foobar"                   # test_json_response_text
    @test Juango.JSON.parse(text(JsonResponse([1, 2, 3]))) == [1, 2, 3]                 # test_json_response_list
    r = StreamingHttpResponse(["hello", "world"])                                       # StreamingHttpResponseTests (basic)
    @test r.status == 200 && text(r) == "helloworld"
    # handled as Django's SuspiciousOperation: a 400, not a 500
    old = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("evil/", req -> HttpResponseRedirect(req.GET["to"]))])
    try
        @test get(Client(), "/evil/?to=javascript:alert(1)").status == 400
    finally
        configure!(ROOT_URLCONF = old)
    end
    # not translated: lazy strings, memoryview content, reading and seeking (tell/seekable),
    # JsonResponse's safe, encoder and json_dumps_params (Juango's takes any JSON value), pickling
end

@testset "django httpwrappers: CookieTests; responses: test_cookie" begin
    r = HttpResponse()                                                                  # test_encode
    set_cookie!(r, "test", "An,awkward;value")
    raw = dhw_cookie(r, "test")["value"]
    @test !occursin(';', raw) && !occursin(',', raw) && raw == "\"An\\054awkward\\073value\""
    @test parse_cookies("test=" * raw)["test"] == "An,awkward;value"                    # test_decode
    set_cookie!(r, "q", "say \"hi\"\\")
    @test parse_cookies("q=" * dhw_cookie(r, "q")["value"])["q"] == "say \"hi\"\\"
    @test dhw_cookie(set_cookie!(HttpResponse(), "plain", "abc-123_x"), "plain")["value"] == "abc-123_x"   # (nothing to quote)
    @test haskey(parse_cookies("good_cookie=yes;bad:cookie=yes"), "good_cookie")          # test_nonstandard_keys
    @test haskey(parse_cookies("a:=b; a:=c; good_cookie=yes"), "good_cookie")              # test_repeated_nonstandard_keys
    @test parse_cookies("chips=ahoy; vienna=finger") == Dict("chips" => "ahoy", "vienna" => "finger")   # test_python_cookies
    @test parse_cookies("keebler=\"E=mc2; L=\\\"Loves\\\"; fudge=\\012;\"") ==
          Dict("keebler" => "\"E=mc2", "L" => "\\\"Loves\\\"", "fudge" => "\\012", "" => "\"")
    @test parse_cookies("keebler=E=mc2") == Dict("keebler" => "E=mc2")
    @test parse_cookies("key:term=value:term") == Dict("key:term" => "value:term")
    @test parse_cookies("a=b; c=[; d=r; f=h") == Dict("a" => "b", "c" => "[", "d" => "r", "f" => "h")
    @test parse_cookies("a=b; Domain=example.com") == Dict("a" => "b", "Domain" => "example.com")   # test_cookie_edgecases
    @test parse_cookies("a=b; h=i; a=c") == Dict("a" => "c", "h" => "i")
    @test haskey(parse_cookies("abc=def; unnamed; django_language=en"), "django_language")  # test_invalid_cookies
    @test parse_cookies("a=b; \"; c=d") == Dict("a" => "b", "" => "\"", "c" => "d")
    @test parse_cookies("a b c=d e = f; gh=i") == Dict("a b c" => "d e = f", "gh" => "i")
    @test parse_cookies("a   b,c<>@:/[]?{}=d  \"  =e,f g") == Dict("a   b,c<>@:/[]?{}" => "d  \"  =e,f g")
    @test parse_cookies("saint=Andr\u00e9 Bessette") == Dict("saint" => "Andr\u00e9 Bessette")
    @test parse_cookies("  =  b  ;  ;  =  ;   c  =  ;  ") == Dict("" => "b", "c" => "")
    # and on a request
    @test get(RequestFactory(; headers = Dict("Cookie" => "a=\"x\\073y\"; b=2")), "/").COOKIES == Dict("a" => "x;y", "b" => "2")

    r = HttpResponse()                                                                  # test_near_expiration
    set_cookie!(r, "datetime", "x"; expires = now(Dates.UTC) + Second(10))
    @test dhw_cookie(r, "datetime")["max-age"] in ("10", "11")
    if Juango.settings.USE_TZ                                                           # test_aware_expiration
        set_cookie!(r, "aware", "x"; expires = Juango.make_aware(now() + Second(10)))
        @test dhw_cookie(r, "aware")["max-age"] in ("10", "11")
    end
    set_cookie!(r, "c", "old-value"); set_cookie!(r, "c", "new-value")                  # test_create_cookie_after_deleting_cookie
    @test dhw_cookie(r, "c")["value"] == "new-value"
    delete_cookie!(r, "c")
    @test dhw_cookie(r, "c")["value"] == "" && dhw_cookie(r, "c")["max-age"] == "0"
    set_cookie!(r, "c", "new-value")
    @test dhw_cookie(r, "c")["value"] == "new-value" && !haskey(dhw_cookie(r, "c"), "max-age")
    set_cookie!(r, "far", "x"; expires = DateTime(2038, 1, 1, 4, 5, 6))                 # test_far_expiration
    @test dhw_cookie(r, "far")["expires"] in ("Fri, 01 Jan 2038 04:05:06 GMT", "Fri, 01 Jan 2038 04:05:07 GMT")
    set_cookie!(r, "s", "x"; expires = "Sat, 01-Jan-2028 04:05:06 GMT")                 # (a string as it is)
    @test dhw_cookie(r, "s")["expires"] == "Sat, 01-Jan-2028 04:05:06 GMT" && !haskey(dhw_cookie(r, "s"), "max-age")
    t = now(Dates.UTC)
    set_cookie!(r, "max_age", "x"; max_age = 10)                                        # test_max_age_expiration
    ck = dhw_cookie(r, "max_age")
    @test ck["max-age"] == "10" && ck["expires"] in (Juango.http_date(t + Second(10)), Juango.http_date(t + Second(11)))
    set_cookie!(r, "max_age", "x"; max_age = 10.6)                                      # test_max_age_int
    @test dhw_cookie(r, "max_age")["max-age"] == "10"
    set_cookie!(r, "max_age", "x"; max_age = Hour(10))                                  # test_max_age_timedelta
    @test dhw_cookie(r, "max_age")["max-age"] == "36000"
    e = try set_cookie!(r, "max_age", "x"; expires = now(Dates.UTC) + Second(10), max_age = 10) catch e; e end   # test_max_age_with_expires
    @test e isa ArgumentError && e.msg == "'expires' and 'max_age' can't be used together."
    set_cookie!(r, "example", "x"; httponly = true)                                     # test_httponly_cookie
    @test haskey(dhw_cookie(r, "example"), "httponly")
    set_cookie!(r, "test", "\u6e05\u98a8")                                               # test_unicode_cookie
    @test parse_cookies("test=" * dhw_cookie(r, "test")["value"])["test"] == "\u6e05\u98a8"
    for s in ("None", "Lax", "lax", "Strict")                                            # test_samesite
        set_cookie!(r, "example", "x"; samesite = s)
        @test dhw_cookie(r, "example")["samesite"] == s
    end
    e = try set_cookie!(r, "example", "x"; samesite = "invalid") catch e; e end         # test_invalid_samesite
    @test e isa ArgumentError && e.msg == "samesite must be \"lax\", \"none\", or \"strict\"."
    r = HttpResponse()                                                                  # DeleteCookieTests
    delete_cookie!(r, "c")                                                              # test_default
    ck = dhw_cookie(r, "c")
    @test ck["expires"] == "Thu, 01 Jan 1970 00:00:00 GMT" && ck["max-age"] == "0" && ck["path"] == "/" && !haskey(ck, "secure")
    for prefix in ("Secure", "Host")                                                    # test_delete_cookie_secure_prefix
        delete_cookie!(r, "__$(prefix)-c")
        @test haskey(dhw_cookie(r, "__$(prefix)-c"), "secure")
    end
    delete_cookie!(r, "s"; samesite = "none")                                           # test_delete_cookie_secure_samesite_none
    @test haskey(dhw_cookie(r, "s"), "secure") && dhw_cookie(r, "s")["samesite"] == "none"
    delete_cookie!(r, "l"; samesite = "lax")                                            # test_delete_cookie_samesite
    @test dhw_cookie(r, "l")["samesite"] == "lax" && !haskey(dhw_cookie(r, "l"), "secure")
end

@testset "django: content_disposition_header (utils_tests.test_http), FileResponse" begin
    cd = Juango.content_disposition
    @test cd("test.txt"; attachment = false) == "inline; filename=\"test.txt\""           # test_basic
    @test cd("test.txt"; attachment = true) == "attachment; filename=\"test.txt\""
    @test cd("esp\u00e9cimen.txt"; attachment = true) == "attachment; filename*=utf-8''esp%C3%A9cimen.txt"
    @test cd("\"test.txt\""; attachment = false) == "inline; filename=\"\\\"test.txt\\\"\""
    @test cd("te\\st.txt"; attachment = false) == "inline; filename=\"te\\\\st.txt\""
    @test cd("te\tst.txt"; attachment = false) == "inline; filename=\"te\tst.txt\""
    @test cd("te\nst.txt"; attachment = true) == "attachment; filename*=utf-8''te%0Ast.txt"
    @test cd(nothing; attachment = true) == "attachment" && cd(nothing; attachment = false) === nothing
    @test cd("\u7956\u6cd5\u738b.odt"; attachment = true) == "attachment; filename*=utf-8''%E7%A5%96%E6%B3%95%E7%8E%8B.odt"
    dir = mktempdir()
    p = joinpath(dir, "test_fileresponse.py"); write(p, "binary content")
    r = FileResponse(p)                                                                 # test_file_from_disk_response
    @test getheader(r, "Content-Disposition") == "inline; filename=\"test_fileresponse.py\"" && getheader(r, "Content-Length") == "14"
    r = FileResponse(p; as_attachment = true)                                           # test_file_from_disk_as_attachment
    @test getheader(r, "Content-Disposition") == "attachment; filename=\"test_fileresponse.py\""
    r = FileResponse(IOBuffer("binary content"))                                        # test_buffer_explicit_absolute_filename (none)
    @test !hasheader(r, "Content-Disposition") && text(r) == "binary content"
    r = FileResponse(IOBuffer("binary content"); as_attachment = true)
    @test getheader(r, "Content-Disposition") == "attachment"                           # test_content_disposition_buffer_attachment
    gz = joinpath(dir, "test.tar.gz"); write(gz, "x")
    @test getheader(FileResponse(gz), "Content-Type") == "application/gzip"              # test_compressed_response
    # not translated: file-like objects without names, Content-Type sniffing of other compression
    # encodings, the response's closing of the file
end
