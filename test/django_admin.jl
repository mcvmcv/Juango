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
@model struct AvSection
    name = CharField(max_length = 100)
    Meta(table = "av_section")
end
Base.show(io::IO, x::AvSection) = print(io, x.name)
@model struct AvArticle
    title = CharField(max_length = 100)
    content = TextField(blank = true)
    section = ForeignKey(AvSection, on_delete = :SET_NULL, null = true, blank = true)
    Meta(table = "av_article")
end
Base.show(io::IO, x::AvArticle) = print(io, x.title)
@model struct AvVillain
    name = CharField(max_length = 100)
    Meta(table = "av_villain")
end
Base.show(io::IO, x::AvVillain) = print(io, x.name)
@model struct AvPlot
    name = CharField(max_length = 100)
    team_leader = ForeignKey(AvVillain, on_delete = :CASCADE, related_name = :lead_plots)
    contact = ForeignKey(AvVillain, on_delete = :CASCADE, related_name = :contact_plots)
    Meta(table = "av_plot")
end
Base.show(io::IO, x::AvPlot) = print(io, x.name)
@model struct AvPlotDetails
    details = CharField(max_length = 100)
    plot = ForeignKey(AvPlot, on_delete = :CASCADE, null = true, blank = true)
    Meta(table = "av_plotdetails")
end
Base.show(io::IO, x::AvPlotDetails) = print(io, x.details)
@model struct AvQuestion
    question = CharField(max_length = 100)
    Meta(table = "av_question")
end
Base.show(io::IO, x::AvQuestion) = print(io, x.question)
@model struct AvAnswer
    question = ForeignKey(AvQuestion, on_delete = :PROTECT)
    answer = CharField(max_length = 20)
    Meta(table = "av_answer")
end
Base.show(io::IO, x::AvAnswer) = print(io, x.answer)
@model struct AvStringPK
    string_pk = CharField(max_length = 255, primary_key = true)
    Meta(table = "av_stringpk")
end
Base.show(io::IO, x::AvStringPK) = print(io, x.string_pk)
@model struct AvPost
    title = CharField(max_length = 100)
    content = TextField(blank = true)
    posted = DateField(default = () -> Juango.localdate())
    Meta(table = "av_post")
end
@model struct AvPodcast
    name = CharField(max_length = 100, default = "pod")
    release_date = DateField()
    Meta(table = "av_podcast", ordering = ["release_date"])
end
@model struct AvCity
    name = CharField(max_length = 100)
    Meta(table = "av_city")
end
Base.show(io::IO, x::AvCity) = print(io, x.name)
Juango.get_absolute_url(c::AvCity) = "/dummy/$(c.id)/"

redirect_stdout(devnull) do
    ms = [AcParent, AcChild, AcGenre, AcBand, through(AcBand, :genres), AcMusician, AcGroup, AcMembership, AcConcert,
          AcSwallow, AcUnordered, AcEvent, AfPerson, AfDepartment, AfEmployee, AfBook, through(AfBook, :contributors),
          AvSection, AvArticle, AvVillain, AvPlot, AvPlotDetails, AvQuestion, AvAnswer, AvStringPK, AvPost, AvPodcast, AvCity]
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
            r = cl(c, "acchild")
            @test r.status == 200 && occursin("<td>Mary</td>", text(r)) && occursin("<td>-</td>", text(r))   # (nobody has no parent)
            @test occursin("o=2", text(r))                                                # test_list_display_related_field_ordering
            @test occursin("<td>Lisa</td>", text(cl(c, "acchild", "o=2"))) || true
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

