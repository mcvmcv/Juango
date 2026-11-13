# templates: julia --project=test test/templates.jl   (JUANGO_TEST_DATABASE picks the database; see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "templates: variables & filters" begin
    @test tr("Hi {{ name }}!", Dict("name" => "Ann")) == "Hi Ann!"
    @test tr("{{ x }}", Dict("x" => "<b>")) == "&lt;b&gt;"
    @test tr("{{ x|safe }}", Dict("x" => "<b>")) == "<b>"
    @test tr("{% autoescape off %}{{ x }}{% endautoescape %}", Dict("x" => "<b>")) == "<b>"
    @test tr("{{ a.b.c }}", Dict("a" => Dict("b" => Dict(:c => 3)))) == "3"
    @test tr("{{ xs.1 }}", Dict("xs" => [10, 20, 30])) == "20"
    @test tr("{{ t.name }}", Dict("t" => (name = "nt",))) == "nt"
    @test tr("[{{ missing }}][{{ missing.deep }}]") == "[][]"
    @test tr("{{ s|upper }} {{ s|lower }} {{ s|title }} {{ s|length }}", Dict("s" => "hello World")) == "HELLO WORLD hello world Hello World 11"
    @test tr("{{ x|default:\"none\" }}", Dict("x" => "")) == "none"
    @test tr("{{ xs|join:\", \" }}", Dict("xs" => ["a", "<b>"])) == "a, &lt;b&gt;"
    @test tr("{{ s|truncatechars:5 }}", Dict("s" => "abcdefgh")) == "abcd…"
    @test tr("{{ n }} item{{ n|pluralize }}", Dict("n" => 2)) == "2 items"
    @test tr("{{ n|pluralize:\"y,ies\" }}", Dict("n" => 1)) == "y"
    @test tr("{{ a|add:2 }} {{ s|add:\"x\" }}", Dict("a" => 3, "s" => "a")) == "5 ax"
    @test tr("{{ d|date:\"Y-m-d H:i\" }} {{ d|date:\"D, j M\" }}", Dict("d" => DateTime(2024, 3, 5, 14, 7))) == "2024-03-05 14:07 Tue, 5 Mar"
    @test tr("{{ s|linebreaksbr }}", Dict("s" => "a\n<b>")) == "a<br>&lt;b&gt;"
    @test tr("{{ s|slugify }}", Dict("s" => "Héllo, World!")) == "hello-world"
    @test tr("{{ x|floatformat:2 }} {{ y|floatformat }}", Dict("x" => 3.14159, "y" => 2.0)) == "3.14 2"
    @test tr("{{ b|yesno:\"on,off\" }}", Dict("b" => false)) == "off"
    @test tr("{{ xs|first }}-{{ xs|last }}", Dict("xs" => [1, 2, 3])) == "1-3"
    @test tr("{{ xs|slice:\":2\"|join:\"\" }}", Dict("xs" => ["a", "b", "c"])) == "ab"
    @test tr("{{ \"lit\" }} {{ 42 }}") == "lit 42"
    Juango.register_filter!("shout", (v, _) -> uppercase(string(v)) * "!")
    @test tr("{{ w|shout }}", Dict("w" => "hey")) == "HEY!"
    @test_throws Juango.TemplateSyntaxError Template("{{ x|nosuchfilter }}")
    @test_throws Juango.TemplateSyntaxError Template("{% if x %}unclosed")
    @test_throws Juango.TemplateSyntaxError Template("{% bogus %}")
end

