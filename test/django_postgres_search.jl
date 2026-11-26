# Django's postgres_tests/test_search, ported (#227). Full-text search expressions need PostgreSQL (the
# __search lookup falls back to word matching elsewhere): the database tests run there; Lexeme's text,
# quote_lexeme, the queries' repr and the argument errors run everywhere.
# julia --project=test test/django_postgres_search.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment. These use dialogue from Monty Python and the Holy Grail, as Django's.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DseScene
    scene = TextField()
    setting = CharField(max_length = 255)
    Meta(table = "dse_scene")
end
@model struct DseCharacter
    name = CharField(max_length = 255)
    Meta(table = "dse_character")
end
@model struct DseLine
    scene = ForeignKey(DseScene; on_delete = :CASCADE)
    character = ForeignKey(DseCharacter; on_delete = :CASCADE)
    dialogue = TextField(blank = true, null = true)
    dialogue_search_vector = SearchVectorField(blank = true, null = true)
    dialogue_config = CharField(max_length = 100, blank = true, null = true)
    Meta(table = "dse_line")
end
@model struct DseLineSavedSearch
    line = ForeignKey(DseLine; on_delete = :CASCADE)
    query = CharField(max_length = 100)
    Meta(table = "dse_linesavedsearch")
end
const DSE_MODELS = [DseScene, DseCharacter, DseLine, DseLineSavedSearch]
redirect_stdout(devnull) do
    Juango.sync_models!(DSE_MODELS); append!(PORT_MODELS, DSE_MODELS)
end
const DSE_PG = Juango.backend() isa Juango.PostgresBackend

function dse_grail()
    robin = create(DseScene; scene = "Scene 10", setting = "The dark forest of Ewing")
    minstrel = create(DseCharacter; name = "Minstrel")
    verses = [create(DseLine; scene = robin, character = minstrel, dialogue = v) for v in [
        "Bravely bold Sir Robin, rode forth from Camelot. He was not afraid to die, o Brave Sir Robin. " *
        "He was not at all afraid to be killed in nasty ways. Brave, brave, brave, brave Sir Robin",
        "He was not in the least bit scared to be mashed into a pulp, Or to have his eyes gouged out, and his elbows broken. " *
        "To have his kneecaps split, and his body burned away, And his limbs all hacked and mangled, brave Sir Robin!",
        "His head smashed in and his heart cut out, And his liver removed and his bowels unplugged, " *
        "And his nostrils ripped and his bottom burned off,And his --"]]
    witch_scene = create(DseScene; scene = "Scene 5", setting = "Sir Bedemir's Castle")
    bedemir, crowd, witch, duck = (create(DseCharacter; name = n) for n in ("Bedemir", "Crowd", "Witch", "Duck"))
    d = (verse0 = verses[1], verse1 = verses[2], verse2 = verses[3], verses = verses, robin = robin, minstrel = minstrel, witch_scene = witch_scene,
         bedemir0 = create(DseLine; scene = witch_scene, character = bedemir, dialogue = "We shall use my larger scales!", dialogue_config = "english"),
         bedemir1 = create(DseLine; scene = witch_scene, character = bedemir, dialogue = "Right, remove the supports!", dialogue_config = "english"),
         duck = create(DseLine; scene = witch_scene, character = duck, dialogue = nothing),
         crowd = create(DseLine; scene = witch_scene, character = crowd, dialogue = "A witch! A witch!"),
         witch = create(DseLine; scene = witch_scene, character = witch, dialogue = "It's a fair cop."),
         french = (s = create(DseScene; scene = "Scene 8", setting = "The castle of Our Master Ruiz' de lu la Ramper");
                   create(DseLine; scene = s, character = create(DseCharacter; name = "French Guards"), dialogue = "Oh. Un beau cadeau. Oui oui.",
                          dialogue_config = "french")))
    d
end
dse_ids(qs) = sort([o.id for o in qs])
dse_ids(objs::Vector{<:Juango.Model}) = sort([o.id for o in objs])
dse_sv(x...; kw...) = annotate(DseLine; search = SearchVector(x...; kw...))

