@model struct Post
    title = CharField(max_length = 200)
    slug = SlugField(unique = true, help_text = "Used in the URL; leave blank to generate from the title.", blank = true)
    author = ForeignKey(User, on_delete = :CASCADE, related_name = :posts)
    body = TextField()
    published = BooleanField(default = false)
    created = DateTimeField(auto_now_add = true)
    updated = DateTimeField(auto_now = true)
    Meta(ordering = ["-created"])
end

@model struct Comment
    post = ForeignKey(Post, on_delete = :CASCADE, related_name = :comments)
    name = CharField(max_length = 80)
    body = TextField()
    approved = BooleanField(default = true)
    created = DateTimeField(auto_now_add = true)
    Meta(ordering = ["created"])
end

Base.show(io::IO, p::Post) = print(io, p.title)
Base.show(io::IO, c::Comment) = print(io, "Comment by ", c.name)
Juango.get_absolute_url(p::Post) = reverse_url("blog:detail"; slug = p.slug)
Juango.tattr(p::Post, ::Val{:approved_comments}) = filter(p.comments; approved = true)

"Fill in the slug from the title, keeping it unique."
function Juango.save!(p::Post)
    if isempty(p.slug)
        base = Juango.slugify(p.title)
        slug, i = base, 2
        while exists(filter(Post, Q(slug = slug), !Q(id = p.id)))
            slug = "$base-$i"
            i += 1
        end
        p.slug = slug
    end
    invoke(Juango.save!, Tuple{Juango.Model}, p)
end
