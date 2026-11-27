# Django's model_package tests, ported (#227): ModelPackageTests. Django's models split into a package's modules are
# models defined in modules nested in another (DmpModels.Article, DmpModels.Publication), which take the app of the
# outer module.
# julia --project=test test/django_model_package.jl   (see setup.jl)
#
# Not translated: admin_autodiscover (Juango's apps include their own admin.jl; there's no autodiscover() to call twice),
# no_models (an app without models: nothing to test without Django's app loading).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DmpModels
module Publication
using Juango
@model struct DmpPublication
    title::String = CharField(max_length = 30)
    Meta(table = "dmp_publication")
end
end
module Article
using Juango
using ..Publication: DmpPublication
@model struct DmpSite
    name::String = CharField(max_length = 255)
    Meta(table = "dmp_site")
end
@model struct DmpArticle
    sites = ManyToManyField(DmpSite)
    headline::String = CharField(max_length = 100)
    publications = ManyToManyField(DmpPublication, blank = true)
    Meta(table = "dmp_article")
end
end
end
using .DmpModels.Publication: DmpPublication
using .DmpModels.Article: DmpSite, DmpArticle
@model struct DmpAdvertisement                       # (a model in the test module itself, #12245)
    customer::String = CharField(max_length = 100)
    publications = ManyToManyField(DmpPublication, blank = true)
    Meta(table = "dmp_advertisement")
end
redirect_stdout(devnull) do
    ms = [DmpPublication, DmpSite, DmpArticle, through(DmpArticle, :sites), through(DmpArticle, :publications),
          DmpAdvertisement, through(DmpAdvertisement, :publications)]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django model_package: ModelPackageTests" begin
    port_block() do
        # test_m2m_tables_in_subpackage_models (#12168)
        p = create(DmpPublication; title = "FooBar")
        site = create(DmpSite; name = "example.com")
        a = create(DmpArticle; headline = "a foo headline")
        add!(a.publications, p)
        add!(a.sites, site)
        a = only(collect(filter(DmpArticle; id = a.id)))
        @test a.id == a.pk
        @test count(a.sites) == 1
        # test_models_in_the_test_package (#12245)
        ad = create(DmpAdvertisement; customer = "Lawrence Journal-World")
        add!(ad.publications, p)
        ad = only(collect(filter(DmpAdvertisement; id = ad.id)))
        @test count(ad.publications) == 1
    end
    # test_automatic_m2m_column_names (#12386): the join model's keys and columns carry no module path
    Th = through(DmpArticle, :publications)
    fks = [f for f in Juango.modelmeta(Th).fields if f.kind === :fk]
    @test [f.name for f in fks] == [:dmparticle, :dmppublication]
    @test [Juango.column(f) for f in fks] == ["dmparticle_id", "dmppublication_id"]
    @test Juango.modelmeta(Th).table == "dmp_article_publications"
    @test Juango.modelmeta(DmpArticle).app == Juango.modelmeta(DmpPublication).app == Juango.modelmeta(DmpAdvertisement).app
end
