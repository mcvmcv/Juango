# N+1 queries: noticed in DEBUG --------------------------------------------------------------------
#
# A relation loaded lazily on many objects of one request (`for a in articles; a.author ...`) is
# one query per object where one would do. Juango counts, per request and relation, the objects
# whose relation was loaded lazily (foreign keys read without select_related, reverse and
# many-to-many accessors without prefetch_related): one object's relation used several ways is
# one, not several (#195). Past NPLUSONE_THRESHOLD (5) objects, it logs a warning naming the relation, where your code reads it and
# the fix. NPLUSONE = :raise makes it an error (for tests), false turns it off; it's on only in
# DEBUG unless NPLUSONE is :raise.

"Raised by a request that runs N+1 queries when `NPLUSONE = :raise`."
struct NPlusOneError <: Exception
    msg::String
end
Base.showerror(io::IO, e::NPlusOneError) = print(io, "NPlusOneError: ", e.msg)

mutable struct NPlusOneTracker
    counts::Dict{Tuple{Any,Symbol},Int}                    # distinct objects whose relation was loaded lazily
    seen::Dict{Tuple{Any,Symbol},Set{Any}}                 # those objects: their primary keys
    found::Dict{Tuple{Any,Symbol},Tuple{Symbol,String}}    # (kind, where) once past the threshold
    allowed::Int
    eager::Dict{Tuple{Any,Symbol},Symbol}                  # select_related / prefetch_related loads: (model, relation) => how
    used::Set{Tuple{Any,Symbol}}                           # eager-loaded relations read at least once
end
const NPLUSONE_KEY = :juango_nplusone

"The mode for this request: `:warn`, `:raise` or `nothing` (off)."
function nplusone_mode()
    m = get(SETTINGS, :NPLUSONE, :warn)
    (m === false || m === nothing) && return nothing
    m === :raise && return :raise
    get(SETTINGS, :DEBUG, false) === true ? :warn : nothing
end

"Track lazy relation loads while `f()` runs (one request); report N+1 patterns at the end."
function with_nplusone_tracking(f)
    mode = nplusone_mode()
    (mode === nothing || haskey(task_local_storage(), NPLUSONE_KEY)) && return f()
    t = NPlusOneTracker(Dict{Tuple{Any,Symbol},Int}(), Dict{Tuple{Any,Symbol},Set{Any}}(), Dict{Tuple{Any,Symbol},Tuple{Symbol,String}}(), 0,
                        Dict{Tuple{Any,Symbol},Symbol}(), Set{Tuple{Any,Symbol}}())
    r = task_local_storage(f, NPLUSONE_KEY, t)
    if mode === :warn
        for (k, (kind, where)) in t.found
            @warn nplusone_message(k, kind, t.counts[k], where)
        end
        for (k, how) in t.eager
            k in t.used || @warn "Unused eager load: $how(:$(k[2])) on $(nameof(k[1])) loaded objects that were never read. Leave it out, or use it."
        end
    end
    r
end

"""
    with_nplusone_allowed(f)

Run `f()` without N+1 reports: for the deliberate cases (a page that really does need each
object's own query).
"""
function with_nplusone_allowed(f)
    t = get(task_local_storage(), NPLUSONE_KEY, nothing)
    t === nothing && return f()
    t.allowed += 1
    try
        f()
    finally
        t.allowed -= 1
    end
end

nplusone_message(k, kind, n, where) =
    "N+1 queries: $(nameof(k[1])).$(k[2]) was loaded for $n objects one at a time in one request$where. " *
    (kind === :fk ? "Add select_related(:$(k[2])) to the queryset." : "Add prefetch_related(:$(k[2])) to the queryset.")

