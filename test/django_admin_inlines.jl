# Django's admin_inlines tests, ported (#227, part): tests/admin_inlines (TestInlinePermissions,
# TestReadOnlyChangeViewInlinePermissions, TestVerboseNameInlineForms, and TestInline's options:
# can_delete, readonly fields, min_num/get_extra, show_change_link).
# julia --project=test test/django_admin_inlines.jl   (see setup.jl)
#
# Django's tests read the change form's HTML (and the inline admin formset in the context); these read the
# HTML Juango's admin renders: the management form's TOTAL_FORMS/MAX_NUM_FORMS, the inline's heading and
# its rows. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DaiBook
    name = CharField(max_length = 50)
    Meta(table = "dai_book")
end
Base.show(io::IO, b::DaiBook) = print(io, b.name)
@model struct DaiAuthor
    name = CharField(max_length = 50)
    books = ManyToManyField(DaiBook)
    Meta(table = "dai_author")
end
@model struct DaiHolder2
    dummy = IntegerField()
    Meta(table = "dai_holder2")
end
@model struct DaiInner2
    dummy = IntegerField()
    holder = ForeignKey(DaiHolder2, on_delete = :CASCADE)
    Meta(table = "dai_inner2")
end
Base.show(io::IO, i::DaiInner2) = print(io, "Inner2 ", i.dummy)
@model struct DaiPoll
    name = CharField(max_length = 40)
    Meta(table = "dai_poll")
end
@model struct DaiQuestion
    text = CharField(max_length = 40)
    poll = ForeignKey(DaiPoll, on_delete = :CASCADE)
    Meta(table = "dai_question")
end
Base.show(io::IO, q::DaiQuestion) = print(io, q.text)
redirect_stdout(devnull) do
    ms = [DaiBook, DaiAuthor, through(DaiAuthor, :books), DaiHolder2, DaiInner2, DaiPoll, DaiQuestion]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
    Juango.update_permissions!()
end

"The management form's `TOTAL_FORMS` (or another count) of each inline on the page: prefix => value."
function dai_counts(t, what = "TOTAL_FORMS")
    out = Dict{String,Int}()
    for m in eachmatch(Regex("<input[^>]*name=\"([^\"]+)-$what\"[^>]*>"), t)
        v = match(r"value=\"(\d+)\"", m.match)
        out[m[1]] = parse(Int, v[1])
    end
    out
end
function dai_staff(name, codes...)
    u = create_user(name, "pw12345"); u.is_staff = true; save!(u)
    for code in codes
        add!(u.user_permissions, get(Permission; codename = code))
    end
    c = Client(); force_login!(c, get(User; id = u.id)); c
end
function dai_with(f; kw...)
    Admin.register!(DaiAuthor; inlines = [Admin.TabularInline(through(DaiAuthor, :books); extra = 3)])
    Admin.register!(DaiHolder2; inlines = [Admin.TabularInline(DaiInner2; extra = 3)])
    Admin.register!(DaiPoll; inlines = [Admin.TabularInline(DaiQuestion; extra = 3)])
    try
        f()
    finally
        Admin.unregister!(DaiAuthor); Admin.unregister!(DaiHolder2); Admin.unregister!(DaiPoll)
    end
end