@testset "templates: tags" begin
    @test tr("{% if a %}A{% elif b %}B{% else %}C{% endif %}", Dict("a" => false, "b" => true)) == "B"
    @test tr("{% if n > 2 and not flag %}yes{% endif %}", Dict("n" => 3, "flag" => false)) == "yes"
    @test tr("{% if x in xs %}in{% endif %}{% if y not in xs %}out{% endif %}", Dict("x" => 1, "y" => 9, "xs" => [1, 2])) == "inout"
    @test tr("{% if s == \"a\" or s == \"b\" %}ok{% endif %}", Dict("s" => "b")) == "ok"
    @test tr("{% if xs|length >= 2 %}long{% endif %}", Dict("xs" => [1, 2])) == "long"
    @test tr("{% if x is None %}none{% endif %}", Dict("x" => nothing)) == "none"
    @test tr("{% for x in xs %}{{ forloop.counter }}:{{ x }}{% if not forloop.last %},{% endif %}{% endfor %}", Dict("xs" => ["a", "b"])) == "1:a,2:b"
    @test tr("{% for x in xs %}x{% empty %}empty{% endfor %}", Dict("xs" => [])) == "empty"
    @test tr("{% for k, v in d.items %}{{ k }}={{ v }}{% endfor %}", Dict("d" => Dict("a" => 1))) == "a=1"
    @test tr("{% for x in xs reversed %}{{ x }}{% endfor %}", Dict("xs" => [1, 2, 3])) == "321"
    @test tr("{% for a, b in ps %}{{ a }}{{ b }};{% endfor %}", Dict("ps" => [(1, 2), (3, 4)])) == "12;34;"
    @test tr("{% for r in rows %}{% for c in r %}{{ forloop.parentloop.counter }}{{ c }}{% endfor %}{% endfor %}", Dict("rows" => [[1], [2]])) == "1122"
    @test tr("{% with total=a|add:b %}{{ total }}{% endwith %}", Dict("a" => 1, "b" => 2)) == "3"
    @test tr("{% for x in xs %}{% cycle 'odd' 'even' %} {% endfor %}", Dict("xs" => 1:3)) == "odd even odd "
    @test tr("{% firstof a b \"z\" %}", Dict("a" => "", "b" => nothing)) == "z"
    @test tr("a{# hidden #}b{% comment %}gone{{ x }}{% endcomment %}c") == "abc"
    @test tr("{% verbatim %}{{ raw }}{% if %}{% endverbatim %}") == "{{ raw }}{% if %}"
    @test tr("{% spaceless %}<p>\n  <a>x</a>\n</p>{% endspaceless %}") == "<p><a>x</a></p>"
    @test tr("{% load static %}{% static 'css/a.css' %}") == "/static/css/a.css"
    @test tr("{% url 'article_detail' id=5 %}|{% url 'blog:detail_slug' 3 'hi' %}") == "/articles/5/|/blog/3/hi/"
    @test tr("{% url 'home' as home %}[{{ home }}]") == "[/]"
    @test tr("{% csrf_token %}", Dict("csrf_token" => "abc")) == "<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"abc\">"
    @test render_to_string("child.html", Dict("name" => "<Bob>")) ==
          "<html><title>Child|Mid|Site</title><body>Hello &lt;Bob&gt;[part 7 &lt;Bob&gt;]</body></html>"
    @test render_to_string("base.html") == "<html><title>Site</title><body>BASE</body></html>"
end

