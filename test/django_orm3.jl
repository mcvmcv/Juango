# More of Django's ORM tests, ported (#227): tests/m2o_recursive, m2m_recursive, many_to_one_null, reverse_lookup,
# mutually_referential, null_fk_ordering, string_lookup, max_lengths, empty, save_delete_hooks, force_insert_update,
# select_related_onetoone, nested_foreign_keys, distinct_on_fields.
# julia --project=test test/django_orm3.jl   (see setup.jl)
#
# As django_orm.jl: Django's models and data, translated to Juango's API; each test keeps its Django name in a
# comment. (tests/get_object_or_404 is in django_shortcuts.jl.)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# --- tests/m2o_recursive/models.py --------------------------------------------------------------------
@model struct DmrCategory
    name = CharField(max_length = 20)
    parent = ForeignKey(:self; on_delete = :SET_NULL, blank = true, null = true, related_name = :child_set)
    Meta(table = "dmr_category")
end
@model struct DmrPerson
    full_name = CharField(max_length = 20)
    mother = ForeignKey(:self; on_delete = :SET_NULL, null = true, related_name = :mothers_child_set)
    father = ForeignKey(:self; on_delete = :SET_NULL, null = true, related_name = :fathers_child_set)
    Meta(table = "dmr_person")
end
# --- tests/m2m_recursive/models.py --------------------------------------------------------------------
@model struct DmmPerson
    name = CharField(max_length = 20)
    friends = ManyToManyField(:self)
    colleagues = ManyToManyField(:self; symmetrical = true, through = :DmmColleague)
    idols = ManyToManyField(:self; symmetrical = false, related_name = :stalkers)
    Meta(table = "dmm_person")
end
@model struct DmmColleague
    first = ForeignKey(DmmPerson; on_delete = :CASCADE)
    second = ForeignKey(DmmPerson; on_delete = :CASCADE, related_name = Symbol("+"))
    first_meet = DateField()
    Meta(table = "dmm_colleague")
end
# --- tests/many_to_one_null/models.py -----------------------------------------------------------------
@model struct DmnReporter
    name = CharField(max_length = 30)
    Meta(table = "dmn_reporter")
end
@model struct DmnArticle
    headline = CharField(max_length = 100)
    reporter = ForeignKey(DmnReporter; on_delete = :SET_NULL, null = true)
    Meta(table = "dmn_article", ordering = ["headline"])
end
@model struct DmnCar
    make = CharField(max_length = 100, null = true, unique = true)
    Meta(table = "dmn_car")
end
@model struct DmnDriver
    car = ForeignKey(DmnCar; on_delete = :SET_NULL, to_field = :make, null = true, related_name = :drivers)
    Meta(table = "dmn_driver")
end
# --- tests/reverse_lookup/models.py -------------------------------------------------------------------
@model struct DrlUser
    name = CharField(max_length = 200)
    Meta(table = "drl_user")
end
@model struct DrlPoll
    question = CharField(max_length = 200)
    creator = ForeignKey(DrlUser; on_delete = :CASCADE)
    Meta(table = "drl_poll")
end
@model struct DrlChoice
    name = CharField(max_length = 100)
    poll = ForeignKey(DrlPoll; on_delete = :CASCADE, related_name = :poll_choice)
    related_poll = ForeignKey(DrlPoll; on_delete = :CASCADE, related_name = :related_choice)
    Meta(table = "drl_choice")
end
# --- tests/mutually_referential/models.py -------------------------------------------------------------
@model struct DmuParent
    name = CharField(max_length = 100)
    bestchild = ForeignKey(:DmuChild; on_delete = :SET_NULL, null = true, related_name = :favored_by)
    Meta(table = "dmu_parent")
end
@model struct DmuChild
    name = CharField(max_length = 100)
    parent = ForeignKey(DmuParent; on_delete = :CASCADE)
    Meta(table = "dmu_child")
end
# --- tests/null_fk_ordering/models.py -----------------------------------------------------------------
@model struct DnoAuthor
    name = CharField(max_length = 150)
    Meta(table = "dno_author")
end
@model struct DnoArticle
    title = CharField(max_length = 150)
    author = ForeignKey(DnoAuthor; on_delete = :SET_NULL, null = true)
    Meta(table = "dno_article", ordering = ["author__name"])
end
@model struct DnoSystemInfo
    system_name = CharField(max_length = 32)
    Meta(table = "dno_systeminfo")
end
@model struct DnoForum
    system_info = ForeignKey(DnoSystemInfo; on_delete = :CASCADE)
    forum_name = CharField(max_length = 32)
    Meta(table = "dno_forum")
end
@model struct DnoPost
    forum = ForeignKey(DnoForum; on_delete = :SET_NULL, null = true)
    title = CharField(max_length = 32)
    Meta(table = "dno_post")
end
@model struct DnoComment
    post = ForeignKey(DnoPost; on_delete = :SET_NULL, null = true)
    comment_text = CharField(max_length = 250)
    Meta(table = "dno_comment", ordering = ["post__forum__system_info__system_name", "comment_text"])
end
# --- tests/string_lookup/models.py --------------------------------------------------------------------
@model struct DslFoo
    name = CharField(max_length = 50)
    friend = CharField(max_length = 50, blank = true)
    Meta(table = "dsl_foo")
end
@model struct DslBar
    name = CharField(max_length = 50)
    normal = ForeignKey(DslFoo; on_delete = :CASCADE, related_name = :normal_foo)
    fwd = ForeignKey(:DslWhiz; on_delete = :CASCADE)
    back = ForeignKey(:DslFoo; on_delete = :CASCADE)
    Meta(table = "dsl_bar")
end
@model struct DslWhiz
    name = CharField(max_length = 50)
    Meta(table = "dsl_whiz")
end
@model struct DslChild
    parent = OneToOneField(:DslBase; on_delete = :CASCADE)
    name = CharField(max_length = 50)
    Meta(table = "dsl_child")
end
@model struct DslBase
    name = CharField(max_length = 50)
    Meta(table = "dsl_base")
end
@model struct DslArticle
    name = CharField(max_length = 50)
    text = TextField()
    submitted_from = GenericIPAddressField(blank = true, null = true)
    Meta(table = "dsl_article")
end
# --- tests/max_lengths/models.py ----------------------------------------------------------------------
@model struct DmlPersonWithDefaultMaxLengths
    email = EmailField()
    vcard = FileField()
    homepage = URLField()
    avatar = FilePathField()
    Meta(table = "dml_personwithdefaultmaxlengths")
end
@model struct DmlPersonWithCustomMaxLengths
    email = EmailField(max_length = 250)
    vcard = FileField(max_length = 250)
    homepage = URLField(max_length = 250)
    avatar = FilePathField(max_length = 250)
    Meta(table = "dml_personwithcustommaxlengths")
end
# --- tests/empty/models.py, tests/save_delete_hooks/models.py -----------------------------------------
@model struct DemEmpty
    Meta(table = "dem_empty")
