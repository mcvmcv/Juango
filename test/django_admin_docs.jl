# Django's admin_docs tests, ported (#227): tests/admin_docs (test_views, test_middleware). Juango's admin
# documentation reads Julia docstrings (Markdown), not reStructuredText: the docutils, rST role and directive tests,
# and the model method tables (Julia models have no methods of their own), aren't translated. Its model URLs are
# `models/app.model/`; its view names are `Module.name`.
# julia --project=test test/django_admin_docs.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

"Stores information about a company."
@model struct DadCompany
    name = CharField(max_length = 200)
    Meta(table = "dad_company")
end
@model struct DadGroup
    name = CharField(max_length = 200)
    Meta(table = "dad_group")
end
@model struct DadFamily
    last_name = CharField(max_length = 200)
    Meta(table = "dad_family")
end
@model struct DadPerson
    first_name = CharField(max_length = 200, help_text = "The person's first name")
    last_name = CharField(max_length = 200, help_text = "The person's last name")
    company = ForeignKey(DadCompany; on_delete = :CASCADE, help_text = "place of work")
    family = ForeignKey(DadFamily; on_delete = :SET_NULL, related_name = "+", null = true)
    groups = ManyToManyField(DadGroup; help_text = "has membership")
    Meta(table = "dad_person")
end
redirect_stdout(devnull) do
    ms = [DadCompany, DadGroup, DadFamily, DadPerson]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

"Base view for the xview tests."
dad_xview(req) = HttpResponse("xview")
struct DadXViewCallable end
(::DadXViewCallable)(req; kw...) = HttpResponse("callable")