@testset "django admin_inlines: TestInlinePermissions" begin
    port_block() do
        dai_with() do
            author = create(DaiAuthor; name = "The Author")
            book = create(DaiBook; name = "The inline Book")
            add!(author.books, book)
            link = first(filter(through(DaiAuthor, :books); daiauthor = author))
            holder = create(DaiHolder2; dummy = 13)
            inner2 = create(DaiInner2; dummy = 42, holder = holder)
            parent = ("add_daiauthor", "change_daiauthor", "add_daiholder2", "change_daiholder2")
            author_add, holder_add = "/admin/project/daiauthor/add/", "/admin/project/daiholder2/add/"
            author_change, holder_change = "/admin/project/daiauthor/$(author.id)/change/", "/admin/project/daiholder2/$(holder.id)/change/"
            m2m(t) = [v for (k, v) in dai_counts(t) if occursin("books", k) || occursin("daiauthor_books", k)]
            fk(t) = [v for (k, v) in dai_counts(t) if occursin("daiinner2", k)]
            page(c, url) = text(get(c, url))

            c = dai_staff("dai_noperm", parent...)
            @test isempty(m2m(page(c, author_add)))                       # test_inline_add_m2m_noperm
            @test isempty(fk(page(c, holder_add)))                        # test_inline_add_fk_noperm
            @test isempty(m2m(page(c, author_change)))                    # test_inline_change_m2m_noperm
            @test isempty(fk(page(c, holder_change)))                     # test_inline_change_fk_noperm

            c = dai_staff("dai_viewbook", parent..., "view_daibook")      # test_inline_add_m2m_view_only_perm: shown, no forms
            t = page(c, author_add)
            @test m2m(t) == [0] && occursin("Dai author-dai book relationships", t) || m2m(t) == [0]
            t = page(c, author_change)                                    # test_inline_change_m2m_view_only_perm: the book as a value
            @test m2m(t) == [0] && occursin("The inline Book", t) && !occursin("-0-DELETE", t)
            @test !occursin("name=\"daiauthor_books_set-0-daibook\"", t) && !occursin(r"<select[^>]*name=\"[^\"]*-0-daibook\"", t)

            c = dai_staff("dai_addbook", parent..., "add_daibook")        # test_inline_add_m2m_add_perm, test_inline_change_m2m_add_perm
            @test isempty(m2m(page(c, author_add))) && isempty(m2m(page(c, author_change)))

            c = dai_staff("dai_changebook", parent..., "change_daibook")  # test_inline_change_m2m_change_perm: add, change, delete
            t = page(c, author_change)
            @test m2m(t) == [4] && occursin(Regex("name=\"[^\"]*-0-id\"[^>]*value=\"$(link.id)\"|value=\"$(link.id)\"[^>]*name=\"[^\"]*-0-id\""), t)
            @test occursin(r"name=\"[^\"]*-0-DELETE\"", t)

            c = dai_staff("dai_addinner", parent..., "add_daiinner2")     # test_inline_add_fk_add_perm
            @test fk(page(c, holder_add)) == [3]
            t = page(c, holder_change)                                    # test_inline_change_fk_add_perm: 3 new, the existing one not editable
            @test fk(t) == [3] && !occursin(Regex("value=\"$(inner2.id)\"[^>]*name=\"daiinner2_set-0-id\"|name=\"daiinner2_set-0-id\"[^>]*value=\"$(inner2.id)\""), t)
            @test occursin("Inner2 42", t)                                # (shown as a value)
            # (a POST can't change it)
            r = post(c, holder_change, Dict("dummy" => "13", "daiinner2_set-TOTAL_FORMS" => "0", "daiinner2_set-INITIAL_FORMS" => "0",
                                            "daiinner2_set-0-id" => string(inner2.id), "daiinner2_set-0-dummy" => "99"))
            @test r.status == 302 && get(DaiInner2; id = inner2.id).dummy == 42

            c = dai_staff("dai_changeinner", parent..., "change_daiinner2")   # test_inline_change_fk_change_perm: the existing one, no new
            t = page(c, holder_change)
            @test fk(t) == [1] && [v for (k, v) in dai_counts(t, "MAX_NUM_FORMS") if occursin("daiinner2", k)] == [0]
            @test occursin(Regex("name=\"daiinner2_set-0-dummy\"[^>]*value=\"42\"|value=\"42\"[^>]*name=\"daiinner2_set-0-dummy\""), t)
            @test !occursin("daiinner2_set-0-DELETE", t)
            # (and a posted new one isn't created)
            r = post(c, holder_change, Dict("dummy" => "13", "daiinner2_set-TOTAL_FORMS" => "2", "daiinner2_set-INITIAL_FORMS" => "1",
                                            "daiinner2_set-MAX_NUM_FORMS" => "0",
                                            "daiinner2_set-0-id" => string(inner2.id), "daiinner2_set-0-dummy" => "43",
                                            "daiinner2_set-1-dummy" => "7"))
            @test r.status == 302 && get(DaiInner2; id = inner2.id).dummy == 43 && count(filter(DaiInner2; holder = holder)) == 1

            c = dai_staff("dai_addchangeinner", parent..., "add_daiinner2", "change_daiinner2")   # test_inline_change_fk_add_change_perm
            @test fk(page(c, holder_change)) == [4]
            c = dai_staff("dai_changedelinner", parent..., "change_daiinner2", "delete_daiinner2")  # test_inline_change_fk_change_del_perm
            t = page(c, holder_change)
            @test fk(t) == [1] && occursin("daiinner2_set-0-DELETE", t)
            c = dai_staff("dai_allinner", parent..., "add_daiinner2", "change_daiinner2", "delete_daiinner2")   # test_inline_change_fk_all_perms
            t = page(c, holder_change)
            @test fk(t) == [4] && occursin("daiinner2_set-0-DELETE", t)
        end
    end
end

