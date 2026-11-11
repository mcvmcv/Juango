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
        {{ html }} {{ html|safe }} {{ title|default:"x"|truncatechars:5|lower }} {{ 3.14159|floatformat:2 }}
        {% include "part.html" %}{% endblock %}""")
    write(joinpath(tdir, "part.html"), "{{ title|slugify }}")
    home(req) = render(req, "page.html", Dict{String,Any}("title" => "hello world", "html" => "<b>",
                                                          "users" => collect(objects(User))))
    json_view(req) = JsonResponse(Dict("ok" => true, "n" => count(objects(User))))
    stream(req) = StreamingHttpResponse(("row $i\n" for i in 1:3))
    urls = [path("", home; name = "home"), path("api/<int:id>/", (req; id) -> json_view(req); name = "api"),
            path("stream/", stream), path("admin/", Admin.urls())]
    old_stdout = stdout
    try
        configure!(DATABASE = ":memory:", ROOT_URLCONF = urls, TEMPLATE_DIRS = [tdir], DEBUG = false,
                   PASSWORD_ITERATIONS = 1, ALLOWED_HOSTS = ["testserver"], SECRET_KEY = "precompile")
        Admin.register_builtin!()                 # done by __init__ at load time
        migrate(verbose = false)
        root = create_superuser("root", "precompile-pw")
        create_user("ann", "precompile-pw"; email = "ann@example.com")

        # ORM
        qs = order_by(filter(objects(User); username__startswith = "a", is_active = true), "-id")
        collect(qs); count(qs); exists(qs); first(collect(values_list(objects(User), :username)))
        collect(annotate(objects(Group), n = Count("user_set")))
        get_or_create(Group; name = "editors")
        u = Juango.get(objects(User); username = "ann")
        u.first_name = "Ann"; save!(u)
        atomic(() -> update!(filter(objects(User); username = "ann"); last_name = "Lee"))

        # templates directly
        render(Template("{{ a }}{% for x in xs %}{{ x|add:2 }},{% endfor %}{{ d.k|default:'-' }}"),
               Dict{String,Any}("a" => "<i>", "xs" => [1, 2], "d" => Dict("k" => nothing)))

        # requests through the middleware, as a browser would
        c = Client()
        get(c, "/"); get(c, "/api/1/"); text(get(c, "/stream/")); get(c, "/missing/")
        get(c, "/admin/login/")
        post(c, "/admin/login/?next=/admin/", Dict("username" => "root", "password" => "precompile-pw"))
        get(c, "/admin/"); get(c, "/admin/user/"); get(c, "/admin/user/?q=ann")
        get(c, "/admin/user/$(root.id)/change/"); get(c, "/admin/group/add/")
        post(c, "/admin/group/add/", Dict("name" => "writers"))

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
        rm(tdir; recursive = true, force = true)
    end
    nothing
end

@setup_workload begin
    @compile_workload begin
        precompile_workload()
    end
end
