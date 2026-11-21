# Django's auth tests, ported (#227), part 2: tests/auth_tests test_auth_backends, test_models,
# test_basic, test_signals, test_context_processors and test_remote_user.
# julia --project=test test/django_auth_backends.jl   (see setup.jl)
#
# Juango's backends are values in AUTHENTICATION_BACKENDS whose types have methods of
# backend_authenticate, backend_has_perm, ... (Django's backend classes and their methods); a
# backend is named by its type ("Juango.ModelBackend") where Django takes a dotted path. Python's
# ValueError and TypeError are ArgumentErrors. Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

# Django's SimpleRowlevelBackend and TestObj
struct DabTestObj end
struct DabRowlevelBackend end
function Juango.backend_has_perm(::DabRowlevelBackend, u, perm, obj)
    obj === nothing && return nothing                  # (only row-level permissions)
    obj isa DabTestObj || return false
    get_username(u) == "dab_test2" && return true
    u isa AnonymousUser && perm == "anon" && return true
    !u.is_active && perm == "inactive" && return true
    false
end
Juango.backend_has_module_perms(::DabRowlevelBackend, u, app) = (u isa AnonymousUser || u.is_active) && app == "app1"
function Juango.backend_get_all_permissions(::DabRowlevelBackend, u, obj)
    obj === nothing && return Set{String}()
    obj isa DabTestObj || return Set(["none"])
    u isa AnonymousUser && return Set(["anon"])
    get_username(u) == "dab_test2" ? Set(["simple", "advanced"]) : Set(["simple"])
end
function Juango.backend_get_group_permissions(::DabRowlevelBackend, u, obj)
    obj === nothing && return Set{String}()
    obj isa DabTestObj || return Set(["none"])
    "dab_group" in [g.name for g in u.groups] ? Set(["group_perm"]) : Set(["none"])
end
# Django's PermissionDeniedBackend
struct DabDeniedBackend end
Juango.backend_authenticate(::DabDeniedBackend, req; kw...) = throw(PermissionDenied())
Juango.backend_has_perm(::DabDeniedBackend, u, perm, obj) = throw(PermissionDenied())
Juango.backend_has_module_perms(::DabDeniedBackend, u, app) = throw(PermissionDenied())
# a backend that takes only a token (SkippedBackend: the credentials don't fit its method)
struct DabTokenBackend end
Juango.backend_authenticate(::DabTokenBackend, req; token) = token == "s3cret" ? get(User; username = "dab_test") : nothing
# TypeErrorBackend
struct DabErrorBackend end
Juango.backend_authenticate(::DabErrorBackend, req; kw...) = throw(ArgumentError("a bug in the backend"))
# CustomModelBackend (with_perm of its own)
struct DabCustomBackend end
Juango.backend_with_perm(::DabCustomBackend, perm; obj = nothing, kw...) =
    filter(User; username = obj === nothing ? "dab_charlie" : "dab_charlie2")
# CustomRemoteUserBackend: the realm is stripped, the user's email set up
struct DabRemoteBackend <: AbstractRemoteUserBackend
    create_unknown_user::Bool
end
Juango.remote_clean_username(::DabRemoteBackend, name) = split(name, '@')[1]
function Juango.remote_configure_user(::DabRemoteBackend, req, u; created = true)
    u.email = created ? "user@example.com" : "existing@example.com"
    save!(u)
end

dab_whoami(req) = HttpResponse(is_authenticated(req.user) ? "user:" * get_username(req.user) : "anon")

dab_cleanup() = (delete!(filter(User; username__startswith = "dab")); delete!(filter(Group; name__startswith = "dab"));
                 delete!(filter(Permission; codename__startswith = "dabp")))
dab_reload(u) = get(User; id = u.id)
dab_req(u = nothing) = (r = get(RequestFactory(), "/"); r.session = Juango.Session(); u === nothing || (r.user = u); r)

