# More of Django's admin_views tests, ported (#227, part 3; parts 1-2 are in django_admin.jl): LimitChoicesToInAdminTest,
# RawIdFieldsTest (the raw id lookup popups with limit_choices_to), UserAdminTest (adding users, their popups), GroupAdminTest,
# AdminUserMessageTest, and the success messages' links (AdminViewBasicTest's test_basic_add_POST / change messages).
# julia --project=test test/django_admin_views.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DavActor
    name = CharField(max_length = 50)
    age = IntegerField()
    title = CharField(max_length = 50, null = true, blank = true)
    Meta(table = "dav_actor")
end
Base.show(io::IO, a::DavActor) = print(io, a.name)
@model struct DavInquisition
    expected = BooleanField(default = false)
    leader = ForeignKey(DavActor, on_delete = :CASCADE)
    country = CharField(max_length = 20)
    Meta(table = "dav_inquisition")
end
Base.show(io::IO, i::DavInquisition) = print(io, "by ", i.leader, " from ", i.country)
@model struct DavSketch
    title = CharField(max_length = 100)
    inquisition = ForeignKey(DavInquisition, on_delete = :CASCADE,
                             limit_choices_to = Dict("leader__name" => "Palin", "leader__age" => 27, "expected" => false))
    defendant0 = ForeignKey(DavActor, on_delete = :CASCADE, related_name = :dav_d0, limit_choices_to = Dict("title__isnull" => false))
    defendant1 = ForeignKey(DavActor, on_delete = :CASCADE, related_name = :dav_d1, limit_choices_to = Dict("title__isnull" => true))
    Meta(table = "dav_sketch")
end
@model struct DavCharacter
    username = CharField(max_length = 100)
    last_action = DateTimeField()
    Meta(table = "dav_character")
end
Base.show(io::IO, c::DavCharacter) = print(io, c.username)
dav_today() = Dict("last_action__gte" => DateTime(today()))
@model struct DavStumpJoke
    variation = CharField(max_length = 100)
    most_recently_fooled = ForeignKey(DavCharacter, on_delete = :CASCADE, limit_choices_to = dav_today, related_name = :dav_jokes)
    has_fooled_today = ManyToManyField(DavCharacter; limit_choices_to = dav_today, related_name = :dav_fooled)
    Meta(table = "dav_stumpjoke")
end
@model struct DavAlbum
    owner = ForeignKey(Juango.User, on_delete = :SET_NULL, null = true, blank = true, related_name = :dav_albums)
    title = CharField(max_length = 30)
    Meta(table = "dav_album")
end
@model struct DavMessenger
    name = CharField(max_length = 20)
    Meta(table = "dav_messenger")
end
@model struct DavBook
    name = CharField(max_length = 100)
    Meta(table = "dav_book")
end
Base.show(io::IO, b::DavBook) = print(io, b.name)
@model struct DavChapter
    title = CharField(max_length = 100)
    content = TextField()
    book = ForeignKey(DavBook, on_delete = :CASCADE, related_name = :chapter_set)
    Meta(table = "dav_chapter")
end
Base.show(io::IO, c::DavChapter) = print(io, c.title)
@model struct DavCoverLetter
    author = CharField(max_length = 30)
    Meta(table = "dav_coverletter")
end
Base.show(io::IO, c::DavCoverLetter) = print(io, c.author)
@model struct DavParent
    name = CharField(max_length = 128)
    Meta(table = "dav_parent")
end
@model struct DavChild
    parent = ForeignKey(DavParent, on_delete = :CASCADE, related_name = :child_set)
    name = CharField(max_length = 30, blank = true)
    Meta(table = "dav_child")
end
@model struct DavPerson
    name = CharField(max_length = 100)
    gender = IntegerField()
    alive = BooleanField(default = true)
    Meta(table = "dav_person")
end
Base.show(io::IO, p::DavPerson) = print(io, p.name)
@model struct DavTitle
    Meta(table = "dav_title")
end
@model struct DavTitleTranslation
    title = ForeignKey(DavTitle, on_delete = :CASCADE, related_name = :titletranslation)
    text = CharField(max_length = 100)
    Meta(table = "dav_titletranslation")
