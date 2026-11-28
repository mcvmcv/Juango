# Django's gis_tests relatedapp tests, ported (#227): RelatedGeoModelTest, on PostGIS: geometries across relations
# (select_related, aggregates and F() through foreign keys, in other SRIDs).
# julia --project=test test/django_gis_relatedapp.jl   (see setup.jl; JUANGO_TEST_DATABASE=postgresql://... with PostGIS)
#
# Not translated: test15_invalid_select_related (it checks Django's query string building for a select_related
# through a unique foreign key's reverse side). Union is GeoUnion (Julia's Union).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

module DgrModels
using Juango, Juango.GIS, Dates
@model struct Location
    point = PointField()
    Meta(app_label = "relatedapp", table = "dgr_location")
end
@model struct City
    name::String = CharField(max_length = 50)
    state::String = CharField(max_length = 2)
    location = ForeignKey(Location, on_delete = :CASCADE)
    Meta(app_label = "relatedapp", table = "dgr_city")
end
@model struct AugmentedLocation <: Location
    extra_text::String = TextField(blank = true, default = "")
    Meta(app_label = "relatedapp", table = "dgr_augmentedlocation")
end
@model struct DirectoryEntry
    listing_text::String = CharField(max_length = 50)
    location = ForeignKey(AugmentedLocation, on_delete = :CASCADE)
    Meta(app_label = "relatedapp", table = "dgr_directoryentry")
end
@model struct Parcel
    name::String = CharField(max_length = 30)
    city = ForeignKey(City, on_delete = :CASCADE)
    center1 = PointField()
    center2 = PointField(srid = 2276, db_column = "mycenter")     # (a curveball: another column name)
    border1 = PolygonField()
    border2 = PolygonField(srid = 2276)
    Meta(app_label = "relatedapp", table = "dgr_parcel")
end
@model struct Author
    name::String = CharField(max_length = 100)
    dob::Date = DateField()
    Meta(app_label = "relatedapp", table = "dgr_author")
end
@model struct Article
    title::String = CharField(max_length = 100)
    author = ForeignKey(Author, on_delete = :CASCADE, unique = true)
    Meta(app_label = "relatedapp", table = "dgr_article")
end
@model struct Book
    title::String = CharField(max_length = 100)
    author = ForeignKey(Author, on_delete = :SET_NULL, related_name = "books", null = true)
    Meta(app_label = "relatedapp", table = "dgr_book")
end
@model struct Event
    name::String = CharField(max_length = 100)
    when::DateTime = DateTimeField()
    Meta(app_label = "relatedapp", table = "dgr_event")
end
end
const DgrLocation, DgrCity, DgrAugLocation, DgrDirEntry = DgrModels.Location, DgrModels.City, DgrModels.AugmentedLocation, DgrModels.DirectoryEntry
const DgrParcel, DgrAuthor, DgrArticle, DgrBook, DgrEvent = DgrModels.Parcel, DgrModels.Author, DgrModels.Article, DgrModels.Book, DgrModels.Event

if IS_POSTGRES
redirect_stdout(devnull) do
    ms = [DgrLocation, DgrCity, DgrAugLocation, DgrDirEntry, DgrParcel, DgrAuthor, DgrArticle, DgrBook, DgrEvent]
    Juango.sync_models!(ms); append!(PORT_MODELS, ms)
end
"A geometry PostGIS makes from others (each ? one): Django's GEOS calls (transform, buffer, centroid)."
dgr_geom(expr, gs...) = parse_wkt(only(collect(execute("SELECT ST_AsEWKT($expr) AS r", Any[ewkt(g) for g in gs])))[:r])
dgr_pts(g) = sort([coords(p) for p in (g isa MultiPoint ? g.geoms : [g])])
dgr_close(a, b) = length(a) == length(b) && all(isapprox(p[1], q[1]; atol = 1e-6) && isapprox(p[2], q[2]; atol = 1e-6) for (p, q) in zip(a, b))

