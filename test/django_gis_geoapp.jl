# Django's gis_tests geoapp tests.py, ported (#227): GeoModelTest, SaveLoadTests, GeoLookupTest and GeoQuerySetTest,
# on PostGIS (the functions are in django_gis_functions.jl, whose models and fixture this file uses).
# julia --project=test test/django_gis_geoapp.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Not translated: the proxy and multi-table inherited models (test_proxy, test_inherited_geofields: plain Juango
# models, nothing GIS), test_gis_query_as_string, GeoLookupUnsafeTests (rasters and external CRS: Juango has no
# rasters; its geometries are values, not strings handed to GDAL), the tolerance of Union (Oracle's), Oracle's and
# MySQL's differences, test_non_concrete_field. Union is GeoUnion (Julia's Union).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
isdefined(Main, :DgfModels) || include("django_gis_functions.jl")

if IS_POSTGRES
@testset "django gis_tests geoapp: GeoModelTest, GeoLookupTest, GeoQuerySetTest" begin
  override_settings(FIXTURE_DIRS = [DGF_FIXTURES]) do
    port_block() do
        loaddata("geoapp_initial")
        cities, countries, states = objects(DgfCity), objects(DgfCountry), objects(DgfState)
        names(qs) = sort([x.name for x in qs])
        # test_fixtures
        @test count(countries) == 2 && count(cities) == 8 && count(states) == 2

        # test_lookup_insert_transform: a point in another SRID is transformed when it's saved and when it's looked up
        sa_4326 = "POINT (-98.493183 29.424170)"
        wkt_3084 = "MULTIPOLYGON (((-98.494 29.423, -98.492 29.423, -98.492 29.425, -98.494 29.425, -98.494 29.423)))"
        tx = get(countries; mpoly__intersects = parse_wkt(sa_4326))
        @test tx.name == "Texas"
        p3857 = parse_wkt(dgf_sql("ST_AsEWKT(ST_Transform($G, 3857))", parse_wkt(sa_4326)))
        @test get(countries; mpoly__intersects = p3857).name == "Texas"
        c = create(DgfCity; name = "San Antonio", point = p3857)
        @test isapprox(get(cities; name = "San Antonio").point, parse_wkt(sa_4326); atol = 1e-6)
        # test_createnull: a geometry that's NOT NULL refuses nothing
        @test_throws Juango.IntegrityError create(DgfCity; name = "nowhere", point = nothing)
        # test_geometryfield: any geometry in a GeometryField
        for gm in (Point(5, 23), LineString([(0, 0), (1, 1), (5, 5)]), Polygon([(0, 0), (0, 5), (5, 5), (5, 0)]),
                   MultiPolygon([Polygon([(0, 0), (0, 5), (5, 5), (5, 0)]), Polygon([(1, 1), (1, 2), (2, 2), (2, 1)])]))
            f = create(DgfFeature; name = Juango.geom_type(gm), geom = gm)
            @test get(objects(DgfFeature); id = f.id).geom == gm
        end
        # test_raw_sql_query: a raw query's geometries come back as geometries
        r = only(collect(raw(DgfCity, "SELECT id, name, point FROM dgf_city WHERE name = 'Pueblo'")))
        @test r.point isa Point && r.point.srid == 4326
        # test_dumpdata_loaddata_cycle
        data = dumpdata("geoapp.city")
        @test occursin("\"point\":\"SRID=4326;POINT(-104.609252 38.255001)\"", data)
        before = sort([(x.name, x.point) for x in cities]; by = first)
        delete!(cities)
        path = joinpath(mktempdir(), "cities.json"); write(path, data)
        loaddata(path)
        @test sort([(x.name, x.point) for x in cities]; by = first) == before
        # test_empty_geometries: an empty geometry of each kind, saved and loaded
        for gm in (Point(NaN, NaN), LineString(Juango.Coord[]), Polygon(Vector{Juango.Coord}[]), MultiPoint(Point[]),
                   MultiLineString(LineString[]), MultiPolygon(Polygon[]), GeometryCollection([]))
            f = create(DgfFeature; name = "empty", geom = gm)
            g2 = get(objects(DgfFeature); id = f.id).geom
            @test isempty(g2) && typeof(g2) == typeof(gm)
        end
        # SaveLoadTests: test_multilinestringfield, test_multipointfield, test_geometrycollectionfield
        for gm in (MultiLineString([[(0, 0), (1, 1)], [(2, 2), (3, 3)]]), MultiPoint([(1, 1), (2, 2)]),
                   GeometryCollection([Point(2, 2), LineString([(0, 0), (2, 2)]), Polygon([(0, 0), (0, 1), (1, 1), (0, 0)])]))
            f = create(DgfFeature; name = "saveload", geom = gm)
            @test get(objects(DgfFeature); id = f.id).geom == gm
        end
        delete!(objects(DgfFeature))

        # GeoLookupTest
        ptown = get(cities; name = "Pueblo")
        # test_disjoint_lookup
        @test count(filter(cities; point__disjoint = ptown.point)) == count(cities) - 1
        @test names(filter(states; poly__disjoint = ptown.point)) == ["Kansas"]
        # test_contained: the bounding boxes only (Oklahoma City is in Texas's)
        texas = get(countries; name = "Texas")
        @test names(filter(cities; point__contained = texas.mpoly)) == ["Dallas", "Houston", "Oklahoma City", "San Antonio"]
        # test_contains: a geometry, EWKB hex or WKT
        houston, wellington, okcity, lawrence = (get(cities; name = n) for n in ("Houston", "Wellington", "Oklahoma City", "Lawrence"))
        @test get(countries; mpoly__contains = houston.point).name == "Texas"
        hexwkb = dgf_sql("encode(ST_AsEWKB($G), 'hex')", wellington.point)
        @test get(countries; mpoly__contains = hexwkb).name == "New Zealand"
        @test get(states; poly__contains = lawrence.point).name == "Kansas"
        @test isempty(collect(filter(countries; mpoly__contains = ptown.point)))
        @test isempty(collect(filter(countries; mpoly__contains = wkt(okcity.point))))
        # test_bbcontains
        @test names(filter(countries; mpoly__bbcontains = okcity.point)) == ["Texas"]
        # test_crosses_lookup
        create(DgfTrack; name = "Line1", line = LineString([(-95, 29), (-60, 0)]))
        @test count(filter(objects(DgfTrack); line__crosses = LineString([(-95, 0), (-60, 29)]))) == 1
        @test count(filter(objects(DgfTrack); line__crosses = LineString([(-95, 30), (0, 30)]))) == 0
        # test_isvalid_lookup
        create(DgfState; name = "invalid", poly = parse_wkt("POLYGON((0 0, 0 1, 1 1, 1 0, 1 1, 1 0, 0 0))"))
        @test count(filter(states; poly__isvalid = false)) == 1 && count(filter(states; poly__isvalid = true)) == count(states) - 1
        delete!(filter(states; name = "invalid"))
        # test_left_right_lookups (bounding boxes: A << B when xmax(A) < xmin(B))
        co, ks = get(states; name = "Colorado").poly, get(states; name = "Kansas").poly
        @test names(filter(cities; point__right = co)) == ["Chicago", "Dallas", "Houston", "Lawrence", "Oklahoma City", "San Antonio", "Wellington"]
        @test names(filter(cities; point__right = ks)) == ["Chicago", "Wellington"]
        @test get(cities; point__left = co).name == "Victoria"
        @test names(filter(cities; point__left = ks)) == ["Pueblo", "Victoria"]
        # test_strictly_above_below_lookups
        dallas = get(cities; name = "Dallas")
        @test names(filter(cities; point__strictly_above = dallas.point)) == ["Chicago", "Lawrence", "Oklahoma City", "Pueblo", "Victoria"]
        @test names(filter(cities; point__strictly_below = dallas.point)) == ["Houston", "San Antonio", "Wellington"]
        # test_equals_lookups
        pnt = parse_wkt("POINT (-95.363151 29.763374)")
        @test get(cities; point = pnt).name == get(cities; point__same_as = pnt).name == get(cities; point__equals = pnt).name == "Houston"
        # test_null_geometries
        create(DgfState; name = "Puerto Rico")
        @test names(filter(states; poly__isnull = true)) == ["Puerto Rico"]
        @test names(filter(states; poly = nothing)) == ["Puerto Rico"]
        @test names(exclude(states; poly = nothing)) == ["Colorado", "Kansas"]
        nmi = create(DgfState; name = "Northern Mariana Islands", poly = nothing)
        @test nmi.poly === nothing
        nmi.poly = parse_wkt("POLYGON((0 0,1 0,1 1,1 0,0 0))"); save!(nmi)
        update!(filter(states; name = "Northern Mariana Islands"); poly = nothing)
        @test get(states; name = "Northern Mariana Islands").poly === nothing
        # test_null_geometries_excluded_in_lookups
        null = create(DgfState; name = "NULL", poly = nothing)
        line = LineString([(0, 0), (1, 1), (5, 5)])
        for (lk, gm) in (("equals", Point(1, 1)), ("disjoint", Point(1, 1)), ("touches", Point(1, 1)), ("crosses", line),
                         ("within", Point(1, 1)), ("overlaps", line), ("contains", line), ("intersects", line),
                         ("relate", (Point(1, 1), "T*T***FF*")), ("same_as", Point(1, 1)), ("exact", Point(1, 1)),
                         ("coveredby", Point(1, 1)), ("covers", Point(1, 1)))
            @test !(null.id in [s.id for s in filter(states; Symbol("poly__$lk") => gm)])
        end
        delete!(filter(states; name__in = ["Puerto Rico", "Northern Mariana Islands", "NULL"]))
        # test_wkt_string_in_lookup
        @test count(filter(states; poly__intersects = "LINESTRING(0 0, 1 1, 5 5)")) == 0
        # test_coveredby_lookup / test_covers_lookup
        sq5 = Polygon([(0, 0), (0, 5), (5, 5), (5, 0), (0, 0)])
        st = create(DgfState; name = "Test", poly = sq5)
        small, large = Polygon([(0, 0), (1, 4), (4, 4), (4, 1), (0, 0)]), Polygon([(0, 0), (-1, 6), (6, 6), (6, -1), (0, 0)])
        @test isempty(collect(filter(states; poly__coveredby = small)))
        @test [s.id for s in filter(states; poly__coveredby = large)] == [st.id] == [s.id for s in filter(states; poly__coveredby = sq5)]
        @test [s.id for s in filter(states; poly__covers = small)] == [st.id] == [s.id for s in filter(states; poly__covers = sq5)]
        @test isempty(collect(filter(states; poly__covers = Polygon([(-1, -1), (-1, 6), (6, 6), (6, -1), (-1, -1)]))))
        # (contains_properly: inside, not touching the boundary)
        @test [s.id for s in filter(states; poly__contains_properly = Point(1, 1))] == [st.id]
        @test isempty(collect(filter(states; poly__contains_properly = Point(0, 1))))
        delete!(filter(states; name = "Test"))
        # test_relate_lookup: a DE-9IM pattern; the geometry in another SRID too
        pnt1 = parse_wkt("POINT (649287.0363174 4177429.4494686)"; srid = 2847)
        pnt2 = parse_wkt("POINT(-98.4919715741052 29.4333344025053)")
        @test_throws ArgumentError collect(filter(countries; mpoly__relate = (23, "foo")))
        @test_throws ArgumentError count(filter(countries; mpoly__relate = (pnt1, 0)))
        @test_throws ArgumentError count(filter(countries; mpoly__relate = (pnt2, "T*T***FF*", 0)))
        @test get(countries; mpoly__relate = (pnt1, "T*T***FF*")).name == "Texas"
        @test get(countries; mpoly__relate = (pnt2, "T*T***FF*")).name == "Texas"
        @test get(filter(cities; name = "Lawrence"); point__relate = (ks, "T*F**F***")).name == "Lawrence"
        @test get(countries; mpoly__relate = (pnt1, "T********")).name == "Texas"
        @test get(cities; point__relate = (ks, "T********")).name == "Lawrence"
        @test !exists(exclude(cities; point__relate = (GeoUnion(:point, :point), "T*F**F***")))
        # test_gis_lookups_with_complex_expressions: a GIS function on the right
        for lk in ("bbcontains", "bboverlaps", "contained", "contains", "contains_properly", "coveredby", "covers", "crosses",
                   "disjoint", "equals", "exact", "intersects", "overlaps", "same_as", "touches", "within", "left", "right",
                   "overlaps_left", "overlaps_right", "overlaps_above", "overlaps_below", "strictly_above", "strictly_below")
            @test exists(filter(cities; Symbol("point__$lk") => GeoUnion(:point, :point))) isa Bool
        end
        @test count(filter(cities; point__equals = GeoUnion(:point, :point))) == count(cities)
        # test_subquery_annotation / an F() on the right: another geometry field of the row
        create(DgfManyPointModel; name = "near", point1 = Point(1, 1), point2 = Point(1, 1), point3 = Point(0, 0; srid = 3857))
        create(DgfManyPointModel; name = "far", point1 = Point(1, 1), point2 = Point(2, 2), point3 = Point(0, 0; srid = 3857))
        @test names(filter(objects(DgfManyPointModel); point1__equals = F(:point2))) == ["near"]
        # test_within_subquery: a queryset's geometry on the right
        @test values_list(order_by(filter(cities; point__within = values(filter(countries; name = "Texas"), :mpoly)), "name"), :name; flat = true) |>
              collect == ["Dallas", "Houston", "San Antonio"]

        # GeoQuerySetTest: test_extent / test_extent_with_limit
        ext = aggregate(filter(cities; name__in = ["Houston", "Dallas"]), Extent(:point))[:point__extent]
        @test all(isapprox.(ext, (-96.8016128540039, 29.7633724212646, -95.3631439208984, 32.782058715820); atol = 1e-4))
        @test aggregate(filter(cities; name = "Smalltown"), Extent(:point))[:point__extent] === nothing
        @test aggregate(cities, Extent(:point))[:point__extent] != aggregate(cities[1:3], Extent(:point))[:point__extent]
        # test_make_line: a line through the points; nothing for polygons
        @test aggregate(states, MakeLine(:poly))[:poly__makeline] === nothing
        ln = aggregate(cities, MakeLine(:point))[:point__makeline]
        @test ln isa LineString && num_points(ln) == count(cities)
        @test all(isapprox(p[1], q[1]; atol = 1e-5) && isapprox(p[2], q[2]; atol = 1e-5)
                  for (p, q) in zip(sort(ln.coords), sort([coords(c.point) for c in cities])))
        # test_unionagg / test_geoagg_subquery: the Union aggregate (GeoUnion with one argument)
        both = parse_wkt("MULTIPOINT(-96.801611 32.782057,-95.363151 29.763374)")
        qs = filter(cities; point__within = texas.mpoly, name__in = ["Houston", "Dallas"])
        @test_throws Exception aggregate(qs, GeoUnion(:name))                     # (not a geometry)
        @test dgf_equals(both, aggregate(qs, GeoUnion(:point))[:point__union])
        @test dgf_equals(both, aggregate(order_by(qs, "name"), GeoUnion(:point))[:point__union])
        @test dgf_equals(both, aggregate(distinct(qs), GeoUnion(:point))[:point__union])
        @test aggregate(filter(cities; name = "NotACity"), GeoUnion(:point))[:point__union] === nothing
        # (Collect: the points as one MultiPoint)
        col = aggregate(qs, Collect(:point))[:point__collect]
        @test col isa MultiPoint && num_points(col) == 2 && col.srid == 4326
        # test_values_srid
        for (c, v) in zip(order_by(cities, "id"), values(order_by(cities, "id")))
            @test c.point.srid == v[:point].srid == 4326 && v[:point] == c.point
        end
    end
  end
end
end
