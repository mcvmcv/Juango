# Django's modeladmin tests, ported (#227): tests/modeladmin (ModelAdminTests, ModelAdminPermissionTests).
# julia --project=test test/django_modeladmin.jl   (see setup.jl)
#
# Django's ModelAdmin is a class whose methods a subclass overrides; Juango's is the options given to
# `Admin.register!`, with hooks (`get_fieldsets = (req, obj) -> ...`) for the methods. These build the
# ModelAdmin on a site of their own and ask it what Django's methods answer: `Admin.admin_fields` is
# the change form's fields (Django's `get_form(...).base_fields`), `Admin.lookup_allowed` and
# `Admin.can` as Django's. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DmaBand
    name = CharField(max_length = 100)
    bio = TextField()
    sign_date = DateField()
    Meta(table = "dma_band", ordering = ["name"])
end
Base.show(io::IO, b::DmaBand) = print(io, b.name)
@model struct DmaSong
    name = CharField(max_length = 100)
    band = ForeignKey(DmaBand, on_delete = :CASCADE)
    featuring = ManyToManyField(DmaBand; related_name = :featured)
    Meta(table = "dma_song")
end
@model struct DmaConcert
    main_band = ForeignKey(DmaBand, on_delete = :CASCADE, related_name = :main_concerts)
    opening_band = ForeignKey(DmaBand, on_delete = :CASCADE, related_name = :opening_concerts, blank = true)
    day = CharField(max_length = 3, choices = ["1" => "Fri", "2" => "Sat"])
    transport = CharField(max_length = 100, choices = ["1" => "Plane", "2" => "Train", "3" => "Bus"], blank = true)
    Meta(table = "dma_concert")
end
# (test_lookup_allowed_onetoone's models)
@model struct DmaDepartment
    code = CharField(max_length = 4, unique = true)
    Meta(table = "dma_department")
end
@model struct DmaEmployee
    department = ForeignKey(DmaDepartment, on_delete = :CASCADE, to_field = :code)
    Meta(table = "dma_employee")
end
@model struct DmaEmployeeProfile
    employee = OneToOneField(DmaEmployee, on_delete = :CASCADE)
    Meta(table = "dma_employee_profile")
end
@model struct DmaEmployeeInfo
    employee = OneToOneField(DmaEmployee, on_delete = :CASCADE)
    description = CharField(max_length = 100)
    Meta(table = "dma_employee_info")
end
# (test_lookup_allowed_for_local_fk_fields, _non_autofield_primary_key, _foreign_primary)
@model struct DmaCountry
    name = CharField(max_length = 256)
    Meta(table = "dma_country")
end
@model struct DmaPlace
    country = ForeignKey(DmaCountry, on_delete = :CASCADE)
    Meta(table = "dma_place")
end
@model struct DmaCodeCountry
    code = CharField(max_length = 2, primary_key = true)
    Meta(table = "dma_code_country")
end
@model struct DmaCodePlace
    country = ForeignKey(DmaCodeCountry, on_delete = :CASCADE)
    Meta(table = "dma_code_place")
end
@model struct DmaRestaurant
    place = OneToOneField(DmaPlace, on_delete = :CASCADE, primary_key = true)
    Meta(table = "dma_restaurant")
end
@model struct DmaWaiter
    restaurant = ForeignKey(DmaRestaurant, on_delete = :CASCADE)
    Meta(table = "dma_waiter")
end
redirect_stdout(devnull) do
    ms = [DmaBand, DmaSong, through(DmaSong, :featuring), DmaConcert, DmaDepartment, DmaEmployee, DmaEmployeeProfile, DmaEmployeeInfo,
          DmaCountry, DmaPlace, DmaCodeCountry, DmaCodePlace, DmaRestaurant, DmaWaiter]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
    Juango.update_permissions!(ms)
end

const DMA_SITE = Admin.AdminSite("dma_site")
"A ModelAdmin for `T` with these options, on a site of its own (Django's `ModelAdmin(Band, self.site)`)."
dma(T; kw...) = (Admin.register!(T; site = DMA_SITE, kw...); DMA_SITE.registry[Admin.admin_key(T)])
dma_req(path = "/"; user = nothing) = (r = Request("GET", path); user === nothing || (r.user = user); r)

