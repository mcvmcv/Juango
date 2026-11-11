using Test
using Juango
using Dates
const JSON = Juango.JSON
import LibPQ    # loads the PostgreSQL driver extension
import MySQL    # loads the MySQL/MariaDB driver extension

# JUANGO_TEST_DATABASE picks the database: unset for in-memory SQLite, a SQLite path or
# sqlite:/// URL, or a postgresql:// URL. For Postgres a fresh database juango_test_<pid>
# is created on that server and dropped afterwards; the database in the URL is untouched.
const TEST_DB_SETTING = get(ENV, "JUANGO_TEST_DATABASE", ":memory:")
const IS_POSTGRES = occursin(r"^postgres(ql)?://"i, TEST_DB_SETTING)
const IS_MYSQL = occursin(r"^(mysql|mariadb)://"i, TEST_DB_SETTING)
const TEST_DATABASE = if IS_MYSQL
    name = "juango_test_$(getpid())"
    p = Juango.mysql_params(TEST_DB_SETTING)
    admin = MySQL.DBInterface.connect(MySQL.Connection, p.host, p.user, p.password; port = p.port)
    MySQL.DBInterface.execute(admin, "DROP DATABASE IF EXISTS $name")
    MySQL.DBInterface.execute(admin, "CREATE DATABASE $name CHARACTER SET utf8mb4")
    MySQL.DBInterface.close!(admin)
    atexit() do
        Juango.close_connection!()
        c = MySQL.DBInterface.connect(MySQL.Connection, p.host, p.user, p.password; port = p.port)
        MySQL.DBInterface.execute(c, "DROP DATABASE IF EXISTS $name")
        MySQL.DBInterface.close!(c)
    end
    replace(TEST_DB_SETTING, r"^((?:mysql|mariadb)://[^/?]*)(/[^?]*)?"i => SubstitutionString("\\1/$name"))
elseif IS_POSTGRES
    name = "juango_test_$(getpid())"
    admin = LibPQ.Connection(TEST_DB_SETTING)
    LibPQ.execute(admin, "SET client_min_messages TO warning")
    LibPQ.execute(admin, "DROP DATABASE IF EXISTS $name")
    LibPQ.execute(admin, "CREATE DATABASE $name")
    close(admin)
    atexit() do
        Juango.close_connection!()
        c = LibPQ.Connection(TEST_DB_SETTING)
        LibPQ.execute(c, "DROP DATABASE IF EXISTS $name WITH (FORCE)")
        close(c)
    end
    replace(TEST_DB_SETTING, r"^(postgres(?:ql)?://[^/?]*)(/[^?]*)?" => SubstitutionString("\\1/$name"))
else
    TEST_DB_SETTING
end
import Juango: Template, render

# ---------------------------------------------------------------------------------------------
# Test project: models, forms, views, urls, templates
# A SQLite backend that uses numbered placeholders (?1, ?2, ...), so the whole ORM runs
# through `rewrite_placeholders`, as it will on Postgres ($1, $2, ...).
struct NumberedSQLite <: Juango.DatabaseBackend
    path::String
end
const _SQ = Juango.SQLiteBackend
_sq(b::NumberedSQLite) = _SQ(b.path)
Juango.placeholder(::NumberedSQLite, i::Int) = "?$i"
struct GenericSQL <: Juango.DatabaseBackend end   # inherits only the standard-SQL defaults
for f in (:open_connection, :close_connection, :driver_rows, :driver_rowcount, :driver_insert_id,
          :translate_error, :autoincrement_pk, :limit_offset_sql, :date_part_sql,
          :table_exists, :table_columns, :inline_foreign_keys, :array_column_type)
    @eval Juango.$f(b::NumberedSQLite, args...) = Juango.$f(_sq(b), args...)
end
for T in (Bool, DateTime, Date)
    @eval Juango.adapt_param(b::NumberedSQLite, x::$T) = Juango.adapt_param(_sq(b), x)
end
Juango.sql_literal(b::NumberedSQLite, x::Bool) = Juango.sql_literal(_sq(b), x)
Juango.column_type(b::NumberedSQLite, kind::Symbol, ml) = Juango.column_type(_sq(b), kind, ml)
Juango.supports_index_method(b::NumberedSQLite, m::Symbol) = Juango.supports_index_method(_sq(b), m)
for L in (:contains, :startswith, :endswith)
    @eval Juango.lookup_sql(b::NumberedSQLite, v::Val{$(QuoteNode(L))}, col, x) = Juango.lookup_sql(_sq(b), v, col, x)
end

# ---------------------------------------------------------------------------------------------

@model struct Author
    name = CharField(max_length = 100, unique = true)
    email = EmailField(blank = true)
end
Base.show(io::IO, a::Author) = print(io, a.name)

@model struct Article
    title = CharField(max_length = 50)
    slug = SlugField(blank = true)
    body = TextField(blank = true)
    status = CharField(max_length = 1, choices = ["d" => "Draft", "p" => "Published"], default = "d")
    views = IntegerField(default = 0)
    rating = FloatField(null = true, blank = true)
    published = BooleanField(default = false)
    author = ForeignKey(Author, on_delete = :CASCADE, related_name = :articles)
    created = DateTimeField(auto_now_add = true)
    updated = DateTimeField(auto_now = true)
    Meta(ordering = ["-id"])
end
Base.show(io::IO, a::Article) = print(io, a.title)
Juango.get_absolute_url(a::Article) = reverse_url("article_detail"; id = a.id)
Juango.tattr(a::Article, ::Val{:shout}) = uppercase(a.title)

@model struct Tag
    label = CharField(max_length = 30)
    article = ForeignKey(Article, on_delete = :SET_NULL, null = true, blank = true)
end

@model struct Topic
    name = CharField(max_length = 30)
end
Base.show(io::IO, t::Topic) = print(io, t.name)

@model struct Essay
    title = CharField(max_length = 50)
    topics = ManyToManyField(Topic; related_name = :essays, blank = true)
    deleted = BooleanField(default = false)
end
Juango.default_queryset(::Type{Essay}) = filter(base_objects(Essay); deleted = false)
Juango.manager(::Type{Essay}, ::Val{:with_topics}) = filter(Essay; topics__isnull = false)
untitled(qs::QuerySet{Essay}) = filter(qs; title = "")

@model struct Person
    name = CharField(max_length = 30)
    friends = ManyToManyField(:self; blank = true)
end

@model struct Club
    name = CharField(max_length = 30)
    members = ManyToManyField(:Person; through = :Membership, related_name = :clubs)
end

@model struct Membership
    person = ForeignKey(:Person)
    club = ForeignKey(:Club)
    role = CharField(max_length = 20, default = "member")
end

@abstract_model struct Stamped
    created = DateTimeField(auto_now_add = true)
    note = CharField(max_length = 20, blank = true)
    Meta(ordering = ["-id"])
end
@abstract_model struct Owned <: Stamped
    owner = ForeignKey(:Author, null = true, on_delete = :SET_NULL)
end
@model struct Doc <: Owned
    title = CharField(max_length = 30)
end

@model struct Place
    name = CharField(max_length = 30)
    city = CharField(max_length = 30, default = "Wellington")
    Meta(ordering = ["name"])
end
Base.show(io::IO, p::Place) = print(io, p.name)
@model struct Restaurant <: Place
    serves_pizza = BooleanField(default = false)
end
@model struct Pizzeria <: Restaurant
    oven = CharField(max_length = 10, default = "wood")
end
@model struct Review
    place = ForeignKey(Place, on_delete = :CASCADE, related_name = :reviews)
    stars = IntegerField(default = 3)
end
@model struct BigPlace <: Place
    Meta(proxy = true, ordering = ["-name"])
end
Juango.default_queryset(::Type{BigPlace}) = filter(base_objects(BigPlace); city = "Auckland")

@model struct Profile
    user = OneToOneField(Author)
    bio = TextField(blank = true)
end

@model struct Remark
    content_type = ForeignKey(ContentType, null = true)
    object_id = IntegerField(null = true)
    content_object = GenericForeignKey()
    text = CharField(max_length = 50)
end
@model struct Gallery
    name = CharField(max_length = 30)
    remarks = GenericRelation(:Remark)
end

@model struct Gadget
    data = JSONField(default = Dict, blank = true)
    tags = ArrayField(CharField(max_length = 20); default = Vector{String}, blank = true)
    scores = ArrayField(IntegerField(); null = true, blank = true)
    token = UUIDField(default = uuid4)
    nick = CICharField(max_length = 30, blank = true)
    ages = IntegerRangeField(null = true, blank = true)
    window = DateTimeRangeField(null = true, blank = true)
    title = CharField(max_length = 50, blank = true)
    body = TextField(blank = true)
    Meta(indexes = [GinIndex(:data)])
end
@model struct Ticket
    name = CharField(max_length = 20)
    Meta(pk = :uuid)
end
Base.show(io::IO, t::Ticket) = print(io, t.name)
@model struct Stub
    ticket = ForeignKey(:Ticket)
end

@model struct Memo
    text = CharField(max_length = 50)
    Meta(permissions = [("publish_memo", "Can publish memos")])
end

@model struct Attachment
    title = CharField(max_length = 50)
    file = FileField(upload_to = "docs/%Y/", validators = [FileExtensionValidator(["txt", "pdf"])])
    photo = ImageField(upload_to = "photos/", blank = true, width_field = :photo_w, height_field = :photo_h)
    photo_w = IntegerField(null = true, blank = true, editable = false)
    photo_h = IntegerField(null = true, blank = true, editable = false)
end
Base.show(io::IO, a::Attachment) = print(io, a.title)

@model struct Locked
    article = ForeignKey(:Article, on_delete = :PROTECT)
end

@form ContactForm begin
    name = CharField(max_length = 10)
    email = EmailField()
    age = IntegerField(blank = true, null = true)
    agree = BooleanField()
    password = CharField(widget = :password)
    confirm = CharField(widget = :password)
end
Juango.clean_form(f::Form, ::Val{:ContactForm}) =
    get(f.cleaned_data, :password, nothing) != get(f.cleaned_data, :confirm, nothing) &&
    add_error!(f, nothing, "Passwords do not match.")

const TPL = mktempdir()
mkpath(joinpath(TPL, "inc"))
write(joinpath(TPL, "base.html"), """<html><title>{% block title %}Site{% endblock %}</title><body>{% block content %}BASE{% endblock %}</body></html>""")
write(joinpath(TPL, "mid.html"), """{% extends "base.html" %}{% block title %}Mid|{{ block.super }}{% endblock %}""")
write(joinpath(TPL, "child.html"), """{% extends "mid.html" %}{% block title %}Child|{{ block.super }}{% endblock %}{% block content %}Hello {{ name }}{% include "inc/part.html" with x=7 %}{% endblock %}""")
write(joinpath(TPL, "inc/part.html"), """[part {{ x }} {{ name }}]""")
write(joinpath(TPL, "article_list.html"), """{% for a in article_list %}<li>{{ a.title }}</li>{% endfor %}{% if is_paginated %}page {{ page_obj.number }}/{{ paginator.num_pages }}{% endif %}""")
write(joinpath(TPL, "article_detail.html"), """<h1>{{ article.title }}</h1><p>{{ article.author.name }}</p><a href="{{ article.get_absolute_url }}">x</a>""")
write(joinpath(TPL, "article_form.html"), """<form method="post">{% csrf_token %}{{ form }}</form>""")
write(joinpath(TPL, "article_confirm_delete.html"), """Delete {{ object }}?""")
write(joinpath(TPL, "contact.html"), """{% for m in messages %}<p class="{{ m.tags }}">{{ m }}</p>{% endfor %}<form method="post">{% csrf_token %}{{ form.as_p }}</form>""")
write(joinpath(TPL, "whoami.html"), """{% if user.is_authenticated %}user:{{ user.username }}{% else %}anon{% endif %}""")
write(joinpath(TPL, "404.html"), """custom 404 for {{ request_path }}""")

