# Development server -------------------------------------------------------------------------------

function from_http(hreq::HTTP.Request, remote = "127.0.0.1")
    headers = Dict{String,String}()
    for (k, v) in hreq.headers
        lk = lowercase(k)
        headers[lk] = haskey(headers, lk) ? headers[lk] * (lk == "cookie" ? "; " : ", ") * v : v
    end
    Request(hreq.method, hreq.target; headers = headers, body = hreq.body, remote_addr = remote)
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
    line = "[$ts] \"$(req.method) $(full_path(req)) HTTP/1.1\" $(resp.status) $(length(resp.body))"
    color = resp.status >= 500 ? :red : resp.status >= 400 ? :yellow : resp.status >= 300 ? :cyan : :normal
    printstyled(stderr, line, "\n"; color = color)
    flush(stderr)
end

"Handler function suitable for `HTTP.serve`."
function http_handler(hreq::HTTP.Request)
    req = from_http(hreq)
    resp = handle_request(req)
    log_request(req, resp)
    to_http(resp)
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
        HTTP.serve(http_handler, host, Int(port); verbose = false)
    else
        HTTP.serve!(http_handler, host, Int(port); verbose = false)
    end
end
