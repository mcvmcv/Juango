# Validators --------------------------------------------------------------------------------------------
#
# Django's django.core.validators, for `validators = [...]` on model and form fields:
#
#     code = CharField(max_length = 8, validators = [RegexValidator(r"^[A-Z]{2}\d+$"; message = "Two letters, then digits.")])
#     qty  = IntegerField(validators = [MinValueValidator(1)])       # or IntegerField(min_value = 1)
#
# Each has a `code` ("invalid", "min_value", ...): a field's `error_messages = Dict("min_value" => "...")`
# replaces the message of that code, as in Django. Messages can name the limit: %(limit_value)s,
# %(show_value)s (the value given), %(value)s.
#
# A validator is also a plain function: `v(x)` gives the error message, or `nothing` when `x` is valid.
# Any function works as a validator too: return `nothing`/`true` when valid, else a message (or `false`),
# or throw `ValidationError(msg; code)`.

abstract type Validator end

"`(code, message)` when `x` fails the validator, else `nothing`."
function validation_error end

"The `%(name)s` parameters of a validator's message for `x` (for a field's own `error_messages`)."
validator_params(v::Validator, x) = Dict{String,Any}("value" => x)

(v::Validator)(x) = (r = validation_error(v, x); r === nothing ? nothing : r[2])

msg_or(v, default) = v.message === nothing ? default : string(v.message)

"""
    RegexValidator(regex; message = "Enter a valid value.", code = "invalid", inverse_match = false)

The value (as a string) must match `regex` (or must not, with `inverse_match`). A string regex
is compiled; `flags` are its options ("i" for case-insensitive).
"""
struct RegexValidator <: Validator
    regex::Regex
    message::Any
    code::String
    inverse_match::Bool
end
RegexValidator(regex = r""; message = nothing, code = "invalid", inverse_match::Bool = false, flags = "") =
    RegexValidator(regex isa Regex ? regex : Regex(string(regex), string(flags)), message, string(code), inverse_match)
validation_error(v::RegexValidator, x) =
    occursin(v.regex, string(x)) != v.inverse_match ? nothing : (v.code, msg_or(v, gettext("Enter a valid value.")))

"""
    EmailValidator(; message, code = "invalid", allowlist = ["localhost"])

An email address: a local part, `@`, and a domain with a dot (or one in `allowlist`).
"""
struct EmailValidator <: Validator
    message::Any
    code::String
    allowlist::Vector{String}
end
EmailValidator(; message = nothing, code = "invalid", allowlist = ["localhost"]) = EmailValidator(message, string(code), String.(allowlist))
function validation_error(v::EmailValidator, x)
    s = string(x)
    bad = (v.code, msg_or(v, gettext("Enter a valid email address.")))
    m = match(r"^([^@\s]+)@([^@\s]+)$", s)
    m === nothing && return bad
    domain = lowercase(m[2])
    domain in v.allowlist && return nothing
    occursin(r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9-]{2,63}$"i, domain) ||
        occursin(r"^\[[0-9a-f:.]+\]$"i, domain) || return bad
    occursin(r"^[\w!#$%&'*+/=?^`{|}~.-]+$", m[1]) && !startswith(m[1], ".") && !endswith(m[1], ".") && !occursin("..", m[1]) ? nothing : bad
end

"""
    URLValidator(; schemes = ["http", "https", "ftp", "ftps"], message, code = "invalid")

A URL with one of `schemes`, a host (a domain, `localhost` or an IP address), and an optional
port, path, query and fragment.
"""
struct URLValidator <: Validator
    schemes::Vector{String}
    message::Any
    code::String
end
URLValidator(; schemes = ["http", "https", "ftp", "ftps"], message = nothing, code = "invalid") =
    URLValidator(lowercase.(String.(schemes)), message, string(code))
function validation_error(v::URLValidator, x)
    s = string(x)
    bad = (v.code, msg_or(v, gettext("Enter a valid URL.")))
    (length(s) > 2048 || occursin(r"\s", s)) && return bad
    m = match(r"^([a-z][a-z0-9+.-]*)://(?:[^\s:@/]+(?::[^\s:@/]*)?@)?(\[[0-9a-f:.]+\]|[^\s:/?#]+)(?::(\d{1,5}))?(?:[/?#]\S*)?$"i, s)
    m === nothing && return bad
    lowercase(m[1]) in v.schemes || return bad
    host = lowercase(m[2])
    ok = host == "localhost" || startswith(host, "[") ||
         occursin(r"^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$", host) ||
         occursin(r"^(?:[a-z0-9\u00a1-\uffff](?:[a-z0-9\u00a1-\uffff-]{0,61}[a-z0-9\u00a1-\uffff])?\.)+(?:[a-z\u00a1-\uffff-]{2,63}|xn--[a-z0-9]{1,59})\.?$"i, host)
    ok ? nothing : bad
