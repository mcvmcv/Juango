# Management commands -------------------------------------------------------------------------
#
#     julia --project manage.jl runserver 8000
#     julia --project manage.jl migrate
#     julia --project manage.jl createsuperuser --username admin --email a@b.c

const COMMANDS = Dict{String,Tuple{String,Function}}()

"Register a custom management command: `register_command!(\"hello\", \"Say hi\", args -> println(\"hi\"))`."
register_command!(name, help, f) = (COMMANDS[string(name)] = (string(help), f); nothing)

"""
    CommandError(msg)

A command's failure, as Django's: `execute_from_command_line` prints `CommandError: msg` to stderr
and exits with status 1 (a script; in the REPL it only prints). `call_command` lets it through.
"""
struct CommandError <: Exception
    msg::String
    returncode::Int        # the exit status from the command line (Django's returncode)
end
CommandError(msg::AbstractString = ""; returncode::Integer = 1) = CommandError(String(msg), Int(returncode))
Base.showerror(io::IO, e::CommandError) = print(io, "CommandError: ", e.msg)

# A command's input and output: the terminal, or what call_command gives (Django's stdin/stdout/stderr
# options and its mocked getpass/input). getpass(prompt) reads a password; system_user is getpass.getuser().
Base.@kwdef struct CommandIO
    stdin::IO = Base.stdin
    stdout::IO = Base.stdout
    stderr::IO = Base.stderr
    getpass::Any = p -> read(Base.getpass(p), String)
    isatty::Bool = Base.stdin isa Base.TTY
    system_user::String = something(get(ENV, "USER", nothing), get(ENV, "USERNAME", nothing), "")
end
const COMMAND_IO = Base.ScopedValues.ScopedValue{Union{Nothing,CommandIO}}(nothing)
command_io() = something(COMMAND_IO[], CommandIO())
cmd_stdout() = command_io().stdout
cmd_stderr() = command_io().stderr

"""
    call_command(name, args...; stdin = "", stdout = IOBuffer(), stderr = IOBuffer(), getpass = nothing,
                 isatty = true, system_user = "") -> the command's return value

Run a management command from code or a test, as Django's `call_command`: `args` are its
command-line words (`call_command("createsuperuser", "--username=joe", "--noinput")`). Its prompts read
lines from `stdin` (a string or an IO); `getpass` answers password prompts (a function of the prompt, or
a vector of answers in turn; by default lines of `stdin` too). Output goes to `stdout` and `stderr`.
A `CommandError` is thrown, not printed.
"""
function call_command(name::AbstractString, args...; stdin = "", stdout = IOBuffer(), stderr = IOBuffer(), getpass = nothing,
                      isatty::Bool = true, system_user::AbstractString = "", options...)
    entry = get(all_commands(), String(name), nothing)
    entry === nothing && throw(CommandError("Unknown command: '$name'"))
    decl = get(DECLARED_COMMANDS, String(name), nothing)
    decl === nothing || COMMANDS[String(name)] === entry || (decl = nothing)      # (an app's command of the same name)
    decl === nothing && !isempty(options) &&
        throw(ArgumentError("Unknown option(s) for $name command: $(join(sort(string.(keys(options))), ", ")). It takes command-line words only."))
    inp = stdin isa AbstractString ? IOBuffer(stdin) : stdin
    gp = getpass === nothing ? (p -> readline(inp)) :
         getpass isa AbstractVector ? (answers = Iterators.Stateful(getpass); p -> String(popfirst!(answers))) : getpass
    io = CommandIO(; stdin = inp, stdout = stdout, stderr = stderr, getpass = gp, isatty = isatty, system_user = String(system_user))
    words = String[string(x) for a in args for x in (a isa Union{AbstractVector,Tuple} ? a : (a,))]   # (a list: its items, as Django's)
    Base.ScopedValues.with(COMMAND_IO => io) do
        decl === nothing ? entry[2](words) : run_declared(decl, words, (; options...); from_code = true)
    end
end

"makemessages/compilemessages options, repeatable as Django's: -l/--locale, -x/--exclude, -i/--ignore, -e/--extension, -a/--all, --flag[=value]."
function i18n_command_options(args)
    lists = Dict(k => String[] for k in ("locale", "exclude", "ignore", "extension"))
    short = Dict("-l" => "locale", "-x" => "exclude", "-i" => "ignore", "-e" => "extension")
    flags, all = Dict{String,String}(), false
    i = 1
    while i <= length(args)
        a = args[i]
        if haskey(short, a) && i < length(args)
            push!(lists[short[a]], args[i+1]); i += 1
        elseif a in ("-a", "--all")
            all = true
        elseif a == "-f"
            flags["f"] = "true"
        elseif startswith(a, "--")
            k, v = occursin('=', a) ? split(a[3:end], '='; limit = 2) : (a[3:end], nothing)
            if haskey(lists, k)
                v === nothing && i < length(args) && (v = args[i+1]; i += 1)
                v === nothing || append!(lists[k], split(v, ','))
            else
                flags[k] = something(v, "true")
            end
        end
        i += 1
    end
    (; locale = lists["locale"], exclude = lists["exclude"], ignore = lists["ignore"], extension = lists["extension"], all,
       flag = k -> haskey(flags, k), value = k -> get(flags, k, nothing))
end

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

const NAIVE_IP_RE = r"^(?:(?<addr>(?<ipv4>\d{1,3}(?:\.\d{1,3}){3})|(?<ipv6>\[[a-fA-F0-9:]+\])|(?<fqdn>[a-zA-Z0-9-]+(?:\.[a-zA-Z0-9-]+)*)):)?(?<port>\d+)$"
"""
    parse_addrport(addrport = ""; use_ipv6 = false, default_addr = "127.0.0.1", default_addr_ipv6 = "::1", default_port = "8000")
        -> (addr, port, use_ipv6, raw_ipv6)

runserver's `[addr:]port` argument, as Django's: an IPv4 address, `[an IPv6 one]` or a host name, then
the port. `raw_ipv6` says the address is an IPv6 address (shown in brackets).
"""
function parse_addrport(addrport::AbstractString = ""; use_ipv6::Bool = false, default_addr = "127.0.0.1",
                        default_addr_ipv6 = "::1", default_port = "8000")
    addr, port, raw = "", string(default_port), false
    if !isempty(addrport)
        m = match(NAIVE_IP_RE, addrport)
        m === nothing && throw(CommandError("\"$addrport\" is not a valid port number or address:port pair."))
        port = String(m[:port])
        if m[:addr] !== nothing
            addr = String(m[:addr])
            if m[:ipv6] !== nothing
                addr, use_ipv6, raw = addr[2:end-1], true, true
            elseif use_ipv6 && m[:fqdn] === nothing
                throw(CommandError("\"$addr\" is not a valid IPv6 address."))
            end
        end
    end
    isempty(addr) && ((addr, raw) = (use_ipv6 ? default_addr_ipv6 : default_addr, use_ipv6))
    (addr, port, use_ipv6, raw)
end

function cmd_runserver(args)
    ipv6 = "-6" in args || "--ipv6" in args
    pos, flags = parse_flags(filter(a -> !(a in ("-6", "--ipv6")), args))
    addr, port, _, _ = parse_addrport(isempty(pos) ? "" : pos[1]; use_ipv6 = ipv6)
    runserver(addr == "0" ? "0.0.0.0" : addr, parse(Int, port); certfile = get(flags, "cert", nothing), keyfile = get(flags, "key", nothing),
              reload = !haskey(flags, "noreload"))
