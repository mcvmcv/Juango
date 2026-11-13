# Precompile workload --------------------------------------------------------------------------------
# Runs a small project while Juango precompiles, so the code for templates, the ORM, forms, request
# handling, the admin and the server's response writing is compiled once and kept in the package
# image instead of being compiled again in every process that loads Juango.

"""
    precompile_workload()

Exercise the main code paths on an in-memory SQLite database, then put every piece of global
state back as it was. Runs at precompile time; harmless (if slow) to call by hand.
"""
function precompile_workload()
    tdir = mktempdir()
    write(joinpath(tdir, "base.html"),
          "<html><title>{% block title %}Site{% endblock %}</title>{% block content %}{% endblock %}</html>")
    write(joinpath(tdir, "page.html"), """
        {% extends "base.html" %}{% load i18n static %}
        {% block title %}{{ title|title }}{% endblock %}
        {% block content %}{% csrf_token %}{% url "home" %} {% static "x.css" %} {% trans "Hello" %}
        {% for u in users %}<p class="{% cycle 'a' 'b' %}">{{ forloop.counter }} {{ u.username|upper }}
          {{ u.date_joined|date:"Y-m-d" }}{% if u.is_staff %} staff{% else %} user{% endif %}</p>
        {% empty %}none{% endfor %}
        {% with n=users|length %}{{ n|add:1 }} {{ n|pluralize }}{% endwith %}
        {{ tags|join:", " }} {{ html }} {{ html|safe }} {{ title|default:"x"|truncatechars:5|lower }} {{ 3.14159|floatformat:2 }}
        {% include "part.html" %}{% endblock %}""")
    write(joinpath(tdir, "part.html"), "{{ title|slugify }}")
    # a paginated list of model instances with a foreign key, as most list pages are
    write(joinpath(tdir, "list.html"), """
        {% extends "base.html" %}{% block content %}<ul>{% for p in page_obj %}
        <li><a href="{% url 'perm' p.id %}">{{ p.name|truncatewords:3 }}</a> {{ p.content_type.app_label }} {{ p.codename|default:"-" }}</li>
        {% endfor %}</ul>{% if page_obj.has_next %}<a href="?page={{ page_obj.next_page_number }}">next</a>{% endif %}
        {{ page_obj.number }} / {{ page_obj.paginator.num_pages }}{% endblock %}""")
    write(joinpath(tdir, "form.html"), """
        {% extends "base.html" %}{% block content %}<form method="post">{% csrf_token %}{{ form }}{{ form.as_div }}
        {% for f in form %}{{ f.label_tag }}{{ f }}{{ f.errors }}{% endfor %}</form>{% endblock %}""")
    home(req) = render(req, "page.html", Dict{String,Any}("title" => "hello world", "html" => "<b>", "tags" => ["a", "b<"],
                                                          "users" => collect(objects(User))))
    json_view(req) = JsonResponse(Dict("ok" => true, "n" => count(objects(User)), "ints" => collect(1:3), "names" => ["a", "b"],
                                       "mixed" => Any[1, "x", nothing, 1.5, false], "nested" => Dict("k" => "v"),
                                       "rows" => [Dict("name" => "a", "score" => 1)], "any" => Dict{String,Any}("t" => now())))
    stream(req) = StreamingHttpResponse(("row $i\n" for i in 1:3))
    function perms(req)
        qs = order_by(select_related(objects(Permission), :content_type), "id")
        render(req, "list.html", Dict("page_obj" => page(Paginator(qs, 5), get(req.GET, "page", "1"))))
    end
    perm(req; id) = JsonResponse(Dict("name" => Juango.get(objects(Permission); id = id).name))
    function signup(req)
        form = UserCreationForm(req.method == "POST" ? req.POST : nothing)
        req.method == "POST" && is_valid(form) && (save!(form); return redirect("/"))
        render(req, "form.html", Dict("form" => form); status = req.method == "POST" ? 422 : 200)
    end
    # a second admin site, so registering models doesn't touch the default one
    site = Admin.AdminSite("precompile")
    Admin.register!(Permission; site = site, list_display = [:name, :content_type, :codename],
                    list_filter = [:content_type], search_fields = [:name, :codename])
    Admin.register!(User; site = site, list_display = [:username, :email, :is_staff], list_filter = [:is_staff, :is_active],
                    search_fields = [:username, :email])
    urls = [path("", home; name = "home"), path("api/<int:id>/", (req; id) -> json_view(req); name = "api"),
            path("stream/", stream), path("admin/", Admin.urls()), path("perms/", perms),
            path("perms/<int:id>/", perm; name = "perm"), path("signup/", signup), path("site/", Admin.urls(site))]
    old_stdout = stdout
    try
        configure!(DATABASE = ":memory:", ROOT_URLCONF = urls, TEMPLATE_DIRS = [tdir], DEBUG = false, TEMPLATE_COMPILE = :eager,
                   PASSWORD_ITERATIONS = 1, ALLOWED_HOSTS = ["testserver"], SECRET_KEY = "precompile")
        Admin.register_builtin!()                 # done by __init__ at load time
        migrate(verbose = false)
        root = create_superuser("root", "precompile-pw")
        create_user("ann", "precompile-pw"; email = "ann@example.com")

        # ORM
        auto_pk_kind(:BigAutoField)
        qs = order_by(filter(objects(User); username__startswith = "a", is_active = true), "-id")
        collect(qs); count(qs); exists(qs); first(collect(values_list(objects(User), :username)))
        collect(annotate(objects(Group), n = Count("user_set")))
        get_or_create(Group; name = "editors")
        u = Juango.get(objects(User); username = "ann")
        u.first_name = "Ann"; save!(u)
        atomic(() -> update!(filter(objects(User); username = "ann"); last_name = "Lee"))
        g = Juango.get(objects(Group); name = "editors")
        add!(g.permissions, first(objects(Permission)))
        collect(prefetch_related(objects(Group), :permissions)); collect(prefetch_related(objects(User), :groups))
        for p in select_related(filter(objects(Permission); content_type__app_label = "auth"), :content_type)[1:3]
            p.content_type.model; p.name
        end
        exists(exclude(objects(User); is_staff = true)); last(objects(User)); count(u.groups)
        collect(values(objects(User), :username, :email)); Dict(get_or_create(Group; name = "x")[1] => 1)

        # templates directly
        render(Template("{{ a }}{% for x in xs %}{{ x|add:2 }},{% endfor %}{{ d.k|default:'-' }}"),
               Dict{String,Any}("a" => "<i>", "xs" => [1, 2], "d" => Dict("k" => nothing)))

        # requests through the middleware, as a browser would: templates interpreted (as on their
        # first renders, while they're compiled in the background), then compiled
        c = Client()
        COMPILE_TEMPLATES[] = :interpret
        get(c, "/"); get(c, "/perms/"); get(c, "/signup/")
        post(c, "/signup/", Dict("username" => "carl", "password1" => "x", "password2" => "y"))
        COMPILE_TEMPLATES[] = :eager
        get(c, "/"); get(c, "/api/1/"); text(get(c, "/stream/")); get(c, "/missing/")
        get(c, "/admin/login/")
        post(c, "/admin/login/?next=/admin/", Dict("username" => "root", "password" => "precompile-pw"))
        get(c, "/admin/"); get(c, "/admin/user/"); get(c, "/admin/user/?q=ann")
        get(c, "/admin/user/$(root.id)/change/"); get(c, "/admin/group/add/")
        post(c, "/admin/group/add/", Dict("name" => "writers"))
        get(c, "/perms/"); get(c, "/perms/?page=2"); get(c, "/perms/1/")
        get(c, "/signup/"); post(c, "/signup/", Dict("username" => "bob", "password1" => "x", "password2" => "y"))
        post(c, "/signup/", Dict("username" => "bob", "password1" => "precompile-pw-9", "password2" => "precompile-pw-9"))
        get(c, "/site/"); get(c, "/site/permission/"); get(c, "/site/permission/?content_type__id__exact=1&q=add&o=1")
        get(c, "/site/permission/1/change/"); get(c, "/site/user/?is_staff__exact=1&q=a")
        post(c, "/site/user/$(root.id)/change/", Dict("username" => "root", "email" => "r@example.com", "is_staff" => "on",
                                                      "is_active" => "on", "is_superuser" => "on"))

        # the server's side of a response
        hreq = HTTP.Request("GET", "/api/1/", ["Host" => "testserver", "Cookie" => "a=1"], UInt8[])
        to_http(consume_stream!(handle_request(from_http(hreq))))       # http_handler without the log line
    catch e
        @warn "Juango precompile workload failed (please report this)" exception = (e, catch_backtrace())
    finally
        close_connection!()
        for a in values(APP_DEFS)
            a.is_ready = false
        end
        reset_settings!()
        lock(() -> empty!(CT_CACHE), CT_LOCK)
        lock(() -> empty!(CACHE_INSTANCES), CACHE_INSTANCES_LOCK)
        lock(() -> empty!(REVERSE_CACHE), REVERSE_LOCK)
        lock(() -> empty!(COMPILED_NODES), COMPILED_LOCK)  # compiled templates (the generators stay precompiled)
        rm(tdir; recursive = true, force = true)
    end
    nothing
