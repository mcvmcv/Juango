# Django's field_subclassing tests, ported (#227): TestDbType. A Django Field subclass overriding `db_type` is a
# field with `db_type = "..."` (or a Dict of vendor => type) in Juango.
# julia --project=test test/django_field_subclassing.jl   (see setup.jl)
#
# Not translated: DescriptorClassTest (a field's descriptor_class; Juango's model instances are structs, whose
# fields are read and set directly).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DfsTyped
    name::String = TextField(db_type = "VARCHAR(20)")
    other::String = TextField(db_type = Dict("postgresql" => "VARCHAR(30)", "mysql" => "VARCHAR(30)", "sqlite" => "VARCHAR(30)"))
    plain::String = TextField(db_type = Dict("oracle" => "NCLOB"), default = "")
    Meta(table = "dfs_typed")
end
redirect_stdout(devnull) do
    Juango.sync_models!([DfsTyped]); push!(PORT_MODELS, DfsTyped)
end

@testset "django field_subclassing: TestDbType" begin
    b = Juango.backend()
    cols = Dict(string(n) => Juango.column_state(Juango.getfield_meta(DfsTyped, n)) for n in (:name, :other, :plain))
    # test_db_parameters_respects_db_type
    @test Juango.column_type_for(b, cols["name"]) == "VARCHAR(20)"
    @test Juango.column_type_for(b, cols["other"]) == "VARCHAR(30)"
    # a vendor the Dict doesn't name: the kind's own type
    @test Juango.column_type_for(b, cols["plain"]) == Juango.column_type_for(b, Juango.with_column(cols["plain"]; db_type = nothing))
    # the type is in the migration's column, and read back from it
    code = Juango.Migrations.column_code(cols["other"])
    @test occursin("db_type = Dict(", code) && Core.eval(Juango.Migrations, Meta.parse(code)) == cols["other"]
    @test Juango.Migrations.column_code(cols["name"]) == "Column(\"name\", :string; db_type = \"VARCHAR(20)\")"
    port_block() do
        create(DfsTyped; name = "abc", other = "def")
        @test only(collect(objects(DfsTyped))).name == "abc"
    end
end
