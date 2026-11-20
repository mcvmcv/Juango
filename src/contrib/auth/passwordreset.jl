# Password reset ---------------------------------------------------------------------------------------
#
#     path("accounts/", auth_urls())                   # also adds password_reset/, reset/<uidb64>/<token>/ ...

# --- password reset tokens (as Django: invalidated by a password change or a new login) -------------------

const RESET_EPOCH = DateTime(2001, 1, 1)
reset_now() = round(Int, (now(Dates.UTC) - RESET_EPOCH) / Second(1))

function reset_hash(u::AbstractUser, ts::Int, secret)
    isempty(string(secret)) && throw(ImproperlyConfigured("The SECRET_KEY setting must not be empty."))
    login = u.last_login === nothing ? "" : Dates.format(u.last_login, "yyyy-mm-ddTHH:MM:SS")
    value = string(u.id, u.password, login, ts, something(u.email, ""))
    h = bytes2hex(hmac_sha256(Vector{UInt8}(codeunits("juango.passwordreset" * string(secret))), Vector{UInt8}(codeunits(value))))
    h[1:2:end]
end

"""
    make_reset_token(user; secret = SECRET_KEY) -> String

A one-time password reset token for a user (Django's PasswordResetTokenGenerator). It stops
working when the password changes, the user logs in, the email changes, or after
PASSWORD_RESET_TIMEOUT seconds.
"""
make_reset_token(u::AbstractUser; ts = reset_now(), secret = settings.SECRET_KEY) = string(ts; base = 36) * "-" * reset_hash(u, ts, secret)

"""
    check_reset_token(user, token; secret = nothing) -> Bool

Whether a password reset token is valid for the user. Made with `SECRET_KEY` or one of
`SECRET_KEY_FALLBACKS` (or with `secret`, when given).
"""
check_reset_token(::Nothing, token; kw...) = false
check_reset_token(u, ::Nothing; kw...) = false
check_reset_token(::Nothing, ::Nothing; kw...) = false
function check_reset_token(u::AbstractUser, token::AbstractString; secret = nothing, now = reset_now())
    parts = split(token, '-')
    length(parts) == 2 || return false
    ts = tryparse(Int, parts[1]; base = 36)
    ts === nothing && return false
    secrets = secret === nothing ? verification_keys() : [secret]
    any(k -> consteq(string(parts[2]), reset_hash(u, ts, k)), secrets) || return false
    now - ts <= settings.PASSWORD_RESET_TIMEOUT
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
    p1 == p2 || return add_error!(f, :new_password2, gettext("The two password fields didn’t match."))
end

"The `AUTH_PASSWORD_VALIDATORS` messages for a password (see `validate_password`)."
password_problems(p; user = nothing) = validate_password(p; user = user)

"Run the password validators on a valid set-password form's new password, for `user`. Returns whether it passed."
function check_new_password!(form::Form, user)
    admin = form.name == "AdminPasswordChangeForm"
    p = get(form.cleaned_data, admin ? :password1 : :new_password1, nothing)
    p === nothing && return false
    for msg in validate_password(p; user = user)
        add_error!(form, admin ? :password2 : :new_password2, msg)
    end
    isempty(form.errors)
end

"""
    AdminPasswordChangeForm(data = nothing)

An administrator setting someone's password (Django's): `password1` and `password2`, which must
match and pass AUTH_PASSWORD_VALIDATORS (`check_new_password!(form, user)` runs those).
Then `set_password!(user, form.cleaned_data[:password1]); save!(user)`.
"""
@form AdminPasswordChangeForm begin
    password1 = CharField(widget = :password, max_length = 4096, label = "Password")
    password2 = CharField(widget = :password, max_length = 4096, label = "Password (again)")
end
function clean_form(f::Form, ::Val{:AdminPasswordChangeForm})
    p1, p2 = get(f.cleaned_data, :password1, nothing), get(f.cleaned_data, :password2, nothing)
    (p1 === nothing || p2 === nothing) && return
    p1 == p2 || return add_error!(f, :password2, gettext("The two password fields didn’t match."))
end

@form PasswordChangeForm begin
    old_password = CharField(widget = :password, max_length = 4096, label = "Old password")
    new_password1 = CharField(widget = :password, max_length = 4096, label = "New password")
    new_password2 = CharField(widget = :password, max_length = 4096, label = "New password confirmation")
end
clean_form(f::Form, ::Val{:PasswordChangeForm}) = clean_form(f, Val(:SetPasswordForm))

"The form data with its username in NFKC form (Django's UsernameField), the rest as it is."
function normalized_username_data(data, U)
    data === nothing && return data
    k = string(username_field(U))
    v = get(data, k, nothing)
    v isa AbstractString || return data
    n = normalize_username(v)
    n == v && return data
    d = data isa QueryDict ? copy(data) : Dict{String,Any}(string(a) => b for (a, b) in data)
    d isa QueryDict ? (d.data[k] = [n]) : (d[k] = n)
    d
