# Django's admin_widgets tests, ported (#227, part): tests/admin_widgets (AdminFormfieldForDBFieldTests,
# ForeignKeyRawIdWidgetTest, ManyToManyRawIdWidgetTest, RelatedFieldWidgetWrapperTests, AdminForeignKeyRawIdWidget)
# and the related-object popups they open: the raw id box's lookup link, the add / change / delete / view links
# beside a relation's select, the change list as a lookup popup (`_popup`, `_to_field`), and the page that
# closes a popup handing the object back (Django's popup_response).
# julia --project=test test/django_admin_widgets.jl   (see setup.jl)
#
# Django's tests render the widget classes themselves; these read the HTML of Juango's change form (or its
# form fields' `widget_type`). Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DawMember
    name = CharField(max_length = 100)
    email = EmailField(blank = true)
    Meta(table = "daw_member")
end
Base.show(io::IO, m::DawMember) = print(io, m.name)
@model struct DawBand
    name = CharField(max_length = 100)
    style = CharField(max_length = 20)
    members = ManyToManyField(DawMember; blank = true)
    Meta(table = "daw_band")
end
Base.show(io::IO, b::DawBand) = print(io, b.name)
@model struct DawAlbum
    band = ForeignKey(DawBand, on_delete = :CASCADE)
    name = CharField(max_length = 100)
    Meta(table = "daw_album")
end
Base.show(io::IO, a::DawAlbum) = print(io, a.name)
@model struct DawEvent
    main_band = ForeignKey(DawBand, on_delete = :PROTECT, related_name = :events_main_band_at, limit_choices_to = Q(id__gt = 0))
    start_date = DateField(null = true, blank = true)
    description = TextField(blank = true)
    Meta(table = "daw_event")
end
@model struct DawInventory
    barcode = PositiveIntegerField(unique = true)
    parent = ForeignKey(:self, to_field = :barcode, on_delete = :CASCADE, null = true, blank = true)
    name = CharField(max_length = 20)
    hidden = BooleanField(default = false)
    Meta(table = "daw_inventory")
end
Base.show(io::IO, i::DawInventory) = print(io, i.name)
"Django's Inventory has a default manager that leaves out hidden rows; the raw id label reads through the base manager."
Juango.default_queryset(::Type{DawInventory}) = filter(Juango.base_objects(DawInventory); hidden = false)
@model struct DawHoneycomb
    location = CharField(max_length = 20)
    Meta(table = "daw_honeycomb")
end
Base.show(io::IO, h::DawHoneycomb) = print(io, "Honeycomb in ", h.location)
@model struct DawBee
    honeycomb = ForeignKey(DawHoneycomb, on_delete = :CASCADE)
    Meta(table = "daw_bee")
end
@model struct DawIndividual
    name = CharField(max_length = 20)
    parent = ForeignKey(:self, on_delete = :SET_NULL, null = true, blank = true, related_name = :children)
    soulmate = ForeignKey(:self, on_delete = :CASCADE, null = true, blank = true, related_name = :soulmates)
    Meta(table = "daw_individual")
end
Base.show(io::IO, i::DawIndividual) = print(io, i.name)
@model struct DawCompany
    name = CharField(max_length = 20)
    Meta(table = "daw_company")
end
Base.show(io::IO, c::DawCompany) = print(io, c.name)
@model struct DawAdvisor
    name = CharField(max_length = 20)
    companies = ManyToManyField(DawCompany)
    Meta(table = "daw_advisor")
end
@model struct DawUnsafe
    band = ForeignKey(DawBand, on_delete = :CASCADE, limit_choices_to = Dict("name" => "\"&><escapeme"))
    Meta(table = "daw_unsafe")
end
redirect_stdout(devnull) do
    ms = [DawMember, DawBand, through(DawBand, :members), DawAlbum, DawEvent, DawInventory, DawHoneycomb, DawBee,
          DawIndividual, DawCompany, DawAdvisor, through(DawAdvisor, :companies), DawUnsafe]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
    Juango.update_permissions!(ms)
