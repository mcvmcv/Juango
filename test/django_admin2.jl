# More of Django's admin tests, ported (#227): admin_ordering.
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
    su = create(User; username = "admin", is_superuser = true)
    other = create(User; username = "other")
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
