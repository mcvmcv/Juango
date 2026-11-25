# Django's invalid_models_tests, ported (#227, part): the model checks of Meta names (models.E012, E013, E016),
# ordering (E015), columns (E007) and reverse accessor / query name clashes (fields.E302-E305).
# julia --project=test test/django_invalid_models.jl   (see setup.jl)
#
# `Juango.model_check_issues(T)` gives a model's problems; `manage.jl check` (tag models) runs it for every model.
# Juango refuses many of Django's other invalid definitions when the model is made (a DecimalField without
# max_digits, on_delete = :SET_NULL without null, ...), so those checks have nothing left to find.
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dim(T) = [(m.id, m.msg) for m in Juango.model_check_issues(T)]
const DIM = "project."

# --- Meta names (IndexTogetherTests, UniqueTogetherTests, IndexesTests, ConstraintsTests) ----------------------
@model struct DimUtMissing
    name = CharField(max_length = 10)
    Meta(table = "dim_ut_missing", unique_together = [(:name, :missing_field)])
end
@model struct DimUtM2M
    name = CharField(max_length = 10)
    m2m = ManyToManyField(DimUtMissing; related_name = :dim_ut_m2m)
    Meta(table = "dim_ut_m2m", unique_together = [(:name, :m2m)])
end
@model struct DimParent
    field1 = IntegerField()
    Meta(table = "dim_parent")
end
@model struct DimChild <: DimParent
    field2 = IntegerField()
    Meta(table = "dim_child", unique_together = [(:field1, :field2)])
end
@model struct DimIdx
    name = CharField(max_length = 10)
    Meta(table = "dim_idx", indexes = [Index(fields = [:missing_field], name = "dim_idx_missing")])
end
@model struct DimCons
    age = IntegerField()
    Meta(table = "dim_cons", constraints = [UniqueConstraint(fields = [:missing_field], name = "dim_cons_missing")])
end
@model struct DimOk
    name = CharField(max_length = 10)
    code = CharField(max_length = 10)
    Meta(table = "dim_ok", unique_together = [(:name, :code)], indexes = [Index(fields = [:name, "-code"], name = "dim_ok_idx")],
         constraints = [UniqueConstraint(fields = [:code], name = "dim_ok_code")], ordering = ["-name", "code", "pk", "?"])
end
# --- ordering (OtherModelTests) ---------------------------------------------------------------------------------
@model struct DimOrdMissing
    Meta(table = "dim_ord_missing", ordering = ["relation"])
end
@model struct DimOrdRel
    parent = ForeignKey(DimOk, on_delete = :CASCADE, related_name = :dim_ord_rels)
    Meta(table = "dim_ord_rel", ordering = ["parent__name", "parent__nope", "-parent_id"])
end
# --- columns (FieldNamesTests) ----------------------------------------------------------------------------------
@model struct DimColumns
    foo = IntegerField(db_column = "dup")
    bar = IntegerField(db_column = "dup")
    Meta(table = "dim_columns")
end
# --- reverse accessors and query names (AccessorClashTests, ReverseQueryNameClashTests, ExplicitRelatedNameClashTests) -
@model struct DimTarget
    model_set = IntegerField()
    clash = IntegerField()
    Meta(table = "dim_target")
end
@model struct DimModel
    rel = ForeignKey(DimTarget, on_delete = :CASCADE, related_name = :model_set)              # E302 (and E303: the query name is it too)
    Meta(table = "dim_model")
end
@model struct DimQName
    rel = ForeignKey(DimTarget, on_delete = :CASCADE, related_name = :ok_accessor, related_query_name = :clash)   # E303
    Meta(table = "dim_qname")
end
@model struct DimTarget2
    Meta(table = "dim_target2")
end
@model struct DimBoth
    foreign = ForeignKey(DimTarget2, on_delete = :CASCADE)                                       # test_clash_between_accessors: E304, E305
    m2m = ManyToManyField(DimTarget2)
    Meta(table = "dim_both")
end
@model struct DimHidden
    foreign = ForeignKey(DimTarget2, on_delete = :CASCADE, related_name = Symbol("+"))
    other = ForeignKey(DimTarget2, on_delete = :CASCADE, related_name = Symbol("+"))           # (hidden: no clash)
    Meta(table = "dim_hidden")