end

const DAW_ADMIN = "/admin/project"
"The HTML of one field's row on a change form: from its widget to the end of its `<div>`s."
function daw_field(t, name)
    i = findfirst("name=\"$name\"", t)
    i === nothing && return ""
    s = findprev("<div class=\"form-row\">", t, first(i))
    e = findnext("<div class=\"form-row\">", t, last(i))
    e2 = findnext("<div class=\"submit-row\">", t, last(i))
    stop = minimum(x -> x === nothing ? lastindex(t) : first(x) - 1, (e, e2))
    t[first(s):stop]
end
function daw_staff(name, codes...; superuser = false)
    u = superuser ? create_superuser(name, "pw12345") : create_user(name, "pw12345")
    u.is_staff = true; save!(u)
    for code in codes
        add!(u.user_permissions, get(Permission; codename = code))
    end
    c = Client(); force_login!(c, get(User; id = u.id)); c
end
function daw_with(f; band = (;), event = (;), album = (;), inventory = (;), advisor = (;), individual = (;), unsafe = (;))
    Admin.register!(DawBand; band...)
    Admin.register!(DawMember)
    Admin.register!(DawAlbum; album...)
    Admin.register!(DawEvent; event...)
    Admin.register!(DawInventory; inventory...)
    Admin.register!(DawAdvisor; advisor...)
    Admin.register!(DawIndividual; individual...)
    Admin.register!(DawBee; raw_id_fields = [:honeycomb])
    Admin.register!(DawUnsafe; unsafe...)
    try
        f()
    finally
        foreach(Admin.unregister!, [DawBand, DawMember, DawAlbum, DawEvent, DawInventory, DawAdvisor, DawIndividual, DawBee, DawUnsafe])
    end
end
"A model admin's form field for `name` on the add form, as the admin configures it (Django's formfield_for_dbfield)."
function daw_formfield(T, name; kw...)
    Admin.register!(T; kw...)
    try
        ma = Admin.get_admin("project", Juango.model_name(T))
        form = Admin.configure_widgets!(ma, Juango.ModelForm(T))
        form.fields[findfirst(f -> f.name === name, form.fields)]
    finally
        Admin.unregister!(T)
    end
end

@testset "django admin_widgets: AdminFormfieldForDBFieldTests" begin
    port_block() do
        wt(T, n; kw...) = Juango.widget_type(daw_formfield(T, n; kw...))
        @test wt(DawEvent, :start_date) == "date"                                                       # test_DateField
        @test wt(DawEvent, :description) == "textarea"                                                  # test_TextField
        @test wt(DawMember, :name) == "text"                                                            # test_CharField
        @test wt(DawMember, :email) == "email"                                                          # test_EmailField
        @test wt(DawEvent, :main_band) == "select"                                                      # test_ForeignKey
        @test wt(DawEvent, :main_band; raw_id_fields = [:main_band]) == "foreignkeyrawid"               # test_raw_id_ForeignKey
        @test wt(DawEvent, :main_band; radio_fields = [:main_band]) == "radioselect"                    # test_radio_fields_ForeignKey
        @test wt(DawBand, :members) == "selectmultiple"                                                 # test_many_to_many
        @test wt(DawBand, :members; raw_id_fields = [:members]) == "manytomanyrawid"                    # test_raw_id_many_to_many
        f = daw_formfield(DawBand, :members; filter_vertical = [:members])                            # test_filtered_many_to_many
        @test f.widget isa Juango.Widget && f.widget.attrs["data-filter-box"] == "vertical"
        @test wt(DawEvent, :start_date; formfield_overrides = Dict(:date => Dict(:widget => :text))) == "text"   # test_formfield_overrides
        # test_formfield_overrides_m2m_filter_widget: an override's widget wins over filter_vertical (and raw_id_fields)
        @test wt(DawBand, :members; filter_vertical = [:members], formfield_overrides = Dict(:m2m => Dict(:widget => :checkboxes))) ==
              "checkboxselectmultiple"
        @test wt(DawBand, :members; raw_id_fields = [:members], formfield_overrides = Dict(:m2m => Dict(:widget => :checkboxes))) ==
              "checkboxselectmultiple"
    end
