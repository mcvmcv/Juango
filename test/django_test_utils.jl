# Django's test_utils tests, ported (#227, part): tests/test_utils (HTMLEqualTests, InHTMLTests, JSONEqualTests,
# AssertNumQueriesTests, AssertQuerySetEqualTests), against Juango's assertions: assert_html_equal,
# assert_in_html, assert_not_in_html, assert_json_equal, assert_num_queries, assert_queryset_equal, and
# `Juango.parse_html` (a vector of nodes: HtmlElement and text).
# julia --project=test test/django_test_utils.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DtuPerson
    name = CharField(max_length = 100)
    Meta(table = "dtu_person")
end
@model struct DtuCar
    name = CharField(max_length = 100)
    Meta(table = "dtu_car")
end
@model struct DtuPossessedCar
    car = ForeignKey(DtuCar, on_delete = :CASCADE)
    belongs_to = ForeignKey(DtuPerson, on_delete = :CASCADE, related_name = :possessed)
    Meta(table = "dtu_possessed_car")
end
redirect_stdout(devnull) do
    ms = [DtuPerson, DtuCar, DtuPossessedCar]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

const PH = Juango.parse_html
canon(s) = Juango.html_canonical(PH(s))
heq(a, b) = try assert_html_equal(a, b) catch e; e isa AssertionError ? false : rethrow() end
hne(a, b) = try assert_html_not_equal(a, b) catch e; e isa AssertionError ? false : rethrow() end
amsg(f) = try f(); "no error" catch e; e isa AssertionError ? e.msg : rethrow() end
hcount(hay, needle) = Juango.count_html(PH(needle), PH(hay))

