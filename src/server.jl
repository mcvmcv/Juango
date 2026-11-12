# Development server -------------------------------------------------------------------------------

function from_http(hreq::HTTP.Request, remote = "127.0.0.1"; body = body_bytes(hreq.body))
    headers = Dict{String,String}()
    for (k, v) in hreq.headers
        lk = lowercase(k)
        headers[lk] = haskey(headers, lk) ? headers[lk] * (lk == "cookie" ? "; " : ", ") * v : v
    end
    Request(hreq.method, hreq.target; headers = headers, body = body, remote_addr = remote)
end

"A request body (bytes or an HTTP.jl body object) as a `Vector{UInt8}`."
body_bytes(b::Vector{UInt8}) = b
body_bytes(b::AbstractVector{UInt8}) = Vector{UInt8}(b)
body_bytes(b::HTTP.BytesBody) = Vector{UInt8}(b)
body_bytes(::Nothing) = UInt8[]
body_bytes(b) = Vector{UInt8}(codeunits(String(b)))

function to_http(resp::HttpResponse)
    hs = Pair{String,String}[h for h in resp.headers]
    for c in resp.cookies
        push!(hs, "Set-Cookie" => c)
    end
    HTTP.Response(resp.status, hs, resp.body)
end

function log_request(req::Request, resp::HttpResponse)
    ts = Dates.format(now(), "dd/u/yyyy HH:MM:SS")
    size = is_streaming(resp) ? something(getheader(resp, "Content-Length"), "-") : string(length(resp.body))
    line = "[$ts] \"$(req.method) $(full_path(req)) HTTP/1.1\" $(resp.status) $size"
    color = resp.status >= 500 ? :red : resp.status >= 400 ? :yellow : resp.status >= 300 ? :cyan : :normal
    printstyled(stderr, line, "\n"; color = color)
    flush(stderr)
end

"Request handler suitable for `HTTP.serve` (buffers streaming responses; `runserver` uses `stream_handler`)."
function http_handler(hreq::HTTP.Request)
    req = from_http(hreq)
    resp = consume_stream!(handle_request(req))
    log_request(req, resp)
    to_http(resp)
end

"The client's IP address (without the port) for a server stream."
function remote_ip(stream)
    addr = try HTTP.peeraddr(stream) catch; nothing end
    addr === nothing && return "127.0.0.1"
    a = string(addr)                                  # "1.2.3.4:5678" or "[::1]:5678"
    strip(a[1:something(findlast(':', a), lastindex(a) + 1) - 1], ['[', ']'])
end

body_allowed(status) = status >= 200 && status != 204 && status != 304

"""
Write a response to a server stream: buffered bodies with Content-Length, streaming ones
chunk by chunk (HTTP.jl uses chunked encoding on HTTP/1.1 and DATA frames on HTTP/2).
"""
function write_response(stream::HTTP.Stream, req::Request, resp::HttpResponse)
    HTTP.setstatus(stream, resp.status)
    out = stream.response.headers
    for (k, v) in resp.headers
        lowercase(k) == "transfer-encoding" && continue      # HTTP.jl frames the body itself
        HTTP.appendheader(out, k, v)
    end
    for c in resp.cookies
        HTTP.appendheader(out, "Set-Cookie", c)
    end
    if !is_streaming(resp)
        body_allowed(resp.status) && getheader(resp, "Content-Length") === nothing &&
            HTTP.appendheader(out, "Content-Length", string(length(resp.body)))
        HTTP.startwrite(stream)
        isempty(resp.body) || write(stream, resp.body)
    else
        HTTP.startwrite(stream)
        try
            each_chunk(b -> (write(stream, b); nothing), resp.stream)
        catch e
            # The status line has gone out, so the client just sees the body end early.
            e isa Union{Base.IOError,EOFError} || is_disconnect(e) ||
                @error "Error while streaming $(req.path)" exception = (e, catch_backtrace())
        end
    end
    nothing
end

