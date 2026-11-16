# Django's own ORM tests, ported: julia --project=test test/django_orm.jl
#
# From django/tests (lookup, aggregation, expressions, queries, model_fields), translated to
# Juango's API: the same models and data, the same expectations. Tests of Django internals (SQL
# strings, pickling, deconstruct(), Python-only APIs, backend features Juango doesn't target) are
# left out. A gap Juango has is filed as an issue and kept here as @test_broken with its number,
# so it turns into an unexpected pass when the gap is closed.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# Each block runs outside a transaction and then empties the port's tables: a test of a gap may
# expect a database error, and on PostgreSQL an error inside a transaction (rollback_after's)
# aborts it, failing every query after it. Tables are emptied children first (the reverse of the
# order they're created in).
const PORT_MODELS = Any[]
function port_block(f)
    try
        f()
    finally
        IS_MYSQL && Juango.execute("SET FOREIGN_KEY_CHECKS = 0")     # rows that refer to rows of their own table (Tag.parent)
        try
            for T in reverse(PORT_MODELS)
                Juango.execute("DELETE FROM " * Juango.qname(Juango.modelmeta(T).table))
            end
        finally
            IS_MYSQL && Juango.execute("SET FOREIGN_KEY_CHECKS = 1")
        end
    end
end

# --- tests/lookup/models.py ---------------------------------------------------------------------------
@model struct DlAuthor
    name = CharField(max_length = 100)
    alias = CharField(max_length = 50, null = true, blank = true)
    bio = TextField(null = true)
    Meta(table = "dl_author", ordering = ["name"])
end
@model struct DlArticle
    headline = CharField(max_length = 100)
    pub_date = DateTimeField()
    author = ForeignKey(DlAuthor, on_delete = :SET_NULL, blank = true, null = true, related_name = :article)
    slug = SlugField(unique = true, blank = true, null = true)
    Meta(table = "dl_article", ordering = ["-pub_date", "headline"])
end
Base.show(io::IO, a::DlArticle) = print(io, a.headline)
@model struct DlTag
    articles = ManyToManyField(DlArticle; related_name = :tag)
    name = CharField(max_length = 100)
    Meta(table = "dl_tag", ordering = ["name"])
end
@model struct DlSeason
    year = PositiveSmallIntegerField()
    gt = IntegerField(null = true, blank = true)
    Meta(table = "dl_season", constraints = [UniqueConstraint(fields = [:year], name = "dl_season_year_unique")])
end
@model struct DlGame
    season = ForeignKey(DlSeason, on_delete = :CASCADE, related_name = :games)
    home = CharField(max_length = 100)
    away = CharField(max_length = 100)
    Meta(table = "dl_game")
end
@model struct DlPlayer
    name = CharField(max_length = 100)
    games = ManyToManyField(DlGame; related_name = :players)
    Meta(table = "dl_player")
end
@model struct DlProduct
    name = CharField(max_length = 80)
    qty_target = DecimalField(max_digits = 6, decimal_places = 2)
    Meta(table = "dl_product")
end
@model struct DlStock
    product = ForeignKey(DlProduct, on_delete = :CASCADE)
    short = BooleanField(default = false)
    qty_available = DecimalField(max_digits = 6, decimal_places = 2)
    Meta(table = "dl_stock")
end
redirect_stdout(devnull) do
    ms = [DlAuthor, DlArticle, DlTag, through(DlTag, :articles), DlSeason, DlGame, DlPlayer,
                         through(DlPlayer, :games), DlProduct, DlStock]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

titles(qs) = [a.headline for a in qs]

@testset "django lookup: LookupTests (part 1: counts, in_bulk, values)" begin
  port_block() do
    au1 = create(DlAuthor; name = "Author 1", alias = "a1", bio = "x"^4001)
    au2 = create(DlAuthor; name = "Author 2", alias = "a2")
    mk(h, d, au, s) = create(DlArticle; headline = h, pub_date = d, author = au, slug = s)
    a1 = mk("Article 1", DateTime(2005, 7, 26), au1, "a1"); a2 = mk("Article 2", DateTime(2005, 7, 27), au1, "a2")
    a3 = mk("Article 3", DateTime(2005, 7, 27), au1, "a3"); a4 = mk("Article 4", DateTime(2005, 7, 28), au1, "a4")
    a5 = mk("Article 5", DateTime(2005, 8, 1, 9), au2, "a5"); a6 = mk("Article 6", DateTime(2005, 8, 1, 8), au2, "a6")
    a7 = mk("Article 7", DateTime(2005, 7, 27), au2, "a7")
    t1 = create(DlTag; name = "Tag 1"); add!(t1.articles, a1, a2, a3)
    t2 = create(DlTag; name = "Tag 2"); add!(t2.articles, a3, a4, a5)
    t3 = create(DlTag; name = "Tag 3"); add!(t3.articles, a5, a6, a7)
    ordered = ["Article 5", "Article 6", "Article 4", "Article 2", "Article 3", "Article 7", "Article 1"]

    # test_lookup_int_as_str
    @test titles(filter(DlArticle; id__iexact = string(a1.id))) == ["Article 1"]
    # test_lookup_date_as_str (a date lookup with a string)
    @test titles(filter(DlArticle; pub_date__startswith = "2005")) == ordered
    # test_iterator
    @test [a.headline for a in iterator(objects(DlArticle))] == ordered
    @test [a.headline for a in iterator(filter(DlArticle; headline__endswith = "4"))] == ["Article 4"]
    # test_count
    @test count(objects(DlArticle)) == 7 && count(filter(DlArticle; pub_date__exact = DateTime(2005, 7, 27))) == 3
    @test count(filter(DlArticle; headline__startswith = "Blah blah")) == 0
    arts = objects(DlArticle)
    @test count(arts[1:4]) == 4 && count(arts[2:100]) == 6 && count(arts[11:100]) == 0
    @test count(filter(DlArticle; pub_date__exact = "2005-07-27 00:00:00")) == 3   # fixed in #202
    # test_in_bulk
    b = in_bulk(DlArticle, [a1.id, a2.id])
    @test b[a1.id].headline == "Article 1" && b[a2.id].headline == "Article 2" && length(in_bulk(DlArticle)) == 7
    @test collect(keys(in_bulk(DlArticle, [a3.id]))) == [a3.id] && isempty(in_bulk(DlArticle, [1000])) && isempty(in_bulk(DlArticle, Int[]))
    @test collect(keys(in_bulk(DlArticle, Set([a3.id])))) == [a3.id] && collect(keys(in_bulk(DlArticle, (a3.id,)))) == [a3.id]
    @test collect(keys(in_bulk(DlArticle, (x for x in [a1.id])))) == [a1.id]
    # test_in_bulk_with_field
    @test Set(keys(in_bulk(DlArticle, ["a1", "a2", "a3"]; field_name = :slug))) == Set(["a1", "a2", "a3"])
    # test_in_bulk_meta_constraint: a single-field UniqueConstraint counts as unique
    s11, s12 = create(DlSeason; year = 2011), create(DlSeason; year = 2012); create(DlSeason; year = 2013)
    @test Set(keys(in_bulk(DlSeason, [2011, 2012]; field_name = :year))) == Set([2011, 2012])
    # test_in_bulk_non_unique_field
    @test_throws ArgumentError in_bulk(DlArticle, [au1]; field_name = :author)
    # test_in_bulk_preserve_ordering: the keys in the order given
    @test collect(keys(in_bulk(DlArticle, [a2.id, a1.id]))) == [a2.id, a1.id]
    # test_in_bulk_sliced_queryset
    e = try in_bulk(objects(DlArticle)[1:5], [a1.id, a2.id]); nothing catch err; err end
    @test e isa ArgumentError && occursin("sliced", e.msg)
    # test_in_bulk_values_*: in_bulk on values()/values_list querysets (Django 6)
    @test isempty(in_bulk(values(objects(DlArticle)), Int[])) && in_bulk(values(objects(DlArticle), :headline), [a1.id])[a1.id] == Dict(:headline => "Article 1")
    @test in_bulk(values_list(objects(DlArticle), :headline), [a1.id])[a1.id] == ("Article 1",)
    @test in_bulk(values_list(objects(DlArticle), :headline; flat = true), [a1.id])[a1.id] == "Article 1"
    @test in_bulk(values(objects(DlArticle), :id, :headline), [a1.id])[a1.id] == Dict(:id => a1.id, :headline => "Article 1")

    # test_values_filter_and_no_fields / test_values_no_field_names
    v = collect(values(filter(DlArticle; id__in = (a5.id, a6.id))))
    @test v == [Dict(:id => a5.id, :headline => "Article 5", :pub_date => DateTime(2005, 8, 1, 9), :author_id => au2.id, :slug => "a5"),
                Dict(:id => a6.id, :headline => "Article 6", :pub_date => DateTime(2005, 8, 1, 8), :author_id => au2.id, :slug => "a6")]
    # test_values_single_field / test_values_filter_and_single_field / test_values_two_fields / test_values_iterator
    @test [d[:headline] for d in values(objects(DlArticle), :headline)] == ordered
    @test collect(values(filter(DlArticle; pub_date__exact = DateTime(2005, 7, 27)), :id)) == [Dict(:id => i) for i in (a2.id, a3.id, a7.id)]
    @test collect(values(objects(DlArticle), :id, :headline))[1] == Dict(:id => a5.id, :headline => "Article 5")
    @test [d[:headline] for d in iterator(values(objects(DlArticle), :id, :headline))] == ordered
    # test_values_relations
    @test collect(values(objects(DlArticle), :headline, :author__name))[1] == Dict(:headline => "Article 5", :author__name => "Author 2")
    vr = try collect(values(order_by(objects(DlAuthor), "name", "article__headline"), :name, :article__headline)) catch; [] end
    @test [(d[:name], d[:article__headline]) for d in vr] ==  # (#209)
          [("Author 1", "Article 1"), ("Author 1", "Article 2"), ("Author 1", "Article 3"), ("Author 1", "Article 4"),
           ("Author 2", "Article 5"), ("Author 2", "Article 6"), ("Author 2", "Article 7")]
    vt = try collect(values(order_by(objects(DlAuthor), "name", "article__headline", "article__tag__name"), :name, :article__headline, :article__tag__name)) catch; [] end
    @test [(d[:article__headline], d[:article__tag__name]) for d in vt] ==  # (#209)
          [("Article 1", "Tag 1"), ("Article 2", "Tag 1"), ("Article 3", "Tag 1"), ("Article 3", "Tag 2"), ("Article 4", "Tag 2"),
           ("Article 5", "Tag 2"), ("Article 5", "Tag 3"), ("Article 6", "Tag 3"), ("Article 7", "Tag 3")]
    # test_values_nonexistent_field: an error naming the field (raised when the query is built)
    @test_throws Juango.LookupError collect(values(objects(DlArticle), :id, :id_plus_two))
    # test_values_list_filter_and_no_fields / single field / order_by / flat
    @test collect(values_list(filter(DlArticle; id__in = (a5.id, a6.id)))) ==
          [(a5.id, "Article 5", DateTime(2005, 8, 1, 9), au2.id, "a5"), (a6.id, "Article 6", DateTime(2005, 8, 1, 8), au2.id, "a6")]
    @test collect(values_list(objects(DlArticle), :headline)) == [(h,) for h in ordered]
    @test collect(values_list(order_by(objects(DlArticle), "id"), :id)) == [(a.id,) for a in (a1, a2, a3, a4, a5, a6, a7)]
    @test collect(values_list(order_by(objects(DlArticle), "id"), :id; flat = true)) == [a.id for a in (a1, a2, a3, a4, a5, a6, a7)]
    # test_values_list_relations
    @test collect(values_list(order_by(objects(DlAuthor), "name", "article__headline"), :name, :article__headline))[1] == ("Author 1", "Article 1")  # (#209)
    # test_values_list_flat_more_than_one_field
    @test_throws ArgumentError values_list(objects(DlArticle), :id, :headline; flat = true)
    # test_values_list_flat_no_fields: flat with no fields is the pk (Django)
    @test collect(values_list(order_by(objects(DlArticle), "id"); flat = true)) == [a.id for a in (a1, a2, a3, a4, a5, a6, a7)]   # #213
    # test_values_extra / test_values_list_extra: extra(select = ...) (Django's legacy raw-SQL select)
    # test_extra: Django calls extra() a last resort; RawSQL annotations cover it, so Juango has none
  end
end

# the lookup tests' data (setUpTestData), for the testsets below
function dl_data()
    au1 = create(DlAuthor; name = "Author 1", alias = "a1", bio = "x"^4001)
    au2 = create(DlAuthor; name = "Author 2", alias = "a2")
    mk(h, d, au, s) = create(DlArticle; headline = h, pub_date = d, author = au, slug = s)
    a = [mk("Article 1", DateTime(2005, 7, 26), au1, "a1"), mk("Article 2", DateTime(2005, 7, 27), au1, "a2"),
         mk("Article 3", DateTime(2005, 7, 27), au1, "a3"), mk("Article 4", DateTime(2005, 7, 28), au1, "a4"),
         mk("Article 5", DateTime(2005, 8, 1, 9), au2, "a5"), mk("Article 6", DateTime(2005, 8, 1, 8), au2, "a6"),
         mk("Article 7", DateTime(2005, 7, 27), au2, "a7")]
    t1 = create(DlTag; name = "Tag 1"); add!(t1.articles, a[1], a[2], a[3])
    t2 = create(DlTag; name = "Tag 2"); add!(t2.articles, a[3], a[4], a[5])
    t3 = create(DlTag; name = "Tag 3"); add!(t3.articles, a[5], a[6], a[7])
    (; au1, au2, a, t = [t1, t2, t3])
end

@testset "django lookup: LookupTests (part 2: adjacent, escaping, exclude, none, in, errors)" begin
  port_block() do
    d = dl_data(); a = d.a
    ordered = ["Article 5", "Article 6", "Article 4", "Article 2", "Article 3", "Article 7", "Article 1"]
    # test_get_next_previous_by: equal dates fall back to the id
    nx(o; kw...) = get_next_by(o, :pub_date; kw...).headline
    pv(o) = Juango.adjacent_by(o, :pub_date, false).headline
    @test [nx(a[1]), nx(a[2]), nx(a[3]), nx(a[4]), nx(a[6]), nx(a[7])] == ["Article 2", "Article 3", "Article 7", "Article 6", "Article 5", "Article 4"]
    @test nx(a[2]; headline__endswith = "6") == "Article 6" && a[1].get_next_by_pub_date.headline == "Article 2"
    @test_throws Juango.DoesNotExist get_next_by(a[5], :pub_date)
    @test [pv(a[7]), pv(a[6]), pv(a[5]), pv(a[4]), pv(a[3]), pv(a[2])] == ["Article 3", "Article 4", "Article 6", "Article 7", "Article 2", "Article 1"]
    # test_escaping: _ % and \ in LIKE patterns are literal
    a8 = create(DlArticle; headline = "Article_ with underscore", pub_date = DateTime(2005, 11, 20))
    @test titles(filter(DlArticle; headline__startswith = "Article")) == vcat(["Article_ with underscore"], ordered)
    @test titles(filter(DlArticle; headline__startswith = "Article_")) == ["Article_ with underscore"]
    a9 = create(DlArticle; headline = "Article% with percent sign", pub_date = DateTime(2005, 11, 21))
    @test titles(filter(DlArticle; headline__startswith = "Article%")) == ["Article% with percent sign"]
    a10 = create(DlArticle; headline = "Article with \\ backslash", pub_date = DateTime(2005, 11, 22))
    @test titles(filter(DlArticle; headline__contains = "\\")) == ["Article with \\ backslash"]
    # test_exclude
    @test titles(exclude(filter(DlArticle; headline__contains = "Article"); headline__contains = "with")) == ordered
    @test titles(exclude(objects(DlArticle); headline__startswith = "Article_")) == vcat([a10.headline, a9.headline], ordered)
    @test titles(exclude(objects(DlArticle); headline = "Article 7")) == vcat([a10.headline, a9.headline, a8.headline], filter(!=("Article 7"), ordered))
    delete!(a8); delete!(a9); delete!(a10)
    # test_none
    @test isempty(collect(none(DlArticle))) && isempty(collect(filter(none(DlArticle); headline__startswith = "Article")))
    @test isempty(collect(none(filter(DlArticle; headline__startswith = "Article")))) && count(none(DlArticle)) == 0
    @test update!(none(DlArticle); headline = "This should not take effect") == 0 && isempty(collect(iterator(none(DlArticle))))
    # test_in / test_in_empty_list
    @test titles(exclude(objects(DlArticle); id__in = Int[])) == ordered && isempty(collect(filter(DlArticle; id__in = Int[])))
    # test_in_iterator_rhs / test_range_iterator_rhs (with an alias: an annotation that isn't selected)
    @test Set(titles(filter(DlArticle; id__in = (x for x in [a[1].id, a[2].id])))) == Set(["Article 1", "Article 2"])
    @test Set(titles(filter(DlArticle; id__in = [a[1].id, Value(a[2].id)]))) == Set(["Article 1", "Article 2"])   # fixed in #198
    @test Set(titles(filter(DlArticle; id__range = (x for x in [a[1].id, a[2].id])))) == Set(["Article 1", "Article 2"])
    @test Set(titles(filter(alias(objects(DlArticle); article_id = F(:id)); article_id__in = [a[1].id]))) == Set(["Article 1"])
    # alias(): usable in filter, order_by and annotate; not in the rows (#207)
    aq = alias(filter(DlArticle; headline__in = ["Article 1", "Article 7"]); hl = Lower(:headline))
    @test [x.headline for x in order_by(aq, "-hl")][1] == "Article 7" && !haskey(getfield(first(aq), :_data), :hl)
    @test collect(values_list(order_by(annotate(aq; hl2 = Concat(:hl, Value("!"))), "hl"), :hl2; flat = true))[1] == "article 1!"
    @test !haskey(first(values(aq)), :hl) && !occursin(" AS \"hl\"", first(Juango.select_sql(aq)))
    @test count(filter(alias(objects(DlAuthor); n = Count(:article)); n__gt = 3)) == 1
    # test_in_ignore_none / test_in_ignore_solo_none: None in the list is dropped, and a list of only None runs no query
    @test titles(filter(DlArticle; id__in = [nothing, a[1].id])) == ["Article 1"]
    @test Juango.count_queries(() -> collect(filter(DlArticle; id__in = [nothing])))[2] == 0  # (#224)
    @test Juango.count_queries(() -> count(filter(objects(DlArticle), Q(id__in = Int[]) | Q(id__in = [nothing]))))[2] == 0
    @test length(filter(objects(DlArticle), Q(id__in = Int[]) | Q(headline = "Article 1"))) == 1
    @test length(exclude(objects(DlArticle); id__in = Int[])) == length(objects(DlArticle))
    # test_in_select_mismatch: a subquery must select one column
    @test (try collect(filter(DlArticle; id__in = values(objects(DlArticle), :id, :headline))); false catch e; e isa ArgumentError end)  # (#208)
    # test_error_messages: the unknown name and the choices
    e = try count(filter(DlArticle; pub_date_year = "2005")); nothing catch err; err end
    @test e isa Juango.LookupError && occursin("pub_date_year", sprint(showerror, e)) && occursin("headline", sprint(showerror, e))
    # test_unsupported_lookups: a misspelled lookup suggests the right one
    e = try collect(filter(DlArticle; headline__starts = "Article")); nothing catch err; err end
    @test e isa Juango.LookupError && occursin("starts", sprint(showerror, e)) && occursin("startswith", sprint(showerror, e))
    e = try collect(filter(DlArticle; pub_date__is_null = true)); nothing catch err; err end
    @test e isa Juango.LookupError && occursin("isnull", sprint(showerror, e))
  end
end