@testset "django test_utils: HTMLEqualTests" begin
    # test_html_parser
    d = PH("<div><p>Hello</p></div>")
    @test length(d) == 1 && length(d[1].children) == 1 && d[1].children[1].tag == "p" && d[1].children[1].children == ["Hello"]
    PH("<p>"); PH("<p attr>")
    d = PH("<p>foo")
    @test length(d) == 1 && d[1].tag == "p" && d[1].children == ["foo"]
    # test_parse_html_in_script: a script's content is text
    PH("<script>var a = \"<p\" + \">\";</script>")
    d = PH("<script><p>foo</p> '</scr'+'ipt>' <span>bar</span></script>")
    @test length(d) == 1 && d[1].children == ["<p>foo</p> '</scr'+'ipt>' <span>bar</span>"]
    # test_void_elements
    for tag in Juango.VOID_ELEMENTS, form in ("<$tag>", "<$tag />")
        d = PH("<p>Hello $form world</p>")[1]
        @test length(d.children) == 3 && d.children[1] == "Hello" && d.children[2].tag == tag && d.children[3] == "world"
    end
    # test_simple_equal_html
    for (a, b) in [("", ""), ("<p></p>", "<p></p>"), ("<p></p>", " <p> </p> "), ("<div><p>Hello</p></div>", "<div><p>Hello</p></div>"),
                   ("<div><p>Hello</p></div>", "<div> <p>Hello</p> </div>"), ("<div>\n<p>Hello</p></div>", "<div><p>Hello</p></div>\n"),
                   ("<div><p>Hello\nWorld !</p></div>", "<div><p>Hello World\n!</p></div>"), ("<p>Hello  World   !</p>", "<p>Hello World\n\n!</p>"),
                   ("<p> </p>", "<p></p>"), ("<p/>", "<p></p>"), ("<p />", "<p></p>"), ("<input checked>", "<input checked=\"checked\">"),
                   ("<p>Hello", "<p> Hello"), ("<p>Hello</p>World", "<p>Hello</p> World")]
        @test heq(a, b)
    end
    @test heq("<div>Hello<!-- this is a comment --> World!</div>", "<div>Hello World!</div>")    # test_ignore_comments
    # test_unequal_html
    for (a, b) in [("<p>Hello</p>", "<p>Hello!</p>"), ("<p>foo&#20;bar</p>", "<p>foo&nbsp;bar</p>"), ("<p>foo bar</p>", "<p>foo &nbsp;bar</p>"),
                   ("<p>foo nbsp</p>", "<p>foo &nbsp;</p>"), ("<p>foo #20</p>", "<p>foo &#20;</p>"),
                   ("<p><span>Hello</span><span>World</span></p>", "<p><span>Hello</span>World</p>"),
                   ("<p><span>Hello</span>World</p>", "<p><span>Hello</span><span>World</span></p>")]
        @test hne(a, b)
    end
    # test_attributes
    @test heq("<input type=\"text\" id=\"id_name\" />", "<input id=\"id_name\" type=\"text\" />")
    @test heq("<input type='text' id=\"id_name\" />", "<input id=\"id_name\" type=\"text\" />")
    @test hne("<input type=\"text\" id=\"id_name\" />", "<input type=\"password\" id=\"id_name\" />")
    # test_class_attribute
    for a in ["<p class=\"foo bar\"></p>", "<p class=\" foo bar \"></p>", "<p class=\"   foo    bar    \"></p>", "<p class=\"foo\tbar\"></p>",
              "<p class=\"\tfoo\tbar\t\"></p>", "<p class=\"\t\t\tfoo\t\t\tbar\t\t\t\"></p>", "<p class=\"\t \nfoo \t\nbar\n\t \"></p>"]
        @test heq(a, "<p class=\"bar foo\"></p>")
    end
    # test_boolean_attribute, test_non_boolean_attibutes
    @test heq("<input checked>", "<input checked=\"\">") && heq("<input checked>", "<input checked=\"checked\">") &&
          heq("<input checked=\"\">", "<input checked=\"checked\">")
    @test hne("<input checked>", "<input checked=\"invalid\">")
    @test heq("<input value>", "<input value=\"\">") && hne("<input value>", "<input value=\"value\">")
    # test_normalize_refs
    for (a, b) in [("&#39;", "&#x27;"), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&#38;"), ("&amp;", "&#x26;"), ("&amp;", "&"),
                   ("&#38;", "&#x26;"), ("&#38;", "&"), ("&#x26;", "&")]
        @test heq(a, b) && heq(b, a)
    end
    # test_complex_examples
    @test heq("""<tr><th><label for="id_first_name">First name:</label></th>
<td><input type="text" name="first_name" value="John" id="id_first_name" /></td></tr>
<tr><th><label for="id_last_name">Last name:</label></th>
<td><input type="text" id="id_last_name" name="last_name" value="Lennon" /></td></tr>""",
              """
        <tr><th>
            <label for="id_first_name">First name:</label></th><td>
            <input type="text" name="first_name" value="John" id="id_first_name" />
        </td></tr>
        <tr><th>
            <label for="id_last_name">Last name:</label></th><td>
            <input type="text" name="last_name" value="Lennon" id="id_last_name" />
        </td></tr>
        """)
    @test heq("""<!DOCTYPE html>
        <html><head><link rel="stylesheet"><title>Document</title><meta attribute="value"></head>
        <body><p>
            This is a valid paragraph
            <div> this is a div AFTER the p</div>
        </body></html>""",
              """<html><head><link rel="stylesheet"><title>Document</title><meta attribute="value"></head>
        <body><p> This is a valid paragraph
            <!-- browsers would close the p tag here -->
            <div> this is a div AFTER the p</div>
            </p> <!-- this is invalid HTML parsing -->
        </body></html>""")
    # test_html_contain, test_count
    @test hcount("<p>foo</p>", "<p>foo") == 1 && hcount("<p>foo", "<p>foo</p>") == 1
    @test hcount("<div><p>foo</p></div>", "<p>foo") == 1 && hcount("<p>foo", "<div><p>foo</p></div>") == 0
    @test hcount("<div><p>foo</p></div>", "foo") == 1
    @test hcount("<p>foo</p><p>bar</p>", "<p>foo") == 1
    @test hcount("<p>foo foo</p><p>foo</p>", "foo") == 3
    @test hcount("<p class=\"bar\">foo</p>", "bar") == 0 && hcount("<p class=\"bar\">foo</p>", "class") == 0 &&
          hcount("<p class=\"bar\">foo</p>", "p") == 0 && hcount("<p class=\"bar\">foo</p>", "o") == 2
    @test hcount("<p>foo</p><p>foo</p>", "<p>foo") == 2
    @test hcount("<div><p>foo<input type=\"\"></p><p>foo</p></div>", "<p>foo") == 1
    @test hcount("<div><div><p>foo</p></div></div>", "<p>foo") == 1
    @test hcount("<p>foo<p>foo</p></p>", "<p>foo") == 1 && hcount("<p>foo<p>bar</p></p>", "<p>foo") == 0
    @test hcount("<div><p>foo</p><p>bar</p></div>", "<p>foo</p><p>bar</p>") == 1
    @test hcount("<div><p>foo</p><p>bar</p><p>foo</p><p>bar</p></div>", "<p>foo</p><p>bar</p>") == 2
    @test hcount("<a/><b/><c/>", "<a/><b/>") == 1 && hcount("<a/><b/><c/>", "<b/><a/>") == 0
    @test hcount("<a><b/><b/></a><b/><b/>", "<b/><b/>") == 2
    # test_root_element_escaped_html, test_escaped_html_errors: escaped text isn't an element
    @test canon("&lt;br&gt;") == "&lt;br&gt;"
    @test hne("<p><foo></p>", "<p>&lt;foo&gt;</p>") && hne("<p><foo></p>", "<p>&#60;foo&#62;</p>") && hne("&lt;br&gt;", "<br>")
    # test_parsing_errors
    @test !heq("<p>", "") && !heq("", "<p>")
    @test amsg(() -> assert_html_equal("< div></div>", "<div></div>")) == "First argument is not valid HTML:\nUnexpected end tag `div` (Line 1, Column 6)"
    @test_throws Juango.HTMLParseError PH("</p>")
    # test_contains_html
    r = HttpResponse("""<body>
        This is a form: <form method="get">
            <input type="text" name="Hello" />
        </form></body>""")
    @test assert_not_contains(r, "<input name='Hello' type='text'>") && assert_contains(r, "<form method=\"get\">")
    @test assert_contains(r, "<input name='Hello' type='text'>"; html = true) && assert_not_contains(r, "<form method=\"get\">"; html = true)
    # test_unicode_handling
    r = HttpResponse("<p class=\"help\">Some help text for the title (with Unicode ŠĐĆŽćžšđ)</p>")
    @test assert_contains(r, "<p class=\"help\">Some help text for the title (with Unicode ŠĐĆŽćžšđ)</p>"; html = true)
