# Async entry points -------------------------------------------------------------------------------
#
# Julia views already run as tasks on a thread pool, so blocking ORM calls don't hold up the
# server. These are Django's async names for code that wants to start database work and wait
# for it later, or run several queries at once:
#
#     t1, t2 = acount(Post), afirst(filter(Comment; approved = false))
#     n, c = fetch(t1), fetch(t2)
#
#     function dashboard(req)                 # a view may return a Task: the handler waits for it
#         run_async() do
#             posts = fetch(acollect(order_by(Post, "-created")[1:5]))
#             render(req, "dashboard.html", Dict("posts" => posts))
#         end
#     end
#
# Each call returns a `Task` that runs on the default thread pool with the caller's database
# alias, language and time zone. Inside `atomic()` the work runs at once in the calling task
# instead (so it is part of the transaction) and the returned task is already finished.

struct AsyncFailure
    exception::Any
    backtrace::Any
end

"""
    run_async(f) -> Task

Run `f()` on the default thread pool as a `Task`, carrying over the caller's task-local
settings (database alias, active language and time zone). Inside a transaction it runs at
once in this task (so it sees, and is part of, the transaction).
"""
Base.@nospecializeinfer function run_async(@nospecialize(f))
    if in_atomic()
        r = try
            f()
        catch e
            AsyncFailure(e, catch_backtrace())
        end
        t = @task r isa AsyncFailure ? throw(r.exception) : r
        schedule(t)
        return t
    end
    tls = copy(task_local_storage())
    delete!(tls, :juango_db)                   # connections and transaction state stay with this task
    Threads.@spawn :default begin
        merge!(task_local_storage(), tls)
        f()
    end
end

"""
    sync_to_async(f) -> function returning a Task

Wrap a blocking function so calling it starts it with `run_async` and returns a `Task`.
"""
sync_to_async(f) = (args...; kw...) -> run_async(() -> f(args...; kw...))

"Wait for a task and return its value, rethrowing the task's own exception (not `TaskFailedException`)."
function await_task(t::Task)
    try
        Base.fetch(t)
    catch e
        e isa TaskFailedException ? throw(e.task.exception) : rethrow()
    end
end

for (a, f, doc) in ((:aget, :get, "get(qs_or_Model; lookups...)"),
                    (:acreate, :create, "create(Model; fields...)"),
                    (:acount, :count, "count(qs)"),
                    (:aexists, :exists, "exists(qs)"),
                    (:afirst, :first, "first(qs)"),
                    (:alast, :last, "last(qs)"),
                    (:acollect, :collect, "collect(qs): all the results"),
                    (:aget_or_create, :get_or_create, "get_or_create(Model; defaults, lookups...)"),
                    (:aupdate_or_create, :update_or_create, "update_or_create(Model; defaults, lookups...)"),
                    (:abulk_create, :bulk_create, "bulk_create(objects; ...)"),
                    (:abulk_update, :bulk_update, "bulk_update(objects, fields; ...)"),
                    (:aaggregate, :aggregate, "aggregate(qs; ...)"),
                    (:ain_bulk, :in_bulk, "in_bulk(qs, keys; ...)"),
                    (:aupdate!, :update!, "update!(qs; fields...)"),
                    (:adelete!, :delete!, "delete!(qs_or_object)"),
                    (:asave!, :save!, "save!(object)"),
                    (:arefresh!, :refresh!, "refresh!(object)"),
                    (:aauthenticate, :authenticate, "authenticate(username, password)"))
    @eval begin
        @doc $("    $a(...) -> Task\n\nAsync `$doc`: starts it with `run_async` and returns a `Task`; `fetch` it for the result.")
        $a(args...; kw...) = run_async(() -> $f(args...; kw...))
    end
end

"""
    aiterator(qs; chunk_size = 2000) -> Channel

Async iteration (Django's `async for`): a `Channel` filled by a background task with the
queryset's objects, fetched `chunk_size` at a time.

    for post in aiterator(objects(Post)) ... end
"""
function aiterator(qs::QuerySet; chunk_size::Integer = 2000)
    if in_atomic()                             # part of the transaction: fetched now, in this task
        ch = Channel{Any}(Inf)
        foreach(x -> put!(ch, x), iterator(qs; chunk_size = chunk_size))
        close(ch)
        return ch
    end
    tls = copy(task_local_storage())
    delete!(tls, :juango_db)
    Channel{Any}(chunk_size; spawn = true) do ch
        merge!(task_local_storage(), tls)
        for x in iterator(qs; chunk_size = chunk_size)
            put!(ch, x)
        end
    end
end
