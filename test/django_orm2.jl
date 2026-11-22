# More of Django's ORM tests, ported (#227): tests/or_lookups, dates, datetimes, raw_query, expressions_case.
# julia --project=test test/django_orm2.jl   (see setup.jl)
#
# As django_orm.jl: Django's models and data, translated to Juango's API; each test keeps its Django name in a
# comment. Python-only APIs (repr of Q objects, pyformat parameters, %-escaping) aren't translated; Juango's raw
# SQL uses `?` placeholders. Fetch modes (FETCH_PEERS, FETCH_RAISE) are #230.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# --- tests/or_lookups/models.py -----------------------------------------------------------------------
@model struct DolArticle
    headline = CharField(max_length = 50)
    pub_date = DateTimeField()
    Meta(table = "dol_article", ordering = ["pub_date"])
end
# --- tests/dates/models.py ----------------------------------------------------------------------------
@model struct DdtArticle
    title = CharField(max_length = 100)
    pub_date = DateField()
    pub_datetime = DateTimeField(default = now)
    Meta(table = "ddt_article")
end
@model struct DdtComment
    article = ForeignKey(DdtArticle, on_delete = :CASCADE, related_name = :comments)
    text = TextField()
    pub_date = DateField()
    approval_date = DateField(null = true)
    Meta(table = "ddt_comment")
end
@model struct DdtCategory
    name = CharField(max_length = 255)
    articles = ManyToManyField(DdtArticle; related_name = :categories)
    Meta(table = "ddt_category")
end
# --- tests/datetimes/models.py ------------------------------------------------------------------------
@model struct DdsArticle
    title = CharField(max_length = 100)
    pub_date = DateTimeField()
    published_on = DateField(null = true)
    Meta(table = "dds_article")
end
@model struct DdsComment
    article = ForeignKey(DdsArticle, on_delete = :CASCADE, related_name = :comments)
    text = TextField()
    pub_date = DateTimeField()
    approval_date = DateTimeField(null = true)
    Meta(table = "dds_comment")
end
@model struct DdsCategory
    name = CharField(max_length = 255)
    articles = ManyToManyField(DdsArticle; related_name = :categories)
    Meta(table = "dds_category")
end
# --- tests/raw_query/models.py ------------------------------------------------------------------------
@model struct DrqAuthor
    first_name = CharField(max_length = 255)
    last_name = CharField(max_length = 255)
    dob = DateField()
    Meta(table = "drq_author")
end
@model struct DrqBook
    title = CharField(max_length = 255)
    author = ForeignKey(DrqAuthor, on_delete = :CASCADE)
    paperback = BooleanField(default = false)
    opening_line = TextField()
    Meta(table = "drq_book")
end
@model struct DrqBookFkAsPk
    book = ForeignKey(DrqBook, on_delete = :CASCADE, primary_key = true, db_column = "not_the_default")
    Meta(table = "drq_bookfkaspk")
end
@model struct DrqCoffee
    brand = CharField(max_length = 255, db_column = "name")
    price = DecimalField(max_digits = 10, decimal_places = 2, default = 0)
    Meta(table = "drq_coffee")
end
@model struct DrqReviewer
    reviewed = ManyToManyField(DrqBook)
    Meta(table = "drq_reviewer")
end
@model struct DrqFriendlyAuthor <: DrqAuthor
    Meta(table = "drq_friendlyauthor")
end
# --- tests/expressions_case/models.py ------------------------------------------------------------------
@model struct DcsCaseTestModel
    integer = IntegerField()
    integer2 = IntegerField(null = true)
    string = CharField(max_length = 100, default = "")
    big_integer = BigIntegerField(null = true)
    binary = BinaryField(default = UInt8[])
    boolean = BooleanField(default = false)
    date = DateField(null = true, db_column = "date_field")
    date_time = DateTimeField(null = true)
    decimal = DecimalField(max_digits = 2, decimal_places = 1, null = true, db_column = "decimal_field")
    duration = DurationField(null = true)
    email = EmailField(default = "")
    file = FileField(null = true, db_column = "file_field")
    file_path = FilePathField(null = true)
    float = FloatField(null = true, db_column = "float_field")
    generic_ip_address = GenericIPAddressField(null = true)
    null_boolean = BooleanField(null = true)
    positive_integer = PositiveIntegerField(null = true)
    positive_small_integer = PositiveSmallIntegerField(null = true)
    positive_big_integer = PositiveSmallIntegerField(null = true)
    slug = SlugField(default = "")
    small_integer = SmallIntegerField(null = true)
    text = TextField(default = "")
    time = TimeField(null = true, db_column = "time_field")
    url = URLField(default = "")
    uuid = UUIDField(null = true)
    fk = ForeignKey(:self; on_delete = :CASCADE, null = true, related_name = :dcs_children)
    Meta(table = "dcs_casetestmodel")
end
@model struct DcsO2OCaseTestModel
    o2o = OneToOneField(DcsCaseTestModel; on_delete = :CASCADE, related_name = :o2o_rel)
    integer = IntegerField()
    Meta(table = "dcs_o2ocasetestmodel")
end
@model struct DcsFKCaseTestModel
    fk = ForeignKey(DcsCaseTestModel; on_delete = :CASCADE, related_name = :fk_rel)
    integer = IntegerField()
    Meta(table = "dcs_fkcasetestmodel")
end
@model struct DcsClient
    name = CharField(max_length = 50)
    registered_on = DateField()
    account_type = CharField(max_length = 1, choices = [("R", "Regular"), ("G", "Gold"), ("P", "Platinum")], default = "R")
    Meta(table = "dcs_client")
