# More of Django's ORM tests, ported (#227): tests/or_lookups, dates, datetimes, raw_query, expressions_case,
# transaction_hooks, known_related_objects, field_defaults, m2m_signals, from_db_value, order_with_respect_to,
# custom_lookups.
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
# --- tests/transaction_hooks, known_related_objects, field_defaults, m2m_signals models ----------------
@model struct DthThing
    num = IntegerField()
    Meta(table = "dth_thing")
end
@model struct DkrTournament
    name = CharField(max_length = 30)
    Meta(table = "dkr_tournament")
end
@model struct DkrOrganiser
    name = CharField(max_length = 30)
    Meta(table = "dkr_organiser")
end
@model struct DkrPool
    name = CharField(max_length = 30)
    tournament = ForeignKey(DkrTournament; on_delete = :CASCADE)
    organiser = ForeignKey(DkrOrganiser; on_delete = :CASCADE)
    Meta(table = "dkr_pool")
end
@model struct DkrPoolStyle
    name = CharField(max_length = 30)
    pool = OneToOneField(DkrPool; on_delete = :CASCADE)
    another_pool = OneToOneField(DkrPool; on_delete = :CASCADE, null = true, related_name = :another_style)
    Meta(table = "dkr_poolstyle")
end
@model struct DfdArticle
    headline = CharField(max_length = 100, default = "Default headline")
    pub_date = DateTimeField(default = now)
    Meta(table = "dfd_article")
end
@model struct DfdDBArticle
    headline = CharField(max_length = 100, db_default = "Default headline")
    pub_date = DateTimeField(db_default = Now())
    cost = DecimalField(max_digits = 3, decimal_places = 2, db_default = Juango.Decimal("3.33"))
    Meta(table = "dfd_dbarticle")
end
@model struct DfdDBDefaults
    both = IntegerField(default = 1, db_default = 2)
    null = FloatField(null = true, db_default = 1.1)
    Meta(table = "dfd_dbdefaults")
end
@model struct DfdDBDefaultsPK
    language_code = CharField(primary_key = true, max_length = 2, db_default = "en")
    Meta(table = "dfd_dbdefaultspk")
end
@model struct DfdDBDefaultsFK
    language_code = ForeignKey(DfdDBDefaultsPK; db_default = "fr", on_delete = :CASCADE)
    Meta(table = "dfd_dbdefaultsfk")
end
@model struct DfdDBDefaultsOneToOnePK
    language_code = OneToOneField(DfdDBDefaultsPK; primary_key = true, default = "tr", db_default = "kr", on_delete = :CASCADE)
    Meta(table = "dfd_dbdefaultsonetoonepk")
end
@model struct DmsPart
    name = CharField(max_length = 20)
    Meta(table = "dms_part", ordering = ["name"])
end
@model struct DmsCar
    name = CharField(max_length = 20)
    default_parts = ManyToManyField(DmsPart)
    optional_parts = ManyToManyField(DmsPart; related_name = :cars_optional)
    Meta(table = "dms_car", ordering = ["name"])
end
@model struct DmsSportsCar <: DmsCar
    price = IntegerField()
    Meta(table = "dms_sportscar")
end
@model struct DmsPerson
    name = CharField(max_length = 20)
    fans = ManyToManyField(:self; related_name = :idols, symmetrical = false)
    friends = ManyToManyField(:self)
    Meta(table = "dms_person", ordering = ["name"])
end
# --- tests/from_db_value/models.py: Cash(Decimal) with a vendor, from CashField's from_db_value --------------
struct DfvCash
    value::Juango.Decimal
    vendor::String
end
DfvCashField(; kw...) = DecimalField(; max_digits = 20, decimal_places = 2,
                                     from_db_value = v -> v === nothing ? nothing : DfvCash(v, Juango.vendor(Juango.backend())),
                                     get_prep_value = v -> v isa DfvCash ? v.value : v, kw...)
@model struct DfvCashModel
    cash = DfvCashField()
    Meta(table = "dfv_cashmodel")
end
# --- tests/order_with_respect_to/models.py --------------------------------------------------------------
@model struct DowQuestion
    text = CharField(max_length = 200)
    Meta(table = "dow_question")
end
@model struct DowAnswer
    text = CharField(max_length = 200)
    question = ForeignKey(DowQuestion; on_delete = :CASCADE)
    Meta(table = "dow_answer", order_with_respect_to = :question)
end
@model struct DowPost
    title = CharField(max_length = 200)
    parent = ForeignKey(:self; on_delete = :SET_NULL, related_name = :children, null = true)
    Meta(table = "dow_post", order_with_respect_to = :parent)
end
@model struct DowEntity
    Meta(table = "dow_entity")
end
@model struct DowDimension
    entity = OneToOneField(DowEntity; primary_key = true, on_delete = :CASCADE)
    Meta(table = "dow_dimension")
end
@model struct DowComponent
    dimension = ForeignKey(DowDimension; on_delete = :CASCADE)
    Meta(table = "dow_component", order_with_respect_to = :dimension)
end
# --- tests/custom_lookups/models.py ---------------------------------------------------------------------
@model struct DclAuthor
    name = CharField(max_length = 20)
    alias = CharField(max_length = 20)
    age = IntegerField(null = true)
    birthdate = DateField(null = true)
    average_rating = FloatField(null = true)
    Meta(table = "dcl_author")
end
redirect_stdout(devnull) do
    ms = [DolArticle, DdtArticle, DdtComment, DdtCategory, through(DdtCategory, :articles),
          DdsArticle, DdsComment, DdsCategory, through(DdsCategory, :articles),
          DrqAuthor, DrqBook, DrqBookFkAsPk, DrqCoffee, DrqReviewer, through(DrqReviewer, :reviewed), DrqFriendlyAuthor,
          DcsCaseTestModel, DcsO2OCaseTestModel, DcsFKCaseTestModel, DcsClient,
          DthThing, DkrTournament, DkrOrganiser, DkrPool, DkrPoolStyle, DfdArticle, DfdDBArticle, DfdDBDefaults, DfdDBDefaultsPK,
          DfdDBDefaultsFK, DfdDBDefaultsOneToOnePK, DmsPart, DmsCar, through(DmsCar, :default_parts), through(DmsCar, :optional_parts),
          DmsSportsCar, DmsPerson, through(DmsPerson, :fans), through(DmsPerson, :friends), DfvCashModel,
          DowQuestion, DowAnswer, DowPost, DowEntity, DowDimension, DowComponent, DclAuthor]
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

