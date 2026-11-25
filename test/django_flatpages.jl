# Django's flatpages tests, ported (#227): tests/flatpages_tests (FlatpageViewTests and its APPEND_SLASH
# variant, FlatpageMiddlewareTests, FlatpageAdminFormTests' URL rules, FlatpageModelTests,
# FlatpageTemplateTagTests' syntax errors, FlatPagesSitemapTests).
# julia --project=test test/django_flatpages.jl   (see setup.jl; runs after views.jl, which checks that
# the flatpages table only appears once the app is installed)
#
# Juango's flat pages have no `sites` (Django's FlatPage.sites: #270). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django flatpages" begin
    old_apps, old_mw, old_urls, old_slash = settings.INSTALLED_APPS, settings.MIDDLEWARE, settings.ROOT_URLCONF, settings.APPEND_SLASH
    mkpath(joinpath(TPL, "flatpages"))
    write(joinpath(TPL, "flatpages", "default.html"), "<title>{{ flatpage.title }}</title>{{ flatpage.content }}")
    configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), ["juango.flatpages"]),
               ROOT_URLCONF = vcat(old_urls, [path("flatpage_root/", flatpage_urls()),
                                              path("dfp_sitemap/", include_urls(sitemap_urls(Dict("flatpages" => flatpage_sitemap()))))]))
    migrate(verbose = false)
    user = create_user("dfpuser", "dfp-password-1")
    try
        create(FlatPage; url = "/flatpage/", title = "A Flatpage", content = "<p>Isn't it flat!</p>")
        create(FlatPage; url = "/location/flatpage/", title = "A Nested Flatpage", content = "<p>Isn't it flat and deep!</p>")
        create(FlatPage; url = "/sekrit/", title = "Sekrit Flatpage", content = "<p>Isn't it sekrit!</p>", registration_required = true)
        create(FlatPage; url = "/location/sekrit/", title = "Sekrit Nested Flatpage", content = "<p>Isn't it sekrit and deep!</p>", registration_required = true)
        create(FlatPage; url = "/some.very_special~chars-here/", title = "A very special page", content = "<p>Isn't it special!</p>")

        @testset "FlatpageViewTests" begin
            configure!(MIDDLEWARE = old_mw, APPEND_SLASH = false)
            c = Client()
            r = get(c, "/flatpage_root/flatpage/")                                        # test_view_flatpage
            @test r.status == 200 && occursin("<p>Isn't it flat!</p>", text(r))
            @test get(c, "/flatpage_root/no_such_flatpage/").status == 404                # test_view_non_existent_flatpage
            r = get(c, "/flatpage_root/sekrit/")                                          # test_view_authenticated_flatpage
            @test r.status == 302 && getheader(r, "Location") == settings.LOGIN_URL * "?next=/flatpage_root/sekrit/"
            force_login!(c, user)
            @test occursin("<p>Isn't it sekrit!</p>", text(get(c, "/flatpage_root/sekrit/")))
            @test get(Client(), "/flatpage/").status == 404                               # test_fallback_flatpage (no middleware)
            @test get(Client(), "/no_such_flatpage/").status == 404                       # test_fallback_non_existent_flatpage
            r = get(Client(), "/flatpage_root/some.very_special~chars-here/")             # test_view_flatpage_special_chars
            @test r.status == 200 && occursin("<p>Isn't it special!</p>", text(r))
            @test get(Client(), "/flatpage_root/flatpage").status == 404                  # (no APPEND_SLASH: no redirect)
        end

        @testset "FlatpageViewAppendSlashTests" begin
            configure!(MIDDLEWARE = old_mw, APPEND_SLASH = true)
            r = get(Client(), "/flatpage_root/flatpage")                                  # test_redirect_view_flatpage
            @test r.status == 301 && getheader(r, "Location") == "/flatpage_root/flatpage/"
            @test get(Client(), "/flatpage_root/no_such_flatpage").status == 404          # test_redirect_view_non_existent_flatpage
            r = get(Client(), "/flatpage_root/some.very_special~chars-here")              # test_redirect_view_flatpage_special_chars
            @test r.status == 301 && getheader(r, "Location") == "/flatpage_root/some.very_special~chars-here/"
        end

        @testset "FlatpageMiddlewareTests" begin
            configure!(MIDDLEWARE = vcat(old_mw, [FlatpageFallbackMiddleware]), APPEND_SLASH = false)
            r = get(Client(), "/flatpage/")                                               # test_fallback_flatpage
            @test r.status == 200 && occursin("<p>Isn't it flat!</p>", text(r))
            @test get(Client(), "/no_such_flatpage/").status == 404                       # test_fallback_non_existent_flatpage
            c = Client()                                                                  # test_fallback_authenticated_flatpage
            r = get(c, "/sekrit/")
            @test r.status == 302 && getheader(r, "Location") == settings.LOGIN_URL * "?next=/sekrit/"
            force_login!(c, user)
            @test occursin("<p>Isn't it sekrit!</p>", text(get(c, "/sekrit/")))
            r = get(Client(), "/location/flatpage/")                                      # (nested)
            @test occursin("<p>Isn't it flat and deep!</p>", text(r))
            r = get(Client(), "/some.very_special~chars-here/")                           # test_fallback_flatpage_special_chars
            @test r.status == 200 && occursin("<p>Isn't it special!</p>", text(r))
            configure!(APPEND_SLASH = true)                                               # FlatpageMiddlewareAppendSlashTests
            r = get(Client(), "/flatpage")                                                # test_redirect_fallback_flatpage
            @test r.status == 301 && getheader(r, "Location") == "/flatpage/"
            @test get(Client(), "/no_such_flatpage").status == 404                        # test_redirect_fallback_non_existent_flatpage
            create(FlatPage; url = "/", title = "Root", content = "Root")                 # test_redirect_fallback_flatpage_root
            @test text(get(Client(), "/")) != "" && get(Client(), "/").status == 200
        end

        @testset "FlatpageAdminFormTests (URL rules)" begin
            configure!(MIDDLEWARE = old_mw, APPEND_SLASH = true)
            errs(url) = get(Juango.full_clean(FlatPage(url = url, title = "A test page", content = "content"); validate_unique = false), :url, String[])
            for url in ("/new_flatpage/", "/some.special~chars/", "/some.very_special~chars-here/")   # test_flatpage_admin_form_url_validation
                @test isempty(errs(url))
            end
            for url in ("/a space/", "/a % char/", "/a ! char/", "/a & char/", "/a ? char/")
                @test errs(url) == ["This value must contain only letters, numbers, dots, underscores, dashes, slashes or tildes."]
            end
            @test errs("no_leading_slash/") == ["URL is missing a leading slash."]          # test_flatpage_requires_leading_slash
            @test errs("/no_trailing_slash") == ["URL is missing a trailing slash."]       # test_flatpage_requires_trailing_slash_with_append_slash
            configure!(APPEND_SLASH = false)                                              # test_flatpage_doesnt_requires_trailing_slash_without_append_slash
            @test isempty(errs("/no_trailing_slash"))
            configure!(APPEND_SLASH = true, MIDDLEWARE = filter(m -> m !== Juango.CommonMiddleware, old_mw))   # (no CommonMiddleware: no slash added, none required)
            @test isempty(errs("/no_trailing_slash"))
        end

        @testset "FlatpageModelTests" begin
            configure!(MIDDLEWARE = old_mw)
            pg = FlatPage(title = "Café!", url = "/café/")
            @test string(pg) == "/café/ -- Café!"                                         # test_str
            @test get_absolute_url(pg) == "/flatpage_root/caf%C3%A9/"                     # test_get_absolute_url_include (and urlencodes)
            configure!(ROOT_URLCONF = old_urls)
            @test get_absolute_url(pg) == "/caf%C3%A9/"                                   # test_get_absolute_url_urlencodes (not routed)
            configure!(ROOT_URLCONF = vcat(old_urls, [path("flatpage_root/", flatpage_urls()),
                                                      path("dfp_sitemap/", include_urls(sitemap_urls(Dict("flatpages" => flatpage_sitemap()))))]))
        end

        @testset "FlatpageTemplateTagTests (syntax)" begin
            for bad in ("{% get_flatpages as %}", "{% get_flatpages cheesecake flatpages %}", "{% get_flatpages as flatpages asdf %}",   # test_parsing_errors
                        "{% get_flatpages cheesecake user as flatpages %}", "{% get_flatpages for user as flatpages asdf %}",
                        "{% get_flatpages prefix for user as flatpages asdf %}")
                @test_throws TemplateSyntaxError Template("{% load flatpages %}" * bad)
            end
            t = Template("{% load flatpages %}{% get_flatpages '/location/' as location_flatpages %}{% for page in location_flatpages %}{{ page.title }},{% endfor %}")
            @test render(t, Dict{String,Any}()) == "A Nested Flatpage,"                   # test_get_flatpages_with_prefix
            t = Template("{% load flatpages %}{% get_flatpages '/location/' for me as fps %}{% for page in fps %}{{ page.title }},{% endfor %}")
            @test render(t, Dict{String,Any}("me" => user)) == "A Nested Flatpage,Sekrit Nested Flatpage,"   # test_get_flatpages_with_prefix_for_user
            t = Template("{% load flatpages %}{% get_flatpages location_prefix as fps %}{% for page in fps %}{{ page.title }},{% endfor %}")
            @test render(t, Dict{String,Any}("location_prefix" => "/location/")) == "A Nested Flatpage,"   # test_get_flatpages_with_variable_prefix
        end

        @testset "FlatPagesSitemapTests" begin
            create(FlatPage; url = "/foo/", title = "foo")                                # test_flatpage_sitemap
            create(FlatPage; url = "/private-foo/", title = "private foo", registration_required = true)
            x = text(get(Client(), "/dfp_sitemap/sitemap.xml"))
            @test occursin("<url><loc>http://testserver/flatpage_root/foo/</loc></url>", x)
            @test !occursin("private-foo", x)
        end
    finally
        configure!(INSTALLED_APPS = old_apps, MIDDLEWARE = old_mw, ROOT_URLCONF = old_urls, APPEND_SLASH = old_slash)
        Admin.is_registered(FlatPage) && Admin.unregister!(FlatPage)
        Juango.execute("DELETE FROM " * Juango.qname("juango_flatpage"))
    end
    # not translated: FlatPage.sites and the per-site lookups (#270), the CSRF tests (the view is a plain
    # view in Juango too); the script prefix is in django_script_prefix.jl
end
