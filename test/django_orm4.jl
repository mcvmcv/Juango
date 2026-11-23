# More of Django's ORM tests, ported (#227): tests/get_earliest_or_latest, m2m_and_m2o, m2m_intermediary, m2m_multiple,
# m2m_through_regress, custom_columns, custom_methods, reserved_names, datatypes, properties, str.
# julia --project=test test/django_orm4.jl   (see setup.jl)
#
# As django_orm.jl: Django's models and data, translated to Juango's API; each test keeps its Django name in a
# comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# --- tests/get_earliest_or_latest/models.py -----------------------------------------------------------
@model struct DgeArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    expire_date = DateField()
    Meta(table = "dge_article", get_latest_by = "pub_date")
end
@model struct DgePerson
    name = CharField(max_length = 30)
    birthday = DateField()
    Meta(table = "dge_person")
end
@model struct DgeComment
    article = ForeignKey(DgeArticle; on_delete = :CASCADE)
    likes_count = PositiveIntegerField()
    Meta(table = "dge_comment")
end
@model struct DgeOrderedArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    Meta(table = "dge_orderedarticle", ordering = ["headline"])
end
# --- tests/m2m_and_m2o/models.py ----------------------------------------------------------------------
@model struct DmoUser
    username = CharField(max_length = 20)
    Meta(table = "dmo_user")
end
@model struct DmoIssue
    num = IntegerField()
    cc = ManyToManyField(DmoUser; blank = true, related_name = :test_issue_cc)
    client = ForeignKey(DmoUser; on_delete = :CASCADE, related_name = :test_issue_client)
    Meta(table = "dmo_issue", ordering = ["num"])
end
@model struct DmoStringReferenceModel
    others = ManyToManyField(:DmoStringReferenceModel)
    Meta(table = "dmo_stringreferencemodel")
end
# --- tests/m2m_intermediary/models.py -----------------------------------------------------------------
@model struct DmqReporter
    first_name = CharField(max_length = 30)
    last_name = CharField(max_length = 30)
    Meta(table = "dmq_reporter")
end
Base.show(io::IO, r::DmqReporter) = print(io, r.first_name, " ", r.last_name)
@model struct DmqArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    Meta(table = "dmq_article")
end
@model struct DmqWriter
    reporter = ForeignKey(DmqReporter; on_delete = :CASCADE)
    article = ForeignKey(DmqArticle; on_delete = :CASCADE)
    position = CharField(max_length = 100)
    Meta(table = "dmq_writer")
end
# --- tests/m2m_multiple/models.py ---------------------------------------------------------------------
@model struct DmpCategory
    name = CharField(max_length = 20)
    Meta(table = "dmp_category", ordering = ["name"])
end
@model struct DmpArticle
    headline = CharField(max_length = 50)
    pub_date = DateTimeField()
    primary_categories = ManyToManyField(DmpCategory; related_name = :primary_article_set)
    secondary_categories = ManyToManyField(DmpCategory; related_name = :secondary_article_set)
    Meta(table = "dmp_article", ordering = ["pub_date"])
end
# --- tests/m2m_through_regress/models.py ----------------------------------------------------------------
@model struct DtrPerson
    name = CharField(max_length = 128)
    Meta(table = "dtr_person")
end
@model struct DtrGroup
    name = CharField(max_length = 128)
    members = ManyToManyField(DtrPerson; through = :DtrMembership)
    user_members = ManyToManyField(User; through = :DtrUserMembership)
    Meta(table = "dtr_group")
end
@model struct DtrMembership
    person = ForeignKey(DtrPerson; on_delete = :CASCADE)
    group = ForeignKey(DtrGroup; on_delete = :CASCADE)
    price = IntegerField(default = 100)
    Meta(table = "dtr_membership")
end
@model struct DtrUserMembership                      # (Django's id is AutoField(db_column = "usermembership_id"): #277)
    user = ForeignKey(User; on_delete = :CASCADE)
    group = ForeignKey(DtrGroup; on_delete = :CASCADE)
    price = IntegerField(default = 100)
    Meta(table = "dtr_usermembership")
end
@model struct DtrCar
    make = CharField(max_length = 20, unique = true, null = true)
    drivers = ManyToManyField(:DtrDriver; through = :DtrCarDriver)
    Meta(table = "dtr_car")
end
Base.show(io::IO, c::DtrCar) = print(io, something(c.make, "None"))
@model struct DtrDriver
    name = CharField(max_length = 20, unique = true, null = true)
    Meta(table = "dtr_driver", ordering = ["name"])
