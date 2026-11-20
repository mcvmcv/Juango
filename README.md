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
| `django.test.Client` | `Client()` (from `using Juango.Testing`) |

`using Juango` brings in the everyday API: settings, requests and responses, URLs, templates, models, fields, querysets and expressions, forms, views, auth, messages, signals, caching, mail and translations. The rest of the API is public but not exported: write `Juango.name`, or `using Juango: name`. Three areas have modules of their own that export their names, like Django's packages:

```julia
using Juango.Testing      # Client, RequestFactory, assertions, override_settings, outbox ...
using Juango.GIS          # geometry fields and values, distances, GeoJSON and WKT
using Juango.Postgres     # HStoreField, CICharField, full-text search, trigrams, ExclusionConstraint, GinIndex
```

`Juango.Admin` and `Juango.Migrations` are modules too. Functions you add methods to (`get_absolute_url`, `tattr`, `natural_key`, database routers, authentication backends) are public.

## Quick start

```julia
julia> using Juango
julia> Juango.startproject("mysite")
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
filter(Post, Q(container__isnull=true) ⊻ Q(material__isnull=true))   # xor: an odd number true (also in CheckConstraints)
order_by(Post, Desc(:published_at; nulls_last = true), "title")   # expressions too; NULLs placed alike on every database
order_by(objects(Post))          # no ordering at all, not even Meta.ordering (also left out of aggregate annotate queries)
contains(qs, post); post in qs     # one EXISTS query (none if qs was already fetched)
update_or_create(Post; slug = "x", defaults = Dict(:title => "new"), create_defaults = Dict(:title => "first"))
refresh!(post; fields = [:views])  # reload just these
annotate(qs; card = JSONObject(title = :title, who = "author__name"))   # a Dict per row
values_list(Event, :data__run; flat = true)                        # a key inside a JSON field (also values, order_by)
exclude(Post; status="d")[1:10]  # slicing → LIMIT/OFFSET
get(Post; slug="hello")          # throws DoesNotExist / MultipleObjectsReturned
update!(filter(Post; author=ann); published=true)
aggregate(objects(Post), :count, :id)
get_or_create(Author; name="Bob", defaults=Dict(:email => "b@x.io"))
atomic() do                      # transaction; nested calls use savepoints
    save!(post); delete!(ann)    # on_delete decides what happens to related rows (see below)
end
```

Lookups: `exact iexact contains icontains startswith istartswith endswith iendswith gt gte lt lte in isnull range year month day ne`, across relations (`author__name__iexact`) in both directions.

`on_commit(f)` runs `f()` once the current transaction commits, and drops it if the transaction (or the savepoint it was registered in) rolls back. Outside a transaction `f()` runs at once. Use it to send mail or enqueue a task only when the data it needs is saved:

```julia
atomic() do
    save!(order)
    on_commit(() -> send_mail("Order received", ...))     # robust = true logs an error instead of raising
end
```

In tests inside `rollback_after`, `capture_on_commit_callbacks(f; execute = true)` returns (and runs) the callbacks `f` registered.

More of Django's `transaction` module:
- **`atomic(f; durable = true)`** refuses to run inside another atomic block, so when it returns the work is committed. Blocks opened by `rollback_after` in tests don't count.
- **`advisory_lock("plates", year) do ... end`** runs a block in a transaction while holding a named lock, so two requests can't both read the last label number and make the same next one (PostgreSQL `pg_advisory_xact_lock`, MySQL `GET_LOCK`, a lock in the process on SQLite). `timeout = 5` gives up with an error instead of waiting.
- **`set_rollback!(true)`** rolls the innermost block back when it ends, without an exception. `get_rollback()` reads the flag.
- **`savepoint()`** returns an id for `savepoint_commit` and `savepoint_rollback`; a rollback also drops the `on_commit` callbacks registered since.
- **`execute_wrapper(wrapper) do ... end`** calls `wrapper(execute, sql, params, context)` around each statement the block runs: for blocking queries, timing them, adding comments or retrying.

