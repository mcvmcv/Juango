# The test suite, split by area into files that each run on their own (`julia --project=test
# test/orm.jl`). Here the files run in a few groups, one process per group: a process compiles
# Juango's code paths once for all its files. JUANGO_TEST_JOBS groups (default 3) run at once;
# each process peaks at about 1-1.5 GB. See CLAUDE.md before raising it.
using Test

# Longest first, so the job slots finish at about the same time.
const GROUPS = [["orm", "db", "migrations", "django_signals", "django_serializers", "django_timezones", "django_orm5", "django_multiple_database"], ["views", "admin", "django_templates", "django_migrations", "django_auth", "django_auth_backends", "django_generic_views", "django_shortcuts", "django_view_tests", "django_test_client", "django_test_client_regress", "django_flatpages", "django_sites", "django_signed_cookies", "django_context_processors", "django_introspection", "django_foreign_object", "django_admin2", "django_middleware2", "django_fixtures_regress", "django_inspectdb"], ["services", "django_forms", "django_admin", "django_csrf", "django_sessions", "django_urls", "django_middleware", "django_httpwrappers", "django_pagination", "django_messages", "django_signing", "django_handlers", "django_i18n", "django_i18n_patterns", "django_i18n_formats", "django_orm6", "django_validation", "django_composite_pk"], ["templates", "forms", "django_orm", "django_humanize", "django_validators", "django_mail", "django_cache", "django_sitemaps", "django_syndication", "django_decorators", "django_file_storage", "django_i18n_tools", "django_orm2", "django_orm3", "django_orm4", "django_orm7", "django_orm8", "django_forms2"]]
const JOBS = parse(Int, get(ENV, "JUANGO_TEST_JOBS", "3"))
# browser tests of live.js (they need chromium and node): JUANGO_BROWSER_TESTS=1
get(ENV, "JUANGO_BROWSER_TESTS", "") == "1" && push!(GROUPS[2], "browser")

# Run each file of the group even when an earlier one fails; exit non-zero if any did.
const RUNNER = """
failed = String[]
times = String[]
for f in ARGS
    t0 = time()
    try
        include(f)
    catch e
        push!(failed, basename(f))
        e isa LoadError && e.error isa Test.TestSetException || showerror(stderr, e, catch_backtrace())
    end
    push!(times, string(basename(f), " ", round(Int, time() - t0), " s"))
end
println("file times (the first includes loading Juango): ", join(times, ", "))
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
