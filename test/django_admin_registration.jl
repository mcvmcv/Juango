# Django's admin_registration tests, ported (#227): tests/admin_registration (TestRegistration). Juango registers
# with `Admin.register!(Model; options...)` (Django's ModelAdmin subclasses are the options), and registering a model
# again replaces its options (Django raises AlreadyRegistered: a difference kept, as Juango projects change options so).
# julia --project=test test/django_admin_registration.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DarPerson
    name = CharField(max_length = 200)
    Meta(table = "dar_person")
end
@model struct DarPlace
    name = CharField(max_length = 200)
    Meta(table = "dar_place")
end
redirect_stdout(devnull) do
    ms = [DarPerson, DarPlace]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django admin_registration: TestRegistration" begin
    st = Admin.AdminSite("dar_site")
    # test_bare_registration, test_registration_with_model_admin
    Admin.register!(DarPerson; site = st)
    @test Admin.get_model_admin(DarPerson; site = st) isa Admin.ModelAdmin
    Admin.unregister!(DarPerson; site = st)
    @test isempty(st.registry)
    # test_unregister_unregistered_model, test_get_model_admin_unregister_model
    @test_throws "The model DarPerson is not registered" Admin.unregister!(DarPerson; site = st)
    @test_throws Admin.NotRegistered Admin.get_model_admin(DarPerson; site = st)
    @test_throws "The model DarPerson is not registered." Admin.get_model_admin(DarPerson; site = st)
    # test_registration_with_star_star_options, test_star_star_overrides
    Admin.register!(DarPerson; site = st, search_fields = ["name"], list_display = [:__str__], save_on_top = true)
    ma = Admin.get_model_admin(DarPerson; site = st)
    @test ma.search_fields == [:name] && ma.list_display == Any[:__str__] && Admin.option(ma, :save_on_top, false) === true
    Admin.unregister!(DarPerson; site = st)
    # test_iterable_registration
    Admin.register!([DarPerson, DarPlace]; site = st, search_fields = ["name"])
    @test Admin.get_model_admin(DarPerson; site = st).search_fields == [:name] && Admin.get_model_admin(DarPlace; site = st).search_fields == [:name]
    Admin.unregister!([DarPerson, DarPlace]; site = st)
    @test isempty(st.registry)
    # test_is_registered_model, test_is_registered_not_registered_model
    @test !Admin.is_registered(DarPerson; site = st)
    Admin.register!(DarPerson; site = st)
    @test Admin.is_registered(DarPerson; site = st) && !Admin.is_registered(DarPerson)
    # (registering again replaces the options, Juango's way)
    Admin.register!(DarPerson; site = st, list_display = [:name])
    @test Admin.get_model_admin(DarPerson; site = st).list_display == Any[:name]
    # not translated: the register decorator (TestRegistrationDecorator: Juango has no admin classes to decorate),
    # AlreadyRegistered (see above), abstract models (Juango's can't be registered: they aren't types with tables),
    # composite primary keys (Juango's admin edits them, the key fields locked)
end

@testset "django admin_default_site, admin_custom_urls" begin
    # admin_default_site: DefaultAdminSiteTests.test_repr, AdminSiteTests.test_repr
    @test string(Admin.site) == "AdminSite(name='admin')" && repr(Admin.AdminSite("other")) == "AdminSite(name='other')"
    # admin_custom_urls: test_post_save_add_redirect, test_post_save_change_redirect (where a plain "Save" goes)
    port_block() do
        Admin.register!(DarPerson; response_post_save_add = (req, o) -> HttpResponseRedirect(reverse_url("admin:history"; app = "project", model = "darperson", id = o.id)),
                        response_post_save_change = (req, o) -> HttpResponseRedirect(reverse_url("admin:delete"; app = "project", model = "darperson", id = o.id)))
        try
            u = create_superuser("dar_super", "secret"); c = Client(); force_login!(c, get(User; id = u.id))
            r = post(c, "/admin/project/darperson/add/", Dict("name" => "John Doe"))
            p = first(objects(DarPerson))
            @test r.status == 302 && getheader(r, "Location") == "/admin/project/darperson/$(p.id)/history/"
            r = post(c, "/admin/project/darperson/$(p.id)/change/", Dict("name" => "Jack Doe"))
            @test r.status == 302 && getheader(r, "Location") == "/admin/project/darperson/$(p.id)/delete/"
            # ("Save and continue" isn't affected)
            r = post(c, "/admin/project/darperson/$(p.id)/change/", Dict("name" => "Jack", "_continue" => "1"))
            @test getheader(r, "Location") == "/admin/project/darperson/$(p.id)/change/"
        finally
            Admin.unregister!(DarPerson)
        end
    end
    # not translated: a ModelAdmin's own URLs (get_urls; Juango's admin URLs are fixed), the custom default site class
end
