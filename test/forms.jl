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
    @test Set(keys(f.errors)) == Set([:name, :email, :age, :agree, :__all__])      # (agree must be checked, #247)
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
    # (the parent's key is in a hidden input, as Django's InlineForeignKeyField)
    @test occursin(Regex("<input type=\"hidden\" name=\"articles-0-author\"[^>]* value=\"$(a1.id)\""), string(as_p(fs)))
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
        # #175: several files in one field
        mf(files; fld = MultipleFileField(max_files = 2)) = Form([:docs => fld]; data = Dict{String,Any}(), files = Dict("docs" => files))
        m = mf([UploadedFile("a.txt", "A"), UploadedFile("b.txt", "B")])
        @test is_valid(m) && [u.name for u in m.cleaned_data[:docs]] == ["a.txt", "b.txt"]
        m = mf(UploadedFile[])
        @test !is_valid(m) && m.errors[:docs] == ["This field is required."]                 # nothing chosen: missing
        m = mf([UploadedFile("a.txt", "A"), UploadedFile("b.txt", "B"), UploadedFile("c.txt", "C")])
        @test !is_valid(m) && occursin("at most 2 files", only(m.errors[:docs]))
        m = mf([UploadedFile("a.txt", ""), UploadedFile("b.txt", "B")])
        @test !is_valid(m) && only(m.errors[:docs]) == "a.txt: The submitted file is empty."
        @test is_valid(mf(UploadedFile[]; fld = MultipleFileField(blank = true)))
        @test is_valid(Form([:docs => MultipleFileField()]; data = Dict{String,Any}(), files = Juango.FileDict(Dict("docs" => [UploadedFile("x.txt", "X")]))))
        m = mf([UploadedFile("fake.png", "text")]; fld = MultipleFileField(images = true))
        @test !is_valid(m) && startswith(only(m.errors[:docs]), "fake.png: Upload a valid image")
        blank_form = Form([:docs => MultipleFileField()])
        @test occursin(" multiple", as_p(blank_form).s) && occursin("type=\"file\"", as_p(blank_form).s) && Juango.tattr(blank_form, Val(:is_multipart))
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
        @test occursin("enctype=\"multipart/form-data\"", text(get(c, "/admin/project/attachment/add/")))
        r = post(c, "/admin/project/attachment/add/", Dict("title" => "from admin", "file" => UploadedFile("admin.txt", "via admin")))
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
    # (a SplitDateTimeField's missing part names it, as Django's: its parts' "incomplete" messages)
    f = MediaForm(Dict("name" => "Ann", "when_0" => "2024-05-01", "when_1" => ""))
    @test !is_valid(f) && f.errors[:when] == ["Enter a valid time."]
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
        # (as Django's div.html: the label, help text, errors, then the input)
        @test occursin("<div><label for=\"id_name\">Name:</label><ul class=\"errorlist\" id=\"id_name_error\"><li>This field is required.</li></ul>", out)
        @test count("<div>", out) == length(f.fields)
    end
    out = string(render_form(f; template = "juango/forms/p.html"))
    @test occursin("<p><label for=\"id_name\">", out) && occursin("<ul class=\"errorlist\" id=\"id_name_error\">", out)
    @test string(tr("{{ form }}", Dict("form" => f))) == string(as_div(f))    # the default is as_div, as Django 5's (#248)
end