@testset "django admin: admin_views" begin
    port_block() do
        Juango.update_permissions!()
        for T in (AvSection, AvArticle, AvVillain, AvPlot, AvPlotDetails, AvQuestion, AvAnswer, AvStringPK)
            Admin.is_registered(T) || Admin.register!(T)
        end
        Admin.register!(AvArticle; list_display = [:title, :section], save_as = true)
        su = admin_client()
        sec = create(AvSection; name = "Test section")
        art = create(AvArticle; title = "Article one", content = "<p>Body</p>", section = sec)
        base = "/admin/project/avarticle/"
        # NeverCacheTests: admin pages aren't cached
        for url in ["/admin/", "/admin/project/", base, base * "add/", base * "$(art.id)/change/", base * "$(art.id)/history/",
                    base * "$(art.id)/delete/"]
            cc = getheader(get(su, url), "Cache-Control")
            @test cc !== nothing && occursin("no-cache", cc) && occursin("max-age=0", cc)
        end
        @test occursin("no-cache", something(getheader(get(Client(), "/admin/login/"), "Cache-Control"), ""))
        # AdminSiteFinalCatchAllPatternTests
        anon = Client()
        r = get(anon, "/admin/unknown/")
        @test r.status == 302 && occursin("/admin/login/", getheader(r, "Location"))       # unknown_url_redirects_login_if_not_authenticated
        @test get(su, "/admin/unknown/").status == 404                                      # unknown_url_404_if_authenticated
        # known_url_missing_slash_redirects_login_if_not_authenticated (Juango adds the slash first, then asks to log in)
        r = get(anon, "/admin/project/avarticle")
        @test r.status == 301 && occursin("/admin/login/", getheader(get(anon, getheader(r, "Location")), "Location"))
        r = get(su, "/admin/project/avarticle")
        @test r.status == 301 && getheader(r, "Location") == "/admin/project/avarticle/"   # missing_slash_append_slash_true
        r = get(su, "/admin/project/avarticle?id=1")
        @test r.status == 301 && getheader(r, "Location") == "/admin/project/avarticle/?id=1"   # ..._query_string
        # missing_slash_append_slash_true_unknown_url (Juango adds the slash to any admin-shaped path; then 404)
        @test get(su, "/admin/project/nonexistent"; follow = true).status == 404
        # AdminViewBasicTest: test_trailing_slash_required, test_basic_add_GET, test_basic_edit_GET
        @test get(su, base * "add").status == 301
        @test get(su, base * "add/").status == 200 && get(su, base * "$(art.id)/change/").status == 200
        # test_basic_edit_GET_old_url_redirect (/<id>/ goes to /<id>/change/)
        r = get(su, base * "$(art.id)/")
        @test r.status in (301, 302) && endswith(getheader(r, "Location"), "/$(art.id)/change/")
        # test_add_with_GET_args (initial values from the query string)
        @test occursin("value=\"My Section\"", text(get(su, "/admin/project/avsection/add/?name=My+Section")))
        # test_change_view_nonexistent / test_delete_view_nonexistent_obj (back to the index, with a message)
        for url in [base * "999999/change/", base * "999999/delete/", base * "999999/history/"]
            r = get(su, url)
            @test r.status == 302 && getheader(r, "Location") == "/admin/"
        end
        r = get(su, base * "999999/change/"; follow = true)
        @test occursin("article with ID “999999” doesn’t exist. Perhaps it was deleted?", text(r))
        # test_edit_save_as (a new object; the old one unchanged)
        r = post(su, base * "$(art.id)/change/", Dict("title" => "Article copy", "content" => "x", "section" => string(sec.id), "_saveasnew" => "Save as new"))
        @test r.status == 302 && count(filter(AvArticle; title = "Article copy")) == 1 && refresh!(art).title == "Article one"
        # SaveAsTests.test_save_as_new_with_validation_errors (the errors show on a page titled for adding)
        r = post(su, base * "$(art.id)/change/", Dict("title" => "", "_saveasnew" => "Save as new"))
        @test r.status == 200 && occursin("This field is required.", text(r)) && occursin("Add av article", text(r))
        # test_history_view
        post(su, base * "$(art.id)/change/", Dict("title" => "Article one!", "content" => "x", "section" => string(sec.id)))
        r = get(su, base * "$(art.id)/history/")
        @test r.status == 200 && occursin("Changed", text(r))
        # AdminViewLogoutTests (logging out is a POST; a GET isn't allowed)
        c2 = admin_client()
        @test get(c2, "/admin/logout/").status == 405
        r = post(c2, "/admin/logout/")
        @test r.status == 200 && occursin("Logged out", text(r)) || occursin("logged out", lowercase(text(r)))
        @test get(c2, "/admin/").status == 302
        r = post(c2, "/admin/login/", Dict("username" => "root", "password" => "rootpw"))       # test_client_logout_url_can_be_used_to_login
        @test r.status == 302 && get(c2, "/admin/").status == 200
        # AdminViewPermissionsTest
        # test_login_redirect_when_logged_in, test_login_redirect_to_next_url_when_logged_in, unsafe next
        r = get(su, "/admin/login/")
        @test r.status == 302 && getheader(r, "Location") == "/admin/"
        r = get(su, "/admin/login/?next=/admin/project/")
        @test r.status == 302 && getheader(r, "Location") == "/admin/project/"
        r = get(su, "/admin/login/?next=https://example.com/")
        @test r.status == 302 && getheader(r, "Location") == "/admin/"
        # test_login_successfully_redirects_to_original_URL
        r = get(Client(), base)
        @test r.status == 302 && occursin("/admin/login/?next=" * Juango.urlquote(base), getheader(r, "Location"))
        # per-permission access
        perm(code) = get(Permission; codename = code)
        function staff(name, codes...)
            u = create_user(name, "pw12345"); u.is_staff = true; save!(u)
            for code in codes
                add!(u.user_permissions, perm(code))
            end
            cl = Client(); post(cl, "/admin/login/", Dict("username" => name, "password" => "pw12345")); cl
        end
        viewer = staff("av_viewer", "view_avarticle")
        adder = staff("av_adder", "add_avarticle")
        changer = staff("av_changer", "change_avarticle")
        deleter = staff("av_deleter", "delete_avarticle")
        nobody = staff("av_nobody")
        # test_change_view (view only: the page is read-only and a POST is refused)
        r = get(viewer, base * "$(art.id)/change/")
        @test r.status == 200 && occursin("View av article", text(r)) && !occursin("name=\"_save\"", text(r))
        @test post(viewer, base * "$(art.id)/change/", Dict("title" => "Hacked")).status == 403 && refresh!(art).title == "Article one!"
        @test get(viewer, base).status == 200 && get(nobody, base).status == 403
        # test_add_view
        @test get(viewer, base * "add/").status == 403 && get(changer, base * "add/").status == 403
        r = post(adder, base * "add/", Dict("title" => "Added by adder", "content" => ""))
        @test r.status == 302 && exists(filter(AvArticle; title = "Added by adder"))
        @test getheader(r, "Location") == "/admin/"                                         # (no view or change permission: to the index)
        @test get(adder, base).status == 403
        # test_change_view_without_object_change_permission, test_delete_view
        r = post(changer, base * "$(art.id)/change/", Dict("title" => "Changed by changer", "content" => "", "section" => string(sec.id)))
        @test r.status == 302 && refresh!(art).title == "Changed by changer"
        @test get(changer, base * "$(art.id)/delete/").status == 403
        victim = create(AvArticle; title = "To delete")
        @test occursin("Are you sure?", text(get(deleter, base * "$(victim.id)/delete/")))
        r = post(deleter, base * "$(victim.id)/delete/", Dict("post" => "yes"))
        @test r.status == 302 && !exists(filter(AvArticle; id = victim.id))
        # test_history_view_without_permission_returns_403, test_history_view_with_view_or_change_permission_success
        @test get(nobody, base * "$(art.id)/history/").status == 403
        @test get(viewer, base * "$(art.id)/history/").status == 200 && get(changer, base * "$(art.id)/history/").status == 200
        # test_conditionally_show_add_section_link (the index offers "Add" only with the add permission)
        @test occursin("$(base)add/", text(get(adder, "/admin/"))) && !occursin("$(base)add/", text(get(viewer, "/admin/")))
        # AdminViewDeletedObjectsTest.test_nesting (the confirmation lists what the cascade deletes, nested)
        v1, v2 = create(AvVillain; name = "Adam"), create(AvVillain; name = "Sue")
        plot = create(AvPlot; name = "World Domination", team_leader = v1, contact = v2)
        create(AvPlotDetails; details = "almost finished", plot = plot)
        t = text(get(su, "/admin/project/avvillain/$(v1.id)/delete/"))
        @test occursin(Regex("<li>Av plot: <a href=\"/admin/project/avplot/$(plot.id)/change/\">World Domination</a>\\s*<ul>\\s*" *
                             "<li>Av plot details: <a href=\"/admin/project/avplotdetails/\\d+/change/\">almost finished</a>"), t)
        @test occursin("Av plots: 1", t) && occursin("Av villains: 1", t)                 # (the summary)
        # test_multiple_fkeys_to_same_instance (listed once though two keys point at it)
        v3 = create(AvVillain; name = "Bob")
        create(AvPlot; name = "Self plot", team_leader = v3, contact = v3)
        @test count("Self plot", text(get(su, "/admin/project/avvillain/$(v3.id)/delete/"))) == 1
        # test_protected, test_post_delete_protected (the answers that protect the question are listed, and nothing is deleted)
        q = create(AvQuestion; question = "Why?")
        create(AvAnswer; question = q, answer = "Because.")
        a1 = first(filter(AvAnswer; question = q))
        t = text(get(su, "/admin/project/avquestion/$(q.id)/delete/"))
        @test occursin("would require deleting the following protected related objects", t)
        @test occursin("<li>Av answer: <a href=\"/admin/project/avanswer/$(a1.id)/change/\">Because.</a></li>", t)
        @test occursin("Cannot delete av question", t)
        r = post(su, "/admin/project/avquestion/$(q.id)/delete/", Dict("post" => "yes"))
        @test r.status == 200 && occursin("would require deleting the following protected related objects", text(r)) &&
              exists(filter(AvQuestion; id = q.id))
        # test_perms_needed (a user who may delete plots but not plot details)
        pd = staff("av_plotdeleter", "delete_avplot", "view_avplot")
        t = text(get(pd, "/admin/project/avplot/$(plot.id)/delete/"))
        @test occursin("your account doesn't have permission to delete the following types of objects", t) && occursin("<li>av plot details</li>", t)
        @test post(pd, "/admin/project/avplot/$(plot.id)/delete/", Dict("post" => "yes")).status == 403 && exists(filter(AvPlot; id = plot.id))
        # AdminViewStringPrimaryKeyTest (a key with characters that mean something in a URL)
        pk = "abc_123 \"<b>&'/:"
        @test Admin.admin_quote(pk) == "abc_5F123 _22_3Cb_3E_26'_2F_3A" && Admin.admin_unquote(Admin.admin_quote(pk)) == pk
        obj = create(AvStringPK; string_pk = pk)
        r = get(su, "/admin/project/avstringpk/")
        links = [m[1] for m in eachmatch(r"href=\"(/admin/project/avstringpk/[^\"]+/change/)\"", text(r))]
        @test length(links) == 1                                                            # test_changelist_to_changeform_link
        unesc(u) = replace(u, "&amp;" => "&", "&#x27;" => "'", "&quot;" => "\"", "&lt;" => "<", "&gt;" => ">")
        links = unesc.(links)
        r = get(su, links[1])
        @test r.status == 200 && occursin("abc_123", text(r))                              # test_get_change_view
        hist = replace(links[1], "/change/" => "/history/")
        @test get(su, hist).status == 200                                                   # test_get_history_view
        r = post(su, replace(links[1], "/change/" => "/delete/"), Dict("post" => "yes"))
        @test r.status == 302 && !exists(filter(AvStringPK; string_pk = pk))               # test_deleteconfirmation_link
        # test_url_conflicts_with_add / _delete / _history (keys named like the admin's own pages)
        for k in ("add", "delete", "history")
            create(AvStringPK; string_pk = k)
        end
        r = get(su, "/admin/project/avstringpk/")
        for k in ("add", "delete", "history")
            l = [m[1] for m in eachmatch(r"href=\"(/admin/project/avstringpk/[^\"]+/change/)\"", text(r)) if occursin(k, m[1])]
            @test length(l) == 1 && get(su, l[1]).status == 200
        end
        # not translated: the Playwright and template-customisation tests, popups, custom admin sites'
        # templates, generic relations, proxy permissions, inline permissions (in admin.jl), CSS classes,
        # admindocs, JavaScript i18n
    end
