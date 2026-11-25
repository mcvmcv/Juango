# Django's urlpatterns_reverse tests, ported (#227): URLPatternReverse (test_data and its messages, query and fragment),
# NamespaceTests, ResolverMatchTests, ResolverTests, LookaheadTests, ReverseResolvedTests, RequestURLconfTests,
# ReverseLazyTest, ReverseShortcutTests.
# julia --project=test test/django_urlpatterns_reverse.jl   (see setup.jl)
#
# re_path's extra kwargs are keyword arguments here (Django's positional dict). Left out: override_script_prefix
# (Juango has no script prefix), reversing by a dotted view path, ResolverMatch's repr, captured_kwargs and
# extra_kwargs (its kwargs are merged), include()'s tuple forms and its refusal of a namespace without an app_name
# (Juango's include_urls takes either), lazy reversing in settings, and Python-only details (pickling, partials).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dur_empty(req; kw...) = HttpResponse("")
dur_absolute(req; arg1 = 1, arg2 = 2) = HttpResponse("")
dur_defaults(req; arg1, arg2) = HttpResponse("")
dur_from_cbv(req; name) = HttpResponse("")

const DUR_INCLUDED = Any[path("", dur_empty; name = "inner-nothing"),
                         re_path(raw"extra/(?P<extra>\w+)/$", dur_empty; name = "inner-extra"),
                         re_path(raw"(?P<one>[0-9]+)|(?P<two>[0-9]+)/$", dur_empty; name = "inner-disjunction")]
const DUR_INCLUDED2 = Any[re_path(raw"^part/(?P<value>\w+)/$", dur_empty; name = "part"),
                          re_path(raw"^part2/(?:(?P<value>\w+)/)?$", dur_empty; name = "part2")]
const DUR_EXTRA = Any[re_path(raw"^e-places/([0-9]+)/$", dur_empty; name = "extra-places"),
                      re_path(raw"^e-people/(?P<name>\w+)/$", dur_empty; name = "extra-people"),
                      path("", include_urls(DUR_INCLUDED2)),
                      re_path(raw"^prefix/(?P<prefix>\w+)/", include_urls(DUR_INCLUDED2))]
