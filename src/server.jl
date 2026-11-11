# Development server -------------------------------------------------------------------------------

function from_http(hreq::HTTP.Request, remote = "127.0.0.1"; body = hreq.body)
    headers = Dict{String,String}()
    for (k, v) in hreq.headers
        lk = lowercase(k)
        headers[lk] = haskey(headers, lk) ? headers[lk] * (lk == "cookie" ? "; " : ", ") * v : v
    end
    Request(hreq.method, hreq.target; headers = headers, body = body isa AbstractVector{UInt8} ? body : UInt8[], remote_addr = remote)
end

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

function remote_ip(stream)
    try
        string(first(Sockets.getpeername(stream)))
    catch
        "127.0.0.1"
    end
end

body_allowed(status) = status >= 200 && status != 204 && status != 304

"Write a response to a server stream: buffered bodies with Content-Length, streaming ones chunk by chunk."
function write_response(stream::HTTP.Stream, req::Request, resp::HttpResponse)
    out = stream.message.response
    out.status = resp.status
    for (k, v) in resp.headers
        push!(out.headers, k => v)
    end
    for c in resp.cookies
        push!(out.headers, "Set-Cookie" => c)
    end
    if !is_streaming(resp)
        body_allowed(resp.status) && getheader(resp, "Content-Length") === nothing &&
            push!(out.headers, "Content-Length" => string(length(resp.body)))
        HTTP.startwrite(stream)
        isempty(resp.body) || write(stream, resp.body)
    else
        if getheader(resp, "Content-Length") === nothing
            stream.message.version >= v"1.1" ? push!(out.headers, "Transfer-Encoding" => "chunked") :
                                               push!(out.headers, "Connection" => "close")
        end
        HTTP.startwrite(stream)
        try
            each_chunk(b -> (write(stream, b); nothing), resp.stream)
        catch e
            # The status line has gone out, so the client just sees the body end early.
            e isa Union{Base.IOError,EOFError} || @error "Error while streaming $(req.path)" exception = (e, catch_backtrace())
        end
    end
    nothing
end

"""
Stream handler for `HTTP.listen`: like `http_handler`, plus streaming responses sent as they
are produced and WebSocket handshakes for `websocket` views.
"""
function stream_handler(stream::HTTP.Stream)
    hreq = stream.message                     # the server has read the head already
    req = from_http(hreq, remote_ip(stream); body = read(stream))
    upgrade = HTTP.WebSockets.isupgrade(hreq)
    upgrade && (req.meta[:websocket_upgrade] = true)
    # HTTP.jl runs each connection as a task on one thread; with `julia -t N` the views run on all N.
    resp = Threads.nthreads() > 1 ? Base.fetch(Threads.@spawn handle_request(req)) : handle_request(req)
    accept = get(req.meta, :websocket_accept, nothing)
    if upgrade && accept !== nothing && resp.status == 101
        if websocket_origin_allowed(req)
            log_request(req, resp)
            view, kwargs = accept
            try
                proto = select_subprotocol(req, view.subprotocols)
                proto === nothing || HTTP.setheader(stream, "Sec-WebSocket-Protocol" => proto)
                HTTP.WebSockets.upgrade(stream; suppress_close_error = true) do ws
                    isempty(kwargs) ? view.handler(ws, req) : view.handler(ws, req; kwargs...)
                end
            catch e
                e isa Union{Base.IOError,EOFError,HTTP.WebSockets.WebSocketError} ||
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
    runserver(host="127.0.0.1", port=8000; block=true)

Start the development server. With `block=false` the server runs in the
background and the `HTTP.Server` is returned (stop it with `close(server)`).
"""
function runserver(host::AbstractString = "127.0.0.1", port::Integer = 8000; block::Bool = true, quiet = false)
    if !quiet
        println(Dates.format(now(), "U dd, yyyy - HH:MM:SS"))
        println("Juango version $VERSION_STRING (Julia $(VERSION)), DEBUG = $(settings.DEBUG)")
        println("Starting development server at http://$host:$port/")
        println("Quit the server with CONTROL-C.")
        flush(stdout)
    end
    if block
        HTTP.listen(stream_handler, host, Int(port))
    else
        HTTP.listen!(stream_handler, host, Int(port))
    end
end