end
Base.show(io::IO, d::DtrDriver) = print(io, something(d.name, "None"))
@model struct DtrCarDriver
    car = ForeignKey(DtrCar; on_delete = :CASCADE, to_field = :make)
    driver = ForeignKey(DtrDriver; on_delete = :CASCADE, to_field = :name)
    Meta(table = "dtr_cardriver")
end
@model struct DtrEvent
    name = CharField(max_length = 50, unique = true)
    people = ManyToManyField(DtrPerson; through = :DtrIndividualCompetitor)
    special_people = ManyToManyField(DtrPerson; through = :DtrProxiedIndividualCompetitor, related_name = :special_event_set)
    teams = ManyToManyField(DtrGroup; through = :DtrCompetingTeam)
    Meta(table = "dtr_event")
end
@model struct DtrCompetitor
    event = ForeignKey(DtrEvent; on_delete = :CASCADE)
    Meta(table = "dtr_competitor")
end
@model struct DtrIndividualCompetitor <: DtrCompetitor
    person = ForeignKey(DtrPerson; on_delete = :CASCADE)
    Meta(table = "dtr_individualcompetitor")
end
@model struct DtrCompetingTeam <: DtrCompetitor
    team = ForeignKey(DtrGroup; on_delete = :CASCADE)
    Meta(table = "dtr_competingteam")
end
@model struct DtrProxiedIndividualCompetitor <: DtrIndividualCompetitor
    Meta(proxy = true)
end
# --- tests/custom_columns/models.py -----------------------------------------------------------------------
@model struct DccAuthor                              # (Django's key is Author_ID = AutoField(db_column = "Author ID"): #277)
    first_name = CharField(max_length = 30, db_column = "firstname")
    last_name = CharField(max_length = 30, db_column = "last")
    Meta(table = "my_author_table", ordering = ["last_name", "first_name"])
end
Base.show(io::IO, a::DccAuthor) = print(io, a.first_name, " ", a.last_name)
@model struct DccArticle
    headline = CharField(max_length = 100)
    authors = ManyToManyField(DccAuthor; db_table = "my_m2m_table")
    primary_author = ForeignKey(DccAuthor; on_delete = :SET_NULL, db_column = "Author ID", related_name = :primary_set, null = true)
    Meta(table = "dcc_article", ordering = ["headline"])
end
# --- tests/custom_methods/models.py -----------------------------------------------------------------------
@model struct DcxArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    Meta(table = "dcx_article")
end
was_published_today(a::DcxArticle) = a.pub_date == today()
articles_from_same_day_1(a::DcxArticle) = exclude(filter(DcxArticle; pub_date = a.pub_date), id = a.id)
# (Django's runs the SQL through a cursor and builds the objects from the rows: a raw query here)
articles_from_same_day_2(a::DcxArticle) =
    collect(raw(DcxArticle, "SELECT id, headline, pub_date FROM dcx_article WHERE pub_date = ? AND id != ?", [a.pub_date, a.id]))
# --- tests/reserved_names/models.py -----------------------------------------------------------------------
@model struct DrnThing                               # (where is a Julia keyword: the field is where_date, its column "where")
    when = CharField(max_length = 1, primary_key = true)
    join = CharField(max_length = 1)
    like = CharField(max_length = 1)
    drop = CharField(max_length = 1)
    alter = CharField(max_length = 1)
    having = CharField(max_length = 1)
    where_date = DateField(db_column = "where")
    has_hyphen = CharField(max_length = 1, db_column = "has-hyphen", default = "")
    Meta(table = "select")
end
# --- tests/datatypes/models.py ----------------------------------------------------------------------------
@model struct DtyDonut
    name = CharField(max_length = 100)
    is_frosted = BooleanField(default = false)
    has_sprinkles = BooleanField(null = true)
    baked_date = DateField(null = true)
    baked_time = TimeField(null = true)
    consumed_at = DateTimeField(null = true)
    review = TextField(default = "")
    Meta(table = "dty_donut", ordering = ["consumed_at"])
end
@model struct DtyRumBaba
    baked_date = DateField(auto_now_add = true)
    baked_timestamp = DateTimeField(auto_now_add = true)
    Meta(table = "dty_rumbaba")
end
# --- tests/properties/models.py ---------------------------------------------------------------------------
@model struct DprPerson
    first_name = CharField(max_length = 30)
    last_name = CharField(max_length = 30)
    Meta(table = "dpr_person")
end
full_name(p::DprPerson) = "$(p.first_name) $(p.last_name)"
# --- tests/str/models.py ----------------------------------------------------------------------------------
@model struct DstInternationalArticle
    headline = CharField(max_length = 100)
    pub_date = DateTimeField()
    Meta(table = "dst_internationalarticle")
