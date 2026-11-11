# admin: julia --project=test test/admin.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "admin" begin
    for i in 1:3
        create(Article; title = "AGV $i", author = ann_author())
    end
    create(Article; title = "Unrelated title", author = ann_author())
    c = Client()
    r = get(c, "/admin/")
    @test r.status == 302 && startswith(getheader(r, "Location"), "/admin/login/")
    create_user("staffless", "pw12345")
    r = post(c, "/admin/login/", Dict("username" => "staffless", "password" => "pw12345"))
    @test r.status == 200 && occursin("staff account", text(r))
    root_user()
    r = post(c, "/admin/login/?next=/admin/", Dict("username" => "root", "password" => "rootpw"); follow = true)
    @test r.status == 200 && occursin("Site administration", text(r))
    @test occursin("Articles", text(r)) && occursin("Users", text(r))

    r = get(c, "/admin/article/")
    @test r.status == 200 && occursin("Select article to change", text(r)) && occursin("By published", text(r))
    r = get(c, "/admin/article/?q=AGV")
    @test occursin("AGV 2", text(r)) && !occursin("Unrelated title", text(r))
    r = get(c, "/admin/article/?published=1")
    @test r.status == 200

    ann = ann_author()
    r = get(c, "/admin/article/add/")
    @test r.status == 200 && occursin("name=\"title\"", text(r)) && !occursin("name=\"created\"", text(r))
    r = post(c, "/admin/article/add/", Dict("title" => "Admin made", "author" => string(ann.id), "status" => "p", "views" => "0"); follow = true)
    @test occursin("was added successfully", text(r))
    a = get(Article; title = "Admin made")
    r = get(c, "/admin/article/$(a.id)/change/")
    @test occursin("value=\"Admin made\"", text(r)) && occursin("View on site", text(r))
    r = post(c, "/admin/article/$(a.id)/change/", Dict("title" => "", "author" => string(ann.id), "status" => "p", "views" => "0"))
    @test r.status == 200 && occursin("This field is required.", text(r))
    r = post(c, "/admin/article/$(a.id)/change/", Dict("title" => "Renamed", "author" => string(ann.id), "status" => "p", "views" => "3", "_continue" => "1"))
    @test r.status == 302 && getheader(r, "Location") == "/admin/article/$(a.id)/change/" && refresh!(a).title == "Renamed"
    @test occursin("Are you sure?", text(get(c, "/admin/article/$(a.id)/delete/")))
    r = post(c, "/admin/article/$(a.id)/delete/"; follow = true)
    @test occursin("deleted successfully", text(r)) && !exists(filter(Article; id = a.id))

    ids = values_list(filter(Article; title__startswith = "AGV"), :id; flat = true)
    r = post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids)))
    @test occursin("Are you sure", text(r)) && length(ids) == 3 && count(filter(Article; id__in = ids)) == 3   # confirmation first
    r = post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids), "post" => "yes"); follow = true)
    @test occursin("Successfully deleted 3 articles", text(r))

    # user admin hashes passwords
    r = post(c, "/admin/user/add/", Dict("username" => "newbie", "password" => "hunter22", "is_active" => "on"))
    @test r.status == 302
    nb = get(User; username = "newbie")
    @test startswith(nb.password, "pbkdf2_sha256\$") && authenticate("newbie", "hunter22") == nb
    r = post(c, "/admin/user/$(nb.id)/change/", Dict("username" => "newbie", "password" => "", "is_active" => "on"))
    @test r.status == 302 && authenticate("newbie", "hunter22") !== nothing
    @test get(c, "/admin/nosuchmodel/").status == 404
    @test post(c, "/admin/logout/").status == 200
    @test get(c, "/admin/").status == 302
end

