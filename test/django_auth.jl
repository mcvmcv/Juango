# Django's auth tests, ported (#227): tests/auth_tests.
# julia --project=test test/django_auth.jl   (see setup.jl)
#
# Juango's validate_password returns the messages (Django raises a ValidationError with them);
# its hashers are values (PBKDF2Hasher(), ...) in PASSWORD_HASHERS. Each test keeps its Django name
# in a comment; tests of Python internals are listed at the end of each testset.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

struct DjaRecordingValidator end
const DJA_SEEN = Ref{Any}(nothing)
Juango.password_changed!(::DjaRecordingValidator, p, u) = (DJA_SEEN[] = (p, u))
struct DjaAmpersandValidator end
Juango.password_help_text(::DjaAmpersandValidator) = "Must contain &"

@testset "django auth: test_validators" begin
    old = get(Juango.settings, :AUTH_PASSWORD_VALIDATORS, nothing)
    configure!(AUTH_PASSWORD_VALIDATORS = Any[CommonPasswordValidator(), MinimumLengthValidator(min_length = 12)])
    try
        # PasswordValidationTest.test_validate_password
        @test isempty(validate_password("sufficiently-long"))
        short = "This password is too short. It must contain at least 12 characters."
        @test validate_password("django4242") == [short]
        @test validate_password("password") == ["This password is too common.", short]
        @test isempty(validate_password("password"; validators = []))
        # test_password_changed, test_password_changed_with_custom_validator
        @test password_changed("password") === nothing
        DJA_SEEN[] = nothing
        seen = DJA_SEEN
        u0 = (username = "u",)
        password_changed("password"; user = u0, validators = [DjaRecordingValidator()])
        @test seen[] == ("password", u0)
        # test_password_validators_help_texts, test_password_validators_help_text_html (+ escaping, empty)
        ht = password_validators_help_texts()
        @test length(ht) == 2 && occursin("12 characters", ht[2])
        @test isempty(password_validators_help_texts([]))
        h = password_validators_help_text_html()
        @test count("<li>", string(h)) == 2 && occursin("12 characters", string(h))
        @test string(password_validators_help_text_html([DjaAmpersandValidator()])) == "<ul><li>Must contain &amp;</li></ul>"
        @test string(password_validators_help_text_html([])) == ""
    finally
        old === nothing ? delete!(Juango.SETTINGS, :AUTH_PASSWORD_VALIDATORS) : configure!(AUTH_PASSWORD_VALIDATORS = old)
    end
    err(v, p; user = nothing) = Juango.password_error(v, p, user)
    # MinimumLengthValidatorTest.test_validate, test_help_text
    @test err(MinimumLengthValidator(min_length = 8), "12345678") === nothing && err(MinimumLengthValidator(min_length = 3), "123") === nothing
    @test err(MinimumLengthValidator(min_length = 8), "1234567") == "This password is too short. It must contain at least 8 characters."
    @test err(MinimumLengthValidator(min_length = 3), "12") == "This password is too short. It must contain at least 3 characters."
    @test Juango.password_help_text(MinimumLengthValidator(min_length = 8)) == "Your password must contain at least 8 characters."
    # UserAttributeSimilarityValidatorTest.test_validate
    user = (username = "testclient", email = "testclient@example.com", first_name = "Test", last_name = "Client")
    sim = UserAttributeSimilarityValidator
    @test err(sim(), "testclient") === nothing
    @test err(sim(), "testclient"; user = user) == "The password is too similar to the username."
    @test err(sim(), "example.com"; user = user) == "The password is too similar to the email."     # (a NamedTuple: no verbose names)
    @test err(sim(user_attributes = [:first_name], max_similarity = 0.3), "testclient"; user = user) == "The password is too similar to the first_name."
    @test err(sim(user_attributes = [:first_name], max_similarity = 1), "Test"; user = user) == "The password is too similar to the first_name."
    @test_throws "max_similarity must be at least 0.1" sim(max_similarity = 0.09)
    @test err(sim(user_attributes = [:first_name]), "testclient"; user = user) === nothing
    # (with a user model: the fields' verbose names, as Django's)
    port_u = User(username = "testclient", email = "testclient@example.com", first_name = "Test", last_name = "Client")
    @test err(sim(), "example.com"; user = port_u) == "The password is too similar to the email address."
    @test err(sim(user_attributes = [:first_name], max_similarity = 0.3), "testclient"; user = port_u) == "The password is too similar to the first name."
    # test_validate_property (any property of the user)
    @test err(sim(), "foobar"; user = (username = "foobar",)) == "The password is too similar to the username."
    @test Juango.password_help_text(sim()) == "Your password can’t be too similar to your other personal information."
    # CommonPasswordValidatorTest
    @test err(CommonPasswordValidator(), "a-safe-password") === nothing && err(CommonPasswordValidator(), "godzilla") == "This password is too common."
    for p in ["asdfjkl:", "&#2336:"]                                                     # test_common_hexed_codes
        @test err(CommonPasswordValidator(), p) == "This password is too common."
    end
    path = tempname()
    write(path, "from-my-custom-list\n")
    @test err(CommonPasswordValidator(path = path), "a-safe-password") === nothing      # test_validate_custom_list
    @test err(CommonPasswordValidator(path = path), "from-my-custom-list") == "This password is too common."
    @test all(p -> p == lowercase(p), Juango.common_passwords(nothing))                  # test_validate_django_supplied_file
    @test Juango.password_help_text(CommonPasswordValidator()) == "Your password can’t be a commonly used password."
    # NumericPasswordValidatorTest
    @test err(NumericPasswordValidator(), "a-safe-password") === nothing && err(NumericPasswordValidator(), "42424242") == "This password is entirely numeric."
    @test Juango.password_help_text(NumericPasswordValidator()) == "Your password can’t be entirely numeric."
    # UsernameValidatorsTests
    for v in ["joe", "René", "ᴮᴵᴳᴮᴵᴿᴰ", "أحمد"]
        @test UnicodeUsernameValidator(v) === true
    end
    for v in ["o'connell", "عبد ال", "zerowidth​space", "nonbreaking space", "en–dash", "trailingnewline\u000a"]
        @test UnicodeUsernameValidator(v) isa AbstractString
    end
    for v in ["glenn", "GLEnN", "jean-marc"]
        @test ASCIIUsernameValidator(v) === true
    end
    for v in ["o'connell", "Éric", "jean marc", "أحمد", "trailingnewline\n"]
        @test ASCIIUsernameValidator(v) isa AbstractString
    end
    # not translated: test_get_password_validators_* (validators are values, not dotted paths), test_l10n
    # (mocks ngettext), test_custom_error* (Python subclasses), error codes (messages only)