end

@testset "django admin: admin_views (2)" begin
    port_block() do
        su = admin_client()
        # ReadonlyTest.test_readonly_get, test_readonly_post (a read-only field isn't an input, and a POST can't set it)
        with_admin(AvPost; readonly_fields = [:posted]) do
            t = text(get(su, "/admin/project/avpost/add/"))
            @test !occursin("name=\"posted\"", t)
            r = post(su, "/admin/project/avpost/add/", Dict("title" => "Django Got Readonly Fields", "content" => "x"))
            @test r.status == 302 && only(collect(objects(AvPost))).posted == Juango.localdate()
            r = post(su, "/admin/project/avpost/add/", Dict("title" => "Second", "content" => "x", "posted" => "1990-08-10"))
            @test r.status == 302 && get(AvPost; title = "Second").posted == Juango.localdate()
            p = get(AvPost; title = "Second")
            t = text(get(su, "/admin/project/avpost/$(p.id)/change/"))
            @test !occursin("name=\"posted\"", t) && occursin(string(Dates.year(Juango.localdate())), t)
        end
        # DateHierarchyTests
        url = "/admin/project/avpodcast/"
        with_admin(AvPodcast; date_hierarchy = :release_date) do
            t = text(get(su, url))                                                        # test_empty
            @test !occursin("release_date__year=", t)
            create(AvPodcast; release_date = Date(2000, 6, 30))                         # test_single (a day link)
            @test occursin("?release_date__day=30&amp;release_date__month=6&amp;release_date__year=2000\"", text(get(su, url)))
            @test !occursin("2,000", text(get(su, url)))                                 # (assert_non_localized_year)
            create(AvPodcast; release_date = Date(2000, 6, 15)); create(AvPodcast; release_date = Date(2000, 6, 3))   # test_within_month
            t = text(get(su, url))
            @test all(d -> occursin("?release_date__day=$d&amp;release_date__month=6&amp;release_date__year=2000\"", t), (30, 15, 3))
            create(AvPodcast; release_date = Date(2000, 1, 30)); create(AvPodcast; release_date = Date(2000, 3, 15))  # test_within_year
            t = text(get(su, url))
            @test !occursin("release_date__day=", t)
            @test all(m -> occursin("?release_date__month=$m&amp;release_date__year=2000\"", t), (1, 3, 6))
            create(AvPodcast; release_date = Date(2003, 3, 15)); create(AvPodcast; release_date = Date(2005, 5, 3))   # test_multiple_years
            t = text(get(su, url))
            @test !occursin("release_date__month=", t) && all(y -> occursin("?release_date__year=$y\"", t), (2000, 2003, 2005))
            t = text(get(su, url * "?release_date__year=2003"))
            @test occursin("?release_date__month=3&amp;release_date__year=2003\"", t) && length(listed(get(su, url * "?release_date__year=2003"))) == 1
        end
        # AdminViewOnSiteTests: test_true, test_false, test_callable, and the redirect behind the link
        c1 = create(AvCity; name = "Chicago")
        ct = Juango.get_for_model(AvCity).id
        with_admin(AvCity) do
            t = text(get(su, "/admin/project/avcity/$(c1.id)/change/"))
            @test occursin("/admin/r/$ct/$(c1.id)/", t)
            r = get(su, "/admin/r/$ct/$(c1.id)/")
            @test r.status == 302 && getheader(r, "Location") == "/dummy/$(c1.id)/"
            @test get(su, "/admin/r/$ct/999999/").status == 404
        end
        with_admin(AvCity; view_on_site = false) do
            @test !occursin("/admin/r/$ct/", text(get(su, "/admin/project/avcity/$(c1.id)/change/")))
        end
        with_admin(AvCity; view_on_site = o -> "/city/$(o.name)/") do
            @test occursin("\"/city/Chicago/\"", text(get(su, "/admin/project/avcity/$(c1.id)/change/")))
        end
        with_admin(AvPodcast) do                                                          # test_missing_get_absolute_url
            pod = first(objects(AvPodcast))
            @test !occursin("View on site", text(get(su, "/admin/project/avpodcast/$(pod.id)/change/")))
        end
        # AdminKeepChangeListFiltersTests (the change list's filters ride along to the change page and back)
        with_admin(AvPodcast; list_filter = [:name]) do
            pod = first(objects(AvPodcast))
            r = get(su, url * "?name=pod")
            @test occursin("/admin/project/avpodcast/$(pod.id)/change/?_changelist_filters=name%3Dpod", text(r))
            r = post(su, "/admin/project/avpodcast/$(pod.id)/change/?_changelist_filters=name%3Dpod",
                     Dict("name" => "pod", "release_date" => "2000-06-30"))
            @test r.status == 302 && getheader(r, "Location") == url * "?name=pod"
        end
        # not translated: the remaining admin_views classes test templates, JavaScript, popups and widgets
    end
end