end
@model struct DavRecommender <: DavTitle
    Meta(table = "dav_recommender")
end
@model struct DavRecommendation <: DavTitle
    the_recommender = ForeignKey(DavRecommender, on_delete = :CASCADE, related_name = :recommendations)
    Meta(table = "dav_recommendation")
end
@model struct DavPluggable
    name = CharField(max_length = 100)
    age = IntegerField()
    Meta(table = "dav_pluggable")
end
Base.show(io::IO, p::DavPluggable) = print(io, p.name)
@model struct DavFoodDelivery
    reference = CharField(max_length = 100)
    driver = CharField(max_length = 100, blank = true)
    restaurant = CharField(max_length = 100, blank = true)
    Meta(table = "dav_fooddelivery", unique_together = [(:driver, :restaurant)], ordering = ["id"])
end
@model struct DavCategory
    order = PositiveIntegerField()
    Meta(table = "dav_category", ordering = ["order"])
end
@model struct DavUnordered
    name = CharField(max_length = 255)
    bool = BooleanField(default = true)
    Meta(table = "dav_unordered")
end
Base.show(io::IO, u::DavUnordered) = print(io, u.name)
redirect_stdout(devnull) do
    ms = [DavActor, DavInquisition, DavSketch, DavCharacter, DavStumpJoke, through(DavStumpJoke, :has_fooled_today), DavAlbum, DavMessenger,
          DavBook, DavChapter, DavCoverLetter, DavParent, DavChild, DavPerson, DavTitle, DavTitleTranslation, DavRecommender,
          DavRecommendation, DavPluggable, DavFoodDelivery, DavCategory, DavUnordered]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
    Juango.update_permissions!(ms)
end
const DAV = "/admin/project"
dav_super(name) = (u = create_superuser(name, "secret"); c = Client(); force_login!(c, get(User; id = u.id)); c)
"The page a redirect leads to (Django's follow=True)."
dav_follow(c, r) = r.status in (301, 302) ? get(c, getheader(r, "Location")) : r
dav_lookup_url(t, field) = (m = match(Regex("<a href=\"([^\"]*)\"[^>]* id=\"lookup_id_$field\""), t); m === nothing ? nothing : replace(m[1], "&amp;" => "&"))

@testset "django admin_views: LimitChoicesToInAdminTest, RawIdFieldsTest" begin
    port_block() do
        Admin.register!(DavStumpJoke); Admin.register!(DavCharacter); Admin.register!(DavActor)
        Admin.register!(DavInquisition; list_display = [:country, :expected])
        Admin.register!(DavSketch; raw_id_fields = [:inquisition, :defendant0, :defendant1])
        try
            c = dav_super("dav_super1")
            # test_limit_choices_to_as_callable: only today's characters, in the select and the multiple select
            create(DavCharacter; username = "threepwood", last_action = now() + Day(1))
            create(DavCharacter; username = "marley", last_action = now() - Day(1))
            t = text(get(c, "$DAV/davstumpjoke/add/"))
            @test count("threepwood", t) == 2 && !occursin("marley", t)
            # test_limit_choices_to: the lookup popup filters by a string, an integer and a boolean across relations
            palin = create(DavActor; name = "Palin", age = 27)
            create(DavInquisition; expected = true, leader = palin, country = "England")
            create(DavInquisition; expected = false, leader = palin, country = "Spain")
            t = text(get(c, "$DAV/davsketch/add/"))
            u = dav_lookup_url(t, "inquisition")
            @test u !== nothing
            t2 = text(get(c, u * "&_popup=1"))
            @test occursin("Spain", t2) && !occursin("England", t2)
            # test_limit_choices_to_isnull_false, test_limit_choices_to_isnull_true
            create(DavActor; name = "Kilbraken", age = 50, title = "Judge")
            t2 = text(get(c, dav_lookup_url(t, "defendant0") * "&_popup=1"))
            @test occursin("Kilbraken", t2) && !occursin(">Palin<", t2)
            t2 = text(get(c, dav_lookup_url(t, "defendant1") * "&_popup=1"))
            @test !occursin("Kilbraken", t2) && occursin(">Palin<", t2)
        finally
            foreach(Admin.unregister!, [DavStumpJoke, DavCharacter, DavActor, DavInquisition, DavSketch])
        end
    end
