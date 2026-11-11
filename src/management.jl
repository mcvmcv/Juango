# Management commands -------------------------------------------------------------------------
#
#     julia --project manage.jl runserver 8000
#     julia --project manage.jl migrate
#     julia --project manage.jl createsuperuser --username admin --email a@b.c

const COMMANDS = Dict{String,Tuple{String,Function}}()

"Register a custom management command: `register_command!(\"hello\", \"Say hi\", args -> println(\"hi\"))`."
register_command!(name, help, f) = (COMMANDS[string(name)] = (string(help), f); nothing)

function parse_flags(args)
    flags = Dict{String,String}()
    positional = String[]
    i = 1
    while i <= length(args)
        a = args[i]
        if startswith(a, "--")
            if occursin('=', a)
                k, v = split(a[3:end], '='; limit = 2)
                flags[k] = v
            elseif i < length(args) && !startswith(args[i+1], "--")
                flags[a[3:end]] = args[i+1]
                i += 1
            else
                flags[a[3:end]] = "true"
            end
        else
            push!(positional, a)
        end
        i += 1
    end
    positional, flags
end

function cmd_runserver(args)
    pos, _ = parse_flags(args)
    host, port = "127.0.0.1", 8000
    if !isempty(pos)
        a = pos[1]
        if occursin(':', a)
            h, p = rsplit(a, ':'; limit = 2)
            isempty(h) || (host = h)
            port = parse(Int, p)
        else
            port = parse(Int, a)
        end
    end
    runserver(host, port)
end

function prompt(msg, default = "")
    print(msg)
    s = readline()
    isempty(s) ? default : s
end

function cmd_createsuperuser(args)
    _, flags = parse_flags(args)
    noinput = haskey(flags, "noinput") || haskey(flags, "no-input")
    username = get(flags, "username", nothing)
    email = get(flags, "email", "")
    password = get(flags, "password", get(ENV, "JUANGO_SUPERUSER_PASSWORD", nothing))
    if username === nothing
        noinput && error("--username is required with --noinput")
        username = prompt("Username: ")
    end
    if !haskey(flags, "email") && !noinput
        email = prompt("Email address: ")
    end
    if password === nothing && !noinput
        while true
            p1 = read(Base.getpass("Password"), String)
            p2 = read(Base.getpass("Password (again)"), String)
            if p1 != p2
                println("Error: Your passwords didn't match.")
            elseif isempty(p1)
                println("Error: Blank passwords aren't allowed.")
            else
                password = p1
                break
            end
        end
    end
    exists(filter(objects(User); username = username)) && error("Error: That username is already taken.")
    create_superuser(username, password; email = email)
    println("Superuser created successfully.")
end

function cmd_showurls(args)
    rows = all_routes()
    isempty(rows) && return println("No URL patterns configured (settings.ROOT_URLCONF is empty).")
    w = maximum(length("/" * r) for (r, _, _) in rows)
    for (r, n, v) in rows
        println(rpad("/" * r, w + 2), rpad(something(n, ""), 28), view_label(v))
    end
end

function cmd_check(args)
    issues = String[]
    settings.SECRET_KEY == default_settings()[:SECRET_KEY] && !settings.DEBUG &&
        push!(issues, "SECRET_KEY is the insecure default while DEBUG is false.")
    isempty(settings.ROOT_URLCONF) && push!(issues, "ROOT_URLCONF is empty.")
    for d in settings.TEMPLATE_DIRS
        isdir(d) || push!(issues, "Template directory '$d' does not exist.")
    end
    for T in MODEL_LIST
        for f in modelmeta(T).fields
            f.kind === :fk || continue
            try
                related_model(f)
            catch e
                push!(issues, "$(nameof(T)).$(f.name): $(sprint(showerror, e))")
            end
        end
    end
    if isempty(issues)
        println("System check identified no issues (0 silenced).")
    else
        println("System check identified $(length(issues)) issue(s):")
        foreach(i -> println("  ⚠ ", i), issues)
    end
    issues
end

# migrate [app] [target] [--fake] [--sync]
function cmd_migrate(args)
    pos, flags = parse_flags(args)
    app, target = nothing, nothing
    if length(pos) >= 2
        app, target = pos[1], pos[2]
    elseif length(pos) == 1
        if pos[1] in Migrations.known_apps()
            app, target = pos[1], nothing
        else
            app, target = "project", pos[1]
        end
    end
    if app !== nothing && target === nothing
        # "migrate juango": everything pending for that app (and what it depends on)
        g = Migrations.build_graph()
        ks = [k for k in Migrations.topo_order(g) if k[1] == app]
        isempty(ks) && return println("App '$app' has no migrations.")
        target = last(ks)[2]
    end
    migrate(; app = app, target = target, fake = haskey(flags, "fake"), sync = haskey(flags, "sync"))