end

@testset "django auth: test_hashers" begin
    old_hashers = get(Juango.SETTINGS, :PASSWORD_HASHERS, nothing)
    configure!(PASSWORD_HASHERS = Juango.DEFAULT_PASSWORD_HASHERS)          # (Django's list; other tests narrow it)
    try
    # TestUtilsHashPass.test_simple
    enc = make_password("lètmein")
    @test startswith(enc, "pbkdf2_sha256\$") && is_password_usable(enc) && check_password("lètmein", enc) && !check_password("lètmeinz", enc)
    blank = make_password("")
    @test startswith(blank, "pbkdf2_sha256\$") && is_password_usable(blank) && check_password("", blank) && !check_password(" ", blank)
    # test_pbkdf2, test_low_level_pbkdf2 (Django's vectors)
    enc = make_password("lètmein"; salt = "seasalt", iterations = 1_800_000)
    @test enc == "pbkdf2_sha256\$1800000\$seasalt\$sXv9FzN4gEo6/P8G5H1jvir9BIb5e5EkXoVGyjOniNE="
    @test check_password("lètmein", enc) && !check_password("lètmeinz", enc) && Juango.algorithm(Juango.identify_hasher(enc)) == "pbkdf2_sha256"
    @test make_password("lètmein"; salt = "seasalt2", iterations = 1_800_000) ==
          "pbkdf2_sha256\$1800000\$seasalt2\$swjWuQn/bYIeQWF1JQRMdMdckgYo6ZXtwyjAMt8Nxdg="
    # (salt entropy: a weak salt is re-hashed)
    h = PBKDF2Hasher()
    @test Juango.must_update(h, make_password("lètmein"; salt = "iodizedsalt")) && !Juango.must_update(h, make_password("lètmein"))
    # test_low_level_pbkdf2_sha1
    s1 = Juango.encode_password(PBKDF2SHA1Hasher(), "lètmein", "seasalt2"; iterations = 1_800_000)
    @test s1 == "pbkdf2_sha1\$1800000\$seasalt2\$MEx5Z/KZ384PO7zdMHxMvXH2k3g="
    @test check_password("lètmein", s1) && !check_password("lètmeinz", s1)             # (in the default PASSWORD_HASHERS, as Django's)
    # test_unusable, test_unspecified_password, test_is_password_usable
    un = make_password(nothing)
    @test length(un) == 41 && !is_password_usable(un) && !check_password(nothing, un) && !check_password(un, un) &&
          !check_password("!", un) && !check_password("", un) && un != make_password(nothing)
    @test !check_password(nothing, make_password("lètmein"))
    @test all(is_password_usable, ["lètmein_badencoded", "", nothing])
    # test_bad_algorithm
    @test_throws "Unknown password hashing algorithm 'lolcat'. Did you specify it in the PASSWORD_HASHERS setting?" make_password("lètmein"; hasher = "lolcat")
    @test Juango.identify_hasher("lolcat\$salt\$hash") === nothing
    # test_upgrade (a password from another hasher is re-hashed with the first one when it's checked)
    old = make_password("lètmein"; hasher = PBKDF2SHA1Hasher(iterations = 1000))
    new = Ref{Any}(nothing)
    @test check_password("lètmein", old; setter = p -> (new[] = p)) && new[] == "lètmein"
    new[] = nothing
    @test !check_password("wrong", old; setter = p -> (new[] = p)) && new[] === nothing  # test_no_upgrade_on_incorrect_pass
    # TestUtilsHashPassScrypt.test_scrypt (Django's vector)
    sc = make_password("lètmein"; salt = "seasalt", hasher = "scrypt")
    @test sc == "scrypt\$16384\$seasalt\$8\$5\$ECMIUp+LMxMSK8xB/IVyba+KYGTI7FTnet025q/1f/vBAVnnP3hdYqJuRi+mJn6ji6ze3Fbb7JEFPKGpuEf5vw=="
    @test check_password("lètmein", sc) && !check_password("lètmeinz", sc)
    # TestUtilsHashPassArgon2.test_argon2
    a2 = make_password("lètmein"; hasher = "argon2")
    @test startswith(a2, "argon2\$argon2id\$") && check_password("lètmein", a2) && !check_password("lètmeinz", a2)
    @test check_password("", make_password(""; hasher = "argon2"))
    # (old argon2i hashes, as Django still verifies: #261)
    @test_broken check_password("secret", "argon2\$argon2i\$v=19\$m=8,t=1,p=1\$c2FsdHNhbHQ\$YC9+jJCrQhs5R6db7LlN8Q")
    # bcrypt_sha256 (TestUtilsHashPass.test_bcrypt_sha256)
    b = make_password("lètmein"; hasher = "bcrypt_sha256")
    @test startswith(b, "bcrypt_sha256\$") && check_password("lètmein", b) && !check_password("lètmeinz", b)
    # not translated: the md5 hasher (#261), harden_runtime and the Python hasher API (decode, safe_summary),
    # the asynchronous acheck_password, the bytes passwords (Julia strings)
    finally
        old_hashers === nothing ? delete!(Juango.SETTINGS, :PASSWORD_HASHERS) : configure!(PASSWORD_HASHERS = old_hashers)
    end
end
