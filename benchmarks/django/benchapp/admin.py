from django.contrib import admin

from .models import Author, Post


@admin.register(Post)
class PostAdmin(admin.ModelAdmin):
    list_display = ["title", "author", "created"]
    search_fields = ["title"]
    list_filter = ["author"]
    list_per_page = 100


@admin.register(Author)
class AuthorAdmin(admin.ModelAdmin):
    list_display = ["name", "email"]
