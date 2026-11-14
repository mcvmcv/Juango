# The DEBUG error page ----------------------------------------------------------------------------
#
# With DEBUG on, an exception in a view shows this page, as Django's technical 500 page:
#
# - the exception and its chain (`rethrow` inside a `catch` keeps the earlier exceptions:
#   "while handling the exception above"),
# - the stack, innermost frame first as Julia prints it, each frame with its signature (argument
#   types) and the source around the line. Frames of your code are open, Juango's are dimmed, and
#   Base's, the standard library's and packages' are collapsed,
# - for a template error, the template, the line and the source around it,
# - the request, the settings (secrets masked), and the whole report as text to copy into an
#   issue. The same text is what `mail_admins` sends for a 500 when DEBUG is off.
#
# The page is built from strings only (no templates, no queries), so it works whatever failed.
# Julia's backtraces don't keep local variables, so unlike Django there are none.

const HIDDEN_SETTINGS = r"API|TOKEN|KEY|SECRET|PASS|SIGNATURE|HTTP_COOKIE"i
const CLEANSED = "********************"

"A setting's value for the report: masked when its name looks secret, with passwords inside URLs masked too."
function cleanse_setting(key, @nospecialize(v))
    occursin(HIDDEN_SETTINGS, string(key)) && return CLEANSED
    v isa AbstractDict && return Dict(string(k) => cleanse_setting(k, x) for (k, x) in v)
    v isa AbstractVector && eltype(v) <: Union{AbstractDict,AbstractString} && return [cleanse_setting("", x) for x in v]
    v isa AbstractString && return replace(v, r"(://[^:/@\s]*:)[^@/\s]*@" => s"\1********@")
    v
end

"`(exception, backtrace)` pairs, outermost (the one that reached the handler) last, as `current_exceptions()`."
function exception_chain(@nospecialize(e), bt)
    stack = try
        Base.current_exceptions()
    catch
        nothing
    end
    if stack !== nothing && !isempty(stack) && stack[end].exception === e
        return [(s.exception, s.backtrace) for s in stack]
    end
    [(e, bt)]
end

"What kind of code a frame is: `:user`, `:juango` or `:library` (Base, the standard library, packages, C)."
function frame_kind(f::Base.StackTraces.StackFrame)
    f.from_c && return :library
    file = string(f.file)
    within(JUANGO_SRC, file) && return :juango
    (startswith(file, "./") || startswith(file, "/cache/build/") || occursin("/share/julia/", file) ||
     occursin("/packages/", file) || file == "none" || startswith(file, "REPL[")) && return :library
    :user
end

"The path of a frame's source file to read (Base's files are given relative to its source tree)."
function frame_source_path(f::Base.StackTraces.StackFrame)
    file = string(f.file)
    startswith(file, "./") || return isfile(file) ? file : nothing
    p = Base.find_source_file(file)
    p !== nothing && isfile(p) ? p : nothing
end

"`(first line number, lines)` around `line` in `path` (`n` lines each side), or `nothing`."
function source_context(path, line::Integer, cache::Dict{String,Vector{String}}; n = 5)
    (path === nothing || line <= 0) && return nothing
    lines = get!(cache, path) do
        try
            readlines(path)
        catch
            String[]
        end
    end
    line > length(lines) && return nothing
    lo, hi = max(1, line - n), min(length(lines), line + n)
    lo, lines[lo:hi]
end

"""
A frame's call as `name(arg::Type, ...)`. A closure (a view defined in a function, a middleware's
inner function) prints as `(::var"#name##0"{...huge type...})(req::Request)`: it's shown by its
name, and closure types inside the arguments lose their type parameters.
"""
function frame_signature(f::Base.StackTraces.StackFrame)
    s = sprint(Base.StackTraces.show_spec_linfo, f)
    s = strip_closure_params(s)
    if startswith(s, "(::")
        depth, close = 0, 0
        for (i, c) in pairs(s)
            c == '(' && (depth += 1)
            c == ')' && (depth -= 1; depth == 0 && (close = i; break))
        end
        if close > 0
            m = match(r"#([^#\"{}]+)", SubString(s, 1, close))
            s = (m === nothing ? "anonymous" : m[1]) * s[nextind(s, close):end]
        end
    elseif startswith(s, "#")
        m = match(r"^#([^#]+)", s)
        m === nothing || (s = m[1])
    end
    s
