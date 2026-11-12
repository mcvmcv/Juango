# forms: julia --project=test test/forms.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "forms" begin
    f = ContactForm()
    @test !is_valid(f)
    html = as_p(f).s
    @test occursin("<input type=\"text\" name=\"name\" id=\"id_name\" required maxlength=\"10\">", html)
    @test occursin("type=\"email\"", html) && occursin("type=\"checkbox\"", html) && occursin("type=\"password\"", html)

    f = ContactForm(Dict("name" => "  Ann ", "email" => "ann@x.io", "age" => "33", "agree" => "on",
                         "password" => "pw", "confirm" => "pw"))
    @test is_valid(f)
    @test f.cleaned_data[:name] == "Ann" && f.cleaned_data[:age] == 33 && f.cleaned_data[:agree] === true

    f = ContactForm(Dict("name" => "far too long name", "email" => "bad", "age" => "x", "password" => "a", "confirm" => "b"))
    @test !is_valid(f)
    @test Set(keys(f.errors)) == Set([:name, :email, :age, :__all__])
    @test occursin("Passwords do not match.", as_p(f).s)
    @test occursin("value=\"far too long name\"", as_p(f).s)
    @test !occursin("value=\"a\"", as_p(f).s)                          # passwords never re-rendered

    ann = ann_author()
    mf = ModelForm(Article; fields = [:title, :author, :status, :published])
    h = as_p(mf).s
    @test occursin("<select name=\"author\"", h) && occursin(">Ann</option>", h) && occursin(">Published</option>", h)
    mf = ModelForm(Article; data = Dict("title" => "From form", "author" => string(ann.id), "status" => "p", "published" => "on"),
                   fields = [:title, :author, :status, :published])
    @test is_valid(mf)
    art = save!(mf)
    @test art.id !== nothing && art.author == ann && art.published && art.status == "p"
    mf2 = ModelForm(Article; data = Dict("title" => "Edited", "author" => string(ann.id)), instance = art, fields = [:title, :author])
    @test is_valid(mf2)
    @test save!(mf2).id == art.id && get(Article; id = art.id).title == "Edited"
    mf3 = ModelForm(Article; data = Dict("title" => "X", "author" => "99999"), fields = [:title, :author])
    @test !is_valid(mf3) && haskey(mf3.errors, :author)
    uf = ModelForm(Author; data = Dict("name" => "Ann"))
    @test !is_valid(uf) && occursin("already exists", uf.errors[:name][1])
    @test occursin("value=\"Edited\"", as_p(ModelForm(Article; instance = art, fields = [:title])).s)
    @test tr("{{ f.title.label }}|{{ f.title }}", Dict("f" => ModelForm(Article; fields = [:title]))) ==
          "Title|<input type=\"text\" name=\"title\" id=\"id_title\" required maxlength=\"50\">"
end

