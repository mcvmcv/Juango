# orm: julia --project=test test/orm.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "orm: basics" begin
    ann = ann_author()
    bob = create(Author; name = "Bob")
    @test ann.id isa Int && ann.pk == ann.id
    a1 = create(Article; title = "Julia rocks", body = "Fast & fun", author = ann, views = 10, published = true, status = "p")
    a2 = create(Article; title = "Django in Julia", body = "Batteries", author = ann, views = 5)
    a3 = create(Article; title = "Bob's post", author = bob, views = 1, rating = 4.5)
    @test a1.created isa DateTime && a1.updated isa DateTime
    @test count(Article) == 3
    @test [a.title for a in objects(Article)] == ["Bob's post", "Django in Julia", "Julia rocks"]   # Meta ordering -id
    @test [a.title for a in order_by(Article, "views")] == ["Bob's post", "Django in Julia", "Julia rocks"]
    @test objects(Article) |> order_by("-views") |> first == a1
    @test get(Article; title = "Julia rocks") == a1
    @test_throws DoesNotExist get(Article; title = "nope")
    @test_throws MultipleObjectsReturned get(Article; author = ann)
    @test count(filter(Article; title__icontains = "JULIA")) == 2
    @test count(filter(Article; title__contains = "julia")) == 0
    @test count(filter(Article; title__startswith = "Julia")) == 1
    @test count(filter(Article; title__endswith = "post")) == 1
    @test count(filter(Article; views__gte = 5)) == 2
    @test count(filter(Article; views__in = [1, 10])) == 2
    @test count(filter(Article; rating__isnull = true)) == 2
    @test count(filter(Article; author__name = "Ann")) == 2
    @test count(filter(Article; author__name__iexact = "bob")) == 1
    @test count(filter(Author; articles__views__gt = 8)) == 1          # reverse relation lookup
    @test count(filter(Article, Q(views = 1) | Q(published = true))) == 2
    @test count(filter(Article, !Q(author = ann))) == 1
    @test count(exclude(Article; author = ann)) == 1
    @test count(filter(Article; title__icontains = "100%")) == 0       # LIKE wildcard escaped
    @test exists(filter(Article; published = true)) && !exists(filter(Article; views = 999))
    @test isempty(none(Article)) && collect(none(Article)) == Article[]
    @test values_list(order_by(Article, "views"), :views; flat = true) == [1, 5, 10]
    @test aggregate(objects(Article), :sum, :views) == 16
    @test aggregate(filter(Article; author = ann), :max, :views) == 10
    @test length(order_by(Article, "views")[1:2]) == 2
    @test order_by(Article, "views")[2] == a2
    @test [a.title for a in order_by(Article, "views")[2:3]] == ["Django in Julia", "Julia rocks"]
    @test collect(values(filter(Article; id = a1.id), :title, :views)) == [Dict(:title => "Julia rocks", :views => 10)]
    @test count(filter(Article; created__year = year(now()))) == 3

    # FK access & reverse relations
    @test a1.author == ann && a1.author_id == ann.id && a1.author.name == "Ann"
    @test count(ann.articles) == 2
    @test a1.shout == "JULIA ROCKS"                                     # tattr-computed property

    # update / save
    a2.title = "Changed"
    save!(a2)
    @test get(Article; id = a2.id).title == "Changed"
    @test update!(filter(Article; author = ann); views = 0) == 2
    @test refresh!(a1).views == 0
    a1.author = bob
    save!(a1)
    @test count(bob.articles) == 2

    # get_or_create / update_or_create
    c, created = get_or_create(Author; name = "Cy", defaults = Dict(:email => "cy@x.io"))
    @test created && c.email == "cy@x.io"
    c2, created2 = get_or_create(Author; name = "Cy")
    @test !created2 && c2 == c
    c3, created3 = update_or_create(Author; name = "Cy", defaults = Dict(:email => "new@x.io"))
    @test !created3 && c3.email == "new@x.io"

    # validation
    bad = Article(title = "x"^60, author = ann, status = "z")
    errs = full_clean(bad)
    @test haskey(errs, :title) && haskey(errs, :status)
    @test haskey(full_clean(Author(name = "Ann")), :name)              # unique
    @test haskey(full_clean(Author(name = "Zed", email = "nope")), :email)
    @test_throws ArgumentError Article(nosuchfield = 1)

    # on_delete behaviours
    t = create(Tag; label = "t", article = a3)
    lk = create(Locked; article = a2)
    @test_throws ProtectedError delete!(a2)
    delete!(lk)
    delete!(a3)
    @test refresh!(t).article === nothing                               # SET_NULL
    n_before = count(Article)
    delete!(bob)                                                        # CASCADE
    @test count(Article) == n_before - 1
    @test delete!(filter(Tag; label = "t")) == 1

    # transactions
    try
        atomic() do
            create(Author; name = "Rollback")
            error("fail")
        end
    catch
    end
    @test !exists(filter(Author; name = "Rollback"))
    atomic(() -> create(Author; name = "Committed"))
    @test exists(filter(Author; name = "Committed"))

    # on_commit
    ran = String[]
    on_commit(() -> push!(ran, "now"))                                  # no transaction: at once
    @test ran == ["now"]
    atomic() do
        on_commit(() -> push!(ran, "outer"))
        @test ran == ["now"]
        try
            atomic() do
                on_commit(() -> push!(ran, "dropped"))
                error("inner fails")
            end
        catch
        end
        atomic(() -> on_commit(() -> push!(ran, "inner")))
        @test ran == ["now"]
    end
    @test ran == ["now", "outer", "inner"]
    try
        atomic() do
            on_commit(() -> push!(ran, "rolled back"))
            error("fail")
        end
    catch
    end
    @test length(ran) == 3
    atomic() do
        on_commit(() -> error("boom"); robust = true)
        on_commit(() -> push!(ran, "after robust"))
    end
    @test ran[end] == "after robust"
    rollback_after() do
        _, cbs = capture_on_commit_callbacks(execute = true) do
            on_commit(() -> push!(ran, "captured"))
        end
        @test length(cbs) == 1 && ran[end] == "captured"
    end
    @test !Juango.in_atomic()
end

@testset "async API" begin
    a = fetch(acreate(Author; name = "Async Ann"))
    @test a isa Author && a.id !== nothing
    t1, t2 = acount(filter(Author; name = "Async Ann")), aexists(filter(Author; name = "Nobody async"))
    @test t1 isa Task && fetch(t1) == 1 && fetch(t2) == false
    @test fetch(aget(Author; name = "Async Ann")) == a && fetch(afirst(filter(Author; name = "Async Ann"))) == a
    @test [x.name for x in fetch(acollect(filter(Author; name = "Async Ann")))] == ["Async Ann"]
    @test_throws DoesNotExist Juango.await_task(aget(Author; name = "Nobody async"))
    o, created = fetch(aget_or_create(Author; name = "Async Bob"))
    @test created && fetch(aupdate!(filter(Author; id = o.id); name = "Async Bobby")) == 1
    @test fetch(arefresh!(o)).name == "Async Bobby"
    @test [x.name for x in aiterator(filter(Author; name__startswith = "Async "); chunk_size = 1)] |> sort == ["Async Ann", "Async Bobby"]
    # inside a transaction it runs in the calling task, so it sees uncommitted rows
    rollback_after() do
        create(Author; name = "Async Tx")
        @test fetch(acount(filter(Author; name = "Async Tx"))) == 1
        @test length(collect(aiterator(filter(Author; name = "Async Tx")))) == 1
    end
    @test fetch(adelete!(filter(Author; name__startswith = "Async "))) >= 2
    add = sync_to_async((x, y) -> x + y)
    @test fetch(add(2, 3)) == 5
    @test Juango.to_response(run_async(() -> "from a task")).body == Vector{UInt8}("from a task")
end

@testset "relations: joins, select_related, prefetch_related" begin
    sel(qs) = Juango.select_sql(qs)[1]
    nq(f) = last(count_queries(f))
    A = create(Author; name = "Rel A")
    B = create(Author; name = "Rel B")
    C = create(Author; name = "Rel C")          # no articles
    a1 = create(Article; title = "rel-a1", author = A, published = true)
    a2 = create(Article; title = "rel-a2", author = A, published = false)
    b1 = create(Article; title = "rel-b1", author = B, published = true)
    t0 = create(Tag; label = "rel-none")
    tx = create(Tag; label = "rel-x", article = a1)
    ty = create(Tag; label = "rel-y", article = b1)
    rel = filter(Author; name__startswith = "Rel ")
    reltags = filter(Tag; label__startswith = "rel-")
    names(qs) = sort([x.name for x in qs])
    labels(qs) = sort([x.label for x in qs])

    # --- joins instead of IN subqueries ---------------------------------------------------
    @test occursin("INNER JOIN", sel(filter(Article; author__name = "Rel A"))) &&
          !occursin("IN (SELECT", sel(filter(Article; author__name = "Rel A")))
    @test occursin("LEFT OUTER JOIN", sel(filter(Tag; article__title = "rel-a1")))
    @test !occursin("JOIN", sel(filter(Article; author__id = A.id)))
    @test sort([x.title for x in filter(Article; author__name = "Rel A")]) == ["rel-a1", "rel-a2"]
    @test labels(filter(Tag; article__author__name = "Rel A")) == ["rel-x"]

    # reverse relations: DISTINCT, and the same-row rule within one filter() call
    @test occursin("SELECT DISTINCT", sel(filter(Author; articles__published = true)))
    @test names(filter(rel; articles__title__startswith = "rel-a")) == ["Rel A"]
    @test count(filter(rel; articles__title__startswith = "rel-a")) == 1
    @test isempty(filter(rel; articles__title = "rel-a2", articles__published = true))
    @test names(filter(filter(rel; articles__title = "rel-a2"); articles__published = true)) == ["Rel A"]
    @test names(filter(rel, Q(articles__title = "rel-a2") & Q(articles__published = true))) == String[]
    @test names(filter(rel; articles__isnull = true)) == ["Rel C"]
    @test names(filter(rel; articles__isnull = false)) == ["Rel A", "Rel B"]

    # negation uses EXISTS: rows without the related object survive an exclude
    @test labels(exclude(reltags; article__title = "rel-a1")) == ["rel-none", "rel-y"]
    @test names(exclude(rel; articles__published = false)) == ["Rel B", "Rel C"]
    @test labels(filter(reltags, !Q(article__author__name = "Rel B"))) == ["rel-none", "rel-x"]
    # OR across a nullable FK keeps rows whose FK is NULL
    @test labels(filter(reltags, Q(article__title = "rel-a1") | Q(label = "rel-none"))) == ["rel-none", "rel-x"]

    # ordering across a foreign key, also combined with DISTINCT
    @test [x.title for x in order_by(filter(Article; title__startswith = "rel-"), "-author__name", "title")] == ["rel-b1", "rel-a1", "rel-a2"]
    @test [x.name for x in order_by(filter(rel; articles__published = true), "name")] == ["Rel A", "Rel B"]
    @test [t.label for t in order_by(filter(reltags; article__isnull = false), "article__author__name")] == ["rel-x", "rel-y"]

    # counts, aggregates, updates and deletes over joined querysets
    @test aggregate(filter(Article; author__name = "Rel A"), :count, :id) == 2
    @test aggregate(filter(rel; articles__published = true), :count, :id) == 2
    @test update!(filter(Article; author__name = "Rel B"); views = 9) == 1 && get(Article; id = b1.id).views == 9
    @test count(filter(Article; id__in = filter(Article; author__name = "Rel A"))) == 2

    # --- select_related ---------------------------------------------------------------------
    arts, n = count_queries(() -> collect(select_related(filter(Article; title__startswith = "rel-"), :author)))
    @test n == 1 && length(arts) == 3
    @test nq(() -> [x.author.name for x in arts]) == 0
    tags, n = count_queries(() -> collect(order_by(select_related(reltags, :article__author), "label")))
    @test n == 1
    @test nq(() -> [t.article === nothing ? nothing : t.article.author.name for t in tags]) == 0
    @test [t.article === nothing ? nothing : t.article.author.name for t in tags] == [nothing, "Rel A", "Rel B"]
    @test occursin("LEFT OUTER JOIN", sel(select_related(reltags, :article)))
    @test_throws Juango.LookupError select_related(Author, :articles)
    @test count(select_related(filter(Article; title__startswith = "rel-"), :author)) == 3

    # --- prefetch_related -------------------------------------------------------------------
    authors, n = count_queries(() -> collect(order_by(prefetch_related(rel, :articles), "name")))
    @test n == 2
    @test nq(() -> [count(x.articles) for x in authors]) == 0
    @test [count(x.articles) for x in authors] == [2, 1, 0]
    @test nq(() -> [[y.title for y in x.articles] for x in authors]) == 0
    @test nq(() -> (first(authors[1].articles), exists(authors[3].articles))) == 0
    @test count(filter(authors[1].articles; published = true)) == 1          # further filtering queries again

    authors = collect(order_by(prefetch_related(rel, Prefetch(:articles; queryset = filter(Article; published = true), to_attr = :pub)), "name"))
    @test [length(x.pub) for x in authors] == [1, 1, 0] && authors[1].pub[1].title == "rel-a1"

    authors, n = count_queries(() -> collect(order_by(prefetch_related(rel, :articles__tag_set), "name")))
    @test n == 3
    @test nq(() -> sort([t.label for x in authors for y in x.articles for t in y.tag_set])) == 0
    @test sort([t.label for x in authors for y in x.articles for t in y.tag_set]) == ["rel-x", "rel-y"]

    tags, n = count_queries(() -> collect(prefetch_related(reltags, :article)))
    @test n == 2 && nq(() -> [t.article for t in tags]) == 0
    @test_throws Juango.LookupError collect(prefetch_related(rel, :nonsense))

    # --- the admin change list doesn't run a query per row ----------------------------------
    c = Client()
    force_login!(c, root_user())
    n1 = nq(() -> get(c, "/admin/article/"))
    for i in 1:5
        create(Article; title = "rel-extra-$i", author = create(Author; name = "Rel Extra $i"))
    end
    n2 = nq(() -> get(c, "/admin/article/"))
    @test n2 == n1
