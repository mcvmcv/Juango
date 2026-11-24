# Django's composite_pk tests, ported (#227): tests.py, test_create, test_get (more below).
# julia --project=test test/django_composite_pk.jl   (see setup.jl)
#
# Django's models name a key field `id`; Juango reserves `id` for the automatic key (#229), so it is `num` here, with
# db_column = "id" (Comment's "comment_id"). Left out: _is_pk_set, the CompositePrimaryKey field object
# (_meta.get_field("pk")), str(qs.query), hashing errors (Julia's hash can't refuse) and mocked max_query_params.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
using Dates, UUIDs

@model struct CpkTenant
    name = CharField(max_length = 10, default = "", blank = true)
    Meta(table = "composite_pk_tenant", app_label = "composite_pk")
end
@model struct CpkToken
    tenant = ForeignKey(CpkTenant; on_delete = :CASCADE, related_name = :tokens)
    num = SmallIntegerField(db_column = "id")
    secret = CharField(max_length = 10, default = "", blank = true)
    Meta(table = "composite_pk_token", app_label = "composite_pk", pk = CompositePrimaryKey(:tenant, :num))
end
@model struct CpkUser
    tenant = ForeignKey(CpkTenant; on_delete = :CASCADE)
    email = EmailField(unique = true)
    num = SmallIntegerField(unique = true, db_column = "id")
    Meta(table = "composite_pk_user", app_label = "composite_pk", pk = CompositePrimaryKey(:tenant, :num))
end
@model struct CpkComment
    tenant = ForeignKey(CpkTenant; on_delete = :CASCADE, related_name = :comments)
    num = SmallIntegerField(unique = true, db_column = "comment_id")
    user_id = SmallIntegerField(null = true)
    user = ForeignObject(CpkUser; on_delete = :CASCADE, from_fields = [:tenant_id, :user_id], to_fields = [:tenant_id, :num],
                         related_name = :comments)
    text = TextField(default = "", blank = true)
    integer = IntegerField(default = 0)
    Meta(table = "composite_pk_comment", app_label = "composite_pk", pk = CompositePrimaryKey(:tenant, :num))
end
@model struct CpkPost
    tenant = ForeignKey(CpkTenant; on_delete = :CASCADE, default = 1)
    num = UUIDField(default = uuid4, db_column = "id")
    Meta(table = "composite_pk_post", app_label = "composite_pk", pk = CompositePrimaryKey(:tenant, :num))
end
@model struct CpkPostDbDefault
    tenant = ForeignKey(CpkTenant; on_delete = :CASCADE, default = 1)
    num = IntegerField(db_default = 1, db_column = "id")
    Meta(table = "composite_pk_postdbdefault", app_label = "composite_pk", pk = CompositePrimaryKey(:tenant, :num))
end
@model struct CpkTimeStamped
    num = SmallIntegerField(unique = true, db_column = "id")
    created = DateTimeField(auto_now_add = true)
    text = TextField(default = "", blank = true)
    Meta(table = "composite_pk_timestamped", app_label = "composite_pk", pk = CompositePrimaryKey(:num, :created))
end
const CPK_MODELS = Any[CpkTenant, CpkToken, CpkUser, CpkComment, CpkPost, CpkPostDbDefault, CpkTimeStamped]
redirect_stdout(devnull) do
    Juango.sync_models!(CPK_MODELS); append!(PORT_MODELS, CPK_MODELS)
end
cpk_err(f) = try; f(); nothing; catch e; e; end
cpk_msg(f) = (e = cpk_err(f); e === nothing ? nothing : sprint(showerror, e))

