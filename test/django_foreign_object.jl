# Django's foreign_object tests (tests/foreign_object: MultiColumnFKTests), ported (#227).
# julia --project=test test/django_foreign_object.jl   (see setup.jl)
#
# A forward ForeignObject that matches no row is `nothing` in Juango (Django raises DoesNotExist), as for foreign keys.
# Not translated: the active_translation fields (a ForeignObject subclass overriding get_extra_restriction and its
# descriptor: Python class mechanics), the fetch_mode tests (#230), TestModelCheckTests, TestExtraJoinFilterQ,
# TestCachedPathInfo (internals), test_query_does_not_mutate and the pickling tests.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Dates

@model struct DfoCountry
    name = CharField(max_length = 50)
    Meta(table = "dfo_country")
end
@model struct DfoPerson
    name = CharField(max_length = 128)
    person_country_id = IntegerField()
    person_country = ForeignObject(DfoCountry; from_fields = [:person_country_id], to_fields = [:id], on_delete = :CASCADE)
    friends = ManyToManyField(:self; through = "DfoFriendship", symmetrical = false)
    Meta(table = "dfo_person", ordering = [:name])
end
@model struct DfoGroup
    name = CharField(max_length = 128)
    group_country = ForeignKey(DfoCountry; on_delete = :CASCADE)
    members = ManyToManyField(DfoPerson; related_name = :groups, through = "DfoMembership")
    Meta(table = "dfo_group", ordering = [:name])
end
@model struct DfoMembership
    membership_country = ForeignKey(DfoCountry; on_delete = :CASCADE, null = true)
    date_joined = DateTimeField(default = () -> now())
    invite_reason = CharField(max_length = 64, null = true)
    person_id = IntegerField()
    group_id = IntegerField(blank = true, null = true)
    person = ForeignObject(DfoPerson; from_fields = [:person_id, :membership_country], to_fields = [:id, :person_country_id], on_delete = :CASCADE)
    group = ForeignObject(DfoGroup; from_fields = [:group_id, :membership_country], to_fields = [:id, :group_country], on_delete = :CASCADE)
    Meta(table = "dfo_membership", ordering = [:date_joined, :invite_reason])
end
@model struct DfoFriendship
    from_friend_country = ForeignKey(DfoCountry; on_delete = :CASCADE, related_name = :from_friend_country)
    from_friend_id = IntegerField()
    to_friend_country_id = IntegerField()
    to_friend_id = IntegerField(null = true)
    from_friend = ForeignObject(DfoPerson; on_delete = :CASCADE, from_fields = [:from_friend_country, :from_friend_id],
                                to_fields = [:person_country_id, :id], related_name = :from_friend)
    to_friend_country = ForeignObject(DfoCountry; from_fields = [:to_friend_country_id], to_fields = [:id],
                                      related_name = :to_friend_country, on_delete = :CASCADE)
    to_friend = ForeignObject(DfoPerson; from_fields = [:to_friend_country_id, :to_friend_id], to_fields = [:person_country_id, :id],
                              related_name = Symbol("to_friend+"), on_delete = :CASCADE)
    Meta(table = "dfo_friendship")
end
@model struct DfoArticle
    pub_date = DateField()
    Meta(table = "dfo_article")
end
@model struct DfoArticleTag
    article = ForeignKey(DfoArticle; on_delete = :CASCADE, related_name = :tags, related_query_name = :tag)
    name = CharField(max_length = 255)
    Meta(table = "dfo_articletag")
end
@model struct DfoArticleIdea
    articles = ManyToManyField(DfoArticle; related_name = :ideas, related_query_name = :idea_things)
    name = CharField(max_length = 255)
    Meta(table = "dfo_articleidea")
end

