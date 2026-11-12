# Password hashing and validation ----------------------------------------------------------------------
#
# `PASSWORD_HASHERS` lists the hashers Juango accepts; the first one hashes new passwords.
# A password stored with another listed hasher (or with weaker settings) still verifies,
# and is re-hashed with the first one the next time the user logs in. The stored formats
# are Django's, so hashes move between the two:
#
#     pbkdf2_sha256$<iterations>$<salt>$<hash>             PBKDF2Hasher (default)
#     argon2$argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>  Argon2Hasher
#     bcrypt_sha256$$2b$<rounds>$<salt+hash>                BCryptSHA256Hasher
#     bcrypt$$2b$<rounds>$<salt+hash>                       BCryptHasher
#
# Argon2 and bcrypt are implemented here in Julia (no C libraries needed).

abstract type PasswordHasher end

# --- PBKDF2-SHA256 ---------------------------------------------------------------------------------

function pbkdf2_sha256(password::AbstractVector{UInt8}, salt::AbstractVector{UInt8}, iterations::Int)
    password = Vector{UInt8}(password)
    u = hmac_sha256(password, vcat(salt, UInt8[0, 0, 0, 1]))
    t = copy(u)
    for _ in 2:iterations
        u = hmac_sha256(password, u)
        t .⊻= u
    end
    t
end

"""
    PBKDF2Hasher(; iterations = nothing)

PBKDF2 with SHA-256 (Django's default). `iterations` defaults to `PASSWORD_ITERATIONS`.
"""
Base.@kwdef struct PBKDF2Hasher <: PasswordHasher
    iterations::Union{Nothing,Int} = nothing
end
algorithm(::PBKDF2Hasher) = "pbkdf2_sha256"
iterations_of(h::PBKDF2Hasher) = something(h.iterations, settings.PASSWORD_ITERATIONS)
function encode_password(h::PBKDF2Hasher, raw::AbstractString, salt::AbstractString; iterations = iterations_of(h))
    dk = pbkdf2_sha256(codeunits(raw), codeunits(salt), iterations)
    "pbkdf2_sha256\$$iterations\$$salt\$$(base64encode(dk))"
end
function verify_password(h::PBKDF2Hasher, raw::AbstractString, encoded::AbstractString)
    parts = split(encoded, '$')
    (length(parts) == 4 && parts[1] == "pbkdf2_sha256") || return false
    iters = tryparse(Int, parts[2])
    iters === nothing && return false
    consteq(encode_password(h, raw, parts[3]; iterations = iters), encoded)
end
must_update(h::PBKDF2Hasher, encoded) = (p = split(encoded, '$'); length(p) < 2 || tryparse(Int, p[2]) != iterations_of(h))

# --- bcrypt ----------------------------------------------------------------------------------------

# Blowfish's initial P-array and S-boxes are the hexadecimal digits of π's fractional part.
const BLOWFISH_INIT = Ref{Union{Nothing,Vector{UInt32}}}(nothing)
function blowfish_init()
    BLOWFISH_INIT[] === nothing || return BLOWFISH_INIT[]
    n = 18 + 4 * 256
    words = setprecision(BigFloat, 32 * n + 64) do
        x = BigFloat(pi) - 3
        out = Vector{UInt32}(undef, n)
        for i in 1:n
            x *= 2^32
            w = floor(x)
            out[i] = UInt32(BigInt(w))
            x -= w
        end
        out
    end
    BLOWFISH_INIT[] = words
end

mutable struct Blowfish
    P::Vector{UInt32}
    S::Vector{UInt32}          # four S-boxes of 256 words, one after another
end
Blowfish() = (w = blowfish_init(); Blowfish(w[1:18], w[19:end]))

@inline function bf_f(S, x::UInt32)
    @inbounds ((S[(x >> 24) + 1] + S[256 + ((x >> 16) & 0xff) + 1]) ⊻ S[512 + ((x >> 8) & 0xff) + 1]) + S[768 + (x & 0xff) + 1]
end
@inline function bf_encipher(bf::Blowfish, l::UInt32, r::UInt32)
    P, S = bf.P, bf.S
    @inbounds begin
        l ⊻= P[1]
        for i in 2:2:16
            r ⊻= bf_f(S, l) ⊻ P[i]
            l ⊻= bf_f(S, r) ⊻ P[i+1]
        end
        r ⊻= P[18]
    end
    r, l