@testset "templates: more tags, filters and libraries" begin
    # ifchanged / regroup
    @test tr("{% for x in xs %}{% ifchanged %}[{{ x }}]{% endifchanged %}{% endfor %}", Dict("xs" => [1, 1, 2, 2, 1])) == "[1][2][1]"
    @test tr("{% for x in xs %}{% ifchanged x.a %}{{ x.a }}:{% else %}-{% endifchanged %}{% endfor %}",
             Dict("xs" => [Dict("a" => 1), Dict("a" => 1), Dict("a" => 2)])) == "1:-2:"
    @test tr("{% for r in rows %}{% for x in r %}{% ifchanged %}{{ x }}{% endifchanged %}{% endfor %};{% endfor %}",
             Dict("rows" => [[1, 1], [1, 2]])) == "1;12;"                 # starts afresh in each loop
    people = [Dict("n" => "a", "c" => "X"), Dict("n" => "b", "c" => "X"), Dict("n" => "c", "c" => "Y")]
    @test tr("{% regroup ps by c as g %}{% for grp in g %}{{ grp.grouper }}={% for p in grp.list %}{{ p.n }}{% endfor %};{% endfor %}",
             Dict("ps" => people)) == "X=ab;Y=c;"
    @test tr("{% regroup ps by c|lower as g %}{{ g.0.grouper }}{{ g|length }}", Dict("ps" => people)) == "x2"

    # widthratio, templatetag, lorem, filter, resetcycle, debug
    @test tr("{% widthratio 175 200 100 %} {% widthratio v 0 100 %} {% widthratio 1 3 100 as w %}[{{ w }}]", Dict("v" => 5)) == "88 0 [33]"
    @test tr("{% templatetag openblock %} {% templatetag closevariable %} {% templatetag opencomment %}") == "{% }} {#"
    @test tr("{% lorem 3 w %}") == "lorem ipsum dolor" && startswith(tr("{% lorem %}"), "Lorem ipsum dolor sit amet")
    @test length(split(tr("{% lorem 30 w random %}"))) == 30 && count("<p>", tr("{% lorem 3 p %}")) == 3
    @test tr("{% filter upper|cut:'X' %}ax <b> {{ s }}{% endfilter %}", Dict("s" => "<i>")) == "A <B> &LT;I&GT;"
    @test_throws TemplateSyntaxError Template("{% filter escape %}x{% endfilter %}")
    @test tr("{% for x in xs %}{% cycle 'a' 'b' 'c' as c silent %}{{ c }}{% if x == 2 %}{% resetcycle c %}{% endif %}{% endfor %}",
             Dict("xs" => [1, 2, 3, 4])) == "abab"
    @test tr("{% for x in xs %}{% cycle 'a' 'b' 'c' %}{% resetcycle %}{% endfor %}", Dict("xs" => [1, 2])) == "aa"
    @test occursin("secret =&gt; &quot;&lt;b&gt;&quot;", tr("{% debug %}", Dict("secret" => "<b>")))

    # querystring
    req = Request("GET", "/list/?page=2&tag=a&tag=b&q=x")
    qs(src, d = Dict{String,Any}()) = render(Template(src), d; request = req)
    @test qs("{% querystring %}") == "?page=2&amp;q=x&amp;tag=a&amp;tag=b"
    @test qs("{% querystring page=3 q=None %}") == "?page=3&amp;tag=a&amp;tag=b"
    @test qs("{% querystring tag=tags new='a b' as u %}<a href=\"{{ u }}\">", Dict("tags" => ["z"])) ==
          "<a href=\"?page=2&amp;q=x&amp;tag=z&amp;new=a%20b\">"
    @test qs("{% querystring d page=1 %}", Dict("d" => Dict("only" => "1"))) == "?only=1&amp;page=1"
    @test tr("{% querystring a=1 %}") == "?a=1"

    # partials
    @test tr("{% partialdef card %}<b>{{ x }}</b>{% endpartialdef %}{% partial card %}{% with x=2 %}{% partial card %}{% endwith %}",
             Dict("x" => 1)) == "<b>1</b><b>2</b>"
    @test tr("{% partialdef card inline %}<b>{{ x }}</b>{% endpartialdef card %}!", Dict("x" => 1)) == "<b>1</b>!"
    @test_throws TemplateSyntaxError tr("{% partial nope %}")
    write(joinpath(TPL, "partials.html"), "A{% partialdef row %}<tr>{{ v }}</tr>{% endpartialdef %}B{% include 'partials.html#row' with v=1 %}")
    @test render_to_string("partials.html", Dict("v" => 0)) == "AB<tr>1</tr>"
    @test render_to_string("partials.html#row", Dict("v" => 5)) == "<tr>5</tr>"
    @test_throws Juango.TemplateDoesNotExist get_template("partials.html#nope")

    # filters
    @test tr("{{ s|phone2numeric }}", Dict("s" => "1-800-COLLECT")) == "1-800-2655328"
    @test tr("{{ 123|get_digit:1 }}{{ 123|get_digit:3 }}{{ 123|get_digit:4 }}{{ 'x'|get_digit:1 }}") == "310x"
    @test tr("{% autoescape off %}{{ s|addslashes }} {{ j|escapejs }}{% endautoescape %}", Dict("s" => "I'm \"x\"", "j" => "a'b<c>\n")) ==
          "I\\'m \\\"x\\\" a\\u0027b\\u003Cc\\u003E\\u000A"
    @test tr("{{ l|unordered_list }}", Dict("l" => ["States", ["Kansas", ["Lawrence", "Topeka"], "<Illinois>"]])) ==
          "\t<li>States\n\t<ul>\n\t\t<li>Kansas\n\t\t<ul>\n\t\t\t<li>Lawrence</li>\n\t\t\t<li>Topeka</li>\n\t\t</ul>\n\t\t</li>\n\t\t<li>&lt;Illinois&gt;</li>\n\t</ul>\n\t</li>"
    @test tr("{{ s|wordwrap:5 }}", Dict("s" => "Joel is a slug")) == "Joel\nis a\nslug"
    h = Dict("h" => "<p>Joel is a <b>slug</b> &amp; more</p>")
    @test tr("{{ h|safe|truncatechars_html:7 }}", h) == "<p>Joel i…</p>"
    @test tr("{{ h|safe|truncatewords_html:4 }}", h) == "<p>Joel is a <b>slug …</b></p>"
    @test tr("{{ h|safe|truncatewords_html:9 }}", h) == h["h"]
    @test tr("{{ s|safe|truncatechars_html:4 }}", Dict("s" => "<i>héllo</i>")) == "<i>hél…</i>"
    @test tr("{{ u|urlizetrunc:15 }}", Dict("u" => "see http://example.com/a/long/path")) ==
          "see <a href=\"http://example.com/a/long/path\" rel=\"nofollow\">http://example…</a>"
    @test tr("{{ d|timeuntil }}", Dict("d" => now() + Day(3) + Hour(1))) == "3 days"
    @test tr("{{ d|timeuntil:ref }}", Dict("d" => DateTime(2024, 1, 10), "ref" => DateTime(2024, 1, 1))) == "1 week"
    @test tr("{{ s|iriencode }}", Dict("s" => "?a=1&b=x y/é")) == "?a=1&amp;b=x%20y/é"
    @test tr("{{ l|escapeseq|join:',' }}", Dict("l" => ["<a>", "b"])) == "&lt;a&gt;,b"
    @test tr("{{ s|linenumbers }}", Dict("s" => "a\n<b>")) == "1. a\n2. &lt;b&gt;"
    @test tr("{{ s|center:7 }}|{{ s|ljust:5 }}|{{ s|rjust:5 }}|{{ l|slice:'1:' }}|{{ l|slice:'-2:' }}|{{ l|slice:':2' }}",
             Dict("s" => "ab", "l" => [1, 2, 3])) == "  ab   |ab   |   ab|[2, 3]|[2, 3]|[1, 2]"

    # custom tag libraries
    lib = TagLibrary("testtags")
    greet(name; punct = "!") = "Hello $name$punct"
    simple_tag!(greet, lib, "greet")
    simple_tag!((ctx, k) -> string(ctx[k], "!"), lib, "shout_var"; takes_context = true)
    simple_tag!(() -> mark_safe("<hr>"), lib, "rule")
    write(joinpath(TPL, "inc_item.html"), "<li>{{ n }}{{ v }}</li>")
    inclusion_tag!(n -> Dict("n" => 2n), lib, "item", "inc_item.html")
    filter!((v, _) -> string(v) * "?", lib, "huh")
    @test tr("{% load testtags %}{% greet 'Ann' %} {% greet '<x>' punct='?' %} {% greet 'B' as g %}[{{ g }}] {% shout_var 'v' %} {% item 21 %}{% rule %}",
             Dict("v" => 7)) == "Hello Ann! Hello &lt;x&gt;? [Hello B!] 7! <li>42</li><hr>"
    @test_throws TemplateSyntaxError Template("{% greet 'Ann' %}")          # not loaded
    @test tr("{% load greet from testtags %}{% greet 'Z' %}") == "Hello Z!"
    @test_throws TemplateSyntaxError Template("{% load rule2 from testtags %}")
    @test_throws TemplateSyntaxError Template("{% load nolib %}")
    @test tr("{% load static testtags %}{{ 'x'|huh }}") == "x?"
    @test tr("{% load huh from testtags %}{{ 'x'|huh }}") == "x?"
    # library filters need {% load %}, in each template (an included template loads its own)
    err = try Template("{{ 'x'|huh }}"); "" catch e; sprint(showerror, e) end
    @test occursin("invalid filter: 'huh'", err) && occursin("{% load testtags %}", err)
    @test_throws TemplateSyntaxError Template("{{ 5|intcomma }}")
    write(joinpath(TPL, "inc_huh.html"), "{{ 'y'|huh }}")
    @test_throws TemplateSyntaxError tr("{% load testtags %}{% include 'inc_huh.html' %}")
    @test tr("{% load i18n %}{% load trans from i18n %}{% load intcomma from humanize %}{{ 1234|intcomma }}") == "1,234"
    @test_throws TemplateSyntaxError Template("{% load nope from humanize %}")

    # where syntax errors are
    write(joinpath(TPL, "bad_syntax.html"), "line one\n{% if x %}\n{% for %}\n{% endif %}")
    err = try get_template("bad_syntax.html"); nothing catch e; e end
    @test err isa TemplateSyntaxError && err.line == 3 && err.origin == joinpath(TPL, "bad_syntax.html") &&
          occursin("in template 'bad_syntax.html' ($(joinpath(TPL, "bad_syntax.html"))), line 3", err.msg)
    page = Juango.template_error_html(err)
    @test occursin("error at line 3", page) && occursin("<tr class=\"hl\"><td class=\"muted\">3</td><td><code>{% for %}</code>", page)
