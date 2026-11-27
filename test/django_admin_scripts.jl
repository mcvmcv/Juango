# Django's admin_scripts tests, ported (#227): CommandTypes (version, help, colors), ManageRunserver, StartApp,
# DiffSettings, Discovery, ArgumentOrder, DjangoAdminSuggestions, and utils_tests/test_termcolors. Django's `manage.py` is Juango's `manage.jl` (`execute_from_command_line`).
# julia --project=test test/django_admin_scripts.jl   (see setup.jl)
#
# Not translated: the settings-module classes (DjangoAdmin*Settings, Manage*Settings: Juango's settings are the
# project's configure! call, not a module named on the command line), ManageRunserver's migration and database
# checks, StartProject (Juango's startproject makes a Julia project), and CommandDBOptionChoiceTests (Juango's
# --database options aren't choices yet, #303).
@isdefined(TEST_SETUP_DONE) || include("setup.jl")

"What `f()` printed to stdout."
function das_stdout(f)
    path, io = mktemp()
    try
        redirect_stdout(f, io); flush(io)
        read(path, String)
    finally
        close(io); rm(path)
    end
end
das_run(args...) = das_stdout(() -> Juango.execute_from_command_line(collect(String, args)))
# Django's ColorCommand: writes in the ERROR style to stdout and stderr
Juango.register_command!("das_color"; requires_system_checks = []) do opts
    Juango.cmd_write("Hello, world!"; style = :ERROR)
    Juango.cmd_write("Hello, world!"; style = :ERROR, err = true)
end

@testset "django admin_scripts: CommandTypes" begin
    @test strip(das_run("version")) == string(pkgversion(Juango))                         # test_version
    @test das_run("version") == das_run("--version")                                       # test_version_alternative
    out = das_run("help")                                                                  # test_help
    @test occursin("Type 'manage.jl help <subcommand>' for help on a specific subcommand.", out)
    @test occursin("[juango]", out) && occursin("startapp", out)
    out = das_run("help", "--commands")                                                    # test_help_commands
    @test !occursin("usage:", out) && !occursin("[juango]", out) && occursin("startapp", out) && !occursin("\n\n", out)
    @test das_run("help") == das_run("--help") == das_run("-h")                            # test_help_alternative, test_help_short_altert
    out = das_run("check", "--help")                                                       # test_specific_help
    @test occursin("--tag", out) && occursin("--version", out) && findfirst("--tag", out)[1] < findfirst("--version", out)[1]
    @test occursin("Checks the entire Juango project for potential problems.", out)
    @test das_run("help", "check") == out                                                 # (help <subcommand>)

    s = Juango.no_style()                                                                  # test_color_style
    @test s.ERROR("Hello, world!") == "Hello, world!"
    @test Juango.make_style("nocolor").ERROR("Hello, world!") == "Hello, world!"
    for cfg in ("dark", "")
        e = Juango.make_style(cfg).ERROR("Hello, world!")
        @test occursin("Hello, world!", e) && e != "Hello, world!"
    end
    out, err = IOBuffer(), IOBuffer()                                                      # test_command_color (not a terminal: no colors)
    call_command("das_color"; stdout = out, stderr = err)
    @test String(take!(out)) == "Hello, world!\n" && String(take!(err)) == "Hello, world!\n"
    call_command("das_color"; stdout = out, stderr = err, no_color = true)                 # test_command_no_color
    @test String(take!(out)) == "Hello, world!\n" && String(take!(err)) == "Hello, world!\n"
    withenv("JUANGO_COLORS" => nothing, "DJANGO_COLORS" => nothing) do                     # test_force_color_execute
        call_command("das_color"; stdout = out, stderr = err, force_color = true)
        @test String(take!(out)) == "\e[31;1mHello, world!\n\e[0m" && String(take!(err)) == "\e[31;1mHello, world!\n\e[0m"
    end
    e = try call_command("das_color"; no_color = true, force_color = true); nothing catch x; x end  # test_no_color_force_color_mutually_exclusive_execute
    @test e isa CommandError && e.msg == "The --no-color and --force-color options can't be used together."