# --- tests/transaction_hooks --------------------------------------------------------------------------
struct DthForcedError <: Exception end
@testset "django transaction_hooks: TestConnectionOnCommit" begin
    notified = Int[]
    notify(n) = n == -1 ? throw(DthForcedError()) : push!(notified, n)
    function run(f)                                                  # (setUp, and the table emptied after)
        empty!(notified)
        port_block(f)
    end
    dth_do(n) = (create(DthThing; num = n); on_commit(() -> notify(n)))
    done(nums) = notified == nums && sort([t.num for t in objects(DthThing)]) == sort(nums)
    forced(f) = try f() catch e; e isa DthForcedError || rethrow() end
    logged(f) = (mem = MemoryHandler();
                 override_settings(f; LOGGING = Dict("handlers" => Dict("mem" => Dict("class" => mem)),
                                                     "loggers" => Dict("juango.db.backends" => Dict("handlers" => ["mem"], "level" => "ERROR", "propagate" => false))));
                 mem.records)
    robust_callback() = throw(ArgumentError("robust callback"))
    run() do                                                         # test_executes_immediately_if_no_transaction
        dth_do(1); @test done([1])
    end
    run() do                                                         # test_robust_if_no_transaction
        recs = logged(() -> (on_commit(robust_callback; robust = true); dth_do(1)))
        @test done([1]) && length(recs) == 1
        @test startswith(recs[1].message, "Error calling $(robust_callback) in on_commit() (robust callback).") && recs[1].exception[1] isa ArgumentError
    end
    run() do                                                         # test_robust_transaction
        recs = logged(() -> atomic(() -> (on_commit(robust_callback; robust = true); dth_do(1))))
        @test done([1]) && length(recs) == 1
        @test startswith(recs[1].message, "Error calling $(robust_callback) in on_commit() during transaction (robust callback).")
        @test recs[1].exception[1] isa ArgumentError && recs[1].exception[1].msg == "robust callback"
    end
    run() do                                                         # test_delays_execution_until_after_transaction_commit
        atomic() do
            dth_do(1); @test isempty(notified)
        end
        @test done([1])
    end
    run() do                                                         # test_does_not_execute_if_transaction_rolled_back
        forced(() -> atomic(() -> (dth_do(1); throw(DthForcedError()))))
        @test done(Int[])
    end
    run() do                                                         # test_executes_only_after_final_transaction_committed
        atomic() do
            atomic(() -> (dth_do(1); @test isempty(notified)))
            @test isempty(notified)
        end
        @test done([1])
    end
    run() do                                                         # test_discards_hooks_from_rolled_back_savepoint
        atomic() do
            atomic(() -> dth_do(1))
            forced(() -> atomic(() -> (dth_do(2); throw(DthForcedError()))))
            atomic(() -> dth_do(3))
        end
        @test done([1, 3])
    end
    run() do                                                         # test_no_hooks_run_from_failed_transaction
        forced(() -> atomic(() -> (atomic(() -> dth_do(1)); throw(DthForcedError()))))
        @test done(Int[])
    end
    run() do                                                         # test_inner_savepoint_rolled_back_with_outer
        atomic() do
            forced(() -> atomic(() -> (atomic(() -> dth_do(1)); throw(DthForcedError()))))
            dth_do(2)
        end
        @test done([2])
    end
    run() do                                                         # test_no_savepoints_atomic_merged_with_outer
        forced(() -> atomic(() -> atomic(() -> (dth_do(1); forced(() -> atomic(() -> throw(DthForcedError()); savepoint = false))))))
        @test done(Int[])
    end
    run() do                                                         # test_inner_savepoint_does_not_affect_outer
        atomic(() -> atomic(() -> (dth_do(1); forced(() -> atomic(() -> throw(DthForcedError()))))))
        @test done([1])
    end
    run() do                                                         # test_runs_hooks_in_order_registered
        atomic(() -> (dth_do(1); atomic(() -> dth_do(2)); dth_do(3)))
        @test done([1, 2, 3])
    end
    run() do                                                         # test_hooks_cleared_after_successful_commit
        atomic(() -> dth_do(1)); atomic(() -> dth_do(2))
        @test done([1, 2])
    end
    run() do                                                         # test_hooks_cleared_after_rollback
        forced(() -> atomic(() -> (dth_do(1); throw(DthForcedError()))))
        atomic(() -> dth_do(2))
        @test done([2])
    end
    run() do                                                         # test_error_in_hook_doesnt_prevent_clearing_hooks
        forced(() -> atomic(() -> on_commit(() -> notify(-1))))
        atomic(() -> dth_do(1))
        @test done([1])
    end
    run() do                                                         # test_db_query_in_hook
        atomic(() -> (create(DthThing; num = 1); on_commit(() -> foreach(t -> notify(t.num), collect(objects(DthThing))))))
        @test done([1])
    end
    run() do                                                         # test_transaction_in_hook
        atomic(() -> on_commit(() -> atomic(() -> notify(create(DthThing; num = 1).num))))
        @test done([1])
    end
    run() do                                                         # test_hook_in_hook
        function hook(i, add_hook)
            atomic() do
                add_hook && on_commit(() -> hook(i + 10, false))
                notify(create(DthThing; num = i).num)
            end
        end
        atomic(() -> (on_commit(() -> hook(1, true)); on_commit(() -> hook(2, true))))
        @test done([1, 11, 2, 12])
    end
    e = try on_commit(nothing) catch e; e end                        # test_raises_exception_non_callable
    @test e isa ArgumentError && e.msg == "on_commit()'s callback must be a callable."
    # not translated: test_raises_exception_non_autocommit_mode (manual transactions: #231), test_hooks_cleared_on_reconnect
end

