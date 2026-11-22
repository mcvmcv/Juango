# Django's validators tests, ported (#227): tests/validators (TestValidators' TEST_DATA, TestValidatorEquality).
# julia --project=test test/django_validators.jl   (see setup.jl)
#
# A Juango validator called on a value gives the error message, or nothing when it's valid (Django's
# raises ValidationError). Django's long valid_urls.txt / invalid_urls.txt lists aren't copied; the
# cases below are from TEST_DATA. Each group keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dvl_ok(v, x) = v(x) === nothing
dvl_bad(v, x) = v(x) !== nothing

@testset "django validators: TEST_DATA" begin
    for x in ("42", "-42", -42, 42), bad in (-42.5, nothing, "a", "\n42", "42\n", "", "-")                # validate_integer
        @test dvl_ok(validate_integer, x) && dvl_bad(validate_integer, bad)
    end
    for e in ("email@here.com", "weirder-email@here.and.there.com", "email@[127.0.0.1]", "email@[2001:dB8::1]",     # validate_email
              "email@[2001:dB8:0:0:0:0:0:1]", "email@[::fffF:127.0.0.1]", "example@valid-----hyphens.com",
              "example@valid-with-hyphens.com", "test@domain.with.idn.tld.उदाहरण.परीक्षा", "email@localhost",
              "\"test@test\"@example.com", "example@atm." * "a"^63, "example@" * "a"^63 * ".atm",
              "example@" * "a"^63 * "." * "b"^10 * ".atm", "\"\\\t\"@here.com")
        @test dvl_ok(validate_email, e)
    end
    @test dvl_ok(EmailValidator(; allowlist = ["localdomain"]), "email@localdomain")
    @test dvl_bad(EmailValidator(; allowlist = ["localdomain"]), "email@localhost")
    for e in (nothing, "", "abc", "abc@", "abc@bar", "a @x.cz", "abc@.com", "something@@somewhere.com", "email@127.0.0.1",
              "email@[127.0.0.256]", "email@[2001:db8::12345]", "email@[2001:db8:0:0:0:0:1]", "email@[::ffff:127.0.0.256]",
              "email@[2001:dg8::1]", "email@[2001:dG8:0:0:0:0:0:1]", "email@[::fTzF:127.0.0.1]", "example@invalid-.com",
              "example@-invalid.com", "example@invalid.com-", "example@inv-.alid-.com", "example@inv-.-alid.com",
              "test@example.com\n\n<script src=\"x.js\">", "\"\\\n\"@here.com", "trailingdot@shouldfail.com.", "a@b.com\n",
              "a\n@b.com", "\"test@test\"\n@example.com", "a@[127.0.0.1]\n", "example@atm." * "a"^64,
              "example@" * "b"^64 * ".atm." * "a"^63, "example@" * ("a"^63 * ".")^100 * "com", "a"^320 * "@example.com")
        @test dvl_bad(validate_email, e)
    end
    for s in ("slug-ok", "longer-slug-still-ok", "--------", "nohyphensoranything", "a", "1", "a1")          # validate_slug
        @test dvl_ok(validate_slug, s)
    end
    for s in ("", " text ", " ", "some@mail.com", "你好", "你 好", "\n", "trailing-newline\n")
        @test dvl_bad(validate_slug, s)
    end
    for s in ("slug-ok", "uni-é", "你好", "a1")                                                                 # validate_unicode_slug
        @test dvl_ok(validate_unicode_slug, s)
    end
    for s in ("", " text ", " ", "some@mail.com", "\n", "你 好", "trailing-newline\n")
        @test dvl_bad(validate_unicode_slug, s)
    end
    for ip in ("1.1.1.1", "255.0.0.0", "0.0.0.0")                                                                # validate_ipv4_address
        @test dvl_ok(validate_ipv4_address, ip) && dvl_ok(validate_ipv46_address, ip)
    end
    for ip in ("256.1.1.1", "25.1.1.", "25,1,1,1", "25.1 .1.1", "1.1.1.1\n", "٧.2٥.3٣.243", "000.000.000.000", "016.016.016.016")
        @test dvl_bad(validate_ipv4_address, ip)
    end
    for ip in ("fe80::1", "::1", "1:2:3:4:5:6:7:8")                                                               # validate_ipv6_address
        @test dvl_ok(validate_ipv6_address, ip) && dvl_ok(validate_ipv46_address, ip)
    end
    for ip in ("1:2", "::zzz", "12345::")
        @test dvl_bad(validate_ipv6_address, ip) && dvl_bad(validate_ipv46_address, ip)
    end
    for ip in ("256.1.1.1", "25.1.1.", "25,1,1,1", "25.1 .1.1")                                                  # validate_ipv46_address
        @test dvl_bad(validate_ipv46_address, ip)
    end
    for s in ("1", "12", "1,2", "1,2,3", "10,32")                                                                # validate_comma_separated_integer_list
        @test dvl_ok(validate_comma_separated_integer_list, s)
    end
    for s in ("", "a", "a,b,c", "1, 2, 3", ",", "1,2,3,", "1,2,", ",1", "1,,2")
        @test dvl_bad(validate_comma_separated_integer_list, s)
    end
    @test dvl_ok(int_list_validator(; sep = "."), "1.2.3") && dvl_bad(int_list_validator(; sep = "."), "1,2,3")   # int_list_validator
    @test dvl_ok(int_list_validator(; allow_negative = true), "-1,-2,3") && dvl_ok(int_list_validator(; allow_negative = true), "1,-2,-12")
    @test dvl_bad(int_list_validator(; allow_negative = true), "-1,2,") && dvl_bad(int_list_validator(), "-1,2,3")
    @test dvl_ok(int_list_validator(; sep = "|"), "1|2|3") && dvl_bad(int_list_validator(; sep = "|"), "1.2.3")

    @test dvl_ok(MaxValueValidator(10), 10) && dvl_ok(MaxValueValidator(10), -10) && dvl_ok(MaxValueValidator(10), 0)   # MaxValueValidator
    @test dvl_ok(MaxValueValidator(Date(2010, 1, 1)), Date(2009, 1, 1)) && dvl_bad(MaxValueValidator(Date(2010, 1, 1)), Date(2010, 1, 2))
    @test dvl_bad(MaxValueValidator(0), 1)
    @test dvl_ok(MinValueValidator(-10), -10) && dvl_ok(MinValueValidator(-10), 10) && dvl_ok(MinValueValidator(-10), 0)   # MinValueValidator
    @test dvl_bad(MinValueValidator(0), -1) && dvl_bad(MinValueValidator(Date(2010, 1, 1)), Date(2009, 12, 31))
    @test dvl_ok(MaxLengthValidator(10), "") && dvl_ok(MaxLengthValidator(10), "x"^10) && dvl_bad(MaxLengthValidator(10), "x"^15)   # MaxLengthValidator
    @test dvl_ok(MinLengthValidator(10), "x"^15) && dvl_ok(MinLengthValidator(10), "x"^10)                     # MinLengthValidator
    @test dvl_bad(MinLengthValidator(10), "") && dvl_bad(MinLengthValidator(10), "x"^5)
    @test MinLengthValidator(10)("x"^5) == "Ensure this value has at least 10 characters (it has 5)."
    @test MaxLengthValidator(1)("xx") == "Ensure this value has at most 1 character (it has 2)."
    for (v, oks, bads) in ((StepValueValidator(3), (0, 3, 6, -3), (1, 2, 5)),                                  # StepValueValidator
                           (StepValueValidator(1.5), (1.5, 3, -1.5), (1, 2.5)),
                           (StepValueValidator(0.001), (0.55, 0.001, 1.0), (0.5555,)),
                           (StepValueValidator(3; offset = 1), (1, 4, -2), (3, 0)),
                           (StepValueValidator(1.5; offset = 0.5), (0.5, 2, 3.5), (1.5, 1)))
        for x in oks
            @test dvl_ok(v, x)
        end
        for x in bads
            @test dvl_bad(v, x)
        end
    end
    @test StepValueValidator(3; offset = 1)(3) == "Ensure this value is a multiple of step size 3, starting from 1, e.g. 1, 4, 7, and so on."

    D = Juango.Decimal                                                                                            # DecimalValidator
    for (v, oks, bads) in ((DecimalValidator(2, 2), (D("0.99"),), (D("0.999"), D("1.00"))),
                           (DecimalValidator(3, 1), (D("99.9"), D("-99.9")), (D("999"), D("7304E-1"), D("7304E-3"))),
                           (DecimalValidator(5, 2), (D("123.45"), D("7304E-2")), (D("70E+3"), D("7304E-3"))),
                           (DecimalValidator(nothing, 2), (D("123456.78"),), (D("1.001"),)),
                           (DecimalValidator(3, nothing), (D("123"), D("1.23")), (D("1234"),)),
                           (DecimalValidator(5, 0), (D("1E+2"), D("12345")), (D("1.1"),)))
        for x in oks
            @test dvl_ok(v, x)
        end
        for x in bads
            @test dvl_bad(v, x)
        end
    end
    for x in ("NaN", "Inf", "-Inf", "abc")
        @test DecimalValidator(4, 2)(x) == "Enter a number."
    end

    v = RegexValidator()                                                                                           # RegexValidator
    @test dvl_ok(v, "") && dvl_ok(RegexValidator("^[0-9]+\$"), "1234") && dvl_bad(RegexValidator("^[0-9]+\$"), "xxxxxx")
    @test dvl_ok(RegexValidator(r"^[0-9]+$"), "1234") && dvl_bad(RegexValidator(r"^[0-9]+$"), "xxxxxx")
    @test dvl_ok(RegexValidator(".*"), "") && dvl_bad(RegexValidator("x"; inverse_match = true), "x")
    @test dvl_ok(RegexValidator("x"; inverse_match = true), "y") && dvl_ok(RegexValidator("x"; inverse_match = true), ".")
    @test dvl_ok(RegexValidator("[a-z]+"; flags = "i"), "A") && dvl_bad(RegexValidator("[a-z]+"), "A")
    @test dvl_bad(RegexValidator("^[0-9]+\$"; message = "digits"), "a") && RegexValidator("^[0-9]+\$"; message = "digits")("a") == "digits"
    @test dvl_ok(ProhibitNullCharactersValidator(), "something") && dvl_bad(ProhibitNullCharactersValidator(), "\0something")   # ProhibitNullCharactersValidator
    @test ProhibitNullCharactersValidator()("\0") == "Null characters are not allowed."

    u = URLValidator()                                                                                             # URLValidator
    for x in ("http://www.djangoproject.com/", "HTTP://WWW.DJANGOPROJECT.COM/", "http://localhost/", "http://example.com/",
              "http://example.com./", "http://www.example.com:8000/test", "http://valid-with-hyphens.com/", "http://subdomain.example.com/",
              "http://200.8.9.10/", "http://200.8.9.10:8000/test", "http://su--b.valid-----hyphens.com/", "http://example.com?something=value",
              "http://example.com/index.php?something=value&another=value2", "https://example.com/", "ftp://example.com/",
              "ftps://example.com/", "http://foo.com/blah_blah", "http://userid:password@example.com:8080",
              "http://userid@example.com", "http://142.42.1.1/", "http://142.42.1.1:8080/", "http://[::1]:8080/",
              "http://[2001:db8::1]/", "http://उदाहरण.परीक्षा", "http://foo.com/unicode_(✪)_in_parens", "http://0.0.0.0",
              "http://xn--7sbb4ac0ad0be6cf.xn--p1ai", "http://a.b-c.de", "http://223.255.255.254")
        @test dvl_ok(u, x)
    end
    for x in ("no_scheme", "foo", "http://", "http://example", "http://example.", "http://.com", "http://invalid-.com",
              "http://-invalid.com", "http://invalid.com-", "http://invalid.-com", "http://inv-.alid-.com", "http://inv-.-alid.com",
              "file://localhost/path", "git://example.com/", "http://.", "http://..", "http://../", "http://?", "http://??/", "http://#",
              "http://foo.bar?q=Spaces should be encoded", "//", "//a", "///a", "///", "http:///a", "foo.com", "rdar://1234",
              "h://test", "http:// shouldfail.com", ":// should fail", "http://foo.bar/foo(bar)baz quux", "http://-error-.invalid/",
              "http://01.1.1.1", "http://1.1.1.1.1", "http://123.123.123", "http://3628126748", "http://.www.foo.bar/",
              "http://.www.foo.bar./", "http://[::1:2::3]:8080/", "http://[]", "http://[]:8080",
              "http://example..com/", "http://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.example.com",
              "http://example.com\n", "http://[::ffff:192.9.5.5]\n", "http://www.djangoproject.com/\n", "http://example.com\r",
              "http://" * "x"^2050 * ".com")
        @test dvl_bad(u, x)
    end
    @test dvl_ok(URLValidator(; schemes = ["git", "git+ssh"]), "git://example.com/")                           # (EXTENDED_SCHEMES)
    @test dvl_ok(URLValidator(; schemes = ["git", "git+ssh"]), "git+ssh://git@github.com/example/hg-git.git")
    @test dvl_bad(URLValidator(; schemes = ["git"]), "http://example.com/")
