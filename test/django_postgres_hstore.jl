# Django's postgres_tests/test_hstore, ported (#227). Juango's HStoreField works on every backend (PostgreSQL's
# hstore, JSON text elsewhere), so these run on all three.
# julia --project=test test/django_postgres_hstore.jl   (see setup.jl)
#
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DhsHStoreModel
    field = HStoreField(blank = true, null = true)
    array_field = ArrayField(HStoreField(); null = true)
    Meta(table = "dhs_hstore")
end
@model struct DhsBadDefault
    field = HStoreField(default = Dict{String,Any}())
    Meta(table = "dhs_baddefault")
end
@model struct DhsGoodDefault
    field = HStoreField(default = Dict)
    Meta(table = "dhs_gooddefault")
end
const DHS_MODELS = [DhsHStoreModel]
redirect_stdout(devnull) do
    Juango.sync_models!(DHS_MODELS); append!(PORT_MODELS, DHS_MODELS)
end
dhs_ids(qs) = sort([o.id for o in qs])

@testset "django postgres_tests test_hstore: SimpleTests" begin
    port_block() do
        M = DhsHStoreModel
        o = create(M; field = Dict("a" => "b"))                                             # test_save_load_success
        @test get(M; id = o.id).field == Dict("a" => "b")
        o = create(M; field = nothing)                                                      # test_null
        @test get(M; id = o.id).field === nothing
        o = create(M; field = Dict("a" => nothing))                                         # test_value_null
        @test get(M; id = o.id).field == Dict("a" => nothing)
        delete!(filter(M))
        value = Dict("a" => 1, "b" => "B", 2 => "c", "ï" => "ê")                          # test_key_val_cast_to_string
        expected = Dict("a" => "1", "b" => "B", "2" => "c", "ï" => "ê")
        create(M; field = value)
        @test only(objects(M)).field == expected
        @test get(M; field__a = 1).field == expected
        @test get(M; field__has_keys = [2, "a", "ï"]).field == expected
        o = create(M; array_field = [value, value])                                         # test_array_field
        refresh!(o)
        @test o.array_field == [expected, expected]
    end
end