dur_nested(req) = HttpResponse("")
const DUR_OTHER = Any[path("non_path_include/", dur_empty; name = "non_path_include"), path("nested_path/", dur_nested)]
const DUR_URLS = Any[
    re_path(raw"^places/([0-9]+)/$", dur_empty; name = "places"),
    re_path(raw"^places?/$", dur_empty; name = "places?"),
    re_path(raw"^places+/$", dur_empty; name = "places+"),
    re_path(raw"^places*/$", dur_empty; name = "places*"),
    re_path(raw"^(?:places/)?$", dur_empty; name = "places2?"),
    re_path(raw"^(?:places/)+$", dur_empty; name = "places2+"),
    re_path(raw"^(?:places/)*$", dur_empty; name = "places2*"),
    re_path(raw"^places/([0-9]+|[a-z_]+)/", dur_empty; name = "places3"),
    re_path(raw"^places/(?P<id>[0-9]+)/$", dur_empty; name = "places4"),
    re_path(raw"^people/(?P<name>\w+)/$", dur_empty; name = "people"),
    re_path(raw"^people/(?:name/)$", dur_empty; name = "people2"),
    re_path(raw"^people/(?:name/(\w+)/)?$", dur_empty; name = "people2a"),
    re_path(raw"^people/(?P<name>\w+)-(?P=name)/$", dur_empty; name = "people_backref"),
    re_path(raw"^optional/(?P<name>.*)/(?:.+/)?", dur_empty; name = "optional"),
    re_path(raw"^optional/(?P<arg1>\d+)/(?:(?P<arg2>\d+)/)?", dur_absolute; name = "named_optional"),
    re_path(raw"^optional/(?P<arg1>\d+)/(?:(?P<arg2>\d+)/)?$", dur_absolute; name = "named_optional_terminated"),
    re_path(raw"^nested/noncapture/(?:(?P<p>\w+))$", dur_empty; name = "nested-noncapture"),
    re_path(raw"^nested/capture/((\w+)/)?$", dur_empty; name = "nested-capture"),
    re_path(raw"^nested/capture/mixed/((?P<p>\w+))$", dur_empty; name = "nested-mixedcapture"),
    re_path(raw"^nested/capture/named/(?P<outer>(?P<inner>\w+)/)?$", dur_empty; name = "nested-namedcapture"),
    re_path(raw"^hardcoded/$", dur_empty; name = "hardcoded"),
    re_path(raw"^hardcoded/doc\.pdf$", dur_empty; name = "hardcoded2"),
    re_path(raw"^people/(?P<state>\w\w)/(?P<name>\w+)/$", dur_empty; name = "people3"),
    re_path(raw"^people/(?P<state>\w\w)/(?P<name>[0-9])/$", dur_empty; name = "people4"),
    re_path(raw"^people/((?P<state>\w\w)/test)?/(\w+)/$", dur_empty; name = "people6"),
    re_path(raw"^character_set/[abcdef0-9]/$", dur_empty; name = "range"),
    re_path(raw"^character_set/[\w]/$", dur_empty; name = "range2"),
    re_path(raw"^price/\$([0-9]+)/$", dur_empty; name = "price"),
    re_path(raw"^price/[$]([0-9]+)/$", dur_empty; name = "price2"),
    re_path(raw"^price/[\$]([0-9]+)/$", dur_empty; name = "price3"),
    re_path(raw"^product/(?P<product>\w+)\+\(\$(?P<price>[0-9]+(\.[0-9]+)?)\)/$", dur_empty; name = "product"),
    re_path(raw"^headlines/(?P<year>[0-9]+)\.(?P<month>[0-9]+)\.(?P<day>[0-9]+)/$", dur_empty; name = "headlines"),
    re_path(raw"^windows_path/(?P<drive_name>[A-Z]):\\(?P<path>.+)/$", dur_empty; name = "windows"),
    re_path(raw"^special_chars/(?P<chars>.+)/$", dur_empty; name = "special"),
    re_path(raw"^resolved/(?P<arg>\d+)/$", dur_empty; name = "resolved", extra = true),
    re_path(raw"^resolved-overridden/(?P<arg>\d+)/(?P<overridden>\w+)/$", dur_empty; name = "resolved-overridden", extra = true, overridden = "default"),
    re_path(raw"^(?P<name>.+)/[0-9]+/$", dur_empty; name = "mixed"),
    re_path(raw"^repeats/a{1,2}/$", dur_empty; name = "repeats"),
    re_path(raw"^repeats/a{2,4}/$", dur_empty; name = "repeats2"),
    re_path(raw"^repeats/a{2}/$", dur_empty; name = "repeats3"),
    re_path(raw"^test/1/?", dur_empty; name = "test"),
    re_path(raw"^outer/(?P<outer>[0-9]+)/", include_urls(DUR_INCLUDED)),
    re_path(raw"^outer-no-kwargs/([0-9]+)/", include_urls(Any[re_path(raw"^inner-no-kwargs/([0-9]+)/$", dur_empty; name = "inner-no-kwargs")])),
    re_path("", include_urls(DUR_EXTRA)),
    re_path(raw"^lookahead-/(?!not-a-city)(?P<city>[^/]+)/$", dur_empty; name = "lookahead-negative"),
    re_path(raw"^lookahead\+/(?=a-city)(?P<city>[^/]+)/$", dur_empty; name = "lookahead-positive"),
    re_path(raw"^lookbehind-/(?P<city>[^/]+)(?<!not-a-city)/$", dur_empty; name = "lookbehind-negative"),
    re_path(raw"^lookbehind\+/(?P<city>[^/]+)(?<=a-city)/$", dur_empty; name = "lookbehind-positive"),
    re_path(raw"^(?:foo|bar)(\w+)/$", dur_empty; name = "disjunction"),
    path("absolute_arg_view/", dur_absolute),
    re_path(raw"^defaults_view1/(?P<arg1>[0-9]+)/$", dur_defaults; name = "defaults", arg2 = 1),
    re_path(raw"^defaults_view2/(?P<arg1>[0-9]+)/$", dur_defaults; name = "defaults", arg2 = 2),
    path("includes/", include_urls(DUR_OTHER)),
    re_path("(.+)/security/\$", dur_empty; name = "security"),
    path("hello/<slug:name>/", dur_from_cbv),
]
const NRM = Juango.NoReverseMatch
const DUR_TEST_DATA = Any[
    ("places", "/places/3/", [3], ()), ("places", "/places/3/", ["3"], ()), ("places", NRM, ["a"], ()), ("places", NRM, [], ()),
    ("places?", "/place/", [], ()), ("places+", "/places/", [], ()), ("places*", "/place/", [], ()),
    ("places2?", "/", [], ()), ("places2+", "/places/", [], ()), ("places2*", "/", [], ()),
    ("places3", "/places/4/", [4], ()), ("places3", "/places/harlem/", ["harlem"], ()), ("places3", NRM, ["harlem64"], ()),
    ("places4", "/places/3/", [], (id = 3,)),
    ("people", NRM, [], ()), ("people", "/people/adrian/", ["adrian"], ()), ("people", "/people/adrian/", [], (name = "adrian",)),
    ("people", NRM, ["name with spaces"], ()), ("people", NRM, [], (name = "name with spaces",)),
    ("people2", "/people/name/", [], ()), ("people2a", "/people/name/fred/", ["fred"], ()),
    ("people_backref", "/people/nate-nate/", ["nate"], ()), ("people_backref", "/people/nate-nate/", [], (name = "nate",)),
    ("optional", "/optional/fred/", [], (name = "fred",)), ("optional", "/optional/fred/", ["fred"], ()),
    ("named_optional", "/optional/1/", [1], ()), ("named_optional", "/optional/1/", [], (arg1 = 1,)),
    ("named_optional", "/optional/1/2/", [1, 2], ()), ("named_optional", "/optional/1/2/", [], (arg1 = 1, arg2 = 2)),
    ("named_optional_terminated", "/optional/1/", [1], ()), ("named_optional_terminated", "/optional/1/", [], (arg1 = 1,)),
    ("named_optional_terminated", "/optional/1/2/", [1, 2], ()), ("named_optional_terminated", "/optional/1/2/", [], (arg1 = 1, arg2 = 2)),
    ("hardcoded", "/hardcoded/", [], ()), ("hardcoded2", "/hardcoded/doc.pdf", [], ()),
    ("people3", "/people/il/adrian/", [], (state = "il", name = "adrian")), ("people3", NRM, [], (state = "il",)),
    ("people3", NRM, [], (name = "adrian",)), ("people4", NRM, [], (state = "il", name = "adrian")),
    ("people6", "/people/il/test/adrian/", ["il/test", "adrian"], ()), ("people6", "/people//adrian/", ["adrian"], ()),
    ("range", "/character_set/a/", [], ()), ("range2", "/character_set/x/", [], ()),
    ("price", "/price/\$10/", ["10"], ()), ("price2", "/price/\$10/", ["10"], ()), ("price3", "/price/\$10/", ["10"], ()),
    ("product", "/product/chocolate+(\$2.00)/", [], (price = "2.00", product = "chocolate")),
    ("headlines", "/headlines/2007.5.21/", [], (year = 2007, month = 5, day = 21)),
    ("windows", raw"/windows_path/C:%5CDocuments%20and%20Settings%5Cspam/", [], (drive_name = "C", path = raw"Documents and Settings\spam")),
    ("special", raw"/special_chars/~@+%5C$*%7C/", [raw"~@+\$*|"], ()),
    ("special", raw"/special_chars/some%20resource/", ["some resource"], ()),
    ("special", raw"/special_chars/10%25%20complete/", ["10% complete"], ()),
    ("special", raw"/special_chars/some%20resource/", [], (chars = "some resource",)),
    ("special", raw"/special_chars/10%25%20complete/", [], (chars = "10% complete",)),
    ("special", NRM, [""], ()),
    ("mixed", "/john/0/", [], (name = "john",)),
    ("repeats", "/repeats/a/", [], ()), ("repeats2", "/repeats/aa/", [], ()), ("repeats3", "/repeats/aa/", [], ()),
    ("test", "/test/1", [], ()),
    ("inner-nothing", "/outer/42/", [], (outer = "42",)), ("inner-nothing", "/outer/42/", ["42"], ()), ("inner-nothing", NRM, ["foo"], ()),
    ("inner-extra", "/outer/42/extra/inner/", [], (extra = "inner", outer = "42")), ("inner-extra", "/outer/42/extra/inner/", ["42", "inner"], ()),
    ("inner-extra", NRM, ["fred", "inner"], ()),
    ("inner-no-kwargs", "/outer-no-kwargs/42/inner-no-kwargs/1/", ["42", "1"], ()),
    ("disjunction", NRM, ["foo"], ()), ("inner-disjunction", NRM, ["10", "11"], ()),
    ("extra-places", "/e-places/10/", ["10"], ()), ("extra-people", "/e-people/fred/", ["fred"], ()), ("extra-people", "/e-people/fred/", [], (name = "fred",)),
    ("part", "/part/one/", [], (value = "one",)), ("part", "/prefix/xx/part/one/", [], (value = "one", prefix = "xx")),
    ("part2", "/part2/one/", [], (value = "one",)), ("part2", "/part2/", [], ()),
    ("part2", "/prefix/xx/part2/one/", [], (value = "one", prefix = "xx")), ("part2", "/prefix/xx/part2/", [], (prefix = "xx",)),
    ("nested-noncapture", "/nested/noncapture/opt", [], (p = "opt",)),
    ("nested-capture", "/nested/capture/opt/", ["opt/"], ()), ("nested-capture", NRM, [], (p = "opt",)),
    ("nested-mixedcapture", "/nested/capture/mixed/opt", ["opt"], ()), ("nested-mixedcapture", NRM, [], (p = "opt",)),
    ("nested-namedcapture", "/nested/capture/named/opt/", [], (outer = "opt/",)),
    ("nested-namedcapture", NRM, [], (outer = "opt/", inner = "opt")), ("nested-namedcapture", NRM, [], (inner = "opt",)),
    ("non_path_include", "/includes/non_path_include/", [], ()),
    ("defaults", "/defaults_view1/3/", [], (arg1 = 3, arg2 = 1)), ("defaults", "/defaults_view2/3/", [], (arg1 = 3, arg2 = 2)),
    ("defaults", NRM, [], (arg1 = 3, arg2 = 3)), ("defaults", NRM, [], (arg2 = 1,)),
    ("security", "/%2Fexample.com/security/", ["/example.com"], ()),
]
dur_rev(name, args...; kw...) = reverse_url(name, args...; urlconf = DUR_URLS, kw...)
dur_msg(f) = try; f(); "no error"; catch e; sprint(showerror, e); end