@testset "django composite_pk: CompositePKTests" begin
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    tenant = create(T)
    user = create(U; tenant = tenant, num = 1, email = "user0001@example.com")
    comment = create(C; tenant = tenant, num = 1, user = user)
    # test_pk_updated_if_field_updated
    u = get(U; pk = user.pk)
    @test u.pk == (tenant.id, user.num)
    u.tenant_id = 9831
    @test u.pk == (9831, user.num)
    u.num = 4321
    @test u.pk == (9831, 4321)
    u.pk = (9132, 3521)
    @test u.tenant_id == 9132 && u.num == 3521
    u.num = nothing
    @test u.pk == (9132, nothing) && u.tenant_id == 9132 && u.num === nothing
    # test_pk_not_set_db_default
    post = CpkPostDbDefault(tenant = tenant)
    @test post.tenant_id == tenant.pk && post.num !== nothing
    # test_eq
    @test U(pk = (1, 2)) == U(pk = (1, 2)) && U(tenant_id = 2, num = 3) == U(tenant_id = 2, num = 3)
    @test U(pk = (1, 2)) != U(pk = (1, 3))
    unset = U()
    @test unset == unset && U() != unset
    @test U(tenant_id = 1) != U(tenant_id = 1) && U(num = 1) != U(num = 1) && U(tenant_id = 1) != U(pk = (1, 2))
    # test_hash
    @test hash(U(pk = (1, 2))) == hash(U(pk = (1, 2))) && hash(U(tenant_id = 2, num = 3)) == hash(U(pk = (2, 3)))
    # test_pk_must_be_list_or_tuple, test_pk_must_have_2_elements
    u = get(U; pk = user.pk)
    for pk in ("foo", 1000, 3.14, true, false)
        @test cpk_msg(() -> (u.pk = pk)) == "ArgumentError: 'pk' must be a list or a tuple."
    end
    for pk in ((), [], (1000,), [1000], (1, 2, 3), [1, 2, 3])
        @test cpk_msg(() -> (u.pk = pk)) == "ArgumentError: 'pk' must have 2 elements."
    end
    # test_error_on_user_pk_conflict, test_error_on_comment_pk_conflict
    @test_throws Juango.IntegrityError atomic(() -> create(U; tenant = tenant, num = user.num, email = "other@example.com"))
    @test_throws Juango.IntegrityError atomic(() -> create(C; tenant = tenant, num = comment.num, user_id = 1))
    # test_get_primary_key_columns
    @test Juango.introspect_primary_key_columns("composite_pk_user") == ["tenant_id", "id"]
    @test Juango.introspect_primary_key_columns("composite_pk_comment") == ["tenant_id", "comment_id"]
    # test_in_bulk and its values forms
    @test in_bulk(objects(C)) == Dict(comment.pk => comment)
    @test in_bulk(objects(C), [comment.pk]) == Dict(comment.pk => comment)
    @test in_bulk(values(objects(C)), [comment.pk]) ==
          Dict(comment.pk => Dict(:tenant_id => comment.tenant_id, :num => comment.num, :user_id => comment.user_id,
                                  :text => comment.text, :integer => comment.integer))
    @test in_bulk(values(objects(C), :text), [comment.pk]) == Dict(comment.pk => Dict(:text => comment.text))
    @test in_bulk(values(objects(C), :pk, :text), [comment.pk]) == Dict(comment.pk => Dict(:pk => comment.pk, :text => comment.text))
    @test in_bulk(values_list(objects(C), :text), [comment.pk]) == Dict(comment.pk => (comment.text,))
    @test in_bulk(values_list(objects(C), :pk, :text), [comment.pk]) == Dict(comment.pk => (comment.pk, comment.text))
    @test in_bulk(values_list(objects(C), :tenant, :num), [comment.pk]) == Dict(comment.pk => (comment.tenant_id, comment.num))
    @test in_bulk(values_list(objects(C), :text; flat = true), [comment.pk]) == Dict(comment.pk => comment.text)
    @test in_bulk(values_list(objects(C), :pk; flat = true), [comment.pk]) == Dict(comment.pk => comment.pk)
    @test in_bulk(values_list(objects(C), :tenant; flat = true), [comment.pk]) == Dict(comment.pk => tenant.id)
    # test_in_bulk_batching (without the mocked parameter limit)
    delete!(objects(C))
    bulk_create([C(num = i, tenant = tenant, user = user) for i in 1:10])
    ids = collect(values_list(objects(C), :pk; flat = true))
    @test Set(keys(in_bulk(objects(C), ids))) == Set(ids) && length(ids) == 10
    delete!(objects(C))
    comment = create(C; tenant = tenant, num = 1, user = user)
    # test_iterator
    @test collect(iterator(objects(C))) == [comment]
    # test_query
    @test collect(values_list(order_by(objects(U), :pk), :pk; flat = true)) == [user.pk]
    # test_raw, test_raw_missing_PK_fields
    users = raw(U, "SELECT * FROM composite_pk_user")
    @test length(users) == 1 && users[1].tenant_id == user.tenant_id && users[1].num == user.num && users[1].email == user.email
    @test occursin("Raw query must include the primary key", cpk_msg(() -> collect(raw(U, "SELECT tenant_id, email FROM composite_pk_user"))))
    # test_only
    us = collect(only(objects(U), :pk))
    @test us == [user]
    @test us[1].pk == (user.tenant_id, user.num) && us[1].email == user.email
    # test_select_related: through the ForeignObject to the composite key
    create(C; tenant = tenant, num = 2)
    cs = collect(order_by(select_related(objects(C), :user), :pk))
    @test length(cs) == 2 && cs[1].user == user && cs[2].user === nothing
    # test_model_forms
    F = modelform_factory(C; fields = "__all__")
    @test [x.name for x in F().fields] == [:tenant, :num, :user_id, :text, :integer]
    @test occursin("Unknown field(s) (pk) specified for CpkComment", cpk_msg(() -> modelform_factory(C; fields = ["pk"])))
  end
end