@testset "django postgres_tests test_hstore: TestQuerying" begin
    port_block() do
        M = DhsHStoreModel
        objs = bulk_create([M(; field = Dict("a" => "b")), M(; field = Dict("a" => "b", "c" => "d")), M(; field = Dict("c" => "d")),
                            M(; field = Dict{String,Any}()), M(; field = nothing),
                            M(; field = Dict("cat" => "TigrOu", "breed" => "birman")), M(; field = Dict("cat" => "minou", "breed" => "ragdoll")),
                            M(; field = Dict("cat" => "kitty", "breed" => "Persian")), M(; field = Dict("cat" => "Kit Kat", "breed" => "persian"))])
        ids(r) = sort([objs[i].id for i in r])
        @test dhs_ids(filter(M; field__exact = Dict("a" => "b"))) == ids(1:1)                # test_exact
        @test dhs_ids(filter(M; field__contained_by = Dict("a" => "b", "c" => "d"))) == ids(1:4)   # test_contained_by
        @test dhs_ids(filter(M; field__contains = Dict("a" => "b"))) == ids(1:2)              # test_contains
        @test dhs_ids(filter(M; field__in = (d for d in [Dict("a" => "b")]))) == ids(1:1)     # test_in_generator
        @test dhs_ids(filter(M; field__has_key = "c")) == ids(2:3)                            # test_has_key
        @test dhs_ids(filter(M; field__has_keys = ["a", "c"])) == ids(2:2)                    # test_has_keys
        @test dhs_ids(filter(M; field__has_any_keys = ["a", "c"])) == ids(1:3)                # test_has_any_keys
        @test dhs_ids(filter(M; field__a = "b")) == ids(1:2)                                  # test_key_transform
        # test_key_transform_raw_expression: not translated (KeyTransform over a RawSQL hstore literal)
        @test sort(collect(values_list(annotate(M; a = F(:field__a)), :a; flat = true)), by = x -> something(x, "")) ==
              [nothing, nothing, nothing, nothing, nothing, nothing, nothing, "b", "b"]       # test_key_transform_annotation
        @test dhs_ids(filter(M; field__keys = ["a"])) == ids(1:1)                             # test_keys
        @test dhs_ids(filter(M; field__values = ["b"])) == ids(1:1)                           # test_values
        @test dhs_ids(filter(M; field__a__contains = "b")) == ids(1:2)                        # test_field_chaining_contains
        @test dhs_ids(filter(M; field__cat__icontains = "INo")) == ids(7:7)                   # test_field_chaining_icontains
        @test dhs_ids(filter(M; field__cat__startswith = "kit")) == ids(8:8)                  # test_field_chaining_startswith
        @test dhs_ids(filter(M; field__cat__istartswith = "kit")) == ids(8:9)                 # test_field_chaining_istartswith
        @test dhs_ids(filter(M; field__cat__endswith = "ou")) == ids(7:7)                     # test_field_chaining_endswith
        @test dhs_ids(filter(M; field__cat__iendswith = "ou")) == ids(6:7)                    # test_field_chaining_iendswith
        @test dhs_ids(filter(M; field__breed__iexact = "persian")) == ids(8:9)                # test_field_chaining_iexact
        @test dhs_ids(filter(M; field__cat__regex = r"ou$")) == ids(7:7)                      # test_field_chaining_regex
        @test dhs_ids(filter(M; field__cat__iregex = r"oU$")) == ids(6:7)                     # test_field_chaining_iregex
        more = [create(M; field = Dict("g" => "637")), create(M; field = Dict("g" => "002")),   # test_order_by_field
                create(M; field = Dict("g" => "042")), create(M; field = Dict("g" => "981"))]
        @test [o.id for o in order_by(filter(M; field__has_key = "g"), "field__g")] == [more[2].id, more[3].id, more[1].id, more[4].id]
        foreach(delete!, more)
        @test dhs_ids(filter(M; field__keys__contains = ["a"])) == ids(1:2)                   # test_keys_contains
        @test dhs_ids(filter(M; field__values__overlap = ["b", "d"])) == ids(1:3)             # test_values_overlap
        o = create(M; field = Dict("a" => nothing))                                         # test_key_isnull
        @test dhs_ids(filter(M; field__a__isnull = true)) == sort(vcat(ids(3:9), [o.id]))
        @test dhs_ids(filter(M; field__a__isnull = false)) == ids(1:2)
        delete!(o)
        @test dhs_ids(filter(M; id__in = filter(M; field__a = "b"))) == ids(1:2)             # test_usage_in_subquery
        # test_key_sql_injection: the key is a parameter (or a quoted literal), never SQL
        @test !exists(filter(M; Symbol("field__test' = 'a') OR 1 = 1 OR ('d") => "x"))
        qs = filter(annotate(M; value = Subquery(values(filter(M; pk = OuterRef(:pk)), :field))), value__a = "b")   # test_obj_subquery_lookup
        @test dhs_ids(qs) == ids(1:2)                                                        # (key lookups on an hstore annotation: #297)
    end
end

@testset "django postgres_tests test_hstore: TestChecks" begin
    issues = [(i.id, i.msg, i.hint) for i in Juango.model_check_issues(DhsBadDefault)]               # test_invalid_default
    @test issues == [("fields.E010", "$(Juango.model_label(DhsBadDefault)).field: HStoreField default should be a callable instead of an " *
                      "instance so that it's not shared between all field instances.", "Use a callable instead, e.g., use `Dict` instead of `Dict()`.")]
    @test isempty(Juango.model_check_issues(DhsGoodDefault))                                           # test_valid_default
end

@testset "django postgres_tests test_hstore: TestSerialization" begin
    M = DhsHStoreModel
    for (fv, av) in [(Dict("a" => "b"), [Dict("a" => "b"), Dict("b" => "a")]),                        # test_dumping / test_loading
                     (Dict("все" => "Трурль и Клапауций"), [Dict("Трурль" => "Клапауций"), Dict("Клапауций" => "Трурль")])]
        data = serialize(:json, [M(; field = fv, array_field = av)])
        o = only(deserialize(:json, data)).object
        @test o.field == fv && o.array_field == av
    end
    for fv in [Dict("a" => "b", "c" => nothing), Dict("Енеїда" => "Ти знаєш, він який суціга", "Зефір" => nothing)]   # test_roundtrip_with_null
        @test only(deserialize(:json, serialize(:json, [M(; field = fv)]))).object.field == fv
    end
end