end

@testset "django admin_scripts: DjangoAdminSuggestions" begin
    @test occursin("Unknown command: 'rnserver'. Did you mean runserver?", Juango.unknown_command_message("rnserver"))  # test_suggestions
    @test !occursin("Did you mean", Juango.unknown_command_message("abcdef"))              # test_no_suggestions
    e = try Juango.cmd_help(["rnserver"]); nothing catch x; x end
    @test e isa CommandError && occursin("Did you mean runserver?", e.msg)
end

@testset "django admin_scripts: ManageRunserver" begin
    pa = Juango.parse_addrport
    @test pa() == ("127.0.0.1", "8000", false, false)                                     # test_runserver_addrport
    @test pa("1.2.3.4:8000") == ("1.2.3.4", "8000", false, false)
    @test pa("7000") == ("127.0.0.1", "7000", false, false)
    @test pa(""; use_ipv6 = true) == ("::1", "8000", true, true)                           # test_runner_addrport_ipv6
    @test pa("7000"; use_ipv6 = true) == ("::1", "7000", true, true)
    @test pa("[2001:0db8:1234:5678::9]:7000") == ("2001:0db8:1234:5678::9", "7000", true, true)
    @test pa("localhost:8000") == ("localhost", "8000", false, false)                     # test_runner_hostname
    @test pa("test.domain.local:7000") == ("test.domain.local", "7000", false, false)
    @test pa("test.domain.local:7000"; use_ipv6 = true) == ("test.domain.local", "7000", true, false)  # test_runner_hostname_ipv6
    @test pa(; default_addr = "0.0.0.0", default_port = "5000") == ("0.0.0.0", "5000", false, false)   # test_runner_custom_defaults
    @test pa(; use_ipv6 = true, default_addr_ipv6 = "::") == ("::", "8000", true, true)  # test_runner_custom_defaults_ipv6
    @test pa("beef:7654") == ("beef", "7654", false, false) && pa("deadbeef:7654") == ("deadbeef", "7654", false, false)  # test_runner_ambiguous
    e = try pa("not a port"); nothing catch x; x end
    @test e isa CommandError && e.msg == "\"not a port\" is not a valid port number or address:port pair."
    e = try pa("1.2.3.4:8000"; use_ipv6 = true); nothing catch x; x end
    @test e isa CommandError && e.msg == "\"1.2.3.4\" is not a valid IPv6 address."
    # test_zero_ip_addr, test_on_bind, test_hide_production_warning_with_environment_variable
    warning = "WARNING: This is a development server. Do not use it in a production setting."
    withenv("JUANGO_RUNSERVER_HIDE_WARNING" => "anything-but-true", "DJANGO_RUNSERVER_HIDE_WARNING" => nothing) do
        @test occursin("Starting development server at http://0.0.0.0:8000/", Juango.runserver_banner("http", "0", 8000))
        b = Juango.runserver_banner("http", "127.0.0.1", 14437)
        @test occursin("Starting development server at http://127.0.0.1:14437/", b) && occursin(warning, b)
        @test occursin("http://[::1]:8000/", Juango.runserver_banner("http", "::1", 8000))
    end
    withenv("JUANGO_RUNSERVER_HIDE_WARNING" => "true") do
        b = Juango.runserver_banner("http", "0", 8000)
        @test occursin("http://0.0.0.0:8000/", b) && !occursin(warning, b)
    end
end

