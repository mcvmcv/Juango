# db: julia --project=test test/db.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "connection pool" begin
    b = Juango.backend()
    if !Juango.supports_pooling(b)
        # SQLite: one shared connection; concurrent tasks still work, one statement at a time
        @sync for i in 1:5
            @async create(Topic; name = "pool-sqlite-$i")
        end
        @test count(filter(Topic; name__startswith = "pool-sqlite-")) == 5
        @test pool_status().in_use == 0
    else
        old = (settings.DATABASE_POOL_SIZE, settings.DATABASE_POOL_TIMEOUT, settings.CONN_MAX_AGE)
        sleep_sql = IS_POSTGRES ? "SELECT pg_sleep(0.4)" : "SELECT SLEEP(0.4)"
        try
            configure!(DATABASE_POOL_SIZE = 4)
            # queries in different tasks run at the same time
            t0 = time()
            @sync for i in 1:4
                @async Juango.execute(sleep_sql)
            end
            @test time() - t0 < 1.2                                        # one after another would take 1.6 s
            @test pool_status().in_use == 0 && pool_status().idle >= 2

            # a transaction keeps its connection; other tasks don't see it until it commits
            started, go_on = Channel(1), Channel(1)
            tx = @async atomic() do
                create(Topic; name = "pool-tx")
                put!(started, true)
                take!(go_on)
            end
            take!(started)
            seen_during = exists(filter(Topic; name = "pool-tx"))
            @test pool_status().in_use == 1
            put!(go_on, true); wait(tx)
            @test !seen_during && exists(filter(Topic; name = "pool-tx"))
            failing = @async try
                atomic() do
                    create(Topic; name = "pool-rolled-back")
                    error("stop")
                end
            catch
            end
            wait(failing)
            @test !exists(filter(Topic; name = "pool-rolled-back")) && pool_status().in_use == 0

            # exhaustion times out with a clear error
            configure!(DATABASE_POOL_SIZE = 1, DATABASE_POOL_TIMEOUT = 0.3)
            hold, release = Channel(1), Channel(1)
            holder = @async atomic(() -> (put!(hold, true); take!(release)))
            take!(hold)
            t0 = time()
            err = try Juango.execute("SELECT 1"); nothing catch e; e end
            @test err isa PoolTimeout && time() - t0 < 2 && occursin("DATABASE_POOL_SIZE", sprint(showerror, err))
            put!(release, true); wait(holder)
            @test Juango.execute("SELECT 1 AS one")[1][:one] == 1

            # broken connections are noticed and replaced
            configure!(DATABASE_POOL_SIZE = 4, DATABASE_POOL_TIMEOUT = 30)
            @sync for i in 1:2
                @async Juango.execute("SELECT 1")
            end
            if IS_POSTGRES
                other = LibPQ.Connection(TEST_DATABASE)
                LibPQ.execute(other, "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid()")
                close(other)
            else
                p = Juango.mysql_params(TEST_DATABASE)
                other = MySQL.DBInterface.connect(MySQL.Connection, p.host, p.user, p.password; port = p.port, db = p.db)
                ids = [r[1] for r in MySQL.DBInterface.execute(other, "SELECT id FROM information_schema.processlist WHERE db = DATABASE() AND id <> CONNECTION_ID()")]
                foreach(id -> MySQL.DBInterface.execute(other, "KILL CONNECTION $id"), ids)
                MySQL.DBInterface.close!(other)
            end
            sleep(1.2)                                                       # idle long enough to be health-checked
            @test Juango.execute("SELECT 1 AS one")[1][:one] == 1 && count(filter(Topic; name = "pool-tx")) == 1

            # CONN_MAX_AGE = 0 closes connections after use
            configure!(CONN_MAX_AGE = 0)
            Juango.execute("SELECT 1")
            @test pool_status().idle == 0
        finally
            configure!(DATABASE_POOL_SIZE = old[1], DATABASE_POOL_TIMEOUT = old[2], CONN_MAX_AGE = old[3])
        end
    end
end

