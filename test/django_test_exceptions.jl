# Django's test_exceptions tests (test_validation_error.py), ported (#227): a ValidationError's messages, equality and
# hash, which ignore the order of messages and fields.
# julia --project=test test/django_test_exceptions.jl   (see setup.jl; no database needed)
#
# Juango's ValidationError interpolates params when it's made and keeps only the messages of nested errors: comparing
# templates, params and nested codes is #311 (@test_broken).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@testset "django test_exceptions: TestValidationError" begin
    VE = Juango.ValidationError
    # test_messages_concatenates_error_dict_values
    md = Dict{String,Any}()
    @test sort(VE(md).messages) == String[]
    md["field1"] = ["E1", "E2"]
    @test sort(VE(md).messages) == ["E1", "E2"]
    md["field2"] = ["E3", "E4"]
    @test sort(VE(md).messages) == ["E1", "E2", "E3", "E4"]
    # test_eq / test_hash
    e1, e2, e3 = VE("message"), VE("message"; code = "my_code1"), VE("message"; code = "my_code2")
    e4 = VE("error %(parm1)s %(parm2)s"; code = "my_code1", params = Dict("parm1" => "val1", "parm2" => "val2"))
    e5, e6 = VE(Dict("field1" => "message", "field2" => "other")), VE(Dict("field1" => "message"))
    e7 = VE([VE(Dict("field1" => "field error", "field2" => "other")), "message"])
    for f in (==, (a, b) -> hash(a) == hash(b))
        @test f(e1, VE("message")) && !f(e1, VE("message2")) && !f(e1, e2) && !f(e1, e4) && !f(e1, e5) && !f(e1, e6) && !f(e1, e7)
        @test f(e2, VE("message"; code = "my_code1")) && !f(e2, VE("other"; code = "my_code1")) && !f(e2, e3) && !f(e2, e4) && !f(e2, e5)
        @test f(e4, VE("error %(parm1)s %(parm2)s"; code = "my_code1", params = Dict("parm2" => "val2", "parm1" => "val1")))
        @test !f(e4, VE("error %(parm1)s %(parm2)s"; code = "my_code2", params = Dict("parm1" => "val1", "parm2" => "val2")))
        @test !f(e4, VE("error %(parm1)s %(parm2)s"; code = "my_code1", params = Dict("parm2" => "val2")))
        @test !f(e4, VE("error %(parm1)s %(parm2)s"; code = "my_code1", params = Dict("parm2" => "val1", "parm1" => "val2")))
        @test f(e5, VE(Dict("field1" => "message", "field2" => "other"))) && f(e5, VE(Dict("field2" => "other", "field1" => "message")))
        @test !f(e5, VE(Dict("field1" => "message", "field2" => "other2"))) && !f(e5, VE(Dict("field1" => "message", "field3" => "other"))) && !f(e5, e6)
        @test f(e7, VE(reverse(e7.messages)))                                # (messages ordering is ignored)
        @test !f(e7, VE(e7.messages[2:end]))
        # test_eq_nested
        ed = Dict{String,Any}("field1" => VE("error %(parm1)s %(parm2)s"; code = "my_code", params = Dict("parm1" => "val1", "parm2" => "val2")), "field2" => "other")
        @test f(VE(ed), VE(copy(ed)))
        @test !f(VE(ed), VE(merge(ed, Dict("field2" => "message"))))
    end
    # (#311: the template and params, and nested codes)
    @test_broken e4 != VE("error val1 val2"; code = "my_code1")
    @test_broken VE(["message"]) != VE([VE("message"; code = "my_code")])
end