@testset "ModelChoiceField, typed, regex and combo fields, as_field_group, formfield_callback" begin
    a1, a2 = create(Author; name = "MC Ann"), create(Author; name = "MC Bob")
    other = create(Author; name = "Elsewhere")
    write(joinpath(TPL, "custom_field.html"), "<div class=\"custom\">{{ field.label }}: {{ field }}</div>")
    PickForm(data = nothing) = Form(Pair{Symbol,Any}[
        :author => ModelChoiceField(filter(Author; name__startswith = "MC ")),
        :byname => ModelChoiceField(Author; to_field_name = :name, required = false),
        :many => ModelMultipleChoiceField(filter(Author; name__startswith = "MC "); label_from_instance = a -> uppercase(a.name)),
        :n => TypedChoiceField(["1" => "One", "2" => "Two"]; coerce = x -> parse(Int, x)),
        :tags => MultipleChoiceField(["a" => "A", "b" => "B"]),
        :code => RegexField(r"^[A-Z]{3}$"; error_message = "Three capitals.", template_name = "custom_field.html"),
        :both => ComboField([CharField(max_length = 12), EmailField()])]; data = data)
    good = Dict("author" => string(a1.id), "byname" => "MC Bob", "many" => [string(a1.id), string(a2.id)], "n" => "2",
                "tags" => ["a", "b"], "code" => "ABC", "both" => "x@y.io")
    f = PickForm(good)
    @test is_valid(f)
    cd = cleaned_data(f)
    @test cd[:author] == a1 && cd[:byname] == a2 && cd[:many] == [a1, a2] && cd[:n] === 2 && cd[:tags] == ["a", "b"]
    @test cd[:code] == "ABC" && cd[:both] == "x@y.io"
    bad = PickForm(merge(good, Dict("author" => string(other.id), "many" => [string(other.id)], "n" => "3", "tags" => ["z"],
                                    "code" => "abc", "both" => "a.very.long.name@example.com")))
    @test !is_valid(bad)
    @test bad.errors[:author] == ["Select a valid choice. That choice is not one of the available choices."]
    @test haskey(bad.errors, :many) && haskey(bad.errors, :n) && haskey(bad.errors, :tags)
    @test bad.errors[:code] == ["Three capitals."] && length(bad.errors[:both]) == 1
    @test !is_valid(PickForm(merge(good, Dict("many" => String[]))))                     # required
    blank = PickForm()
    many_html = Juango.widget_html(blank[:many])
    @test occursin("multiple", many_html) && occursin(">MC ANN<", many_html) && !occursin("Elsewhere", many_html)
    @test occursin("<option value=\"\" selected>---------</option>", Juango.widget_html(blank[:author]))
    @test occursin("value=\"MC Bob\"", Juango.widget_html(blank[:byname]))
    t(s, ctx) = render(Template(s), ctx)
    @test occursin("<div class=\"custom\">Code: <input", t("{{ form.code.as_field_group }}", Dict("form" => blank)))
    g = t("{{ form.n.as_field_group }}", Dict("form" => blank))
    @test occursin("<label for=\"id_n\">", g) && occursin("<select", g) && occursin("Two", g)
    @test occursin("<div>", string(as_div(blank)))

    # ModelForm: other form fields, and a callback for each
    mf = ModelForm(Article; fields = [:title, :body], field_classes = Dict(:title => CharField(max_length = 5)),
                   data = Dict("title" => "too long", "body" => "b"))
    @test !is_valid(mf) && haskey(mf.errors, :title)
    cb = ModelForm(Article; fields = [:title, :body, :status],
                   formfield_callback = f -> f.name === :body ? nothing : (f.help_text = "from the callback"; f))
    @test [x.name for x in cb.fields] == [:title, :status] && all(x -> x.help_text == "from the callback", cb.fields)
end

@testset "validators and error_messages (#144)" begin
    # the validators, on their own
    @test RegexValidator(r"^[A-Z]{2}\d+$")("AB12") === nothing && RegexValidator(r"^[A-Z]{2}\d+$")("ab") == "Enter a valid value."
    @test RegexValidator("x"; inverse_match = true, message = "no x")("axb") == "no x"
    @test validate_email("a.b+c@example.org") === nothing && validate_email("a@b") !== nothing && validate_email("x@localhost") === nothing
    @test validate_email("a..b@example.org") !== nothing && validate_email("no at sign") !== nothing
    @test URLValidator()("https://example.com:8000/p?q=1#f") === nothing && URLValidator()("http://localhost/") === nothing
    @test URLValidator()("ftp://10.0.0.1/x") === nothing && URLValidator()("javascript:alert(1)") !== nothing
    @test URLValidator(schemes = ["https"])("http://example.com") !== nothing && URLValidator()("http://exa mple.com") !== nothing
    @test MinValueValidator(1)(0) == "Ensure this value is greater than or equal to 1." && MinValueValidator(1)(1) === nothing
    @test MaxValueValidator(10)(11) !== nothing && MinLengthValidator(3)("ab") == "Ensure this value has at least 3 characters (it has 2)."
    @test MaxLengthValidator(2)("abc") == "Ensure this value has at most 2 characters (it has 3)."
    @test StepValueValidator(5)(10) === nothing && StepValueValidator(5)(7) == "Ensure this value is a multiple of step size 5."
    @test StepValueValidator(0.1)(0.3) === nothing && StepValueValidator(3; offset = 1)(4) === nothing && StepValueValidator(3; offset = 1)(5) !== nothing
    @test Juango.validation_error(DecimalValidator(5, 2), Juango.Decimal("1234.5"))[1] == "max_whole_digits"
    @test Juango.validation_error(DecimalValidator(5, 2), Juango.Decimal("1.234"))[1] == "max_decimal_places"
    @test ProhibitNullCharactersValidator()("a\0b") == "Null characters are not allowed."
    @test validate_slug("ok-slug_1") === nothing && validate_slug("not ok") !== nothing && validate_unicode_slug("café") === nothing
    @test validate_ipv4_address("10.1.2.3") === nothing && validate_ipv4_address("::1") !== nothing && validate_ipv46_address("::1") === nothing
    @test validate_comma_separated_integer_list("1,22,3") === nothing && validate_comma_separated_integer_list("1,-2") !== nothing
    @test int_list_validator(sep = ";", allow_negative = true)("1;-2") === nothing

    # on form fields: limits as options, messages by code
    F(data) = (f = Form([:qty => IntegerField(min_value = 1, max_value = 10, step_size = 3,
                                              error_messages = Dict("min_value" => "At least %(limit_value)s, please.", "invalid" => "Digits only.")),
                         :code => CharField(max_length = 5, min_length = 2, validators = [RegexValidator(r"^[A-Z]+$"; code = "letters")],
                                            error_messages = Dict("required" => "A code!", "letters" => "Capitals only.", "max_length" => "≤ %(limit_value)s")),
                         :tag => CharField(blank = true, validators = [v -> v == "bad" ? throw(ValidationError("nope"; code = "badtag")) : nothing],
                                           error_messages = Dict("badtag" => "Not that tag."))];
                        data = data); is_valid(f); f)
    f = F(Dict("qty" => "-2", "code" => "", "tag" => "bad"))          # (-2 is on a step from 1: only too small)
    @test f.errors[:qty] == ["At least 1, please."] && f.errors[:code] == ["A code!"] && f.errors[:tag] == ["Not that tag."]
    f = F(Dict("qty" => "x", "code" => "abcdef"))
    @test f.errors[:qty] == ["Digits only."] && f.errors[:code] == ["≤ 5", "Capitals only."]
    f = F(Dict("qty" => "5", "code" => "A"))
    @test f.errors[:qty] == ["Ensure this value is a multiple of step size 3, starting from 1, e.g. 1, 4, 7, and so on."]
    @test f.errors[:code] == ["Ensure this value has at least 2 characters (it has 1)."]
    @test is_valid(F(Dict("qty" => "7", "code" => "AB")))

    # ValidationError with params; model field error_messages and ModelForm's override
    @test only(ValidationError("Too many: %(n)s"; params = Dict("n" => 3)).errors[:__all__]) == "Too many: 3"
    mf = ModelForm(Author; data = Dict("name" => "", "email" => "not-an-email"),
                   error_messages = Dict(:name => Dict("required" => "Who wrote it?"), :email => Dict("invalid" => "That's no address.")))
    @test !is_valid(mf) && mf.errors[:name] == ["Who wrote it?"] && mf.errors[:email] == ["That's no address."]
    fld = CharField(max_length = 3, error_messages = Dict(:max_length => "Short, please"))
    @test Juango.validate_field(fld, "abcd") == ["Short, please"]
