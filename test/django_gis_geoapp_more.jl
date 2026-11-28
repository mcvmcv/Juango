# Django's gis_tests geoapp test_regress.py, test_expressions.py, test_indexes.py, test_serializers.py and test_feeds.py, and test_fields.py, ported
# (#227), on PostGIS, with the models and fixture of django_gis_functions.jl.
# julia --project=test test/django_gis_geoapp_more.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Juango's Value has no output field: Django's `Value(p, GeometryField(srid=4326))` is the geometry itself, and
# `Transform(p, 4326)` where Django's Value transforms it to the field's SRID. Not translated: test_kmz
# (render_to_kmz: #309), test_no_transform_attempted_for_invalid_srid_expression (a Juango
# geometry field always has an SRID), test_namespaced_db_table (schema-qualified tables) and the 3D opclass
# tests (Juango's geometries are 2D), test_sitemaps (KML and KMZ sitemaps: #309). The feeds are Juango Feeds with
# item_geometry and geometry (Django's gis Feed's methods), on items of named tuples (no database).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")
isdefined(Main, :DgfModels) || include("django_gis_functions.jl")

module DgxModels
using Juango, Juango.GIS
import ..DgfModels
@model struct PennsylvaniaCity <: DgfModels.City
    county::String = CharField(max_length = 30)
    founded = DateTimeField(null = true)
    Meta(app_label = "geoapp", table = "dgx_pennsylvaniacity")
end
@model struct MultiFields
    name::String = CharField(max_length = 30)
    city = ForeignKey(DgfModels.City, on_delete = :CASCADE)
    point = PointField()
    poly = PolygonField()
    Meta(app_label = "geoapp", table = "dgx_multifields")
end
@model struct Truth
    val::Bool = BooleanField(default = false)
    Meta(app_label = "geoapp", table = "dgx_truth")
end
end
const DgxPennsylvaniaCity, DgxMultiFields, DgxTruth = DgxModels.PennsylvaniaCity, DgxModels.MultiFields, DgxModels.Truth

@testset "django gis_tests geoapp: GeoFeedTest" begin
    cities = [(id = i, name = n, point = Point(x, y)) for (i, (n, x, y)) in enumerate([("Houston", -95.363151, 29.763374),
              ("Dallas", -95.363151, 29.763374), ("Oklahoma City", -97.521157, 34.464642), ("Wellington", 174.783117, -41.315268)])]
    rss1 = Feed(title = "Test GeoDjango Cities", link = "/city/", items = () -> cities, item_title = :name,
                item_link = c -> "/city/$(c.id)/", item_geometry = :point)
    rss2 = Feed(rss1; geometry = (-123.30, -41.32, 174.78, 48.46), item_geometry = c -> (c.point.x, c.point.y))
    atom1, atom2 = Feed(rss1; feed_type = :atom), Feed(rss2; feed_type = :atom, geometry = ((-123.30, -41.32), (174.78, 48.46)))
    w3c1, w3c2 = Feed(rss1; geo_format = :w3c), Feed(rss2; geo_format = :w3c)
    w3c3 = Feed(rss1; geo_format = :w3c, item_geometry = c -> Polygon([(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)]))
    req = Juango.Request("GET", "/feeds/"; headers = Dict("Host" => "testserver"))
    feed(f) = text(f(req))
    tags(x, tag) = [m[1] for m in eachmatch(Regex("<$tag(?:\\s[^>]*)?>(.*?)</$tag>", "s"), x)]
    # test_geofeed_rss: the GeoRSS namespace, a box on the channel (rss2), a point on each item
    for (f, box) in ((rss1, false), (rss2, true))
        x = feed(f)
        @test occursin("xmlns:georss=\"http://www.georss.org/georss\"", x)
        @test occursin("<georss:box>", only(tags(x, "channel"))) == box
        items = tags(x, "item")
        @test length(items) == length(cities) && all(i -> occursin("<georss:point>", i), items)
    end
    @test only(tags(feed(rss2), "georss:box")) == "-41.320000 -123.300000 48.460000 174.780000"
    @test tags(feed(rss1), "georss:point")[1] == "29.763374 -95.363151"
    # test_geofeed_atom
    for (f, box) in ((atom1, false), (atom2, true))
        x = feed(f)
        @test occursin("xmlns:georss=\"http://www.georss.org/georss\"", x)
        @test length(tags(x, "georss:box")) == (box ? 1 : 0)
        entries = tags(x, "entry")
        @test length(entries) == length(cities) && all(e -> occursin("<georss:point>", e), entries)
    end
    # test_geofeed_w3c: geo:lat and geo:lon; boxes and polygons refused
    x = feed(w3c1)
    @test occursin("xmlns:geo=\"http://www.w3.org/2003/01/geo/wgs84_pos#\"", x)
    @test all(i -> occursin("<geo:lat>", i) && occursin("<geo:lon>", i), tags(x, "item"))
    @test tags(x, "geo:lat")[1] == "29.763374" && tags(x, "geo:lon")[1] == "-95.363151"
    @test_throws "Cannot use simple GeoRSS box in W3C Geo feeds." feed(w3c2)
    @test_throws "W3C Geo only supports Point geometries." feed(w3c3)
    # (lines and polygons in GeoRSS)
    @test occursin("<georss:polygon>0.000000 0.000000 1.000000 0.000000 1.000000 1.000000 0.000000 1.000000 0.000000 0.000000</georss:polygon>",
                   feed(Feed(rss1; item_geometry = c -> Polygon([(0, 0), (0, 1), (1, 1), (1, 0), (0, 0)]))))
    @test occursin("<georss:line>0.000000 0.000000 1.000000 1.000000</georss:line>", feed(Feed(rss1; item_geometry = c -> LineString([(0, 0), (1, 1)]))))
    @test_throws "Geometry type \"MULTIPOINT\" not supported." feed(Feed(rss1; item_geometry = c -> MultiPoint([Point(0, 0)])))