end

@testset "many-to-many" begin
    nq(f) = last(count_queries(f))
    b = Juango.backend()
    @test Juango.table_exists(b, "essay_topics")
    @test Set(Juango.table_columns(b, "essay_topics")) == Set(["id", "essay_id", "topic_id"])
    st = Juango.models_state()["essay_topics"]
    @test st.unique_together == [["essay_id", "topic_id"]] && st.app == "project"

    julia, web, db = create(Topic; name = "julia"), create(Topic; name = "web"), create(Topic; name = "db")
    e1 = create(Essay; title = "Fast web apps")
    e2 = create(Essay; title = "Databases")
    @test count(e1.topics) == 0
    add!(e1.topics, julia, web)
    add!(e1.topics, julia)                              # already there: skipped
    add!(e2.topics, db.id, julia)                       # ids work too
    @test sort([t.name for t in e1.topics]) == ["julia", "web"]
    @test count(julia.essays) == 2 && count(db.essays) == 1
    @test_throws IntegrityError Juango.execute("INSERT INTO \"essay_topics\" (\"essay_id\", \"topic_id\") VALUES (?, ?)", [e1.id, julia.id])
    @test_throws ArgumentError add!(filter(Topic; name = "x"), julia)
    @test_throws ArgumentError add!(Essay(title = "unsaved").topics, julia)

    # lookups in both directions
    @test sort([e.title for e in filter(Essay; topics__name = "julia")]) == ["Databases", "Fast web apps"]
    @test [e.title for e in filter(Essay; topics = web)] == ["Fast web apps"]
    @test [t.name for t in order_by(filter(Topic; essays__title = "Databases"), "name")] == ["db", "julia"]
    @test count(filter(Essay; topics__name__in = ["web", "db"])) == 2
    @test [e.title for e in exclude(Essay; topics__name = "web")] == ["Databases"]
    @test isempty(filter(Essay; topics__name = "web", topics__name__startswith = "j"))     # one join, same row
    @test count(filter(filter(Essay; topics__name = "web"); topics__name = "julia")) == 1  # two joins
    e3 = create(Essay; title = "")
    @test [e.title for e in filter(Essay; topics__isnull = true)] == [""]
    @test sort([t.name for t in filter(Topic; essays__isnull = false)]) == ["db", "julia", "web"]

    # changing the relation
    remove!(e1.topics, web)
    @test [t.name for t in e1.topics] == ["julia"]
    set!(e1.topics, [web, db])
    @test sort([t.name for t in e1.topics]) == ["db", "web"]
    clear!(e1.topics)
    @test count(e1.topics) == 0 && count(julia.essays) == 1
    set!(e1.topics, [julia, web])

    # deleting either side removes its rows in the join table
    tmp = create(Topic; name = "tmp")
    add!(e1.topics, tmp)
    delete!(tmp)
    @test sort([t.name for t in e1.topics]) == ["julia", "web"]
    gone = create(Essay; title = "gone")
    add!(gone.topics, julia)
    delete!(gone)
    @test count(julia.essays) == 2

    # prefetching
    essays, n = count_queries(() -> collect(order_by(prefetch_related(filter(Essay; title__in = ["Fast web apps", "Databases"]), :topics), "title")))
    @test n == 3      # essays, join rows, topics
    @test nq(() -> [sort([t.name for t in e.topics]) for e in essays]) == 0
    @test [sort([t.name for t in e.topics]) for e in essays] == [["db", "julia"], ["julia", "web"]]
    @test count(filter(essays[1].topics; name = "db")) == 1
    add!(essays[1].topics, web)                      # prefetched querysets keep their add!/remove! context
    @test count(filter(Essay; title = "Databases", topics = web)) == 1
    topics = collect(order_by(prefetch_related(filter(Topic; name__in = ["julia", "db"]), :essays), "name"))
    @test nq(() -> [count(t.essays) for t in topics]) == 0
    @test [count(t.essays) for t in topics] == [1, 2]

    # self-referential, not symmetrical
    ann, bob = create(Person; name = "Ann"), create(Person; name = "Bob")
    add!(ann.friends, bob)
    @test [p.name for p in ann.friends] == ["Bob"] && count(bob.friends) == 0
    @test [p.name for p in bob.person_set] == ["Ann"]
    @test [p.name for p in filter(Person; friends__name = "Bob")] == ["Ann"]
    @test Set(Juango.table_columns(b, "person_friends")) == Set(["id", "from_person_id", "to_person_id"])

    # self-referential and symmetrical (the default for :self)
    cy = create(Person; name = "Cy")
    add!(ann.pals, bob, cy)
    @test sort([p.name for p in ann.pals]) == ["Bob", "Cy"] && [p.name for p in bob.pals] == ["Ann"]
    add!(bob.pals, ann)                                         # already there both ways
    @test count(objects(Juango.through_model(Juango.modelmeta(Person).m2m[2]))) == 4
    remove!(cy.pals, ann)
    @test [p.name for p in ann.pals] == ["Bob"] && count(cy.pals) == 0
    add!(cy.pals, cy)                                           # a relation to itself is one row
    @test [p.name for p in cy.pals] == ["Cy"]
    clear!(bob.pals)
    @test count(ann.pals) == 0 && count(bob.pals) == 0
    @test sort([p.name for p in filter(Person; pals__name = "Cy")]) == ["Cy"]
    @test_throws ArgumentError ManyToManyField(Topic; symmetrical = true)
    @test_throws ArgumentError ManyToManyField(:self; through = :Membership)

    # custom intermediate model
    chess = create(Club; name = "Chess")
    add!(chess.members, ann; through_defaults = Dict(:role => "chair"))
    add!(chess.members, bob)
    @test sort([p.name for p in chess.members]) == ["Ann", "Bob"]
    @test get(Membership; person = ann).role == "chair" && get(Membership; person = bob).role == "member"
    @test [c.name for c in ann.clubs] == ["Chess"]
    @test [c.name for c in filter(Club; members__name = "Bob")] == ["Chess"]

    # ModelForm with a many-to-many field
    f = ModelForm(Essay; data = Dict("title" => "Formed", "topics" => [string(julia.id), string(db.id)]))
    @test is_valid(f)
    e = save!(f)
    @test sort([t.name for t in e.topics]) == ["db", "julia"]
    html = string(f[:topics].form |> as_p)
    @test occursin("multiple", html) && occursin("value=\"$(julia.id)\" selected", html)
    f = ModelForm(Essay; data = Dict("title" => "Formed", "topics" => [string(julia.id)]), instance = e)
    @test is_valid(f) && [t.name for t in save!(f).topics] == ["julia"]
    @test !is_valid(ModelForm(Essay; data = Dict("title" => "x", "topics" => ["999999"])))
    f2 = ModelForm(Essay; instance = e)
    @test occursin("value=\"$(julia.id)\" selected", string(as_p(f2)))
    f3 = ModelForm(Club; data = Dict("name" => "Empty"))
    @test !is_valid(f3) && haskey(f3.errors, :members)      # not blank: at least one required

    # admin add form saves the relation
    Admin.register!(Essay; list_display = [:title])
    c = Client()
    force_login!(c, root_user())
    r = get(c, "/admin/essay/add/")
    @test r.status == 200 && occursin("name=\"topics\"", text(r)) && occursin("multiple", text(r))
    r = post(c, "/admin/essay/add/", Dict("title" => "From admin", "topics" => [string(web.id)]))
    @test r.status == 302 && [t.name for t in get(Essay; title = "From admin").topics] == ["web"]
    Admin.unregister!(Essay)
end

@testset "managers" begin
    hidden = create(Essay; title = "Hidden", deleted = true)
    @test !exists(filter(Essay; title = "Hidden"))
    @test exists(filter(base_objects(Essay); title = "Hidden"))
    @test_throws DoesNotExist get(Essay; id = hidden.id)
    @test get(base_objects(Essay); id = hidden.id).title == "Hidden"
    add!(hidden.topics, create(Topic; name = "secret"))
    @test count(get(Topic; name = "secret").essays) == 0         # reverse relations use the default queryset
    @test all(e -> !isempty(e.topics), objects(Essay, :with_topics))
    @test count(objects(Essay, :with_topics)) < count(Essay)
    @test_throws ArgumentError objects(Essay, :nope)
    @test [e.title for e in objects(Essay) |> untitled] == [""]
    # the admin lists the default queryset, or its own `queryset`
    c = Client()
    force_login!(c, root_user())
    Admin.register!(Essay; list_display = [:title])
    @test !occursin("Hidden", text(get(c, "/admin/essay/")))
    @test get(c, "/admin/essay/$(hidden.id)/change/").status == 404
    Admin.register!(Essay; list_display = [:title], queryset = req -> filter(base_objects(Essay); title__startswith = "H"))
    r = get(c, "/admin/essay/")
    @test occursin("Hidden", text(r)) && !occursin("Databases", text(r))
    @test get(c, "/admin/essay/$(hidden.id)/change/").status == 200
    Admin.unregister!(Essay)
    delete!(filter(base_objects(Essay); title = "Hidden"))
    @test !exists(filter(base_objects(Essay); title = "Hidden"))
end