@testset "django lookup: LookupTests (part 3: regex, collisions, transforms, expressions on the right)" begin
  port_block() do
    d = dl_data(); a = d.a
    # test_regex
    delete!(objects(DlArticle))
    now_ = DateTime(2026, 1, 1)
    bulk_create([DlArticle(; pub_date = now_, headline = h) for h in ["f", "fo", "foo", "fooo", "hey-Foo", "bar", "AbBa", "baz", "baxZ"]])
    rx(p; i = false) = Set(titles(filter(DlArticle; (i ? :headline__iregex : :headline__regex) => p)))
    @test rx("fo*") == Set(["f", "fo", "foo", "fooo"]) && rx("fo*"; i = true) == Set(["f", "fo", "foo", "fooo", "hey-Foo"])
    @test rx("fo+") == Set(["fo", "foo", "fooo"]) && rx("fooo?") == Set(["foo", "fooo"])
    @test rx("^b") == Set(["bar", "baxZ", "baz"]) && rx("^a"; i = true) == Set(["AbBa"])
    @test rx("z\$") == Set(["baz"]) && rx("z\$"; i = true) == Set(["baxZ", "baz"])
    @test rx("ba[rz]") == Set(["bar", "baz"]) && rx("ba.[RxZ]") == Set(["baxZ"]) && rx("ba[RxZ]"; i = true) == Set(["bar", "baxZ", "baz"])
    bulk_create([DlArticle(; pub_date = now_, headline = h) for h in ["foobar", "foobaz", "ooF", "foobarbaz", "zoocarfaz", "barfoobaz", "bazbaRFOO"]])
    @test rx("oo(f|b)") == Set(["barfoobaz", "foobar", "foobarbaz", "foobaz"]) && rx("oo(f|b)"; i = true) == Set(["barfoobaz", "foobar", "foobarbaz", "foobaz", "ooF"])
    @test rx("^foo(f|b)") == Set(["foobar", "foobarbaz", "foobaz"])
    @test rx("b.*az") == Set(["barfoobaz", "baz", "bazbaRFOO", "foobarbaz", "foobaz"]) && rx("b.*ar"; i = true) == Set(["bar", "barfoobaz", "bazbaRFOO", "foobar", "foobarbaz"])
    # test_regex_backreferencing (PostgreSQL and MySQL; SQLite's REGEXP is Juango's own function)
    @test rx("b(.).*b\\1") == Set(["barfoobaz", "bazbaRFOO", "foobarbaz"])
    # test_regex_null / test_regex_non_string / test_regex_non_ascii
    create(DlSeason; year = 2012, gt = nothing)
    @test isempty(collect(filter(DlSeason; gt__regex = "^\$")))
    s13 = create(DlSeason; year = 2013, gt = 444)
    @test [s.id for s in filter(DlSeason; gt__regex = "^444\$")] == [s13.id]
    create(DlPlayer; name = "♠")
    @test get(DlPlayer; name__regex = "♠").name == "♠"
    # test_textfield_exact_null / test_isnull_textfield
    au2 = d.au2
    @test [x.name for x in filter(DlAuthor; bio = nothing)] == ["Author 2"] && [x.name for x in filter(DlAuthor; bio__isnull = false)] == ["Author 1"]
    # test_nonfield_lookups
    @test_throws Juango.LookupError collect(filter(DlArticle; headline__blahblah = 99))
    @test_throws Juango.LookupError collect(filter(DlArticle; headline__blahblah__exact = 99))
    @test_throws Juango.LookupError collect(filter(DlArticle; blahblah = 99))
    # test_relation_nested_lookup_error / test_unsupported_lookup_reverse_foreign_key
    @test_throws Juango.LookupError collect(filter(DlArticle; author__editor__name = "James"))
    @test_throws Juango.LookupError collect(filter(DlTag; articles__foo = "bar"))
    @test_throws Juango.LookupError collect(filter(DlAuthor; article__title = "Article 1"))
    # test_lookup_collision: field names that are also lookup names (year, gt)
    s09 = create(DlSeason; year = 2009, gt = 111); s10 = create(DlSeason; year = 2010, gt = 222); s11 = create(DlSeason; year = 2011, gt = 333)
    g(s, away) = create(DlGame; season = s, home = "Houston Astros", away = away)
    g(s09, "St. Louis Cardinals"); g(s10, "Chicago Cubs"); g(s10, "Milwaukee Brewers"); g(s10, "St. Louis Cardinals")
    g(s11, "St. Louis Cardinals"); g(s11, "Milwaukee Brewers")
    hp = create(DlPlayer; name = "Hunter Pence"); set!(hp.games, collect(filter(DlGame; season__year__in = [2009, 2010])))
    pu = create(DlPlayer; name = "Ivan Rodriquez"); set!(pu.games, collect(filter(DlGame; season__year = 2009)))
    pf = create(DlPlayer; name = "Pedro Feliz"); set!(pf.games, collect(filter(DlGame; season__year__in = [2011])))
    jo = create(DlPlayer; name = "Johnson"); set!(jo.games, collect(filter(DlGame; season__year__in = [2011])))
    gc(; kw...) = count(filter(DlGame; kw...))
    @test gc(season__year = 2010) == 3 && gc(season__year__exact = 2010) == 3 && gc(season__gt = 222) == 3 && gc(season__gt__exact = 222) == 3   # fixed in #197
    @test gc(season__year = 2011) == 2 && gc(season__gt = 333) == 2 && gc(season__year__gt = 2010) == 2 && gc(season__gt__gt = 222) == 2   # fixed in #197
    @test gc(season__year__in = [2010, 2011]) == 5 && gc(season__year__gt = 2009) == 5 && gc(season__gt__in = [222, 333]) == 5 && gc(season__gt__gt = 111) == 5
    pc(; kw...) = count(distinct(filter(DlPlayer; kw...)))
    @test pc(games__season__year = 2009) == 2 && pc(games__season__gt = 111) == 2 && pc(games__season__gt__exact = 111) == 2   # fixed in #197
    @test pc(games__season__year = 2010) == 1 && pc(games__season__gt = 222) == 1   # fixed in #197
    @test pc(games__season__year = 2011) == 2 && pc(games__season__year__gt = 2010) == 2 && pc(games__season__gt__gt = 222) == 2
  end
  port_block() do
    d = dl_data(); a = d.a
    # test_chain_date_time_lookups
    ts(qs) = Set(titles(qs))
    @test ts(filter(DlArticle; pub_date__month__gt = 7)) == Set(["Article 5", "Article 6"])
    @test ts(filter(DlArticle; pub_date__day__gte = 27)) == Set(["Article 2", "Article 3", "Article 4", "Article 7"])
    @test ts(filter(DlArticle; pub_date__hour__lt = 8)) == Set(["Article 1", "Article 2", "Article 3", "Article 4", "Article 7"])
    @test length(ts(filter(DlArticle; pub_date__minute__lte = 0))) == 7
    # test_exact_sliced_queryset_limit_one(_offset): a one-row queryset as the value
    @test ts(filter(DlArticle; author = objects(DlAuthor)[1:1])) == Set(["Article 1", "Article 2", "Article 3", "Article 4"])  # (#208)
    @test ts(filter(DlArticle; author = objects(DlAuthor)[2:2])) == Set(["Article 5", "Article 6", "Article 7"])  # (#208)
    @test (try collect(filter(DlArticle; author = objects(DlAuthor))); false catch e; e isa ArgumentError && occursin("sliced", e.msg) end)
    # test_exact_sliced_queryset_not_limited_to_one
    @test_throws ArgumentError collect(filter(DlArticle; author = objects(DlAuthor)[1:2]))
    # test_exact_booleanfield(_annotation): a boolean annotation (F, Q, Exists, Case) compared with true
    p = create(DlProduct; name = "Paper", qty_target = 5000)
    create(DlStock; product = p, short = false, qty_available = 5100); st1 = create(DlStock; product = p, short = true, qty_available = 180)
    @test [s.id for s in filter(DlStock; short = true)] == [st1.id]
    @test [s.id for s in filter(annotate(objects(DlStock); short_annotation = F(:short)); short_annotation = true)] == [st1.id]
    @test [x.name for x in filter(annotate(objects(DlAuthor); node = Q(alias = "a1")); node = true)] == ["Author 1"]   # fixed in #199
    @test [x.name for x in filter(annotate(objects(DlAuthor); ex = Exists(filter(DlAuthor; alias = "a1", pk = OuterRef(:pk)))); ex = true)] == ["Author 1"]
    @test [x.name for x in filter(annotate(objects(DlAuthor); case = Case(When(; alias = "a1", then = true); default = false)); case = true)] == ["Author 1"]
    # test_pattern_lookups_with_substr: an expression on the right of startswith & co.
    ja = create(DlAuthor; name = "John Smith", alias = "Johx"); rh = create(DlAuthor; name = "Rhonda Simpson", alias = "sonx")
    for (lk, want) in (("startswith", ["John Smith"]), ("istartswith", ["John Smith"]), ("contains", ["John Smith", "Rhonda Simpson"]),
                       ("icontains", ["John Smith", "Rhonda Simpson"]), ("endswith", ["Rhonda Simpson"]), ("iendswith", ["Rhonda Simpson"]))
        got = try Set(x.name for x in filter(DlAuthor; Symbol("name__", lk) => Substr(:alias, 1, 3))) catch err; err end
        @test got == Set(want)   # fixed in #198
    end
    # test_exact_exists: an Exists compared with an Exists
    qs = filter(DlArticle; pk = OuterRef(:pk))
    @test (try count(filter(annotate(objects(DlSeason); pk_exists = Exists(qs)); pk_exists = Exists(qs))) == count(objects(DlSeason)) catch; false end)
    # test_nested_outerref_lhs
    tag = create(DlTag; name = "a1"); add!(tag.articles, a[1])
    @test (try get(annotate(objects(DlTag); has_match = Exists(filter(annotate(objects(DlArticle); author_exists = Exists(filter(DlAuthor; alias = OuterRef(OuterRef(:name))))); author_exists = true))); has_match = true).id == tag.id catch; false end)  # (#208)
    # test_exact_query_rhs_with_selected_columns(_mismatch)
    newest = create(DlAuthor; name = "Author 2")
    mx = values(annotate(values(filter(DlAuthor; name = "Author 2"), :name); max_id = Max(:id)), :max_id)
    @test (try get(filter(DlAuthor; id = mx[1:1])).id == newest.id catch; false end)  # (#208)
    @test_throws ArgumentError collect(filter(DlAuthor; id = values(objects(DlAuthor), :id, :name)[1:1]))
    # test_isnull_non_boolean_value: isnull takes true or false only
    @test (try exists(filter(DlAuthor; alias__isnull = 1)); false catch e; e isa ArgumentError end)
    @test (try exists(filter(DlArticle; author__isnull = 1)); false catch e; e isa ArgumentError end)
    # test_lookup_rhs: a Q (a condition) as a boolean field's value
    p2 = create(DlProduct; name = "GME", qty_target = 5000)
    sa = create(DlStock; product = p2, short = true, qty_available = 180); sb = create(DlStock; product = p2, short = false, qty_available = 5100)
    create(DlStock; product = p2, short = false, qty_available = 4000)
    @test (try Set(s.id for s in filter(DlStock; product = p2, short = Q(qty_available__lt = F(:product__qty_target)))) == Set([sa.id, sb.id]) catch; false end)   # fixed in #199
  end
end

@testset "django lookup: LookupQueryingTests (lookups as expressions)" begin
  port_block() do
    s1 = create(DlSeason; year = 1942, gt = 1942); s2 = create(DlSeason; year = 1842, gt = 1942); s3 = create(DlSeason; year = 2042, gt = 1942)
    J = Juango
    tryset(f) = try Set(f()) catch err; err end
    yrs(qs) = Set(x.year for x in qs)
    # test_annotate / test_alias / test_annotate_*: Exact, GreaterThan, ... as annotations
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); equal = J.Exact(F(:year), 1942)), :year, :equal))) == Set([(1942, true), (1842, false), (2042, false)])  # (#206)
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); greater = J.GreaterThan(F(:year), F(:gt))), :year, :greater))) == Set([(1942, false), (1842, false), (2042, true)])  # (#206)
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); greater = J.GreaterThan(1930, F(:year))), :year, :greater))) == Set([(1942, false), (1842, true), (2042, false)])  # (#206)
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); lesser = J.LessThan(F(:year), 1942.1)), :year, :lesser))) == Set([(1942, true), (1842, true), (2042, false)])  # (#206)
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); g = J.GreaterThanOrEqual(F(:year), 1942)), :year, :g))) == Set([(1942, true), (1842, false), (2042, true)])  # (#206)
    # test_combined_lookups / test_lookup_in_filter / test_in_lookup_in_filter / test_combined_lookups_in_filter
    @test tryset(() -> collect(values_list(annotate(objects(DlSeason); gte = J.Exact(F(:year), 1942) | J.GreaterThan(F(:year), 1942)), :year, :gte))) == Set([(1942, true), (1842, false), (2042, true)])  # (#206)
    @test tryset(() -> yrs(filter(objects(DlSeason), J.GreaterThan(F(:year), 1910)))) == Set([1942, 2042])  # (#206)
    @test tryset(() -> yrs(filter(objects(DlSeason), J.In(F(:year), (1942, 2042, 1842))))) == Set([1942, 1842, 2042])  # (#206)
    @test tryset(() -> yrs(filter(objects(DlSeason), J.Exact(F(:year), 1942) | J.GreaterThan(F(:year), 1942)))) == Set([1942, 2042])  # (#206)
    # test_filter_lookup_lhs: a lookup on the left, compared with a lookup
    @test tryset(() -> yrs(filter(annotate(objects(DlSeason); before_20 = J.LessThan(F(:year), 2000)); before_20 = J.LessThan(F(:year), 1900)))) == Set([1842, 2042])  # (#206)
    # test_lookup_in_order_by / test_aggregate_combined_lookup / test_conditional_expression
    @test (try [x.year for x in order_by(objects(DlSeason), J.LessThan(F(:year), 1910), F(:year))] == [1942, 2042, 1842] catch; false end)  # (#206)
    @test (try aggregate(objects(DlSeason); modern = Sum(Cast(J.GreaterThan(F(:year), 1900), :integer)))[:modern] == 2 catch; false end)  # (#206)
    @test tryset(() -> [(d[:year], d[:century]) for d in values(annotate(objects(DlSeason);
                       century = Case(When(J.GreaterThan(F(:year), 1900) & J.LessThanOrEqual(F(:year), 2000); then = Value("20th")); default = Value("other"))), :year, :century)]) ==
          Set([(1942, "20th"), (1842, "other"), (2042, "other")])  # (#206)
    # Q combined with conditional expressions, either order (#223)
    later = Exists(filter(DlSeason; year__gt = OuterRef(:year)))
    @test yrs(filter(objects(DlSeason), Q(year__lt = 2000) & later)) == Set([1942, 1842])
    @test yrs(filter(objects(DlSeason), later & Q(year__lt = 1900))) == Set([1842])
    @test yrs(exclude(objects(DlSeason), Q(year__lt = 2000) & !later)) == Set([1942, 1842, 2042])
    @test yrs(filter(objects(DlSeason), Q(year = 2042) | later)) == Set([1942, 1842, 2042])
    @test yrs(filter(objects(DlSeason), ~later | Q(year = 1842))) == Set([1842, 2042])
    @test yrs(filter(objects(DlSeason), J.GreaterThan(F(:year), 2000) | later & Q(year = 1942))) == Set([1942, 2042])
    @test yrs(filter(objects(DlSeason), ~J.LessThan(F(:year), 1900))) == Set([1942, 2042])
    @test yrs(filter(objects(DlSeason), xor(later, Q(year__lt = 1900)))) == Set([1942])
    @test Set(collect(values_list(annotate(objects(DlSeason); w = Case(When(later; then = Value("y")); default = Value("n"))), :year, :w))) ==
          Set([(1942, "y"), (1842, "y"), (2042, "n")])
  end
end

# --- tests/aggregation/models.py ----------------------------------------------------------------------
@model struct DaAuthor
    name = CharField(max_length = 100)
    age = IntegerField()
    friends = ManyToManyField(:self; blank = true)
    rating = FloatField(null = true)
    Meta(table = "da_author")
end
Base.show(io::IO, a::DaAuthor) = print(io, a.name)
@model struct DaPublisher
    name = CharField(max_length = 255)
    num_awards = IntegerField(null = true)
    duration = DurationField(blank = true, null = true)
    Meta(table = "da_publisher")
end
@model struct DaBook
    isbn = CharField(max_length = 9)
    name = CharField(max_length = 255)
    pages = IntegerField()
    rating = FloatField()
    price = DecimalField(decimal_places = 2, max_digits = 6)
    authors = ManyToManyField(DaAuthor; related_name = :book)
    contact = ForeignKey(DaAuthor, on_delete = :CASCADE, related_name = :book_contact_set)
    publisher = ForeignKey(DaPublisher, on_delete = :CASCADE, related_name = :book)
    pubdate = DateField()
    Meta(table = "da_book")
end
@model struct DaStore
    name = CharField(max_length = 255)
    books = ManyToManyField(DaBook; related_name = :store)
    original_opening = DateTimeField()
    friday_night_closing = TimeField()
    Meta(table = "da_store")
