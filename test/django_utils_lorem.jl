# Django's utils_tests test_lorem_ipsum.py, ported (#227): the lorem ipsum words, sentences and paragraphs ({% lorem %}'s).
# julia --project=test test/django_utils_lorem.jl   (see setup.jl; no database needed)
#
# Not translated: the tests that mock Python's random module (the phrase and sample counts).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_lorem_ipsum: LoremIpsumTests" begin
    # test_negative_words / test_same_or_less_common_words / test_common_words_in_string / test_more_words_than_common
    @test Juango.lorem_words(-5, true) == "lorem ipsum dolor sit amet consectetur adipisicing elit sed do eiusmod tempor incididunt ut"
    @test Juango.lorem_words(7, true) == "lorem ipsum dolor sit amet consectetur adipisicing"
    @test startswith(Juango.lorem_words(25, true), "lorem ipsum dolor sit amet consectetur adipisicing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua")
    @test length(split(Juango.lorem_words(25, true))) == 25
    @test length(split(Juango.lorem_words(500, true))) == 500                        # (test_common_large_number_of_words)
    # test_not_common_words: different random words
    w = split(Juango.lorem_words(2, false))
    @test length(w) == 2 && w[1] != w[2] && all(x -> x in Juango.LOREM_WORDS, w)
    # test_sentence_starts_with_capital / test_sentence_ending
    for _ in 1:20
        s = Juango.lorem_sentence()
        @test isuppercase(s[1]) && s[end] in "?."
    end
    # test_paragraphs
    @test Juango.lorem_paragraphs(1, true) == ["Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."]
    @test Juango.lorem_paragraphs(1, false) != Juango.lorem_paragraphs(1, true)        # (test_paragraphs_not_common)
end
