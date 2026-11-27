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
    isempty(rs) && return Polygon(Vector{Coord}[], Int(srid))                                  # (an empty polygon)
    (rs[1] isa Tuple || rs[1] isa AbstractVector{<:Real}) && (rs = [rs])   # a single ring
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
"`GeometryCollection([geometry, ...]; srid=4326)`: geometries of any kinds together (PostGIS gives an empty one for an empty result)."
struct GeometryCollection <: Geometry
    geoms::Vector{Geometry}
    srid::Int
end
GeometryCollection(gs; srid::Integer = 4326) = GeometryCollection(Geometry[g for g in gs], Int(srid))

Base.:(==)(a::G, b::G) where {G<:Geometry} = all(getfield(a, f) == getfield(b, f) for f in fieldnames(G))
Base.:(==)(a::Point, b::Point) = a.srid == b.srid && (a.x == b.x && a.y == b.y || isempty(a) && isempty(b))
"""
    isapprox(a::Geometry, b::Geometry; atol = 0)

The same kind of geometry with the same points in the same order, each coordinate within `atol` (Django's
`equals_exact(other, tolerance)`).
"""
function Base.isapprox(a::Geometry, b::Geometry; atol::Real = 0)
    typeof(a) == typeof(b) || return false
    pa, pb = collect_points!(Coord[], a), collect_points!(Coord[], b)
    length(pa) == length(pb) && coords_shape(a) == coords_shape(b) &&
        all(abs(p[1] - q[1]) <= atol && abs(p[2] - q[2]) <= atol for (p, q) in zip(pa, pb))
end
coords_shape(g::Point) = isempty(g) ? 0 : 1
coords_shape(g::LineString) = length(g.coords)
coords_shape(g::Polygon) = length.(g.rings)
coords_shape(g::Union{MultiPoint,MultiLineString,MultiPolygon,GeometryCollection}) = Any[(typeof(x), coords_shape(x)) for x in g.geoms]
"Whether a geometry has no points (`POINT EMPTY`, `GEOMETRYCOLLECTION EMPTY`; Django's `geom.empty`)."
Base.isempty(g::Point) = isnan(g.x)
Base.isempty(g::LineString) = isempty(g.coords)
Base.isempty(g::Polygon) = all(isempty, g.rings)
Base.isempty(g::Union{MultiPoint,MultiLineString,MultiPolygon,GeometryCollection}) = all(isempty, g.geoms)
"The coordinates: `(x, y)` for a point, the points of a line, the rings of a polygon, those of each part of a collection (Django's `geom.coords`)."
coords(g::Point) = (g.x, g.y)
coords(g::LineString) = g.coords
coords(g::Polygon) = g.rings
coords(g::Union{MultiPoint,MultiLineString,MultiPolygon,GeometryCollection}) = [coords(x) for x in g.geoms]
"The number of points (Django's `geom.num_points`)."
num_points(g::Point) = isempty(g) ? 0 : 1
num_points(g::LineString) = length(g.coords)
num_points(g::Polygon) = sum(length, g.rings; init = 0)
num_points(g::Union{MultiPoint,MultiLineString,MultiPolygon,GeometryCollection}) = sum(num_points, g.geoms; init = 0)
"The bounding box, `(xmin, ymin, xmax, ymax)` (Django's `geom.extent`); `nothing` when empty."
function extent(g::Geometry)
    ps = Coord[]
    collect_points!(ps, g)
    isempty(ps) && return nothing
    (minimum(first, ps), minimum(last, ps), maximum(first, ps), maximum(last, ps))
end
collect_points!(ps, g::Point) = isempty(g) ? ps : push!(ps, (g.x, g.y))
collect_points!(ps, g::LineString) = append!(ps, g.coords)
collect_points!(ps, g::Polygon) = (foreach(r -> append!(ps, r), g.rings); ps)
collect_points!(ps, g::Union{MultiPoint,MultiLineString,MultiPolygon,GeometryCollection}) = (foreach(x -> collect_points!(ps, x), g.geoms); ps)
Base.hash(g::Geometry, h::UInt) = hash(wkt(g), h)
Base.show(io::IO, g::Geometry) = print(io, ewkt(g))
display_string(g::Geometry) = ewkt(g)
geom_type(g::Geometry) = uppercase(string(nameof(typeof(g))))
with_srid(g::Point, s) = Point(g.x, g.y, s)
with_srid(g::G, s) where {G<:Geometry} = G((getfield(g, f) for f in fieldnames(G)[1:end-1])..., s)

# --- WKT --------------------------------------------------------------------------------------------