@testset "django modeladmin: ModelAdminTests" begin
    port_block() do
        band = create(DmaBand; name = "The Doors", bio = "", sign_date = Date(1965, 1, 1))
        req = dma_req(; user = root_user())

        ma = dma(DmaBand)
        @test isempty(ma.inlines) && [a.name for a in ma.actions] == ["delete_selected"]     # test_default_attributes (and Django's site-wide delete action)
        # test_default_fields
        @test Admin.admin_fields(ma, req) == [:name, :bio, :sign_date]
        @test Admin.admin_fields(ma, req, band) == [:name, :bio, :sign_date]
        @test isempty(Admin.admin_exclude(ma, req, band))
        @test isempty(Admin.admin_fieldsets(ma, req))                                      # test_default_fieldsets (none declared: one group of the form's fields)

        # test_get_fieldsets: the fieldsets' fields are the form's (#18681)
        ma = dma(DmaBand; get_fieldsets = (req, obj) -> [nothing => [:name, :bio]])
        @test Admin.admin_fields(ma, nothing) == [:name, :bio]

        # test_lookup_allowed_allows_nonexistent_lookup (#21129)
        ma = dma(DmaBand; fields = [:name])
        @test Admin.lookup_allowed(ma, "name__nonexistent", "test_value", req) === true
        # test_lookup_allowed_onetoone: a reverse one-to-one, a one-to-one and a key with to_field
        ma = dma(DmaEmployeeProfile; list_filter = ["employee__dmaemployeeinfo__description", "employee__department__code"])
        @test Admin.lookup_allowed(ma, "employee__dmaemployeeinfo__description", "test_value", req) === true
        @test Admin.lookup_allowed(ma, "employee__department__code", "test_value", req) === true
        # test_lookup_allowed_for_local_fk_fields
        ma = dma(DmaPlace)
        for (lookup, value) in [("country", "1"), ("country__exact", "1"), ("country__id", "1"), ("country__id__exact", "1"),
                                ("country__isnull", true), ("country__isnull", false), ("country__id__isnull", false)]
            @test Admin.lookup_allowed(ma, lookup, value, req) === true
        end
        # test_lookup_allowed_non_autofield_primary_key
        ma = dma(DmaCodePlace; list_filter = [:country])
        @test Admin.lookup_allowed(ma, "country__code__exact", "DE", req) === true
        # test_lookup_allowed_foreign_primary
        ma = dma(DmaWaiter; list_filter = ["restaurant__place__country", "restaurant__place__country__name"])
        @test Admin.lookup_allowed(ma, "restaurant__place__country", "1", req) === true
        @test Admin.lookup_allowed(ma, "restaurant__place__country__id__exact", "1", req) === true
        @test Admin.lookup_allowed(ma, "restaurant__place__country__name", "test_value", req) === true
        # (and what isn't allowed: a path through relations no list filter names)
        @test Admin.lookup_allowed(ma, "restaurant__place__country__name__startswith", "x", req) === true    # (a lookup on a named path)
        @test Admin.lookup_allowed(dma(DmaWaiter; list_filter = ["restaurant__place__country"]),
                                   "restaurant__place__country__name", "x", req) === false
        @test Admin.lookup_allowed(dma(DmaEmployeeProfile; list_filter = ["employee__department__code"]),
                                   "employee__dmaemployeeinfo__description", "x", req) === false
        # test_lookup_allowed_considers_dynamic_list_filter
        ma = dma(DmaConcert; list_filter = ["main_band__sign_date"],
                 get_list_filter = r -> r.user !== nothing && r.user.is_authenticated ? ["main_band__sign_date", "main_band__name"] : ["main_band__sign_date"])
        anon = dma_req("/?main_band__name=test")
        @test Admin.lookup_allowed(ma, "main_band__sign_date", "?", anon) === true
        @test Admin.lookup_allowed(ma, "main_band__name", "?", anon) === false
        @test Admin.lookup_allowed(ma, "main_band__sign_date", "?", req) === true
        @test Admin.lookup_allowed(ma, "main_band__name", "?", req) === true
        # (a hook replaces the rule, as overriding Django's lookup_allowed)
        @test Admin.lookup_allowed(dma(DmaConcert; lookup_allowed = (l, v, r) -> l == "main_band__bio"), "main_band__bio", "x", req) === true

        # test_field_arguments
        ma = dma(DmaBand; fields = [:name])
        @test Admin.admin_fields(ma, req) == [:name] && Admin.admin_fields(ma, req, band) == [:name]
        # test_field_arguments_restricted_on_form: fields, fieldsets and exclude all limit the form
        @test Admin.admin_fields(dma(DmaBand; fieldsets = ["" => [:name]]), req) == [:name]
        @test Admin.admin_fields(dma(DmaBand; fieldsets = ["" => [:name]]), req, band) == [:name]
        @test Admin.admin_fields(dma(DmaBand; exclude = [:bio]), req) == [:name, :sign_date]
        @test Admin.admin_fields(dma(DmaBand; exclude = (:bio,)), req) == [:name, :sign_date]
        @test Admin.admin_fields(dma(DmaBand; fields = [:name, :bio], exclude = [:bio]), req) == [:name]
        # test_overriding_get_exclude, test_get_exclude_overrides_exclude, test_get_exclude_takes_obj
        @test Admin.admin_fields(dma(DmaBand; get_exclude = (r, o) -> [:name]), req) == [:bio, :sign_date]
        @test Admin.admin_fields(dma(DmaBand; exclude = [:bio], get_exclude = (r, o) -> [:name]), req) == [:bio, :sign_date]
        @test Admin.admin_fields(dma(DmaBand; get_exclude = (r, o) -> o === nothing ? [:name] : [:sign_date]), req, band) == [:name, :bio]
        # (read-only fields aren't the form's: Django's get_form excludes them)
        @test Admin.admin_fields(dma(DmaBand; readonly_fields = [:name]), req) == [:bio, :sign_date]

        # the change form as the admin shows it (test_default_foreign_key_widget, test_foreign_key_as_radio_field)
        root_user(); c = Client(); force_login!(c, root_user())
        Admin.register!(DmaConcert)
        Admin.register!(DmaBand)
        try
            t = text(get(c, "/admin/project/dmaconcert/add/"))
            @test occursin(Regex("<select[^>]*name=\"main_band\"[^>]*>(?s:.)*<option value=\"$(band.id)\"[^>]*>The Doors</option>"), t)
            @test occursin(r"<select[^>]*name=\"day\"[^>]*>(?s:.)*<option value=\"1\"[^>]*>Fri</option>(?s:.)*<option value=\"2\"[^>]*>Sat</option>", t)
            Admin.register!(DmaConcert; radio_fields = [:main_band, :opening_band, :day, :transport])
            t = text(get(c, "/admin/project/dmaconcert/add/"))
            @test occursin(Regex("type=\"radio\"[^>]*name=\"main_band\"[^>]*value=\"$(band.id)\"|name=\"main_band\"[^>]*type=\"radio\"[^>]*value=\"$(band.id)\""), t)
            @test occursin(r"type=\"radio\"[^>]*name=\"day\"|name=\"day\"[^>]*type=\"radio\"", t)
            # test_queryset_override: the select lists every band, by name
            band2 = create(DmaBand; name = "The Beatles", bio = "", sign_date = Date(1962, 1, 1))
            Admin.register!(DmaConcert)
            t = text(get(c, "/admin/project/dmaconcert/add/"))
            @test occursin(Regex("<option value=\"$(band2.id)\"[^>]*>The Beatles</option>\\s*<option value=\"$(band.id)\"[^>]*>The Doors</option>"), t)
            # test_get_deleted_objects, test_get_deleted_objects_with_custom_has_delete_permission
            d = Admin.get_deleted_objects(req, band)
            @test d.model_count == ["dma bands" => 1]
            @test isempty(d.perms_needed) && isempty(d.protected)
            Admin.register!(DmaBand; has_delete_permission = (r, o) -> false)
            d = Admin.get_deleted_objects(req, band2)
            @test d.perms_needed == ["dma band"] && isempty(d.protected)
        finally
            Admin.unregister!(DmaConcert); Admin.unregister!(DmaBand)
        end

        # test_log_actions
        bill = create_user("dma_bill", "pw")
        e = Juango.log_action!(bill, band, Juango.ADDITION, "[{\"added\": {}}]")
        f = first(order_by(filter(Juango.LogEntry; action_flag = Juango.ADDITION), "-id"))
        @test f.id == e.id && f.user_id == bill.id && f.object_id == string(band.id) && f.object_repr == "The Doors"
        @test f.content_type_id == Juango.get_for_model(band).id && f.change_message == "[{\"added\": {}}]"
        # not translated: the custom ModelForm classes (Meta.exclude, form fields; Juango's add_form and get_form
        # hooks give the whole form), InlineModelAdmin's exclude/readonly_fields/get_fieldsets/get_formset and
        # formfield_overrides by field class (Juango's are by field kind), str/repr, the list_select_related deprecation
    end
