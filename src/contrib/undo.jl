# Undo: record what an action writes, and put it back (#194) ---------------------------------------------
#
#     data = recording() do rec
#         plate.status = "done"; save!(plate)
#         delete!(filter(Well; plate = plate, empty = true))
#         recorded(rec)                        # JSON-ready: store it with the action (a JSONField)
#     end
#     undo_problem(data)                       # nothing, or why it can't be undone now (tried, rolled back)
#     undo_recorded!(data)                     # puts it all back in one transaction, or throws UndoProblem
#
# Inside `recording`, every write is noted: rows made, each changed field's value before, and a copy of
# each deleted row, whatever wrote them (save!, update!, bulk_create, bulk_update, delete! and the rows
# a delete cascades to or empties a link on) and every many-to-many add, remove or clear. Undoing
# refuses, with an UndoProblem saying why, when:
#
# - a row it changed has been changed again since (or deleted);
# - deleting a row it made would delete, or empty a link on, something made or changed since;
# - a row it deleted can't go back because its place has been taken (a unique value, say).
#
# Fields with `auto_now`/`auto_now_add` are kept with deleted rows but aren't changes worth putting
# back. Juango's own bookkeeping (sessions, the admin log, content types, permissions) isn't recorded.
# The writes an undo makes aren't recorded, and `undoing()` is true while it runs. Rows made by a
# bulk_create on MySQL have no ids to note, so their undo can't delete them.
#
# (Generalised from Echidna's recorder: a LIMS that records each page's action this way.)

"Why something can't be undone."
struct UndoProblem <: Exception
    msg::String
end
Base.showerror(io::IO, e::UndoProblem) = print(io, e.msg)

"What an action has written so far, by model label and row key (as a string)."
struct Recording
    made::Dict{String,Set{String}}
    before::Dict{String,Dict{String,Dict{String,Any}}}     # each changed row's values, as first seen
    deleted::Dict{String,Dict{String,Dict{String,Any}}}    # each deleted row, as first seen
    exclude::Set{String}                                    # model labels not recorded
end

const RECORDING = Base.ScopedValues.ScopedValue{Union{Recording,Nothing}}(nothing)
const UNDOING = Base.ScopedValues.ScopedValue(false)
const UNDO_CONNECTED = Ref(false)
"The models an undo leaves alone unless asked: Juango's own bookkeeping."
const UNDO_DEFAULT_EXCLUDE = ("sessions.Session", "admin.LogEntry", "contenttypes.ContentType", "auth.Permission")

"""
    recording(f; exclude = []) -> f(rec)

Run `f(rec)` with its writes noted in `rec`, a new Recording; `recorded(rec)` turns them into JSON.
`exclude`: model types or labels (`"app.Model"`) not to record, besides Juango's own bookkeeping.
"""
function recording(f; exclude = ())
    connect_undo!()
    ex = Set{String}(UNDO_DEFAULT_EXCLUDE)
    for x in exclude
        push!(ex, x isa Type ? model_label(x) : string(x))
    end
    rec = Recording(Dict(), Dict(), Dict(), ex)
    Base.ScopedValues.with(() -> f(rec), RECORDING => rec)
end
"Run `f()` without recording its writes (inside a `recording`)."
not_recording(f) = Base.ScopedValues.with(f, RECORDING => nothing)
"Whether an undo is putting things back (receivers can leave alone what a delete usually tidies up)."
undoing() = UNDOING[]

# -- rows as JSON ------------------------------------------------------------------------------------------

stamp_field(f::Field) = f.auto_now || f.auto_now_add
"The fields of `T` a recording keeps: the columns but the key and generated ones (and, without `stamps`, the auto_now ones)."
undo_fields(@nospecialize(T); stamps = false) =
    [f for f in concrete_fields(T) if f.generated === nothing && (stamps || !stamp_field(f))]
undo_key(@nospecialize(T), s::AbstractString) = something(parse_pk(T, s), s)

