# Django's signing tests, ported (#227): tests/signing (TestSigner, TestTimestampSigner, TestBase62).
# julia --project=test test/django_signing.jl   (see setup.jl)
#
# Juango's signatures aren't Django's byte for byte (the HMAC key is salt * "signer" * key, not
# Django's salted_hmac derivation), so the tests that compare with a precomputed signature compare
# with Juango's own construction instead. signing_dumps keeps a base 36 timestamp, so cookies and
# sessions signed before still load. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django signing: TestSigner" begin
    signer = Signer(; key = "predictable-secret")
    s2 = Signer(; key = "predictable-secret2")                                           # test_signature
    for s in ("hello", "3098247:529:087:", "’")
        @test Juango.signature(signer, s) == Juango.b64url(Juango.SHA.hmac_sha256(Vector{UInt8}(codeunits("juango.signing.Signersigner" * "predictable-secret")), Vector{UInt8}(codeunits(s))))
        @test Juango.signature(signer, s) != Juango.signature(s2, s)
    end
    @test Juango.signature(Signer(; key = "predictable-secret", salt = "extra-salt"), "hello") != Juango.signature(signer, "hello")   # test_signature_with_salt
    @test Juango.signature(Signer(; key = "predictable-secret", salt = "one"), "hello") != Juango.signature(Signer(; key = "predictable-secret", salt = "two"), "hello")
    for (alg, h) in (("sha1", Juango.SHA.hmac_sha1), ("sha512", Juango.SHA.hmac_sha512))              # test_custom_algorithm
        s = Signer(; key = "predictable-secret", algorithm = alg)
        @test Juango.signature(s, "hello") == Juango.b64url(h(Vector{UInt8}(codeunits("juango.signing.Signersignerpredictable-secret")), Vector{UInt8}(codeunits("hello"))))
    end
    e = try sign(Signer(; key = "predictable-secret", algorithm = "whatever"), "hello") catch e; e end   # test_invalid_algorithm
    @test e isa InvalidAlgorithm && e.msg == "\"whatever\" is not an algorithm accepted by the hashlib module."
    for example in ("q;wjmbk;wkmb", "3098247529087", "3098247:529:087:", "jkw osanteuh ,rcuh nthu aou oauh ,ud du", "’")   # test_sign_unsign
        signed = sign(signer, example)
        @test signed != example && unsign(signer, signed) == example
    end
    for example in (123, 1.23, true, "abc")                                               # test_sign_unsign_non_string
        signed = sign(signer, example)
        @test unsign(signer, signed) == string(example)
    end
    value = "Another string"                                                              # test_unsign_detects_tampering
    signed = sign(signer, value)
    for t in (signed * "a", "a" * signed[2:end], replace(signed, ":" => ""))
        @test_throws BadSignature unsign(signer, t)
    end
    e = try unsign(signer, "no separator here") catch e; e end
    @test e isa BadSignature && e.msg == "No \":\" found in value"
    for o in ("a", "’", 3.14, Dict("a" => 1, "b" => [1, 2]), Any["a", "b"], Dict("é" => "ü"))   # test_sign_unsign_object
        so = sign_object(signer, o)
        @test unsign_object(signer, so) == o
        @test unsign_object(signer, sign_object(signer, o; compress = true)) == o
    end
    big = Dict("a" => repeat("abcdef", 100))                                             # (compressed: shorter, marked by ".")
    so = sign_object(signer, big; compress = true)
    @test startswith(so, ".") && length(so) < length(sign_object(signer, big)) && unsign_object(signer, so) == big
    @test !startswith(sign_object(signer, "x"; compress = true), ".")                   # (compression that doesn't help isn't used)
    for t in (so * "a", "a" * so[2:end])                                                  # test_unsign_object_detects_tampering (sort of)
        @test_throws BadSignature unsign_object(signer, t)
    end

    objects = Any[Any["a", "list"], "a string ’", Dict("a" => "dictionary")]          # test_dumps_loads
    for o in objects
        @test signing_loads(signing_dumps(o)) == o
        @test signing_loads(signing_dumps(o; compress = true)) == o
        @test signing_loads(signing_dumps(o; key = "other-key"); key = "other-key") == o
        @test_throws BadSignature signing_loads(signing_dumps(o; key = "other-key"))
    end
    @test startswith(signing_dumps(Dict("a" => repeat("x", 300)); compress = true), ".")
    value = Dict("foo" => "bar", "baz" => 1)                                              # test_decode_detects_tampering
    enc = signing_dumps(value)
    for t in (uppercase(enc), enc * "a", "a" * enc[2:end], replace(enc, ":" => ""))
        @test_throws BadSignature signing_loads(t)
    end
    binary_key = UInt8[0xe7]                                                              # test_works_with_non_ascii_keys
    s = Signer(; key = binary_key)
    @test unsign(s, sign(s, "foo")) == "foo" && sign(s, "foo") != sign(Signer(; key = "ç"), "foo")
    for sep in ("~", "!", "%", "’", "::", ";")                                       # test_valid_sep
        s = Signer(; key = "predictable-secret", sep = sep)
        @test sign(s, "foo") == "foo" * sep * Juango.signature(s, "foo") && unsign(s, sign(s, "foo")) == "foo"
    end
    for sep in ("", "-", "abc", "A", "z", "9", "=", "_", "[")                            # test_invalid_sep
        e = try Signer(; sep = sep) catch e; e end
        @test e isa ArgumentError && e.msg == "Unsafe Signer separator: $(repr(sep)) (cannot be empty or consist of only A-z0-9-_=)"
    end
    old = Signer(; key = "secret")                                                        # test_verify_with_non_default_key
    signed = sign(old, "abc")
    @test unsign(Signer(; key = "secret"), signed) == "abc"
    @test_throws BadSignature unsign(Signer(; key = "newsecret"), signed)
    @test unsign(Signer(; key = "newsecret", fallback_keys = ["othersecret", "secret"]), signed) == "abc"   # test_sign_unsign_multiple_keys
    @test signing_loads(signing_dumps("abc"; key = "secret"); key = "newsecret", fallback_keys = ["secret"]) == "abc"
    override_settings(SECRET_KEY = "newsecret", SECRET_KEY_FALLBACKS = ["oldsecret"]) do     # test_verify_with_fallback_keys (settings)
        @test unsign(Signer(), sign(Signer(; key = "oldsecret"), "abc")) == "abc"
        @test sign(Signer(), "abc") == sign(Signer(; key = "newsecret"), "abc")         # test_sign_with_fallback (signs with the key)
        @test_throws BadSignature unsign(Signer(), sign(Signer(; key = "unknown"), "abc"))
    end
    # sign_value / unsign_value are a Signer with the given salt
    @test sign_value("hello"; salt = "s") == sign(Signer(; salt = "s"), "hello") && unsign_value(sign(Signer(; salt = "s"), "hello"); salt = "s") == "hello"
    # not translated: the legacy (sha1) signatures Django still reads, Signer's positional-argument deprecation,
    # custom serializers for dumps/loads
