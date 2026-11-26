# Django's sites_tests, sites_framework and redirects_tests, ported (#227).
# julia --project=test test/django_sites.jl   (see setup.jl)
#
# Not translated: the "other" database and router cases of CreateDefaultSiteTests (Juango's multi-database
# tests are in db.jl), test_unavailable_site_model (Django's app registry), and clear_site_cache's `using`.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dsite_req(meta...) = Request("GET", "/"; headers = Dict(meta...))
dsite_out(f) = mktemp() do path, io                     # (redirect_stdout needs a file, not an IOBuffer)
    redirect_stdout(f, io); close(io); read(path, String)
end

# sites_framework's models: an article on one site, on several, through a field of another name
@model struct DsfExclusiveArticle
    title = CharField(max_length = 50)
    site = ForeignKey(Site; on_delete = :CASCADE)
    Meta(table = "dsf_exclusivearticle")
end
@model struct DsfSyndicatedArticle
    title = CharField(max_length = 50)
    sites = ManyToManyField(Site)
    Meta(table = "dsf_syndicatedarticle")
end
@model struct DsfCustomArticle
    title = CharField(max_length = 50)
    places_this_article_should_appear = ForeignKey(Site; on_delete = :CASCADE)
    Meta(table = "dsf_customarticle")
end
@model struct DsfConfusedArticle
    title = CharField(max_length = 50)
    site = IntegerField()
    Meta(table = "dsf_confusedarticle")
end
Juango.manager(::Type{DsfExclusiveArticle}, ::Val{:on_site}) = CurrentSiteManager(DsfExclusiveArticle)
Juango.manager(::Type{DsfSyndicatedArticle}, ::Val{:on_site}) = CurrentSiteManager(DsfSyndicatedArticle)
Juango.manager(::Type{DsfCustomArticle}, ::Val{:on_site}) = CurrentSiteManager(DsfCustomArticle; field = :places_this_article_should_appear)