"{key => {attname => JSON value}} of `T`'s rows with these keys, as stored."
function stored_rows(@nospecialize(T), keys, fields = undo_fields(T; stamps = true))
    rows = Dict{String,Dict{String,Any}}()
    isempty(keys) && return rows
    names = [attname(f) for f in fields]
    for row in values(filter(base_objects(T); id__in = [undo_key(T, string(k)) for k in keys]), :id, names...)
        rows[string(row[:id])] = Dict{String,Any}(string(n) => value_to_json(f, row[n]) for (f, n) in zip(fields, names))
    end
    rows
end

# -- noting writes -------------------------------------------------------------------------------------------

active_recording(@nospecialize(T)) =
    (rec = RECORDING[]; rec === nothing || UNDOING[] || is_composite(T) || model_label(T) in rec.exclude ? nothing : rec)

noted_made!(rec, @nospecialize(T), ids) = union!(get!(Set{String}, rec.made, model_label(T)), (string(i) for i in ids if i !== nothing))

"Note the rows' values before they change, unless already noted or made by this action."
function noted_changing!(rec, @nospecialize(T), ids)
    label = model_label(T)
    before = get!(Dict{String,Dict{String,Any}}, rec.before, label)
    made = get(rec.made, label, Set{String}())
    fresh = [string(i) for i in ids if i !== nothing && !haskey(before, string(i)) && !(string(i) in made)]
    isempty(fresh) || merge!(before, stored_rows(T, fresh, undo_fields(T)))
end

function noted_deleting!(rec, @nospecialize(T), rows)
    deleted = get!(Dict{String,Dict{String,Any}}, rec.deleted, model_label(T))
    for (k, row) in rows
        haskey(deleted, k) || (deleted[k] = row)
    end
end

# Before a write: rows about to change (save! over, update!, bulk_update) or be deleted (cascades too,
# and the links a remove! or clear! takes). After it: the rows made (save!, bulk_create) and links added.
function undo_pre_write(@nospecialize(sender); action, ids = nothing, kw...)
    sender isa Type && sender <: Model || return
    rec = active_recording(sender)
    (rec === nothing || ids === nothing) && return
    if action === :update
        noted_changing!(rec, sender, ids)
    elseif action === :delete
        noted_deleting!(rec, sender, stored_rows(sender, [string(i) for i in ids if i !== nothing]))
    end
end
function undo_post_write(@nospecialize(sender); action, ids = nothing, kw...)
    sender isa Type && sender <: Model || return
    rec = active_recording(sender)
    (rec === nothing || ids === nothing || action !== :insert) && return
    noted_made!(rec, sender, ids)
end

"The join model's keys to `instance`'s model and to `model`."
function undo_link_fields(through, instance, model)
    names = Dict{Any,Symbol}()
    for f in concrete_fields(through)
        f.kind === :fk && get!(names, related_model(f), attname(f))
    end
    get(names, typeof(instance), nothing), get(names, model, nothing)
end

function undo_links(@nospecialize(through); action, instance, model, pk_set = nothing, kw...)
    rec = active_recording(through)
    rec === nothing && return
    source, target = undo_link_fields(through, instance, model)
    (source === nothing || target === nothing || source === target) && return
    links = filter(base_objects(through), Q(source => instance.id))
    if action in (:pre_remove, :pre_clear)
        pk_set === nothing || (links = filter(links, Q(Symbol(target, "__in") => collect(pk_set))))
        noted_deleting!(rec, through, stored_rows(through, collect(values_list(links, :id; flat = true))))
    elseif action === :post_add && pk_set !== nothing && !isempty(pk_set)
        noted_made!(rec, through, collect(values_list(filter(links, Q(Symbol(target, "__in") => collect(pk_set))), :id; flat = true)))
    end
end

function connect_undo!()
    UNDO_CONNECTED[] && return
    connect!(pre_write, undo_pre_write; dispatch_uid = "juango undo: before writes")
    connect!(post_write, undo_post_write; dispatch_uid = "juango undo: after writes")
    connect!(m2m_changed, undo_links; dispatch_uid = "juango undo: links")
    UNDO_CONNECTED[] = true
end

# -- the record ------------------------------------------------------------------------------------------------

