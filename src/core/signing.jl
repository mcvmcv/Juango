# Signing ----------------------------------------------------------------------------------------------
#
#     s = signing_dumps(Dict("user" => 3))            # tamper-proof, URL-safe text
#     signing_loads(s; max_age = 3600)                 # the value, or throws BadSignature / SignatureExpired

struct BadSignature <: Exception
    msg::String
end
Base.showerror(io::IO, e::BadSignature) = print(io, "BadSignature: ", e.msg)
struct SignatureExpired <: Exception
    msg::String
end
Base.showerror(io::IO, e::SignatureExpired) = print(io, "SignatureExpired: ", e.msg)

b64url(x) = replace(base64encode(x), "+" => "-", "/" => "_", "=" => "")
function b64url_decode(s::AbstractString)
    t = replace(s, "-" => "+", "_" => "/")
    t *= repeat("=", mod(-length(t), 4))
    base64decode(t)
end
signature(value, salt; key = settings.SECRET_KEY) = b64url(hmac_sha256(vcat(Vector{UInt8}(codeunits(salt * "signer")), signing_key_bytes(key)),
                                                                        Vector{UInt8}(codeunits(value))))
"""
The keys a signature may have been made with: `SECRET_KEY`, then `SECRET_KEY_FALLBACKS` (Django's:
list the old key there when rotating it, so what it signed stays valid until it's removed).
"""
verification_keys() = vcat([settings.SECRET_KEY], collect(get(settings, :SECRET_KEY_FALLBACKS, String[])))

"Append a signature: `sign_value(\"hello\") == \"hello:<signature>\"` (keyed by SECRET_KEY and `salt`)."
sign_value(value::AbstractString; salt = "juango.signing") = value * ":" * signature(value, salt)
"The value of a signed string, or throw `BadSignature`."
function unsign_value(signed::AbstractString; salt = "juango.signing")
    i = findlast(':', signed)
    i === nothing && throw(BadSignature("no signature"))
    v, sig = signed[1:prevind(signed, i)], signed[nextind(signed, i):end]
    any(k -> consteq(sig, signature(v, salt; key = k)), verification_keys()) || throw(BadSignature("signature does not match"))
    v
end

# Signer and TimestampSigner, as Django's django.core.signing ------------------------------------------

"A `Signer` algorithm SHA.jl doesn't have (Django's InvalidAlgorithm)."
struct InvalidAlgorithm <: Exception
    msg::String
end
Base.showerror(io::IO, e::InvalidAlgorithm) = print(io, "InvalidAlgorithm: ", e.msg)

const SIGNER_HMACS = Dict{String,Function}("sha1" => SHA.hmac_sha1, "sha224" => SHA.hmac_sha224, "sha256" => SHA.hmac_sha256,
                                           "sha384" => SHA.hmac_sha384, "sha512" => SHA.hmac_sha512)
signing_key_bytes(k) = k isa AbstractVector{UInt8} ? Vector{UInt8}(k) : Vector{UInt8}(codeunits(string(k)))

# django.utils.crypto: salted_hmac, pbkdf2, constant_time_compare -------------------------------------------

const CRYPTO_HASHES = Dict{String,Function}("sha1" => SHA.sha1, "sha224" => SHA.sha224, "sha256" => SHA.sha256,
                                            "sha384" => SHA.sha384, "sha512" => SHA.sha512)
function crypto_hash(algorithm::AbstractString)
    haskey(CRYPTO_HASHES, algorithm) || throw(InvalidAlgorithm("'$algorithm' is not an algorithm accepted by the hashlib module."))
    CRYPTO_HASHES[algorithm], SIGNER_HMACS[algorithm]
end

"""
    salted_hmac(key_salt, value; secret = SECRET_KEY, algorithm = "sha1") -> Vector{UInt8}

Django's `salted_hmac`: the HMAC of `value` under a key derived from `key_salt` and `secret` (the hash of the two), so
different uses of the one secret give unrelated signatures. `bytes2hex` of it is Django's `hexdigest()`. An algorithm
SHA.jl hasn't (blake2b, ...) is an `InvalidAlgorithm`.
"""
function salted_hmac(key_salt, value; secret = nothing, algorithm::AbstractString = "sha1")
    h, mac = crypto_hash(algorithm)
    key = h(vcat(signing_key_bytes(key_salt), signing_key_bytes(something(secret, settings.SECRET_KEY))))
    mac(Vector{UInt8}(key), signing_key_bytes(value))
end

"""
    pbkdf2(password, salt, iterations; dklen = 0, digest = "sha256") -> Vector{UInt8}

Django's `pbkdf2` (PBKDF2-HMAC, RFC 8018): `dklen` bytes (0: the digest's length) derived from `password` and `salt`.
"""
function pbkdf2(password, salt, iterations::Integer; dklen::Integer = 0, digest::AbstractString = "sha256")
    _, mac = crypto_hash(digest)
    pw, sl = signing_key_bytes(password), signing_key_bytes(salt)
    hlen = length(mac(UInt8[], UInt8[]))
    n = dklen == 0 ? hlen : Int(dklen)
    out = UInt8[]
    for block in 1:cld(n, hlen)
        u = mac(pw, vcat(sl, reverse(reinterpret(UInt8, [UInt32(block)]))))
        t = copy(u)
        for _ in 2:iterations
            u = mac(pw, u)
            t .⊻= u
        end
        append!(out, t)
    end
    out[1:n]