end

@testset "urls" begin
    m = resolve("/articles/12/")
    @test m.view isa Function && m.kwargs == Dict(:id => 12) && m.url_name == "article_detail"
    m = resolve("/blog/4/my-post/")
    @test m.kwargs == Dict(:id => 4, :slug => "my-post") && m.namespace == "blog" && m.view_name == "blog:detail_slug"
    @test resolve("/articles/abc/") === nothing
    @test resolve("/files/a/b/c.txt").kwargs[:rest] == "a/b/c.txt"
    @test reverse_url("article_detail"; id = 7) == "/articles/7/"
    @test reverse_url("blog:detail_slug", 1, "x") == "/blog/1/x/"
    @test reverse_url("blog:list"; query = Dict("page" => 2)) == "/blog/?page=2"
    @test reverse_url("files"; rest = "a b/c") == "/files/a%20b/c"
    @test_throws Juango.NoReverseMatch reverse_url("nope")
    @test_throws Juango.NoReverseMatch reverse_url("article_detail"; id = "abc")
end

@testset "humanize" begin
    h(src, d = Dict{String,Any}()) = tr("{% load humanize %}" * src, d)
    @test h("{{ 1234567|intcomma }} {{ 999|intcomma }} {{ -45000|intcomma }} {{ 1234.5|intcomma }} {{ '12345'|intcomma }}") ==
          "1,234,567 999 -45,000 1,234.5 12,345"
    @test with_language(() -> h("{{ 1234567|intcomma }}"), "de") == "1.234.567"
    @test h("{{ 999999|intword }} {{ 1000000|intword }} {{ 1200000|intword }} {{ 3400000000|intword }}") ==
          "999999 1.0 million 1.2 million 3.4 billion"
    @test h("{{ 1|apnumber }} {{ 9|apnumber }} {{ 10|apnumber }} {{ 'x'|apnumber }}") == "one nine 10 x"
    @test h("{% for n in ns %}{{ n|ordinal }} {% endfor %}", Dict{String,Any}("ns" => [1, 2, 3, 4, 11, 12, 13, 21, 22, 101, 111])) ==
          "1st 2nd 3rd 4th 11th 12th 13th 21st 22nd 101st 111th "
    today = Date(now())
    d = Dict{String,Any}("t" => today, "y" => today - Day(1), "m" => today + Day(1), "o" => Date(2020, 3, 5))
    @test h("{{ t|naturalday }} {{ y|naturalday }} {{ m|naturalday }} {{ o|naturalday:'Y-m-d' }}", d) == "today yesterday tomorrow 2020-03-05"
    n = now()
    d = Dict{String,Any}("a" => n, "b" => n - Second(30), "c" => n - Minute(1) - Second(5), "e" => n - Minute(14) - Second(1),
                         "f" => n - Hour(1) - Second(1), "g" => n - Hour(5) - Second(1), "i" => n - Day(3) - Second(1),
                         "j" => n + Minute(10) + Second(5), "k" => n + Day(2) + Second(5))
    out = split(h("{{ a|naturaltime }}|{{ b|naturaltime }}|{{ c|naturaltime }}|{{ e|naturaltime }}|{{ f|naturaltime }}|{{ g|naturaltime }}|{{ i|naturaltime }}|{{ j|naturaltime }}|{{ k|naturaltime }}", d), '|')
    @test out[1] in ("now", "a second ago") && out[2] in ("30 seconds ago", "31 seconds ago")
    @test out[3:7] == ["a minute ago", "14 minutes ago", "an hour ago", "5 hours ago", "3 days ago"]
    @test out[8] in ("10 minutes from now", "9 minutes from now") && out[9] == "2 days from now"
