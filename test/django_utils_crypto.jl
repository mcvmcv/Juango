# Django's utils_tests test_crypto.py and test_ipv6.py, ported (#227): constant_time_compare, salted_hmac, pbkdf2 (RFC
# vectors), is_valid_ipv6_address and clean_ipv6_address.
# julia --project=test test/django_utils_crypto.jl   (see setup.jl; no database needed)
#
# Not translated: blake2b (SHA.jl hasn't it: an InvalidAlgorithm, tested) and the salted_hmac default-algorithm
# deprecation warning (Juango's default is sha1, Django's for now); Python IPv6Address instances; the traceback of the
# too-long address's ValueError.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django utils_tests test_crypto: TestUtilsCryptoMisc, TestUtilsCryptoPBKDF2" begin
    b(s) = Vector{UInt8}(s)
    # test_constant_time_compare
    @test Juango.constant_time_compare(b("spam"), b("spam")) && !Juango.constant_time_compare(b("spam"), b("eggs"))
    @test Juango.constant_time_compare("spam", "spam") && !Juango.constant_time_compare("spam", "eggs")
    @test Juango.constant_time_compare(b("spam"), "spam") && !Juango.constant_time_compare("spam", b("eggs"))
    @test Juango.constant_time_compare("ありがとう", "ありがとう") && !Juango.constant_time_compare("ありがとう", "おはよう")
    # test_salted_hmac
    for (args, kw, digest) in (((b("salt"), b("value")), (; algorithm = "sha1"), "b51a2e619c43b1ca4f91d15c57455521d71d61eb"),
                               (("salt", "value"), (; algorithm = "sha1"), "b51a2e619c43b1ca4f91d15c57455521d71d61eb"),
                               (("salt", "value"), (; secret = "abcdefg", algorithm = "sha1"), "8bbee04ccddfa24772d1423a0ba43bd0c0e24b76"),
                               (("salt", "value"), (; secret = "x"^64, algorithm = "sha1"), "bd3749347b412b1b0a9ea65220e55767ac8e96b0"),
                               (("salt", "value"), (; algorithm = "sha256"), "ee0bf789e4e009371a5372c90f73fcf17695a8439c9108b0480f14e347b3f9ec"))
        # (Django's test settings' SECRET_KEY, where the case gives none)
        @test bytes2hex(Juango.salted_hmac(args...; merge((; secret = "django_tests_secret_key"), kw)...)) == digest
    end
    # test_invalid_algorithm
    @test_throws "'whatever' is not an algorithm accepted by the hashlib module." Juango.salted_hmac("salt", "value"; algorithm = "whatever")
    @test_throws Juango.InvalidAlgorithm Juango.salted_hmac("salt", "value"; algorithm = "blake2b")
    # test_public_vectors / test_regression_vectors
    for (pw, salt, it, dklen, digest, result) in (("password", "salt", 1, 20, "sha1", "0c60c80f961f0e71f3a9b524af6012062fe037a6"),
                                                  ("password", "salt", 2, 20, "sha1", "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957"),
                                                  ("password", "salt", 4096, 20, "sha1", "4b007901b765489abead49d926f721d065a429c1"),
                                                  ("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 25, "sha1",
                                                   "3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038"),
                                                  ("pass\0word", "sa\0lt", 4096, 16, "sha1", "56fa6aa75548099dcc37d7f03425e0c3"),
                                                  ("password", "salt", 1, 20, "sha256", "120fb6cffcf8b32c43e7225256c4f837a86548c9"),
                                                  ("password", "salt", 1, 20, "sha512", "867f70cf1ade02cff3752599a3a53dc4af34c7a6"),
                                                  ("password", "salt", 1000, 0, "sha512",
                                                   "afe6c5530785b6cc6b1c6453384731bd5ee432ee549fd42fb6695779ad8a1c5bf59de69c48f774efc4007d5298f9033c0241d5ab69305e7b64eceeb8d834cfec"),
                                                  (UInt8[0xba], "salt", 1, 20, "sha1", "0053d3b91a7f1e54effebd6d68771e8a6e0b2c5b"))
        @test bytes2hex(Juango.pbkdf2(pw, salt, it; dklen, digest)) == result
    end
    # test_default_hmac_alg: sha256 by default
    @test Juango.pbkdf2(b("password"), b("salt"), 1; dklen = 20) == Juango.pbkdf2(b("password"), b("salt"), 1; dklen = 20, digest = "sha256")
end

@testset "django utils_tests test_ipv6: TestUtilsIPv6" begin
    valid(s) = Juango.is_valid_ipv6_address(s)
    for s in ("fe80::223:6cff:fe8a:2e8a", "2a02::223:6cff:fe8a:2e8a", "1::2:3:4:5:6:7", "::", "::a", "2::", "::ffff:254.42.16.14",
              "::ffff:0a0a:0a0a", "::254.42.16.14", "::0a0a:0a0a")
        @test valid(s)
    end
    for s in ("foo", "127.0.0.1", "12345::", "1::2:3::4", "1::zzz", "1::2:3:4:5:6:7:8", "1:2", "1:::2", "fe80::223: 6cff:fe8a:2e8a",
              "2a02::223:6cff :fe8a:2e8a", "::ffff:999.42.16.14", "::ffff:zzzz:0a0a", "::999.42.16.14", "::zzzz:0a0a")
        @test !valid(s)
    end
    for case in (nothing, [], Dict(), (), 2.46, 192.168, 42)
        @test valid(case) === false
    end
    # test_cleans_plain_address / test_cleans_with_v4_mapping / test_unpacks_ipv4
    @test Juango.clean_ipv6_address("DEAD::0:BEEF") == "dead::beef"
    @test Juango.clean_ipv6_address("2001:000:a:0000:0:fe:fe:beef") == "2001:0:a::fe:fe:beef"
    @test Juango.clean_ipv6_address("2001::a:0000:0:fe:fe:beef") == "2001:0:a::fe:fe:beef"
    for (s, out) in (("::ffff:0a0a:0a0a", "::ffff:10.10.10.10"), ("::ffff:1234:1234", "::ffff:18.52.18.52"), ("::ffff:18.52.18.52", "::ffff:18.52.18.52"),
                     ("::ffff:0.52.18.52", "::ffff:0.52.18.52"), ("::ffff:0.0.0.0", "::ffff:0.0.0.0"))
        @test Juango.clean_ipv6_address(s) == out
    end
    for (s, out) in (("::ffff:0a0a:0a0a", "10.10.10.10"), ("::ffff:1234:1234", "18.52.18.52"), ("::ffff:18.52.18.52", "18.52.18.52"))
        @test Juango.clean_ipv6_address(s; unpack_ipv4 = true) == out
    end
    # test_address_too_long
    for addr in ("0000:0000:0000:0000:0000:ffff:192.168.100.228", "0000:0000:0000:0000:0000:ffff:192.168.100.228%123456",
                 "fe80::223:6cff:fe8a:2e8a:1234:5678:00000")
        @test length(addr) > Juango.MAX_IPV6_ADDRESS_LENGTH && !valid(addr)
        @test_throws "This is the error message." Juango.clean_ipv6_address(addr; error_message = "This is the error message.")
    end
end