end
Base.show(io::IO, a::DstInternationalArticle) = print(io, a.headline)
@model struct DstDefault
    Meta(table = "dst_default")
end

redirect_stdout(devnull) do
    ms = Any[DgeArticle, DgePerson, DgeComment, DgeOrderedArticle,
             DmoUser, DmoIssue, DmoStringReferenceModel, through(DmoIssue, :cc), through(DmoStringReferenceModel, :others),
             DmqReporter, DmqArticle, DmqWriter,
             DmpCategory, DmpArticle, through(DmpArticle, :primary_categories), through(DmpArticle, :secondary_categories),
             DtrPerson, DtrGroup, DtrMembership, DtrUserMembership, DtrCar, DtrDriver, DtrCarDriver,
             DtrEvent, DtrCompetitor, DtrIndividualCompetitor, DtrCompetingTeam,
             DccAuthor, DccArticle, through(DccArticle, :authors), DcxArticle, DrnThing, DtyDonut, DtyRumBaba, DprPerson,
             DstInternationalArticle, DstDefault]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

# --- tests/get_earliest_or_latest ---------------------------------------------------------------------
@testset "django get_earliest_or_latest: EarliestOrLatestTests" begin
    A = DgeArticle
    meta = Juango.modelmeta(A).extra
    with_latest_by(f, v) = (old = meta[:get_latest_by]; v === nothing ? delete!(meta, :get_latest_by) : (meta[:get_latest_by] = v);
                            try f() finally meta[:get_latest_by] = old end)
    NOFIELDS = "earliest() and latest() require either fields as positional arguments or 'get_latest_by' in the model's Meta."
    port_block() do                   # test_earliest
        @test_throws Juango.DoesNotExist earliest(A)
        a1 = create(A; headline = "Article 1", pub_date = Date(2005, 7, 26), expire_date = Date(2005, 9, 1))
        a2 = create(A; headline = "Article 2", pub_date = Date(2005, 7, 27), expire_date = Date(2005, 7, 28))
        a3 = create(A; headline = "Article 3", pub_date = Date(2005, 7, 28), expire_date = Date(2005, 8, 27))
        a4 = create(A; headline = "Article 4", pub_date = Date(2005, 7, 28), expire_date = Date(2005, 7, 30))
        @test earliest(A) == a1
        @test earliest(filter(A; pub_date__gt = Date(2005, 7, 26))) == a2
        @test earliest(A, :expire_date) == a2
        @test earliest(filter(A; pub_date__gt = Date(2005, 7, 26)), :expire_date) == a2
        @test earliest(order_by(objects(A), "id")) == a1                  # (#11283)
        with_latest_by(nothing) do
            @test_throws ArgumentError(NOFIELDS) earliest(A)
            @test earliest(filter(A; pub_date = Date(2005, 7, 28)), :pub_date, :expire_date) == a4
            @test earliest(filter(A; pub_date = Date(2005, 7, 28)), :pub_date, "-expire_date") == a3
        end
        with_latest_by(("pub_date", "expire_date")) do
            @test earliest(filter(A; pub_date = Date(2005, 7, 28))) == a4
        end
    end
    port_block() do                   # test_earliest_sliced_queryset, test_latest_sliced_queryset
        @test_throws ArgumentError("Cannot change a query once a slice has been taken.") earliest(objects(A)[1:5])
        @test_throws ArgumentError("Cannot change a query once a slice has been taken.") latest(objects(A)[1:5])
    end
    port_block() do                   # test_latest
        @test_throws Juango.DoesNotExist latest(A)
        a1 = create(A; headline = "Article 1", pub_date = Date(2005, 7, 26), expire_date = Date(2005, 9, 1))
        a2 = create(A; headline = "Article 2", pub_date = Date(2005, 7, 27), expire_date = Date(2005, 7, 28))
        a3 = create(A; headline = "Article 3", pub_date = Date(2005, 7, 27), expire_date = Date(2005, 8, 27))
        a4 = create(A; headline = "Article 4", pub_date = Date(2005, 7, 28), expire_date = Date(2005, 7, 30))
        @test latest(A) == a4
        @test latest(filter(A; pub_date__lt = Date(2005, 7, 27))) == a1
        @test latest(A, :expire_date) == a1
        @test latest(filter(A; pub_date__gt = Date(2005, 7, 26)), :expire_date) == a3
        @test latest(order_by(objects(A), "id")) == a4                    # (#11283)
        with_latest_by(nothing) do
            @test_throws ArgumentError(NOFIELDS) latest(A)
            @test latest(filter(A; pub_date = Date(2005, 7, 27)), :pub_date, :expire_date) == a3
            @test latest(filter(A; pub_date = Date(2005, 7, 27)), :pub_date, "-expire_date") == a2
        end
        with_latest_by(("pub_date", "expire_date")) do
            @test latest(filter(A; pub_date = Date(2005, 7, 27))) == a3
        end
    end
    port_block() do                   # test_latest_manual
        create(DgePerson; name = "Ralph", birthday = Date(1950, 1, 1))
        p2 = create(DgePerson; name = "Stephanie", birthday = Date(1960, 2, 3))
        @test_throws ArgumentError(NOFIELDS) latest(DgePerson)
        @test latest(DgePerson, :birthday) == p2
    end
