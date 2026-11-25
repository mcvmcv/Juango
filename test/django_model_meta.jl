# Django's model_meta tests, ported (#227): tests/model_meta (get_field, get_fields, label, related objects,
# parents), against Juango's introspection API: `get_field(T, name)`, `get_fields(T; include_parents,
# include_hidden)`, `related_objects(T)`, `model_label(T)`, `model_label_lower(T)`.
# julia --project=test test/django_model_meta.jl   (see setup.jl)
#
# Juango's automatic `id` isn't a field, and a reverse relation is a `RelatedObject` (Django's ForeignObjectRel).
# Each test keeps its Django name in a comment.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DmmRelation
    Meta(table = "dmm_relation")
end
@model struct DmmBasePerson
    data_base = CharField(max_length = 10)
    fk_base = ForeignKey(DmmRelation, on_delete = :CASCADE, related_name = :fk_base_rel)
    m2m_base = ManyToManyField(DmmRelation; related_name = :relating_basepeople)
    Meta(table = "dmm_baseperson")
end
@model struct DmmPerson <: DmmBasePerson
    data_inherited = CharField(max_length = 10)
    fk_inherited = ForeignKey(DmmRelation, on_delete = :CASCADE, related_name = :fk_concrete_rel)
    m2m_inherited = ManyToManyField(DmmRelation; related_name = :m2m_concrete_rel)
    friends = ManyToManyField(:self; related_name = :friends_rev)
    Meta(table = "dmm_person")
end
@model struct DmmRelating
    baseperson = ForeignKey(DmmBasePerson, on_delete = :CASCADE, related_name = :relating_baseperson)
    person = ForeignKey(DmmPerson, on_delete = :CASCADE, related_name = :relating_person)
    hidden_person = ForeignKey(DmmPerson, on_delete = :CASCADE, related_name = Symbol("+"))
    people = ManyToManyField(DmmPerson; related_name = :relating_people)
    Meta(table = "dmm_relating")
end
redirect_stdout(devnull) do
    ms = [DmmRelation, DmmBasePerson, through(DmmBasePerson, :m2m_base), DmmPerson, through(DmmPerson, :m2m_inherited),
          through(DmmPerson, :friends), DmmRelating, through(DmmRelating, :people)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
dmm_names(xs) = [x isa Juango.RelatedObject ? x.name : x.name for x in xs]

@testset "django model_meta" begin
    # LabelTests
    @test Juango.model_label(DmmPerson) == "project.DmmPerson"                                   # test_label
    @test Juango.model_label_lower(DmmPerson) == "project.dmmperson"                             # test_label_lower
    # DataTests: the fields, a multi-table child's parents' first
    @test dmm_names(Juango.concrete_fields(DmmPerson)) == [:data_base, :fk_base, :data_inherited, :fk_inherited]   # test_fields
    @test dmm_names(Juango.get_fields(DmmPerson; include_parents = false))[1:2] == [:data_inherited, :fk_inherited]   # test_local_fields
    # M2MTests
    @test dmm_names(Juango.many_to_many(DmmPerson)) == [:m2m_base, :m2m_inherited, :friends]             # test_many_to_many
    # RelatedObjectsTests: the relations of other models to it, by their query names
    rel = Juango.related_objects(DmmPerson)
    @test Set(r.name for r in rel if !r.hidden) ⊇ Set([:relating_person, :relating_people])          # test_related_objects
    @test any(r -> r.hidden && r.related_model === DmmRelating, rel)                                  # test_related_objects_include_hidden
    @test !any(x -> x isa Juango.RelatedObject && x.hidden, Juango.get_fields(DmmPerson))
    @test any(x -> x isa Juango.RelatedObject && x.hidden, Juango.get_fields(DmmPerson; include_hidden = true))
    # GetFieldByNameTests
    f = Juango.get_field(DmmPerson, :data_base)                                                      # test_get_data_field (an inherited one)
    @test f isa Juango.Field && f.kind === :char
    f = Juango.get_field(DmmPerson, "m2m_base")                                                      # test_get_m2m_field
    @test f.kind === :m2m && Juango.related_model(f) === DmmRelation
    r = Juango.get_field(DmmBasePerson, :relating_baseperson)                                        # test_get_related_object
    @test r isa Juango.RelatedObject && r.one_to_many && r.related_model === DmmRelating && r.field.name === :baseperson
    @test r.accessor === :relating_baseperson && Juango.is_relation(r)
    r = Juango.get_field(DmmPerson, :relating_people)                                                # test_get_related_m2m
    @test r isa Juango.RelatedObject && r.many_to_many && r.related_model === DmmRelating
    r = Juango.get_field(DmmRelation, :relating_basepeople)
    @test r.many_to_many && r.related_model === DmmBasePerson
    e = try Juango.get_field(DmmPerson, :nope) catch e; e end
    @test e isa Juango.FieldDoesNotExist && e.msg == "DmmPerson has no field named 'nope'"
    @test sprint(show, Juango.get_field(DmmBasePerson, :relating_baseperson)) == "<ManyToOneRel: project.DmmRelating.baseperson>"
    # AllParentsTests
    @test Juango.table_parent(DmmPerson) === DmmBasePerson && Juango.table_parent(DmmBasePerson) === nothing
    # not translated: get_fields' immutability and caches (the relation tree), GenericRelations and private fields,
    # verbose_name_raw, swappable models, the apps-not-ready search, _property_names, db_returning_fields, abstract
    # models (Juango's @abstract_model can't be made)
end
