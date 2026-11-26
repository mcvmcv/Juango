# Django's proxy_model_inheritance tests, ported (#227): a proxy between a model and its multi-table child, and a
# proxy of that child. Not translated: test_table_exists (migrating apps found on sys.path; Juango's proxies make
# no tables, as orm.jl tests), model_utils (create_namedtuple_class: Python's).
# julia --project=test test/django_proxy_model_inheritance.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DpmConcreteModel
    Meta(table = "dpm_concretemodel")
end
@model struct DpmProxyModel <: DpmConcreteModel
    Meta(proxy = true)
end
@model struct DpmConcreteModelSubclass <: DpmProxyModel
    Meta(table = "dpm_concretemodelsubclass")
end
@model struct DpmConcreteModelSubclassProxy <: DpmConcreteModelSubclass
    Meta(proxy = true)
end
redirect_stdout(devnull) do
    ms = [DpmConcreteModel, DpmProxyModel, DpmConcreteModelSubclass, DpmConcreteModelSubclassProxy]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django proxy_model_inheritance: MultiTableInheritanceProxyTest" begin
    port_block() do
        # test_model_subclass_proxy: deleting the proxy of the child deletes down the whole chain
        instance = create(DpmConcreteModelSubclassProxy)
        delete!(instance)
        @test count(objects(DpmConcreteModelSubclassProxy)) == 0
        @test count(objects(DpmConcreteModelSubclass)) == 0
        @test count(objects(DpmConcreteModel)) == 0
        # test_deletion_through_intermediate_proxy
        child = create(DpmConcreteModelSubclass)
        proxy = get(DpmProxyModel; pk = child.pk)
        delete!(proxy)
        @test !exists(objects(DpmConcreteModel))
        @test !exists(objects(DpmConcreteModelSubclass))
    end
end
