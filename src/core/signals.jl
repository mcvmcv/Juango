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
    key = something(dispatch_uid, objectid(receiver))
    lock(sig.lock) do
        any(r -> r[1] == key && r[3] === sender, sig.receivers) || push!(sig.receivers, (key, receiver, sender))
    end
    receiver
end

"""
    receiver(f, signal; sender=nothing)

Connect a do-block. It gets the sender and the signal's arguments as a NamedTuple:

    receiver(post_save; sender = Post) do sender, args
        args.created && notify(args.instance)
    end

Disconnect it with the `dispatch_uid` you give here.
"""
receiver(f, sig::Signal; sender = nothing, dispatch_uid = nothing) =
    connect!(sig, (s; kw...) -> f(s, (; kw...)); sender = sender, dispatch_uid = something(dispatch_uid, objectid(f)))

"Unsubscribe a receiver (or a `dispatch_uid`); returns whether one was removed."
function disconnect!(sig::Signal, receiver = nothing; sender = nothing, dispatch_uid = nothing)
    key = dispatch_uid === nothing ? objectid(receiver) : dispatch_uid
    lock(sig.lock) do
        n = length(sig.receivers)
        filter!(r -> !(r[1] == key && r[3] === sender), sig.receivers)
        length(sig.receivers) < n
    end
end

live_receivers(sig::Signal, sender) = lock(() -> [r[2] for r in sig.receivers if r[3] === nothing || r[3] === sender], sig.lock)
"Whether any receiver would get a signal from `sender` (lets callers skip expensive work)."
has_receivers(sig::Signal, sender) = !isempty(live_receivers(sig, sender))

"""
    send(signal, sender; kwargs...) -> Vector{Pair{receiver, result}}

Call every matching receiver. An exception in a receiver stops the sending and propagates;
`send_robust` collects exceptions as results instead.
"""
send(sig::Signal, sender; kw...) = [r => r(sender; signal = sig, kw...) for r in live_receivers(sig, sender)]
function send_robust(sig::Signal, sender; kw...)
    out = Pair{Any,Any}[]
    for r in live_receivers(sig, sender)
        push!(out, r => try
            r(sender; signal = sig, kw...)
        catch e
            e
        end)
    end
    out
end

"Before `save!` writes an object: `instance`, `created` (no id yet)."
const pre_save = Signal("pre_save")
"After `save!`: `instance`, `created`."
const post_save = Signal("post_save")
"Before an object is deleted (also for cascaded deletes): `instance`."
const pre_delete = Signal("pre_delete")
"After an object is deleted: `instance`."
const post_delete = Signal("post_delete")
"""
A many-to-many relation changed: sender is the join model; `action` is `:pre_add`,
`:post_add`, `:pre_remove`, `:post_remove`, `:pre_clear` or `:post_clear`; `instance`,
`model` (the other side), `pk_set`, `reverse`.
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