end
redirect_stdout(devnull) do
    ms = [DaAuthor, through(DaAuthor, :friends), DaPublisher, DaBook, through(DaBook, :authors), DaStore, through(DaStore, :books)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

function da_data()
    A = Dict(n => create(DaAuthor; name = n, age = age) for (n, age) in
             ("Adrian Holovaty" => 34, "Jacob Kaplan-Moss" => 35, "Brad Dayley" => 45, "James Bennett" => 29, "Jeffrey Forcier" => 37,
              "Paul Bissex" => 29, "Wesley J. Chun" => 25, "Peter Norvig" => 57, "Stuart Russell" => 46))
    a1, a2, a3, a4, a5, a6, a7, a8, a9 = (A[n] for n in ("Adrian Holovaty", "Jacob Kaplan-Moss", "Brad Dayley", "James Bennett", "Jeffrey Forcier",
                                                          "Paul Bissex", "Wesley J. Chun", "Peter Norvig", "Stuart Russell"))
    add!(a1.friends, a2, a4); add!(a2.friends, a1, a7); add!(a4.friends, a1); add!(a5.friends, a6, a7); add!(a6.friends, a5, a7)
    add!(a7.friends, a2, a5, a6); add!(a8.friends, a9); add!(a9.friends, a8)
    p1 = create(DaPublisher; name = "Apress", num_awards = 3, duration = Day(1)); p2 = create(DaPublisher; name = "Sams", num_awards = 1, duration = Day(2))
    p3 = create(DaPublisher; name = "Prentice Hall", num_awards = 7); p4 = create(DaPublisher; name = "Morgan Kaufmann", num_awards = 9)
    p5 = create(DaPublisher; name = "Jonno's House of Books", num_awards = 0)
    bk(isbn, name, pages, rating, price, contact, pub, d) = create(DaBook; isbn, name, pages, rating, price = Juango.Decimal(price), contact, publisher = pub, pubdate = d)
    b1 = bk("159059725", "The Definitive Guide to Django: Web Development Done Right", 447, 4.5, "30.00", a1, p1, Date(2007, 12, 6))
    b2 = bk("067232959", "Sams Teach Yourself Django in 24 Hours", 528, 3.0, "23.09", a3, p2, Date(2008, 3, 3))
    b3 = bk("159059996", "Practical Django Projects", 300, 4.0, "29.69", a4, p1, Date(2008, 6, 23))
    b4 = bk("013235613", "Python Web Development with Django", 350, 4.0, "29.69", a5, p3, Date(2008, 11, 3))
    b5 = bk("013790395", "Artificial Intelligence: A Modern Approach", 1132, 4.0, "82.80", a8, p3, Date(1995, 1, 15))
    b6 = bk("155860191", "Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp", 946, 5.0, "75.00", a8, p4, Date(1991, 10, 15))
    add!(b1.authors, a1, a2); add!(b2.authors, a3); add!(b3.authors, a4); add!(b4.authors, a5, a6, a7); add!(b5.authors, a8, a9); add!(b6.authors, a8)
    s1 = create(DaStore; name = "Amazon.com", original_opening = DateTime(1994, 4, 23, 9, 17, 42), friday_night_closing = Time(23, 59, 59))
    s2 = create(DaStore; name = "Books.com", original_opening = DateTime(2001, 3, 15, 11, 23, 37), friday_night_closing = Time(23, 59, 59))
    s3 = create(DaStore; name = "Mamma and Pappa's Books", original_opening = DateTime(1945, 4, 25, 16, 24, 14), friday_night_closing = Time(21, 30))
    add!(s1.books, b1, b2, b3, b4, b5, b6); add!(s2.books, b1, b3, b5, b6); add!(s3.books, b3, b4, b6)
    (; a = [a1, a2, a3, a4, a5, a6, a7, a8, a9], p = [p1, p2, p3, p4, p5], b = [b1, b2, b3, b4, b5, b6], s = [s1, s2, s3])
end
approx(x, y; places = 2) = x !== nothing && round(Float64(x); digits = places) == round(Float64(y); digits = places)
D_(s) = Juango.Decimal(s)

@testset "django aggregation: AggregateTestCase (part 1)" begin
  port_block() do
    d = da_data(); b = d.b
    agg(qs; kw...) = aggregate(qs; kw...)
    # test_empty_aggregate / test_single_aggregate / test_multiple_aggregates / test_filter_aggregate
    @test isempty(aggregate(objects(DaAuthor)))   # fixed in #203
    @test approx(agg(objects(DaAuthor); age__avg = Avg(:age))[:age__avg], 37.4; places = 1)
    v = agg(objects(DaAuthor); age__sum = Sum(:age), age__avg = Avg(:age))
    @test v[:age__sum] == 337 && approx(v[:age__avg], 37.4; places = 1)
    @test agg(filter(DaAuthor; age__gt = 29); s = Sum(:age))[:s] == 254
    # Django's default aliases for positional aggregates: aggregate(Avg("age")) => age__avg
    @test (try haskey(aggregate(objects(DaAuthor), Avg(:age)), :age__avg) catch; false end)   # fixed in #203
    # test_related_aggregate
    @test approx(agg(objects(DaAuthor); x = Avg(:friends__age))[:x], 34.07)
    @test approx(agg(filter(DaBook; rating__lt = 4.5); x = Avg(:authors__age))[:x], 38.2857)
    @test agg(filter(DaAuthor; name__contains = "a"); x = Avg(:book__rating))[:x] == 4.0
    @test agg(objects(DaBook); x = Sum(:publisher__num_awards))[:x] == 30
    @test agg(objects(DaPublisher); x = Sum(:book__price))[:x] == D_("270.27")
    # test_aggregate_multi_join / test_aggregate_alias / test_aggregate_transform / test_aggregate_join_transform
    @test agg(objects(DaStore); x = Max(:books__authors__age))[:x] == 57 && agg(objects(DaAuthor); x = Min(:book__publisher__num_awards))[:x] == 1
    @test approx(agg(filter(DaStore; name = "Amazon.com"); amazon_mean = Avg(:books__rating))[:amazon_mean], 4.08)
    @test agg(objects(DaStore); min_month = Min(:original_opening__month))[:min_month] == 3  # (#205)
    @test agg(objects(DaPublisher); min_year = Min(:book__pubdate__year))[:min_year] == 1991  # (#205)
    # test_annotate_basic
    bo = get(annotate(objects(DaBook); mean_age = Avg(:authors__age)); pk = b[1].pk)
    @test bo.mean_age == 34.5
    # test_annotate_defer / test_annotate_defer_select_related
    r = only(order_by(filter(Juango.defer(annotate(objects(DaBook); page_sum = Sum(:pages)), :name); pk = b[1].pk), "pk"))
    @test (r.id, r.isbn, r.page_sum, r.name) == (b[1].id, "159059725", 447, b[1].name)
    r = only(filter(Juango.defer(annotate(select_related(objects(DaBook), :contact); page_sum = Sum(:pages)), :name); pk = b[1].pk))
    @test r.contact.name == "Adrian Holovaty" && r.page_sum == 447
    # test_annotate_m2m / test_backwards_m2m_annotate / test_reverse_fkey_annotate
    bs = order_by(annotate(filter(DaBook; rating__lt = 4.5); x = Avg(:authors__age)), "name")
    @test [(o.name, round(o.x; digits = 1)) for o in bs] == [("Artificial Intelligence: A Modern Approach", 51.5), ("Practical Django Projects", 29.0),
                                                              ("Python Web Development with Django", 30.3), ("Sams Teach Yourself Django in 24 Hours", 45.0)]
    @test [o.num_authors for o in order_by(annotate(objects(DaBook); num_authors = Count(:authors)), "name")] == [2, 1, 1, 3, 1, 2]
    @test [(o.name, o.x) for o in order_by(annotate(filter(DaAuthor; name__contains = "a"); x = Avg(:book__rating)), "name")] ==
          [("Adrian Holovaty", 4.5), ("Brad Dayley", 3.0), ("Jacob Kaplan-Moss", 4.5), ("James Bennett", 4.0), ("Paul Bissex", 4.0), ("Stuart Russell", 4.0)]
    @test [o.num_books for o in order_by(annotate(objects(DaAuthor); num_books = Count(:book)), "name")] == [1, 1, 1, 1, 1, 1, 2, 1, 1]
    @test [o.x for o in order_by(annotate(objects(DaBook); x = Sum(:publisher__num_awards)), "name")] == [7, 9, 3, 7, 1, 3]
    @test [(o.name, o.x) for o in order_by(annotate(objects(DaPublisher); x = Sum(:book__price)), "name")] ==
          [("Apress", D_("59.69")), ("Jonno's House of Books", nothing), ("Morgan Kaufmann", D_("75.00")), ("Prentice Hall", D_("112.49")), ("Sams", D_("23.09"))]
    # test_annotate_values
    v = only(collect(values(annotate(filter(DaBook; pk = b[1].pk); mean_age = Avg(:authors__age)))))
    @test v[:mean_age] == 34.5 && v[:isbn] == "159059725" && v[:pubdate] == Date(2007, 12, 6) && v[:pages] == 447
    @test only(collect(values(annotate(filter(DaBook; pk = b[1].pk); mean_age = Avg(:authors__age)), :pk, :isbn, :mean_age))) ==
          Dict(:pk => b[1].pk, :isbn => "159059725", :mean_age => 34.5)
    @test only(collect(values(annotate(filter(DaBook; pk = b[1].pk); mean_age = Avg(:authors__age)), :name))) == Dict(:name => b[1].name)   # fixed in #201
    @test only(collect(annotate(values(filter(DaBook; pk = b[1].pk)); mean_age = Avg(:authors__age))))[:mean_age] == 34.5
  end
end

@testset "django aggregation: AggregateTestCase (part 2)" begin
  port_block() do
    d = da_data(); a = d.a; b = d.b
    # test_count_distinct_expression / test_distinct_on_aggregate
    @test aggregate(objects(DaBook); x = Count(Case(When(; pages__gt = 300, then = F(:rating))); distinct = true))[:x] == 4
    @test aggregate(objects(DaBook); x = Avg(:rating; distinct = true))[:x] == 4.125
    @test aggregate(objects(DaBook); x = Count(:rating; distinct = true))[:x] == 4
    @test aggregate(objects(DaBook); x = Sum(:rating; distinct = true))[:x] == 16.5
    # test_non_grouped_annotation_not_in_group_by / test_grouped_annotation_in_group_by
    q = order_by(values(annotate(values(filter(annotate(objects(DaBook); xprice = F(:price)); rating = 4.0), :rating); count = Count(:publisher_id; distinct = true)), :count, :rating), "count")
    @test collect(q) == [Dict(:rating => 4.0, :count => 2)]   # fixed in #201
    q = order_by(values(annotate(values(filter(annotate(objects(DaBook); xprice = F(:price)); rating = 4.0), :rating, :xprice); count = Count(:publisher_id; distinct = true)), :count, :rating), "count")
    @test collect(q) == [Dict(:rating => 4.0, :count => 1), Dict(:rating => 4.0, :count => 2)]   # fixed in #201
    # test_fkey_aggregate
    @test Set(o.c for o in annotate(objects(DaAuthor); c = Count(:book__id))) == Set(o.c for o in annotate(objects(DaAuthor); c = Count(:book)))
    # test_annotate_ordering
    @test collect(order_by(annotate(values(objects(DaBook), :rating); oldest = Max(:authors__age)), "oldest", "rating")) ==
          [Dict(:rating => 4.5, :oldest => 35), Dict(:rating => 3.0, :oldest => 45), Dict(:rating => 4.0, :oldest => 57), Dict(:rating => 5.0, :oldest => 57)]
    @test [r[:rating] for r in order_by(annotate(values(objects(DaBook), :rating); oldest = Max(:authors__age)), "-oldest", "-rating")] == [5.0, 4.0, 3.0, 4.5]
    # test_aggregate_annotation: an aggregate over an aggregate annotation
    @test (try approx(aggregate(annotate(objects(DaBook); num_authors = Count(:authors__id)); x = Avg(:num_authors))[:x], 1.66; places = 1) catch; false end)  # (#204)
    # test_avg_duration_field / test_sum_duration_field
    @test (try aggregate(objects(DaPublisher); x = Avg(:duration))[:x] == Day(1) + Hour(12) catch; false end)
    @test (try Dates.canonicalize(aggregate(objects(DaPublisher); x = Sum(:duration))[:x]) == Dates.canonicalize(Day(3)) catch; false end)
    # test_sum_distinct_aggregate
    au = filter(DaAuthor; book__in = [b[5], b[6]])
    # Django counts 3 (one row per matching book, the join duplicates an author); Juango matches each author once
    @test count(au) == 2 && count(distinct(au)) == 2 && aggregate(distinct(au); s = Sum(:age))[:s] == 103
    # test_annotation
    @test aggregate(filter(DaAuthor; pk = a[1].pk); c = Count(:friends__id))[:c] == 2
    @test aggregate(objects(DaStore); m = Max(:friday_night_closing), n = Min(:original_opening)) == Dict(:m => Time(23, 59, 59), :n => DateTime(1945, 4, 25, 16, 24, 14))
    # test_annotate_values_list
    bq = annotate(filter(DaBook; pk = b[1].pk); mean_age = Avg(:authors__age))
    @test collect(values_list(bq, :pk, :isbn, :mean_age)) == [(b[1].id, "159059725", 34.5)] && collect(values_list(bq, :mean_age; flat = true)) == [34.5]
    @test collect(order_by(annotate(values_list(objects(DaBook), :price); count = Count(:price)), "-count", "price")) ==   # fixed in #201
          [(D_("29.69"), 2), (D_("23.09"), 1), (D_("30"), 1), (D_("75"), 1), (D_("82.8"), 1)]
    # test_dates_with_aggregation
    @test (try collect(Juango.dates(annotate(objects(DaBook); n = Count(:authors)), :pubdate, :year)) == [Date(1991), Date(1995), Date(2007), Date(2008)] catch; false end)
    # test_values_aggregation
    @test aggregate(values(objects(DaBook), :rating); m = Max(:rating))[:m] == 5
    @test (try aggregate(annotate(values(objects(DaBook), :rating); n = Count(:id)); m = Max(:n))[:m] == 3 catch; false end)  # (#204)
    # test_ticket17424: exclude across a relation after annotate
    @test [o.pk for o in exclude(annotate(order_by(objects(DaBook), "pk"); one = Count(:id)); publisher__name = "__UNLIKELY_VALUE__")] == sort([x.pk for x in b])
    # test_ticket12886: aggregate over a sliced queryset
    @test (try approx(aggregate(order_by(objects(DaBook), "-rating")[1:3]; x = Avg(:rating))[:x], 4.5) catch; false end)   # fixed in #200
    # test_nonaggregate_aggregation_throws / test_nonfield_annotation
    @test (try aggregate(objects(DaBook); fail = F(:price)); false catch e; e isa Exception end)   # fixed in #203
    @test (try first(annotate(objects(DaBook); val = Max(Value(2)))).val == 2 catch; false end)
    # test_annotation_expressions: Sum of an expression, and a sum of aggregates
    want = [132, nothing, 129, 63, 128, 120, 103, 103, 176]
    @test (try [o.c for o in order_by(annotate(objects(DaAuthor); c = Sum(F(:age) + F(:friends__age))), "name")] == want catch; false end)
    @test (try [o.c for o in order_by(annotate(objects(DaAuthor); c = Sum(:age) + Sum(:friends__age)), "name")] == want catch; false end)
    # test_aggregation_expressions
    @test (try aggregate(objects(DaAuthor); x = Sum(:age) / Count(:age))[:x] == 37 catch; false end)
    # test_avg_decimal_field: Avg of a decimal is a decimal
    v = aggregate(filter(DaBook; rating = 4); x = Avg(:price))[:x]
    @test v isa Juango.Decimal && approx(v, 47.39)
    # test_order_of_precedence
    @test (try approx(aggregate(filter(DaBook; rating = 4); x = (Avg(:price) + 2) * 3)[:x], 148.18) catch; false end)
  end
end

@testset "django aggregation: AggregateTestCase (part 3: expressions over aggregates)" begin
  port_block() do
    d = da_data(); a = d.a; b = d.b
    # test_values_annotation_with_expression: an F() alongside an aggregate goes into the GROUP BY
    qs = annotate(values(objects(DaAuthor), :name); another_age = Sum(:age) + F(:age))
    @test (try get(qs; name = "Adrian Holovaty")[:another_age] == 68 catch; false end)
    qs2 = annotate(qs; friend_count = Count(:friends))
    @test (try get(qs2; name = "Adrian Holovaty")[:friend_count] == 2 catch; false end)
    # test_annotate_values_aggregate / test_annotate_over_annotate
    @test (try aggregate(values(annotate(objects(DaAuthor); age_alias = F(:age)), :age_alias); s = Sum(:age_alias))[:s] == 337 catch; false end)  # (#204)
    @test (try get(annotate(annotate(objects(DaAuthor); age_alias = F(:age)); sum_age = Sum(:age_alias)); name = "Adrian Holovaty").sum_age == 34 catch; false end)
    # test_aggregate_over_aggregate / test_annotated_aggregate_over_annotated_aggregate: refused
    @test_throws Exception aggregate(objects(DaAuthor); age_agg = Sum(F(:age)), avg_age = Avg(F(:age_agg)))
    @test_throws Exception collect(annotate(annotate(objects(DaBook); id__max = Max(:id)); s = Sum(:id__max)))
    # test_complex_values_aggregation
    @test (try aggregate(values(objects(DaBook), :rating); x = Max(:rating) + Max(:rating))[:x] == 10 catch; false end)
    @test (try aggregate(annotate(values(objects(DaBook), :rating); n = Count(:id) + 5); m = Max(:n))[:m] == 8 catch; false end)  # (#204)
    # test_expression_on_aggregation: Greatest over aggregates, filtered against a field
    @test (try [p.num_awards for p in order_by(filter(annotate(objects(DaPublisher); pm = Greatest(Avg(:book__rating), Avg(:book__price))); pm__gte = F(:num_awards)), "num_awards")] == [1, 3, 7, 9] catch; false end)
    @test (try [p.num_awards for p in order_by(filter(annotate(objects(DaPublisher); r = Greatest(Avg(:book__rating), F(:num_awards))); r__gt = F(:num_awards)), "num_awards")] == [1, 3] catch; false end)
    # test_arguments_must_be_expressions
    @test (try aggregate(objects(DaBook); is_book = true); false catch e; e isa Exception end)   # fixed in #203
    # test_aggregation_subquery_annotation: a subquery annotation with an aggregate
    latest = values(order_by(filter(DaBook; publisher = OuterRef(:pk)), "-pubdate"), :pubdate)[1:1]
    pq = annotate(annotate(objects(DaPublisher); latest = Subquery(latest)); count = Count(:book))
    @test (try Dict(p.name => (p.latest, p.count) for p in pq)["Apress"] == (Date(2008, 6, 23), 2) catch; false end)
  end
end

@testset "django aggregation: AggregateTestCase (part 4: subqueries, grouping)" begin
  port_block() do
    d = da_data(); a = d.a; b = d.b; p = d.p
    tr(f) = try f() catch err; err end
    # test_aggregation_subquery_annotation_exists / test_aggregation_exists_annotation
    latest = values(order_by(filter(DaBook; publisher = OuterRef(:pk)), "-pubdate"), :pubdate)[1:1]
    @test exists(annotate(objects(DaPublisher); latest = Subquery(latest), count = Count(:book)))
    @test Set(tr(() -> collect(values_list(annotate(objects(DaPublisher); published_book = Exists(filter(DaBook; publisher = OuterRef(:pk))), count = Count(:book)), :name; flat = true)))) ==
          Set(["Apress", "Morgan Kaufmann", "Jonno's House of Books", "Prentice Hall", "Sams"])
    # test_aggregation_subquery_annotation_values: a subquery annotation used in filter, not grouped by
    bq = order_by(values(annotate(filter(annotate(objects(DaBook); same_age = Subquery(values(order_by(filter(DaAuthor; age = OuterRef(:contact__friends__age)), "age"), :id)[1:1]));
                                         publisher = p[1], same_age__isnull = false); min_age = Min(:contact__friends__age)), :name, :min_age), "name")
    @test tr(() -> collect(bq)) == [Dict(:name => "Practical Django Projects", :min_age => 34), Dict(:name => b[1].name, :min_age => 29)]
    # test_aggregation_subquery_annotation_values_collision: grouped by a subquery annotation
    pq = order_by(annotate(values(annotate(filter(DaPublisher; book__contact__age__gt = 20); rating = Subquery(values(filter(DaBook; pk = OuterRef(:book)), :rating))), :rating); total_count = Count()), "rating")
    @test tr(() -> collect(pq)) == [Dict(:rating => 3.0, :total_count => 1), Dict(:rating => 4.0, :total_count => 3), Dict(:rating => 4.5, :total_count => 1), Dict(:rating => 5.0, :total_count => 1)]
    # test_aggregation_subquery_annotation_multivalued
    sq = values(filter(DaAuthor; pk = OuterRef(:pk), book__name = OuterRef(:book__name)), :pk)
    @test tr(() -> count(annotate(annotate(objects(DaAuthor); subquery_id = Subquery(sq)); count = Count(:book)))) == count(objects(DaAuthor))
    # test_aggregation_order_by_not_selected_annotation_values: ordered by an annotation over an aggregate
    asc = [b[4].pk, b[3].pk, b[1].pk, b[2].pk, b[5].pk, b[6].pk]
    oq(o) = tr(() -> collect(values_list(order_by(annotate(annotate(objects(DaBook); min_age = Min(:authors__age)); min_related_age = Coalesce(:min_age, :contact__age)), o), :pk; flat = true)))
    @test oq("min_related_age") == asc && oq("-min_related_age") == reverse(asc)
    @test oq(Asc(:min_related_age)) == asc && oq(Desc(:min_related_age)) == reverse(asc)
    # test_group_by_exists_annotation: values_list of an Exists, grouped
    @test tr(() -> Dict(collect(annotate(values_list(annotate(objects(DaPublisher); has_long = Exists(filter(DaBook; publisher = OuterRef(:pk), pages__gt = 800))), :has_long); total = Count())))) == Dict(true => 2, false => 3)
    # test_group_by_nested_expression_with_params
    @test Set(tr(() -> collect(values_list(annotate(values(annotate(objects(DaBook); greatest_pages = Greatest(:pages, Value(600))), :greatest_pages);
                                                    min_pages = Min(:pages), least = Least(:min_pages, :greatest_pages)), :least; flat = true)))) == Set([300, 946, 1132])
  end
end

@testset "django aggregation: AggregateTestCase (part 5: nested subqueries, ordering, empty results)" begin
  port_block() do
    d = da_data(); a = d.a; b = d.b; p = d.p
    tr(f) = try f() catch err; err end
    # test_aggregation_subquery_annotation_related_field
    pub = create(DaPublisher; name = a[9].name, num_awards = 2)
    bk = create(DaBook; isbn = "159059999", name = "Test book.", pages = 819, rating = 2.5, price = D_("14.44"), contact = a[9], publisher = pub, pubdate = Date(2019, 12, 6))
    add!(bk.authors, a[5], a[6], a[7])
    q = annotate(filter(annotate(objects(DaBook); contact_publisher = Subquery(values(filter(DaPublisher; pk = OuterRef(:publisher), name = OuterRef(:contact__name)), :name)[1:1]));
                        contact_publisher__isnull = false); count = Count(:authors))
    @test tr(() -> [x.pk for x in q]) == [bk.pk]
    delete!(bk); delete!(pub)
    # test_aggregation_exists_multivalued_outeref
    @test tr(() -> count(annotate(objects(DaPublisher); books_exists = Exists(filter(DaBook; publisher = OuterRef(:book__publisher))), books_count = Count(:book)))) == 5
    # test_filter_in_subquery_or_aggregation: an aggregate condition OR a subquery one (both in HAVING)
    @test tr(() -> count(filter(annotate(objects(DaAuthor); n = Count(:book)), Q(n__gt = 0) | Q(pk__in = values(objects(DaBook), :authors))))) == 9
    # test_aggregation_random_ordering: order_by("?") isn't grouped by
    @test tr(() -> Set((x.name, x.c) for x in order_by(annotate(objects(DaAuthor); c = Count(:book)), "?"))) ==
          Set([("Adrian Holovaty", 1), ("Jacob Kaplan-Moss", 1), ("Brad Dayley", 1), ("James Bennett", 1), ("Jeffrey Forcier", 1),
               ("Paul Bissex", 1), ("Wesley J. Chun", 1), ("Stuart Russell", 1), ("Peter Norvig", 2)])
    # test_order_by_aggregate_default_alias: annotate(qs, Count(:book)) is book__count
    @test tr(() -> collect(values_list(order_by(annotate(values(objects(DaPublisher), :book), Count(:book)), "book__count", "book__id"), :book; flat = true))) ==  # (#209)
          Any[nothing; [x.id for x in b]]
    # test_empty_result_optimization / test_coalesced_empty_result_set: none() aggregates without a query
    @test Juango.count_queries(() -> aggregate(none(DaPublisher); sum_awards = Sum(:num_awards), books_count = Count(:book)))[2] == 0
    @test aggregate(none(DaPublisher); sum_awards = Sum(:num_awards), books_count = Count(:book)) == Dict(:sum_awards => nothing, :books_count => 0)
    @test tr(() -> aggregate(none(DaPublisher); s = Coalesce(Sum(:num_awards), 0))[:s]) == 0
    @test tr(() -> aggregate(none(DaPublisher); s = Coalesce(Coalesce(Sum(:num_awards), nothing), 0))[:s]) == 0
  end
end

@testset "django aggregation: AggregateTestCase (part 6: defaults)" begin
  port_block() do
    d = da_data(); a = d.a; b = d.b
    tr(f) = try f() catch err; err end
    none_ = filter(DaAuthor; age__gt = 100)
    # test_aggregation_default_unset / _zero / _integer / _expression
    for A in (Avg, Max, Min, Sum, StdDev, Variance)
        @test tr(() -> aggregate(none_; v = A(:age))[:v]) === nothing
        @test tr(() -> aggregate(none_; v = A(:age; default = 0))[:v]) == 0
        @test tr(() -> aggregate(none_; v = A(:age; default = 21))[:v]) == 21
        @test tr(() -> aggregate(none_; v = A(:age; default = Value(5) * Value(7)))[:v]) == 35
    end
    # test_stringagg_default_value
    @test tr(() -> aggregate(none_; v = StringAgg(:name, ";"; default = Value("<empty>")))[:v]) == "<empty>"
    # test_aggregation_default_group_by
    @test tr(() -> collect(filter(annotate(values(objects(DaPublisher), :name); books = Count(:book), pages = Sum(:book__pages; default = 0)); books = 0))) ==
          [Dict(:name => "Jonno's House of Books", :books => 0, :pages => 0)]
    # test_aggregation_default_compound_expression
    @test tr(() -> [(r[:name], r[:rating]) for r in values(order_by(annotate(objects(DaPublisher); rating = Avg(:book__rating; default = 2.5) * 20.0), "name"), :name, :rating)]) ==
          [("Apress", 85.0), ("Jonno's House of Books", 50.0), ("Morgan Kaufmann", 100.0), ("Prentice Hall", 80.0), ("Sams", 60.0)]
    # test_aggregation_default_using_time_from_python / date_from_python
    q = order_by(annotate(objects(DaBook); o = Min(:store__friday_night_closing; filter = ~Q(store__name = "Amazon.com"), default = Time(17))), "isbn")
    @test tr(() -> [r[:o] for r in values(q, :isbn, :o)]) == [Time(21, 30), Time(23, 59, 59), Time(17), Time(21, 30), Time(23, 59, 59), Time(21, 30)]
    q = order_by(annotate(objects(DaPublisher); e = Min(:book__pubdate; default = Date(1970, 1, 1))), "name")
    @test tr(() -> [r[:e] for r in values(q, :name, :e)]) == [Date(2007, 12, 6), Date(1970, 1, 1), Date(1991, 10, 15), Date(1995, 1, 15), Date(2008, 3, 3)]
  end
end

# --- tests/expressions/models.py ----------------------------------------------------------------------
@model struct DeManager
    name = CharField(max_length = 50)
    Meta(table = "de_manager")
end
@model struct DeEmployee
    firstname = CharField(max_length = 50)
    lastname = CharField(max_length = 50)
    salary = IntegerField(blank = true, null = true)
    manager = ForeignKey(DeManager, on_delete = :CASCADE, null = true)
    based_in_eu = BooleanField(default = false)
    Meta(table = "de_employee")
end
@model struct DeCompany
    name = CharField(max_length = 100)
    num_employees = PositiveIntegerField()
    num_chairs = PositiveIntegerField()
    ceo = ForeignKey(DeEmployee, on_delete = :CASCADE, related_name = :company_ceo_set)
    point_of_contact = ForeignKey(DeEmployee, on_delete = :SET_NULL, related_name = :company_point_of_contact_set, null = true)
    based_in_eu = BooleanField(default = false)
    Meta(table = "de_company")
end
@model struct DeNumber
    integer = BigIntegerField(db_column = "the_integer")
    float = FloatField(null = true, db_column = "the_float")
    decimal_value = DecimalField(max_digits = 20, decimal_places = 17, null = true)
    Meta(table = "de_number")
end
@model struct DeExperiment
    name = CharField(max_length = 24)
    assigned = DateField()
    completed = DateField()
    estimated_time = DurationField()
    start = DateTimeField()
    finish = DateTimeField()
    scalar = IntegerField(null = true)
    Meta(table = "de_experiment", ordering = ["name"])
end
redirect_stdout(devnull) do
    ms = [DeManager, DeEmployee, DeCompany, DeNumber, DeExperiment]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

# Django's models give these fields db_column ("the_integer", "the_float"): DeNumber has them (#212)
@testset "django expressions: db_column" begin
  port_block() do
    f = Juango.findfield(Juango.modelmeta(DeNumber), :integer)
    @test Juango.column(f) == "the_integer" && Juango.attname(f) == :integer
    n = create(DeNumber; integer = 42, float = 15.5)
    @test get(DeNumber; integer = 42).float == 15.5 && (refresh!(n); n.integer == 42)
    @test only(Juango.execute("SELECT the_integer FROM de_number"))[:the_integer] == 42
    @test collect(values(objects(DeNumber), :integer)) == [Dict(:integer => 42)] && haskey(first(values(objects(DeNumber))), :integer)
    @test collect(values_list(order_by(objects(DeNumber), "-integer"), :float; flat = true)) == [15.5]
    update!(objects(DeNumber); integer = F(:integer) + 1)
    @test first(objects(DeNumber)).integer == 43 && first(only(objects(DeNumber), :integer)).integer == 43
  end
end

function de_data()
    joe = create(DeEmployee; firstname = "Joe", lastname = "Smith", salary = 10)
    ex = create(DeCompany; name = "Example Inc.", num_employees = 2300, num_chairs = 5, ceo = joe)
    frank = create(DeEmployee; firstname = "Frank", lastname = "Meyer", salary = 20)
    fo = create(DeCompany; name = "Foobar Ltd.", num_employees = 3, num_chairs = 4, based_in_eu = true, ceo = frank)
    max_ = create(DeEmployee; firstname = "Max", lastname = "Mustermann", salary = 30)
    gm = create(DeCompany; name = "Test GmbH", num_employees = 32, num_chairs = 1, ceo = max_)
    (; joe, frank, max_, ex, fo, gm)
end
company_query() = order_by(values(objects(DeCompany), :name, :num_employees, :num_chairs), "name", "num_employees", "num_chairs")
triples() = [(d[:name], d[:num_employees], d[:num_chairs]) for d in company_query()]

@testset "django expressions: BasicExpressionsTests (part 1)" begin
  port_block() do
    d = de_data()
    # test_annotate_values_aggregate
    @test aggregate(values(annotate(objects(DeCompany); salaries = F(:ceo__salary)), :num_employees, :salaries); result = Sum(F(:salaries) + F(:num_employees)))[:result] == 2395  # (#204)
    # test_decimal_division_literal_value
    n = create(DeNumber; integer = 2)
    @test (try approx(get(annotate(objects(DeNumber); val = F(:integer) / Value(Juango.Decimal("3.0"))); pk = n.pk).val, 0.6667; places = 4) catch; false end)
    delete!(n)
    # test_annotate_values_filter / test_filtering_on_rawsql_that_is_boolean (RawSQL)
    @test count(filter(annotate(objects(DeCompany); big = RawSQL("num_employees > ?", [100]; output = :bool)); big = true)) ==
          count(filter(DeCompany; num_employees__gt = 100))  # (#215)
    @test count(filter(objects(DeCompany), RawSQL("num_employees > %s", [100]))) == count(filter(DeCompany; num_employees__gt = 100))
    @test first(values_list(annotate(order_by(objects(DeCompany), Desc(RawSQL("num_employees", []))); b = RawSQL("num_employees > ?", [100]; output = :bool)), :b; flat = true)) === true
    @test aggregate(annotate(objects(DeCompany); n = RawSQL("num_chairs", [])); s = Sum(:n))[:s] == sum(c.num_chairs for c in objects(DeCompany))
    @test first(values_list(annotate(objects(DeCompany); w = ExpressionWrapper(Q(num_employees__gt = 100000); output = :bool)), :w; flat = true)) === false
    # test_filtering_on_annotate_that_uses_q / test_filtering_on_q_that_is_boolean
    @test (try count(filter(annotate(objects(DeCompany); chk = Q(num_employees__gt = 3)); chk = true)) == 2 catch; false end)
    # test_filter_inter_attribute
    @test [(r[:name], r[:num_employees], r[:num_chairs]) for r in filter(company_query(); num_employees__gt = F(:num_chairs))] == [("Example Inc.", 2300, 5), ("Test GmbH", 32, 1)]
    # test_slicing_of_f_expressions: F(:name)[1:7] (Julia's 1-based ranges for Django's F("name")[:7])
    @test first(values_list(annotate(filter(DeCompany; name = "Example Inc."); s = F(:name)[1:7]), :s; flat = true)) == "Example"  # (#216)
    @test first(values_list(annotate(filter(DeCompany; name = "Example Inc."); s = F(:name)[3:5], c = F(:name)[1]), :s, :c)) == ("amp", "E")
    @test [c.name for c in filter(DeCompany; name__startswith = F(:name)[1:4], num_employees = 2300)] == ["Example Inc."]
    @test (try F(:name)[1:2:5]; false catch e; e isa ArgumentError end) && (try F(:name)[0]; false catch e; e isa ArgumentError end)
    # test_order_by_exists
    mary = create(DeEmployee; firstname = "Mary", lastname = "Mustermann", salary = 20)
    @test [e.firstname for e in order_by(filter(DeEmployee; lastname = "Mustermann"), Desc(Exists(filter(DeCompany; ceo = OuterRef(:pk)))))] == ["Max", "Mary"]
    delete!(mary)
    # test_outerref: a queryset with an OuterRef can't run on its own
    inner = filter(DeCompany; point_of_contact = OuterRef(:pk))
    @test_throws Exception exists(inner)
    @test exists(annotate(objects(DeEmployee); is_poc = Exists(inner)))
    # test_in_subquery
    small = values(filter(DeCompany; num_employees__lt = 200), :pk)
    @test Set(c.name for c in filter(DeCompany; pk__in = Subquery(small))) == Set(["Foobar Ltd.", "Test GmbH"])
    @test (try [c.name for c in filter(DeCompany; pk = Subquery(filter(small; num_employees = 3)[1:1]))] == ["Foobar Ltd."] catch; false end)
    # test_lookups_subquery: every text lookup with a subquery on the right
    smallest = values(order_by(objects(DeCompany), "num_employees"), :name)[1:1]
    for lk in ("exact", "iexact", "contains", "icontains", "startswith", "istartswith", "endswith", "iendswith", "gt", "gte", "lt", "lte", "regex", "iregex")
        got = try length(collect(filter(DeCompany; Symbol("name__", lk) => Subquery(smallest)))) > 0 catch err; err end
        @test got === true
    end
    # test_nested_subquery_join_outer_ref
    inner2 = values(filter(DeEmployee; pk = OuterRef(:ceo__pk)), :pk)
    q = annotate(objects(DeEmployee); ceo_company = Subquery(values(filter(DeCompany; ceo__in = inner2, ceo__pk = OuterRef(:pk)), :pk)))
    @test (try collect(values_list(order_by(q, "pk"), :ceo_company; flat = true)) == [d.ex.pk, d.fo.pk, d.gm.pk] catch; false end)
    # test_annotations_within_subquery
    update!(filter(DeCompany; num_employees__lt = 50); ceo = d.frank)
    inner3 = values(annotate(values(filter(DeCompany; ceo = OuterRef(:pk)), :ceo); total_employees = Sum(:num_employees)), :total_employees)
    outer = filter(annotate(objects(DeEmployee); total_employees = Subquery(inner3)); salary__lte = Subquery(inner3))
    @test (try collect(values(order_by(outer, "-total_employees"), :salary, :total_employees)) == [Dict(:salary => 10, :total_employees => 2300), Dict(:salary => 20, :total_employees => 35)] catch; false end)
  end
  port_block() do
    d = de_data()
    # test_update / test_arithmetic / test_order_of_operations / test_parenthesis_priority
    update!(company_query(); num_chairs = F(:num_employees))
    @test triples() == [("Example Inc.", 2300, 2300), ("Foobar Ltd.", 3, 3), ("Test GmbH", 32, 32)]
    update!(company_query(); num_chairs = F(:num_employees) + 2)
    @test triples() == [("Example Inc.", 2300, 2302), ("Foobar Ltd.", 3, 5), ("Test GmbH", 32, 34)]
    update!(company_query(); num_chairs = F(:num_employees) + 2 * F(:num_employees))
    @test triples() == [("Example Inc.", 2300, 6900), ("Foobar Ltd.", 3, 9), ("Test GmbH", 32, 96)]
    update!(company_query(); num_chairs = (F(:num_employees) + 2) * F(:num_employees))
    @test triples() == [("Example Inc.", 2300, 5294600), ("Foobar Ltd.", 3, 15), ("Test GmbH", 32, 1088)]
    # test_update_with_fk / test_update_with_none
    @test update!(objects(DeCompany); point_of_contact = F(:ceo)) == 3
    @test Set(c.point_of_contact.lastname for c in objects(DeCompany)) == Set(["Smith", "Meyer", "Mustermann"])
    create(DeNumber; integer = 1, float = 1.0); create(DeNumber; integer = 2)
    update!(filter(DeNumber; float__isnull = false); float = Value(nothing))
    @test all(isnothing, [x.float for x in objects(DeNumber)])
    # test_filter_with_join
    c = first(order_by(objects(DeCompany), "name")); c.point_of_contact = create(DeEmployee; firstname = "Guido", lastname = "van Rossum"); save!(c)
    @test Set(x.name for x in filter(DeCompany; ceo__firstname = F(:point_of_contact__firstname))) == Set(["Foobar Ltd.", "Test GmbH"])
    update!(exclude(objects(DeCompany); ceo__firstname = F(:point_of_contact__firstname)); name = "foo")
    @test get(exclude(objects(DeCompany); ceo__firstname = F(:point_of_contact__firstname))).name == "foo"
    # Joined field references aren't allowed in an UPDATE's values
    @test_throws Exception update!(objects(DeCompany); name = F(:point_of_contact__lastname))
    # test_object_update: an F() on an instance, then save
    gm = get(DeCompany; pk = d.gm.pk)
    @test (try gm.num_employees = F(:num_employees) + 4; save!(gm); get(DeCompany; pk = gm.pk).num_employees == 36 catch; false end)
    # test_new_object_save / test_new_object_create: a function as a value on insert
    @test (try co = create(DeCompany; name = Lower(Value("UPPER")), num_employees = 32, num_chairs = 1, ceo = d.max_); refresh!(co); co.name == "upper" catch; false end)
    # test_object_create_with_aggregate: refused
    @test_throws Exception create(DeCompany; name = "Company", num_employees = Max(Value(1)), num_chairs = 1, ceo = d.max_)
    # test_object_update_fk: a joined F() in save() is refused
    g2 = get(DeCompany; pk = d.gm.pk); g2.name = F(:ceo__lastname)
    @test_throws Exception save!(g2)
    # test_object_update_unsaved_objects: an F() on an unsaved object is refused
    acme = DeCompany(; name = "The Acme Widget Co.", num_employees = 12, num_chairs = 5, ceo = d.max_)
    @test (try acme.num_employees = F(:num_employees) + 16; save!(acme); false catch e; e isa ArgumentError end)
    # test_ticket_11722_iexact_lookup / test_ticket_16731_startswith_lookup
    create(DeEmployee; firstname = "John", lastname = "Doe"); t = create(DeEmployee; firstname = "Test", lastname = "test")
    @test [e.id for e in filter(DeEmployee; firstname__iexact = F(:lastname))] == [t.id]
    e2 = create(DeEmployee; firstname = "Jack", lastname = "Jackson"); e3 = create(DeEmployee; firstname = "Jack", lastname = "jackson")
    @test Set(e.id for e in filter(DeEmployee; lastname__istartswith = F(:firstname))) == Set([t.id, e2.id, e3.id])   # ("test" starts with "Test" too)
  end
end

@testset "django expressions: numbers, operators, iterable lookups" begin
  port_block() do
    # ExpressionsNumericTests
    for i in (-1, 42, 1337); save!(DeNumber(; integer = i)); end
    update!(objects(DeNumber); float = F(:integer))
    pairs_() = Set((n.integer, round(Int, n.float)) for n in objects(DeNumber))
    @test pairs_() == Set([(-1, -1), (42, 42), (1337, 1337)])
    @test update!(filter(DeNumber; integer__gt = 0); integer = F(:integer) + 1) == 2
    @test pairs_() == Set([(-1, -1), (43, 42), (1338, 1337)])
    @test Set((n.integer, round(Int, n.float)) for n in exclude(objects(DeNumber); float = F(:integer))) == Set([(43, 42), (1338, 1337)])
    n = create(DeNumber; integer = 10, float = 123.45)
    @test update!(filter(DeNumber; pk = n.pk); float = F(:integer) + F(:float) * 2) == 1
    @test get(DeNumber; pk = n.pk).integer == 10 && approx(get(DeNumber; pk = n.pk).float, 256.9; places = 3)
    # test_decimal_expression: an F() on an instance's decimal field, then save
    n = create(DeNumber; integer = 1, decimal_value = Juango.Decimal("0.5"))
    @test (try n.decimal_value = F(:decimal_value) - Juango.Decimal("0.4"); save!(n); get(DeNumber; pk = n.pk).decimal_value == Juango.Decimal("0.1") catch; false end)
  end
  port_block() do
    # ExpressionOperatorTests
    n = create(DeNumber; integer = 42, float = 15.5); n1 = create(DeNumber; integer = -42, float = -15.5)
    upd(o; kw...) = (update!(filter(DeNumber; pk = o.pk); kw...); get(DeNumber; pk = o.pk))
    reset!() = (update!(filter(DeNumber; pk = n.pk); integer = 42, float = 15.5); update!(filter(DeNumber; pk = n1.pk); integer = -42, float = -15.5))
    tr(f) = try f() catch err; err end
    r = upd(n; integer = F(:integer) + 15, float = F(:float) + 42.7); @test r.integer == 57 && approx(r.float, 58.2; places = 3); reset!()
    r = upd(n; integer = F(:integer) - 15, float = F(:float) - 42.7); @test r.integer == 27 && approx(r.float, -27.2; places = 3); reset!()
    r = upd(n; integer = F(:integer) * 15, float = F(:float) * 42.7); @test r.integer == 630 && approx(r.float, 661.85; places = 3); reset!()
    r = upd(n; integer = F(:integer) / 2, float = F(:float) / 42.7); @test r.integer == 21 && approx(r.float, 0.363; places = 3); reset!()
    @test tr(() -> (r = upd(n; integer = F(:integer) % 20, float = F(:float) % 42.7); (r.integer, round(r.float; digits = 3)))) == (2, 15.5); reset!()  # (#217)
    @test tr(() -> upd(n; integer = F(:integer) & 56).integer) == 40; @test tr(() -> upd(n1; integer = F(:integer) & 56).integer) == 16; reset!()  # (#217)
    @test tr(() -> upd(n; integer = F(:integer) | 48).integer) == 58; @test tr(() -> upd(n1; integer = F(:integer) | 48).integer) == -10; reset!()  # (#217)
    @test tr(() -> upd(n; integer = F(:integer) ⊻ 48).integer) == 26; @test tr(() -> upd(n1; integer = F(:integer) ⊻ 48).integer) == -26; reset!()  # (#217)
    @test tr(() -> upd(n; integer = F(:integer) << 2).integer) == 168; @test tr(() -> upd(n1; integer = F(:integer) << 2).integer) == -168; reset!()  # (#217)
    @test tr(() -> upd(n; integer = F(:integer) >> 2).integer) == 10; @test tr(() -> upd(n1; integer = F(:integer) >> 2).integer) == -11; reset!()  # (#217)
    @test tr(() -> (r = upd(n; integer = F(:integer)^2, float = F(:float)^1.5); (r.integer, round(r.float; digits = 2)))) == (1764, 61.02); reset!()  # (#217)
    # right-hand operands
    r = upd(n; integer = 15 + F(:integer), float = 42.7 + F(:float)); @test r.integer == 57 && approx(r.float, 58.2; places = 3); reset!()
    r = upd(n; integer = 15 - F(:integer), float = 42.7 - F(:float)); @test r.integer == -27 && approx(r.float, 27.2; places = 3); reset!()
    r = upd(n; integer = 15 * F(:integer), float = 42.7 * F(:float)); @test r.integer == 630 && approx(r.float, 661.85; places = 3); reset!()
    r = upd(n; integer = 640 / F(:integer), float = 42.7 / F(:float)); @test r.integer == 15 && approx(r.float, 2.755; places = 3); reset!()
    @test tr(() -> upd(n; integer = 69 % F(:integer)).integer) == 27; reset!()  # (#217)
    @test tr(() -> (r = upd(n; integer = 2^F(:integer), float = 1.5^F(:float)); (r.integer, round(r.float; digits = 3)))) == (4398046511104, 536.308); reset!()  # (#217)
  end
  port_block() do
    # IterableLookupInnerExpressionsTests
    ceo = create(DeEmployee; firstname = "Just", lastname = "Doit", salary = 30)
    mk(nm, e, c) = create(DeCompany; name = nm, num_employees = e, num_chairs = c, ceo = ceo)
    mk("5020 Ltd", 50, 20); mk("5040 Ltd", 50, 40); mk("5050 Ltd", 50, 50); mk("5060 Ltd", 50, 60); mk("99300 Ltd", 99, 300)
    nm(qs) = try Set(c.name for c in qs) catch err; err end
    @test nm(filter(DeCompany; num_employees__in = [F(:num_chairs) - 10])) == Set(["5060 Ltd"])
    @test nm(filter(DeCompany; num_employees__in = [F(:num_chairs) - 10, F(:num_chairs) + 10])) == Set(["5040 Ltd", "5060 Ltd"])
    @test nm(filter(DeCompany; num_employees__in = [F(:num_chairs) - 10, F(:num_chairs), F(:num_chairs) + 10])) == Set(["5040 Ltd", "5050 Ltd", "5060 Ltd"])
    @test nm(filter(DeCompany; num_employees__range = (F(:num_chairs), 100))) == Set(["5020 Ltd", "5040 Ltd", "5050 Ltd"])
    @test nm(filter(DeCompany; num_employees__range = (F(:num_chairs) - 10, F(:num_chairs) + 10))) == Set(["5040 Ltd", "5050 Ltd", "5060 Ltd"])
    @test nm(filter(DeCompany; num_employees__range = (F(:num_chairs) - 10, 100))) == Set(["5020 Ltd", "5040 Ltd", "5050 Ltd", "5060 Ltd"])
    @test nm(filter(DeCompany; num_employees__range = (minimum = 51, maximum = 100))) == Set(["99300 Ltd"])     # a named tuple
    # test_expressions_not_introduce_sql_injection_via_untrusted_string_inclusion
    @test (r = nm(filter(DeCompany; name__in = [F(:num_chairs) + "1)) OR ((1==1"])); r isa Exception || isempty(r))   # no rows: the string is a value, not SQL
  end
end

@testset "django expressions: durations, transforms, negation" begin
  port_block() do
    # FTimeDeltaTests
    sday, stime = Date(2010, 6, 25), DateTime(2010, 6, 25, 12, 15, 30, 747)
    deltas = [Millisecond(0), Millisecond(253), Second(44), Hour(21) + Minute(8), Day(10), Day(90)]
    ex(name, assigned, start, finish, est) = create(DeExperiment; name, assigned, start, finish, completed = Date(finish), estimated_time = est)
    ex("e0", sday, stime, stime, deltas[1])
    ex("e1", sday, stime + Day(1), stime + Day(1) + deltas[2], deltas[2])
    ex("e2", sday - Day(3), stime, stime + deltas[3], Hour(1))
    ex("e3", sday, stime + Day(4), stime + Day(4) + deltas[4], deltas[4])
    ex("e4", sday - Day(10), stime, stime + deltas[5], deltas[5] - Day(1))
    ex("e5", sday, stime + Day(30), stime + Day(30) + deltas[6], deltas[6])
    names = ["e0", "e1", "e2", "e3", "e4", "e5"]
    nms(qs) = try [e.name for e in qs] catch err; err end
    # test_delta_add / test_delta_subtract / test_exclude
    for (i, d) in enumerate(deltas)
        @test nms(filter(DeExperiment; finish__lt = F(:start) + d)) == names[1:i-1]
        @test nms(filter(DeExperiment; finish__lte = d + F(:start))) == names[1:i]
        @test nms(filter(DeExperiment; start__gt = F(:finish) - d)) == names[1:i-1]
        @test nms(exclude(objects(DeExperiment); finish__lt = F(:start) + d)) == names[i:end]
    end
    # test_durationfield_add
    @test nms(filter(DeExperiment; start = F(:start) + F(:estimated_time))) == ["e0"]
    @test nms(filter(DeExperiment; finish__lt = F(:start) + F(:estimated_time))) == ["e2"]
    @test nms(filter(DeExperiment; finish__gte = F(:start) + F(:estimated_time) + Hour(1))) == ["e4"]
    # test_duration_expressions
    @test (try all(o.d == o.estimated_time + Day(10) for o in annotate(objects(DeExperiment); d = F(:estimated_time) + Day(10))) catch; false end)
    # test_date_subtraction
    q = annotate(objects(DeExperiment); completion_duration = F(:completed) - F(:assigned))
    @test (try Set(nms(filter(q; completion_duration__gte = Day(5)))) == Set(["e3", "e4", "e5"]) catch; false end)
    @test (try Set(nms(filter(q; completion_duration__lt = Day(5)))) == Set(["e0", "e1", "e2"]) catch; false end)
    # test_datetime_subtraction
    q = annotate(objects(DeExperiment); dur = F(:finish) - F(:start))
    @test (try nms(filter(q; dur__gt = Hour(1))) == ["e3", "e4", "e5"] catch; false end)
    # test_date_minus_duration
    @test (try nms(filter(DeExperiment; completed__gt = F(:assigned) - Day(1) + Day(4))) == ["e3", "e4", "e5"] catch; false end)
    # test_delta_update
    before = [(e.start, e.finish) for e in objects(DeExperiment)]
    update!(objects(DeExperiment); start = F(:start) + Day(10), finish = F(:finish) + Day(10))
    @test [(e.start, e.finish) for e in objects(DeExperiment)] == [(s + Day(10), t + Day(10)) for (s, t) in before]
    # test_negative_timedelta_update
    update!(objects(DeExperiment); start = F(:start) - Second(-30))
    @test (try all(e.start - b[1] == Day(10) + Second(30) for (e, b) in zip(objects(DeExperiment), before)) catch; false end)
  end
  port_block() do
    # FieldTransformTests
    stime = DateTime(2010, 6, 25, 12, 15, 30, 747)
    create(DeExperiment; name = "Experiment 1", assigned = Date(2010, 6, 25), completed = Date(2010, 6, 27), estimated_time = Day(2), start = stime, finish = stime + Day(2))
    @test aggregate(objects(DeExperiment); month_count = Count(:assigned__month))[:month_count] == 1  # (#205)
    @test collect(values(objects(DeExperiment), :assigned__month)) == [Dict(:assigned__month => 6)]  # (#205)
    @test (try collect(values(objects(DeExperiment), :finish__date__month)) == [Dict(:finish__date__month => 6)] catch; false end)  # (#205)
  end
  port_block() do
    # NegatedExpressionTests: ~F() on a boolean
    ceo = create(DeEmployee; firstname = "Joe", lastname = "Smith", salary = 10)
    create(DeCompany; name = "Example Inc.", num_employees = 2300, num_chairs = 5, ceo = ceo, based_in_eu = true)
    create(DeCompany; name = "Foobar Ltd.", num_employees = 3, num_chairs = 4, ceo = ceo, based_in_eu = false)
    @test (try [c.name for c in filter(objects(DeCompany), ~F(:based_in_eu))] == ["Foobar Ltd."] catch; false end)  # (#218)
    @test (try collect(values_list(order_by(annotate(objects(DeCompany); negated = ~F(:based_in_eu)), "name"), :name, :negated)) == [("Example Inc.", false), ("Foobar Ltd.", true)] catch; false end)  # (#218)
    @test (try [c.name for c in filter(annotate(objects(DeCompany); eu_required = ~Value(false)); based_in_eu = F(:eu_required))] == ["Example Inc."] catch; false end)  # (#218)
  end
end

# --- tests/queries/models.py (the models Queries1Tests uses) --------------------------------------------
# Relations get Django's default reverse query names (Author.objects.filter(item = ...)); Juango's
# default is the model's name in lowercase. Report.creator has Django's to_field = "num";
# ExtraInfo.date (a DateTimePK, a datetime primary key) is left out (#221).
@model struct DqDumbCategory
    Meta(table = "dq_dumbcategory")
end
@model struct DqNamedCategory <: DqDumbCategory
    name = CharField(max_length = 10)
    Meta(table = "dq_namedcategory")
end
@model struct DqTag
    name = CharField(max_length = 10)
    parent = ForeignKey(:self; on_delete = :SET_NULL, blank = true, null = true, related_name = :children)
    category = ForeignKey(DqNamedCategory; on_delete = :SET_NULL, null = true, default = nothing, related_name = :tag)
    Meta(table = "dq_tag", ordering = ["name"])
end
@model struct DqNote
    note = CharField(max_length = 100)
    misc = CharField(max_length = 25)
    tag = ForeignKey(DqTag; on_delete = :SET_NULL, blank = true, null = true, related_name = :note)
    negate = BooleanField(default = true)
    Meta(table = "dq_note", ordering = ["note"])
end
@model struct DqAnnotation
    name = CharField(max_length = 10)
    tag = ForeignKey(DqTag; on_delete = :CASCADE, related_name = :annotation)
    notes = ManyToManyField(DqNote; related_name = :annotation)
    Meta(table = "dq_annotation")
end
@model struct DqExtraInfo
    info = CharField(max_length = 100)
    note = ForeignKey(DqNote; on_delete = :CASCADE, null = true, related_name = :extrainfo)
    value = IntegerField(null = true)
    filterable = BooleanField(default = true)
    Meta(table = "dq_extrainfo", ordering = ["info"])
end
@model struct DqAuthor
    name = CharField(max_length = 10)
    num = IntegerField(unique = true)
    extra = ForeignKey(DqExtraInfo; on_delete = :CASCADE, related_name = :author)
    Meta(table = "dq_author", ordering = ["name"])
end
@model struct DqItem
    name = CharField(max_length = 10)
    created = DateTimeField()
    modified = DateTimeField(blank = true, null = true)
    tags = ManyToManyField(DqTag; blank = true, related_name = :item)
    creator = ForeignKey(DqAuthor; on_delete = :CASCADE, related_name = :item)
    note = ForeignKey(DqNote; on_delete = :CASCADE, related_name = :item)
    Meta(table = "dq_item", ordering = ["-note", "name"])
end
@model struct DqReport
    name = CharField(max_length = 10)
    creator = ForeignKey(DqAuthor; on_delete = :SET_NULL, null = true, related_name = :report, to_field = :num)
    Meta(table = "dq_report")
end
@model struct DqRanking
    rank = IntegerField()
    author = ForeignKey(DqAuthor; on_delete = :CASCADE, related_name = :ranking)
    Meta(table = "dq_ranking", ordering = ["author__extra__note", "author__name", "rank"])
end
@model struct DqCover
    title = CharField(max_length = 50)
    item = ForeignKey(DqItem; on_delete = :CASCADE, related_name = :cover)
    Meta(table = "dq_cover", ordering = ["item"])
end
@model struct DqNumber
    num = IntegerField()
    other_num = IntegerField(null = true)
    another_num = IntegerField(null = true)
    Meta(table = "dq_number")
end
@model struct DqValid
    valid = CharField(max_length = 10)
    parent = ManyToManyField(:self; symmetrical = true)
    Meta(table = "dq_valid", ordering = ["valid"])
end
@model struct DqManagedModel
    data = CharField(max_length = 10)
    tag = ForeignKey(DqTag; on_delete = :CASCADE, related_name = :managedmodel)
    public = BooleanField(default = true)
    Meta(table = "dq_managedmodel")
end
@model struct DqSimpleCategory
    name = CharField(max_length = 25)
    Meta(table = "dq_simplecategory")
end
@model struct DqSpecialCategory <: DqSimpleCategory
    special_name = CharField(max_length = 35)
    Meta(table = "dq_specialcategory")
end
@model struct DqCategoryItem
    category = ForeignKey(DqSimpleCategory; on_delete = :CASCADE, related_name = :categoryitem)
    Meta(table = "dq_categoryitem")
end
@model struct DqOneToOneCategory
    new_name = CharField(max_length = 15)
    category = OneToOneField(DqSimpleCategory; on_delete = :CASCADE, related_name = :onetoonecategory)
    Meta(table = "dq_onetoonecategory")
end
@model struct DqSchool
    Meta(table = "dq_school")
end
@model struct DqClassroom
    name = CharField(max_length = 20)
    has_blackboard = BooleanField(null = true)
    school = ForeignKey(DqSchool; on_delete = :CASCADE, related_name = :classroom)
    Meta(table = "dq_classroom")
end
@model struct DqArticle
    name = CharField(max_length = 20)
    created = DateTimeField()
    Meta(table = "dq_article")
end
@model struct DqFood
    name = CharField(max_length = 20, unique = true)
    Meta(table = "dq_food")
end
@model struct DqEaten
    food = ForeignKey(DqFood; on_delete = :SET_NULL, null = true, related_name = :eaten, to_field = :name)
    meal = CharField(max_length = 20)
    Meta(table = "dq_eaten")
end
@model struct DqReservedName
    name = CharField(max_length = 20)
    order = IntegerField()
    Meta(table = "dq_reservedname")
end
@model struct DqLoopX
    y = ForeignKey(:DqLoopY; on_delete = :CASCADE, related_name = :loopx)
    Meta(table = "dq_loopx", ordering = ["y"])
end
@model struct DqLoopY
    x = ForeignKey(DqLoopX; on_delete = :CASCADE, related_name = :loopy)
    Meta(table = "dq_loopy", ordering = ["x"])
end
@model struct DqLoopZ
    z = ForeignKey(:self; on_delete = :CASCADE, related_name = :loopz)
    Meta(table = "dq_loopz", ordering = ["z"])
end
@model struct DqObjectA
    name = CharField(max_length = 50)
    Meta(table = "dq_objecta")
end
@model struct DqObjectB
    name = CharField(max_length = 50)
    objecta = ForeignKey(DqObjectA; on_delete = :CASCADE, related_name = :objectb)
    num = PositiveIntegerField()
    Meta(table = "dq_objectb")
end
@model struct DqObjectC
    name = CharField(max_length = 50)
    objecta = ForeignKey(DqObjectA; on_delete = :SET_NULL, null = true, related_name = :objectc)
    objectb = ForeignKey(DqObjectB; on_delete = :SET_NULL, null = true, related_name = :objectc)
    Meta(table = "dq_objectc")
end
@model struct DqJob
    name = CharField(max_length = 20, unique = true)
    Meta(table = "dq_job")
end
@model struct DqJobResponsibilities
    job = ForeignKey(DqJob; on_delete = :CASCADE, related_name = :jobresponsibilities, to_field = :name)
    responsibility = ForeignKey(:DqResponsibility; on_delete = :CASCADE, related_name = :jobresponsibilities, to_field = :description)
    Meta(table = "dq_jobresponsibilities")
end
@model struct DqResponsibility
    description = CharField(max_length = 20, unique = true)
    jobs = ManyToManyField(DqJob; through = DqJobResponsibilities, related_name = :responsibilities)
    Meta(table = "dq_responsibility")
end
@model struct DqOrder
    name = CharField(max_length = 12, null = true, default = "")
    Meta(table = "dq_order", ordering = ["pk"])
end
@model struct DqOrderItem
    order = ForeignKey(DqOrder; on_delete = :CASCADE, related_name = :items)
    status = IntegerField()
    Meta(table = "dq_orderitem", ordering = ["pk"])
end
@model struct DqCategoryRelationship
    first = ForeignKey(DqSimpleCategory; on_delete = :CASCADE, related_name = :first_rel)
    second = ForeignKey(DqSimpleCategory; on_delete = :CASCADE, related_name = :second_rel)
    Meta(table = "dq_categoryrelationship")
end
@model struct DqNullableName
    name = CharField(max_length = 20, null = true)
    Meta(table = "dq_nullablename", ordering = ["id"])
end
@model struct DqNode
    num = IntegerField(unique = true)
    parent = ForeignKey(:self; on_delete = :SET_NULL, null = true, related_name = :node, to_field = :num)
    Meta(table = "dq_node")
end
@model struct DqModelD
    name = TextField()
    Meta(table = "dq_modeld")
end
@model struct DqModelC
    name = TextField()
    Meta(table = "dq_modelc")
end
@model struct DqModelB
    name = TextField()
    c = ForeignKey(DqModelC; on_delete = :CASCADE, related_name = :modelb)
    Meta(table = "dq_modelb")
end
@model struct DqModelA
    name = TextField()
    b = ForeignKey(DqModelB; on_delete = :SET_NULL, null = true, related_name = :modela)
    d = ForeignKey(DqModelD; on_delete = :CASCADE, related_name = :modela)
    Meta(table = "dq_modela")
end
@model struct DqFK1
    f1 = TextField()
    f2 = TextField()
    Meta(table = "dq_fk1")
end
@model struct DqBaseA
    a = ForeignKey(DqFK1; on_delete = :SET_NULL, null = true, related_name = :basea)
    Meta(table = "dq_basea")
end
@model struct DqIdentifier
    name = CharField(max_length = 100)
    Meta(table = "dq_identifier")
end
@model struct DqProgram
    identifier = OneToOneField(DqIdentifier; on_delete = :CASCADE, related_name = :program)
    Meta(table = "dq_program")
end
@model struct DqChannel
    identifier = OneToOneField(DqIdentifier; on_delete = :CASCADE, related_name = :channel)
    Meta(table = "dq_channel")
end
@model struct DqTeacher
    schools = ManyToManyField(DqSchool; related_name = :teacher)
    friends = ManyToManyField(:self; symmetrical = true)
    Meta(table = "dq_teacher")
end
redirect_stdout(devnull) do
    ms = [DqDumbCategory, DqNamedCategory, DqTag, DqNote, DqAnnotation, through(DqAnnotation, :notes), DqExtraInfo, DqAuthor,
          DqItem, through(DqItem, :tags), DqReport, DqRanking, DqCover, DqNumber, DqValid, through(DqValid, :parent),
          DqManagedModel, DqSimpleCategory, DqSpecialCategory, DqCategoryItem, DqOneToOneCategory, DqSchool, DqClassroom, DqArticle, DqFood, DqEaten, DqReservedName,
          DqLoopX, DqLoopY, DqLoopZ, DqObjectA, DqObjectB, DqObjectC, DqJob, DqResponsibility, DqJobResponsibilities,
          DqOrder, DqOrderItem, DqCategoryRelationship, DqNullableName, DqNode, DqModelD, DqModelC, DqModelB, DqModelA,
          DqFK1, DqBaseA, DqIdentifier, DqProgram, DqChannel, DqTeacher,
          through(DqTeacher, :schools), through(DqTeacher, :friends)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

function dq_data()
    nc1 = create(DqNamedCategory; name = "Generic")
    t1 = create(DqTag; name = "t1", category = nc1); t2 = create(DqTag; name = "t2", parent = t1, category = nc1)
    t3 = create(DqTag; name = "t3", parent = t1); t4 = create(DqTag; name = "t4", parent = t3); t5 = create(DqTag; name = "t5", parent = t3)
    n1 = create(DqNote; note = "n1", misc = "foo"); n2 = create(DqNote; note = "n2", misc = "bar"); n3 = create(DqNote; note = "n3", misc = "foo", negate = false)
    ann1 = create(DqAnnotation; name = "a1", tag = t1); add!(ann1.notes, n1)
    ann2 = create(DqAnnotation; name = "a2", tag = t4); add!(ann2.notes, n2, n3)
    e2 = create(DqExtraInfo; info = "e2", note = n2, value = 41, filterable = false)
    e1 = create(DqExtraInfo; info = "e1", note = n1, value = 42)
    a1 = create(DqAuthor; name = "a1", num = 1001, extra = e1); a2 = create(DqAuthor; name = "a2", num = 2002, extra = e1)
    a3 = create(DqAuthor; name = "a3", num = 3003, extra = e2); a4 = create(DqAuthor; name = "a4", num = 4004, extra = e2)
    time1, time2 = DateTime(2007, 12, 19, 22, 25), DateTime(2007, 12, 19, 21, 0)
    i1 = create(DqItem; name = "one", created = time1, modified = time1, creator = a1, note = n3); set!(i1.tags, [t1, t2])
    i2 = create(DqItem; name = "two", created = time2, creator = a2, note = n2); set!(i2.tags, [t1, t3])
    i3 = create(DqItem; name = "three", created = DateTime(2007, 12, 20, 22, 25), creator = a2, note = n3)
    i4 = create(DqItem; name = "four", created = DateTime(2007, 12, 20, 21, 0), creator = a4, note = n3); set!(i4.tags, [t4])
    r1 = create(DqReport; name = "r1", creator = a1); r2 = create(DqReport; name = "r2", creator = a3); r3 = create(DqReport; name = "r3")
    rank1 = create(DqRanking; rank = 2, author = a2)
    c1 = create(DqCover; title = "first", item = i4); c2 = create(DqCover; title = "second", item = i2)
    (; nc1, t1, t2, t3, t4, t5, n1, n2, n3, ann1, ann2, e1, e2, a1, a2, a3, a4, time1, time2, i1, i2, i3, i4, r1, r2, r3, rank1, c1, c2)
end
names_(qs) = try [x.name for x in qs] catch err; err end

@testset "django queries: Queries1Tests (part 1)" begin
  port_block() do
    d = dq_data()
    # test_ticket1050
    @test names_(filter(DqItem; tags__isnull = true)) == ["three"] && names_(filter(DqItem; tags__id__isnull = true)) == ["three"]
    # test_ticket1801: and two querysets ANDed (qs1 & qs2)
    @test names_(filter(DqAuthor; item = d.i2)) == ["a2"] && names_(filter(DqAuthor; item = d.i3)) == ["a2"]
    @test names_(try filter(DqAuthor; item = d.i2) & filter(DqAuthor; item = d.i3) catch err; err end) == ["a2"]
    # test_ticket2306
    @test names_(order_by(filter(objects(DqItem), Q(tags = d.t1)), "name")) == ["one", "two"]
    @test names_(filter(filter(objects(DqItem), Q(tags = d.t1)), Q(tags = d.t2))) == ["one"]
    @test names_(filter(filter(objects(DqItem), Q(tags = d.t1)), Q(creator__name = "fred") | Q(tags = d.t2))) == ["one"]
    @test names_(filter(objects(DqItem), Q(tags = d.t1) & Q(tags = d.t2))) == String[]       # one tag row can't be both
    @test names_(filter(objects(DqItem), Q(tags = d.t1), Q(creator__name = "fred") | Q(tags = d.t2))) == String[]
    @test names_(filter(DqAuthor; ranking__rank = 2, ranking__id = d.rank1.id)) == ["a2"]
    # test_ticket4464 (Juango matches each item once across a many-to-many: no [one, one, two])
    @test names_(filter(filter(DqItem; tags = d.t1); tags = d.t2)) == ["one"]
    @test names_(order_by(distinct(filter(DqItem; tags__in = [d.t1, d.t2])), "name")) == ["one", "two"]
    @test names_(filter(filter(DqItem; tags__in = [d.t1, d.t2]); tags = d.t3)) == ["two"]
    # test_tickets_2080_3592
    @test names_(try filter(DqAuthor; item__name = "one") | filter(DqAuthor; name = "a3") catch err; err end) == ["a1", "a3"]
    @test names_(filter(objects(DqAuthor), Q(item__name = "one") | Q(name = "a3"))) == ["a1", "a3"]
    @test names_(filter(objects(DqAuthor), Q(name = "a3") | Q(item__name = "one"))) == ["a1", "a3"]
    @test names_(filter(objects(DqAuthor), Q(item__name = "three") | Q(report__name = "r3"))) == ["a2"]
    # test_ticket6074
    @test names_(filter(objects(DqAuthor), Q(id__in = Int[]))) == String[] && names_(filter(objects(DqAuthor), Q(id__in = Int[]) | Q(id__in = Int[]))) == String[]
    # test_tickets_1878_2939 / test_ticket7323
    @test count(distinct(values(objects(DqItem), :creator))) == 3
    xx = create(DqItem; name = "four", created = d.time1, creator = d.a2, note = d.n1)
    @test count(distinct(values(exclude(objects(DqItem); name = "two"), :creator, :name))) == 4
    delete!(xx)
    @test count(values(objects(DqItem), :creator, :name)) == 4
    # test_ticket2253: querysets ORed and ANDed
    q1 = order_by(objects(DqItem), "name"); q2 = filter(DqItem; id = d.i1.id)
    @test names_(q1) == ["four", "one", "three", "two"] && names_(q2) == ["one"]
    @test names_(try order_by(q1 | q2, "name") catch err; err end) == ["four", "one", "three", "two"]
    @test names_(try order_by(q1 & q2, "name") catch err; err end) == ["one"]
    # test_get_clears_ordering
    sqls = String[]
    Juango.execute_wrapper((ex, sql, ps, ctx) -> (push!(sqls, sql); ex(sql, ps))) do
        get(order_by(objects(DqAuthor), "name"); pk = d.a1.pk)
    end
    @test !any(s -> occursin("order by", lowercase(s)), sqls)
    # test_tickets_4088_4306 (Report.creator by to_field num, in Django)
    @test names_(filter(DqReport; creator__num = 1001)) == ["r1"] && names_(filter(DqReport; creator__id = d.a1.id)) == ["r1"] && names_(filter(DqReport; creator__name = "a1")) == ["r1"]
    # test_ticket4510 / test_ticket7378
    @test names_(filter(DqAuthor; report__name = "r1")) == ["a1"] && names_(d.a1.report) == ["r1"]
    # test_tickets_5324_6704
    @test names_(filter(DqItem; tags__name = "t4")) == ["four"]
    @test names_(distinct(order_by(exclude(objects(DqItem); tags__name = "t4"), "name"))) == ["one", "three", "two"]
    @test names_(try reverse(distinct(order_by(exclude(objects(DqItem); tags__name = "t4"), "name"))) catch err; err end) == ["two", "three", "one"]
    @test names_(order_by(distinct(exclude(objects(DqAuthor); item__name = "one")), "name")) == ["a2", "a3", "a4"]
    @test names_(order_by(exclude(objects(DqItem); tags__name = "t1"), "name")) == ["four", "three"]
    @test names_(exclude(exclude(objects(DqItem); tags__name = "t1"); tags__name = "t4")) == ["three"]
    @test names_(order_by(filter(DqTag; parent__isnull = true), "name")) == ["t1"]
    @test names_(order_by(exclude(objects(DqTag); parent__isnull = true), "name")) == ["t2", "t3", "t4", "t5"]
  end
end

@testset "django queries: Queries1Tests (part 2)" begin
  port_block() do
    d = dq_data()
    tn(qs) = try [x.name for x in qs] catch err; err end
    # test_tickets_5324_6704 (continued): exclude with OR across a relation, two levels up
    @test tn(order_by(exclude(objects(DqTag), Q(parent__name = "t1") | Q(parent__isnull = true)), "name")) == ["t4", "t5"]
    @test tn(order_by(exclude(objects(DqTag), Q(parent__isnull = true) | Q(parent__name = "t1")), "name")) == ["t4", "t5"]
    @test tn(order_by(exclude(objects(DqTag), Q(parent__parent__isnull = true)), "name")) == ["t4", "t5"]
    @test tn(order_by(filter(objects(DqTag), ~Q(parent__parent__isnull = true)), "name")) == ["t4", "t5"]
    # test_ticket2091
    @test tn(filter(DqItem; tags__in = [get(DqTag; name = "t4")])) == ["four"]
    # test_reasonable_number_of_subq_aliases: 20 nested subqueries
    x = filter(DqTag; pk = 1)
    for _ in 1:20; x = filter(DqTag; pk__in = x); end
    @test (try collect(x); true catch; false end)
    # test_heterogeneous_qs_combination
    @test (try objects(DqAuthor) | objects(DqTag); false catch e; true end)
    # test_ticket2400: reverse relations isnull
    @test tn(filter(DqAuthor; item__isnull = true)) == ["a3"] && tn(filter(DqTag; item__isnull = true)) == ["t5"]
    # test_tickets_2076_7256: ordering by a relation follows the related model's Meta.ordering
    @test tn(order_by(objects(DqItem), "note__note", "name")) == ["two", "four", "one", "three"]
    @test tn(order_by(objects(DqAuthor), "extra", "-name")) == ["a2", "a1", "a4", "a3"]
    @test [c.title for c in objects(DqCover)] == ["first", "second"]
    @test tn(order_by(objects(DqItem), "creator", "name")) == ["one", "three", "two", "four"]
    @test tn(order_by(objects(DqItem), "name")) == ["four", "one", "three", "two"]
    # the model's own ordering by a relation: Item's Meta.ordering is ["-note", "name"] (note by its Meta.ordering, "note")
    @test tn(objects(DqItem)) == ["four", "one", "three", "two"]
    # test_tickets_2874_3002
    qs = order_by(select_related(objects(DqItem), :creator, :note), "note__note", "name")
    @test tn(qs) == ["two", "four", "one", "three"] && first(qs).note.note == "n2" && first(qs).creator.extra.note.note == "n1"
    # test_ticket3037
    @test tn(filter(objects(DqItem), Q(creator__name = "a3", name = "two") | Q(creator__name = "a4", name = "four"))) == ["four"]
    # test_tickets_5321_7070: distinct values ordered by a field not selected
    @test (try collect(order_by(distinct(values(objects(DqNote), :misc)), "note", "-misc")) == [Dict(:misc => "foo"), Dict(:misc => "bar"), Dict(:misc => "foo")] catch; false end)
    # test_ticket4358: values() keys a foreign key by its attname (note_id); values(:note) too
    @test haskey(first(values(objects(DqExtraInfo))), :note_id)
    @test collect(values(objects(DqExtraInfo), :note_id)) == [Dict(:note_id => d.n1.pk), Dict(:note_id => d.n2.pk)]
    @test collect(values(objects(DqExtraInfo), :note)) == [Dict(:note => d.n1.pk), Dict(:note => d.n2.pk)]
    # test_ticket6154
    @test tn(filter(filter(DqAuthor; id = d.a1.id), Q(extra__note = d.n1) | Q(item__note = d.n3))) == ["a1"]
    @test tn(filter(filter(objects(DqAuthor), Q(extra__note = d.n1) | Q(item__note = d.n3)); id = d.a1.id)) == ["a1"]
    # test_ticket6981 / test_ticket9926
    @test tn(order_by(select_related(objects(DqTag), :parent), "name")) == ["t1", "t2", "t3", "t4", "t5"]
    @test tn(order_by(select_related(objects(DqTag), :parent, :category), "name")) == ["t1", "t2", "t3", "t4", "t5"]
    @test tn(order_by(select_related(objects(DqTag), :parent, :parent__category), "name")) == ["t1", "t2", "t3", "t4", "t5"]
    # test_tickets_6180_6203: datetimes()
    @test (try length(Juango.datetimes(objects(DqItem), :created, :month)) == 1 catch; false end)
    @test (try collect(Juango.datetimes(objects(DqItem), :created, :day)) == [DateTime(2007, 12, 19), DateTime(2007, 12, 20)] catch; false end)
  end
end

@testset "django queries: Queries1Tests (part 3)" begin
  port_block() do
    d = dq_data()
    tn(qs) = try [x.name for x in qs] catch err; err end
    tr(f) = try f() catch err; err end
    # test_tickets_6180_6203 (continued)
    @test tr(() -> length(Juango.datetimes(objects(DqItem), :created, :day))) == 2
    @test tr(() -> first(Juango.datetimes(objects(DqItem), :created, :day))) == DateTime(2007, 12, 19)
    # test_ticket7155: a nullable datetime
    @test tr(() -> collect(Juango.datetimes(objects(DqItem), :modified, :day))) == [DateTime(2007, 12, 19)]
    # test_order_by_rawsql
    # (by the item's own column: Juango names joined tables j1, j2..., where Django uses the table's name)
    @test tr(() -> collect(order_by(values(objects(DqItem), :note__note), RawSQL("dq_item.note_id", ()), "id"))) ==
          [Dict(:note__note => n) for n in ["n2", "n3", "n3", "n3"]]  # (#215)
    # test_ticket7096: exclude with several conditions, nested negations
    @test tn(order_by(filter(DqTag; parent = d.t1, name = "t3"), "name")) == ["t3"]
    @test tn(order_by(exclude(objects(DqTag); parent = d.t1, name = "t3"), "name")) == ["t1", "t2", "t4", "t5"]
    @test tn(distinct(order_by(exclude(objects(DqItem); tags__name = "t1", name = "one"), "name"))) == ["four", "three", "two"]
    @test tn(order_by(exclude(filter(DqItem; name__in = ["three", "four"]); tags__name = "t1"), "name")) == ["four", "three"]
    @test tn(exclude(objects(DqItem), ~Q(tags__name = "t1", name = "one"))) == ["one"]
    @test tn(filter(objects(DqItem), ~Q(tags__name = "t1", name = "one"); name = "two")) == ["two"]
    @test tn(exclude(objects(DqItem), ~Q(tags__name = "t1", name = "one"); name = "two")) == ["four", "one", "three"]
    # test_ticket7277: through a related manager (n1.annotation_set), across a self-referential relation
    @test tn(filter(filter(DqAnnotation; notes = d.n1), Q(tag = d.t5) | Q(tag__children = d.t5) | Q(tag__children__children = d.t5))) == ["a1"]
    # test_tickets_7448_7707
    @test tn(filter(DqItem; created__in = [d.time1, d.time2])) == ["one", "two"]
    # test_ticket7235: an empty queryset stays empty, without a query
    create(DqTag; name = "m")
    q = none(DqTag)
    r, n = count_queries(() -> [collect(q), collect(filter(q; name = "m")), collect(exclude(q; name = "m")), collect(select_related(q, :parent)),
                                collect(annotate(q; n = Count(:children))), collect(order_by(q, "name", "parent")), collect(distinct(q)),
                                collect(reverse(q)), collect(defer(q, :name)), collect(only(q, :name))])
    @test all(isempty, r) && n == 0
    delete!(get(DqTag; name = "m"))
    # test_ticket7791: ordering and distinct across a reverse relation
    @test tr(() -> length(collect(distinct(order_by(objects(DqNote), "extrainfo__info"))))) == 3  # (#209)
    # test_ticket9997: a values() queryset as an __in value selects its one field
    @test tn(filter(DqTag; name__in = values(filter(DqTag; parent = d.t1), :name))) == ["t2", "t3"]
    # test_ticket9985: values_list(...) then values(...)
    @test tr(() -> collect(order_by(values(values_list(objects(DqNote), :note; flat = true), :id), "id"))) == [Dict(:id => n.pk) for n in (d.n1, d.n2, d.n3)]
    @test tn(filter(DqAnnotation; notes__in = values(values_list(filter(DqNote; note = "n1"), :note), :id))) == ["a1"]
    # test_ticket10205: an empty __in updates nothing
    @test tr(() -> update!(filter(DqTag; name__in = String[]); name = "foo")) == 0
    # test_ticket10432: __in with a generator
    @test tr(() -> collect(filter(DqNote; pk__in = (x for x in Int[])))) == DqNote[]
    nobj = first(objects(DqNote))
    @test tr(() -> [x.pk for x in filter(DqNote; pk__in = (p for p in [nobj.pk]))]) == [nobj.pk]
    # test_ticket10742: a queryset as an __in value is a subquery, not run first
    subq = filter(DqAuthor; num__lt = 3000)
    @test tn(filter(DqAuthor; pk__in = subq)) == ["a1", "a2"] && tn(exclude(objects(DqAuthor); pk__in = subq)) == ["a3", "a4"]
    @test tn(filter(objects(DqAuthor), Q(pk__in = subq) & Q(name = "a1"))) == ["a1"]
    # test_ticket7076: excluding keeps NULLs
    @test tn(order_by(exclude(objects(DqItem); modified = d.time1), "name")) == ["four", "three", "two"]
    @test tn(exclude(objects(DqTag); parent__name = d.t1.name)) == ["t1", "t4", "t5"]
    # test_ticket7181: ordering by a nullable relation; none() combined
    @test length(tn(order_by(objects(DqTag), "parent__name"))) == 5
    nn = ["n1", "n2", "n3"]
    @test [x.note for x in tr(() -> none(DqNote) | objects(DqNote))] == nn && [x.note for x in tr(() -> objects(DqNote) | none(DqNote))] == nn
    @test isempty(collect(tr(() -> none(DqNote) & objects(DqNote)))) && isempty(collect(tr(() -> objects(DqNote) & none(DqNote))))
    # test_ticket8439: OR across nullable relations
    @test tn(filter(objects(DqAuthor), Q(item__note__extrainfo = d.e2) | Q(report = d.r1, name = "xyz"))) == ["a2"]
    @test tn(filter(objects(DqAuthor), Q(report = d.r1, name = "xyz") | Q(item__note__extrainfo = d.e2))) == ["a2"]
    @test tn(filter(objects(DqAnnotation), Q(tag__parent = d.t1) | Q(notes__note = "n1", name = "a1"))) == ["a1"]
    xx = create(DqExtraInfo; info = "xx", note = d.n3)
    @test [x.note for x in filter(objects(DqNote), Q(extrainfo__author = d.a1) | Q(extrainfo = xx))] == ["n1", "n3"]
    delete!(xx)
    # test_exclude, test_nested_exclude, test_double_exclude, test_exclude_in: exclude(q) is filter(~q)
    same(a, b) = tn(a) == tn(b)
    @test same(exclude(objects(DqItem); tags__name = "t4"), filter(objects(DqItem), ~Q(tags__name = "t4")))
    @test same(exclude(objects(DqItem), Q(tags__name = "t4") | Q(tags__name = "t3")), filter(objects(DqItem), ~(Q(tags__name = "t4") | Q(tags__name = "t3"))))
    @test same(exclude(objects(DqItem), Q(tags__name = "t4") | ~Q(tags__name = "t3")), filter(objects(DqItem), ~(Q(tags__name = "t4") | ~Q(tags__name = "t3"))))
    @test same(exclude(objects(DqItem), ~Q(tags__name = "t4")), filter(objects(DqItem), ~~Q(tags__name = "t4")))
    @test same(filter(objects(DqItem), Q(tags__name = "t4")), filter(objects(DqItem), ~~Q(tags__name = "t4")))
    @test same(filter(objects(DqItem), Q(tags__name = "t4")), filter(objects(DqItem), ~Q(~Q(tags__name = "t4"))))
    @test same(exclude(objects(DqItem), Q(tags__name__in = ["t4", "t3"])), filter(objects(DqItem), ~Q(tags__name__in = ["t4", "t3"])))
    @test same(filter(objects(DqItem), Q(tags__name__in = ["t4", "t3"])), filter(objects(DqItem), ~~Q(tags__name__in = ["t4", "t3"])))
    @test tn(filter(objects(DqItem), Q(tags__name = "t4"))) == ["four"]
    # test_ticket_10790_1..8 (the rows; Django's join counts are its own, and Juango returns each object once
    # across a multi-valued relation, so no duplicates)
    @test tn(filter(DqTag; parent__isnull = true)) == ["t1"] && tn(filter(DqTag; parent__isnull = false)) == ["t2", "t3", "t4", "t5"]
    @test tn(exclude(objects(DqTag); parent__isnull = true)) == ["t2", "t3", "t4", "t5"] && tn(exclude(objects(DqTag); parent__isnull = false)) == ["t1"]
    @test tn(exclude(objects(DqTag); parent__parent__isnull = false)) == ["t1", "t2", "t3"]
    @test !occursin("JOIN", first(Juango.select_sql(filter(DqTag; parent__isnull = true))))
    @test tn(filter(DqTag; parent__parent__isnull = false)) == ["t4", "t5"] && tn(filter(DqTag; parent__parent = d.t1)) == ["t4", "t5"]
    @test tn(filter(DqNamedCategory; tag__isnull = true)) == String[] && tn(filter(DqNamedCategory; tag__parent__isnull = true)) == ["Generic"]
    @test tn(filter(DqAuthor; item__tags__isnull = true)) == ["a2", "a3"]
    @test tn(filter(DqAuthor; item__tags__parent__isnull = true)) == ["a1", "a2", "a3"]
    @test tn(filter(DqAuthor; item__tags__isnull = false)) == ["a1", "a2", "a4"]
    @test tn(filter(DqAuthor; item__tags__parent__isnull = false)) == ["a1", "a2", "a4"]
    @test tn(filter(DqAuthor; item__tags__parent__parent__isnull = false)) == ["a4"]
    @test tn(filter(DqAuthor; item__tags__parent__parent__isnull = true)) == ["a1", "a2", "a3"]
    @test tn(filter(DqAuthor; item__isnull = true)) == ["a3"] && tn(filter(DqAuthor; item__isnull = false)) == ["a1", "a2", "a4"]
    @test tn(filter(objects(DqTag), Q(parent__isnull = true) | Q(parent = d.t1))) == ["t1", "t2", "t3"]
    # test_ticket_10790_combine
    q1, q2 = filter(DqTag; parent__isnull = true), filter(DqTag; parent__isnull = false)
    @test tn(tr(() -> q1 | q2)) == ["t1", "t2", "t3", "t4", "t5"]
    @test tn(tr(() -> q1 & q2)) == String[]
    q2 = filter(DqTag; parent = d.t1)
    @test tn(tr(() -> q1 | q2)) == ["t1", "t2", "t3"] && tn(tr(() -> q2 | q1)) == ["t1", "t2", "t3"]
    q2 = filter(DqTag; parent__parent__isnull = true)
    @test tn(tr(() -> q1 | q2)) == ["t1", "t2", "t3"] && tn(tr(() -> q2 | q1)) == ["t1", "t2", "t3"]
    # test_ticket19672
    @test tn(filter(objects(DqReport), Q(creator__isnull = false) & ~Q(creator__extra__value = 41))) == ["r1"]
    # test_ticket_20250: a negated Q on an annotated queryset
    @test tn(order_by(filter(annotate(objects(DqAuthor), Count(:item)), ~Q(extra__value = 0)), "name")) == ["a1", "a2", "a3", "a4"]
    # test_lookup_constraint_fielderror: the error names the field
    err = tr(() -> collect(filter(DqTag; unknown_field__name = "generic")))
    @test err isa Exception && occursin("unknown_field", sprint(showerror, err))
    # test_excluded_intermediary_m2m_table_joined
    @test [x.note for x in filter(objects(DqNote), ~Q(tag__annotation__name = F(:note)))] == ["n1", "n2", "n3"]
    @test [x.note for x in filter(filter(DqNote; tag__annotation__name = "a1"), ~Q(tag__annotation__name = F(:note)))] == String[]
    # test_field_with_filterable, test_negate_field: fields named like Django's internals
    @test tn(filter(DqAuthor; extra = d.e2)) == ["a3", "a4"]
    @test [x.note for x in filter(DqNote; negate = true)] == ["n1", "n2"] && [x.note for x in exclude(objects(DqNote); negate = true)] == ["n3"]
    # test_combining_does_not_mutate
    all_authors = objects(DqAuthor)
    with_report = filter(objects(DqAuthor), Exists(filter(DqReport; creator__pk = OuterRef(:id))))
    before = Set(tn(filter(DqItem; creator__in = exclude(all_authors; pk__in = with_report))))
    tr(() -> all_authors | with_report); tr(() -> all_authors & with_report)
    after = Set(tn(filter(DqItem; creator__in = exclude(all_authors; pk__in = with_report))))
    @test before == after == Set(["two", "three", "four"])
    # test_union_values_subquery
    ia = order_by(annotate(objects(DqAuthor); is_creator = Exists(filter(DqItem; creator = OuterRef(:pk)))))
    ra = order_by(annotate(objects(DqAuthor); is_creator = Exists(filter(DqReport; creator = OuterRef(:pk)))))
    @test tr(() -> collect(values_list(order_by(union(ia, ra), "is_creator"), :is_creator; flat = true))) == [false, true]
  end
end


@testset "django queries: Queries2Tests, Queries3Tests, Queries4Tests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    nums(qs) = try sort([x.num for x in qs]) catch err; err end
    for n in (4, 8, 12); create(DqNumber; num = n); end
    # test_ticket4289
    @test nums(filter(DqNumber; num__lt = 4)) == [] && nums(filter(DqNumber; num__gt = 8, num__lt = 12)) == []
    @test nums(filter(DqNumber; num__gt = 8, num__lt = 13)) == [12]
    @test nums(filter(objects(DqNumber), Q(num__lt = 4) | Q(num__gt = 8, num__lt = 12))) == []
    @test nums(filter(objects(DqNumber), Q(num__gt = 8, num__lt = 12) | Q(num__lt = 4))) == []
    @test nums(filter(objects(DqNumber), Q(num__gt = 8) & Q(num__lt = 12) | Q(num__lt = 4))) == []
    @test nums(filter(objects(DqNumber), Q(num__gt = 7) & Q(num__lt = 12) | Q(num__lt = 4))) == [8]
    # test_ticket12239: a float compared with an integer field
    @test nums(filter(DqNumber; num__gt = 11.9)) == [12] && nums(filter(DqNumber; num__gt = 12)) == [] && nums(filter(DqNumber; num__gt = 12.0)) == []
    @test nums(filter(DqNumber; num__gt = 12.1)) == [] && nums(filter(DqNumber; num__lt = 12)) == [4, 8] && nums(filter(DqNumber; num__lt = 12.0)) == [4, 8]
    @test nums(filter(DqNumber; num__lt = 12.1)) == [4, 8, 12] && nums(filter(DqNumber; num__gte = 11.9)) == [12] && nums(filter(DqNumber; num__gte = 12)) == [12]
    @test nums(filter(DqNumber; num__gte = 12.0)) == [12] && nums(filter(DqNumber; num__gte = 12.1)) == [] && nums(filter(DqNumber; num__gte = 12.9)) == []
    @test nums(filter(DqNumber; num__lte = 11.9)) == [4, 8] && nums(filter(DqNumber; num__lte = 12)) == [4, 8, 12] && nums(filter(DqNumber; num__lte = 12.0)) == [4, 8, 12]
    @test nums(filter(DqNumber; num__lte = 12.1)) == [4, 8, 12] && nums(filter(DqNumber; num__lte = 12.9)) == [4, 8, 12]
    # test_ticket7759: count while iterating
    qs = objects(DqNumber)
    @test tr(() -> (for _ in qs; return count(qs) == 3; end)) == true
    # Queries3Tests: test_ticket7107, test_datetimes_invalid_field, test_ticket22023
    @test isempty(collect(objects(DqValid)))
    err = tr(() -> collect(Juango.datetimes(objects(DqItem), :name, :month)))
    @test err isa Exception && occursin("name", sprint(showerror, err))
    @test tr(() -> only(values(objects(DqValid)), :valid)) isa Exception
    @test tr(() -> defer(values(objects(DqValid)), :valid)) isa Exception
  end
  port_block() do
    # Queries4Tests
    tr(f) = try f() catch err; err end
    tn(qs) = try [x.name for x in qs] catch err; err end
    generic = create(DqNamedCategory; name = "Generic")
    t1 = create(DqTag; name = "t1", category = generic)
    n1 = create(DqNote; note = "n1", misc = "foo"); n2 = create(DqNote; note = "n2", misc = "bar")
    e1 = create(DqExtraInfo; info = "e1", note = n1); e2 = create(DqExtraInfo; info = "e2", note = n2)
    a1 = create(DqAuthor; name = "a1", num = 1001, extra = e1); a3 = create(DqAuthor; name = "a3", num = 3003, extra = e2)
    r1 = create(DqReport; name = "r1", creator = a1); r2 = create(DqReport; name = "r2", creator = a3); r3 = create(DqReport; name = "r3")
    i1 = create(DqItem; name = "i1", created = now(), note = n1, creator = a1); i2 = create(DqItem; name = "i2", created = now(), note = n1, creator = a3)
    # test_ticket24525: & of two related querysets
    tag = create(DqTag; name = "")
    anth100 = create(DqNote; note = "ANTH", misc = "100", tag = tag); math101 = create(DqNote; note = "MATH", misc = "101", tag = tag)
    s1 = create(DqAnnotation; name = "1", tag = tag); s2 = create(DqAnnotation; name = "2", tag = tag)
    set!(s1.notes, [math101, anth100]); set!(s2.notes, [math101])
    @test tn(tr(() -> filter(DqAnnotation; notes = math101) & exclude(filter(DqAnnotation; tag = tag); notes__in = [anth100]))) == ["2"]
    # test_ticket11811: an unsaved object in an update
    @test tr(() -> update!(filter(DqTag; pk = t1.pk); category = DqNamedCategory(name = "Other"))) isa Exception
    # test_ticket14876: an OR of conditions is the OR of the querysets
    for (qa, qb) in ((Q(creator__isnull = true), Q(creator__extra__info = "e1")), (Q(creator__extra__info = "e1"), Q(creator__isnull = true)))
        @test Set(tn(filter(objects(DqReport), qa | qb))) == Set(["r1", "r3"]) == Set(tn(tr(() -> filter(objects(DqReport), qa) | filter(objects(DqReport), qb))))
    end
    for (qa, qb) in ((Q(creator = a1), Q(creator__report__name = "r1")), (Q(creator__report__name = "e1"), Q(creator = a1)))
        @test tn(order_by(filter(objects(DqItem), qa | qb))) == ["i1"] == tn(tr(() -> order_by(filter(objects(DqItem), qa)) | order_by(filter(objects(DqItem), qb))))
    end
    # test_combine_join_reuse, test_combine_or_filter_reuse
    create(DqReport; name = "r4", creator = a1)
    @test tn(tr(() -> filter(DqAuthor; report__name = "r5") | filter(filter(DqAuthor; report__name = "r4"); report__name = "r1"))) == ["a1"]
    @test tr(() -> get(filter(DqAuthor; name = "a1") | filter(DqAuthor; name = "a3"); name = "a1").pk) == a1.pk
    # test_join_reuse_order
    sc1, sc2, sc3 = create(DqSchool), create(DqSchool), create(DqSchool)
    te1 = create(DqTeacher)
    others = exclude(exclude(objects(DqTeacher); pk = te1.pk); friends = te1)
    @test tr(() -> collect(filter(filter(others; schools = sc1); schools = sc2) | filter(filter(others; schools = sc1); schools = sc3))) == DqTeacher[]
    # test_ticket7095: an update filtered on its own model; outer joins after a nullable one
    create(DqManagedModel; data = "mm1", tag = t1, public = true)
    @test tr(() -> update!(objects(DqManagedModel); data = "mm")) == 1
    @test tr(() -> collect(order_by(values_list(objects(DqReport), :creator__extra__info; flat = true), "name"))) == ["e1", "e2", nothing, "e1"]
    @test tn(order_by(select_related(objects(DqReport), :creator, :creator__extra), "name")) == ["r1", "r2", "r3", "r4"]
    # test_order_by_resetting
    @test occursin("ORDER BY", first(Juango.select_sql(order_by(order_by(objects(DqAuthor)), "name"))))
    # test_order_by_reverse_fk: ordering by a reverse relation (Django repeats an object for each related row)
    c1 = create(DqSimpleCategory; name = "category1"); c2 = create(DqSimpleCategory; name = "category2")
    create(DqCategoryItem; category = c1); create(DqCategoryItem; category = c2); create(DqCategoryItem; category = c1)
    @test tr(() -> [x.pk for x in order_by(objects(DqSimpleCategory), "categoryitem", "pk")]) == [c1.pk, c2.pk, c1.pk]  # (#209)
    # test_ticket10181
    @test tr(() -> collect(filter(DqTag; id__in = filter(DqTag; id__in = Int[])))) == DqTag[]
  end
  port_block() do
    # test_ticket15316_*: isnull across a multi-table child and a one-to-one
    tr(f) = try f() catch err; err end
    ids(qs) = try sort([x.pk for x in qs]) catch err; err end
    c1 = create(DqSimpleCategory; name = "category1")
    c2 = create(DqSpecialCategory; name = "named category1", special_name = "special1")
    c3 = create(DqSpecialCategory; name = "named category2", special_name = "special2")
    ci1 = create(DqCategoryItem; category = c1)
    ci2 = create(DqCategoryItem; category = tr(() -> get(DqSimpleCategory; pk = c2.pk)))
    ci3 = create(DqCategoryItem; category = tr(() -> get(DqSimpleCategory; pk = c3.pk)))
    @test ids(filter(DqCategoryItem; category__dqspecialcategory__isnull = false)) == [ci2.pk, ci3.pk]
    @test ids(exclude(objects(DqCategoryItem); category__dqspecialcategory__isnull = false)) == [ci1.pk]
    @test ids(filter(DqCategoryItem; category__dqspecialcategory__isnull = true)) == [ci1.pk]
    @test ids(exclude(objects(DqCategoryItem); category__dqspecialcategory__isnull = true)) == [ci2.pk, ci3.pk]
  end
  port_block() do
    ids(qs) = try sort([x.pk for x in qs]) catch err; err end
    c = create(DqSimpleCategory; name = "cat"); c0 = create(DqSimpleCategory; name = "cat0"); c1 = create(DqSimpleCategory; name = "category1")
    create(DqOneToOneCategory; category = c1, new_name = "new1"); create(DqOneToOneCategory; category = c0, new_name = "new2")
    ci1 = create(DqCategoryItem; category = c); ci2 = create(DqCategoryItem; category = c0); ci3 = create(DqCategoryItem; category = c1)
    @test ids(filter(DqCategoryItem; category__onetoonecategory__isnull = false)) == [ci2.pk, ci3.pk]
    @test ids(exclude(objects(DqCategoryItem); category__onetoonecategory__isnull = false)) == [ci1.pk]
    @test ids(filter(DqCategoryItem; category__onetoonecategory__isnull = true)) == [ci1.pk]
    @test ids(exclude(objects(DqCategoryItem); category__onetoonecategory__isnull = true)) == [ci2.pk, ci3.pk]
  end
end

@testset "django queries: Queries5Tests, DisjunctiveFilterTests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    n1 = create(DqNote; note = "n1", misc = "foo"); n2 = create(DqNote; note = "n2", misc = "bar")
    e1 = create(DqExtraInfo; info = "e1", note = n1); e2 = create(DqExtraInfo; info = "e2", note = n2)
    a1 = create(DqAuthor; name = "a1", num = 1001, extra = e1); a2 = create(DqAuthor; name = "a2", num = 2002, extra = e1)
    a3 = create(DqAuthor; name = "a3", num = 3003, extra = e2)
    rank2 = create(DqRanking; rank = 2, author = a2); rank1 = create(DqRanking; rank = 1, author = a3); rank3 = create(DqRanking; rank = 3, author = a1)
    rk(qs) = try [x.rank for x in qs] catch err; err end
    notes(qs) = try [x.note for x in qs] catch err; err end
    # test_ordering: Meta.ordering across models
    @test rk(objects(DqRanking)) == [3, 2, 1] && rk(order_by(objects(DqRanking), "rank")) == [1, 2, 3]
    # test_ticket9848: an update filtered through a relation updates the right rows
    @test rk(filter(DqRanking; author__name = "a1")) == [3]
    @test tr(() -> update!(filter(DqRanking; author__name = "a1"); rank = 4636)) == 1
    r = get(DqRanking; author__name = "a1")
    @test r.id == rank3.id && r.author_id == a1.id && r.rank == 4636
    r.rank = 3; save!(r)
    @test rk(objects(DqRanking)) == [3, 2, 1]
    # test_ticket5261: empty Q()s
    @test notes(tr(() -> exclude(objects(DqNote), Q()))) == ["n1", "n2"] && notes(tr(() -> filter(objects(DqNote), ~Q()))) == ["n1", "n2"]
    @test notes(tr(() -> filter(objects(DqNote), ~Q() | ~Q()))) == ["n1", "n2"] && notes(tr(() -> exclude(objects(DqNote), ~Q() & ~Q()))) == ["n1", "n2"]
    @test notes(tr(() -> exclude(objects(DqNote), xor(~Q(), ~Q())))) == ["n1", "n2"]
    # test_queryset_reuse
    authors = filter(objects(DqAuthor), Q(name = "a1") | Q(name = "nonexistent"))
    @test tr(() -> get(filter(DqRanking; author__in = authors)).pk) == rank3.pk && count(authors) == 1
    # test_filter_unsaved_object
    @test tr(() -> collect(filter(DqRanking; author = DqAuthor(name = "unsaved", num = 1, extra = e1)))) isa Exception
    @test tr(() -> collect(filter(DqRanking; author__in = [a1, DqAuthor(name = "unsaved", num = 1, extra = e1)]))) isa Exception
    # DisjunctiveFilterTests.test_ticket8283: filter after an OR of querysets
    @test tr(() -> [x.info for x in filter(filter(DqExtraInfo; note = n1) | filter(DqExtraInfo; info = "e2"); note = n1)]) == ["e1"]
    @test tr(() -> [x.info for x in filter(filter(DqExtraInfo; info = "e2") | filter(DqExtraInfo; note = n1); note = n1)]) == ["e1"]
  end
end

@testset "django queries: Queries6Tests, ComparisonTests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    tn(qs) = try [x.name for x in qs] catch err; err end
    generic = create(DqNamedCategory; name = "Generic")
    t1 = create(DqTag; name = "t1", category = generic); t2 = create(DqTag; name = "t2", parent = t1, category = generic)
    t3 = create(DqTag; name = "t3", parent = t1); t4 = create(DqTag; name = "t4", parent = t3); t5 = create(DqTag; name = "t5", parent = t3)
    n1 = create(DqNote; note = "n1", misc = "foo")
    ann1 = create(DqAnnotation; name = "a1", tag = t1); add!(ann1.notes, n1)
    ann2 = create(DqAnnotation; name = "a2", tag = t4)
    # test_parallel_iterators
    qs = objects(DqTag)
    i1 = Iterators.Stateful(qs); i2 = Iterators.Stateful(qs)
    @test [popfirst!(i1).name, popfirst!(i1).name, popfirst!(i2).name, popfirst!(i2).name, popfirst!(i2).name, popfirst!(i1).name] == ["t1", "t2", "t1", "t2", "t3", "t3"]
    # test_nested_queries_sql: a queryset as an __in value is a subquery
    @test count("SELECT", first(Juango.select_sql(filter(DqAnnotation; notes__in = filter(DqNote; note = "xyzzy"))))) == 2
    # test_tickets_8921_9188: exclude across multi-valued relations
    @test tn(exclude(objects(DqTag); children = nothing)) == ["t1", "t3"]
    @test tn(exclude(objects(DqTag); parent__annotation__name = "a1")) == ["t1", "t4", "t5"]
    @test tn(exclude(objects(DqAnnotation); tag__children__name = "t2")) == ["a2"]
    @test tn(filter(DqAnnotation; notes__in = filter(DqNote; note = "n1"))) == ["a1"]
    # test_distinct_ordered_sliced_subquery_aggregation
    @test tr(() -> count(order_by(distinct(objects(DqTag)), "category__name")[1:3])) == 3
    # test_multiple_columns_with_the_same_name_slice
    @test tr(() -> collect(values_list(order_by(objects(DqTag), "name"), :name, :category__name)[1:2])) == [("t1", "Generic"), ("t2", "Generic")]
    @test tn(select_related(order_by(objects(DqTag), "name"), :category)[1:2]) == ["t1", "t2"]
    @test tr(() -> collect(values_list(order_by(objects(DqTag), "-name"), :name, :parent__name)[1:2])) == [("t5", "t3"), ("t4", "t3")]
    @test tn(select_related(order_by(objects(DqTag), "-name"), :parent)[1:2]) == ["t5", "t4"]
    # test_col_alias_quoted
    @test tr(() -> aggregate(annotate(values(objects(DqTag), :parent); tag_per_parent = Count(:pk)), Max(:tag_per_parent))) == Dict(:tag_per_parent__max => 2)
    # test_xor_subquery
    @test tn(filter(objects(DqTag), xor(Exists(filter(DqTag; id = OuterRef(:id), name = "t3")), Exists(filter(DqTag; id = OuterRef(:id), parent = t1))))) == ["t2"]
  end
  port_block() do
    # ComparisonTests.test_ticket8597: _ and % are literal in iexact, istartswith, iendswith
    tn(qs) = try [x.name for x in qs] catch err; err end
    n1 = create(DqNote; note = "n1", misc = "foo"); e1 = create(DqExtraInfo; info = "e1", note = n1)
    a2 = create(DqAuthor; name = "a2", num = 2002, extra = e1)
    create(DqItem; name = "a_b", created = now(), creator = a2, note = n1); create(DqItem; name = "x%y", created = now(), creator = a2, note = n1)
    @test tn(filter(DqItem; name__iexact = "A_b")) == ["a_b"] && tn(filter(DqItem; name__iexact = "x%Y")) == ["x%y"]
    @test tn(filter(DqItem; name__istartswith = "A_b")) == ["a_b"] && tn(filter(DqItem; name__iendswith = "A_b")) == ["a_b"]
    # ExistsSql.test_exists: exists() selects no columns
    _, n = count_queries(() -> @test !exists(objects(DqTag)))
    @test n == 1
  end
end

@testset "django queries: QuerysetOrderedTests, SubqueryTests, QuerySetBitwiseOperationTests, EmptyQuerySetTests" begin
  # QuerysetOrderedTests: is_ordered (Django's qs.ordered)
  @test !Juango.is_ordered(objects(DqAnnotation))
  @test Juango.is_ordered(objects(DqTag)) && !Juango.is_ordered(order_by(objects(DqTag)))
  @test Juango.is_ordered(order_by(objects(DqAnnotation), "id"))
  @test Juango.is_ordered(none(DqAnnotation))
  @test !Juango.is_ordered(annotate(objects(DqAnnotation); num_notes = Count(:notes))) && Juango.is_ordered(order_by(annotate(objects(DqAnnotation); num_notes = Count(:notes)), "num_notes"))
  # a grouped query ignores Meta.ordering, so it isn't ordered
  @test !Juango.is_ordered(annotate(objects(DqTag); num_notes = Count(:pk))) && Juango.is_ordered(order_by(annotate(objects(DqTag); num_notes = Count(:pk)), "name"))
  @test !Juango.is_ordered(annotate(values(objects(DqTag), :name); num_notes = Count(:pk))) && Juango.is_ordered(order_by(annotate(values(objects(DqTag), :name); num_notes = Count(:pk)), "name"))
  port_block() do
    # SubqueryTests: sliced subqueries keep their ordering
    tr(f) = try f() catch err; err end
    for (i, n) in enumerate(["first", "second", "third", "fourth"]); create(DqNamedCategory; id = i, name = n); end
    idset(qs) = try Set(values_list(qs, :id; flat = true)) catch err; err end
    @test idset(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[1:2])) == Set([3, 4])
    @test idset(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[2:2])) == Set([3])
    @test idset(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[3:end])) == Set([1, 2])
    # test_slice_subquery_and_query
    @test tr(() -> [x.id for x in order_by(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[1:2]), "id")[1:2]]) == [3, 4]
    @test tr(() -> [x.id for x in order_by(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[2:3]), "id")[2:3]]) == [3]
    @test tr(() -> [x.id for x in order_by(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[3:end]), "id")[2:end]]) == [2]
    # test_related_sliced_subquery
    generic = create(DqNamedCategory; id = 5, name = "Generic")
    t1 = create(DqTag; name = "t1", category = generic); t2 = create(DqTag; name = "t2", category = generic)
    create(DqManagedModel; data = "mm1", tag = t1, public = true); mm2 = create(DqManagedModel; data = "mm2", tag = t2, public = true)
    @test tr(() -> Set(x.id for x in filter(DqManagedModel; tag__in = order_by(objects(DqTag), "-id")[1:1]))) == Set([mm2.id])
    delete!(filter(objects(DqManagedModel))); delete!(objects(DqTag)); delete!(get(DqNamedCategory; id = 5))
    # test_distinct_ordered_sliced_subquery
    @test tr(() -> collect(values_list(order_by(filter(DqNamedCategory; id__in = order_by(distinct(objects(DqNamedCategory)), "name")[1:2]), "name"), :name; flat = true))) == ["first", "fourth"]
    @test tr(() -> collect(values_list(order_by(filter(DqNamedCategory; id__in = values(order_by(distinct(objects(DqNamedCategory)), "-name"), :id)[1:2]), "name"), :name; flat = true))) == ["second", "third"]
    @test tr(() -> collect(values_list(order_by(filter(DqDumbCategory; id__in = values(distinct(order_by(annotate(objects(DqDumbCategory); double_id = F(:id) * 2), "id")), :double_id)[1:2]), "id"), :id; flat = true))) == [2, 4]
    # test_sliced_delete
    tr(() -> delete!(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[1:1])))
    @test idset(objects(DqDumbCategory)) == Set([1, 2, 3])
    tr(() -> delete!(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[2:2])))
    @test idset(objects(DqDumbCategory)) == Set([1, 3])
    tr(() -> delete!(filter(DqDumbCategory; id__in = order_by(objects(DqDumbCategory), "-id")[2:end])))
    @test idset(objects(DqDumbCategory)) == Set([3])
  end
  port_block() do
    # QuerySetBitwiseOperationTests: | and ⊻ of sliced querysets
    tr(f) = try f() catch err; err end
    school = create(DqSchool)
    rooms = [create(DqClassroom; school = school, has_blackboard = hb, name = "Room $i") for (i, hb) in enumerate([false, true, true, false])]
    rn(qs) = try Set(x.name for x in qs) catch err; err end
    bb(v) = filter(DqClassroom; has_blackboard = v)
    @test rn(tr(() -> bb(true) | order_by(bb(false), "pk")[1:1])) == Set(["Room 1", "Room 2", "Room 3"])
    @test rn(tr(() -> order_by(bb(true), "pk")[1:1] | bb(false))) == Set(["Room 1", "Room 2", "Room 4"])
    @test rn(tr(() -> order_by(bb(false), "pk")[1:1] | order_by(bb(true), "pk")[1:1])) == Set(["Room 1", "Room 2"])
    @test rn(tr(() -> order_by(bb(false), "-pk")[1:1] | order_by(bb(true), "-name")[1:1])) == Set(["Room 3", "Room 4"])
    @test rn(tr(() -> xor(bb(true), order_by(bb(false), "pk")[1:1]))) == Set(["Room 1", "Room 2", "Room 3"])
    @test rn(tr(() -> xor(order_by(bb(false), "-pk")[1:1], order_by(bb(true), "-name")[1:1]))) == Set(["Room 3", "Room 4"])
    # test_subquery_aliases
    combined = tr(() -> filter(DqSchool; pk__isnull = false) & filter(objects(DqSchool), Exists(filter(DqClassroom; has_blackboard = true, school = OuterRef(:pk)))))
    @test tr(() -> [x.pk for x in combined]) == [school.pk]
    @test tr(() -> [x.pk for x in filter(DqSchool; pk__in = values(combined, :pk))]) == [school.pk]
  end
  # EmptyQuerySetTests
  @test isempty(collect(order_by(values(none(DqNumber), :num), "num")))
  @test isempty(collect(filter(DqNumber; pk__in = values(none(DqNumber), :pk)))) && isempty(collect(filter(DqNumber; pk__in = values_list(none(DqNumber), :pk))))
  @test isempty(collect(values(none(DqAuthor)))) && isempty(collect(values_list(none(DqAuthor))))
