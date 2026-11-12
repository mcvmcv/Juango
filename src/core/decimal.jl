# Decimal numbers -------------------------------------------------------------------------------------
#
# An exact decimal number, like Python's `decimal.Decimal`, for `DecimalField`:
#
#     price = dec"19.99"                  # or Decimal("19.99"), Decimal(5), Decimal(0.1) == dec"0.1"
#     price * 3                           # dec"59.97"   (exact; integers and floats promote to Decimal)
#     round(dec"2.675"; digits = 2)       # dec"2.68"    (half to even; also RoundNearestTiesAway, RoundDown...)
#     round(dec"2.5"; digits = 2)         # dec"2.50"    (rounding to more places pads, like `quantize`)
#     dec"1" / 3                          # dec"0.3333333333333333333333333333" (28 significant digits)
#
# The value is `c * 10^q` with an integer coefficient, so a Decimal remembers its scale: `dec"1.50"`
# prints as 1.50 and equals `dec"1.5"`. Floats convert through their shortest representation
# (`Decimal(0.1) == dec"0.1"`).

"""
    Decimal(x)

An exact decimal number: from a string (`Decimal("19.99")`, also `dec"19.99"`), an integer, a
float (through its shortest representation) or another `Decimal`. Arithmetic with `+ - *` is
exact; `/` gives 28 significant digits as Python's `decimal` does. `round(d; digits)` rounds half to
even and pads to exactly `digits` places.
"""
struct Decimal <: Real
    c::BigInt      # coefficient, with the sign
    q::Int         # exponent: the value is c * 10^q
    Decimal(c::Integer, q::Integer, ::Val{:raw}) = new(BigInt(c), Int(q))
end

const DECIMAL_PRECISION = 28           # significant digits of a quotient, as Python's default context
const DECIMAL_RE = r"^\s*([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?\s*$"

Decimal(d::Decimal) = d
Decimal(n::Integer) = Decimal(n, 0, Val(:raw))
Decimal(x::AbstractFloat) = isfinite(x) ? parse(Decimal, string(Float64(x))) :
    throw(ArgumentError("$x can't be represented as a Decimal"))
Decimal(x::Rational) = Decimal(numerator(x)) / Decimal(denominator(x))
Decimal(s::AbstractString) = parse(Decimal, s)

function Base.tryparse(::Type{Decimal}, s::AbstractString)
    m = match(DECIMAL_RE, s)
    m === nothing && return nothing
    whole, frac = m[2], something(m[3], "")
    isempty(whole) && isempty(frac) && return nothing
    c = parse(BigInt, string(whole, frac))
    q = -length(frac) + (m[4] === nothing ? 0 : parse(Int, m[4]))
    Decimal(m[1] == "-" ? -c : c, q, Val(:raw))
end
function Base.parse(::Type{Decimal}, s::AbstractString)
    d = tryparse(Decimal, s)
    d === nothing && throw(ArgumentError("invalid decimal number: $(repr(s))"))
    d
end

"`dec\"19.99\"`: a `Decimal` literal."
macro dec_str(s)
    parse(Decimal, s)
end

"Digits after the decimal point (`scale(dec\"1.50\") == 2`)."
scale(d::Decimal) = max(-d.q, 0)

function Base.print(io::IO, d::Decimal)
    d.c < 0 && print(io, '-')
    digits = string(abs(d.c))
    if d.q >= 0
        print(io, digits, d.c == 0 ? "" : repeat('0', d.q))
    else
        n = -d.q
        length(digits) <= n && (digits = repeat('0', n - length(digits) + 1) * digits)
        print(io, digits[1:end-n], '.', digits[end-n+1:end])
    end
end
Base.show(io::IO, d::Decimal) = get(io, :compact, false) ? print(io, d) : print(io, "dec\"", d, "\"")
Base.string(d::Decimal) = sprint(print, d)

# --- comparisons and hashing ---------------------------------------------------------------------------

