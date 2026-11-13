# The benchmark app in Juango (the Django one is in ../django): see ../README.md.
const DB = get(ENV, "BENCH_DB", joinpath(@__DIR__, "..", "data", "juango.sqlite3"))
if startswith(DB, "postgres")
    using LibPQ                  # only for PostgreSQL: loading it costs some of Juango's precompiled code
end
using Juango
using Dates

@model struct Author
    name = CharField(max_length = 100)
    email = EmailField()
end

@model struct Post
    title = CharField(max_length = 200)
    body = TextField()
    author = ForeignKey(Author, on_delete = :CASCADE, related_name = :posts)
    created = DateTimeField()
end
Base.show(io::IO, a::Author) = print(io, a.name)
Base.show(io::IO, p::Post) = print(io, p.title)

@form ContactForm begin
    name = CharField(max_length = 100)
    email = EmailField()
    message = CharField(max_length = 1000)
end

json_view(req) = JsonResponse(Dict("message" => "Hello, World!", "items" => collect(1:10)))

const ROWS = [Dict("name" => "item number $i", "score" => i * 37 % 100, "tags" => ["alpha", "b<c>", "gamma"]) for i in 1:100]
template_view(req) = render(req, "page.html", Dict("title" => "A page of rows", "rows" => ROWS))

function posts_view(req)
    qs = order_by(select_related(objects(Post), :author), "id")
    render(req, "posts.html", Dict("page_obj" => page(Paginator(qs, 20), get(req.GET, "page", "1"))))
end

function form_view(req)
    form = ContactForm(req.method == "POST" ? req.POST : nothing)
    req.method == "POST" && is_valid(form) && return HttpResponse("Thanks, $(form.cleaned_data[:name])!")
    render(req, "form.html", Dict("form" => form))
end

Admin.register!(Post; list_display = [:title, :author, :created], search_fields = [:title], list_filter = [:author],
                list_per_page = 100)
Admin.register!(Author; list_display = [:name, :email])

const urlpatterns = [
    path("json/", json_view),
    path("template/", template_view),
    path("posts/", posts_view),
    path("form/", form_view),
    path("admin/", Admin.urls()),
]

configure!(
    DEBUG = false,
    SECRET_KEY = "benchmark-only-not-secret",
    ALLOWED_HOSTS = ["127.0.0.1", "localhost"],
    DATABASE = DB,
    MIGRATIONS_DIR = joinpath(@__DIR__, "migrations"),
    ROOT_URLCONF = urlpatterns,
    TEMPLATE_DIRS = [joinpath(@__DIR__, "..", "templates")],
    ACCESS_LOG = false,           # gunicorn and uvicorn (--no-access-log) don't log either
)

Juango.register_command!("seed", "The benchmark data: 20 authors, 1000 posts, superuser admin / admin-pass", function (args)
    exists(objects(Post)) && return println("Already seeded.")
    atomic() do
        create_superuser("admin", "admin-pass"; email = "admin@example.com")
        bulk_create([Author(name = "Author $i", email = "author$i@example.com") for i in 1:20])
        authors = collect(order_by(objects(Author), "id"))
        t0 = DateTime(2025, 1, 1)
        bulk_create([Post(title = "Post number $i", body = "The body of post $i. " ^ 20, author = authors[(i - 1) % 20 + 1],
                          created = t0 + Hour(i)) for i in 1:1000])
    end
    println("Seeded.")
end)