end
redirect_stdout(devnull) do
    ms = [DolArticle, DdtArticle, DdtComment, DdtCategory, through(DdtCategory, :articles),
          DdsArticle, DdsComment, DdsCategory, through(DdsCategory, :articles),
          DrqAuthor, DrqBook, DrqBookFkAsPk, DrqCoffee, DrqReviewer, through(DrqReviewer, :reviewed), DrqFriendlyAuthor,
          DcsCaseTestModel, DcsO2OCaseTestModel, DcsFKCaseTestModel, DcsClient]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django or_lookups" begin
  port_block() do
    a1 = create(DolArticle; headline = "Hello", pub_date = DateTime(2005, 11, 27)).id
    a2 = create(DolArticle; headline = "Goodbye", pub_date = DateTime(2005, 11, 28)).id
    a3 = create(DolArticle; headline = "Hello and goodbye", pub_date = DateTime(2005, 11, 29)).id
    h(qs) = [a.headline for a in qs]
    all3 = ["Hello", "Goodbye", "Hello and goodbye"]
    A = objects(DolArticle)
    # test_filter_or
    @test h(filter(A; headline__startswith = "Hello") | filter(A; headline__startswith = "Goodbye")) == all3
    @test h(filter(A; headline__contains = "Hello") | filter(A; headline__contains = "bye")) == all3
    @test h(filter(A; headline__iexact = "Hello") | filter(A; headline__contains = "ood")) == all3
    @test h(filter(A, Q(headline__startswith = "Hello") | Q(headline__startswith = "Goodbye"))) == all3
    # test_stages
    @test isempty(h(filter(A; headline__startswith = "Hello") & filter(A; headline__startswith = "Goodbye")))
    @test h(filter(A; headline__startswith = "Hello") & filter(A; headline__contains = "bye")) == ["Hello and goodbye"]
    # test_pk_q
    @test h(filter(A, Q(pk = a1) | Q(pk = a2))) == ["Hello", "Goodbye"]
    @test h(filter(A, Q(pk = a1) | Q(pk = a2) | Q(pk = a3))) == all3
    # test_pk_in
    @test h(filter(A; pk__in = [a1, a2, a3])) == all3 && h(filter(A; pk__in = (a1, a2, a3))) == all3
    @test h(filter(A; pk__in = [a1, a2, a3, 40000])) == all3
    # test_q_negated
    @test h(filter(A, Q(pk = a1) | ~Q(pk = a2))) == ["Hello", "Hello and goodbye"]
    @test h(filter(A, ~Q(pk = a1) & ~Q(pk = a2))) == ["Hello and goodbye"]
    @test h(filter(A, Q(pk = a1) & (~Q(pk = a2) | Q(pk = a3)))) == ["Hello"]
    # test_complex_filter
    @test h(complex_filter(A, Dict("pk" => a1))) == ["Hello"]
    @test h(complex_filter(A, Q(pk = a1) | Q(pk = a2))) == ["Hello", "Goodbye"]
    # test_empty_in
    @test isempty(h(filter(A; pk__in = Int[])))
    @test h(filter(A, Q(pk__in = Int[]) | Q(headline__icontains = "goodbye"))) == ["Goodbye", "Hello and goodbye"]
    # test_q_and
    @test h(filter(A, Q(headline__startswith = "Hello"), Q(headline__contains = "bye"))) == ["Hello and goodbye"]
    @test h(filter(A, Q(headline__contains = "bye"); headline__startswith = "Hello")) == ["Hello and goodbye"]
    @test isempty(h(filter(A, Q(headline__startswith = "Hello") & Q(headline__startswith = "Goodbye"))))
    # test_q_exclude
    @test h(exclude(A, Q(headline__startswith = "Hello"))) == ["Goodbye"]
    # test_other_arg_queries
    @test get(A, Q(headline__startswith = "Hello"), Q(headline__contains = "bye")).headline == "Hello and goodbye"
    @test count(filter(A, Q(headline__startswith = "Hello") | Q(headline__contains = "bye"))) == 3
    v = collect(values(filter(A, Q(headline__startswith = "Hello"), Q(headline__contains = "bye"))))
    @test length(v) == 1 && v[1][:headline] == "Hello and goodbye" && v[1][:id] == a3 && v[1][:pub_date] == DateTime(2005, 11, 29)
    b = in_bulk(filter(A, Q(headline__startswith = "Hello")), [a1, a2])
    @test collect(keys(b)) == [a1] && b[a1] == get(A; pk = a1)
  end
end

@testset "django dates" begin
  port_block() do
    # test_related_model_traverse
    a1 = create(DdtArticle; title = "First one", pub_date = Date(2005, 7, 28))
    a2 = create(DdtArticle; title = "Another one", pub_date = Date(2010, 7, 28))
    a3 = create(DdtArticle; title = "Third one, in the first day", pub_date = Date(2005, 7, 28))
    create(DdtComment; article = a1, text = "Im the HULK!", pub_date = Date(2005, 7, 28))
    create(DdtComment; article = a1, text = "HULK SMASH!", pub_date = Date(2005, 7, 29))
    create(DdtComment; article = a2, text = "LMAO", pub_date = Date(2010, 7, 28))
    create(DdtComment; article = a3, text = "+1", pub_date = Date(2005, 8, 29))
    c = create(DdtCategory; name = "serious-news")
    add!(c.articles, a1, a3)
    @test dates(DdtComment, "article__pub_date", "year") == [Date(2005), Date(2010)]
    @test dates(DdtComment, "article__pub_date", "month") == [Date(2005, 7), Date(2010, 7)]
    @test dates(DdtComment, "article__pub_date", "week") == [Date(2005, 7, 25), Date(2010, 7, 26)]
    @test dates(DdtComment, "article__pub_date", "day") == [Date(2005, 7, 28), Date(2010, 7, 28)]
    @test dates(DdtArticle, "comments__pub_date", "day") == [Date(2005, 7, 28), Date(2005, 7, 29), Date(2005, 8, 29), Date(2010, 7, 28)]
    @test isempty(dates(DdtArticle, "comments__approval_date", "day"))
    @test dates(DdtCategory, "articles__pub_date", "day") == [Date(2005, 7, 28)]
    # test_dates_fails_when_no_arguments_are_provided
    @test_throws MethodError dates(DdtArticle)
    # test_dates_fails_when_given_invalid_field_argument
    e = try dates(DdtArticle, "invalid_field", "year") catch e; e end
    @test e isa Juango.LookupError && occursin("'invalid_field'", e.msg) && occursin("Choices are: categories, comments, id, pub_date, pub_datetime, title", e.msg)
    # test_dates_fails_when_given_invalid_kind_argument
    e = try dates(DdtArticle, "pub_date", "bad_kind") catch e; e end
    @test e isa ArgumentError && e.msg == "'kind' must be one of 'year', 'month', 'week', or 'day'."
    # test_dates_fails_when_given_invalid_order_argument
    e = try dates(DdtArticle, "pub_date", "year"; order = "bad order") catch e; e end
    @test e isa ArgumentError && e.msg == "'order' must be either 'ASC' or 'DESC'."
    @test dates(DdtArticle, "pub_date", "year"; order = "DESC") == [Date(2010), Date(2005)]   # (Django's strings, and Juango's :desc)
    @test dates(DdtArticle, "pub_date", "year"; order = :desc) == [Date(2010), Date(2005)]
  end
  port_block() do
    # test_dates_trunc_datetime_fields
    override_settings(USE_TZ = false) do
        bulk_create([DdtArticle(title = "", pub_date = Date(d), pub_datetime = d)
                                 for d in (DateTime(2015, 10, 21, 18, 1), DateTime(2015, 10, 21, 18, 2), DateTime(2015, 10, 22, 18, 1), DateTime(2015, 10, 22, 18, 2))])
        @test dates(DdtArticle, "pub_datetime", "day"; order = "ASC") == [Date(2015, 10, 21), Date(2015, 10, 22)]
    end
  end
end

