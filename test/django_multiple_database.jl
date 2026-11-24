# Django's multiple_database tests, ported (#227): QueryTestCase (part) and RouterTestCase (part).
# julia --project=test test/django_multiple_database.jl   (see setup.jl)
#
# The "other" database is an SQLite file next to the default one (any backend). Juango's errors for objects of
# two databases are ArgumentErrors; the messages are compared where Juango's say the same thing.
# Juango's routers get Django's instance hint in their three-argument form. Not translated: test_refresh_router_instance_hint
# (Mock), db_manager (using_db), str(qs.query), MigrateTestCase
# (migrate --database with routers is in db.jl), RouterModelArgumentTestCase (models are types), and the pickling test. Signals carry Django's `using` as `database`.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Dates

@model struct DmdPerson
    name = CharField(max_length = 100, unique = true)
    Meta(table = "dmd_person", app_label = "multiple_database", ordering = [:name])
end
Base.string(p::DmdPerson) = p.name
Juango.natural_key(p::DmdPerson) = (p.name,)
Juango.get_by_natural_key(::Type{DmdPerson}, name) = get(DmdPerson; name = name)
@model struct DmdReview
    source = CharField(max_length = 100)
    content_type = ForeignKey(Juango.ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    Meta(table = "dmd_review", ordering = [:source])
end
@model struct DmdBook
    reviews = GenericRelation(:DmdReview)
    title = CharField(max_length = 100)
    published = DateField()
    authors = ManyToManyField(DmdPerson)
    editor = ForeignKey(DmdPerson; on_delete = :SET_NULL, null = true, related_name = :edited)
    pages = IntegerField(default = 100)
    Meta(table = "dmd_book", app_label = "multiple_database", ordering = [:title])
end
Base.string(b::DmdBook) = b.title
@model struct DmdPet
    name = CharField(max_length = 100)
    owner = ForeignKey(DmdPerson; on_delete = :CASCADE)
    Meta(table = "dmd_pet", app_label = "multiple_database", ordering = [:name])
end
@model struct DmdAccount
    username = CharField(max_length = 150, unique = true)
    Meta(table = "dmd_account", ordering = [:username])
end
Base.string(a::DmdAccount) = a.username
@model struct DmdProfile
    account = OneToOneField(DmdAccount; on_delete = :SET_NULL, null = true)
    flavor = CharField(max_length = 100)
    Meta(table = "dmd_profile", ordering = [:flavor])
end
Base.string(p::DmdProfile) = p.flavor
const DMD_MODELS = Any[DmdPerson, DmdBook, through(DmdBook, :authors), DmdPet, DmdReview, DmdAccount, DmdProfile]
redirect_stdout(devnull) do
    Juango.sync_models!(DMD_MODELS); append!(PORT_MODELS, DMD_MODELS)
end

const DMD_OTHER = joinpath(mktempdir(), "dmd_other.sqlite3")
# Run `f` with the "other" database configured, and its tables emptied afterwards (the default's too, as port_block)
function dmd_block(f)
    old = get(settings, :DATABASES, nothing)
    configure!(DATABASES = Dict("default" => settings.DATABASE, "other" => DMD_OTHER))
    try
        using_db(() -> redirect_stdout(() -> Juango.sync_models!(vcat(Any[Juango.ContentType], DMD_MODELS)), devnull), "other")
        port_block(f)
    finally
        using_db("other") do
            atomic(db = "other") do
                foreach(T -> execute("DELETE FROM " * Juango.qname(Juango.modelmeta(T).table)), reverse(DMD_MODELS))
            end
        end
        configure!(DATABASES = old)
    end
end
dmd_titles(qs) = collect(values_list(qs, :title; flat = true))

@testset "django multiple_database: QueryTestCase" begin
  dmd_block() do
    B, P = DmdBook, DmdPerson
    # test_db_selection
    @test objects(B).db === nothing && using_db(objects(B), "other").db == "other"
    # test_default_creation
    create(B; title = "Pro Django", published = Date(2008, 12, 16))
    dive = B(); dive.title = "Dive into Python"; dive.published = Date(2009, 5, 4); save!(dive)
    for t in ("Pro Django", "Dive into Python")
        @test get(B; title = t) isa B && get(using_db(B, "default"); title = t) isa B
        @test_throws Juango.DoesNotExist get(using_db(B, "other"); title = t)
    end
    delete!(objects(B))
    # test_other_creation
    using_db(() -> create(B; title = "Pro Django", published = Date(2008, 12, 16)), "other")
    dive = B(); dive.title = "Dive into Python"; dive.published = Date(2009, 5, 4); save!(dive; db = "other")
    for t in ("Pro Django", "Dive into Python")
        @test get(using_db(B, "other"); title = t) isa B
        @test_throws Juango.DoesNotExist get(B; title = t)
        @test_throws Juango.DoesNotExist get(using_db(B, "default"); title = t)
    end
    # test_refresh
    dive2 = get(using_db(B, "other"); title = "Dive into Python")
    dive2.title = "Dive into Python (on default)"; save!(dive2; db = "default")
    refresh!(dive)
    @test dive.title == "Dive into Python"
    refresh!(dive; db = "default")
    @test dive.title == "Dive into Python (on default)" && Juango.instance_db(dive) == "default"
    delete!(objects(B))
    # test_basic_queries
    delete!(objects(B)); delete!(using_db(objects(B), "other"))
    using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
    O = using_db(B, "other")
    for kw in ((published = Date(2009, 5, 4),), (title__icontains = "dive",), (title__iexact = "dive INTO python",), (published__year = 2009,))
        @test get(O; kw...).title == "Dive into Python"
        @test_throws Juango.DoesNotExist get(using_db(B, "default"); kw...)
    end
    @test [Dates.year(d) for d in dates(O, :published, :year)] == [2009] && isempty(dates(using_db(B, "default"), :published, :year))
    @test [Dates.month(d) for d in dates(O, :published, :month)] == [5] && isempty(dates(using_db(B, "default"), :published, :month))
  end
  dmd_block() do
    B, P = DmdBook, DmdPerson
    # test_m2m_separation
    pro = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    marty = create(P; name = "Marty Alchin")
    dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
    mark = using_db(() -> create(P; name = "Mark Pilgrim"), "other")
    set!(pro.authors, [marty]); set!(dive.authors, [mark])
    TH = through(B, :authors)
    @test count(using_db(objects(TH), "default")) == 1 && count(using_db(objects(TH), "other")) == 1
    @test dmd_titles(filter(using_db(B, "default"); authors__name = "Marty Alchin")) == ["Pro Django"]
    @test isempty(dmd_titles(filter(using_db(B, "other"); authors__name = "Marty Alchin")))
    @test isempty(dmd_titles(filter(using_db(B, "default"); authors__name = "Mark Pilgrim")))
    @test dmd_titles(filter(using_db(B, "other"); authors__name = "Mark Pilgrim")) == ["Dive into Python"]
    dive = get(using_db(B, "other"); title = "Dive into Python"); mark = get(using_db(P, "other"); name = "Mark Pilgrim")
    @test collect(values_list(dive.authors, :name; flat = true)) == ["Mark Pilgrim"]          # (database-bound)
    @test dmd_titles(mark.dmdbook_set) == ["Dive into Python"]
    # test_m2m_cross_database_protection
    @test_throws ArgumentError("Cannot assign \"<DmdPerson: Marty Alchin>\": the current database router prevents this relation.") atomic(() -> set!(marty.edited, [pro, dive]))
    msg = "Cannot add \"<DmdBook: Dive into Python>\": instance is on database \"default\", value is on database \"other\""
    @test_throws ArgumentError(msg) atomic(() -> add!(marty.dmdbook_set, dive))
    @test_throws ArgumentError(msg) atomic(() -> set!(marty.dmdbook_set, [pro, dive]))
    msg = "Cannot add \"<DmdPerson: Marty Alchin>\": instance is on database \"other\", value is on database \"default\""
    @test_throws ArgumentError(msg) atomic(() -> add!(dive.authors, marty); db = "other")
    @test_throws ArgumentError(msg) atomic(() -> set!(dive.authors, [mark, marty]); db = "other")
  end
  dmd_block() do
    B, P = DmdBook, DmdPerson
    names(qs) = collect(values_list(qs, :name; flat = true))
    # test_foreign_key_separation
    pro = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    george = create(P; name = "George Vilches")
    dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
    chris = using_db(() -> create(P; name = "Chris Mills"), "other")
    pro.editor = george; save!(pro)
    dive.editor = chris; save!(dive)
    @test get(using_db(B, "default"); title = "Pro Django").editor.name == "George Vilches"
    @test get(using_db(B, "other"); title = "Dive into Python").editor.name == "Chris Mills"
    @test names(filter(using_db(P, "default"); edited__title = "Pro Django")) == ["George Vilches"]
    @test isempty(names(filter(using_db(P, "other"); edited__title = "Pro Django")))
    @test isempty(names(filter(using_db(P, "default"); edited__title = "Dive into Python")))
    @test names(filter(using_db(P, "other"); edited__title = "Dive into Python")) == ["Chris Mills"]
    chris = get(using_db(P, "other"); name = "Chris Mills")
    @test dmd_titles(chris.edited) == ["Dive into Python"]
    # test_foreign_key_reverse_operations
    html5 = using_db(() -> create(B; title = "Dive into HTML5", published = Date(2010, 3, 15)), "other")
    ed(t) = names(filter(using_db(P, "other"); edited__title = t))
    @test isempty(ed("Dive into HTML5"))
    add!(chris.edited, html5)
    @test ed("Dive into HTML5") == ["Chris Mills"] && ed("Dive into Python") == ["Chris Mills"]
    remove!(chris.edited, html5)
    @test isempty(ed("Dive into HTML5")) && ed("Dive into Python") == ["Chris Mills"]
    clear!(chris.edited)
    @test isempty(ed("Dive into HTML5")) && isempty(ed("Dive into Python"))
    create(chris.edited; title = "Dive into Water", published = Date(2010, 3, 15))
    @test ed("Dive into Water") == ["Chris Mills"] && isempty(ed("Dive into HTML5"))
    @test count(using_db(objects(B), "other")) == 3 && count(objects(B)) == 1     # (made on chris's database)
    # test_foreign_key_cross_database_protection
    marty = create(P; name = "Marty Alchin")
    msg = "Cannot assign \"<DmdPerson: Marty Alchin>\": the current database router prevents this relation."
    @test_throws ArgumentError(msg) (dive.editor = marty)
    @test_throws ArgumentError(msg) atomic(() -> set!(marty.edited, [pro, dive]))
    @test_throws ArgumentError(msg) atomic(() -> add!(marty.edited, dive))
  end
  dmd_block() do
    B, P = DmdBook, DmdPerson
    # test_foreign_key_deletion: the cascade runs on the right database
    mark = using_db(() -> create(P; name = "Mark Pilgrim"), "other")
    using_db(() -> create(DmdPet; name = "Fido", owner = mark), "other")
    cnt(T, d) = count(using_db(objects(T), d))
    @test (cnt(P, "default"), cnt(DmdPet, "default"), cnt(P, "other"), cnt(DmdPet, "other")) == (0, 0, 1, 1)
    delete!(mark; db = "other")
    @test (cnt(P, "default"), cnt(DmdPet, "default"), cnt(P, "other"), cnt(DmdPet, "other")) == (0, 0, 0, 0)
    # test_foreign_key_validation: the key's row is looked for on the object's database
    mickey = using_db(() -> create(P; name = "Mickey"), "other")
    pluto = using_db(() -> create(DmdPet; name = "Pluto", owner = mickey), "other")
    @test isempty(full_clean(pluto))
    # test_ordering: get_next_by_* stays on the object's database
    create(B; title = "Pro Django", published = Date(2008, 12, 16))
    dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
    learn = using_db(() -> create(B; title = "Learning Python", published = Date(2008, 7, 16)), "other")
    @test get_next_by(learn, :published).title == "Dive into Python"
    @test get_previous_by(dive, :published).title == "Learning Python"
    # test_raw
    @test [x.pk for x in collect(raw(B, "SELECT id FROM dmd_book WHERE title = 'Dive into Python'"; db = "other"))] == [dive.pk]
    # test_select_related: the related object remembers its database
    m2 = using_db(() -> create(P; name = "Mark Pilgrim"), "other")
    using_db(() -> create(B; title = "Dive into HTML5", published = Date(2009, 5, 4), editor = m2), "other")
    book = get(select_related(using_db(B, "other"), :editor); title = "Dive into HTML5")
    @test Juango.instance_db(book.editor) == "other"
    # test_subquery: a queryset of another database isn't a subquery
    sub = filter(using_db(P, "other"); name = "fff")
    @test_throws ArgumentError("Subqueries aren't allowed across different databases. Force the inner query to be evaluated using `list(inner_query)`.") collect(filter(B; editor__in = sub))
    # test_related_manager: create and get_or_create through the relation, on its database
    mark = get(using_db(P, "other"); name = "Mark Pilgrim")
    create(mark.dmdbook_set; title = "Dive into Python 2", published = Date(2009, 5, 4))
    get_or_create(mark.dmdbook_set; title = "Dive into Python 2", published = Date(2009, 5, 4))
    create(mark.edited; title = "Dive into Water", published = Date(2009, 5, 4))
    get_or_create(mark.edited; title = "Dive into Water", published = Date(2009, 5, 4))
    @test count(filter(using_db(B, "other"); title__in = ["Dive into Python 2", "Dive into Water"])) == 2
  end
end

@testset "django multiple_database: QueryTestCase (one-to-one, generic keys)" begin
  dmd_block() do
    A, Pr = DmdAccount, DmdProfile
    flavors(d) = collect(values_list(using_db(objects(Pr), d), :flavor; flat = true))
    users(d) = collect(values_list(using_db(objects(A), d), :username; flat = true))
    # test_o2o_separation
    alice = using_db(() -> create(A; username = "alice"), "default")
    using_db(() -> create(Pr; account = alice, flavor = "chocolate"), "default")
    bob = using_db(() -> create(A; username = "bob"), "other")
    using_db(() -> create(Pr; account = bob, flavor = "crunchy frog"), "other")
    @test get(using_db(A, "default"); username = "alice").dmdprofile.flavor == "chocolate"
    @test get(using_db(A, "other"); username = "bob").dmdprofile.flavor == "crunchy frog"
    un(d, fl) = collect(values_list(filter(using_db(A, d); dmdprofile__flavor = fl), :username; flat = true))
    @test un("default", "chocolate") == ["alice"] && isempty(un("other", "chocolate"))
    @test isempty(un("default", "crunchy frog")) && un("other", "crunchy frog") == ["bob"]
    @test get(using_db(Pr, "default"); flavor = "chocolate").account.username == "alice"
    @test get(using_db(Pr, "other"); flavor = "crunchy frog").account.username == "bob"
  end
  dmd_block() do
    A, Pr = DmdAccount, DmdProfile
    flavors(d) = collect(values_list(using_db(objects(Pr), d), :flavor; flat = true))
    users(d) = sort(collect(values_list(using_db(objects(A), d), :username; flat = true)))
    # test_o2o_cross_database_protection
    alice = using_db(() -> create(A; username = "alice"), "default")
    bob = using_db(() -> create(A; username = "bob"), "other")
    alice_profile = using_db(() -> create(Pr; account = alice, flavor = "chocolate"), "default")
    @test_throws ArgumentError (bob.dmdprofile = alice_profile)
    bob_profile = using_db(() -> create(Pr; account = bob, flavor = "crunchy frog"), "other")
    new_bob_profile = Pr(; flavor = "spring surprise")
    charlie = A(; username = "charlie")
    @test Juango.instance_db(new_bob_profile) === nothing && Juango.instance_db(charlie) === nothing
    new_bob_profile.account = bob
    charlie.dmdprofile = bob_profile
    @test Juango.instance_db(new_bob_profile) == "other" && Juango.instance_db(charlie) == "other"     # (they take bob's database)
    @test users("other") == ["bob"] && flavors("other") == ["crunchy frog"]
    save!(charlie); save!(bob_profile); save!(new_bob_profile)
    @test users("default") == ["alice"] && users("other") == ["bob", "charlie"]
    @test flavors("default") == ["chocolate"] && flavors("other") == ["crunchy frog", "spring surprise"]
    denise = using_db(() -> create(A; username = "denise"), "other")
    denise_profile = Pr(; flavor = "tofu", account = denise)
    @test Juango.instance_db(denise_profile) == "other"
    save!(denise_profile)
    @test flavors("default") == ["chocolate"] && flavors("other") == ["crunchy frog", "spring surprise", "tofu"]
  end
  dmd_block() do
    B, R = DmdBook, DmdReview
    # test_generic_key_separation
    pro = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    create(R; source = "Python Monthly", content_object = pro)
    dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
    using_db(() -> create(R; source = "Python Weekly", content_object = dive), "other")
    @test get(using_db(R, "default"); source = "Python Monthly").content_object.title == "Pro Django"
    @test get(using_db(R, "other"); source = "Python Weekly").content_object.title == "Dive into Python"
    dive = get(using_db(B, "other"); title = "Dive into Python")
    @test collect(values_list(dive.reviews, :source; flat = true)) == ["Python Weekly"]
  end
end

# --- routers.py ---------------------------------------------------------------------------------------------------
"Vaguely like primary/replica: reads from other, writes to default (the databases don't propagate changes)."
struct DmdTestRouter end
Juango.db_for_read(::DmdTestRouter, T) = "other"
# (Django's: told an object, reads stay on its database)
Juango.db_for_read(::DmdTestRouter, T, hints) = haskey(hints, :instance) ? something(Juango.instance_db(hints.instance), "other") : "other"
Juango.db_for_write(::DmdTestRouter, T) = "default"
Juango.allow_relation(::DmdTestRouter, a, b) = true
Juango.allow_migrate(::DmdTestRouter, db, app; model = nothing) = true
"Every operation on auth's models: reads from default, writes to other, migrations only on other."
struct DmdAuthRouter end
Juango.db_for_read(::DmdAuthRouter, T) = Juango.modelmeta(T).app == "auth" ? "default" : nothing
Juango.db_for_write(::DmdAuthRouter, T) = Juango.modelmeta(T).app == "auth" ? "other" : nothing
Juango.allow_relation(::DmdAuthRouter, a, b) = Juango.modelmeta(typeof(a)).app == "auth" || Juango.modelmeta(typeof(b)).app == "auth" || nothing
Juango.allow_migrate(::DmdAuthRouter, db, app; model = nothing) = app == "auth" ? db == "other" : nothing
"An opinion on writes only."
struct DmdWriteRouter end
Juango.db_for_write(::DmdWriteRouter, T) = "writer"

@testset "django multiple_database: RouterTestCase" begin
  dmd_block() do
    B, P = DmdBook, DmdPerson
    app(T) = Juango.modelmeta(T).app
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_migrate_selection
        for d in ("default", "other"), T in (User, B)
            @test Juango.migrate_allowed(d, app(T); model = T)
        end
        override_settings(DATABASE_ROUTERS = Any[DmdTestRouter(), DmdAuthRouter()]) do      # (TestRouter answers first)
            @test Juango.migrate_allowed("default", app(User); model = User) && Juango.migrate_allowed("other", app(User); model = User)
        end
        override_settings(DATABASE_ROUTERS = Any[DmdAuthRouter(), DmdTestRouter()]) do
            @test !Juango.migrate_allowed("default", app(User); model = User) && Juango.migrate_allowed("default", app(B); model = B)
            @test Juango.migrate_allowed("other", app(User); model = User) && Juango.migrate_allowed("other", app(B); model = B)
        end
        # test_partial_router
        dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
        @test Juango.route_read(User) == "other" && Juango.route_read(B) == "other"
        @test Juango.route_write(User) == "default" && Juango.route_write(B) == "default"
        @test Juango.ask_routers(Juango.allow_relation, dive, dive) === true
        override_settings(DATABASE_ROUTERS = Any[DmdWriteRouter(), DmdAuthRouter(), DmdTestRouter()]) do
            @test Juango.route_read(User) == "default" && Juango.route_read(B) == "other"
            @test Juango.route_write(User) == "writer" && Juango.route_write(B) == "writer"
            @test !Juango.migrate_allowed("default", app(User); model = User) && Juango.migrate_allowed("default", app(B); model = B)
        end
        delete!(using_db(objects(B), "other"))
        # test_db_selection / test_database_routing: reads go to other, writes (update, delete, get_or_create's get) to default
        marty = using_db(() -> create(P; name = "Marty Alchin"), "default")
        pro = using_db(() -> create(B; title = "Pro Django", published = Date(2008, 12, 16), editor = marty), "default")
        set!(pro.authors, [marty])
        using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
        update!(filter(B; title = "Pro Django"); pages = 200)
        @test_throws Juango.DoesNotExist get(B; title = "Pro Django")                     # (read on other)
        pro = get(using_db(B, "default"); title = "Pro Django")
        @test pro.pages == 200
        update!(filter(using_db(B, "other"); title = "Dive into Python"); pages = 300)
        @test get(B; title = "Dive into Python").pages == 300
        # related objects stay on the object's database, whatever the router says
        @test collect(values_list(pro.authors, :name; flat = true)) == ["Marty Alchin"] && pro.editor.name == "Marty Alchin"
        # get_or_create looks on the write database
        book, created = get_or_create(B; title = "Pro Django")
        @test !created
        book, created = get_or_create(B; title = "Dive Into Python", defaults = Dict(:published => Date(2009, 5, 4)))
        @test created
        @test count(using_db(objects(B), "default")) == 2 && count(using_db(objects(B), "other")) == 1
        @test count(objects(B)) == 1                                                           # (the read database)
        delete!(filter(B; pages__gt = 150))                                                    # (on the write database)
        @test count(using_db(objects(B), "default")) == 1 && count(using_db(objects(B), "other")) == 1
    end
  end
end

@testset "django multiple_database: RouterTestCase (cross-database protection)" begin
  dmd_block() do
    B, P, R = DmdBook, DmdPerson, DmdReview
    db(x) = Juango.instance_db(x)
    T = through(B, :authors)
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_foreign_key_cross_database_protection: allowed, and the object is saved on the write database
        pro = using_db(() -> create(B; title = "Pro Django", published = Date(2008, 12, 16)), "default")
        marty = using_db(() -> create(P; name = "Marty Alchin"), "default")
        dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
        mark = using_db(() -> create(P; name = "Mark Pilgrim"), "other")
        dive.editor = marty
        @test (db(marty), db(pro), db(dive), db(mark)) == ("default", "default", "other", "other")
        save!(dive)
        @test db(dive) == "default"
        delete!(get(using_db(B, "default"); title = "Dive into Python"))
        dive = get(using_db(B, "other"); title = "Dive into Python")
        @test db(dive) == "other"
        set!(marty.edited, [pro, dive]; bulk = false)
        @test (db(marty), db(pro), db(dive), db(mark)) == ("default", "default", "default", "other")
        delete!(get(using_db(B, "default"); title = "Dive into Python"))
        dive = get(using_db(B, "other"); title = "Dive into Python")
        add!(marty.edited, dive; bulk = false)
        @test (db(marty), db(pro), db(dive), db(mark)) == ("default", "default", "default", "other")
        delete!(get(using_db(B, "default"); title = "Dive into Python"))
        dive = get(using_db(B, "other"); title = "Dive into Python")
        # an unsaved object takes the routers' write database for the related object
        chris = P(name = "Chris Mills")
        html5 = B(title = "Dive into HTML5", published = Date(2010, 3, 15))
        @test db(chris) === nothing && db(html5) === nothing
        save!(chris)
        dive.editor = chris
        html5.editor = mark
        @test (db(dive), db(mark), db(chris), db(html5)) == ("other", "other", "default", "default")
        water = B(title = "Dive into Water", published = Date(2001, 1, 1), editor = mark)
        @test db(water) == "default"
        save!(mark; db = "default")
        save!(mark; db = "other")
        @test db(mark) == "other"
        # created through a relation: on the write database, even from an object of the read one
        cheesecake = create(mark.edited; title = "Dive into Cheesecake", published = Date(2010, 3, 15))
        @test db(cheesecake) == "default"
        cheesecake, created = get_or_create(mark.edited; title = "Dive into Cheesecake", published = Date(2010, 3, 15))
        @test db(cheesecake) == "default" && !created
        puddles, created = get_or_create(mark.edited; title = "Dive into Puddles", published = Date(2010, 3, 15))
        @test db(puddles) == "default" && created
    end
  end
  dmd_block() do
    B, P, R = DmdBook, DmdPerson, DmdReview
    db(x) = Juango.instance_db(x)
    T = through(B, :authors)
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_m2m_cross_database_protection: the join rows go to the write database
        pro = using_db(() -> create(B; id = 1, title = "Pro Django", published = Date(2008, 12, 16)), "other")
        marty = using_db(() -> create(P; id = 1, name = "Marty Alchin"), "other")
        dive = using_db(() -> create(B; id = 2, title = "Dive into Python", published = Date(2009, 5, 4)), "default")
        mark = using_db(() -> create(P; id = 2, name = "Mark Pilgrim"), "default")
        save!(pro; db = "default"); save!(marty; db = "default"); save!(dive; db = "other"); save!(mark; db = "other")
        @test count(using_db(objects(B), "default")) == 2 && count(using_db(objects(B), "other")) == 2
        @test count(using_db(objects(P), "default")) == 2 && count(using_db(objects(P), "other")) == 2
        nrows(d) = count(using_db(objects(T), d))
        states() = (db(marty), db(pro), db(dive), db(mark))
        set!(marty.dmdbook_set, [pro, dive])
        @test states() == ("default", "default", "other", "other")
        @test nrows("default") == 2 && nrows("other") == 0
        delete!(using_db(objects(T), "default"))
        add!(marty.dmdbook_set, dive)
        @test states() == ("default", "default", "other", "other")
        @test nrows("default") == 1 && nrows("other") == 0
        delete!(using_db(objects(T), "default"))
        set!(dive.authors, [mark, marty])
        @test states() == ("default", "default", "other", "other")
        @test nrows("default") == 2 && nrows("other") == 0
        delete!(using_db(objects(T), "default"))
        add!(dive.authors, marty)
        @test states() == ("default", "default", "other", "other")
        @test nrows("default") == 1 && nrows("other") == 0
        alice = create(dive.authors; name = "Alice", id = 3)
        @test db(alice) == "default"
        alice, created = get_or_create(dive.authors; name = "Alice")
        @test db(alice) == "default"
        bob, created = get_or_create(dive.authors; name = "Bob", defaults = Dict(:id => 4))
        @test db(bob) == "default"
    end
  end
  dmd_block() do
    B, P, R = DmdBook, DmdPerson, DmdReview
    db(x) = Juango.instance_db(x)
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_o2o_cross_database_protection
        alice = using_db(() -> create(DmdAccount; username = "alice"), "default")
        bob = using_db(() -> create(DmdAccount; username = "bob"), "other")
        alice_profile = create(DmdProfile; account = alice, flavor = "chocolate")
        bob.dmdprofile = alice_profile
        @test (db(alice), db(alice_profile), db(bob)) == ("default", "default", "other")
        save!(bob)
        @test db(bob) == "default"
    end
  end
  dmd_block() do
    B, P, R = DmdBook, DmdPerson, DmdReview
    db(x) = Juango.instance_db(x)
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_generic_key_cross_database_protection
        pro = using_db(() -> create(B; title = "Pro Django", published = Date(2008, 12, 16)), "default")
        review1 = using_db(() -> create(R; source = "Python Monthly", content_object = pro), "default")
        dive = using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4)), "other")
        review2 = using_db(() -> create(R; source = "Python Weekly", content_object = dive), "other")
        review1.content_object = dive
        @test (db(pro), db(review1), db(dive), db(review2)) == ("default", "default", "other", "other")
        save!(dive)
        @test db(review1) == "default" && db(dive) == "default"
        delete!(get(using_db(B, "default"); title = "Dive into Python"))
        dive = get(using_db(B, "other"); title = "Dive into Python")
        @test db(dive) == "other"
        add!(dive.reviews, review1)
        @test (db(pro), db(review1), db(dive), db(review2)) == ("default", "default", "other", "other")
        save!(dive)
        @test db(dive) == "default"
        delete!(get(using_db(B, "default"); title = "Dive into Python"))
        review3 = R(source = "Python Daily")
        @test db(review3) === nothing
        review3.content_object = dive
        @test db(review3) == "default"
        dive = get(using_db(B, "other"); title = "Dive into Python")
        nyt = create(dive.reviews; source = "New York Times", content_object = dive)
        @test db(nyt) == "default"
    end
  end
  dmd_block() do
    B, P, R = DmdBook, DmdPerson, DmdReview
    override_settings(DATABASE_ROUTERS = Any[DmdTestRouter()]) do
        # test_m2m_managers, test_foreign_key_managers, test_generic_key_managers (Django's db_manager: using_db)
        pro = using_db(() -> create(B; title = "Pro Django", published = Date(2008, 12, 16)), "other")
        marty = using_db(() -> create(P; name = "Marty Alchin"), "other")
        using_db(() -> create(R; source = "Python Monthly", content_object = pro), "other")
        for rel in (pro.authors, marty.dmdbook_set, marty.edited, pro.reviews)
            @test rel.db == "other" && using_db(rel, "default").db == "default"
        end
        # test_generic_key_subquery
        book = create(B; title = "Pro Django", published = Date(2008, 12, 16))
        @test isempty(collect(filter(R; pk__in = book.reviews)))
        # test_generic_relation_queryset_uses_instance_database
        @test book.reviews.db == "default"
        # test_subquery: the subquery follows the outer query to the read database
        mark = using_db(() -> create(P; name = "Mark Pilgrim"), "other")
        using_db(() -> create(B; title = "Dive into Python", published = Date(2009, 5, 4), editor = mark), "other")
        qs = filter(B; editor__in = filter(P; name = "Mark Pilgrim"))
        @test dmd_titles(qs) == ["Dive into Python"]
        # test_deferred_models
        mark_def = using_db(() -> create(P; name = "Mark Pilgrim"), "default")
        orig_b = get(using_db(B, "other"); title = "Dive into Python")
        b = get(only(using_db(B, "other"), :title); pk = orig_b.pk)
        @test b.published == Date(2009, 5, 4)
        b = get(only(using_db(B, "other"), :title); pk = orig_b.pk)
        b.editor = mark_def
        save!(b; db = "default")
        @test get(using_db(B, "default"); pk = b.pk).published == Date(2009, 5, 4)
    end
  end
