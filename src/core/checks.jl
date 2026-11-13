# System checks -----------------------------------------------------------------------------------------
#
#     Juango.register_check!(tags = [:models]) do
#         isempty(objects(Plan)) ? [Juango.CheckMessage(:warning, "No plans yet."; id = "billing.W001",
#                                                       hint = "Create one in the admin.")] : []
#     end
#     configure!(SILENCED_SYSTEM_CHECKS = ["billing.W001"])
#
# `manage.jl check` runs every registered check (`--deploy` adds the deployment ones, `--tag
# security` picks tags), and `runserver` reports problems when it starts. A check returns
# CheckMessages (or plain strings, taken as warnings); Juango's own have Django's ids where Django
# has the same check (security.W004 for HSTS, ...).

"""
    CheckMessage(level, msg; id = "", hint = nothing)

One problem a system check found. `level` is `:critical`, `:error`, `:warning`, `:info` or `:debug`;
`id` (like `"billing.W001"`) is what `SILENCED_SYSTEM_CHECKS` names.
"""
struct CheckMessage
    level::Symbol
    msg::String
    id::String
    hint::Union{Nothing,String}
end
CheckMessage(level::Symbol, msg::AbstractString; id = "", hint = nothing) =
    CheckMessage(level, String(msg), String(id), hint === nothing ? nothing : String(hint))
Base.show(io::IO, m::CheckMessage) =
    print(io, isempty(m.id) ? "" : "($(m.id)) ", m.msg, m.hint === nothing ? "" : "\n\tHINT: " * m.hint)
is_serious(m::CheckMessage) = m.level in (:error, :critical)

const CHECKS = Vector{Tuple{Any,Vector{Symbol},Bool}}()    # (function, tags, deploy only)

"""
    register_check!(f; tags = Symbol[], deploy = false)

Add a system check: `f()` returns a vector of `CheckMessage`s (or strings). `deploy = true` runs it
only with `check --deploy`. Returns `f`, so it works with `do` blocks.
"""
function register_check!(f; tags = Symbol[], deploy::Bool = false)
    push!(CHECKS, (f, Symbol[Symbol(t) for t in tags], deploy))
    f
end

"""
    run_checks(; tags = nothing, deploy = false, include_silenced = false) -> Vector{CheckMessage}

Run the registered checks (those with one of `tags`, if given), leaving out the ids in
`SILENCED_SYSTEM_CHECKS`.
"""
function run_checks(; tags = nothing, deploy::Bool = false, include_silenced::Bool = false)
    silenced = Set(String[string(x) for x in get(settings, :SILENCED_SYSTEM_CHECKS, String[])])
    out = CheckMessage[]
    for (f, ts, dep) in CHECKS
        dep && !deploy && continue
        tags === nothing || any(in(ts), Symbol.(tags isa Union{Symbol,AbstractString} ? [tags] : tags)) || continue
        msgs = try
            f()
        catch e
            [CheckMessage(:error, "A system check failed: " * sprint(showerror, e); id = "juango.E000")]
        end
        for m in msgs
            m = m isa CheckMessage ? m : CheckMessage(:warning, string(m))
            (include_silenced || !(m.id in silenced)) && push!(out, m)
        end
    end
    out
end