@testset "django auth: test_auth_backends" begin
    dab_cleanup()
    ct = get_for_model(Group)
    mkperm(code) = create(Permission; name = code, content_type = ct, codename = code)
    try
        p1, p2, p3, pg = mkperm("dabp1"), mkperm("dabp2"), mkperm("dabp3"), mkperm("dabp_group")
        u = create_user("dab_test", "test"; email = "test@example.com")
        # BaseModelBackendTest.test_has_perm
        @test !has_perm(u, "auth.dabp1")
        u.is_staff = true; save!(u)
        @test !has_perm(u, "auth.dabp1")
        u.is_superuser = true; save!(u)
        @test has_perm(u, "auth.dabp1")
        u.is_staff = true; u.is_superuser = true; u.is_active = false; save!(u)
        @test !has_perm(u, "auth.dabp1")
        u.is_staff = false; u.is_superuser = false; u.is_active = true; save!(u)
        u = dab_reload(u)
        # test_custom_perms
        add!(u.user_permissions, p1)
        u = dab_reload(u)
        @test get_all_permissions(u) == Set(["auth.dabp1"])
        @test Juango.get_user_permissions(u) == Set(["auth.dabp1"])
        @test isempty(Juango.get_group_permissions(u))
        @test !has_module_perms(u, "Group") && has_module_perms(u, "auth")
        add!(u.user_permissions, p2, p3)
        @test get_all_permissions(u) == Set(["auth.dabp1"])            # (cached on the user object)
        u = dab_reload(u)
        @test get_all_permissions(u) == Set(["auth.dabp1", "auth.dabp2", "auth.dabp3"])
        @test !has_perm(u, "dabp1") && has_perm(u, "auth.dabp1") && has_perms(u, ["auth.dabp2", "auth.dabp3"])
        g = create(Group; name = "dab_group")
        add!(g.permissions, pg); add!(u.groups, g)
        u = dab_reload(u)
        @test get_all_permissions(u) == Set(["auth.dabp1", "auth.dabp2", "auth.dabp3", "auth.dabp_group"])
        @test Juango.get_user_permissions(u) == Set(["auth.dabp1", "auth.dabp2", "auth.dabp3"])
        @test Juango.get_group_permissions(u) == Set(["auth.dabp_group"])
        @test has_perms(u, ["auth.dabp3", "auth.dabp_group"])
        # test_has_no_object_perm: ModelBackend has no per-object permissions
        @test !has_perm(u, "auth.dabp1"; obj = "object") && isempty(get_all_permissions(u; obj = "object"))
        @test has_perm(u, "auth.dabp1")
        # test_anonymous_has_no_permissions
        mb, anon = ModelBackend(), AnonymousUser()
        @test isempty(Juango.backend_get_all_permissions(mb, anon, nothing)) &&
              isempty(Juango.backend_get_user_permissions(mb, anon, nothing)) &&
              isempty(Juango.backend_get_group_permissions(mb, anon, nothing))
        # test_inactive_has_no_permissions
        u.is_active = false; save!(u)
        u = dab_reload(u)
        @test isempty(Juango.backend_get_all_permissions(mb, u, nothing)) &&
              isempty(Juango.backend_get_user_permissions(mb, u, nothing)) &&
              isempty(Juango.backend_get_group_permissions(mb, u, nothing)) && !has_perm(u, "auth.dabp1")
        # test_authenticate_inactive
        @test authenticate("dab_test", "test") === nothing
        u.is_active = true; save!(u)
        @test authenticate("dab_test", "test").id == u.id
        # test_get_all_superuser_permissions
        su = create_superuser("dab_super", "test"; email = "s@example.com")
        @test length(get_all_permissions(su)) == count(objects(Permission))
        # test_authentication_without_credentials
        @test authenticate(nothing; password = "test") === nothing && authenticate(nothing; username = "dab_test") === nothing
        # test_get_user
        @test Juango.backend_get_user(mb, u.id).id == u.id

        # AllowAllUsersModelBackendTest: an inactive user logs in, still with no permissions
        override_settings(AUTHENTICATION_BACKENDS = Any[AllowAllUsersModelBackend()]) do
            ina = create_user("dab_inactive", "test"; is_active = false)
            add!(ina.user_permissions, p1)
            @test authenticate("dab_inactive", "test").id == ina.id                 # test_authenticate
            @test Juango.backend_get_user(AllowAllUsersModelBackend(), ina.id).id == ina.id   # test_get_user
            @test !has_perm(dab_reload(ina), "auth.dabp1")
        end

        # RowlevelBackendTest
        u2 = create_user("dab_test2", "test"); u3 = create_user("dab_test3", "test")
        override_settings(AUTHENTICATION_BACKENDS = Any[ModelBackend(), DabRowlevelBackend()]) do
            o = DabTestObj()
            @test !has_perm(u, "perm"; obj = o) && has_perm(u2, "perm"; obj = o) && !has_perm(u2, "perm")   # test_has_perm
            @test has_perms(u2, ["simple", "advanced"]; obj = o)
            @test !has_perm(u3, "perm"; obj = o) && !has_perm(u3, "anon"; obj = o) && !has_perms(u3, ["simple", "advanced"]; obj = o)
            @test get_all_permissions(u; obj = o) == Set(["simple"])                     # test_get_all_permissions
            @test get_all_permissions(u2; obj = o) == Set(["simple", "advanced"]) && isempty(get_all_permissions(u2))
            add!(g.user_set, u3)                                                          # test_get_group_permissions
            @test Juango.get_group_permissions(dab_reload(u3); obj = o) == Set(["group_perm"])
        end
        # AnonymousUserBackendTest: a backend may give anonymous users permissions
        override_settings(AUTHENTICATION_BACKENDS = Any[DabRowlevelBackend()]) do
            a, o = AnonymousUser(), DabTestObj()
            @test !has_perm(a, "perm"; obj = o) && has_perm(a, "anon"; obj = o)
            @test has_perms(a, ["anon"]; obj = o) && !has_perms(a, ["anon", "perm"]; obj = o)
            @test has_module_perms(a, "app1") && !has_module_perms(a, "app2")
            @test get_all_permissions(a; obj = o) == Set(["anon"])
        end
        # NoBackendsTest
        override_settings(AUTHENTICATION_BACKENDS = Any[]) do
            @test_throws Juango.ImproperlyConfigured has_perm(u, "perm"; obj = DabTestObj())
            @test_throws Juango.ImproperlyConfigured authenticate("dab_test", "test")
        end
        # InActiveUserBackendTest: and inactive users
        override_settings(AUTHENTICATION_BACKENDS = Any[DabRowlevelBackend()]) do
            ina = dab_reload(u); ina.is_active = false
            @test !has_perm(ina, "perm"; obj = DabTestObj()) && has_perm(ina, "inactive"; obj = DabTestObj())
            @test !has_module_perms(ina, "app1") && !has_module_perms(ina, "app2")
        end

        # PermissionDeniedBackendTest
        failed = Any[]
        lf(sender; credentials, kw...) = push!(failed, credentials)
        connect!(user_login_failed, lf; sender = :authenticate)
        try
            override_settings(AUTHENTICATION_BACKENDS = Any[DabDeniedBackend(), ModelBackend()]) do
                @test authenticate("dab_test", "test") === nothing                       # test_permission_denied
                @test failed == [Dict("username" => "dab_test", "password" => "********************")]
                @test !has_perm(dab_reload(u), "auth.dabp1")                            # test_has_perm_denied
                @test !has_module_perms(dab_reload(u), "auth")                           # test_has_module_perms_denied
            end
            override_settings(AUTHENTICATION_BACKENDS = Any[ModelBackend(), DabDeniedBackend()]) do
                @test authenticate("dab_test", "test").id == u.id                       # test_authenticates
                @test has_perm(dab_reload(u), "auth.dabp1") && has_module_perms(dab_reload(u), "auth")
            end
        finally
            disconnect!(user_login_failed, lf; sender = :authenticate)
        end

        # SkippedBackend: a backend that doesn't take the credentials is skipped; TypeErrorBackend: errors propagate
        override_settings(AUTHENTICATION_BACKENDS = Any[DabTokenBackend(), ModelBackend()]) do
            @test authenticate("dab_test", "test").id == u.id                           # test_skips_backends_without_arguments
            @test authenticate(nothing; token = "s3cret").id == u.id
        end
        override_settings(AUTHENTICATION_BACKENDS = Any[DabErrorBackend()]) do
            @test_throws ArgumentError authenticate("dab_test", "test")                 # test_type_error_raised
        end

        # ChangedBackendSettingsTest: a session from a backend no longer in the settings is logged out
        r = dab_req()
        login!(r, dab_reload(u))
        @test get_user(r).id == u.id
        override_settings(AUTHENTICATION_BACKENDS = Any[DabRowlevelBackend()]) do
            @test get_user(r) isa AnonymousUser                                        # test_changed_backend_settings
        end

        # SelectingBackendTests
        override_settings(AUTHENTICATION_BACKENDS = Any[ModelBackend(), DabRowlevelBackend()]) do
            @test_throws ArgumentError login!(dab_req(), dab_reload(u))                   # test_backend_path_login_without_authenticate_multiple_backends
            r = dab_req(); login!(r, dab_reload(u); backend = ModelBackend())             # test_backend_path_login_with_explicit_backends
            @test r.session["_auth_user_backend"] == "Juango.ModelBackend"
            r = dab_req(); login!(r, dab_reload(u); backend = "Juango.ModelBackend")
            @test r.session["_auth_user_backend"] == "Juango.ModelBackend"
            r = dab_req(); login!(r, authenticate("dab_test", "test"))                    # test_backend_path (from authenticate)
            @test r.session["_auth_user_backend"] == "Juango.ModelBackend"
        end
        override_settings(AUTHENTICATION_BACKENDS = Any[ModelBackend()]) do
            r = dab_req(); login!(r, dab_reload(u))                                       # test_backend_path_login_without_authenticate_single_backend
            @test r.session["_auth_user_backend"] == "Juango.ModelBackend"
        end
        # not translated: the custom user models (ExtensionUser, CustomPermissionsUser, CustomUser without
        # is_active, UUIDUser), backends loaded by import path (ImportedBackendTests), authenticate's
        # sensitive_variables, and the hasher timing test (make_password is run for unknown users: auth.jl)
    finally
        dab_cleanup()
    end
