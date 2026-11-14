# Live views (experimental), in the manner of Phoenix LiveView ------------------------------------------
#
#     Base.@kwdef mutable struct Counter <: LiveView
#         count::Int = 0
#     end
#     Juango.mount(v::Counter, req, params) = (v.count = parse(Int, get(params, "start", "0")))
#     Juango.handle_event(v::Counter, name, params) = name == "inc" && (v.count += 1)
#
#     urlpatterns = [live("counter/", Counter, "counter.html"; name = "counter")]
#
#     counter.html:
#     {% extends "base.html" %}
#     {% block content %}{% liveview %}<p>{{ count }}</p><button j-click="inc">+1</button>{% endliveview %}{% endblock %}
#
# The page is rendered as ordinary HTML (it works without JavaScript). Then live.js opens a
# WebSocket to the same URL: the server mounts a fresh view, keeps it in a task for as long as the
# page is open, and after every browser event (or message published to a topic it subscribed
# to) renders the `{% liveview %}` part again and sends what changed (the span between the first
# and last differing character, against the last HTML the browser has); the browser patches its
# copy and morphs it into the page.
#
# Settings: LIVE_MAX_STATE_BYTES (a view bigger than this is closed), LIVE_MAX_VIEWS_PER_SESSION, LIVE_MAX_VIEWS,
# LIVE_MAX_MESSAGE_BYTES, LIVE_MAX_UPLOAD_BYTES, and LIVE_PUBSUB = :postgres to deliver `publish`
# to every process through PostgreSQL's LISTEN/NOTIFY. A view type can keep its state across a
# reconnect (`Juango.live_snapshot(::Type{MyView}) = true`): the browser holds a signed copy.

"""
    LiveView

The supertype of live views. A live view is a mutable struct with a zero-argument constructor
(`Base.@kwdef` gives one) and methods of `mount`, `handle_event` and `handle_info`. Its fields
are the template's variables (`live_context` changes that).
"""
abstract type LiveView end

"""
    mount(view, req, params)

Set up a new view. `params` (a `Dict{String,Any}`) holds the URL's parameters and query
string. Called for the page and again when the browser connects (or reconnects) its socket.
Throwing `Http404` or `PermissionDenied` refuses the view.
"""
mount(v::LiveView, req, params) = nothing

"""
    handle_event(view, name, params)

A browser event: `name` from `j-click="name"` and the other bindings, `params` its values
(form fields, `j-value-*` attributes...). Return `live_redirect(url)` to send the browser
elsewhere. The view is rendered again afterwards.
"""
handle_event(v::LiveView, name, params) = @warn "$(nameof(typeof(v))) has no handle_event for $(repr(name))"

"`handle_info(view, msg)`: a message `publish`ed to a topic the view subscribed to (in `mount`)."
handle_info(v::LiveView, msg) = nothing

"The template variables of a view: its fields, and `view` itself."
function live_context(v::LiveView)
    d = Dict{String,Any}(string(f) => getfield(v, f) for f in fieldnames(typeof(v)))
    d["view"] = v
    d
end

struct LiveRedirect
    url::String
end
"`live_redirect(url)`: return it from `handle_event` to send the browser to `url`."
live_redirect(url) = LiveRedirect(string(url))

# --- one open page ------------------------------------------------------------------------------------

mutable struct LiveSession
    view::Any
    req::Request
    template::String
    inbox::Channel{Any}
    topics::Set{String}
    html::String
    seq::Int                                  # renders sent; patches name the one they apply to
    uploads::Dict{String,Any}                 # ref => (name, content_type, IOBuffer or (path, io), size)
end
LiveSession(view, req, template) = LiveSession(view, req, template, Channel{Any}(1024), Set{String}(), "", 0, Dict{String,Any}())

"The view's `{% liveview %}` part, rendered."
function render_live(s::LiveSession)
    resp = render(s.req, s.template * "#live", live_context(s.view))
    String(resp.body)
end

current_live_session() = get(task_local_storage(), :juango_live, nothing)
with_live_session(f, s::LiveSession) = task_local_storage(f, :juango_live, s)

function live_params(req::Request, kwargs, extra = nothing)
    p = Dict{String,Any}(string(k) => v for (k, v) in kwargs)
    for (k, v) in req.GET
        p[k] = v
    end
    extra === nothing || foreach(((k, v),) -> p[string(k)] = v, pairs(extra))
    p
