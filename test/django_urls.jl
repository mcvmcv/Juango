# Django's urlpatterns tests, ported (#227): tests/urlpatterns.
# julia --project=test test/django_urls.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dju_view(req; kw...) = HttpResponse("")
const DJU_INCLUDED = [path("extra/<extra>/", dju_view; name = "inner-extra"), re_path(raw"^more/(?P<extra>\w+)/$", dju_view; name = "inner-more")]
const DJU_URLS = Any[
    path("articles/2003/", dju_view; name = "articles-2003"),
    path("articles/<int:year>/", dju_view; name = "articles-year"),
    path("articles/<int:year>/<int:month>/", dju_view; name = "articles-year-month"),
    path("articles/<int:year>/<int:month>/<int:day>/", dju_view; name = "articles-year-month-day"),
    path("books/2007/", dju_view; name = "books-2007", extra = true),
    path("books/<int:year>/<int:month>/<int:day>/", dju_view; name = "books-year-month-day", extra = true),
    path("users/", dju_view; name = "users"),
    path("users/<id>/", dju_view; name = "user-with-id"),
    path("included_urls/", include_urls(DJU_INCLUDED)),
    re_path(raw"^regex/(?P<pk>[0-9]+)/$", dju_view; name = "regex"),
    re_path(raw"^regex_optional/(?P<arg1>\d+)/(?:(?P<arg2>\d+)/)?", dju_view; name = "regex_optional"),
    re_path(raw"^regex_only_optional/(?:(?P<arg1>\d+)/)?", dju_view; name = "regex_only_optional"),
    # converter_urls (before the catch-all)
    path("int/<int:int>/", dju_view; name = "int"), path("str/<str:str>/", dju_view; name = "str"),
    path("path/<path:path>/", dju_view; name = "path"), path("slug/<slug:slug>/", dju_view; name = "slug"),
    path("uuid/<uuid:uuid>/", dju_view; name = "uuid"),
    path("<lang>/<path:url>/", dju_view; name = "lang-and-path")]

