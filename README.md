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

`on_commit(f)` runs `f()` once the current transaction commits, and drops it if the transaction (or the savepoint it was registered in) rolls back. Outside a transaction `f()` runs at once. Use it to send mail or enqueue a task only when the data it needs is saved:

```julia
atomic() do
    save!(order)
    on_commit(() -> send_mail("Order received", ...))     # robust = true logs an error instead of raising
end
```

In tests inside `rollback_after`, `capture_on_commit_callbacks(f; execute = true)` returns (and runs) the callbacks `f` registered.

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

`bulk_create` and `bulk_update` don't call `save!` or send signals. Combined querysets can be ordered, sliced and counted but not filtered further.

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

- **The `Decimal` type.** `Decimal` is an exact decimal number, like Python's `decimal.Decimal`. Juango includes its own, because the Decimals package that LibPQ needs is too limited (no hashing, inexact division). `+`, `-` and `*` are exact, and `/` gives 28 significant digits. A Decimal keeps its scale: `dec"1.50"` prints as `1.50` and equals `dec"1.5"`. `round(d; digits)` rounds to exactly that many places and pads with zeros. Floats convert through their shortest form, so `Decimal(0.1) == dec"0.1"`.
- **Saving and loading.** Values are rounded to `decimal_places` when they are saved and loaded. `full_clean` and forms check `max_digits` and `decimal_places` with Django's messages. The form widget is a number input with `step="0.01"`.
- **Databases.** Postgres uses `NUMERIC(p, s)` and MySQL/MariaDB `DECIMAL(p, s)`, both exact. SQLite has no exact decimal type. Its `NUMERIC` column stores values as doubles (about 15 significant digits), which is enough for amounts of money. `Sum`, `Min`, `Max` and arithmetic on decimal fields return Decimals. Other computed numbers (`Avg` of an integer field, for example) are `Float64` as before.
- **Output.** Fixtures store decimals as strings (`"4.95"`), as Django does. Templates print them exactly, including `floatformat`, `localize` and `intcomma`. `JsonResponse` writes them as JSON numbers.

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
- **Self-referential relations.** `friends = ManyToManyField(:self)` is symmetrical: adding Bob to Ann's friends adds Ann to Bob's, and removing works both ways. Use `symmetrical = false` for one-way relations such as "follows".
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
- **Window functions:** `annotate(qs; rank = Window(RowNumber(); partition_by=[:author], order_by=["-views"]))`, also with `Rank`, `DenseRank`, `Lag`, `Lead` and aggregates over a window. You can order and filter by them: `filter(qs; rank = 1)` wraps the query, because SQL can't filter on a window function directly. Plain conditions in the same queryset apply before the window is computed, as in Django.
- **`FilteredRelation`:** join a relation with an extra condition in the JOIN's `ON` clause, so authors without a match are kept and aggregates see only matching rows. It works with forward and reverse relations, one level deep:
  - `qs = annotate(Author; pub = FilteredRelation(:posts; condition = Q(posts__published = true)))`
  - `annotate(qs; n = Count(:pub))`, `filter(qs; pub__title__contains = "Julia")`, `exclude(qs; pub__views = 0)`, `order_by(qs, "pub__views")`
- **`values()` is lazy.** It returns a queryset whose rows are `Dict`s. Aggregates in `annotate` after `values(:field)` group by that field. As in Django, combining aggregates over two different reverse relations multiplies rows, so use `distinct=true`.

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

`to_fields` defaults to the target's primary key, so a `ForeignObject` can point at any model. Deleting the target applies `on_delete` (`:CASCADE` by default, `:SET_NULL`, `:PROTECT`, `:DO_NOTHING`). There is no database constraint, and the relation isn't a form field: forms edit the fields it is made of.

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

