# Django's postgres_tests/test_array, ported (part, #227). Juango's ArrayField works on every backend (a native
# array on PostgreSQL, JSON text elsewhere), so these run on all three.
# julia --project=test test/django_postgres_array.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DpaIntegerArrayModel
    field = ArrayField(BigIntegerField(); default = Vector{Int}, blank = true)
    Meta(table = "dpa_integerarray")
end
@model struct DpaNullableIntegerArrayModel
    field = ArrayField(BigIntegerField(); blank = true, null = true)
    field_nested = ArrayField(ArrayField(BigIntegerField(; null = true)); null = true)
    order = IntegerField(null = true)
    Meta(table = "dpa_nullableintegerarray")
end
@model struct DpaCharArrayModel
    field = ArrayField(CharField(max_length = 10))
    Meta(table = "dpa_chararray")
end
@model struct DpaDateTimeArrayModel
    datetimes = ArrayField(DateTimeField())
    dates = ArrayField(DateField())
    times = ArrayField(TimeField())
    Meta(table = "dpa_datetimearray")
end
@model struct DpaWithSizeArrayModel
    field = ArrayField(FloatField(); size = 3)
    Meta(table = "dpa_withsizearray")
end
@model struct DpaNestedIntegerArrayModel
    field = ArrayField(ArrayField(IntegerField()))
    Meta(table = "dpa_nestedintegerarray")
end
@model struct DpaOtherTypesArrayModel
    ips = ArrayField(GenericIPAddressField(); default = Vector{String})
    uuids = ArrayField(UUIDField(); default = Vector{UUID})
    decimals = ArrayField(DecimalField(max_digits = 5, decimal_places = 2); default = Vector{Decimal})
    json = ArrayField(JSONField(); default = Vector{Any}, null = true)
    int_ranges = ArrayField(IntegerRangeField(); blank = true, null = true)
    Meta(table = "dpa_othertypesarray")
end
@model struct DpaChoicesArrayModel
    field = ArrayField(CharField(max_length = 16); choices = ["Media" => [["vinyl", "cd"] => "Audio"], ["mp3", "mp4"] => "Digital"])
    Meta(table = "dpa_choicesarray")
end
@model struct DpaNestedChoicesArrayModel
    field = ArrayField(ArrayField(CharField(max_length = 16)); choices = ["Media" => [[["vinyl", "cd"], ["x"]] => "Audio"],
                                                                          [["mp3"], ["mp4"]] => "Digital"])
    Meta(table = "dpa_nestedchoicesarray")
end
const DPA_MODELS = [DpaIntegerArrayModel, DpaNullableIntegerArrayModel, DpaCharArrayModel, DpaDateTimeArrayModel,
                    DpaWithSizeArrayModel, DpaNestedIntegerArrayModel, DpaOtherTypesArrayModel]
redirect_stdout(devnull) do
    Juango.sync_models!(DPA_MODELS); append!(PORT_MODELS, DPA_MODELS)
end
dpa_ids(qs) = sort([o.id for o in qs])