# --- tests/known_related_objects ----------------------------------------------------------------------
@testset "django known_related_objects: ExistingRelatedInstancesTests" begin
  port_block() do
    t1 = create(DkrTournament; name = "Tourney 1"); t2 = create(DkrTournament; name = "Tourney 2")
    o1 = create(DkrOrganiser; name = "Organiser 1")
    p1 = create(DkrPool; name = "T1 Pool 1", tournament = t1, organiser = o1)
    p2 = create(DkrPool; name = "T1 Pool 2", tournament = t1, organiser = o1)
    p3 = create(DkrPool; name = "T2 Pool 1", tournament = t2, organiser = o1)
    p4 = create(DkrPool; name = "T2 Pool 2", tournament = t2, organiser = o1)
    ps1 = create(DkrPoolStyle; name = "T1 Pool 2 Style", pool = p2)
    ps2 = create(DkrPoolStyle; name = "T2 Pool 1 Style", pool = p3)
    ps3 = create(DkrPoolStyle; name = "T1 Pool 1/3 Style", pool = p1, another_pool = p3)
    nq(f, n) = assert_num_queries(f, n)
    @test nq(2) do                                                                        # test_foreign_key
        t = get(DkrTournament; pk = t1.pk); pool = collect(t.dkrpool_set)[1]; pool.tournament === t
    end
    @test nq(2) do                                                                        # test_foreign_key_prefetch_related
        t = get(prefetch_related(objects(DkrTournament), :dkrpool_set); pk = t1.pk); pool = collect(t.dkrpool_set)[1]; pool.tournament === t
    end
    @test nq(2) do                                                                        # test_foreign_key_multiple_prefetch
        ts = collect(order_by(prefetch_related(objects(DkrTournament), :dkrpool_set), "pk"))
        collect(ts[1].dkrpool_set)[1].tournament === ts[1] && collect(ts[2].dkrpool_set)[1].tournament === ts[2]
    end
    @test nq(1) do                                                                        # test_queryset_or
        pools = t1.dkrpool_set | t2.dkrpool_set
        Set(p.tournament for p in pools) == Set([t1, t2])
    end
    @test nq(1) do                                                                        # test_queryset_or_different_cached_items
        first_ = collect(filter(t1.dkrpool_set | o1.dkrpool_set; pk = p1.pk))[1]
        first_.tournament === t1 && first_.organiser === o1
    end
    @test nq(2) do                                                                        # test_queryset_or_only_one_with_precache
        Set(p.tournament for p in (t1.dkrpool_set | filter(DkrPool; pk = p3.pk))) == Set([t1, t2])
    end
    @test nq(2) do
        Set(p.tournament for p in (filter(DkrPool; pk = p3.pk) | t1.dkrpool_set)) == Set([t1, t2])
    end
    @test nq(1) do                                                                        # test_queryset_and
        first_ = collect(filter(t1.dkrpool_set & o1.dkrpool_set; pk = p1.pk))[1]
        first_.tournament === t1 && first_.organiser === o1
    end
    @test nq(2) do                                                                        # test_one_to_one
        style = get(DkrPoolStyle; pk = ps1.pk); style.pool.dkrpoolstyle === style
    end
    @test nq(1) do                                                                        # test_one_to_one_select_related
        style = get(select_related(objects(DkrPoolStyle), :pool); pk = ps1.pk); style.pool.dkrpoolstyle === style
    end
    @test nq(1) do                                                                        # test_one_to_one_multi_select_related
        s = collect(order_by(select_related(objects(DkrPoolStyle), :pool), "pk"))
        s[1] === s[1].pool.dkrpoolstyle && s[2] === s[2].pool.dkrpoolstyle
    end
    @test nq(2) do                                                                        # test_one_to_one_prefetch_related
        style = get(prefetch_related(objects(DkrPoolStyle), :pool); pk = ps1.pk); style.pool.dkrpoolstyle === style
    end
    @test nq(2) do                                                                        # test_one_to_one_multi_prefetch_related
        s = collect(order_by(prefetch_related(objects(DkrPoolStyle), :pool), "pk"))
        s[1] === s[1].pool.dkrpoolstyle && s[2] === s[2].pool.dkrpoolstyle
    end
    @test nq(2) do                                                                        # test_reverse_one_to_one
        pool = get(DkrPool; pk = p2.pk); pool.dkrpoolstyle.pool === pool
    end
    @test nq(1) do                                                                        # test_reverse_one_to_one_select_related
        pool = get(select_related(objects(DkrPool), :dkrpoolstyle); pk = p2.pk); pool.dkrpoolstyle.pool === pool
    end
    @test nq(2) do                                                                        # test_reverse_one_to_one_prefetch_related
        pool = get(prefetch_related(objects(DkrPool), :dkrpoolstyle); pk = p2.pk); pool.dkrpoolstyle.pool === pool
    end
    @test nq(1) do                                                                        # test_reverse_one_to_one_multi_select_related
        ps = collect(order_by(select_related(objects(DkrPool), :dkrpoolstyle), "pk"))
        ps[2] === ps[2].dkrpoolstyle.pool && ps[3] === ps[3].dkrpoolstyle.pool
    end
    @test nq(2) do                                                                        # test_reverse_one_to_one_multi_prefetch_related
        ps = collect(order_by(prefetch_related(objects(DkrPool), :dkrpoolstyle), "pk"))
        ps[2] === ps[2].dkrpoolstyle.pool && ps[3] === ps[3].dkrpoolstyle.pool
    end
    # test_reverse_fk_select_related_multiple, test_multilevel_reverse_fk_select_related: select_related through a
    # FilteredRelation is #273
    @test_broken try
        ps = collect(order_by(select_related(annotate(objects(DkrPoolStyle); pool_1 = FilteredRelation("pool"), pool_2 = FilteredRelation("another_pool")),
                                             :pool_1, :pool_2), "-pk"))
        ps[1] === ps[1].pool_1.dkrpoolstyle && ps[1] === ps[1].pool_2.another_style
    catch
        false
    end
    @test try
        p = filter(select_related(annotate(filter(DkrTournament; id = t2.id); style = FilteredRelation("dkrpool__another_style")), :style); style__isnull = false)
        get(p).style.another_pool == p3
    catch
        false
    end
    # not translated: test_multilevel_reverse_fk_cyclic_select_related (a FilteredRelation back through the same model)
  end
end

