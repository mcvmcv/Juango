# Django's postgres_tests test_trigram, test_unaccent, test_functions and test_bulk_update, ported (#227). The trigram
# operators (pg_trgm), UNACCENT, TransactionNow and RandomUUID are PostgreSQL's: those tests run there. bulk_update of
# arrays, hstore and ranges runs on every database.
# julia --project=test test/django_postgres_trigram.jl   (see setup.jl)
#
# Not translated: test_signals (psycopg's type OIDs; Juango's own libpq driver reads hstore and citext as text);
# test_unaccent_with_conforming_strings_off (Juango sends values as parameters, never in the SQL text);
# BulkSaveTests.test_bulk_create (a Python custom field whose get_db_prep_value adds one).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DtgCharFieldModel
    field = CharField(max_length = 64)
    Meta(table = "dtg_charfieldmodel")
end
@model struct DtgTextFieldModel
    field = TextField()
    Meta(table = "dtg_textfieldmodel")
end
@model struct DtgNowTestModel
    when = DateTimeField(null = true, default = nothing)
    Meta(table = "dtg_nowtestmodel")
end
@model struct DtgUUIDTestModel
    uuid = UUIDField(default = nothing, null = true)
    Meta(table = "dtg_uuidtestmodel")
end
@model struct DtgIntegerArrayModel
    field = ArrayField(BigIntegerField(); default = Vector{Int}, blank = true)
    Meta(table = "dtg_integerarraymodel")
end
@model struct DtgNullableIntegerArrayModel
    field = ArrayField(BigIntegerField(); blank = true, null = true)
    Meta(table = "dtg_nullableintegerarraymodel")
end
@model struct DtgNestedIntegerArrayModel
    field = ArrayField(ArrayField(IntegerField()))
    Meta(table = "dtg_nestedintegerarraymodel")
end
@model struct DtgHStoreModel
    field = HStoreField(blank = true, null = true)
    Meta(table = "dtg_hstoremodel")
end
@model struct DtgRangesModel
    ints = IntegerRangeField(blank = true, null = true)
    dates = DateRangeField(blank = true, null = true)
    Meta(table = "dtg_rangesmodel")
end
@model struct DtgOtherTypesArrayModel
    ips = ArrayField(GenericIPAddressField(); default = Vector{String})
    json = ArrayField(JSONField(); default = Vector{Any}, null = true)
    Meta(table = "dtg_othertypesarraymodel")
end
const DTG_MODELS = [DtgCharFieldModel, DtgTextFieldModel, DtgNowTestModel, DtgUUIDTestModel, DtgIntegerArrayModel,
                    DtgNullableIntegerArrayModel, DtgNestedIntegerArrayModel, DtgHStoreModel, DtgRangesModel,
                    DtgOtherTypesArrayModel]
const DTG_PG = Juango.backend() isa Juango.PostgresBackend
redirect_stdout(devnull) do
    DTG_PG && foreach(e -> Juango.execute("CREATE EXTENSION IF NOT EXISTS $e"), ("pg_trgm", "unaccent"))
    Juango.sync_models!(DTG_MODELS); append!(PORT_MODELS, DTG_MODELS)
end
dtg_ids(qs) = sort([o.id for o in collect(qs)])
dtg_fields(qs) = [o.field for o in collect(qs)]
dtg_rows(qs, k) = [(r[:field], round(Float64(r[k]); digits = 6)) for r in collect(qs)]

