# More of Django's system checks (django/core/checks): translation settings, caches, URL settings and
# patterns, and the CSP settings' type. `manage.jl check` runs them; each keeps Django's id.

# --- translation (translation.E001-E004) ------------------------------------------------------------------
const LANGUAGE_CODE_RE = r"^[a-z]{1,8}(?:-[a-z0-9]{1,8})*(?:@[a-z0-9]{1,20})?$"i
valid_language_code(x) = x isa AbstractString && occursin(LANGUAGE_CODE_RE, x)
function translation_check_issues()
    s = settings
    out = CheckMessage[]
    e(id, msg) = push!(out, CheckMessage(:error, msg; id = id))
    lc = s.LANGUAGE_CODE
    valid_language_code(lc) || e("translation.E001", "You have provided an invalid value for the LANGUAGE_CODE setting: $(repr(lc)).")
    for item in s.LANGUAGES
        tag = item isa Union{Tuple,AbstractVector} && !isempty(item) ? first(item) : item
        valid_language_code(tag) || e("translation.E002", "You have provided an invalid language code in the LANGUAGES setting: $(repr(tag)).")
    end
    for tag in s.LANGUAGES_BIDI
        valid_language_code(tag) || e("translation.E003", "You have provided an invalid language code in the LANGUAGES_BIDI setting: $(repr(tag)).")
    end
    if valid_language_code(lc) && supported_variant_or_nothing(lc) === nothing
        e("translation.E004", "You have provided a value for the LANGUAGE_CODE setting that is not in the LANGUAGES setting.")
    end
    out
end
register_check!(translation_check_issues; tags = [:translation])

# --- caches (caches.E001, W002, W003) ---------------------------------------------------------------------
function cache_check_issues()
    s = settings
    out = CheckMessage[]
    caches = s.CACHES
    haskey(caches, "default") ||
        push!(out, CheckMessage(:error, "You must define a 'default' cache in your CACHES setting."; id = "caches.E001"))
    roots = Tuple{String,String}[]
    for name in (:MEDIA_ROOT, :STATIC_ROOT)
        v = string(something(get(s, name, ""), ""))
        isempty(v) || push!(roots, (string(name), abspath(v)))
    end
    for d in something(get(s, :STATICFILES_DIRS, String[]), String[])
        d = d isa Union{Tuple,Pair} ? last(d) : d
        push!(roots, ("STATICFILES_DIRS", abspath(string(d))))
    end
    within(a, b) = a == b || startswith(a, rstrip(b, '/') * "/")
    for (alias, c) in caches
        get(c, :backend, :locmem) === :file || continue
        loc = get(c, :location, nothing)
        loc === nothing && continue
        loc = string(loc)
        isabspath(loc) ||
            push!(out, CheckMessage(:warning, "Your '$alias' cache LOCATION path is relative. Use an absolute path instead."; id = "caches.W003"))
        p = abspath(loc)
        for (name, r) in roots
            rel = p == r ? "matches" : within(p, r) ? "is inside" : within(r, p) ? "contains" : nothing
            rel === nothing && continue
            push!(out, CheckMessage(:warning, "Your '$alias' cache configuration might expose your cache or lead to corruption of your data because its LOCATION $rel $name."; id = "caches.W002"))
        end
    end
    out
end
register_check!(cache_check_issues; tags = [:caches])

