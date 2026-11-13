from datetime import datetime, timedelta, timezone

from django.contrib.auth.models import User
from django.core.management.base import BaseCommand

from benchapp.models import Author, Post


class Command(BaseCommand):
    help = "The benchmark data: 20 authors, 1000 posts, superuser admin / admin-pass"

    def handle(self, *args, **options):
        if Post.objects.exists():
            return self.stdout.write("Already seeded.")
        User.objects.create_superuser("admin", "admin@example.com", "admin-pass")
        Author.objects.bulk_create([Author(name=f"Author {i}", email=f"author{i}@example.com") for i in range(1, 21)])
        authors = list(Author.objects.order_by("id"))
        t0 = datetime(2025, 1, 1, tzinfo=timezone.utc)
        Post.objects.bulk_create([Post(title=f"Post number {i}", body=f"The body of post {i}. " * 20,
                                       author=authors[(i - 1) % 20], created=t0 + timedelta(hours=i))
                                  for i in range(1, 1001)])
        self.stdout.write("Seeded.")
