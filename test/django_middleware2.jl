# Django's middleware_exceptions tests, ported (#227).
# julia --project=test test/django_middleware2.jl   (see setup.jl)
#
# Juango's middleware hooks are methods on the middleware function: process_view(mw, req, view, kwargs),
# process_exception(mw, req, e) and process_template_response(mw, req, resp).
# Not translated: the async tests (Juango has no async handler; sync_capable/async_capable), RootUrlconfTests
# (ROOT_URLCONF is always set) and the sync/async adaptation tests.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DME_LOG = Any[]
dme_normal_view(req) = HttpResponse("OK")
dme_server_error(req) = error("Error in view")
dme_permission_denied(req) = throw(PermissionDenied())
dme_template_response(req) = TemplateResponse(req, Template("template_response OK{% for m in mw %}\n{{ m }}{% endfor %}"), Dict("mw" => Any[]))
dme_exception_in_render(req) = TemplateResponse(req, Template("{% include \"dme_no_such_template.html\" %}"))
const DME_URLS = Any[path("middleware_exceptions/view/", dme_normal_view), path("middleware_exceptions/error/", dme_server_error),
                     path("middleware_exceptions/permission_denied/", dme_permission_denied),
                     path("middleware_exceptions/exception_in_render/", dme_exception_in_render),
                     path("middleware_exceptions/template_response/", dme_template_response)]

# --- tests/middleware_exceptions/middleware.py ---------------------------------------------------------------
dme_view_none(gr) = req -> gr(req)
Juango.process_view(::typeof(dme_view_none), req, view, kw) = (push!(DME_LOG, "processed view $(nameof(view))"); nothing)
dme_view_response(gr) = req -> gr(req)
Juango.process_view(::typeof(dme_view_response), req, view, kw) = HttpResponse("Processed view $(nameof(view))")
dme_view_template_response(gr) = req -> gr(req)
Juango.process_view(::typeof(dme_view_template_response), req, view, kw) =
    TemplateResponse(req, Template("Processed view {{ view }}{% for m in mw %}\n{{ m }}{% endfor %}"),
                     Dict("view" => string(nameof(view)), "mw" => Any["ProcessViewTemplateResponseMiddleware"]))
dme_log(gr) = req -> (r = gr(req); push!(DME_LOG, (r.status, text(r))); r)          # reads the content
dme_template_response_mw(gr) = req -> gr(req)
Juango.process_template_response(::typeof(dme_template_response_mw), req, resp) = (push!(resp.context_data["mw"], "TemplateResponseMiddleware"); resp)
dme_no_template_response(gr) = req -> gr(req)
Juango.process_template_response(::typeof(dme_no_template_response), req, resp) = nothing
dme_process_exception(gr) = req -> gr(req)
Juango.process_exception(::typeof(dme_process_exception), req, e) = HttpResponse("Exception caught")
dme_process_exception_log(gr) = req -> gr(req)
Juango.process_exception(::typeof(dme_process_exception_log), req, e) = (push!(DME_LOG, "process-exception"); nothing)
dme_not_found(gr) = req -> throw(Http404())
dme_payment(gr) = req -> (r = gr(req); r.status = 402; r)
dme_not_used(gr) = throw(Juango.MiddlewareNotUsed())
dme_not_used_msg(gr) = throw(Juango.MiddlewareNotUsed("spam eggs"))

@testset "django middleware_exceptions: MiddlewareTests" begin
    # (Django's test client raises a request's exception; Juango's does with raise_request_exception)
    run_with(mws, url; raise = false) = (empty!(DME_LOG); override_settings(ROOT_URLCONF = DME_URLS, MIDDLEWARE = Any[mws...]) do
        get(Client(; raise_request_exception = raise), "/middleware_exceptions/$url/")
    end)
    # test_process_view_return_none / test_process_view_return_response
    r = run_with([dme_view_none], "view")
    @test DME_LOG == ["processed view dme_normal_view"] && text(r) == "OK"
    @test text(run_with([dme_view_response], "view")) == "Processed view dme_normal_view"
    # test_templateresponse_from_process_view_rendered: rendered before the middleware around it read it
    @test text(run_with([dme_view_template_response, dme_log], "view")) == "Processed view dme_normal_view\nProcessViewTemplateResponseMiddleware"
    # test_templateresponse_from_process_view_passed_to_process_template_response
    @test text(run_with([dme_view_template_response, dme_template_response_mw], "view")) ==
          "Processed view dme_normal_view\nProcessViewTemplateResponseMiddleware\nTemplateResponseMiddleware"
    # test_process_template_response / test_process_template_response_returns_none
    @test text(run_with([dme_template_response_mw], "template_response")) == "template_response OK\nTemplateResponseMiddleware"
    @test_throws "Main.dme_no_template_response.process_template_response didn't return an HttpResponse object. It returned nothing instead." run_with([dme_no_template_response], "template_response"; raise = true)
    # test_view_exception_converted_before_middleware
    r = run_with([dme_log], "permission_denied")
    @test DME_LOG == [(r.status, text(r))] && r.status == 403
    # test_view_exception_handled_by_process_exception
    @test text(run_with([dme_process_exception], "error")) == "Exception caught"
    # test_response_from_process_exception_short_circuits_remainder (innermost first)
    r = run_with([dme_process_exception_log, dme_process_exception], "error")
    @test isempty(DME_LOG) && text(r) == "Exception caught"
    # test_response_from_process_exception_when_return_response
    r = run_with([dme_process_exception, dme_process_exception_log], "error")
    @test DME_LOG == ["process-exception"] && text(r) == "Exception caught"
    # test_exception_in_middleware_converted_before_prior_middleware
    r = run_with([dme_log, dme_not_found], "view")
    @test DME_LOG == [(404, text(r))] && r.status == 404
    # test_exception_in_render_passed_to_process_exception
    @test text(run_with([dme_process_exception], "exception_in_render")) == "Exception caught"
end

@testset "django middleware_exceptions: MiddlewareNotUsedTests, MiddlewareSyncAsyncTests" begin
    mem = MemoryHandler()
    conf = Dict("handlers" => Dict("mem" => Dict("class" => mem, "level" => "DEBUG")),
                "loggers" => Dict("juango.request" => Dict("handlers" => ["mem"], "level" => "DEBUG", "propagate" => false)))
    logged(mws; debug = true) = (empty!(mem.records);
        override_settings(DEBUG = debug, LOGGING = conf, ROOT_URLCONF = DME_URLS, MIDDLEWARE = Any[mws...]) do
            get(Client(), "/middleware_exceptions/view/")
        end; [r.message for r in mem.records if r.name == "juango.request"])
    # test_raise_exception
    @test_throws Juango.MiddlewareNotUsed dme_not_used(req -> HttpResponse())
    # test_log / test_log_custom_message / test_do_not_log_when_debug_is_false
    @test logged([dme_not_used]) == ["MiddlewareNotUsed: 'Main.dme_not_used'"]
    @test logged([dme_not_used_msg]) == ["MiddlewareNotUsed('Main.dme_not_used_msg'): spam eggs"]
    @test isempty(logged([dme_not_used]; debug = false))
    # test_sync_middleware
    override_settings(ROOT_URLCONF = DME_URLS, MIDDLEWARE = Any[dme_payment]) do
        @test get(Client(), "/middleware_exceptions/view/").status == 402
    end
end