end

@testset "django admin_views: UserAdminTest, GroupAdminTest" begin
    port_block() do
        Admin.register_builtin!()
        Admin.register!(DavAlbum)
        try
            c = dav_super("dav_super2")
            changeuser = create_user("dav_changeuser", "secret"); changeuser.is_staff = true; save!(changeuser)
            n = count(objects(User))
            # test_save_button: adding a user goes on to its change page
            r = post(c, "/admin/auth/user/add/", Dict("username" => "dav_newuser", "password1" => "newpassword", "password2" => "newpassword"))
            nu = get(User; username = "dav_newuser")
            url = "/admin/auth/user/$(nu.id)/change/"
            @test r.status == 302 && getheader(r, "Location") == url && count(objects(User)) == n + 1 && Juango.has_usable_password(nu)
            # test_save_continue_editing_button: the message links the new user
            r = post(c, "/admin/auth/user/add/", Dict("username" => "dav_newuser2", "password1" => "newpassword", "password2" => "newpassword", "_continue" => "1"))
            nu2 = get(User; username = "dav_newuser2")
            url2 = "/admin/auth/user/$(nu2.id)/change/"
            @test getheader(r, "Location") == url2
            @test occursin("The user “<a href=\"$url2\">dav_newuser2</a>” was added successfully. You may edit it again below.", text(get(c, url2)))
            # test_password_mismatch
            r = post(c, "/admin/auth/user/add/", Dict("username" => "dav_newuser3", "password1" => "newpassword", "password2" => "mismatch"))
            @test r.status == 200 && occursin("The two password fields didn’t match.", text(r))
            # test_save_add_another_button
            r = post(c, "/admin/auth/user/add/", Dict("username" => "dav_newuser4", "password1" => "newpassword", "password2" => "newpassword", "_addanother" => "1"))
            @test r.status == 302 && getheader(r, "Location") == "/admin/auth/user/add/" && exists(filter(User; username = "dav_newuser4"))
            # test_user_fk_add_popup, test_user_fk_change_popup, test_user_fk_delete_popup
            t = text(get(c, "$DAV/davalbum/add/"))
            @test occursin("/admin/auth/user/add/", t) && occursin("class=\"related-widget-wrapper-link add-related\" id=\"add_id_owner\"", t)
            @test occursin("/admin/auth/user/__fk__/change/", t) && occursin("/admin/auth/user/__fk__/delete/", t)
            @test occursin("class=\"related-widget-wrapper-link change-related\" id=\"change_id_owner\"", t)
            t = text(get(c, "/admin/auth/user/add/?_popup=1"))
            @test !occursin("name=\"_continue\"", t) && !occursin("name=\"_addanother\"", t)
            r = post(c, "/admin/auth/user/add/?_popup=1", Dict("username" => "dav_popupuser", "password1" => "newpassword", "password2" => "newpassword",
                                                               "_popup" => "1", "_save" => "1"))
            @test occursin("&quot;obj&quot;:&quot;dav_popupuser&quot;", text(r))
            r = post(c, "/admin/auth/user/$(changeuser.id)/change/?_popup=1", Dict("username" => "dav_renamed", "is_active" => "on", "is_staff" => "on",
                                                                                   "_popup" => "1", "_save" => "1"))
            @test occursin("&quot;obj&quot;:&quot;dav_renamed&quot;", text(r)) && occursin("&quot;action&quot;:&quot;change&quot;", text(r))
            @test get(c, "/admin/auth/user/$(changeuser.id)/delete/?_popup=1").status == 200
            r = post(c, "/admin/auth/user/$(changeuser.id)/delete/?_popup=1", Dict("post" => "yes", "_popup" => "1"))
            @test occursin("&quot;action&quot;:&quot;delete&quot;", text(r))
            # GroupAdminTest test_save_button: back to the change list
            ng = count(objects(Juango.Group))
            r = post(c, "/admin/auth/group/add/", Dict("name" => "dav_newgroup"))
            @test r.status == 302 && getheader(r, "Location") == "/admin/auth/group/" && count(objects(Juango.Group)) == ng + 1
            # (the change message links the page itself; a user who may only add gets no link)
            g = get(Juango.Group; name = "dav_newgroup")
            r = post(c, "/admin/auth/group/$(g.id)/change/", Dict("name" => "dav_group2"))
            @test occursin("The group “<a href=\"/admin/auth/group/$(g.id)/change/\">dav_group2</a>” was changed successfully.", text(dav_follow(c, r)))
            adder = create_user("dav_adder", "secret"); adder.is_staff = true; save!(adder)
            add!(adder.user_permissions, get(Permission; codename = "add_group"))
            ca = Client(); force_login!(ca, get(User; id = adder.id))
            r = post(ca, "/admin/auth/group/add/", Dict("name" => "dav_g3", "_continue" => "1"))
            @test r.status == 302
            t = text(get(ca, "/admin/"))
            @test occursin("The group “dav_g3” was added successfully.", t) && !occursin("You may edit it again below.", t)
            # (an object with HTML in its name is escaped in the message)
            r = post(c, "/admin/auth/group/add/", Dict("name" => "<b>bold</b>"))
            t = text(dav_follow(c, r))
            @test occursin("&lt;b&gt;bold&lt;/b&gt;", t) && !occursin("<b>bold</b>", t)
        finally
            Admin.unregister!(DavAlbum)
        end
    end
