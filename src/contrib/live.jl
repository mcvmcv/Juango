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
# to) renders the `{% liveview %}` part again and sends it; the browser morphs it into the page.
# The whole part is sent each time; sending only the changed parts is for later.

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
end
LiveSession(view, req, template) = LiveSession(view, req, template, Channel{Any}(1024), Set{String}(), "")

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
    publish(topic, msg) -> number of views it was sent to

Send `msg` to the `handle_info` of every open live view subscribed to `topic`. A view whose
queue is full (1024 unhandled messages) misses it.
"""
function publish(topic::AbstractString, msg)
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

"The socket's side: mount, then handle events and messages until the page closes."
function run_live(ws, req::Request, lr::LiveRoute, kwargs)
    s = nothing
    reader = nothing
    try
        join = JSON.parse(String(ws_receive(ws)))
        get(join, "type", "") == "join" || return
        s = LiveSession(lr.view(), req, lr.template)
        try
            with_live_session(() -> mount(s.view, req, live_params(req, kwargs, get(join, "params", nothing))), s)
        catch e
            e isa Union{Http404,PermissionDenied} || rethrow()
            return close(ws, HTTP.WebSockets.CloseFrameBody(4403, "refused"))
        end
        s.html = render_live(s)
        ws_send(ws, Dict("type" => "render", "html" => s.html))
        inbox = s.inbox
        reader = @async begin
            try
                for raw in ws
                    m = JSON.parse(raw isa AbstractString ? raw : String(raw))
                    get(m, "type", "") == "event" &&
                        put!(inbox, (:event, string(get(m, "event", "")), Dict{String,Any}(string(k) => v for (k, v) in get(m, "params", Dict()))))
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
            url = live_dispatch!(s, m)
            if url !== nothing
                ws_send(ws, Dict("type" => "redirect", "url" => url))
                continue
            end
            html = render_live(s)
            if html != s.html
                s.html = html
                ws_send(ws, Dict("type" => "render", "html" => html))
            end
        end
    catch e
        # a failing handler closes the socket; the browser reconnects and mounts a fresh view
        is_disconnect(e) || @error "live view $(lr.view) failed" exception = (e, catch_backtrace())
    finally
        if s !== nothing
            foreach(t -> unsubscribe!(s, t), collect(s.topics))
            close(s.inbox)
        end
        ws_isopen(ws) && try close(ws) catch end
    end
    nothing
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
