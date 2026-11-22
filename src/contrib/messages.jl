# Messages framework: one-time notifications for the next page ----------------------------------------
#
#     message!(req, :success, "Saved.")                        # or a level number: message!(req, 35, "...")
#     message!(req, :info, format_html("<a href=\"{}\">Undo</a>", url); extra_tags = "undo")
#     {% for m in messages %}<p class="{{ m.tags }}">{{ m }}</p>{% endfor %}
#
# Levels are numbers, as Django's: debug 10, info 20, success 25, warning 30, error 40; custom
# levels are other numbers, named for templates with MESSAGE_TAGS (`Dict(35 => "notice")`, which
# can also rename the built-in ones: `Dict(40 => "danger")` for Bootstrap). Messages below
# MESSAGE_LEVEL (default info), or below `set_level!(req, level)` for one request, are dropped.
#
# Storage (MESSAGE_STORAGE): `:session` (the default) keeps them in the session; `:cookie` in a
# signed cookie, so no session is needed; `:fallback` (Django's default) in the cookie while they
# fit, and the rest in the session. The cookie storages need `MessageMiddleware`, which writes the
# cookie on the way out.

const MESSAGE_LEVELS = Dict(:debug => 10, :info => 20, :success => 25, :warning => 30, :error => 40)
const DEFAULT_MESSAGE_TAGS = Dict(10 => "debug", 20 => "info", 25 => "success", 30 => "warning", 40 => "error")
const MESSAGE_SESSION_KEY = "_messages"
const MESSAGE_COOKIE = "messages"
const MESSAGE_COOKIE_MAX = 2048          # bytes, as Django's CookieStorage: browsers drop big cookies

struct Message
    level::Int
    message::String
    safe::Bool              # made with mark_safe / format_html: rendered as HTML, not escaped
    extra_tags::String
end
Message(level, message; extra_tags = "") =
    Message(message_level(level), display_string(message), message isa SafeString, string(extra_tags))
Base.print(io::IO, m::Message) = print(io, m.message)
Base.show(io::IO, m::Message) = print(io, "Message(level=", m.level, ", message=", repr(m.message), ")")   # (Django's repr)

"""
A message that can't be stored (Django's MessageFailure): no SessionMiddleware for the session
storage, no MessageMiddleware for the cookie ones. `fail_silently = true` drops the message instead.
"""
struct MessageFailure <: Exception
    msg::String
end
Base.showerror(io::IO, e::MessageFailure) = print(io, "MessageFailure: ", e.msg)
"The levels by name, for templates: `{% if m.level == DEFAULT_MESSAGE_LEVELS.ERROR %}` (Django's context processor)."
const DEFAULT_MESSAGE_LEVELS = Dict("DEBUG" => 10, "INFO" => 20, "SUCCESS" => 25, "WARNING" => 30, "ERROR" => 40)
Base.:(==)(a::Message, b::Message) = a.level == b.level && a.message == b.message && a.extra_tags == b.extra_tags
Base.hash(m::Message, h::UInt) = hash((m.level, m.message, m.extra_tags), h)
display_string(m::Message) = m.message
__html__(m::Message) = m.safe ? m.message : nothing
"The name of a level in templates: MESSAGE_TAGS, else the built-in names."
function level_tag(level::Integer)
    tags = get(settings, :MESSAGE_TAGS, nothing)
    tags !== nothing && haskey(tags, level) && return string(tags[level])
    get(DEFAULT_MESSAGE_TAGS, level, "")
end
tattr(m::Message, ::Val{:level_tag}) = level_tag(m.level)
tattr(m::Message, ::Val{:tags}) = strip(m.extra_tags * " " * level_tag(m.level))
tattr(m::Message, ::Val{:extra_tags}) = m.extra_tags

message_level(l::Integer) = Int(l)
message_level(l::Symbol) = get(() -> throw(ArgumentError("unknown message level :$l; use :debug, :info, :success, :warning, :error or a number")),
                               MESSAGE_LEVELS, l)
message_level(l::AbstractString) = message_level(Symbol(l))

"The lowest level stored for this request: `set_level!`, else MESSAGE_LEVEL (info)."
get_level(req::Request) = get(req.meta, :message_level, message_level(something(get(settings, :MESSAGE_LEVEL, nothing), 20)))::Int
"Store messages of `level` and up for the rest of this request (`set_level!(req, :debug)` to keep debug messages)."
set_level!(req::Request, level) = (req.meta[:message_level] = message_level(level); nothing)

