# Django's utils_tests test_text.py, ported (#227): get_text_list, smart_split, Truncator (truncate_chars and
# truncate_words, with html: Python's HTMLParser's way), wrap, normalize_newlines, phone2numeric, slugify,
# unescape_string_literal and get_valid_filename.
# julia --project=test test/django_utils_text.jl   (see setup.jl; no database needed)
#
# Not translated: lazystr, the Arabic get_text_list (Juango ships a German catalog only), trim_value (an internal helper
# of Django's), compress_sequence (Juango's gzip_stream: the GZipMiddleware tests), format_lazy (Juango's lazy text has
# no format()).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dut_chars(t, n, tr = nothing; html = false) = Juango.truncate_chars(t, n; truncate = tr, html)
dut_words(t, n, tr = nothing; html = false) = Juango.truncate_words(t, n; truncate = tr, html)

@testset "django utils_tests test_text: TestUtilsText" begin
    # test_get_text_list
    @test Juango.get_text_list(["a", "b", "c", "d"]) == "a, b, c or d"
    @test Juango.get_text_list(["a", "b", "c"], "and") == "a, b and c"
    @test Juango.get_text_list(["a", "b"], "and") == "a and b"
    @test Juango.get_text_list(["a"]) == "a"
    @test Juango.get_text_list(String[]) == ""
    # test_smart_split
    for (t, expected) in (("This is \"a person\" test.", ["This", "is", "\"a person\"", "test."]),
                          ("This is \"a person's\" test.", ["This", "is", "\"a person's\"", "test."]),
                          ("This is \"a person\\\"s\" test.", ["This", "is", "\"a person\\\"s\"", "test."]),
                          ("\"a 'one", ["\"a", "'one"]), ("all friends' tests", ["all", "friends'", "tests"]),
                          ("url search_page words=\"something else\"", ["url", "search_page", "words=\"something else\""]),
                          ("url search_page words='something else'", ["url", "search_page", "words='something else'"]),
                          ("url search_page words \"something else\"", ["url", "search_page", "words", "\"something else\""]),
                          ("url search_page words-\"something else\"", ["url", "search_page", "words-\"something else\""]),
                          ("url search_page words=hello", ["url", "search_page", "words=hello"]),
                          ("url search_page words=\"something else", ["url", "search_page", "words=\"something", "else"]),
                          ("cut:','|cut:' '", ["cut:','|cut:' '"]), ("a b c d", ["a", "b", "c", "d"]))
        @test Juango.smart_split(t) == expected
    end
    # test_truncate_chars
    t = "The quick brown fox jumped over the lazy dog."
    @test dut_chars(t, 100) == t
    @test dut_chars(t, 21) == "The quick brown fox …"
    @test dut_chars(t, 23, ".....") == "The quick brown fo....."
    @test dut_chars(t, 4, ".....") == "....."
    nfc, nfd = "o\u00fco\u00fco\u00fco\u00fc", "ou\u0308ou\u0308ou\u0308ou\u0308"
    @test dut_chars(nfc, 8) == "oüoüoüoü" && dut_chars(nfd, 8) == "oüoüoüoü"
    @test dut_chars(nfc, 3) == "oü…" && dut_chars(nfd, 3) == "oü…"
    t = "-B\u030aB\u030a----8"
    @test dut_chars(t, 3) == "-B\u030a…"
    @test dut_chars(t, 5) == "-B\u030aB\u030a-…"
    @test dut_chars(t, 8) == "-B\u030aB\u030a----8"
    @test dut_chars("-----", 4, "B\u030a") == "---B\u030a"
    @test dut_chars("-----", 5, "B\u030a") == "-----"
    @test dut_chars("asdf", 1, "...") == "..."
    @test dut_chars("The quick brown fox", 10) == "The quick…"
    # test_truncate_chars_html
    t = "<p id=\"par\"><strong><em>The quick brown fox jumped over the lazy dog.</em></strong></p>"
    @test dut_chars(t, 80; html = true) == t
    @test dut_chars(t, 46; html = true) == t
    @test dut_chars(t, 45; html = true) == "<p id=\"par\"><strong><em>The quick brown fox jumped over the lazy dog…</em></strong></p>"
    @test dut_chars(t, 10; html = true) == "<p id=\"par\"><strong><em>The quick…</em></strong></p>"
    @test dut_chars(t, 1; html = true) == "<p id=\"par\"><strong><em>…</em></strong></p>"
    @test dut_chars(t, 0; html = true) == "" && dut_chars(t, -1; html = true) == ""
    @test dut_chars(t, 10, "...."; html = true) == "<p id=\"par\"><strong><em>The qu....</em></strong></p>"
    @test dut_chars(t, 10, ""; html = true) == "<p id=\"par\"><strong><em>The quick </em></strong></p>"
    @test dut_chars("foo</p>", 5; html = true) == "foo</p>"
    # test_truncate_chars_html_with_newline_inside_tag
    t = "<p>The quick <a href=\"xyz.html\"\n id=\"mylink\">brown fox</a> jumped over the lazy dog.</p>"
    @test dut_chars(t, 15; html = true) == "<p>The quick <a href=\"xyz.html\"\n id=\"mylink\">brow…</a></p>"
    @test dut_chars(t, 3; html = true) == "<p>Th…</p>"
    # test_truncate_chars_html_with_void_elements
    @test dut_chars("<br/>The <hr />quick brown fox jumped over the lazy dog.", 16; html = true) == "<br/>The <hr />quick brown…"
    t = "<br>The <hr/>quick <em>brown fox</em> jumped over the lazy dog."
    @test dut_chars(t, 16; html = true) == "<br>The <hr/>quick <em>brown…</em>"
    @test dut_chars(t, 6; html = true) == "<br>The <hr/>q…"
    @test dut_chars(t, 5; html = true) == "<br>The <hr/>…"
    @test dut_chars(t, 4; html = true) == "<br>The…"
    @test dut_chars(t, 3; html = true) == "<br>Th…"
    # test_truncate_chars_html_with_html_entities
    t = "<i>Buenos d&iacute;as! &#x00bf;C&oacute;mo est&aacute;?</i>"
    @test dut_chars(t, 40; html = true) == "<i>Buenos días! ¿Cómo está?</i>"
    @test dut_chars(t, 12; html = true) == "<i>Buenos días…</i>"
    @test dut_chars(t, 24; html = true) == "<i>Buenos días! ¿Cómo está…</i>"
    @test dut_chars("<p>I &lt;3 python, what about you?</p>", 16; html = true) == "<p>I &lt;3 python, wh…</p>"
    # test_truncate_chars_html_with_misnested_tags
    @test dut_chars("<a><b><c></b>XXXX", 2, ""; html = true) == "<a><b><c></b>XX</c></b></a>"
    # test_truncate_words
    t = "The quick brown fox jumped over the lazy dog."
    @test dut_words(t, 10) == t
    @test dut_words(t, 4) == "The quick brown fox…"
    @test dut_words(t, 4, "[snip]") == "The quick brown fox[snip]"
    @test dut_words(t, 0) == "" && dut_words(t, -1) == ""
    # test_truncate_html_words
    t = "<p id=\"par\"><strong><em>The quick brown fox jumped over the lazy dog.</em></strong></p>"
    @test dut_words(t, 10; html = true) == t
    @test dut_words(t, 4; html = true) == "<p id=\"par\"><strong><em>The quick brown fox…</em></strong></p>"
    @test dut_words(t, 0; html = true) == ""
    @test dut_words(t, 4, "...."; html = true) == "<p id=\"par\"><strong><em>The quick brown fox....</em></strong></p>"
    @test dut_words(t, 4, ""; html = true) == "<p id=\"par\"><strong><em>The quick brown fox</em></strong></p>"
    @test dut_words("<p>The  quick \t brown fox jumped over the lazy dog.</p>", 4; html = true) == "<p>The quick brown fox…</p>"
    t = "<p>The quick <a href=\"xyz.html\"\n id=\"mylink\">brown fox</a> jumped over the lazy dog.</p>"
    @test dut_words(t, 3; html = true) == "<p>The quick <a href=\"xyz.html\"\n id=\"mylink\">brown…</a></p>"
    @test dut_words(t, 1; html = true) == "<p>The…</p>"
    @test dut_words("<br/>The <hr />quick brown fox jumped over the lazy dog.", 3; html = true) == "<br/>The <hr />quick brown…"
    @test dut_words("<br>The <hr/>quick <em>brown fox</em> jumped over the lazy dog.", 3; html = true) == "<br>The <hr/>quick <em>brown…</em>"
    @test dut_words("<i>Buenos d&iacute;as! &#x00bf;C&oacute;mo est&aacute;?</i>", 3; html = true) == "<i>Buenos días! ¿Cómo…</i>"
    @test dut_words("<p>I &lt;3 python, what about you?</p>", 3; html = true) == "<p>I &lt;3 python,…</p>"
    @test dut_words("foo</p>", 3; html = true) == "foo</p>"
    @test dut_words("<"^60_000, 1; html = true) == "&lt;…"
    @test dut_words("<i style=\"margin: 5%; font: *;\">Hello, my dear lady!</i>", 3; html = true) == "<i style=\"margin: 5%; font: *;\">Hello, my dear…</i>"
    @test dut_words("<p data-x=\"א\">Hello, my dear lady!</p>", 3; html = true) == "<p data-x=\"א\">Hello, my dear…</p>"
    t = "hello >< world"
    @test dut_words(t, 1; html = true) == "hello…"
    @test dut_words(t, 2; html = true) == "hello &gt;…"
    @test dut_words(t, 3; html = true) == "hello &gt;&lt;…"
    @test dut_words(t, 4; html = true) == "hello &gt;&lt; world"
    # test_wrap
    digits = "1234 67 9"
    @test Juango.wrap_text(digits, 100) == "1234 67 9"
    @test Juango.wrap_text(digits, 9) == "1234 67 9"
    @test Juango.wrap_text(digits, 8) == "1234 67\n9"
    @test Juango.wrap_text("short\na long line", 7) == "short\na long\nline"
    @test Juango.wrap_text("do-not-break-long-words please? ok", 8) == "do-not-break-long-words\nplease?\nok"
    long_word = "l" * "o"^20 * "ng"
    @test Juango.wrap_text(long_word, 20) == long_word
    @test Juango.wrap_text("a $long_word word", 10) == "a\n$long_word\nword"
    # test_normalize_newlines
    @test Juango.normalize_newlines("abc\ndef\rghi\r\n") == "abc\ndef\nghi\n"
    @test Juango.normalize_newlines("\n\r\r\n\r") == "\n\n\n\n"
    @test Juango.normalize_newlines("abcdefghi") == "abcdefghi" && Juango.normalize_newlines("") == ""
    # test_phone2numeric
    @test string(Juango.FILTERS["phone2numeric"].fn("0800 flowers", nothing)) == "0800 3569377"
    # test_slugify
    for (value, output, uni) in (("Hello, World!", "hello-world", false), ("spam & eggs", "spam-eggs", false),
                                 (" multiple---dash and  space ", "multiple-dash-and-space", false),
                                 ("\t whitespace-in-value \n", "whitespace-in-value", false), ("underscore_in-value", "underscore_in-value", false),
                                 ("__strip__underscore-value___", "strip__underscore-value", false), ("--strip-dash-value---", "strip-dash-value", false),
                                 ("__strip-mixed-value---", "strip-mixed-value", false), ("_ -strip-mixed-value _-", "strip-mixed-value", false),
                                 ("spam & ıçüş", "spam-ıçüş", true), ("foo ıç bar", "foo-ıç-bar", true), ("    foo ıç bar", "foo-ıç-bar", true),
                                 ("你好", "你好", true), ("İstanbul", "istanbul", true))
        @test Juango.slugify(value; allow_unicode = uni) == output
    end
    # (Django's default drops the other non-ASCII letters: #310)
    @test_broken Juango.slugify("spam & ıçüş") == "spam-cus"
    @test_broken Juango.slugify("你好") == ""
    # test_unescape_string_literal / _invalid_value
    for (value, output) in (("\"abc\"", "abc"), ("'abc'", "abc"), ("\"a \"bc\"\"", "a \"bc\""), ("''ab' c'", "'ab' c"))
        @test Juango.unescape_string_literal(value) == output
    end
    for (item, r) in (("", "''"), ("abc", "'abc'"), ("'abc\"", "'\\'abc\"'"))
        @test_throws "Not a string literal: $r" Juango.unescape_string_literal(item)
    end
    # test_get_valid_filename
    @test Juango.get_valid_filename("^&'@{}[],\$=!-#()%+~_123.txt") == "-_123.txt"
    @test_throws "Could not derive file name from '???'" Juango.get_valid_filename("???")
    @test_throws "Could not derive file name from '\$.\$.\$'" Juango.get_valid_filename("\$.\$.\$")
end