end

"""
    UserCreationForm(data = nothing; fields = [username_field], instance = nothing, kw...)

Django's sign-up form for the `AUTH_USER_MODEL`: its username field (plus any `fields`),
`password1` and `password2`. The passwords must match and pass `AUTH_PASSWORD_VALIDATORS`;
`save!(form)` stores the password hashed. Other keywords go to `ModelForm`.

    form = UserCreationForm(req.POST)
    is_valid(form) && (user = save!(form); login!(req, user))
"""
function UserCreationForm(data = nothing; fields = nothing, instance = nothing, kw...)
    U = get_user_model()
    data = normalized_username_data(data, U)
    f = ModelForm(U; data = data, instance = instance, kw...,
                  fields = fields === nothing ? [username_field(U)] : fields)
    for (n, l) in ((:password1, "Password"), (:password2, "Password confirmation"))
        fld = CharField(widget = :password, max_length = 4096, label = l)
        fld.name = n
        push!(f.fields, fld)
    end
    f.fields[end].help_text = "Enter the same password as before, for verification."
    f.fields[end-1].help_text = password_validators_help_text_html()       # (the validators' rules, as Django's)
    f.name = "UserCreationForm"
    f
end
function clean_form(f::Form, ::Val{:UserCreationForm})
    p1, p2 = get(f.cleaned_data, :password1, nothing), get(f.cleaned_data, :password2, nothing)
    (p1 === nothing || p2 === nothing) && return
    p1 == p2 || return add_error!(f, :password2, gettext("The two password fields didn’t match."))
    # validate against the user as entered, so UserAttributeSimilarityValidator sees the username
    u = f.instance === nothing ? f.model() : f.instance
    for (k, v) in f.cleaned_data
        findfield(modelmeta(f.model), k) === nothing || setproperty!(u, k, v)
    end
    foreach(msg -> add_error!(f, :password2, msg), validate_password(p1; user = u))
end
form_save_hook(f::Form, ::Val{:UserCreationForm}, u) = set_password!(u, f.cleaned_data[:password1])

"""
    UserChangeForm(data = nothing; instance, fields = nothing, kw...)

Django's form for editing a user: the `AUTH_USER_MODEL`'s editable fields except the
password, which can only be changed through a password form. `password_summary(user)`
describes the stored hash for display.
"""
function UserChangeForm(data = nothing; instance = nothing, fields = nothing, exclude = Symbol[], kw...)
    U = get_user_model()
    f = ModelForm(U; data = data, instance = instance, fields = fields, exclude = vcat(Symbol.(exclude), :password), kw...)
    f.name = "UserChangeForm"
    f
end

"""
    password_summary(user_or_hash) -> String

A safe description of a stored password hash (algorithm and parameters, never the hash),
like the admin's "Password" line: `"algorithm: pbkdf2_sha256 iterations: 1000000 salt: abc***"`.
"""
function password_summary(x)
    h = x isa AbstractString ? x : string(something(getproperty(x, :password), ""))
    (isempty(h) || startswith(h, "!")) && return "No password set."
    parts = split(h, '$')
    length(parts) < 2 && return "Invalid password format or unknown hashing algorithm."
    algo = parts[1]
    io = IOBuffer()
    print(io, "algorithm: ", algo)
    if startswith(algo, "pbkdf2") && length(parts) == 4
        print(io, " iterations: ", parts[2], " salt: ", mask(parts[3]), " hash: ", mask(parts[4]))
    else
        print(io, " hash: ", mask(parts[end]))
    end
    String(take!(io))
end
mask(s, shown = 6) = (n = min(shown, length(s)); first(s, n) * "*"^max(length(s) - n, 0))

"""
    update_session_auth_hash!(req, user)

Keep the user logged in after changing their password (which otherwise ends their sessions):
store the new password's hash in this session, under a new session key.
"""
function update_session_auth_hash!(req::Request, u::AbstractUser)
    s = req.session
    s isa Session || return
    s.key === nothing || cycle_key!(s)
    req.user isa AbstractUser && req.user.id == u.id && (s["_auth_user_hash"] = session_auth_hash(u))
    nothing
end