@testset "expressions and aggregation" begin
    sel(qs) = Juango.select_sql(qs)[1]
    A, B, C = create(Author; name = "Ex A"), create(Author; name = "Ex B"), create(Author; name = "Ex C")
    create(Article; title = "ex-1", author = A, views = 10, published = true, rating = 4.0)
    create(Article; title = "ex-2", author = A, views = 30, published = false, rating = 2.0)
    create(Article; title = "ex-3", author = B, views = 5, published = true)
    exa = filter(Article; title__startswith = "ex-")
    exau = filter(Author; name__startswith = "Ex ")
    titles(qs) = [x.title for x in order_by(qs, "title")]

    # --- annotate with aggregates (GROUP BY, HAVING) --------------------------------------------
    rows = collect(order_by(annotate(exau; n = Count(:articles)), "name"))
    @test [r.n for r in rows] == [2, 1, 0]
    @test occursin("GROUP BY", sel(annotate(exau; n = Count(:articles))))
    q = filter(annotate(exau; n = Count(:articles)); n__gte = 1)
    @test occursin("HAVING", sel(q)) && sort([a.name for a in q]) == ["Ex A", "Ex B"]
    @test count(q) == 2
    # NULL sorts differently per database (last on SQLite, first on Postgres), so coalesce
    @test [a.name for a in order_by(annotate(exau; total = Coalesce(Sum(:articles__views), Value(0))), "-total")] == ["Ex A", "Ex B", "Ex C"]
    rows = collect(order_by(annotate(exau; pub = Count(:articles; filter = Q(articles__published = true))), "name"))
    @test [r.pub for r in rows] == [1, 1, 0]
    rows = collect(order_by(annotate(exau; n = Count(:articles), mx = Max(:articles__views)), "name"))
    @test [(r.n, r.mx) for r in rows] == [(2, 30), (1, 5), (0, nothing)]
    @test [a.name for a in annotate(exau; n = Count(:articles)) |> filter(n = 0)] == ["Ex C"]

    # --- FilteredRelation ----------------------------------------------------------------------
    pubrel = annotate(exau; pub = FilteredRelation(:articles; condition = Q(articles__published = true)))
    rows = collect(order_by(annotate(pubrel; n = Count(:pub), v = Sum(:pub__views)), "name"))
    @test [(r.n, r.v) for r in rows] == [(1, 10), (1, 5), (0, nothing)]
    @test occursin(r"LEFT OUTER JOIN \S+ \S+ ON .* AND", sel(annotate(pubrel; n = Count(:pub))))
    @test sort([a.name for a in filter(pubrel; pub__views__gte = 5)]) == ["Ex A", "Ex B"]
    @test isempty(filter(pubrel; pub__title = "ex-2"))                     # ex-2 isn't published
    @test [a.name for a in filter(pubrel; pub__isnull = true)] == ["Ex C"]
    @test sort([a.name for a in exclude(pubrel; pub__views = 10)]) == ["Ex B", "Ex C"]
    @test aggregate(pubrel; n = Count(:pub))[:n] == 2
    @test values_list(order_by(filter(pubrel; pub__isnull = false), "pub__views"), :name; flat = true) == ["Ex B", "Ex A"]
    viewed = annotate(exa; who = FilteredRelation(:author; condition = Q(author__name = "Ex A")))
    @test titles(filter(viewed; who__isnull = false)) == ["ex-1", "ex-2"]
    @test_throws ArgumentError collect(annotate(exau; x = FilteredRelation(:articles; condition = Q(published = true))) |> filter(x__id = 1))
    @test_throws ArgumentError collect(annotate(exau; x = FilteredRelation(:articles; condition = Q(articles__author__name = "y"))) |> filter(x__id = 1))

    # --- custom lookups and transforms ------------------------------------------------------------
    try
        register_lookup("notequal"; kinds = [:char, :text]) do lhs, rhs
            "$lhs <> $rhs"
        end
        register_lookup("divisible_by"; kinds = :int, prepare = Int) do lhs, rhs
            "MOD($lhs, $rhs) = 0"
        end
        register_transform("lower"; kinds = [:char, :text]) do lhs
            "LOWER($lhs)"
        end
        register_transform("len"; kinds = [:char, :text], output = :int) do lhs
            (Juango.backend() isa Juango.SQLiteBackend ? "LENGTH" : "CHAR_LENGTH") * "($lhs)"
        end
        @test titles(filter(exa; title__notequal = "ex-2")) == ["ex-1", "ex-3"]
        @test titles(exclude(exa; title__notequal = "ex-2")) == ["ex-2"]
        @test titles(filter(exa; views__divisible_by = 10)) == ["ex-1", "ex-2"]
        @test_throws Juango.LookupError collect(filter(exa; views__notequal = 3))            # not for integers
        @test sort([a.name for a in filter(exau; name__lower = "ex a")]) == ["Ex A"]
        @test sort([a.name for a in filter(exau; name__lower__startswith = "ex ")]) == ["Ex A", "Ex B", "Ex C"]
        @test [a.name for a in filter(exau; name__lower__len__gte = 5)] == []
        @test length(collect(filter(exau; name__len = 4))) == 3
        @test titles(filter(exa; title__len__divisible_by = 4)) == ["ex-1", "ex-2", "ex-3"]
        @test count(filter(exa, Q(title__lower__notequal = "ex-1") | Q(views = 10))) == 3
        @test titles(filter(exa; title__notequal = F(:title))) == []
        @test titles(filter(exa; author__name__lower = "ex b")) == ["ex-3"]                 # through a relation
    finally
        foreach(Juango.unregister_lookup, ("notequal", "divisible_by", "lower", "len"))
    end
    @test_throws Juango.LookupError collect(filter(exau; name__lower = "x"))

    # --- values(): dict rows, relation paths, GROUP BY ------------------------------------------
    @test collect(values(order_by(exa, "title"), :title, :author__name)) ==
          [Dict(:title => "ex-1", :author__name => "Ex A"), Dict(:title => "ex-2", :author__name => "Ex A"),
           Dict(:title => "ex-3", :author__name => "Ex B")]
    g = order_by(annotate(values(exa, :published); n = Count(:id), v = Sum(:views)), "published")
    @test collect(g) == [Dict(:published => false, :n => 1, :v => 30), Dict(:published => true, :n => 2, :v => 15)]
    @test count(g) == 2
    @test collect(values(objects(Article), :author__name) |> annotate(n = Count()) |> filter(author__name__startswith = "Ex ") |>
                  order_by("author__name")) == [Dict(:author__name => "Ex A", :n => 2), Dict(:author__name => "Ex B", :n => 1)]
    @test values_list(order_by(exa, "title"), :title; flat = true) == ["ex-1", "ex-2", "ex-3"]
    @test values_list(order_by(exa, "title"), :title, :author__name)[3] == ("ex-3", "Ex B")
    @test values_list(order_by(annotate(exau; n = Count(:articles)), "name"), :n; flat = true) == [2, 1, 0]
    @test first(values(exa, :id))[:id] isa Integer

    # --- aggregate() -----------------------------------------------------------------------------
    agg = aggregate(exa; total = Sum(:views), n = Count(), mx = Max(:views), avg = Avg(:rating))
    @test agg == Dict(:total => 45, :n => 3, :mx => 30, :avg => 3.0)
    @test aggregate(exau; n = Count(:articles))[:n] == 3
    @test aggregate(exa, :sum, :views) == 45
    @test aggregate(exa; pub = Count(; filter = Q(published = true)))[:pub] == 2

    # --- functions, Case/When --------------------------------------------------------------------
    rows = collect(order_by(annotate(exa; up = Upper(:title), len = Length(:title), both = Concat(:title, Value("/"), :author__name),
                                     r = Coalesce(:rating, Value(0.0)), v = Cast(:views, :float), lo = Lower(Value("ABC"))), "title"))
    @test [r.up for r in rows] == ["EX-1", "EX-2", "EX-3"] && all(r -> r.len == 4, rows)
    @test rows[1].both == "ex-1/Ex A" && rows[3].r == 0.0 && rows[1].v === 10.0 && rows[1].lo == "abc"
    @test titles(filter(annotate(exa; up = Upper(:title)); up = "EX-2")) == ["ex-2"]
    @test all(a -> a.y == year(now()), annotate(exa; y = ExtractYear(:created)))
    @test count(filter(exa; created__lte = Now())) == 3
    kinds = annotate(exa; kind = Case(When(; views__gte = 20, then = "big"), When(Q(published = true); then = "pub"); default = "other"))
    @test [a.kind for a in order_by(kinds, "title")] == ["pub", "big", "pub"]
    @test [a.v for a in order_by(annotate(exa; v = F(:views) * 2 + 1), "title")] == [21, 61, 11]
    @test [a.aname for a in order_by(annotate(exa; aname = F(:author__name)), "title")] == ["Ex A", "Ex A", "Ex B"]

    # --- subqueries --------------------------------------------------------------------------------
    top = values(order_by(filter(Article; author = OuterRef(:id)), "-views"), :title)[1:1]
    @test [a.top for a in order_by(annotate(exau; top = Subquery(top)), "name")] == ["ex-2", "ex-3", nothing]
    @test [a.name for a in filter(exau, Exists(filter(Article; author = OuterRef(:id), published = false)))] == ["Ex A"]
    @test [a.name for a in filter(exau, !Exists(filter(Article; author = OuterRef(:id))))] == ["Ex C"]
    @test count(filter(exa; author__in = filter(Author; name = "Ex A"))) == 2
    @test count(filter(exa; author__in = Subquery(values(filter(Author; name = "Ex B"), :id)))) == 1

    # --- window functions --------------------------------------------------------------------------
    w = annotate(exa; rn = Window(RowNumber(); partition_by = [:author], order_by = ["-views"]),
                 tot = Window(Sum(:views); partition_by = [:author]))
    @test [(a.title, a.rn, a.tot) for a in order_by(w, "title")] == [("ex-1", 2, 40), ("ex-2", 1, 40), ("ex-3", 1, 5)]
    @test [a.prev for a in order_by(annotate(exa; prev = Window(Lag(:views); order_by = ["title"])), "title")] == [nothing, 10, 30]
    # filtering on a window annotation wraps the query
    @test titles(filter(w; rn = 1)) == ["ex-2", "ex-3"] && count(filter(w; rn = 1)) == 2
    @test exists(filter(w; rn__gt = 1)) && !exists(filter(w; rn__gt = 2))
    @test titles(filter(w; rn = 1, views__gt = 6)) == ["ex-2"]            # with the model's own fields
    # plain conditions apply before the window is computed, as in Django
    @test titles(filter(filter(w; rn = 1), title__endswith = "1")) == ["ex-1"]
    @test values_list(order_by(filter(values(w, :title), rn = 1), "-title"), :title; flat = true) == ["ex-3", "ex-2"]
    @test first(order_by(filter(w; rn = 1), "-views")).title == "ex-2"

    # --- F() in filters and updates ------------------------------------------------------------------
    @test titles(filter(exa; views__gt = F(:rating) * 5)) == ["ex-2"]
    @test titles(filter(exa; views = F(:views))) == ["ex-1", "ex-2", "ex-3"]
    @test update!(filter(exa; title = "ex-1"); views = F(:views) + 1) == 1
    @test get(Article; title = "ex-1").views == 11
    update!(exa; views = F(:views) * 2)
    @test values_list(order_by(exa, "title"), :views; flat = true) == [22, 60, 10]
    @test_throws ArgumentError update!(exa; views = F(:author__id))
    @test_throws ArgumentError annotate(exa; title = Upper(:title))
end

