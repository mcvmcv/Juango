# Shared setup for the test files: models, templates, URLs and the test database.
# Each file includes it once: `@isdefined(TEST_SETUP_DONE) || include("setup.jl")`.
using Test
using Juango, Juango.Testing, Juango.GIS, Juango.Postgres
# The tests cover the whole public API, so they use the public names that aren't exported too.
for n in names(Juango)
    Base.isexported(Juango, n) || n === :Juango || Core.eval(Main, :(using Juango: $n))
end
using Dates
using UUIDs: UUID, uuid4
const JSON = Juango.JSON

# JUANGO_TEST_DATABASE picks the database: unset for in-memory SQLite, a SQLite path or
# sqlite:/// URL, or a postgresql:// URL. For Postgres a fresh database juango_test_<pid>
# is created on that server and dropped afterwards; the database in the URL is untouched.
const TEST_DB_SETTING = get(ENV, "JUANGO_TEST_DATABASE", ":memory:")
const IS_POSTGRES = occursin(r"^postgres(ql)?://"i, TEST_DB_SETTING)
const IS_MYSQL = occursin(r"^(mysql|mariadb)://"i, TEST_DB_SETTING)
# Load only the driver in use: LibPQ's dependencies invalidate thousands of compiled methods,
# which costs every test file seconds of recompiling.
IS_POSTGRES && import LibPQ     # loads the PostgreSQL driver extension
IS_MYSQL && import MySQL        # loads the MySQL/MariaDB driver extension
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
          :translate_error, :autoincrement_pk, :limit_offset_sql,
          :table_exists, :table_columns, :inline_foreign_keys, :array_column_type)
    @eval Juango.$f(b::NumberedSQLite, args...) = Juango.$f(_sq(b), args...)
end
Juango.date_part_expr(b::NumberedSQLite, part::Symbol, col, kind) = Juango.date_part_expr(_sq(b), part, col, kind)
Juango.trunc_expr(b::NumberedSQLite, kind::Symbol, col, ink) = Juango.trunc_expr(_sq(b), kind, col, ink)
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
    friends = ManyToManyField(:self; blank = true, symmetrical = false)
    pals = ManyToManyField(:self; blank = true, related_name = :pal_of)
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
@model struct Delivery
    pizzeria = ForeignKey(Pizzeria, on_delete = :CASCADE, null = true)
    note = CharField(max_length = 20, default = "")
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
@model struct Shelf
    attrs = HStoreField(default = Dict, blank = true)
    label = CharField(max_length = 40, blank = true)
end
@model struct Reservation
    room = IntegerField()
    during = DateRangeField()
    cancelled = BooleanField(default = false)
    Meta(constraints = [ExclusionConstraint(name = "reservation_no_overlap", expressions = [(:during, "&&")],
                                            condition = Q(cancelled = false))])
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

# choices: enumerations, groups and callables
@choices Phase begin
    DRAFT = "d", "Draft"
    REVIEW = "r", gettext_lazy("In review")
    IN_PRINT = "p"
end
@choices Priority begin
    LOW = 1
    HIGH = 3, "High!"
end
const SHELVES = ["a", "b"]
@model struct Chapter
    phase = CharField(max_length = 1, choices = Phase, default = Phase.DRAFT)
    priority = IntegerField(choices = Priority, default = Priority.LOW)
    medium = CharField(max_length = 10, blank = true,
                       choices = ["Audio" => ["vinyl" => "Vinyl", "cd" => "CD"], "Video" => ["vhs" => "VHS"], "unknown" => "Unknown"])
    shelf = CharField(max_length = 10, blank = true, choices = () -> [s => uppercase(s) for s in SHELVES])
end

# on_delete = :RESTRICT, :SET_DEFAULT and SET(...) (Django's documentation example)
@model struct Band
    name = CharField(max_length = 20)
end
@model struct Record
    band = ForeignKey(Band, on_delete = :CASCADE)
    title = CharField(max_length = 20)
end
@model struct Track
    band = ForeignKey(Band, on_delete = :CASCADE)
    record = ForeignKey(Record, on_delete = :RESTRICT)
end
@model struct Venue
    name = CharField(max_length = 20, unique = true)
end
venue_tba() = (v = first(filter(Venue; name = "TBA")); v === nothing ? create(Venue; name = "TBA") : v).id
@model struct Gig
    venue = ForeignKey(Venue, on_delete = :SET_DEFAULT, default = venue_tba)
    backup = ForeignKey(Venue, on_delete = SET(venue_tba), null = true, blank = true, related_name = :backup_gigs)
end

const FILEPATH_DIR = mktempdir()
foreach(n -> write(joinpath(FILEPATH_DIR, n), "x"), ["a.txt", "b.txt", "c.log"])
mkpath(joinpath(FILEPATH_DIR, "sub")); write(joinpath(FILEPATH_DIR, "sub", "d.txt"), "x")

@model struct Device
    name = CharField(max_length = 20)
    ip = GenericIPAddressField(null = true, blank = true)
    ip6 = GenericIPAddressField(protocol = "IPv6", null = true, blank = true)
    mapped = GenericIPAddressField(unpack_ipv4 = true, null = true, blank = true)
    blob = BinaryField(null = true, max_length = 16)
    script = FilePathField(path = FILEPATH_DIR, match = r"\.txt$", blank = true)
    tree = FilePathField(path = FILEPATH_DIR, recursive = true, match = r"\.txt$", blank = true, max_length = 200)
end

@model struct Tally
    small = SmallIntegerField(default = 0)
    big = BigIntegerField(default = 0)
    count = PositiveIntegerField(default = 0)
    tiny = PositiveSmallIntegerField(default = 0)
    huge = PositiveBigIntegerField(default = 0)
end

@model struct Shift
    name = CharField(max_length = 20)
    starts = TimeField()
    stamp = TimeField(auto_now = true)
    opened = DateTimeField(null = true, blank = true)
    length = DurationField(null = true, blank = true)
end

@model struct Ledger
    label = CharField(max_length = 20)
    amount = DecimalField(max_digits = 8, decimal_places = 2)
    rate = DecimalField(max_digits = 30, decimal_places = 10, null = true, blank = true)
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

# Shared fixtures, created on first use so each test file also runs on its own.
"The superuser `root` (password `rootpw`)."
root_user() = (u = first(filter(User; username = "root")); u === nothing ? create_superuser("root", "rootpw") : u)
"The author `Ann`."
ann_author() = (a = first(filter(Author; name = "Ann")); a === nothing ? create(Author; name = "Ann", email = "ann@example.com") : a)

const TEST_SETUP_DONE = true