end

# --- limits ---------------------------------------------------------------------------------------------

abstract type LimitValidator <: Validator end
validator_params(v::LimitValidator, x) =
    Dict{String,Any}("limit_value" => v.limit, "value" => x, "show_value" => v isa Union{MinLengthValidator,MaxLengthValidator} ? length(x) : x)
limit_message(v::LimitValidator, default, x, shown) =
    (v.code, interpolate(msg_or(v, default), Dict("limit_value" => v.limit, "show_value" => shown, "value" => x)))

"`MinValueValidator(limit)`: the value must be at least `limit` (code \"min_value\")."
struct MinValueValidator <: LimitValidator
    limit::Any
    message::Any
    code::String
end
MinValueValidator(limit; message = nothing, code = "min_value") = MinValueValidator(limit, message, string(code))
validation_error(v::MinValueValidator, x) =
    x < v.limit ? limit_message(v, gettext("Ensure this value is greater than or equal to %(limit_value)s."), x, x) : nothing

"`MaxValueValidator(limit)`: the value must be at most `limit` (code \"max_value\")."
struct MaxValueValidator <: LimitValidator
    limit::Any
    message::Any
    code::String
end
MaxValueValidator(limit; message = nothing, code = "max_value") = MaxValueValidator(limit, message, string(code))
validation_error(v::MaxValueValidator, x) =
    x > v.limit ? limit_message(v, gettext("Ensure this value is less than or equal to %(limit_value)s."), x, x) : nothing

"`MinLengthValidator(n)`: at least `n` characters (or items) (code \"min_length\")."
struct MinLengthValidator <: LimitValidator
    limit::Int
    message::Any
    code::String
end
MinLengthValidator(limit::Integer; message = nothing, code = "min_length") = MinLengthValidator(Int(limit), message, string(code))
function validation_error(v::MinLengthValidator, x)
    n = length(x)
    n >= v.limit && return nothing
    limit_message(v, ngettext("Ensure this value has at least %(limit_value)d character (it has %(show_value)d).",
                              "Ensure this value has at least %(limit_value)d characters (it has %(show_value)d).", v.limit), x, n)
end

"`MaxLengthValidator(n)`: at most `n` characters (or items) (code \"max_length\")."
struct MaxLengthValidator <: LimitValidator
    limit::Int
    message::Any
    code::String
end
MaxLengthValidator(limit::Integer; message = nothing, code = "max_length") = MaxLengthValidator(Int(limit), message, string(code))
function validation_error(v::MaxLengthValidator, x)
    n = length(x)
    n <= v.limit && return nothing
    limit_message(v, ngettext("Ensure this value has at most %(limit_value)d character (it has %(show_value)d).",
                              "Ensure this value has at most %(limit_value)d characters (it has %(show_value)d).", v.limit), x, n)
end

"""
    StepValueValidator(step; offset = nothing)

The value must be a multiple of `step` (code "step_size"), counted from `offset` when given
(Django 5: a field with `min_value` counts steps from it).
"""
struct StepValueValidator <: LimitValidator
    limit::Any
    offset::Any
    message::Any
    code::String
end
StepValueValidator(step; offset = nothing, message = nothing, code = "step_size") = StepValueValidator(step, offset, message, string(code))
function validation_error(v::StepValueValidator, x)
    base = v.offset === nothing ? zero(x) : v.offset
    r = rem(x - base, v.limit)
    on_step = iszero(r) || (r isa AbstractFloat && (isapprox(r, 0; atol = 1e-9) || isapprox(abs(r), abs(v.limit); atol = 1e-9)))
    on_step && return nothing
    default = v.offset === nothing ? gettext("Ensure this value is a multiple of step size %(limit_value)s.") :
              interpolate(gettext("Ensure this value is a multiple of step size %(limit_value)s, starting from %(offset)s, e.g. %(offset)s, %(valid_value1)s, %(valid_value2)s, and so on."),
                          Dict("offset" => v.offset, "valid_value1" => v.offset + v.limit, "valid_value2" => v.offset + 2v.limit,
                               "limit_value" => v.limit))
    limit_message(v, default, x, x)
end

"""
    DecimalValidator(max_digits, decimal_places)

At most `max_digits` digits in all and `decimal_places` after the point (codes "max_digits",
"max_decimal_places", "max_whole_digits"; "invalid" for something that isn't a number).
"""
struct DecimalValidator <: Validator
    max_digits::Union{Nothing,Int}
    decimal_places::Union{Nothing,Int}
