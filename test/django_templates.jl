# Django's template tests, ported (#227): tests/template_tests.
# julia --project=test test/django_templates.jl   (see setup.jl)
#
# The filter and syntax tests are translated from Django's modules by a script (each keeps its
# Django name in a comment) and corrected by hand where Juango differs, with the reason at the
# test. Tests the script couldn't translate are listed at the end of each module's testset.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# Django's engine.render_to_string(template, context) for a template given as a string
rt(src, ctx = Dict{Any,Any}()) = render(Template(src), Dict{String,Any}(string(k) => v for (k, v) in ctx))
# several templates by name (Django's locmem loader): render `name`, which can extend or include the others
# (configured only when the templates change: a change of settings empties the caches, which
# {% cache %} tests rely on between renders; the old TEMPLATES come back at the end of the file)
const DJT_OLD_TEMPLATES = get(Juango.settings, :TEMPLATES, nothing)
const DJT_CURRENT = Ref{Any}(nothing)
function rtn(templates, name, ctx = Dict{Any,Any}())
    if DJT_CURRENT[] != templates
        configure!(TEMPLATES = Any[Juango.LocMemTemplates(templates)])
        DJT_CURRENT[] = templates
    end
    render(get_template(name), Dict{String,Any}(string(k) => v for (k, v) in ctx))
end
# a filter called as a function, as Django's tests import them from defaultfilters
function filt(name, v, args...; autoescape = true)
    f = Juango.FILTERS[name]
    arg = isempty(args) ? nothing : args[1]
    f.needs_autoescape ? f.fn(v, arg, autoescape) : f.fn(v, arg)
end
# Python's float(): of text too ("inf")
pyfloat(x) = x isa AbstractString ? parse(Float64, x) : Float64(x)
html_eq(a, b) = try assert_html_equal(string(a), string(b)) catch; false end

# Django's test tag libraries (template_tests/templatetags): testtags' echo, other_echo and upper, custom's noop,
# minusone and minustwo, and subpackage.echo's echo2
let lib = get(Juango.TAG_LIBRARIES, "testtags", nothing)
    lib === nothing && (lib = Juango.TagLibrary("testtags"))
    for name in ("echo", "other_echo")
        Juango.tag!(lib, name, (p, t) -> Juango.TextNode(join(Juango.split_contents(t.contents)[2:end], " ")))
    end
    filter!(lib, "upper", (v, _) -> uppercase(string(v)))
    custom = Juango.TagLibrary("custom")
    filter!(custom, "noop", (v, _) -> v)
    Juango.simple_tag!(x -> x - 1, custom, "minusone")
    Juango.simple_tag!(x -> x - 2, custom, "minustwo")
    Juango.simple_tag!(x -> x, Juango.TagLibrary("subpackage.echo"), "echo2")
end
# Django's template_tests/urls.py, for {% url %}
djt_view(req; kw...) = HttpResponse("")
const DJT_URLS = [path("", djt_view; name = "index"), re_path(raw"^client/([0-9,]+)/$", djt_view; name = "client"),
                  re_path(raw"^client/(?P<id>[0-9]+)/(?P<action>[^/]+)/$", djt_view; name = "client_action"),
                  re_path(raw"^client/(?P<client_id>[0-9]+)/(?P<action>[^/]+)/$", djt_view; name = "client_action"),
                  re_path(raw"^named-client/([0-9]+)/$", djt_view; name = "named.client"),
                  re_path(raw"^Юникод/(\w+)/$", djt_view; name = "метка_оператора"),
                  re_path(raw"^Юникод/(?P<tag>\S+)/$", djt_view; name = "метка_оператора_2")]

@testset "django template_tests: test_add" begin
    # test_add01
    @test rt("{{ i|add:\"5\" }}", Dict{Any,Any}("i" => 2000)) == "2005"
    # test_add02
    @test rt("{{ i|add:\"napis\" }}", Dict{Any,Any}("i" => 2000)) == ""
    # test_add03
    @test rt("{{ i|add:16 }}", Dict{Any,Any}("i" => "not_an_int")) == ""
    # test_add04
    @test rt("{{ i|add:\"16\" }}", Dict{Any,Any}("i" => "not_an_int")) == "not_an_int16"
    # test_add05
    @test rt("{{ l1|add:l2 }}", Dict{Any,Any}("l1" => Any[1, 2], "l2" => Any[3, 4])) == "[1, 2, 3, 4]"
    # test_add06
    @test rt("{{ t1|add:t2 }}", Dict{Any,Any}("t1" => (3, 4), "t2" => (1, 2))) == "(3, 4, 1, 2)"
    # test_add08
    @test rt("{{ s1|add:lazy_s2 }}", Dict{Any,Any}("s1" => "string", "lazy_s2" => gettext_lazy("lazy"))) == "stringlazy"
    # test_add09
    @test rt("{{ lazy_s1|add:lazy_s2 }}", Dict{Any,Any}("lazy_s1" => gettext_lazy("string"), "lazy_s2" => gettext_lazy("lazy"))) == "stringlazy"
    # test_add
    @test filt("add", "1", "2") == 3
    # not translated: test_add07 (call timedelta)
end

@testset "django template_tests: test_addslashes" begin
    # test_addslashes01
    @test rt("{% autoescape off %}{{ a|addslashes }} {{ b|addslashes }}{% endautoescape %}", Dict{Any,Any}("a" => "<a>'", "b" => mark_safe("<a>'"))) == "<a>\\' <a>\\'"
    # test_addslashes02
    @test rt("{{ a|addslashes }} {{ b|addslashes }}", Dict{Any,Any}("a" => "<a>'", "b" => mark_safe("<a>'"))) == "&lt;a&gt;\\&#x27; <a>\\'"
    # test_quotes
    @test filt("addslashes", "\"double quotes\" and 'single quotes'") == "\\\"double quotes\\\" and \\'single quotes\\'"
    # test_backslashes
    @test filt("addslashes", "\\ : backslashes, too") == "\\\\ : backslashes, too"
    # test_non_string_input
    @test filt("addslashes", 123) == "123"
end

@testset "django template_tests: test_autoescape" begin

    # not translated: test_autoescape_stringfilter01 (call UnsafeClass); test_autoescape_stringfilter02 (call UnsafeClass); test_autoescape_stringfilter03 (call SafeClass); test_autoescape_stringfilter04 (call SafeClass)
end

@testset "django template_tests: test_capfirst" begin
    # test_capfirst01
    @test rt("{% autoescape off %}{{ a|capfirst }} {{ b|capfirst }}{% endautoescape %}", Dict{Any,Any}("a" => "fred>", "b" => mark_safe("fred&gt;"))) == "Fred> Fred&gt;"
    # test_capfirst02
    @test rt("{{ a|capfirst }} {{ b|capfirst }}", Dict{Any,Any}("a" => "fred>", "b" => mark_safe("fred&gt;"))) == "Fred&gt; Fred&gt;"
    # test_capfirst
    @test filt("capfirst", "hello world") == "Hello world"
end

@testset "django template_tests: test_center" begin
    # test_center01
    @test rt("{% autoescape off %}.{{ a|center:\"5\" }}. .{{ b|center:\"5\" }}.{% endautoescape %}", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ". a&b . . a&b ."
    # test_center02
    @test rt(".{{ a|center:\"5\" }}. .{{ b|center:\"5\" }}.", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ". a&amp;b . . a&b ."
    # test_center
    @test filt("center", "test", 6) == " test "
    # test_non_string_input
    @test filt("center", 123, 5) == " 123 "
    # test_odd_input
    @test filt("center", "odd", 6) == " odd  "
    # test_even_input
    @test filt("center", "even", 7) == " even  "
    # not translated: test_widths (For)
end

@testset "django template_tests: test_chaining" begin
    # test_chaining01
    @test rt("{{ a|capfirst|center:\"7\" }}.{{ b|capfirst|center:\"7\" }}", Dict{Any,Any}("a" => "a < b", "b" => mark_safe("a < b"))) == " A &lt; b . A < b "
    # test_chaining02
    @test rt("{% autoescape off %}{{ a|capfirst|center:\"7\" }}.{{ b|capfirst|center:\"7\" }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b", "b" => mark_safe("a < b"))) == " A < b . A < b "
    # test_chaining03
    @test rt("{{ a|cut:\"b\"|capfirst }}.{{ b|cut:\"b\"|capfirst }}", Dict{Any,Any}("a" => "a < b", "b" => mark_safe("a < b"))) == "A &lt; .A < "
    # test_chaining04
    @test rt("{% autoescape off %}{{ a|cut:\"b\"|capfirst }}.{{ b|cut:\"b\"|capfirst }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b", "b" => mark_safe("a < b"))) == "A < .A < "
    # test_chaining05
    @test rt("{{ a|escape|capfirst }}", Dict{Any,Any}("a" => "a < b")) == "A &lt; b"
    # test_chaining06
    @test rt("{% autoescape off %}{{ a|escape|capfirst }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b")) == "A &lt; b"
    # test_chaining07
    @test rt("{{ a|force_escape|cut:\";\" }}", Dict{Any,Any}("a" => "a < b")) == "a &amp;lt b"
    # test_chaining08
    @test rt("{% autoescape off %}{{ a|force_escape|cut:\";\" }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b")) == "a &lt b"
    # test_chaining09
    @test rt("{{ a|cut:\";\"|force_escape }}", Dict{Any,Any}("a" => "a < b")) == "a &lt; b"
    # test_chaining10
    @test rt("{% autoescape off %}{{ a|cut:\";\"|force_escape }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b")) == "a &lt; b"
    # test_chaining11
    @test rt("{{ a|cut:\"b\"|safe }}", Dict{Any,Any}("a" => "a < b")) == "a < "
    # test_chaining12
    @test rt("{% autoescape off %}{{ a|cut:\"b\"|safe }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b")) == "a < "
    # test_chaining13
    @test rt("{{ a|safe|force_escape }}", Dict{Any,Any}("a" => "a < b")) == "a &lt; b"
    # test_chaining14
    @test rt("{% autoescape off %}{{ a|safe|force_escape }}{% endautoescape %}", Dict{Any,Any}("a" => "a < b")) == "a &lt; b"
end

