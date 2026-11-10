#!/usr/bin/env julia
# julia --project manage.jl <command>   (try: help, migrate, seed, createsuperuser, runserver)
include(joinpath(@__DIR__, "project.jl"))
Juango.execute_from_command_line(ARGS)
