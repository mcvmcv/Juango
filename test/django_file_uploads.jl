# Django's file_uploads tests, ported (#227): tests/file_uploads (FileUploadTests' parsing of multipart bodies,
# MultiPartParserTests): upload file names sanitized before the view sees them, RFC 2231 names, base64 parts,
# content type parameters, truncated and empty bodies.
# julia --project=test test/django_file_uploads.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DFU_BOUNDARY = "BoUnDaRyStRiNg"
const DFU_UNICODE_FILENAME = "test-0123456789_中文_Orléans.jpg"
const DFU_TRAVERSAL = ["/tmp/hax0rd.txt", "C:\\Windows\\hax0rd.txt", "C:/Windows/hax0rd.txt", "\\tmp\\hax0rd.txt", "/tmp\\hax0rd.txt",
                       "subdir/hax0rd.txt", "subdir\\hax0rd.txt", "sub/dir\\hax0rd.txt", "../../hax0rd.txt", "..\\..\\hax0rd.txt",
                       "../..\\hax0rd.txt", "..&#x2F;hax0rd.txt", "..&sol;hax0rd.txt"]
# the view: each file's name, or each field's value (Django's /echo/), and the files' content type parameters
dfu_echo(req) = Juango.JsonResponse(merge(Dict{String,Any}(k => req.POST[k] for k in keys(req.POST.data)),
                                          Dict{String,Any}(k => req.FILES[k].name for k in keys(req.FILES))))
dfu_extra(req) = Juango.JsonResponse(Dict{String,Any}(k => req.FILES[k].content_type_extra for k in keys(req.FILES)))
dfu_content(req) = Juango.JsonResponse(Dict{String,Any}(k => String(read(req.FILES[k])) for k in keys(req.FILES)))
dfu_getlist(req) = Juango.JsonResponse(Dict{String,Any}(k => [f.name for f in Juango.getlist(req.FILES, k)] for k in keys(req.FILES)))
const DFU_URLS = Any[path("echo/", dfu_echo), path("extra/", dfu_extra), path("content/", dfu_content), path("getlist/", dfu_getlist)]
"A multipart body of parts, each (disposition params, headers, content)."
function dfu_payload(parts; close = true)
    io = IOBuffer()
    for (disp, headers, content) in parts
        print(io, "--", DFU_BOUNDARY, "\r\n", "Content-Disposition: form-data; ", disp, "\r\n")
        for h in headers
            print(io, h, "\r\n")
        end
        print(io, "\r\n", content, "\r\n")
    end
    close && print(io, "--", DFU_BOUNDARY, "--\r\n")
    String(take!(io))
end
dfu_post(c, url, body) = Juango.JSON.parse(text(request(c, "POST", url; body = body, content_type = "multipart/form-data; boundary=$DFU_BOUNDARY")))
dfu_file(name, filename; ct = "application/octet-stream", content = "You got pwnd.") =
    ("name=\"$name\"; filename=\"$filename\"", ["Content-Type: $ct"], content)