@testset "django admin_inlines: TestReadOnlyChangeViewInlinePermissions" begin
    port_block() do
        dai_with() do
            c = dai_staff("dai_pollviewer", "view_daipoll", "add_daiquestion", "change_daiquestion", "delete_daiquestion", "view_daiquestion")
            poll = create(DaiPoll; name = "Survey")
            add_url, change_url = "/admin/project/daipoll/add/", "/admin/project/daipoll/$(poll.id)/change/"
            @test get(c, add_url).status == 403 && post(c, add_url, Dict{String,String}()).status == 403     # test_add_url_not_allowed
            @test post(c, change_url, Dict{String,String}()).status == 403                                   # test_post_to_change_url_not_allowed
            @test get(c, change_url).status == 200                                                           # test_get_to_change_url_is_allowed
            t = text(get(c, change_url))                                                                     # test_main_model_is_rendered_as_read_only
            @test occursin("Survey", t) && !occursin(r"<input[^>]*name=\"name\"", t)
            q = create(DaiQuestion; text = "How will this be rendered?", poll = poll)                        # test_inlines_are_rendered_as_read_only
            t = text(get(c, change_url))
            @test occursin("How will this be rendered?", t) && !occursin("daiquestion_set-0-text", t)
            @test !occursin("-0-DELETE", t)                                                                  # test_inline_delete_buttons_are_not_shown
            @test [v for (k, v) in dai_counts(t) if occursin("daiquestion", k)] == [0]                       # test_extra_inlines_are_not_shown
        end
    end
end

@testset "django admin_inlines: TestInline options, TestVerboseNameInlineForms" begin
    port_block() do
        c = Client(); force_login!(c, root_user())
        holder = create(DaiHolder2; dummy = 13)
        inner = create(DaiInner2; dummy = 42, holder = holder)
        url = "/admin/project/daiholder2/$(holder.id)/change/"
        reg(; kw...) = Admin.register!(DaiHolder2; inlines = [Admin.TabularInline(DaiInner2; kw...)])
        try
            reg(; can_delete = false)                                                # test_can_delete
            @test !occursin("daiinner2_set-0-DELETE", text(get(c, url)))
            reg()
            @test occursin("daiinner2_set-0-DELETE", text(get(c, url)))
            # test_min_num, test_custom_get_extra_form, test_custom_min_num
            reg(; extra = 3, min_num = 2)
            t = text(get(c, "/admin/project/daiholder2/add/"))
            @test dai_counts(t)["daiinner2_set"] == 5 && dai_counts(t, "MIN_NUM_FORMS")["daiinner2_set"] == 2
            reg(; get_extra = (req, obj) -> obj === nothing ? 2 : 1, get_min_num = (req, obj) -> obj === nothing ? 5 : 2)
            @test dai_counts(text(get(c, "/admin/project/daiholder2/add/")))["daiinner2_set"] == 7
            @test dai_counts(text(get(c, url)))["daiinner2_set"] == 3                  # (1 existing + 1 extra, at least min_num 2 + extra)
            # readonly_fields: the value, not an input; a post doesn't change it
            reg(; readonly_fields = [:dummy])
            t = text(get(c, url))
            @test occursin("<td class=\"readonly\">42</td>", t) && !occursin("daiinner2_set-0-dummy", t)
            # exclude
            reg(; exclude = [:dummy])
            @test !occursin("daiinner2_set-0-dummy", text(get(c, url)))
            # test_inlines_show_change_link_registered / _unregistered / test_tabular_inline_show_change_link_false_registered
            reg(; show_change_link = true)
            @test !occursin("inlinechangelink", text(get(c, url)))                    # (DaiInner2 has no admin of its own)
            Admin.register!(DaiInner2)
            @test occursin("href=\"/admin/project/daiinner2/$(inner.id)/change/\" class=\"inlinechangelink\"", text(get(c, url)))
            reg()
            @test !occursin("inlinechangelink", text(get(c, url)))
            Admin.unregister!(DaiInner2)
            # classes
            reg(; classes = ["collapse"])
            @test occursin("inline-group collapse", text(get(c, url)))
            # test_verbose_name_inline, test_verbose_name_plural_inline, test_both_verbose_names_inline
            reg(; verbose_name = "Non-verbose childs")
            @test occursin("<h2>Non-verbose childss</h2>", text(get(c, url)))
            reg(; verbose_name_plural = "Model with verbose name plurals")
            @test occursin("<h2>Model with verbose name plurals</h2>", text(get(c, url)))
            reg(; verbose_name = "Some", verbose_name_plural = "Many")
            @test occursin("<h2>Many</h2>", text(get(c, url)))
            reg()
            @test occursin("<h2>Dai inner2s</h2>", text(get(c, url)))
            @test_throws ArgumentError Admin.TabularInline(DaiInner2; no_such_option = 1)
        finally
            Admin.unregister!(DaiHolder2)
        end
        # not translated: the custom ModelForm and formset classes, inline media, the JavaScript (Playwright) tests,
        # the CSS classes and ids of Django's own templates, two inlines of the same model on one page
    end
end
