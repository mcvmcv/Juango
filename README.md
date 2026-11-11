# Juango

**A Django-style web framework for Julia.**

Juango gives Julia the "batteries included" workflow from Django. If you know Django, you already know most of it:

| Django | Juango |
|---|---|
| `urls.py`, `path("posts/<int:id>/", view, name=...)` | `path("posts/<int:id>/", view; name=...)` |
| `reverse("blog:detail", kwargs={...})` | `reverse_url("blog:detail"; id=3)` |
| Django template language | Same syntax: `{% extends %}`, `{% block %}`, `{{ x\|date:"Y" }}`, autoescape… |
| `class Post(models.Model)` | `@model struct Post ... end` |
| `Post.objects.filter(title__icontains="x")` | `filter(Post; title__icontains="x")` |
| `Q(a=1) \| ~Q(b=2)` | `Q(a=1) \| !Q(b=2)` |
| `forms.Form`, `ModelForm` | `@form`, `ModelForm(Post; ...)` |
| sessions, auth, `@login_required`, CSRF, messages | sessions, auth, `login_required(view)`, CSRF, messages |
| `ListView`, `DetailView`, `CreateView`... | same names |
| `django.contrib.admin` | `Admin.register!(Post; list_display=..., search_fields=...)` |
| `manage.py makemigrations / migrate / showmigrations / sqlmigrate` | `manage.jl makemigrations / migrate / showmigrations / sqlmigrate` |
| `manage.py runserver / createsuperuser` | `manage.jl runserver / createsuperuser` |
| `django.test.Client` | `Client()` |

## Quick start

```julia
julia> using Juango
julia> startproject("mysite")
```

```sh
cd mysite
julia --project manage.jl makemigrations
julia --project manage.jl migrate
julia --project manage.jl createsuperuser
julia --project manage.jl runserver        # http://127.0.0.1:8000/  and  /admin/
```

Try the full example app:

```sh
cd examples/blog
julia --project -e 'using Pkg; Pkg.instantiate()'
julia --project manage.jl migrate
julia --project manage.jl seed             # demo user: demo / demo-pass
julia --project manage.jl runserver
```

## A tour

### Models and the ORM (SQLite)

```julia
using Juango

@model struct Author
    name  = CharField(max_length=100, unique=true)
    email = EmailField(blank=true)
end

@model struct Post
    title     = CharField(max_length=200)
    slug      = SlugField(unique=true)
    author    = ForeignKey(Author, on_delete=:CASCADE, related_name=:posts)
    body      = TextField()
    status    = CharField(max_length=1, choices=["d" => "Draft", "p" => "Published"], default="d")
    published = BooleanField(default=false)
    created   = DateTimeField(auto_now_add=true)
    Meta(ordering=["-created"])
end

Base.show(io::IO, p::Post) = print(io, p.title)               # like __str__
Juango.get_absolute_url(p::Post) = reverse_url("post"; slug=p.slug)

# julia --project manage.jl makemigrations && julia --project manage.jl migrate

ann  = create(Author; name="Ann")
post = create(Post; title="Hello", slug="hello", body="...", author=ann)

post.author.name                 # FK traversal (lazy)
count(ann.posts)                 # reverse relation
filter(Post; author__name="Ann", title__icontains="hel") |> order_by("-created")
filter(Post, Q(status="p") | Q(published=true))
exclude(Post; status="d")[1:10]  # slicing → LIMIT/OFFSET
get(Post; slug="hello")          # throws DoesNotExist / MultipleObjectsReturned
update!(filter(Post; author=ann); published=true)
aggregate(objects(Post), :count, :id)
get_or_create(Author; name="Bob", defaults=Dict(:email => "b@x.io"))
atomic() do                      # transaction; nested calls use savepoints
    save!(post); delete!(ann)    # on_delete: :CASCADE / :SET_NULL / :PROTECT / :DO_NOTHING
end
```

Lookups: `exact iexact contains icontains startswith istartswith endswith iendswith gt gte lt lte in isnull range year month day ne`, across relations (`author__name__iexact`) in both directions.

Lookups across relations compile to JOINs, following Django's rules:

- **Forward foreign keys** join once per path. The join is INNER when the column is NOT NULL and LEFT OUTER when it is nullable, so `Q(author__name="Ann") | Q(title="x")` still finds posts without an author.
- **Reverse relations** (`filter(Author; posts__published=true)`) add `DISTINCT`, so each author appears once.
- **Conditions in one `filter()` call must match the same related row.** `filter(Author; posts__title="x", posts__published=true)` needs one post that matches both. Chained calls, `filter(filter(Author; posts__title="x"); posts__published=true)`, may match different posts.
- **`exclude()` and `!Q(...)` use `EXISTS`**, so `exclude(Post; author__name="Ann")` keeps posts that have no author.
- **`order_by` follows foreign keys:** `order_by(qs, "author__name", "-created")`.

Avoid a query per row with `select_related` and `prefetch_related`:

```julia
posts = filter(Post; published=true) |> select_related(:author) |> prefetch_related(:comments)
for p in posts
    p.author.name          # loaded by the same query (JOIN)
    count(p.comments)      # loaded by one extra query for all posts
end
prefetch_related(objects(Author), :posts__comments)                 # follow relations further
prefetch_related(objects(Author), Prefetch(:posts; queryset=filter(Post; published=true), to_attr=:published_posts))
```

`select_related` follows forward foreign keys (`:author__profile` works too). `prefetch_related` handles reverse relations and forward foreign keys. A prefetched relation answers iteration, `count`, `first` and `exists` from memory. Filtering it further queries the database again.

#### Many-to-many

```julia
@model struct Post
    title = CharField(max_length=200)
    tags  = ManyToManyField(Tag; related_name=:posts, blank=true)
end

add!(post.tags, julia, web)      # objects or ids; existing links are skipped
remove!(post.tags, web)
set!(post.tags, [julia, db])
clear!(post.tags)
post.tags                        # QuerySet{Tag};   tag.posts is QuerySet{Post}
filter(Post; tags__name="julia")                  # lookups in both directions
prefetch_related(objects(Post), :tags)            # 2 extra queries for any number of posts
```

