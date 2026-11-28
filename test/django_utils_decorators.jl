# Django's utils_tests test_decorators.py, ported (#227): decorator_from_middleware.
# julia --project=test test/django_utils_decorators.jl   (see setup.jl; no database needed)
#
# A Juango middleware is a `get_response -> handler` factory (Django's new-style middleware), without the old
# process_view/process_template_response hooks: the request and response phases are what's tested. Not translated:
# the TemplateResponse ordering (#16004: Juango's views return rendered responses).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

struct DudClassView end
(::DudClassView)(req) = HttpResponse("")

@testset "django utils_tests test_decorators: DecoratorFromMiddlewareTests" begin
    reached = Dict{Symbol,Any}()
    function full_mw(get_response)
        function (req)
            reached[:request] = true
            resp = get_response(req)
            reached[:response] = true
            reached[:content] = String(copy(resp.body))
            resp
        end
    end
    full_dec = Juango.decorator_from_middleware(full_mw)
    normal_view = full_dec(req -> HttpResponse(render(Template("Hello world"), Dict{String,Any}())))
    resp = normal_view(Juango.Request("GET", "/"))
    @test resp.status == 200 && get(reached, :request, false) && get(reached, :response, false) && reached[:content] == "Hello world"
    # (a callable object as the view)
    @test full_dec(DudClassView())(Juango.Request("GET", "/")).status == 200
end
