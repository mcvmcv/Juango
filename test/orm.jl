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