end

"Run one message through the view: an event or a published message. Returns a redirect URL or nothing."
function live_dispatch!(s::LiveSession, m)
    r = with_live_session(s) do
        m[1] === :event ? handle_event(s.view, m[2], m[3]) : handle_info(s.view, m[2])
    end
    r isa LiveRedirect ? r.url : nothing
end

# --- publish / subscribe --------------------------------------------------------------------------

const LIVE_TOPICS = Dict{String,Set{Channel{Any}}}()
const LIVE_TOPICS_LOCK = ReentrantLock()

"""
    subscribe(topic)

In a live view's `mount` (or event handler): deliver messages `publish`ed to `topic` to the view's
`handle_info`, for as long as its page is open. In-process only, for now.
"""
function subscribe(topic::AbstractString)
    s = current_live_session()
    s === nothing && throw(ArgumentError("subscribe: call it from a live view's mount or handlers"))
    lock(() -> push!(get!(Set{Channel{Any}}, LIVE_TOPICS, String(topic)), s.inbox), LIVE_TOPICS_LOCK)
    push!(s.topics, String(topic))
    ensure_live_listener()
    nothing
end

"`unsubscribe(topic)`: stop delivering `topic` to the current live view."
function unsubscribe(topic::AbstractString)
    s = current_live_session()
    s === nothing && return nothing
    unsubscribe!(s, String(topic))
end
function unsubscribe!(s::LiveSession, topic::String)
    lock(LIVE_TOPICS_LOCK) do
        subs = get(LIVE_TOPICS, topic, nothing)
        subs === nothing && return
        delete!(subs, s.inbox)
        isempty(subs) && delete!(LIVE_TOPICS, topic)
    end
    delete!(s.topics, topic)
    nothing
end

"""
    publish(topic, msg) -> number of views it was sent to (in this process)

Send `msg` to the `handle_info` of every open live view subscribed to `topic`. A view whose
queue is full (1024 unhandled messages) misses it.

With `LIVE_PUBSUB = :postgres`, the message goes to the views of every process using the same
PostgreSQL database, through `NOTIFY` (sent when the current transaction commits, if there is
one). It must then be something the cache's JSON serializer stores (numbers, strings, dates,
models, containers ...), at most about 7 KB as JSON, and `publish` returns `nothing`.
"""
function publish(topic::AbstractString, msg)
    settings.LIVE_PUBSUB === :postgres || return publish_local(topic, msg)
    backend() isa PostgresBackend || throw(ImproperlyConfigured("LIVE_PUBSUB = :postgres needs a PostgreSQL DATABASE"))
    payload = JSON.json(Dict("t" => String(topic), "m" => cache_encode(msg)))
    ncodeunits(payload) < 7900 || throw(ArgumentError("publish: the message is too big for NOTIFY ($(ncodeunits(payload)) bytes as JSON)"))
    execute("SELECT pg_notify(?, ?)", Any[LIVE_CHANNEL, payload])
    nothing
end

const LIVE_CHANNEL = "juango_live"
"The process's LISTEN task for LIVE_PUBSUB = :postgres: (listener, the database setting it listens on)."
const LIVE_LISTENER = Ref{Any}(nothing)
const LIVE_LISTENER_LOCK = ReentrantLock()

"Start listening for other processes' `publish` (LIVE_PUBSUB = :postgres), once per process."
function ensure_live_listener()
    settings.LIVE_PUBSUB === :postgres || return
    lock(LIVE_LISTENER_LOCK) do
        url = db_state().setting
        cur = LIVE_LISTENER[]
        cur !== nothing && cur[2] == url && return
        cur === nothing || close(cur[1])
        url isa AbstractString || throw(ImproperlyConfigured("LIVE_PUBSUB = :postgres needs DATABASE to be a postgresql:// URL"))
        l = PGListener()
        LIVE_LISTENER[] = (l, url)
        ready = Channel{Bool}(1)
        errormonitor(Threads.@spawn begin
            first_try = true
            while !l.stopped
                try
                    pg_listen(l, url, LIVE_CHANNEL) do payload
                        d = JSON.parse(payload)
                        publish_local(string(d["t"]), cache_decode(d["m"]))
                    end
                catch e
                    l.stopped || @error "live views: listening for NOTIFY failed; retrying" exception = e
                end
                first_try && (first_try = false; isready(ready) || put!(ready, false))
                l.stopped || sleep(1)
            end
        end)
        # wait until LISTEN is in place, so a publish right after subscribing isn't missed
        t0 = time()
        while (l.watcher === nothing && !l.stopped) && time() - t0 < 10 && !isready(ready)
            sleep(0.01)
        end
    end
    nothing