end

@testset "forms: localised input, SelectDateWidget, NullBooleanField, structured errors (#145)" begin
    D(data; kw...) = (f = Form([:d => DateField(; kw...)]; data = data); is_valid(f) ? f.cleaned_data[:d] : f.errors[:d])
    @test D(Dict("d" => "2026-11-15")) == Date(2026, 11, 15)
    @test D(Dict("d" => "11/15/2026")) == Date(2026, 11, 15) && D(Dict("d" => "Nov 15, 2026")) == Date(2026, 11, 15)   # English formats
    @test D(Dict("d" => "11/15/26")) == Date(2026, 11, 15) && D(Dict("d" => "1/2/70")) == Date(1970, 1, 2)            # two-digit years
    @test D(Dict("d" => "15.11.2026")) == ["Enter a valid date."]
    with_language("de") do
        @test D(Dict("d" => "15.11.2026")) == Date(2026, 11, 15) && D(Dict("d" => "2026-11-15")) == Date(2026, 11, 15)
        @test D(Dict("d" => "11/15/2026")) isa Vector{String}                  # an error (in German)
    end
    @test D(Dict("d" => "15|11|2026"); input_formats = ["%d|%m|%Y"]) == Date(2026, 11, 15)
    override_settings(DATE_INPUT_FORMATS = ["%d %m %Y"]) do
        with_language("sv") do                                       # a language without formats of its own
            @test D(Dict("d" => "15 11 2026")) == Date(2026, 11, 15)
        end
    end
    T(data; kw...) = (f = Form([:t => DateTimeField(; kw...)]; data = data); is_valid(f) ? f.cleaned_data[:t] : f.errors[:t])
    @test T(Dict("t" => "11/15/2026 14:30")) == DateTime(2026, 11, 15, 14, 30) && T(Dict("t" => "2026-11-15T14:30")) == DateTime(2026, 11, 15, 14, 30)
    with_language("fr") do
        @test T(Dict("t" => "15/11/2026 14:30:05")) == DateTime(2026, 11, 15, 14, 30, 5)
    end
    N(s; kw...) = (f = Form([:n => DecimalField(; max_digits = 10, decimal_places = 2, kw...)]; data = Dict("n" => s)); is_valid(f) ? f.cleaned_data[:n] : f.errors[:n])
    with_language("de") do
        @test N("1.234,5"; localize = true) == Juango.Decimal("1234.5")
        @test N("1.234,5") isa Vector{String}                        # only with localize = true, as Django
    end

    # SelectDateWidget
    sdw = SelectDateWidget(years = 2024:2027)
    F(data) = Form([:born => DateField(widget = sdw, blank = true)]; data = data)
    f = F(Dict("born_year" => "2026", "born_month" => "3", "born_day" => "7"))
    @test is_valid(f) && f.cleaned_data[:born] == Date(2026, 3, 7)
    f = F(Dict("born_year" => "2026", "born_month" => "", "born_day" => "7"))
    @test !is_valid(f) && f.errors[:born] == ["Enter a valid date."]
    @test is_valid(F(Dict("born_year" => "", "born_month" => "", "born_day" => ""))) && F(Dict()).data !== nothing
    html = as_p(Form([:born => DateField(widget = sdw)]; initial = Dict(:born => Date(2025, 12, 31)))).s
    @test occursin("name=\"born_year\"", html) && occursin("<option value=\"2025\" selected>", html)
    @test occursin("<option value=\"12\" selected>December</option>", html) && occursin("<option value=\"31\" selected>", html)
    @test findfirst("born_month", html)[1] < findfirst("born_day", html)[1]            # English: month, day, year
    with_language("de") do
        h = as_p(Form([:born => DateField(widget = sdw)])).s
        @test findfirst("born_day", h)[1] < findfirst("born_month", h)[1]
    end
    # SplitHiddenDateTimeWidget
    h = as_p(Form([:when => SplitDateTimeField(widget = SplitHiddenDateTimeWidget())]; initial = Dict(:when => DateTime(2024, 1, 2, 3, 4)))).s
    @test occursin("type=\"hidden\" name=\"when_0\"", h) && occursin("type=\"hidden\" name=\"when_1\"", h)

    # NullBooleanField
    NB(v) = (f = Form([:ok => NullBooleanField()]; data = Dict("ok" => v)); is_valid(f) ? f.cleaned_data[:ok] : f.errors[:ok])
    @test NB("true") === true && NB("false") === false && NB("unknown") === nothing && NB("") === nothing
    @test occursin("<option value=\"unknown\"", as_p(Form([:ok => NullBooleanField()])).s)

    # errors as data, field order, required attributes, legend
    g = Form([:a => CharField(), :b => IntegerField()]; data = Dict("a" => "", "b" => "x"), field_order = [:b])
    @test [x.name for x in g.fields] == [:b, :a]
    is_valid(g); add_error!(g, nothing, "whole form")                 # (validating clears errors: add it after)
    @test errors_json_data(g)["b"] == [Dict("message" => "Enter a whole number.", "code" => "")]
    @test JSON.parse(errors_as_json(g))["a"][1]["message"] == "This field is required." && Juango.non_field_errors(g) == ["whole form"]
    @test !occursin(" required", as_p(Form([:a => CharField()]; use_required_attribute = false)).s)
    @test occursin(" required", as_p(Form([:a => CharField()])).s)
    FS = formset_factory((d; prefix, initial) -> Form([:qty => IntegerField()]; data = d, prefix = prefix, initial = initial); extra = 1)
    @test !occursin(" required", as_p(first(FS())).s)                # formsets: none, as Django
    bf = Form([:size => CharField(choices = ["s" => "Small"], widget = :radio, label = "Size")])[:size]
    @test legend_tag(bf) == "<legend>Size:</legend>"
