# Django's serializer and fixture tests, ported (#227): tests/serializers (SerializersTestBase run for
# each format, the JSON deserializer's errors, natural keys) and tests/fixtures (FixtureLoadingTests).
# julia --project=test test/django_serializers.jl   (see setup.jl)
#
# Juango ignores fields a fixture names that its model lacks (Django: FieldDoesNotExist unless
# --ignorenonexistent), and has no compressed fixtures. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DseCategory
    name = CharField(max_length = 20)
    Meta(table = "dse_category", ordering = ["name"])
end
@model struct DseAuthor
    name = CharField(max_length = 20)
    Meta(table = "dse_author", ordering = ["name"])
end
@model struct DseArticle
    author = ForeignKey(DseAuthor; on_delete = :CASCADE)
    headline = CharField(max_length = 50)
    pub_date = DateTimeField()
    categories = ManyToManyField(DseCategory; blank = true)
    Meta(table = "dse_article", ordering = ["pub_date"])
end
@model struct DseScore
    score = FloatField()
    Meta(table = "dse_score")
end
@model struct DsePlayer
    name = CharField(max_length = 50)
    rank = IntegerField()
    Meta(table = "dse_player")
end
@model struct DsePerson          # with a natural key
    name = CharField(max_length = 50, unique = true)
    Meta(table = "dse_person")
end
@model struct DseBook
    title = CharField(max_length = 50)
    writer = ForeignKey(DsePerson; on_delete = :CASCADE)
    Meta(table = "dse_book")
end
Juango.natural_key(p::DsePerson) = (p.name,)
Juango.get_by_natural_key(::Type{DsePerson}, name) = get(DsePerson; name = name)
const DSE_MODELS = [DseCategory, DseAuthor, DseArticle, through(DseArticle, :categories), DseScore, DsePlayer, DsePerson, DseBook]
redirect_stdout(devnull) do
    Juango.sync_models!(DSE_MODELS); append!(PORT_MODELS, DSE_MODELS)
end
dse_label(T) = Juango.serial_label(T)

function dse_setup()
    sports, music = save!(DseCategory(name = "Sports")), save!(DseCategory(name = "Music"))
    op_ed = save!(DseCategory(name = "Op-Ed"))
    joe, jane = save!(DseAuthor(name = "Joe")), save!(DseAuthor(name = "Jane"))
    a1 = save!(DseArticle(author = jane, headline = "Poker has no place on ESPN", pub_date = DateTime(2006, 6, 16, 11, 0)))
    add!(a1.categories, sports, op_ed)
    a2 = save!(DseArticle(author = joe, headline = "Time to reform copyright", pub_date = DateTime(2006, 6, 16, 13, 0, 11, 345)))
    add!(a2.categories, music, op_ed)
    (; sports, music, op_ed, joe, jane, a1, a2)
end

@testset "django serializers: SerializersTestBase ($fmt)" for fmt in (:json, :jsonl, :yaml, :xml)
    port_block() do
        o = dse_setup()
        s = serialize(fmt, objects(DseArticle))                                           # test_serialize
        objs = deserialize(fmt, s)
        @test length(objs) == 2 && all(d -> d.object isa DseArticle, objs)
        @test objs[1].object.headline == "Poker has no place on ESPN" && objs[1].object.author_id == o.jane.id
        @test sort(objs[1].m2m[:categories]) == sort([o.sports.id, o.op_ed.id])
        @test objs[2].object.pub_date == DateTime(2006, 6, 16, 13, 0, 11, 345)            # (milliseconds kept)
        s = serialize(fmt, objects(DseArticle); fields = [:headline, :pub_date])          # test_serialize_specific_fields
        d = only(filter(x -> x.object.id == o.a1.id, deserialize(fmt, s)))
        @test d.object.headline == "Poker has no place on ESPN" && d.object.author_id === nothing && isempty(d.m2m)
        s = serialize(fmt, filter(objects(DseArticle); id = o.a1.id))                     # test_altering_serialized_output
        s = replace(s, "Poker has no place on ESPN" => "Poker has no place on television")
        foreach(save!, deserialize(fmt, s))
        @test get(DseArticle; id = o.a1.id).headline == "Poker has no place on television"
        @test count(get(DseArticle; id = o.a1.id).categories) == 2
        art = save!(DseArticle(author = o.joe, headline = "Iñtërnâtiônàlizætiøn: ½ & <b>", pub_date = DateTime(2006, 1, 1)))   # test_serialize_unicode_roundtrip
        d = only(deserialize(fmt, serialize(fmt, [art])))
        @test d.object.headline == "Iñtërnâtiônàlizætiøn: ½ & <b>"
        d = only(deserialize(fmt, serialize(fmt, [DseCategory(name = "Reference")])))     # test_serialize_with_null_pk
        @test d.object.id === nothing && d.object.name == "Reference"
        save!(d)
        @test d.object.id !== nothing && exists(filter(objects(DseCategory); name = "Reference"))
        sc = save!(DseScore(score = 3.4))                                                 # test_float_serialization
        @test only(deserialize(fmt, serialize(fmt, [sc]))).object.score == 3.4
        old = save!(DseArticle(author = o.joe, headline = "Nobody remembers the early years", pub_date = DateTime(1, 2, 3, 4, 5, 6)))   # test_pre_1000ad_date
        s = serialize(fmt, [old])
        @test only(deserialize(fmt, s)).object.pub_date == DateTime(1, 2, 3, 4, 5, 6)
    end