@testset "django composite_pk: CompositePKFixturesTests" begin
  port_block() do
    T, U = CpkTenant, CpkUser
    override_settings(FIXTURE_DIRS = [joinpath(@__DIR__, "fixtures_composite_pk")]) do
        loaddata("tenant")
    end
    # test_objects
    t1, t2, t3 = collect(order_by(objects(T), :pk))
    @test (t1.id, t1.name, t2.id, t2.name, t3.id, t3.name) == (1, "Tenant 1", 2, "Tenant 2", 3, "Tenant 3")
    us = collect(order_by(objects(U), :pk))
    @test [(u.num, u.tenant_id, u.pk, u.email) for u in us] ==
          [(1, 1, (1, 1), "user0001@example.com"), (2, 1, (1, 2), "user0002@example.com"),
           (3, 2, (2, 3), "user0003@example.com"), (4, 2, (2, 4), "user0004@example.com")]
    p1, p2 = collect(order_by(objects(CpkPost), :pk))
    @test p1.num == UUID("11111111-1111-1111-1111-111111111111") && p1.tenant_id == 2 && p1.pk == (2, p1.num)
    @test p2.num == UUID("ffffffff-ffff-ffff-ffff-ffffffffffff") && p2.tenant_id == 2 && p2.pk == (2, p2.num)
    # serializing: pk as a list
    function roundtrip(fmt, users, s)
        d = first(deserialize(fmt, s))
        @test d.object.email == users[1].email && d.object.num == users[1].num && d.object.tenant == users[1].tenant && d.object.pk == users[1].pk
    end
    users = collect(filter(U; pk = (1, 1)))
    s = serialize(:json, users)
    @test JSON.parse(s) == [Dict("model" => "composite_pk.cpkuser", "pk" => [1, 1],
                                 "fields" => Dict("email" => "user0001@example.com", "num" => 1, "tenant" => 1))]
    roundtrip(:json, users, s)
    users = collect(filter(U; pk = (1, 2)))
    s = serialize(:jsonl, users)
    @test JSON.parse(s) == Dict("model" => "composite_pk.cpkuser", "pk" => [1, 2],
                                "fields" => Dict("email" => "user0002@example.com", "num" => 2, "tenant" => 1))
    roundtrip(:jsonl, users, s)
    users = collect(filter(U; pk = (2, 3)))
    s = serialize(:yaml, users)
    @test occursin("pk:", s)
    roundtrip(:yaml, users, s)
    users = collect(filter(U; pk = (1, 1)))
    s = serialize(:xml, users)
    @test occursin("<object model=\"composite_pk.cpkuser\" pk='[\"1\", \"1\"]'>", s)
    roundtrip(:xml, users, s)
    s = serialize(:xml, [U()])                                      # test_serialize_unsaved_user_xml_omits_pk
    @test occursin("<object model=\"composite_pk.cpkuser\">", s) && !occursin(" pk=", s)
    posts = collect(filter(CpkPost; pk = (2, "11111111-1111-1111-1111-111111111111")))
    @test JSON.parse(serialize(:json, posts)) == [Dict("model" => "composite_pk.cpkpost", "pk" => [2, "11111111-1111-1111-1111-111111111111"],
                                                      "fields" => Dict("num" => "11111111-1111-1111-1111-111111111111", "tenant" => 2))]
    @test JSON.parse(serialize(:json, collect(objects(CpkTimeStamped)))) ==
          [Dict("model" => "composite_pk.cpktimestamped", "pk" => [1, "2022-01-12T05:55:14.956"],
                "fields" => Dict("num" => 1, "created" => "2022-01-12T05:55:14.956", "text" => ""))]
    # test_invalid_pk_extra_field
    bad = "[{\"fields\": {\"email\": \"user0001@example.com\", \"num\": 1, \"tenant\": 1}, \"pk\": [1, 1, \"extra\"], \"model\": \"composite_pk.cpkuser\"}]"
    @test_throws Juango.DeserializationError deserialize(:json, bad)
  end
end

@testset "django composite_pk: CompositePKCreateTests" begin
  port_block() do
    T, U = CpkTenant, CpkUser
    tenant = create(T; id = 1)
    create(U; tenant = tenant, num = 1, email = "user0001@example.com")
    # test_create_user
    for fields in ((tenant = tenant, num = 2412, email = "user2412@example.com"),
                   (tenant_id = tenant.id, num = 5316, email = "user5316@example.com"),
                   (pk = (tenant.id, 7424), email = "user7424@example.com"))
        n = count(objects(U))
        user = U(; fields...)
        obj = create(U; fields...)
        @test obj.tenant_id == tenant.id && obj.num == user.num && obj.pk == (tenant.id, user.num) && obj.email == user.email
        @test count(objects(U)) == n + 1
    end
    # test_save_user
    for fields in ((tenant = tenant, num = 9241, email = "user9241@example.com"),
                   (tenant_id = tenant.id, num = 5132, email = "user5132@example.com"),
                   (pk = (tenant.id, 3014), email = "user3014@example.com"))
        n = count(objects(U))
        user = U(; fields...)
        @test user.num !== nothing && user.email !== nothing
        save!(user)
        @test user.tenant_id == tenant.id && user.tenant == tenant && user.pk == (tenant.id, user.num)
        @test user.email == fields.email == "user$(user.num)@example.com" && count(objects(U)) == n + 1
    end
    # test_bulk_create_users
    o1, o2, o3 = bulk_create([U(tenant = tenant, num = 8291, email = "user8291@example.com"),
                                 U(tenant_id = tenant.id, num = 4021, email = "user4021@example.com"),
                                 U(pk = (tenant.id, 8214), email = "user8214@example.com")])
    @test (o1.tenant_id, o1.num, o1.pk, o1.email) == (tenant.id, 8291, (tenant.id, 8291), "user8291@example.com")
    @test (o2.tenant_id, o2.num, o2.pk, o2.email) == (tenant.id, 4021, (tenant.id, 4021), "user4021@example.com")
    @test (o3.tenant_id, o3.num, o3.pk, o3.email) == (tenant.id, 8214, (tenant.id, 8214), "user8214@example.com")
    # test_bulk_create_user_with_pk_field_in_update_fields
    @test occursin("bulk_create() cannot be used with primary keys in update_fields.",
                   cpk_msg(() -> bulk_create([U(tenant = tenant, num = 8291, email = "user8291@example.com")];
                                             update_conflicts = true, update_fields = [:tenant_id], unique_fields = [:num, :tenant_id])))
    # test_get_or_create_user, test_update_or_create_user
    for (f, cases) in ((get_or_create, ((pk = (tenant.id, 8314), email = "user8314@example.com"),
                                        (tenant = tenant, num = 3142, email = "user3142@example.com"),
                                        (tenant_id = tenant.id, num = 4218, email = "user4218@example.com"))),
                       (update_or_create, ((pk = (tenant.id, 2931), email = "user2931@example.com"),
                                           (tenant = tenant, num = 6428, email = "user6428@example.com"),
                                           (tenant_id = tenant.id, num = 5278, email = "user5278@example.com"))))
        for c in cases
            n = count(objects(U))
            kw = Base.structdiff(c, NamedTuple{(:email,)})
            user, created = f(U; kw..., defaults = Dict(:email => c.email))
            @test created && user.num !== nothing && user.pk == (tenant.id, user.num) && user.tenant_id == tenant.id
            @test user.email == c.email == "user$(user.num)@example.com" && count(objects(U)) == n + 1
        end
    end
    # test_save_default_pk_not_set, test_save_default_pk_set
    save!(CpkPost())
    post = create(CpkPost)
    @test_throws Juango.IntegrityError atomic(() -> save!(CpkPost(tenant_id = post.tenant_id, num = post.num)))
  end
