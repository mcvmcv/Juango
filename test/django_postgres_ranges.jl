# Django's postgres_tests/test_ranges, ported (#227). Juango's range fields work on every backend (PostgreSQL's
# ranges, JSON elsewhere), so these run on all three. Django's NumericRange, DateRange and DateTimeTZRange are
# Juango's ValueRange.
# julia --project=test test/django_postgres_ranges.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DrgRangesModel
    ints = IntegerRangeField(blank = true, null = true)
    bigints = BigIntegerRangeField(blank = true, null = true)
    decimals = DecimalRangeField(blank = true, null = true)
    timestamps = DateTimeRangeField(blank = true, null = true)
    timestamps_inner = DateTimeRangeField(blank = true, null = true)
    timestamps_closed_bounds = DateTimeRangeField(blank = true, null = true, default_bounds = "[]")
    dates = DateRangeField(blank = true, null = true)
    dates_inner = DateRangeField(blank = true, null = true)
    Meta(table = "drg_ranges")
end
@model struct DrgRangeLookupsModel
    parent = ForeignKey(DrgRangesModel; on_delete = :SET_NULL, blank = true, null = true)
    integer = IntegerField(blank = true, null = true)
    big_integer = BigIntegerField(blank = true, null = true)
    float = FloatField(blank = true, null = true)
    timestamp = DateTimeField(blank = true, null = true)
    date = DateField(blank = true, null = true)
    small_integer = SmallIntegerField(blank = true, null = true)
    decimal_field = DecimalField(max_digits = 5, decimal_places = 2, blank = true, null = true)
    Meta(table = "drg_rangelookups")
end
@model struct DrgChoicesModel
    field = IntegerRangeField(choices = ["1-50" => [(1, 25) => "1-25", [26, 50] => "26-50"], (51, 100) => "51-100"])
    Meta(table = "drg_choices")
end
const DRG_MODELS = [DrgRangesModel, DrgRangeLookupsModel]
redirect_stdout(devnull) do
    Juango.sync_models!(DRG_MODELS); append!(PORT_MODELS, DRG_MODELS)
end
drg_ids(qs) = sort([o.id for o in qs])

@testset "django postgres_tests test_ranges: BasicTests" begin
    for (value, display) in [((1, 25), "1-25"), ([26, 50], "26-50"), ((51, 100), "51-100"), ((1, 2), "(1, 2)"), ([1, 2], "[1, 2]")]
        @test get_display(DrgChoicesModel(; field = value), :field) == display                     # test_get_field_display
    end
    for F in (BigIntegerRangeField, IntegerRangeField, DateRangeField)                              # test_discrete_range_fields_unsupported_default_bounds
        @test_throws "Cannot use 'default_bounds' with $(nameof(F))." F(default_bounds = "[]")
    end
    for F in (DecimalRangeField, DateTimeRangeField)                                                # test_continuous_range_fields_default_bounds
        @test Juango.range_default_bounds(F(default_bounds = "[]")) == "[]"
    end
    for b in (")]", ")[", "](", "])", "([", "[(", "x", "")                                          # test_invalid_default_bounds
        @test_throws "default_bounds must be one of '[)', '(]', '()', or '[]'." DecimalRangeField(default_bounds = b)
    end
    # test_deconstruct: field options aren't deconstructed (Juango's migrations compare columns)
end

