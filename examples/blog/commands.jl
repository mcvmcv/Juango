Juango.register_command!("seed", "Create a demo user (demo/demo-pass) and some posts", function (args)
    u = first(filter(User; username = "demo"))
    u === nothing && (u = create_superuser("demo", "demo-pass"; email = "demo@example.com", first_name = "Demo"))
    for (t, b) in [("Hello, Juango", "Juango brings Django's batteries-included style to **Julia**.\n\nModels, templates, forms, an admin — all here."),
                   ("Multiple dispatch for web apps", "Views are just functions. Middleware is just closures.\n\nEverything composes."),
                   ("Templates you already know", "{% extends %}, {% block %}, filters, autoescaping: the Django template language, in Julia.")]
        exists(filter(Post; title = t)) && continue
        p = create(Post; title = t, body = b, author = u, published = true)
        create(Comment; post = p, name = "Ada", body = "Lovely post!")
    end
    println("Seeded. Log in at /admin/ as demo / demo-pass")
end)