end

@testset "django composite_pk: CompositePKGetTests" begin
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    t1, t2 = create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    create(U; tenant = t1, num = 2, email = "user0002@example.com")
    create(U; tenant = t2, num = 3, email = "user0003@example.com")
    c1 = create(C; num = 1, user = u1)
    # test_get_user
    for kw in ((pk = u1.pk,), (pk = (t1.id, u1.num),), (num = u1.num,))
        @test get(U; kw...) == u1
    end
    # test_get_comment
    for kw in ((pk = c1.pk,), (pk = (t1.id, c1.num),), (num = c1.num,), (user = u1,), (user_id = u1.num,), (user__num = u1.num,),
               (user__pk = u1.pk,), (tenant = t1,), (tenant_id = t1.id,), (tenant__id = t1.id,), (tenant__pk = t1.pk,))
        @test get(C; kw...) == c1
    end
    # test_get_or_create_user: found
    for c in ((pk = u1.pk,), (pk = (t1.id, u1.num),), (tenant = t1, num = u1.num), (tenant_id = t1.id, num = u1.num))
        n = count(objects(U))
        user, created = get_or_create(U; c..., defaults = Dict(:email => "user9201@example.com"))
        @test !created && user.num == u1.num && user.pk == (t1.id, u1.num) && user.tenant_id == t1.id && user.email == u1.email
        @test count(objects(U)) == n
    end
    # test_lookup_errors
    tup(l) = "'$l' lookup of 'pk' must be a tuple or a list"
    two(l) = "'$l' lookup of 'pk' must have 2 elements"
    for (kw, msg) in (((pk = 1,), tup("exact")), ((pk = (1, 2, 3),), two("exact")), ((pk__exact = 1,), tup("exact")),
                      ((pk__exact = (1, 2, 3),), two("exact")), ((pk__in = 1,), tup("in")),
                      ((pk__in = (1, 2, 3),), "'in' lookup of 'pk' must be a collection of tuples or lists"),
                      ((pk__in = ((1, 2, 3),),), "'in' lookup of 'pk' must have 2 elements each"),
                      ((pk__gt = 1,), tup("gt")), ((pk__gt = (1, 2, 3),), two("gt")), ((pk__gte = 1,), tup("gte")),
                      ((pk__gte = (1, 2, 3),), two("gte")), ((pk__lt = 1,), tup("lt")), ((pk__lt = (1, 2, 3),), two("lt")),
                      ((pk__lte = 1,), tup("lte")), ((pk__lte = (1, 2, 3),), two("lte")))
        @test occursin(msg, something(cpk_msg(() -> get(C; kw...)), "no error"))
    end
    # test_get_user_by_comments
    @test get(U; comments = c1) == u1
    # test_get_previous_by_field
    s1 = create(CpkTimeStamped; num = 1)
    s2 = CpkTimeStamped(num = 2)
    @test occursin("get_next/get_previous cannot be used on unsaved objects.", something(cpk_msg(() -> get_previous_by(s2, :created)), "no error"))
    save!(s2)
    @test get_previous_by(s2, :created) == s1
  end
end

@testset "django composite_pk: CompositePKDeleteTests" begin
    T, U, C = CpkTenant, CpkUser, CpkComment
    function setup()
        t1, t2 = create(T), create(T)
        u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
        u2 = create(U; tenant = t2, num = 2, email = "user0002@example.com")
        c1, c2, c3 = create(C; num = 1, user = u1), create(C; num = 2, user = u2), create(C; num = 3, user = u2)
        (; t1, t2, u1, u2, c1, c2, c3)
    end
    has(M, o) = exists(filter(M; pk = o.pk))
    port_block() do                                                   # test_delete_tenant_by_pk: cascades through both keys
        s = setup()
        @test_broken delete!(filter(T; pk = s.t1.pk)) == 3          # (Juango counts the model's own rows: #285)
        @test !has(T, s.t1) && has(T, s.t2) && !has(U, s.u1) && has(U, s.u2) && !has(C, s.c1) && has(C, s.c2) && has(C, s.c3)
    end
    port_block() do                                                   # test_delete_user_by_pk: and the ForeignObject's comments
        s = setup()
        @test_broken delete!(filter(U; pk = s.u1.pk)) == 2          # (#285)
        @test !has(U, s.u1) && has(U, s.u2) && !has(C, s.c1) && has(C, s.c2) && has(C, s.c3)
    end
    port_block() do                                                   # test_delete_comments_by_user
        s = setup()
        @test delete!(filter(C; user = s.u2)) == 2
        @test has(C, s.c1) && !has(C, s.c2) && !has(C, s.c3)
    end
    # test_delete_without_pk
    msg = "CpkComment object can't be deleted because its pk attribute is set to None."
    for c in (C(), C(tenant_id = 1), C(num = 1))
        @test occursin(msg, something(cpk_msg(() -> delete!(c)), "no error"))
    end
end