end

"`var\"#f##0\"{A, B{C}}` → `var\"#f##0\"`: the type parameters of closure types, which repeat whole middleware chains."
function strip_closure_params(s::AbstractString)
    io = IOBuffer()
    i = firstindex(s)
    while i <= lastindex(s)
        j = findnext("var\"", s, i)
        if j === nothing
            write(io, SubString(s, i))
            break
        end
        q = findnext('"', s, last(j) + 1)
        q === nothing && (write(io, SubString(s, i)); break)
        write(io, SubString(s, i, q))
        i = nextind(s, q)
        if i <= lastindex(s) && s[i] == '{'
            depth = 0
            while i <= lastindex(s)
                s[i] == '{' && (depth += 1)
                s[i] == '}' && (depth -= 1; depth == 0 && (i = nextind(s, i); break))
                i = nextind(s, i)
            end
        end
    end
    String(take!(io))
end
frame_location(f::Base.StackTraces.StackFrame) =
    (frame_kind(f) === :juango ? "Juango/src/" * relpath(string(f.file), JUANGO_SRC) : string(f.file)) * ":" * string(f.line)

"The template failure noted while rendering (engine.jl), if it's about one of these exceptions."
function template_failure(chain)
    info = get(task_local_storage(), :juango_template_error, nothing)
    info isa TemplateErrorInfo || return nothing
    any(c -> c[1] === info.exception, chain) || return nothing
    isempty(info.name) ? nothing : info
end

"The request, as `(label, value)` pairs per section, masked as Django's SafeExceptionReporterFilter."
function report_request_sections(req::Request)
    secret(k) = occursin(HIDDEN_SETTINGS, string(k))
    rm = req.resolver_match
    out = Pair{String,Vector{Pair{String,String}}}[]
    meta = Pair{String,String}["Method" => req.method, "URL" => build_absolute_uri(req)]
    if rm !== nothing
        push!(meta, "View" => debug_view_name(rm.view))
        rm.url_name === nothing || push!(meta, "URL name" => (rm.namespace === nothing || isempty(rm.namespace) ? "" : rm.namespace * ":") * rm.url_name)
        isempty(rm.kwargs) || push!(meta, "URL arguments" => join(["$k=$(repr(v))" for (k, v) in rm.kwargs], ", "))
    end
    u = getfield(req, :user)
    u === nothing || u isa LazyUser || push!(meta, "User" => debug_repr(u))
    push!(out, "Request" => meta)
    push!(out, "GET" => [k => join(v, ", ") for (k, v) in req.GET.data])
    push!(out, "POST" => [k => (secret(k) ? CLEANSED : join(v, ", ")) for (k, v) in req.POST.data])
    files = get(req.meta, :FILES, nothing)
    files === nothing || push!(out, "FILES" => [string(k) => join([string(f.name, " (", f.size, " bytes)") for f in v], ", ") for (k, v) in files.data])
    push!(out, "Cookies" => [k => (k == settings.SESSION_COOKIE_NAME || k == settings.CSRF_COOKIE_NAME || secret(k) ? CLEANSED : v)
                             for (k, v) in req.COOKIES])
    s = req.session
    s isa Session && s.loaded && push!(out, "Session" => [k => (secret(k) ? CLEANSED : debug_repr(v)) for (k, v) in s.data])
    push!(out, "Headers" => sort!([k => (k in ("cookie", "authorization", "proxy-authorization") || secret(k) ? CLEANSED : v)
                                   for (k, v) in req.headers]; by = first))
    out
end

report_settings() = sort!([string(k) => repr(cleanse_setting(k, v); context = :limit => true) for (k, v) in SETTINGS]; by = first)