end

@testset "model formsets with a custom row form; set_field! (#156)" begin
    rollback_after() do
        a1 = create(Author; name = "MF156 a", email = "a@x156.io"); a2 = create(Author; name = "MF156 b", email = "b@x156.io")
        # a row form of its own: an extra field, initial values from the instance, its own clean
        function row(; data, instance, prefix, initial)
            init = instance === nothing ? initial : merge(Dict{Symbol,Any}(initial), Dict(:shout => uppercase(instance.name)))
            f = ModelForm(Author; data = data, instance = instance, prefix = prefix, initial = init, fields = [:name, :email],
                          extra_fields = [:shout => CharField(blank = true)],
                          clean = f -> (get(f.cleaned_data, :name, "") == "bad" && add_error!(f, :name, "No.")))
            set_field!(f, :email, EmailField(blank = true, help_text = "optional"))    # replaced in place
            f
        end
        FS = modelformset_factory(Author; form = row, extra = 0)
        fs = FS(; queryset = order_by(filter(Author; name__startswith = "MF156"), "name"))
        Juango.build_forms!(fs)
        @test length(fs.forms) == 2 && [x.name for x in fs.forms[1].fields] == [:id, :name, :email, :shout]   # (the formset adds id)
        @test fs.forms[1].initial[:shout] == "MF156 A" && fs.forms[1][:email].field.help_text == "optional"
        data = Dict("form-TOTAL_FORMS" => "2", "form-INITIAL_FORMS" => "2",
                    "form-0-id" => string(a1.id), "form-0-name" => "MF156 a2", "form-0-email" => "", "form-0-shout" => "x",
                    "form-1-id" => string(a2.id), "form-1-name" => "bad", "form-1-email" => "b@x156.io")
        fs = FS(data; queryset = order_by(filter(Author; name__startswith = "MF156"), "name"))
        @test !is_valid(fs) && fs.forms[2].errors[:name] == ["No."]
        data["form-1-name"] = "MF156 b2"
        fs = FS(data; queryset = order_by(filter(Author; name__startswith = "MF156"), "name"))
        @test is_valid(fs)
        save!(fs)
        @test get(Author; id = a1.id).name == "MF156 a2" && get(Author; id = a1.id).email == "" && get(Author; id = a2.id).name == "MF156 b2"
        # the ModelForm options pass through
        FS2 = modelformset_factory(Author; fields = [:name], help_texts = Dict(:name => "Full name"), extra = 1,
                                   extra_fields = [:note => CharField(blank = true)])
        f = first(FS2())
        @test f[:name].field.help_text == "Full name" && [x.name for x in f.fields] == [:id, :name, :note]
        # inline formsets too
        IF = inlineformset_factory(Author, Article; form = (; data, instance, prefix, initial) ->
                                       ModelForm(Article; data, instance, prefix, initial, fields = [:title], labels = Dict(:title => "Heading")),
                                   extra = 1)
        @test Juango.label(first(IF(; instance = a1))[:title].field) == "Heading"
    end
    # set_field! and delete_field! on any form
    g = Form([:a => CharField(), :b => CharField()])
    set_field!(g, :c, IntegerField(); after = :a)
    @test [x.name for x in g.fields] == [:a, :c, :b]
    set_field!(g, :b, IntegerField(); before = :a)
    @test [x.name for x in g.fields] == [:b, :a, :c] && g.fields[1].kind in Juango.INT_KINDS
    set_field!(g, :d, CharField())
    @test g.fields[end].name === :d
    @test_throws ArgumentError set_field!(g, :e, CharField(); after = :nope)
    delete_field!(g, :a)
    @test [x.name for x in g.fields] == [:b, :c, :d]