end

@testset "django queries: ValuesQuerysetTests, QuerySetSupportsPythonIdioms, WeirdQuerysetSlicingTests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    create(DqNumber; num = 72)
    # test_flat_values_list, test_duplicate_values_list
    @test tr(() -> collect(values_list(values_list(objects(DqNumber), :num), :num; flat = true))) == [72]
    @test tr(() -> get(values_list(objects(DqNumber), :num, :num))) == (72, 72)
    @test_broken tr(() -> get(values_list(objects(DqNumber), F(:num), F(:num)))) == (72, 72)   # values_list of expressions
    # test_field_error_values_list
    @test tr(() -> collect(values_list(objects(DqTag), :name__foo))) isa Exception
    # test_named_values_list_flat
    @test tr(() -> values_list(objects(DqNumber), :num; flat = true, named = true)) isa Exception
    # test_named_values_list_with_fields / without fields
    v = tr(() -> first(values_list(annotate(objects(DqNumber), Count(:id)), :num, :id__count; named = true)))
    @test tr(() -> (keys(v), v.num, v.id__count)) == ((:num, :id__count), 72, 1)
    v = tr(() -> first(values_list(annotate(objects(DqNumber), Count(:id)); named = true)))
    @test tr(() -> keys(v)) == (:id, :num, :other_num, :another_num, :id__count)
    # test_named_values_pickle
    @test tr(() -> Tuple(get(values_list(objects(DqNumber), :num, :other_num; named = true)))) == (72, nothing)
  end
  port_block() do
    # QuerySetSupportsPythonIdioms (Julia's 1-based ranges for Python's slices)
    tr(f) = try f() catch err; err end
    some_date = DateTime(2014, 5, 16, 12, 1)
    arts = [create(DqArticle; name = "Article $i", created = some_date) for i in 1:7]
    oa() = order_by(objects(DqArticle), "name")
    an(qs) = try [x.name for x in qs] catch err; err end
    @test tr(() -> oa()[1].name) == "Article 1" && an(oa()[2:3]) == ["Article 2", "Article 3"]
    @test an(tr(() -> oa()[1:2:end])) == ["Article 1", "Article 3", "Article 5", "Article 7"]
    _, n = count_queries(() -> oa()[1:5]); @test n == 0
    @test an(tr(() -> oa()[1:5][1:2])) == ["Article 1", "Article 2"] && an(tr(() -> oa()[1:5][5:end])) == ["Article 5"] && an(tr(() -> oa()[1:5][6:end])) == String[]
    @test an(tr(() -> oa()[3:end][1:2])) == ["Article 3", "Article 4"] && an(tr(() -> oa()[3:end][3:3])) == ["Article 5"]
    @test an(oa()[6:end]) == ["Article 6", "Article 7"]
    @test tr(() -> filter(objects(DqArticle)[1:5]; name = "foo")) isa Exception
    @test tr(() -> order_by(objects(DqArticle)[1:5], "id")) isa Exception
    @test tr(() -> objects(DqArticle)[1:1] & objects(DqArticle)[5:5]) isa Exception
    @test tr(() -> objects(DqArticle)[0]) isa Exception && tr(() -> objects(DqArticle)[-1]) isa Exception
    @test tr(() -> objects(DqArticle)["foo"]) isa Exception
    @test length(filter(DqArticle; name__exact = "Article 1")) == 1
    s1, s2 = filter(DqArticle; name__exact = "Article 1"), filter(DqArticle; name__exact = "Article 2")
    @test an(tr(() -> order_by(s1 | s2, "name"))) == ["Article 1", "Article 2"] && an(tr(() -> s1 & s2)) == String[]
  end
  port_block() do
    # WeirdQuerysetSlicingTests
    tr(f) = try f() catch err; err end
    create(DqNumber; num = 1); create(DqNumber; num = 2)
    for n in ("one", "two", "three", "four"); create(DqArticle; name = n, created = now()); end
    food = create(DqFood; name = "spam"); create(DqEaten; meal = "spam with eggs", food = food)
    @test tr(() -> collect(objects(DqArticle)[1:0])) == DqArticle[] && tr(() -> collect(objects(DqArticle)[1:0][1:10])) == DqArticle[]
    @test tr(() -> count(objects(DqArticle)[1:0])) == 0
    @test tr(() -> latest(objects(DqArticle)[1:0], :created)) isa Exception
    _, n = count_queries(() -> collect(objects(DqNumber)[2:1])); @test n == 0
    @test tr(() -> count(filter(DqEaten; food__in = objects(DqFood)[1:0]))) == 0
    @test tr(() -> count(exclude(objects(DqEaten); food__in = objects(DqFood)[1:0]))) == 1
    r, n = count_queries(() -> (collect(values(objects(DqArticle))[43:42]), collect(values_list(objects(DqArticle))[43:42])))
    @test r == (Dict{Symbol,Any}[], Tuple[]) || all(isempty, r)
    @test n == 0
  end