end
# No tables: the checks don't need them, and the models with bad names can't be migrated. They're registered only
# while their tests run (as Django's isolate_apps), so migrations and model scans elsewhere don't meet them.
const DIM_MODELS = Any[DimUtMissing, DimUtM2M, DimParent, DimChild, DimIdx, DimCons, DimOk, DimOrdMissing, DimOrdRel, DimColumns,
                       DimTarget, DimModel, DimQName, DimTarget2, DimBoth, through(DimBoth, :m2m), through(DimUtM2M, :m2m), DimHidden]
dim_unregister!() = (filter!(m -> !any(x -> x === m, DIM_MODELS), Juango.MODEL_LIST); Juango.invalidate_relations!())
dim_unregister!()
function with_dim_models(f)
    append!(Juango.MODEL_LIST, DIM_MODELS); Juango.invalidate_relations!()
    try
        f()
    finally
        dim_unregister!()
    end
end

@testset "django invalid_models_tests" begin
with_dim_models() do
    # test_pointing_to_missing_field (unique_together, indexes, constraints), test_pointing_to_m2m, test_pointing_to_non_local_field
    @test dim(DimUtMissing) == [("models.E012", "$(DIM)DimUtMissing: 'unique_together' refers to the nonexistent field 'missing_field'.")]
    @test dim(DimUtM2M) == [("models.E013", "$(DIM)DimUtM2M: 'unique_together' refers to a ManyToManyField 'm2m', but ManyToManyFields are not permitted in 'unique_together'.")]
    @test dim(DimChild) == [("models.E016", "$(DIM)DimChild: 'unique_together' refers to field 'field1' which is not local to model 'DimChild'.")]
    @test Juango.model_check_issues(DimChild)[1].hint == "This issue may be caused by multi-table inheritance."
    @test dim(DimIdx) == [("models.E012", "$(DIM)DimIdx: 'indexes' refers to the nonexistent field 'missing_field'.")]
    @test dim(DimCons) == [("models.E012", "$(DIM)DimCons: 'constraints' refers to the nonexistent field 'missing_field'.")]
    @test isempty(dim(DimOk))
    # test_ordering_pointing_to_missing_field, test_ordering_pointing_to_missing_related_field, test_ordering_pointing_to_related_model_pk
    @test dim(DimOrdMissing) == [("models.E015", "$(DIM)DimOrdMissing: 'ordering' refers to the nonexistent field, related field, or lookup 'relation'.")]
    @test dim(DimOrdRel) == [("models.E015", "$(DIM)DimOrdRel: 'ordering' refers to the nonexistent field, related field, or lookup 'parent__nope'.")]
    # test_db_column_clash
    @test dim(DimColumns) == [("models.E007", "$(DIM)DimColumns: Field 'bar' has column name 'dup' that is used by another field.")]
    # test_clash_between_accessors, AccessorClashTests, ReverseQueryNameClashTests
    @test dim(DimModel) == [("fields.E302", "Reverse accessor 'DimTarget.model_set' for '$(DIM)DimModel.rel' clashes with field name '$(DIM)DimTarget.model_set'."),
                            ("fields.E303", "Reverse query name for '$(DIM)DimModel.rel' clashes with field name '$(DIM)DimTarget.model_set'.")]
    @test Juango.model_check_issues(DimModel)[1].hint ==
          "Rename field '$(DIM)DimTarget.model_set', or add/change a related_name argument to the definition for field '$(DIM)DimModel.rel'."
    @test dim(DimQName) == [("fields.E303", "Reverse query name for '$(DIM)DimQName.rel' clashes with field name '$(DIM)DimTarget.clash'.")]
    @test dim(DimBoth) == [("fields.E304", "Reverse accessor 'DimTarget2.dimboth_set' for '$(DIM)DimBoth.foreign' clashes with reverse accessor for '$(DIM)DimBoth.m2m'."),
                           ("fields.E305", "Reverse query name for '$(DIM)DimBoth.foreign' clashes with reverse query name for '$(DIM)DimBoth.m2m'."),
                           ("fields.E304", "Reverse accessor 'DimTarget2.dimboth_set' for '$(DIM)DimBoth.m2m' clashes with reverse accessor for '$(DIM)DimBoth.foreign'."),
                           ("fields.E305", "Reverse query name for '$(DIM)DimBoth.m2m' clashes with reverse query name for '$(DIM)DimBoth.foreign'.")]
    @test isempty(dim(DimHidden))
    # manage.jl check reports them
    @test any(m -> m.id == "fields.E304" && occursin("DimBoth.foreign", m.msg), Juango.run_checks(; tags = [:models]))
end
    # not translated: the checks Juango makes when a model is defined (CharField max_length, DecimalField digits,
    # on_delete, through models, primary keys, ...), the database-specific checks, and custom fields' checks
end
