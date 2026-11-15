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

    r = get(c, "/admin/project/article/")
    @test r.status == 200 && occursin("Select article to change", text(r)) && occursin("By published", text(r))
    r = get(c, "/admin/project/article/?q=AGV")
    @test occursin("AGV 2", text(r)) && !occursin("Unrelated title", text(r))
    r = get(c, "/admin/project/article/?published=1")
    @test r.status == 200

    ann = ann_author()
    r = get(c, "/admin/project/article/add/")
    @test r.status == 200 && occursin("name=\"title\"", text(r)) && !occursin("name=\"created\"", text(r))
    r = post(c, "/admin/project/article/add/", Dict("title" => "Admin made", "author" => string(ann.id), "status" => "p", "views" => "0"); follow = true)
    @test occursin("was added successfully", text(r))
    a = get(Article; title = "Admin made")
    r = get(c, "/admin/project/article/$(a.id)/change/")
    @test occursin("value=\"Admin made\"", text(r)) && occursin("View on site", text(r))
    r = post(c, "/admin/project/article/$(a.id)/change/", Dict("title" => "", "author" => string(ann.id), "status" => "p", "views" => "0"))
    @test r.status == 200 && occursin("This field is required.", text(r))
    r = post(c, "/admin/project/article/$(a.id)/change/", Dict("title" => "Renamed", "author" => string(ann.id), "status" => "p", "views" => "3", "_continue" => "1"))
    @test r.status == 302 && getheader(r, "Location") == "/admin/project/article/$(a.id)/change/" && refresh!(a).title == "Renamed"
    @test occursin("Are you sure?", text(get(c, "/admin/project/article/$(a.id)/delete/")))
    r = post(c, "/admin/project/article/$(a.id)/delete/"; follow = true)
    @test occursin("deleted successfully", text(r)) && !exists(filter(Article; id = a.id))

    ids = values_list(filter(Article; title__startswith = "AGV"), :id; flat = true)
    r = post(c, "/admin/project/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids)))
    @test occursin("Are you sure", text(r)) && length(ids) == 3 && count(filter(Article; id__in = ids)) == 3   # confirmation first
    r = post(c, "/admin/project/article/", Dict("action" => "delete_selected", "_selected_action" => string.(ids), "post" => "yes"); follow = true)
    @test occursin("Successfully deleted 3 articles", text(r))

    # user admin hashes passwords
    r = get(c, "/admin/auth/user/add/")
    @test occursin("password1", text(r)) && occursin("password2", text(r)) && !occursin("is_superuser", text(r))
    r = post(c, "/admin/auth/user/add/", Dict("username" => "newbie", "password1" => "hunter22", "password2" => "hunter23"))
    @test r.status == 200 && occursin("didn’t match", text(r))
    r = post(c, "/admin/auth/user/add/", Dict("username" => "newbie", "password1" => "hunter22", "password2" => "hunter22"))
    nb = get(User; username = "newbie")
    @test r.status == 302 && getheader(r, "Location") == "/admin/auth/user/$(nb.id)/change/"      # then the change page
    @test startswith(nb.password, "pbkdf2_sha256\$") && authenticate("newbie", "hunter22") == nb
    r = post(c, "/admin/auth/user/$(nb.id)/change/", Dict("username" => "newbie", "password" => "", "is_active" => "on"))
    @test r.status == 302 && authenticate("newbie", "hunter22") !== nothing
    @test get(c, "/admin/project/nosuchmodel/").status == 404
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
        r = post(c, "/admin/project/author/add/", Dict("name" => "Adm Ann", "email" => "",
                                              "articles-TOTAL_FORMS" => "1", "articles-INITIAL_FORMS" => "0",
                                              "articles-0-title" => "Inline one", "articles-0-status" => "d"))
        @test r.status == 302
        ann = get(Author; name = "Adm Ann")
        @test [x.title for x in ann.articles] == ["Inline one"]               # inline saved with the new parent
        e = first(filter(LogEntry; content_type = ct, object_id = string(ann.id)))
        @test e.action_flag == ADDITION && e.user == root && e.object_repr == "Adm Ann"

        r = get(c, "/admin/project/author/$(ann.id)/change/")
        @test r.status == 200 && occursin("<h2>Contact</h2>", text(r)) && occursin("articles-TOTAL_FORMS", text(r))
        @test occursin("name=\"_saveasnew\"", text(r)) && occursin("/admin/project/author/$(ann.id)/history/", text(r))
        art = only(ann.articles)
        post(c, "/admin/project/author/$(ann.id)/change/", Dict("name" => "Adm Ann", "email" => "ann@x.io",
            "articles-TOTAL_FORMS" => "2", "articles-INITIAL_FORMS" => "1",
            "articles-0-id" => string(art.id), "articles-0-title" => "Inline one", "articles-0-status" => "d", "articles-0-DELETE" => "on",
            "articles-1-title" => "Inline two", "articles-1-status" => "p"))
        @test [x.title for x in get(Author; id = ann.id).articles] == ["Inline two"]
        e = first(order_by(filter(LogEntry; object_id = string(ann.id), content_type = ct), "-id"))
        @test e.action_flag == CHANGE && occursin("Changed email.", e.change_message) &&
              occursin("Added article “Inline two”.", e.change_message) && occursin("Deleted article “Inline one”.", e.change_message)
        r = get(c, "/admin/project/author/$(ann.id)/history/")
        @test r.status == 200 && occursin("Changed email.", text(r)) && occursin("Added.", text(r))
        @test occursin("Recent actions", text(get(c, "/admin/"))) && occursin(">Adm Ann</a>", text(get(c, "/admin/")))

        # save as new
        post(c, "/admin/project/author/$(ann.id)/change/", Dict("name" => "Adm Copy", "email" => "c@x.io", "_saveasnew" => "1"))
        @test exists(filter(Author; name = "Adm Copy")) && get(Author; id = ann.id).name == "Adm Ann"

        # list_editable
        bob = create(Author; name = "Adm Bob")
        r = get(c, "/admin/project/author/?q=Adm+Bob")
        @test occursin("name=\"form-0-email\"", text(r)) && occursin("form-TOTAL_FORMS", text(r))
        r = post(c, "/admin/project/author/?q=Adm+Bob", Dict("_save" => "Save", "form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1",
                                                     "form-0-id" => string(bob.id), "form-0-email" => "bob@x.io"); follow = true)
        @test get(Author; id = bob.id).email == "bob@x.io" && occursin("1 author was changed", text(r))

        # actions: confirmation, custom, CSV export, delete with logging
        r = get(c, "/admin/project/author/")
        @test occursin("Shout names", text(r)) && occursin("Export selected as CSV", text(r)) && occursin("Delete selected authors", text(r))
        r = post(c, "/admin/project/author/", Dict("action" => "shout", "_selected_action" => string(bob.id)))
        @test occursin("Are you sure", text(r)) && get(Author; id = bob.id).name == "Adm Bob"
        r = post(c, "/admin/project/author/", Dict("action" => "shout", "_selected_action" => string(bob.id), "post" => "yes"); follow = true)
        @test get(Author; id = bob.id).name == "ADM BOB" && occursin("Shouted 1.", text(r))
        r = post(c, "/admin/project/author/", Dict("action" => "export_csv", "_selected_action" => [string(bob.id), string(ann.id)]))
        @test startswith(getheader(r, "Content-Type"), "text/csv") && startswith(text(r), "Name,Email\r\n")
        @test occursin("ADM BOB,bob@x.io", text(r)) && occursin("attachment", getheader(r, "Content-Disposition"))
        post(c, "/admin/project/author/", Dict("action" => "delete_selected", "_selected_action" => string(bob.id), "post" => "yes"))
        @test !exists(filter(Author; id = bob.id)) && get(LogEntry; object_id = string(bob.id), action_flag = DELETION).object_repr == "ADM BOB"
        @test occursin("No action selected", text(post(c, "/admin/project/author/", Dict("action" => "nope", "_selected_action" => "1"); follow = true)))

        # Article: readonly, prepopulated, raw id, autocomplete, date hierarchy
        Admin.register!(Article; list_display = [:title, :author], readonly_fields = [:views], date_hierarchy = :created,
                        prepopulated_fields = Dict(:slug => [:title]), autocomplete_fields = [:author])
        r = get(c, "/admin/project/article/add/")
        @test occursin("\"target\":\"id_slug\"", text(r)) && occursin("data-autocomplete=\"project/author\"", text(r))
        @test !occursin("name=\"views\"", text(r))
        a2 = only(get(Author; id = ann.id).articles)
        r = get(c, "/admin/project/article/$(a2.id)/change/")
        @test occursin("Views:", text(r)) && !occursin("name=\"views\"", text(r)) && !occursin("\"target\"", text(r))
        @test occursin("<option value=\"$(ann.id)\" selected>Adm Ann</option>", text(r))
        js = Juango.JSON.parse(text(get(c, "/admin/project/author/autocomplete/?term=adm+a")))
        @test [x["text"] for x in js["results"]] == ["Adm Ann"]
        r = get(c, "/admin/project/article/")
        y = year(now())
        @test occursin(">$y</a>", text(r))
        r = get(c, "/admin/project/article/?created__year=$y")
        @test occursin("‹ All dates", text(r)) && occursin(Dates.monthname(month(now())), text(r))
        @test !occursin("Inline two", text(get(c, "/admin/project/article/?created__year=1999")))
        Admin.register!(Article; list_display = [:title], raw_id_fields = [:author])
        r = get(c, "/admin/project/article/$(a2.id)/change/")
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
    @test get(c, "/admin/auth/user/").status == 403
    r = get(c, "/admin/project/article/")
    @test r.status == 200 && occursin("Add article", text(r)) && !occursin("Delete selected", text(r))
    a = create(Article; title = "perm-art", author = create(Author; name = "Perm Author"))
    r = get(c, "/admin/project/article/$(a.id)/change/")
    @test r.status == 200 && occursin("name=\"_save\"", text(r)) && !occursin("class=\"deletelink\"", text(r))
    @test get(c, "/admin/project/article/$(a.id)/delete/").status == 403
    @test post(c, "/admin/project/article/", Dict("action" => "delete_selected", "_selected_action" => string(a.id))).status == 403
    @test exists(filter(Article; id = a.id))

    viewer = create_user("viewer", "pw12345"); viewer.is_staff = true; save!(viewer)
    add!(viewer.user_permissions, perm("view_article"))
    c2 = Client()
    force_login!(c2, viewer)
    r = get(c2, "/admin/project/article/$(a.id)/change/")
    @test r.status == 200 && occursin("View article", text(r)) && occursin("perm-art", text(r)) && !occursin("name=\"_save\"", text(r))
    @test post(c2, "/admin/project/article/$(a.id)/change/", Dict("title" => "hacked")).status == 403
    @test get(Article; id = a.id).title == "perm-art"
    @test get(c2, "/admin/project/article/add/").status == 403
    @test !occursin("Add article", text(get(c2, "/admin/project/article/")))

    bare = create_user("bare", "pw12345"); bare.is_staff = true; save!(bare)
    c3 = Client()
    force_login!(c3, bare)
    @test occursin("You don’t have permission", text(get(c3, "/admin/")))

    # groups are in the admin, and a user's groups can be edited there
    rc = Client()
    force_login!(rc, root)
    @test occursin("Groups", text(get(rc, "/admin/")))
    r = get(rc, "/admin/auth/user/$(bare.id)/change/")
    @test occursin("name=\"groups\"", text(r)) && occursin("name=\"user_permissions\"", text(r))
end

@testset "admin sites, custom list filters, custom views, per-object permissions" begin
    root_user()
    c = Client(); force_login!(c, get(User; username = "root"))
    staff = Admin.AdminSite("staff"; site_header = "Staff area", index_title = "Staff home",
                            has_permission = req -> req.user.username == "root",
                            urls = [path("stats/", req -> HttpResponse("stats for " * req.user.username); name = "stats")])
    popular = Admin.ListFilter("popularity", "pop"; lookups = (req, ma) -> ["hot" => "Hot", "cold" => "Cold"],
                               queryset = (req, qs, v) -> v == "hot" ? filter(qs; views__gte = 100) : filter(qs; views__lt = 100))
    publish(req; id) = HttpResponse("publishing $id at " * reverse_url("admin:changelist"; app = "project", model = "article"))
    Admin.register!(Article; site = staff, search_fields = [:title], list_filter = [popular, :author => :related_only, :slug => :empty],
                    has_change_permission = (req, obj) -> obj === nothing || obj.views < 1000,
                    has_delete_permission = (req, obj) -> false, list_select_related = false, show_full_result_count = false,
                    get_list_display = req -> [:title, :views], urls = [path("<str:id>/publish/", publish; name = "article_publish")])
    @test Admin.is_registered(Article; site = staff) && !Admin.is_registered(Author; site = staff)
    old = settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = vcat(old, [path("staff/", Admin.urls(staff))]))
    try
        au = create(Author; name = "Site author")
        hot = create(Article; title = "SA hot", author = au, views = 500)
        cold = create(Article; title = "SA cold", author = au, views = 5, slug = "x")
        big = create(Article; title = "SA big", author = au, views = 5000)
        r = get(c, "/staff/")
        @test r.status == 200 && occursin("Staff area", text(r)) && occursin("Staff home", text(r))
        @test occursin("/staff/project/article/", text(r)) && !occursin("/staff/auth/user/", text(r)) && !occursin("/admin/project/article/", text(r))
        r = get(c, "/staff/project/article/?pop=hot&q=SA")
        @test occursin("SA hot", text(r)) && occursin("SA big", text(r)) && !occursin("SA cold", text(r))
        @test occursin("popularity", text(r)) && occursin("Show all", text(r)) && occursin(">Views<", text(r))
        r = get(c, "/staff/project/article/?slug__isempty=0&q=SA")
        @test occursin("SA cold", text(r)) && !occursin("SA hot", text(r))
        @test occursin("Site author", text(get(c, "/staff/project/article/")))                    # related_only lists authors in use

        # per-object permissions
        r = get(c, "/staff/project/article/$(big.id)/change/")
        @test r.status == 200 && occursin("View article", text(r))
        @test post(c, "/staff/project/article/$(big.id)/change/", Dict("title" => "x")).status == 403
        @test occursin("Change article", text(get(c, "/staff/project/article/$(hot.id)/change/")))
        @test get(c, "/staff/project/article/$(hot.id)/delete/").status == 403

        # custom views go through the site's checks and reverse within the site
        @test text(get(c, "/staff/project/article/$(hot.id)/publish/")) == "publishing $(hot.id) at /staff/project/article/"
        @test text(get(c, "/staff/stats/")) == "stats for root"
        @test reverse_url("staff:article_publish"; id = 3) == "/staff/project/article/3/publish/" && reverse_url("admin:index") == "/admin/"
        other = create_user("staffer2", "pw12345pw"; is_staff = true)
        c2 = Client(); force_login!(c2, other)
        r = get(c2, "/staff/")
        @test r.status == 302 && startswith(getheader(r, "Location"), "/staff/login/")
        @test get(c2, "/staff/stats/").status == 302 && get(c2, "/staff/project/article/$(hot.id)/publish/").status == 302
        @test occursin("Site administration", text(get(c, "/admin/")))              # the default site is unchanged
    finally
        configure!(ROOT_URLCONF = old)
    end
