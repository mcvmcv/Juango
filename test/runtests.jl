# The whole suite: each part runs in its own Julia process, one after another, so memory is
# freed between parts (one process for everything needs more than 5 GB). Run one part with
# `julia --project=test test/orm.jl`.
using Test

const PARTS = ["templates", "orm", "forms", "views", "admin", "services", "db", "migrations"]

@testset "Juango" begin
    for part in PARTS
        file = joinpath(@__DIR__, part * ".jl")
        cmd = `$(Base.julia_cmd()) --heap-size-hint=2G --project=$(Base.active_project()) $file`
        println("\n=== $part ===")
        @test success(pipeline(cmd; stdout = stdout, stderr = stderr))
    end
end