function contact(req)
    form = ContactForm(req.method == "POST" ? req.POST : nothing)
    if req.method == "POST" && is_valid(form)
        message!(req, :success, "Thanks, $(form.cleaned_data[:name])!")
        return redirect("contact")
    end
    render(req, "contact.html", Dict("form" => form))
end

counter(req) = (req.session["n"] = get(req.session, "n", 0) + 1; HttpResponse(string(req.session["n"])))
api_echo(req) = Dict("method" => req.method, "q" => get(req.GET, "q", nothing))
json_in(req) = JsonResponse(Dict("got" => json_body(req)["x"]))
boom(req) = error("kaboom")
forbidden(req) = throw(PermissionDenied())
hook(req) = HttpResponse("hooked")
secret(req) = HttpResponse("secret for $(req.user.username)")
whoami(req) = render(req, "whoami.html")
article_view(req; id::Int, slug = nothing) = HttpResponse("article $id $(something(slug, "-"))")

const blog_urls = [
    path("", ListView(Article; paginate_by = 2); name = "list"),
    path("<int:id>/<slug:slug>/", article_view; name = "detail_slug"),
]

const urlpatterns = [
    path("", TemplateView("child.html"; extra_context = Dict("name" => "World")); name = "home"),
    path("articles/", ListView(Article); name = "article_list"),
    path("articles/new/", CreateView(Article; fields = [:title, :body, :author, :status, :published]); name = "article_new"),
    path("articles/<int:id>/", DetailView(Article); name = "article_detail"),
    path("articles/<int:id>/edit/", UpdateView(Article; fields = [:title, :body, :author]); name = "article_edit"),
    path("articles/<int:id>/delete/", DeleteView(Article; success_url = "/articles/"); name = "article_delete"),
    path("blog/", include_urls(blog_urls; namespace = "blog")),
    path("contact/", contact; name = "contact"),
    path("counter/", counter; name = "counter"),
    path("api/", require_GET(api_echo); name = "api"),
    path("json/", json_in; name = "json"),
    path("boom/", boom),
    path("forbidden/", forbidden),
    path("hook/", csrf_exempt(hook)),
    path("secret/", login_required(secret); name = "secret"),
    path("whoami/", whoami),
    path("accounts/", Juango.auth_urls()),
    path("admin/", Admin.urls()),
    path("files/<path:rest>", (req; rest) -> HttpResponse(rest); name = "files"),
]

configure!(DATABASE = TEST_DATABASE, ROOT_URLCONF = urlpatterns, TEMPLATE_DIRS = [TPL],
           PASSWORD_ITERATIONS = 1000, DEBUG = true)
migrate(verbose = false)

Admin.register!(Author; list_display = [:name, :email], search_fields = [:name])
Admin.register!(Article; list_display = [:title, :author, :status, :published, "Len" => a -> length(a.body)],
                search_fields = [:title, :body], list_filter = [:published, :status, :author])

tr(src, ctx = Dict()) = render(Template(src), ctx)

# ---------------------------------------------------------------------------------------------

@testset "Juango" begin

@testset "templates: variables & filters" begin
    @test tr("Hi {{ name }}!", Dict("name" => "Ann")) == "Hi Ann!"
    @test tr("{{ x }}", Dict("x" => "<b>")) == "&lt;b&gt;"
    @test tr("{{ x|safe }}", Dict("x" => "<b>")) == "<b>"
    @test tr("{% autoescape off %}{{ x }}{% endautoescape %}", Dict("x" => "<b>")) == "<b>"
    @test tr("{{ a.b.c }}", Dict("a" => Dict("b" => Dict(:c => 3)))) == "3"
    @test tr("{{ xs.1 }}", Dict("xs" => [10, 20, 30])) == "20"
    @test tr("{{ t.name }}", Dict("t" => (name = "nt",))) == "nt"
    @test tr("[{{ missing }}][{{ missing.deep }}]") == "[][]"
    @test tr("{{ s|upper }} {{ s|lower }} {{ s|title }} {{ s|length }}", Dict("s" => "hello World")) == "HELLO WORLD hello world Hello World 11"
    @test tr("{{ x|default:\"none\" }}", Dict("x" => "")) == "none"
    @test tr("{{ xs|join:\", \" }}", Dict("xs" => ["a", "<b>"])) == "a, &lt;b&gt;"
    @test tr("{{ s|truncatechars:5 }}", Dict("s" => "abcdefgh")) == "abcd…"
    @test tr("{{ n }} item{{ n|pluralize }}", Dict("n" => 2)) == "2 items"
    @test tr("{{ n|pluralize:\"y,ies\" }}", Dict("n" => 1)) == "y"
    @test tr("{{ a|add:2 }} {{ s|add:\"x\" }}", Dict("a" => 3, "s" => "a")) == "5 ax"
    @test tr("{{ d|date:\"Y-m-d H:i\" }} {{ d|date:\"D, j M\" }}", Dict("d" => DateTime(2024, 3, 5, 14, 7))) == "2024-03-05 14:07 Tue, 5 Mar"
    @test tr("{{ s|linebreaksbr }}", Dict("s" => "a\n<b>")) == "a<br>&lt;b&gt;"
    @test tr("{{ s|slugify }}", Dict("s" => "Héllo, World!")) == "hello-world"
    @test tr("{{ x|floatformat:2 }} {{ y|floatformat }}", Dict("x" => 3.14159, "y" => 2.0)) == "3.14 2"
    @test tr("{{ b|yesno:\"on,off\" }}", Dict("b" => false)) == "off"
    @test tr("{{ xs|first }}-{{ xs|last }}", Dict("xs" => [1, 2, 3])) == "1-3"
    @test tr("{{ xs|slice:\":2\"|join:\"\" }}", Dict("xs" => ["a", "b", "c"])) == "ab"
    @test tr("{{ \"lit\" }} {{ 42 }}") == "lit 42"
    Juango.register_filter!("shout", (v, _) -> uppercase(string(v)) * "!")
    @test tr("{{ w|shout }}", Dict("w" => "hey")) == "HEY!"
    @test_throws Juango.TemplateSyntaxError Template("{{ x|nosuchfilter }}")
    @test_throws Juango.TemplateSyntaxError Template("{% if x %}unclosed")
    @test_throws Juango.TemplateSyntaxError Template("{% bogus %}")
end

@testset "templates: tags" begin
    @test tr("{% if a %}A{% elif b %}B{% else %}C{% endif %}", Dict("a" => false, "b" => true)) == "B"
    @test tr("{% if n > 2 and not flag %}yes{% endif %}", Dict("n" => 3, "flag" => false)) == "yes"
    @test tr("{% if x in xs %}in{% endif %}{% if y not in xs %}out{% endif %}", Dict("x" => 1, "y" => 9, "xs" => [1, 2])) == "inout"
    @test tr("{% if s == \"a\" or s == \"b\" %}ok{% endif %}", Dict("s" => "b")) == "ok"
    @test tr("{% if xs|length >= 2 %}long{% endif %}", Dict("xs" => [1, 2])) == "long"
    @test tr("{% if x is None %}none{% endif %}", Dict("x" => nothing)) == "none"
    @test tr("{% for x in xs %}{{ forloop.counter }}:{{ x }}{% if not forloop.last %},{% endif %}{% endfor %}", Dict("xs" => ["a", "b"])) == "1:a,2:b"
    @test tr("{% for x in xs %}x{% empty %}empty{% endfor %}", Dict("xs" => [])) == "empty"
    @test tr("{% for k, v in d.items %}{{ k }}={{ v }}{% endfor %}", Dict("d" => Dict("a" => 1))) == "a=1"
    @test tr("{% for x in xs reversed %}{{ x }}{% endfor %}", Dict("xs" => [1, 2, 3])) == "321"
    @test tr("{% for a, b in ps %}{{ a }}{{ b }};{% endfor %}", Dict("ps" => [(1, 2), (3, 4)])) == "12;34;"
    @test tr("{% for r in rows %}{% for c in r %}{{ forloop.parentloop.counter }}{{ c }}{% endfor %}{% endfor %}", Dict("rows" => [[1], [2]])) == "1122"
    @test tr("{% with total=a|add:b %}{{ total }}{% endwith %}", Dict("a" => 1, "b" => 2)) == "3"
    @test tr("{% for x in xs %}{% cycle 'odd' 'even' %} {% endfor %}", Dict("xs" => 1:3)) == "odd even odd "
    @test tr("{% firstof a b \"z\" %}", Dict("a" => "", "b" => nothing)) == "z"
    @test tr("a{# hidden #}b{% comment %}gone{{ x }}{% endcomment %}c") == "abc"
    @test tr("{% verbatim %}{{ raw }}{% if %}{% endverbatim %}") == "{{ raw }}{% if %}"
    @test tr("{% spaceless %}<p>\n  <a>x</a>\n</p>{% endspaceless %}") == "<p><a>x</a></p>"
    @test tr("{% load static %}{% static 'css/a.css' %}") == "/static/css/a.css"
    @test tr("{% url 'article_detail' id=5 %}|{% url 'blog:detail_slug' 3 'hi' %}") == "/articles/5/|/blog/3/hi/"
    @test tr("{% url 'home' as home %}[{{ home }}]") == "[/]"
    @test tr("{% csrf_token %}", Dict("csrf_token" => "abc")) == "<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"abc\">"
    @test render_to_string("child.html", Dict("name" => "<Bob>")) ==
          "<html><title>Child|Mid|Site</title><body>Hello &lt;Bob&gt;[part 7 &lt;Bob&gt;]</body></html>"
    @test render_to_string("base.html") == "<html><title>Site</title><body>BASE</body></html>"
end

@testset "urls" begin
    m = resolve("/articles/12/")
    @test m.view isa Function && m.kwargs == Dict(:id => 12) && m.url_name == "article_detail"
    m = resolve("/blog/4/my-post/")
    @test m.kwargs == Dict(:id => 4, :slug => "my-post") && m.namespace == "blog" && m.view_name == "blog:detail_slug"
    @test resolve("/articles/abc/") === nothing
    @test resolve("/files/a/b/c.txt").kwargs[:rest] == "a/b/c.txt"
    @test reverse_url("article_detail"; id = 7) == "/articles/7/"
    @test reverse_url("blog:detail_slug", 1, "x") == "/blog/1/x/"
    @test reverse_url("blog:list"; query = Dict("page" => 2)) == "/blog/?page=2"
    @test reverse_url("files"; rest = "a b/c") == "/files/a%20b/c"
    @test_throws Juango.NoReverseMatch reverse_url("nope")
    @test_throws Juango.NoReverseMatch reverse_url("article_detail"; id = "abc")
end

@testset "orm: basics" begin
    ann = create(Author; name = "Ann", email = "ann@example.com")
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

