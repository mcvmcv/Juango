# Django's template tests, ported (#227): tests/template_tests.
# julia --project=test test/django_templates.jl   (see setup.jl)
#
# The filter and syntax tests are translated from Django's modules by a script (each keeps its
# Django name in a comment) and corrected by hand where Juango differs, with the reason at the
# test. Tests the script couldn't translate are listed at the end of each module's testset.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# Django's engine.render_to_string(template, context) for a template given as a string
rt(src, ctx = Dict{Any,Any}()) = render(Template(src), Dict{String,Any}(string(k) => v for (k, v) in ctx))
# a filter called as a function, as Django's tests import them from defaultfilters
function filt(name, v, args...; autoescape = true)
    f = Juango.FILTERS[name]
    arg = isempty(args) ? nothing : args[1]
    f.needs_autoescape ? f.fn(v, arg, autoescape) : f.fn(v, arg)
end
html_eq(a, b) = try assert_html_equal(string(a), string(b)) catch; false end

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

