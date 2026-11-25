# Django's logging_tests, ported (#227, part): HandlerLoggingTests (what juango.request logs), LoggingFiltersTest,
# CallbackFilterTest, AdminEmailHandlerTest's subjects and HTML, SecurityLoggerTest, LogResponseRealLoggerTests
# (log_response, escape_log).
# julia --project=test test/django_logging.jl   (see setup.jl)
#
# Records are kept with a "memory" handler (Django's assertLogs). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

using Juango: log_response, reason_phrase

dlg_view(req) = HttpResponse("ok")
dlg_redirect(req) = HttpResponseRedirect("/innocent/")
dlg_raise404(req) = throw(Http404("nope"))
dlg_boom(req) = error("uncaught")
dlg_500(req) = HttpResponse("x"; status = 500)
dlg_599(req) = HttpResponse("x"; status = 599)
dlg_403(req) = throw(PermissionDenied())
dlg_bad(req) = throw(BadRequest(""))
dlg_suspicious(req) = throw(Juango.DisallowedRedirect("dubious"))
const DLG_URLS = Any[path("innocent/", dlg_view), path("redirect/", dlg_redirect), path("does_not_exist_raised/", dlg_raise404),
                     path("uncaught_exception/", dlg_boom), path("internal_server_error/", dlg_500), path("internal_server_error_599/", dlg_599),
                     path("permission_denied/", dlg_403), path("bad_request/", dlg_bad), path("suspicious/", dlg_suspicious)]
"Run `f()` logging to a memory handler (juango.request, juango.security and the root); returns its records."
function dlg_records(f; level = "DEBUG", extra = Dict())
    mem = Juango.MemoryHandler()
    conf = merge(Dict("handlers" => Dict("mem" => Dict("class" => mem, "level" => level)),
                      "loggers" => Dict("juango" => Dict("handlers" => ["mem"], "level" => level, "propagate" => false)),
                      "root" => Dict("handlers" => String[], "level" => "WARNING")), extra)
    override_settings(LOGGING = conf) do
        f()
    end
    mem.records
end
dlg_req(rs) = [(r.message, r.level, get(r.data, :status_code, nothing)) for r in rs if r.name == "juango.request"]

@testset "django logging_tests: HandlerLoggingTests" begin
    override_settings(ROOT_URLCONF = DLG_URLS, MIDDLEWARE = Any[], DEBUG = false, ALLOWED_HOSTS = ["testserver"]) do
        c = Client()
        @test isempty(dlg_req(dlg_records(() -> get(c, "/innocent/"))))                                  # test_page_found_no_warning
        @test isempty(dlg_req(dlg_records(() -> get(c, "/redirect/"))))                                  # test_redirect_no_warning
        @test dlg_req(dlg_records(() -> get(c, "/does_not_exist/"))) == [("Not Found: /does_not_exist/", 30, 404)]   # test_page_not_found_warning
        @test dlg_req(dlg_records(() -> get(c, "/%1B[1;31mNOW IN RED!!!1B[0m/"))) ==                      # test_control_chars_escaped
              [("Not Found: /\\x1b[1;31mNOW IN RED!!!1B[0m/", 30, 404)]
        @test dlg_req(dlg_records(() -> get(c, "/does_not_exist_raised/"))) == [("Not Found: /does_not_exist_raised/", 30, 404)]   # test_page_not_found_raised
        rs = dlg_records(() -> get(c, "/uncaught_exception/"))                                           # test_uncaught_exception
        @test dlg_req(rs) == [("Internal Server Error: /uncaught_exception/", 40, 500)] && only(rs).exception !== nothing
        # test_internal_server_error, test_internal_server_error_599: a 5xx response a view returns is logged too
        @test dlg_req(dlg_records(() -> get(c, "/internal_server_error/"))) == [("Internal Server Error: /internal_server_error/", 40, 500)]
        @test dlg_req(dlg_records(() -> get(c, "/internal_server_error_599/"))) == [("Unknown Status Code: /internal_server_error_599/", 40, 599)]
        @test dlg_req(dlg_records(() -> get(c, "/permission_denied/"))) == [("Forbidden (Permission denied): /permission_denied/", 30, 403)]   # test_permission_denied
        @test dlg_req(dlg_records(() -> get(c, "/bad_request/"))) == [("Bad Request: /bad_request/", 30, 400)]
        # SecurityLoggerTest: a suspicious operation on juango.security.<name>, answered with 400
        rs = dlg_records(() -> @test get(c, "/suspicious/").status == 400)
        @test any(r -> r.name == "juango.security.DisallowedRedirect" && r.message == "dubious" && r.level == 40, rs)
        # (DisallowedHost: Juango's test client is exempt from ALLOWED_HOSTS; the host check is tested in views.jl)
    end