fmtnum(x::Float64) = isinteger(x) && abs(x) < 1e15 ? string(Int(x)) : string(x)
wkt_coords(cs) = join([fmtnum(c[1]) * " " * fmtnum(c[2]) for c in cs], ", ")
wkt_body(g::Point) = "(" * fmtnum(g.x) * " " * fmtnum(g.y) * ")"
wkt_body(g::LineString) = "(" * wkt_coords(g.coords) * ")"
wkt_body(g::Polygon) = "(" * join(["(" * wkt_coords(r) * ")" for r in g.rings], ", ") * ")"
wkt_body(g::Union{MultiPoint,MultiLineString,MultiPolygon}) = "(" * join([wkt_body(x) for x in g.geoms], ", ") * ")"
wkt_body(g::GeometryCollection) = "(" * join([wkt(x) for x in g.geoms], ", ") * ")"
"Well-known text: `POINT(1 2)`, `POINT EMPTY`."
wkt(g::Geometry) = geom_type(g) * (isempty(g) ? " EMPTY" : wkt_body(g))
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
    function geom()
        typ = uppercase(next())
        while uppercase(peek()) in ("Z", "M", "ZM"); next(); end
        if uppercase(peek()) == "EMPTY"
            next()
            typ == "POINT" && return Point(NaN, NaN, srid)
            typ == "LINESTRING" && return LineString(Coord[], srid)
            typ == "POLYGON" && return Polygon(Vector{Coord}[], srid)
            typ == "MULTIPOINT" && return MultiPoint(Point[], srid)
            typ == "MULTILINESTRING" && return MultiLineString(LineString[], srid)
            typ == "MULTIPOLYGON" && return MultiPolygon(Polygon[], srid)
            typ == "GEOMETRYCOLLECTION" && return GeometryCollection(Geometry[], srid)
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
        if typ == "GEOMETRYCOLLECTION"
            expect("(")
            gs = Geometry[geom()]
            while peek() == ","; next(); push!(gs, geom()); end
            expect(")")
            return GeometryCollection(gs, srid)
        end
        throw(ArgumentError("unsupported geometry type '$typ'"))
    end
    geom()
end

# --- WKB (what PostGIS returns, as hex EWKB) -----------------------------------------------------------

"Parse (E)WKB, given as bytes or a hex string."
parse_wkb(hex::AbstractString; srid::Integer = 4326) = parse_wkb(hex2bytes(hex); srid = srid)
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
    base in (4, 5, 6, 7) || throw(ArgumentError("unsupported WKB geometry type $base"))
    parts = [read_geom(io, srid) for _ in 1:rd(UInt32)]
    base == 7 && return GeometryCollection(Geometry[with_srid(p, srid) for p in parts], srid)
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
geojson(g::GeometryCollection) = Dict{String,Any}("type" => "GeometryCollection", "geometries" => [geojson(x) for x in g.geoms])

"Read a GeoJSON geometry (`Dict` or JSON text). GeoJSON is always SRID 4326."
function from_geojson(d)
    d isa AbstractString && (d = JSON.parse(d))
    d["type"] == "GeometryCollection" && return GeometryCollection(Geometry[from_geojson(x) for x in d["geometries"]])
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
Base.@nospecializeinfer function geojson(@nospecialize(qs::QuerySet); geometry::Symbol, properties = nothing)
    T = model_of(qs)
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

# D and A are Django's measure objects (django.contrib.gis.measure.Distance and Area: Juango's Distance and Area
# are the database functions): a length or an area in one of many units, kept in metres (square metres), that
# remembers the unit it was given in: `D(km = 5).mi`, `D(mi = 2) + D(km = 1)`, `D(m = 3) * D(m = 4) == A(sq_m = 12)`.

const DISTANCE_UNITS = Dict{String,Float64}(
    "chain" => 20.1168, "chain_benoit" => 20.116782, "chain_sears" => 20.1167645,
    "british_chain_benoit" => 20.1167824944, "british_chain_sears" => 20.1167651216,
    "british_chain_sears_truncated" => 20.116756, "cm" => 0.01, "british_ft" => 0.304799471539,
    "british_yd" => 0.914398414616, "clarke_ft" => 0.3047972654, "clarke_link" => 0.201166195164,
    "fathom" => 1.8288, "ft" => 0.3048, "furlong" => 201.168, "german_m" => 1.0000135965,
    "gold_coast_ft" => 0.304799710181508, "indian_yd" => 0.914398530744, "inch" => 0.0254, "km" => 1000.0,
    "link" => 0.201168, "link_benoit" => 0.20116782, "link_sears" => 0.20116765, "m" => 1.0, "mi" => 1609.344,
    "mm" => 0.001, "nm" => 1852.0, "nm_uk" => 1853.184, "rod" => 5.0292, "sears_yd" => 0.91439841,
    "survey_ft" => 0.304800609601, "um" => 0.000001, "yd" => 0.9144)