@testset "django postgres_tests test_ranges: TestSaveLoad" begin
    port_block() do
        M = DrgRangesModel
        t = now()
        o = create(M; ints = ValueRange(0, 10), bigints = ValueRange(10, 20), decimals = ValueRange(Decimal(20), Decimal(30)),   # test_all_fields
                   timestamps = ValueRange(t - Hour(1), t), dates = ValueRange(Date(t) - Day(1), Date(t)))
        l = get(M; id = o.id)
        @test l.ints == ValueRange(0, 10) && l.bigints == ValueRange(10, 20) && l.decimals == ValueRange(Decimal(20), Decimal(30))
        @test l.timestamps == ValueRange(t - Hour(1), t) && l.dates == ValueRange(Date(t) - Day(1), Date(t))
        o = create(M; ints = ValueRange(0, 10)); @test get(M; id = o.id).ints == ValueRange(0, 10)         # test_range_object
        o = create(M; ints = (0, 10)); @test get(M; id = o.id).ints == ValueRange(0, 10)                   # test_tuple
        r = (t, t + Hour(1))                                                                              # test_tuple_range_with_default_bounds
        o = create(M; timestamps_closed_bounds = r, timestamps = r)
        l = get(M; id = o.id)
        @test l.timestamps_closed_bounds == ValueRange(r...; bounds = "[]")
        @test l.timestamps == ValueRange(r...; bounds = "[)")
        r = ValueRange(Decimal(0), Decimal(10); bounds = "[]")                                             # test_range_object_boundaries
        o = create(M; decimals = r); l = get(M; id = o.id)
        @test l.decimals == r && Decimal(10) in l.decimals
        r = ValueRange(t, t + Hour(1); bounds = "()")                                                     # test_range_object_boundaries_range_with_default_bounds
        o = create(M; timestamps_closed_bounds = r); @test get(M; id = o.id).timestamps_closed_bounds == r
        r = ValueRange(nothing, nothing; bounds = "()")                                                   # test_unbounded
        o = create(M; decimals = r); @test get(M; id = o.id).decimals == r
        o = create(M; ints = ValueRange(; empty = true))                                                  # test_empty
        @test isempty(get(M; id = o.id).ints) && get(M; id = o.id).ints == ValueRange(; empty = true)
        o = create(M; ints = nothing); @test get(M; id = o.id).ints === nothing                           # test_null
        # test_model_set_on_base_field: not translated (a range field has no base field object here)
    end
end

@testset "django postgres_tests test_ranges: TestRangeContainsLookup" begin
    port_block() do
        M = DrgRangesModel
        ts = [DateTime(2016, 1, 1), DateTime(2016, 1, 2, 1), DateTime(2016, 1, 2, 12), DateTime(2016, 1, 3), DateTime(2016, 1, 3, 1), DateTime(2016, 2, 2)]
        aware = [Juango.make_aware(x) for x in ts]
        ds = [Date(2016, 1, 1), Date(2016, 1, 2), Date(2016, 1, 3), Date(2016, 1, 4), Date(2016, 2, 2), Date(2016, 2, 3)]
        obj = create(M; dates = (ds[1], ds[4]), dates_inner = (ds[2], ds[3]), timestamps = (ts[1], ts[4]), timestamps_inner = (ts[2], ts[3]))
        aobj = create(M; dates = (ds[1], ds[4]), dates_inner = (ds[2], ds[3]), timestamps = (aware[1], aware[4]), timestamps_inner = (ts[2], ts[3]))
        create(M; dates = (ds[4], ds[5]), timestamps = (ts[4], ts[5]))
        create(M; dates = (ds[4], ds[5]), timestamps = (aware[4], aware[5]))
        want = sort([obj.id, aobj.id])
        # test_datetime_range_contains (Func(F("dates"), "lower") and F("timestamps_inner") aren't translated)
        for arg in (ts[2], aware[2], (ts[2], ts[3]), (aware[2], aware[3]), Value(DateTime(ds[1])))
            @test drg_ids(filter(M; timestamps__contains = arg)) == want
        end
        for arg in (ts[2], (ds[2], ds[3]), Value(ds[1]))                                                 # test_date_range_contains
            @test drg_ids(filter(M; dates__contains = arg)) == want
        end
    end
end

