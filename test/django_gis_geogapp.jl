# Django's gis_tests geogapp tests, ported (#227): GeographyTest and GeographyFunctionTests, on PostGIS: geography
# fields (distances and areas on the spheroid, in metres).
# julia --project=test test/django_gis_geogapp.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Not translated: test05_geography_layermapping (LayerMapping reads shapefiles through GDAL: Juango has none),
# test_geodetic_area_raises_if_not_supported (PostGIS supports it). Juango's results are numbers (#306).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DggModels
using Juango, Juango.GIS
@model struct City
    name::String = CharField(max_length = 30)
    point = PointField(geography = true)
    Meta(app_label = "geogapp", table = "dgg_city")
end
@model struct CityUnique
    name::String = CharField(max_length = 30, default = "")
    point = PointField(geography = true, unique = true)
    Meta(app_label = "geogapp", table = "dgg_cityunique")
end
@model struct Zipcode
    name::String = CharField(max_length = 30, default = "")
    code::String = CharField(max_length = 10)
    poly = PolygonField(geography = true)
    Meta(app_label = "geogapp", table = "dgg_zipcode")
end
end
const DggCity, DggCityUnique, DggZipcode = DggModels.City, DggModels.CityUnique, DggModels.Zipcode

if IS_POSTGRES
redirect_stdout(devnull) do
    ms = [DggCity, DggCityUnique, DggZipcode]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django gis_tests geogapp: GeographyTest, GeographyFunctionTests" begin
  override_settings(FIXTURE_DIRS = [joinpath(@__DIR__, "gis_fixtures")]) do
    port_block() do
        loaddata("geogapp_initial")
        cities = objects(DggCity)
        # test01_fixture_load
        @test count(cities) == 8 && all(c -> c.point isa Point && c.point.srid == 4326, cities)
        # test02_distance_lookup: a polygon, on the spheroid
        z = get(objects(DggZipcode); code = "77002")
        for lk in (:point__distance_lte, :point__dwithin)
            @test collect(values_list(order_by(filter(cities; lk => (z.poly, D(mi = 500))), "name"), :name; flat = true)) ==
                  ["Dallas", "Houston", "Oklahoma City"]
        end
        # test_geography_unique: uniqueness is checked through geometry
        htown = get(cities; name = "Houston")
        create(DggCityUnique; point = htown.point)
        @test Juango.validate_unique(DggCityUnique(point = htown.point))[:point] == ["City unique with this Point already exists."]
        # test_operators_functions_unavailable_for_geography: geography cast to geometry for them
        @test count(filter(cities; point__within = z.poly)) == 1
        @test count(filter(cities; point__contained = z.poly)) == 1
        @test count(filter(cities; point__exact = htown.point)) == 1
        sqls = String[]
        Juango.execute_wrapper((ex, sql, ps, ctx) -> (push!(sqls, sql); ex(sql, ps))) do
            count(filter(cities; point__within = z.poly))
        end
        @test any(s -> occursin("ST_Within(CAST(\"dgg_city\".\"point\" AS geometry)", s), sqls)

        # GeographyFunctionTests: test_cast_aggregate (Extent of a geography field: through geometry)
        ext = aggregate(filter(cities; name__in = ["Houston", "Dallas"]); extent = Extent(:point))[:extent]
        @test all(isapprox.(ext, (-96.8016128540039, 29.7633724212646, -95.3631439208984, 32.782058715820); atol = 1e-4))
        # test_distance_function: a geography first is on the spheroid; a geometry first (4326), on a sphere
        qs = order_by(annotate(objects(DggZipcode); distance = Distance(:poly, htown.point), distance2 = Distance(htown.point, :poly)), "id")
        @test all(isapprox.([z.distance for z in qs], [0, 4891.20, 8071.64, 9123.95]; atol = 0.01))
        @test all(isapprox.([z.distance2 for z in qs], [0, 4899.68, 8081.30, 9115.15]; atol = 0.01))
        @test get(qs; distance__lte = 0).code == "77002"
        # test_geography_area: square metres
        a = get(annotate(objects(DggZipcode); area = Area(:poly)); code = "77002").area
        @test a - a % 1000 == 5439000
    end
  end
end
end