end

@testset "django admin_views: AdminUserMessageTest" begin
    port_block() do
        msg(level; tags = "") = Admin.action((ma, req, qs) -> message!(req, level, "Test $(level)"; extra_tags = tags); name = "message_$(level)")
        Admin.register!(DavMessenger; actions = [msg(:debug), msg(:info), msg(:success), msg(:warning), msg(:error),
                                                 Admin.action((ma, req, qs) -> message!(req, :info, "Test tags"; extra_tags = "extra_tag"); name = "message_extra_tags")])
        try
            c = dav_super("dav_super3")
            m = create(DavMessenger; name = "m")
            send(action) = text(dav_follow(c, post(c, "$DAV/davmessenger/", Dict("_selected_action" => string(m.id), "action" => action, "index" => "0"))))
            override_settings(MESSAGE_LEVEL = 10) do                                                     # test_message_debug
                @test occursin("<li class=\"debug\">Test debug</li>", send("message_debug"))
            end
            for level in ("info", "success", "warning", "error")                                       # test_message_info, ..._success, ..._warning, ..._error
                @test occursin("<li class=\"$level\">Test $level</li>", send("message_$level"))
            end
            @test occursin("<li class=\"extra_tag info\">Test tags</li>", send("message_extra_tags"))   # test_message_extra_tags
        finally
            Admin.unregister!(DavMessenger)
        end
    end
end

dav_secure(req) = HttpResponse("secret")
@testset "django admin_views: SecureViewTests" begin
    urls = vcat(Any[path("secure-view/", staff_member_required(dav_secure)),
                    path("secure-view2/", staff_member_required(dav_secure; redirect_field_name = "myfield"))], settings.ROOT_URLCONF)
    override_settings(ROOT_URLCONF = urls) do
        # test_secure_view_shows_login_if_not_logged_in, test_staff_member_required_decorator_works_with_argument
        r = get(Client(), "/secure-view/")
        @test r.status == 302 && getheader(r, "Location") == "/admin/login/?next=/secure-view/"
        r = get(Client(), "/secure-view2/")
        @test r.status == 302 && getheader(r, "Location") == "/admin/login/?myfield=/secure-view2/"
    end
end

