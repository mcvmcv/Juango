# Django's multiple_database tests, ported (#227): QueryTestCase (part).
# julia --project=test test/django_multiple_database.jl   (see setup.jl)
#
# The "other" database is an SQLite file next to the default one (any backend). Juango's errors for objects of
# two databases are ArgumentErrors; the messages are compared where Juango's say the same thing.
# Not translated: test_refresh_router_instance_hint (Mock), test_db_selection's db_manager, the
# router, signal and fixture classes (later), and the pickling test.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Dates

@model struct DmdPerson
    name = CharField(max_length = 100, unique = true)
    Meta(table = "dmd_person", ordering = [:name])
end
Base.string(p::DmdPerson) = p.name
@model struct DmdBook
    title = CharField(max_length = 100)
    published = DateField()
    authors = ManyToManyField(DmdPerson)
    editor = ForeignKey(DmdPerson; on_delete = :SET_NULL, null = true, related_name = :edited)
    pages = IntegerField(default = 100)
    Meta(table = "dmd_book", ordering = [:title])
end
Base.string(b::DmdBook) = b.title
@model struct DmdPet
    name = CharField(max_length = 100)
    owner = ForeignKey(DmdPerson; on_delete = :CASCADE)
    Meta(table = "dmd_pet", ordering = [:name])
end
const DMD_MODELS = Any[DmdPerson, DmdBook, through(DmdBook, :authors), DmdPet]
redirect_stdout(devnull) do
    Juango.sync_models!(DMD_MODELS); append!(PORT_MODELS, DMD_MODELS)
end

const DMD_OTHER = joinpath(mktempdir(), "dmd_other.sqlite3")
# Run `f` with the "other" database configured, and its tables emptied afterwards (the default's too, as port_block)
function dmd_block(f)
    old = get(settings, :DATABASES, nothing)
    configure!(DATABASES = Dict("default" => settings.DATABASE, "other" => DMD_OTHER))
    try
        using_db(() -> redirect_stdout(() -> Juango.sync_models!(DMD_MODELS), devnull), "other")
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
