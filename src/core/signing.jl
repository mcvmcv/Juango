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
signature(value, salt) = b64url(hmac_sha256(Vector{UInt8}(codeunits(salt * "signer" * string(settings.SECRET_KEY))),
                                            Vector{UInt8}(codeunits(value))))

"Append a signature: `sign_value(\"hello\") == \"hello:<signature>\"` (keyed by SECRET_KEY and `salt`)."
sign_value(value::AbstractString; salt = "juango.signing") = value * ":" * signature(value, salt)
"The value of a signed string, or throw `BadSignature`."
function unsign_value(signed::AbstractString; salt = "juango.signing")
    i = findlast(':', signed)
    i === nothing && throw(BadSignature("no signature"))
    v, sig = signed[1:prevind(signed, i)], signed[nextind(signed, i):end]
    consteq(sig, signature(v, salt)) || throw(BadSignature("signature does not match"))
    v
end

"""
    signing_dumps(value; salt="juango.signing") -> String

A URL-safe, signed and timestamped encoding of a JSON-serialisable value.
"""
signing_dumps(value; salt = "juango.signing") =
    sign_value(b64url(JSON.json(value)) * ":" * string(round(Int, time()); base = 36); salt = salt)

"""
    signing_loads(s; max_age=nothing, salt="juango.signing")

Decode `signing_dumps` output. Throws `BadSignature` if it was tampered with and
`SignatureExpired` if older than `max_age` seconds.
"""
function signing_loads(s::AbstractString; max_age = nothing, salt = "juango.signing")
    v = unsign_value(s; salt = salt)
    i = findlast(':', v)
    i === nothing && throw(BadSignature("no timestamp"))
    payload, ts = v[1:i-1], parse(Int, v[i+1:end]; base = 36)
    max_age !== nothing && time() - ts > max_age && throw(SignatureExpired("signature is $(round(Int, time() - ts)) seconds old"))
    plainjson(JSON.parse(String(b64url_decode(payload))))
end
