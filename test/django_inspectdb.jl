# Django's inspectdb tests, ported (#227): the @model code inspectdb writes for Django's test tables.
# julia --project=test test/django_inspectdb.jl   (see setup.jl)
#
# Juango's types for SQLite's TEXT and INTEGER columns are TextField and IntegerField. Not translated: the
# column-type, collation and comment tests (Juango's field_for is tested in db.jl and django_introspection.jl),
# test_custom_normalize_table_name (a Command subclass), the materialized-view and partition tests, the
# db_on_delete one (#228), test_custom_fields and the introspection-error tests (mocks).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DinsPeople
    name = CharField(max_length = 255)
    parent = ForeignKey(:self; on_delete = :CASCADE)
    Meta(table = "inspectdb_people")
end
@model struct DinsMessage
    from_field = ForeignKey(DinsPeople; on_delete = :CASCADE, db_column = "from_id")
    Meta(table = "inspectdb_message")
end
@model struct DinsPeopleData
    people_pk = ForeignKey(DinsPeople; on_delete = :CASCADE, primary_key = true)
    ssn = CharField(max_length = 11)
    Meta(table = "inspectdb_peopledata")
end
@model struct DinsPeopleMoreData
    people_unique = ForeignKey(DinsPeople; on_delete = :CASCADE, unique = true)
    message = ForeignKey(DinsMessage; on_delete = :CASCADE, blank = true, null = true)
    license = CharField(max_length = 255)
    Meta(table = "inspectdb_peoplemoredata")
end
@model struct DinsForeignKeyToField
    to_field_fk = ForeignKey(DinsPeopleMoreData; on_delete = :CASCADE, to_field = :people_unique)
    Meta(table = "inspectdb_foreignkeytofield")
end
@model struct DinsDigitsInColumnName
    all_digits = CharField(max_length = 11, db_column = "123")
    leading_digit = CharField(max_length = 11, db_column = "4extra")
    leading_digits = CharField(max_length = 11, db_column = "45extra")
    Meta(table = "inspectdb_digitsincolumnname")
end
@model struct DinsSpecialName
    field = IntegerField(db_column = "field")
    field_field = IntegerField(db_column = "Field_")              # (underscores at the end)
    field_field_0 = IntegerField(db_column = "Field__")
    field_field_1 = IntegerField(db_column = "__field")           # (at the start)
    prc_x = IntegerField(db_column = "prc(%) x")                  # (other characters)
    tamaño = IntegerField()
    Meta(table = "inspectdb_special.table name")
end
@model struct DinsUniqueTogether
    field1 = IntegerField()
    field2 = CharField(max_length = 10)
    from_field = IntegerField(db_column = "from")
    non_unique = IntegerField(db_column = "non__unique_column")
    non_unique_0 = IntegerField(db_column = "non_unique__column")
    Meta(table = "inspectdb_uniquetogether", unique_together = [(:field1, :field2), (:from_field, :field1), (:non_unique, :non_unique_0)])
end
@model struct DinsKeywords
    end_field = IntegerField(db_column = "end")
    Meta(table = "inspectdb_keywords")
end
redirect_stdout(devnull) do
    ms = Any[DinsKeywords, DinsPeople, DinsMessage, DinsPeopleData, DinsPeopleMoreData, DinsForeignKeyToField, DinsDigitsInColumnName,
             DinsSpecialName, DinsUniqueTogether]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
dins_only(t) = startswith(t, "inspectdb_")