end

@testset "django gis_tests test_fields: GeometryFieldTests" begin
    # test_deconstruct_empty / test_deconstruct_values: a geometry field's migration column keeps its type and SRID
    # (Juango's migrations record columns: Django's dim, extent and tolerance aren't Juango's, #308)
    code(T, n) = Juango.Migrations.column_code(Juango.column_state(Juango.getfield_meta(T, n)))
    @test occursin(":geometry", code(DgfFeature, :geom)) && occursin("of = Symbol(\"GEOMETRY:4326\")", code(DgfFeature, :geom))
    @test occursin("of = Symbol(\"POINT:3857\")", code(DgfManyPointModel, :point3))
    # (the code a migration file holds reads back: a geometry's type and SRID aren't a plain symbol literal)
    @test Core.eval(Juango, Meta.parse(code(DgfManyPointModel, :point3))).of == Symbol("POINT:3857")
    @test Juango.column_state(Juango.getfield_meta(DgfManyPointModel, :point3)).of == Symbol("POINT:3857")
end

if IS_POSTGRES
redirect_stdout(devnull) do
    ms = [DgxPennsylvaniaCity, DgxMultiFields, DgxTruth]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end

@testset "django gis_tests geoapp: GeoRegressionTests" begin
  override_settings(FIXTURE_DIRS = [DGF_FIXTURES]) do
    port_block() do
        loaddata("geoapp_initial")
        cities = objects(DgfCity)
        # test_update
        pueblo = get(cities; name = "Pueblo")
        bak = pueblo.point
        moved = Point(bak.x + 0.005, bak.y + 0.005)
        update!(filter(cities; name = "Pueblo"); point = moved)
        p = (refresh!(pueblo); pueblo).point
        @test isapprox(p.x, bak.x + 0.005; atol = 1e-6) && isapprox(p.y, bak.y + 0.005; atol = 1e-6)
        update!(filter(cities; name = "Pueblo"); point = bak)
        @test isapprox((refresh!(pueblo); pueblo).point, bak; atol = 1e-6)
        # test_extent: one point's
        ext = aggregate(filter(cities; name = "Pueblo"); e = Extent(:point))[:e]
        @test all(isapprox.(ext, (bak.x, bak.y, bak.x, bak.y); atol = 1e-4))
        # test_unicode_date
        founded = DateTime(1857, 5, 23)
        create(DgxPennsylvaniaCity; name = "Mansfield", county = "Tioga", point = parse_wkt("POINT(-77.071445 41.823881)"), founded = founded)
        @test datetimes(objects(DgxPennsylvaniaCity), :founded, :day)[1] == founded
        @test aggregate(objects(DgxPennsylvaniaCity); m = Min(:founded))[:m] == founded
        # test_empty_count: a geo lookup with an id__in subquery
        state = filter(objects(DgfState); poly__contains = pueblo.point)
        @test count(filter(cities; id__in = values_list(state, :id; flat = true))) == 1
        # test_defer_or_only_with_annotate
        @test collect(defer(annotate(cities; c = Count(:point)), :name)) isa Vector
        @test collect(only(annotate(cities; c = Count(:point)), :name)) isa Vector
        # test_boolean_conversion
        t1, t2 = create(DgxTruth; val = true), create(DgxTruth; val = false)
        @test get(objects(DgxTruth); id = t1.id).val === true && get(objects(DgxTruth); id = t2.id).val === false
    end
  end