@testset "django postgres_tests test_ranges: TestQuerying" begin
    port_block() do
        M = DrgRangesModel
        objs = bulk_create([M(; ints = ValueRange(0, 10)), M(; ints = ValueRange(5, 15)), M(; ints = ValueRange(nothing, 0)),
                            M(; ints = ValueRange(; empty = true)), M(; ints = nothing)])
        ids(r) = sort([objs[i].id for i in r])
        @test drg_ids(filter(M; ints__exact = ValueRange(0, 10))) == ids(1:1)                   # test_exact
        @test drg_ids(filter(M; ints__isnull = true)) == ids(5:5)                               # test_isnull
        @test drg_ids(filter(M; ints__isempty = true)) == ids(4:4)                              # test_isempty
        @test drg_ids(filter(M; ints__contains = 8)) == ids(1:2)                                # test_contains
        @test drg_ids(filter(M; ints__contains = ValueRange(3, 8))) == ids(1:1)                 # test_contains_range
        @test drg_ids(filter(M; ints__contained_by = ValueRange(0, 20))) == ids([1, 2, 4])      # test_contained_by
        @test drg_ids(filter(M; ints__overlap = ValueRange(3, 8))) == ids(1:2)                  # test_overlap
        @test drg_ids(filter(M; ints__fully_lt = ValueRange(5, 10))) == ids(3:3)                # test_fully_lt
        @test isempty(filter(M; ints__fully_gt = ValueRange(5, 10)))                            # test_fully_gt
        @test drg_ids(filter(M; ints__not_lt = ValueRange(5, 10))) == ids(2:2)                  # test_not_lt
        @test drg_ids(filter(M; ints__not_gt = ValueRange(5, 10))) == ids([1, 3])               # test_not_gt
        @test drg_ids(filter(M; ints__adjacent_to = ValueRange(0, 5))) == ids(2:3)              # test_adjacent_to
        @test drg_ids(filter(M; ints__startswith = 0)) == ids(1:1)                              # test_startswith
        @test drg_ids(filter(M; ints__endswith = 0)) == ids(3:3)                                # test_endswith
        @test drg_ids(filter(M; ints__startswith__gte = 0)) == ids(1:2)                         # test_startswith_chaining
        d = bulk_create([M(; decimals = ValueRange(nothing, Decimal(10))), M(; decimals = ValueRange(Decimal(10), nothing)),
                         M(; decimals = ValueRange(Decimal(5), Decimal(15))), M(; decimals = ValueRange(Decimal(5), Decimal(15); bounds = "(]"))])
        dids(r) = sort([d[i].id for i in r])
        for (contains, want) in [(199, [2]), (1, [1]), (15, [2, 4])]                             # test_decimal_contains_range
            @test drg_ids(filter(M; decimals__contains = contains)) == dids(want)
        end
        for (lookup, arg, want) in [("lower_inc", true, [2, 3]), ("lower_inc", false, [1, 4]), ("lower_inf", true, [1]),   # test_bound_type
                                    ("lower_inf", false, [2, 3, 4]), ("upper_inc", true, [4]), ("upper_inc", false, [1, 2, 3]),
                                    ("upper_inf", true, [2]), ("upper_inf", false, [1, 3, 4])]
            @test drg_ids(filter(M; Symbol("decimals__", lookup) => arg)) == dids(want)
        end
    end
end

@testset "django postgres_tests test_ranges: TestQueryingWithRanges" begin
    port_block() do
        L = DrgRangeLookupsModel
        o = [create(L; date = Date(2015, 1, 1)), create(L; date = Date(2015, 5, 5))]                     # test_date_range
        @test drg_ids(filter(L; date__contained_by = ValueRange(Date(2015, 1, 1), Date(2015, 5, 4)))) == [o[1].id]
        delete!(filter(L))
        o = [create(L; timestamp = DateTime(2015, 1, 1)), create(L; timestamp = DateTime(2015, 5, 5))]   # test_date_range_datetime_field
        @test drg_ids(filter(L; timestamp__date__contained_by = ValueRange(Date(2015, 1, 1), Date(2015, 5, 4)))) == [o[1].id]
        delete!(filter(L))
        o = [create(L; timestamp = DateTime(2015, 1, 1, 9)), create(L; timestamp = DateTime(2015, 5, 5, 17))]   # test_datetime_range
        @test drg_ids(filter(L; timestamp__contained_by = ValueRange(DateTime(2015, 1, 1, 9), DateTime(2015, 5, 4, 23, 55)))) == [o[1].id]
        delete!(filter(L))
        for (fld, vals, r, want) in [(:small_integer, [8, 4, -1], ValueRange(4, 6), 2),                  # test_small_integer_field_contained_by
                                     (:integer, [5, 99, -1], ValueRange(1, 98), 1),                      # test_integer_range
                                     (:big_integer, [5, 99, -1], ValueRange(1, 98), 1),                  # test_biginteger_range
                                     (:decimal_field, [Decimal("1.33"), Decimal("2.88"), Decimal("99.17")],
                                      ValueRange(Decimal("1.89"), Decimal("7.91")), 2),                  # test_decimal_field_contained_by
                                     (:float, [5, 99, -1], ValueRange(1, 98), 1)]                        # test_float_range
            o = [create(L; fld => v) for v in vals]
            @test drg_ids(filter(L; Symbol(fld, "__contained_by") => r)) == [o[want].id]
            delete!(filter(L))
        end
        o = bulk_create([L() for _ in 1:4])                                                              # test_auto_field_contained_by
        @test drg_ids(filter(L; id__contained_by = ValueRange(o[2].pk, o[4].pk))) == sort([o[2].id, o[3].id])
        # test_small_auto_field_contained_by / test_big_auto_field_contained_by: Juango's keys are one kind
        delete!(filter(L))
        # test_f_ranges: not translated (contained_by an F() of a range column)
        o = [create(L; float = 5), create(L; float = 99), create(L; float = -1)]                        # test_exclude
        @test drg_ids(exclude(L; float__contained_by = ValueRange(0, 100))) == [o[3].id]
    end