@testset "django urlpatterns_reverse: URLPatternReverse" begin
    # test_urlpattern_reverse
    for (name, expected, args, kwargs) in DUR_TEST_DATA
        got = try
            dur_rev(name, args...; kwargs...)
        catch e
            e isa NRM || rethrow()
            NRM
        end
        got == expected || @info "reverse" name args kwargs got expected
        @test got == expected
    end
    @test_throws NRM reverse_url(nothing; urlconf = DUR_URLS)                                # test_reverse_none
    @test occursin("Don't mix *args and **kwargs in call to reverse()!", dur_msg(() -> dur_rev("name", "a"; b = "c")))   # test_mixing_args_and_kwargs
    # test_patterns_reported
    @test occursin(raw"1 pattern(s) tried: ['people/(?P<name>\\w+)/$']", dur_msg(() -> dur_rev("people")))
    # test_view_not_found_message, test_no_args_message, test_illegal_args_message, test_illegal_kwargs_message
    @test occursin("Reverse for 'nonexistent-view' not found. 'nonexistent-view' is not a valid view function or pattern name.",
                   dur_msg(() -> dur_rev("nonexistent-view")))
    @test occursin("Reverse for 'places' with no arguments not found. 1 pattern(s) tried:", dur_msg(() -> dur_rev("places")))
    @test occursin("Reverse for 'places' with arguments '(1, 2)' not found. 1 pattern(s) tried:", dur_msg(() -> dur_rev("places", 1, 2)))
    @test occursin("Reverse for 'places' with keyword arguments '{'arg1': 2}' not found. 1 pattern(s) tried:", dur_msg(() -> dur_rev("places"; arg1 = 2)))
    # test_view_func_from_cbv, test_view_func_from_cbv_no_expected_kwarg: reversing by the view
    @test dur_rev(dur_from_cbv; name = "world") == "/hello/world/"
    @test_throws NRM dur_rev(dur_from_cbv)
    # test_reverse_with_query, ..._sequences, ..._fragment, ..._not_encoded, ..._query_and_fragment, ..._empty_fragment
    @test dur_rev("test"; query = (hello = "world", foo = 123)) == "/test/1?hello=world&foo=123"
    for q in ([("hello", "world"), ("foo", 123), ("foo", 456)], (("hello", "world"), ("foo", 123), ("foo", 456)),
              (hello = "world", foo = (123, 456)), ["hello" => "world", "foo" => 123, "foo" => 456])
        @test dur_rev("test"; query = q) == "/test/1?hello=world&foo=123&foo=456"
    end
    @test dur_rev("test"; fragment = "tab-1") == "/test/1#tab-1"
    @test dur_rev("test"; fragment = "tab 1 is the best!") == "/test/1#tab 1 is the best!"
    @test dur_rev("test"; query = (hello = "world", foo = 123), fragment = "tab-1") == "/test/1?hello=world&foo=123#tab-1"
    @test dur_rev("test"; fragment = nothing) == "/test/1" && dur_rev("test"; fragment = "") == "/test/1#"
    # test_reverse_with_invalid_fragment, test_reverse_with_empty_query, test_reverse_with_invalid_query
    for f in (0, false, Dict(), [], Set(), ())
        @test_throws ArgumentError dur_rev("test"; fragment = f)
    end
    for q in (nothing, "", Dict(), [], Set(), (), Juango.QueryDict(""))
        @test dur_rev("test"; query = q) == "/test/1"
    end
    for q in (0, false, [1, 3, 5], Set([1, 2, 3]))
        @test_throws ArgumentError dur_rev("test"; query = q)
    end
    # test_reverse_encodes_query_string, test_reverse_with_query_from_querydict
    @test dur_rev("test"; query = ["hello world" => "django project", "foo" => [123, 456], "@invalid" => ["?", "!", "a b"]]) ==
          "/test/1?hello+world=django+project&foo=123&foo=456&%40invalid=%3F&%40invalid=%21&%40invalid=a+b"
    @test dur_rev("test"; query = Juango.QueryDict("a=1&b=2&b=3&c=4")) == "/test/1?a=1&b=2&b=3&c=4"
