# Django's postgres_tests/test_aggregates, ported (#227). Juango's ArrayAgg, JSONBAgg, BoolAnd, BoolOr and the
# statistics aggregates work on every backend, so these run on all three.
# julia --project=test test/django_postgres_aggregates.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DagAggregateTestModel
    char_field = CharField(max_length = 30, blank = true)
    text_field = TextField(blank = true)
    integer_field = IntegerField(null = true)
    boolean_field = BooleanField(null = true)
    json_field = JSONField(null = true)
    Meta(table = "dag_aggregatetest")
end
@model struct DagStatTestModel
    int1 = IntegerField()
    int2 = IntegerField()
    related_field = ForeignKey(DagAggregateTestModel; on_delete = :SET_NULL, null = true)
    Meta(table = "dag_stattest")
end
const DAG_MODELS = [DagAggregateTestModel, DagStatTestModel]
redirect_stdout(devnull) do
    Juango.sync_models!(DAG_MODELS); append!(PORT_MODELS, DAG_MODELS)
end

function dag_setup()
    M = DagAggregateTestModel
    bulk_create([M(; boolean_field = true, char_field = "Foo1", text_field = "Text1", integer_field = 0),
                 M(; boolean_field = false, char_field = "Foo2", text_field = "Text2", integer_field = 1, json_field = Dict("lang" => "pl")),
                 M(; boolean_field = false, char_field = "Foo4", text_field = "Text4", integer_field = 2, json_field = Dict("lang" => "en")),
                 M(; boolean_field = true, char_field = "Foo3", text_field = "Text3", integer_field = 0, json_field = Dict("breed" => "collie"))])
end
dag_agg(qs, a) = aggregate(qs; agg = a)[:agg]