redirect_stdout(devnull) do
    ms = Any[DfoCountry, DfoPerson, DfoGroup, DfoMembership, DfoFriendship, DfoArticle, DfoArticleTag, DfoArticleIdea,
             through(DfoArticleIdea, :articles)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

dfo_names(qs) = [x.name for x in collect(qs)]

@testset "django foreign_object: MultiColumnFKTests" begin
  setup() = begin
      usa, su = create(DfoCountry; name = "United States of America"), create(DfoCountry; name = "Soviet Union")
      p(n, c) = create(DfoPerson; name = n, person_country = c)
      (; usa, su, bob = p("Bob", usa), jim = p("Jim", usa), george = p("George", usa), jane = p("Jane", su), mark = p("Mark", su),
         sam = p("Sam", su), kgb = create(DfoGroup; name = "KGB", group_country = su), cia = create(DfoGroup; name = "CIA", group_country = usa),
         republican = create(DfoGroup; name = "Republican", group_country = usa), democrat = create(DfoGroup; name = "Democrat", group_country = usa))
  end
  M = DfoMembership
  mem(c, p, g; kw...) = create(M; membership_country_id = c.id, person_id = p.id, group_id = g === nothing ? nothing : g.id, kw...)
  port_block() do
    d = setup()
    # test_get_succeeds_on_multicolumn_match
    m = mem(d.usa, d.bob, d.cia)
    @test (m.person.id, m.person.name) == (d.bob.id, "Bob")
    # test_get_fails_on_multicolumn_mismatch (nothing: Juango's missing related object)
    @test mem(d.usa, d.jane, d.cia).person === nothing
  end
  port_block() do
    d = setup()
    # test_reverse_query_returns_correct_result
    mem(d.usa, d.bob, d.cia); mem(d.su, d.bob, d.republican)
    @test assert_num_queries(1) do
        m = get(d.bob.dfomembership_set)
        m.group_id == d.cia.id
    end
  end
  port_block() do
    d = setup()
    # test_query_filters_correctly / test_forward_in_lookup_filters_correctly
    mem(d.usa, d.bob, d.cia); mem(d.usa, d.jim, d.cia); mem(d.su, d.george, d.cia)
    @test [x.person_id for x in collect(filter(M; person__name__contains = "o"))] == [d.bob.id]
    @test [x.person_id for x in collect(filter(M; person__in = [d.george, d.jim]))] == [d.jim.id]
    @test [x.person_id for x in collect(filter(M; person__in = filter(DfoPerson; name = "Jim")))] == [d.jim.id]
  end
  port_block() do
    d = setup()
    # test_reverse_query_filters_correctly
    t = now(); dt = Day(1)
    mem(d.usa, d.bob, d.cia; date_joined = t - dt); mem(d.usa, d.jim, d.cia; date_joined = t + dt); mem(d.su, d.george, d.cia; date_joined = t + dt)
    @test dfo_names(filter(DfoPerson; dfomembership__date_joined__gte = t)) == ["Jim"]
  end
  port_block() do
    d = setup()
    # test_double_nested_query
    m1 = mem(d.usa, d.bob, d.cia); m2 = mem(d.usa, d.jim, d.cia)
    create(DfoFriendship; from_friend_country_id = d.usa.id, from_friend_id = d.bob.id, to_friend_country_id = d.usa.id, to_friend_id = d.jim.id)
    inner = filter(DfoPerson; from_friend__in = filter(DfoFriendship; to_friend__in = objects(DfoPerson)))
    @test [x.pk for x in collect(filter(M; person__in = inner))] == [m1.pk]
    @test [x.pk for x in collect(exclude(M; person__in = inner))] == [m2.pk]
  end
  port_block() do
    d = setup()
    create(M; membership_country = d.usa, person = d.bob, group = d.cia)
    create(M; membership_country = d.usa, person = d.jim, group = d.democrat)
    normal = [m.person for m in collect(order_by(objects(M), "pk"))]
    # test_select_related_foreignkey_forward_works
    @test assert_num_queries(() -> [m.person for m in collect(order_by(select_related(objects(M), :person), "pk"))] == normal, 1)
    # test_prefetch_foreignobject_forward
    @test assert_num_queries(() -> [m.person for m in collect(order_by(prefetch_related(objects(M), :person), "pk"))] == normal, 2)
    # test_prefetch_foreignobject_reverse
    pr, n = count_queries() do
        [collect(p.dfomembership_set) for p in collect(order_by(prefetch_related(objects(DfoPerson), :dfomembership_set), "pk"))]
    end
    @test n == 2 && pr == [collect(p.dfomembership_set) for p in collect(order_by(objects(DfoPerson), "pk"))]
  end
  port_block() do
    d = setup()
    # test_prefetch_foreignobject_hidden_forward
    create(DfoFriendship; from_friend_country = d.usa, from_friend_id = d.bob.id, to_friend_country_id = d.usa.id, to_friend_id = d.george.id)
    create(DfoFriendship; from_friend_country = d.usa, from_friend_id = d.bob.id, to_friend_country_id = d.su.id, to_friend_id = d.sam.id)
    fs, n = count_queries(() -> collect(order_by(prefetch_related(objects(DfoFriendship), :to_friend), "pk")))
    @test n == 2
    @test assert_num_queries(() -> fs[1].to_friend == d.george && fs[2].to_friend == d.sam, 0)
  end
  port_block() do
    d = setup()
    # test_prefetch_foreignobject_null_hidden_forward_skipped
    f = create(DfoFriendship; from_friend_country = d.usa, from_friend_id = d.bob.id, to_friend_country_id = d.usa.id, to_friend_id = nothing)
    @test assert_num_queries(() -> get(prefetch_related(objects(DfoFriendship), :to_friend)) == f, 1)
  end
  # test_m2m_through_* and test_prefetch_related_m2m_*: a many-to-many through ForeignObjects is #283
  dfo_try(f) = try f() catch; false end
  port_block() do
    d = setup()
    create(M; membership_country = d.usa, person = d.bob, group = d.cia)
    create(M; membership_country = d.usa, person = d.jim, group = d.cia)
    create(M; membership_country = d.usa, person = d.bob, group = d.republican)
    create(M; membership_country = d.usa, person = d.jane, group = d.cia)          # Jane's country isn't the CIA's
    @test_broken dfo_try(() -> dfo_names(d.cia.members) == ["Bob", "Jim"])
    @test_broken dfo_try(() -> dfo_names(d.bob.groups) == ["CIA", "Republican"] && isempty(collect(d.jane.groups)))
    create(DfoFriendship; from_friend_country = d.jane.person_country, from_friend = d.jane, to_friend_country = d.george.person_country,
           to_friend = d.george)
    @test_broken dfo_try(() -> dfo_names(d.jane.friends) == ["George"])
    @test_broken dfo_try(() -> (count_queries(() -> [collect(g.members) for g in collect(prefetch_related(objects(DfoGroup), :members))])[2] == 2))
  end
  port_block() do
    d = setup()
    # test_refresh_foreign_object
    member = create(M; membership_country = d.usa, person = d.bob, group = d.cia)
    member.person = d.jim
    @test assert_num_queries(() -> (refresh!(member); true), 1)
    @test member.person == d.bob
  end
  port_block() do
    # test_foreign_key_related_query_name / test_many_to_many_related_query_name
    a1 = create(DfoArticle; pub_date = today())
    create(DfoArticleTag; article = a1, name = "foo")
    @test count(filter(DfoArticle; tag__name = "foo")) == 1 && count(filter(DfoArticle; tag__name = "bar")) == 0
    e = try collect(filter(DfoArticle; tags__name = "foo")); nothing catch e; e end
    @test e isa Juango.LookupError && occursin("Choices are: id, idea_things, pub_date, tag", e.msg)
    i1 = create(DfoArticleIdea; name = "idea1")
    add!(a1.ideas, i1)
    @test count(filter(DfoArticle; idea_things__name = "idea1")) == 1 && count(filter(DfoArticle; idea_things__name = "idea2")) == 0
    e = try collect(filter(DfoArticle; ideas__name = "idea1")); nothing catch e; e end
    @test e isa Juango.LookupError && occursin("Choices are: id, idea_things, pub_date, tag", e.msg)
  end
  port_block() do
    d = setup()
    # test_batch_create_foreign_object
    bulk_create([DfoPerson(; name = "abcd_$i", person_country = d.usa) for i in 0:4]; batch_size = 10)
    @test count(filter(DfoPerson; name__startswith = "abcd_")) == 5
    # test_isnull_lookup
    m1 = create(M; person_id = d.bob.id, membership_country_id = d.usa.id, group_id = nothing)
    m2 = create(M; person_id = d.jim.id, membership_country_id = nothing, group_id = d.cia.id)
    m3 = create(M; person_id = d.jane.id, membership_country_id = nothing, group_id = nothing)
    m4 = create(M; person_id = d.george.id, membership_country_id = d.su.id, group_id = d.kgb.id)
    @test all(m -> m.group === nothing, [m1, m2, m3])
    @test [x.pk for x in collect(filter(M; group__isnull = true))] == [m1.pk, m2.pk, m3.pk]
    @test [x.pk for x in collect(filter(M; group__isnull = false))] == [m4.pk]
  end
end
