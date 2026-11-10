const blog_patterns = [
    path("", post_list; name = "list"),
    path("new/", post_create; name = "create"),
    path("drafts/", drafts; name = "drafts"),
    path("<slug:slug>/", post_detail; name = "detail"),
    path("<slug:slug>/edit/", post_edit; name = "edit"),
]

const urlpatterns = [
    path("", RedirectView("blog:list"); name = "home"),
    path("blog/", include_urls(blog_patterns; namespace = "blog")),
    path("about/", TemplateView("about.html"); name = "about"),
    path("api/posts/", require_GET(api_posts); name = "api_posts"),
    path("accounts/", Juango.auth_urls()),
    path("admin/", Admin.urls()),
]