@testset "django postgres_tests test_array: TestSaveLoad" begin
    port_block() do
        i = create(DpaIntegerArrayModel; field = [1, 2, 3])                                  # test_integer
        @test get(DpaIntegerArrayModel; id = i.id).field == [1, 2, 3]
        c = create(DpaCharArrayModel; field = ["hello", "goodbye"])                         # test_char
        @test get(DpaCharArrayModel; id = c.id).field == ["hello", "goodbye"]
        t = now(); d = create(DpaDateTimeArrayModel; datetimes = [t], dates = [Date(t)], times = [Time(t)])   # test_dates
        l = get(DpaDateTimeArrayModel; id = d.id)
        @test l.datetimes == [t]
        @test l.dates == [Date(t)]
        @test l.times == [Time(t)]
        i = create(DpaIntegerArrayModel; field = (1,))                                      # test_tuples
        @test collect(get(DpaIntegerArrayModel; id = i.id).field) == [1]
        i = create(DpaIntegerArrayModel; field = ["1"])                                     # test_integers_passed_as_strings
        @test get(DpaIntegerArrayModel; id = i.id).field == [1]
        n = create(DpaNullableIntegerArrayModel)                                            # test_default_null
        @test get(DpaNullableIntegerArrayModel; id = n.id).field === nothing
        n = create(DpaNullableIntegerArrayModel; field = nothing)                           # test_null_handling
        @test get(DpaNullableIntegerArrayModel; id = n.id).field === nothing
        @test_throws Juango.IntegrityError save!(DpaIntegerArrayModel(; field = nothing))
        x = create(DpaNestedIntegerArrayModel; field = [[1, 2], [3, 4]])                    # test_nested
        @test get(DpaNestedIntegerArrayModel; id = x.id).field == [[1, 2], [3, 4]]
        u = uuid4()                                                                         # test_other_array_types
        o = create(DpaOtherTypesArrayModel; uuids = [u], decimals = [Decimal("1.25"), 1.75], json = [Dict("a" => 1), Dict("b" => 2)],
                   int_ranges = [ValueRange(10, 20), ValueRange(30, 40)])
        l = get(DpaOtherTypesArrayModel; id = o.id)
        @test l.uuids == [u] && l.decimals == [Decimal("1.25"), Decimal("1.75")] && l.json == [Dict("a" => 1), Dict("b" => 2)]
        @test l.int_ranges == [ValueRange(10, 20), ValueRange(30, 40)]
        o = create(DpaOtherTypesArrayModel; uuids = [u], decimals = [Decimal("1.25")])       # test_null_from_db_value_handling
        refresh!(o)
        @test o.json == [] && o.int_ranges === nothing
        n = create(DpaNullableIntegerArrayModel; field_nested = [[nothing, nothing], [nothing, nothing]])   # test_nested_nullable_base_field
        @test get(DpaNullableIntegerArrayModel; id = n.id).field_nested == [[nothing, nothing], [nothing, nothing]]
        # TestValidation.test_with_size
        @test get(full_clean(DpaWithSizeArrayModel(; field = [1, 2, 3, 4])), :field, String[]) ==
              ["List contains 4 items, it should contain no more than 3."]
        @test isempty(full_clean(DpaWithSizeArrayModel(; field = [1, 2, 3])))
    end
end

