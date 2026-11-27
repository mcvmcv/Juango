# Django's tasks tests, ported (#227): tests/tasks (test_tasks, test_immediate_backend, test_dummy_backend,
# test_custom_backend). Django's `@task` is Juango's `@background`, `Task.using` is `using_task`, `task.enqueue()` is
# `enqueue(task)`, `task.get_result(id)` is `get_result(task, id)` and `task_backends[alias]` is `task_backends(alias)`.
# julia --project=test test/django_tasks.jl   (see setup.jl)
#
# Not translated: the async tests (aenqueue, acall, aget_result, arefresh: Julia has no coroutine functions to tell
# apart), pickling (Julia has no pickle; a task is found by name), SystemExit (Julia's exit() ends the process),
# test_complex_exception (Python's exception-in-exception repr), the custom Task classes with extra fields
# (task_class; Julia structs can't be subclassed), test_name (a task's name is its registry key, Module.function).
# Django's stricter defaults are question #301: test_enqueue_with_invalid_argument, test_complex_return_value,
# test_naive_datetime and return_value raising before a task succeeds are @test_broken.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@background function dtk_noop(args...; kwargs...)
    nothing
end
@background function dtk_noop_other(args...; kwargs...)
    nothing
end
@background function dtk_meaning_of_life()
    42
end
@background function dtk_failing_value_error()
    throw(ArgumentError("This Task failed due to ValueError"))
end
@background function dtk_failing_interrupt()
    throw(InterruptException())
end
@background takes_context = true function dtk_get_task_id(context)
    context.task_result.id
end
@background takes_context = true function dtk_context(context, attempt)
    (context isa TaskContext && context.attempt == attempt) || error("wrong context")
end

"Log records from juango.tasks while `f()` runs, and `f()`'s value (Django's assertLogs)."
function dtk_logs(f)
    mem = Juango.MemoryHandler()
    v = override_settings(LOGGING = Dict("handlers" => Dict("mem" => Dict("class" => mem, "level" => "DEBUG")),
                                         "loggers" => Dict("juango.tasks" => Dict("handlers" => ["mem"], "level" => "DEBUG", "propagate" => false)))) do
        f()
    end
    mem.records, v
end
dtk_throws(f, T, msg = "") = try f(); false catch e; e isa T && occursin(msg, sprint(showerror, e)) end
const DTK_TASKS = Dict("default" => Dict("BACKEND" => "django.tasks.backends.dummy.DummyBackend", "QUEUES" => ["default", "queue_1"]),
                       "immediate" => Dict("BACKEND" => "django.tasks.backends.immediate.ImmediateBackend", "QUEUES" => String[]),
                       "missing" => Dict("BACKEND" => "does.not.exist"))
const DTK_IMMEDIATE = Dict("default" => Dict("BACKEND" => :immediate, "QUEUES" => String[]))
const DTK_DUMMY = Dict("default" => Dict("BACKEND" => :dummy, "QUEUES" => String[]))

"A backend of your own (Django's CustomBackend): it logs with its prefix option."
mutable struct DtkCustomBackend <: Juango.TaskBackend
    alias::String
    queues::Vector{String}
    options::Dict{String,Any}
end
DtkCustomBackend(alias, params::AbstractDict) = DtkCustomBackend(alias, Juango.backend_queues(params), Juango.backend_options(params))
Juango.enqueue(b::DtkCustomBackend, t::Juango.TaskDef, args::Vector{Any}, kwargs::Dict{String,Any}) =
    (Juango.log!("juango.tasks", :info, get(b.options, "prefix", "") * "Task enqueued."); nothing)
"One without enqueue (Django's CustomBackendNoEnqueue)."
mutable struct DtkCustomBackendNoEnqueue <: Juango.TaskBackend
    alias::String
    queues::Vector{String}
    options::Dict{String,Any}
end
DtkCustomBackendNoEnqueue(alias, params::AbstractDict) = DtkCustomBackendNoEnqueue(alias, String[], Dict{String,Any}())