end

function prompt(msg, default = "")
    io = command_io()
    print(io.stdout, msg)
    s = readline(io.stdin)
    isempty(s) ? default : s
end

"The fields `createsuperuser` asks for besides the username and password (Django's REQUIRED_FIELDS); define a method for your user model."
required_fields(T::Type) = username_field(T) === :email ? () : (:email,)

# (as Django's createsuperuser: a username error as a message, or nothing)
function superuser_username_error(U, name)
    uf = username_field(U)
    vname = string(getfield_meta(U, uf).verbose_name)
    exists(filter(objects(U), Q(uf => name))) && return "Error: That $vname is already taken."
    isempty(name) && return uppercasefirst(vname) * " cannot be blank."
    errs = validate_field(getfield_meta(U, uf), name)
    isempty(errs) ? nothing : join(errs, "; ")
end
# one field's value, cleaned as the model field does; the error messages or nothing
function superuser_field_errors(U, f::Symbol, v)
    fl = getfield_meta(U, f)
    isempty(v) && !fl.blank && return ["This field cannot be blank."]
    isempty(v) && return nothing
    errs = validate_field(fl, v)
    isempty(errs) ? nothing : errs
end
"The system user's name as a username suggestion, if it's a valid one and not taken (Django's get_default_username)."
function default_superuser_username(U, system_user)
    name = lowercase(Base.Unicode.normalize(system_user; stripmark = true))
    name = filter(isascii, name)
    (isempty(name) || superuser_username_error(U, name) !== nothing) ? "" : name
end

"""
createsuperuser [--username U] [--email E] [--noinput] [--verbosity 0]: as Django's. Interactive, it
asks for what's missing (suggesting the system user's name) and the password twice, repeats a question
whose answer isn't valid, and offers to bypass the password validators. With `--noinput` the username,
email and password come from the flags or JUANGO_SUPERUSER_USERNAME / _EMAIL / _PASSWORD; without a
password the user gets an unusable one.
"""
function cmd_createsuperuser(args)
    _, flags = parse_flags(args)
    io = command_io()
    out, err = io.stdout, io.stderr
    noinput = haskey(flags, "noinput") || haskey(flags, "no-input")
    verbosity = parse(Int, get(flags, "verbosity", "1"))
    U = get_user_model()
    uf = username_field(U)
    vname = string(getfield_meta(U, uf).verbose_name)
    others = [f for f in required_fields(U) if f !== uf]
    data = Dict{Symbol,Any}()
    password = get(flags, "password", nothing)
    username = get(flags, string(uf), get(flags, "username", nothing))
    try
        if noinput
            password = something(password, get(ENV, "JUANGO_SUPERUSER_PASSWORD", nothing), Some(nothing))
            username = something(username, get(ENV, "JUANGO_SUPERUSER_" * uppercase(string(uf)), nothing), Some(nothing))
            username === nothing && throw(CommandError("You must use --$uf with --noinput."))
            e = superuser_username_error(U, username)
            e === nothing || throw(CommandError(e))
            for f in others
                v = something(get(flags, string(f), nothing), get(ENV, "JUANGO_SUPERUSER_" * uppercase(string(f)), nothing), Some(nothing))
                v === nothing && throw(CommandError("You must use --$f with --noinput."))
                errs = superuser_field_errors(U, f, v)
                errs === nothing || throw(CommandError(join(errs, "; ")))
                data[f] = v
            end
        else
            io.isatty || (println(out, "Superuser creation skipped due to not running in a TTY. You can run `manage.py createsuperuser` in your project to create one manually."); return nothing)
            if username !== nothing
                e = superuser_username_error(U, username)
                e === nothing || (println(err, e); username = nothing)
            end
            default = default_superuser_username(U, io.system_user)
            while username === nothing
                msg = uppercasefirst(vname) * (isempty(default) ? "" : " (leave blank to use '$default')") * ": "
                v = prompt(msg, default)
                e = isempty(v) ? "Error: This field cannot be blank." : superuser_username_error(U, v)
                e === nothing ? (username = v) : println(err, startswith(e, "Error: ") ? e : "Error: " * e)
            end
            for f in others
                if haskey(flags, string(f))
                    errs = superuser_field_errors(U, f, flags[string(f)])
                    errs === nothing && (data[f] = flags[string(f)]; continue)
                    println(err, "Error: ", join(errs, "; "))
                end
                while !haskey(data, f)
                    v = prompt(uppercasefirst(string(getfield_meta(U, f).verbose_name)) * ": ")
                    errs = superuser_field_errors(U, f, v)
                    errs === nothing ? (data[f] = v) : println(err, "Error: ", join(errs, "; "))
                end
            end
            while password === nothing
                p1 = io.getpass("Password: ")
                p2 = io.getpass("Password (again): ")
                if p1 != p2
                    println(err, "Error: Your passwords didn't match.")
                elseif isempty(strip(p1))
                    println(err, "Error: Blank passwords aren't allowed.")
                else
                    errs = validate_password(p1; user = (; uf => username, (k => v for (k, v) in data)...))
                    if !isempty(errs)
                        println(err, join(errs, "\n"))
                        lowercase(strip(prompt("Bypass password validation and create user anyway? [y/N]: "))) in ("y", "yes") || continue
                    end
                    password = p1
                end
            end
        end
    catch e
        e isa InterruptException || rethrow()
        println(err, "\nOperation cancelled.")
        throw(CommandError("Operation cancelled."))
    end
    create_superuser(username, password; data...)
    verbosity >= 1 && println(out, "Superuser created successfully.")
    nothing
end

"""
changepassword [username] [--password P]: as Django's. The username defaults to the system user's; the
password is asked for twice, up to three times if they differ or the validators refuse it.
"""
function cmd_changepassword(args)
    pos, flags = parse_flags(args)
    io = command_io()
    U = get_user_model()
    name = isempty(pos) ? io.system_user : pos[1]
    u = first(filter(objects(U), Q(username_field(U) => name)))
    u === nothing && throw(CommandError("user '$name' does not exist"))
    pw = get(flags, "password", nothing)
    if pw === nothing
        println(io.stdout, "Changing password for user '$(get_username(u))'")
        tries, ok = 0, false
        while !ok && tries < 3
            p1 = io.getpass("Password: ")
            p2 = io.getpass("Password (again): ")
            if p1 != p2
                println(io.stdout, "Passwords do not match. Please try again.")
                tries += 1
                continue
            end
            errs = validate_password(p2; user = u)
            if isempty(errs)
                ok, pw = true, p1
            else
                println(io.stderr, join(errs, "\n"))
                tries += 1
            end
        end
        ok || throw(CommandError("Aborting password change for user '$(get_username(u))' after $tries attempts"))
    end
    set_password!(u, pw)
    save!(u)
    println(io.stdout, "Password changed successfully for user '$(get_username(u))'")
    "Password changed successfully for user '$(get_username(u))'"
end

function cmd_showurls(args)
    rows = all_routes()
    isempty(rows) && return println("No URL patterns configured (settings.ROOT_URLCONF is empty).")
    w = maximum(length("/" * r) for (r, _, _) in rows)
    for (r, n, v) in rows
        println(rpad("/" * r, w + 2), rpad(something(n, ""), 28), view_label(v))
    end
