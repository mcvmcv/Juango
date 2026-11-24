# Django's introspection tests, ported (#227).
# julia --project=test test/django_introspection.jl   (see setup.jl)
#
# Juango's introspection functions: introspect_tables, introspect_columns (Django's get_table_description),
# introspect_constraints, introspect_relations, introspect_primary_key_column, introspect_comments,
# django_table_names, installed_models; get_field_type is the type inspectdb gives a column (field_for).
#
# Not translated: test_sequence_list (Juango resets sequences itself and lists none), the db_on_delete cases
# (#228), test_get_relations' remove_field part, and the "orders" of indexes (introspect_constraints has none).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DinCity
    name = CharField(max_length = 50)
    Meta(table = "din_city", pk = BigAutoField())
end
@model struct DinCountry
    name = CharField(max_length = 50)
    Meta(table = "din_country", pk = SmallAutoField())
end
@model struct DinDistrict
    city = ForeignKey(DinCity; on_delete = :CASCADE, primary_key = true)
    name = CharField(max_length = 50)
    Meta(table = "din_district")
end
@model struct DinReporter
    first_name = CharField(max_length = 30)
    last_name = CharField(max_length = 30)
    email = EmailField()
    facebook_user_id = BigIntegerField(null = true)
    raw_data = BinaryField(null = true)
    small_int = SmallIntegerField()
    interval = DurationField()
    Meta(table = "din_reporter", unique_together = [(:first_name, :last_name)])
end
@model struct DinArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    body = TextField(default = "")
    reporter = ForeignKey(DinReporter; on_delete = :CASCADE)
    response_to = ForeignKey("DinArticle"; on_delete = :SET_NULL, null = true)
    Meta(table = "din_article", ordering = [:headline],
         indexes = [Index(fields = ["headline", "pub_date"]), Index(fields = ["headline", "response_to", "pub_date", "reporter"])])
end
@model struct DinArticleReporter
    article = ForeignKey(DinArticle; on_delete = :CASCADE)
    reporter = ForeignKey(DinReporter; on_delete = :CASCADE)
    Meta(table = "din_articlereporter", managed = false)
end
@model struct DinComment
    ref = UUIDField(unique = true)
    article = ForeignKey(DinArticle; on_delete = :CASCADE, db_index = true)
    email = EmailField()
    pub_date = DateTimeField()
    body = TextField()
    Meta(table = "din_comment",
         constraints = [UniqueConstraint(fields = ["article", "email", "pub_date"], name = "article_email_pub_date_uniq")],
         indexes = [Index(fields = ["email", "pub_date"], name = "email_pub_date_idx")])
end
@model struct DinCheckConstraintModel
    up_votes = PositiveIntegerField()
    voting_number = PositiveIntegerField(unique = true)
    Meta(table = "din_checkconstraintmodel", constraints = [CheckConstraint(name = "up_votes_gte_0_check", condition = Q(up_votes__gte = 0))])
end
@model struct DinUniqueConstraintConditionModel
    name = CharField(max_length = 255)
    color = CharField(max_length = 32, null = true)
    Meta(table = "din_uniqueconstraintconditionmodel",
         constraints = [UniqueConstraint(fields = ["name"], name = "cond_name_without_color_uniq", condition = Q(color__isnull = true))])
end
@model struct DinDbCommentModel
    name = CharField(max_length = 15, db_comment = "'Name' column comment")
    Meta(table = "din_dbcommentmodel", db_table_comment = "Custom table comment")
end

const DIN_MODELS = Any[DinCity, DinCountry, DinDistrict, DinReporter, DinArticle, DinComment, DinCheckConstraintModel,
                       DinUniqueConstraintConditionModel, DinDbCommentModel]
redirect_stdout(devnull) do
    Juango.sync_models!(DIN_MODELS); append!(PORT_MODELS, DIN_MODELS)
end
din_type(c) = first(split(first(Juango.field_for(c)), '('))
din_desc(T) = Juango.introspect_columns(Juango.modelmeta(T).table)

