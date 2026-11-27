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

# Django 6's django.tasks: a task (`TaskDef`, from `@background`) is enqueued on one of the TASKS
# backends, each an object (`task_backends("default")`) that validates the task (`validate_task`), runs or
# stores it, and (the database backend) gives results back by id. `using_task(t; priority, queue_name,
# run_after, backend)` is Django's `Task.using`.

const DEFAULT_TASK_BACKEND_ALIAS = "default"
const DEFAULT_TASK_PRIORITY = 0
const DEFAULT_TASK_QUEUE_NAME = "default"
const TASK_MAX_PRIORITY = 100
const TASK_MIN_PRIORITY = -100
"A task result's status, as Django's TaskResultStatus (`r.status == TaskResultStatus.SUCCESSFUL`)."
const TaskResultStatus = (READY = :ready, RUNNING = :running, FAILED = :failed, SUCCESSFUL = :successful)

"The task is invalid for its backend (a priority it can't honour, an unknown queue, ...)."
struct InvalidTask <: Exception
    msg::String
end
"TASKS names no such backend, or one that can't be made."
struct InvalidTaskBackend <: Exception
    msg::String
end
"No task result has that id."
struct TaskResultDoesNotExist <: Exception
    msg::String
end
"The task result belongs to another task."
struct TaskResultMismatch <: Exception
    msg::String
end
for E in (:InvalidTask, :InvalidTaskBackend, :TaskResultDoesNotExist, :TaskResultMismatch)
    @eval Base.showerror(io::IO, e::$E) = print(io, $(string(E)), ": ", e.msg)
end

"A function that can be enqueued as a background task (made with `@background`)."
struct TaskDef
    f::Function
    name::String                     # the registry key, Module.function (Django's module_path)
    queue_name::String
    priority::Int
    backend::String
    takes_context::Bool              # the function's first argument is a TaskContext (`context`)
    run_after::Any                   # nothing, or the earliest time it may run (using_task)
end
TaskDef(f, name, queue_name, priority, backend) = TaskDef(f, name, queue_name, priority, backend, false, nothing)
(t::TaskDef)(args...; kw...) = t.f(args...; kw...)
Base.show(io::IO, t::TaskDef) = print(io, "<TaskDef ", t.name, ">")
function Base.getproperty(t::TaskDef, s::Symbol)
    s === :module_path && return getfield(t, :name)
    s === :func && return getfield(t, :f)
    getfield(t, s)
end

const TASK_REGISTRY = Dict{String,TaskDef}()

"A function defined at the top of a module (not a closure, not anonymous): workers find tasks by name."
function module_level_function(f)
    f isa Function || return false
    n = nameof(f)
    !occursin('#', string(n)) && isdefined(parentmodule(f), n) && getfield(parentmodule(f), n) === f
end
first_argname(f) = (ms = methods(f); isempty(ms) ? nothing : (a = Base.method_argnames(first(ms)); length(a) >= 2 ? a[2] : nothing))
function check_priority(p)
    (p isa Real && isinteger(p) && TASK_MIN_PRIORITY <= p <= TASK_MAX_PRIORITY) ||
        throw(InvalidTask("priority must be a whole number between $TASK_MIN_PRIORITY and $TASK_MAX_PRIORITY."))
    Int(p)
end

"""
    background(f; name, queue_name = "default", priority = 0, backend = "default", takes_context = false) -> TaskDef
    @background function f(...) ... end

Make `f` a task: `enqueue(t, args...; kw...)` runs it through a TASKS backend. Tasks are
found by name, so give them stable names (the default is `Module.function`). With
`takes_context = true` the function's first argument (named `context`) is a `TaskContext`:
`context.task_result`, `context.attempt`. (`run_after` isn't a task's own: set it with `using_task`.)
"""
function background(f::Function; name = nothing, queue_name = DEFAULT_TASK_QUEUE_NAME, priority = DEFAULT_TASK_PRIORITY,
                    backend = DEFAULT_TASK_BACKEND_ALIAS, takes_context = false, kw...)
    haskey(kw, :run_after) && throw(ArgumentError("run_after cannot be defined statically with the @background decorator. " *
                                                  "Use using_task(task; run_after = ...) to set it dynamically."))
    isempty(kw) || throw(ArgumentError("background got an unexpected keyword argument '$(first(keys(kw)))'"))
    n = something(name, string(parentmodule(f), ".", nameof(f)))
    t = TaskDef(f, n, string(queue_name), check_priority(priority), string(backend), Bool(takes_context), nothing)
    validate_function(t)
    TASK_REGISTRY[n] = t
