# Database functions ------------------------------------------------------------------------------------
#
#     using Juango.Functions                         # Django's django.db.models.functions
#     annotate(Product; shout = Upper(Replace(:name, "-", " ")), cheap = Least(:price, :sale_price))
#     annotate(Product; r = Round(:price, 1), h = SHA256(:name))
#     aggregate(Product; sd = StdDev(:price), names = StringAgg(:name, ", "; ordering = "name"))
#
# Names and literals: strings and symbols are field references (`Replace(:name, "-", " ")` replaces
# in the `name` field); the text arguments of Replace, LPad, StringAgg ... are literals.
# SQLite lacks many of these, so Juango registers them as functions on its connections.

const SQLITE_UDF = Dict{Symbol,String}()       # function name => the SQLite function Juango registers for it

"A function whose SQL is the same everywhere apart from the name: `NAME(args...)`."
fn(name::Symbol, args...) = Func(name, Any[args...])

lit_text(x) = x isa Expression ? x : Value(string(x))

# comparison
"The largest of the values (NULL if any is NULL, except on MySQL/SQLite... see the README)."
Greatest(xs...) = (length(xs) >= 2 || throw(ArgumentError("Greatest needs at least two expressions")); fn(:greatest, ref.(xs)...))
"The smallest of the values."
Least(xs...) = (length(xs) >= 2 || throw(ArgumentError("Least needs at least two expressions")); fn(:least, ref.(xs)...))
"NULL when `a` equals `b`, else `a`."
NullIf(a, b) = fn(:nullif, ref(a), ref(b))
"`expr COLLATE collation`, for comparing or ordering with a collation."
Collate(x, collation::AbstractString) =
    (occursin(r"^[A-Za-z0-9_.\-@]+$", collation) || throw(ArgumentError("invalid collation name")); fn(:collate, ref(x), Symbol(collation)))

# text
Replace(x, text, replacement = "") = fn(:replace, ref(x), lit_text(text), lit_text(replacement))
"Part of a string: from `pos` (1-based), `length` characters (or to the end)."
Substr(x, pos::Integer, length::Union{Nothing,Integer} = nothing) =
    length === nothing ? fn(:substr, ref(x), Value(pos)) : fn(:substr, ref(x), Value(pos), Value(length))
Left(x, n::Integer) = fn(:left, ref(x), Value(n))
Right(x, n::Integer) = fn(:right, ref(x), Value(n))
Trim(x) = fn(:trim, ref(x))
LTrim(x) = fn(:ltrim, ref(x))
RTrim(x) = fn(:rtrim, ref(x))
LPad(x, length::Integer, fill = " ") = fn(:lpad, ref(x), Value(length), lit_text(fill))
RPad(x, length::Integer, fill = " ") = fn(:rpad, ref(x), Value(length), lit_text(fill))
Repeat(x, n::Integer) = fn(:repeat, ref(x), Value(n))
Reverse(x) = fn(:reverse, ref(x))
"1-based position of `substring` in the string (0 when it isn't there)."
StrIndex(x, substring) = fn(:strindex, ref(x), ref(substring))
MD5(x) = fn(:md5, ref(x))
SHA256(x) = fn(:sha256, ref(x))
"The character with a code point."
Chr(x) = fn(:chr, ref(x))
"The code point of the first character."
Ord(x) = fn(:ord, ref(x))

# math
Abs(x) = fn(:abs, ref(x))
"Rounded to `precision` decimal places."
Round(x, precision::Integer = 0) = fn(:round, ref(x), Value(precision))
Ceil(x) = fn(:ceil, ref(x))
Floor(x) = fn(:floor, ref(x))
Mod(a, b) = fn(:mod, ref(a), ref(b))
Power(a, b) = fn(:power, ref(a), ref(b))
Sqrt(x) = fn(:sqrt, ref(x))
Sign(x) = fn(:sign, ref(x))
Ln(x) = fn(:ln, ref(x))
"The logarithm of `x` in `base`."
Log(base, x) = fn(:log, ref(base), ref(x))
Exp(x) = fn(:exp, ref(x))
Sin(x) = fn(:sin, ref(x)); Cos(x) = fn(:cos, ref(x)); Tan(x) = fn(:tan, ref(x)); Cot(x) = fn(:cot, ref(x))
ASin(x) = fn(:asin, ref(x)); ACos(x) = fn(:acos, ref(x)); ATan(x) = fn(:atan, ref(x))
ATan2(y, x) = fn(:atan2, ref(y), ref(x))
Degrees(x) = fn(:degrees, ref(x))
Radians(x) = fn(:radians, ref(x))
Pi() = fn(:pi)

