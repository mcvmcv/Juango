# Django's postgres_tests test_constraints, ported (#227). ExclusionConstraint, deferrable and covering constraints and
# operator classes are PostgreSQL's: the tests that build them run there. The constructors' errors, repr and ==, the
# model checks and validating CheckConstraints over arrays and ranges run everywhere.
# julia --project=test test/django_postgres_constraints.jl   (see setup.jl)
#
# Not translated: the deconstruct() tests (Python's migration serializer; Juango's migration files hold a ConstraintSpec,
# whose code is tested below); test_validate_generated_field_range_adjacent (a generated field in a constraint is
# validated from its expression in Django; not yet in Juango, #232). "end" is a Julia keyword: HotelReservation's end is
# `stop`.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DcoScene
    scene = TextField()
    setting = CharField(max_length = 255)
    Meta(table = "dco_scene")
end
@model struct DcoRangesModel
    ints = IntegerRangeField(blank = true, null = true, db_default = ValueRange(5, 10))
    decimals = DecimalRangeField(blank = true, null = true)
    timestamps = DateTimeRangeField(blank = true, null = true)
    timestamps_inner = DateTimeRangeField(blank = true, null = true)
    dates = DateRangeField(blank = true, null = true)
    dates_inner = DateRangeField(blank = true, null = true)
    Meta(table = "dco_rangesmodel")
end
@model struct DcoIntegerArrayModel
    field = ArrayField(BigIntegerField(); default = Vector{Int}, blank = true)
    Meta(table = "dco_integerarraymodel")
end
@model struct DcoRoom
    number = IntegerField(unique = true)
    Meta(table = "dco_room")
end
@model struct DcoHotelReservation
    room = ForeignKey(DcoRoom; on_delete = :CASCADE)
    datespan = DateRangeField()
    start = DateTimeField()
    stop = DateTimeField()
    cancelled = BooleanField(default = false)
    requirements = JSONField(blank = true, null = true)
    Meta(table = "dco_hotelreservation")
end
@model struct DcoModelWithExclusionConstraint                                                     # (test_table_create)
    number = IntegerField()
    Meta(table = "dco_modelwithexclusionconstraint",
         constraints = [ExclusionConstraint(name = "exclusion_equal_number_tc", expressions = [("number", RangeOperators.EQUAL)])])
end
const DCO_MODELS = [DcoScene, DcoRangesModel, DcoIntegerArrayModel, DcoRoom, DcoHotelReservation, DcoModelWithExclusionConstraint]
const DCO_PG = Juango.backend() isa Juango.PostgresBackend
redirect_stdout(devnull) do
    DCO_PG && Juango.execute("CREATE EXTENSION IF NOT EXISTS btree_gist")
    Juango.sync_models!(DCO_MODELS); append!(PORT_MODELS, DCO_MODELS)
end

# ExclusionConstraintTests.test_check: a model whose constraint names a missing and joined fields (checked, never synced)
@model struct DcoAuthor
    name = CharField(max_length = 255)
    alias = CharField(max_length = 255)
    Meta(app_label = "dco_check")
end
@model struct DcoBook
    title = CharField(max_length = 255)
    published_date = DateField()
    author = ForeignKey(DcoAuthor; on_delete = :CASCADE)
    Meta(app_label = "dco_check", constraints = [ExclusionConstraint(name = "exclude_check", expressions = [
        (F(:title), RangeOperators.EQUAL), (F("published_date__year"), RangeOperators.EQUAL),
        ("published_date__month", RangeOperators.EQUAL), (F("author__name"), RangeOperators.EQUAL),
        ("author__alias", RangeOperators.EQUAL), ("nonexistent", RangeOperators.EQUAL)])])
end

dco_spec(T, c) = Juango.constraint_spec(T, c)
dco_add!(T, c) = (t = Juango.table_state(T); foreach(Juango.execute, Juango.add_constraint_sql(Juango.backend(), t, t, dco_spec(T, c))))
dco_remove!(T, c) = (t = Juango.table_state(T); foreach(Juango.execute, Juango.remove_constraint_sql(Juango.backend(), t, t, dco_spec(T, c))))
dco_constraints(T) = Juango.introspect_constraints(Juango.modelmeta(T).table)
const DCO_OPCLASS_QUERY = """SELECT opcname, c.relname FROM pg_opclass AS oc JOIN pg_index as i on oc.oid = ANY(i.indclass)
                             JOIN pg_class as c on c.oid = i.indexrelid WHERE c.relname = ?"""
