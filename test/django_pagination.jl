# Django's pagination tests, ported (#227): tests/pagination (PaginationTests, ModelPaginationTests).
# julia --project=test test/django_pagination.jl   (see setup.jl)
#
# Juango's page.next_page_number is `nothing` on the last page (Django's method raises EmptyPage):
# a difference kept. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DpgArticle
    headline = CharField(max_length = 100, default = "Default headline")
    pub_date = DateTimeField()
    Meta(table = "dpg_article", ordering = ["pub_date"])
end
redirect_stdout(devnull) do
    Juango.sync_models!([DpgArticle]); push!(PORT_MODELS, DpgArticle)
end

@testset "django pagination: PaginationTests" begin
    nine = collect(1:9); ten = collect(1:10); eleven = collect(1:11)
    # test_paginator: (items, per_page, orphans, allow_empty_first_page) => (count, num_pages, page_range)
    cases = [
        ((ten, 4, 0, false), (10, 3, [1, 2, 3])), ((ten, 4, 1, false), (10, 3, [1, 2, 3])), ((ten, 4, 2, false), (10, 2, [1, 2])),
        ((ten, 4, 0, true), (10, 3, [1, 2, 3])), ((ten, 4, 1, true), (10, 3, [1, 2, 3])), ((ten, 4, 2, true), (10, 2, [1, 2])),
        ((Int[], 4, 0, false), (0, 0, Int[])), ((Int[], 4, 1, false), (0, 0, Int[])), ((Int[], 4, 2, false), (0, 0, Int[])),
        ((Int[], 4, 0, true), (0, 1, [1])), ((Int[], 4, 1, true), (0, 1, [1])), ((Int[], 4, 2, true), (0, 1, [1])),
        (([1], 4, 0, false), (1, 1, [1])), (([1], 4, 1, false), (1, 1, [1])), (([1], 4, 2, false), (1, 1, [1])),
        (([1], 4, 0, true), (1, 1, [1])), (([1], 4, 1, true), (1, 1, [1])), (([1], 4, 2, true), (1, 1, [1])),
        (([1, 2], 2, 0, false), (2, 1, [1])), (([1, 2], 2, 1, false), (2, 1, [1])),
        (([1, 2], 1, 0, true), (2, 2, [1, 2])), ((nine, 4, 0, true), (9, 3, [1, 2, 3])), ((nine, 4, 1, true), (9, 2, [1, 2])),
        ((eleven, 4, 0, true), (11, 3, [1, 2, 3])), ((eleven, 4, 3, true), (11, 2, [1, 2])),
    ]
    for ((items, per, orph, aefp), (cnt, np, pr)) in cases
        p = Paginator(items, per; orphans = orph, allow_empty_first_page = aefp)
        @test (p.count, p.num_pages, collect(p.page_range)) == (cnt, np, pr)
    end
    p = Paginator([1, 2, 3], 2)                                                          # test_invalid_page_number
    for bad in (nothing, "x", 1.2, "1.2")
        e = try validate_number(p, bad) catch e; e end
        @test e isa PageNotAnInteger && e isa InvalidPage && e.msg == "That page number is not an integer"
    end
    e = try validate_number(p, 0) catch e; e end
    @test e isa EmptyPage && e.msg == "That page number is less than 1"
    e = try validate_number(p, 3) catch e; e end
    @test e isa EmptyPage && e.msg == "That page contains no results"
    @test validate_number(p, 1.0) == 1 && validate_number(p, "2") == 2 && validate_number(p, "last") == 2   # test_float_integer_page
    p = Paginator([1, 2, 3], 2; error_messages = Dict(:invalid_page => "Wrong page number", :min_page => "Too small",
                                                      :no_results => "There is nothing here"))   # test_error_messages
    @test (try validate_number(p, "x") catch e; e.msg end) == "Wrong page number"
    @test (try validate_number(p, 0) catch e; e.msg end) == "Too small"
    @test (try validate_number(p, 3) catch e; e.msg end) == "There is nothing here"
    p = Paginator(Int[], 2)                                                              # test_no_content_allow_empty_first_page
    @test validate_number(p, 1) == 1 && isempty(page(p, 1).object_list)
    @test_throws EmptyPage validate_number(Paginator(Int[], 2; allow_empty_first_page = false), 1)

    p = Paginator(collect(1:10), 2)                                                      # test_get_page
    @test get_page(p, 1).number == 1 && get_page(p, "x").number == 1 && get_page(p, nothing).number == 1   # test_get_page_invalid_value
    @test get_page(p, 0).number == 5 && get_page(p, 999).number == 5 && get_page(p, -1).number == 5   # test_get_page_empty_page
    @test get_page(Paginator(Int[], 2), 1).number == 1                                    # test_get_page_empty_object_list
    @test_throws EmptyPage get_page(Paginator(Int[], 2; allow_empty_first_page = false), 1)   # ..._and_allow_empty_first_page_false

    # test_page_indexes: (items, per_page, orphans, allow_empty_first_page) => (first page's (start, end), last page's)
    for ((items, per, orph, aefp), (first_, last_)) in [
            ((ten, 1, 0, true), ((1, 1), (10, 10))), ((ten, 2, 0, true), ((1, 2), (9, 10))), ((ten, 3, 0, true), ((1, 3), (10, 10))),
            ((ten, 5, 0, true), ((1, 5), (6, 10))), ((ten, 3, 1, true), ((1, 3), (7, 10))), ((ten, 3, 2, true), ((1, 3), (7, 10))),
            ((ten, 1, 1, true), ((1, 1), (9, 10))), ((ten, 1, 2, true), ((1, 1), (8, 10))), ((ten, 3, 4, true), ((1, 3), (4, 10))),
            ((ten, 5, 1, true), ((1, 5), (6, 10))), ((ten, 5, 2, true), ((1, 5), (6, 10))), ((ten, 5, 5, true), ((1, 10), (1, 10))),
            (([1], 4, 0, true), ((1, 1), (1, 1))),
            ((Int[], 4, 0, true), ((0, 0), (0, 0)))]
        p = Paginator(items, per; orphans = orph, allow_empty_first_page = aefp)
        f, l = page(p, 1), page(p, p.num_pages)
        @test (f.start_index, f.end_index) == first_ && (l.start_index, l.end_index) == last_
    end
    p = Paginator(collect("abcde"), 2)                                                   # test_page_sequence
    pg = page(p, 2)
    @test length(pg) == 2 && join(pg) == "cd" && pg[1] == 'c' && pg[end] == 'd' && collect(pg[1:2]) == ['c', 'd']
    @test repr(page(p, 1)) == "<Page 1 of 3>"                                             # test_page_repr
    pg = page(Paginator(collect(1:10), 5), 1)                                             # (first page: test_paginator's page methods)
    @test pg.has_next && !pg.has_previous && pg.has_other_pages && pg.next_page_number == 2 && pg.previous_page_number === nothing
    pg = page(Paginator(collect(1:10), 5), 2)
    @test !pg.has_next && pg.has_previous && pg.next_page_number === nothing && pg.previous_page_number == 1

    p = Paginator(collect(1:500), 10)                                                    # test_get_elided_page_range
    E = Juango.PAGINATOR_ELLIPSIS
    @test get_elided_page_range(p) == [1, 2, 3, 4, E, 49, 50]
    @test get_elided_page_range(p, 7) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, E, 49, 50]
    @test get_elided_page_range(p, 8) == [1, 2, E, 5, 6, 7, 8, 9, 10, 11, E, 49, 50]
    @test get_elided_page_range(p, 43) == [1, 2, E, 40, 41, 42, 43, 44, 45, 46, E, 49, 50]
    @test get_elided_page_range(p, 44) == [1, 2, E, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50]
    @test get_elided_page_range(p, 45) == [1, 2, E, 42, 43, 44, 45, 46, 47, 48, 49, 50]
    @test get_elided_page_range(p, 50) == [1, 2, E, 47, 48, 49, 50]
    @test get_elided_page_range(p, 25; on_each_side = 1, on_ends = 1) == [1, E, 24, 25, 26, E, 50]
    @test get_elided_page_range(p, 25; on_each_side = 0, on_ends = 0) == [E, 25, E]
    @test get_elided_page_range(Paginator(collect(1:30), 10), 2) == [1, 2, 3]            # (few pages: all of them)
    @test_throws PageNotAnInteger get_elided_page_range(p, "x")