end

"The next big-endian word of `data`, cycling through it (Blowfish_stream2word)."
@inline function stream2word(data::Vector{UInt8}, j::Base.RefValue{Int})
    w = UInt32(0)
    n = length(data)
    @inbounds for _ in 1:4
        w = (w << 8) | data[j[] + 1]
        j[] = (j[] + 1) % n
    end
    w
end

function bf_expand!(bf::Blowfish, data::Union{Nothing,Vector{UInt8}}, key::Vector{UInt8})
    j = Ref(0)
    for i in 1:18
        bf.P[i] ⊻= stream2word(key, j)
    end
    j = Ref(0)
    l = r = UInt32(0)
    for i in 1:2:18
        if data !== nothing
            l ⊻= stream2word(data, j); r ⊻= stream2word(data, j)
        end
        l, r = bf_encipher(bf, l, r)
        bf.P[i], bf.P[i+1] = l, r
    end
    for i in 1:2:1024
        if data !== nothing
            l ⊻= stream2word(data, j); r ⊻= stream2word(data, j)
        end
        l, r = bf_encipher(bf, l, r)
        bf.S[i], bf.S[i+1] = l, r
    end
    bf
end

const BCRYPT_B64 = "./ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
function bcrypt_b64encode(data::AbstractVector{UInt8})
    io = IOBuffer()
    i, n = 1, length(data)
    while i <= n
        c1 = data[i]; i += 1
        write(io, BCRYPT_B64[(c1 >> 2) + 1])
        c1 = (c1 & 0x03) << 4
        if i > n
            write(io, BCRYPT_B64[c1 + 1]); break
        end
        c2 = data[i]; i += 1
        write(io, BCRYPT_B64[(c1 | (c2 >> 4)) + 1])
        c1 = (c2 & 0x0f) << 2
        if i > n
            write(io, BCRYPT_B64[c1 + 1]); break
        end
        c2 = data[i]; i += 1
        write(io, BCRYPT_B64[(c1 | (c2 >> 6)) + 1])
        write(io, BCRYPT_B64[(c2 & 0x3f) + 1])
    end
    String(take!(io))
