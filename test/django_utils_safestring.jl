# Django's utils_tests test_safestring.py, ported (#227): mark_safe in templates, values with their own __html__,
# mark_safe on functions, safe and unsafe text joined.
# julia --project=test test/django_utils_safestring.jl   (see setup.jl; no database needed)
#
# Julia joins text with `*`. Not translated: lazy strings and Promise, Python's attribute and __add__/__radd__
# protocols, the French gettext_lazy (Juango ships a German catalog only), html.escape returning SafeString (Juango's
# escape_html gives plain text: the escape filter marks it safe).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

struct DusCustomEscape
    s::String
end
Base.print(io::IO, x::DusCustomEscape) = print(io, x.s)
Juango.__html__(x::DusCustomEscape) = replace(x.s, "<" => "<<", ">" => ">>")      # (wrong on purpose: to see it ran)
struct DusObj end
Base.print(io::IO, ::DusObj) = print(io, "<obj>")

@testset "django utils_tests test_safestring: SafeStringTest" begin
    r(tpl; ctx...) = render(Template(tpl), Dict{String,Any}(string(k) => v for (k, v) in ctx))
    # test_mark_safe
    s = mark_safe("a&b")
    @test r("{{ s }}"; s) == "a&b"
    @test r("{{ s|force_escape }}"; s) == "a&amp;b"
    @test mark_safe(s) === s
    # test_mark_safe_object_implementing_dunder_html
    e = DusCustomEscape("<a&b>")
    @test mark_safe(e) === e
    @test r("{{ s }}"; s = mark_safe(e)) == "<<a&b>>"
    @test r("{{ s|force_escape }}"; s = mark_safe(e)) == "&lt;a&amp;b&gt;"
    # test_mark_safe_object_implementing_dunder_str / test_mark_safe_result_implements_dunder_html
    @test r("{{ s }}"; s = mark_safe(DusObj())) == "<obj>"
    @test Juango.__html__(mark_safe("a&b")) == "a&b"
    # test_mark_safe_as_decorator / test_mark_safe_decorator_does_not_affect_dunder_html
    provider() = "<html><body>dummy</body></html>"
    @test string(mark_safe(provider)()) == provider() && mark_safe(provider)() isa SafeString
    # test_add_str
    for (case, expected) in (("test", "a&amp;btest"), ("<p>unsafe</p>", "a&amp;b&lt;p&gt;unsafe&lt;/p&gt;"), (mark_safe("<p>safe</p>"), "a&b<p>safe</p>"))
        @test r("{{ s }}"; s = s * case) == expected
    end
    @test s * "x" isa String && "x" * s isa String && s * mark_safe("x") isa SafeString
end