@testset "django datetimes" begin
  port_block() do
    # test_related_model_traverse
    a1 = create(DdsArticle; title = "First one", pub_date = DateTime(2005, 7, 28, 9))
    a2 = create(DdsArticle; title = "Another one", pub_date = DateTime(2010, 7, 28, 10))
    a3 = create(DdsArticle; title = "Third one, in the first day", pub_date = DateTime(2005, 7, 28, 17))
    create(DdsComment; article = a1, text = "Im the HULK!", pub_date = DateTime(2005, 7, 28, 9, 30))
    create(DdsComment; article = a1, text = "HULK SMASH!", pub_date = DateTime(2005, 7, 29, 1, 30))
    create(DdsComment; article = a2, text = "LMAO", pub_date = DateTime(2010, 7, 28, 10, 10, 10))
    create(DdsComment; article = a3, text = "+1", pub_date = DateTime(2005, 8, 29, 10, 10, 10))
    c = create(DdsCategory; name = "serious-news")
    add!(c.articles, a1, a3)
    @test datetimes(DdsComment, "article__pub_date", "year") == [DateTime(2005), DateTime(2010)]
    @test datetimes(DdsComment, "article__pub_date", "month") == [DateTime(2005, 7), DateTime(2010, 7)]
    @test datetimes(DdsComment, "article__pub_date", "week") == [DateTime(2005, 7, 25), DateTime(2010, 7, 26)]
    @test datetimes(DdsComment, "article__pub_date", "day") == [DateTime(2005, 7, 28), DateTime(2010, 7, 28)]
    @test datetimes(DdsArticle, "comments__pub_date", "day") == DateTime.([Date(2005, 7, 28), Date(2005, 7, 29), Date(2005, 8, 29), Date(2010, 7, 28)])
    @test isempty(datetimes(DdsArticle, "comments__approval_date", "day"))
    @test datetimes(DdsCategory, "articles__pub_date", "day") == [DateTime(2005, 7, 28)]
  end
  port_block() do
    # test_21432
    override_settings(USE_TZ = true) do
        t = Juango.localtime(Dates.floor(timezone_now(), Second))
        create(DdsArticle; title = "First one", pub_date = t)
        @test only(datetimes(DdsArticle, "pub_date", "second")) == t
    end
  end
  port_block() do
    # test_datetimes_returns_available_dates_for_given_scope_and_given_field
    for (i, d) in enumerate([DateTime(2005, 7, 28, 12, 15), DateTime(2005, 7, 29, 2, 15), DateTime(2005, 7, 30, 5, 15), DateTime(2005, 7, 31, 19, 15)])
        save!(DdsArticle(pub_date = d, title = "title #$(i - 1)"))
    end
    days = [DateTime(2005, 7, d) for d in 28:31]
    @test datetimes(DdsArticle, "pub_date", "year") == [DateTime(2005)]
    @test datetimes(DdsArticle, "pub_date", "month") == [DateTime(2005, 7)]
    @test datetimes(DdsArticle, "pub_date", "week") == [DateTime(2005, 7, 25)]
    @test datetimes(DdsArticle, "pub_date", "day") == days
    @test datetimes(DdsArticle, "pub_date", "day"; order = "ASC") == days
    @test datetimes(DdsArticle, "pub_date", "day"; order = "DESC") == reverse(days)
    # test_datetimes_has_lazy_iterator (Juango's datetimes runs one query and returns the values)
    @test assert_num_queries(() -> datetimes(DdsArticle, "pub_date", "day"; order = "DESC"), 1)
    # test_datetimes_disallows_date_fields
    create(DdsArticle; pub_date = DateTime(2005, 7, 28, 12, 15), published_on = Date(2005, 7, 28), title = "Don't put dates into datetime functions!")
    e = try datetimes(DdsArticle, "published_on", "second") catch e; e end
    @test e isa ArgumentError && e.msg == "Cannot truncate DateField 'published_on' to DateTimeField"
    # test_datetimes_fails_when_given_invalid_kind_argument
    e = try datetimes(DdsArticle, "pub_date", "bad_kind") catch e; e end
    @test e isa ArgumentError && e.msg == "'kind' must be one of 'year', 'month', 'week', 'day', 'hour', 'minute', or 'second'."
    # test_datetimes_fails_when_given_invalid_order_argument
    e = try datetimes(DdsArticle, "pub_date", "year"; order = "bad order") catch e; e end
    @test e isa ArgumentError && e.msg == "'order' must be either 'ASC' or 'DESC'."
  end
end