end

@testset "django admin_widgets: ForeignKeyRawIdWidgetTest, ManyToManyRawIdWidgetTest" begin
    port_block() do
        daw_with(; album = (; raw_id_fields = [:band]), inventory = (; raw_id_fields = [:parent]),
                   individual = (; raw_id_fields = [:parent]), band = (; raw_id_fields = [:members]),
                   advisor = (; raw_id_fields = [:companies]), unsafe = (; raw_id_fields = [:band])) do
            c = daw_staff("dawsuper"; superuser = true)
            band = create(DawBand; name = "Linkin Park", style = "rock")
            album = create(DawAlbum; band = band, name = "Hybrid Theory")
            # test_render: the id box, the lookup link to the related change list (by its to_field), the object linked
            t = daw_field(text(get(c, "$DAW_ADMIN/dawalbum/$(album.id)/change/")), "band")
            @test assert_html_equal(t, """<div class="form-row"><label for="id_band">Band:</label><div><div>
                <input type="text" name="band" id="id_band" required class="vForeignKeyRawIdAdminField" value="$(band.id)">
                <a href="$DAW_ADMIN/dawband/?_to_field=id" class="related-lookup" id="lookup_id_band" title="Lookup"></a>&nbsp;<strong>
                <a href="$DAW_ADMIN/dawband/$(band.id)/change/">Linkin Park</a></strong></div></div></div>""")
            t = daw_field(text(get(c, "$DAW_ADMIN/dawalbum/add/")), "band")
            @test occursin("<a href=\"$DAW_ADMIN/dawband/?_to_field=id\" class=\"related-lookup\"", t) && !occursin("<strong>", t)
            # test_relations_to_non_primary_key, test_proper_manager_for_label_lookup: by barcode, through the base manager
            apple = create(DawInventory; barcode = 86, name = "Apple")
            core = create(DawInventory; barcode = 87, name = "Core", parent = apple)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawinventory/$(core.id)/change/")), "parent")
            @test occursin("value=\"86\"", t) && occursin("href=\"$DAW_ADMIN/dawinventory/?_to_field=barcode\"", t) &&
                  occursin("<strong><a href=\"$DAW_ADMIN/dawinventory/$(apple.id)/change/\">Apple</a></strong>", t)
            hidden = create(DawInventory; barcode = 93, name = "Hidden", hidden = true)
            child = create(DawInventory; barcode = 94, name = "Child of hidden", parent = hidden)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawinventory/$(child.id)/change/")), "parent")
            @test occursin("value=\"93\"", t) && occursin(">Hidden</a></strong>", t)
            # test_fk_related_model_not_in_admin: no lookup link, the object's name unlinked
            comb = create(DawHoneycomb; location = "Old tree")
            bee = create(DawBee; honeycomb = comb)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawbee/$(bee.id)/change/")), "honeycomb")
            @test occursin("value=\"$(comb.id)\"", t) && occursin("&nbsp;<strong>Honeycomb in Old tree</strong>", t) &&
                  !occursin("related-lookup", t) && !occursin("vForeignKeyRawIdAdminField", t)
            # test_render_unsafe_limit_choices_to: limit_choices_to as the lookup's query, escaped
            t = daw_field(text(get(c, "$DAW_ADMIN/dawunsafe/add/")), "band")
            @test occursin("href=\"$DAW_ADMIN/dawband/?name=%22%26%3E%3Cescapeme&amp;_to_field=id\"", t)
            # (a Q in limit_choices_to gives no parameters)
            @test Admin.url_params_from_lookup_dict(Q(id__gt = 0)) == Pair{String,String}[]
            # test_url_params_from_lookup_dict_any_iterable, test_url_params_from_lookup_dict_callable
            @test Admin.url_params_from_lookup_dict(Dict("color__in" => ("red", "blue"))) == ["color__in" => "red,blue"]
            @test Admin.url_params_from_lookup_dict(Dict("color__in" => ["red", "blue"])) == ["color__in" => "red,blue"]
            @test Admin.url_params_from_lookup_dict(Dict("active" => true, "n" => () -> 3)) == ["active" => "1", "n" => "3"]
            # ManyToManyRawIdWidgetTest test_render: the ids comma-separated, a lookup link without _to_field
            m1 = create(DawMember; name = "Chester"); m2 = create(DawMember; name = "Mike")
            add!(band.members, m1, m2)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawband/$(band.id)/change/")), "members")
            @test occursin("""<div><input type="text" name="members" id="id_members" class="vManyToManyRawIdAdminField" value="$(m1.id),$(m2.id)">""" *
                           """<a href="$DAW_ADMIN/dawmember/" class="related-lookup" id="lookup_id_members" title="Lookup"></a></div>""", t)
            # (and saving reads them back)
            m3 = create(DawMember; name = "Rob")
            r = post(c, "$DAW_ADMIN/dawband/$(band.id)/change/", Dict("name" => "Linkin Park", "style" => "rock", "members" => "$(m1.id), $(m3.id)", "_save" => "1"))
            @test r.status == 302 && Set(m.name for m in collect(get(DawBand; id = band.id).members)) == Set(["Chester", "Rob"])
            # test_m2m_related_model_not_in_admin
            adv = create(DawAdvisor; name = "Rockstar Techie")
            c1 = create(DawCompany; name = "Doodle"); c2 = create(DawCompany; name = "Pear")
            add!(adv.companies, c1, c2)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawadvisor/$(adv.id)/change/")), "companies")
            @test occursin("value=\"$(c1.id),$(c2.id)\"", t) && !occursin("related-lookup", t)
            # AdminForeignKeyRawIdWidget test_nonexistent_target_id, test_invalid_target_id: a form error, not a crash
            for v in ("999999", "a-b", "-1", " ")
                r = post(c, "$DAW_ADMIN/dawalbum/$(album.id)/change/", Dict("band" => v, "name" => "x", "_save" => "1"))
                @test r.status == 200 && occursin("errorlist", text(r))
            end
        end
    end