end

"Pets on other only, everything else on default; an opinion on migrations only."
struct DmdAntiPetRouter end
Juango.allow_migrate(::DmdAntiPetRouter, db, app; model = nothing) = db == "other" ? model === DmdPet : model !== DmdPet
"Every write to other."
struct DmdWriteToOtherRouter end
Juango.db_for_write(::DmdWriteToOtherRouter, T) = "other"

@testset "django multiple_database: AuthTestCase, FixtureTestCase, SignalTests" begin
  dmd_block() do
    B, P = DmdBook, DmdPerson
    using_db(() -> redirect_stdout(() -> Juango.sync_models!(Any[Juango.Permission, Juango.Group, through(Juango.Group, :permissions), User, through(User, :groups), through(User, :user_permissions)]), devnull), "other")
    try
        override_settings(DATABASE_ROUTERS = Any[DmdAuthRouter()]) do
            # test_auth_manager: created on the router's write database, unless one is named
            create_user("dmd_alice"; email = "alice@example.com")
            using_db(() -> create_user("dmd_bob"; email = "bob@example.com"), "default")
            alice = get(using_db(User, "other"); username = "dmd_alice")
            @test alice.username == "dmd_alice" && Juango.instance_db(alice) == "other"
            @test_throws Juango.DoesNotExist get(using_db(User, "default"); username = "dmd_alice")
            bob = get(using_db(User, "default"); username = "dmd_bob")
            @test Juango.instance_db(bob) == "default"
            @test_throws Juango.DoesNotExist get(using_db(User, "other"); username = "dmd_bob")
            @test count(filter(using_db(User, "default"); username__startswith = "dmd_")) == 1
            @test count(filter(using_db(User, "other"); username__startswith = "dmd_")) == 1
            # test_dumpdata: allow_migrate keeps auth off default's dump
            out = IOBuffer()
            call_command("dumpdata", "auth.user", "--format=json", "--database=default"; stdout = out)
            @test strip(String(take!(out))) == "[]"
            call_command("dumpdata", "auth.user", "--format=json", "--database=other"; stdout = out)
            @test occursin("\"email\":\"alice@example.com\"", String(take!(out)))
        end
    finally
        using_db(() -> execute("DELETE FROM auth_user WHERE username LIKE 'dmd_%'"), "other")      # (no admin log there)
        delete!(filter(User; username__startswith = "dmd_"))
    end
    # FixtureTestCase: each database gets the common fixture and its own (name.<database>.json)
    override_settings(FIXTURE_DIRS = [joinpath(@__DIR__, "fixtures_multiple_database")]) do
        for d in ("default", "other")                           # (Django's setUpClass: before the router)
            loaddata("multidb-common", "multidb"; database = d)
        end
    end
    override_settings(DATABASE_ROUTERS = Any[DmdAntiPetRouter()],
                      FIXTURE_DIRS = [joinpath(@__DIR__, "fixtures_multiple_database")]) do
        # test_fixture_loading
        @test get(B; title = "Pro Django") isa B && get(using_db(B, "default"); title = "Pro Django") isa B
        @test_throws Juango.DoesNotExist get(using_db(B, "other"); title = "Pro Django")
        @test get(using_db(B, "other"); title = "Dive into Python") isa B
        @test_throws Juango.DoesNotExist get(B; title = "Dive into Python")
        @test_throws Juango.DoesNotExist get(using_db(B, "default"); title = "Dive into Python")
        for d in ("default", "other")
            @test get(using_db(B, d); title = "The Definitive Guide to Django") isa B
        end
        @test collect(values_list(get(using_db(B, "other"); title = "Dive into Python").authors, :name; flat = true)) == ["Mark Pilgrim"]
        # test_pseudo_empty_fixtures: objects the router keeps off the database aren't an error
        out = IOBuffer()
        call_command("loaddata", "pets"; stdout = out)
        @test strip(String(take!(out))) == "Installed 0 object(s) (of 2) from 1 fixture(s)"
        @test count(objects(DmdPet)) == 0
    end
    delete!(objects(B)); delete!(objects(P))
    # SignalTests: the signals name the database (Django's using, Juango's `database`)
    heard = Dict{Symbol,Any}()
    rec(name) = (sender; database = nothing, kw...) -> (heard[name] = database)
    recs = [(sig, rec(n)) for (sig, n) in ((pre_save, :pre_save), (post_save, :post_save), (pre_delete, :pre_delete), (post_delete, :post_delete))]
    foreach(((sig, r),) -> connect!(sig, r; sender = P), recs)
    mrec = rec(:m2m)
    connect!(m2m_changed, mrec)
    try
        # test_database_arg_save_and_delete
        p = create(P; name = "Darth Vader")
        save!(p)
        @test heard[:pre_save] == "default" && heard[:post_save] == "default"
        delete!(p)
        @test heard[:pre_delete] == "default" && heard[:post_delete] == "default"
        save!(p; db = "other")
        @test heard[:pre_save] == "other" && heard[:post_save] == "other"
        delete!(p; db = "other")
        @test heard[:pre_delete] == "other" && heard[:post_delete] == "other"
        # test_database_arg_m2m
        b = create(B; title = "Pro Django", published = Date(2008, 12, 16))
        p = create(P; name = "Marty Alchin")
        using_db(() -> create(B; id = b.id, title = b.title, published = b.published), "other")
        using_db(() -> create(P; id = p.id, name = p.name), "other")
        to_other(f) = override_settings(f, DATABASE_ROUTERS = Any[DmdWriteToOtherRouter()])
        add!(b.authors, p);                      @test heard[:m2m] == "default"
        to_other(() -> add!(b.authors, p));      @test heard[:m2m] == "other"
        remove!(b.authors, p);                   @test heard[:m2m] == "default"
        to_other(() -> remove!(b.authors, p));   @test heard[:m2m] == "other"
        add!(p.dmdbook_set, b);                  @test heard[:m2m] == "default"
        to_other(() -> add!(p.dmdbook_set, b));  @test heard[:m2m] == "other"
        clear!(b.authors);                       @test heard[:m2m] == "default"
        to_other(() -> clear!(b.authors));       @test heard[:m2m] == "other"
    finally
        foreach(((sig, r),) -> disconnect!(sig, r; sender = P), recs)
        disconnect!(m2m_changed, mrec)
    end
  end