@testset "django raw_query" begin
  port_block() do
    a1 = create(DrqAuthor; first_name = "Joe", last_name = "Smith", dob = Date(1950, 9, 20))
    a2 = create(DrqAuthor; first_name = "Jill", last_name = "Doe", dob = Date(1920, 4, 2))
    a3 = create(DrqAuthor; first_name = "Bob", last_name = "Smith", dob = Date(1986, 1, 25))
    a4 = create(DrqAuthor; first_name = "Bill", last_name = "Jones", dob = Date(1932, 5, 10))
    b1 = create(DrqBook; title = "The awesome book", author = a1, paperback = false,
                opening_line = "It was a bright cold day in April and the clocks were striking thirteen.")
    b2 = create(DrqBook; title = "The horrible book", author = a1, paperback = true, opening_line = "On an evening in the latter part of May...")
    b3 = create(DrqBook; title = "Another awesome book", author = a1, paperback = false, opening_line = "A squat gray building of only thirty-four stories.")
    b4 = create(DrqBook; title = "Some other book", author = a3, paperback = true, opening_line = "It was the day my grandmother exploded.")
    create(DrqCoffee; brand = "dunkin doughnuts"); create(DrqCoffee; brand = "starbucks")
    r1 = create(DrqReviewer); create(DrqReviewer)
    add!(r1.reviewed, b2, b3, b4)
    # assertSuccessfulRawQuery: the same objects, field by field (and of the same types), with the annotations
    function same(T, results, orig, annotations = ())
        length(results) == length(orig) || return false
        for (i, (r, o)) in enumerate(zip(results, orig))
            for f in Juango.concrete_fields(T)
                a = Juango.attname(f)
                (getproperty(r, a) == getproperty(o, a) && typeof(getproperty(r, a)) == typeof(getproperty(o, a))) || return false
            end
            isempty(annotations) || getproperty(r, annotations[i][1]) == annotations[i][2] || return false
        end
        true
    end
    authors = collect(order_by(objects(DrqAuthor), "pk"))
    @test same(DrqAuthor, collect(raw(DrqAuthor, "SELECT * FROM drq_author ORDER BY id")), authors)      # test_simple_raw_query
    q = raw(DrqAuthor, "SELECT * FROM drq_author")                                         # test_raw_query_lazy
    @test assert_num_queries(() -> raw(DrqAuthor, "SELECT * FROM drq_author"), 0)
    @test assert_num_queries(() -> collect(q), 1)
    @test same(DrqBook, collect(raw(DrqBook, "SELECT * FROM drq_book ORDER BY id")), collect(order_by(objects(DrqBook), "pk")))   # test_FK_raw_query
    @test same(DrqCoffee, collect(raw(DrqCoffee, "SELECT * FROM drq_coffee ORDER BY id")), collect(order_by(objects(DrqCoffee), "pk")))   # test_db_column_handler
    for sel in ("dob, last_name, first_name, id", "last_name, dob, first_name, id", "first_name, last_name, dob, id")   # test_order_handler
        @test same(DrqAuthor, collect(raw(DrqAuthor, "SELECT $sel FROM drq_author ORDER BY id")), authors)
    end
    @test same(DrqAuthor, collect(raw(DrqAuthor, "SELECT first_name AS first, last_name AS last, dob, id FROM drq_author ORDER BY id";   # test_translations
                                      translations = Dict("first" => "first_name", "last" => "last_name"))), authors)
    author = collect(objects(DrqAuthor))[3]                                               # test_params
    qs = raw(DrqAuthor, "SELECT * FROM drq_author WHERE first_name = ?", [author.first_name])
    @test same(DrqAuthor, collect(qs), [author]) && length(qs) == 1 && repr(qs) isa String
    @test length(raw(DrqAuthor, "SELECT * FROM drq_author WHERE first_name like 'J%'")) == 2   # test_params_none
    qs = raw(DrqAuthor, "SELECT * FROM drq_author WHERE last_name = ?", ["foo"])          # test_query_representation
    @test repr(qs) == "<RawQuerySet: SELECT * FROM drq_author WHERE last_name = foo>"
    @test same(DrqReviewer, collect(raw(DrqReviewer, "SELECT * FROM drq_reviewer ORDER BY id")), collect(order_by(objects(DrqReviewer), "pk")))   # test_many_to_many
    @test same(DrqAuthor, collect(raw(DrqAuthor, "SELECT * FROM drq_author ORDER BY id"; translations = Dict("something" => "else"))), authors)   # test_extra_conversions
    for a in raw(DrqAuthor, "SELECT id, first_name, dob FROM drq_author")                 # test_missing_fields
        @test a.first_name !== nothing && a.last_name !== nothing                         # (last_name: loaded on access)
    end
    e = try collect(raw(DrqAuthor, "SELECT first_name, dob FROM drq_author")) catch e; e end   # test_missing_fields_without_PK
    @test e isa Juango.FieldDoesNotExist && occursin("Raw query must include the primary key", sprint(showerror, e))
    rs = collect(raw(DrqAuthor, "SELECT a.*, count(b.id) as book_count FROM drq_author a LEFT JOIN drq_book b ON a.id = b.author_id " *   # test_annotations
                                "GROUP BY a.id, a.first_name, a.last_name, a.dob ORDER BY a.id"))
    @test same(DrqAuthor, rs, authors, ((:book_count, 3), (:book_count, 0), (:book_count, 1), (:book_count, 0)))
    @test same(DrqAuthor, collect(raw(DrqAuthor, "    SELECT * FROM drq_author ORDER BY id")), authors)   # test_white_space_query
    ra = raw(DrqAuthor, "SELECT * FROM drq_author ORDER BY id")                          # test_multiple_iterations
    @test [x for x in ra] == authors && [x for x in ra] == authors
    query = "SELECT * FROM drq_author ORDER BY id ASC"                                    # test_get_item
    @test raw(DrqAuthor, query)[3].first_name == "Bob"
    @test length(raw(DrqAuthor, query)[1:2]) == 2
    @test_throws Exception raw(DrqAuthor, query)["test"]
    f = create(DrqFriendlyAuthor; first_name = "Wesley", last_name = "Chun", dob = Date(1962, 10, 28))   # test_inheritance
    @test [o.pk for o in raw(DrqFriendlyAuthor, "SELECT * FROM drq_friendlyauthor")] == [f.pk]
    @test assert_num_queries(() -> collect(raw(DrqAuthor, "SELECT * FROM drq_author")), 1)   # test_query_count
    @test length(collect(raw(DrqBook, "SELECT id FROM (SELECT * FROM drq_book WHERE paperback IS NOT NULL) sq"))) == 4   # test_subquery_in_raw_sql
    b = create(DrqBookFkAsPk; book = b1)                                                  # test_db_column_name_is_used_in_raw_query
    @test collect(raw(DrqBookFkAsPk, "SELECT not_the_default FROM drq_bookfkaspk")) == [b]
    c = create(DrqCoffee; brand = "starbucks", price = 20.5)                              # test_decimal_parameter
    @test collect(raw(DrqCoffee, "SELECT * FROM drq_coffee WHERE price >= ?", [Juango.Decimal(20)])) == [c]
    @test assert_num_queries(1) do                                                        # test_result_caching
        bs = raw(DrqBook, "SELECT * FROM drq_book"); collect(bs); collect(bs)
    end
    @test assert_num_queries(2) do                                                        # test_iterator
        bs = raw(DrqBook, "SELECT * FROM drq_book"); collect(Juango.iterator(bs)); collect(Juango.iterator(bs))
    end
    @test !isempty(raw(DrqBook, "SELECT * FROM drq_book")) && isempty(raw(DrqBook, "SELECT * FROM drq_book WHERE id = 0"))   # test_bool
    @test length(raw(DrqBook, "SELECT * FROM drq_book")) == 4 && length(raw(DrqBook, "SELECT * FROM drq_book WHERE id = 0")) == 0   # test_len
    @test raw(DrqBook, "SELECT * FROM drq_book ORDER BY id")[1] isa DrqBook               # (still a vector of objects)
    # not translated: test_rawqueryset_repr (a RawQuerySet without a model), test_pyformat_params and
    # test_escaped_percent (Python's placeholders), test_pk_with_mixed_case_db_column (#229: a declared id),
    # the fetch mode tests (#230)
  end
end

# --- tests/expressions_case ---------------------------------------------------------------------------
function dcs_setup()
    for (i, i2, s, o2o, fks) in ((1, 1, "1", 1, [1]), (2, 3, "2", 2, [2, 3]), (3, 4, "3", 3, [3, 4]), (2, 2, "2", 2, [2, 3]),
                                 (3, 4, "3", 3, [3, 4]), (3, 3, "3", 3, [3, 4]), (4, 5, "4", 1, [5]))
        o = create(DcsCaseTestModel; integer = i, integer2 = i2, string = s)
        create(DcsO2OCaseTestModel; o2o = o, integer = o2o)
        foreach(n -> create(DcsFKCaseTestModel; fk = o, integer = n), fks)
    end
end
const DCS_GROUP_BY = (:id, :integer, :integer2, :string)      # (Django's group_by_fields: grouped by the id all the same)