end

# the background compiler (the workload compiles templates eagerly)
precompile(put!, (Channel{Tuple{Vector{Node},UInt}}, Tuple{Vector{Node},UInt}))
precompile(compile_worker, (Channel{Tuple{Vector{Node},UInt}},))
precompile(compile_queue, ())

# the PostgreSQL driver (no server to run it against here)
for f in (pg_bool, pg_int, pg_float, pg_numeric, pg_bytea, pg_bpchar, pg_date, pg_timestamp, pg_timestamptz,
          pg_int_array, pg_float_array, pg_numeric_array, pg_string)
    precompile(read_pg_column!, (Vector{Dict{Symbol,Any}}, Symbol, Ptr{Cvoid}, Int, typeof(f)))
end
precompile(pg_connect, (String,)); precompile(pg_exec, (PGConn, String, Vector{Any}))
precompile(pg_read_result, (Ptr{Cvoid},)); precompile(pg_usable, (PGConn,)); precompile(pg_close, (PGConn,))
precompile(open_connection, (PostgresBackend,)); precompile(driver_rows, (PostgresBackend, PGConn, String, Vector{Any}))
precompile(driver_rowcount, (PostgresBackend, PGConn, String, Vector{Any}))
precompile(driver_insert_id, (PostgresBackend, PGConn, String, Vector{Any}))

@setup_workload begin
    @compile_workload begin
        precompile_workload()
    end
end
