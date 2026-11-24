# Django's signed_cookies_tests, ported (#227).
# julia --project=test test/django_signed_cookies.jl   (see setup.jl)
#
# Juango's cookie value is the base64 of the value (Django's is the value itself: "hello:..."), so it needs no
# quoting in the header; freeze_time is a cookie signed with an older timestamp here.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dsc_value(resp, name) = only(split(split(c, ';')[1], '='; limit = 2)[2] for c in resp.cookies if startswith(c, "$name="))
dsc_req(pairs...) = Request("GET", "/"; headers = Dict("Cookie" => join(["$k=$v" for (k, v) in pairs], "; ")))
# a cookie as set_signed_cookie! makes it `age` seconds ago (or with another salt string)
dsc_signed(value, saltstr; age = 0) =
    Juango.sign_value(Juango.b64url(Vector{UInt8}(codeunits(value))) * ":" * string(round(Int, time()) - age; base = 36); salt = saltstr)

@testset "django signed_cookies_tests" begin
    # test_can_set_and_read_signed_cookies
    resp = set_signed_cookie!(HttpResponse(), "c", "hello")
    @test any(startswith("c="), resp.cookies)
    @test get_signed_cookie(dsc_req("c" => dsc_value(resp, "c")), "c") == "hello"
    # test_can_use_salt
    resp = set_signed_cookie!(HttpResponse(), "a", "hello"; salt = "one")
    req = dsc_req("a" => dsc_value(resp, "a"))
    @test get_signed_cookie(req, "a"; salt = "one") == "hello"
    @test_throws Juango.BadSignature get_signed_cookie(req, "a"; salt = "two")
    # test_salt_namespace_is_unambiguous
    resp = set_signed_cookie!(HttpResponse(), "a", "hello"; salt = "bc")
    @test_throws Juango.BadSignature get_signed_cookie(dsc_req("ab" => dsc_value(resp, "a")), "ab"; salt = "c")
    # test_expired_legacy_cookie_raises_signature_expired
    override_settings(SIGNED_COOKIE_LEGACY_SALT_FALLBACK = true) do
        req = dsc_req("a" => dsc_signed("hello", Juango.signed_cookie_legacy_salt("a", "bc"); age = 11))
        @test_throws Juango.SignatureExpired get_signed_cookie(req, "a"; salt = "bc", max_age = 10)
        # test_legacy_salt_namespace_is_accepted: no protection with the fallback
        req = dsc_req("ab" => dsc_signed("hello", Juango.signed_cookie_legacy_salt("a", "bc")))
        @test get_signed_cookie(req, "ab"; salt = "c") == "hello"
        # test_expired_new_style_cookie_does_not_fallback_to_legacy_salt
        req = dsc_req("a" => dsc_signed("hello", Juango.signed_cookie_salt("a", "bc"); age = 11))
        @test_throws Juango.SignatureExpired get_signed_cookie(req, "a"; salt = "bc", max_age = 10)
    end
    # test_legacy_salt_namespace_not_accepted: SIGNED_COOKIE_LEGACY_SALT_FALLBACK is false by default in Django;
    # Juango's default is true for now, so cookies already set stay valid
    req = dsc_req("a" => dsc_signed("hello", Juango.signed_cookie_legacy_salt("a", "bc")))
    @test_broken (try get_signed_cookie(req, "a"; salt = "bc"); false catch e; e isa Juango.BadSignature end)
    override_settings(SIGNED_COOKIE_LEGACY_SALT_FALLBACK = false) do
        @test_throws Juango.BadSignature get_signed_cookie(req, "a"; salt = "bc")
    end
    # test_detects_tampering / test_default_argument_suppresses_exceptions
    resp = set_signed_cookie!(HttpResponse(), "c", "hello")
    req = dsc_req("c" => dsc_value(resp, "c")[1:end-2] * "\$\$")
    @test_throws Juango.BadSignature get_signed_cookie(req, "c")
    @test get_signed_cookie(req, "c"; default = nothing) === nothing
    # test_max_age_argument (signed 11 seconds ago)
    req = dsc_req("c" => dsc_signed("hello", Juango.signed_cookie_salt("c", ""); age = 11))
    @test get_signed_cookie(req, "c") == "hello"
    @test get_signed_cookie(req, "c"; max_age = 12) == "hello"
    @test get_signed_cookie(req, "c"; max_age = Second(12)) == "hello"
    @test_throws Juango.SignatureExpired get_signed_cookie(req, "c"; max_age = 10)
    @test_throws Juango.SignatureExpired get_signed_cookie(req, "c"; max_age = Second(10))
    # test_set_signed_cookie_max_age_argument
    resp = set_signed_cookie!(HttpResponse(), "c", "value"; max_age = 100)
    set_signed_cookie!(resp, "d", "value"; max_age = Hour(2))
    @test occursin("Max-Age=100", only(filter(startswith("c="), resp.cookies)))
    @test occursin("Max-Age=7200", only(filter(startswith("d="), resp.cookies)))
    # test_signed_cookies_with_binary_key
    for key in ("\xe7", UInt8[0xe7])
        override_settings(SECRET_KEY = key) do
            resp = set_signed_cookie!(HttpResponse(), "c", "hello")
            @test get_signed_cookie(dsc_req("c" => dsc_value(resp, "c")), "c") == "hello"
        end
    end
end