end

"Django's `constant_time_compare`: whether two strings (or byte strings) are equal, in time that doesn't depend on where they differ."
constant_time_compare(a, b) = consteq(signing_key_bytes(a), signing_key_bytes(b))

"""
    Signer(; key = SECRET_KEY, sep = ":", salt = "juango.signing.Signer", algorithm = "sha256", fallback_keys = SECRET_KEY_FALLBACKS)

Signs text as Django's `Signer`: `sign(s, "hello") == "hello:<signature>"`, and `unsign(s, signed)`
gives the text back or throws `BadSignature`. `sign_object(s, obj; compress = false)` and
`unsign_object(s, signed)` do the same for a JSON value. A different `salt` gives different
signatures from the same key; `sep` can't be empty or made only of `A-z0-9-_=` (it would clash with
the signature). `algorithm` is one of sha1, sha224, sha256, sha384, sha512. A signature made with one
of `fallback_keys` still unsigns (for rotating the key).
"""
struct Signer
    key::Vector{UInt8}
    sep::String
    salt::String
    algorithm::String
    fallback_keys::Vector{Vector{UInt8}}
end
const SIGNER_SEP_UNSAFE = r"^[A-z0-9\-_=]*$"
function Signer(; key = nothing, sep::AbstractString = ":", salt = nothing, algorithm::AbstractString = "sha256", fallback_keys = nothing)
    occursin(SIGNER_SEP_UNSAFE, sep) &&
        throw(ArgumentError("Unsafe Signer separator: $(repr(sep)) (cannot be empty or consist of only A-z0-9-_=)"))
    Signer(signing_key_bytes(something(key, settings.SECRET_KEY)), String(sep), string(something(salt, "juango.signing.Signer")),
           String(algorithm), [signing_key_bytes(k) for k in something(fallback_keys, get(settings, :SECRET_KEY_FALLBACKS, String[]))])
end

"""
    TimestampSigner(; key, sep, salt = "juango.signing.TimestampSigner", algorithm, fallback_keys)

A `Signer` that also signs the time (base 62), as Django's: `unsign(ts, signed; max_age = 60)` (seconds
or a `Period`) throws `SignatureExpired` for a signature older than that.
"""
struct TimestampSigner
    signer::Signer
end
TimestampSigner(; salt = nothing, kw...) = TimestampSigner(Signer(; salt = something(salt, "juango.signing.TimestampSigner"), kw...))
Base.getproperty(t::TimestampSigner, s::Symbol) = s === :signer ? getfield(t, :signer) : getproperty(getfield(t, :signer), s)

"The signature of `value` (Django's `signer.signature`), with `key` instead of the signer's own."
function signature(s::Signer, value; key = s.key)
    h = get(SIGNER_HMACS, s.algorithm, nothing)
    h === nothing && throw(InvalidAlgorithm("$(repr(s.algorithm)) is not an algorithm accepted by the hashlib module."))
    b64url(h(vcat(Vector{UInt8}(codeunits(s.salt * "signer")), signing_key_bytes(key)), Vector{UInt8}(codeunits(string(value)))))
end
"`sign(signer, value)`: `value` (as text), the separator and its signature."
Base.sign(s::Signer, value) = string(value) * s.sep * signature(s, value)
"""
    unsign(signer, signed) -> String
    unsign(timestamp_signer, signed; max_age = nothing) -> String

The value of a signed string, or throw `BadSignature` (`SignatureExpired` when older than `max_age`).
"""
function unsign(s::Signer, signed::AbstractString)
    occursin(s.sep, signed) || throw(BadSignature("No \"$(s.sep)\" found in value"))
    r = findlast(s.sep, signed)
    value, sig = signed[1:prevind(signed, first(r))], signed[nextind(signed, last(r)):end]
    any(k -> consteq(sig, signature(s, value; key = k)), [[s.key]; s.fallback_keys]) && return value
    throw(BadSignature("Signature \"$sig\" does not match"))
end

"""
    sign_object(signer, obj; compress = false) -> String

A JSON value, base64-encoded (zlib-compressed first if `compress` and that's shorter, marked by a
leading "."), signed: Django's `sign_object`. `unsign_object` reverses it.
"""
function sign_object(s::Union{Signer,TimestampSigner}, obj; compress::Bool = false)
    data = Vector{UInt8}(codeunits(JSON.json(obj)))
    compressed = false
    if compress
        z = transcode(CodecZlib.ZlibCompressor, data)
        length(z) < length(data) - 1 && ((data, compressed) = (z, true))
    end
    sign(s, (compressed ? "." : "") * b64url(data))