"""
    PasswordChangeView(; template = "registration/password_change_form.html", success_url = nothing)

For a logged-in user: the old password and the new one twice (checked by
`AUTH_PASSWORD_VALIDATORS`). On success the user stays logged in and goes to `success_url`
(default: the `password_change_done` URL).
"""
function PasswordChangeView(; template = "registration/password_change_form.html", success_url = nothing)
    login_required(name_view!(function (req::Request; kw...)
        u = req.user
        form = PasswordChangeForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form)
            check_password(u, form.cleaned_data[:old_password]) ||
                add_error!(form, :old_password, gettext("Your old password was entered incorrectly. Please enter it again."))
            if isempty(form.errors) && check_new_password!(form, u)
                set_password!(u, form.cleaned_data[:new_password1])
                save!(u)
                update_session_auth_hash!(req, u)
                return HttpResponseRedirect(something(success_url, reverse_url("password_change_done")))
            end
        end
        render(req, template, Dict("form" => form))
    end, "PasswordChangeView"))
end

"""
    PasswordChangeDoneView(; template = "registration/password_change_done.html")

The page after a successful password change (logged-in users only).
"""
PasswordChangeDoneView(; template = "registration/password_change_done.html") =
    login_required(template_page(template, "PasswordChangeDoneView"))

"""
    PasswordResetView(; template, email_template, subject_template, from_email=nothing)

Asks for an email address and mails a reset link to the active users with that address.
Always continues to the "done" page, so it doesn't reveal which addresses exist.
"""
function PasswordResetView(; template = "registration/password_reset_form.html",
                           email_template = "registration/password_reset_email.txt",
                           subject_template = "registration/password_reset_subject.txt", from_email = nothing,
                           success_url = nothing, extra_email_context = Dict{String,Any}())
    name_view!(function (req::Request; kw...)
        form = PasswordResetForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form)
            email = form.cleaned_data[:email]
            for u in filter(get_user_model(); email__iexact = email, is_active = true)
                has_usable_password(u) || continue
                ctx = Dict{String,Any}("user" => u, "uid" => uid_encode(u.id), "token" => make_reset_token(u),
                                       "protocol" => is_secure(req) ? "https" : "http", "domain" => site_domain(req), "site_name" => (is_installed("sites") ? get_current_site(req).name : get_host(req)),
                                       "site_name" => settings.SITE_NAME, "email" => u.email)
                merge!(ctx, Dict{String,Any}(string(k) => v for (k, v) in extra_email_context))
                ctx["reset_url"] = ctx["protocol"] * "://" * ctx["domain"] *
                                   reverse_url("password_reset_confirm"; uidb64 = ctx["uid"], token = ctx["token"])
                subject = replace(strip(render_to_string(subject_template, ctx)), r"\s+" => " ")
                send_mail(subject, render_to_string(email_template, ctx), from_email, [u.email])
            end
            return HttpResponseRedirect(something(success_url === nothing ? nothing : resolve_login_url(success_url), reverse_url("password_reset_done")))
        end
        render(req, template, Dict("form" => form))
    end, "PasswordResetView")
end

"""
    PasswordResetConfirmView(; template="registration/password_reset_confirm.html")

The page behind the emailed link: checks the token and lets the user choose a new
password. `validlink` is false in the template when the link is invalid or used.
"""
function PasswordResetConfirmView(; template = "registration/password_reset_confirm.html", success_url = nothing,
                                  post_reset_login = false, post_reset_login_backend = nothing, reset_url_token = "set-password")
    name_view!(function (req::Request; uidb64, token, kw...)
        id = uid_decode(uidb64)
        pk = id === nothing ? nothing : parse_pk(get_user_model(), id)
        u = pk === nothing ? nothing : first(filter(get_user_model(); id = pk))
        invalid() = render(req, template, Dict("validlink" => false, "form" => nothing))
        u === nothing && return invalid()
        # As Django's: the emailed link's token goes into the session and the browser to
        # .../<reset_url_token>/, so the token isn't in the address the page's resources see (Referer)
        s = req.session isa Session ? req.session : nothing
        if token == reset_url_token
            s === nothing && return invalid()
            t = get(s, "_password_reset_token", nothing)
            (t === nothing || !check_reset_token(u, t)) && return invalid()
        else
            check_reset_token(u, token) || return invalid()
            if s !== nothing
                s["_password_reset_token"] = token
                return HttpResponseRedirect(replace(req.path, token => reset_url_token))
            end
        end
        form = SetPasswordForm(req.method == "POST" ? req.POST : nothing)
        if req.method == "POST" && is_valid(form) && check_new_password!(form, u)
            set_password!(u, form.cleaned_data[:new_password1])
            save!(u)
            s === nothing || delete!(s, "_password_reset_token")
            post_reset_login && login!(req, u; backend = post_reset_login_backend)
            return HttpResponseRedirect(something(success_url === nothing ? nothing : resolve_login_url(success_url), reverse_url("password_reset_complete")))
        end
        render(req, template, Dict("validlink" => true, "form" => form))
    end, "PasswordResetConfirmView")
end

"A view that only renders a template (the reset 'done' and 'complete' pages)."
template_page(template, label) = name_view!((req::Request; kw...) -> render(req, template), label)