@testset "model inheritance" begin
    b = Juango.backend()
    cols(t) = Set(Juango.table_columns(b, t))
    nq(f) = last(count_queries(f))

    # --- abstract base models ------------------------------------------------------------------
    @test [f.name for f in Juango.all_fields(Doc)] == [:created, :note, :owner, :title]
    @test cols("doc") == Set(["id", "created", "note", "owner_id", "title"]) && !Juango.table_exists(b, "stamped")
    @test Doc <: Owned <: Stamped <: Model
    @test Juango.modelmeta(Doc).ordering == ["-id"]
    ann = create(Author; name = "Inh Ann")
    d1 = create(Doc; title = "first", note = "n1", owner = ann)
    d2 = create(Doc; title = "second")
    @test d1.created isa DateTime && d1.owner.name == "Inh Ann"
    @test [d.title for d in objects(Doc)] == ["second", "first"]          # inherited ordering
    @test [d.title for d in filter(Doc; owner__name = "Inh Ann")] == ["first"]

    # --- multi-table inheritance -----------------------------------------------------------------
    @test cols("restaurant") == Set(["id", "serves_pizza"]) && cols("pizzeria") == Set(["id", "oven"])
    r = create(Restaurant; name = "Pizza Hut", serves_pizza = true)
    plain = create(Place; name = "Library")
    @test count(filter(Place; name = "Pizza Hut")) == 1                  # a Place row too, same id
    @test get(Place; id = r.id).name == "Pizza Hut"
    got = get(Restaurant; name = "Pizza Hut")                             # inherited field lookup (join)
    @test got.id == r.id && got.serves_pizza && got.city == "Wellington"
    @test [x.name for x in filter(Restaurant; city = "Wellington")] == ["Pizza Hut"]
    @test get(Place; id = r.id).restaurant.serves_pizza                  # parent -> child
    @test get(Place; id = plain.id).restaurant === nothing
    @test got.place_ptr isa Place && got.place_ptr.name == "Pizza Hut"   # child -> parent
    @test [p.name for p in filter(Place; restaurant__serves_pizza = true)] == ["Pizza Hut"]
    @test "Library" in [p.name for p in filter(Place; restaurant__isnull = true)]

    got.name = "Pizza Palace"; got.serves_pizza = false
    save!(got)
    @test get(Place; id = r.id).name == "Pizza Palace" && !get(Restaurant; id = r.id).serves_pizza
    @test update!(filter(Restaurant; id = r.id); name = "PP", serves_pizza = true) >= 1
    @test get(Place; id = r.id).name == "PP" && get(Restaurant; id = r.id).serves_pizza
    @test [v[:name] for v in values(filter(Restaurant; id = r.id))] == ["PP"]
    @test values_list(filter(Restaurant; id = r.id), :name, :serves_pizza) == [("PP", true)]

    # three levels
    nap = create(Pizzeria; name = "Napoli", serves_pizza = true, oven = "coal", city = "Auckland")
    g = get(Pizzeria; name = "Napoli")
    @test g.oven == "coal" && g.serves_pizza && g.city == "Auckland"
    @test count(filter(Pizzeria; city = "Auckland", serves_pizza = true)) == 1
    @test get(Place; id = nap.id).restaurant.pizzeria.oven == "coal"
    @test [p.name for p in order_by(filter(Restaurant; name__in = ["PP", "Napoli"]), "name")] == ["Napoli", "PP"]
    # select_related into a model that extends other tables loads the inherited fields too
    create(Delivery; pizzeria = nap, note = "fast"); create(Delivery; note = "none")
    ds, n = count_queries(() -> collect(order_by(select_related(objects(Delivery), :pizzeria), "note")))
    @test n == 1 && ds[1].note == "fast" && ds[2].pizzeria === nothing
    @test last(count_queries(() -> (ds[1].pizzeria.oven, ds[1].pizzeria.name, ds[1].pizzeria.city, ds[1].pizzeria.serves_pizza))) == 0
    @test (ds[1].pizzeria.oven, ds[1].pizzeria.name, ds[1].pizzeria.city, ds[1].pizzeria.serves_pizza) == ("coal", "Napoli", "Auckland", true)

    # reverse relations of the parent work from the child
    create(Review; place = get(Place; id = r.id), stars = 5)
    @test count(get(Restaurant; id = r.id).reviews) == 1
    @test [x.name for x in filter(Restaurant; reviews__stars__gte = 4)] == ["PP"]

    # forms see inherited fields; saving writes both tables
    f = ModelForm(Restaurant; data = Dict("name" => "Formed", "city" => "Nelson", "serves_pizza" => "on"))
    @test [x.name for x in f.fields] == [:name, :city, :serves_pizza]
    @test is_valid(f)
    fr = save!(f)
    @test get(Place; id = fr.id).city == "Nelson" && get(Restaurant; id = fr.id).serves_pizza

    # deletes remove the child and parent rows (and cascade)
    delete!(get(Restaurant; id = r.id))
    @test !exists(filter(Place; id = r.id)) && !exists(filter(Review; stars = 5))
    delete!(get(Place; id = nap.id))
    @test !exists(filter(Restaurant; id = nap.id)) && !exists(filter(Pizzeria; id = nap.id))

    # --- proxy models ------------------------------------------------------------------------------
    @test !Juango.table_exists(b, "bigplace")
    create(Place; name = "Sky Tower", city = "Auckland")
    create(Place; name = "Auckland Museum", city = "Auckland")
    bp = collect(objects(BigPlace))
    @test [p.name for p in bp] == ["Sky Tower", "Auckland Museum"] && all(p -> p isa BigPlace, bp)
    nb = create(BigPlace; name = "Harbour Bridge", city = "Auckland")
    @test get(Place; id = nb.id).name == "Harbour Bridge"
    delete!(nb)
    @test !exists(filter(Place; name = "Harbour Bridge"))

    # --- OneToOneField -------------------------------------------------------------------------------
    bob = create(Author; name = "Inh Bob")
    @test bob.profile === nothing
    create(Profile; user = ann, bio = "writes")
    @test get(Author; id = ann.id).profile.bio == "writes"
    @test_throws IntegrityError create(Profile; user = ann)
    @test [a.name for a in filter(Author; profile__bio = "writes")] == ["Inh Ann"]
    authors = collect(order_by(prefetch_related(filter(Author; name__startswith = "Inh "), :profile), "name"))
    @test nq(() -> [a.profile === nothing ? nothing : a.profile.bio for a in authors]) == 0
    @test [a.profile === nothing ? nothing : a.profile.bio for a in authors] == ["writes", nothing]
end

@testset "content types and generic relations" begin
    nq(f) = last(count_queries(f))
    ct = get_for_model(Gallery)
    @test ct.app_label == "project" && ct.model == "gallery" && string(ct) == "project | gallery"
    @test get_for_model(Gallery).id == ct.id && model_class(ct) === Gallery
    @test get_for_model(BigPlace).id == get_for_model(Place).id
    @test exists(filter(ContentType; app_label = "auth", model = "user"))     # filled in by migrate
    @test Juango.table_exists(Juango.backend(), "juango_content_type")

    g1, g2 = create(Gallery; name = "Te Papa"), create(Gallery; name = "City Gallery")
    au = create(Author; name = "GR Author")
    r1 = create(Remark; content_object = g1, text = "nice")
    r2 = create(Remark; content_object = g1, text = "busy")
    r3 = create(Remark; content_object = au, text = "prolific")
    @test r1.content_object === g1 && r1.content_type_id == ct.id && r1.object_id == g1.id
    @test get(Remark; id = r1.id).content_object == g1
    @test get(Remark; id = r3.id).content_object isa Author
    @test sort([r.text for r in g1.remarks]) == ["busy", "nice"] && count(g2.remarks) == 0
    @test_throws ArgumentError create(Remark; content_object = Gallery(name = "unsaved"), text = "x")

    # lookups through the generic relation (the content type is part of the join)
    @test [g.name for g in filter(Gallery; remarks__text = "nice")] == ["Te Papa"]
    @test isempty(filter(Gallery; remarks__text = "prolific"))          # same object_id space, other type
    @test "City Gallery" in [g.name for g in filter(Gallery; remarks__isnull = true)]
    @test [g.name for g in exclude(filter(Gallery; name__in = ["Te Papa", "City Gallery"]); remarks__text = "busy")] == ["City Gallery"]
    @test [g.n for g in order_by(annotate(filter(Gallery; name__in = ["Te Papa", "City Gallery"]); n = Count(:remarks)), "name")] == [0, 2]

    # reassigning and clearing
    r2.content_object = g2
    save!(r2)
    @test [r.text for r in g2.remarks] == ["busy"]
    r2.content_object = nothing
    save!(r2)
    @test get(Remark; id = r2.id).content_object === nothing

    # prefetching both directions
    rs = collect(prefetch_related(filter(Remark; id__in = [r1.id, r3.id]), :content_object))
    @test nq(() -> [r.content_object for r in rs]) == 0
    @test Set(typeof(r.content_object) for r in rs) == Set([Gallery, Author])
    gs = collect(order_by(prefetch_related(filter(Gallery; name__in = ["Te Papa", "City Gallery"]), :remarks), "name"))
    @test nq(() -> [count(g.remarks) for g in gs]) == 0
    @test [count(g.remarks) for g in gs] == [0, 1]

    # deleting the target deletes its generic relations (only where a GenericRelation is declared)
    delete!(g1)
    @test !exists(filter(Remark; id = r1.id)) && exists(filter(Remark; id = r3.id))
    delete!(au)
    @test exists(filter(Remark; id = r3.id))
    @test get(Remark; id = r3.id).content_object === nothing           # points at a deleted row
end