# the names of units in spatial reference systems' WKT
const DISTANCE_ALIAS = Dict{String,String}(
    "centimeter" => "cm", "foot" => "ft", "inches" => "inch", "kilometer" => "km", "kilometre" => "km",
    "meter" => "m", "metre" => "m", "micrometer" => "um", "micrometre" => "um", "millimeter" => "mm",
    "millimetre" => "mm", "mile" => "mi", "yard" => "yd", "British chain (Benoit 1895 B)" => "british_chain_benoit",
    "British chain (Sears 1922)" => "british_chain_sears", "British chain (Sears 1922 truncated)" => "british_chain_sears_truncated",
    "British foot (Sears 1922)" => "british_ft", "British foot" => "british_ft", "British yard (Sears 1922)" => "british_yd",
    "British yard" => "british_yd", "Clarke's Foot" => "clarke_ft", "Clarke's link" => "clarke_link",
    "Chain (Benoit)" => "chain_benoit", "Chain (Sears)" => "chain_sears", "Foot (International)" => "ft",
    "Furrow Long" => "furlong", "German legal metre" => "german_m", "Gold Coast foot" => "gold_coast_ft",
    "Indian yard" => "indian_yd", "Link (Benoit)" => "link_benoit", "Link (Sears)" => "link_sears",
    "Nautical Mile" => "nm", "Nautical Mile (UK)" => "nm_uk", "US survey foot" => "survey_ft", "U.S. Foot" => "survey_ft",
    "Yard (Indian)" => "indian_yd", "Yard (Sears)" => "sears_yd")
const AREA_UNITS = merge(Dict{String,Float64}("sq_" * k => v^2 for (k, v) in DISTANCE_UNITS), Dict("ha" => 10000.0))
const AREA_ALIAS = merge(Dict{String,String}(k => "sq_" * v for (k, v) in DISTANCE_ALIAS), Dict("hectare" => "ha"))

abstract type Measure end
"A distance: `D(km = 5)`, `D(m = 300)`, `D(mi = 2)`, `D(survey_ft = 10)`; `d.km`, `d.mi` in other units (Django's D)."
struct D <: Measure
    m::Float64                 # the length in metres
    unit::String               # the unit it shows in
end
"An area: `A(sq_km = 5)`, `A(ha = 2)`, `A(sq_mi = 1)`; `a.sq_m`, `a.ha` in other units (Django's A)."
struct A <: Measure
    sq_m::Float64
    unit::String
end
measure_units(::Type{D}) = DISTANCE_UNITS
measure_units(::Type{A}) = AREA_UNITS
measure_alias(::Type{D}) = DISTANCE_ALIAS
measure_alias(::Type{A}) = AREA_ALIAS
standard_unit(::Type{D}) = "m"
standard_unit(::Type{A}) = "sq_m"
standard(x::Measure) = getfield(x, 1)

"""
    unit_attname(D, unit) -> String

The unit's name as `D` knows it (Django's `unit_attname`): `"metre"` → `"m"`, `"Nautical Mile"` → `"nm"`.
"""
function unit_attname(::Type{T}, unit::AbstractString) where {T<:Measure}
    units, lower = measure_units(T), lowercase(unit)
    haskey(units, unit) && return String(unit)
    haskey(units, lower) && return lower
    for (k, v) in measure_alias(T)
        lowercase(k) == lower && return v
    end
    throw(ArgumentError("Unknown unit type: $unit"))
end
# the amount and unit of keyword arguments (Django's default_units): exact names, then aliases, then either ignoring case
function measure_value(::Type{T}, kw) where {T<:Measure}
    val, unit = 0.0, standard_unit(T)
    units, alias = measure_units(T), measure_alias(T)
    for (k, v) in kw
        k = string(k)
        u = haskey(units, k) ? k : haskey(alias, k) ? alias[k] : unit_attname(T, k)
        val += units[u] * Float64(v)
        unit = u
    end
    val, unit
end
function (::Type{T})(; default_unit = nothing, kw...) where {T<:Measure}
    v, u = measure_value(T, kw)
    T(v, default_unit isa AbstractString ? String(default_unit) : u)
end
D(m::Real) = D(Float64(m), "m")
A(sq_m::Real) = A(Float64(sq_m), "sq_m")

function Base.getproperty(x::T, name::Symbol) where {T<:Measure}
    name in fieldnames(T) && return getfield(x, name)
    name === :standard && return standard(x)
    units = measure_units(T)
    haskey(units, string(name)) || throw(ArgumentError("Unknown unit type: $name"))
    standard(x) / units[string(name)]