# --- tests/field_defaults -----------------------------------------------------------------------------
@testset "django field_defaults: DefaultTests" begin
  port_block() do
    a = DfdArticle(); t = now(); save!(a)                                                # test_field_defaults
    @test a.id isa Integer && a.headline == "Default headline" && abs(t - a.pub_date) < Second(5)
    a = DfdDBArticle(); save!(a)                                                          # test_field_db_defaults_returning / _refresh
    @test a.id isa Integer && a.headline == "Default headline" && a.pub_date isa Dates.AbstractDateTime && a.cost == Juango.Decimal("3.33")
    obj1 = create(DfdDBDefaults)                                                          # test_null_db_default
    @test obj1.null == 1.1
    obj2 = create(DfdDBDefaults; null = nothing)
    @test assert_num_queries(() -> obj2.null === nothing, 0)
    obj1 = create(DfdDBDefaults; null = 1.2)                                              # test_db_default_blind_overwrite
    save!(DfdDBDefaults(id = obj1.pk)); refresh!(obj1)
    @test obj1.null == 1.1
    o = create(DfdDBDefaultsPK)                                                           # test_pk_db_default
    @test o.pk == "en"
    o = get(DfdDBDefaultsPK; pk = "en")
    @test o.pk == "en" && o.language_code == "en"
    o2 = create(DfdDBDefaultsPK; language_code = "de")
    @test o2.pk == "de" && o2.language_code == "de"
    parent1 = create(DfdDBDefaultsPK; language_code = "fr")                               # test_foreign_key_db_default
    child1 = create(DfdDBDefaultsFK); refresh!(child1)
    @test child1.language_code == parent1
    parent2 = get(DfdDBDefaultsPK; pk = "en")
    @test create(DfdDBDefaultsFK; language_code = parent2).language_code == parent2
    create(DfdDBDefaultsPK; language_code = "kr"); create(DfdDBDefaultsPK; language_code = "tr")   # test_primary_key_assigned_db_default_expression
    o3 = DfdDBDefaultsOneToOnePK(language_code = get(DfdDBDefaultsPK; pk = "kr")); save!(o3)
    @test o3.language_code_id != "tr"
  end
  port_block() do
    bulk_create([DfdDBArticle(), DfdDBArticle()])                                         # test_bulk_create_all_db_defaults
    @test collect(values_list(objects(DfdDBArticle), :headline; flat = true)) == ["Default headline", "Default headline"]
  end
  port_block() do
    t = Dates.floor(now(), Second)                                                         # test_bulk_create_all_db_defaults_one_field
    bulk_create([DfdDBArticle(pub_date = t), DfdDBArticle(pub_date = t)])
    @test collect(values_list(objects(DfdDBArticle), :headline, :pub_date, :cost)) ==
          [("Default headline", t, Juango.Decimal("3.33")), ("Default headline", t, Juango.Decimal("3.33"))]
  end
  port_block() do
    bulk_create([DfdDBArticle(), DfdDBArticle(headline = "Something else")])              # test_bulk_create_mixed_db_defaults
    @test sort(collect(values_list(objects(DfdDBArticle), :headline; flat = true))) == ["Default headline", "Something else"]
  end
  port_block() do
    obj = DfdDBArticle(); full_clean(obj); save!(obj); refresh!(obj)                      # test_full_clean
    @test obj.headline == "Default headline"
    obj = DfdDBArticle(headline = "Other title"); full_clean(obj); save!(obj); refresh!(obj)
    @test obj.headline == "Other title"
    @test haskey(full_clean(DfdDBArticle(headline = "")), :headline)        # (Juango returns the errors)
  end
  # test_db_default_function, test_case_when_db_default_*, test_bulk_create_mixed_db_defaults_function and AllowedDefaultTests:
  # a db_default expression other than Now() (Pi(), ExtractYear(Now()), Coalesce, Case) (#272)
  @test_broken (try Juango.db_default_value(Pi()) isa Juango.SQLDefault catch; false end)
  # not translated: test_both_default (a backend's insert_test_table_with_defaults SQL), the UUID4() primary key tests
end