end

@testset "django logging_tests: LoggingFiltersTest, CallbackFilterTest" begin
    r = Juango.LogRecord("x", 40, "m", now(), Dict{Symbol,Any}(), nothing)
    h(filters...) = Juango.HandlerConf(Juango.MemoryHandler(), 0, collect(String, filters), "")
    override_settings(DEBUG = true) do                                                                  # test_require_debug_false_filter, ..._true
        @test !Juango.passes(h("require_debug_false"), r) && Juango.passes(h("require_debug_true"), r)
    end
    override_settings(DEBUG = false) do
        @test Juango.passes(h("require_debug_false"), r) && !Juango.passes(h("require_debug_true"), r)
    end
    # CallbackFilterTest: test_sense, test_passes_on_record (the callback gets the record)
    seen = Any[]
    mem = Juango.MemoryHandler()
    conf = Dict("filters" => Dict("odd" => Dict("callback" => rec -> (push!(seen, rec.message); isodd(rec.data[:n])))),
                "handlers" => Dict("mem" => Dict("class" => mem, "filters" => ["odd"])),
                "loggers" => Dict("dlg" => Dict("handlers" => ["mem"], "level" => "INFO")))
    override_settings(LOGGING = conf) do
        for n in 1:4
            log!("dlg", :info, "n$n"; n = n)
        end
    end
    @test [x.message for x in mem.records] == ["n1", "n3"] && seen == ["n1", "n2", "n3", "n4"]
    @test_throws Juango.ImproperlyConfigured override_settings(LOGGING = Dict("filters" => Dict("bad" => 1))) do
        log!("dlg", :error, "x")
    end
end

@testset "django logging_tests: AdminEmailHandlerTest" begin
    override_settings(ROOT_URLCONF = DLG_URLS, MIDDLEWARE = Any[], DEBUG = false, ADMINS = [("admin", "admin@example.com")],
                      EMAIL_SUBJECT_PREFIX = "-SuperAwesomeSubject-", ALLOWED_HOSTS = ["testserver"]) do
        conf(; html = false) = Dict("handlers" => Dict("mail" => Dict("class" => "mail_admins", "level" => "ERROR", "include_html" => html)),
                                    "loggers" => Dict("juango.request" => Dict("handlers" => ["mail"], "level" => "ERROR", "propagate" => false)))
        # test_accepts_args_and_request, test_subject_accepts_newlines: the subject's level, (EXTERNAL IP), message; newlines escaped
        empty!(Juango.outbox)
        override_settings(LOGGING = conf()) do
            get(Client(), "/uncaught_exception/")
        end
        @test only(Juango.outbox).subject == "-SuperAwesomeSubject-ERROR (EXTERNAL IP): Internal Server Error: /uncaught_exception/"
        @test only(Juango.outbox).to == ["admin@example.com"]
        empty!(Juango.outbox)
        override_settings(LOGGING = conf(), INTERNAL_IPS = ["127.0.0.1"]) do                             # (internal IP)
            get(Client(), "/uncaught_exception/")
        end
        @test only(Juango.outbox).subject == "-SuperAwesomeSubject-ERROR (internal IP): Internal Server Error: /uncaught_exception/"
        empty!(Juango.outbox)
        override_settings(LOGGING = Dict("handlers" => Dict("mail" => Dict("class" => "mail_admins", "level" => "ERROR")),
                                         "loggers" => Dict("dlg" => Dict("handlers" => ["mail"], "level" => "ERROR")))) do
            log!("dlg", :error, "Message \r\n with newlines")                                           # test_subject_accepts_newlines
        end
        @test only(Juango.outbox).subject == "-SuperAwesomeSubject-ERROR: Message \\r\\n with newlines"
        @test Juango.format_log_subject("x"^1000) == "x"^989                                            # test_truncate_subject
        # test_emit_non_ascii / include_html: the debug page attached as HTML only when asked
        empty!(Juango.outbox)
        override_settings(LOGGING = conf(; html = true)) do
            get(Client(), "/uncaught_exception/")
        end
        m = only(Juango.outbox)
        @test !isempty(m.alternatives) && occursin("uncaught", first(m.alternatives)[1])
        empty!(Juango.outbox)
        override_settings(LOGGING = conf()) do
            get(Client(), "/uncaught_exception/")
        end
        @test isempty(only(Juango.outbox).alternatives)
        # test_fail_silently: no ADMINS, nothing sent and no error
        empty!(Juango.outbox)
        override_settings(LOGGING = conf(), ADMINS = []) do
            @test get(Client(), "/uncaught_exception/").status == 500
        end
        @test isempty(Juango.outbox)
    end
    # not translated: custom email backends and reporter classes, the default logging config's console output,
    # SettingsConfigTest/SetupConfigureLogging (LOGGING_CONFIG callables), the colour formatters (ServerFormatter)