@testset "django admin_views: AdminViewUnicodeTest, AdminConsecutiveWhiteSpaceObjectDisplayTest, AdminCustomSaveRelatedTests" begin
    port_block() do
        Admin.register!(DavBook; inlines = [Admin.TabularInline(DavChapter; extra = 3)])
        Admin.register!(DavCoverLetter)
        # save_related: the children take the parent's surname (Django's ParentAdmin)
        surname!(parent) = for ch in collect(parent.child_set)
            endswith(ch.name, " " * last(split(parent.name))) || (ch.name = ch.name * " " * last(split(parent.name)); save!(ch))
        end
        Admin.register!(DavParent; inlines = [Admin.TabularInline(DavChild; extra = 3)], list_editable = [:name], list_display = [:id, :name],
                        save_related = function (req, form, formsets, change)
                            Juango.save_m2m!(form); foreach(save!, formsets); surname!(form.instance)
                        end)
        try
            c = dav_super("dav_super4")
            b = create(DavBook; name = "Lærdommer")
            ch = [create(DavChapter; title = t, content = "<p>x</p>", book = b) for t in ("Norske bostaver æøå skaper problemer", "Kjærlighet", "Kjærlighet")]
            # test_unicode_edit
            post_data = Dict("name" => "Test lærdommer", "chapter_set-TOTAL_FORMS" => "6", "chapter_set-INITIAL_FORMS" => "3", "chapter_set-MAX_NUM_FORMS" => "0")
            for (i, (cc, title)) in enumerate(zip(ch, ("Norske bostaver æøå skaper problemer", "Kjærlighet.", "Need a title.")))
                post_data["chapter_set-$(i-1)-id"] = string(cc.id); post_data["chapter_set-$(i-1)-title"] = title
                post_data["chapter_set-$(i-1)-content"] = "&lt;p&gt;Svært frustrerende med UnicodeDecodeError&lt;/p&gt;"
            end
            r = post(c, "$DAV/davbook/$(b.id)/change/", post_data)
            @test r.status == 302 && get(DavBook; id = b.id).name == "Test lærdommer"
            # test_unicode_delete
            @test get(c, "$DAV/davbook/$(b.id)/delete/").status == 200
            r = post(c, "$DAV/davbook/$(b.id)/delete/", Dict("post" => "yes"))
            @test r.status == 302 && getheader(r, "Location") == "$DAV/davbook/"
            # AdminConsecutiveWhiteSpaceObjectDisplayTest: an object whose name is only spaces shows as "-"
            cl = create(DavCoverLetter; author = "             ")
            change = "$DAV/davcoverletter/$(cl.id)/change/"
            @test occursin("› -</div>", text(get(c, change)))                                         # test_display_consecutive_whitespace_object_in_breadcrumbs
            t = text(get(c, "$DAV/davcoverletter/$(cl.id)/delete/"))                                   # ..._in_delete_confirmation_page, ..._in_deleted_object
            @test occursin("Are you sure you want to delete the dav cover letter “-”?", t) && occursin("Dav cover letter: <a href=\"$change\">-</a>", t)
            @test occursin("<a href=\"$change\">-</a>", text(get(c, "$DAV/davcoverletter/")))       # ..._in_changelist
            @test occursin("-", text(get(c, "$DAV/davcoverletter/$(cl.id)/history/")))
            # AdminCustomSaveRelatedTests: test_should_be_able_to_edit_related_objects_on_add_view, ..._on_change_view, ..._on_changelist_view
            post(c, "$DAV/davparent/add/", Dict("child_set-TOTAL_FORMS" => "3", "child_set-INITIAL_FORMS" => "0", "name" => "Josh Stone",
                                                "child_set-0-name" => "Paul", "child_set-1-name" => "Catherine"))
            @test count(objects(DavParent)) == 1 && sort([x.name for x in collect(objects(DavChild))]) == ["Catherine Stone", "Paul Stone"]
            delete!(objects(DavChild)); delete!(objects(DavParent))
            p = create(DavParent; name = "Josh Stone")
            paul = create(DavChild; parent = p, name = "Paul"); cat = create(DavChild; parent = p, name = "Catherine")
            post(c, "$DAV/davparent/$(p.id)/change/", Dict("child_set-TOTAL_FORMS" => "5", "child_set-INITIAL_FORMS" => "2", "name" => "Josh Stone",
                                                          "child_set-0-name" => "Paul", "child_set-0-id" => string(paul.id),
                                                          "child_set-1-name" => "Catherine", "child_set-1-id" => string(cat.id)))
            @test sort([x.name for x in collect(objects(DavChild))]) == ["Catherine Stone", "Paul Stone"]
            delete!(objects(DavChild)); delete!(objects(DavParent))
            p = create(DavParent; name = "Josh Rock")
            create(DavChild; parent = p, name = "Paul"); create(DavChild; parent = p, name = "Catherine")
            post(c, "$DAV/davparent/", Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                                            "form-0-id" => string(p.id), "form-0-name" => "Josh Stone", "_save" => "Save"))
            @test get(DavParent; id = p.id).name == "Josh Stone" && sort([x.name for x in collect(objects(DavChild))]) == ["Catherine Stone", "Paul Stone"]
        finally
            foreach(Admin.unregister!, [DavBook, DavCoverLetter, DavParent])
        end
    end
    # not translated: TestLabelVisibility (Django's fieldset markup)
