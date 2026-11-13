const blog_patterns = [
    path("", post_list; name = "list"),
    path("new/", post_create; name = "create"),
    path("drafts/", drafts; name = "drafts"),
    path("<slug:slug>/", post_detail; name = "detail"),
    path("<slug:slug>/edit/", post_edit; name = "edit"),
    path("<slug:slug>/title/", post_title; name = "title"),          # htmx inline edit
]

const sitemaps = Dict(
    "posts" => Sitemap(() -> filter(Post; published = true); lastmod = :updated, changefreq = "weekly", priority = 0.6),
    "pages" => Sitemap(["blog:list", "about"]; location = name -> reverse_url(name), changefreq = "monthly"),
)

const latest_posts = Feed(title = "Juango Blog", link = "/blog/", description = "The latest posts",
                          items = () -> filter(Post; published = true)[1:10],
                          item_description = :body, item_pubdate = :created, item_updateddate = :updated,
                          item_author_name = p -> p.author.username)

const urlpatterns = [
    path("", RedirectView("blog:list"); name = "home"),
    path("blog/", include_urls(blog_patterns; namespace = "blog")),
    path("about/", TemplateView("about.html"); name = "about"),
    path("api/posts/", require_GET(api_posts); name = "api_posts"),
    path("accounts/", Juango.auth_urls()),
    path("admin/", Admin.urls()),
    path("feed/", latest_posts; name = "feed"),                                  # RSS 2.0
    path("feed/atom/", Feed(latest_posts; feed_type = :atom); name = "feed_atom"),
    sitemap_urls(sitemaps)...,                       # /sitemap.xml, /sitemap-posts.xml, /sitemap-pages.xml
]
