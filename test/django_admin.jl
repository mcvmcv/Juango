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
@model struct AfPerson
    username = CharField(max_length = 30)
    email = CharField(max_length = 60, blank = true)
    Meta(table = "af_person")
end
Base.show(io::IO, p::AfPerson) = print(io, p.username)
@model struct AfDepartment
    code = CharField(max_length = 4, unique = true)
    description = CharField(max_length = 50, blank = true, null = true)
    Meta(table = "af_department")
end
Base.show(io::IO, d::AfDepartment) = print(io, d.description === nothing ? d.code : d.description)
@model struct AfEmployee
    department = ForeignKey(AfDepartment, on_delete = :CASCADE)
    name = CharField(max_length = 100)
    Meta(table = "af_employee", ordering = ["name"])
end
Base.show(io::IO, e::AfEmployee) = print(io, e.name)
@model struct AfBook
    title = CharField(max_length = 50)
    year = PositiveIntegerField(null = true, blank = true)
    author = ForeignKey(AfPerson, on_delete = :SET_NULL, related_name = :books_authored, blank = true, null = true)
    contributors = ManyToManyField(AfPerson; related_name = :books_contributed, blank = true)
    employee = ForeignKey(AfEmployee, on_delete = :SET_NULL, blank = true, null = true, related_name = :books)
    is_best_seller = BooleanField(default = false, null = true)
    availability = BooleanField(choices = [(false, "Paid"), (true, "Free"), (nothing, "Obscure")], null = true)
    date_registered = DateField(null = true)
    no = IntegerField(blank = true, null = true)
    status = CharField(max_length = 1, choices = [("p", "Published"), ("d", "Draft")], blank = true, null = true)
    Meta(table = "af_book", ordering = ["-id"])
end
Base.show(io::IO, b::AfBook) = print(io, b.title)

redirect_stdout(devnull) do
    ms = [AcParent, AcChild, AcGenre, AcBand, through(AcBand, :genres), AcMusician, AcGroup, AcMembership, AcConcert,
          AcSwallow, AcUnordered, AcEvent, AfPerson, AfDepartment, AfEmployee, AfBook, through(AfBook, :contributors)]
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
            create(AcBand; name = "Silent", nr_of_members = 1)
            @test listed(cl(c, "acband", "genres__id__exact=$(jazz.id)")) == [string(band.id)]
            @test length(listed(cl(c, "acband", "genres__isnull=True"))) == 1
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