@testset "django utils_tests: test_termcolors (TermColorTests)" begin
    P, pcs = Juango.PALETTES, Juango.parse_color_setting
    nocolor(pairs...) = merge(copy(P["nocolor"]), Dict(pairs...))
    d(; kw...) = Dict{String,Any}(string(k) => v for (k, v) in kw)
    @test pcs("") == P["dark"]                                                             # test_empty_string
    @test pcs("light") == P["light"] && pcs("dark") == P["dark"] && pcs("nocolor") === nothing  # test_simple_palette
    @test pcs("error=green") == nocolor("ERROR" => d(fg = "green"))                        # test_fg
    @test pcs("error=green/blue") == nocolor("ERROR" => d(fg = "green", bg = "blue"))      # test_fg_bg
    @test pcs("error=green,blink") == nocolor("ERROR" => d(fg = "green", opts = ("blink",)))  # test_fg_opts
    @test pcs("error=green,bold,blink") == nocolor("ERROR" => d(fg = "green", opts = ("blink", "bold")))
    @test pcs("error=green/blue,blink") == nocolor("ERROR" => d(fg = "green", bg = "blue", opts = ("blink",)))  # test_fg_bg_opts
    @test pcs("error=green/blue,bold,blink") == nocolor("ERROR" => d(fg = "green", bg = "blue", opts = ("blink", "bold")))
    @test pcs("light;error=green") == merge(copy(P["light"]), Dict("ERROR" => d(fg = "green")))  # test_override_palette
    @test pcs("nocolor;error=green") == nocolor("ERROR" => d(fg = "green"))                # test_override_nocolor
    @test pcs("error=green;light") == P["light"]                                           # test_reverse_override
    @test pcs("error=green;sql_field=blue") == nocolor("ERROR" => d(fg = "green"), "SQL_FIELD" => d(fg = "blue"))  # test_multiple_roles
    @test pcs("light;error=green;sql_field=blue") ==                                       # test_override_with_multiple_roles
          merge(copy(P["light"]), Dict("ERROR" => d(fg = "green"), "SQL_FIELD" => d(fg = "blue")))
    @test pcs(";") === nothing && pcs("light;") == P["light"] && pcs(";;;") === nothing   # test_empty_definition
    @test pcs("error=green,") == pcs("error=green,,,") == nocolor("ERROR" => d(fg = "green"))  # test_empty_options
    @test pcs("error=green,,blink,,") == nocolor("ERROR" => d(fg = "green", opts = ("blink",)))
    @test pcs("unknown") === nothing                                                       # test_bad_palette
    @test pcs("unknown=") === nothing && pcs("unknown=green") === nothing                 # test_bad_role
    @test pcs("unknown=green;sql_field=blue") == nocolor("SQL_FIELD" => d(fg = "blue"))
    @test pcs("error=") === nothing && pcs("error=unknown") === nothing                   # test_bad_color
    @test pcs("error=;sql_field=blue") == pcs("error=unknown;sql_field=blue") == nocolor("SQL_FIELD" => d(fg = "blue"))
    @test pcs("error=green/unknown") == nocolor("ERROR" => d(fg = "green"))
    @test pcs("error=green/blue/something") == nocolor("ERROR" => d(fg = "green", bg = "blue"))
    @test pcs("error=green/blue/something,blink") == nocolor("ERROR" => d(fg = "green", bg = "blue", opts = ("blink",)))
    @test pcs("error=green,unknown") == nocolor("ERROR" => d(fg = "green"))                # test_bad_option
    @test pcs("error=green,unknown,blink") == nocolor("ERROR" => d(fg = "green", opts = ("blink",)))
    @test pcs("ERROR=green") == pcs("eRrOr=green") == nocolor("ERROR" => d(fg = "green"))  # test_role_case
    @test pcs("error=GREEN") == pcs("error=gReEn") == nocolor("ERROR" => d(fg = "green"))  # test_color_case
    @test pcs("error=GREEN/BLUE") == pcs("error=gReEn/bLuE") == nocolor("ERROR" => d(fg = "green", bg = "blue"))
    @test pcs("error=green,BLINK") == pcs("error=green,bLiNk") == nocolor("ERROR" => d(fg = "green", opts = ("blink",)))  # test_opts_case
    c = Juango.colorize
    @test c(nothing) == c("") == "\e[m\e[0m"                                               # test_colorize_empty_text
    @test c(nothing; opts = ("noreset",)) == c(""; opts = ("noreset",)) == "\e[m"
    @test c(""; opts = ("reset",)) == "\e[0m"                                              # test_colorize_reset
    @test c("Test"; fg = "red") == "\e[31mTest\e[0m" && c("Test"; bg = "red") == "\e[41mTest\e[0m"  # test_colorize_fg_bg
    @test c("Test"; other = "red") == "\e[mTest\e[0m"
    @test c("Test"; opts = ("bold", "underscore")) == "\e[1;4mTest\e[0m"                   # test_colorize_opts
    @test c("Test"; opts = ("blink",)) == "\e[5mTest\e[0m" && c("Test"; opts = ("not_an_option",)) == "\e[mTest\e[0m"
