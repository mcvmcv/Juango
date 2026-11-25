# Django's requests_tests, ported (#227, part): test_accept_header (MediaType, accepted_types, get_preferred_type)
# and test_data_upload_settings (DATA_UPLOAD_MAX_MEMORY_SIZE, DATA_UPLOAD_MAX_NUMBER_FIELDS, DATA_UPLOAD_MAX_NUMBER_FILES).
# julia --project=test test/django_requests.jl   (see setup.jl)
#
# Django's RequestDataTooBig, TooManyFieldsSent and TooManyFilesSent are 400s (BadRequest) from the handler here;
# the tests send the requests through the test client. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

using Juango: MediaType, accepted_types, accepted_types_by_precedence, accepted_type, get_preferred_type, accepts, getlist
const MT = MediaType
drq(accept) = (r = get(RequestFactory(), "/"); accept === nothing || (r.headers["accept"] = accept); r)
dstr(ts) = [string(t) for t in ts]

@testset "django requests_tests: MediaTypeTests" begin
    for e in (nothing, "", "  ")                                                                     # test_empty
        @test string(MT(e)) == "" && sprint(show, MT(e)) == "<MediaType: >"
    end
    @test string(MT("*/*; q=0.8")) == "*/*; q=0.8" && string(MT("application/xml")) == "application/xml"           # test_str
    @test string(MT("application/xml;type=madeup;q=42")) == "application/xml; type=madeup; q=42"
    @test sprint(show, MT("*/*; q=0.8")) == "<MediaType: */*; q=0.8>"                                  # test_repr
    for (a, m) in [("*/*; q=0.8", "*/*"), ("*/*", "application/json"), (" */* ", "application/json"), ("application/*", "application/json"),   # test_match
                   ("application/*", "application/*"), ("application/xml", "application/xml"), (" application/xml ", "application/xml"),
                   ("application/xml", " application/xml "), ("text/vcard; version=4.0", "text/vcard; version=4.0"),
                   ("text/vcard; version=4.0; q=0.7", "text/vcard; version=4.0"), ("text/vcard; version=4.0", "text/vcard")]
        @test match(MT(a), m) === true
    end
    for (a, m) in [("*/*", nothing), ("*/*", ""), ("*/*", "; q=0.8"), ("/*", "*/*"), ("*/*", "/*"), ("application", "application/*"),   # test_no_match
                   ("application/*", "application"), ("application/xml", "application/html"), ("text/vcard; version=4.0", "text/vcard; version=3.0"),
                   ("text/vcard; q=0.7", "text/vcard; version=3.0"), ("text/vcard", "text/vcard; version=3.0")]
        @test match(MT(a), m) === false
    end
    for (a, params, rp) in [("text/plain", Dict(), Dict()), ("text/plain;q=0.7", Dict("q" => "0.7"), Dict()),               # test_params
                            ("text/plain;version=2;q=0.8", Dict("version" => "2", "q" => "0.8"), Dict("version" => "2")),
                            ("text/plain; charset=UTF-8; q=0.3", Dict("charset" => "UTF-8", "q" => "0.3"), Dict("charset" => "UTF-8")),
                            ("text/plain ; q = 0.5 ; version = 3.0", Dict("q" => "0.5", "version" => "3.0"), Dict("version" => "3.0")),
                            ("text/html;q= 0.9", Dict("q" => "0.9"), Dict()), ("text/html ; q = \"0.6\"", Dict("q" => "0.6"), Dict())]
        m = MT(a)
        @test Dict(m.params) == params && Juango.range_params(m) == rp
    end
    for (a, q) in [("*/*; q=0.8", 0.8), ("*/*; q=0.0001", 0), ("*/*; q=0.12345", 0.123), ("*/*; q=0.1", 0.1), ("*/*; q=-1", 1),   # test_quality
                   ("*/*; q=2", 1), ("*/*; q=h", 1), ("*/*; q=inf", 1), ("*/*; q=0", 0), ("*/*", 1)]
        @test Juango.quality(MT(a)) == q
    end
    for (a, s) in [("*/*", 0), ("*/*;q=0.5", 0), ("text/*", 1), ("text/*;q=0.5", 1), ("text/html", 2), ("text/html;q=1", 2),   # test_specificity
                   ("text/html;q=0.5", 2), ("text/html;version=5", 3)]
        @test Juango.specificity(MT(a)) == s
    end
end