end

@testset "django pagination: ModelPaginationTests" begin
    port_block() do
        for x in 1:9
            create(DpgArticle; headline = "Article $x", pub_date = DateTime(2005, 7, 29))
        end
        p = Paginator(order_by(objects(DpgArticle), "id"), 5)                           # (the same pub_date for all: Django's order_by("id"))
        pg = page(p, 1)                                                                  # test_first_page
        @test repr(pg) == "<Page 1 of 2>" && [a.headline for a in pg] == ["Article $x" for x in 1:5]
        @test pg.has_next && !pg.has_previous && pg.has_other_pages && pg.next_page_number == 2
        @test pg.start_index == 1 && pg.end_index == 5
        pg = page(p, 2)                                                                  # test_last_page
        @test [a.headline for a in pg] == ["Article $x" for x in 6:9] && pg.start_index == 6 && pg.end_index == 9
        @test pg[1].headline == "Article 6"                                              # test_page_getitem
        @test_throws EmptyPage page(p, 3)
        # an InvalidPage a view lets through is a 404
        old = Juango.settings.ROOT_URLCONF
        configure!(ROOT_URLCONF = [path("p/", req -> HttpResponse(string(page(Paginator(order_by(objects(DpgArticle), "id"), 5), get(req.GET, "page", "1")).number)))])
        try
            @test text(get(Client(), "/p/?page=2")) == "2" && get(Client(), "/p/?page=9").status == 404 && get(Client(), "/p/?page=x").status == 404
        finally
            configure!(ROOT_URLCONF = old)
        end
        # not translated: paginating objects with only a count() method or __len__, the
        # UnorderedObjectListWarning for object lists with an `ordered` attribute (querysets warn: views.jl)
    end
end