port_block() do
    DTG_PG && @testset "django postgres_tests test_trigram: TrigramTest ($M)" for M in (DtgCharFieldModel, DtgTextFieldModel)
        for f in ("Matthew", "Cat sat on mat.", "Dog sat on rug.")
            create(M; field = f)
        end
        @test dtg_fields(filter(M; field__trigram_similar = "Mathew")) == ["Matthew"]               # test_trigram_search

        @test sort(dtg_fields(order_by(filter(M; field__trigram_similar = "Bat sat on cat."), :id))) ==  # test_trigram_similarity
              ["Cat sat on mat.", "Dog sat on rug."]
        qs = order_by(annotate(filter(M; field__trigram_similar = "Bat sat on cat."); similarity = TrigramSimilarity(:field, "Bat sat on cat.")), "-similarity")
        @test [(o.field, round(Float64(o.similarity); digits = 6)) for o in collect(qs)] == [("Cat sat on mat.", 0.625), ("Dog sat on rug.", 0.333333)]

        qs = order_by(values(annotate(filter(M; field__trigram_word_similar = "mat");                 # test_trigram_word_similarity
                                       word_similarity = TrigramWordSimilarity("mat", :field)), :field, :word_similarity), "-word_similarity")
        @test dtg_rows(qs, :word_similarity) == [("Cat sat on mat.", 1.0), ("Matthew", 0.75)]

        qs = order_by(values(annotate(filter(M; field__trigram_word_similar = "matt");                # test_trigram_strict_word_similarity
                                       word_similarity = TrigramStrictWordSimilarity("matt", :field)), :field, :word_similarity), "-word_similarity")
        @test dtg_rows(qs, :word_similarity) == [("Cat sat on mat.", 0.5), ("Matthew", 0.444444)]

        qs = order_by(filter(annotate(M; distance = TrigramDistance(:field, "Bat sat on cat.")); distance__lte = 0.7), :distance)  # test_trigram_similarity_alternate
        @test [(o.field, round(Float64(o.distance); digits = 6)) for o in collect(qs)] == [("Cat sat on mat.", 0.375), ("Dog sat on rug.", 0.666667)]

        qs = order_by(values(filter(annotate(M; word_distance = TrigramWordDistance("mat", :field)); word_distance__lte = 0.7),  # test_trigram_word_similarity_alternate
                             :field, :word_distance), :word_distance)
        @test dtg_rows(qs, :word_distance) == [("Cat sat on mat.", 0.0), ("Matthew", 0.25)]

        qs = order_by(values(filter(annotate(M; word_distance = TrigramStrictWordDistance("matt", :field)); word_distance__lte = 0.7),  # test_trigram_strict_word_distance
                             :field, :word_distance), :word_distance)
        @test dtg_rows(qs, :word_distance) == [("Cat sat on mat.", 0.5), ("Matthew", 0.555556)]

        qs = values(filter(annotate(M; concat_result = Concat(Value("I'm "), F(:field))); concat_result__trigram_similar = "im matthew"), :field)  # test_trigram_concat_precedence
        @test [r[:field] for r in collect(qs)] == ["Matthew"]

        obj = create(M; field = "Gumby rides on the path of Middlesbrough")
        @test dtg_ids(filter(M; field__trigram_word_similar = "Middlesborough")) == [obj.id]             # test_trigram_word_search
        @test dtg_ids(filter(M; field__trigram_word_similar = "Middle")) == [obj.id]
        @test dtg_ids(filter(M; field__trigram_strict_word_similar = "Middlesborough")) == [obj.id]      # test_trigram_strict_word_search_matched
        @test isempty(dtg_ids(filter(M; field__trigram_strict_word_similar = "Middle")))
    end

    DTG_PG && @testset "django postgres_tests test_unaccent: UnaccentTest ($M)" for M in (DtgCharFieldModel, DtgTextFieldModel)
        delete!(filter(M))
        for f in ("àéÖ", "aeO", "aeo")
            create(M; field = f)
        end
        @test sort(dtg_fields(filter(M; field__unaccent = "aeO"))) == sort(["àéÖ", "aeO"])               # test_unaccent
        @test sort(dtg_fields(filter(M; field__unaccent__iexact = "aeO"))) == sort(["àéÖ", "aeO", "aeo"])  # test_unaccent_chained
        @test sort(dtg_fields(filter(M; field__unaccent__endswith = "éÖ"))) == sort(["àéÖ", "aeO"])
        @test sort(dtg_fields(filter(M; field__unaccent = "aéÖ"))) == sort(["àéÖ", "aeO"])               # test_unaccent_accentuated_needle
    end

    DTG_PG && @testset "django postgres_tests test_functions" begin
        atomic() do                                                                              # TestTransactionNow
            m1 = create(DtgNowTestModel); m2 = create(DtgNowTestModel)
            update!(filter(DtgNowTestModel; id = m1.id); when = TransactionNow())
            sleep(0.1)
            update!(filter(DtgNowTestModel; id = m2.id); when = TransactionNow())
            m1 = refresh!(m1); m2 = refresh!(m2)
            @test m1.when isa DateTime
            @test m1.when == m2.when
        end
        m1 = create(DtgUUIDTestModel); m2 = create(DtgUUIDTestModel)                                 # TestRandomUUID
        update!(filter(DtgUUIDTestModel); uuid = RandomUUID())
        m1 = refresh!(m1); m2 = refresh!(m2)
        @test m1.uuid isa UUID
        @test m1.uuid != m2.uuid
    end

    @testset "django postgres_tests test_bulk_update: BulkSaveTests.test_bulk_update ($M.$f)" for (M, f, initial, new) in [
            (DtgIntegerArrayModel, :field, Int[], [1, 2, 3]),
            (DtgNullableIntegerArrayModel, :field, [1, 2, 3], nothing),
            (DtgNestedIntegerArrayModel, :field, Vector{Int}[], [[1, 2, 3]]),
            (DtgHStoreModel, :field, Dict{String,Any}(), Dict("1" => "2")),
            (DtgRangesModel, :ints, nothing, ValueRange(1, 10)),
            (DtgRangesModel, :dates, nothing, ValueRange(today(), today())),
            (DtgOtherTypesArrayModel, :ips, String[], ["1.2.3.4"]),
            (DtgOtherTypesArrayModel, :json, Any[], Any[Dict("a" => "b")])]
        objs = bulk_create([M(; (f => initial,)...) for _ in 1:20])
        for o in objs
            setproperty!(o, f, new)
        end
        bulk_update(objs, [f])
        @test sort(dtg_ids(filter(M; (f => new,)...))) == sort([o.id for o in objs])
        delete!(filter(M))
    end
end