@testset "django file_uploads" begin
    override_settings(ROOT_URLCONF = DFU_URLS, MIDDLEWARE = Any[]) do
        c = Client()
        # test_simple_upload, test_file_content: fields and files through the client
        r = Juango.JSON.parse(text(post(c, "/echo/", Dict("name" => "Ringo", "file_field" => UploadedFile("test.txt", "file contents")))))
        @test r == Dict("name" => "Ringo", "file_field" => "test.txt")
        r = Juango.JSON.parse(text(post(c, "/content/", Dict("f" => UploadedFile("a.txt", "no content")))))
        @test r == Dict("f" => "no content")
        # test_unicode_file_name, ..._rfc2231, test_unicode_name_rfc2231 (and with double quotes)
        @test dfu_post(c, "/echo/", dfu_payload([dfu_file("file_unicode", DFU_UNICODE_FILENAME)]))["file_unicode"] == DFU_UNICODE_FILENAME
        q = Juango.urlquote(DFU_UNICODE_FILENAME)
        for disp in ["name=\"file_unicode\"; filename*=UTF-8''$q", "name*=UTF-8''file_unicode; filename*=UTF-8''$q",
                     "name=\"file_unicode\"; filename*=\"UTF-8''$q\"", "name*=\"UTF-8''file_unicode\"; filename*=\"UTF-8''$q\""]
            @test dfu_post(c, "/echo/", dfu_payload([(disp, ["Content-Type: application/octet-stream"], "You got pwnd.")])) ==
                  Dict("file_unicode" => DFU_UNICODE_FILENAME)
        end
        # test_blank_filenames: empty before or after sanitizing: no file
        names = ["", "C:\\Windows\\", "/", "ends-with-slash/"]
        @test dfu_post(c, "/echo/", dfu_payload([dfu_file("file$(i-1)", n) for (i, n) in enumerate(names)])) == Dict()
        # test_non_printable_chars_in_file_names
        @test dfu_post(c, "/echo/", dfu_payload([dfu_file("file", "non-\x00printable\x00\n_chars.txt\x00")]))["file"] == "non-printable_chars.txt"
        # test_dangerous_file_names: sanitized before the view
        r = dfu_post(c, "/echo/", dfu_payload([dfu_file("file$(i-1)", n) for (i, n) in enumerate(DFU_TRAVERSAL)]))
        @test all(i -> r["file$(i-1)"] == "hax0rd.txt", eachindex(DFU_TRAVERSAL))
        # test_filename_overflow
        long = "f"^300
        cases = [("long_filename", "$long.txt", "$(long[1:251]).txt"), ("long_extension", "foo.$long", ".$(long[1:254])"),
                 ("no_extension", long, long[1:255]), ("no_filename", ".$long", ".$(long[1:254])"), ("long_everything", "$long.$long", ".$(long[1:254])")]
        r = dfu_post(c, "/echo/", dfu_payload([dfu_file(n, f; content = "Oops.") for (n, f, _) in cases]))
        @test all(x -> r[x[1]] == x[3] && length(r[x[1]]) < 256, cases)
        # test_filename_case_preservation
        @test dfu_post(c, "/echo/", dfu_payload([dfu_file("file_field", "MiXeD_cAsE.txt")]))["file_field"] == "MiXeD_cAsE.txt"
        # test_filename_traversal_upload: the name in FILES has no directory, whatever the HTML entities
        @test dfu_post(c, "/echo/", dfu_payload([dfu_file("my_file", "..&#x2F;test.txt")]))["my_file"] == "test.txt"
        # test_base64_upload, test_big_base64_upload, test_big_base64_newlines_upload, test_base64_invalid_upload
        for content in ["This data will be transmitted base64-encoded.", "Big data"^68000]
            enc = Juango.Base64.base64encode(content)
            for body in (enc, join([enc[i:min(i + 75, end)] for i in 1:76:length(enc)], "\r\n"))
                r = dfu_post(c, "/content/", dfu_payload([("name=\"file\"; filename=\"test.txt\"",
                                                           ["Content-Type: application/octet-stream", "Content-Transfer-Encoding: base64"], body)]))
                @test r["file"] == content
            end
        end
        r = request(c, "POST", "/content/"; content_type = "multipart/form-data; boundary=$DFU_BOUNDARY",
                    body = dfu_payload([("name=\"file\"; filename=\"test.txt\"", ["Content-Type: application/octet-stream",
                                                                                 "Content-Transfer-Encoding: base64"], "!!not base64!!")]))
        @test r.status == 400
        # test_content_type_extra
        r = Juango.JSON.parse(text(post(c, "/extra/", Dict("no_content_type" => UploadedFile("a.ctype_extra", "something"),
                                                           "simple_file" => UploadedFile("b.ctype_extra", "something";
                                                                                         content_type = "text/plain; test-key=test_value")))))
        @test r["no_content_type"] == Dict() && r["simple_file"] == Dict("test-key" => "test_value")
        # test_truncated_multipart_handled_gracefully, test_empty_multipart_handled_gracefully
        full = dfu_payload([dfu_file("file", "foo.txt"; content = "file contents")])
        @test dfu_post(c, "/echo/", full[1:end-10]) == Dict()
        @test dfu_post(c, "/echo/", "") == Dict()
        # test_fileupload_getlist
        r = Juango.JSON.parse(text(post(c, "/getlist/", Dict("file1" => [UploadedFile("a.txt", "a"), UploadedFile("b.txt", "b")],
                                                             "file2" => UploadedFile("c.txt", "c")))))
        @test r == Dict("file1" => ["a.txt", "b.txt"], "file2" => ["c.txt"])
        # MultiParserTests: test_invalid_content_type (no boundary: a 400), test_sanitize_file_name, test_sanitize_invalid_file_name
        @test request(c, "POST", "/echo/"; body = "x", content_type = "multipart/form-data").status == 400
        for (name, expected) in [("diLLmUTX", "diLLmUTX"), ("..", nothing), ("../x", "x"), ("x/../y", "y"), ("..&#x2F;z", "z"),
                                 ("non-\x00printable", "non-printable")]
            @test Juango.sanitize_file_name(name) == expected
        end
        for name in ["/tmp/", "c:\\tmp\\", "/tmp/.", "c:\\tmp\\.", "/tmp/..", "c:\\tmp\\..", ""]
            @test Juango.sanitize_file_name(name) === nothing
        end
    end
    # not translated: the custom and broken upload handlers (Juango's are `upload_file` methods, tested in views.jl), the
    # temporary-file handlers' stop/interrupt, large header fields, closing files at the request's end, directory creation
end
