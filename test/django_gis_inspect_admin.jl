# Django's gis_tests inspectapp (InspectDbTests) and geoadmin tests, ported (#227): inspectdb of PostGIS columns, and
# the admin's geometry widget (its map's starting place, has_changed, bad input).
# julia --project=test test/django_gis_inspect_admin.jl   (see setup.jl; inspectdb's part needs PostGIS)
#
# Not translated: ogrinspect and the OGR inspection tests (GDAL), 3D columns, test_raster_lookup_not_allowed
# (rasters), and the OpenLayers widget's markup and logs (Juango's widget is a textarea with a Leaflet map). Juango has
# no GISModelAdmin: a ModelAdmin's formfield_overrides give the geometry widget its attrs (Django's gis_widget_kwargs),
# and the map starts at (0, 0), zoom 1, unless they say (GISModelAdmin's default is 47, 5, zoom 12).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DgiModels
using Juango, Juango.GIS
@model struct AllFields
    name::String = CharField(max_length = 10)
    geom = PolygonField()
    point = PointField()
    route = LineStringField(srid = 2276, null = true)
    place = PointField(geography = true, null = true)
    anything = GeometryField(null = true)
    Meta(app_label = "inspectapp", table = "inspectapp_allogrfields")
end
@model struct City
    name::String = CharField(max_length = 30)
    point = PointField()
    Meta(app_label = "geoadmin", table = "dgi_city")
end
end
const DgiAllFields, DgiCity = DgiModels.AllFields, DgiModels.City

if IS_POSTGRES
    redirect_stdout(devnull) do
        Juango.sync_models!([DgiAllFields, DgiCity]); append!(PORT_MODELS, [DgiAllFields, DgiCity])
    end
    @testset "django gis_tests inspectapp: InspectDbTests" begin
        # test_geom_columns: the geometry type and SRID from geometry_columns (and geography_columns)
        out = Juango.inspectdb(; table_name_filter = ==("inspectapp_allogrfields"))
        @test occursin("using Juango, Juango.GIS", out)
        @test occursin("geom = PolygonField()", out)
        @test occursin("point = PointField()", out)
        @test occursin("route = LineStringField(srid = 2276, blank = true, null = true)", out)
        @test occursin("place = PointField(geography = true, blank = true, null = true)", out)
        @test occursin("anything = GeometryField(blank = true, null = true)", out)
        # (the management command)
        cmd = mktemp() do path, io
            redirect_stdout(() -> call_command("inspectdb", "inspectapp_allogrfields"), io); flush(io); read(path, String)
        end
        @test occursin("point = PointField()", cmd)
    end
end

@testset "django gis_tests geoadmin: GeoAdminTest" begin
    form() = Juango.ModelForm(DgiCity)
    # test_widget_empty_string / test_widget_invalid_string: the widget renders, its textarea empty
    for v in ("", "INVALID()")
        f = Juango.ModelForm(DgiCity; data = Dict("name" => "x", "point" => v))
        html = Juango.widget_html(f[:point])
        @test occursin("<textarea name=\"point\"", html) && occursin(">$(Juango.escape_html(v))</textarea>", html)
        @test !is_valid(f) && only(f.errors[:point]) == (v == "" ? "No geometry value provided." : "Invalid geometry value.")
    end
    # test_widget_has_changed (in the field's SRID, 4326; Django's test sends 3857 for its 3857 map)
    initial = Point(13.4197458572965953, 52.5194108501149799)
    changed(init, data) = :point in Juango.changed_fields(Juango.ModelForm(DgiCity; data = Dict("name" => "x", "point" => data),
                                                                           initial = Dict{Symbol,Any}(:point => init)))
    @test changed(nothing, "SRID=4326;POINT(13.5 52.6)")
    @test changed(initial, "")
    @test !changed(nothing, "")
    @test !changed(initial, "SRID=4326;POINT(13.4197458572965953 52.5194108501149799)")
    @test !changed(initial, "SRID=4326;POINT(13.41974585729659 52.51941085011497)")
    @test changed(initial, "SRID=4326;POINT(13.42 52.52)")
    # test_default_gis_widget_kwargs / test_custom_gis_widget_kwargs: where an empty map starts
    html = Juango.widget_html(form()[:point])
    @test occursin("data-default-lat=\"0\" data-default-lon=\"0\" data-default-zoom=\"1\"", html)
    Admin.register!(DgiCity; formfield_overrides = Dict(:geometry => Dict(:widget => Widget(; attrs = Dict("default_lat" => 55, "default_lon" => 37, "default_zoom" => 12)))))
    try
        ma = Admin.get_admin("geoadmin", Juango.model_name(DgiCity))
        f = Admin.configure_widgets!(ma, Juango.ModelForm(DgiCity))
        html = Juango.widget_html(f[:point])
        @test occursin("data-default-lat=\"55\" data-default-lon=\"37\" data-default-zoom=\"12\"", html)
    finally
        Admin.unregister!(DgiCity)
    end
end