end

"How many rows a searched change list says it found (\"N result(s) (...)\")."
dav_found(t) = (m = match(r"(\d+) results? \(", t); m === nothing ? -1 : parse(Int, m[1]))
@testset "django admin_views: AdminSearchTest" begin
    port_block() do
        Admin.register!(DavPerson; search_fields = ["^name"], list_display = [:name])
        Admin.register!(DavRecommendation; search_fields = ["=titletranslation__text", "=the_recommender__titletranslation__text"],
                        show_full_result_count = false)
        # test_pluggable_search: the name as usual, and the age when the term is a number
        Admin.register!(DavPluggable; search_fields = [:name], list_display = [:name],
                        get_search_results = function (req, qs, term)
                            r, dups = Admin.search_results(DavPluggable, qs, [:name], term)
                            n = tryparse(Int, term)
                            n === nothing ? (r, dups) : (filter(qs, Q(name__icontains = term) | Q(age = n)), dups)
                        end)
        Admin.register_builtin!()
        try
            c = dav_super("dav_super5")
            joe = create_user("dav_joepublic", "secret")
            for (n, a) in (("John Mauchly", true), ("Grace Hopper", false), ("Guido van Rossum", true), ("John Doe", true),
                           ("John O\"Hara", true), ("John O'Hara", true))
                create(DavPerson; name = n, gender = 1, alive = a)
            end
            t1 = create(DavRecommender); t2 = create(DavRecommendation; the_recommender = t1)
            t3 = create(DavRecommender); t4 = create(DavRecommendation; the_recommender = t3)
            for (t, txt) in ((t1, "Bar"), (t2, "Foo"), (t3, "Few"), (t4, "Bas"))
                create(DavTitleTranslation; title = get(DavTitle; id = t.id), text = txt)
            end
            # test_search_on_sibling_models, test_exact_matches
            @test dav_found(text(get(c, "$DAV/davrecommendation/?q=bar"))) == 1
            @test dav_found(text(get(c, "$DAV/davrecommendation/?q=ba"))) == 0
            # test_with_fk_to_field: _to_field is kept when searching (in a popup)
            t = text(get(c, "/admin/auth/user/?q=dav_joe&_to_field=id&_popup=1"))
            @test dav_found(t) == 1 && occursin("<input type=\"hidden\" name=\"_to_field\" value=\"id\">", t)
            # test_beginning_matches
            t = text(get(c, "$DAV/davperson/?q=Gui"))
            @test dav_found(t) == 1 && occursin("Guido", t)
            t = text(get(c, "$DAV/davperson/?q=uido"))
            @test dav_found(t) == 0 && !occursin("Guido", t)
            # test_pluggable_search
            create(DavPluggable; name = "Bob", age = 10); create(DavPluggable; name = "Amy", age = 20)
            t = text(get(c, "$DAV/davpluggable/?q=Bob"))
            @test dav_found(t) == 1 && occursin("Bob", t)
            t = text(get(c, "$DAV/davpluggable/?q=20"))
            @test dav_found(t) == 1 && occursin("Amy", t)
            # test_reset_link, test_no_total_count
            @test occursin("1 result (<a href=\"?\">6 total</a>)", text(get(c, "$DAV/davperson/?q=Gui")))
            @test occursin("1 result (<a href=\"?\">Show all</a>)", text(get(c, "$DAV/davrecommendation/?q=bar")))
            # test_search_with_spaces: quoted phrases, and quotes escaped inside them
            for (q, hits) in [("\"John Doe\"", 1), ("'John Doe'", 1), ("John Doe", 0), ("\"John Doe\" John", 1), ("'John Doe' John", 1),
                              ("John Doe John", 0), ("\"John Do\"", 1), ("'John Do'", 1), ("'John O'Hara'", 0), ("'John O\\'Hara'", 1),
                              ("\"John O\"Hara\"", 0), ("\"John O\\\"Hara\"", 1)]
                @test dav_found(text(get(c, "$DAV/davperson/?q=" * Juango.urlquote(q)))) == hits
            end
        finally
            foreach(Admin.unregister!, [DavPerson, DavRecommendation, DavPluggable])
        end
    end