end

@testset "django test_utils: InHTMLTests, JSONEqualTests" begin
    @test amsg(() -> assert_in_html("<b>Hello</b>", "<p>Test</p>")) ==                                          # test_needle_msg
          "Couldn't find '<b>Hello</b>' in the following response\n'<p>Test</p>'"
    @test amsg(() -> assert_in_html("<b>Hello</b>", "<input type=\"text\" name=\"Hello\" />"; msg_prefix = "Prefix")) ==   # test_msg_prefix
          "Prefix: Couldn't find '<b>Hello</b>' in the following response\n'<input type=\"text\" name=\"Hello\" />'"
    @test amsg(() -> assert_in_html("<b>Hello</b>", "<b>Hello</b><b>Hello</b>"; count = 1, msg_prefix = "Prefix")) ==   # test_count_msg_prefix
          "Prefix: Found 2 instances of '<b>Hello</b>' (expected 1) in the following response\n'<b>Hello</b><b>Hello</b>'"
    hay = "<p><b>Hello</b> <span>there</span>! Hi <span>there</span>!</p>"                                    # test_base
    @test assert_in_html("<b>Hello</b>", hay) && assert_in_html("<span>there</span>", hay; count = 2)
    @test amsg(() -> assert_in_html("<p>Howdy</p>", hay)) == "Couldn't find '<p>Howdy</p>' in the following response\n'$hay'"
    @test amsg(() -> assert_in_html("<b>Hello</b>", hay; count = 2)) == "Found 1 instances of '<b>Hello</b>' (expected 2) in the following response\n'$hay'"
    @test assert_not_in_html("<b>Hi</b>", hay)                                                                  # test_assert_not_in_html
    @test amsg(() -> assert_not_in_html("<b>Hello</b>", hay)) == "'<b>Hello</b>' unexpectedly found in the following response\n'$hay'"
    @test amsg(() -> assert_not_in_html("<p>Hello</p>", "<p>Hello</p>"; msg_prefix = "Prefix")) ==
          "Prefix: '<p>Hello</p>' unexpectedly found in the following response\n'<p>Hello</p>'"
    # JSONEqualTests
    j1, j2 = "{\"attr1\": \"foo\", \"attr2\":\"baz\"}", "{\"attr2\":\"baz\", \"attr1\": \"foo\"}"
    @test assert_json_equal(j1, j1) && assert_json_equal(j1, j2)                                                # test_simple_equal(_unordered)
    @test_throws AssertionError assert_json_equal(j1, "{\"attr2\":\"baz\"}")                                     # test_simple_equal_raise
    bad = "{\"attr1\": \"foo, \"attr2\":\"baz\"}"                                                                 # test_equal_parsing_errors
    @test_throws AssertionError assert_json_equal(bad, j1)
    @test_throws AssertionError assert_json_equal(j1, bad)
    @test assert_json_not_equal(j1, "{\"attr2\":\"baz\"}")                                                       # test_simple_not_equal
    @test_throws AssertionError assert_json_not_equal(j1, j1)
    @test_throws AssertionError assert_json_not_equal(bad, j1)                                                   # test_not_equal_parsing_errors
    @test_throws AssertionError assert_json_not_equal(j1, bad)