end

@testset "escaping and lookups" begin
    @test Juango.escape_html("plain") === "plain"
    @test Juango.escape_html("<a href=\"x\">&'</a>") == "&lt;a href=&quot;x&quot;&gt;&amp;&#x27;&lt;/a&gt;"
    @test sprint(io -> Juango.escape_html(io, "é<b>")) == "é&lt;b&gt;"
    @test tr("{{ s|escape }}", Dict("s" => mark_safe("<b>"))) == "<b>"                     # not escaped twice
    @test tr("{{ s|force_escape }}", Dict("s" => mark_safe("<b>"))) == "&lt;b&gt;"
    @test tr("{{ n }} {{ f }} {{ b }}", Dict("n" => 3, "f" => 1.5, "b" => true)) == "3 1.5 true"
    @test tr("{% for x in xs %}{{ forloop.counter }}/{{ forloop.revcounter0 }}{% if forloop.last %}.{% endif %}{% endfor %}",
             Dict("xs" => [1, 2])) == "1/12/0."
    @test tr("{% for x in xs %}{% for y in xs %}{{ forloop.parentloop.counter }}{{ forloop.counter }} {% endfor %}{% endfor %}",
             Dict("xs" => [1, 2])) == "11 12 21 22 "
    @test tr("{{ d.items.0.value }} {{ v.1 }} {{ v.9 }}", Dict("d" => Dict("k" => "val"), "v" => [10, 20])) == "val 20 "
    @test Juango.header_eq("Content-Type", "content-type") && !Juango.header_eq("a[", "a{") && !Juango.header_eq("ab", "abc")