end

@testset "django admin_views: AdminViewListEditable" begin
    port_block() do
        Admin.register!(DavPerson; list_display = [:name, :gender, :alive], list_editable = [:gender, :alive], list_filter = [:gender],
                        search_fields = [:name], actions = [Admin.action((ma, req, qs) -> message!(req, :info, "acted"); name = "mark")])
        Admin.register!(DavFoodDelivery; list_display = [:reference, :driver, :restaurant], list_editable = [:driver, :restaurant])
        Admin.register!(DavCategory; list_display = [:id, :order], list_editable = [:order])
        Admin.register!(DavUnordered; list_display = [:name, :bool], list_editable = [:bool], list_per_page = 2)
        try
            c = dav_super("dav_super6")
            delete!(objects(DavPerson))
            per1 = create(DavPerson; name = "John Mauchly", gender = 1, alive = true)
            per2 = create(DavPerson; name = "Grace Hopper", gender = 1, alive = false)
            per3 = create(DavPerson; name = "Guido van Rossum", gender = 1, alive = true)
            form(rows) = merge(Dict("form-TOTAL_FORMS" => string(length(rows)), "form-INITIAL_FORMS" => string(length(rows)), "form-MAX_NUM_FORMS" => "0",
                                    "_save" => "Save"),
                               Dict("form-$(i-1)-$k" => v for (i, r) in enumerate(rows) for (k, v) in r))
            # test_post_submission: the page's rows; a filtered page; a searched page
            post(c, "$DAV/davperson/", form([Dict("gender" => "1", "id" => string(per1.id)), Dict("gender" => "2", "id" => string(per2.id)),
                                             Dict("alive" => "on", "gender" => "1", "id" => string(per3.id))]))
            @test !get(DavPerson; id = per1.id).alive && get(DavPerson; id = per2.id).gender == 2
            post(c, "$DAV/davperson/?gender=1", form([Dict("id" => string(per1.id), "gender" => "1", "alive" => "on"),
                                                     Dict("id" => string(per3.id), "gender" => "1", "alive" => "on")]))
            @test get(DavPerson; id = per1.id).alive
            post(c, "$DAV/davperson/?q=john", form([Dict("id" => string(per1.id), "gender" => "1")]))
            @test !get(DavPerson; id = per1.id).alive
            # test_post_messages: one message for the save, no action warnings
            get(c, "$DAV/davperson/")                               # (the earlier saves' messages shown and gone)
            r = post(c, "$DAV/davperson/", form([Dict("gender" => "1", "id" => string(per1.id)), Dict("gender" => "2", "id" => string(per2.id)),
                                                 Dict("alive" => "on", "gender" => "1", "id" => string(per3.id))]))
            t = text(dav_follow(c, r))
            ml = match(r"<ul class=\"messagelist\">(.*?)</ul>"s, t)
            @test (ml === nothing ? t[1:min(end, 300)] : count("<li", ml[1])) == 1
            # test_forged_post_submission_when_no_add_permission: a row that would add an object is refused
            n = count(objects(DavPerson))
            r = post(c, "$DAV/davperson/", Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "0", "form-MAX_NUM_FORMS" => "0",
                                                "form-0-gender" => "1", "form-0-alive" => "on", "form-0-id" => "", "_save" => "Save"))
            @test r.status in (302, 400) && count(objects(DavPerson)) == n
            r = post(c, "$DAV/davperson/", Dict("form-TOTAL_FORMS" => "1", "form-INITIAL_FORMS" => "1", "form-MAX_NUM_FORMS" => "0",
                                                "form-0-gender" => "2", "form-0-id" => "999999", "_save" => "Save"))
            @test r.status in (200, 302, 400)
            @test count(objects(DavPerson)) == n                                    # (an unknown object: not added)
            # test_non_field_errors: each row's unique_together error, on its row
            fd = [create(DavFoodDelivery; reference = r_, driver = "bill", restaurant = x) for (r_, x) in (("123", "thai"), ("456", "india"), ("789", "pizza"))]
            rows(rs) = form([Dict("id" => string(f.id), "reference" => f.reference, "driver" => "bill", "restaurant" => x) for (f, x) in zip(fd, rs)])
            t = text(post(c, "$DAV/davfooddelivery/", rows(["thai", "thai", "pizza"])))
            @test count("with this Driver and Restaurant already exists.", t) == 1
            t = text(post(c, "$DAV/davfooddelivery/", rows(["thai", "thai", "thai"])))
            @test count("with this Driver and Restaurant already exists.", t) == 2
            # test_list_editable_ordering: the values land on the right objects though the order changes
            cats = [create(DavCategory; order = o) for o in (1, 2, 0, 0)]
            r = post(c, "$DAV/davcategory/", form([Dict("order" => o, "id" => string(cc.id)) for (cc, o) in zip(cats, ("14", "13", "1", "0"))]))
            @test r.status == 302 && [get(DavCategory; id = cc.id).order for cc in cats] == [14, 13, 1, 0]
            # test_list_editable_pagination
            for i in 1:3
                create(DavUnordered; name = "Unordered object #$i")
            end
            t = text(get(c, "$DAV/davunordered/"))
            @test occursin("Unordered object #3", t) && occursin("Unordered object #2", t) && !occursin("Unordered object #1", t)
            t = text(get(c, "$DAV/davunordered/?page=2"))
            @test !occursin("Unordered object #3", t) && occursin("Unordered object #1", t)
            # test_list_editable_action_submit: the action button runs the action, not the edits
            d = form([Dict("gender" => "1", "id" => string(per1.id)), Dict("gender" => "2", "id" => string(per2.id)),
                      Dict("alive" => "on", "gender" => "1", "id" => string(per3.id))])
            delete!(d, "_save"); d["index"] = "0"; d["_selected_action"] = string(per3.id); d["action"] = "mark"
            g2 = get(DavPerson; id = per2.id).gender
            post(c, "$DAV/davperson/", d)
            @test get(DavPerson; id = per2.id).gender == g2
            # test_list_editable_popup: no editing in a popup
            @test !occursin("form-0-gender", text(get(c, "$DAV/davperson/?_popup=1")))
            # test_list_editable_per_object_permissions, ..._submission: an object the user may not change shows its value, isn't saved
            Admin.register!(DavPerson; list_display = [:name, :gender, :alive], list_editable = [:gender, :alive],
                            has_change_permission = (req, obj) -> obj === nothing || obj.name != "Grace Hopper")
            t = text(get(c, "$DAV/davperson/"))
            @test count("name=\"form-", t) > 0
            gid = findfirst(==(per2.id), [p.id for p in collect(order_by(objects(DavPerson), "-id"))])
            @test !occursin("name=\"form-$(gid-1)-gender\"", t)
            post(c, "$DAV/davperson/", form([Dict("gender" => "2", "id" => string(per1.id)), Dict("gender" => "1", "id" => string(per2.id))]))
            @test get(DavPerson; id = per2.id).gender == 2 && get(DavPerson; id = per1.id).gender == 2
        finally
            foreach(Admin.unregister!, [DavPerson, DavFoodDelivery, DavCategory, DavUnordered])
        end
    end
    # not translated: the input counts and the action counter's markup (Django's change list template), custom
    # changelist formsets (non_form_errors), inherited and custom-pk change lists (tested elsewhere)
end