@testset "django postgres_tests test_aggregates: TestGeneralAggregate" begin
    port_block() do
        M = DagAggregateTestModel
        for a in (ArrayAgg(:char_field), ArrayAgg(:integer_field), ArrayAgg(:boolean_field), BoolAnd(:boolean_field),   # test_empty_result_set
                  BoolOr(:boolean_field), JSONBAgg(:integer_field))
            @test dag_agg(none(M), a) === nothing
            @test dag_agg(objects(M), a) === nothing
        end
        for (a, want) in ((ArrayAgg(:char_field; default = ["<empty>"]), ["<empty>"]), (ArrayAgg(:integer_field; default = [0]), [0]),   # test_default_argument
                          (ArrayAgg(:boolean_field; default = [false]), [false]), (BoolAnd(:boolean_field; default = false), false),
                          (BoolOr(:boolean_field; default = false), false), (JSONBAgg(:integer_field; default = ["<empty>"]), ["<empty>"]))
            @test dag_agg(none(M), a) == want
            @test dag_agg(objects(M), a) == want
        end
        aggs = dag_setup()
        @test dag_agg(order_by(M, "id"), ArrayAgg(:char_field)) == ["Foo1", "Foo2", "Foo4", "Foo3"]           # test_array_agg_charfield
        for (ob, want) in ((Desc(:char_field), ["Foo4", "Foo3", "Foo2", "Foo1"]), (Asc(:char_field), ["Foo1", "Foo2", "Foo3", "Foo4"]),   # test_array_agg_charfield_order_by
                           (F(:char_field), ["Foo1", "Foo2", "Foo3", "Foo4"]), ([F(:boolean_field), Desc(:char_field)], ["Foo4", "Foo2", "Foo3", "Foo1"]),
                           ((F(:boolean_field), Desc(:char_field)), ["Foo4", "Foo2", "Foo3", "Foo1"]),
                           ("char_field", ["Foo1", "Foo2", "Foo3", "Foo4"]), ("-char_field", ["Foo4", "Foo3", "Foo2", "Foo1"]),
                           (Concat(:char_field, Value("@")), ["Foo1", "Foo2", "Foo3", "Foo4"]),
                           (Desc(Concat(:char_field, Value("@"))), ["Foo4", "Foo3", "Foo2", "Foo1"]),
                           ((Substr(:char_field, 1, 1), F(:integer_field), Desc(Substr(:char_field, 4, 1))), ["Foo3", "Foo1", "Foo2", "Foo4"]))
            Juango.backend() isa Juango.MySQLBackend && !Juango.is_mariadb(Juango.backend()) && continue     # (MySQL can't order JSON_ARRAYAGG)
            @test dag_agg(objects(M), ArrayAgg(:char_field; order_by = ob)) == want
        end
        @test dag_agg(order_by(M, "id"), ArrayAgg(:integer_field)) == [0, 1, 2, 0]                            # test_array_agg_integerfield
        @test dag_agg(objects(M), ArrayAgg(:integer_field; order_by = Desc(:integer_field))) == [2, 1, 0, 0]  # test_array_agg_integerfield_order_by
        @test dag_agg(order_by(M, "id"), ArrayAgg(:boolean_field)) == [true, false, false, true]              # test_array_agg_booleanfield
        for (ob, want) in ((Asc(:boolean_field), [false, false, true, true]), (Desc(:boolean_field), [true, true, false, false]),   # test_array_agg_booleanfield_order_by
                           (F(:boolean_field), [false, false, true, true]))
            @test dag_agg(objects(M), ArrayAgg(:boolean_field; order_by = ob)) == want
        end
        langs = dag_agg(order_by(M, "id"), ArrayAgg(:json_field__lang; filter = Q(json_field__lang__isnull = false)))   # test_array_agg_jsonfield
        @test langs == ["pl", "en"]
        @test dag_agg(objects(M), ArrayAgg(:json_field__lang; filter = Q(json_field__lang__isnull = false),          # test_array_agg_jsonfield_order_by
                                           order_by = F(:json_field__lang))) == ["en", "pl"]
        @test dag_agg(objects(M), ArrayAgg(:char_field; filter = Q(json_field__has_key = "lang"),                      # test_array_agg_filter_and_order_by_params
                                           order_by = LPad(Cast(:integer_field, :string), 2, Value("0")))) == ["Foo2", "Foo4"]
        @test dag_agg(order_by(M, "id"), ArrayAgg(:integer_field; filter = Q(integer_field__gt = 0))) == [1, 2]   # test_array_agg_filter
        S = DagStatTestModel
        a1, a2 = create(M), create(M)                                                                          # test_array_agg_lookups
        foreach(((r, i),) -> create(S; related_field = r, int1 = i, int2 = 0), [(a1, 1), (a1, 2), (a2, 3), (a2, 4)])
        qs = values_list(filter(annotate(values(S, :related_field); array = ArrayAgg(:int1)), array__overlap = [2]), :array; flat = true)
        @test sort(only(collect(qs))) == [1, 2]                                  # (lookups on an ArrayAgg annotation: #297)
        delete!(filter(S)); delete!(a1); delete!(a2)
        @test dag_agg(objects(M), BoolAnd(:boolean_field)) == false                                            # test_bool_and_general
        @test dag_agg(objects(M), BoolAnd(Q(integer_field__gt = 2))) == false                                  # test_bool_and_q_object
        @test dag_agg(objects(M), BoolOr(:boolean_field)) == true                                              # test_bool_or_general
        @test dag_agg(objects(M), BoolOr(Q(integer_field__gt = 2))) == false                                   # test_bool_or_q_object
        @test dag_agg(objects(M), ArrayAgg(:integer_field; order_by = Asc(:char_field))) == [0, 1, 0, 2]      # test_orderable_agg_alternative_fields
        @test dag_agg(order_by(M, "id"), JSONBAgg(:char_field)) == ["Foo1", "Foo2", "Foo4", "Foo3"]           # test_jsonb_agg
        @test dag_agg(objects(M), JSONBAgg(:integer_field; order_by = Desc(:integer_field))) == [2, 1, 0, 0]  # test_jsonb_agg_integerfield_order_by
        # test_array_agg_order_by_in_subquery
        stats = DagStatTestModel[]
        for (i, a) in enumerate(order_by(M, "char_field"))
            push!(stats, S(; related_field = a, int1 = i - 1, int2 = i), S(; related_field = a, int1 = i, int2 = i - 1))
        end
        bulk_create(stats)
        sub = values(annotate(filter(M; pk = OuterRef(:pk)); agg = ArrayAgg(:dagstattestmodel__int1; order_by = "-dagstattestmodel__int2")), :agg)
        got = collect(values_list(order_by(annotate(M; agg = Subquery(sub)), "char_field"), :char_field, :agg))
        @test [(r[1], r[2]) for r in got] == [("Foo1", [0, 1]), ("Foo2", [1, 2]), ("Foo3", [2, 3]), ("Foo4", [3, 4])]
        delete!(filter(S))
        # test_string_agg_array_agg_filter_in_subquery
        bulk_create([S(; related_field = aggs[1], int1 = 0, int2 = 5), S(; related_field = aggs[1], int1 = 1, int2 = 4), S(; related_field = aggs[1], int1 = 2, int2 = 3)])
        sub = values(annotate(filter(M; pk = OuterRef(:pk)); agg = ArrayAgg(:dagstattestmodel__int1; filter = Q(dagstattestmodel__int2__gt = 3), order_by = "dagstattestmodel__int1")), :agg)
        got = collect(values_list(order_by(filter(annotate(M; agg = Subquery(sub)), char_field__in = ["Foo1", "Foo2"]), "char_field"), :char_field, :agg))
        @test [(r[1], r[2]) for r in got] == [("Foo1", [0, 1]), ("Foo2", nothing)]
        delete!(filter(S))
        # test_window (MariaDB has no JSON_ARRAYAGG as a window function)
        if !Juango.is_mariadb(Juango.backend())
            rows = collect(values(annotate(M; integers = Window(ArrayAgg(:char_field); partition_by = F(:integer_field))), :integers, :char_field))
            @test sort([(r[:char_field], sort(r[:integers])) for r in rows]) ==
                  [("Foo1", ["Foo1", "Foo3"]), ("Foo2", ["Foo2"]), ("Foo3", ["Foo1", "Foo3"]), ("Foo4", ["Foo4"])]
        end
        for a in (ArrayAgg(:integer_field), JSONBAgg(:integer_field))                                          # test_values_list
            @test sort([r[1] for r in values_list(annotate(M; agg = a), :agg)]) == [[0], [0], [1], [2]]
        end
        @test dag_agg(objects(M), StringAgg(:char_field, "'"; order_by = "id")) == "Foo1'Foo2'Foo4'Foo3"      # test_string_agg_*_deprecation
        @test dag_agg(objects(M), BitXor(:integer_field)) == xor(0, 1, 2, 0)                                   # test_bit_agg_deprecation
        @test dag_agg(objects(M), BitAnd(:integer_field)) == 0 && dag_agg(objects(M), BitOr(:integer_field)) == 3
        # test_ordering_isnt_cleared_for_array_subquery, test_array_agg_filter_index / _slice, test_jsonb_agg_key_index_transforms,
        # test_array_agg_with_order_by_outer_ref: not translated (Func("ARRAY", subquery); transforms of an ArrayAgg annotation, #297)
    end