end
function bcrypt_b64decode(s::AbstractString, nbytes::Int)
    vals = [something(findfirst(==(ch), BCRYPT_B64), 1) - 1 for ch in s]
    out = UInt8[]
    i = 1
    while length(out) < nbytes && i + 1 <= length(vals)
        c1, c2 = vals[i], vals[i+1]
        push!(out, UInt8(((c1 << 2) | ((c2 & 0x30) >> 4)) & 0xff))
        (length(out) >= nbytes || i + 2 > length(vals)) && break
        c3 = vals[i+2]
        push!(out, UInt8((((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2)) & 0xff))
        (length(out) >= nbytes || i + 3 > length(vals)) && break
        c4 = vals[i+3]
        push!(out, UInt8((((c3 & 0x03) << 6) | c4) & 0xff))
        i += 4
    end
    out
end

"""
    bcrypt(password, salt22, cost) -> "\$2b\$<cost>\$<salt><hash>"

The bcrypt hash of `password` (at most 72 bytes count) with a 22-character bcrypt salt.
"""
function bcrypt(password::AbstractString, salt::AbstractString, cost::Integer)
    4 <= cost <= 31 || throw(ArgumentError("bcrypt cost must be between 4 and 31"))
    length(salt) >= 22 || throw(ArgumentError("bcrypt salt must be 22 characters"))
    saltb = bcrypt_b64decode(salt[1:22], 16)
    key = vcat(Vector{UInt8}(codeunits(password)), UInt8[0])
    length(key) > 72 && (key = key[1:72])
    bf = bf_expand!(Blowfish(), saltb, key)
    for _ in 1:(1 << cost)
        bf_expand!(bf, nothing, key)
        bf_expand!(bf, nothing, saltb)
    end
    ctext = [stream2word(Vector{UInt8}(codeunits("OrpheanBeholderScryDoubt")), Ref(4 * (i - 1))) for i in 1:6]
    for _ in 1:64, k in 1:2:6
        ctext[k], ctext[k+1] = bf_encipher(bf, ctext[k], ctext[k+1])
    end
    out = UInt8[]
    for w in ctext
        push!(out, UInt8(w >> 24), UInt8((w >> 16) & 0xff), UInt8((w >> 8) & 0xff), UInt8(w & 0xff))
    end
    "\$2b\$" * lpad(cost, 2, '0') * "\$" * bcrypt_b64encode(saltb) * bcrypt_b64encode(out[1:23])
end
bcrypt_salt() = bcrypt_b64encode(rand(RandomDevice(), UInt8, 16))

"""
    BCryptSHA256Hasher(; rounds = 12)

bcrypt of the password's SHA-256 (so passwords longer than 72 bytes still count in full).
"""
Base.@kwdef struct BCryptSHA256Hasher <: PasswordHasher
    rounds::Int = 12
end
"""
    BCryptHasher(; rounds = 12)

Plain bcrypt: only the first 72 bytes of a password count. Prefer `BCryptSHA256Hasher`.
"""
Base.@kwdef struct BCryptHasher <: PasswordHasher
    rounds::Int = 12
end
algorithm(::BCryptSHA256Hasher) = "bcrypt_sha256"
algorithm(::BCryptHasher) = "bcrypt"
bcrypt_input(::BCryptSHA256Hasher, raw) = bytes2hex(sha256(raw))
bcrypt_input(::BCryptHasher, raw) = raw
encode_password(h::Union{BCryptSHA256Hasher,BCryptHasher}, raw::AbstractString, salt::AbstractString) =
    algorithm(h) * "\$" * bcrypt(bcrypt_input(h, raw), salt, h.rounds)
function verify_password(h::Union{BCryptSHA256Hasher,BCryptHasher}, raw::AbstractString, encoded::AbstractString)
    pre = algorithm(h) * "\$"
    startswith(encoded, pre) || return false
    b = encoded[length(pre)+1:end]
    m = match(r"^\$2[abxy]\$(\d\d)\$([./A-Za-z0-9]{53})$", b)
    m === nothing && return false
    consteq(bcrypt(bcrypt_input(h, raw), m[2][1:22], parse(Int, m[1]))[5:end], b[5:end])
end
must_update(h::Union{BCryptSHA256Hasher,BCryptHasher}, encoded) =
    (m = match(r"\$2[abxy]\$(\d\d)\$", encoded); m === nothing || parse(Int, m[1]) != h.rounds)
salt_for(::Union{BCryptSHA256Hasher,BCryptHasher}) = bcrypt_salt()

# --- BLAKE2b (RFC 7693) and Argon2id (RFC 9106) ----------------------------------------------------

const BLAKE2B_IV = UInt64[0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                          0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
const BLAKE2B_SIGMA = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]]

@inline function blake2b_g!(v, a, b, c, d, x, y)
    @inbounds begin
        v[a] = v[a] + v[b] + x; v[d] = bitrotate(v[d] ⊻ v[a], -32)
        v[c] = v[c] + v[d];     v[b] = bitrotate(v[b] ⊻ v[c], -24)
        v[a] = v[a] + v[b] + y; v[d] = bitrotate(v[d] ⊻ v[a], -16)
        v[c] = v[c] + v[d];     v[b] = bitrotate(v[b] ⊻ v[c], -63)
    end
end

function blake2b_compress!(h::Vector{UInt64}, block::AbstractVector{UInt8}, t::UInt128, last::Bool)
    m = reinterpret(UInt64, Vector{UInt8}(block))      # little-endian words
    v = vcat(h, BLAKE2B_IV)
    v[13] ⊻= UInt64(t & typemax(UInt64)); v[14] ⊻= UInt64(t >> 64)
    last && (v[15] = ~v[15])
    for r in 0:11
        s = BLAKE2B_SIGMA[r % 10 + 1]
        blake2b_g!(v, 1, 5, 9, 13, m[s[1]+1], m[s[2]+1]);  blake2b_g!(v, 2, 6, 10, 14, m[s[3]+1], m[s[4]+1])
        blake2b_g!(v, 3, 7, 11, 15, m[s[5]+1], m[s[6]+1]); blake2b_g!(v, 4, 8, 12, 16, m[s[7]+1], m[s[8]+1])
        blake2b_g!(v, 1, 6, 11, 16, m[s[9]+1], m[s[10]+1]); blake2b_g!(v, 2, 7, 12, 13, m[s[11]+1], m[s[12]+1])
        blake2b_g!(v, 3, 8, 9, 14, m[s[13]+1], m[s[14]+1]); blake2b_g!(v, 4, 5, 10, 15, m[s[15]+1], m[s[16]+1])
    end
    for i in 1:8
        h[i] ⊻= v[i] ⊻ v[i+8]
    end
    h