@testset "forms" begin
    f = ContactForm()
    @test !is_valid(f)
    html = as_p(f).s
    @test occursin("<input type=\"text\" name=\"name\" id=\"id_name\" required maxlength=\"10\">", html)
    @test occursin("type=\"email\"", html) && occursin("type=\"checkbox\"", html) && occursin("type=\"password\"", html)

    f = ContactForm(Dict("name" => "  Ann ", "email" => "ann@x.io", "age" => "33", "agree" => "on",
                         "password" => "pw", "confirm" => "pw"))
    @test is_valid(f)
    @test f.cleaned_data[:name] == "Ann" && f.cleaned_data[:age] == 33 && f.cleaned_data[:agree] === true

    f = ContactForm(Dict("name" => "far too long name", "email" => "bad", "age" => "x", "password" => "a", "confirm" => "b"))
    @test !is_valid(f)
    @test Set(keys(f.errors)) == Set([:name, :email, :age, :__all__])
    @test occursin("Passwords do not match.", as_p(f).s)
    @test occursin("value=\"far too long name\"", as_p(f).s)
    @test !occursin("value=\"a\"", as_p(f).s)                          # passwords never re-rendered

    ann = get(Author; name = "Ann")
    mf = ModelForm(Article; fields = [:title, :author, :status, :published])
    h = as_p(mf).s
    @test occursin("<select name=\"author\"", h) && occursin(">Ann</option>", h) && occursin(">Published</option>", h)
    mf = ModelForm(Article; data = Dict("title" => "From form", "author" => string(ann.id), "status" => "p", "published" => "on"),
                   fields = [:title, :author, :status, :published])
    @test is_valid(mf)
    art = save!(mf)
    @test art.id !== nothing && art.author == ann && art.published && art.status == "p"
    mf2 = ModelForm(Article; data = Dict("title" => "Edited", "author" => string(ann.id)), instance = art, fields = [:title, :author])
    @test is_valid(mf2)
    @test save!(mf2).id == art.id && get(Article; id = art.id).title == "Edited"
    mf3 = ModelForm(Article; data = Dict("title" => "X", "author" => "99999"), fields = [:title, :author])
    @test !is_valid(mf3) && haskey(mf3.errors, :author)
    uf = ModelForm(Author; data = Dict("name" => "Ann"))
    @test !is_valid(uf) && occursin("already exists", uf.errors[:name][1])
    @test occursin("value=\"Edited\"", as_p(ModelForm(Article; instance = art, fields = [:title])).s)
    @test tr("{{ f.title.label }}|{{ f.title }}", Dict("f" => ModelForm(Article; fields = [:title]))) ==
          "Title|<input type=\"text\" name=\"title\" id=\"id_title\" required maxlength=\"50\">"
end

@testset "auth" begin
    h = make_password("s3cret")
    @test startswith(h, "pbkdf2_sha256\$1000\$")
    @test check_password("s3cret", h) && !check_password("nope", h)
    # Reference: base64(hashlib.pbkdf2_hmac("sha256", b"password", b"seasalt", 1000)), as Django computes it
    @test make_password("password"; salt = "seasalt", iterations = 1000) ==
          "pbkdf2_sha256\$1000\$seasalt\$" * "YIWkt6M1JFXrHg5s0jZjBSc7C2Cz6QvchSJ0h8Y+i7c="
    u = create_user("alice", "wonderland"; email = "a@x.io")
    @test authenticate("alice", "wonderland") == u
    @test authenticate("alice", "wrong") === nothing
    @test authenticate("nobody", "x") === nothing
    u.is_active = false
    save!(u)
    @test authenticate("alice", "wonderland") === nothing
    u.is_active = true
    save!(u)
    @test_throws ArgumentError create_user("bad name!", "x")
end

@testset "client: views, sessions, messages" begin
    c = Client()
    r = get(c, "/")
    @test r.status == 200 && occursin("Hello World", text(r)) && r.templates == ["child.html"]
    @test getheader(r, "X-Frame-Options") == "DENY"

    @test text(get(c, "/counter/")) == "1"
    @test text(get(c, "/counter/")) == "2"
    @test text(get(Client(), "/counter/")) == "1"

    r = get(c, "/articles")                                            # APPEND_SLASH
    @test r.status == 301 && getheader(r, "Location") == "/articles/"

    r = get(c, "/nope/")
    @test r.status == 404 && occursin("Page not found", text(r)) && occursin("articles/&lt;int:id&gt;/", text(r))
    configure!(DEBUG = false)
    r = get(c, "/nope/")
    @test r.status == 404 && text(r) == "custom 404 for /nope/"
    r = get(c, "/boom/")
    @test r.status == 500 && occursin("Server Error", text(r))
    configure!(DEBUG = true)
    r = @test_logs (:error,) match_mode = :any get(c, "/boom/")
    @test r.status == 500 && occursin("kaboom", text(r))
    @test get(c, "/forbidden/").status == 403

    r = get(c, "/api/"; data = Dict("q" => "a b"))
    @test r.status == 200 && getheader(r, "Content-Type") == "application/json" && occursin("\"q\":\"a b\"", text(r))
    @test post(c, "/api/").status == 405
    @test text(request(c, "POST", "/json/"; json = Dict("x" => 42))) == "{\"got\":42}"

    r = get(c, "/contact/")
    @test r.status == 200 && r.context["form"] isa Form
    r = post(c, "/contact/", Dict("name" => "Zoe", "email" => "z@x.io", "password" => "p", "confirm" => "p"); follow = true)
    @test r.status == 200 && occursin("<p class=\"success\">Thanks, Zoe!</p>", text(r))
    @test !occursin("Thanks", text(get(c, "/contact/")))                # messages are one-shot
    r = post(c, "/contact/", Dict("name" => "Zoe"))
    @test r.status == 200 && occursin("errorlist", text(r))
end

@testset "client: csrf" begin
    c = Client(enforce_csrf = true)
    @test post(c, "/contact/", Dict("name" => "x")).status == 403
    r = get(c, "/contact/")
    tok = match(r"name=\"csrfmiddlewaretoken\" value=\"(\w+)\"", text(r))[1]
    @test haskey(c.cookies, "csrftoken") && c.cookies["csrftoken"] == tok
    r = post(c, "/contact/", Dict("csrfmiddlewaretoken" => tok, "name" => "Q", "email" => "q@x.io",
                                  "password" => "p", "confirm" => "p"))
    @test r.status == 302
    @test post(c, "/contact/", Dict("csrfmiddlewaretoken" => "wrong")).status == 403
    @test request(c, "POST", "/contact/"; headers = Dict("X-CSRFToken" => tok), data = Dict("name" => "")).status == 200
    @test post(c, "/hook/").status == 200                                # csrf_exempt
end

@testset "client: auth flow" begin
    c = Client()
    @test text(get(c, "/whoami/")) == "anon"
    r = get(c, "/secret/")
    @test r.status == 302 && getheader(r, "Location") == "/accounts/login/?next=%2Fsecret%2F"
    r = post(c, "/accounts/login/?next=/secret/", Dict("username" => "alice", "password" => "bad"))
    @test r.status == 200 && occursin("correct username and password", text(r))
    r = post(c, "/accounts/login/?next=/secret/", Dict("username" => "alice", "password" => "wonderland"); follow = true)
    @test text(r) == "secret for alice"
    @test text(get(c, "/whoami/")) == "user:alice"
    r = post(c, "/accounts/logout/")
    @test r.status == 302
    @test text(get(c, "/whoami/")) == "anon"
    c2 = Client()
    force_login!(c2, get(User; username = "alice"))
    @test text(get(c2, "/secret/")) == "secret for alice"
    # changing the password invalidates existing sessions
    u = get(User; username = "alice"); set_password!(u, "new-pass"); save!(u)
    @test text(get(c2, "/whoami/")) == "anon"
end

@testset "generic views" begin
    ann = get(Author; name = "Ann")
    for i in 1:3
        create(Article; title = "GV $i", author = ann)
    end
    c = Client()
    r = get(c, "/articles/")
    @test r.status == 200 && occursin("<li>GV 3</li>", text(r))
    r = get(c, "/blog/?page=2")
    @test r.status == 200 && occursin("page 2/", text(r))
    @test get(c, "/blog/?page=999").status == 404
    a = first(filter(Article; title = "GV 1"))
    r = get(c, "/articles/$(a.id)/")
    @test occursin("<h1>GV 1</h1><p>Ann</p><a href=\"/articles/$(a.id)/\">", text(r))
    @test get(c, "/articles/999999/").status == 404
    r = post(c, "/articles/new/", Dict("title" => "Created", "author" => string(ann.id), "status" => "d"))
    new = get(Article; title = "Created")
    @test r.status == 302 && getheader(r, "Location") == "/articles/$(new.id)/"
    r = post(c, "/articles/new/", Dict("title" => ""))
    @test r.status == 200 && occursin("This field is required.", text(r))
    r = post(c, "/articles/$(new.id)/edit/", Dict("title" => "Updated", "author" => string(ann.id)))
    @test r.status == 302 && refresh!(new).title == "Updated"
    @test occursin("Delete Updated?", text(get(c, "/articles/$(new.id)/delete/")))
    r = post(c, "/articles/$(new.id)/delete/")
    @test r.status == 302 && !exists(filter(Article; id = new.id))
end

@testset "admin" begin
    c = Client()
    r = get(c, "/admin/")
    @test r.status == 302 && startswith(getheader(r, "Location"), "/admin/login/")
    create_user("staffless", "pw12345")
    r = post(c, "/admin/login/", Dict("username" => "staffless", "password" => "pw12345"))
    @test r.status == 200 && occursin("staff account", text(r))
    create_superuser("root", "rootpw")
    r = post(c, "/admin/login/?next=/admin/", Dict("username" => "root", "password" => "rootpw"); follow = true)
    @test r.status == 200 && occursin("Site administration", text(r))
    @test occursin("Articles", text(r)) && occursin("Users", text(r))

    r = get(c, "/admin/article/")
    @test r.status == 200 && occursin("Select article to change", text(r)) && occursin("By published", text(r))
    r = get(c, "/admin/article/?q=GV")
    @test occursin("GV 2", text(r)) && !occursin("Julia rocks", text(r))
    r = get(c, "/admin/article/?published=1")
    @test r.status == 200

    ann = get(Author; name = "Ann")
    r = get(c, "/admin/article/add/")
    @test r.status == 200 && occursin("name=\"title\"", text(r)) && !occursin("name=\"created\"", text(r))
    r = post(c, "/admin/article/add/", Dict("title" => "Admin made", "author" => string(ann.id), "status" => "p", "views" => "0"); follow = true)
    @test occursin("was added successfully", text(r))
    a = get(Article; title = "Admin made")
    r = get(c, "/admin/article/$(a.id)/change/")
    @test occursin("value=\"Admin made\"", text(r)) && occursin("View on site", text(r))
    r = post(c, "/admin/article/$(a.id)/change/", Dict("title" => "", "author" => string(ann.id), "status" => "p", "views" => "0"))
    @test r.status == 200 && occursin("This field is required.", text(r))
    r = post(c, "/admin/article/$(a.id)/change/", Dict("title" => "Renamed", "author" => string(ann.id), "status" => "p", "views" => "3", "_continue" => "1"))
    @test r.status == 302 && getheader(r, "Location") == "/admin/article/$(a.id)/change/" && refresh!(a).title == "Renamed"
    @test occursin("Are you sure?", text(get(c, "/admin/article/$(a.id)/delete/")))
    r = post(c, "/admin/article/$(a.id)/delete/"; follow = true)
    @test occursin("deleted successfully", text(r)) && !exists(filter(Article; id = a.id))

    ids = values_list(filter(Article; title__startswith = "GV"), :id; flat = true)
    r = post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids)))
    @test occursin("Are you sure", text(r)) && length(ids) == 3 && count(filter(Article; id__in = ids)) == 3   # confirmation first
    r = post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids), "post" => "yes"); follow = true)
    @test occursin("Successfully deleted 3 articles", text(r))

    # user admin hashes passwords
    r = post(c, "/admin/user/add/", Dict("username" => "newbie", "password" => "hunter22", "is_active" => "on"))
    @test r.status == 302
    nb = get(User; username = "newbie")
    @test startswith(nb.password, "pbkdf2_sha256\$") && authenticate("newbie", "hunter22") == nb
    r = post(c, "/admin/user/$(nb.id)/change/", Dict("username" => "newbie", "password" => "", "is_active" => "on"))
    @test r.status == 302 && authenticate("newbie", "hunter22") !== nothing
    @test get(c, "/admin/nosuchmodel/").status == 404
    @test post(c, "/admin/logout/").status == 200
    @test get(c, "/admin/").status == 302
