# Django's generic_inline_admin tests, ported (#227): tests/generic_inline_admin. Juango's generic inlines are
# `Admin.GenericTabularInline(Model; ct_field, ct_fk_field, options...)` (and GenericStackedInline), built on
# `generic_inlineformset_factory`.
# julia --project=test test/django_generic_inline_admin.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DgiEpisode
    name = CharField(max_length = 100)
    length = CharField(max_length = 100, blank = true)
    author = CharField(max_length = 100, blank = true)
    Meta(table = "dgi_episode")
end
@model struct DgiMedia
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    url = URLField()
    description = CharField(max_length = 100, blank = true)
    keywords = CharField(max_length = 100, blank = true)
    Meta(table = "dgi_media")
end
Base.show(io::IO, m::DgiMedia) = print(io, m.url)
@model struct DgiCategory
    name = CharField(max_length = 50)
    Meta(table = "dgi_category")
end
@model struct DgiPhoneNumber
    content_type = ForeignKey(ContentType; on_delete = :CASCADE)
    object_id = PositiveIntegerField()
    content_object = GenericForeignKey()
    phone_number = CharField(max_length = 30)
    category = ForeignKey(DgiCategory; on_delete = :SET_NULL, null = true, blank = true)
    Meta(table = "dgi_phonenumber", unique_together = [(:content_type, :object_id, :phone_number)])
end
@model struct DgiContact
    name = CharField(max_length = 50)
    Meta(table = "dgi_contact")
end
redirect_stdout(devnull) do
    ms = [DgiEpisode, DgiMedia, DgiCategory, DgiPhoneNumber, DgiContact]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

"An inline's TOTAL_FORMS (or another management count) on an admin page."
function dgi_count(t, prefix, key = "TOTAL_FORMS")
    m = match(Regex("name=\"" * replace(prefix, "-" => "\\-") * "-" * key * "\"[^>]*value=\"(\\d+)\""), t)
    m === nothing && (m = match(Regex("value=\"(\\d+)\"[^>]*name=\"" * replace(prefix, "-" => "\\-") * "-" * key * "\""), t))
    m === nothing ? nothing : parse(Int, m[1])
end
const DGI_MEDIA = "project-dgimedia-content_type-object_id"