@testset "django requests_tests: AcceptHeaderTests" begin
    @test dstr(accepted_types(drq(nothing))) == ["*/*"]                                                # test_no_headers
    r = drq("text/*,text/html, application/xhtml+xml,application/xml ;q=0.9,*/*;q=0.8,")             # test_accept_headers
    @test dstr(accepted_types(r)) == ["text/html", "application/xhtml+xml", "text/*", "application/xml; q=0.9", "*/*; q=0.8"]
    @test dstr(accepted_types_by_precedence(r)) == ["text/html", "application/xhtml+xml", "application/xml; q=0.9", "text/*", "*/*; q=0.8"]
    @test dstr(accepted_types(drq("text/*;q=0,text/html"))) == ["text/html"]                           # test_zero_quality
    @test dstr(accepted_types_by_precedence(drq("text/*, text/plain, text/plain;format=flowed, */*"))) ==     # test_precedence
          ["text/plain; format=flowed", "text/plain", "text/*", "*/*"]
    r = drq("*/*")                                                                                     # test_request_accepts_any
    @test accepts(r, "application/json") && get_preferred_type(r, String[]) === nothing &&
          get_preferred_type(r, ["application/json", "text/plain"]) == "application/json"
    r = drq("")                                                                                        # test_request_accepts_none
    @test !accepts(r, "application/json") && isempty(accepted_types(r)) && get_preferred_type(r, ["application/json", "text/plain"]) === nothing
    r = drq("text/html,application/xhtml+xml,application/xml;q=0.9")                                  # test_request_accepts_some
    @test accepts(r, "text/html") && accepts(r, "application/xhtml+xml") && accepts(r, "application/xml") && !accepts(r, "application/json")
    r = drq("text/html,application/xml;q=0.9,*/*;q=0.1,text/*;q=0.5")                                 # test_accept_header_priority
    for (types, pref) in [(["text/html", "application/xml"], "text/html"), (["application/xml", "application/json"], "application/xml"),
                          (["application/json"], "application/json"), (["application/json", "text/plain"], "text/plain")]
        @test get_preferred_type(r, types) == pref
    end
    r = drq("text/*;q=0.8,text/html;q=0.8")                                                            # test_accept_header_priority_overlapping_mime
    @test dstr(accepted_types(r)) == ["text/html; q=0.8", "text/*; q=0.8"] == dstr(accepted_types_by_precedence(r))
    @test get_preferred_type(drq("text/html"), ["application/json", "text/plain"]) === nothing          # test_no_matching_accepted_type
    r = drq("text/vcard; version=3.0, text/html;q=0.5")                                                # test_accept_with_param
    @test get_preferred_type(r, ["text/vcard; version=4.0", "text/vcard; version=3.0", "text/vcard", "text/directory"]) == "text/vcard; version=3.0"
    @test get_preferred_type(r, ["text/vcard; version=4.0", "text/vcard", "text/directory"]) === nothing
    @test get_preferred_type(r, ["text/vcard; version=4.0", "text/html"]) == "text/html"
    r = drq("text/*;q=0.3,text/html;q=0.7,text/html;level=1,text/html;level=2;q=0.4,*/*;q=0.5")          # test_quality_for_media_type_rfc7231
    for (m, q) in [("text/html;level=1", 1), ("text/html", 0.7), ("text/plain", 0.3), ("image/jpeg", 0.5), ("text/html;level=2", 0.4), ("text/html;level=3", 0.7)]
        @test Juango.quality(accepted_type(r, m)) == q
    end
    @test get_preferred_type(r, ["text/html", "text/html; level=1"]) == "text/html; level=1"
    @test get_preferred_type(r, ["text/html; level=2", "text/html; level=3"]) == "text/html; level=3"
    r = drq("text/*;q=0.3, text/plain;q=0.7, text/plain;format=flowed, text/plain;format=fixed;q=0.4, */*;q=0.5")   # test_quality_for_media_type_rfc9110
    for (m, q) in [("text/plain;format=flowed", 1), ("text/plain", 0.7), ("text/html", 0.3), ("image/jpeg", 0.5), ("text/plain;format=fixed", 0.4), ("text/html;level=3", 0.3)]
        @test Juango.quality(accepted_type(r, m)) == q
    end
    @test get_preferred_type(r, ["text/plain", "text/plain; format=flowed"]) == "text/plain; format=flowed"
    @test get_preferred_type(r, ["text/html", "image/jpeg"]) == "image/jpeg"
    r = drq("text/plain;q=0.5,text/html")                                                             # test_quality_breaks_specificity
    @test Juango.quality(accepted_type(r, "text/plain")) == 0.5 && Juango.specificity(accepted_type(r, "text/plain")) == 2
    @test get_preferred_type(r, ["text/html", "text/plain"]) == "text/html"
    r = drq("text/*,image/jpeg")                                                                      # test_quality_over_specificity
    @test Juango.specificity(accepted_type(r, "text/plain")) == 1 && get_preferred_type(r, ["text/plain", "image/jpeg"]) == "image/jpeg"