dco_opclasses(name) = sort([(String(r[:opcname]), String(r[:relname])) for r in Juango.execute(DCO_OPCLASS_QUERY, [name])])
"A test whose schema changes and rows are rolled back (Django's TestCase transaction)."
dco_case(f) = atomic() do
    f()
    set_rollback!(true)
end
dco_violated(name) = "Constraint “$(name)” is violated."
dco_validate(c, T, obj; exclude = Symbol[]) = Juango.validate(c, T, obj; exclude = exclude)
"The ValidationError `validate` throws (or `nothing`)."
dco_error(c, T, obj; exclude = Symbol[]) = try dco_validate(c, T, obj; exclude = exclude); nothing catch e; e isa ValidationError ? e : rethrow() end
dco_msg(e) = e === nothing ? nothing : only(only(values(e.errors)))
dco_code(e) = e.code

port_block() do
    @testset "django postgres_tests test_constraints: SchemaTests (validation)" begin
        c = CheckConstraint(condition = Q(field__contains = [1]), name = "array_contains")             # test_check_constraint_array_contains
        @test dco_msg(dco_error(c, DcoIntegerArrayModel, DcoIntegerArrayModel())) == dco_violated("array_contains")
        @test dco_error(c, DcoIntegerArrayModel, DcoIntegerArrayModel(field = [1])) === nothing
        c = CheckConstraint(condition = Q(field__len = 1), name = "array_length")                      # test_check_constraint_array_length
        @test dco_msg(dco_error(c, DcoIntegerArrayModel, DcoIntegerArrayModel())) == dco_violated("array_length")
        @test dco_error(c, DcoIntegerArrayModel, DcoIntegerArrayModel(field = [1])) === nothing
        c = CheckConstraint(condition = Q(ints__contains = (1, 5)), name = "ints_contains")            # test_check_constraint_range_contains
        @test dco_msg(dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(6, 10)))) == dco_violated("ints_contains")
        c = CheckConstraint(condition = Q(ints__startswith__gte = 0) & Q(ints__endswith__lte = 99),  # test_check_constraint_range_lower_upper
                            name = "ints_range_lower_upper")
        @test dco_msg(dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(-1, 20)))) == dco_violated("ints_range_lower_upper")
        @test dco_msg(dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(0, 100)))) == dco_violated("ints_range_lower_upper")
        @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(0, 99))) === nothing
        c = CheckConstraint(condition = Q(ints__isnull = true) | Q(ints__startswith__gte = 0),         # test_check_constraint_range_lower_with_nulls
                            name = "ints_optional_positive_range")
        @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = nothing)) === nothing
        c = CheckConstraint(condition = Q(ints__startswith__gte = 0), name = "ints_positive_range")
        @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = nothing)) === nothing

        c = UniqueConstraint(OpClass(Lower(:scene), name = "text_pattern_ops"),                        # test_opclass_func_validate_constraints
                             name = "test_opclass_func_validate_constraints")
        create(DcoScene; scene = "First scene", setting = "")
        @test dco_msg(dco_error(c, DcoScene, DcoScene(scene = "first Scene"))) == dco_violated("test_opclass_func_validate_constraints")
        @test dco_error(c, DcoScene, DcoScene(scene = "second Scene")) === nothing
        delete!(filter(DcoScene))
    end

    DCO_PG && @testset "django postgres_tests test_constraints: SchemaTests" begin
        dco_case() do                                                                                 # test_check_constraint_range_value
            c = CheckConstraint(condition = Q(ints__contained_by = ValueRange(10, 30)), name = "ints_between")
            @test !haskey(dco_constraints(DcoRangesModel), "ints_between")
            dco_add!(DcoRangesModel, c)
            @test haskey(dco_constraints(DcoRangesModel), "ints_between")
            @test_throws IntegrityError atomic(() -> create(DcoRangesModel; ints = ValueRange(20, 50)))
            @test create(DcoRangesModel; ints = ValueRange(10, 30)).id !== nothing
        end
        dco_case() do                                                                                 # test_check_constraint_daterange_contains
            c = CheckConstraint(condition = Q(dates__contains = F(:dates_inner)), name = "dates_contains")
            dco_add!(DcoRangesModel, c)
            @test haskey(dco_constraints(DcoRangesModel), "dates_contains")
            d1, d2 = Date(2016, 1, 1), Date(2016, 1, 4)
            @test_throws IntegrityError atomic(() -> create(DcoRangesModel; dates = ValueRange(d1, d2), dates_inner = ValueRange(d1, Date(2016, 1, 5))))
            @test create(DcoRangesModel; dates = ValueRange(d1, d2), dates_inner = ValueRange(d1, d2)).id !== nothing
        end
        dco_case() do                                                                                 # test_check_constraint_datetimerange_contains
            c = CheckConstraint(condition = Q(timestamps__contains = F(:timestamps_inner)), name = "timestamps_contains")
            dco_add!(DcoRangesModel, c)
            @test haskey(dco_constraints(DcoRangesModel), "timestamps_contains")
            t1, t2 = DateTime(2016, 1, 1), DateTime(2016, 1, 2, 12)
            @test_throws IntegrityError atomic(() -> create(DcoRangesModel; timestamps = ValueRange(t1, t2),
                                                            timestamps_inner = ValueRange(t1, DateTime(2016, 1, 2, 13))))
            @test create(DcoRangesModel; timestamps = ValueRange(t1, t2), timestamps_inner = ValueRange(t1, t2)).id !== nothing
        end
        dco_case() do                                                                                 # test_opclass
            c = UniqueConstraint(name = "test_opclass", fields = [:scene], opclasses = ["varchar_pattern_ops"])
            dco_add!(DcoScene, c)
            @test haskey(dco_constraints(DcoScene), "test_opclass")
            @test dco_opclasses("test_opclass") == [("varchar_pattern_ops", "test_opclass")]
            dco_remove!(DcoScene, c)
            @test !haskey(dco_constraints(DcoScene), "test_opclass")
        end
        dco_case() do                                                                                 # test_opclass_multiple_columns
            c = UniqueConstraint(name = "test_opclass_multiple", fields = [:scene, :setting], opclasses = ["varchar_pattern_ops", "text_pattern_ops"])
            dco_add!(DcoScene, c)
            @test dco_opclasses("test_opclass_multiple") == sort([("varchar_pattern_ops", "test_opclass_multiple"), ("text_pattern_ops", "test_opclass_multiple")])
        end
        dco_case() do                                                                                 # test_opclass_partial
            c = UniqueConstraint(name = "test_opclass_partial", fields = [:scene], opclasses = ["varchar_pattern_ops"],
                                 condition = Q(setting__contains = "Sir Bedemir's Castle"))
            dco_add!(DcoScene, c)
            @test dco_opclasses("test_opclass_partial") == [("varchar_pattern_ops", "test_opclass_partial")]
        end
        dco_case() do                                                                                 # test_opclass_include
            c = UniqueConstraint(name = "test_opclass_include", fields = [:scene], opclasses = ["varchar_pattern_ops"], include = [:setting])
            dco_add!(DcoScene, c)
            @test dco_opclasses("test_opclass_include") == [("varchar_pattern_ops", "test_opclass_include")]
        end
        dco_case() do                                                                                 # test_opclass_func
            c = UniqueConstraint(OpClass(Lower(:scene), name = "text_pattern_ops"), name = "test_opclass_func")
            dco_add!(DcoScene, c)
            cs = dco_constraints(DcoScene)
            @test haskey(cs, "test_opclass_func") && cs["test_opclass_func"].unique
            @test dco_opclasses("test_opclass_func") == [("text_pattern_ops", "test_opclass_func")]
            create(DcoScene; scene = "Scene 10", setting = "The dark forest of Ewing")
            @test_throws IntegrityError atomic(() -> create(DcoScene; scene = "ScEnE 10", setting = "Sir Bedemir's Castle"))
            create(DcoScene; scene = "Scene 5", setting = "Sir Bedemir's Castle")
            dco_remove!(DcoScene, c)
            @test !haskey(dco_constraints(DcoScene), "test_opclass_func")
            @test create(DcoScene; scene = "ScEnE 10", setting = "Sir Bedemir's Castle").id !== nothing
        end
    end

    @testset "django postgres_tests test_constraints: ExclusionConstraintTests (arguments)" begin
        ov = RangeOperators.OVERLAPS
        @test_throws "ExclusionConstraint.condition must be a Q instance." ExclusionConstraint(          # test_invalid_condition
            index_type = "GIST", name = "exclude_invalid_condition", expressions = [(F(:datespan), ov)], condition = F(:invalid))
        @test_throws "Exclusion constraints only support GiST, Hash, or SP-GiST indexes." ExclusionConstraint(  # test_invalid_index_type
            index_type = "gin", name = "exclude_invalid_index_type", expressions = [(F(:datespan), ov)])
        for exprs in (["foo"], [("foo",)], [("foo_1", "foo_2", "foo_3")])                              # test_invalid_expressions
            @test_throws "The expressions must be a list of 2-tuples." ExclusionConstraint(index_type = "GIST", name = "x", expressions = exprs)
        end
        for exprs in (nothing, [])                                                                       # test_empty_expressions
            @test_throws "At least one expression is required to define an exclusion constraint." ExclusionConstraint(
                index_type = "GIST", name = "exclude_empty_expressions", expressions = exprs)
        end
        @test_throws "ExclusionConstraint.deferrable must be a Deferrable instance." ExclusionConstraint(  # test_invalid_deferrable
            name = "exclude_invalid_deferrable", expressions = [(F(:datespan), ov)], deferrable = "invalid")
        @test_throws "ExclusionConstraint.include must be a list or tuple." ExclusionConstraint(           # test_invalid_include_type
            name = "exclude_invalid_include", expressions = [(F(:datespan), ov)], include = "invalid")
        @test_throws "Covering exclusion constraints using Hash indexes are not supported." ExclusionConstraint(  # test_covering_hash_index_not_supported
            name = "covering_hash_index_not_supported", expressions = [("int1", RangeOperators.EQUAL)], index_type = "hash", include = ["int2"])
        @test_throws "Composite exclusion constraints using Hash indexes are not supported." ExclusionConstraint(  # test_composite_hash_index_not_supported
            name = "composite_hash_index_not_supported", expressions = [("int1", RangeOperators.EQUAL), ("int2", RangeOperators.EQUAL)],
            index_type = "hash")
        @test_throws "Exclusion constraints using Hash indexes only support the EQUAL operator." ExclusionConstraint(  # test_non_equal_hash_index_not_supported
            name = "none_equal_hash_index_not_supported", expressions = [("int1", RangeOperators.NOT_EQUAL)], index_type = "hash")
    end

    @testset "django postgres_tests test_constraints: ExclusionConstraintTests.test_check" begin
        msgs = sort([(m.id, m.msg) for m in Juango.model_check_issues(DcoBook)])
        label = Juango.model_check_label(DcoBook)
        @test msgs == sort([("models.E012", "$label: 'constraints' refers to the nonexistent field 'nonexistent'."),
                            ("models.E041", "$label: 'constraints' refers to the joined field 'author__alias'."),
                            ("models.E041", "$label: 'constraints' refers to the joined field 'author__name'.")])
    end

    @testset "django postgres_tests test_constraints: ExclusionConstraintTests.test_repr" begin
        adj, ov, eq = RangeOperators.ADJACENT_TO, RangeOperators.OVERLAPS, RangeOperators.EQUAL
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), ov), (F(:room), eq)])) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(F(datespan), '&&'), (F(room), '=')] name='exclude_overlapping'>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), adj)], condition = Q(cancelled = false),
                                       index_type = "SPGiST")) ==
              "<ExclusionConstraint: index_type='SPGiST' expressions=[(F(datespan), '-|-')] name='exclude_overlapping' condition=(AND: ('cancelled', False))>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), adj)], deferrable = Deferrable.IMMEDIATE)) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(F(datespan), '-|-')] name='exclude_overlapping' deferrable=Deferrable.IMMEDIATE>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), adj)], include = ["cancelled", "room"])) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(F(datespan), '-|-')] name='exclude_overlapping' include=('cancelled', 'room')>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(OpClass("datespan", name = "range_ops"), adj)])) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(OpClass(F(datespan), name=range_ops), '-|-')] name='exclude_overlapping'>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), adj)],
                                       violation_error_message = "Overlapping must be excluded")) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(F(datespan), '-|-')] name='exclude_overlapping' violation_error_message='Overlapping must be excluded'>"
        @test repr(ExclusionConstraint(name = "exclude_overlapping", expressions = [(F(:datespan), adj)],
                                       violation_error_code = "overlapping_must_be_excluded")) ==
              "<ExclusionConstraint: index_type='GIST' expressions=[(F(datespan), '-|-')] name='exclude_overlapping' violation_error_code='overlapping_must_be_excluded'>"
        @test repr(ExclusionConstraint(name = "exclude_equal_hash", index_type = "hash", expressions = [(F(:room), eq)],
                                       violation_error_code = "room_must_be_unique")) ==
              "<ExclusionConstraint: index_type='hash' expressions=[(F(room), '=')] name='exclude_equal_hash' violation_error_code='room_must_be_unique'>"
    end

    @testset "django postgres_tests test_constraints: ExclusionConstraintTests.test_eq" begin
        ov, eq = RangeOperators.OVERLAPS, RangeOperators.EQUAL
        X(; kw...) = ExclusionConstraint(; name = "exclude_overlapping", kw...)
        c1 = X(expressions = [(F(:datespan), ov), (F(:room), eq)], condition = Q(cancelled = false))
        c2 = X(expressions = [("datespan", ov), ("room", eq)])
        c3 = X(expressions = [("datespan", ov)], condition = Q(cancelled = false))
        c4 = X(expressions = [("datespan", ov), ("room", eq)], deferrable = Deferrable.DEFERRED)
        c5 = X(expressions = [("datespan", ov), ("room", eq)], deferrable = Deferrable.IMMEDIATE)
        c6 = X(expressions = [("datespan", ov), ("room", eq)], deferrable = Deferrable.IMMEDIATE, include = ["cancelled"])
        c7 = X(expressions = [("datespan", ov), ("room", eq)], include = ["cancelled"])
        c8 = X(index_type = "gist", expressions = [("datespan", ov), ("room", eq)], include = ["cancelled"])
        c9 = X(index_type = "GIST", expressions = [("datespan", ov), ("room", eq)], include = ["cancelled"])
        c10 = X(expressions = [(F(:datespan), ov), (F(:room), eq)], condition = Q(cancelled = false), violation_error_message = "custom error")
        c11 = X(expressions = [(F(:datespan), ov), (F(:room), eq)], condition = Q(cancelled = false), violation_error_message = "other custom error")
        c12 = X(expressions = [(F(:datespan), ov), (F(:room), eq)], condition = Q(cancelled = false), violation_error_code = "custom_code",
                violation_error_message = "other custom error")
        c13 = ExclusionConstraint(name = "exclude_equal_hash", index_type = "hash", expressions = [(F(:room), eq)], violation_error_code = "room_must_be_unique")
        @test c1 == c1
        @test c1 != c2 && c1 != c3 && c1 != c4 && c1 != c10
        @test c2 != c3 && c2 != c4 && c2 != c7
        @test c7 == c8 && c7 == c9
        @test c4 != c5 && c5 != c6
        @test c1 != "object()"
        @test c10 != c11 && c11 != c12 && c12 != c13
        @test c10 == c10 && c12 == c12 && c13 == c13
        # (Django's deconstruct: a migration file's ConstraintSpec)
        @test Juango.constraint_code(dco_spec(DcoHotelReservation, X(expressions = [("datespan", ov), ("room", eq)], include = ["cancelled", "room"],
                                                                   deferrable = Deferrable.DEFERRED, condition = Q(cancelled = false)))) ==
              "ConstraintSpec(:exclusion, \"exclude_overlapping\"; expressions = [(\"datespan\", \"&&\"), (\"room_id\", \"=\")], " *
              "condition = Q(:AND, Any[:cancelled => false], false), index_type = \"gist\", include = [\"cancelled\", \"room_id\"], deferrable = \"deferred\")"
        @test Juango.constraint_code(dco_spec(DcoRangesModel, X(expressions = [(OpClass(Left(:dates, 4), "range_ops"), eq)]))) ==
              "ConstraintSpec(:exclusion, \"exclude_overlapping\"; expressions = [(Func(:left, Any[F(\"dates\"), Value(4)]), \"=\")], " *
              "index_type = \"gist\", opclasses = [\"range_ops\"])"
    end

    DCO_PG && @testset "django postgres_tests test_constraints: ExclusionConstraintTests" begin
        datetimes = [DateTime(2018, 6, 20), DateTime(2018, 6, 24), DateTime(2018, 6, 26), DateTime(2018, 6, 28), DateTime(2018, 6, 29)]
        dspan(i, j) = ValueRange(Date(datetimes[i]), Date(datetimes[j]))
        function range_overlaps(c)                                                                      # _test_range_overlaps
            @test !haskey(dco_constraints(DcoHotelReservation), c.name)
            dco_add!(DcoHotelReservation, c)
            @test haskey(dco_constraints(DcoHotelReservation), c.name)
            room101 = create(DcoRoom; number = 101); room102 = create(DcoRoom; number = 102)
            r = create(DcoHotelReservation; datespan = dspan(1, 2), start = datetimes[1], stop = datetimes[2], room = room102)
            @test dco_error(c, DcoHotelReservation, r) === nothing
            create(DcoHotelReservation; datespan = dspan(2, 4), start = datetimes[2], stop = datetimes[4], room = room102)
            create(DcoHotelReservation; datespan = dspan(4, 5), start = datetimes[4], stop = datetimes[5], room = room102, cancelled = true)
            # overlapping dates
            r = DcoHotelReservation(datespan = dspan(2, 3), start = datetimes[2], stop = datetimes[3], room = room102)
            @test dco_msg(dco_error(c, DcoHotelReservation, r)) == dco_violated(c.name)
            @test_throws IntegrityError atomic(() -> save!(r))
            others = [DcoHotelReservation(datespan = dspan(2, 3), start = datetimes[2], stop = datetimes[3], room = room101),  # other room
                      DcoHotelReservation(datespan = dspan(2, 2), start = datetimes[2], stop = datetimes[3], room = room102, cancelled = true),
                      DcoHotelReservation(datespan = dspan(4, 5), start = datetimes[4], stop = datetimes[5], room = room102)]  # adjacent
            @test all(o -> dco_error(c, DcoHotelReservation, o) === nothing, others)
            bulk_create(others)
            r = DcoHotelReservation(datespan = dspan(2, 3), start = datetimes[2], stop = datetimes[3], room = room102)
            @test dco_error(c, DcoHotelReservation, r; exclude = [:room]) === nothing                     # excluded fields
            @test dco_error(c, DcoHotelReservation, r; exclude = [:datespan, :start, :stop, :room]) === nothing
            @test dco_error(c, DcoHotelReservation, r; exclude = [:cancelled]) === nothing                # (in the condition)
        end
        # (TSTZRANGE of timestamps with time zones; Juango's DateTimeFields are TIMESTAMP without USE_TZ: TSRANGE there)
        dco_case() do                                                                                 # test_range_overlaps_custom
            range_overlaps(ExclusionConstraint(name = "exclude_overlapping_reservations_custom_opclass",
                expressions = [(OpClass(SQLFunction(Juango.settings.USE_TZ ? "TSTZRANGE" : "TSRANGE", :start, :stop, RangeBoundary()), "range_ops"), RangeOperators.OVERLAPS),
                               (OpClass(:room, "gist_int8_ops"), RangeOperators.EQUAL)],
                condition = Q(cancelled = false)))
        end
        dco_case() do                                                                                 # test_range_overlaps
            range_overlaps(ExclusionConstraint(name = "exclude_overlapping_reservations",
                expressions = [(F(:datespan), RangeOperators.OVERLAPS), ("room", RangeOperators.EQUAL)], condition = Q(cancelled = false)))
        end
        dco_case() do                                                                                 # test_range_adjacent
            c = ExclusionConstraint(name = "ints_adjacent", expressions = [("ints", RangeOperators.ADJACENT_TO)])
            @test !haskey(dco_constraints(DcoRangesModel), "ints_adjacent")
            dco_add!(DcoRangesModel, c)
            @test haskey(dco_constraints(DcoRangesModel), "ints_adjacent")
            create(DcoRangesModel; ints = ValueRange(20, 50))
            @test_throws IntegrityError atomic(() -> create(DcoRangesModel; ints = ValueRange(10, 20)))
            create(DcoRangesModel; ints = ValueRange(10, 19)); create(DcoRangesModel; ints = ValueRange(51, 60))
            dco_remove!(DcoRangesModel, c)
            @test !haskey(dco_constraints(DcoRangesModel), "ints_adjacent")
        end
        dco_case() do                                                                                 # test_validate_range_adjacent
            c = ExclusionConstraint(name = "ints_adjacent", expressions = [("ints", RangeOperators.ADJACENT_TO)],
                                    violation_error_code = "custom_code", violation_error_message = "Custom error message.")
            r = create(DcoRangesModel; ints = ValueRange(20, 50))
            @test dco_error(c, DcoRangesModel, r) === nothing
            e = dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(10, 20)))
            @test dco_msg(e) == "Custom error message." && dco_code(e) == "custom_code"
            @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(10, 19))) === nothing
            @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(51, 60))) === nothing
            @test dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(10, 20)); exclude = [:ints]) === nothing
        end
        dco_case() do                                                                                 # test_validate_with_custom_code_and_condition
            c = ExclusionConstraint(name = "ints_adjacent", expressions = [("ints", RangeOperators.ADJACENT_TO)],
                                    violation_error_code = "custom_code", condition = Q(ints__lt = (100, 200)))
            r = create(DcoRangesModel; ints = ValueRange(20, 50))
            @test dco_error(c, DcoRangesModel, r) === nothing
            @test dco_code(dco_error(c, DcoRangesModel, DcoRangesModel(ints = ValueRange(10, 20)))) == "custom_code"
        end
        dco_case() do                                                                                 # test_expressions_with_params
            c = ExclusionConstraint(name = "scene_left_equal", expressions = [(Left(:scene, 4), RangeOperators.EQUAL)])
            @test !haskey(dco_constraints(DcoScene), "scene_left_equal")
            dco_add!(DcoScene, c)
            @test haskey(dco_constraints(DcoScene), "scene_left_equal")
        end
        dco_case() do                                                                                 # test_expressions_with_key_transform
            c = ExclusionConstraint(name = "exclude_overlapping_reservations_smoking",
                                    expressions = [(F(:datespan), RangeOperators.OVERLAPS), (KeyTextTransform("smoking", "requirements"), RangeOperators.EQUAL)])
            dco_add!(DcoHotelReservation, c)
            @test haskey(dco_constraints(DcoHotelReservation), "exclude_overlapping_reservations_smoking")
        end
        dco_case() do                                                                                 # test_index_transform
            c = ExclusionConstraint(name = "first_index_equal", expressions = [("field__0", RangeOperators.EQUAL)])
            dco_add!(DcoIntegerArrayModel, c)
            @test haskey(dco_constraints(DcoIntegerArrayModel), "first_index_equal")
        end
        for cond in (nothing, Q(ints__lt = (100, 200)))                                               # test_range_adjacent_initially_deferred(_with_condition)
            dco_case() do
                name = cond === nothing ? "ints_adjacent_deferred" : "ints_adjacent_deferred_with_condition"
                c = ExclusionConstraint(name = name, expressions = [("ints", RangeOperators.ADJACENT_TO)], condition = cond,
                                        deferrable = Deferrable.DEFERRED)
                dco_add!(DcoRangesModel, c)
                @test haskey(dco_constraints(DcoRangesModel), name)
                create(DcoRangesModel; ints = ValueRange(20, 50))
                adjacent = create(DcoRangesModel; ints = ValueRange(10, 20))
                @test_throws IntegrityError atomic(() -> Juango.execute("SET CONSTRAINTS \"$name\" IMMEDIATE"))
                delete!(adjacent)
                create(DcoRangesModel; ints = ValueRange(10, 19)); create(DcoRangesModel; ints = ValueRange(51, 60))
                if cond !== nothing                                                                    # (a range the condition leaves out)
                    create(DcoRangesModel; ints = ValueRange(200, 500)); create(DcoRangesModel; ints = ValueRange(100, 200))
                    @test atomic(() -> (Juango.execute("SET CONSTRAINTS \"$name\" IMMEDIATE"); true))
                end
            end
        end
        for it in ("gist", "spgist")                                                                  # test_range_adjacent_gist/spgist_include
            dco_case() do
                name = "ints_adjacent_$(it)_include"
                c = ExclusionConstraint(name = name, expressions = [("ints", RangeOperators.ADJACENT_TO)], index_type = it, include = ["decimals", "ints"])
                dco_add!(DcoRangesModel, c)
                @test haskey(dco_constraints(DcoRangesModel), name)
                create(DcoRangesModel; ints = ValueRange(20, 50))
                @test_throws IntegrityError atomic(() -> create(DcoRangesModel; ints = ValueRange(10, 20)))
                create(DcoRangesModel; ints = ValueRange(10, 19)); create(DcoRangesModel; ints = ValueRange(51, 60))
            end
            for (suffix, kw) in (("include_condition", (include = ["decimals"], condition = Q(id__gte = 100))),   # ..._include_condition, _include_deferrable
                                 ("include_deferrable", (include = ["decimals"], deferrable = Deferrable.DEFERRED)),
                                 ("opclass_include", (include = ["decimals"],)))                             # test_range_adjacent_gist/spgist_opclass_include
                dco_case() do
                    name = "ints_adjacent_$(it)_$suffix"
                    e = suffix == "opclass_include" ? OpClass("ints", name = "range_ops") : "ints"
                    c = ExclusionConstraint(; name = name, expressions = [(e, RangeOperators.ADJACENT_TO)], index_type = it, kw...)
                    dco_add!(DcoRangesModel, c)
                    @test haskey(dco_constraints(DcoRangesModel), name)
                end
            end
        end
        dco_case() do                                                                                 # test_range_adjacent_opclass
            c = ExclusionConstraint(name = "ints_adjacent_opclass", expressions = [(OpClass("ints", name = "range_ops"), RangeOperators.ADJACENT_TO)])
            dco_add!(DcoRangesModel, c)
            @test haskey(dco_constraints(DcoRangesModel), "ints_adjacent_opclass")
            @test dco_opclasses("ints_adjacent_opclass") == [("range_ops", "ints_adjacent_opclass")]
            create(DcoRangesModel; ints = ValueRange(20, 50))
            @test_throws IntegrityError atomic(() -> create(DcoRangesModel; ints = ValueRange(10, 20)))
            create(DcoRangesModel; ints = ValueRange(10, 19)); create(DcoRangesModel; ints = ValueRange(51, 60))
            dco_remove!(DcoRangesModel, c)
            @test !haskey(dco_constraints(DcoRangesModel), "ints_adjacent_opclass")
        end
        for (suffix, kw) in (("condition", (condition = Q(id__gte = 100),)), ("deferrable", (deferrable = Deferrable.DEFERRED,)))
            dco_case() do                                                                             # test_range_adjacent_opclass_condition/_deferrable
                name = "ints_adjacent_opclass_$suffix"
                c = ExclusionConstraint(; name = name, expressions = [(OpClass("ints", name = "range_ops"), RangeOperators.ADJACENT_TO)], kw...)
                dco_add!(DcoRangesModel, c)
                @test haskey(dco_constraints(DcoRangesModel), name)
            end
        end
        dco_case() do                                                                                 # test_range_equal_cast
            c = ExclusionConstraint(name = "exclusion_equal_room_cast", expressions = [(Cast(:number, IntegerField()), RangeOperators.EQUAL)])
            dco_add!(DcoRoom, c)
            @test haskey(dco_constraints(DcoRoom), "exclusion_equal_room_cast")
        end
        dco_case() do                                                                                 # test_hash_uniqueness
            c = ExclusionConstraint(name = "exclusion_equal_room_hash", index_type = "hash", expressions = [(F(:number), RangeOperators.EQUAL)])
            dco_add!(DcoRoom, c)
            @test haskey(dco_constraints(DcoRoom), "exclusion_equal_room_hash")
            create(DcoRoom; number = 101)
            @test_throws IntegrityError atomic(() -> create(DcoRoom; number = 101))
            create(DcoRoom; number = 102)
            dco_remove!(DcoRoom, c)
            @test !haskey(dco_constraints(DcoRoom), "exclusion_equal_room_hash")
        end
        @test haskey(dco_constraints(DcoModelWithExclusionConstraint), "exclusion_equal_number_tc")    # test_table_create
        dco_case() do                                                                                 # test_database_default
            c = ExclusionConstraint(name = "ints_equal", expressions = [("ints", RangeOperators.EQUAL)])
            r0 = create(DcoRangesModel)
            @test refresh!(r0).ints == ValueRange(5, 10)
            @test dco_msg(dco_error(c, DcoRangesModel, DcoRangesModel())) == dco_violated("ints_equal")
        end
    end
end
foreach(Juango.unregister_model!, (DcoBook, DcoAuthor))