end

@testset "server roundtrip" begin
    server = runserver("127.0.0.1", 8765; block = false, quiet = true)
    try
        r = Juango.HTTP.get("http://127.0.0.1:8765/articles/"; status_exception = false)
        @test r.status == 200
        r = Juango.HTTP.get("http://127.0.0.1:8765/nope/"; status_exception = false)
        @test r.status == 404
    finally
        close(server)
    end
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
    force_login!(c, get(User; username = "root"))
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
    force_login!(c, get(User; username = "root"))
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
    force_login!(c, get(User; username = "root"))
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

@testset "content types and generic relations" begin
    nq(f) = last(count_queries(f))
    ct = get_for_model(Gallery)
    @test ct.app_label == "project" && ct.model == "gallery" && string(ct) == "project | gallery"
    @test get_for_model(Gallery).id == ct.id && model_class(ct) === Gallery
    @test get_for_model(BigPlace).id == get_for_model(Place).id
    @test exists(filter(ContentType; app_label = "juango", model = "user"))     # filled in by migrate
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
    force_login!(c, get(User; username = "root"))
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

@testset "permissions and groups" begin
    @test exists(filter(Permission; codename = "change_article"))
    p = get(Permission; codename = "change_article")
    @test p.content_type.model == "article" && p.name == "Can change article" && string(p) == "project | article | Can change article"
    @test perm_name(Article, :change) == "project.change_article"
    @test exists(filter(Permission; codename = "publish_memo")) && exists(filter(Permission; codename = "view_memo"))
    @test count(filter(Permission; codename__endswith = "_user")) == 4
    perm(code) = get(Permission; codename = code)
    fresh(u) = get(User; id = u.id)            # permissions are cached per user object

    u = create_user("permy", "pw12345")
    u.is_staff = true; save!(u)
    @test !has_perm(u, "project.change_article") && isempty(get_all_permissions(u))
    add!(u.user_permissions, perm("view_article"))
    u = fresh(u)
    @test has_perm(u, "project.view_article") && !has_perm(u, "project.change_article")
    editors = create(Group; name = "editors")
    add!(editors.permissions, perm("change_article"), perm("add_article"))
    add!(u.groups, editors)
    u = fresh(u)
    @test has_perms(u, ["project.view_article", "project.change_article", "project.add_article"])
    @test !has_perm(u, "project.delete_article") && !has_perm(u, "project.change_article"; obj = Article())
    @test get_all_permissions(u) == Set(["project.view_article", "project.change_article", "project.add_article"])
    @test has_module_perms(u, "project") && !has_module_perms(u, "juango")
    @test [g.name for g in u.groups] == ["editors"] && [x.username for x in editors.user_set] == ["permy"]
    root = get(User; username = "root")
    @test has_perm(root, "project.delete_article") && has_perm(root, "anything.at_all") && has_module_perms(root, "juango")
    off = create_user("offline", "pw12345"); off.is_superuser = true; off.is_active = false; save!(off)
    @test !has_perm(off, "project.view_article")
    @test !has_perm(Juango.AnonymousUser(), "project.view_article")

    # permission_required
    view = permission_required("project.add_article", "project.change_article")(req -> HttpResponse("ok"))
    req(user) = (r = Request("GET", "/x"); r.user = user; r)
    @test view(req(u)).status == 200
    @test_throws PermissionDenied view(req(create_user("nobody", "pw12345")))
    @test view(req(Juango.AnonymousUser())).status == 302
    @test permission_required(r -> "x", "project.delete_article"; raise_exception = false)(req(u)).status == 302

    # templates
    tpl = "{% if perms.project.add_article %}A{% endif %}{% if perms.project.delete_article %}D{% endif %}" *
          "{% if perms.project %}P{% endif %}{% if perms.juango %}J{% endif %}{% if \"project.view_article\" in perms %}V{% endif %}"
    @test tr(tpl, Dict("perms" => Juango.PermWrapper(u))) == "APV"

    # the admin follows permissions
    c = Client()
    force_login!(c, u)
    r = get(c, "/admin/")
    @test occursin("Articles", text(r)) && !occursin("Users", text(r))
    @test get(c, "/admin/user/").status == 403
    r = get(c, "/admin/article/")
    @test r.status == 200 && occursin("Add article", text(r)) && !occursin("Delete selected", text(r))
    a = create(Article; title = "perm-art", author = create(Author; name = "Perm Author"))
    r = get(c, "/admin/article/$(a.id)/change/")
    @test r.status == 200 && occursin("name=\"_save\"", text(r)) && !occursin("class=\"deletelink\"", text(r))
    @test get(c, "/admin/article/$(a.id)/delete/").status == 403
    @test post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string(a.id))).status == 403
    @test exists(filter(Article; id = a.id))

    viewer = create_user("viewer", "pw12345"); viewer.is_staff = true; save!(viewer)
    add!(viewer.user_permissions, perm("view_article"))
    c2 = Client()
    force_login!(c2, viewer)
    r = get(c2, "/admin/article/$(a.id)/change/")
    @test r.status == 200 && occursin("View article", text(r)) && occursin("perm-art", text(r)) && !occursin("name=\"_save\"", text(r))
    @test post(c2, "/admin/article/$(a.id)/change/", Dict("title" => "hacked")).status == 403
    @test get(Article; id = a.id).title == "perm-art"
    @test get(c2, "/admin/article/add/").status == 403
    @test !occursin("Add article", text(get(c2, "/admin/article/")))

    bare = create_user("bare", "pw12345"); bare.is_staff = true; save!(bare)
    c3 = Client()
    force_login!(c3, bare)
    @test occursin("You don’t have permission", text(get(c3, "/admin/")))

    # groups are in the admin, and a user's groups can be edited there
    rc = Client()
    force_login!(rc, root)
    @test occursin("Groups", text(get(rc, "/admin/")))
    r = get(rc, "/admin/user/$(bare.id)/change/")
    @test occursin("name=\"groups\"", text(r)) && occursin("name=\"user_permissions\"", text(r))
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

@testset "formsets" begin
    @eval @form LineForm begin
        name = CharField(max_length = 20)
        qty = IntegerField()
    end
    LineFS = formset_factory(LineForm; extra = 2)
    fs = LineFS()
    @test length(fs) == 2 && fs[1].prefix == "form-0"
    mf = string(management_form(fs))
    @test occursin("name=\"form-TOTAL_FORMS\" value=\"2\"", mf) && occursin("name=\"form-INITIAL_FORMS\" value=\"0\"", mf)
    @test occursin("name=\"form-1-qty\"", string(as_p(fs)))
    @test length(LineFS(; initial = [Dict(:name => "a", :qty => 1)])) == 3
    @test occursin("form-__prefix__-name", string(as_p(empty_form(fs))))
    html = tr("{{ fs.management_form }}{% for f in fs %}[{{ f.prefix }}]{% endfor %}", Dict("fs" => fs))
    @test occursin("TOTAL_FORMS", html) && occursin("[form-0][form-1]", html)

    mg(total, initial = 0) = Dict("form-TOTAL_FORMS" => string(total), "form-INITIAL_FORMS" => string(initial))
    data = merge(mg(3), Dict("form-0-name" => "x", "form-0-qty" => "2", "form-1-name" => "y", "form-1-qty" => "3",
                             "form-2-name" => "", "form-2-qty" => ""))
    fs = LineFS(data)
    @test is_valid(fs) && cleaned_data(fs) == [Dict(:name => "x", :qty => 2), Dict(:name => "y", :qty => 3)]   # blank extra skipped
    bad = LineFS(merge(data, Dict("form-1-qty" => "abc")))
    @test !is_valid(bad) && haskey(Juango.errors(bad)[2], :qty)
    tampered = LineFS(Dict("form-0-name" => "x"))
    @test !is_valid(tampered) && occursin("ManagementForm", only(tampered.non_form_errors))

    strict = formset_factory(LineForm; extra = 0, min_num = 2, validate_min = true, max_num = 2, validate_max = true)
    @test !is_valid(strict(merge(mg(1), Dict("form-0-name" => "a", "form-0-qty" => "1"))))
    three = merge(mg(3), Dict("form-$i-name" => "n$i" for i in 0:2), Dict("form-$i-qty" => "1" for i in 0:2))
    f3 = strict(three)
    @test !is_valid(f3) && occursin("at most 2", only(f3.non_form_errors))

    DelFS = formset_factory(LineForm; extra = 0, can_delete = true, can_order = true)
    d = merge(mg(3, 3), Dict("form-0-name" => "a", "form-0-qty" => "1", "form-0-ORDER" => "3",
                             "form-1-name" => "b", "form-1-qty" => "1", "form-1-DELETE" => "on", "form-1-ORDER" => "1",
                             "form-2-name" => "c", "form-2-qty" => "1", "form-2-ORDER" => "2"))
    fd = DelFS(d)
    @test is_valid(fd) && [x[:name] for x in cleaned_data(fd)] == ["c", "a"] && length(deleted_forms(fd)) == 1
    nodup(fs) = length(unique(x[:name] for x in cleaned_data(fs))) == length(cleaned_data(fs)) || Juango.add_error!(fs, "Names must differ.")
    DupFS = formset_factory(LineForm; extra = 0, clean = nodup)
    fdup = DupFS(merge(mg(2), Dict("form-0-name" => "a", "form-0-qty" => "1", "form-1-name" => "a", "form-1-qty" => "2")))
    @test !is_valid(fdup) && fdup.non_form_errors == ["Names must differ."]

    # model formsets
    a1, a2 = create(Author; name = "FS One"), create(Author; name = "FS Two")
    outsider = create(Author; name = "FS Outsider")
    AuthorFS = modelformset_factory(Author; fields = [:name], extra = 1, can_delete = true)
    qs = order_by(filter(Author; name__in = ["FS One", "FS Two"]), "name")
    fs = AuthorFS(; queryset = qs)
    @test length(fs) == 3 && occursin("name=\"form-0-id\" id=\"id_form-0-id\"", string(as_p(fs)))
    post_ = merge(mg(3, 2), Dict("form-0-id" => string(a1.id), "form-0-name" => "FS One renamed",
                                 "form-1-id" => string(a2.id), "form-1-name" => "FS Two", "form-1-DELETE" => "on",
                                 "form-2-id" => "", "form-2-name" => "FS Three"))
    fs = AuthorFS(post_; queryset = qs)
    @test is_valid(fs)
    saved = save!(fs)
    @test length(saved) == 2 && length(fs.new_objects) == 1 && length(fs.changed_objects) == 1 && length(fs.deleted_objects) == 1
    @test get(Author; id = a1.id).name == "FS One renamed" && !exists(filter(Author; id = a2.id)) && exists(filter(Author; name = "FS Three"))
    # an id outside the queryset never touches that object
    sneaky = AuthorFS(merge(mg(1, 1), Dict("form-0-id" => string(outsider.id), "form-0-name" => "hacked"));
                      queryset = filter(Author; name = "FS One renamed"))
    is_valid(sneaky) && save!(sneaky)
    @test get(Author; id = outsider.id).name == "FS Outsider"

    # inline formsets
    ArtFS = inlineformset_factory(Author, Article; fields = [:title], extra = 2)
    create(Article; title = "existing", author = a1)
    fs = ArtFS(; instance = a1)
    @test length(fs) == 3 && fs.prefix == "articles"
    @test !occursin("articles-0-author", string(as_p(fs)))
    existing = only(filter(Article; author = a1))
    p2 = Dict("articles-TOTAL_FORMS" => "3", "articles-INITIAL_FORMS" => "1",
              "articles-0-id" => string(existing.id), "articles-0-title" => "existing (edited)",
              "articles-1-title" => "brand new", "articles-2-title" => "")
    fs = ArtFS(p2; instance = a1)
    @test is_valid(fs)
    save!(fs)
    @test sort([x.title for x in filter(Article; author = a1)]) == ["brand new", "existing (edited)"]
    @test_throws ArgumentError inlineformset_factory(Topic, Article)