end

@testset "django gis_tests geoapp: GeoExpressionsTests" begin
  override_settings(FIXTURE_DIRS = [DGF_FIXTURES]) do
    port_block() do
        loaddata("geoapp_initial")
        cities = objects(DgfCity)
        # test_geometry_value_annotation
        p = Point(1, 1; srid = 4326)
        @test first(annotate(cities; p = Value(p))).p == p
        # test_geometry_value_annotation_different_srid
        p2 = Point(1, 1; srid = 32140)
        q = first(annotate(cities; p = Transform(p2, 4326))).p
        @test q.srid == 4326 && isapprox(q, Juango.transform_geometry(p2, 4326); atol = 1e-5)
        # test_geography_value: a polygon's area on the spheroid
        poly = Polygon([(1, 1), (1, 2), (2, 2), (2, 1), (1, 1)])
        @test isapprox(first(annotate(cities; a = Area(poly))).a / 1e6, 12305.1; atol = 0.5)
        # test_update_from_other_field
        p1, p2 = Point(1, 1), Point(2, 2)
        obj = create(DgfManyPointModel; name = "m", point1 = p1, point2 = p2, point3 = Juango.transform_geometry(p2, 3857))
        update!(filter(objects(DgfManyPointModel); id = obj.id); point2 = F(:point1))
        @test (refresh!(obj); obj).point2 == p1
        update!(filter(objects(DgfManyPointModel); id = obj.id); point3 = F(:point1))
        @test isapprox((refresh!(obj); obj).point3, Juango.transform_geometry(p1, 3857); atol = 0.1)
        # test_multiple_annotation
        houston = get(cities; name = "Houston")
        create(DgxMultiFields; name = "x", point = Point(1, 1), city = houston, poly = poly)
        qs = annotate(annotate(order_by(values(objects(DgfCity), :name), :name); distance = Min(Distance("multifields__point", houston.point))),
                      count = Count("multifields"))
        @test first(qs) !== nothing
        # test_update_with_expression
        city = create(DgfCity; name = "t", point = Point(1, 1))
        update!(filter(cities; id = city.id); point = Translate(:point, 1, 1))
        @test (refresh!(city); city).point == Point(2, 2)
    end
  end
end