end

@testset "django admin_scripts: StartApp" begin
    tmp = mktempdir()
    q(f) = redirect_stdout(f, devnull)
    das_err(f) = try q(f); nothing catch e; e isa CommandError ? e.msg : rethrow() end
    for bad in ("7testproject", "../testproject")                                        # test_invalid_name
        @test das_err(() -> Juango.startapp(bad; dir = tmp)) == "'$bad' is not a valid app name. Please make sure the name is a valid identifier."
        @test !ispath(joinpath(tmp, bad))
    end
    # test_importable_name (an app `dates` would be a module Dates, the standard library's name)
    @test das_err(() -> Juango.startapp("dates"; dir = tmp)) ==
          "'dates' conflicts with the name of an existing Julia module (Dates) and cannot be used as an app name. Please try another name."
    @test !ispath(joinpath(tmp, "dates"))
    for bad in ("invalid.dir_name", "7invalid_dir_name", ".invalid_dir_name")              # test_invalid_target_name
        @test das_err(() -> Juango.startapp("app", bad; dir = tmp)) == "'$bad' is not a valid app directory. Please make sure the directory is a valid identifier."
    end
    @test occursin("cannot be used as an app directory", das_err(() -> Juango.startapp("app", "dates"; dir = tmp)))  # test_importable_target_name
    mkpath(joinpath(tmp, "apps", "app1"))                                                 # test_trailing_slash_in_target_app_directory_name
    q(() -> Juango.startapp("app", joinpath("apps", "app1", ""); dir = tmp))
    @test isfile(joinpath(tmp, "apps", "app1", "App.jl"))
    mkpath(joinpath(tmp, "apps2", "app1"))                                                # test_overlaying_app
    q(() -> Juango.startapp("app1", "apps2/app1"; dir = tmp))
    @test occursin("already exists. Overlaying an app into an existing directory won't replace conflicting files.",
                   das_err(() -> Juango.startapp("app1", "apps2/app1"; dir = tmp)))
    q(() -> Juango.startapp("new_app"; dir = tmp))                                        # test_template
    @test occursin("module NewApp", read(joinpath(tmp, "new_app", "NewApp.jl"), String)) &&
          occursin("App(\"new_app\"", read(joinpath(tmp, "new_app", "NewApp.jl"), String))
    q(() -> Juango.startapp("my_app", "my_app2"; dir = tmp))                               # test_creates_directory_when_custom_app_destination_missing
    @test isdir(joinpath(tmp, "my_app2"))
    q(() -> Juango.startapp("my_app", "apps3/my_app"; dir = tmp))                          # test_custom_app_destination_missing_with_nested_subdirectory
    @test isdir(joinpath(tmp, "apps3", "my_app"))
    q(() -> Juango.startapp("parent"; dir = tmp))                                         # test_custom_name_with_app_within_other_app
    q(() -> Juango.startapp("child", "parent/child"; dir = tmp))
    @test isdir(joinpath(tmp, "parent", "child"))
    if !Sys.iswindows() && get(ENV, "USER", "") != "root"                                  # test_custom_app_directory_creation_error_handling
        mkpath(joinpath(tmp, "project_dir")); chmod(joinpath(tmp, "project_dir"), 0o500)
        @test occursin("ermission denied", something(das_err(() -> Juango.startapp("my_app", "project_dir/my_app"; dir = tmp)), ""))
        @test !ispath(joinpath(tmp, "project_dir", "my_app"))
        chmod(joinpath(tmp, "project_dir"), 0o700)
    end