@testset "JSON, array, UUID, range and text-search fields" begin
    ids(qs) = sort([x.title for x in qs])
    g1 = create(Gadget; data = Dict("owner" => Dict("name" => "Ann", "age" => 30), "tags" => ["a", "b"], "active" => true),
                tags = ["julia", "web"], scores = [3, 5, 8], nick = "MiXeD", ages = ValueRange(18, 30; bounds = "[]"),
                window = ValueRange(DateTime(2024, 1, 1, 10), DateTime(2024, 1, 1, 12)),
                title = "Julia web apps", body = "Fast servers with multiple dispatch")
    g2 = create(Gadget; data = Dict("owner" => Dict("name" => "Bob", "age" => 41)), tags = ["db"], nick = "other",
                title = "Databases", body = "Postgres and SQLite")
    gs = filter(Gadget; title__in = ["Julia web apps", "Databases"])

    # round trip
    r = get(Gadget; id = g1.id)
    @test r.data == Dict("owner" => Dict("name" => "Ann", "age" => 30), "tags" => ["a", "b"], "active" => true)
    @test r.tags == ["julia", "web"] && r.scores == [3, 5, 8] && r.token isa UUID && r.token == g1.token
    @test r.ages == ValueRange(18, 31) && 30 in r.ages && !(31 in r.ages)
    @test r.window == ValueRange(DateTime(2024, 1, 1, 10), DateTime(2024, 1, 1, 12))
    @test get(Gadget; id = g2.id).scores === nothing && get(Gadget; id = g2.id).ages === nothing
    @test Gadget().data == Dict() && Gadget().tags == String[]

    # JSON lookups
    @test ids(filter(gs; data__owner__name = "Ann")) == ["Julia web apps"]
    @test ids(filter(gs; data__owner__age__gt = 35)) == ["Databases"]
    @test ids(filter(gs; data__owner__age__in = [30, 41])) == ["Databases", "Julia web apps"]
    @test ids(filter(gs; data__active = true)) == ["Julia web apps"]
    @test ids(filter(gs; data__tags__0 = "a")) == ["Julia web apps"]
    @test ids(filter(gs; data__has_key = "active")) == ["Julia web apps"]
    @test ids(filter(gs; data__has_keys = ["owner", "tags"])) == ["Julia web apps"]
    @test ids(filter(gs; data__has_any_keys = ["tags", "zzz"])) == ["Julia web apps"]
    @test ids(filter(gs; data__contains = Dict("active" => true))) == ["Julia web apps"]
    @test ids(filter(gs; data__missing__isnull = true)) == ["Databases", "Julia web apps"]
    @test ids(filter(gs; data__active__isnull = false)) == ["Julia web apps"]
    @test ids(exclude(gs; data__owner__name = "Ann")) == ["Databases"]

    # arrays
    @test ids(filter(gs; tags__contains = ["julia"])) == ["Julia web apps"]
    @test ids(filter(gs; tags__overlap = ["db", "web"])) == ["Databases", "Julia web apps"]
    @test ids(filter(gs; tags__contained_by = ["julia", "web", "x"])) == ["Julia web apps"]
    @test ids(filter(gs; tags__len = 2)) == ["Julia web apps"]
    @test ids(filter(gs; scores__len__gt = 1)) == ["Julia web apps"]
    @test ids(filter(gs; tags__0 = "db")) == ["Databases"]
    @test ids(filter(gs; tags = ["db"])) == ["Databases"]

    # UUID and case-insensitive text
    @test ids(filter(gs; token = g1.token)) == ["Julia web apps"]
    @test ids(filter(gs; token = string(g2.token))) == ["Databases"]
    @test ids(filter(gs; nick = "mixed")) == ["Julia web apps"]

    # ranges
    @test ids(filter(gs; ages__contains = 20)) == ["Julia web apps"]
    @test isempty(filter(gs; ages__contains = 31))
    @test ids(filter(gs; ages__overlap = ValueRange(29, 40))) == ["Julia web apps"]
    @test isempty(filter(gs; ages__overlap = ValueRange(31, 40)))
    @test ids(filter(gs; ages__contained_by = ValueRange(0, 100))) == ["Julia web apps"]
    @test ids(filter(gs; ages__contains = ValueRange(20, 25))) == ["Julia web apps"]
    @test ids(filter(gs; window__contains = DateTime(2024, 1, 1, 11))) == ["Julia web apps"]

    # full-text search: the lookup works everywhere, expressions need PostgreSQL
    @test ids(filter(gs; title__search = "julia web")) == ["Julia web apps"]
    @test ids(filter(gs; body__search = "postgres sqlite")) == ["Databases"]
    sv = annotate(gs; search = SearchVector(:title, :body))
    if IS_POSTGRES
        @test ids(filter(sv; search = SearchQuery("dispatch"))) == ["Julia web apps"]
        @test ids(filter(sv; search = SearchQuery("\"multiple dispatch\""; search_type = :websearch))) == ["Julia web apps"]
        ranked = order_by(annotate(gs; rank = SearchRank(SearchVector(:title; weight = "A") + SearchVector(:body), SearchQuery("julia"))), "-rank")
        @test first(ranked).title == "Julia web apps"
        @test !isempty(Juango.execute("SELECT 1 FROM pg_indexes WHERE indexname = 'gadget_data_gin'"))
    else
        @test_throws ArgumentError collect(filter(sv; search = SearchQuery("dispatch")))
    end

    # forms
    f = ModelForm(Gadget; fields = [:data, :tags, :ages, :token],
                  data = Dict("data" => "{\"k\": [1, 2]}", "tags" => "x, y", "ages" => "1, 5", "token" => string(g1.token)))
    @test is_valid(f)
    @test f.cleaned_data[:data] == Dict("k" => [1, 2]) && f.cleaned_data[:tags] == ["x", "y"]
    @test f.cleaned_data[:ages] == ValueRange(1, 5) && f.cleaned_data[:token] == g1.token
    bad = ModelForm(Gadget; fields = [:data, :token], data = Dict("data" => "{nope", "token" => "zzz"))
    @test !is_valid(bad) && haskey(bad.errors, :data) && haskey(bad.errors, :token)
    @test occursin("&quot;owner&quot;", string(as_p(ModelForm(Gadget; fields = [:data], instance = g1))))

    # UUID primary keys
    t = create(Ticket; name = "t1")
    @test t.id isa UUID && get(Ticket; id = t.id).name == "t1" && get(Ticket; id = string(t.id)).name == "t1"
    st = create(Stub; ticket = t)
    @test get(Stub; id = st.id).ticket.name == "t1" && get(Stub; id = st.id).ticket_id == t.id
    @test count(filter(Stub; ticket__name = "t1")) == 1
    @test [x.ticket.name for x in select_related(objects(Stub), :ticket)] == ["t1"]
    c = Client()
    force_login!(c, root_user())
    Admin.register!(Ticket)
    @test get(c, "/admin/ticket/$(t.id)/change/").status == 200
    @test get(c, "/admin/ticket/not-a-uuid/change/").status == 404
    @test occursin("t1", text(get(c, "/admin/ticket/")))
    Admin.unregister!(Ticket)
    delete!(t)
    @test !exists(filter(Stub; id = st.id))

    # migration snapshots know the new column kinds
    st_ = Juango.models_state()
    @test Juango.Migrations.column_code(only(filter(c -> c.name == "tags", st_["gadget"].columns))) ==
          "Column(\"tags\", :array; max_length = 20, of = :string)"
    @test st_["ticket"].pk === :uuid && only(filter(c -> c.name == "ticket_id", st_["stub"].columns)).of === :uuid
    @test only(st_["gadget"].indexes).method === :gin
end

@testset "hstore, exclusion constraints, trigram, unaccent" begin
    pg = Juango.backend() isa Juango.PostgresBackend
    s1 = create(Shelf; attrs = Dict("color" => "red", "size" => "L", "gift" => nothing), label = "Café crème")
    s2 = create(Shelf; attrs = Dict("color" => "blue"), label = "Cafe noir")
    s3 = create(Shelf; label = "Tea")
    shelves = filter(Shelf; id__in = [s1.id, s2.id, s3.id])
    labels(qs) = sort([x.label for x in qs])
    @test get(Shelf; id = s1.id).attrs == Dict("color" => "red", "size" => "L", "gift" => nothing)
    @test get(Shelf; id = s3.id).attrs == Dict()
    @test labels(filter(shelves; attrs__color = "red")) == ["Café crème"]
    @test labels(filter(shelves; attrs__has_key = "color")) == ["Cafe noir", "Café crème"]
    @test labels(filter(shelves; attrs__has_keys = ["color", "size"])) == ["Café crème"]
    @test labels(filter(shelves; attrs__has_any_keys = ["size", "nope"])) == ["Café crème"]
    @test labels(filter(shelves; attrs__contains = Dict("color" => "blue"))) == ["Cafe noir"]
    Juango.backend() isa Juango.SQLiteBackend ||                      # SQLite's JSON has no contained_by
        @test labels(filter(shelves; attrs__contained_by = Dict("color" => "blue", "x" => "y"))) == ["Cafe noir", "Tea"]
    @test labels(filter(shelves; attrs = Dict("color" => "blue"))) == ["Cafe noir"]
    @test Juango.decode_hstore("\"a\"=>\"1\", \"q\\\"x\"=>NULL") == Dict("a" => "1", "q\"x" => nothing)
    @test Juango.decode_hstore(Juango.encode_hstore(Juango.PostgresBackend(""), Dict("k\\" => "v\"", "n" => nothing))) ==
          Dict("k\\" => "v\"", "n" => nothing)

    spec = Juango.constraint_spec(Reservation, only(Juango.model_constraints(Reservation)))
    @test Juango.constraint_code(spec) == "ConstraintSpec(:exclusion, \"reservation_no_overlap\"; expressions = [(\"during\", \"&&\")], " *
                                           "condition = Q(:AND, Any[:cancelled => false], false), index_type = \"gist\")"
    create(Reservation; room = 1, during = ValueRange(Date(2025, 1, 1), Date(2025, 1, 5)))
    create(Reservation; room = 1, during = ValueRange(Date(2025, 1, 5), Date(2025, 1, 8)))       # touching is fine
    create(Reservation; room = 1, during = ValueRange(Date(2025, 1, 2), Date(2025, 1, 3)), cancelled = true)
    clash = Reservation(room = 2, during = ValueRange(Date(2025, 1, 3), Date(2025, 1, 4)))
    if pg
        @test_throws IntegrityError save!(clash)
        @test full_clean(clash)[:__all__] == ["Constraint “reservation_no_overlap” is violated."]
        @test !isempty(Juango.Migrations.forwards(Juango.Migrations.HStoreExtension(), Juango.backend(), nothing, nothing, []))
        Juango.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
        Juango.execute("CREATE EXTENSION IF NOT EXISTS unaccent")
        @test labels(filter(shelves; label__unaccent = "Cafe creme")) == ["Café crème"]
        @test labels(filter(shelves; label__unaccent__icontains = "cafe")) == ["Cafe noir", "Café crème"]
        @test labels(filter(shelves; label__trigram_similar = "Cafe noire")) == ["Cafe noir"]
        @test labels(filter(shelves; label__trigram_word_similar = "noir")) == ["Cafe noir"]
        r = collect(order_by(annotate(shelves; sim = TrigramSimilarity(:label, "Cafe noir")), "-sim"))
        @test r[1].label == "Cafe noir" && r[1].sim ≈ 1.0
        r = collect(order_by(annotate(shelves; d = TrigramDistance(:label, "Tea")), "d"))
        @test r[1].label == "Tea" && r[1].d ≈ 0.0
        @test only(values_list(filter(shelves; id = s1.id) |> annotate(u = Unaccent(:label)), :u; flat = true)) == "Cafe creme"
    else
        save!(clash)                                               # other databases skip the constraint
        @test isempty(Juango.Migrations.forwards(Juango.Migrations.HStoreExtension(), Juango.backend(), nothing, nothing, []))
    end
end