const TEXT_FUNCS = (:replace, :substr, :trim, :ltrim, :rtrim, :lpad, :rpad, :repeat, :reverse, :md5, :sha256, :chr, :left, :right)
const MATH_FUNCS = (:abs, :ceil, :floor, :mod, :power, :sqrt, :sign, :ln, :log, :exp, :sin, :cos, :tan, :cot,
                    :asin, :acos, :atan, :atan2, :degrees, :radians, :pi)

"SQL for the functions above (`nothing` for the ones expressions.jl handles itself)."
function function_sql(b::DatabaseBackend, n::Symbol, sqls, e)
    n in (:greatest, :least, :nullif, :replace, :trim, :ltrim, :rtrim, :lpad, :rpad, :repeat, :reverse, :md5,
          :abs, :ceil, :floor, :mod, :power, :sqrt, :sign, :ln, :exp, :sin, :cos, :tan, :cot, :asin, :acos,
          :atan, :atan2, :degrees, :radians, :left, :right, :chr, :substr) &&
        return uppercase(string(n)) * "(" * join(sqls, ", ") * ")"
    n === :pi && return "PI()"
    n === :collate && return "($(sqls[1]) COLLATE \"$(e.args[2])\")"
    n === :strindex && return "STRPOS($(sqls[1]), $(sqls[2]))"
    n === :sha256 && return "ENCODE(SHA256(CONVERT_TO($(sqls[1]), 'UTF8')), 'hex')"
    n === :ord && return "ASCII($(sqls[1]))"
    n === :round && return "ROUND(CAST($(sqls[1]) AS NUMERIC), $(sqls[2]))"
    n === :log && return "LOG(CAST($(sqls[1]) AS NUMERIC), CAST($(sqls[2]) AS NUMERIC))"
    nothing
end
function function_sql(b::MySQLBackend, n::Symbol, sqls, e)
    n === :collate && return "($(sqls[1]) COLLATE $(e.args[2]))"
    n === :strindex && return "INSTR($(sqls[1]), $(sqls[2]))"
    n === :sha256 && return "SHA2($(sqls[1]), 256)"
    n === :ord && return "ORD($(sqls[1]))"
    n === :chr && return "CHAR($(sqls[1]) USING utf8mb4)"
    n === :round && return "ROUND($(sqls[1]), $(sqls[2]))"
    n === :log && return "LOG($(sqls[1]), $(sqls[2]))"
    invoke(function_sql, Tuple{DatabaseBackend,Symbol,Any,Any}, b, n, sqls, e)
end
function function_sql(b::SQLiteBackend, n::Symbol, sqls, e)
    n === :greatest && return "MAX(" * join(sqls, ", ") * ")"
    n === :least && return "MIN(" * join(sqls, ", ") * ")"
    n === :collate && return "($(sqls[1]) COLLATE $(e.args[2]))"
    n === :strindex && return "INSTR($(sqls[1]), $(sqls[2]))"
    n === :ord && return "UNICODE($(sqls[1]))"
    n === :chr && return "CHAR($(sqls[1]))"
    n === :left && return "SUBSTR($(sqls[1]), 1, $(sqls[2]))"
    n === :right && return "juango_right($(sqls[1]), $(sqls[2]))"
    n === :round && return "ROUND($(sqls[1]), $(sqls[2]))"
    n in (:nullif, :replace, :trim, :ltrim, :rtrim, :abs, :substr) && return uppercase(string(n)) * "(" * join(sqls, ", ") * ")"
    n === :pi && return "juango_pi()"
    "juango_$n(" * join(sqls, ", ") * ")"                 # registered below
end

# --- SQLite: Julia versions of the functions it lacks ----------------------------------------------------