end

@testset "admin: hooks, sorting, display columns, form field hooks (#143)" begin
    root_user()
    c = Client(); force_login!(c, get(User; username = "root"))
    ann = ann_author()
    bob = first(filter(Author; name = "Bob143")); bob === nothing && (bob = create(Author; name = "Bob143", email = "b@143"))
    for (t, v) in (("s143 b", 20), ("s143 a", 30), ("s143 c", 10))
        create(Article; title = t, author = ann, views = v)
    end
    saved = Any[]; deleted = Any[]
    try
        Admin.register!(Article; list_display = [:title, :views, Admin.display(a -> a.views > 15; description = "Popular", boolean = true),
                                                 Admin.display(a -> uppercase(a.title); description = "Shout", ordering = "-title"),
                                                 Admin.display(a -> nothing; description = "Nothing", empty_value = "(none)")],
                        search_fields = [:title], list_display_links = [:views], empty_value_display = "n/a",
                        search_help_text = "Search by title", save_on_top = true,
                        save_model = (req, obj, form, change) -> (obj.body = "saved by $(req.user.username)"; save!(obj); push!(saved, change)),
                        delete_model = (req, obj) -> (push!(deleted, obj.title); delete!(obj)),
                        response_add = (req, obj) -> Juango.HttpResponseRedirect("/added/$(obj.id)/"),
                        formfield_for_foreignkey = (req, f) -> f.name === :author ? ModelChoiceField(filter(Author; name = "Bob143")) : nothing,
                        radio_fields = [:status])
        r = get(c, "/admin/project/article/?q=s143")
        body = text(r)
        @test occursin(r"<th><a href=\"\?[^\"]*o=1[^\"]*\">Title</a></th>", body)
        @test occursin("Search by title", body)
        @test occursin("title=\"True\">✔", body) && occursin("(none)", body)
        @test occursin("<td>s143 a</td>", body) && occursin("<th><a href=", body)                      # the link is on views now
        titles(b) = [m[1] for m in eachmatch(r"<td>(s143 [abc])</td>", b)]
        @test titles(text(get(c, "/admin/project/article/?q=s143&o=1"))) == ["s143 a", "s143 b", "s143 c"]
        @test titles(text(get(c, "/admin/project/article/?q=s143&o=-2"))) == ["s143 a", "s143 b", "s143 c"]      # views 30, 20, 10
        @test titles(text(get(c, "/admin/project/article/?q=s143&o=4"))) == ["s143 c", "s143 b", "s143 a"]       # Shout sorts by -title
        @test occursin("class=\"sorted asc\"", text(get(c, "/admin/project/article/?q=s143&o=1")))
        @test titles(text(get(c, "/admin/project/article/?q=s143&o=3"))) |> length == 3                         # not sortable: ignored
        # the change form: radio choices, the narrowed foreign key, save buttons on top too
        r = get(c, "/admin/project/article/add/")
        @test occursin("type=\"radio\" name=\"status\"", text(r)) && count("name=\"_save\"", text(r)) == 2
        @test occursin(">Bob143</option>", text(r)) && !occursin(">Ann</option>", text(r))
        r = post(c, "/admin/project/article/add/", Dict("title" => "s143 new", "author" => string(bob.id), "status" => "p", "views" => "0"))
        new = get(Article; title = "s143 new")
        @test r.status == 302 && getheader(r, "Location") == "/added/$(new.id)/" && new.body == "saved by root" && saved == [false]
        r = post(c, "/admin/project/article/$(new.id)/delete/", Dict("post" => "yes"))
        @test deleted == ["s143 new"] && !exists(filter(Article; title = "s143 new"))
    finally
        Admin.register!(Article; list_display = [:title, :author, :status, :published, "Len" => a -> length(a.body)],
                        search_fields = [:title, :body], list_filter = [:published, :status, :author])
        delete!(filter(Article; title__startswith = "s143"))
    end