end

# namespace_urls and included_namespace_urls, which include each other: Julia builds them to a depth (Django's are
# one module each, so the cycle is lazy), deep enough for the paths the tests take.
dur_class_view(req; kw...) = HttpResponse("")
const DUR_URLOBJECT = Any[path("inner/", dur_empty; name = "urlobject-view"),
                          re_path(raw"^inner/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty; name = "urlobject-view"),
                          re_path(raw"^inner/\+\\\$\*/$", dur_empty; name = "urlobject-special-view")]
const DUR_INCLUDED_URLS = Any[path("", dur_empty; name = "inner-nothing"),
                              re_path(raw"extra/(?P<extra>\w+)/$", dur_empty; name = "inner-extra"),
                              re_path(raw"(?P<one>[0-9]+)|(?P<two>[0-9]+)/$", dur_empty; name = "inner-disjunction")]
const DUR_APP_URLS = Any[path("normal/", dur_empty; name = "inc-normal-view"),
                         re_path(raw"^normal/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty; name = "inc-normal-view"),
                         re_path(raw"^\+\\\$\*/$", dur_empty; name = "inc-special-view"),
                         re_path(raw"^mixed_args/([0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty; name = "inc-mixed-args"),
                         re_path(raw"^no_kwargs/([0-9]+)/([0-9]+)/$", dur_empty; name = "inc-no-kwargs"),
                         re_path(raw"^view_class/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_class_view; name = "inc-view-class")]
function dur_inc_ns_urls(d)
    ps = Any[DUR_APP_URLS...,
             path("test3/", include_urls(DUR_URLOBJECT; app_name = "testapp", namespace = "test-ns3")),
             path("test4/", include_urls(DUR_URLOBJECT; app_name = "testapp", namespace = "test-ns4")),
             path("ns-included3/", include_urls(DUR_INCLUDED_URLS; app_name = "included_urls", namespace = "inc-ns3"))]
    d > 1 && push!(ps, path("ns-included4/", include_urls(dur_ns_urls(d - 1); app_name = "namespace_urls", namespace = "inc-ns4")))
    ps
end
dur_inc(d; kw...) = include_urls(dur_inc_ns_urls(d); app_name = "included_namespace_urls", kw...)
function dur_ns_urls(d)
    ps = Any[path("normal/", dur_empty; name = "normal-view"),
             re_path(raw"^normal/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty; name = "normal-view"),
             path("resolver_match/", dur_empty; name = "test-resolver-match"),
             re_path(raw"^\+\\\$\*/$", dur_empty; name = "special-view"),
             re_path(raw"^mixed_args/([0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty; name = "mixed-args", extra = true),
             re_path(raw"^no_kwargs/([0-9]+)/([0-9]+)/$", dur_empty; name = "no-kwargs"),
             re_path(raw"^view_class/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_class_view; name = "view-class"),
             re_path(raw"^unnamed/normal/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_empty),
             re_path(raw"^unnamed/view_class/(?P<arg1>[0-9]+)/(?P<arg2>[0-9]+)/$", dur_class_view),
             path("test1/", include_urls(DUR_URLOBJECT; app_name = "testapp", namespace = "test-ns1")),
             path("test2/", include_urls(DUR_URLOBJECT; app_name = "testapp", namespace = "test-ns2")),
             path("default/", include_urls(DUR_URLOBJECT; app_name = "testapp", namespace = "testapp")),
             path("other1/", include_urls(DUR_URLOBJECT; app_name = "nodefault", namespace = "other-ns1")),
             re_path(raw"^other[246]/", include_urls(DUR_URLOBJECT; app_name = "nodefault", namespace = "other-ns2")),
             path("newapp1/", include_urls(DUR_URLOBJECT; app_name = "newapp", namespace = "new-ns1")),
             path("new-default/", include_urls(DUR_URLOBJECT; app_name = "newapp")),
             re_path(raw"^app-included[135]/", include_urls(DUR_APP_URLS; app_name = "inc-app", namespace = "app-ns1")),
             path("app-included2/", include_urls(DUR_APP_URLS; app_name = "inc-app", namespace = "app-ns2")),
             re_path(raw"^ns-included[135]/", dur_inc(d; namespace = "inc-ns1")),
             path("ns-included2/", dur_inc(d; namespace = "inc-ns2")),
             path("app-included/", dur_inc(d; namespace = "inc-app")),
             path("included/", dur_inc(d)),
             re_path(raw"^inc(?P<outer>[0-9]+)/", include_urls(DUR_INCLUDED_URLS; app_name = "included_urls", namespace = "inc-ns5")),
             re_path(raw"^included/([0-9]+)/", dur_inc(d)),
             re_path(raw"^ns-outer/(?P<outer>[0-9]+)/", dur_inc(d; namespace = "inc-outer"))]
    d > 1 && push!(ps, re_path(raw"^\+\\\$\*/", include_urls(dur_ns_urls(d - 1); app_name = "namespace_urls", namespace = "special")))
    ps
end
const DUR_NS_URLS = dur_ns_urls(3)
dur_ns(name, args...; kw...) = reverse_url(name, args...; urlconf = DUR_NS_URLS, kw...)
dur_ns_ok(name, args...; kw...) = try; dur_ns(name, args...; kw...); catch e; e isa NRM ? NRM : rethrow(); end

@testset "django urlpatterns_reverse: NamespaceTests" begin
    # test_ambiguous_object, test_ambiguous_urlpattern, test_non_existent_namespace
    for n in ("urlobject-view", "inner-nothing")
        @test dur_ns_ok(n) === NRM && dur_ns_ok(n, 37, 42) === NRM && dur_ns_ok(n; arg1 = 42, arg2 = 37) === NRM
    end
    @test dur_ns_ok("blahblah:urlobject-view") === NRM && dur_ns_ok("test-ns1:blahblah:urlobject-view") === NRM
    @test occursin("'blahblah' is not a registered namespace", dur_msg(() -> dur_ns("blahblah:urlobject-view")))
    @test occursin("'blahblah' is not a registered namespace inside 'test-ns1'", dur_msg(() -> dur_ns("test-ns1:blahblah:urlobject-view")))
    # the four forms each test takes: no arguments, positional, keyword, the special view
    function four(prefix, base, view = "urlobject-view", special = "urlobject-special-view"; current_app = nothing)
        @test dur_ns("$prefix$view"; current_app) == "$base"
        @test dur_ns("$prefix$view", 37, 42; current_app) == "$(base)37/42/"
        @test dur_ns("$prefix$view"; arg1 = 42, arg2 = 37, current_app) == "$(base)42/37/"
        @test dur_ns("$prefix$special"; current_app) == "$(chop(base; tail = length("normal/") * (view == "normal-view" || view == "inc-normal-view")))+%5C\$*/"
    end
    four("", "/normal/", "normal-view", "special-view")                                                     # test_normal_name
    four("included_namespace_urls:", "/included/normal/", "inc-normal-view", "inc-special-view")          # test_simple_included_name
    four("test-ns1:", "/test1/inner/")                                                                    # test_namespace_object
    four("new-ns1:", "/newapp1/inner/")                                                                   # test_app_object
    four("newapp:", "/new-default/inner/")                                                                # test_app_object_default_namespace
    four("included_namespace_urls:test-ns3:", "/included/test3/inner/")                                   # test_embedded_namespace_object
    four("inc-ns1:", "/ns-included1/normal/", "inc-normal-view", "inc-special-view")                      # test_namespace_pattern
    four("app-ns1:", "/app-included1/normal/", "inc-normal-view", "inc-special-view")                     # test_app_name_pattern
    four("inc-ns1:test-ns3:", "/ns-included1/test3/inner/")                                               # test_multiple_namespace_pattern
    four("inc-ns1:inc-ns4:inc-ns1:test-ns3:", "/ns-included1/ns-included4/ns-included1/test3/inner/")     # test_nested_namespace_pattern
    four("testapp:", "/default/inner/")                                                                   # test_app_lookup_object
    four("testapp:", "/default/inner/"; current_app = "test-ns3")                                        # test_app_lookup_object_with_default
    four("nodefault:", "/other2/inner/")                                                                  # test_app_lookup_object_without_default
    four("nodefault:", "/other1/inner/"; current_app = "other-ns1")
    four("special:included_namespace_urls:", "/+%5C\$*/included/normal/", "inc-normal-view", "inc-special-view")   # test_special_chars_namespace
    four("inc-ns1:testapp:", "/ns-included1/test4/inner/")                                                # test_nested_app_lookup
    four("inc-ns1:testapp:", "/ns-included1/test3/inner/"; current_app = "inc-ns1:test-ns3")
    four("inc-ns1:testapp:", "/ns-included1/test4/inner/"; current_app = "nonexistent:test-ns3")          # test_current_app_no_partial_match
    # test_namespace_pattern_with_variable_prefix
    @test dur_ns("inc-outer:inc-normal-view"; outer = 42) == "/ns-outer/42/normal/"
    @test dur_ns("inc-outer:inc-normal-view", 42) == "/ns-outer/42/normal/"
    @test dur_ns("inc-outer:inc-normal-view"; arg1 = 37, arg2 = 4, outer = 42) == "/ns-outer/42/normal/37/4/"
    @test dur_ns("inc-outer:inc-normal-view", 42, 37, 4) == "/ns-outer/42/normal/37/4/"
    @test dur_ns("inc-outer:inc-special-view"; outer = 42) == "/ns-outer/42/+%5C\$*/"
    @test dur_ns("inc-outer:inc-special-view", 42) == "/ns-outer/42/+%5C\$*/"
    # test_namespaces_with_variables
    @test dur_ns("inc-ns5:inner-nothing"; outer = "70") == "/inc70/"
    @test dur_ns("inc-ns5:inner-extra"; extra = "foobar", outer = "78") == "/inc78/extra/foobar/"
    @test dur_ns("inc-ns5:inner-nothing", "70") == "/inc70/"
    @test dur_ns("inc-ns5:inner-extra", "78", "foobar") == "/inc78/extra/foobar/"
end

@testset "django urlpatterns_reverse: ResolverMatchTests" begin
    # test_urlpattern_resolve: (path, url_name, app_name, namespace, view_name, view, args, kwargs); Django's "" is nothing
    kw2 = Dict{Symbol,Any}(:arg1 => "42", :arg2 => "37")
    for (p, name, app, ns, vname, view, args, kwargs) in (
            ("/normal/42/37/", "normal-view", nothing, nothing, "normal-view", dur_empty, [], kw2),
            ("/view_class/42/37/", "view-class", nothing, nothing, "view-class", dur_class_view, [], kw2),
            ("/included/normal/42/37/", "inc-normal-view", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-normal-view", dur_empty, [], kw2),
            ("/included/view_class/42/37/", "inc-view-class", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-view-class", dur_class_view, [], kw2),
            ("/mixed_args/42/37/", "mixed-args", nothing, nothing, "mixed-args", dur_empty, [], Dict{Symbol,Any}(:extra => true, :arg2 => "37")),
            ("/included/mixed_args/42/37/", "inc-mixed-args", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-mixed-args", dur_empty, [], Dict{Symbol,Any}(:arg2 => "37")),
            ("/included/12/mixed_args/42/37/", "inc-mixed-args", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-mixed-args", dur_empty, [], Dict{Symbol,Any}(:arg2 => "37")),
            ("/unnamed/normal/42/37/", nothing, nothing, nothing, nothing, dur_empty, [], kw2),          # (Django's view_name: the view's dotted path)
            ("/no_kwargs/42/37/", "no-kwargs", nothing, nothing, "no-kwargs", dur_empty, ["42", "37"], Dict{Symbol,Any}()),
            ("/included/no_kwargs/42/37/", "inc-no-kwargs", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-no-kwargs", dur_empty, ["42", "37"], Dict{Symbol,Any}()),
            ("/included/12/no_kwargs/42/37/", "inc-no-kwargs", "included_namespace_urls", "included_namespace_urls",
             "included_namespace_urls:inc-no-kwargs", dur_empty, ["12", "42", "37"], Dict{Symbol,Any}()),
            ("/test1/inner/42/37/", "urlobject-view", "testapp", "test-ns1", "test-ns1:urlobject-view", dur_empty, [], kw2),
            ("/included/test3/inner/42/37/", "urlobject-view", "included_namespace_urls:testapp", "included_namespace_urls:test-ns3",
             "included_namespace_urls:test-ns3:urlobject-view", dur_empty, [], kw2),
            ("/ns-included1/normal/42/37/", "inc-normal-view", "included_namespace_urls", "inc-ns1", "inc-ns1:inc-normal-view", dur_empty, [], kw2),
            ("/default/inner/42/37/", "urlobject-view", "testapp", "testapp", "testapp:urlobject-view", dur_empty, [], kw2),
            ("/other2/inner/42/37/", "urlobject-view", "nodefault", "other-ns2", "other-ns2:urlobject-view", dur_empty, [], kw2),
            ("/other1/inner/42/37/", "urlobject-view", "nodefault", "other-ns1", "other-ns1:urlobject-view", dur_empty, [], kw2),
            ("/ns-included1/test3/inner/42/37/", "urlobject-view", "included_namespace_urls:testapp", "inc-ns1:test-ns3",
             "inc-ns1:test-ns3:urlobject-view", dur_empty, [], kw2),
            ("/ns-included1/ns-included4/ns-included2/test3/inner/42/37/", "urlobject-view",
             "included_namespace_urls:namespace_urls:included_namespace_urls:testapp", "inc-ns1:inc-ns4:inc-ns2:test-ns3",
             "inc-ns1:inc-ns4:inc-ns2:test-ns3:urlobject-view", dur_empty, [], kw2),
            ("/app-included/test3/inner/42/37/", "urlobject-view", "included_namespace_urls:testapp", "inc-app:test-ns3",
             "inc-app:test-ns3:urlobject-view", dur_empty, [], kw2),
            ("/app-included/ns-included4/ns-included2/test3/inner/42/37/", "urlobject-view",
             "included_namespace_urls:namespace_urls:included_namespace_urls:testapp", "inc-app:inc-ns4:inc-ns2:test-ns3",
             "inc-app:inc-ns4:inc-ns2:test-ns3:urlobject-view", dur_empty, [], kw2),
            ("/inc70/", "inner-nothing", "included_urls", "inc-ns5", "inc-ns5:inner-nothing", dur_empty, [], Dict{Symbol,Any}(:outer => "70")),
            ("/inc78/extra/foobar/", "inner-extra", "included_urls", "inc-ns5", "inc-ns5:inner-extra", dur_empty, [],
             Dict{Symbol,Any}(:outer => "78", :extra => "foobar")))
        m = resolve(p, DUR_NS_URLS)
        ok = m !== nothing && m.url_name == name && m.app_name == app && m.namespace == ns && m.view_name == vname &&
             m.view === view && m.args == args && m.kwargs == kwargs
        ok || @info "resolve" p m
        @test ok
    end
end

const DUR_CONFLICT = Any[path("conflict/cannot-go-here/", dur_empty; name = "name-conflict"),
                         path("conflict/", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict-first/(?P<first>\w+)/$", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict-cannot-go-here/(?P<middle>\w+)/$", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict-middle/(?P<middle>\w+)/$", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict-last/(?P<last>\w+)/$", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict/(?P<another>\w+)/(?P<extra>\w+)/cannot-go-here/$", dur_empty; name = "name-conflict"),
                         re_path(raw"^conflict/(?P<extra>\w+)/(?P<another>\w+)/$", dur_empty; name = "name-conflict")]
const DUR_NAMED = Any[path("", dur_empty; name = "named-url1"), re_path(raw"^extra/(?P<extra>\w+)/$", dur_empty; name = "named-url2"),
                      re_path(raw"^(?P<one>[0-9]+)|(?P<two>[0-9]+)/$", dur_empty)]

@testset "django urlpatterns_reverse: ResolverTests, LookaheadTests, ReverseResolvedTests" begin
    # test_resolver_reverse
    @test reverse_url("named-url1"; urlconf = DUR_NAMED) == "/"
    @test reverse_url("named-url2", "arg"; urlconf = DUR_NAMED) == "/extra/arg/" && reverse_url("named-url2"; extra = "arg", urlconf = DUR_NAMED) == "/extra/arg/"
    # test_resolver_reverse_conflict: the last pattern of a name first; with arguments, the one they fit
    rc(args...; kw...) = reverse_url("name-conflict", args...; urlconf = DUR_CONFLICT, kw...)
    @test rc() == "/conflict/" && rc("arg") == "/conflict-last/arg/"
    @test rc(; first = "arg") == "/conflict-first/arg/" && rc(; middle = "arg") == "/conflict-middle/arg/" && rc(; last = "arg") == "/conflict-last/arg/"
    @test rc("arg", "arg") == "/conflict/arg/arg/"
    # (test_non_regex: Django's resolve needs a leading "/"; Juango's takes a path with or without it)
    # LookaheadTests
    for u in ("/lookahead-/a-city/", "/lookbehind-/a-city/", "/lookahead+/a-city/", "/lookbehind+/a-city/")
        @test resolve(u, DUR_URLS).kwargs == Dict(:city => "a-city")
    end
    for u in ("/lookahead-/not-a-city/", "/lookbehind-/not-a-city/", "/lookahead+/other-city/", "/lookbehind+/other-city/")
        m = resolve(u, DUR_URLS)
        @test m === nothing || !startswith(something(m.url_name, ""), "look")
    end
    for (n, exp) in (("lookahead-positive", "/lookahead+/a-city/"), ("lookahead-negative", "/lookahead-/a-city/"),
                     ("lookbehind-positive", "/lookbehind+/a-city/"), ("lookbehind-negative", "/lookbehind-/a-city/"))
        @test dur_rev(n; city = "a-city") == exp
    end
    for (n, city) in (("lookahead-positive", "other-city"), ("lookahead-negative", "not-a-city"),
                      ("lookbehind-positive", "other-city"), ("lookbehind-negative", "not-a-city"))
        @test_throws NRM dur_rev(n; city)
    end
    # ReverseResolvedTests.test_rereverse (the pattern's extra kwargs come back in the match, and reverse takes them)
    m = resolve("/resolved/12/", DUR_URLS)
    @test dur_rev(m.url_name, m.args...; m.kwargs...) == "/resolved/12/"
end

# urlconf_outer and urlconf_inner, and the middleware that switches a request to the inner one
dur_inner_view(req) = HttpResponse(render(Template("{% url \"outer\" as outer_url %}outer:{{ outer_url }},{% url \"inner\" as inner_url %}inner:{{ inner_url }}"),
                                          Dict{String,Any}()))
const DUR_INNER = Any[path("second_test/", dur_inner_view; name = "inner")]
const DUR_OUTER = Any[path("test/me/", dur_inner_view; name = "outer"), path("inner_urlconf/", include_urls(DUR_INNER))]
dur_change_urlconf(h) = req -> (req.urlconf = DUR_INNER; h(req))
dur_null_urlconf(h) = req -> (req.urlconf = nothing; h(req))
dur_reverse_inner(h) = req -> (h(req); HttpResponse(reverse_url("inner")))
dur_reverse_outer(h) = req -> (h(req); HttpResponse(reverse_url("outer")))

@testset "django urlpatterns_reverse: RequestURLconfTests" begin
    body(r) = String(r.body)
    override_settings(ROOT_URLCONF = DUR_OUTER) do
        c = Client()
        r = get(c, "/test/me/")                                                                     # test_urlconf
        @test r.status == 200 && body(r) == "outer:/test/me/,inner:/inner_urlconf/second_test/"
        @test get(c, "/inner_urlconf/second_test/").status == 200 && get(c, "/second_test/").status == 404
        override_settings(MIDDLEWARE = [dur_change_urlconf]) do                                      # test_urlconf_overridden
            @test get(c, "/test/me/").status == 404 && get(c, "/inner_urlconf/second_test/").status == 404
            r = get(c, "/second_test/")
            @test r.status == 200 && body(r) == "outer:,inner:/second_test/"
        end
        override_settings(MIDDLEWARE = [dur_null_urlconf]) do                                        # test_urlconf_overridden_with_null
            r = get(c, "/test/me/")
            @test r.status == 200 && body(r) == "outer:/test/me/,inner:/inner_urlconf/second_test/"
            @test get(c, "/second_test/").status == 404
        end
        override_settings(MIDDLEWARE = [dur_change_urlconf, dur_reverse_inner]) do                   # test_reverse_inner_in_response_middleware
            r = get(c, "/second_test/")
            @test r.status == 200 && body(r) == "/second_test/"
        end
        override_settings(MIDDLEWARE = [dur_change_urlconf, dur_reverse_outer]) do                   # test_reverse_outer_in_response_middleware
            @test occursin("Reverse for 'outer' not found. 'outer' is not a valid view function or pattern name.",
                           dur_msg(() -> get(Client(; raise_request_exception = true), "/second_test/")))
        end
        # test_urlconf_is_reset_after_request
        @test Juango.get_urlconf() === nothing
        override_settings(MIDDLEWARE = [dur_change_urlconf]) do
            get(c, reverse_url("inner"; urlconf = DUR_INNER))
        end
        @test Juango.get_urlconf() === nothing
    end
    # (the streaming forms: a streamed body is read after the request is handled, outside its URLconf)
end

const DUR_LAZY_URLS = Any[path("redirected_to/", dur_empty; name = "named-lazy-url-redirected-to"),
                          path("login/", dur_empty; name = "some-login-page"),
                          path("login_required_view/", login_required(dur_empty; login_url = reverse_lazy("some-login-page"))),
                          path("redirect/", RedirectView(reverse_lazy("named-lazy-url-redirected-to")))]

@testset "django urlpatterns_reverse: ReverseLazyTest, ReverseShortcutTests" begin
  port_block() do
    override_settings(ROOT_URLCONF = DUR_LAZY_URLS) do
        c = Client()
        r = get(c, "/redirect/")                                                                    # test_redirect_with_lazy_reverse
        @test r.status == 302 && getheader(r, "Location") == "/redirected_to/"
        alfred = create_user("dur_alfred", "testpw")                                                 # test_user_permission_with_lazy_reverse
        r = get(c, "/login_required_view/")
        @test r.status == 302 && getheader(r, "Location") == "/login/?next=/login_required_view/"
        force_login!(c, alfred)
        @test get(c, "/login_required_view/").status == 200
        @test "Some URL: $(reverse_lazy("some-login-page"))" == "Some URL: /login/"                  # test_inserting_reverse_lazy_into_string
        @test build_absolute_uri(Juango.Request("GET", "/"; headers = Dict("Host" => "testserver")), reverse_lazy("some-login-page")) ==
              "http://testserver/login/"                                                             # test_build_absolute_uri
    end
  end
    override_settings(ROOT_URLCONF = DUR_URLS) do
        # test_redirect_to_view_name, test_redirect_to_url
        loc(r) = getheader(r, "Location")
        @test loc(redirect("hardcoded2")) == "/hardcoded/doc.pdf" && loc(redirect("places", 1)) == "/places/1/"
        @test loc(redirect("headlines"; year = "2008", month = "02", day = "17")) == "/headlines/2008.02.17/"
        @test_throws NRM redirect("not-a-view")
        @test loc(redirect("/foo/")) == "/foo/" && loc(redirect("http://example.com/")) == "http://example.com/"
        @test loc(redirect("/æøå/abc/")) == "/%C3%A6%C3%B8%C3%A5/abc/" && loc(redirect("/æøå.abc/")) == "/%C3%A6%C3%B8%C3%A5.abc/"
        @test loc(redirect("os.path")) == "os.path"
        @test redirect("/foo/"; permanent = true).status == 301
        # test_reverse_by_path_nested, test_redirect_view_object: by the view, included or not
        @test reverse_url(dur_nested) == "/includes/nested_path/"
        @test loc(redirect(dur_absolute)) == "/absolute_arg_view/"
        @test_throws NRM redirect(dur_absolute; wrong_argument = nothing)
    end
end

dur_bad_view(req) = throw(ArgumentError("I don't think I'm getting good value for this view"))
const DUR_WITHOUT_HANDLERS = Any[path("test/", dur_empty), path("bad_view/", dur_bad_view)]

@testset "django urlpatterns_reverse: ErroneousViewTests, DefaultErrorHandlerTests" begin
    # test_noncallable_view: refused when the pattern is made
    @test_throws "view must be a callable or a list/tuple in the case of include()" path("uncallable-object/", 1)
    @test_throws "view must be a callable or a list/tuple in the case of include()" re_path("^uncallable/\$", (a = 1,))
    # test_invalid_regex: Juango finds it when the pattern is made, not on reverse (Django's message, as ImproperlyConfigured)
    @test_throws Juango.ImproperlyConfigured re_path("^(regex_error/\$", dur_empty)
    @test occursin("(regex_error/\$\" is not a valid regular expression", dur_msg(() -> re_path("^(regex_error/\$", dur_empty)))
    @test_throws Juango.ImproperlyConfigured re_path("^(bad/", include_urls(DUR_INCLUDED))
    # test_default_handler: no HANDLER404 & co., the defaults are used; a test client raises the view's error
    override_settings(ROOT_URLCONF = DUR_WITHOUT_HANDLERS) do
        @test get(Client(), "/test/x/").status == 404
        @test_throws "I don't think I'm getting good value for this view" get(Client(raise_request_exception = true), "/bad_view/")
    end
    # (ErrorHandlerResolutionTests: Juango's handlers are the HANDLER400/403/404/500 settings, tested in views.jl;
    # NoRootUrlConfTests, ViewLoadingTests and the include() tuple forms are about Python's dotted-path imports and tuples)
end