nomiss(f) = (args...) -> any(a -> a === missing || a === nothing, args) ? missing : f(args...)
num(x) = x isa Number ? x : parse(Float64, string(x))
const SQLITE_SCALARS = Dict(
    "lpad" => (s, n, f) -> (s = string(s); n = Int(n); length(s) >= n ? first(s, n) : first(repeat(string(f), n), n - length(s)) * s),
    "rpad" => (s, n, f) -> (s = string(s); n = Int(n); length(s) >= n ? first(s, n) : s * first(repeat(string(f), n), n - length(s))),
    "repeat" => (s, n) -> repeat(string(s), max(Int(n), 0)),
    "reverse" => s -> reverse(string(s)),
    "right" => (s, n) -> (s = string(s); Int(n) <= 0 ? "" : last(s, Int(n))),
    "md5" => s -> bytes2hex(MD5_hash(codeunits(string(s)))),
    "sha256" => s -> bytes2hex(sha256(string(s))),
    "ceil" => x -> ceil(num(x)), "floor" => x -> floor(num(x)),
    "mod" => (a, b) -> (a isa Integer && b isa Integer) ? rem(a, b) : rem(num(a), num(b)),
    "power" => (a, b) -> num(a)^num(b), "sqrt" => x -> sqrt(num(x)), "sign" => x -> Int(sign(num(x))),
    "ln" => x -> log(num(x)), "log" => (b, x) -> log(num(b), num(x)), "exp" => x -> exp(num(x)),
    "sin" => x -> sin(num(x)), "cos" => x -> cos(num(x)), "tan" => x -> tan(num(x)), "cot" => x -> cot(num(x)),
    "asin" => x -> asin(num(x)), "acos" => x -> acos(num(x)), "atan" => x -> atan(num(x)),
    "atan2" => (y, x) -> atan(num(y), num(x)), "degrees" => x -> rad2deg(num(x)), "radians" => x -> deg2rad(num(x)))

"Register the functions above, aggregates and REGEXP on a SQLite connection."
function register_sqlite_extras!(db)
    for (name, f) in SQLITE_SCALARS
        SQLite.register(db, nomiss(f); nargs = first(methods(f)).nargs - 1, name = "juango_" * name)
    end
    SQLite.register(db, () -> Float64(pi); nargs = 0, name = "juango_pi")
    SQLite.register(db, (p, s) -> (p === missing || s === missing) ? missing : occursin(Regex(string(p)), string(s)); nargs = 2, name = "regexp")
    # variance and standard deviation (population and sample), and bitwise and/or
    for (name, final) in (("var_pop", v -> v[1] < 1 ? missing : v[3] / v[1]), ("var_samp", v -> v[1] < 2 ? missing : v[3] / (v[1] - 1)),
                          ("stddev_pop", v -> v[1] < 1 ? missing : sqrt(v[3] / v[1])), ("stddev_samp", v -> v[1] < 2 ? missing : sqrt(v[3] / (v[1] - 1))))
        # Welford's online algorithm: (count, mean, M2)
        SQLite.register(db, (0, 0.0, 0.0), (st, x) -> x === missing ? st : (n = st[1] + 1; d = num(x) - st[2]; m = st[2] + d / n; (n, m, st[3] + d * (num(x) - m))),
                        final; nargs = 1, name = "juango_" * name)
    end
    SQLite.register(db, missing, (a, x) -> x === missing ? a : a === missing ? Int(x) : a & Int(x); nargs = 1, name = "juango_bit_and")
    SQLite.register(db, missing, (a, x) -> x === missing ? a : a === missing ? Int(x) : a | Int(x); nargs = 1, name = "juango_bit_or")
    db
end

# MD5 (RFC 1321) for SQLite's MD5(); the SHA package has no MD5
const MD5_S = UInt32[7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                     5, 9, 14, 20, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21,
                     6, 10, 15, 21, 6, 10, 15, 21]
const MD5_K = UInt32[floor(UInt64, abs(sin(i + 1)) * 2.0^32) % UInt32 for i in 0:63]
function MD5_hash(data::AbstractVector{UInt8})
    msg = Vector{UInt8}(data)
    bitlen = UInt64(length(msg)) * 8
    push!(msg, 0x80)
    while length(msg) % 64 != 56
        push!(msg, 0x00)
    end
    append!(msg, reinterpret(UInt8, [htol(bitlen)]))
    a0, b0, c0, d0 = 0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476
    for chunk in 0:(length(msg) ÷ 64 - 1)
        M = [ltoh(reinterpret(UInt32, msg[chunk*64+1:chunk*64+64])[j]) for j in 1:16]
        A, B, C, D = a0, b0, c0, d0
        for i in 0:63
            F, g = i < 16 ? ((B & C) | (~B & D), i) : i < 32 ? ((D & B) | (~D & C), (5i + 1) % 16) :
                   i < 48 ? (B ⊻ C ⊻ D, (3i + 5) % 16) : (C ⊻ (B | ~D), (7i) % 16)
            F = F + A + MD5_K[i+1] + M[g+1]
            A, D, C = D, C, B
            B = B + bitrotate(F, Int(MD5_S[i+1]))
        end
        a0 += A; b0 += B; c0 += C; d0 += D
    end
    reinterpret(UInt8, htol.([a0, b0, c0, d0]))
end