end

@testset "django admin_scripts: DiffSettings" begin
    override_settings(FOO = "bar", STATIC_URL = Juango.default_settings()[:STATIC_URL]) do
        out = Juango.diffsettings()                                                          # test_basic, test_settings_configured
        @test "FOO = \"bar\"  ###" in out && !any(l -> startswith(l, "STATIC_URL"), out)
        @test any(l -> startswith(l, "### STATIC_URL = "), Juango.diffsettings(; all = true))   # test_all
        # test_custom_default: compared with other defaults
        d = merge(Juango.default_settings(), Dict(:FOO => "bar"))
        @test !any(l -> startswith(l, "FOO"), Juango.diffsettings(; default = d))
        out = Juango.diffsettings(; output = :unified)                                     # test_unified
        @test "+ FOO = \"bar\"" in out && !any(l -> startswith(l, "  APPEND_SLASH"), out)
        out = Juango.diffsettings(; output = :unified, all = true)                          # test_unified_all
        @test any(l -> startswith(l, "  APPEND_SLASH = "), out) && "+ FOO = \"bar\"" in out
        @test any(l -> startswith(l, "- DATABASE = "), out) && any(l -> startswith(l, "+ DATABASE = "), out)
        @test strip(das_run("diffsettings", "--output=unified")) == strip(join(Juango.diffsettings(; output = :unified), "\n"))
    end
end

# Django's base_command: labels and three options
Juango.register_command!("das_base_command"; requires_system_checks = [],
                         arguments = [Juango.arg("args"; nargs = "*"), Juango.arg("--option_a", "-a"; default = "1"),
                                      Juango.arg("--option_b", "-b"; default = "2"), Juango.arg("--option_c", "-c"; default = "3")]) do opts
    println(Juango.cmd_stdout(), "EXECUTE:BaseCommand labels=", Tuple(opts.args), ", option_a=", repr(opts.option_a), ", option_b=",
            repr(opts.option_b), ", option_c=", repr(opts.option_c), ", settings=", repr(opts.settings))
end

@testset "django admin_scripts: Discovery, ArgumentOrder" begin
    # Discovery.test_precedence: of two apps with a command of the same name, the first in INSTALLED_APPS wins
    complex_app, simple_app = Juango.App("das_complex_app"), Juango.App("das_simple_app")
    complex_app.commands["duplicate"] = ("", args -> println(Juango.cmd_stdout(), "complex_app"))
    simple_app.commands["duplicate"] = ("", args -> println(Juango.cmd_stdout(), "simple_app"))
    for (apps, want) in (([complex_app, simple_app], "complex_app"), ([simple_app, complex_app], "simple_app"))
        override_settings(INSTALLED_APPS = vcat(Any[a for a in settings.INSTALLED_APPS], apps)) do
            out = IOBuffer()
            call_command("duplicate"; stdout = out)
            @test strip(String(take!(out))) == want
        end
    end
    # ArgumentOrder: options before and after --settings (which Juango takes and ignores)
    expected(b = "\"2\"") = "EXECUTE:BaseCommand labels=(\"testlabel\",), option_a=\"x\", option_b=$b, option_c=\"3\", settings=\"alternate_settings\""
    @test strip(das_run("das_base_command", "testlabel", "--settings=alternate_settings", "--option_a=x")) == expected()  # test_setting_then_option
    @test strip(das_run("das_base_command", "testlabel", "--settings=alternate_settings", "-a", "x")) == expected()       # test_setting_then_short_option
    @test strip(das_run("das_base_command", "testlabel", "--option_a=x", "--settings=alternate_settings")) == expected()  # test_option_then_setting
    @test strip(das_run("das_base_command", "testlabel", "-a", "x", "--settings=alternate_settings")) == expected()       # test_short_option_then_setting
    @test strip(das_run("das_base_command", "testlabel", "--option_a=x", "--settings=alternate_settings", "--option_b=y")) ==  # test_option_then_setting_then_option
          expected("\"y\"")
end