@testset "django inspectdb: InspectDBTestCase" begin
    # test_stealth_table_name_filter_option
    out = inspectdb(; table_name_filter = dins_only)
    @test !occursin("@model struct DjangoContentType", out) && !occursin("JuangoContenttype", out) && occursin("InspectdbPeople", out)
    # test_table_option
    out = inspectdb(["inspectdb_people"])
    @test occursin("@model struct InspectdbPeople\n", out) && !occursin("InspectdbPeopledata", out)
    # test_managed_models
    @test occursin("managed = false", out)
    # test_attribute_name_not_python_keyword: a key to its own table is :self; one whose column isn't <name>_id keeps it
    out = inspectdb(; table_name_filter = dins_only)
    @test occursin("parent = ForeignKey(:self; on_delete = :DO_NOTHING)", out)
    @test occursin("    from = ForeignKey(:InspectdbPeople; on_delete = :DO_NOTHING)", out)      # (Django's from_field: from is a Python keyword)
    @test occursin("people_pk = OneToOneField(:InspectdbPeople; on_delete = :DO_NOTHING, primary_key = true)", out)
    @test occursin("people_unique = OneToOneField(:InspectdbPeople; on_delete = :DO_NOTHING)", out)
    @test occursin("message = ForeignKey(:InspectdbMessage; on_delete = :DO_NOTHING, blank = true, null = true)", out)
    # test_foreign_key_to_field
    @test occursin("to_field_fk = ForeignKey(:InspectdbPeoplemoredata; on_delete = :DO_NOTHING, to_field = :people_unique_id)",
                   inspectdb(["inspectdb_foreignkeytofield"]))
    # test_digits_column_name_introspection
    out = inspectdb(["inspectdb_digitsincolumnname"])
    for n in ("123", "4extra", "45extra")
        @test occursin("    number_$n = ", out) && !occursin("    $n = ", out)
    end
    # test_special_column_name_introspection / test_table_name_introspection
    out = inspectdb(; table_name_filter = t -> occursin("special", t))
    @test occursin("    field = IntegerField()", out)
    @test occursin("    field_field = IntegerField(db_column = \"Field_\")", out)
    @test occursin("    field_field_0 = IntegerField(db_column = \"Field__\")", out)
    @test occursin("    field_field_1 = IntegerField(db_column = \"__field\")", out)
    @test occursin("    prc_x = IntegerField(db_column = \"prc(%) x\")", out)
    @test occursin("    tamaño = IntegerField()", out)
    @test occursin("@model struct InspectdbSpecialTableName", out)
    # test_unique_together_meta: names that normalize to the same one are numbered
    out = inspectdb(["inspectdb_uniquetogether"])
    m = match(r"unique_together = \[(.*?)\]\)", out)
    @test m !== nothing
    @test occursin("(:field1, :field2)", m[1]) && occursin("(:from, :field1)", m[1]) && occursin("(:non_unique_column, :non_unique_column_0)", m[1])
    @test occursin("    from = IntegerField()", out)        # (from isn't a Julia keyword: Django's from_field)
    @test occursin("    end_field = IntegerField(db_column = \"end\")", inspectdb(["inspectdb_keywords"]))   # (end is)
end

@testset "django inspectdb: InspectDBTransactionalTests" begin
    # test_include_views
    execute("CREATE VIEW inspectdb_people_view AS SELECT id, name FROM inspectdb_people")
    try
        @test !occursin("InspectdbPeopleView", inspectdb(; table_name_filter = dins_only))
        @test occursin("@model struct InspectdbPeopleView", inspectdb(; table_name_filter = dins_only, include_views = true))
    finally
        execute("DROP VIEW inspectdb_people_view")
    end
end

# Django's postgres_tests test_introspection (InspectDBTests): range and hstore columns read back as their fields
Juango.backend() isa Juango.PostgresBackend && @testset "django postgres_tests test_introspection: InspectDBTests" begin
    execute("CREATE EXTENSION IF NOT EXISTS hstore")
    execute("CREATE TABLE inspectdb_rangesmodel (id serial PRIMARY KEY, ints int4range, bigints int8range, decimals numrange, " *
            "timestamps tstzrange, timestamps_inner tsrange, dates daterange)")
    execute("CREATE TABLE inspectdb_hstoremodel (id serial PRIMARY KEY, field hstore)")
    try
        out = inspectdb(["inspectdb_rangesmodel"])                                   # test_range_fields
        for line in ["ints = IntegerRangeField(blank = true, null = true)", "bigints = BigIntegerRangeField(blank = true, null = true)",
                     "decimals = DecimalRangeField(blank = true, null = true)", "timestamps = DateTimeRangeField(blank = true, null = true)",
                     "timestamps_inner = DateTimeRangeField(blank = true, null = true)", "dates = DateRangeField(blank = true, null = true)"]
            @test occursin(line, out)
        end
        @test occursin("field = HStoreField(blank = true, null = true)", inspectdb(["inspectdb_hstoremodel"]))  # test_hstore_field
    finally
        execute("DROP TABLE inspectdb_rangesmodel")
        execute("DROP TABLE inspectdb_hstoremodel")
    end
end
