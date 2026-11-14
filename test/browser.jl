# Browser tests for live.js: headless Chromium driven over the DevTools protocol by
# test/browser/live.mjs. Opt-in (they need chromium and node): JUANGO_BROWSER_TESTS=1.
include("setup.jl")

Base.@kwdef mutable struct LiveBrowser <: LiveView
    count::Int = 0
    note::String = ""
    files::Vector{String} = String[]
end
Juango.live_snapshot(::Type{LiveBrowser}) = true
function Juango.handle_event(v::LiveBrowser, name, params)
    name == "inc" && (v.count += 1)
    name == "note" && (v.note = string(get(params, "note", "")))
    name == "drop" && error("dropping the socket on purpose")
    name == "send" && (f = params["file"]; push!(v.files, "$(f.name):$(f.size)"))
    nothing
end

@testset "live.js in a browser (#103)" begin
    write(joinpath(TPL, "live_browser.html"), """
        <!doctype html><html><body>{% liveview %}
        <p id="n">{{ count }}</p><button j-click="inc">+1</button><button j-click="drop">drop</button>
        <form j-change="note" j-debounce="50"><input id="note" name="note" value="{{ note }}"></form><p id="shown">{{ note }}</p>
        <form id="upload" j-submit="send"><input id="file" type="file" name="file"></form><p id="files">{{ files|join:"," }}</p>
        {% endliveview %}</body></html>""")
    old_urls = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = [live("browser/", LiveBrowser, "live_browser.html")], DEBUG = true)
    port = let s = Juango.Sockets.listen(Juango.Sockets.localhost, 0)
        p = Int(Juango.Sockets.getsockname(s)[2]); close(s); p
    end
    server = runserver("127.0.0.1", port; block = false, quiet = true)
    upload = joinpath(mktempdir(), "sample.txt")
    write(upload, "hello from the browser\n" ^ 3000)             # ~70 KB: more than one chunk
    try
        out = read(`node --experimental-websocket $(joinpath(@__DIR__, "browser", "live.mjs")) http://127.0.0.1:$port $upload`, String)
        r = Juango.JSON.parse(strip(split(strip(out), '\n')[end]))
        (haskey(r, "error") || get(ENV, "SHOWBROWSER", "") != "") && @info "browser test" r
        @test get(r, "loaded", false) === true && get(r, "connected", false) === true
        @test get(r, "click", false) === true
        @test get(r, "typing", false) === true && get(r, "focus", false) === true
        @test get(r, "reconnected", false) === true && get(r, "reconnect_keeps_state", false) === true && get(r, "after_reconnect", false) === true
        @test get(r, "upload", false) === true && get(r, "files_text", "") == "sample.txt:$(filesize(upload))"
    finally
        close(server)
        configure!(ROOT_URLCONF = old_urls)
        rm(joinpath(TPL, "live_browser.html"); force = true)
    end
end