end

@testset "django postgres_tests test_ranges: TestSerialization" begin
    M = DrgRangesModel
    lo_dt, hi_dt = DateTime(2014, 1, 1), DateTime(2014, 2, 2, 12, 12, 12)
    # test_loading: Django's fixture (ranges as JSON text, bounds as text, {"empty": true})
    data = """[{"fields": {"ints": "{\\"upper\\": \\"10\\", \\"lower\\": \\"0\\", \\"bounds\\": \\"[)\\"}", "decimals": "{\\"empty\\": true}",
               "bigints": null, "timestamps": "{\\"upper\\": \\"2014-02-02T12:12:12+00:00\\", \\"lower\\": \\"2014-01-01T00:00:00+00:00\\", \\"bounds\\": \\"[)\\"}",
               "timestamps_inner": null,
               "timestamps_closed_bounds": "{\\"upper\\": \\"2014-02-02T12:12:12+00:00\\", \\"lower\\": \\"2014-01-01T00:00:00+00:00\\", \\"bounds\\": \\"()\\"}",
               "dates": "{\\"upper\\": \\"2014-02-02\\", \\"lower\\": \\"2014-01-01\\", \\"bounds\\": \\"[)\\"}", "dates_inner": null},
               "model": "$(Juango.model_label(M))", "pk": null}]"""
    o = only(deserialize(:json, data)).object
    @test o.ints == ValueRange(0, 10) && o.decimals == ValueRange(; empty = true) && o.bigints === nothing
    @test o.dates == ValueRange(Date(2014, 1, 1), Date(2014, 2, 2))
    utc(x) = x isa DateTime ? x : Juango.to_utc_naive(x)
    @test ValueRange(utc(o.timestamps.lower), utc(o.timestamps.upper)) == ValueRange(lo_dt, hi_dt)
    @test ValueRange(utc(o.timestamps_closed_bounds.lower), utc(o.timestamps_closed_bounds.upper); bounds = o.timestamps_closed_bounds.bounds) ==
          ValueRange(lo_dt, hi_dt; bounds = "()")
    # test_dumping: Juango's serializer writes a range as an object, not as JSON text; it round-trips
    i = M(; ints = ValueRange(0, 10), decimals = ValueRange(; empty = true), timestamps = ValueRange(lo_dt, hi_dt),
          timestamps_closed_bounds = ValueRange(lo_dt, hi_dt; bounds = "()"), dates = ValueRange(Date(2014, 1, 1), Date(2014, 2, 2)))
    back = only(deserialize(:json, serialize(:json, [i]))).object
    @test back.ints == i.ints && back.decimals == i.decimals && back.dates == i.dates && back.timestamps_closed_bounds == i.timestamps_closed_bounds
    for r in (ValueRange(nothing, 10), ValueRange(10, nothing))                                         # test_serialize_range_with_null
        @test only(deserialize(:json, serialize(:json, [M(; ints = r)]))).object.ints == r
    end
end

