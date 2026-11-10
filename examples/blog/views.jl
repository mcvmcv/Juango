function post_list(req)
    qs = filter(Post; published = true)
    q = strip(get(req.GET, "q", ""))
    isempty(q) || (qs = filter(qs, Q(title__icontains = q) | Q(body__icontains = q)))
    pg = page(Paginator(qs, 5), get(req.GET, "page", "1"))
    render(req, "blog/post_list.html", Dict("page_obj" => pg, "q" => q))
end

function post_detail(req; slug)
    post = get_object_or_404(Post; slug = slug)
    post.published || (is_authenticated(req.user) && req.user.id == post.author_id) || throw(Http404())
    form = CommentForm(req.method == "POST" ? req.POST : nothing)
    if req.method == "POST" && is_valid(form)
        create(Comment; post = post, form.cleaned_data...)
        message!(req, :success, "Thanks for your comment!")
        return redirect(post)
    end
    render(req, "blog/post_detail.html", Dict("post" => post, "form" => form))
end

function post_form(req, post)
    form = ModelForm(Post; data = req.method == "POST" ? req.POST : nothing, instance = post,
                     fields = [:title, :slug, :body, :published])
    if req.method == "POST" && is_valid(form)
        p = save!(form; commit = false)
        p.author = req.user
        save!(p)
        message!(req, :success, post === nothing ? "Post created." : "Post updated.")
        return redirect(p)
    end
    render(req, "blog/post_form.html", Dict("form" => form, "post" => post))
end

const post_create = login_required(req -> post_form(req, nothing))

function edit_own_post(req; slug)
    post = get_object_or_404(Post; slug = slug, author = req.user)
    post_form(req, post)
end
const post_edit = login_required(edit_own_post)

const drafts = login_required(ListView(Post; template = "blog/drafts.html",
                                 queryset = req -> filter(Post; author = req.user, published = false)))

"A small JSON API."
api_posts(req) = [Dict("title" => p.title, "url" => build_absolute_uri_for(req, p), "author" => p.author.username,
                       "created" => string(p.created), "comments" => count(p.comments))
                  for p in filter(Post; published = true)]
build_absolute_uri_for(req, p) = Juango.build_absolute_uri(req, Juango.get_absolute_url(p))