- **Join table.** Juango creates a join table (`post_tags`, unique per pair) that migrations manage like any other table. Deleting either side removes its links.
- **Custom intermediate model.** Use `through=:Membership` for one with extra fields, and fill those fields with `add!(club.members, ann; through_defaults=Dict(:role => "chair"))`.
- **Self-referential relations.** `ManyToManyField(:self)` works but isn't symmetrical: adding Bob to Ann's friends doesn't add Ann to Bob's.
- **Forms and admin.** `ModelForm` renders a multiple select and `save!(form)` saves the relation. After `save!(form; commit=false)`, call `save_m2m!(form)` once the object is saved. The admin does this for you.
- **`unique_together`.** `Meta(unique_together=[(:code, :batch)])` adds a multi-column unique constraint, and migrations track it (`AlterUniqueTogether`).

#### Expressions, annotations and aggregation

```julia
update!(filter(Post; id=1); views = F(:views) + 1)              # atomic increment, no race
filter(Post; updated__gt = F(:created))                         # compare columns
annotate(objects(Author); n = Count(:posts)) |> filter(n__gt = 2) |> order_by("-n")   # GROUP BY / HAVING
annotate(objects(Author); published = Count(:posts; filter = Q(posts__published = true)))
values(objects(Post), :status) |> annotate(n = Count())        # rows like Dict(:status => "p", :n => 12)
aggregate(objects(Post); total = Sum(:views), avg = Avg(:views))   # Dict(:total => ..., :avg => ...)
values_list(objects(Post), :title, :author__name)               # tuples; flat=true for one field
```

- **Aggregates:** `Count`, `Sum`, `Avg`, `Min`, `Max`, with `distinct=` and `filter=`.
- **Functions:** `Lower`, `Upper`, `Length`, `Coalesce`, `Concat`, `Cast(x, :float)`, `Now()`, and `ExtractYear`/`ExtractMonth`/`ExtractDay`.
- **Conditionals:** `Case(When(; views__gte=100, then="hot"); default="cold")`.
- **Arguments:** strings and symbols inside functions are field names, and they can follow relations (`:author__name`). Wrap literals in `Value("...")`.
- **Subqueries:**
  - `annotate(objects(Author); latest = Subquery(values(order_by(filter(Post; author=OuterRef(:id)), "-created"), :title)[1:1]))`
  - `filter(objects(Author), Exists(filter(Post; author=OuterRef(:id))))`, negated with `!Exists(...)`
- **Window functions:** `annotate(qs; rank = Window(RowNumber(); partition_by=[:author], order_by=["-views"]))`, also with `Rank`, `DenseRank`, `Lag`, `Lead` and aggregates over a window. You can order by them but not filter on them.
- **`values()` is lazy.** It returns a queryset whose rows are `Dict`s. Aggregates in `annotate` after `values(:field)` group by that field. As in Django, combining aggregates over two different reverse relations multiplies rows, so use `distinct=true`.

#### GIS (PostGIS)

```julia
@model struct City
    name     = CharField(max_length = 100)
    location = PointField()                       # SRID 4326; also LineString/Polygon/Multi*/GeometryField
end
@model struct Region
    area = PolygonField()                         # geography = true for a geography column
end

near = Point(174.78, -41.29)                      # (longitude, latitude)
filter(City; location__within = region.area)      # also intersects, contains, covers, disjoint, touches, ...
filter(City; location__distance_lte = (near, D(km = 50)))          # D(m=...), D(mi=...)
filter(City; location__dwithin = (near, D(km = 350)))
order_by(annotate(objects(City); d = Distance(:location, near)), "d")   # metres
annotate(objects(Region); a = Area(:area))                          # square metres; also GeoLength, AsGeoJSON
geojson(objects(City); geometry = :location, properties = [:name])  # a FeatureCollection Dict
```

- **Geometry values.** `Point`, `LineString`, `Polygon`, `MultiPoint`, `MultiLineString` and `MultiPolygon` are plain Julia values. They read and write WKT/EWKT (`wkt`, `ewkt`, `parse_wkt`), GeoJSON (`geojson`, `from_geojson`) and WKB (`parse_wkb`). PostGIS does the spatial work.
- **Units.** Distances and areas for SRID 4326 and geography columns are geodetic (metres). Other SRIDs use their own units, and geometries in another SRID are transformed automatically.
- **Indexes and setup.** Geometry columns get a GiST index, and the `postgis` extension is created the first time a table needs it.
- **Forms and admin.** Forms accept WKT or GeoJSON. The admin shows a Leaflet map, and clicking it sets a point. The map loads Leaflet 1.9.4 from unpkg and tiles from OpenStreetMap.
- **Other databases.** GIS fields need PostgreSQL with PostGIS. On other databases they raise an error.

#### Managers

```julia
Juango.default_queryset(::Type{Post}) = filter(base_objects(Post); deleted = false)   # hide soft-deleted rows
Juango.manager(::Type{Post}, ::Val{:published}) = filter(Post; status = "p")          # objects(Post, :published)
published(qs::QuerySet{Post}) = filter(qs; status = "p")                              # chainable method:
objects(Post) |> published |> order_by("-created")
```

- **`default_queryset`** is what `objects`, `filter(Model; ...)`, reverse relations and the admin see. Build it on `base_objects(Model)`, never on `objects(Model)`, which would recurse.
- **`base_objects`** is the unfiltered table. Foreign-key access, cascading deletes and uniqueness checks always use it, like Django's base manager.
- **Admin:** `Admin.register!(Post; queryset = req -> ...)` sets what the admin lists and edits.

#### Model inheritance

```julia
@abstract_model struct TimeStamped            # no table; fields and Meta are inherited
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["-created"])
end
@model struct Post <: TimeStamped
    title = CharField(max_length = 200)
end

@model struct Place                           # multi-table: each subclass adds a table
    name = CharField(max_length = 50)
end
@model struct Restaurant <: Place             # id is also a foreign key to place.id
    serves_pizza = BooleanField()
end
filter(Restaurant; name = "Napoli")           # parent fields work everywhere (JOIN)
place.restaurant; restaurant.place_ptr        # the other part of the same row, or nothing

@model struct BigPlace <: Place               # proxy: same table, own type, manager and admin
    Meta(proxy = true, ordering = ["-name"])
end

@model struct Profile
    user = OneToOneField(User)                # user.profile is an object (or nothing)
end
```

- **Abstract models** can extend each other.
- **Multi-table children:** saving writes every table in one transaction, deleting a child removes its parent row too, and `update!` splits across the tables. Reverse relations and lookups of the parent work from the child.
- **Migrations** create child tables with `parent = "place"`.

#### Generic relations