"The whole report as plain text: for copying into an issue, and the body of the 500 email to ADMINS."
function exception_report_text(req::Union{Nothing,Request}, @nospecialize(e), bt; chain = exception_chain(e, bt))
    io = IOBuffer()
    println(io, nameof(typeof(e)), req === nothing ? "" : " at " * req.path)
    println(io, sprint(showerror, e))
    println(io)
    req === nothing || println(io, "Request Method: ", req.method, "\nRequest URL: ", build_absolute_uri(req))
    println(io, "Julia: ", VERSION, "\nJuango: ", VERSION_STRING)
    info = template_failure(chain)
    if info !== nothing
        println(io, "\nTemplate error in ", info.name, info.line > 0 ? ", line $(info.line)" : "")
    end
    for (k, (ex, b)) in enumerate(chain)
        k > 1 && println(io, "\nWhile handling the exception above, another exception occurred:\n")
        println(io, "\n", nameof(typeof(ex)), ": ", first(split(sprint(showerror, ex), '\n')))
        println(io, "Traceback (innermost first):")
        for f in stacktrace(b)
            frame_kind(f) === :library && continue
            println(io, "  ", frame_signature(f), "\n    @ ", frame_location(f))
        end
    end
    if req !== nothing
        for (title, ps) in report_request_sections(req)
            println(io, "\n", title, ":")
            isempty(ps) && println(io, "  (none)")
            for (k, v) in ps
                println(io, "  ", k, " = ", v)
            end
        end
    end
    String(take!(io))
end

function technical_500(req::Request, e, bt)
    chain = exception_chain(e, bt)
    info = template_failure(chain)
    cache = Dict{String,Vector{String}}()
    io = IOBuffer()
    title = escape_html(string(nameof(typeof(e)))) * " at " * escape_html(req.path)
    print(io, "<!doctype html><html><head><meta charset=\"utf-8\"><title>", title, "</title>", DEBUG_CSS, DEBUG_500_CSS,
          "</head><body><header class=\"err\"><h1>", escape_html(string(nameof(typeof(e)))), " <span class=\"muted\">at ",
          escape_html(req.path), "</span></h1><pre class=\"msg\">", escape_html(sprint(showerror, e)), "</pre>",
          "<table class=\"meta\"><tr><th>Request Method</th><td>", escape_html(req.method), "</td></tr>",
          "<tr><th>Request URL</th><td>", escape_html(build_absolute_uri(req)), "</td></tr>")
    rm = req.resolver_match
    rm === nothing || print(io, "<tr><th>View</th><td><code>", escape_html(debug_view_name(rm.view)), "</code></td></tr>")
    print(io, "<tr><th>Julia</th><td>", VERSION, "</td></tr><tr><th>Juango</th><td>", VERSION_STRING, "</td></tr>",
          "<tr><th>Server time</th><td>", Dates.format(Dates.now(), "yyyy-mm-dd HH:MM:SS"), "</td></tr></table></header><main>")

    # template errors: a syntax error knows its source; a failure while rendering was noted by the engine
    print(io, template_error_html(e))
    if info !== nothing && !(e isa TemplateSyntaxError)
        print(io, "<h2>Error during template rendering</h2><p>In template <code>", escape_html(something(info.origin, info.name)), "</code>",
              info.line > 0 ? ", error at line $(info.line)" : "", "</p>")
        src = info.origin === nothing ? nothing : source_context(info.origin, info.line, cache; n = 7)
        if src !== nothing
            write_source(io, src[1], src[2], info.line)
        end
    end

    # the exception chain and the stack
    for (k, (ex, b)) in enumerate(chain)
        if length(chain) > 1
            print(io, k == 1 ? "<h2>Exceptions</h2>" : "<p class=\"chain\">While handling the exception above, another exception occurred:</p>",
                  "<h3>", escape_html(string(nameof(typeof(ex)))), "</h3><pre class=\"msg\">", escape_html(sprint(showerror, ex)), "</pre>")
        end
        write_stack(io, stacktrace(b), cache)
    end

    # request, settings and the text report
    print(io, "<h2>Request information</h2>")
    for (title, ps) in report_request_sections(req)
        print(io, "<h3>", escape_html(title), "</h3>")
        if isempty(ps)
            print(io, "<p class=\"muted\">No ", escape_html(title), " data</p>")
        else
            print(io, "<table class=\"kv\">")
            for (k, v) in ps
                print(io, "<tr><th>", escape_html(k), "</th><td><code>", escape_html(v), "</code></td></tr>")
            end
            print(io, "</table>")
        end
    end
    print(io, "<details><summary><h2>Settings</h2></summary><table class=\"kv\">")
    for (k, v) in report_settings()
        print(io, "<tr><th>", escape_html(k), "</th><td><code>", escape_html(v), "</code></td></tr>")
    end
    print(io, "</table></details>")
    print(io, "<details><summary><h2>Copy-and-paste view</h2></summary><textarea readonly rows=\"30\">",
          escape_html(exception_report_text(req, e, bt; chain = chain)), "</textarea></details>")
    print(io, "<p class=\"muted\">You’re seeing this error because you have <code>DEBUG = true</code> in your settings. ",
          "Change that to <code>false</code>, and Juango will display a standard page generated by the handler for this status code.</p>",
          "</main></body></html>")
    delete!(task_local_storage(), :juango_template_error)
    HttpResponse(take!(io); status = 500)
