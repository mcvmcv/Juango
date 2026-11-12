# migrations: julia --project=test test/migrations.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "migrations: inheritance and indexes" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("miginh" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    hastable(t) = Juango.table_exists(Juango.backend(), t)
    try
        @eval @abstract_model struct MiBase
            label = CharField(max_length = 20, default = "")
        end
        @eval @model struct MiShop <: MiBase
            name = CharField(max_length = 20)
            Meta(table = "mi_shop", app_label = "miginh", indexes = [Index(:name, :label; name = "mi_shop_name_label")])
        end
        @eval @model struct MiCafe <: MiShop
            seats = IntegerField(default = 0)
            Meta(table = "mi_cafe", app_label = "miginh")
        end
        @eval @model struct MiProxy <: MiShop
            Meta(proxy = true, app_label = "miginh")
        end
        p1 = only(quiet(() -> makemigrations(app = "miginh", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("CreateModel(\"mi_cafe\"", src) && occursin("parent = \"mi_shop\"", src)
        @test occursin("Index([\"name\", \"label\"]; name = \"mi_shop_name_label\")", src)
        @test !occursin("MiProxy", src)
        @test findfirst("\"mi_shop\";", src)[1] < findfirst("\"mi_cafe\";", src)[1]
        quiet(() -> migrate())
        c = create(MiCafe; name = "Fidel's", label = "cafe", seats = 20)
        @test get(MiShop; id = c.id).name == "Fidel's" && get(MiCafe; name = "Fidel's").seats == 20
        @test count(objects(MiProxy)) == 1

        Juango.unregister_model!(MiCafe); Juango.unregister_model!(MiProxy); Juango.unregister_model!(MiShop)
        @eval @model struct MiShop2 <: MiBase
            name = CharField(max_length = 20)
            Meta(table = "mi_shop", name = "MiShop", app_label = "miginh", indexes = [Index(:name; name = "mi_shop_name", unique = true)])
        end
        @eval @model struct MiCafe2 <: MiShop2
            seats = IntegerField(default = 0)
            Meta(table = "mi_cafe", name = "MiCafe", app_label = "miginh")
        end
        p2 = only(quiet(() -> makemigrations(app = "miginh", questioner = _ -> false)))
        src = read(p2, String)
        @test occursin("RemoveIndex(\"mi_shop\", \"mi_shop_name_label\")", src)
        @test occursin("AddIndex(\"mi_shop\", Index([\"name\"]; name = \"mi_shop_name\", unique = true))", src)
        quiet(() -> migrate())
        @test_throws IntegrityError create(MiShop2; name = "Fidel's")
        quiet(() -> migrate(app = "miginh", target = "0001"))
        create(MiShop2; name = "Fidel's")                          # unique index gone again
        quiet(() -> migrate(app = "miginh", target = "zero"))
        @test !hastable("mi_cafe") && !hastable("mi_shop")
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "miginh", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "migrations: partial and expression indexes" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migidx" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    mysql = Juango.backend() isa Juango.MySQLBackend
    try
        @eval @model struct MiAcct
            email = CharField(max_length = 50)
            handle = CharField(max_length = 50, default = "")
            active = BooleanField(default = true)
            Meta(table = "mi_acct", app_label = "migidx", indexes = [
                Index(Lower(:email); name = "mi_acct_email_ci", unique = true),
                Index(:handle; name = "mi_acct_handle_active", unique = true, condition = Q(active = true)),
                Index(:handle; name = "mi_acct_handle_inc", include = [:active]),
            ])
        end
        p1 = only(quiet(() -> makemigrations(app = "migidx", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("expressions = [(\"LOWER\", \"email\")]", src)
        @test occursin("condition = Q(:AND, Any[:active => true], false)", src)
        @test occursin("include = [\"active\"]", src)
        quiet(() -> migrate())
        @test isempty(quiet(() -> makemigrations(app = "migidx", questioner = _ -> false)))   # the migration matches the model
        create(MiAcct; email = "Ann@x.io", handle = "ann")
        create(MiAcct; email = "bob@x.io", handle = "ann", active = false)          # outside the partial index
        if mysql
            create(MiAcct; email = "ANN@x.io", handle = "x")                         # MySQL/MariaDB skip these indexes
        else
            @test_throws IntegrityError create(MiAcct; email = "ANN@x.io", handle = "x")
            @test_throws IntegrityError create(MiAcct; email = "cy@x.io", handle = "ann")
        end
        ix = Index(Lower(:email); name = "n")
        @test ix.expressions == [("LOWER", "email")] && isempty(ix.columns)
        @test_throws ArgumentError Index(Lower(:email))                              # needs a name
        @test_throws ArgumentError Index(:a, Lower(:b); name = "n")
        pg = Juango.PostgresBackend
        sqls = Juango.index_spec_sql(Juango.backend(), "t", Index(["a"]; name = "i", opclasses = ["varchar_pattern_ops"], include = ["b"], condition = Q(:AND, Any[:c => 1], false)))
        sql = mysql ? "" : only(sqls)
        if mysql
            @test isempty(sqls)                                                      # no partial indexes
        elseif Juango.backend() isa pg
            @test occursin("varchar_pattern_ops", sql) && occursin("INCLUDE", sql) && occursin("WHERE", sql)
        elseif !mysql
            @test !occursin("varchar_pattern_ops", sql) && !occursin("INCLUDE", sql) && occursin("WHERE \"c\" = 1", sql)
        end
        quiet(() -> migrate(app = "migidx", target = "zero"))
        @test !Juango.table_exists(Juango.backend(), "mi_acct")
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migidx", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "migrations: database comments" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migcom" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    b = Juango.backend()
    col_comment() = b isa Juango.PostgresBackend ?
        only(Juango.execute("SELECT col_description('mi_note'::regclass, (SELECT attnum FROM pg_attribute WHERE attrelid = 'mi_note'::regclass AND attname = 'body')) AS c"))[:c] :
        b isa Juango.MySQLBackend ?
        only(Juango.execute("SELECT COLUMN_COMMENT AS c FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'mi_note' AND COLUMN_NAME = 'body'"))[:c] : nothing
    tab_comment() = b isa Juango.PostgresBackend ? only(Juango.execute("SELECT obj_description('mi_note'::regclass, 'pg_class') AS c"))[:c] :
        b isa Juango.MySQLBackend ?
        only(Juango.execute("SELECT TABLE_COMMENT AS c FROM information_schema.TABLES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'mi_note'"))[:c] : nothing
    try
        @eval @model struct MiNote
            body = TextField(db_comment = "The note's text")
            Meta(table = "mi_note", app_label = "migcom", db_table_comment = "Notes, one per row")
        end
        src = read(only(quiet(() -> makemigrations(app = "migcom", questioner = _ -> false))), String)
        @test occursin("comment = \"The note's text\"", src) && occursin("comment = \"Notes, one per row\"", src)
        quiet(() -> migrate())
        if !(b isa Juango.SQLiteBackend)
            @test col_comment() == "The note's text" && tab_comment() == "Notes, one per row"
        end
        Juango.unregister_model!(MiNote)
        @eval @model struct MiNote2
            body = TextField(db_comment = "Changed")
            Meta(table = "mi_note", name = "MiNote", app_label = "migcom")
        end
        src = read(only(quiet(() -> makemigrations(app = "migcom", questioner = _ -> false))), String)
        @test occursin("AlterField(\"mi_note\"", src) && occursin("AlterModelTableComment(\"mi_note\", nothing)", src)
        quiet(() -> migrate())
        if !(b isa Juango.SQLiteBackend)
            @test col_comment() == "Changed" && something(tab_comment(), "") == ""
        end
        @test isempty(quiet(() -> makemigrations(app = "migcom", questioner = _ -> false)))
        quiet(() -> migrate(app = "migcom", target = "0001"))
        b isa Juango.SQLiteBackend || @test tab_comment() == "Notes, one per row"
        quiet(() -> migrate(app = "migcom", target = "zero"))
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migcom", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "migrations" begin
    M = Juango.Migrations
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migtest" => dir))
    function capture(f)
        path, io = mktemp()
        r = redirect_stdout(f, io)
        close(io)
        r, read(path, String)
    end
    quiet(f) = first(capture(f))
    no = _ -> false
    b() = Juango.backend()
    cols(t) = Set(Juango.table_columns(b(), t))
    hastable(t) = Juango.table_exists(b(), t)
    writemig(name, code) = write(joinpath(dir, name * ".jl"), "using Juango.Migrations\n" * code)
    try
        # --- 0001: initial ---------------------------------------------------------------
        @eval @model struct MigAuthor
            name = CharField(max_length = 50)
            Meta(table = "mig_author", app_label = "migtest")
        end
        @eval @model struct MigPostV1
            title = CharField(max_length = 100)
            body = TextField(blank = true)
            obsolete = IntegerField(default = 0)
            author = ForeignKey(:MigAuthor, on_delete = :CASCADE)
            Meta(table = "mig_post", app_label = "migtest")
        end
        paths = quiet(() -> makemigrations(app = "migtest", questioner = no))
        @test length(paths) == 1 && basename(paths[1]) == "0001_initial.jl"
        src = read(paths[1], String)
        @test occursin("initial = true", src) && occursin("dependencies = []", src)
        @test findfirst("CreateModel(\"mig_author\"", src)[1] < findfirst("CreateModel(\"mig_post\"", src)[1]
        @test occursin("Column(\"author_id\", :fk; index = true, references = \"mig_author\")", src)
        @test quiet(() -> makemigrations(app = "migtest", questioner = no)) == String[]
        @test occursin("CREATE TABLE $(Juango.qname("mig_post"))", sqlmigrate("migtest", "0001"))
        @test occursin("DROP TABLE", sqlmigrate("migtest", "0001"; backwards = true))

        _, out = capture(() -> migrate())
        @test occursin("Applying migtest.0001_initial... OK", out)
        @test cols("mig_post") == Set(["id", "title", "body", "obsolete", "author_id"])
        rows = M.showmigrations(io = devnull)
        @test ("migtest", "0001_initial", true) in rows && ("auth", "0001_initial", true) in rows
        a = create(MigAuthor; name = "Ann")
        create(MigPostV1; title = "Hello", body = "b", author = a)

        # --- 0002: rename, add, alter, remove, create -------------------------------------
        Juango.unregister_model!(MigPostV1)
        @eval @model struct MigPostV2
            headline = CharField(max_length = 100)
            body = CharField(max_length = 500, null = true, blank = true)
            status = CharField(max_length = 1, default = "d")
            author = ForeignKey(:MigAuthor, on_delete = :CASCADE)
            Meta(table = "mig_post", app_label = "migtest")
        end
        @eval @model struct MigTag
            label = CharField(max_length = 20, unique = true)
            post = ForeignKey(:MigPostV2, null = true, on_delete = :SET_NULL)
            Meta(table = "mig_tag", app_label = "migtest")
        end
        _, out = capture(() -> migrate())
        @test occursin("have changes that are not yet reflected in a migration", out)

        ops = M.detect_changes(M.build_graph(), "migtest"; questioner = no)   # no rename: add + remove
        @test any(op -> op isa M.AddField && op.column.name == "headline", ops)
        @test any(op -> op isa M.RemoveField && op.name == "title", ops)

        asked = String[]
        paths = quiet(() -> makemigrations(app = "migtest", questioner = q -> (push!(asked, q); true)))
        @test startswith(basename(paths[1]), "0002_")
        @test any(q -> occursin("mig_post.title renamed to mig_post.headline", q), asked)
        src = read(paths[1], String)
        @test occursin("(\"migtest\", \"0001_initial\")", src) && !occursin("initial = true", src)
        @test occursin("RenameField(\"mig_post\", \"title\", \"headline\")", src)
        @test occursin("AddField(\"mig_post\", Column(\"status\", :string; default = \"d\", max_length = 1))", src)
        @test occursin("AlterField(\"mig_post\", Column(\"body\", :string; null = true, max_length = 500))", src)
        @test occursin("RemoveField(\"mig_post\", \"obsolete\")", src)
        @test occursin("CreateModel(\"mig_tag\"", src)

        quiet(() -> migrate())
        @test cols("mig_post") == Set(["id", "headline", "body", "status", "author_id"])
        r = only(Juango.execute("SELECT \"headline\", \"body\", \"status\" FROM \"mig_post\""))
        @test r[:headline] == "Hello" && r[:body] == "b" && r[:status] == "d"
        create(MigTag; label = "x", post = get(MigPostV2; headline = "Hello"))
        @test_throws IntegrityError create(MigTag; label = "x")
        @test get(MigPostV2; headline = "Hello").author.name == "Ann"

        # --- backwards and forwards ---------------------------------------------------------
        create(MigPostV2; headline = "No body", body = nothing, author = a)   # NULL, then body becomes NOT NULL again
        _, out = capture(() -> migrate(app = "migtest", target = "0001"))
        @test occursin("Unapplying migtest.0002", out)
        @test cols("mig_post") == Set(["id", "title", "body", "obsolete", "author_id"]) && !hastable("mig_tag")
        rs = Juango.execute("SELECT \"title\", \"body\", \"obsolete\" FROM \"mig_post\" ORDER BY \"id\"")
        @test [r[:title] for r in rs] == ["Hello", "No body"] && [r[:body] for r in rs] == ["b", ""]
        @test all(r -> r[:obsolete] == 0, rs)
        quiet(() -> migrate())
        @test "headline" in cols("mig_post") && hastable("mig_tag")
        create(MigTag; label = "x", post = get(MigPostV2; headline = "Hello"))   # the table was recreated empty

        # --- renaming a table ---------------------------------------------------------------
        Juango.unregister_model!(MigTag)
        @eval @model struct MigLabel
            label = CharField(max_length = 20, unique = true)
            post = ForeignKey(:MigPostV2, null = true, on_delete = :SET_NULL)
            Meta(table = "mig_label", app_label = "migtest")
        end
        paths = quiet(() -> makemigrations(app = "migtest", questioner = _ -> true, name = "label"))
        @test basename(paths[1]) == "0003_label.jl"
        @test occursin("RenameModel(\"mig_tag\", \"mig_label\"; model = \"MigLabel\")", read(paths[1], String))
        quiet(() -> migrate())
        @test hastable("mig_label") && !hastable("mig_tag") && get(MigLabel; label = "x").post.headline == "Hello"

        # --- hand-written data migration ----------------------------------------------------
        global MIG_FLAG = 0
        writemig("0004_data", """
        Migration(
            dependencies = [("migtest", "0003_label")],
            operations = [
                RunSQL("INSERT INTO \\"mig_author\\" (\\"name\\") VALUES ('From SQL')",
                       "DELETE FROM \\"mig_author\\" WHERE \\"name\\" = 'From SQL'"),
                RunJulia(() -> (Main.MIG_FLAG += 1), () -> (Main.MIG_FLAG -= 10)),
            ],
        )
        """)
        quiet(() -> migrate())
        @test exists(filter(MigAuthor; name = "From SQL")) && MIG_FLAG == 1
        quiet(() -> migrate(app = "migtest", target = "0003"))
        @test !exists(filter(MigAuthor; name = "From SQL")) && MIG_FLAG == -9
        quiet(() -> migrate())

        # irreversible: the failed unapply rolls back and stays recorded
        writemig("0005_oneway", """
        Migration(dependencies = [("migtest", "0004_data")],
                  operations = [RunSQL("UPDATE \\"mig_author\\" SET \\"name\\" = \\"name\\"")])
        """)
        quiet(() -> migrate())
        @test_throws M.IrreversibleError quiet(() -> migrate(app = "migtest", target = "0004"))
        @test ("migtest", "0005_oneway") in M.applied_migrations()
        quiet(() -> migrate(app = "migtest", target = "0004", fake = true))
        @test !(("migtest", "0005_oneway") in M.applied_migrations())
        quiet(() -> migrate(fake = true))

        # --- conflicts and merging ----------------------------------------------------------
        writemig("0006_a", "Migration(dependencies = [(\"migtest\", \"0005_oneway\")])")
        writemig("0006_b", "Migration(dependencies = [(\"migtest\", \"0005_oneway\")])")
        @test_throws M.MigrationError quiet(() -> migrate())
        @test_throws M.MigrationError quiet(() -> makemigrations(app = "migtest", questioner = no))
        paths = quiet(() -> makemigrations(app = "migtest", merge = true))
        @test basename(paths[1]) == "0007_merge_0006_0006.jl"
        quiet(() -> migrate())
        @test ("migtest", "0007_merge_0006_0006") in M.applied_migrations()

        # empty migration template
        paths = quiet(() -> makemigrations(app = "migtest", empty = true, name = "custom"))
        @test basename(paths[1]) == "0008_custom.jl" && occursin("# RunSQL(", read(paths[1], String))
        @test M.load_migration(paths[1], "migtest").dependencies == [("migtest", "0007_merge_0006_0006")]
        quiet(() -> migrate())

        # check / dry run write nothing
        @eval @model struct MigExtra
            n = IntegerField(default = 1)
            Meta(table = "mig_extra", app_label = "migtest")
        end
        n_files = length(readdir(dir))
        @test length(quiet(() -> makemigrations(app = "migtest", check = true, questioner = no))) == 1
        @test length(readdir(dir)) == n_files
        Juango.unregister_model!(MigExtra)

        # --- all the way down ---------------------------------------------------------------
        @test_throws M.IrreversibleError quiet(() -> migrate(app = "migtest", target = "zero"))
        quiet(() -> migrate(app = "migtest", target = "0004", fake = true))   # step over the one-way migration
        quiet(() -> migrate(app = "migtest", target = "zero"))
        @test !hastable("mig_post") && !hastable("mig_author") && !hastable("mig_label")
        @test !any(k -> k[1] == "migtest", M.applied_migrations())

        # --- existing tables: the initial migration is faked ---------------------------------
        fakedir = mktempdir()
        configure!(MIGRATION_MODULES = Dict("migtest" => dir, "migfake" => fakedir))
        @eval @model struct MigOld
            note = CharField(max_length = 10)
            Meta(table = "mig_old", app_label = "migfake")
        end
        quiet(() -> Juango.sync_models!([MigOld]))
        quiet(() -> makemigrations(app = "migfake", questioner = no))
        _, out = capture(() -> migrate())
        @test occursin("Applying migfake.0001_initial... FAKED (tables already exist)", out)
        quiet(() -> migrate(app = "migfake", target = "zero"))
        @test !hastable("mig_old")
        Juango.unregister_model!(MigOld)
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app in ("migtest", "migfake"), Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "migrations: many-to-many and unique_together" begin
    M = Juango.Migrations
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migm2m" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    hastable(t) = Juango.table_exists(Juango.backend(), t)
    try
        @eval @model struct MmLabel
            name = CharField(max_length = 20)
            Meta(table = "mm_label", app_label = "migm2m")
        end
        @eval @model struct MmItem
            code = CharField(max_length = 10)
            batch = IntegerField(default = 0)
            labels = ManyToManyField(:MmLabel; blank = true)
            Meta(table = "mm_item", app_label = "migm2m")
        end
        p1 = only(quiet(() -> makemigrations(app = "migm2m", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("CreateModel(\"mm_item_labels\"", src)
        @test occursin("unique_together = [[\"mmitem_id\", \"mmlabel_id\"]]", src)
        quiet(() -> migrate())
        @test hastable("mm_item_labels")
        it, lb = create(MmItem; code = "a"), create(MmLabel; name = "x")
        add!(it.labels, lb)
        @test_throws IntegrityError Juango.execute("INSERT INTO \"mm_item_labels\" (\"mmitem_id\", \"mmlabel_id\") VALUES (?, ?)", [it.id, lb.id])

        # add a unique_together to a model: AlterUniqueTogether
        Juango.unregister_model!(MmItem)
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).table == "mm_item_labels", Juango.all_models()))
        @eval @model struct MmItem2
            code = CharField(max_length = 10)
            batch = IntegerField(default = 0)
            labels = ManyToManyField(:MmLabel; blank = true)
            Meta(table = "mm_item", name = "MmItem", app_label = "migm2m", unique_together = [(:code, :batch)])
        end
        p2 = only(quiet(() -> makemigrations(app = "migm2m", questioner = _ -> false)))
        @test occursin("AlterUniqueTogether(\"mm_item\", [[\"code\", \"batch\"]])", read(p2, String))
        quiet(() -> migrate())
        create(MmItem2; code = "b", batch = 1)
        @test_throws IntegrityError create(MmItem2; code = "b", batch = 1)
        @test count(get(MmItem2; code = "a").labels) == 1
        quiet(() -> migrate(app = "migm2m", target = "0001"))
        create(MmItem2; code = "c", batch = 1)
        create(MmItem2; code = "c", batch = 1)          # constraint gone again
        quiet(() -> migrate(app = "migm2m", target = "zero"))
        @test !hastable("mm_item_labels") && !hastable("mm_item")
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migm2m", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

# (inheritance migration tests are defined before "database backends")

@testset "apps" begin
    quiet(f) = redirect_stdout(f, devnull)
    IC = Juango.ImproperlyConfigured
    tmp = mktempdir()
    root = quiet(() -> startapp("shop"; dir = tmp))
    @test isfile(joinpath(root, "Shop.jl")) && isfile(joinpath(root, "templates", "shop", "index.html")) &&
          isdir(joinpath(root, "migrations")) && isdir(joinpath(root, "static", "shop"))
    @test_throws ErrorException quiet(() -> startapp("Bad-Name"; dir = tmp))
    write(joinpath(root, "models.jl"), "@model struct Product\n    name = CharField(max_length = 50)\nend\n")
    write(joinpath(root, "static", "shop", "app.css"), "body{}")
    mkpath(joinpath(root, "locale", "de", "LC_MESSAGES"))
    write(joinpath(root, "locale", "de", "LC_MESSAGES", "juango.po"), "msgid \"Shop hello\"\nmsgstr \"Hallo Laden\"\n")
    include(joinpath(root, "Shop.jl"))
    Shop = Main.Shop
    Product = Shop.Product
    calls = Ref(0)
    Shop.APP.ready = () -> (calls[] += 1)
    old_apps, old_urls = settings.INSTALLED_APPS, settings.ROOT_URLCONF
    try
        configure!(INSTALLED_APPS = vcat(Juango.default_installed_apps(), [Shop.APP]),
                   ROOT_URLCONF = vcat(old_urls, [path("shop/", include_urls(Shop.APP))]))
        configure!(DEBUG = true)
        @test calls[] == 1                                              # ready runs once
        @test is_installed("shop") && is_installed(Shop) && get_app("shop") === Shop.APP && !is_installed("nope")
        @test is_installed("juango.admin") && get_app("auth") === Juango.AUTH_APP

        # models belong to the app that defines them
        @test model_label(Product) == "shop.Product" && get_model("shop.product") === Product && app_models("shop") == [Product]
        @test model_label(User) == "auth.User" && get_model("auth.user") === User && model_label(Juango.SessionRecord) == "sessions.SessionRecord"
        @test_throws IC get_model("shop.Nope")
        @test Juango.Migrations.migration_dir("shop") == joinpath(root, "migrations") && "shop" in Juango.Migrations.known_apps()
        p = only(quiet(() -> makemigrations(; app = "shop")))
        @test p == joinpath(root, "migrations", "0001_initial.jl") && occursin("CreateModel", read(p, String))
        @test isempty(quiet(() -> Juango.execute_from_command_line(["makemigrations", "shop"])))     # nothing new
        quiet(() -> Juango.sync_models!([Product]))
        @test get_for_model(Product).app_label == "shop"

        # templates, URLs, static files and translations from the app's folder
        c = Client()
        r = get(c, "/shop/")
        @test r.status == 200 && occursin("<h1>Shop</h1>", text(r)) && reverse_url("shop:index") == "/shop/"
        r = get(c, "/static/shop/app.css")
        @test r.status == 200 && text(r) == "body{}"
        @test joinpath(root, "static") in static_dirs()
        @test with_language(() -> gettext("Shop hello"), "de") == "Hallo Laden"
        sroot = mktempdir()
        configure!(STATIC_ROOT = sroot)
        @test collectstatic() >= 1 && read(joinpath(sroot, "shop", "app.css"), String) == "body{}"
        configure!(APP_DIRS = false)
        @test !(joinpath(root, "templates") in Juango.template_dirs()) && !(joinpath(root, "static") in static_dirs())
        configure!(APP_DIRS = true)

        # management commands from apps
        Shop.APP.commands["shophello"] = ("Say hi", args -> "hi " * join(args, " "))
        @test Juango.execute_from_command_line(["shophello", "there"]) == "hi there"
        helptext = mktemp() do path, io
            redirect_stdout(() -> Juango.execute_from_command_line(["help"]), io); flush(io); read(path, String)
        end
        @test occursin("shophello", helptext)
        @test isempty(quiet(() -> Juango.execute_from_command_line(["check"])))

        # leaving built-in apps out
        configure!(INSTALLED_APPS = ["juango.auth", "juango.contenttypes", Shop])
        @test_throws IC Admin.urls()
        cmds = Juango.all_commands()
        @test !haskey(cmds, "clearsessions") && haskey(cmds, "createsuperuser") && haskey(cmds, "shophello")
        @test any(i -> occursin("SessionMiddleware", i), Juango.app_issues())
        configure!(INSTALLED_APPS = ["juango.admin", "juango.contenttypes", "juango.sessions", "juango.messages"])
        @test any(i -> occursin("requires 'auth'", i), Juango.app_issues())
        @test_throws IC Juango.auth_urls()
        @test !haskey(Juango.all_commands(), "createsuperuser")
        @test_throws IC configure!(INSTALLED_APPS = ["nope"])
        @test_throws IC configure!(INSTALLED_APPS = [Shop.APP, "shop"])
        @test_throws IC App("not valid")
    finally
        configure!(INSTALLED_APPS = old_apps, ROOT_URLCONF = old_urls, STATIC_ROOT = "", APP_DIRS = true)
        table = Juango.modelmeta(Product).table
        Juango.unregister_model!(Product)
        Juango.execute("DROP TABLE IF EXISTS " * Juango.qname(table))
    end
    @test !is_installed("shop") && haskey(Juango.all_commands(), "clearsessions")
end

@testset "startproject" begin
    dir = mktempdir()
    root = redirect_stdout(devnull) do
        startproject("mysite"; dir = dir, develop = false)
    end
    @test isfile(joinpath(root, "manage.jl")) && isfile(joinpath(root, "templates", "home.html"))
end

@testset "constraints: CheckConstraint and UniqueConstraint" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migcons" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    partial = Juango.supports_partial_indexes(Juango.backend())
    functional = Juango.supports_expression_indexes(Juango.backend())
    try
        @eval @model struct CnBooking
            room = CharField(max_length = 10)
            start = DateField()
            stop = DateField()
            cancelled = BooleanField(default = false)
            code = CharField(max_length = 10, default = "")
            Meta(table = "cn_booking", app_label = "migcons", constraints = [
                CheckConstraint(condition = Q(stop__gte = F(:start)), name = "cn_stop_after_start"),
                CheckConstraint(condition = Q(room__ne = "") & !Q(room__startswith = "x"), name = "cn_room",
                                violation_error_message = "Bad room."),
                UniqueConstraint(fields = [:room, :start], condition = Q(cancelled = false), name = "cn_one_per_day"),
                UniqueConstraint(Lower(:code); name = "cn_code_ci", condition = Q(code__ne = "")),
            ])
        end
        p1 = only(quiet(() -> makemigrations(app = "migcons", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("ConstraintSpec(:check, \"cn_stop_after_start\"; condition = Q(:AND, Any[:stop__gte => F(\"start\")], false))", src)
        @test occursin("ConstraintSpec(:unique, \"cn_one_per_day\"; columns = [\"room\", \"start\"], condition = Q(:AND, Any[:cancelled => false], false))", src)
        @test occursin("expressions = [(\"LOWER\", \"code\")]", src)
        @test quiet(() -> makemigrations(app = "migcons", questioner = _ -> false)) == String[]   # no changes
        quiet(() -> migrate())

        d(x) = Date(2024, 5, x)
        b1 = create(CnBooking; room = "A", start = d(1), stop = d(3), code = "Ab1")
        # the database enforces them
        @test_throws IntegrityError create(CnBooking; room = "B", start = d(5), stop = d(4))
        @test_throws IntegrityError create(CnBooking; room = "", start = d(5), stop = d(6))
        @test_throws IntegrityError create(CnBooking; room = "x1", start = d(5), stop = d(6))
        create(CnBooking; room = "A", start = d(1), stop = d(2), cancelled = true)        # cancelled ones don't count
        create(CnBooking; room = "C", start = d(1), stop = d(2))
        partial && @test_throws IntegrityError create(CnBooking; room = "A", start = d(1), stop = d(2))
        functional && @test_throws IntegrityError create(CnBooking; room = "D", start = d(1), stop = d(2), code = "AB1")

        # full_clean reports them before saving
        allerrs(o) = get(full_clean(o), :__all__, String[])
        @test isempty(allerrs(CnBooking(; room = "E", start = d(1), stop = d(1))))
        @test allerrs(CnBooking(; room = "E", start = d(2), stop = d(1))) == ["Constraint “cn_stop_after_start” is violated."]
        @test allerrs(CnBooking(; room = "x2", start = d(1), stop = d(1))) == ["Bad room."]
        @test allerrs(CnBooking(; room = "A", start = d(1), stop = d(9))) == ["Constraint “cn_one_per_day” is violated."]
        @test isempty(allerrs(CnBooking(; room = "A", start = d(1), stop = d(9), cancelled = true)))
        @test isempty(allerrs(b1))                                                   # itself doesn't clash
        @test allerrs(CnBooking(; room = "F", start = d(1), stop = d(2), code = "aB1")) == ["Constraint “cn_code_ci” is violated."]
        @test isempty(allerrs(CnBooking(; room = "F", start = d(1), stop = d(2))))   # code "" is outside the condition
        @test !haskey(full_clean(CnBooking(; room = "E", start = d(2), stop = d(1)); exclude = [:stop]), :__all__)

        # model forms too
        mf = ModelForm(CnBooking; data = Dict("room" => "A", "start" => "2024-05-01", "stop" => "2024-05-04", "code" => "q1"))
        @test !is_valid(mf) && Juango.non_field_errors(mf) == ["Constraint “cn_one_per_day” is violated."]
        mf = ModelForm(CnBooking; data = Dict("room" => "G", "start" => "2024-05-03", "stop" => "2024-05-01", "code" => "q2"))
        @test !is_valid(mf) && Juango.non_field_errors(mf) == ["Constraint “cn_stop_after_start” is violated."]
        mf = ModelForm(CnBooking; data = Dict("room" => "A", "start" => "2024-05-01", "stop" => "2024-05-05", "code" => "zz"),
                       instance = b1)
        @test is_valid(mf)

        # changing the constraints makes a migration that drops and adds them
        Juango.unregister_model!(CnBooking)
        @eval @model struct CnBooking2
            room = CharField(max_length = 10)
            start = DateField()
            stop = DateField()
            cancelled = BooleanField(default = false)
            code = CharField(max_length = 10, default = "")
            Meta(table = "cn_booking", name = "CnBooking", app_label = "migcons", constraints = [
                CheckConstraint(condition = Q(stop__gt = F(:start)) | Q(cancelled = true), name = "cn_stop_after_start"),
                UniqueConstraint(fields = [:room, :start], condition = Q(cancelled = false), name = "cn_one_per_day"),
            ])
        end
        # rows that break the stricter check would stop the migration; cancel them first
        update!(filter(CnBooking2; stop = d(1)); cancelled = true)
        update!(filter(base_objects(CnBooking2); start = d(1), stop = d(2), cancelled = false); stop = d(3))
        p2 = only(quiet(() -> makemigrations(app = "migcons", questioner = _ -> false)))
        src = read(p2, String)
        @test occursin("RemoveConstraint(\"cn_booking\", \"cn_stop_after_start\")", src) && occursin("RemoveConstraint(\"cn_booking\", \"cn_room\")", src)
        @test occursin("AddConstraint(\"cn_booking\", ConstraintSpec(:check, \"cn_stop_after_start\"; condition = Q(:OR, Any[Q(:AND, Any[:stop__gt => F(\"start\")], false), Q(:AND, Any[:cancelled => true], false)], false)))", src)
        quiet(() -> migrate())
        @test count(objects(CnBooking2)) == 3
        @test_throws IntegrityError create(CnBooking2; room = "H", start = d(5), stop = d(5))
        create(CnBooking2; room = "H", start = d(5), stop = d(5), cancelled = true)
        create(CnBooking2; room = "", start = d(6), stop = d(7))                 # cn_room is gone
        functional && create(CnBooking2; room = "I", start = d(6), stop = d(7), code = "AB1")
        # and back
        Juango.execute("DELETE FROM " * Juango.qname("cn_booking") * " WHERE " * Juango.qname("room") * " IN ('', 'H', 'I')")
        quiet(() -> migrate(app = "migcons", target = "0001"))
        @test_throws IntegrityError create(CnBooking2; room = "", start = d(6), stop = d(7))
        quiet(() -> migrate(app = "migcons", target = "zero"))
        @test !Juango.table_exists(Juango.backend(), "cn_booking")

        # bad definitions
        @test_throws ArgumentError UniqueConstraint(name = "none")
        @test_throws ArgumentError UniqueConstraint(Juango.Length(:code); name = "len")
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migcons", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "db_default and GeneratedField" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("miggen" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    persist = IS_POSTGRES          # PostgreSQL only has stored generated columns; elsewhere try virtual ones
    try
        @eval @model struct GfItem
            price = FloatField()
            qty = IntegerField(default = 1)
            label = CharField(max_length = 20, db_default = "none")
            stamp = DateTimeField(db_default = Now())
            total = GeneratedField(expression = F(:price) * F(:qty), output_field = FloatField())
            shout = GeneratedField(expression = Upper(:label), output_field = CharField(max_length = 20), db_persist = $persist)
            Meta(table = "gf_item", app_label = "miggen")
        end
        p1 = only(quiet(() -> makemigrations(app = "miggen", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("Column(\"total\", :float; null = true, generated = (CombinedExpression(\"*\", F(\"price\"), F(\"qty\")), true))", src)
        @test occursin("default = \"none\"", src) && occursin("default = Juango.SQLDefault(\"CURRENT_TIMESTAMP\")", src)
        @test quiet(() -> makemigrations(app = "miggen", questioner = _ -> false)) == String[]
        quiet(() -> migrate())

        o = GfItem(; price = 2.5, qty = 4)
        @test o.label === DB_DEFAULT && o.total === nothing
        @test !haskey(full_clean(o), :label)
        save!(o)
        @test o.total == 10.0 && o.label == "none" && o.shout == "NONE" && o.stamp !== nothing
        o.qty = 2; o.label = "big"; save!(o)
        @test o.total == 5.0 && o.shout == "BIG"
        update!(filter(GfItem; id = o.id); qty = 3)
        @test refresh!(o).total == 7.5
        @test get(GfItem; id = o.id).total == 7.5
        @test !(:total in [f.name for f in ModelForm(GfItem).fields]) && :label in [f.name for f in ModelForm(GfItem).fields]
        o2 = create(GfItem; price = 1.0, label = "given")
        @test o2.label == "given" && o2.total == 1.0
        if !occursin("SQLite", Juango.vendor(Juango.backend()))
            items = bulk_create([GfItem(; price = 3.0), GfItem(; price = 4.0, label = "set")])
            @test sort(values_list(filter(GfItem; price__gte = 3), :label; flat = true)) == ["none", "set"]
        end
        @test_throws ArgumentError bulk_update([o], [:total])

        # changing the expression changes the column
        Juango.unregister_model!(GfItem)
        @eval @model struct GfItem2
            price = FloatField()
            qty = IntegerField(default = 1)
            label = CharField(max_length = 20, db_default = "none")
            stamp = DateTimeField(db_default = Now())
            total = GeneratedField(expression = F(:price) * F(:qty) + 1, output_field = FloatField())
            shout = GeneratedField(expression = Upper(:label), output_field = CharField(max_length = 20), db_persist = $persist)
            Meta(table = "gf_item", name = "GfItem", app_label = "miggen")
        end
        p2 = only(quiet(() -> makemigrations(app = "miggen", questioner = _ -> false)))
        @test occursin("AlterField(\"gf_item\", Column(\"total\"", read(p2, String))
        quiet(() -> migrate())
        @test get(GfItem2; id = o.id).total == 8.5
        quiet(() -> migrate(app = "miggen", target = "0001"))
        @test get(GfItem2; id = o.id).total == 7.5
        quiet(() -> migrate(app = "miggen", target = "zero"))
        @test !Juango.table_exists(Juango.backend(), "gf_item")
        @test_throws ArgumentError Juango.column_state(Juango.Field(:int; db_default = Lower(:x)))
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "miggen", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "composite primary keys" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migcomp" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    try
        @eval @model struct CpLine
            order = IntegerField()
            product = CharField(max_length = 10)
            qty = IntegerField(default = 1)
            author = ForeignKey(Author, on_delete = :CASCADE, null = true)
            Meta(table = "cp_line", app_label = "migcomp", pk = CompositePrimaryKey(:order, :product))
        end
        p1 = only(quiet(() -> makemigrations(app = "migcomp", questioner = _ -> false)))
        src = read(p1, String)
        @test occursin("pk = :composite, pk_columns = [\"order\", \"product\"]", src)
        quiet(() -> migrate())
        @test !("id" in Juango.table_columns(Juango.backend(), "cp_line"))

        au = create(Author; name = "Composite Author")
        a = create(CpLine; order = 1, product = "apple", qty = 3, author = au)
        @test a.pk == (1, "apple") && a.id == (1, "apple")
        create(CpLine; order = 1, product = "pear", qty = 2)
        create(CpLine; order = 2, product = "apple", qty = 7)
        @test_throws IntegrityError create(CpLine; order = 1, product = "apple")
        @test get(CpLine; pk = (1, "apple")).qty == 3 && get(CpLine; pk = (2, "apple")).qty == 7
        @test_throws DoesNotExist get(CpLine; pk = (9, "x"))
        @test count(filter(CpLine; pk__in = [(1, "pear"), (2, "apple"), (5, "none")])) == 2
        @test count(filter(CpLine; pk__in = Tuple[])) == 0
        @test count(exclude(objects(CpLine), Q(pk = (1, "apple")))) == 2
        @test first(objects(CpLine)).pk == (1, "apple") && last(objects(CpLine)).pk == (2, "apple")
        @test [o.product for o in order_by(objects(CpLine), "-pk")] == ["apple", "pear", "apple"]
        @test get(CpLine; pk = (1, "apple")).author.name == "Composite Author"
        @test count(objects(CpLine)) == 3 && aggregate(objects(CpLine); t = Sum(:qty))[:t] == 12
        # save updates the row; a changed key saves a new row
        a.qty = 5; save!(a)
        @test get(CpLine; pk = (1, "apple")).qty == 5 && count(objects(CpLine)) == 3
        a.product = "plum"; save!(a)
        @test a.pk == (1, "plum") && count(objects(CpLine)) == 4 && exists(filter(CpLine; pk = (1, "apple")))
        @test refresh!(a).qty == 5
        # bulk operations
        @test update!(filter(CpLine; order = 1); qty = 9) == 3
        @test values_list(order_by(filter(CpLine; order = 1), "product"), :qty; flat = true) == [9, 9, 9]
        made = bulk_create([CpLine(; order = 3, product = "fig"), CpLine(; order = 3, product = "kiwi")])
        @test [o.pk for o in made] == [(3, "fig"), (3, "kiwi")]
        # delete
        delete!(get(CpLine; pk = (1, "plum")))
        @test !exists(filter(CpLine; pk = (1, "plum")))
        @test delete!(filter(CpLine; order = 3)) == 2 && count(objects(CpLine)) == 3
        # deleting the author cascades to its lines
        delete!(au)
        @test !exists(filter(CpLine; pk = (1, "apple")))
        # what isn't supported says so
        @test_throws ArgumentError Admin.register!(CpLine)
        @test_throws Juango.LookupError collect(filter(CpLine; pk__gt = (1, "a")))
        @eval @model struct CpNote
            line = ForeignKey(CpLine, on_delete = :CASCADE)
            Meta(table = "cp_note", app_label = "migcomp")
        end
        @test_throws ArgumentError quiet(() -> makemigrations(app = "migcomp", questioner = _ -> false))
        Juango.unregister_model!(CpNote)
        quiet(() -> migrate(app = "migcomp", target = "zero"))
        @test !Juango.table_exists(Juango.backend(), "cp_line")
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migcomp", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "squashmigrations and historical models" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migsq" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    M = Juango.Migrations
    mm() = basename(only(quiet(() -> makemigrations(app = "migsq", questioner = _ -> false))))
    unreg() = foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migsq", Juango.all_models()))
    applied() = sort([k[2] for k in M.applied_migrations() if k[1] == "migsq"])
    try
        @eval @model struct SqA
            name = CharField(max_length = 20)
            Meta(table = "sq_a", app_label = "migsq")
        end
        f1 = mm()
        unreg()
        @eval @model struct SqA2
            name = CharField(max_length = 20)
            rank = IntegerField(default = 0)
            Meta(table = "sq_a", name = "SqA", app_label = "migsq")
        end
        @eval @model struct SqB
            label = CharField(max_length = 10)
            a = ForeignKey(SqA2, on_delete = :CASCADE)
            Meta(table = "sq_b", app_label = "migsq")
        end
        f2 = mm()
        unreg()
        @eval @model struct SqA3
            name = CharField(max_length = 20)
            rank = IntegerField(default = 0)
            Meta(table = "sq_a", name = "SqA", app_label = "migsq")
        end
        @eval @model struct SqB3
            label = CharField(max_length = 40)
            a = ForeignKey(SqA3, on_delete = :CASCADE)
            Meta(table = "sq_b", name = "SqB", app_label = "migsq")
        end
        f3 = mm()
        n1, n3 = f1[1:end-3], f3[1:end-3]
        quiet(() -> migrate(app = "migsq", target = n1))

        # squash 0001..0003: both tables were created in the range, so it is two CreateModels
        p = quiet(() -> squashmigrations("migsq", n3))
        src = read(p, String)
        @test basename(p) == "0001_squashed_$n3.jl"
        @test occursin("replaces = [(\"migsq\", \"$n1\"), (\"migsq\", \"$(f2[1:end-3])\"), (\"migsq\", \"$n3\")]", src)
        @test count("CreateModel(", src) == 2 && !occursin("AddField", src) && !occursin("AlterField", src)
        @test occursin("Column(\"label\", :string; max_length = 40)", src) && occursin("initial = true", src)
        sq = basename(p)[1:end-3]

        # this database applied only the first original: it carries on with the originals
        @test !haskey(M.build_graph(["migsq"]).nodes, ("migsq", sq))
        quiet(() -> migrate())
        @test applied() == sort([n1, f2[1:end-3], n3])
        quiet(() -> migrate())                                  # now all originals ran: the squashed one counts as applied
        @test sq in applied()
        @test haskey(M.build_graph(["migsq"]).nodes, ("migsq", sq)) && !haskey(M.build_graph(["migsq"]).nodes, ("migsq", n1))
        # a fresh database uses the squashed migration only
        quiet(() -> migrate(app = "migsq", target = "zero"))
        @test isempty(applied()) && !Juango.table_exists(Juango.backend(), "sq_a")
        quiet(() -> migrate())
        @test applied() == sort([sq, n1, f2[1:end-3], n3])
        @test Set(Juango.table_columns(Juango.backend(), "sq_b")) == Set(["id", "label", "a_id"])
        @test_throws M.MigrationError squashmigrations("migsq", n1)

        # a data migration that uses historical models; it depends on an original, which is remapped
        create(SqA3; name = "four"); create(SqA3; name = "sixsix")
        write(joinpath(dir, "0004_fill.jl"), """
            using Juango.Migrations
            Migration(dependencies = [("migsq", "$n3")], operations = [
                RunJulia(apps -> begin
                             A = get_model(apps, "migsq", "SqA")
                             for r in objects(A)
                                 r.rank = length(r.name)
                                 save!(r)
                             end
                             create(A; name = "hist")
                             @assert count(A) == 3 && count(A; rank__gt = 4) == 1
                             @assert get(A; name = "four").rank == 4 && length(filter(A; name__in = ["four", "nope"])) == 1
                         end,
                         apps -> update!(get_model(apps, "migsq", "SqA"), (; rank__gt = 0); rank = 0)),
            ])
            """)
        @test M.build_graph(["migsq"]).nodes[("migsq", "0004_fill")].dependencies == [("migsq", sq)]
        quiet(() -> migrate())
        @test sort([(a.name, a.rank) for a in objects(SqA3)]) == [("four", 4), ("hist", 0), ("sixsix", 6)]
        quiet(() -> migrate(app = "migsq", target = sq))
        @test all(a -> a.rank == 0, objects(SqA3))
        bad = Juango.HistoricalApps(M.replay(M.build_graph(["migsq"]), keys(M.build_graph(["migsq"]).nodes)))
        @test_throws ArgumentError get_model(bad, "migsq", "SqA") |> objects |> first |> (r -> r.nope)
        @test_throws Juango.LookupError get_model(bad, "migsq", "Nope")
        quiet(() -> migrate(app = "migsq", target = "zero"))
    finally
        unreg()
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@testset "migrations: foreign keys to the user model are swappable" begin
    dir = mktempdir()
    configure!(MIGRATION_MODULES = Dict("migusr" => dir))
    quiet(f) = redirect_stdout(f, devnull)
    try
        @eval @model struct UsNote
            owner = ForeignKey(USER_MODEL, on_delete = :CASCADE)
            text = CharField(max_length = 20)
            Meta(table = "us_note", app_label = "migusr")
        end
        src = read(only(quiet(() -> makemigrations(app = "migusr", questioner = _ -> false))), String)
        @test occursin("references = \"__user_model__\"", src) && occursin("(\"__user_model__\", \"__first__\")", src)
        g = Juango.Migrations.build_graph(["auth", "contenttypes", "migusr"])
        n = only([m for m in values(g.nodes) if m.app == "migusr"])
        @test ("auth", "0001_initial") in n.dependencies
        quiet(() -> migrate())
        note = create(UsNote; owner = root_user(), text = "hi")
        @test get(UsNote; id = note.id).owner.username == "root"
        quiet(() -> migrate(app = "migusr", target = "zero"))
    finally
        foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "migusr", Juango.all_models()))
        configure!(MIGRATION_MODULES = Dict{String,String}())
    end
end

@model struct SwapMember <: AbstractUser
    Meta(table = "swap_member", app_label = "project")
end

@testset "migrations: a swapped user model's tables aren't created" begin
    sqls(; kw...) = join(filter(x -> x isa AbstractString, Juango.Migrations.migration_actions(
        Juango.Migrations.build_graph(["auth", "contenttypes"]), ("auth", "0001_initial"); kw...)), "\n")
    @test occursin("auth_user", sqls()) && occursin("auth_user_groups", sqls())
    try
        configure!(AUTH_USER_MODEL = SwapMember)
        @test Juango.Migrations.swapped_tables() == Set(["auth_user", "auth_user_groups", "auth_user_user_permissions"])
        for s in (sqls(), sqls(backwards = true))
            @test occursin("auth_group", s) && !occursin("auth_user", s)
        end
        g = Juango.Migrations.build_graph(["auth", "contenttypes"])
        @test haskey(Juango.Migrations.replay(g, keys(g.nodes)), "auth_user")      # still in the migration state
    finally
        configure!(AUTH_USER_MODEL = User)
    end
end

@testset "pre_migrate and post_migrate signals" begin
    seen = Tuple{Symbol,String,Any}[]
    pre = (s; app_label, database, plan, apps, kw...) -> push!(seen, (:pre, app_label, (database, apps)))
    post = (s; app_label, database, plan, apps, kw...) -> push!(seen, (:post, app_label, (database, apps)))
    connect!(pre_migrate, pre; dispatch_uid = :test_pre)
    connect!(post_migrate, post; sender = "auth", dispatch_uid = :test_post)
    try
        redirect_stdout(() -> migrate(), devnull)
        pres = [x[2] for x in seen if x[1] === :pre]
        @test pres[1:3] == ["contenttypes", "auth", "sites"] && "project" in pres
        @test [x[2] for x in seen if x[1] === :post] == ["auth"]                 # sender filter
        @test all(x -> x[3][1] == "default" && x[3][2] isa Juango.HistoricalApps, seen)
        @test findlast(x -> x[1] === :pre, seen) < findfirst(x -> x[1] === :post, seen)
        # the built-in receiver still creates permissions for new models
        @test exists(filter(Juango.Permission; codename = "add_article"))
    finally
        disconnect!(pre_migrate; dispatch_uid = :test_pre)
        disconnect!(post_migrate; dispatch_uid = :test_post, sender = "auth")
    end
end
