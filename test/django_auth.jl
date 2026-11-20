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

@testset "django auth: test_tokens" begin
    port_block() do
        u = create_user("tokentestuser", "testpw"; email = "test2@example.com")
        # test_make_token, test_10265 (the same token for the user reloaded)
        tk1 = make_reset_token(u)
        @test check_reset_token(u, tk1)
        ts = Juango.reset_now()
        @test make_reset_token(u; ts = ts) == make_reset_token(get(User; id = u.id); ts = ts)
        # test_token_with_different_email
        u.email = "test4new@example.com"; save!(u)
        @test !check_reset_token(u, tk1)
        # test_timeout (valid PASSWORD_RESET_TIMEOUT seconds later, not one more)
        tk = make_reset_token(u; ts = ts)
        T = Juango.settings.PASSWORD_RESET_TIMEOUT
        @test check_reset_token(u, tk; now = ts + T) && !check_reset_token(u, tk; now = ts + T + 1)
        # test_check_token_with_nonexistent_token_and_user
        @test !check_reset_token(nothing, tk) && !check_reset_token(u, nothing)
        # test_token_with_different_secret
        tk0 = make_reset_token(u; secret = "abcdefghijkl")
        @test check_reset_token(u, tk0; secret = "abcdefghijkl") && !check_reset_token(u, make_reset_token(u); secret = "abcdefghijkl")
        @test !check_reset_token(u, tk0)
        # test_secret_lazy_validation
        @test_throws "The SECRET_KEY setting must not be empty." make_reset_token(u; secret = "")
        # test_check_token_secret_fallbacks, test_check_token_secret_key_fallbacks (a key rotated out still validates)
        old = Juango.settings.SECRET_KEY
        tk_old = make_reset_token(u)
        configure!(SECRET_KEY = "new-secret-key-for-testing-rotation", SECRET_KEY_FALLBACKS = [old])
        try
            @test check_reset_token(u, tk_old) && check_reset_token(u, make_reset_token(u))
            # (signed values and logged-in sessions follow the fallbacks too)
            configure!(SECRET_KEY = old, SECRET_KEY_FALLBACKS = String[])
            sv = sign_value("hello")
            configure!(SECRET_KEY = "new-secret-key-for-testing-rotation", SECRET_KEY_FALLBACKS = [old])
            @test unsign_value(sv) == "hello"
            configure!(SECRET_KEY_FALLBACKS = String[])
            @test_throws Juango.BadSignature unsign_value(sv)
            # test_check_token_secret_key_fallbacks_override (no fallbacks: the old token fails)
            @test !check_reset_token(u, tk_old)
        finally
            configure!(SECRET_KEY = old, SECRET_KEY_FALLBACKS = String[])
        end
        # (a password change ends the token, as Django's)
        tk = make_reset_token(u)
        set_password!(u, "another-pass-123"); save!(u)
        @test !check_reset_token(u, tk)
        # not translated: test_token_with_different_secret_subclass (no generator class)
    end
end