# --- URLs (urls.E004, E006, W001, W002, W003, W005) -------------------------------------------------------
describe_pattern(p) = "'" * p.route * "'" * (p isa URLPattern && p.name !== nothing ? " [name='$(p.name)']" : "")
"""
The URL checks of Django's resolvers: a route starting with '/' (W002, with APPEND_SLASH), an include's
route ending with '\$' (W001), a name with ':' (W003), an instance namespace used twice (W005) and an
entry that isn't a pattern (E004).
"""
function url_check_issues(patterns = settings.ROOT_URLCONF)
    out = CheckMessage[]
    namespaces = Dict{String,Int}()
    walk(ps, prefix_ns) = for p in ps
        if p isa URLPattern || p isa URLResolver
            r = p.route
            if get(settings, :APPEND_SLASH, true) && (startswith(r, "/") || startswith(r, "^/") || startswith(r, "^\\/")) && !endswith(r, "/")
                push!(out, CheckMessage(:warning, "Your URL pattern $(describe_pattern(p)) has a route beginning with a '/'. Remove this slash as it is unnecessary. If this pattern is targeted in an include(), ensure the include() pattern has a trailing '/'."; id = "urls.W002"))
            end
            if p isa URLPattern
                p.name !== nothing && occursin(':', p.name) &&
                    push!(out, CheckMessage(:warning, "Your URL pattern $(describe_pattern(p)) has a name including a ':'. Remove the colon, to avoid ambiguous namespace references."; id = "urls.W003"))
            else
                endswith(r, "\$") && !endswith(r, "\\\$") &&
                    push!(out, CheckMessage(:warning, "Your URL pattern $(describe_pattern(p)) uses include with a route ending with a '\$'. Remove the dollar from the route to avoid problems including URLs."; id = "urls.W001"))
                ns = p.namespace === nothing ? prefix_ns : (prefix_ns === nothing ? "" : prefix_ns * ":") * p.namespace
                if p.namespace !== nothing
                    key = (p.app_name === nothing ? "" : p.app_name * ":") * ns
                    namespaces[key] = get(namespaces, key, 0) + 1
                end
                walk(p.patterns, ns)
            end
        elseif p isa LocalePrefix
            walk(p.patterns, prefix_ns)
        elseif p isa AbstractVector
            walk(p, prefix_ns)
        else
            push!(out, CheckMessage(:error, "Your URL pattern $(repr(p)) is invalid. Ensure that urlpatterns is a list of path() and/or re_path() instances."; id = "urls.E004"))
        end
    end
    patterns isa AbstractVector ? walk(patterns, nothing) :
        push!(out, CheckMessage(:error, "The URLconf ROOT_URLCONF must be a list of URL patterns, not $(typeof(patterns))."; id = "urls.E004"))
    for (key, n) in sort!(collect(namespaces); by = first)
        n > 1 && push!(out, CheckMessage(:warning, "URL namespace '$key' isn't unique. You may not be able to reverse all URLs in this namespace"; id = "urls.W005"))
    end
    for name in (:STATIC_URL, :MEDIA_URL)
        v = get(settings, name, nothing)
        v isa AbstractString && !isempty(v) && !endswith(v, "/") &&
            push!(out, CheckMessage(:error, "The $name setting must end with a slash."; id = "urls.E006"))
    end
    out
end
register_check!(url_check_issues; tags = [:urls])

# --- the CSP settings (security.E026) ------------------------------------------------------------------------
register_check!(tags = [:security]) do
    [CheckMessage(:error, "The Content Security Policy setting '$name' must be a dictionary (got $(repr(v)) instead)."; id = "security.E026")
     for name in (:SECURE_CSP, :SECURE_CSP_REPORT_ONLY) for v in (get(settings, name, nothing),) if v !== nothing && !(v isa AbstractDict)]
end

# --- the check command (Django's: --tag, --list-tags, --deploy, --fail-level) ---------------------------------
const CHECK_LEVELS = Dict(:debug => 10, :info => 20, :warning => 30, :error => 40, :critical => 50)
"The tags of the registered checks (the deployment ones too with `deploy = true`), as Django's tags_available."
tags_available(; deploy::Bool = false) = Set{Symbol}(t for (_, ts, dep) in CHECKS if deploy || !dep for t in ts)

register_command!("check"; help = "Checks the entire Juango project for potential problems.", requires_system_checks = [],
                  arguments = [arg("-t", "--tag"; action = :append, dest = :tags, help = "Run only checks labeled with given tag."),
                               arg("--list-tags"; action = :store_true, help = "List available tags."),
                               arg("--deploy"; action = :store_true, help = "Check deployment settings."),
                               arg("--fail-level"; default = "ERROR", choices = ["CRITICAL", "ERROR", "WARNING", "INFO", "DEBUG"],
                                   help = "Message level that will cause the command to exit with a non-zero status. Default is ERROR."),
                               arg("--database"; action = :append, dest = :databases, choices = database_aliases, help = "Run database related checks against these aliases.")]) do opts
    if opts.list_tags
        println(cmd_stdout(), join(sort!(string.(collect(tags_available(; deploy = opts.deploy)))), "\n"))
        return CheckMessage[]
    end
    tags = opts.tags === nothing ? nothing : Symbol[Symbol(strip(t)) for x in opts.tags for t in split(string(x), ',') if !isempty(strip(t))]
    if tags !== nothing
        avail = tags_available(; deploy = opts.deploy)
        bad = findfirst(t -> !(t in avail), tags)
        bad === nothing || throw(CommandError("There is no system check with the '$(tags[bad])' tag."))
    end
    msgs = run_checks(; tags = tags, deploy = opts.deploy)
    silenced = length(run_checks(; tags = tags, deploy = opts.deploy, include_silenced = true)) - length(msgs)
    fail = CHECK_LEVELS[Symbol(lowercase(opts.fail_level))]
    if any(m -> get(CHECK_LEVELS, m.level, 30) >= fail, msgs)
        # (as Django's SystemCheckError: the report as the command's error, exit status 1)
        throw(CommandError("SystemCheckError: " * rstrip(sprint(io -> report_checks(msgs, silenced; io = io)))))
    end
    report_checks(msgs, silenced; io = cmd_stdout())
end
