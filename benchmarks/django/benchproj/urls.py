from django.contrib import admin
from django.urls import path
from benchapp import views

urlpatterns = [
    path("json/", views.json_view),
    path("template/", views.template_view),
    path("posts/", views.posts_view),
    path("form/", views.form_view),
    path("admin/", admin.site.urls),
]
