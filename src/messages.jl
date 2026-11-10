# Messages framework (one-time notifications stored in the session) ---------------------------

struct Message
    level::Symbol
    message::String
end
Base.show(io::IO, m::Message) = print(io, m.message)
tattr(m::Message, ::Val{:tags}) = string(m.level)
tattr(m::Message, ::Val{:level_tag}) = string(m.level)

"""
    message!(req, level, text)

Queue a one-time message for the next page render. `level` is one of `:debug`,
`:info`, `:success`, `:warning`, `:error`. Templates read them via `messages`.
"""
function message!(req::Request, level::Symbol, text)
    s = req.session
    s isa Session || error("messages require SessionMiddleware")
    msgs = collect(Any, get(s, "_messages", Any[]))
    push!(msgs, Dict("level" => string(level), "message" => string(text)))
    s["_messages"] = msgs
    nothing
end

"Pop and return the pending messages."
function get_messages(req::Request)
    s = req.session
    s isa Session || return Message[]
    raw = pop!(s, "_messages", Any[])
    Message[Message(Symbol(m["level"]), m["message"]) for m in raw]
end

"Lazy messages for templates: only consumed when actually iterated."
mutable struct LazyMessages
    req::Request
    loaded::Union{Nothing,Vector{Message}}
end
load!(lm::LazyMessages) = (lm.loaded === nothing && (lm.loaded = get_messages(lm.req)); lm.loaded)
truthy(lm::LazyMessages) = lm.loaded !== nothing ? !isempty(lm.loaded) :
    (lm.req.session isa Session && !isempty(get(lm.req.session, "_messages", Any[])))
Base.iterate(lm::LazyMessages, st...) = iterate(load!(lm), st...)
Base.length(lm::LazyMessages) = length(load!(lm))
to_iterable(lm::LazyMessages) = load!(lm)