@testset "django gis_tests geoapp: SchemaIndexesTests" begin
    b = Juango.backend()
    t = Juango.modelmeta(DgfCity).table
    sql(ix) = only(Juango.index_spec_sql(b, t, Juango.index_state(DgfCity, ix)))
    add!(ix) = foreach(Juango.execute, Juango.index_spec_sql(b, t, Juango.index_state(DgfCity, ix)))
    remove!(ix) = foreach(Juango.execute, Juango.drop_index_spec_sql(b, t, Juango.index_state(DgfCity, ix)))
    indexes() = Dict(k => v.columns for (k, v) in Juango.introspect_constraints(t) if v.index)
    # test_using_sql: an index on a geometry field is a spatial one
    @test occursin("$(Juango.quote_name(b, t)) USING gist", sql(Index(fields = ["point"])))
    # test_index_name
    ix = Index(fields = ["point"], name = "custom_point_index_name")
    add!(ix)
    @test indexes()["custom_point_index_name"] == ["point"]
    remove!(ix)
    @test !haskey(indexes(), "custom_point_index_name")
    # test_partial_index
    ix = Index(fields = ["point"], name = "city_point_partial_on_name_idx", condition = Q(name = "Harahetania"))
    @test occursin("WHERE $(Juango.quote_name(b, "name"))", sql(ix))
    add!(ix); @test haskey(indexes(), ix.name); remove!(ix)
    # test_tablespace
    ix = Index(fields = ["point"], name = "city_point_partial_tblspce_idx", db_tablespace = "pg_default")
    @test occursin("TABLESPACE \"pg_default\"", sql(ix))
    add!(ix); @test haskey(indexes(), ix.name); remove!(ix)
    # test_covering_index
    ix = Index(fields = ["point"], include = ["name"], name = "city_point_covering_name_idx")
    @test occursin("(\"point\") INCLUDE (\"name\")", sql(ix))
    add!(ix); @test indexes()[ix.name] == ["point", "name"]; remove!(ix)
    # test_specified_opclass_is_used
    ix = Index(fields = ["point"], name = "city_point_geom_3d_idx", opclasses = ["gist_geometry_ops_nd"])
    add!(ix)
    @test [(String(r[:opcname]), String(r[:relname])) for r in Juango.execute(
        """SELECT opcname, c.relname FROM pg_opclass AS oc JOIN pg_index as i on oc.oid = ANY(i.indclass)
           JOIN pg_class as c on c.oid = i.indexrelid WHERE c.relname = ?""", Any[ix.name])] == [("gist_geometry_ops_nd", ix.name)]
    remove!(ix)
    # test_using_not_overridden
    @test occursin("USING brin", sql(BrinIndex(fields = ["point"], name = "city_point_brin_idx")))
end

@testset "django gis_tests geoapp: GeoJSONSerializerTests" begin
  override_settings(FIXTURE_DIRS = [DGF_FIXTURES]) do
    port_block() do
        loaddata("geoapp_initial")
        cities = order_by(objects(DgfCity), :name)
        # test_builtin_serializers
        @test :geojson in Juango.SERIAL_FORMATS
        # test_serialization_base
        geodata = JSON.parse(serialize(:geojson, cities))
        @test collect(keys(geodata)) == ["type", "features"] && geodata["type"] == "FeatureCollection"
        @test length(geodata["features"]) == count(cities)
        f1 = geodata["features"][1]
        @test f1["geometry"]["type"] == "Point" && f1["properties"]["name"] == "Chicago"
        @test f1["id"] == first(cities).id && f1["properties"]["pk"] == string(first(cities).id)
        # test_geometry_field_option
        create(DgxMultiFields; city = first(objects(DgfCity)), name = "Name", point = Point(5, 23),
               poly = Polygon([(0, 0), (0, 5), (5, 5), (5, 0), (0, 0)]))
        mf = objects(DgxMultiFields)
        @test JSON.parse(serialize(:geojson, mf))["features"][1]["geometry"]["type"] == "Point"
        @test JSON.parse(serialize(:geojson, mf; geometry_field = "poly"))["features"][1]["geometry"]["type"] == "Polygon"
        @test JSON.parse(serialize(:geojson, mf; geometry_field = "poly", fields = ("city",)))["features"][1]["geometry"]["type"] == "Polygon"
        # test_id_field_option
        @test JSON.parse(serialize(:geojson, cities; id_field = "name"))["features"][1]["id"] == first(cities).name
        # test_fields_option
        create(DgxPennsylvaniaCity; name = "Mansfield", county = "Tioga", point = parse_wkt("POINT(-77.071445 41.823881)"))
        props = JSON.parse(serialize(:geojson, objects(DgxPennsylvaniaCity); fields = ("county", "point")))["features"][1]["properties"]
        @test haskey(props, "county") && !haskey(props, "founded") && !haskey(props, "pk")
        # test_srid_option
        c = JSON.parse(serialize(:geojson, cities; srid = 2847))["features"][1]["geometry"]["coordinates"]
        @test isapprox(c[1], 1564802; atol = 10) && isapprox(c[2], 5613214; atol = 10)
        # test_deserialization_exception
        @test_throws ArgumentError deserialize(:geojson, "{}")
    end
  end
end
end
