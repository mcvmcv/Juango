function post_list(req)
    # author in the same query, all comments in one more: no queries per post in the template
    qs = filter(Post; published = true) |> select_related(:author) |> prefetch_related(:comments)
    q = strip(get(req.GET, "q", ""))
    isempty(q) || (qs = filter(qs, Q(title__icontains = q) | Q(body__icontains = q)))
    pg = page(Paginator(qs, 5), get(req.GET, "page", "1"))
    # htmx (search as you type, the next page when scrolling) gets just the list of posts
    render(req, "blog/post_list.html", Dict("page_obj" => pg, "q" => q); htmx_partial = "posts")
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

"The title of a post, edited in place with htmx (see the partials in post_detail.html)."
function edit_title(req; slug)
    post = get_object_or_404(Post; slug = slug, author = req.user)
    show(form = nothing; status = 200) =
        render(req, "blog/post_detail.html#" * (form === nothing ? "title" : "title_form"),
               Dict("post" => post, "form" => form); status = status)
    if req.method == "POST"
        form = ModelForm(Post; data = req.POST, instance = post, fields = [:title])
        is_valid(form) || return show(form; status = form_status(form))      # 422: htmx swaps the errors in
        save!(form)
        message!(req, :success, "Title updated.")                             # arrives as an out-of-band swap
        return show()
    end
    haskey(req.GET, "cancel") ? show() : show(ModelForm(Post; instance = post, fields = [:title]))
end
const post_title = login_required(edit_title)

const drafts = login_required(ListView(Post; template = "blog/drafts.html",
                                 queryset = req -> filter(Post; author = req.user, published = false)))

"A small JSON API."
api_posts(req) = [Dict("title" => p.title, "url" => build_absolute_uri_for(req, p), "author" => p.author.username,
                       "created" => string(p.created), "comments" => count(p.comments))
                  for p in filter(Post; published = true) |> select_related(:author) |> prefetch_related(:comments)]
build_absolute_uri_for(req, p) = Juango.build_absolute_uri(req, Juango.get_absolute_url(p))