end
stop_live_listener() = lock(() -> (cur = LIVE_LISTENER[]; cur === nothing || close(cur[1]); LIVE_LISTENER[] = nothing), LIVE_LISTENER_LOCK)
push!(SETTINGS_CHANGED_HOOKS, () -> (cur = LIVE_LISTENER[]; cur !== nothing && (settings.LIVE_PUBSUB !== :postgres ||
                                     get(database_settings(), "default", nothing) != cur[2]) && stop_live_listener()))

function publish_local(topic::AbstractString, msg)
    inboxes = lock(() -> collect(get(LIVE_TOPICS, String(topic), Set{Channel{Any}}())), LIVE_TOPICS_LOCK)
    n = 0
    for ch in inboxes
        if isopen(ch) && Base.n_avail(ch) < 1024
            put!(ch, (:info, msg))
            n += 1
        end
    end
    n
end

# --- the route ---------------------------------------------------------------------------------------

struct LiveRoute
    view::Type
    template::String
end

"""
    live(route, View, template; name = nothing)

A URL pattern for a live view: an ordinary GET renders `template` with a freshly mounted view;
the WebSocket that live.js opens to the same URL keeps a view alive for the page.
"""
live(route::AbstractString, V::Type{<:LiveView}, template::AbstractString; name = nothing) =
    path(route, LiveRoute(V, String(template)); name = name)

function (lr::LiveRoute)(req::Request; kwargs...)
    if get(req.meta, :websocket_upgrade, false)
        return WebSocketView((ws, r; kw...) -> run_live(ws, r, lr, kw), String[])(req; kwargs...)
    end
    v = lr.view()
    s = LiveSession(v, req, lr.template)
    with_live_session(() -> mount(v, req, live_params(req, kwargs)), s)
    foreach(t -> unsubscribe!(s, t), collect(s.topics))     # the page itself doesn't stay subscribed
    render(req, lr.template, live_context(v))
end

# --- patches -----------------------------------------------------------------------------------------

"""
The change from `old` to `new` as (start, deleted, inserted), in UTF-16 code units as JavaScript
counts them: the span between the first and the last character that differ.
"""
function live_patch(old::String, new::String)
    a, b = transcode(UInt16, old), transcode(UInt16, new)
    n = min(length(a), length(b))
    p = 0
    while p < n && a[p+1] == b[p+1]
        p += 1
    end
    p > 0 && 0xd800 <= a[p] <= 0xdbff && (p -= 1)             # don't split a surrogate pair
    q = 0
    while q < n - p && a[end-q] == b[end-q]
        q += 1
    end
    q > 0 && 0xdc00 <= a[end-q+1] <= 0xdfff && (q -= 1)
    (p, length(a) - p - q, transcode(String, b[p+1:end-q]))
end

"Send the view's HTML: a patch against what the browser has when that's smaller, else the whole part."
function live_send_render!(ws, s::LiveSession, html::String, diff::Bool)
    msg = Dict{String,Any}("seq" => s.seq + 1)
    if diff && !isempty(s.html)
        start, del, ins = live_patch(s.html, html)
        if ncodeunits(ins) + 64 < ncodeunits(html)
            merge!(msg, Dict("type" => "patch", "base" => s.seq, "start" => start, "del" => del, "ins" => ins))
        end
    end
    haskey(msg, "type") || merge!(msg, Dict("type" => "render", "html" => html))
    snap = live_snapshot_token(s)
    snap === nothing || (msg["snap"] = snap)
    s.seq += 1
    s.html = html
    ws_send(ws, msg)
end

# --- limits ----------------------------------------------------------------------------------------