```julia
@model struct Comment
    content_type   = ForeignKey(ContentType)
    object_id      = IntegerField()
    content_object = GenericForeignKey()      # points at any model
    text           = TextField()
end
@model struct Post
    title    = CharField(max_length = 100)
    comments = GenericRelation(:Comment)      # post.comments, filter(Post; comments__text = "x")
end
create(Comment; content_object = post, text = "Nice")
get_for_model(Post), model_class(ct)          # ContentType <-> model
```

- **Content types:** `migrate` fills the `ContentType` table, whose migration ships with Juango.
- **`GenericRelation`** supports lookups (the join also matches the content type), `Count(:comments)`, `prefetch_related(:comments)`, and deleting the object deletes its comments. `prefetch_related(:content_object)` loads mixed targets with one query per model.

#### JSON, arrays, UUIDs, ranges and full-text search

```julia
@model struct Event
    data   = JSONField(default = Dict)                  # jsonb on Postgres, JSON text on SQLite
    tags   = ArrayField(CharField(max_length = 20); default = Vector{String})
    token  = UUIDField(default = uuid4)
    email  = CICharField(max_length = 200)              # case-insensitive (citext / NOCASE)
    ages   = IntegerRangeField(null = true)             # also DateRangeField, DateTimeRangeField
    Meta(indexes = [GinIndex(:data), Index(:email; name = "event_email", unique = true)])
end

filter(Event; data__owner__name = "Ann", data__score__gt = 5)   # JSON key paths (numbers compare as numbers)
filter(Event; data__contains = Dict("active" => true), data__has_key = "owner")
filter(Event; tags__contains = ["julia"], tags__overlap = ["a", "b"], tags__len__gte = 2, tags__0 = "x")
filter(Event; ages__contains = 30, ages__overlap = ValueRange(20, 40))
filter(Post; body__search = "julia web")                        # full-text lookup
annotate(qs; s = SearchVector(:title; weight = "A") + SearchVector(:body)) |> filter(s = SearchQuery("julia"))
order_by(annotate(qs; rank = SearchRank(SearchVector(:title, :body), SearchQuery("julia"))), "-rank")
```

- **Both databases:** these fields and lookups work on Postgres and SQLite. SQLite stores them as JSON text and answers the lookups with its JSON functions. Two limits there: JSON `contains` takes a `Dict` of plain values, and JSON `contained_by` needs Postgres.
- **Full-text search:** `SearchVector`, `SearchQuery` (`search_type = :plain | :phrase | :websearch | :raw`) and `SearchRank` need Postgres. On SQLite the `__search` lookup falls back to matching every word.
- **Ranges:** values are `ValueRange(lower, upper; bounds = "[)")`. Integer and date ranges are stored in canonical `[)` form, as Postgres does.
- **UUID primary keys:** `Meta(pk = :uuid)` makes `id` a UUID created by Juango. Foreign keys to such a model use UUID columns, and the admin accepts UUIDs in URLs.
- **Indexes:** `Meta(indexes = [...])` adds named indexes, and migrations track them with `AddIndex`/`RemoveIndex`. GIN indexes apply on Postgres only.
- **Postgres extension:** `CICharField` creates the `citext` extension the first time a table needs it.

Computed attributes for templates (and `obj.name` in Julia) use `tattr`:

```julia
Juango.tattr(p::Post, ::Val{:summary}) = first(p.body, 100)
```

### Apps

An app bundles models, views, URLs, templates, static files, translations, migrations and management commands, so a project can install it as a unit. `julia --project manage.jl startapp blog` creates one:

```
blog/
  Blog.jl          module Blog; const APP = App("blog"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)
  models.jl  admin.jl  views.jl  urls.jl  tests.jl
  templates/blog/  static/blog/  migrations/
```

Install it in `project.jl` and the settings:

```julia
include(joinpath(BASE_DIR, "blog", "Blog.jl")); using .Blog

configure!(INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions",
                             "juango.messages", Blog.APP], ...)
urlpatterns = [path("blog/", include_urls(Blog.APP)), ...]     # namespaced: {% url 'blog:index' %}
```

- **Models** defined in the app's module get its label: `model_label(Blog.Post) == "blog.Post"` and `get_model("blog.post")`. The label also applies to content types and permission names (`blog.add_post`).
- **Migrations** go in `blog/migrations/`. `makemigrations blog` writes them there, and plain `makemigrations` covers the project and every installed app.
- **Templates, static files and translations** are found in each app's `templates/`, `static/` and `locale/`, after the project's own directories. Set `APP_DIRS = false` to turn this off. `collectstatic` copies every static file into `STATIC_ROOT` for production.
- **`ready`** (`App(...; ready = () -> connect!(post_save, ...))`) runs once, when the app is installed. Use it to connect signals.
- **Commands**: `App(...; commands = Dict("import_posts" => ("Import posts from a feed", args -> ...)))` adds `manage.jl import_posts`.
- **`requires`** lists other apps that must be installed. `manage.jl check` reports any that are missing.

Juango's own features are apps too: `juango.admin`, `juango.auth`, `juango.contenttypes`, `juango.sessions` and `juango.messages`. A project can leave any of them out, which removes that app's URLs (`Admin.urls()` and `auth_urls()` refuse to run), commands (`createsuperuser`, `changepassword`, `clearsessions`) and dependency checks. Their models stay in one `juango` migration history, so their tables are created anyway. `installed_apps()`, `is_installed("blog")`, `get_app("blog")` and `app_models("blog")` query the registry.

### Migrations

Migrations are versioned, reviewable files that move the database schema forwards and backwards:

```sh
julia --project manage.jl makemigrations          # writes migrations/0002_add_post_status.jl
julia --project manage.jl sqlmigrate 0002         # the SQL it will run (--backwards for the reverse)
julia --project manage.jl migrate                 # apply everything pending
julia --project manage.jl migrate 0001            # go back to 0001, unapplying 0002 and later
julia --project manage.jl migrate zero            # unapply all of the project's migrations
julia --project manage.jl showmigrations          # [X] applied, [ ] pending
```

`makemigrations` compares your models with the state the existing migration files describe and writes the difference as operations. These are `CreateModel`, `DeleteModel`, `RenameModel`, `AddField`, `RemoveField`, `AlterField` and `RenameField`. When a column (or table) disappears and an identical one appears under a new name, it asks whether you renamed it. With `--noinput` the answer is no. A generated file looks like this:

```julia
using Juango.Migrations

Migration(
    dependencies = [("project", "0001_initial")],
    operations = [
        RenameField("post", "title", "headline"),
        AddField("post", Column("status", :string; default = "d", max_length = 1)),
    ],
)
```

