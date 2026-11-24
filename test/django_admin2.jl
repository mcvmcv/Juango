# More of Django's admin tests, ported (#227): admin_ordering, admin_utils (UtilsTests: display_for_field, display_for_value).
#
# Juango's boolean icons are its own ✔/✘/? spans, not Django's images. Not translated from admin_utils:
# NestedObjectsTests (Django's NestedObjects collector), lookup_field, label_for_field and help_text_for_field (Python
# attribute lookup), the password-hash display, flatten/flatten_fieldsets, quote and test_logentry.
# julia --project=test test/django_admin2.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Juango.Admin

# --- tests/admin_ordering ------------------------------------------------------------------------------------
@model struct DaoBand
    name = CharField(max_length = 100)
    bio = TextField()
    rank = IntegerField()
    Meta(table = "dao_band", ordering = [:name])
end
@model struct DaoSong
    band = ForeignKey(DaoBand; on_delete = :CASCADE)
    name = CharField(max_length = 100)
    duration = IntegerField()
    other_interpreters = ManyToManyField(DaoBand; related_name = :covers)
    Meta(table = "dao_song", ordering = [:name])
end
redirect_stdout(devnull) do
    ms = Any[DaoBand, DaoSong, through(DaoSong, :other_interpreters)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

"A ModelAdmin of `T` with these options (registered for the call, then put back)."
function dao_admin(f, T; kw...)
    key = Admin.admin_key(T)
    old = get(Admin.site.registry, key, nothing)
    Admin.register!(T; kw...)
    try
        f(Admin.site.registry[key])
    finally
        old === nothing ? Admin.unregister!(T) : (Admin.site.registry[key] = old)
    end
end
dao_names(qs) = [x.name for x in collect(qs)]

@testset "django admin_ordering: TestAdminOrdering" begin
  port_block() do
    bulk_create([DaoBand(; name = "Aerosmith", bio = "", rank = 3), DaoBand(; name = "Radiohead", bio = "", rank = 1),
                 DaoBand(; name = "Van Halen", bio = "", rank = 2)])
    req = Request("GET", "/")
    # test_default_ordering: the model's Meta.ordering
    dao_admin(DaoBand) do ma
        @test dao_names(Admin.admin_queryset(ma, req)) == ["Aerosmith", "Radiohead", "Van Halen"]
    end
    # test_specified_ordering
    dao_admin(DaoBand; ordering = ["rank"]) do ma
        @test dao_names(Admin.admin_queryset(ma, req)) == ["Radiohead", "Van Halen", "Aerosmith"]
    end
    # test_specified_ordering_by_f_expression
    dao_admin(DaoBand; ordering = [Desc(F(:rank); nulls_last = true)]) do ma
        @test dao_names(Admin.admin_queryset(ma, req)) == ["Aerosmith", "Van Halen", "Radiohead"]
    end
    # test_dynamic_ordering
    su = create(User; username = "dao_admin", is_superuser = true)
    other = create(User; username = "dao_other")
    dao_admin(DaoBand; get_ordering = r -> r.user.is_superuser ? ["rank"] : ["name"]) do ma
        req.user = su
        @test dao_names(Admin.admin_queryset(ma, req)) == ["Radiohead", "Van Halen", "Aerosmith"]
        req.user = other
        @test dao_names(Admin.admin_queryset(ma, req)) == ["Aerosmith", "Radiohead", "Van Halen"]
    end
  end
end

@testset "django admin_ordering: TestInlineModelAdminOrdering" begin
  port_block() do
    band = create(DaoBand; name = "Aerosmith", bio = "", rank = 3)
    bulk_create([DaoSong(; band, name = "Pink", duration = 235), DaoSong(; band, name = "Dude (Looks Like a Lady)", duration = 264),
                 DaoSong(; band, name = "Jaded", duration = 214)])
    @test dao_names(Admin.inline_queryset(Admin.StackedInline(DaoSong))) == ["Dude (Looks Like a Lady)", "Jaded", "Pink"]   # test_default_ordering
    @test dao_names(Admin.inline_queryset(Admin.StackedInline(DaoSong; ordering = ["duration"]))) == ["Jaded", "Pink", "Dude (Looks Like a Lady)"]
  end
end

@testset "django admin_ordering: TestRelatedFieldsAdminOrdering" begin
  port_block() do
    b1 = create(DaoBand; name = "Pink Floyd", bio = "", rank = 1)
    b2 = create(DaoBand; name = "Foo Fighters", bio = "", rank = 5)
    req = Request("GET", "/")
    function choices(ma)
        form = Admin.configure_widgets!(ma, ModelForm(DaoSong; fields = [:band, :other_interpreters]), req)
        [collect(Juango.choices_queryset(f)) for f in form.fields if f.name in (:band, :other_interpreters)]
    end
    dao_admin(DaoSong) do sa
        @test choices(sa) == [[b2, b1], [b2, b1]]                                  # test_no_admin_fallback_to_model_ordering
        dao_admin(DaoBand) do _
            @test choices(sa) == [[b2, b1], [b2, b1]]                              # test_admin_with_no_ordering_fallback_to_model_ordering
        end
        dao_admin(DaoBand; ordering = ["rank"]) do _
            @test choices(sa) == [[b1, b2], [b1, b2]]                              # test_admin_ordering_beats_model_ordering
        end
    end
    # test_custom_queryset_still_wins (#21405)
    narrow(r, f) = f.kind === :fk ? ModelChoiceField(filter(DaoBand; rank__gt = 2)) : ModelMultipleChoiceField(filter(DaoBand; rank__gt = 2))
    dao_admin(DaoSong; formfield_for_foreignkey = narrow, formfield_for_manytomany = narrow) do sa
        dao_admin(DaoBand; ordering = ["rank"]) do _
            form = Admin.configure_widgets!(sa, ModelForm(DaoSong; fields = [:band, :other_interpreters]), req)
            @test [collect(f.related.queryset) for f in form.fields if f.name in (:band, :other_interpreters)] == [[b2], [b2]]
        end
    end
  end
end

# --- tests/admin_utils (UtilsTests) -----------------------------------------------------------------------------
@testset "django admin_utils: UtilsTests" begin
    E = "-empty-"
    dff(v, f) = Admin.display_for_field(v, f, E)
    dfv(v; kw...) = Admin.display_for_value(v, E; kw...)
    # test_empty_value_display_for_field
    for f in (CharField(max_length = 10), DateField(), DecimalField(max_digits = 10, decimal_places = 2), FloatField(), URLField(), JSONField(), TimeField())
        for v in (nothing, "", Any[], Dict{String,Any}())
            f.kind !== :json && v isa Union{AbstractVector,AbstractDict} && continue
            @test dff(v, f) == E
        end
    end
    # test_empty_value_database_default_display_for_field / test_empty_value_display_choices
    @test dff(Juango.DB_DEFAULT, IntegerField()) == E
    @test dff(nothing, CharField(max_length = 10, choices = [(nothing, "test_none")])) == "test_none"
    # test_empty_value_display_booleanfield
    for v in (nothing, Juango.DB_DEFAULT)
        @test string(dff(v, BooleanField(null = true))) == "<span class=\"unknown\" title=\"None\">?</span>"
    end
    # test_json_display_for_field
    @test dff(Dict("a" => Dict("b" => "c")), JSONField()) == "{\"a\": {\"b\": \"c\"}}"
    @test dff(["a", "b"], JSONField()) == "[\"a\", \"b\"]"
    @test dff("a", JSONField()) == "\"a\""
    @test dff(Dict("a" => "你好 世界"), JSONField()) == "{\"a\": \"你好 世界\"}"
    # test_url_display_for_field / test_url_display_for_field_invalid_url
    @test string(dff("http://example.com", URLField())) == "<a href=\"http://example.com\">http://example.com</a>"
    for v in ("javascript:alert(1)", "data:text/html,<script>alert(1)</script>")
        @test dff(v, URLField()) == v
    end
    # test_number_formats_display_for_field / ..._with_thousand_separator_...
    @test dff(12345.6789, FloatField()) == "12345.6789"
    @test dff(Juango.Decimal("12345.6789"), DecimalField(max_digits = 10, decimal_places = 4)) == "12345.6789"
    @test dff(12345, IntegerField()) == "12345"
    override_settings(USE_THOUSAND_SEPARATOR = true) do
        @test dff(12345.6789, FloatField()) == "12,345.6789"
        @test dff(Juango.Decimal("12345.6789"), DecimalField(max_digits = 10, decimal_places = 4)) == "12,345.6789"
        @test dff(12345, IntegerField()) == "12,345"
    end
    # test_display_for_field_password_name_not_user_model
    @test dff("test", CharField(max_length = 200)) == "test"
    # test_list_display_for_value / ..._boolean / ..._boolean_database_default / ..._empty / test_list_display_for_database_default
    @test dfv([1, 2, 3]) == "1, 2, 3" && dfv([1, 2, "buckle", "my", "shoe"]) == "1, 2, buckle, my, shoe"
    @test string(Admin.display_for_value(true, ""; boolean = true)) == "<span class=\"yes\" title=\"True\">✔</span>"
    @test string(Admin.display_for_value(false, ""; boolean = true)) == "<span class=\"no\" title=\"False\">✘</span>"
    @test Admin.display_for_value(true, "") == "True" && Admin.display_for_value(false, "") == "False"
    @test string(Admin.display_for_value(Juango.DB_DEFAULT, ""; boolean = true)) == "<span class=\"unknown\" title=\"None\">?</span>"
    @test Admin.display_for_value(Juango.DB_DEFAULT, "") == ""
    @test all(v -> dfv(v) == E, (nothing, "", Any[], ())) && dfv(Juango.DB_DEFAULT) == E
    # test_list_display_for_value_consecutive_whitespace
    @test dfv("   ") == E && dfv("        cheeze") == "cheeze" && dfv("pizza       ") == "pizza" && dfv("       chicken        ") == "chicken"
    @test string(dfv(SafeString("  <em>soy chicken</em>  "))) == "  <em>soy chicken</em>  "
end