@testset "django postgres_tests test_array: TestQuerying" begin
    port_block() do
        M = DpaNullableIntegerArrayModel
        objs = [create(M; order = 1, field = [1]), create(M; order = 2, field = [2]), create(M; order = 3, field = [2, 3]),
                create(M; order = 4, field = [20, 30, 40]), create(M; order = 5, field = nothing)]
        ids(r) = sort([objs[i].id for i in r])
        s = bulk_create([DpaWithSizeArrayModel(; field = [1, 2]), DpaWithSizeArrayModel(; field = [3, 4])])   # test_bulk_create_with_sized_arrayfield
        @test s[1].field == [1, 2] && s[2].field == [3, 4]
        @test dpa_ids(filter(M; field__exact = [1])) == ids(1:1)                            # test_exact
        @test dpa_ids(filter(M; field = [Value(1)])) == ids(1:1)                            # test_exact_with_expression
        c = create(DpaCharArrayModel; field = ["text"])                                     # test_exact_charfield
        @test dpa_ids(filter(DpaCharArrayModel; field = ["text"])) == [c.id]
        n = create(DpaNestedIntegerArrayModel; field = [[1, 2], [3, 4]])                    # test_exact_nested
        @test dpa_ids(filter(DpaNestedIntegerArrayModel; field = [[1, 2], [3, 4]])) == [n.id]
        @test dpa_ids(filter(M; field__isnull = true)) == ids(5:5)                          # test_isnull
        @test dpa_ids(filter(M; field__in = [[1], [2]])) == ids(1:2)                        # test_in
        create(DpaIntegerArrayModel; field = [2, 3])                                        # test_in_subquery
        @test dpa_ids(filter(M; field__in = values_list(objects(DpaIntegerArrayModel), :field; flat = true))) == ids(3:3)
        @test dpa_ids(filter(M; field__contained_by = [1, 2])) == ids(1:2)                  # test_contained_by
        @test dpa_ids(filter(M; field__contains = [2])) == ids(2:3)                         # test_contains
        @test isempty(filter(DpaCharArrayModel; field__contains = ["nope"]))                # test_contains_charfield
        @test isempty(filter(DpaCharArrayModel; field__contained_by = ["nope"]))            # test_contained_by_charfield
        @test isempty(filter(DpaCharArrayModel; field__overlap = ["nope"]))                 # test_overlap_charfield
        @test dpa_ids(filter(M; field__overlap = [1, 2])) == ids(1:3)                       # test_overlap
        @test dpa_ids(filter(M; field__len__lte = 2)) == ids(1:3)                           # test_len
        e = create(M; field = Int[])                                                        # test_len_empty_array
        @test dpa_ids(filter(M; field__len = 0)) == [e.id]
        delete!(e)
        @test dpa_ids(filter(M; field__0 = 2)) == ids(2:3)                                  # test_index
        @test dpa_ids(filter(M; field__0__lt = 3)) == ids(1:3)                              # test_index_chained
        @test dpa_ids(filter(DpaNestedIntegerArrayModel; field__0__0 = 1)) == [n.id]        # test_index_nested
        @test sort(collect(values_list(annotate(M; second = F(:field__1)), :second; flat = true)), by = x -> something(x, -1)) ==
              [nothing, nothing, nothing, 3, 30]                                            # test_index_annotation
        @test dpa_ids(filter(M; id__in = filter(M; field__len = 3))) == ids(4:4)           # test_usage_in_subquery
        # test_lookups_autofield_array / test_order_by_arrayagg_index (ArrayAgg)
        qs = order_by(annotate(values(filter(M; field__0__isnull = false), :field__0); arrayagg = ArrayAgg(:id; ordering = "id")), "field__0")
        @test [(r[:field__0], r[:arrayagg]) for r in qs] == [(1, [objs[1].id]), (2, [objs[2].id, objs[3].id]), (20, [objs[4].id])]
        @test dpa_ids(filter(M; field__0_1 = [2])) == ids(2:3)                              # test_slice
        @test dpa_ids(filter(M; field__0_2 = [2, 3])) == ids(3:3)
        @test sort(collect(values_list(annotate(M; first_two = F(:field__0_2)), :first_two; flat = true)),   # test_slice_annotation
                   by = x -> x === nothing ? [-1] : x) == [nothing, [1], [2], [2, 3], [20, 30]]
        @test dpa_ids(filter(M; field__contains = [Value(2)])) == ids(2:3)                  # test_contains_including_expression
        # test_index_used_on_nested_data (an expected failure in Django: PostgreSQL's field[1] of a 2-D array is NULL)
        if Juango.backend() isa Juango.PostgresBackend
            @test_broken dpa_ids(filter(DpaNestedIntegerArrayModel; field__0 = [1, 2])) == [n.id]
        else
            @test dpa_ids(filter(DpaNestedIntegerArrayModel; field__0 = [1, 2])) == [n.id]
        end
        if Juango.backend() isa Juango.PostgresBackend
            @test dpa_ids(filter(M; field__gt = [0])) == ids(1:4)                           # test_gt
            @test dpa_ids(filter(M; field__lt = [2])) == ids(1:1)                           # test_lt
        else
            @test_broken false      # arrays compared item by item (lexicographically) need PostgreSQL's arrays (#296)
        end
        more = [create(M; field = [1, 637]), create(M; field = [2, 1]), create(M; field = [3, -98123]), create(M; field = [4, 2])]
        # test_order_by_index (Django's order puts NULL last, as PostgreSQL sorts ascending)
        got = [o.id for o in order_by(filter(M; field__1__isnull = false), "field__1")]
        @test got == [more[3].id, more[2].id, more[4].id, objs[3].id, objs[4].id, more[1].id]
        foreach(delete!, more)
        o = create(M; field = [nothing], field_nested = [nothing, nothing])                # test_exact_null_only_array
        @test dpa_ids(filter(M; field__exact = [nothing])) == [o.id]
        @test dpa_ids(filter(M; field_nested__exact = [nothing, nothing])) == [o.id]
        o1 = create(M; field_nested = [[nothing, nothing]])                                  # test_exact_null_only_nested_array
        o2 = create(M; field_nested = [[nothing, nothing], [nothing, nothing]])
        @test dpa_ids(filter(M; field_nested__exact = [[nothing, nothing]])) == [o1.id]
        @test dpa_ids(filter(M; field_nested__exact = [[nothing, nothing], [nothing, nothing]])) == [o2.id]
    end