# --- tests/m2m_signals --------------------------------------------------------------------------------
@testset "django m2m_signals: ManyToManySignalsTest" begin
    msgs = Any[]
    function receiver(sender; kw...)
        pk = kw[:pk_set]
        push!(msgs, (instance = kw[:instance], action = kw[:action], reverse = kw[:reverse], model = kw[:model], raw = kw[:raw],
                     objects = pk === nothing || isempty(pk) ? nothing : collect(filter(objects(kw[:model]); pk__in = collect(pk)))))
    end
    m(inst, action, rev, model, objs = nothing; raw = false) = (instance = inst, action = action, reverse = rev, model = model, raw = raw, objects = objs)
    senders = [through(DmsCar, :default_parts), through(DmsCar, :optional_parts), through(DmsPerson, :fans), through(DmsPerson, :friends)]
    function each(f)
        port_block() do
            empty!(msgs)
            vw, bmw, toyota = create(DmsCar; name = "VW"), create(DmsCar; name = "BMW"), create(DmsCar; name = "Toyota")
            wheelset, doors, engine, airbag, sunroof = (create(DmsPart; name = n) for n in ("Wheelset", "Doors", "Engine", "Airbag", "Sunroof"))
            alice, bob, chuck, daisy = (create(DmsPerson; name = n) for n in ("Alice", "Bob", "Chuck", "Daisy"))
            try
                f((; vw, bmw, toyota, wheelset, doors, engine, airbag, sunroof, alice, bob, chuck, daisy))
            finally
                foreach(s -> disconnect!(m2m_changed, receiver; sender = s), senders)
            end
        end
    end
    function car_signals(x; add_default_parts_before = false)
        connect!(m2m_changed, receiver; sender = through(DmsCar, :optional_parts))
        add_default_parts_before && add!(x.vw.default_parts, x.sunroof)
        connect!(m2m_changed, receiver; sender = through(DmsCar, :default_parts))
    end
    person_signals() = (connect!(m2m_changed, receiver; sender = through(DmsPerson, :fans)); connect!(m2m_changed, receiver; sender = through(DmsPerson, :friends)))
    each() do x                                                                            # test_pk_set_on_repeated_add_remove
        sets = Any[]
        handler(sender; kw...) = kw[:action] in (:pre_add, :pre_remove) && push!(sets, kw[:pk_set])
        connect!(m2m_changed, handler; sender = through(DmsCar, :default_parts))
        add!(x.vw.default_parts, x.wheelset); add!(x.vw.default_parts, x.wheelset)
        remove!(x.vw.default_parts, x.wheelset); remove!(x.vw.default_parts, x.wheelset)
        disconnect!(m2m_changed, handler; sender = through(DmsCar, :default_parts))
        @test sets == [Set([x.wheelset.pk]), Set(), Set([x.wheelset.pk]), Set([x.wheelset.pk])]
    end
    each() do x                                                                            # test_m2m_relations_add_remove_clear
        car_signals(x; add_default_parts_before = true)
        add!(x.vw.default_parts, x.wheelset, x.doors, x.engine)
        dew = [x.doors, x.engine, x.wheelset]
        @test msgs == [m(x.vw, :pre_add, false, DmsPart, dew), m(x.vw, :post_add, false, DmsPart, dew)]
        add!(x.doors.dmscar_set, x.bmw, x.toyota)
        @test msgs[3:4] == [m(x.doors, :pre_add, true, DmsCar, [x.bmw, x.toyota]), m(x.doors, :post_add, true, DmsCar, [x.bmw, x.toyota])]
    end
    each() do x                                                                            # test_m2m_relations_signals_remove_relation
        car_signals(x)
        remove!(x.vw.default_parts, x.engine, x.airbag)
        @test msgs == [m(x.vw, :pre_remove, false, DmsPart, [x.airbag, x.engine]), m(x.vw, :post_remove, false, DmsPart, [x.airbag, x.engine])]
    end
    each() do x                                                                            # test_m2m_relations_signals_give_the_self_vw_some_optional_parts
        car_signals(x)
        add!(x.vw.optional_parts, x.airbag, x.sunroof)
        @test msgs == [m(x.vw, :pre_add, false, DmsPart, [x.airbag, x.sunroof]), m(x.vw, :post_add, false, DmsPart, [x.airbag, x.sunroof])]
        add!(x.airbag.cars_optional, x.vw, x.bmw, x.toyota)
        @test msgs[3:4] == [m(x.airbag, :pre_add, true, DmsCar, [x.bmw, x.toyota]), m(x.airbag, :post_add, true, DmsCar, [x.bmw, x.toyota])]
    end
    each() do x                                                                            # test_m2m_relations_signals_reverse_relation_with_custom_related_name
        car_signals(x)
        remove!(x.airbag.cars_optional, x.vw)
        @test msgs == [m(x.airbag, :pre_remove, true, DmsCar, [x.vw]), m(x.airbag, :post_remove, true, DmsCar, [x.vw])]
    end
    each() do x                                                                            # test_m2m_relations_signals_clear_all_parts_of_the_self_vw
        car_signals(x)
        clear!(x.vw.default_parts)
        @test msgs == [m(x.vw, :pre_clear, false, DmsPart), m(x.vw, :post_clear, false, DmsPart)]
    end
    each() do x                                                                            # test_m2m_relations_signals_all_the_doors_off_of_cars
        car_signals(x)
        clear!(x.doors.dmscar_set)
        @test msgs == [m(x.doors, :pre_clear, true, DmsCar), m(x.doors, :post_clear, true, DmsCar)]
    end
    each() do x                                                                            # test_m2m_relations_signals_reverse_relation
        car_signals(x)
        clear!(x.airbag.cars_optional)
        @test msgs == [m(x.airbag, :pre_clear, true, DmsCar), m(x.airbag, :post_clear, true, DmsCar)]
    end
    each() do x                                                                            # test_m2m_relations_signals_alternative_ways
        car_signals(x)
        create(x.vw.default_parts; name = "Windows")
        p6 = get(DmsPart; name = "Windows")
        @test msgs == [m(x.vw, :pre_add, false, DmsPart, [p6]), m(x.vw, :post_add, false, DmsPart, [p6])]
        set!(x.vw.default_parts, [x.wheelset, x.doors, x.engine])
        dew = [x.doors, x.engine, x.wheelset]
        @test msgs[3:6] == [m(x.vw, :pre_remove, false, DmsPart, [p6]), m(x.vw, :post_remove, false, DmsPart, [p6]),
                            m(x.vw, :pre_add, false, DmsPart, dew), m(x.vw, :post_add, false, DmsPart, dew)]
    end
    each() do x                                                                            # test_m2m_relations_signals_clearing_removing
        car_signals(x; add_default_parts_before = true)
        set!(x.vw.default_parts, [x.wheelset, x.doors, x.engine]; clear = true)
        dew = [x.doors, x.engine, x.wheelset]
        @test msgs == [m(x.vw, :pre_clear, false, DmsPart), m(x.vw, :post_clear, false, DmsPart),
                       m(x.vw, :pre_add, false, DmsPart, dew), m(x.vw, :post_add, false, DmsPart, dew)]
        set!(x.vw.default_parts, [x.wheelset, x.doors]; clear = false)
        @test msgs[5:6] == [m(x.vw, :pre_remove, false, DmsPart, [x.engine]), m(x.vw, :post_remove, false, DmsPart, [x.engine])]
    end
    each() do x                                                                            # test_m2m_relations_signals_when_inheritance
        car_signals(x; add_default_parts_before = true)
        c4 = create(DmsSportsCar; name = "Bugatti", price = 1000000)
        c4b = get(DmsCar; name = "Bugatti")
        set!(c4.default_parts, [x.doors])
        @test msgs == [m(c4, :pre_add, false, DmsPart, [x.doors]), m(c4, :post_add, false, DmsPart, [x.doors])]
        add!(x.engine.dmscar_set, c4)
        @test msgs[3:4] == [m(x.engine, :pre_add, true, DmsCar, [c4b]), m(x.engine, :post_add, true, DmsCar, [c4b])]
    end
    each() do x                                                                            # test_m2m_relations_with_self_add_friends
        person_signals()
        set!(x.alice.friends, [x.bob, x.chuck])
        @test msgs == [m(x.alice, :pre_add, false, DmsPerson, [x.bob, x.chuck]), m(x.alice, :post_add, false, DmsPerson, [x.bob, x.chuck])]
    end
    each() do x                                                                            # test_m2m_relations_with_self_add_fan
        person_signals()
        set!(x.alice.fans, [x.daisy])
        @test msgs == [m(x.alice, :pre_add, false, DmsPerson, [x.daisy]), m(x.alice, :post_add, false, DmsPerson, [x.daisy])]
    end
    each() do x                                                                            # test_m2m_relations_with_self_add_idols
        person_signals()
        set!(x.chuck.idols, [x.alice, x.bob])
        @test msgs == [m(x.chuck, :pre_add, true, DmsPerson, [x.alice, x.bob]), m(x.chuck, :post_add, true, DmsPerson, [x.alice, x.bob])]
    end
    each() do x                                                                            # test_m2m_relations_set_base_raw (loading a fixture)
        add!(x.chuck.idols, x.daisy)
        person_signals()
        Base.ScopedValues.with(() -> set!(x.chuck.idols, [x.alice, x.bob]), Juango.SAVE_RAW => true)
        @test msgs == [m(x.chuck, :pre_remove, true, DmsPerson, [x.daisy]; raw = true), m(x.chuck, :post_remove, true, DmsPerson, [x.daisy]; raw = true),
                       m(x.chuck, :pre_add, true, DmsPerson, [x.alice, x.bob]; raw = true), m(x.chuck, :post_add, true, DmsPerson, [x.alice, x.bob]; raw = true)]
    end
    each() do x                                                                            # test_m2m_relations_set_base_raw_clear
        set!(x.chuck.idols, [x.daisy, x.bob])
        person_signals()
        Base.ScopedValues.with(() -> set!(x.chuck.idols, [x.alice, x.bob]; clear = true), Juango.SAVE_RAW => true)
        @test msgs == [m(x.chuck, :pre_clear, true, DmsPerson; raw = true), m(x.chuck, :post_clear, true, DmsPerson; raw = true),
                       m(x.chuck, :pre_add, true, DmsPerson, [x.alice, x.bob]; raw = true), m(x.chuck, :post_add, true, DmsPerson, [x.alice, x.bob]; raw = true)]
    end
end