@testset "django template_tests: test_cut" begin
    # test_cut01
    @test rt("{% autoescape off %}{{ a|cut:\"x\" }} {{ b|cut:\"x\" }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "&y &amp;y"
    # test_cut02
    @test rt("{{ a|cut:\"x\" }} {{ b|cut:\"x\" }}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "&amp;y &amp;y"
    # test_cut03
    @test rt("{% autoescape off %}{{ a|cut:\"&\" }} {{ b|cut:\"&\" }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "xy xamp;y"
    # test_cut04
    @test rt("{{ a|cut:\"&\" }} {{ b|cut:\"&\" }}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "xy xamp;y"
    # test_cut05
    @test rt("{% autoescape off %}{{ a|cut:\";\" }} {{ b|cut:\";\" }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "x&y x&ampy"
    # test_cut06
    @test rt("{{ a|cut:\";\" }} {{ b|cut:\";\" }}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&amp;y"))) == "x&amp;y x&amp;ampy"
    # test_character
    @test filt("cut", "a string to be mangled", "a") == " string to be mngled"
    # test_characters
    @test filt("cut", "a string to be mangled", "ng") == "a stri to be maled"
    # test_non_matching_string
    @test filt("cut", "a string to be mangled", "strings") == "a string to be mangled"
    # test_non_string_input
    @test filt("cut", 123, "2") == "13"
end

@testset "django template_tests: test_date" begin
    # test_date01
    @test rt("{{ d|date:\"m\" }}", Dict{Any,Any}("d" => DateTime(2008, 1, 1))) == "01"
    # test_date02
    @test rt("{{ d|date }}", Dict{Any,Any}("d" => DateTime(2008, 1, 1))) == "Jan. 1, 2008"
    # test_date03
    @test rt("{{ d|date:\"m\" }}", Dict{Any,Any}("d" => "fail_string")) == ""
    # test_date04
    @test rt("{{ d|date:\"o\" }}", Dict{Any,Any}("d" => DateTime(2008, 12, 29))) == "2009"
    # test_date05
    @test rt("{{ d|date:\"o\" }}", Dict{Any,Any}("d" => DateTime(2010, 1, 3))) == "2009"
    # test_date07
    @test rt("{{ d|date:\"e\" }}", Dict{Any,Any}("d" => DateTime(2009, 3, 12))) == ""
    # test_date08
    @test rt("{{ t|date:\"H:i\" }}", Dict{Any,Any}("t" => Dates.Time(0, 1))) == "00:01"
    # test_date09
    @test rt("{{ t|date:\"H:i\" }}", Dict{Any,Any}("t" => Dates.Time(0, 0))) == "00:00"
    # test_date_lazy
    @test rt("{{ t|date:_(\"H:i\") }}", Dict{Any,Any}("t" => Dates.Time(0, 0))) == "00:00"
    # test_date
    @test filt("date", DateTime(2005, 12, 29), "d F Y") == "29 December 2005"
    # test_no_args
    @test filt("date", "") == ""
    @test filt("date", nothing) == ""
    # test_escape_characters
    @test filt("date", DateTime(2005, 12, 29), "jS \\o\\f F") == "29th of December"
    # not translated: test_date02_l10n (with); test_date06 (call keywords)
end

@testset "django template_tests: test_default_if_none" begin
    # test_value
    @test filt("default_if_none", "val", "default") == "val"
    # test_none
    @test filt("default_if_none", nothing, "default") == "default"
    # test_empty_string
    @test filt("default_if_none", "", "default") == ""
end

@testset "django template_tests: test_default" begin
    # test_default01
    @test rt("{{ a|default:\"x<\" }}", Dict{Any,Any}("a" => "")) == "x<"
    # test_default02
    @test rt("{% autoescape off %}{{ a|default:\"x<\" }}{% endautoescape %}", Dict{Any,Any}("a" => "")) == "x<"
    # test_default03
    @test rt("{{ a|default:\"x<\" }}", Dict{Any,Any}("a" => mark_safe("x>"))) == "x>"
    # test_default04
    @test rt("{% autoescape off %}{{ a|default:\"x<\" }}{% endautoescape %}", Dict{Any,Any}("a" => mark_safe("x>"))) == "x>"
    # test_default_if_none01
    @test rt("{{ a|default:\"x<\" }}", Dict{Any,Any}("a" => nothing)) == "x<"
    # test_default_if_none02
    @test rt("{% autoescape off %}{{ a|default:\"x<\" }}{% endautoescape %}", Dict{Any,Any}("a" => nothing)) == "x<"
    # test_value
    @test filt("default", "val", "default") == "val"
    # test_none
    @test filt("default", nothing, "default") == "default"
    # test_empty_string
    @test filt("default", "", "default") == "default"
end

@testset "django template_tests: test_dictsort" begin
    # test_sort_list_of_tuples
    @test filt("dictsort", Any[("a", "42"), ("c", "string"), ("b", "foo")], 0) == Any[("a", "42"), ("b", "foo"), ("c", "string")]
    # test_sort_list_of_tuple_like_dicts
    @test filt("dictsort", Any[Dict{Any,Any}("0" => "a", "1" => "42"), Dict{Any,Any}("0" => "c", "1" => "string"), Dict{Any,Any}("0" => "b", "1" => "foo")], "0") == Any[Dict{Any,Any}("0" => "a", "1" => "42"), Dict{Any,Any}("0" => "b", "1" => "foo"), Dict{Any,Any}("0" => "c", "1" => "string")]
    # test_invalid_values
    @test filt("dictsort", Any[1, 2, 3], "age") == ""
    @test filt("dictsort", "Hello!", "age") == ""
    @test filt("dictsort", Dict{Any,Any}("a" => 1), "age") == ""
    @test filt("dictsort", 1, "age") == ""
    # test_invalid_args
    @test filt("dictsort", Any[Dict{Any,Any}()], "._private") == ""
    @test filt("dictsort", Any[Dict{Any,Any}("_private" => "test")], "_private") == ""
    @test filt("dictsort", Any[Dict{Any,Any}("nested" => Dict{Any,Any}("_private" => "test"))], "nested._private") == ""
    # not translated: test_property (Return); test_method (nothing); test_property_resolver (call User); test_sort (call dictsort); test_dictsort_complex_sorting_key (call dictsort)
end

@testset "django template_tests: test_dictsortreversed" begin
    # test_sort_list_of_tuples
    @test filt("dictsortreversed", Any[("a", "42"), ("c", "string"), ("b", "foo")], 0) == Any[("c", "string"), ("b", "foo"), ("a", "42")]
    # test_sort_list_of_tuple_like_dicts
    @test filt("dictsortreversed", Any[Dict{Any,Any}("0" => "a", "1" => "42"), Dict{Any,Any}("0" => "c", "1" => "string"), Dict{Any,Any}("0" => "b", "1" => "foo")], "0") == Any[Dict{Any,Any}("0" => "c", "1" => "string"), Dict{Any,Any}("0" => "b", "1" => "foo"), Dict{Any,Any}("0" => "a", "1" => "42")]
    # test_invalid_values
    @test filt("dictsortreversed", Any[1, 2, 3], "age") == ""
    @test filt("dictsortreversed", "Hello!", "age") == ""
    @test filt("dictsortreversed", Dict{Any,Any}("a" => 1), "age") == ""
    @test filt("dictsortreversed", 1, "age") == ""
    # test_invalid_args
    @test filt("dictsortreversed", Any[Dict{Any,Any}()], "._private") == ""
    @test filt("dictsortreversed", Any[Dict{Any,Any}("_private" => "test")], "_private") == ""
    @test filt("dictsortreversed", Any[Dict{Any,Any}("nested" => Dict{Any,Any}("_private" => "test"))], "nested._private") == ""
    # not translated: test_sort (call dictsortreversed)
end

@testset "django template_tests: test_divisibleby" begin
    # test_true
    @test filt("divisibleby", 4, 2) == true
    # test_false
    @test filt("divisibleby", 4, 3) == false
end

@testset "django template_tests: test_escapejs" begin
    # test_escapejs01
    @test rt("{{ a|escapejs }}", Dict{Any,Any}("a" => "testing\r\njavascript 'string\" <b>escaping</b>")) == "testing\\u000D\\u000Ajavascript \\u0027string\\u0022 \\u003Cb\\u003Eescaping\\u003C/b\\u003E"
    # test_escapejs02
    @test rt("{% autoescape off %}{{ a|escapejs }}{% endautoescape %}", Dict{Any,Any}("a" => "testing\r\njavascript 'string\" <b>escaping</b>")) == "testing\\u000D\\u000Ajavascript \\u0027string\\u0022 \\u003Cb\\u003Eescaping\\u003C/b\\u003E"
    # test_quotes
    @test filt("escapejs", "\"double quotes\" and 'single quotes'") == "\\u0022double quotes\\u0022 and \\u0027single quotes\\u0027"
    # test_backslashes
    @test filt("escapejs", "\\ : backslashes, too") == "\\u005C : backslashes, too"
    # test_whitespace
    @test filt("escapejs", "and lots of whitespace: \r\n\t\x0b\x0c\x08") == "and lots of whitespace: \\u000D\\u000A\\u0009\\u000B\\u000C\\u0008"
    # test_script
    @test filt("escapejs", "<script>and this</script>") == "\\u003Cscript\\u003Eand this\\u003C/script\\u003E"
    # test_paragraph_separator
    @test filt("escapejs", "paragraph separator: and line separator: ") == "paragraph separator:\\u2029and line separator:\\u2028"
    # not translated: test_lazy_string (call lazy)
end

@testset "django template_tests: test_escape" begin
    # test_escape01
    @test rt("{{ a|escape }} {{ b|escape }}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&y"))) == "x&amp;y x&y"
    # test_escape02
    @test rt("{% autoescape off %}{{ a|escape }} {{ b|escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y", "b" => mark_safe("x&y"))) == "x&amp;y x&y"
    # test_escape03
    @test rt("{% autoescape off %}{{ a|escape|escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_escape04
    @test rt("{{ a|escape|escape }}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_non_string_input
    @test filt("escape", 123) == "123"
    # not translated: test_escape_lazy_string (call lazy)
end

@testset "django template_tests: test_escapeseq" begin
    # test_basic
    @test rt("{{ a|escapeseq|join:\", \" }} -- {{ b|escapeseq|join:\", \" }}", Dict{Any,Any}("a" => Any["x&y", "<p>"], "b" => Any[mark_safe("x&y"), mark_safe("<p>")])) == "x&amp;y, &lt;p&gt; -- x&y, <p>"
    # test_autoescape_off
    @test rt("{% autoescape off %}{{ a|escapeseq|join:\", \" }} -- {{ b|escapeseq|join:\", \"}}{% endautoescape %}", Dict{Any,Any}("a" => Any["x&y", "<p>"], "b" => Any[mark_safe("x&y"), mark_safe("<p>")])) == "x&amp;y, &lt;p&gt; -- x&y, <p>"
    # test_chain_join
    @test rt("{{ a|escapeseq|join:\"<br/>\" }}", Dict{Any,Any}("a" => Any["x&y", "<p>"])) == "x&amp;y<br/>&lt;p&gt;"
    # test_chain_join_autoescape_off
    @test rt("{% autoescape off %}{{ a|escapeseq|join:\"<br/>\" }}{% endautoescape %}", Dict{Any,Any}("a" => Any["x&y", "<p>"])) == "x&amp;y<br/>&lt;p&gt;"
end

@testset "django template_tests: test_filesizeformat" begin

    # not translated: test_formats (call complex); test_localized_formats (call complex); test_negative_numbers (For)
end

@testset "django template_tests: test_first" begin
    # test_first01
    @test rt("{{ a|first }} {{ b|first }}", Dict{Any,Any}("a" => Any["a&b", "x"], "b" => Any[mark_safe("a&b"), "x"])) == "a&amp;b a&b"
    # test_first02
    @test rt("{% autoescape off %}{{ a|first }} {{ b|first }}{% endautoescape %}", Dict{Any,Any}("a" => Any["a&b", "x"], "b" => Any[mark_safe("a&b"), "x"])) == "a&b a&b"
    # test_list
    @test filt("first", Any[0, 1, 2]) == 0
    # test_empty_string
    @test filt("first", "") == ""
    # test_string
    @test filt("first", "test") == "t"
end

@testset "django template_tests: test_floatformat" begin
    # test_floatformat01
    @test rt("{% autoescape off %}{{ a|floatformat }} {{ b|floatformat }}{% endautoescape %}", Dict{Any,Any}("a" => "1.42", "b" => mark_safe("1.42"))) == "1.4 1.4"
    # test_floatformat02
    @test rt("{{ a|floatformat }} {{ b|floatformat }}", Dict{Any,Any}("a" => "1.42", "b" => mark_safe("1.42"))) == "1.4 1.4"
    # test_inputs
    @test filt("floatformat", 7.7) == "7.7"
    @test filt("floatformat", 7.0) == "7"
    @test filt("floatformat", 0.7) == "0.7"
    @test filt("floatformat", -0.7) == "-0.7"
    @test filt("floatformat", 0.07) == "0.1"
    @test filt("floatformat", -0.07) == "-0.1"
    @test filt("floatformat", 0.007) == "0.0"
    @test filt("floatformat", 0.0) == "0"
    @test filt("floatformat", 7.7, 0) == "8"
    @test filt("floatformat", 7.7, 3) == "7.700"
    @test filt("floatformat", 6.0, 3) == "6.000"
    @test filt("floatformat", 6.2, 3) == "6.200"
    @test filt("floatformat", 6.2, -3) == "6.200"
    @test filt("floatformat", 13.1031, -3) == "13.103"
    @test filt("floatformat", 11.1197, -2) == "11.12"
    @test filt("floatformat", 11.0, -2) == "11"
    @test filt("floatformat", 11.000001, -2) == "11.00"
    @test filt("floatformat", 8.2798, 3) == "8.280"
    @test filt("floatformat", 5555.555, 2) == "5555.56"
    @test filt("floatformat", 1.3, 2) == "1.30"
    @test filt("floatformat", 0.12345, 2) == "0.12"
    @test filt("floatformat", Decimal("555.555"), 2) == "555.56"
    @test filt("floatformat", Decimal("09.000")) == "9"
    @test filt("floatformat", Decimal("123456.123456789012345678901"), 21) == "123456.123456789012345678901"
    @test filt("floatformat", 13.1031, "bar") == "13.1031"
    @test filt("floatformat", 18.125, 2) == "18.13"
    @test filt("floatformat", -1.323297138040798e+35, 2) == "-132329713804079800000000000000000000.00"
    @test filt("floatformat", -1.323297138040798e+35, -2) == "-132329713804079800000000000000000000"
    @test filt("floatformat", 1.5e-15, 20) == "0.00000000000000150000"
    @test filt("floatformat", 1.5e-15, -20) == "0.00000000000000150000"
    @test filt("floatformat", 1.0000000000000002, 16) == "1.0000000000000002"
    @test filt("floatformat", "1e199") == ("1" * ("0" ^ 199))
    # test_zero_values
    @test filt("floatformat", 0, 6) == "0.000000"
    @test filt("floatformat", 0, 7) == "0.0000000"
    @test filt("floatformat", 0, 10) == "0.0000000000"
    @test filt("floatformat", 1.5e-20, 20) == "0.00000000000000000002"
    @test filt("floatformat", "0.00", 0) == "0"
    @test filt("floatformat", Decimal("0.00"), 0) == "0"
    @test filt("floatformat", "0.0000", 2) == "0.00"
    @test filt("floatformat", Decimal("0.0000"), 2) == "0.00"
    @test filt("floatformat", "0.000000", 4) == "0.0000"
    @test filt("floatformat", Decimal("0.000000"), 4) == "0.0000"
    # not translated: test_invalid_inputs (call object); test_force_grouping (with); test_unlocalize (with); test_negative_zero_values (For); test_infinity (binop); test_too_many_digits_to_render (For); test_too_many_digits_to_render_very_long (Try); test_float_dunder_method (ClassDef); test_low_decimal_precision (with)
end

@testset "django template_tests: test_force_escape" begin
    # test_force_escape01
    @test rt("{% autoescape off %}{{ a|force_escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_force_escape02
    @test rt("{{ a|force_escape }}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_force_escape03
    @test rt("{% autoescape off %}{{ a|force_escape|force_escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y")) == "x&amp;amp;y"
    # test_force_escape04
    @test rt("{{ a|force_escape|force_escape }}", Dict{Any,Any}("a" => "x&y")) == "x&amp;amp;y"
    # test_force_escape05
    @test rt("{% autoescape off %}{{ a|force_escape|escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_force_escape06
    @test rt("{{ a|force_escape|escape }}", Dict{Any,Any}("a" => "x&y")) == "x&amp;y"
    # test_force_escape07
    @test rt("{% autoescape off %}{{ a|escape|force_escape }}{% endautoescape %}", Dict{Any,Any}("a" => "x&y")) == "x&amp;amp;y"
    # test_force_escape08
    @test rt("{{ a|escape|force_escape }}", Dict{Any,Any}("a" => "x&y")) == "x&amp;amp;y"
    # test_unicode
    @test filt("force_escape", "<some html & special characters > here ĐÅ€£") == "&lt;some html &amp; special characters &gt; here ĐÅ€£"
    # not translated: test_escape (call force_escape)
end

@testset "django template_tests: test_get_digit" begin
    # test_values
    @test filt("get_digit", 123, 1) == 3
    @test filt("get_digit", 123, 2) == 2
    @test filt("get_digit", 123, 3) == 1
    @test filt("get_digit", 123, 4) == 0
    @test filt("get_digit", 123, 0) == 123
    # test_string
    @test filt("get_digit", "xyz", 0) == "xyz"
end

@testset "django template_tests: test_iriencode" begin
    # test_iriencode01
    @test rt("{{ url|iriencode }}", Dict{Any,Any}("url" => "?test=1&me=2")) == "?test=1&amp;me=2"
    # test_iriencode02
    @test rt("{% autoescape off %}{{ url|iriencode }}{% endautoescape %}", Dict{Any,Any}("url" => "?test=1&me=2")) == "?test=1&me=2"
    # test_iriencode03
    @test rt("{{ url|iriencode }}", Dict{Any,Any}("url" => mark_safe("?test=1&me=2"))) == "?test=1&me=2"
    # test_iriencode04
    @test rt("{% autoescape off %}{{ url|iriencode }}{% endautoescape %}", Dict{Any,Any}("url" => mark_safe("?test=1&me=2"))) == "?test=1&me=2"
    # test_unicode
    @test filt("iriencode", "Sør-Trøndelag") == "S%C3%B8r-Tr%C3%B8ndelag"
    # not translated: test_urlencoded (call urlencode)
end

@testset "django template_tests: test_join" begin
    # test_join01
    @test rt("{{ a|join:\", \" }}", Dict{Any,Any}("a" => Any["alpha", "beta & me"])) == "alpha, beta &amp; me"
    # test_join02
    @test rt("{% autoescape off %}{{ a|join:\", \" }}{% endautoescape %}", Dict{Any,Any}("a" => Any["alpha", "beta & me"])) == "alpha, beta & me"
    # test_join03
    @test rt("{{ a|join:\" &amp; \" }}", Dict{Any,Any}("a" => Any["alpha", "beta & me"])) == "alpha &amp; beta &amp; me"
    # test_join04
    @test rt("{% autoescape off %}{{ a|join:\" &amp; \" }}{% endautoescape %}", Dict{Any,Any}("a" => Any["alpha", "beta & me"])) == "alpha &amp; beta & me"
    # test_join05
    @test rt("{{ a|join:var }}", Dict{Any,Any}("a" => Any["alpha", "beta & me"], "var" => " & ")) == "alpha &amp; beta &amp; me"
    # test_join06
    @test rt("{{ a|join:var }}", Dict{Any,Any}("a" => Any["alpha", "beta & me"], "var" => mark_safe(" & "))) == "alpha & beta &amp; me"
    # test_join07
    @test rt("{{ a|join:var|lower }}", Dict{Any,Any}("a" => Any["Alpha", "Beta & me"], "var" => " & ")) == "alpha &amp; beta &amp; me"
    # test_join08
    @test rt("{{ a|join:var|lower }}", Dict{Any,Any}("a" => Any["Alpha", "Beta & me"], "var" => mark_safe(" & "))) == "alpha & beta &amp; me"
    # test_join_autoescape_off
    @test rt("{% autoescape off %}{{ var_list|join:var_joiner }}{% endautoescape %}", Dict{Any,Any}("var_list" => Any["<p>Hello World!</p>", "beta & me", "<script>Hi!</script>"], "var_joiner" => "<br/>")) == "<p>Hello World!</p><br/>beta & me<br/><script>Hi!</script>"
    # test_list
    @test filt("join", Any[0, 1, 2], "glue") == "0glue1glue2"
    # test_autoescape
    @test filt("join", Any["<a>", "<img>", "</a>"], "<br>") == "&lt;a&gt;&lt;br&gt;&lt;img&gt;&lt;br&gt;&lt;/a&gt;"
    # test_autoescape_off
    @test filt("join", Any["<a>", "<img>", "</a>"], "<br>"; autoescape = false) == "<a><br><img><br></a>"
    # not translated: test_noniterable_arg (call object); test_noniterable_arg_autoescape_off (call object)
end

@testset "django template_tests: test_json_script" begin
    # test_basic
    @test rt("{{ value|json_script:\"test_id\" }}", Dict{Any,Any}("value" => Dict{Any,Any}("a" => "testing\r\njson 'string\" <b>escaping</b>"))) == "<script id=\"test_id\" type=\"application/json\">{\"a\": \"testing\\r\\njson 'string\\\" \\u003Cb\\u003Eescaping\\u003C/b\\u003E\"}</script>"
    # test_without_id
    @test rt("{{ value|json_script }}", Dict{Any,Any}("value" => Dict{Any,Any}())) == "<script type=\"application/json\">{}</script>"
end

@testset "django template_tests: test_last" begin
    # test_last01
    @test rt("{{ a|last }} {{ b|last }}", Dict{Any,Any}("a" => Any["x", "a&b"], "b" => Any["x", mark_safe("a&b")])) == "a&amp;b a&b"
    # test_last02
    @test rt("{% autoescape off %}{{ a|last }} {{ b|last }}{% endautoescape %}", Dict{Any,Any}("a" => Any["x", "a&b"], "b" => Any["x", mark_safe("a&b")])) == "a&b a&b"
    # test_empty_list
    @test rt("{% autoescape off %}{{ a|last }}{% endautoescape %}", Dict{Any,Any}("a" => Any[])) == ""
end

@testset "django template_tests: test_length" begin
    # test_length01
    @test rt("{{ list|length }}", Dict{Any,Any}("list" => Any["4", nothing, true, Dict{Any,Any}()])) == "4"
    # test_length02
    @test rt("{{ list|length }}", Dict{Any,Any}("list" => Any[])) == "0"
    # test_length03
    @test rt("{{ string|length }}", Dict{Any,Any}("string" => "")) == "0"
    # test_length04
    @test rt("{{ string|length }}", Dict{Any,Any}("string" => "django")) == "6"
    # test_length05
    @test rt("{% if string|length == 6 %}Pass{% endif %}", Dict{Any,Any}("string" => mark_safe("django"))) == "Pass"
    # test_length06
    @test rt("{{ int|length }}", Dict{Any,Any}("int" => 7)) == "0"
    # test_length07
    @test rt("{{ None|length }}", Dict{Any,Any}("None" => nothing)) == "0"
    # test_string
    @test filt("length", "1234") == 4
    # test_safestring
    @test filt("length", mark_safe("1234")) == 4
    # test_list
    @test filt("length", Any[1, 2, 3, 4]) == 4
end

@testset "django template_tests: test_linebreaksbr" begin
    # test_linebreaksbr01
    @test rt("{{ a|linebreaksbr }} {{ b|linebreaksbr }}", Dict{Any,Any}("a" => "x&\ny", "b" => mark_safe("x&\ny"))) == "x&amp;<br>y x&<br>y"
    # test_linebreaksbr02
    @test rt("{% autoescape off %}{{ a|linebreaksbr }} {{ b|linebreaksbr }}{% endautoescape %}", Dict{Any,Any}("a" => "x&\ny", "b" => mark_safe("x&\ny"))) == "x&<br>y x&<br>y"
    # test_newline
    @test filt("linebreaksbr", "line 1\nline 2") == "line 1<br>line 2"
    # test_carriage
    @test filt("linebreaksbr", "line 1\rline 2") == "line 1<br>line 2"
    # test_carriage_newline
    @test filt("linebreaksbr", "line 1\r\nline 2") == "line 1<br>line 2"
    # test_non_string_input
    @test filt("linebreaksbr", 123) == "123"
    # test_autoescape
    @test filt("linebreaksbr", "foo\n<a>bar</a>\nbuz") == "foo<br>&lt;a&gt;bar&lt;/a&gt;<br>buz"
    # test_autoescape_off
    @test filt("linebreaksbr", "foo\n<a>bar</a>\nbuz"; autoescape = false) == "foo<br><a>bar</a><br>buz"
end

@testset "django template_tests: test_linebreaks" begin
    # test_linebreaks01
    @test rt("{{ a|linebreaks }} {{ b|linebreaks }}", Dict{Any,Any}("a" => "x&\ny", "b" => mark_safe("x&\ny"))) == "<p>x&amp;<br>y</p> <p>x&<br>y</p>"
    # test_linebreaks02
    @test rt("{% autoescape off %}{{ a|linebreaks }} {{ b|linebreaks }}{% endautoescape %}", Dict{Any,Any}("a" => "x&\ny", "b" => mark_safe("x&\ny"))) == "<p>x&<br>y</p> <p>x&<br>y</p>"
    # test_line
    @test filt("linebreaks", "line 1") == "<p>line 1</p>"
    # test_newline
    @test filt("linebreaks", "line 1\nline 2") == "<p>line 1<br>line 2</p>"
    # test_carriage
    @test filt("linebreaks", "line 1\rline 2") == "<p>line 1<br>line 2</p>"
    # test_carriage_newline
    @test filt("linebreaks", "line 1\r\nline 2") == "<p>line 1<br>line 2</p>"
    # test_non_string_input
    @test filt("linebreaks", 123) == "<p>123</p>"
    # test_autoescape
    @test filt("linebreaks", "foo\n<a>bar</a>\nbuz") == "<p>foo<br>&lt;a&gt;bar&lt;/a&gt;<br>buz</p>"
    # test_autoescape_off
    @test filt("linebreaks", "foo\n<a>bar</a>\nbuz"; autoescape = false) == "<p>foo<br><a>bar</a><br>buz</p>"
    # not translated: test_lazy_string_input (call lazy)
end

@testset "django template_tests: test_linenumbers" begin
    # test_linenumbers01
    @test rt("{{ a|linenumbers }} {{ b|linenumbers }}", Dict{Any,Any}("a" => "one\n<two>\nthree", "b" => mark_safe("one\n&lt;two&gt;\nthree"))) == "1. one\n2. &lt;two&gt;\n3. three 1. one\n2. &lt;two&gt;\n3. three"
    # test_linenumbers02
    @test rt("{% autoescape off %}{{ a|linenumbers }} {{ b|linenumbers }}{% endautoescape %}", Dict{Any,Any}("a" => "one\n<two>\nthree", "b" => mark_safe("one\n&lt;two&gt;\nthree"))) == "1. one\n2. <two>\n3. three 1. one\n2. &lt;two&gt;\n3. three"
    # test_linenumbers
    @test filt("linenumbers", "line 1\nline 2") == "1. line 1\n2. line 2"
    # test_non_string_input
    @test filt("linenumbers", 123) == "1. 123"
    # test_autoescape
    @test filt("linenumbers", "foo\n<a>bar</a>\nbuz") == "1. foo\n2. &lt;a&gt;bar&lt;/a&gt;\n3. buz"
    # test_autoescape_off
    @test filt("linenumbers", "foo\n<a>bar</a>\nbuz"; autoescape = false) == "1. foo\n2. <a>bar</a>\n3. buz"
    # not translated: test_linenumbers2 (call join)
end

@testset "django template_tests: test_ljust" begin
    # test_ljust01
    @test rt("{% autoescape off %}.{{ a|ljust:\"5\" }}. .{{ b|ljust:\"5\" }}.{% endautoescape %}", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ".a&b  . .a&b  ."
    # test_ljust02
    @test rt(".{{ a|ljust:\"5\" }}. .{{ b|ljust:\"5\" }}.", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ".a&amp;b  . .a&b  ."
    # test_ljust
    @test filt("ljust", "test", 10) == "test      "
    @test filt("ljust", "test", 3) == "test"
    # test_less_than_string_length
    @test filt("ljust", "test", 3) == "test"
    # test_non_string_input
    @test filt("ljust", 123, 4) == "123 "
end

@testset "django template_tests: test_lower" begin
    # test_lower01
    @test rt("{% autoescape off %}{{ a|lower }} {{ b|lower }}{% endautoescape %}", Dict{Any,Any}("a" => "Apple & banana", "b" => mark_safe("Apple &amp; banana"))) == "apple & banana apple &amp; banana"
    # test_lower02
    @test rt("{{ a|lower }} {{ b|lower }}", Dict{Any,Any}("a" => "Apple & banana", "b" => mark_safe("Apple &amp; banana"))) == "apple &amp; banana apple &amp; banana"
    # test_lower
    @test filt("lower", "TEST") == "test"
    # test_unicode
    @test filt("lower", "Ë") == "ë"
    # test_non_string_input
    @test filt("lower", 123) == "123"
end

@testset "django template_tests: test_make_list" begin
    # test_make_list01
    @test rt("{% autoescape off %}{{ a|make_list }}{% endautoescape %}", Dict{Any,Any}("a" => mark_safe("&"))) == "['&']"
    # test_make_list02
    @test rt("{{ a|make_list }}", Dict{Any,Any}("a" => mark_safe("&"))) == "[&#x27;&amp;&#x27;]"
    # test_make_list03
    @test rt("{% autoescape off %}{{ a|make_list|stringformat:\"s\"|safe }}{% endautoescape %}", Dict{Any,Any}("a" => mark_safe("&"))) == "['&']"
    # test_make_list04
    @test rt("{{ a|make_list|stringformat:\"s\"|safe }}", Dict{Any,Any}("a" => mark_safe("&"))) == "['&']"
    # test_string
    @test filt("make_list", "abc") == Any["a", "b", "c"]
    # test_integer
    @test filt("make_list", 1234) == Any["1", "2", "3", "4"]
end

@testset "django template_tests: test_phone2numeric" begin
    # test_phone2numeric01
    @test rt("{{ a|phone2numeric }} {{ b|phone2numeric }}", Dict{Any,Any}("a" => "<1-800-call-me>", "b" => mark_safe("<1-800-call-me>"))) == "&lt;1-800-2255-63&gt; <1-800-2255-63>"
    # test_phone2numeric02
    @test rt("{% autoescape off %}{{ a|phone2numeric }} {{ b|phone2numeric }}{% endautoescape %}", Dict{Any,Any}("a" => "<1-800-call-me>", "b" => mark_safe("<1-800-call-me>"))) == "<1-800-2255-63> <1-800-2255-63>"
    # test_phone2numeric03
    @test rt("{{ a|phone2numeric }}", Dict{Any,Any}("a" => "How razorback-jumping frogs can level six piqued gymnasts!")) == "469 729672225-5867464 37647 226 53835 749 747833 49662787!"
    # test_phone2numeric
    @test filt("phone2numeric", "0800 flowers") == "0800 3569377"
end

@testset "django template_tests: test_pluralize" begin
    # test_integers
    @test filt("pluralize", 1) == ""
    @test filt("pluralize", 0) == "s"
    @test filt("pluralize", 2) == "s"
    # test_floats
    @test filt("pluralize", 0.5) == "s"
    @test filt("pluralize", 1.5) == "s"
    # test_decimals
    @test filt("pluralize", Decimal(1)) == ""
    @test filt("pluralize", Decimal(0)) == "s"
    @test filt("pluralize", Decimal(2)) == "s"
    # test_lists
    @test filt("pluralize", Any[1]) == ""
    @test filt("pluralize", Any[]) == "s"
    @test filt("pluralize", Any[1, 2, 3]) == "s"
    # test_suffixes
    @test filt("pluralize", 1, "es") == ""
    @test filt("pluralize", 0, "es") == "es"
    @test filt("pluralize", 2, "es") == "es"
    @test filt("pluralize", 1, "y,ies") == "y"
    @test filt("pluralize", 0, "y,ies") == "ies"
    @test filt("pluralize", 2, "y,ies") == "ies"
    @test filt("pluralize", 0, "y,ies,error") == ""
    # test_value_error
    @test filt("pluralize", "", "y,es") == ""
    @test filt("pluralize", "", "es") == ""
    # not translated: test_no_arguments (method check_values); test_suffix (method check_values); test_singular_and_plural_suffix (method check_values); test_no_len_type (call object)
end

@testset "django template_tests: test_random" begin
    # test_random01
    @test rt("{{ a|random }} {{ b|random }}", Dict{Any,Any}("a" => Any["a&b", "a&b"], "b" => Any[mark_safe("a&b"), mark_safe("a&b")])) == "a&amp;b a&b"
    # test_random02
    @test rt("{% autoescape off %}{{ a|random }} {{ b|random }}{% endautoescape %}", Dict{Any,Any}("a" => Any["a&b", "a&b"], "b" => Any[mark_safe("a&b"), mark_safe("a&b")])) == "a&b a&b"
    # test_empty_list
    @test rt("{{ list|random }}", Dict{Any,Any}("list" => Any[])) == ""
end

@testset "django template_tests: test_rjust" begin
    # test_rjust01
    @test rt("{% autoescape off %}.{{ a|rjust:\"5\" }}. .{{ b|rjust:\"5\" }}.{% endautoescape %}", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ".  a&b. .  a&b."
    # test_rjust02
    @test rt(".{{ a|rjust:\"5\" }}. .{{ b|rjust:\"5\" }}.", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == ".  a&amp;b. .  a&b."
    # test_rjust
    @test filt("rjust", "test", 10) == "      test"
    # test_less_than_string_length
    @test filt("rjust", "test", 3) == "test"
    # test_non_string_input
    @test filt("rjust", 123, 4) == " 123"
end

@testset "django template_tests: test_safe" begin
    # test_safe01
    @test rt("{{ a }} -- {{ a|safe }}", Dict{Any,Any}("a" => "<b>hello</b>")) == "&lt;b&gt;hello&lt;/b&gt; -- <b>hello</b>"
    # test_safe02
    @test rt("{% autoescape off %}{{ a }} -- {{ a|safe }}{% endautoescape %}", Dict{Any,Any}("a" => "<b>hello</b>")) == "<b>hello</b> -- <b>hello</b>"
end

@testset "django template_tests: test_safeseq" begin
    # test_safeseq01
    @test rt("{{ a|join:\", \" }} -- {{ a|safeseq|join:\", \" }}", Dict{Any,Any}("a" => Any["&", "<"])) == "&amp;, &lt; -- &, <"
    # test_safeseq02
    @test rt("{% autoescape off %}{{ a|join:\", \" }} -- {{ a|safeseq|join:\", \" }}{% endautoescape %}", Dict{Any,Any}("a" => Any["&", "<"])) == "&, < -- &, <"
end

@testset "django template_tests: test_slice" begin
    # test_slice01
    @test rt("{{ a|slice:\"1:3\" }} {{ b|slice:\"1:3\" }}", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == "&amp;b &b"
    # test_slice02
    @test rt("{% autoescape off %}{{ a|slice:\"1:3\" }} {{ b|slice:\"1:3\" }}{% endautoescape %}", Dict{Any,Any}("a" => "a&b", "b" => mark_safe("a&b"))) == "&b &b"
    # test_zero_length
    @test filt("slice", "abcdefg", "0") == ""
    # test_index
    @test filt("slice", "abcdefg", "1") == "a"
    # test_index_integer
    @test filt("slice", "abcdefg", 1) == "a"
    # test_negative_index
    @test filt("slice", "abcdefg", "-1") == "abcdef"
    # test_range
    @test filt("slice", "abcdefg", "1:2") == "b"
    # test_range_multiple
    @test filt("slice", "abcdefg", "1:3") == "bc"
    # test_range_step
    @test filt("slice", "abcdefg", "0::2") == "aceg"
    # test_empty_dict
    @test filt("slice", Dict{Any,Any}(), "1") == Dict{Any,Any}()
    # not translated: test_fail_silently (call object)
end

@testset "django template_tests: test_slugify" begin
    # test_slugify01
    @test rt("{% autoescape off %}{{ a|slugify }} {{ b|slugify }}{% endautoescape %}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "a-b a-amp-b"
    # test_slugify02
    @test rt("{{ a|slugify }} {{ b|slugify }}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "a-b a-amp-b"
    # test_slugify
    @test filt("slugify", " Jack & Jill like numbers 1,2,3 and 4 and silly characters ?%.\$!/") == "jack-jill-like-numbers-123-and-4-and-silly-characters"
    # test_unicode
    @test filt("slugify", "Un éléphant à l'orée du bois") == "un-elephant-a-loree-du-bois"
    # test_non_string_input
    @test filt("slugify", 123) == "123"
    # not translated: test_slugify_lazy_string (call lazy)
end

@testset "django template_tests: test_stringformat" begin
    # test_stringformat01
    @test rt("{% autoescape off %}.{{ a|stringformat:\"5s\" }}. .{{ b|stringformat:\"5s\" }}.{% endautoescape %}", Dict{Any,Any}("a" => "a<b", "b" => mark_safe("a<b"))) == ".  a<b. .  a<b."
    # test_stringformat02
    @test rt(".{{ a|stringformat:\"5s\" }}. .{{ b|stringformat:\"5s\" }}.", Dict{Any,Any}("a" => "a<b", "b" => mark_safe("a<b"))) == ".  a&lt;b. .  a<b."
    # not translated: test_format (Set); test_invalid (call object)
end

@testset "django template_tests: test_striptags" begin
    # test_striptags01
    @test rt("{{ a|striptags }} {{ b|striptags }}", Dict{Any,Any}("a" => "<a>x</a> <p><b>y</b></p>", "b" => mark_safe("<a>x</a> <p><b>y</b></p>"))) == "x y x y"
    # test_striptags02
    @test rt("{% autoescape off %}{{ a|striptags }} {{ b|striptags }}{% endautoescape %}", Dict{Any,Any}("a" => "<a>x</a> <p><b>y</b></p>", "b" => mark_safe("<a>x</a> <p><b>y</b></p>"))) == "x y x y"
    # test_strip
    @test filt("striptags", "some <b>html</b> with <script>alert(\"You smell\")</script> disallowed <img /> tags") == "some html with alert(\"You smell\") disallowed  tags"
    # test_non_string_input
    @test filt("striptags", 123) == "123"
    # not translated: test_strip_lazy_string (call lazystr)
end

@testset "django template_tests: test_time" begin
    # test_time00
    @test rt("{{ dt|time }}", Dict{Any,Any}("dt" => Dates.Time(16, 25))) == "4:25 p.m."
    # test_time04
    @test rt("{{ t|time:\"P:e:O:T:Z\" }}", Dict{Any,Any}("t" => Dates.Time(4, 0))) == "4 a.m.::::"
    # test_time06
    @test rt("{{ obj|time:\"P:e:O:T:Z\" }}", Dict{Any,Any}("obj" => "non-datetime-value")) == ""
    # test_no_args
    @test filt("time", "") == ""
    @test filt("time", nothing) == ""
    # test_inputs
    @test filt("time", Dates.Time(13), "h") == "01"
    @test filt("time", Dates.Time(0), "h") == "12"
    # not translated: test_time00_l10n (with); test_time01 (Attribute); test_time02 (Attribute); test_time03 (call keywords); test_time05 (Attribute)
end

@testset "django template_tests: test_timesince" begin
    # test_no_args
    @test filt("timesince", nothing) == ""
    # test_explicit_date
    @test filt("timesince", DateTime(2005, 12, 29), DateTime(2005, 12, 30)) == "1 day"
    # not translated: test_timesince01 (call now); test_timesince02 (call now); test_timesince03 (call now); test_timesince04 (Attribute); test_timesince05 (Attribute); test_timesince06 (Attribute); test_timesince07 (Attribute); test_timesince08 (Attribute); test_timesince09 (Attribute); test_timesince10 (Attribute); test_timesince11 (Attribute); test_timesince12 (Attribute); test_timesince13 (Attribute); test_timesince14 (Attribute); test_timesince15 (Attribute); test_timesince16 (Attribute); test_timesince17 (Attribute); test_timesince18 (Attribute); test_timesince19 (Attribute); test_timesince20 (call keywords); test_since_now (call now)
end

@testset "django template_tests: test_timeuntil" begin
    # test_no_args
    @test filt("timeuntil", nothing) == ""
    # test_explicit_date
    @test filt("timeuntil", DateTime(2005, 12, 30), DateTime(2005, 12, 29)) == "1 day"
    # not translated: test_timeuntil01 (call now); test_timeuntil02 (call now); test_timeuntil03 (call now); test_timeuntil04 (Attribute); test_timeuntil05 (Attribute); test_timeuntil06 (Attribute); test_timeuntil07 (Attribute); test_timeuntil08 (Attribute); test_timeuntil09 (Attribute); test_timeuntil10 (Attribute); test_timeuntil11 (Attribute); test_timeuntil12 (Attribute); test_timeuntil13 (Attribute); test_timeuntil14 (Attribute); test_naive_aware_type_error (Attribute); test_aware_naive_type_error (Attribute); test_until_now (call now)
end

@testset "django template_tests: test_title" begin
    # test_title1
    @test rt("{{ a|title }}", Dict{Any,Any}("a" => "JOE'S CRAB SHACK")) == "Joe&#x27;s Crab Shack"
    # test_title2
    @test rt("{{ a|title }}", Dict{Any,Any}("a" => "555 WEST 53RD STREET")) == "555 West 53rd Street"
    # test_title
    @test filt("title", "a nice title, isn't it?") == "A Nice Title, Isn't It?"
    # test_unicode
    @test filt("title", "discothèque") == "Discothèque"
    # test_non_string_input
    @test filt("title", 123) == "123"
end

@testset "django template_tests: test_truncatechars_html" begin
    # test_truncate_zero
    @test filt("truncatechars_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 0) == ""
    # test_truncate
    @test filt("truncatechars_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 4) == "<p>one…</p>"
    # test_truncate2
    @test filt("truncatechars_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 9) == "<p>one <a href=\"#\">two …</a></p>"
    # test_truncate3
    @test filt("truncatechars_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 100) == "<p>one <a href=\"#\">two - three <br>four</a> five</p>"
    # test_truncate_unicode
    @test filt("truncatechars_html", "<b>Ångström</b> was here", 3) == "<b>Ån…</b>"
    # test_truncate_something
    @test filt("truncatechars_html", "a<b>b</b>c", 3) == "a<b>b</b>c"
    # test_invalid_arg
    @test filt("truncatechars_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", "a") == "<p>one <a href=\"#\">two - three <br>four</a> five</p>"
end

@testset "django template_tests: test_truncatechars" begin
    # test_truncatechars01
    @test rt("{{ a|truncatechars:3 }}", Dict{Any,Any}("a" => "Testing, testing")) == "Te…"
    # test_truncatechars02
    @test rt("{{ a|truncatechars:7 }}", Dict{Any,Any}("a" => "Testing")) == "Testing"
    # test_fail_silently_incorrect_arg
    @test rt("{{ a|truncatechars:'e' }}", Dict{Any,Any}("a" => "Testing, testing")) == "Testing, testing"
    # test_truncatechars04
    @test rt("{{ a|truncatechars:3 }}", Dict{Any,Any}("a" => "abc")) == "abc"
end

@testset "django template_tests: test_truncatewords_html" begin
    # test_truncate_zero
    @test filt("truncatewords_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 0) == ""
    # test_truncate
    @test filt("truncatewords_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 2) == "<p>one <a href=\"#\">two …</a></p>"
    # test_truncate2
    @test filt("truncatewords_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 4) == "<p>one <a href=\"#\">two - three <br> …</a></p>"
    # test_truncate3
    @test filt("truncatewords_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 5) == "<p>one <a href=\"#\">two - three <br>four</a> …</p>"
    # test_truncate4
    @test filt("truncatewords_html", "<p>one <a href=\"#\">two - three <br>four</a> five</p>", 100) == "<p>one <a href=\"#\">two - three <br>four</a> five</p>"
    # test_truncate_unicode
    @test filt("truncatewords_html", "Ångström was here", 1) == "Ångström …"
    # test_truncate_complex
    @test filt("truncatewords_html", "<i>Buenos d&iacute;as! &#x00bf;C&oacute;mo est&aacute;?</i>", 3) == "<i>Buenos días! ¿Cómo …</i>"
    # test_invalid_arg
    @test filt("truncatewords_html", "<p>string</p>", "a") == "<p>string</p>"
end

@testset "django template_tests: test_truncatewords" begin
    # test_truncatewords01
    @test rt("{% autoescape off %}{{ a|truncatewords:\"2\" }} {{ b|truncatewords:\"2\"}}{% endautoescape %}", Dict{Any,Any}("a" => "alpha & bravo", "b" => mark_safe("alpha &amp; bravo"))) == "alpha & … alpha &amp; …"
    # test_truncatewords02
    @test rt("{{ a|truncatewords:\"2\" }} {{ b|truncatewords:\"2\"}}", Dict{Any,Any}("a" => "alpha & bravo", "b" => mark_safe("alpha &amp; bravo"))) == "alpha &amp; … alpha &amp; …"
    # test_truncate
    @test filt("truncatewords", "A sentence with a few words in it", 1) == "A …"
    # test_truncate2
    @test filt("truncatewords", "A sentence with a few words in it", 5) == "A sentence with a few …"
    # test_overtruncate
    @test filt("truncatewords", "A sentence with a few words in it", 100) == "A sentence with a few words in it"
    # test_invalid_number
    @test filt("truncatewords", "A sentence with a few words in it", "not a number") == "A sentence with a few words in it"
    # test_non_string_input
    @test filt("truncatewords", 123, 2) == "123"
end

@testset "django template_tests: test_unordered_list" begin
    # test_unordered_list01
    @test rt("{{ a|unordered_list }}", Dict{Any,Any}("a" => Any["x>", Any["<y"]])) == "\t<li>x&gt;\n\t<ul>\n\t\t<li>&lt;y</li>\n\t</ul>\n\t</li>"
    # test_unordered_list02
    @test rt("{% autoescape off %}{{ a|unordered_list }}{% endautoescape %}", Dict{Any,Any}("a" => Any["x>", Any["<y"]])) == "\t<li>x>\n\t<ul>\n\t\t<li><y</li>\n\t</ul>\n\t</li>"
    # test_unordered_list03
    @test rt("{{ a|unordered_list }}", Dict{Any,Any}("a" => Any["x>", Any[mark_safe("<y")]])) == "\t<li>x&gt;\n\t<ul>\n\t\t<li><y</li>\n\t</ul>\n\t</li>"
    # test_unordered_list04
    @test rt("{% autoescape off %}{{ a|unordered_list }}{% endautoescape %}", Dict{Any,Any}("a" => Any["x>", Any[mark_safe("<y")]])) == "\t<li>x>\n\t<ul>\n\t\t<li><y</li>\n\t</ul>\n\t</li>"
    # test_unordered_list05
    @test rt("{% autoescape off %}{{ a|unordered_list }}{% endautoescape %}", Dict{Any,Any}("a" => Any["x>", Any["<y"]])) == "\t<li>x>\n\t<ul>\n\t\t<li><y</li>\n\t</ul>\n\t</li>"
    # test_list
    @test filt("unordered_list", Any["item 1", "item 2"]) == "\t<li>item 1</li>\n\t<li>item 2</li>"
    # test_list_gettext
    @test filt("unordered_list", Any["item 1", gettext_lazy("item 2")]) == "\t<li>item 1</li>\n\t<li>item 2</li>"
    # test_nested
    @test filt("unordered_list", Any["item 1", Any["item 1.1"]]) == "\t<li>item 1\n\t<ul>\n\t\t<li>item 1.1</li>\n\t</ul>\n\t</li>"
    # test_nested2
    @test filt("unordered_list", Any["item 1", Any["item 1.1", "item1.2"], "item 2"]) == "\t<li>item 1\n\t<ul>\n\t\t<li>item 1.1</li>\n\t\t<li>item1.2</li>\n\t</ul>\n\t</li>\n\t<li>item 2</li>"
    # test_nested3
    @test filt("unordered_list", Any["item 1", "item 2", Any["item 2.1"]]) == "\t<li>item 1</li>\n\t<li>item 2\n\t<ul>\n\t\t<li>item 2.1</li>\n\t</ul>\n\t</li>"
    # test_nested_multiple
    @test filt("unordered_list", Any["item 1", Any["item 1.1", Any["item 1.1.1", Any["item 1.1.1.1"]]]]) == "\t<li>item 1\n\t<ul>\n\t\t<li>item 1.1\n\t\t<ul>\n\t\t\t<li>item 1.1.1\n\t\t\t<ul>\n\t\t\t\t<li>item 1.1.1.1</li>\n\t\t\t</ul>\n\t\t\t</li>\n\t\t</ul>\n\t\t</li>\n\t</ul>\n\t</li>"
    # test_nested_multiple2
    @test filt("unordered_list", Any["States", Any["Kansas", Any["Lawrence", "Topeka"], "Illinois"]]) == "\t<li>States\n\t<ul>\n\t\t<li>Kansas\n\t\t<ul>\n\t\t\t<li>Lawrence</li>\n\t\t\t<li>Topeka</li>\n\t\t</ul>\n\t\t</li>\n\t\t<li>Illinois</li>\n\t</ul>\n\t</li>"
    # test_autoescape
    @test filt("unordered_list", Any["<a>item 1</a>", "item 2"]) == "\t<li>&lt;a&gt;item 1&lt;/a&gt;</li>\n\t<li>item 2</li>"
    # test_autoescape_off
    @test filt("unordered_list", Any["<a>item 1</a>", "item 2"]; autoescape = false) == "\t<li><a>item 1</a></li>\n\t<li>item 2</li>"
    # not translated: test_ulitem (ClassDef); test_nested_generators (FunctionDef); test_non_iterable_list_subclass (ClassDef); test_ulitem_autoescape_off (ClassDef)
end

@testset "django template_tests: test_upper" begin
    # test_upper01
    @test rt("{% autoescape off %}{{ a|upper }} {{ b|upper }}{% endautoescape %}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "A & B A &AMP; B"
    # test_upper02
    @test rt("{{ a|upper }} {{ b|upper }}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "A &amp; B A &amp;AMP; B"
    # test_upper
    @test filt("upper", "Mixed case input") == "MIXED CASE INPUT"
    # test_unicode
    @test filt("upper", "ë") == "Ë"
    # test_non_string_input
    @test filt("upper", 123) == "123"
end

@testset "django template_tests: test_urlencode" begin
    # test_urlencode01
    @test rt("{{ url|urlencode }}", Dict{Any,Any}("url" => "/test&\"/me?/")) == "/test%26%22/me%3F/"
    # test_urlencode02
    @test rt("/test/{{ urlbit|urlencode:\"\" }}/", Dict{Any,Any}("urlbit" => "escape/slash")) == "/test/escape%2Fslash/"
    # test_urlencode
    @test filt("urlencode", "françois & jill") == "fran%C3%A7ois%20%26%20jill"
    # test_non_string_input
    @test filt("urlencode", 1) == "1"
end

@testset "django template_tests: test_urlize" begin
    # test_urlize01
    @test rt("{% autoescape off %}{{ a|urlize }} {{ b|urlize }}{% endautoescape %}", Dict{Any,Any}("a" => "http://example.com/?x=&y=", "b" => mark_safe("http://example.com?x=&amp;y=&lt;2&gt;"))) == "<a href=\"http://example.com/?x=&amp;y=\" rel=\"nofollow\">http://example.com/?x=&y=</a> <a href=\"http://example.com?x=&amp;y=%3C2%3E\" rel=\"nofollow\">http://example.com?x=&amp;y=&lt;2&gt;</a>"
    # test_urlize02
    @test rt("{{ a|urlize }} {{ b|urlize }}", Dict{Any,Any}("a" => "http://example.com/?x=&y=", "b" => mark_safe("http://example.com?x=&amp;y="))) == "<a href=\"http://example.com/?x=&amp;y=\" rel=\"nofollow\">http://example.com/?x=&amp;y=</a> <a href=\"http://example.com?x=&amp;y=\" rel=\"nofollow\">http://example.com?x=&amp;y=</a>"
    # test_urlize03
    @test rt("{% autoescape off %}{{ a|urlize }}{% endautoescape %}", Dict{Any,Any}("a" => mark_safe("a &amp; b"))) == "a &amp; b"
    # test_urlize04
    @test rt("{{ a|urlize }}", Dict{Any,Any}("a" => mark_safe("a &amp; b"))) == "a &amp; b"
    # test_urlize05
    @test rt("{% autoescape off %}{{ a|urlize }}{% endautoescape %}", Dict{Any,Any}("a" => "<script>alert('foo')</script>")) == "<script>alert('foo')</script>"
    # test_urlize06
    @test rt("{{ a|urlize }}", Dict{Any,Any}("a" => "<script>alert('foo')</script>")) == "&lt;script&gt;alert(&#x27;foo&#x27;)&lt;/script&gt;"
    # test_urlize07
    @test rt("{{ a|urlize }}", Dict{Any,Any}("a" => "Email me at me@example.com")) == "Email me at <a href=\"mailto:me@example.com\">me@example.com</a>"
    # test_urlize08
    @test rt("{{ a|urlize }}", Dict{Any,Any}("a" => "Email me at <me@example.com>")) == "Email me at &lt;<a href=\"mailto:me@example.com\">me@example.com</a>&gt;"
    # test_urlize09
    @test rt("{% autoescape off %}{{ a|urlize }}{% endautoescape %}", Dict{Any,Any}("a" => "http://example.com/?x=&amp;y=&lt;2&gt;")) == "<a href=\"http://example.com/?x=&amp;y=%3C2%3E\" rel=\"nofollow\">http://example.com/?x=&amp;y=&lt;2&gt;</a>"
    # test_urls
    @test filt("urlize", "http://google.com") == "<a href=\"http://google.com\" rel=\"nofollow\">http://google.com</a>"
    @test filt("urlize", "http://google.com/") == "<a href=\"http://google.com/\" rel=\"nofollow\">http://google.com/</a>"
    @test filt("urlize", "www.google.com") == "<a href=\"https://www.google.com\" rel=\"nofollow\">www.google.com</a>"
    @test filt("urlize", "djangoproject.org") == "<a href=\"https://djangoproject.org\" rel=\"nofollow\">djangoproject.org</a>"
    @test filt("urlize", "djangoproject.org/") == "<a href=\"https://djangoproject.org/\" rel=\"nofollow\">djangoproject.org/</a>"
    # test_url_split_chars
    @test filt("urlize", "www.server.com\"abc") == "<a href=\"https://www.server.com\" rel=\"nofollow\">www.server.com</a>&quot;abc"
    @test filt("urlize", "www.server.com'abc") == "<a href=\"https://www.server.com\" rel=\"nofollow\">www.server.com</a>&#x27;abc"
    @test filt("urlize", "www.server.com<abc") == "<a href=\"https://www.server.com\" rel=\"nofollow\">www.server.com</a>&lt;abc"
    @test filt("urlize", "www.server.com>abc") == "<a href=\"https://www.server.com\" rel=\"nofollow\">www.server.com</a>&gt;abc"
    # test_email
    @test filt("urlize", "info@djangoproject.org") == "<a href=\"mailto:info@djangoproject.org\">info@djangoproject.org</a>"
    # test_word_with_dot
    @test filt("urlize", "some.organization") == "some.organization"
    # test_https
    @test filt("urlize", "https://google.com") == "<a href=\"https://google.com\" rel=\"nofollow\">https://google.com</a>"
    # test_quoting
    @test filt("urlize", "http://hi.baidu.com/%E9%87%8D%E6%96%B0%E5%BC%80%E5%A7%8B") == "<a href=\"http://hi.baidu.com/%E9%87%8D%E6%96%B0%E5%BC%80%E5%A7%8B\" rel=\"nofollow\">http://hi.baidu.com/%E9%87%8D%E6%96%B0%E5%BC%80%E5%A7%8B</a>"
    # test_urlencoded
    @test filt("urlize", "www.mystore.com/30%OffCoupons!") == "<a href=\"https://www.mystore.com/30%25OffCoupons\" rel=\"nofollow\">www.mystore.com/30%OffCoupons</a>!"
    @test filt("urlize", "https://en.wikipedia.org/wiki/Caf%C3%A9") == "<a href=\"https://en.wikipedia.org/wiki/Caf%C3%A9\" rel=\"nofollow\">https://en.wikipedia.org/wiki/Caf%C3%A9</a>"
    # test_unicode
    @test filt("urlize", "https://en.wikipedia.org/wiki/Café") == "<a href=\"https://en.wikipedia.org/wiki/Caf%C3%A9\" rel=\"nofollow\">https://en.wikipedia.org/wiki/Café</a>"
    # test_parenthesis
    @test filt("urlize", "https://en.wikipedia.org/wiki/Django_(web_framework)") == "<a href=\"https://en.wikipedia.org/wiki/Django_(web_framework)\" rel=\"nofollow\">https://en.wikipedia.org/wiki/Django_(web_framework)</a>"
    @test filt("urlize", "(see https://en.wikipedia.org/wiki/Django_(web_framework))") == "(see <a href=\"https://en.wikipedia.org/wiki/Django_(web_framework)\" rel=\"nofollow\">https://en.wikipedia.org/wiki/Django_(web_framework)</a>)"
    # test_parenthesis_and_bracket
    @test filt("urlize", "[(https://en.wikipedia.org/)]") == "[(<a href=\"https://en.wikipedia.org/\" rel=\"nofollow\">https://en.wikipedia.org/</a>)]"
    # test_nofollow
    @test filt("urlize", "foo@bar.com or www.bar.com") == "<a href=\"mailto:foo@bar.com\">foo@bar.com</a> or <a href=\"https://www.bar.com\" rel=\"nofollow\">www.bar.com</a>"
    # test_idn
    @test filt("urlize", "http://c✶.ws") == "<a href=\"http://c%E2%9C%B6.ws\" rel=\"nofollow\">http://c✶.ws</a>"
    @test filt("urlize", "www.c✶.ws") == "<a href=\"https://www.c%E2%9C%B6.ws\" rel=\"nofollow\">www.c✶.ws</a>"
    @test filt("urlize", "c✶.org") == "<a href=\"https://c%E2%9C%B6.org\" rel=\"nofollow\">c✶.org</a>"
    @test filt("urlize", "info@c✶.org") == "<a href=\"mailto:info@c%E2%9C%B6.org\">info@c✶.org</a>"
    @test filt("urlize", "www.xn--iny-zx5a.com/idna2003") == "<a href=\"https://www.xn--iny-zx5a.com/idna2003\" rel=\"nofollow\">www.xn--iny-zx5a.com/idna2003</a>"
    @test filt("urlize", "www.xn--fa-hia.com/idna2008") == "<a href=\"https://www.xn--fa-hia.com/idna2008\" rel=\"nofollow\">www.xn--fa-hia.com/idna2008</a>"
    # test_malformed
    @test filt("urlize", "http:///www.google.com") == "http:///www.google.com"
    @test filt("urlize", "http://.google.com") == "http://.google.com"
    @test filt("urlize", "http://@foo.com") == "http://@foo.com"
    # test_tlds
    @test filt("urlize", "usa.gov") == "<a href=\"https://usa.gov\" rel=\"nofollow\">usa.gov</a>"
    # test_invalid_email
    @test filt("urlize", "email@.stream.ru") == "email@.stream.ru"
    # test_uppercase
    @test filt("urlize", "HTTPS://github.com/") == "<a href=\"https://github.com/\" rel=\"nofollow\">HTTPS://github.com/</a>"
    # test_trailing_period
    @test filt("urlize", "(Go to http://www.example.com/foo.)") == "(Go to <a href=\"http://www.example.com/foo\" rel=\"nofollow\">http://www.example.com/foo</a>.)"
    # test_trailing_multiple_punctuation
    @test filt("urlize", "A test http://testing.com/example..") == "A test <a href=\"http://testing.com/example\" rel=\"nofollow\">http://testing.com/example</a>.."
    @test filt("urlize", "A test http://testing.com/example!!") == "A test <a href=\"http://testing.com/example\" rel=\"nofollow\">http://testing.com/example</a>!!"
    @test filt("urlize", "A test http://testing.com/example!!!") == "A test <a href=\"http://testing.com/example\" rel=\"nofollow\">http://testing.com/example</a>!!!"
    @test filt("urlize", "A test http://testing.com/example.,:;)\"!") == "A test <a href=\"http://testing.com/example\" rel=\"nofollow\">http://testing.com/example</a>.,:;)&quot;!"
    # test_trailing_semicolon
    @test filt("urlize", "http://example.com?x=&amp;"; autoescape = false) == "<a href=\"http://example.com?x=\" rel=\"nofollow\">http://example.com?x=&amp;</a>"
    @test filt("urlize", "http://example.com?x=&amp;;"; autoescape = false) == "<a href=\"http://example.com?x=\" rel=\"nofollow\">http://example.com?x=&amp;</a>;"
    @test filt("urlize", "http://example.com?x=&amp;;;"; autoescape = false) == "<a href=\"http://example.com?x=\" rel=\"nofollow\">http://example.com?x=&amp;</a>;;"
    @test filt("urlize", "http://example.com?x=&amp.;...;"; autoescape = false) == "<a href=\"http://example.com?x=\" rel=\"nofollow\">http://example.com?x=&amp</a>.;...;"
    # test_brackets
    @test filt("urlize", "[see www.example.com]") == "[see <a href=\"https://www.example.com\" rel=\"nofollow\">www.example.com</a>]"
    @test filt("urlize", "see test[at[example.com") == "see test[at[example.com"
    @test filt("urlize", "[http://168.192.0.1](http://168.192.0.1)") == "[<a href=\"http://168.192.0.1](http://168.192.0.1)\" rel=\"nofollow\">http://168.192.0.1](http://168.192.0.1)</a>"
    # test_ipv4
    @test filt("urlize", "http://192.168.0.15/api/9") == "<a href=\"http://192.168.0.15/api/9\" rel=\"nofollow\">http://192.168.0.15/api/9</a>"
    # test_ipv6
    @test filt("urlize", "http://[2001:db8:cafe::2]/api/9") == "<a href=\"http://[2001:db8:cafe::2]/api/9\" rel=\"nofollow\">http://[2001:db8:cafe::2]/api/9</a>"
    # test_quotation_marks
    @test filt("urlize", "before \"hi@example.com\" afterward"; autoescape = false) == "before \"<a href=\"mailto:hi@example.com\">hi@example.com</a>\" afterward"
    @test filt("urlize", "before hi@example.com\" afterward"; autoescape = false) == "before <a href=\"mailto:hi@example.com\">hi@example.com</a>\" afterward"
    @test filt("urlize", "before \"hi@example.com afterward"; autoescape = false) == "before \"<a href=\"mailto:hi@example.com\">hi@example.com</a> afterward"
    @test filt("urlize", "before 'hi@example.com' afterward"; autoescape = false) == "before '<a href=\"mailto:hi@example.com\">hi@example.com</a>' afterward"
    @test filt("urlize", "before hi@example.com' afterward"; autoescape = false) == "before <a href=\"mailto:hi@example.com\">hi@example.com</a>' afterward"
    @test filt("urlize", "before 'hi@example.com afterward"; autoescape = false) == "before '<a href=\"mailto:hi@example.com\">hi@example.com</a> afterward"
    # test_quote_commas
    @test filt("urlize", "Email us at \"hi@example.com\", or phone us at +xx.yy"; autoescape = false) == "Email us at \"<a href=\"mailto:hi@example.com\">hi@example.com</a>\", or phone us at +xx.yy"
    # test_exclamation_marks
    @test filt("urlize", "Go to djangoproject.com! and enjoy.") == "Go to <a href=\"https://djangoproject.com\" rel=\"nofollow\">djangoproject.com</a>! and enjoy."
    @test filt("urlize", "Search for google.com/?q=! and see.") == "Search for <a href=\"https://google.com/?q=\" rel=\"nofollow\">google.com/?q=</a>! and see."
    @test filt("urlize", "Search for google.com/?q=dj!`? and see.") == "Search for <a href=\"https://google.com/?q=dj%21%60%3F\" rel=\"nofollow\">google.com/?q=dj!`?</a> and see."
    @test filt("urlize", "Search for google.com/?q=dj!`?! and see.") == "Search for <a href=\"https://google.com/?q=dj%21%60%3F\" rel=\"nofollow\">google.com/?q=dj!`?</a>! and see."
    # test_non_string_input
    @test filt("urlize", 123) == "123"
    # test_autoescape
    @test filt("urlize", "foo<a href=\" google.com \">bar</a>buz") == "foo&lt;a href=&quot; <a href=\"https://google.com\" rel=\"nofollow\">google.com</a> &quot;&gt;bar&lt;/a&gt;buz"
    # test_autoescape_off
    @test filt("urlize", "foo<a href=\" google.com \">bar</a>buz"; autoescape = false) == "foo<a href=\" <a href=\"https://google.com\" rel=\"nofollow\">google.com</a> \">bar</a>buz"
    # not translated: test_wrapping_characters (For); test_lazystring (call lazy); test_caching_repeated_words (Expr); test_caching_repeated_calls (Expr)
end

@testset "django template_tests: test_urlizetrunc" begin
    # test_urlizetrunc01
    @test rt("{% autoescape off %}{{ a|urlizetrunc:\"8\" }} {{ b|urlizetrunc:\"8\" }}{% endautoescape %}", Dict{Any,Any}("a" => "\"Unsafe\" http://example.com/x=&y=", "b" => mark_safe("&quot;Safe&quot; http://example.com?x=&amp;y="))) == "\"Unsafe\" <a href=\"http://example.com/x=&amp;y=\" rel=\"nofollow\">http://…</a> &quot;Safe&quot; <a href=\"http://example.com?x=&amp;y=\" rel=\"nofollow\">http://…</a>"
    # test_urlizetrunc02
    @test rt("{{ a|urlizetrunc:\"8\" }} {{ b|urlizetrunc:\"8\" }}", Dict{Any,Any}("a" => "\"Unsafe\" http://example.com/x=&y=", "b" => mark_safe("&quot;Safe&quot; http://example.com?x=&amp;y="))) == "&quot;Unsafe&quot; <a href=\"http://example.com/x=&amp;y=\" rel=\"nofollow\">http://…</a> &quot;Safe&quot; <a href=\"http://example.com?x=&amp;y=\" rel=\"nofollow\">http://…</a>"
    # test_overtruncate
    @test filt("urlizetrunc", "http://short.com/", 20) == "<a href=\"http://short.com/\" rel=\"nofollow\">http://short.com/</a>"
    # test_query_string
    @test filt("urlizetrunc", "http://www.google.co.uk/search?hl=en&q=some+long+url&btnG=Search&meta=", 20) == "<a href=\"http://www.google.co.uk/search?hl=en&amp;q=some+long+url&amp;btnG=Search&amp;meta=\" rel=\"nofollow\">http://www.google.c…</a>"
    # test_non_string_input
    @test filt("urlizetrunc", 123, 1) == "123"
    # test_autoescape
    @test filt("urlizetrunc", "foo<a href=\" google.com \">bar</a>buz", 10) == "foo&lt;a href=&quot; <a href=\"https://google.com\" rel=\"nofollow\">google.com</a> &quot;&gt;bar&lt;/a&gt;buz"
    # test_autoescape_off
    @test filt("urlizetrunc", "foo<a href=\" google.com \">bar</a>buz", 9; autoescape = false) == "foo<a href=\" <a href=\"https://google.com\" rel=\"nofollow\">google.c…</a> \">bar</a>buz"
    # not translated: test_truncate (call len)
end

@testset "django template_tests: test_wordcount" begin
    # test_wordcount01
    @test rt("{% autoescape off %}{{ a|wordcount }} {{ b|wordcount }}{% endautoescape %}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "3 3"
    # test_wordcount02
    @test rt("{{ a|wordcount }} {{ b|wordcount }}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a &amp; b"))) == "3 3"
    # test_empty_string
    @test filt("wordcount", "") == 0
    # test_count_one
    @test filt("wordcount", "oneword") == 1
    # test_count_multiple
    @test filt("wordcount", "lots of words") == 3
    # test_non_string_input
    @test filt("wordcount", 123) == 1
end

@testset "django template_tests: test_wordwrap" begin
    # test_wordwrap01
    @test rt("{% autoescape off %}{{ a|wordwrap:\"3\" }} {{ b|wordwrap:\"3\" }}{% endautoescape %}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a & b"))) == "a &\nb a &\nb"
    # test_wordwrap02
    @test rt("{{ a|wordwrap:\"3\" }} {{ b|wordwrap:\"3\" }}", Dict{Any,Any}("a" => "a & b", "b" => mark_safe("a & b"))) == "a &amp;\nb a &\nb"
    # test_wrap
    @test filt("wordwrap", "this is a long paragraph of text that really needs to be wrapped I'm afraid", 14) == "this is a long\nparagraph of\ntext that\nreally needs\nto be wrapped\nI'm afraid"
    # test_indent
    @test filt("wordwrap", "this is a short paragraph of text.\n  But this line should be indented", 14) == "this is a\nshort\nparagraph of\ntext.\n  But this\nline should be\nindented"
    # test_indent2
    @test filt("wordwrap", "this is a short paragraph of text.\n  But this line should be indented", 15) == "this is a short\nparagraph of\ntext.\n  But this line\nshould be\nindented"
    # test_non_string_input
    @test filt("wordwrap", 123, 2) == "123"
    # not translated: test_wrap_lazy_string (call lazystr); test_wrap_long_text (method assertIn); test_wrap_preserve_newlines (For); test_wrap_preserve_whitespace (f-string)
end

@testset "django template_tests: test_yesno" begin
    # test_true
    @test rt("{{ var|yesno:\"yup,nup,mup\" }} {{ var|yesno }}", Dict{Any,Any}("var" => true)) == "yup yes"
    # test_true
    @test filt("yesno", true) == "yes"
    # test_false
    @test filt("yesno", false) == "no"
    # test_none
    @test filt("yesno", nothing) == "maybe"
    # test_true_arguments
    @test filt("yesno", true, "certainly,get out of town,perhaps") == "certainly"
    # test_false_arguments
    @test filt("yesno", false, "certainly,get out of town,perhaps") == "get out of town"
    # test_none_two_arguments
    @test filt("yesno", nothing, "certainly,get out of town") == "get out of town"
    # test_none_three_arguments
    @test filt("yesno", nothing, "certainly,get out of town,perhaps") == "perhaps"
    # not translated: test_invalid_value (method assertIsNone)
end

@testset "django template_tests: test_autoescape" begin
    # test_autoescape_tag01
    @test rt("{% autoescape off %}hello{% endautoescape %}", Dict{Any,Any}()) == "hello"
    # test_autoescape_tag02
    @test rt("{% autoescape off %}{{ first }}{% endautoescape %}", Dict{Any,Any}("first" => "<b>hello</b>")) == "<b>hello</b>"
    # test_autoescape_tag03
    @test rt("{% autoescape on %}{{ first }}{% endautoescape %}", Dict{Any,Any}("first" => "<b>hello</b>")) == "&lt;b&gt;hello&lt;/b&gt;"
    # test_autoescape_tag04
    @test rt("{% autoescape off %}{{ first }} {% autoescape on %}{{ first }}{% endautoescape %}{% endautoescape %}", Dict{Any,Any}("first" => "<a>")) == "<a> &lt;a&gt;"
    # test_autoescape_tag05
    @test rt("{% autoescape on %}{{ first }}{% endautoescape %}", Dict{Any,Any}("first" => "<b>first</b>")) == "&lt;b&gt;first&lt;/b&gt;"
    # test_autoescape_tag06
    @test rt("{{ first }}", Dict{Any,Any}("first" => mark_safe("<b>first</b>"))) == "<b>first</b>"
    # test_autoescape_tag07
    @test rt("{% autoescape on %}{{ first }}{% endautoescape %}", Dict{Any,Any}("first" => mark_safe("<b>Apple</b>"))) == "<b>Apple</b>"
    # test_autoescape_tag08
    @test rt("{% autoescape on %}{{ var|default_if_none:\" endquote\\\" hah\" }}{% endautoescape %}", Dict{Any,Any}("var" => nothing)) == " endquote\" hah"
    # test_autoescape_filtertag01
    @test_throws Juango.TemplateSyntaxError rt("{{ first }}{% filter safe %}{{ first }} x<y{% endfilter %}", Dict{Any,Any}("first" => "<a>"))
    # test_autoescape_filters01
    @test rt("{{ var|cut:\"&\" }}", Dict{Any,Any}("var" => "this & that")) == "this  that"
    # test_autoescape_filters02
    @test rt("{{ var|join:\" & \" }}", Dict{Any,Any}("var" => ("Tom", "Dick", "Harry"))) == "Tom & Dick & Harry"
    # test_autoescape_literals01
    @test rt("{{ \"this & that\" }}", Dict{Any,Any}()) == "this & that"
    # test_autoescape_stringiterations01
    @test rt("{% for l in var %}{{ l }},{% endfor %}", Dict{Any,Any}("var" => "K&R")) == "K,&amp;,R,"
    # test_autoescape_lookup01
    @test rt("{{ var.key }}", Dict{Any,Any}("var" => Dict{Any,Any}("key" => "this & that"))) == "this &amp; that"
    # test_invalid_arg
    @test_throws Juango.TemplateSyntaxError rt("{% autoescape true %}{{ var.key }}{% endautoescape %}", Dict{Any,Any}("var" => Dict{Any,Any}("key" => "this & that")))
    # test_no_arg
    @test_throws Juango.TemplateSyntaxError rt("{% autoescape %}{{ var.key }}{% endautoescape %}", Dict{Any,Any}("var" => Dict{Any,Any}("key" => "this & that")))
    # not translated: test_autoescape_tag09 (call UnsafeClass); test_autoescape_tag10 (call SafeClass)
end

@testset "django template_tests: test_basic" begin
    # test_basic_syntax01
    @test rtn(Dict("basic-syntax01" => "something cool", "basic-syntax02" => "{{ headline }}", "basic-syntax03" => "{{ first }} --- {{ second }}"), "basic-syntax01", Dict{Any,Any}()) == "something cool"
    # test_basic_syntax02
    @test rtn(Dict("basic-syntax01" => "something cool", "basic-syntax02" => "{{ headline }}", "basic-syntax03" => "{{ first }} --- {{ second }}"), "basic-syntax02", Dict{Any,Any}("headline" => "Success")) == "Success"
    # test_basic_syntax03
    @test rtn(Dict("basic-syntax01" => "something cool", "basic-syntax02" => "{{ headline }}", "basic-syntax03" => "{{ first }} --- {{ second }}"), "basic-syntax03", Dict{Any,Any}("first" => 1, "second" => 2)) == "1 --- 2"
    # test_basic_syntax04
    @test rt("as{{ missing }}df", Dict{Any,Any}()) == "asdf"
    # test_basic_syntax06
    @test_throws Juango.TemplateSyntaxError rt("{{ multi word variable }}", Dict{Any,Any}())
    # test_basic_syntax07
    @test_throws Juango.TemplateSyntaxError rt("{{ }}", Dict{Any,Any}())
    # test_basic_syntax08
    @test_throws Juango.TemplateSyntaxError rt("{{        }}", Dict{Any,Any}())
    # test_basic_syntax12
    @test_throws Juango.TemplateSyntaxError rt("{{ var.__dict__ }}", Dict{Any,Any}())
    # test_basic_syntax13
    @test_throws Juango.TemplateSyntaxError rt("{{ va>r }}", Dict{Any,Any}())
    # test_basic_syntax14
    @test_throws Juango.TemplateSyntaxError rt("{{ (var.r) }}", Dict{Any,Any}())
    # test_basic_syntax15
    @test_throws Juango.TemplateSyntaxError rt("{{ sp%am }}", Dict{Any,Any}())
    # test_basic_syntax16
    @test_throws Juango.TemplateSyntaxError rt("{{ eggs! }}", Dict{Any,Any}())
    # test_basic_syntax17
    @test_throws Juango.TemplateSyntaxError rt("{{ moo? }}", Dict{Any,Any}())
    # test_basic_syntax18
    @test rt("{{ foo.bar }}", Dict{Any,Any}("foo" => Dict{Any,Any}("bar" => "baz"))) == "baz"
    # test_basic_syntax19
    @test rt("{{ foo.spam }}", Dict{Any,Any}("foo" => Dict{Any,Any}("bar" => "baz"))) == ""
    # test_basic_syntax21
    @test rt("a {{ moo %} b", Dict{Any,Any}()) == "a {{ moo %} b"
    # test_basic_syntax22
    @test rt("{{ moo #}", Dict{Any,Any}()) == "{{ moo #}"
    # test_basic_syntax23
    @test_throws Juango.TemplateSyntaxError rt("{{ moo #} {{ cow }}", Dict{Any,Any}())
    # test_basic_syntax24
    @test rt("{{ moo\n }}", Dict{Any,Any}()) == "{{ moo\n }}"
    # test_basic_syntax25
    @test rt("{{ \"fred\" }}", Dict{Any,Any}()) == "fred"
    # test_basic_syntax26
    @test rt("{{ \"\\\"fred\\\"\" }}", Dict{Any,Any}()) == "\"fred\""
    # test_basic_syntax27
    @test rt("{{ _(\"\\\"fred\\\"\") }}", Dict{Any,Any}()) == "\"fred\""
    # test_basic_syntax30
    @test rt("{{ 1.2.3 }}", Dict{Any,Any}("1" => Dict{Any,Any}("2" => Dict{Any,Any}("3" => "d")))) == "d"
    # test_basic_syntax31
    @test rt("{{ 1.2.3 }}", Dict{Any,Any}("1" => Dict{Any,Any}("2" => ("a", "b", "c", "d")))) == "d"
    # test_basic_syntax32
    @test rt("{{ 1.2.3 }}", Dict{Any,Any}("1" => (("x", "x", "x", "x"), ("y", "y", "y", "y"), ("a", "b", "c", "d")))) == "d"
    # test_basic_syntax33
    @test rt("{{ 1.2.3 }}", Dict{Any,Any}("1" => ("xxxx", "yyyy", "abcd"))) == "d"
    # test_basic_syntax34
    @test rt("{{ 1.2.3 }}", Dict{Any,Any}("1" => (Dict{Any,Any}("x" => "x"), Dict{Any,Any}("y" => "y"), Dict{Any,Any}("z" => "z", "3" => "d")))) == "d"
    # test_basic_syntax35
    @test rt("{{ 1 }}", Dict{Any,Any}("1" => "abc")) == "1"
    # test_basic_syntax36
    @test rt("{{ 1.2 }}", Dict{Any,Any}("1" => "abc")) == "1.2"
    # test_unclosed_multiline_block_tag_error_suggests_templatetag
    @test_throws Juango.TemplateSyntaxError rt("The open tag: {%\nif user %}", Dict{Any,Any}())
    # test_multiline_block_tag_error_inside_block
    @test_throws Juango.TemplateSyntaxError rt("{% if user %}\n<p>The open tag: {%</p>\n<p>The close tag: %}</p>\n{% endif %}", Dict{Any,Any}())
    # test_multiline_block_tag_error_message
    @test_throws Juango.TemplateSyntaxError rt("<p>The open tag: {%</p>\n<p>The close tag: %}</p>", Dict{Any,Any}())
    # test_block_tags_rendered_as_text
    @test rt("<p>The open tag: {% templatetag openblock %}</p>\n<p>The close tag: {% templatetag closeblock %}</p>", Dict{Any,Any}()) == "<p>The open tag: {%</p>\n<p>The close tag: %}</p>"
    # test_unclosed_block
    @test_throws Juango.TemplateSyntaxError rt("{% block content %}", Dict{Any,Any}())
    # test_unclosed_block2
    @test_throws Juango.TemplateSyntaxError rt("{% if a %}", Dict{Any,Any}())
    # test_ignores_strings_that_look_like_format_interpolation
    @test rtn(Dict("tpl-str" => "%s", "tpl-percent" => "%%", "tpl-weird-percent" => "% %s"), "tpl-str", Dict{Any,Any}()) == "%s"
    @test rtn(Dict("tpl-str" => "%s", "tpl-percent" => "%%", "tpl-weird-percent" => "% %s"), "tpl-percent", Dict{Any,Any}()) == "%%"
    @test rtn(Dict("tpl-str" => "%s", "tpl-percent" => "%%", "tpl-weird-percent" => "% %s"), "tpl-weird-percent", Dict{Any,Any}()) == "% %s"
    # not translated: test_basic_syntax09 (call SomeClass); test_basic_syntax10 (call SomeClass); test_basic_syntax11 (call SomeClass); test_basic_syntax20 (call SomeClass); test_basic_syntax20b (call get_template); test_basic_syntax28 (call SilentGetItemClass); test_basic_syntax29 (call SilentAttrClass); test_basic_syntax37 (Lambda); test_basic_syntax38 (Lambda); test_multiline_block_tags (for body); test_multiline_block_tag_between_literal_braces (for body); test_multiline_block_tag_message_truncates_source (malformed node or string on line 412: <ast.BinOp object at 0x7f618d45a250>); test_multiline_block_tag_debug_info (call keywords); test_allow_multiline_tags_disabled (for body); test_subscriptable_class (ClassDef); test_access_class_property_if_getitem_is_defined_in_metaclass (ClassDef); test_double_dot_lookup (for body); test_double_dot_in_literal (call Engine); test_repr (call BlockContext); test_template_name_in_error_message (f-string); test_template_name_not_in_debug_view (Try); test_unknown_source_template (Try); test_double_dot_lookup (call Context)
end

@testset "django template_tests: test_builtins" begin
    # test_builtins01
    @test_broken rt("{{ True }}", Dict{Any,Any}()) == "True"      # (a Juango difference)
    # test_builtins02
    @test_broken rt("{{ False }}", Dict{Any,Any}()) == "False"      # (a Juango difference)
    # test_builtins03
    @test_broken rt("{{ None }}", Dict{Any,Any}()) == "None"      # (a Juango difference)
end

@testset "django template_tests: test_cache" begin
    # test_cache03
    @test rt("{% load cache %}{% cache 2 test %}cache03{% endcache %}", Dict{Any,Any}()) == "cache03"
    # test_cache05
    @test rt("{% load cache %}{% cache 2 test foo %}cache05{% endcache %}", Dict{Any,Any}("foo" => 1)) == "cache05"
    # test_cache06
    @test rt("{% load cache %}{% cache 2 test foo %}cache06{% endcache %}", Dict{Any,Any}("foo" => 2)) == "cache06"
    # test_cache11
    @test_throws Juango.TemplateSyntaxError rt("{% load cache %}{% cache %}{% endcache %}", Dict{Any,Any}())
    # test_cache12
    @test_throws Juango.TemplateSyntaxError rt("{% load cache %}{% cache 1 %}{% endcache %}", Dict{Any,Any}())
    # test_cache13
    @test_throws Juango.TemplateSyntaxError rt("{% load cache %}{% cache foo bar %}{% endcache %}", Dict{Any,Any}())
    # test_cache14
    @test_throws Juango.TemplateSyntaxError rt("{% load cache %}{% cache foo bar %}{% endcache %}", Dict{Any,Any}("foo" => "fail"))
    # test_cache15
    @test_throws Juango.TemplateSyntaxError rt("{% load cache %}{% cache foo bar %}{% endcache %}", Dict{Any,Any}("foo" => Any[]))
    # test_cache16
    @test rt("{% load cache %}{% cache 1 foo bar %}{% endcache %}", Dict{Any,Any}("foo" => "foo", "bar" => "with spaces")) == ""
    # test_cache17
    @test rt("{% load cache %}{% cache 10 long_cache_key poem %}Some Content{% endcache %}", Dict{Any,Any}("poem" => "Oh freddled gruntbuggly/Thy micturations are to me/As plurdled gabbleblotchits/On a lurgid bee/That mordiously hath bitled out/Its earted jurtles/Into a rancid festering/Or else I shall rend thee in the gobberwarts with my blurglecruncheon/See if I don't.")) == "Some Content"
    # test_cache18
    @test rt("{% load cache custom %}{% cache 2|noop:\"x y\" cache18 %}cache18{% endcache %}", Dict{Any,Any}()) == "cache18"
    # test_none_timeout
    @test rtn(Dict("first" => "{% load cache %}{% cache None fragment19 %}content{% endcache %}", "second" => "{% load cache %}{% cache None fragment19 %}not rendered{% endcache %}"), "first", Dict{Any,Any}()) == "content"
    @test rtn(Dict("first" => "{% load cache %}{% cache None fragment19 %}content{% endcache %}", "second" => "{% load cache %}{% cache None fragment19 %}not rendered{% endcache %}"), "second", Dict{Any,Any}()) == "content"
    # not translated: test_cache04 (method render_to_string); test_cache07 (method render_to_string); test_cache08 (method render_to_string); test_cache_regression_20130 (call from_string); test_cache_fragment_cache (call from_string); test_cache_missing_backend (call from_string)
end

@testset "django template_tests: test_comment" begin
    # test_comment_syntax01
    @test rt("{# this is hidden #}hello", Dict{Any,Any}()) == "hello"
    # test_comment_syntax02
    @test rt("{# this is hidden #}hello{# foo #}", Dict{Any,Any}()) == "hello"
    # test_comment_syntax03
    @test rt("foo{#  {% if %}  #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax04
    @test rt("foo{#  {% endblock %}  #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax05
    @test rt("foo{#  {% somerandomtag %}  #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax06
    @test rt("foo{# {% #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax07
    @test rt("foo{# %} #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax08
    @test rt("foo{# %} #}bar", Dict{Any,Any}()) == "foobar"
    # test_comment_syntax09
    @test rt("foo{# {{ #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax10
    @test rt("foo{# }} #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax11
    @test rt("foo{# { #}", Dict{Any,Any}()) == "foo"
    # test_comment_syntax12
    @test rt("foo{# } #}", Dict{Any,Any}()) == "foo"
    # test_comment_tag01
    @test rt("{% comment %}this is hidden{% endcomment %}hello", Dict{Any,Any}()) == "hello"
    # test_comment_tag02
    @test rt("{% comment %}this is hidden{% endcomment %}hello{% comment %}foo{% endcomment %}", Dict{Any,Any}()) == "hello"
    # test_comment_tag03
    @test rt("foo{% comment %} {% if %} {% endcomment %}", Dict{Any,Any}()) == "foo"
    # test_comment_tag04
    @test rt("foo{% comment %} {% endblock %} {% endcomment %}", Dict{Any,Any}()) == "foo"
    # test_comment_tag05
    @test rt("foo{% comment %} {% somerandomtag %} {% endcomment %}", Dict{Any,Any}()) == "foo"
    # test_closing_tag_after_literal_opening_brace
    @test rt("{% comment %}{{% endcomment %}visible", Dict{Any,Any}()) == "visible"
    # test_multiline_raw_block_closing_tags
    @test rt("{% comment %}content{%\nendcomment\n%}", Dict{Any,Any}()) == ""
    # test_template_syntax_in_raw_blocks
    @test rt("{% comment %}\n{% if user %}Hello, {{ user }}{% endif %}\n{% endcomment %}", Dict{Any,Any}()) == ""
    # test_literal_multiline_block_opener_in_raw_blocks
    @test rt("{% comment %}\n{%\n{% endcomment %}", Dict{Any,Any}()) == ""
    # not translated: test_tags_without_spaces (for body)
end

@testset "django template_tests: test_csp_nonce_attr" begin

    # not translated: test_with_nonce_in_context (call Template); test_without_csp_nonce_in_context (call Template); test_with_csp_nonce_none (call Template); test_nonce_is_escaped (call Template); test_with_nonce_in_context (call keywords); test_without_csp_nonce_in_context (call keywords); test_with_csp_nonce_none (call keywords); test_css_and_js (call keywords); test_with_script_object (call keywords); test_output_is_safe (call keywords); test_script_with_conflicting_nonce_raises (call keywords)
end

@testset "django template_tests: test_cycle" begin
    # test_cycle01
    @test_throws Juango.TemplateSyntaxError rt("{% cycle a %}", Dict{Any,Any}())
    # test_cycle05
    @test_throws Juango.TemplateSyntaxError rt("{% cycle %}", Dict{Any,Any}())
    # test_cycle07
    @test_throws Juango.TemplateSyntaxError rt("{% cycle a,b,c as foo %}{% cycle bar %}", Dict{Any,Any}())
    # test_cycle10
    @test rt("{% cycle 'a' 'b' 'c' as abc %}{% cycle abc %}", Dict{Any,Any}()) == "ab"
    # test_cycle11
    @test rt("{% cycle 'a' 'b' 'c' as abc %}{% cycle abc %}{% cycle abc %}", Dict{Any,Any}()) == "abc"
    # test_cycle12
    @test rt("{% cycle 'a' 'b' 'c' as abc %}{% cycle abc %}{% cycle abc %}{% cycle abc %}", Dict{Any,Any}()) == "abca"
    # test_cycle14
    @test rt("{% cycle one two as foo %}{% cycle foo %}", Dict{Any,Any}("one" => "1", "two" => "2")) == "12"
    # test_cycle16
    @test rt("{% cycle one|lower two as foo %}{% cycle foo %}", Dict{Any,Any}("one" => "A", "two" => "2")) == "a2"
    # test_cycle17
    @test rt("{% cycle 'a' 'b' 'c' as abc silent %}{% cycle abc %}{% cycle abc %}{% cycle abc %}{% cycle abc %}", Dict{Any,Any}()) == ""
    # test_cycle18
    @test_throws Juango.TemplateSyntaxError rt("{% cycle 'a' 'b' 'c' as foo invalid_flag %}", Dict{Any,Any}())
    # test_cycle19
    @test rt("{% cycle 'a' 'b' as silent %}{% cycle silent %}", Dict{Any,Any}()) == "ab"
    # test_cycle20
    @test rt("{% cycle one two as foo %} &amp; {% cycle foo %}", Dict{Any,Any}("two" => "C & D", "one" => "A & B")) == "A &amp; B &amp; C &amp; D"
    # test_cycle21
    @test rt("{% filter force_escape %}{% cycle one two as foo %} & {% cycle foo %}{% endfilter %}", Dict{Any,Any}("two" => "C & D", "one" => "A & B")) == "A &amp;amp; B &amp; C &amp;amp; D"
    # test_cycle22
    @test rt("{% for x in values %}{% cycle 'a' 'b' 'c' as abc silent %}{{ x }}{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3, 4])) == "1234"
    # test_cycle23
    @test rt("{% for x in values %}{% cycle 'a' 'b' 'c' as abc silent %}{{ abc }}{{ x }}{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3, 4])) == "a1b2c3a4"
    # test_cycle24
    @test rtn(Dict("cycle24" => "{% for x in values %}{% cycle 'a' 'b' 'c' as abc silent %}{% include 'included-cycle' %}{% endfor %}", "included-cycle" => "{{ abc }}"), "cycle24", Dict{Any,Any}("values" => Any[1, 2, 3, 4])) == "abca"
    # test_cycle25
    @test rt("{% cycle a as abc %}", Dict{Any,Any}("a" => "<")) == "&lt;"
    # test_cycle26
    @test rt("{% cycle a b as ab %}{% cycle ab %}", Dict{Any,Any}("a" => "<", "b" => ">")) == "&lt;&gt;"
    # test_cycle27
    @test rt("{% autoescape off %}{% cycle a b as ab %}{% cycle ab %}{% endautoescape %}", Dict{Any,Any}("a" => "<", "b" => ">")) == "<>"
    # test_cycle28
    @test rt("{% cycle a|safe b as ab %}{% cycle ab %}", Dict{Any,Any}("a" => "<", "b" => ">")) == "<&gt;"
    # test_cycle29
    @test rt("{% cycle 'a' 'b' 'c' as cycler silent %}{% for x in values %}{% ifchanged x %}{% cycle cycler %}{{ cycler }}{% else %}{{ cycler }}{% endifchanged %}{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3, 4, 5, 6, 7, 8, 8, 8, 9, 9])) == "bcabcabcccaa"
    # test_cycle30
    @test rt("{% cycle 'a' 'b' 'c' as cycler silent %}{% for x in values %}{% with doesnothing=irrelevant %}{% ifchanged x %}{% cycle cycler %}{{ cycler }}{% else %}{{ cycler }}{% endifchanged %}{% endwith %}{% endfor %}", Dict{Any,Any}("irrelevant" => 1, "values" => Any[1, 2, 3, 4, 5, 6, 7, 8, 8, 8, 9, 9])) == "bcabcabcccaa"
    # test_cycle_undefined
    @test_throws Juango.TemplateSyntaxError rt("{% cycle 'a' 'b' 'c' as cycler silent %}{% for x in values %}{% cycle undefined %}{{ cycler }}{% endfor %}", Dict{Any,Any}())
    # not translated: test_cycle13 (call list); test_cycle15 (call list)
end

@testset "django template_tests: test_debug" begin
    # test_non_debug
    let old = Juango.settings.DEBUG
        configure!(DEBUG = false)
        try
    @test rt("{% debug %}", Dict{Any,Any}()) == ""
        finally
            configure!(DEBUG = old)
        end
    end
    # not translated: test_modules (method assertIn); test_plain (method assertTrue); test_non_ascii (call keywords); test_script (method assertTrue)
end

@testset "django template_tests: test_exceptions" begin
    # test_exception01
    @test_throws Juango.TemplateDoesNotExist rt("{% extends 'nonexistent' %}", Dict{Any,Any}())
    # test_exception02
    @test_throws Juango.TemplateSyntaxError rt("{% extends nonexistent %}", Dict{Any,Any}())
    # test_exception05
    @test_throws Juango.TemplateSyntaxError rt("{% block first %}{{ block.super }}{% endblock %}", Dict{Any,Any}())
    # not translated: test_exception03 (setup arg); test_exception04 (setup arg); test_unknown_origin_relative_path (For)
end

@testset "django template_tests: test_extends" begin
    # test_inheritance01
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance01", Dict{Any,Any}()) == "1&3_"
    # test_inheritance02
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance02", Dict{Any,Any}()) == "1234"
    # test_inheritance03
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance03", Dict{Any,Any}()) == "1234"
    # test_inheritance04
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance04", Dict{Any,Any}()) == "1&3_"
    # test_inheritance05
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance05", Dict{Any,Any}()) == "1234"
    # test_inheritance06
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance06", Dict{Any,Any}("foo" => "inheritance02")) == "1234"
    # test_inheritance07
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance07", Dict{Any,Any}()) == "1&35"
    # test_inheritance08
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance08", Dict{Any,Any}()) == "1235"
    # test_inheritance09
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance09", Dict{Any,Any}()) == "1&3_"
    # test_inheritance10
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance10", Dict{Any,Any}()) == "1&3_"
    # test_inheritance11
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance11", Dict{Any,Any}()) == "1234"
    # test_inheritance12
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance12", Dict{Any,Any}()) == "1235"
    # test_inheritance13
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance13", Dict{Any,Any}()) == "1a3b"
    # test_inheritance14
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance14", Dict{Any,Any}()) == "1&3_"
    # test_inheritance15
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance15", Dict{Any,Any}()) == "12inner3_"
    # test_inheritance16
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance16", Dict{Any,Any}()) == "12out3_"
    # test_inheritance17
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance17", Dict{Any,Any}()) == "1234"
    # test_inheritance18
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance18", Dict{Any,Any}()) == "this that theother5678"
    # test_inheritance19
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance19", Dict{Any,Any}()) == "140056783_"
    # test_inheritance20
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance20", Dict{Any,Any}()) == "1&a3_"
    # test_inheritance21
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance21", Dict{Any,Any}()) == "12a34"
    # test_inheritance22
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance22", Dict{Any,Any}()) == "1&a3_"
    # test_inheritance23
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance23", Dict{Any,Any}()) == "1&ab3_"
    # test_inheritance26
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance26", Dict{Any,Any}()) == "no tags"
    # test_inheritance27
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance27", Dict{Any,Any}()) == "no tags"
    # test_inheritance_28
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance 28", Dict{Any,Any}()) == "!"
    # test_inheritance29
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance29", Dict{Any,Any}()) == "!"
    # test_inheritance30
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance30", Dict{Any,Any}("optional" => true)) == "123"
    # test_inheritance31
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance31", Dict{Any,Any}("optional" => true)) == "1two3"
    # test_inheritance32
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance32", Dict{Any,Any}()) == "13"
    # test_inheritance33
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance33", Dict{Any,Any}("optional" => 1)) == "123"
    # test_inheritance34
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance34", Dict{Any,Any}("optional" => 1)) == "1two3"
    # test_inheritance35
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance35", Dict{Any,Any}("optional" => 2)) == "13"
    # test_inheritance36
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance36", Dict{Any,Any}("numbers" => "123")) == "_1_2_3_"
    # test_inheritance37
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance37", Dict{Any,Any}("numbers" => "123")) == "_X_X_X_"
    # test_inheritance38
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance38", Dict{Any,Any}()) == "_"
    # test_inheritance39
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance39", Dict{Any,Any}("optional" => true)) == "1new23"
    # test_inheritance40
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance40", Dict{Any,Any}("optional" => 1)) == "1new23"
    # test_inheritance41
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance41", Dict{Any,Any}("numbers" => "123")) == "_new1_new2_new3_"
    # test_inheritance42
    @test rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance42", Dict{Any,Any}()) == "1234"
    # test_inheritance_empty
    @test_throws Juango.TemplateSyntaxError rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "inheritance_empty", Dict{Any,Any}())
    # test_extends_duplicate
    @test_throws Juango.TemplateSyntaxError rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "extends_duplicate", Dict{Any,Any}())
    # test_duplicate_block
    @test_throws Juango.TemplateSyntaxError rtn(Dict("inheritance01" => "1{% block first %}&{% endblock %}3{% block second %}_{% endblock %}", "inheritance02" => "{% extends 'inheritance01' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance03" => "{% extends 'inheritance02' %}", "inheritance04" => "{% extends 'inheritance01' %}", "inheritance05" => "{% extends 'inheritance02' %}", "inheritance06" => "{% extends foo %}", "inheritance07" => "{% extends 'inheritance01' %}{% block second %}5{% endblock %}", "inheritance08" => "{% extends 'inheritance02' %}{% block second %}5{% endblock %}", "inheritance09" => "{% extends 'inheritance04' %}", "inheritance10" => "{% extends 'inheritance04' %}      ", "inheritance11" => "{% extends 'inheritance04' %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance12" => "{% extends 'inheritance07' %}{% block first %}2{% endblock %}", "inheritance13" => "{% extends 'inheritance02' %}{% block first %}a{% endblock %}{% block second %}b{% endblock %}", "inheritance14" => "{% extends 'inheritance01' %}{% block newblock %}NO DISPLAY{% endblock %}", "inheritance15" => "{% extends 'inheritance01' %}{% block first %}2{% block inner %}inner{% endblock %}{% endblock %}", "inheritance16" => "{% extends 'inheritance15' %}{% block inner %}out{% endblock %}", "inheritance17" => "{% load testtags %}{% block first %}1234{% endblock %}", "inheritance18" => "{% load testtags %}{% echo this that theother %}5678", "inheritance19" => "{% extends 'inheritance01' %}{% block first %}{% load testtags %}{% echo 400 %}5678{% endblock %}", "inheritance20" => "{% extends 'inheritance01' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance21" => "{% extends 'inheritance02' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance22" => "{% extends 'inheritance04' %}{% block first %}{{ block.super }}a{% endblock %}", "inheritance23" => "{% extends 'inheritance20' %}{% block first %}{{ block.super }}b{% endblock %}", "inheritance24" => "{% extends context_template %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance25" => "{% extends context_template.1 %}{% block first %}2{% endblock %}{% block second %}4{% endblock %}", "inheritance26" => "no tags", "inheritance27" => "{% extends 'inheritance26' %}", "inheritance 28" => "{% block first %}!{% endblock %}", "inheritance29" => "{% extends 'inheritance 28' %}", "inheritance30" => "1{% if optional %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance31" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance32" => "{% extends 'inheritance30' %}{% block opt %}two{% endblock %}", "inheritance33" => "1{% if optional == 1 %}{% block opt %}2{% endblock %}{% endif %}3", "inheritance34" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance35" => "{% extends 'inheritance33' %}{% block opt %}two{% endblock %}", "inheritance36" => "{% for n in numbers %}_{% block opt %}{{ n }}{% endblock %}{% endfor %}_", "inheritance37" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance38" => "{% extends 'inheritance36' %}{% block opt %}X{% endblock %}", "inheritance39" => "{% extends 'inheritance30' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance40" => "{% extends 'inheritance33' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance41" => "{% extends 'inheritance36' %}{% block opt %}new{{ block.super }}{% endblock %}", "inheritance42" => "{% extends 'inheritance02'|cut:' ' %}", "inheritance_empty" => "{% extends %}", "extends_duplicate" => "{% extends 'base.html' %}{% extends 'base.html' %}", "duplicate_block" => "{% extends 'base.html' %}{% block content %}2{% endblock %}{% block content %}4{% endblock %}"), "duplicate_block", Dict{Any,Any}())
    # not translated: test_inheritance24 (call from_string); test_inheritance25 (call from_string); test_extends_node_repr (call keywords)
end

@testset "django template_tests: test_filter_syntax" begin
    # test_filter_syntax01
    @test rt("{{ var|upper }}", Dict{Any,Any}("var" => "Django is the greatest!")) == "DJANGO IS THE GREATEST!"
    # test_filter_syntax02
    @test rt("{{ var|upper|lower }}", Dict{Any,Any}("var" => "Django is the greatest!")) == "django is the greatest!"
    # test_filter_syntax03
    @test rt("{{ var |upper }}", Dict{Any,Any}("var" => "Django is the greatest!")) == "DJANGO IS THE GREATEST!"
    # test_filter_syntax04
    @test rt("{{ var| upper }}", Dict{Any,Any}("var" => "Django is the greatest!")) == "DJANGO IS THE GREATEST!"
    # test_filter_syntax05
    @test_throws Juango.TemplateSyntaxError rt("{{ var|does_not_exist }}", Dict{Any,Any}())
    # test_filter_syntax06
    @test_throws Juango.TemplateSyntaxError rt("{{ var|fil(ter) }}", Dict{Any,Any}())
    # test_filter_syntax07
    @test_throws Juango.TemplateSyntaxError rt("{% nothing_to_see_here %}", Dict{Any,Any}())
    # test_filter_syntax08
    @test_throws Juango.TemplateSyntaxError rt("{% %}", Dict{Any,Any}())
    # test_filter_syntax08_multi_line
    @test_throws Juango.TemplateSyntaxError rt("line 1\nline 2\nline 3{% %}\nline 4\nline 5", Dict{Any,Any}())
    # test_filter_syntax09
    @test rt("{{ var|cut:\"o\"|upper|lower }}", Dict{Any,Any}("var" => "Foo")) == "f"
    # test_filter_syntax10
    @test rt("{{ var|default_if_none:\" endquote\\\" hah\" }}", Dict{Any,Any}("var" => nothing)) == " endquote\" hah"
    # test_filter_syntax11
    @test rt("{{ var|default_if_none:var2 }}", Dict{Any,Any}("var" => nothing, "var2" => "happy")) == "happy"
    # test_filter_syntax15
    @test rt("{{ var|default_if_none:\"foo\\bar\" }}", Dict{Any,Any}("var" => nothing)) == "foo\\bar"
    # test_filter_syntax16
    @test rt("{{ var|default_if_none:\"foo\\now\" }}", Dict{Any,Any}("var" => nothing)) == "foo\\now"
    # test_filter_syntax17
    @test rt("{{ var|join:\"\" }}", Dict{Any,Any}("var" => Any["a", "b", "c"])) == "abc"
    # test_filter_syntax19
    @test rt("{{ var|truncatewords:1 }}", Dict{Any,Any}("var" => "hello world")) == "hello …"
    # test_filter_syntax20
    @test rt("{{ \"\"|default_if_none:\"was none\" }}", Dict{Any,Any}()) == ""
    # not translated: test_filter_syntax13 (call SomeClass); test_filter_syntax14 (call SomeClass); test_filter_syntax18 (call UTF8Class); test_filter_syntax21 (call SomeClass); test_filter_syntax22 (call SomeClass); test_filter_syntax23 (call SomeClass); test_filter_syntax24 (call SomeClass); test_filter_syntax25 (call SomeClass); test_type_error_attribute (call SomeClass)
end

@testset "django template_tests: test_filter_tag" begin
    # test_filter01
    @test rt("{% filter upper %}{% endfilter %}", Dict{Any,Any}()) == ""
    # test_filter02
    @test rt("{% filter upper %}django{% endfilter %}", Dict{Any,Any}()) == "DJANGO"
    # test_filter03
    @test rt("{% filter upper|lower %}django{% endfilter %}", Dict{Any,Any}()) == "django"
    # test_filter04
    @test rt("{% filter cut:remove %}djangospam{% endfilter %}", Dict{Any,Any}("remove" => "spam")) == "django"
    # test_filter05
    @test_throws Juango.TemplateSyntaxError rt("{% filter safe %}fail{% endfilter %}", Dict{Any,Any}())
    # test_filter05bis
    @test_throws Juango.TemplateSyntaxError rt("{% filter upper|safe %}fail{% endfilter %}", Dict{Any,Any}())
    # test_filter06
    @test_throws Juango.TemplateSyntaxError rt("{% filter escape %}fail{% endfilter %}", Dict{Any,Any}())
    # test_filter06bis
    @test_throws Juango.TemplateSyntaxError rt("{% filter upper|escape %}fail{% endfilter %}", Dict{Any,Any}())
end

@testset "django template_tests: test_firstof" begin
    # test_firstof01
    @test rt("{% firstof a b c %}", Dict{Any,Any}("a" => 0, "c" => 0, "b" => 0)) == ""
    # test_firstof02
    @test rt("{% firstof a b c %}", Dict{Any,Any}("a" => 1, "c" => 0, "b" => 0)) == "1"
    # test_firstof03
    @test rt("{% firstof a b c %}", Dict{Any,Any}("a" => 0, "c" => 0, "b" => 2)) == "2"
    # test_firstof04
    @test rt("{% firstof a b c %}", Dict{Any,Any}("a" => 0, "c" => 3, "b" => 0)) == "3"
    # test_firstof05
    @test rt("{% firstof a b c %}", Dict{Any,Any}("a" => 1, "c" => 3, "b" => 2)) == "1"
    # test_firstof06
    @test rt("{% firstof a b c %}", Dict{Any,Any}("c" => 3, "b" => 0)) == "3"
    # test_firstof07
    @test rt("{% firstof a b \"c\" %}", Dict{Any,Any}("a" => 0)) == "c"
    # test_firstof08
    @test rt("{% firstof a b \"c and d\" %}", Dict{Any,Any}("a" => 0, "b" => 0)) == "c and d"
    # test_firstof09
    @test_throws Juango.TemplateSyntaxError rt("{% firstof %}", Dict{Any,Any}())
    # test_firstof_asvar_no_args
    @test_throws Juango.TemplateSyntaxError rt("{% firstof as myvar %}", Dict{Any,Any}())
    # test_firstof10
    @test rt("{% firstof a %}", Dict{Any,Any}("a" => "<")) == "&lt;"
    # test_firstof11
    @test rt("{% firstof a b %}", Dict{Any,Any}("a" => "<", "b" => ">")) == "&lt;"
    # test_firstof12
    @test rt("{% firstof a b %}", Dict{Any,Any}("a" => "", "b" => ">")) == "&gt;"
    # test_firstof13
    @test rt("{% autoescape off %}{% firstof a %}{% endautoescape %}", Dict{Any,Any}("a" => "<")) == "<"
    # test_firstof14
    @test rt("{% firstof a|safe b %}", Dict{Any,Any}("a" => "<")) == "<"
    # not translated: test_firstof15 (Subscript); test_all_false_arguments_asvar (Subscript)
end

@testset "django template_tests: test_for" begin
    # test_for_tag01
    @test rt("{% for val in values %}{{ val }}{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3])) == "123"
    # test_for_tag02
    @test rt("{% for val in values reversed %}{{ val }}{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3])) == "321"
    # test_for_tag_vars01
    @test rt("{% for val in values %}{{ forloop.counter }}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "123"
    # test_for_tag_vars02
    @test rt("{% for val in values %}{{ forloop.counter0 }}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "012"
    # test_for_tag_vars03
    @test rt("{% for val in values %}{{ forloop.revcounter }}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "321"
    # test_for_tag_vars04
    @test rt("{% for val in values %}{{ forloop.revcounter0 }}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "210"
    # test_for_tag_vars05
    @test rt("{% for val in values %}{% if forloop.first %}f{% else %}x{% endif %}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "fxx"
    # test_for_tag_vars06
    @test rt("{% for val in values %}{% if forloop.last %}l{% else %}x{% endif %}{% endfor %}", Dict{Any,Any}("values" => Any[6, 6, 6])) == "xxl"
    # test_for_tag_unpack01
    @test rt("{% for key,value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2)))) == "one:1/two:2/"
    # test_for_tag_unpack03
    @test rt("{% for key, value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2)))) == "one:1/two:2/"
    # test_for_tag_unpack04
    @test rt("{% for key , value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2)))) == "one:1/two:2/"
    # test_for_tag_unpack05
    @test rt("{% for key ,value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2)))) == "one:1/two:2/"
    # test_for_tag_unpack06
    @test_throws Juango.TemplateSyntaxError rt("{% for key value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2))))
    # test_for_tag_unpack07
    @test_throws Juango.TemplateSyntaxError rt("{% for key,,value in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2))))
    # test_for_tag_unpack08
    @test_throws Juango.TemplateSyntaxError rt("{% for key,value, in items %}{{ key }}:{{ value }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2))))
    # test_unpack_double_quote
    @test_throws Juango.TemplateSyntaxError rt("{% for \"k\" in items %}{{ \"k\" }}/{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # test_unpack_single_quote
    @test_throws Juango.TemplateSyntaxError rt("{% for 'k' in items %}{{ k }}/{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # test_unpack_vertical_bar
    @test_throws Juango.TemplateSyntaxError rt("{% for k|upper in items %}{{ k|upper }}/{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # test_for_tag_unpack09
    @test rt("{% for val in items %}{{ val.0 }}:{{ val.1 }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2)))) == "one:1/two:2/"
    # test_for_tag_unpack13
    @test rt("{% for x,y,z in items %}{{ x }}:{{ y }},{{ z }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1, "carrot"), ("two", 2, "cheese")))) == "one:1,carrot/two:2,cheese/"
    # test_for_tag_empty01
    @test rt("{% for val in values %}{{ val }}{% empty %}empty text{% endfor %}", Dict{Any,Any}("values" => Any[1, 2, 3])) == "123"
    # test_for_tag_empty02
    @test rt("{% for val in values %}{{ val }}{% empty %}values array empty{% endfor %}", Dict{Any,Any}("values" => Any[])) == "values array empty"
    # test_for_tag_empty03
    @test rt("{% for val in values %}{{ val }}{% empty %}values array not found{% endfor %}", Dict{Any,Any}()) == "values array not found"
    # test_for_tag_filter_ws
    @test rt("{% load custom %}{% for x in s|noop:'x y' %}{{ x }}{% endfor %}", Dict{Any,Any}("s" => "abc")) == "abc"
    # test_for_tag_unpack_strs
    @test rt("{% for x,y in items %}{{ x }}:{{ y }}/{% endfor %}", Dict{Any,Any}("items" => ("ab", "ac"))) == "a:b/a:c/"
    # test_for_tag_unpack10
    @test_throws Exception rt("{% for x,y in items %}{{ x }}:{{ y }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1, "carrot"), ("two", 2, "orange"))))
    # test_for_tag_unpack11
    @test_throws Exception rt("{% for x,y,z in items %}{{ x }}:{{ y }},{{ z }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1), ("two", 2))))
    # test_for_tag_unpack12
    @test_throws Exception rt("{% for x,y,z in items %}{{ x }}:{{ y }},{{ z }}/{% endfor %}", Dict{Any,Any}("items" => (("one", 1, "carrot"), ("two", 2))))
    # test_for_tag_unpack14
    @test_throws Exception rt("{% for x,y in items %}{{ x }}:{{ y }}/{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # test_for_tag_context
    @test rtn(Dict("main" => "{% with alpha=alpha.values %}{% include \"base\" %}{% endwith %}_{% with alpha=alpha.extra %}{% include \"base\" %}{% endwith %}", "base" => "{% for x, y in alpha %}{{ x }}:{{ y }},{% endfor %}"), "main", Dict{Any,Any}("alpha" => Dict{Any,Any}("values" => Any[("two", 2), ("four", 4)], "extra" => Any[("six", 6), ("eight", 8)]))) == "two:2,four:4,_six:6,eight:8,"
    # test_invalid_arg
    @test_throws Juango.TemplateSyntaxError rt("{% for x items %}{{ x }}{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # test_invalid_in_keyword
    @test_throws Juango.TemplateSyntaxError rt("{% for x from items %}{{ x }}{% endfor %}", Dict{Any,Any}("items" => (1, 2)))
    # not translated: test_forloop_length (For); test_repr (call keywords)
end

@testset "django template_tests: test_if_changed" begin
    # test_ifchanged01
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% endfor %}", Dict{Any,Any}("num" => (1, 2, 3))) == "123"
    # test_ifchanged02
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 3))) == "13"
    # test_ifchanged03
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 1))) == "1"
    # test_ifchanged04
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% for x in numx %}{% ifchanged %}{{ x }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 2, 3), "numx" => (2, 2, 2))) == "122232"
    # test_ifchanged05
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% for x in numx %}{% ifchanged %}{{ x }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 1), "numx" => (1, 2, 3))) == "1123123123"
    # test_ifchanged06
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% for x in numx %}{% ifchanged %}{{ x }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 1), "numx" => (2, 2, 2))) == "1222"
    # test_ifchanged07
    @test rt("{% for n in num %}{% ifchanged %}{{ n }}{% endifchanged %}{% for x in numx %}{% ifchanged %}{{ x }}{% endifchanged %}{% for y in numy %}{% ifchanged %}{{ y }}{% endifchanged %}{% endfor %}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 1), "numx" => (2, 2, 2), "numy" => (3, 3, 3))) == "1233323332333"
    # test_ifchanged08
    @test rt("{% for data in datalist %}{% for c,d in data %}{% if c %}{% ifchanged %}{{ d }}{% endifchanged %}{% endif %}{% endfor %}{% endfor %}", Dict{Any,Any}("datalist" => Any[Any[(1, "a"), (1, "a"), (0, "b"), (1, "c")], Any[(0, "a"), (1, "c"), (1, "d"), (1, "d"), (0, "e")]])) == "accd"
    # test_ifchanged_param01
    @test rt("{% for n in num %}{% ifchanged n %}..{% endifchanged %}{{ n }}{% endfor %}", Dict{Any,Any}("num" => (1, 2, 3))) == "..1..2..3"
    # test_ifchanged_param02
    @test rt("{% for n in num %}{% for x in numx %}{% ifchanged n %}..{% endifchanged %}{{ x }}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 2, 3), "numx" => (5, 6, 7))) == "..567..567..567"
    # test_ifchanged_param03
    @test rt("{% for n in num %}{{ n }}{% for x in numx %}{% ifchanged x n %}{{ x }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("num" => (1, 1, 2), "numx" => (5, 6, 6))) == "156156256"
    # test_ifchanged_param04
    @test rt("{% for d in days %}{% ifchanged %}{{ d.day }}{% endifchanged %}{% for h in d.hours %}{% ifchanged d h %}{{ h }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("days" => Any[Dict{Any,Any}("hours" => Any[1, 2, 3], "day" => 1), Dict{Any,Any}("hours" => Any[3], "day" => 2)])) == "112323"
    # test_ifchanged_param05
    @test rt("{% for d in days %}{% ifchanged d.day %}{{ d.day }}{% endifchanged %}{% for h in d.hours %}{% ifchanged d.day h %}{{ h }}{% endifchanged %}{% endfor %}{% endfor %}", Dict{Any,Any}("days" => Any[Dict{Any,Any}("hours" => Any[1, 2, 3], "day" => 1), Dict{Any,Any}("hours" => Any[3], "day" => 2)])) == "112323"
    # test_ifchanged_else01
    @test rt("{% for id in ids %}{{ id }}{% ifchanged id %}-first{% else %}-other{% endifchanged %},{% endfor %}", Dict{Any,Any}("ids" => Any[1, 1, 2, 2, 2, 3])) == "1-first,1-other,2-first,2-other,2-other,3-first,"
    # test_ifchanged_else02
    @test rt("{% for id in ids %}{{ id }}-{% ifchanged id %}{% cycle \"red\" \"blue\" %}{% else %}gray{% endifchanged %},{% endfor %}", Dict{Any,Any}("ids" => Any[1, 1, 2, 2, 2, 3])) == "1-red,1-gray,2-blue,2-gray,2-gray,3-red,"
    # test_ifchanged_else03
    @test rt("{% for id in ids %}{{ id }}{% ifchanged id %}-{% cycle \"red\" \"blue\" %}{% else %}{% endifchanged %},{% endfor %}", Dict{Any,Any}("ids" => Any[1, 1, 2, 2, 2, 3])) == "1-red,1,2-blue,2,2,3-red,"
    # test_ifchanged_else04
    @test rt("{% for id in ids %}{% ifchanged %}***{{ id }}*{% else %}...{% endifchanged %}{{ forloop.counter }}{% endfor %}", Dict{Any,Any}("ids" => Any[1, 1, 2, 2, 2, 3, 4])) == "***1*1...2***2*3...4...5***3*6***4*7"
    # test_ifchanged_filter_ws
    @test rt("{% load custom %}{% for n in num %}{% ifchanged n|noop:\"x y\" %}..{% endifchanged %}{{ n }}{% endfor %}", Dict{Any,Any}("num" => (1, 2, 3))) == "..1..2..3"
    # not translated: test_ifchanged_concurrency (call from_string); test_ifchanged_render_once (call from_string); test_include (call keywords); test_include_state (call keywords)
end

@testset "django template_tests: test_if" begin
    # test_if_tag01
    @test rt("{% if foo %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true)) == "yes"
    # test_if_tag02
    @test rt("{% if foo %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false)) == "no"
    # test_if_tag03
    @test rt("{% if foo %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag04
    @test rt("{% if foo %}foo{% elif bar %}bar{% endif %}", Dict{Any,Any}("foo" => true)) == "foo"
    # test_if_tag05
    @test rt("{% if foo %}foo{% elif bar %}bar{% endif %}", Dict{Any,Any}("bar" => true)) == "bar"
    # test_if_tag06
    @test rt("{% if foo %}foo{% elif bar %}bar{% endif %}", Dict{Any,Any}()) == ""
    # test_if_tag07
    @test rt("{% if foo %}foo{% elif bar %}bar{% else %}nothing{% endif %}", Dict{Any,Any}("foo" => true)) == "foo"
    # test_if_tag08
    @test rt("{% if foo %}foo{% elif bar %}bar{% else %}nothing{% endif %}", Dict{Any,Any}("bar" => true)) == "bar"
    # test_if_tag09
    @test rt("{% if foo %}foo{% elif bar %}bar{% else %}nothing{% endif %}", Dict{Any,Any}()) == "nothing"
    # test_if_tag10
    @test rt("{% if foo %}foo{% elif bar %}bar{% elif baz %}baz{% else %}nothing{% endif %}", Dict{Any,Any}("foo" => true)) == "foo"
    # test_if_tag11
    @test rt("{% if foo %}foo{% elif bar %}bar{% elif baz %}baz{% else %}nothing{% endif %}", Dict{Any,Any}("bar" => true)) == "bar"
    # test_if_tag12
    @test rt("{% if foo %}foo{% elif bar %}bar{% elif baz %}baz{% else %}nothing{% endif %}", Dict{Any,Any}("baz" => true)) == "baz"
    # test_if_tag13
    @test rt("{% if foo %}foo{% elif bar %}bar{% elif baz %}baz{% else %}nothing{% endif %}", Dict{Any,Any}()) == "nothing"
    # test_if_tag_filter01
    @test rt("{% if foo|length == 5 %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => "abcde")) == "yes"
    # test_if_tag_filter02
    @test rt("{% if foo|upper == 'ABC' %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_eq01
    @test rt("{% if foo == bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_eq02
    @test rt("{% if foo == bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1)) == "no"
    # test_if_tag_eq03
    @test rt("{% if foo == bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1, "bar" => 1)) == "yes"
    # test_if_tag_eq04
    @test rt("{% if foo == bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1, "bar" => 2)) == "no"
    # test_if_tag_eq05
    @test rt("{% if foo == '' %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_noteq01
    @test rt("{% if foo != bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_noteq02
    @test rt("{% if foo != bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1)) == "yes"
    # test_if_tag_noteq03
    @test rt("{% if foo != bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1, "bar" => 1)) == "no"
    # test_if_tag_noteq04
    @test rt("{% if foo != bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1, "bar" => 2)) == "yes"
    # test_if_tag_noteq05
    @test rt("{% if foo != \"\" %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_gt_01
    @test rt("{% if 2 > 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_gt_02
    @test rt("{% if 1 > 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_gte_01
    @test rt("{% if 1 >= 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_gte_02
    @test rt("{% if 1 >= 2 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_lt_01
    @test rt("{% if 1 < 2 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_lt_02
    @test rt("{% if 1 < 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_lte_01
    @test rt("{% if 1 <= 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_lte_02
    @test rt("{% if 2 <= 1 %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_in_01
    @test rt("{% if 1 in x %}yes{% else %}no{% endif %}", Dict{Any,Any}("x" => Any[1])) == "yes"
    # test_if_tag_in_02
    @test rt("{% if 2 in x %}yes{% else %}no{% endif %}", Dict{Any,Any}("x" => Any[1])) == "no"
    # test_if_tag_not_in_01
    @test rt("{% if 1 not in x %}yes{% else %}no{% endif %}", Dict{Any,Any}("x" => Any[1])) == "no"
    # test_if_tag_not_in_02
    @test rt("{% if 2 not in x %}yes{% else %}no{% endif %}", Dict{Any,Any}("x" => Any[1])) == "yes"
    # test_if_tag_and01
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "yes"
    # test_if_tag_and02
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "no"
    # test_if_tag_and03
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "no"
    # test_if_tag_and04
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "no"
    # test_if_tag_and05
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false)) == "no"
    # test_if_tag_and06
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("bar" => false)) == "no"
    # test_if_tag_and07
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true)) == "no"
    # test_if_tag_and08
    @test rt("{% if foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("bar" => true)) == "no"
    # test_if_tag_or01
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "yes"
    # test_if_tag_or02
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "yes"
    # test_if_tag_or03
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "yes"
    # test_if_tag_or04
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "no"
    # test_if_tag_or05
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false)) == "no"
    # test_if_tag_or06
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("bar" => false)) == "no"
    # test_if_tag_or07
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true)) == "yes"
    # test_if_tag_or08
    @test rt("{% if foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("bar" => true)) == "yes"
    # test_if_tag_or09
    @test rt("{% if foo or bar or baz %}yes{% else %}no{% endif %}", Dict{Any,Any}("baz" => true)) == "yes"
    # test_if_tag_not01
    @test rt("{% if not foo %}no{% else %}yes{% endif %}", Dict{Any,Any}("foo" => true)) == "yes"
    # test_if_tag_not02
    @test rt("{% if not not foo %}no{% else %}yes{% endif %}", Dict{Any,Any}("foo" => true)) == "no"
    # test_if_tag_not06
    @test rt("{% if foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_not07
    @test rt("{% if foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "no"
    # test_if_tag_not08
    @test rt("{% if foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "yes"
    # test_if_tag_not09
    @test rt("{% if foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "no"
    # test_if_tag_not10
    @test rt("{% if foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "no"
    # test_if_tag_not11
    @test rt("{% if not foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_not12
    @test rt("{% if not foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "no"
    # test_if_tag_not13
    @test rt("{% if not foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "no"
    # test_if_tag_not14
    @test rt("{% if not foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "yes"
    # test_if_tag_not15
    @test rt("{% if not foo and bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "no"
    # test_if_tag_not16
    @test rt("{% if foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_not17
    @test rt("{% if foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "yes"
    # test_if_tag_not18
    @test rt("{% if foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "yes"
    # test_if_tag_not19
    @test rt("{% if foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "no"
    # test_if_tag_not20
    @test rt("{% if foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "yes"
    # test_if_tag_not21
    @test rt("{% if not foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_not22
    @test rt("{% if not foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "yes"
    # test_if_tag_not23
    @test rt("{% if not foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "no"
    # test_if_tag_not24
    @test rt("{% if not foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "yes"
    # test_if_tag_not25
    @test rt("{% if not foo or bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "yes"
    # test_if_tag_not26
    @test rt("{% if not foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_not27
    @test rt("{% if not foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "no"
    # test_if_tag_not28
    @test rt("{% if not foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "no"
    # test_if_tag_not29
    @test rt("{% if not foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "no"
    # test_if_tag_not30
    @test rt("{% if not foo and not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "yes"
    # test_if_tag_not31
    @test rt("{% if not foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_tag_not32
    @test rt("{% if not foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => true)) == "no"
    # test_if_tag_not33
    @test rt("{% if not foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true, "bar" => false)) == "yes"
    # test_if_tag_not34
    @test rt("{% if not foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => true)) == "yes"
    # test_if_tag_not35
    @test rt("{% if not foo or not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false, "bar" => false)) == "yes"
    # test_if_tag_error01
    @test_throws Juango.TemplateSyntaxError rt("{% if %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error02
    @test_throws Juango.TemplateSyntaxError rt("{% if foo and %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true))
    # test_if_tag_error03
    @test_throws Juango.TemplateSyntaxError rt("{% if foo or %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true))
    # test_if_tag_error04
    @test_throws Juango.TemplateSyntaxError rt("{% if not foo and %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true))
    # test_if_tag_error05
    @test_throws Juango.TemplateSyntaxError rt("{% if not foo or %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true))
    # test_if_tag_error06
    @test_throws Juango.TemplateSyntaxError rt("{% if abc def %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error07
    @test_throws Juango.TemplateSyntaxError rt("{% if not %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error08
    @test_throws Juango.TemplateSyntaxError rt("{% if and %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error09
    @test_throws Juango.TemplateSyntaxError rt("{% if or %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error10
    @test_throws Juango.TemplateSyntaxError rt("{% if == %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error11
    @test_throws Juango.TemplateSyntaxError rt("{% if 1 == %}yes{% endif %}", Dict{Any,Any}())
    # test_if_tag_error12
    @test_throws Juango.TemplateSyntaxError rt("{% if a not b %}yes{% endif %}", Dict{Any,Any}())
    # test_else_if_tag_error01
    @test_throws Juango.TemplateSyntaxError rt("{% if foo is bar %} yes {% else if foo is not bar %} no {% endif %}", Dict{Any,Any}())
    # test_if_tag_badarg01
    @test rt("{% if x|default_if_none:y %}yes{% endif %}", Dict{Any,Any}()) == ""
    # test_if_tag_badarg02
    @test rt("{% if x|default_if_none:y %}yes{% endif %}", Dict{Any,Any}("y" => 0)) == ""
    # test_if_tag_badarg03
    @test rt("{% if x|default_if_none:y %}yes{% endif %}", Dict{Any,Any}("y" => 1)) == "yes"
    # test_if_tag_badarg04
    @test rt("{% if x|default_if_none:y %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # test_if_tag_single_eq
    @test_broken (try; rt("{% if foo = bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1)); false; catch e; e isa Juango.TemplateSyntaxError; end)      # (a Juango difference)
    # test_if_is_match
    @test rt("{% if foo is True %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => true)) == "yes"
    # test_if_is_no_match
    @test rt("{% if foo is True %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1)) == "no"
    # test_if_is_variable_missing
    @test rt("{% if foo is bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => 1)) == "no"
    # test_if_is_both_variables_missing
    @test rt("{% if foo is bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "yes"
    # test_if_is_not_match
    @test rt("{% if foo is not None %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false)) == "yes"
    # test_if_is_not_no_match
    @test rt("{% if foo is not None %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => nothing)) == "no"
    # test_if_is_not_variable_missing
    @test rt("{% if foo is not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}("foo" => false)) == "yes"
    # test_if_is_not_both_variables_missing
    @test rt("{% if foo is not bar %}yes{% else %}no{% endif %}", Dict{Any,Any}()) == "no"
    # not translated: test_if_tag_shortcircuit01 (call TestObj); test_if_tag_shortcircuit02 (call TestObj); test_repr (call keywords)
end

@testset "django template_tests: test_include" begin
    # test_include06
    @test rtn(Dict("include 05" => "template with a space", "include06" => "{% include \"include 05\"%}"), "include06", Dict{Any,Any}()) == "template with a space"
    # test_include_error01
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" with %}", Dict{Any,Any}())
    # test_include_error02
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" with \"no key\" %}", Dict{Any,Any}())
    # test_include_error03
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" with dotted.arg=\"error\" %}", Dict{Any,Any}())
    # test_include_error04
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" something_random %}", Dict{Any,Any}())
    # test_include_error05
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" foo=\"duplicate\" foo=\"key\" %}", Dict{Any,Any}())
    # test_include_error06
    @test_throws Juango.TemplateSyntaxError rt("{% include \"basic-syntax01\" only only %}", Dict{Any,Any}())
    # test_include_fail1
    @test_throws Exception rtn(Dict("include-fail1" => "{% load bad_tag %}{% badtag %}", "include-fail2" => "{% load broken_tag %}"), "include-fail1", Dict{Any,Any}())
    # test_include_fail2
    @test_throws Juango.TemplateSyntaxError rtn(Dict("include-fail1" => "{% load bad_tag %}{% badtag %}", "include-fail2" => "{% load broken_tag %}"), "include-fail2", Dict{Any,Any}())
    # test_include_empty
    @test_throws Juango.TemplateSyntaxError rt("{% include %}", Dict{Any,Any}())
    # not translated: test_include01 (setup arg); test_include02 (setup arg); test_include03 (setup arg); test_include04 (call get_template); test_include07 (setup arg); test_include08 (setup arg); test_include09 (setup arg); test_include10 (setup arg); test_include11 (setup arg); test_include12 (setup arg); test_include13 (setup arg); test_include14 (setup arg); test_include_error07 (call get_template); test_include_error08 (call get_template); test_include_error09 (call Context); test_include_error10 (call Context); test_include_missing_template (call keywords); test_extends_include_missing_baseloader (call keywords); test_extends_include_missing_cachedloader (call keywords); test_include_template_argument (call Engine); test_include_template_iterable (call get_default); test_include_template_none (call get_default); test_include_from_loader_get_template (call get_template); test_include_immediate_missing (method from_string); test_include_recursive (with); test_include_cache (call keywords); test_repr (call IncludeNode)
end

@testset "django template_tests: test_invalid_string" begin
    # test_invalidstr01
    @test rt("{{ var|default:\"Foo\" }}", Dict{Any,Any}()) == "Foo"
    # test_invalidstr02
    @test rt("{{ var|default_if_none:\"Foo\" }}", Dict{Any,Any}()) == ""
    # test_invalidstr03
    @test rt("{% for v in var %}({{ v }}){% endfor %}", Dict{Any,Any}()) == ""
    # test_invalidstr04
    @test rt("{% if var %}Yes{% else %}No{% endif %}", Dict{Any,Any}()) == "No"
    # test_invalidstr04_2
    @test rt("{% if var|default:\"Foo\" %}Yes{% else %}No{% endif %}", Dict{Any,Any}()) == "Yes"
    # test_invalidstr05
    @test rt("{{ var }}", Dict{Any,Any}()) == ""
    # test_invalidstr06
    @test rt("{{ var.prop }}", Dict{Any,Any}()) == ""
    # test_invalidstr07
    @test rt("{% load i18n %}{% blocktranslate %}{{ var }}{% endblocktranslate %}", Dict{Any,Any}()) == ""
end

@testset "django template_tests: test_list_index" begin
    # test_list_index01
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => Any["first item", "second item"])) == "second item"
    # test_list_index02
    @test rt("{{ var.5 }}", Dict{Any,Any}("var" => Any["first item", "second item"])) == ""
    # test_list_index03
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => nothing)) == ""
    # test_list_index04
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => Dict{Any,Any}())) == ""
    # test_list_index05
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => Dict{Any,Any}("1" => "hello"))) == "hello"
    # test_list_index06
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => Dict{Any,Any}(1 => "hello"))) == "hello"
    # test_list_index07
    @test rt("{{ var.1 }}", Dict{Any,Any}("var" => Dict{Any,Any}("1" => "hello", 1 => "world"))) == "hello"
end

@testset "django template_tests: test_load" begin
    # test_load01
    @test rt("{% load testtags subpackage.echo %}{% echo test %} {% echo2 \"test\" %}", Dict{Any,Any}()) == "test test"
    # test_load02
    @test rt("{% load subpackage.echo %}{% echo2 \"test\" %}", Dict{Any,Any}()) == "test"
    # test_load03
    @test rt("{% load echo from testtags %}{% echo this that theother %}", Dict{Any,Any}()) == "this that theother"
    # test_load04
    @test rt("{% load echo other_echo from testtags %}{% echo this that theother %} {% other_echo and another thing %}", Dict{Any,Any}()) == "this that theother and another thing"
    # test_load05
    @test rt("{% load echo upper from testtags %}{% echo this that theother %} {{ statement|upper }}", Dict{Any,Any}("statement" => "not shouting")) == "this that theother NOT SHOUTING"
    # test_load06
    @test rt("{% load echo2 from subpackage.echo %}{% echo2 \"test\" %}", Dict{Any,Any}()) == "test"
    # test_load07
    @test_throws Juango.TemplateSyntaxError rt("{% load echo other_echo bad_tag from testtags %}", Dict{Any,Any}())
    # test_load08
    @test_throws Juango.TemplateSyntaxError rt("{% load echo other_echo bad_tag from %}", Dict{Any,Any}())
    # test_load09
    @test_throws Juango.TemplateSyntaxError rt("{% load from testtags %}", Dict{Any,Any}())
    # test_load10
    @test_throws Juango.TemplateSyntaxError rt("{% load echo from bad_library %}", Dict{Any,Any}())
    # test_load12
    @test_throws Juango.TemplateSyntaxError rt("{% load subpackage.missing %}", Dict{Any,Any}())
end

@testset "django template_tests: test_lorem" begin
    # test_lorem1
    @test rt("{% lorem 3 w %}", Dict{Any,Any}()) == "lorem ipsum dolor"
    # test_lorem_syntax
    @test_throws Juango.TemplateSyntaxError rt("{% lorem 1 2 3 4 %}", Dict{Any,Any}())
    # not translated: test_lorem_random (call split); test_lorem_default (name COMMON_P); test_lorem_multiple_paragraphs (call count); test_lorem_incorrect_count (call count)
end

@testset "django template_tests: test_multiline" begin

    # not translated: test_multiline01 (malformed node or string on line 16: <ast.Name object at 0x7f618d5d3050>)
end

@testset "django template_tests: test_named_endblock" begin
    # test_namedendblocks01
    @test rt("1{% block first %}_{% block second %}2{% endblock second %}_{% endblock first %}3", Dict{Any,Any}()) == "1_2_3"
    # test_namedendblocks02
    @test_throws Juango.TemplateSyntaxError rt("1{% block first %}_{% block second %}2{% endblock first %}_{% endblock second %}3", Dict{Any,Any}())
    # test_namedendblocks03
    @test_throws Juango.TemplateSyntaxError rt("1{% block first %}_{% block second %}2{% endblock %}_{% endblock second %}3", Dict{Any,Any}())
    # test_namedendblocks04
    @test_throws Juango.TemplateSyntaxError rt("1{% block first %}_{% block second %}2{% endblock second %}_{% endblock third %}3", Dict{Any,Any}())
    # test_namedendblocks05
    @test_throws Juango.TemplateSyntaxError rt("1{% block first %}_{% block second %}2{% endblock first %}", Dict{Any,Any}())
    # test_namedendblocks06
    @test rt("1{% block first %}_{% block second %}2{% endblock %}_{% endblock first %}3", Dict{Any,Any}()) == "1_2_3"
    # test_namedendblocks07
    @test rt("1{% block first %}_{% block second %}2{% endblock second %}_{% endblock %}3", Dict{Any,Any}()) == "1_2_3"
    # not translated: test_namedendblock_multiline (call strip)
end

@testset "django template_tests: test_now" begin
    # test_now_args
    @test_throws Juango.TemplateSyntaxError rt("{% now %}", Dict{Any,Any}())
    # not translated: test_now01 (Attribute); test_now02 (call date_format); test_now03 (Attribute); test_now04 (call date_format); test_now05 (Attribute); test_now06 (Attribute); test_now07 (Attribute); test_now_variable (Attribute); test_now_variable_as (Attribute); test_now_format_escaping (call render_to_string)
end

@testset "django template_tests: test_numpy" begin

    # not translated: test_numpy_array_index01 (call array); test_numpy_array_index02 (call array)
end

@testset "django template_tests: test_partials" begin
    # test_partial_inline_and_used_once
    @test rt("{% partialdef testing-name inline %}HERE IS THE TEST CONTENT{% endpartialdef testing-name %}\n{% partial testing-name %}", Dict{Any,Any}()) == "HERE IS THE TEST CONTENT\nHERE IS THE TEST CONTENT"
    # test_partial_used_before_definition
    @test rt("TEMPLATE START\n{% partial testing-name %}\nMIDDLE CONTENT\n{% partialdef testing-name %}\nTHIS IS THE PARTIAL CONTENT\n{% endpartialdef %}\nTEMPLATE END", Dict{Any,Any}()) == "TEMPLATE START\n\nTHIS IS THE PARTIAL CONTENT\n\nMIDDLE CONTENT\n\nTEMPLATE END"
    # test_partial_in_included_template
    @test rtn(Dict("partial_with_include" => "MAIN TEMPLATE START\n{% include 'partial_included.html' %}\nMAIN TEMPLATE END", "partial_base.html" => "<main>{% block main %}Default main content.{% endblock main %}</main>", "partial_included.html" => "INCLUDED TEMPLATE START\n{% partialdef included-partial %}\nTHIS IS CONTENT FROM THE INCLUDED PARTIAL\n{% endpartialdef %}\n\nNow using the partial: {% partial included-partial %}\nINCLUDED TEMPLATE END\n"), "partial_with_include", Dict{Any,Any}()) == "MAIN TEMPLATE START\nINCLUDED TEMPLATE START\n\n\nNow using the partial: \nTHIS IS CONTENT FROM THE INCLUDED PARTIAL\n\nINCLUDED TEMPLATE END\n\nMAIN TEMPLATE END"
    # test_partial_as_include_in_template
    @test rtn(Dict("partial_as_include_in_other_template" => "MAIN TEMPLATE START\n{% include 'partial_included.html#included-partial' %}\nMAIN TEMPLATE END", "partial_base.html" => "<main>{% block main %}Default main content.{% endblock main %}</main>", "partial_included.html" => "INCLUDED TEMPLATE START\n{% partialdef included-partial %}\nTHIS IS CONTENT FROM THE INCLUDED PARTIAL\n{% endpartialdef %}\n\nNow using the partial: {% partial included-partial %}\nINCLUDED TEMPLATE END\n"), "partial_as_include_in_other_template", Dict{Any,Any}()) == "MAIN TEMPLATE START\n\nTHIS IS CONTENT FROM THE INCLUDED PARTIAL\n\nMAIN TEMPLATE END"
    # test_multiline_named_closing_tag
    @test rt("{% partialdef greeting %}Hello!{%\n    endpartialdef\n    greeting\n%}{% partial greeting %}", Dict{Any,Any}()) == "Hello!"
    # not translated: test_valid_partialdef_names (setup arg); test_basic_usage (for body); test_partial_inline_only_with_before_and_after_content (call strip); test_partial_inline_and_used_once_with_before_and_after_content (call strip); test_partial_defined_outside_main_block (method assertIn); test_partial_used_with_block_super (method assertIn); test_nested_partials (with); test_basic_parse_errors (malformed node or string on line 290: <ast.Call object at 0x7f618d5ccc10>); test_partialdef_invalid_inline (for body); test_broken_partial_unclosed_exception_info (method assertIn); test_partial_runtime_exception_has_debug_info (call get_template); test_partial_template_get_exception_info_delegation (If); test_undefined_partial_exception_info (call get_template); test_undefined_partial_exception_info_template_does_not_exist (template); test_partial_with_syntax_error_exception_info (If); test_partial_runtime_error_exception_info (call get_template); test_nested_partial_error_exception_info (call get_template); test_partial_in_extended_template_error (method assertIn); test_broken_partial_nesting (method assertIn); test_broken_partial_nesting_mixed (method assertIn)
end

@testset "django template_tests: test_querystring" begin
    # test_querystring_without_request_or_explicit_query_dict
    @test_throws Exception rt("{% querystring %}", Dict{Any,Any}())
    # not translated: test_querystring_empty_get_params (call RequestContext); test_querystring_remove_all_params (call RequestContext); test_querystring_remove_all_params_custom_querydict (call QueryDict); test_querystring_non_empty_get_params (call get); test_querystring_multiple (call get); test_querystring_multiple_lists (call get); test_querystring_lists_with_replacement (call get); test_querystring_empty_params (call QueryDict); test_querystring_replace (call get); test_querystring_add (call get); test_querystring_remove (call get); test_querystring_remove_nonexistent (call get); test_querystring_remove_from_dict (call get); test_querystring_remove_querydict (call get); test_querystring_remove_querydict_many (call get); test_querystring_variable (call get); test_querystring_dict (method assertRenderEqual); test_querystring_dict_list_values (method assertRenderEqual); test_querystring_multiple_args_override (call QueryDict); test_querystring_request_get_ignored (call get); test_querystring_same_arg (method assertTemplateSyntaxError); test_querystring_non_mapping_args (call get); test_querystring_non_string_dict_keys (method assertTemplateSyntaxError); test_querystring_add_list (call get); test_querystring_add_dict (call get); test_querystring_with_explicit_query_dict (call get); test_querystring_with_explicit_query_dict_and_no_request (call QueryDict)
end

@testset "django template_tests: test_regroup" begin
    # test_regroup01
    @test rt("{% regroup data by bar as grouped %}{% for group in grouped %}{{ group.grouper }}:{% for item in group.list %}{{ item.foo }}{% endfor %},{% endfor %}", Dict{Any,Any}("data" => Any[Dict{Any,Any}("foo" => "c", "bar" => 1), Dict{Any,Any}("foo" => "d", "bar" => 1), Dict{Any,Any}("foo" => "a", "bar" => 2), Dict{Any,Any}("foo" => "b", "bar" => 2), Dict{Any,Any}("foo" => "x", "bar" => 3)])) == "1:cd,2:ab,3:x,"
    # test_regroup02
    @test rt("{% regroup data by bar as grouped %}{% for group in grouped %}{{ group.grouper }}:{% for item in group.list %}{{ item.foo }}{% endfor %}{% endfor %}", Dict{Any,Any}()) == ""
    # test_regroup03
    @test rt("{% regroup data by at|date:\"m\" as grouped %}{% for group in grouped %}{{ group.grouper }}:{% for item in group.list %}{{ item.at|date:\"d\" }}{% endfor %},{% endfor %}", Dict{Any,Any}("data" => Any[Dict{Any,Any}("at" => Date(2012, 2, 14)), Dict{Any,Any}("at" => Date(2012, 2, 28)), Dict{Any,Any}("at" => Date(2012, 7, 4))])) == "02:1428,07:04,"
    # test_regroup04
    @test rt("{% regroup data by bar|join:\"\" as grouped %}{% for group in grouped %}{{ group.grouper }}:{% for item in group.list %}{{ item.foo|first }}{% endfor %},{% endfor %}", Dict{Any,Any}("data" => Any[Dict{Any,Any}("foo" => "x", "bar" => Any["ab", "c"]), Dict{Any,Any}("foo" => "y", "bar" => Any["a", "bc"]), Dict{Any,Any}("foo" => "z", "bar" => Any["a", "d"])])) == "abc:xy,ad:z,"
    # test_regroup05
    @test_throws Juango.TemplateSyntaxError rt("{% regroup data by bar as %}", Dict{Any,Any}())
    # test_regroup06
    @test_throws Juango.TemplateSyntaxError rt("{% regroup data by bar thisaintright grouped %}", Dict{Any,Any}())
    # test_regroup07
    @test_throws Juango.TemplateSyntaxError rt("{% regroup data thisaintright bar as grouped %}", Dict{Any,Any}())
    # test_regroup08
    @test_throws Juango.TemplateSyntaxError rt("{% regroup data by bar as grouped toomanyargs %}", Dict{Any,Any}())
    # test_regroup_unpack
    @test rt("{% regroup data by bar as grouped %}{% for grouper, group in grouped %}{{ grouper }}:{% for item in group %}{{ item.foo }}{% endfor %},{% endfor %}", Dict{Any,Any}("data" => Any[Dict{Any,Any}("foo" => "c", "bar" => 1), Dict{Any,Any}("foo" => "d", "bar" => 1), Dict{Any,Any}("foo" => "a", "bar" => 2), Dict{Any,Any}("foo" => "b", "bar" => 2), Dict{Any,Any}("foo" => "x", "bar" => 3)])) == "1:cd,2:ab,3:x,"
end

@testset "django template_tests: test_resetcycle" begin
    # test_resetcycle01
    @test_throws Juango.TemplateSyntaxError rt("{% resetcycle %}", Dict{Any,Any}())
    # test_resetcycle02
    @test_throws Juango.TemplateSyntaxError rt("{% resetcycle undefinedcycle %}", Dict{Any,Any}())
    # test_resetcycle03
    @test_throws Juango.TemplateSyntaxError rt("{% cycle 'a' 'b' %}{% resetcycle undefinedcycle %}", Dict{Any,Any}())
    # test_resetcycle04
    @test_throws Juango.TemplateSyntaxError rt("{% cycle 'a' 'b' as ab %}{% resetcycle undefinedcycle %}", Dict{Any,Any}())
    # not translated: test_resetcycle05 (call list); test_resetcycle06 (call list); test_resetcycle07 (call list); test_resetcycle08 (call list); test_resetcycle09 (call list); test_resetcycle10 (call list); test_resetcycle11 (call list)
end

@testset "django template_tests: test_setup" begin

    # not translated: test_setup (FunctionDef)
end

@testset "django template_tests: test_simple_tag" begin
    # test_simpletag_renamed01
    @test rt("{% load custom %}{% minusone 7 %}", Dict{Any,Any}()) == "6"
    # test_simpletag_renamed02
    @test rt("{% load custom %}{% minustwo 7 %}", Dict{Any,Any}()) == "5"
    # test_simpletag_renamed03
    @test_throws Juango.TemplateSyntaxError rt("{% load custom %}{% minustwo_overridden_name 7 %}", Dict{Any,Any}())
end

@testset "django template_tests: test_spaceless" begin
    # test_spaceless01
    @test rt("{% spaceless %} <b>    <i> text </i>    </b> {% endspaceless %}", Dict{Any,Any}()) == "<b><i> text </i></b>"
    # test_spaceless02
    @test rt("{% spaceless %} <b> \n <i> text </i> \n </b> {% endspaceless %}", Dict{Any,Any}()) == "<b><i> text </i></b>"
    # test_spaceless03
    @test rt("{% spaceless %}<b><i>text</i></b>{% endspaceless %}", Dict{Any,Any}()) == "<b><i>text</i></b>"
    # test_spaceless04
    @test rt("{% spaceless %}<b>   <i>{{ text }}</i>  </b>{% endspaceless %}", Dict{Any,Any}("text" => "This & that")) == "<b><i>This &amp; that</i></b>"
    # test_spaceless05
    @test rt("{% autoescape off %}{% spaceless %}<b>   <i>{{ text }}</i>  </b>{% endspaceless %}{% endautoescape %}", Dict{Any,Any}("text" => "This & that")) == "<b><i>This & that</i></b>"
    # test_spaceless06
    @test rt("{% spaceless %}<b>   <i>{{ text|safe }}</i>  </b>{% endspaceless %}", Dict{Any,Any}("text" => "This & that")) == "<b><i>This & that</i></b>"
end

@testset "django template_tests: test_static" begin
    # test_static_prefixtag_without_as
    @test_throws Juango.TemplateSyntaxError rt("{% load static %}{% get_media_prefix ad media_prefix %}{{ media_prefix }}", Dict{Any,Any}())
    # test_static_statictag_without_path
    @test_throws Juango.TemplateSyntaxError rt("{% load static %}{% static %}", Dict{Any,Any}())
    # not translated: test_static_prefixtag01 (Attribute); test_static_prefixtag02 (Attribute); test_static_prefixtag03 (Attribute); test_static_prefixtag04 (Attribute); test_static_statictag01 (call urljoin); test_static_statictag02 (call urljoin); test_static_statictag03 (call urljoin); test_static_statictag04 (call urljoin); test_static_quotes_urls (call urljoin); test_repr (call keywords)
end

@testset "django template_tests: test_template_tag" begin
    # test_templatetag01
    @test rt("{% templatetag openblock %}", Dict{Any,Any}()) == "{%"
    # test_templatetag02
    @test rt("{% templatetag closeblock %}", Dict{Any,Any}()) == "%}"
    # test_templatetag03
    @test rt("{% templatetag openvariable %}", Dict{Any,Any}()) == "{{"
    # test_templatetag04
    @test rt("{% templatetag closevariable %}", Dict{Any,Any}()) == "}}"
    # test_templatetag05
    @test_throws Juango.TemplateSyntaxError rt("{% templatetag %}", Dict{Any,Any}())
    # test_templatetag06
    @test_throws Juango.TemplateSyntaxError rt("{% templatetag foo %}", Dict{Any,Any}())
    # test_templatetag07
    @test rt("{% templatetag openbrace %}", Dict{Any,Any}()) == "{"
    # test_templatetag08
    @test rt("{% templatetag closebrace %}", Dict{Any,Any}()) == "}"
    # test_templatetag09
    @test rt("{% templatetag openbrace %}{% templatetag openbrace %}", Dict{Any,Any}()) == "{{"
    # test_templatetag10
    @test rt("{% templatetag closebrace %}{% templatetag closebrace %}", Dict{Any,Any}()) == "}}"
    # test_templatetag11
    @test rt("{% templatetag opencomment %}", Dict{Any,Any}()) == "{#"
    # test_templatetag12
    @test rt("{% templatetag closecomment %}", Dict{Any,Any}()) == "#}"
end

@testset "django template_tests: test_url" begin
  old_urls = Juango.settings.ROOT_URLCONF
  configure!(ROOT_URLCONF = DJT_URLS)
  try
    # test_url01
    @test rt("{% url \"client\" client.id %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/"
    # test_url02
    @test rt("{% url \"client_action\" id=client.id action=\"update\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/update/"
    # test_url02a
    @test rt("{% url \"client_action\" client.id \"update\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/update/"
    # test_url02b
    @test rt("{% url 'client_action' id=client.id action='update' %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/update/"
    # test_url02c
    @test rt("{% url 'client_action' client.id 'update' %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/update/"
    # test_url03
    @test rt("{% url \"index\" %}", Dict{Any,Any}()) == "/"
    # test_url04
    @test rt("{% url \"named.client\" client.id %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/named-client/1/"
    # test_url05
    @test rt("{% url \"метка_оператора\" v %}", Dict{Any,Any}("v" => "Ω")) == "/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4/%CE%A9/"
    # test_url06
    @test rt("{% url \"метка_оператора_2\" tag=v %}", Dict{Any,Any}("v" => "Ω")) == "/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4/%CE%A9/"
    # test_url08
    @test rt("{% url \"метка_оператора\" v %}", Dict{Any,Any}("v" => "Ω")) == "/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4/%CE%A9/"
    # test_url09
    @test rt("{% url \"метка_оператора_2\" tag=v %}", Dict{Any,Any}("v" => "Ω")) == "/%D0%AE%D0%BD%D0%B8%D0%BA%D0%BE%D0%B4/%CE%A9/"
    # test_url10
    @test rt("{% url \"client_action\" id=client.id action=\"two words\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/two%20words/"
    # test_url11
    @test rt("{% url \"client_action\" id=client.id action=\"==\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/==/"
    # test_url12
    @test rt("{% url \"client_action\" id=client.id action=\"!\$&'()*+,;=~:@,\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/!\$&amp;&#x27;()*+,;=~:@,/"
    # test_url13
    @test rt("{% url \"client_action\" id=client.id action=arg|join:\"-\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1), "arg" => Any["a", "b"])) == "/client/1/a-b/"
    # test_url14
    @test rt("{% url \"client_action\" client.id arg|join:\"-\" %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1), "arg" => Any["a", "b"])) == "/client/1/a-b/"
    # test_url15
    @test rt("{% url \"client_action\" 12 \"test\" %}", Dict{Any,Any}()) == "/client/12/test/"
    # test_url18
    @test rt("{% url \"client\" \"1,2\" %}", Dict{Any,Any}()) == "/client/1,2/"
    # test_url19
    @test rt("{% url named_url client.id %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1), "named_url" => "client")) == "/client/1/"
    # test_url20
    @test rt("{% url url_name_in_var client.id %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1), "url_name_in_var" => "named.client")) == "/named-client/1/"
    # test_url21
    @test rt("{% autoescape off %}{% url \"client_action\" id=client.id action=\"!\$&'()*+,;=~:@,\" %}{% endautoescape %}", Dict{Any,Any}("client" => Dict{Any,Any}("id" => 1))) == "/client/1/!\$&'()*+,;=~:@,/"
    # test_url_fail01
    @test_throws Juango.TemplateSyntaxError rt("{% url %}", Dict{Any,Any}())
    # test_url_fail02
    @test_throws Exception rt("{% url \"no_such_view\" %}", Dict{Any,Any}())
    # test_url_fail03
    @test_throws Exception rt("{% url \"client\" %}", Dict{Any,Any}())
    # test_url_fail04
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" id, %}", Dict{Any,Any}())
    # test_url_fail05
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" id= %}", Dict{Any,Any}())
    # test_url_fail06
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" a.id=id %}", Dict{Any,Any}())
    # test_url_fail07
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" a.id!id %}", Dict{Any,Any}())
    # test_url_fail08
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" id=\"unterminatedstring %}", Dict{Any,Any}())
    # test_url_fail09
    @test_throws Juango.TemplateSyntaxError rt("{% url \"view\" id=\", %}", Dict{Any,Any}())
    # test_url_fail11
    @test_throws Exception rt("{% url named_url %}", Dict{Any,Any}())
    # test_url_fail12
    @test_throws Exception rt("{% url named_url %}", Dict{Any,Any}("named_url" => "no_such_view"))
    # test_url_fail13
    @test_throws Exception rt("{% url named_url %}", Dict{Any,Any}("named_url" => "template_tests.views.client"))
    # test_url_fail14
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url id, %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_fail15
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url id= %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_fail16
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url a.id=id %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_fail17
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url a.id!id %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_fail18
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url id=\"unterminatedstring %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_fail19
    @test_throws Juango.TemplateSyntaxError rt("{% url named_url id=\", %}", Dict{Any,Any}("named_url" => "view"))
    # test_url_asvar01
    @test rt("{% url \"index\" as url %}", Dict{Any,Any}()) == ""
    # test_url_asvar02
    @test rt("{% url \"index\" as url %}{{ url }}", Dict{Any,Any}()) == "/"
    # test_url_asvar03
    @test rt("{% url \"no_such_view\" as url %}{{ url }}", Dict{Any,Any}()) == ""
    # not translated: test_url_namespace01 (call get); test_url_namespace02 (call get); test_url_namespace03 (call get); test_url_namespace_no_current_app (call get); test_url_namespace_explicit_current_app (call get); test_repr (call keywords)
  finally
    configure!(ROOT_URLCONF = old_urls)
  end
end

@testset "django template_tests: test_verbatim" begin
    # test_verbatim_tag01
    @test rt("{% verbatim %}{{bare   }}{% endverbatim %}", Dict{Any,Any}()) == "{{bare   }}"
    # test_verbatim_tag02
    @test rt("{% verbatim %}{% endif %}{% endverbatim %}", Dict{Any,Any}()) == "{% endif %}"
    # test_verbatim_tag03
    @test rt("{% verbatim %}It's the {% verbatim %} tag{% endverbatim %}", Dict{Any,Any}()) == "It's the {% verbatim %} tag"
    # test_verbatim_tag04
    @test_throws Juango.TemplateSyntaxError rt("{% verbatim %}{% verbatim %}{% endverbatim %}{% endverbatim %}", Dict{Any,Any}())
    # test_verbatim_tag05
    @test rt("{% verbatim %}{% endverbatim %}{% verbatim %}{% endverbatim %}", Dict{Any,Any}()) == ""
    # test_verbatim_tag06
    @test rt("{% verbatim special %}Don't {% endverbatim %} just yet{% endverbatim special %}", Dict{Any,Any}()) == "Don't {% endverbatim %} just yet"
    # test_literal_multiline_opener_in_named_verbatim
    @test rt("{% verbatim example %}\n{%\n{% endverbatim %}\n{% endverbatim example %}", Dict{Any,Any}()) == "\n{%\n{% endverbatim %}\n"
    # test_multiline_raw_block_closing_tags
    @test rt("{% verbatim %}content{%\nendverbatim\n%}", Dict{Any,Any}()) == "content"
    # test_named_verbatim_name_whitespace_not_preserved
    @test_throws Juango.TemplateSyntaxError rt("{% verbatim a  b %}{% endverbatim a b %}{% endverbatim a  b %}", Dict{Any,Any}())
    # test_template_syntax_in_raw_blocks
    @test rt("{% verbatim %}\n{% if user %}Hello, {{ user }}{% endif %}\n{% endverbatim %}", Dict{Any,Any}()) == "\n{% if user %}Hello, {{ user }}{% endif %}\n"
    # test_literal_multiline_block_opener_in_raw_blocks
    @test rt("{% verbatim %}\n{%\n{% endverbatim %}", Dict{Any,Any}()) == "\n{%\n"
    # test_multiline_named_closing_tag
    @test rt("{% verbatim example %}content{%\n    endverbatim\n    example\n%}", Dict{Any,Any}()) == "content"
    # not translated: test_multiple_verbatim_tags_on_same_line (For); test_named_verbatim_preserves_name_whitespace_legacy (call keywords); test_tags_without_spaces (for body)
end

@testset "django template_tests: test_width_ratio" begin
    # test_widthratio01
    @test rt("{% widthratio a b 0 %}", Dict{Any,Any}("a" => 50, "b" => 100)) == "0"
    # test_widthratio02
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 0, "b" => 0)) == "0"
    # test_widthratio03
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 0, "b" => 100)) == "0"
    # test_widthratio04
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 50, "b" => 100)) == "50"
    # test_widthratio05
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 100, "b" => 100)) == "100"
    # test_widthratio06
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 50, "b" => 80)) == "62"
    # test_widthratio07
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => 50, "b" => 70)) == "71"
    # test_widthratio08
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio %}", Dict{Any,Any}())
    # test_widthratio09
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio a b %}", Dict{Any,Any}("a" => 50, "b" => 100))
    # test_widthratio10
    @test rt("{% widthratio a b 100.0 %}", Dict{Any,Any}("a" => 50, "b" => 100)) == "50"
    # test_widthratio11
    @test rt("{% widthratio a b c %}", Dict{Any,Any}("a" => 50, "c" => 100, "b" => 100)) == "50"
    # test_widthratio12a
    @test rt("{% widthratio a b c %}", Dict{Any,Any}("a" => "a", "c" => 100, "b" => 100)) == ""
    # test_widthratio12b
    @test rt("{% widthratio a b c %}", Dict{Any,Any}("a" => nothing, "c" => 100, "b" => 100)) == ""
    # test_widthratio13a
    @test rt("{% widthratio a b c %}", Dict{Any,Any}("a" => 0, "c" => 100, "b" => "b")) == ""
    # test_widthratio13b
    @test rt("{% widthratio a b c %}", Dict{Any,Any}("a" => 0, "c" => 100, "b" => nothing)) == ""
    # test_widthratio14a
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio a b c %}", Dict{Any,Any}("a" => 0, "c" => "c", "b" => 100))
    # test_widthratio14b
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio a b c %}", Dict{Any,Any}("a" => 0, "c" => nothing, "b" => 100))
    # test_widthratio15
    @test rt("{% load custom %}{% widthratio a|noop:\"x y\" b 0 %}", Dict{Any,Any}("a" => 50, "b" => 100)) == "0"
    # test_widthratio16
    @test rt("{% widthratio a b 100 as variable %}-{{ variable }}-", Dict{Any,Any}("a" => 50, "b" => 100)) == "-50-"
    # test_widthratio17
    @test rt("{% widthratio a b 100 as variable %}-{{ variable }}-", Dict{Any,Any}("a" => 100, "b" => 100)) == "-100-"
    # test_widthratio18
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio a b 100 as %}", Dict{Any,Any}())
    # test_widthratio19
    @test_throws Juango.TemplateSyntaxError rt("{% widthratio a b 100 not_as variable %}", Dict{Any,Any}())
    # test_widthratio20
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => pyfloat("inf"), "b" => pyfloat("inf"))) == ""
    # test_widthratio21
    @test rt("{% widthratio a b 100 %}", Dict{Any,Any}("a" => pyfloat("inf"), "b" => 2)) == ""
    # test_zerodivisionerror_as_var
    @test rt("{% widthratio a b 100 as variable %}-{{ variable }}-", Dict{Any,Any}("a" => 0, "b" => 0)) == "-0-"
    # test_typeerror_as_var
    @test rt("{% widthratio a b c as variable %}-{{ variable }}-", Dict{Any,Any}("a" => "a", "c" => 100, "b" => 100)) == "--"
end

@testset "django template_tests: test_with" begin
    # test_with01
    @test rt("{% with key=dict.key %}{{ key }}{% endwith %}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50))) == "50"
    # test_legacywith01
    @test rt("{% with dict.key as key %}{{ key }}{% endwith %}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50))) == "50"
    # test_with02
    @test rt("{{ key }}{% with key=dict.key %}{{ key }}-{{ dict.key }}-{{ key }}{% endwith %}{{ key }}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50))) == "50-50-50"
    # test_legacywith02
    @test rt("{{ key }}{% with dict.key as key %}{{ key }}-{{ dict.key }}-{{ key }}{% endwith %}{{ key }}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50))) == "50-50-50"
    # test_with03
    @test rt("{% with a=alpha b=beta %}{{ a }}{{ b }}{% endwith %}", Dict{Any,Any}("alpha" => "A", "beta" => "B")) == "AB"
    # test_with_error01
    @test_throws Juango.TemplateSyntaxError rt("{% with dict.key xx key %}{{ key }}{% endwith %}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50)))
    # test_with_error02
    @test_throws Juango.TemplateSyntaxError rt("{% with dict.key as %}{{ key }}{% endwith %}", Dict{Any,Any}("dict" => Dict{Any,Any}("key" => 50)))
    # not translated: test_repr (call keywords)
end


configure!(TEMPLATES = DJT_OLD_TEMPLATES)
