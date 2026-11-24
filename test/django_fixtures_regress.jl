# Django's fixtures_regress tests, ported (#227): loaddata's errors and warnings, forward references, and
# serializers.sort_dependencies.
# julia --project=test test/django_fixtures_regress.jl   (see setup.jl)
#
# The fixtures (test/fixtures_regress) are Django's (BSD licence), copied with their model labels pointing at these
# models (fixtures_regress.animal is fixtures_regress.dfranimal). Not translated: the natural-key loading tests that need Django's managers
# (test_nk_*, test_normal_pk, Ticket tests), dumpdata's verbosity and output tests, the M2M dependency-sorting
# variants, test_unimportable_serializer (SERIALIZATION_MODULES) and test_pg_sequence_resetting_checks.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DfrAnimal
    name = CharField(max_length = 150)
    latin_name = CharField(max_length = 150)
    count = IntegerField()
    weight = FloatField()
    Meta(table = "dfr_animal", app_label = "fixtures_regress")
end
@model struct DfrAbsolute
    name = CharField(max_length = 40)
    Meta(table = "dfr_absolute", app_label = "fixtures_regress")
end
@model struct DfrStore
    name = CharField(max_length = 255, unique = true)
    main = ForeignKey(:self; on_delete = :SET_NULL, null = true)
    Meta(table = "dfr_store", app_label = "fixtures_regress", ordering = [:name])
end
@model struct DfrPerson
    name = CharField(max_length = 255, unique = true)
    Meta(table = "dfr_person", app_label = "fixtures_regress", ordering = [:name])
end
@model struct DfrBook
    name = CharField(max_length = 255)
    author = ForeignKey(DfrPerson; on_delete = :CASCADE)
    stores = ManyToManyField(DfrStore)
    Meta(table = "dfr_book", app_label = "fixtures_regress", ordering = [:name])
end
@model struct DfrM2MToSelf
    parent = ManyToManyField(:self; blank = true)
    Meta(table = "dfr_m2mtoself", app_label = "fixtures_regress")
end
for (i, dep) in ((1, 2), (2, 1), (3, 3), (4, 5), (5, 6), (6, 4))
    T = Symbol(:DfrCircle, i)
    @eval @model struct $T
        name = CharField(max_length = 255, unique = true)
        Meta(table = $("dfr_circle$i"), app_label = "fixtures_regress")
    end
    @eval Juango.natural_key(o::$T) = (o.name,)
    @eval Juango.natural_key_dependencies(::Type{$T}) = [$("fixtures_regress.dfrcircle$dep")]
end
@model struct DfrExternalDependency
    name = CharField(max_length = 255, unique = true)
    Meta(table = "dfr_externaldependency", app_label = "fixtures_regress")
end
Juango.natural_key(o::DfrStore) = (o.name,)
Juango.get_by_natural_key(::Type{DfrStore}, k) = get(DfrStore; name = k)
Juango.natural_key(o::DfrPerson) = (o.name,)
Juango.get_by_natural_key(::Type{DfrPerson}, k) = get(DfrPerson; name = k)
Juango.natural_key_dependencies(::Type{DfrPerson}) = ["fixtures_regress.dfrstore"]
Juango.natural_key(o::DfrExternalDependency) = (o.name,)
Juango.natural_key_dependencies(::Type{DfrExternalDependency}) = ["fixtures_regress.dfrbook"]