message_dict(m::Message) = (d = Dict{String,Any}("level" => m.level, "message" => m.message);
                            m.safe && (d["safe"] = true); isempty(m.extra_tags) || (d["tags"] = m.extra_tags); d)
function message_from_dict(d)
    l = d["level"]
    Message(l isa Integer ? Int(l) : message_level(string(l)), string(d["message"]), get(d, "safe", false) === true,
            string(get(d, "tags", "")))
end

storage_kind() = something(get(settings, :MESSAGE_STORAGE, nothing), :session)

# the cookie storages: MessageMiddleware puts this in req.meta, message! and get_messages use it
mutable struct CookieMessages
    incoming::Union{Nothing,Vector{Message}}    # read lazily: the cookie's (and for :fallback, the session's)
    added::Vector{Message}
    used::Bool
end

function incoming!(req::Request, st::CookieMessages)
    st.incoming === nothing || return st.incoming
    msgs = Message[]
    raw = get(req.COOKIES, MESSAGE_COOKIE, nothing)
    if raw !== nothing
        try
            append!(msgs, message_from_dict.(signing_loads(raw; salt = "juango.messages")))
        catch e
            e isa Union{BadSignature,SignatureExpired,ArgumentError,KeyError} || rethrow()
        end
    end
    if storage_kind() === :fallback && req.session isa Session
        append!(msgs, message_from_dict.(get(req.session, MESSAGE_SESSION_KEY, Any[])))
    end
    st.incoming = msgs
end

cookie_store(req::Request) = get(req.meta, :message_store, nothing)

"""
    message!(req, level, text; extra_tags = "", fail_silently = false)

Queue a one-time message for the next page that shows `messages`. `level` is `:debug`, `:info`,
`:success`, `:warning`, `:error` or a number (custom levels: see MESSAGE_TAGS). A message made with
`mark_safe` or `format_html` stays safe, so it renders as HTML (a link, an Undo button); any other
text is escaped. An empty message is ignored, as Django's. Without a place to store it (no
SessionMiddleware for session storage, no MessageMiddleware for the cookie ones) it throws
`MessageFailure`, or with `fail_silently = true` does nothing.
"""
function message!(req::Request, level, text; extra_tags = "", fail_silently::Bool = false)
    m = Message(level, text; extra_tags = extra_tags)
    (isempty(m.message) || m.level < get_level(req)) && return nothing
    kind = storage_kind()
    if kind === :session
        s = req.session
        if !(s isa Session)
            fail_silently && return nothing
            throw(MessageFailure("You cannot add messages without installing SessionMiddleware (or MESSAGE_STORAGE = :cookie with MessageMiddleware)"))
        end
        msgs = collect(Any, get(s, MESSAGE_SESSION_KEY, Any[]))
        push!(msgs, message_dict(m))
        s[MESSAGE_SESSION_KEY] = msgs
    else
        st = cookie_store(req)
        if st === nothing
            fail_silently && return nothing
            throw(MessageFailure("You cannot add messages without installing MessageMiddleware (MESSAGE_STORAGE = :$kind)"))
        end
        push!(st.added, m)
    end
    nothing
end

"""
    get_messages(req) -> Vector{Message}

The pending messages, which are then gone (as iterating Django's storage). `peek_messages` reads
them without that.
"""
get_messages(req::Request) = read_messages(req, true)
"The pending messages, left in place for a later `get_messages` or page."
peek_messages(req::Request) = read_messages(req, false)
"Whether there are messages waiting (without loading the session when nothing could be there)."
has_messages(req::Request) = !isempty(peek_messages(req))

function read_messages(req::Request, consume::Bool)
    if storage_kind() === :session
        s = req.session
        s isa Session || return Message[]
        raw = consume ? pop!(s, MESSAGE_SESSION_KEY, Any[]) : get(s, MESSAGE_SESSION_KEY, Any[])
        return Message[message_from_dict(m) for m in raw]
    end
    st = cookie_store(req)
    st === nothing && return Message[]
    msgs = vcat(incoming!(req, st), st.added)
    if consume
        st.used = true
        st.incoming = Message[]
        empty!(st.added)
    end
    msgs
end

