# Signals ----------------------------------------------------------------------------------------------
#
#     function on_post_saved(sender; instance, created, kw...)
#         created && send_mail("New post", instance.title, nothing, ["editor@example.com"])
#     end
#     connect!(post_save, on_post_saved; sender = Post)
#
# Receivers are called as `receiver(sender; signal, kwargs...)`, so they should accept extra
# keyword arguments (`kw...`). Overriding `save!` for a model is still the clearer way to change
# that model's own behaviour; signals suit code that lives elsewhere (search indexes, caches,
# notifications).

"""
    Signal(name="")

A hook that receivers subscribe to with `connect!` and that code fires with `send`.
"""
mutable struct Signal
    name::String
    receivers::Vector{Tuple{Any,Any,Any}}    # (key, receiver, sender or nothing for any)
    lock::ReentrantLock
end
Signal(name = "") = Signal(string(name), Tuple{Any,Any,Any}[], ReentrantLock())
Base.show(io::IO, s::Signal) = print(io, "<Signal ", isempty(s.name) ? "(unnamed)" : s.name, ">")

"""
    connect!(signal, receiver; sender=nothing, dispatch_uid=nothing)

Subscribe `receiver` (called as `receiver(sender; signal, kwargs...)`). With `sender`, only
signals sent by that sender (for model signals: the model type) reach it. Connecting the
same receiver (or `dispatch_uid`) twice for the same sender has no effect.
"""
function connect!(sig::Signal, receiver; sender = nothing, dispatch_uid = nothing)
    check_receiver(receiver)
    key = something(dispatch_uid, objectid(receiver))
    lock(sig.lock) do
        any(r -> r[1] == key && r[3] === sender, sig.receivers) || push!(sig.receivers, (key, receiver, sender))
    end
    receiver
end

# (as Django's: refused when connected rather than failing at the first send; every receiver gets the
# `signal` keyword, so one without keyword arguments can't be called)
function check_receiver(@nospecialize(receiver))
    ms = methods(receiver)
    isempty(ms) && throw(ArgumentError("Signal receivers must be callable."))
    any(m -> !isempty(Base.kwarg_decl(m)), ms) || throw(ArgumentError("Signal receivers must accept keyword arguments (kw...)."))
    nothing
end

"""
    receiver(f, signal; sender=nothing)

Connect a do-block. It gets the sender and the signal's arguments as a NamedTuple:

    receiver(post_save; sender = Post) do sender, args
        args.created && notify(args.instance)
    end

It returns the do-block. Disconnect it with the `dispatch_uid` you give here (default: `objectid` of the do-block).
"""
receiver(f, sig::Signal; sender = nothing, dispatch_uid = nothing) =
    (connect!(sig, (s; kw...) -> f(s, (; kw...)); sender = sender, dispatch_uid = something(dispatch_uid, objectid(f))); f)
"`receiver(f, [signal1, signal2]; ...)`: connect the do-block to each of the signals."
receiver(f, sigs::AbstractVector{Signal}; kw...) = (foreach(sig -> receiver(f, sig; kw...), sigs); f)

"Unsubscribe a receiver (or a `dispatch_uid`); returns whether one was removed."
function disconnect!(sig::Signal, receiver = nothing; sender = nothing, dispatch_uid = nothing)
    key = dispatch_uid === nothing ? objectid(receiver) : dispatch_uid
    lock(sig.lock) do
        n = length(sig.receivers)
        filter!(r -> !(r[1] == key && r[3] === sender), sig.receivers)
        length(sig.receivers) < n
    end
end

"Whether anything is connected at all (no allocation: for signals sent very often, such as post_init)."
any_receivers(sig::Signal) = !isempty(sig.receivers)
live_receivers(sig::Signal, sender) = lock(() -> [r[2] for r in sig.receivers if r[3] === nothing || r[3] === sender], sig.lock)
"""
    receiver_active(receiver, sender) -> Bool

Whether a connected receiver currently wants signals from `sender` (default: always). A receiver
that is usually idle (contrib undo's, outside `recording`) defines a method returning `false`
then, so `has_receivers` doesn't count it and the ORM can take its quick paths (a delete in one
statement, an update without reading the keys first). It is still called if a signal is sent.
"""
receiver_active(@nospecialize(receiver), @nospecialize(sender)) = true
"Whether any receiver would get a signal from `sender` (lets callers skip expensive work)."
has_receivers(sig::Signal, sender) = lock(() -> any(r -> (r[3] === nothing || r[3] === sender) && receiver_active(r[2], sender), sig.receivers), sig.lock)

