# Background tasks ---------------------------------------------------------------------------------------
#
#     @background function send_welcome(user_id; greeting = "Hi")
#         u = get(User; id = user_id)
#         send_mail("Welcome", "$greeting $(u.username)", "site@example.com", [u.email])
#     end
#
#     r = enqueue(send_welcome, user.id; greeting = "Hello")     # a TaskResult
#     r.status        # :ready, :running, :successful or :failed
#
# TASKS picks the backend:  Dict("default" => Dict("backend" => :immediate))   (the default)
#   :immediate   runs the task at once, in the caller's task (for development and small sites)
#   :database    stores it in the juango_task table (add "juango.tasks" to INSTALLED_APPS) for
#                `manage.jl db_worker` (or `db_worker()`) to run; arguments must be JSON-friendly
#   :dummy       stores results without running anything (for tests: `dummy_results()`)
# Calling `send_welcome(...)` directly still just runs the function.

"A function that can be enqueued as a background task (made with `@background`)."
struct TaskDef
    f::Function
    name::String
    queue_name::String
    priority::Int
    backend::String
end
(t::TaskDef)(args...; kw...) = t.f(args...; kw...)
Base.show(io::IO, t::TaskDef) = print(io, "<TaskDef ", t.name, ">")

const TASK_REGISTRY = Dict{String,TaskDef}()

"""
    background(f; name, queue_name = "default", priority = 0, backend = "default") -> TaskDef
    @background function f(...) ... end

Make `f` a task: `enqueue(t, args...; kw...)` runs it through a TASKS backend. Tasks are
found by name, so give them stable names (the default is `Module.function`).
"""
function background(f::Function; name = nothing, queue_name = "default", priority = 0, backend = "default")
    n = something(name, string(parentmodule(f), ".", nameof(f)))
    TASK_REGISTRY[n] = TaskDef(f, n, string(queue_name), Int(priority), string(backend))
end

macro background(args...)
    fdef = args[end]
    opts = args[1:end-1]
    (fdef isa Expr && fdef.head in (:function, :(=))) || error("@background expects a function definition")
    call = fdef.args[1]
    while call isa Expr && call.head === :where
        call = call.args[1]
    end
    fname = call.args[1]
    impl = Symbol("__task_impl_", fname)
    newdef = copy(fdef)
    newcall = copy(fdef.args[1])
    c = newcall
    while c isa Expr && c.head === :where
        c = c.args[1]
    end
    c.args[1] = impl
    newdef.args[1] = newcall
    kws = [Expr(:kw, o.args[1], esc(o.args[2])) for o in opts]
    quote
        $(esc(newdef))
        const $(esc(fname)) = $(GlobalRef(@__MODULE__, :background))($(esc(impl)); name = $(string(__module__, ".", fname)), $(kws...))
    end
end

"The outcome of an enqueued task."
mutable struct TaskResult
    id::String
    task::String
    args::Vector{Any}
    kwargs::Dict{String,Any}
    queue_name::String
    priority::Int
    backend::String
    status::Symbol                 # :ready, :running, :successful, :failed
    enqueued_at::DateTime
    run_after::Union{Nothing,DateTime}
    started_at::Union{Nothing,DateTime}
    finished_at::Union{Nothing,DateTime}
    return_value::Any
    error::String
end
Base.show(io::IO, r::TaskResult) = print(io, "<TaskResult ", r.task, " ", r.status, ">")

task_backend_conf(alias) = (d = get(settings, :TASKS, Dict("default" => Dict("backend" => :immediate)));
    haskey(d, alias) ? d[alias] : throw(ImproperlyConfigured("no task backend '$alias' in TASKS")))
task_backend_kind(alias) = Symbol(get(task_backend_conf(alias), "backend", :immediate))

"Run a task now and record the outcome in `r`."
function run_task!(r::TaskResult)
    t = get(TASK_REGISTRY, r.task, nothing)
    r.started_at = now(); r.status = :running
    try
        t === nothing && error("no task named '$(r.task)' is defined in this process")
        r.return_value = Base.invokelatest(t.f, r.args...; (Symbol(k) => v for (k, v) in r.kwargs)...)
        r.status = :successful
    catch e
        r.status = :failed
        r.error = sprint(showerror, e, catch_backtrace())
        log!("juango.tasks", :error, "Task $(r.task) failed"; exception = (e, catch_backtrace()), task = r.task)
    end
    r.finished_at = now()
    r
end

const DUMMY_RESULTS = TaskResult[]
"Results stored by the `:dummy` backend (newest last); `empty!` it between tests."
dummy_results() = DUMMY_RESULTS

