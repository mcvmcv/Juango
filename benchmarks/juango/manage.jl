#!/usr/bin/env julia
# julia --project manage.jl <command>   (migrate, seed, runserver)
include(joinpath(@__DIR__, "project.jl"))
Juango.execute_from_command_line(ARGS)
