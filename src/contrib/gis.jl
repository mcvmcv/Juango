# GIS: geometry fields and spatial queries on PostGIS ----------------------------------------------
#
#     @model struct City
#         name     = CharField(max_length = 100)
#         location = PointField()                       # SRID 4326 (longitude, latitude)
#     end
#     wellington = Point(174.7762, -41.2865)
#     filter(City; location__distance_lte = (wellington, D(km = 50)))
#     filter(City; location__within = region.area)
#     order_by(annotate(objects(City); d = Distance(:location, wellington)), "d")   # metres
#     geojson(objects(City); geometry = :location, properties = [:name])          # FeatureCollection
#
# Geometries are small Julia values that read and write WKT/EWKT, GeoJSON and (E)WKB; the
# spatial work is done by PostGIS. Coordinates are (x, y) = (longitude, latitude) in SRID 4326.

abstract type Geometry end

const Coord = NTuple{2,Float64}
coord(p) = (Float64(p[1]), Float64(p[2]))

"`Point(x, y; srid=4326)`: for SRID 4326, x is longitude and y latitude."
struct Point <: Geometry
    x::Float64
    y::Float64
    srid::Int
end
Point(x::Real, y::Real; srid::Integer = 4326) = Point(Float64(x), Float64(y), Int(srid))

"`LineString([(x, y), ...]; srid=4326)`"
struct LineString <: Geometry
    coords::Vector{Coord}
    srid::Int
end
LineString(cs; srid::Integer = 4326) = LineString(Coord[coord(c) for c in cs], Int(srid))

"`Polygon([(x, y), ...]; srid=4326)` or `Polygon([outer_ring, hole...])`. Rings are closed automatically."
struct Polygon <: Geometry
    rings::Vector{Vector{Coord}}
    srid::Int
end
closering(r) = (isempty(r) || r[1] == r[end]) ? r : vcat(r, [r[1]])
function Polygon(rings; srid::Integer = 4326)
    rs = collect(rings)
    (isempty(rs) || rs[1] isa Tuple || rs[1] isa AbstractVector{<:Real}) && (rs = [rs])   # a single ring
    Polygon([closering(Coord[coord(c) for c in r]) for r in rs], Int(srid))
end

"Collections of points, lines or polygons."
struct MultiPoint <: Geometry
    geoms::Vector{Point}
    srid::Int
end
struct MultiLineString <: Geometry
    geoms::Vector{LineString}
    srid::Int
end
struct MultiPolygon <: Geometry
    geoms::Vector{Polygon}
    srid::Int
end
MultiPoint(ps; srid::Integer = 4326) = MultiPoint(Point[p isa Point ? p : Point(p[1], p[2]; srid = srid) for p in ps], Int(srid))
MultiLineString(ls; srid::Integer = 4326) = MultiLineString(LineString[l isa LineString ? l : LineString(l; srid = srid) for l in ls], Int(srid))
MultiPolygon(ps; srid::Integer = 4326) = MultiPolygon(Polygon[p isa Polygon ? p : Polygon(p; srid = srid) for p in ps], Int(srid))

Base.:(==)(a::G, b::G) where {G<:Geometry} = all(getfield(a, f) == getfield(b, f) for f in fieldnames(G))
Base.hash(g::Geometry, h::UInt) = hash(wkt(g), h)
Base.show(io::IO, g::Geometry) = print(io, ewkt(g))
display_string(g::Geometry) = ewkt(g)
geom_type(g::Geometry) = uppercase(string(nameof(typeof(g))))
with_srid(g::Point, s) = Point(g.x, g.y, s)
with_srid(g::G, s) where {G<:Geometry} = G((getfield(g, f) for f in fieldnames(G)[1:end-1])..., s)

# --- WKT --------------------------------------------------------------------------------------------

fmtnum(x::Float64) = isinteger(x) && abs(x) < 1e15 ? string(Int(x)) : string(x)
wkt_coords(cs) = join([fmtnum(c[1]) * " " * fmtnum(c[2]) for c in cs], ", ")
wkt_body(g::Point) = isnan(g.x) ? "EMPTY" : "(" * fmtnum(g.x) * " " * fmtnum(g.y) * ")"
wkt_body(g::LineString) = "(" * wkt_coords(g.coords) * ")"
wkt_body(g::Polygon) = "(" * join(["(" * wkt_coords(r) * ")" for r in g.rings], ", ") * ")"
wkt_body(g::Union{MultiPoint,MultiLineString,MultiPolygon}) = "(" * join([wkt_body(x) for x in g.geoms], ", ") * ")"
"Well-known text: `POINT(1 2)`."
wkt(g::Geometry) = geom_type(g) * wkt_body(g)
"Extended WKT with the SRID: `SRID=4326;POINT(1 2)`."
ewkt(g::Geometry) = "SRID=$(g.srid);" * wkt(g)