end
@model struct DsdPerson
    first_name = CharField(max_length = 20)
    last_name = CharField(max_length = 20)
    Meta(table = "dsd_person")
end
Base.show(io::IO, p::DsdPerson) = print(io, p.first_name, " ", p.last_name)
# (Django keeps the list on the instance; here a list per object)
const DSD_DATA = IdDict{Any,Vector{String}}()
dsd_data(p) = get!(Vector{String}, DSD_DATA, p)
function Juango.save!(p::DsdPerson; kw...)
    push!(dsd_data(p), "Before save")
    invoke(Juango.save!, Tuple{Juango.Model}, p; kw...)
    push!(dsd_data(p), "After save")
    p
end
function Base.delete!(p::DsdPerson; kw...)
    push!(dsd_data(p), "Before deletion")
    r = invoke(Base.delete!, Tuple{Juango.Model}, p; kw...)
    push!(dsd_data(p), "After deletion")
    r
end

# --- tests/force_insert_update/models.py --------------------------------------------------------------
@model struct DfiCounter
    name = CharField(max_length = 10)
    value = IntegerField()
    Meta(table = "dfi_counter")
end
@model struct DfiInheritedCounter <: DfiCounter
    tag = CharField(max_length = 10)
    Meta(table = "dfi_inheritedcounter")
end
@model struct DfiProxyCounter <: DfiCounter
    Meta(proxy = true)
end
@model struct DfiSubCounter <: DfiCounter
    Meta(table = "dfi_subcounter")
end
@model struct DfiSubSubCounter <: DfiSubCounter
    Meta(table = "dfi_subsubcounter")
end
@model struct DfiWithCustomPK
    name = IntegerField(primary_key = true)
    value = IntegerField()
    Meta(table = "dfi_withcustompk")
end

# --- tests/select_related_onetoone/models.py ----------------------------------------------------------
@model struct DsoUser
    username = CharField(max_length = 100)
    email = EmailField()
    Meta(table = "dso_user")
end
@model struct DsoUserProfile
    user = OneToOneField(DsoUser; on_delete = :CASCADE)
    city = CharField(max_length = 100)
    state = CharField(max_length = 2)
    Meta(table = "dso_userprofile")
end
@model struct DsoUserStatResult
    results = CharField(max_length = 50)
    Meta(table = "dso_userstatresult")
end
@model struct DsoUserStat
    user = OneToOneField(DsoUser; on_delete = :CASCADE, primary_key = true)
    posts = IntegerField()
    results = ForeignKey(DsoUserStatResult; on_delete = :CASCADE)
    Meta(table = "dso_userstat")
end
@model struct DsoStatDetails
    base_stats = OneToOneField(DsoUserStat; on_delete = :CASCADE)
    comments = IntegerField()
    Meta(table = "dso_statdetails")
end
@model struct DsoImage
    name = CharField(max_length = 100)
    Meta(table = "dso_image")
end
@model struct DsoProduct
    name = CharField(max_length = 100)
    image = OneToOneField(DsoImage; on_delete = :SET_NULL, null = true)
    Meta(table = "dso_product")
end
@model struct DsoParent1
    name1 = CharField(max_length = 50)
    Meta(table = "dso_parent1")
end
@model struct DsoParent2
    name2 = CharField(max_length = 50)
    Meta(table = "dso_parent2")
end
@model struct DsoChild2 <: DsoParent1
    parent2 = OneToOneField(DsoParent2; on_delete = :CASCADE)
    value = IntegerField()
    Meta(table = "dso_child2")
end
@model struct DsoChild3 <: DsoChild2
    value3 = IntegerField()
    Meta(table = "dso_child3")
end
@model struct DsoLinkedList
    name = CharField(max_length = 50)
    previous_item = OneToOneField(:self; on_delete = :CASCADE, related_name = :next_item, blank = true, null = true)
    Meta(table = "dso_linkedlist")
end

# --- tests/nested_foreign_keys/models.py --------------------------------------------------------------
@model struct DnkPerson
    name = CharField(max_length = 200)
    Meta(table = "dnk_person")
end
@model struct DnkMovie
    title = CharField(max_length = 200)
    director = ForeignKey(DnkPerson; on_delete = :CASCADE)
    Meta(table = "dnk_movie")
end
@model struct DnkEvent
    Meta(table = "dnk_event")
end
@model struct DnkScreening <: DnkEvent
    movie = ForeignKey(DnkMovie; on_delete = :CASCADE)
    Meta(table = "dnk_screening")
end
@model struct DnkScreeningNullFK <: DnkEvent
    movie = ForeignKey(DnkMovie; on_delete = :SET_NULL, null = true)
    Meta(table = "dnk_screeningnullfk")
end
@model struct DnkPackage
    screening = ForeignKey(DnkScreening; on_delete = :SET_NULL, null = true)
    Meta(table = "dnk_package")
end
@model struct DnkPackageNullFK
    screening = ForeignKey(DnkScreeningNullFK; on_delete = :SET_NULL, null = true)
    Meta(table = "dnk_packagenullfk")
end

# --- tests/distinct_on_fields/models.py ---------------------------------------------------------------
@model struct DdoTag
    name = CharField(max_length = 10)
    parent = ForeignKey(:self; on_delete = :SET_NULL, blank = true, null = true, related_name = :children)
    Meta(table = "ddo_tag", ordering = ["name"])
end
@model struct DdoCelebrity
    name = CharField(max_length = 20, verbose_name = "Name")
    greatest_fan = ForeignKey(:DdoFan; on_delete = :SET_NULL, null = true, unique = true)
    Meta(table = "ddo_celebrity")
end
@model struct DdoFan
    fan_of = ForeignKey(DdoCelebrity; on_delete = :CASCADE)
    Meta(table = "ddo_fan")
end
@model struct DdoStaff
    name = CharField(max_length = 50)
    organisation = CharField(max_length = 100)
    tags = ManyToManyField(DdoTag; through = :DdoStaffTag)
    coworkers = ManyToManyField(:self)
    Meta(table = "ddo_staff")
end
@model struct DdoStaffTag
    staff = ForeignKey(DdoStaff; on_delete = :CASCADE)
    tag = ForeignKey(DdoTag; on_delete = :CASCADE)
    Meta(table = "ddo_stafftag")
end