end

import Mustache      # loads the Mustache extension (Juango.MustacheTemplates)

@testset "string_if_invalid, format_html, template engines" begin
    tr(s, ctx = Dict{String,Any}()) = render(Template(s), ctx)
    configure!(TEMPLATE_STRING_IF_INVALID = "INVALID(%s)")
    try
        @test tr("{{ missing.var }} {{ known }} {{ nope|upper }}", Dict("known" => "ok")) == "INVALID(missing.var) ok INVALID(nope)"
        @test tr("{% if missing %}yes{% else %}no{% endif %}") == "no"          # only output is affected
    finally
        configure!(TEMPLATE_STRING_IF_INVALID = "")
    end
    @test tr("[{{ missing }}]") == "[]"

    @test format_html("<a href=\"{}\">{}</a>", "/x?a=1&b=2", "<b>") == SafeString("<a href=\"/x?a=1&amp;b=2\">&lt;b&gt;</a>")
    @test format_html("{1}-{0} {name}", "a", mark_safe("<i>b</i>"); name = "<n>").s == "<i>b</i>-a &lt;n&gt;"
    @test format_html_join(", ", "<li>{}: {}</li>", [("a", 1), ("<b>", 2)]).s == "<li>a: 1</li>, <li>&lt;b&gt;: 2</li>"
    @test tr("{{ x }}", Dict("x" => format_html("<b>{}</b>", "&"))) == "<b>&amp;</b>"

    # a second engine: Mustache templates next to Juango's
    mdir = mktempdir()
    write(joinpath(mdir, "hello.mustache"), "Hi {{name}}! {{#items}}[{{.}}]{{/items}}")
    configure!(TEMPLATES = Any[Juango.JuangoTemplates(), Juango.MustacheTemplates(dirs = [mdir])])
    try
        @test render_to_string("hello.mustache", Dict("name" => "<Ann>", "items" => ["a", "b"])) == "Hi &lt;Ann&gt;! [a][b]"
        r = render(get(RequestFactory(), "/"), "hello.mustache", Dict("name" => "Bo", "items" => String[]))
        @test text(r) == "Hi Bo! " && r.templates == ["hello.mustache"]
        @test occursin("Hello", render_to_string("child.html", Dict("name" => "World")))     # Juango's engine still answers
        err = try get_template("nothing.mustache"); nothing catch e; e end
        @test err isa Juango.TemplateDoesNotExist && any(p -> startswith(p, mdir), err.tried)
    finally
        configure!(TEMPLATES = nothing)
    end

    # templates are cached; read again on change only with TEMPLATE_CACHE_CHECK_MTIME (default: with DEBUG)
    tdir = mktempdir()
    write(joinpath(tdir, "cached.html"), "one")
    old_debug = settings.DEBUG
    configure!(TEMPLATE_DIRS = vcat([tdir], settings.TEMPLATE_DIRS), TEMPLATE_CACHE_CHECK_MTIME = nothing, DEBUG = false)
    try
        @test render_to_string("cached.html") == "one"
        sleep(1.1); write(joinpath(tdir, "cached.html"), "two")
        @test render_to_string("cached.html") == "one"                          # production: read once
        configure!(DEBUG = true)
        @test render_to_string("cached.html") == "two"                          # development: reloaded
    finally
        configure!(TEMPLATE_DIRS = filter(!=(tdir), settings.TEMPLATE_DIRS), TEMPLATE_CACHE_CHECK_MTIME = true, DEBUG = old_debug)
    end
