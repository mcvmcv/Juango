# Django's shell tests, ported (#227): tests/shell. Django's `shell.Command().get_namespace(...)` is Juango's
# `shell_namespace(...)`, and `get_auto_imports` is `shell_auto_imports()` (passed as `auto_imports` to change it);
# the import lines are Julia's (`using Juango: settings, ...`).
# julia --project=test test/django_shell.jl   (see setup.jl)
#
# Not translated: test_no_settings (Juango has no settings module to be missing), the IPython / bpython / python
# interface tests (Juango's interactive shell is `julia -i manage.jl`), and isort ordering.
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

@model struct DshMarker
    Meta(table = "dsh_marker", app_label = "dsh")
end
@model struct DshPhone
    name = CharField(max_length = 50)
    Meta(table = "dsh_phone", app_label = "dsh")
end
"What `f()` printed to stdout."
function dsh_stdout(f)
    path, io = mktemp()
    try
        redirect_stdout(f, io)
        flush(io)
        read(path, String)
    finally
        close(io); rm(path)
    end
end
dsh_ns(; kw...) = (out = IOBuffer(); ns = Juango.shell_namespace(; io = out, kw...); (ns, String(take!(out))))
const DSH_DEFAULTS = ["Juango.settings", "Juango.connection_queries", "Juango.reset_queries!", "Juango.Functions", "Juango.timezone_now"]

@testset "django shell: ShellCommandTestCase" begin
    script_globals = "println(@isdefined(DshPhone) && @isdefined(settings))"
    script_with_inline_function = "f() = println(Juango.VERSION_STRING)\nf()"
    let
        # test_command_option, test_command_option_globals, test_command_option_inline_function_call
        @test strip(dsh_stdout(() -> call_command("shell", "-c", "println(1 + 1)", "-v", "0"))) == "2"
        @test strip(dsh_stdout(() -> call_command("shell"; command = script_globals, verbosity = 0))) == "true"
        @test strip(dsh_stdout(() -> call_command("shell"; command = script_with_inline_function, verbosity = 0))) == string(Juango.VERSION_STRING)
        # test_stdin_read, test_stdin_read_globals, test_stdin_read_inline_function_call (code piped in)
        @test strip(dsh_stdout(() -> call_command("shell"; stdin = "println(100)\n", isatty = false, verbosity = 0))) == "100"
        @test strip(dsh_stdout(() -> call_command("shell"; stdin = script_globals, isatty = false, verbosity = 0))) == "true"
        @test strip(dsh_stdout(() -> call_command("shell"; stdin = script_with_inline_function, isatty = false, verbosity = 0))) == string(Juango.VERSION_STRING)

        ns, _ = dsh_ns()                                                                   # test_get_namespace
        @test ns["settings"] === settings && ns["reset_queries!"] === Juango.reset_queries! && ns["Functions"] === Juango.Functions
        @test ns["DshMarker"] === DshMarker && ns["DshPhone"] === DshPhone && ns["User"] === Juango.User
        # test_no_imports_flag
        @test all(v -> dsh_ns(; verbosity = v, no_imports = true) == (Dict{String,Any}(), ""), 0:3)
        ns, out = dsh_ns(; verbosity = 0)                                                  # test_verbosity_zero
        @test length(ns) == length(unique(last.(split.(Juango.shell_auto_imports(), '.')))) && out == ""
        ns, out = dsh_ns(; verbosity = 1)                                                  # test_verbosity_one
        @test out == "$(length(ns)) objects imported automatically (use -v 2 for details).\n\n"
        # test_get_namespace_overridden (more imports)
        ns, _ = dsh_ns(; auto_imports = vcat(Juango.shell_auto_imports(), ["Juango.reverse_url", "Juango.resolve"]))
        @test ns["reverse_url"] === Juango.reverse_url && ns["resolve"] === Juango.resolve
    end
    override_settings(INSTALLED_APPS = String[]) do                                       # test_get_namespace_default_imports
        ns, _ = dsh_ns()
        @test all(n -> haskey(ns, n), ["settings", "connection_queries", "reset_queries!", "Functions", "timezone_now"]) && !haskey(ns, "User")
    end
    # test_message_with_stdout_no_installed_apps (the default imports alone)
    @test dsh_ns(; verbosity = 0, auto_imports = DSH_DEFAULTS)[2] == ""
    @test dsh_ns(; verbosity = 1, auto_imports = DSH_DEFAULTS)[2] == "5 objects imported automatically (use -v 2 for details).\n\n"
    @test dsh_ns(; verbosity = 2, auto_imports = DSH_DEFAULTS)[2] == "5 objects imported automatically:\n\n" *
          "  using Juango: settings, connection_queries, reset_queries!, Functions, timezone_now\n\n"
    # test_message_with_stdout_listing_objects (duplicates counted once; top-level modules as `import`)
    _, out = dsh_ns(; verbosity = 2, auto_imports = ["Juango", "Juango.settings", "Juango.reverse_url", "Juango.resolve", "Juango", "Juango.reverse_url"])
    @test out == "4 objects imported automatically:\n\n  import Juango\n  using Juango: settings, reverse_url, resolve\n\n"
    # test_message_with_stdout_one_object
    @test [dsh_ns(; verbosity = v, auto_imports = ["Juango.settings"])[2] for v in 0:2] ==
          ["", "1 object imported automatically (use -v 2 for details).\n\n", "1 object imported automatically:\n\n  using Juango: settings\n\n"]
    # test_message_with_stdout_zero_object
    @test [dsh_ns(; verbosity = v, auto_imports = String[])[2] for v in 0:2] ==
          ["", "0 objects imported automatically.\n\n", "0 objects imported automatically.\n\n"]
    # test_message_with_stdout_overriden_none_result
    @test all(v -> dsh_ns(; verbosity = v, auto_imports = nothing) == (Dict{String,Any}(), ""), 0:2)
    # test_override_get_auto_imports
    @test dsh_ns(; verbosity = 2, auto_imports = ["Juango", "Base", "does.not.exist", "doesntexisteither"])[2] ==
          "2 objects could not be automatically imported:\n\n  does.not.exist\n  doesntexisteither\n\n" *
          "2 objects imported automatically:\n\n  import Juango\n  import Base\n\n"
    # test_override_get_auto_imports_one_error, test_override_get_auto_imports_many_errors
    expected = "1 object could not be automatically imported:\n\n  foo\n\n0 objects imported automatically.\n\n"
    @test [dsh_ns(; verbosity = v, auto_imports = ["foo"])[2] for v in 0:2] == ["", expected, expected]
    expected = "2 objects could not be automatically imported:\n\n  does.not.exist\n  doesntexisteither\n\n0 objects imported automatically.\n\n"
    @test [dsh_ns(; verbosity = v, auto_imports = ["does.not.exist", "doesntexisteither"])[2] for v in 0:2] == ["", expected, expected]
end
foreach(Juango.unregister_model!, (DshPhone, DshMarker))