end
function validate_function(t::TaskDef)
    module_level_function(t.f) || throw(InvalidTask("Task function must be defined at a module level."))
    t.takes_context && first_argname(t.f) !== :context &&
        throw(InvalidTask("Task takes context but does not have a first argument of 'context'."))
    nothing
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

"""
    using_task(t; priority, queue_name, run_after, backend) -> TaskDef

A copy of the task with other defaults (Django's `Task.using`), checked against its backend.
"""
function using_task(t::TaskDef; priority = nothing, queue_name = nothing, run_after = nothing, backend = nothing)
    p = priority === nothing ? t.priority : check_priority(priority)
    n = TaskDef(t.f, t.name, something(queue_name === nothing ? nothing : string(queue_name), t.queue_name), p,
                something(backend === nothing ? nothing : string(backend), t.backend), t.takes_context,
                run_after === nothing ? t.run_after : run_after)
    validate_task(get_backend(n), n)
    n
end
"The backend a task is enqueued on."
get_backend(t::TaskDef) = task_backends(t.backend)
"Run the task's function now, in this task (Django's `Task.call`)."
call_task(t::TaskDef, args...; kw...) = t.f(args...; kw...)

"A failure of a task: the exception's type (by name) and its traceback."
struct TaskError
    exception_class_path::String
    traceback::String
end
"""
    exception_class(e::TaskError) -> Type

The exception type a failed task raised, found by its name.
"""
function exception_class(e::TaskError)
    path = e.exception_class_path
    v = Main
    for part in split(path, '.')
        (v isa Module && isdefined(v, Symbol(part))) || throw(ArgumentError("Could not import '$path'."))
        v = getfield(v, Symbol(part))
    end
    v isa Type && v <: Exception || throw(ArgumentError("$(repr(path)) does not reference a valid exception."))
    v
end
exception_path(T::Type) = string(parentmodule(T), ".", nameof(T))

"The outcome of an enqueued task."
mutable struct TaskResult
    id::String
    task::TaskDef
    args::Vector{Any}
    kwargs::Dict{String,Any}
    queue_name::String
    priority::Int
    backend::String
    status::Symbol                 # TaskResultStatus: :ready, :running, :successful, :failed
    enqueued_at::Any
    run_after::Any
    started_at::Any
    finished_at::Any
    last_attempted_at::Any
    return_value::Any
    error::String                  # the last error's traceback ("" if none)
    errors::Vector{TaskError}
    worker_ids::Vector{String}     # the workers that ran it, one per attempt
end
Base.show(io::IO, r::TaskResult) = print(io, "<TaskResult ", r.task.name, " ", r.status, ">")
# (equal when every field is, as Django's dataclass)
Base.:(==)(a::TaskResult, b::TaskResult) = all(f -> isequal(getfield(a, f), getfield(b, f)), fieldnames(TaskResult))
Base.copy(r::TaskResult) = TaskResult((f === :args || f === :kwargs || f === :errors || f === :worker_ids ? copy(getfield(r, f)) : getfield(r, f)
                                      for f in fieldnames(TaskResult))...)
function Base.getproperty(r::TaskResult, s::Symbol)
    s === :is_finished && return getfield(r, :status) in (:failed, :successful)
    s === :attempts && return length(getfield(r, :worker_ids))
    getfield(r, s)
end
new_result(t::TaskDef, args, kwargs, b) =
    TaskResult(random_string(32), t, collect(Any, args), Dict{String,Any}(string(k) => v for (k, v) in kwargs), t.queue_name,
               t.priority, backend_alias(b), :ready, nothing, t.run_after, nothing, nothing, nothing, nothing, "", TaskError[], String[])

"What a task with `takes_context = true` gets first: its result (`context.task_result`) and `context.attempt`."
struct TaskContext
    task_result::TaskResult
end
Base.getproperty(c::TaskContext, s::Symbol) = s === :attempt ? getfield(c, :task_result).attempts : getfield(c, s)

# signals, as Django's (sender: the backend's type; keyword task_result)
"Sent when a task is enqueued."
const task_enqueued = Signal("task_enqueued")
"Sent when a task starts running."
const task_started = Signal("task_started")
"Sent when a task has finished (successfully or not)."
const task_finished = Signal("task_finished")

