# Django's aggregation_regress tests (tests/aggregation_regress), translated (#227).
# Tests built on QuerySet.extra() are left out (Juango has no extra(): #280), and so is Entries' AutoField
# under another name and column (#277): Juango's Entries has a plain id.

using Dates

# --- tests/aggregation_regress/models.py ---------------------------------------------------------------
@model struct DarAuthor
    name = CharField(max_length = 100)
    age = IntegerField()
    friends = ManyToManyField(:self; blank = true)
    Meta(table = "dar_author")
end
Base.show(io::IO, a::DarAuthor) = print(io, a.name)
@model struct DarPublisher
    name = CharField(max_length = 255)
    num_awards = IntegerField()
    Meta(table = "dar_publisher")
end
@model struct DarItemTag
    tag = CharField(max_length = 100)
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    Meta(table = "dar_itemtag")
end
@model struct DarBook
    isbn = CharField(max_length = 9)
    name = CharField(max_length = 255)
    pages = IntegerField()
    rating = FloatField()
    price = DecimalField(decimal_places = 2, max_digits = 6)
    authors = ManyToManyField(DarAuthor; related_name = :book)
    contact = ForeignKey(DarAuthor; on_delete = :CASCADE, related_name = :book_contact_set)
    publisher = ForeignKey(DarPublisher; on_delete = :CASCADE, related_name = :book)
    pubdate = DateField()
    tags = GenericRelation(:DarItemTag)
    Meta(table = "dar_book", ordering = ["name"])
end
Base.show(io::IO, b::DarBook) = print(io, b.name)
@model struct DarStore
    name = CharField(max_length = 255)
    books = ManyToManyField(DarBook; related_name = :store)
    original_opening = DateTimeField()
    friday_night_closing = TimeField()
    Meta(table = "dar_store")
end
@model struct DarEntries
    Entry = CharField(unique = true, max_length = 50)
    Exclude = BooleanField(default = false)
    Meta(table = "dar_entries")
end
@model struct DarClues
    EntryID = ForeignKey(DarEntries; on_delete = :CASCADE, verbose_name = "Entry", db_column = "Entry ID", related_name = :clues)
    Clue = CharField(max_length = 150)
    Meta(table = "dar_clues")
end
@model struct DarWithManualPK              # (Django's field is `id`: a field named id as the key is #229)
    mpk = IntegerField(primary_key = true)
    Meta(table = "dar_withmanualpk")
end
@model struct DarHardbackBook <: DarBook
    weight = FloatField()
    Meta(table = "dar_hardbackbook")
end
@model struct DarAlfa
    name = CharField(max_length = 10, null = true)
    Meta(table = "dar_alfa")
end
@model struct DarBravo
    Meta(table = "dar_bravo")
end
@model struct DarCharlie
    alfa = ForeignKey(DarAlfa; on_delete = :SET_NULL, null = true)
    bravo = ForeignKey(DarBravo; on_delete = :SET_NULL, null = true)
    Meta(table = "dar_charlie")
end
@model struct DarSelfRefFK
    name = CharField(max_length = 50)
    parent = ForeignKey(:self; on_delete = :SET_NULL, null = true, blank = true, related_name = :children)
    Meta(table = "dar_selfreffk")
end
@model struct DarAuthorProxy <: DarAuthor
    Meta(proxy = true)
end
@model struct DarRecipe
    name = CharField(max_length = 20)
    author = ForeignKey(DarAuthorProxy; on_delete = :CASCADE)
    tasters = ManyToManyField(DarAuthorProxy; related_name = :recipes)
    Meta(table = "dar_recipe")
end
@model struct DarRecipeProxy <: DarRecipe
    Meta(proxy = true)
end
# unmanaged models over the tables above (Juango's automatic join table and column names)
@model struct DarAuthorUnmanaged
    age = IntegerField()
    Meta(table = "dar_author", managed = false)
end
@model struct DarRecipeTasterUnmanaged
    recipe = ForeignKey(:DarRecipeUnmanaged; on_delete = :CASCADE, db_column = "darrecipe_id")
    author = ForeignKey(DarAuthorUnmanaged; on_delete = :CASCADE, db_column = "darauthorproxy_id", related_name = "+")
    Meta(table = "dar_recipe_tasters", managed = false)
end
@model struct DarRecipeUnmanaged
    author = ForeignKey(DarAuthorUnmanaged; on_delete = :CASCADE, related_name = :recipeunmanaged)
    tasters = ManyToManyField(DarAuthorUnmanaged; through = :DarRecipeTasterUnmanaged, related_name = "+")
    Meta(table = "dar_recipe", managed = false)
end

# --- tests/unmanaged_models/models.py -----------------------------------------------------------------------
@model struct DumA01
    f_a = CharField(max_length = 10, db_index = true)
    f_b = IntegerField()
    Meta(table = "a01")
end
@model struct DumB01
    fk_a = ForeignKey(DumA01; on_delete = :CASCADE)
    f_a = CharField(max_length = 10, db_index = true)
    f_b = IntegerField()
    Meta(table = "b01", managed = true)
end
@model struct DumC01
    mm_a = ManyToManyField(DumA01; db_table = "d01")
    f_a = CharField(max_length = 10, db_index = true)
    f_b = IntegerField()
    Meta(table = "c01")
end
@model struct DumA02
    f_a = CharField(max_length = 10, db_index = true)
    Meta(table = "a01", managed = false)
end
@model struct DumB02
    fk_a = ForeignKey(DumA02; on_delete = :CASCADE, db_column = "fk_a_id")
    f_a = CharField(max_length = 10, db_index = true)
    f_b = IntegerField()
    Meta(table = "b01", managed = false)
end
@model struct DumC02
    mm_a = ManyToManyField(:DumA02; through = :DumIntermediate)
    f_a = CharField(max_length = 10, db_index = true)
    f_b = IntegerField()
    Meta(table = "c01", managed = false)
end
@model struct DumIntermediate
    a02 = ForeignKey(DumA02; on_delete = :CASCADE, db_column = "duma01_id")
    c02 = ForeignKey(DumC02; on_delete = :CASCADE, db_column = "dumc01_id")
    Meta(table = "d01", managed = false)
end
@model struct DumProxy1
    Meta(table = "unmanaged_models_proxy1")
end
@model struct DumProxy2
    Meta(table = "unmanaged_models_proxy2")
end
@model struct DumUnmanaged1
    Meta(table = "unmanaged_models_proxy1", managed = false)
end
@model struct DumUnmanaged2
    mm = ManyToManyField(DumUnmanaged1)
    Meta(table = "unmanaged_models_proxy2", managed = false)
end
@model struct DumManaged1
    mm = ManyToManyField(DumUnmanaged1)
    Meta(table = "dum_managed1")
end