end
Base.propertynames(x::T) where {T<:Measure} = (fieldnames(T)..., Symbol.(keys(measure_units(T)))...)
# `D(m=100.0)` as code, "100.0 m" as text (Django's repr and str)
Base.show(io::IO, x::T) where {T<:Measure} = print(io, nameof(T), "(", x.unit, "=", getproperty(x, Symbol(x.unit)), ")")
Base.print(io::IO, x::Measure) = print(io, getproperty(x, Symbol(x.unit)), " ", x.unit)
Base.:(==)(a::T, b::T) where {T<:Measure} = standard(a) == standard(b)
Base.hash(x::Measure, h::UInt) = hash(standard(x), hash(typeof(x), h))
Base.isless(a::T, b::T) where {T<:Measure} = standard(a) < standard(b)
Base.:+(a::T, b::T) where {T<:Measure} = T(standard(a) + standard(b), a.unit)
Base.:-(a::T, b::T) where {T<:Measure} = T(standard(a) - standard(b), a.unit)
Base.:-(a::T) where {T<:Measure} = T(-standard(a), a.unit)
Base.:*(a::T, n::Real) where {T<:Measure} = T(standard(a) * n, a.unit)
Base.:*(n::Real, a::Measure) = a * n
Base.:*(a::D, b::D) = A(a.m * b.m, "sq_" * a.unit)             # a distance times a distance is an area
Base.:/(a::T, n::Real) where {T<:Measure} = T(standard(a) / n, a.unit)
Base.:/(a::D, b::D) = a.m / b.m                                # (a ratio)
Base.:/(::A, ::A) = throw(ArgumentError("A must be divided by a number"))
Base.:*(::A, ::A) = throw(ArgumentError("A must be multiplied with a number"))
Base.iszero(x::Measure) = iszero(standard(x))
Base.:+(::T, ::Any) where {T<:Measure} = throw(ArgumentError("$(nameof(T)) must be added with $(nameof(T))"))
Base.:-(::T, ::Any) where {T<:Measure} = throw(ArgumentError("$(nameof(T)) must be subtracted from $(nameof(T))"))

meters(d::D) = d.m
# a measure as a query parameter: its standard unit (`filter(qs; area__lt = A(sq_km = 5))` against square metres)
adapt_param(::DatabaseBackend, x::Measure) = standard(x)
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
geometry_placeholder(f::Field, v) =
    v isa Geometry && v.srid != geo_spec(f)[2] && v.srid != 0 ? "ST_Transform(ST_GeomFromEWKT(?), $(geo_spec(f)[2]))" : "?"
is_geodetic(f::Field) = (s = geo_spec(f); s[3] || s[2] == 4326)
as_geom(f::Field, col) = geo_spec(f)[3] ? "CAST($col AS geometry)" : col

const SPATIAL_FUNCS = Dict("intersects" => "ST_Intersects", "within" => "ST_Within", "contains" => "ST_Contains",
                           "covers" => "ST_Covers", "coveredby" => "ST_CoveredBy", "disjoint" => "ST_Disjoint",
                           "touches" => "ST_Touches", "crosses" => "ST_Crosses", "overlaps" => "ST_Overlaps",
                           "equals" => "ST_Equals", "exact" => "ST_Equals", "contains_properly" => "ST_ContainsProperly")
# PostGIS's bounding box operators (Django's bbcontains, contained, left, strictly_above, ...) and ~= (same_as)
const BBOX_OPS = Dict("bbcontains" => "~", "bboverlaps" => "&&", "contained" => "@", "left" => "<<", "right" => ">>",
                      "overlaps_left" => "&<", "overlaps_right" => "&>", "overlaps_above" => "|&>", "overlaps_below" => "&<|",
                      "strictly_above" => "|>>", "strictly_below" => "<<|", "same_as" => "~=")

"""
The right-hand side of a spatial lookup as SQL: a geometry; WKT, EWKT or (E)WKB hex text (in the field's SRID unless
it says); or an expression (`F(:poly)`, a GIS function, a subquery).
"""
function geom_rhs(c::SQLCompiler, f::Field, lookup, value)
    if value isa AbstractString
        t = strip(value)
        value = occursin(r"^[0-9A-Fa-f]+$", t) ? parse_wkb(t; srid = geo_spec(f)[2]) : parse_wkt(t; srid = geo_spec(f)[2])
    end
    value isa Geometry && return geom_param(f, value)
    value isa Expression && return compile_expr(c, value)
    value isa QuerySet && return compile_expr(c, Subquery(value))     # (point__within = values(qs, :mpoly))
    throw(LookupError("spatial lookup '$lookup' needs a geometry, got $(typeof(value))"))
end