end

"BLAKE2b of `data` with an `outlen`-byte digest (1 to 64)."
function blake2b(data::AbstractVector{UInt8}, outlen::Int = 64)
    h = copy(BLAKE2B_IV)
    h[1] ⊻= 0x01010000 ⊻ UInt64(outlen)
    n = length(data)
    t = UInt128(0)
    i = 1
    while n - i + 1 > 128
        t += 128
        blake2b_compress!(h, view(data, i:i+127), t, false)
        i += 128
    end
    rest = data[i:end]
    t += length(rest)
    blake2b_compress!(h, vcat(rest, zeros(UInt8, 128 - length(rest))), t, true)
    reinterpret(UInt8, h)[1:outlen]
end

le32(x) = reinterpret(UInt8, [UInt32(x)])

"Argon2's variable-length hash H'."
function blake2b_long(data::Vector{UInt8}, outlen::Int)
    outlen <= 64 && return blake2b(vcat(le32(outlen), data), outlen)
    r = cld(outlen, 32) - 2
    out = UInt8[]
    v = blake2b(vcat(le32(outlen), data), 64)
    append!(out, v[1:32])
    for _ in 2:r
        v = blake2b(v, 64)
        append!(out, v[1:32])
    end
    append!(out, blake2b(v, outlen - 32 * r))
    out
end

@inline fblamka(x::UInt64, y::UInt64) = x + y + 2 * (x & 0xffffffff) * (y & 0xffffffff)
@inline function gb!(v, a, b, c, d)
    @inbounds begin
        v[a] = fblamka(v[a], v[b]); v[d] = bitrotate(v[d] ⊻ v[a], -32)
        v[c] = fblamka(v[c], v[d]); v[b] = bitrotate(v[b] ⊻ v[c], -24)
        v[a] = fblamka(v[a], v[b]); v[d] = bitrotate(v[d] ⊻ v[a], -16)
        v[c] = fblamka(v[c], v[d]); v[b] = bitrotate(v[b] ⊻ v[c], -63)
    end
end
@inline function blamka_round!(v, i0, i1, i2, i3, i4, i5, i6, i7, i8, i9, i10, i11, i12, i13, i14, i15)
    gb!(v, i0, i4, i8, i12); gb!(v, i1, i5, i9, i13); gb!(v, i2, i6, i10, i14); gb!(v, i3, i7, i11, i15)
    gb!(v, i0, i5, i10, i15); gb!(v, i1, i6, i11, i12); gb!(v, i2, i7, i8, i13); gb!(v, i3, i4, i9, i14)
end

"Argon2's compression G: `out = G(x, y)`, or `out ⊻= G(x, y)` with `xor_into`. Blocks are 128 words."
function argon2_g!(out::AbstractVector{UInt64}, x::AbstractVector{UInt64}, y::AbstractVector{UInt64},
                   r::Vector{UInt64}, z::Vector{UInt64}, xor_into::Bool)
    @inbounds for i in 1:128
        r[i] = x[i] ⊻ y[i]
    end
    copyto!(z, r)
    @inbounds for i in 0:7            # rows: 16 consecutive words
        b = 16i
        blamka_round!(z, b+1, b+2, b+3, b+4, b+5, b+6, b+7, b+8, b+9, b+10, b+11, b+12, b+13, b+14, b+15, b+16)
    end
    @inbounds for i in 0:7            # columns: word pairs 2i, 2i+1 of every row
        b = 2i
        blamka_round!(z, b+1, b+2, b+17, b+18, b+33, b+34, b+49, b+50, b+65, b+66, b+81, b+82, b+97, b+98, b+113, b+114)
    end
    if xor_into
        @inbounds for i in 1:128
            out[i] ⊻= z[i] ⊻ r[i]
        end
    else
        @inbounds for i in 1:128
            out[i] = z[i] ⊻ r[i]
        end
    end
    out
