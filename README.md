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

### Auth, sessions, CSRF, messages

- `User` model with PBKDF2-SHA256 password hashes in Django's format, so existing Django hashes verify.
- `authenticate`, `login!`, `logout!`, `create_user`, `create_superuser`, `login_required`, `staff_member_required`.
- Sessions are stored in the database (`req.session["k"] = v`). The session key rotates on login, and changing a password invalidates existing sessions.
- CSRF protection on POST/PUT/PATCH/DELETE: `{% csrf_token %}` or an `X-CSRFToken` header. Mark exceptions with `csrf_exempt(view)`.
- One-time messages: `message!(req, :success, "Saved")`, rendered with `{% for m in messages %}`.

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

The admin gives you login, a model index, change lists (search, filters, pagination, bulk delete), add/change forms with validation, and delete confirmation that shows cascade effects. Users are registered automatically, with password hashing in the form.

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

Set them with `configure!(...)` and read them with `settings.NAME`. The main ones: `DEBUG`, `SECRET_KEY`, `DATABASE` (a SQLite path, `":memory:"`, a `scheme://` URL, or a backend instance), `ROOT_URLCONF`, `TEMPLATE_DIRS`, `STATIC_URL`, `STATIC_DIRS`, `ALLOWED_HOSTS`, `MIDDLEWARE`, `CONTEXT_PROCESSORS`, `LOGIN_URL`, `LOGIN_REDIRECT_URL`, `APPEND_SLASH`, `SESSION_COOKIE_AGE`, `PASSWORD_ITERATIONS`, `SQL_DEBUG`. Any extra keyword becomes a custom setting.

## Differences from Django (current limitations)

- **Migrations can't be squashed yet.** Migration files describe tables and columns, and there are no historical model classes as in Django, so data migrations use raw SQL or today's models.
- **SQLite and PostgreSQL only.** MySQL is [#11](https://github.com/mcvmcv/Juango/issues/11). Postgres uses a single connection behind a lock; a connection pool is [#30](https://github.com/mcvmcv/Juango/issues/30).
- **ORM features not yet built:** symmetrical self-referential many-to-many, filtering on window functions, and `select_related` into a model that inherits from another table (use `prefetch_related`).
- No `INSTALLED_APPS`/app registry. A project is a set of Julia files you `include`, as in the `startproject` layout.
- File uploads: multipart fields are parsed, and uploaded files are exposed raw in `req.meta[:FILES]`. There is no `FileField`.
- No i18n, caching framework, signals, or permission groups.
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
  testclient.jl  test Client             templates/   built-in admin templates
test/runtests.jl                          examples/blog/  complete example app
```

Run the tests with `julia --project -e 'using Pkg; Pkg.test()'`.