# --- backends -------------------------------------------------------------------------------------

"""
A TASKS backend. Juango's are `ImmediateBackend` (runs the task at once), `DummyBackend` (stores
it, for tests) and `DatabaseTaskBackend` (for `db_worker`). Your own is a subtype `B` with fields
`alias`, `queues` and `options`, a constructor `B(alias, params::AbstractDict)` and
`enqueue(b::B, task, args, kwargs) -> TaskResult`; `TASKS = Dict("default" => Dict("BACKEND" => B))`.
Its `supports_priority(b)`, `supports_defer(b)` and `supports_get_result(b)` are false unless
defined, and `get_result(b, id)` gives results back.
"""
abstract type TaskBackend end
backend_alias(b::TaskBackend) = b.alias
supports_defer(::TaskBackend) = false
supports_priority(::TaskBackend) = false
supports_get_result(::TaskBackend) = false
get_result(::TaskBackend, id) = throw(ArgumentError("This backend does not support retrieving or refreshing results."))
check_backend(::TaskBackend) = CheckMessage[]

"Runs each task at once, in the caller's task (the default)."
mutable struct ImmediateBackend <: TaskBackend
    alias::String
    queues::Vector{String}
    options::Dict{String,Any}
    worker_id::String
end
ImmediateBackend(alias, params::AbstractDict) = ImmediateBackend(alias, backend_queues(params), backend_options(params), random_string(32))
"Stores tasks without running them (`dummy_results()`), for tests."
mutable struct DummyBackend <: TaskBackend
    alias::String
    queues::Vector{String}
    options::Dict{String,Any}
end
DummyBackend(alias, params::AbstractDict) = DummyBackend(alias, backend_queues(params), backend_options(params))
"Stores tasks in the juango_task table for `db_worker` (add \"juango.tasks\" to INSTALLED_APPS)."
mutable struct DatabaseTaskBackend <: TaskBackend
    alias::String
    queues::Vector{String}
    options::Dict{String,Any}
end
DatabaseTaskBackend(alias, params::AbstractDict) = DatabaseTaskBackend(alias, backend_queues(params), backend_options(params))
supports_priority(::Union{ImmediateBackend,DummyBackend,DatabaseTaskBackend}) = true
supports_defer(::Union{DummyBackend,DatabaseTaskBackend}) = true
supports_get_result(::DatabaseTaskBackend) = true

task_param(params, k) = get(params, uppercase(k), get(params, lowercase(k), nothing))
# (no QUEUES: any queue, as Juango has always taken; Django's default is ["default"])
backend_queues(params) = (q = task_param(params, "queues"); q === nothing ? String[] : String[string(x) for x in q])
backend_options(params) = (o = task_param(params, "options"); o === nothing ? Dict{String,Any}() : Dict{String,Any}(string(k) => v for (k, v) in o))

const BACKEND_NAMES = Dict{String,Any}("immediate" => ImmediateBackend, "dummy" => DummyBackend, "database" => DatabaseTaskBackend,
                                       "django.tasks.backends.immediate.ImmediateBackend" => ImmediateBackend,
                                       "django.tasks.backends.dummy.DummyBackend" => DummyBackend)
function make_backend(alias, params)
    spec = something(task_param(params, "backend"), :immediate)
    B = spec isa Type ? spec : get(BACKEND_NAMES, string(spec), nothing)
    B === nothing && throw(InvalidTaskBackend("Could not find backend '$spec': have :immediate, :dummy, :database or a TaskBackend type"))
    B <: TaskBackend || throw(InvalidTaskBackend("Could not find backend '$spec': $B isn't a TaskBackend"))
    hasmethod(enqueue, Tuple{B,TaskDef,Vector{Any},Dict{String,Any}}) ||
        throw(ArgumentError("Can't instantiate abstract class $(nameof(B)) without an implementation for abstract method 'enqueue'"))
    B(string(alias), params)
end