The signals `connection_created` (run per-connection `SET`s; the receiver's `execute` uses the new connection), `got_request_exception`, `setting_changed`, `pre_init`/`post_init` and `class_prepared` are sent as in Django.

Add your own lookups and transforms with `Juango.register_lookup` and `Juango.register_transform` (Django's `register_lookup`). They work in `filter`, `exclude` and `Q`, across relations, and transforms chain:

```julia
Juango.register_lookup("notequal"; kinds = [:char, :text]) do lhs, rhs     # rhs is the value's placeholder
    "$lhs <> $rhs"
end
Juango.register_transform("lower"; kinds = [:char, :text]) do lhs
    "LOWER($lhs)"
end
Juango.register_transform(lhs -> "CHAR_LENGTH($lhs)", "len"; kinds = [:char, :text], output = :int)
filter(Author; name__lower__startswith = "an", name__len__gte = 3, email__notequal = "")
```

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

**N+1 queries are reported.** With DEBUG on, a relation loaded lazily on many objects in one request (five by default, `NPLUSONE_THRESHOLD`; one object's relation used several ways counts once) logs a warning naming it, the line of your code that read it and the fix: `N+1 queries: Article.author was loaded for 23 objects one at a time in one request (from post_list at views.jl:12). Add select_related(:author) to the queryset.` A `select_related`/`prefetch_related` whose objects were never read is reported too. `NPLUSONE = :raise` makes it an error, so a test suite catches regressions; `with_nplusone_allowed() do ... end` covers the deliberate cases, and `NPLUSONE = false` turns it off. `AUTO_PREFETCH = true` goes further: the first time a foreign key is read on one object of a fetched queryset, it's loaded for all of them in one query (django-auto-prefetch's idea; off by default).

More QuerySet tools:

```julia
defer(objects(Post), :body)                  # leave big columns out; reading post.body loads them
only(objects(Post), :title, :author)         # just these fields (and the id)
distinct(values(objects(Post), :status))     # SELECT DISTINCT
distinct(order_by(qs, "author", "-published"), :author)   # DISTINCT ON (PostgreSQL)
latest(objects(Post), :published)            # or Meta(get_latest_by = "published"); earliest() too
in_bulk(objects(Post), [1, 2, 3])            # Dict(id => post)
dates(objects(Post), :published, :month)     # distinct months with posts; datetimes() for hours etc.
raw(Post, "SELECT id, title FROM post WHERE views > ?", [100])   # model instances from your own SQL
explain(filter(Post; published=true))        # the database's query plan
```

Saving an object with deferred fields writes only the fields that were loaded.

For many rows at once:

```julia
bulk_create([Post(; title = "p$i") for i in 1:1000]; batch_size = 500)   # ids set on SQLite, PostgreSQL, MariaDB
bulk_create(tags; ignore_conflicts = true)                               # skip duplicates
bulk_create(tags; update_conflicts = true, update_fields = [:count], unique_fields = [:name])
bulk_update(posts, [:views, :title])                                     # a few UPDATE ... CASE statements
for p in iterator(objects(Post); chunk_size = 2000)  ...  end           # pages through a big table
atomic() do
    acct = first(select_for_update(filter(Account; id = 1)))             # row locked until commit
end
union(filter(Post; featured = true), filter(Post; views__gt = 1000))     # intersection, difference too
```

`bulk_create` and `bulk_update` don't call `save!` or send signals. Unlike Django, `update!`, `bulk_update` and upserts (`update_conflicts`) stamp `auto_now` fields such as `updated_at`, so "last changed" stays true after bulk writes; pass `touch_auto_now = false` for Django's behaviour. An upsert given two objects with the same `unique_fields` writes the last one (PostgreSQL would refuse the batch). Combined querysets can be ordered, sliced and counted but not filtered further. Querysets of objects combine with querysets of the same model; `values`/`values_list` querysets combine across models when they select the same number of columns (`union(values_list(filter(Result; ...), :assay_id; flat = true), values_list(report.markers, :id; flat = true))`), and the rows take their names from the first. A queryset used as a subquery (`__in`, `Subquery`, `Exists`) drops its ordering unless it's sliced, as in Django, and a `values_list` subquery selects only its named columns.

#### Validation and neighbours

```julia
errors = full_clean(post)                     # Dict(:field => messages, :__all__ => row-wide messages); empty when valid
clean_fields(post); validate_unique(post); validate_constraints(post; exclude = [:slug])
full_clean(post; validate_unique = false)

@model struct Bulletin
    slug     = SlugField(unique_for_date = :pub_date)       # also unique_for_month, unique_for_year
    pub_date = DateTimeField()
end

get_next_by(post, :created)                   # also get_previous_by, with filters: get_next_by(post, :created; published = true)
post.get_next_by_created                      # Django's get_next_by_FOO, for non-null date fields
```

- **`full_clean`** runs `clean_fields` (each field on its own), then the model's own `Juango.clean`, then `validate_unique` (`unique`, `unique_together`, `unique_for_*`), then `validate_constraints` (`Meta(constraints = ...)`). It skips fields that already have errors, as Django does.
- **`Juango.clean(obj)`** is Django's `Model.clean`, for rules across fields or rows. Throw `ValidationError("message")` for the whole object or `ValidationError(Dict(:field => ["message"]))` for fields. ModelForms call it too (on the instance with the form's data applied), so the admin and the generic edit views apply it. A form's own `clean` function may throw `ValidationError` as well.

  ```julia
  function Juango.clean(b::NumberBlock)
      b.first > b.last && throw(ValidationError("The first number comes after the last."))
  end
  ```
- **Partial saves.** `save!(obj; update_fields = [:status, :approved_at])` writes only those columns, so another request's change to a different field isn't overwritten. `auto_now` fields are written with them (Django leaves them out; `touch_auto_now = false` does too), an empty list saves nothing, and `pre_save`/`post_save` get `update_fields` (a `Set`, or `nothing`).
- **`get_next_by` and `get_previous_by`** break ties by primary key, and throw `DoesNotExist` at the end.

#### Choices

```julia
@choices Status begin
    DRAFT = "d", "Draft"                         # value, label (gettext_lazy("Draft") translates it)
    PUBLISHED = "p", "Published"
    ARCHIVED = "a"                               # the label comes from the name: "Archived"
end

@model struct Post
    status = CharField(max_length = 1, choices = Status, default = Status.DRAFT)
    medium = CharField(max_length = 10, blank = true,
                       choices = ["Audio" => ["vinyl" => "Vinyl", "cd" => "CD"], "Video" => ["vhs" => "VHS"]])
    shelf  = CharField(max_length = 10, choices = () -> [s.code => s.name for s in shelves()])   # read when needed
end

filter(Post; status = Status.PUBLISHED)
post.status == Status.DRAFT                     # members equal their values
post.get_status_display                         # "Draft" (also get_display(post, :status), and in templates)
Status.choices; Status.values; Status.label("p")
```

- **Members** are `Choice`s with `.value`, `.label` and `.name`. They equal and hash like their values, so they work as query values and Dict keys. Loading from the database gives back the plain value, as in Django.
- **Grouped choices** become optgroups in forms.
- **A function** as `choices` is called each time the choices are needed, both for validation and for forms (Django 5's callable choices).

#### Natural keys and legacy columns: to_field and db_column

```julia
plate  = ForeignKey(Plate; on_delete = :CASCADE, to_field = :barcode)   # stores the plate's barcode, not its id
count_ = IntegerField(db_column = "count")                              # a column named other than the field
```

`to_field` names a unique field of the related model. The column takes that field's type, and the database constraint refers to it. `filter(Well; plate = "P-0001")` compares barcodes, `well.plate_id` is the barcode, and joins, `select_related`, `prefetch_related`, cascades and forms follow the field. `db_column` changes only the column's name: lookups, `values()` keys and serializers still use the field's name.

#### What deleting does: on_delete

```julia
record = ForeignKey(Record, on_delete = :RESTRICT)              # see below
venue  = ForeignKey(Venue, on_delete = :SET_DEFAULT, default = default_venue_id)
backup = ForeignKey(Venue, on_delete = SET(fallback), null = true)   # an object, a key, or a function returning one
```

- **The options.** `:CASCADE` deletes the referencing rows too, `:SET_NULL` clears the key (it needs `null = true`), `:PROTECT` refuses with `ProtectedError`, and `:DO_NOTHING` leaves the rows alone. `:SET_DEFAULT` points the key at its `default`, and `SET(x)` points it at `x` or at what `x()` returns.
- **`:RESTRICT`** works like `:PROTECT`, with one exception, as in Django. Deleting is allowed when the rows pointing through the key are deleted by the same operation. For example, deleting a band deletes its records and its tracks together, even though a track's `record` key is restricted. Deleting just the record raises `RestrictedError`.
- **Telling users.** The errors carry the rows that block the delete (`e.protected_objects`, `e.restricted_objects`, as Django's), and `protected_message(e)` makes a sentence of them, with plurals that agree: `Can't delete this author: 2 articles still refer to it (“A”, “B”).` The admin shows it.
- **The admin's delete page** lists everything the delete takes along, nested under what it hangs from, as Django's; protected rows, and kinds the user may not delete, make it a "Cannot delete" page.
- **The database checks the keys too**, on every backend: a row can't point at a row that isn't there. On SQLite (since #260, as Django) the keys are checked when the transaction commits, so rows that refer to each other can be written in any order within one; a key with `:DO_NOTHING` that's left pointing at a deleted row fails the commit. SQLite databases from before #260 should be checked for such orphans first: `PRAGMA foreign_key_check` lists them.

#### Integer sizes and primary keys

```julia
@model struct Stats
    visits = PositiveBigIntegerField(default = 0)   # also BigIntegerField, SmallIntegerField,
    rank   = SmallIntegerField(null = true)         # PositiveIntegerField, PositiveSmallIntegerField
end

configure!(DEFAULT_AUTO_FIELD = :BigAutoField)      # the automatic `id`: :BigAutoField (default), :AutoField, :SmallAutoField
const APP = App("shop"; default_auto_field = :AutoField)     # per app
@model struct Tag
    name = CharField(max_length = 20)
    Meta(pk = SmallAutoField())                    # per model
end
```

- **Sizes.** `IntegerField` is a 32-bit `INTEGER`, as in Django. The other integer fields are `BIGINT` and `SMALLINT`, and `full_clean` and forms check their ranges.
- **Positive fields.** They get `CHECK (col >= 0)` on Postgres and SQLite, and `UNSIGNED` columns on MySQL/MariaDB.
- **Primary keys and foreign keys.** Foreign keys use the size of the key they point at.
- **Changing the key size.** Changing `DEFAULT_AUTO_FIELD`, an app's `default_auto_field` or `Meta(pk = ...)` makes `makemigrations` write an `AlterPrimaryKey`. It changes the key and the foreign keys pointing at it; on MySQL it drops and re-adds those foreign keys.
- **Juango's own apps** always use 64-bit keys.

#### Decimals

```julia
@model struct Product
    name  = CharField(max_length = 100)
    price = DecimalField(max_digits = 10, decimal_places = 2)    # NUMERIC(10, 2)
end

p = create(Product; name = "Tea", price = dec"4.95")    # dec"..." or Decimal("4.95"); integers and floats convert
p.price * 3                                              # dec"14.85", exact
aggregate(objects(Product); total = Sum(:price))[:total] # a Decimal, without binary rounding errors
round(dec"2.675"; digits = 2)                            # dec"2.68" (half to even; RoundNearestTiesAway rounds half up)
```

- **The `Decimal` type.** `Decimal` is an exact decimal number, like Python's `decimal.Decimal`. Juango includes its own, because the Decimals package is too limited (no hashing, inexact division). `+`, `-` and `*` are exact, and `/` gives 28 significant digits. A Decimal keeps its scale: `dec"1.50"` prints as `1.50` and equals `dec"1.5"`. `round(d; digits)` rounds to exactly that many places and pads with zeros. Floats convert through their shortest form, so `Decimal(0.1) == dec"0.1"`.
- **Saving and loading.** Values are rounded to `decimal_places` when they are saved and loaded. `full_clean` and forms check `max_digits` and `decimal_places` with Django's messages. The form widget is a number input with `step="0.01"`.
- **Databases.** Postgres uses `NUMERIC(p, s)` and MySQL/MariaDB `DECIMAL(p, s)`, both exact. SQLite has no exact decimal type. Its `NUMERIC` column stores values as doubles (about 15 significant digits), which is enough for amounts of money. `Sum`, `Min`, `Max` and arithmetic on decimal fields return Decimals. Other computed numbers (`Avg` of an integer field, for example) are `Float64` as before.
- **Output.** Fixtures store decimals as strings (`"4.95"`), as Django does. Templates print them exactly, including `floatformat`, `localize` and `intcomma`. `JsonResponse` writes them as JSON numbers.

#### Dates and times in queries

```julia
filter(Post; created__year = 2026, created__hour__gte = 9)          # transforms chain into lookups
filter(Post; created__date = Date(2026, 3, 1), created__week_day = 2)
filter(Post; created__quarter = 1, created__iso_year = 2026, created__time__lt = Dates.Time(12))
annotate(Post; q = ExtractQuarter(:created), month = TruncMonth(:created))
annotate(values(annotate(Post; month = TruncMonth(:created)), :month); n = Count(:id))   # posts per month
```

- **Transforms:** `year`, `quarter`, `month`, `week` (ISO), `week_day` (1 = Sunday, as Django), `iso_week_day` (1 = Monday), `iso_year`, `day`, `hour`, `minute`, `second`, `date` and `time`. They work on date, datetime and time fields, and chain into any lookup (`created__month__in = [6, 7]`).
- **Functions:** `Extract(x, part)` and `ExtractYear` … `ExtractSecond` give integers. `Trunc(x, kind)` and `TruncYear`, `TruncQuarter`, `TruncMonth`, `TruncWeek`, `TruncDay`, `TruncHour`, `TruncMinute`, `TruncSecond` give datetimes (or dates for a date field). `TruncDate` and `TruncTime` give the date or time of a datetime.
- **Time zones.** With `USE_TZ`, datetimes are converted to the current time zone first, as in Django: Postgres uses `AT TIME ZONE`, and SQLite uses two functions Juango registers on its connections. MySQL/MariaDB uses `CONVERT_TZ`, which needs the server's time zone tables (`mysql_tzinfo_to_sql`); without them, only `TIME_ZONE = "UTC"` works there.

#### Times of day and durations

```julia
@model struct Shift
    starts = TimeField()                       # Dates.Time; auto_now / auto_now_add work too
    length = DurationField()                   # Hour(8) + Minute(30), read back as a CompoundPeriod
    opened = DateTimeField()
end

filter(Shift; starts__gte = Dates.Time(9), length__lt = Hour(1))
annotate(Shift; ends = F(:opened) + F(:length))                   # a datetime
filter(Shift; opened__gt = Value(now()) - F(:length))              # datetimes minus durations
annotate(Shift; took = F(:closed) - F(:opened))                    # datetime - datetime: a duration
aggregate(objects(Shift); total = Sum(:length))
```

- **Durations** are fixed `Period`s or `CompoundPeriod`s, and come back as a canonical `CompoundPeriod` (`Day(1) + Hour(2)`). Months and years have no fixed length, so a duration can't hold them, as Python's `timedelta` can't.
- **Storage.** Postgres stores `TIME` and `INTERVAL` and does the arithmetic natively. MySQL/MariaDB use `TIME(6)`, SQLite stores times as text, and both store durations as a number of microseconds. `datetime ± duration` and `datetime - datetime` get the right SQL on each database.
- **Text forms.** Templates and forms show durations as Django does (`1 day, 2:03:00`), and form inputs accept that, `1 02:03:00`, a number of seconds, or ISO 8601 (`P1DT2H`). Fixtures write times as `06:30:00` and durations as `1 02:03:00`.

#### Binary data, IP addresses and file paths

```julia
@model struct Device
    ip     = GenericIPAddressField(null = true, blank = true)   # protocol = "IPv4" / "IPv6", unpack_ipv4 = true
    key    = BinaryField(max_length = 32)                       # Vector{UInt8}
    script = FilePathField(path = "/srv/scripts", match = r"\.sh$", recursive = true)
end
```

- **`GenericIPAddressField`** stores addresses in their normal form (`2001:DB8::0:1` becomes `2001:db8::1`) and rejects invalid ones with Django's messages. Postgres uses `INET`, the other databases `CHAR(39)`. A blank value is stored as NULL, so `blank = true` needs `null = true`.
- **`BinaryField`** holds raw bytes: `BYTEA`, `LONGBLOB` or `BLOB`. It isn't editable in forms, and fixtures carry it as base64.
- **`FilePathField`** stores a path. Forms offer the matching files (or folders, with `allow_folders = true`) under `path` as a select, and refuse any other value.

#### The other side of a foreign key

`author.posts` (the `related_name`, or `post_set`) is a queryset of the author's posts, and changes the relation as Django's related manager does:

```julia
create(author.posts; title = "Hello")       # a Post whose author is `author`
add!(author.posts, p1, p2)                  # point their author at `author` (one UPDATE; bulk = false saves each)
set!(author.posts, [p1])                    # with a nullable key the others are set to NULL; without one they stay
remove!(author.posts, p2); clear!(author.posts)    # a nullable key only (else delete them, or give them another author)
```

After `prefetch_related(objects(Author), :posts)`, a change through `author.posts` drops the prefetched rows, so the next access sees it. An unsaved object's reverse relation has no rows. An object assigned to a foreign key must be of the related model (or a proxy, parent or child of it), and one that is still unsaved when its owner is saved stops the save, as in Django; saved by then, its key is taken at that moment.

#### Many-to-many

```julia
@model struct Post
    title = CharField(max_length=200)
    tags  = ManyToManyField(Tag; related_name=:posts, blank=true)
end

add!(post.tags, julia, web)      # objects or ids; existing links are skipped
create(post.tags; name = "new")  # a Tag, added to the post's tags
remove!(post.tags, web)
set!(post.tags, [julia, db])     # only the differences are written; clear = true removes all first
clear!(post.tags)
post.tags                        # QuerySet{Tag};   tag.posts is QuerySet{Post}
filter(Post; tags__name="julia")                  # lookups in both directions
prefetch_related(objects(Post), :tags)            # 1 extra query for any number of posts
```

- **What can be added.** Objects of the related model (or their keys, or with a `to_field` through model that field's value, `add!(article.authors, "jean")`); an object of another model or a key that isn't one is refused, as in Django. `post.tags = [...]` is an error: use `set!`. A change drops the relation's prefetched rows.
- **Reverse names.** The reverse side is `tag.post_set` (or `related_name`) on an object, and `post` in lookups (`filter(Tag; post__title = "x")`, `Count(:post)`), or `related_query_name` when given; the same holds for foreign keys. A many-to-many to `USER_MODEL` names its join column `user_id`.
- **Join table.** Juango creates a join table (`post_tags`, unique per pair) that migrations manage like any other table. Deleting either side removes its links. `through(Post, :tags)` is its model (Django's `Post.tags.through`), with foreign keys `post` and `tag` (`from_post`/`to_post` for a relation to the same model): query it, `bulk_create` links, or connect `m2m_changed` with it as the sender.
- **Custom intermediate model.** Use `through=:Membership` for one with extra fields, and fill those fields with `add!(club.members, ann; through_defaults=Dict(:role => "chair"))` (a function as a default is called once per call; `create`, `set!`, `get_or_create` and `update_or_create` through the relation take `through_defaults` too). One with two foreign keys to the same model (an invitation's inviter and invitee) needs `through_fields = (:event, :invitee)`, its keys to this model and the related one; without it Juango refuses the relation, as Django does.
- **Self-referential relations.** `friends = ManyToManyField(:self)` is symmetrical: adding Bob to Ann's friends adds Ann to Bob's, and removing works both ways. Use `symmetrical = false` for one-way relations such as "follows".
- **Forms and admin.** `ModelForm` renders a multiple select and `save!(form)` saves the relation. After `save!(form; commit=false)`, call `save_m2m!(form)` once the object is saved. The admin does this for you.
- **`unique_together`.** `Meta(unique_together=[(:code, :batch)])` adds a multi-column unique constraint, and migrations track it (`AlterUniqueTogether`).

#### Expressions, annotations and aggregation

```julia
update!(filter(Post; id=1); views = F(:views) + 1)              # atomic increment, no race
post.views = F(:views) + 1; save!(post)                         # the same on one object (then post.views is the new number)
filter(Post; updated__gt = F(:created))                         # compare columns
annotate(objects(Author); n = Count(:posts)) |> filter(n__gt = 2) |> order_by("-n")   # GROUP BY / HAVING
annotate(objects(Author); published = Count(:posts; filter = Q(posts__published = true)))
values(objects(Post), :status) |> annotate(n = Count())        # rows like Dict(:status => "p", :n => 12)
aggregate(objects(Post); total = Sum(:views), avg = Avg(:views))   # Dict(:total => ..., :avg => ...)
aggregate(objects(Post), Avg(:views))                           # Dict(:views__avg => ...), Django's default name
annotate(objects(Post); popular = Q(views__gt = 100))           # a condition as a true/false column
values_list(objects(Post), :title, :author__name)               # tuples; flat=true for one field, named=true for NamedTuples
filter(Plate; id__in = values_list(filter(Event; kind = "load"), :plate_id; flat = true))   # one query: a subquery
```

`lookup_value(post, "author__profile__city")` follows the same kind of path on an object: `nothing` (or `default`) where a relation is empty, and a property that throws is logged rather than raised.

With DEBUG on, paginating an unordered queryset, or slicing one from a later row, logs a warning once: without `order_by` or `Meta(ordering)` the database may return rows in any order, so pages overlap or skip rows (`first` and `last` already order by the primary key).

`values` and `values_list` return lazy QuerySets, as in Django: they chain (`order_by`, `distinct`, slices, `count`, `exists`), `first` and `last` give `nothing` when there are no rows, and nothing runs until they're iterated, compared with a vector or `collect`ed. Collect one when you need a snapshot that later writes can't change. A few vector idioms need `collect` too: `[qs1; qs2]` is a vector of two querysets, not their rows (using it as a query value is an error naming this), `filter(pred, qs)` is the ORM's `filter`, and `findfirst` needs a vector.

- **Aggregates:** `Count`, `Sum`, `Avg`, `Min`, `Max`, with `distinct=` and `filter=`.
- **Functions:** `Lower`, `Upper`, `Length`, `Coalesce`, `Concat`, `Cast(x, :float)`, `Now()`, and `ExtractYear`/`ExtractMonth`/`ExtractDay`.
- **Conditionals:** `Case(When(; views__gte=100, then="hot"); default="cold")`.
- **Arguments:** strings and symbols inside functions are field names, and they can follow relations (`:author__name`). Wrap literals in `Value("...")`.
- **Subqueries:**
  - `annotate(objects(Author); latest = Subquery(values(order_by(filter(Post; author=OuterRef(:id)), "-created"), :title)[1:1]))`
  - `filter(objects(Author), Exists(filter(Post; author=OuterRef(:id))))`, negated with `!Exists(...)`
  - Conditions combine whatever they are: `Q(genre = "poetry") & !Exists(...)`, `Q(rating__gt = 4) | Exists(...)`, `xor(...)`, and `When(Exists(...); then = ...)`.
- **Lookups as expressions:** `Exact`, `IExact`, `GreaterThan`, `GreaterThanOrEqual`, `LessThan`, `LessThanOrEqual`, `In`, `Range`, `IsNull`, `Contains`, `StartsWith`, `EndsWith` (and `I...` forms), in `annotate`, `filter`, `order_by` and `When`: `annotate(qs; modern = GreaterThan(F(:year), 1900))`, `filter(qs, Exact(F(:year), 1942) | GreaterThan(F(:year), 2000))`.
- **Operators:** `F(:x) + 1`, `-`, `*`, `/`, `%` (MOD), `^` (POWER), and on integers `&`, `|`, `⊻`, `<<`, `>>`. `~F(:flag)` negates a boolean. `F(:name)[1:3]` and `OuterRef(:code)[1]` are substrings.
- **`alias(qs; n = Count(:books))`:** a name for `filter`, `order_by` and `annotate` to use, without selecting it.
- **`RawSQL("num_employees > ?", [100]; output = :bool)`:** an SQL fragment as an expression, with parameters (never put user input in the SQL itself). `ExpressionWrapper(expr; output = :duration)` gives an expression a type, so its values convert.
- **`aggregate` over annotations:** `aggregate(annotate(qs; n = Count(:authors)); avg = Avg(:n))` runs the annotated query as a subquery.
- **Window functions:** `annotate(qs; rank = Window(RowNumber(); partition_by=[:author], order_by=["-views"]))`, also with `Rank`, `DenseRank`, `Lag`, `Lead`, `FirstValue`, `LastValue`, `NthValue`, `Ntile`, `PercentRank`, `CumeDist` and aggregates over a window. A frame narrows the window: `Window(Sum(:amount); order_by = ["day"], frame = RowRange(start = -6, stop = 0))` is a seven-row moving sum, `RowRange(stop = 0)` a running total, and `ValueRange(...)` counts in the ordering's values (`RANGE`). `exclusion = :current_row` (or `:group`, `:ties`) works on PostgreSQL and SQLite. You can order and filter by them: `filter(qs; rank = 1)` wraps the query, because SQL can't filter on a window function directly. Plain conditions in the same queryset apply before the window is computed, as in Django.
- **`FilteredRelation`:** join a relation with an extra condition in the JOIN's `ON` clause, so authors without a match are kept and aggregates see only matching rows. It works with forward and reverse relations, one level deep:
  - `qs = annotate(Author; pub = FilteredRelation(:posts; condition = Q(posts__published = true)))`
  - `annotate(qs; n = Count(:pub))`, `filter(qs; pub__title__contains = "Julia")`, `exclude(qs; pub__views = 0)`, `order_by(qs, "pub__views")`
- **`values()` is lazy.** It returns a queryset whose rows are `Dict`s. Aggregates in `annotate` after `values(:field)` group by that field, and a later `values(...)` only picks the columns. As in Django, a row has the fields `values()` names, and the annotations made after it (an annotation made before it is there only if it's named). As in Django, combining aggregates over two different reverse relations multiplies rows, so use `distinct=true`.

**More functions** live in `Juango.Functions` (Django's `django.db.models.functions`):

```julia
using Juango.Functions
annotate(Product; slug = Lower(Replace(:name, " ", "-")), code = LPad(Cast(:id, :string), 6, "0"),
         cheapest = Least(:price, :sale_price), net = Round(F(:price) / 1.2, 2), h = SHA256(:name))
aggregate(Product; sd = StdDev(:price), names = StringAgg(:name, ", "; ordering = "name"),
          ids = ArrayAgg(:id; ordering = "-id"), total = Sum(:price; default = 0))
filter(Product; name__regex = "^[A-Z]{2}-\\d+", code__iregex = "x\$")
```

- **Comparison and text:** `Greatest`, `Least`, `NullIf`, `Collate`, `Replace`, `Substr`, `Left`, `Right`, `Trim`, `LTrim`, `RTrim`, `LPad`, `RPad`, `Repeat`, `Reverse`, `StrIndex`, `MD5`, `SHA256`, `Chr` and `Ord`.
- **Math:** `Abs`, `Round`, `Ceil`, `Floor`, `Mod`, `Power`, `Sqrt`, `Sign`, `Ln`, `Log`, `Exp`, the trigonometric functions, `Degrees`, `Radians` and `Pi`.
- **Aggregates:** `StdDev` and `Variance` (`sample = true`), `StringAgg`, `ArrayAgg` (also `JSONBAgg`), `BoolAnd`, `BoolOr`, `BitAnd` and `BitOr`. Every aggregate takes `filter =` and `default =`.
- **How they work on each database.** `ArrayAgg` builds a JSON array in the database, so it works everywhere, and dates come back as text. MySQL ignores the ordering of `ArrayAgg`; MariaDB respects it. `Greatest`/`Least` follow each database's NULL rules. SQLite lacks many of these functions, so Juango registers Julia versions on its connections.
- **Regular expressions.** `regex` and `iregex` lookups use the database's own syntax: `~` and `~*` on Postgres, PCRE or ICU on MySQL, and Julia's PCRE on SQLite.

#### Async

Views already run as tasks on a thread pool, so blocking database calls don't hold up the server. For starting work and collecting it later, or running queries side by side, Juango has Django's async names. Each returns a `Task`:

```julia
t1, t2 = acount(Post), afirst(filter(Comment; approved = false))
n, c = fetch(t1), fetch(t2)
post = fetch(acreate(Post; title = "x"))
for p in aiterator(objects(Post)) ... end            # rows fetched by a background task
```

There are `aget`, `acreate`, `acount`, `aexists`, `afirst`, `alast`, `acollect`, `aget_or_create`, `aupdate_or_create`, `abulk_create`, `abulk_update`, `aaggregate`, `ain_bulk`, `aupdate!`, `adelete!`, `asave!`, `arefresh!` and `aauthenticate`, plus `run_async(f)` and `sync_to_async(f)` for your own functions. The task runs with the caller's database alias, language and time zone. Inside `atomic()` the work runs at once in the calling task instead, so it's part of the transaction. A view may return a `Task`, and the handler waits for it.

#### GIS (PostGIS)

```julia
using Juango.GIS

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

`CharField(db_collation = "C")` (or `TextField`) gives the column a collation, for a case- or accent-insensitive column, or byte order: `"C"` or an ICU collation such as `"und-x-icu"` on PostgreSQL, `"utf8mb4_bin"` on MySQL, `"NOCASE"` on SQLite. Changing it is a migration (`AlterField`).

`Meta(order_with_respect_to = :question)` keeps each question's answers in an order of their own, as Django's: a hidden `_order` column (a migration adds it), new answers go last, `get_order(question, Answer)` gives their ids in order, `set_order!(question, Answer, ids)` reorders them, and `get_next_in_order(answer)` / `get_previous_in_order(answer)` step through them. It's the default ordering unless `Meta(ordering)` says otherwise.

`Meta(default_related_name = "%(class)s_items")` names the reverse side of a model's relations that don't set `related_name` (and their query name), as Django's.

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
- **One-to-one fields.** `user.profile` is the object or `nothing` (Django raises), remembered once read, missing included. `user.profile = p` points `p`'s key at the user (save `p`), and `= nothing` clears the key of the one it had. Reading one side caches the other, so `profile.user.profile` makes no second query. `OneToOneField(Place; primary_key = true)` makes the relation the table's key: `restaurant.pk == place.id`, and foreign keys to it store that id.

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
Juango.get_for_model(Post), Juango.model_class(ct)   # ContentType <-> model
```

- **Content types:** `migrate` fills the `ContentType` table, whose migration ships with Juango.
- **`GenericRelation`** supports lookups (the join also matches the content type), `Count(:comments)`, `prefetch_related(:comments)`, and deleting the object deletes its comments. `prefetch_related(:content_object)` loads mixed targets with one query per model.

#### Constraints, database defaults and generated columns

```julia
@model struct Booking
    room = CharField(max_length = 10)
    start = DateField()
    stop = DateField()
    cancelled = BooleanField(default = false)
    code = CharField(max_length = 10, blank = true)
    created = DateTimeField(db_default = Now())          # the database fills it in on INSERT
    room_upper = GeneratedField(expression = Upper(:room), output_field = CharField(max_length = 10))
    Meta(constraints = [
        CheckConstraint(condition = Q(stop__gte = F(:start)), name = "stop_after_start"),
        UniqueConstraint(fields = [:room, :start], condition = Q(cancelled = false), name = "one_per_day"),
        UniqueConstraint(Lower(:code); name = "code_ci_unique"),
    ])
end
```

- Constraints are created and dropped by migrations, enforced by the database, and checked by `full_clean` and model forms, which report a violation as a form-wide error. MySQL/MariaDB can't build conditional or expression unique indexes, so there only the validation applies. `unique_together` is validated the same way now.
- A `db_default` field holds `DB_DEFAULT` until the object is saved. The value the database chose is then read back. A `db_default` can be a value or `Now()`.
- A `GeneratedField` is computed by the database and read back after every `save!`. It can use `F`, literals, `+ - * /`, `Lower`, `Upper`, `Length`, `Coalesce` and `Concat`. `db_persist = false` makes a virtual column; PostgreSQL only has stored ones.

A field can be the primary key instead of `id`, as Django's `primary_key=True`:

```julia
@model struct Country
    code = CharField(max_length = 2, primary_key = true)   # obj.pk == "NZ"; no id column
    name = CharField(max_length = 60)
end
@model struct City
    country = ForeignKey(Country, on_delete = :CASCADE)   # stores the code: city.country_id == "NZ"
end
```

`get(Country; pk = "NZ")`, foreign keys, many-to-many fields, `select_related`, cascades and forms work with it. Saving an object after changing its key writes a new row, as in Django.

A table can have a composite primary key instead of `id`:

```julia
@model struct OrderLine
    order = ForeignKey(Order, on_delete = :CASCADE)
    product = CharField(max_length = 20)
    qty = IntegerField(default = 1)
    Meta(pk = CompositePrimaryKey(:order, :product))
end
line = get(OrderLine; pk = (order.id, "apple"))     # line.pk == (order.id, "apple")
filter(OrderLine; pk__in = [(1, "apple"), (1, "pear")])
```

Saving with a changed key field writes a new row. As in Django, it can't use multi-table inheritance, and a plain `ForeignKey` or many-to-many field can't point at it: other models point at it with a `ForeignObject`, a relation through fields they already have (Django's multi-column relation):

```julia
@model struct Shipment
    order = ForeignKey(Order, on_delete = :CASCADE)
    product = CharField(max_length = 20)
    line = ForeignObject(OrderLine; from_fields = (:order, :product), related_name = :shipments)
end
s.line; s.line = other_line            # read it, or set order_id and product together
line.shipments                         # the reverse queryset
filter(Shipment; line__qty__gt = 2); filter(OrderLine; shipments__id = 3)
```

`to_fields` defaults to the target's primary key, so a `ForeignObject` can point at any model. Deleting the target applies `on_delete` (`:CASCADE` by default, `:SET_NULL`, `:PROTECT`, `:RESTRICT`, `:DO_NOTHING`). There is no database constraint, and the relation isn't a form field: forms edit the fields it is made of.

The admin supports composite-key models. Their URLs carry the key as `7,apple` (each part escaped as Django's admin does, so a comma inside a value becomes `_2C`; `pk_string(obj)` and `parse_pk(Model, s)` convert). The key fields can be filled in when adding and are read-only afterwards.

#### JSON, arrays, UUIDs, ranges and full-text search

```julia
using UUIDs: uuid4
using Juango.Postgres                                    # CICharField, GinIndex, SearchVector ...

@model struct Event
    data   = JSONField(default = Dict)                  # jsonb on Postgres, JSON text on SQLite
    tags   = ArrayField(CharField(max_length = 20); default = Vector{String})
    token  = UUIDField(default = uuid4)
    email  = CICharField(max_length = 200)              # case-insensitive (citext / NOCASE)
    ages   = IntegerRangeField(null = true)             # also DateRangeField, DateTimeRangeField, DecimalRangeField
    Meta(indexes = [GinIndex(:data), Index(:email; name = "event_email", unique = true)])   # also GistIndex, BrinIndex,
end                                                                                       # SpGistIndex, HashIndex, BloomIndex

# migrations: AddIndexConcurrently / RemoveIndexConcurrently build an index without locking the table
# (the migration then runs outside a transaction, as Django's atomic = False)

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
- **Postgres extension:** `CICharField` creates the `citext` extension the first time a table needs it (and `HStoreField` the `hstore` one).
- **Partial and expression indexes:** `Index(:handle; name = "...", unique = true, condition = Q(active = true))` indexes only the rows that match, `Index(Lower(:email); name = "...")` indexes an expression, and on Postgres `include = [:field]` and `opclasses = ["varchar_pattern_ops"]` are supported. MySQL/MariaDB skip partial and expression indexes.
- **Comments:** `TextField(db_comment = "...")` and `Meta(db_table_comment = "...")` become database comments on Postgres and MySQL/MariaDB (SQLite has none). Migrations track them.

#### PostgreSQL extras

```julia
using Juango.Postgres

@model struct Booking
    room   = IntegerField()
    during = DateRangeField()
    attrs  = HStoreField(default = Dict)                 # hstore on Postgres, JSON elsewhere
    Meta(constraints = [ExclusionConstraint(name = "no_overlap",
                                            expressions = [(:room, "="), (:during, "&&")])])
end
filter(Booking; attrs__color = "red", attrs__has_key = "size", attrs__contains = Dict("x" => "1"))
filter(Post; title__trigram_similar = "julai", title__unaccent__icontains = "cafe")
order_by(annotate(Post; sim = TrigramSimilarity(:title, "julia")), "-sim")    # also TrigramDistance, Unaccent
```

- `ExclusionConstraint` (GiST or SP-GiST, with an optional `condition`) is enforced by Postgres only. `full_clean` checks it there when the operators are `=` and `&&`. `=` on a plain column inside GiST needs the `btree_gist` extension.
- The trigram lookups and expressions need `pg_trgm`, and `unaccent` needs the `unaccent` extension. Create extensions in a migration with `CreateExtension("name")` or `HStoreExtension()`, `TrigramExtension()`, `UnaccentExtension()`, `BtreeGistExtension()`, `BtreeGinExtension()`, `CITextExtension()`. These operations do nothing on other databases.

Computed attributes for templates (and `obj.name` in Julia) use `tattr`, and `tattr!` makes one settable, in assignments and constructors (`Sample(well = "B3")`, `create`, `bulk_create`):

```julia
Juango.tattr(p::Post, ::Val{:summary}) = first(p.body, 100)
Juango.tattr(s::Sample, ::Val{:well}) = well_name(s.position)
Juango.tattr!(s::Sample, ::Val{:well}, v) = (s.position = well_position(v))
```

Values that aren't fields and aren't saved go in `instance_cache(obj)`, a `Dict` on the object that `obj.name` and `{{ obj.name }}` read after the fields and relations: `get!(() -> expensive_total(order), instance_cache(order), :total)`. Assigning to a name that's neither a field nor a `tattr!` is still an error, so typos don't pass silently.

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

Juango's own features are apps too: `juango.admin`, `juango.auth`, `juango.contenttypes`, `juango.sessions` and `juango.messages`, all installed by default, plus the optional `juango.flatpages`. Each owns its models and migrations, as in Django: `auth.User`, `auth.Group`, `auth.Permission`, `contenttypes.ContentType`, `sessions.SessionRecord`, `admin.LogEntry` and `flatpages.FlatPage`, with permission names such as `auth.change_user`. A project can leave any of them out. That app's tables are then not created, and its URLs (`Admin.urls()` and `auth_urls()` refuse to run) and commands (`createsuperuser`, `changepassword`, `clearsessions`) go too. `manage.jl check` reports apps whose requirements are missing (admin needs auth, contenttypes, sessions and messages; auth needs contenttypes). `installed_apps()`, `is_installed("blog")`, `get_app("blog")` and `app_models("blog")` query the registry.

### Migrations

Migrations are versioned, reviewable files that move the database schema forwards and backwards:

```sh
julia --project manage.jl makemigrations          # writes migrations/0002_post_status.jl
julia --project manage.jl sqlmigrate 0002         # the SQL it will run (--backwards for the reverse)
julia --project manage.jl migrate                 # apply everything pending
julia --project manage.jl migrate 0001            # go back to 0001, unapplying 0002 and later
julia --project manage.jl migrate zero            # unapply all of the project's migrations
julia --project manage.jl showmigrations          # [X] applied, [ ] pending (showmigrations blog --plan: one app, in order)
julia --project manage.jl migrate --plan          # what migrate would do, without doing it
julia --project manage.jl migrate --check         # exit status 1 if any migration is unapplied (for deploy scripts)
julia --project manage.jl sqlflush                # the SQL flush would run; sqlsequencereset <app> moves id sequences (PostgreSQL)
```

`makemigrations` compares your models with the state the existing migration files describe and writes the difference as operations. These are `CreateModel`, `DeleteModel`, `RenameModel`, `AddField`, `RemoveField`, `AlterField` and `RenameField`. When a column (or table) disappears and an identical one appears under a new name, it asks whether you renamed it (a table counts as identical when its columns' definitions match, so a table renamed together with a column is asked about both). With `--noinput` the answer is no. A model whose table name changed (a new `Meta(table = ...)`, or the default name) is renamed without asking. A model's table is `<app label>_<model name>` (`blog_post`), as Django's, unless `Meta(table = ...)` names one; many-to-many join tables add the field's name (`blog_post_tags`). A generated file looks like this:

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

- **Data migrations.** `makemigrations --empty --name backfill` writes a file to fill in with `RunSQL(forward, backward)` or `RunJulia(forward_fn, backward_fn)`. A `RunSQL` string may hold several statements separated by `;`, or give a vector of statements and `(sql, params)` pairs with `?` placeholders. A `RunJulia` function that takes an argument gets the models as they were at that point in history, so it doesn't depend on today's model structs:

  ```julia
  RunJulia(apps -> begin
      Post = get_model(apps, "blog", "Post")
      for p in objects(Post)                      # rows with the columns of that time
          p.slug = lowercase(replace(p.title, " " => "-")); save!(p)
      end
  end)
  ```

  Historical models support `objects`, `filter`/`get`/`count` with column lookups, `create`, `save!`, `update!(Model, (; lookups...); values...)` and `delete!`. Rows have their columns (`p.author_id`) and relations as they were then: foreign keys (`p.author`, and `p.author = a`), many-to-many fields with an auto-created join table (`p.tags`, with `add!`, `remove!` and `clear!`), and reverse accessors named `<model>_set` (`a.post_set`, which also takes `filter`, `count` and `create`). Historical states don't keep `related_name` or methods.
- **Squashing.** `squashmigrations blog 0004` (or `manage.jl squashmigrations blog 0004`) writes one migration that replaces 0001 to 0004. Tables created in the range become a single `CreateModel`. Databases that applied all or none of the originals use it, the rest keep the originals. When every database has moved past it, delete the old files and the `replaces` line. Ranges with `RunSQL`/`RunJulia` are refused.
- **Optimizing.** `optimizemigration blog 0005` rewrites one migration with fewer operations. An `AddField` absorbs later `AlterField`s of its column, an `AddField` followed by `RemoveField` cancels out, repeated `AlterField`s collapse, and tables created and changed in the migration become one `CreateModel`. `--check` only reports. `makemigrations --update` folds new model changes into the latest migration, as long as it hasn't been applied.
- **`SeparateDatabaseAndState(database_operations = [...], state_operations = [...])`** runs SQL changes and state changes separately. For example, it can start managing a table that already exists, or move a model between apps without touching its table.
- **Pruning.** After you delete migration files that a squashed migration replaced, `migrate blog --prune` (or `migrate(app = "blog", prune = true)`) removes their records from the history.
- **Transactions.** Each migration runs in a transaction. If it fails, nothing is applied.
- **SQLite.** SQLite can't alter or drop columns in place, so those changes rebuild the table: create a copy, move the rows, then swap. On Postgres they are ordinary `ALTER TABLE` statements.
- **Backfill.** Adding a NOT NULL column without a default fills existing rows with `""`, `0`, `false` or 1970-01-01, and `makemigrations` says so.
- **Conflicts.** Two branches that both added a migration conflict. `migrate` refuses to run, and `makemigrations --merge` writes a merge migration.
- **Checking in CI.** `makemigrations --check` exits with status 1 if models have changes without a migration.
- **What's tracked.** Only schema attributes are tracked: column type, `null`, database default, `unique`, `db_index` and the foreign key target. Changing `choices`, `help_text` or validators never creates a migration.

**Apps.** Juango's own apps (`auth`, `contenttypes`, `sessions`, `admin`, `flatpages`) ship their migrations with Juango, and they are applied only for installed apps. Models defined in an `App`'s module use that app's `migrations/` folder (see Apps). Your other models are the `project` app, stored in `settings.MIGRATIONS_DIR` (`startproject` sets it to `<project>/migrations`). A model can also opt into another app with `Meta(app_label = "billing")` plus `MIGRATION_MODULES = Dict("billing" => "path/to/dir")`.

**No migration files yet?** An app without migration files is synchronised: missing tables and columns are created and nothing is altered, which is how Juango worked before migrations existed. `migrate --sync` does that for every app. When you switch an existing database over, run `makemigrations`, then `migrate`. Initial migrations whose tables and columns already exist are marked as applied ("FAKED") instead of run, as Django's `--fake-initial` does. Juango does this by default; pass `--no-fake-initial` (`fake_initial = false`) to run them anyway. `migrate --fake` records migrations without running them, as in Django.

#### Migration safety

Some migrations are fine on a laptop and break a running site: the code of the previous release keeps serving requests while they run. `makemigrations` warns when it writes one, and `manage.jl check --tag migrations` reports the unapplied ones (`MIGRATION_LINT = :error` makes that fail CI; `false` turns it off). The safe sequences:

| Warning | Problem | Safe way |
|---|---|---|
| `migrations.W001` | A NOT NULL column without a database default: inserts by the old code fail. | Add it with `null = true` (or `db_default`), deploy, backfill, then make it NOT NULL. |
| `migrations.W002` | Removing a column or table the old code still uses. | Deploy the code without the field or model first (`SeparateDatabaseAndState` drops it from the state), then drop it in a later migration. |
| `migrations.W003` | Renaming a column or table. | Keep the database name (`db_column`, `Meta(table = ...)`), or add the new column, write both, backfill, switch, drop the old one. |
| `migrations.W004` | Changing a column's type rewrites the table under a lock. | A new column of the new type, backfilled, then switch over. |
| `migrations.W005` | An index (or unique constraint) built without CONCURRENTLY blocks writes on PostgreSQL. | `AddIndexConcurrently`, in a migration of its own. |
| `migrations.W006` | SET NOT NULL scans the table under a lock. | On PostgreSQL: `CHECK (col IS NOT NULL) NOT VALID`, `VALIDATE CONSTRAINT`, then `SET NOT NULL`. |
| `migrations.W007` | An AlterField may rebuild the table on MySQL/MariaDB. | Check it's INSTANT/INPLACE on your server, or run it at a quiet time. |

Changes to tables created in the same migration, and initial migrations, are fine. A migration file containing `# juango: allow-unsafe` is accepted as it is (a small table, a maintenance window).

### Database backends

The ORM talks to the database through a `DatabaseBackend`. Each backend supplies the driver calls, its SQL dialect (quoting, column types, lookups, `LIMIT`, inserts that return ids) and the introspection that `migrate()` needs. SQL is written by hand, with no query builder in between.

```julia
configure!(DATABASE = "db.sqlite3")             # SQLite file (the default backend)
configure!(DATABASE = ":memory:")               # in-memory SQLite
configure!(DATABASE = "sqlite:///db.sqlite3")   # the same, as a URL
configure!(DATABASE = "postgresql://user:pass@localhost:5432/mydb")   # PostgreSQL
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

#### Multiple databases

```julia
configure!(DATABASES = Dict("default" => "postgresql://localhost/app",
                            "replica" => "postgresql://replica/app",
                            "archive" => "archive.sqlite3"))
migrate(database = "archive")                       # manage.jl migrate --database archive

using_db(objects(Post), "replica")                  # one queryset
save!(post; db = "archive")                         # one save
using_db("archive") do                              # everything in the block
    create(Post; title = "old")
end
atomic(db = "archive") do ... end                   # a transaction on that database
```

Without `DATABASES`, `DATABASE` is the "default" database. Each database has its own connections and transactions. An object remembers the database it was loaded from or saved to: saving it again, `refresh!` and following its relations use that database. Saving an object together with a related object from another database raises an error, unless a router allows the relation.

Routers (`DATABASE_ROUTERS`) choose a database for each model. A router is any value whose type has methods of `Juango.db_for_read`, `db_for_write`, `allow_relation` and `allow_migrate`. Each returns an alias (or `true`/`false`), or `nothing` to leave the decision to the next router:

```julia
struct PrimaryReplica end
Juango.db_for_read(::PrimaryReplica, ::Type) = "replica"
Juango.db_for_write(::PrimaryReplica, ::Type) = "default"
Juango.allow_migrate(::PrimaryReplica, db, app_label; model = nothing) = db == "default"
configure!(DATABASE_ROUTERS = [PrimaryReplica()])
```

An explicit database (`using_db`, `db = ...`) beats a `using_db` block, which beats the object's own database, which beats the routers. Where `allow_migrate` says no, `migrate` records an app's migrations without running them.

#### PostgreSQL

PostgreSQL works out of the box: Juango talks to libpq, the PostgreSQL client library, directly (it comes with Juango as `LibPQ_jll`). Point `DATABASE` at the server:

```julia
using Juango
configure!(DATABASE = "postgresql://user:pass@localhost:5432/mydb")
```

The URL is passed to libpq, so its query parameters work (`postgresql:///mydb?host=/var/run/postgresql` for a Unix socket), and the usual `PG*` environment variables and `~/.pgpass` apply. Juango doesn't use LibPQ.jl: its dependencies invalidated thousands of compiled methods when they loaded, which made a PostgreSQL project start several times more slowly than an SQLite one. Errors other than constraint violations raise `DatabaseError(msg, sqlstate)`.

The database must already exist (`createdb mydb`). `migrate()` creates the tables. Postgres uses native types: `BOOLEAN`, `TIMESTAMP`, `DATE`, `DOUBLE PRECISION`, `BIGINT` identity primary keys, and `VARCHAR(n)` for `CharField(max_length=n)`. Foreign keys become real constraints (`DEFERRABLE INITIALLY DEFERRED`). Deletes still cascade through the ORM according to `on_delete`, so `:DO_NOTHING` raises `IntegrityError` while referencing rows still exist. Case-insensitive lookups use `ILIKE`.

SQLite stores booleans as 0/1 and timestamps as ISO-8601 text. The ORM converts both ways, so model code doesn't change between backends.

Write raw SQL with `?` placeholders: `Juango.execute("SELECT * FROM post WHERE id = ?", [1])`. Each backend rewrites `?` into its own placeholder style. Constraint violations raise `IntegrityError` on every backend.

To add a backend, subtype `Juango.DatabaseBackend`, implement the driver methods, override any dialect methods that differ from standard SQL, and call `register_backend!("scheme", url -> MyBackend(url))`. The interface is documented at the top of `src/db/connection.jl`. The implementations are in `src/db/backends/` (the PostgreSQL driver is `libpq.jl`), with the MySQL driver in `ext/`.

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

Query-string parameters can be read typed, so junk in the URL is a 400 Bad Request instead of a 500 from `parse`: `query_param(req, :page, Int; default = 1)`, `query_param(req, :since, Date)` (required: missing is a 400 too), `query_param(req, :sort, Symbol; default = :name, choices = (:name, :date))`, and `Vector{Int}` for a repeated parameter. `Bool`, `Float64`, `Decimal`, `DateTime` and `String` work as well.

Converters: `str int slug path uuid`, plus `register_converter!`.

An app mounted more than once gets an application namespace and an instance namespace per mount,
as Django's `app_name`: `include_urls(blog_patterns; app_name = "blog", namespace = "news")`. Then
`reverse_url("blog:post", 3)` and `{% url 'blog:post' 3 %}` give the instance the current request
is in, or `current_app = "news"`, or the instance named like the app.

View decorators besides `require_GET`/`require_POST`/`require_safe` and `login_required`:
`csrf_exempt`, `csrf_protect` (for projects without the middleware), `ensure_csrf_cookie`,
`xframe_options_exempt`/`_deny`/`_sameorigin`, `gzip_page`, `never_cache`, `cache_page`,
`no_append_slash` and `sensitive_post_parameters(view, "card")` (masked on the error page and in
error emails). `set_signed_cookie!(resp, name, value)` and `get_signed_cookie(req, name; max_age)`
keep a cookie the client can read but not change. `HttpResponseGone`, `HttpResponseNotModified`
and `HttpResponseServerError` complete the response shortcuts.

#### Transactions, error pages and TemplateResponse

```julia
configure!(ATOMIC_REQUESTS = true)                 # each view in a transaction (or a list of database aliases)
path("report/", non_atomic_requests(report))       # this one manages its own transactions

configure!(HANDLER404 = (req; exception) -> render(req, "errors/404.html"; status = 404),
           HANDLER500 = req -> HttpResponse("Sorry!"; status = 500))   # also HANDLER400, HANDLER403

article(req; id) = TemplateResponse(req, "article.html", Dict("article" => get(Article; id)))
Juango.process_template_response(::typeof(MyMiddleware), req, resp) = (resp.context_data["ad"] = pick_ad(); resp)
```

- **`ATOMIC_REQUESTS`.** If the view throws, its transaction is rolled back and the error page is shown, as in Django.
- **Error views.** Without them, the `404.html`, `403.html`, `400.html` and `500.html` templates are used. With `DEBUG`, 404s and 500s show the debug pages instead. An error view that fails itself falls back to the built-in page. `manage.jl check` reports error views with the wrong signature.
- **The DEBUG 500 page.** As Django's, it shows:
  - the exception and the exceptions it was raised while handling;
  - each frame, innermost first, with its argument types and the source around the line: your code open, Juango's dimmed, Base's and packages' folded;
  - for an error while rendering a template, the template and line, with the source around it;
  - the request and the settings, with anything that looks secret masked (cookies, passwords in database URLs, settings named like KEY, TOKEN, SECRET or PASS);
  - a copy-and-paste text version.

  The same text is what `mail_admins` sends for a 500 when DEBUG is off. Julia's backtraces don't keep local variables, so unlike Django's page it has none.
- **`TemplateResponse`** is rendered after the middleware's `process_template_response` methods run. Until then, `resp.template_name` and `resp.context_data` can still change.

### Generic views

`TemplateView`, `RedirectView`, `ListView`, `DetailView`, `CreateView`, `UpdateView`, `DeleteView` and `FormView` are configured with keywords (`template`, `queryset`, `paginate_by`, `fields`, `success_url`, `extra_context`, `context_object_name`...). Any step can be replaced with a hook. A hook receives the `ViewCall` `v`, which holds `v.request`, the URL's `v.kwargs`, `v.object`, `v.object_list`, `v.form` and `v.model`. Inside a hook, `default_hook(name, v, args...)` runs the built-in step, like `super()`:

```julia
my_posts = ListView(Post; paginate_by = 20, login_required = true,
                    get_queryset = v -> filter(objects(Post); author = v.request.user),
                    get_context_data = (v, ctx) -> (ctx["today"] = today(); ctx))

new_post = CreateView(Post; fields = [:title, :body], login_required = true,
                      success_message = "“%(title)s” was published.",
                      form_valid = (v, form) -> (form.instance.author = v.request.user;
                                                 default_hook(:form_valid, v, form)))

contact = FormView(ContactForm; template = "contact.html", success_url = "/thanks/",
                   form_valid = (v, form) -> (send_mail("Contact", form.cleaned_data[:message], ...);
                                              default_hook(:form_valid, v, form)))
```

The hooks are `get_queryset`, `get_object`, `get_context_data(v, ctx)`, `get_template_names`, `get_success_url`, `get_initial`, `get_form`, `form_valid(v, form)` and `form_invalid(v, form)`. DeleteView deletes in its `form_valid` step, where the form is `nothing`. Templates get `view` too.

Access control works on every generic view: `login_required = true`, `permission_required = "blog.change_post"` (403 when the user lacks it), and `test_func = user -> user.is_staff` (a logged-in user who fails it gets 403, an anonymous one the login page, as Django's UserPassesTestMixin). For other views, the wrappers `LoginRequiredMixin(view)`, `PermissionRequiredMixin(view, perms...)` and `UserPassesTestMixin(view, test)` do the same, with Django's AccessMixin options: `login_url`, `redirect_field_name`, `raise_exception` and `permission_denied_message`. `success_message` (the SuccessMessageMixin) takes `%(field)s` placeholders from the cleaned data.

Date-based archives take a `date_field`:

```julia
A(view; kw...) = view(Post; date_field = :published, kw...)
path("archive/", A(ArchiveIndexView)),                         # latest, date_list (years)
path("archive/<int:year>/", A(YearArchiveView)),               # year, date_list (months), next_year, previous_year
path("archive/<int:year>/<int:month>/", A(MonthArchiveView)),  # month, object_list, date_list (days), next_month...
path("archive/<int:year>/<int:month>/<int:day>/", A(DayArchiveView)),
path("archive/<int:year>/<int:month>/<int:day>/<slug:slug>/", A(DateDetailView)),
path("archive/week/<int:year>/<int:week>/", A(WeekArchiveView)),  # week (its first day), object_list; week_format = "%U" | "%W" | "%V"
path("archive/today/", A(TodayArchiveView)),                    # DayArchiveView for today
```

Future-dated objects are left out unless `allow_future = true`. An empty period is a 404 unless `allow_empty = true`. YearArchiveView lists its objects only with `make_object_list = true`. The default templates are `<model>_archive.html`, `_archive_year`, `_archive_month`, `_archive_day` and `_detail`. With USE_TZ, days are counted in the current time zone.

### Filtering lists: FilterSet

Filters for a list page from its GET parameters, in the manner of django-filter:

```julia
function posts(req)
    fs = FilterSet(Post, [
        :title   => CharFilter(lookup = "icontains"),
        :status  => ChoiceFilter(),                                       # the model field's choices
        :author  => ModelChoiceFilter(r -> filter(Author; team = r.user.team)),   # choices for this request
        :tags    => ModelMultipleChoiceFilter(objects(Tag)),              # any of them (made distinct)
        :created => DateFromToRangeFilter(),                              # ?created_after=...&created_before=...
        :draft   => IsNullFilter(field_name = :published_at),
        :q       => CharFilter(method = (qs, name, v) -> filter(qs, Q(title__icontains = v) | Q(body__icontains = v))),
        :o       => OrderingFilter([:created, :title, "author__name" => "author"]),    # ?o=-created,title
    ]; data = req.GET, request = req)
    render(req, "posts.html", Dict("filter" => fs, "page_obj" => get_page(Paginator(fs.qs, 20), get(req.GET, "page", "1"))))
end
```

```
<form method="get">{{ filter.form.title.label_tag }} {{ filter.form.title }} {{ filter.form.title.errors }} ...</form>
{% for post in page_obj %}...{% endfor %}
<a href="{% querystring page=page_obj.next_page_number %}">next</a>      {# keeps the filters #}
```

- **Filters:** `CharFilter`, `NumberFilter`, `BooleanFilter` (yes/no/either), `ChoiceFilter`, `MultipleChoiceFilter`, `ModelChoiceFilter`, `ModelMultipleChoiceFilter`, `DateFilter`, `DateTimeFilter`, `DateFromToRangeFilter`, `NumberRangeFilter` (`_min`/`_max`), `IsNullFilter` and `OrderingFilter`. Each takes `field_name` (a path such as `"author__name"`; the filter's name by default), `lookup` (any lookup `filter` takes; `in` on a `CharFilter` splits commas), `exclude`, `distinct`, `label`, `method` and `form_field`.
- **From model fields:** `FilterSet(Post; fields = [:status, :author], data = req.GET)`, or with lookups, `fields = Dict(:views => ["gte", "lte"])` (named `views__gte` ...).
- **Results:** `fs.qs` is the filtered queryset, to chain, paginate or count; `fs.form` is the bound form. An empty value leaves its filter out, and so does an invalid one, whose field shows the error, so a stale or mistyped URL still lists results. A date range on a datetime field includes the whole of the last day.

### Tables

`using Juango.Tables` gives django-tables2's tables. They take a model, a queryset or a list of
rows, and have sortable headers, pagination, footers and CSV/XLSX export:

```julia
using Juango.Tables

function article_list(req)
    table = Table(filter(Article; published = true), req;
                  columns = [:title => LinkColumn(),                                # to get_absolute_url
                             :author => Column(accessor = "author__name", order_by = "author__name"),
                             :views => Column(footer = t -> sum(a.views for a in t.data)),
                             :published => BooleanColumn(),
                             :created => DateTimeColumn(format = "Y-m-d H:i"),
                             :edit => TemplateColumn("<a href=\"{% url 'edit' record.id %}\">Edit</a>")],
                  order_by = "-created", per_page = 25)
    r = export_response(table)                     # ?_export=csv or ?_export=xlsx: the whole table
    r === nothing || return r
    render(req, "articles.html", Dict("table" => table))    # {% render_table table %}
end
```

CSV exports (here and the admin's `export_csv`) prefix text starting with `=`, `+`, `-` or `@` with `'`, so a value like `=HYPERLINK(...)` opens in a spreadsheet as text, not as a live formula (`export_response(t; csv_formulas = true)` turns that off; `csv_field(v)` does it for your own CSV).

- **Sorting:** clicking a header sorts by it (`?sort=views`, again for `-views`), keeping the page's other parameters. Querysets sort in the database, other rows in Julia.
- **Columns:** `columns = nothing` takes the model's fields. `exclude` and `sequence = [:title, :..., :edit]` change the set and order.
- **Column options:** `label`, `accessor` (a path such as `"author__name"`), `order_by`/`orderable`, `linkify`, `default` for empty values, `render = (value, record) -> html`, `value = (value, record) -> export value`, `footer`, and `attrs = Dict("th" => ..., "td" => ...)`.
- **Column types:** `BooleanColumn`, `DateColumn`/`DateTimeColumn`, `TemplateColumn`, `LinkColumn`, `CheckBoxColumn`, `ManyToManyColumn`, `EmailColumn` and `URLColumn`.
- **Several tables on a page:** `prefix = "t1-"` keeps their parameters apart. `template_name` renders a table with your own template (context `table`).

`XlsxResponse(rows; filename = "report.xlsx")` and `write_xlsx(path, rows)` write a spreadsheet
of values, without another package. Numbers, booleans, dates and datetimes become real Excel
values, and the first row is a bold header.

### Importing and exporting rows (django-import-export)

Reference data often lives in spreadsheets that staff maintain. A resource says how a model's rows map to columns:

```julia
r = ModelResource(Sample; fields = [:code, :name, :plate, :volume], import_id_fields = [:code],
                  fk = Dict(:plate => :label), headers = Dict(:volume => "Volume (µl)"))
export_data(r, filter(Sample; plate__project = p); format = :xlsx)     # bytes: :csv, :xlsx or :json
export_download(r, qs; format = :csv)                                  # an attachment, from a view
res = import_data(r, read(path); format = :xlsx)                        # a dry run: nothing is kept
res.totals                                                              # :new, :update, :skip, :delete, :invalid
has_errors(res) || import_data(r, read(path); format = :xlsx, dry_run = false)
```

- **Matching:** a row matches its existing record by `import_id_fields` (the id by default; a natural key such as a code is usually better for spreadsheets). Columns match by header, field name or label, ignoring case; others are listed in `res.ignored_columns`.
- **Values** go through the field's form conversion and the model's validation (`full_clean`). Foreign keys and many-to-many fields are given by id, or by a field of the related model (`fk`), a many-to-many as a comma-separated list. Excel dates are converted.
- **One transaction:** a dry run, or any invalid row, keeps nothing. Each `res.rows` entry has the row's line, what happened, the changed fields (old and new) and the errors.
- **Options:** `skip_unchanged` (default true), `delete_column = "Delete"` (true values delete the row's record) and `before_save = (obj, row) -> ...`.
- **CSV exports** are protected against formula injection (`csv_field`), and imports undo that protection, so an export round-trips. `parse_csv` and `read_xlsx` are there for other uses.

In the admin, `Admin.register!(Sample; import_export = r)` (or `true` for every field) adds Import and Export buttons to the change list. Importing shows a dry run first, row by row, with a button to confirm it; it needs the add and change permissions.

### Typed JSON APIs (django-ninja style)

Django's answer for APIs is Django REST framework; Juango builds in django-ninja's idea instead: a handler's argument types validate the input and produce OpenAPI docs.

```julia
api = API(title = "Lab API", version = "1")
struct SampleIn; name::String; volume_ul::Float64; plate_id::Int; end
struct SampleOut; id::Int; name::String; well::String; end

get(api, "/samples/{id}"; response = SampleOut) do req, id::Int
    s = get_object_or_404(Sample; id); SampleOut(s.id, s.name, s.well)
end
post(api, "/samples"; status = 201, response = SampleOut) do req, body::SampleIn
    s = create(Sample; name = body.name, volume_ul = body.volume_ul, plate_id = body.plate_id)
    SampleOut(s.id, s.name, s.well)
end
search(req, q::String, limit::Union{Int,Nothing} = nothing) = paginate_api(filter(Sample; name__icontains = q), req)
get(search, api, "/samples/search"; response = ModelSchema(Sample; fields = [:id, :name], many = true))
route!(api, "DELETE", "/samples/{id}"; status = 204) do req, id::Int ... end

urlpatterns = [path("api/", api_urls(api))]        # and api/openapi.json, api/docs (Swagger UI)
```

- **Parameters** come from the handler's arguments after `req`: a name in the path (`{id}`) is a path parameter; a struct (or a vector of them) is the JSON body, decoded with nested structs, vectors, dicts, enums (by name), dates, UUIDs and Decimals; anything else is a query parameter (`Vector{T}` for a repeated one). `Union{T,Nothing}` or a default makes one optional.
- **Bad input** is a 422 listing every problem with where it is, as ninja and FastAPI answer: `{"detail": [{"loc": ["body", "wells", 0, "col"], "msg": "field required"}, ...]}`. Unknown fields are reported too.
- **Replies** are encoded from structs, named tuples, dicts, vectors, models and querysets (through `ModelSchema(Model; fields)`); an `HttpResponse` goes out as it is. `paginate_api(items, req)` pages a list with `?limit=&offset=`.
- **Auth:** `API(; auth = api_key_auth(key -> user))`, `bearer_auth(token -> user)` or `session_auth` (with `csrf = true`: routes are otherwise CSRF-exempt), per API or per route (`auth = false` for a public one); the result is in `req.meta[:api_auth]`, and nothing or `false` is a 401. `add_router!(api, "/plates", plates_api)` nests one API in another.
- **OpenAPI 3.1** is served at `openapi.json` (`openapi_schema(api)`), with schemas from the struct types and `ModelSchema`s, and Swagger UI at `docs`.

### Debug toolbar

`DebugToolbarMiddleware` shows each page's SQL, templates and timings in a panel in the
corner of the page, like django-debug-toolbar. It's for finding N+1 queries in development:
queries that differ only in their parameters are grouped as "similar", repeated ones are
marked as duplicates, and each query says where it came from (your function and line, and
the template it ran in).

```julia
configure!(DEBUG = true, INTERNAL_IPS = ["127.0.0.1", "::1"],
           MIDDLEWARE = [DebugToolbarMiddleware, Juango.default_settings()[:MIDDLEWARE]...])
```

Put it first, so the queries of the other middleware (sessions, authentication) count too, but
after `GZipMiddleware` and `ContentSecurityPolicyMiddleware` if you use them. Only clients in
`INTERNAL_IPS` see it, and only while `DEBUG` is on. `DEBUG_TOOLBAR_SHOW = req -> ...` decides
for itself instead.

- **Panels:** timing (total, SQL, GC and allocation), SQL (statements with parameters,
  duration, database alias and stack), templates (each render, include and extends, with
  the context), request (view, URL name, GET/POST, cookie names, session, headers) and
  response headers.
- **Lazy values stay lazy:** querysets, the lazy user and the other context processors'
  values are shown by type, so the panel never runs a query of its own.
- **Responses without `</body>`:** htmx partials, JSON and other non-HTML responses are
  recorded but left unchanged. Their `X-Juango-Debug` header links to the request's page
  under `/__debug__/` (`DEBUG_TOOLBAR_PREFIX`), which also lists the last 25 requests
  (`DEBUG_TOOLBAR_HISTORY`).
- **Cost:** a backtrace per query; `DEBUG_TOOLBAR_STACKTRACES = false` turns it off.
- **Development only:** it keeps recent requests, with their parameters and session values,
  in memory. Leave it out of production settings.

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

**Concurrency.** `runserver` handles each connection in its own task, so a slow view, a sleeping event stream or an open WebSocket doesn't hold up other requests. Database queries on PostgreSQL wait cooperatively, so other tasks run meanwhile, and each task gets its own pooled connection (see Database backends). Connections are served on Julia's interactive thread pool and views run on the default pool, so start Julia with an interactive thread as well as worker threads (`julia --threads=auto,1 manage.jl runserver`): then views run in parallel on all cores and a busy view never stalls the server. The shared caches (templates, URL reversing, content types, translations and cache backends) are protected by locks. A view can start its own work with `Threads.@spawn`, and the spawned task takes its own database connection.

### Templates

This is the Django template language. The tags:

- `if/elif/else` (with `and or not in == != < > <= >= is`) and `for … empty` (with `forloop.*` and `reversed`)
- `extends`/`block` (with `block.super`) and `include … with … only` (the name may be a variable)
- `with`, `url … as`, `csrf_token`, `static`, `cycle`/`resetcycle`, `firstof`, `now`, `comment`, `verbatim`, `spaceless`, `autoescape`
- `ifchanged`, `regroup … by … as`, `widthratio`, `templatetag`, `filter`, `lorem` and `debug`
- `querystring` (the request's query string with changes: `{% querystring page=2 sort=None %}`)
- `partialdef`/`partial`, plus the translation, time zone and cache tags

Partials are named fragments. Use them in place, or render one alone with `render(req, "page.html#row", ctx)` or `{% include "page.html#row" %}`, which suits htmx-style updates:

```
{% partialdef row %}<tr><td>{{ item.name }}</td></tr>{% endpartialdef %}
{% for item in items %}{% partial row %}{% endfor %}
```

**Components** are reusable pieces with parameters and slots (django-components and django-cotton's idea), better than `{% include %}` with arguments: a template `components/card.html`, its parameters declared with `{% props %}` (unknown or missing ones are errors naming them), slots filled by the page:

```
{# templates/components/card.html #}
{% props title size="md" %}
<div class="card card-{{ size }}"><h3>{{ title }}</h3>{% slot %}{% endslot %}
  {% if slots.footer %}<footer>{% slot "footer" %}{% endslot %}</footer>{% endif %}</div>

{% component "card" title=post.title %}
  {{ post.summary }}
  {% fill "footer" %}<a href="{{ post.get_absolute_url }}">Read more</a>{% endfill %}
{% endcomponent %}
{% component "badge" text="new" / %}
```

A component sees only its parameters, its slots and `request`, `user`, `csrf_token` and `perms`; the contents of a `{% fill %}` render with the page's variables. `component!("chart"; params = [:series, :height => 300], context = (p, req) -> Dict("svg" => draw(p["series"])))` declares one with Julia code computing extra context. Component templates are ordinary templates, so `{% partialdef %}` and htmx partials work inside them.

There are over 60 filters. Among them:

- dates and times: `date time timesince timeuntil`
- text: `default join length truncatechars truncatewords truncatechars_html truncatewords_html wordwrap center ljust rjust`
- HTML: `linebreaks urlize urlizetrunc striptags unordered_list json_script safe escape escapejs`
- lists and numbers: `dictsort slice pluralize add yesno slugify floatformat filesizeformat stringformat get_digit phone2numeric`

Add your own with `register_filter!("name", (value, arg) -> ...)`.

**Tag libraries** work like Django's `@register.simple_tag` and `@register.inclusion_tag`. Templates load them with `{% load name %}`:

```julia
lib = TagLibrary("shop")
price(amount; currency = "€") = "$currency$(round(amount; digits = 2))"
simple_tag!(price, lib, "price")                       # {% price item.cost currency="£" %}, {% price 3 as p %}
inclusion_tag!(lib, "cart", "shop/cart.html"; takes_context = true) do ctx
    Dict("items" => ctx["cart"].items)                 # {% cart %} renders shop/cart.html with this
end
filter!((v, _) -> round(Int, 100v), lib, "cents")      # {% load shop %}{{ x|cents }}
```

`{% load price cents from shop %}` loads single tags or filters. As in Django, `{% load %}` applies to the template it's in, not to the templates it includes or extends. `tag!(lib, name, (parser, token) -> node)` adds a full custom tag, and so does `register_tag!` for every template.

Output is HTML-escaped unless you mark it safe (`mark_safe`, `|safe`). A syntax error names the template file and line, and in DEBUG the error page shows the lines around it.

#### Building HTML, unknown variables and other engines

```julia
format_html("<a href=\"{}\">{}</a>", url, title)                   # arguments are escaped unless already safe
format_html_join("\n", "<li>{}: {}</li>", [(k, v) for (k, v) in pairs(d)])

configure!(TEMPLATE_STRING_IF_INVALID = "MISSING(%s)")             # debugging: unknown variables show up

using Mustache                                                    # a second template engine
configure!(TEMPLATES = [Juango.JuangoTemplates(), Juango.MustacheTemplates(dirs = ["mustache"])])
render(req, "emails/welcome.mustache", Dict("name" => user.username))
```

- **Engines.** `TEMPLATES` lists the engines to search, in order, and the first one that finds the name renders it. `JuangoTemplates(; dirs, app_dirs)` is Juango's own language, and the default uses `TEMPLATE_DIRS`. `MustacheTemplates(; dirs, extension = ".mustache")` uses Mustache.jl once you load it. Context processors work in both.
- **Your own engine.** Give its type a method `Juango.engine_template(engine, name, tried)` that returns a template or `nothing`. Its templates need a `name` and `render(t, context; request)`.

#### humanize

`{% load humanize %}` adds `intcomma` (`1,234,567`, with the active language's separator), `intword` (`1.2 million`), `apnumber` (`four`), `ordinal` (`22nd`), `naturalday` (`today`, `yesterday`, `tomorrow`, else the date) and `naturaltime` (`3 minutes ago`, `an hour from now`).

#### htmx

[htmx](https://htmx.org) comes with Juango, much as django-htmx adds it to Django. Put
`{% htmx_script %}` in your base template's `<head>`: it loads htmx from Juango's static files
(`juango/htmx.min.js`, version 2.0.4), sends the CSRF token with every htmx request, and makes
htmx swap in 422 responses (see forms below). The example blog has active search, infinite
scroll and editing a title in place.

```julia
function post_list(req)
    qs = filter(Post; title__icontains = get(req.GET, "q", ""))
    render(req, "posts.html", Dict("posts" => page(Paginator(qs, 10), get(req.GET, "page", "1")));
           htmx_partial = "results")    # {% partialdef results %} for htmx, the whole page otherwise
end

function edit_title(req; id)
    post = get_object_or_404(Post; id = id)
    form = ModelForm(Post; data = req.method == "POST" ? req.POST : nothing, instance = post, fields = [:title])
    if req.method == "POST" && is_valid(form)
        save!(form)
        message!(req, :success, "Saved.")                       # sent as an out-of-band swap
        return hx_trigger(render(req, "post.html#title", Dict("post" => post)), "post-saved")
    end
    render(req, "post.html#title_form", Dict("post" => post, "form" => form); status = form_status(form))
end
```

- **The request:** `is_htmx(req)` says whether htmx sent it (`boosted = false` leaves out `hx-boost` requests and history restores, which want whole pages). `req.htmx` has the details: `boosted`, `target`, `trigger`, `trigger_name`, `current_url`, `current_url_abs_path`, `history_restore_request` and `prompt`. In templates, use `{% if request.htmx %}`. Reading either marks the response `Vary: HX-Request`, so caches and conditional GETs keep partials and whole pages apart.
- **Responses:**
  - `hx_redirect(url)` makes the browser load a page. A plain redirect would be followed by htmx and the result swapped in.
  - `hx_refresh()` reloads the page.
  - `hx_location(path; target = "#main", ...)` loads `path` with htmx and pushes it to the history.
  - `hx_push_url`, `hx_replace_url`, `hx_retarget`, `hx_reswap` and `hx_reselect` set those headers on a response.
  - `hx_trigger(resp, events; after = :receive | :settle | :swap)` triggers client-side events. `events` is a name, a vector of names, or a Dict of name => detail.
  - `hx_stop_polling()` answers 286.
- **Forms:** `form_status(form)` is 422 for a submitted form with errors, and 200 otherwise. Re-render the form's partial with that status: `{% htmx_script %}` tells htmx to swap 422 responses, so the errors appear in place, while tests and logs still see the failure.
- **Messages:** after an htmx request, messages still queued are appended to the HTML response as `<div id="messages" hx-swap-oob="true">`. Give your base template a `<div id="messages">` for them to replace. The markup is `juango/htmx_messages.html` (override it in your templates), and `HTMX_OOB_MESSAGES = false` turns it off. This, and the `Vary` header, are done by `HtmxMiddleware`, which is in the default `MIDDLEWARE`.
- **Tests:** `get(client, "/posts/"; htmx = true)` sends `HX-Request`. `htmx = (target = "results", boosted = true)` adds other headers. `assert_htmx(resp; redirect = "/done/", trigger = "post-saved")` checks the response headers.

#### Live views (experimental)

Live views are server-rendered pages that stay connected, in the manner of Phoenix LiveView. The page is
rendered as ordinary HTML, so it works without JavaScript and can be indexed. Then a small script
(`juango/live.js`) opens a WebSocket to the same URL. The server keeps a view for the page in a
task: each browser event updates its state, and the server renders the `{% liveview %}` part again
and sends what changed (a patch against the HTML the browser has, or the whole part when that's
smaller), which the browser morphs into the page (with the vendored Idiomorph, so focus and typing survive).

```julia
Base.@kwdef mutable struct Chat <: LiveView         # fields are the template's variables
    room::String = ""
    lines::Vector{String} = String[]
end
function Juango.mount(v::Chat, req, params)       # for the page, and when the socket (re)connects
    v.room = params["room"]                       # URL parameters and the query string
    subscribe("chat:" * v.room)
end
function Juango.handle_event(v::Chat, name, params)
    name == "say" && publish("chat:" * v.room, params["text"])   # to every open page in the room
    name == "leave" && return live_redirect("/")
end
Juango.handle_info(v::Chat, line) = push!(v.lines, line)

urlpatterns = [live("chat/<str:room>/", Chat, "chat.html"; name = "chat")]
```

```
{% extends "base.html" %}
{% block content %}{% liveview %}
  <ul>{% for line in lines %}<li>{{ line }}</li>{% endfor %}</ul>
  <form j-submit="say"><input name="text" autocomplete="off"><button>Send</button></form>
{% endliveview %}{% endblock %}
```

- **Bindings:**
  - `j-click="name"` sends the element's `j-value-*` attributes as parameters.
  - `j-submit="name"` on a form sends its fields. Its files are uploaded over the socket first, in chunks, and arrive as `UploadedFile`s (in memory, or temporary files past `FILE_UPLOAD_MAX_MEMORY_SIZE`).
  - `j-change="name"` fires on input in a field, or in any field of a form that has the attribute. It sends the form's fields and `_target`, debounced by `j-debounce` milliseconds (150 by default).
  - `j-keydown="name"` sends `key` and `value`; add `j-key="Enter"` to fire only for that key.
- **Pub-sub:** `subscribe(topic)` in `mount` delivers `publish(topic, msg)` to `handle_info` while the page is open. Within one process by default; with `LIVE_PUBSUB = :postgres`, to every process using the same PostgreSQL database, through `LISTEN`/`NOTIFY` (sent when the current transaction commits). The message must then be something the cache's JSON serializer stores (it arrives decoded, with its types), at most about 7 KB.
- **Forms:** `LiveForm(d -> ContactForm(d))` validates as the user types (`<form j-change="validate" j-submit="save">`, with `live_change!(v.form, params)` and `live_submit!(v.form, params)` in `handle_event`), showing errors only for the fields they've changed, and every field's once they submit. The template renders `form.form` as any form.
- **Keeping state across a reconnect:** with `Juango.live_snapshot(::Type{Chat}) = true`, the browser holds a signed copy of the view's fields (refreshed with each render) and sends it back when it reconnects, so the view gets its state back instead of starting afresh. The fields must be values the cache's JSON serializer stores; snapshots expire after `LIVE_SNAPSHOT_MAX_AGE` seconds.
- **Connections:** the WebSocket has the session and `req.user`, as usual, and the browser's `Origin` must be this site. Throwing `Http404` or `PermissionDenied` in `mount` refuses the socket. A dropped connection reconnects with backoff and mounts a fresh view (form fields keep what was typed), unless the view keeps snapshots. A failing handler closes the socket, so the page reconnects and remounts.
- **Tests:** `lt = live_test(Chat, "chat.html"; params = Dict("room" => "a"), user = u)`. Then `live_event!(lt, "say", Dict("text" => "hi"))`, `live_info!(lt, msg)` and `live_flush!(lt)` (for published messages) each return the live part's HTML. `lt.view` is the view and `lt.redirect` the last redirect. Juango's own tests drive `live.js` in headless Chromium (`test/browser.jl`, with `JUANGO_BROWSER_TESTS=1`).
- **Costs and limits:**
  - Each open page holds a task, a view and its request. Every change re-renders the live part on the server; only the changed span is sent.
  - A view whose state grows past `LIVE_MAX_STATE_BYTES` (1 MB) is closed, a session can have `LIVE_MAX_VIEWS_PER_SESSION` (20) open and the process `LIVE_MAX_VIEWS` (10,000), and messages and uploads are capped by `LIVE_MAX_MESSAGE_BYTES` and `LIVE_MAX_UPLOAD_BYTES`.
  - With several server processes, a load balancer must keep each socket on one process (any process can mount a view: its state is rebuilt, or restored from the snapshot, on reconnect).

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
    render(req, "contact.html", Dict("form" => form))   # {{ form }} / {{ form.as_div }} / {{ form.email }}
end

form = ModelForm(Post; data=req.POST, instance=post, fields=[:title, :body])
is_valid(form) && save!(form)
```

For cross-field validation, define `Juango.clean_form(f::Form, ::Val{:ContactForm})` and call `add_error!`.

**More form fields and rendering:**

```julia
@form OrderForm begin
    customer = ModelChoiceField(filter(Customer; active = true))          # cleaned value: the object
    sku      = ModelChoiceField(Product; to_field_name = :sku)            # submits a field other than the key
    extras   = ModelMultipleChoiceField(Extra; label_from_instance = e -> uppercase(e.name))
    qty      = TypedChoiceField(["1" => "One", "2" => "Two"]; coerce = x -> parse(Int, x))
    days     = MultipleChoiceField(["mon" => "Monday", "tue" => "Tuesday"])
    code     = RegexField(r"^[A-Z]{3}\d{2}$"; error_message = "Like ABC12.", template_name = "fields/code.html")
    contact  = ComboField([CharField(max_length = 40), EmailField()])
end

ModelForm(Post; field_classes = Dict(:slug => SlugField(max_length = 30)),          # a different form field
          formfield_callback = f -> f.name === :internal ? nothing : f)              # change or leave out each field
```

```
{{ form.code.as_field_group }}      {# label, help text, errors and widget (Django 5) #}
{{ form.as_div }}  {{ form.as_table }}  {{ form.as_p }}
```

- **Model choices.** `ModelChoiceField` and `ModelMultipleChoiceField` work in any form. Their querysets are read when the form is rendered and validated, so they're always current.
- **Field groups.** `as_field_group` uses the field's `template_name`, else `juango/forms/field.html`.
- **Other field types.** Decimal, time, duration, IP address and file path fields work in forms too.

#### Media, widgets, multi-value fields and renderers

```julia
@form EventForm begin
    title = CharField(widget = Widget(:text; attrs = Dict("class" => "wide"), media = Media(js = ["js/title.js"])))
    starts = SplitDateTimeField()                   # a date and a time input, one DateTime
    code = MultiValueField([CharField(max_length = 3), IntegerField()];
                           compress = vs -> "$(vs[1])-$(vs[2])", decompress = v -> split(v, '-'))
end
form = EventForm(; media = Media(css = Dict("all" => ["css/forms.css"])))
```

- `{{ form.media }}` renders the `<link>` and `<script>` tags of the form's `Media` and its widgets'. Relative paths go through `{% static %}`.
- A `MultiValueField` reads inputs `name_0`, `name_1`, ..., cleans each with its field, and `compress`es them. An `ArgumentError` thrown by `compress` becomes the field's error.
- `FORM_RENDERER = TemplateFormRenderer()` renders `{{ form }}` with `juango/forms/div.html` (or your `form_template`). `render_form(form; template)` renders one form with another template.

#### Styling fields in the template

Classes, placeholders and other attributes belong in the template, not the form class (django-widget-tweaks' idea, built in):

```
{% render_field form.title class="input" placeholder="Title" %}
{% render_field form.body class+="wide" rows="4" %}        {# += adds to the widget's own class #}
{{ form.email|add_class:"input"|attr:"autocomplete:email" }}
{{ form.email|add_error_class:"is-invalid" }}              {# only when the field has errors #}
```

They work on every widget: inputs, selects, textareas, checkboxes, radio lists and template widgets. The filters are `add_class`, `attr` (`"name:value"`, or `"name"` for an attribute without a value), `set_attr`, `append_attr`, `set_data` (`data-` attributes), `add_error_class`, `add_error_attr`, `add_required_class`, `field_type` and `widget_type`. A field's `name`, `id` and `type` stay its own.

#### Form templates and layouts

`{% form form %}` renders a whole form, and `{% field form.email placeholder="you@example.com" %}` one field (label, widget, help text, errors), through a template pack: `"plain"` (the default), `"bootstrap5"` or `"tailwind"`, set with `FORM_TEMPLATE_PACK` or per tag (`{% form form pack="bootstrap5" %}`). A pack is `juango/forms/packs/<name>/field.html` and `form.html`; override either, or add a pack of your own, in your templates directory. Classes from the template combine with the pack's. `form_html(form)` and `field_html(bf)` do the same from Julia.

For more than a column of fields, a layout (django-crispy-forms' idea):

```julia
using Juango.Layout
contact = FormLayout(Fieldset("Contact", :name, FormField(:email; placeholder = "you@example.com")),
                     Row(Column(:city), Column(:postcode; class = "col-3")), RawHTML("<hr>"), Submit("Send"))
```

`{% form form layout=contact %}` renders the fields the layout places (hidden fields always) in fieldsets, rows and columns, with the pack's classes. The pieces are `FormLayout`, `Fieldset`, `Row`, `Column`, `Div`, `RawHTML`, `Submit` and `FormField(:name; attributes...)` (`add_class = "x"` adds to the pack's class).

#### Dates and numbers as people type them

Date, datetime and time fields accept the active language's formats, as Django's locale formats:
`11/15/2026` and `Nov 15, 2026` in English, `15.11.2026` in German, `15/11/2026` in French. ISO 8601
is always accepted, and two-digit years fall in 1969-2068. `input_formats = ["%d|%m|%Y"]`
(strftime directives) adds formats to one field. `DATE_INPUT_FORMATS`, `DATETIME_INPUT_FORMATS` and
`TIME_INPUT_FORMATS` serve languages Juango has no formats for. Number fields with
`localize = true` accept `1.234,5` in German.

Widgets and fields:
- `DateField(widget = SelectDateWidget(years = 2020:2030))` shows three selects, in the order the language writes dates.
- `SplitDateTimeField(widget = SplitHiddenDateTimeWidget())` puts the date and time in hidden inputs.
- `NullBooleanField()` gives yes, no or unknown (`true`, `false`, `nothing`).

Forms also have:
- `errors_json_data(form)` and `errors_as_json(form)`, for API and htmx responses;
- `Form(...; field_order = [...])` and `order_fields!`;
- `use_required_attribute = false`. Formset forms never have the `required` attribute, as in Django.

`legend_tag(bf)` labels a radio or checkbox group.

#### Validators and error messages

Model and form fields take `validators = [...]`: Django's set (`RegexValidator`, `EmailValidator`,
`URLValidator`, `MinValueValidator`, `MaxValueValidator`, `MinLengthValidator`,
`MaxLengthValidator`, `StepValueValidator`, `DecimalValidator`, `ProhibitNullCharactersValidator`,
`validate_slug`, `validate_ipv46_address`, `int_list_validator`, ...) or any function returning
`nothing` when the value is fine and a message otherwise (or throwing `ValidationError(msg; code)`).
Form fields also take `min_value`, `max_value`, `step_size` and `min_length`, which add those
validators.

Every message has a code, and `error_messages` replaces it per field. On a model field it carries
into its ModelForms; `ModelForm(...; error_messages = Dict(:field => Dict(...)))` overrides it:

```julia
qty = IntegerField(min_value = 1, error_messages = Dict("min_value" => "At least %(limit_value)s.", "invalid" => "Digits only."))
code = CharField(max_length = 8, validators = [RegexValidator(r"^[A-Z]+$"; code = "caps")],
                 error_messages = Dict("required" => "A code, please.", "caps" => "Capitals only."))
```

The codes: `required`, `invalid`, `max_length`, `min_length`, `min_value`, `max_value`,
`step_size`, `invalid_choice`, `unique`, `max_digits`, `max_decimal_places`, `max_whole_digits`,
and for files `empty`, `invalid_image` and `contradiction`.

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
  {% for form in formset %}{{ form }}{% endfor %}
</form>
```

- **What's skipped.** Blank extra forms are ignored. Forms marked `DELETE` are skipped, and unchanged objects aren't re-saved.
- **Model formsets** carry a hidden `id` per form. Ids are matched against the queryset, so a tampered id can't reach other rows.
- **`formset.empty_form`** renders a form with `__prefix__` in place of the index, for adding rows with JavaScript.
- **`add_error!(formset, msg)`** adds a formset-wide error from a `clean` function.

#### Nested forms

A form with child formsets, to any depth, so a record and its children (or a JSON document of lists in lists) edit as one form. Prefixes are built from the path (`plates-0-blocks-2-label`); every level can delete and order its rows; `has_changed(tree)` says whether anything below changed; and `cleaned_data(tree)` gives back a document of the same shape, in its order, keeping keys no form edits. Rails' nested attributes are the model; Django leaves you to nest formsets by hand.

```julia
spec = (; plates = nested_formset(PlateForm; extra = 1, can_delete = true, can_order = true,
                                  children = (; blocks = nested_formset(BlockForm; extra = 1, can_delete = true))))
tree = nested_form(SheetForm; data = req.method == "POST" ? req.POST : nothing, initial = format.specification, children = spec)
if is_valid(tree)                          # every level, every error
    format.specification = cleaned_data(tree)
    save!(format)
end
```

```
{{ tree.form }}{{ tree.plates.management_form }}
{% for plate in tree.plates %}
  {{ plate.form }}{{ plate.blocks.management_form }}
  {% for block in plate.blocks %}{{ block.form }}{% endfor %}
{% endfor %}
```

`{{ tree }}` renders all of it, and `empty_form(tree.plates)` gives a row with `__prefix__` for adding rows in the page, and `nested_row(spec.plates, "plates", n)` renders row `n` for an htmx view that adds one (the page then raises `plates-TOTAL_FORMS`). A row's form is made with `F(data; prefix, initial)`, so it can be worked out from the row's initial values. Over models, `nested_model_form(Order; fields = [...], nested = [:items => (fields = [:product, :qty], extra = 1, can_delete = true)])` edits an object and its children (an inline formset per relation, one level), and `save!(tree)` saves everything in one transaction.

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
- **Storage.** Files go through a storage, `FileSystemStorage` by default. The `STORAGES` setting names storages, as in Django:
  ```julia
  configure!(STORAGES = Dict(
      "default"     => Dict(:BACKEND => FileSystemStorage, :OPTIONS => Dict(:location => "/srv/media")),
      "staticfiles" => Dict(:BACKEND => :manifest),          # or :static
      "scratch"     => Dict(:BACKEND => InMemoryStorage)))   # keeps files in memory, handy in tests
  storages("scratch")                                    # the instance
  FileField(storage = "scratch")                         # a field can name one
  ```
  A backend is a `Storage` value, a type or function called with the `OPTIONS`, or `:filesystem`/`:memory`. A storage implements `save_file`, `read`, `exists`, `size`, `delete_file` and `url`, and optionally `path` and `listdir`, so other backends (a cloud bucket, say) plug in the same way. `DEFAULT_FILE_STORAGE` still works when `STORAGES` has no `"default"`.
- **Safe file names.** Names are sanitised, can't escape `MEDIA_ROOT`, and never overwrite: an existing name gets a random suffix.
- **Images.** `ImageField` accepts PNG, GIF, JPEG and WebP. Juango reads the size itself, so no image library is needed.
- **Private uploads.** `path("media/<path:name>", protected_media(allow = (req, name) -> owns(req.user, name)))` serves files only to users `allow` lets through (by default, anyone logged in), confined to MEDIA_ROOT, with `Content-Security-Policy: sandbox` and `nosniff`, and anything but a plain image sent as a download, so an upload can never run as one of the site's pages. `sendfile = :x_accel_redirect` (nginx) or `:x_sendfile` lets the web server send the bytes.
- **Several files in one field.** `MultipleFileField(max_files = 10)` (a form field; `images = true` checks each is an image) renders `<input type="file" multiple>` and cleans to a `Vector{UploadedFile}`, each checked like a `FileField`'s upload. When required, choosing nothing is an error. Save each one yourself, say as a row of a related model.
- **Forms and admin.** Forms show the current file with a "Clear" checkbox when the field is optional, and the admin handles uploads.
- **Testing.** The test client uploads when the data contains an `UploadedFile`: `post(c, url, Dict("file" => UploadedFile("a.txt", "hi")))`.
- **Serving.** With `DEBUG`, the development server serves `MEDIA_URL`. In production, serve `MEDIA_ROOT` from your web server.
- **Deleting objects keeps their files**, as in Django. Use `delete_file` to remove them.


**Big uploads and upload handlers.** Uploads up to `FILE_UPLOAD_MAX_MEMORY_SIZE` (2.5 MB) stay in memory. Bigger ones are written to a temporary file in `FILE_UPLOAD_TEMP_DIR`: `temporary_file_path(f)` returns it, `FileSystemStorage` moves it into place rather than reading it, and it's removed when the request is done. `FILE_UPLOAD_HANDLERS` (default `[MemoryFileUploadHandler(), TemporaryFileUploadHandler()]`) decides what becomes of each file. A handler is any value with a method `Juango.upload_file(handler, field, filename, content_type, data)` that returns an `UploadedFile`, returns `nothing` to pass, or throws `BadRequest` to refuse the upload with a 400. `FILE_UPLOAD_PERMISSIONS` (default `0o644`) and `FILE_UPLOAD_DIRECTORY_PERMISSIONS` set the modes of what `FileSystemStorage` writes.
### Auth, sessions, CSRF, messages

- `User` model with PBKDF2-SHA256 password hashes in Django's format, so existing Django hashes verify.
- `authenticate`, `login!`, `logout!`, `create_user`, `create_superuser`, `login_required`, `staff_member_required`. `login_required`, `user_passes_test`, `permission_required`, `LoginView` and `LoginRequiredMixin` take `redirect_field_name` (`"next"`; `nothing` for none). `AllowAllUsersModelBackend()` lets inactive users log in (still without permissions), and `AdminPasswordChangeForm` sets someone else's password.
- Sessions (`req.session["k"] = v`) are stored where `SESSION_ENGINE` says: `:db` (default), `:cache`, `:cached_db`, `:file` (in `SESSION_FILE_PATH`) or `:signed_cookies` (the signed data itself in the cookie, so nothing on the server, but a session can't be revoked early). The session key rotates on login, and changing a password invalidates existing sessions. Sessions and `req.user` load lazily, as in Django: the store is read when a view first uses the session, and the user is looked up when `req.user` is first read (templates that don't use `user` or `perms` don't load it), so requests that don't need them cost no queries. `clearsessions` removes expired database rows and files.
- CSRF protection on every method except GET, HEAD, OPTIONS and TRACE: `{% csrf_token %}` or an `X-CSRFToken` header. Mark exceptions with `csrf_exempt(view)`. The token (and its cookie) is only created when a page uses it.
  - Settings as Django's: `CSRF_HEADER_NAME`, `CSRF_COOKIE_NAME`/`_AGE`/`_DOMAIN`/`_PATH`/`_SECURE`/`_HTTPONLY`/`_SAMESITE`, `CSRF_USE_SESSIONS` (the secret in the session, no cookie) and `CSRF_FAILURE_VIEW` (a view `(req; reason)` for the 403).
  - Pages get a masked form of the token, different on every render, so response compression can't leak it (BREACH). The cookie's plain value is accepted too, for JavaScript that reads it.
  - As in Django, a browser's `Origin` must match the request's scheme and host, or be in `CSRF_TRUSTED_ORIGINS`, where `https://*.example.com` trusts every subdomain. Over HTTPS without an `Origin`, the `Referer` must be this host, a trusted origin's, or one under `CSRF_COOKIE_DOMAIN`.
  - Over HTTPS without an `Origin`, the `Referer` must be an https URL of this site.
- `url_has_allowed_host_and_scheme(url, hosts)` says whether a redirect target (a `next` parameter, say) stays on the site. The login and logout views and `set_language` use it, and it refuses what browsers would read as another site (`//evil`, `/\evil`, `https:evil`).
- Forms: `AuthenticationForm`, `UserCreationForm` (username, two passwords checked against `AUTH_PASSWORD_VALIDATORS`; `save!` hashes the password), `UserChangeForm` (every field but the password; `Juango.password_summary(user)` describes the stored hash safely), `PasswordChangeForm`, `SetPasswordForm`. The admin's "add user" page uses `UserCreationForm`, then opens the user's change page.
- One-time messages: `message!(req, :success, "Saved")`, rendered with `{% for m in messages %}<p class="{{ m.tags }}">{{ m }}</p>{% endfor %}`.
  - Levels are numbers as in Django (debug 10, info 20, success 25, warning 30, error 40). Custom levels are other numbers, named by `MESSAGE_TAGS`, which can also rename the built-in ones (`Dict(40 => "danger")`). `MESSAGE_LEVEL` drops lower ones.
  - `extra_tags = "..."` joins `m.tags`. A `format_html`/`mark_safe` message renders as HTML. `peek_messages(req)` reads them without using them up. `using Juango.Messages` gives `success!(req, msg)` and the other shortcuts, plus `set_level!`.
  - `MESSAGE_STORAGE`: `:session` (the default), `:cookie` (a signed cookie, no session needed) or `:fallback` (the cookie while they fit, then the session). The cookie storages need `MessageMiddleware`, and `manage.jl check` says so.

#### Passwords

- **Hashers.** `PASSWORD_HASHERS` lists the accepted hashers; the first hashes new passwords. The default is Django's list: `PBKDF2Hasher()` (1,200,000 iterations, `PASSWORD_ITERATIONS`, as Django 6.0; under a second per login), `PBKDF2SHA1Hasher()`, `Argon2Hasher()`, `BCryptSHA256Hasher()` and `ScryptPasswordHasher()`, all pure Julia and in Django's formats, so hashes move between the two frameworks (`BCryptHasher()` is there too). A password stored with another hasher, fewer iterations or a weak salt is re-hashed when the user next logs in.
- **Validators.** `AUTH_PASSWORD_VALIDATORS` (default: `MinimumLengthValidator()` and `NumericPasswordValidator()`) also offers `CommonPasswordValidator()` (Django's list of 20,000 common passwords, or `path = "file"`, plain or `.gz`) and `UserAttributeSimilarityValidator()`. `validate_password(pw; user)` returns the messages; the password reset, password change and `createsuperuser` use them. A validator of your own is any value with a method `Juango.password_error(v, password, user)` returning a message or `nothing`.
- **Changing passwords.** `auth_urls()` includes `password_change/` and `password_change/done/` (`PasswordChangeView`, `PasswordChangeDoneView`). The user stays logged in; their other sessions end. Call `update_session_auth_hash!(req, user)` after changing a password in your own views.

#### Custom user model

Extend `AbstractUser` and name it in `AUTH_USER_MODEL`, best before the first `migrate` (a new project should start with one, even an empty one, so it can grow fields later):

```julia
@model struct Member <: AbstractUser
    phone = CharField(max_length = 20, blank = true)
    Meta(app_label = "accounts")
end
Juango.username_field(::Type{Member}) = :email      # log in with the email (default :username)
configure!(AUTH_USER_MODEL = "accounts.Member")     # or Member

@model struct Order
    customer = ForeignKey(USER_MODEL, on_delete = :CASCADE)   # follows AUTH_USER_MODEL
end
```

`get_user_model()` returns it, and `create_user`, `authenticate`, sessions, permissions, password reset, the admin and `createsuperuser` all use it. Migrations record `ForeignKey(USER_MODEL)` references as swappable, so an app's migrations work whichever user model a project picks. Only the chosen user model has a table: Juango's `User` drops out of content types, permissions and reverse relations when it's swapped. The auth app's migration then skips `auth_user` and its join tables, as Django does.

**Switching later**, with users in the database, is supported (Django leaves you to hand-write it):

1. Write the new model and run `makemigrations` and `migrate` with the old one still in `AUTH_USER_MODEL`, so its tables exist, empty.
2. `manage.jl swap_user_model accounts.Member` (`--dry-run` prints the plan) copies the users with their ids, their groups and permissions, moves every foreign key that points at the old user table (the admin's log and your models) to the new one, and moves the id sequence on, in one transaction where the database allows.
3. Set `AUTH_USER_MODEL = "accounts.Member"`. Sessions stay valid, since the ids are the same. The old table is left alone; drop it with a migration when you're sure.

If `AUTH_USER_MODEL` is switched without moving the users, the `auth.W020` check says so.

#### Authentication backends

`AUTHENTICATION_BACKENDS` (default `[ModelBackend()]`) decides who can log in and what they may do. A backend is any value whose type has methods of some of these functions. Each returns `nothing` when it has no opinion:

```julia
struct TokenBackend end
Juango.backend_authenticate(::TokenBackend, req; token = nothing, kw...) =
    token === nothing ? nothing : first(filter(objects(get_user_model()); api_token = token))
Juango.backend_get_user(::TokenBackend, id) = first(filter(objects(get_user_model()); id = id))
Juango.backend_has_perm(::TokenBackend, user, perm, obj) =          # object-level permissions
    obj isa Post && obj.author_id == user.id ? true : nothing
configure!(AUTHENTICATION_BACKENDS = [ModelBackend(), TokenBackend()])

authenticate(req; token = "...")                 # each backend in turn; the first user wins
has_perm(user, "blog.change_post"; obj = post)   # true if any backend says so
```

The session remembers which backend logged a user in. If that backend is removed from the settings, the user is logged out. A backend can throw `PermissionDenied` to stop the search. `ModelBackend` checks the password and gives users their own and their groups' permissions, with no per-object rules. Active superusers have every permission.

- **Object permissions in views.** Generic views check them with `UpdateView(Post; object_permission_required = "blog.change_post", login_required = true)`, which asks `has_perm(user, perm; obj = the_object)` once the object is loaded and answers 403 if the user lacks the permission.
- **Logins by a front-end server.** `RemoteUserMiddleware` (after `AuthenticationMiddleware`) with `RemoteUserBackend()` logs in the user whose name the proxy puts in the `REMOTE_USER_HEADER` header (default `Remote-User`). It creates the user on first sight unless `RemoteUserBackend(create_unknown_user = false)`, and logs them out when the header goes away. `PersistentRemoteUserMiddleware` keeps the session instead. The proxy must strip that header from clients' requests.
- **Login required everywhere.** `LoginRequiredMiddleware` (Django 5.1) sends anonymous users to `LOGIN_URL` from every view except those wrapped in `login_not_required(view)`. The login, password reset and admin views are exempt already.

### Email

```julia
send_mail("Welcome", "Hi Ann!", nothing, ["ann@example.com"]; html_message = "<p>Hi Ann!</p>")   # nothing = DEFAULT_FROM_EMAIL
msg = EmailMessage("Report", "See attached."; to = ["boss@example.com"], cc = [...], bcc = [...], reply_to = [...])
attach!(msg, "report.csv", csv_text, "text/csv")         # or attach_file(msg, "/path/report.pdf")
attach_alternative!(msg, html, "text/html")
send!(msg)
mail_admins("Disk almost full", details)          # to settings.ADMINS = [("Name", "email"), ...]
```

- **Backends.** `EMAIL_BACKEND` is `:smtp` (the default), `:console`, `:file` (`EMAIL_FILE_PATH`), `:locmem` (messages collect in `Juango.outbox`) or `:dummy`. You can also give it any function that takes a vector of messages.
- **Many messages.** `send_mass_mail([(subject, body, from, [to...]), ...])` sends them over one connection (SMTP logs in once). `get_connection(:console)` picks a backend for some messages: `send!(msg; connection = conn)`, `send_messages(conn, msgs)`.
- **SMTP** uses `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`/`EMAIL_HOST_PASSWORD` (AUTH PLAIN), and `EMAIL_USE_TLS` (STARTTLS) or `EMAIL_USE_SSL`, with the server's certificate verified against the system roots. `EMAIL_TIMEOUT` (seconds) limits the whole conversation.
- **Tests.** The test `Client` switches `:smtp` to `:locmem`, so tests never send real mail and can inspect `outbox`.
- **Errors.** With `DEBUG = false`, unhandled errors are mailed to `ADMINS`.
- **Password reset.** `auth_urls()` now includes password reset: `password_reset/` emails a link that works once, expires after `PASSWORD_RESET_TIMEOUT` (3 days), and leads to a page for choosing a new password. The templates are in `registration/password_reset_*`, and you can override them in your own template directory.
- **Signing.** `signing_dumps(value)` / `signing_loads(s; max_age)` make tamper-proof, URL-safe tokens keyed by `SECRET_KEY`, and `sign_value`/`unsign_value` do the same for plain strings. To rotate the key, put the old one in `SECRET_KEY_FALLBACKS` (as Django): what it signed (signed cookies, password reset links, logged-in sessions) keeps working, and new signatures use the new key.

### Permissions and groups

`migrate` creates `add_`, `change_`, `delete_` and `view_` permissions for every model (`Meta(default_permissions = ("add", "view"))` changes that list), plus any declared with `Meta(permissions = [("publish_post", "Can publish posts")])`. Users get permissions directly or through groups:

```julia
editors = create(Group; name = "editors")
add!(editors.permissions, get(Permission; codename = "change_post"))
add!(user.groups, editors)
add!(user.user_permissions, get(Permission; codename = "publish_post"))

has_perm(user, "project.change_post")            # "<app label>.<codename>"; Juango.perm_name(Post, :change) builds it
has_perms(user, ["project.add_post", "project.change_post"])
Juango.has_module_perms(user, "project")
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
- **Object-level permissions** (`has_perm(user, perm; obj)`) come from authentication backends; see Authentication backends.

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
{% get_current_language as LANGUAGE_CODE %}  {% language "de" %}...{% endlanguage %}  {% load l10n %}{{ price|localize }}
{% get_language_info for "de" as lang %}{{ lang.name_local }}      {# Deutsch; also name, name_translated, bidi #}
{% get_language_info_list for LANGUAGES as langs %}  {{ code|language_name_local }}
```

`get_language_info("pt-br")` gives the same in Julia.

- **Catalogues** are standard gettext files at `locale/<lang>/LC_MESSAGES/juango.po`, editable in Poedit, Weblate and similar tools.
  - `manage.jl makemessages -l de` collects strings from `.jl` files and templates and keeps existing translations.
  - `manage.jl compilemessages` builds the `.mo` files.
  - Juango reads `.po` files directly too, so compiling is optional.
- **Language selection.** `LocaleMiddleware` picks the language from the URL prefix, then the `juango_language` cookie, then `Accept-Language`, then `LANGUAGE_CODE`. It also sets `Content-Language`. Under `i18n_patterns`, a URL without a prefix redirects to the right language, and `reverse_url` adds the active prefix (`prefix_default_language = false` leaves the default language unprefixed).
- **Formats.** Dates use translated month and day names, and the `date` filter's default format follows the language. `localize` and `number_format` use the language's decimal separator, and thousands separators too with `USE_THOUSAND_SEPARATOR`.
- **Built-in German.** The admin's interface and validation messages are translatable, and Juango ships a German translation (`src/assets/locale/de`). Other languages fall back to English until someone adds a catalogue.

**In JavaScript.** Serve the active language's translations to the browser:

```julia
path("jsi18n/", Juango.JavaScriptCatalog(); name = "jsi18n")      # Juango.JSONCatalog() for the same as JSON
```

```html
<script src="{% url 'jsi18n' %}"></script>
<script>alert(interpolate(ngettext("%s item", "%s items", n), [n]))</script>
```

The script defines `gettext`, `ngettext`, `pgettext`, `npgettext`, `interpolate`, `pluralidx` and `get_format`, also under `juango.`. `JavaScriptCatalog(; prefixes = ["Cart"])` sends only msgids with those prefixes.

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
{% timezone "Asia/Tokyo" %}...{% endtimezone %}  {% load tz %}{{ t|utc }}  {{ t|timezone:"America/New_York" }}  {% localtime off %}
```

- **Storage.** With `USE_TZ`, datetimes are stored in UTC: `TIMESTAMP WITH TIME ZONE` on PostgreSQL, and UTC on SQLite and MySQL. The ORM returns aware `ZonedDateTime`s (TimeZones.jl).
- **Naive values.** Naive `DateTime`s you pass in are taken as wall-clock times in the current time zone.
- **Display.** Templates and forms show and read times in the current time zone: the one activated for the request (`TimezoneMiddleware` uses the session's `"juango_timezone"`), else `TIME_ZONE`. The `date` filter adds `e` (zone name), `T` (abbreviation) and `O` (offset).
- **Existing data.** To turn `USE_TZ` on for an existing database, run `manage.jl convert_naive_datetimes --from Europe/Berlin` once. It rewrites stored values as UTC and, on PostgreSQL, converts the columns. Back up first.
- **Lookups.** Date lookups such as `created__year` compare in UTC.

### Logging

Juango logs to named loggers, configured by `LOGGING` in the shape of Django's `dictConfig`:

```julia
configure!(LOGGING = Dict(
    "handlers" => Dict(
        "console" => Dict("class" => "console", "level" => "INFO", "format" => "{levelname} {name}: {message}"),
        "file" => Dict("class" => "file", "filename" => "site.log", "level" => "WARNING"),
        "mail_admins" => Dict("class" => "mail_admins", "level" => "ERROR", "filters" => ["require_debug_false"])),
    "loggers" => Dict(
        "juango.request" => Dict("handlers" => ["mail_admins", "file"], "level" => "WARNING"),
        "juango.db.backends" => Dict("handlers" => ["console"], "level" => "DEBUG", "propagate" => false)),
    "root" => Dict("handlers" => ["console"], "level" => "WARNING")))

Juango.log!("shop.payments", :info, "charged"; amount = 10)     # your own loggers
```

- **Loggers.** `juango.request` gets 5xx errors (with the exception) and 4xx warnings. `juango.db.backends` gets each SQL statement with its duration, at DEBUG level. `juango.security.*` gets CSRF failures and disallowed hosts. Records pass up the dotted names to the root, unless a logger has `"propagate" => false`.
- **Handlers.** `julia` (Julia's logging), `console`, `file`, `mail_admins` and `memory` (keeps `handler.records`; useful in tests). You can also put a handler value of your own as the `"class"`, with a method `Juango.emit(handler, record, format)`.
- **Default.** Without `LOGGING`, errors go to Julia's logger, and a 500 is mailed to `ADMINS` when `DEBUG` is false.

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
  - `m2m_changed` (`action`, `instance`, `model`, `pk_set`, `reverse`; the sender is the join model, `through(Post, :tags)`)
  - `post_write`, which Django lacks: after every write, bulk ones included (`save!`, `update!`, `bulk_create`, `bulk_update`, deletes and cascades, many-to-many changes), with `action` (`:insert`, `:update`, `:delete`, `:m2m`), `via`, the rows' `ids`, the `fields` written and the `instances` when the write had them. It's the one hook an audit log or undo needs.
  - `request_started` and `request_finished`
  - `user_logged_in`, `user_logged_out` and `user_login_failed` (without the password)
  - `pre_migrate` and `post_migrate`, once per app around `migrate` (the sender is the app label; `app_label`, `database`, `plan`, and `apps` for historical models). Juango's content types, permissions and default site are created by `post_migrate` receivers for "contenttypes", "auth" and "sites", which run before other apps'.
- **Filtering.** `sender` limits a receiver to one model (or other sender). `dispatch_uid` identifies a receiver for `disconnect!`.
- **What doesn't send.** Bulk `update!` doesn't send `pre_save`/`post_save`, as in Django (it sends `post_write`).
- **When to use them.** To change a model's own behaviour, overriding `save!` (as the blog example does) is usually clearer. Signals are for code that lives elsewhere, such as caches, search indexes and notifications.

### Caching

```julia
cache_set("greeting", "hi"; timeout = 60)          # seconds; nothing = for ever, 0 = don't store
cache_get("greeting", "default")
get_or_set("stats", () -> expensive(); timeout = 300)
Juango.incr("hits"); cache_add(k, v); cache_delete(k); cache_get_many(keys); Juango.incr_version("menu")
const home = cache_page(home_view; timeout = 60)   # whole GET responses, keyed by URL
```

```
{% cache 600 "sidebar" user.id %} ...expensive fragment... {% endcache %}
```

`cache_delete(make_template_fragment_key("sidebar", [user.id]))` drops one such fragment when its data changes.

- **Backends.** `CACHES` names one or more caches: `Dict("default" => Dict(:backend => :locmem, :max_entries => 1000, :timeout => 300))`. The backends are:
  - `:locmem` (per process, LRU)
  - `:db` (run `manage.jl createcachetable`)
  - `:redis` (`:location => "redis://host:6379/0"`, using a small built-in client)
  - `:memcached` (`:location => "127.0.0.1:11211"`, also built in)
  - `:file` (`:location => "/var/tmp/cache"`, one file per key, culled at `:max_entries`)
  - `:dummy`

  Use another cache with `cache_name = "shared"`. `:locmem` stores copies of the values.
- **What `:db`, `:redis`, `:memcached` and `:file` store.** They store JSON with type tags, so a value comes back equal and with the same type, and reading an entry never runs code. That covers `nothing`, booleans, numbers (including `BigInt`, `Rational`, `NaN`), strings, symbols, chars, dates and times (with time zones), UUIDs, `SafeString`, byte vectors, vectors, dicts, tuples, named tuples, pairs, sets, model instances and `HttpResponse`s (so `cache_page` works). Vectors, dicts and sets keep simple element types (`Vector{Int}`, `Dict{String,Date}`); nested containers come back with `Any`. Storing anything else raises `Juango.CacheSerializationError`.

  `:serializer => :serialization` in a cache's settings uses Julia's `Serialization` instead, which stores any value. Like Django's pickle, it lets anyone who can write to the cache store (the Redis server, the cache table) make the reader construct arbitrary objects, which can lead to running code. It also can't be read by another Julia version. An entry that can't be read counts as a miss and is deleted.
- **Page caching.** `cache_page` and the per-site `CacheMiddleware` (`CACHE_MIDDLEWARE_SECONDS`) skip responses that set cookies or vary on `Cookie`, so per-user pages aren't shared.
- **Templates.** Templates are read once and cached when `DEBUG` is off. With `DEBUG` on, they're read again when their files change, as Django's cached loader does. `TEMPLATE_CACHE_CHECK_MTIME = true` or `false` overrides that. With `DEBUG` off, each template is also compiled into a Julia function: text, `{% if %}`, `{% for %}` and `{{ variables|filters }}` become plain Julia code, which renders about twice as fast as interpreting the parsed nodes. Other tags (custom ones included) are called as they are. Compiling takes tens to hundreds of milliseconds per template, so it happens in a background task after a template's first render, and the template is interpreted until its function is ready; no request waits for it. `TEMPLATE_COMPILE = true` or `false` overrides the default, and `TEMPLATE_COMPILE = :eager` compiles on the first render instead.
- **Sessions.** `SESSION_ENGINE = :cache` keeps sessions in the cache only, and `:cached_db` puts the cache in front of the database. The default is `:db`.

### Background tasks

```julia
@background function send_welcome(user_id; greeting = "Hi")      # @background queue_name = "mail" priority = 5 function ...
    u = get(User; id = user_id)
    send_mail("Welcome", "$greeting $(u.username)", "site@example.com", [u.email])
end

r = enqueue(send_welcome, user.id; greeting = "Hello")          # a TaskResult: r.status, r.return_value, r.error
```

`TASKS` picks the backend: `:immediate` (the default) runs the task at once. `:dummy` only records it (`dummy_results()`, for tests). `:database` (add `"juango.tasks"` to `INSTALLED_APPS`) stores it for `manage.jl db_worker` to run, with `run_after`, priorities and queues; arguments must be JSON-friendly, and `get_result(id)` / `refresh!(result)` read the outcome. Several workers can run at once on PostgreSQL and MySQL. Calling the function directly still just runs it.

### Sitemaps

```julia
sitemaps = Dict(
    "posts" => Sitemap(() -> filter(Post; published = true); lastmod = :updated, changefreq = "weekly", priority = 0.6),
    "pages" => Sitemap(["blog:list", "about"]; location = name -> reverse_url(name)),
)
urlpatterns = [..., sitemap_urls(sitemaps)...]
```

`/sitemap.xml` is a sitemap index that points at `/sitemap-posts.xml` and `/sitemap-pages.xml`. With a single section, it is that section's urlset. `items` is a collection, a QuerySet or a function returning one. `location`, `lastmod`, `changefreq` and `priority` are each a value, a function of the item, or a field name. Without a `location`, models use `get_absolute_url` and strings are taken as URLs. URLs become absolute with the request's host (set `protocol = "https"` to force a scheme). Sections larger than `limit` (50,000) are split into pages (`?p=2`), and the index lists each page.

### Syndication feeds

A `Feed` is a view that produces RSS 2.0 or Atom 1.0:

```julia
latest = Feed(title = "My blog", link = "/blog/", description = "The latest posts",
              items = () -> filter(Post; published = true)[1:10],
              item_description = :body, item_pubdate = :created, item_author_name = p -> p.author.username)
by_author = Feed(get_object = (req; id) -> get_object_or_404(objects(User); id),
                 title = u -> "Posts by $(u.username)", link = u -> "/authors/$(u.id)/",
                 items = u -> filter(Post; author = u, published = true))
urlpatterns = [path("feed/", latest), path("feed/atom/", Feed(latest; feed_type = :atom)),
               path("authors/<int:id>/feed/", by_author), ...]
```

Feed-level options (`title`, `link`, `description`, `items`, `language`, `author_name`, `ttl`, `feed_url`) are values or functions of the object that `get_object` returns. Item options are values, functions of the item, or field names:

- `item_title` (default: the item as a string)
- `item_description`
- `item_link` (default: `get_absolute_url`)
- `item_pubdate` and `item_updateddate`
- `item_author_name`
- `item_guid` (default: the link)
- `item_categories`

`title_template` and `description_template` render each item with `obj` and `site` in the context. Links are made absolute with the request's host.

### Flat pages

Simple pages such as "About" or "Terms" can live in the database and be edited in the admin:

```julia
configure!(INSTALLED_APPS = [..., "juango.flatpages"],               # registers FlatPage in the admin
           MIDDLEWARE = vcat(settings.MIDDLEWARE, [Juango.FlatpageFallbackMiddleware]))
# and/or serve them under a prefix:
urlpatterns = [..., path("pages/", Juango.flatpage_urls())]                 # /pages/about/ shows the page with url "/about/"
```

The fallback middleware turns any 404 into the flat page at that URL, if there is one. It also adds a missing trailing slash, as APPEND_SLASH does. A page renders its `template_name` (default `flatpages/default.html`) with `flatpage` in the context. The page's title and content are HTML from the admin and are inserted unescaped. Pages with `registration_required` send anonymous visitors to the login page. For menus, `{% load flatpages %}{% get_flatpages '/about/' for user as pages %}` lists pages, optionally under a URL prefix. Pages that need a login are included only for a logged-in `user`.

### Sites and redirects

Add `"juango.sites"` to `INSTALLED_APPS` for a `Site` per domain: `get_current_site(req)` returns the one with `SITE_ID` (default 1; `migrate` creates `example.com`), or with `SITE_ID = nothing` the one matching the request's host. Without the app it returns a `RequestSite` for the host. Sitemaps, feeds and password-reset emails use the site's domain.

`"juango.redirects"` (it needs sites) keeps old URLs in the database and in the admin. Add `RedirectFallbackMiddleware` last in `MIDDLEWARE`: a 404 for a redirected path becomes a 301 to its new path, or 410 Gone when the new path is empty.

### Middleware

A middleware has Django's shape: a factory `get_response -> (req -> response)`.

```julia
function Timing(get_response)
    req -> (t = time(); r = get_response(req); setheader!(r, "X-Time", string(time() - t)); r)
end
configure!(MIDDLEWARE = [Juango.default_settings()[:MIDDLEWARE]..., Timing])
```

The defaults are security headers, sessions, `APPEND_SLASH`, CSRF, authentication and htmx (`Vary: HX-Request` and out-of-band messages). Also available:

- `GZipMiddleware` compresses responses of 200 bytes or more for clients that accept gzip, with random padding in the gzip header against BREACH (as Django does). Put it first. Streaming responses are compressed chunk by chunk, each chunk flushed so it still goes out at once.
- `BrokenLinkEmailsMiddleware` emails `MANAGERS` (via `mail_managers`) when a page linked from somewhere returns 404, unless `DEBUG` is on. Links from your own site are reported as broken internal links. Like Django it ignores requests without a referer, search engines, and paths matching `IGNORABLE_404_URLS` regexes.
- `ConditionalGetMiddleware` gives GET responses an `ETag` and answers `If-None-Match`/`If-Modified-Since` with 304 Not Modified.

#### Security settings

`SecurityMiddleware` (in the defaults) handles HTTPS and security headers:

```julia
configure!(SECURE_SSL_REDIRECT = true,                         # http:// -> https:// (SECURE_SSL_HOST, SECURE_REDIRECT_EXEMPT)
           SECURE_HSTS_SECONDS = 31536000, SECURE_HSTS_INCLUDE_SUBDOMAINS = true, SECURE_HSTS_PRELOAD = false,
           SECURE_PROXY_SSL_HEADER = ("X-Forwarded-Proto", "https"))   # behind a proxy that sets this header
```

It also sends `X-Content-Type-Options: nosniff`, `X-Frame-Options` (`X_FRAME_OPTIONS`, default `DENY`), `Referrer-Policy` (`SECURE_REFERRER_POLICY`) and `Cross-Origin-Opener-Policy` (`SECURE_CROSS_ORIGIN_OPENER_POLICY`). `is_secure(req)` is true for requests served over TLS, or when `SECURE_PROXY_SSL_HEADER` names a header the proxy sets. Set that only if the proxy always sets or strips the header. Likewise `USE_X_FORWARDED_HOST = true` makes `get_host(req)` (and ALLOWED_HOSTS) use the proxy's `X-Forwarded-Host`, and `USE_X_FORWARDED_PORT = true` makes `get_port(req)` use `X-Forwarded-Port`.

For a Content-Security-Policy, add `ContentSecurityPolicyMiddleware`:

```julia
configure!(SECURE_CSP = Dict("default-src" => [CSP.SELF], "script-src" => [CSP.SELF, CSP.NONCE],
                             "upgrade-insecure-requests" => true),
           SECURE_CSP_REPORT_ONLY = Dict("img-src" => [CSP.SELF, "data:"]))
```

```html
<script nonce="{{ csp_nonce }}">...</script>
```

`CSP.NONCE` becomes the request's nonce, if a template used `csp_nonce`. `csp_override(view, policy)` changes the policy for one view (`nothing` sends none). `manage.jl check --deploy` lists settings that are unsafe in production.

#### HTTP caching decorators

```julia
never_cache(view)                                   # Cache-Control: max-age=0, no-cache, no-store, must-revalidate, private
cache_control(view; max_age = 3600, public = true)  # any directives; Juango.patch_cache_control!(resp; ...) for a response
vary_on_headers(view, "Accept-Language")            # vary_on_cookie(view)
etag(view, (req; id) -> string(get(Post; id).updated))
last_modified(view, (req; id) -> get(Post; id).updated)
condition(view; etag_func, last_modified_func)      # both
```

`etag`, `last_modified` and `condition` answer conditional requests without running the view: 304 for an unchanged GET or HEAD, 412 when an `If-Match` or `If-Unmodified-Since` precondition fails.

### Admin

```julia
Admin.register!(Post; list_display=[:title, :author, :published, "Words" => p -> length(split(p.body))],
                search_fields=[:title, :body], list_filter=[:published, :author])
```

The admin gives you login, a model index, change lists (search, filters, pagination), add/change forms with validation, and delete confirmation that shows cascade effects. Users and groups are registered automatically, with password hashing in the user form.

URLs are Django's: each model is under its app (`/admin/blog/post/`, `/admin/blog/post/3/change/`, `/admin/auth/user/`), so models with the same name in different apps don't collide. The index groups models by app, and `/admin/blog/` lists one app's. Pages reverse with Django's names, `{% url 'admin:blog_post_change' post.pk %}`, `admin:blog_post_changelist`, `_add`, `_delete`, `_history` and `admin:app_list` (`app = "blog"`), or with the generic `admin:changelist` / `admin:change` given `app`, `model` and `id`. More options:

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

**Filters, permissions per object, and request-dependent options:**

```julia
decade = Admin.ListFilter("decade born", "decade";                     # Django's SimpleListFilter
    lookups = (req, admin) -> ["80s" => "in the eighties", "90s" => "in the nineties"],
    queryset = (req, qs, v) -> filter(qs; born__year__range = v == "80s" ? (1980, 1989) : (1990, 1999)))

Admin.register!(Person;
    list_filter = [decade, :is_active, :email => :empty, :team => :related_only],
    has_change_permission = (req, obj) -> obj === nothing || obj.owner_id == req.user.id,   # also view, add, delete
    queryset = req -> filter(objects(Person); company = req.user.company),
    get_list_display = req -> req.user.is_superuser ? [:name, :salary] : [:name],          # get_list_filter, get_search_fields,
    get_readonly_fields = (req, obj) -> obj === nothing ? [] : [:email],                   # get_ordering, get_fields too
    list_select_related = [:team], show_full_result_count = false,
    urls = [path("<str:id>/promote/", promote; name = "person_promote")])                 # admin/hr/person/3/promote/
```

The filters are Django's, with its URL parameters, so its links and bookmarks work: a boolean
(`is_active__exact=1`, "Unknown" when nullable), choices (`status__exact=p`), a date (Today, Past 7
days, This month, This year: `born__gte` / `born__lt`), a foreign key, many-to-many or reverse
relation (`team__id__exact=3`, `team__isnull=True`, in the related admin's ordering; `:team =>
:related_only` lists only those in use), a field through a relation (`:team__city`), or any other
field (its values in use). Other parameters are lookups, as in Django: `?name__startswith=A` on the
model's own fields, or through a relation a list filter names; others get a 400, and a value that
doesn't fit (`?born__gte=soon`) sends back to the unfiltered list (`?e=1`).

The search splits the term into words (a quoted phrase is one) and each must match one of
`search_fields`: a field is searched with `icontains`, `"^name"` with `istartswith`, `"=name"` with
`iexact`, `"@name"` with full-text `search`, and `"age__exact"` or `"team__name__startswith"` with
that lookup (an exact lookup on a number skips words that aren't numbers). Searching or filtering
across a many-to-many or reverse relation lists each row once.

- **Big tables.** A foreign key to a table with more than `ADMIN_FK_SELECT_LIMIT` rows (1000) becomes a search box when the related model is in the admin with `search_fields`, else an id box, instead of a select of every row (`raw_id_fields` and `autocomplete_fields` choose explicitly; `ADMIN_FK_SELECT_LIMIT = nothing` turns this off).
- **Filters.** `:field => :empty` filters on empty values and `:fk => :related_only` lists only the related objects in use.
- **Permissions per object.** `has_*_permission(req, obj)` is asked for the model (with `obj = nothing`) and for each object, so a change page can be view-only for some objects. Custom views in `urls` run behind the admin's login and permission checks.
- **Hooks**, as Django's ModelAdmin methods:
  - `save_model = (req, obj, form, change) -> ...`: stamp `obj.created_by = req.user`, then `save!(obj)`.
  - `save_related`, `delete_model`, `delete_queryset`: the rest of saving, and deleting.
  - `response_add`/`response_change`/`response_delete`: where to go afterwards.
  - `get_form`: build the change form yourself.
  - `formfield_for_foreignkey`/`_manytomany`/`_choice_field = (req, field) -> field`: narrow a select per request, for example `ModelChoiceField(filter(Team; org = req.user.org))`.
  - `formfield_overrides = Dict(:text => Dict(:widget => ...))` and `radio_fields = [:status]`.
- **Change list:**
  - Clicking a column header sorts by it (`?o=2.-1`). Columns of model fields sort, and `Admin.display(f; description, boolean, ordering, empty_value)` columns sort when given an `ordering`.
  - `list_display_links`, `sortable_by`, `empty_value_display` and `search_help_text`.
  - `save_on_top = true` repeats the save buttons above the form.

**More than one admin site:**

```julia
staff = Admin.AdminSite("staff"; site_header = "Staff area", has_permission = req -> req.user.is_staff,
                        urls = [path("stats/", stats; name = "stats")])
Admin.register!(Order; site = staff)
urlpatterns = [path("admin/", Admin.urls()), path("staff/", Admin.urls(staff))]
```

Each site has its own registry, titles, permission check and URL namespace (`"staff:index"`). Its pages use the same templates. While a site handles a request, `admin:` URL names resolve to that site, so `{% url 'admin:changelist' ... %}` in a template points at the right one (Django's `current_app`).

### Admin documentation

Add `"juango.admindocs"` to `INSTALLED_APPS` and `path("admin/doc/", admindocs_urls())` before the admin's URLs. Staff then get pages listing the models (fields, relations, docstrings), the URL patterns with their views' docstrings, and the template tags and filters. Docstrings are rendered as Markdown (Django renders reStructuredText).

### Testing

```julia
using Juango.Testing

c = Client()
r = get(c, "/posts/hello/")
@test r.status == 200 && r.context["post"].title == "Hello" && r.templates == ["post.html"]
force_login!(c, user)
r = post(c, "/posts/new/", Dict("title" => "X", ...); follow=true)
```

The client keeps cookies, skips CSRF unless you pass `Client(enforce_csrf=true)`, and never opens a socket.

**A throwaway test database.** `julia --project manage.jl test [--keepdb] [--failfast] [--reverse] [--shuffle[=SEED]] [-k PATTERN] [file ...]` runs each test file, carrying on after a failing one unless `--failfast` (`-k` picks files by name; `--shuffle` prints its seed so an order that fails can be repeated). It runs the tests against a database of their own, so they never touch the development one: SQLite in memory, or `test_<name>` on the same PostgreSQL or MySQL server (created, migrated, and dropped afterwards; `--keepdb` reuses it). `TEST_DATABASE` names another. A suite run with `julia test/runtests.jl` or `Pkg.test()` does the same with:

```julia
db = Juango.Testing.setup_test_database()          # (keepdb = true to reuse it)
try
    include("test_models.jl")
finally
    Juango.Testing.teardown_test_database(db)
end
```

For data that a group of tests shares and none may keep (Django's `setUpTestData`), create it inside an outer `rollback_after` and give each test its own inner `rollback_after`: they nest as savepoints.

For browser automation or any real HTTP client, `with_live_server` runs the app on a free port for the block (Django's `LiveServerTestCase`). It serves static files even with `DEBUG` off, and allows its host for the block. The server answers in other tasks, so on Postgres and MySQL it only sees committed data: create test data outside `rollback_after`.

```julia
with_live_server() do s
    r = HTTP.get(s.url * "/posts/")              # also live_server_url()
end
```

To catch N+1 queries, `count_queries` runs a function and counts the SQL statements it executed:

```julia
r, n = count_queries(() -> get(c, "/posts/"))
@test n <= 3
```

**Helpers** for tests:

```julia
rollback_after() do                                  # undo every change at the end (like Django's TestCase)
    create(Post; title = "draft")
    override_settings(DEBUG = false) do              # settings changed just for this block
        r = get(Client(), "/posts/")
        @test assert_contains(r, "draft")            # also: count=, status=, html=true; assert_not_contains
        @test assert_template_used(r, "posts/list.html")
    end
end
@test assert_redirects(get(Client(), "/secret/"), "/accounts/login/?next=%2Fsecret%2F")
@test assert_num_queries(() -> collect(select_related(objects(Post), :author)), 1)
@test assert_form_error(form, :title, "This field is required.")
@test assert_html_equal(html, "<p class='a b'>Hi</p>")   # whitespace, attribute and class order ignored
@test assert_in_html("<li>one</li>", r; count = 2)      # also assert_contains(r, ...; html = true)
@test assert_json_equal(r, Dict("ok" => true))           # a response or a JSON string, key order ignored
@test assert_queryset_equal(order_by(qs, "title"), ["a", "b"]; transform = p -> p.title)   # ordered = false too
@test assert_formset_error(formset, 1, :qty, "Enter a whole number.")   # form 1; nothing: the non-form errors
@test assert_field_output(IntegerField(), Dict("3" => 3), Dict("x" => ["Enter a whole number."]))

req = get(RequestFactory(), "/posts/"; data = Dict("page" => 2))   # call a view directly, no middleware
req.user = user
resp = post_list(req)
```

The `assert_*` functions return `true` or throw an `AssertionError` that says what went wrong, so `@test assert_...` reports it. `load_fixtures(names...)` loads fixture files.

### Static files

`collectstatic` copies `STATIC_DIRS` and each app's `static/` into `STATIC_ROOT`. Where static files are looked for is `STATICFILES_FINDERS` (default `[FileSystemFinder(), AppDirectoriesFinder()]`); a finder of your own subtypes `Juango.StaticFinder` and defines `find_static(finder, path)` and `list_static(finder)`. `{% get_static_prefix %}` and `{% get_media_prefix %}` give `STATIC_URL` and `MEDIA_URL`. With `STATICFILES_STORAGE = :manifest` it also writes copies with a content hash in the name (`css/site.55e7cbb9ba48.css`) and a `staticfiles.json` manifest. It rewrites `url(...)` and `@import` references inside CSS to the hashed names. Then, with `DEBUG` off, `{% static "css/site.css" %}` gives the hashed URL, so a web server can tell browsers to cache static files forever. A name missing from the manifest raises an error.

**Serving them without nginx** (WhiteNoise built in): with `SERVE_STATIC = true` and `DEBUG` off, Juango serves `STATIC_URL` from `STATIC_ROOT` itself. Hashed names are sent with `Cache-Control: public, max-age=31536000, immutable`, others with `max-age=60` (`STATIC_MAX_AGE`) and an ETag, answered with 304 when unchanged. `collectstatic` writes `.gz` copies of text files (CSS, JavaScript, SVG, JSON...; `STATIC_COMPRESS = false` turns that off), sent to clients that accept gzip, with `Vary: Accept-Encoding`. Byte ranges work, files up to 1 MB are kept in memory (`STATIC_MAX_MEMORY_FILE`), and paths can't leave `STATIC_ROOT`. For uploads, see `protected_media`.

### Model introspection

Generic code that works on any model, such as an audit log, an undo, a CSV export or a "copy
this row" helper, can ask a model about its fields. This is Django's `Model._meta` and field
methods:

```julia
for f in concrete_fields(Material)           # columns, multi-table parents' first; no m2m, no automatic id
    f.name, attname(f), column(f), f.kind    # :plate, :plate_id, "plate_id", :fk
    is_relation(f) && related_model(f)       # Plate
    v = value_from_object(f, obj)            # the stored value: a foreign key's id, a Decimal, a datetime...
    x = value_to_json(f, v)                  # what dumpdata writes: "19.90", "2026-11-14T18:21:17.605Z"
    @assert value_from_json(f, x) == v       # and back, ready for update! or setproperty!
end
many_to_many(Material)                       # m2m fields; through(Material, :tags) is the join model
model_label(Material), get_model("lab.Material")
```

The automatic primary key is `obj.pk`, not a field. A `CompositePrimaryKey`'s fields are
concrete fields, with `is_primary_key(Material, f)` true.

### Undo

An app can record what one action writes and put it back later (`django-reversion`'s idea, organised around one action at a time):

```julia
data = recording() do rec
    plate.status = "done"; save!(plate)
    delete!(filter(Well; plate = plate, empty = true))
    recorded(rec)                  # JSON-ready: store it with the action, in a JSONField
end
undo_problem(data)                 # nothing, or why it can't be undone now (it's tried and rolled back)
undo_recorded!(data)               # puts it all back in one transaction, or throws UndoProblem
```

Every write inside `recording` is noted, whatever made it: `save!`, `update!`, `bulk_create`, `bulk_update`, `delete!` with its cascades and the links it empties, and many-to-many changes. An undo refuses, saying why, when a row it changed has been changed again since, when deleting what it made would take something made or changed since with it, or when a deleted row's place (a unique value) has been taken. Deleted rows come back with their own keys and `auto_now` stamps. `recording(; exclude = [AuditEntry])` leaves models out, and Juango's own bookkeeping (sessions, the admin log, content types, permissions) is never recorded. A receiver of `undoing_recorded` can redo what an app works out from the rows, since an undo's `update!` and `bulk_create` send no `post_save`. Rows made by `bulk_create` on MySQL have no ids to note, so an undo can't delete them.

### Fixtures and serialization

```julia
s = Juango.serialize(:json, objects(Post); indent = 2)    # Django's format: [{"model": "blog.post", "pk": 1, "fields": {...}}]
for d in Juango.deserialize(:json, s)                     # also :jsonl (one object per line), :yaml and :xml
    save!(d)                                       # writes the row as it is, then its many-to-many values
end
Juango.dumpdata("blog"; output = "blog.json")      # manage.jl dumpdata blog --indent 2 --output blog.json (or .yaml, .xml)
Juango.loaddata("blog.json")                       # manage.jl loaddata initial_data  (searches FIXTURE_DIRS
Juango.load_fixtures("initial_data")               #  and each app's fixtures/ folder); in tests
```

Fixture files from Django's `dumpdata` (JSON, JSONL, YAML or XML) load as they are; `loaddata` picks the format from the extension (`.json`, `.jsonl`, `.yaml`/`.yml`, `.xml`). YAML and XML need no extra packages: the YAML reader handles what fixtures use (block and flow collections, quoted, plain and block scalars, comments), but not anchors, aliases or tags. Foreign keys and many-to-many values are ids, or natural keys with `natural_foreign = true` (`--natural-foreign`) for models that define them:

```julia
Juango.natural_key(t::Tag) = (t.name,)
Juango.get_by_natural_key(::Type{Tag}, name) = get(Tag; name = name)
```

`loaddata` runs in one transaction. Objects with a primary key replace the row with that key.

### Management commands

`runserver [host:]port`, `makemigrations`, `migrate`, `showmigrations`, `sqlmigrate`, `createsuperuser`, `changepassword`, `showurls`, `sqlschema`, `check`, `clearsessions`, `dumpdata`, `loaddata`, `flush`, `dbshell`, `inspectdb`, `squashmigrations`, `optimizemigration`, `diffsettings`, `sendtestemail`, `findstatic`, `remove_stale_contenttypes`, `test`, `help`. Add your own with `Juango.register_command!("name", "help", args -> ...)`.

- `inspectdb [table ...]` writes `@model` definitions for existing tables, with `Meta(managed = false)` so migrations leave those tables alone. Check the field types it guesses.
- `deploy [--plan] [--fake]` runs deploy tasks: one-off jobs (data fixes, imports) that must run once on each database, declared with `deploy_task!("0001_fill_species"; app = "lab") do ... end` and recorded like migrations so they never run twice. A task returning `deploy_waiting("species.csv isn't uploaded yet")` is reported and tried again next time; one that throws rolls back and isn't recorded. Don't rename a task once it has run.
- `flush` empties every table Juango manages (asks first, unless `--noinput`).
- `dbshell` opens `sqlite3`, `psql` or `mysql` on the configured database.
- `test` runs `test/runtests.jl`, or else each `tests/test*.jl`, against a throwaway database and a throwaway `MEDIA_ROOT` (removed afterwards, so uploads made by tests don't pile up). `--coverage` runs them with Julia's coverage on and prints the lines covered per file of the project (the full report goes to `coverage/lcov.info`). `--update-snapshots` approves new output for `assert_matches_snapshot(name, output)`, which compares a report, page or export with its approved copy in `test/snapshots/` byte for byte, the safety net for a big refactor.
- `diffsettings [--all]` lists the settings that differ from the defaults. `sendtestemail you@example.com [--managers] [--admins]` checks the mail setup. `findstatic css/site.css` shows where a static file comes from. `remove_stale_contenttypes [--include-stale-apps]` deletes the content types of models that no longer exist, along with their permissions.

**System checks.** `check` runs every registered check. `--deploy` adds the deployment checks, and `--tag security,models` picks tags. `runserver` reports problems when it starts. Add your own checks:

```julia
Juango.register_check!(tags = [:billing]) do
    isempty(objects(Plan)) ? [Juango.CheckMessage(:warning, "No plans yet."; id = "billing.W001", hint = "Add one in the admin.")] : []
end
configure!(SILENCED_SYSTEM_CHECKS = ["billing.W001", "security.W004"])
```

`check --tag templates` parses every template of the project and its apps and reports syntax errors, unknown tags and filters with the closest known name (`invalid filter: 'uppr'; did you mean 'upper'?`), `{% url %}` names no pattern has, and `{% extends %}` / `{% include %}` of templates that don't exist (`templates.E101`–`E103`), so these turn up before a user finds them.

Juango's own checks use Django's ids where Django has the same check (`security.W004` for HSTS, `security.W009` for `SECRET_KEY`, and so on). Some go further than Django's: unknown and mistyped settings (`settings.W001`, `settings.E001`–`E004`), and text fields with `null = true` that aren't unique (`fields.W800`), which then have two kinds of blank, NULL and `""`.

## Deployment

**Precompiling Juango.** After installing or updating Juango, Julia precompiles it once: about 2.5 minutes on a 4-core desktop. Most of that runs a workload of requests, queries, templates, forms and admin pages, so the code they need is compiled ahead of time and a fresh process (a server, a test run, `manage.jl migrate`) doesn't compile it again; without the workload, precompiling takes about 30 s but each new process spends over a minute compiling on its first requests. Two settings help:
- `JULIA_IMAGE_THREADS` (in your shell's environment) sets how many threads write the compiled package. Julia uses half the cores by default; all of them cut the time from about 148 s to 118 s on a 4-core machine: `export JULIA_IMAGE_THREADS=$(nproc)`.
- To precompile without the workload (quicker updates, slower first requests; worth it only if you update Juango far more often than you start processes), add to the project's `LocalPreferences.toml`:

  ```toml
  [Juango]
  precompile_workload = false
  ```

**Starting fast.** A freshly started Julia compiles code the first time it runs it, so a new server answers its first requests slowly; the example blog takes 11 seconds from `runserver` to its first response. `manage.jl build` makes a system image of the project's packages (with PackageCompiler.jl, which it installs into a shared `@juango-build` environment the first time) while running a workload taken from the project. The workload requests every URL without parameters through the test client, against an in-memory copy of the schema, and parses every template:

```sh
julia --project manage.jl build                       # build/juango.so (.dylib on macOS, .dll on Windows)
julia --project manage.jl build --workload tests      # also run test/runtests.jl while compiling
julia --project manage.jl build --dry-run             # write the workload and print the command
julia --project -J build/juango.so manage.jl runserver 0.0.0.0:8000
```

With the image, the example blog answers its first request **3.1-3.6 s** after `runserver` starts, against **11.0 s** without it (Julia 1.13, a 4-core desktop; a second page then takes 70-90 ms either way). What's left of the 3 s is loading the 470 MB image and the project's own code, which is loaded, not compiled into the image.

Building takes 9-11 minutes and needs about **11 GB of free memory**. PackageCompiler compiles the image in one process that loads every package from source, and the example blog peaked at 10.9 GB with the heap-size hint `build` passes (12.1 GB without). On a smaller server, build on a 16 GB machine or a CI runner with the same OS, CPU family and Julia version, and copy `build/juango.so` across. Rebuild after changing the project's dependencies. Juango's own code is in the image too, so rebuild after upgrading Juango.

**A standalone app.** `manage.jl build --app` goes one step further: `build/app` holds an executable named after the project, Julia's runtime and libraries, the compiled image, and a copy of the project's files, so it runs on a machine without Julia (of the same OS and CPU family). It's made with PackageCompiler's `create_app`, from a small wrapper package `build` writes into `build/app_src`, whose `julia_main` loads the project and runs its command line:

```sh
julia --project manage.jl build --app                 # build/app/bin/blog, build/app/lib, build/app/project
julia --project manage.jl build --app --cpu-target native   # for this machine's CPU only: less memory to build
build/app/bin/blog migrate
build/app/bin/blog runserver 0.0.0.0:8000             # any manage.jl command
JUANGO_PROJECT_DIR=/srv/blog build/app/bin/blog runserver   # run a project kept elsewhere
```

The project's code is still loaded when the app starts (as with `-J`), so a change to it needs no rebuild. A change to its dependencies or to Juango does.

The app answers its first request **3.2 s** after it starts, like the image. By default it's compiled for several x86-64 CPU types so it runs on other machines, which costs more memory to build than this 16 GB desktop could spare. `--cpu-target native` compiles it for the build machine's CPU only: the example blog's app then took 26 minutes and peaked at 11.2 GB, and is 920 MB on disk. Build the portable default on a bigger machine or a CI runner, or use `native` when the app will run on the same kind of CPU it was built on.

**Running in production.** Set `DEBUG = false`, a long random `SECRET_KEY` and `ALLOWED_HOSTS`, run `manage.jl check --deploy`, and put the server behind a reverse proxy that terminates TLS and serves static and media files:

```ini
# /etc/systemd/system/blog.service
[Service]
WorkingDirectory=/srv/blog
Environment=JUANGO_DEBUG=false JUANGO_SECRET_KEY=... JULIA_NUM_THREADS=auto,1
ExecStart=/usr/local/bin/julia --project -J build/juango.so manage.jl runserver 127.0.0.1:8000
Restart=always
User=www-data
```

**Threads, memory and garbage collection.** One Juango process serves the whole machine, unlike Django's worker processes:
- **Threads:** `--threads=auto,1` (or `JULIA_NUM_THREADS=auto,1`): worker threads for the views, plus the interactive thread the server answers connections on. More threads than cores doesn't help.
- **Memory:** a process starts at about 450 MB (bare Julia is 230 MB, and Juango's compiled code most of the rest), and under load the heap grows by a few hundred MB above the data actually live (20-60 MB for the benchmark app), because Julia collects lazily. The benchmark app peaked at 0.5-0.65 GB under 32 connections.
- **`--heap-size-hint`** makes the collector work harder as the heap nears the hint. Only use it to keep a process inside a memory limit, and leave plenty of room: a hint close to what's live makes every collection a full one (in the benchmark, `--heap-size-hint=150M` cut throughput by three-quarters). 1-2 GB is a sensible ceiling for a typical app.
- **Tail latency:** collections stop every thread for a few milliseconds, so a busy server's p99 is several times its median (see `benchmarks/README.md`). The fewer objects a view allocates (`values_list` instead of whole objects, `only`, paginating big lists), the fewer collections. `--gcthreads` didn't help in the benchmark.

```nginx
location /static/ { alias /srv/blog/staticfiles/; }     # manage.jl collectstatic
location /media/  { alias /srv/blog/media/; }
location / {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;        # with SECURE_PROXY_SSL_HEADER
    proxy_http_version 1.1;                            # WebSockets:
    proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade";
}
```

```dockerfile
FROM julia:1.12
WORKDIR /app
COPY . .
RUN julia --project -e 'using Pkg; Pkg.instantiate()' && julia --project manage.jl build
EXPOSE 8000
CMD ["julia", "--project", "-J", "build/juango.so", "manage.jl", "runserver", "0.0.0.0:8000"]
```

**Logging requests.** `runserver` prints a line to stderr for each request. `ACCESS_LOG = false` turns that off, for example behind a proxy that logs requests itself.

**Performance.** `benchmarks/` has the same small app in Juango and Django, plus a script that measures both: throughput, latency, start-up time and memory. On a 4-core desktop, Juango served 3-12x as many requests per second as Django under gunicorn, depending on the page. It takes about 7 s to start without a system image (Django: under a second), its first request to each page takes 70-200 ms, and its one process uses 0.5-0.65 GB against 165-300 MB for Django's four workers. See `benchmarks/README.md` for the numbers.

## Settings

Set them with `configure!(...)` and read them with `settings.NAME`. Request limits:
- `DATA_UPLOAD_MAX_MEMORY_SIZE`: 2.5 MB, for bodies that aren't file uploads.
- `DATA_UPLOAD_MAX_NUMBER_FIELDS`: 1000 GET and POST parameters.
- `DATA_UPLOAD_MAX_NUMBER_FILES`: 100 files in one request.
- `FILE_UPLOAD_MAX_SIZE`: 100 MB, for multipart uploads, which Juango holds in memory.

A request over a limit gets 400 Bad Request; `nothing` turns a limit off. `runserver` drops clients that take more than `SERVER_READ_HEADER_TIMEOUT` seconds (10) to send their headers, and kept-alive connections idle for `SERVER_IDLE_TIMEOUT` seconds (120). `SERVER_READ_TIMEOUT` limits reading a whole request (off by default, so slow uploads, server-sent events and WebSockets work).

`ALLOWED_HOSTS` is checked with `DEBUG` on too: the default allows only `localhost`, `127.0.0.1` and `[::1]`. An empty list in `DEBUG` allows any `*.localhost` name as well. This keeps other sites from reaching a development server through DNS rebinding. Add your machine's name or address to reach it from elsewhere. The main ones: `DEBUG`, `SECRET_KEY`, `DATABASE` (a SQLite path, `":memory:"`, a `scheme://` URL, or a backend instance), `INSTALLED_APPS`, `APP_DIRS`, `ROOT_URLCONF`, `TEMPLATE_DIRS`, `STATIC_URL`, `STATIC_DIRS`, `STATIC_ROOT`, `ALLOWED_HOSTS`, `MIDDLEWARE`, `CONTEXT_PROCESSORS`, `LOGIN_URL`, `LOGIN_REDIRECT_URL`, `APPEND_SLASH`, `SESSION_COOKIE_AGE`, `PASSWORD_ITERATIONS`, `SQL_DEBUG`. Any extra keyword becomes a custom setting.

### Misspelled and mistyped settings

Django ignores `DEBG = False` without a word. Juango knows every setting it reads, so:
- **`configure!` warns** in DEBUG, once per name, when a name is a letter or two away from a known one: `Unknown setting ALLOWED_HOST: did you mean ALLOWED_HOSTS?`
- **`manage.jl check`** (and `runserver` when it starts) reports every unknown setting as `settings.W001`, with the closest known name.
- **The same check catches wrong types:**
  - a true/false setting given anything else (`DEBUG = "false"` from an environment variable): `settings.E001`;
  - a list setting given a string (`ALLOWED_HOSTS = "example.com"`, read as a list of characters): `settings.E002`;
  - a number setting given a string: `settings.E003`;
  - a `DATABASE` (or `DATABASES` entry) that isn't a path, a URL with a known scheme or a backend: `settings.E004`.

Declare your own settings so they aren't reported, optionally with defaults that `settings.NAME` returns until a project sets them:

```julia
declare_settings!(:BLOG_PAGE_SIZE => 20, :BLOG_API_KEY)      # a library or project
const BLOG = App("blog"; settings = Dict(:BLOG_PAGE_SIZE => 20))
configure!(EXTRA_SETTINGS = [:MY_FLAG, "ACME_*"])           # or list them (* for a prefix)
```


### Settings from the environment

What changes between deployments (secrets, the database, `DEBUG`) can come from environment
variables or a `.env` file kept out of version control, as with django-environ. The
`settings.jl` that `startproject` writes does this:

```julia
using Juango.Environ
read_env(joinpath(BASE_DIR, ".env"))                    # KEY=value lines; variables already set win

configure!(
    DEBUG = env("DEBUG", Bool; default = false),        # true/on/yes/1, false/off/no/0
    SECRET_KEY = env("SECRET_KEY"),                      # no default: a clear error if it's missing
    ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost"]),   # "a.com,b.com"
    DATABASE = env_db(; default = "sqlite:///db.sqlite3"),         # DATABASE_URL=postgresql://u:p@host/db
    CACHES = Dict("default" => env_cache(; default = "locmem://")), # CACHE_URL=redis://host:6379/0?timeout=60
    env_email(; default = "consolemail://")...,                    # EMAIL_URL=smtp+tls://user:pass@host
)
```

- **`env(name, T; default)`** reads `String`, `Bool`, numbers, `Vector{T}` (comma-separated), `Dict{K,V}` (`k=v,k2=v2`) and `Any` (JSON).
- **`.env` files** take comments, `export`, single quotes (taken as they are), double quotes (with escapes) and `${OTHER}` expansion.
- **`env_db`** accepts django-environ's scheme names (`psql`, `pgsql`, `postgis`, `mysql2`, `sqlite3`).
## Differences from Django (current limitations)

- **SQLite, PostgreSQL and MySQL/MariaDB.** Postgres and MySQL use a connection pool; SQLite uses one connection behind a lock.
- **Swappable user models** can be switched after the first `migrate` with `swap_user_model` (Django has no supported way).
- `runserver` is HTTP.jl's server. It speaks HTTP/1.1 and HTTP/2 (cleartext with prior knowledge, or negotiated over TLS), and serves HTTPS with `runserver 8443 --cert cert.pem --key key.pem` (or `runserver(...; certfile, keyfile)`). WebSockets need HTTP/1.1, which browsers use for them anyway. It is fine for development and small deployments. For production, put it behind a reverse proxy, set `DEBUG=false`, set a real `SECRET_KEY` and `ALLOWED_HOSTS`, and run `manage.jl check --deploy`.

## Layout

```
src/
  Juango.jl     the module: includes, in dependency order
  api.jl        the public API: exports, public names, Juango.Testing / GIS / Postgres
  core/         settings, utils, Decimal, apps, signals, signing, logging, cache, mail, files,
                async helpers, management commands
  http/         Request and responses, URLs, middleware, security, views, streaming,
                HTTP caching, the request handler and server
  template/     the template engine (engine, tags, filters), tag libraries, humanize
  i18n/         translations, time zones, the JavaScript catalog
  db/           connection.jl (the backend interface), backends/, orm/ (fields, models,
                lookups, SQL compiler, QuerySet, bulk operations, instances, many-to-many),
                expressions, schema, constraints, migrations/, fixtures, database tools
  forms/        forms, formsets, media and widgets
  contrib/      auth/, admin/, sessions, messages, contenttypes, flatpages, sites,
                sitemaps, feeds, tasks, staticfiles, gis
  testing/      the test client and testing helpers for your own apps
  assets/       built-in templates, translations, migrations and data
ext/            optional integrations loaded on demand (MySQL, Mustache)
test/           Juango's own test suite: setup.jl + one file per area
examples/blog/  a complete example app
```

Run the tests with `julia --project -e 'using Pkg; Pkg.test()'`. The files run in four groups, one process per group and two groups at a time (`JUANGO_TEST_JOBS` changes that); the whole suite takes about four minutes on SQLite, five on Postgres or MariaDB, and needs about 2 GB of memory. Run one part with `julia --project=test test/orm.jl`; the parts are `templates`, `orm`, `forms`, `views`, `admin`, `services`, `db` and `migrations`. `JUANGO_TEST_DATABASE` picks the database: unset for in-memory SQLite, or a `postgresql://` or `mysql://` URL.