# Open live views per session, and in all. A visitor without a session counts only towards the total
# (not per client address: behind a reverse proxy every visitor has the proxy's address).
const LIVE_OPEN = Dict{String,Int}()
const LIVE_OPEN_TOTAL = Ref(0)
const LIVE_OPEN_LOCK = ReentrantLock()
live_owner(req::Request) = (k = try req.session.key catch; nothing end; k === nothing ? nothing : "session:" * k)
function live_claim!(owner::Union{Nothing,String})
    lock(LIVE_OPEN_LOCK) do
        LIVE_OPEN_TOTAL[] >= settings.LIVE_MAX_VIEWS && return false
        if owner !== nothing
            n = get(LIVE_OPEN, owner, 0)
            n >= settings.LIVE_MAX_VIEWS_PER_SESSION && return false
            LIVE_OPEN[owner] = n + 1
        end
        LIVE_OPEN_TOTAL[] += 1
        true
    end
end
function live_release!(owner::Union{Nothing,String})
    lock(LIVE_OPEN_LOCK) do
        LIVE_OPEN_TOTAL[] = max(0, LIVE_OPEN_TOTAL[] - 1)
        owner === nothing && return
        n = get(LIVE_OPEN, owner, 1) - 1
        n <= 0 ? delete!(LIVE_OPEN, owner) : (LIVE_OPEN[owner] = n)
    end
end

struct LiveTooLarge <: Exception
    what::String
end

# --- state across a reconnect ----------------------------------------------------------------------

"""
    Juango.live_snapshot(::Type{MyView}) = true

Keep a view's state across a reconnect: after each render the browser gets a signed copy of its
fields (they must be values the cache's JSON serializer stores: numbers, strings, dates, models,
containers of them ...), and sends it back when it reconnects; the view is mounted (for its
subscriptions) and then gets those fields back, instead of starting afresh. Snapshots older than
LIVE_SNAPSHOT_MAX_AGE seconds are ignored.
"""
live_snapshot(::Type) = false

# Whose state it is: the user and the session (a new login, or another browser, mounts afresh).
function live_snapshot_owner(req::Request)
    u = try req.user catch; nothing end
    uid = u isa AbstractUser ? string(u.id) : ""
    k = try req.session.key catch; nothing end
    uid * "|" * something(k, "")
end

function live_snapshot_token(s::LiveSession)
    V = typeof(s.view)
    live_snapshot(V) || return nothing
    try
        fields = Dict{String,Any}(string(f) => cache_encode(getfield(s.view, f)) for f in fieldnames(V))
        signing_dumps(Dict("v" => string(nameof(V)), "p" => s.req.path, "o" => live_snapshot_owner(s.req), "f" => fields); salt = "juango.live")
    catch e
        @warn "live view $V: can't snapshot its state (keep live_snapshot for views whose fields the cache can store)" exception = e maxlog = 1
        nothing
    end
end

function live_restore!(s::LiveSession, token)
    token isa AbstractString || return false
    d = try
        signing_loads(token; salt = "juango.live", max_age = settings.LIVE_SNAPSHOT_MAX_AGE)
    catch
        return false                                   # tampered with, or too old: mount afresh
    end
    V = typeof(s.view)
    (get(d, "v", "") == string(nameof(V)) && get(d, "p", "") == s.req.path && get(d, "o", nothing) == live_snapshot_owner(s.req)) || return false
    for (k, v) in get(d, "f", Dict())
        f = Symbol(k)
        f in fieldnames(V) || continue
        setfield!(s.view, f, convert(fieldtype(V, f), cache_decode(v)))
    end
    true
end

# --- uploads over the socket -------------------------------------------------------------------------
#
# live.js sends a form's files before its submit event, in chunks: {type: "upload", ref, name,
# content_type, chunk (base64), last}. The event's parameters then name each file as
# {"__upload__": ref}, which becomes an `UploadedFile` (in memory, or a temporary file past
# FILE_UPLOAD_MAX_MEMORY_SIZE). LIVE_MAX_UPLOAD_BYTES limits each file.