const BACKEND_CACHE = Dict{String,Tuple{Any,TaskBackend}}()     # alias => (the TASKS entry it was made from, backend)
"""
    task_backends(alias = "default") -> TaskBackend

The backend TASKS names `alias` (made once per TASKS setting, as Django's `task_backends[alias]`).
"""
function task_backends(alias = DEFAULT_TASK_BACKEND_ALIAS)
    alias = string(alias)
    tasks = get(settings, :TASKS, Dict("default" => Dict("backend" => :immediate)))
    haskey(tasks, alias) || throw(InvalidTaskBackend("The connection '$alias' doesn't exist."))
    params = tasks[alias]
    c = get(BACKEND_CACHE, alias, nothing)
    c !== nothing && c[1] === params && return c[2]
    b = make_backend(alias, params)
    BACKEND_CACHE[alias] = (params, b)
    b
end
"The default backend (Django's `default_task_backend`)."
default_task_backend() = task_backends(DEFAULT_TASK_BACKEND_ALIAS)
task_backend_kind(alias) = (b = task_backends(alias); b isa ImmediateBackend ? :immediate : b isa DummyBackend ? :dummy : b isa DatabaseTaskBackend ? :database : :custom)

"""
    validate_task(backend, task)

Throw `InvalidTask` if the backend can't run the task as it is: its priority, `run_after` or queue.
"""
function validate_task(b::TaskBackend, t::TaskDef)
    validate_function(t)
    supports_priority(b) || t.priority == DEFAULT_TASK_PRIORITY || throw(InvalidTask("Backend does not support setting priority of tasks."))
    check_priority(t.priority)
    supports_defer(b) || t.run_after === nothing || throw(InvalidTask("Backend does not support run_after."))
    # (a naive run_after with USE_TZ is taken as local time, where Django refuses it: #301)
    isempty(b.queues) || t.queue_name in b.queues || throw(InvalidTask("Queue '$(t.queue_name)' is not valid for backend."))
    nothing
end

function mark_enqueued!(b::TaskBackend, r::TaskResult)
    r.enqueued_at = timezone_now()
    log!("juango.tasks", :debug, "Task id=$(r.id) path=$(r.task.module_path) enqueued backend=$(r.backend)")
    send(task_enqueued, typeof(b); task_result = r)
    r
end

"Run a task now and record the outcome in `r` (`worker`: the id of who runs it)."
function run_task!(r::TaskResult, worker = "")
    t = r.task
    r.started_at = r.last_attempted_at = timezone_now(); r.status = :running
    push!(r.worker_ids, worker)
    log!("juango.tasks", :info, "Task id=$(r.id) path=$(t.module_path) state=RUNNING")
    send(task_started, Nothing; task_result = r)
    try
        kw = (Symbol(k) => v for (k, v) in r.kwargs)
        r.return_value = t.takes_context ? Base.invokelatest(t.f, TaskContext(r), r.args...; kw...) :
                                           Base.invokelatest(t.f, r.args...; kw...)
        r.status = :successful
        r.finished_at = timezone_now()
        log!("juango.tasks", :info, "Task id=$(r.id) path=$(t.module_path) state=SUCCESSFUL")
    catch e
        e isa InterruptException && rethrow()
        bt = catch_backtrace()
        r.status = :failed
        r.finished_at = timezone_now()
        r.error = sprint(showerror, e, bt)
        push!(r.errors, TaskError(exception_path(typeof(e)), r.error))
        log!("juango.tasks", :error, "Task id=$(r.id) path=$(t.module_path) state=FAILED"; exception = (e, bt), task = t.name)
    end
    send(task_finished, Nothing; task_result = r)
    r
end

function enqueue(b::ImmediateBackend, t::TaskDef, args::Vector{Any}, kwargs::Dict{String,Any})
    validate_task(b, t)
    r = mark_enqueued!(b, new_result(t, args, kwargs, b))
    run_task!(r, b.worker_id)
end

const DUMMY_RESULTS = TaskResult[]
"Results stored by the `:dummy` backend (newest last); `empty!` it between tests."
dummy_results() = DUMMY_RESULTS
Base.getproperty(b::DummyBackend, s::Symbol) = s === :results ? DUMMY_RESULTS : getfield(b, s)
"Forget the dummy backend's results."
clear!(::DummyBackend) = empty!(DUMMY_RESULTS)
function enqueue(b::DummyBackend, t::TaskDef, args::Vector{Any}, kwargs::Dict{String,Any})
    validate_task(b, t)
    r = new_result(t, args, kwargs, b)
    push!(DUMMY_RESULTS, r)
    mark_enqueued!(b, r)
    copy(r)                    # (the stored result changes only through the backend, as Django's)