end

@testset "django test_utils: AssertNumQueriesTests, AssertQuerySetEqualTests" begin
    port_block() do
        @test_throws ArgumentError assert_num_queries(() -> throw(ArgumentError("x")), 2)                       # test_assert_num_queries
        p1, p2 = create(DtuPerson; name = "p1"), create(DtuPerson; name = "p2")
        @test assert_num_queries(() -> collect(filter(DtuPerson; name = "p1")), 1)
        @test_throws AssertionError assert_num_queries(() -> collect(filter(DtuPerson; name = "p1")), 2)
        @test assert_queryset_equal(filter(DtuPerson; name = "p3"), [])                                         # test_empty
        @test assert_queryset_equal(order_by(objects(DtuPerson), "name"), [p1, p2])                              # test_ordered
        @test assert_queryset_equal(order_by(objects(DtuPerson), "name"), [p2, p1]; ordered = false)             # test_unordered
        @test assert_queryset_equal(order_by(objects(DtuPerson), "name"), order_by(objects(DtuPerson), "name"))  # test_queryset
        @test assert_queryset_equal(values_list(order_by(objects(DtuPerson), "name"), :name; flat = true), ["p1", "p2"])   # test_flat_values_list
        @test assert_queryset_equal(order_by(objects(DtuPerson), "name"), [p1.pk, p2.pk]; transform = x -> x.pk)    # test_transform
        @test_throws "Trying to compare non-ordered queryset against more than one ordered value." assert_queryset_equal(objects(DtuPerson), [p1, p2])   # test_undefined_order
        @test assert_queryset_equal(filter(DtuPerson; name = "p1"), [p1])
        bat, k2000 = create(DtuCar; name = "Batmobile"), create(DtuCar; name = "K 2000")                         # test_repeated_values
        bulk_create([DtuPossessedCar(; car = c, belongs_to = p1) for c in [bat, bat, k2000, k2000, k2000, k2000]])
        cars = [pc.car for pc in p1.possessed]
        @test_throws AssertionError assert_queryset_equal(cars, [bat, k2000]; ordered = false)
        @test assert_queryset_equal(cars, vcat(fill(bat, 2), fill(k2000, 4)); ordered = false, transform = c -> c)
    end
    # not translated: the skipping decorators, assertTemplateUsed's context managers, XML, warnings, setup_test_environment,
    # assertFieldOutput/FormError (tested in django_forms.jl), DisallowedDatabaseQueries, isolate_apps, TestContextDecorator
end
