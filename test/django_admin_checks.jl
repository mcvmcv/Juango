# Django's ModelAdmin system checks, ported (#227): tests/modeladmin/test_checks.py (the checks of names and
# kinds of fields; Juango's options are typed, so Django's "must be a list or tuple / a boolean / an integer"
# checks have nothing to find).
# julia --project=test test/django_admin_checks.jl   (see setup.jl)
#
# `Admin.check_admin(ma)` gives a ModelAdmin's problems with Django's ids and messages; `manage.jl check`
# runs it for every mounted admin site. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DacBand
    name = CharField(max_length = 100)
    sign_date = DateField()
    Meta(table = "dac_band")
end
@model struct DacSong
    title = CharField(max_length = 100)
    Meta(table = "dac_song")
end
@model struct DacBandMember
    band = ForeignKey(DacBand, on_delete = :CASCADE)
    song = ForeignKey(DacSong, on_delete = :CASCADE)
    Meta(table = "dac_band_member")
end
@model struct DacValidation
    name = CharField(max_length = 100)
    slug = SlugField()
    users = ManyToManyField(DacSong; related_name = :validations)
    members = ManyToManyField(DacBand; through = DacBandMember, related_name = :validations)
    state = CharField(max_length = 2, choices = ["CO" => "Colorado", "WA" => "Washington"])
    is_active = BooleanField(default = false)
    pub_date = DateTimeField()
    band = ForeignKey(DacBand, on_delete = :CASCADE)
    best_friend = OneToOneField(DacSong, on_delete = :CASCADE, related_name = :best_friend)
    no = IntegerField(verbose_name = "Number", null = true, blank = true)
    Meta(table = "dac_validation")
end
@model struct DacInline
    parent = ForeignKey(DacValidation, on_delete = :CASCADE)
    Meta(table = "dac_inline")
end
@model struct DacTwoKeys
    one = ForeignKey(DacValidation, on_delete = :CASCADE, related_name = :ones)
    two = ForeignKey(DacValidation, on_delete = :CASCADE, related_name = :twos)
    Meta(table = "dac_two_keys")
end

redirect_stdout(devnull) do
    ms = [DacBand, DacSong, DacBandMember, DacValidation, through(DacValidation, :users), DacInline, DacTwoKeys]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

const DAC_SITE = Admin.AdminSite("dac_site")
"The problems of a ModelAdmin for `T` with these options: (id, message) pairs."
function dac(T = DacValidation; kw...)
    Admin.register!(T; site = DAC_SITE, kw...)
    [(m.id, replace(m.msg, r"^<ModelAdmin [^>]*>: " => "")) for m in Admin.check_admin(DAC_SITE.registry[Admin.admin_key(T)])]
end
dac_valid(T = DacValidation; kw...) = isempty(dac(T; kw...))
dac_invalid(msg, id, T = DacValidation; kw...) = (r = dac(T; kw...); r == [(id, msg)] ? true : (println(r); false))
const DAC = "project.DacValidation"

