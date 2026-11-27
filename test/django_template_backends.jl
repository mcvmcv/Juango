# Django's template_backends tests, ported (#227): test_django (DjangoTemplatesTests, with the TemplateStringsTests it
# inherits). Django's DjangoTemplates backend is Juango's `JuangoTemplates` engine; `engine.from_string(src)` and
# `engine.get_template(name)` are `from_string(engine, src)` and `get_template(engine, name)`.
# julia --project=test test/django_template_backends.jl   (see setup.jl)
#
# Not translated: test_dummy and test_jinja2 (Django's string.Template and Jinja2 backends; Juango's other engines are
# Mustache and LocMem), test_utils (TEMPLATES given as BACKEND paths), the per-engine `libraries` and `builtins`
# options (test_templatetag_discovery*, test_builtins_discovery: Juango's tag libraries are global, #302),
# test_default_template_loaders (Django's loader classes), RequestContext (Juango has no such type) and
# TemplateDoesNotExist.backend.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DTB_DIR = mktempdir()
for (path, src) in ["templates/template_backends/hello.html" => "Hello {{ name }}!\n",
                    "templates/template_backends/csrf.html" => "{% csrf_token %}",
                    "templates/template_backends/django_escaping.html" => "{{ media }}\n\n{{ test_form }}\n\n{{ test_form.test_field }}",
                    "templates/template_backends/syntax_error.html" => "{% block %}\n",
                    "forbidden/template_backends/hello.html" => "Hello {{ name }}!\n"]
    mkpath(dirname(joinpath(DTB_DIR, path)))
    write(joinpath(DTB_DIR, path), src)
end
const DTB_ENGINE = Juango.JuangoTemplates(dirs = [joinpath(DTB_DIR, "templates")], app_dirs = false)
dtb_throws(f, T, msg = "") = try f(); false catch e; e isa T && occursin(msg, sprint(showerror, e)) end
@form DtbTestForm begin
    test_field = CharField()
end
dtb_processor(req) = Dict("processors" => "yes")      # (Django's template_tests.test_response.test_processor)

@testset "django template_backends: test_django (DjangoTemplatesTests)" begin
    e = DTB_ENGINE
    @test render(Juango.from_string(e, "Hello!\n")) == "Hello!\n"                                     # test_from_string
    @test render(get_template(e, "template_backends/hello.html"), Dict("name" => "world")) == "Hello world!\n"  # test_get_template
    @test_throws Juango.TemplateDoesNotExist get_template(e, "template_backends/nonexistent.html")   # test_get_template_nonexistent
    @test_throws Juango.TemplateSyntaxError get_template(e, "template_backends/syntax_error.html")    # test_get_template_syntax_error
    content = render(get_template(e, "template_backends/hello.html"), Dict("name" => "<script>alert(\"XSS!\");</script>"))  # test_html_escaping
    @test occursin("&lt;script&gt;", content) && !occursin("<script>", content)
    media = Juango.Media(js = ["my-script.js"])                                                      # test_django_html_escaping
    form = DtbTestForm()
    content = render(get_template(e, "template_backends/django_escaping.html"), Dict("media" => media, "test_form" => form))
    @test assert_html_equal(content, Juango.conditional_escape(media) * "\n\n" * Juango.conditional_escape(form) * "\n\n" * Juango.conditional_escape(form[:test_field]))
    req = Request("GET", "/")                                                                        # test_csrf_token
    content = render(get_template(e, "template_backends/csrf.html"); request = req)
    m = match(r"^<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"([^\"]+)\">", content)
    @test m !== nothing && length(m[1]) == 64 && Juango.unmask_csrf(m[1]) == Juango.unmask_csrf(Juango.get_csrf_token(req))
    @test_throws Juango.TemplateDoesNotExist get_template(e, "../forbidden/template_backends/hello.html")  # test_no_directory_traversal
    @test render(get_template(e, "template_backends/hello.html"), Dict("name" => "Jérôme")) == "Hello Jérôme!\n"  # test_non_ascii_characters

    # test_context_has_priority_over_template_context_processors (#23789)
    pe = Juango.JuangoTemplates(dirs = String[], app_dirs = false, context_processors = Any[dtb_processor])
    t = Juango.from_string(pe, "{{ processors }}")
    @test render(t, Dict(); request = Request("GET", "/")) == "yes"
    @test render(t, Dict("processors" => "no"); request = Request("GET", "/")) == "no"
    t = Juango.from_string(Juango.JuangoTemplates(dirs = String[], app_dirs = false), "")              # test_render_requires_dict
    @test dtb_throws(() -> render(t, Juango.Context([Dict{String,Any}()], true, Dict{Symbol,Any}(), nothing)), ArgumentError,
                     "context must be a dict rather than Context.")
    # test_autoescape_off, test_autoescape_default
    @test render(Juango.from_string(Juango.JuangoTemplates(autoescape = false), "Hello, {{ name }}"), Dict("name" => "Bob & Jim")) == "Hello, Bob & Jim"
    @test render(Juango.from_string(Juango.JuangoTemplates(), "Hello, {{ name }}"), Dict("name" => "Bob & Jim")) == "Hello, Bob &amp; Jim"
    # test_dirs_pathlib (a directory given as a path)
    pe = Juango.JuangoTemplates(dirs = [joinpath(DTB_DIR, "templates", "template_backends")], app_dirs = false)
    @test render(get_template(pe, "hello.html"), Dict("name" => "Joe")) == "Hello Joe!\n"
end