end

@testset "django signing: TestTimestampSigner" begin
    value = "hello"                                                                       # test_timestamp_signer
    old_clock = Juango.SIGNING_CLOCK[]
    try
        Juango.SIGNING_CLOCK[] = () -> 123456789.0
        signer = TimestampSigner(; key = "predictable-key")
        ts = sign(signer, value)
        @test ts != sign(Signer(; key = "predictable-key"), value)
        @test ts == "hello:" * b62_encode(123456789) * ":" * Juango.signature(signer.signer, "hello:" * b62_encode(123456789))
        @test unsign(signer, ts) == value
        Juango.SIGNING_CLOCK[] = () -> 123456800.0
        @test unsign(signer, ts; max_age = 12) == value
        @test unsign(signer, ts; max_age = Second(12)) == value                         # (max_age may be a timedelta)
        @test_throws SignatureExpired unsign(signer, ts; max_age = 10)
        @test_throws SignatureExpired unsign(signer, ts; max_age = Second(10))
        e = try unsign(signer, ts; max_age = 10) catch e; e end
        @test e.msg == "Signature age 11.0 > 10.0 seconds"
        so = sign_object(signer, Dict("a" => 1))                                         # (sign_object with a TimestampSigner)
        @test unsign_object(signer, so; max_age = 5) == Dict("a" => 1)
        Juango.SIGNING_CLOCK[] = () -> 123456900.0
        @test_throws SignatureExpired unsign_object(signer, so; max_age = 5)
        @test_throws BadSignature unsign(signer, sign(Signer(; key = "predictable-key", salt = "juango.signing.TimestampSigner"), "no-timestamp"))
        Juango.SIGNING_CLOCK[] = () -> 1000.0                                            # (signing_dumps' max_age, a Period too)
        d = signing_dumps("x")
        Juango.SIGNING_CLOCK[] = () -> 1100.0
        @test signing_loads(d; max_age = Minute(2)) == "x"
        @test_throws SignatureExpired signing_loads(d; max_age = Minute(1))
    finally
        Juango.SIGNING_CLOCK[] = old_clock
    end
end

@testset "django signing: TestBase62" begin
    for i in [-10^6:7919:10^6; 0; 1; -1; 61; 62; typemax(Int32)]                        # test_base62
        @test b62_decode(b62_encode(i)) == i
    end
    @test b62_encode(0) == "0" && b62_encode(61) == "z" && b62_encode(62) == "10" && b62_encode(-62) == "-10"
end