end

drq_echo(req) = HttpResponse(join(sort(["$k=$(join(getlist(req.POST, k), ","))" for k in keys(req.POST.data)]), "&") * "|" *
                             join(sort(collect(keys(req.FILES))), ","))
const DRQ_URLS = Any[path("echo/", drq_echo)]
const DRQ_B = "boundary"
drq_mp(parts) = join(["--$DRQ_B\r\nContent-Disposition: form-data; $d\r\n" * (ct === nothing ? "" : "Content-Type: $ct\r\n") * "\r\n$v\r\n" for (d, ct, v) in parts]) * "--$DRQ_B--\r\n"
@testset "django requests_tests: test_data_upload_settings" begin
    override_settings(ROOT_URLCONF = DRQ_URLS, MIDDLEWARE = Any[]) do
        c = Client()
        form(lim; body = "a=1&a=2&a=3\r\n") = override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE = lim) do
            request(c, "POST", "/echo/"; body = body, content_type = "application/x-www-form-urlencoded").status
        end
        # DataUploadMaxMemorySizeFormPostTests: test_size_exceeded, test_size_not_exceeded, test_no_limit
        @test form(12) == 400 && form(13) == 200 && form(nothing) == 200
        # DataUploadMaxMemorySizeMultipartPostTests: the fields count (name + value), not the files
        mp = drq_mp([("name=\"name\"", nothing, "value")])
        mpost(lim, body) = override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE = lim) do
            request(c, "POST", "/echo/"; body = body, content_type = "multipart/form-data; boundary=$DRQ_B")
        end
        @test mpost(10, mp).status == 400 && mpost(11, mp).status == 200 && mpost(nothing, mp).status == 200
        r = mpost(1, drq_mp([("name=\"File1\"; filename=\"test.txt\"", "text/plain", "value")]))     # test_file_passes
        @test r.status == 200 && text(r) == "|File1"
        # DataUploadMaxMemorySizeGetTests: a GET with a body
        get_body(lim) = override_settings(DATA_UPLOAD_MAX_MEMORY_SIZE = lim) do
            request(c, "GET", "/echo/"; body = "abc", content_type = "text/plain").status
        end
        @test get_body(2) == 400 && get_body(3) == 200 && get_body(nothing) == 200
        # DataUploadMaxNumberOfFieldsGet
        fields(lim, f) = override_settings(DATA_UPLOAD_MAX_NUMBER_FIELDS = lim) do; f(); end
        @test fields(1, () -> get(c, "/echo/?a=1&a=2&a=3").status) == 400 && fields(3, () -> get(c, "/echo/?a=1&a=2&a=3").status) == 200
        # DataUploadMaxNumberOfFieldsMultipartPost
        mp2 = drq_mp([("name=\"name1\"", nothing, "value1"), ("name=\"name2\"", nothing, "value2")])
        mpf(lim) = fields(lim, () -> request(c, "POST", "/echo/"; body = mp2, content_type = "multipart/form-data; boundary=$DRQ_B").status)
        @test mpf(1) == 400 && mpf(2) == 200 && mpf(nothing) == 200
        # DataUploadMaxNumberOfFilesMultipartPost
        mp3 = drq_mp([("name=\"name1\"; filename=\"name1.txt\"", "text/plain", "value1"), ("name=\"name2\"; filename=\"name2.txt\"", "text/plain", "value2")])
        files(lim) = override_settings(DATA_UPLOAD_MAX_NUMBER_FILES = lim) do
            request(c, "POST", "/echo/"; body = mp3, content_type = "multipart/form-data; boundary=$DRQ_B").status
        end
        @test files(1) == 400 && files(2) == 200 && files(nothing) == 200
        # DataUploadMaxNumberOfFieldsFormPost
        ff(lim) = fields(lim, () -> request(c, "POST", "/echo/"; body = "a=1&a=2&a=3\r\n", content_type = "application/x-www-form-urlencoded").status)
        @test ff(2) == 400 && ff(3) == 200 && ff(nothing) == 200
        # (the query string and the body are counted on their own, as Django's)
        @test fields(3, () -> request(c, "POST", "/echo/?b=1&b=2"; body = "a=1&a=2", content_type = "application/x-www-form-urlencoded").status) == 200
    end
    # not translated: requests_tests/tests.py (the WSGIRequest environ, stream reading and the body's read-once rules
    # are Python's; Juango's request basics are in django_httpwrappers.jl and django_handlers.jl)
end