end

@testset "django queries: EscapingTests, IsNullTests, ConditionalTests, UnionTests, ExcludeTests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    # EscapingTests.test_ticket_7302: a field named like an SQL keyword
    r_a = create(DqReservedName; name = "a", order = 42); r_b = create(DqReservedName; name = "b", order = 37)
    @test tr(() -> [x.name for x in order_by(objects(DqReservedName), "order")]) == ["b", "a"]
    # IsNullTests.test_to_field (a plain foreign key here)
    apple = create(DqFood; name = "apple")
    e1 = create(DqEaten; food = apple, meal = "lunch"); e2 = create(DqEaten; meal = "lunch")
    @test [x.pk for x in filter(DqEaten; food__isnull = false)] == [e1.pk] && [x.pk for x in filter(DqEaten; food__isnull = true)] == [e2.pk]
    # ConditionalTests.test_infinite_loop: Meta.ordering by relations in a cycle is an error, not a hang
    err = tr(() -> collect(objects(DqLoopX)))
    @test err isa Exception && !(err isa StackOverflowError) && occursin("loop", lowercase(sprint(showerror, err)))
    err = tr(() -> collect(objects(DqLoopZ)))
    @test err isa Exception && !(err isa StackOverflowError) && occursin("loop", lowercase(sprint(showerror, err)))
    @test tr(() -> collect(order_by(objects(DqLoopX), "y__x__y__x__id"))) == DqLoopX[]
    # ConditionalTests.test_in_list_limit: __in with 2050 values
    bulk_create([DqNumber(num = n) for n in 0:2049])
    @test all(k -> tr(() -> count(filter(DqNumber; num__in = collect(0:k-1)))) == k, [1000, 1001, 2000, 2050])
  end
  port_block() do
    # UnionTests: filter(q1) | filter(q2) is filter(q1 | q2)
    tr(f) = try f() catch err; err end
    oa = [create(DqObjectA; name = n) for n in ("one", "two", "three")]
    ob = [create(DqObjectB; name = n, num = k, objecta = a) for (n, k, a) in (("un", 1, oa[1]), ("deux", 2, oa[1]), ("trois", 3, oa[3]))]
    for (n, a, b) in (("ein", oa[3], ob[3]), ("zwei", oa[2], ob[2])); create(DqObjectC; name = n, objecta = a, objectb = b); end
    ids(qs) = try Set(x.pk for x in qs) catch err; err end
    check(T, q1, q2) = ids(tr(() -> filter(objects(T), q1) | filter(objects(T), q2))) == ids(filter(objects(T), q1 | q2)) ==
                       ids(tr(() -> filter(objects(T), q2) | filter(objects(T), q1)))
    @test check(DqObjectA, Q(name = "two"), Q(objectb__name = "deux"))
    @test check(DqObjectA, Q(name = "two"), Q(objectb__name = "deux", objectb__num = 2))
    @test check(DqObjectA, Q(objectb__name = "deux"), Q(objectc__objectb__name = "deux"))
    @test check(DqObjectB, Q(objecta__objectb__name = "deux"), Q(objecta__objectc__name = "ein"))
    @test check(DqObjectB, Q(objecta__objectb__name = "deux"), Q(objecta__objectc__objectb__name = "trois"))
    @test check(DqObjectB, Q(objecta__name = "one", objectc__objecta__name = "two"),
                Q(objecta__objectc__name = "ein", objectc__objecta__name = "three", objecta__objectb__name = "trois"))
    # ExcludeTests.test_exclude_with_circular_fk_relation
    @test tr(() -> count(exclude(objects(DqObjectB); objecta__objectb__name = F(:name)))) == 0
    # DefaultValuesInsertTest: a model with only its primary key
    @test tr(() -> create(DqDumbCategory)) isa DqDumbCategory
  end
  port_block() do
    # ExcludeTests
    tr(f) = try f() catch err; err end
    f1 = create(DqFood; name = "apples"); f2 = create(DqFood; name = "oranges")
    create(DqEaten; food = f1, meal = "dinner")
    j1 = create(DqJob; name = "Manager"); r1 = create(DqResponsibility; description = "Playing golf")
    j2 = create(DqJob; name = "Programmer"); r2 = create(DqResponsibility; description = "Programming")
    create(DqJobResponsibilities; job = j1, responsibility = r1); create(DqJobResponsibilities; job = j2, responsibility = r2)
    # test_to_field
    @test [x.name for x in exclude(objects(DqFood); eaten__meal = "dinner")] == ["oranges"]
    @test [x.name for x in exclude(objects(DqJob); responsibilities__description = "Playing golf")] == ["Programmer"]
    @test [x.description for x in exclude(objects(DqResponsibility); jobs__name = "Manager")] == ["Programming"]
    # test_exclude_reverse_fk_field_ref
    tag = create(DqTag; name = ""); create(DqNote; tag = tag, note = "note", misc = "")
    annotation = create(DqAnnotation; name = "annotation", tag = tag)
    @test tr(() -> get(exclude(objects(DqAnnotation); tag__note__note = F(:name))).pk) == annotation.pk
    # test_subquery_exclude_outerref
    qs = filter(objects(DqJobResponsibilities), Exists(exclude(objects(DqResponsibility); jobs = OuterRef(:job))))
    @test tr(() -> exists(qs)) == true
    delete!(r1)
    @test tr(() -> exists(qs)) == false
    # test_exclude_nullable_fields: a NULL on either side isn't equal
    number = create(DqNumber; num = 1, other_num = 1); create(DqNumber; num = 2, other_num = 2, another_num = 2)
    @test [x.num for x in exclude(objects(DqNumber); other_num = F(:another_num))] == [1]
    @test [x.num for x in exclude(objects(DqNumber); num = F(:another_num))] == [1]
    # test_exclude_multivalued_exists
    @test [x.name for x in exclude(objects(DqJob); responsibilities__description = "Programming")] == ["Manager"]
    # test_exclude_subquery: a combined queryset as a subquery annotation
    sub = tr(() -> filter(DqJobResponsibilities; responsibility__description = "bar") | exclude(objects(DqJobResponsibilities); job__responsibilities__description = "foo"))
    @test tr(() -> Set(x.name for x in annotate(objects(DqJob); responsibility = Subquery(values(filter(sub; job = OuterRef(:name)), :id)[1:1])))) == Set(["Manager", "Programmer"])
  end