end

@testset "admin: history, actions, inlines and layout options" begin
    root = get(User; username = "root")
    c = Client()
    force_login!(c, root)
    ct = get_for_model(Author)
    function shout(ma, req, qs)
        for a in qs
            a.name = uppercase(a.name); save!(a)
            log_action!(req.user, a, CHANGE, "Shouted.")
        end
        message!(req, :success, "Shouted $(count(qs)).")
        nothing
    end
    Admin.register!(Author; list_display = [:name, :email], list_editable = [:email], search_fields = [:name],
                    fieldsets = ["Main" => [:name], "Contact" => [:email]], save_as = true,
                    inlines = [Admin.TabularInline(Article; fields = [:title, :status], extra = 1)],
                    actions = [Admin.action(shout; description = "Shout names", confirm = true), Admin.export_csv])
    try
        # adding and changing are logged; history and recent actions show them
        r = post(c, "/admin/author/add/", Dict("name" => "Adm Ann", "email" => "",
                                              "articles-TOTAL_FORMS" => "1", "articles-INITIAL_FORMS" => "0",
                                              "articles-0-title" => "Inline one", "articles-0-status" => "d"))
        @test r.status == 302
        ann = get(Author; name = "Adm Ann")
        @test [x.title for x in ann.articles] == ["Inline one"]               # inline saved with the new parent
        e = first(filter(LogEntry; content_type = ct, object_id = string(ann.id)))
        @test e.action_flag == ADDITION && e.user == root && e.object_repr == "Adm Ann"

        r = get(c, "/admin/author/$(ann.id)/change/")
        @test r.status == 200 && occursin("<h2>Contact</h2>", text(r)) && occursin("articles-TOTAL_FORMS", text(r))
        @test occursin("name=\"_saveasnew\"", text(r)) && occursin("/admin/author/$(ann.id)/history/", text(r))
        art = only(ann.articles)
        post(c, "/admin/author/$(ann.id)/change/", Dict("name" => "Adm Ann", "email" => "ann@x.io",
            "articles-TOTAL_FORMS" => "2", "articles-INITIAL_FORMS" => "1",
            "articles-0-id" => string(art.id), "articles-0-title" => "Inline one", "articles-0-status" => "d", "articles-0-DELETE" => "on",
            "articles-1-title" => "Inline two", "articles-1-status" => "p"))
        @test [x.title for x in get(Author; id = ann.id).articles] == ["Inline two"]
        e = first(order_by(filter(LogEntry; object_id = string(ann.id), content_type = ct), "-id"))
        @test e.action_flag == CHANGE && occursin("Changed email.", e.change_message) &&
              occursin("Added article “Inline two”.", e.change_message) && occursin("Deleted article “Inline one”.", e.change_message)
        r = get(c, "/admin/author/$(ann.id)/history/")
        @test r.status == 200 && occursin("Changed email.", text(r)) && occursin("Added.", text(r))
        @test occursin("Recent actions", text(get(c, "/admin/"))) && occursin(">Adm Ann</a>", text(get(c, "/admin/")))

        # save as new
        post(c, "/admin/author/$(ann.id)/change/", Dict("name" => "Adm Copy", "email" => "c@x.io", "_saveasnew" => "1"))
        @test exists(filter(Author; name = "Adm Copy")) && get(Author; id = ann.id).name == "Adm Ann"

        # list_editable
        bob = create(Author; name = "Adm Bob")
        r = get(c, "/admin/author/?q=Adm+Bob")
        @test occursin("name=\"form-0-email\"", text(r)) && occursin("form-TOTAL_FORMS", text(r))
        r = post(c, "/admin/author/?q=Adm+Bob", Dict("_save" => "Save", "form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1",
                                                     "form-0-id" => string(bob.id), "form-0-email" => "bob@x.io"); follow = true)
        @test get(Author; id = bob.id).email == "bob@x.io" && occursin("1 author was changed", text(r))

        # actions: confirmation, custom, CSV export, delete with logging
        r = get(c, "/admin/author/")
        @test occursin("Shout names", text(r)) && occursin("Export selected as CSV", text(r)) && occursin("Delete selected authors", text(r))
        r = post(c, "/admin/author/", Dict("action" => "shout", "_selected_action" => string(bob.id)))
        @test occursin("Are you sure", text(r)) && get(Author; id = bob.id).name == "Adm Bob"
        r = post(c, "/admin/author/", Dict("action" => "shout", "_selected_action" => string(bob.id), "post" => "yes"); follow = true)
        @test get(Author; id = bob.id).name == "ADM BOB" && occursin("Shouted 1.", text(r))
        r = post(c, "/admin/author/", Dict("action" => "export_csv", "_selected_action" => [string(bob.id), string(ann.id)]))
        @test startswith(getheader(r, "Content-Type"), "text/csv") && startswith(text(r), "Name,Email\r\n")
        @test occursin("ADM BOB,bob@x.io", text(r)) && occursin("attachment", getheader(r, "Content-Disposition"))
        post(c, "/admin/author/", Dict("action" => "delete_selected", "_selected_action" => string(bob.id), "post" => "yes"))
        @test !exists(filter(Author; id = bob.id)) && get(LogEntry; object_id = string(bob.id), action_flag = DELETION).object_repr == "ADM BOB"
        @test occursin("No action selected", text(post(c, "/admin/author/", Dict("action" => "nope", "_selected_action" => "1"); follow = true)))

        # Article: readonly, prepopulated, raw id, autocomplete, date hierarchy
        Admin.register!(Article; list_display = [:title, :author], readonly_fields = [:views], date_hierarchy = :created,
                        prepopulated_fields = Dict(:slug => [:title]), autocomplete_fields = [:author])
        r = get(c, "/admin/article/add/")
        @test occursin("\"target\":\"id_slug\"", text(r)) && occursin("data-autocomplete=\"author\"", text(r))
        @test !occursin("name=\"views\"", text(r))
        a2 = only(get(Author; id = ann.id).articles)
        r = get(c, "/admin/article/$(a2.id)/change/")
        @test occursin("Views:", text(r)) && !occursin("name=\"views\"", text(r)) && !occursin("\"target\"", text(r))
        @test occursin("<option value=\"$(ann.id)\" selected>Adm Ann</option>", text(r))
        js = Juango.JSON.parse(text(get(c, "/admin/author/autocomplete/?term=adm+a")))
        @test [x["text"] for x in js["results"]] == ["Adm Ann"]
        r = get(c, "/admin/article/")
        y = year(now())
        @test occursin(">$y</a>", text(r))
        r = get(c, "/admin/article/?created__year=$y")
        @test occursin("‹ All dates", text(r)) && occursin(Dates.monthname(month(now())), text(r))
        @test !occursin("Inline two", text(get(c, "/admin/article/?created__year=1999")))
        Admin.register!(Article; list_display = [:title], raw_id_fields = [:author])
        r = get(c, "/admin/article/$(a2.id)/change/")
        @test occursin("class=\"raw-id\" value=\"$(ann.id)\"", text(r)) && occursin(">Adm Ann</span>", text(r))
    finally
        Admin.unregister!(Author)
        Admin.register!(Author; list_display = [:name, :email], search_fields = [:name])
        Admin.register!(Article; list_display = [:title, :author, :status, :published, "Len" => a -> length(a.body)],
                        search_fields = [:title, :body], list_filter = [:published, :status, :author])
    end
end