"""
    MessageMiddleware

Needed for `MESSAGE_STORAGE = :cookie` or `:fallback`: writes the messages still to show into the
signed `messages` cookie (and, for `:fallback`, what doesn't fit into the session). Put it after
SessionMiddleware.
"""
function MessageMiddleware(get_response)
    function (req::Request)
        storage_kind() === :session && return get_response(req)
        st = CookieMessages(nothing, Message[], false)
        req.meta[:message_store] = st
        resp = get_response(req)
        had_cookie = haskey(req.COOKIES, MESSAGE_COOKIE)
        # what's left: unread incoming ones (if nothing read them) and any added since
        remaining = vcat(st.incoming === nothing ? (st.used ? Message[] : incoming!(req, st)) : st.incoming, st.added)
        st.incoming === nothing && !had_cookie && isempty(st.added) && return resp     # nothing read, nothing to change
        store_cookie_messages!(req, resp, remaining, had_cookie)
        resp
    end
end

function store_cookie_messages!(req::Request, resp::HttpResponse, msgs::Vector{Message}, had_cookie::Bool)
    fallback = storage_kind() === :fallback
    s = req.session
    in_session = Message[]
    keep = copy(msgs)
    value = ""
    while !isempty(keep)
        value = signing_dumps(message_dict.(keep); salt = "juango.messages")
        ncodeunits(value) <= MESSAGE_COOKIE_MAX && break
        # too big for a cookie: the newest go to the session (fallback), or the oldest are dropped
        if fallback
            pushfirst!(in_session, pop!(keep))
        else
            popfirst!(keep)
            log!("juango.messages", :warning, "Messages dropped: they don't fit in the messages cookie"; request = req)
        end
    end
    # (as Django's CookieStorage: the session cookie's domain, Secure, HttpOnly and SameSite settings)
    if isempty(keep)
        had_cookie && delete_cookie!(resp, MESSAGE_COOKIE; domain = settings.SESSION_COOKIE_DOMAIN, samesite = settings.SESSION_COOKIE_SAMESITE)
    else
        set_cookie!(resp, MESSAGE_COOKIE, value; domain = settings.SESSION_COOKIE_DOMAIN, secure = settings.SESSION_COOKIE_SECURE,
                    httponly = settings.SESSION_COOKIE_HTTPONLY, samesite = settings.SESSION_COOKIE_SAMESITE)
    end
    if fallback && s isa Session
        if isempty(in_session)
            haskey(s, MESSAGE_SESSION_KEY) && delete!(s, MESSAGE_SESSION_KEY)
        else
            s[MESSAGE_SESSION_KEY] = Any[message_dict(m) for m in in_session]
        end
    end
    nothing
end

"Lazy messages for templates: only consumed when actually iterated."
mutable struct LazyMessages
    req::Request
    loaded::Union{Nothing,Vector{Message}}
end
load!(lm::LazyMessages) = (lm.loaded === nothing && (lm.loaded = get_messages(lm.req)); lm.loaded)
truthy(lm::LazyMessages) = lm.loaded !== nothing ? !isempty(lm.loaded) : has_messages(lm.req)
Base.iterate(lm::LazyMessages, st...) = iterate(load!(lm), st...)
Base.length(lm::LazyMessages) = length(load!(lm))
to_iterable(lm::LazyMessages) = load!(lm)

"""
`using Juango.Messages` for Django's shortcuts: `success!(req, "Saved.")`, `info!`, `warning!`,
`error!` and `debug!`, which take `message!`'s keywords. They're kept out of Juango's exports
because the names are short and common.
"""
module Messages
import ..Juango: message!, Request, set_level!, get_level
export debug!, info!, success!, warning!, error!, set_level!, get_level
debug!(req::Request, text; kw...) = message!(req, :debug, text; kw...)
info!(req::Request, text; kw...) = message!(req, :info, text; kw...)
success!(req::Request, text; kw...) = message!(req, :success, text; kw...)
warning!(req::Request, text; kw...) = message!(req, :warning, text; kw...)
error!(req::Request, text; kw...) = message!(req, :error, text; kw...)
end

register_check!(tags = [:messages]) do
    k = storage_kind()
    k === :session && return CheckMessage[]
    k in (:cookie, :fallback) || return [CheckMessage(:error, "MESSAGE_STORAGE must be :session, :cookie or :fallback, not $(repr(k))."; id = "messages.E002")]
    any(m -> m === MessageMiddleware, settings.MIDDLEWARE) ? CheckMessage[] :
        [CheckMessage(:error, "MESSAGE_STORAGE = :$k needs MessageMiddleware in MIDDLEWARE (after SessionMiddleware)."; id = "messages.E001")]
end