"Parse WKT or EWKT (`SRID=4326;POINT(1 2)`)."
function parse_wkt(s::AbstractString; srid::Integer = 4326)
    s = strip(s)
    m = match(r"^SRID=(\d+);(.*)$"is, s)
    m === nothing || (srid = parse(Int, m[1]); s = strip(m[2]))
    toks = [t.match for t in eachmatch(r"[A-Za-z]+|\(|\)|,|[-+0-9.eE]+", s)]
    i = Ref(1)
    peek() = i[] <= length(toks) ? toks[i[]] : ""
    next() = (t = peek(); i[] += 1; t)
    expect(t) = next() == t || throw(ArgumentError("invalid WKT near '$(join(toks[max(1, i[]-1):end], " "))'"))
    pt() = (x = parse(Float64, next()); y = parse(Float64, next()); while occursin(r"^[-+0-9.]", peek()); next(); end; (x, y))
    coords() = (expect("("); cs = Coord[pt()]; while peek() == ","; next(); push!(cs, pt()); end; expect(")"); cs)
    rings() = (expect("("); rs = [coords()]; while peek() == ","; next(); push!(rs, coords()); end; expect(")"); rs)
    typ = uppercase(next())
    while uppercase(peek()) in ("Z", "M", "ZM"); next(); end
    if uppercase(peek()) == "EMPTY"
        typ == "POINT" && return Point(NaN, NaN, srid)
        typ == "LINESTRING" && return LineString(Coord[], srid)
        typ == "POLYGON" && return Polygon(Vector{Coord}[], srid)
    end
    typ == "POINT" && (c = (expect("("); p = pt(); expect(")"); p); return Point(c[1], c[2], srid))
    typ == "LINESTRING" && return LineString(coords(), srid)
    typ == "POLYGON" && return Polygon(rings(), srid)
    if typ == "MULTIPOINT"
        expect("(")
        ps = Point[]
        while true
            if peek() == "("; next(); c = pt(); expect(")") else c = pt() end
            push!(ps, Point(c[1], c[2], srid))
            peek() == "," ? next() : break
        end
        expect(")")
        return MultiPoint(ps, srid)
    end
    typ == "MULTILINESTRING" && return MultiLineString([LineString(r, srid) for r in rings()], srid)
    if typ == "MULTIPOLYGON"
        expect("(")
        ps = [Polygon(rings(), srid)]
        while peek() == ","; next(); push!(ps, Polygon(rings(), srid)); end
        expect(")")
        return MultiPolygon(ps, srid)
    end
    throw(ArgumentError("unsupported geometry type '$typ'"))
end

# --- WKB (what PostGIS returns, as hex EWKB) -----------------------------------------------------------

"Parse (E)WKB, given as bytes or a hex string."
parse_wkb(hex::AbstractString) = parse_wkb(hex2bytes(hex))
function parse_wkb(bytes::AbstractVector{UInt8}; srid::Integer = 4326)
    io = IOBuffer(bytes)
    read_geom(io, Int(srid))
end
function read_geom(io, srid)
    le = read(io, UInt8) == 1
    rd(T) = (v = read(io, T); le ? ltoh(v) : ntoh(v))
    t = rd(UInt32)
    hasz = t & 0x80000000 != 0 || (t % 1000) != t && (t ÷ 1000) in (1, 3)
    hasm = t & 0x40000000 != 0 || (t ÷ 1000) in (2, 3)
    t & 0x20000000 != 0 && (srid = Int(rd(UInt32)))
    base = Int((t & 0x0fffffff) % 1000)
    pt() = (x = rd(Float64); y = rd(Float64); hasz && rd(Float64); hasm && rd(Float64); (x, y))
    pts() = Coord[pt() for _ in 1:rd(UInt32)]
    base == 1 && (c = pt(); return Point(c[1], c[2], srid))
    base == 2 && return LineString(pts(), srid)
    base == 3 && return Polygon([pts() for _ in 1:rd(UInt32)], srid)
    base in (4, 5, 6) || throw(ArgumentError("unsupported WKB geometry type $base"))
    parts = [read_geom(io, srid) for _ in 1:rd(UInt32)]
    base == 4 && return MultiPoint(Point[with_srid(p, srid) for p in parts], srid)
    base == 5 && return MultiLineString(LineString[with_srid(p, srid) for p in parts], srid)
    MultiPolygon(Polygon[with_srid(p, srid) for p in parts], srid)