@testset "file uploads and storage" begin
    media = mktempdir()
    old_media = settings.MEDIA_ROOT
    configure!(MEDIA_ROOT = media)
    png = vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13], Vector{UInt8}("IHDR"),
               UInt8[0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0], zeros(UInt8, 8))
    try
        # image sizes without an image library
        @test image_size(png) == (3, 2)
        @test image_size(vcat(Vector{UInt8}("GIF89a"), UInt8[5, 0, 7, 0], zeros(UInt8, 4))) == (5, 7)
        @test image_size(UInt8[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0, 0, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x09, 0x00, 0x0a, 0, 0, 0]) == (10, 9)
        @test image_size(vcat(Vector{UInt8}("RIFF"), zeros(UInt8, 4), Vector{UInt8}("WEBPVP8X"), zeros(UInt8, 8), UInt8[3, 0, 0, 1, 0, 0], zeros(UInt8, 4))) == (4, 2)
        @test image_size(Vector{UInt8}("not an image")) === nothing

        # storage: safe names, no escaping the root, no overwriting
        @test Juango.get_valid_name("../../etc/passwd") == "passwd" && Juango.get_valid_name(" my file (1).txt") == "my_file_1.txt"
        st = FileSystemStorage()
        n1 = save_file(st, "a/b/report.txt", Vector{UInt8}("one"))
        n2 = save_file(st, "a/b/report.txt", Vector{UInt8}("two"))
        @test n1 == "a/b/report.txt" && n2 != n1 && startswith(n2, "a/b/report_") && endswith(n2, ".txt")
        @test read(st, n1) == Vector{UInt8}("one") && Juango.exists(st, n2) && size(st, n2) == 3
        @test Juango.url(st, n1) == "/media/a/b/report.txt"
        @test save_file(st, "../../outside.txt", UInt8[1]) == "outside.txt" && isfile(joinpath(media, "outside.txt"))
        @test_throws ArgumentError Juango.path(st, "../secret")
        delete_file(st, n2)
        @test !Juango.exists(st, n2)

        # model fields
        a = create(Attachment; title = "notes", file = UploadedFile("my notes.txt", "hello"), photo = UploadedFile("p.png", png))
        @test a.file isa FieldFile && startswith(a.file.name, "docs/$(year(now()))/my_notes") && String(read(a.file)) == "hello"
        @test a.photo_w == 3 && a.photo_h == 2 && a.photo.width == 3 && a.file.size == 5
        r = get(Attachment; id = a.id)
        @test r.file.name == a.file.name && r.file.url == "/media/" * a.file.name && r.photo.height == 2
        @test tr("{{ a.file.url }} {{ a.photo.width }}", Dict("a" => r)) == "/media/$(a.file.name) 3"
        nophoto = create(Attachment; title = "bare", file = UploadedFile("x.txt", "x"))
        @test get(Attachment; id = nophoto.id).photo === nothing

        # forms
        f = ModelForm(Attachment; data = Dict("title" => "via form"), files = Dict("file" => UploadedFile("doc.pdf", "%PDF")))
        @test is_valid(f) && Juango.has_changed(f)
        saved = save!(f)
        @test endswith(saved.file.name, "doc.pdf") && String(read(saved.file)) == "%PDF"
        bad = ModelForm(Attachment; data = Dict("title" => "x"), files = Dict("file" => UploadedFile("evil.exe", "MZ"), "photo" => UploadedFile("fake.png", "text")))
        @test !is_valid(bad) && occursin("not allowed", only(bad.errors[:file])) && occursin("valid image", only(bad.errors[:photo]))
        @test !is_valid(ModelForm(Attachment; data = Dict("title" => "no file")))          # required
        keep = ModelForm(Attachment; data = Dict("title" => "renamed"), instance = get(Attachment; id = a.id))
        @test is_valid(keep) && save!(keep).file.name == a.file.name                      # no upload: file kept
        clear = ModelForm(Attachment; data = Dict("title" => "renamed", "photo-clear" => "on"), instance = get(Attachment; id = a.id))
        @test is_valid(clear) && save!(clear).photo === nothing
        html = string(as_p(ModelForm(Attachment; instance = get(Attachment; id = nophoto.id))))
        @test occursin("type=\"file\" name=\"file\"", html) && occursin("Currently: <a href=\"/media/", html) && occursin("accept=\"image/*\"", html)

        # multipart requests, the admin, and media served in development
        body, ctype = Juango.multipart_body(Dict("title" => "t", "file" => UploadedFile("up.txt", "uploaded"; content_type = "text/plain")))
        req = Request("POST", "/x"; headers = Dict("content-type" => ctype), body = body)
        @test req.POST["title"] == "t" && req.FILES["file"].name == "up.txt" && String(read(req.FILES["file"])) == "uploaded"
        @test req.FILES["file"].content_type == "text/plain" && isempty(Request("GET", "/").FILES)
        c = Client()
        force_login!(c, get(User; username = "root"))
        Admin.register!(Attachment; list_display = [:title, :file])
        @test occursin("enctype=\"multipart/form-data\"", text(get(c, "/admin/attachment/add/")))
        r = post(c, "/admin/attachment/add/", Dict("title" => "from admin", "file" => UploadedFile("admin.txt", "via admin")))
        @test r.status == 302
        fa = get(Attachment; title = "from admin")
        @test String(read(fa.file)) == "via admin" && isfile(fa.file.path)
        r = get(c, fa.file.url)
        @test r.status == 200 && text(r) == "via admin" && startswith(getheader(r, "Content-Type"), "text/plain")
        @test get(c, "/media/../runtests.jl").status == 404 && get(c, "/media/nope.txt").status == 404
        Admin.unregister!(Attachment)
    finally
        configure!(MEDIA_ROOT = old_media)
    end
end

@testset "email, signing and password reset" begin
    import Sockets
    c = Client()
    @test settings.EMAIL_BACKEND === :locmem                       # the test Client keeps mail in memory
    empty!(outbox)
    @test send_mail("Hi", "Body", "a@x.io", ["b@x.io", "c@x.io"]) == 1
    @test only(outbox).subject == "Hi" && only(outbox).to == ["b@x.io", "c@x.io"] && only(outbox).from_email == "a@x.io"
    @test send_mail("Nobody", "x", nothing, String[]) == 0

    msg = EmailMessage("Ünïcode subject", "body text"; to = ["t@x.io"], cc = ["c@x.io"], bcc = ["secret@x.io"], reply_to = ["r@x.io"])
    attach!(msg, "r.csv", "a,b", "text/csv")
    attach_alternative!(msg, "<p>hi</p>")
    s = Juango.message_string(msg)
    @test occursin("Subject: =?utf-8?b?", s) && occursin("Cc: c@x.io", s) && occursin("Reply-To: r@x.io", s) && !occursin("secret@x.io", s)
    @test occursin("multipart/mixed", s) && occursin("multipart/alternative", s) && occursin("filename=\"r.csv\"", s)
    @test occursin(Juango.base64encode("body text"), s) && occursin(Juango.base64encode("<p>hi</p>"), s)
    @test Juango.recipients(msg) == ["t@x.io", "c@x.io", "secret@x.io"]
    @test !occursin("\r\nBcc: evil", Juango.message_string(EmailMessage("a\r\nBcc: evil@x.io", "b"; to = ["t@x.io"])))

    # backends
    configure!(EMAIL_BACKEND = :console)
    path_, io = mktemp()
    redirect_stdout(() -> send_mail("Console", "printed", nothing, ["t@x.io"]), io); close(io)
    @test occursin("Subject: Console", read(path_, String))
    dir = mktempdir()
    configure!(EMAIL_BACKEND = :file, EMAIL_FILE_PATH = dir)
    send_mail("Filed", "x", nothing, ["t@x.io"])
    @test length(readdir(dir)) == 1 && occursin("Subject: Filed", read(joinpath(dir, only(readdir(dir))), String))
    configure!(EMAIL_BACKEND = :dummy)
    @test send_mail("Dropped", "x", nothing, ["t@x.io"]) == 1
    configure!(EMAIL_BACKEND = :locmem, ADMINS = [("Admin", "admin@x.io")])
    empty!(outbox)
    mail_admins("Oops", "details")
    @test only(outbox).subject == "[Juango] Oops" && only(outbox).to == ["admin@x.io"]

    # 500 errors are mailed to ADMINS when DEBUG is off
    empty!(outbox)
    configure!(DEBUG = false)
    try
        @test get(c, "/boom/").status == 500
    finally
        configure!(DEBUG = true)
    end
    @test occursin("Internal Server Error: /boom/", only(outbox).subject) && occursin("boom", only(outbox).body)
    configure!(ADMINS = Any[])

    # SMTP against a tiny fake server
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    transcript = String[]
    srv = @async begin
        sock = Sockets.accept(server)
        write(sock, "220 fake ESMTP\r\n")
        indata = false
        while isopen(sock)
            l = readline(sock)
            push!(transcript, l)
            if indata
                l == "." && (indata = false; write(sock, "250 queued\r\n"))
            elseif startswith(l, "EHLO")
                write(sock, "250-fake\r\n250 AUTH PLAIN\r\n")
            elseif startswith(l, "AUTH")
                write(sock, "235 ok\r\n")
            elseif startswith(l, "DATA")
                indata = true; write(sock, "354 go\r\n")
            elseif startswith(l, "QUIT")
                write(sock, "221 bye\r\n"); close(sock)
            elseif !isempty(l)
                write(sock, "250 ok\r\n")
            end
        end
    end
    configure!(EMAIL_BACKEND = :smtp, EMAIL_HOST = "127.0.0.1", EMAIL_PORT = port, EMAIL_HOST_USER = "u", EMAIL_HOST_PASSWORD = "p")
    try
        @test send_mail("SMTP test", "hello", "Site <from@x.io>", ["to@x.io"]; html_message = "<b>hello</b>") == 1
        wait(srv)
    finally
        close(server)
        configure!(EMAIL_BACKEND = :locmem, EMAIL_HOST_USER = "", EMAIL_HOST_PASSWORD = "")
    end
    @test "MAIL FROM:<from@x.io>" in transcript && "RCPT TO:<to@x.io>" in transcript
    @test ("AUTH PLAIN " * Juango.base64encode("\0u\0p")) in transcript && "Subject: SMTP test" in transcript && "QUIT" in transcript

    # signing
    t = signing_dumps(Dict("a" => 1, "b" => [1, 2]))
    @test signing_loads(t) == Dict("a" => 1, "b" => [1, 2]) && signing_loads(t; max_age = 60)["a"] == 1
    @test_throws BadSignature signing_loads(t[1:end-1] * (t[end] == 'A' ? "B" : "A"))
    @test_throws BadSignature signing_loads(t; salt = "other")
    @test_throws SignatureExpired signing_loads(t; max_age = -1)
    @test unsign_value(sign_value("hello")) == "hello"
    @test_throws BadSignature unsign_value("hello:nope")

    # password reset
    u = create_user("resetme", "oldpassword1"; email = "reset@x.io")
    empty!(outbox)
    r = post(c, "/accounts/password_reset/", Dict("email" => "RESET@x.io"))
    @test r.status == 302 && getheader(r, "Location") == "/accounts/password_reset/done/"
    @test only(outbox).to == ["reset@x.io"] && only(outbox).subject == "Password reset on $(settings.SITE_NAME)"
    link = match(r"http://testserver(/accounts/reset/\S+/)", only(outbox).body)[1]
    @test occursin("resetme", only(outbox).body)
    @test post(c, "/accounts/password_reset/", Dict("email" => "nobody@x.io")).status == 302 && length(outbox) == 1
    @test occursin("Password reset sent", text(get(c, "/accounts/password_reset/done/")))
    @test occursin("Enter new password", text(get(c, link)))
    r = post(c, link, Dict("new_password1" => "newpassword9", "new_password2" => "different9"))
    @test occursin("didn’t match", text(r))
    r = post(c, link, Dict("new_password1" => "123", "new_password2" => "123"))
    @test occursin("too short", text(r)) && occursin("entirely numeric", text(r))
    r = post(c, link, Dict("new_password1" => "newpassword9", "new_password2" => "newpassword9"))
    @test r.status == 302 && getheader(r, "Location") == "/accounts/reset/done/"
    @test authenticate("resetme", "newpassword9") !== nothing && authenticate("resetme", "oldpassword1") === nothing
    @test occursin("unsuccessful", text(get(c, link)))                # used: the password hash changed
    @test !check_reset_token(get(User; id = u.id), "garbage") && occursin("unsuccessful", text(get(c, "/accounts/reset/xx/1-abc/")))
    @test check_reset_token(get(User; id = u.id), make_reset_token(get(User; id = u.id)))
end