@testset "django expressions_case: CaseExpressionTests" begin
  port_block() do
    dcs_setup()
    T = objects(DcsCaseTestModel)
    rows(qs, ks...) = [Tuple(getproperty(o, k) for k in ks) for o in qs]
    drows(qs, ks...) = [Tuple(r[k] for k in ks) for r in qs]
    byp(qs) = order_by(qs, "pk")
    other7(a, b, c) = [(1, a), (2, b), (3, c), (2, b), (3, c), (3, c), (4, c)]
    # test_annotate
    @test rows(byp(annotate(T; test = Case(When(integer = 1, then = Value("one")), When(integer = 2, then = Value("two")); default = Value("other")))), :integer, :test) ==
          other7("one", "two", "other")
    # test_annotate_without_default
    @test rows(byp(annotate(T; test = Case(When(integer = 1, then = 1), When(integer = 2, then = 2)))), :integer, :test) ==
          [(1, 1), (2, 2), (3, nothing), (2, 2), (3, nothing), (3, nothing), (4, nothing)]
    # test_annotate_with_expression_as_value
    @test rows(byp(annotate(T; f_test = Case(When(integer = 1, then = F(:integer) + 1), When(integer = 2, then = F(:integer) + 3); default = F(:integer)))), :integer, :f_test) ==
          [(1, 2), (2, 5), (3, 3), (2, 5), (3, 3), (3, 3), (4, 4)]
    # test_annotate_with_expression_as_condition
    eq_p1 = [(1, "equal"), (2, "+1"), (3, "+1"), (2, "equal"), (3, "+1"), (3, "equal"), (4, "+1")]
    @test rows(byp(annotate(T; f_test = Case(When(integer2 = F(:integer), then = Value("equal")), When(integer2 = F(:integer) + 1, then = Value("+1"))))), :integer, :f_test) == eq_p1
    # test_annotate_with_join_in_value
    @test rows(byp(annotate(T; join_test = Case(When(integer = 1, then = F(:o2o_rel__integer) + 1), When(integer = 2, then = F(:o2o_rel__integer) + 3);
                                                default = F(:o2o_rel__integer)))), :integer, :join_test) == [(1, 2), (2, 5), (3, 3), (2, 5), (3, 3), (3, 3), (4, 1)]
    # test_annotate_with_in_clause
    fk_rels = filter(objects(DcsFKCaseTestModel); integer__in = [5])
    @test rows(byp(annotate(only(T, :pk, :integer); in_test = Sum(Case(When(fk_rel__in = fk_rels, then = F(:fk_rel__integer)); default = Value(0))))), :integer, :in_test) ==
          [(1, 0), (2, 0), (3, 0), (2, 0), (3, 0), (3, 0), (4, 5)]
    # test_annotate_with_join_in_condition
    @test rows(byp(annotate(T; join_test = Case(When(integer2 = F(:o2o_rel__integer), then = Value("equal")), When(integer2 = F(:o2o_rel__integer) + 1, then = Value("+1"));
                                                default = Value("other")))), :integer, :join_test) ==
          [(1, "equal"), (2, "+1"), (3, "+1"), (2, "equal"), (3, "+1"), (3, "equal"), (4, "other")]
    # test_annotate_with_join_in_predicate
    @test rows(byp(annotate(T; join_test = Case(When(o2o_rel__integer = 1, then = Value("one")), When(o2o_rel__integer = 2, then = Value("two")),
                                                When(o2o_rel__integer = 3, then = Value("three")); default = Value("other")))), :integer, :join_test) ==
          [(1, "one"), (2, "two"), (3, "three"), (2, "two"), (3, "three"), (3, "three"), (4, "one")]
    # test_annotate_with_annotation_in_value
    @test rows(byp(annotate(annotate(T; f_plus_1 = F(:integer) + 1, f_plus_3 = F(:integer) + 3);
                            f_test = Case(When(integer = 1, then = F(:f_plus_1)), When(integer = 2, then = F(:f_plus_3)); default = F(:integer)))), :integer, :f_test) ==
          [(1, 2), (2, 5), (3, 3), (2, 5), (3, 3), (3, 3), (4, 4)]
    # test_annotate_with_annotation_in_condition
    @test rows(byp(annotate(annotate(T; f_plus_1 = F(:integer) + 1);
                            f_test = Case(When(integer2 = F(:integer), then = Value("equal")), When(integer2 = F(:f_plus_1), then = Value("+1"))))), :integer, :f_test) == eq_p1
    # test_annotate_with_annotation_in_predicate
    @test rows(byp(annotate(annotate(T; f_minus_2 = F(:integer) - 2);
                            test = Case(When(f_minus_2 = -1, then = Value("negative one")), When(f_minus_2 = 0, then = Value("zero")),
                                        When(f_minus_2 = 1, then = Value("one")); default = Value("other")))), :integer, :test) ==
          [(1, "negative one"), (2, "zero"), (3, "one"), (2, "zero"), (3, "one"), (3, "one"), (4, "other")]
    # test_annotate_with_aggregation_in_value
    mm = annotate(values(T, DCS_GROUP_BY...); min = Min(:fk_rel__integer), max = Max(:fk_rel__integer))
    @test drows(byp(annotate(mm; test = Case(When(integer = 2, then = F(:min)), When(integer = 3, then = F(:max))))), :integer, :test, :min, :max) ==
          [(1, nothing, 1, 1), (2, 2, 2, 3), (3, 4, 3, 4), (2, 2, 2, 3), (3, 4, 3, 4), (3, 4, 3, 4), (4, nothing, 5, 5)]
    # test_annotate_with_aggregation_in_condition
    @test drows(byp(annotate(mm; test = Case(When(integer2 = F(:min), then = Value("min")), When(integer2 = F(:max), then = Value("max"))))), :integer, :integer2, :test) ==
          [(1, 1, "min"), (2, 3, "max"), (3, 4, "max"), (2, 2, "min"), (3, 4, "max"), (3, 3, "min"), (4, 5, "min")]
    # test_annotate_with_aggregation_in_predicate
    mx = annotate(values(T, DCS_GROUP_BY...); max = Max(:fk_rel__integer))
    @test drows(byp(annotate(mx; test = Case(When(max = 3, then = Value("max = 3")), When(max = 4, then = Value("max = 4")); default = Value("")))), :integer, :max, :test) ==
          [(1, 1, ""), (2, 3, "max = 3"), (3, 4, "max = 4"), (2, 3, "max = 3"), (3, 4, "max = 4"), (3, 4, "max = 4"), (4, 5, "")]
    # test_annotate_exclude
    @test rows(byp(exclude(annotate(T; test = Case(When(integer = 1, then = Value("one")), When(integer = 2, then = Value("two")); default = Value("other"))); test = "other")),
               :integer, :test) == [(1, "one"), (2, "two"), (2, "two")]
    # test_annotate_filter_decimal
    obj = create(DcsCaseTestModel; integer = 0, decimal = Juango.Decimal("1"))
    qs = annotate(T; x = Case(When(integer = 0, then = F(:decimal))), y = Case(When(integer = 0, then = Value(Juango.Decimal("1")))))
    @test collect(filter(qs, Q(x = 1) & Q(x = Juango.Decimal("1")))) == [obj]
    @test collect(filter(qs, Q(y = 1) & Q(y = Juango.Decimal("1")))) == [obj]
    delete!(obj)
    # test_annotate_values_not_in_order_by
    @test collect(values_list(order_by(annotate(T; test = Case(When(integer = 1, then = Value("one")), When(integer = 2, then = Value("two")),
                                                               When(integer = 3, then = Value("three")); default = Value("other"))), "test"), :integer; flat = true)) ==
          [1, 4, 3, 3, 3, 2, 2]
    # test_annotate_with_empty_when / test_annotate_with_full_when
    objs = collect(annotate(T; selected = Case(When(pk__in = Int[], then = Value("selected")); default = Value("not selected"))))
    @test length(objs) == count(T) && all(o -> o.selected == "not selected", objs)
    objs = collect(annotate(T; selected = Case(When(~Q(pk__in = Int[]), then = Value("selected")); default = Value("not selected"))))
    @test length(objs) == count(T) && all(o -> o.selected == "selected", objs)
    # test_combined_expression
    @test rows(byp(annotate(T; test = Case(When(integer = 1, then = 2), When(integer = 2, then = 1); default = 3) + 1)), :integer, :test) ==
          [(1, 3), (2, 2), (3, 4), (2, 2), (3, 4), (3, 4), (4, 4)]
    # test_in_subquery
    @test rows(byp(filter(T; pk__in = values(annotate(T; test = Case(When(integer = F(:integer2), then = F(:pk)), When(integer = 4, then = F(:pk)))), :test))), :integer, :integer2) ==
          [(1, 1), (2, 2), (3, 3), (4, 5)]
    # test_condition_with_lookups
    qs = annotate(T; test = Case(When(Q(integer2 = 1); string = "2", then = Value(false)), When(Q(integer2 = 1); string = "1", then = Value(true));
                                 default = Value(false), output_field = BooleanField()))
    @test get(qs; integer = 1).test === true
    # test_case_reuse
    some_case = Case(When(pk = 0, then = Value("0")); default = Value("1"))
    @test [(o.pk, o.somecase) for o in byp(annotate(T; somecase = some_case))] == collect(values_list(byp(annotate(T; somecase = some_case)), :pk, :somecase))
    # test_aggregate
    @test aggregate(T; one = Sum(Case(When(integer = 1, then = 1))), two = Sum(Case(When(integer = 2, then = 1))),
                    three = Sum(Case(When(integer = 3, then = 1))), four = Sum(Case(When(integer = 4, then = 1)))) == Dict(:one => 1, :two => 2, :three => 3, :four => 1)
    # test_aggregate_with_expression_as_value
    @test aggregate(T; one = Sum(Case(When(integer = 1, then = F(:integer)))), two = Sum(Case(When(integer = 2, then = F(:integer) - 1))),
                    three = Sum(Case(When(integer = 3, then = F(:integer) + 1)))) == Dict(:one => 1, :two => 2, :three => 12)
    # test_aggregate_with_expression_as_condition
    @test aggregate(T; equal = Sum(Case(When(integer2 = F(:integer), then = 1))), plus_one = Sum(Case(When(integer2 = F(:integer) + 1, then = 1)))) ==
          Dict(:equal => 3, :plus_one => 4)
    # test_filter
    @test rows(byp(filter(T; integer2 = Case(When(integer = 2, then = 3), When(integer = 3, then = 4); default = 1))), :integer, :integer2) == [(1, 1), (2, 3), (3, 4), (3, 4)]
    # test_filter_without_default
    @test rows(byp(filter(T; integer2 = Case(When(integer = 2, then = 3), When(integer = 3, then = 4)))), :integer, :integer2) == [(2, 3), (3, 4), (3, 4)]
    # test_filter_with_expression_as_value
    @test rows(byp(filter(T; integer2 = Case(When(integer = 2, then = F(:integer) + 1), When(integer = 3, then = F(:integer)); default = F(:integer)))), :integer, :integer2) ==
          [(1, 1), (2, 3), (3, 3)]
    # test_filter_with_expression_as_condition
    @test rows(byp(filter(T; string = Case(When(integer2 = F(:integer), then = Value("2")), When(integer2 = F(:integer) + 1, then = Value("3"))))), :integer, :integer2, :string) ==
          [(3, 4, "3"), (2, 2, "2"), (3, 4, "3")]
    # test_filter_with_join_in_value
    @test rows(byp(filter(T; integer2 = Case(When(integer = 2, then = F(:o2o_rel__integer) + 1), When(integer = 3, then = F(:o2o_rel__integer));
                                             default = F(:o2o_rel__integer)))), :integer, :integer2) == [(1, 1), (2, 3), (3, 3)]
    # test_filter_with_join_in_condition
    @test rows(byp(filter(T; integer = Case(When(integer2 = F(:o2o_rel__integer) + 1, then = 2), When(integer2 = F(:o2o_rel__integer), then = 3)))), :integer, :integer2) ==
          [(2, 3), (3, 3)]
    # test_filter_with_join_in_predicate
    @test rows(byp(filter(T; integer2 = Case(When(o2o_rel__integer = 1, then = 1), When(o2o_rel__integer = 2, then = 3), When(o2o_rel__integer = 3, then = 4)))),
               :integer, :integer2) == [(1, 1), (2, 3), (3, 4), (3, 4)]
    # test_filter_with_annotation_in_value
    @test rows(byp(filter(annotate(T; f = F(:integer), f_plus_1 = F(:integer) + 1); integer2 = Case(When(integer = 2, then = F(:f_plus_1)), When(integer = 3, then = F(:f))))),
               :integer, :integer2) == [(2, 3), (3, 3)]
    # test_filter_with_annotation_in_condition
    @test rows(byp(filter(annotate(T; f_plus_1 = F(:integer) + 1); integer = Case(When(integer2 = F(:integer), then = 2), When(integer2 = F(:f_plus_1), then = 3)))),
               :integer, :integer2) == [(3, 4), (2, 2), (3, 4)]
    # test_filter_with_annotation_in_predicate
    @test rows(byp(filter(annotate(T; f_plus_1 = F(:integer) + 1); integer2 = Case(When(f_plus_1 = 3, then = 3), When(f_plus_1 = 4, then = 4); default = 1))),
               :integer, :integer2) == [(1, 1), (2, 3), (3, 4), (3, 4)]
    # test_filter_with_aggregation_in_value
    @test drows(byp(filter(mm; integer2 = Case(When(integer = 2, then = F(:min)), When(integer = 3, then = F(:max))))), :integer, :integer2, :min, :max) ==
          [(3, 4, 3, 4), (2, 2, 2, 3), (3, 4, 3, 4)]
    # test_filter_with_aggregation_in_condition
    @test drows(byp(filter(mm; integer = Case(When(integer2 = F(:min), then = 2), When(integer2 = F(:max), then = 3)))), :integer, :integer2, :min, :max) ==
          [(3, 4, 3, 4), (2, 2, 2, 3), (3, 4, 3, 4)]
    # test_filter_with_aggregation_in_predicate
    @test drows(byp(filter(mx; integer = Case(When(max = 3, then = 2), When(max = 4, then = 3)))), :integer, :integer2, :max) ==
          [(2, 3, 3), (3, 4, 4), (2, 2, 3), (3, 4, 4), (3, 3, 4)]
    # test_lookup_in_condition
    @test rows(byp(annotate(T; test = Case(When(integer__lt = 2, then = Value("less than 2")), When(integer__gt = 2, then = Value("greater than 2"));
                                           default = Value("equal to 2")))), :integer, :test) ==
          [(1, "less than 2"), (2, "equal to 2"), (3, "greater than 2"), (2, "equal to 2"), (3, "greater than 2"), (3, "greater than 2"), (4, "greater than 2")]
    # test_lookup_different_fields
    when7 = [(1, 1, "default"), (2, 3, "when"), (3, 4, "default"), (2, 2, "default"), (3, 4, "default"), (3, 3, "default"), (4, 5, "default")]
    @test rows(byp(annotate(T; test = Case(When(integer = 2, integer2 = 3, then = Value("when")); default = Value("default")))), :integer, :integer2, :test) == when7
    # test_combined_q_object
    @test rows(byp(annotate(T; test = Case(When(Q(integer = 2) | Q(integer2 = 3), then = Value("when")); default = Value("default")))), :integer, :integer2, :test) ==
          [(1, 1, "default"), (2, 3, "when"), (3, 4, "default"), (2, 2, "when"), (3, 4, "default"), (3, 3, "when"), (4, 5, "default")]
    # test_order_by_conditional_implicit / test_order_by_conditional_explicit
    lte2 = annotate(filter(T; integer__lte = 2); test = Case(When(integer = 1, then = 2), When(integer = 2, then = 1); default = 3))
    @test rows(order_by(lte2, "test", "pk"), :integer, :test) == [(2, 1), (2, 1), (1, 2)]
    @test rows(order_by(lte2, Asc(F(:test)), "pk"), :integer, :test) == [(2, 1), (2, 1), (1, 2)]
    # test_join_promotion
    o = create(DcsCaseTestModel; integer = 1, integer2 = 1, string = "1")
    @test [(x, x.foo) for x in annotate(filter(T; pk = o.pk); foo = Case(When(fk_rel__pk = 1, then = 2); default = 3))] == [(o, 3)]
    @test [(x, x.foo) for x in annotate(filter(T; pk = o.pk); foo = Case(When(fk_rel__isnull = true, then = 2); default = 3))] == [(o, 2)]
    # test_join_promotion_multiple_annotations
    @test [(x, x.foo, x.bar) for x in annotate(filter(T; pk = o.pk); foo = Case(When(fk_rel__pk = 1, then = 2); default = 3),
                                                                      bar = Case(When(fk_rel__pk = 1, then = 4); default = 5))] == [(o, 3, 5)]
    @test [(x, x.foo, x.bar) for x in annotate(filter(T; pk = o.pk); foo = Case(When(fk_rel__isnull = true, then = 2); default = 3),
                                                                      bar = Case(When(fk_rel__isnull = true, then = 4); default = 5))] == [(o, 2, 4)]
    delete!(o)
    # test_m2m_exclude / test_m2m_reuse
    create(DcsCaseTestModel; integer = 10, integer2 = 1, string = "1")
    qs = order_by(annotate(values_list(T, :id, :integer); cnt = Sum(Case(When(~Q(fk_rel__integer = 1), then = 1); default = 2))), "integer")
    @test [Tuple(r[2:end]) for r in qs] == [(1, 2), (2, 2), (2, 2), (3, 2), (3, 2), (3, 2), (4, 1), (10, 1)]
    qs = order_by(annotate(annotate(values_list(T, :id, :integer); cnt = Sum(Case(When(~Q(fk_rel__integer = 1), then = 1); default = 2)));
                           cnt2 = Sum(Case(When(~Q(fk_rel__integer = 1), then = 1); default = 2))), "integer")
    @test count("JOIN", first(Juango.select_sql(qs))) == 1
    @test [Tuple(r[2:end]) for r in qs] == [(1, 2, 2), (2, 2, 2), (2, 2, 2), (3, 2, 2), (3, 2, 2), (3, 2, 2), (4, 1, 1), (10, 1, 1)]
    delete!(filter(T; integer = 10))
    # test_aggregation_empty_cases
    for (case, value) in ((Case(; output_field = IntegerField()), nothing), (Case(; default = Value("empty")), "empty"), (Case(; default = F(:url)), ""))
        @test drows(order_by(annotate(values(T, :string); case = case, integer_sum = Sum(:integer)), "string"), :string, :case, :integer_sum) ==
              [("1", value, 1), ("2", value, 4), ("3", value, 9), ("4", value, 4)]
    end
  end