end

# makemigrations [--app NAME] [--name NAME] [--empty] [--merge] [--dry-run] [--check] [--noinput]
function cmd_makemigrations(args)
    _, flags = parse_flags(args)
    q = haskey(flags, "noinput") || haskey(flags, "no-input") ? (_ -> false) : Migrations.ask
    paths = makemigrations(; app = get(flags, "app", "project"), name = get(flags, "name", nothing),
                           empty = haskey(flags, "empty"), merge = haskey(flags, "merge"),
                           dry_run = haskey(flags, "dry-run"), check = haskey(flags, "check"), questioner = q)
    haskey(flags, "check") && !isempty(paths) && exit(1)
    paths
end

# sqlmigrate [app] name [--backwards]
function cmd_sqlmigrate(args)
    pos, flags = parse_flags(args)
    isempty(pos) && error("usage: sqlmigrate [app] <migration> [--backwards]")
    app, name = length(pos) >= 2 ? (pos[1], pos[2]) : ("project", pos[1])
    println(sqlmigrate(app, name; backwards = haskey(flags, "backwards")))
end

function cmd_help(args)
    println("Usage: julia --project manage.jl <command> [options]\n\nAvailable commands:")
    for k in sort(collect(keys(COMMANDS)))
        println("  ", rpad(k, 18), COMMANDS[k][1])
    end
end

function cmd_shell(args)
    println("Juango shell — models and settings are loaded. Start Julia with:")
    println("    julia --project -i manage.jl")
    println("(running manage.jl without a command in interactive mode loads your project without doing anything.)")
end

for (n, h, f) in (
    ("runserver", "Start the development server: runserver [host:]port", cmd_runserver),
    ("migrate", "Apply migrations: migrate [app] [target|zero] [--fake] [--sync]", cmd_migrate),
    ("makemigrations", "Write migrations for model changes (--name, --empty, --merge, --dry-run, --check, --noinput, --app)", cmd_makemigrations),
    ("showmigrations", "List migrations and whether they are applied", _ -> showmigrations()),
    ("sqlmigrate", "Print the SQL for a migration: sqlmigrate [app] <name> [--backwards]", cmd_sqlmigrate),
    ("createsuperuser", "Create an admin user (--username, --email, --password, --noinput)", cmd_createsuperuser),
    ("showurls", "List all URL patterns", cmd_showurls),
    ("createcachetable", "Create the table for database caches (CACHES backend :db)", _ -> foreach(create_cache_table, keys(settings.CACHES))),
    ("sqlschema", "Print the SQL schema for all models", _ -> println(schema_sql())),
    ("check", "Inspect the project for common problems", cmd_check),
    ("clearsessions", "Delete expired sessions", _ -> println("Deleted ", clear_expired_sessions!(), " expired sessions.")),
    ("changepassword", "Change a user's password: changepassword <username>", function (args)
        pos, flags = parse_flags(args)
        u = get(objects(User); username = isempty(pos) ? prompt("Username: ") : pos[1])
        pw = get(flags, "password", nothing)
        pw === nothing && (pw = read(Base.getpass("New password"), String))
        set_password!(u, pw)
        save!(u)
        println("Password changed successfully for user '$(u.username)'")
    end),
    ("shell", "How to start an interactive session with the project loaded", cmd_shell),
    ("help", "Show this message", cmd_help))
    COMMANDS[n] = (h, f)
end

"""
    execute_from_command_line(args=ARGS)

Entry point used by a project's `manage.jl`.
"""
function execute_from_command_line(args = ARGS)
    if isempty(args)
        isinteractive() && return nothing
        return cmd_help(args)
    end
    cmd = args[1]
    entry = get(COMMANDS, cmd, nothing)
    if entry === nothing
        println(stderr, "Unknown command: '$cmd'. Type 'julia --project manage.jl help' for usage.")
        return nothing
    end
    entry[2](args[2:end])
end

# --- startproject ---------------------------------------------------------------------------------