function live_upload_chunk!(s::LiveSession, m)
    ref = string(get(m, "ref", ""))
    isempty(ref) && return
    # at most DATA_UPLOAD_MAX_NUMBER_FILES waiting for an event at once (each up to LIVE_MAX_UPLOAD_BYTES)
    !haskey(s.uploads, ref) && something(settings.DATA_UPLOAD_MAX_NUMBER_FILES, typemax(Int)) <= length(s.uploads) &&
        throw(LiveTooLarge("number of uploads"))
    haskey(s.uploads, ref) && s.uploads[ref]["done"] && return            # finished: no more chunks
    u = get!(s.uploads, ref) do
        Dict{String,Any}("name" => basename(string(get(m, "name", "upload"))), "ctype" => string(get(m, "content_type", "application/octet-stream")),
                         "buf" => IOBuffer(), "path" => nothing, "size" => 0, "done" => false)
    end
    bytes = base64decode(string(get(m, "chunk", "")))
    u["size"] += length(bytes)
    u["size"] > settings.LIVE_MAX_UPLOAD_BYTES && throw(LiveTooLarge("upload $(u["name"])"))
    if u["path"] === nothing && u["size"] > settings.FILE_UPLOAD_MAX_MEMORY_SIZE
        path, io = mktemp(something(settings.FILE_UPLOAD_TEMP_DIR, tempdir()))
        write(io, take!(u["buf"]))
        u["path"], u["buf"] = path, io
    end
    write(u["buf"], bytes)
    get(m, "last", false) === true && (u["done"] = true)
    nothing
end

"""
Event parameters with `{\"__upload__\": ref}` (or a list of them) replaced by the uploaded files.
Returns the refs used: they're released once the event has been handled (`live_release_uploads!`).
"""
function live_attach_uploads!(s::LiveSession, params::Dict{String,Any})
    used = String[]
    function file_for(v)
        v isa AbstractDict && haskey(v, "__upload__") || return v
        ref = string(v["__upload__"])
        u = get(s.uploads, ref, nothing)
        (u === nothing || !u["done"] || ref in used) && return nothing
        push!(used, ref)
        if u["path"] === nothing
            UploadedFile(u["name"], take!(u["buf"]); content_type = u["ctype"])
        else
            close(u["buf"])
            TemporaryUploadedFile(u["name"], u["path"]; content_type = u["ctype"])
        end
    end
    for (k, v) in collect(params)
        if v isa AbstractVector && any(x -> x isa AbstractDict && haskey(x, "__upload__"), v)
            fs = Any[f for f in (file_for(x) for x in v) if f !== nothing]
            isempty(fs) ? delete!(params, k) : (params[k] = fs)
        elseif v isa AbstractDict && haskey(v, "__upload__")
            f = file_for(v)
            f === nothing ? delete!(params, k) : (params[k] = f)
        end
    end
    used
end
"Forget uploads an event has used, removing their temporary files (as a request's are removed at its end)."
function live_release_uploads!(s::LiveSession, refs)
    for ref in refs
        u = pop!(s.uploads, ref, nothing)
        (u === nothing || u["path"] === nothing) && continue
        try close(u["buf"]) catch end
        rm(u["path"]; force = true)
    end
end
function live_cleanup_uploads!(s::LiveSession)
    for u in values(s.uploads)
        u["path"] === nothing && continue
        try close(u["buf"]) catch end
        rm(u["path"]; force = true)
    end
    empty!(s.uploads)
end