end

@testset "django expressions_case: updates" begin
    T = objects(DcsCaseTestModel)
    upd(field, whens...; default = nothing) = (update!(T; (field => Case(whens...; default = default),)...);
                                               [(o.integer, getproperty(o, field)) for o in order_by(T, "pk")])
    seven(a, b, c) = [(1, a), (2, b), (3, c), (2, b), (3, c), (3, c), (4, c)]
    W(v1, v2) = (When(integer = 1, then = v1), When(integer = 2, then = v2))
    cases = [(:string, W(Value("one"), Value("two")), Value("other"), seven("one", "two", "other")),            # test_update
             (:integer2, W(1, 2), nothing, seven(1, 2, nothing)),                                             # test_update_without_default
             (:big_integer, W(1, 2), nothing, seven(1, 2, nothing)),                                          # test_update_big_integer
             (:boolean, W(true, true), false, seven(true, true, false)),                                      # test_update_boolean
             (:date, W(Date(2015, 1, 1), Date(2015, 1, 2)), nothing, seven(Date(2015, 1, 1), Date(2015, 1, 2), nothing)),   # test_update_date
             (:date_time, W(DateTime(2015, 1, 1), DateTime(2015, 1, 2)), nothing, seven(DateTime(2015, 1, 1), DateTime(2015, 1, 2), nothing)),   # test_update_date_time
             (:decimal, W(Juango.Decimal("1.1"), Value(Juango.Decimal("2.2"))), nothing, seven(Juango.Decimal("1.1"), Juango.Decimal("2.2"), nothing)),   # test_update_decimal
             (:duration, W(Day(1), Day(2)), nothing, seven(Day(1), Day(2), nothing)),                          # test_update_duration
             (:email, W(Value("1@example.com"), Value("2@example.com")), Value(""), seven("1@example.com", "2@example.com", "")),   # test_update_email
             (:file_path, W(Value("~/1"), Value("~/2")), Value(""), seven("~/1", "~/2", "")),                  # test_update_file_path
             (:float, W(1.1, 2.2), nothing, seven(1.1, 2.2, nothing)),                                        # test_update_float
             (:null_boolean, W(true, false), nothing, seven(true, false, nothing)),                           # test_update_null_boolean
             (:positive_big_integer, W(1, 2), nothing, seven(1, 2, nothing)),                                 # test_update_positive_big_integer
             (:positive_integer, W(1, 2), nothing, seven(1, 2, nothing)),                                     # test_update_positive_integer
             (:positive_small_integer, W(1, 2), nothing, seven(1, 2, nothing)),                               # test_update_positive_small_integer
             (:slug, W(Value("1"), Value("2")), Value(""), seven("1", "2", "")),                              # test_update_slug
             (:small_integer, W(1, 2), nothing, seven(1, 2, nothing)),                                        # test_update_small_integer
             (:text, W(Value("1"), Value("2")), Value(""), seven("1", "2", "")),                              # test_update_text
             (:time, W(Time(1), Time(2)), nothing, seven(Time(1), Time(2), nothing)),                         # test_update_time
             (:url, W(Value("http://1.example.com/"), Value("http://2.example.com/")), Value(""), seven("http://1.example.com/", "http://2.example.com/", "")),   # test_update_url
             (:uuid, W(UUID("11111111-1111-1111-1111-111111111111"), UUID("22222222-2222-2222-2222-222222222222")), nothing,
              seven(UUID("11111111-1111-1111-1111-111111111111"), UUID("22222222-2222-2222-2222-222222222222"), nothing))]   # test_update_uuid
    for (field, whens, default, expected) in cases
        port_block() do
            dcs_setup()
            @test upd(field, whens...; default = default) == expected
        end
    end
    port_block() do
        dcs_setup()
        # test_update_binary
        update!(T; binary = Case(W(Vector{UInt8}("one"), Vector{UInt8}("two"))...; default = UInt8[]))
        @test [(o.integer, Vector{UInt8}(o.binary)) for o in order_by(T, "pk")] == seven(Vector{UInt8}("one"), Vector{UInt8}("two"), UInt8[])
        # test_update_file
        update!(T; file = Case(W(Value("~/1"), Value("~/2"))...))
        @test [(o.integer, o.file === nothing ? "" : string(o.file)) for o in order_by(T, "pk")] == seven("~/1", "~/2", "")
        # test_update_generic_ip_address
        update!(T; generic_ip_address = Case(W(Value("1.1.1.1"), Value("2.2.2.2"))...; output_field = GenericIPAddressField()))
        @test [(o.integer, o.generic_ip_address) for o in order_by(T, "pk")] == seven("1.1.1.1", "2.2.2.2", nothing)
        # test_update_with_expression_as_value
        update!(T; integer = Case(When(integer = 1, then = F(:integer) + 1), When(integer = 2, then = F(:integer) + 3); default = F(:integer)))
        @test [(o.string, o.integer) for o in order_by(T, "pk")] == [("1", 2), ("2", 5), ("3", 3), ("2", 5), ("3", 3), ("3", 3), ("4", 4)]
    end
    port_block() do
        dcs_setup()
        # test_update_with_expression_as_condition
        update!(T; string = Case(When(integer2 = F(:integer), then = Value("equal")), When(integer2 = F(:integer) + 1, then = Value("+1"))))
        @test [(o.integer, o.string) for o in order_by(T, "pk")] == [(1, "equal"), (2, "+1"), (3, "+1"), (2, "equal"), (3, "+1"), (3, "equal"), (4, "+1")]
        # test_update_with_join_in_condition_raise_field_error / test_update_with_join_in_predicate_raise_field_error
        e = try update!(T; integer = Case(When(integer2 = F(:o2o_rel__integer) + 1, then = 2), When(integer2 = F(:o2o_rel__integer), then = 3))) catch e; e end
        @test e isa Exception && occursin("Joined field references are not permitted in this query", sprint(showerror, e))
        e = try update!(T; string = Case(When(o2o_rel__integer = 1, then = Value("one")), When(o2o_rel__integer = 2, then = Value("two")); default = Value("other"))) catch e; e end
        @test e isa Exception && occursin("Joined field references are not permitted in this query", sprint(showerror, e))
        # test_update_fk
        obj1, obj2 = collect(order_by(T, "pk"))[1:2]
        update!(T; fk = Case(When(integer = 1, then = obj1.pk), When(integer = 2, then = obj2.pk)))
        @test [(o.integer, o.fk_id) for o in order_by(T, "pk")] == seven(obj1.pk, obj2.pk, nothing)
    end
