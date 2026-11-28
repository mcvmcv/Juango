# Django's utils_tests test_html.py, ported (#227): escape, format_html, linebreaks, strip_tags (Python's HTMLParser's
# way), strip_spaces_between_tags, escapejs, json_script, smart_urlquote, conditional_escape and urlize.
# julia --project=test test/django_utils_html.jl   (see setup.jl; no database needed)
#
# Juango's are functions (Juango.strip_tags, ...) and template filters; lazystr has no counterpart. Not translated:
# html_safe (a Python class decorator: Juango's __html__ is a method on a type), json_script's custom encoder class, and
# the URLIZE_ASSUME_HTTPS deprecation warning (Juango assumes https, Django 2028's default). Suspicious input is a
# BadRequest (Django's SuspiciousOperation is answered with a 400 too).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

duh_urlize(v) = Juango.urlize_text(v; nofollow = false)
duh_filter(name, v, args...) = (f = Juango.FILTERS[name]; a = isempty(args) ? nothing : args[1];
                                string(f.needs_autoescape ? f.fn(v, a, true) : f.fn(v, a)))

@testset "django utils_tests test_html: TestUtilsHtml" begin
    # test_escape
    for (value, output) in (("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&#x27;"))
        for pat in ("%s", "asdf%sfdsa", "%s1", "1%sb")
            @test Juango.escape_html(replace(pat, "%s" => value)) == replace(pat, "%s" => output)
        end
        @test Juango.escape_html(value^2) == output^2
    end
    @test Juango.escape_html("<&") == "&lt;&amp;"
    # test_format_html / test_format_html_join_*
    @test string(format_html("{} {} {third} {fourth}", "< Dangerous >", mark_safe("<b>safe</b>");
                             third = "< dangerous again", fourth = mark_safe("<i>safe again</i>"))) ==
          "&lt; Dangerous &gt; <b>safe</b> &lt; dangerous again <i>safe again</i>"
    @test_throws "args or kwargs must be provided." format_html("<i>Adam</i>")
    @test string(Juango.format_html_join("\n", "<li>{}) {}</li>", [(1, "Emma"), (2, "Matilda")])) == "<li>1) Emma</li>\n<li>2) Matilda</li>"
    @test string(Juango.format_html_join("\n", "<li>{id}) {text}</li>", [Dict("id" => 1, "text" => "Emma"), Dict("id" => 2, "text" => "Matilda")])) ==
          "<li>1) Emma</li>\n<li>2) Matilda</li>"
    # test_linebreaks
    for (value, output) in (("para1\n\npara2\r\rpara3", "<p>para1</p>\n\n<p>para2</p>\n\n<p>para3</p>"),
                            ("para1\nsub1\rsub2\n\npara2", "<p>para1<br>sub1<br>sub2</p>\n\n<p>para2</p>"),
                            ("para1\r\n\r\npara2\rsub1\r\rpara4", "<p>para1</p>\n\n<p>para2<br>sub1</p>\n\n<p>para4</p>"),
                            ("para1\tmore\n\npara2", "<p>para1\tmore</p>\n\n<p>para2</p>"))
        @test duh_filter("linebreaks", value) == output
    end
    # test_strip_tags (Python 3.14's HTMLParser: the fixed results)
    for (value, output) in (("<p>See: &#39;&eacute; is an apostrophe followed by e acute</p>", "See: &#39;&eacute; is an apostrophe followed by e acute"),
                            ("<p>See: &#x27;&eacute; is an apostrophe followed by e acute</p>", "See: &#x27;&eacute; is an apostrophe followed by e acute"),
                            ("<adf>a", "a"), ("</adf>a", "a"), ("<asdf><asdf>e", "e"), ("hi, <f x", "hi, <f x"),
                            ("234<235, right?", "234<235, right?"), ("a4<a5 right?", "a4<a5 right?"), ("b7>b2!", "b7>b2!"),
                            ("</fe", "</fe"), ("<x>b<y>", "b"), ("a<p onclick=\"alert('<test>')\">b</p>c", "abc"),
                            ("a<p a >b</p>c", "abc"), ("d<a:b c:d>e</p>f", "def"),
                            ("<strong>foo</strong><a href=\"http://example.com\">bar</a>", "foobar"),
                            ("&gotcha&#;<>", "&gotcha&#;<>"), ("<sc<!-- -->ript>test<<!-- -->/script>", "ript>test"),
                            ("<script>alert()</script>&h", "alert()&h;"), ("><!" * "&"^16000 * "D", ">"),
                            ("X<<<<br>br>br>br>X", "XX"), ("<"^50 * "a>"^50, ""), (">" * "<a"^500 * "a", ">"),
                            ("<a"^49 * "a"^951, "<a"^49 * "a"^951), ("<" * "a"^1002, "<" * "a"^1002))
        @test Juango.strip_tags(value) == output
        @test duh_filter("striptags", value) == output
    end
    # test_strip_tags_suspicious_operation_max_depth / _large_open_tags
    @test_throws Juango.BadRequest Juango.strip_tags("<"^51 * "a>"^51)
    for value in (">" * "<a"^501, "<a"^50 * "a"^950)
        @test_throws Juango.BadRequest Juango.strip_tags(value)
    end
    # test_strip_tags_files: longer content, quickly
    for name in ("strip_tags1.html", "strip_tags2.txt")
        content = read(joinpath(@__DIR__, "utils_fixtures", name), String)
        t = @elapsed stripped = Juango.strip_tags(content)
        @test t < 1
        @test occursin("Test string that has not been stripped.", stripped) && !occursin('<', stripped)
    end
    # test_strip_spaces_between_tags
    for value in (" <adf>", "<adf> ", " </adf> ", " <f> x</f>")
        @test Juango.strip_spaces_between_tags(value) == value
    end
    for (value, output) in (("<d> </d>", "<d></d>"), ("<p>hello </p>\n<p> world</p>", "<p>hello </p><p> world</p>"),
                            ("\n<p>\t</p>\n<p> </p>\n", "\n<p></p><p></p>\n"))
        @test Juango.strip_spaces_between_tags(value) == output
    end
    # test_escapejs
    for (value, output) in (("\"double quotes\" and 'single quotes'", "\\u0022double quotes\\u0022 and \\u0027single quotes\\u0027"),
                            ("\\ : backslashes, too", "\\u005C : backslashes, too"),
                            ("and lots of whitespace: \r\n\t\v\f\b", "and lots of whitespace: \\u000D\\u000A\\u0009\\u000B\\u000C\\u0008"),
                            ("<script>and this</script>", "\\u003Cscript\\u003Eand this\\u003C/script\\u003E"),
                            ("paragraph separator: and line separator: ", "paragraph separator:\\u2029and line separator:\\u2028"),
                            ("`", "\\u0060"), ("\u007f", "\\u007F"), ("\u0080", "\\u0080"), ("\u009f", "\\u009F"))
        @test duh_filter("escapejs", value) == output
    end
    # test_json_script / test_json_script_without_id
    @test duh_filter("json_script", "&<>", "test_id") == "<script id=\"test_id\" type=\"application/json\">\"\\u0026\\u003C\\u003E\"</script>"
    @test duh_filter("json_script", Dict("a" => "<script>test&ing</script>"), "test_id") ==
          "<script id=\"test_id\" type=\"application/json\">{\"a\": \"\\u003Cscript\\u003Etest\\u0026ing\\u003C/script\\u003E\"}</script>"
    @test duh_filter("json_script", Dict("key" => "value")) == "<script type=\"application/json\">{\"key\": \"value\"}</script>"
    # test_smart_urlquote
    for (value, output) in (("http://öäü.com/", "http://%C3%B6%C3%A4%C3%BC.com/"), ("https://faß.example.com", "https://fa%C3%9F.example.com"),
                            ("http://öäü.com/öäü/", "http://%C3%B6%C3%A4%C3%BC.com/%C3%B6%C3%A4%C3%BC/"),
                            ("https://މިހާރު.com", "https://%DE%89%DE%A8%DE%80%DE%A7%DE%83%DE%AA.com"),
                            ("http://👓.ws", "http://%F0%9F%91%93.ws"),
                            ("http://xn--iny-zx5a.com/idna2003", "http://xn--iny-zx5a.com/idna2003"),
                            ("http://xn--fa-hia.com/idna2008", "http://xn--fa-hia.com/idna2008"),
                            ("http://example.com/path/öäü/", "http://example.com/path/%C3%B6%C3%A4%C3%BC/"),
                            ("http://example.com/%C3%B6/ä/", "http://example.com/%C3%B6/%C3%A4/"),
                            ("http://example.com/?x=1&y=2+3&z=", "http://example.com/?x=1&y=2+3&z="),
                            ("http://example.com/?x=<>\"'", "http://example.com/?x=%3C%3E%22%27"),
                            ("http://example.com/?q=http://example.com/?x=1%26q=django",
                             "http://example.com/?q=http%3A%2F%2Fexample.com%2F%3Fx%3D1%26q%3Ddjango"),
                            ("http://example.com/?q=http%3A%2F%2Fexample.com%2F%3Fx%3D1%26q%3Ddjango",
                             "http://example.com/?q=http%3A%2F%2Fexample.com%2F%3Fx%3D1%26q%3Ddjango"),
                            ("http://.www.f oo.bar/", "http://.www.f%20oo.bar/"), ("http://example.com\">", "http://example.com%22%3E"),
                            ("http://10.22.1.1/", "http://10.22.1.1/"), ("http://[fd00::1]/", "http://[fd00::1]/"))
        @test Juango.smart_urlquote(value) == output
    end
    # test_conditional_escape
    s = "<h1>interop</h1>"
    @test Juango.conditional_escape(s) == "&lt;h1&gt;interop&lt;/h1&gt;"
    @test Juango.conditional_escape(mark_safe(s)) == s
    # test_urlize
    for (value, output) in (("Search for google.com/?q=! and see.", "Search for <a href=\"https://google.com/?q=\">google.com/?q=</a>! and see."),
                            ("Search for google.com/?q=1&lt! and see.", "Search for <a href=\"https://google.com/?q=1%3C\">google.com/?q=1&lt</a>! and see."),
                            ("http://www.foo.bar/", "<a href=\"http://www.foo.bar/\">http://www.foo.bar/</a>"),
                            ("Look on www.نامه‌ای.com.", "Look on <a href=\"https://www.%D9%86%D8%A7%D9%85%D9%87%E2%80%8C%D8%A7%DB%8C.com\">www.نامه‌ای.com</a>."),
                            ("foo@example.com", "<a href=\"mailto:foo@example.com\">foo@example.com</a>"),
                            ("test@" * "한.글."^15 * "aaa", "<a href=\"mailto:test@" * "%ED%95%9C.%EA%B8%80."^15 * "aaa\">test@" * "한.글."^15 * "aaa</a>"),
                            ("yes+this=is&a%valid!email@example.com", "<a href=\"mailto:yes%2Bthis%3Dis%26a%25valid%21email@example.com\">yes+this=is&a%valid!email@example.com</a>"),
                            ("foo@faß.example.com", "<a href=\"mailto:foo@fa%C3%9F.example.com\">foo@faß.example.com</a>"),
                            ("idna-2008@މިހާރު.example.mv", "<a href=\"mailto:idna-2008@%DE%89%DE%A8%DE%80%DE%A7%DE%83%DE%AA.example.mv\">idna-2008@މިހާރު.example.mv</a>"),
                            ("host.djangoproject.com", "<a href=\"https://host.djangoproject.com\">host.djangoproject.com</a>"))
        @test string(duh_urlize(value)) == output
    end
    # test_urlize_unchanged_inputs (and the catastrophic-backtracking ones, quickly)
    for value in ("a" * "@a"^50000 * "a", "a@" * "한.글."^1_000_000 * "a", "http://" * "한.글."^1_000_000 * "com",
                  "www." * "한.글."^1_000_000 * "com", "a" * "."^1000000 * "a", "foo@", "@foo.com", "foo@.example.com", "foo@localhost",
                  "foo@localhost.", "test@example?;+!.com", "email me@example.com,then I'll respond",
                  "[a link](https://www.djangoproject.com/)", "("^100_000 * ":" * ")"^100_000, "("^100_000 * "&:" * ")"^100_000,
                  "(["^100_000 * ":" * "])"^100_000, "[("^100_000 * ":" * ")]"^100_000, "([["^100_000 * ":" * "]])"^100_000,
                  "&:" * ";"^100_000, "&.;"^100_000, ".;"^100_000, "&" * ";:"^100_000)
        t = @elapsed r = string(duh_urlize(value))
        @test r == value
        @test t < 5
    end
end
