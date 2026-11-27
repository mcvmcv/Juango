# Django's test_runner tests, ported (#227): the parts Juango's file-based runner has. Django's DiscoverRunner finds
# and orders test cases; `manage.jl test` finds and orders test files (`test_plan(args)`) and makes a throwaway
# database (`setup_test_database`, `test_database_setting`).
# julia --project=test test/django_test_runner.jl   (see setup.jl)
#
# Not translated: test_debug_sql.py, test_parallel.py and DiscoverRunner's --parallel, --tag, --durations, --buffer,
# --pdb (#304); the unittest suite machinery (reorder_tests by test class, partition_suite_by_case, MySuite,
# the Shuffler's per-test hashing: Juango shuffles files with a seeded generator); DependencyOrderingTests and
# mirrors (Juango's DATABASES have no TEST DEPENDENCIES or MIRROR); custom test runner classes (TEST_RUNNER).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DtrPerson
    first_name::String = CharField(max_length = 20)
    Meta(table = "dtr_person")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DtrPerson]); push!(PORT_MODELS, DtrPerson)
end

const DTR_ROOT = mktempdir()
mkpath(joinpath(DTR_ROOT, "tests"))
for f in ("test_b.jl", "test_a.jl", "test_views.jl", "test_models.jl", "helpers.jl", "test_notes.txt")
    write(joinpath(DTR_ROOT, "tests", f), "")
end
dtr_names(args...) = basename.(Juango.test_plan(collect(String, args); root = DTR_ROOT)[1])

@testset "django test_runner: DiscoverRunnerTests (test files)" begin
    # test_dotted_test_module / test_discovery: tests/test*.jl, in order (helpers and other files left out)
    @test dtr_names() == ["test_a.jl", "test_b.jl", "test_models.jl", "test_views.jl"]
    # test/runtests.jl wins when there is one
    mkpath(joinpath(DTR_ROOT, "test")); write(joinpath(DTR_ROOT, "test", "runtests.jl"), "")
    @test dtr_names() == ["runtests.jl"]
    rm(joinpath(DTR_ROOT, "test"); recursive = true)
    # test_name_patterns (-k): files whose path contains a pattern; several patterns: any
    @test dtr_names("-k", "model") == ["test_models.jl"]
    @test dtr_names("-k", "model", "-k", "views") == ["test_models.jl", "test_views.jl"]
    @test isempty(dtr_names("-k", "nothing_matches"))
    # files given on the command line, in that order
    @test Juango.test_plan(["tests/test_b.jl", "tests/test_a.jl"]; root = DTR_ROOT)[1] == ["tests/test_b.jl", "tests/test_a.jl"]
    # test_reverse
    @test dtr_names("--reverse") == ["test_views.jl", "test_models.jl", "test_b.jl", "test_a.jl"]
    # test_shuffle_with_seed (ShufflerTests): one seed, one order, every time; and the seed is returned
    files, flags, seed = Juango.test_plan(["--shuffle=42"]; root = DTR_ROOT)
    @test seed == 42 && sort(basename.(files)) == dtr_names()
    @test all(_ -> dtr_names("--shuffle=42") == basename.(files), 1:5)
    @test length(unique([Tuple(dtr_names("--shuffle=$s")) for s in 1:20])) > 1          # (seeds do give other orders)
    # test_shuffle_without_seed: a seed is picked, and repeats the order
    files, _, seed = Juango.test_plan(["--shuffle"]; root = DTR_ROOT)
    @test seed isa Int && dtr_names("--shuffle=$seed") == basename.(files)
    # (-k, --reverse and --shuffle together: filtered, then ordered)
    @test sort(dtr_names("-k", "test_", "--reverse", "--shuffle=3")) == dtr_names()
    # the other options are kept for the runner (--failfast, --keepdb)
    _, flags, _ = Juango.test_plan(["--failfast", "--keepdb", "--update-snapshots"]; root = DTR_ROOT)
    @test flags == Dict("failfast" => "true", "keepdb" => "true", "update-snapshots" => "true")
end

@testset "django test_runner: test databases (SetupDatabasesTests, SQLiteInMemoryTestDbs, AutoIncrementResetTest)" begin
    # the test database's name: the real one's, prefixed with test_ (Django's TEST NAME default), the rest of the URL kept
    @test Juango.test_database_setting("postgresql://u:p@db:5432/shop?sslmode=require") == "postgresql://u:p@db:5432/test_shop?sslmode=require"
    @test Juango.test_database_setting("mysql://u@db/shop") == "mysql://u@db/test_shop"
    @test Juango.test_database_setting("postgresql://u@db") == "postgresql://u@db/test_juango"
    @test Juango.test_database_name("postgresql://u@db/test_shop") == "test_shop"
    # SQLiteInMemoryTestDbs: a SQLite database's tests run in memory
    @test Juango.test_database_setting("sqlite:///srv/app/db.sqlite3") == ":memory:"
    @test Juango.test_database_setting("db.sqlite3") == ":memory:"
    @test_throws Juango.ImproperlyConfigured Juango.test_database_setting(42)
    # a test database that is one of the real ones is refused: it would be dropped
    if occursin("://", string(settings.DATABASE))
        e = try
            override_settings(TEST_DATABASE = settings.DATABASE) do
                Juango.setup_test_database()
            end
            nothing
        catch err
            err
        end
        @test e isa Juango.ImproperlyConfigured && occursin("it would be dropped", sprint(showerror, e))
    end
    # AutoIncrementResetTest (reset_sequences = True): after a flush, ids start from 1 again
    port_block() do
        create(DtrPerson; first_name = "Jack"); create(DtrPerson; first_name = "Jill")
        serialized_rollback() do
            flush!()
            @test create(DtrPerson; first_name = "Jack").id == 1
            @test create(DtrPerson; first_name = "Jill").id == 2
        end
        @test sort([p.first_name for p in objects(DtrPerson)]) == ["Jack", "Jill"]
    end
end
