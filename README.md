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
| `manage.py runserver / migrate / createsuperuser` | `manage.jl runserver / migrate / createsuperuser` |
| `django.test.Client` | `Client()` |

## Quick start

```julia
julia> using Juango
julia> startproject("mysite")
```

```sh
cd mysite
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

migrate()                                                     # create/alter tables

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

Computed attributes for templates (and `obj.name` in Julia) use `tattr`:

```julia
Juango.tattr(p::Post, ::Val{:summary}) = first(p.body, 100)
```

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

### Management commands

`runserver [host:]port`, `migrate`, `createsuperuser`, `changepassword`, `showurls`, `sqlschema`, `check`, `clearsessions`, `help`. Add your own with `Juango.register_command!("name", "help", args -> ...)`.

## Settings

Set them with `configure!(...)` and read them with `settings.NAME`. The main ones: `DEBUG`, `SECRET_KEY`, `DATABASE` (a SQLite path, `":memory:"`, a `scheme://` URL, or a backend instance), `ROOT_URLCONF`, `TEMPLATE_DIRS`, `STATIC_URL`, `STATIC_DIRS`, `ALLOWED_HOSTS`, `MIDDLEWARE`, `CONTEXT_PROCESSORS`, `LOGIN_URL`, `LOGIN_REDIRECT_URL`, `APPEND_SLASH`, `SESSION_COOKIE_AGE`, `PASSWORD_ITERATIONS`, `SQL_DEBUG`. Any extra keyword becomes a custom setting.

## Differences from Django (current limitations)

- **Migrations sync the schema; they are not versioned.** `migrate` creates missing tables, columns and indexes, and reports columns that are no longer used. It never renames or drops anything. Write SQL by hand for those changes (`Juango.execute(sql, params)`).
- **SQLite and PostgreSQL only.** MySQL is [#11](https://github.com/mcvmcv/Juango/issues/11). Postgres uses a single connection behind a lock; a connection pool is [#30](https://github.com/mcvmcv/Juango/issues/30).
- No many-to-many fields, `select_related`, annotations or `F()` expressions yet. Aggregates go through `aggregate(qs, :sum, :field)`.
- No `INSTALLED_APPS`/app registry. A project is a set of Julia files you `include`, as in the `startproject` layout.
- File uploads: multipart fields are parsed, and uploaded files are exposed raw in `req.meta[:FILES]`. There is no `FileField`.
- No i18n, caching framework, signals, or permission groups.
- `runserver` is HTTP.jl's server. It is fine for development and small deployments. For production, put it behind a reverse proxy, set `DEBUG=false`, set a real `SECRET_KEY` and `ALLOWED_HOSTS`, and set `SESSION_COOKIE_SECURE`/`CSRF_COOKIE_SECURE`.

## Layout

```
src/
  Juango.jl      module & exports        orm.jl       models, QuerySet, Q, migrate
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
