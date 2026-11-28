# Django's servers tests (tests.py), ported (#227): the live test server (Juango's with_live_server, Django's
# LiveServerTestCase): views, 404s, static and media files, the query string, data in the database, threaded views
# calling the server back, ports.
# julia --project=test test/django_servers.jl   (see setup.jl)
#
# The server sees committed data (on PostgreSQL and MySQL, other connections), so the people are made outside a
# rollback and deleted afterwards. Not translated: the connection-handling tests (HTTP/1.1 keep-alive, Connection:
# close, single-threaded servers: HTTP.jl's server's), the in-memory SQLite lock and setUpClass failures (Django's
# thread classes), test_basehttp and test_liveserverthread (the WSGI server's internals).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DsvModels
using Juango
@model struct Person
    name::String = CharField(max_length = 255)
    Meta(app_label = "servers", table = "servers_person")
end
end
const DsvPerson = DsvModels.Person
redirect_stdout(devnull) do
    Juango.sync_models!([DsvPerson]); append!(PORT_MODELS, [DsvPerson])
end

dsv_get(url) = Juango.HTTP.get(url; status_exception = false, retry = false)
dsv_example(req) = HttpResponse("example view")
dsv_streaming(req) = Juango.StreamingHttpResponse(["I", "am", "a", "stream"])
dsv_model_view(req) = HttpResponse(join([p.name for p in objects(DsvPerson)], "\n"))
dsv_create(req) = (save!(DsvPerson(name = "emily")); HttpResponse(""))
dsv_environ(req) = HttpResponse("QUERY_STRING: '$(req.query_string)'")
dsv_subview(req) = HttpResponse("subview")
dsv_subview_calling(req) = HttpResponse("subview calling view: " * String(dsv_get(req.GET["url"] * "/subview/").body))
function dsv_check_from_subview(req)
    dsv_get(req.GET["url"] * "/create_model_instance/")
    HttpResponse("subview calling view: " * String(dsv_get(req.GET["url"] * "/model_view/").body))
end
dsv_method(req) = HttpResponse(req.method)

@testset "django servers: LiveServerViews, LiveServerDatabase, LiveServerPort, LiveServerThreadedTests" begin
    fx = joinpath(@__DIR__, "servers_fixtures")
    urls = [path("example_view/", dsv_example), path("streaming_example_view/", dsv_streaming), path("model_view/", dsv_model_view),
            path("create_model_instance/", dsv_create), path("environ_view/", dsv_environ), path("subview_calling_view/", dsv_subview_calling),
            path("subview/", dsv_subview), path("check_model_instance_from_subview/", dsv_check_from_subview),
            path("method_view/", csrf_exempt(dsv_method))]
    jane, robert = save!(DsvPerson(name = "jane")), save!(DsvPerson(name = "robert"))       # (the fixtures, committed)
    try
        override_settings(ROOT_URLCONF = urls, DEBUG = false, MEDIA_URL = "/media/", MEDIA_ROOT = joinpath(fx, "media"),
                          STATIC_URL = "/static/", STATIC_ROOT = joinpath(fx, "static"), STATIC_DIRS = [joinpath(fx, "another_app_static")]) do
            with_live_server(static = false) do s
                # test_404 / test_view / test_static_files / test_no_collectstatic_emulation / test_media_files
                @test dsv_get(s.url * "/").status == 404
                r = dsv_get(s.url * "/example_view/")
                @test r.status == 200 && String(r.body) == "example view"
                @test rstrip(String(dsv_get(s.url * "/static/example_static_file.txt").body), ['\r', '\n']) == "example static file"
                @test dsv_get(s.url * "/static/another_app/another_app_static_file.txt").status == 404
                @test rstrip(String(dsv_get(s.url * "/media/example_media_file.txt").body), ['\r', '\n']) == "example media file"
                # test_environ: the query string as sent
                @test occursin("QUERY_STRING: 'q=%D1%82%D0%B5%D1%81%D1%82'", String(dsv_get(s.url * "/environ_view/?" * Juango.urlencode(["q" => "тест"])).body))
                # (a streaming response; a POST, twice on one connection)
                @test String(dsv_get(s.url * "/streaming_example_view/").body) == "Iamastream"
                for _ in 1:2
                    r = Juango.HTTP.post(s.url * "/method_view/", [], "{}"; status_exception = false)
                    @test r.status == 200 && String(r.body) == "POST"
                end
                # test_fixtures_loaded / test_database_writes
                @test Set(split(String(dsv_get(s.url * "/model_view/").body), "\n")) == Set(["jane", "robert"])
                dsv_get(s.url * "/create_model_instance/")
                @test [p.name for p in order_by(objects(DsvPerson), :pk)] == ["jane", "robert", "emily"]
                # test_view_calls_subview / test_check_model_instance_from_subview: the server answers while a view waits on it
                r = dsv_get(s.url * "/subview_calling_view/?" * Juango.urlencode(["url" => s.url]))
                @test String(r.body) == "subview calling view: subview"
                @test occursin("emily", String(dsv_get(s.url * "/check_model_instance_from_subview/?" * Juango.urlencode(["url" => s.url])).body))
                # test_port_bind / test_specified_port_bind
                with_live_server(static = false) do s2
                    @test s2.url != s.url
                end
                p = Juango.free_port()
                with_live_server(static = false, port = p) do s3
                    @test s3.port == p
                end
            end
            # (with static = true, the static files are found as in DEBUG: StaticLiveServerTestCase)
            with_live_server() do s
                @test dsv_get(s.url * "/static/another_app/another_app_static_file.txt").status == 200
            end
        end
    finally
        delete!(objects(DsvPerson))
    end
end