- **Data migrations.** `makemigrations --empty --name backfill` writes a file to fill in with `RunSQL(forward, backward)` or `RunJulia(forward_fn, backward_fn)`. Prefer raw SQL (`Juango.execute`) inside `RunJulia`. The ORM uses today's model definitions, which may not match the schema at that point in history.
- **Transactions.** Each migration runs in a transaction. If it fails, nothing is applied.
- **SQLite.** SQLite can't alter or drop columns in place, so those changes rebuild the table: create a copy, move the rows, then swap. On Postgres they are ordinary `ALTER TABLE` statements.
- **Backfill.** Adding a NOT NULL column without a default fills existing rows with `""`, `0`, `false` or 1970-01-01, and `makemigrations` says so.
- **Conflicts.** Two branches that both added a migration conflict. `migrate` refuses to run, and `makemigrations --merge` writes a merge migration.
- **Checking in CI.** `makemigrations --check` exits with status 1 if models have changes without a migration.
- **What's tracked.** Only schema attributes are tracked: column type, `null`, database default, `unique`, `db_index` and the foreign key target. Changing `choices`, `help_text` or validators never creates a migration.

**Apps.** Juango's built-in tables (`auth_user`, `juango_session`) are the `juango` app, and their migrations ship with Juango. Your models are the `project` app, stored in `settings.MIGRATIONS_DIR` (`startproject` sets it to `<project>/migrations`). A model can opt into another app with `Meta(app_label = "billing")` plus `MIGRATION_MODULES = Dict("billing" => "path/to/dir")`. Full reusable apps are [#29](https://github.com/mcvmcv/Juango/issues/29).

**No migration files yet?** An app without migration files is synchronised: missing tables and columns are created and nothing is altered, which is how Juango worked before migrations existed. `migrate --sync` does that for every app. When you switch an existing database over, run `makemigrations`, then `migrate`. Initial migrations whose tables already exist are marked as applied ("FAKED") instead of run. `migrate --fake` records migrations without running them, as in Django.

### Database backends

The ORM talks to the database through a `DatabaseBackend`. Each backend supplies the driver calls, its SQL dialect (quoting, column types, lookups, `LIMIT`, inserts that return ids) and the introspection that `migrate()` needs. SQL is written by hand, with no query builder in between.

```julia
configure!(DATABASE = "db.sqlite3")             # SQLite file (the default backend)
configure!(DATABASE = ":memory:")               # in-memory SQLite
configure!(DATABASE = "sqlite:///db.sqlite3")   # the same, as a URL
configure!(DATABASE = "postgresql://user:pass@localhost:5432/mydb")   # PostgreSQL (needs LibPQ, below)
configure!(DATABASE = MyBackend(...))           # any DatabaseBackend instance
```

#### MySQL and MariaDB

```sh
julia --project -e 'using Pkg; Pkg.add("MySQL")'
```

```julia
using Juango
using MySQL          # loads Juango's MySQL driver
configure!(DATABASE = "mysql://user:password@localhost:3306/mydb")    # or mariadb://
```

Each connection sets `sql_mode` (`ANSI_QUOTES`, `PIPES_AS_CONCAT`, `NO_BACKSLASH_ESCAPES`, `STRICT_TRANS_TABLES`), so queries mean the same as on the other databases. Some differences remain:

- **Case-insensitive `exact`.** String comparisons follow the column collation, which is case-insensitive by default, so `exact` ignores case, as in Django on MySQL. `contains`, `startswith` and `endswith` are case-sensitive.
- **No transactional DDL.** A migration that fails halfway keeps the steps that already ran.
- **JSON storage.** `JSONField` uses JSON columns, and arrays and ranges are stored as JSON with the same lookups.
- **No full-text search expressions.** The `__search` lookup matches words instead, and GIN indexes are skipped.
- **Tested on MariaDB 11.** MySQL 8 should work, but `DROP INDEX IF EXISTS`, used by some migrations, is MariaDB-only.

#### Connections

PostgreSQL and MySQL use a connection pool, and SQLite uses one shared connection.

- **Sharing.** A query borrows a connection and returns it. Queries from different tasks run at the same time, because the Postgres driver waits cooperatively and MySQL.jl uses Julia sockets.
- **Transactions.** `atomic` keeps one connection for its task until the transaction ends, so other tasks don't see its changes until it commits. Tasks you start inside a transaction get their own connections.
- **Settings:**
  - `DATABASE_POOL_SIZE` (10): connections per process.
  - `DATABASE_POOL_TIMEOUT` (30 s): how long to wait for a free connection before raising `PoolTimeout`.
  - `CONN_MAX_AGE` (600 s): close connections idle longer than this (`0` closes after every use, `nothing` keeps them).
  - `CONN_HEALTH_CHECKS` (true): ping a connection that sat idle before reusing it, so connections dropped by a server restart are replaced.
- **Monitoring.** `pool_status()` reports the pool's size and how many connections are in use and idle.

#### PostgreSQL

