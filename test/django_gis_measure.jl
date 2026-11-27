# Django's gis_tests test_measure, ported (#227): DistanceTest and AreaTest. Django's measure objects Distance (D) and
# Area (A) are Juango's D and A (Juango's Distance and Area are the database functions). Python's `x += y` is
# `x = x + y`; a unit the object doesn't have is an ArgumentError (Django's AttributeError) and arithmetic with the
# wrong kind of value one too (Django's TypeError); `repr` shows `D(m=100.0)` (Django's `Distance(m=100.0)`).
# julia --project=test test/django_gis_measure.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

const GD, GA = Juango.D, Juango.A
gm_throws(f) = try f(); false catch e; e isa ArgumentError end

@testset "django gis_tests test_measure: DistanceTest" begin
    @test GD(m = 100).m == 100                                                       # test_init
    @test all(d -> d.m == 100, (GD(m = 100), GD(meter = 100), GD(metre = 100)))
    @test GD(nm = 100).m == 185200
    @test all(d -> d.yd == 100, (GD(yd = 100), GD(yard = 100), GD(Yard = 100)))
    @test all(d -> d.m == 1.0 && d.mm == 1000.0, (GD(millimeter = 1000), GD(MiLLiMeTeR = 1000)))
    @test gm_throws(() -> GD(banana = 100))                                          # test_init_invalid
    @test gm_throws(() -> GD(ha = 100))                                              # test_init_invalid_area_only_units
    d = GD(m = 100)                                                                  # test_access
    @test d.km == 0.1 && isapprox(d.ft, 328.084; atol = 5e-4)
    @test !hasproperty(d, :banana) && gm_throws(() -> d.banana)                      # test_access_invalid
    d1, d2 = GD(m = 100), GD(m = 200)                                                # test_addition
    d3 = d1 + d2; @test d3.m == 300
    d3 += d1; @test d3.m == 400
    d4 = d1 - d2; @test d4.m == -100
    d4 -= d1; @test d4.m == -200
    @test gm_throws(() -> d1 + 1) && gm_throws(() -> d1 - 1)
    d1 = GD(m = 100)                                                                 # test_multiplication
    @test (d1 * 2).m == 200 && (2 * d1).m == 200
    d3 = d1 * 2; d3 *= 5; @test d3.m == 1000
    d4 = d1 / 2; @test d4.m == 50
    d4 /= 5; @test d4.m == 10
    @test d1 / GD(m = 2) == 50
    a5 = d1 * GD(m = 10)
    @test a5 isa GA && a5.sq_m == 100 * 10
    d1, d2 = GD(m = 100), GD(km = 1)                                                 # test_unit_conversions
    @test (d1 + d2).unit == "m" && (d2 + d1).unit == "km" && (d1 * 2).unit == "m" && (d1 / 2).unit == "m"
    d3 = GD(km = 0)                                                                  # test_comparisons
    @test d2 > d1 && d1 == d1 && d1 < d2 && iszero(d3)
    @test string(GD(m = 100)) == "100.0 m" && string(GD(km = 3.5)) == "3.5 km"      # test_units_str
    @test repr(GD(m = 100)) == "D(m=100.0)" && repr(GD(km = 3.5)) == "D(km=3.5)"
    @test GD(m = 201.168).furlong == 1                                               # test_furlong
    for (nm, att) in [("Yard", "yd"), ("Nautical Mile", "nm"), ("German legal metre", "german_m"),   # test_unit_att_name
                      ("Indian yard", "indian_yd"), ("Chain (Sears)", "chain_sears"), ("Chain", "chain"), ("Furrow Long", "furlong")]
        @test Juango.unit_attname(GD, nm) == att
    end
    for T in (GD, GA)                                                                # test_unit_att_name_invalid
        e = try Juango.unit_attname(T, "invalid-unit-name"); nothing catch err; err end
        @test e isa ArgumentError && occursin("Unknown unit type: invalid-unit-name", e.msg)
    end
    @test hash(GD(m = 100)) == hash(GD(km = 0.1)) && hash(GD(m = 99)) != hash(GD(m = 100))   # test_hash
    @test hash(GD(m = 99)) != hash(GD(km = 0.1))
    # (a distance still works where spatial lookups take one: metres)
    @test Juango.meters(GD(km = 5)) == 5000.0 && Juango.meters(GD(mi = 2)) == 2 * 1609.344
    @test GD(5000) == GD(km = 5) && GD(km = 5, default_unit = "mi").unit == "mi"
end

@testset "django gis_tests test_measure: AreaTest" begin
    @test GA(sq_m = 100).sq_m == 100                                                 # test_init
    @test GA(sq_mi = 100).sq_m == 258998811.0336
    @test gm_throws(() -> GA(banana = 100))                                          # test_init_invalid_a
    a = GA(sq_m = 100)                                                               # test_access
    @test a.sq_km == 0.0001 && isapprox(a.sq_ft, 1076.391; atol = 5e-4)
    @test !hasproperty(a, :banana)                                                   # test_access_invalid_a
    a1, a2 = GA(sq_m = 100), GA(sq_m = 200)                                          # test_addition
    a3 = a1 + a2; @test a3.sq_m == 300
    a3 += a1; @test a3.sq_m == 400
    a4 = a1 - a2; @test a4.sq_m == -100
    a4 -= a1; @test a4.sq_m == -200
    @test gm_throws(() -> a1 + 1) && gm_throws(() -> a1 - 1)
    @test (a1 * 2).sq_m == 200 && (2 * a1).sq_m == 200                               # test_multiplication
    a3 = a1 * 2; a3 *= 5; @test a3.sq_m == 1000
    a4 = a1 / 2; @test a4.sq_m == 50
    a4 /= 5; @test a4.sq_m == 10
    @test gm_throws(() -> a1 * GA(sq_m = 1)) && gm_throws(() -> a1 / GA(sq_m = 1))
    a1, a2 = GA(sq_m = 100), GA(sq_km = 1)                                           # test_unit_conversions
    @test (a1 + a2).unit == "sq_m" && (a2 + a1).unit == "sq_km" && (a1 * 2).unit == "sq_m" && (a1 / 2).unit == "sq_m"
    @test a2 > a1 && a1 == a1 && a1 < a2 && iszero(GA(sq_km = 0))                   # test_comparisons
    @test string(GA(sq_m = 100)) == "100.0 sq_m" && string(GA(sq_km = 3.5)) == "3.5 sq_km"   # test_units_str
    @test repr(GA(sq_m = 100)) == "A(sq_m=100.0)" && repr(GA(sq_km = 3.5)) == "A(sq_km=3.5)"
    @test GA(sq_m = 10000).ha == 1                                                   # test_hectare
    @test Juango.unit_attname(GA, "Hectare") == "ha"                                 # test_hectare_unit_att_name
    @test hash(GA(sq_m = 1000000)) == hash(GA(sq_km = 1)) && hash(GA(sq_m = 100)) != hash(GA(sq_m = 1000000))   # test_hash
end