end

@testset "django auth: test_models, test_basic" begin
    dab_cleanup()
    try
        # NaturalKeysTestCase
        staff = create_user("dab_staff", "pw")
        @test natural_key(staff) == ("dab_staff",) && get_by_natural_key(User, "dab_staff").id == staff.id
        g = create(Group; name = "dab_group")
        @test natural_key(g) == ("dab_group",) && get_by_natural_key(Group, "dab_group").id == g.id
        p = get(Permission; codename = "add_user")
        @test natural_key(p) == ("add_user", "auth", "user") && get_by_natural_key(Permission, "add_user", "auth", "user").id == p.id

        # UserManagerTestCase
        u = create_user("dab_user", "test"; email = "normal@DOMAIN.COM")
        @test u.email == "normal@domain.com" && u.username == "dab_user" && Juango.has_usable_password(u)   # test_create_user
        # (create_user validates the user, as Django's doesn't: the address with a space is checked on its own)
        @test Juango.normalize_email("email\\ with_whitespace@D.COM") == "email\\ with_whitespace@d.com"   # rfc3696
        @test create_user("dab_u3"; email = "normal@DOMAIN.COM", is_staff = true).is_staff        # test_create_user_is_staff
        @test_throws ArgumentError create_user("")                                                # test_empty_username
        @test_throws ArgumentError create_superuser("dab_s1", "pw"; is_superuser = false)          # ..._on_false_is_superuser
        @test_throws ArgumentError create_superuser("dab_s2", "pw"; is_staff = false)              # ..._on_false_is_staff
        @test Juango.normalize_email(nothing) == "" && Juango.normalize_email("") == "" &&
              Juango.normalize_email("foo@BAR.COM") == "foo@bar.com"                              # test_normalize_email
        @test Juango.normalize_email("email\\@with_at@D.COM") == "email\\@with_at@d.com"

        # AbstractBaseUserTests, AbstractUserTestCase
        nu = User(username = "dab_iamtheΩ", email = "foo@BAR.com")                           # test_clean_normalize_username
        full_clean(nu)
        @test nu.username == "dab_iamtheΩ" && nu.email == "foo@bar.com"                        # (and test_user_clean_normalize_email)
        @test Juango.normalize_username(1) == 1                                                   # (only strings)
        @test u.last_login === nothing                                                           # test_last_login_default
        @test u.is_active                                                                        # IsActiveTestCase.test_builtin_user_isactive
        empty!(Juango.outbox)
        override_settings(EMAIL_BACKEND = :locmem) do
            email_user(u, "Subject here", "This is a message", "from@domain.com")                # test_email_user
        end
        m = only(Juango.outbox)
        @test m.subject == "Subject here" && m.body == "This is a message" && m.from_email == "from@domain.com" && m.to == ["normal@domain.com"]
        empty!(Juango.outbox)
        @test string(u) == "dab_user" && string(g) == "dab_group"                                # test_str
        @test get_full_name(User(first_name = "John", last_name = "Smith")) == "John Smith"
        @test get_short_name(User(first_name = "John", last_name = "Smith")) == "John"

        # AnonymousUserTests
        a = AnonymousUser()
        @test a.id === nothing && a.pk === nothing && a.username == "" && get_username(a) == ""
        @test a.is_anonymous && !a.is_authenticated && !is_authenticated(a) && !a.is_staff && !a.is_active && !a.is_superuser
        @test isempty(Juango.get_user_permissions(a)) && isempty(Juango.get_group_permissions(a)) && isempty(get_all_permissions(a))
        @test string(a) == "AnonymousUser" && a == AnonymousUser() && hash(a) == hash(AnonymousUser())   # test_str, test_eq, test_hash
        @test !has_perm(a, "auth.add_user") && !has_perms(a, ["auth.add_user"]) && !has_module_perms(a, "auth")
        @test_throws ArgumentError has_perms(a, "auth.add_user")                                  # test_has_perms_perm_list_invalid
        @test_throws ArgumentError has_perms(u, "auth.add_user")
        @test_throws MethodError save!(a)                                                         # test_save, test_delete, ...
        @test_throws MethodError delete!(a)
        @test_throws MethodError set_password!(a, "pw")

        # UserWithPermTestCase
        perm = create(Permission; name = "dabp", content_type = get_for_model(Group), codename = "dabp")
        with_p = create_user("dab_withperm", "pw"); add!(with_p.user_permissions, perm)
        grp = create(Group; name = "dab_permgroup"); add!(grp.permissions, perm)
        in_grp = create_user("dab_ingroup", "pw"); add!(in_grp.groups, grp)
        ina = create_user("dab_inactive", "pw"; is_active = false); add!(ina.user_permissions, perm)
        su = create_superuser("dab_super", "pw")
        ina_su = create_superuser("dab_inactsuper", "pw"; is_active = false)
        charlie = create_user("dab_charlie", "pw"); charlie2 = create_user("dab_charlie2", "pw")
        names(qs) = Set(u.username for u in qs if startswith(u.username, "dab"))
        @test names(with_perm("auth.dabp")) == Set(["dab_withperm", "dab_ingroup", "dab_super"])  # test_basic
        @test names(with_perm(perm)) == Set(["dab_withperm", "dab_ingroup", "dab_super"])
        @test names(with_perm("auth.dabp"; is_active = false)) == Set(["dab_inactive", "dab_inactsuper"])
        @test names(with_perm("auth.dabp"; is_active = nothing)) ==
              Set(["dab_withperm", "dab_ingroup", "dab_super", "dab_inactive", "dab_inactsuper"])
        @test names(with_perm("auth.dabp"; include_superusers = false)) == Set(["dab_withperm", "dab_ingroup"])
        @test names(with_perm("auth.nosuchperm")) == Set(["dab_super"])                           # test_nonexistent_permission
        @test isempty(names(with_perm("auth.dabp"; obj = grp)))                                   # (ModelBackend: no per-object)
        for bad in ("nodots", "too.many.dots", "...", "")                                         # test_invalid_permission_name
            @test_throws ArgumentError with_perm(bad)
        end
        @test_throws ArgumentError with_perm(1)                                                   # test_invalid_permission_type
        @test_throws ArgumentError with_perm("auth.dabp"; backend = "invalid.backend.CustomModelBackend")   # test_nonexistent_backend
        override_settings(AUTHENTICATION_BACKENDS = Any[DabCustomBackend(), ModelBackend()]) do
            @test_throws ArgumentError with_perm("auth.dabp")                                     # test_multiple_backends
            @test names(with_perm("auth.dabp"; backend = DabCustomBackend())) == Set(["dab_charlie"])   # test_custom_backend
            @test names(with_perm("auth.dabp"; backend = "Main.DabCustomBackend")) == Set(["dab_charlie"])
            @test names(with_perm("auth.dabp"; backend = DabCustomBackend(), obj = grp)) == Set(["dab_charlie2"])   # ..._pass_obj
            @test names(with_perm("auth.dabp"; backend = "Juango.ModelBackend")) == Set(["dab_withperm", "dab_ingroup", "dab_super"])
        end
        override_settings(AUTHENTICATION_BACKENDS = Any[DabRowlevelBackend()]) do
            @test isempty(with_perm("auth.dabp"))                                                 # test_backend_without_with_perm
        end

        # test_basic: BasicTestCase
        b = create_user("dab_testuser", "testpw"; email = "test@example.com")
        @test check_password(b, "testpw") && !check_password(b, "bad") && b.email == "test@example.com"   # test_user
        Juango.set_unusable_password!(b)
        @test !check_password(b, "testpw") && !Juango.has_usable_password(b)
        @test create_user("dab_noemail", "pw").email == ""                                        # test_user_no_email
        @test create_user("dab_jörg").username == "dab_jörg"                                      # test_unicode_username
        @test create_user("dab_Григорий").username == "dab_Григорий"
        s = create_superuser("dab_super2", "pw"; email = "s@example.com")
        @test s.is_superuser && s.is_staff && s.is_active                                          # test_superuser
        override_settings(AUTH_USER_MODEL = "thismodel.doesntexist") do
            @test_throws Juango.ImproperlyConfigured get_user_model()                                     # test_swappable_user_bad_setting
        end
        # TestGetUser
        @test get_user(dab_req()) isa AnonymousUser                                               # test_get_user_anonymous
        r = dab_req(); login!(r, b)
        @test get_user(r).id == b.id                                                               # test_get_user
        r.session["_auth_user_hash"] = "wrong"
        @test get_user(r) isa AnonymousUser                                                        # (a changed password logs out)
        # not translated: the swapped and custom user models (CustomUser, the email USERNAME_FIELD,
        # IntegerUsernameUser), fixtures with natural keys, migrations' manager methods, and
        # make_random_password (gone from Django). Permission's text is "auth | user | Can add user"
        # (app labels; Django: the apps' verbose names).
    finally
        dab_cleanup()
    end
