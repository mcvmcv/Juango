# Streaming responses, server-sent events and WebSockets ----------------------------------------------------
#
#     big_csv(req) = StreamingHttpResponse(content_type = "text/csv") do io
#         for row in rows; println(io, join(row, ",")); end        # each write goes out as it happens
#     end
#     download(req; name) = FileResponse(joinpath(REPORTS, name); as_attachment = true)
#     ticks(req) = EventStreamResponse() do io
#         for i in 1:10; write(io, sse_event(i; event = "tick")); sleep(1); end
#     end
#     chat = websocket() do ws, req
#         for msg in ws; ws_send(ws, "you said: " * String(msg)); end
#     end
#     urlpatterns = [path("big.csv", big_csv), path("ws/chat/", chat)]
#
# A streaming response's body is produced while it is sent, so it never sits in memory whole.
# The test client and `text(resp)` read it to the end. `runserver` serves each connection in its
# own task; start Julia with `-t auto` and they run on all cores.

"Chunks to send: an iterable of strings/bytes, or a function `io -> ...` that writes them."
struct StreamBody
    source::Any
    locals::Vector{Pair{Symbol,Any}}      # the view's language and time zone, restored while streaming
end

const STREAM_LOCALS = (:juango_language, :juango_timezone, :juango_localtime_off)
snapshot_locals() = Pair{Symbol,Any}[k => task_local_storage()[k] for k in STREAM_LOCALS if haskey(task_local_storage(), k)]

"An `IO` whose every write is passed straight on as one chunk."
struct ChunkIO{F} <: IO
    f::F
end
function Base.unsafe_write(io::ChunkIO, p::Ptr{UInt8}, n::UInt)
    n == 0 || io.f(unsafe_wrap(Array, p, Int(n)) |> copy)
    Int(n)
end
Base.write(io::ChunkIO, b::UInt8) = (io.f(UInt8[b]); 1)
Base.isopen(::ChunkIO) = true
Base.iswritable(::ChunkIO) = true
Base.isreadable(::ChunkIO) = false
Base.flush(::ChunkIO) = nothing

chunk_bytes(x::AbstractVector{UInt8}) = Vector{UInt8}(x)
chunk_bytes(x) = Vector{UInt8}(codeunits(string(x)))

"Call `f(bytes)` for each chunk of a streaming body, in the view's language and time zone."
function each_chunk(f, sb::StreamBody)
    tls = task_local_storage()
    old = Pair{Symbol,Any}[k => get(tls, k, nothing) for (k, _) in sb.locals]
    for (k, v) in sb.locals
        tls[k] = v
    end
    try
        if sb.source isa Function
            sb.source(ChunkIO(f))
        else
            for c in sb.source
                b = chunk_bytes(c)
                isempty(b) || f(b)
            end
        end
    finally
        for (k, v) in old
            v === nothing ? delete!(tls, k) : (tls[k] = v)
        end
    end
    nothing
end

"Read a streaming response to the end into `resp.body` (the test client and `text` do this)."
function consume_stream!(r::HttpResponse)
    r.stream === nothing && return r
    buf = IOBuffer()
    each_chunk(b -> write(buf, b), r.stream)
    r.body = take!(buf)
    r.stream = nothing
    r
end
is_streaming(r::HttpResponse) = r.stream !== nothing

"""
    StreamingHttpResponse(chunks; status=200, content_type="text/html; charset=utf-8", headers=[])
    StreamingHttpResponse(; content_type=...) do io ... end

A response whose body is sent as it is produced: `chunks` is any iterable of strings or
bytes (a generator, a `Channel`, ...), or a function that `write`s to the `io` it is given.
It goes out with chunked transfer encoding unless you set Content-Length.
"""
function StreamingHttpResponse(chunks; status::Integer = 200, content_type = "text/html; charset=utf-8",
                               headers = Pair{String,String}[])
    r = HttpResponse(""; status = status, content_type = content_type, headers = headers)
    r.stream = StreamBody(chunks, snapshot_locals())
    r
end

"""
    FileResponse(path; as_attachment=false, filename=basename(path), content_type=<from the extension>)

Stream a file from disk in 64 KiB blocks, with Content-Length and Content-Disposition
(`attachment` makes browsers download it rather than show it).
"""
function FileResponse(path::AbstractString; as_attachment::Bool = false, filename = basename(path),
                      content_type = nothing, status::Integer = 200, headers = Pair{String,String}[])
    isfile(path) || throw(Http404("File '$(basename(path))' not found"))
    ct = something(content_type, get(MIME_TYPES, lowercase(splitext(path)[2]), "application/octet-stream"))
    writer = function (io)
        open(path) do f
            while !eof(f)
                write(io, read(f, 65536))
            end
        end
    end
    r = StreamingHttpResponse(writer; status = status, content_type = ct, headers = headers)
    setheader!(r, "Content-Length", string(filesize(path)))
    setheader!(r, "Content-Disposition", content_disposition(filename; attachment = as_attachment))
    r
end