end
"The value `sign_object` signed, or throw `BadSignature`; a `TimestampSigner` takes `max_age` too."
function unsign_object(s::Union{Signer,TimestampSigner}, signed::AbstractString; kw...)
    b = unsign(s, signed; kw...)
    decode_signed_object(b)
end
function decode_signed_object(b::AbstractString)
    data = try
        startswith(b, ".") ? transcode(CodecZlib.ZlibDecompressor, b64url_decode(b[2:end])) : b64url_decode(b)
    catch
        throw(BadSignature("the signed value isn't base64 or zlib"))
    end
    plainjson(JSON.parse(String(data)))
end

const BASE62_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
"An integer in base 62, as Django's `b62_encode` (the timestamps of `TimestampSigner`)."
function b62_encode(n::Integer)
    n == 0 && return "0"
    sign_ = n < 0 ? "-" : ""
    n = abs(n); out = Char[]
    while n > 0
        n, r = divrem(n, 62)
        push!(out, BASE62_ALPHABET[r+1])
    end
    sign_ * String(reverse(out))
end
"The integer of a base 62 string (`b62_encode`'s)."
function b62_decode(s::AbstractString)
    s == "0" && return 0
    neg = startswith(s, "-")
    n = 0
    for c in (neg ? s[2:end] : s)
        i = findfirst(==(c), BASE62_ALPHABET)
        i === nothing && throw(ArgumentError("not a base 62 digit: $(repr(c))"))
        n = n * 62 + (i - 1)
    end
    neg ? -n : n
end
"The clock signatures are timed by: `time()`, replaceable in tests."
const SIGNING_CLOCK = Ref{Any}(time)
signing_now() = SIGNING_CLOCK[]()

Base.sign(t::TimestampSigner, value) = (s = t.signer; sign(s, string(value) * s.sep * b62_encode(floor(Int, signing_now()))))
max_age_seconds(a) = a isa Dates.Period ? Dates.value(convert(Dates.Millisecond, a)) / 1000 :
                     a isa Dates.CompoundPeriod ? sum(max_age_seconds, a.periods; init = 0.0) : float(a)
function unsign(t::TimestampSigner, signed::AbstractString; max_age = nothing)
    s = t.signer
    result = unsign(s, signed)
    r = findlast(s.sep, result)
    r === nothing && throw(BadSignature("No timestamp in the value"))
    value, ts = result[1:prevind(result, first(r))], result[nextind(result, last(r)):end]
    stamp = try b62_decode(ts) catch; throw(BadSignature("Bad timestamp")) end
    if max_age !== nothing
        age, limit = signing_now() - stamp, max_age_seconds(max_age)
        age > limit && throw(SignatureExpired("Signature age $age > $limit seconds"))
    end
    value
end

"""
    signing_dumps(value; salt = "juango.signing", key = SECRET_KEY, compress = false) -> String

A URL-safe, signed and timestamped encoding of a JSON-serialisable value (Django's `signing.dumps`).
With `compress = true` it's zlib-compressed first when that makes it shorter.
"""
function signing_dumps(value; salt = "juango.signing", key = nothing, compress::Bool = false)
    data = Vector{UInt8}(codeunits(JSON.json(value)))
    pre = ""
    if compress
        z = transcode(CodecZlib.ZlibCompressor, data)
        length(z) < length(data) - 1 && ((data, pre) = (z, "."))
    end
    v = pre * b64url(data) * ":" * string(floor(Int, signing_now()); base = 36)
    v * ":" * signature(v, salt; key = something(key, settings.SECRET_KEY))
end

"""
    signing_loads(s; max_age = nothing, salt = "juango.signing", key = SECRET_KEY, fallback_keys = SECRET_KEY_FALLBACKS)

Decode `signing_dumps` output. Throws `BadSignature` if it was tampered with and
`SignatureExpired` if older than `max_age` (seconds or a `Period`).
"""
function signing_loads(s::AbstractString; max_age = nothing, salt = "juango.signing", key = nothing, fallback_keys = nothing)
    keys_ = key === nothing && fallback_keys === nothing ? verification_keys() :
            [something(key, settings.SECRET_KEY); collect(something(fallback_keys, String[]))]
    i = findlast(':', s)
    i === nothing && throw(BadSignature("no signature"))
    v, sig = s[1:prevind(s, i)], s[nextind(s, i):end]
    any(k -> consteq(sig, signature(v, salt; key = k)), keys_) || throw(BadSignature("signature does not match"))
    i = findlast(':', v)
    i === nothing && throw(BadSignature("no timestamp"))
    payload = v[1:i-1]
    ts = tryparse(Int, v[i+1:end]; base = 36)
    ts === nothing && throw(BadSignature("bad timestamp"))
    if max_age !== nothing
        age = signing_now() - ts
        age > max_age_seconds(max_age) && throw(SignatureExpired("signature is $(round(Int, age)) seconds old"))
    end
    decode_signed_object(payload)
end