end

@testset "django logging_tests: LogResponseRealLoggerTests" begin
    rq = get(RequestFactory(), "/test-path/")
    lr(args...; kw...) = (rs = dlg_records(() -> log_response(args...; kw...)); [(r.message, r.level, r.data[:status_code], r.data[:request]) for r in rs])
    @test_throws ArgumentError log_response("No response provided"; response = nothing, request = rq)    # test_missing_response_raises_attribute_error
    @test lr("Missing request"; response = HttpResponse(""; status = 403)) == [("Missing request", 30, 403, nothing)]   # test_missing_request_logs_with_none
    @test lr("Server error occurred"; response = HttpResponse(""; status = 508), request = rq) == [("Server error occurred", 40, 508, rq)]   # test_logs_5xx_as_error
    @test lr("This is a teapot!"; response = HttpResponse(""; status = 418), request = rq)[1][2] == 30   # test_logs_4xx_as_warning
    @test lr("OK response"; response = HttpResponse(""; status = 201), request = rq)[1][2] == 20        # test_logs_2xx_as_info
    @test lr("Debug level log"; response = HttpResponse(""; status = 403), request = rq, level = :debug)[1][2] == 10   # test_custom_log_level
    r = HttpResponse(""; status = 500)                                                                   # test_logs_only_once_per_response
    rs = dlg_records() do
        log_response("First log"; response = r, request = rq); log_response("Second log"; response = r, request = rq)
    end
    @test [x.message for x in rs] == ["First log"]
    rs = dlg_records(() -> log_response("With exception"; response = HttpResponse(""; status = 500), request = rq,   # test_exc_info_output
                                        exception = (ErrorException("Simulated failure"), backtrace())))
    @test only(rs).exception[1].msg == "Simulated failure"
    @test lr("Something went wrong: %s (%d)", "DB error", 42; response = HttpResponse(""; status = 500))[1][1] ==   # test_format_args_are_applied
          "Something went wrong: DB error (42)"
    rs = dlg_records(() -> log_response("Handled by custom logger"; response = HttpResponse(""; status = 404), logger = "juango.custom"))   # test_logs_with_custom_logger
    @test only(rs).name == "juango.custom" && only(rs).level == 30
    # test_unicode_escape_escaping
    for (case, expected) in [("line\nbreak", "line\\nbreak"), ("carriage\rreturn", "carriage\\rreturn"), ("tab\tseparated", "tab\\tseparated"),
                             ("formfeed\f", "formfeed\\x0c"), ("bell\a", "bell\\x07"), ("slash\\test", "slash\\\\test"),
                             ("quote\"test\"", "quote\"test\""), ("café", "caf\\xe9"), ("é", "e\\u0301"), ("smile🙂", "smile\\U0001f642"),
                             ("weird ☃️", "weird \\u2603\\ufe0f"), ("Привет", "\\u041f\\u0440\\u0438\\u0432\\u0435\\u0442"), ("你好", "\\u4f60\\u597d"),
                             ("escape\e[31mred\e[0m", "escape\\x1b[31mred\\x1b[0m"),
                             ("/\r\n\r\n1984-04-22 INFO    Listening on 0.0.0.0:8080\r\n\r\n", "/\\r\\n\\r\\n1984-04-22 INFO    Listening on 0.0.0.0:8080\\r\\n\\r\\n"),
                             ("normal-path", "normal-path"), ("slash/colon:", "slash/colon:"), (0, "0"), ([1, 2, 3], "[1, 2, 3]")]
        m = lr("Test message: %s", case; response = HttpResponse(""; status = 318), level = :error)[1][1]
        @test m == "Test message: " * expected && length(split(m, '\n')) == 1
    end
    @test reason_phrase(404) == "Not Found" && reason_phrase(599) == "Unknown Status Code"
    @test Juango.escape_log(String(UInt8[0x2f, 0xed, 0x2f])) == "/\\xed/"                              # (not UTF-8: the bytes)
end