"""
    startproject(name; dir=pwd(), juango_path=pkgdir(Juango))

Create a new project skeleton in `dir/name` with `manage.jl`, settings, URLs,
models, views and templates, and an environment that depends on Juango.
"""
function startproject(name::AbstractString; dir = pwd(), juango_path = pkgdir(@__MODULE__), develop = true)
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", name) || error("'$name' is not a valid project name (use letters, digits, underscores).")
    root = joinpath(dir, name)
    ispath(root) && error("'$root' already exists")
    mkpath(joinpath(root, "templates"))
    mkpath(joinpath(root, "static"))
    secret = random_string(50)
    files = Dict(
        "manage.jl" => """
        #!/usr/bin/env julia
        # Project management script: julia --project manage.jl <command>
        include(joinpath(@__DIR__, "project.jl"))
        Juango.execute_from_command_line(ARGS)
        """,
        "project.jl" => """
        # Loads the whole project (settings, models, views, urls).
        using Juango
        using Dates

        const BASE_DIR = @__DIR__

        include(joinpath(BASE_DIR, "models.jl"))
        include(joinpath(BASE_DIR, "admin.jl"))
        include(joinpath(BASE_DIR, "views.jl"))
        include(joinpath(BASE_DIR, "urls.jl"))
        include(joinpath(BASE_DIR, "settings.jl"))
        """,
        "settings.jl" => """
        configure!(
            DEBUG = get(ENV, "JUANGO_DEBUG", "true") == "true",
            SECRET_KEY = get(ENV, "JUANGO_SECRET_KEY", "$secret"),
            ALLOWED_HOSTS = ["localhost", "127.0.0.1"],
            # For PostgreSQL: Pkg.add("LibPQ"), add `using LibPQ` to project.jl, then
            # DATABASE = "postgresql://user:password@localhost:5432/$name",
            DATABASE = joinpath(BASE_DIR, "db.sqlite3"),
            MIGRATIONS_DIR = joinpath(BASE_DIR, "migrations"),
            ROOT_URLCONF = urlpatterns,
            TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
            STATIC_DIRS = [joinpath(BASE_DIR, "static")],
            MEDIA_ROOT = joinpath(BASE_DIR, "media"),     # uploaded files (FileField/ImageField)
            SITE_NAME = "$name",
        )
        """,
        "models.jl" => """
        # Define your models here, then run:
        #     julia --project manage.jl makemigrations
        #     julia --project manage.jl migrate

        @model struct Note
            title = CharField(max_length = 200)
            body = TextField(blank = true)
            created = DateTimeField(auto_now_add = true)
            Meta(ordering = ["-created"])
        end

        Base.show(io::IO, n::Note) = print(io, n.title)
        """,
        "admin.jl" => """
        Admin.register!(Note; list_display = [:title, :created], search_fields = [:title, :body])
        """,
        "views.jl" => """
        function home(req)
            render(req, "home.html", Dict("notes" => objects(Note)[1:10]))
        end
        """,
        "urls.jl" => """
        const urlpatterns = [
            path("", home; name = "home"),
            path("admin/", Admin.urls()),
        ]
        """,
        "templates/base.html" => """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>{% block title %}$name{% endblock %}</title>
          <link rel="stylesheet" href="{% static 'style.css' %}">
        </head>
        <body>
          <main>
            {% for message in messages %}<p class="msg {{ message.tags }}">{{ message }}</p>{% endfor %}
            {% block content %}{% endblock %}
          </main>
        </body>
        </html>
        """,
        "templates/home.html" => """
        {% extends "base.html" %}
        {% block content %}
          <h1>The install worked successfully! Congratulations!</h1>
          <p>You are seeing this page because <code>DEBUG = true</code>. Edit <code>views.jl</code> and <code>templates/home.html</code>.</p>
          <p><a href="{% url 'admin:index' %}">Go to the admin</a> (create a user with <code>julia --project manage.jl createsuperuser</code>).</p>
          <h2>Latest notes</h2>
          <ul>{% for note in notes %}<li>{{ note.title }} — {{ note.created|timesince }} ago</li>{% empty %}<li>No notes yet.</li>{% endfor %}</ul>
        {% endblock %}
        """,
        "static/style.css" => """
        body { font: 16px/1.6 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #222; }
        .msg { padding: .5rem 1rem; background: #eef; border-radius: 4px; }
        .msg.success { background: #e6f6e6; } .msg.error { background: #fde8e8; }
        """,
        ".gitignore" => "db.sqlite3*\nManifest.toml\n",
    )
    for (rel, content) in files
        p = joinpath(root, rel)
        mkpath(dirname(p))
        write(p, content)
    end
    write(joinpath(root, "Project.toml"), "[deps]\nDates = \"ade2ca70-3891-5945-98fb-dc099432e06a\"\nJuango = \"05cba04f-b8df-4159-83db-d292e8d0197f\"\n")
    if develop
        try
            cmd = `$(Base.julia_cmd()) --project=$root -e "using Pkg; Pkg.develop(path=raw\"$juango_path\")"`
            run(pipeline(cmd; stdout = devnull, stderr = devnull))
        catch e
            @warn "Could not add Juango to the new project's environment automatically. Run: julia --project=$root -e 'using Pkg; Pkg.develop(path=\"$juango_path\")'" exception = e
        end
    end
    println("""Created project '$name' in $root

    Next steps:
      cd $root
      julia --project manage.jl makemigrations
      julia --project manage.jl migrate
      julia --project manage.jl createsuperuser
      julia --project manage.jl runserver
    """)
    root
end
