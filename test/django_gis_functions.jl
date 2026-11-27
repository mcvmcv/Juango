# Django's gis_tests geoapp test_functions, ported (#227): GISFunctionsTests, on PostGIS. Django's tests check the
# database's results against GEOS on the Python side (`c.mpoly.difference(geom).equals(c.diff)`); Juango's geometries
# are plain values without GEOS, so those checks ask PostGIS (`dgf_sql`) or compare coordinates.
# julia --project=test test/django_gis_functions.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Not translated: test_make_valid_output_field (Juango's expressions have no output_field objects: a GIS function's
# geometries come back as geometries), test_num_dimensions' 3D feature (Juango's geometries are 2D), and
# test_argument_validation's "SRID is required" (a Juango geometry always has one). Union is GeoUnion (Julia's Union).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DgfModels
using Juango, Juango.GIS
@model struct Country
    name::String = CharField(max_length = 30)
    mpoly = MultiPolygonField()
    Meta(app_label = "geoapp", table = "dgf_country")
end
@model struct CountryWebMercator
    name::String = CharField(max_length = 30)
    mpoly = MultiPolygonField(srid = 3857)
    Meta(app_label = "geoapp", table = "dgf_countrywm")
end
@model struct City
    name::String = CharField(max_length = 30)
    point = PointField()
    Meta(app_label = "geoapp", table = "dgf_city")
end
@model struct State
    name::String = CharField(max_length = 30)
    poly = PolygonField(null = true)
    Meta(app_label = "geoapp", table = "dgf_state")
end
@model struct Track
    name::String = CharField(max_length = 30)
    line = LineStringField()
    Meta(app_label = "geoapp", table = "dgf_track")
end
@model struct Feature
    name::String = CharField(max_length = 30)
    geom = GeometryField()
    Meta(app_label = "geoapp", table = "dgf_feature")
end
@model struct ManyPointModel
    name::String = CharField(max_length = 30)
    point1 = PointField()
    point2 = PointField()
    point3 = PointField(srid = 3857)
    Meta(app_label = "geoapp", table = "dgf_manypoint")
end
end
# (aliases: orm.jl has its own City)
const DgfCountry = DgfModels.Country
const DgfCountryWebMercator = DgfModels.CountryWebMercator
const DgfCity = DgfModels.City
const DgfState = DgfModels.State
const DgfTrack = DgfModels.Track
const DgfFeature = DgfModels.Feature
const DgfManyPointModel = DgfModels.ManyPointModel

"PostGIS's answer for an expression of geometries (each `\$G` a geometry argument): GEOS on Django's side."
const G = "ST_GeomFromEWKT(?)"
dgf_sql(expr, gs::Juango.Geometry...) = only(collect(execute("SELECT $expr AS r", Any[ewkt(g) for g in gs])))[:r]
dgf_equals(a, b) = dgf_sql("ST_Equals($G, $G)", a, b) == true
dgf_get(qs, name) = only(collect(filter(qs; name = name)))

if !IS_POSTGRES
    @testset "django gis_tests geoapp: GIS functions (PostGIS only)" begin
        @test_throws Juango.ImproperlyConfigured Juango.geometry_column_type(Juango.backend(), :POINT)
    end
else
redirect_stdout(devnull) do
    ms = [DgfCountry, DgfCountryWebMercator, DgfCity, DgfState, DgfTrack, DgfFeature, DgfManyPointModel]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
const DGF_FIXTURES = joinpath(@__DIR__, "gis_fixtures")