end

@testset "django get_earliest_or_latest: TestFirstLast" begin
    P = DgePerson
    port_block() do                   # test_first
        p1 = create(P; name = "Bob", birthday = Date(1950, 1, 1))
        p2 = create(P; name = "Alice", birthday = Date(1961, 2, 3))
        @test first(P) == p1
        @test first(order_by(objects(P), "name")) == p2
        @test first(filter(P; birthday__lte = Date(1955, 1, 1))) == p1
        @test first(filter(P; birthday__lte = Date(1940, 1, 1))) === nothing
    end
    port_block() do                   # test_last
        p1 = create(P; name = "Alice", birthday = Date(1950, 1, 1))
        p2 = create(P; name = "Bob", birthday = Date(1960, 2, 3))
        @test last(P) == p2
        @test last(order_by(objects(P), "-name")) == p1
        @test last(filter(P; birthday__lte = Date(1955, 1, 1))) == p1
        @test last(filter(P; birthday__lte = Date(1940, 1, 1))) === nothing
    end
    # (test_index_error_not_suppressed: a Python queryset class whose iteration raises IndexError, not translated)
    port_block() do                   # test_first_last_unordered_qs_aggregation_error
        a1 = create(DgeArticle; headline = "Article 1", pub_date = Date(2005, 7, 26), expire_date = Date(2005, 9, 1))
        create(DgeComment; article = a1, likes_count = 5)
        qs = annotate(values(objects(DgeComment), :article); avg_likes = Avg(:likes_count))
        for (f, name) in ((first, "first"), (last, "last"))
            @test_throws ArgumentError("Cannot use QuerySet.$name() on an unordered queryset performing aggregation. Add an ordering with order_by().") f(qs)
        end
        @test first(order_by(qs, "article"))[:avg_likes] == 5                 # (ordered: fine)
    end
    port_block() do                   # test_first_last_empty_order_by_has_no_pk_ordering, ..._clears_default_ordering
        create(DgeArticle; headline = "Article 1", pub_date = Date(2006, 9, 10), expire_date = Date(2056, 9, 11))
        create(DgeOrderedArticle; headline = "Article 1", pub_date = Date(2006, 9, 10))
        # (Django's check that first/last don't call order_by: here, that their SQL has no ORDER BY. Juango orders by id: #278)
        sqls = String[]
        Juango.execute_wrapper((ex, sql, ps, ctx) -> (push!(sqls, sql); ex(sql, ps))) do
            first(order_by(objects(DgeArticle))); last(order_by(objects(DgeArticle)))
            first(order_by(objects(DgeOrderedArticle))); last(order_by(objects(DgeOrderedArticle)))
        end
        @test_broken !any(s -> occursin("ORDER BY", s), sqls)
    end
end

# --- tests/m2m_and_m2o --------------------------------------------------------------------------------
@testset "django m2m_and_m2o" begin
  port_block() do
    U, I = DmoUser, DmoIssue
    # test_related_objects_have_name_attribute: the reverse query names are the related_names
    @test count(filter(U; test_issue_client__num = 1)) == 0 && count(filter(U; test_issue_cc__num = 1)) == 0
    r = create(U; username = "russell"); g = create(U; username = "gustav")       # test_m2m_and_m2o
    i1 = create(I; num = 1, client = r)
    i2 = create(I; num = 2, client = r); add!(i2.cc, r)
    i3 = create(I; num = 3, client = g); add!(i3.cc, r)
    nums(qs) = [i.num for i in qs]
    @test nums(filter(I; client = r.id)) == [1, 2]
    @test nums(filter(I; client = g.id)) == [3]
    @test nums(filter(I; cc__id__exact = g.id)) == []
    @test nums(filter(I; cc__id__exact = r.id)) == [2, 3]
    @test nums(filter(I, Q(cc__id__exact = r.id) | Q(client = r.id))) == [1, 2, 3]
    @test nums(filter(I; cc__id__exact = r.id) | filter(I; client = r.id)) == [1, 2, 3]
    @test nums(filter(I, Q(client = r.id) | Q(cc__id__exact = r.id))) == [1, 2, 3]
    @test sort(nums(r.test_issue_client)) == [1, 2] && nums(r.test_issue_cc) == [2, 3]
    # RelatedObjectUnicodeTests.test_m2m_with_unicode_reference (#6045: a self-referential m2m named as a string)
    m1 = create(DmoStringReferenceModel); m2 = create(DmoStringReferenceModel)
    add!(m2.others, m1); save!(m2)
    @test collect(m2.others) == [m1]
  end