end

@testset "django admin_widgets: RelatedFieldWidgetWrapperTests" begin
    port_block() do
        daw_with(; individual = (; radio_fields = [:parent])) do
            c = daw_staff("dawsuper2"; superuser = true)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawalbum/add/")), "band")
            # test_widget_is_not_hidden: the links, the add one a popup with _to_field and the source model
            @test occursin("<div class=\"related-widget-wrapper\" data-model-ref=\"dawband\">", t)
            @test occursin("<a class=\"related-widget-wrapper-link add-related\" id=\"add_id_band\" href=\"$DAW_ADMIN/dawband/add/?_to_field=id&amp;_popup=1&amp;_source_model=project.dawalbum\" data-popup=\"yes\" title=\"Add another daw band\">", t)
            @test occursin("id=\"change_id_band\" data-href-template=\"$DAW_ADMIN/dawband/__fk__/change/?_to_field=id&amp;_popup=1\"", t)
            # test_on_delete_cascade_rel_cant_delete_related: Album.band cascades: no delete link
            @test !occursin("delete_id_band", t)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawevent/add/")), "main_band")        # (PROTECT: deleting may be offered)
            @test occursin("id=\"delete_id_main_band\" data-href-template=\"$DAW_ADMIN/dawband/__fk__/delete/?_to_field=id&amp;_popup=1\"", t)
            # test_select_multiple_widget_cant_change_delete_related: add only
            t = daw_field(text(get(c, "$DAW_ADMIN/dawband/add/")), "members")
            @test occursin("add_id_members", t) && !occursin("change_id_members", t) && !occursin("delete_id_members", t)
            # test_non_select_widget_cant_change_delete_related, test_no_can_add_related: radio buttons: add only
            t = daw_field(text(get(c, "$DAW_ADMIN/dawindividual/add/")), "parent")
            @test occursin("add_id_parent", t) && !occursin("change_id_parent", t)
            # test_data_model_ref_when_model_name_is_camel_case: the model's name, lowercased
            t = daw_field(text(get(c, "$DAW_ADMIN/dawinventory/add/")), "parent")
            @test occursin("data-model-ref=\"dawinventory\"", t) && occursin("?_to_field=barcode&amp;_popup=1", t)
            # (a related model without an admin: no links)
            Admin.unregister!(DawBee); Admin.register!(DawBee)
            t = daw_field(text(get(c, "$DAW_ADMIN/dawbee/add/")), "honeycomb")
            @test !occursin("related-widget-wrapper", t)
            # each link only with its permission: add on band only, view without change
            v = daw_staff("dawviewer", "add_dawalbum", "add_dawband", "view_dawband")
            t = daw_field(text(get(v, "$DAW_ADMIN/dawalbum/add/")), "band")
            @test occursin("add_id_band", t) && !occursin("change_id_band", t) &&
                  occursin("<a class=\"related-widget-wrapper-link view-related\" id=\"view_id_band\" data-href-template=\"$DAW_ADMIN/dawband/__fk__/change/?_to_field=id&amp;_popup=1\" title=\"View selected daw band\">", t)
            n = daw_staff("dawnone", "add_dawalbum")
            @test !occursin("related-widget-wrapper-link", daw_field(text(get(n, "$DAW_ADMIN/dawalbum/add/")), "band"))
        end
    end
