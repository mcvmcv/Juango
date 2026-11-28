# Django's gis_tests distapp tests, ported (#227): DistanceTest and DistanceFunctionsTests, on PostGIS: distance
# lookups and the measurement functions on projected SRIDs (metres, US survey feet) and geodetic ones.
# julia --project=test test/django_gis_distapp.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Juango's Distance, Area, GeoLength (Length) and Perimeter give numbers, not Django's D and A (#306): metres for a
# geodetic geometry, else the SRID's units (a US-survey-feet SRID's distances in feet). Its dwithin on a geodetic
# field takes metres, not degrees (#307). Not translated: the tolerance parameter (Oracle's), MySQL's and
# SpatiaLite's differences, test_distance_function_raw_result (no geodetic support is PostGIS's case too).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DgdModels
using Juango, Juango.GIS
@model struct SouthTexasCity
    name::String = CharField(max_length = 30)
    point = PointField(srid = 32140)
    radius::Int = IntegerField(default = 10000)
    Meta(app_label = "distapp", table = "dgd_southtexascity")
end
@model struct SouthTexasCityFt
    name::String = CharField(max_length = 30)
    point = PointField(srid = 2278)
    Meta(app_label = "distapp", table = "dgd_southtexascityft")
end
@model struct AustraliaCity
    name::String = CharField(max_length = 30)
    point = PointField()
    radius::Int = IntegerField(default = 10000)
    allowed_distance::Float64 = FloatField(default = 0.5)
    ref_point = PointField(null = true)
    Meta(app_label = "distapp", table = "dgd_australiacity")
end
@model struct CensusZipcode
    name::String = CharField(max_length = 30)
    poly = PolygonField(srid = 4269)
    Meta(app_label = "distapp", table = "dgd_censuszipcode")
end
@model struct SouthTexasZipcode
    name::String = CharField(max_length = 30)
    poly = PolygonField(srid = 32140, null = true)
    Meta(app_label = "distapp", table = "dgd_southtexaszipcode")
end
@model struct Interstate
    name::String = CharField(max_length = 30)
    path = LineStringField()
    Meta(app_label = "distapp", table = "dgd_interstate")
end
@model struct SouthTexasInterstate
    name::String = CharField(max_length = 30)
    path = LineStringField(srid = 32140)
    Meta(app_label = "distapp", table = "dgd_southtexasinterstate")
end
end
const DgdSTCity, DgdSTCityFt, DgdAUCity = DgdModels.SouthTexasCity, DgdModels.SouthTexasCityFt, DgdModels.AustraliaCity
const DgdCensusZip, DgdSTZip = DgdModels.CensusZipcode, DgdModels.SouthTexasZipcode
const DgdInterstate, DgdSTInterstate = DgdModels.Interstate, DgdModels.SouthTexasInterstate

if IS_POSTGRES
redirect_stdout(devnull) do
    ms = [DgdSTCity, DgdSTCityFt, DgdAUCity, DgdCensusZip, DgdSTZip, DgdInterstate, DgdSTInterstate]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
dgd_names(qs) = sort([x.name for x in qs])
"A geometry in another SRID, by PostGIS (Django's geom.transform(srid, clone=True))."
dgd_transform(g, srid) = parse_wkt(only(collect(execute("SELECT ST_AsEWKT(ST_Transform(ST_GeomFromEWKT(?), $srid)) AS r", Any[ewkt(g)])))[:r])