end

@testset "django expressions_case: CaseDocumentationExamples" begin
  port_block() do
    td = today()
    create(DcsClient; name = "Jane Doe", account_type = "R", registered_on = td - Day(36))
    create(DcsClient; name = "James Smith", account_type = "G", registered_on = td - Day(5))
    create(DcsClient; name = "Jack Black", account_type = "P", registered_on = td - Day(10 * 365))
    C = objects(DcsClient)
    na(qs, k) = [(c.name, getproperty(c, k)) for c in order_by(qs, "pk")]
    # test_simple_example
    @test na(annotate(C; discount = Case(When(account_type = "G", then = Value("5%")), When(account_type = "P", then = Value("10%")); default = Value("0%"))), :discount) ==
          [("Jane Doe", "0%"), ("James Smith", "5%"), ("Jack Black", "10%")]
    # test_lookup_example
    a_month_ago, a_year_ago = td - Day(30), td - Day(365)
    @test na(annotate(C; discount = Case(When(registered_on__lte = a_year_ago, then = Value("10%")), When(registered_on__lte = a_month_ago, then = Value("5%"));
                                         default = Value("0%"))), :discount) == [("Jane Doe", "5%"), ("James Smith", "0%"), ("Jack Black", "10%")]
    # test_filter_example
    @test [(c.name, c.account_type) for c in filter(C; registered_on__lte = Case(When(account_type = "G", then = a_month_ago), When(account_type = "P", then = a_year_ago)))] ==
          [("Jack Black", "P")]
    # test_conditional_update_example
    update!(C; account_type = Case(When(registered_on__lte = a_year_ago, then = Value("P")), When(registered_on__lte = a_month_ago, then = Value("G")); default = Value("R")))
    @test na(C, :account_type) == [("Jane Doe", "G"), ("James Smith", "R"), ("Jack Black", "P")]
    # test_conditional_aggregation_example
    update!(C; account_type = Case(When(name = "Jane Doe", then = Value("R")), When(name = "James Smith", then = Value("G")); default = Value("P")))
    create(DcsClient; name = "Jean Grey", account_type = "R", registered_on = td)
    create(DcsClient; name = "James Bond", account_type = "P", registered_on = td)
    create(DcsClient; name = "Jane Porter", account_type = "P", registered_on = td)
    @test aggregate(C; regular = Count(:pk; filter = Q(account_type = "R")), gold = Count(:pk; filter = Q(account_type = "G")),
                    platinum = Count(:pk; filter = Q(account_type = "P"))) == Dict(:regular => 2, :gold => 1, :platinum => 3)
    @test aggregate(C; regular = Sum(Case(When(account_type = "R", then = 1))), gold = Sum(Case(When(account_type = "G", then = 1))),
                    platinum = Sum(Case(When(account_type = "P", then = 1)))) == Dict(:regular => 2, :gold => 1, :platinum => 3)
    # test_hash
    e1 = Case(When(account_type__in = ["R", "G"], then = 1); default = 2, output_field = IntegerField())
    e2 = Case(When(account_type__in = ("R", "G"), then = 1); default = 2, output_field = IntegerField())
    e3 = Case(When(account_type__in = ["R", "G"], then = 1); default = 3)
    e4 = Case(When(account_type__in = ["P", "G"], then = 2); default = 1)
    @test hash(e1) == hash(e2) && hash(e2) != hash(e3) && hash(e1) != hash(e4) && hash(e3) != hash(e4)
  end
end

@testset "django expressions_case: CaseWhenTests" begin
    msg(f) = try f(); "" catch e; e isa ArgumentError ? e.msg : sprint(showerror, e) end
    @test msg(() -> Case(When(Q(pk__in = Int[])), "x")) == "Positional arguments must all be When objects."   # test_only_when_arguments
    w = "When() supports a Q object, a boolean expression, or lookups as a condition."           # test_invalid_when_constructor_args
    @test msg(() -> When(; condition = "x")) == w && msg(() -> When(; condition = Value(1))) == w
    @test msg(() -> When(Value(1); string = "1")) == w && msg(() -> When()) == w
    @test msg(() -> When(; _negated = true, _connector = "evil")) == "The following kwargs are invalid: '_connector', '_negated'"   # test_when_rejects_invalid_arguments
    @test msg(() -> When(Q(); then = Value(true))) == "An empty Q() can't be used as a When() condition."   # test_empty_q_object
end