end

# --- tests/m2m_intermediary ---------------------------------------------------------------------------
@testset "django m2m_intermediary" begin
  port_block() do                     # test_intermediary
    r1 = create(DmqReporter; first_name = "John", last_name = "Smith")
    r2 = create(DmqReporter; first_name = "Jane", last_name = "Doe")
    a = create(DmqArticle; headline = "This is a test", pub_date = Date(2005, 7, 27))
    w1 = create(DmqWriter; reporter = r1, article = a, position = "Main writer")
    w2 = create(DmqWriter; reporter = r2, article = a, position = "Contributor")
    @test [(string(w.reporter), w.position) for w in order_by(select_related(a.dmqwriter_set, :reporter, :article), "-position")] ==
          [("John Smith", "Main writer"), ("Jane Doe", "Contributor")]
    @test w1.reporter == r1 && w2.reporter == r2 && w1.article == a && w2.article == a
    @test [(string(w.reporter), w.position) for w in r1.dmqwriter_set] == [("John Smith", "Main writer")]
  end
end

# --- tests/m2m_multiple -------------------------------------------------------------------------------
@testset "django m2m_multiple" begin
  port_block() do                     # test_multiple
    c1, c2, c3, c4 = (create(DmpCategory; name = n) for n in ("Sports", "News", "Crime", "Life"))
    a1 = create(DmpArticle; headline = "Parrot steals", pub_date = DateTime(2005, 11, 27))
    add!(a1.primary_categories, c2, c3); add!(a1.secondary_categories, c4)
    a2 = create(DmpArticle; headline = "Parrot runs", pub_date = DateTime(2005, 11, 28))
    add!(a2.primary_categories, c1, c2); add!(a2.secondary_categories, c4)
    names(qs) = [c.name for c in qs]
    heads(qs) = [a.headline for a in qs]
    @test names(a1.primary_categories) == ["Crime", "News"]
    @test names(a2.primary_categories) == ["News", "Sports"]
    @test names(a1.secondary_categories) == ["Life"]
    @test heads(c1.primary_article_set) == ["Parrot runs"] && isempty(c1.secondary_article_set)
    @test heads(c2.primary_article_set) == ["Parrot steals", "Parrot runs"] && isempty(c2.secondary_article_set)
    @test heads(c3.primary_article_set) == ["Parrot steals"] && isempty(c3.secondary_article_set)
    @test isempty(c4.primary_article_set) && heads(c4.secondary_article_set) == ["Parrot steals", "Parrot runs"]
  end
end