end

@testset "django serializers: JSON details" begin
    port_block() do
        o = dse_setup()
        s = serialize(:json, [o.a1])                                                       # test_deterministic_mapping_ordering
        @test occursin(r"^\[\{\"model\":\"[^\"]+\",\"pk\":\d+,\"fields\":\{\"author\":\d+,\"headline\":", s)
        @test findfirst("\"pub_date\"", s)[1] < findfirst("\"categories\"", s)[1]
        s = """[{"model": "$(dse_label(DseCategory))", "fields": {"name": "Reference"}}]"""   # test_pkless_serialized_strings
        d = only(deserialize(:json, s))
        @test d.object.id === nothing
        save!(d)
        @test d.object.id !== nothing
        e = try deserialize(:json, """[{"pk": 1}""") catch e; e end                       # test_json_deserializer_exception
        @test e isa Juango.DeserializationError
        e = try deserialize(:json, """[{"pk": 1, "model": "serializers.nonexistent", "fields": {}}]""") catch e; e end
        @test e isa Juango.DeserializationError && e.msg == "Invalid model identifier: 'serializers.nonexistent'"
        e = try deserialize(:json, """[{"pk": 1, "model": "$(dse_label(DsePlayer))", "fields": {"name": "Bob", "rank": "invalidint"}}]""") catch e; e end
        @test e isa Juango.DeserializationError && occursin("($(dse_label(DsePlayer)):pk=1) field_value was 'invalidint'", e.msg)   # test_helpful_error_message_invalid_field
        e = try deserialize(:json, """[{"pk": 1, "model": "$(dse_label(DseArticle))", "fields": {"author": "nonexistent", "headline": "x", "pub_date": "2006-06-16T11:00:00"}}]""") catch e; e end
        @test e isa Juango.DeserializationError && occursin("field_value was 'nonexistent'", e.msg)   # test_helpful_error_message_for_foreign_keys
        @test_throws Juango.DeserializationError deserialize(:json, """{"model": "x"}""")    # (not a list)

        ann = save!(DsePerson(name = "Ann"))                                              # natural keys: test_natural_key_dependencies
        b = save!(DseBook(title = "Ann's book", writer = ann))
        s = serialize(:json, [ann, b]; natural_foreign = true, natural_primary = true)
        items = JSON.parse(s)
        @test !haskey(items[1], "pk") && items[2]["fields"]["writer"] == ["Ann"]
        delete!(b)
        foreach(save!, deserialize(:json, s))                                             # (Ann is found by her name, not added twice)
        @test count(objects(DsePerson)) == 1 && get(DseBook; title = "Ann's book").writer_id == ann.id
    end
end