@testset "django introspection: IntrospectionTests" begin
    # test_table_names
    tl = introspect_tables()
    @test tl == sort(tl) && "din_reporter" in tl && "din_article" in tl
    # test_django_table_names: not a table no model has
    execute("CREATE TABLE django_ixn_test_table (id INTEGER)")
    try
        @test !("django_ixn_test_table" in django_table_names())
    finally
        execute("DROP TABLE django_ixn_test_table")
    end
    # test_django_table_names_retval_type
    @test django_table_names(only_existing = true) isa Vector && django_table_names(only_existing = false) isa Vector
    @test "din_article" in django_table_names(only_existing = true)
    # test_table_names_with_views
    execute("CREATE VIEW din_article_view AS SELECT headline FROM din_article")
    try
        @test "din_article_view" in introspect_tables(include_views = true)
        @test !("din_article_view" in introspect_tables())
    finally
        execute("DROP VIEW din_article_view")
    end
    # test_unmanaged_through_model
    @test !("din_articlereporter" in django_table_names())
    # test_installed_models
    @test installed_models(["din_article", "din_reporter"]) == Set{Any}([DinArticle, DinReporter])
    # test_get_table_description_names
    desc = din_desc(DinReporter)
    @test [c.name for c in desc] == ["id", "first_name", "last_name", "email", "facebook_user_id", "raw_data", "small_int", "interval"]
    # test_get_table_description_types (the key's type aside: inspectdb writes no field for it)
    # (Juango's SQLite columns are TEXT and INTEGER, so the types there are those)
    @test din_type.(desc[2:end]) == (IS_POSTGRES || IS_MYSQL ?
        ["CharField", "CharField", "CharField", "BigIntegerField", "BinaryField", "SmallIntegerField", IS_POSTGRES ? "DurationField" : "BigIntegerField"] :
        ["TextField", "TextField", "TextField", "IntegerField", "BinaryField", "IntegerField", "IntegerField"])
    # test_get_table_description_col_lengths
    (IS_POSTGRES || IS_MYSQL) &&
        @test [parse(Int, match(r"max_length = (\d+)", first(Juango.field_for(c)))[1]) for c in desc if din_type(c) == "CharField"] == [30, 30, 254]
    # test_get_table_description_nullable
    @test [c.null for c in desc] == [false, false, false, false, true, true, false, false]
    # test_bigautofield / test_smallautofield
    @test occursin(r"bigint|integer", only(c.type for c in din_desc(DinCity) if c.name == "id"))
    @test !(IS_POSTGRES || IS_MYSQL) || occursin("smallint", only(c.type for c in din_desc(DinCountry) if c.name == "id"))
    # test_db_comments (SQLite keeps none)
    if IS_POSTGRES || IS_MYSQL
        cm = introspect_comments("din_dbcommentmodel")
        @test cm.columns["name"] == "'Name' column comment" && cm.table == "Custom table comment"
    end
    # test_get_relations
    @test introspect_relations("din_article") == Dict("reporter_id" => ("id", "din_reporter"), "response_to_id" => ("id", "din_article"))
    # test_get_primary_key_column
    @test introspect_primary_key_column("din_article") == "id"
    @test introspect_primary_key_column("din_district") == "city_id"
    # test_get_constraints_index_types
    cons = introspect_constraints("din_article")
    @test only(c.type for c in values(cons) if c.columns == ["headline", "pub_date"]) == "idx"
    @test only(c.type for c in values(cons) if c.columns == ["headline", "response_to_id", "pub_date", "reporter_id"]) == "idx"
    # test_get_constraints_unique_indexes_orders (without the orders)
    if !IS_MYSQL                                         # (no partial indexes)
        c = introspect_constraints("din_uniqueconstraintconditionmodel")["cond_name_without_color_uniq"]
        @test c.unique && c.columns == ["name"]
    end
    # test_get_constraints
    function details(d, cols; primary_key = false, unique = false, index = false, check = false, foreign_key = nothing)
        u = d.unique || d.primary_key
        (d.columns == cols || (check && d.check)) && d.primary_key == primary_key && u == unique && (u ? false : d.index) == index &&
            d.check == check && d.foreign_key == foreign_key
    end
    constraints = merge(introspect_constraints("din_comment"), introspect_constraints("din_checkconstraintmodel"))
    custom = Set(["article_email_pub_date_uniq", "email_pub_date_idx", "up_votes_gte_0_check"])
    @test details(constraints["up_votes_gte_0_check"], ["up_votes"]; check = true)
    @test details(constraints["article_email_pub_date_uniq"], ["article_id", "email", "pub_date"]; unique = true)
    @test details(constraints["email_pub_date_idx"], ["email", "pub_date"]; index = true)
    field_constraints = Set{String}()
    for (name, d) in constraints
        name in custom && continue
        ok = if d.check
            true                                             # (the positive integer checks; some backends add more)
        elseif d.columns == ["ref"] && d.unique
            details(d, ["ref"]; unique = true)
        elseif d.columns == ["voting_number"] && d.unique
            details(d, ["voting_number"]; unique = true)
        elseif d.columns == ["article_id"] && d.foreign_key !== nothing
            details(d, ["article_id"]; foreign_key = ("din_article", "id"))
        elseif d.columns == ["article_id"] && d.index
            details(d, ["article_id"]; index = true)
        elseif d.columns == ["id"] && d.primary_key
            details(d, ["id"]; primary_key = true, unique = true)
        else
            false
        end
        ok ? push!(field_constraints, name) : @info "unaccounted constraint" name d
    end
    @test isempty(symdiff(Set(keys(constraints)), union(custom, field_constraints)))
end