"""
    enqueue(task, args...; run_after = nothing, priority = nothing, queue_name = nothing, kw...) -> TaskResult

Hand a task to its backend. `run_after` (a DateTime) delays it (database backend);
`priority` (higher first) and `queue_name` override the task's own.
"""
function enqueue(t::TaskDef, args...; run_after = nothing, priority = nothing, queue_name = nothing, kw...)
    r = TaskResult(string(uuid4()), t.name, collect(Any, args), Dict{String,Any}(string(k) => v for (k, v) in kw),
                   something(queue_name, t.queue_name), something(priority, t.priority), t.backend, :ready, now(),
                   run_after, nothing, nothing, nothing, "")
    conf = task_backend_conf(t.backend)
    queues = get(conf, "queues", nothing)
    queues === nothing || r.queue_name in queues || throw(ArgumentError("queue '$(r.queue_name)' isn't one of the backend's queues"))
    kind = task_backend_kind(t.backend)
    if kind === :immediate
        run_after === nothing || throw(ArgumentError("the immediate backend can't delay tasks (run_after)"))
        run_task!(r)
    elseif kind === :dummy
        push!(DUMMY_RESULTS, r)
    elseif kind === :database
        require_app("tasks", "the database task backend")
        rec = save!(TaskRecord(; task_id = r.id, task_name = r.task, args = JSON.json(r.args), kwargs = JSON.json(r.kwargs),
                               queue_name = r.queue_name, priority = r.priority, status = "ready",
                               enqueued_at = timezone_now(), run_after = run_after === nothing ? nothing :
                                   (settings.USE_TZ && run_after isa DateTime ? make_aware(run_after) : run_after), backend = r.backend))
    else
        throw(ImproperlyConfigured("unknown task backend $(kind) (have :immediate, :database, :dummy)"))
    end
    r
end

# --- the database backend ----------------------------------------------------------------------------

@model struct TaskRecord
    task_id = CharField(max_length = 36, unique = true)
    task_name = CharField(max_length = 255)
    args = TextField(blank = true)
    kwargs = TextField(blank = true)
    queue_name = CharField(max_length = 100, default = "default", db_index = true)
    backend = CharField(max_length = 100, default = "default")
    priority = IntegerField(default = 0)
    status = CharField(max_length = 10, default = "ready", db_index = true)
    enqueued_at = DateTimeField()
    run_after = DateTimeField(null = true, blank = true)
    started_at = DateTimeField(null = true, blank = true)
    finished_at = DateTimeField(null = true, blank = true)
    return_value = TextField(blank = true)
    error = TextField(blank = true)
    Meta(table = "juango_task", app_label = "tasks", ordering = ["-priority", "enqueued_at"], verbose_name = "task result")
end
Base.show(io::IO, t::TaskRecord) = print(io, t.task_name, " (", t.status, ")")

naive(d) = d isa TimeZones.ZonedDateTime ? make_naive(d) : d
function record_result(rec::TaskRecord)
    ret = isempty(rec.return_value) ? nothing : JSON.parse(rec.return_value)
    TaskResult(rec.task_id, rec.task_name, collect(Any, JSON.parse(rec.args)), Dict{String,Any}(JSON.parse(rec.kwargs)),
               rec.queue_name, rec.priority, rec.backend, Symbol(rec.status), naive(rec.enqueued_at), naive(rec.run_after),
               naive(rec.started_at), naive(rec.finished_at), ret, rec.error)
end

"""
    get_result(id) -> TaskResult

The current state of a task stored by the database backend.
"""
get_result(id::AbstractString) = (require_app("tasks", "get_result"); record_result(get(TaskRecord; task_id = id)))
"Reload a task result's state (database backend)."
refresh!(r::TaskResult) = task_backend_kind(r.backend) === :database ? (n = get_result(r.id); foreach(f -> setfield!(r, f, getfield(n, f)), fieldnames(TaskResult)); r) : r

"Claim the next ready task (highest priority, oldest first) for this worker, or `nothing`."
function claim_task(queues)
    atomic() do
        qs = filter(TaskRecord; status = "ready")
        queues === nothing || (qs = filter(qs; queue_name__in = collect(queues)))
        qs = filter(qs, Q(run_after__isnull = true) | Q(run_after__lte = timezone_now()))
        qs = order_by(qs, "-priority", "enqueued_at", "id")
        b = backend()
        rec = first(b isa SQLiteBackend ? qs : select_for_update(qs; skip_locked = true))
        rec === nothing && return nothing
        rec.status = "running"; rec.started_at = timezone_now()
        save!(rec)
        rec
    end
end

"""
    db_worker(; queues = nothing, max_tasks = nothing, sleep_seconds = 1.0, stop_when_empty = false) -> Int

Run tasks from the database backend: claim the next ready one (several workers can run at
once on PostgreSQL and MySQL), run it, store the result, repeat. Returns how many ran.
"""
function db_worker(; queues = nothing, max_tasks = nothing, sleep_seconds = 1.0, stop_when_empty = false)
    n = 0
    while max_tasks === nothing || n < max_tasks
        rec = claim_task(queues)
        if rec === nothing
            stop_when_empty && break
            sleep(sleep_seconds)
            continue
        end
        r = run_task!(record_result(rec))
        rec.status = string(r.status)
        rec.finished_at = timezone_now()
        rec.return_value = r.status === :successful ? (try JSON.json(r.return_value) catch; JSON.json(string(r.return_value)) end) : ""
        rec.error = r.error
        save!(rec)
        n += 1
    end
    n
end

const TASKS_APP = App("tasks"; name = "juango.tasks", verbose_name = "Tasks", ready = function ()
    is_installed("admin") && !Admin.is_registered(TaskRecord) &&
        Admin.register!(TaskRecord; list_display = [:task_name, :status, :queue_name, :priority, :enqueued_at, :finished_at],
                        list_filter = [:status, :queue_name], search_fields = [:task_name, :task_id])
end)