end

# --- GeoJSON ---------------------------------------------------------------------------------------------

gj(cs::Vector{Coord}) = [[c[1], c[2]] for c in cs]
"GeoJSON geometry object (a `Dict`)."
geojson(g::Point) = Dict{String,Any}("type" => "Point", "coordinates" => [g.x, g.y])
geojson(g::LineString) = Dict{String,Any}("type" => "LineString", "coordinates" => gj(g.coords))
geojson(g::Polygon) = Dict{String,Any}("type" => "Polygon", "coordinates" => [gj(r) for r in g.rings])
geojson(g::MultiPoint) = Dict{String,Any}("type" => "MultiPoint", "coordinates" => [[p.x, p.y] for p in g.geoms])
geojson(g::MultiLineString) = Dict{String,Any}("type" => "MultiLineString", "coordinates" => [gj(l.coords) for l in g.geoms])
geojson(g::MultiPolygon) = Dict{String,Any}("type" => "MultiPolygon", "coordinates" => [[gj(r) for r in p.rings] for p in g.geoms])

"Read a GeoJSON geometry (`Dict` or JSON text). GeoJSON is always SRID 4326."
function from_geojson(d)
    d isa AbstractString && (d = JSON.parse(d))
    t, c = d["type"], d["coordinates"]
    cs(x) = Coord[(Float64(p[1]), Float64(p[2])) for p in x]
    t == "Point" && return Point(c[1], c[2])
    t == "LineString" && return LineString(cs(c))
    t == "Polygon" && return Polygon([cs(r) for r in c], 4326)
    t == "MultiPoint" && return MultiPoint([Point(p[1], p[2]) for p in c])
    t == "MultiLineString" && return MultiLineString([LineString(cs(l)) for l in c])
    t == "MultiPolygon" && return MultiPolygon([Polygon([cs(r) for r in p], 4326) for p in c])
    throw(ArgumentError("unsupported GeoJSON type '$t'"))
end

"""
    geojson(qs; geometry=:location, properties=nothing) -> Dict

A GeoJSON FeatureCollection of a queryset. `properties` are field names (default: all
non-geometry fields); each feature's `id` is the object's id.
"""
function geojson(qs::QuerySet{T}; geometry::Symbol, properties = nothing) where {T}
    props = properties === nothing ? [f.name for f in all_fields(T) if f.kind !== :geometry] : Symbol.(properties)
    feats = Any[]
    for o in qs
        g = getproperty(o, geometry)
        push!(feats, Dict{String,Any}("type" => "Feature", "id" => json_scalar(o.id),
                                      "geometry" => g === nothing ? nothing : geojson(g),
                                      "properties" => Dict{String,Any}(string(p) => json_scalar(getproperty(o, p) isa Model ? getproperty(o, p).id : getproperty(o, p)) for p in props)))
    end
    Dict{String,Any}("type" => "FeatureCollection", "features" => feats)
end

# --- distances -------------------------------------------------------------------------------------------

"A distance for spatial lookups: `D(km=5)`, `D(m=300)`, `D(mi=2)`; stored in metres."
struct D
    m::Float64
end
D(; m = 0, km = 0, mi = 0, ft = 0, nm = 0) = D(Float64(m + 1000km + 1609.344mi + 0.3048ft + 1852nm))
meters(d::D) = d.m
meters(x::Real) = Float64(x)

# --- fields ------------------------------------------------------------------------------------------------

"""
    GeometryField(; srid=4326, geom_type=:GEOMETRY, geography=false, spatial_index=true, kw...)

A PostGIS geometry column (`geometry(POINT, 4326)`; `geography=true` for `geography`). A GiST
index is created unless `spatial_index=false`. Needs PostgreSQL with PostGIS.
"""
GeometryField(; srid = 4326, geom_type = :GEOMETRY, geography = false, spatial_index = true, kw...) =
    (f = Field(:geometry; db_index = spatial_index, kw...); f.related = (Symbol(uppercase(string(geom_type))), Int(srid), geography); f)