end

@testset "django admin_widgets: popups (_popup, _to_field)" begin
    port_block() do
        daw_with(; band = (; actions = [], list_editable = [:style], list_display = [:name, :style])) do
            c = daw_staff("dawsuper3"; superuser = true)
            band = create(DawBand; name = "Linkin Park", style = "rock")
            # the change list as a lookup popup: each row hands back its key; no header, actions or editing
            t = text(get(c, "$DAW_ADMIN/dawband/?_to_field=id&_popup=1"))
            @test occursin("<a href=\"$DAW_ADMIN/dawband/$(band.id)/change/?_changelist_filters=_to_field%3Did%26_popup%3D1\" data-popup-opener=\"$(band.id)\">", t)
            @test !occursin("id=\"header\"", t) && !occursin("name=\"form-0-style\"", t) && occursin("id=\"header\"", text(get(c, "$DAW_ADMIN/dawband/")))
            @test occursin("href=\"$DAW_ADMIN/dawband/add/?_popup=1&amp;_to_field=id\"", t)
            # by another field: the value is that field's (Inventory.parent points at barcode)
            inv = create(DawInventory; barcode = 86, name = "Apple")
            @test occursin("data-popup-opener=\"86\"", text(get(c, "$DAW_ADMIN/dawinventory/?_to_field=barcode&_popup=1")))
            # to_field_allowed: a field no relation points at is refused (Django's DisallowedModelAdminToField)
            @test get(c, "$DAW_ADMIN/dawband/?_to_field=style&_popup=1").status == 400
            @test get(c, "$DAW_ADMIN/dawinventory/?_to_field=name").status == 400
            @test get(c, "$DAW_ADMIN/dawband/add/?_to_field=style&_popup=1").status == 400
            @test get(c, "$DAW_ADMIN/dawband/?_to_field=nope").status == 400
            @test get(c, "$DAW_ADMIN/dawband/?_to_field=pk").status == 200
            # limit_choices_to's parameters are allowed lookups (related_fkey_lookups), so the popup can filter
            create(DawBand; name = "\"&><escapeme", style = "x")
            t = text(get(c, "$DAW_ADMIN/dawband/?name=%22%26%3E%3Cescapeme&_to_field=id&_popup=1"))
            @test occursin("&quot;&amp;&gt;&lt;escapeme", t) && !occursin(">Linkin Park<", t)
            # the add form in a popup: Save only; saving closes it, handing back the new object
            t = text(get(c, "$DAW_ADMIN/dawband/add/?_to_field=id&_popup=1"))
            @test occursin("<input type=\"hidden\" name=\"_popup\" value=\"1\"><input type=\"hidden\" name=\"_to_field\" value=\"id\">", t)
            @test !occursin("_addanother", t) && !occursin("_continue", t) && occursin("name=\"_save\"", t)
            r = post(c, "$DAW_ADMIN/dawband/add/?_to_field=id&_popup=1", Dict("name" => "Muse", "style" => "rock", "_popup" => "1", "_to_field" => "id"))
            muse = get(DawBand; name = "Muse")
            @test r.status == 200 && occursin("data-popup-response=\"{&quot;value&quot;:&quot;$(muse.id)&quot;,&quot;obj&quot;:&quot;Muse&quot;}\"", text(r)) ||
                  occursin("data-popup-response=\"{&quot;obj&quot;:&quot;Muse&quot;,&quot;value&quot;:&quot;$(muse.id)&quot;}\"", text(r))
            d = Juango.JSON.parse(Juango.html_unescape(match(r"data-popup-response=\"([^\"]*)\"", text(r))[1]))
            @test d == Dict("value" => string(muse.id), "obj" => "Muse")
            # by barcode: the new object's barcode
            r = post(c, "$DAW_ADMIN/dawinventory/add/", Dict("barcode" => "99", "name" => "Pear", "_popup" => "1", "_to_field" => "barcode"))
            @test Juango.JSON.parse(Juango.html_unescape(match(r"data-popup-response=\"([^\"]*)\"", text(r))[1])) == Dict("value" => "99", "obj" => "Pear")
            # change: the old value, the new one and the new name
            r = post(c, "$DAW_ADMIN/dawinventory/$(inv.id)/change/?_to_field=barcode&_popup=1", Dict("barcode" => "87", "name" => "Apple2", "_popup" => "1"))
            @test Juango.JSON.parse(Juango.html_unescape(match(r"data-popup-response=\"([^\"]*)\"", text(r))[1])) ==
                  Dict("action" => "change", "value" => "86", "obj" => "Apple2", "new_value" => "87")
            # delete: the deleted object's value
            t = text(get(c, "$DAW_ADMIN/dawband/$(muse.id)/delete/?_to_field=id&_popup=1"))
            @test occursin("<input type=\"hidden\" name=\"_popup\" value=\"1\">", t)
            r = post(c, "$DAW_ADMIN/dawband/$(muse.id)/delete/?_to_field=id&_popup=1", Dict("post" => "yes", "_popup" => "1"))
            @test Juango.JSON.parse(Juango.html_unescape(match(r"data-popup-response=\"([^\"]*)\"", text(r))[1])) ==
                  Dict("action" => "delete", "value" => string(muse.id))
            @test !Juango.exists(filter(DawBand; name = "Muse"))
            # (the popup functions the pages call are on every admin page)
            @test occursin("window.dismissAddRelatedObjectPopup", text(get(c, "$DAW_ADMIN/dawalbum/add/")))
        end
    end
    # not translated: the admin's own form field classes (AdminDateWidget, AdminSplitDateTime, vDateField, ...; Juango's
    # admin uses the browser's inputs), AdminFileWidget, AdminURLFieldWidget, the Playwright tests (calendars, the
    # horizontal/vertical filter, the popups clicked through), AdminFormfieldForDBFieldWithRequestTests (formfield_for_foreignkey
    # is tested in admin.jl), test_changelist_ForeignKey
end