"Both coefficients at the smaller exponent."
aligned(a::Decimal, b::Decimal) = a.q == b.q ? (a.c, b.c, a.q) :
    a.q < b.q ? (a.c, b.c * big(10)^(b.q - a.q), a.q) : (a.c * big(10)^(a.q - b.q), b.c, b.q)

Base.:(==)(a::Decimal, b::Decimal) = ((x, y, _) = aligned(a, b); x == y)
Base.:(<)(a::Decimal, b::Decimal) = ((x, y, _) = aligned(a, b); x < y)
Base.:(<=)(a::Decimal, b::Decimal) = ((x, y, _) = aligned(a, b); x <= y)
Base.isless(a::Decimal, b::Decimal) = a < b
Base.cmp(a::Decimal, b::Decimal) = ((x, y, _) = aligned(a, b); cmp(x, y))
# Base hashes every Real through `decompose` (num * 2^pow / den), so `hash(dec"2.0") == hash(2)`
function Base.decompose(d::Decimal)
    d.q >= 0 && return (d.c * big(10)^d.q, 0, big(1))
    den = big(10)^(-d.q)
    g = gcd(d.c, den)                   # reduced, as hashing expects
    (div(d.c, g), 0, div(den, g))
end

# --- arithmetic ------------------------------------------------------------------------------------------

Base.promote_rule(::Type{Decimal}, ::Type{<:Integer}) = Decimal
Base.promote_rule(::Type{Decimal}, ::Type{<:AbstractFloat}) = Decimal
Base.promote_rule(::Type{Decimal}, ::Type{<:Rational}) = Decimal
Base.convert(::Type{Decimal}, x::Real) = Decimal(x)
Base.convert(::Type{Decimal}, d::Decimal) = d
(::Type{T})(d::Decimal) where {T<:AbstractFloat} = parse(T, string(d))
function (::Type{T})(d::Decimal) where {T<:Integer}
    isinteger(d) || throw(InexactError(nameof(T), T, d))
    T(d.q >= 0 ? d.c * big(10)^d.q : div(d.c, big(10)^(-d.q)))