@testset "database backends" begin
    B = Juango
    @test B.backend() isa (IS_POSTGRES ? B.PostgresBackend : IS_MYSQL ? B.MySQLBackend : B.SQLiteBackend)
    @test B.backend_from_setting("site.db") == B.SQLiteBackend("site.db")
    @test B.backend_from_setting("sqlite:///:memory:") == B.SQLiteBackend(":memory:")
    @test B.backend_from_setting("sqlite:////var/db/x.db") == B.SQLiteBackend("/var/db/x.db")
    @test B.backend_from_setting("postgresql://u@h/db") == B.PostgresBackend("postgresql://u@h/db")
    @test B.backend_from_setting("postgres://u@h/db") isa B.PostgresBackend
    @test B.backend_from_setting("mysql://u@h/db") isa B.MySQLBackend
    @test B.mysql_params("mysql://bob:p%40ss@db.local:3307/app") == (user = "bob", password = "p@ss", host = "db.local", port = 3307, db = "app")
    @test_throws B.ImproperlyConfigured B.backend_from_setting("oracle://u@h/db")
    pg = B.PostgresBackend("postgresql://u@h/db")
    @test B.rewrite_placeholders(pg, "a = ? AND b = '?' AND c IN (?, ?)") == "a = \$1 AND b = '?' AND c IN (\$2, \$3)"
    @test B.insert_sql(pg, "\"t\"", ["\"a\""]) == "INSERT INTO \"t\" (\"a\") VALUES (?) RETURNING \"id\""
    @test B.lookup_sql(pg, Val(:icontains), "c", "50%") == ("c ILIKE ? ESCAPE '\\'", Any["%50\\%%"])
    @test B.column_type(pg, :datetime, nothing) == "TIMESTAMP" && B.column_type(pg, :char, 30) == "VARCHAR(30)"
    @test occursin("DEFERRABLE", B.foreign_key_sql(pg, "post", "author_id", "author"))
    @test length(B.constraint_name(repeat("x", 80), "col", "fk")) == 63
    @test_throws B.ImproperlyConfigured B.backend_from_setting("nosuch://x")
    @test_throws B.ImproperlyConfigured B.backend_from_setting(42)

    nb = NumberedSQLite(":memory:")
    rw(s) = B.rewrite_placeholders(nb, s)
    @test rw("SELECT * FROM t WHERE a = ? AND b IN (?, ?)") == "SELECT * FROM t WHERE a = ?1 AND b IN (?2, ?3)"
    @test rw("SELECT '?', \"q?\", 'it''s ?' FROM t WHERE x = ?") == "SELECT '?', \"q?\", 'it''s ?' FROM t WHERE x = ?1"
    @test rw("SELECT 1 -- what?\nWHERE y = ? /* and? */ AND z = ?") == "SELECT 1 -- what?\nWHERE y = ?1 /* and? */ AND z = ?2"
    @test B.rewrite_placeholders(B.SQLiteBackend(":memory:"), "a = ?") == "a = ?"

    # constraint violations become IntegrityError
    create(Author; name = "Unique Ursula")
    @test_throws IntegrityError create(Author; name = "Unique Ursula")

    # explicit ids don't break later inserts (Postgres needs its sequence moved)
    big = save!(Author(id = 5000, name = "Explicit Id"))
    @test big.id == 5000 && create(Author; name = "After Explicit").id == 5001
    # aggregates come back as plain Julia numbers on every backend
    @test aggregate(filter(Author; id__gte = 5000), :sum, :id) === 10001
    @test aggregate(filter(Author; id__gte = 5000), :avg, :id) == 5000.5
    if IS_POSTGRES
        # Postgres enforces foreign keys (deferred, so atomic blocks can insert in any order)
        @test_throws IntegrityError Juango.execute("INSERT INTO \"tag\" (\"label\", \"article_id\") VALUES (?, ?)", ["x", 999999])
        @test_throws IntegrityError atomic(() -> create(Author; name = "Explicit Id"))
        @test exists(filter(Author; name = "After Explicit"))   # connection still usable after a failed transaction
        @test !isempty(Juango.execute("SELECT 1 FROM pg_constraint WHERE contype = 'f' AND conname LIKE 'article_author_id_fk%'"))
    end

    # generic SQL defaults (what a new backend inherits)
    g = GenericSQL()
    @test B.column_type(g, :bool, nothing) == "BOOLEAN" && B.column_type(g, :char, 20) == "VARCHAR(20)"
    @test B.limit_offset_sql(g, 10, 0) == " LIMIT 10" && B.limit_offset_sql(g, nothing, 5) == " OFFSET 5"
    @test B.lookup_sql(g, Val(:year), "c", 2024) == ("EXTRACT(YEAR FROM c) = ?", Any[2024])
    @test B.lookup_sql(g, Val(:startswith), "c", "a_b") == ("c LIKE ? ESCAPE '\\'", Any["a\\_b%"])
    @test B.insert_sql(g, "t", String[]) == "INSERT INTO t DEFAULT VALUES"
    @test B.sql_literal(g, true) == "TRUE" && B.sql_literal(g, "it's") == "'it''s'"
    @test B.limit_offset_sql(B.SQLiteBackend(""), nothing, 5) == " LIMIT -1 OFFSET 5"
    @test B.column_type(B.SQLiteBackend(""), :bool, nothing) == "INTEGER"

    # the ORM end-to-end through numbered placeholders
    old = settings.DATABASE
    try
        configure!(DATABASE = nb)
        @test B.backend() === nb
        migrate(verbose = false)
        a = create(Author; name = "Num", email = "n@x.io")
        for i in 1:5
            create(Article; title = "Post $i", body = i == 3 ? "50% off_now" : "body", author = a,
                   published = isodd(i))
        end
        @test count(filter(Article; author__name = "Num")) == 5
        @test count(filter(Article; published = true)) == 3
        @test count(filter(Article; body__contains = "50% off_")) == 1
        @test count(filter(Article; body__icontains = "OFF_NOW")) == 1
        @test count(filter(Article; body__contains = "x%")) == 0
        @test count(filter(Article; title__startswith = "Post")) == 5
        @test count(filter(Article; title__endswith = "4")) == 1
        @test count(filter(Article; created__year = year(now()))) == 5 && count(filter(Article; created__day = 40)) == 0
        @test count(filter(Article; id__in = Int[])) == 0
        @test count(none(objects(Article))) == 0
        @test [x.title for x in order_by(Article, "id")[2:3]] == ["Post 2", "Post 3"]
        @test aggregate(objects(Article), :max, :views) == 0
        @test update!(filter(Article; published = false); views = 7) == 2
        @test count(filter(Article; views = 7)) == 2
        @test_throws ErrorException atomic() do
            create(Author; name = "Rolled back")
            error("boom")
        end
        @test !exists(filter(Author; name = "Rolled back"))
        @test delete!(a) isa Author && count(objects(Article)) == 0
    finally
        configure!(DATABASE = old)
    end
    @test B.backend() isa (IS_POSTGRES ? B.PostgresBackend : IS_MYSQL ? B.MySQLBackend : B.SQLiteBackend)
end