@testset "django postgres_tests test_hstore: TestValidation" begin
    msgs(f, v) = try clean(f, v); String[] catch e; e isa ValidationError || rethrow(); reduce(vcat, collect(values(e.errors)); init = String[]) end
    @test msgs(HStoreField(), Dict("a" => 1)) == ["The value of “a” is not a string or null."]       # test_not_a_string
    @test clean(HStoreField(), Dict("a" => nothing)) == Dict("a" => nothing)                         # test_none_allowed_as_value
end

@testset "django postgres_tests test_hstore: TestFormField" begin
    msgs(f, v) = try clean(f, v); String[] catch e; e isa ValidationError || rethrow(); reduce(vcat, collect(values(e.errors)); init = String[]) end
    @test clean(HStoreField(), "{\"a\": \"b\"}") == Dict("a" => "b")                                 # test_valid
    @test msgs(HStoreField(), "{\"a\": \"b\"") == ["Could not load JSON data."]                      # test_invalid_json
    # test_invalid_json_deeply_nested: not translated (mocks json.loads raising RecursionError)
    @test msgs(HStoreField(), "[\"a\", \"b\", 1]") == ["Input must be a JSON dictionary."]           # test_non_dict_json
    @test clean(HStoreField(), "{\"a\": 1}") == Dict("a" => "1")                                    # test_not_string_values
    @test clean(HStoreField(), "{\"a\": null}") == Dict("a" => nothing)                             # test_none_value
    @test clean(HStoreField(; required = false), "") == Dict()                                       # test_empty
    # test_model_field_formfield: the model field is its own form field here
    changed(data; kw...) = has_changed(Form([:f1 => HStoreField()]; data = data, kw...))              # test_field_has_changed
    @test !has_changed(Form([:f1 => HStoreField()]))
    @test changed(Dict{String,Any}("f1" => "{\"a\": 1}"))
    @test !changed(Dict{String,Any}("f1" => "{\"a\": 1}"); initial = Dict{Symbol,Any}(:f1 => "{\"a\": 1}"))
    @test changed(Dict{String,Any}("f1" => "{\"a\": 2}"); initial = Dict{Symbol,Any}(:f1 => "{\"a\": 1}"))
    @test !changed(Dict{String,Any}("f1" => "{\"a\": 1}"); initial = Dict{Symbol,Any}(:f1 => Dict("a" => 1)))
    @test changed(Dict{String,Any}("f1" => "{\"a\": 2}"); initial = Dict{Symbol,Any}(:f1 => Dict("a" => 1)))
    # test_prepare_value: shown as JSON, not escaped to \u sequences (Juango's JSON has no spaces after the colons)
    f = Form([:f1 => HStoreField()]; initial = Dict{Symbol,Any}(:f1 => Dict("aira_maplayer" => "Αρδευτικό δίκτυο")))
    @test Juango.display_value(f[:f1]) == "{\"aira_maplayer\":\"Αρδευτικό δίκτυο\"}"
end

@testset "django postgres_tests test_hstore: TestValidator" begin
    @test KeysValidator(["a", "b"])(Dict("a" => "foo", "b" => "bar", "c" => "baz")) === nothing      # test_simple_valid
    @test Juango.validation_error(KeysValidator(["a", "b"]), Dict("a" => "foo", "c" => "baz")) ==    # test_missing_keys
          ("missing_keys", "Some keys were missing: b")
    @test KeysValidator(["a", "b"]; strict = true)(Dict("a" => "foo", "b" => "bar")) === nothing    # test_strict_valid
    @test Juango.validation_error(KeysValidator(["a", "b"]; strict = true), Dict("a" => "foo", "b" => "bar", "c" => "baz")) ==   # test_extra_keys
          ("extra_keys", "Some unknown keys were provided: c")
    v = KeysValidator(["a", "b"]; strict = true, messages = Dict("missing_keys" => "Foobar"))       # test_custom_messages
    @test Juango.validation_error(v, Dict("a" => "foo", "c" => "baz")) == ("missing_keys", "Foobar")
    @test Juango.validation_error(v, Dict("a" => "foo", "b" => "bar", "c" => "baz")) == ("extra_keys", "Some unknown keys were provided: c")
    # test_deconstruct: validators with the same settings are equal (what migrations compare)
    @test KeysValidator(["a", "b"]; strict = true, messages = Dict("missing_keys" => "Foobar")) ==
          KeysValidator(["a", "b"]; strict = true, messages = Dict("missing_keys" => "Foobar"))
end