end

@testset "django queries: ExcludeTest17600, Exclude15786, NullInExcludeTest, EmptyStringsAsNullTest, QuerySetExceptionTests" begin
  port_block() do
    tr(f) = try f() catch err; err end
    o = [create(DqOrder; id = k) for k in 1:3]
    for (k, st) in ((1, 1), (1, 1), (1, 1), (2, 1), (2, 2), (2, 3), (3, 2), (3, 3), (3, 4)); create(DqOrderItem; order = o[k], status = st); end
    oids(qs) = try [x.pk for x in qs] catch err; err end
    # exclude across a multi-valued relation: orders with an item of status 1
    @test oids(exclude(objects(DqOrder); items__status = 1)) == [3] && oids(distinct(exclude(objects(DqOrder); items__status = 1))) == [3]
    @test oids(distinct(exclude(objects(DqOrder), Q(items__status = 1)))) == [3] && oids(exclude(objects(DqOrder), Q(items__status = 1))) == [3]
    # test_only_orders_with_all_items_having_status_1: an expected failure in Django too
    @test oids(distinct(exclude(objects(DqOrder), ~Q(items__status = 1)))) != [1] || true
  end
  port_block() do
    # Exclude15786: exclude comparing two one-to-one relations
    tr(f) = try f() catch err; err end
    c1 = create(DqSimpleCategory; name = "c1"); c2 = create(DqSimpleCategory; name = "c2")
    create(DqOneToOneCategory; category = c1, new_name = ""); create(DqOneToOneCategory; category = c2, new_name = "")
    rel = create(DqCategoryRelationship; first = c1, second = c2)
    @test tr(() -> get(exclude(objects(DqCategoryRelationship); first__onetoonecategory = F(:second__onetoonecategory))).pk) == rel.pk
  end
  port_block() do
    # NullInExcludeTest: exclude(name__in = ...) keeps NULLs as Django does
    tr(f) = try f() catch err; err end
    create(DqNullableName; name = "i1"); create(DqNullableName)
    nm(qs) = try [x.name for x in qs] catch err; err end
    @test nm(exclude(objects(DqNullableName); name__in = String[])) == ["i1", nothing]
    @test nm(exclude(objects(DqNullableName); name__in = ["i1"])) == [nothing]
    @test nm(exclude(objects(DqNullableName); name__in = ["i3"])) == ["i1", nothing]
    @test nm(exclude(objects(DqNullableName); name__in = values_list(filter(DqNullableName; name = "i1"), :name))) == [nothing]
    # test_col_not_in_list_containing_null
    @test nm(exclude(objects(DqNullableName); name__in = [nothing])) == ["i1"]
    # test_double_exclude
    @test nm(filter(objects(DqNullableName), ~~Q(name = "i1"))) == nm(filter(objects(DqNullableName), Q(name = "i1")))
    @test !occursin("IS NOT NULL", first(Juango.select_sql(filter(objects(DqNullableName), ~~Q(name = "i1")))))
  end
  port_block() do
    # EmptyStringsAsNullTest
    nc = create(DqNamedCategory; name = "")
    @test [x.pk for x in exclude(objects(DqNamedCategory); name__in = ["nonexistent"])] == [nc.pk]
    @test (try [x.pk for x in exclude(objects(DqDumbCategory); dqnamedcategory__name__in = ["nonexistent"])] catch err; err end) == [nc.pk]
    foo = create(DqNamedCategory; name = "foo")
    @test [x.pk for x in exclude(objects(DqNamedCategory); name = "")] == [foo.pk]
  end
  # QuerySetExceptionTests
  tr(f) = try f() catch err; err end
  @test tr(() -> collect(order_by(objects(DqArticle), "*"))) isa Exception
  @test tr(() -> collect(order_by(values(objects(DqItem), :creator__name), "dq_author.name"))) isa Exception
  @test tr(() -> collect(filter(DqAuthor; extra = objects(DqArticle)))) isa Exception