"The socket's side: mount, then handle events and messages until the page closes."
function run_live(ws, req::Request, lr::LiveRoute, kwargs)
    s = nothing
    reader = nothing
    owner = live_owner(req)
    claimed = false
    try
        join = JSON.parse(String(ws_receive(ws)))
        get(join, "type", "") == "join" || return
        claimed = live_claim!(owner)
        claimed || return close(ws, HTTP.WebSockets.CloseFrameBody(4429, "too many live views"))
        diff = get(join, "diff", false) === true
        s = LiveSession(lr.view(), req, lr.template)
        try
            with_live_session(() -> mount(s.view, req, live_params(req, kwargs, get(join, "params", nothing))), s)
        catch e
            e isa Union{Http404,PermissionDenied} || rethrow()
            return close(ws, HTTP.WebSockets.CloseFrameBody(4403, "refused"))
        end
        live_snapshot(typeof(s.view)) && live_restore!(s, get(join, "snap", nothing))
        live_send_render!(ws, s, render_live(s), diff)
        inbox = s.inbox
        sess = s
        reader = @async begin
            try
                for raw in ws
                    sizeof(raw) > settings.LIVE_MAX_MESSAGE_BYTES && (put!(inbox, (:toolarge, "message")); break)
                    m = JSON.parse(raw isa AbstractString ? raw : String(raw))
                    t = get(m, "type", "")
                    if t == "event"
                        put!(inbox, (:event, string(get(m, "event", "")), Dict{String,Any}(string(k) => v for (k, v) in get(m, "params", Dict()))))
                    elseif t == "upload"
                        put!(inbox, (:upload, m))
                    elseif t == "resync"
                        put!(inbox, (:resync,))
                    end
                end
            catch e
                is_disconnect(e) || e isa InvalidStateException || @error "live view: reading the socket" exception = (e, catch_backtrace())
            finally
                isopen(inbox) && put!(inbox, (:closed,))
            end
        end
        while true
            m = take!(inbox)
            m[1] === :closed && break
            m[1] === :toolarge && throw(LiveTooLarge(m[2]))
            m[1] === :upload && (live_upload_chunk!(s, m[2]); continue)
            if m[1] === :resync                       # the browser lost track: send the whole part
                s.html = ""
                live_send_render!(ws, s, render_live(s), false)
                continue
            end
            used = m[1] === :event ? live_attach_uploads!(s, m[3]) : String[]
            url = try
                live_dispatch!(s, m)
            finally
                live_release_uploads!(s, used)
            end
            if url !== nothing
                ws_send(ws, Dict("type" => "redirect", "url" => url))
                continue
            end
            Base.summarysize(s.view) > settings.LIVE_MAX_STATE_BYTES && throw(LiveTooLarge("state"))
            html = render_live(s)
            html == s.html || live_send_render!(ws, s, html, diff)
        end
    catch e
        if e isa LiveTooLarge
            @warn "live view $(lr.view): closed, $(e.what) too large (LIVE_MAX_STATE_BYTES, LIVE_MAX_MESSAGE_BYTES, LIVE_MAX_UPLOAD_BYTES)"
            ws_isopen(ws) && try close(ws, HTTP.WebSockets.CloseFrameBody(4413, "too large")) catch end
        else
            # a failing handler closes the socket; the browser reconnects and mounts a fresh view
            is_disconnect(e) || @error "live view $(lr.view) failed" exception = (e, catch_backtrace())
        end
    finally
        claimed && live_release!(owner)
        if s !== nothing
            foreach(t -> unsubscribe!(s, t), collect(s.topics))
            close(s.inbox)
            live_cleanup_uploads!(s)
        end
        ws_isopen(ws) && try close(ws) catch end
    end
    nothing
end

# --- forms in live views -------------------------------------------------------------------------------

"""
    LiveForm(make)

A form in a live view, validated as the user types: errors show only for fields they've changed
(or all of them once they submit). `make(data)` (or `make(data, files)`) builds the form from
the submitted values: `LiveForm(d -> ContactForm(d))`, or `LiveForm((d, files) -> ModelForm(Post; data = d, files = files))`.

    Base.@kwdef mutable struct Contact <: LiveView
        form::LiveForm = LiveForm(d -> ContactForm(d))
    end
    function Juango.handle_event(v::Contact, name, params)
        name == "validate" && live_change!(v.form, params)                 # <form j-change="validate" j-submit="save">
        name == "save" && live_submit!(v.form, params) && (save_message(v.form.form); return live_redirect("/thanks/"))
    end

The template renders `form.form` as any form (`{{ form.form }}`, or field by field). File inputs
in a `j-submit` form are uploaded over the socket first and arrive as `UploadedFile`s.
"""
mutable struct LiveForm
    make::Any
    form::Any
    touched::Set{String}          # html names of the fields the user has changed
end
LiveForm(make) = LiveForm(make, make(nothing), Set{String}())

function live_form_data(params)
    data = Dict{String,Vector{String}}()
    files = Dict{String,Any}()
    for (k, v) in params
        k == "_target" && continue
        if v isa UploadedFile
            files[k] = v
        elseif v isa AbstractVector
            data[k] = String[string(x) for x in v]
        else
            data[k] = [v === nothing ? "" : string(v)]
        end
    end
    QueryDict(data), files
end
function live_rebuild!(lf::LiveForm, params)
    data, files = live_form_data(params)
    lf.form = applicable(lf.make, data, files) ? lf.make(data, files) : lf.make(data)
    is_valid(lf.form)
end