"""
    recorded(rec) -> Dict

What was done, JSON-ready: `{"made": {label: [key]}, "changed": {label: {key: {attname: [before, after]}}},
"deleted": {label: {key: row}}}`. A row made and deleted again is left out; one changed and then deleted
is kept as it was before the change.
"""
function recorded(rec::Recording)
    made, changed, deleted = Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}()
    for (label, keys) in rec.made
        kept = sort(collect(setdiff(keys, Base.keys(get(rec.deleted, label, Dict())))))
        isempty(kept) || (made[label] = kept)
    end
    for (label, rows) in rec.deleted
        before, mine = get(rec.before, label, Dict()), get(rec.made, label, Set{String}())
        kept = Dict{String,Any}(k => merge(row, get(before, k, Dict())) for (k, row) in rows if !(k in mine))
        isempty(kept) || (deleted[label] = kept)
    end
    for (label, rows) in rec.before
        T = get_model(label)
        keys = [k for k in Base.keys(rows) if !haskey(get(rec.deleted, label, Dict()), k)]
        after = stored_rows(T, keys, undo_fields(T))
        for k in keys
            haskey(after, k) || continue
            fields = Dict{String,Any}(a => Any[v, after[k][a]] for (a, v) in rows[k] if after[k][a] != v)
            isempty(fields) || (get!(Dict{String,Any}, changed, label)[k] = fields)
        end
    end
    Dict{String,Any}("made" => made, "changed" => changed, "deleted" => deleted)
end

"Whether a recording did anything."
has_changes(data) = any(!isempty(get(data, k, Dict())) for k in ("made", "changed", "deleted"))

# -- undoing ----------------------------------------------------------------------------------------------------

counted(@nospecialize(T), n) = (m = modelmeta(T); "$n $(n == 1 ? m.verbose_name : m.verbose_name_plural)")

"""
Sent (sender `nothing`, keyword `data`) by `undo_recorded!` before it puts anything back, while every row it
names is still there: undo writes with `update!` and `bulk_create`, which send no `post_save`, so what an
app works out from the rows in its own receivers is redone by a receiver of this.
"""
const undoing_recorded = Signal("undoing_recorded")

"""
    undo_recorded!(data; tell = true)

Put back what `data` (from `recorded`) did, in one transaction, or throw an `UndoProblem` saying why it
can't be, and change nothing. `tell = false` doesn't send `undoing_recorded`.
"""
undo_recorded!(data; tell = true) =
    Base.ScopedValues.with(RECORDING => nothing, UNDOING => true) do
        atomic() do
            # a link goes back before the deleted row it points at: foreign keys are checked at the end
            deferred_foreign_keys(backend()) do
            tell && send(undoing_recorded, nothing; data = data)
            undo_check_unchanged(data["changed"])
            # first the links it changed, so nothing points at what it made; then what it made goes,
            # making room for the other fields it changed and the rows it deleted
            undo_restore_changed!(data["changed"]; links = true)
            undo_delete_made!(data["made"])
            undo_restore_changed!(data["changed"]; links = false)
            undo_restore_deleted!(data["deleted"])
            end
        end
    end

# PostgreSQL's foreign keys are DEFERRABLE INITIALLY DEFERRED already; SQLite defers them until the
# transaction commits; MySQL can only turn the checks off (and back on) for the connection
deferred_foreign_keys(f, ::DatabaseBackend) = f()
deferred_foreign_keys(f, ::SQLiteBackend) = (execute("PRAGMA defer_foreign_keys = ON"); f())
function deferred_foreign_keys(f, ::MySQLBackend)
    execute("SET FOREIGN_KEY_CHECKS = 0")
    try f() finally execute("SET FOREIGN_KEY_CHECKS = 1") end
end

struct UndoTriedOnly <: Exception end

"Why `undo_recorded!(data)` can't be done now, or `nothing`: it's tried and rolled back."
function undo_problem(data)
    try
        atomic() do
            undo_recorded!(data; tell = false)
            throw(UndoTriedOnly())
        end
    catch e
        e isa UndoProblem && return e.msg
        e isa UndoTriedOnly || rethrow()
    end
    nothing
end