end

@testset "django postgres_tests test_array: exact querying of other types" begin
    port_block() do
        t = now(); d = create(DpaDateTimeArrayModel; datetimes = [t], dates = [Date(t)], times = [Time(t)])
        @test dpa_ids(filter(DpaDateTimeArrayModel; datetimes = [t])) == [d.id]              # test_exact_datetimes
        @test dpa_ids(filter(DpaDateTimeArrayModel; dates = [Date(t)])) == [d.id]            # test_exact_dates
        @test dpa_ids(filter(DpaDateTimeArrayModel; times = [Time(t)])) == [d.id]            # test_exact_times
        ips, uuids, decimals = ["192.168.0.1", "::1"], [uuid4()], [Decimal("1.25"), 1.75]
        o = create(DpaOtherTypesArrayModel; ips = ips, uuids = uuids, decimals = decimals)
        @test dpa_ids(filter(DpaOtherTypesArrayModel; ips = ips)) == [o.id]                  # test_exact_ip_addresses
        @test dpa_ids(filter(DpaOtherTypesArrayModel; uuids = uuids)) == [o.id]              # test_exact_uuids
        @test dpa_ids(filter(DpaOtherTypesArrayModel; decimals = decimals)) == [o.id]        # test_exact_decimals
        # test_exact_tags: not translated (a custom field class whose values are Python objects)
    end
end

@testset "django postgres_tests test_array: BasicTests (get_FIELD_display)" begin
    # Django's model is built in the test; here a model that isn't synced (no table is needed)
    @test get_display(DpaChoicesArrayModel(; field = ["vinyl", "cd"]), :field) == "Audio"          # test_get_field_display
    @test get_display(DpaChoicesArrayModel(; field = ["mp3", "mp4"]), :field) == "Digital"
    @test get_display(DpaChoicesArrayModel(; field = ["c", "d"]), :field) == string(["c", "d"])      # (Julia's repr, as Django shows Python's)
    @test get_display(DpaNestedChoicesArrayModel(; field = [["vinyl", "cd"], ["x"]]), :field) == "Audio"   # test_get_field_display_nested_array
    @test get_display(DpaNestedChoicesArrayModel(; field = [["mp3"], ["mp4"]]), :field) == "Digital"
    @test get_display(DpaNestedChoicesArrayModel(; field = [["a", "b"], ["c"]]), :field) == string([["a", "b"], ["c"]])
end

@testset "django postgres_tests test_array: TestValidation" begin
    msgs(f, v) = try clean(f, v); String[] catch e; e isa ValidationError || rethrow(); reduce(vcat, collect(values(e.errors)); init = String[]) end
    @test msgs(ArrayField(IntegerField()), [1, nothing]) == ["Item 2 in the array did not validate: This field cannot be null."]   # test_unbounded
    @test isempty(msgs(ArrayField(IntegerField(; blank = true, null = true)), [1, nothing]))           # test_blank_true
    @test isempty(msgs(ArrayField(IntegerField(); size = 3), [1, 2, 3]))                                # test_with_size
    @test msgs(ArrayField(IntegerField(); size = 3), [1, 2, 3, 4]) == ["List contains 4 items, it should contain no more than 3."]
    @test isempty(msgs(ArrayField(IntegerField(); size = 1), [1]))                                      # test_with_size_singular
    @test msgs(ArrayField(IntegerField(); size = 1), [1, 2]) == ["List contains 2 items, it should contain no more than 1."]
    @test isempty(msgs(ArrayField(ArrayField(IntegerField())), [[1, 2], [3, 4]]))                      # test_nested_array_mismatch
    @test msgs(ArrayField(ArrayField(IntegerField())), [[1, 2], [3, 4, 5]]) == ["Nested arrays must have the same length."]
    @test msgs(ArrayField(CharField(max_length = 2)), ["abc"]) ==                                       # test_with_base_field_error_params
          ["Item 1 in the array did not validate: Ensure this value has at most 2 characters (it has 3)."]
    f = ArrayField(IntegerField(; validators = [MinValueValidator(1)]))                                  # test_with_validators
    @test isempty(msgs(f, [1, 2]))
    @test msgs(f, [0]) == ["Item 1 in the array did not validate: Ensure this value is greater than or equal to 1."]
