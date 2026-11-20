# Django's admin tests, ported (#227): tests/admin_changelist, admin_filters and admin_views.
# julia --project=test test/django_admin.jl   (see setup.jl)
#
# Django's tests build a ChangeList from a request and read its queryset; Juango's change list is
# a view, so these request the page as a logged-in superuser and read the rows it lists (each row's
# "_selected_action" checkbox carries its primary key). Each test keeps its Django name in a
# comment; tests of Python internals are listed at the end of each testset.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct AcParent
    name = CharField(max_length = 128)
    Meta(table = "ac_parent")
end
@model struct AcChild
    parent = ForeignKey(AcParent, on_delete = :SET_NULL, null = true, blank = true)
    name = CharField(max_length = 30, blank = true)
    age = IntegerField(null = true, blank = true)
    Meta(table = "ac_child")
end
Base.show(io::IO, c::AcChild) = print(io, c.name)
@model struct AcGenre
    name = CharField(max_length = 20)
    Meta(table = "ac_genre")
end
@model struct AcBand
    name = CharField(max_length = 20)
    nr_of_members = PositiveIntegerField()
    genres = ManyToManyField(AcGenre)
    Meta(table = "ac_band")
end
@model struct AcMusician
    name = CharField(max_length = 30)
    age = IntegerField(null = true, blank = true)
    Meta(table = "ac_musician")
end
@model struct AcGroup
    name = CharField(max_length = 30)
    members = ManyToManyField(AcMusician; through = :AcMembership)
    Meta(table = "ac_group")
end
@model struct AcMembership
    music = ForeignKey(AcMusician, on_delete = :CASCADE)
    group = ForeignKey(AcGroup, on_delete = :CASCADE)
    role = CharField(max_length = 15)
    Meta(table = "ac_membership")
end
@model struct AcConcert
    name = CharField(max_length = 30)
    group = ForeignKey(AcGroup, on_delete = :CASCADE)
    Meta(table = "ac_concert")
end
@model struct AcSwallow
    origin = CharField(max_length = 255)
    load = FloatField()
    speed = FloatField()
    flag = BooleanField(default = false)
    Meta(table = "ac_swallow", ordering = ["speed", "load"])
end
@model struct AcUnordered
    name = CharField(max_length = 255)
    bool = BooleanField(default = true)
    Meta(table = "ac_unordered")
end
@model struct AcEvent
    date = DateField()
    Meta(table = "ac_event")
end
redirect_stdout(devnull) do
    ms = [AcParent, AcChild, AcGenre, AcBand, through(AcBand, :genres), AcMusician, AcGroup, AcMembership, AcConcert,
          AcSwallow, AcUnordered, AcEvent]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

"A client logged in as a superuser."
function admin_client()
    root_user()
    c = Client()
    post(c, "/admin/login/", Dict("username" => "root", "password" => "rootpw"))
    c
end
"The primary keys of the rows a change list page shows, in order."
listed(r) = [m[1] for m in eachmatch(r"name=\"_selected_action\" value=\"([^\"]+)\"", text(r))]
cl(c, model, query = "") = get(c, "/admin/project/$model/" * (isempty(query) ? "" : "?" * query))
"Re-register a model's admin for one test."
function with_admin(f, T; kw...)
    key = Admin.admin_key(T)
    old = get(Admin.site.registry, key, nothing)
    Admin.register!(T; kw...)
    try
        f()
    finally
        old === nothing ? Admin.unregister!(T) : (Admin.site.registry[key] = old)
    end
end