@testset "formsets" begin
    @eval @form LineForm begin
        name = CharField(max_length = 20)
        qty = IntegerField()
    end
    LineFS = formset_factory(LineForm; extra = 2)
    fs = LineFS()
    @test length(fs) == 2 && fs[1].prefix == "form-0"
    mf = string(management_form(fs))
    @test occursin("name=\"form-TOTAL_FORMS\" value=\"2\"", mf) && occursin("name=\"form-INITIAL_FORMS\" value=\"0\"", mf)
    @test occursin("name=\"form-1-qty\"", string(as_p(fs)))
    @test length(LineFS(; initial = [Dict(:name => "a", :qty => 1)])) == 3
    @test occursin("form-__prefix__-name", string(as_p(empty_form(fs))))
    html = tr("{{ fs.management_form }}{% for f in fs %}[{{ f.prefix }}]{% endfor %}", Dict("fs" => fs))
    @test occursin("TOTAL_FORMS", html) && occursin("[form-0][form-1]", html)

    mg(total, initial = 0) = Dict("form-TOTAL_FORMS" => string(total), "form-INITIAL_FORMS" => string(initial))
    data = merge(mg(3), Dict("form-0-name" => "x", "form-0-qty" => "2", "form-1-name" => "y", "form-1-qty" => "3",
                             "form-2-name" => "", "form-2-qty" => ""))
    fs = LineFS(data)
    @test is_valid(fs) && cleaned_data(fs) == [Dict(:name => "x", :qty => 2), Dict(:name => "y", :qty => 3)]   # blank extra skipped
    bad = LineFS(merge(data, Dict("form-1-qty" => "abc")))
    @test !is_valid(bad) && haskey(Juango.errors(bad)[2], :qty)
    tampered = LineFS(Dict("form-0-name" => "x"))
    @test !is_valid(tampered) && occursin("ManagementForm", only(tampered.non_form_errors))

    strict = formset_factory(LineForm; extra = 0, min_num = 2, validate_min = true, max_num = 2, validate_max = true)
    @test !is_valid(strict(merge(mg(1), Dict("form-0-name" => "a", "form-0-qty" => "1"))))
    three = merge(mg(3), Dict("form-$i-name" => "n$i" for i in 0:2), Dict("form-$i-qty" => "1" for i in 0:2))
    f3 = strict(three)
    @test !is_valid(f3) && occursin("at most 2", only(f3.non_form_errors))

    DelFS = formset_factory(LineForm; extra = 0, can_delete = true, can_order = true)
    d = merge(mg(3, 3), Dict("form-0-name" => "a", "form-0-qty" => "1", "form-0-ORDER" => "3",
                             "form-1-name" => "b", "form-1-qty" => "1", "form-1-DELETE" => "on", "form-1-ORDER" => "1",
                             "form-2-name" => "c", "form-2-qty" => "1", "form-2-ORDER" => "2"))
    fd = DelFS(d)
    @test is_valid(fd) && [x[:name] for x in cleaned_data(fd)] == ["c", "a"] && length(deleted_forms(fd)) == 1
    nodup(fs) = length(unique(x[:name] for x in cleaned_data(fs))) == length(cleaned_data(fs)) || Juango.add_error!(fs, "Names must differ.")
    DupFS = formset_factory(LineForm; extra = 0, clean = nodup)
    fdup = DupFS(merge(mg(2), Dict("form-0-name" => "a", "form-0-qty" => "1", "form-1-name" => "a", "form-1-qty" => "2")))
    @test !is_valid(fdup) && fdup.non_form_errors == ["Names must differ."]

    # model formsets
    a1, a2 = create(Author; name = "FS One"), create(Author; name = "FS Two")
    outsider = create(Author; name = "FS Outsider")
    AuthorFS = modelformset_factory(Author; fields = [:name], extra = 1, can_delete = true)
    qs = order_by(filter(Author; name__in = ["FS One", "FS Two"]), "name")
    fs = AuthorFS(; queryset = qs)
    @test length(fs) == 3 && occursin("name=\"form-0-id\" id=\"id_form-0-id\"", string(as_p(fs)))
    post_ = merge(mg(3, 2), Dict("form-0-id" => string(a1.id), "form-0-name" => "FS One renamed",
                                 "form-1-id" => string(a2.id), "form-1-name" => "FS Two", "form-1-DELETE" => "on",
                                 "form-2-id" => "", "form-2-name" => "FS Three"))
    fs = AuthorFS(post_; queryset = qs)
    @test is_valid(fs)
    saved = save!(fs)
    @test length(saved) == 2 && length(fs.new_objects) == 1 && length(fs.changed_objects) == 1 && length(fs.deleted_objects) == 1
    @test get(Author; id = a1.id).name == "FS One renamed" && !exists(filter(Author; id = a2.id)) && exists(filter(Author; name = "FS Three"))
    # an id outside the queryset never touches that object
    sneaky = AuthorFS(merge(mg(1, 1), Dict("form-0-id" => string(outsider.id), "form-0-name" => "hacked"));
                      queryset = filter(Author; name = "FS One renamed"))
    is_valid(sneaky) && save!(sneaky)
    @test get(Author; id = outsider.id).name == "FS Outsider"

    # inline formsets
    ArtFS = inlineformset_factory(Author, Article; fields = [:title], extra = 2)
    create(Article; title = "existing", author = a1)
    fs = ArtFS(; instance = a1)
    @test length(fs) == 3 && fs.prefix == "articles"
    @test !occursin("articles-0-author", string(as_p(fs)))
    existing = only(filter(Article; author = a1))
    p2 = Dict("articles-TOTAL_FORMS" => "3", "articles-INITIAL_FORMS" => "1",
              "articles-0-id" => string(existing.id), "articles-0-title" => "existing (edited)",
              "articles-1-title" => "brand new", "articles-2-title" => "")
    fs = ArtFS(p2; instance = a1)
    @test is_valid(fs)
    save!(fs)
    @test sort([x.title for x in filter(Article; author = a1)]) == ["brand new", "existing (edited)"]
    @test_throws ArgumentError inlineformset_factory(Topic, Article)