@testset "django gis_tests relatedapp: RelatedGeoModelTest" begin
  override_settings(FIXTURE_DIRS = [joinpath(@__DIR__, "gis_fixtures")]) do
    port_block() do
        loaddata("relatedapp_initial")
        cities = objects(DgrCity)
        # test02_select_related
        ref = [("Aurora", "TX", -97.516111, 33.058333), ("Roswell", "NM", -104.528056, 33.387222), ("Kecksburg", "PA", -79.460734, 40.18476)]
        for qs in (order_by(cities, "id"), select_related(order_by(cities, "id"), :location))
            for ((nm, st, lon, lat), c) in zip(ref, collect(qs))
                @test c.name == nm && c.state == st && isapprox(c.location.point.x, lon; atol = 1e-6) && isapprox(c.location.point.y, lat; atol = 1e-6)
            end
        end
        # test_related_extent_aggregate / test_related_extent_annotate: through a foreign key
        all_extent, txpa_extent = (-104.528056, 29.763374, -79.460734, 40.18476), (-97.516111, 29.763374, -79.460734, 40.18476)
        @test all(isapprox.(aggregate(cities, Extent(:location__point))[:location__point__extent], all_extent; atol = 1e-4))
        @test all(isapprox.(aggregate(exclude(cities; state = "NM"), Extent(:location__point))[:location__point__extent], txpa_extent; atol = 1e-4))
        @test all(isapprox.(first(order_by(annotate(cities; e = Extent(:location__point)), "name")).e, (-97.516111, 33.058333, -97.516111, 33.058333); atol = 1e-4))
        # test_related_union_aggregate
        p1, p2, p3, p4, p5 = (-104.528056, 33.387222), (-97.516111, 33.058333), (-79.460734, 40.18476), (-96.801611, 32.782057), (-95.363151, 29.763374)
        u1 = aggregate(cities, GeoUnion(:location__point))[:location__point__union]
        u2 = aggregate(exclude(cities; name__in = ["Roswell", "Houston", "Dallas", "Fort Worth"]), GeoUnion(:location__point))[:location__point__union]
        @test u1 isa MultiPoint && dgr_close(dgr_pts(u1), sort([p1, p2, p3, p4, p5]))
        @test dgr_close(dgr_pts(u2), sort([p2, p3]))
        # test05_select_related_fk_to_subclass
        @test collect(select_related(objects(DgrDirEntry), :location)) isa Vector

        # test06_f_expressions: F() to another geometry field, of the row or through a foreign key, in another SRID
        b1 = parse_wkt("POLYGON((-97.501205 33.052520,-97.501205 33.052576,-97.501150 33.052576,-97.501150 33.052520,-97.501205 33.052520))")
        pcity = get(cities; name = "Aurora")
        c1 = pcity.location.point
        c2 = dgr_geom("ST_Transform(ST_GeomFromEWKT(?), 2276)", c1)
        b2 = dgr_geom("ST_Buffer(ST_GeomFromEWKT(?), 100)", c2)
        create(DgrParcel; name = "P1", city = pcity, center1 = c1, center2 = c2, border1 = b1, border2 = b2)
        c1 = dgr_geom("ST_Centroid(ST_GeomFromEWKT(?))", b1)
        c2 = dgr_geom("ST_Transform(ST_GeomFromEWKT(?), 2276)", c1)
        create(DgrParcel; name = "P2", city = pcity, center1 = c1, center2 = c2, border1 = b1, border2 = b1)   # (border2 transformed on save)
        parcels = filter(objects(DgrParcel); name__in = ["P1", "P2"])
        @test [p.name for p in filter(parcels; center1__within = F(:border1))] == ["P2"]
        @test only(collect(filter(parcels; center2__within = F(:border1)))).name == "P2"
        @test [p.name for p in filter(parcels; center1 = F(:city__location__point))] == ["P1"]
        @test only(collect(filter(parcels; border2__contains = F(:city__location__point)))).name == "P1"
        @test get(parcels; name = "P2").border2.srid == 2276
        delete!(parcels)

        # test07_values: geometries, not text
        for (m, d, t) in zip(order_by(objects(DgrLocation), "id"), values(order_by(objects(DgrLocation), "id")), values_list(order_by(objects(DgrLocation), "id")))
            @test d[:point] isa Point && t[2] isa Point && m.point == d[:point] == t[2]
        end
        # test_07b_values: an aware datetime
        override_settings(USE_TZ = true) do
            create(DgrEvent; name = "foo", when = Dates.now())
            @test length(collect(values_list(objects(DgrEvent), :when))) == 1
        end
        # test08_defer_only
        for (loc, dl) in zip(order_by(objects(DgrLocation), "pk"), order_by(defer(objects(DgrLocation), :point), "pk"))
            @test loc.point == dl.point
        end
        # test09_pk_relations
        @test [(v[:id], v[:location__id]) for v in values(order_by(cities, "id"), :id, :location__id)][1:5] == [(1, 1), (2, 2), (3, 3), (4, 5), (5, 4)]
        # test10_combine
        buf1 = dgr_geom("ST_Buffer(ST_GeomFromEWKT(?), 0.1)", get(cities; name = "Aurora").location.point)
        buf2 = dgr_geom("ST_Buffer(ST_GeomFromEWKT(?), 0.1)", get(cities; name = "Kecksburg").location.point)
        @test sort([c.name for c in filter(cities; location__point__within = buf1) | filter(cities; location__point__within = buf2)]) == ["Aurora", "Kecksburg"]
        # test12a_count / test12b_count / test13c_count
        dallas = get(cities; name = "Dallas")
        @test get(annotate(objects(DgrLocation); num_cities = Count(:city)); id = dallas.location_id).num_cities == 2
        qs = filter(annotate(objects(DgrAuthor); num_books = Count(:books)); num_books__gt = 1)
        @test length(collect(qs)) == 1 && first(qs).num_books == 3
        vqs = filter(annotate(values(objects(DgrAuthor), :name); num_books = Count(:books)); num_books__gt = 1)
        @test length(collect(vqs)) == 1 && first(collect(vqs))[:num_books] == 3
        v = only(collect(values(annotate(filter(objects(DgrLocation); id = 5); num_cities = Count(:city)), :id, :point, :num_cities)))
        @test v[:num_cities] == 2 && v[:point] isa Point
        # test13_select_related_null_fk
        create(DgrBook; title = "Without Author")
        @test get(select_related(objects(DgrBook), :author); title = "Without Author").author === nothing

        # test_collect: four points (Dallas and Fort Worth share one)
        coll = aggregate(filter(cities; state = "TX"), Collect(:location__point))[:location__point__collect]
        @test coll isa MultiPoint && length(coll.geoms) == 4
        @test dgr_close(dgr_pts(coll), sort([(-97.516111, 33.058333), (-96.801611, 32.782057), (-95.363151, 29.763374), (-96.801611, 32.782057)]))
        # test_collect_filter / test_centroid_collect_filter / test_make_line_filter / test_extent_filter / test_union_filter
        notignored = !Q(parcel__name__icontains = "ignore")
        city = get(annotate(cities;
                            parcel_center = Collect(:parcel__center1; filter = notignored),
                            parcel_center_nonexistent = Collect(:parcel__center1; filter = Q(parcel__name__icontains = "nonexistent")),
                            parcel_center_single = Collect(:parcel__center1; filter = Q(parcel__name__contains = "Alpha"))); name = "Aurora")
        @test dgr_close(dgr_pts(city.parcel_center), [(1.7128, -2.006), (4.7128, 5.006)])
        @test city.parcel_center_nonexistent === nothing
        @test dgr_close(dgr_pts(city.parcel_center_single), [(1.7128, -2.006)])
        city = get(annotate(cities; parcel_centroid = Centroid(Collect(:parcel__center1; filter = notignored))); name = "Aurora")
        @test city.parcel_centroid isa Point && isapprox(city.parcel_centroid.x, 3.2128; atol = 1e-4) && isapprox(city.parcel_centroid.y, 1.5; atol = 1e-4)
        city = get(annotate(cities; parcel_line = MakeLine(:parcel__center1; filter = notignored),
                                    parcel_line_nonexistent = MakeLine(:parcel__center1; filter = Q(parcel__name__icontains = "nonexistent"))); name = "Aurora")
        @test wkt(city.parcel_line) in ("LINESTRING(1.7128 -2.006, 4.7128 5.006)", "LINESTRING(4.7128 5.006, 1.7128 -2.006)")
        @test city.parcel_line_nonexistent === nothing
        city = get(annotate(cities; parcel_border = Extent(:parcel__border1; filter = notignored),
                                    parcel_border_nonexistent = Extent(:parcel__border1; filter = Q(parcel__name__icontains = "nonexistent")),
                                    parcel_border_no_filter = Extent(:parcel__border1)); name = "Aurora")
        @test city.parcel_border == (0.0, 0.0, 22.0, 22.0) && city.parcel_border_nonexistent === nothing &&
              city.parcel_border_no_filter == (0.0, 0.0, 32.0, 32.0)
        city = get(annotate(cities; parcel_point_union = GeoUnion(:parcel__center2; filter = notignored),
                                    parcel_point_nonexistent = GeoUnion(:parcel__center2; filter = Q(parcel__name__icontains = "nonexistent")),
                                    parcel_point_union_single = GeoUnion(:parcel__center2; filter = Q(parcel__name__contains = "Alpha"))); name = "Aurora")
        @test dgr_close(dgr_pts(city.parcel_point_union), sort([(12.75, 10.05), (3.7128, -5.006)])) && city.parcel_point_union.srid == 2276
        @test city.parcel_point_nonexistent === nothing
        @test wkt(city.parcel_point_union_single) == "POINT(3.7128 -5.006)"
        # test16_annotated_date_queryset
        @test sort([Dates.year(d) for d in dates(annotate(objects(DgrAuthor); num_books = Count(:books)), :dob, :year)]) == [1950, 1974]
    end
  end
end
end
