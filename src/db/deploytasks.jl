# Deploy tasks: one-off jobs that run once per database, after migrate ------------------------------
#
#     deploy_task!("0001_fill_species"; app = "lab") do
#         isfile(SPECIES_CSV) || return deploy_waiting("species.csv isn't on this server yet")
#         import_species(SPECIES_CSV)
#     end
#
# `manage.jl deploy` runs the ones not run yet on this database, in the order they were
# declared, and records each in `juango_deploy_tasks` like a migration, so it never runs twice.
# A task that returns `deploy_waiting(reason)` is reported and tried again next time; one that throws
# stops the run (its transaction rolls back) and isn't recorded. Never rename a task once it
# has run anywhere: the name is how it's remembered.

struct DeployTask
    app::String
    name::String
    f::Function
    atomic::Bool
end
"Deploy tasks in the order they were declared."
const DEPLOY_TASKS = DeployTask[]

"""
    deploy_task!(f, name; app = "project", atomic = true)

Declare a deploy task: `f()` runs once per database, the first time `manage.jl deploy` runs
after it's declared (in a transaction unless `atomic = false`). Return `deploy_waiting("reason")` to be
skipped and tried again next time (a file not uploaded yet, say). See `run_deploy_tasks`.
"""
function deploy_task!(f, name::AbstractString; app::AbstractString = "project", atomic::Bool = true)
    any(t -> t.app == app && t.name == name, DEPLOY_TASKS) && throw(ArgumentError("deploy task $app.$name is declared twice"))
    push!(DEPLOY_TASKS, DeployTask(String(app), String(name), f, atomic))
    nothing
end

struct DeployWaiting
    reason::String
end
"What a deploy task returns when it can't run yet: it's reported, not recorded, and tried again next time."
deploy_waiting(reason::AbstractString) = DeployWaiting(String(reason))

const DEPLOY_RECORDER = Table("juango_deploy_tasks", "juango", "DeployTaskRecord",
                              [Column("app", :string; max_length = 100), Column("name", :string; max_length = 255),
                               Column("applied", :datetime)])
function ensure_deploy_recorder!()
    b = backend()
    table_exists(b, DEPLOY_RECORDER.name) || foreach(execute, first(create_table_sql(b, DEPLOY_RECORDER)))
end
"The deploy tasks run on this database, as (app, name) pairs."
function applied_deploy_tasks()
    ensure_deploy_recorder!()
    Set((String(r[:app]), String(r[:name])) for r in execute("SELECT \"app\", \"name\" FROM \"juango_deploy_tasks\""))
end

"""
    run_deploy_tasks(; plan = false, fake = false, log = println) -> NamedTuple

Run the deploy tasks this database hasn't run, in order: `(ran, waiting, skipped)` names.
`plan = true` only lists them; `fake = true` records them without running them (for a database
where the work was done by hand).
"""
function run_deploy_tasks(; plan::Bool = false, fake::Bool = false, log = println)
    done = applied_deploy_tasks()
    pending = [t for t in DEPLOY_TASKS if !((t.app, t.name) in done)]
    ran, waits = String[], String[]
    isempty(pending) && (log("No deploy tasks to run."); return (ran = ran, waiting = waits))
    for t in pending
        label = t.app * "." * t.name
        if plan
            log("  ", label)
            continue
        end
        record() = execute("INSERT INTO \"juango_deploy_tasks\" (\"app\", \"name\", \"applied\") VALUES (?, ?, ?)", Any[t.app, t.name, now()])
        if fake
            record(); push!(ran, label); log("  Faked ", label)
            continue
        end
        result = nothing
        body() = (result = t.f(); result isa DeployWaiting || record())
        t.atomic ? atomic(body) : body()
        if result isa DeployWaiting
            push!(waits, label); log("  Waiting ", label, ": ", result.reason)
        else
            push!(ran, label); log("  Ran ", label)
        end
    end
    (ran = ran, waiting = waits)
end