@testset "django gis_tests geoapp: GISFunctionsTests" begin
  override_settings(FIXTURE_DIRS = [DGF_FIXTURES]) do
    port_block() do
        @test loaddata("geoapp_initial") == 12                    # (a gzipped fixture, as Django's)
        cities, countries, states = objects(DgfCity), objects(DgfCountry), objects(DgfState)

        # test_asgeojson
        @test JSON.parse(dgf_get(annotate(cities; json = AsGeoJSON(:point)), "Pueblo").json) ==
              JSON.parse("""{"type":"Point","coordinates":[-104.609252,38.255001]}""")
        @test JSON.parse(dgf_get(annotate(cities; json = AsGeoJSON(:point; crs = true)), "Houston").json) ==
              JSON.parse("""{"type":"Point","crs":{"type":"name","properties":{"name":"EPSG:4326"}},"coordinates":[-95.363151,29.763374]}""")
        @test JSON.parse(dgf_get(annotate(cities; json = AsGeoJSON(:point; bbox = true)), "Victoria").json) ==
              JSON.parse("""{"type":"Point","bbox":[-123.305196,48.462611,-123.305196,48.462611],"coordinates":[-123.305196,48.462611]}""")
        chicago = JSON.parse(dgf_get(annotate(cities; json = AsGeoJSON(:point; bbox = true, crs = true, precision = 5)), "Chicago").json)
        @test chicago["crs"]["properties"]["name"] == "EPSG:4326" && chicago["bbox"] == [-87.65018, 41.85039, -87.65018, 41.85039] ||
              chicago["bbox"] == [-87.65018, 41.85038, -87.65018, 41.85038]
        @test chicago["coordinates"] in ([-87.65018, 41.85039], [-87.65018, 41.85038])
        @test_throws ArgumentError AsGeoJSON(:point; precision = "foo")    # (precision is an integer)
        # test_asgeojson_option_0: no CRS for another SRID either
        create(DgfManyPointModel; name = "m", point1 = Point(1, 1), point2 = Point(-87.65018, 41.85039),
               point3 = Point(-9757173.40553877, 5138594.87034608; srid = 3857))
        @test JSON.parse(only(collect(annotate(objects(DgfManyPointModel); json = AsGeoJSON(:point3)))).json) ==
              JSON.parse("""{"type":"Point","coordinates":[-9757173.40553877,5138594.87034608]}""")

        # test_asgml
        @test_throws ArgumentError collect(annotate(cities; gml = AsGML(:name)))      # (not a geometry field)
        @test occursin(r"^<gml:Point srsName=\"(urn:ogc:def:crs:)?EPSG:4326\"><gml:coordinates>-104\.60925\d+,38\.255001</gml:coordinates></gml:Point>",
                       dgf_get(annotate(cities; gml = AsGML(:point; precision = 9)), "Pueblo").gml)
        @test occursin("<gml:pos srsDimension=\"2\">", dgf_get(annotate(cities; gml = AsGML(:point; version = 3)), "Pueblo").gml)
        # test_askml
        @test_throws ArgumentError collect(annotate(cities; kml = AsKML(:name)))
        @test dgf_get(annotate(cities; kml = AsKML(:point; precision = 9)), "Pueblo").kml ==
              "<Point><coordinates>-104.609252,38.255001</coordinates></Point>"
        # test_assvg
        @test_throws ArgumentError AsSVG(:point; precision = "foo")
        @test dgf_get(annotate(cities; svg = AsSVG(:point)), "Pueblo").svg == "cx=\"-104.609252\" cy=\"-38.255001\""
        @test dgf_get(annotate(cities; svg = AsSVG(:point; relative = 5)), "Pueblo").svg == "x=\"-104.609252\" y=\"-38.255001\""
        # test_aswkb / test_aswkt
        wkb = first(annotate(cities; wkb = AsWKB(Point(1, 2)))).wkb
        @test wkb in (UInt8[0x00, 0x00, 0x00, 0x00, 0x01, 0x3f, 0xf0, 0, 0, 0, 0, 0, 0, 0x40, 0, 0, 0, 0, 0, 0, 0],
                      UInt8[0x01, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xf0, 0x3f, 0, 0, 0, 0, 0, 0, 0, 0x40])
        @test first(annotate(cities; wkt = AsWKT(Point(1, 2)))).wkt == "POINT(1 2)"
        # test_azimuth: radians; nothing for the same point
        @test isapprox(first(annotate(cities; az = Azimuth(Point(0, 0), Point(1, 1)))).az, pi / 4; atol = 0.01)
        @test first(annotate(cities; az = Azimuth(Point(0, 0), Point(0, 0)))).az === nothing

        # test_bounding_circle
        circ = first(order_by(annotate(countries; circle = BoundingCircle(:mpoly)), "name")).circle
        @test round(dgf_sql("ST_Area($G)", circ)) == 169 && num_points(circ) == 4 * 48 + 1
        for ns in (12, Value(12))
            circ = first(order_by(annotate(countries; circle = BoundingCircle(:mpoly; num_seg = ns)), "name")).circle
            @test 168.4 < dgf_sql("ST_Area($G)", circ) < 169.5 && num_points(circ) == 4 * 12 + 1
        end
        # test_centroid
        for st in annotate(filter(states; poly__isnull = false); centroid = Centroid(:poly))
            @test st.centroid isa Point && dgf_sql("ST_Distance(ST_Centroid($G), $G)", st.poly, st.centroid) < 0.00001
        end
        @test_throws MethodError Centroid(:poly, :poly)                # ('Centroid' takes exactly 1 argument)
        # test_difference / test_difference_mixed_srid: a geometry in another SRID is transformed to the field's
        geom = Point(5, 23)
        for c in annotate(countries; diff = Difference(:mpoly, geom))
            @test dgf_sql("ST_Equals(ST_Difference($G, $G), $G)", c.mpoly, geom, c.diff) && c.diff.srid == 4326
        end
        merc = Point(556597.4, 2632018.6; srid = 3857)
        for c in annotate(countries; diff = Difference(:mpoly, merc))
            @test dgf_sql("ST_Equals(ST_Difference($G, ST_Transform($G, 4326)), $G)", c.mpoly, merc, c.diff) && c.diff.srid == 4326
        end
        # test_envelope
        for c in annotate(countries; envelope = Envelope(:mpoly))
            @test c.envelope isa Polygon && dgf_equals(c.envelope, parse_wkt(dgf_sql("ST_AsEWKT(ST_Envelope($G))", c.mpoly)))
            @test extent(c.envelope) == extent(c.mpoly)
        end
        # test_force_polygon_cw
        create(DgfState; name = "Foo", poly = Polygon([[(0, 0), (5, 0), (0, 5), (0, 0)], [(1, 1), (1, 3), (3, 1), (1, 1)]]))
        @test dgf_get(annotate(states; cw = ForcePolygonCW(:poly)), "Foo").cw.rings ==
              [[(0.0, 0.0), (0.0, 5.0), (5.0, 0.0), (0.0, 0.0)], [(1.0, 1.0), (3.0, 1.0), (1.0, 3.0), (1.0, 1.0)]]
        delete!(filter(states; name = "Foo"))
        # test_fromwkb / test_fromwkt: no SRID (0) unless given
        g = Point(56.811078, 60.608647)
        wkbg = vcat(UInt8[0x01], reinterpret(UInt8, [htol(UInt32(1))]), reinterpret(UInt8, htol.([g.x, g.y])))
        r = first(annotate(cities; p1 = FromWKB(Value(wkbg)), p2 = FromWKB(Value(wkbg); srid = 4326)))
        @test isapprox(r.p1, Point(g.x, g.y; srid = 0); atol = 0.00001) && r.p1.srid == 0 && r.p2.srid == 4326
        r = first(annotate(cities; p1 = FromWKT(Value(wkt(g))), p2 = FromWKT(Value(wkt(g)); srid = 4326)))
        @test isapprox(r.p1, Point(g.x, g.y; srid = 0); atol = 0.00001) && r.p1.srid == 0 && r.p2 == g
        # test_geohash
        @test startswith(dgf_get(annotate(cities; h = GeoHash(:point)), "Houston").h, "9vk1mfq8jx0c8e0386z6")
        @test dgf_get(annotate(cities; h = GeoHash(:point; precision = 5)), "Houston").h == "9vk1m"
        # test_geometry_distance
        ds = [c.distance for c in order_by(annotate(cities; distance = GeometryDistance(:point, Point(-90, 40))), "distance")]
        @test all(isapprox.(ds, [2.99091995527296, 5.33507274054713, 9.33852187483721, 9.91769193646233,
                                 11.556465744884, 14.713098433352, 34.3635252198568, 276.987855073372]; atol = 1e-7))
        # test_intersection: an empty geometry
        @test all(c -> isempty(c.inter), annotate(countries; inter = Intersection(:mpoly, geom)))
        # test_isempty_geometry_empty
        empty_ = create(DgfCity; name = "Nowhere", point = Point(NaN, NaN))
        create(DgfCity; name = "Somewhere", point = Point(6.825, 47.1))
        @test [c.id for c in filter(annotate(cities; isempty = IsEmpty(:point)); isempty = true)] == [empty_.id]
        @test [c.id for c in filter(cities; point__isempty = true)] == [empty_.id]
        @test isempty(get(DgfCity; id = empty_.id).point)
        delete!(filter(cities; name__in = ["Nowhere", "Somewhere"]))
        # test_isempty_geometry_null
        nowhere = create(DgfState; name = "Nowhere", poly = nothing)
        qs = annotate(states; isempty = IsEmpty(:poly))
        @test [s.id for s in filter(qs; isempty__isnull = true)] == [nowhere.id]
        @test collect(values_list(order_by(filter(qs; isempty = false), "name"), :name; flat = true)) == ["Colorado", "Kansas"]
        @test isempty(collect(filter(qs; isempty = true))) && isempty(collect(filter(states; poly__isempty = true)))
        delete!(filter(states; name = "Nowhere"))
        # test_isvalid (and the isvalid lookup)
        create(DgfState; name = "valid", poly = parse_wkt("POLYGON((0 0, 0 1, 1 1, 1 0, 0 0))"))
        create(DgfState; name = "invalid", poly = parse_wkt("POLYGON((0 0, 0 1, 1 1, 1 0, 1 1, 1 0, 0 0))"))
        @test dgf_get(annotate(states; v = IsValid(:poly)), "valid").v === true
        @test dgf_get(annotate(states; v = IsValid(:poly)), "invalid").v === false
        @test collect(values_list(filter(states; poly__isvalid = false), :name; flat = true)) == ["invalid"]
        # test_make_valid
        repaired = dgf_get(annotate(states; r = MakeValid(:poly)), "invalid").r
        @test dgf_sql("ST_IsValid($G)", repaired) && dgf_equals(repaired, parse_wkt("POLYGON((0 0, 0 1, 1 1, 1 0, 0 0))"))
        delete!(filter(states; name__in = ["valid", "invalid"]))
        # test_make_valid_multipolygon: a polygon whose hole is outside becomes two polygons
        create(DgfState; name = "invalid", poly = parse_wkt("POLYGON((0 0, 0 1 , 1 1 , 1 0, 0 0), (10 0, 10 1, 11 1, 11 0, 10 0))"))
        repaired = only(collect(annotate(filter(states; name = "invalid"); r = MakeValid(:poly)))).r
        @test repaired isa MultiPolygon && length(repaired.geoms) == 2 && dgf_sql("ST_IsValid($G)", repaired) &&
              dgf_equals(repaired, parse_wkt("MULTIPOLYGON(((0 0, 0 1, 1 1, 1 0, 0 0)), ((10 0, 10 1, 11 1, 11 0, 10 0)))"))
        delete!(filter(states; name = "invalid"))

        # test_area_with_regular_aggregate / test_area_lookups (in a projected SRID: square metres)
        for c in annotate(countries; t = Transform(:mpoly, 3857))
            @test c.t.srid == 3857
            create(DgfCountryWebMercator; name = c.name, mpoly = c.t)
        end
        for c in defer(annotate(objects(DgfCountryWebMercator); area_sum = Sum(Area(:mpoly))), :mpoly)
            @test isapprox(c.area_sum, dgf_sql("ST_Area($G)", c.mpoly); rtol = 1e-9)
        end
        qs = annotate(objects(DgfCountryWebMercator); area = Area(:mpoly))
        @test only(collect(filter(qs; area__lt = A(sq_km = 500000)))).name == "New Zealand"
        @test only(collect(filter(qs; area__lt = 500000e6))).name == "New Zealand"       # (and square metres: Area is a number)
        # test_closest_point
        for c in annotate(countries; cp = ClosestPoint(:mpoly, Centroid(:mpoly)))
            @test c.cp isa Point && dgf_sql("ST_Equals(ST_Intersection($G, $G), $G)", c.mpoly, c.cp, c.cp)
        end
        # test_line_locate_point
        @test isapprox(first(annotate(states; pos = LineLocatePoint(LineString([(0, 0), (0, 3)]), Point(0, 1)))).pos, 1 / 3; atol = 1e-7)
        # test_memsize
        @test 20 <= dgf_get(annotate(cities; size = MemSize(:point)), "Pueblo").size <= 105
        # test_num_geom / test_num_dimensions / test_num_points
        @test all(c -> c.n == 2, annotate(countries; n = NumGeometries(:mpoly)))
        @test all(c -> c.n == 1, annotate(filter(cities; point__isnull = false); n = NumGeometries(:point)))
        @test all(c -> c.n == 2, annotate(countries; n = NumDimensions(:mpoly)))
        create(DgfTrack; name = "Foo", line = LineString([(-95.363151, 29.763374), (-95.448601, 29.713803)]))
        @test first(annotate(objects(DgfTrack); n = NumPoints(:line))).n == 2
        @test all(c -> c.n == num_points(c.mpoly), annotate(countries; n = NumPoints(:mpoly)))
        @test all(c -> c.n == 1, annotate(cities; n = NumPoints(:point)))
        # test_point_on_surface
        @test all(c -> dgf_sql("ST_Intersects($G, $G)", c.mpoly, c.pos), annotate(countries; pos = PointOnSurface(:mpoly)))
        # test_reverse_geom (the same Reverse as the text function's)
        @test dgf_get(annotate(objects(DgfTrack); r = Reverse(:line)), "Foo").r.coords == [(-95.448601, 29.713803), (-95.363151, 29.763374)]
        @test dgf_get(annotate(objects(DgfTrack); r = Reverse(Centroid(:line))), "Foo").r isa Point

        # test_rotate / test_rotate_invalid_params
        for (kw, o) in (((;), (0, 0)), ((; origin = Point(0, 0)), (0, 0)), ((; origin = Point(1, 1)), (1, 1)))
            for c in annotate(countries; rotated = Rotate(:mpoly, pi; kw...))
                ok = true
                for (p1, p2) in zip(c.mpoly.geoms, c.rotated.geoms), (r1, r2) in zip(p1.rings, p2.rings), (c1, c2) in zip(r1, r2)
                    ok &= isapprox(-c1[1] + 2 * o[1], c2[1]; atol = 1e-5) && isapprox(-c1[2] + 2 * o[2], c2[2]; atol = 1e-5)
                end
                @test ok
            end
        end
        for bad in (0, [0, 0])
            e = try Rotate(:mpoly, pi; origin = bad) catch err; err end
            @test e isa ArgumentError && e.msg == "origin argument must be a Point"
        end
        # test_scale / test_translate
        for c in annotate(countries; scaled = Scale(:mpoly, 2, 3), moved = Translate(:mpoly, 5, -23))
            ok = true
            for (p1, p2, p3) in zip(c.mpoly.geoms, c.scaled.geoms, c.moved.geoms), (r1, r2, r3) in zip(p1.rings, p2.rings, p3.rings),
                (c1, c2, c3) in zip(r1, r2, r3)
                ok &= isapprox(c1[1] * 2, c2[1]; atol = 1e-5) && isapprox(c1[2] * 3, c2[2]; atol = 1e-5) &&
                      isapprox(c1[1] + 5, c3[1]; atol = 1e-5) && isapprox(c1[2] - 23, c3[2]; atol = 1e-5)
            end
            @test ok
        end
        c = first(annotate(countries; scaled = Scale(:mpoly, 1.5, parse(Juango.Decimal, "2.5"))))
        @test dgf_sql("ST_Area($G)", c.scaled) > dgf_sql("ST_Area($G)", c.mpoly)
        # test_snap_to_grid
        for bad in ((), (1, 2, 3), (1, 2, 3, 4, 5))
            @test_throws ArgumentError SnapToGrid(:mpoly, bad...)
        end
        for bad in (("1.0",), (1.0, nothing), ("0", "1", "2", "3"))
            @test_throws ArgumentError SnapToGrid(:mpoly, bad...)
        end
        create(DgfCountry; name = "San Marino", mpoly = parse_wkt(
            "MULTIPOLYGON(((12.41580 43.95795,12.45055 43.97972,12.45389 43.98167,12.46250 43.98472,12.47167 43.98694,12.49278 43.98917," *
            "12.50555 43.98861,12.51000 43.98694,12.51028 43.98277,12.51167 43.94333,12.51056 43.93916,12.49639 43.92333," *
            "12.49500 43.91472,12.48778 43.90583,12.47444 43.89722,12.46472 43.89555,12.45917 43.89611,12.41639 43.90472," *
            "12.41222 43.90610,12.40782 43.91366,12.40389 43.92667,12.40500 43.94833,12.40889 43.95499,12.41580 43.95795)))"))
        snap(args...) = dgf_get(annotate(countries; snap = SnapToGrid(:mpoly, args...)), "San Marino").snap
        @test isapprox(parse_wkt("MULTIPOLYGON(((12.4 44,12.5 44,12.5 43.9,12.4 43.9,12.4 44)))"), snap(0.1); atol = 1e-9)
        @test isapprox(parse_wkt("MULTIPOLYGON(((12.4 43.93,12.45 43.93,12.5 43.93,12.45 43.93,12.4 43.93)))"), snap(0.05, 0.23); atol = 1e-9)
        @test isapprox(parse_wkt("MULTIPOLYGON(((12.4 43.87,12.45 43.87,12.45 44.1,12.5 44.1,12.5 43.87,12.45 43.87,12.4 43.87)))"),
                       snap(0.05, 0.23, 0.5, 0.17); atol = 1e-9)
        delete!(filter(countries; name = "San Marino"))
        # test_transform
        pt = dgf_get(annotate(cities; pt = Transform(:point, 2774)), "Pueblo").pt
        @test pt.srid == 2774 && abs(992363.390841912 - pt.x) < 1 && abs(481455.395105533 - pt.y) < 1

        # test_sym_difference / test_diff_intersection_union
        for c in annotate(countries; difference = Difference(:mpoly, geom), sym_difference = SymDifference(:mpoly, geom),
                          union = GeoUnion(:mpoly, geom), intersection = Intersection(:mpoly, geom))
            @test dgf_sql("ST_Equals(ST_Difference($G, $G), $G)", c.mpoly, geom, c.difference)
            @test isempty(c.intersection)
            @test dgf_sql("ST_Equals(ST_SymDifference($G, $G), $G)", c.mpoly, geom, c.sym_difference)
            @test dgf_sql("ST_Equals(ST_Union($G, $G), $G)", c.mpoly, geom, c.union)
        end
        # test_union: fields and geometries, in either order
        houston = Point(-95.363151, 29.763374)
        both = parse_wkt("MULTIPOINT(-96.801611 32.782057,-95.363151 29.763374)")
        @test dgf_equals(both, dgf_get(annotate(cities; u = GeoUnion(:point, houston)), "Dallas").u)
        @test dgf_equals(both, dgf_get(annotate(cities; u = GeoUnion(houston, :point)), "Dallas").u)
        @test dgf_equals(Point(-96.801611, 32.782057), dgf_get(annotate(cities; u = GeoUnion(:point, :point)), "Dallas").u)
        @test dgf_equals(houston, dgf_get(annotate(cities; u = GeoUnion(houston, houston)), "Dallas").u)
        # test_union_mixed_srid: the result's SRID is the first argument's
        g4326 = Point(61.42915, 55.15402)
        g3857 = parse_wkt(dgf_sql("ST_AsEWKT(ST_Transform($G, 3857))", g4326))
        for c in annotate(cities; u = GeoUnion(:point, g3857))
            @test c.u.srid == 4326 && dgf_sql("ST_HausdorffDistance($G, ST_Union($G, $G))", c.u, c.point, g4326) < 0.001
        end
        for c in annotate(cities; u = GeoUnion(g3857, :point))
            @test c.u.srid == 3857 && dgf_sql("ST_HausdorffDistance($G, ST_Union($G, ST_Transform($G, 3857)))", c.u, g3857, c.point) < 0.001
        end

        # test_argument_validation
        e = try collect(annotate(cities; geo = GeoFunc("GeoFunc", "ST_Centroid", [:name]))) catch err; err end
        @test e isa ArgumentError && e.msg == "GeoFunc function requires a GeometryField in position 1, got CharField."
        e = try GeoFunc("GeoFunc", "ST_Union", [1, :point]) catch err; err end
        @test e isa ArgumentError && e.msg == "GeoFunc function requires a geometric argument in position 1."

        # test_geometry_type (and the geom_type lookup)
        sq = [(0, 0), (1, 0), (1, 1), (0, 0)]
        for (name, gm) in (("POINT", Point(0, 0)), ("LINESTRING", LineString([(0, 0), (1, 1)])), ("POLYGON", Polygon(sq)),
                           ("MULTILINESTRING", MultiLineString([[(0, 0), (1, 1)], [(1, 1), (2, 2)]])),
                           ("MULTIPOLYGON", MultiPolygon([Polygon(sq), Polygon([(1, 1), (2, 1), (2, 2), (1, 1)])])),
                           ("MULTIPOINT", MultiPoint([(0, 0), (1, 1)])))
            create(DgfFeature; name = name, geom = gm)
            obj = only(collect(filter(annotate(objects(DgfFeature); geometry_type = GeometryType(:geom)); geom__geom_type = name)))
            @test obj.geom isa typeof(gm) && obj.geom == gm && obj.geometry_type == name
        end
        # (a geometry field's value through F comes back as a geometry, not hex)
        @test dgf_get(annotate(cities; p = F(:point)), "Pueblo").p == Point(-104.609252, 38.255001)
        # (a GeometryCollection, through WKT, GeoJSON and the database)
        gc = GeometryCollection([Point(1, 2), LineString([(0, 0), (1, 1)])])
        @test parse_wkt(wkt(gc)) == gc && from_geojson(geojson(gc)) == gc && wkt(GeometryCollection([])) == "GEOMETRYCOLLECTION EMPTY"
        create(DgfFeature; name = "gc", geom = gc)
        @test get(DgfFeature; name = "gc").geom == gc
    end
  end
end
end