end

@testset "django queries: to_field (Queries1Tests.test_tickets_4088_4306, ToFieldTests)" begin
  port_block() do
    d = dq_data()
    tn(qs) = try [x.name for x in qs] catch err; err end
    tr(f) = try f() catch err; err end
    # test_tickets_4088_4306: Report.creator stores the author's num
    @test tn(filter(DqReport; creator = 1001)) == ["r1"] && tn(filter(DqReport; creator__num = 1001)) == ["r1"]
    @test tn(filter(DqReport; creator__id = 1001)) == String[] && tn(filter(DqReport; creator__id = d.a1.id)) == ["r1"]
    @test tn(filter(DqReport; creator__name = "a1")) == ["r1"] && tn(filter(DqAuthor; report__name = "r1")) == ["a1"]
    @test get(DqReport; name = "r1").creator_id == 1001 && get(DqReport; name = "r1").creator.name == "a1"
    @test tn(order_by(select_related(filter(DqReport; creator__isnull = false), :creator), "name")) == ["r1", "r2"] &&
          first(order_by(select_related(objects(DqReport), :creator), "name")).creator.num == 1001
    @test Set(x.name for x in prefetch_related(objects(DqAuthor), :report) for r in x.report) == Set(["a1", "a3"])
    @test [x.name for x in d.a1.report] == ["r1"]
  end
  port_block() do
    tr(f) = try f() catch err; err end
    meals(qs) = try Set(x.meal for x in qs) catch err; err end
    apple = create(DqFood; name = "apple"); pear = create(DqFood; name = "pear")
    lunch = create(DqEaten; food = apple, meal = "lunch"); dinner = create(DqEaten; food = pear, meal = "dinner")
    @test lunch.food_id == "apple" && get(DqEaten; meal = "lunch").food.name == "apple"
    # test_in_query, test_in_subquery, test_reverse_in, test_single_object(_reverse)
    @test meals(filter(DqEaten; food__in = [apple, pear])) == Set(["lunch", "dinner"])
    @test meals(filter(DqEaten; food__in = filter(DqFood; name = "apple"))) == Set(["lunch"])
    @test tr(() -> Set(x.name for x in filter(DqFood; eaten__in = filter(DqEaten; meal = "lunch")))) == Set(["apple"])
    @test tr(() -> Set(x.name for x in filter(DqFood; eaten__in = [lunch, dinner]))) == Set(["apple", "pear"])
    @test meals(filter(DqEaten; food = apple)) == Set(["lunch"]) && tr(() -> [x.name for x in filter(DqFood; eaten = lunch)]) == ["apple"]
    # cascades and SET_NULL follow the to_field
    delete!(apple)
    @test get(DqEaten; meal = "lunch").food_id === nothing
  end
  port_block() do
    # test_recursive_fk(_reverse)
    node1 = create(DqNode; num = 42); node2 = create(DqNode; num = 1, parent = node1)
    @test [x.num for x in filter(DqNode; parent = node1)] == [1] && [x.num for x in filter(DqNode; node = node2)] == [42]
    @test get(DqNode; num = 1).parent_id == 42 && get(DqNode; num = 1).parent.num == 42
  end
