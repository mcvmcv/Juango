# htmx (https://htmx.org) support, in the manner of django-htmx -------------------------------------
#
#     # base.html: <head>{% htmx_script %}</head>   (htmx itself, the CSRF header, 422 swapping)
#     function post_list(req)
#         qs = filter(Post; title__icontains = get(req.GET, "q", ""))
#         render(req, "posts.html", Dict("posts" => qs); htmx_partial = "results")
#     end
#
# `req.htmx` reads the HX-* request headers; `is_htmx(req)` says whether htmx sent the request.
# Reading either marks the response `Vary: HX-Request` (through HtmxMiddleware), so caches keep
# the partial and the whole page apart. Response helpers (`hx_redirect`, `hx_trigger`, ...) set
# the HX-* response headers, and messages queued during an htmx request are sent along as an
# out-of-band swap into `<div id="messages">`.

"""
    HtmxDetails

What `req.htmx` returns: the request's htmx headers. In templates `{% if request.htmx %}` is true
for htmx requests; in Julia use `is_htmx(req)` or `req.htmx.request`.

- `request`: htmx sent the request (`HX-Request`)
- `boosted`: by an element with `hx-boost`
- `current_url`, `current_url_abs_path`: the browser's URL (and its path and query, for this site)
- `target`, `trigger`, `trigger_name`: the ids (and name) of the target and triggering elements
- `history_restore_request`: htmx wants the whole page to restore its history
- `prompt`: the user's answer to `hx-prompt`
"""
struct HtmxDetails
    req::Request
end

"An htmx request header (without `HX-`), decoded when htmx URI-encoded it (non-ASCII values)."
function hx_header(req::Request, name::AbstractString)
    v = header(req, "hx-" * name)
    v !== nothing && header(req, "hx-" * name * "-uri-autoencoded") == "true" ? URIs.unescapeuri(v) : v
end

function Base.getproperty(h::HtmxDetails, s::Symbol)
    req = getfield(h, :req)
    s === :req && return req
    s === :request && return hx_header(req, "request") == "true"
    s === :boosted && return hx_header(req, "boosted") == "true"
    s === :history_restore_request && return hx_header(req, "history-restore-request") == "true"
    s === :current_url && return hx_header(req, "current-url")
    if s === :current_url_abs_path
        u = hx_header(req, "current-url")
        u === nothing && return nothing
        uri = URIs.URI(u)
        (isempty(uri.host) || uri.host == split(get_host(req), ':')[1]) || return nothing    # another site
        return (isempty(uri.path) ? "/" : uri.path) * (isempty(uri.query) ? "" : "?" * uri.query)
    end
    s in (:target, :trigger, :trigger_name, :prompt) && return hx_header(req, replace(string(s), '_' => '-'))
    throw(ArgumentError("HtmxDetails has no property $s"))
end
Base.propertynames(::HtmxDetails, private::Bool = false) =
    (:request, :boosted, :current_url, :current_url_abs_path, :target, :trigger, :trigger_name, :history_restore_request, :prompt)
tattr(h::HtmxDetails, ::Val{S}) where {S} = S in propertynames(h) ? getproperty(h, S) : NOTFOUND
truthy(h::HtmxDetails) = h.request
Base.show(io::IO, h::HtmxDetails) = print(io, "HtmxDetails(request = ", h.request, ")")

"The request's htmx details (marks the response `Vary: HX-Request`)."
function htmx_details(req::Request)
    getfield(req, :meta)[:htmx_vary] = true
    HtmxDetails(req)
end

"""
    is_htmx(req; boosted = true) -> Bool

Whether htmx sent the request. `boosted = false` leaves out `hx-boost` requests and history
restores, which want the whole page. Marks the response `Vary: HX-Request`.
"""
function is_htmx(req::Request; boosted::Bool = true)
    h = htmx_details(req)
    h.request && (boosted || !(h.boosted || h.history_restore_request))
end

# --- response headers ------------------------------------------------------------------------------------

"Status code that tells htmx to stop polling (`hx-trigger=\"every 2s\"`)."
const HTMX_STOP_POLLING = 286

"""
    hx_redirect(url) -> HttpResponse

Make htmx load `url` as a full page (`HX-Redirect`). A plain 302 would be followed by the
browser's XMLHttpRequest and its result swapped into the target.
"""
hx_redirect(url) = (r = HttpResponse(""); setheader!(r, "HX-Redirect", string(url)); r)

"`hx_refresh()`: make htmx reload the whole page (`HX-Refresh: true`)."
hx_refresh() = (r = HttpResponse(""); setheader!(r, "HX-Refresh", "true"); r)

"""
    hx_location(path; source, event, handler, target, swap, values, headers, select) -> HttpResponse

Make htmx load `path` with an AJAX request and push it to the history, without a full page
load (`HX-Location`). The keywords are htmx's (`target = "#main"`, ...).
"""
function hx_location(path; kw...)
    r = HttpResponse("")
    setheader!(r, "HX-Location", isempty(kw) ? string(path) :
               JSON.json(merge(Dict{String,Any}("path" => string(path)), Dict{String,Any}(string(k) => v for (k, v) in kw))))
    r
end

"`hx_stop_polling(resp = HttpResponse(\"\"))`: answer with 286, which makes htmx stop polling."
hx_stop_polling(resp::HttpResponse = HttpResponse("")) = (resp.status = HTMX_STOP_POLLING; resp)