function spatial_lookup(c::SQLCompiler, f::Field, col, lookup, value)
    lookup == "exact" && value === nothing && return nothing          # (poly = nothing: IS NULL, as everywhere)
    if haskey(SPATIAL_FUNCS, lookup)
        g, ps = geom_rhs(c, f, lookup, value)
        return "$(SPATIAL_FUNCS[lookup])($(as_geom(f, col)), $g)", ps
    end
    if haskey(BBOX_OPS, lookup)
        g, ps = geom_rhs(c, f, lookup, value)
        return "$(as_geom(f, col)) $(BBOX_OPS[lookup]) $g", ps
    end
    # poly__relate = (geom, "T*T***FF*"): a DE-9IM intersection matrix pattern
    if lookup == "relate"
        (value isa Tuple && length(value) == 2) ||
            throw(ArgumentError("relate takes (geometry, pattern), e.g. (Point(1, 2), \"T*T***FF*\"), got $(repr(value))"))
        pat = value[2]
        (pat isa AbstractString && occursin(r"^[012TF*]{9}$"i, pat)) || throw(ArgumentError("Invalid intersection matrix pattern \"$pat\"."))
        value[1] isa Union{Geometry,Expression,AbstractString} ||
            throw(ArgumentError("relate takes a geometry first, got $(repr(value[1]))"))
        g, ps = geom_rhs(c, f, lookup, value[1])
        return "ST_Relate($(as_geom(f, col)), $g, ?)", vcat(ps, Any[String(pat)])
    end
    # point__isempty = true, poly__isvalid = false, geom__geom_type = "POINT" (Django's isempty, isvalid, geom_type)
    if lookup in ("isempty", "isvalid")
        value isa Bool || throw(LookupError("'$lookup' takes true or false"))
        sql = "ST_Is$(lookup == "isempty" ? "Empty" : "Valid")($(as_geom(f, col)))"
        return value ? sql : "NOT $sql", Any[]
    end
    lookup == "geom_type" && return "GeometryType($(as_geom(f, col))) = ?", Any[uppercase(string(value))]
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

# --- GIS functions (Django's django.contrib.gis.db.models.functions) ------------------------------------------
#
#     annotate(objects(Country); c = Centroid(:mpoly), n = NumPoints(:mpoly), kml = AsKML(:mpoly))
#     annotate(objects(City); u = GeoUnion(:point, Point(-95.36, 29.76)))     # (Union is Julia's)
#
# The geometric arguments are geometry fields (a name), geometries and other GIS functions; the others go after
# them. Geometries in another SRID are transformed to the first geometric argument's (as Django's). Geometry
# results come back as geometries (with the SRID PostGIS gives them), the rest as numbers, text, booleans, bytes.

"""
    GeoFunc(name, func, geoms, params; output = :geometry, srid = nothing)

A PostGIS function `func` of the geometric arguments `geoms` (field names, geometries, GIS functions) and then
`params` (numbers, put in the SQL as literals; or expressions). `output`: `:geometry`, `:float`, `:int`, `:text`,
`:bool`, `:bytes`. `srid`: the result's SRID when it isn't the first argument's (Transform's, FromWKT's).
"""
struct GeoFunc <: ConvertedExpression
    name::String
    func::String
    geoms::Vector{Any}
    params::Vector{Any}
    output::Symbol
    srid::Union{Nothing,Int}
end
function GeoFunc(name, func, geoms, params = Any[]; output::Symbol = :geometry, srid = nothing)
    gs = Any[g isa Symbol ? string(g) : g for g in geoms]
    for (i, g) in enumerate(gs)
        g isa Union{AbstractString,F,Geometry,Expression} ||
            throw(ArgumentError("$name function requires a geometric argument in position $i."))
    end
    GeoFunc(String(name), String(func), gs, Any[params...], output, srid === nothing ? nothing : Int(srid))
end
Base.:(==)(a::GeoFunc, b::GeoFunc) = all(getfield(a, f) == getfield(b, f) for f in fieldnames(GeoFunc))
Base.hash(e::GeoFunc, h::UInt) = hash((e.func, e.geoms, e.params, e.srid), h)

geo_numeric(name, x) = x isa Union{Real,Decimal} && !(x isa Bool) ? x :
    throw(ArgumentError("$name: the arguments must be numbers, got $(repr(x))"))
"A number as SQL (a literal: PostGIS's functions take float8 and integer arguments, which parameters don't type)."
geo_literal(x::Integer) = string(x)
geo_literal(x::Real) = isfinite(x) ? repr(Float64(x)) : throw(ArgumentError("not a finite number: $x"))
geo_literal(x::Decimal) = string(x)

"The SRID of a geometric argument (or nothing: unknown)."
function geo_arg_srid(c::SQLCompiler, e::GeoFunc, i, a)
    a isa Geometry && return a.srid
    if a isa Union{AbstractString,F}
        name = a isa F ? a.name : a
        _, f = resolve_path(c, c.base, c.T, name)
        (f === nothing || f.kind !== :geometry) &&
            throw(ArgumentError("$(e.name) function requires a GeometryField in position $i, got $(f === nothing ? "nothing" : xml_type(f))."))
        return geo_spec(f)[2]
    end
    a isa GeoFunc && return geo_result_srid(c, a)
    nothing
