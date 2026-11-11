# Signing and password reset ---------------------------------------------------------------------------
#
#     s = signing_dumps(Dict("user" => 3))            # tamper-proof, URL-safe text
#     signing_loads(s; max_age = 3600)                 # the value, or throws BadSignature / SignatureExpired
#
#     path("accounts/", auth_urls())                   # also adds password_reset/, reset/<uidb64>/<token>/ ...

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

# --- password reset tokens (as Django: invalidated by a password change or a new login) -------------------

const RESET_EPOCH = DateTime(2001, 1, 1)
reset_now() = round(Int, (now(Dates.UTC) - RESET_EPOCH) / Second(1))

function reset_hash(u::User, ts::Int)
    login = u.last_login === nothing ? "" : Dates.format(u.last_login, "yyyy-mm-ddTHH:MM:SS")
    value = string(u.id, u.password, login, ts, u.email)
    h = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits("juango.passwordreset" * string(settings.SECRET_KEY))), Vector{UInt8}(codeunits(value))))
    h[1:2:end]
end

"A one-time password reset token for a user."
make_reset_token(u::User; ts = reset_now()) = string(ts; base = 36) * "-" * reset_hash(u, ts)

"Whether a password reset token is valid (not tampered with, not used, not older than PASSWORD_RESET_TIMEOUT)."
function check_reset_token(u::User, token::AbstractString)
    parts = split(token, '-')
    length(parts) == 2 || return false
    ts = tryparse(Int, parts[1]; base = 36)
    ts === nothing && return false
    consteq(string(parts[2]), reset_hash(u, ts)) || return false
    reset_now() - ts <= settings.PASSWORD_RESET_TIMEOUT
end

uid_encode(id) = b64url(string(id))
uid_decode(s) = try String(b64url_decode(s)) catch; nothing end

# --- forms and views -----------------------------------------------------------------------------------------

@form PasswordResetForm begin
    email = EmailField(max_length = 254)
end

@form SetPasswordForm begin
    new_password1 = CharField(widget = :password, max_length = 4096, label = "New password")
    new_password2 = CharField(widget = :password, max_length = 4096, label = "New password confirmation")
end
function clean_form(f::Form, ::Val{:SetPasswordForm})
    p1, p2 = get(f.cleaned_data, :new_password1, nothing), get(f.cleaned_data, :new_password2, nothing)
    (p1 === nothing || p2 === nothing) && return
    p1 == p2 || return add_error!(f, :new_password2, "The two password fields didn’t match.")
    for msg in password_problems(p1)
        add_error!(f, :new_password2, msg)
    end
end

"Basic password checks: at least `PASSWORD_MIN_LENGTH` characters, not entirely numeric."
function password_problems(p)
    out = String[]
    length(p) < settings.PASSWORD_MIN_LENGTH &&
        push!(out, "This password is too short. It must contain at least $(settings.PASSWORD_MIN_LENGTH) characters.")
    all(isdigit, p) && push!(out, "This password is entirely numeric.")
    out
end

"""
    PasswordResetView(; template, email_template, subject_template, from_email=nothing)

Asks for an email address and mails a reset link to the active users with that address.
Always continues to the "done" page, so it doesn't reveal which addresses exist.
"""
function PasswordResetView(; template = "registration/password_reset_form.html",
                           email_template = "registration/password_reset_email.txt",
                           subject_template = "registration/password_reset_subject.txt", from_email = nothing)
    name_view!(function (req::Request; kw...)
        form = PasswordResetForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form)
            email = form.cleaned_data[:email]
            for u in filter(User; email__iexact = email, is_active = true)
                has_usable_password(u) || continue
                ctx = Dict{String,Any}("user" => u, "uid" => uid_encode(u.id), "token" => make_reset_token(u),
                                       "protocol" => is_secure(req) ? "https" : "http", "domain" => get_host(req),
                                       "site_name" => settings.SITE_NAME, "email" => u.email)
                ctx["reset_url"] = ctx["protocol"] * "://" * ctx["domain"] *
                                   reverse_url("password_reset_confirm"; uidb64 = ctx["uid"], token = ctx["token"])
                subject = replace(strip(render_to_string(subject_template, ctx)), r"\s+" => " ")
                send_mail(subject, render_to_string(email_template, ctx), from_email, [u.email])
            end
            return HttpResponseRedirect(reverse_url("password_reset_done"))
        end
        render(req, template, Dict("form" => form))
    end, "PasswordResetView")
end

"""
    PasswordResetConfirmView(; template="registration/password_reset_confirm.html")

The page behind the emailed link: checks the token and lets the user choose a new
password. `validlink` is false in the template when the link is invalid or used.
"""
function PasswordResetConfirmView(; template = "registration/password_reset_confirm.html")
    name_view!(function (req::Request; uidb64, token, kw...)
        id = uid_decode(uidb64)
        pk = id === nothing ? nothing : parse_pk(User, id)
        u = pk === nothing ? nothing : first(filter(User; id = pk))
        if u === nothing || !check_reset_token(u, token)
            return render(req, template, Dict("validlink" => false, "form" => nothing))
        end
        form = SetPasswordForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form)
            set_password!(u, form.cleaned_data[:new_password1])
            save!(u)
            return HttpResponseRedirect(reverse_url("password_reset_complete"))
        end
        render(req, template, Dict("validlink" => true, "form" => form))
    end, "PasswordResetConfirmView")
end

"A view that only renders a template (the reset 'done' and 'complete' pages)."
template_page(template, label) = name_view!((req::Request; kw...) -> render(req, template), label)
