# Django's bash_completion tests, ported (#227): tests/bash_completion. Django's ManagementUtility.autocomplete is
# Juango's `autocomplete(comp_words, comp_cword)`, which manage.jl runs when JUANGO_AUTO_COMPLETE is set.
# julia --project=test test/django_bash_completion.jl   (see setup.jl)
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

Juango.register_command!("dbc_test_command"; requires_system_checks = [],
                         arguments = [Juango.arg("--list"; action = :store_true)]) do opts
    nothing
end
"Bash's COMP_WORDS and COMP_CWORD for a command line, and what autocomplete prints for it (Django's _user_input + _run_autocomplete)."
function dbc_complete(input)
    idx = length(split(input, " ")) - 1
    out = IOBuffer()
    Juango.autocomplete(input, endswith(input, " ") ? idx + 1 : idx; io = out)
    split(strip(String(take!(out))), "\n")
end

@testset "django bash_completion: BashCompletionTests" begin
    for cmd in ("manage.jl", "julia")
        @test dbc_complete("$cmd sqlmigrate --verb") == ["--verbosity="]                    # test_option_flags, test_manage_py
    end
    @test dbc_complete("manage.jl dbc_test_command --l") == ["--list"]                       # test_custom_command
    @test dbc_complete("manage.jl sql") == ["sqlflush sqlmigrate sqlschema sqlsequencereset"]  # test_subcommands (Juango has sqlschema too)
    @test all(l -> startswith(l, "--"), dbc_complete("manage.jl startapp "))                 # test_completed_subcommand
    @test dbc_complete("manage.jl help --") == [""]                                          # test_help
    labels = sort([a.label for a in Juango.installed_apps() if startswith(a.label, "a")])    # test_app_completion
    @test dbc_complete("manage.jl sqlmigrate a") == labels
    # (through manage.jl: JUANGO_AUTO_COMPLETE with bash's variables)
    path, io = mktemp()
    withenv("JUANGO_AUTO_COMPLETE" => "1", "COMP_WORDS" => "manage.jl sqlm", "COMP_CWORD" => "1") do
        Base.ScopedValues.with(Juango.COMMAND_IO => Juango.CommandIO(stdout = io)) do
            Juango.autocomplete(ENV["COMP_WORDS"], parse(Int, ENV["COMP_CWORD"]))
        end
    end
    flush(io); close(io)
    @test strip(read(path, String)) == "sqlmigrate"
end
