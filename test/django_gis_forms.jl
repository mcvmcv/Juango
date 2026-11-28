# Django's gis_tests test_geoforms.py, ported (#227): GeometryFieldTest and SpecializedFieldTest's cleaning. A geometry
# form field is Juango's GeometryField (PointField, ...) in a Form, as any field.
# julia --project=test test/django_gis_forms.jl   (see setup.jl; the transforms need PostGIS)
#
# Not translated: the OpenLayers/OSM widgets' HTML and options (Juango's widget is a textarea with a Leaflet map:
# OSMWidgetTest, GeometryWidgetTests, test_override_attrs, test_field_string_value's markup), max_geom_collections
# (GEOS's nesting limit), rasters (test_raster_types), the widget's map_srid (Juango's input is in the field's SRID).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

dgo_errors(f, v) = try
    Juango.clean(f, v); nothing
catch e
    e isa Juango.ValidationError || rethrow()
    reduce(vcat, collect(values(e.errors)))
end

@testset "django gis_tests test_geoforms: GeometryFieldTest" begin
    # test_init: bad values are refused
    fld = GeometryField()
    for bad in ("blah", 3, "FoO", nothing, 0)
        @test dgo_errors(fld, bad) !== nothing
    end
    # test_srid: input without an SRID is in the field's; in another SRID, transformed to the field's (by PostGIS)
    @test Juango.clean(GeometryField(srid = 4326), "POINT(5 23)").srid == 4326
    merc = "SRID=3857;POINT (-10615777.40976205 3473169.895707852)"
    if IS_POSTGRES
        g = Juango.clean(GeometryField(srid = 32140), merc)
        @test g.srid == 32140 && isapprox(g, Point(951640.547328465, 4219369.26171664; srid = 32140); atol = 1)
    else
        @test dgo_errors(GeometryField(srid = 32140), merc) ==
              ["An error occurred when transforming the geometry to the SRID of the geometry form field."]
    end
    # test_widgets_reject_external_crs / test_nested_external_crs_rejected: GeoJSON naming a CRS by URL (a 400)
    ext = """{"type": "Point", "coordinates": [0, 0], "crs": {"type": "link", "properties": {"href": "http://example.com/crs", "type": "proj4"}}}"""
    @test_throws Juango.BadRequest Juango.clean(GeometryField(), ext)
    named = """{"type": "Point", "coordinates": [0, 0], "crs": {"type": "name", "properties": {"href": "http://example.com/crs"}}}"""
    @test_throws Juango.BadRequest Juango.clean(GeometryField(), named)
    nested = """{"type": "GeometryCollection", "geometries": [$ext]}"""
    @test_throws Juango.BadRequest Juango.clean(GeometryField(), nested)
    @test Juango.clean(GeometryField(), """{"type": "Point", "coordinates": [5, 23]}""") == Point(5, 23)
    # test_null
    @test dgo_errors(GeometryField(), nothing) == ["No geometry value provided."]
    @test Juango.clean(GeometryField(required = false), nothing) === nothing
    # test_geom_type: any type by default; PointField refuses the others
    for w in ("POINT(5 23)", "MULTIPOLYGON(((0 0, 0 1, 1 1, 1 0, 0 0)))", "LINESTRING(0 0, 1 1)")
        @test Juango.clean(GeometryField(), w) == parse_wkt(w)
    end
    @test Juango.clean(PointField(), "POINT(5 23)") == Point(5, 23)
    @test dgo_errors(PointField(), "LINESTRING(0 0, 1 1)") == ["Invalid geometry type."]
    # test_to_python: WKT, EWKT and HEXEWKB in; other text, a bad WKT or a FeatureCollection refused
    for w in ("POINT(5 23)", "MULTIPOLYGON(((0 0, 0 1, 1 1, 1 0, 0 0)))", "LINESTRING(0 0, 1 1)")
        @test Juango.clean(GeometryField(), w) == parse_wkt(w)
    end
    @test Juango.clean(GeometryField(), "0101000020E6100000000000000000F03F0000000000000040") == Point(1, 2)
    for bad in ("POINT(5)", "MULTI   POLYGON(((0 0, 0 1, 1 1, 1 0, 0 0)))", "BLAH(0 0, 1 1)",
                """{"type": "FeatureCollection", "features": [{"geometry": {"type": "Point", "coordinates": [508375, 148905]}, "type": "Feature"}]}""")
        @test dgo_errors(GeometryField(), bad) == ["Invalid geometry value."]
    end
    # test_to_python_different_map_srid: GeoJSON in
    @test Juango.clean(GeometryField(), """{ "type": "Point", "coordinates": [ 5.0, 23.0 ] }""") == Point(5, 23)
    # test_field_with_text_widget / has_changed: the same point is no change
    pf = PointField(srid = 4326, widget = :text)
    @test Juango.clean(pf, "POINT(5 23)") == Point(5, 23)
    @test dgo_errors(pf, "POINT(5)") == ["Invalid geometry value."]
    form = Form([:pt => PointField(srid = 4326)]; data = Dict("pt" => "POINT(5 23)"), initial = Dict(:pt => parse_wkt("SRID=4326;POINT(5 23)")))
    @test !has_changed(form)
    form = Form([:pt => PointField(srid = 4326)]; data = Dict("pt" => "POINT(5 23.0000001)"), initial = Dict(:pt => Point(5, 23)))
    @test !has_changed(form)                                      # (within a millionth)
    form = Form([:pt => PointField(srid = 4326)]; data = Dict("pt" => "POINT(5 24)"), initial = Dict(:pt => Point(5, 23)))
    @test has_changed(form)
    # (a form's errors)
    form = Form([:pt1 => PointField(srid = 4326), :pt2 => PointField(srid = 4326), :pt3 => PointField(srid = 4326)];
                data = Dict("pt1" => "SRID=4326;POINT(7.3 44)", "pt2" => "", "pt3" => "PNT(0)"))
    @test !is_valid(form) && form.errors[:pt2] == ["No geometry value provided."] && form.errors[:pt3] == ["Invalid geometry value."]
    @test form.cleaned_data[:pt1] == Point(7.3, 44)