end
function validation_error(v::DecimalValidator, x)
    d = x isa Decimal ? x : something(tryparse(Decimal, string(x)), Some(nothing))
    d === nothing && return ("invalid", gettext("Enter a number."))
    digits, decimals = decimal_digits(d)
    md, dp = v.max_digits, v.decimal_places
    if md !== nothing && digits > md
        return ("max_digits", interpolate(ngettext("Ensure that there are no more than %(max)s digit in total.",
                                                   "Ensure that there are no more than %(max)s digits in total.", md), Dict("max" => md)))
    elseif dp !== nothing && decimals > dp
        return ("max_decimal_places", interpolate(ngettext("Ensure that there are no more than %(max)s decimal place.",
                                                           "Ensure that there are no more than %(max)s decimal places.", dp), Dict("max" => dp)))
    elseif md !== nothing && dp !== nothing && digits - decimals > md - dp
        return ("max_whole_digits", interpolate(ngettext("Ensure that there are no more than %(max)s digit before the decimal point.",
                                                         "Ensure that there are no more than %(max)s digits before the decimal point.", md - dp),
                                                Dict("max" => md - dp)))
    end
    nothing
end

"`ProhibitNullCharactersValidator()`: no NUL characters (code \"null_characters_not_allowed\"), which PostgreSQL refuses."
struct ProhibitNullCharactersValidator <: Validator
    message::Any
    code::String
end
ProhibitNullCharactersValidator(; message = nothing, code = "null_characters_not_allowed") = ProhibitNullCharactersValidator(message, string(code))
validation_error(v::ProhibitNullCharactersValidator, x) =
    occursin('\0', string(x)) ? (v.code, msg_or(v, gettext("Null characters are not allowed."))) : nothing

"`IPAddressValidator(protocol)`: an IPv4 (`\"ipv4\"`), IPv6 (`\"ipv6\"`) or either (`\"both\"`) address."
struct IPAddressValidator <: Validator
    protocol::String
end
validation_error(v::IPAddressValidator, x) = (r = clean_ip(string(x), v.protocol, false); r isa Tuple ? ("invalid", r[1]) : nothing)

# Django's ready-made validators
const validate_email = EmailValidator()
const validate_slug = RegexValidator(r"^[-a-zA-Z0-9_]+\z";
    message = gettext_lazy("Enter a valid “slug” consisting of letters, numbers, underscores or hyphens."))
const validate_unicode_slug = RegexValidator(r"^[-\p{L}\p{N}_]+\z";
    message = gettext_lazy("Enter a valid “slug” consisting of Unicode letters, numbers, underscores, or hyphens."))
const validate_ipv4_address = IPAddressValidator("ipv4")
const validate_ipv6_address = IPAddressValidator("ipv6")
const validate_ipv46_address = IPAddressValidator("both")

"""
    int_list_validator(; sep = ",", allow_negative = false, message, code = "invalid")

Integers separated by `sep` (Django's `validate_comma_separated_integer_list`).
"""
function int_list_validator(; sep = ",", allow_negative::Bool = false, message = nothing, code = "invalid")
    n = allow_negative ? "-?\\d+" : "\\d+"
    s = replace(string(sep), r"([\\^$.|?*+()\[\]{}])" => s"\\\1")
    RegexValidator(Regex("^$n(?:$s$n)*\\z"); message = something(message, gettext_lazy("Enter only digits separated by commas.")), code = code)
end
const validate_comma_separated_integer_list = int_list_validator()

"""
A message of field `f` for error `code`: its `error_messages` entry if it has one, else `default`,
with `%(name)s` parameters filled in.
"""
function field_message(f, code::AbstractString, default::AbstractString, params = nothing)
    em = f.error_messages
    m = em !== nothing && haskey(em, code) ? em[code] : default
    params === nothing ? String(m) : interpolate(m, params)
end

"""
The messages from a field's validators for value `x` (with the field's `error_messages` applied
by code): `Validator`s, functions returning a message or `false`, and functions throwing
`ValidationError`.
"""
function validator_errors(f, x)
    errs = String[]
    for val in f.validators
        if val isa Validator
            r = validation_error(val, x)
            r === nothing || push!(errs, f.error_messages !== nothing && haskey(f.error_messages, r[1]) ?
                                         field_message(f, r[1], r[2], validator_params(val, x)) : r[2])
            continue
        end
        r = try
            val(x)
        catch e
            e isa ValidationError || rethrow()
            e
        end
        if r isa ValidationError
            for (_, ms) in r.errors, m in ms
                push!(errs, r.code === nothing ? m : field_message(f, r.code, m))
            end
        elseif r isa AbstractString
            push!(errs, r)
        elseif r === false
            push!(errs, field_message(f, "invalid", gettext("Enter a valid value.")))
        end
    end
    errs
end