@testset "admin: history, actions, inlines and layout options" begin
    root = root_user()
    c = Client()
    force_login!(c, root)
    ct = get_for_model(Author)
    function shout(ma, req, qs)
        for a in qs
            a.name = uppercase(a.name); save!(a)
            log_action!(req.user, a, CHANGE, "Shouted.")
        end
        message!(req, :success, "Shouted $(count(qs)).")
        nothing
    end
    Admin.register!(Author; list_display = [:name, :email], list_editable = [:email], search_fields = [:name],
                    fieldsets = ["Main" => [:name], "Contact" => [:email]], save_as = true,
                    inlines = [Admin.TabularInline(Article; fields = [:title, :status], extra = 1)],
                    actions = [Admin.action(shout; description = "Shout names", confirm = true), Admin.export_csv])
    try
        # adding and changing are logged; history and recent actions show them
        r = post(c, "/admin/author/add/", Dict("name" => "Adm Ann", "email" => "",
                                              "articles-TOTAL_FORMS" => "1", "articles-INITIAL_FORMS" => "0",
                                              "articles-0-title" => "Inline one", "articles-0-status" => "d"))
        @test r.status == 302
        ann = get(Author; name = "Adm Ann")
        @test [x.title for x in ann.articles] == ["Inline one"]               # inline saved with the new parent
        e = first(filter(LogEntry; content_type = ct, object_id = string(ann.id)))
        @test e.action_flag == ADDITION && e.user == root && e.object_repr == "Adm Ann"

        r = get(c, "/admin/author/$(ann.id)/change/")
        @test r.status == 200 && occursin("<h2>Contact</h2>", text(r)) && occursin("articles-TOTAL_FORMS", text(r))
        @test occursin("name=\"_saveasnew\"", text(r)) && occursin("/admin/author/$(ann.id)/history/", text(r))
        art = only(ann.articles)
        post(c, "/admin/author/$(ann.id)/change/", Dict("name" => "Adm Ann", "email" => "ann@x.io",
            "articles-TOTAL_FORMS" => "2", "articles-INITIAL_FORMS" => "1",
            "articles-0-id" => string(art.id), "articles-0-title" => "Inline one", "articles-0-status" => "d", "articles-0-DELETE" => "on",
            "articles-1-title" => "Inline two", "articles-1-status" => "p"))
        @test [x.title for x in get(Author; id = ann.id).articles] == ["Inline two"]
        e = first(order_by(filter(LogEntry; object_id = string(ann.id), content_type = ct), "-id"))
        @test e.action_flag == CHANGE && occursin("Changed email.", e.change_message) &&
              occursin("Added article “Inline two”.", e.change_message) && occursin("Deleted article “Inline one”.", e.change_message)
        r = get(c, "/admin/author/$(ann.id)/history/")
        @test r.status == 200 && occursin("Changed email.", text(r)) && occursin("Added.", text(r))
        @test occursin("Recent actions", text(get(c, "/admin/"))) && occursin(">Adm Ann</a>", text(get(c, "/admin/")))

        # save as new
        post(c, "/admin/author/$(ann.id)/change/", Dict("name" => "Adm Copy", "email" => "c@x.io", "_saveasnew" => "1"))
        @test exists(filter(Author; name = "Adm Copy")) && get(Author; id = ann.id).name == "Adm Ann"

        # list_editable
        bob = create(Author; name = "Adm Bob")
        r = get(c, "/admin/author/?q=Adm+Bob")
        @test occursin("name=\"form-0-email\"", text(r)) && occursin("form-TOTAL_FORMS", text(r))
        r = post(c, "/admin/author/?q=Adm+Bob", Dict("_save" => "Save", "form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1",
                                                     "form-0-id" => string(bob.id), "form-0-email" => "bob@x.io"); follow = true)
        @test get(Author; id = bob.id).email == "bob@x.io" && occursin("1 author was changed", text(r))

        # actions: confirmation, custom, CSV export, delete with logging
        r = get(c, "/admin/author/")
        @test occursin("Shout names", text(r)) && occursin("Export selected as CSV", text(r)) && occursin("Delete selected authors", text(r))
        r = post(c, "/admin/author/", Dict("action" => "shout", "_selected_action" => string(bob.id)))
        @test occursin("Are you sure", text(r)) && get(Author; id = bob.id).name == "Adm Bob"
        r = post(c, "/admin/author/", Dict("action" => "shout", "_selected_action" => string(bob.id), "post" => "yes"); follow = true)
        @test get(Author; id = bob.id).name == "ADM BOB" && occursin("Shouted 1.", text(r))
        r = post(c, "/admin/author/", Dict("action" => "export_csv", "_selected_action" => [string(bob.id), string(ann.id)]))
        @test startswith(getheader(r, "Content-Type"), "text/csv") && startswith(text(r), "Name,Email\r\n")
        @test occursin("ADM BOB,bob@x.io", text(r)) && occursin("attachment", getheader(r, "Content-Disposition"))
        post(c, "/admin/author/", Dict("action" => "delete_selected", "_selected_action" => string(bob.id), "post" => "yes"))
        @test !exists(filter(Author; id = bob.id)) && get(LogEntry; object_id = string(bob.id), action_flag = DELETION).object_repr == "ADM BOB"
        @test occursin("No action selected", text(post(c, "/admin/author/", Dict("action" => "nope", "_selected_action" => "1"); follow = true)))

        # Article: readonly, prepopulated, raw id, autocomplete, date hierarchy
        Admin.register!(Article; list_display = [:title, :author], readonly_fields = [:views], date_hierarchy = :created,
                        prepopulated_fields = Dict(:slug => [:title]), autocomplete_fields = [:author])
        r = get(c, "/admin/article/add/")
        @test occursin("\"target\":\"id_slug\"", text(r)) && occursin("data-autocomplete=\"author\"", text(r))
        @test !occursin("name=\"views\"", text(r))
        a2 = only(get(Author; id = ann.id).articles)
        r = get(c, "/admin/article/$(a2.id)/change/")
        @test occursin("Views:", text(r)) && !occursin("name=\"views\"", text(r)) && !occursin("\"target\"", text(r))
        @test occursin("<option value=\"$(ann.id)\" selected>Adm Ann</option>", text(r))
        js = Juango.JSON.parse(text(get(c, "/admin/author/autocomplete/?term=adm+a")))
        @test [x["text"] for x in js["results"]] == ["Adm Ann"]
        r = get(c, "/admin/article/")
        y = year(now())
        @test occursin(">$y</a>", text(r))
        r = get(c, "/admin/article/?created__year=$y")
        @test occursin("‹ All dates", text(r)) && occursin(Dates.monthname(month(now())), text(r))
        @test !occursin("Inline two", text(get(c, "/admin/article/?created__year=1999")))
        Admin.register!(Article; list_display = [:title], raw_id_fields = [:author])
        r = get(c, "/admin/article/$(a2.id)/change/")
        @test occursin("class=\"raw-id\" value=\"$(ann.id)\"", text(r)) && occursin(">Adm Ann</span>", text(r))
    finally
        Admin.unregister!(Author)
        Admin.register!(Author; list_display = [:name, :email], search_fields = [:name])
        Admin.register!(Article; list_display = [:title, :author, :status, :published, "Len" => a -> length(a.body)],
                        search_fields = [:title, :body], list_filter = [:published, :status, :author])
    end