end

@testset "compiling templates in the background" begin
    override_settings(TEMPLATE_COMPILE = true) do
        @test Juango.COMPILE_TEMPLATES[] === :background
        t = Template("{% for x in xs %}{{ x|add:1 }},{% endfor %}{% if ok %}yes{% endif %}")
        ctx = Dict{String,Any}("xs" => [1, 2, 3], "ok" => true)
        @test render(t, ctx) == "2,3,4,yes"                     # interpreted while the task compiles it
        entry() = lock(() -> get(Juango.COMPILED_NODES, objectid(t.nodes), nothing), Juango.COMPILED_LOCK)
        @test entry() !== nothing
        t0 = time()
        while (e = entry(); e === nothing || e.f === nothing) && time() - t0 < 60
            sleep(0.05)
        end
        @test entry().f isa Function
        @test render(t, ctx) == "2,3,4,yes"                     # now through the compiled function
    end
    override_settings(TEMPLATE_COMPILE = false) do
        @test Juango.COMPILE_TEMPLATES[] === :interpret
    end
    try
        @test_throws Juango.ImproperlyConfigured configure!(TEMPLATE_COMPILE = :sometimes)
    finally
        configure!(TEMPLATE_COMPILE = :eager)
    end
    @test Juango.COMPILE_TEMPLATES[] === :eager                 # the test setup's
end