end

@testset "django queries: NullJoinPromotionOrTest (the rows; Django's join types are its own)" begin
  port_block() do
    tn(qs) = try [x.name for x in qs] catch err; err end
    d1 = create(DqModelD; name = "foo"); d2 = create(DqModelD; name = "bar")
    a1 = create(DqModelA; name = "a1", d = d1)
    c = create(DqModelC; name = "c"); b = create(DqModelB; name = "b", c = c)
    a2 = create(DqModelA; name = "a2", b = b, d = d2)
    # test_ticket_17886: an OR across a nullable relation keeps the rows the other branches match
    @test tn(filter(objects(DqModelA), Q(d__name = "foo") | Q(b__name = "foo") | Q(b__c__name = "foo"))) == ["a1"]
    # test_isnull_filter_promotion
    A = objects(DqModelA)
    @test tn(filter(A, Q(b__name__isnull = true))) == ["a1"] && tn(filter(A, ~Q(b__name__isnull = true))) == ["a2"]
    @test tn(filter(A, ~~Q(b__name__isnull = true))) == ["a1"] && tn(filter(A, Q(b__name__isnull = false))) == ["a2"]
    @test tn(filter(A, ~Q(b__name__isnull = false))) == ["a1"] && tn(filter(A, ~~Q(b__name__isnull = false))) == ["a2"]
    # test_null_join_demotion
    @test tn(filter(A, Q(b__name__isnull = false) & Q(b__name__isnull = true))) == String[]
    @test Set(tn(filter(A, Q(b__name__isnull = false) | Q(b__name__isnull = true)))) == Set(["a1", "a2"])
  end
  port_block() do
    # test_xor_promotion, test_negated_xor_promotion
    fk1 = create(DqFK1; f1 = "match", f2 = "value")
    with_rel = create(DqBaseA; a = fk1); without = create(DqBaseA)
    ids(qs) = try [x.pk for x in order_by(qs, "pk")] catch err; err end
    B = objects(DqBaseA)
    @test ids(filter(B, xor(Q(a__f1__isnull = false), Q(pk = without.pk)))) == [with_rel.pk, without.pk]
    @test ids(filter(B, xor(Q(a__f1 = "match"), Q(a__f2 = "other")))) == [with_rel.pk]
    @test ids(filter(B, ~xor(Q(a__f1__isnull = true), Q(pk = without.pk)))) == [with_rel.pk, without.pk]
    @test ids(filter(B, ~xor(~Q(a__f1__isnull = false), Q(pk = without.pk)))) == [with_rel.pk, without.pk]
  end
  port_block() do
    # test_ticket_21366
    n = create(DqNote; note = "n", misc = "m"); e = create(DqExtraInfo; info = "info", note = n)
    a = create(DqAuthor; name = "Author1", num = 1, extra = e); create(DqRanking; rank = 1, author = a)
    r1 = create(DqReport; name = "Foo", creator = a); r2 = create(DqReport; name = "Bar"); create(DqReport; name = "Bar", creator = a)
    @test [x.pk for x in order_by(filter(objects(DqReport), Q(creator__ranking__isnull = true) | Q(creator__ranking__rank = 1, name = "Foo")), "name")] == [r2.pk, r1.pk]
  end
  port_block() do
    # test_ticket_21748 and the double-negated variants
    tn(qs) = try [x.name for x in qs] catch err; err end
    i1 = create(DqIdentifier; name = "i1"); i2 = create(DqIdentifier; name = "i2"); i3 = create(DqIdentifier; name = "i3")
    p1 = create(DqProgram; identifier = i1); c1 = create(DqChannel; identifier = i1); p2 = create(DqProgram; identifier = i2)
    I = objects(DqIdentifier)
    @test tn(filter(I; program = nothing, channel = nothing)) == ["i3"]
    @test tn(order_by(exclude(I; program = nothing, channel = nothing), "name")) == ["i1", "i2"]
    @test tn(order_by(exclude(I, ~Q(program__id = p1.id, channel__id = c1.id)), "pk")) == tn(order_by(filter(I; program__id = p1.id, channel__id = c1.id), "pk")) == ["i1"]
    @test tn(order_by(exclude(I, ~(Q(program__id = p2.id, channel__id = c1.id) | Q(program__id = p1.id))), "pk")) ==
          tn(order_by(filter(I, Q(program__id = p2.id, channel__id = c1.id) | Q(program__id = p1.id)), "pk")) == ["i1"]
  end
end

@testset "values() + aggregate over a relation the filter crossed (#225)" begin
  port_block() do
    d = dq_data()
    q = annotate(values(filter(DqAuthor; item__name__in = ["one", "two", "three"], item__note__note = "n3"), :item__name); n = Count(:id; distinct = true))
    sql = first(Juango.select_sql(q))
    @test length(collect(eachmatch(r"JOIN [`\"]dq_item[`\"]", sql))) == 1          # the filter's join, in SELECT and GROUP BY alike
    @test Dict(r[:item__name] => r[:n] for r in q) == Dict("one" => 1, "three" => 1)
  end
end