end

@testset "django postgres_tests test_aggregates: TestAggregateDistinct" begin
    port_block() do
        M = DagAggregateTestModel
        create(M; char_field = "Foo"); create(M; char_field = "Foo"); create(M; char_field = "Bar")
        @test sort(dag_agg(objects(M), ArrayAgg(:char_field; distinct = false))) == ["Bar", "Foo", "Foo"]     # test_array_agg_distinct_false
        @test sort(dag_agg(objects(M), ArrayAgg(:char_field; distinct = true))) == ["Bar", "Foo"]             # test_array_agg_distinct_true
        @test sort(dag_agg(objects(M), JSONBAgg(:char_field; distinct = false))) == ["Bar", "Foo", "Foo"]     # test_jsonb_agg_distinct_false
        @test sort(dag_agg(objects(M), JSONBAgg(:char_field; distinct = true))) == ["Bar", "Foo"]             # test_jsonb_agg_distinct_true
    end
end

@testset "django postgres_tests test_aggregates: TestStatisticsAggregate" begin
    @test_throws "Both y and x must be provided." StatAggregate(; x = nothing, y = nothing)                 # test_missing_arguments_raises_exception
    e = StatAggregate(; x = "test", y = 13)                                                                   # test_correct_source_expressions
    @test e.arg.args[1] isa Value && e.arg.args[2] isa F
    # test_alias_is_required: Juango's aggregate() takes names only
    @test_throws "RegrCount does not allow default." RegrCount(; y = :int2, x = :int1, default = 0)          # test_regr_count_default
    port_block() do
        S, M = DagStatTestModel, DagAggregateTestModel
        all_ = [(Corr, (;)), (CovarPop, (;)), (CovarPop, (; sample = true)), (RegrAvgX, (;)), (RegrAvgY, (;)), (RegrIntercept, (;)),
                (RegrR2, (;)), (RegrSlope, (;)), (RegrSXX, (;)), (RegrSXY, (;)), (RegrSYY, (;))]
        for (A, kw) in all_                                                                                    # test_empty_result_set
            @test dag_agg(none(S), A(; y = :int2, x = :int1, kw...)) === nothing
            @test dag_agg(objects(S), A(; y = :int2, x = :int1, kw...)) === nothing
        end
        @test dag_agg(none(S), RegrCount(; y = :int2, x = :int1)) == 0
        @test dag_agg(objects(S), RegrCount(; y = :int2, x = :int1)) == 0
        for (A, kw) in all_                                                                                    # test_default_argument
            @test dag_agg(none(S), A(; y = :int2, x = :int1, default = 0, kw...)) == 0
            @test dag_agg(objects(S), A(; y = :int2, x = :int1, default = 0, kw...)) == 0
        end
        create(S; int1 = 1, int2 = 3, related_field = create(M; integer_field = 0))
        create(S; int1 = 2, int2 = 2, related_field = create(M; integer_field = 1))
        create(S; int1 = 3, int2 = 1, related_field = create(M; integer_field = 2))
        st(A; kw...) = dag_agg(objects(S), A(; y = :int2, x = :int1, kw...))
        @test st(Corr) ≈ -1.0                                                                                  # test_corr_general
        @test isapprox(st(CovarPop), -0.66; atol = 0.05)                                                       # test_covar_pop_general
        @test st(CovarPop; sample = true) ≈ -1.0                                                               # test_covar_pop_sample
        @test st(RegrAvgX) ≈ 2.0                                                                               # test_regr_avgx_general
        @test st(RegrAvgY) ≈ 2.0                                                                               # test_regr_avgy_general
        @test st(RegrCount) === 3                                                                              # test_regr_count_general
        @test st(RegrIntercept) ≈ 4                                                                            # test_regr_intercept_general
        @test st(RegrR2) ≈ 1                                                                                   # test_regr_r2_general
        @test st(RegrSlope) ≈ -1                                                                               # test_regr_slope_general
        @test st(RegrSXX) ≈ 2.0                                                                                # test_regr_sxx_general
        @test st(RegrSXY) ≈ -2.0                                                                               # test_regr_sxy_general
        @test st(RegrSYY) ≈ 2.0                                                                                # test_regr_syy_general
        @test dag_agg(objects(S), RegrAvgX(; y = 5, x = :related_field__integer_field)) ≈ 1.0                  # test_regr_avgx_with_related_obj_and_number_as_argument
    end
end