end

@testset "BoundField.name is the field's own name; formset.forms builds on use (#157, #158)" begin
    f = Form([:title => CharField()]; prefix = "p")
    @test f[:title].name == "title" && f[:title].html_name == "p-title"
    FS = formset_factory((d; prefix, initial) -> Form([:qty => IntegerField()]; data = d, prefix = prefix, initial = initial);
                         extra = 2, can_delete = true)
    fs = FS()
    @test length(fs.forms) == 2 && all(x -> x isa Juango.Form, fs.forms)      # built on first use, in Julia too
    @test fs.forms === fs.forms                                                  # (once)
    html = tr("{% for form in fs %}{% for field in form %}{% if field.name != 'DELETE' %}[{{ field.name }}]{% endif %}{% endfor %}{% endfor %}",
              Dict("fs" => fs))
    @test html == "[qty][qty]"                                                   # the idiom works: DELETE left out
end

@testset "field attributes from the template: render_field, add_class, attr (#112)" begin
    f = Form([:title => CharField(max_length = 20), :body => TextField(blank = true, widget = Widget(:textarea; attrs = Dict("class" => "own"))),
              :colour => CharField(max_length = 1, choices = ["r" => "Red", "g" => "Green"]), :ok => BooleanField(blank = true)])
    r(src, form = f) = render(Template(src), Dict{String,Any}("form" => form))
    t = r("""{% render_field form.title class="input" placeholder="Title" %}""")
    @test occursin("class=\"input\"", t) && occursin("placeholder=\"Title\"", t) && occursin("name=\"title\"", t) && occursin("maxlength", t)
    b = r("""{% render_field form.body class+="wide" rows="3" %}""")
    @test occursin("<textarea", b) && occursin("class=\"own wide\"", b) && occursin("rows=\"3\"", b)   # += appends to the widget's own
    @test occursin("class=\"input\"", r("""{% render_field form.body class="input" %}""")) && !occursin("own", r("""{% render_field form.body class="input" %}"""))
    @test occursin("<select", r("""{% render_field form.colour class="sel" %}""")) && occursin("class=\"sel\"", r("""{% render_field form.colour class="sel" %}"""))
    @test occursin("type=\"checkbox\"", r("""{% render_field form.ok class="tick" %}""")) && occursin("class=\"tick\"", r("""{% render_field form.ok class="tick" %}"""))
    @test occursin("autofocus", r("""{% render_field form.title autofocus="" %}""")) && !occursin("autofocus=", r("""{% render_field form.title autofocus="" %}"""))
    @test count("id=\"id_title\"", r("""{% render_field form.title id="other" name="x" %}""")) == 1                # id/name stay the widget's
    v = r("""{% with cls="from-var" %}{% render_field form.title class=cls %}{% endwith %}""")
    @test occursin("class=\"from-var\"", v)
    # the filters, chained
    c = r("""{{ form.title|add_class:"a"|add_class:"b"|attr:"placeholder:Name"|set_data:"role:main" }}""")
    @test occursin("class=\"a b\"", c) && occursin("placeholder=\"Name\"", c) && occursin("data-role=\"main\"", c) && !occursin("&lt;", c)
    @test occursin("class=\"own x\"", r("""{{ form.body|append_attr:"class:x" }}"""))
    @test r("""{{ form.title|field_type }} {{ form.body|widget_type }}""") == "char textarea"
    # error and required classes
    bad = Form([:title => CharField(max_length = 20)]; data = Dict("title" => ""))
    is_valid(bad)
    @test occursin("class=\"is-invalid\"", r("""{{ form.title|add_error_class:"is-invalid" }}""", bad))
    @test !occursin("is-invalid", r("""{{ form.title|add_error_class:"is-invalid" }}"""))
    @test occursin("class=\"req\"", r("""{{ form.title|add_required_class:"req" }}""")) && !occursin("req", r("""{{ form.body|add_required_class:"req" }}"""))
    # a tweaked field still gives its label and errors; other values pass through the filters untouched
    @test r("""{{ form.title|add_class:"a"|attr:"x:1" }}{% with t=form.title|add_class:"a" %}{{ t.label }}{% endwith %}""") |> s -> occursin("Title", s)
    @test r("""{{ "text"|add_class:"a" }}""") == "text"
    @test_throws Juango.TemplateSyntaxError Template("""{% render_field form.title class %}""")
    @test_throws Juango.TemplateSyntaxError r("""{% render_field "not a field" class="a" %}""")