@testset "GIS" begin
    # geometry values: WKT, EWKT, WKB and GeoJSON (no database needed)
    p = Point(174.7762, -41.2865)
    @test wkt(p) == "POINT(174.7762 -41.2865)" && ewkt(p) == "SRID=4326;POINT(174.7762 -41.2865)"
    @test parse_wkt(ewkt(p)) == p && parse_wkt("POINT (1 2)"; srid = 2193) == Point(1, 2; srid = 2193)
    sq = Polygon([(0, 0), (10, 0), (10, 10), (0, 10)])
    @test wkt(sq) == "POLYGON((0 0, 10 0, 10 10, 0 10, 0 0))"          # rings are closed
    for g in (sq, LineString([(0, 0), (1, 1.5)]), MultiPoint([(1, 2), (3, 4)]), MultiPolygon([sq, Polygon([(20, 20), (21, 20), (21, 21)])]),
              MultiLineString([[(0, 0), (1, 1)], [(2, 2), (3, 3)]]), Polygon([[(0, 0), (9, 0), (9, 9), (0, 0)], [(1, 1), (2, 1), (2, 2), (1, 1)]]))
        @test parse_wkt(wkt(g)) == g && from_geojson(geojson(g)) == g && from_geojson(JSON.json(geojson(g))) == g
    end
    @test parse_wkt("MULTIPOINT(1 2, 3 4)") == MultiPoint([(1, 2), (3, 4)])
    @test parse_wkb("0101000000000000000000F03F0000000000000040") == Point(1, 2)                 # WKB
    @test parse_wkb("0101000020E6100000000000000000F03F0000000000000040") == Point(1, 2)         # EWKB with SRID
    @test parse_wkb("0101000020910800000000000000005940000000000000F03F").srid == 2193
    @test geojson(p) == Dict("type" => "Point", "coordinates" => [174.7762, -41.2865])
    @test Juango.meters(D(km = 1.5)) == 1500 && Juango.meters(D(mi = 1)) ≈ 1609.344
    @test_throws ArgumentError parse_wkt("CIRCLE(1 2)")
    f = PointField()
    @test Juango.parse_geometry_input(f, "POINT(1 2)") == Point(1, 2)
    @test Juango.parse_geometry_input(f, "{\"type\": \"Point\", \"coordinates\": [1, 2]}") == Point(1, 2)
    @test_throws ArgumentError Juango.parse_geometry_input(f, "LINESTRING(0 0, 1 1)")

    if !IS_POSTGRES
        @test_throws Juango.ImproperlyConfigured Juango.geometry_column_type(Juango.backend(), :POINT)
    else
        quiet(fn) = redirect_stdout(fn, devnull)
        try
            @eval @model struct City
                name = CharField(max_length = 50)
                location = PointField()
                Meta(app_label = "gistest", table = "gis_city")
            end
            @eval @model struct Region
                name = CharField(max_length = 50)
                area = PolygonField()
                Meta(app_label = "gistest", table = "gis_region")
            end
            @eval @model struct Route
                name = CharField(max_length = 50)
                path = LineStringField(geography = true)
                Meta(app_label = "gistest", table = "gis_route")
            end
            quiet(() -> Juango.sync_models!([City, Region, Route]))
            @test !isempty(Juango.execute("SELECT 1 FROM pg_indexes WHERE tablename = 'gis_city' AND indexdef LIKE '%gist%'"))
            wlg = create(City; name = "Wellington", location = Point(174.7762, -41.2865))
            create(City; name = "Auckland", location = Point(174.7633, -36.8485))
            create(City; name = "Christchurch", location = Point(172.6362, -43.5321))
            region = create(Region; name = "Lower North Island",
                            area = Polygon([(174.0, -41.8), (176.5, -41.8), (176.5, -39.5), (174.0, -39.5)]))
            @test get(City; name = "Wellington").location == Point(174.7762, -41.2865)
            @test get(Region; id = region.id).area == region.area
            names(qs) = sort([c.name for c in qs])

            @test names(filter(City; location__within = region.area)) == ["Wellington"]
            @test names(filter(City; location__intersects = region.area)) == ["Wellington"]
            @test [r.name for r in filter(Region; area__contains = wlg.location)] == ["Lower North Island"]
            @test names(filter(City; location__disjoint = region.area)) == ["Auckland", "Christchurch"]
            near = Point(174.78, -41.29)
            @test names(filter(City; location__distance_lte = (near, D(km = 50)))) == ["Wellington"]
            @test names(filter(City; location__distance_gt = (near, D(km = 400)))) == ["Auckland"]
            @test names(filter(City; location__dwithin = (near, D(km = 350)))) == ["Christchurch", "Wellington"]
            @test names(filter(City; location__within = Polygon([(1748000, 5420000), (1760000, 5420000), (1760000, 5440000), (1748000, 5440000)]; srid = 2193))) == ["Wellington"]

            ranked = collect(order_by(annotate(objects(City); d = Distance(:location, near)), "d"))
            @test [c.name for c in ranked] == ["Wellington", "Christchurch", "Auckland"]
            @test 400_000 < ranked[3].d < 500_000                       # metres, Wellington-Auckland ~495 km
            @test 3e10 < first(annotate(objects(Region); a = Area(:area))).a < 6e10
            @test JSON.parse(first(annotate(filter(City; name = "Auckland"); g = AsGeoJSON(:location))).g)["type"] == "Point"

            create(Route; name = "SH1", path = LineString([(174.7762, -41.2865), (174.7633, -36.8485)]))
            r = get(Route; name = "SH1")
            @test r.path isa LineString && 490_000 < first(annotate(objects(Route); l = GeoLength(:path))).l < 500_000
            @test [x.name for x in filter(Route; path__distance_lte = (Point(174.77, -40.0), D(km = 20)))] == ["SH1"]

            fc = geojson(order_by(objects(City), "name"); geometry = :location)
            @test fc["type"] == "FeatureCollection" && length(fc["features"]) == 3
            @test fc["features"][1]["properties"]["name"] == "Auckland" && fc["features"][1]["geometry"]["type"] == "Point"

            fm = ModelForm(City; data = Dict("name" => "Nelson", "location" => "POINT(173.284 -41.2706)"))
            @test is_valid(fm) && save!(fm).location == Point(173.284, -41.2706)
            bad = ModelForm(City; data = Dict("name" => "x", "location" => "LINESTRING(0 0, 1 1)"))
            @test !is_valid(bad) && occursin("Expected a point", only(bad.errors[:location]))
            html = string(as_p(ModelForm(City; instance = wlg)))
            @test occursin("leaflet", html) && occursin("geo-map", html) && occursin("SRID=4326;POINT(174.7762 -41.2865)", html)
        finally
            foreach(Juango.unregister_model!, filter(T -> Juango.modelmeta(T).app == "gistest", Juango.all_models()))
            for t in ("gis_route", "gis_region", "gis_city")
                Juango.execute("DROP TABLE IF EXISTS \"$t\"")
            end
        end
    end
end

@testset "only/defer, distinct, latest/earliest, in_bulk, dates, raw, explain" begin
    au = create(Author; name = "QS Extra")
    mk(t, d; kw...) = (a = create(Article; title = t, body = "body of $t", author = au, views = length(t), kw...);
                       Juango.execute("UPDATE " * Juango.qname("article") * " SET " * Juango.qname("created") * " = ? WHERE id = ?",
                                      Any[d, a.id]); refresh!(a))
    a1 = mk("qx-one", DateTime(2024, 1, 15, 9, 30))
    a2 = mk("qx-two", DateTime(2024, 1, 20, 18, 5); status = "p")
    a3 = mk("qx-three", DateTime(2024, 3, 2, 7, 0); status = "p")
    qs = filter(Article; title__startswith = "qx-")

    # defer / only: left out of the query, loaded with one query on first access
    o = first(order_by(defer(qs, :body, :views), "id"))
    @test Set(deferred_fields(o)) == Set([:body, :views])
    @test o.title == "qx-one"
    v, n = count_queries(() -> o.body)
    @test v == "body of qx-one" && n == 1 && isempty(deferred_fields(o))
    @test last(count_queries(() -> o.views)) == 0
    o = first(order_by(only(qs, :title), "id"))
    @test :body in deferred_fields(o) && :author_id in deferred_fields(o) && o.title == "qx-one"
    @test o.author.name == "QS Extra"                                 # the FK id loads on demand too
    @test isempty(deferred_fields(first(defer(defer(qs, :body), nothing))))
    @test_throws Juango.LookupError defer(qs, :nope)
    @test_throws ArgumentError defer(qs, :id)
    # saving a deferred object writes only the loaded fields
    o = first(order_by(only(qs, :title), "id")); o.title = "qx-one!"; save!(o)
    r = get(Article; id = a1.id)
    @test r.title == "qx-one!" && r.body == "body of qx-one" && r.views == 6
    @test only(collect(filter(qs; id = a2.id))).title == "qx-two"     # Base.only still works

    # distinct
    statuses = values_list(order_by(distinct(values(qs, :status)), "status"), :status; flat = true)
    @test statuses == ["d", "p"]
    @test count(distinct(filter(Author; articles__title__startswith = "qx-"))) == 1
    if IS_POSTGRES
        firsts = collect(order_by(distinct(qs, :status), "status", "id"))
        @test [a.title for a in firsts] == ["qx-one!", "qx-two"]
    else
        @test_throws ArgumentError collect(distinct(qs, :status))
    end

    # latest / earliest
    @test latest(qs, :created).id == a3.id && earliest(qs, :created).id == a1.id
    @test latest(qs, :status, :created).id == a3.id && earliest(qs, "-views").id == a3.id
    @test_throws DoesNotExist latest(filter(qs; views = -1), :created)
    @test_throws ArgumentError latest(qs)                              # no Meta(get_latest_by)

    # in_bulk
    b = in_bulk(qs)
    @test Set(keys(b)) == Set([a1.id, a2.id, a3.id]) && b[a2.id].title == "qx-two"
    @test collect(keys(in_bulk(qs, [a1.id, 999_999]))) == [a1.id] && isempty(in_bulk(qs, Int[]))
    @test in_bulk(Author, ["QS Extra"]; field_name = :name)["QS Extra"].id == au.id
    @test_throws ArgumentError in_bulk(qs; field_name = :title)

    # dates / datetimes
    @test dates(qs, :created, :month) == [Date(2024, 1, 1), Date(2024, 3, 1)]
    @test dates(qs, :created, :year) == [Date(2024, 1, 1)]
    @test dates(qs, :created; order = :desc) == [Date(2024, 3, 2), Date(2024, 1, 20), Date(2024, 1, 15)]
    @test dates(qs, :created, :week) == [Date(2024, 1, 15), Date(2024, 2, 26)]
    @test datetimes(qs, :created, :hour) == [DateTime(2024, 1, 15, 9), DateTime(2024, 1, 20, 18), DateTime(2024, 3, 2, 7)]
    @test_throws ArgumentError dates(qs, :created, :hour)

    # raw SQL
    t = Juango.qname("article")
    rs = raw(Article, "SELECT id, title, views * 2 AS double_views FROM $t WHERE title LIKE ? ORDER BY id", ["qx-%"])
    @test [x.title for x in rs] == ["qx-one!", "qx-two", "qx-three"]
    @test rs[2].double_views == 12 && :body in deferred_fields(rs[2]) && rs[2].body == "body of qx-two"
    @test_throws ArgumentError raw(Article, "SELECT title FROM $t")

    # explain
    plan = explain(filter(qs; status = "p"))
    @test plan isa String && !isempty(plan)
end

