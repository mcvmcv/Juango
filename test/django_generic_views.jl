# Django's generic views tests, ported (#227): tests/generic_views (test_base, test_list, test_detail,
# test_edit, test_dates).
# julia --project=test test/django_generic_views.jl   (see setup.jl)
#
# Juango's generic views are values built with options (Django's class attributes) and hooks (its
# methods). Django's tests read response.context; here each view's get_context_data hook keeps the
# context it was given (DGV_CTX), and each template says its own name, for Django's
# assertTemplateUsed. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DgvArtist
    name = CharField(max_length = 100)
    Meta(table = "dgv_artist", ordering = ["name"], verbose_name = "professional artist")
end
@model struct DgvAuthor
    name = CharField(max_length = 100)
    slug = SlugField()
    Meta(table = "dgv_author", ordering = ["name"])
end
@model struct DgvBook
    name = CharField(max_length = 255)
    slug = SlugField()
    pages = IntegerField()
    authors = ManyToManyField(DgvAuthor)
    pubdate = DateField()
    Meta(table = "dgv_book", ordering = ["-pubdate"])
end
@model struct DgvBookSigning
    event_date = DateTimeField()
    Meta(table = "dgv_booksigning")
end
Juango.get_absolute_url(a::DgvArtist) = "/detail/artist/$(a.id)/"

redirect_stdout(devnull) do
    ms = [DgvArtist, DgvAuthor, DgvBook, through(DgvBook, :authors), DgvBookSigning]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

const DGV_CTX = Ref{Any}(nothing)
dgv_cap(v, ctx) = (DGV_CTX[] = ctx; ctx)
"A generic view whose context is kept in DGV_CTX."
DGV(view, args...; kw...) = view(args...; get_context_data = dgv_cap, kw...)
dgv_ctx() = DGV_CTX[]
dgv_names(xs) = [x.name for x in xs]
const DGV_APP = Juango.modelmeta(DgvAuthor).app
for n in ["dgvauthor_list", "dgvauthor_objects", "dgvbook_list", "dgvauthor_detail", "dgvauthor_view",
          "dgvartist_detail", "dgvauthor_form", "dgvartist_form", "dgvauthor_confirm_delete", "dgvbook_archive",
          "dgvbook_archive_year", "dgvbook_archive_month", "dgvbook_archive_week", "dgvbook_archive_day", "dgvbook_detail",
          "dgvbooksigning_archive", "dgvbooksigning_archive_year", "dgvbooksigning_archive_month", "dgvbooksigning_archive_day",
          "dgvbooksigning_detail", "dgvbook_archive_objects"]
    mkpath(joinpath(TPL, DGV_APP))
    write(joinpath(TPL, DGV_APP, n * ".html"), "T:$DGV_APP/$n.html")
end
write(joinpath(TPL, "dgvartist_list.html"), "T:dgvartist_list.html")           # (Juango's own name, without the app)
write(joinpath(TPL, "dgv_about.html"), "T:dgv_about.html")
write(joinpath(TPL, "dgv_simple.html"), "T:dgv_simple.html foo={{ foo }} extra={{ extra }}")
write(joinpath(TPL, "dgv_form.html"), "T:dgv_form.html")

@form DgvContactForm begin
    name = CharField(max_length = 100)
    message = CharField()
end

