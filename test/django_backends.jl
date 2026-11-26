# Django's backends tests, ported (part, #227): tests/backends/tests.py (LongNameTest, SequenceResetTest,
# FkConstraintsTests, DBConstraintTestCase). Juango's raw SQL takes `?` parameters (no %s escaping: EscapingChecks,
# ParameterHandlingTest), has no DB-API cursors (BackendTestCase's cursor tests, ThreadTests), logs queries under
# DEBUG (connection_queries, tested in db.jl), and tests connection_created in db.jl.
# julia --project=test test/django_backends.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DbkPerson
    first_name = CharField(max_length = 20)
    last_name = CharField(max_length = 20)
    Meta(table = "dbk_person")
end
# Django's long names: the table's, the join table's and the sequence's names pass PostgreSQL's 63 characters (Django's model has
# a long key name too: an automatic key not named id is #277)
@model struct DbkVeryLongModelNameZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ
    m2m_also_quite_long_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz = ManyToManyField(DbkPerson; blank = true)
end
@model struct DbkPost
    name = CharField(max_length = 30)
    text = TextField()
    Meta(table = "dbk_post")
end
@model struct DbkReporter
    first_name = CharField(max_length = 30)
    last_name = CharField(max_length = 30)
    Meta(table = "dbk_reporter")
end
@model struct DbkReporterProxy <: DbkReporter
    Meta(proxy = true)
end
@model struct DbkArticle
    headline = CharField(max_length = 100)
    pub_date = DateField()
    reporter = ForeignKey(DbkReporter; on_delete = :CASCADE)
    reporter_proxy = ForeignKey(DbkReporterProxy; on_delete = :SET_NULL, null = true, related_name = "reporter_proxy")
    Meta(table = "dbk_article")
end
@model struct DbkSQLKeywordsModel
    reporter = ForeignKey(DbkReporter; on_delete = :CASCADE)
    Meta(table = "order")
end
@model struct DbkObject
    related_objects = ManyToManyField(:DbkObject; db_constraint = false, symmetrical = false)
    Meta(table = "dbk_object")
end
@model struct DbkObjectReference
    obj = ForeignKey(DbkObject; on_delete = :CASCADE, db_constraint = false)
    Meta(table = "dbk_objectreference")
end
const DBK_MODELS = [DbkPerson, DbkVeryLongModelNameZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ, DbkPost, DbkReporter,
                    DbkReporterProxy, DbkArticle, DbkSQLKeywordsModel, DbkObject, DbkObjectReference]
redirect_stdout(devnull) do
    joins = [T for T in Juango.all_models() if T <: Juango.AutoThrough &&
             any(f -> f.kind === :fk && Juango.related_model(f) in DBK_MODELS, Juango.modelmeta(T).fields)]
    ms = vcat(DBK_MODELS, joins)
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
const DbkVLM = DbkVeryLongModelNameZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ

@testset "django backends: LongNameTest, SequenceResetTest" begin
    port_block() do
        o = create(DbkVLM)                                                              # test_sequence_name_length_limits_create
        @test o.pk isa Integer && create(DbkVLM).pk > o.pk
        p = create(DbkPerson; first_name = "Django", last_name = "Reinhardt")           # test_sequence_name_length_limits_m2m
        add!(o.m2m_also_quite_long_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz, p)
        @test count(o.m2m_also_quite_long_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz) == 1
        # test_sequence_name_length_limits_flush: the sequence reset of a long-named table runs
        foreach(Juango.execute, Juango.sequence_reset_sql(; models = [DbkVLM]))
        @test create(DbkVLM).pk > o.pk
        # SequenceResetTest.test_generic_relation: a key given by hand, then the sequences reset: the next is above it
        create(DbkPost; id = 10, name = "1st post", text = "hello world")
        foreach(Juango.execute, Juango.sequence_reset_sql(; models = [DbkPost]))
        @test create(DbkPost; name = "New post", text = "goodbye world").pk > 10
    end
end

@testset "django backends: FkConstraintsTests" begin
    port_block() do
        r = create(DbkReporter; first_name = "John", last_name = "Smith")
        # test_integrity_checks_on_creation (a key to no row fails, at the latest when the transaction commits)
        @test_throws Juango.IntegrityError atomic(() -> save!(DbkArticle(; headline = "This is a test", pub_date = Date(2005, 7, 27), reporter_id = 30)))
        @test_throws Juango.IntegrityError atomic(() -> save!(DbkArticle(; headline = "Another", reporter = r, pub_date = Date(2012, 8, 3), reporter_proxy_id = 30)))
        # test_integrity_checks_on_update
        create(DbkArticle; headline = "Test article", pub_date = Date(2010, 9, 4), reporter = r)
        a = get(DbkArticle; headline = "Test article")
        @test_throws Juango.IntegrityError atomic(() -> (a.reporter_id = 30; save!(a)))
        a = get(DbkArticle; headline = "Test article")
        @test_throws Juango.IntegrityError atomic(() -> (a.reporter_proxy_id = 30; save!(a)))
        # test_disable_constraint_checks_context_manager, test_check_constraints
        a = get(DbkArticle; headline = "Test article")
        atomic() do
            a.reporter_id = 30
            constraint_checks_disabled() do
                save!(a)
                e = try check_constraints(; table_names = ["dbk_article"]); nothing catch e; e end
                @test e isa Juango.IntegrityError && occursin("dbk_article", e.msg) && occursin("'30'", e.msg)
                @test check_constraints(; table_names = ["dbk_reporter"]) === nothing    # (another table is fine)
            end
            set_rollback!(true)
        end
        @test get(DbkArticle; id = a.id).reporter_id == r.id
        # test_check_constraints_sql_keywords: a table named "order"
        obj = create(DbkSQLKeywordsModel; reporter = r)
        atomic() do
            obj.reporter_id = 30
            constraint_checks_disabled() do
                save!(obj)
                @test_throws Juango.IntegrityError check_constraints(; table_names = ["order"])
            end
            set_rollback!(true)
        end
    end
end

@testset "django backends: DBConstraintTestCase" begin
    port_block() do
        obj = create(DbkObject)                                                         # test_can_reference_existent
        ref = create(DbkObjectReference; obj = obj)
        @test ref.obj.id == obj.id && get(DbkObjectReference; obj = obj).obj.id == obj.id
        @test !exists(filter(DbkObject; id = 12345))                                    # test_can_reference_non_existent
        ref = create(DbkObjectReference; obj_id = 12345)
        @test get(DbkObjectReference; obj_id = 12345).id == ref.id
        @test_throws Juango.DoesNotExist get(DbkObjectReference; id = ref.id).obj
        @test check_constraints(; table_names = ["dbk_objectreference"]) === nothing     # (no constraint: not checked)
        obj = create(DbkObject)                                                         # test_many_to_many
        add!(obj.related_objects, create(DbkObject))
        @test count(objects(DbkObject)) == 3 && count(obj.related_objects) == 1
        J = Juango.through_model(only(f for f in Juango.modelmeta(DbkObject).m2m if f.name === :related_objects))
        cols = [f.name for f in Juango.modelmeta(J).fields if f.kind === :fk]
        create(J; Symbol(cols[1], :_id) => obj.id, Symbol(cols[2], :_id) => 12345)
        @test count(obj.related_objects) == 1 && count(objects(J)) == 2
    end
end