end

@testset "django auth: test_signals, test_context_processors" begin
    dab_cleanup()
    events = Any[]
    li(sender; request, user, kw...) = push!(events, (:in, get_username(user)))
    lo(sender; request, user, kw...) = push!(events, (:out, user === nothing ? nothing : get_username(user)))
    lf(sender; credentials, kw...) = push!(events, (:failed, credentials))
    connect!(user_logged_in, li); connect!(user_logged_out, lo); connect!(user_login_failed, lf)
    try
        u = create_user("dab_sig", "password")
        @test authenticate("dab_sig", "bad") === nothing                                          # test_login_failed
        @test (:failed, Dict("username" => "dab_sig", "password" => "********************")) in events
        authenticate(nothing; username = "dab_sig", password = "bad", api_key = "k", signature = "s", other = 1)
        @test events[end] == (:failed, Dict("username" => "dab_sig", "password" => "********************",
                                            "api_key" => "********************", "signature" => "********************", "other" => 1))
        r = dab_req()
        login!(r, authenticate("dab_sig", "password"))                                             # test_login
        @test events[end] == (:in, "dab_sig") && dab_reload(u).last_login !== nothing               # (and test_update_last_login)
        logout!(r)                                                                                 # test_logout
        @test events[end] == (:out, "dab_sig")
        logout!(dab_req(AnonymousUser()))                                                          # test_logout_anonymous
        @test events[end] == (:out, nothing)

        # test_context_processors: PermWrapper and PermLookup ({{ perms }})
        add!(u.user_permissions, get(Permission; codename = "add_user"))
        pw = Juango.PermWrapper(dab_reload(u))
        @test "auth" in pw && "auth.add_user" in pw && !("nonexisting" in pw) && !("auth.nonexisting" in pw)   # test_permwrapper_in
        auth = Juango.tattr(pw, Val(:auth))                                                        # (perms.auth in a template)
        @test "add_user" in auth && !("nonexisting" in auth)                                       # test_permlookupdict_in
        @test_throws ArgumentError iterate(pw)                                                     # test_permwrapper_not_iterable
        @test Juango.truthy(auth) && !Juango.truthy(Juango.tattr(pw, Val(:nonexisting)))
        @test Juango.tattr(auth, Val(:add_user)) === true && Juango.tattr(auth, Val(:delete_user)) === false
        @test repr(auth) == "PermLookup(\"auth\")"
        ctx = Dict{String,Any}("perms" => pw)
        @test tr("{% if 'auth' in perms %}A{% endif %}{% if 'auth.add_user' in perms %}B{% endif %}{% if 'add_user' in perms.auth %}C{% endif %}" *
                 "{% if 'nope' in perms %}D{% endif %}{% if perms.auth %}E{% endif %}{% if perms.auth.add_user %}F{% endif %}", ctx) == "ABCEF"
        # not translated: the lazy user (SimpleLazyObject) and the query counts of the context processor
    finally
        disconnect!(user_logged_in, li); disconnect!(user_logged_out, lo); disconnect!(user_login_failed, lf)
        dab_cleanup()
    end