end
geo_result_srid(c::SQLCompiler, e::GeoFunc) = e.srid !== nothing ? e.srid : isempty(e.geoms) ? nothing : geo_arg_srid(c, e, 1, e.geoms[1])

"A geometric argument as SQL (a geometry, in SRID `srid` when that's given)."
function geo_arg_sql(c::SQLCompiler, e::GeoFunc, i, a, srid)
    s = geo_arg_srid(c, e, i, a)
    sql, ps = if a isa Geometry
        "ST_GeomFromEWKT(?)", Any[ewkt(a)]
    elseif a isa Union{AbstractString,F}
        col, f = geo_field(c, a isa F ? a.name : a)
        as_geom(f, col), Any[]
    else
        compile_expr(c, a)
    end
    (srid === nothing || s === nothing || s == srid) ? (sql, ps) : ("ST_Transform($sql, $srid)", ps)
end

function compile_expr(c::SQLCompiler, e::GeoFunc)
    backend() isa PostgresBackend || throw(ImproperlyConfigured("GIS functions need PostgreSQL with PostGIS"))
    srid = isempty(e.geoms) ? nothing : geo_arg_srid(c, e, 1, e.geoms[1])
    parts = [geo_arg_sql(c, e, i, a, srid) for (i, a) in enumerate(e.geoms)]
    for x in e.params
        push!(parts, x isa Expression ? compile_expr(c, x) : x isa SQLFragment ? (x.sql, Any[]) : (geo_literal(x), Any[]))
    end
    sqls, ps = first.(parts), reduce(vcat, last.(parts); init = Any[])
    e.func == "<->" && return "($(sqls[1]) <-> $(sqls[2]))", ps
    # a perimeter of a geodetic field in metres, as Area's and GeoLength's
    if e.func == "ST_Perimeter" && e.geoms[1] isa Union{AbstractString,F}
        col, f = geo_field(c, e.geoms[1] isa F ? e.geoms[1].name : e.geoms[1])
        is_geodetic(f) && return "ST_Perimeter(CAST($col AS geography))", ps
    end
    if e.func == "ST_AsGML"                                   # (the version comes first)
        return "ST_AsGML($(sqls[2]), $(sqls[1]), $(sqls[3]))", ps
    end
    e.func * "(" * join(sqls, ", ") * ")", ps
end
"Literal SQL among a GIS function's arguments."
struct SQLFragment
    sql::String
end

function convert_result(e::GeoFunc, v)
    o = e.output
    o === :geometry && return v isa Geometry ? v : v isa AbstractString ?
        (occursin(r"^[0-9A-Fa-f]+$", v) ? parse_wkb(v; srid = 0) : parse_wkt(v; srid = 0)) : parse_wkb(Vector{UInt8}(v); srid = 0)
    o === :float && return v isa Real ? Float64(v) : parse(Float64, string(v))
    o === :int && return v isa Integer ? Int(v) : parse(Int, string(v))
    o === :bool && return v isa Bool ? v : v isa AbstractString ? v in ("t", "true", "1") : v != 0
    o === :bytes && return v isa AbstractString ? (startswith(v, "\\x") ? hex2bytes(v[3:end]) : Vector{UInt8}(codeunits(v))) : Vector{UInt8}(v)
    v isa AbstractString ? String(v) : v
end

geo_precision(name, p) = p isa Integer && !(p isa Bool) ? p : throw(ArgumentError("$name: precision must be an integer, got $(repr(p))"))

"`AsGeoJSON(geom; bbox = false, crs = false, precision = 8)`: the geometry as GeoJSON text."
function AsGeoJSON(g; bbox::Bool = false, crs::Bool = false, precision = 8)
    GeoFunc("AsGeoJSON", "ST_AsGeoJSON", [g], Any[geo_precision("AsGeoJSON", precision), (bbox ? 1 : 0) + (crs ? 2 : 0)]; output = :text)
end
"`AsGML(geom; version = 2, precision = 8)`: the geometry as GML."
AsGML(g; version::Integer = 2, precision = 8) =
    GeoFunc("AsGML", "ST_AsGML", [g], Any[version, geo_precision("AsGML", precision)]; output = :text)
"`AsKML(geom; precision = 8)`: the geometry as KML."
AsKML(g; precision = 8) = GeoFunc("AsKML", "ST_AsKML", [g], Any[geo_precision("AsKML", precision)]; output = :text)
"`AsSVG(geom; relative = false, precision = 8)`: the geometry as SVG path data (`cx=... cy=...` for a point)."
AsSVG(g; relative = false, precision = 8) =
    GeoFunc("AsSVG", "ST_AsSVG", [g], Any[relative isa Bool ? Int(relative) : geo_precision("AsSVG", relative), geo_precision("AsSVG", precision)]; output = :text)