function content_disposition(filename; attachment = false)
    kind = attachment ? "attachment" : "inline"
    name = string(filename)
    isempty(name) && return kind
    if all(c -> isascii(c) && isprint(c), name)
        return "$kind; filename=\"$(replace(name, "\\" => "\\\\", "\"" => "\\\""))\""
    end
    encoded = join(c in UInt8('0'):UInt8('9') || c in UInt8('A'):UInt8('Z') || c in UInt8('a'):UInt8('z') ||
                   c in codeunits("!#\$&+-.^_`|~") ? string(Char(c)) : "%" * uppercase(string(c, base = 16, pad = 2))
                   for c in codeunits(name))
    "$kind; filename*=UTF-8''$encoded"
end

# --- server-sent events -------------------------------------------------------------------------------------

"""
    sse_event(data; event=nothing, id=nothing, retry=nothing) -> String

One server-sent event. `data` that isn't a string is sent as JSON; multi-line data becomes
several `data:` lines, as the format requires.
"""
function sse_event(data; event = nothing, id = nothing, retry = nothing)
    io = IOBuffer()
    event === nothing || print(io, "event: ", event, "\n")
    id === nothing || print(io, "id: ", id, "\n")
    retry === nothing || print(io, "retry: ", Int(retry), "\n")
    s = data isa AbstractString ? data : JSON.json(data)
    for line in split(s, r"\r\n|\r|\n")
        print(io, "data: ", line, "\n")
    end
    print(io, "\n")
    String(take!(io))
end
"A comment line: keeps an idle event stream from being closed by proxies."
sse_comment(text = "") = ": " * replace(string(text), '\n' => ' ') * "\n\n"

"""
    EventStreamResponse(chunks)  /  EventStreamResponse() do io ... end

A `StreamingHttpResponse` for server-sent events (`text/event-stream`, not cached or
buffered by proxies). Write `sse_event(...)` strings to it. In the browser:
`new EventSource("/events/").onmessage = e => ...`.
"""
function EventStreamResponse(chunks; headers = Pair{String,String}[], kw...)
    hs = vcat(Pair{String,String}["Cache-Control" => "no-cache", "X-Accel-Buffering" => "no"],
              Pair{String,String}[string(k) => string(v) for (k, v) in headers])
    StreamingHttpResponse(chunks; content_type = "text/event-stream; charset=utf-8", headers = hs, kw...)
end

# --- WebSockets ---------------------------------------------------------------------------------------------

"A URL pattern's view that answers WebSocket handshakes; see `websocket`."
struct WebSocketView
    handler::Any
    subprotocols::Vector{String}
end

"""
    websocket(handler; subprotocols=String[]) -> view

A view for WebSocket connections. `handler(ws, req)` runs once the handshake is done (with
the URL's parameters as keywords, `handler(ws, req; room)`, when the pattern has any), with sessions and `req.user` loaded by the middleware as usual; the connection
closes when it returns. Read with `for msg in ws` or `ws_receive(ws)`, write with
`ws_send(ws, msg)`. Text frames arrive as `String`, binary ones as `Vector{UInt8}`.

The browser's `Origin` must be this host or in CSRF_TRUSTED_ORIGINS (so other sites can't
use a visitor's session). Ordinary requests to the URL get 426 Upgrade Required. Wrapping
with `login_required` etc. works: a refused handshake gets the redirect or 403 instead.
"""
websocket(handler; subprotocols = String[]) = WebSocketView(handler, String[string(s) for s in subprotocols])

function (v::WebSocketView)(req::Request; kwargs...)
    if get(req.meta, :websocket_upgrade, false)
        req.meta[:websocket_accept] = (v, kwargs)
        return HttpResponse(""; status = 101)
    end
    r = HttpResponse("<h1>426 Upgrade Required</h1><p>This URL takes WebSocket connections.</p>"; status = 426)
    setheader!(r, "Upgrade", "websocket")
    setheader!(r, "Connection", "Upgrade")
    r
end

"Send a text (`String`) or binary (`Vector{UInt8}`) message; other values go as JSON text."
ws_send(ws, msg::Union{AbstractString,AbstractVector{UInt8}}) = HTTP.WebSockets.send(ws, msg)
ws_send(ws, msg) = HTTP.WebSockets.send(ws, JSON.json(msg))
"The next message (`String` or `Vector{UInt8}`); throws when the peer has closed the connection."
ws_receive(ws) = HTTP.WebSockets.receive(ws)
ws_close(ws) = close(ws)
"Whether the connection is still open."
ws_isopen(ws) = !HTTP.WebSockets.isclosed(ws)

"The first of the view's subprotocols that the client offered, if any."
function select_subprotocol(req::Request, protos)
    isempty(protos) && return nothing
    offered = strip.(split(header(req, "sec-websocket-protocol", ""), ','))
    for p in protos
        p in offered && return p
    end
    nothing
end

"Whether a WebSocket handshake's Origin may use this site (same host, or CSRF_TRUSTED_ORIGINS)."
function websocket_origin_allowed(req::Request)
    origin = header(req, "origin")
    origin === nothing && return true          # not a browser
    origin == request_origin(req) || origin in settings.CSRF_TRUSTED_ORIGINS     # same scheme too, as for CSRF
end