end

@testset "django auth: test_remote_user" begin
    dab_cleanup()
    old_urls, old_mw = Juango.settings.ROOT_URLCONF, Juango.settings.MIDDLEWARE
    configure!(ROOT_URLCONF = [path("remote_user/", dab_whoami)])
    H(name) = Dict("Remote-User" => name)
    try
        override_settings(MIDDLEWARE = vcat(old_mw, [RemoteUserMiddleware]),
                          AUTHENTICATION_BACKENDS = Any[RemoteUserBackend(), ModelBackend()]) do
            c = Client()
            @test text(get(c, "/remote_user/")) == "anon"                                         # test_no_remote_user
            @test text(get(c, "/remote_user/"; headers = H(""))) == "anon"
            n = count(objects(User))
            @test text(get(c, "/remote_user/"; headers = H("dab_newuser"))) == "user:dab_newuser"  # test_unknown_user
            @test count(objects(User)) == n + 1
            @test text(get(c, "/remote_user/"; headers = H("dab_newuser"))) == "user:dab_newuser"
            @test count(objects(User)) == n + 1
            create_user("dab_knownuser"); create_user("dab_knownuser2")
            c = Client()
            @test text(get(c, "/remote_user/"; headers = H("dab_knownuser"))) == "user:dab_knownuser"   # test_known_user
            ll = get(User; username = "dab_knownuser").last_login
            @test ll !== nothing                                                                   # test_last_login
            get(c, "/remote_user/"; headers = H("dab_knownuser"))
            @test get(User; username = "dab_knownuser").last_login == ll                           # (same session: not updated)
            @test text(get(c, "/remote_user/"; headers = H("dab_knownuser2"))) == "user:dab_knownuser2"   # test_user_switch_forces_new_login
            @test text(get(c, "/remote_user/")) == "anon"                                         # test_header_disappears
            # a user logged in by another backend stays logged in without the header
            create_user("dab_modeluser", "pw")
            c = Client(); force_login!(c, get(User; username = "dab_modeluser"); backend = ModelBackend())
            @test text(get(c, "/remote_user/")) == "user:dab_modeluser"
            ina = create_user("dab_inactive"; is_active = false)
            @test text(get(Client(), "/remote_user/"; headers = H("dab_inactive"))) == "anon"      # test_inactive_user
        end
        # AllowAllUsersRemoteUserBackendTest
        override_settings(MIDDLEWARE = vcat(old_mw, [RemoteUserMiddleware]),
                          AUTHENTICATION_BACKENDS = Any[AllowAllUsersRemoteUserBackend()]) do
            @test text(get(Client(), "/remote_user/"; headers = H("dab_inactive"))) == "user:dab_inactive"
        end
        # RemoteUserNoCreateTest
        override_settings(MIDDLEWARE = vcat(old_mw, [RemoteUserMiddleware]),
                          AUTHENTICATION_BACKENDS = Any[RemoteUserBackend(create_unknown_user = false)]) do
            @test text(get(Client(), "/remote_user/"; headers = H("dab_stranger"))) == "anon"
            @test !exists(filter(User; username = "dab_stranger"))
        end
        # RemoteUserCustomTest: clean_username and configure_user
        override_settings(MIDDLEWARE = vcat(old_mw, [RemoteUserMiddleware]),
                          AUTHENTICATION_BACKENDS = Any[DabRemoteBackend(true)]) do
            c = Client()
            @test text(get(c, "/remote_user/"; headers = H("dab_newuser2@example.com"))) == "user:dab_newuser2"   # test_unknown_user
            @test get(User; username = "dab_newuser2").email == "user@example.com"
            @test text(get(c, "/remote_user/"; headers = H("dab_newuser2@example.com"))) == "user:dab_newuser2"   # (the cleaned name matches)
            @test text(get(Client(), "/remote_user/"; headers = H("dab_knownuser@example.com"))) == "user:dab_knownuser"   # test_known_user
            @test get(User; username = "dab_knownuser").email == "existing@example.com"
        end
        # PersistentRemoteUserTest
        override_settings(MIDDLEWARE = vcat(old_mw, [PersistentRemoteUserMiddleware]),
                          AUTHENTICATION_BACKENDS = Any[RemoteUserBackend(), ModelBackend()]) do
            c = Client()
            get(c, "/remote_user/"; headers = H("dab_knownuser"))
            @test text(get(c, "/remote_user/")) == "user:dab_knownuser"                           # test_header_disappears
        end
        # not translated: REMOTE_USER from the WSGI environment (Juango reads a header: REMOTE_USER_HEADER),
        # the async variants, and the CSRF check after a remote login
    finally
        configure!(ROOT_URLCONF = old_urls)
        dab_cleanup()
    end