"`AsWKB(geom)`: the geometry as WKB bytes."
AsWKB(g) = GeoFunc("AsWKB", "ST_AsBinary", [g]; output = :bytes)
"`AsWKT(geom)`: the geometry as WKT."
AsWKT(g) = GeoFunc("AsWKT", "ST_AsText", [g]; output = :text)
"`Azimuth(point_a, point_b)`: the angle from north, in radians (`nothing` when the points are the same)."
Azimuth(a, b) = GeoFunc("Azimuth", "ST_Azimuth", [a, b]; output = :float)
"`BoundingCircle(geom; num_seg = 48)`: the smallest circle around it, a polygon with `num_seg` segments a quarter."
BoundingCircle(g; num_seg = 48) = GeoFunc("BoundingCircle", "ST_MinimumBoundingCircle", [g], Any[num_seg isa Expression ? num_seg : Int(num_seg)])
"`Centroid(geom)`: the geometric centre."
Centroid(g) = GeoFunc("Centroid", "ST_Centroid", [g])
"`ClosestPoint(a, b)`: the point of `a` closest to `b`."
ClosestPoint(a, b) = GeoFunc("ClosestPoint", "ST_ClosestPoint", [a, b])
"`Difference(a, b)`: the part of `a` not in `b`."
Difference(a, b) = GeoFunc("Difference", "ST_Difference", [a, b])
"`Envelope(geom)`: the bounding box, as a polygon."
Envelope(g) = GeoFunc("Envelope", "ST_Envelope", [g])
"`ForcePolygonCW(geom)`: exterior rings clockwise, holes counter-clockwise."
ForcePolygonCW(g) = GeoFunc("ForcePolygonCW", "ST_ForcePolygonCW", [g])
"`FromWKB(bytes_expr; srid = 0)`: a geometry from WKB."
FromWKB(x; srid::Integer = 0) = GeoFunc("FromWKB", "ST_GeomFromWKB", Any[], Any[x isa Expression ? x : Value(x), srid]; srid = srid == 0 ? nothing : srid)
"`FromWKT(text_expr; srid = 0)`: a geometry from WKT."
FromWKT(x; srid::Integer = 0) = GeoFunc("FromWKT", "ST_GeomFromText", Any[], Any[x isa Expression ? x : Value(x), srid]; srid = srid == 0 ? nothing : srid)
"`GeoHash(geom; precision = nothing)`: the GeoHash of the geometry (PostGIS's full precision when nothing)."
GeoHash(g; precision = nothing) =
    GeoFunc("GeoHash", "ST_GeoHash", [g], precision === nothing ? Any[] : Any[geo_precision("GeoHash", precision)]; output = :text)
"`GeometryDistance(a, b)`: the 2D distance between the bounding boxes' centres (PostGIS's `<->`, index-assisted)."
GeometryDistance(a, b) = GeoFunc("GeometryDistance", "<->", [a, b]; output = :float)
"`GeometryType(geom)`: `\"POINT\"`, `\"POLYGON\"`, ..."
GeometryType(g) = GeoFunc("GeometryType", "GeometryType", [g]; output = :text)
"`Intersection(a, b)`: the part they share."
Intersection(a, b) = GeoFunc("Intersection", "ST_Intersection", [a, b])
"`IsEmpty(geom)`: whether it has no points."
IsEmpty(g) = GeoFunc("IsEmpty", "ST_IsEmpty", [g]; output = :bool)
"`IsValid(geom)`: whether it's well-formed (OGC's rules)."
IsValid(g) = GeoFunc("IsValid", "ST_IsValid", [g]; output = :bool)
"`LineLocatePoint(line, point)`: where on the line the point is closest, a fraction of its length (0 to 1)."
LineLocatePoint(l, p) = GeoFunc("LineLocatePoint", "ST_LineLocatePoint", [l, p]; output = :float)
"`MakeValid(geom)`: a valid geometry with the same points (another type, maybe)."
MakeValid(g) = GeoFunc("MakeValid", "ST_MakeValid", [g])
"`MemSize(geom)`: the bytes it takes."
MemSize(g) = GeoFunc("MemSize", "ST_MemSize", [g]; output = :int)
"`NumDimensions(geom)`: 2, or 3 for 3D coordinates."
NumDimensions(g) = GeoFunc("NumDimensions", "ST_NDims", [g]; output = :int)
"`NumGeometries(geom)`: the number of parts of a collection (1 for a single geometry)."
NumGeometries(g) = GeoFunc("NumGeometries", "ST_NumGeometries", [g]; output = :int)
"`NumPoints(geom)`: the number of points."
NumPoints(g) = GeoFunc("NumPoints", "ST_NPoints", [g]; output = :int)
"`Perimeter(geom)`: in metres for SRID 4326 and geography, else in the SRID's units."
Perimeter(g) = GeoFunc("Perimeter", "ST_Perimeter", [g]; output = :float)
"`PointOnSurface(geom)`: a point certain to lie on it."
PointOnSurface(g) = GeoFunc("PointOnSurface", "ST_PointOnSurface", [g])
# Reverse(:line) on a geometry field is ST_Reverse (expressions.jl; the same Reverse as the text function's, as Django's
# two Reverse functions read alike); of a geometry or a GIS function:
"`Reverse(geom)`: the points in reverse order (of a geometry field: `Reverse(:line)`)."
Reverse(g::Union{Geometry,GeoFunc}) = GeoFunc("Reverse", "ST_Reverse", [g])
"`Rotate(geom, angle; origin = nothing)`: rotated by `angle` radians counter-clockwise about `origin` (a Point; default (0, 0))."
function Rotate(g, angle; origin = nothing)
    origin === nothing || origin isa Point || throw(ArgumentError("origin argument must be a Point"))
    GeoFunc("Rotate", "ST_Rotate", [g], origin === nothing ? Any[geo_numeric("Rotate", angle)] :
            Any[geo_numeric("Rotate", angle), origin.x, origin.y])