@testset "caching" begin
    import Sockets
    old_caches = settings.CACHES
    try
        configure!(CACHES = Dict("default" => Dict(:backend => :locmem, :max_entries => 3, :timeout => 300),
                                 "nothing" => Dict(:backend => :dummy),
                                 "db" => Dict(:backend => :db, :location => "juango_cache_test")))
        cache_clear()
        @test cache_get("missing") === nothing && cache_get("missing", 7) == 7
        cache_set("a", Dict("x" => [1, 2]))
        v = cache_get("a"); push!(v["x"], 3)
        @test cache_get("a") == Dict("x" => [1, 2])                      # stored values are copies
        cache_set("short", 1; timeout = 2); cache_set("never", 1; timeout = 0)
        @test cache_has("short") && !cache_has("never")
        sleep(2.2)
        @test !cache_has("short")
        @test cache_add("k", 1) && !cache_add("k", 2) && cache_get("k") == 1
        @test cache_delete("k") && !cache_delete("k")
        calls = Ref(0)
        @test get_or_set("computed", () -> (calls[] += 1; 42)) == 42 && get_or_set("computed", () -> (calls[] += 1; 0)) == 42 && calls[] == 1
        cache_set("n", 10)
        @test incr("n") == 11 && incr("n", 5) == 16 && decr("n") == 15
        @test_throws KeyError incr("no such key")
        cache_set("v", "one"; version = 1); cache_set("v", "two"; version = 2)
        @test cache_get("v"; version = 1) == "one" && cache_get("v"; version = 2) == "two"
        cache_set("menu", "old")
        @test incr_version("menu") == 2 && cache_get("menu") === nothing && cache_get("menu"; version = 2) == "old"
        cache_clear()
        for k in ("p", "q", "r"); cache_set(k, 1); end
        cache_get("p")                                                    # p is now the most recently used
        cache_set("s", 1)                                                 # evicts q, the least recently used
        @test cache_has("p") && !cache_has("q") && cache_has("r") && cache_has("s")
        cache_set_many(Dict("m1" => 1, "m2" => 2))
        @test cache_get_many(["m1", "m2", "zz"]) == Dict("m1" => 1, "m2" => 2)
        longkey = repeat("long key ", 50)                                 # long or odd keys are hashed
        cache_set(longkey, 1)
        @test cache_get(longkey) == 1

        cache_set("x", 1; cache_name = "nothing")
        @test cache_get("x"; cache_name = "nothing") === nothing

        create_cache_table("db")
        @test Juango.table_exists(Juango.backend(), "juango_cache_test")
        cache_set("obj", (a = 1, b = "two", c = [1.5]); cache_name = "db")
        @test cache_get("obj"; cache_name = "db") == (a = 1, b = "two", c = [1.5])
        cache_set("obj", "replaced"; cache_name = "db")
        @test cache_get("obj"; cache_name = "db") == "replaced"
        cache_set("brief", 1; timeout = 1, cache_name = "db"); sleep(1.2)
        @test cache_get("brief"; cache_name = "db") === nothing
        cache_set("n", 1; cache_name = "db")
        @test incr("n"; cache_name = "db") == 2
        cache_clear(cache_name = "db")
        @test cache_get("obj"; cache_name = "db") === nothing
        Juango.execute("DROP TABLE " * Juango.qname("juango_cache_test"))

        # Redis, against a fake server speaking RESP
        server = Sockets.listen(Sockets.localhost, 0)
        port = Int(Sockets.getsockname(server)[2])
        store = Dict{String,String}()
        commands = String[]
        bulk(v) = v === nothing ? "\$-1\r\n" : string("\$", ncodeunits(v), "\r\n", v, "\r\n")
        srv = @async begin
            sock = Sockets.accept(server)
            while isopen(sock) && !eof(sock)
                args = Juango.resp_read(sock)
                cmd = uppercase(args[1])
                push!(commands, cmd)
                if cmd == "GET"
                    write(sock, bulk(get(store, args[2], nothing)))
                elseif cmd == "SET"
                    store[args[2]] = args[3]; write(sock, "+OK\r\n")
                elseif cmd == "DEL"
                    write(sock, string(":", pop!(store, args[2], nothing) === nothing ? 0 : 1, "\r\n"))
                elseif cmd == "FLUSHDB"
                    empty!(store); write(sock, "+OK\r\n")
                else
                    write(sock, "+OK\r\n")
                end
            end
        end
        configure!(CACHES = Dict("default" => Dict(:backend => :redis, :location => "redis://127.0.0.1:$port/2")))
        cache_set("r", Dict("deep" => [1, 2]); timeout = 60)
        @test cache_get("r") == Dict("deep" => [1, 2]) && cache_get("absent") === nothing
        @test cache_delete("r") && !cache_has("r")
        cache_set("n", 1)
        @test incr("n") == 2
        cache_clear()
        @test isempty(store) && "SELECT" in commands && "FLUSHDB" in commands
        configure!(CACHES = Dict("default" => Dict(:backend => :locmem)))     # closes the Redis connection
        close(server)

        # cached views and the per-site middleware
        hits = Ref(0)
        view = cache_page((req) -> (hits[] += 1; HttpResponse("page $(hits[])")); timeout = 60)
        req(path) = Request("GET", path; headers = Dict("host" => "testserver"))
        @test text(view(req("/c/"))) == "page 1" && text(view(req("/c/"))) == "page 1" && hits[] == 1
        @test occursin("max-age=60", getheader(view(req("/c/")), "Cache-Control"))
        @test text(view(req("/c/?page=2"))) == "page 2"
        cookie_view = cache_page((req) -> (hits[] += 1; r = HttpResponse("c"); set_cookie!(r, "x", "1"); r))
        cookie_view(req("/k/")); cookie_view(req("/k/"))
        @test hits[] == 4                                                  # responses setting cookies aren't cached
        mw = CacheMiddleware(r -> (hits[] += 1; HttpResponse("site")))
        mw(req("/m/")); mw(req("/m/"))
        @test hits[] == 5
        mw(Request("POST", "/m/"))
        @test hits[] == 6

        # {% cache %} template fragments
        tpl = "{% cache 60 \"sidebar\" uid %}{{ text }}{% endcache %}"
        @test tr(tpl, Dict("uid" => 1, "text" => "first")) == "first"
        @test tr(tpl, Dict("uid" => 1, "text" => "second")) == "first"
        @test tr(tpl, Dict("uid" => 2, "text" => "second")) == "second"

        # templates read once when TEMPLATE_CACHE_CHECK_MTIME is off
        tdir = mktempdir()
        write(joinpath(tdir, "cached.html"), "v1")
        old_dirs = settings.TEMPLATE_DIRS
        configure!(TEMPLATE_DIRS = vcat([tdir], old_dirs), TEMPLATE_CACHE_CHECK_MTIME = false)
        @test render_to_string("cached.html") == "v1"
        sleep(1.1); write(joinpath(tdir, "cached.html"), "v2")
        @test render_to_string("cached.html") == "v1"
        configure!(TEMPLATE_CACHE_CHECK_MTIME = true)
        @test render_to_string("cached.html") == "v2"
        configure!(TEMPLATE_DIRS = old_dirs)

        # cache-backed sessions
        for engine in (:cache, :cached_db)
            configure!(SESSION_ENGINE = engine)
            sess = Juango.Session(); sess["cart"] = [1, 2]
            Juango.save_session!(sess)
            @test Juango.load_session(sess.key)["cart"] == [1, 2]
            @test exists(filter(Juango.SessionRecord; session_key = sess.key)) == (engine === :cached_db)
            Juango.flush!(sess)
        end
        configure!(SESSION_ENGINE = :db)
        c = Client()
        force_login!(c, get(User; username = "root"))
        @test get(c, "/admin/").status == 200
    finally
        configure!(CACHES = old_caches, SESSION_ENGINE = :db)
    end
end

@testset "signals" begin
    log = Any[]
    function on_save(sender; instance, created, signal, kw...)
        push!(log, (signal.name, sender, instance isa Topic ? instance.name : instance, created))
    end
    on_delete(sender; instance, signal, kw...) = push!(log, (signal.name, sender, instance.name))
    connect!(pre_save, on_save; sender = Topic)
    connect!(post_save, on_save; sender = Topic)
    connect!(post_save, on_save; sender = Topic)                       # connecting twice has no effect
    connect!(pre_delete, on_delete; sender = Topic)
    connect!(post_delete, on_delete; sender = Topic)
    try
        t = create(Topic; name = "sig-a")
        @test log == [("pre_save", Topic, "sig-a", true), ("post_save", Topic, "sig-a", true)]
        empty!(log)
        t.name = "sig-b"; save!(t)
        @test log == [("pre_save", Topic, "sig-b", false), ("post_save", Topic, "sig-b", false)]
        empty!(log)
        create(Author; name = "Sig Author")                           # other senders don't reach these receivers
        @test isempty(log)
        delete!(t)
        @test log == [("pre_delete", Topic, "sig-b"), ("post_delete", Topic, "sig-b")]
        empty!(log)

        # cascaded deletes send signals too
        deleted = String[]
        on_art(sender; instance, kw...) = push!(deleted, instance.title)
        connect!(post_delete, on_art; sender = Article)
        a = create(Author; name = "Sig Cascade")
        create(Article; title = "sig-child", author = a)
        delete!(a)
        @test deleted == ["sig-child"]
        disconnect!(post_delete, on_art; sender = Article)

        # many-to-many changes
        changes = Any[]
        on_m2m(sender; action, instance, model, pk_set, reverse, kw...) = push!(changes, (action, instance isa Essay ? instance.title : instance.name, model, pk_set, reverse))
        through = Juango.through_model(only(Juango.modelmeta(Essay).m2m))
        connect!(m2m_changed, on_m2m; sender = through)
        e = create(Essay; title = "sig-essay")
        t1, t2 = create(Topic; name = "sig-t1"), create(Topic; name = "sig-t2")
        empty!(log)
        add!(e.topics, t1, t2)
        add!(e.topics, t1)                                               # nothing new: no signal
        remove!(e.topics, t2)
        clear!(t1.essays)
        @test changes == [(:pre_add, "sig-essay", Topic, Set([t1.id, t2.id]), false), (:post_add, "sig-essay", Topic, Set([t1.id, t2.id]), false),
                          (:pre_remove, "sig-essay", Topic, Set([t2.id]), false), (:post_remove, "sig-essay", Topic, Set([t2.id]), false),
                          (:pre_clear, "sig-t1", Essay, nothing, true), (:post_clear, "sig-t1", Essay, nothing, true)]
        disconnect!(m2m_changed, on_m2m; sender = through)

        # dispatch_uid, any sender, robust sending, do-block receivers
        sig = Signal("custom")
        seen = Any[]
        receiver(sig) do sender, args
            push!(seen, (sender, args.value))
            args.value * 2
        end
        connect!(sig, (s; kw...) -> error("broken receiver"); dispatch_uid = "broken")
        @test_throws ErrorException send(sig, :me; value = 1)
        res = send_robust(sig, :me; value = 2)
        @test last(res[1]) == 4 && last(res[2]) isa ErrorException && (:me, 2) in seen
        @test disconnect!(sig; dispatch_uid = "broken") && !disconnect!(sig; dispatch_uid = "broken")
        @test [last(r) for r in send(sig, :other; value = 5)] == [10]
        @test has_receivers(sig, :anyone) && !has_receivers(Signal(), :anyone)

        # requests and authentication
        events = Any[]
        rs(sender; request, kw...) = push!(events, (:started, request.path))
        rf(sender; request, response, kw...) = push!(events, (:finished, response.status))
        li(sender; request, user, kw...) = push!(events, (:in, user.username))
        lo(sender; request, user, kw...) = push!(events, (:out, user.username))
        lf(sender; credentials, kw...) = push!(events, (:failed, credentials["username"]))
        connect!(request_started, rs); connect!(request_finished, rf)
        connect!(user_logged_in, li; sender = User); connect!(user_logged_out, lo; sender = User)
        connect!(user_login_failed, lf; sender = :authenticate)
        create_user("sigu", "pw123456")
        c = Client()
        post(c, "/accounts/login/", Dict("username" => "sigu", "password" => "wrong"))
        post(c, "/accounts/login/", Dict("username" => "sigu", "password" => "pw123456"))
        post(c, "/accounts/logout/")
        @test (:started, "/accounts/login/") in events && (:finished, 302) in events
        @test (:failed, "sigu") in events && (:in, "sigu") in events && (:out, "sigu") in events
        @test !any(e -> e == (:failed, "pw123456"), events)
        foreach(((s, f),) -> disconnect!(s, f; sender = s === request_started || s === request_finished ? nothing : s === user_login_failed ? :authenticate : User),
                [(request_started, rs), (request_finished, rf), (user_logged_in, li), (user_logged_out, lo), (user_login_failed, lf)])
        @test !has_receivers(request_started, :handler)
    finally
        disconnect!(pre_save, on_save; sender = Topic); disconnect!(post_save, on_save; sender = Topic)
        disconnect!(pre_delete, on_delete; sender = Topic); disconnect!(post_delete, on_delete; sender = Topic)
    end