redirect_stdout(devnull) do
    ms = Any[DarAuthor, through(DarAuthor, :friends), DarPublisher, DarItemTag, DarBook, through(DarBook, :authors), DarStore,
             through(DarStore, :books), DarEntries, DarClues, DarWithManualPK, DarHardbackBook, DarAlfa, DarBravo, DarCharlie,
             DarSelfRefFK, DarRecipe, through(DarRecipe, :tasters),
             DumA01, DumB01, DumC01, through(DumC01, :mm_a), DumProxy1, DumProxy2, DumManaged1, through(DumManaged1, :mm)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

function dar_data()
    A = [create(DarAuthor; name = n, age = age) for (n, age) in
         ("Adrian Holovaty" => 34, "Jacob Kaplan-Moss" => 35, "Brad Dayley" => 45, "James Bennett" => 29, "Jeffrey Forcier" => 37,
          "Paul Bissex" => 29, "Wesley J. Chun" => 25, "Peter Norvig" => 57, "Stuart Russell" => 46)]
    a1, a2, a3, a4, a5, a6, a7, a8, a9 = A
    add!(a1.friends, a2, a4); add!(a2.friends, a1, a7); add!(a4.friends, a1); add!(a5.friends, a6, a7); add!(a6.friends, a5, a7)
    add!(a7.friends, a2, a5, a6); add!(a8.friends, a9); add!(a9.friends, a8)
    P = [create(DarPublisher; name = n, num_awards = k) for (n, k) in
         ("Apress" => 3, "Sams" => 1, "Prentice Hall" => 7, "Morgan Kaufmann" => 9, "Jonno's House of Books" => 0)]
    p1, p2, p3, p4, p5 = P
    bk(isbn, name, pages, rating, price, contact, pub, d) =
        create(DarBook; isbn, name, pages, rating, price = Juango.Decimal(price), contact, publisher = pub, pubdate = d)
    b1 = bk("159059725", "The Definitive Guide to Django: Web Development Done Right", 447, 4.5, "30.00", a1, p1, Date(2007, 12, 6))
    b2 = bk("067232959", "Sams Teach Yourself Django in 24 Hours", 528, 3.0, "23.09", a3, p2, Date(2008, 3, 3))
    b3 = bk("159059996", "Practical Django Projects", 300, 4.0, "29.69", a4, p1, Date(2008, 6, 23))
    b4 = bk("013235613", "Python Web Development with Django", 350, 4.0, "29.69", a5, p3, Date(2008, 11, 3))
    b5 = create(DarHardbackBook; isbn = "013790395", name = "Artificial Intelligence: A Modern Approach", pages = 1132, rating = 4.0,
                price = Juango.Decimal("82.80"), contact = a8, publisher = p3, pubdate = Date(1995, 1, 15), weight = 4.5)
    b6 = create(DarHardbackBook; isbn = "155860191", name = "Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp",
                pages = 946, rating = 5.0, price = Juango.Decimal("75.00"), contact = a8, publisher = p4, pubdate = Date(1991, 10, 15),
                weight = 3.7)
    add!(b1.authors, a1, a2); add!(b2.authors, a3); add!(b3.authors, a4); add!(b4.authors, a5, a6, a7); add!(b5.authors, a8, a9)
    add!(b6.authors, a8)
    s1 = create(DarStore; name = "Amazon.com", original_opening = DateTime(1994, 4, 23, 9, 17, 42), friday_night_closing = Time(23, 59, 59))
    s2 = create(DarStore; name = "Books.com", original_opening = DateTime(2001, 3, 15, 11, 23, 37), friday_night_closing = Time(23, 59, 59))
    s3 = create(DarStore; name = "Mamma and Pappa's Books", original_opening = DateTime(1945, 4, 25, 16, 24, 14),
                friday_night_closing = Time(21, 30))
    add!(s1.books, b1, b2, b3, b4, b5, b6); add!(s2.books, b1, b3, b5, b6); add!(s3.books, b3, b4, b6)
    (; a = A, p = P, b = [b1, b2, b3, b4, b5, b6], s = [s1, s2, s3])
end
dar_approx(x, y; places = 2) = x !== nothing && round(Float64(x); digits = places) == round(Float64(y); digits = places)
DD(s) = Juango.Decimal(s)
# Django's assertObjectAttrs
dar_attrs(o; kw...) = all(getproperty(o, k) == v for (k, v) in kw)

@testset "django aggregation_regress: AggregationTests (part 1)" begin
  port_block() do
    d = dar_data(); a, p, b = d.a, d.p, d.b
    B, Au, Pu = objects(DarBook), objects(DarAuthor), objects(DarPublisher)
    # test_count_preserve_group_by
    create(DarBook; isbn = "113235613", name = b[4].name, pages = b[4].pages, rating = 4.0, price = DD("39.69"), contact = a[5],
           publisher = p[3], pubdate = Date(2018, 11, 3))
    qs = annotate(values(B, "contact__name", "publisher__name"); publications = Count("id"))
    for o in ("id", "-id", "-publications", "-contact__name", "?")
        @test count(order_by(qs, o)) == length(collect(order_by(qs, o)))
    end
    delete!(filter(B; isbn = "113235613"))
    # test_annotation_with_value
    vq = annotate(values(annotate(filter(B; name = "Practical Django Projects"); discount_price = F(:price) * 2), "discount_price");
                  sum_discount = Sum("discount_price"))
    sqls = String[]
    rows = execute_wrapper(() -> collect(vq), (ex, sql, ps, ctx) -> (push!(sqls, sql); ex(sql, ps)))
    @test length(sqls) == 1
    @test length(rows) == 1 && rows[1][:discount_price] == DD("59.38") && rows[1][:sum_discount] == DD("59.38")
    # test_aggregates_in_where_clause / test_aggregates_in_where_clause_pre_eval
    qs = values_list(order_by(annotate(values(B, "contact"), Max(:id)), "contact"), "id__max"; flat = true)
    books = order_by(B, "id")
    @test collect(filter(books; id__in = qs)) == collect(filter(books; id__in = collect(qs)))
    collect(qs)
    @test collect(filter(books; id__in = qs)) == collect(filter(books; id__in = collect(qs)))
    # test_aggregate
    @test dar_approx(aggregate(order_by(Au, "name"), Avg(:age))[:age__avg], 37.444; places = 1)
    @test aggregate(B, Sum(:pages)) == Dict(:pages__sum => 3703)
    v = aggregate(B, Sum(:pages), Avg(:pages))
    @test v[:pages__sum] == 3703 && dar_approx(v[:pages__avg], 617.166)
    v = aggregate(values(B), Sum(:pages), Avg(:pages))
    @test v[:pages__sum] == 3703 && dar_approx(v[:pages__avg], 617.166)
    # test_annotation (the extra() parts left out)
    o = get(annotate(B; mean_auth_age = Avg("authors__age")); pk = b[2].pk)
    @test dar_attrs(o; contact_id = a[3].id, isbn = "067232959", mean_auth_age = 45.0, name = "Sams Teach Yourself Django in 24 Hours",
                    pages = 528, price = DD("23.09"), pubdate = Date(2008, 3, 3), publisher_id = p[2].id, rating = 3.0)
    want = Dict(:id => b[2].id, :contact_id => a[3].id, :isbn => "067232959", :mean_auth_age => 45.0,
                :name => "Sams Teach Yourself Django in 24 Hours", :pages => 528, :price => DD("23.09"), :pubdate => Date(2008, 3, 3),
                :publisher_id => p[2].id, :rating => 3.0)
    @test get(values(annotate(B; mean_auth_age = Avg("authors__age"))); pk = b[2].pk) == want
    @test get(annotate(values(B); mean_auth_age = Avg("authors__age")); pk = b[2].pk) == want
    @test get(values(annotate(B; mean_auth_age = Avg("authors__age")), "name"); pk = b[1].pk) ==
          Dict(:name => "The Definitive Guide to Django: Web Development Done Right")
    @test get(values(annotate(B; mean_auth_age = Avg("authors__age")), "name", "mean_auth_age"); pk = b[1].pk) ==
          Dict(:mean_auth_age => 34.5, :name => "The Definitive Guide to Django: Web Development Done Right")
    @test collect(filter(values(annotate(B; n_authors = Count("authors")), "name"); n_authors__gt = 2)) ==
          [Dict(:name => "Python Web Development with Django")]
    @test get(annotate(values(B, "name"); mean_auth_age = Avg("authors__age")); pk = b[1].pk) ==
          Dict(:mean_auth_age => 34.5, :name => "The Definitive Guide to Django: Web Development Done Right")
    @test length(collect(values(annotate(Au, Avg(:friends__age))))) == 9
    qs = annotate(order_by(annotate(values(B, "price"); oldest = Max("authors__age")), "oldest", "price"), Max(:publisher__num_awards))
    @test collect(qs) == [Dict(:price => DD("30"), :oldest => 35, :publisher__num_awards__max => 3),
                          Dict(:price => DD("29.69"), :oldest => 37, :publisher__num_awards__max => 7),
                          Dict(:price => DD("23.09"), :oldest => 45, :publisher__num_awards__max => 1),
                          Dict(:price => DD("75"), :oldest => 57, :publisher__num_awards__max => 9),
                          Dict(:price => DD("82.8"), :oldest => 57, :publisher__num_awards__max => 7)]
    # test_aggregate_annotation
    v = aggregate(annotate(B; num_authors = Count("authors__id")), Max(:pages), Max(:price), Sum(:num_authors), Avg(:num_authors))
    @test v[:num_authors__sum] == 10 && dar_approx(v[:num_authors__avg], 1.666) && v[:pages__max] == 1132 && v[:price__max] == DD("82.80")
    @test aggregate(values(annotate(B; c = Count("authors")), "c"), Max(:c)) == Dict(:c__max => 3)
    # test_conditional_aggregate / test_sliced_conditional_aggregate / test_annotated_conditional_aggregate
    @test aggregate(values(annotate(B; c = Count("authors")), "pk"); test = Sum(Case(When(; c__gt = 1, then = 1))))[:test] == 3
    @test aggregate(order_by(Au, "pk")[1:5]; test = Sum(Case(When(; age__lte = 35, then = 1))))[:test] == 3
    r = aggregate(annotate(B; discount_price = F(:price) * DD("0.75"));
                  test = Avg(Case(When(; pages__lt = 400, then = F(:discount_price)); output_field = DecimalField())))[:test]
    @test dar_approx(r, 22.27)
    # test_distinct_conditional_aggregate / test_conditional_aggregate_on_complex_condition
    @test aggregate(distinct(B); test = Avg(Case(When(; price = DD("29.69"), then = F(:pages)); output_field = IntegerField())))[:test] == 325
    @test aggregate(distinct(B); test = Avg(Case(When(Q(price__gte = DD("29")) & Q(price__lt = DD("30")); then = F(:pages));
                                                 output_field = IntegerField())))[:test] == 325
    # test_q_annotation_aggregate
    @test count(annotate(B; has_pk = Q(pk__isnull = false))) == 6
    # test_decimal_aggregate_annotation_filter
    @test length(collect(filter(annotate(Au; sum = Sum("book_contact_set__price")); sum__gt = DD("40")))) == 1
    @test length(collect(filter(annotate(Au; sum = Sum("book_contact_set__price")); sum__lte = DD("40")))) == 4
    # test_field_error
    msg = "Cannot resolve keyword 'foo' into field. Choices are: authors, contact, contact_id, hardbackbook, id, isbn, name, pages, " *
          "price, pubdate, publisher, publisher_id, rating, store, tags"
    @test_throws Juango.LookupError aggregate(B; num_authors = Count("foo"))
    @test_throws Juango.LookupError collect(annotate(B; num_authors = Count("foo")))
    @test_throws Juango.LookupError aggregate(annotate(B; num_authors = Count("authors__id")), Max(:foo))
    # (Juango's wording; the choices are Django's, with Juango's name for the child link)
    @test (try aggregate(B; num_authors = Count("foo")); "" catch e; sprint(showerror, e) end) |>
          s -> occursin("Choices are: authors, contact, contact_id, darhardbackbook, id, isbn, name, pages, price, pubdate, " *
                        "publisher, publisher_id, rating, store, tags", s)
    # test_count_after_count_function
    @test count(annotate(B; num_authors = Count("authors"))) == 6
    # test_aggregates_over_annotations
    @test aggregate(annotate(B; num_authors = Count("authors")), Max(:num_authors)) == Dict(:num_authors__max => 3)
    @test aggregate(annotate(Pu; avg_price = Avg("book__price")), Max(:avg_price))[:avg_price__max] == 75.0
    # test_aliases_quoted
    @test aggregate(B; number = Max("pages"), select = Max("pages")) == Dict(:number => 1132, :select => 1132)
    # test_select_related
    @test get(values(annotate(select_related(B, "publisher"); num_authors = Count("authors"))); isbn = "013790395") ==
          Dict(:contact_id => a[8].id, :id => b[5].id, :isbn => "013790395", :name => "Artificial Intelligence: A Modern Approach",
               :num_authors => 2, :pages => 1132, :price => DD("82.8"), :pubdate => Date(1995, 1, 15), :publisher_id => p[3].id,
               :rating => 4.0)
    # test_exclude_on_aggregate
    na = annotate(B; num_authors = Count("authors"))
    @test length(collect(na)) == 6
    @test length(collect(filter(na; num_authors__gt = 2))) == 1
    @test length(collect(exclude(na; num_authors__gt = 2))) == 5
    @test length(collect(exclude(filter(na; num_authors__lt = 3); num_authors__lt = 2))) == 2
    @test length(collect(filter(exclude(na; num_authors__lt = 2); num_authors__lt = 3))) == 2
    # test_aggregate_fexpr
    nb = annotate(Pu; num_books = Count("book"))
    vals(q) = collect(values(order_by(q, "name"), "name", "num_books", "num_awards"))
    two = [Dict(:num_books => 1, :name => "Morgan Kaufmann", :num_awards => 9), Dict(:num_books => 2, :name => "Prentice Hall", :num_awards => 7)]
    three = [Dict(:num_books => 2, :name => "Apress", :num_awards => 3), Dict(:num_books => 0, :name => "Jonno's House of Books", :num_awards => 0),
             Dict(:num_books => 1, :name => "Sams", :num_awards => 1)]
    @test vals(filter(nb; num_books__lt = F(:num_awards) / 2)) == two
    @test vals(exclude(nb; num_books__lt = F(:num_awards) / 2)) == three
    @test vals(filter(nb; num_awards__gt = 2 * F(:num_books))) == two
    # test_db_col_table
    @test isempty(collect(annotate(values(objects(DarClues), "EntryID__Entry"); Appearances = Count("EntryID"),
                                   Distinct_Clues = Count("Clue"; distinct = true))))
    @test isempty(collect(annotate(objects(DarEntries); clue_count = Count("clues__id"))))
    # test_boolean_conversion
    e = create(DarEntries; Entry = "foo")
    c = create(DarClues; EntryID = e, Clue = "bar")
    qs = annotate(select_related(objects(DarClues), "EntryID"), Count(:id))
    @test [x.pk for x in collect(qs)] == [c.pk]
    @test collect(qs)[1].EntryID.pk == e.pk
    @test collect(qs)[1].EntryID.Exclude === false
  end
end

@testset "django aggregation_regress: AggregationTests (part 2)" begin
  port_block() do
    d = dar_data(); a, p, b = d.a, d.p, d.b
    B, Au, Pu, H = objects(DarBook), objects(DarAuthor), objects(DarPublisher), objects(DarHardbackBook)
    names(q) = [x.name for x in collect(q)]
    # test_empty
    @test count(filter(B; id__in = Int[])) == 0
    @test aggregate(filter(B; id__in = Int[]); num_authors = Count("authors"), avg_authors = Avg("authors"), max_authors = Max("authors"),
                    max_price = Max("price"), max_rating = Max("rating")) ==
          Dict(:max_authors => nothing, :max_rating => nothing, :num_authors => 0, :avg_authors => nothing, :max_price => nothing)
    @test collect(values(annotate(filter(Pu; name = "Jonno's House of Books"); num_authors = Count("book__authors"),
                                  avg_authors = Avg("book__authors"), max_authors = Max("book__authors"), max_price = Max("book__price"),
                                  max_rating = Max("book__rating")))) ==
          [Dict(:max_authors => nothing, :name => "Jonno's House of Books", :num_awards => 0, :max_price => nothing, :num_authors => 0,
                :max_rating => nothing, :id => p[5].id, :avg_authors => nothing)]
    # test_order_by_group_by_join
    @test names(order_by(annotate(B; num_authors = Count("authors")), "publisher__name", "name")) ==
          ["Practical Django Projects", "The Definitive Guide to Django: Web Development Done Right",
           "Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp", "Artificial Intelligence: A Modern Approach",
           "Python Web Development with Django", "Sams Teach Yourself Django in 24 Hours"]
    # test_annotate_select_related (select_related() with no arguments is deprecated in Django: the relations named)
    rows = [(x.name, x.authors__age__avg, x.publisher.name, x.contact.name) for x in
            collect(order_by(annotate(select_related(filter(B; rating__lt = 4.5), :publisher, :contact), Avg(:authors__age)), "name"))]
    @test [r[[1, 3, 4]] for r in rows] == [("Artificial Intelligence: A Modern Approach", "Prentice Hall", "Peter Norvig"),
                                           ("Practical Django Projects", "Apress", "James Bennett"),
                                           ("Python Web Development with Django", "Prentice Hall", "Jeffrey Forcier"),
                                           ("Sams Teach Yourself Django in 24 Hours", "Sams", "Brad Dayley")]
    @test rows[1][2] == 51.5 && rows[2][2] == 29.0 && dar_approx(rows[3][2], 30.333) && rows[4][2] == 45.0
    # test_aggregate_subquery_annotation
    ids = order_by(filter(annotate(filter(B; pages__gt = 100); n_authors = Count("authors")); n_authors__gt = 2), "n_authors")
    @test names(filter(B; id__in = ids)) == ["Python Web Development with Django"]
    # test_group_by_field_uniqueness
    qstr = first(Juango.select_sql(order_by(annotate(values(B, "publisher"); max_pages = Max("pages")))))
    @test count(", ", qstr[findfirst("GROUP BY", qstr)[1]:end]) == 0
    # test_duplicate_alias / test_field_name_conflict / test_m2m_name_conflict / test_fk_attname_conflict
    @test_throws "The named annotation 'authors__age__avg' conflicts with the default name for another annotation." annotate(B,
        Avg(:authors__age); authors__age__avg = Avg("authors__age"))
    @test_throws "The annotation 'age' conflicts with a field on the model." annotate(Au; age = Avg("friends__age"))
    @test_throws "The annotation 'friends' conflicts with a field on the model." annotate(Au; friends = Count("friends"))
    @test_throws "The annotation 'contact_id' conflicts with a field on the model." annotate(B; contact_id = F(:publisher_id))
    # test_values_queryset_non_conflict
    r = collect(order_by(annotate(values(Au, "name"); age = Count("book_contact_set")), "name"))
    @test length(r) == 9 && r[1][:name] == "Adrian Holovaty" && r[1][:age] == 1
    r = collect(order_by(annotate(values(Au, "name"); age = Avg("friends__age")), "name"))
    @test length(r) == 9 && r[1][:name] == "Adrian Holovaty" && r[1][:age] == 32.0
    r = collect(order_by(annotate(values(Au, "name"); friends = Count("friends")), "name"))
    @test length(r) == 9 && r[1][:name] == "Adrian Holovaty" && r[1][:friends] == 2
    # test_reverse_relation_name_conflict
    @test_throws "The annotation 'book_contact_set' conflicts with a field on the model." annotate(Au; book_contact_set = Avg("friends__age"))
    # test_pickle: Julia's serialize of a queryset
    qs = annotate(B; num_authors = Count("authors"))
    io = IOBuffer(); Juango.Serialization.serialize(io, qs); seekstart(io)
    @test first(Juango.select_sql(Juango.Serialization.deserialize(io))) == first(Juango.select_sql(qs))
    # test_aggregate_cloning
    books = B
    aggregate(books, Avg(:authors__age))
    @test names(books) == ["Artificial Intelligence: A Modern Approach", "Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp",
                           "Practical Django Projects", "Python Web Development with Django", "Sams Teach Yourself Django in 24 Hours",
                           "The Definitive Guide to Django: Web Development Done Right"]
    # test_annotate_with_dates
    @test collect(dates(filter(annotate(B; num_authors = Count("authors")); num_authors = 2), "pubdate", :day)) ==
          [Date(1995, 1, 15), Date(2007, 12, 6)]
    # test_annotate_and_count
    @test count(annotate(values(B, "publisher"), Count(:publisher))) == 4
    @test count(values(annotate(B, Count(:publisher)), "publisher")) == 6
    # test_annotate_ordering_by_annotation_and_filtering
    pubs = filter(Pu; id__in = [p[1].id, p[2].id])
    @test sort([x.name for x in collect(pubs)]) == ["Apress", "Sams"]
    pubs = annotate(pubs; n_books = Count("book"))
    sp = sort(collect(pubs); by = x -> x.name)
    @test sp[1].n_books == 2 && sp[2].n_books == 1
    @test names(filter(B; publisher__in = pubs)) == ["Practical Django Projects", "Sams Teach Yourself Django in 24 Hours",
                                                    "The Definitive Guide to Django: Web Development Done Right"]
    @test sort([x.name for x in collect(pubs)]) == ["Apress", "Sams"]
    # test_inherited_fields_aggregation
    @test aggregate(H; n_pages = Sum("darbook_ptr__pages")) == Dict(:n_pages => 2078)
    @test aggregate(H; n_pages = Sum("pages")) == Dict(:n_pages => 2078)
    want = [Dict(:n_authors => 2, :name => "Artificial Intelligence: A Modern Approach"),
            Dict(:n_authors => 1, :name => "Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp")]
    @test collect(order_by(values(annotate(H; n_authors = Count("darbook_ptr__authors")), "name", "n_authors"), "name")) == want
    @test collect(order_by(values(annotate(H; n_authors = Count("authors")), "name", "n_authors"), "name")) == want
    # test_aggregate_referencing_aggregate
    @test_throws "Cannot compute Avg('mean_age'): 'mean_age' is an aggregate" annotate(annotate(B; mean_age = Avg("authors__age")), Avg(:mean_age))
    # test_empty_filter_count / test_empty_filter_aggregate / test_none_call_before_aggregate
    @test count(annotate(filter(Au; id__in = Int[]), Count(:friends))) == 0
    @test aggregate(annotate(filter(Au; id__in = Int[]), Count(:friends)), Count(:pk)) == Dict(:pk__count => 0)
    @test aggregate(none(Au), Avg(:age)) == Dict(:age__avg => nothing)
    # test_annotate_and_join
    @test count(exclude(annotate(Au; c = Count("friends__name")); friends__name = "Joe")) == count(Au)
    # test_f_expression_annotation
    qs = values_list(filter(annotate(values(B, "name"); n_authors = Count("authors")); pages__lt = F(:n_authors) * 200), "pk")
    @test names(filter(B; pk__in = qs)) == ["Python Web Development with Django"]
    # test_values_annotate_values
    qs = order_by(values_list(annotate(values(B, "name"); n_authors = Count("authors")), "pk"; flat = true), "name")
    @test collect(qs) == collect(values_list(B, "pk"; flat = true))
    # test_having_group_by
    qs = order_by(values_list(filter(annotate(values_list(B, "name"); n_authors = Count("authors")); pages__gt = F(:n_authors)), "name";
                              flat = true), "name")
    @test collect(qs) == collect(values_list(B, "name"; flat = true))
    # test_values_list_annotation_args_ordering
    books = order_by(annotate(values_list(B, "publisher__name"), Count(:id), Avg(:price), Avg(:authors__age); avg_pgs = Avg("pages")),
                     "-publisher__name")
    r = collect(books)[1]
    @test r[1:2] == ("Sams", 1) && dar_approx(r[3], 23.09) && r[4] == 45.0 && r[5] == 528.0
    # test_annotation_disjunction
    na = annotate(B; n_authors = Count("authors"))
    @test names(order_by(filter(na, Q(n_authors = 2) | Q(name = "Python Web Development with Django")), "name")) ==
          ["Artificial Intelligence: A Modern Approach", "Python Web Development with Django",
           "The Definitive Guide to Django: Web Development Done Right"]
    @test names(order_by(filter(na, Q(name = "The Definitive Guide to Django: Web Development Done Right") |
                                    (Q(name = "Artificial Intelligence: A Modern Approach") & Q(n_authors = 3))), "name")) ==
          ["The Definitive Guide to Django: Web Development Done Right"]
    rs = annotate(Pu; rating_sum = Sum("book__rating"), book_count = Count("book"))
    @test names(order_by(filter(rs, Q(rating_sum__gt = 5.5) | Q(rating_sum__isnull = true)), "pk")) == ["Apress", "Prentice Hall", "Jonno's House of Books"]
    @test names(order_by(filter(rs, Q(rating_sum__gt = F(:book_count)) | Q(rating_sum = nothing)), "num_awards")) ==
          ["Jonno's House of Books", "Sams", "Apress", "Prentice Hall", "Morgan Kaufmann"]
    # test_quoting_aggregate_order_by
    @test [(x.name, x.authorCount) for x in collect(order_by(annotate(filter(B; name = "Python Web Development with Django");
                                                                       authorCount = Count("authors")), "authorCount"))] ==
          [("Python Web Development with Django", 3)]
    # test_stddev
    @test dar_approx(aggregate(B, StdDev(:pages))[:pages__stddev], 311.46; places = 1)
    @test dar_approx(aggregate(B, StdDev(:rating))[:rating__stddev], 0.60; places = 1)
    @test dar_approx(aggregate(B, StdDev(:price))[:price__stddev], 24.16)
    @test dar_approx(aggregate(B, StdDev(:pages; sample = true))[:pages__stddev], 341.19)
    @test dar_approx(aggregate(B, StdDev(:rating; sample = true))[:rating__stddev], 0.66)
    @test dar_approx(aggregate(B, StdDev(:price; sample = true))[:price__stddev], 26.46; places = 1)
    @test dar_approx(aggregate(B, Variance(:pages))[:pages__variance], 97010.80; places = 1)
    @test dar_approx(aggregate(B, Variance(:rating))[:rating__variance], 0.36; places = 1)
    @test dar_approx(aggregate(B, Variance(:price))[:price__variance], 583.77; places = 1)
    @test dar_approx(aggregate(B, Variance(:pages; sample = true))[:pages__variance], 116412.96; places = 1)
    @test dar_approx(aggregate(B, Variance(:rating; sample = true))[:rating__variance], 0.44)
    @test dar_approx(aggregate(B, Variance(:price; sample = true))[:price__variance], 700.53)
    # test_filtering_by_annotation_name
    @test names(order_by(filter(annotate(Au; book_cnt = Count("book")); book_cnt = 2), "name")) == ["Peter Norvig"]
    @test names(order_by(filter(annotate(Au; book_count = Count("book")); book_count = 2), "name")) == ["Peter Norvig"]
    @test names(order_by(filter(annotate(Au, Count(:book)); book__count = 2), "name")) == ["Peter Norvig"]
    @test aggregate(annotate(Au, Count(:book)), Max(:book__count)) == Dict(:book__count__max => 2)
    # test_annotate_joins
    @test length(collect(exclude(annotate(B; n = Count("pk")); publisher = -1))) == 6
  end
end

@testset "django aggregation_regress: AggregationTests (part 3)" begin
  port_block() do
    d = dar_data(); a, p, b = d.a, d.p, d.b
    B, Au, Pu = objects(DarBook), objects(DarAuthor), objects(DarPublisher)
    names(q) = [x.name for x in collect(q)]
    groupby(q) = (s = first(Juango.select_sql(q)); i = findfirst("GROUP BY", s); i === nothing ? "" : s[i[1]:end])
    # test_aggregate_duplicate_columns / ..._only: grouped by the key alone, not name and age
    contacts = [("Adrian Holovaty", 1), ("Brad Dayley", 1), ("Jacob Kaplan-Moss", 0), ("James Bennett", 1), ("Jeffrey Forcier", 1),
                ("Paul Bissex", 0), ("Peter Norvig", 2), ("Stuart Russell", 0), ("Wesley J. Chun", 0)]
    for results in (annotate(Au; num_contacts = Count("book_contact_set")), annotate(only(Au, "id", "name"); num_contacts = Count("book_contact_set")))
        g = groupby(results)
        @test occursin("id", g) && !occursin("name", g) && !occursin("age", g)
        @test [(x.name, x.num_contacts) for x in collect(order_by(results, "name"))] == contacts
    end
    # test_aggregate_duplicate_columns_select_related: the book's key and the contact's
    results = annotate(select_related(B, "contact"); num_authors = Count("authors"))
    g = groupby(order_by(results))
    @test count(",", g) == 1 && !occursin("name", g)
    @test [(x.name, x.num_authors) for x in collect(order_by(results, "name"))] ==
          [("Artificial Intelligence: A Modern Approach", 2), ("Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp", 1),
           ("Practical Django Projects", 1), ("Python Web Development with Django", 3), ("Sams Teach Yourself Django in 24 Hours", 1),
           ("The Definitive Guide to Django: Web Development Done Right", 2)]
    # (test_aggregate_unmanaged_model_columns / ..._as_tables mock Meta.managed and a backend feature: not translated)
    # test_reverse_join_trimming
    @test occursin(" JOIN ", first(Juango.select_sql(annotate(Au, Count(:book_contact_set__contact)))))
    # test_aggregation_with_generic_reverse_relation
    django_book = get(B; name = "Practical Django Projects")
    create(DarItemTag; object_id = django_book.id, tag = "intermediate", content_type = get_for_model(django_book))
    create(DarItemTag; object_id = django_book.id, tag = "django", content_type = get_for_model(django_book))
    wmpk = create(DarWithManualPK; mpk = django_book.pk)
    create(DarItemTag; object_id = wmpk.pk, tag = "hi mom", content_type = get_for_model(wmpk))
    ai_book = get(B; name__startswith = "Paradigms of Artificial Intelligence")
    create(DarItemTag; object_id = ai_book.id, tag = "intermediate", content_type = get_for_model(ai_book))
    @test aggregate(B, Count(:tags)) == Dict(:tags__count => 3)
    @test [(x.name, x.tags__count) for x in collect(order_by(annotate(B, Count(:tags)), "-tags__count", "name"))] ==
          [("Practical Django Projects", 2), ("Paradigms of Artificial Intelligence Programming: Case Studies in Common Lisp", 1),
           ("Artificial Intelligence: A Modern Approach", 0), ("Python Web Development with Django", 0),
           ("Sams Teach Yourself Django in 24 Hours", 0), ("The Definitive Guide to Django: Web Development Done Right", 0)]
    # test_negated_aggregation
    expected = names(order_by(exclude(Au; pk__in = filter(annotate(Au; book_cnt = Count("book")); book_cnt = 2)), "name"))
    @test names(order_by(exclude(annotate(Au; book_cnt = Count("book")), Q(book_cnt = 2), Q(book_cnt = 2)), "name")) == expected
    @test names(order_by(exclude(annotate(Au; book_cnt = Count("book")), Q(book_cnt = 2) | Q(book_cnt = 2)), "name")) == expected
    # test_name_filters / test_name_expressions
    @test names(order_by(filter(annotate(Au, Count(:book)), Q(book__count__exact = 2) | Q(name = "Adrian Holovaty")), "name")) ==
          ["Adrian Holovaty", "Peter Norvig"]
    @test names(order_by(filter(annotate(Au, Count(:book)), Q(name = "Peter Norvig") | Q(age = F(:book__count) + 33)), "name")) ==
          ["Adrian Holovaty", "Peter Norvig"]
    # test_filter_aggregates_or/negated_and/xor/negated_xor_connector
    q1, q2 = Q(price__gt = 50), Q(authors__count__gt = 1)
    pkq(q) = [x.pk for x in collect(order_by(filter(annotate(B, Count(:authors)), q), "pk"))]
    @test pkq(q1 | q2) == [b[1].pk, b[4].pk, b[5].pk, b[6].pk]
    @test pkq(!(q1 & q2)) == [b[1].pk, b[2].pk, b[3].pk, b[4].pk, b[6].pk]
    @test pkq(q1 ⊻ q2) == [b[1].pk, b[4].pk, b[6].pk]
    @test pkq(!(q1 ⊻ q2)) == [b[2].pk, b[3].pk, b[5].pk]
  end
end

@testset "django aggregation_regress: AggregationTests (part 4)" begin
  port_block() do
    d = dar_data(); a, p, b = d.a, d.p, d.b
    B, Au = objects(DarBook), objects(DarAuthor)
    names(q) = [x.name for x in collect(q)]
    # test_ticket_11293_q_immutable
    q1, q2 = Q(isbn = ""), Q(authors__count__gt = 1)
    filter(annotate(B, Count(:authors)), q1 | q2)
    @test length(q2.children) == 1
    # test_fobj_group_by
    @test names(filter(annotate(B; account = Count("authors")); account = F(:publisher__num_awards))) == ["Sams Teach Yourself Django in 24 Hours"]
    # test_annotate_reserved_word
    v = aggregate(annotate(B; select = Count("authors__id")), Sum(:select), Avg(:select))
    @test v[:select__sum] == 10 && dar_approx(v[:select__avg], 1.666)
    # test_annotate_on_relation / test_aggregate_on_relation
    bk = get(annotate(B; avg_price = Avg("price"), publisher_name = F(:publisher__name)); pk = b[1].pk)
    @test bk.avg_price == 30.0 && bk.publisher_name == "Apress"
    @test aggregate(annotate(B; avg_price = Avg("price")); publisher_awards = Sum("publisher__num_awards"))[:publisher_awards] == 30
    # test_annotate_distinct_aggregate
    @test aggregate(distinct(values(B, "rating", "price")); result = Sum("rating")) == aggregate(B; result = Sum("rating") - Value(4.0))
    # test_annotate_values_list_flat
    @test collect(filter(annotate(values_list(Au, "age"; flat = true); age_count = Count("age")); age_count__gt = 1)) == [29]
    # (test_allow_distinct: an Aggregate subclass's allow_distinct; Juango's aggregates are one type)
    # test_having_subquery_select
    books = filter(annotate(B, Count(:authors)), Q(authors__in = filter(Au; pk = a[1].pk)) | Q(authors__count__gt = 2))
    @test Set(x.pk for x in collect(books)) == Set([b[1].pk, b[4].pk])
    # test_aggregate_and_annotate_duplicate_columns
    @test collect(order_by(annotate(values(B, "isbn"); name = F(:publisher__name), num_authors = Count("authors")), "isbn")) ==
          [Dict(:isbn => "013235613", :name => "Prentice Hall", :num_authors => 3), Dict(:isbn => "013790395", :name => "Prentice Hall", :num_authors => 2),
           Dict(:isbn => "067232959", :name => "Sams", :num_authors => 1), Dict(:isbn => "155860191", :name => "Morgan Kaufmann", :num_authors => 1),
           Dict(:isbn => "159059725", :name => "Apress", :num_authors => 2), Dict(:isbn => "159059996", :name => "Apress", :num_authors => 1)]
    # test_aggregate_and_annotate_duplicate_columns_proxy / ..._unmanaged
    author = latest(objects(DarAuthorProxy), "pk")
    recipe = create(DarRecipeProxy; name = "Dahl", author = author)
    add!(recipe.tasters, author)
    @test collect(annotate(values(objects(DarRecipeProxy), "pk"); name = F(:author__name), num_tasters = Count("tasters"))) ==
          [Dict(:pk => recipe.pk, :name => "Stuart Russell", :num_tasters => 1)]
    @test collect(annotate(values(objects(DarRecipeUnmanaged), "pk"); name = F(:author__age), num_tasters = Count("tasters"))) ==
          [Dict(:pk => recipe.pk, :name => 46, :num_tasters => 1)]
    # test_aggregate_group_by_unseen_columns_unmanaged
    shadow_author = create(DarAuthorProxy; name = author.name, age = author.age - 2)
    shadow_recipe = create(DarRecipeProxy; name = "Shadow Dahl", author = shadow_author)
    add!(recipe.tasters, shadow_author)
    add!(shadow_recipe.tasters, author)
    ar = values(filter(annotate(values(annotate(objects(DarAuthorUnmanaged); name = Concat(Value("Writer at "), Cast(F(:age), CharField()))), "name");
                                num_recipes = Count("recipeunmanaged")); num_recipes__gt = 0), "num_recipes")
    @test collect(ar) == [Dict(:num_recipes => 1), Dict(:num_recipes => 1)]
  end
end

@testset "django aggregation_regress: JoinPromotionTests, SelfReferentialFKTests" begin
  port_block() do
    # test_ticket_21150
    bv = create(DarBravo)
    c = create(DarCharlie; bravo = bv)
    qs = annotate(select_related(objects(DarCharlie), "alfa"), Count(:bravo__darcharlie))
    @test [x.pk for x in collect(qs)] == [c.pk]
    @test collect(qs)[1].alfa === nothing
    al = create(DarAlfa)
    c.alfa = al; save!(c)
    @test [x.pk for x in collect(qs)] == [c.pk]
    @test collect(qs)[1].alfa.pk == al.pk
    # test_existing_join_not_promoted
    sq(q) = first(Juango.select_sql(q))
    # (Juango keeps the LEFT JOIN that a filter excluding nulls lets Django make INNER: the same rows, as in select_related_regress)
    @test_broken occursin(" INNER JOIN ", sq(annotate(filter(objects(DarCharlie); alfa__name__isnull = false), Count(:alfa__name))))
    @test_broken occursin(" INNER JOIN ", sq(filter(annotate(objects(DarCharlie), Count(:alfa__name)); alfa__name__isnull = false)))
    @test occursin(" LEFT OUTER JOIN ", sq(annotate(objects(DarCharlie), Count(:alfa__name))))
    # test_non_nullable_fk_not_promoted
    @test occursin(" INNER JOIN ", sq(annotate(objects(DarBook), Count(:contact__name))))
    # test_ticket_24748
    t1 = create(DarSelfRefFK; name = "t1")
    create(DarSelfRefFK; name = "t2", parent = t1)
    create(DarSelfRefFK; name = "t3", parent = t1)
    @test [(x.name, x.num_children) for x in collect(order_by(annotate(objects(DarSelfRefFK); num_children = Count("children")), "name"))] ==
          [("t1", 2), ("t2", 0), ("t3", 0)]
  end
end

@testset "django unmanaged_models" begin
  port_block() do
    # test_simple
    a = create(DumA01; f_a = "foo", f_b = 42)
    create(DumB01; fk_a = a, f_a = "fred", f_b = 1729)
    c = create(DumC01; f_a = "barney", f_b = 1)
    set!(c.mm_a, [a])
    a2 = collect(objects(DumA02))[1]
    @test a2 isa DumA02 && a2.f_a == "foo"
    b2 = collect(objects(DumB02))[1]
    @test b2 isa DumB02 && b2.f_a == "fred"
    @test b2.fk_a isa DumA02 && b2.fk_a.f_a == "foo"
    @test isempty(collect(filter(objects(DumC02); f_a = nothing)))
    resp = collect(filter(objects(DumC02); mm_a = a.id))
    @test length(resp) == 1 && resp[1] isa DumC02 && resp[1].f_a == "barney"
    # test_many_to_many_between_unmanaged / ..._and_managed
    b = Juango.backend()
    @test !Juango.table_exists(b, Juango.modelmeta(through(DumUnmanaged2, :mm)).table)
    @test Juango.table_exists(b, Juango.modelmeta(through(DumManaged1, :mm)).table)
  end
end

# --- tests/model_enums ------------------------------------------------------------------------------------
@choices DmeSuit begin
    DIAMOND = 1, gettext_lazy("Diamond")
    SPADE = 2, gettext_lazy("Spade")
    HEART = 3, gettext_lazy("Heart")
    CLUB = 4, gettext_lazy("Club")
end
@choices DmeYearInSchool begin
    FRESHMAN = "FR", gettext_lazy("Freshman")
    SOPHOMORE = "SO", gettext_lazy("Sophomore")
    JUNIOR = "JR", gettext_lazy("Junior")
    SENIOR = "SR", gettext_lazy("Senior")
    GRADUATE = "GR", gettext_lazy("Graduate")
end
@choices DmeVehicle begin
    CAR = 1, "Carriage"
    TRUCK = 2
    JET_SKI = 3
    __empty__ = gettext_lazy("(Unknown)")
end
@choices DmeGender begin
    MALE = "M"
    FEMALE = "F"
    NOT_SPECIFIED = "X"
    __empty__ = "(Undeclared)"
end

@choices DmeMoonLandings begin
    APOLLO_11 = Date(1969, 7, 20), "Apollo 11 (Eagle)"
    APOLLO_12 = Date(1969, 11, 19), "Apollo 12 (Intrepid)"
end
@choices DmeMealTimes begin
    BREAKFAST = Time(7, 0)
    LUNCH = Time(13, 0)
    DINNER = Time(18, 30)
end
@choices DmeConstants begin
    PI = 3.141592653589793, "π"
    TAU = 6.283185307179586, "τ"
end
@choices DmeNumber begin
    E = Juango.Decimal("2.718281828459045"), "e"
    PI = Juango.Decimal("3.141592653589793"), "π"
end

@testset "django model_enums: ChoicesTests, CustomChoicesTests" begin
    S = DmeSuit
    # test_integerchoices
    @test S.choices == [1 => "Diamond", 2 => "Spade", 3 => "Heart", 4 => "Club"]
    @test S.labels == ["Diamond", "Spade", "Heart", "Club"]
    @test S.values == [1, 2, 3, 4]
    @test S.names == ["DIAMOND", "SPADE", "HEART", "CLUB"]
    @test S.DIAMOND.label == "Diamond" && S.DIAMOND.value == 1
    @test S["DIAMOND"] == S.DIAMOND && S(1) == S.DIAMOND
    @test S.DIAMOND isa Choice && S.DIAMOND.value isa Int
    # (Django's repr(Suit.DIAMOND) is "Suit.DIAMOND"; Juango's show gives the name, value and label)
    # test_integerchoices_auto_label / test_integerchoices_empty_label
    @test (DmeVehicle.CAR.label, DmeVehicle.TRUCK.label, DmeVehicle.JET_SKI.label) == ("Carriage", "Truck", "Jet Ski")
    @test DmeVehicle.choices[1] == (nothing => "(Unknown)") && DmeVehicle.labels[1] == "(Unknown)"
    @test DmeVehicle.values[1] === nothing && DmeVehicle.names[1] == "__empty__"
    # test_integerchoices_functional_api / test_integerchoices_containment
    Place = IntegerChoices("Place", "FIRST SECOND THIRD")
    @test Place.labels == ["First", "Second", "Third"] && Place.values == [1, 2, 3] && Place.names == ["FIRST", "SECOND", "THIRD"]
    @test S.DIAMOND in S && 1 in S && !(0 in S)
    # test_textchoices
    Y = DmeYearInSchool
    @test Y.choices == ["FR" => "Freshman", "SO" => "Sophomore", "JR" => "Junior", "SR" => "Senior", "GR" => "Graduate"]
    @test Y.labels == ["Freshman", "Sophomore", "Junior", "Senior", "Graduate"]
    @test Y.values == ["FR", "SO", "JR", "SR", "GR"] && Y.names == ["FRESHMAN", "SOPHOMORE", "JUNIOR", "SENIOR", "GRADUATE"]
    @test Y.FRESHMAN.label == "Freshman" && Y.FRESHMAN.value == "FR" && Y["FRESHMAN"] == Y.FRESHMAN && Y("FR") == Y.FRESHMAN
    @test Y.FRESHMAN.value isa String
    # test_textchoices_auto_label / _empty_label / _functional_api / _containment
    @test (DmeGender.MALE.label, DmeGender.FEMALE.label, DmeGender.NOT_SPECIFIED.label) == ("Male", "Female", "Not Specified")
    @test DmeGender.choices[1] == (nothing => "(Undeclared)") && DmeGender.labels[1] == "(Undeclared)"
    @test DmeGender.values[1] === nothing && DmeGender.names[1] == "__empty__"
    Medal = TextChoices("Medal", "GOLD SILVER BRONZE")
    @test Medal.labels == ["Gold", "Silver", "Bronze"] && Medal.values == ["GOLD", "SILVER", "BRONZE"] && Medal.names == ["GOLD", "SILVER", "BRONZE"]
    @test Y.FRESHMAN in Y && "FR" in Y && !("XX" in Y)
    # test_textchoices_blank_value
    BlankStr = ChoiceSet(:BlankStr, Choice[Choice(:EMPTY, "", "(Empty)"), Choice(:ONE, "ONE", "One")])
    @test BlankStr.labels == ["(Empty)", "One"] && BlankStr.values == ["", "ONE"] && BlankStr.names == ["EMPTY", "ONE"]
    # test_invalid_definition
    @test_throws Exception @eval @choices DmeInvalidArgumentEnum begin
        ONE = 1, "X", "Invalid"
    end
    @test_throws "duplicate values found in <enum 'Fruit'>: PINEAPPLE -> APPLE" ChoiceSet(:Fruit,
        Choice[Choice(:APPLE, 1, "Apple"), Choice(:PINEAPPLE, 1, "Pineapple")])
    # test_str
    for t in (DmeGender, S, Y, DmeVehicle), m in t
        @test string(t[m.name]) == string(m.value)
    end
    # test_templates
    @test render(Template("{{ Suit.DIAMOND.label }}|{{ Suit.DIAMOND.value }}"), Dict("Suit" => S)) == "Diamond|1"
    # test_property_names_conflict_with_member_names / test_label_member
    @test_throws ArgumentError TextChoices("Properties", "choices labels names values")
    Stationery = TextChoices("Stationery", "label stamp sticker")
    @test Stationery.label.label == "Label" && Stationery.label.value == "label" && Stationery.label.name === :label
    # (test_do_not_call_in_templates_*: Django templates call callables; not applicable)
    # CustomChoicesTests.test_labels_valid: values of other types, labels from the names
    for e in (DmeMoonLandings, DmeMealTimes, DmeConstants, DmeNumber)
        @test !(nothing in e.labels)
    end
    @test DmeMealTimes.LUNCH.label == "Lunch"
end

# --- tests/model_indexes ------------------------------------------------------------------------------------
@testset "django model_indexes: SimpleIndexesTests" begin
    # (test_suffix: Django's Index.suffix "idx"; Juango's index names end in _idx too)
    # test_repr
    @test repr(Index(fields = ["title"])) == "<Index: fields=['title']>"
    @test repr(Index(fields = ["title"], name = "title_idx")) == "<Index: fields=['title'] name='title_idx'>"
    @test repr(Index(fields = ["title", "author"])) == "<Index: fields=['title', 'author']>"
    @test repr(Index(fields = ["title"], name = "long_books_idx", condition = Q(pages__gt = 400))) ==
          "<Index: fields=['title'] name='long_books_idx' condition=(AND: ('pages__gt', 400))>"
    @test repr(Index(fields = ["title"], name = "include_idx", include = ["author", "pages"])) ==
          "<Index: fields=['title'] name='include_idx' include=('author', 'pages')>"
    @test repr(Index(fields = ["headline", "body"], name = "opclasses_idx", opclasses = ["varchar_pattern_ops", "text_pattern_ops"])) ==
          "<Index: fields=['headline', 'body'] name='opclasses_idx' opclasses=['varchar_pattern_ops', 'text_pattern_ops']>"
    @test repr(Index(Lower(:title), "subtitle"; name = "book_func_idx")) == "<Index: expressions=(Lower(F(title)), F(subtitle)) name='book_func_idx'>"
    # (the db_tablespace repr: Juango has no tablespaces)
    # test_eq / test_eq_func
    @test Index(fields = ["title"]) == Index(fields = ["title"]) && Index(fields = ["title"]) != Index(fields = ["title", "author"])
    @test Index(Lower(:title), F(:author); name = "book_func_idx") == Index(Lower(:title), "author"; name = "book_func_idx")
    @test Index(Lower(:title), F(:author); name = "book_func_idx") != Index(Lower(:title); name = "book_func_idx")
    # test_index_fields_type ... test_include_requires_index_name
    @test_throws "Index.fields must be a list or tuple." Index(fields = "title")
    @test_throws "Index.fields must contain only strings with field names." Index(fields = [F(:title)])
    @test Index(fields = ("title",)).fields == ["title"]
    @test_throws "At least one field or expression is required to define an index." Index()
    @test_throws "Index.fields and expressions are mutually exclusive." Index(Upper(:foo); fields = ["field"])
    @test_throws "An index must be named to use opclasses." Index(opclasses = ["jsonb_path_ops"])
    @test_throws "Index.opclasses must be a list or tuple." Index(name = "test_opclass", fields = ["field"], opclasses = "jsonb_path_ops")
    @test_throws "Index.fields and Index.opclasses must have the same number of elements." Index(name = "test_opclass",
        fields = ["field", "other"], opclasses = ["jsonb_path_ops"])
    @test_throws "An index must be named to use condition." Index(condition = Q(pages__gt = 400))
    @test_throws "An index must be named to use expressions." Index(Lower(:field))
    @test_throws "Index.opclasses cannot be used with expressions." Index(Lower(:field); name = "test_func_opclass", opclasses = ["jsonb_path_ops"])
    @test_throws "Index.condition must be a Q instance." Index(condition = "invalid", name = "long_book_idx")
    @test_throws "Index.include must be a list or tuple." Index(name = "test_include", fields = ["field"], include = "other")
    @test_throws "A covering index must be named." Index(fields = ["field"], include = ["other"])
    # test_name_auto_generation, test_name_set, test_abstract_children: Django names an unnamed index
    # table[:11]_column[:7]_<md5 digest>_idx ("model_index_author_0f5565_idx"); Juango names it table_columns_idx.
    # Changing that would rename the indexes of existing projects' migrations: question #281.
    @test_broken false
    # test_clone
    ix = Index(fields = ["title"])
    @test Index(fields = copy(ix.fields)) == ix          # (immutable: a copy is an equal one)
    # (test_deconstruction ...: Django's migration serializer; Juango writes Index(...) source itself, tested in migrations.jl)
end