"`live_change!(lf, params)`: a field changed (`j-change` on the form): validate, showing errors for the fields touched so far."
function live_change!(lf::LiveForm, params)
    t = string(get(params, "_target", ""))
    isempty(t) || push!(lf.touched, t)
    live_rebuild!(lf, params)
    f = lf.form
    shown = Set(fld.name for fld in f.fields if html_name(f, fld) in lf.touched)
    filter!(kv -> kv.first in shown, f.errors)
    lf
end

"`live_submit!(lf, params) -> Bool`: the form was submitted: validate every field; true when it's valid."
function live_submit!(lf::LiveForm, params)
    ok = live_rebuild!(lf, params)
    foreach(fld -> push!(lf.touched, html_name(lf.form, fld)), lf.form.fields)
    ok
end

# --- {% liveview %} ----------------------------------------------------------------------------------

"Opens the live part: the element live.js connects, with the URL of the page's view."
struct LiveOpenNode <: Node end
function render!(io::IO, ::LiveOpenNode, ctx::Context)
    req = lookup(ctx, "request")
    p = req isa Request ? req.path : ""
    write(io, "<div id=\"j-live\" data-j-live=\"", escape_html(p), "\">")
end

struct LiveViewNode <: Node
    parts::Vector{Node}           # [the "live" partial]: what the socket renders again
end
child_nodelists(n::LiveViewNode) = (n.parts,)
function render!(io::IO, n::LiveViewNode, ctx::Context)
    write(io, "<script src=\"", escape_html(static_url("juango/idiomorph.min.js")), "\" defer></script>",
          "<script src=\"", escape_html(static_url("juango/live.js")), "\" defer></script>")
    run_nodes(io, n.parts[1].body, ctx)
end

function tag_liveview(p::Parser, t::Token)
    body, _ = parse_nodes(p, ["endliveview"])
    partials = get!(Dict{String,PartialDefNode}, p.extra, :partials)
    haskey(partials, "live") && throw(TemplateSyntaxError("a template can have only one {% liveview %} (partial 'live')"))
    d = PartialDefNode("live", false, Node[LiveOpenNode(); body; TextNode("</div>")])
    partials["live"] = d
    LiveViewNode(Node[d])
end
register_tag!("liveview", tag_liveview)

# --- testing ---------------------------------------------------------------------------------------

"""
    lt = live_test(View, template; params = Dict(), user = nothing, path = "/")

Mount a live view without a browser or socket, for tests: `live_event!(lt, "inc")` sends an event,
`live_info!(lt, msg)` a message, `live_flush!(lt)` handles messages `publish`ed to its topics.
Each returns the rendered `{% liveview %}` part (also `lt.html`); `lt.redirect` is the last
`live_redirect`, `lt.view` the view.
"""
mutable struct LiveTest
    session::LiveSession
    redirect::Union{Nothing,String}
end
function Base.getproperty(lt::LiveTest, s::Symbol)
    s === :view && return getfield(lt, :session).view
    s === :html && return getfield(lt, :session).html
    getfield(lt, s)
end

function live_test(V::Type{<:LiveView}, template::AbstractString; params = Dict{String,Any}(), user = nothing, path = "/")
    req = Request("GET", path)
    user === nothing || (req.user = user)
    s = LiveSession(V(), req, String(template))
    with_live_session(() -> mount(s.view, req, Dict{String,Any}(string(k) => v for (k, v) in pairs(params))), s)
    s.html = render_live(s)
    LiveTest(s, nothing)
end
function live_step!(lt::LiveTest, m)
    s = getfield(lt, :session)
    url = live_dispatch!(s, m)
    url === nothing || (lt.redirect = url)
    s.html = render_live(s)
end
live_event!(lt::LiveTest, name, params = Dict{String,Any}()) =
    live_step!(lt, (:event, string(name), Dict{String,Any}(string(k) => v for (k, v) in pairs(params))))
live_info!(lt::LiveTest, msg) = live_step!(lt, (:info, msg))
function live_flush!(lt::LiveTest)
    s = getfield(lt, :session)
    while isready(s.inbox)
        m = take!(s.inbox)
        m[1] === :info && live_dispatch!(s, m)
    end
    s.html = render_live(s)
end
"Close a `live_test` view: unsubscribe it from its topics."
Base.close(lt::LiveTest) = (s = getfield(lt, :session); foreach(t -> unsubscribe!(s, t), collect(s.topics)); close(s.inbox))
