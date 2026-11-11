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