end

"Raised by DmdWriteCheckRouter: what it was asked."
struct DmdRouterUsed <: Exception
    model::Any
    hints::Any
end
struct DmdWriteCheckRouter end
Juango.db_for_write(::DmdWriteCheckRouter, T, hints) = throw(DmdRouterUsed(T, hints))
"Django's AttributeErrorRouter: every read and write routing fails."
struct DmdFailingRouter end
struct DmdRouterFailed <: Exception end
Juango.db_for_read(::DmdFailingRouter, T) = throw(DmdRouterFailed())
Juango.db_for_write(::DmdFailingRouter, T) = throw(DmdRouterFailed())
struct DmdNoRelationRouter end
Juango.allow_relation(::DmdNoRelationRouter, a, b) = false

@testset "django multiple_database: RouteForWriteTestCase, RouterAttributeErrorTestCase, RelationAssignmentTests" begin
  dmd_block() do
    B, P, Pet = DmdBook, DmdPerson, DmdPet
    # RouteForWriteTestCase: writes ask db_for_write, told the object (Django's hints = {"instance": ...})
    function used(f)
        try
            override_settings(f, DATABASE_ROUTERS = Any[DmdWriteCheckRouter()])
        catch e
            e isa DmdRouterUsed && return e
            rethrow()
        end
        nothing
    end
    owner = create(P; name = "Someone")
    pet = create(Pet; name = "fido", owner = owner)
    e = used(() -> delete!(pet.owner))                                          # test_fk_delete
    @test e isa DmdRouterUsed && e.model === P && e.hints.instance === owner
    e = used(() -> delete!(owner.dmdpet_set))                                   # test_reverse_fk_delete
    @test e isa DmdRouterUsed && e.model === Pet && e.hints.instance === owner
    e = used(() -> get_or_create(owner.dmdpet_set; name = "fido"))              # test_reverse_fk_get_or_create
    @test e isa DmdRouterUsed && e.model === Pet && e.hints.instance === owner
    e = used(() -> update!(owner.dmdpet_set; name = "max"))                     # test_reverse_fk_update
    @test e isa DmdRouterUsed && e.model === Pet && e.hints.instance === owner
    auth = create(P; name = "Someone else")
    book = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    e = used(() -> add!(book.authors, auth))                                    # test_m2m_add
    @test e isa DmdRouterUsed && e.model === through(B, :authors) && e.hints.instance === book
    add!(book.authors, auth)
    e = used(() -> update!(auth.dmdbook_set; title = "Different"))
    @test e isa DmdRouterUsed && e.model === B && e.hints.instance === auth
    @test get(B; id = book.id).title == "Pro Django" && count(objects(Pet)) == 1
    delete!(objects(Pet)); delete!(objects(B)); delete!(objects(P))
    # RouterAttributeErrorTestCase: a router's error comes through
    failing(f) = override_settings(f, DATABASE_ROUTERS = Any[DmdFailingRouter()])
    b = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    @test_throws DmdRouterFailed failing(() -> get(B; pk = b.pk))                # test_attribute_error_read
    dive = B(); dive.title = "Dive into Python"; dive.published = Date(2009, 5, 4)
    @test_throws DmdRouterFailed failing(() -> save!(dive))                     # test_attribute_error_save
    p = create(P; name = "Marty Alchin")
    set!(b.authors, [p]); b.editor = p
    @test_throws DmdRouterFailed failing(() -> delete!(b))                      # test_attribute_error_delete
    delete!(objects(B)); delete!(objects(P))
    b = create(B; title = "Pro Django", published = Date(2008, 12, 16))
    p = create(P; name = "Marty Alchin")
    @test_throws DmdRouterFailed failing(() -> set!(b.authors, [p]))            # test_attribute_error_m2m
    @test isempty(collect(b.authors))
    # RelationAssignmentTests: allow_relation is asked about unsaved objects too
    override_settings(DATABASE_ROUTERS = Any[DmdNoRelationRouter()]) do
        person = P(name = "Someone"); pet = Pet()
        e = try; pet.owner = person; nothing; catch err; err; end               # test_foreign_key_relation
        @test e isa ArgumentError && occursin("the current database router prevents this relation", e.msg)
        account = DmdAccount(username = "Someone"); profile = DmdProfile()
        e = try; account.dmdprofile = profile; nothing; catch err; err; end     # test_reverse_one_to_one_relation
        @test e isa ArgumentError && occursin("the current database router prevents this relation", e.msg)
    end
  end
end
