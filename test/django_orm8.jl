# Django's model_options tests (default_related_name) and absolute_url_overrides, translated (#227).
#
# Not translated: model_options' test_default_pk (DEFAULT_AUTO_FIELD and AppConfig.default_auto_field: Juango's is
# Meta(pk = ...), tested in orm.jl) and test_tablespaces (Oracle and PostgreSQL tablespaces).

# --- tests/model_options/models/default_related_name.py ---------------------------------------------------
@model struct DmoAuthor
    first_name = CharField(max_length = 128)
    last_name = CharField(max_length = 128)
    Meta(table = "dmo_author")
end
@model struct DmoEditor
    name = CharField(max_length = 128)
    bestselling_author = ForeignKey(DmoAuthor; on_delete = :CASCADE)
    Meta(table = "dmo_editor")
end
@model struct DmoBook
    title = CharField(max_length = 128)
    authors = ManyToManyField(DmoAuthor)
    editor = ForeignKey(DmoEditor; on_delete = :CASCADE, related_name = "edited_books")
    Meta(table = "dmo_book", default_related_name = "books")
end
@abstract_model struct DmoStore
    name = CharField(max_length = 128)
    address = CharField(max_length = 128)
    Meta(default_related_name = "%(app_label)s_%(model_name)ss")
end
@model struct DmoBookStore <: DmoStore
    available_books = ManyToManyField(DmoBook)
    Meta(table = "dmo_bookstore")
end
@model struct DmoEditorStore <: DmoStore
    editor = ForeignKey(DmoEditor; on_delete = :CASCADE)
    available_books = ManyToManyField(DmoBook)
    Meta(table = "dmo_editorstore", default_related_name = "editor_stores")
end

redirect_stdout(devnull) do
    ms = Any[DmoAuthor, DmoEditor, DmoBook, through(DmoBook, :authors), DmoBookStore, through(DmoBookStore, :available_books),
             DmoEditorStore, through(DmoEditorStore, :available_books)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_options: DefaultRelatedNameTests" begin
    port_block() do
        author = create(DmoAuthor; first_name = "Dave", last_name = "Loper")
        editor = create(DmoEditor; name = "Test Editions", bestselling_author = author)
        book = create(DmoBook; title = "Test Book", editor = editor)
        add!(book.authors, author)
        pks(qs) = [x.pk for x in collect(qs)]
        @test pks(author.dmoeditor_set) == [editor.pk]                               # test_no_default_related_name
        @test pks(author.books) == [book.pk]                                         # test_default_related_name
        @test get(DmoAuthor; books = book).pk == author.pk                           # test_default_related_name_in_queryset_lookup
        @test_throws Juango.LookupError get(DmoAuthor; dmobook = book)                # test_model_name_not_available_in_queryset_lookup
        @test pks(editor.edited_books) == [book.pk]                                  # test_related_name_overrides_default_related_name
        app = lowercase(Juango.modelmeta(DmoBookStore).app)
        @test isempty(collect(getproperty(book, Symbol(app, "_dmobookstores"))))   # test_inheritance
        @test isempty(collect(book.editor_stores))                                   # test_inheritance_with_overridden_default_related_name
    end
end

# --- tests/absolute_url_overrides ---------------------------------------------------------------------------
@model struct DauTestA
    name = CharField(max_length = 50)
    Meta(table = "dau_testa", app_label = "absolute_url_overrides")
end
@model struct DauTestB
    name = CharField(max_length = 50)
    Meta(table = "dau_testb", app_label = "absolute_url_overrides")
end
@model struct DauTestC
    name = CharField(max_length = 50)
    Meta(table = "dau_testc", app_label = "absolute_url_overrides")
end
Juango.get_absolute_url(o::DauTestA) = "/test-a/$(o.pk)/"
Juango.get_absolute_url(o::DauTestB) = "/test-b/$(o.pk)/"

@testset "django absolute_url_overrides" begin
    # test_get_absolute_url
    obj = DauTestA(; id = 1, name = "Foo")
    @test absolute_url(obj) == "/test-a/1/" == get_absolute_url(obj)
    # test_override_get_absolute_url: ABSOLUTE_URL_OVERRIDES wins (keyed by the lowercase "app.model")
    override_settings(ABSOLUTE_URL_OVERRIDES = Dict("absolute_url_overrides.dautestb" => o -> "/overridden-test-b/$(o.pk)/")) do
        @test absolute_url(DauTestB(; id = 1, name = "Foo")) == "/overridden-test-b/1/"
        @test render(Template("{{ o.get_absolute_url }}"), Dict("o" => DauTestB(; id = 1, name = "Foo"))) == "/overridden-test-b/1/"
    end
    # test_insert_get_absolute_url: also for a model without get_absolute_url
    @test absolute_url(DauTestC(; id = 1, name = "Foo")) === nothing
    override_settings(ABSOLUTE_URL_OVERRIDES = Dict("absolute_url_overrides.dautestc" => o -> "/test-c/$(o.pk)/")) do
        @test absolute_url(DauTestC(; id = 1, name = "Foo")) == "/test-c/1/"
    end
end