@testset "django tasks: test_tasks (TaskTestCase)" begin
    override_settings(TASKS = DTK_TASKS, USE_TZ = true) do
        Juango.clear!(default_task_backend())
        @test default_task_backend() === task_backends("default")                         # test_using_correct_backend
        @test task_backends("default") isa Juango.DummyBackend
        @test dtk_noop isa TaskDef                                                         # test_task_decorator

        r = enqueue(dtk_noop)                                                              # test_enqueue_task
        @test r.status == TaskResultStatus.READY
        @test r.task == dtk_noop && r.args == [] && isempty(r.kwargs)
        @test default_task_backend().results == [r]
        @test_broken dtk_throws(() -> enqueue(dtk_noop, now()), Exception, "Unsupported type")   # test_enqueue_with_invalid_argument (#301)

        @test dtk_noop.priority == 0                                                       # test_using_priority
        @test using_task(dtk_noop; priority = 1).priority == 1 && dtk_noop.priority == 0
        @test dtk_noop.queue_name == DEFAULT_TASK_QUEUE_NAME                               # test_using_queue_name
        @test using_task(dtk_noop; queue_name = "queue_1").queue_name == "queue_1" && dtk_noop.queue_name == DEFAULT_TASK_QUEUE_NAME
        t = Juango.timezone_now()                                                          # test_using_run_after
        @test dtk_noop.run_after === nothing && using_task(dtk_noop; run_after = t).run_after == t && dtk_noop.run_after === nothing
        @test dtk_noop.backend == "default"                                                # test_using_unknown_backend
        @test dtk_throws(() -> using_task(dtk_noop; backend = "unknown"), InvalidTaskBackend, "The connection 'unknown' doesn't exist.")
        @test dtk_throws(() -> using_task(dtk_noop; backend = "missing"), InvalidTaskBackend, "Could not find backend 'does.not.exist'")  # test_using_missing_backend
        @test using_task(dtk_noop) == dtk_noop                                             # test_using_creates_new_instance
        rt = using_task(dtk_noop; run_after = t)                                           # test_chained_using
        pt = using_task(rt; priority = 10)
        @test rt.run_after == t && pt.priority == 10 && pt.run_after == t && rt.priority == 0
        r = enqueue(dtk_noop)                                                              # test_refresh_result
        @test Juango.refresh!(copy(r)) == r
        @test_broken dtk_throws(() -> using_task(dtk_noop; run_after = now()), InvalidTask, "run_after must be an aware datetime.")  # test_naive_datetime (#301)
        msg = "priority must be a whole number between $TASK_MIN_PRIORITY and $TASK_MAX_PRIORITY."  # test_invalid_priority
        for p in (-101, 101, 3.1)
            @test dtk_throws(() -> using_task(dtk_noop; priority = p), InvalidTask, msg)
        end
        @test all(p -> using_task(dtk_noop; priority = p).priority == p, (100, -100, 0))
        @test dtk_throws(() -> using_task(dtk_noop; queue_name = "queue-2"), InvalidTask, "Queue 'queue-2' is not valid for backend.")  # test_unknown_queue_name
        @test using_task(dtk_noop; queue_name = "queue-2", backend = "immediate").queue_name == "queue-2"   # (QUEUES = []: any)
        @test call_task(dtk_meaning_of_life) == 42                                         # test_call_task

        r = enqueue(default_task_backend(), dtk_noop, Any[], Dict{String,Any}())          # test_get_result
        @test get_result(dtk_noop, r.id) == r
        @test_throws TaskResultDoesNotExist get_result(dtk_noop, "123")                    # test_get_missing_result
        r = enqueue(default_task_backend(), dtk_noop_other, Any[], Dict{String,Any}())    # test_get_incorrect_result
        @test dtk_throws(() -> get_result(dtk_noop, r.id), TaskResultMismatch, "Task does not match")
        @test dtk_throws(() -> background(x -> x), InvalidTask, "Task function must be defined at a module level.")  # test_invalid_function
        @test dtk_noop.backend == "default" && Juango.get_backend(dtk_noop) isa Juango.DummyBackend  # test_get_backend
        it = using_task(dtk_noop; backend = "immediate")
        @test it.backend == "immediate" && Juango.get_backend(it) isa Juango.ImmediateBackend
        @test dtk_noop.module_path == "Main.dtk_noop"                                      # test_module_path (Juango's: Module.function)

        override_settings(TASKS = Dict()) do                                               # test_no_backends
            @test_throws InvalidTaskBackend enqueue(dtk_noop)
        end
        logs, r = dtk_logs(() -> enqueue(using_task(dtk_failing_value_error; backend = "immediate")))  # test_task_error_invalid_exception
        @test !isempty(logs) && length(r.errors) == 1
        @test exception_class(r.errors[1]) === ArgumentError
        @test dtk_throws(() -> exception_class(TaskError("Base.run", r.errors[1].traceback)), ArgumentError,
                         "\"Base.run\" does not reference a valid exception.")
        @test_throws ArgumentError exception_class(TaskError("does.not.exist", ""))       # test_task_error_unknown_module
        @test dtk_throws(() -> background(dtk_meaning_of_life.func; takes_context = true), InvalidTask,  # test_takes_context_without_taking_context
                         "Task takes context but does not have a first argument of 'context'.")
        @test dtk_throws(() -> background(dtk_meaning_of_life.func; run_after = now()), ArgumentError,   # test_run_after_in_decorator
                         "run_after cannot be defined statically with the @background decorator.")
    end