@testset "django gis_tests distapp: DistanceTest, DistanceFunctionsTests" begin
  override_settings(FIXTURE_DIRS = [joinpath(@__DIR__, "gis_fixtures")]) do
    port_block() do
        loaddata("distapp_initial")
        stx_pnt = parse_wkt("POINT (-95.370401017314293 29.704867409475465)")
        au_pnt = parse_wkt("POINT (150.791 -34.4919)")
        stcity, stcityft, aucity = objects(DgdSTCity), objects(DgdSTCityFt), objects(DgdAUCity)
        # test_init
        @test (count(stcity), count(stcityft), count(aucity), count(objects(DgdSTZip)), count(objects(DgdCensusZip)),
               count(objects(DgdInterstate)), count(objects(DgdSTInterstate))) == (9, 9, 11, 4, 4, 1, 1)

        # test_dwithin: a D in the field's units (metres, or US survey feet), a number in the field's units
        for (d1, d2) in ((7000, 22965.83), (D(km = 7), D(km = 7)), (D(mi = 4.349), D(mi = 4.349)))
            @test dgd_names(filter(stcity; point__dwithin = (stx_pnt, d1))) == ["Downtown Houston", "Southside Place"]
            @test dgd_names(filter(stcityft; point__dwithin = (stx_pnt, d2))) == ["Downtown Houston", "Southside Place"]
        end
        @test !exists(exclude(stcity; point__dwithin = (GeoUnion(:point, :point), 0)))
        # (a geodetic field: metres, D or a number, #307; Django takes degrees there and refuses a D)
        au = ["Mittagong", "Shellharbour", "Thirroul", "Wollongong"]
        for d in (32000, D(km = 32), D(mi = 19.884))
            @test dgd_names(filter(aucity; point__dwithin = (au_pnt, d))) == au
        end
        @test_broken dgd_names(filter(aucity; point__dwithin = (au_pnt, 0.5))) == au       # (degrees, as Django: #307)

        # test_distance_lookups: a donut, in either SRID
        for M in (DgdSTCity, DgdSTCityFt)
            qs = filter(filter(objects(M); point__distance_gte = (stx_pnt, D(km = 7))); point__distance_lte = (stx_pnt, D(km = 20)))
            @test dgd_names(qs) == ["Bellaire", "Pearland", "West University Place"]
        end
        z = get(objects(DgdSTZip); name = "77005")
        @test dgd_names(filter(exclude(objects(DgdSTZip); name = "77005"); poly__distance_lte = (z.poly, D(m = 275)))) == ["77025", "77401"]
        @test dgd_names(filter(exclude(objects(DgdSTZip); name = "77005"); poly__distance_lte = (z.poly, D(m = 300)))) == ["77002", "77025", "77401"]

        # test_geodetic_distance_lookups
        line = parse_wkt("LINESTRING(144.9630 -37.8143,151.2607 -33.8870)")
        @test dgd_names(filter(aucity; point__distance_lte = (line, D(km = 100)))) ==
              ["Batemans Bay", "Canberra", "Hillsdale", "Melbourne", "Mittagong", "Shellharbour", "Sydney", "Thirroul", "Wollongong"]
        e = try collect(filter(aucity; point__distance_lte = ("POINT(5 23)", D(km = 100), "spheroid", "4", nothing))) catch err; err end
        @test e isa ArgumentError && e.msg == "2, 3, or 4-element tuple required for 'distance_lte' lookup."
        e = try collect(filter(aucity; point__distance_lte = ("POINT(5 23)",))) catch err; err end
        @test e isa ArgumentError && e.msg == "2, 3, or 4-element tuple required for 'distance_lte' lookup."
        e = try collect(filter(aucity; point__distance_lte = ("POINT(5 23)", D(km = 100), "spheroid", "4"))) catch err; err end
        @test e isa ArgumentError && e.msg == "For 4-element tuples the last argument must be the 'spheroid' directive."
        hobart = get(aucity; name = "Hobart")
        @test dgd_names(filter(exclude(aucity; name = "Hobart"); point__distance_lte = (hobart.point, D(mi = 550)))) ==
              ["Batemans Bay", "Canberra", "Melbourne"]
        wollongong = get(aucity; name = "Wollongong")
        d1, d2 = D(yd = 19500), D(nm = 400)
        for sph in ((), ("spheroid",))
            q = Q(point__distance_lte = (wollongong.point, d1, sph...)) | Q(point__distance_gte = (wollongong.point, d2, sph...))
            @test dgd_names(filter(exclude(aucity; name = "Wollongong"), q)) == ["Adelaide", "Hobart", "Shellharbour", "Thirroul"]
        end

        # test_distance_lookups_with_expression_rhs: the distance an expression, in the field's units
        stx32140 = dgd_transform(stx_pnt, 32140)
        @test dgd_names(filter(stcity; point__distance_lte = (stx32140, F(:radius)))) ==
              ["Bellaire", "Downtown Houston", "Southside Place", "West University Place"]
        r2 = dgd_names(filter(stcity; point__distance_lte = (stx32140, F(:radius) * 2)))
        @test length(r2) == 5 && "Pearland" in r2
        update!(aucity; ref_point = hobart.point)
        for ref in (hobart.point, F(:ref_point))
            @test dgd_names(filter(aucity; point__distance_lte = (ref, F(:radius) * 70, "spheroid"))) == ["Canberra", "Hobart", "Melbourne"]
        end
        @test !exists(filter(stcity; point__distance_gt = (GeoUnion(:point, :point), 0)))
        @test count(filter(stcity; point__distance_lte = (GeoUnion(:point, :point), 0))) == count(stcity)

        # test_distance_annotation_group_by
        rel = Case(When(Q(point__distance_lte = (stx32140, D(km = 20))); then = Value(20)); default = Value(100))
        rows = collect(annotate(values(annotate(stcity; relative_distance = rel), :relative_distance); count = Count(:pk)))
        @test sort([(r[:relative_distance], r[:count]) for r in rows]) == [(20, 5), (100, 4)]
        # test_dwithin_subquery: OuterRef to a geometry in another SRID
        qs = filter(annotate(objects(DgdCensusZip); v = Exists(filter(stcity; point__dwithin = (OuterRef(:poly), D(m = 10))))); v = true)
        @test dgd_names(qs) == ["77002", "77025", "77401"]
        # test_dwithin_with_expression_rhs: the distance an expression (metres on a geodetic field, #307)
        ls = LineString([(150.902, -34.4245), (138.6, -34.9258)])
        @test dgd_names(filter(aucity; point__dwithin = (ls, F(:allowed_distance) * 111_000))) ==
              ["Adelaide", "Mittagong", "Shellharbour", "Thirroul", "Wollongong"]

        # DistanceFunctionsTests: test_area (square metres of a projected SRID)
        areas = [a.area for a in order_by(annotate(objects(DgdSTZip); area = Area(:poly)), "name")]
        @test all(isapprox.(areas, [5437908.90234375, 10183031.4389648, 11254471.0073242, 9881708.91772461]; atol = 0.01))
        # test_distance_simple
        lagrange32140 = parse_wkt("POINT(805066.295722839 4231496.29461335)"; srid = 32140)
        @test isapprox(first(order_by(annotate(stcity; dist = Distance(:point, lagrange32140)), "id")).dist, 147075.069813; atol = 1e-5)
        # test_distance_projected: the field's units (metres; US survey feet)
        lagrange = parse_wkt("POINT(-96.876369 29.905320)")
        m_d = [147075.069813, 139630.198056, 140888.552826, 138809.684197, 158309.246259, 212183.594374, 70870.188967, 165337.758878, 139196.085105]
        ft_d = [482528.79154625, 458103.408123001, 462231.860397575, 455411.438904354, 519386.252102563, 696139.009211594,
                232513.278304279, 542445.630586414, 456679.155883207]
        @test all(isapprox.([c.distance for c in order_by(annotate(stcity; distance = Distance(:point, lagrange)), "id")], m_d; atol = 10))
        @test all(isapprox.([c.distance for c in order_by(annotate(stcityft; distance = Distance(:point, lagrange)), "id")], ft_d; atol = 10))
        @test all(isapprox.(ft_d .* (1200 / 3937), m_d; atol = 10))          # (feet, the same distances)
        # test_distance_geodetic: metres on a sphere, to a line
        ls2 = LineString([(150.902, -34.4245), (150.87, -34.5789)])
        dists = [1120954.92533513, 140575.720018241, 640396.662906304, 60580.9693849269, 972807.955955075, 568451.8357838,
                 40435.4335201384, 0, 68272.3896586844, 12375.0643697706, 0]
        @test all(isapprox.([c.distance for c in order_by(annotate(aucity; distance = Distance(:point, ls2)), "name")], dists; atol = 1))
        # test_distance_geodetic_spheroid
        hillsdale = get(aucity; name = "Hillsdale")
        sph = [60504.0628957201, 77023.9489850262, 49154.8867574404, 90847.4358768573, 217402.811919332, 709599.234564757,
               640011.483550888, 7772.00667991925, 1047861.78619339, 1165126.55236034]
        sphere = [60580.9693849267, 77144.0435286473, 49199.4415344719, 90804.7533823494, 217713.384600405, 709134.127242793,
                  639828.157159169, 7786.82949717788, 1049204.06569028, 1162623.7238134]
        qs = order_by(exclude(aucity; id = hillsdale.id), "id")
        @test all(isapprox.([c.d for c in annotate(qs; d = Distance(:point, hillsdale.point; spheroid = true))], sph; atol = 1e-4))
        @test all(isapprox.([c.d for c in annotate(qs; d = Distance(:point, hillsdale.point))], sphere; atol = 1e-4))
        # test_distance_function_d_lookup: a D against a distance in metres
        @test exists(filter(annotate(objects(DgdInterstate); d = Distance(Point(0, 0; srid = 3857), Point(0, 1; srid = 3857))); d = D(m = 1)))
        # test_distance_transform: Transform first, the other geometry in either SRID
        z = get(objects(DgdSTZip); name = "77005")
        buf1 = parse_wkt(only(collect(execute("SELECT ST_AsEWKT(ST_Buffer(ST_Centroid(ST_GeomFromEWKT(?)), 100)) AS r", Any[ewkt(z.poly)])))[:r])
        buf2 = dgd_transform(buf1, 4269)
        for buf in (buf1, buf2)
            qs = order_by(annotate(exclude(objects(DgdCensusZip); name = "77005"); distance = Distance(Transform(:poly, 32140), buf)), "name")
            @test [c.name for c in qs] == ["77002", "77025", "77401"]
            @test all(isapprox.([c.distance for c in qs], [3553.30384972258, 1243.18391525602, 2186.15439472242]; atol = 1e-4))
        end
        # test_distance_order_by
        @test collect(values_list(filter(order_by(annotate(stcity; distance = Distance(:point, Point(3, 3; srid = 32140))), "distance");
                                         name__in = ["San Antonio", "Pearland"]), :name; flat = true)) == ["San Antonio", "Pearland"]
        # test_length: geodetic (the spheroid) and projected; Length is the same function as the text one's
        @test isapprox(first(annotate(objects(DgdInterstate); length = Length(:path))).length, 473504.769553813; atol = 1)
        @test isapprox(first(annotate(objects(DgdInterstate); length = GeoLength(:path))).length, 473504.769553813; atol = 1)
        i10 = get(annotate(objects(DgdSTInterstate); length = Length(:path)); name = "I-10")
        @test isapprox(i10.length, 4617.668; atol = 0.01)
        @test exists(filter(annotate(objects(DgdSTInterstate); length = GeoLength(:path)); length__gt = 4000))
        @test isapprox(first(annotate(objects(DgdInterstate); length = GeoLength(i10.path))).length, 4617.668; atol = 0.01)
        # test_perimeter
        per = [p.perimeter for p in order_by(annotate(objects(DgdSTZip); perimeter = Perimeter(:poly)), "name")]
        @test all(isapprox.(per, [18404.3550889361, 15627.2108551001, 20632.5588368978, 17094.5996143697]; atol = 1e-7))
        @test all(c -> c.perim == 0, annotate(stcity; perim = Perimeter(:point)))
        # test_perimeter_geodetic: Juango measures a geodetic geometry's perimeter (metres, through geography; Django's
        # PostGIS backend refuses it); and transformed to a projected SRID
        @test isapprox(first(annotate(filter(objects(DgdCensusZip); name = "77002"); perim = Perimeter(:poly))).perim, 18406.38; atol = 5)
        @test isapprox(first(annotate(filter(objects(DgdCensusZip); name = "77002"); perim = Perimeter(Transform(:poly, 32140)))).perim, 18404.355; atol = 1e-3)
        # test_measurement_null_fields
        create(DgdSTZip; name = "78212")
        htown = get(stcity; name = "Downtown Houston")
        z = get(annotate(objects(DgdSTZip); distance = Distance(:poly, htown.point), area = Area(:poly)); name = "78212")
        @test z.distance === nothing && z.area === nothing
        # (#306: Django's results are measures)
        @test_broken first(annotate(stcity; d = Distance(:point, lagrange))).d isa D
    end
  end
end
end