end

@testset "django auth: test_management (createsuperuser, changepassword)" begin
    dab_cleanup()
    out() = IOBuffer()
    try
        joe = create_user("dab_joe", "qwerty"; email = "joe@example.com")
        # ChangepasswordManagementCommandTestCase
        o = out()
        r = call_command("changepassword", "dab_joe"; getpass = ["not qwerty", "not qwerty"], stdout = o)
        @test String(take!(o)) == "Changing password for user 'dab_joe'\nPassword changed successfully for user 'dab_joe'\n"   # test_get_pass
        @test r == "Password changed successfully for user 'dab_joe'" && check_password(dab_reload(joe), "not qwerty")
        call_command("changepassword"; getpass = ["joes new pw", "joes new pw"], system_user = "dab_joe")      # test_system_username
        @test check_password(dab_reload(joe), "joes new pw")
        e = try call_command("changepassword", "dab_joe2"; getpass = ["x", "x"]); nothing catch e; e end        # test_nonexistent_username
        @test e isa CommandError && e.msg == "user 'dab_joe2' does not exist"
        o = out()
        e = try call_command("changepassword", "dab_joe"; getpass = repeat(["a1b2c3d4e5", "zzzzzzzzzz"], 3), stdout = o); nothing catch e; e end
        @test e isa CommandError && e.msg == "Aborting password change for user 'dab_joe' after 3 attempts"   # test_that_max_tries_exits_1
        @test count("Passwords do not match. Please try again.", String(take!(o))) == 3
        override_settings(AUTH_PASSWORD_VALIDATORS = Any[Juango.NumericPasswordValidator()]) do         # test_password_validation
            er = out()
            e = try call_command("changepassword", "dab_joe"; getpass = fill("1234567890", 6), stderr = er); nothing catch e; e end
            @test e isa CommandError && occursin("This password is entirely numeric.", String(take!(er)))
            call_command("changepassword", "dab_joe"; getpass = ["1234567890", "1234567890", "abcdef1234", "abcdef1234"])   # (then a good one)
            @test check_password(dab_reload(joe), "abcdef1234")
        end
        create_user("dab_Júlia", "pw")
        o = out()
        call_command("changepassword", "dab_Júlia"; getpass = ["n3w p4ss", "n3w p4ss"], stdout = o)           # ..._works_with_nonascii_output
        @test occursin("for user 'dab_Júlia'", String(take!(o)))

        # CreatesuperuserManagementCommandTestCase, --noinput
        o = out()
        call_command("createsuperuser", "--noinput", "--username=dab_su", "--email=su@somewhere.org"; stdout = o)   # test_basic_usage
        su = get(User; username = "dab_su")
        @test String(take!(o)) == "Superuser created successfully.\n"
        @test su.email == "su@somewhere.org" && su.is_superuser && su.is_staff && !Juango.has_usable_password(su)
        e = try call_command("createsuperuser", "--noinput", "--username=dab_noemail"); nothing catch e; e end      # test_no_email_argument
        @test e isa CommandError && e.msg == "You must use --email with --noinput."
        e = try call_command("createsuperuser", "--noinput", "--email=x@y.org"); nothing catch e; e end
        @test e isa CommandError && e.msg == "You must use --username with --noinput."
        e = try call_command("createsuperuser", "--noinput", "--username=\U1f920", "--email=x@y.org"); nothing catch e; e end   # test_validate_username
        @test e isa CommandError && e.msg == "Enter a valid username. This value may contain only letters, numbers, and @/./+/-/_ characters."
        e = try call_command("createsuperuser", "--noinput", "--username=dab_su", "--email=x@y.org"); nothing catch e; e end   # test_existing_username_non_interactive
        @test e isa CommandError && e.msg == "Error: That username is already taken."
        e = try call_command("createsuperuser", "--noinput", "--username=dab_bad", "--email=notanemail"); nothing catch e; e end
        @test e isa CommandError && e.msg == "Enter a valid email address."
        o = out()
        call_command("createsuperuser", "--noinput", "--username=dab_quiet", "--email=q@y.org", "--verbosity=0"; stdout = o)   # test_verbosity_zero
        @test isempty(String(take!(o)))
        call_command("createsuperuser", "--noinput", "--username=dab_joe+admin@somewhere.org", "--email=joe@somewhere.org")   # test_email_in_username
        @test exists(filter(User; username = "dab_joe+admin@somewhere.org"))
        withenv("JUANGO_SUPERUSER_PASSWORD" => "test_password", "JUANGO_SUPERUSER_USERNAME" => "dab_test_superuser",
                "JUANGO_SUPERUSER_EMAIL" => "joe@somewhere.org") do                                                 # test_environment_variable_non_interactive
            call_command("createsuperuser", "--noinput")
        end
        u = get(User; username = "dab_test_superuser")
        @test u.email == "joe@somewhere.org" && check_password(u, "test_password")

        # interactive
        o = out()
        call_command("createsuperuser"; isatty = false, stdout = o)                                                # test_skip_if_not_in_TTY
        @test occursin("Superuser creation skipped due to not running in a TTY.", String(take!(o)))
        o, er = out(), out()
        call_command("createsuperuser"; stdin = "dab_alice2\nalice@example.com\n", getpass = ["password", "password"],
                     stdout = o, stderr = er)                                                                       # test_basic_usage (interactive)
        @test exists(filter(User; username = "dab_alice2", email = "alice@example.com")) && endswith(String(take!(o)), "Superuser created successfully.\n")
        o = out()
        call_command("createsuperuser"; stdin = "\n\n", getpass = ["password", "password"], system_user = "dab_alice", stdout = o)   # test_default_username
        @test startswith(String(take!(o)), "Username (leave blank to use 'dab_alice'): ") && exists(filter(User; username = "dab_alice", email = ""))
        o = out()
        call_command("createsuperuser"; stdin = "dab_bob\n\n", getpass = ["password", "password"], system_user = "dab_alice", stdout = o)   # GetDefaultUsername: test_existing
        @test startswith(String(take!(o)), "Username: ")
        call_command("createsuperuser"; stdin = "\n\n", getpass = ["password", "password"], system_user = "Dáb_Zöe")   # test_i18n
        @test exists(filter(User; username = "dab_zoe"))
        er = out()
        call_command("createsuperuser"; stdin = "\U1f920\ndab_valid\n\n", getpass = ["password", "password"], stderr = er)   # test_invalid_username
        @test String(take!(er)) == "Error: Enter a valid username. This value may contain only letters, numbers, and @/./+/-/_ characters.\n"
        er = out()
        call_command("createsuperuser"; stdin = "dab_su\ndab_janet2\n\n", getpass = ["password", "password"], stderr = er)   # test_existing_username
        @test String(take!(er)) == "Error: That username is already taken.\n" && exists(filter(User; username = "dab_janet2"))
        er = out()
        call_command("createsuperuser", "--username=dab_su"; stdin = "dab_janet3\n\n", getpass = ["password", "password"], stderr = er)   # ..._provided_via_option_and_interactive
        @test String(take!(er)) == "Error: That username is already taken.\n" && exists(filter(User; username = "dab_janet3"))
        er = out()
        call_command("createsuperuser"; stdin = "\ndab_blank\n\n", getpass = ["password", "password"], stderr = er)          # test_blank_username
        @test String(take!(er)) == "Error: This field cannot be blank.\n"
        er = out()
        call_command("createsuperuser"; stdin = "dab_em\nbad-email\ngood@example.com\n", getpass = ["password", "password"], stderr = er)   # (REQUIRED_FIELDS validated)
        @test String(take!(er)) == "Error: Enter a valid email address.\n" && get(User; username = "dab_em").email == "good@example.com"
        er = out()
        call_command("createsuperuser"; stdin = "dab_mm\n\n", getpass = ["password", "not password", "password", "password"], stderr = er)   # test_validation_mismatched_passwords
        @test String(take!(er)) == "Error: Your passwords didn't match.\n"
        er = out()
        call_command("createsuperuser"; stdin = "dab_bl\n\n", getpass = ["", "", "password", "password"], stderr = er)       # test_validation_blank_password_entered
        @test String(take!(er)) == "Error: Blank passwords aren't allowed.\n"
        override_settings(AUTH_PASSWORD_VALIDATORS = Any[Juango.NumericPasswordValidator()]) do
            er = out()
            call_command("createsuperuser"; stdin = "dab_pv\n\nn\n", getpass = ["1234567890", "1234567890", "password", "password"], stderr = er)   # test_password_validation
            @test String(take!(er)) == "This password is entirely numeric.\n" && check_password(get(User; username = "dab_pv"), "password")
            call_command("createsuperuser"; stdin = "dab_pvb\n\ny\n", getpass = ["1234567890", "1234567890"])               # test_password_validation_bypass
            @test check_password(get(User; username = "dab_pvb"), "1234567890")
        end
        withenv("JUANGO_SUPERUSER_PASSWORD" => "env_password") do                                                 # test_ignore_environment_variable_interactive
            call_command("createsuperuser"; stdin = "dab_ienv\n\n", getpass = ["cmd_password", "cmd_password"])
        end
        @test check_password(get(User; username = "dab_ienv"), "cmd_password")
        er = out()
        e = try call_command("createsuperuser"; stdin = "dab_ki\n\n", getpass = p -> throw(InterruptException()), stderr = er); nothing catch e; e end
        @test e isa CommandError && String(take!(er)) == "\nOperation cancelled.\n" && !exists(filter(User; username = "dab_ki"))   # test_keyboard_interrupt
        # not translated: the custom and swapped user models (REQUIRED_FIELDS with foreign keys and many-to-many,
        # USERNAME_FIELD email, IntegerUsernameUser; `required_fields` is the hook), --database, and the
        # non-Unicode terminals
    finally
        dab_cleanup()
    end