@testset "bulk_create, bulk_update, iterator, select_for_update, union" begin
    au = create(Author; name = "Bulk Author")
    # bulk_create: one INSERT per batch; ids come back where the database can return them
    arts = [Article(; title = "bu-$i", author = au, views = i) for i in 1:5]
    objs, n = count_queries(() -> bulk_create(arts; batch_size = 2))
    @test objs === arts && n <= 4                   # 3 INSERTs (+ MariaDB's one-time version check)
    qs = filter(Article; title__startswith = "bu-")
    @test count(qs) == 5 && all(a -> a.created !== nothing, arts)
    got_ids = all(a -> a.id !== nothing, arts)
    @test got_ids == Juango.supports_insert_returning(Juango.backend())
    got_ids && @test get(Article; id = arts[3].id).title == "bu-3"
    # explicit ids, then the sequence still works for save!
    mx = maximum(values_list(objects(Author), :id; flat = true))
    bulk_create([Author(; id = mx + 10, name = "Bulk Explicit")])
    @test get(Author; name = "Bulk Explicit").id == mx + 10 && create(Author; name = "Bulk After").id > mx + 10
    # conflicts on a unique field
    bulk_create([Author(; name = "Bulk Author"), Author(; name = "Bulk New")]; ignore_conflicts = true)
    @test count(filter(Author; name__startswith = "Bulk")) == 4
    @test_throws IntegrityError bulk_create([Author(; name = "Bulk Author")])
    bulk_create([Author(; name = "Bulk Author", email = "up@x.io")]; update_conflicts = true,
                update_fields = [:email], unique_fields = [:name])
    @test get(Author; name = "Bulk Author").email == "up@x.io"
    @test_throws ArgumentError bulk_create([Author(; name = "x")]; update_conflicts = true)
    @test isempty(bulk_create(Author[]))

    # bulk_update
    objs = collect(order_by(qs, "views"))
    for o in objs
        o.views *= 10; o.title *= "!"; o.rating = 1.5
    end
    @test bulk_update(objs, [:views, :title, :rating]; batch_size = 2) == 5
    @test values_list(order_by(filter(Article; author = au), "views"), :views; flat = true) == [10, 20, 30, 40, 50]
    @test get(Article; id = objs[1].id).title == "bu-1!" && get(Article; id = objs[1].id).rating == 1.5
    @test_throws ArgumentError bulk_update(objs, [:id])
    @test_throws Juango.LookupError bulk_update(objs, [:nope])
    qs = filter(Article; author = au)

    # iterator: chunks of 2 -> 3 queries for 5 rows, in order
    titles, n = count_queries(() -> [a.title for a in iterator(order_by(qs, "views"); chunk_size = 2)])
    @test titles == ["bu-$(i)!" for i in 1:5] && n == 3
    @test length(collect(iterator(qs; chunk_size = 10))) == 5
    @test [d[:views] for d in iterator(order_by(values(qs, :views), "-views"); chunk_size = 3)] == [50, 40, 30, 20, 10]
    @test_throws ArgumentError iterator(order_by(qs, "?"))

    # select_for_update
    target = first(qs)
    @test_throws TransactionManagementError collect(select_for_update(qs))
    @test atomic(() -> length(collect(select_for_update(filter(qs; id = target.id))))) == 1
    sql = first(Juango.select_sql(select_for_update(qs; nowait = true)))
    @test occursin("FOR UPDATE NOWAIT", sql) == !occursin("SQLite", Juango.vendor(Juango.backend()))
    if IS_POSTGRES || IS_MYSQL
        locked, release = Channel{Bool}(1), Channel{Bool}(1)
        holder = @async atomic() do
            collect(select_for_update(filter(Article; id = target.id))); put!(locked, true); take!(release)
        end
        take!(locked)
        err = try
            atomic(() -> collect(select_for_update(filter(Article; id = target.id); nowait = true))); nothing
        catch e
            e
        end
        @test err !== nothing                                   # the row is locked by the other transaction
        @test isempty(atomic(() -> collect(select_for_update(filter(Article; id = target.id); skip_locked = true))))
        put!(release, true); wait(holder)
        IS_POSTGRES && @test occursin("FOR UPDATE OF", first(Juango.select_sql(select_for_update(select_related(qs, :author); of = ("self", "author")))))
    end

    # union / intersection / difference
    low, high = filter(qs; views__lte = 20), filter(qs; views__gte = 40)
    u = union(low, high)
    @test count(u) == 4 && sort([a.views for a in u]) == [10, 20, 40, 50]
    @test [a.views for a in order_by(u, "-views")] == [50, 40, 20, 10]
    @test [a.views for a in order_by(u, "views")[2:3]] == [20, 40] && first(order_by(u, "views")).views == 10
    @test count(union(low, low)) == 2 && count(union(low, low; all = true)) == 4
    @test count(union(low, high, filter(qs; views = 30))) == 5
    mid = filter(qs; views__gte = 20, views__lte = 40)
    @test sort([a.views for a in intersection(qs, mid)]) == [20, 30, 40]
    @test sort([a.views for a in difference(qs, mid)]) == [10, 50]
    @test values_list(order_by(union(values(low, :title), values(high, :title)), "title"), :title; flat = true) ==
          ["bu-1!", "bu-2!", "bu-4!", "bu-5!"]
    @test exists(u) && !exists(intersection(low, high))
    @test_throws ArgumentError filter(u; views = 10)
    @test_throws ArgumentError union(low, filter(Author; name = "x"))
    @test union(low) === low
end

# natural keys for the serialization tests
Juango.natural_key(t::Topic) = (t.name,)
Juango.get_by_natural_key(::Type{Topic}, name) = get(Topic; name = name)

@testset "serializers, dumpdata and loaddata" begin
    t1, t2 = create(Topic; name = "ser-one"), create(Topic; name = "ser-two")
    e = create(Essay; title = "ser-essay"); add!(e.topics, t1, t2)
    au = create(Author; name = "Ser Author", email = "s@x.io")
    a = create(Article; title = "ser-art", body = "b", author = au, rating = 2.5)
    s = serialize(:json, [a, e]; indent = 2)
    d = JSON.parse(s)
    @test d[1]["model"] == "project.article" && d[1]["pk"] == a.id && d[1]["fields"]["author"] == au.id
    @test d[1]["fields"]["rating"] == 2.5 && startswith(d[1]["fields"]["created"], string(year(a.created)))
    @test sort(d[2]["fields"]["topics"]) == sort([t1.id, t2.id]) && occursin("\n", s)
    @test serialize(:json, [a]; fields = [:title]) |> JSON.parse |> only |> x -> collect(keys(x["fields"])) == ["title"]

    # round trip: delete, then load back with the same ids and relations
    objs = deserialize(:json, s)
    @test length(objs) == 2 && objs[1].object isa Article && objs[1].object.id == a.id
    aid, eid, acreated = a.id, e.id, a.created
    delete!(a); delete!(e)
    foreach(save!, objs)
    a2, e2 = get(Article; id = aid), get(Essay; id = eid)
    @test a2.title == "ser-art" && a2.author.name == "Ser Author" && a2.rating == 2.5 && a2.created == acreated
    @test sort([t.name for t in e2.topics]) == ["ser-one", "ser-two"]
    @test create(Article; title = "after-load", author = au).id > aid           # the id sequence moved past them

    # natural foreign keys: topics by name
    s = serialize(:json, [e2]; natural_foreign = true)
    @test sort(JSON.parse(s)[1]["fields"]["topics"]) == [["ser-one"], ["ser-two"]]
    remove!(e2.topics, t2)
    foreach(save!, deserialize(:json, s))
    @test count(get(Essay; id = eid).topics) == 2

    # dumpdata / loaddata
    dir = mktempdir()
    out = joinpath(dir, "topics.json")
    txt = dumpdata("project.Topic"; indent = 2, output = out)
    @test isfile(out) && occursin("ser-two", txt) && all(x -> x["model"] == "project.topic", JSON.parse(txt))
    rows = JSON.parse(dumpdata("project"; exclude = ["project.article", "project.essay"]))
    models = unique(x["model"] for x in rows)
    @test "project.author" in models && !("project.article" in models)
    @test findfirst(==("project.topic"), models) !== nothing
    update!(filter(Topic; name = "ser-one"); name = "renamed")
    write(joinpath(dir, "extra.jsonl"), serialize(:jsonl, [Topic(; name = "from-fixture")]))
    configure!(FIXTURE_DIRS = [dir])
    try
        @test loaddata(out) == count(objects(Topic)) - 0              # every topic, back as dumped
        @test exists(filter(Topic; name = "ser-one")) && !exists(filter(Topic; name = "renamed"))
        @test load_fixtures("extra") == 1 && exists(filter(Topic; name = "from-fixture"))
        @test_throws ArgumentError loaddata("no-such-fixture")
    finally
        configure!(FIXTURE_DIRS = String[])
    end
    # a bad object rolls the whole load back
    bad = joinpath(dir, "bad.json")
    write(bad, """[{"model": "project.topic", "pk": null, "fields": {"name": "rolled-back"}},
                   {"model": "project.nosuchmodel", "pk": 1, "fields": {}}]""")
    @test_throws Exception loaddata(bad)
    @test !exists(filter(Topic; name = "rolled-back"))

    # YAML and XML: the same objects, relations and natural keys as JSON
    for fmt in (:yaml, :xml)
        art = create(Article; title = "fmt <&> \"$fmt\": #1", body = "two\nlines", author = au, rating = 1.5, published = true)
        es = create(Essay; title = "fmt-essay-$fmt"); add!(es.topics, t1, t2)
        g = create(Gadget; data = Dict("k" => [1, "x"]), tags = ["a b", "c"], scores = [1, 2], ages = ValueRange(1, 5),
                   nick = "", title = "yes", body = "null")
        txt = serialize(fmt, [art, es, g]; indent = 2)
        fmt === :yaml ? @test(startswith(txt, "- model: project.article\n")) : @test(occursin("<django-objects version=\"1.0\">", txt))
        objs = deserialize(fmt, txt)
        @test [typeof(o.object) for o in objs] == [Article, Essay, Gadget]
        ids = (art.id, es.id, g.id, art.created)
        delete!(art); delete!(es); delete!(g)
        foreach(save!, objs)
        a3, e3, g3 = get(Article; id = ids[1]), get(Essay; id = ids[2]), get(Gadget; id = ids[3])
        @test a3.title == "fmt <&> \"$fmt\": #1" && a3.body == "two\nlines" && a3.rating == 1.5 && a3.published &&
              a3.author_id == au.id && a3.created == ids[4]
        @test sort([t.name for t in e3.topics]) == sort([t1.name, t2.name])
        @test g3.data == Dict("k" => Any[1, "x"]) && g3.tags == ["a b", "c"] && g3.scores == [1, 2] && g3.title == "yes" &&
              g3.body == "null" && g3.token == g.token && g3.ages == g.ages && g3.window === nothing
        nat = serialize(fmt, [e3]; natural_foreign = true)
        remove!(e3.topics, t2)
        foreach(save!, deserialize(fmt, nat))
        @test count(get(Essay; id = ids[2]).topics) == 2
    end
    dumpdata("project.Topic"; format = :yaml, output = joinpath(dir, "tops.yaml"))
    dumpdata("project.Topic"; format = :xml, output = joinpath(dir, "tops.xml"))
    @test loaddata(joinpath(dir, "tops.yaml")) == loaddata(joinpath(dir, "tops.xml")) == count(objects(Topic))
    write(joinpath(dir, "hand.yml"), """
        # written by hand
        - model: project.topic
          fields:
            name: 'hand: written'   # a comment
        - model: project.topic
          fields: {name: flow-style}
        """)
    write(joinpath(dir, "hand.xml"), """<?xml version="1.0" encoding="utf-8"?>
        <django-objects version="1.0"><object model="project.topic"><field name="name" type="CharField">x&amp;y</field></object></django-objects>""")
    configure!(FIXTURE_DIRS = [dir])
    try
        @test loaddata("hand") == 3         # hand.yml and hand.xml
        @test exists(filter(Topic; name = "hand: written")) && exists(filter(Topic; name = "flow-style")) && exists(filter(Topic; name = "x&y"))
    finally
        configure!(FIXTURE_DIRS = String[])
    end
    @test Juango.parse_yaml("a: [1, {b: 'c'}]\nd: |\n  x\n  y\ne: >-\n  p\n  q\n") ==
          Dict("a" => Any[1, Dict("b" => "c")], "d" => "x\ny\n", "e" => "p q")
    @test_throws Juango.YAMLError Juango.parse_yaml("a: &x 1\nb: *x")
end