end

@testset "django validators: TestValidatorEquality" begin
    @test RegexValidator(r"^(?:[a-z0-9.-]*)://") == RegexValidator(r"^(?:[a-z0-9.-]*)://")                   # test_regex_equality
    @test RegexValidator(r"^(?:[a-z0-9.-]*)://") != RegexValidator(r"^(?:[0-9.-]*)://")
    @test RegexValidator(r"^(?:[a-z0-9.-]*)://"; message = "NOT A URL", code = "invalid") ==
          RegexValidator(r"^(?:[a-z0-9.-]*)://"; message = "NOT A URL", code = "invalid")
    @test RegexValidator(r"^(?:[a-z0-9.-]*)://"; message = "NOT A URL", code = "invalid") !=
          RegexValidator(r"^(?:[a-z0-9.-]*)://"; message = "NOT A URL", code = "invalid-url")
    @test RegexValidator("^(?:[a-z0-9.-]*)://"; message = "NOT A URL") != RegexValidator("^(?:[a-z0-9.-]*)://"; message = "NOT A URLX")
    @test RegexValidator("a"; flags = "i") == RegexValidator("a"; flags = "i") && RegexValidator("a"; flags = "i") != RegexValidator("a")
    @test RegexValidator("x"; inverse_match = true) != RegexValidator("x")
    @test RegexValidator("") == RegexValidator("")                                                             # test_regex_equality_blank
    @test EmailValidator() == EmailValidator() && EmailValidator(; allowlist = ["a"]) != EmailValidator(; allowlist = ["b"])   # test_email_equality
    @test EmailValidator(; message = "BAD EMAIL") != EmailValidator() && EmailValidator(; code = "bad") != EmailValidator()
    @test MaxValueValidator(44) == MaxValueValidator(44) && MaxValueValidator(44) != MaxValueValidator(45)   # test_basic_equality
    @test MaxValueValidator(44) != MinValueValidator(44) && MinValueValidator(45) != MinValueValidator(11)
    @test MaxValueValidator(44; message = "custom") != MaxValueValidator(44) && MaxValueValidator(44; code = "x") != MaxValueValidator(44)
    @test DecimalValidator(1, 2) == DecimalValidator(1, 2) && DecimalValidator(1, 2) != DecimalValidator(1, 1)   # test_decimal_equality
    @test DecimalValidator(1, 2) != DecimalValidator(2, 2) && DecimalValidator(1, 2) != MinValueValidator(11)
    @test ProhibitNullCharactersValidator() == ProhibitNullCharactersValidator()                               # test_prohibit_null_characters_validator_equality
    @test ProhibitNullCharactersValidator(; message = "message") != ProhibitNullCharactersValidator(; message = "other")
    @test ProhibitNullCharactersValidator(; code = "code") != ProhibitNullCharactersValidator(; code = "other")
    @test StepValueValidator(2) == StepValueValidator(2) && StepValueValidator(2) != StepValueValidator(3)   # (Django 5's step validator)
    @test URLValidator() == URLValidator() && URLValidator(; schemes = ["http"]) != URLValidator()
    @test length(unique([MaxValueValidator(44), MaxValueValidator(44), MaxValueValidator(45)])) == 2          # (hash agrees with ==)
    # not translated: FileExtensionValidator (forms.jl, files), the DomainNameValidator class on its own,
    # validators raising ValidationError with params (Juango's give the message; see field error_messages)
end