PointField(; kw...) = GeometryField(; geom_type = :POINT, kw...)
LineStringField(; kw...) = GeometryField(; geom_type = :LINESTRING, kw...)
PolygonField(; kw...) = GeometryField(; geom_type = :POLYGON, kw...)
MultiPointField(; kw...) = GeometryField(; geom_type = :MULTIPOINT, kw...)
MultiLineStringField(; kw...) = GeometryField(; geom_type = :MULTILINESTRING, kw...)
MultiPolygonField(; kw...) = GeometryField(; geom_type = :MULTIPOLYGON, kw...)

geo_spec(f::Field) = f.related::Tuple{Symbol,Int,Bool}
function geo_of(f::Field)
    t, s, g = geo_spec(f)
    Symbol(t, ":", s, g ? ":geog" : "")
end
function geo_parse_of(of::Symbol)
    parts = split(string(of), ":")
    (parts[1], parse(Int, parts[2]), length(parts) > 2)
end

"Column type of a geometry column (`of` is `TYPE:SRID[:geog]`)."
geometry_column_type(::DatabaseBackend, of) =
    throw(ImproperlyConfigured("GIS fields need PostgreSQL with PostGIS (the current database is $(vendor(backend())))"))
function geometry_column_type(::PostgresBackend, of)
    t, s, geog = geo_parse_of(of)
    "$(geog ? "geography" : "geometry")($t, $s)"
end

decode_geometry(v::Geometry) = v
decode_geometry(v::AbstractString) = occursin(r"^[0-9A-Fa-f]+$", v) ? parse_wkb(v) : parse_wkt(v)
encode_geometry(g::Geometry) = ewkt(g)

"A geometry parameter in the field's SRID, as SQL."
function geom_param(f::Field, g::Geometry)
    _, srid, _ = geo_spec(f)
    g.srid == srid ? ("ST_GeomFromEWKT(?)", Any[ewkt(g)]) : ("ST_Transform(ST_GeomFromEWKT(?), $srid)", Any[ewkt(g)])
end
is_geodetic(f::Field) = (s = geo_spec(f); s[3] || s[2] == 4326)
as_geom(f::Field, col) = geo_spec(f)[3] ? "CAST($col AS geometry)" : col

const SPATIAL_FUNCS = Dict("intersects" => "ST_Intersects", "within" => "ST_Within", "contains" => "ST_Contains",
                           "covers" => "ST_Covers", "coveredby" => "ST_CoveredBy", "disjoint" => "ST_Disjoint",
                           "touches" => "ST_Touches", "crosses" => "ST_Crosses", "overlaps" => "ST_Overlaps",
                           "equals" => "ST_Equals", "exact" => "ST_Equals")

function spatial_lookup(f::Field, col, lookup, value)
    if haskey(SPATIAL_FUNCS, lookup)
        value isa Geometry || throw(LookupError("spatial lookup '$lookup' needs a geometry, got $(typeof(value))"))
        g, ps = geom_param(f, value)
        return "$(SPATIAL_FUNCS[lookup])($(as_geom(f, col)), $g)", ps
    end
    if lookup in ("distance_lt", "distance_lte", "distance_gt", "distance_gte", "dwithin")
        (value isa Tuple && length(value) == 2 && value[1] isa Geometry) ||
            throw(LookupError("'$lookup' takes (geometry, distance), e.g. (Point(1, 2), D(km = 5))"))
        g, ps = geom_param(f, value[1])
        d = meters(value[2])
        a, bsql = is_geodetic(f) ? ("CAST($col AS geography)", "CAST($g AS geography)") : (col, g)
        lookup == "dwithin" && return "ST_DWithin($a, $bsql, $d)", ps
        op = Dict("distance_lt" => "<", "distance_lte" => "<=", "distance_gt" => ">", "distance_gte" => ">=")[lookup]
        return "ST_Distance($a, $bsql) $op $d", ps
    end
    nothing
end

# --- expressions --------------------------------------------------------------------------------------------

"`Distance(:location, point)`: distance in metres (geodetic for SRID 4326/geography), else SRID units."
struct Distance <: Expression
    field::String
    geom::Geometry
end
Distance(f, g::Geometry) = Distance(string(f), g)
"`Area(:region)`: square metres for SRID 4326/geography, else SRID units."
struct Area <: Expression
    field::String