end

"""
    argon2id(password, salt; t = 2, m = 102400, p = 8, len = 32, secret = UInt8[], ad = UInt8[]) -> bytes

Argon2id (version 1.3) with `t` passes over `m` KiB of memory in `p` lanes.
"""
function argon2id(password::AbstractVector{UInt8}, salt::AbstractVector{UInt8}; t::Int = 2, m::Int = 102400, p::Int = 8,
                  len::Int = 32, secret::AbstractVector{UInt8} = UInt8[], ad::AbstractVector{UInt8} = UInt8[])
    (t >= 1 && p >= 1 && m >= 8p && len >= 4) || throw(ArgumentError("invalid Argon2 parameters"))
    y = 2                                                # Argon2id
    h0 = blake2b(vcat(le32(p), le32(len), le32(m), le32(t), le32(0x13), le32(y),
                      le32(length(password)), password, le32(length(salt)), salt,
                      le32(length(secret)), secret, le32(length(ad)), ad), 64)
    mp = 4p * (m ÷ (4p))
    q = mp ÷ p                                           # columns per lane
    seg = q ÷ 4
    B = Matrix{UInt64}(undef, 128, mp)                   # block (lane l, column c) is column l*q + c + 1
    col(l, c) = l * q + c + 1
    for l in 0:p-1
        B[:, col(l, 0)] = reinterpret(UInt64, blake2b_long(vcat(h0, le32(0), le32(l)), 1024))
        B[:, col(l, 1)] = reinterpret(UInt64, blake2b_long(vcat(h0, le32(1), le32(l)), 1024))
    end
    r, z = zeros(UInt64, 128), zeros(UInt64, 128)
    zero_block = zeros(UInt64, 128)
    input, addresses, tmp = zeros(UInt64, 128), zeros(UInt64, 128), zeros(UInt64, 128)
    for pass in 0:t-1, slice in 0:3, l in 0:p-1
        data_independent = pass == 0 && slice < 2
        if data_independent
            fill!(input, 0)
            input[1], input[2], input[3], input[4], input[5], input[6] = pass, l, slice, mp, t, y
        end
        start = pass == 0 && slice == 0 ? 2 : 0
        if data_independent && start != 0     # the first address block
            input[7] += 1
            argon2_g!(tmp, zero_block, input, r, z, false); argon2_g!(addresses, zero_block, tmp, r, z, false)
        end
        for idx in start:seg-1
            c = slice * seg + idx
            prev = c == 0 ? q - 1 : c - 1
            if data_independent
                if idx % 128 == 0
                    input[7] += 1
                    argon2_g!(tmp, zero_block, input, r, z, false); argon2_g!(addresses, zero_block, tmp, r, z, false)
                end
                pr = addresses[idx % 128 + 1]
            else
                pr = B[1, col(l, prev)]
            end
            j1, j2 = pr & 0xffffffff, pr >> 32
            rl = pass == 0 && slice == 0 ? l : Int(j2 % p)
            same = rl == l
            area = if pass == 0
                same ? slice * seg + idx - 1 : slice * seg - (idx == 0 ? 1 : 0)
            else
                same ? q - seg + idx - 1 : q - seg - (idx == 0 ? 1 : 0)
            end
            rel = UInt64(area) - 1 - ((UInt64(area) * ((j1 * j1) >> 32)) >> 32)
            startpos = pass == 0 ? 0 : (slice == 3 ? 0 : (slice + 1) * seg)
            refc = Int((UInt64(startpos) + rel) % UInt64(q))
            argon2_g!(view(B, :, col(l, c)), view(B, :, col(l, prev)), view(B, :, col(rl, refc)), r, z, pass > 0)
        end
    end
    final = copy(B[:, col(0, q - 1)])
    for l in 1:p-1
        final .⊻= B[:, col(l, q - 1)]
    end
    blake2b_long(Vector{UInt8}(reinterpret(UInt8, final)), len)
end

b64_nopad(x) = rstrip(base64encode(x), '=')
b64_nopad_decode(s) = base64decode(s * repeat("=", mod(-length(s), 4)))