@testset "django modeladmin checks" begin
    # RawIdCheckTests
    @test dac_invalid("The value of 'raw_id_fields[0]' refers to 'non_existent_field', which is not a field of '$DAC'.", "admin.E002";
                      raw_id_fields = [:non_existent_field])
    @test dac_invalid("The value of 'raw_id_fields[0]' must be a foreign key or a many-to-many field.", "admin.E003"; raw_id_fields = (:name,))
    @test dac_valid(; raw_id_fields = (:users,))
    @test dac_invalid("The value of 'raw_id_fields[0]' refers to 'band_id', which is not a field of '$DAC'.", "admin.E002";
                      raw_id_fields = [:band_id])                                                       # test_field_attname
    # FieldsetsCheckTests
    @test dac_valid(; fieldsets = ["General" => [:name]])
    @test dac_invalid("Both 'fieldsets' and 'fields' are specified.", "admin.E005"; fieldsets = ["General" => [:name]], fields = [:name])
    @test dac_invalid("There are duplicate field(s) in 'fieldsets[0][1]'.", "admin.E012"; fieldsets = ["General" => [:name, :name]])
    @test dac_invalid("There are duplicate field(s) in 'fieldsets[1][1]'.", "admin.E012";                # test_duplicate_fields_in_fieldsets
                      fieldsets = ["Header 1" => [:name], "Header 2" => [:name]])
    # FieldsCheckTests
    @test dac_invalid("The value of 'fields' contains duplicate field(s).", "admin.E006"; fields = [:name, :name])
    @test dac_invalid("The value of 'fields' cannot include the ManyToManyField 'members', because that field manually specifies a relationship model.",
                      "admin.E013"; fields = [:name, :members])
    # (ExcludeCheckTests)
    @test dac_invalid("The value of 'exclude' contains duplicate field(s).", "admin.E015"; exclude = [:name, :name])
    # FilterVerticalCheckTests, FilterHorizontalCheckTests
    for opt in (:filter_vertical, :filter_horizontal)
        @test dac_invalid("The value of '$opt[0]' refers to 'non_existent_field', which is not a field of '$DAC'.", "admin.E019";
                          (opt => [:non_existent_field],)...)
        @test dac_invalid("The value of '$opt[0]' must be a many-to-many field.", "admin.E020"; (opt => [:name],)...)
        @test dac_valid(; (opt => [:users],)...)
    end
    # RadioFieldsCheckTests
    @test dac_invalid("The value of 'radio_fields' refers to 'non_existent_field', which is not a field of '$DAC'.", "admin.E022";
                      radio_fields = [:non_existent_field])
    @test dac_invalid("The value of 'radio_fields' refers to 'name', which is not an instance of ForeignKey, and does not have a 'choices' definition.",
                      "admin.E023"; radio_fields = [:name])
    @test dac_valid(; radio_fields = [:state, :band])
    # PrepopulatedFieldsCheckTests
    @test dac_invalid("The value of 'prepopulated_fields' refers to 'non_existent_field', which is not a field of '$DAC'.", "admin.E027";
                      prepopulated_fields = Dict(:non_existent_field => [:slug]))
    @test dac_invalid("The value of 'prepopulated_fields[\"slug\"][0]' refers to 'non_existent_field', which is not a field of '$DAC'.",
                      "admin.E030"; prepopulated_fields = Dict(:slug => [:non_existent_field]))
    @test dac_invalid("The value of 'prepopulated_fields' refers to 'users', which must not be a DateTimeField, a ForeignKey, a OneToOneField, or a ManyToManyField.",
                      "admin.E028"; prepopulated_fields = Dict(:users => [:name]))
    @test dac_invalid("The value of 'prepopulated_fields' refers to 'best_friend', which must not be a DateTimeField, a ForeignKey, a OneToOneField, or a ManyToManyField.",
                      "admin.E028"; prepopulated_fields = Dict(:best_friend => [:name]))
    @test dac_valid(; prepopulated_fields = Dict(:slug => [:name]))
    # ListDisplayTests (E109)
    @test dac_invalid("The value of 'list_display[0]' must not be a many-to-many field or a reverse foreign key.", "admin.E109"; list_display = [:users])
    @test dac_valid(; list_display = [:name, :band, Admin.display(o -> 1; description = "x")])
    # ListDisplayLinksCheckTests
    @test dac_invalid("The value of 'list_display_links[0]' refers to 'non_existent_field', which is not defined in 'list_display'.", "admin.E111";
                      list_display_links = [:non_existent_field])
    @test dac_invalid("The value of 'list_display_links[0]' refers to 'name', which is not defined in 'list_display'.", "admin.E111";
                      list_display = [:band], list_display_links = [:name])
    @test dac_valid(; list_display = [:name, :band], list_display_links = [:name])
    # ListFilterTests (E116)
    @test dac_invalid("The value of 'list_filter[0]' refers to 'non_existent_field', which does not refer to a Field.", "admin.E116";
                      list_filter = [:non_existent_field])
    @test dac_invalid("The value of 'list_filter[0]' refers to 'band__nope', which does not refer to a Field.", "admin.E116";
                      list_filter = ["band__nope"])
    @test dac_valid(; list_filter = [:is_active, "band__name", :band => :related_only])
    # DateHierarchyCheckTests
    @test dac_invalid("The value of 'date_hierarchy' refers to 'non_existent_field', which does not refer to a Field.", "admin.E127";
                      date_hierarchy = :non_existent_field)
    @test dac_invalid("The value of 'date_hierarchy' must be a DateField or DateTimeField.", "admin.E128"; date_hierarchy = :name)
    @test dac_valid(; date_hierarchy = :pub_date) && dac_valid(; date_hierarchy = "band__sign_date")
    @test dac_invalid("The value of 'date_hierarchy' must be a DateField or DateTimeField.", "admin.E128"; date_hierarchy = "band__name")
    # OrderingCheckTests
    @test dac_invalid("The value of 'ordering[0]' refers to 'non_existent_field', which is not a field of '$DAC'.", "admin.E033";
                      ordering = ["non_existent_field"])
    @test dac_invalid("The value of 'ordering' has the random ordering marker '?', but contains other fields as well.", "admin.E032";
                      ordering = ["?", "name"])
    @test dac_valid(; ordering = ["?"]) && dac_valid(; ordering = ["band__name"]) && dac_valid(; ordering = ["-name", "pk"])
    @test dac_invalid("The value of 'ordering[1]' refers to 'nope', which is not a field of '$DAC'.", "admin.E033"; ordering = ["name", "-nope"])
    # ListDisplayEditableTests (Juango refuses a list_editable field missing from list_display when registering)
    @test dac_invalid("The value of 'list_editable[0]' refers to the first field in 'list_display' ('name'), which cannot be used unless 'list_display_links' is set.",
                      "admin.E124"; list_display = [:name, :slug], list_editable = [:name])
    @test dac_valid(; list_display = [:name, :slug], list_display_links = [:name], list_editable = [:slug])
    @test dac_invalid("The value of 'list_editable[0]' cannot be in both 'list_editable' and 'list_display_links'.", "admin.E123";
                      list_display = [:name, :slug], list_display_links = [:slug], list_editable = [:slug])
    @test_throws ArgumentError dac(; list_display = [:name], list_editable = [:slug])
    # AutocompleteFieldsTests
    @test dac_invalid("The value of 'autocomplete_fields[0]' refers to 'nonexistent', which is not a field of '$DAC'.", "admin.E037";
                      autocomplete_fields = [:nonexistent])
    @test dac_invalid("The value of 'autocomplete_fields[0]' must be a foreign key or a many-to-many field.", "admin.E038"; autocomplete_fields = [:name])
    @test dac_invalid("An admin for model \"DacBand\" has to be registered to be referenced by <ModelAdmin project.dacvalidation>.autocomplete_fields.",
                      "admin.E039"; autocomplete_fields = [:band])
    Admin.register!(DacBand; site = DAC_SITE)
    @test dac_invalid("<ModelAdmin project.dacband> must define \"search_fields\", because it's referenced by <ModelAdmin project.dacvalidation>.autocomplete_fields.",
                      "admin.E040"; autocomplete_fields = [:band])
    Admin.register!(DacBand; site = DAC_SITE, search_fields = [:name])
    @test dac_valid(; autocomplete_fields = [:band])
    # ActionsCheckTests
    dac_action(admin, req, qs) = nothing
    @test dac_invalid("__name__ attributes of actions defined in <ModelAdmin project.dacvalidation> must be unique. Name 'dac_action' is not unique.",
                      "admin.E130"; actions = [dac_action, Admin.action((a, r, q) -> nothing; name = "dac_action")])
    # FkNameCheckTests, InlinesCheckTests
    @test dac_valid(; inlines = [Admin.TabularInline(DacInline)])
    @test dac(; inlines = [Admin.TabularInline(DacTwoKeys)]) == [("admin.E202",
          "<TabularInline project.dactwokeys>: 'DacTwoKeys' has more than one ForeignKey to 'DacValidation'. You must specify a 'fk_name' attribute.")]
    @test dac(; inlines = [Admin.TabularInline(DacInline; fk = :nope)]) ==
          [("admin.E202", "<TabularInline project.dacinline>: 'DacInline' has no field named 'nope'.")]
    @test dac_valid(; inlines = [Admin.TabularInline(DacTwoKeys; fk = :one)])
    @test dac(; inlines = [Admin.TabularInline(DacInline; exclude = [:parent])]) ==                     # (ExcludeCheckTests, admin.E201)
          [("admin.E201", "<TabularInline project.dacinline>: Cannot exclude the field 'parent', because it is the foreign key to the parent model '$DAC'.")]

    # manage.jl check reports a mounted site's problems
    Admin.register!(DacValidation; site = DAC_SITE, raw_id_fields = [:name])
    @test !any(m -> m.id == "admin.E003", Admin.admin_check_issues())                                  # (not mounted: not checked)
    push!(Admin.CHECKED_SITES, DAC_SITE)
    try
        @test any(m -> m.id == "admin.E003" && occursin("project.dacvalidation", m.msg), Juango.run_checks(; tags = [:admin]))
    finally
        filter!(s -> s !== DAC_SITE, Admin.CHECKED_SITES)
    end
    # not translated: the type checks (E001, E004, E007-E011, E014, E016-E018, E021, E024-E026, E029, E031, E034, E101-E107,
    # E110, E112-E115, E117-E120, E126, E203-E206: Juango's options are typed), E035/E108 (Juango's list_display
    # and readonly_fields may name any property of the object), the delete_confirmation_max_display and formset checks
end