@testset "django postgres_tests test_search: without a database" begin
    @test Juango.search_config(nothing) === nothing                                                    # SearchConfigTests.test_from_parameter
    @test Juango.search_config("foo") == SearchConfig("foo")
    @test Juango.search_config(SearchConfig("bar")) == SearchConfig("bar")
    @test_throws "Unknown search_type argument 'foo'." SearchQuery("kneecaps"; search_type = "foo")    # test_bad_search_type
    @test_throws "SearchVector can only be combined with other SearchVector instances, got Nothing." nothing + SearchVector(:character__name)   # test_vector_combined_mismatch
    @test_throws "SearchQuery can only be combined with other SearchQuery instances, got Nothing." nothing | SearchQuery("kneecaps")   # test_query_combined_mismatch
    @test_throws "SearchQuery can only be combined with other SearchQuery instances, got Nothing." nothing & SearchQuery("kneecaps")
    for (q, s) in [(~SearchQuery("a"), "~SearchQuery(Value('a'))"),                                     # SearchQueryTests.test_str
                   ((SearchQuery("a") | SearchQuery("b")) & (SearchQuery("c") | SearchQuery("d")),
                    "((SearchQuery(Value('a')) || SearchQuery(Value('b'))) && (SearchQuery(Value('c')) || SearchQuery(Value('d'))))"),
                   (SearchQuery("a") & (SearchQuery("b") | SearchQuery("c")), "(SearchQuery(Value('a')) && (SearchQuery(Value('b')) || SearchQuery(Value('c'))))"),
                   ((SearchQuery("a") | SearchQuery("b")) & SearchQuery("c"), "((SearchQuery(Value('a')) || SearchQuery(Value('b'))) && SearchQuery(Value('c')))"),
                   (SearchQuery("a") & (SearchQuery("b") & (SearchQuery("c") | SearchQuery("d"))),
                    "(SearchQuery(Value('a')) && (SearchQuery(Value('b')) && (SearchQuery(Value('c')) || SearchQuery(Value('d')))))")]
        @test sprint(show, q) == s
    end
    for (e, t) in [(Lexeme("a"), "'a'"), (Lexeme("a"; invert = true), "!'a'"), (~Lexeme("a"), "!'a'"), (Lexeme("a"; prefix = true), "'a':*"),   # test_as_sql
                   (Lexeme("a"; weight = "D"), "'a':D"), (Lexeme("a"; invert = true, prefix = true, weight = "D"), "!'a':*D"),
                   (Lexeme("a") | Lexeme("b") & ~Lexeme("c"), "('a' | ('b' & !'c'))"), (~(Lexeme("a") | Lexeme("b") & ~Lexeme("c")), "(!'a' & (!'b' | 'c'))")]
        @test Juango.lexeme_text(e) == t
    end
    for (l, q) in [("L'amour piqué par une abeille", "'L amour piqué par une abeille'"), ("'starting quote", "'starting quote'"),   # test_quote_lexeme
                   ("ending quote'", "'ending quote'"), ("double quo''te", "'double quo te'"), ("triple quo'''te", "'triple quo te'"),
                   ("backslash\\", "'backslash'"), ("exclamation!", "'exclamation'"), ("ampers&nd", "'ampers nd'"), ("&", "NULL")]
        @test quote_lexeme(l) == q
    end
    @test_throws "A Lexeme can only be combined with another Lexeme, got Nothing." nothing | Lexeme("kneecaps")   # test_invalid_combinations
    @test_throws "A Lexeme can only be combined with another Lexeme, got Nothing." nothing & Lexeme("kneecaps")
    for w in ("E", "Drandom", "AB", "C ", 0, "", " ", [1, 2, 3])                                          # test_invalid_weights
        @test_throws "Weight must be one of 'A', 'B', 'C', and 'D', got $(repr(w))." Lexeme("kneecaps"; weight = w)
    end
    @test_throws "Lexeme value cannot be empty." Lexeme("")                                               # test_empty
    @test_throws "Lexeme value must be a string, got Nothing." Lexeme(nothing)                            # test_non_string_values
end