@testset "django admin: admin_changelist" begin
    port_block() do
        c = admin_client()
        # test_many_search_terms (every word must match; a quoted phrase is one word)
        mary = create(AcParent; name = "Mary")
        create(AcChild; parent = mary, name = "Danielle"); create(AcChild; parent = mary, name = "Daniel")
        other = create(AcParent; name = "Lisa")
        create(AcChild; parent = other, name = "Danielle Smith")
        with_admin(AcParent; search_fields = [:acchild__name]) do
            @test listed(cl(c, "acparent", "q=Danielle")) |> length == 2
            @test listed(cl(c, "acparent", "q=Danielle+Smith")) == [string(other.id)]
            @test listed(cl(c, "acparent", "q=%22Danielle+Smith%22")) == [string(other.id)]
            # test_distinct_for_non_unique_related_object_in_search_fields (Mary has two matching children: listed once)
            @test listed(cl(c, "acparent", "q=Daniel")) |> sort == sort(string.([mary.id, other.id]))
        end
        # test_related_field_multiple_search_terms
        with_admin(AcChild; search_fields = [:name, :parent__name]) do
            @test listed(cl(c, "acchild", "q=Mary+Daniel")) |> length == 2           # Danielle and Daniel, children of Mary
            @test listed(cl(c, "acchild", "q=Lisa+Smith")) |> length == 1
            @test isempty(listed(cl(c, "acchild", "q=Lisa+Daniel+Mary")))
        end
        # test_multiple_search_fields, test_builtin_lookup_in_search_fields (a lookup in the field, prefixes)
        with_admin(AcChild; search_fields = [:name__istartswith]) do
            @test listed(cl(c, "acchild", "q=dan")) |> length == 3
            @test isempty(listed(cl(c, "acchild", "q=iel")))
        end
        with_admin(AcChild; search_fields = ["=name"]) do
            @test listed(cl(c, "acchild", "q=daniel")) |> length == 1
        end
        with_admin(AcChild; search_fields = ["^name"]) do
            @test listed(cl(c, "acchild", "q=Danielle")) |> length == 2
            @test isempty(listed(cl(c, "acchild", "q=Smith")))
        end
        # test_pk_in_search_fields, test_exact_lookup_with_invalid_value (a word that isn't a number skips that field)
        kid = first(filter(AcChild; name = "Daniel"))
        with_admin(AcChild; search_fields = [:name, :pk__exact]) do
            @test listed(cl(c, "acchild", "q=$(kid.id)")) == [string(kid.id)]
            @test listed(cl(c, "acchild", "q=Smith")) |> length == 1                  # "Smith" isn't an id: only the name is searched
        end
        with_admin(AcChild; search_fields = [:age__exact]) do
            kid.age = 7; save!(kid)
            @test listed(cl(c, "acchild", "q=7")) == [string(kid.id)]
            @test isempty(listed(cl(c, "acchild", "q=abc")))                          # no field can take it: nothing
        end
        # test_exact_lookup_mixed_terms
        with_admin(AcChild; search_fields = [:name, :age__exact]) do
            @test listed(cl(c, "acchild", "q=Daniel+7")) == [string(kid.id)]
        end
        # test_exact_boolean_lookup_is_case_insensitive / explicit values
        create(AcSwallow; origin = "Africa", load = 1.0, speed = 2.0, flag = true)
        create(AcSwallow; origin = "Europe", load = 2.0, speed = 1.0, flag = false)
        with_admin(AcSwallow; search_fields = [:origin, :flag__exact]) do
            @test listed(cl(c, "acswallow", "q=true")) |> length == 1
            @test listed(cl(c, "acswallow", "q=0")) |> length == 1
            @test listed(cl(c, "acswallow", "q=Africa")) |> length == 1
            @test isempty(listed(cl(c, "acswallow", "q=yes")))                       # (not a strict boolean, not an origin)
        end
        # test_ordering_from_model_meta (the model's ordering, then the key)
        with_admin(AcSwallow; list_display = [:origin, :load, :speed]) do
            @test listed(cl(c, "acswallow")) == string.([first(filter(AcSwallow; origin = "Europe")).id, first(filter(AcSwallow; origin = "Africa")).id])
        end
        # test_distinct_for_m2m_in_list_filter (a band in two matching genres is listed once)
        rock, jazz = create(AcGenre; name = "Rock"), create(AcGenre; name = "Jazz")
        band = create(AcBand; name = "Blues Band", nr_of_members = 5)
        add!(band.genres, rock, jazz)
        with_admin(AcBand; list_filter = [:genres], search_fields = [:genres__name]) do
            @test listed(cl(c, "acband", "q=a")) == [string(band.id)]               # (Rock? no; Jazz and Blues: one row)
            r = cl(c, "acband", "genres__id__exact=$(rock.id)")
            @test r.status == 200 && listed(r) == [string(band.id)]
        end
        # test_distinct_for_through_m2m_in_list_filter / _in_search_fields
        lead = create(AcMusician; name = "Vox")
        grp = create(AcGroup; name = "The Band")
        create(AcMembership; music = lead, group = grp, role = "Lead")
        create(AcMembership; music = lead, group = grp, role = "Bass")
        with_admin(AcGroup; search_fields = [:members__name]) do
            @test listed(cl(c, "acgroup", "q=Vox")) == [string(grp.id)]
        end
        # test_no_distinct_for_m2m_in_list_filter_without_params / a plain search doesn't repeat rows either
        with_admin(AcGroup; search_fields = [:name]) do
            @test listed(cl(c, "acgroup", "q=Band")) == [string(grp.id)]
        end
        # test_result_list_empty_changelist_value, test_result_list_set_empty_value_display_in_model_admin
        nobody = create(AcChild; name = "")
        with_admin(AcChild; list_display = [:name, :parent]) do
            @test occursin("<td>-</td>", text(cl(c, "acchild")))                     # (nobody's parent)
        end
        with_admin(AcChild; list_display = [:name, :parent], empty_value_display = "???") do
            @test occursin("???", text(cl(c, "acchild")))
        end
        # test_pagination, test_pagination_page_range, test_show_all
        for i in 1:30
            create(AcUnordered; name = "obj $i")
        end
        with_admin(AcUnordered; list_per_page = 10, list_display = [:name]) do
            @test length(listed(cl(c, "acunordered"))) == 10
            @test length(listed(cl(c, "acunordered", "page=3"))) == 10
            @test isempty(intersect(listed(cl(c, "acunordered", "page=1")), listed(cl(c, "acunordered", "page=2"))))
            @test occursin("Page 1 of 3", text(cl(c, "acunordered")))
            @test length(listed(cl(c, "acunordered", "all="))) == 30
        end
        with_admin(AcUnordered; list_per_page = 10, list_max_show_all = 20) do
            @test length(listed(cl(c, "acunordered", "all="))) == 10                  # more than list_max_show_all: paged
        end
        # test_deterministic_order_for_unordered_model (by the key, so pages don't overlap or skip rows)
        with_admin(AcUnordered; list_per_page = 10, list_display = [:name]) do
            seen = vcat([listed(cl(c, "acunordered", "page=$p")) for p in 1:3]...)
            @test length(unique(seen)) == 30
        end
        # test_dynamic_list_display, test_dynamic_search_fields, test_dynamic_list_filter (per request)
        with_admin(AcChild; get_list_display = req -> [:name, :age], get_search_fields = req -> [:name]) do
            r = cl(c, "acchild", "q=Daniel")
            @test occursin(">Age<", text(r)) || occursin("Age", text(r))
            @test length(listed(r)) == 3                                              # Danielle, Daniel, Danielle Smith
        end
        # test_search_help_text
        with_admin(AcChild; search_fields = [:name], search_help_text = "Search by name") do
            @test occursin("Search by name", text(cl(c, "acchild")))
        end
        # test_date_hierarchy_out_of_range (an impossible date is ignored, not a crash)
        create(AcEvent; date = Date(2020, 1, 1))
        with_admin(AcEvent; date_hierarchy = :date) do
            @test cl(c, "acevent", "date__year=2020&date__month=13").status in (200, 302)
            @test cl(c, "acevent", "date__year=99999").status in (200, 302)
        end
        # test_list_display_related_field (a column through a foreign key)
        with_admin(AcChild; list_display = [:name, :parent__name]) do
            @test occursin("Mary", text(cl(c, "acchild")))
        end
        # test_no_list_display_links, test_dynamic_list_display_links
        with_admin(AcChild; list_display = [:name, :age], list_display_links = []) do
            @test !occursin("/admin/project/acchild/$(kid.id)/change/", text(cl(c, "acchild")))
        end
        with_admin(AcChild; list_display = [:name, :age], list_display_links = [:age]) do
            @test occursin("/admin/project/acchild/$(kid.id)/change/", text(cl(c, "acchild")))
        end
        # test_list_editable_atomicity / test_result_list_editable (a bad row saves nothing)
        a, b = create(AcSwallow; origin = "A", load = 1.0, speed = 1.0), create(AcSwallow; origin = "B", load = 2.0, speed = 2.0)
        with_admin(AcSwallow; list_display = [:origin, :load, :speed], list_editable = [:load, :speed]) do
            r = cl(c, "acswallow")
            ids = listed(r)
            data = Dict{String,Any}("form-TOTAL_FORMS" => string(length(ids)), "form-INITIAL_FORMS" => string(length(ids)),
                                    "form-MIN_NUM_FORMS" => "0", "form-MAX_NUM_FORMS" => "1000", "_save" => "Save")
            for (i, id) in enumerate(ids)
                o = get(AcSwallow; id = parse(Int, id))
                data["form-$(i-1)-id"] = id
                data["form-$(i-1)-load"] = string(o.load)
                data["form-$(i-1)-speed"] = string(o.speed)
            end
            ia = findfirst(==(string(a.id)), ids) - 1
            ib = findfirst(==(string(b.id)), ids) - 1
            data["form-$ia-load"] = "9.0"
            data["form-$ib-speed"] = "not a number"
            r = post(c, "/admin/project/acswallow/", data)
            @test r.status == 200 && refresh!(a).load == 1.0                         # nothing saved
            data["form-$ib-speed"] = "3.0"
            r = post(c, "/admin/project/acswallow/", data)
            @test r.status == 302 && refresh!(a).load == 9.0 && refresh!(b).speed == 3.0
        end
        # not translated: test_repr, the select_related tests (queries, not pages), test_custom_paginator,
        # test_multiuser_edit, the get_edited_object_ids / get_list_editable_queryset internals, the
        # selenium tests (row selection, pending-edit warnings, collapsed filters), the template tag
        # tests (result_list, the admin_list tags), test_custom_user_pk_not_named_id, the custom lookup
        # tests (register_lookup on a model field)
    end
end
