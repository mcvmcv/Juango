# Flat pages -------------------------------------------------------------------------------------------------
#
# Simple pages kept in the database and edited in the admin ("About", "Terms"...). Add
# "juango.flatpages" to INSTALLED_APPS, then either
#
#     MIDDLEWARE = vcat(settings.MIDDLEWARE, [FlatpageFallbackMiddleware])    # any 404 tries a flat page
#     path("pages/", flatpage_urls())                                          # or under a prefix
#
# A page renders `template_name` (default "flatpages/default.html") with `flatpage` in the
# context; its `content` is HTML, inserted unescaped.

@model struct FlatPage
    url = CharField(max_length = 100, db_index = true, help_text = "Example: “/about/contact/”. Make sure to have leading and trailing slashes.")
    title = CharField(max_length = 200)
    content = TextField(blank = true)
    template_name = CharField(max_length = 70, blank = true,
                              help_text = "Example: “flatpages/contact_page.html”. If this isn’t provided, “flatpages/default.html” is used.")
    registration_required = BooleanField(default = false, help_text = "If this is checked, only logged-in users will be able to view the page.")
    Meta(table = "juango_flatpage", ordering = ["url"], verbose_name = "flat page", verbose_name_plural = "flat pages")
end
Base.show(io::IO, p::FlatPage) = print(io, p.url, " -- ", p.title)
get_absolute_url(p::FlatPage) = p.url

const FLATPAGES_APP = App("flatpages"; name = "juango.flatpages", verbose_name = "Flat Pages", ready = function ()
    is_installed("admin") && !Admin.is_registered(FlatPage) &&
        Admin.register!(FlatPage; list_display = [:url, :title, :registration_required], search_fields = [:url, :title],
                        list_filter = [:registration_required], fieldsets = ["" => [:url, :title, :content],
                                                                            "Advanced options" => [:registration_required, :template_name]])
end)

"Render the flat page at `url` (raising Http404 if there is none)."
function render_flatpage(req::Request, url::AbstractString)
    url = startswith(url, "/") ? String(url) : "/" * url
    page = first(filter(FlatPage; url = url))
    if page === nothing
        if settings.APPEND_SLASH && !endswith(url, "/") && exists(filter(FlatPage; url = url * "/"))
            return HttpResponsePermanentRedirect(url * "/" * (isempty(req.query_string) ? "" : "?" * req.query_string))
        end
        throw(Http404("No FlatPage matches the given query."))
    end
    page.registration_required && !is_authenticated(req.user) && return redirect_to_login(req)
    # title and content are HTML from the admin, shown as is
    fp = Dict{String,Any}("id" => page.id, "url" => page.url, "title" => mark_safe(page.title), "content" => mark_safe(page.content),
                          "template_name" => page.template_name, "registration_required" => page.registration_required, "object" => page)
    render(req, isempty(page.template_name) ? ["flatpages/default.html"] : [page.template_name, "flatpages/default.html"],
           Dict{String,Any}("flatpage" => fp))
end

"The flat page view: `path(\"pages/<path:url>\", flatpage)` looks up `/<url>`."
flatpage(req::Request; url = req.path, kw...) = (require_app("flatpages", "the flatpage view"); render_flatpage(req, url))

"URL patterns serving flat pages under a prefix: `path(\"pages/\", flatpage_urls())` serves `/pages/about/` from the page with url `/about/`."
flatpage_urls() = include_urls([path("<path:url>", flatpage; name = "flatpage")])   # urls.jl may load before INSTALLED_APPS is set

"""
Middleware: when a response is a 404, serve the flat page for the request's path instead,
if there is one. Put it last in MIDDLEWARE.
"""
function FlatpageFallbackMiddleware(get_response)
    function (req::Request)
        resp = get_response(req)
        resp.status == 404 || return resp
        try
            return render_flatpage(req, req.path)
        catch e
            e isa Http404 || (settings.DEBUG && rethrow())
            return resp
        end
    end
end
push!(MIDDLEWARE_APPS, FlatpageFallbackMiddleware => "flatpages")

"""
`{% get_flatpages ['/prefix/'] [for user] as pages %}`: flat pages ordered by URL, optionally
under a prefix. Pages that need a login are left out unless `for user` names a logged-in user.
"""
struct GetFlatpagesNode <: Node
    prefix::Union{Nothing,FilterExpr}
    user::Union{Nothing,FilterExpr}
    asvar::String
end
function tag_get_flatpages(p::Parser, t::Token)
    bits = split_contents(t.contents)[2:end]
    (length(bits) >= 2 && bits[end-1] == "as") || throw(TemplateSyntaxError("get_flatpages expects a syntax of get_flatpages ['url_starts_with'] [for user] as context_name"))
    asvar = bits[end]
    bits = bits[1:end-2]
    user = nothing
    if length(bits) >= 2 && bits[end-1] == "for"
        user = parse_filter_expr(bits[end]); bits = bits[1:end-2]
    end
    length(bits) <= 1 || throw(TemplateSyntaxError("get_flatpages expects a syntax of get_flatpages ['url_starts_with'] [for user] as context_name"))
    GetFlatpagesNode(isempty(bits) ? nothing : parse_filter_expr(bits[1]), user, asvar)
end
function render!(io::IO, n::GetFlatpagesNode, ctx::Context)
    qs = objects(FlatPage)
    n.prefix === nothing || (qs = filter(qs; url__startswith = display_string(eval_fe(n.prefix, ctx))))
    u = n.user === nothing ? nothing : eval_fe(n.user, ctx)
    (u !== nothing && is_authenticated(u)) || (qs = filter(qs; registration_required = false))
    ctx[n.asvar] = collect(order_by(qs, "url"))
    nothing
end
const FLATPAGES_LIBRARY = tag!(TagLibrary("flatpages"), "get_flatpages", tag_get_flatpages)
