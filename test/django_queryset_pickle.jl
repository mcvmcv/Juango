# Django's queryset_pickle tests, ported (#227): PickleabilityTestCase. Django pickles model instances and querysets
# (for its cache); Juango's cache stores them as tagged JSON (`cache_encode` / `cache_decode`): an instance with its
# field values and annotations, a QuerySet as its results. `:serializer => :serialization` caches use Julia's
# Serialization, which stores a QuerySet itself, unevaluated.
# julia --project=test test/django_queryset_pickle.jl   (see setup.jl)
#
# Not translated: the exception classes (DoesNotExist and friends are plain Julia types, nothing to pickle),
# test_missing_django_version_unpickling / test_unsupported_unpickle (Django's version stamp), fetch modes
# (Juango has none) and FilteredRelation (#227 notes it elsewhere).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DqpGroup
    name::String = CharField(max_length = 100)
    Meta(table = "dqp_group")
end
@model struct DqpEvent
    title::String = CharField(max_length = 100)
    group = ForeignKey(DqpGroup, on_delete = :CASCADE, related_name = "event_set")
    Meta(table = "dqp_event")
end
@model struct DqpHappening
    when::DateTime = DateTimeField(default = () -> Dates.now())
    name::String = CharField(max_length = 100, default = "test")
    number::Int = IntegerField(default = 1)
    data::Vector{UInt8} = BinaryField(default = UInt8[])
    Meta(table = "dqp_happening")
end
@model struct DqpM2M
    added::Date = DateField(default = () -> Dates.today())
    groups = ManyToManyField(DqpGroup)
    Meta(table = "dqp_m2m")
end
redirect_stdout(devnull) do
    ms = [DqpGroup, DqpEvent, DqpHappening, DqpM2M, through(DqpM2M, :groups)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
"Through the cache's JSON and back (Django's pickle.loads(pickle.dumps(x)))."
dqp_rt(x) = Juango.cache_decode(Juango.JSON.parse(Juango.JSON.json(Juango.cache_encode(x))))
"Through Julia's Serialization and back (a :serialization cache)."
dqp_ser(x) = (io = IOBuffer(); Juango.Serialization.serialize(io, x); seekstart(io); Juango.Serialization.deserialize(io))
dqp_ids(xs) = sort([x.id for x in xs])

@testset "django queryset_pickle: PickleabilityTestCase" begin
    port_block() do
        g = create(DqpGroup; name = "Ponies Who Own Maybachs")
        e1 = create(DqpEvent; title = "Event 1", group = g)
        create(DqpHappening; data = UInt8[0x01, 0x02])
        create(DqpHappening; name = "two")
        # assert_pickles: the queryset's results come back
        assert_pickles(qs) = (r = dqp_rt(qs); dqp_ids(r) == dqp_ids(collect(qs)) && all(x -> x isa Juango.model_of(qs), r))
        @test assert_pickles(filter(DqpHappening; data = UInt8[0x01, 0x02]))           # test_binaryfield
        @test assert_pickles(filter(objects(DqpGroup); event_set__title = "Event 1"))  # test_related_field / test_filter_reverse_fk
        @test assert_pickles(objects(DqpHappening))                                    # test_datetime_callable_default_all
        @test assert_pickles(filter(DqpHappening; when__lte = Dates.now() + Dates.Day(1)))   # ..._default_filter
        @test assert_pickles(filter(DqpHappening; name = "test"))                       # test_string_as_default
        @test assert_pickles(filter(DqpHappening; number = 1))                          # test_standalone_method_as_default

        # test_model_pickle: an instance comes back equal, with its values, and its relations still work
        e = dqp_rt(e1)
        @test e == e1 && e.title == "Event 1" && e.group_id == g.id && e.group.name == g.name
        h = first(collect(filter(DqpHappening; name = "test")))
        h2 = dqp_rt(h)
        @test h2.when == h.when
        @test h2.data == UInt8[0x01, 0x02]
        @test h2.number == 1
        # test_model_pickle_m2m: the many-to-many still works on the copy
        m = create(DqpM2M); add!(m.groups, g)
        m2 = dqp_rt(m)
        @test m2 == m && m2.added == m.added && [x.id for x in m2.groups] == [g.id]

        # test_annotation_values / test_annotation_with_callable_default: annotations are kept
        qs = annotate(objects(DqpGroup); n = Count(:event_set))
        r = only(dqp_rt(qs))
        @test r.n == 1 && r.name == g.name
        vs = dqp_rt(values(annotate(objects(DqpHappening); latest = Max(:when)), :name, :latest))
        @test sort([v[:name] for v in vs]) == ["test", "two"]
        # test_annotation_values_list
        @test sort(dqp_rt(values_list(objects(DqpHappening), :name; flat = true))) == ["test", "two"]
        # test_filter_deferred: a deferred field stays deferred, and loads on access
        d = only(collect(defer(filter(DqpGroup; id = g.id), :name)))
        d2 = dqp_rt(d)
        @test !haskey(getfield(d2, :_data), :name) && d2.name == g.name

        # test_specialized_queryset / ..._not_evaluated / ..._still_usable (Serialization stores the query, not rows)
        qs = filter(objects(DqpGroup); name__startswith = "Ponies")
        qs2 = dqp_ser(qs)
        create(DqpGroup; name = "Ponies 2")
        @test count(qs2) == 2 && dqp_ids(qs2) == dqp_ids(qs)
        sub = filter(DqpGroup; event_set__in = objects(DqpEvent))                       # test_pickle_subquery_queryset_not_evaluated
        @test dqp_ids(dqp_ser(sub)) == dqp_ids(sub)
        # test_in_lookup_queryset_evaluation: a queryset inside a filter isn't evaluated by the JSON copy either
        @test dqp_ids(dqp_rt(filter(DqpEvent; group__in = objects(DqpGroup)))) == [e1.id]
        # (what the cache does with them)
        cache_set("dqp-qs", filter(objects(DqpGroup); name__startswith = "Ponies"))
        @test dqp_ids(cache_get("dqp-qs")) == dqp_ids(qs)
        cache_delete("dqp-qs")
    end
end