end

@testset "admin: get_* hooks, show all, preserved filters, the password page (#143)" begin
    root = root_user()
    c = Client(); force_login!(c, root)
    ann = ann_author()
    for i in 1:3
        create(Article; title = "pf143 $i", author = ann, slug = "pf143-$i")
    end
    try
        Admin.register!(Article; list_display = [:title], search_fields = [:title], list_per_page = 2, list_max_show_all = 5,
                        get_exclude = (req, obj) -> obj === nothing ? [:body] : Symbol[],
                        get_fieldsets = (req, obj) -> obj === nothing ? [] : ["Main" => [:title, :author], "More" => [:status, :views]],
                        get_prepopulated_fields = (req, obj) -> Dict(:slug => [:title]))
        r = get(c, "/admin/project/article/?q=pf143")
        body = text(r)
        @test occursin("Show all", body) && occursin("/change/?_changelist_filters=q%3Dpf143", body)
        @test count("<td>pf143", text(get(c, "/admin/project/article/?q=pf143&all="))) + count(">pf143", text(get(c, "/admin/project/article/?q=pf143&all="))) >= 3
        @test !occursin("name=\"body\"", text(get(c, "/admin/project/article/add/"))) && occursin("\"target\":\"id_slug\"", text(get(c, "/admin/project/article/add/")))
        a = get(Article; title = "pf143 1")
        r = get(c, "/admin/project/article/$(a.id)/change/")
        @test occursin("<h2>Main</h2>", text(r)) && occursin("<h2>More</h2>", text(r)) && occursin("name=\"body\"", text(r)) == false
        # saving goes back to the filtered list
        r = post(c, "/admin/project/article/$(a.id)/change/?_changelist_filters=q%3Dpf143",
                 Dict("title" => "pf143 1b", "author" => string(ann.id), "status" => "p", "views" => "0", "_save" => "1"))
        @test r.status == 302 && getheader(r, "Location") == "/admin/project/article/?q=pf143"
        r = post(c, "/admin/project/article/$(a.id)/change/?_changelist_filters=q%3Dpf143",
                 Dict("title" => "pf143 1c", "author" => string(ann.id), "status" => "p", "views" => "0", "_continue" => "1"))
        @test endswith(getheader(r, "Location"), "/change/?_changelist_filters=q%3Dpf143")
        # facets: counts per filter choice, with the search applied
        Admin.register!(Article; list_display = [:title], search_fields = [:title], list_filter = [:status])
        @test occursin("Show counts", text(get(c, "/admin/project/article/?q=pf143")))
        body = text(get(c, "/admin/project/article/?q=pf143&_facets=1"))
        @test occursin("All (3)", body) && occursin("Hide counts", body)
        Admin.register!(Article; list_display = [:title], list_filter = [:status], show_facets = :never)
        @test !occursin("Show counts", text(get(c, "/admin/project/article/")))
    finally
        Admin.register!(Article; list_display = [:title, :author, :status, :published, "Len" => a -> length(a.body)],
                        search_fields = [:title, :body], list_filter = [:published, :status, :author])
        delete!(filter(Article; title__startswith = "pf143"))
    end
    # filter_horizontal: the many-to-many select is marked for the two-list widget
    Admin.register!(Essay; filter_horizontal = [:topics])
    try
        r = get(c, "/admin/project/essay/add/")
        @test occursin("data-filter-box=\"horizontal\"", text(r)) && occursin("select[data-filter-box]", text(r))
    finally
        Admin.unregister!(Essay)
    end
    # the user admin: a summary and its own password page
    u = first(filter(User; username = "pw143")); u === nothing && (u = create_user("pw143", "Old-pass-143"))
    r = get(c, "/admin/auth/user/$(u.id)/change/")
    @test occursin("Change the password", text(r)) && !occursin("type=\"password\" name=\"password\"", text(r))
    r = get(c, "/admin/auth/user/$(u.id)/password/")
    @test r.status == 200 && occursin("name=\"password1\"", text(r))
    r = post(c, "/admin/auth/user/$(u.id)/password/", Dict("password1" => "New-pass-143x", "password2" => "different"))
    @test r.status == 200 && occursin("didn’t match", text(r))
    r = post(c, "/admin/auth/user/$(u.id)/password/", Dict("password1" => "New-pass-143x", "password2" => "New-pass-143x"))
    @test r.status == 302 && authenticate("pw143", "New-pass-143x") !== nothing
    @test get(c, "/admin/project/article/1/password/").status == 404                      # only where password_change_page is on