@testset "django fixtures: FixtureLoadingTests" begin
    dir = mktempdir()
    cat_, art, auth, cats = dse_label(DseCategory), dse_label(DseArticle), dse_label(DseAuthor), dse_label(through(DseArticle, :categories))
    write(joinpath(dir, "fixture1.json"), """[
        {"model": "$cat_", "pk": 1, "fields": {"name": "News Stories"}},
        {"model": "$auth", "pk": 1, "fields": {"name": "Writer"}},
        {"model": "$art", "pk": 2, "fields": {"author": 1, "headline": "Poker has no place on ESPN", "pub_date": "2006-06-16T12:00:00", "categories": [1]}},
        {"model": "$art", "pk": 3, "fields": {"author": 1, "headline": "Time to reform copyright", "pub_date": "2006-06-16T13:00:00", "categories": []}}]""")
    write(joinpath(dir, "fixture2.yaml"), """
        - model: $art
          pk: 4
          fields: {author: 1, headline: Django conquers world!, pub_date: '2006-06-16T15:00:00'}
        """)
    write(joinpath(dir, "fixture3.json"), "[]"); write(joinpath(dir, "fixture3.xml"), """<?xml version="1.0" encoding="utf-8"?><django-objects version="1.0"></django-objects>""")
    write(joinpath(dir, "bad.json"), """[{"model": "$art", "pk": 9, "fields": {"author": 1, "headline": "x", "pub_date": "not a date"}}]""")
    old = get(settings, :FIXTURE_DIRS, String[])
    configure!(FIXTURE_DIRS = [dir])
    try
        port_block() do
            @test loaddata("fixture1") == 4                                               # test_loading_and_dumping
            @test [a.headline for a in objects(DseArticle)] == ["Poker has no place on ESPN", "Time to reform copyright"]
            @test [c.name for c in get(DseArticle; id = 2).categories] == ["News Stories"]
            dumped = dumpdata(dse_label(DseCategory))
            @test dumped == """[{"model":"$cat_","pk":1,"fields":{"name":"News Stories"}}]"""
            @test dumpdata(art; primary_keys = [2]) |> JSON.parse |> x -> [d["pk"] for d in x] == [2]   # test_dumpdata_with_pks
            @test dumpdata(art; primary_keys = [2, 3]) |> JSON.parse |> x -> [d["pk"] for d in x] == [2, 3]
            e = try dumpdata(art, cat_; primary_keys = [2]) catch e; e end
            @test e isa ArgumentError && occursin("only use primary_keys with one model", e.msg)
            names = [d["model"] for d in JSON.parse(dumpdata(lowercase(Juango.modelmeta(DseArticle).app); exclude = [art, cats]))]   # test_dumpdata_with_excludes
            @test !(art in names) && cat_ in names && auth in names
            @test loaddata("fixture2") == 1 && get(DseArticle; id = 4).headline == "Django conquers world!"   # (a YAML fixture)
            new = save!(DseArticle(author = get(DseAuthor; id = 1), headline = "after", pub_date = DateTime(2007)))   # test_db_loading: the sequence moved past the loaded ids
            @test new.id > 4
            n = save!(DseScore(score = 1.0)).id; delete!(objects(DseScore))              # (ids just past the sequence: a collision without the reset)
            write(joinpath(dir, "scores.json"), """[{"model": "$(dse_label(DseScore))", "pk": $(n + 1), "fields": {"score": 1.5}},
                                                    {"model": "$(dse_label(DseScore))", "pk": $(n + 2), "fields": {"score": 2.5}}]""")
            @test loaddata("scores") == 2
            @test save!(DseScore(score = 3.5)).id > n + 2
            e = try loaddata("fixture3") catch e; e end                                   # test_ambiguous_compressed_fixture (here: two formats)
            @test e isa ArgumentError && occursin("Multiple fixtures named 'fixture3'", e.msg)
            e = try loaddata("this_fixture_doesnt_exist") catch e; e end                  # test_loaddata_not_existent_fixture_file
            @test e isa ArgumentError && occursin("no fixture named 'this_fixture_doesnt_exist'", e.msg)
            e = try loaddata("bad") catch e; e end                                        # test_loaddata_error_message
            @test e isa Juango.DeserializationError && occursin("($art:pk=9) field_value was 'not a date'", e.msg)
            @test !exists(filter(objects(DseArticle); id = 9))
        end
        port_block() do
            @test loaddata("fixture1"; exclude = [art]) == 2                              # test_loading_with_exclude_model
            @test !exists(objects(DseArticle)) && exists(objects(DseCategory))
            @test loaddata("fixture1"; exclude = [lowercase(Juango.modelmeta(DseArticle).app)]) == 0   # test_loading_with_exclude_app
            seen = Any[]                                                                  # (fixtures save raw: pre_save/post_save say so)
            h(sender; raw = false, created = nothing, kw...) = push!(seen, (raw, created))
            connect!(pre_save, h; sender = DseCategory); connect!(post_save, h; sender = DseCategory)
            try
                loaddata("fixture1")
                @test seen == [(true, false), (true, false)]                              # (the category was there: an update)
                empty!(seen)
                save!(DseCategory(name = "plain"))
                @test seen == [(false, true), (false, true)]
                empty!(seen)
                foreach(save!, deserialize(:json, """[{"model": "$cat_", "fields": {"name": "pkless"}}]"""))
                @test seen == [(true, true), (true, true)]
            finally
                disconnect!(pre_save, h; sender = DseCategory); disconnect!(post_save, h; sender = DseCategory)
            end
        end
    finally
        configure!(FIXTURE_DIRS = old)
    end
    # not translated: compressed fixtures (.gz, .zip, .bz2, .xz), loaddata from stdin, --app, --database,
    # the management command's verbosity and progress output, ignorenonexistent, proxy and
    # multi-table inheritance serialization details
end