# --- tests/from_db_value ------------------------------------------------------------------------------
@testset "django from_db_value: FromDBValueTest" begin
  port_block() do
    create(DfvCashModel; cash = "12.50")
    @test get(objects(DfvCashModel)).cash isa DfvCash                              # test_simple_load
    @test get(objects(DfvCashModel)).cash.value == Juango.Decimal("12.50")
    @test first(values_list(DfvCashModel, :cash; flat = true)) isa DfvCash         # test_values_list
    @test first(values(DfvCashModel, :cash))[:cash] isa DfvCash                    # test_values
    @test aggregate(objects(DfvCashModel); m = Max(:cash))[:m] isa DfvCash                   # test_aggregation
    @test get(defer(objects(DfvCashModel), :cash)).cash isa DfvCash                  # test_defer
    @test get(objects(DfvCashModel)).cash.vendor == Juango.vendor(Juango.backend())  # test_connection
    # (get_prep_value, the other direction: the value saved and compared)
    T = DfvCashModel
    o = create(T; cash = DfvCash(Juango.Decimal("3.25"), "x"))
    @test get(T; pk = o.pk).cash.value == Juango.Decimal("3.25")
  end
end

# --- tests/order_with_respect_to (base_tests.py's BaseOrderWithRespectToTests, and tests.py) --------------
@testset "django order_with_respect_to: OrderWithRespectToBaseTests" begin
    Q_, A = DowQuestion, DowAnswer
    texts(qs) = [o.text for o in qs]
    function each(f)
        port_block() do
            q1 = create(Q_; text = "Which Beatle starts with the letter 'R'?")
            as = [create(A; text = t, question = q1) for t in ("John", "Paul", "George", "Ringo")]
            f(q1, as)
        end
    end
    each() do q1, as      # test_default_to_insertion_order
        @test texts(collect(q1.dowanswer_set)) == ["John", "Paul", "George", "Ringo"]
    end
    each() do q1, as      # test_previous_and_next_in_order
        a1 = first(collect(q1.dowanswer_set))
        @test a1.text == "John" && get_next_in_order(a1).text == "Paul"
        a2 = collect(collect(q1.dowanswer_set))[end]
        @test a2.text == "Ringo" && get_previous_in_order(a2).text == "George"
    end
    each() do q1, as      # test_item_ordering
        a1 = collect(collect(q1.dowanswer_set))[2]
        @test get_order(a1.question, A) == [o.pk for o in collect(q1.dowanswer_set)]
        a2 = create(A; text = "Number five", question = q1)
        @test get_order(a1.question, A) == get_order(a2.question, A)
    end
    each() do q1, as      # test_set_order_unrelated_object
        q = create(Q_; text = "other")
        a = create(A; text = "Number five", question = q)
        set_order!(q1, A, vcat([o.pk for o in collect(q1.dowanswer_set)], [a.pk]))
        @test get(A; pk = a.pk)._order == 0
    end
    each() do q1, as      # test_change_ordering
        a = create(A; text = "Number five", question = q1)
        ids = [o.pk for o in collect(q1.dowanswer_set)]
        x = pop!(ids); insert!(ids, length(ids), x)
        @test get_order(a.question, A) != ids
        set_order!(a.question, A, ids)
        @test texts(collect(q1.dowanswer_set)) == ["John", "Paul", "George", "Number five", "Ringo"]
    end
    each() do q1, as      # test_recursive_ordering
        p1, p2 = create(DowPost; title = "1"), create(DowPost; title = "2")
        p1_1 = create(DowPost; title = "1.1", parent = p1); p1_2 = create(DowPost; title = "1.2", parent = p1)
        create(DowPost; title = "2.1", parent = p2)
        p1_3 = create(DowPost; title = "1.3", parent = p1)
        @test get_order(p1, DowPost) == [p1_1.pk, p1_2.pk, p1_3.pk]
    end
    each() do _, _        # test_delete_and_insert
        q1, q2 = create(Q_; text = "What is your favorite color?"), create(Q_; text = "What color is it?")
        a1, a2, a3, a4 = (create(A; text = t, question = q1) for t in ("Blue", "Red", "Green", "Yellow"))
        @test [o.pk for o in collect(q1.dowanswer_set)] == [a1.pk, a2.pk, a3.pk, a4.pk]
        a3.question = q2; save!(a3)
        delete!(a1)
        new_answer = create(A; text = "Black", question = q1)
        @test [o.pk for o in collect(q1.dowanswer_set)] == [a2.pk, a4.pk, new_answer.pk]
    end
    # (test_database_routing: set_order! is one UPDATE; the second database isn't set up here)
    each() do _, _        # test_bulk_create_with_empty_parent
        question = create(Q_; text = "Test Question")
        @test [o._order for o in bulk_create([A(; question = question, text = "Answer $i") for i in 0:2])] == [0, 1, 2]
    end
    each() do _, _        # test_bulk_create_with_existing_children
        question = create(Q_; text = "Test Question")
        create(A; question = question, text = "Existing 0"); create(A; question = question, text = "Existing 1")
        @test [o._order for o in bulk_create([A(; question = question, text = "New Answer $i") for i in 0:1])] == [2, 3]
    end
    each() do _, _        # test_bulk_create_multiple_parents
        q0, q1 = create(Q_; text = "Question 0"), create(Q_; text = "Question 1")
        made = bulk_create([A(; question = q0, text = "Q0 Answer 0"), A(; question = q1, text = "Q1 Answer 0"),
                            A(; question = q0, text = "Q0 Answer 1"), A(; question = q1, text = "Q1 Answer 1")])
        @test [o._order for o in made] == [0, 0, 1, 1]
    end
    each() do _, _        # test_bulk_create_mixed_scenario
        q0, q1 = create(Q_; text = "Question 0"), create(Q_; text = "Question 1")
        create(A; question = q1, text = "Q1 Existing 0"); create(A; question = q1, text = "Q1 Existing 1")
        made = bulk_create([A(; question = q0, text = "Q0 New 0"), A(; question = q1, text = "Q1 New 0"), A(; question = q0, text = "Q0 New 1")])
        @test [o._order for o in made] == [0, 2, 1]
    end
    each() do _, _        # test_bulk_create_respects_mixed_manual_order
        qa, qb = create(Q_; text = "Question A"), create(Q_; text = "Question B")
        create(A; question = qa, text = "Q-A Existing 0")
        create(A; question = qb, text = "Q-B Existing 0"); create(A; question = qb, text = "Q-B Existing 1")
        made = bulk_create([A(; question = qa, text = "Q-A Manual 4", _order = 4), A(; question = qb, text = "Q-B Auto 2"),
                            A(; question = qa, text = "Q-A Auto"), A(; question = qb, text = "Q-B Manual 10", _order = 10),
                            A(; question = qa, text = "Q-A Manual 7", _order = 7), A(; question = qb, text = "Q-B Auto 3")])
        @test [o._order for o in made] == [4, 2, 1, 10, 7, 3]
    end
    each() do _, _        # test_bulk_create_allows_duplicate_order_values
        question = create(Q_; text = "Duplicated Test")
        create(A; question = question, text = "Existing Answer")
        made = bulk_create([A(; question = question, text = "Manual Order 1", _order = 1), A(; question = question, text = "Auto Order 1"),
                            A(; question = question, text = "Auto Order 2"), A(; question = question, text = "Manual Order 1 Duplicate", _order = 1)])
        @test [o._order for o in made] == [1, 1, 2, 1]
    end