end

@testset "file uploads and storage" begin
    media = mktempdir()
    old_media = settings.MEDIA_ROOT
    configure!(MEDIA_ROOT = media)
    png = vcat(UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13], Vector{UInt8}("IHDR"),
               UInt8[0, 0, 0, 3, 0, 0, 0, 2, 8, 6, 0, 0, 0], zeros(UInt8, 8))
    try
        # image sizes without an image library
        @test image_size(png) == (3, 2)
        @test image_size(vcat(Vector{UInt8}("GIF89a"), UInt8[5, 0, 7, 0], zeros(UInt8, 4))) == (5, 7)
        @test image_size(UInt8[0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0, 0, 0xff, 0xc0, 0x00, 0x11, 0x08, 0x00, 0x09, 0x00, 0x0a, 0, 0, 0]) == (10, 9)
        @test image_size(vcat(Vector{UInt8}("RIFF"), zeros(UInt8, 4), Vector{UInt8}("WEBPVP8X"), zeros(UInt8, 8), UInt8[3, 0, 0, 1, 0, 0], zeros(UInt8, 4))) == (4, 2)
        @test image_size(Vector{UInt8}("not an image")) === nothing

        # storage: safe names, no escaping the root, no overwriting
        @test Juango.get_valid_name("../../etc/passwd") == "passwd" && Juango.get_valid_name(" my file (1).txt") == "my_file_1.txt"
        st = FileSystemStorage()
        n1 = save_file(st, "a/b/report.txt", Vector{UInt8}("one"))
        n2 = save_file(st, "a/b/report.txt", Vector{UInt8}("two"))
        @test n1 == "a/b/report.txt" && n2 != n1 && startswith(n2, "a/b/report_") && endswith(n2, ".txt")
        @test read(st, n1) == Vector{UInt8}("one") && Juango.exists(st, n2) && size(st, n2) == 3
        @test Juango.url(st, n1) == "/media/a/b/report.txt"
        @test save_file(st, "../../outside.txt", UInt8[1]) == "outside.txt" && isfile(joinpath(media, "outside.txt"))
        @test_throws ArgumentError Juango.path(st, "../secret")
        delete_file(st, n2)
        @test !Juango.exists(st, n2)

        # model fields
        a = create(Attachment; title = "notes", file = UploadedFile("my notes.txt", "hello"), photo = UploadedFile("p.png", png))
        @test a.file isa FieldFile && startswith(a.file.name, "docs/$(year(now()))/my_notes") && String(read(a.file)) == "hello"
        @test a.photo_w == 3 && a.photo_h == 2 && a.photo.width == 3 && a.file.size == 5
        r = get(Attachment; id = a.id)
        @test r.file.name == a.file.name && r.file.url == "/media/" * a.file.name && r.photo.height == 2
        @test tr("{{ a.file.url }} {{ a.photo.width }}", Dict("a" => r)) == "/media/$(a.file.name) 3"
        nophoto = create(Attachment; title = "bare", file = UploadedFile("x.txt", "x"))
        @test get(Attachment; id = nophoto.id).photo === nothing

        # forms
        f = ModelForm(Attachment; data = Dict("title" => "via form"), files = Dict("file" => UploadedFile("doc.pdf", "%PDF")))
        @test is_valid(f) && Juango.has_changed(f)
        saved = save!(f)
        @test endswith(saved.file.name, "doc.pdf") && String(read(saved.file)) == "%PDF"
        bad = ModelForm(Attachment; data = Dict("title" => "x"), files = Dict("file" => UploadedFile("evil.exe", "MZ"), "photo" => UploadedFile("fake.png", "text")))
        @test !is_valid(bad) && occursin("not allowed", only(bad.errors[:file])) && occursin("valid image", only(bad.errors[:photo]))
        @test !is_valid(ModelForm(Attachment; data = Dict("title" => "no file")))          # required
        keep = ModelForm(Attachment; data = Dict("title" => "renamed"), instance = get(Attachment; id = a.id))
        @test is_valid(keep) && save!(keep).file.name == a.file.name                      # no upload: file kept
        clear = ModelForm(Attachment; data = Dict("title" => "renamed", "photo-clear" => "on"), instance = get(Attachment; id = a.id))
        @test is_valid(clear) && save!(clear).photo === nothing
        html = string(as_p(ModelForm(Attachment; instance = get(Attachment; id = nophoto.id))))
        @test occursin("type=\"file\" name=\"file\"", html) && occursin("Currently: <a href=\"/media/", html) && occursin("accept=\"image/*\"", html)

        # multipart requests, the admin, and media served in development
        body, ctype = Juango.multipart_body(Dict("title" => "t", "file" => UploadedFile("up.txt", "uploaded"; content_type = "text/plain")))
        req = Request("POST", "/x"; headers = Dict("content-type" => ctype), body = body)
        @test req.POST["title"] == "t" && req.FILES["file"].name == "up.txt" && String(read(req.FILES["file"])) == "uploaded"
        @test req.FILES["file"].content_type == "text/plain" && isempty(Request("GET", "/").FILES)
        c = Client()
        force_login!(c, root_user())
        Admin.register!(Attachment; list_display = [:title, :file])
        @test occursin("enctype=\"multipart/form-data\"", text(get(c, "/admin/attachment/add/")))
        r = post(c, "/admin/attachment/add/", Dict("title" => "from admin", "file" => UploadedFile("admin.txt", "via admin")))
        @test r.status == 302
        fa = get(Attachment; title = "from admin")
        @test String(read(fa.file)) == "via admin" && isfile(fa.file.path)
        r = get(c, fa.file.url)
        @test r.status == 200 && text(r) == "via admin" && startswith(getheader(r, "Content-Type"), "text/plain")
        @test get(c, "/media/../runtests.jl").status == 404 && get(c, "/media/nope.txt").status == 404
        Admin.unregister!(Attachment)

        # STORAGES and InMemoryStorage
        override_settings(STORAGES = Dict("default" => Dict(:BACKEND => :memory),
                                          "other" => Dict(:BACKEND => FileSystemStorage, :OPTIONS => Dict(:location => media, :base_url => "/o/")),
                                          "staticfiles" => Dict(:BACKEND => :manifest))) do
            ms = storages()
            @test ms isa InMemoryStorage && storages("default") === ms && Juango.default_storage() === ms
            m = create(Attachment; title = "in memory", file = UploadedFile("mem.txt", "kept in RAM"))
            @test String(read(get(Attachment; id = m.id).file)) == "kept in RAM" && !isfile(joinpath(media, m.file.name))
            @test m.file.url == "/media/" * m.file.name && Juango.exists(ms, m.file.name)
            @test Juango.listdir(ms, "docs") == ([string(year(now()))], String[])
            @test Juango.listdir(ms, "docs/$(year(now()))")[2] == [basename(m.file.name)]
            @test_throws ArgumentError m.file.path
            delete_file(ms, m.file.name)
            @test !Juango.exists(ms, m.file.name)
            o = storages("other")
            @test o isa FileSystemStorage && Juango.url(o, "x.txt") == "/o/x.txt"
            @test Juango.manifest_storage()
            @test_throws Juango.ImproperlyConfigured storages("nope")
        end
        @test !(storages() isa InMemoryStorage) && !Juango.manifest_storage()
        @test "outside.txt" in Juango.listdir(FileSystemStorage(), "")[2]
    finally
        configure!(MEDIA_ROOT = old_media)
    end
