# Django's fixtures_model_package tests, ported (#227): fixtures for a model defined in a nested module (Django's models
# package), loaded with loaddata from FIXTURE_DIRS.
# julia --project=test test/django_fixtures_model_package.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DfmpModels
using Juango, Dates
@model struct Article
    headline::String = CharField(max_length = 100, default = "Default headline")
    pub_date::DateTime = DateTimeField()
    Meta(app_label = "fixtures_model_package", table = "dfmp_article", ordering = ["-pub_date", "headline"])
end
end
redirect_stdout(devnull) do
    Juango.sync_models!([DfmpModels.Article]); push!(PORT_MODELS, DfmpModels.Article)
end
const DFMP_DIR = mktempdir()
write(joinpath(DFMP_DIR, "model_package_fixture1.json"), """[
    {"pk": "2", "model": "fixtures_model_package.article",
     "fields": {"headline": "Poker has no place on ESPN", "pub_date": "2006-06-16 12:00:00"}},
    {"pk": "3", "model": "fixtures_model_package.article",
     "fields": {"headline": "Time to reform copyright", "pub_date": "2006-06-16 13:00:00"}}
]""")
write(joinpath(DFMP_DIR, "model_package_fixture2.json"), """[
    {"pk": "3", "model": "fixtures_model_package.article",
     "fields": {"headline": "Copyright is fine the way it is", "pub_date": "2006-06-16 14:00:00"}},
    {"pk": "4", "model": "fixtures_model_package.article",
     "fields": {"headline": "Django conquers world!", "pub_date": "2006-06-16 15:00:00"}}
]""")
dfmp_headlines() = [a.headline for a in objects(DfmpModels.Article)]

@testset "django fixtures_model_package" begin
    override_settings(FIXTURE_DIRS = [DFMP_DIR]) do
        port_block() do
            # SampleTestCase.test_class_fixtures: a test's fixtures load into a model in a nested module
            loaddata("model_package_fixture1.json", "model_package_fixture2.json")
            @test dfmp_headlines() == ["Django conquers world!", "Copyright is fine the way it is", "Poker has no place on ESPN"]
        end
        port_block() do
            # FixtureTestCase.test_loaddata
            call_command("loaddata", "model_package_fixture1.json"; stdout = devnull)
            @test dfmp_headlines() == ["Time to reform copyright", "Poker has no place on ESPN"]
            call_command("loaddata", "model_package_fixture2.json"; stdout = devnull)     # (overwrites pk 3)
            @test dfmp_headlines() == ["Django conquers world!", "Copyright is fine the way it is", "Poker has no place on ESPN"]
            e = try call_command("loaddata", "unknown.json"; stdout = devnull); nothing catch err; err end
            @test e isa Juango.CommandError && occursin("No fixture named 'unknown' found.", sprint(showerror, e))
            @test dfmp_headlines() == ["Django conquers world!", "Copyright is fine the way it is", "Poker has no place on ESPN"]
        end
    end
end