end

@testset "permissions and groups" begin
    @test exists(filter(Permission; codename = "change_article"))
    p = get(Permission; codename = "change_article")
    @test p.content_type.model == "article" && p.name == "Can change article" && string(p) == "project | article | Can change article"
    @test perm_name(Article, :change) == "project.change_article"
    @test exists(filter(Permission; codename = "publish_memo")) && exists(filter(Permission; codename = "view_memo"))
    @test count(filter(Permission; codename__endswith = "_user")) == 4
    perm(code) = get(Permission; codename = code)
    fresh(u) = get(User; id = u.id)            # permissions are cached per user object

    u = create_user("permy", "pw12345")
    u.is_staff = true; save!(u)
    @test !has_perm(u, "project.change_article") && isempty(get_all_permissions(u))
    add!(u.user_permissions, perm("view_article"))
    u = fresh(u)
    @test has_perm(u, "project.view_article") && !has_perm(u, "project.change_article")
    editors = create(Group; name = "editors")
    add!(editors.permissions, perm("change_article"), perm("add_article"))
    add!(u.groups, editors)
    u = fresh(u)
    @test has_perms(u, ["project.view_article", "project.change_article", "project.add_article"])
    @test !has_perm(u, "project.delete_article") && !has_perm(u, "project.change_article"; obj = Article())
    @test get_all_permissions(u) == Set(["project.view_article", "project.change_article", "project.add_article"])
    @test has_module_perms(u, "project") && !has_module_perms(u, "auth")
    @test [g.name for g in u.groups] == ["editors"] && [x.username for x in editors.user_set] == ["permy"]
    root = root_user()
    @test has_perm(root, "project.delete_article") && has_perm(root, "anything.at_all") && has_module_perms(root, "auth")
    off = create_user("offline", "pw12345"); off.is_superuser = true; off.is_active = false; save!(off)
    @test !has_perm(off, "project.view_article")
    @test !has_perm(Juango.AnonymousUser(), "project.view_article")

    # permission_required
    view = permission_required("project.add_article", "project.change_article")(req -> HttpResponse("ok"))
    req(user) = (r = Request("GET", "/x"); r.user = user; r)
    @test view(req(u)).status == 200
    @test_throws PermissionDenied view(req(create_user("nobody", "pw12345")))
    @test view(req(Juango.AnonymousUser())).status == 302
    @test permission_required(r -> "x", "project.delete_article"; raise_exception = false)(req(u)).status == 302

    # templates
    tpl = "{% if perms.project.add_article %}A{% endif %}{% if perms.project.delete_article %}D{% endif %}" *
          "{% if perms.project %}P{% endif %}{% if perms.juango %}J{% endif %}{% if \"project.view_article\" in perms %}V{% endif %}"
    @test tr(tpl, Dict("perms" => Juango.PermWrapper(u))) == "APV"

    # the admin follows permissions
    c = Client()
    force_login!(c, u)
    r = get(c, "/admin/")
    @test occursin("Articles", text(r)) && !occursin("Users", text(r))
    @test get(c, "/admin/user/").status == 403
    r = get(c, "/admin/article/")
    @test r.status == 200 && occursin("Add article", text(r)) && !occursin("Delete selected", text(r))
    a = create(Article; title = "perm-art", author = create(Author; name = "Perm Author"))
    r = get(c, "/admin/article/$(a.id)/change/")
    @test r.status == 200 && occursin("name=\"_save\"", text(r)) && !occursin("class=\"deletelink\"", text(r))
    @test get(c, "/admin/article/$(a.id)/delete/").status == 403
    @test post(c, "/admin/article/", Dict("action" => "delete_selected", "_selected_action" => string(a.id))).status == 403
    @test exists(filter(Article; id = a.id))

    viewer = create_user("viewer", "pw12345"); viewer.is_staff = true; save!(viewer)
    add!(viewer.user_permissions, perm("view_article"))
    c2 = Client()
    force_login!(c2, viewer)
    r = get(c2, "/admin/article/$(a.id)/change/")
    @test r.status == 200 && occursin("View article", text(r)) && occursin("perm-art", text(r)) && !occursin("name=\"_save\"", text(r))
    @test post(c2, "/admin/article/$(a.id)/change/", Dict("title" => "hacked")).status == 403
    @test get(Article; id = a.id).title == "perm-art"
    @test get(c2, "/admin/article/add/").status == 403
    @test !occursin("Add article", text(get(c2, "/admin/article/")))

    bare = create_user("bare", "pw12345"); bare.is_staff = true; save!(bare)
    c3 = Client()
    force_login!(c3, bare)
    @test occursin("You don’t have permission", text(get(c3, "/admin/")))

    # groups are in the admin, and a user's groups can be edited there
    rc = Client()
    force_login!(rc, root)
    @test occursin("Groups", text(get(rc, "/admin/")))
    r = get(rc, "/admin/user/$(bare.id)/change/")
    @test occursin("name=\"groups\"", text(r)) && occursin("name=\"user_permissions\"", text(r))
end