end

@testset "django modeladmin: ModelAdminPermissionTests" begin
    port_block() do
        perm(code) = get(Permission; codename = code)
        function user_with(name, code)
            u = create_user(name, "pw"); u.is_staff = true; save!(u)
            add!(u.user_permissions, perm(code))
            get(User; id = u.id)          # (a fresh object: permissions are cached per object)
        end
        viewer, adder, changer, deleter = (user_with("dma_$c", "$(c)_dmaband") for c in ("view", "add", "change", "delete"))
        ma = dma(DmaBand)
        r(u) = dma_req(; user = u)
        # test_has_view_permission (change implies view, as Django's)
        @test [Admin.can_view(r(u), ma) for u in (viewer, adder, changer, deleter)] == [true, false, true, false]
        # test_has_add_permission, test_has_change_permission, test_has_delete_permission
        @test [Admin.can(r(u), ma, :add) for u in (viewer, adder, changer, deleter)] == [false, true, false, false]
        @test [Admin.can(r(u), ma, :change) for u in (viewer, adder, changer, deleter)] == [false, false, true, false]
        @test [Admin.can(r(u), ma, :delete) for u in (viewer, adder, changer, deleter)] == [false, false, false, true]
        # test_has_module_permission: any permission in the app
        @test all(u -> Juango.has_module_perms(u, "project"), (viewer, adder, changer, deleter))
        @test !any(u -> Juango.has_module_perms(u, "anotherapp"), (viewer, adder, changer, deleter))
        # not translated: test_inline_has_add_permission_uses_obj (Juango's inlines take the model's permissions)
    end
end
