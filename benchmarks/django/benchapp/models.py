from django.db import models


class Author(models.Model):
    name = models.CharField(max_length=100)
    email = models.EmailField()

    def __str__(self):
        return self.name


class Post(models.Model):
    title = models.CharField(max_length=200)
    body = models.TextField()
    author = models.ForeignKey(Author, on_delete=models.CASCADE, related_name="posts")
    created = models.DateTimeField()

    def __str__(self):
        return self.title