# --- tests/m2m_through_regress --------------------------------------------------------------------------
@testset "django m2m_through_regress: M2MThroughTestCase, M2MThroughSerializationTestCase" begin
  port_block() do
    bob = create(DtrPerson; name = "Bob"); jim = create(DtrPerson; name = "Jim")
    rock = create(DtrGroup; name = "Rock"); roll = create(DtrGroup; name = "Roll")
    frank = create_user("dtr_frank", "password"; email = "frank@example.com")
    jane = create_user("dtr_jane", "password"; email = "jane@example.com")
    try
        create(DtrMembership; person = bob, group = rock)
        create(DtrMembership; person = bob, group = roll, price = 50)
        create(DtrMembership; person = jim, group = rock, price = 50)
        create(DtrUserMembership; user = frank, group = rock)
        create(DtrUserMembership; user = frank, group = roll)
        create(DtrUserMembership; user = jane, group = rock)
        ids(qs) = sort([o.pk for o in qs])
        @test ids(bob.dtrgroup_set) == ids([rock, roll])                             # test_retrieve_reverse_m2m_items
        @test collect(roll.members) == [bob]                                         # test_retrieve_forward_m2m_items
        @test ids(frank.dtrgroup_set) == ids([rock, roll])                           # ..._via_custom_id_intermediary
        @test collect(roll.user_members) == [frank]
        @test collect(filter(rock.members; dtrmembership__price = 50)) == [jim]      # test_join_trimming_forwards (#8046, #8254)
        @test collect(filter(bob.dtrgroup_set; dtrmembership__price = 50)) == [roll] # test_join_trimming_reverse
    finally
        delete!(frank); delete!(jane)
    end
  end
  port_block() do                     # test_serialization (#8134): the through row serializes as a plain model
    bob = create(DtrPerson; name = "Bob"); roll = create(DtrGroup; name = "Roll")
    bob_roll = create(DtrMembership; person = bob, group = roll)
    out = JSON.parse(dumpdata(Juango.serial_label(DtrMembership), Juango.serial_label(DtrPerson), Juango.serial_label(DtrGroup)))
    # (Juango writes referenced models first; Django in the order given. The group's members, a many-to-many with its
    # own through model, aren't a field of the group: the through row is dumped instead)
    @test Set((d["model"], d["pk"], Dict(d["fields"])) for d in out) ==
          Set([(Juango.serial_label(DtrMembership), bob_roll.pk, Dict("person" => bob.pk, "price" => 100, "group" => roll.pk)),
               (Juango.serial_label(DtrPerson), bob.pk, Dict("name" => "Bob")), (Juango.serial_label(DtrGroup), roll.pk, Dict("name" => "Roll"))])
    # (the XML dump: the format is covered by django_serializers.jl)
  end
end

@testset "django m2m_through_regress: ToFieldThroughTests" begin
    Car, Driver = DtrCar, DtrDriver
    function each(f)
        port_block() do
            car = create(Car; make = "Toyota"); driver = create(Driver; name = "Ryan Briscoe")
            create(DtrCarDriver; car = car, driver = driver)
            unused_driver = create(Driver; name = "Barney Gumble")
            create(Car; make = "Trabant"); create(Car; make = "Wartburg")
            f((; car, driver, unused_driver))
        end
    end
    each(x -> @test collect(x.car.drivers) == [x.driver])                             # test_to_field
    each(x -> @test collect(x.driver.dtrcar_set) == [x.car])                          # test_to_field_reverse
    each() do x                                                                       # test_to_field_clear_reverse
        clear!(x.driver.dtrcar_set); @test isempty(x.driver.dtrcar_set)
    end
    each() do x                                                                       # test_to_field_clear
        clear!(x.car.drivers); @test isempty(x.car.drivers)
    end
    # (Django's _add_items/_remove_items are internals: add!/remove! here, which the through model's own rows allow)
    each() do x                                                                       # test_add
        add!(x.car.drivers, x.unused_driver); @test collect(x.car.drivers) == [x.unused_driver, x.driver]
    end
    each() do x                                                                       # test_m2m_relations_unusable_on_null_to_field
        @test_throws ArgumentError("\"None\" needs to have a value for field \"make\" before this many-to-many relationship can be used.") add!(Car(make = nothing).drivers, x.driver)
    end
    each() do x                                                                       # test_m2m_relations_unusable_on_null_pk_obj
        @test_throws ArgumentError("'DtrCar' instance needs to have a primary key value before a many-to-many relationship can be used.") add!(Car(make = "Ford").drivers, x.driver)
    end
    each() do x                                                                       # test_add_related_null
        @test_throws ArgumentError("Cannot add \"None\": the value for field \"driver\" is None") add!(x.car.drivers, Driver(name = nothing))
    end
    each() do x                                                                       # test_add_reverse
        car2 = create(Car; make = "Honda")
        @test collect(x.driver.dtrcar_set) == [x.car]
        add!(x.driver.dtrcar_set, car2)
        @test sort([c.make for c in x.driver.dtrcar_set]) == ["Honda", "Toyota"]
    end
    each() do x                                                                       # test_add_null_reverse
        @test_throws ArgumentError("Cannot add \"None\": the value for field \"car\" is None") add!(x.driver.dtrcar_set, Car(make = nothing))
    end
    each() do x                                                                       # test_add_null_reverse_related
        @test_throws ArgumentError("\"None\" needs to have a value for field \"name\" before this many-to-many relationship can be used.") add!(Driver(name = nothing).dtrcar_set, x.car)
    end
    each() do x                                                                       # test_remove
        remove!(x.car.drivers, x.driver); @test isempty(x.car.drivers)
    end
    each() do x                                                                       # test_remove_reverse
        remove!(x.driver.dtrcar_set, x.car); @test isempty(x.driver.dtrcar_set)
    end
    # (ThroughLoadDataTestCase loads a fixture with the custom-column key of #277: not translated)
