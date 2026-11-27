# Django's migration_test_data_persistence tests, ported (#227): data a migration loaded is still there in the tests.
# Django's TransactionTestCase with serialized_rollback = True is Juango's `serialized_rollback(f)`: the data from
# before is loaded again after `f` (which may commit or flush). A TestCase is `rollback_after`.
# julia --project=test test/django_migration_test_data_persistence.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DmtBook
    title::String = CharField(max_length = 100)
    Meta(table = "dmt_book")
end
@model struct DmtTag
    name::String = CharField(max_length = 20)
    books = ManyToManyField(DmtBook, related_name = "tags")
    Meta(table = "dmt_tag")
end
redirect_stdout(devnull) do
    ms = [DmtBook, DmtTag, through(DmtTag, :books)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django migration_test_data_persistence" begin
    port_block() do
        # (the row a data migration would have added: Django's migration_test_data_persistence/migrations/0002)
        b = create(DmtBook; title = "Book 1")
        t = create(DmtTag; name = "t"); add!(t.books, b)
        others = count(objects(Juango.User))
        # MigrationDataPersistenceTestCase.test_persistence: the data is there, in a test that commits
        r = serialized_rollback() do
            @test count(objects(DmtBook)) == 1
            create(DmtBook; title = "committed by the test")
            :done
        end
        @test r === :done
        @test [x.title for x in objects(DmtBook)] == ["Book 1"]
        @test [x.name for x in only(collect(objects(DmtBook))).tags] == ["t"]
        # MigrationDataPersistenceClassSetup: after another test flushed the database, the data is back
        serialized_rollback() do
            flush!()
            @test count(objects(DmtBook)) == 0
        end
        @test only(collect(objects(DmtBook))) isa DmtBook
        @test only(collect(objects(DmtBook))).id == b.id
        @test count(first(collect(objects(DmtBook))).tags) == 1
        @test count(objects(Juango.User)) == others
        # (and when the test throws)
        @test_throws ErrorException serialized_rollback(() -> (flush!(); error("boom")))
        @test count(objects(DmtBook)) == 1
        # new rows don't collide with the restored ones
        @test create(DmtBook; title = "Book 2").id != b.id
        # MigrationDataNormalPersistenceTestCase: a TestCase (rollback_after) sees it too
        rollback_after() do
            @test count(objects(DmtBook)) == 2
        end
        # the JSON round trip on its own
        data = serialize_database()
        @test occursin("Book 1", data)
        flush!(; inhibit_post_migrate = true)          # (the data has its own content types)
        @test deserialize_database!(data) >= 2 && count(objects(DmtBook)) == 2
    end
    # flush! on SQLite also empties a table that isn't Juango's but references one of its tables (as PostgreSQL's
    # TRUNCATE ... CASCADE): its rows would otherwise fail the foreign key check
    if Juango.backend() isa Juango.SQLiteBackend
        port_block() do
            b = create(DmtBook; title = "Book 1")
            execute("CREATE TABLE dmt_rawnote (id INTEGER PRIMARY KEY, book_id INTEGER REFERENCES dmt_book (id) DEFERRABLE INITIALLY DEFERRED)")
            try
                execute("INSERT INTO dmt_rawnote (id, book_id) VALUES (1, ?)", [b.id])
                @test any(s -> occursin("dmt_rawnote", s), Juango.flush_sql())
                flush!()
                @test count(objects(DmtBook)) == 0 && isempty(execute("SELECT id FROM dmt_rawnote"))
            finally
                execute("DROP TABLE dmt_rawnote")
            end
        end
    end
end