end

# nested forms (#188): the report-sheet case, three levels over a JSON-style document
nt_sheet(d; prefix = "", initial = Dict()) = Form([:title => CharField(max_length = 30)]; data = d, prefix = prefix, initial = initial)
nt_plate(d; prefix = "", initial = Dict()) = Form([:name => CharField(max_length = 20)]; data = d, prefix = prefix, initial = initial)
nt_block(d; prefix = "", initial = Dict()) = Form([:label => CharField(max_length = 20), :wells => IntegerField(blank = true, null = true)];
                                              data = d, prefix = prefix, initial = initial)
@testset "nested forms over a document, and over models (#188)" begin
    doc = Dict("title" => "Sheet", "kind" => "plate map",                       # "kind": no form edits it, it's kept
               "plates" => [Dict("name" => "P1", "colour" => "red", "blocks" => [Dict("label" => "A", "wells" => 8), Dict("label" => "B", "wells" => 4)]),
                            Dict("name" => "P2", "blocks" => [Dict("label" => "C", "wells" => 2)])])
    spec = (; plates = nested_formset(nt_plate; extra = 1, can_delete = true, can_order = true,
                                      children = (; blocks = nested_formset(nt_block; extra = 1, can_delete = true))))
    t = nested_form(nt_sheet; initial = doc, children = spec)
    @test t.plates isa Juango.NestedFormSet && length(t.plates) == 3 && length(t[:plates][1].blocks) == 3       # initial rows + 1 extra
    @test t.plates.formset.prefix == "plates" && t[:plates][1].form.prefix == "plates-0" && t[:plates][1].blocks.formset.prefix == "plates-0-blocks"
    @test t[:plates][1].form.initial[:name] == "P1" && t[:plates][2][:blocks][1].form.initial[:label] == "C"
    html = as_p(t).s
    @test occursin("name=\"plates-0-blocks-1-label\"", html) && occursin("value=\"B\"", html) && occursin("plates-1-blocks-TOTAL_FORMS", html)
    @test !has_changed(t) && !is_valid(t)                                       # unbound
    # a submission: title edited; P1's block B relabelled and A deleted; P2 deleted; a new plate P3 (from the extra row) with a block;
    # the new plate moved first
    data = Dict("title" => "Sheet 2",
                "plates-TOTAL_FORMS" => "3", "plates-INITIAL_FORMS" => "2",
                "plates-0-name" => "P1", "plates-0-ORDER" => "2",
                "plates-0-blocks-TOTAL_FORMS" => "3", "plates-0-blocks-INITIAL_FORMS" => "2",
                "plates-0-blocks-0-label" => "A", "plates-0-blocks-0-wells" => "8", "plates-0-blocks-0-DELETE" => "on",
                "plates-0-blocks-1-label" => "B2", "plates-0-blocks-1-wells" => "4", "plates-0-blocks-2-label" => "",
                "plates-1-name" => "P2", "plates-1-ORDER" => "3", "plates-1-DELETE" => "on",
                "plates-1-blocks-TOTAL_FORMS" => "2", "plates-1-blocks-INITIAL_FORMS" => "1", "plates-1-blocks-0-label" => "C", "plates-1-blocks-0-wells" => "2",
                "plates-2-name" => "P3", "plates-2-ORDER" => "1",
                "plates-2-blocks-TOTAL_FORMS" => "1", "plates-2-blocks-INITIAL_FORMS" => "0", "plates-2-blocks-0-label" => "D", "plates-2-blocks-0-wells" => "")
    t = nested_form(nt_sheet; data = data, initial = doc, children = spec)
    @test is_valid(t) && has_changed(t)
    c = cleaned_data(t)
    @test c["title"] == "Sheet 2" && c["kind"] == "plate map"
    @test [p["name"] for p in c["plates"]] == ["P3", "P1"]                       # P2 deleted, P3 first by ORDER
    @test c["plates"][2]["colour"] == "red"                                     # a key no form edits survives on its row
    @test [b["label"] for b in c["plates"][2]["blocks"]] == ["B2"] && c["plates"][2]["blocks"][1]["wells"] == 4
    @test c["plates"][1]["blocks"] == [Dict("label" => "D", "wells" => nothing)]
    @test !haskey(c["plates"][1], "ORDER") && !haskey(c["plates"][1], "DELETE")
    # the same values submitted back: nothing changed
    same = Dict("title" => "Sheet", "plates-TOTAL_FORMS" => "2", "plates-INITIAL_FORMS" => "2",
                "plates-0-name" => "P1", "plates-0-ORDER" => "1", "plates-0-blocks-TOTAL_FORMS" => "2", "plates-0-blocks-INITIAL_FORMS" => "2",
                "plates-0-blocks-0-label" => "A", "plates-0-blocks-0-wells" => "8", "plates-0-blocks-1-label" => "B", "plates-0-blocks-1-wells" => "4",
                "plates-1-name" => "P2", "plates-1-ORDER" => "2", "plates-1-blocks-TOTAL_FORMS" => "1", "plates-1-blocks-INITIAL_FORMS" => "1",
                "plates-1-blocks-0-label" => "C", "plates-1-blocks-0-wells" => "2")
    t2 = nested_form(nt_sheet; data = same, initial = doc, children = spec)
    @test !has_changed(t2) && is_valid(t2)
    @test has_changed(nested_form(nt_sheet; data = merge(same, Dict("plates-1-blocks-0-label" => "CC")), initial = doc, children = spec))   # three levels down
    @test has_changed(nested_form(nt_sheet; data = merge(same, Dict("plates-0-ORDER" => "2", "plates-1-ORDER" => "1")), initial = doc, children = spec))  # moved
    # an error three levels down fails the whole tree, and is on that row's form
    bad = merge(same, Dict("plates-1-blocks-0-label" => "", "plates-1-blocks-0-wells" => "x"))
    tb = nested_form(nt_sheet; data = bad, initial = doc, children = spec)
    @test !is_valid(tb) && haskey(tb[:plates][2][:blocks][1].form.errors, :label) && haskey(tb[:plates][2][:blocks][1].form.errors, :wells)
    # an extra plate left blank but with a block filled in counts, so its own required name is checked
    ex = merge(same, Dict("plates-TOTAL_FORMS" => "3", "plates-2-name" => "", "plates-2-blocks-TOTAL_FORMS" => "1", "plates-2-blocks-INITIAL_FORMS" => "0",
                          "plates-2-blocks-0-label" => "E"))
    te = nested_form(nt_sheet; data = ex, initial = doc, children = spec)
    @test !is_valid(te) && haskey(te[:plates][3].form.errors, :name)
    # from a template
    out = render(Template("{{ tree.title.value }}|{% for p in tree.plates %}{{ p.name.value }}:{% for b in p.blocks %}{{ b.label.value }}{% endfor %};{% endfor %}"),
                 Dict{String,Any}("tree" => nested_form(nt_sheet; initial = doc, children = spec)))
    @test out == "Sheet|P1:AB;P2:C;:;"
    @test occursin("plates-__prefix__-blocks-0-label", as_p(empty_form(t.plates)).s)
    r3 = as_p(Juango.nested_row(spec.plates, "plates", 3)).s                    # a row added with htmx
    @test occursin("name=\"plates-3-name\"", r3) && occursin("plates-3-blocks-0-label", r3) && occursin("plates-3-DELETE", r3)
    # over models: an author and their articles in one form, saved in one transaction
    data = Dict("name" => "NF Author", "email" => "",
                "articles-TOTAL_FORMS" => "2", "articles-INITIAL_FORMS" => "0",
                "articles-0-title" => "NF one", "articles-0-views" => "3", "articles-1-title" => "", "articles-1-views" => "0")   # (the extra row as rendered)
    mt = nested_model_form(Author; data = data, fields = [:name, :email], nested = [:articles => (fields = [:title, :views], extra = 1, can_delete = true)])
    @test is_valid(mt)
    au = save!(mt)
    @test au.name == "NF Author" && [a.title for a in filter(Article; author = au)] == ["NF one"]
    edit = Dict("name" => "NF Author", "email" => "", "articles-TOTAL_FORMS" => "2", "articles-INITIAL_FORMS" => "1",
                "articles-0-id" => string(get(Article; title = "NF one").id), "articles-0-title" => "NF one!", "articles-0-views" => "3",
                "articles-1-title" => "NF two", "articles-1-views" => "1")
    mt2 = nested_model_form(Author; data = edit, instance = au, fields = [:name, :email], nested = [:articles => (fields = [:title, :views], extra = 1, can_delete = true)])
    @test is_valid(mt2) && has_changed(mt2)
    save!(mt2)
    @test sort([a.title for a in filter(Article; author = au)]) == ["NF one!", "NF two"]
    @test_throws ArgumentError nested_model_form(Author; nested = [:nosuch])
    @test_throws ErrorException save!(nested_form(nt_sheet; data = Dict("title" => "x"), initial = Dict()))       # not over a model