@testset "DecimalField" begin
    @test_throws ArgumentError DecimalField(max_digits = 3, decimal_places = 4)
    @test_throws UndefKeywordError DecimalField(max_digits = 3)
    f = Juango.getfield_meta(Ledger, :amount)
    c = Juango.column_state(f)
    @test c.kind === :decimal && c.max_digits == 8 && c.decimal_places == 2
    @test Juango.column_type_for(Juango.backend(), c) == (IS_MYSQL ? "DECIMAL(8, 2)" : "NUMERIC(8, 2)")
    @test occursin("max_digits = 8, decimal_places = 2", Juango.Migrations.column_code(c))

    a = create(Ledger; label = "a", amount = dec"19.99", rate = dec"0.0000001234")
    b = create(Ledger; label = "b", amount = 5, rate = nothing)               # integers and floats convert
    cc = create(Ledger; label = "c", amount = 0.1)
    for o in (a, b, cc); refresh!(o); end
    @test a.amount isa Decimal && string(a.amount) == "19.99" && string(a.rate) == "0.0000001234"
    @test string(b.amount) == "5.00" && b.rate === nothing && string(cc.amount) == "0.10"
    d = create(Ledger; label = "d", amount = dec"2.675"); refresh!(d)
    @test string(d.amount) == "2.68"                                            # rounded to decimal_places, half to even
    @test [o.label for o in filter(Ledger; amount__gte = dec"5", amount__lt = 20) |> order_by("amount")] == ["b", "a"]
    @test get(Ledger; amount = dec"19.990").label == "a" && count(filter(Ledger; amount__in = [5, dec"0.1"])) == 2

    # sums are exact (no 0.1 + 0.2 trouble) and come back as Decimals
    for i in 1:3; create(Ledger; label = "s$i", amount = dec"0.1"); end
    agg = aggregate(filter(Ledger; label__startswith = "s"); total = Sum(:amount), top = Max(:amount), avg = Avg(:amount), n = Count())
    @test agg[:total] isa Decimal && agg[:total] == dec"0.3" && string(agg[:total]) == "0.30" && agg[:top] == dec"0.1" && agg[:n] == 3
    @test agg[:avg] isa Decimal && agg[:avg] == dec"0.1"
    @test aggregate(objects(Ledger); m = Avg(:id))[:m] isa Real                 # other averages are numbers as before
    rows = values(annotate(filter(Ledger; label = "a"); double = F(:amount) * 2), :label, :amount)
    @test only(collect(rows))[:amount] == dec"19.99" && only(collect(rows))[:double] == dec"39.98"
    @test only(values_list(filter(Ledger; label = "a"), :amount; flat = true)) isa Decimal
    update!(filter(Ledger; label = "a"); amount = F(:amount) + dec"0.01")
    @test get(Ledger; label = "a").amount == dec"20.00"

    # validation (Django's DecimalValidator)
    @test isempty(full_clean(Ledger(label = "ok", amount = dec"123456.78")))
    @test full_clean(Ledger(label = "x", amount = dec"1234567.8"))[:amount] == ["Ensure that there are no more than 6 digits before the decimal point."]
    @test full_clean(Ledger(label = "x", amount = dec"1.234"))[:amount] == ["Ensure that there are no more than 2 decimal places."]
    @test full_clean(Ledger(label = "x", amount = dec"123456789"))[:amount] == ["Ensure that there are no more than 8 digits in total."]
    with_language("de") do
        @test full_clean(Ledger(label = "x", amount = dec"1.234"))[:amount] == ["Bitte geben Sie nicht mehr als 2 Dezimalstellen ein."]
    end

    # forms
    F_(data = nothing) = ModelForm(Ledger; fields = [:label, :amount], data = data)
    form = F_(Dict("label" => "f", "amount" => "12.50"))
    @test is_valid(form) && cleaned_data(form)[:amount] isa Decimal && cleaned_data(form)[:amount] == dec"12.5"
    @test !is_valid(F_(Dict("label" => "f", "amount" => "abc"))) && !is_valid(F_(Dict("label" => "f", "amount" => "1.999")))
    html = Juango.widget_html(F_()[:amount])
    @test occursin("type=\"number\"", html) && occursin("step=\"0.01\"", html)
    obj = save!(form); refresh!(obj)
    @test obj.amount == dec"12.50"

    # fixtures keep the digits; the cache stores Decimals
    s = Juango.serialize(:json, filter(Ledger; label = "a"))
    @test occursin("\"amount\":\"20.00\"", s)
    back = only(Juango.deserialize(:json, s)).object
    @test back.amount == dec"20.00" && string(back.amount) == "20.00"
    @test only(Juango.deserialize(:yaml, Juango.serialize(:yaml, filter(Ledger; label = "a")))).object.amount == dec"20.00"
    @test only(Juango.deserialize(:xml, Juango.serialize(:xml, filter(Ledger; label = "a")))).object.amount == dec"20.00"

    # template filters format decimals exactly
    t(s, ctx) = render(Template(s), ctx)
    @test t("{{ x }} {{ x|floatformat:1 }} {{ x|floatformat }} {{ y|floatformat }}", Dict("x" => dec"2.25", "y" => dec"3.00")) == "2.25 2.3 2.3 3"
    @test t("{% load humanize l10n %}{{ x|intcomma }} {{ x|localize }}", Dict("x" => dec"1234567.10")) == "1,234,567.10 1234567.10"
    @test with_language(() -> Juango.number_format(dec"1234.565"; decimals = 2), "de") == "1234,57"
end

@testset "TimeField and DurationField" begin
    @test Juango.parse_time("9:05") == Dates.Time(9, 5) && Juango.parse_time("12:30:05.25") == Dates.Time(12, 30, 5, 250)
    @test Juango.parse_time("24:00") === nothing && Juango.time_string(Dates.Time(1, 2, 3, 4, 5)) == "01:02:03.004005"
    @test Juango.duration_string(Day(1) + Hour(2) + Minute(3)) == "1 day, 2:03:00" && Juango.duration_string(Second(-90)) == "-0:01:30"
    @test Juango.duration_string(Day(2) + Millisecond(5); serial = true) == "2 00:00:00.005000"
    @test Juango.parse_duration_us("1 day, 2:03:04") == Juango.parse_duration_us("1 02:03:04") == Juango.duration_us(Day(1) + Hour(2) + Minute(3) + Second(4))
    @test Juango.parse_duration_us("90") == 90_000_000 && Juango.parse_duration_us("P1DT2H0.5S") == 93_600_500_000 &&
          Juango.parse_duration_us("P-1DT2H") == -79_200_000_000
    @test Juango.to_duration(Hour(26)) == Day(1) + Hour(2)
    @test_throws ArgumentError Juango.duration_us(Month(1))

    s = create(Shift; name = "early", starts = Dates.Time(6, 30), length = Hour(8) + Minute(30),
               opened = DateTime(2026, 3, 1, 6, 30))
    create(Shift; name = "late", starts = Dates.Time(14, 0, 0, 500), length = Minute(45), opened = DateTime(2026, 3, 1, 23, 50))
    create(Shift; name = "none", starts = Dates.Time(0))
    refresh!(s)
    @test s.starts == Dates.Time(6, 30) && s.starts isa Dates.Time && s.stamp isa Dates.Time
    @test s.length == Hour(8) + Minute(30) && s.length isa Dates.CompoundPeriod
    @test get(Shift; name = "late").starts == Dates.Time(14, 0, 0, 500)
    @test [x.name for x in filter(Shift; starts__gt = Dates.Time(6)) |> order_by("starts")] == ["early", "late"]
    @test [x.name for x in filter(Shift; length__lt = Hour(1))] == ["late"] && get(Shift; length = Minute(510)).name == "early"
    @test aggregate(filter(Shift; length__isnull = false); total = Sum(:length))[:total] == Hour(9) + Minute(15)

    # arithmetic: datetime + duration, datetime - datetime
    ends = Dict(r[:name] => r[:ends] for r in values(annotate(filter(Shift; length__isnull = false); ends = F(:opened) + F(:length)), :name))
    @test ends["early"] == DateTime(2026, 3, 1, 15, 0) && ends["late"] == DateTime(2026, 3, 2, 0, 35)
    @test [x.name for x in filter(Shift; opened__lt = F(:opened) + Value(Hour(1)), length__isnull = false) |> order_by("name")] == ["early", "late"]
    @test count(filter(Shift; opened__gt = Value(DateTime(2026, 3, 2)) - F(:length))) == 1
    took = only(values(annotate(filter(Shift; name = "early"); took = Value(DateTime(2026, 3, 1, 8, 0)) - F(:opened)), :name))[:took]
    @test took == Hour(1) + Minute(30)
    update!(filter(Shift; name = "late"); length = F(:length) + Value(Minute(15)))
    @test get(Shift; name = "late").length == Hour(1)

    # forms, fixtures, display
    f = ModelForm(Shift; fields = [:name, :starts, :length], data = Dict("name" => "x", "starts" => "07:15", "length" => "1 day, 1:00:00"))
    @test is_valid(f) && cleaned_data(f)[:starts] == Dates.Time(7, 15) && cleaned_data(f)[:length] == Day(1) + Hour(1)
    bad = ModelForm(Shift; fields = [:name, :starts, :length], data = Dict("name" => "x", "starts" => "25:00", "length" => "soon"))
    @test !is_valid(bad) && bad.errors[:starts] == ["Enter a valid time."] && bad.errors[:length] == ["Enter a valid duration."]
    @test occursin("type=\"time\"", Juango.widget_html(ModelForm(Shift; fields = [:starts])[:starts]))
    @test occursin("value=\"8:30:00\"", Juango.widget_html(ModelForm(Shift; instance = s, fields = [:length])[:length]))
    js = Juango.serialize(:json, filter(Shift; name = "early"))
    @test occursin("\"starts\":\"06:30:00\"", js) && occursin("\"length\":\"08:30:00\"", js)
    back = only(Juango.deserialize(:json, js)).object
    @test back.starts == Dates.Time(6, 30) && back.length == Hour(8) + Minute(30)
    @test render(Template("{{ s.starts }} {{ s.starts|time:\"H:i\" }} {{ s.length }}"), Dict("s" => s)) == "06:30:00 06:30 8:30:00"
end

@testset "integer sizes" begin
    b = Juango.backend()
    ty(n) = Juango.column_type_for(b, Juango.column_state(Juango.getfield_meta(Tally, n)))
    if IS_MYSQL
        @test (ty(:small), ty(:big), ty(:count), ty(:tiny), ty(:huge)) == ("SMALLINT", "BIGINT", "INT UNSIGNED", "SMALLINT UNSIGNED", "BIGINT UNSIGNED")
    elseif IS_POSTGRES
        @test (ty(:small), ty(:big), ty(:count), ty(:tiny), ty(:huge)) == ("SMALLINT", "BIGINT", "INTEGER", "SMALLINT", "BIGINT")
    end
    @test Juango.column_type_for(b, Juango.column_state(Juango.getfield_meta(Article, :views))) == (IS_MYSQL ? "INT" : IS_POSTGRES ? "INTEGER" : "INTEGER")
    t = create(Tally; small = -32768, big = typemax(Int64), count = 2147483647, tiny = 32767, huge = typemax(Int64))
    refresh!(t)
    @test t.big == typemax(Int64) && t.small == -32768 && t.count == 2147483647
    @test isempty(full_clean(Tally(small = 5, count = 0)))
    errs = full_clean(Tally(small = 40000, count = -1, tiny = 32768, huge = -5))
    @test errs[:small] == ["Ensure this value is less than or equal to 32767."]
    @test errs[:count] == ["Ensure this value is greater than or equal to 0."] && haskey(errs, :tiny) && haskey(errs, :huge)
    @test full_clean(Article(title = "x", author = create(Author; name = "Range author"), views = 2^31))[:views] ==
          ["Ensure this value is less than or equal to 2147483647."]
    with_language("de") do
        @test full_clean(Tally(count = -1))[:count] == ["Dieser Wert muss größer oder gleich 0 sein."]
    end
    # the database refuses negative values in positive fields too (CHECK, or UNSIGNED on MySQL)
    @test_throws Exception Juango.execute("INSERT INTO " * Juango.qname("tally") * " (" *
        join(Juango.qname.(["small", "big", "count", "tiny", "huge"]), ", ") * ") VALUES (0, 0, -1, 0, 0)")
    @test occursin("min=\"0\"", Juango.widget_html(ModelForm(Tally; fields = [:count])[:count]))
    f = ModelForm(Tally; fields = [:small, :count], data = Dict("small" => "99999", "count" => "3"))
    @test !is_valid(f) && f.errors[:small] == ["Ensure this value is less than or equal to 32767."]
end