end

@testset "django tasks: test_immediate_backend" begin
    override_settings(TASKS = DTK_IMMEDIATE) do
        b = default_task_backend()                                                         # test_using_correct_backend
        @test b === task_backends("default") && b isa Juango.ImmediateBackend && b.alias == "default" && isempty(b.options)
        r = enqueue(dtk_noop, 1; two = 3)                                                  # test_enqueue_task
        @test r.status == TaskResultStatus.SUCCESSFUL && r.is_finished
        @test r.started_at !== nothing && r.last_attempted_at !== nothing && r.finished_at !== nothing
        @test r.started_at >= r.enqueued_at && r.finished_at >= r.started_at
        @test r.return_value === nothing && r.task == dtk_noop && r.args == [1] && r.kwargs == Dict("two" => 3) && r.attempts == 1

        logs, r = dtk_logs(() -> enqueue(dtk_failing_value_error))                        # test_catches_exception
        errs = [l for l in logs if l.level >= Juango.log_level(:error)]
        @test length(errs) == 1 && errs[1].exception !== nothing && occursin("This Task failed due to ValueError", sprint(showerror, errs[1].exception[1]))
        @test r.status == TaskResultStatus.FAILED && r.is_finished
        @test_broken dtk_throws(() -> r.return_value, Exception, "Task failed")            # (#301)
        @test r.started_at !== nothing && r.last_attempted_at !== nothing && r.finished_at !== nothing && r.finished_at >= r.started_at
        @test exception_class(r.errors[1]) === ArgumentError
        @test occursin("ArgumentError: This Task failed due to ValueError", r.errors[1].traceback)
        @test r.task == dtk_failing_value_error && r.args == [] && isempty(r.kwargs)

        logs, _ = dtk_logs(() -> @test_throws InterruptException enqueue(default_task_backend(), dtk_failing_interrupt, Any[], Dict{String,Any}()))  # test_throws_keyboard_interrupt
        @test !any(l -> l.level >= Juango.log_level(:error), logs)
        @test_broken false                                                                 # test_complex_return_value (#301)
        r = enqueue(default_task_backend(), dtk_meaning_of_life, Any[], Dict{String,Any}())  # test_result
        @test r.status == TaskResultStatus.SUCCESSFUL && r.return_value == 42
        @test dtk_throws(() -> get_result(default_task_backend(), "123"), ArgumentError,   # test_cannot_get_result
                         "This backend does not support retrieving or refreshing results.")
        @test dtk_throws(() -> Juango.refresh!(r), ArgumentError, "This backend does not support retrieving or refreshing results.")  # test_cannot_refresh_result
        @test dtk_throws(() -> validate_task(default_task_backend(), using_task(dtk_failing_value_error; run_after = Juango.timezone_now())),  # test_cannot_pass_run_after
                         InvalidTask, "Backend does not support run_after.")

        logs, r = dtk_logs(() -> enqueue(dtk_noop))                                        # test_enqueue_logs
        @test length(logs) == 3 && occursin("enqueued", logs[1].message) && all(l -> occursin(r.id, l.message), logs)
        @test occursin("state=RUNNING", logs[2].message) && occursin("state=SUCCESSFUL", logs[3].message)
        @test !any(l -> occursin("nothing", l.message), logs)                              # test_successful_task_no_none_in_logs
        logs, r = dtk_logs(() -> enqueue(dtk_failing_value_error))                        # test_failed_logs
        @test length(logs) == 3 && occursin("state=RUNNING", logs[2].message) && occursin("state=FAILED", logs[3].message) && occursin(r.id, logs[3].message)

        r = enqueue(dtk_get_task_id)                                                       # test_takes_context
        @test r.return_value == r.id
        @test enqueue(dtk_context, 1).status == TaskResultStatus.SUCCESSFUL               # test_context
        t = using_task(dtk_noop; queue_name = "unknown_queue")                             # test_validate_on_enqueue
        override_settings(TASKS = Dict("default" => Dict("BACKEND" => :immediate, "QUEUES" => ["queue-1"]))) do
            @test dtk_throws(() -> enqueue(t), InvalidTask, "Queue 'unknown_queue' is not valid for backend")
        end
    end
    # ImmediateBackendTransactionTestCase.test_doesnt_wait_until_transaction_commit_by_default
    override_settings(TASKS = Dict("default" => Dict("BACKEND" => :immediate))) do
        r = atomic() do
            r = enqueue(dtk_noop)
            @test r.enqueued_at !== nothing && r.status == TaskResultStatus.SUCCESSFUL
            r
        end
        @test r.status == TaskResultStatus.SUCCESSFUL
    end