@testset "django urlpatterns: SimplifiedURLTests" begin
    old = Juango.settings.ROOT_URLCONF
    configure!(ROOT_URLCONF = DJU_URLS)
    try
        # test_path_lookup_without_parameters, _with_typed_parameters, _with_multiple_parameters
        m = resolve("/articles/2003/")
        @test m.url_name == "articles-2003" && isempty(m.kwargs) && m.route == "articles/2003/"
        m = resolve("/articles/2015/")
        @test m.url_name == "articles-year" && m.kwargs == Dict(:year => 2015) && m.route == "articles/<int:year>/"
        m = resolve("/articles/2015/04/12/")
        @test m.kwargs == Dict(:year => 2015, :month => 4, :day => 12)
        # test_path_lookup_with_multiple_parameters_and_extra_kwarg, test_path_lookup_with_extra_kwarg
        @test resolve("/books/2015/04/12/").kwargs == Dict(:year => 2015, :month => 4, :day => 12, :extra => true)
        @test resolve("/books/2007/").kwargs == Dict(:extra => true)
        # test_two_variable_at_start_of_path_pattern
        m = resolve("/en/foo/")
        @test m.url_name == "lang-and-path" && m.kwargs == Dict(:lang => "en", :url => "foo")
        # test_re_path, test_re_path_with_optional_parameter, test_re_path_with_missing_optional_parameter
        m = resolve("/regex/1/")
        @test m.url_name == "regex" && m.kwargs == Dict(:pk => "1") && m.route == raw"^regex/(?P<pk>[0-9]+)/$"
        @test resolve("/regex_optional/1/2/").kwargs == Dict(:arg1 => "1", :arg2 => "2")
        @test resolve("/regex_optional/1/").kwargs == Dict(:arg1 => "1")
        @test isempty(resolve("/regex_only_optional/").kwargs)
        # test_path_lookup_with_inclusion, test_path_lookup_with_double_inclusion
        m = resolve("/included_urls/extra/something/")
        @test m.url_name == "inner-extra" && m.route == "included_urls/extra/<extra>/"
        @test resolve("/included_urls/more/some_value/").url_name == "inner-more"
        # test_path_reverse_without_parameter, test_path_reverse_with_parameter
        @test reverse_url("articles-2003") == "/articles/2003/"
        @test reverse_url("articles-year-month-day"; year = 2015, month = 4, day = 12) == "/articles/2015/4/12/"
        # test_path_trailing_newlines (\z, not $)
        for u in ["/articles/2003/\n", "/articles/2010/\n", "/en/foo/\n", "/included_urls/extra/\n", "/regex/1/\n", "/users/1/\n"]
            @test resolve(u) === nothing
        end
        # ConverterTests.test_matching_urls
        for (name, suffixes, conv) in (("int", ["0", "1", "01", "1234567890"], s -> parse(Int, s)), ("str", ["abcxyz"], identity),
                                       ("path", ["allows.ANY*characters"], identity), ("slug", ["abcxyz-ABCXYZ_01234567890"], identity),
                                       ("uuid", ["39da9369-838e-4750-91a5-f7805cd82839"], identity))
            for sfx in suffixes
                m = resolve("/$name/$sfx/")
                @test m.url_name == name && m.kwargs == Dict(Symbol(name) => conv(sfx))
                @test reverse_url(name; Symbol(name) => sfx) == "/$name/$sfx/"
            end
        end
        @test reverse_url("int"; int = 1) == "/int/1/"
        # test_nonmatching_urls
        for (name, suffixes) in (("int", ["-1", "letters"]), ("str", ["", "/"]), ("path", [""]), ("slug", ["", "stars*notallowed"]),
                                 ("uuid", ["", "9da9369-838e-4750-91a5-f7805cd82839", "39da9369-838-4750-91a5-f7805cd82839",
                                           "39da9369-838e-475-91a5-f7805cd82839", "39da9369-838e-4750-91a-f7805cd82839",
                                           "39da9369-838e-4750-91a5-f7805cd8283"]))
            for sfx in suffixes
                m = resolve("/$name/$sfx/")
                @test m === nothing || m.url_name != name
            end
        end
        # (an int too big for an Int: no match, not an error)
        m = resolve("/int/99999999999999999999999/")
        @test m === nothing || m.url_name != "int"
    finally
        configure!(ROOT_URLCONF = old)
    end
    # test_invalid_converter, test_whitespace_in_route
    @test_throws "URL route 'foo/<nonexistent:var>/' uses invalid converter 'nonexistent'." path("foo/<nonexistent:var>/", dju_view)
    for ws in (" ", "\t", "\n")
        @test_throws "cannot contain whitespace in angle brackets" path("space/<int:num>/extra/<str:$(ws)test>", dju_view)
    end
    p = path("space \t/<int:num>/", dju_view)                                             # (whitespace outside them is fine)
    @test match(p.regex, "space \t/1/") !== nothing
    # test_warning_override_default_converter
    @test_throws "Converter 'int' is already registered." Juango.register_converter!("int", "[0-9]+")
    # test_invalid_view
    @test_throws "view must be a callable or a list/tuple in the case of include(), but got str." path("articles/", "invalid_view")
    # ParameterRestrictionTests
    @test_throws "URL route 'hello/<int:1>/' uses parameter name '1' which isn't a valid Python identifier." path("hello/<int:1>/", dju_view)
    @test_throws "uses parameter name 'book.id' which isn't a valid Python identifier." path("b/<int:book.id>/", dju_view)
    p = path("hello/<str:Δ>/", dju_view)
    @test match(p.regex, "hello/1/")["Δ"] == "1"
    # ConversionExceptionTests: an ArgumentError from a converter is no match (Django's ValueError), others propagate
    haskey(Juango.CONVERTERS, "dynamic") || Juango.register_converter!("dynamic", "[0-9a-zA-Z]+",
        s -> s == "bad" ? throw(ArgumentError("no")) : s == "boom" ? error("This error propagates.") : s,
        v -> v == "bad" ? throw(ArgumentError("no")) : v == "boom" ? error("This error propagates.") : string(v))
    configure!(ROOT_URLCONF = [path("dynamic/<dynamic:value>/", dju_view; name = "dynamic")])
    try
        @test resolve("/dynamic/abc/").kwargs == Dict(:value => "abc")
        @test resolve("/dynamic/bad/") === nothing                                        # test_resolve_value_error_means_no_match
        @test_throws "This error propagates." resolve("/dynamic/boom/")                   # test_resolve_type_error_propagates
        @test_throws Juango.NoReverseMatch reverse_url("dynamic"; value = "bad")         # test_reverse_value_error_means_no_match
        @test_throws "This error propagates." reverse_url("dynamic"; value = "boom")     # test_reverse_type_error_propagates
    finally
        configure!(ROOT_URLCONF = old)
    end
    # not translated: captured_kwargs / extra_kwargs (Juango's ResolverMatch has the merged kwargs), simplify_regex
    # (admindocs), class-based view instances, the base64 converter's namespace tests (namespaces are in views.jl)
end