end

# Juango's own system checks (`register_check!` adds yours)
register_check!(tags = [:security]) do
    get(settings, :SECRET_KEY, "") == default_settings()[:SECRET_KEY] && !settings.DEBUG ?
        [CheckMessage(:error, "SECRET_KEY is the insecure default while DEBUG is false."; id = "security.E101")] : CheckMessage[]
end
register_check!(tags = [:urls]) do
    msgs = [CheckMessage(:error, m; id = "urls.E007") for m in error_handler_issues()]
    isempty(settings.ROOT_URLCONF) && push!(msgs, CheckMessage(:warning, "ROOT_URLCONF is empty."; id = "urls.W001"))
    msgs
end
register_check!(tags = [:templates]) do
    msgs = [CheckMessage(:error, "Template directory '$d' does not exist."; id = "templates.E001") for d in settings.TEMPLATE_DIRS if !isdir(d)]
    append!(msgs, [CheckMessage(:error, "$name: $msg"; id = id) for (id, name, msg) in template_issues()])
    msgs
end
register_check!(tags = [:settings]) do
    [CheckMessage(l, m; id = id, hint = h) for (l, m, id, h) in settings_issues()]
end
register_check!(() -> [CheckMessage(:error, m; id = "apps.E001") for m in app_issues()]; tags = [:apps])
register_check!(tags = [:models]) do
    msgs = CheckMessage[]
    for T in MODEL_LIST, f in modelmeta(T).fields
        f.kind === :fk || continue
        try
            related_model(f)
        catch e
            push!(msgs, CheckMessage(:error, "$(nameof(T)).$(f.name): $(sprint(showerror, e))"; id = "fields.E300"))
        end
    end
    msgs
end
# Two kinds of blank: a nullable text field holds both NULL and "" (Django has no such check;
# linters do). Unique fields are left out (there NULL is how several rows stay empty), and so are
# Juango's own models.
const TEXT_FIELD_KINDS = (:char, :text, :email, :slug, :url, :citext)
register_check!(tags = [:models]) do
    msgs = CheckMessage[]
    for T in MODEL_LIST
        pm = parentmodule(T)
        (pm === Juango || parentmodule(pm) === Juango) && continue
        for f in modelmeta(T).fields
            f.kind in TEXT_FIELD_KINDS && f.null && !f.unique || continue
            push!(msgs, CheckMessage(:warning, "$(nameof(T)).$(f.name): a text field with null = true has two empty values, NULL and \"\"."; id = "fields.W800",
                                     hint = "Leave out null = true (blank = true stores \"\"), unless the field is unique."))
        end
    end
    msgs
end
# migrations not applied yet that are unsafe for a running site (Migrations.lint_migration)
register_check!(tags = [:migrations]) do
    mode = get(SETTINGS, :MIGRATION_LINT, :warn)
    mode === false && return CheckMessage[]
    ws = try
        Migrations.lint_unapplied()
    catch e
        return CheckMessage[]                     # no database to compare with: nothing to say
    end
    [CheckMessage(mode === :error ? :error : :warning, "$(w.migration), operation $(w.op): $(w.msg)"; id = w.id, hint = w.hint) for w in ws]
end
register_check!(() -> [CheckMessage(:warning, m; id = "auth.W020") for m in user_model_swap_issues()]; tags = [:models])
register_check!(() -> [CheckMessage(l, m; id = id, hint = h) for (l, m, id, h) in auth_check_issues()]; tags = [:models])
register_check!(deploy_checks; tags = [:security], deploy = true)

"Print check messages as `manage.jl check` does (with how many were silenced); returns them."
function report_checks(msgs, silenced::Integer = 0; io = stdout)
    sil = " ($silenced silenced)"
    if isempty(msgs)
        println(io, "System check identified no issues", sil, ".")
    else
        println(io, "System check identified $(length(msgs)) issue$(length(msgs) == 1 ? "" : "s")", sil, ":")
        for lvl in (:critical, :error, :warning, :info, :debug), m in msgs
            m.level === lvl && println(io, "  ", uppercase(string(lvl)), ": ", m)
        end
    end
    msgs
end

"""
    diffsettings(; all = false, output = :hash, default = default_settings()) -> Vector{String}

The settings that differ from `default` (Juango's defaults), as Django's `diffsettings`: with
`output = :hash`, `NAME = value  ###` lines (`all = true` adds the others as `### NAME = value`); with
`:unified`, `- NAME = default` and `+ NAME = value` (`all`: the others as `  NAME = value`).
"""
function diffsettings(; all::Bool = false, output::Symbol = :hash, default = default_settings())
    output in (:hash, :unified) || throw(CommandError("argument --output: invalid choice: '$output' (choose from 'hash', 'unified')"))
    defaults = Dict{Symbol,Any}(Symbol(k) => v for (k, v) in pairs(default))
    lines = String[]
    for k in sort(collect(keys(Juango.SETTINGS)); by = string)
        v = Juango.SETTINGS[k]
        changed = !haskey(defaults, k) || !isequal(defaults[k], v)
        if output === :hash               # (Django's: "KEY = value  ###" when changed, "### KEY = value" with --all)
            changed ? push!(lines, string(k, " = ", repr(v), "  ###")) : all && push!(lines, string("### ", k, " = ", repr(v)))
        elseif changed                    # unified: the default as "- ", the setting as "+ "
            haskey(defaults, k) && push!(lines, string("- ", k, " = ", repr(defaults[k])))
            push!(lines, string("+ ", k, " = ", repr(v)))
        elseif all
            push!(lines, string("  ", k, " = ", repr(v)))
        end
    end
    lines
end

"""
    sendtestemail(recipients...; managers = false, admins = false) -> Int

Send a test message (Django's `sendtestemail`) to the addresses given, and/or to MANAGERS and ADMINS.
"""
function sendtestemail(recipients::AbstractString...; managers::Bool = false, admins::Bool = false)
    subject = "Test email from $(gethostname()) on $(Dates.format(now(), "yyyy-mm-dd HH:MM"))"
    body = "If you're reading this, it was successful."
    n = isempty(recipients) ? 0 : send_mail(subject, body, settings.DEFAULT_FROM_EMAIL, collect(String, recipients))
    managers && (n += mail_managers(subject, body))
    admins && (n += mail_admins(subject, body))
    n
end

"Where a static file is found: every match across STATICFILES_FINDERS, the one served first first."
findstatic(path::AbstractString) = String[p for f in static_finders() for p in find_static(f, path)]

"""
    remove_stale_contenttypes(; include_stale_apps = false, confirm = true) -> Vector{ContentType}

Delete content types whose model no longer exists (and, by cascade, their permissions and admin
log entries), for installed apps, or for every app with `include_stale_apps`. `confirm` is a
function given the stale content types (default: ask on a terminal); returning false keeps them.
"""
function remove_stale_contenttypes(; include_stale_apps::Bool = false, confirm = nothing, verbose = true)
    known = Set((modelmeta(T).app, lowercase(modelmeta(T).name)) for T in MODEL_LIST)
    apps = Set(modelmeta(T).app for T in MODEL_LIST)
    stale = [ct for ct in objects(ContentType) if !((ct.app_label, ct.model) in known) && (include_stale_apps || ct.app_label in apps)]
    isempty(stale) && (verbose && println("No stale content types."); return ContentType[])
    ok = confirm === nothing ? begin
        println("These content types are stale and will be deleted, with their permissions and log entries:")
        foreach(ct -> println("  - ", ct), stale)
        Migrations.ask("Delete them?")
    end : confirm(stale)
    ok || return ContentType[]
    foreach(delete!, stale)
    verbose && foreach(ct -> println("Deleted content type ", ct), stale)
    stale