end

@form MediaForm begin
    name = CharField(max_length = 20, widget = Widget(:text; attrs = Dict("class" => "wide", "placeholder" => "Name"),
                                                         media = Media(js = ["js/name.js"])))
    when = SplitDateTimeField()
    code = MultiValueField([CharField(max_length = 3), IntegerField()]; compress = vs -> "$(vs[1])-$(vs[2])",
                           decompress = v -> v === nothing ? [nothing, nothing] : split(v, '-'), blank = true)
end

@testset "form media, multi-value fields, template renderers" begin
    f = MediaForm(; media = Media(css = Dict("all" => ["css/forms.css", "/abs/x.css"]), js = ["js/name.js", "https://cdn.example/x.js"]))
    @test string(tr("{{ form.media }}", Dict("form" => f))) ==
          "<link href=\"/static/css/forms.css\" media=\"all\" rel=\"stylesheet\">\n<link href=\"/abs/x.css\" media=\"all\" rel=\"stylesheet\">\n" *
          "<script src=\"/static/js/name.js\"></script>\n<script src=\"https://cdn.example/x.js\"></script>"
    @test (Media(js = ["a.js"]) + Media(js = ["b.js", "a.js"])).js == ["a.js", "b.js"]
    html = string(as_p(f))
    @test occursin("class=\"wide\"", html) && occursin("placeholder=\"Name\"", html)
    @test occursin("<input type=\"date\" name=\"when_0\"", html) && occursin("<input type=\"time\" name=\"when_1\"", html)

    # multi-value fields clean their parts, then compress them
    f = MediaForm(Dict("name" => "Ann", "when_0" => "2024-05-01", "when_1" => "13:45", "code_0" => "abc", "code_1" => "7"))
    @test is_valid(f) && f.cleaned_data[:when] == (settings.USE_TZ ? make_aware(DateTime(2024, 5, 1, 13, 45)) : DateTime(2024, 5, 1, 13, 45))
    @test f.cleaned_data[:code] == "abc-7"
    f = MediaForm(Dict("name" => "Ann", "when_0" => "2024-05-01", "when_1" => "25:99"))
    @test !is_valid(f) && f.errors[:when] == ["Enter a valid time."] && f.cleaned_data[:code] === nothing
    f = MediaForm(Dict("name" => "Ann", "when_0" => "", "when_1" => ""))
    @test !is_valid(f) && f.errors[:when] == ["This field is required."]
    f = MediaForm(Dict("name" => "Ann", "when_0" => "2024-05-01", "when_1" => "10:00", "code_0" => "abc", "code_1" => "x"))
    @test !is_valid(f) && f.errors[:code] == ["Enter a whole number."]
    f = MediaForm(Dict("name" => "Ann", "when_0" => "2024-05-01", "when_1" => ""))
    @test !is_valid(f) && f.errors[:when] == ["Enter a complete value."]
    # an unbound form shows the initial value split into parts
    f = MediaForm(; initial = Dict(:when => DateTime(2024, 1, 2, 3, 4), :code => "xy-9"))
    html = string(as_p(f))
    @test occursin("name=\"when_0\" id=\"id_when_0\" required value=\"2024-01-02\"", html) && occursin("value=\"03:04\"", html)
    @test occursin("name=\"code_1\" id=\"id_code_1\" value=\"9\"", html)

    # template renderers
    f = ContactForm(Dict("name" => "", "email" => "bad"))
    is_valid(f)
    override_settings(FORM_RENDERER = TemplateFormRenderer()) do
        out = string(tr("{{ form }}", Dict("form" => f)))
        @test occursin("<div><ul class=\"errorlist\"><li>This field is required.</li></ul><label for=\"id_name\">", out)
        @test count("<div>", out) == length(f.fields)
    end
    out = string(render_form(f; template = "juango/forms/p.html"))
    @test occursin("<p><label for=\"id_name\">", out) && occursin("<ul class=\"errorlist\">", out)
    @test string(tr("{{ form }}", Dict("form" => f))) == string(as_p(f))      # the default stays as_p
end
