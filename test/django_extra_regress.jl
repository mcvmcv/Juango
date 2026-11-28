# Django's extra_regress tests, ported (#227): QuerySet.extra() (#280): raw select columns, where conditions, tables
# and ordering, with Django's rules for their parameters and for values().
# julia --project=test test/django_extra_regress.jl   (see setup.jl)
#
# Django's select is a dict (ordered); Juango's takes pairs or a NamedTuple. RevisionableModel's save() setting its
# own base is done by the test.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DerRevisionableModel
    base = ForeignKey(:self; on_delete = :SET_NULL, null = true)
    title::String = CharField(blank = true, max_length = 255)
    when = DateTimeField()
    Meta(table = "extra_regress_revisionablemodel")
end
@model struct DerOrder
    created_by = ForeignKey(User; on_delete = :CASCADE)
    text::String = TextField()
    Meta(table = "extra_regress_order")
end
@model struct DerTestObject
    first::String = CharField(max_length = 20)
    second::String = CharField(max_length = 20)
    third::String = CharField(max_length = 20)
    Meta(table = "extra_regress_testobject")
end
redirect_stdout(devnull) do
    ms = [DerRevisionableModel, DerOrder, DerTestObject]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
"RevisionableModel's save(): a first revision is its own base."
der_save!(rm) = (save!(rm); rm.base_id === nothing && (rm.base_id = rm.id; save!(rm)); rm)