redirect_stdout(devnull) do
    ms = Any[DfrAnimal, DfrAbsolute, DfrStore, DfrPerson, DfrBook, through(DfrBook, :stores), DfrM2MToSelf, through(DfrM2MToSelf, :parent)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

# Django's fixture directories (test/fixtures_regress), their labels rewritten for these models
const DFR_DIR = joinpath(@__DIR__, "fixtures_regress")
dfr_fx(sub = "fixtures") = joinpath(DFR_DIR, sub)

@testset "django fixtures_regress: TestFixtures" begin
  override_settings(FIXTURE_DIRS = [dfr_fx()]) do
    port_block() do
        # test_duplicate_pk: the sequence moves past the loaded ids
        loaddata("sequence")
        a = create(DfrAnimal; name = "Platypus", latin_name = "Ornithorhynchus anatinus", count = 2, weight = 2.2)
        @test a.id > 1
    end
    # test_loaddata_not_found_fields_not_ignore (with ignorenonexistent = false; Juango's default skips an unknown field: #284)
    for fx in ("sequence_extra", "sequence_extra_jsonl", "sequence_extra_yaml")
        port_block() do
            @test_throws Juango.DeserializationError loaddata(fx; ignorenonexistent = false)
        end
    end
    # (an unknown model is refused by default too; an unknown field alone isn't: #284)
    port_block() do
        @test_throws Juango.DeserializationError loaddata("sequence_extra")
        js = """[{"pk": 1, "model": "fixtures_regress.dfranimal", "fields": {"name": "x", "extra_name": "y", "latin_name": "z", "count": 1, "weight": 1.0}}]"""
        @test_broken (try Juango.deserialize(:json, js); false catch e; e isa Juango.DeserializationError end)
    end
    # test_loaddata_not_found_fields_ignore / ..._xml / ..._jsonl / ..._yaml
    for (fx, name) in (("sequence_extra", "Lion"), ("sequence_extra_xml", "Wolf"), ("sequence_extra_jsonl", "Eagle"), ("sequence_extra_yaml", "Cat"))
        port_block() do
            loaddata(fx; ignorenonexistent = true)
            @test first(objects(DfrAnimal)).name == name
        end
    end
    port_block() do
        # test_loaddata_empty_lines_jsonl
        loaddata("sequence_empty_lines_jsonl")
        @test first(objects(DfrAnimal)).name == "Eagle"
        # test_absolute_path / test_path_containing_dots
        loaddata(joinpath(dfr_fx(), "absolute.json"))
        @test count(objects(DfrAbsolute)) == 1
        loaddata("path.containing.dots.json")
        @test count(objects(DfrAbsolute)) == 1
    end
    port_block() do
        # test_relative_path_in_fixture_dirs
        override_settings(FIXTURE_DIRS = [dfr_fx("fixtures_1")]) do
            loaddata(joinpath("inner", "absolute.json"))
        end
        @test count(objects(DfrAbsolute)) == 1
    end
    # test_unknown_format
    @test_throws "Problem installing fixture 'bad_fix.ture1': unkn is not a known serialization format." loaddata("bad_fix.ture1.unkn")
    # test_invalid_data / test_invalid_data_no_ext / test_empty / test_error_message: warnings, not errors
    msg = "No fixture data found for 'bad_fixture2'. (File format may be invalid.)"
    port_block() do
        @test_logs (:warn, msg) loaddata("bad_fixture2.xml")
        @test_logs (:warn, msg) loaddata("bad_fixture2")
        @test_logs (:warn, "No fixture data found for 'empty'. (File format may be invalid.)") loaddata("empty")
    end
    port_block() do
        # test_loaddata_works_when_fixture_has_forward_refs
        loaddata("forward_ref.json")
        @test first(objects(DfrBook)).id == 1 && first(objects(DfrPerson)).id == 4
    end
    port_block() do
        # test_loaddata_raises_error_when_fixture_has_invalid_foreign_key
        @test_throws "Problem installing fixture" loaddata("forward_ref_bad_data.json")
    end
    port_block() do
        # test_loaddata_forward_refs_split_fixtures
        override_settings(FIXTURE_DIRS = [dfr_fx("fixtures_1"), dfr_fx("fixtures_2")]) do
            loaddata("forward_ref_1.json", "forward_ref_2.json")
        end
        @test first(objects(DfrBook)).id == 1 && first(objects(DfrPerson)).id == 4
    end
    port_block() do
        # test_loaddata_with_m2m_to_self
        loaddata("m2mtoself.json")
        @test count(objects(DfrM2MToSelf)) == 1
    end
  end
end

@testset "django fixtures_regress: NaturalKeyFixtureTests (dependency sorting)" begin
    sd = Juango.sort_dependencies
    for order in ([DfrBook, DfrPerson, DfrStore], [DfrBook, DfrStore, DfrPerson], [DfrStore, DfrBook, DfrPerson],
                  [DfrStore, DfrPerson, DfrBook], [DfrPerson, DfrBook, DfrStore], [DfrPerson, DfrStore, DfrBook])
        @test sd(order) == [DfrStore, DfrPerson, DfrBook]                       # test_dependency_sorting ... _6
    end
    @test sd([DfrPerson, DfrCircle1, DfrStore, DfrBook]) == [DfrCircle1, DfrStore, DfrPerson, DfrBook]     # test_dependency_sorting_dangling
    c12 = "Can't resolve dependencies for fixtures_regress.DfrCircle1, fixtures_regress.DfrCircle2 in serialized app list."
    @test_throws c12 sd([DfrPerson, DfrCircle2, DfrCircle1, DfrStore, DfrBook])          # test_dependency_sorting_tight_circular
    @test_throws c12 sd([DfrCircle1, DfrBook, DfrCircle2])                               # ..._tight_circular_2
    @test_throws "Can't resolve dependencies for fixtures_regress.DfrCircle3 in serialized app list." sd([DfrBook, DfrCircle3])
    @test_throws "Can't resolve dependencies for fixtures_regress.DfrCircle1, fixtures_regress.DfrCircle2, fixtures_regress.DfrCircle3 in serialized app list." sd([DfrPerson, DfrCircle2, DfrCircle1, DfrCircle3, DfrStore, DfrBook])
    @test sd([DfrPerson, DfrExternalDependency, DfrBook]) == [DfrPerson, DfrBook, DfrExternalDependency]   # test_dependency_sorting_normal
    @test length(sd([DfrCircle1, DfrCircle2]; allow_cycles = true)) == 2
end