DSE_PG && @testset "django postgres_tests test_search: searching (PostgreSQL)" begin
    port_block() do
        g = dse_grail()
        # SimpleSearchTest
        @test dse_ids(filter(DseLine; dialogue__search = "elbows")) == [g.verse1.id]                           # test_simple
        @test dse_ids(filter(DseLine; dialogue__search = "hearts")) == [g.verse2.id]                           # test_non_exact_match
        @test dse_ids(filter(DseLine; dialogue__search = "heart bowel")) == [g.verse2.id]                      # test_search_two_terms
        @test dse_ids(filter(DseLine; dialogue__search = "Robin killed")) == [g.verse0.id]                     # test_search_two_terms_with_partial_match
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("nostrils"; config = "simple"))) == [g.verse2.id]   # test_search_query_config
        create(DseLineSavedSearch; line = g.verse1, query = "hearts")                                   # test_search_with_F_expression
        match_ = create(DseLineSavedSearch; line = g.verse1, query = "elbows")
        for qe in (F(:query), SearchQuery(F(:query)))
            @test dse_ids(filter(DseLineSavedSearch; line__dialogue__search = qe)) == [match_.id]
        end
        # SearchVectorFieldTest
        update!(objects(DseLine); dialogue_search_vector = SearchVector(:dialogue))                           # test_existing_vector
        @test dse_ids(filter(DseLine; dialogue_search_vector = SearchQuery("Robin killed"))) == [g.verse0.id]
        @test dse_ids(filter(DseLine; dialogue_search_vector = SearchQuery("cadeaux"; config = "french"))) == [g.french.id]   # test_existing_vector_config_explicit
        @test length(collect(filter(annotate(DseLine; search = SearchVector(Value("This week everything is 10% off"))), search = "10 % off"))) == 9   # test_values_with_percent
        # MultipleFieldsTest
        @test dse_ids(filter(dse_sv(:scene__setting, :dialogue); search = "elbows")) == [g.verse1.id]        # test_simple_on_dialogue
        @test dse_ids(filter(dse_sv(:scene__setting, :dialogue); search = "Forest")) == dse_ids(g.verses)     # test_simple_on_scene
        @test dse_ids(filter(dse_sv(:scene__setting, :dialogue); search = "heart")) == [g.verse2.id]         # test_non_exact_match
        @test dse_ids(filter(dse_sv(:scene__setting, :dialogue); search = "heart forest")) == [g.verse2.id]  # test_search_two_terms
        @test dse_ids(filter(dse_sv(:character__name, :dialogue); search = "minstrel")) == dse_ids(g.verses) # test_terms_adjacent
        @test isempty(filter(dse_sv(:scene__setting, :dialogue); search = "minstrelbravely"))
        @test dse_ids(filter(dse_sv(:scene__setting, :dialogue); search = "bedemir")) ==                      # test_search_with_null
              dse_ids([g.bedemir0, g.bedemir1, g.crowd, g.witch, g.duck])
        @test dse_ids(filter(dse_sv(:id); search = string(g.crowd.id))) == [g.crowd.id]                      # test_search_with_non_text
        q = dse_sv(:dialogue)                                                                                # test_phrase_search
        @test isempty(filter(q; search = SearchQuery("burned body his away"; search_type = "phrase")))
        @test dse_ids(filter(q; search = SearchQuery("his body burned away"; search_type = "phrase"))) == [g.verse1.id]
        qf = dse_sv(:scene__setting, :dialogue; config = "french")                                           # test_phrase_search_with_config
        @test isempty(filter(qf; search = SearchQuery("cadeau beau un"; search_type = "phrase", config = "french")))
        @test dse_ids(filter(qf; search = SearchQuery("un beau cadeau"; search_type = "phrase", config = "french"))) == [g.french.id]
        @test dse_ids(filter(q; search = SearchQuery("Robin"; search_type = "raw"))) == dse_ids([g.verse0, g.verse1])   # test_raw_search
        @test dse_ids(filter(q; search = SearchQuery("Robin & !'Camelot'"; search_type = "raw"))) == [g.verse1.id]
        @test dse_ids(filter(dse_sv(:dialogue; config = "french"); search = SearchQuery("'cadeaux' & 'beaux'"; search_type = "raw", config = "french"))) ==
              [g.french.id]                                                                              # test_raw_search_with_config
        @test isempty(filter(q; search = SearchQuery("\"burned body\" \"split kneecaps\""; search_type = "websearch")))   # test_web_search
        @test dse_ids(filter(q; search = SearchQuery("\"body burned\" \"kneecaps split\" -\"nostrils\""; search_type = "websearch"))) == [g.verse1.id]
        @test dse_ids(filter(q; search = SearchQuery("\"Sir Robin\" (\"kneecaps\" OR \"Camelot\")"; search_type = "websearch"))) == dse_ids([g.verse0, g.verse1])
        @test isempty(filter(qf; search = SearchQuery("cadeau -beau"; search_type = "websearch", config = "french")))   # test_web_search_with_config
        @test dse_ids(filter(qf; search = SearchQuery("beau cadeau"; search_type = "websearch", config = "french"))) == [g.french.id]
        @test dse_ids(filter(qf; search = SearchQuery("cadeaux"; config = "french"))) == [g.french.id]    # test_config_query_explicit
        @test dse_ids(filter(qf; search = "cadeaux")) == [g.french.id]                                    # test_config_query_implicit
        qc = dse_sv(:scene__setting, :dialogue; config = F(:dialogue_config))
        @test dse_ids(filter(qc; search = SearchQuery("cadeaux"; config = F(:dialogue_config)))) == [g.french.id]   # test_config_from_field_explicit
        @test dse_ids(filter(qc; search = "cadeaux")) == [g.french.id]                                    # test_config_from_field_implicit
        # TestCombinations
        want = dse_ids([g.bedemir0, g.bedemir1, g.crowd, g.witch, g.duck])
        @test dse_ids(filter(annotate(DseLine; search = SearchVector(:scene__setting) + SearchVector(:character__name)), search = "bedemir")) == want   # test_vector_add
        @test dse_ids(filter(annotate(DseLine; search = SearchVector(:scene__setting) + SearchVector(:character__name) + SearchVector(:dialogue)),
                             search = "bedemir")) == want                                                # test_vector_add_multi
        @test dse_ids(filter(annotate(DseLine; search = SearchVector(:dialogue; config = "english") + SearchVector(:dialogue; config = "french")),   # test_combine_different_vector_configs
                             search = SearchQuery("cadeaux"; config = "french") | SearchQuery("nostrils"))) == dse_ids([g.french, g.verse2])
        q2 = dse_sv(:scene__setting, :dialogue)
        @test dse_ids(filter(q2; search = SearchQuery("bedemir") & SearchQuery("scales"))) == [g.bedemir0.id]   # test_query_and
        @test isempty(filter(q2; search = SearchQuery("bedemir") & SearchQuery("scales") & SearchQuery("nostrils")))   # test_query_multiple_and
        @test dse_ids(filter(q2; search = SearchQuery("shall") & SearchQuery("use") & SearchQuery("larger"))) == [g.bedemir0.id]
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("kneecaps") | SearchQuery("nostrils"))) == dse_ids([g.verse1, g.verse2])   # test_query_or
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("kneecaps") | SearchQuery("nostrils") | SearchQuery("Sir Robin"))) ==       # test_query_multiple_or
              dse_ids([g.verse0, g.verse1, g.verse2])
        @test dse_ids(filter(DseLine; character = g.minstrel, dialogue__search = ~SearchQuery("kneecaps"))) == dse_ids([g.verse0, g.verse2])   # test_query_invert
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("cadeau"; config = "french") | SearchQuery("nostrils"; config = "english"))) ==   # test_combine_different_configs
              dse_ids([g.french, g.verse2])
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("nostrils"; config = "simple") & SearchQuery("bowels"; config = "simple"))) ==   # test_combined_configs
              [g.verse2.id]
        @test dse_ids(filter(DseLine; dialogue__search = SearchQuery("burn:*"; search_type = "raw", config = "simple") |                       # test_combine_raw_phrase
                                                   SearchQuery("rode forth from Camelot"; search_type = "phrase"))) == dse_ids(g.verses)
        # TestRankingAndWeights
        mins = filter(DseLine; character = g.minstrel)
        @test [o.id for o in order_by(annotate(mins; rank = SearchRank(SearchVector(:dialogue), SearchQuery("brave sir robin"))), "rank")] ==   # test_ranking
              [g.verse2.id, g.verse1.id, g.verse0.id]
        @test [o.id for o in order_by(annotate(mins; rank = SearchRank("dialogue", "brave sir robin")), "rank")] ==                       # test_rank_passing_untyped_args
              [g.verse2.id, g.verse1.id, g.verse0.id]
        ws = filter(DseLine; scene = g.witch_scene)
        v = SearchVector(:dialogue; weight = "A") + SearchVector(:character__name; weight = "D")                                          # test_weights_in_vector
        @test [o.id for o in order_by(annotate(ws; rank = SearchRank(v, SearchQuery("witch"))), "-rank")[1:2]] == [g.crowd.id, g.witch.id]
        v = SearchVector(:dialogue; weight = "D") + SearchVector(:character__name; weight = "A")
        @test [o.id for o in order_by(annotate(ws; rank = SearchRank(v, SearchQuery("witch"))), "-rank")[1:2]] == [g.witch.id, g.crowd.id]
        @test [o.id for o in order_by(annotate(ws; rank = SearchRank(v, SearchQuery("witch"); weights = [1.0, 0.0, 0.0, 0.5])), "-rank")[1:2]] ==   # test_ranked_custom_weights
              [g.crowd.id, g.witch.id]
        @test dse_ids(filter(annotate(mins; rank = SearchRank(SearchVector(:dialogue), SearchQuery("brave sir robin"))), rank__gt = 0.3)) ==   # test_ranking_chaining
              [g.verse0.id]
        nd = create(DseLine; scene = g.robin, character = g.minstrel,                                                                          # test_cover_density_ranking
                    dialogue = "Bravely taking to his feet, he beat a very brave retreat. A brave retreat brave Sir Robin.")
        @test [o.id for o in order_by(annotate(filter(DseLine; character = g.minstrel); rank = SearchRank(SearchVector(:dialogue), SearchQuery("brave robin"); cover_density = true)),
                                      "rank", "-pk")] == [g.verse2.id, nd.id, g.verse1.id, g.verse0.id]
        delete!(nd)
        short = create(DseLine; scene = g.robin, character = g.minstrel, dialogue = "A brave retreat brave Sir Robin.")
        for norm in (2, 2 | 8)                                                                                                           # test_ranking_with_normalization / _masked_normalization
            @test [o.id for o in order_by(annotate(filter(DseLine; character = g.minstrel); rank = SearchRank(SearchVector(:dialogue), SearchQuery("brave sir robin"); normalization = norm)),
                                          "rank")] == [g.verse2.id, g.verse1.id, g.verse0.id, short.id]
        end
        delete!(short)
        # SearchHeadlineTests
        hl(e) = get(annotate(DseLine; headline = e); pk = g.verse0.pk).headline
        @test hl(SearchHeadline(F(:dialogue), SearchQuery("brave sir robin"); config = SearchConfig("english"))) ==                       # test_headline
              "<b>Robin</b>. He was not at all afraid to be killed in nasty ways. <b>Brave</b>, <b>brave</b>, <b>brave</b>, <b>brave</b> <b>Sir</b> <b>Robin</b>"
        @test hl(SearchHeadline("dialogue", "killed"; config = "english")) ==                                                             # test_headline_untyped_args
              "Robin. He was not at all afraid to be <b>killed</b> in nasty ways. Brave, brave, brave, brave Sir Robin"
        @test get(annotate(DseLine; headline = SearchHeadline("dialogue", SearchQuery("cadeaux"; config = "french"); config = "french")); pk = g.french.pk).headline ==   # test_headline_with_config
              "Oh. Un beau <b>cadeau</b>. Oui oui."
        @test get(annotate(DseLine; headline = SearchHeadline("dialogue", SearchQuery("cadeaux"; config = F(:dialogue_config)); config = F(:dialogue_config))); pk = g.french.pk).headline ==
              "Oh. Un beau <b>cadeau</b>. Oui oui."                                                                                       # test_headline_with_config_from_field
        @test hl(SearchHeadline("dialogue", "brave sir robin"; start_sel = "<span>", stop_sel = "</span>")) ==                           # test_headline_separator_options
              "<span>Robin</span>. He was not at all afraid to be killed in nasty ways. <span>Brave</span>, <span>brave</span>, <span>brave</span>, <span>brave</span> <span>Sir</span> <span>Robin</span>"
        @test occursin("<b>Bravely</b> bold <b>Sir</b> <b>Robin</b>, rode forth from Camelot. He was not afraid to die, o ",              # test_headline_highlight_all_option
                       hl(SearchHeadline("dialogue", SearchQuery("brave sir robin"; config = "english"); highlight_all = true)))
        @test hl(SearchHeadline("dialogue", SearchQuery("Camelot"; config = "english"); short_word = 5, min_words = 8)) ==                # test_headline_short_word_option
              "<b>Camelot</b>. He was not afraid to die, o Brave Sir Robin. He was not at all afraid"
        @test hl(SearchHeadline("dialogue", SearchQuery("brave sir robin"; config = "english"); fragment_delimiter = "...<br>",          # test_headline_fragments_words_options
                                max_fragments = 4, max_words = 3, min_words = 1)) ==
              "<b>Sir</b> <b>Robin</b>, rode...<br><b>Brave</b> <b>Sir</b> <b>Robin</b>...<br><b>Brave</b>, <b>brave</b>, <b>brave</b>...<br><b>brave</b> <b>Sir</b> <b>Robin</b>"
        # TestLexemes
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("bedemir") & Lexeme("scales")))) == [g.bedemir0.id]                         # test_and
        @test isempty(filter(q2; search = SearchQuery(Lexeme("bedemir") & Lexeme("scales") & Lexeme("nostrils"))))                      # test_multiple_and
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("shall") & Lexeme("use") & Lexeme("larger")))) == [g.bedemir0.id]
        @test dse_ids(filter(q; search = SearchQuery(Lexeme("kneecaps") | Lexeme("nostrils")))) == dse_ids([g.verse1, g.verse2])        # test_or
        @test dse_ids(filter(q; search = SearchQuery(Lexeme("kneecaps") | Lexeme("nostrils") | Lexeme("Sir Robin")))) ==                # test_multiple_or
              dse_ids([g.verse0, g.verse1, g.verse2])
        @test dse_ids(filter(q; search = SearchQuery(Lexeme("shall") & Lexeme("use") & Lexeme("larger") | Lexeme("nostrils")))) ==      # test_advanced
              dse_ids([g.bedemir0, g.verse2])
        @test dse_ids(filter(q; character = g.minstrel, search = SearchQuery(~Lexeme("kneecaps")))) == dse_ids([g.verse0, g.verse2])    # test_invert
        @test dse_ids(filter(q; search = SearchQuery(~(Lexeme("shall") & Lexeme("use") & Lexeme("larger") | Lexeme("nostrils"))))) ==   # test_advanced_invert
              dse_ids(exclude(DseLine; id__in = [g.bedemir0.id, g.verse2.id]))
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("hear"; prefix = true)))) == [g.verse2.id]                                 # test_prefix_searching
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("Robi"; prefix = true, invert = true)))) ==                                # test_inverse_prefix_searching
              dse_ids([g.verse2, g.bedemir0, g.bedemir1, g.french, g.crowd, g.witch, g.duck])
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("Robi"; prefix = true) & Lexeme("Camel"; prefix = true)))) == [g.verse0.id]   # test_lexemes_multiple_and
        @test dse_ids(filter(q2; search = SearchQuery(Lexeme("kneecap"; prefix = true) | Lexeme("afrai"; prefix = true)))) ==           # test_lexemes_multiple_or
              dse_ids([g.verse0, g.verse1])
        @test dse_ids(filter(qf; search = SearchQuery(Lexeme("cadeaux"); config = "french"))) == [g.french.id]                          # test_config_query_explicit
        @test dse_ids(filter(qf; search = Lexeme("cadeaux"))) == [g.french.id]                                                         # test_config_query_implicit
        @test dse_ids(filter(qc; search = SearchQuery(Lexeme("cadeaux"); config = F(:dialogue_config)))) == [g.french.id]             # test_config_from_field_explicit
        @test dse_ids(filter(qc; search = Lexeme("cadeaux"))) == [g.french.id]                                                         # test_config_from_field_implicit
        # test_single_coalesce_expression: one COALESCE per field (compile_expr(SearchVector)); test_non_exact_match's
        # check_default_text_search_config: the throwaway database uses English, PostgreSQL's default
    end
end