end
function get_result(::DummyBackend, id)
    i = findfirst(r -> r.id == id, DUMMY_RESULTS)
    i === nothing ? throw(TaskResultDoesNotExist(string(id))) : DUMMY_RESULTS[i]
end

function enqueue(b::DatabaseTaskBackend, t::TaskDef, args::Vector{Any}, kwargs::Dict{String,Any})
    validate_task(b, t)
    require_app("tasks", "the database task backend")
    r = new_result(t, args, kwargs, b)
    ra = t.run_after
    save!(TaskRecord(; task_id = r.id, task_name = t.name, args = JSON.json(r.args), kwargs = JSON.json(r.kwargs),
                     queue_name = r.queue_name, priority = r.priority, status = "ready", enqueued_at = timezone_now(),
                     run_after = ra === nothing ? nothing : (settings.USE_TZ && ra isa DateTime ? make_aware(ra) : ra), backend = r.backend))
    mark_enqueued!(b, r)
end
function get_result(::DatabaseTaskBackend, id)
    require_app("tasks", "get_result")
    rec = first(filter(TaskRecord; task_id = string(id)))
    rec === nothing && throw(TaskResultDoesNotExist(string(id)))
    record_result(rec)
end

"""
    enqueue(task, args...; run_after = nothing, priority = nothing, queue_name = nothing, kw...) -> TaskResult

Hand a task to its backend. `run_after` (a DateTime) delays it (database backend);
`priority` (higher first) and `queue_name` override the task's own (as `using_task`).
"""
function enqueue(t::TaskDef, args...; run_after = nothing, priority = nothing, queue_name = nothing, kw...)
    (run_after === nothing && priority === nothing && queue_name === nothing) ||
        (t = TaskDef(t.f, t.name, something(queue_name === nothing ? nothing : string(queue_name), t.queue_name),
                     priority === nothing ? t.priority : check_priority(priority), t.backend, t.takes_context,
                     something(run_after, Some(t.run_after))))
    enqueue(get_backend(t), t, collect(Any, args), Dict{String,Any}(string(k) => v for (k, v) in kw))
end

"""
    get_result(task, id) -> TaskResult

The task's result with that id, from its backend (`TaskResultMismatch` if it's another task's).
"""
function get_result(t::TaskDef, id)
    r = get_result(get_backend(t), id)
    r.task.f === t.f || throw(TaskResultMismatch("Task does not match (received $(repr(r.task.module_path)))"))
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
# a task the record names that isn't defined in this process: running it fails with that
missing_task(name) = TaskDef((args...; kw...) -> error("no task named '$name' is defined in this process"), name,
                             DEFAULT_TASK_QUEUE_NAME, 0, DEFAULT_TASK_BACKEND_ALIAS, false, nothing)
function record_result(rec::TaskRecord)
    ret = isempty(rec.return_value) ? nothing : JSON.parse(rec.return_value)
    t = get(() -> missing_task(rec.task_name), TASK_REGISTRY, rec.task_name)
    started = naive(rec.started_at)
    TaskResult(rec.task_id, t, collect(Any, JSON.parse(rec.args)), Dict{String,Any}(JSON.parse(rec.kwargs)),
               rec.queue_name, rec.priority, rec.backend, Symbol(rec.status), naive(rec.enqueued_at), naive(rec.run_after),
               started, naive(rec.finished_at), started, ret, rec.error,
               isempty(rec.error) ? TaskError[] : [TaskError("", rec.error)], started === nothing ? String[] : ["db_worker"])
end

"""
    get_result(id) -> TaskResult

The current state of a task stored by the database backend.
"""
get_result(id::AbstractString) = get_result(DatabaseTaskBackend("", Dict()), id)
"""
    refresh!(r::TaskResult) -> r

Reload a task result's state from its backend (Django's `TaskResult.refresh`); the immediate
backend keeps no results to reload from.
"""
function refresh!(r::TaskResult)
    n = get_result(task_backends(r.backend), r.id)
    n === r && return r
    for f in (:errors, :return_value, :error, :finished_at, :started_at, :last_attempted_at, :status, :enqueued_at, :worker_ids)
        setfield!(r, f, getfield(n, f))
    end
    r
end

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
    worker = random_string(32)
    while max_tasks === nothing || n < max_tasks
        rec = claim_task(queues)
        if rec === nothing
            stop_when_empty && break
            sleep(sleep_seconds)
            continue
        end
        r = run_task!(record_result(rec), worker)
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