end

@testset "django order_with_respect_to: OrderWithRespectToTests, TestOrderWithRespectToOneToOnePK" begin
    # test_duplicate_order_field: one hidden _order field
    @test count(f -> f.name === :_order, Juango.concrete_fields(DowAnswer)) == 1
    port_block() do       # test_set_order
        e = create(DowEntity)
        d = create(DowDimension; entity = e)
        c1 = create(d.dowcomponent_set); c2 = create(d.dowcomponent_set)
        set_order!(d, DowComponent, [c1.id, c2.id])
        @test [c.pk for c in collect(d.dowcomponent_set)] == [c1.id, c2.id]
    end
end

# --- tests/custom_lookups -----------------------------------------------------------------------------
# Django's Lookup and Transform classes are register_lookup / register_transform functions here; the tests of
# the class registry's introspection (get_lookup, get_lookups, its cache, ForeignObject's lookups) and of
# get_lookup/get_transform overridden on a field class (CustomizedMethodsTests) aren't translated.
"Run `f` with these lookups and transforms registered, unregistering them afterwards (Django's register_lookup())."
function dcl_with(f, regs...)
    try
        for r in regs
            r()
        end
        f()
    finally
        for n in ("div3", "mult3", "lastdigit", "upper", "testyear", "justtheyear", "exactly", "isactually", "ne", "exact", "sw", "ew", "st_end", "lte")
            Juango.unregister_lookup(n)
        end
    end
end
const DCL_DIV3_LOOKUP = () -> Juango.register_lookup((l, r) -> "($l) % 3 = $r", "div3"; kinds = :int)
const DCL_DIV3 = (bilateral = false) -> () -> Juango.register_transform(l -> "($l) % 3", "div3"; kinds = :int, bilateral = bilateral)
const DCL_MULT3 = () -> Juango.register_transform(l -> "3 * ($l)", "mult3"; kinds = :int, bilateral = true)
const DCL_YEAR = (name = "testyear") -> () -> Juango.register_transform(l -> Juango.date_transform(l, :date, "year")[1], name; kinds = :date, output = :int)

@testset "django custom_lookups: LookupTests" begin
  port_block() do
    A = DclAuthor
    names(qs) = [a.name for a in qs]
    ages(n) = [create(A; name = "a$i", alias = "", age = i) for i in 1:n]
    # test_custom_name_lookup
    a1 = create(A; name = "a1", alias = "", birthdate = Date(1981, 2, 16)); create(A; name = "a2", alias = "", birthdate = Date(2012, 2, 29))
    dcl_with(DCL_YEAR(), DCL_YEAR("justtheyear"),
             () -> Juango.register_lookup((l, r) -> "$l = $r", "exactly"; transform = "testyear"),
             () -> Juango.register_lookup((l, r) -> "$l = $r", "isactually"; transform = "justtheyear")) do
        @test [a.pk for a in filter(A; birthdate__testyear__exactly = 1981)] == [a1.pk]
        @test [a.pk for a in filter(A; birthdate__justtheyear__isactually = 1981)] == [a1.pk]
        # (a lookup registered for a transform doesn't apply elsewhere)
        @test_throws Juango.LookupError collect(filter(A; birthdate__justtheyear__exactly = 1981))
    end
    delete!(objects(A))
    # test_custom_lookup_with_subquery
    author = create(A; name = "Isabella", alias = "")
    dcl_with(() -> Juango.register_lookup((l, r) -> "$l <> $r", "ne")) do
        sub = values(order_by(filter(A; age__isnull = true), "name"), :name)[1:1]
        @test [a.pk for a in filter(annotate(A; unknown_age = Subquery(sub)); unknown_age__ne = "Plato")] == [author.pk]
        @test [a.pk for a in filter(annotate(A; unknown_age = Lower(Subquery(sub))); unknown_age__ne = "plato")] == [author.pk]
    end
    delete!(objects(A))
    # test_custom_exact_lookup_none_rhs
    author = create(A; name = "author", alias = "", birthdate = nothing)
    dcl_with(() -> Juango.register_lookup((l, r) -> "$l = $r", "exact"; field = Juango.getfield_meta(A, :birthdate))) do
        @test get(A; birthdate__exact = nothing).pk == author.pk
    end
    delete!(objects(A))
    # test_basic_lookup
    a1, a2, a3, a4 = ages(4)
    dcl_with(DCL_DIV3_LOOKUP) do
        @test names(filter(A; age__div3 = 0)) == ["a3"]
        @test names(order_by(filter(A; age__div3 = 1), "age")) == ["a1", "a4"]
        @test names(filter(A; age__div3 = 2)) == ["a2"]
        @test isempty(filter(A; age__div3 = 3))
    end
    # test_div3_extract
    dcl_with(DCL_DIV3()) do
        b = order_by(objects(A), "name")
        @test names(filter(b; age__div3 = 2)) == ["a2"]
        @test names(filter(b; age__div3__lte = 3)) == ["a1", "a2", "a3", "a4"]
        @test names(filter(b; age__div3__in = [0, 2])) == ["a2", "a3"]
        @test names(filter(b; age__div3__in = [2, 4])) == ["a2"]
        @test isempty(filter(b; age__div3__gte = 3))
        @test names(filter(b; age__div3__range = (1, 2))) == ["a1", "a2", "a4"]
        # SubqueryTransformTests.test_subquery_usage
        @test names(filter(b; id__in = filter(A; age__div3 = 2))) == ["a2"]
    end
  end
end