@testset "django extra_regress: ExtraRegressTests" begin
    port_block() do
        u = create_user("fred", "secret"; email = "fred@example.com")
        users = objects(User)
        # test_regression_7314_7372
        rm = der_save!(DerRevisionableModel(title = "First Revision", when = DateTime(2008, 9, 28, 10, 30)))
        @test rm.base_id == rm.id
        rm2 = der_save!(DerRevisionableModel(title = "Second Revision", when = DateTime(2008, 9, 28, 14, 25), base_id = rm.id))
        @test rm2.base.title == "First Revision" && rm2.id != rm.id
        t = "extra_regress_revisionablemodel"
        qs = extra(objects(DerRevisionableModel); where = ["$t.id IN (SELECT MAX(rev.id) FROM $t rev GROUP BY rev.base_id)"])
        @test [(r.title, r.base.title) for r in qs] == [("Second Revision", "First Revision")]
        qs2 = filter(objects(DerRevisionableModel); title__contains = "Revision")
        @test Set((r.title, r.base.title) for r in qs2) == Set([("First Revision", "First Revision"), ("Second Revision", "First Revision")])
        @test [(r.title, r.base.title) for r in (qs & qs2)] == [("Second Revision", "First Revision")]

        # test_extra_stay_tied: parameters stay with their select, which a later extra() replaces
        qs = extra(users; select = ["alpha" => "%s", "beta" => "2", "gamma" => "%s"], select_params = (1, 3))
        qs = extra(qs; select = ["beta" => 4])
        qs = extra(qs; select = ["alpha" => "%s"], select_params = [5])
        @test collect(values(filter(qs; id = u.id), :alpha, :beta, :gamma)) == [Dict(:alpha => 5, :beta => 4, :gamma => 3)]
        # test_regression_7957
        @test first(extra(extra(users; select = ["alpha" => "%s"], select_params = (1,)); select = ["beta" => "%s"], select_params = (2,))).alpha == 1
        @test first(extra(extra(users; select = ["beta" => "%s"], select_params = (1,)); select = ["alpha" => "%s"], select_params = (2,))).alpha == 2
        # test_regression_7961: an unused extra select's parameters dropped
        @test collect(values_list(filter(extra(users; select = ["alpha" => "%s"], select_params = (-6,)); id = u.id), :id; flat = true)) == [u.id]
        # test_regression_8063: slicing keeps the extra where
        qs = extra(users; where = ["id=%s"], params = [u.id])
        @test collect(qs) == [u] && collect(qs[1:1]) == [u]
        # test_regression_8039: an extra table stays in the FROM (by created_by_id: Juango's User has Meta(ordering =
        # ["username"]), Django's none, so order_by(:created_by) joins auth_user and username would be ambiguous)
        @test isempty(collect(order_by(extra(objects(DerOrder); where = ["username=%s"], params = ["fred"], tables = ["auth_user"]), :created_by_id)))
        # test_regression_8819: extra selects in distinct() and order_by
        @test collect(distinct(extra(filter(users; id = u.id); select = ["extra_field" => 1]))) == [u]
        @test collect(extra(filter(users; id = u.id); select = ["extra_field" => 1], order_by = ["extra_field"])) == [u]
        @test collect(distinct(extra(filter(users; id = u.id); select = ["extra_field" => 1], order_by = ["extra_field"]))) == [u]
    end
    port_block() do
        # test_dates_query: datetimes() leaves the extra selects out
        der_save!(DerRevisionableModel(title = "First Revision", when = DateTime(2008, 9, 28, 10, 30)))
        @test datetimes(extra(objects(DerRevisionableModel); select = ["the_answer" => "id"]), :when, :month) == [DateTime(2008, 9, 1)]
    end
    port_block() do
        # test_values_with_extra
        obj = save!(DerTestObject(first = "first", second = "second", third = "third"))
        sel = ["foo" => "first", "bar" => "second", "whiz" => "third"]
        tos = objects(DerTestObject)
        all_d = Dict(:bar => "second", :third => "third", :second => "second", :whiz => "third", :foo => "first", :id => obj.id, :first => "first")
        @test collect(values(extra(tos; select = sel))) == [all_d]
        @test collect(extra(values(tos); select = sel)) == [all_d]                      # (after an empty values(): included)
        @test collect(values(extra(tos; select = sel), :first, :second)) == [Dict(:second => "second", :first => "first")]
        @test collect(extra(values(tos, :first, :second); select = sel)) == [Dict(:second => "second", :first => "first")]   # (ignored)
        @test collect(values(extra(tos; select = sel), :first, :second, :foo)) == [Dict(:second => "second", :foo => "first", :first => "first")]
        @test collect(values(extra(tos; select = sel), :foo, :whiz)) == [Dict(:foo => "first", :whiz => "third")]
        all_t = ("first", "second", "third", obj.id, "first", "second", "third")
        @test collect(values_list(extra(tos; select = sel))) == [all_t]
        @test collect(extra(values_list(tos); select = sel)) == [all_t]
        @test collect(values_list(extra(tos; select = sel), :first, :second)) == [("first", "second")]
        @test collect(extra(values_list(tos, :first, :second); select = sel)) == [("first", "second")]
        @test collect(values_list(extra(tos; select = sel), :second; flat = true)) == ["second"]
        @test collect(values_list(extra(tos; select = sel), :first, :second, :whiz)) == [("first", "second", "third")]
        @test collect(values_list(extra(tos; select = sel), :foo, :whiz)) == [("first", "third")]
        @test collect(values_list(extra(tos; select = sel), :whiz; flat = true)) == ["third"]
        @test collect(values_list(extra(tos; select = sel), :whiz, :foo)) == [("third", "first")]
        @test collect(values_list(extra(tos; select = sel), :first, :id)) == [("first", obj.id)]
        @test collect(values_list(extra(tos; select = sel), :whiz, :first, :bar, :id)) == [("third", "first", "second", obj.id)]
        # test_regression_10847
        @test collect(values(extra(tos; select = ["extra" => 1]), :pk)) == [Dict(:pk => obj.id)]
        @test collect(filter(tos; pk__in = values(extra(tos; select = ["extra" => 1]), :pk))) == [obj]
        @test collect(extra(values(tos, :pk); select = ["extra" => 1])) == [Dict(:pk => obj.id)]
        @test collect(filter(tos; pk__in = extra(values(tos, :pk); select = ["extra" => 1]))) == [obj]
        @test collect(filter(tos; pk = obj.id) | extra(tos; where = ["id > %s"], params = [obj.id])) == [obj]
    end
    port_block() do
        # test_regression_17877: the extra where conditions ANDed, each whole
        mk(a, b, c) = save!(DerTestObject(first = a, second = b, third = c))
        t1, t2 = mk("a", "a", "a"), mk("b", "a", "a")
        mk("a", "a", "b"); mk("b", "a", "b"); mk("b", "b", "a"); mk("a", "b", "b")
        @test Set(extra(objects(DerTestObject); where = ["first = 'a' OR second = 'a'", "third = 'a'"])) == Set([t1, t2])
    end
    port_block() do
        # test_extra_values_distinct_ordering
        t1 = save!(DerTestObject(first = "a", second = "a", third = "a"))
        t2 = save!(DerTestObject(first = "a", second = "b", third = "b"))
        qs = distinct(values_list(extra(objects(DerTestObject); select = ["second_extra" => "second"]), :id; flat = true))
        @test collect(order_by(qs, :second_extra)) == [t1.id, t2.id]
        @test collect(order_by(qs, "-second_extra")) == [t2.id, t1.id]
        @test collect(values_list(order_by(qs, "-second_extra"), :first)) == [("a",), ("a",)]
    end
end