@testset "django composite_pk: CompositePKUpdateTests" begin
  port_block() do
    T, U, C, K = CpkTenant, CpkUser, CpkComment, CpkToken
    t1, t2 = create(T; name = "A"), create(T; name = "B")
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    create(U; tenant = t2, num = 3, email = "user0003@example.com")
    c1, c2, c3 = create(C; num = 1, user = u1), create(C; num = 2, user = u1), create(C; num = 3, user = u2)
    k1, k2, k3, k4 = create(K; num = 1, tenant = t1), create(K; num = 2, tenant = t2), create(K; num = 3, tenant = t1), create(K; num = 4, tenant = t2)
    # test_update_user
    @test update!(filter(U; pk = u1.pk); email = "user9315@example.com") == 1
    @test get(U; pk = u1.pk).email == "user9315@example.com"
    # test_save_user: one UPDATE, the key's columns named once (in its WHERE)
    n = count(objects(U))
    user = get(U; pk = u1.pk)
    user.email = "user9314@example.com"
    reset_queries!()
    override_settings(DEBUG = true) do
        Juango.reset_queries!()
        save!(user)
        qs = Juango.connection_queries()
        @test length(qs) == 1
        sqltext = qs[1].sql
        @test count("tenant_id", sqltext) == 1 && length(collect(eachmatch(r"\"id\"|`id`", sqltext))) == 1
    end
    refresh!(user)
    @test user.email == "user9314@example.com" && get(U; pk = u1.pk).email == "user9314@example.com" && count(objects(U)) == n
    # test_update_fields_deferred
    c = get(defer(objects(C), :text, :user_id); pk = c1.pk)
    c.text = "Hello"
    override_settings(DEBUG = true) do
        Juango.reset_queries!()
        save!(c)
        qs = Juango.connection_queries()
        @test length(qs) == 1 && count("tenant_id", qs[1].sql) == 1 && count("comment_id", qs[1].sql) == 1
    end
    @test get(C; pk = c1.pk).text == "Hello"
    # test_update_fields_pk_field
    @test occursin("primary keys", something(cpk_msg(() -> save!(u1; update_fields = [:num])), "no error"))
    # test_bulk_update_comments
    cs = [get(C; pk = x.pk) for x in (c1, c2, c3)]
    for (x, t) in zip(cs, ("foo", "bar", "baz")); x.text = t; end
    @test bulk_update(cs, [:text]) == 3
    @test [get(C; pk = x.pk).text for x in (c1, c2, c3)] == ["foo", "bar", "baz"]
    # test_bulk_update_primary_key_fields
    @test occursin("bulk_update() cannot be used with primary key fields.", something(cpk_msg(() -> bulk_update([c1, c2], [:num])), "no error"))
    # test_update_or_create_user: found and updated
    for (c, email) in (((pk = u1.pk,), "user3914@example.com"), ((pk = (t1.id, u1.num),), "user9375@example.com"),
                       ((tenant = t1, num = u1.num), "user3517@example.com"), ((tenant_id = t1.id, num = u1.num), "user8391@example.com"))
        n = count(objects(U))
        user, created = update_or_create(U; c..., defaults = Dict(:email => email))
        @test !created && user.num == u1.num && user.pk == (t1.id, u1.num) && user.tenant_id == t1.id && user.email == email
        @test count(objects(U)) == n
    end
    # test_update_or_create_with_pre_save_pk_field
    ts = create(CpkTimeStamped; num = 1)
    @test count(objects(CpkTimeStamped)) == 1
    ts, created = update_or_create(CpkTimeStamped; pk = ts.pk, defaults = Dict(:text => "new text"))
    @test !created && count(objects(CpkTimeStamped)) == 1 && ts.text == "new text"
    # test_update_comment_by_user_email, test_update_token_by_tenant_name
    @test update!(filter(C; user__email = get(U; pk = u1.pk).email); text = "foo") == 2
    @test get(C; pk = c1.pk).text == "foo" && get(C; pk = c2.pk).text == "foo"
    @test update!(filter(K; tenant__name = "A"); secret = "bar") == 2
    @test get(K; pk = k1.pk).secret == "bar" && get(K; pk = k3.pk).secret == "bar"
    # test_cant_update_relation
    for v in (u1, U())
        @test occursin("only concrete fields are permitted", something(cpk_msg(() -> update!(objects(C); user = v)), "no error"))
    end
    # test_cant_update_pk_field
    @test occursin("Composite primary key fields must be updated individually.",
                   something(cpk_msg(() -> update!(filter(C; user__email = "x"); pk = (1, 10))), "no error"))
    # test_update_value_not_composite
    @test occursin("Composite primary keys expressions are not allowed in this query (text=F('pk')).",
                   something(cpk_msg(() -> update!(objects(C); text = F(:pk))), "no error"))
  end
end