@testset "django postgres_tests test_ranges: TestChecks, TestValidators" begin
    @test isempty(Juango.model_check_issues(DrgChoicesModel))                                          # test_choices_tuple_list
    v = RangeMaxValueValidator(5)                                                                       # test_max
    @test v(ValueRange(0, 5)) === nothing
    @test Juango.validation_error(v, ValueRange(0, 10)) == ("max_value", "Ensure that the upper bound of the range is not greater than 5.")
    @test v(ValueRange(0, nothing)) == "Ensure that the upper bound of the range is not greater than 5."
    v = RangeMinValueValidator(5)                                                                       # test_min
    @test v(ValueRange(10, 15)) === nothing
    @test Juango.validation_error(v, ValueRange(0, 10)) == ("min_value", "Ensure that the lower bound of the range is not less than 5.")
    @test v(ValueRange(nothing, 10)) == "Ensure that the lower bound of the range is not less than 5."
end

@testset "django postgres_tests test_ranges: TestFormField" begin
    msgs(f, v) = try clean(f, v); String[] catch e; e isa ValidationError || rethrow(); reduce(vcat, collect(values(e.errors)); init = String[]) end
    @test clean(IntegerRangeField(), ["1", "2"]) == ValueRange(1, 2)                                    # test_valid_integer
    @test clean(DecimalRangeField(), ["1.12345", "2.001"]) == ValueRange(Decimal("1.12345"), Decimal("2.001"))   # test_valid_decimal
    @test clean(DateTimeRangeField(), ["01/01/2014 00:00:00", "02/02/2014 12:12:12"]) ==                # test_valid_timestamps
          ValueRange(DateTime(2014, 1, 1), DateTime(2014, 2, 2, 12, 12, 12))
    @test clean(DateRangeField(), ["01/01/2014", "02/02/2014"]) == ValueRange(Date(2014, 1, 1), Date(2014, 2, 2))   # test_valid_dates
    # test_using_split_datetime_widget, test_datetime_form_as_table, test_rendering, TestWidget: Juango's range form
    # fields are one text input ("lower, upper"), not Django's two (#298)
    @test clean(IntegerRangeField(; required = false), ["", ""]) === nothing                            # test_none
    for (F, lohi, open_, opened, bad, badmsg, two) in [
            (IntegerRangeField, ["10", "2"], ["", "0"], ValueRange(nothing, 0), "a", "Enter a whole number.", "Enter two whole numbers."),
            (DecimalRangeField, ["1.8", "1.6"], ["", "3.1415926"], ValueRange(nothing, Decimal("3.1415926")), "a", "Enter a number.", "Enter two numbers."),
            (DateRangeField, ["2013-04-09", "1976-04-16"], ["", "2013-04-09"], ValueRange(nothing, Date(2013, 4, 9)), "a", "Enter a valid date.", "Enter two valid dates."),
            (DateTimeRangeField, ["2006-10-25 14:59", "2006-10-25 14:58"], ["", "2013-04-09 11:45"], ValueRange(nothing, DateTime(2013, 4, 9, 11, 45)),
             "a", "Enter a valid date/time.", "Enter two valid date/times.")]
        @test msgs(F(), lohi) == ["The start of the range must not exceed the end of the range."]       # test_*_lower_bound_higher
        @test clean(F(), open_) == opened                                                                # test_*_open
        @test msgs(F(), "1") == [two]                                                                    # test_*_incorrect_data_type
        @test msgs(F(), [bad, open_[2]]) == [badmsg]                                                     # test_*_invalid_lower
        @test msgs(F(), [open_[2], "b"]) == [badmsg]                                                     # test_*_invalid_upper
        @test msgs(F(), ["", ""]) == ["This field is required."]                                         # test_*_required
    end
    @test clean(IntegerRangeField(), [1, ""]) == ValueRange(1, nothing)
    # test_*_has_changed_*: a form's range compared with its initial value
    changed(F, initial, data) = has_changed(Form([:f => F()]; data = Dict{String,Any}("f" => data), initial = Dict{Symbol,Any}(:f => initial)))
    @test changed(DateRangeField, ValueRange(Date(2010, 1, 1), Date(2020, 12, 12)), "2010-01-31, 2020-12-12")   # test_date_has_changed_first
    @test changed(DateRangeField, ValueRange(Date(2010, 1, 1), Date(2020, 12, 12)), "2010-01-01, 2020-12-31")   # test_date_has_changed_last
    @test !changed(DateRangeField, ValueRange(Date(2010, 1, 1), Date(2020, 12, 12)), "2010-01-01, 2020-12-12")
    @test !changed(IntegerRangeField, ValueRange(1, 2), "1, 2")                                       # test_has_changed
end
