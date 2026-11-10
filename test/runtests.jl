using Test
using Juango
using Dates
import LibPQ    # loads the PostgreSQL driver extension

# JUANGO_TEST_DATABASE picks the database: unset for in-memory SQLite, a SQLite path or
# sqlite:/// URL, or a postgresql:// URL. For Postgres a fresh database juango_test_<pid>
# is created on that server and dropped afterwards; the database in the URL is untouched.
const TEST_DB_SETTING = get(ENV, "JUANGO_TEST_DATABASE", ":memory:")
const IS_POSTGRES = occursin(r"^postgres(ql)?://"i, TEST_DB_SETTING)
const TEST_DATABASE = if IS_POSTGRES
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
          :table_exists, :table_columns, :inline_foreign_keys)
    @eval Juango.$f(b::NumberedSQLite, args...) = Juango.$f(_sq(b), args...)
end
for T in (Bool, DateTime, Date)
    @eval Juango.adapt_param(b::NumberedSQLite, x::$T) = Juango.adapt_param(_sq(b), x)
end
Juango.sql_literal(b::NumberedSQLite, x::Bool) = Juango.sql_literal(_sq(b), x)
Juango.column_type(b::NumberedSQLite, kind::Symbol, ml) = Juango.column_type(_sq(b), kind, ml)
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
    @test values(filter(Article; id = a1.id), :title, :views) == [Dict(:title => "Julia rocks", :views => 10)]
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
    r = post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids)); follow = true)
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

@testset "database backends" begin
    B = Juango
    @test B.backend() isa (IS_POSTGRES ? B.PostgresBackend : B.SQLiteBackend)
    @test B.backend_from_setting("site.db") == B.SQLiteBackend("site.db")
    @test B.backend_from_setting("sqlite:///:memory:") == B.SQLiteBackend(":memory:")
    @test B.backend_from_setting("sqlite:////var/db/x.db") == B.SQLiteBackend("/var/db/x.db")
    @test B.backend_from_setting("postgresql://u@h/db") == B.PostgresBackend("postgresql://u@h/db")
    @test B.backend_from_setting("postgres://u@h/db") isa B.PostgresBackend
    @test_throws B.ImproperlyConfigured B.backend_from_setting("mysql://u@h/db")
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
    @test B.backend() isa (IS_POSTGRES ? B.PostgresBackend : B.SQLiteBackend)
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
        @test occursin("CREATE TABLE \"mig_post\"", sqlmigrate("migtest", "0001"))
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

@testset "startproject" begin
    dir = mktempdir()
    root = redirect_stdout(devnull) do
        startproject("mysite"; dir = dir, develop = false)
    end
    @test isfile(joinpath(root, "manage.jl")) && isfile(joinpath(root, "templates", "home.html"))
end

end