end
Base.Rational{T}(d::Decimal) where {T} = Rational{T}(d.q >= 0 ? d.c * big(10)^d.q // 1 : d.c // big(10)^(-d.q))
Base.float(d::Decimal) = Float64(d)

Base.zero(::Type{Decimal}) = Decimal(0)
Base.one(::Type{Decimal}) = Decimal(1)
Base.iszero(d::Decimal) = iszero(d.c)
Base.isinteger(d::Decimal) = d.q >= 0 || iszero(rem(d.c, big(10)^(-d.q)))
Base.signbit(d::Decimal) = d.c < 0
Base.sign(d::Decimal) = Decimal(sign(d.c))
Base.abs(d::Decimal) = Decimal(abs(d.c), d.q, Val(:raw))
Base.:(-)(d::Decimal) = Decimal(-d.c, d.q, Val(:raw))
Base.:(+)(a::Decimal, b::Decimal) = ((x, y, q) = aligned(a, b); Decimal(x + y, q, Val(:raw)))
Base.:(-)(a::Decimal, b::Decimal) = ((x, y, q) = aligned(a, b); Decimal(x - y, q, Val(:raw)))
Base.:(*)(a::Decimal, b::Decimal) = Decimal(a.c * b.c, a.q + b.q, Val(:raw))

"Remove trailing zeros from the coefficient, but not past exponent `ideal`."
function strip_zeros(c::BigInt, q::Int, ideal::Int)
    while q < ideal && !iszero(c) && iszero(rem(c, 10))
        c = div(c, 10); q += 1
    end
    Decimal(c, q, Val(:raw))
end

"`round(c / 10^n)` for `n > 0`, with a rounding mode."
function shift_round(c::BigInt, n::Int, r::RoundingMode)
    d = big(10)^n
    quo, rest = divrem(c, d)            # truncated toward zero
    iszero(rest) && return quo
    away = if r === RoundToZero
        false
    elseif r === RoundFromZero
        true
    elseif r === RoundDown
        c < 0
    elseif r === RoundUp
        c > 0
    else                                # RoundNearest (ties to even), RoundNearestTiesAway, RoundNearestTiesUp
        twice = 2 * abs(rest)
        twice > d || (twice == d && (r === RoundNearestTiesAway || (r === RoundNearestTiesUp ? c > 0 : isodd(quo))))
    end
    away ? quo + sign(c) : quo
end

function Base.:(/)(a::Decimal, b::Decimal)
    iszero(b.c) && throw(DivideError())
    ideal = a.q - b.q
    iszero(a.c) && return Decimal(0, ideal, Val(:raw))
    # scale the dividend so the quotient has at least PRECISION + 1 digits, then round
    shift = max(0, DECIMAL_PRECISION + 1 - (ndigits(a.c) - ndigits(b.c)))
    quo, rest = divrem(a.c * big(10)^shift, b.c)
    q = ideal - shift
    if iszero(rest)
        return strip_zeros(quo, q, ideal)
    end
    extra = ndigits(quo) - DECIMAL_PRECISION
    if extra > 0
        # include a sticky digit for the discarded remainder so ties round correctly
        quo = shift_round(quo * 10 + sign(quo) * 1, extra + 1, RoundNearest)
        q += extra
    end
    Decimal(quo, q, Val(:raw))
end
Base.inv(d::Decimal) = Decimal(1) / d

"""
    round(d::Decimal, [r::RoundingMode]; digits = 0)

Round to exactly `digits` places, half to even by default (`RoundNearestTiesAway` rounds half
away from zero; `RoundDown`, `RoundUp`, `RoundToZero` and `RoundFromZero` work too). Rounding
to more places than `d` has pads with zeros: `round(dec"1.5"; digits = 2) == dec"1.50"`.
"""
function Base.round(d::Decimal, r::RoundingMode = RoundNearest; digits::Integer = 0)
    target = -Int(digits)
    d.q == target && return d
    d.q > target && return Decimal(d.c * big(10)^(d.q - target), target, Val(:raw))
    Decimal(shift_round(d.c, target - d.q, r), target, Val(:raw))
end
Base.trunc(d::Decimal; digits::Integer = 0) = round(d, RoundToZero; digits = digits)
Base.floor(d::Decimal; digits::Integer = 0) = round(d, RoundDown; digits = digits)
Base.ceil(d::Decimal; digits::Integer = 0) = round(d, RoundUp; digits = digits)
Base.round(::Type{T}, d::Decimal, r::RoundingMode = RoundNearest) where {T<:Integer} = T(round(d, r))
Base.trunc(::Type{T}, d::Decimal) where {T<:Integer} = T(trunc(d))
Base.floor(::Type{T}, d::Decimal) where {T<:Integer} = T(floor(d))
Base.ceil(::Type{T}, d::Decimal) where {T<:Integer} = T(ceil(d))

"""
    decimal_digits(d) -> (digits, decimals)

Total significant digits and digits after the point, as Django's `DecimalValidator` counts
them (trailing zeros after the point count: `dec"1.50"` has 3 digits, 2 decimals).
"""
function decimal_digits(d::Decimal)
    n = iszero(d.c) ? 1 : ndigits(d.c)
    d.q >= 0 && return (n + (iszero(d.c) ? 0 : d.q), 0)
    decimals = -d.q
    (max(n, decimals), decimals)
end

JSON.tostring(d::Decimal) = string(d)

"A value from a driver, a form or a fixture as a `Decimal` (floats through their shortest form)."
to_decimal(v::Decimal) = v
to_decimal(v::Union{Integer,AbstractFloat,Rational}) = Decimal(v)
to_decimal(v::AbstractString) = parse(Decimal, v)
to_decimal(v) = parse(Decimal, string(v))