Juango's own features are apps too: `juango.admin`, `juango.auth`, `juango.contenttypes`, `juango.sessions` and `juango.messages`, all installed by default, plus the optional `juango.flatpages`. Each owns its models and migrations, as in Django: `auth.User`, `auth.Group`, `auth.Permission`, `contenttypes.ContentType`, `sessions.SessionRecord`, `admin.LogEntry` and `flatpages.FlatPage`, with permission names such as `auth.change_user`. A project can leave any of them out. That app's tables are then not created, and its URLs (`Admin.urls()` and `auth_urls()` refuse to run) and commands (`createsuperuser`, `changepassword`, `clearsessions`) go too. `manage.jl check` reports apps whose requirements are missing (admin needs auth, contenttypes, sessions and messages; auth needs contenttypes). `installed_apps()`, `is_installed("blog")`, `get_app("blog")` and `app_models("blog")` query the registry.

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

- **Data migrations.** `makemigrations --empty --name backfill` writes a file to fill in with `RunSQL(forward, backward)` or `RunJulia(forward_fn, backward_fn)`. A `RunJulia` function that takes an argument gets the models as they were at that point in history, so it doesn't depend on today's model structs:

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
- **Transactions.** Each migration runs in a transaction. If it fails, nothing is applied.
- **SQLite.** SQLite can't alter or drop columns in place, so those changes rebuild the table: create a copy, move the rows, then swap. On Postgres they are ordinary `ALTER TABLE` statements.
- **Backfill.** Adding a NOT NULL column without a default fills existing rows with `""`, `0`, `false` or 1970-01-01, and `makemigrations` says so.
- **Conflicts.** Two branches that both added a migration conflict. `migrate` refuses to run, and `makemigrations --merge` writes a merge migration.
- **Checking in CI.** `makemigrations --check` exits with status 1 if models have changes without a migration.
- **What's tracked.** Only schema attributes are tracked: column type, `null`, database default, `unique`, `db_index` and the foreign key target. Changing `choices`, `help_text` or validators never creates a migration.

**Apps.** Juango's own apps (`auth`, `contenttypes`, `sessions`, `admin`, `flatpages`) ship their migrations with Juango, and they are applied only for installed apps. Models defined in an `App`'s module use that app's `migrations/` folder (see Apps). Your other models are the `project` app, stored in `settings.MIGRATIONS_DIR` (`startproject` sets it to `<project>/migrations`). A model can also opt into another app with `Meta(app_label = "billing")` plus `MIGRATION_MODULES = Dict("billing" => "path/to/dir")`.

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

To add a backend, subtype `Juango.DatabaseBackend`, implement the driver methods, override any dialect methods that differ from standard SQL, and call `register_backend!("scheme", url -> MyBackend(url))`. The interface is documented at the top of `src/db/connection.jl`. The implementations are in `src/db/backends/`, with the PostgreSQL and MySQL drivers in `ext/`.

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

Access control works on every generic view: `login_required = true`, `permission_required = "blog.change_post"` (403 when the user lacks it), and `test_func = user -> user.is_staff`. For other views, the wrappers `LoginRequiredMixin(view)`, `PermissionRequiredMixin(view, perms...)` and `UserPassesTestMixin(view, test)` do the same. `success_message` (the SuccessMessageMixin) takes `%(field)s` placeholders from the cleaned data.

Date-based archives take a `date_field`:

```julia
A(view; kw...) = view(Post; date_field = :published, kw...)
path("archive/", A(ArchiveIndexView)),                         # latest, date_list (years)
path("archive/<int:year>/", A(YearArchiveView)),               # year, date_list (months), next_year, previous_year
path("archive/<int:year>/<int:month>/", A(MonthArchiveView)),  # month, object_list, date_list (days), next_month...
path("archive/<int:year>/<int:month>/<int:day>/", A(DayArchiveView)),
path("archive/<int:year>/<int:month>/<int:day>/<slug:slug>/", A(DateDetailView)),
```

