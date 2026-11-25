# Django's shortcuts tests, ported (#227): tests/shortcuts, tests/get_object_or_404 and tests/resolve_url.
# julia --project=test test/django_shortcuts.jl   (see setup.jl)
#
# Python's ValueError is an ArgumentError. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DsAuthor
    name = CharField(max_length = 50)
    Meta(table = "ds_author", ordering = ["name"])
end
@model struct DsArticle
    authors = ManyToManyField(DsAuthor; related_name = :articles)
    title = CharField(max_length = 50)
    Meta(table = "ds_article", ordering = ["title"])
end
Juango.get_absolute_url(a::DsArticle) = "/articles/$(a.id)/"
struct DsCustomClass end
redirect_stdout(devnull) do
    ms = [DsAuthor, DsArticle, through(DsArticle, :authors)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
write(joinpath(TPL, "ds_render.html"), "FOO.{{ foo }}")
ds_view(req) = HttpResponse("view")
ds_params_view(req; slug) = HttpResponse("")
const DS_SOME_CBV = TemplateView("ds_render.html")
const DS_PARAMS_CBV = TemplateView("ds_render.html")

@testset "django shortcuts, get_object_or_404, resolve_url" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [path("articles/<int:id>/", ds_view; name = "ds_article"), path("some-view/", ds_view; name = "ds_some_view"),
                               path("params/<slug:slug>/", ds_params_view; name = "params-view"), path("params-cbv/<int:pk>/", DS_PARAMS_CBV; name = "params-cbv"),
                               path("some-cbv/", DS_SOME_CBV; name = "some-cbv")])
    try
        port_block() do
            # --- tests/shortcuts: render
            req = get(RequestFactory(), "/")
            r = render(req, "ds_render.html", Dict("foo" => "FOO"))                         # test_render
            @test text(r) == "FOO.FOO" && getheader(r, "Content-Type") == "text/html; charset=utf-8" && r.status == 200
            r = render(req, "ds_render.html", Dict("foo" => "FOO"); content_type = "application/x-rendertest")   # test_render_with_content_type
            @test getheader(r, "Content-Type") == "application/x-rendertest"
            @test render(req, "ds_render.html"; status = 403).status == 403                 # test_render_with_status
            @test text(render(req, ["ds_missing.html", "ds_render.html"], Dict("foo" => 1))) == "FOO.1"   # (the first that exists)

            # --- redirect (tests/shortcuts test_redirect_*, Django 5.2's preserve_request)
            r = redirect("/some-url/")
            @test r.status == 302 && getheader(r, "Location") == "/some-url/"
            @test redirect("/some-url/"; permanent = true).status == 301
            @test redirect("/some-url/"; preserve_request = true).status == 307               # test_redirect_preserve_request
            @test redirect("/some-url/"; permanent = true, preserve_request = true).status == 308
            @test getheader(redirect("ds_article"; id = 3), "Location") == "/articles/3/"

            # --- tests/resolve_url
            @test resolve_url("/something/") == "/something/"                                # test_url_path
            @test resolve_url("../") == "../" && resolve_url("./") == "./"                   # test_relative_path
            @test resolve_url("../relative/") == "../relative/" && resolve_url("./relative/") == "./relative/"
            @test resolve_url("https://www.example.com/") == "https://www.example.com/"     # test_full_url
            @test resolve_url("example.com") == "example.com"                                 # test_domain (it looks like one)
            @test resolve_url("ds_some_view") == "/some-view/"                                # test_valid_view_name
            @test resolve_url("ds_article", 7) == "/articles/7/"
            @test_throws Juango.NoReverseMatch resolve_url("ds_not_a_view")                   # test_view_name (a name that doesn't reverse)
            @test_throws Juango.NoReverseMatch redirect("ds_not_a_view")                      # (not a redirect to the misspelled name)
            @test resolve_url(ds_view) == "/some-view/"                                       # test_view_function (the mount its arguments fit)
            @test resolve_url(ds_params_view; slug = "django") == "/params/django/"           # test_view_function_with_kwargs
            @test resolve_url(ds_params_view, "django") == "/params/django/"                  # test_view_function_with_args
            @test resolve_url(DS_SOME_CBV) == "/some-cbv/"                                    # test_class_based_view (a generic view)
            @test resolve_url(DS_PARAMS_CBV; pk = 5) == "/params-cbv/5/" && resolve_url(DS_PARAMS_CBV, 5) == "/params-cbv/5/"
            @test_throws Juango.NoReverseMatch resolve_url(ds_params_view)                    # test_missing_params_raise_no_reverse_match
            @test_throws Juango.NoReverseMatch resolve_url(DS_PARAMS_CBV)
            @test resolve_url(reverse_lazy("ds_some_view")) === "/some-view/"                 # test_lazy_reverse (a String)
            @test_throws Juango.NoReverseMatch resolve_url(() -> "asdf")                      # test_non_view_callable_raises_no_reverse_match
            a1 = create(DsAuthor; name = "Brave Sir Robin"); a2 = create(DsAuthor; name = "Patsy")
            # --- tests/get_object_or_404
            @test_throws Http404 get_object_or_404(DsArticle; title = "Foo")                  # test_get_object_or_404
            art = create(DsArticle; title = "Run away!")
            set!(art.authors, [a1, a2])
            @test resolve_url(art) == "/articles/$(art.id)/"                                  # test_model (resolve_url)
            @test getheader(redirect(art), "Location") == "/articles/$(art.id)/"
            @test get_object_or_404(DsArticle; title__contains = "Run").id == art.id
            @test get_object_or_404(a1.articles; title__contains = "Run").id == art.id        # (through a related manager)
            @test_throws Http404 get_object_or_404(a1.articles; title__contains = "Camelot")
            @test get_object_or_404(filter(objects(DsArticle); title__startswith = "Run"); title = "Run away!").id == art.id   # (a custom manager's queryset)
            @test get_object_or_404(objects(DsArticle); title__contains = "Run").id == art.id
            @test_throws Juango.MultipleObjectsReturned get_object_or_404(objects(DsAuthor))
            @test_throws Http404 get_object_or_404(none(objects(DsArticle)); title__contains = "Run")
            e = try get_object_or_404(DsArticle; title = "Foo") catch e; e end
            @test e.msg == "No DsArticle matches the given query."
            @test [x.id for x in get_list_or_404(a1.articles; title__icontains = "Run")] == [art.id]
            @test_throws Http404 get_list_or_404(a1.articles; title__icontains = "Shrubbery")
            @test [x.id for x in get_list_or_404(objects(DsArticle); title__icontains = "Run")] == [art.id]
            @test [x.id for x in get_list_or_404(DsArticle; title__icontains = "Run")] == [art.id]
            e = try get_object_or_404("DsArticle"; title__icontains = "Run") catch e; e end   # test_bad_class
            @test e isa ArgumentError && e.msg == "First argument to get_object_or_404() must be a Model, Manager, or QuerySet, not 'String'."
            e = try get_object_or_404(DsCustomClass; title__icontains = "Run") catch e; e end
            @test e isa ArgumentError && e.msg == "First argument to get_object_or_404() must be a Model, Manager, or QuerySet, not 'DsCustomClass'."
            e = try get_list_or_404([DsArticle]; title__icontains = "Run") catch e; e end
            @test e isa ArgumentError && e.msg == "First argument to get_list_or_404() must be a Model, Manager, or QuerySet, not 'Array'."
            # not translated: render's `using` (Juango has one template engine per project) and querysets' AttributeError
        end
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end