end

@testset "form template packs and layouts (#112: crispy-forms)" begin
    L = Juango.Layout
    mk(data = nothing) = Form([:name => CharField(max_length = 20, help_text = "Your name"), :email => EmailField(blank = true),
                               :colour => CharField(max_length = 1, choices = ["r" => "Red", "g" => "Green"]),
                               :ok => BooleanField(blank = true), :token => CharField(max_length = 5, blank = true, widget = :hidden)]; data = data)
    p = form_html(mk()).s                                                      # the default pack: plain
    @test occursin("<div class=\"field required\">", p) && occursin("Your name", p) && occursin("type=\"hidden\" name=\"token\"", p)
    b = form_html(mk(); pack = "bootstrap5").s
    @test occursin("class=\"form-control\"", b) && occursin("class=\"form-select\"", b) && occursin("class=\"form-check-input\"", b)
    @test occursin("<div class=\"form-text\" id=\"id_name_helptext\">Your name</div>", b)
    bad = mk(Dict("name" => "", "email" => "nope", "colour" => "r")); is_valid(bad)
    be = form_html(bad; pack = "bootstrap5").s
    @test occursin("form-control is-invalid", be) && occursin("invalid-feedback", be) && occursin("This field is required.", be)
    t = form_html(mk(); pack = "tailwind").s
    @test occursin("rounded-md border border-gray-300", t)
    # the tags
    r(src, ctx = Dict{String,Any}()) = render(Template(src), merge(Dict{String,Any}("form" => mk()), ctx))
    @test occursin("form-select", r("""{% form form pack="bootstrap5" %}"""))
    f1 = r("""{% field form.email pack="bootstrap5" placeholder="you@example.com" class="input" %}""")
    @test occursin("placeholder=\"you@example.com\"", f1) && occursin("class=\"input form-control\"", f1)   # the template's and the pack's
    override_settings(FORM_TEMPLATE_PACK = "bootstrap5") do
        @test occursin("form-control", r("""{% field form.name %}""")) && occursin("form-control", r("""{% form form %}"""))
    end
    @test_throws Juango.TemplateSyntaxError Template("""{% form form colour="x" %}""")
    # layouts
    lay = L.FormLayout(L.Fieldset("Who", :name, L.FormField(:email; placeholder = "@", add_class = "wide")),
                       L.Row(L.Column(:colour), :ok), L.RawHTML("<hr>"), L.Submit("Send"))
    h = form_html(mk(); pack = "bootstrap5", layout = lay).s
    @test occursin("<fieldset class=\"mb-3\"><legend>Who</legend>", h) && occursin("<div class=\"row\"><div class=\"col\">", h)
    @test occursin("placeholder=\"@\"", h) && occursin("wide form-control", h) && occursin("<hr>", h)
    @test occursin("<button type=\"submit\" name=\"submit\" class=\"btn btn-primary\">Send</button>", h)
    @test occursin("name=\"token\"", h)                                       # hidden fields are always there
    small = form_html(mk(); layout = L.FormLayout(:name)).s                    # only the fields the layout places
    @test occursin("name=\"name\"", small) && !occursin("name=\"email\"", small)
    @test occursin("<legend>Who</legend>", r("""{% form form layout=lay %}""", Dict{String,Any}("lay" => lay)))
    @test occursin("class=\"col-3\"", form_html(mk(); layout = L.FormLayout(L.Row(L.Column(:name; class = "col-3")))).s)
    @test_throws ArgumentError form_html(mk(); layout = L.FormLayout(42))
    # a pack of your own, from the templates directory
    mkpath(joinpath(TPL, "juango", "forms", "packs", "mine"))
    write(joinpath(TPL, "juango", "forms", "packs", "mine", "field.html"), """<p class="mine">{{ field.label }}: {% render_field field class+="m" %}</p>""")
    write(joinpath(TPL, "juango", "forms", "packs", "mine", "form.html"), """<section>{{ body }}</section>""")
    m = form_html(mk(); pack = "mine").s
    @test startswith(m, "<section><p class=\"mine\">Name: ") && occursin("class=\"m\"", m)
end

@testset "formset row predicates: is_deleted, is_blank_extra, active_forms (#193)" begin
    RowF(d; prefix = "", initial = Dict()) = Form([:name => CharField(max_length = 10)]; data = d, prefix = prefix, initial = initial)
    FS = formset_factory(RowF; extra = 1, can_delete = true)
    fs = FS(Dict("form-TOTAL_FORMS" => "3", "form-INITIAL_FORMS" => "2", "form-0-name" => "a", "form-1-name" => "b",
                 "form-1-DELETE" => "on", "form-2-name" => ""); initial = [Dict(:name => "a"), Dict(:name => "b")])
    @test is_valid(fs)
    f0, f1, f2 = fs.forms
    @test !is_deleted(fs, f0) && is_deleted(fs, f1) && !is_deleted(fs, f2)
    @test !is_blank_extra(fs, f0) && is_blank_extra(fs, f2) && active_forms(fs) == [f0]
end