Future-dated objects are left out unless `allow_future = true`. An empty period is a 404 unless `allow_empty = true`. YearArchiveView lists its objects only with `make_object_list = true`. The default templates are `<model>_archive.html`, `_archive_year`, `_archive_month`, `_archive_day` and `_detail`. With USE_TZ, days are counted in the current time zone.

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

#### humanize

`{% load humanize %}` adds `intcomma` (`1,234,567`, with the active language's separator), `intword` (`1.2 million`), `apnumber` (`four`), `ordinal` (`22nd`), `naturalday` (`today`, `yesterday`, `tomorrow`, else the date) and `naturaltime` (`3 minutes ago`, `an hour from now`).

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
- **Forms and admin.** Forms show the current file with a "Clear" checkbox when the field is optional, and the admin handles uploads.
- **Testing.** The test client uploads when the data contains an `UploadedFile`: `post(c, url, Dict("file" => UploadedFile("a.txt", "hi")))`.
- **Serving.** With `DEBUG`, the development server serves `MEDIA_URL`. In production, serve `MEDIA_ROOT` from your web server.
- **Deleting objects keeps their files**, as in Django. Use `delete_file` to remove them.

### Auth, sessions, CSRF, messages

- `User` model with PBKDF2-SHA256 password hashes in Django's format, so existing Django hashes verify.
- `authenticate`, `login!`, `logout!`, `create_user`, `create_superuser`, `login_required`, `staff_member_required`.
- Sessions (`req.session["k"] = v`) are stored where `SESSION_ENGINE` says: `:db` (default), `:cache`, `:cached_db`, `:file` (in `SESSION_FILE_PATH`) or `:signed_cookies` (the signed data itself in the cookie, so nothing on the server, but a session can't be revoked early). The session key rotates on login, and changing a password invalidates existing sessions. Sessions and `req.user` load lazily, as in Django: the store is read when a view first uses the session, and the user is looked up when `req.user` is first read (templates that don't use `user` or `perms` don't load it), so requests that don't need them cost no queries. `clearsessions` removes expired database rows and files.
- CSRF protection on POST/PUT/PATCH/DELETE: `{% csrf_token %}` or an `X-CSRFToken` header. Mark exceptions with `csrf_exempt(view)`. The token (and its cookie) is only created when a page uses it.
- Forms: `AuthenticationForm`, `UserCreationForm` (username, two passwords checked against `AUTH_PASSWORD_VALIDATORS`; `save!` hashes the password), `UserChangeForm` (every field but the password; `Juango.password_summary(user)` describes the stored hash safely), `PasswordChangeForm`, `SetPasswordForm`. The admin's "add user" page uses `UserCreationForm`, then opens the user's change page.
- One-time messages: `message!(req, :success, "Saved")`, rendered with `{% for m in messages %}`.

#### Passwords

- **Hashers.** `PASSWORD_HASHERS` (default `[PBKDF2Hasher()]`) lists the accepted hashers; the first hashes new passwords. `Argon2Hasher()`, `BCryptSHA256Hasher()` and `BCryptHasher()` are built in (pure Julia) and use Django's formats, so hashes move between the two frameworks. A password stored with an older hasher, or with weaker settings, is re-hashed when the user next logs in.
- **Validators.** `AUTH_PASSWORD_VALIDATORS` (default: `MinimumLengthValidator()` and `NumericPasswordValidator()`) also offers `CommonPasswordValidator()` (Django's list of 20,000 common passwords, or `path = "file"`, plain or `.gz`) and `UserAttributeSimilarityValidator()`. `validate_password(pw; user)` returns the messages; the password reset, password change and `createsuperuser` use them. A validator of your own is any value with a method `Juango.password_error(v, password, user)` returning a message or `nothing`.
- **Changing passwords.** `auth_urls()` includes `password_change/` and `password_change/done/` (`PasswordChangeView`, `PasswordChangeDoneView`). The user stays logged in; their other sessions end. Call `update_session_auth_hash!(req, user)` after changing a password in your own views.

#### Custom user model

Extend `AbstractUser` and name it in `AUTH_USER_MODEL` before the first `migrate`:

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
- **SMTP** uses `EMAIL_HOST`, `EMAIL_PORT`, `EMAIL_HOST_USER`/`EMAIL_HOST_PASSWORD` (AUTH PLAIN), and `EMAIL_USE_TLS` (STARTTLS) or `EMAIL_USE_SSL`, with the server's certificate verified against the system roots. `EMAIL_TIMEOUT` (seconds) limits the whole conversation.
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
{% get_current_language as LANGUAGE_CODE %}  {% language "de" %}...{% endlanguage %}  {% load l10n %}{{ price|localize }}
```

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
  - `m2m_changed` (`action`, `instance`, `model`, `pk_set`, `reverse`; the sender is the join model)
  - `request_started` and `request_finished`
  - `user_logged_in`, `user_logged_out` and `user_login_failed` (without the password)
  - `pre_migrate` and `post_migrate`, once per app around `migrate` (the sender is the app label; `app_label`, `database`, `plan`, and `apps` for historical models). Juango's content types, permissions and default site are created by `post_migrate` receivers for "contenttypes", "auth" and "sites", which run before other apps'.
- **Filtering.** `sender` limits a receiver to one model (or other sender). `dispatch_uid` identifies a receiver for `disconnect!`.
- **What doesn't send.** Bulk `update!` doesn't send `pre_save`/`post_save`, as in Django.
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

- **Backends.** `CACHES` names one or more caches: `Dict("default" => Dict(:backend => :locmem, :max_entries => 1000, :timeout => 300))`. The backends are:
  - `:locmem` (per process, LRU)
  - `:db` (run `manage.jl createcachetable`)
  - `:redis` (`:location => "redis://host:6379/0"`, using a small built-in client)
  - `:dummy`

  Use another cache with `cache_name = "shared"`. `:locmem` stores copies of the values.
- **What `:db` and `:redis` store.** They store JSON with type tags, so a value comes back equal and with the same type, and reading an entry never runs code. That covers `nothing`, booleans, numbers (including `BigInt`, `Rational`, `NaN`), strings, symbols, chars, dates and times (with time zones), UUIDs, `SafeString`, byte vectors, vectors, dicts, tuples, named tuples, pairs, sets, model instances and `HttpResponse`s (so `cache_page` works). Vectors, dicts and sets keep simple element types (`Vector{Int}`, `Dict{String,Date}`); nested containers come back with `Any`. Storing anything else raises `Juango.CacheSerializationError`.

  `:serializer => :serialization` in a cache's settings uses Julia's `Serialization` instead, which stores any value. Like Django's pickle, it lets anyone who can write to the cache store (the Redis server, the cache table) make the reader construct arbitrary objects, which can lead to running code. It also can't be read by another Julia version. An entry that can't be read counts as a miss and is deleted.
- **Page caching.** `cache_page` and the per-site `CacheMiddleware` (`CACHE_MIDDLEWARE_SECONDS`) skip responses that set cookies or vary on `Cookie`, so per-user pages aren't shared.
- **Templates.** `TEMPLATE_CACHE_CHECK_MTIME = false` reads each template once instead of checking its file on every render. Use it in production.
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

The defaults are security headers, sessions, `APPEND_SLASH`, CSRF and authentication. Also available:

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

It also sends `X-Content-Type-Options: nosniff`, `X-Frame-Options` (`X_FRAME_OPTIONS`, default `DENY`), `Referrer-Policy` (`SECURE_REFERRER_POLICY`) and `Cross-Origin-Opener-Policy` (`SECURE_CROSS_ORIGIN_OPENER_POLICY`). `is_secure(req)` is true for requests served over TLS, or when `SECURE_PROXY_SSL_HEADER` names a header the proxy sets. Set that only if the proxy always sets or strips the header.

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

req = get(RequestFactory(), "/posts/"; data = Dict("page" => 2))   # call a view directly, no middleware
req.user = user
resp = post_list(req)
```

The `assert_*` functions return `true` or throw an `AssertionError` that says what went wrong, so `@test assert_...` reports it. `load_fixtures(names...)` loads fixture files.

### Static files

`collectstatic` copies `STATIC_DIRS` and each app's `static/` into `STATIC_ROOT`. With `STATICFILES_STORAGE = :manifest` it also writes copies with a content hash in the name (`css/site.55e7cbb9ba48.css`) and a `staticfiles.json` manifest. It rewrites `url(...)` and `@import` references inside CSS to the hashed names. Then, with `DEBUG` off, `{% static "css/site.css" %}` gives the hashed URL, so a web server can tell browsers to cache static files forever. A name missing from the manifest raises an error.

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

`runserver [host:]port`, `makemigrations`, `migrate`, `showmigrations`, `sqlmigrate`, `createsuperuser`, `changepassword`, `showurls`, `sqlschema`, `check`, `clearsessions`, `dumpdata`, `loaddata`, `flush`, `dbshell`, `inspectdb`, `squashmigrations`, `test`, `help`. Add your own with `Juango.register_command!("name", "help", args -> ...)`.

- `inspectdb [table ...]` writes `@model` definitions for existing tables, with `Meta(managed = false)` so migrations leave those tables alone. Check the field types it guesses.
- `flush` empties every table Juango manages (asks first, unless `--noinput`).
- `dbshell` opens `sqlite3`, `psql` or `mysql` on the configured database.
- `test` runs `test/runtests.jl`, or else each `tests/test*.jl`.

## Settings

Set them with `configure!(...)` and read them with `settings.NAME`. Request limits, as in Django: `DATA_UPLOAD_MAX_MEMORY_SIZE` (2.5 MB, for bodies that aren't file uploads), `DATA_UPLOAD_MAX_NUMBER_FIELDS` (1000 GET and POST parameters) and Juango's `FILE_UPLOAD_MAX_SIZE` (100 MB, for multipart uploads, which Juango holds in memory). A request over a limit gets 400 Bad Request; `nothing` turns a limit off. The main ones: `DEBUG`, `SECRET_KEY`, `DATABASE` (a SQLite path, `":memory:"`, a `scheme://` URL, or a backend instance), `INSTALLED_APPS`, `APP_DIRS`, `ROOT_URLCONF`, `TEMPLATE_DIRS`, `STATIC_URL`, `STATIC_DIRS`, `STATIC_ROOT`, `ALLOWED_HOSTS`, `MIDDLEWARE`, `CONTEXT_PROCESSORS`, `LOGIN_URL`, `LOGIN_REDIRECT_URL`, `APPEND_SLASH`, `SESSION_COOKIE_AGE`, `PASSWORD_ITERATIONS`, `SQL_DEBUG`. Any extra keyword becomes a custom setting.

## Differences from Django (current limitations)

- **SQLite, PostgreSQL and MySQL/MariaDB.** Postgres and MySQL use a connection pool; SQLite uses one connection behind a lock.
- **Swappable user models** have Django's limitation: choose `AUTH_USER_MODEL` before the first `migrate`.
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
ext/            database drivers loaded on demand (LibPQ, MySQL)
test/           Juango's own test suite: setup.jl + one file per area
examples/blog/  a complete example app
```

Run the tests with `julia --project -e 'using Pkg; Pkg.test()'`. The files run in four groups, one process per group and two groups at a time (`JUANGO_TEST_JOBS` changes that); the whole suite takes about four minutes on SQLite, five on Postgres or MariaDB, and needs about 2 GB of memory. Run one part with `julia --project=test test/orm.jl`; the parts are `templates`, `orm`, `forms`, `views`, `admin`, `services`, `db` and `migrations`. `JUANGO_TEST_DATABASE` picks the database: unset for in-memory SQLite, or a `postgresql://` or `mysql://` URL.