end

@testset "internationalisation" begin
    J = Juango
    # plural rules from Plural-Forms
    pl = J.plural_function("n==1 ? 0 : n%10>=2 && n%10<=4 && (n%100<10 || n%100>=20) ? 1 : 2")   # Polish
    @test [pl(n) for n in (1, 2, 4, 5, 12, 22, 25)] == [0, 1, 1, 2, 2, 1, 2]
    @test J.plural_function("(n != 1)")(1) == 0 && J.plural_function("n > 1")(0) == 0

    # .po and .mo round trips
    po = """
    msgid ""
    msgstr ""
    "Plural-Forms: nplurals=2; plural=(n > 1);\\n"

    #: x.jl
    msgid "Hello"
    msgstr "Bonjour"

    msgctxt "verb"
    msgid "Book"
    msgstr "Réserver"

    msgid "%(n)d apple"
    msgid_plural "%(n)d apples"
    msgstr[0] "%(n)d pomme"
    msgstr[1] "%(n)d pommes"

    msgid "%(n)s apple"
    msgid_plural "%(n)s apples"
    msgstr[0] "%(n)s pomme"
    msgstr[1] "%(n)s pommes"

    #, fuzzy
    msgid "Unsure"
    msgstr "Pas sûr"

    msgid "Multi"
    "line"
    msgstr "Multi\\n"
    "ligne"
    """
    es = J.parse_po(po)
    cat = J.catalog_from_entries(es)
    @test cat.messages[("", "Hello")] == ["Bonjour"] && cat.messages[("verb", "Book")] == ["Réserver"]
    @test cat.messages[("", "%(n)d apple")] == ["%(n)d pomme", "%(n)d pommes"] && !haskey(cat.messages, ("", "Unsure"))
    @test cat.messages[("", "Multiline")] == ["Multi\nligne"] && cat.plural(0) == 0 && cat.plural(2) == 1
    @test J.catalog_from_entries(J.read_mo(J.write_mo(es))).messages == cat.messages
    io = IOBuffer(); J.write_po(io, es; header = J.header_of(es))
    @test J.catalog_from_entries(J.parse_po(String(take!(io)))).messages == cat.messages

    # Juango's own German catalogue
    with_language("de") do
        @test gettext("This field is required.") == "Dieses Feld ist zwingend erforderlich."
        @test pgettext("abbrev. month", "Oct") == "Okt" && J.format_date(Date(2024, 10, 3), "l, j. F Y") == "Donnerstag, 3. Oktober 2024"
        @test tr("{{ d|date }}", Dict("d" => Date(2024, 3, 5))) == "5. März 2024"
        f = ModelForm(Author; data = Dict("name" => ""))
        @test !is_valid(f) && f.errors[:name] == ["Dieses Feld ist zwingend erforderlich."]
        @test get_language() == "de"
    end
    @test get_language() == "en" && gettext("This field is required.") == "This field is required."
    lazy = gettext_lazy("Save")
    @test lazy == "Save" && with_language(() -> string(lazy), "de") == "Sichern" && with_language(() -> uppercase(lazy), "de") == "SICHERN"
    fld = CharField(max_length = 10, verbose_name = gettext_lazy("Search"))
    fld.name = :q
    @test with_language(() -> J.label(fld), "de") == "Suchen" && J.label(fld) == "Search"
    @test interpolate("%(n)d items for %(who)s", Dict("n" => 3, "who" => "Ann")) == "3 items for Ann"

    # project catalogues in LOCALE_PATHS override Juango's own
    ldir = mktempdir()
    mkpath(joinpath(ldir, "fr", "LC_MESSAGES")); write(joinpath(ldir, "fr", "LC_MESSAGES", "juango.po"), po)
    mkpath(joinpath(ldir, "de", "LC_MESSAGES"))
    write(joinpath(ldir, "de", "LC_MESSAGES", "juango.po"), "msgid \"Save\"\nmsgstr \"Speichern\"\n")
    configure!(LOCALE_PATHS = [ldir])
    try
        with_language("fr") do
            @test gettext("Hello") == "Bonjour" && pgettext("verb", "Book") == "Réserver" && gettext("Book") == "Book"
            @test interpolate(ngettext("%(n)d apple", "%(n)d apples", 0), Dict("n" => 0)) == "0 pomme"
            @test interpolate(ngettext("%(n)d apple", "%(n)d apples", 3), Dict("n" => 3)) == "3 pommes"
            @test t"Hello" == "Bonjour"
        end
        with_language("de") do
            @test gettext("Save") == "Speichern" && gettext("Delete") == "Löschen"
        end
        @test with_language(() -> gettext("Hello"), "fr-ca") == "Bonjour"          # region falls back to the language

        # templates
        with_language("fr") do
            @test tr("{% load i18n %}{% translate \"Hello\" %} {% trans 'Book' context 'verb' %}") == "Bonjour Réserver"
            @test tr("{% translate \"Hello\" as hi %}[{{ hi }}]") == "[Bonjour]"
            @test tr("{% translate \"Hello\" noop %}") == "Hello"
            b = "{% blocktranslate count n=items|length %}{{ n }} apple{% plural %}{{ n }} apples{% endblocktranslate %}"
            @test tr(b, Dict("items" => [1])) == "1 pomme" && tr(b, Dict("items" => [1, 2, 3])) == "3 pommes"
            @test tr("{% blocktranslate with who=name %}Hi {{ who }}{% endblocktranslate %}", Dict("name" => "<b>")) == "Hi &lt;b&gt;"
            @test tr("{% get_current_language as L %}{{ L }}") == "fr"
            @test tr("{% language 'de' %}{% translate 'Save' %}{% endlanguage %} {% translate 'Hello' %}") == "Speichern Bonjour"
        end
        @test tr("{% blocktranslate trimmed %}\n  Hello\n{% endblocktranslate %}") == "Hello"
        @test tr("{{ x|localize }}", Dict("x" => 1234.5)) == "1234.5" && with_language(() -> tr("{{ x|localize }}", Dict("x" => 1234.5)), "de") == "1234,5"
        @test number_format(1234567.891; decimals = 2, lang = "de", grouping = true) == "1.234.567,89"
        @test number_format(-1234; lang = "en", grouping = true) == "-1,234"

        # makemessages / compilemessages
        proj = mktempdir()
        write(joinpath(proj, "views.jl"), """
            greet() = gettext("Hello")
            other() = t"World"
            cats(n) = ngettext("%(n)d cat", "%(n)d cats", n)
            book() = pgettext("verb", "Book")
            # gettext("not this one: a comment")
            """)
        mkpath(joinpath(proj, "templates"))
        write(joinpath(proj, "templates", "page.html"),
              "{% translate \"Title\" %}{% blocktranslate trimmed count n=k %}\n {{ n }} dog\n{% plural %}{{ n }} dogs{% endblocktranslate %}")
        out = makemessages("nl"; root = proj, locale_dir = joinpath(proj, "locale"))
        ids = Dict((e.context, e.msgid) => e for e in J.parse_po(read(out, String)))
        @test haskey(ids, ("", "Hello")) && haskey(ids, ("", "World")) && haskey(ids, ("verb", "Book")) && haskey(ids, ("", "Title"))
        @test ids[("", "%(n)d cat")].msgid_plural == "%(n)d cats" && ids[("", "%(n)s dog")].msgid_plural == "%(n)s dogs"
        @test !any(k -> occursin("comment", k[2]), keys(ids))
        write(out, replace(read(out, String), "msgid \"Hello\"\nmsgstr \"\"" => "msgid \"Hello\"\nmsgstr \"Hallo\""))
        makemessages("nl"; root = proj, locale_dir = joinpath(proj, "locale"))           # keeps translations
        @test occursin("msgstr \"Hallo\"", read(out, String))
        configure!(LOCALE_PATHS = [joinpath(proj, "locale")])
        @test only(compilemessages([joinpath(proj, "locale")])) == joinpath(dirname(out), "juango.mo")
        @test with_language(() -> gettext("Hello"), "nl") == "Hallo"
    finally
        configure!(LOCALE_PATHS = String[])
    end

    # choosing the language for a request
    hello(req) = HttpResponse(gettext("Save") * " " * reverse_url("i18n_hello") * " " * get_language())
    old_urls, old_mw = settings.ROOT_URLCONF, settings.MIDDLEWARE
    try
        configure!(ROOT_URLCONF = [i18n_patterns(path("hello/", hello; name = "i18n_hello")), path("i18n/", i18n_urls())],
                   MIDDLEWARE = vcat(old_mw, [LocaleMiddleware]))
        c = Client()
        r = get(c, "/de/hello/")
        @test text(r) == "Sichern /de/hello/ de" && getheader(r, "Content-Language") == "de"
        @test text(get(c, "/en/hello/")) == "Save /en/hello/ en"
        r = get(Client(; headers = Dict("Accept-Language" => "fr-CH, fr;q=0.9, de;q=0.8")), "/hello/")
        @test r.status == 302 && getheader(r, "Location") == "/fr/hello/"
        @test J.parse_accept_language("de;q=0.5, en-GB, *") == ["en-GB", "de"]
        r = post(c, "/i18n/setlang/", Dict("language" => "de", "next" => "/en/hello/"))
        @test r.status == 302 && getheader(r, "Location") == "/de/hello/" && c.cookies["juango_language"] == "de"
        @test getheader(get(c, "/hello/"), "Location") == "/de/hello/"                # the cookie wins now
        @test get(c, "/xx/hello/").status == 404
        configure!(ROOT_URLCONF = [i18n_patterns(path("hello/", hello; name = "i18n_hello"); prefix_default_language = false)])
        @test text(get(Client(), "/hello/")) == "Save /hello/ en" && text(get(Client(), "/de/hello/")) == "Sichern /de/hello/ de"
        @test get(Client(), "/en/hello/").status == 404

        # the admin in German
        configure!(ROOT_URLCONF = old_urls)
        ac = Client(; headers = Dict("Accept-Language" => "de"))
        force_login!(ac, get(User; username = "root"))
        r = get(ac, "/admin/")
        @test occursin("Website-Verwaltung", text(r)) && occursin("Neueste Aktionen", text(r)) && occursin("lang=\"de\"", text(r))
        @test occursin("Sichern und weiter bearbeiten", text(get(ac, "/admin/author/add/")))
    finally
        configure!(ROOT_URLCONF = old_urls, MIDDLEWARE = old_mw)
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
        @test ("migtest", "0001_initial", true) in rows && ("juango", "0001_initial", true) in rows
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
@testset "startproject" begin
    dir = mktempdir()
    root = redirect_stdout(devnull) do
        startproject("mysite"; dir = dir, develop = false)
    end
    @test isfile(joinpath(root, "manage.jl")) && isfile(joinpath(root, "templates", "home.html"))
end

end