PostgreSQL goes through [LibPQ.jl](https://github.com/JuliaDatabases/LibPQ.jl). LibPQ is an optional dependency, so SQLite-only projects never install it. To use Postgres:

```sh
julia --project -e 'using Pkg; Pkg.add("LibPQ")'
```

```julia
using Juango
using LibPQ          # loads Juango's PostgreSQL driver
configure!(DATABASE = "postgresql://user:pass@localhost:5432/mydb")
```

The database must already exist (`createdb mydb`). `migrate()` creates the tables. Postgres uses native types: `BOOLEAN`, `TIMESTAMP`, `DATE`, `DOUBLE PRECISION`, `BIGINT` identity primary keys, and `VARCHAR(n)` for `CharField(max_length=n)`. Foreign keys become real constraints (`DEFERRABLE INITIALLY DEFERRED`). Deletes still cascade through the ORM according to `on_delete`, so `:DO_NOTHING` raises `IntegrityError` while referencing rows still exist. Case-insensitive lookups use `ILIKE`.

SQLite stores booleans as 0/1 and timestamps as ISO-8601 text. The ORM converts both ways, so model code doesn't change between backends.

Write raw SQL with `?` placeholders: `Juango.execute("SELECT * FROM post WHERE id = ?", [1])`. Each backend rewrites `?` into its own placeholder style. Constraint violations raise `IntegrityError` on every backend.

To add a backend, subtype `Juango.DatabaseBackend`, implement the driver methods, override any dialect methods that differ from standard SQL, and call `register_backend!("scheme", url -> MyBackend(url))`. The interface is documented at the top of `src/db.jl`. `src/backends/sqlite.jl` and `src/backends/postgres.jl` (with its driver in `ext/JuangoLibPQExt.jl`) are the two implementations.

Run the test suite against another database with `JUANGO_TEST_DATABASE`:

```sh
JUANGO_TEST_DATABASE=postgresql://localhost/postgres julia --project -e 'using Pkg; Pkg.test()'
```

For Postgres, the tests create a throwaway database `juango_test_<pid>` on that server and drop it afterwards. They never touch the database named in the URL.

### URLs and views

Views are plain functions `req -> response`. URL captures arrive as keyword arguments. A view may also return a `String` (HTML) or a `Dict`/`Vector`, which becomes JSON.

```julia
home(req) = render(req, "home.html", Dict("posts" => filter(Post; published=true)))
post_detail(req; slug) = render(req, "post.html", Dict("post" => get_object_or_404(Post; slug)))
api(req) = [Dict("title" => p.title) for p in objects(Post)]

urlpatterns = [
    path("", home; name="home"),
    path("posts/<slug:slug>/", post_detail; name="post"),
    path("posts/new/", login_required(CreateView(Post; fields=[:title, :slug, :body, :author])); name="post_new"),
    path("api/posts/", require_GET(api)),
    path("blog/", include_urls(blog_patterns; namespace="blog")),
    path("accounts/", Juango.auth_urls()),      # login / logout views
    path("admin/", Admin.urls()),
]

configure!(ROOT_URLCONF=urlpatterns, DATABASE="db.sqlite3", TEMPLATE_DIRS=["templates"])
```

Converters: `str int slug path uuid`, plus `register_converter!`.

### Streaming, server-sent events and WebSockets

A streaming response sends its body while it is produced, so it never has to sit in memory whole.

```julia
export_csv(req) = StreamingHttpResponse(content_type = "text/csv") do io
    for p in objects(Post)                      # each write goes out as a chunk
        println(io, p.id, ",", p.title)
    end
end
report(req; name) = FileResponse(joinpath("reports", name); as_attachment = true)   # 64 KiB at a time

ticker(req) = EventStreamResponse() do io       # text/event-stream, not buffered by proxies
    for i in 1:10
        write(io, sse_event(Dict("n" => i); event = "tick", id = i))
        sleep(1)
    end
end

chat = websocket() do ws, req                   # sessions and req.user are loaded as usual
    for msg in ws                               # String for text frames, Vector{UInt8} for binary
        ws_send(ws, "$(req.user.username): $msg")
    end
end
room(ws, req; name) = ws_send(ws, "welcome to $name")          # URL parameters arrive as keywords

urlpatterns = [path("posts.csv", export_csv), path("reports/<str:name>", report), path("ticks/", ticker),
               path("ws/chat/", login_required(chat)), path("ws/room/<slug:name>/", websocket(room))]
```

`StreamingHttpResponse` also takes any iterable of strings or bytes (a generator, a `Channel`). The body is produced in the view's language and time zone. The test client reads streams to the end when you call `text(resp)`, and `is_streaming(resp)` tells you if it hasn't yet. Streaming responses are never cached.

A WebSocket handshake goes through the middleware like any request, so `login_required` and friends can refuse it. The browser's `Origin` must be the site itself or listed in `CSRF_TRUSTED_ORIGINS`, so other sites can't open sockets with a visitor's cookies. A plain GET to a WebSocket URL gets 426 Upgrade Required. Pass `websocket(handler; subprotocols = ["chat.v1"])` to negotiate a subprotocol.

**Concurrency.** `runserver` handles each connection in its own task, so a slow view, a sleeping event stream or an open WebSocket doesn't hold up other requests. Database queries on PostgreSQL wait cooperatively, so other tasks run meanwhile, and each task gets its own pooled connection (see Database backends). Start Julia with threads (`julia -t auto manage.jl runserver`) and the views also run in parallel on all cores. The shared caches (templates, URL reversing, content types, translations and cache backends) are protected by locks. A view can start its own work with `Threads.@spawn`, and the spawned task takes its own database connection.

### Templates

This is the Django template language. Tags: `if/elif/else` (with `and or not in == != < > <= >= is`), `for … empty` (with `forloop.*` and `reversed`), `extends`/`block` (with `block.super`), `include … with … only`, `with`, `url … as`, `csrf_token`, `static`, `cycle`, `firstof`, `now`, `comment`, `verbatim`, `spaceless`, `autoescape`, `load`.

There are 40+ filters, including `date timesince default length join truncatechars truncatewords linebreaks linebreaksbr pluralize add yesno slugify floatformat urlize json_script safe escape …`. Add your own with `register_filter!("name", (value, arg) -> ...)`. Add custom tags with `register_tag!`.

Output is HTML-escaped unless you mark it safe (`mark_safe`, `|safe`).

### Forms

```julia
@form ContactForm begin
    name    = CharField(max_length=100)
    email   = EmailField()
    message = TextField(validators=[s -> length(s) > 10 || "Too short."])
end

function contact(req)
    form = ContactForm(req.method == "POST" ? req.POST : nothing)
    if req.method == "POST" && is_valid(form)
        send_mail(form.cleaned_data[:email], ...)
        message!(req, :success, "Thanks!")
        return redirect("contact")
    end
    render(req, "contact.html", Dict("form" => form))   # {{ form }} / {{ form.as_p }} / {{ form.email }}
end

form = ModelForm(Post; data=req.POST, instance=post, fields=[:title, :body])
is_valid(form) && save!(form)
```

For cross-field validation, define `Juango.clean_form(f::Form, ::Val{:ContactForm})` and call `add_error!`.

### Formsets

```julia
LineFormSet = formset_factory(LineForm; extra = 2, can_delete = true, can_order = true,
                              min_num = 1, validate_min = true, clean = fs -> ...)
fs = LineFormSet(req.method == "POST" ? req.POST : nothing; initial = [Dict(:name => "a")])
is_valid(fs) && cleaned_data(fs)            # one Dict per filled-in, non-deleted form

PostFormSet = modelformset_factory(Post; fields = [:title, :published], extra = 1, can_delete = true)
fs = PostFormSet(req.POST; queryset = filter(Post; author = req.user))
is_valid(fs) && save!(fs)                   # fs.new_objects, fs.changed_objects, fs.deleted_objects

CommentFormSet = inlineformset_factory(Post, Comment; fields = [:name, :body], extra = 3)
fs = CommentFormSet(req.POST; instance = post)   # the foreign key to the post is set on save
```

```
<form method="post">{% csrf_token %}
  {{ formset.management_form }}
  {% for form in formset %}{{ form.as_p }}{% endfor %}
</form>
```

- **What's skipped.** Blank extra forms are ignored. Forms marked `DELETE` are skipped, and unchanged objects aren't re-saved.
- **Model formsets** carry a hidden `id` per form. Ids are matched against the queryset, so a tampered id can't reach other rows.
- **`formset.empty_form`** renders a form with `__prefix__` in place of the index, for adding rows with JavaScript.
- **`add_error!(formset, msg)`** adds a formset-wide error from a `clean` function.

### File uploads

```julia
configure!(MEDIA_ROOT = joinpath(BASE_DIR, "media"), MEDIA_URL = "/media/")   # startproject sets MEDIA_ROOT

@model struct Document
    title  = CharField(max_length = 100)
    file   = FileField(upload_to = "docs/%Y/%m/", validators = [FileExtensionValidator(["pdf"]), MaxFileSizeValidator(5_000_000)])
    cover  = ImageField(upload_to = "covers/", blank = true, width_field = :cover_w, height_field = :cover_h)
    cover_w = IntegerField(null = true, editable = false)
    cover_h = IntegerField(null = true, editable = false)
end

form = ModelForm(Document; data = req.POST, files = req.FILES)    # <form enctype="multipart/form-data">
is_valid(form) && save!(form)
doc.file.url, doc.file.size, doc.file.path, read(doc.file), doc.cover.width
create(Document; title = "x", file = req.FILES["file"])           # an UploadedFile is stored by save!
```

- **Uploads.** `req.FILES` holds the uploads (`getlist` for `multiple` inputs). Each is an `UploadedFile` with a name, content type, size and bytes.
- **Storage.** Files go through a storage: `FileSystemStorage` by default, or set `DEFAULT_FILE_STORAGE` for another. It provides `save_file`, `read`, `delete_file`, `url`, `size` and `path`.
- **Safe file names.** Names are sanitised, can't escape `MEDIA_ROOT`, and never overwrite: an existing name gets a random suffix.
- **Images.** `ImageField` accepts PNG, GIF, JPEG and WebP. Juango reads the size itself, so no image library is needed.
- **Forms and admin.** Forms show the current file with a "Clear" checkbox when the field is optional, and the admin handles uploads.
- **Testing.** The test client uploads when the data contains an `UploadedFile`: `post(c, url, Dict("file" => UploadedFile("a.txt", "hi")))`.
- **Serving.** With `DEBUG`, the development server serves `MEDIA_URL`. In production, serve `MEDIA_ROOT` from your web server.
- **Deleting objects keeps their files**, as in Django. Use `delete_file` to remove them.

### Auth, sessions, CSRF, messages

- `User` model with PBKDF2-SHA256 password hashes in Django's format, so existing Django hashes verify.
- `authenticate`, `login!`, `logout!`, `create_user`, `create_superuser`, `login_required`, `staff_member_required`.
- Sessions are stored in the database (`req.session["k"] = v`). The session key rotates on login, and changing a password invalidates existing sessions.
- CSRF protection on POST/PUT/PATCH/DELETE: `{% csrf_token %}` or an `X-CSRFToken` header. Mark exceptions with `csrf_exempt(view)`.
- One-time messages: `message!(req, :success, "Saved")`, rendered with `{% for m in messages %}`.

### Email

```julia
send_mail("Welcome", "Hi Ann!", nothing, ["ann@example.com"]; html_message = "<p>Hi Ann!</p>")   # nothing = DEFAULT_FROM_EMAIL
msg = EmailMessage("Report", "See attached."; to = ["boss@example.com"], cc = [...], bcc = [...], reply_to = [...])
attach!(msg, "report.csv", csv_text, "text/csv")
attach_alternative!(msg, html, "text/html")
send!(msg)
mail_admins("Disk almost full", details)          # to settings.ADMINS = [("Name", "email"), ...]
```

- **Backends.** `EMAIL_BACKEND` is `:smtp` (the default), `:console`, `:file` (`EMAIL_FILE_PATH`), `:locmem` (messages collect in `Juango.outbox`) or `:dummy`. You can also give it any function that takes a vector of messages.
- **SMTP** uses `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`/`EMAIL_HOST_PASSWORD` (AUTH PLAIN), and `EMAIL_USE_TLS` (STARTTLS) or `EMAIL_USE_SSL`.
- **Tests.** The test `Client` switches `:smtp` to `:locmem`, so tests never send real mail and can inspect `outbox`.
- **Errors.** With `DEBUG = false`, unhandled errors are mailed to `ADMINS`.
- **Password reset.** `auth_urls()` now includes password reset: `password_reset/` emails a link that works once, expires after `PASSWORD_RESET_TIMEOUT` (3 days), and leads to a page for choosing a new password. The templates are in `registration/password_reset_*`, and you can override them in your own template directory.
- **Signing.** `signing_dumps(value)` / `signing_loads(s; max_age)` make tamper-proof, URL-safe tokens keyed by `SECRET_KEY`, and `sign_value`/`unsign_value` do the same for plain strings.

### Permissions and groups

`migrate` creates `add_`, `change_`, `delete_` and `view_` permissions for every model, plus any declared with `Meta(permissions = [("publish_post", "Can publish posts")])`. Users get permissions directly or through groups:

```julia
editors = create(Group; name = "editors")
add!(editors.permissions, get(Permission; codename = "change_post"))
add!(user.groups, editors)
add!(user.user_permissions, get(Permission; codename = "publish_post"))

has_perm(user, "project.change_post")            # "<app label>.<codename>"; perm_name(Post, :change) builds it
has_perms(user, ["project.add_post", "project.change_post"])
has_module_perms(user, "project")
const edit_post = permission_required("project.change_post")(edit_post_view)   # login redirect, else 403
```

```
{% if perms.project.add_post %}<a href="{% url 'post_new' %}">New post</a>{% endif %}
{% if "project.publish_post" in perms %}...{% endif %}
```

- **Superusers and inactive users.** Active superusers have every permission, and inactive users have none.
- **Caching.** Permissions are cached on the user object, so reload the user after changing them.
- **Admin.** The admin follows these permissions:
  - Staff only see models they have permissions for.
  - With only `view_` permission, a user sees a read-only page.
  - Adding, changing and deleting each need the matching permission.
- **Groups in the admin.** Groups are registered in the admin, and a user's groups and permissions can be edited on their page.
- **Not yet supported.** Object-level permissions (`has_perm(user, perm; obj)`) return `false` except for superusers.

### Translations and formats

```julia
gettext("Welcome"); t"Welcome"                       # into the active language
ngettext("%(n)d comment", "%(n)d comments", n) |> s -> interpolate(s, Dict("n" => n))
pgettext("month name", "May")
title = CharField(max_length = 100, verbose_name = gettext_lazy("Title"))   # translated when shown
with_language("de") do ... end

configure!(MIDDLEWARE = [..., SessionMiddleware, LocaleMiddleware, ...],
           LANGUAGE_CODE = "en", LANGUAGES = [("en", "English"), ("de", "Deutsch")],
           LOCALE_PATHS = [joinpath(BASE_DIR, "locale")])
urlpatterns = [i18n_patterns(path("about/", about; name = "about")),   # /en/about/, /de/about/
               path("i18n/", i18n_urls())]                            # POST setlang/ to switch language
```

```
{% load i18n %}
{% translate "Welcome" %}  {% translate "May" context "month name" as m %}
{% blocktranslate count n=comments|length %}{{ n }} comment{% plural %}{{ n }} comments{% endblocktranslate %}
{% get_current_language as LANGUAGE_CODE %}  {% language "de" %}...{% endlanguage %}  {{ price|localize }}
```

- **Catalogues** are standard gettext files at `locale/<lang>/LC_MESSAGES/juango.po`, editable in Poedit, Weblate and similar tools.
  - `manage.jl makemessages -l de` collects strings from `.jl` files and templates and keeps existing translations.
  - `manage.jl compilemessages` builds the `.mo` files.
  - Juango reads `.po` files directly too, so compiling is optional.
- **Language selection.** `LocaleMiddleware` picks the language from the URL prefix, then the `juango_language` cookie, then `Accept-Language`, then `LANGUAGE_CODE`. It also sets `Content-Language`. Under `i18n_patterns`, a URL without a prefix redirects to the right language, and `reverse_url` adds the active prefix (`prefix_default_language = false` leaves the default language unprefixed).
- **Formats.** Dates use translated month and day names, and the `date` filter's default format follows the language. `localize` and `number_format` use the language's decimal separator, and thousands separators too with `USE_THOUSAND_SEPARATOR`.
- **Built-in German.** The admin's interface and validation messages are translatable, and Juango ships a German translation (`src/locale/de`). Other languages fall back to English until someone adds a catalogue.

### Time zones

```julia
configure!(USE_TZ = true, TIME_ZONE = "Europe/Berlin")   # startproject turns USE_TZ on
post.created                       # ZonedDateTime, in UTC
timezone_now()                     # aware "now" (auto_now fields use it)
with_timezone("Asia/Tokyo") do ... end      # or activate_timezone!(user.tz) per request
make_aware(DateTime(2024, 6, 1, 9)); make_naive(z); localtime(z)
```

```
{{ post.created }}  {{ post.created|date:"H:i T" }}      {# in the current time zone #}
{% timezone "Asia/Tokyo" %}...{% endtimezone %}  {{ t|utc }}  {{ t|timezone:"America/New_York" }}  {% localtime off %}
```

- **Storage.** With `USE_TZ`, datetimes are stored in UTC: `TIMESTAMP WITH TIME ZONE` on PostgreSQL, and UTC on SQLite and MySQL. The ORM returns aware `ZonedDateTime`s (TimeZones.jl).
- **Naive values.** Naive `DateTime`s you pass in are taken as wall-clock times in the current time zone.
- **Display.** Templates and forms show and read times in the current time zone: the one activated for the request (`TimezoneMiddleware` uses the session's `"juango_timezone"`), else `TIME_ZONE`. The `date` filter adds `e` (zone name), `T` (abbreviation) and `O` (offset).
- **Existing data.** To turn `USE_TZ` on for an existing database, run `manage.jl convert_naive_datetimes --from Europe/Berlin` once. It rewrites stored values as UTC and, on PostgreSQL, converts the columns. Back up first.
- **Lookups.** Date lookups such as `created__year` compare in UTC.

### Signals

```julia
function on_post_saved(sender; instance, created, kw...)       # always accept kw...
    created && send_mail("New post", instance.title, nothing, ["editor@example.com"])
end
connect!(post_save, on_post_saved; sender = Post)

receiver(post_delete; sender = Post) do sender, args              # do-block: arguments as a NamedTuple
    cache_delete("post:$(args.instance.id)")
end

const order_placed = Signal("order_placed")                      # your own signals
send(order_placed, Order; order = o)                             # send_robust collects exceptions instead
```

- **Built-in signals:**
  - `pre_save` and `post_save` (`instance`, `created`)
  - `pre_delete` and `post_delete` (`instance`, also sent for cascaded deletes)
  - `m2m_changed` (`action`, `instance`, `model`, `pk_set`, `reverse`; the sender is the join model)
  - `request_started` and `request_finished`
  - `user_logged_in`, `user_logged_out` and `user_login_failed` (without the password)
- **Filtering.** `sender` limits a receiver to one model (or other sender). `dispatch_uid` identifies a receiver for `disconnect!`.
- **What doesn't send.** Bulk `update!` doesn't send `pre_save`/`post_save`, as in Django.
- **When to use them.** To change a model's own behaviour, overriding `save!` (as the blog example does) is usually clearer. Signals are for code that lives elsewhere, such as caches, search indexes and notifications.

### Caching

```julia
cache_set("greeting", "hi"; timeout = 60)          # seconds; nothing = for ever, 0 = don't store
cache_get("greeting", "default")
get_or_set("stats", () -> expensive(); timeout = 300)
incr("hits"); cache_add(k, v); cache_delete(k); cache_get_many(keys); incr_version("menu")
const home = cache_page(home_view; timeout = 60)   # whole GET responses, keyed by URL
```

```
{% cache 600 "sidebar" user.id %} ...expensive fragment... {% endcache %}
```

- **Backends.** `CACHES` names one or more caches: `Dict("default" => Dict(:backend => :locmem, :max_entries => 1000, :timeout => 300))`. The backends are:
  - `:locmem` (per process, LRU)
  - `:db` (run `manage.jl createcachetable`)
  - `:redis` (`:location => "redis://host:6379/0"`, using a small built-in client)
  - `:dummy`

  Use another cache with `cache_name = "shared"`. Values are copied, or serialized for `:db` and `:redis`.
- **Page caching.** `cache_page` and the per-site `CacheMiddleware` (`CACHE_MIDDLEWARE_SECONDS`) skip responses that set cookies or vary on `Cookie`, so per-user pages aren't shared.
- **Templates.** `TEMPLATE_CACHE_CHECK_MTIME = false` reads each template once instead of checking its file on every render. Use it in production.
- **Sessions.** `SESSION_ENGINE = :cache` keeps sessions in the cache only, and `:cached_db` puts the cache in front of the database. The default is `:db`.

### Middleware

A middleware has Django's shape: a factory `get_response -> (req -> response)`.

```julia
function Timing(get_response)
    req -> (t = time(); r = get_response(req); setheader!(r, "X-Time", string(time() - t)); r)
end
configure!(MIDDLEWARE = [Juango.default_settings()[:MIDDLEWARE]..., Timing])
```

The defaults are security headers, sessions, `APPEND_SLASH`, CSRF and authentication.

### Admin

```julia
Admin.register!(Post; list_display=[:title, :author, :published, "Words" => p -> length(split(p.body))],
                search_fields=[:title, :body], list_filter=[:published, :author])
```

The admin gives you login, a model index, change lists (search, filters, pagination), add/change forms with validation, and delete confirmation that shows cascade effects. Users and groups are registered automatically, with password hashing in the user form. More options:

```julia
function publish(admin, req, qs)                    # an action: runs on the selected objects
    update!(qs; published = true)
    message!(req, :success, "Published $(count(qs)).")
end

Admin.register!(Post;
    list_display = [:title, :author, :published],
    list_editable = [:published],                   # edit right in the change list
    date_hierarchy = :created,                      # drill down by year / month / day
    actions = [Admin.action(publish; description = "Publish selected", confirm = true), Admin.export_csv],
    fieldsets = ["Content" => [:title, :slug, :body], "Publishing" => [:author, :published]],
    readonly_fields = [:views],
    prepopulated_fields = Dict(:slug => [:title]),  # filled while typing, when adding
    autocomplete_fields = [:author],                # search box (Author's admin needs search_fields)
    raw_id_fields = [],                             # or a plain id box for huge tables
    inlines = [Admin.TabularInline(Comment; fields = [:name, :body], extra = 1)],   # or StackedInline
    save_as = true)                                 # "Save as new"
```

- **Bulk delete** is a built-in action with a confirmation page; `delete_action = false` removes it.
- **Change history.** Every add, change and delete is recorded as a `LogEntry` with a message like "Changed title. Added comment “Nice”." Each object has a history page, and the index lists your recent actions. Record your own entries with `log_action!(user, obj, CHANGE, "Published.")`.
- **Permissions apply** to actions (`permission = :change` by default) and to inlines (add, change and delete on the inline model).

### Testing

```julia
c = Client()
r = get(c, "/posts/hello/")
@test r.status == 200 && r.context["post"].title == "Hello" && r.templates == ["post.html"]
force_login!(c, user)
r = post(c, "/posts/new/", Dict("title" => "X", ...); follow=true)
```

The client keeps cookies, skips CSRF unless you pass `Client(enforce_csrf=true)`, and never opens a socket.

To catch N+1 queries, `count_queries` runs a function and counts the SQL statements it executed:

```julia
r, n = count_queries(() -> get(c, "/posts/"))
@test n <= 3
```

### Management commands

`runserver [host:]port`, `makemigrations`, `migrate`, `showmigrations`, `sqlmigrate`, `createsuperuser`, `changepassword`, `showurls`, `sqlschema`, `check`, `clearsessions`, `help`. Add your own with `Juango.register_command!("name", "help", args -> ...)`.

## Settings

Set them with `configure!(...)` and read them with `settings.NAME`. The main ones: `DEBUG`, `SECRET_KEY`, `DATABASE` (a SQLite path, `":memory:"`, a `scheme://` URL, or a backend instance), `INSTALLED_APPS`, `APP_DIRS`, `ROOT_URLCONF`, `TEMPLATE_DIRS`, `STATIC_URL`, `STATIC_DIRS`, `STATIC_ROOT`, `ALLOWED_HOSTS`, `MIDDLEWARE`, `CONTEXT_PROCESSORS`, `LOGIN_URL`, `LOGIN_REDIRECT_URL`, `APPEND_SLASH`, `SESSION_COOKIE_AGE`, `PASSWORD_ITERATIONS`, `SQL_DEBUG`. Any extra keyword becomes a custom setting.

## Differences from Django (current limitations)

- **Migrations can't be squashed yet.** Migration files describe tables and columns, and there are no historical model classes as in Django, so data migrations use raw SQL or today's models.
- **SQLite, PostgreSQL and MySQL/MariaDB.** Postgres and MySQL use a connection pool; SQLite uses one connection behind a lock.
- **ORM features not yet built:** symmetrical self-referential many-to-many, filtering on window functions, and `select_related` into a model that inherits from another table (use `prefetch_related`).
- Built-in models are labelled `juango.User`, `juango.Group` and so on, not `auth.User`. They share one migration history, so leaving out a built-in app doesn't remove its tables.
- `runserver` is HTTP.jl's server. It is fine for development and small deployments. For production, put it behind a reverse proxy, set `DEBUG=false`, set a real `SECRET_KEY` and `ALLOWED_HOSTS`, and set `SESSION_COOKIE_SECURE`/`CSRF_COOKIE_SECURE`.

## Layout

```
src/
  Juango.jl      module & exports        orm.jl       models, QuerySet, Q
  schema.jl      schema snapshots, DDL   migrations.jl  makemigrations, migrate
  migrations/    built-in app's migrations
  conf.jl        settings                forms.jl     Form, ModelForm, widgets
  http.jl        Request/HttpResponse    sessions.jl  DB-backed sessions
  urls.jl        path/resolve/reverse    auth.jl      User, hashing, login views
  template.jl    template language       middleware.jl  middleware, CSRF
  db.jl          backend interface       views.jl     shortcuts, generic views
  backends/      sqlite.jl, postgres.jl  ext/         LibPQ driver (optional)
  handler.jl     request pipeline        admin.jl     the admin
  server.jl      HTTP server             management.jl  CLI, startproject
  streaming.jl   streaming, SSE, WebSockets
  apps.jl        App, INSTALLED_APPS
  testclient.jl  test Client             templates/   built-in admin templates
test/runtests.jl                          examples/blog/  complete example app
```

Run the tests with `julia --project -e 'using Pkg; Pkg.test()'`.