"""
    Argon2Hasher(; time_cost = 2, memory_cost = 102400, parallelism = 8)

Argon2id, the winner of the Password Hashing Competition (memory in KiB, as in Django).
"""
Base.@kwdef struct Argon2Hasher <: PasswordHasher
    time_cost::Int = 2
    memory_cost::Int = 102400
    parallelism::Int = 8
end
algorithm(::Argon2Hasher) = "argon2"
function encode_password(h::Argon2Hasher, raw::AbstractString, salt::AbstractString)
    d = argon2id(codeunits(raw), codeunits(salt); t = h.time_cost, m = h.memory_cost, p = h.parallelism)
    "argon2\$argon2id\$v=19\$m=$(h.memory_cost),t=$(h.time_cost),p=$(h.parallelism)\$$(b64_nopad(codeunits(salt)))\$$(b64_nopad(d))"
end
function argon2_params(encoded)
    m = match(r"^argon2\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$([A-Za-z0-9+/]+)\$([A-Za-z0-9+/]+)$", encoded)
    m === nothing ? nothing : (m = parse(Int, m[1]), t = parse(Int, m[2]), p = parse(Int, m[3]),
                               salt = b64_nopad_decode(m[4]), hash = b64_nopad_decode(m[5]))
end
function verify_password(h::Argon2Hasher, raw::AbstractString, encoded::AbstractString)
    a = argon2_params(encoded)
    a === nothing && return false
    d = argon2id(codeunits(raw), a.salt; t = a.t, m = a.m, p = a.p, len = length(a.hash))
    consteq(bytes2hex(d), bytes2hex(a.hash))
end
must_update(h::Argon2Hasher, encoded) =
    (a = argon2_params(encoded); a === nothing || (a.m, a.t, a.p) != (h.memory_cost, h.time_cost, h.parallelism))

salt_for(::PasswordHasher) = random_string(22)

# --- choosing a hasher -------------------------------------------------------------------------------

password_hashers() = collect(get(settings, :PASSWORD_HASHERS, Any[PBKDF2Hasher()]))
"The hasher that made an encoded password (among `PASSWORD_HASHERS`), or `nothing`."
function identify_hasher(encoded::AbstractString)
    alg = first(split(encoded, '$'; limit = 2))
    i = findfirst(h -> algorithm(h) == alg, password_hashers())
    i === nothing ? nothing : password_hashers()[i]
end

"""
    make_password(raw; hasher = first(PASSWORD_HASHERS)) -> String

Hash a password in Django's format (by default `pbkdf2_sha256\$iterations\$salt\$hash`).
"""
function make_password(raw::AbstractString; hasher = nothing, iterations = nothing, salt = nothing)
    h = something(hasher, iterations === nothing ? nothing : PBKDF2Hasher(iterations = iterations), first(password_hashers()))
    encode_password(h, raw, something(salt, salt_for(h)))
end

"""
    check_password(raw, encoded; setter = nothing) -> Bool

Whether `raw` matches. When it does but was hashed by an older hasher or with other
settings than the first of `PASSWORD_HASHERS`, `setter(raw)` is called so the caller can
store a new hash.
"""
function check_password(raw::AbstractString, encoded::AbstractString; setter = nothing)
    h = identify_hasher(encoded)
    h === nothing && return false
    ok = verify_password(h, raw, encoded)
    if ok && setter !== nothing
        preferred = first(password_hashers())
        (algorithm(h) != algorithm(preferred) || must_update(preferred, encoded)) && setter(raw)
    end
    ok
end

# --- validators ------------------------------------------------------------------------------------

"""
Password validators, listed in `AUTH_PASSWORD_VALIDATORS`. Each is a value whose type has a
method `password_error(validator, password, user)` returning a message or `nothing`.
"""
password_error(v, password, user) = nothing

"At least `min_length` characters (default `PASSWORD_MIN_LENGTH`)."
Base.@kwdef struct MinimumLengthValidator
    min_length::Union{Nothing,Int} = nothing
end
function password_error(v::MinimumLengthValidator, p, user)
    n = something(v.min_length, settings.PASSWORD_MIN_LENGTH)
    length(p) < n ? ngettext("This password is too short. It must contain at least %(min_length)d character.",
                             "This password is too short. It must contain at least %(min_length)d characters.", n) |>
                    s -> interpolate(s, Dict("min_length" => n)) : nothing