function undo_check_unchanged(changed)
    since = String[]
    for (label, rows) in changed
        T = get_model(label)
        names = Set(a for fields in values(rows) for a in keys(fields))
        now = stored_rows(T, collect(keys(rows)), [f for f in undo_fields(T) if string(attname(f)) in names])
        moved = count(rows) do (k, fields)
            row = get(now, k, nothing)
            row === nothing || any(row[a] != v[2] for (a, v) in fields)
        end
        moved > 0 && push!(since, counted(T, moved))
    end
    isempty(since) || throw(UndoProblem("$(join(since, " and ")) it changed have been changed or deleted since."))
end

"Put back the fields it changed: the relations (`links`), or the rest."
function undo_restore_changed!(changed; links)
    for (label, rows) in changed
        T = get_model(label)
        fields = Dict(string(attname(f)) => f for f in undo_fields(T))
        for (k, vals) in rows
            before = Dict(Symbol(a) => value_from_json(fields[a], v[1]) for (a, v) in vals if (fields[a].kind === :fk) == links)
            isempty(before) || update!(filter(base_objects(T); id = undo_key(T, k)); before...)
        end
    end
end

"Delete what it made, refusing if that would delete or change anything else."
function undo_delete_made!(made)
    mine = Set((label, string(k)) for (label, ks) in made for k in ks)
    side = Recording(Dict(), Dict(), Dict(), Set{String}())
    pending = collect(keys(made))
    Base.ScopedValues.with(RECORDING => side, UNDOING => false) do
        # in an order the protected links allow: those blocked wait for the others
        while !isempty(pending)
            blocked, last_error = String[], nothing
            for label in pending
                T = get_model(label)
                try
                    atomic(() -> delete!(filter(base_objects(T); id__in = [undo_key(T, string(k)) for k in made[label]])))
                catch e
                    e isa Union{ProtectedError,RestrictedError} || rethrow()
                    push!(blocked, label)
                    last_error = e
                end
            end
            if length(blocked) == length(pending)
                users = last_error isa ProtectedError ? last_error.protected_objects : last_error.restricted_objects
                throw(UndoProblem("what it made is used by $(users isa QuerySet ? modelmeta(model_of(users)).verbose_name_plural : "something") since."))
            end
            pending = blocked
        end
    end
    others = Dict{String,Int}()
    for (label, rows) in side.deleted, k in keys(rows)
        (label, k) in mine || (others[label] = get(others, label, 0) + 1)
    end
    for (label, rows) in side.before, k in keys(rows)
        (label, k) in mine || (others[label] = get(others, label, 0) + 1)
    end
    isempty(others) || throw(UndoProblem("$(join([counted(get_model(l), n) for (l, n) in others], ", ")) made or changed since use what it made."))
end

"Put back the rows it deleted, with their keys and stamps: those others point at first."
function undo_restore_deleted!(deleted)
    pending = collect(keys(deleted))
    while !isempty(pending)
        blocked = String[]
        for label in pending
            T = get_model(label)
            rows = deleted[label]
            fields = Dict(string(attname(f)) => f for f in undo_fields(T; stamps = true))
            try
                atomic() do
                    bulk_create([T(; id = undo_key(T, k), (Symbol(a) => value_from_json(fields[a], v) for (a, v) in row if haskey(fields, a))...)
                                 for (k, row) in rows])
                    # an insert stamps auto_now fields itself: give each row back its own
                    stamps = [f for f in values(fields) if stamp_field(f)]
                    if !isempty(stamps)
                        for (k, row) in rows
                            update!(filter(base_objects(T); id = undo_key(T, k)); touch_auto_now = false,
                                    (attname(f) => value_from_json(f, get(row, string(attname(f)), nothing)) for f in stamps)...)
                        end
                    end
                end
            catch e
                e isa IntegrityError || rethrow()
                push!(blocked, label)
            end
        end
        length(blocked) == length(pending) &&
            throw(UndoProblem("the $(join([counted(get_model(l), length(deleted[l])) for l in blocked], " and ")) it deleted can't be put back: something has taken their place since."))
        pending = blocked
    end
end