end

function write_source(io::IO, lo::Int, lines::Vector{String}, hl::Integer)
    print(io, "<table class=\"src\">")
    for (i, l) in enumerate(lines)
        n = lo + i - 1
        print(io, "<tr", n == hl ? " class=\"hl\"" : "", "><td class=\"ln\">", n, "</td><td><code>", escape_html(l), "</code></td></tr>")
    end
    print(io, "</table>")
end

"The frames, innermost first: your code open, Juango's dimmed, runs of library frames folded into one line."
function write_stack(io::IO, frames, cache)
    print(io, "<h2>Traceback <span class=\"muted\">(innermost call first)</span></h2><ol class=\"frames\">")
    opened = false
    k = 1
    while k <= length(frames)
        f = frames[k]
        kind = frame_kind(f)
        if kind === :library
            j = k
            while j < length(frames) && frame_kind(frames[j+1]) === :library
                j += 1
            end
            print(io, "<li class=\"lib\"><details><summary>", j - k + 1, j == k ? " library frame" : " library frames",
                  " <span class=\"muted\">(Base, the standard library, packages)</span></summary><ol>")
            for g in frames[k:j]
                print(io, "<li><code>", escape_html(frame_signature(g)), "</code> <span class=\"loc\">", escape_html(frame_location(g)), "</span></li>")
            end
            print(io, "</ol></details></li>")
            k = j + 1
            continue
        end
        src = source_context(frame_source_path(f), f.line, cache)
        open_it = kind === :user && !opened
        open_it && (opened = true)
        print(io, "<li class=\"", kind, "\"><details", open_it ? " open" : "", "><summary><code>", escape_html(frame_signature(f)),
              "</code> <span class=\"loc\">", escape_html(frame_location(f)), "</span>", f.inlined ? " <span class=\"muted\">[inlined]</span>" : "")
        if src !== nothing
            i = f.line - src[1] + 1
            1 <= i <= length(src[2]) && print(io, "<pre class=\"line\">", escape_html(strip(src[2][i])), "</pre>")
        end
        print(io, "</summary>")
        src === nothing ? print(io, "<p class=\"muted\">Source not available.</p>") : write_source(io, src[1], src[2], f.line)
        print(io, "</details></li>")
        k += 1
    end
    print(io, "</ol>")
end

const DEBUG_500_CSS = """
<style>
.msg{white-space:pre-wrap;background:#fff;border:1px solid #f3c5c5}
table.meta th,table.kv th{text-align:left;font-weight:500;color:#555;padding:2px 12px 2px 0;vertical-align:top;white-space:nowrap}
table.kv{border-collapse:collapse;width:100%}table.kv td,table.kv th{border-bottom:1px solid #eee;padding:3px 8px}
table.kv code{background:none;word-break:break-all}
h2{font-size:18px;margin:24px 0 8px}h3{font-size:15px;margin:14px 0 4px}
ol.frames{list-style:none;padding:0}ol.frames>li{margin:4px 0;border:1px solid #e3e3e3;border-radius:4px;padding:4px 8px}
ol.frames li.user{border-color:#d9a3a3;background:#fffafa}ol.frames li.juango{opacity:.75}ol.frames li.lib{background:#fafafa;opacity:.7}
ol.frames summary{cursor:pointer}ol.frames code{background:none;word-break:break-word}
ol.frames ol{list-style:none;padding-left:12px;font-size:12px}
.loc{color:#777;font-size:12px}
pre.line{margin:2px 0 0;padding:2px 8px;background:#f6f6f6;font-size:12px;white-space:pre-wrap}
table.src{border-collapse:collapse;margin:6px 0;font-size:12px;width:100%}table.src td{padding:0 8px;white-space:pre}
table.src code{background:none}table.src td.ln{color:#999;text-align:right;width:3em;user-select:none}table.src tr.hl{background:#fde8e8}
details>summary>h2{display:inline}
textarea{width:100%;font:12px ui-monospace,monospace}
p.chain{margin-top:20px;font-style:italic}
</style>"""