@testset "django composite_pk: CompositePKValuesTests, CompositePKOrderByTests" begin
  port_block() do
    T, U, P, C = CpkTenant, CpkUser, CpkPost, CpkComment
    t1, t2 = create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    u3 = create(U; tenant = t2, num = 3, email = "user0003@example.com")
    ids = (UUID("77777777-7777-7777-7777-777777777777"), UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"), UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    create(P; tenant = t1, num = ids[1]); create(P; tenant = t1, num = ids[2]); create(P; tenant = t2, num = ids[3])
    us = (u1, u2, u3)
    vl(M, fs...; kw...) = collect(order_by(values_list(objects(M), fs...; kw...), :pk))
    vs(M, fs...) = collect(order_by(values(objects(M), fs...), :pk))
    # test_values_list
    @test vl(U, :pk) == [(u.pk,) for u in us]
    @test vl(U, :pk, :email) == [(u.pk, u.email) for u in us]
    @test vl(U, :pk, :num) == [(u.pk, u.num) for u in us]
    @test vl(U, :pk, :tenant_id, :num) == [(u.pk, u.tenant_id, u.num) for u in us]
    @test vl(U, :pk; flat = true) == [u.pk for u in us]
    pks = [(t1.id, ids[1]), (t1.id, ids[2]), (t2.id, ids[3])]
    @test vl(P, :pk; flat = true) == pks
    @test vl(P, :pk) == [(k,) for k in pks]
    @test vl(P, :pk, :num) == [(k, k[2]) for k in pks]
    @test vl(P, :num, :pk) == [(k[2], k) for k in pks]
    @test [r.pk for r in vl(U, :pk; named = true)] == [u.pk for u in us]
    @test vl(U, :pk, :pk) == [(u.pk, u.pk) for u in us]
    @test vl(U, :pk, :num, :pk, :num) == [(u.pk, u.num, u.pk, u.num) for u in us]
    # test_values
    @test vs(U, :pk) == [Dict(:pk => u.pk) for u in us]
    @test vs(U, :pk, :email) == [Dict(:pk => u.pk, :email => u.email) for u in us]
    @test vs(U, :pk, :num) == [Dict(:pk => u.pk, :num => u.num) for u in us]
    @test vs(U, :pk, :tenant_id, :num) == [Dict(:pk => u.pk, :tenant_id => u.tenant_id, :num => u.num) for u in us]
    @test vs(U, :pk, :pk) == [Dict(:pk => u.pk) for u in us]
    @test vs(U, :pk, :num, :pk, :num) == [Dict(:pk => u.pk, :num => u.num) for u in us]
    # test_foreign_object_values: a ForeignObject's value is the tuple of its columns
    create(C; num = 1, user = u1, integer = 42)
    for qs in (objects(C), exclude(objects(C); user__email__endswith = "net"))
        v = collect(values(qs, :user, :integer))
        @test v[1][:user] == (u1.tenant_id, u1.num) && v[1][:integer] == 42
    end
  end
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    t1, t2 = create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    u3 = create(U; tenant = t2, num = 3, email = "user0003@example.com")
    c1, c2, c3 = create(C; num = 1, user = u1), create(C; num = 2, user = u1), create(C; num = 3, user = u2)
    c4, c5 = create(C; num = 4, user = u3), create(C; num = 5, user = u1)
    # test_order_comments_by_pk_asc / _desc / _expr
    @test collect(order_by(objects(C), :pk)) == [c1, c2, c3, c5, c4]
    @test collect(order_by(objects(C), "-pk")) == [c4, c5, c3, c2, c1]
    @test collect(order_by(objects(C), F(:pk))) == [c1, c2, c3, c5, c4]
    @test collect(order_by(objects(C), Desc(F(:pk)))) == [c4, c5, c3, c2, c1]
    @test collect(order_by(objects(C), Desc(F(:pk); nulls_last = true))) == [c4, c5, c3, c2, c1]
  end
end

@testset "django composite_pk: CompositePKAggregateTests" begin
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    t1, t2 = create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    u3 = create(U; tenant = t2, num = 3, email = "user0003@example.com")
    c1 = create(C; num = 1, user = u2, text = "foo")
    for (i, u, t) in ((2, u1, "bar"), (3, u1, "foobar"), (4, u3, "foobarbaz"), (5, u3, "barbaz"), (6, u3, "baz"))
        create(C; num = i, user = u, text = t)
    end
    us = (u1, u2, u3)
    # test_users_annotated_with_comments_id_count, ..._aliased_..., ..._comments_count
    r = collect(order_by(annotate(objects(U), Count(:comments__num)), :pk))
    @test r == collect(us) && [x.comments__num__count for x in r] == [2, 1, 3]
    r = collect(order_by(annotate(objects(U); comments_count = Count(:comments__num)), :pk))
    @test [x.comments_count for x in r] == [2, 1, 3]
    r = collect(order_by(annotate(objects(U), Count(:comments)), :pk))
    @test r == collect(us) && [x.comments__count for x in r] == [2, 1, 3]
    # test_users_annotated_with_comments_count_filter
    r = collect(order_by(annotate(objects(U); comments__count = Count(:comments; filter = Q(pk__in = [u1.pk, u2.pk]))), :pk))
    @test [x.comments__count for x in r] == [2, 1, 0]
    # test_count_distinct_not_supported
    @test occursin("COUNT(DISTINCT) doesn't support composite primary keys",
                   something(cpk_msg(() -> collect(annotate(objects(U); comments__count = Count(:comments; distinct = true)))), "no error"))
    # test_user_values_annotated_with_comments_id_count, ..._filtered_...
    @test collect(order_by(annotate(values(objects(U), :pk), Count(:comments__num)), :pk)) ==
          [Dict(:pk => u.pk, :comments__num__count => n) for (u, n) in zip(us, (2, 1, 3))]
    @test collect(order_by(annotate(values(objects(U), :pk); comments_count = Count(:comments__num; filter = Q(comments__text__icontains = "foo"))), :pk)) ==
          [Dict(:pk => u.pk, :comments_count => 1) for u in us]
    # test_filter_and_count_users_by_comments_fields
    qs = order_by(filter(U; comments__num__gt = 2), :pk)
    @test count(qs) == 4 && collect(qs) == [u1, u3, u3, u3]
    qs = order_by(filter(U; comments__text__icontains = "foo"), :pk)
    @test count(qs) == 3 && collect(qs) == [u1, u2, u3]
    qs = order_by(filter(U; comments__text__icontains = "baz"), :pk)
    @test count(qs) == 3 && collect(qs) == [u3, u3, u3]
    # test_order_by_comments_id_count
    @test collect(order_by(annotate(objects(U); comments_count = Count(:comments__num)), "-comments_count")) == [u3, u1, u2]
    # test_max_pk
    @test occursin("Max expression does not support composite primary keys.", something(cpk_msg(() -> aggregate(objects(C), Max(:pk))), "no error"))
    # test_first_from_unordered_queryset_aggregation_pk_selected / _separately / _incomplete
    @test first(annotate(values(objects(C), :pk); max = Max(:num))) == Dict(:pk => (c1.tenant_id, 1), :max => 1)
    @test first(annotate(values(objects(C), :tenant, :num); max = Max(:num))) == Dict(:tenant => c1.tenant_id, :num => 1, :max => 1)
    @test occursin("Cannot use QuerySet.first() on an unordered queryset performing aggregation. Add an ordering with order_by().",
                   something(cpk_msg(() -> first(annotate(values(objects(C), :tenant); max = Max(:num)))), "no error"))
  end
end

@testset "django composite_pk: CompositePKFilterTests" begin
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    t1, t2, t3 = create(T), create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    u3 = create(U; tenant = t2, num = 3, email = "user0003@example.com")
    u4 = create(U; tenant = t3, num = 4, email = "user0004@example.com")
    c11, c12, c13 = create(C; num = 1, user = u1), create(C; num = 2, user = u1), create(C; num = 3, user = u2)
    c24, c15 = create(C; num = 4, user = u3), create(C; num = 5, user = u1)
    cs(qs) = collect(order_by(qs, :pk))
    # test_filter_and_count_user_by_pk
    for (pk, n) in ((u1.pk, 1), (u2.pk, 1), (u3.pk, 1), ((t1.id, u1.num), 1), ((t1.id, u2.num), 1), ((t2.id, u3.num), 1),
                    ((t1.id, u3.num), 0), ((t2.id, u1.num), 0), ((t2.id, u2.num), 0))
        @test count(filter(U; pk = pk)) == n
    end
    # test_rhs_pk, test_rhs_combinable
    @test occursin("CompositePrimaryKey cannot be used as a lookup value.", something(cpk_msg(() -> count(filter(C; text__gt = F(:pk)))), "no error"))
    # test_filter_comments_by_pk_gt / gte / lt / lte: tuple comparison
    for (o, gt) in ((c11, [c12, c13, c15, c24]), (c12, [c13, c15, c24]), (c13, [c15, c24]), (c15, [c24]), (c24, []))
        @test cs(filter(C; pk__gt = o.pk)) == gt
        @test cs(filter(C; pk__gte = o.pk)) == vcat([o], gt)
    end
    for (o, lt) in ((c24, [c11, c12, c13, c15]), (c15, [c11, c12, c13]), (c13, [c11, c12]), (c12, [c11]), (c11, []))
        @test cs(filter(C; pk__lt = o.pk)) == lt
        @test cs(filter(C; pk__lte = o.pk)) == vcat(lt, [o])
    end
    # test_filter_comments_by_pk_in
    for objs in ([], [c11], [c11, c24])
        @test cs(filter(C; pk__in = [o.pk for o in objs])) == objs
    end
    # test_filter_comments_by_pk_in_subquery
    @test collect(filter(C; pk__in = filter(C; pk = c11.pk))) == [c11]
    @test collect(filter(C; pk__in = values(filter(C; pk = c11.pk), :tenant_id, :num))) == [c11]
    c12.integer = c11.num; save!(c12)
    @test collect(filter(C; pk__in = values(objects(C), :tenant_id, :integer))) == [c11]
    # test_filter_by_pk_in_subquery_invalid_selected_columns
    @test occursin("The QuerySet value for the 'in' lookup must have 2 selected fields (received 3)",
                   something(cpk_msg(() -> collect(filter(C; pk__in = values(objects(C), :pk, :text)))), "no error"))
    # test_filter_by_pk_in_none
    @test isempty(collect(filter(C; pk__in = [(nothing, 1), (1, nothing)])))
    # by user, ordered, excluded, contains
    @test cs(filter(C; user = u1)) == [c11, c12, c15]
    @test collect(order_by(filter(C; user = u1), "-pk")) == [c15, c12, c11]
    @test cs(exclude(filter(C; user = u1); pk = c11.pk)) == [c12, c15]
    @test contains(filter(C; user = u1), c11)
    # test_filter_users_by_comments_in / lt / lte / gt / gte / exact (the reverse ForeignObject)
    for (comments, users) in (([], []), ([c11], [u1]), ([c11, c12], [u1, u1]), ([c11, c12, c13], [u1, u1, u2]),
                              ([c11, c12, c13, c24], [u1, u1, u2, u3]), ([c11, c12, c13, c24, c15], [u1, u1, u1, u2, u3]))
        @test cs(filter(U; comments__in = comments)) == users
    end
    for (c, lt, lte) in ((c11, [], [u1]), (c12, [u1], [u1, u1]), (c13, [u1, u1], [u1, u1, u2]), (c15, [u1, u1, u2], [u1, u1, u1, u2]),
                         (c24, [u1, u1, u1, u2], [u1, u1, u1, u2, u3]))
        @test cs(filter(U; comments__lt = c)) == lt
        @test cs(filter(U; comments__lte = c)) == lte
    end
    for (c, gt, gte, ex) in ((c11, [u1, u1, u2, u3], [u1, u1, u1, u2, u3], [u1]), (c12, [u1, u2, u3], [u1, u1, u2, u3], [u1]),
                             (c13, [u1, u3], [u1, u2, u3], [u2]), (c15, [u3], [u1, u3], [u1]), (c24, [], [u3], [u3]))
        @test cs(filter(U; comments__gt = c)) == gt
        @test cs(filter(U; comments__gte = c)) == gte
        @test cs(filter(U; comments = c)) == ex
    end
    # isnull
    @test cs(filter(U; comments__isnull = true)) == [u4]
    @test cs(filter(U; comments__isnull = false)) == [u1, u1, u1, u2, u3]
    @test isempty(cs(filter(C; pk__isnull = true))) && cs(filter(C; pk__isnull = false)) == [c11, c12, c13, c15, c24]
    # subqueries
    @test collect(filter(U; comments__in = only(filter(C; num = 3), :pk))) == [u2]
    @test collect(filter(C; user__in = values(filter(C; num = 3), :user))) == [c13]
    @test count(filter(U; pk__in = Subquery(values(objects(U), :pk)))) == 4
    @test count(filter(C; user__in = Subquery(values(objects(U), :pk)))) == 5
    # test_cannot_cast_pk, test_filter_case_when
    @test occursin("Cast expression does not support composite primary keys.",
                   something(cpk_msg(() -> count(filter(C; text__gt = Cast(F(:pk), TextField())))), "no error"))
    # test_outer_ref_pk, test_outer_ref_pk_filter_on_pk_exact
    sub = Subquery(values(filter(C; pk = OuterRef(:pk)), :num)[1:1])
    for (lk, n) in ((:num, 5), (:num__gt, 0), (:num__gte, 5), (:num__lt, 0), (:num__lte, 5))
        @test count(filter(C; (lk => sub,)...)) == n
    end
    @test count(filter(C; pk = Subquery(values(filter(U; pk = OuterRef(:pk)), :pk)[1:1]))) == 2
    # test_filter_by_pk_exact_rhs_f_object
    @test count(filter(C; pk = F(:pk))) == count(objects(C))
    # test_filter_comments_by_pk_exact_subquery
    @test collect(filter(C; pk = filter(C; pk = c11.pk)[1:1])) == [c11]
    # test_filter_by_tuple_containing_expression
    pk = (c11.tenant.id, (Value(c11.num) + 1) - 1)
    @test get(filter(C; pk = pk)) == c11 && get(filter(C; pk__in = [pk])) == c11
  end
  # CompositePKExcludeNoneTests
  port_block() do
    t = create(CpkTenant)
    u = create(CpkUser; tenant = t, num = 1, email = "exclude@example.com")
    @test isempty(collect(filter(CpkUser; pk__in = [(u.pk[1], nothing)]))) && isempty(collect(filter(CpkUser; pk__in = [(nothing, nothing)])))
    @test collect(exclude(objects(CpkUser); pk__in = [(u.pk[1], nothing)])) == [u]
    @test collect(exclude(objects(CpkUser); pk__in = [(nothing, nothing)])) == [u]
  end
end

@testset "django composite_pk: CompositePKModelsTests" begin
  port_block() do
    T, U, C = CpkTenant, CpkUser, CpkComment
    t1, t2 = create(T), create(T)
    u1 = create(U; tenant = t1, num = 1, email = "user0001@example.com")
    u2 = create(U; tenant = t1, num = 2, email = "user0002@example.com")
    u3 = create(U; tenant = t2, num = 3, email = "user0003@example.com")
    c1, c2, c3, c4 = create(C; num = 1, user = u1), create(C; num = 2, user = u1), create(C; num = 3, user = u2), create(C; num = 4, user = u3)
    cs(qs) = collect(order_by(qs, :pk))
    # test_fields
    @test cs(t1.cpkuser_set) == [u1, u2] && cs(t1.comments) == [c1, c2, c3]
    @test cs(t2.cpkuser_set) == [u3] && cs(t2.comments) == [c4]
    @test u1.num == 1 && u1.tenant_id == t1.id && u1.tenant == t1 && u1.pk == (t1.id, 1) && cs(u1.comments) == [c1, c2]
    @test u2.num == 2 && u2.tenant == t1 && u2.pk == (t1.id, 2) && cs(u2.comments) == [c3]
    @test c1.num == 1 && c1.user_id == u1.num && c1.user == u1 && c1.tenant_id == t1.id && c1.tenant == t1 && c1.pk == (t1.id, u1.num)
    # test_full_clean_success
    for (kw, excl) in (((tenant = t1, num = 1234), []), ((tenant_id = t1.id, num = 1234), []), ((pk = (t1.id, 1234),), []),
                       ((tenant = t1, num = 1), [:num]), ((tenant_id = t1.id, num = 1), [:num]), ((pk = (t1.id, 1),), [:num]),
                       ((tenant = t1, num = 1), [:tenant, :num]), ((tenant_id = t1.id, num = 1), [:tenant, :num]), ((pk = (t1.id, 1),), [:tenant, :num]))
        @test isempty(full_clean(U(; kw..., email = "user0004@example.com"); exclude = excl))
    end
    # test_full_clean_failure: the key together, and num's own uniqueness
    both = "Cpk user with this Tenant and Num already exists."
    one = "Cpk user with this Num already exists."
    for (kw, excl, msgs) in (((tenant = t1, num = 1), [], [both, one]), ((tenant_id = t1.id, num = 1), [], [both, one]),
                             ((pk = (t1.id, 1),), [], [both, one]), ((tenant = t2, num = 1), [], [one]), ((tenant_id = t2.id, num = 1), [], [one]),
                             ((pk = (t2.id, 1),), [], [one]), ((tenant = t1, num = 1), [:tenant], [one]),
                             ((tenant_id = t1.id, num = 1), [:tenant], [one]), ((pk = (t1.id, 1),), [:tenant], [one]))
        errs = full_clean(U(; kw..., email = "user0004@example.com"); exclude = excl)
        @test sort(vcat(String[], values(errs)...)) == sort(msgs)
    end
    # test_full_clean_update
    @test isempty(full_clean(c1))
    # test_field_conflicts: pk wins over its fields, given before or after
    for (kw, pk) in (((pk = (1, 1), num = 2), (1, 1)), ((num = 2, pk = (1, 1)), (1, 1)), ((pk = (1, 1), tenant_id = 2), (1, 1)),
                     ((tenant_id = 2, pk = (1, 1)), (1, 1)), ((pk = (2, 2), tenant_id = 3, num = 4), (2, 2)), ((tenant_id = 3, num = 4, pk = (2, 2)), (2, 2)))
        @test U(; kw...).pk == pk
    end
    # test_validate_unique
    user = get(U; pk = u1.pk)
    user.num = nothing
    @test vcat(String[], values(validate_unique(user))...) == ["Cpk user with this Email already exists."]
  end
end