end

# --- tests/custom_columns -----------------------------------------------------------------------------
@testset "django custom_columns: CustomColumnsTests" begin
  port_block() do
    A = DccAuthor
    a1 = create(A; first_name = "John", last_name = "Smith")
    a2 = create(A; first_name = "Peter", last_name = "Jones")
    article = create(DccArticle; headline = "Django lets you build web apps easily", primary_author = a1)
    set!(article.authors, [a1, a2])
    @test collect(objects(A)) == [a2, a1]                                                      # test_query_all_available_authors
    @test get(A; first_name__exact = "John") == a1                                    # test_get_first_name, test_author_get
    @test collect(filter(A; first_name__exact = "John")) == [a1]                      # test_filter_first_name, test_author_filtering
    # test_field_error, test_filter_on_nonexistent_field: the column's name isn't a keyword (Django: Author_ID, article, ...)
    e = try collect(filter(A; firstname__exact = "John")); nothing catch e; e end
    @test e isa Juango.LookupError && occursin("'firstname'", e.msg) && occursin("Choices are: dccarticle, first_name, id, last_name, primary_set", e.msg)
    # test_attribute_error, test_author_get_attributes
    a = get(A; last_name__exact = "Smith")
    @test a.first_name == "John" && a.last_name == "Smith"
    @test_throws Exception a.firstname
    @test_throws Exception a.last
    @test collect(article.authors) == [a2, a1]                                       # test_get_all_authors_for_an_article
    @test [x.headline for x in a1.dccarticle_set] == ["Django lets you build web apps easily"]   # test_get_all_articles_for_an_author
    @test collect(filter(article.authors; last_name = "Jones")) == [a2]              # test_get_author_m2m_relation
    @test collect(order_by(objects(A), "last_name")) == [a2, a1]                     # test_author_querying
    @test collect(order_by(article.authors, "last_name")) == [a2, a1]                # test_m2m_table
    @test collect(a1.dccarticle_set) == [article]
    @test collect(a1.primary_set) == [article]
    # the custom names are what the database has
    @test Juango.modelmeta(through(DccArticle, :authors)).table == "my_m2m_table"
    @test length(Juango.execute("SELECT * FROM " * Juango.qname("my_m2m_table"))) == 2
    @test length(Juango.execute("SELECT " * Juango.qname("firstname") * ", " * Juango.qname("last") * " FROM " * Juango.qname("my_author_table"))) == 2
    @test only(Juango.execute("SELECT " * Juango.qname("Author ID") * " AS a FROM " * Juango.qname("dcc_article")))[:a] == a1.pk
  end
end

# --- tests/custom_methods -----------------------------------------------------------------------------
@testset "django custom_methods" begin
  port_block() do                     # test_custom_methods
    a = create(DcxArticle; headline = "Parrot programs in Python", pub_date = Date(2005, 7, 27))
    b = create(DcxArticle; headline = "Beatles reunite", pub_date = Date(2005, 7, 27))
    @test !was_published_today(a)
    @test [x.headline for x in articles_from_same_day_1(a)] == ["Beatles reunite"]
    @test [x.headline for x in articles_from_same_day_2(a)] == ["Beatles reunite"]
    @test [x.headline for x in articles_from_same_day_1(b)] == ["Parrot programs in Python"]
    @test [x.headline for x in articles_from_same_day_2(b)] == ["Parrot programs in Python"]
  end
end

# --- tests/reserved_names -----------------------------------------------------------------------------
@testset "django reserved_names: ReservedNameTests" begin
    T = DrnThing
    generate() = (create(T; when = "a", join = "b", like = "c", drop = "d", alter = "e", having = "f", where_date = Date(2005, 1, 1), has_hyphen = "h");
                  create(T; when = "h", join = "i", like = "j", drop = "k", alter = "l", having = "m", where_date = Date(2006, 2, 2)))
    port_block() do                   # test_simple
        t = create(T; when = "a", join = "b", like = "c", drop = "d", alter = "e", having = "f", where_date = Date(2005, 1, 1), has_hyphen = "h")
        @test t.when == "a"
        u = create(T; when = "h", join = "i", like = "j", drop = "k", alter = "l", having = "m", where_date = Date(2006, 2, 2))
        @test u.when == "h"
    end
    port_block() do
        generate()
        @test [t.when for t in order_by(objects(T), "when")] == ["a", "h"]                      # test_order_by
        v = get(T; pk = "a")                                                                    # test_fields
        @test v.join == "b" && v.where_date == Date(2005, 1, 1) && v.has_hyphen == "h"
        @test collect(dates(T, :where_date, :year)) == [Date(2005, 1, 1), Date(2006, 1, 1)]         # test_dates
        @test first(filter(T; where_date__month = 1)).when == "a"                                   # test_month_filter
        @test [t.when for t in order_by(filter(T; has_hyphen = "h", like__in = ["c", "j"]), "-having")] == ["a"]
    end