end

"Not only digits."
struct NumericPasswordValidator end
password_error(::NumericPasswordValidator, p, user) = all(isdigit, p) ? gettext("This password is entirely numeric.") : nothing

"""
Not one of a list of common passwords: Django's list of 20,000 (shipped gzipped), or
`CommonPasswordValidator(path = "file")` with one password per line (`.gz` files too).
"""
Base.@kwdef struct CommonPasswordValidator
    path::Union{Nothing,String} = nothing
end
const COMMON_PASSWORDS = Dict{Any,Set{String}}()
const COMMON_PASSWORDS_LOCK = ReentrantLock()
function common_passwords(path)
    lock(COMMON_PASSWORDS_LOCK) do
        get!(COMMON_PASSWORDS, path) do
            file = something(path, joinpath(ASSETS_DIR, "data", "common-passwords.txt.gz"))
            open(file) do io
                src = endswith(file, ".gz") ? CodecZlib.GzipDecompressorStream(io) : io
                Set(lowercase(strip(l)) for l in eachline(src) if !isempty(strip(l)))
            end
        end
    end
end
password_error(v::CommonPasswordValidator, p, user) =
    lowercase(strip(p)) in common_passwords(v.path) ? gettext("This password is too common.") : nothing

"""
Not too similar to the user's attributes (`username`, `first_name`, `last_name`, `email` and
its parts): Ratcliff-Obershelp similarity at least `max_similarity` fails.
"""
Base.@kwdef struct UserAttributeSimilarityValidator
    user_attributes::Vector{Symbol} = [:username, :first_name, :last_name, :email]
    max_similarity::Float64 = 0.7
end

"Ratcliff-Obershelp similarity of two strings, as Python's difflib.SequenceMatcher.ratio."
function similarity(a::AbstractString, b::AbstractString)
    x, y = collect(a), collect(b)
    total = length(x) + length(y)
    total == 0 && return 1.0
    matches(lo1, hi1, lo2, hi2) = begin
        (lo1 > hi1 || lo2 > hi2) && return 0
        best, bi, bj = 0, 0, 0
        prev = zeros(Int, hi2 - lo2 + 2)
        for i in lo1:hi1
            cur = zeros(Int, hi2 - lo2 + 2)
            for j in lo2:hi2
                if x[i] == y[j]
                    cur[j - lo2 + 2] = prev[j - lo2 + 1] + 1
                    if cur[j - lo2 + 2] > best
                        best, bi, bj = cur[j - lo2 + 2], i - cur[j - lo2 + 2] + 1, j - cur[j - lo2 + 2] + 1
                    end
                end
            end
            prev = cur
        end
        best == 0 && return 0
        best + matches(lo1, bi - 1, lo2, bj - 1) + matches(bi + best, hi1, bj + best, hi2)
    end
    2 * matches(1, length(x), 1, length(y)) / total
end

function password_error(v::UserAttributeSimilarityValidator, p, user)
    user === nothing && return nothing
    pl = lowercase(p)
    for a in v.user_attributes
        val = try getproperty(user, a) catch; nothing end
        (val isa AbstractString && !isempty(val)) || continue
        parts = vcat([lowercase(val)], split(lowercase(val), r"\W+"; keepempty = false))
        for part in parts
            if similarity(pl, part) >= v.max_similarity
                f = user isa Model ? findfield(modelmeta(typeof(user)), a) : nothing
                return interpolate(gettext("The password is too similar to the %(verbose_name)s."),
                                   Dict("verbose_name" => f === nothing ? string(a) : lowercase(label(f))))
            end
        end
    end
    nothing
end

default_password_validators() = Any[MinimumLengthValidator(), NumericPasswordValidator()]

"""
    validate_password(password; user = nothing) -> Vector{String}

The messages of the `AUTH_PASSWORD_VALIDATORS` the password fails (empty when it passes).
"""
function validate_password(password::AbstractString; user = nothing)
    msgs = String[]
    for v in get(settings, :AUTH_PASSWORD_VALIDATORS, default_password_validators())
        e = password_error(v, password, user)
        e === nothing || push!(msgs, string(e))
    end
    msgs
end