@testset "django admin_docs" begin
    old_apps, old_urls, old_mw = settings.INSTALLED_APPS, settings.ROOT_URLCONF, settings.MIDDLEWARE
    port_block() do
        try
            configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.admindocs"]),
                       ROOT_URLCONF = vcat([path("admindocs/", admindocs_urls()), path("xview/func/", dad_xview),
                                            path("xview/callable_object/", DadXViewCallable()), path("admin/", Admin.urls())]),
                       MIDDLEWARE = vcat(settings.MIDDLEWARE, [XViewMiddleware]))
            Juango.update_contenttypes!(); Juango.update_permissions!()
            su = create_superuser("dad_super", "secret"); c = Client(); force_login!(c, get(User; id = su.id))
            @testset "AdminDocViewTests" begin
                r = get(c, "/admindocs/")                                                    # test_index
                @test r.status == 200 && occursin("Documentation", text(r))
                @test getheader(get(Client(), "/admindocs/"), "Location") |> l -> occursin("next=/admindocs/", l)
                @test occursin("/admindocs/views/", text(get(c, "/admindocs/bookmarklets/")))   # test_bookmarklets
                @test occursin("id=\"extends\"", text(get(c, "/admindocs/tags/")))              # test_templatetag_index
                @test occursin("id=\"first\"", text(get(c, "/admindocs/filters/")))             # test_templatefilter_index
                t = text(get(c, "/admindocs/views/"))                                        # test_view_index
                @test occursin("<a href=\"/admindocs/views/Main.dad_xview/\">dad_xview</a>", t)
                @test occursin("/admindocs/views/Main.DadXViewCallable/", t)
                r = get(c, "/admindocs/views/Main.dad_xview/")                               # test_view_detail
                @test r.status == 200 && occursin("Base view for the xview tests.", text(r)) && occursin("<h1 class=\"page\">Main.dad_xview</h1>", text(r))
                @test get(c, "/admindocs/views/Main.nonexistent_view/").status == 404         # test_view_detail_illegal_import
                @test get(c, "/admindocs/views/Base.println/").status == 404                  # (a function that isn't a view)
                t = text(get(c, "/admindocs/models/"))                                       # test_model_index
                @test occursin("<a href=\"/admindocs/models/project.dadperson/\">DadPerson</a>", t)
                r = get(c, "/admindocs/templates/admin_doc/template_detail.html/")           # test_template_detail
                @test r.status == 200 && occursin("Template: <q>admin_doc/template_detail.html</q>", text(r))
                @test occursin("{% extends", text(r))                                        # (its source, escaped by nothing but HTML)
                for p in ("/etc/passwd", "../passwd")                                       # test_template_detail_path_traversal
                    @test get(c, "/admindocs/templates/$p/").status == 400
                end
            end
            @testset "TestModelDetailView" begin
                t = text(get(c, "/admindocs/models/project.dadperson/"))
                @test occursin("<h1 class=\"page\">project.DadPerson</h1>", t)                 # test_model_detail_title
                @test occursin(r"The person(&#39;|&#x27;|')s first name", t)                                 # test_descriptions_render_correctly
                link(m) = "<a class=\"reference external\" href=\"/admindocs/models/project.$(lowercase(m))/\">project.$m</a>"
                @test occursin("the related $(link("DadCompany")) object", t) && occursin("place of work", t)
                @test occursin("all related $(link("DadGroup")) objects", t)
                t = text(get(c, "/admindocs/models/project.dadcompany/"))                     # test_model_with_many_to_one
                @test occursin("number of related $(link("DadPerson")) objects", t) && occursin("all related $(link("DadPerson")) objects", t)
                @test occursin("Stores information about a company.", t)                     # (the model's docstring)
                # test_model_with_no_backward_relations_render_only_relevant_fields (related_name = "+": nothing on DadFamily)
                @test !occursin("DadPerson", text(get(c, "/admindocs/models/project.dadfamily/")))
                r = get(c, "/admindocs/models/doesnotexist.person/")                        # test_app_not_found
                @test r.status == 404
                r = get(c, "/admindocs/models/project.doesnotexist/")                       # test_model_not_found
                @test r.status == 404
                # test_model_permission_denied, TestModelIndexView.test_model_index_with_model_permission
                staff = create_user("dad_staff", "secret"; is_staff = true); sc = Client(); force_login!(sc, get(User; id = staff.id))
                @test get(sc, "/admindocs/models/project.dadperson/").status == 403 && get(sc, "/admindocs/models/project.dadcompany/").status == 403
                @test !occursin("project.dadperson/", text(get(sc, "/admindocs/models/")))
                add!(staff.user_permissions, get(Juango.Permission; codename = "view_dadcompany"), get(Juango.Permission; codename = "change_dadperson"))
                sc = Client(); force_login!(sc, get(User; id = staff.id))
                @test get(sc, "/admindocs/models/project.dadperson/").status == 200 && get(sc, "/admindocs/models/project.dadcompany/").status == 200
                t = text(get(sc, "/admindocs/models/"))
                @test occursin("project.dadperson/", t) && occursin("project.dadcompany/", t) && !occursin("project.dadfamily/", t)
            end
            @testset "XViewMiddlewareTest" begin
                # test_xview_func, test_callable_object_view
                @test !hasheader(head(Client(), "/xview/func/"), "X-View")
                @test getheader(head(c, "/xview/func/"), "X-View") == "Main.dad_xview"
                @test getheader(head(c, "/xview/callable_object/"), "X-View") == "Main.DadXViewCallable"
                @test !hasheader(get(c, "/xview/func/"), "X-View")                        # (HEAD only)
                u = get(User; id = su.id); u.is_staff = false; save!(u)
                @test !hasheader(head(c, "/xview/func/"), "X-View")
                u.is_staff = true; u.is_active = false; save!(u)
                @test !hasheader(head(Client(), "/xview/func/"), "X-View")
                u.is_active = true; save!(u)
                # (an INTERNAL_IPS address needs no login)
                override_settings(INTERNAL_IPS = ["127.0.0.1"]) do
                    @test getheader(head(Client(), "/xview/func/"), "X-View") == "Main.dad_xview"
                end
                # test_no_auth_middleware
                configure!(MIDDLEWARE = [XViewMiddleware])
                @test_throws "The XView middleware requires authentication middleware" head(Client(; raise_request_exception = true), "/xview/func/")
            end
        finally
            configure!(INSTALLED_APPS = old_apps, ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw)
        end
    end
    # not translated: docutils and reStructuredText (roles, directives, the missing-docutils page), model methods and
    # properties, multiple template engines, test_namespaced_view_detail, TestFieldType (get_readable_field_data_type),
    # the bookmarklet's JavaScript (Playwright)
end