end

# --- tests/datatypes ----------------------------------------------------------------------------------
@testset "django datatypes: DataTypesTestCase" begin
    D = DtyDonut
    port_block() do                   # test_boolean_type
        d = D(name = "Apple Fritter")
        @test d.is_frosted == false && d.has_sprinkles === nothing
        d.has_sprinkles = true
        @test d.has_sprinkles == true
        save!(d)
        d2 = get(D; name = "Apple Fritter")
        @test d2.is_frosted == false && d2.has_sprinkles == true
    end
    port_block() do                   # test_date_type
        save!(D(name = "Apple Fritter", baked_date = Date(1938, 6, 4), baked_time = Time(5, 30), consumed_at = DateTime(2007, 4, 20, 16, 19, 59)))
        d2 = get(D; name = "Apple Fritter")
        @test d2.baked_date == Date(1938, 6, 4) && d2.baked_time == Time(5, 30) && d2.consumed_at == DateTime(2007, 4, 20, 16, 19, 59)
    end
    port_block() do                   # test_time_field (#12059): a datetime given to a TimeField keeps its time
        d = D(name = "Apple Fritter"); d.baked_time = DateTime(2007, 4, 20, 16, 19, 59); save!(d)
        @test get(D; name = "Apple Fritter").baked_time == Time(16, 19, 59)
    end
    port_block() do                   # test_year_boundaries (#3689)
        create(D; name = "Date Test 2007", baked_date = Date(2007, 12, 31), consumed_at = DateTime(2007, 12, 31, 23, 59, 59))
        create(D; name = "Date Test 2006", baked_date = Date(2006, 1, 1), consumed_at = DateTime(2006, 1, 1))
        @test first(filter(D; baked_date__year = 2007)).name == "Date Test 2007"
        @test first(filter(D; baked_date__year = 2006)).name == "Date Test 2006"
        create(D; name = "Apple Fritter", consumed_at = DateTime(2007, 4, 20, 16, 19, 59))
        @test collect(values_list(order_by(filter(D; consumed_at__year = 2007), "name"), :name; flat = true)) == ["Apple Fritter", "Date Test 2007"]
        @test count(filter(D; consumed_at__year = 2005)) == 0 && count(filter(D; consumed_at__year = 2008)) == 0
    end
    port_block() do                   # test_textfields_str
        d = create(D; name = "Jelly Donut", review = "Outstanding")
        @test get(D; id = d.id).review isa AbstractString
    end
    # (test_error_on_timezone: Django refuses an aware datetime when the database has no time zones and USE_TZ is off;
    # Juango's handling of aware datetimes is django_timezones.jl's)
    port_block() do                   # test_datefield_auto_now_add (#10970)
        b = create(DtyRumBaba)
        @test b.baked_timestamp isa DateTime && b.baked_date isa Date
    end
end

# --- tests/properties ---------------------------------------------------------------------------------
@testset "django properties: PropertyTests" begin
  port_block() do
    a = create(DprPerson; first_name = "John", last_name = "Lennon")
    @test full_name(a) == "John Lennon"                                               # test_getter
    # test_setter: a name that isn't a field can't be set or given (Python's read-only property; a Julia function here)
    @test_throws Exception (a.full_name = "Paul McCartney")
    @test_throws Exception DprPerson(full_name = "Paul McCartney")
    # (full_name_2, a Python property with a setter: not translated)
  end
end

# --- tests/str ----------------------------------------------------------------------------------------
@testset "django str: SimpleTests" begin
  port_block() do
    a = create(DstInternationalArticle; headline = "Girl wins €12.500 in lottery", pub_date = DateTime(2005, 7, 28))   # test_international
    @test string(a) == "Girl wins €12.500 in lottery"
    obj = DstDefault()                                                                # test_defaults (Django's "(None)")
    @test string(obj) == "DstDefault object (unsaved)" && repr(MIME"text/plain"(), obj) == "<DstDefault: DstDefault object (unsaved)>"
    obj2 = DstDefault(id = 100)
    @test string(obj2) == "DstDefault object (100)" && repr(MIME"text/plain"(), obj2) == "<DstDefault: DstDefault object (100)>"
  end
end