"""
Note a lazy load of relation `s` of `obj`, a `T` (`kind`: `:fk` or `:reverse`); called by the
accessors. It counts distinct objects (by primary key), so one object's relation used several
ways (updated, then filtered, then listed) isn't taken for an N+1.
"""
Base.@nospecializeinfer function note_lazy_load(@nospecialize(T), s::Symbol, kind::Symbol, @nospecialize(obj))
    t = get(task_local_storage(), NPLUSONE_KEY, nothing)
    t === nothing && return
    t = t::NPlusOneTracker
    t.allowed > 0 && return
    k = (T, s)
    id = get(getfield(obj, :_data)::Dict{Symbol,Any}, :id, nothing)
    seen = get!(Set{Any}, t.seen, k)
    key = id === nothing ? objectid(obj) : id
    key in seen && return                                       # this object's relation again: not an N+1
    push!(seen, key)
    n = length(seen)
    t.counts[k] = n
    n == something(get(SETTINGS, :NPLUSONE_THRESHOLD, 5), typemax(Int)) || return
    where = nplusone_origin()
    t.found[k] = (kind, where)
    nplusone_mode() === :raise && throw(NPlusOneError(nplusone_message(k, kind, n, where)))
    nothing
end

"Where the caller's code is: the first frame outside Juango, Base and packages (or a template)."
function nplusone_origin()
    src = normpath(joinpath(@__DIR__, ".."))
    intemplate = false
    for fr in stacktrace(backtrace())
        fr.from_c && continue
        file = string(fr.file)
        if startswith(normpath(file), src)
            startswith(relpath(normpath(file), src), "template") && (intemplate = true)
            continue
        end
        (startswith(file, "./") || occursin("/share/julia/", file) || occursin("/packages/", file) || file == "none") && continue
        return " (from $(fr.func) at $(basename(file)):$(fr.line)$(intemplate ? ", in a template" : ""))"
    end
    intemplate ? " (in a template)" : ""
end

"Note that a queryset of `T` eager-loaded relation `s` (`how`: `:select_related` or `:prefetch_related`)."
Base.@nospecializeinfer function note_eager_load(@nospecialize(T), s::Symbol, how::Symbol)
    t = get(task_local_storage(), NPLUSONE_KEY, nothing)
    t === nothing || t.allowed > 0 || get!(t.eager, (T, s), how)
    nothing
end
"Note that an eager-loaded relation was read."
Base.@nospecializeinfer function note_eager_use(@nospecialize(T), s::Symbol)
    t = get(task_local_storage(), NPLUSONE_KEY, nothing)
    t === nothing || push!(t.used, (T, s))
    nothing
end

# --- AUTO_PREFETCH (django-auto-prefetch's idea) ---------------------------------------------------

"""
With `AUTO_PREFETCH = true`, the objects of a fetched queryset know each other, and the first
time a foreign key is read on one of them it's loaded for all of them in one query, so a loop
over the queryset costs two queries instead of N + 1. Off by default.
"""
Base.@nospecializeinfer function remember_siblings!(@nospecialize(objs::Vector))
    get(SETTINGS, :AUTO_PREFETCH, false) === true && length(objs) > 1 || return
    for o in objs
        (getfield(o, :_cache)::Dict{Symbol,Any})[:__siblings] = objs
    end
end
Base.@nospecializeinfer function auto_prefetch!(@nospecialize(objs::Vector), f, s::Symbol, db)
    a = attname(f)
    need = [o for o in objs if !haskey((getfield(o, :_cache)::Dict{Symbol,Any}), s) && field_data(o, a) !== nothing]
    ids = unique(Any[field_data(o, a) for o in need])
    isempty(ids) && return
    byid = Dict{Any,Any}()
    for r in with_db(() -> fetch(filter(base_objects(related_model(f)); id__in = ids)), db)
        byid[(getfield(r, :_data)::Dict{Symbol,Any})[:id]] = r
    end
    for o in need
        r = get(byid, field_data(o, a), nothing)
        r === nothing || ((getfield(o, :_cache)::Dict{Symbol,Any})[s] = r)
    end
end