end

# a model named like the project's Article, in another app (#159)
module AdminDup
using Juango
@model struct Article
    title = CharField(max_length = 50)
    Meta(app_label = "dupapp", table = "dupapp_article")
end
end

@testset "admin: models under their app, grouped index, Django's URL names (#159)" begin
    redirect_stdout(() -> Juango.sync_models!([AdminDup.Article]), devnull)
    Admin.register!(AdminDup.Article; list_display = [:title])
    try
        c = Client()
        force_login!(c, root_user())
        @test Admin.is_registered(Article) && Admin.is_registered(AdminDup.Article)
        @test Admin.model_admin(Article).model === Article && Admin.model_admin(AdminDup.Article).model === AdminDup.Article
        create(AdminDup.Article; title = "from dupapp")
        r = get(c, "/admin/dupapp/article/")
        @test r.status == 200 && occursin("from dupapp", text(r)) && !occursin("AGV", text(r))
        @test occursin("href=\"/admin/dupapp/\"", text(r))                                    # the app in the breadcrumbs
        r = get(c, "/admin/project/article/")
        @test r.status == 200 && !occursin("from dupapp", text(r))
        # the index, grouped by app, and each app's page
        t = text(get(c, "/admin/"))
        @test occursin("href=\"/admin/auth/\"", t) && occursin("Authentication and Authorization", t) && occursin("href=\"/admin/dupapp/\"", t)
        @test findfirst("Authentication and Authorization", t).start < findfirst("Dupapp", t).start            # apps by name
        r = get(c, "/admin/auth/")
        @test r.status == 200 && occursin("Users", text(r)) && occursin("Groups", text(r)) && !occursin("Articles", text(r))
        @test occursin("Authentication and Authorization administration", text(r))
        @test get(c, "/admin/nosuchapp/").status == 404 && get(c, "/admin/dupapp/nosuch/").status == 404
        # Django's names: admin:<app>_<model>_changelist, _add, _change, _delete, _history
        u = root_user()
        @test reverse_url("admin:auth_user_changelist") == "/admin/auth/user/"
        @test reverse_url("admin:auth_user_add") == "/admin/auth/user/add/"
        @test reverse_url("admin:project_article_change"; object_id = 3) == "/admin/project/article/3/change/"
        @test reverse_url("admin:project_article_delete", 3) == "/admin/project/article/3/delete/"
        @test reverse_url("admin:project_article_history"; object_id = 3) == "/admin/project/article/3/history/"
        @test reverse_url("admin:app_list"; app = "auth") == "/admin/auth/"
        @test get(c, reverse_url("admin:auth_user_change"; object_id = u.id)).status == 200
        @test get(c, reverse_url("admin:auth_user_changelist")).status == 200
        @test render(Template("{% url 'admin:auth_user_change' u.id %}"), Dict("u" => u)) == "/admin/auth/user/$(u.id)/change/"
    finally
        Admin.unregister!(AdminDup.Article)
    end
    @test !Admin.is_registered(AdminDup.Article) && Admin.is_registered(Article)
end