end
Area(f::Union{Symbol,AbstractString}) = Area(string(f))
"`GeoLength(:route)`: length in metres for SRID 4326/geography."
struct GeoLength <: Expression
    field::String
end
GeoLength(f::Union{Symbol,AbstractString}) = GeoLength(string(f))
"`AsGeoJSON(:location)`: the geometry as GeoJSON text."
struct AsGeoJSON <: Expression
    field::String
end
AsGeoJSON(f::Union{Symbol,AbstractString}) = AsGeoJSON(string(f))

function geo_field(c::SQLCompiler, name)
    col, f = resolve_path(c, c.base, c.T, name)
    (f === nothing || f.kind !== :geometry) && throw(LookupError("'$name' is not a geometry field"))
    col, f
end
function compile_expr(c::SQLCompiler, e::Distance)
    col, f = geo_field(c, e.field)
    g, ps = geom_param(f, e.geom)
    (is_geodetic(f) ? "ST_Distance(CAST($col AS geography), CAST($g AS geography))" : "ST_Distance($col, $g)"), ps
end
compile_expr(c::SQLCompiler, e::Area) = ((col, f) = geo_field(c, e.field);
    (is_geodetic(f) ? "ST_Area(CAST($col AS geography))" : "ST_Area($col)", Any[]))
compile_expr(c::SQLCompiler, e::GeoLength) = ((col, f) = geo_field(c, e.field);
    (is_geodetic(f) ? "ST_Length(CAST($col AS geography))" : "ST_Length($col)", Any[]))
compile_expr(c::SQLCompiler, e::AsGeoJSON) = ((col, f) = geo_field(c, e.field); ("ST_AsGeoJSON($(as_geom(f, col)))", Any[]))

# --- forms and the admin map widget --------------------------------------------------------------------------

"Parse form input for a geometry field: WKT, EWKT or GeoJSON."
function parse_geometry_input(f::Field, s::AbstractString)
    t, srid, _ = geo_spec(f)
    g = startswith(strip(s), "{") ? from_geojson(s) : parse_wkt(s; srid = srid)
    (t === :GEOMETRY || geom_type(g) == string(t)) ||
        throw(ArgumentError("Expected a $(lowercase(string(t))), got a $(lowercase(geom_type(g)))."))
    g
end

const LEAFLET = "https://unpkg.com/leaflet@1.9.4/dist"

"A textarea (WKT/GeoJSON) with a Leaflet map; clicking the map sets a point."
function geometry_widget(name, id, f::Field, val)
    t, srid, _ = geo_spec(f)
    g = val isa Geometry ? val : nothing
    text = g === nothing ? (val === nothing ? "" : string(val)) : ewkt(g)
    gjs = g === nothing ? "null" : JSON.json(geojson(g))
    """<div class="geo-widget">
    <div id="$(id)_map" class="geo-map" style="height:300px;margin-bottom:6px;border:1px solid var(--border, #ccc)"
         data-geom-type="$(t)" data-srid="$(srid)"></div>
    <textarea name="$name" id="$id" rows="3" cols="60" placeholder="WKT (POINT(lon lat)) or GeoJSON">$(escape_html(text))</textarea>
    <link rel="stylesheet" href="$LEAFLET/leaflet.css">
    <script src="$LEAFLET/leaflet.js"></script>
    <script>(function(){
      var ta = document.getElementById("$id"), el = document.getElementById("$(id)_map");
      if (!window.L) { el.style.display = "none"; return; }
      var map = L.map(el).setView([0, 0], 1), layer = null;
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {maxZoom: 19, attribution: "&copy; OpenStreetMap"}).addTo(map);
      function show(gj) { if (layer) map.removeLayer(layer); if (!gj) return; layer = L.geoJSON(gj).addTo(map);
        var b = layer.getBounds(); if (b.isValid()) map.fitBounds(b, {maxZoom: 14}); }
      show($gjs);
      if (el.dataset.geomType === "POINT" && el.dataset.srid === "4326") {
        map.on("click", function(e) { var x = e.latlng.lng.toFixed(6), y = e.latlng.lat.toFixed(6);
          ta.value = "SRID=4326;POINT(" + x + " " + y + ")"; show({type: "Point", coordinates: [+x, +y]}); });
      }
    })();</script>
    </div>"""
end