end

@testset "django gis_tests test_geoforms: SpecializedFieldTest" begin
    # each specialized field takes its own type and refuses the others
    geoms = Dict("POINT" => "POINT(5 23)", "MULTIPOINT" => "MULTIPOINT(5 23, 13 27)", "LINESTRING" => "LINESTRING(0 0, 1 1)",
                 "MULTILINESTRING" => "MULTILINESTRING((0 0, 1 1), (2 2, 3 3))", "POLYGON" => "POLYGON((0 0, 0 1, 1 1, 0 0))",
                 "MULTIPOLYGON" => "MULTIPOLYGON(((0 0, 0 1, 1 1, 0 0)))",
                 "GEOMETRYCOLLECTION" => "GEOMETRYCOLLECTION(POINT(5 23), LINESTRING(0 0, 1 1))")
    fields = Dict("POINT" => PointField, "MULTIPOINT" => MultiPointField, "LINESTRING" => LineStringField,
                  "MULTILINESTRING" => MultiLineStringField, "POLYGON" => PolygonField, "MULTIPOLYGON" => MultiPolygonField,
                  "GEOMETRYCOLLECTION" => GeometryCollectionField)
    for (t, F_) in fields
        f = F_()
        @test Juango.clean(f, geoms[t]) == parse_wkt(geoms[t])
        for (t2, w) in geoms
            t2 == t && continue
            @test dgo_errors(f, w) == ["Invalid geometry type."]
        end
        form = Form([:f => F_()]; data = Dict("f" => geoms[t]))
        @test is_valid(form)
        @test occursin("data-geom-type=\"$t\"", Juango.widget_html(form[:f]))
    end
end