end

@testset "django tasks: test_dummy_backend" begin
    override_settings(TASKS = DTK_DUMMY) do
        b = default_task_backend()
        Juango.clear!(b)
        @test b === task_backends("default") && b isa Juango.DummyBackend && b.alias == "default" && isempty(b.options)  # test_using_correct_backend
        r = enqueue(dtk_noop, 1; two = 3)                                                  # test_enqueue_task
        @test r.status == TaskResultStatus.READY && !r.is_finished
        @test r.started_at === nothing && r.last_attempted_at === nothing && r.finished_at === nothing
        @test_broken dtk_throws(() -> r.return_value, Exception, "Task has not finished yet")   # (#301)
        @test r.task == dtk_noop && r.args == [1] && r.kwargs == Dict("two" => 3) && r.attempts == 0 && r in b.results
        r = enqueue(b, dtk_noop, Any[], Dict{String,Any}())                               # test_get_result
        @test get_result(b, r.id) == r
        Juango.clear!(b)                                                                   # test_refresh_result
        r = enqueue(b, dtk_meaning_of_life, Any[], Dict{String,Any}())
        b.results[1].status = TaskResultStatus.SUCCESSFUL
        @test r.status == TaskResultStatus.READY
        Juango.refresh!(r)
        @test r.status == TaskResultStatus.SUCCESSFUL
        @test_throws TaskResultDoesNotExist get_result(b, "123")                           # test_get_missing_result
        logs, r = dtk_logs(() -> enqueue(dtk_noop))                                        # test_enqueue_logs
        @test length(logs) == 1 && occursin("enqueued", logs[1].message) && occursin(r.id, logs[1].message)
        @test isempty(enqueue(dtk_noop).errors)                                            # test_errors
        @test isempty(Juango.check_backend(b))                                             # test_check
        @test enqueue(dtk_get_task_id).status == TaskResultStatus.READY                    # test_takes_context
        r = enqueue(dtk_noop)                                                              # test_clear
        get_result(b, r.id)
        Juango.clear!(b)
        @test dtk_throws(() -> get_result(b, r.id), TaskResultDoesNotExist, r.id)
        t = using_task(dtk_noop; queue_name = "unknown_queue")                             # test_validate_on_enqueue
        override_settings(TASKS = Dict("default" => Dict("BACKEND" => :dummy, "QUEUES" => ["queue-1"]))) do
            @test dtk_throws(() -> enqueue(t), InvalidTask, "Queue 'unknown_queue' is not valid for backend")
        end
    end
    # DummyBackendTransactionTestCase.test_doesnt_wait_until_transaction_commit_by_default
    override_settings(TASKS = Dict("default" => Dict("BACKEND" => :dummy))) do
        Juango.clear!(default_task_backend())
        atomic() do
            r = enqueue(dtk_noop)
            @test r.enqueued_at !== nothing && length(default_task_backend().results) == 1
        end
        @test length(default_task_backend().results) == 1
        Juango.clear!(default_task_backend())
    end
end

@testset "django tasks: test_custom_backend (CustomBackendTestCase)" begin
    override_settings(TASKS = Dict("default" => Dict("BACKEND" => DtkCustomBackend, "OPTIONS" => Dict("prefix" => "PREFIX: ")),
                                   "no_enqueue" => Dict("BACKEND" => DtkCustomBackendNoEnqueue))) do
        b = default_task_backend()                                                         # test_using_correct_backend
        @test b === task_backends("default") && b isa DtkCustomBackend && b.alias == "default" && b.options == Dict("prefix" => "PREFIX: ")
        @test dtk_throws(() -> using_task(dtk_noop; priority = 10), InvalidTask,           # test_backend_does_not_support_priority
                         "Backend does not support setting priority of tasks.")
        logs, _ = dtk_logs(() -> enqueue(dtk_noop))                                        # test_options
        @test length(logs) == 1 && occursin("PREFIX: Task enqueued", logs[1].message)
        @test dtk_throws(() -> using_task(dtk_noop; backend = "no_enqueue"), ArgumentError,  # test_no_enqueue
                         "Can't instantiate abstract class DtkCustomBackendNoEnqueue without an implementation for abstract method 'enqueue'")
    end
end