end

# check [--deploy] [--tag TAG,...]: prints the problems and returns them (CheckMessages)
function cmd_check(args)
    _, flags = parse_flags(args)
    tags = haskey(flags, "tag") ? split(flags["tag"], ',') : nothing
    deploy = haskey(flags, "deploy")
    msgs = run_checks(; tags = tags, deploy = deploy)
    report_checks(msgs, length(run_checks(; tags = tags, deploy = deploy, include_silenced = true)) - length(msgs))
end

# migrate [app] [target] [--fake] [--sync] [--plan] [--check] [--prune] [--no-fake-initial] [--database NAME]
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
        # "migrate auth": everything pending for that app (and what it depends on)
        g = Migrations.build_graph()
        ks = [k for k in Migrations.topo_order(g) if k[1] == app]
        isempty(ks) && return println("App '$app' has no migrations.")
        target = last(ks)[2]
    end
    haskey(flags, "prune") && return migrate(; app = app, prune = true, database = get(flags, "database", nothing))
    haskey(flags, "plan") && return (migrate(; app = app, target = target, plan_only = true, database = get(flags, "database", nothing)); nothing)
    if haskey(flags, "check")                          # (as Django's: exit 1 when migrations are unapplied)
        migrate(; app = app, target = target, check = true, database = get(flags, "database", nothing)) || exit(1)
        return nothing
    end
    migrate(; app = app, target = target, fake = haskey(flags, "fake"), sync = haskey(flags, "sync"),
            fake_initial = !haskey(flags, "no-fake-initial"), database = get(flags, "database", nothing))
end

# makemigrations [app...] [--app NAME] [--name NAME] [--empty] [--merge] [--update] [--dry-run] [--check] [--noinput]
# Without an app: the project's models and every installed app that has a directory.
function cmd_makemigrations(args)
    pos, flags = parse_flags(args)
    apps = !isempty(pos) ? pos : haskey(flags, "app") ? [flags["app"]] :
           unique(vcat(["project"], [a.label for a in installed_apps() if a.path !== nothing]))
    q = haskey(flags, "noinput") || haskey(flags, "no-input") ? (_ -> false) : Migrations.ask
    kw = (name = get(flags, "name", nothing), empty = haskey(flags, "empty"), merge = haskey(flags, "merge"),
          dry_run = haskey(flags, "dry-run"), check = haskey(flags, "check"), update = haskey(flags, "update"), questioner = q)
    paths = length(apps) > 1 ? Migrations.makemigrations_apps(apps; kw...) : makemigrations(; app = only(apps), kw...)
    haskey(flags, "check") && !isempty(paths) && exit(1)
    paths
end

# dumpdata [app[.Model] ...] [--indent N] [--format json|jsonl|yaml|xml] [--exclude a,b] [--natural-foreign] [--natural-primary] [--output FILE] [--database DB]
function cmd_dumpdata(args)
    pos, flags = parse_flags(args)
    ind = get(flags, "indent", nothing)
    s = dumpdata(pos...; format = haskey(flags, "format") ? Symbol(flags["format"]) : haskey(flags, "output") ? fixture_format(flags["output"]) : :json, indent = ind === nothing ? nothing : parse(Int, ind),
                 exclude = haskey(flags, "exclude") ? split(flags["exclude"], ',') : String[],
                 natural_foreign = haskey(flags, "natural-foreign"), natural_primary = haskey(flags, "natural-primary"),
                 output = get(flags, "output", nothing), database = get(flags, "database", nothing))
    haskey(flags, "output") || print(cmd_stdout(), s)
end

# flush [--noinput]
function cmd_flush(args)
    _, flags = parse_flags(args)
    if !(haskey(flags, "noinput") || haskey(flags, "no-input"))
        println("This will delete ALL data in the database \"$(vendor(backend()))\" and return each table to an empty state.")
        lowercase(strip(prompt("Are you sure you want to do this? Type 'yes' to continue, or 'no' to cancel: "))) == "yes" ||
            return println("Flush cancelled.")
    end
    n = flush!()
    println("Emptied $n table(s).")
end

"""
    test_plan(args; root = ".") -> (files, flags, seed)

What `manage.jl test args...` runs, in order: the files given, else `test/runtests.jl`, else `tests/test*.jl`
(sorted), under `root`; those whose path contains a `-k` pattern; reversed with `--reverse`; shuffled with
`--shuffle[=SEED]` (`seed` is the one used, else `nothing`). `flags` has the other `--name[=value]` options.
"""
function test_plan(args; root::AbstractString = ".")
    files, patterns = String[], String[]
    flags = Dict{String,String}()
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "-k"
            i < length(args) || error("usage: test -k PATTERN")
            push!(patterns, args[i+1])
            i += 2
            continue
        elseif startswith(a, "--")
            k, v = occursin('=', a) ? split(a[3:end], '='; limit = 2) : (a[3:end], "true")
            flags[String(k)] = String(v)
        else
            push!(files, a)
        end
        i += 1
    end
    if isempty(files)
        tests = joinpath(root, "tests")
        files = if isfile(joinpath(root, "test", "runtests.jl"))
            [joinpath(root, "test", "runtests.jl")]
        else
            sort([joinpath(tests, f) for f in (isdir(tests) ? readdir(tests) : String[]) if startswith(f, "test") && endswith(f, ".jl")])
        end
    end
    isempty(patterns) || filter!(f -> any(p -> occursin(p, f), patterns), files)
    haskey(flags, "reverse") && reverse!(files)
    seed = nothing
    if haskey(flags, "shuffle")
        seed = flags["shuffle"] == "true" ? Int(rand(RandomDevice(), UInt16)) : parse(Int, flags["shuffle"])
        shuffle!(MersenneTwister(seed), files)
    end
    files, flags, seed
end

# test [--keepdb] [--failfast] [--reverse] [--shuffle[=SEED]] [-k PATTERN ...] [file ...]
"""
Run the project's tests (test/runtests.jl, or tests/test_*.jl, or the files given) against a
throwaway test database. Each file runs even when an earlier one fails, unless `--failfast`; the
command fails when any did. `-k PATTERN` (repeatable) keeps the files whose path contains a
pattern; `--reverse` and `--shuffle[=SEED]` change the order, to catch tests that depend on
others (the seed is printed, so a failing order can be repeated).
"""
function cmd_test(args)
    files, flags, seed = test_plan(args)
    isempty(files) && return println("No tests found (test/runtests.jl or tests/test_*.jl$(any(==("-k"), args) ? " matching -k" : "")).")
    seed === nothing || println("Shuffling the test files with seed $seed (--shuffle=$seed repeats this order)")
    # --coverage: run the tests again in a process that records coverage, then summarise it
    haskey(flags, "coverage") && return test_with_coverage(args)
    haskey(flags, "update-snapshots") && (ENV["JUANGO_UPDATE_SNAPSHOTS"] = "1")
    # a throwaway database, migrated, so the tests never touch the development one (--keepdb reuses it)
    db = setup_test_database(; keepdb = haskey(flags, "keepdb"), verbose = true)
    # and a throwaway MEDIA_ROOT, so uploads made by tests don't pile up in the project or /tmp
    media_before = get(SETTINGS, :MEDIA_ROOT, nothing)
    media = mktempdir(; cleanup = false)
    configure!(MEDIA_ROOT = media)
    failed = String[]
    try
        for f in files
            println("Running ", f)
            try
                Base.include(Main, abspath(f))
            catch e
                push!(failed, f)
                # a failing @testset has printed its report already; anything else gets its stack trace
                e isa LoadError && nameof(typeof(e.error)) === :TestSetException || showerror(stderr, e, catch_backtrace())
                if haskey(flags, "failfast")
                    println(stderr, "Stopping after the first failing file (--failfast).")
                    break
                end
            end
        end
    finally
        teardown_test_database(db; verbose = true)
        media_before === nothing ? delete!(SETTINGS, :MEDIA_ROOT) : configure!(MEDIA_ROOT = media_before)
        rm(media; recursive = true, force = true)
    end
    isempty(failed) || error("tests failed in: " * join(failed, ", "))
    nothing