end

@testset "django postgres_tests test_array: TestSimpleFormField" begin
    msgs(f, v) = try clean(f, v); String[] catch e; e isa ValidationError || rethrow(); reduce(vcat, collect(values(e.errors)); init = String[]) end
    @test clean(SimpleArrayField(CharField()), "a,b,c") == ["a", "b", "c"]                               # test_valid
    @test msgs(SimpleArrayField(IntegerField()), "a,b,9")[1] == "Item 1 in the array did not validate: Enter a whole number."   # test_to_python_fail
    @test msgs(SimpleArrayField(CharField(required = true)), "a,b,") == ["Item 3 in the array did not validate: This field is required."]   # test_validate_fail
    @test msgs(SimpleArrayField(CharField(max_length = 2)), "abc,c,defg") ==                             # test_validate_fail_base_field_error_params
          ["Item 1 in the array did not validate: Ensure this value has at most 2 characters (it has 3).",
           "Item 3 in the array did not validate: Ensure this value has at most 2 characters (it has 4)."]
    @test msgs(SimpleArrayField(RegexField(r"[a-e]{2}")), "a,bc,de") == ["Item 1 in the array did not validate: Enter a valid value."]   # test_validators_fail
    @test clean(SimpleArrayField(CharField(); delimiter = "|"), "a|b|c") == ["a", "b", "c"]             # test_delimiter
    @test clean(SimpleArrayField(SimpleArrayField(CharField()); delimiter = "|"), "a,b|c,d") == [["a", "b"], ["c", "d"]]   # test_delimiter_with_nesting
    @test Juango.array_form_text(SimpleArrayField(CharField()), ["a", "b", "c"]) == "a,b,c"             # test_prepare_value
    @test msgs(SimpleArrayField(CharField(); max_length = 2), "a,b,c") == ["List contains 3 items, it should contain no more than 2."]   # test_max_length
    @test msgs(SimpleArrayField(CharField(); min_length = 4), "a,b,c") == ["List contains 3 items, it should contain no fewer than 4."]  # test_min_length
    @test clean(SimpleArrayField(IntegerField(); min_length = 2), [1, 2]) == [1, 2]                      # test_min_length_singular
    @test msgs(SimpleArrayField(IntegerField(); min_length = 2), [1]) == ["List contains 1 item, it should contain no fewer than 2."]
    @test msgs(SimpleArrayField(CharField(); required = true), "") == ["This field is required."]         # test_required
    mf = ArrayField(CharField(max_length = 27))                                                          # test_model_field_formfield
    @test Juango.array_base(mf).max_length == 27
    @test Juango.array_size(ArrayField(CharField(max_length = 27); size = 4)) == 4                       # test_model_field_formfield_size
    @test clean(ArrayField(IntegerField(choices = [1 => "A", 2 => "B"])), "1,2") == [1, 2]               # test_model_field_choices
    @test clean(SimpleArrayField(CharField()), ["a", "b", "c"]) == ["a", "b", "c"]                      # test_already_converted_value
    changed(f, initial, data) = has_changed(Form([:f => f]; data = Dict{String,Any}("f" => data), initial = Dict{Symbol,Any}(:f => initial)))
    @test !changed(SimpleArrayField(IntegerField()), [1, 2], "1,2")                                     # test_has_changed
    @test changed(SimpleArrayField(IntegerField()), [1, 2], "1,2,3")
    @test changed(SimpleArrayField(IntegerField()), [1, 2], "a,b")
    @test !changed(SimpleArrayField(CharField()), nothing, "")                                          # test_has_changed_empty
    @test !changed(SimpleArrayField(CharField()), [], "")
end