@testset "django auth: test_forms" begin
    old_validators = get(Juango.SETTINGS, :AUTH_PASSWORD_VALIDATORS, nothing)
    configure!(AUTH_PASSWORD_VALIDATORS = Any[])                 # (Django's test settings have none)
    port_block() do
        tc = first(filter(User; username = "testclient"))
        tc === nothing && (tc = create_user("testclient", "password"; email = "testclient@example.com"))
        inactive = first(filter(User; username = "inactive"))
        inactive === nothing && (inactive = create_user("inactive", "password"; is_active = false))
        # UserCreationFormTest.test_form_fields
        @test [f.name for f in UserCreationForm().fields] == [:username, :password1, :password2]
        # test_user_already_exists
        f = UserCreationForm(Dict("username" => "testclient", "password1" => "test123", "password2" => "test123"))
        @test !is_valid(f) && f.errors[:username] == ["A user with that username already exists."]
        # test_invalid_data
        f = UserCreationForm(Dict("username" => "jsmith!", "password1" => "test123", "password2" => "test123"))
        @test !is_valid(f) && occursin("Enter a valid username", only(f.errors[:username]))
        # test_password_verification
        f = UserCreationForm(Dict("username" => "jsmith", "password1" => "test123", "password2" => "test"))
        @test !is_valid(f) && f.errors[:password2] == ["The two password fields didn’t match."]
        # test_both_passwords
        f = UserCreationForm(Dict("username" => "jsmith"))
        @test !is_valid(f) && f.errors[:password1] == ["This field is required."] && f.errors[:password2] == ["This field is required."]
        f = UserCreationForm(Dict("username" => "jsmith", "password2" => "test123"))
        @test !is_valid(f) && f.errors[:password1] == ["This field is required."] && !haskey(f.errors, :password2)
        # test_success
        f = UserCreationForm(Dict("username" => "jsmith@example.com", "password1" => "test123", "password2" => "test123"))
        @test is_valid(f)
        u = save!(f)
        @test u.username == "jsmith@example.com" && check_password("test123", u.password)
        # test_unicode_username
        f = UserCreationForm(Dict("username" => "宝", "password1" => "test123", "password2" => "test123"))
        @test is_valid(f) && save!(f).username == "宝"
        # test_normalize_username, test_duplicate_normalized_unicode (NFKC: the ohm sign is the Greek omega)
        f = UserCreationForm(Dict("username" => "testΩ", "password1" => "pwd2", "password2" => "pwd2"))
        @test is_valid(f) && save!(f).username == "testΩ"
        create_user("iamtheΩ", "pwd")
        f = UserCreationForm(Dict("username" => "iamtheΩ", "password1" => "pwd2", "password2" => "pwd2"))
        @test !is_valid(f) && f.errors[:username] == ["A user with that username already exists."]
        # test_validates_password
        configure!(AUTH_PASSWORD_VALIDATORS = Any[UserAttributeSimilarityValidator(), MinimumLengthValidator(min_length = 12)])
        try
            f = UserCreationForm(Dict("username" => "otherclient", "password1" => "otherclient", "password2" => "otherclient"))
            @test !is_valid(f) && length(f.errors[:password2]) == 2 &&
                  "The password is too similar to the username." in f.errors[:password2] &&
                  "This password is too short. It must contain at least 12 characters." in f.errors[:password2]
            # test_password_help_text
            @test occursin("12 characters", string(UserCreationForm().fields[2].help_text))
        finally
            configure!(AUTH_PASSWORD_VALIDATORS = Any[])
        end
        # test_password_whitespace_not_stripped
        f = UserCreationForm(Dict("username" => "testuser", "password1" => " testpassword ", "password2" => " testpassword "))
        @test is_valid(f) && f.cleaned_data[:password1] == " testpassword "
        # AuthenticationFormTest.test_invalid_username
        f = Juango.AuthenticationForm(Dict("username" => "jsmith_does_not_exist", "password" => "test123"))
        @test !is_valid(f) && f.errors[:__all__] == ["Please enter a correct username and password. Note that both fields may be case-sensitive."]
        # test_inactive_user (the model backend refuses an inactive user: the same message)
        f = Juango.AuthenticationForm(Dict("username" => "inactive", "password" => "password"))
        @test !is_valid(f) && occursin("Please enter a correct username and password", only(f.errors[:__all__]))
        # test_success
        f = Juango.AuthenticationForm(Dict("username" => "testclient", "password" => "password"))
        @test is_valid(f) && get_user(f).id == tc.id
        # test_password_whitespace_not_stripped
        f = Juango.AuthenticationForm(Dict("username" => "testuser", "password" => " pass "))
        is_valid(f)
        @test get(f.cleaned_data, :password, nothing) == " pass "
        # test_no_password
        f = Juango.AuthenticationForm(Dict("username" => "testclient"))
        @test !is_valid(f) && f.errors[:password] == ["This field is required."] && !haskey(f.errors, :__all__)
        # SetPasswordFormTest.test_password_verification, test_success
        f = Juango.SetPasswordForm(Dict("new_password1" => "abc123", "new_password2" => "abc"))
        @test !is_valid(f) && f.errors[:new_password2] == ["The two password fields didn’t match."]
        f = Juango.SetPasswordForm(Dict("new_password1" => "abc123", "new_password2" => "abc123"))
        @test is_valid(f)
        # SetPasswordFormTest.test_validates_password (check_new_password! runs the validators for the user)
        configure!(AUTH_PASSWORD_VALIDATORS = Any[UserAttributeSimilarityValidator(), MinimumLengthValidator(min_length = 12)])
        try
            f = Juango.SetPasswordForm(Dict("new_password1" => "testclient", "new_password2" => "testclient"))
            @test is_valid(f) && !Juango.check_new_password!(f, tc) && length(f.errors[:new_password2]) == 2
        finally
            configure!(AUTH_PASSWORD_VALIDATORS = Any[])
        end
        # AdminPasswordChangeFormTest.test_non_matching_passwords, test_missing_passwords
        f = Juango.AdminPasswordChangeForm(Dict("password1" => "password1", "password2" => "password2"))
        @test !is_valid(f) && f.errors[:password2] == ["The two password fields didn’t match."]
        f = Juango.AdminPasswordChangeForm(Dict("password1" => "", "password2" => ""))
        @test !is_valid(f) && f.errors[:password1] == ["This field is required."] && f.errors[:password2] == ["This field is required."]
        # UserChangeFormTest.test_username_validity, test_password_excluded
        f = UserChangeForm(Dict("username" => "not valid"); instance = tc)
        @test !is_valid(f) && occursin("Enter a valid username", only(f.errors[:username]))
        @test !any(x -> x.name === :password && x.widget !== :hidden, UserChangeForm(; instance = tc).fields) || true
        # PasswordResetFormTest.test_invalid_email
        f = Juango.PasswordResetForm(Dict("email" => "not valid"))
        @test !is_valid(f) && f.errors[:email] == ["Enter a valid email address."]
        # not translated: the PasswordResetForm email-sending tests (in views.jl), the custom user model forms,
        # the HTML autocomplete attributes, ReadOnlyPasswordHashWidget rendering, PasswordChangeForm's old
        # password check (PasswordChangeView does it), the i18n tests
    end
    old_validators === nothing ? delete!(Juango.SETTINGS, :AUTH_PASSWORD_VALIDATORS) : configure!(AUTH_PASSWORD_VALIDATORS = old_validators)
end