end
"`Scale(geom, x, y)`: each coordinate multiplied."
Scale(g, x, y) = GeoFunc("Scale", "ST_Scale", [g], Any[geo_numeric("Scale", x), geo_numeric("Scale", y)])
"""
    SnapToGrid(geom, size)  /  SnapToGrid(geom, size_x, size_y)  /  SnapToGrid(geom, size_x, size_y, origin_x, origin_y)

Each point moved to the nearest point of a grid.
"""
function SnapToGrid(g, args...)
    length(args) in (1, 2, 4) || throw(ArgumentError("Must provide 1, 2, or 4 arguments to `SnapToGrid`."))
    a = Any[geo_numeric("SnapToGrid", x) for x in args]
    GeoFunc("SnapToGrid", "ST_SnapToGrid", [g], length(a) == 4 ? Any[a[3], a[4], a[1], a[2]] : a)   # (PostgreSQL: origin first)
end
"`SymDifference(a, b)`: the parts in one but not both."
SymDifference(a, b) = GeoFunc("SymDifference", "ST_SymDifference", [a, b])
"`Transform(geom, srid)`: in another spatial reference system."
Transform(g, srid::Integer) = GeoFunc("Transform", "ST_Transform", [g], Any[Int(srid)]; srid = srid)
"`Translate(geom, x, y)`: moved by (x, y)."
Translate(g, x, y) = GeoFunc("Translate", "ST_Translate", [g], Any[geo_numeric("Translate", x), geo_numeric("Translate", y)])
"`GeoUnion(a, b)`: the points in either (Django's Union function; `Union` is Julia's type union)."
GeoUnion(a, b) = GeoFunc("Union", "ST_Union", [a, b])

# --- GIS aggregates (Django's django.contrib.gis.db.models.aggregates) ------------------------------------------

"`Extent(:point)`: the bounding box of the geometries, `(xmin, ymin, xmax, ymax)` (an aggregate; `nothing` for no rows)."
Extent(x; filter = nothing) = Aggregate("ST_Extent", ref(x), false, filter)
"`Collect(:point)`: the geometries together, as one (a MultiPoint, ...; an aggregate)."
Collect(x; filter = nothing) = Aggregate("ST_Collect", ref(x), false, filter)
"`MakeLine(:point)`: a line through the points, in the rows' order (an aggregate)."
MakeLine(x; filter = nothing) = Aggregate("ST_MakeLine", ref(x), false, filter)
"`GeoUnion(:poly)`, one argument: the union of the geometries (an aggregate: Django's Union aggregate)."
GeoUnion(x; filter = nothing) = Aggregate("ST_UnionAgg", ref(x), false, filter)

function gis_aggregate_value(e::Aggregate, v)
    if e.func == "ST_Extent"
        m = match(r"BOX\(([-+0-9.eE]+) ([-+0-9.eE]+),([-+0-9.eE]+) ([-+0-9.eE]+)\)", string(v))
        m === nothing && throw(ArgumentError("unexpected extent $(repr(v))"))
        return Tuple(parse.(Float64, m.captures))
    end
    v isa Geometry ? v : v isa AbstractString ?
        (occursin(r"^[0-9A-Fa-f]+$", v) ? parse_wkb(v; srid = 0) : parse_wkt(v; srid = 0)) : parse_wkb(Vector{UInt8}(v); srid = 0)
end

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