@testset "django generic_inline_admin" begin
    port_block() do
        u = create_superuser("dgi_super", "secret"); c = Client(); force_login!(c, get(User; id = u.id))
        reg(; kw...) = Admin.register!(DgiEpisode; inlines = [Admin.GenericTabularInline(DgiMedia; kw...)])
        try
            reg(; extra = 3)
            e = create(DgiEpisode; name = "This Week in Django")
            ct = get_for_model(DgiEpisode)
            mp3 = create(DgiMedia; content_type = ct, object_id = e.id, url = "http://example.com/podcast.mp3")
            png = create(DgiMedia; content_type = ct, object_id = e.id, url = "http://example.com/logo.png")
            @testset "GenericAdminViewTest" begin
                @test get(c, "/admin/project/dgiepisode/add/").status == 200                     # test_basic_add_GET
                t = text(get(c, "/admin/project/dgiepisode/$(e.id)/change/"))                    # test_basic_edit_GET
                @test occursin("http://example.com/podcast.mp3", t) && occursin("http://example.com/logo.png", t)
                @test dgi_count(t, DGI_MEDIA) == 5 && dgi_count(t, DGI_MEDIA, "INITIAL_FORMS") == 2
                r = post(c, "/admin/project/dgiepisode/add/", Dict("name" => "This Week in Django",   # test_basic_add_POST
                         "$DGI_MEDIA-TOTAL_FORMS" => "1", "$DGI_MEDIA-INITIAL_FORMS" => "0", "$DGI_MEDIA-MAX_NUM_FORMS" => "0"))
                @test r.status == 302
                r = post(c, "/admin/project/dgiepisode/$(e.id)/change/", Dict("name" => "This Week in Django",   # test_basic_edit_POST
                         "$DGI_MEDIA-TOTAL_FORMS" => "3", "$DGI_MEDIA-INITIAL_FORMS" => "2", "$DGI_MEDIA-MAX_NUM_FORMS" => "0",
                         "$DGI_MEDIA-0-id" => string(mp3.id), "$DGI_MEDIA-0-url" => "http://example.com/podcast.mp3",
                         "$DGI_MEDIA-1-id" => string(png.id), "$DGI_MEDIA-1-url" => "http://example.com/logo2.png",
                         "$DGI_MEDIA-2-id" => "", "$DGI_MEDIA-2-url" => "http://example.com/new.ogg"))
                @test r.status == 302
                @test get(DgiMedia; id = png.id).url == "http://example.com/logo2.png"
                new = get(DgiMedia; url = "http://example.com/new.ogg")
                @test new.object_id == e.id && new.content_type.id == ct.id
                # (a row deleted)
                r = post(c, "/admin/project/dgiepisode/$(e.id)/change/", Dict("name" => "This Week in Django",
                         "$DGI_MEDIA-TOTAL_FORMS" => "3", "$DGI_MEDIA-INITIAL_FORMS" => "3", "$DGI_MEDIA-MAX_NUM_FORMS" => "0",
                         "$DGI_MEDIA-0-id" => string(mp3.id), "$DGI_MEDIA-0-url" => "http://example.com/podcast.mp3",
                         "$DGI_MEDIA-1-id" => string(png.id), "$DGI_MEDIA-1-url" => "http://example.com/logo2.png",
                         "$DGI_MEDIA-2-id" => string(new.id), "$DGI_MEDIA-2-url" => "http://example.com/new.ogg", "$DGI_MEDIA-2-DELETE" => "on"))
                @test r.status == 302 && count(objects(DgiMedia)) == 2
            end
            @testset "GenericInlineAdminParametersTest" begin
                url = "/admin/project/dgiepisode/$(e.id)/change/"
                delete!(get(DgiMedia; id = png.id))                                          # (one Media, as the Django tests)
                reg(); t = text(get(c, url))                                                 # test_no_param (Juango's default extra is 1)
                @test dgi_count(t, DGI_MEDIA) == 2 && dgi_count(t, DGI_MEDIA, "INITIAL_FORMS") == 1
                reg(; extra = 3); @test dgi_count(text(get(c, url)), DGI_MEDIA) == 4
                reg(; extra = 0); @test dgi_count(text(get(c, url)), DGI_MEDIA) == 1           # test_extra_param
                reg(; extra = 5, max_num = 2); t = text(get(c, url))                         # test_max_num_param
                @test dgi_count(t, DGI_MEDIA) == 2 && dgi_count(t, DGI_MEDIA, "MAX_NUM_FORMS") == 2
                reg(; extra = 3, min_num = 2); t = text(get(c, url))                         # test_min_num_param
                @test dgi_count(t, DGI_MEDIA) == 5 && dgi_count(t, DGI_MEDIA, "MIN_NUM_FORMS") == 2
                reg(; extra = 4, get_extra = (req, obj) -> 2); @test dgi_count(text(get(c, url)), DGI_MEDIA) == 3   # test_get_extra
                reg(; min_num = 5, get_min_num = (req, obj) -> 2)                            # test_get_min_num
                @test dgi_count(text(get(c, url)), DGI_MEDIA, "MIN_NUM_FORMS") == 2
                reg(; extra = 5, get_max_num = (req, obj) -> 2)                              # test_get_max_num
                @test dgi_count(text(get(c, url)), DGI_MEDIA, "MAX_NUM_FORMS") == 2
                # (stacked)
                Admin.register!(DgiEpisode; inlines = [Admin.GenericStackedInline(DgiMedia)])
                @test occursin("http://example.com/podcast.mp3", text(get(c, url)))
            end
        finally
            Admin.is_registered(DgiEpisode) && Admin.unregister!(DgiEpisode)
        end
        # GenericInlineAdminWithUniqueTogetherTest: test_add, test_delete
        Admin.register!(DgiContact; inlines = [Admin.GenericTabularInline(DgiPhoneNumber)])
        try
            cat = create(DgiCategory; name = "male")
            p = "project-dgiphonenumber-content_type-object_id"
            @test get(c, "/admin/project/dgicontact/add/").status == 200
            r = post(c, "/admin/project/dgicontact/add/", Dict("name" => "John Doe", "$p-TOTAL_FORMS" => "1", "$p-INITIAL_FORMS" => "0",
                     "$p-MAX_NUM_FORMS" => "0", "$p-0-id" => "", "$p-0-phone_number" => "555-555-5555", "$p-0-category" => string(cat.id)))
            @test r.status == 302
            contact = get(DgiContact; name = "John Doe")
            pn = get(DgiPhoneNumber; phone_number = "555-555-5555")
            @test pn.object_id == contact.id && pn.category.id == cat.id
            # test_delete: deleting the contact page lists nothing it can't delete
            r = post(c, "/admin/project/dgicontact/$(contact.id)/delete/", Dict("post" => "yes"))
            @test r.status == 302 && count(filter(DgiContact; id = contact.id)) == 0
        finally
            Admin.unregister!(DgiContact)
        end
        # GenericInlineModelAdminTest: the formset factory itself
        e2 = create(DgiEpisode; name = "Another")
        FS = generic_inlineformset_factory(DgiMedia; fields = [:url, :description], extra = 2)
        fs = FS(; instance = e2)
        @test fs.prefix == DGI_MEDIA && length(Juango.build_forms!(fs)) == 2
        @test !any(f -> f.name in (:content_type, :object_id), Juango.empty_form(fs).fields)
        @test_throws "fk_name 'url' is not a ForeignKey to ContentType" generic_inlineformset_factory(DgiMedia; ct_field = :url)
        @test_throws "has no field named 'oid'" generic_inlineformset_factory(DgiMedia; fk_field = :oid)
        # (save_as_new: every row a new object)
        m1 = create(DgiMedia; content_type = get_for_model(DgiEpisode), object_id = e2.id, url = "http://example.com/a")
        e3 = create(DgiEpisode; name = "Copy")
        fs = FS(Dict("$DGI_MEDIA-TOTAL_FORMS" => "1", "$DGI_MEDIA-INITIAL_FORMS" => "1", "$DGI_MEDIA-0-id" => string(m1.id),
                     "$DGI_MEDIA-0-url" => "http://example.com/a"); instance = e3, save_as_new = true)
        @test is_valid(fs)
        save!(fs)
        @test count(filter(DgiMedia; url = "http://example.com/a")) == 2 && get(DgiMedia; id = m1.id).object_id == e2.id
        # admin checks: a generic inline whose content type field isn't one (GenericInlineModelAdminChecks, admin.E304)
        Admin.register!(DgiContact; inlines = [Admin.GenericTabularInline(DgiPhoneNumber; ct_field = :phone_number)])
        try
            @test any(m -> m.id == "admin.E304", Juango.run_checks())
        finally
            Admin.unregister!(DgiContact)
        end
        # not translated: GenericInlineAdminPermissionsTest's get_formsets_with_inlines, NoInlineDeletionTest (the
        # formset class attributes), the Media/DELETE widget class tests of GenericInlineModelAdminTest
    end
end