"Whether `e` just means the client went away."
is_disconnect(e) = e isa Union{Base.IOError,EOFError,HTTP.WebSockets.WebSocketError} ||
                   (e isa Exception && occursin(r"closed|reset|broken pipe"i, sprint(showerror, e)))

"""
Stream handler for `HTTP.listen`: like `http_handler`, plus streaming responses sent as they
are produced and WebSocket handshakes for `websocket` views.
"""
function stream_handler(stream::HTTP.Stream; secure::Bool = false)
    hreq = HTTP.startread(stream)
    req = from_http(hreq, remote_ip(stream); body = read(stream))
    secure && (req.meta[:secure] = true)       # served over TLS
    upgrade = HTTP.WebSockets.isupgrade(hreq)
    upgrade && (req.meta[:websocket_upgrade] = true)
    # HTTP.jl runs connections on the :interactive thread pool; views run on the :default pool so
    # slow ones don't hold up the server (start Julia with e.g. `--threads=4,1`).
    resp = Base.fetch(Threads.@spawn :default handle_request(req))
    accept = get(req.meta, :websocket_accept, nothing)
    if upgrade && accept !== nothing && resp.status == 101
        if websocket_origin_allowed(req)
            log_request(req, resp)
            view, kwargs = accept
            try
                proto = select_subprotocol(req, view.subprotocols)
                # Juango checked the origin above (same host or CSRF_TRUSTED_ORIGINS).
                HTTP.WebSockets.upgrade(stream; subprotocols = proto === nothing ? String[] : [proto],
                                        check_origin = (_, _) -> true) do ws
                    isempty(kwargs) ? view.handler(ws, req) : view.handler(ws, req; kwargs...)
                end
            catch e
                is_disconnect(e) ||
                    @error "Error in WebSocket handler for $(req.path)" exception = (e, catch_backtrace())
            end
            return nothing
        end
        resp = HttpResponseForbidden("<h1>403 Forbidden</h1><p>WebSocket origin not allowed.</p>")
    elseif resp.status == 101
        resp = HttpResponseBadRequest("<h1>Bad Request (400)</h1><p>Expected a WebSocket handshake.</p>")
    end
    log_request(req, resp)
    write_response(stream, req, resp)
end

"""
    runserver(host="127.0.0.1", port=8000; block=true, certfile=nothing, keyfile=nothing)

Start the development server. With `block=false` the server runs in the background and the
`HTTP.Server` is returned (stop it with `close(server)`).

It speaks HTTP/1.1, and HTTP/2 to clients that ask for it. Pass `certfile` and `keyfile` (PEM)
to serve HTTPS, where browsers pick HTTP/2. Start Julia with an interactive thread, e.g.
`julia --threads=4,1`, so the server keeps answering while views run on the other threads.
"""
function runserver(host::AbstractString = "127.0.0.1", port::Integer = 8000; block::Bool = true, quiet = false,
                   certfile = nothing, keyfile = nothing)
    (certfile === nothing) == (keyfile === nothing) ||
        throw(ArgumentError("runserver: pass both certfile and keyfile, or neither"))
    scheme = certfile === nothing ? "http" : "https"
    if !quiet
        println(Dates.format(now(), "U dd, yyyy - HH:MM:SS"))
        println("Juango version $VERSION_STRING (Julia $(VERSION)), DEBUG = $(settings.DEBUG)")
        println("Starting development server at $scheme://$(occursin(':', host) ? "[$host]" : host):$port/")
        println("Quit the server with CONTROL-C.")
        flush(stdout)
    end
    server = if certfile === nothing
        HTTP.listen!(stream_handler, host, Int(port))
    else
        config = TLS.Config(; cert_file = string(certfile), key_file = string(keyfile),
                              alpn_protocols = ["h2", "http/1.1"])
        addr = (occursin(':', host) ? "[$host]" : host) * ":$port"
        HTTP.listen!(s -> stream_handler(s; secure = true), TLS.listen("tcp", addr, config))
    end
    block || return server
    try
        wait(server)
    finally
        close(server)
    end
end
