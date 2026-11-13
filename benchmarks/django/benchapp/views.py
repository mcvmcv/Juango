from django import forms
from django.core.paginator import Paginator
from django.http import HttpResponse, JsonResponse
from django.shortcuts import render

from .models import Post


class ContactForm(forms.Form):
    name = forms.CharField(max_length=100)
    email = forms.EmailField()
    message = forms.CharField(max_length=1000)


def json_view(request):
    return JsonResponse({"message": "Hello, World!", "items": list(range(1, 11))})


ROWS = [{"name": f"item number {i}", "score": i * 37 % 100, "tags": ["alpha", "b<c>", "gamma"]} for i in range(1, 101)]


def template_view(request):
    return render(request, "page.html", {"title": "A page of rows", "rows": ROWS})


def posts_view(request):
    qs = Post.objects.select_related("author").order_by("id")
    return render(request, "posts.html", {"page_obj": Paginator(qs, 20).get_page(request.GET.get("page", "1"))})


def form_view(request):
    form = ContactForm(request.POST if request.method == "POST" else None)
    if request.method == "POST" and form.is_valid():
        return HttpResponse(f"Thanks, {form.cleaned_data['name']}!")
    return render(request, "form.html", {"form": form})
