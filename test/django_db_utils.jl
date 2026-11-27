# Django's db_utils tests, ported (#227): tests/db_utils. Django's ConnectionHandler is Juango's DATABASES lookup
# (`Juango.db_state(alias)`), and a backend comes from the setting's URL scheme rather than an ENGINE path.
# julia --project=test test/django_db_utils.jl   (see setup.jl)
#
# Not translated: test_databases_property (a deprecated alias), test_no_default_database (Juango's "default" is
# always DATABASE, so there's always one).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

ddu_throws(f, T, msg = "") = try f(); false catch e; e isa T && occursin(msg, sprint(showerror, e)) end

@testset "django db_utils: ConnectionHandlerTests, LoadBackendTests, DatabaseErrorWrapperTests" begin
    # test_connection_handler_no_databases: an empty setting is improperly configured (Django: "Please supply the ENGINE value")
    @test occursin("empty", something(Juango.database_setting_issue(""), ""))
    # test_nonexistent_alias
    @test ddu_throws(() -> Juango.db_state("nonexistent"), Juango.ImproperlyConfigured, "no database 'nonexistent' in DATABASES")
    @test ddu_throws(() -> using_db(() -> Juango.db_state(), "nonexistent"), Juango.ImproperlyConfigured, "no database 'nonexistent'")
    # test_load_backend_invalid_name: an unknown scheme names the ones there are
    @test ddu_throws(() -> Juango.backend_from_setting("foo://x"), Juango.ImproperlyConfigured, "no database backend for 'foo://'")
    @test occursin("no database backend for 'foo://'", something(Juango.database_setting_issue("foo://x"), ""))
    # test_reraising_backend_specific_database_exception: PostgreSQL's own error, with its SQLSTATE
    if Juango.backend() isa Juango.PostgresBackend
        e = try Juango.execute("DROP TABLE \"X\""); nothing catch err; err end
        @test e isa DatabaseError && occursin("table \"X\" does not exist", e.msg) && e.sqlstate == "42P01"
    end
end