redirect_stdout(devnull) do
    ms = [DmrCategory, DmrPerson, DmmPerson, DmmColleague, through(DmmPerson, :friends), through(DmmPerson, :idols),
          DmnReporter, DmnArticle, DmnCar, DmnDriver, DrlUser, DrlPoll, DrlChoice, DmuParent, DmuChild,
          DnoAuthor, DnoArticle, DnoSystemInfo, DnoForum, DnoPost, DnoComment,
          DslFoo, DslWhiz, DslBar, DslBase, DslChild, DslArticle, DmlPersonWithDefaultMaxLengths, DmlPersonWithCustomMaxLengths,
          DemEmpty, DsdPerson, DfiCounter, DfiInheritedCounter, DfiSubCounter, DfiSubSubCounter, DfiWithCustomPK,
          DsoUser, DsoUserProfile, DsoUserStatResult, DsoUserStat, DsoStatDetails, DsoImage, DsoProduct, DsoParent1, DsoParent2,
          DsoChild2, DsoChild3, DsoLinkedList,
          DnkPerson, DnkMovie, DnkEvent, DnkScreening, DnkScreeningNullFK, DnkPackage, DnkPackageNullFK,
          DdoTag, DdoCelebrity, DdoFan, DdoStaff, DdoStaffTag, through(DdoStaff, :coworkers)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
pks(qs) = [o.pk for o in qs]
# Django's TestCase runs each test in a transaction, so the atomic blocks of what it counts send no BEGIN/COMMIT
# (Juango counts those): a count of queries is taken inside one here
in_test_tx(f) = atomic(f)

# --- tests/m2o_recursive ------------------------------------------------------------------------------
@testset "django m2o_recursive" begin
  port_block() do                     # ManyToOneRecursiveTests.test_m2o_recursive
    r = create(DmrCategory; name = "Root category", parent = nothing)
    c = create(DmrCategory; name = "Child category", parent = r)
    @test pks(r.child_set) == [c.pk]
    @test get(r.child_set; name__startswith = "Child").id == c.id
    @test r.parent === nothing
    @test isempty(c.child_set)
    @test c.parent.id == r.id
  end
  port_block() do                     # MultipleManyToOneRecursiveTests.test_m2o_recursive2
    dad = create(DmrPerson; full_name = "John Smith Senior", mother = nothing, father = nothing)
    mom = create(DmrPerson; full_name = "Jane Smith", mother = nothing, father = nothing)
    kid = create(DmrPerson; full_name = "John Smith Junior", mother = mom, father = dad)
    @test kid.mother.id == mom.id && kid.father.id == dad.id
    @test pks(dad.fathers_child_set) == [kid.pk] && pks(mom.mothers_child_set) == [kid.pk]
    @test isempty(kid.mothers_child_set) && isempty(kid.fathers_child_set)
  end
end

# --- tests/m2m_recursive ------------------------------------------------------------------------------
@testset "django m2m_recursive: RecursiveM2MTests" begin
    function each(f)
        port_block() do
            a, b, c, d = (create(DmmPerson; name = n) for n in ("Anne", "Bill", "Chuck", "David"))
            add!(a.friends, b, c); add!(d.friends, a, c)
            f(a, b, c, d)
        end
    end
    byname(qs) = pks(order_by(qs, "name"))
    each() do a, b, c, d          # test_recursive_m2m_all
        @test byname(a.friends) == pks([b, c, d]) && byname(b.friends) == pks([a])
        @test byname(c.friends) == pks([a, d]) && byname(d.friends) == pks([a, c])
    end
    each() do a, b, c, d          # test_recursive_m2m_reverse_add
        add!(b.friends, a)
        @test byname(a.friends) == pks([b, c, d]) && pks(b.friends) == [a.pk]
    end
    each() do a, b, c, d          # test_recursive_m2m_remove
        remove!(b.friends, a)
        @test byname(a.friends) == pks([c, d]) && isempty(b.friends)
    end
    each() do a, b, c, d          # test_recursive_m2m_clear
        clear!(a.friends)
        @test isempty(a.friends) && pks(c.friends) == [d.pk] && pks(d.friends) == [c.pk]
    end
    each() do a, b, c, d          # test_recursive_m2m_add_via_related_name
        add!(d.stalkers, a)
        @test pks(a.idols) == [d.pk] && isempty(a.stalkers)
    end
    each() do a, b, c, d          # test_recursive_m2m_add_in_both_directions
        add!(a.idols, d); add!(d.stalkers, a)
        @test pks(a.idols) == [d.pk]
    end
    each() do a, b, c, d          # test_recursive_m2m_related_to_self
        add!(a.idols, a)
        @test pks(a.idols) == [a.pk] && pks(a.stalkers) == [a.pk]
    end
end

@testset "django m2m_recursive: RecursiveSymmetricalM2MThroughTests" begin
    function each(f)
        port_block() do
            a, b, c, d = (create(DmmPerson; name = n) for n in ("Anne", "Bill", "Chuck", "David"))
            add!(a.colleagues, b, c; through_defaults = Dict(:first_meet => Date(2013, 1, 5)))
            add!(d.colleagues, a, c; through_defaults = Dict(:first_meet => Date(2015, 6, 15)))
            f(a, b, c, d)
        end
    end
    byname(qs) = pks(order_by(qs, "name"))
    each() do a, b, c, d          # test_recursive_m2m_all
        @test byname(a.colleagues) == pks([b, c, d]) && byname(b.colleagues) == pks([a])
        @test byname(c.colleagues) == pks([a, d]) && byname(d.colleagues) == pks([a, c])
    end
    each() do a, b, c, d          # test_recursive_m2m_reverse_add
        add!(b.colleagues, a; through_defaults = Dict(:first_meet => Date(2013, 1, 5)))
        @test sort(pks(a.colleagues)) == sort(pks([b, c, d])) && pks(b.colleagues) == [a.pk]
    end
    each() do a, b, c, d          # test_recursive_m2m_remove
        remove!(b.colleagues, a)
        @test byname(a.colleagues) == pks([c, d]) && isempty(b.colleagues)
    end
    each() do a, b, c, d          # test_recursive_m2m_clear
        clear!(a.colleagues)
        @test isempty(a.friends) && pks(c.colleagues) == [d.pk] && pks(d.colleagues) == [c.pk]
    end
    each() do a, b, c, d          # test_recursive_m2m_set
        set!(c.colleagues, [b, d]; through_defaults = Dict(:first_meet => Date(2013, 1, 5)))
        @test byname(c.colleagues) == pks([b, d]) && byname(a.colleagues) == pks([b, d])
    end
end

# --- tests/many_to_one_null ---------------------------------------------------------------------------
@testset "django many_to_one_null: ManyToOneNullTests" begin
    A, R = DmnArticle, DmnReporter
    heads(qs) = [x.headline for x in qs]
    function each(f)
        port_block() do
            r = DmnReporter(name = "John Smith"); save!(r)
            a = A(headline = "First", reporter = r); save!(a)
            a2 = create(r.dmnarticle_set; headline = "Second")
            a3 = A(headline = "Third", reporter = nothing); save!(a3)
            r2 = DmnReporter(name = "Paul Jones"); save!(r2)
            a4 = create(r2.dmnarticle_set; headline = "Fourth")
            f((; r, a, a2, a3, r2, a4))
        end
    end
    each() do x                   # test_get_related, test_created_via_related_set
        @test x.a.reporter.id == x.r.id && x.a2.reporter.id == x.r.id
    end
    each() do x                   # test_related_set
        @test heads(x.r.dmnarticle_set) == ["First", "Second"]
        @test heads(filter(x.r.dmnarticle_set; headline__startswith = "Fir")) == ["First"]
        @test count(x.r.dmnarticle_set) == 2
    end
    each() do x                   # test_created_without_related
        @test x.a3.reporter === nothing
        a3 = get(A; pk = x.a3.pk)
        @test a3.reporter === nothing
        @test heads(filter(A; reporter__isnull = true)) == ["Third"]
        @test heads(filter(A; reporter = nothing)) == ["Third"]
        add!(x.r.dmnarticle_set, a3)
        @test heads(x.r.dmnarticle_set) == ["First", "Second", "Third"]
        remove!(x.r.dmnarticle_set, a3)
        @test heads(x.r.dmnarticle_set) == ["First", "Second"]
        @test heads(filter(A; reporter__isnull = true)) == ["Third"]
    end
    each() do x                   # test_remove_from_wrong_set
        @test heads(x.r2.dmnarticle_set) == ["Fourth"]
        e = try remove!(x.r.dmnarticle_set, x.a4); nothing catch e; e end
        @test e isa Juango.DoesNotExist && e.model === DmnReporter        # (Django's Reporter.DoesNotExist)
        @test heads(x.r2.dmnarticle_set) == ["Fourth"]
    end
    each() do x                   # test_set
        set!(x.r2.dmnarticle_set, [x.a2, x.a3])
        @test heads(x.r2.dmnarticle_set) == ["Second", "Third"]
        set!(x.r2.dmnarticle_set, [x.a3, x.a4]; clear = true)
        @test heads(x.r2.dmnarticle_set) == ["Fourth", "Third"]
        set!(x.r2.dmnarticle_set, [])
        @test isempty(x.r2.dmnarticle_set)
        @test heads(filter(A; reporter__isnull = true)) == ["Fourth", "Second", "Third"]
    end
    each() do x                   # test_set_clear_non_bulk
        @test in_test_tx(() -> assert_num_queries(() -> set!(x.r.dmnarticle_set, [x.a]; bulk = false, clear = true), 4))
    end
    each() do x                   # test_assign_clear_related_set
        set!(x.r2.dmnarticle_set, [x.a2, x.a3])
        @test heads(x.r2.dmnarticle_set) == ["Second", "Third"]
        clear!(x.r.dmnarticle_set)
        @test isempty(x.r.dmnarticle_set)
        @test heads(filter(A; reporter__isnull = true)) == ["First", "Fourth"]
    end
    each() do x                   # test_assign_with_queryset
        set!(x.r2.dmnarticle_set, [x.a2, x.a3])
        qs = filter(x.r2.dmnarticle_set; headline = "Second")
        set!(x.r2.dmnarticle_set, qs)
        @test count(x.r2.dmnarticle_set) == 1 && count(qs) == 1
    end
    each() do _                   # test_add_efficiency
        r = create(R; name = "")
        articles = [create(A; headline = "") for _ in 1:3]
        @test assert_num_queries(() -> add!(r.dmnarticle_set, articles...), 1)
        @test count(r.dmnarticle_set) == 3
    end
    each() do _                   # test_clear_efficiency
        r = create(R; name = "")
        foreach(_ -> create(r.dmnarticle_set; headline = ""), 1:3)
        @test assert_num_queries(() -> clear!(r.dmnarticle_set), 1)
        @test count(r.dmnarticle_set) == 0
    end
    each() do _                   # test_related_null_to_field
        c1 = create(DmnCar); d1 = create(DmnDriver)
        @test d1.car === nothing
        @test assert_num_queries(() -> isempty(collect(c1.drivers)), 0)
    end
    each() do _                   # test_related_null_to_field_related_managers
        car = create(DmnCar; make = nothing); driver = create(DmnDriver)
        msg = "\"$(repr(car))\" needs to have a value for field \"make\" before this relationship can be used."
        for op in (() -> add!(car.drivers, driver), () -> create(car.drivers), () -> get_or_create(car.drivers),
                   () -> update_or_create(car.drivers), () -> remove!(car.drivers, driver), () -> clear!(car.drivers),
                   () -> set!(car.drivers, [driver]))
            @test_throws ArgumentError(msg) op()
        end
        @test assert_num_queries(() -> count(car.drivers) == 0, 0)
    end
    # test_unsaved: Car(make = "Ford").drivers raising "'Car' instance needs to have a primary key value before this
    # relationship can be used." is #274 (Juango gives an empty queryset)
    @test_broken try collect(DmnCar(make = "Ford").drivers); false catch e; e isa ArgumentError end
end

# --- tests/reverse_lookup -----------------------------------------------------------------------------
@testset "django reverse_lookup: ReverseLookupTests" begin
  port_block() do
    john = create(DrlUser; name = "John Doe"); jim = create(DrlUser; name = "Jim Bo")
    first_poll = create(DrlPoll; question = "What's the first question?", creator = john)
    second_poll = create(DrlPoll; question = "What's the second question?", creator = jim)
    create(DrlChoice; poll = first_poll, related_poll = second_poll, name = "This is the answer.")
    # test_reverse_by_field
    @test get(DrlUser; drlpoll__question__exact = "What's the first question?").name == "John Doe"
    @test get(DrlUser; drlpoll__question__exact = "What's the second question?").name == "Jim Bo"
    # test_reverse_by_related_name
    @test get(DrlPoll; poll_choice__name__exact = "This is the answer.").question == "What's the first question?"
    @test get(DrlPoll; related_choice__name__exact = "This is the answer.").question == "What's the second question?"
    # test_reverse_field_name_disallowed: with a related_name, the model's name isn't a keyword (Juango accepts it, #275)
    e = try get(DrlPoll; drlchoice__name__exact = "This is the answer"); nothing catch e; e end
    @test_broken e isa Juango.LookupError &&
          occursin("Choices are: creator, creator_id, id, poll_choice, question, related_choice", e.msg)
    e = try get(DrlPoll; nosuchname__name__exact = "x"); nothing catch e; e end                  # (the choices, as Django's)
    @test e isa Juango.LookupError && occursin("Choices are: creator, creator_id, id, poll_choice, question, related_choice", e.msg)
  end
end

# --- tests/mutually_referential, tests/null_fk_ordering, tests/empty, tests/save_delete_hooks ------------
@testset "django mutually_referential, null_fk_ordering, empty, save_delete_hooks" begin
  port_block() do                     # MutuallyReferentialTests.test_mutually_referential
    q = DmuParent(name = "Elizabeth"); save!(q)
    c = create(q.dmuchild_set; name = "Charles")
    create(q.dmuchild_set; name = "Edward")
    q.bestchild = c; save!(q)
    delete!(q)
    @test !exists(objects(DmuParent)) && !exists(objects(DmuChild))
  end
  port_block() do                     # NullFkOrderingTests.test_ordering_across_null_fk
    author_1 = create(DnoAuthor; name = "Tom Jones"); author_2 = create(DnoAuthor; name = "Bob Smith")
    create(DnoArticle; title = "No author on this article")
    create(DnoArticle; author = author_1, title = "This article written by Tom Jones")
    create(DnoArticle; author = author_2, title = "This article written by Bob Smith")
    @test length(collect(objects(DnoArticle))) == 3
    s = create(DnoSystemInfo; system_name = "System Info")
    f = create(DnoForum; system_info = s, forum_name = "First forum")
    p = create(DnoPost; forum = f, title = "First Post")
    create(DnoComment; post = p, comment_text = "My first comment")
    create(DnoComment; comment_text = "My second comment")
    s2 = create(DnoSystemInfo; system_name = "More System Info")
    f2 = create(DnoForum; system_info = s2, forum_name = "Second forum")
    p2 = create(DnoPost; forum = f2, title = "Second Post")
    create(DnoComment; comment_text = "Another first comment")
    create(DnoComment; post = p2, comment_text = "Another second comment")
    @test length(collect(objects(DnoComment))) == 4
  end
  port_block() do                     # EmptyModelTests.test_empty
    m = DemEmpty()
    @test m.id === nothing
    save!(m)
    create(DemEmpty)
    @test length(collect(objects(DemEmpty))) == 2
    @test m.id !== nothing
    existing = DemEmpty(id = m.id); save!(existing)
    @test count(objects(DemEmpty)) == 2
  end
  port_block() do                     # SaveDeleteHookTests.test_basic
    p = DsdPerson(first_name = "John", last_name = "Smith")
    @test isempty(dsd_data(p))
    save!(p)
    @test dsd_data(p) == ["Before save", "After save"]
    @test [repr(x) for x in objects(DsdPerson)] == ["John Smith"]
    delete!(p)
    @test dsd_data(p) == ["Before save", "After save", "Before deletion", "After deletion"]
    @test isempty(objects(DsdPerson))
  end
end

# --- tests/string_lookup, tests/max_lengths -----------------------------------------------------------
@testset "django string_lookup, max_lengths" begin
  port_block() do
    # StringLookupTests.test_string_form_referencing
    f1 = DslFoo(name = "Foo1"); save!(f1); f2 = DslFoo(name = "Foo2"); save!(f2)
    w1 = DslWhiz(name = "Whiz1"); save!(w1)
    b1 = DslBar(name = "Bar1", normal = f1, fwd = w1, back = f2); save!(b1)
    @test b1.normal == f1 && b1.fwd == w1 && b1.back == f2
    base1 = DslBase(name = "Base1"); save!(base1)
    child1 = DslChild(name = "Child1", parent = base1); save!(child1)
    @test child1.parent == base1
    # test_unicode_chars_in_queries
    fx = DslFoo(name = "Bjorn", friend = "François"); save!(fx)
    @test get(DslFoo; friend__contains = "\u00e7") == fx
    # test_queries_on_textfields
    a = DslArticle(name = "Test", text = "The quick brown fox jumps over the lazy dog."); save!(a)
    @test get(DslArticle; text__exact = "The quick brown fox jumps over the lazy dog.") == a
    @test get(DslArticle; text__contains = "quick brown fox") == a
    # test_ipaddress_on_postgresql
    a = DslArticle(name = "IP test", text = "The body", submitted_from = "192.0.2.100"); save!(a)
    @test pks(filter(DslArticle; submitted_from__contains = "192.0.2")) == [a.pk]
    @test count(filter(DslArticle; submitted_from__contains = "32")) == 0
  end
  # MaxLengthArgumentsTests
  ml(M, f) = Juango.getfield_meta(M, f).max_length
  @test [ml(DmlPersonWithDefaultMaxLengths, f) for f in (:email, :vcard, :homepage, :avatar)] == [254, 100, 200, 100]
  @test [ml(DmlPersonWithCustomMaxLengths, f) for f in (:email, :vcard, :homepage, :avatar)] == [250, 250, 250, 250]
  port_block() do                     # MaxLengthORMTests.test_custom_max_lengths
    args = Dict(:email => "someone@example.com", :vcard => "vcard", :homepage => "http://example.com/", :avatar => "me.jpg")
    for field in (:email, :vcard, :homepage, :avatar)
        p = create(DmlPersonWithCustomMaxLengths; merge(args, Dict(field => "X"^250))...)
        v = getproperty(p, field)
        @test (v isa AbstractString ? v : v.name) == "X"^250
    end
  end
end

# --- tests/force_insert_update ------------------------------------------------------------------------
# (OtherSubCounter's own parent link and DiamondSubSubCounter: Juango's multi-table inheritance has one parent
# per model and an automatic parent link, so test_force_insert_diamond_mti isn't translated)
@testset "django force_insert_update: ForceTests, InheritanceTests" begin
  port_block() do                     # ForceTests.test_force_update
    C = DfiCounter
    c = create(C; name = "one", value = 1)
    c.value = 2; save!(c)
    c.value = 3; save!(c; force_update = true)
    c.value = 4
    @test_throws ArgumentError("Cannot force both insert and updating in model saving.") save!(c; force_insert = true, force_update = true)
    c1 = C(name = "two", value = 2)
    @test_throws ArgumentError("Cannot force an update in save() with no primary key.") atomic(() -> save!(c1; force_update = true))
    save!(c1; force_insert = true)
    c.value = 5
    @test_throws Juango.IntegrityError atomic(() -> save!(c; force_insert = true))
    obj = DfiWithCustomPK(name = 1, value = 1)
    e = try atomic(() -> save!(obj; force_update = true)); nothing catch e; e end
    @test e isa Juango.DatabaseError && e.msg == "Forced update did not affect any rows."
  end
  port_block() do                     # InheritanceTests
    a = DfiInheritedCounter(name = "count", value = 1, tag = "spam"); save!(a); save!(a; force_update = true)
    a = DfiProxyCounter(name = "count", value = 1); save!(a); save!(a; force_update = true)
    a = DfiSubCounter(name = "count", value = 1); save!(a)
    a.value = 2; save!(a; force_update = true)                                   # (no fields of its own: #13864)
    @test get(DfiSubCounter; pk = a.pk).value == 2
  end
end

@testset "django force_insert_update: ForceInsertInheritanceTests" begin
    C, S, SS = DfiCounter, DfiSubCounter, DfiSubSubCounter
    nq(f, n) = in_test_tx(() -> assert_num_queries(f, n))
    # a save that INSERTs a new root row with its id given: on PostgreSQL Juango then moves the id sequence past it
    # (one query more; Django leaves the sequence behind, for the next row without an id to collide with)
    nqi(f, n) = nq(f, n + IS_POSTGRES)
    port_block() do                   # test_force_insert_not_bool_or_tuple
        for x in (1, "test", [])
            e = try atomic(() -> save!(C(name = "", value = 0); force_insert = x)); nothing catch e; e end
            @test e isa TypeError && e.context == "force_insert must be a bool or tuple."
        end
    end
    port_block() do                   # test_force_insert_not_model, test_force_insert_not_base
        e = try save!(C(name = "", value = 0); force_insert = (Int,)); nothing catch e; e end
        @test e isa TypeError && e.context == "Invalid force_insert member. Int64 must be a model subclass."
        e = try save!(C(name = "", value = 0); force_insert = (S,)); nothing catch e; e end
        @test e isa TypeError && e.context == "Invalid force_insert member. DfiSubCounter must be a base of DfiCounter."
    end
    port_block() do                   # test_force_insert_false
        obj = nothing
        @test nqi(3) do
            obj = create(S; id = 1, name = "", value = 0); true
        end
        @test nq(() -> save!(S(id = obj.pk, name = "", value = 1)), 2)
        @test refresh!(obj).value == 1
        @test nq(() -> save!(S(id = obj.pk, name = "", value = 2); force_insert = false), 2)
        @test refresh!(obj).value == 2
        @test nq(() -> save!(S(id = obj.pk, name = "", value = 3); force_insert = ()), 2)
        @test refresh!(obj).value == 3
    end
    port_block() do                   # test_force_insert_false_with_existing_parent
        parent = create(C; name = "", value = 1)
        @test_broken try nq(() -> create(S; id = parent.pk, name = "", value = 2), 2) catch; false end   # (create doesn't force an insert: #276)
    end
    port_block() do                   # test_force_insert_parent
        @test nqi(() -> save!(S(id = 1, name = "", value = 1); force_insert = true), 3)
        @test nqi(() -> save!(S(id = 2, name = "", value = 1); force_insert = (C,)), 2)       # a new parent, no UPDATE first
        @test nqi(() -> save!(S(id = 3, name = "", value = 1); force_insert = (Juango.Model,)), 2)
    end
    port_block() do                   # test_force_insert_with_grandparent
        @test nqi(() -> save!(SS(id = 1, name = "", value = 1); force_insert = true), 4)
        @test nqi(() -> save!(SS(id = 2, name = "", value = 1); force_insert = (Juango.Model,)), 3)
        @test nqi(() -> save!(SS(id = 3, name = "", value = 1); force_insert = (C,)), 3)
        @test nqi(() -> save!(SS(id = 4, name = "", value = 1); force_insert = (S,)), 4)     # only the last parent
    end
    port_block() do                   # test_force_insert_with_existing_grandparent
        gp = create(C; name = "", value = 1)
        @test nq(() -> save!(SS(id = gp.pk, name = "", value = 1); force_insert = true), 4)
        gp = create(C; name = "", value = 1)
        @test nq(() -> save!(SS(id = gp.pk, name = "", value = 1); force_insert = (S,)), 3)
        gp = create(C; name = "", value = 1)
        @test_throws Juango.IntegrityError atomic(() -> save!(SS(id = gp.pk, name = "", value = 1); force_insert = (C,)))
    end
end

# --- tests/select_related_onetoone --------------------------------------------------------------------
# (AdvancedUserStat, a child of a model whose key is a one-to-one, and Child1/Child4, children of two parents, aren't
# translated: Juango's multi-table children have one parent with an automatic key; a missing reverse one-to-one is
# nothing in Juango, where Django raises DoesNotExist)
@testset "django select_related_onetoone: ReverseSelectRelatedTestCase" begin
  port_block() do
    user = create(DsoUser; username = "test", email = "")
    create(DsoUserProfile; user = user, state = "KS", city = "Lawrence")
    results = create(DsoUserStatResult; results = "first results")
    userstat = create(DsoUserStat; user = user, posts = 150, results = results)
    create(DsoStatDetails; base_stats = userstat, comments = 259)
    user2 = create(DsoUser; username = "bob", email = "")
    p1 = DsoParent1(name1 = "Only Parent1"); save!(p1)
    p2 = DsoParent2(name2 = "Child2 Parent2"); save!(p2)
    c2 = DsoChild2(name1 = "Child2 Parent1", parent2 = p2, value = 2); save!(c2)
    nq(f, n) = assert_num_queries(f, n)
    sr(paths...) = select_related(objects(DsoUser), paths...)
    @test nq(1) do                                                                    # test_basic
        get(sr(:dsouserprofile); username = "test").dsouserprofile.state == "KS"
    end
    @test nq(1) do                                                                    # test_follow_next_level
        u = get(sr(:dsouserstat__results); username = "test")
        u.dsouserstat.posts == 150 && u.dsouserstat.results.results == "first results"
    end
    @test nq(1) do                                                                    # test_follow_two
        u = get(sr(:dsouserprofile, :dsouserstat); username = "test")
        u.dsouserprofile.state == "KS" && u.dsouserstat.posts == 150
    end
    @test nq(1) do                                                                    # test_follow_two_next_level
        u = get(sr(:dsouserstat__results, :dsouserstat__dsostatdetails); username = "test")
        u.dsouserstat.results.results == "first results" && u.dsouserstat.dsostatdetails.comments == 259
    end
    @test nq(1) do                                                                    # test_forward_and_back
        stat = get(select_related(objects(DsoUserStat), :user__dsouserprofile); user__username = "test")
        stat.user.dsouserprofile.state == "KS" && stat.user.dsouserstat.posts == 150
    end
    @test nq(1) do                                                                    # test_back_and_forward
        get(sr(:dsouserstat); username = "test").dsouserstat.user.username == "test"
    end
    @test nq(2) do                                                                    # test_not_followed_by_default
        get(objects(DsoUser); username = "test").dsouserstat.posts == 150
    end
    im = create(DsoImage; name = "imag1")                                             # test_nullable_relation
    pp1 = create(DsoProduct; name = "Django Plushie", image = im)
    pp2 = create(DsoProduct; name = "Talking Django Plushie")
    @test nq(1) do
        result = sort(collect(select_related(objects(DsoProduct), :image)); by = x -> x.name)
        [p.name for p in result] == ["Django Plushie", "Talking Django Plushie"] && result[1].image == im && result[2].image === nothing
    end
    @test nq(1) do                                                                    # test_missing_reverse
        get(sr(:dsouserprofile); username = "bob").dsouserprofile === nothing
    end
    @test nq(1) do                                                                    # test_nullable_missing_reverse
        img = create(DsoImage; name = "imag2"); true
    end
    @test nq(1) do
        get(select_related(objects(DsoImage), :dsoproduct); name = "imag2").dsoproduct === nothing
    end
    p = nothing
    @test nq(1) do                                                                    # test_parent_only
        p = get(select_related(objects(DsoParent1), :dsochild2); name1 = "Only Parent1"); true
    end
    @test nq(() -> p.dsochild2 === nothing, 0)
    @test nq(1) do                                                                    # test_onetoone_with_subclass
        get(select_related(objects(DsoParent2), :dsochild2); name2 = "Child2 Parent2").dsochild2.name1 == "Child2 Parent1"
    end
    @test nq(1) do                                                                    # test_onetoone_with_two_subclasses
        q = get(select_related(objects(DsoParent2), :dsochild2, :dsochild2__dsochild3); name2 = "Child2 Parent2")
        q.dsochild2.name1 == "Child2 Parent1" && q.dsochild2.dsochild3 === nothing
    end
    p3 = DsoParent2(name2 = "Child3 Parent2"); save!(p3)
    save!(DsoChild3(name1 = "Child3 Parent1", parent2 = p3, value = 2, value3 = 3))
    @test nq(1) do
        q = get(select_related(objects(DsoParent2), :dsochild2, :dsochild2__dsochild3); name2 = "Child3 Parent2")
        q.dsochild2.name1 == "Child3 Parent1" && q.dsochild2.dsochild3.value3 == 3 && q.dsochild2.dsochild3.value == q.dsochild2.value &&
            q.dsochild2.name1 == q.dsochild2.dsochild3.name1
    end
    item1 = create(DsoLinkedList; name = "item1")                                     # test_self_relation
    create(DsoLinkedList; name = "item2", previous_item = item1)
    @test nq(1) do
        get(select_related(objects(DsoLinkedList), :next_item); name = "item1").next_item.name == "item2"
    end
  end
end

@testset "django select_related_onetoone: ReverseSelectRelatedValidationTests" begin
    err(f) = try f(); nothing catch e; e end
    e = err(() -> collect(select_related(objects(DsoUser), :foobar)))                 # test_reverse_related_validation
    @test e isa Juango.LookupError && occursin("Invalid field name(s) given in select_related: 'foobar'. Choices are: dsouserprofile, dsouserstat", e.msg)
    e = err(() -> collect(select_related(objects(DsoUser), :username)))
    @test e isa Juango.LookupError && occursin("Non-relational field given in select_related: 'username'. Choices are: dsouserprofile, dsouserstat", e.msg)
    # test_reverse_related_validation_with_filtered_relation
    e = err(() -> collect(select_related(annotate(objects(DsoUser); relation = FilteredRelation("dsouserprofile")), :foobar)))
    @test e isa Juango.LookupError &&
          occursin("Invalid field name(s) given in select_related: 'foobar'. Choices are: dsouserprofile, dsouserstat, relation", e.msg)
end

# --- tests/nested_foreign_keys (#16715: a nullable relation followed by a non-nullable one is joined LEFT throughout) ----
@testset "django nested_foreign_keys: NestedForeignKeysTests, DeeplyNestedForeignKeysTests" begin
    # the rows, the select_related paths and the values() path lists (with `s` for the screening relation) must all count n
    function check(M, s, n; deep = false)
        @test length(collect(objects(M))) == n
        sr = deep ? ["$(s)__movie__director"] : [s, "$(s)__movie"]
        for p in sr
            @test length(collect(select_related(objects(M), Symbol(p)))) == n
        end
        @test length(collect(values(objects(M)))) == n
        vs = deep ? [["$(s)__movie__director__pk"], ["$(s)__movie__director__name"], ["$(s)__movie__director__pk", "$(s)__movie__director__name"],
                     ["$(s)__movie__pk", "$(s)__movie__director__pk"], ["$(s)__movie__pk", "$(s)__movie__director__name"],
                     ["$(s)__movie__title", "$(s)__movie__director__pk"], ["$(s)__movie__title", "$(s)__movie__director__name"]] :
                    [["$(s)__pk"], ["$(s)__movie__pk"], ["$(s)__movie__title"], ["$(s)__movie__pk", "$(s)__movie__title"]]
        for v in vs
            @test length(collect(values(objects(M), Symbol.(v)...))) == n
        end
    end
    function each(f)
        port_block() do
            director = create(DnkPerson; name = "Terry Gilliam / Terry Jones")
            movie = create(DnkMovie; title = "Monty Python and the Holy Grail", director = director)
            f(director, movie)
        end
    end
    for deep in (false, true)
        each() do director, movie     # test_inheritance
            create(DnkEvent); create(DnkScreening; movie = movie)
            check(DnkEvent, "dnkscreening", 2; deep = deep)
            key, val = deep ? (:dnkscreening__movie__director, director) : (:dnkscreening__movie, movie)
            @test count(filter(DnkEvent; (key => val,)...)) == 1 && count(exclude(DnkEvent; (key => val,)...)) == 1
        end
        each() do director, movie     # test_explicit_ForeignKey
            create(DnkPackage); screening = create(DnkScreening; movie = movie); create(DnkPackage; screening = screening)
            check(DnkPackage, "screening", 2; deep = deep)
            key, val = deep ? (:screening__movie__director, director) : (:screening__movie, movie)
            @test count(filter(DnkPackage; (key => val,)...)) == 1 && count(exclude(DnkPackage; (key => val,)...)) == 1
        end
    end
    each() do director, movie         # test_inheritance_null_FK
        create(DnkEvent); create(DnkScreeningNullFK; movie = nothing); create(DnkScreeningNullFK; movie = movie)
        check(DnkEvent, "dnkscreeningnullfk", 3)
        @test count(filter(DnkEvent; dnkscreeningnullfk__movie = movie)) == 1 && count(exclude(DnkEvent; dnkscreeningnullfk__movie = movie)) == 2
    end
    each() do director, movie         # test_null_exclude
        screening = create(DnkScreeningNullFK; movie = nothing); create(DnkScreeningNullFK; movie = movie)
        @test [x.pk for x in exclude(DnkScreeningNullFK; movie__id = movie.pk)] == [screening.pk]
    end
    each() do director, movie         # test_explicit_ForeignKey_NullFK
        create(DnkPackageNullFK)
        screening = create(DnkScreeningNullFK; movie = nothing); with_movie = create(DnkScreeningNullFK; movie = movie)
        create(DnkPackageNullFK; screening = screening); create(DnkPackageNullFK; screening = with_movie)
        check(DnkPackageNullFK, "screening", 3)
        @test count(filter(DnkPackageNullFK; screening__movie = movie)) == 1 && count(exclude(DnkPackageNullFK; screening__movie = movie)) == 2
    end
end

# --- tests/distinct_on_fields (DISTINCT ON: PostgreSQL) ------------------------------------------------
# (Staff's key is declared `id` in Django (#229): here the automatic id, given explicitly)
if Juango.backend() isa Juango.PostgresBackend
@testset "django distinct_on_fields: DistinctOnTests" begin
  port_block() do
    T, St, ST, Cel, Fan = DdoTag, DdoStaff, DdoStaffTag, DdoCelebrity, DdoFan
    t1 = create(T; name = "t1"); t2 = create(T; name = "t2", parent = t1); t3 = create(T; name = "t3", parent = t1)
    t4 = create(T; name = "t4", parent = t3); t5 = create(T; name = "t5", parent = t3)
    p1_o1 = create(St; id = 1, name = "p1", organisation = "o1"); p2_o1 = create(St; id = 2, name = "p2", organisation = "o1")
    p3_o1 = create(St; id = 3, name = "p3", organisation = "o1"); p1_o2 = create(St; id = 4, name = "p1", organisation = "o2")
    add!(p1_o1.coworkers, p2_o1, p3_o1)
    st1 = create(ST; staff = p1_o1, tag = t1); create(ST; staff = p1_o1, tag = t1)
    celeb1 = create(Cel; name = "c1"); celeb2 = create(Cel; name = "c2")
    fan1 = create(Fan; fan_of = celeb1); fan2 = create(Fan; fan_of = celeb1); fan3 = create(Fan; fan_of = celeb2)
    # test_basic_distinct_on
    for (qs, expected) in ((order_by(distinct(objects(St)), "name"), [p1_o1, p1_o2, p2_o1, p3_o1]),
                           (order_by(distinct(objects(St), :name), "name"), [p1_o1, p2_o1, p3_o1]),
                           (order_by(distinct(objects(St), :organisation), "organisation", "name"), [p1_o1, p1_o2]),
                           (order_by(distinct(objects(St), :name, :organisation), "name", "organisation"), [p1_o1, p1_o2, p2_o1, p3_o1]),
                           (order_by(distinct(filter(Cel; ddofan__in = [fan1, fan2, fan3]), :name), "name"), [celeb1, celeb2]),
                           (order_by(distinct(filter(Cel; ddofan__in = [fan1, fan2]), :name), "name") |
                            order_by(distinct(filter(Cel; ddofan__in = [fan3]), :name), "name"), [celeb1, celeb2]),
                           (distinct(objects(ST), :staff, :tag), [st1]),
                           (distinct(order_by(objects(T), "parent__pk", "pk"), :parent), [t2, t4, t1]),     # (NULLs last on PostgreSQL)
                           (order_by(distinct(select_related(objects(ST), :staff), :staff__name), "staff__name"), [st1]))
        @test pks(qs) == pks(expected)
        @test count(qs) == length(expected)
    end
    # the alphabetically first coworker of each
    qs = values_list(order_by(distinct(objects(St), :id), "id", "coworkers__name"), :id, :coworkers__name)
    @test collect(qs) == [(1, "p2"), (2, "p1"), (3, "p1"), (4, nothing)] && count(qs) == 4
    base = objects(Cel)
    @test_throws "Cannot combine a unique query with a non-unique query." distinct(base, :id) & base
    @test_throws "Cannot combine queries with different distinct fields." distinct(base, :id) & distinct(base, :name)
    # (join unreffing: a str(query) check, not translated)
    # test_sliced_queryset
    @test_throws "Cannot create distinct fields once a slice has been taken." distinct(objects(St)[1:5], :name)
    # test_distinct_on_in_ordered_subquery
    @test pks(order_by(filter(St; pk__in = order_by(distinct(objects(St), :name), "name", "id")), "name")) == pks([p1_o1, p2_o1, p3_o1])
    @test pks(order_by(filter(St; pk__in = order_by(distinct(objects(St), :name), "name", "-id")), "name")) == pks([p1_o2, p2_o1, p3_o1])
    # test_distinct_on_get_ordering_preserved
    @test get(order_by(distinct(objects(St), :name), "name", "-organisation"); name = "p1").organisation == "o2"
    # test_distinct_on_mixed_case_annotation
    @test pks(order_by(distinct(annotate(objects(St); nAmEAlIaS = F(:name)), :nAmEAlIaS), "nAmEAlIaS")) == pks([p1_o1, p2_o1, p3_o1])
    # test_distinct_on_duplicated_selected_foreign_key_columns
    fs = (:tag_id, :tag__id, :tag__name)
    @test collect(values_list(distinct(order_by(objects(ST), string.(fs)...), fs...), fs...)) == [(t1.pk, t1.pk, "t1")]
    # test_distinct_on_column_selected_by_annotation_first, test_distinct_on_annotation_duplicating_selected_column
    @test collect(values_list(distinct(order_by(annotate(objects(St); name_alias = F(:name)), "name"), :name), :name_alias, :name)) ==
          [("p1", "p1"), ("p2", "p2"), ("p3", "p3")]
    @test collect(values_list(distinct(order_by(annotate(objects(St); name_alias = F(:name)), "name_alias"), :name_alias), :name, :name_alias)) ==
          [("p1", "p1"), ("p2", "p2"), ("p3", "p3")]
    # test_distinct_on_duplicated_selected_columns(_descending)
    fs = ("ddostafftag__tag__name", "tags__name", "name")
    @test collect(values_list(distinct(order_by(objects(St), (Asc(F(f); nulls_last = true) for f in fs)...), Symbol.(fs)...), Symbol.(fs)...)) ==
          [("t1", "t1", "p1"), (nothing, nothing, "p1"), (nothing, nothing, "p2"), (nothing, nothing, "p3")]
    @test collect(values_list(distinct(order_by(objects(St), (Desc(F(f); nulls_first = true) for f in fs)...), Symbol.(fs)...), Symbol.(fs)...)) ==
          [(nothing, nothing, "p3"), (nothing, nothing, "p2"), (nothing, nothing, "p1"), ("t1", "t1", "p1")]
    # test_distinct_on_duplicated_selected_columns_with_annotation
    @test collect(values_list(distinct(order_by(annotate(objects(St); tag_name = F(:tags__name)), (Asc(F(f); nulls_last = true) for f in fs)...),
                                       Symbol.(fs)...), :ddostafftag__tag__name, :tag_name, :tags__name, :name)) ==
          [("t1", "t1", "t1", "p1"), (nothing, nothing, nothing, "p1"), (nothing, nothing, nothing, "p2"), (nothing, nothing, nothing, "p3")]
    # test_distinct_on_duplicated_raw_sql_annotations
    @test length(collect(order_by(distinct(values(annotate(objects(St); a = RawSQL("random()", []; output_field = FloatField()),
                                                                       b = RawSQL("random()", []; output_field = FloatField())), :a, :b, :id), :name),
                                  "name", "b"))) == 3
    # test_disallowed_update_distinct_on
    @test_throws "Cannot call update() after .distinct(*fields)." update!(order_by(distinct(objects(St), :organisation), "organisation"); name = "p4")
    # test_distinct_on_annotation_alias_with_lookup_separator
    @test length(collect(distinct(annotate(objects(Cel); celebrity__something = Value(1)), :celebrity__something))) == 1
    # test_transform
    create(T; name = uppercase(t1.name))
    dcl_ok = try
        Juango.register_transform(l -> "LOWER($l)", "lower"; kinds = :char)
        sort(pks(distinct(order_by(objects(T)), :name__lower))) == sort(pks([t1, t2, t3, t4, t5]))
    finally
        Juango.unregister_lookup("lower")
    end
    @test dcl_ok
    # test_distinct_not_implemented_checks
    @test_throws "annotate() + distinct(fields) is not implemented." first(distinct(annotate(objects(Cel); id__max = Max(:id)), :id))
    @test_throws "annotate() + distinct(fields) is not implemented." first(annotate(distinct(objects(Cel), :id); id__max = Max(:id)))
    first(distinct(annotate(distinct(objects(Cel), :id); id__max = Max(:id))))
    @test_throws "aggregate() + distinct(fields) not implemented." aggregate(distinct(objects(Cel), :id); m = Max(:id))
  end
end
end