"""
    send(signal, sender; kwargs...) -> Vector{Pair{receiver, result}}

Call every matching receiver. An exception in a receiver stops the sending and propagates;
`send_robust` collects exceptions as results instead (and logs each to `juango.dispatch` at ERROR).
"""
send(sig::Signal, sender; kw...) = [r => r(sender; signal = sig, kw...) for r in live_receivers(sig, sender)]
function send_robust(sig::Signal, sender; kw...)
    out = Pair{Any,Any}[]
    for r in live_receivers(sig, sender)
        push!(out, r => try
            r(sender; signal = sig, kw...)
        catch e
            log!("juango.dispatch", :error, "Error calling $(r) in Signal.send_robust() ($(sprint(showerror, e)))";
                 exception = (e, catch_backtrace()))
            e
        end)
    end
    out
end

"Before `save!` writes an object: `instance`, `created` (no id yet), `database` (the alias written to; Django's `using`)."
const pre_save = Signal("pre_save")
"After `save!`: `instance`, `created`, `database`."
const post_save = Signal("post_save")
"""
Before an object is deleted (also for cascaded deletes): `instance`, and `origin`: the object or
queryset whose `delete!` started the deletion, and `database` (the alias; Django's `using`).
"""
const pre_delete = Signal("pre_delete")
"After an object is deleted: `instance`, `origin`, `database` (as `pre_delete`)."
const post_delete = Signal("post_delete")
"""
After every write to a model's table, bulk ones included, which Django's signals miss: the one
hook an audit log or undo needs. Sender: the model. Keywords:
- `action`: `:insert`, `:update`, `:delete` or `:m2m`;
- `via`: what wrote it: `:save`, `:update` (`update!`), `:bulk_create`, `:bulk_update`, `:delete`
  (objects, querysets and cascades), or for `:m2m` the `m2m_changed` action (`:post_add`, ...);
- `ids`: the primary keys of the rows written (`nothing` where unknown: bulk inserts on MySQL);
- `fields`: the fields written (`nothing`: all of them);
- `instances`: the objects, when the write had them (`save!`, bulk writes), else `nothing`;
- for `:m2m`, `instance` (the object whose relation changed), `model` and `pk_set`, as `m2m_changed`.
Deletes are reported after the rows are gone; `update!` finds its rows' ids first (one query, and
only when someone listens).
"""
const post_write = Signal("post_write")
"""
Before every write to a model's table, bulk ones included: `post_write`'s twin, with the same
keywords, sent inside the write's transaction before the statement runs, so a receiver can read
the rows as they are (an undo or audit log's old values). New rows have no ids yet: `ids` is
`nothing` for `bulk_create`, and a new object's `save!` has `ids = Any[nothing]`.
"""
const pre_write = Signal("pre_write")
"""
A many-to-many relation changed: sender is the join model; `action` is `:pre_add`,
`:post_add`, `:pre_remove`, `:post_remove`, `:pre_clear` or `:post_clear`; `instance`,
`model` (the other side), `pk_set`, `reverse`, `database` (the alias; Django's `using`).
"""
const m2m_changed = Signal("m2m_changed")
"""
Before `migrate` changes a database, once per app (sender: the app label, e.g. `"auth"`);
`app_label`, `database` (the alias; Django's `using`), `plan` (`[(app, name) => backwards, ...]`) and
`apps` (historical models as the database is now, for `get_model`).
"""
const pre_migrate = Signal("pre_migrate")
"""
After `migrate`, once per app (sender: the app label), with the same arguments as
`pre_migrate`; `apps` describes the migrated state. Juango's content types, permissions
and default site are created by receivers of this signal (for "contenttypes", "auth" and
"sites"), so receivers for later apps can rely on them.
"""
const post_migrate = Signal("post_migrate")
"A request arrived (sender `:handler`; `request`)."
const request_started = Signal("request_started")
"A response is ready (sender `:handler`; `request`, `response`)."
const request_finished = Signal("request_finished")
"A user logged in (sender `User`; `request`, `user`)."
const user_logged_in = Signal("user_logged_in")
"A user logged out (sender `User`; `request`, `user`)."
const user_logged_out = Signal("user_logged_out")
"Authentication failed (sender `:authenticate`; `credentials` without the password)."
const user_login_failed = Signal("user_login_failed")
"A database connection was opened (sender: its backend; `connection` (the driver's) and `alias`): run per-connection `SET`s here."
const connection_created = Signal("connection_created")
"A view raised an exception that becomes a 500 (sender `:handler`; `request`, `exception`)."
const got_request_exception = Signal("got_request_exception")
"""
A setting changed through `configure!` or `override_settings` (sender `:settings`; `setting`,
`value`, `enter`: false when `override_settings` puts the old value back).
"""
const setting_changed = Signal("setting_changed")
"Before a model object is made with `Model(; kwargs...)` (sender: the model; `kwargs`)."
const pre_init = Signal("pre_init")
"After a model object is made, by `Model(; ...)` or from a database row (sender: the model; `instance`)."
const post_init = Signal("post_init")
"A model was defined with `@model` (sender: the model)."
const class_prepared = Signal("class_prepared")