@testset "django custom_lookups: BilateralTransformTests" begin
  port_block() do
    A = DclAuthor
    names(qs) = [a.name for a in qs]
    UPPER = () -> Juango.register_transform(l -> "UPPER($l)", "upper"; kinds = :char, bilateral = true)
    dcl_with(UPPER) do                 # test_bilateral_upper
        create(A; name = "Doe", alias = ""); create(A; name = "doe", alias = ""); create(A; name = "Foo", alias = "")
        @test sort(names(filter(A; name__upper = "doe"))) == ["Doe", "doe"]
        @test names(filter(A; name__upper__contains = "f")) == ["Foo"]
        # test_bilateral_inner_qs
        @test_throws "Bilateral transformations on nested querysets are not implemented." collect(filter(A; name__upper__in = values_list(A, :name)))
        delete!(objects(A))
        # test_bilateral_multi_value
        bulk_create([A(; name = "Foo", alias = ""), A(; name = "Bar", alias = ""), A(; name = "Ray", alias = "")])
        @test names(order_by(filter(A; name__upper__in = ["foo", "bar", "doe"]), "name")) == ["Bar", "Foo"]
        delete!(objects(A))
    end
    for i in 1:4
        create(A; name = "a$i", alias = "", age = i, average_rating = (3.2, 0.5, 1.5, nothing)[i])
    end
    b = order_by(objects(A), "name")
    dcl_with(DCL_DIV3(true)) do        # test_div3_bilateral_extract
        @test names(filter(b; age__div3 = 2)) == ["a2"]
        @test names(filter(b; age__div3__lte = 3)) == ["a3"]
        @test names(filter(b; age__div3__in = [0, 2])) == ["a2", "a3"]
        @test names(filter(b; age__div3__in = [2, 4])) == ["a1", "a2", "a4"]
        @test names(filter(b; age__div3__gte = 3)) == ["a1", "a2", "a3", "a4"]
        @test names(filter(b; age__div3__range = (1, 2))) == ["a1", "a2", "a4"]
    end
    dcl_with(DCL_MULT3, DCL_DIV3(true)) do          # test_bilateral_order
        @test names(filter(b; age__mult3__div3 = 42)) == ["a1", "a2", "a3", "a4"]     # mult3__div3 always leads to 0
        @test names(filter(b; age__div3__mult3 = 42)) == ["a3"]
    end
    dcl_with(DCL_MULT3) do             # test_bilateral_fexpr
        @test names(filter(b; age__mult3 = F(:age))) == ["a1", "a2", "a3", "a4"]
        @test names(filter(b; age__mult3__gte = F(:average_rating))) == ["a2", "a3"]    # same as age >= average_rating
    end
    delete!(objects(A))
    # test_transform_order_by
    for (i, age) in enumerate((11, 23, 32, 40))
        create(A; name = "a$i", alias = "", age = age)
    end
    dcl_with(() -> Juango.register_transform(l -> "SUBSTR(CAST($l AS CHAR(2)), 2, 1)", "lastdigit"; kinds = :int)) do
        @test names(order_by(objects(A), "age__lastdigit")) == ["a4", "a1", "a3", "a2"]
    end
  end
end

@testset "django custom_lookups: YearLteTests, LookupTransformCallOrderTests, RegisterLookupTests" begin
  port_block() do
    A = DclAuthor
    names(qs) = [a.name for a in qs]
    for (i, d) in enumerate((Date(1981, 2, 16), Date(2012, 2, 29), Date(2012, 1, 31), Date(2012, 3, 1)))
        create(A; name = "a$i", alias = "", birthdate = d)
    end
    b = order_by(objects(A), "name")
    YEAR_LOOKUPS = (() -> Juango.register_lookup((l, r, inner) -> "$inner >= ($r || '-01-01')::date AND $inner <= ($r || '-12-31')::date",
                                                 "exact"; transform = "testyear"),
                    () -> Juango.register_lookup((l, r, inner) -> "$inner <= ($r || '-12-31')::date", "lte"; transform = "testyear"))
    dcl_with(DCL_YEAR(), YEAR_LOOKUPS...) do
        # test_year_lte_sql, test_postgres_year_exact (the SQL; Juango's values are parameters)
        @test occursin("<= (? || '-12-31')::date", first(Juango.select_sql(filter(b; birthdate__testyear__lte = 2011))))
        @test occursin(">= (? || '-01-01')::date", first(Juango.select_sql(filter(b; birthdate__testyear = 2011))))
        if Juango.backend() isa Juango.PostgresBackend        # test_year_lte (PostgreSQL's SQL)
            @test names(filter(b; birthdate__testyear__lte = 2012)) == ["a1", "a2", "a3", "a4"]
            @test names(filter(b; birthdate__testyear = 2012)) == ["a2", "a3", "a4"]
            @test !occursin("BETWEEN", first(Juango.select_sql(filter(b; birthdate__testyear = 2012))))
            @test names(filter(b; birthdate__testyear__lte = 2011)) == ["a1"]
            @test names(filter(b; birthdate__testyear__lt = 2012)) == ["a1"]       # the non-optimized version works, too
            # test_year_lte_fexpr
            for (n, age) in (("a2", 2011), ("a3", 2012), ("a4", 2013))
                update!(filter(A; name = n); age = age)
            end
            @test names(filter(b; birthdate__testyear__lte = F(:age))) == ["a3", "a4"]
            @test names(filter(b; birthdate__testyear__lt = F(:age))) == ["a4"]
        end
    end
    # LookupTransformCallOrderTests.test_call_order: the messages
    dcl_with(DCL_YEAR()) do
        @test_throws Juango.LookupError("Unsupported lookup 'junk' for IntegerField or join on the field not permitted.") collect(filter(A; birthdate__testyear__junk = 2012))
        @test_throws Juango.LookupError("Unsupported lookup 'junk__more_junk' for IntegerField or join on the field not permitted.") collect(filter(A; birthdate__testyear__junk__more_junk = 2012))
        @test length(filter(A; birthdate__testyear = 2012)) == 3
        @test length(filter(A; birthdate__testyear__exact = 2012)) == 3
    end
    delete!(objects(A))
    # RegisterLookupTests: a lookup or transform registered for one field (Django's instance lookups)
    create(A; name = "ab", alias = "ba")
    name, alias = Juango.getfield_meta(A, :name), Juango.getfield_meta(A, :alias)
    cat(a, b) = Juango.backend() isa Juango.MySQLBackend ? "CONCAT($a, $b)" : "$a || $b"
    SW = (n = "sw"; kw...) -> () -> Juango.register_lookup((l, r) -> "$l LIKE " * cat(r, "'%'"), n; kw...)
    dcl_with(SW(; field = name)) do                                  # test_instance_lookup
        @test length(filter(A; name__sw = "a")) == 1
        @test_throws Juango.LookupError collect(filter(A; alias__sw = "b"))
    end
    @test_throws Juango.LookupError collect(filter(A; name__sw = "a"))
    # test_instance_lookup_override_class_lookups: the field's registration first, whatever the order
    dcl_with(SW("st_end"; kinds = :char),
             () -> Juango.register_lookup((l, r) -> "$l LIKE " * cat("'%'", r), "st_end"; field = alias)) do
        @test length(filter(A; name__st_end = "a")) == 1 && isempty(filter(A; name__st_end = "b"))
        @test length(filter(A; alias__st_end = "a")) == 1 && isempty(filter(A; alias__st_end = "b"))
    end
    # test_transform_on_field
    dcl_with(() -> Juango.register_transform(l -> "UPPER($l)", "upper"; field = alias)) do
        @test length(filter(A; alias__upper = "BA")) == 1
        @test_throws Juango.LookupError collect(filter(A; name__upper = "AB"))
    end
  end
end
