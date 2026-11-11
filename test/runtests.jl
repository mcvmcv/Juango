# The test suite, split by area into files that each run on their own (`julia --project=test
# test/orm.jl`). Here the files run in a few groups, one process per group: a process compiles
# Juango's code paths once for all its files. JUANGO_TEST_JOBS groups (default 2) run at once;
# each process peaks at about 1-1.5 GB. See CLAUDE.md before raising it.
using Test

# Longest first, so the two job slots finish at about the same time.
const GROUPS = [["orm", "db", "migrations"], ["views", "admin"], ["services"], ["templates", "forms"]]
const JOBS = parse(Int, get(ENV, "JUANGO_TEST_JOBS", "2"))

# Run each file of the group even when an earlier one fails; exit non-zero if any did.
const RUNNER = """
failed = String[]
for f in ARGS
    try
        include(f)
    catch e
        push!(failed, basename(f))
        e isa LoadError && e.error isa Test.TestSetException || showerror(stderr, e, catch_backtrace())
    end
end
isempty(failed) || (println(stderr, "\\nFAILED: ", join(failed, ", ")); exit(1))
"""

function run_group(files)
    paths = [joinpath(@__DIR__, f * ".jl") for f in files]
    cmd = `$(Base.julia_cmd()) --heap-size-hint=1500M --project=$(Base.active_project()) -e "using Test; $RUNNER" $paths`
    out = IOBuffer()
    t = @elapsed ok = success(pipeline(cmd; stdout = out, stderr = out))
    files, ok, t, String(take!(out))
end

const PRINT_LOCK = ReentrantLock()
results = asyncmap(GROUPS; ntasks = JOBS) do files
    r = run_group(files)
    lock(PRINT_LOCK) do                       # whole groups at a time, so the output doesn't interleave
        println("\n=== ", join(files, ", "), " (", round(Int, r[3]), " s) ===")
        print(r[4])
        flush(stdout)
    end
    r
end

println()
for (files, ok, t, _) in results
    println(rpad(join(files, ", "), 24), lpad(round(Int, t), 5), " s  ", ok ? "ok" : "FAILED")
end
@testset "Juango" begin
    for (files, ok, _, _) in results
        @test ok
    end
end