@testset "django sites_tests and redirects_tests" begin
    old_apps, old_mw, old_slash, old_urls = settings.INSTALLED_APPS, settings.MIDDLEWARE, settings.APPEND_SLASH, settings.ROOT_URLCONF
    configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.sites", "juango.redirects"]))
    redirect_stdout(() -> migrate(verbose = false), devnull)
    reset() = (delete!(objects(Redirect)); delete!(objects(Site)); clear_site_cache!();
               save!(Site(; id = settings.SITE_ID, domain = "example.com", name = "example.com")))
    try
        @testset "SitesFrameworkTests" begin
            reset()
            # test_site_manager
            s = get_current_site()
            @test s isa Site
            delete!(s)
            @test_throws Juango.DoesNotExist get_current_site()
            # test_site_cache
            reset()
            @test get_current_site().name == "example.com"
            s2 = get(Site; id = settings.SITE_ID)
            s2.name = "Example site"; save!(s2)
            @test get_current_site().name == "Example site"
            # test_delete_all_sites_clears_cache
            @test get_current_site() isa Site
            delete!(objects(Site))
            @test_throws Juango.DoesNotExist get_current_site()
            # test_get_current_site
            reset()
            override_settings(ALLOWED_HOSTS = ["example.com"]) do
                req = dsite_req("host" => "example.com")
                site = get_current_site(req)
                @test site isa Site && site.id == settings.SITE_ID
                delete!(site)
                @test_throws Juango.DoesNotExist get_current_site(req)
                override_settings(INSTALLED_APPS = Juango.default_installed_apps()) do
                    site = get_current_site(req)
                    @test site isa RequestSite && site.name == "example.com"
                end
            end
            # test_get_current_site_no_site_id / test_get_current_site_host_with_trailing_dot
            reset()
            override_settings(SITE_ID = nothing, ALLOWED_HOSTS = ["example.com"]) do
                @test get_current_site(dsite_req("host" => "example.com")).name == "example.com"
                @test get_current_site(dsite_req("host" => "example.com.")).name == "example.com"
            end
            # test_get_current_site_no_site_id_and_handle_port_fallback
            reset()
            override_settings(SITE_ID = nothing, ALLOWED_HOSTS = ["example.com", "example.net"]) do
                s1 = get(Site; domain = "example.com")
                s2 = create(Site; domain = "example.com:80", name = "example.com:80")
                @test get_current_site(dsite_req("host" => "example.com")).pk == s1.pk
                @test get_current_site(dsite_req("host" => "example.com:80")).pk == s2.pk
                @test get_current_site(dsite_req("host" => "example.com:81")).pk == s1.pk
                @test_throws Juango.DoesNotExist get_current_site(dsite_req("host" => "example.net"))
                override_settings(INSTALLED_APPS = Juango.default_installed_apps()) do
                    @test get_current_site(dsite_req("host" => "example.com")).name == "example.com"
                    @test get_current_site(dsite_req("host" => "example.com:80")).name == "example.com:80"
                end
            end
            # test_domain_name_with_whitespaces
            for d in ("test test", "test\ttest", "test\ntest")
                @test get(full_clean(Site(; name = "test name", domain = d); validate_unique = false), :domain, String[]) ==
                      ["The domain name cannot contain any spaces or tabs."]          # (Juango's full_clean returns the errors)
            end
            # test_clear_site_cache / test_clear_site_cache_domain (what the cache gives, not its contents)
            reset()
            override_settings(ALLOWED_HOSTS = ["example.com"]) do
                req = dsite_req("host" => "example.com")
                a = get_current_site(req)
                @test get_current_site(req) === a                    # cached
                clear_site_cache!()
                @test get_current_site(req) !== a && get_current_site(req).pk == a.pk
            end
            # test_unique_domain
            reset()
            @test validate_unique(Site(; domain = "example.com"))[:domain] == ["Site with this Domain name already exists."]
            # test_site_natural_key
            site = get(Site; domain = "example.com")
            @test Juango.get_by_natural_key(Site, "example.com").pk == site.pk
            @test Juango.natural_key(site) == ("example.com",)
            # test_check_site_id_incorrect_type / test_check_site_id_failed_to_validate / test_valid_site_id
            override_settings(SITE_ID = "1") do
                m = Juango.check_site_id()
                @test length(m) == 1 && m[1].msg == "The SITE_ID setting must be of type int." && m[1].id == "sites.E101"
            end
            override_settings(SITE_ID = "x") do
                m = Juango.check_site_id()
                @test length(m) == 1 && m[1].msg == "The SITE_ID setting failed to validate: ['“x” value must be an integer.']." &&
                      m[1].id == "sites.E101"
            end
            for id in (1, nothing)
                override_settings(SITE_ID = id) do
                    @test isempty(Juango.check_site_id())
                end
            end
        end

        @testset "RequestSiteTests" begin
            override_settings(ALLOWED_HOSTS = ["example.com"]) do
                site = RequestSite(dsite_req("host" => "example.com"))
                @test site.domain == "example.com" && site.name == "example.com"      # test_init_attributes
                @test string(site) == "example.com"                                   # test_str
                @test_throws "RequestSite cannot be saved." save!(site)               # test_save
                @test_throws "RequestSite cannot be deleted." delete!(site)           # test_delete
            end
        end

        @testset "CreateDefaultSiteTests" begin
            delete!(objects(Site)); clear_site_cache!()
            # test_basic
            out = dsite_out(() -> Juango.create_default_site!())
            @test count(objects(Site)) == 1 && occursin("Creating example.com", out)
            out = dsite_out(() -> Juango.create_default_site!())
            @test count(objects(Site)) == 1 && out == ""
            # test_save_another
            delete!(objects(Site))
            Juango.create_default_site!(; verbosity = 0)
            save!(Site(; domain = "example2.com", name = "example2.com"))
            @test count(objects(Site)) == 2
            # test_signal: post_migrate creates it
            delete!(objects(Site))
            redirect_stdout(() -> migrate(verbose = false), devnull)
            @test exists(objects(Site))
            # test_custom_site_id / test_no_site_id
            delete!(objects(Site))
            override_settings(SITE_ID = 35696) do
                Juango.create_default_site!(; verbosity = 0)
                @test only(collect(objects(Site))).pk == 35696
            end
            delete!(objects(Site))
            override_settings(SITE_ID = nothing) do
                Juango.create_default_site!(; verbosity = 0)
                @test only(collect(objects(Site))).pk == 1
            end
        end

        @testset "MiddlewareTest" begin
            reset()
            resp = Juango.CurrentSiteMiddleware(req -> HttpResponse(string(req.site.id)))(dsite_req("host" => "testserver"))
            @test text(resp) == string(settings.SITE_ID)                               # test_request
        end

        @testset "RedirectTests" begin
            reset()
            site = get(Site; pk = settings.SITE_ID)
            configure!(MIDDLEWARE = vcat(old_mw, [RedirectFallbackMiddleware]), APPEND_SLASH = false,
                       ROOT_URLCONF = Any[path("", req -> HttpResponse("home"))])
            # test_model
            @test string(create(Redirect; site, old_path = "/initial", new_path = "/new_target")) == "/initial ---> /new_target"
            # test_redirect
            assert_redirects(get(Client(), "/initial"), "/new_target"; status_code = 301, target_status_code = 404)
            # test_redirect_with_append_slash / ..._and_query_string / test_redirect_not_found_with_append_slash
            delete!(objects(Redirect))
            configure!(APPEND_SLASH = true)
            create(Redirect; site, old_path = "/initial/", new_path = "/new_target/")
            assert_redirects(get(Client(), "/initial"), "/new_target/"; status_code = 301, target_status_code = 404)
            delete!(objects(Redirect))
            create(Redirect; site, old_path = "/initial/?foo", new_path = "/new_target/")
            assert_redirects(get(Client(), "/initial?foo"), "/new_target/"; status_code = 301, target_status_code = 404)
            @test get(Client(), "/test").status == 404
            configure!(APPEND_SLASH = false)
            # test_redirect_shortcircuits_non_404_response
            @test get(Client(), "/").status == 200
            # test_response_gone
            delete!(objects(Redirect))
            create(Redirect; site, old_path = "/initial", new_path = "")
            @test get(Client(), "/initial").status == 410
            # test_sites_not_installed
            override_settings(INSTALLED_APPS = Juango.default_installed_apps()) do
                @test_throws "You cannot use RedirectFallbackMiddleware when juango.sites is not installed." RedirectFallbackMiddleware(req -> HttpResponse(""))
            end
        end

        @testset "OverriddenRedirectMiddlewareTests" begin
            reset()
            site = get(Site; pk = settings.SITE_ID)
            mw = gr -> RedirectFallbackMiddleware(gr; response_gone_class = HttpResponseForbidden, response_redirect_class = HttpResponseRedirect)
            configure!(MIDDLEWARE = vcat(old_mw, [mw]), APPEND_SLASH = false, ROOT_URLCONF = Any[path("", req -> HttpResponse("home"))])
            create(Redirect; site, old_path = "/initial/", new_path = "")
            @test get(Client(), "/initial/").status == 403                            # test_response_gone_class
            delete!(objects(Redirect))
            create(Redirect; site, old_path = "/initial/", new_path = "/new_target/")
            @test get(Client(), "/initial/").status == 302                            # test_response_redirect_class
        end
        @testset "sites_framework" begin
            reset()
            ms = [DsfExclusiveArticle, DsfSyndicatedArticle, DsfCustomArticle, DsfConfusedArticle]
            redirect_stdout(() -> (Juango.sync_models!(ms); append!(PORT_MODELS, ms)), devnull)
            site1 = get(Site; id = settings.SITE_ID)
            site2 = create(Site; domain = "example2.com", name = "example2.com")
            # test_site_fk
            a = create(DsfExclusiveArticle; title = "Breaking News!", site = site1)
            create(DsfExclusiveArticle; title = "Elsewhere", site = site2)
            @test get(objects(DsfExclusiveArticle, :on_site)).id == a.id
            # test_sites_m2m
            a = create(DsfSyndicatedArticle; title = "Fresh News!")
            add!(a.sites, site1); add!(a.sites, site2)
            a2 = create(DsfSyndicatedArticle; title = "More News!")
            add!(a2.sites, site2)
            @test get(objects(DsfSyndicatedArticle, :on_site)).id == a.id
            # test_custom_named_field
            a = create(DsfCustomArticle; title = "Tantalizing News!", places_this_article_should_appear_id = site1.id)
            @test get(objects(DsfCustomArticle, :on_site)).id == a.id
            # CurrentSiteManagerChecksTests: test_invalid_name, test_invalid_field_type
            e = only(check_current_site_manager(DsfCustomArticle; field = :places))
            @test e.id == "sites.E001" && e.msg == "CurrentSiteManager could not find a field named 'places'."
            e = only(check_current_site_manager(DsfConfusedArticle))
            @test e.id == "sites.E002" && e.msg == "CurrentSiteManager cannot use 'DsfConfusedArticle.site' as it is not a foreign key or a many-to-many field."
            @test_throws Juango.ImproperlyConfigured CurrentSiteManager(DsfConfusedArticle)
            @test isempty(check_current_site_manager(DsfSyndicatedArticle))
            foreach(m -> delete!(objects(m)), ms)
        end
    finally
        delete!(objects(Redirect)); delete!(objects(Site)); clear_site_cache!()
        configure!(INSTALLED_APPS = old_apps, MIDDLEWARE = old_mw, APPEND_SLASH = old_slash, ROOT_URLCONF = old_urls)
    end
end