end

"`test --coverage`: rerun `manage.jl test` with Julia's coverage on for the project's files, then print a summary."
function test_with_coverage(args)
    out = joinpath("coverage", "lcov.info")
    mkpath("coverage"); isfile(out) && rm(out)
    script = isempty(PROGRAM_FILE) ? "manage.jl" : PROGRAM_FILE
    rest = [a for a in args if a != "--coverage"]
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --code-coverage=@$(pwd()) --code-coverage=$out $script test $rest`
    ok = success(pipeline(cmd; stdout = stdout, stderr = stderr))
    isfile(out) ? print_coverage(out) : println("No coverage was recorded ($out is missing).")
    ok || error("tests failed")
    nothing
end

"Print lines covered per file from an LCOV tracefile (the project's own files, not tests or packages)."
function print_coverage(lcov::AbstractString; io = stdout, root = pwd())
    files = Dict{String,Tuple{Int,Int}}()
    cur = nothing
    for l in eachline(lcov)
        if startswith(l, "SF:")
            cur = relpath(l[4:end], root)
        elseif startswith(l, "DA:") && cur !== nothing
            _, hits = split(l[4:end], ',')
            h, n = get(files, cur, (0, 0))
            files[cur] = (h + (parse(Int, split(hits, ',')[1]) > 0), n + 1)
        end
    end
    filter!(p -> !startswith(p.first, "..") && !startswith(p.first, "test") && !occursin(".julia", p.first), files)
    isempty(files) && return println(io, "No project files were covered.")
    w = maximum(length, keys(files))
    th, tn = 0, 0
    for (f, (h, n)) in sort(collect(files); by = p -> p.second[1] / max(p.second[2], 1))
        println(io, rpad(f, w + 2), lpad(string(round(100h / max(n, 1); digits = 1)), 6), "%   ", h, "/", n, " lines")
        th += h; tn += n
    end
    println(io, rpad("TOTAL", w + 2), lpad(string(round(100th / max(tn, 1); digits = 1)), 6), "%   ", th, "/", tn, " lines")
    println(io, "(the full report is coverage/lcov.info: open it with an LCOV viewer, or `genhtml coverage/lcov.info -o coverage/html`)")
end

# loaddata fixture [fixture ...] [--database DB]
function cmd_loaddata(args)
    pos, flags = parse_flags(args)
    isempty(pos) && error("usage: loaddata <fixture> [fixture ...]")
    n, total, files = try
        loaddata_counts(pos...; database = get(flags, "database", nothing))
    catch e                                   # (a fixture that isn't there, or isn't a format: Django's CommandError)
        e isa ArgumentError ? throw(CommandError(e.msg)) : rethrow()
    end
    println(cmd_stdout(), n == total ? "Installed $n object(s) from $files fixture(s)" : "Installed $n object(s) (of $total) from $files fixture(s)")
end

# optimizemigration app name [--check]
function cmd_optimizemigration(args)
    pos, flags = parse_flags(args)
    length(pos) == 2 || error("usage: optimizemigration <app> <migration> [--check]")
    changed = optimizemigration(pos[1], pos[2]; check = haskey(flags, "check"))
    haskey(flags, "check") && changed && exit(1)
end

# squashmigrations app [start] stop [--name NAME] [--dry-run]
function cmd_squashmigrations(args)
    pos, flags = parse_flags(args)
    length(pos) in (2, 3) || error("usage: squashmigrations <app> [start] <stop> [--name NAME] [--dry-run]")
    app = pos[1]
    start, stop = length(pos) == 3 ? (pos[2], pos[3]) : (nothing, pos[2])
    squashmigrations(app, stop; start = start, name = get(flags, "name", nothing), dry_run = haskey(flags, "dry-run"))
end

# sqlmigrate [app] name [--backwards]
function cmd_sqlmigrate(args)
    pos, flags = parse_flags(args)
    isempty(pos) && error("usage: sqlmigrate [app] <migration> [--backwards]")
    app, name = length(pos) >= 2 ? (pos[1], pos[2]) : ("project", pos[1])
    println(sqlmigrate(app, name; backwards = haskey(flags, "backwards")))
end

"""
`help`: the commands, grouped by the app they come from (`[juango]`, then each installed app's), as Django's
`manage.py help`; `help --commands` lists the names alone, and `help <command>` gives that command's help.
"""
function cmd_help(args)
    io = cmd_stdout()
    if "--commands" in args
        foreach(k -> println(io, k), sort(collect(keys(all_commands()))))
        return nothing
    end
    if !isempty(args) && !startswith(args[1], "-")
        name = args[1]
        entry = get(all_commands(), name, nothing)
        entry === nothing && throw(CommandError(unknown_command_message(name)))
        decl = get(DECLARED_COMMANDS, name, nothing)
        decl !== nothing && COMMANDS[name] === entry && return print_command_help(decl)
        println(io, "usage: manage.jl ", name, "\n\n", entry[1])
        return nothing
    end
    println(io, "\nType 'manage.jl help <subcommand>' for help on a specific subcommand.\n\nAvailable subcommands:\n")
    println(io, "[juango]")
    for k in sort(collect(keys(COMMANDS)))
        println(io, "    ", rpad(k, 24), COMMANDS[k][1])
    end
    for a in installed_apps()
        isempty(a.commands) && continue
        println(io, "\n[", a.label, "]")
        for k in sort(collect(keys(a.commands)))
            println(io, "    ", rpad(k, 24), a.commands[k][1])
        end
    end
    nothing
end

"The options of a command for completion: (long name, takes a value), its own and the common ones."
function command_options(name)
    decl = get(DECLARED_COMMANDS, name, nothing)
    entry = get(all_commands(), name, nothing)
    args = decl !== nothing && entry !== nothing && COMMANDS[name] === entry ? vcat(decl.arguments, COMMON_ARGS) : COMMON_ARGS
    opts = [(minimum(a.names), a.action in (:store, :append)) for a in args if !a.positional]
    if decl === nothing && entry !== nothing     # (a command without declared arguments: the --options its help names)
        append!(opts, [(String(m.match), false) for m in eachmatch(r"--[a-z][a-z0-9-]*", entry[1])])
    end
    unique(first, opts)
end

"""
    autocomplete(comp_words, comp_cword; io = stdout)

Completions for bash (Django's ManagementUtility.autocomplete): the commands starting with the word
being typed, or that command's options (`=` after one that takes a value) and, for dumpdata,
sqlmigrate, sqlsequencereset and test, the app labels. `manage.jl` runs it when JUANGO_AUTO_COMPLETE
(or DJANGO_AUTO_COMPLETE) is set, with bash's COMP_WORDS and COMP_CWORD:

    _manage_jl() { COMPREPLY=( \$(COMP_WORDS="\${COMP_WORDS[*]}" COMP_CWORD=\$COMP_CWORD JUANGO_AUTO_COMPLETE=1 julia --project manage.jl 2>/dev/null) ); }
    complete -F _manage_jl -o default manage.jl
"""
function autocomplete(comp_words::AbstractString, comp_cword::Integer; io::IO = cmd_stdout())
    cwords = split(comp_words)[2:end]
    curr = 1 <= comp_cword <= length(cwords) ? cwords[comp_cword] : ""
    subcommands = unique(vcat(collect(keys(all_commands())), ["help"]))
    if comp_cword == 1
        println(io, join(sort(filter(x -> startswith(x, curr), subcommands)), " "))
    elseif !isempty(cwords) && cwords[1] in subcommands && cwords[1] != "help"
        options = Tuple{String,Bool}[("--help", false)]
        cwords[1] in ("dumpdata", "sqlmigrate", "sqlsequencereset", "test") && append!(options, [(a.label, false) for a in installed_apps()])
        append!(options, command_options(cwords[1]))
        prev = Set(first(split(x, '=')) for x in cwords[2:min(comp_cword - 1, length(cwords))])
        for (k, v) in sort([o for o in options if !(o[1] in prev) && startswith(o[1], curr)])
            println(io, v ? k * "=" : k)
        end
    end
    nothing
end

"Python's difflib.get_close_matches: the candidates at least `cutoff` similar to `word`, most similar first."
close_matches(word, candidates; n = 3, cutoff = 0.6) =
    first([c for (r, c) in sort([(similarity(word, c), c) for c in candidates]; by = first, rev = true) if r >= cutoff], n)
"Django's message for an unknown command, with the closest one if there is one."
function unknown_command_message(name)
    m = close_matches(name, collect(keys(all_commands())))
    "Unknown command: '$name'." * (isempty(m) ? "" : " Did you mean $(m[1])?") * "\nType 'manage.jl help' for usage."
end


for (n, h, f) in (
    ("runserver", "Start the development server: runserver [host:]port [--cert cert.pem --key key.pem] [--noreload]", cmd_runserver),
    ("migrate", "Apply migrations: migrate [app] [target|zero] [--plan] [--check] [--fake] [--no-fake-initial] [--sync] [--prune] [--database ALIAS]", cmd_migrate),
    ("sqlflush", "Print the SQL that flush would run", _ -> foreach(s -> println(s, ";"), flush_sql())),
    ("sqlsequencereset", "Print the SQL that moves id sequences past the existing rows: sqlsequencereset <app> ...",
     args -> foreach(s -> println(s, ";"), sequence_reset_sql(isempty(args) ? nothing : String.(args)))),
    ("optimizemigration", "Rewrite a migration with fewer operations: optimizemigration <app> <migration> [--check]", cmd_optimizemigration),
    ("makemigrations", "Write migrations for model changes (--name, --empty, --merge, --update, --dry-run, --check, --noinput, --app)", cmd_makemigrations),
    ("showmigrations", "List migrations and whether they are applied: showmigrations [app...] [--plan]",
     function (args)
         pos, flags = parse_flags(args)
         showmigrations(pos...; plan = haskey(flags, "plan"))
         nothing
     end),
    ("swap_user_model", "Move the users to a new user model before switching AUTH_USER_MODEL: swap_user_model <app.Model> [--dry-run]",
     function (args)
         pos, flags = parse_flags(args)
         length(pos) == 1 || error("usage: swap_user_model <app.Model> [--dry-run]")
         swap_user_model(pos[1]; dry_run = haskey(flags, "dry-run"))
         nothing
     end),
    ("deploy", "Run the deploy tasks this database hasn't run: deploy [--plan] [--fake]",
     function (args)
         _, flags = parse_flags(args)
         r = run_deploy_tasks(; plan = haskey(flags, "plan"), fake = haskey(flags, "fake"))
         isempty(r.waiting) || println("$(length(r.waiting)) deploy task(s) waiting; they'll be tried again next time.")
     end),
    ("sqlmigrate", "Print the SQL for a migration: sqlmigrate [app] <name> [--backwards]", cmd_sqlmigrate),
    ("db_worker", "Run background tasks of the database backend: db_worker [--queue a,b] [--max-tasks N] [--stop-when-empty]",
     function (args)
         _, flags = parse_flags(args)
         n = db_worker(; queues = haskey(flags, "queue") ? split(flags["queue"], ',') : nothing,
                       max_tasks = haskey(flags, "max-tasks") ? parse(Int, flags["max-tasks"]) : nothing,
                       stop_when_empty = haskey(flags, "stop-when-empty"))
         println("Ran $n task(s).")
     end),
    ("flush", "Delete all data from the database: flush [--noinput]", cmd_flush),
    ("dbshell", "Open the database's command-line client: dbshell [-- parameters for the client]",
     args -> dbshell(String[a for a in (!isempty(args) && first(args) == "--" ? args[2:end] : args)])),
    ("inspectdb", "Write models for existing tables: inspectdb [table ...]", args -> print(inspectdb(isempty(first(parse_flags(args))) ? nothing : first(parse_flags(args))))),
    ("test", "Run the project's tests against a throwaway test database: test [--keepdb] [--failfast] [--reverse] [--shuffle[=SEED]] [-k PATTERN] [file ...]", cmd_test),
    ("dumpdata", "Write the database's objects as a fixture: dumpdata [app[.Model] ...] [--format json|jsonl|yaml|xml] [--indent N] [--output FILE] [--database DB]", cmd_dumpdata),
    ("loaddata", "Load fixtures: loaddata <name or file> ... [--database DB]", cmd_loaddata),
    ("squashmigrations", "Combine migrations into one: squashmigrations <app> [start] <stop> [--name NAME]", cmd_squashmigrations),
    ("createsuperuser", "Create an admin user (--username, --email, --password, --noinput)", cmd_createsuperuser),
    ("showurls", "List all URL patterns", cmd_showurls),
    ("startapp", "Create an app skeleton: startapp <name> [directory] [--dir DIR]", function (args)
        pos, flags = parse_flags(args)
        isempty(pos) && throw(CommandError("usage: startapp <name> [directory]"))
        startapp(pos[1], get(pos, 2, nothing); dir = get(flags, "dir", pwd()))
    end),
    ("collectstatic", "Copy static files from STATIC_DIRS and apps into STATIC_ROOT (--clear)",
     args -> println(collectstatic(; clear = haskey(last(parse_flags(args)), "clear")), " static files copied to ", settings.STATIC_ROOT)),
    ("convert_naive_datetimes", "Rewrite stored naive datetimes as UTC when turning USE_TZ on: convert_naive_datetimes [--from Europe/Berlin]",
     args -> (f = last(parse_flags(args)); println("Converted ", convert_naive_datetimes(; from_tz = get(f, "from", settings.TIME_ZONE)), " columns."))),
    ("makemessages", "Collect translatable strings: makemessages -l de [-l fr] | -a [-x de] [-e html,txt] [-i pattern] [--no-location | --add-location=file] [--no-obsolete] [--no-default-ignore]",
     function (args)
        o = i18n_command_options(args)
        isempty(o.locale) && !o.all && error("usage: makemessages -l <locale> (or -a for all of them)")
        for p in makemessages(o.locale; all = o.all, exclude = o.exclude, extensions = isempty(o.extension) ? nothing : o.extension,
                              ignore = o.ignore, no_default_ignore = o.flag("no-default-ignore"), no_obsolete = o.flag("no-obsolete"),
                              no_location = o.flag("no-location"), add_location = something(o.value("add-location"), "full"))
            println("processing locale ", basename(dirname(dirname(p))), ": ", p)
        end
    end),
    ("compilemessages", "Compile .po translation files into .mo: compilemessages [-l de] [-x fr] [-f/--use-fuzzy] [-i pattern]",
     function (args)
        o = i18n_command_options(args)
        foreach(p -> println("compiled ", p), compilemessages(; locale = isempty(o.locale) ? nothing : o.locale, exclude = o.exclude,
                                                             use_fuzzy = o.flag("use-fuzzy") || o.flag("f"), ignore = o.ignore, verbose = true))
    end),
    ("createcachetable", "Create the table for database caches (CACHES backend :db)", _ -> foreach(create_cache_table, keys(settings.CACHES))),
    ("sqlschema", "Print the SQL schema for all models", _ -> println(schema_sql())),
    ("check", "Run the system checks: check [--deploy] [--tag security,models]", cmd_check),
    ("build", "Build a system image that starts fast: build [--output PATH] [--workload urls|tests|none] [--app] [--cpu-target native|generic;...] [--dry-run]", function (args)
        _, f = parse_flags(args)
        r = build(; output = get(f, "output", nothing), workload = Symbol(get(f, "workload", "urls")), dry_run = haskey(f, "dry-run"),
                  app = haskey(f, "app"), cpu_target = get(f, "cpu-target", nothing))
        haskey(f, "dry-run") && println("JULIA_LOAD_PATH='@:$BUILD_ENV:@stdlib' ", Base.shell_escape(r.exec...))
        r
    end),
    ("diffsettings", "Show the settings that differ from the defaults: diffsettings [--all] [--output hash|unified]",
     function (args)
        _, f = parse_flags(args)
        foreach(l -> println(cmd_stdout(), l), diffsettings(; all = haskey(f, "all"), output = Symbol(get(f, "output", "hash"))))
    end),
    ("sendtestemail", "Send a test email: sendtestemail [address ...] [--managers] [--admins]", function (args)
        pos, f = parse_flags(args)
        n = sendtestemail(pos...; managers = haskey(f, "managers"), admins = haskey(f, "admins"))
        println(n, " message", n == 1 ? "" : "s", " sent.")
    end),
    ("findstatic", "Where static files are found: findstatic <path> ...", function (args)
        for p in first(parse_flags(args))
            found = findstatic(p)
            isempty(found) ? println("No matching file found for '$p'.") : (println("Found '$p' here:"); foreach(x -> println("  ", x), found))
        end
    end),
    ("remove_stale_contenttypes", "Delete content types of models that no longer exist: remove_stale_contenttypes [--include-stale-apps] [--noinput]",
     function (args)
        _, f = parse_flags(args)
        remove_stale_contenttypes(; include_stale_apps = haskey(f, "include-stale-apps"),
                                  confirm = haskey(f, "noinput") || haskey(f, "no-input") ? (_ -> true) : nothing)
    end),
    ("clearsessions", "Delete expired sessions", _ -> println("Deleted ", clear_expired_sessions!(), " expired sessions.")),
    ("changepassword", "Change a user's password: changepassword [username] (default: the system user)", cmd_changepassword),
    ("help", "Show this message", cmd_help))
    COMMANDS[n] = (h, f)
end
# commands that belong to an optional built-in app (gone when it isn't installed)
for (n, app) in (("createsuperuser", AUTH_APP), ("changepassword", AUTH_APP), ("clearsessions", SESSIONS_APP),
                 ("remove_stale_contenttypes", CONTENTTYPES_APP))
    app.commands[n] = pop!(COMMANDS, n)
end

"""
    execute_from_command_line(args=ARGS)

Entry point used by a project's `manage.jl`.
"""
function execute_from_command_line(args = ARGS)
    if haskey(ENV, "JUANGO_AUTO_COMPLETE") || haskey(ENV, "DJANGO_AUTO_COMPLETE")     # (bash completion: see autocomplete)
        autocomplete(get(ENV, "COMP_WORDS", ""), something(tryparse(Int, get(ENV, "COMP_CWORD", "0")), 0))
        isinteractive() || exit(0)
        return nothing
    end
    if isempty(args)
        isinteractive() && return nothing
        return cmd_help(args)
    end
    cmd = args[1]
    cmd in ("--version", "version") && (println(cmd_stdout(), pkgversion(@__MODULE__)); return nothing)
    cmd in ("--help", "-h") && return cmd_help(args[2:end])
    entry = get(all_commands(), cmd, nothing)
    if entry === nothing
        println(cmd_stderr(), unknown_command_message(cmd))
        isinteractive() || exit(1)
        return nothing
    end
    try
        entry[2](args[2:end])
    catch e
        e isa CommandError || rethrow()
        println(stderr, "CommandError: ", e.msg)          # (as Django's: the message and its exit status, 1 by default)
        isinteractive() || exit(e.returncode)
        nothing
    end
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

        # `runserver` reloads your code when it changes, with Revise.jl installed in your global
        # environment (`julia -e 'using Pkg; Pkg.add("Revise")'`); --noreload turns it off.
        if "runserver" in ARGS && !("--noreload" in ARGS)
            try
                @eval using Revise
            catch
                @info "Install Revise.jl (in your global environment) and runserver reloads code when it changes."
            end
        end
        include(joinpath(@__DIR__, "project.jl"))
        Juango.execute_from_command_line(ARGS)
        """,
        "project.jl" => """
        # Loads the whole project (settings, models, views, urls).
        using Juango
        using Dates

        const BASE_DIR = @__DIR__

        # project_include: tracked by Revise for runserver's reloading when Revise is loaded
        Juango.project_include(joinpath(BASE_DIR, "models.jl"))
        Juango.project_include(joinpath(BASE_DIR, "admin.jl"))
        Juango.project_include(joinpath(BASE_DIR, "views.jl"))
        Juango.project_include(joinpath(BASE_DIR, "urls.jl"))
        Juango.project_include(joinpath(BASE_DIR, "settings.jl"))
        # after a reload, apply the settings again (they hold `urlpatterns`, which urls.jl may have rebuilt)
        Juango.on_reload!(() -> Base.include(@__MODULE__, joinpath(BASE_DIR, "settings.jl")))
        """,
        "settings.jl" => """
        # Settings, with what changes between deployments read from the environment or a .env file
        # (kept out of version control): DEBUG=false, SECRET_KEY=..., DATABASE_URL=postgresql://...
        using Juango.Environ
        read_env(joinpath(BASE_DIR, ".env"))

        configure!(
            DEBUG = env("DEBUG", Bool; default = true),
            SECRET_KEY = env("SECRET_KEY"; default = "$secret"),
            ALLOWED_HOSTS = env("ALLOWED_HOSTS", Vector{String}; default = ["localhost", "127.0.0.1"]),
            # DATABASE_URL=postgresql://user:password@localhost:5432/$name (or mysql://, sqlite:////path)
            DATABASE = env_db(; default = "sqlite:///" * joinpath(BASE_DIR, "db.sqlite3")),
            # Your apps (`julia --project manage.jl startapp blog`) go here too, e.g. Blog.APP
            INSTALLED_APPS = ["juango.admin", "juango.auth", "juango.contenttypes", "juango.sessions", "juango.messages"],
            MIGRATIONS_DIR = joinpath(BASE_DIR, "migrations"),
            ROOT_URLCONF = urlpatterns,
            TEMPLATE_DIRS = [joinpath(BASE_DIR, "templates")],
            STATIC_DIRS = [joinpath(BASE_DIR, "static")],
            MEDIA_ROOT = joinpath(BASE_DIR, "media"),     # uploaded files (FileField/ImageField)
            USE_TZ = true,                                # aware datetimes, stored in UTC
            TIME_ZONE = "UTC",
            SITE_NAME = "$name",
            INDEX_NAMES = :django,                        # unnamed Meta indexes named as Django names them
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
        ".gitignore" => "db.sqlite3*\nManifest.toml\n.env\nbuild/\n",
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

# --- startapp ----------------------------------------------------------------------------------------

"The module name of an app (`blog_posts` → `BlogPosts`)."
app_module_name(name) = join(uppercasefirst.(split(name, '_'; keepempty = false)))
"Whether a module of that name exists already (a package of the environment, a standard library, Base's own)."
existing_module(M) = !isempty(M) && (Base.identify_package(M) !== nothing || isdefined(Base, Symbol(M)) || isdefined(Core, Symbol(M)))
const JULIA_KEYWORDS = Set(["baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif", "end", "export",
                             "false", "finally", "for", "function", "global", "if", "import", "let", "local", "macro", "module",
                             "quote", "return", "struct", "true", "try", "using", "while"])
valid_app_identifier(s) = Base.isidentifier(s) && !(s in JULIA_KEYWORDS)

"""
    startapp(name, target = nothing; dir = pwd()) -> path

Create an app skeleton in `dir/name` (or in `target`, a directory made if it doesn't exist): a module
`Name` (in `Name.jl`) with `const APP`, models, admin, views and URLs, and `templates/name/`,
`static/name/` and `migrations/`. As Django's, the name must be an identifier whose module (`Name`)
isn't one that exists already (an app `dates` would hide the standard library's `Dates`), and an
existing target directory gets the files unless one is there already.
"""
function startapp(name::AbstractString, target = nothing; dir = pwd())
    valid_app_identifier(name) || throw(CommandError("'$name' is not a valid app name. Please make sure the name is a valid identifier."))
    M = app_module_name(name)
    existing_module(M) && throw(CommandError("'$name' conflicts with the name of an existing Julia module ($M) and cannot be used as an app name. Please try another name."))
    if target === nothing
        root = joinpath(dir, name)
        ispath(root) && throw(CommandError("'$root' already exists"))
    else
        root = abspath(joinpath(dir, target))
        base = basename(rstrip(target, ['/', '\\']))
        valid_app_identifier(base) || throw(CommandError("'$target' is not a valid app directory. Please make sure the directory is a valid identifier."))
        existing_module(app_module_name(base)) &&
            throw(CommandError("'$base' conflicts with the name of an existing Julia module and cannot be used as an app directory. Please try another directory."))
        try
            mkpath(root)
        catch e
            throw(CommandError(sprint(showerror, e)))
        end
    end
    files = Dict(
        "$M.jl" => """
        # The $name app. To install it, in project.jl:
        #     include(joinpath(BASE_DIR, "$name", "$M.jl")); using .$M
        # then add $M.APP to INSTALLED_APPS and route to it with
        #     path("$name/", include_urls($M.APP))
        module $M

        using Juango
        using Dates

        const APP = App("$name"; mod = @__MODULE__, path = @__DIR__, urls = () -> urlpatterns)

        include("models.jl")
        include("admin.jl")
        include("views.jl")
        include("urls.jl")

        end
        """,
        "models.jl" => """
        # Models here get the label "$name" (e.g. $name.Item); their migrations go in migrations/:
        #     julia --project manage.jl makemigrations $name
        #
        # @model struct Item
        #     name = CharField(max_length = 100)
        # end
        """,
        "admin.jl" => "# Admin.register!(Item; list_display = [:name])\n",
        "views.jl" => """
        index(req) = render(req, "$name/index.html", Dict("app" => APP))
        """,
        "urls.jl" => """
        const urlpatterns = [
            path("", index; name = "index"),        # {% url '$name:index' %}
        ]
        """,
        "templates/$name/index.html" => """
        <h1>{{ app.verbose_name }}</h1>
        <p>This page is <code>$name/templates/$name/index.html</code>.</p>
        """,
        "static/$name/.gitkeep" => "",
        "migrations/.gitkeep" => "",
        "tests.jl" => """
        using Test
        @testset "$name" begin
            @test get(Client(), reverse_url("$name:index")).status == 200
        end
        """,
    )
    for (rel, content) in files
        p = joinpath(root, rel)
        ispath(p) && throw(CommandError("$p already exists. Overlaying an app into an existing directory won't replace conflicting files."))
    end
    for (rel, content) in files
        p = joinpath(root, rel)
        try
            mkpath(dirname(p))
            write(p, content)
        catch e
            throw(CommandError(sprint(showerror, e)))
        end
    end
    println(cmd_stdout(), """Created app '$name' in $root

    Install it: include("$name/$M.jl") and `using .$M` in project.jl, add $M.APP to INSTALLED_APPS,
    and add path("$name/", include_urls($M.APP)) to urlpatterns.
    """)
    root
end

"""
    collectstatic(; clear=false) -> Int

Copy every static file (STATIC_DIRS first, then each installed app's `static/`; the first
file found for a path wins) into STATIC_ROOT, for a web server to serve in production.
"""
function collectstatic(; clear = false, verbose = false)
    root = string(settings.STATIC_ROOT)
    isempty(root) && throw(ImproperlyConfigured("set STATIC_ROOT to the directory collectstatic should copy files to"))
    clear && isdir(root) && foreach(p -> rm(joinpath(root, p); recursive = true), readdir(root))
    seen = Set{String}()
    for finder in static_finders(), (rel, src) in list_static(finder)   # the first finder with a path wins
        rel in seen && continue
        push!(seen, rel)
        dst = joinpath(root, rel)
        mkpath(dirname(dst))
        cp(src, dst; force = true)
        verbose && println("  ", rel)
    end
    if manifest_storage()
        try
            post_process_manifest!(root, [replace(r, '\\' => '/') for r in seen])
        catch e
            # (as Django's collectstatic: which files, then the error as the command's)
            e isa PostProcessError || e isa MissingStaticReference || rethrow()
            println(cmd_stderr(), "Post-processing '", e isa PostProcessError ? e.paths : e.name, "' failed!\n")
            throw(CommandError(e.msg))
        end
    end
    get(SETTINGS, :STATIC_COMPRESS, true) === true && compress_static!(root)      # .gz copies for SERVE_STATIC (or nginx gzip_static)
    length(seen)
end