end

@testset "django auth: test_checks" begin
    m = Module(:DabChecks)
    Core.eval(m, :(using Juango))
    long_model = "Dab" * "x"^91                                   # (94 characters: its codenames would be too long)
    Base.include_string(m, """
        @model struct DabChecked
            Meta(app_label = "dabchecks", permissions = [("change_dabchecked", "Can edit permission (duplicate)")])
        end
        @model struct DabDuplicated
            Meta(app_label = "dabchecks", permissions = [("my_custom_permission", "Some permission"), ("other_one", "Some other permission"),
                                                         ("my_custom_permission", "Some permission with duplicate permission code")])
        end
        @model struct DabLongVerbose
            Meta(app_label = "dabchecks", verbose_name = "$("some ridiculously long verbose name that is out of control" ^ 5)")
        end
        @model struct DabLongVerboseNoPerms
            Meta(app_label = "dabchecks", verbose_name = "$("some ridiculously long verbose name that is out of control" ^ 5)", default_permissions = ())
        end
        @model struct DabLongPermName
            Meta(app_label = "dabchecks", permissions = [("dab_perm", "$("X" ^ 256)")])
        end
        @model struct DabLongCodename
            Meta(app_label = "dabchecks", permissions = [("$("x" ^ 101)", "Custom permission")])
        end
        @model struct $long_model
            Meta(app_label = "dabchecks")
        end
        @model struct DabEmailUser <: AbstractUser
            Meta(app_label = "dabchecks", table = "dab_email_user")
        end
        Juango.username_field(::Type{DabEmailUser}) = :email
        @model struct DabGoodEmailUser <: AbstractUser
            login_email = EmailField(unique = true)
            Meta(app_label = "dabchecks", table = "dab_good_email_user")
        end
        Juango.username_field(::Type{DabGoodEmailUser}) = :login_email
        """)
    T(n) = getfield(m, Symbol(n))
    issues(models...) = [(l, msg, id) for (l, msg, id, _) in Juango.auth_check_issues(collect(Any, models))]
    try
        @test issues(T(:DabChecked)) == [(:error, "The permission codenamed 'change_dabchecked' clashes with a builtin permission for model 'dabchecks.DabChecked'.", "auth.E005")]   # test_clashing_default_permissions
        @test issues(T(:DabDuplicated)) == [(:error, "The permission codenamed 'my_custom_permission' is duplicated for model 'dabchecks.DabDuplicated'.", "auth.E006")]   # test_non_clashing_custom_permissions
        @test issues(T(:DabLongVerbose)) == [(:error, "The verbose_name of model 'dabchecks.DabLongVerbose' must be at most 244 characters for its builtin permission names to be at most 255 characters.", "auth.E007")]   # test_verbose_name_max_length
        @test isempty(issues(T(:DabLongVerboseNoPerms)))                                                   # test_empty_default_permissions
        @test issues(T(:DabLongPermName)) == [(:error, "The permission named '$("X" ^ 256)' of model 'dabchecks.DabLongPermName' is longer than 255 characters.", "auth.E008")]   # test_custom_permission_name_max_length
        @test issues(T(:DabLongCodename)) == [(:error, "The permission codenamed '$("x" ^ 101)' of model 'dabchecks.DabLongCodename' is longer than 100 characters.", "auth.E012")]   # test_custom_permission_codename_max_length
        @test issues(T(long_model)) == [(:error, "The name of model 'dabchecks.$long_model' must be at most 93 characters for its builtin permission codenames to be at most 100 characters.", "auth.E011")]   # test_model_name_max_length
        @test isempty(Juango.auth_check_issues(filter(X -> parentmodule(X) !== m, Juango.all_models())))   # (Juango's own models and the tests' pass)
        # UserModelChecksTests
        override_settings(AUTH_USER_MODEL = T(:DabEmailUser)) do
            @test issues(T(:DabEmailUser)) == [(:error, "'DabEmailUser.email' must be unique because it is named as the 'USERNAME_FIELD'.", "auth.E003")]   # test_username_non_unique
            override_settings(AUTHENTICATION_BACKENDS = Any[ModelBackend(), DabRowlevelBackend()]) do
                @test issues(T(:DabEmailUser)) == [(:warning, "'DabEmailUser.email' is named as the 'USERNAME_FIELD', but it is not unique.", "auth.W004")]
            end
            Core.eval(m, :(Juango.required_fields(::Type{DabEmailUser}) = (:email, :first_name)))
            @test (:error, "The field named as the 'USERNAME_FIELD' for a custom user model must not be included in 'REQUIRED_FIELDS'.", "auth.E002") in
                  Base.invokelatest(issues, T(:DabEmailUser))   # test_username_not_in_required_fields
        end
        override_settings(AUTH_USER_MODEL = T(:DabGoodEmailUser)) do
            @test isempty(issues(T(:DabGoodEmailUser)))                                                     # test_required_fields_is_list (and a unique USERNAME_FIELD)
        end
        # not translated: is_anonymous and is_authenticated as methods (auth.C009, C010: Python), and the
        # UniqueConstraint variants of test_username_partially_unique (a conditional constraint isn't unique: auth.jl)
    finally
        foreach(Juango.unregister_model!, filter(X -> parentmodule(X) === m, Juango.all_models()))
    end
end