function dgv_urls()
    B(view; kw...) = DGV(view, DgvBook; date_field = :pubdate, kw...)
    S(view; kw...) = DGV(view, DgvBookSigning; date_field = :event_date, kw...)
    [
    # test_base
    path("template/simple/<str:foo>/", TemplateView("dgv_simple.html")),
    path("template/extra_context/", TemplateView("dgv_simple.html"; extra_context = Dict("extra" => "e"))),
    path("redirect/", RedirectView("/bar/")),
    path("redirect/none/", RedirectView(nothing)),
    path("redirect/permanent/", RedirectView("/bar/"; permanent = true)),
    path("redirect/qs/", RedirectView("/bar/"; query_string = true)),
    path("redirect/sub/<int:object_id>/", RedirectView("/bar/%(object_id)d/")),
    path("redirect/named/<int:pk>/", RedirectView("dgv_artist_detail")),
    path("methods/", DGV(ListView, DgvAuthor; http_method_names = ["post"], template = "dgv_about.html")),
    # test_list
    path("list/authors/", DGV(ListView, DgvAuthor)),
    path("list/authors/paginated/", DGV(ListView, DgvAuthor; paginate_by = 30)),
    path("list/authors/paginated/<int:page>/", DGV(ListView, DgvAuthor; paginate_by = 30)),
    path("list/authors/paginated/custom_page_kwarg/", DGV(ListView, DgvAuthor; paginate_by = 30, page_kwarg = "pagina")),
    path("list/authors/paginated-orphaned/", DGV(ListView, DgvAuthor; paginate_by = 30, paginate_orphans = 2)),
    path("list/authors/notempty/", DGV(ListView, DgvAuthor; allow_empty = false)),
    path("list/authors/notempty/paginated/", DGV(ListView, DgvAuthor; allow_empty = false, paginate_by = 2)),
    path("list/authors/template_name_suffix/", DGV(ListView, DgvAuthor; template_name_suffix = "_objects")),
    path("list/authors/context_object_name/", DGV(ListView, DgvAuthor; context_object_name = "author_list2")),
    path("list/artists/", DGV(ListView, DgvArtist)),
    path("list/books/sorted/", DGV(ListView, DgvBook; ordering = "name")),
    path("list/books/sortedbypagesandnamedec/", DGV(ListView, DgvBook; ordering = ["pages", "-name"])),
    # test_detail
    path("detail/author/<int:pk>/", DGV(DetailView, DgvAuthor)),
    path("detail/author/byid/<int:id>/", DGV(DetailView, DgvAuthor)),
    path("detail/author/bycustompk/<int:foo>/", DGV(DetailView, DgvAuthor; pk_kwarg = :foo)),
    path("detail/author/byslug/<slug:slug>/", DGV(DetailView, DgvAuthor)),
    path("detail/author/bycustomslug/<slug:foo>/", DGV(DetailView, DgvAuthor; slug_kwarg = :foo)),
    path("detail/author/bypkignoreslug/<int:pk>-<slug:slug>/", DGV(DetailView, DgvAuthor)),
    path("detail/author/bypkandslug/<int:pk>-<slug:slug>/", DGV(DetailView, DgvAuthor; query_pk_and_slug = true)),
    path("detail/author/<int:pk>/template_name_suffix/", DGV(DetailView, DgvAuthor; template_name_suffix = "_view")),
    path("detail/author/<int:pk>/template_name/", DGV(DetailView, DgvAuthor; template = "dgv_about.html")),
    path("detail/author/<int:pk>/context_object_name/", DGV(DetailView, DgvAuthor; context_object_name = "thingy")),
    path("detail/artist/<int:pk>/", DGV(DetailView, DgvArtist); name = "dgv_artist_detail"),
    # test_edit
    path("edit/authors/create/", DGV(CreateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/")),
    path("edit/authors/create/interpolate_redirect/", DGV(CreateView, DgvAuthor; fields = [:name, :slug], success_url = "/edit/author/{id}/update/")),
    path("edit/authors/create/restricted/", DGV(CreateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/", login_required = true)),
    path("edit/authors/create/special/", DGV(CreateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/",
                                            context_object_name = "thingy", template = "dgv_form.html")),
    path("edit/artists/create/", DGV(CreateView, DgvArtist; fields = [:name])),
    path("edit/author/<int:pk>/update/", DGV(UpdateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/")),
    path("edit/author/<int:pk>/update/interpolate_redirect/", DGV(UpdateView, DgvAuthor; fields = [:name, :slug], success_url = "/edit/author/{id}/update/")),
    path("edit/author/<int:pk>/update/special/", DGV(UpdateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/",
                                                    context_object_name = "thingy", template = "dgv_form.html")),
    path("edit/artists/<int:pk>/update/", DGV(UpdateView, DgvArtist; fields = [:name])),
    path("edit/author/update/", DGV(UpdateView, DgvAuthor; fields = [:name, :slug], success_url = "/list/authors/",
                                   get_object = v -> first(objects(DgvAuthor)))),
    path("edit/author/<int:pk>/delete/", DGV(DeleteView, DgvAuthor; success_url = "/list/authors/")),
    path("edit/author/<int:pk>/delete/interpolate_redirect/", DGV(DeleteView, DgvAuthor; success_url = "/edit/authors/create/?deleted={id}")),
    path("edit/author/<int:pk>/delete/special/", DGV(DeleteView, DgvAuthor; success_url = "/list/authors/", context_object_name = "thingy")),
    path("contact/", DGV(FormView, DgvContactForm; template = "dgv_form.html", success_url = "/list/authors/")),
    # test_dates
    path("dates/books/", B(ArchiveIndexView)),
    path("dates/books/context_object_name/", B(ArchiveIndexView; context_object_name = "thingies")),
    path("dates/books/allow_empty/", B(ArchiveIndexView; allow_empty = true)),
    path("dates/books/template_name_suffix/", B(ArchiveIndexView; template_name_suffix = "_archive_objects")),
    path("dates/books/allow_future/", B(ArchiveIndexView; allow_future = true)),
    path("dates/books/paginated/", B(ArchiveIndexView; paginate_by = 10)),
    path("dates/booksignings/", S(ArchiveIndexView)),
    path("dates/books/<int:year>/", B(YearArchiveView)),
    path("dates/books/<int:year>/make_object_list/", B(YearArchiveView; make_object_list = true)),
    path("dates/books/<int:year>/allow_empty/", B(YearArchiveView; allow_empty = true)),
    path("dates/books/<int:year>/allow_future/", B(YearArchiveView; allow_future = true)),
    path("dates/books/<str:year>/", B(YearArchiveView)),
    path("dates/books/<int:year>/<str:month>/", B(MonthArchiveView)),
    path("dates/books/<int:year>/<str:month>/allow_empty/", B(MonthArchiveView; allow_empty = true)),
    path("dates/books/<int:year>/<str:month>/allow_future/", B(MonthArchiveView; allow_future = true)),
    path("dates/books/<int:year>/<str:month>/paginated/", B(MonthArchiveView; paginate_by = 30)),
    path("dates/books/<int:year>/<int:month>/format/", B(MonthArchiveView; month_format = "%m")),
    path("dates/books/<int:year>/<str:month>/strictformat/", B(MonthArchiveView; month_format = "%b")),
    path("dates/books/<int:year>/week/<int:week>/", B(WeekArchiveView)),
    path("dates/books/<int:year>/week/<int:week>/allow_empty/", B(WeekArchiveView; allow_empty = true)),
    path("dates/books/<int:year>/week/<int:week>/monday/", B(WeekArchiveView; week_format = "%W")),
    path("dates/books/<int:year>/week/<int:week>/iso/", B(WeekArchiveView; week_format = "%V")),
    path("dates/books/today/", B(TodayArchiveView)),
    path("dates/books/today/allow_empty/", B(TodayArchiveView; allow_empty = true)),
    path("dates/books/<int:year>/<str:month>/<int:day>/", B(DayArchiveView)),
    path("dates/books/<int:year>/<str:month>/<int:day>/allow_empty/", B(DayArchiveView; allow_empty = true)),
    path("dates/books/<int:year>/<str:month>/<int:day>/allow_future/", B(DayArchiveView; allow_future = true)),
    path("dates/books/<int:year>/<str:month>/<str:day>/", B(DayArchiveView)),
    path("dates/books/<int:year>/<str:month>/<int:day>/<int:pk>/", B(DateDetailView)),
    path("dates/books/<int:year>/<str:month>/<int:day>/byslug/<slug:slug>/", B(DateDetailView)),
    path("dates/books/<int:year>/<str:month>/<int:day>/<int:pk>/allow_future/", B(DateDetailView; allow_future = true)),
    path("dates/books/get_object_custom_queryset/<int:year>/<str:month>/<int:day>/<int:pk>/",
         B(DateDetailView; queryset = filter(objects(DgvBook); pk = -1))),
    path("dates/booksignings/<int:year>/", S(YearArchiveView)),
    path("dates/booksignings/<int:year>/<str:month>/", S(MonthArchiveView)),
    path("dates/booksignings/<int:year>/<str:month>/<int:day>/", S(DayArchiveView)),
    path("dates/booksignings/<int:year>/<str:month>/<int:day>/<int:pk>/", S(DateDetailView)),
    ]
end

dgv_body(r) = String(copy(r.body))
dgv_loc(r) = getheader(r, "Location")
"The exception a view throws when called directly (Django's assertRaises around a client request)."
dgv_thrown(f) = try f(); nothing catch e; e end
dgv_get(path) = get(RequestFactory(), path)

@testset "django generic_views" begin
    old_urls = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = dgv_urls())
    c = Client()
    try
        port_block() do
            # --- test_base: TemplateView, RedirectView, View's methods
            r = get(c, "/template/simple/bar/")
            @test r.status == 200 && dgv_body(r) == "T:dgv_simple.html foo=bar extra="                     # test_template_params
            @test dgv_body(get(c, "/template/extra_context/")) == "T:dgv_simple.html foo= extra=e"         # test_extra_context
            r = post(c, "/template/simple/bar/")
            @test r.status == 405 && getheader(r, "Allow") == "GET, HEAD, OPTIONS"                     # test_get_and_post / test_not_calling_parent_setup_error
            r = request(c, "OPTIONS", "/template/simple/bar/")
            @test r.status == 200 && getheader(r, "Allow") == "GET, HEAD, OPTIONS" && getheader(r, "Content-Length") == "0"   # test_options
            @test request(c, "HEAD", "/template/simple/bar/").status == 200                            # test_head_no_get
            @test request(c, "PUT", "/list/authors/").status == 405 && post(c, "/list/authors/").status == 405   # test_invalid_keyword_argument (405s)
            @test post(c, "/methods/").status == 200 && get(c, "/methods/").status == 405               # test_get_and_head (http_method_names)
            r = get(c, "/redirect/")
            @test r.status == 302 && dgv_loc(r) == "/bar/"                                                  # test_default_redirect
            @test get(c, "/redirect/none/").status == 410                                               # test_no_url
            r = get(c, "/redirect/permanent/")
            @test r.status == 301 && dgv_loc(r) == "/bar/"                                                  # test_permanent_redirect
            @test dgv_loc(get(c, "/redirect/qs/?pork=spam")) == "/bar/?pork=spam"                           # test_include_args
            @test dgv_loc(get(c, "/redirect/qs/?pork=spam&unicode=%E2%9C%93")) == "/bar/?pork=spam&unicode=%E2%9C%93"   # test_include_urlencoded_args
            @test dgv_loc(get(c, "/redirect/qs/")) == "/bar/"                                               # test_redirect_when_meta_contains_no_query_string
            @test dgv_loc(get(c, "/redirect/sub/42/")) == "/bar/42/"                                        # test_parameter_substitution
            @test dgv_loc(get(c, "/redirect/named/1/")) == "/detail/artist/1/"                               # test_named_url_pattern
            for m in ("POST", "HEAD", "OPTIONS", "PUT", "PATCH", "DELETE")                              # test_redirect_POST, ..._DELETE
                r = request(c, m, "/redirect/")
                @test r.status == 302 && dgv_loc(r) == "/bar/"
            end

            # --- test_list
            for i in 0:99
                create(DgvAuthor; name = "Author " * lpad(i, 2, '0'), slug = "a$i")
            end
            r = get(c, "/list/authors/")
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_list.html"                       # test_queryset
            @test dgv_ctx()["dgvauthor_list"] == dgv_ctx()["object_list"] && length(dgv_ctx()["object_list"]) == 100 && !dgv_ctx()["is_paginated"]
            @test dgv_ctx()["view"] isa Juango.ViewCall
            r = get(c, "/list/authors/paginated/")                                                     # test_paginated_queryset
            @test r.status == 200 && length(dgv_ctx()["object_list"]) == 30 && dgv_ctx()["is_paginated"] &&
                  dgv_ctx()["page_obj"].number == 1 && dgv_ctx()["paginator"].num_pages == 4 && dgv_ctx()["dgvauthor_list"] == dgv_ctx()["object_list"]
            get(c, "/list/authors/paginated/?page=2")                                                  # test_paginated_get_page_by_query_string
            @test dgv_ctx()["object_list"][1].name == "Author 30" && dgv_ctx()["page_obj"].number == 2
            get(c, "/list/authors/paginated/?page=last")                                               # test_paginated_get_last_page_by_query_string
            @test length(dgv_ctx()["object_list"]) == 10 && dgv_ctx()["object_list"][1].name == "Author 90" && dgv_ctx()["page_obj"].number == 4
            get(c, "/list/authors/paginated/3/")                                                       # test_paginated_get_page_by_urlvar
            @test dgv_ctx()["object_list"][1].name == "Author 60" && dgv_ctx()["page_obj"].number == 3
            @test get(c, "/list/authors/paginated/?page=42").status == 404                            # test_paginated_page_out_of_range
            @test get(c, "/list/authors/paginated/?page=frog").status == 404                          # test_paginated_invalid_page
            get(c, "/list/authors/paginated/custom_page_kwarg/?pagina=2")                              # test_paginated_custom_page_kwarg
            @test dgv_ctx()["object_list"][1].name == "Author 30" && dgv_ctx()["page_obj"].number == 2
            delete!(filter(DgvAuthor; name__in = ["Author 9$i" for i in 2:9]))                         # (92 authors: the last page takes 2 orphans)
            get(c, "/list/authors/paginated-orphaned/")                                                # test_paginated_orphaned_queryset
            @test dgv_ctx()["page_obj"].number == 1
            get(c, "/list/authors/paginated-orphaned/?page=last")
            @test dgv_ctx()["page_obj"].number == 3 && length(dgv_ctx()["object_list"]) == 32
            get(c, "/list/authors/paginated-orphaned/?page=3")
            @test dgv_ctx()["page_obj"].number == 3
            @test get(c, "/list/authors/paginated-orphaned/?page=4").status == 404
            get(c, "/list/authors/template_name_suffix/")                                              # test_template_name_suffix
            @test dgv_body(get(c, "/list/authors/template_name_suffix/")) == "T:$DGV_APP/dgvauthor_objects.html"
            get(c, "/list/authors/context_object_name/")                                               # test_context_object_name
            @test haskey(dgv_ctx(), "author_list2") && !haskey(dgv_ctx(), "dgvauthor_list")
            create(DgvArtist; name = "Rene Magritte")
            r = get(c, "/list/artists/")
            @test dgv_body(r) == "T:dgvartist_list.html" && haskey(dgv_ctx(), "dgvartist_list")                   # (Juango's template name, when there's no app one)
            delete!(objects(DgvAuthor))
            @test get(c, "/list/authors/notempty/").status == 404                                      # test_allow_empty_false
            @test get(c, "/list/authors/notempty/paginated/").status == 404
            r = get(c, "/list/authors/")
            @test r.status == 200 && isempty(dgv_ctx()["object_list"])                                     # (allow_empty: the default)
            r = get(c, "/list/authors/paginated/")
            @test r.status == 200 && isempty(dgv_ctx()["object_list"]) && dgv_ctx()["page_obj"].number == 1
            create(DgvAuthor; name = "Author 1", slug = "a1")
            @test get(c, "/list/authors/notempty/").status == 200
            delete!(objects(DgvAuthor))

            # --- test_detail (and the books and authors of test_dates' and test_edit's setUpTestData)
            bolano = create(DgvAuthor; name = "Roberto Bolaño", slug = "roberto-bolano")
            scott = create(DgvAuthor; name = "Scott Rosenberg", slug = "scott-rosenberg")
            b2066 = create(DgvBook; name = "2066", slug = "2066", pages = 800, pubdate = Date(2008, 10, 1)); add!(b2066.authors, bolano)
            dic = create(DgvBook; name = "Dreaming in Code", slug = "dreaming-in-code", pages = 300, pubdate = Date(2006, 5, 1))
            add!(dic.authors, scott)
            zen = create(DgvBook; name = "Zen and the Art of Motorcycle Maintenance", slug = "zen-and-the-art-of-motorcycle-maintenance",
                         pages = 350, pubdate = Date(2006, 5, 1))
            get(c, "/list/books/sorted/")                                                              # test_explicitly_ordered_list_view
            @test dgv_names(dgv_ctx()["object_list"]) == ["2066", "Dreaming in Code", "Zen and the Art of Motorcycle Maintenance"]
            get(c, "/list/books/sortedbypagesandnamedec/")
            @test dgv_names(dgv_ctx()["object_list"]) == ["Dreaming in Code", "Zen and the Art of Motorcycle Maintenance", "2066"]

            a = bolano
            r = get(c, "/detail/author/$(a.id)/")
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_detail.html"                     # test_detail_by_pk
            @test dgv_ctx()["object"].id == a.id && dgv_ctx()["dgvauthor"].id == a.id
            get(c, "/detail/author/byid/$(a.id)/")
            @test dgv_ctx()["object"].id == a.id                                                           # (Juango's <int:id>)
            @test get(c, "/detail/author/500/").status == 404                                          # test_detail_missing_object
            get(c, "/detail/author/bycustompk/$(a.id)/")                                               # test_detail_by_custom_pk
            @test dgv_ctx()["object"].id == a.id
            get(c, "/detail/author/byslug/scott-rosenberg/")                                           # test_detail_by_slug
            @test dgv_ctx()["object"].id == scott.id && dgv_ctx()["dgvauthor"].id == scott.id
            get(c, "/detail/author/bycustomslug/scott-rosenberg/")                                     # test_detail_by_custom_slug
            @test dgv_ctx()["object"].id == scott.id
            get(c, "/detail/author/bypkignoreslug/$(a.id)-roberto-bolano/")                            # test_detail_by_pk_ignore_slug
            @test dgv_ctx()["object"].id == a.id
            get(c, "/detail/author/bypkignoreslug/$(a.id)-scott-rosenberg/")                           # test_detail_by_pk_ignore_slug_mismatch
            @test dgv_ctx()["object"].id == a.id
            get(c, "/detail/author/bypkandslug/$(a.id)-roberto-bolano/")                               # test_detail_by_pk_and_slug
            @test dgv_ctx()["object"].id == a.id
            @test get(c, "/detail/author/bypkandslug/$(a.id)-scott-rosenberg/").status == 404          # test_detail_by_pk_and_slug_mismatch_404
            @test dgv_body(get(c, "/detail/author/$(a.id)/template_name_suffix/")) == "T:$DGV_APP/dgvauthor_view.html"   # test_template_name_suffix
            @test dgv_body(get(c, "/detail/author/$(a.id)/template_name/")) == "T:dgv_about.html"           # test_template_name
            get(c, "/detail/author/$(a.id)/context_object_name/")                                      # test_context_object_name
            @test dgv_ctx()["thingy"].id == a.id && !haskey(dgv_ctx(), "dgvauthor") && dgv_ctx()["object"].id == a.id
            e = dgv_thrown(() -> DGV(DetailView, DgvAuthor)(dgv_get("/")))                                     # test_invalid_url
            @test e isa ArgumentError && occursin("must be called with either an object pk or a slug in the URLconf", e.msg)

            # --- test_edit
            r = get(c, "/edit/authors/create/")                                                        # test_create
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_form.html" && haskey(dgv_ctx(), "form") && !haskey(dgv_ctx(), "object")
            r = post(c, "/edit/authors/create/", Dict("name" => "Randall Munroe", "slug" => "randall-munroe"))
            @test r.status == 302 && dgv_loc(r) == "/list/authors/" && exists(filter(DgvAuthor; name = "Randall Munroe"))
            r = post(c, "/edit/authors/create/", Dict("name" => "A"^101, "slug" => "randall-munroe"))   # test_create_invalid
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_form.html" && haskey(dgv_ctx()["form"].errors, :name)
            r = post(c, "/edit/artists/create/", Dict("name" => "Rene Magritte 2"))                    # test_create_with_object_url
            @test r.status == 302 && dgv_loc(r) == "/detail/artist/$(get(DgvArtist; name = "Rene Magritte 2").id)/"
            r = post(c, "/edit/authors/create/interpolate_redirect/", Dict("name" => "Randall Munroe 2", "slug" => "rm2"))   # test_create_with_interpolated_redirect
            @test r.status == 302 && dgv_loc(r) == "/edit/author/$(get(DgvAuthor; slug = "rm2").id)/update/"
            r = get(c, "/edit/authors/create/special/")                                                # test_create_with_special_properties
            @test dgv_body(r) == "T:dgv_form.html" && !haskey(dgv_ctx(), "thingy")
            r = post(c, "/edit/authors/create/special/", Dict("name" => "Randall Munroe 3", "slug" => "rm3"))
            @test r.status == 302 && dgv_loc(r) == "/list/authors/"
            r = post(c, "/edit/authors/create/restricted/", Dict("name" => "Randall Munroe 4", "slug" => "rm4"))   # test_create_restricted
            @test r.status == 302 && startswith(dgv_loc(r), "/accounts/login/") && !exists(filter(DgvAuthor; slug = "rm4"))
            req = post(RequestFactory(), "/", Dict("name" => "Randall Munroe 5", "slug" => "rm5"))
            e = dgv_thrown(() -> DGV(CreateView, DgvAuthor; fields = [:name, :slug])(req))                     # test_create_without_redirect
            @test e isa Juango.ImproperlyConfigured && occursin("No URL to redirect to.", e.msg)
            r = get(c, "/edit/author/$(a.id)/update/")                                                 # test_update_post
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_form.html" && dgv_ctx()["object"].id == a.id &&
                  dgv_ctx()["dgvauthor"].id == a.id && dgv_ctx()["form"].instance.id == a.id
            r = post(c, "/edit/author/$(a.id)/update/", Dict("name" => "Randall Munroe (xkcd)", "slug" => "randall-munroe"))
            @test r.status == 302 && dgv_loc(r) == "/list/authors/" && get(DgvAuthor; id = a.id).name == "Randall Munroe (xkcd)"
            r = post(c, "/edit/author/$(a.id)/update/", Dict("name" => "A"^101, "slug" => "randall-munroe"))   # test_update_invalid
            @test r.status == 200 && haskey(dgv_ctx()["form"].errors, :name) && get(DgvAuthor; id = a.id).name == "Randall Munroe (xkcd)"
            art = get(DgvArtist; name = "Rene Magritte")
            r = post(c, "/edit/artists/$(art.id)/update/", Dict("name" => "Rene Magritte"))           # test_update_with_object_url
            @test r.status == 302 && dgv_loc(r) == "/detail/artist/$(art.id)/"
            r = post(c, "/edit/author/$(a.id)/update/interpolate_redirect/", Dict("name" => "Randall Munroe (author of xkcd)", "slug" => "randall-munroe"))
            @test r.status == 302 && dgv_loc(r) == "/edit/author/$(a.id)/update/"                           # test_update_with_interpolated_redirect
            r = get(c, "/edit/author/$(a.id)/update/special/")                                          # test_update_with_special_properties
            @test dgv_body(r) == "T:dgv_form.html" && dgv_ctx()["thingy"].id == a.id && !haskey(dgv_ctx(), "dgvauthor")
            req = post(RequestFactory(), "/", Dict("name" => "Randall Munroe (author of xkcd)", "slug" => "randall-munroe"))
            e = dgv_thrown(() -> DGV(UpdateView, DgvAuthor; fields = [:name, :slug])(req; pk = a.id))          # test_update_without_redirect
            @test e isa Juango.ImproperlyConfigured && occursin("No URL to redirect to.", e.msg)
            r = get(c, "/edit/author/update/")                                                         # test_update_get_object
            @test r.status == 200 && dgv_ctx()["object"].id == first(objects(DgvAuthor)).id
            victim = create(DgvAuthor; name = "Randall Munroe 6", slug = "rm6")
            r = get(c, "/edit/author/$(victim.id)/delete/")                                            # test_delete_by_post
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvauthor_confirm_delete.html" && dgv_ctx()["object"].id == victim.id
            r = post(c, "/edit/author/$(victim.id)/delete/")
            @test r.status == 302 && dgv_loc(r) == "/list/authors/" && !exists(filter(DgvAuthor; id = victim.id))
            victim = create(DgvAuthor; name = "Randall Munroe 7", slug = "rm7")
            r = request(c, "DELETE", "/edit/author/$(victim.id)/delete/")                              # test_delete_by_delete
            @test r.status == 302 && dgv_loc(r) == "/list/authors/" && !exists(filter(DgvAuthor; id = victim.id))
            victim = create(DgvAuthor; name = "Randall Munroe 8", slug = "rm8")
            r = post(c, "/edit/author/$(victim.id)/delete/interpolate_redirect/")                      # test_delete_with_interpolated_redirect
            @test r.status == 302 && dgv_loc(r) == "/edit/authors/create/?deleted=$(victim.id)"
            victim = create(DgvAuthor; name = "Randall Munroe 9", slug = "rm9")
            get(c, "/edit/author/$(victim.id)/delete/special/")                                        # test_delete_with_special_properties
            @test dgv_ctx()["thingy"].id == victim.id && !haskey(dgv_ctx(), "dgvauthor")
            art2 = create(DgvArtist; name = "Doomed")
            e = dgv_thrown(() -> DGV(DeleteView, DgvArtist)(post(RequestFactory(), "/"); pk = art2.id))       # test_delete_without_redirect
            @test e isa Juango.ImproperlyConfigured && e.msg == "No URL to redirect to. Provide a success_url."
            r = post(c, "/contact/", Dict("name" => "Me", "message" => "Hello"))                       # FormView: test_post_data
            @test r.status == 302 && dgv_loc(r) == "/list/authors/"
            r = post(c, "/contact/", Dict("name" => "Me"))                                             # (form_invalid)
            @test r.status == 200 && haskey(dgv_ctx()["form"].errors, :message)
            e = dgv_thrown(() -> DGV(FormView, DgvContactForm; template = "dgv_form.html")(post(RequestFactory(), "/", Dict("name" => "Me", "message" => "x"))))
            @test e isa Juango.ImproperlyConfigured && e.msg == "No URL to redirect to. Provide a success_url."   # test_get_success_url (none)

            # --- test_dates: ArchiveIndexView
            r = get(c, "/dates/books/")                                                                # test_archive_view
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_archive.html"
            @test dgv_ctx()["date_list"] == [Date(2008), Date(2006)] && dgv_names(dgv_ctx()["latest"]) == dgv_names(objects(DgvBook))
            get(c, "/dates/books/context_object_name/")                                                # test_archive_view_context_object_name
            @test haskey(dgv_ctx(), "thingies") && !haskey(dgv_ctx(), "latest")
            @test dgv_body(get(c, "/dates/books/template_name_suffix/")) == "T:$DGV_APP/dgvbook_archive_objects.html"   # test_archive_view_template_suffix
            e = dgv_thrown(() -> DGV(ArchiveIndexView, DgvBook)(dgv_get("/")))                                 # test_archive_view_invalid
            @test e isa Juango.ImproperlyConfigured
            future = create(DgvBook; name = "The New New Testement", slug = "nnt", pages = 1, pubdate = today() + Day(1000))
            get(c, "/dates/books/")                                                                    # test_allow_future
            @test !("The New New Testement" in dgv_names(dgv_ctx()["latest"]))
            get(c, "/dates/books/allow_future/")
            @test "The New New Testement" in dgv_names(dgv_ctx()["latest"]) && dgv_ctx()["date_list"][1] == Date(year(today() + Day(1000)))
            delete!(future)
            get(c, "/dates/books/paginated/")                                                          # test_paginated_archive_view
            @test dgv_ctx()["page_obj"].number == 1 && length(dgv_ctx()["latest"]) == 3 && dgv_ctx()["date_list"] == [Date(2008), Date(2006)]
            dt(x...) = Juango.settings.USE_TZ ? Juango.make_aware(DateTime(x...)) : DateTime(x...)
            bs = create(DgvBookSigning; event_date = dt(2008, 4, 2, 12, 0))
            @test get(c, "/dates/booksignings/").status == 200                                        # test_datetime_archive_view
            @test dgv_ctx()["date_list"] == [Date(2008)]

            # YearArchiveView
            r = get(c, "/dates/books/2008/")                                                           # test_year_view
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_archive_year.html"
            @test dgv_ctx()["date_list"] == [Date(2008, 10, 1)] && dgv_ctx()["year"] == Date(2008) && isempty(dgv_ctx()["object_list"])
            @test dgv_ctx()["previous_year"] == Date(2006) && dgv_ctx()["next_year"] === nothing
            get(c, "/dates/books/2006/make_object_list/")                                              # test_year_view_make_object_list
            @test dgv_ctx()["date_list"] == [Date(2006, 5, 1)] && Set(dgv_names(dgv_ctx()["object_list"])) == Set(["Dreaming in Code", "Zen and the Art of Motorcycle Maintenance"])
            @test get(c, "/dates/books/1999/").status == 404                                           # test_year_view_empty
            r = get(c, "/dates/books/1999/allow_empty/")
            @test r.status == 200 && isempty(dgv_ctx()["date_list"]) && isempty(dgv_ctx()["object_list"])
            @test dgv_ctx()["next_year"] == Date(2000) && dgv_ctx()["previous_year"] == Date(1998)             # (allow_empty: empty years, #7164)
            get(c, "/dates/books/$(year(today()) + 1)/allow_empty/")
            @test dgv_ctx()["next_year"] === nothing                                                       # (not in the future)
            fy = year(today()) + 2
            create(DgvBook; name = "The New New Testement", slug = "nnt", pages = 600, pubdate = Date(fy, 1, 1))
            @test get(c, "/dates/books/$fy/").status == 404                                            # test_year_view_allow_future
            r = get(c, "/dates/books/$fy/allow_future/")
            @test r.status == 200 && dgv_ctx()["date_list"] == [Date(fy, 1, 1)]
            delete!(filter(DgvBook; slug = "nnt"))
            @test get(c, "/dates/books/no_year/").status == 404                                        # test_year_view_invalid_pattern
            get(c, "/dates/booksignings/2008/")                                                        # test_datetime_year_view
            @test dgv_ctx()["date_list"] == [Date(2008, 4, 1)]

            # MonthArchiveView
            r = get(c, "/dates/books/2008/oct/")                                                       # test_month_view
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_archive_month.html"
            @test dgv_ctx()["date_list"] == [Date(2008, 10, 1)] && dgv_names(dgv_ctx()["object_list"]) == ["2066"] && dgv_ctx()["month"] == Date(2008, 10, 1)
            @test dgv_ctx()["next_month"] === nothing && dgv_ctx()["previous_month"] == Date(2006, 5, 1)
            @test get(c, "/dates/books/2000/jan/").status == 404                                       # test_month_view_allow_empty
            get(c, "/dates/books/2000/jan/allow_empty/")
            @test isempty(dgv_ctx()["date_list"]) && isempty(dgv_ctx()["object_list"]) && dgv_ctx()["month"] == Date(2000, 1, 1)
            @test dgv_ctx()["next_month"] == Date(2000, 2, 1) && dgv_ctx()["previous_month"] == Date(1999, 12, 1)
            m = firstdayofmonth(today())
            mon = Juango.MONTH_ABBRS[month(m)]
            get(c, "/dates/books/$(year(m))/$mon/allow_empty/")
            @test dgv_ctx()["next_month"] === nothing                                                      # (no next month in the future)
            fm = firstdayofmonth(today() + Day(70))
            create(DgvBook; name = "The New New Testement", slug = "nnt", pages = 600, pubdate = fm)
            @test get(c, "/dates/books/$(year(fm))/$(Juango.MONTH_ABBRS[month(fm)])/").status == 404   # test_month_view_allow_future
            get(c, "/dates/books/$(year(fm))/$(Juango.MONTH_ABBRS[month(fm)])/allow_future/")
            @test dgv_ctx()["date_list"] == [fm] && dgv_ctx()["next_month"] === nothing
            delete!(filter(DgvBook; slug = "nnt"))
            get(c, "/dates/books/2008/oct/paginated/")                                                 # test_month_view_paginated
            @test dgv_names(dgv_ctx()["object_list"]) == ["2066"] && dgv_ctx()["page_obj"].number == 1
            @test get(c, "/dates/books/2008/10/").status == 200                                        # (a number works too)
            @test get(c, "/dates/books/2008/10/format/").status == 200                                 # test_custom_month_format
            @test get(c, "/dates/books/2008/10/strictformat/").status == 404 && get(c, "/dates/books/2008/oct/strictformat/").status == 200
            @test get(c, "/dates/books/2007/no_month/").status == 404                                  # test_month_view_invalid_pattern
            create(DgvBook; name = "Book A", slug = "a", pages = 100, pubdate = Date(2010, 1, 1))     # test_previous_month_without_content
            create(DgvBook; name = "Book B", slug = "b", pages = 100, pubdate = Date(2010, 3, 1))
            get(c, "/dates/books/2010/mar/")
            @test dgv_ctx()["previous_month"] == Date(2010, 1, 1)
            @test get(c, "/dates/books/2010/feb/").status == 404
            delete!(filter(DgvBook; slug__in = ["a", "b"]))
            get(c, "/dates/booksignings/2008/apr/")                                                    # test_datetime_month_view
            @test length(dgv_ctx()["object_list"]) == 1

            # WeekArchiveView
            r = get(c, "/dates/books/2008/week/39/")                                                   # test_week_view
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_archive_week.html"
            @test dgv_names(dgv_ctx()["object_list"]) == ["2066"] && dgv_ctx()["week"] == Date(2008, 9, 28)
            @test dgv_ctx()["next_week"] === nothing && dgv_ctx()["previous_week"] == Date(2006, 4, 30)
            @test get(c, "/dates/books/2008/week/12/").status == 404                                   # test_week_view_allow_empty
            get(c, "/dates/books/2008/week/12/allow_empty/")
            @test isempty(dgv_ctx()["object_list"])
            get(c, "/dates/books/2008/week/39/monday/")                                                # test_week_start_Monday
            @test dgv_ctx()["week"] == Date(2008, 9, 29)
            get(c, "/dates/books/2008/week/40/iso/")                                                   # test_iso_week_format
            @test dgv_ctx()["week"] == Date(2008, 9, 29)
            @test_throws ArgumentError Juango.week_start(2008, 1, "%T")                                # test_unknown_week_format

            # DayArchiveView, TodayArchiveView
            r = get(c, "/dates/books/2008/oct/1/")                                                     # test_day_view
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_archive_day.html"
            @test dgv_names(dgv_ctx()["object_list"]) == ["2066"] && dgv_ctx()["day"] == Date(2008, 10, 1)
            @test dgv_ctx()["next_day"] === nothing && dgv_ctx()["previous_day"] == Date(2006, 5, 1)
            @test dgv_ctx()["next_month"] === nothing && dgv_ctx()["previous_month"] == Date(2006, 5, 1)       # (a day's month neighbours, as Django's)
            @test get(c, "/dates/books/2000/jan/1/").status == 404                                     # test_day_view_allow_empty
            get(c, "/dates/books/2000/jan/1/allow_empty/")
            @test isempty(dgv_ctx()["object_list"]) && dgv_ctx()["day"] == Date(2000, 1, 1)
            @test dgv_ctx()["next_day"] == Date(2000, 1, 2) && dgv_ctx()["previous_day"] == Date(1999, 12, 31)
            @test get(c, "/dates/books/2008/10/1/").status == 200                                      # test_custom_month_format
            @test get(c, "/dates/books/2007/oct/no_day/").status == 404                                # test_day_view_invalid_pattern
            @test get(c, "/dates/books/today/").status == 404                                          # test_today_view
            get(c, "/dates/books/today/allow_empty/")
            @test dgv_ctx()["day"] == Juango.localdate()
            get(c, "/dates/booksignings/2008/apr/2/")                                                  # test_datetime_day_view
            @test length(dgv_ctx()["object_list"]) == 1

            # DateDetailView
            r = get(c, "/dates/books/2008/oct/1/$(b2066.id)/")                                         # test_date_detail_by_pk
            @test r.status == 200 && dgv_body(r) == "T:$DGV_APP/dgvbook_detail.html"
            @test dgv_ctx()["object"].id == b2066.id && dgv_ctx()["dgvbook"].id == b2066.id
            get(c, "/dates/books/2006/may/1/byslug/dreaming-in-code/")                                 # test_date_detail_by_slug
            @test dgv_ctx()["dgvbook"].id == dic.id
            @test get(c, "/dates/books/2008/10/1/$(b2066.id)/").status == 200                          # test_date_detail_custom_month_format
            @test get(c, "/dates/books/2008/oct/2/$(b2066.id)/").status == 404                         # (not that day)
            fd = today() + Day(400)
            fb = create(DgvBook; name = "The New New Testement", slug = "nnt", pages = 600, pubdate = fd)
            u = "/dates/books/$(year(fd))/$(Juango.MONTH_ABBRS[month(fd)])/$(day(fd))/$(fb.id)/"
            @test get(c, u).status == 404                                                              # test_date_detail_allow_future
            @test get(c, u * "allow_future/").status == 200 && dgv_ctx()["dgvbook"].id == fb.id
            delete!(fb)
            @test get(c, "/dates/books/9999/dec/31/$(b2066.id)/").status == 404                        # test_year_out_of_range
            @test get(c, "/dates/books/get_object_custom_queryset/2006/may/1/$(dic.id)/").status == 404   # test_get_object_custom_queryset
            r = get(c, "/dates/booksignings/2008/apr/2/$(bs.id)/")                                      # test_datetime_date_detail
            @test r.status == 200 && dgv_ctx()["object"].id == bs.id
            # not translated: views built from dicts and non-model objects (Juango's take a model), the
            # class mechanics (as_view's checks, setup(), get_context_data's kwargs, custom Paginator
            # classes), query counts, date_list_period and date_list ordering options, year_format and
            # day_format, ModelFormMixin's requirement of `fields` (Juango's ModelForm takes every
            # field without them: a difference kept), and the deprecation tests
        end
    finally
        configure!(ROOT_URLCONF = old_urls)
    end
end
