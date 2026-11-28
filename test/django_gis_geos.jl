# Django's gis_tests geos_tests (test_geos.py, test_io.py), ported (#227): the parts about geometry values (reading and
# writing WKT, EWKT, WKB, HEXEWKB and GeoJSON; coordinates, points, extents, equality), with Django's geometries.json.
# Juango's geometries are plain values; the GEOS operations (buffer, union, relate, transform, ...) are PostGIS's in
# queries (#308). No database needed.
# julia --project=test test/django_gis_geos.jl   (see setup.jl)
#
# Not translated: 3D (Z) and measured (M) geometries and curves, LinearRing (Juango's polygons hold their rings),
# mutation and the mutable-list protocol, prepared geometries, pickling, KML/GML output (AsKML and AsGML are PostGIS's),
# test_io's reader/writer objects (byte order and dimension options).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const DGO_DATA = JSON.parse(read(joinpath(@__DIR__, "gis_fixtures", "geometries.json"), String))
dgo_2d(xs) = [x for x in xs if !occursin(r"\b(Z|M|ZM)\b|\(\s*[-0-9.]+ [-0-9.]+ [-0-9.]+", x["wkt"]) && !startswith(x["wkt"], "LINEARRING")]

@testset "django gis_tests geos_tests: GEOSTest (geometry values)" begin
    # test_wkt / test_ewkt: WKT read and written back; an EWKT's SRID kept through its output
    for g in dgo_2d(DGO_DATA["wkt_out"])
        geom = parse_wkt(g["wkt"])
        @test parse_wkt(wkt(geom)) == geom
    end
    for srid in (-1, 32140), p in DGO_DATA["polygons"]
        poly = parse_wkt("SRID=$srid;$(p["wkt"])")
        @test poly.srid == srid && parse_wkt(ewkt(poly)).srid == srid
    end
    # test_wkt_invalid / test_errors: Django's message
    for bad in ("POINT(٠٠١ ٠)", "SRID=٧٥٨٣;POINT(100 0)")
        @test_throws "String input unrecognized as WKT EWKT, and HEXEWKB." parse_geometry(bad)
    end
    for e in DGO_DATA["errors"]
        @test_throws ArgumentError parse_geometry(e["wkt"])
    end
    @test_throws "Invalid WKB input." parse_geometry("FFFFFFFFFFFFFFFFF1355555555555555555565111"[1:end-1])
    # test_hex / test_wkb / test_create_hex / test_create_wkb: WKB written and read
    for g in dgo_2d(DGO_DATA["hex_wkt"])
        geom = parse_wkt(g["wkt"])
        @test hexwkb(geom) == g["hex"]
        @test parse_wkb(g["hex"]) == geom && parse_wkb(wkb(geom)) == geom && parse_geometry(g["hex"]) == geom
    end
    # test_hexewkb: OGC WKB has no SRID; EWKB has it
    pnt = Point(0, 1; srid = 4326)
    @test hexwkb(pnt) == "01010000000000000000000000000000000000F03F"
    @test hexewkb(pnt) == "0101000020E61000000000000000000000000000000000F03F"
    @test ewkb(pnt) == hex2bytes("0101000020E61000000000000000000000000000000000F03F")
    @test parse_wkb("0101000020E61000000000000000000000000000000000F03F").srid == 4326
    # test_json / test_json_srid: GeoJSON in and out; a named CRS's SRID
    for g in DGO_DATA["json_geoms"]
        geom = parse_wkt(g["wkt"])
        haskey(g, "not_equal") || @test JSON.parse(JSON.json(geojson(geom))) == JSON.parse(g["json"])
        @test from_geojson(JSON.json(geojson(geom))) == geom             # (Django reads its own output back too)
    end
    @test from_geojson(Dict("type" => "Point", "coordinates" => [2, 49],
                            "crs" => Dict("type" => "name", "properties" => Dict("name" => "urn:ogc:def:crs:EPSG::4322")))) == Point(2, 49; srid = 4322)
    # test_fromfile: WKT and WKB from a file
    ref = parse_wkt("POINT(5 23)")
    for bytes in (Vector{UInt8}(wkt(ref)), wkb(ref))
        path, io = mktemp(); write(io, bytes); close(io)
        data = read(path)
        @test (all(b -> b < 0x80 && b >= 0x20, data) ? parse_wkt(String(data)) : parse_wkb(data)) == ref
    end
    # test_eq / test_hash / test_eq_with_srid: equal values, and the SRID counts
    p = parse_wkt("POINT(5 23)")
    @test p == parse_wkt(wkt(p)) && p == parse_wkt("POINT(5.0 23.0)") && p != parse_wkt("LINESTRING(0 0, 1 1, 5 5)")
    @test Point(5, 23; srid = 4326) != Point(5, 23; srid = 32632)
    @test hash(Point(5, 23; srid = 4326)) != hash(Point(5, 23; srid = 32632))
    @test hash(MultiPoint([Point(5, 23)]; srid = 4326)) != hash(Point(5, 23; srid = 4326))
    @test length(Set([Point(5, 23), Point(5, 23), Point(5, 23; srid = 32632)])) == 2
    # test_points / test_multipoints / test_linestring / test_multilinestring / test_polygons / test_multipolygons
    for pt in DGO_DATA["points"]
        g = parse_wkt(pt["wkt"])
        dgo_2d([pt]) == [pt] || continue
        @test g isa Point && g.x == pt["x"] && g.y == pt["y"] && coords(g) == (pt["x"], pt["y"]) && num_points(g) == 1
    end
    for mp in DGO_DATA["multipoints"]
        g = parse_wkt(mp["wkt"])
        @test g isa MultiPoint && num_points(g) == mp["n_p"] && coords(g) == [Tuple(Float64.(c)) for c in mp["coords"]]
    end
    for ls in DGO_DATA["linestrings"]
        g = parse_wkt(ls["wkt"])
        @test g isa LineString && num_points(g) == ls["n_p"] && coords(g) == [Tuple(Float64.(c)) for c in ls["coords"]]
    end
    for ml in DGO_DATA["multilinestrings"]
        g = parse_wkt(ml["wkt"])
        @test g isa MultiLineString && num_points(g) == ml["n_p"] && coords(g) == [[Tuple(Float64.(c)) for c in l] for l in ml["coords"]]
    end
    for pl in DGO_DATA["polygons"]
        g = parse_wkt(pl["wkt"])
        @test g isa Polygon && num_points(g) == pl["n_p"] && length(g.rings) - 1 == pl["n_i"]
        pl["ext_ring_cs"] === false || @test g.rings[1] == [Tuple(Float64.(c)) for c in pl["ext_ring_cs"]]
    end
    for mp in DGO_DATA["multipolygons"]
        mp["valid"] || continue                                   # (Django checks only the valid ones)
        g = parse_wkt(mp["wkt"])
        @test g isa MultiPolygon && length(g.geoms) == mp["num_geom"] && num_points(g) == mp["n_p"]
    end
    # test_extent
    @test extent(MultiPoint([Point(5, 23), Point(0, 0), Point(10, 50)])) == (0.0, 0.0, 10.0, 50.0)
    @test extent(Point(5.23, 17.8)) == (5.23, 17.8, 5.23, 17.8)
    poly = parse_wkt(DGO_DATA["polygons"][4]["wkt"])
    xs, ys = first.(poly.rings[1]), last.(poly.rings[1])
    @test extent(poly) == (minimum(xs), minimum(ys), maximum(xs), maximum(ys))
    # test_from_ewkt / test_fromstr_scientific_wkt
    @test parse_wkt("SRID=1;POINT(1 1)") == Point(1, 1; srid = 1) && parse_wkt("POINT(1 1)") == Point(1, 1)
    @test parse_wkt("POINT(1.0e-1 1.0e+1)") == Point(0.1, 10)
    @test_throws ArgumentError parse_geometry("")
    @test_throws ArgumentError parse_geometry("SRID=1;")
    # test_empty_point / test_emptyCollections
    @test isempty(Point(NaN, NaN)) && wkt(Point(NaN, NaN)) == "POINT EMPTY" && parse_wkt("POINT EMPTY") == Point(NaN, NaN)
    for w in ("GEOMETRYCOLLECTION EMPTY", "LINESTRING EMPTY", "POLYGON EMPTY", "MULTIPOINT EMPTY", "MULTILINESTRING EMPTY", "MULTIPOLYGON EMPTY")
        g = parse_wkt(w)
        @test isempty(g) && wkt(g) == w && num_points(g) == 0 && extent(g) === nothing
        @test parse_wkb(wkb(g)) == g
    end
    # test_empty_point_wkb (test_io): an empty point's WKB is NaN coordinates
    @test hexwkb(Point(NaN, NaN)) == "0101000000000000000000F87F000000000000F87F"
    @test isempty(parse_wkb("0101000000000000000000F87F000000000000F87F"))
    # (a GeometryCollection's WKB, GeoJSON and EWKB)
    gc = GeometryCollection([Point(1, 2), LineString([(0, 0), (1, 1)]), Polygon([(0, 0), (0, 1), (1, 1), (0, 0)])]; srid = 3857)
    @test parse_wkb(hexewkb(gc)) == gc && parse_wkb(wkb(gc); srid = 3857) == gc
end