"`hx_push_url(resp, url)`: push `url` (or `false`: nothing) to the browser history (`HX-Push-Url`)."
hx_push_url(resp::HttpResponse, url) = (setheader!(resp, "HX-Push-Url", url === false ? "false" : string(url)); resp)
"`hx_replace_url(resp, url)`: replace the browser's current URL (`HX-Replace-Url`)."
hx_replace_url(resp::HttpResponse, url) = (setheader!(resp, "HX-Replace-Url", url === false ? "false" : string(url)); resp)
"`hx_retarget(resp, selector)`: swap the response into another element (`HX-Retarget`)."
hx_retarget(resp::HttpResponse, selector) = (setheader!(resp, "HX-Retarget", string(selector)); resp)
"`hx_reswap(resp, swap)`: swap it another way, e.g. `\"outerHTML\"` or `\"beforeend show:top\"` (`HX-Reswap`)."
hx_reswap(resp::HttpResponse, swap) = (setheader!(resp, "HX-Reswap", string(swap)); resp)
"`hx_reselect(resp, selector)`: swap in only part of the response (`HX-Reselect`)."
hx_reselect(resp::HttpResponse, selector) = (setheader!(resp, "HX-Reselect", string(selector)); resp)

"""
    hx_trigger(resp, events; after = :receive) -> resp

Trigger client-side events when htmx gets the response: `events` is an event name, a vector of
names, or a dict of name => detail (anything JSON can encode). `after = :settle` or `:swap`
triggers them after that step instead (`HX-Trigger-After-Settle`, ...). Events already set on
the response are kept.
"""
function hx_trigger(resp::HttpResponse, events; after::Symbol = :receive)
    name = after === :receive ? "HX-Trigger" : after === :settle ? "HX-Trigger-After-Settle" :
           after === :swap ? "HX-Trigger-After-Swap" : throw(ArgumentError("hx_trigger: after must be :receive, :settle or :swap"))
    evs = Dict{String,Any}()
    old = getheader(resp, name)
    if old !== nothing
        if startswith(strip(old), "{")
            merge!(evs, JSON.parse(old))
        else
            foreach(e -> evs[strip(e)] = nothing, split(old, ','))
        end
    end
    if events isa AbstractDict
        foreach(((k, v),) -> evs[string(k)] = v, pairs(events))
    else
        foreach(e -> evs[string(e)] = nothing, events isa Union{AbstractString,Symbol} ? [events] : events)
    end
    setheader!(resp, name, all(isnothing, values(evs)) ? join(sort!(collect(keys(evs))), ", ") : JSON.json(evs))
    resp
end

"""
    form_status(form; invalid = 422) -> Int

The status for re-rendering a form: 422 when it was submitted and has errors, else 200.
`{% htmx_script %}` configures htmx to swap 422 responses, so the form partial with its errors
replaces the form, while the status still tells tests and caches the submission failed.
"""
form_status(form; invalid::Integer = 422) = (form.data !== nothing && !is_valid(form)) ? Int(invalid) : 200

# --- middleware: Vary and messages --------------------------------------------------------------------

"""
    HtmxMiddleware

In the default MIDDLEWARE (keep it after SessionMiddleware). Adds `Vary: HX-Request` to the
responses of views that looked at `req.htmx`, and after an htmx request appends the messages
still queued to the HTML response as an out-of-band swap (`HTMX_OOB_MESSAGES`, default true;
the markup is `juango/htmx_messages.html`, which replaces `<div id="messages">`).
"""
function HtmxMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        meta = getfield(req, :meta)
        get(meta, :htmx_vary, false) === true && patch_vary!(resp, "HX-Request")
        if hx_header(req, "request") == "true" && get(settings, :HTMX_OOB_MESSAGES, true) === true
            append_oob_messages!(req, resp)
        end
        resp
    end
end

function append_oob_messages!(req::Request, resp::HttpResponse)
    (200 <= resp.status < 300 && resp.status != 204 && !is_streaming(resp)) || return
    occursin("text/html", something(getheader(resp, "Content-Type"), "")) || return
    s = req.session
    (s isa Session && !isempty(get(s, "_messages", Any[]))) || return
    html = render(get_template("juango/htmx_messages.html"), Dict{String,Any}("messages" => get_messages(req)))
    append!(resp.body, codeunits(html))
    nothing
end

# --- {% htmx_script %} --------------------------------------------------------------------------------

struct HtmxScriptNode <: Node end
tag_htmx_script(p, t) = HtmxScriptNode()

# htmx's default response handling, plus swapping 422 (a form with errors: see form_status)
const HTMX_CONFIG = """{"responseHandling":[{"code":"204","swap":false},{"code":"[23]..","swap":true},""" *
                    """{"code":"422","swap":true},{"code":"[45]..","swap":false,"error":true},{"code":"...","swap":false}]}"""

function render!(io::IO, ::HtmxScriptNode, ctx::Context)
    write(io, "<meta name=\"htmx-config\" content='", HTMX_CONFIG, "'>\n<script src=\"",
          escape_html(static_url("juango/htmx.min.js")), "\" defer></script>")
    tok = lookup(ctx, "csrf_token")
    if !(tok === UNDEF || tok === nothing)
        # every htmx request sends the CSRF token in the header CsrfViewMiddleware reads (with the
        # CSP nonce when SECURE_CSP is set, so a strict policy allows this inline script)
        nonce = isempty(something(get(settings, :SECURE_CSP, nothing), ())) ? UNDEF : lookup(ctx, "csp_nonce")
        write(io, "\n<script", nonce === UNDEF ? "" : " nonce=\"" * escape_html(display_string(nonce)) * "\"", ">document.addEventListener(\"htmx:configRequest\",function(e){e.detail.headers[\"X-CSRFToken\"]=",
              replace(JSON.json(display_string(tok)), "<" => "\\u003c"), "})</script>")
    end
end
register_tag!("htmx_script", tag_htmx_script)