@testset "django admin: admin_filters" begin
    port_block() do
        c = admin_client()
        alfred = create(AfPerson; username = "alfred", email = "alfred@example.com")
        bob = create(AfPerson; username = "bob", email = "bob@example.com")
        lisa = create(AfPerson; username = "lisa", email = "lisa@example.com")
        design = create(AfDepartment; code = "DSN", description = "Design")
        dev = create(AfDepartment; code = "DEV", description = "Development")
        john = create(AfEmployee; department = dev, name = "John Blue")
        jack = create(AfEmployee; department = design, name = "Jack Red")
        today = Juango.localdate()
        bio = create(AfBook; title = "Julius Caesar", year = 1993, author = alfred, is_best_seller = false, date_registered = today,
                     availability = true, employee = john, status = "p")
        django = create(AfBook; title = "The Django Book", year = nothing, author = bob, is_best_seller = nothing,
                        date_registered = today - Day(1) < Date(year(today), month(today), 1) ? today : today - Day(1),
                        availability = false, no = 103, employee = jack, status = "d")
        gipsy = create(AfBook; title = "Gipsy guitar for dummies", year = 2002, is_best_seller = true,
                       date_registered = Date(year(today) - 1, 6, 1), availability = nothing, no = 207)
        djangonaut = create(AfBook; title = "Djangonaut: an art of living", year = 2009, author = alfred, is_best_seller = true,
                            date_registered = nothing, no = 103)
        add!(gipsy.contributors, bob, lisa)
        add!(django.contributors, bob)
        ids(r) = sort(parse.(Int, listed(r)))
        books(q) = ids(cl(c, "afbook", q))
        # test_datefieldlistfilter (Today, Past 7 days, This month, This year, No date, Has date)
        with_admin(AfBook; list_filter = [:date_registered]) do
            r = cl(c, "afbook")
            @test all(l -> occursin(l, text(r)), ["Today", "Past 7 days", "This month", "This year", "No date", "Has date"])
            tom = today + Day(1)
            @test books("date_registered__gte=$today&date_registered__lt=$tom") == sort([bio.id, (django.date_registered == today ? [django.id] : [])...])
            @test books("date_registered__gte=$(Date(year(today), 1, 1))&date_registered__lt=$(Date(year(today) + 1, 1, 1))") == sort([bio.id, django.id])
            @test books("date_registered__isnull=True") == [djangonaut.id]
            @test books("date_registered__isnull=False") == sort([bio.id, django.id, gipsy.id])
            # (the links carry Django's parameters)
            @test occursin("date_registered__gte=$(today)", replace(text(r), "&amp;" => "&"))
        end
        # test_allvaluesfieldlistfilter
        with_admin(AfBook; list_filter = [:year]) do
            r = cl(c, "afbook")
            @test occursin("1993", text(r)) && occursin("2002", text(r)) && occursin("?year=2002", replace(text(r), "&amp;" => "&"))
            @test books("year=2002") == [gipsy.id]
            @test books("year__isnull=True") == [django.id]
        end
        # test_relatedfieldlistfilter_foreignkey (every person, and "-" for none)
        with_admin(AfBook; list_filter = [:author]) do
            r = cl(c, "afbook")
            @test occursin("alfred", text(r)) && occursin("bob", text(r)) && occursin("lisa", text(r))
            @test occursin("author__id__exact=$(alfred.id)", text(r)) && occursin("author__isnull=True", text(r))
            @test books("author__id__exact=$(alfred.id)") == sort([bio.id, djangonaut.id])
            @test books("author__isnull=True") == [gipsy.id]
            # test_fieldlistfilter_invalid_lookup_parameters (not a key: the filters are dropped, ?e=1)
            r = cl(c, "afbook", "author__id__exact=StringNotInteger!")
            @test r.status == 302 && endswith(getheader(r, "Location"), "?e=1")
            r = get(c, getheader(r, "Location"))
            @test r.status == 200 && length(listed(r)) == 4
        end
        # test_relatedfieldlistfilter_foreignkey_ordering (in the related admin's ordering)
        with_admin(AfEmployee; ordering = ["name"]) do
            with_admin(AfBook; list_filter = [:employee]) do
                t = text(cl(c, "afbook"))
                @test findfirst("Jack Red", t)[1] < findfirst("John Blue", t)[1]
            end
        end
        with_admin(AfEmployee; ordering = ["-name"]) do
            with_admin(AfBook; list_filter = [:employee]) do
                t = text(cl(c, "afbook"))
                @test findfirst("John Blue", t)[1] < findfirst("Jack Red", t)[1]
            end
        end
        # test_relatedfieldlistfilter_manytomany
        with_admin(AfBook; list_filter = [:contributors]) do
            @test occursin("contributors__id__exact=$(bob.id)", text(cl(c, "afbook")))
            @test books("contributors__id__exact=$(bob.id)") == sort([django.id, gipsy.id])
            @test books("contributors__id__exact=$(lisa.id)") == [gipsy.id]
            @test books("contributors__isnull=True") == sort([bio.id, djangonaut.id])
        end
        # test_relatedfieldlistfilter_reverse_relationships
        with_admin(AfPerson; list_filter = [:books_authored, :books_contributed]) do
            r = cl(c, "afperson")
            @test occursin("books_authored__id__exact=$(bio.id)", text(r)) && occursin("books_contributed__id__exact=$(gipsy.id)", text(r))
            @test ids(cl(c, "afperson", "books_authored__id__exact=$(bio.id)")) == [alfred.id]
            @test ids(cl(c, "afperson", "books_contributed__id__exact=$(gipsy.id)")) == sort([bob.id, lisa.id])
            @test ids(cl(c, "afperson", "books_authored__isnull=True")) == [lisa.id]
        end
        # test_relatedonlyfieldlistfilter_foreignkey (only the people who wrote a book)
        with_admin(AfBook; list_filter = [:author => :related_only]) do
            r = cl(c, "afbook")
            @test occursin("author__id__exact=$(alfred.id)", text(r)) && occursin("author__id__exact=$(bob.id)", text(r))
            @test !occursin("author__id__exact=$(lisa.id)", text(r))
        end
        # test_relatedonlyfieldlistfilter_manytomany
        with_admin(AfBook; list_filter = [:contributors => :related_only]) do
            r = cl(c, "afbook")
            @test occursin("contributors__id__exact=$(lisa.id)", text(r)) && !occursin("contributors__id__exact=$(alfred.id)", text(r))
        end
        # test_booleanfieldlistfilter (Yes, No, Unknown for a nullable one)
        with_admin(AfBook; list_filter = [:is_best_seller]) do
            r = cl(c, "afbook")
            @test occursin("Unknown", text(r)) && occursin("is_best_seller__exact=1", text(r))
            @test books("is_best_seller__exact=0") == [bio.id]
            @test books("is_best_seller__exact=1") == sort([gipsy.id, djangonaut.id])
            @test books("is_best_seller__isnull=True") == [django.id]
        end
        # test_booleanfieldlistfilter_choices (the choices' labels)
        with_admin(AfBook; list_filter = [:availability]) do
            r = cl(c, "afbook")
            @test occursin("Paid", text(r)) && occursin("Free", text(r))
            @test books("availability__exact=1") == [bio.id]
            @test books("availability__exact=0") == [django.id]
        end
        # test_choicesfieldlistfilter_has_none_choice, a choices field
        with_admin(AfBook; list_filter = [:status]) do
            r = cl(c, "afbook")
            @test occursin("Published", text(r)) && occursin("status__exact=p", text(r))
            @test books("status__exact=d") == [django.id]
        end
        # test_fieldlistfilter_underscorelookup_tuple (a field through a relation)
        with_admin(AfBook; list_filter = [:author__email]) do
            r = cl(c, "afbook")
            @test occursin("alfred@example.com", text(r)) && occursin("author__email=alfred%40example.com", text(r))
            @test books("author__email=alfred%40example.com") == sort([bio.id, djangonaut.id])
        end
        with_admin(AfBook; list_filter = [:employee__department]) do
            r = cl(c, "afbook")
            @test occursin("employee__department__id__exact=$(dev.id)", text(r))
            @test books("employee__department__id__exact=$(dev.id)") == [bio.id]
        end
        # test_two_characters_long_field
        with_admin(AfBook; list_filter = [:no]) do
            @test books("no=207") == [gipsy.id]
            @test books("no=103") == sort([django.id, djangonaut.id])
        end
        # test_simplelistfilter
        decade = Admin.ListFilter("publication decade", "publication-decade";
                                  lookups = (req, ma) -> [("the 80s", "the 1980's"), ("the 90s", "the 1990's"), ("the 00s", "the 2000's")],
                                  queryset = (req, qs, v) -> v == "the 90s" ? filter(qs; year__gte = 1990, year__lte = 1999) :
                                                             v == "the 00s" ? filter(qs; year__gte = 2000, year__lte = 2009) : qs)
        with_admin(AfBook; list_filter = [decade]) do
            r = cl(c, "afbook")
            @test occursin("publication decade", text(r)) && occursin("the 1990&#x27;s", text(r))
            @test books("publication-decade=the+90s") == [bio.id]
            @test books("publication-decade=the+00s") == sort([gipsy.id, djangonaut.id])
        end
        # test_emptylistfieldfilter
        with_admin(AfBook; list_filter = [:author => :empty, :title => :empty]) do
            @test books("author__isempty=1") == [gipsy.id]
            @test books("author__isempty=0") == sort([bio.id, django.id, djangonaut.id])
            @test isempty(books("title__isempty=1"))
        end
        # test_emptylistfieldfilter_invalid_lookup_parameters
        with_admin(AfBook; list_filter = [:author => :empty]) do
            r = cl(c, "afbook", "author__isempty=42")
            @test r.status == 302 && endswith(getheader(r, "Location"), "?e=1")
        end
        # test_facets_always, test_facets_filter (each choice with its count)
        with_admin(AfBook; list_filter = [:is_best_seller, :author], show_facets = :always) do
            t = text(cl(c, "afbook"))
            @test occursin("All (4)", t) && occursin("Yes (2)", t) && occursin("alfred (2)", t)
            t = text(cl(c, "afbook", "is_best_seller__exact=1"))
            @test occursin("alfred (1)", t)                                          # (counting the other filter)
        end
        # test_list_filter_queryset_filtered_by_default / bookmarked lookups (Django applies other lookups
        # on the model's own fields; through a relation only one a list filter names; an unknown one: ?e=1)
        with_admin(AfBook; list_filter = [:author]) do
            @test books("title__startswith=Gipsy") == [gipsy.id]
            @test books("year__gte=2000") == sort([gipsy.id, djangonaut.id])
            @test books("author__username=bob") == [django.id]
            @test cl(c, "afbook", "employee__name=John+Blue").status == 400            # (not a list filter's relation)
            r = cl(c, "afbook", "nonexistent=1")
            @test r.status == 302 && endswith(getheader(r, "Location"), "?e=1")
            r = cl(c, "afbook", "year=notanumber")
            @test r.status == 302 && endswith(getheader(r, "Location"), "?e=1")
        end
        # not translated: test_datefieldlistfilter_with_time_zone_support (Juango's date bounds are in the
        # current time zone; covered by the date tests above), the generic relation tests, the custom
        # divider and facet-count internals, SimpleListFilter's Python class checks (a title is required)
    end
end
